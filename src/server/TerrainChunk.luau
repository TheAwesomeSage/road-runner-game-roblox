--!strict
--[[
	TerrainChunk
	Turns the data in ChunkConfig into chunk template Models, and reads back
	where each template's spawn points are.

	Every chunk template Model has:
	  Root          invisible Part at the chunk START, road level. It is the
	                Model's PrimaryPart, so PivotTo(cf) puts the start at cf.
	  EndMarker     invisible Part at the chunk END. The next chunk is pivoted
	                onto this part's CFrame, so chunks always join exactly.
	  SpawnPoints   invisible Parts tagged "ObstacleSpawn" (attributes Lane,
	                Row) and "CoinSpawn" (attributes Lane, Run).
	  Scenery       whatever the theme builds.

	Templates are generated at startup into ServerStorage.ChunkTemplates.
	If a Model with the same name is already there (e.g. built by hand in
	Studio), it is used as-is instead, as long as it has Root and EndMarker.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ChunkConfig = require(script.Parent.ChunkConfig)
local RunnerConfig = require(ReplicatedStorage.Shared.RunnerConfig)

local TerrainChunk = {}

TerrainChunk.OBSTACLE_TAG = "ObstacleSpawn"
TerrainChunk.COIN_TAG = "CoinSpawn"

-- The theme module selected in ChunkConfig. Everything visual goes through it.
local themeModule = script.Parent.Themes:FindFirstChild(ChunkConfig.Theme)
assert(themeModule and themeModule:IsA("ModuleScript"), `Theme "{ChunkConfig.Theme}" not found in Server/Themes`)
TerrainChunk.Theme = (require :: any)(themeModule)

-- Chunk dimensions handed to the theme.
TerrainChunk.Layout = {
	Length = ChunkConfig.ChunkLength,
	RoadWidth = RunnerConfig.LaneCount * RunnerConfig.LaneWidth,
	SidewalkWidth = 8,
	LaneCount = RunnerConfig.LaneCount,
	LaneOffset = RunnerConfig.LaneOffset,
}

-- A spawn point relative to the chunk's Root. Stored as an offset so one
-- read of the template serves every pooled copy wherever it is placed.
export type SpawnPoint = { Lane: number, Offset: CFrame }
export type ObstacleRow = { Z: number, Points: { [number]: SpawnPoint } } -- keyed by lane
export type CoinRun = { [number]: { SpawnPoint } } -- lane -> points along the run
export type TemplateInfo = {
	Name: string,
	Weight: number,
	Model: Model,
	Length: number,
	Rows: { ObstacleRow },
	CoinRuns: { CoinRun },
}

local function marker(name: string, cframe: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.one
	p.CFrame = cframe
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Transparency = 1
	p.Parent = parent
	return p
end

-- Builds one template Model from its ChunkConfig entry.
local function buildTemplate(spec: ChunkConfig.Template): Model
	local length = ChunkConfig.ChunkLength
	local model = Instance.new("Model")
	model.Name = spec.Name

	local root = marker("Root", CFrame.new(), model)
	model.PrimaryPart = root
	marker("EndMarker", CFrame.new(0, 0, -length), model)

	TerrainChunk.Theme.BuildChunk(model, spec, TerrainChunk.Layout)

	local spawns = Instance.new("Folder")
	spawns.Name = "SpawnPoints"
	spawns.Parent = model

	for rowIndex, z in spec.ObstacleRows or ChunkConfig.DefaultObstacleRows do
		for lane = 1, RunnerConfig.LaneCount do
			local p = marker(TerrainChunk.OBSTACLE_TAG, CFrame.new(RunnerConfig.LaneOffset(lane), 0, -z), spawns)
			p:SetAttribute("Lane", lane)
			p:SetAttribute("Row", rowIndex)
			CollectionService:AddTag(p, TerrainChunk.OBSTACLE_TAG)
		end
	end

	for runIndex, run in spec.CoinRuns or ChunkConfig.DefaultCoinRuns do
		for z = run.From, run.To, run.Step do
			for lane = 1, RunnerConfig.LaneCount do
				local cf = CFrame.new(RunnerConfig.LaneOffset(lane), ChunkConfig.Coins.Height, -z)
				local p = marker(TerrainChunk.COIN_TAG, cf, spawns)
				p:SetAttribute("Lane", lane)
				p:SetAttribute("Run", runIndex)
				CollectionService:AddTag(p, TerrainChunk.COIN_TAG)
			end
		end
	end

	return model
end

-- Reads the tagged spawn markers of a template into offsets from its Root.
local function readTemplate(model: Model, weight: number): TemplateInfo?
	local root = model:FindFirstChild("Root")
	local endMarker = model:FindFirstChild("EndMarker")
	if not (root and root:IsA("BasePart") and endMarker and endMarker:IsA("BasePart")) then
		warn(`[TerrainChunk] template "{model.Name}" needs BaseParts named Root and EndMarker; skipped`)
		return nil
	end
	model.PrimaryPart = root

	-- Measure the length from the markers rather than trusting config, so a
	-- hand-built template of a different length still joins without gaps.
	local length = (endMarker.Position - root.Position).Magnitude
	if length < 1 then
		-- A zero-length chunk would make ChunkManager's spawn loop never finish.
		warn(`[TerrainChunk] template "{model.Name}" has EndMarker on top of Root; skipped`)
		return nil
	end

	local rowsByIndex: { [number]: ObstacleRow } = {}
	local runsByIndex: { [number]: CoinRun } = {}

	for _, d in model:GetDescendants() do
		if not d:IsA("BasePart") then
			continue
		end
		local lane = d:GetAttribute("Lane")
		if type(lane) ~= "number" then
			continue
		end
		local offset = root.CFrame:ToObjectSpace(d.CFrame)
		local point: SpawnPoint = { Lane = lane, Offset = offset }

		if CollectionService:HasTag(d, TerrainChunk.OBSTACLE_TAG) then
			local rowIndex = d:GetAttribute("Row") :: number? or 1
			local row = rowsByIndex[rowIndex]
			if not row then
				-- Offset.Z is negative (chunks extend toward -Z); store distance.
				row = { Z = -offset.Position.Z, Points = {} }
				rowsByIndex[rowIndex] = row
			end
			row.Points[lane] = point
		elseif CollectionService:HasTag(d, TerrainChunk.COIN_TAG) then
			local runIndex = d:GetAttribute("Run") :: number? or 1
			local run = runsByIndex[runIndex] or {}
			runsByIndex[runIndex] = run
			run[lane] = run[lane] or {}
			table.insert(run[lane], point)
		end
	end

	local rows = {}
	for _, row in rowsByIndex do
		table.insert(rows, row)
	end
	table.sort(rows, function(a, b)
		return a.Z < b.Z
	end)

	local runs = {}
	for _, run in runsByIndex do
		for _, points in run do
			table.sort(points, function(a, b)
				return a.Offset.Position.Z > b.Offset.Position.Z
			end)
		end
		table.insert(runs, run)
	end

	return {
		Name = model.Name,
		Weight = weight,
		Model = model,
		Length = length,
		Rows = rows,
		CoinRuns = runs,
	}
end

-- Builds (or picks up hand-made) templates. Call once at server start.
function TerrainChunk.LoadTemplates(): { TemplateInfo }
	local folder = ServerStorage:FindFirstChild("ChunkTemplates")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ChunkTemplates"
		folder.Parent = ServerStorage
	end
	assert(folder, "ChunkTemplates folder missing")

	local templates: { TemplateInfo } = {}
	local seen: { [string]: boolean } = {}

	for _, spec in ChunkConfig.Templates do
		assert(not seen[spec.Name], `Duplicate chunk template name "{spec.Name}"`)
		seen[spec.Name] = true
		local model = folder:FindFirstChild(spec.Name)
		if not (model and model:IsA("Model")) then
			model = buildTemplate(spec)
			model.Parent = folder
		end
		local info = readTemplate(model :: Model, spec.Weight)
		if info then
			table.insert(templates, info)
		end
	end

	-- Hand-made templates with no config entry: weight from a "Weight" attribute.
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and not seen[child.Name] then
			local weight = child:GetAttribute("Weight")
			local info = readTemplate(child, if type(weight) == "number" then weight else 1)
			if info then
				table.insert(templates, info)
			end
		end
	end

	assert(#templates > 0, "No usable chunk templates")
	return templates
end

return TerrainChunk
