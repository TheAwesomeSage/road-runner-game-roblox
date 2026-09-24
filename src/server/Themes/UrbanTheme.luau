--!strict
--[[
	UrbanTheme
	Blocky low-poly city art. This is the ONLY module that decides how things
	look. To reskin the game, copy this file, change the art, and point
	ChunkConfig.Theme at the new module. A theme must provide:

	  Theme.BuildChunk(model, template, layout)  -- scenery for one chunk
	  Theme.BuildObstacle(kind, hitbox) -> Model -- pivot at road-level centre
	  Theme.BuildCoin() -> BasePart

	Everything is built around the chunk's local origin: the chunk starts at
	z = 0 and runs toward -Z; the road surface is at y = 0.
	Gameplay collision never touches these parts (see ChunkConfig hitboxes),
	so they are all non-colliding and not queryable.
]]

local UrbanTheme = {}

export type Layout = {
	Length: number,
	RoadWidth: number,
	SidewalkWidth: number,
	LaneCount: number,
	LaneOffset: (lane: number) -> number,
}

local Palette: { [string]: Color3 } = {
	Asphalt = Color3.fromRGB(58, 60, 66),
	LaneLine = Color3.fromRGB(235, 235, 225),
	Sidewalk = Color3.fromRGB(175, 172, 165),
	Curb = Color3.fromRGB(140, 138, 132),
	Lot = Color3.fromRGB(120, 118, 112),
	Window = Color3.fromRGB(70, 95, 120),
	Storefront = Color3.fromRGB(45, 55, 70),
	Metal = Color3.fromRGB(70, 74, 80),
	LampGlow = Color3.fromRGB(255, 236, 170),
	Leaves = Color3.fromRGB(88, 160, 72),
	LeavesDark = Color3.fromRGB(64, 128, 58),
	Bark = Color3.fromRGB(110, 76, 48),
	Rock = Color3.fromRGB(128, 126, 122),
	RockDark = Color3.fromRGB(98, 96, 94),
	Coin = Color3.fromRGB(255, 200, 40),
	Hydrant = Color3.fromRGB(200, 45, 40),
	Bin = Color3.fromRGB(46, 110, 70),
	Wood = Color3.fromRGB(150, 105, 65),
	Glass = Color3.fromRGB(170, 210, 230),

	-- Building colours referenced by name from ChunkConfig templates
	Slate = Color3.fromRGB(96, 106, 122),
	Concrete = Color3.fromRGB(165, 165, 160),
	Navy = Color3.fromRGB(52, 66, 102),
	Sand = Color3.fromRGB(214, 190, 142),
	Teal = Color3.fromRGB(64, 142, 140),
	Brick = Color3.fromRGB(156, 82, 62),
	RedBrick = Color3.fromRGB(132, 56, 48),
	Cream = Color3.fromRGB(234, 224, 198),
	Mustard = Color3.fromRGB(216, 170, 62),
	Coral = Color3.fromRGB(222, 116, 96),
	Mint = Color3.fromRGB(150, 205, 170),
	Rust = Color3.fromRGB(150, 90, 55),
}

local FALLBACK_COLOR = Color3.fromRGB(255, 0, 255) -- loud, so typos are obvious
local BUILDING_DEPTH = 18
local FLOOR_HEIGHT = 5

local function color(name: string): Color3
	return Palette[name] or FALLBACK_COLOR
end

