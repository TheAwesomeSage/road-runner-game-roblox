--!strict
--[[
	RunnerInput
	Client side of the runner: key bindings, smooth visuals and the camera.

	The server is authoritative (see Server/PlayerRunner). This script only
	REQUESTS lane changes and jumps, and predicts their result locally so the
	game feels instant:

	  * Forward distance is simulated locally with the same speed curve as
	    the server, and gently pulled toward the server's Distance.
	  * Lane changes are applied to a predicted lane immediately. Each request
	    has a sequence number; when the server's LaneSeq catches up, those
	    requests are dropped from the pending list and the prediction becomes
	    server lane + whatever is still pending.
	  * Jumps are predicted locally; the server validates its own copy.

	The predicted position is written to the local character every frame,
	just before rendering. The server's replicated CFrame lands between
	frames and is overwritten before it is ever drawn.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RunnerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RunnerConfig"))
local RunnerHud = require(script.Parent:WaitForChild("RunnerHud"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local LaneChangeRemote = Remotes:WaitForChild("LaneChange") :: RemoteEvent
local JumpRemote = Remotes:WaitForChild("Jump") :: RemoteEvent
local RunEventRemote = Remotes:WaitForChild("RunEvent") :: RemoteEvent

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local hud = RunnerHud.new(player)

-- Tuning for visuals only (gameplay tuning lives in RunnerConfig).
local DISTANCE_CORRECTION = 6 -- how fast prediction is pulled to the server (1/s)
local SNAP_DISTANCE = 12 -- errors bigger than this snap instead of blending
local CAMERA_BACK = 17
local CAMERA_UP = 10
local CAMERA_LOOK_AHEAD = 25
local CAMERA_FOLLOW_X = 0.7 -- how much the camera follows lane changes (0..1)
local COIN_SPIN_SPEED = 3 -- radians per second
local COIN_SPIN_RANGE = 250

local RUN_ANIMATIONS = {
	[Enum.HumanoidRigType.R15] = "rbxassetid://913376220",
	[Enum.HumanoidRigType.R6] = "rbxassetid://180426354",
}

-- Stop the default WASD/jump controls: this game only has lanes and jump.
task.spawn(function()
	local ok, playerModule = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
	end)
	if ok and playerModule then
		playerModule:GetControls():Disable()
	end
end)

-- Prediction state ---------------------------------------------------------------
type PendingInput = { Seq: number, Direction: number }

local predicted = {
	RunId = 0,
	Running = false,
	Distance = 0,
	Lateral = 0,
	Airborne = false,
	JumpElapsed = 0,
	JumpBuffered = false,
	CameraX = 0,
}
local pending: { PendingInput } = {}
local nextSeq = 0

local serverDistance = 0
local serverDistanceAt = os.clock()

local function attr(name: string, default: any): any
	local value = player:GetAttribute(name)
	if value == nil then
		return default
	end
	return value
end

-- Server lane with every not-yet-acknowledged request replayed on top.
local function predictedLane(): number
	local lane = attr("Lane", RunnerConfig.StartLane)
	for _, input in pending do
		lane = math.clamp(lane + input.Direction, 1, RunnerConfig.LaneCount)
	end
	return lane
end

local function resetPrediction()
	predicted.RunId = attr("RunId", 0)
	predicted.Distance = attr("Distance", 0)
	predicted.Lateral = attr("Lateral", 0)
	predicted.Airborne = false
	predicted.JumpElapsed = 0
	predicted.JumpBuffered = false
	predicted.CameraX = predicted.Lateral * CAMERA_FOLLOW_X
	serverDistance = predicted.Distance
	serverDistanceAt = os.clock()
	table.clear(pending)
	-- The server's LaneSeq carries on across runs, so ours must too.
	nextSeq = math.max(nextSeq, attr("LaneSeq", 0))
end

player:GetAttributeChangedSignal("Distance"):Connect(function()
	serverDistance = attr("Distance", 0)
	serverDistanceAt = os.clock()
end)

player:GetAttributeChangedSignal("LaneSeq"):Connect(function()
	local acked = attr("LaneSeq", 0)
	while pending[1] and pending[1].Seq <= acked do
		table.remove(pending, 1)
	end
end)

player:GetAttributeChangedSignal("RunId"):Connect(function()
	resetPrediction()
	hud:HideCrash()
end)

player:GetAttributeChangedSignal("RunState"):Connect(function()
	predicted.Running = attr("RunState", "") == "Running"
end)
predicted.Running = attr("RunState", "") == "Running"
if predicted.Running then
	resetPrediction()
end

RunEventRemote.OnClientEvent:Connect(function(kind: string, data: any)
	if kind == "Crashed" and type(data) == "table" then
		predicted.Running = false
		hud:ShowCrash(data.Distance, data.Coins, data.Best, RunnerConfig.RestartDelay)
	end
end)

-- Input --------------------------------------------------------------------------
local function requestLane(direction: number)
	if not predicted.Running then
		return
	end
	local target = predictedLane() + direction
	if target < 1 or target > RunnerConfig.LaneCount then
		return -- already in the outermost lane; don't bother the server
	end
	nextSeq += 1
	table.insert(pending, { Seq = nextSeq, Direction = direction })
	LaneChangeRemote:FireServer(direction, nextSeq)
end

local function requestJump()
	if not predicted.Running then
		return
	end
	if not predicted.Airborne then
		predicted.Airborne = true
		predicted.JumpElapsed = 0
	elseif RunnerConfig.AirTime() - predicted.JumpElapsed <= RunnerConfig.JumpBufferTime then
		predicted.JumpBuffered = true
	end
	JumpRemote:FireServer()
end

local function onAction(actionName: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if actionName == "RunnerLeft" then
		requestLane(-1)
	elseif actionName == "RunnerRight" then
		requestLane(1)
	elseif actionName == "RunnerJump" then
		requestJump()
	end
	return Enum.ContextActionResult.Sink
end

-- High priority so these win over the default character controls; the last
-- argument adds on-screen buttons for touch devices.
local PRIORITY = Enum.ContextActionPriority.High.Value
ContextActionService:BindActionAtPriority("RunnerLeft", onAction, true, PRIORITY, Enum.KeyCode.A, Enum.KeyCode.Left)
ContextActionService:BindActionAtPriority("RunnerRight", onAction, true, PRIORITY, Enum.KeyCode.D, Enum.KeyCode.Right)
ContextActionService:BindActionAtPriority("RunnerJump", onAction, true, PRIORITY, Enum.KeyCode.Space, Enum.KeyCode.Up)
ContextActionService:SetTitle("RunnerLeft", "<")
ContextActionService:SetTitle("RunnerRight", ">")
ContextActionService:SetTitle("RunnerJump", "Jump")

-- Run animation ------------------------------------------------------------------
local runTrack: AnimationTrack? = nil

local function onCharacter(character: Model)
	runTrack = nil
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	local animator = humanoid:WaitForChild("Animator", 10) :: Animator?
	local id = RUN_ANIMATIONS[humanoid.RigType]
	if animator and id then
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local track = animator:LoadAnimation(animation)
		track.Priority = Enum.AnimationPriority.Movement
		track.Looped = true
		runTrack = track
	end
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end

-- Coin spin (purely local decoration) ---------------------------------------------
local coins: { [BasePart]: true } = {}
local function trackCoin(instance: Instance)
	if instance:IsA("BasePart") then
		coins[instance] = true
	end
end
for _, coin in CollectionService:GetTagged("RunnerCoin") do
	trackCoin(coin)
end
CollectionService:GetInstanceAddedSignal("RunnerCoin"):Connect(trackCoin)
CollectionService:GetInstanceRemovedSignal("RunnerCoin"):Connect(function(instance)
	coins[instance :: BasePart] = nil
end)

local function spinCoins(dt: number)
	local cameraPosition = camera.CFrame.Position
	local spin = CFrame.Angles(0, COIN_SPIN_SPEED * dt, 0)
	for coin in coins do
		if (coin.Position - cameraPosition).Magnitude < COIN_SPIN_RANGE then
			coin.CFrame = CFrame.new(coin.Position) * spin * coin.CFrame.Rotation
		end
	end
end

-- Per-frame update ---------------------------------------------------------------
local function simulate(dt: number)
	if predicted.Running then
		-- Forward: local simulation, blended toward the server.
		predicted.Distance += RunnerConfig.SpeedAt(predicted.Distance) * dt
		local sinceUpdate = math.min(os.clock() - serverDistanceAt, 0.3)
		local target = serverDistance + RunnerConfig.SpeedAt(serverDistance) * sinceUpdate
		local err = target - predicted.Distance
		if math.abs(err) > SNAP_DISTANCE then
			predicted.Distance = target
		else
			predicted.Distance += err * math.min(1, dt * DISTANCE_CORRECTION)
		end

		-- Sideways: the same fixed-speed slide the server uses.
		predicted.Lateral = RunnerConfig.MoveToward(
			predicted.Lateral,
			RunnerConfig.LaneOffset(predictedLane()),
			RunnerConfig.LaneChangeSpeed * dt
		)

		if predicted.Airborne then
			predicted.JumpElapsed += dt
			if predicted.JumpElapsed >= RunnerConfig.AirTime() then
				predicted.Airborne = predicted.JumpBuffered
				predicted.JumpElapsed = 0
				predicted.JumpBuffered = false
			end
		end
	else
		-- Not running (crashed / waiting): settle on the server's values.
		local alpha = math.min(1, dt * 10)
		predicted.Distance += (attr("Distance", predicted.Distance) - predicted.Distance) * alpha
		predicted.Lateral += (attr("Lateral", predicted.Lateral) - predicted.Lateral) * alpha
		predicted.Airborne = false
	end
end

local function render(dt: number)
	local origin = player:GetAttribute("TrackOrigin")
	if typeof(origin) ~= "Vector3" then
		return -- no run has started yet; leave the default camera alone
	end

	simulate(dt)
	spinCoins(dt)

	local height = if predicted.Airborne then RunnerConfig.JumpHeight(predicted.JumpElapsed) else 0
	local groundPoint = origin + Vector3.new(predicted.Lateral, 0, -predicted.Distance)

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and root.Anchored then
		root.CFrame = CFrame.new(groundPoint + Vector3.new(0, height + attr("RootHeight", 3), 0))
	end

	if runTrack then
		if predicted.Running and not predicted.Airborne then
			if not runTrack.IsPlaying then
				runTrack:Play(0.1)
			end
			runTrack:AdjustSpeed(RunnerConfig.SpeedAt(predicted.Distance) / RunnerConfig.BaseSpeed)
		elseif runTrack.IsPlaying then
			runTrack:Stop(0.1)
		end
	end

	-- Camera: behind and above the runner, following lane changes partly and
	-- smoothly, and ignoring jumps so the view stays steady.
	camera.CameraType = Enum.CameraType.Scriptable
	predicted.CameraX += (predicted.Lateral * CAMERA_FOLLOW_X - predicted.CameraX) * math.min(1, dt * 8)
	local base = Vector3.new(origin.X + predicted.CameraX, origin.Y, groundPoint.Z)
	local eye = base + Vector3.new(0, CAMERA_UP, CAMERA_BACK)
	local focus = base + Vector3.new(0, 3, -CAMERA_LOOK_AHEAD)
	camera.CFrame = CFrame.lookAt(eye, focus)

	local speedAlpha = (RunnerConfig.SpeedAt(predicted.Distance) - RunnerConfig.BaseSpeed)
		/ (RunnerConfig.MaxSpeed - RunnerConfig.BaseSpeed)
	camera.FieldOfView = 70 + 15 * speedAlpha

	hud:SetStats(predicted.Distance, attr("RunCoins", 0))
end

RunService:BindToRenderStep("RunnerRender", Enum.RenderPriority.Camera.Value + 1, render)
