--!strict
--[[
	PlayerRunner
	Server-authoritative runner simulation, one per player.

	The server owns everything that matters: distance, lane, jump, collisions,
	coins and score. The character's HumanoidRootPart is anchored and the
	server sets its CFrame every frame, so nothing the client does to its
	character position has any effect on the game.

	The client may only send two requests:
	  Remotes.LaneChange(direction: -1 | 1, seq: number)
	  Remotes.Jump()
	Both are type-checked and rate limited. LaneChange carries an increasing
	sequence number that the server echoes back in the LaneSeq attribute, so
	the client's prediction knows which of its inputs have been applied.

	State published to the client as attributes on the Player:
	  RunState   "Waiting" | "Running" | "Crashed"
	  RunId      increments on every new run (client resets its prediction)
	  TrackOrigin, RootHeight  constants for the current run
	  Distance, Lateral, Lane, LaneSeq, RunCoins
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ChunkConfig = require(script.Parent.ChunkConfig)
local ChunkManager = require(script.Parent.ChunkManager)
local RunnerConfig = require(ReplicatedStorage.Shared.RunnerConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LaneChangeRemote = Remotes:WaitForChild("LaneChange") :: RemoteEvent
local JumpRemote = Remotes:WaitForChild("Jump") :: RemoteEvent
local RunEventRemote = Remotes:WaitForChild("RunEvent") :: RemoteEvent

-- Hitboxes are shrunk by this factor, so clipping the corner of an
-- obstacle is forgiven.
local HAZARD_FORGIVENESS = 0.85
-- Longest step we simulate in one go; bigger frame gaps are split up.
local MAX_STEP = 1 / 30
-- Request rate limit (token bucket shared by lane and jump requests).
local BUCKET_SIZE = 10
local BUCKET_REFILL = 12 -- tokens per second

type Runner = {
	Player: Player,
	Slot: number,
	Track: ChunkManager.ChunkManager,
	State: "Waiting" | "Running" | "Crashed",
	RunId: number,
	Root: BasePart?,
	RootHeight: number,

	Distance: number,
	Lane: number,
	Lateral: number,
	LaneSeq: number,
	Airborne: boolean,
	JumpElapsed: number,
	JumpBufferedAt: number?, -- os.clock() of a jump pressed just before landing
	RunCoins: number,

	Tokens: number,
	TokensUpdatedAt: number,

	Best: IntValue,
	Coins: IntValue,
}

local runners: { [Player]: Runner } = {}
local usedSlots: { [number]: boolean } = {}

local PlayerRunner = {}

-- Helpers --------------------------------------------------------------------------
local function claimSlot(): number
	local slot = 0
	while usedSlots[slot] do
		slot += 1
	end
	usedSlots[slot] = true
	return slot
end

local function takeToken(runner: Runner): boolean
	local now = os.clock()
	runner.Tokens = math.min(BUCKET_SIZE, runner.Tokens + (now - runner.TokensUpdatedAt) * BUCKET_REFILL)
	runner.TokensUpdatedAt = now
	if runner.Tokens < 1 then
		return false
	end
	runner.Tokens -= 1
	return true
end

local function publish(runner: Runner)
	local player = runner.Player
	player:SetAttribute("Distance", runner.Distance)
	player:SetAttribute("Lateral", runner.Lateral)
	player:SetAttribute("Lane", runner.Lane)
	player:SetAttribute("LaneSeq", runner.LaneSeq)
	player:SetAttribute("RunCoins", runner.RunCoins)
end

local function setState(runner: Runner, state: "Waiting" | "Running" | "Crashed")
	runner.State = state
	runner.Player:SetAttribute("RunState", state)
end

local function placeCharacter(runner: Runner, height: number)
	local root = runner.Root
	if root and root.Parent then
		-- Facing -Z is the default orientation of CFrame.new, which is the
		-- direction of travel.
		root.CFrame = CFrame.new(runner.Track:ToWorld(runner.Distance, runner.Lateral, height + runner.RootHeight))
	end
end

-- Distance from the road to the centre of the HumanoidRootPart.
local function rootHeightOf(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return 3 -- R6 legs are 2 studs, root is 2 tall
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

local function startJump(runner: Runner)
	runner.Airborne = true
	runner.JumpElapsed = 0
	runner.JumpBufferedAt = nil
end

-- Runs ---------------------------------------------------------------------------
local function startRun(runner: Runner)
	local character = runner.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root and root:IsA("BasePart")) then
		return
	end

	-- Anchor the character: from now on only the server moves it.
	root.Anchored = true
	humanoid.WalkSpeed = 0
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	runner.Root = root
	runner.RootHeight = rootHeightOf(humanoid, root)

	runner.Track:Reset()
	runner.RunId += 1
	runner.Distance = RunnerConfig.StartDistance
	runner.Lane = RunnerConfig.StartLane
	runner.Lateral = RunnerConfig.LaneOffset(runner.Lane)
	runner.Airborne = false
	runner.JumpElapsed = 0
	runner.JumpBufferedAt = nil
	runner.RunCoins = 0
	runner.Track:Update(runner.Distance)

	local player = runner.Player
	player:SetAttribute("TrackOrigin", runner.Track:ToWorld(0, 0, 0))
	player:SetAttribute("RootHeight", runner.RootHeight)
	player:SetAttribute("RunId", runner.RunId)
	publish(runner)
	placeCharacter(runner, 0)
	setState(runner, "Running")
end

local function crash(runner: Runner, cause: string)
	setState(runner, "Crashed")
	local score = math.floor(runner.Distance)
	if score > runner.Best.Value then
		runner.Best.Value = score
	end
	RunEventRemote:FireClient(runner.Player, "Crashed", {
		Distance = score,
		Coins = runner.RunCoins,
		Best = runner.Best.Value,
		Cause = cause,
	})

	local runId = runner.RunId
	task.delay(RunnerConfig.RestartDelay, function()
		-- Only restart if nothing else (respawn, leaving) happened meanwhile.
		if runners[runner.Player] == runner and runner.RunId == runId and runner.State == "Crashed" then
			startRun(runner)
		end
	end)
end

-- Collision ----------------------------------------------------------------------
-- Everything is axis-aligned boxes in track coordinates. The distance range
-- covers the whole path travelled this step (fromDistance -> runner.Distance)
-- so a fast runner cannot skip through a thin obstacle between frames.
local function checkHazards(runner: Runner, fromDistance: number, height: number): string?
	local halfWidth = RunnerConfig.HitboxWidth / 2
	local minD = fromDistance - RunnerConfig.HitboxDepth / 2
	local maxD = runner.Distance + RunnerConfig.HitboxDepth / 2

	for _, chunk in runner.Track:ChunksBetween(minD, maxD) do
		for _, hazard in chunk.Hazards do
			local halfZ = hazard.Size.Z / 2 * HAZARD_FORGIVENESS
			local halfX = hazard.Size.X / 2 * HAZARD_FORGIVENESS
			local overlapsD = maxD >= hazard.Distance - halfZ and minD <= hazard.Distance + halfZ
			local overlapsX = math.abs(runner.Lateral - hazard.Lateral) < halfWidth + halfX
			if overlapsD and overlapsX then
				-- Feet above the top of a jumpable obstacle = cleared it.
				if not hazard.Jumpable or height < hazard.Size.Y * HAZARD_FORGIVENESS then
					return hazard.Kind
				end
			end
		end
	end
	return nil
end

local function collectCoins(runner: Runner, fromDistance: number, height: number)
	local reach = ChunkConfig.Coins.PickupRadius
	local minD = fromDistance - RunnerConfig.HitboxDepth / 2 - reach
	local maxD = runner.Distance + RunnerConfig.HitboxDepth / 2 + reach
	local halfWidth = RunnerConfig.HitboxWidth / 2 + reach
	local spawner = ChunkManager.GetSpawner()

	for _, chunk in runner.Track:ChunksBetween(minD, maxD) do
		for _, coin in chunk.Coins do
			if
				not coin.Collected
				and coin.Distance >= minD
				and coin.Distance <= maxD
				and math.abs(coin.Lateral - runner.Lateral) <= halfWidth
				and coin.Height >= height - reach
				and coin.Height <= height + RunnerConfig.HitboxHeight + reach
			then
				spawner:CollectCoin(coin)
				runner.RunCoins += ChunkConfig.Coins.Value
				runner.Coins.Value += ChunkConfig.Coins.Value
			end
		end
	end
end

-- Simulation ---------------------------------------------------------------------
local function step(runner: Runner, dt: number)
	local fromDistance = runner.Distance
	runner.Distance += RunnerConfig.SpeedAt(runner.Distance) * dt
	runner.Lateral =
		RunnerConfig.MoveToward(runner.Lateral, RunnerConfig.LaneOffset(runner.Lane), RunnerConfig.LaneChangeSpeed * dt)

	if runner.Airborne then
		runner.JumpElapsed += dt
		if runner.JumpElapsed >= RunnerConfig.AirTime() then
			runner.Airborne = false
			runner.JumpElapsed = 0
			-- onJump only buffers a press made within JumpBufferTime of landing.
			if runner.JumpBufferedAt then
				startJump(runner)
			end
		end
	end
	local height = if runner.Airborne then RunnerConfig.JumpHeight(runner.JumpElapsed) else 0

	runner.Track:Update(runner.Distance)

	local hit = checkHazards(runner, fromDistance, height)
	if hit then
		placeCharacter(runner, height)
		publish(runner)
		crash(runner, hit)
		return
	end
	collectCoins(runner, fromDistance, height)
	placeCharacter(runner, height)
end

local function onHeartbeat(dt: number)
	for _, runner in runners do
		if runner.State ~= "Running" then
			continue
		end
		if not (runner.Root and runner.Root.Parent) then
			setState(runner, "Waiting")
			continue
		end
		-- Split long frames so the lane/jump maths stays accurate.
		local remaining = math.min(dt, 0.25)
		while remaining > 0 and runner.State == "Running" do
			local slice = math.min(remaining, MAX_STEP)
			step(runner, slice)
			remaining -= slice
		end
		if runner.State == "Running" then
			publish(runner)
		end
	end
end

-- Client requests ----------------------------------------------------------------
local function onLaneChange(player: Player, direction: unknown, seq: unknown)
	local runner = runners[player]
	if not runner then
		return
	end
	-- Validate types and values; never trust the client.
	if type(direction) ~= "number" or (direction ~= 1 and direction ~= -1) then
		return
	end
	if type(seq) ~= "number" or seq ~= seq or seq % 1 ~= 0 or seq <= runner.LaneSeq then
		return
	end

	-- Always acknowledge a well-formed request, even one we refuse to act on,
	-- so the client's prediction stops counting it as pending.
	runner.LaneSeq = seq
	if runner.State == "Running" and takeToken(runner) then
		runner.Lane = math.clamp(runner.Lane + direction, 1, RunnerConfig.LaneCount)
	end
	player:SetAttribute("Lane", runner.Lane)
	player:SetAttribute("LaneSeq", runner.LaneSeq)
end

local function onJump(player: Player)
	local runner = runners[player]
	if not runner or runner.State ~= "Running" or not takeToken(runner) then
		return
	end
	if not runner.Airborne then
		startJump(runner)
	elseif RunnerConfig.AirTime() - runner.JumpElapsed <= RunnerConfig.JumpBufferTime then
		-- Pressed just before landing: jump again the moment we touch down.
		runner.JumpBufferedAt = os.clock()
	end
end

-- Players ------------------------------------------------------------------------
local function makeLeaderstats(player: Player): (IntValue, IntValue)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local best = Instance.new("IntValue")
	best.Name = "Best"
	best.Parent = leaderstats
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = leaderstats
	leaderstats.Parent = player
	return best, coins
end

local function onPlayerAdded(player: Player)
	local slot = claimSlot()
	local origin = Vector3.new(slot * ChunkConfig.TrackSpacing, 0, 0)
	local best, coins = makeLeaderstats(player)

	local runner: Runner = {
		Player = player,
		Slot = slot,
		Track = ChunkManager.new(`Track_{player.UserId}`, origin),
		State = "Waiting",
		RunId = 0,
		Root = nil,
		RootHeight = 3,
		Distance = 0,
		Lane = RunnerConfig.StartLane,
		Lateral = RunnerConfig.LaneOffset(RunnerConfig.StartLane),
		LaneSeq = 0,
		Airborne = false,
		JumpElapsed = 0,
		JumpBufferedAt = nil,
		RunCoins = 0,
		Tokens = BUCKET_SIZE,
		TokensUpdatedAt = os.clock(),
		Best = best,
		Coins = coins,
	}
	runners[player] = runner
	setState(runner, "Waiting")

	local function onCharacter(character: Model)
		character:WaitForChild("HumanoidRootPart", 10)
		character:WaitForChild("Humanoid", 10)
		if runners[player] ~= runner or player.Character ~= character then
			return
		end
		startRun(runner)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Died:Connect(function()
				if runner.State == "Running" then
					-- Respawning starts the next run via CharacterAdded.
					setState(runner, "Crashed")
				end
			end)
		end
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local runner = runners[player]
	if not runner then
		return
	end
	runners[player] = nil
	runner.Track:Destroy()
	usedSlots[runner.Slot] = nil
end

function PlayerRunner.Start()
	LaneChangeRemote.OnServerEvent:Connect(onLaneChange)
	JumpRemote.OnServerEvent:Connect(onJump)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	RunService.Heartbeat:Connect(onHeartbeat)
end

return PlayerRunner
