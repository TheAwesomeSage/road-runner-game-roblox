--!strict
--[[
	RunnerConfig
	Movement tuning shared by the server (authoritative simulation) and the
	client (prediction/visuals). Both sides run the same maths from this
	module, so keeping it in one place stops them drifting apart.

	Track coordinates used everywhere in this project:
	  distance  - studs travelled along the track (forward is world -Z)
	  lateral   - studs left/right of the track centre line (right is +X)
	  height    - studs above the road surface
]]

local RunnerConfig = {}

-- Lanes ---------------------------------------------------------------------
RunnerConfig.LaneCount = 3
RunnerConfig.LaneWidth = 8 -- studs between lane centres
RunnerConfig.StartLane = 2 -- 1 = leftmost
-- Lateral speed while changing lanes (studs/s). 8 studs at 70 ≈ 0.11s.
RunnerConfig.LaneChangeSpeed = 70

-- Forward speed ---------------------------------------------------------------
RunnerConfig.BaseSpeed = 40 -- studs/s at the start of a run
RunnerConfig.MaxSpeed = 75 -- hard cap
RunnerConfig.SpeedRampDistance = 6000 -- distance at which MaxSpeed is reached

-- Jump ------------------------------------------------------------------------
RunnerConfig.JumpVelocity = 45
RunnerConfig.Gravity = 150
-- A jump pressed this long before landing is remembered and fires on landing.
RunnerConfig.JumpBufferTime = 0.15

-- Player hitbox (studs). Kept slightly smaller than the visual character so
-- near misses feel fair.
RunnerConfig.HitboxWidth = 2.4
RunnerConfig.HitboxDepth = 2
RunnerConfig.HitboxHeight = 5

RunnerConfig.StartDistance = 5 -- where the runner stands on the first chunk
RunnerConfig.RestartDelay = 3 -- seconds between crashing and a new run

-- Lateral offset of a lane's centre from the track centre line.
function RunnerConfig.LaneOffset(lane: number): number
	return (lane - (RunnerConfig.LaneCount + 1) / 2) * RunnerConfig.LaneWidth
end

-- Forward speed at a given distance: linear ramp from BaseSpeed, capped.
function RunnerConfig.SpeedAt(distance: number): number
	local alpha = math.clamp(distance / RunnerConfig.SpeedRampDistance, 0, 1)
	return RunnerConfig.BaseSpeed + (RunnerConfig.MaxSpeed - RunnerConfig.BaseSpeed) * alpha
end

-- Total time spent in the air for one jump.
function RunnerConfig.AirTime(): number
	return 2 * RunnerConfig.JumpVelocity / RunnerConfig.Gravity
end

-- Height of the feet above the road `elapsed` seconds into a jump.
function RunnerConfig.JumpHeight(elapsed: number): number
	if elapsed <= 0 or elapsed >= RunnerConfig.AirTime() then
		return 0
	end
	return RunnerConfig.JumpVelocity * elapsed - 0.5 * RunnerConfig.Gravity * elapsed * elapsed
end

-- Move `current` toward `target` by at most `maxStep`.
function RunnerConfig.MoveToward(current: number, target: number, maxStep: number): number
	local delta = target - current
	if math.abs(delta) <= maxStep then
		return target
	end
	return current + math.sign(delta) * maxStep
end

return RunnerConfig
