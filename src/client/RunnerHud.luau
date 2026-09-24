--!strict
--[[
	RunnerHud
	Distance / coin counters and the crash panel. Pure display: it never
	decides anything about the game.
]]

local RunnerHud = {}
RunnerHud.__index = RunnerHud

export type RunnerHud = typeof(setmetatable(
	{} :: {
		_distance: TextLabel,
		_coins: TextLabel,
		_panel: Frame,
		_panelText: TextLabel,
	},
	RunnerHud
))

local function label(parent: Instance, size: UDim2, position: UDim2, textSize: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = position
	l.Font = Enum.Font.FredokaOne
	l.TextSize = textSize
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.4
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

function RunnerHud.new(player: Player): RunnerHud
	local gui = Instance.new("ScreenGui")
	gui.Name = "RunnerHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true

	local distance = label(gui, UDim2.fromOffset(300, 48), UDim2.fromOffset(20, 50), 40)
	local coins = label(gui, UDim2.fromOffset(300, 36), UDim2.fromOffset(20, 96), 28)
	coins.TextColor3 = Color3.fromRGB(255, 214, 70)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.45)
	panel.Size = UDim2.fromOffset(380, 200)
	panel.BackgroundColor3 = Color3.fromRGB(25, 28, 36)
	panel.BackgroundTransparency = 0.2
	panel.Visible = false
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = panel

	local panelText = label(panel, UDim2.fromScale(1, 1), UDim2.new(), 28)
	panelText.TextXAlignment = Enum.TextXAlignment.Center
	panelText.RichText = true

	gui.Parent = player:WaitForChild("PlayerGui")

	return setmetatable({
		_distance = distance,
		_coins = coins,
		_panel = panel,
		_panelText = panelText,
	}, RunnerHud)
end

function RunnerHud.SetStats(self: RunnerHud, distance: number, coins: number)
	self._distance.Text = `{math.floor(distance)} m`
	self._coins.Text = `Coins: {coins}`
end

function RunnerHud.ShowCrash(self: RunnerHud, distance: number, coins: number, best: number, restartIn: number)
	self._panelText.Text =
		`<b>CRASHED!</b>\n{distance} m  ·  {coins} coins\nBest: {best} m\n<font size="20">Next run in {restartIn}s</font>`
	self._panel.Visible = true
end

function RunnerHud.HideCrash(self: RunnerHud)
	self._panel.Visible = false
end

return RunnerHud
