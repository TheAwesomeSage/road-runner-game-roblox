--!strict
--[[
	ObstacleSpawner
	Fills a freshly placed chunk's spawn points with obstacles and coins, and
	hands them back to their pools when the chunk is recycled.

	For every obstacle row in the chunk it:
	  1. rolls whether the row is used at all (more likely at higher difficulty)
	  2. picks a pattern from ChunkConfig.Patterns (harder patterns are
	     unlocked and weighted up as difficulty rises)
	  3. rejects patterns that could not be reached from the previous row,
	     so the track is always passable

	Gameplay data (position, hitbox, jumpable) is recorded on the chunk as
	plain tables. Collision is done against those, never against the art.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChunkConfig = require(script.Parent.ChunkConfig)
local Pool = require(script.Parent.Pool)
local TerrainChunk = require(script.Parent.TerrainChunk)
local RunnerConfig = require(ReplicatedStorage.Shared.RunnerConfig)

local LANES = RunnerConfig.LaneCount
local MAX_PATTERN_TRIES = 6

export type Hazard = {
	Kind: string,
	Distance: number, -- track distance of the hitbox centre
	Lateral: number,
	Size: Vector3,
	Jumpable: boolean,
	Instance: PVInstance,
}

export type Coin = {
	Distance: number,
	Lateral: number,
	Height: number,
	Instance: BasePart,
	Collected: boolean,
}

-- Per-track memory between rows, so a pattern can be checked against the
-- previous row even when that row was in the previous chunk.
export type TrackState = {
	OpenLanes: { [number]: boolean },
}

-- The parts of an active chunk this module reads and writes.
export type ChunkSlot = {
	Model: Model,
	StartDistance: number,
	Hazards: { Hazard },
	Coins: { Coin },
}

type ParsedPattern = {
	Lanes: { string | false }, -- obstacle kind per lane, false = empty
	Weight: number,
	MinDifficulty: number,
}

-- Startup validation -----------------------------------------------------------
-- Bad pattern data should fail at server start, not as an impossible wall of
-- trunks ten minutes into someone's run.
local function parsePatterns(): { ParsedPattern }
	local parsed = {}
	for _, pattern in ChunkConfig.Patterns do
		assert(#pattern.Lanes == LANES, `Pattern "{pattern.Lanes}" must have {LANES} lanes`)
		local lanes: { string | false } = {}
		local passable = false
		for i = 1, LANES do
			local char = pattern.Lanes:sub(i, i)
			if char == "." then
				lanes[i] = false
				passable = true
			else
				local kind = ChunkConfig.PatternKeys[char]
				assert(kind, `Pattern "{pattern.Lanes}": unknown key "{char}"`)
				local obstacleType = ChunkConfig.ObstacleTypes[kind]
				assert(obstacleType, `Pattern "{pattern.Lanes}": no ObstacleTypes entry for "{kind}"`)
				lanes[i] = kind
				passable = passable or obstacleType.Jumpable
			end
		end
		assert(passable, `Pattern "{pattern.Lanes}" blocks every lane`)
		table.insert(parsed, { Lanes = lanes, Weight = pattern.Weight, MinDifficulty = pattern.MinDifficulty })
	end
	return parsed
end

local PATTERNS = parsePatterns()

local ObstacleSpawner = {}
ObstacleSpawner.__index = ObstacleSpawner

export type ObstacleSpawner = typeof(setmetatable(
	{} :: {
		_obstaclePools: { [string]: Pool.Pool },
		_coinPool: Pool.Pool,
	},
	ObstacleSpawner
))

function ObstacleSpawner.new(holdingParent: Instance): ObstacleSpawner
	local theme = TerrainChunk.Theme
	local obstaclePools = {}
	for kind, obstacleType in ChunkConfig.ObstacleTypes do
		obstaclePools[kind] = Pool.new(`Obstacle_{kind}`, function()
			return theme.BuildObstacle(kind, obstacleType.Hitbox)
		end, holdingParent, ChunkConfig.HoldingCFrame)
	end
	local coinPool = Pool.new("Coins", function()
		local coin = theme.BuildCoin()
		coin:AddTag("RunnerCoin") -- the client spins these
		return coin
	end, holdingParent, ChunkConfig.HoldingCFrame)

	return setmetatable({
		_obstaclePools = obstaclePools,
		_coinPool = coinPool,
	}, ObstacleSpawner)
end

function ObstacleSpawner.NewTrackState(): TrackState
	local open = {}
	for lane = 1, LANES do
		open[lane] = true
	end
	return { OpenLanes = open }
end

-- A lane counts as reachable if it is open and within one lane of a lane that
-- was open in the previous row (one lane change fits comfortably in the gap).
local function isReachable(open: { [number]: boolean }, previous: { [number]: boolean }): boolean
	for lane = 1, LANES do
		if open[lane] and (previous[lane - 1] or previous[lane] or previous[lane + 1]) then
			return true
		end
	end
	return false
end

local function pickPattern(rng: Random, difficulty: number): ParsedPattern?
	local total = 0
	local weights = {}
	for i, pattern in PATTERNS do
		local w = 0
		if pattern.MinDifficulty <= difficulty then
			-- Harder patterns (higher MinDifficulty) scale up faster.
			w = pattern.Weight * (1 + ChunkConfig.Difficulty.ComplexityBias * pattern.MinDifficulty * difficulty)
		end
		weights[i] = w
		total += w
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	for i, w in weights do
		roll -= w
		if roll <= 0 and w > 0 then
			return PATTERNS[i]
		end
	end
	return PATTERNS[#PATTERNS]
end

-- Which lanes of `pattern` are passable in this particular row (a lane with
-- no spawn point in the template simply gets no obstacle).
local function openLanesFor(pattern: ParsedPattern, row: TerrainChunk.ObstacleRow): { [number]: boolean }
	local open = {}
	for lane = 1, LANES do
		local kind = pattern.Lanes[lane]
		open[lane] = not kind or not row.Points[lane] or ChunkConfig.ObstacleTypes[kind :: string].Jumpable
	end
	return open
end

local function allOpen(): { [number]: boolean }
	local open = {}
	for lane = 1, LANES do
		open[lane] = true
	end
	return open
end

function ObstacleSpawner.Populate(
	self: ObstacleSpawner,
	chunk: ChunkSlot,
	template: TerrainChunk.TemplateInfo,
	difficulty: number,
	state: TrackState,
	rng: Random
)
	local rootCFrame = chunk.Model:GetPivot()
	local spawned = chunk.Model:FindFirstChild("Spawned")
	if not spawned then
		local folder = Instance.new("Folder")
		folder.Name = "Spawned"
		folder.Parent = chunk.Model
		spawned = folder
	end

	local rowChance = ChunkConfig.Difficulty.RowChanceMin
		+ (ChunkConfig.Difficulty.RowChanceMax - ChunkConfig.Difficulty.RowChanceMin) * difficulty

	-- Obstacles
	for _, row in template.Rows do
		local chosen: ParsedPattern? = nil
		if rng:NextNumber() < rowChance then
			for _ = 1, MAX_PATTERN_TRIES do
				local candidate = pickPattern(rng, difficulty)
				if candidate and isReachable(openLanesFor(candidate, row), state.OpenLanes) then
					chosen = candidate
					break
				end
			end
		end

		if not chosen then
			state.OpenLanes = allOpen()
			continue
		end

		for lane = 1, LANES do
			local laneKind = chosen.Lanes[lane]
			local point = row.Points[lane]
			if laneKind == false or point == nil then
				continue
			end
			local kind = laneKind :: string
			local obstacleType = ChunkConfig.ObstacleTypes[kind]
			local instance = self._obstaclePools[kind]:Acquire()
			-- Square obstacles get a random quarter turn so repeats look different.
			local spin = if obstacleType.Hitbox.X == obstacleType.Hitbox.Z
				then CFrame.Angles(0, rng:NextInteger(0, 3) * math.pi / 2, 0)
				else CFrame.identity
			instance:PivotTo(rootCFrame * point.Offset * spin)
			instance.Parent = spawned
			table.insert(chunk.Hazards, {
				Kind = kind,
				Distance = chunk.StartDistance - point.Offset.Position.Z,
				Lateral = point.Offset.Position.X,
				Size = obstacleType.Hitbox,
				Jumpable = obstacleType.Jumpable,
				Instance = instance,
			})
		end
		state.OpenLanes = openLanesFor(chosen, row)
	end

	-- Coins: each run goes in one random lane.
	for _, run in template.CoinRuns do
		if rng:NextNumber() >= ChunkConfig.Coins.RunChance then
			continue
		end
		local points = run[rng:NextInteger(1, LANES)]
		if not points then
			continue -- this template has no coin points in that lane
		end
		for _, point in points do
			local coin = self._coinPool:Acquire() :: BasePart
			coin:PivotTo(rootCFrame * point.Offset * CFrame.Angles(0, math.pi / 2, 0))
			coin.Parent = spawned
			table.insert(chunk.Coins, {
				Distance = chunk.StartDistance - point.Offset.Position.Z,
				Lateral = point.Offset.Position.X,
				Height = point.Offset.Position.Y,
				Instance = coin,
				Collected = false,
			})
		end
	end
end

-- Returns one coin to the pool as soon as it is picked up.
function ObstacleSpawner.CollectCoin(self: ObstacleSpawner, coin: Coin)
	if coin.Collected then
		return
	end
	coin.Collected = true
	self._coinPool:Release(coin.Instance)
end

-- Returns everything spawned on a chunk to the pools. Must run BEFORE the
-- chunk itself is released, otherwise the obstacles would travel with it.
function ObstacleSpawner.Clear(self: ObstacleSpawner, chunk: ChunkSlot)
	for _, hazard in chunk.Hazards do
		self._obstaclePools[hazard.Kind]:Release(hazard.Instance)
	end
	for _, coin in chunk.Coins do
		if not coin.Collected then
			self._coinPool:Release(coin.Instance)
		end
	end
	table.clear(chunk.Hazards)
	table.clear(chunk.Coins)
end

return ObstacleSpawner
