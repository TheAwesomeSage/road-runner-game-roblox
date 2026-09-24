--!strict
--[[
	ChunkManager
	Owns one runner's track: a rolling window of chunks that starts just behind
	the runner and reaches ChunksAhead chunks in front of them.

	-----------------------------------------------------------------------------
	Coordinates
	-----------------------------------------------------------------------------
	All bookkeeping is in TRACK DISTANCE (studs from the track origin, forward
	= world -Z), not world positions. Each active chunk remembers:

	    StartDistance ---------------------------> EndDistance
	    (its Root marker)                           (its EndMarker)

	and the invariant for the active list is:

	    active[i + 1].StartDistance == active[i].EndDistance      (no gaps)
	    active is sorted oldest (nearest the runner's back) -> newest

	-----------------------------------------------------------------------------
	Per-update order (see Update)
	-----------------------------------------------------------------------------
	  1. SPAWN ahead first, while the road ends less than
	     ChunksAhead * ChunkLength in front of the runner.
	  2. DESPAWN behind second, any chunk whose END is more than DespawnBehind
	     behind the runner.

	Spawning first matters: a new chunk is positioned on the newest chunk's
	EndMarker. If we despawned first and the list became empty (a very long
	frame, or a bad distance value), there would be nothing to attach to and
	the track would restart at the origin, far behind the runner. The newest
	chunk is always ahead of the runner after step 1, so step 2 can never
	remove it.

	-----------------------------------------------------------------------------
	Pitfalls this module is careful about
	-----------------------------------------------------------------------------
	* Despawn is measured from a chunk's END, not its start. Measuring from the
	  start would recycle the chunk the runner is standing on as soon as they
	  are DespawnBehind studs into it.
	* DespawnBehind must be larger than the camera's distance behind the
	  runner, or the road visibly disappears under the camera.
	* Both loops are `while`, not `if`: after a hitch (large dt) the runner can
	  cross more than one chunk in a single update.
	* Obstacles are cleared from a chunk BEFORE the chunk is returned to the
	  pool. Otherwise PivotTo would carry them to the holding area inside the
	  chunk, and they would still count as "in use" in their own pools.
	* The next chunk is placed on the previous EndMarker's POSITION only
	  (rotation stripped). The distance maths assumes a straight track; a
	  slightly rotated marker on a hand-built template would otherwise bend the
	  track and make distances wrong.
	* A pooled chunk keeps its old "Spawned" folder (now empty) and is simply
	  moved; nothing is destroyed or re-created during a run.
]]

local ChunkConfig = require(script.Parent.ChunkConfig)
local ObstacleSpawner = require(script.Parent.ObstacleSpawner)
local Pool = require(script.Parent.Pool)
local TerrainChunk = require(script.Parent.TerrainChunk)

-- Extra margin when looking up chunks for collision, in case a hazard's
-- hitbox sticks out past its chunk's end (e.g. a trunk near the boundary).
local QUERY_MARGIN = 10
-- Warn if placement and distance bookkeeping disagree by more than this.
local PLACEMENT_TOLERANCE = 0.05

export type ActiveChunk = {
	Template: TerrainChunk.TemplateInfo,
	Model: Model,
	StartDistance: number,
	EndDistance: number,
	Hazards: { ObstacleSpawner.Hazard },
	Coins: { ObstacleSpawner.Coin },
}

-- Shared by every track: one pool per template, so a chunk recycled by one
-- player's track can be reused by another's.
local templates: { TerrainChunk.TemplateInfo } = {}
local chunkPools: { [string]: Pool.Pool } = {}
local spawner: ObstacleSpawner.ObstacleSpawner
local activeRoot: Folder
local initialised = false

local ChunkManager = {}
ChunkManager.__index = ChunkManager

export type ChunkManager = typeof(setmetatable(
	{} :: {
		_origin: Vector3,
		_rng: Random,
		_folder: Folder,
		_active: { ActiveChunk },
		_recent: { string }, -- names of the last few templates used
		_placedCount: number, -- chunks placed this run (for SafeChunks)
		_trackState: ObstacleSpawner.TrackState,
	},
	ChunkManager
))

-- Call once at server start, before creating any ChunkManager.
function ChunkManager.Init(loadedTemplates: { TerrainChunk.TemplateInfo })
	assert(not initialised, "ChunkManager.Init called twice")
	initialised = true
	templates = loadedTemplates

	local holding = Instance.new("Folder")
	holding.Name = "Pooled"
	holding.Parent = workspace

	activeRoot = Instance.new("Folder")
	activeRoot.Name = "Tracks"
	activeRoot.Parent = workspace

	spawner = ObstacleSpawner.new(holding)
	for _, template in templates do
		chunkPools[template.Name] = Pool.new(`Chunk_{template.Name}`, function()
			return template.Model:Clone()
		end, holding, ChunkConfig.HoldingCFrame)
	end
end

function ChunkManager.GetSpawner(): ObstacleSpawner.ObstacleSpawner
	return spawner
end

-- origin: world position of the track start, at road level. Tracks are
-- straight and run toward -Z from here.
function ChunkManager.new(name: string, origin: Vector3, rng: Random?): ChunkManager
	assert(initialised, "ChunkManager.Init must be called first")
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = activeRoot
	return setmetatable({
		_origin = origin,
		_rng = rng or Random.new(),
		_folder = folder,
		_active = {},
		_recent = {},
		_placedCount = 0,
		_trackState = ObstacleSpawner.NewTrackState(),
	}, ChunkManager)
end

-- Template choice ----------------------------------------------------------------
-- Weighted random, with templates used in the last RecentHistory chunks
-- multiplied by RepeatPenalty. Penalised, not banned, so a config with only
-- one or two templates still works.
function ChunkManager._pickTemplate(self: ChunkManager): TerrainChunk.TemplateInfo
	local total = 0
	local weights = table.create(#templates, 0)
	for i, template in templates do
		local w = template.Weight
		if table.find(self._recent, template.Name) then
			w *= ChunkConfig.RepeatPenalty
		end
		weights[i] = w
		total += w
	end

	local roll = self._rng:NextNumber() * total
	local chosen = templates[#templates]
	for i, w in weights do
		roll -= w
		if roll <= 0 then
			chosen = templates[i]
			break
		end
	end

	table.insert(self._recent, chosen.Name)
	while #self._recent > ChunkConfig.RecentHistory do
		table.remove(self._recent, 1)
	end
	return chosen
end

-- Spawning -----------------------------------------------------------------------
function ChunkManager._spawnNext(self: ChunkManager)
	local template = self:_pickTemplate()
	local model = chunkPools[template.Name]:Acquire() :: Model

	local previous = self._active[#self._active]
	local startDistance: number
	local startCFrame: CFrame
	if previous then
		-- Join onto the previous chunk's EndMarker (position only; see header).
		local endMarker = previous.Model:FindFirstChild("EndMarker") :: BasePart
		startCFrame = CFrame.new(endMarker.Position)
		startDistance = previous.EndDistance
	else
		startCFrame = CFrame.new(self._origin)
		startDistance = 0
	end

	-- PivotTo moves the Model so its PrimaryPart (Root, at the chunk start)
	-- lands exactly on startCFrame.
	model:PivotTo(startCFrame)
	model.Parent = self._folder

	-- Cross-check: the world position we just used and the distance we are
	-- about to record must describe the same point. If they drift apart,
	-- collision would be tested against the wrong place.
	local expected = self._origin - Vector3.zAxis * startDistance
	if (startCFrame.Position - expected).Magnitude > PLACEMENT_TOLERANCE then
		warn(
			`[ChunkManager] {self._folder.Name}: chunk {template.Name} placed off-track by {(
				startCFrame.Position - expected
			).Magnitude} studs`
		)
	end

	local chunk: ActiveChunk = {
		Template = template,
		Model = model,
		StartDistance = startDistance,
		EndDistance = startDistance + template.Length,
		Hazards = {},
		Coins = {},
	}
	table.insert(self._active, chunk)
	self._placedCount += 1

	if self._placedCount > ChunkConfig.SafeChunks then
		-- Difficulty is judged at the chunk's start, i.e. how far the runner
		-- will have gone when they reach it, not where they are now.
		local difficulty = ChunkConfig.DifficultyAt(startDistance)
		spawner:Populate(chunk, template, difficulty, self._trackState, self._rng)
	end
end

-- Despawning ---------------------------------------------------------------------
function ChunkManager._releaseOldest(self: ChunkManager)
	local chunk = table.remove(self._active, 1)
	if not chunk then
		return
	end
	-- Order matters: obstacles/coins out first, then the chunk itself.
	spawner:Clear(chunk)
	chunkPools[chunk.Template.Name]:Release(chunk.Model)
end

-- Call every frame with the runner's current distance.
function ChunkManager.Update(self: ChunkManager, runnerDistance: number)
	-- 1. Spawn ahead. `furthest` is where the road currently ends.
	local lookahead = ChunkConfig.ChunksAhead * ChunkConfig.ChunkLength
	while true do
		local newest = self._active[#self._active]
		local furthest = if newest then newest.EndDistance else 0
		if newest and furthest >= runnerDistance + lookahead then
			break
		end
		self:_spawnNext()
	end

	-- 2. Despawn behind, oldest first. Never removes the newest chunk, since
	-- after step 1 the newest chunk always ends ahead of the runner.
	while #self._active > 1 and self._active[1].EndDistance < runnerDistance - ChunkConfig.DespawnBehind do
		self:_releaseOldest()
	end
end

-- Chunks whose span (plus a small margin) overlaps [fromDistance, toDistance].
-- Only a handful of chunks are ever active, so a linear scan is fine.
function ChunkManager.ChunksBetween(self: ChunkManager, fromDistance: number, toDistance: number): { ActiveChunk }
	local result = {}
	for _, chunk in self._active do
		if chunk.EndDistance + QUERY_MARGIN >= fromDistance and chunk.StartDistance - QUERY_MARGIN <= toDistance then
			table.insert(result, chunk)
		end
	end
	return result
end

-- World position of a point given in track coordinates.
function ChunkManager.ToWorld(self: ChunkManager, distance: number, lateral: number, height: number): Vector3
	return self._origin + Vector3.new(lateral, height, -distance)
end

-- Returns every chunk to the pool, ready for a fresh run on the same track.
function ChunkManager.Reset(self: ChunkManager)
	while #self._active > 0 do
		self:_releaseOldest()
	end
	table.clear(self._recent)
	self._placedCount = 0
	self._trackState = ObstacleSpawner.NewTrackState()
end

function ChunkManager.Destroy(self: ChunkManager)
	self:Reset()
	self._folder:Destroy()
end

return ChunkManager