-- Every scenery part goes through here so they all share the same cheap,
-- physics-free settings.
local function part(parent: Instance?, size: Vector3, cframe: CFrame, colour: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cframe
	p.Color = colour
	p.Parent = parent
	return p
end

-- Cylinders in Roblox lie along X; this stands them upright.
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
-- ... and this lays them along the track (Z).
local ALONG_TRACK = CFrame.Angles(0, math.pi / 2, 0)

-- Road, lane markings and sidewalks ----------------------------------------------
local function buildStreet(folder: Folder, layout: Layout)
	local length = layout.Length
	local halfRoad = layout.RoadWidth / 2
	local sidewalk = layout.SidewalkWidth
	local midZ = -length / 2

	part(folder, Vector3.new(layout.RoadWidth, 1, length), CFrame.new(0, -0.5, midZ), Palette.Asphalt)

	-- Dashed lines between lanes. Dashes start 3 studs in and repeat every
	-- 10 studs, so they line up across chunk boundaries (60 is a multiple).
	for lane = 1, layout.LaneCount - 1 do
		local x = (layout.LaneOffset(lane) + layout.LaneOffset(lane + 1)) / 2
		for z = 3, length - 1, 10 do
			part(folder, Vector3.new(0.3, 0.05, 4), CFrame.new(x, 0.025, -z - 2), Palette.LaneLine)
		end
	end

	for _, side in { -1, 1 } do
		local x = side * (halfRoad + sidewalk / 2)
		part(folder, Vector3.new(sidewalk, 1.5, length), CFrame.new(x, -0.25, midZ), Palette.Sidewalk)
		part(folder, Vector3.new(0.6, 1.52, length), CFrame.new(side * (halfRoad + 0.3), -0.25, midZ), Palette.Curb)
		-- Ground under the buildings so alleys are not holes in the world.
		local lotX = side * (halfRoad + sidewalk + BUILDING_DEPTH / 2)
		part(folder, Vector3.new(BUILDING_DEPTH, 1, length), CFrame.new(lotX, 0, midZ), Palette.Lot)
	end
end

-- Buildings ------------------------------------------------------------------------
local function buildBuilding(
	folder: Folder,
	side: number,
	frontX: number,
	zStart: number,
	width: number,
	height: number,
	colour: Color3
)
	local zMid = -(zStart + width / 2)
	local depthX = side * (frontX + BUILDING_DEPTH / 2)
	-- Leave a 0.4 stud gap between neighbours so the row reads as separate blocks.
	local frontage = width - 0.4

	part(folder, Vector3.new(BUILDING_DEPTH, height, frontage), CFrame.new(depthX, height / 2 + 0.5, zMid), colour)
	-- Roof ledge
	part(
		folder,
		Vector3.new(BUILDING_DEPTH + 0.6, 0.8, frontage + 0.6),
		CFrame.new(depthX, height + 0.9, zMid),
		colour:Lerp(Color3.new(0, 0, 0), 0.25)
	)

	-- Window bands and storefront glass on the face that looks at the road.
	local faceX = side * (frontX - 0.1)
	part(folder, Vector3.new(0.3, 3, frontage - 2), CFrame.new(faceX, 2.2, zMid), Palette.Storefront)
	for y = 6, height - 3, FLOOR_HEIGHT do
		part(folder, Vector3.new(0.3, 1.8, frontage - 2), CFrame.new(faceX, y, zMid), Palette.Window)
	end

	-- A rooftop box on wider buildings breaks up the skyline.
	if width >= 14 then
		part(
			folder,
			Vector3.new(4, 2.5, 4),
			CFrame.new(side * (frontX + BUILDING_DEPTH * 0.6), height + 2.5, zMid + width * 0.15),
			Palette.Metal
		)
	end
end

local function buildBuildings(folder: Folder, template: any, layout: Layout)
	local frontX = layout.RoadWidth / 2 + layout.SidewalkWidth
	for sideName, side in { Left = -1, Right = 1 } :: { [string]: number } do
		local cursor = 0
		for _, b in template[sideName] do
			if cursor + b.W > layout.Length + 0.001 then
				warn(`[UrbanTheme] {template.Name}: {sideName} buildings are longer than the chunk; extra ones skipped`)
				break
			end
			buildBuilding(folder, side, frontX, cursor, b.W, b.H, color(b.Color))
			cursor += b.W
		end
	end
end

-- Props ----------------------------------------------------------------------------
-- Each builder gets the side (-1 left, +1 right), the curb-side x, and the
-- CFrame of the prop's base point on the sidewalk.
type PropBuilder = (folder: Folder, side: number, base: CFrame, layout: Layout) -> ()

local PropBuilders: { [string]: PropBuilder } = {}

PropBuilders.LampPost = function(folder, side, base)
	part(folder, Vector3.new(0.5, 11, 0.5), base * CFrame.new(0, 5.5, 0), Palette.Metal)
	-- Arm reaches out over the road (toward the centre line, i.e. -side).
	part(folder, Vector3.new(3, 0.35, 0.35), base * CFrame.new(-side * 1.5, 10.8, 0), Palette.Metal)
	local head = part(folder, Vector3.new(1.4, 0.5, 1.8), base * CFrame.new(-side * 3, 10.5, 0), Palette.LampGlow)
	head.Material = Enum.Material.Neon
end

PropBuilders.Hydrant = function(folder, _side, base)
	part(
		folder,
		Vector3.new(2, 1.1, 1.1),
		base * CFrame.new(0, 1, 0) * UPRIGHT,
		Palette.Hydrant,
		Enum.PartType.Cylinder
	)
	part(folder, Vector3.new(0.5, 1.5, 0.5), base * CFrame.new(0, 1.2, 0), Palette.Hydrant)
	part(folder, Vector3.new(0.8, 0.8, 0.8), base * CFrame.new(0, 2.1, 0), Palette.Hydrant, Enum.PartType.Ball)
end

PropBuilders.TrashCan = function(folder, _side, base)
	part(
		folder,
		Vector3.new(2.6, 1.6, 1.6),
		base * CFrame.new(0, 1.3, 0) * UPRIGHT,
		Palette.Bin,
		Enum.PartType.Cylinder
	)
	part(
		folder,
		Vector3.new(0.3, 1.8, 1.8),
		base * CFrame.new(0, 2.7, 0) * UPRIGHT,
		Palette.Metal,
		Enum.PartType.Cylinder
	)
end

PropBuilders.Tree = function(folder, _side, base)
	part(folder, Vector3.new(3, 0.8, 3), base * CFrame.new(0, 0.4, 0), Palette.Curb)
	part(folder, Vector3.new(0.9, 6, 0.9), base * CFrame.new(0, 3.5, 0), Palette.Bark)
	part(
		folder,
		Vector3.new(5, 3.5, 5),
		base * CFrame.new(0, 7.5, 0) * CFrame.Angles(0, math.rad(20), 0),
		Palette.Leaves
	)
	part(
		folder,
		Vector3.new(3.4, 2.6, 3.4),
		base * CFrame.new(0, 9.8, 0) * CFrame.Angles(0, math.rad(55), 0),
		Palette.LeavesDark
	)
end

PropBuilders.Bench = function(folder, side, base)
	part(folder, Vector3.new(1.6, 0.3, 5), base * CFrame.new(0, 1.3, 0), Palette.Wood)
	part(folder, Vector3.new(0.3, 1.4, 5), base * CFrame.new(side * 0.8, 2.1, 0), Palette.Wood)
	for _, z in { -2, 2 } do
		part(folder, Vector3.new(1.2, 1.2, 0.3), base * CFrame.new(0, 0.6, z), Palette.Metal)
	end
end

PropBuilders.BusStop = function(folder, side, base, layout)
	part(folder, Vector3.new(4.5, 0.4, 10), base * CFrame.new(side * 0.5, 7.5, 0), Palette.Metal)
	part(folder, Vector3.new(0.2, 5.5, 9.4), base * CFrame.new(side * 2.4, 3.6, 0), Palette.Glass).Transparency = 0.4
	for _, z in { -4.8, 4.8 } do
		part(folder, Vector3.new(0.4, 7.4, 0.4), base * CFrame.new(side * 2.4, 3.8, z), Palette.Metal)
	end
	PropBuilders.Bench(folder, side, base * CFrame.new(side * 1.2, 0, 0), layout)
end

-- Distance from the curb for each prop kind (bigger things sit further back).
local PropInset: { [string]: number } = {
	LampPost = 1.5,
	Hydrant = 1.5,
	TrashCan = 1.8,
	Tree = 2,
	Bench = 5,
	BusStop = 4.5,
}

local function buildProps(folder: Folder, template: any, layout: Layout)
	for _, prop in template.Props or {} do
		local builder = PropBuilders[prop.Kind]
		if not builder then
			warn(`[UrbanTheme] {template.Name}: unknown prop kind "{prop.Kind}"`)
			continue
		end
		local side = if prop.Side == "Left" then -1 else 1
		local x = side * (layout.RoadWidth / 2 + (PropInset[prop.Kind] or 2))
		-- Sidewalk top is at y = 0.5.
		builder(folder, side, CFrame.new(x, 0.5, -prop.Z), layout)
	end
end

-- Road features ---------------------------------------------------------------------
local FeatureBuilders: { [string]: (folder: Folder, layout: Layout) -> () } = {}

FeatureBuilders.Crosswalk = function(folder, layout)
	local halfRoad = layout.RoadWidth / 2
	for x = -halfRoad + 1.5, halfRoad - 1.5, 3 do
		part(folder, Vector3.new(1.6, 0.06, 10), CFrame.new(x, 0.03, -layout.Length / 2), Palette.LaneLine)
	end
end

FeatureBuilders.Overpass = function(folder, layout)
	local span = layout.RoadWidth + layout.SidewalkWidth * 2 + BUILDING_DEPTH * 2
	local z = -layout.Length / 2
	part(folder, Vector3.new(span, 2.5, 12), CFrame.new(0, 22, z), Palette.Concrete)
	for _, side in { -1, 1 } do
		part(folder, Vector3.new(span, 1.2, 0.5), CFrame.new(0, 23.8, z + side * 5.75), Palette.Slate)
		local pillarX = side * (layout.RoadWidth / 2 + layout.SidewalkWidth - 1.5)
		for _, dz in { -4, 4 } do
			part(folder, Vector3.new(2, 21, 2), CFrame.new(pillarX, 11, z + dz), Palette.Concrete)
		end
	end
end

FeatureBuilders.Manholes = function(folder, layout)
	for i, z in { 12, 40 } do
		local lane = (i % layout.LaneCount) + 1
		part(
			folder,
			Vector3.new(0.1, 2.6, 2.6),
			CFrame.new(layout.LaneOffset(lane) + 2.5, 0.05, -z) * UPRIGHT,
			Palette.Metal,
			Enum.PartType.Cylinder
		)
	end
end

function UrbanTheme.BuildChunk(model: Model, template: any, layout: Layout)
	local folder = Instance.new("Folder")
	folder.Name = "Scenery"
	folder.Parent = model

	buildStreet(folder, layout)
	buildBuildings(folder, template, layout)
	buildProps(folder, template, layout)
	for _, feature in template.Features or {} do
		local builder = FeatureBuilders[feature]
		if builder then
			builder(folder, layout)
		else
			warn(`[UrbanTheme] {template.Name}: unknown feature "{feature}"`)
		end
	end
end

-- Obstacles --------------------------------------------------------------------------
local ObstacleBuilders: { [string]: (model: Model, hitbox: Vector3) -> () } = {}

ObstacleBuilders.Rock = function(model, hitbox)
	local h = hitbox.Y
	part(
		model,
		Vector3.new(hitbox.X * 0.9, h, hitbox.Z * 0.85),
		CFrame.new(0, h / 2, 0) * CFrame.Angles(0, math.rad(25), math.rad(6)),
		Palette.Rock
	)
	part(
		model,
		Vector3.new(hitbox.X * 0.55, h * 0.6, hitbox.Z * 0.55),
		CFrame.new(0.9, h * 0.3, 1) * CFrame.Angles(math.rad(10), math.rad(-15), 0),
		Palette.RockDark
	)
	part(
		model,
		Vector3.new(hitbox.X * 0.4, h * 0.45, hitbox.Z * 0.4),
		CFrame.new(-1.1, h * 0.95, -0.4) * CFrame.Angles(0, math.rad(45), math.rad(12)),
		Palette.RockDark
	)
end

ObstacleBuilders.Trunk = function(model, hitbox)
	local length = hitbox.Z
	local radius = 1.6
	-- The log itself, lying along the lane.
	part(
		model,
		Vector3.new(length, radius * 2, radius * 2),
		CFrame.new(0, radius, 0) * ALONG_TRACK,
		Palette.Bark,
		Enum.PartType.Cylinder
	)
	-- Root plate at the near end (the end the runner sees first).
	part(
		model,
		Vector3.new(1, 5, 5),
		CFrame.new(0, 2.5, length / 2) * ALONG_TRACK,
		Palette.Bark:Lerp(Color3.new(), 0.3),
		Enum.PartType.Cylinder
	)
	-- Branches and a leafy crown make it clearly too tall to jump.
	for i, z in { -2, -4.5 } do
		part(
			model,
			Vector3.new(0.6, 4.5, 0.6),
			CFrame.new((i - 1.5) * 0.9, radius + 2, z) * CFrame.Angles(0, 0, math.rad((i - 1.5) * 40)),
			Palette.Bark
		)
	end
	part(model, Vector3.new(5.5, 3.5, 5), CFrame.new(0, 5.5, -length / 2 + 2.5), Palette.Leaves)
	part(
		model,
		Vector3.new(3.6, 2.6, 3.6),
		CFrame.new(0.8, 6.8, -length / 2 + 5) * CFrame.Angles(0, math.rad(35), 0),
		Palette.LeavesDark
	)
end

function UrbanTheme.BuildObstacle(kind: string, hitbox: Vector3): Model
	local model = Instance.new("Model")
	model.Name = kind
	local builder = ObstacleBuilders[kind]
	if builder then
		builder(model, hitbox)
	else
		-- Unknown obstacle type: a plain box the size of its hitbox, so new
		-- obstacle types added to ChunkConfig are playable before they have art.
		part(model, hitbox, CFrame.new(0, hitbox.Y / 2, 0), FALLBACK_COLOR)
	end
	model.WorldPivot = CFrame.new() -- pivot = centre of the base, on the road
	return model
end

function UrbanTheme.BuildCoin(): BasePart
	local coin = part(nil, Vector3.new(0.4, 2.2, 2.2), ALONG_TRACK, Palette.Coin, Enum.PartType.Cylinder)
	coin.Name = "Coin"
	coin.Material = Enum.Material.Neon
	return coin
end

return UrbanTheme
