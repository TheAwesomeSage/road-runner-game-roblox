--!strict
--[[
	ChunkConfig
	Everything that decides WHAT the track contains lives here as plain data.
	To add a new street segment, add an entry to `Templates`. To add a new
	obstacle arrangement, add an entry to `Patterns`. No script changes needed.

	Local chunk coordinates used by templates:
	  z      - studs from the START of the chunk (0 .. ChunkLength), forward
	  lane   - 1 .. RunnerConfig.LaneCount, 1 = leftmost
	  side   - "Left" / "Right" of the road

	How the art is drawn is decided by the theme module named in `Theme`
	(see Themes/UrbanTheme). The theme reads the `Color`, `Kind` etc. names
	below; gameplay never looks at them.
]]

local ChunkConfig = {}

-- Name of the ModuleScript in Server/Themes that builds the visuals.
ChunkConfig.Theme = "UrbanTheme"

-- Track window ------------------------------------------------------------------
ChunkConfig.ChunkLength = 60 -- every template is this long (studs)
ChunkConfig.ChunksAhead = 6 -- keep this many chunks' worth of road ahead
-- A chunk is recycled once its END is this far behind the runner. Must be
-- larger than the camera's distance behind the runner, or the road vanishes
-- under the camera.
ChunkConfig.DespawnBehind = 40
-- Weight multiplier for a template used in either of the last 2 chunks.
ChunkConfig.RepeatPenalty = 0.1
ChunkConfig.RecentHistory = 2
-- First N chunks of every run have no obstacles or coins.
ChunkConfig.SafeChunks = 2

-- Where recycled chunks/obstacles are parked. Below the map and behind the
-- start (+Z), above Workspace.FallenPartsDestroyHeight (-500).
ChunkConfig.HoldingCFrame = CFrame.new(0, -250, 5000)

-- Distance between runner tracks when several players are in the server.
ChunkConfig.TrackSpacing = 400

-- Obstacles ---------------------------------------------------------------------
-- Hitbox is the gameplay collision box (X = across, Y = up, Z = along the
-- track), centred on the spawn point and resting on the road. It is
-- independent of the theme's art, so reskinning never changes difficulty.
export type ObstacleType = {
	Hitbox: Vector3,
	Jumpable: boolean, -- false = can only be avoided by changing lane
}

ChunkConfig.ObstacleTypes = {
	Rock = { Hitbox = Vector3.new(4, 3, 4), Jumpable = true },
	-- A fallen trunk lying along its lane. Branches make it too tall to jump.
	Trunk = { Hitbox = Vector3.new(6, 4, 14), Jumpable = false },
} :: { [string]: ObstacleType }

-- One character per lane, left to right: "." empty, "R" rock, "T" trunk.
-- Every pattern must leave at least one lane that is empty or jumpable
-- (checked at startup by ObstacleSpawner).
-- MinDifficulty: pattern only appears once difficulty (0..1) reaches it.
export type Pattern = { Lanes: string, Weight: number, MinDifficulty: number }

ChunkConfig.PatternKeys = {
	R = "Rock",
	T = "Trunk",
}

ChunkConfig.Patterns = {
	-- Singles: available from the start
	{ Lanes = "R..", Weight = 3, MinDifficulty = 0 },
	{ Lanes = ".R.", Weight = 3, MinDifficulty = 0 },
	{ Lanes = "..R", Weight = 3, MinDifficulty = 0 },
	{ Lanes = "T..", Weight = 2, MinDifficulty = 0 },
	{ Lanes = ".T.", Weight = 2, MinDifficulty = 0 },
	{ Lanes = "..T", Weight = 2, MinDifficulty = 0 },
	-- Doubles
	{ Lanes = "RR.", Weight = 2, MinDifficulty = 0.15 },
	{ Lanes = ".RR", Weight = 2, MinDifficulty = 0.15 },
	{ Lanes = "R.T", Weight = 2, MinDifficulty = 0.25 },
	{ Lanes = "T.R", Weight = 2, MinDifficulty = 0.25 },
	{ Lanes = "TT.", Weight = 2, MinDifficulty = 0.35 },
	{ Lanes = ".TT", Weight = 2, MinDifficulty = 0.35 },
	{ Lanes = "T.T", Weight = 2, MinDifficulty = 0.35 },
	-- Combos: switch lane AND jump
	{ Lanes = "RRR", Weight = 1, MinDifficulty = 0.5 },
	{ Lanes = "TRT", Weight = 2, MinDifficulty = 0.55 },
	{ Lanes = "TTR", Weight = 2, MinDifficulty = 0.65 },
	{ Lanes = "RTT", Weight = 2, MinDifficulty = 0.65 },
	{ Lanes = "RTR", Weight = 2, MinDifficulty = 0.65 },
} :: { Pattern }

-- Difficulty ----------------------------------------------------------------
ChunkConfig.Difficulty = {
	RampDistance = 5000, -- distance at which difficulty reaches 1
	RowChanceMin = 0.45, -- chance an obstacle row is filled at difficulty 0
	RowChanceMax = 0.95, -- ... and at difficulty 1
	-- Harder patterns gain this much extra weight per point of difficulty
	-- above their MinDifficulty, so combos get more common over time.
	ComplexityBias = 3,
}

function ChunkConfig.DifficultyAt(distance: number): number
	return math.clamp(distance / ChunkConfig.Difficulty.RampDistance, 0, 1)
end

-- Coins -------------------------------------------------------------------------
ChunkConfig.Coins = {
	RunChance = 0.65, -- chance each coin run in a chunk is filled
	Value = 1,
	PickupRadius = 2, -- added to the player's hitbox when checking pickups
	Height = 2.5, -- coin centre above the road
}

-- Chunk templates ---------------------------------------------------------------
--[[
	Fields:
	  Name          unique; a hand-built Model with this name in
	                ServerStorage.ChunkTemplates replaces the generated one
	  Weight        relative chance of being picked
	  Left / Right  buildings along each side, in order from the chunk start.
	                W = frontage length (studs along the road), H = height.
	                Widths per side should add up to at most ChunkLength;
	                leftover space shows as an alley.
	  Props         street furniture on the sidewalks
	  Features      road decorations: "Crosswalk", "Overpass", "Manholes"
	  ObstacleRows  optional, z of each obstacle row (default {15, 45}).
	                Keep rows about 30 studs apart, including across chunk
	                boundaries, or reaction time at top speed gets too short.
	  CoinRuns      optional, lines of coins {From, To, Step} in z
	                (default one run from 24 to 36).
]]
export type Building = { W: number, H: number, Color: string }
export type Prop = { Kind: string, Side: string, Z: number }
export type CoinRun = { From: number, To: number, Step: number }
export type Template = {
	Name: string,
	Weight: number,
	Left: { Building },
	Right: { Building },
	Props: { Prop }?,
	Features: { string }?,
	ObstacleRows: { number }?,
	CoinRuns: { CoinRun }?,
}

ChunkConfig.DefaultObstacleRows = { 15, 45 }
ChunkConfig.DefaultCoinRuns = { { From = 24, To = 36, Step = 4 } }

ChunkConfig.Templates = {
	{
		Name = "Downtown",
		Weight = 3,
		Left = {
			{ W = 18, H = 42, Color = "Slate" },
			{ W = 14, H = 28, Color = "Concrete" },
			{ W = 24, H = 55, Color = "Navy" },
		},
		Right = {
			{ W = 22, H = 36, Color = "Sand" },
			{ W = 16, H = 48, Color = "Teal" },
			{ W = 20, H = 30, Color = "Concrete" },
		},
		Props = {
			{ Kind = "LampPost", Side = "Left", Z = 10 },
			{ Kind = "LampPost", Side = "Right", Z = 40 },
			{ Kind = "Hydrant", Side = "Right", Z = 22 },
		},
	},
	{
		Name = "Brownstones",
		Weight = 3,
		Left = {
			{ W = 12, H = 20, Color = "Brick" },
			{ W = 12, H = 22, Color = "RedBrick" },
			{ W = 12, H = 19, Color = "Brick" },
			{ W = 12, H = 23, Color = "Cream" },
			{ W = 12, H = 20, Color = "RedBrick" },
		},
		Right = {
			{ W = 15, H = 21, Color = "RedBrick" },
			{ W = 15, H = 18, Color = "Brick" },
			{ W = 15, H = 24, Color = "Cream" },
			{ W = 15, H = 20, Color = "Brick" },
		},
		Props = {
			{ Kind = "Tree", Side = "Left", Z = 18 },
			{ Kind = "Tree", Side = "Right", Z = 42 },
			{ Kind = "TrashCan", Side = "Left", Z = 48 },
		},
	},
	{
		Name = "Shopfronts",
		Weight = 3,
		Left = {
			{ W = 10, H = 14, Color = "Mustard" },
			{ W = 10, H = 12, Color = "Teal" },
			{ W = 10, H = 15, Color = "Cream" },
			{ W = 10, H = 13, Color = "Coral" },
			{ W = 10, H = 14, Color = "Mint" },
			{ W = 10, H = 12, Color = "Mustard" },
		},
		Right = {
			{ W = 20, H = 16, Color = "Coral" },
			{ W = 20, H = 13, Color = "Cream" },
			{ W = 20, H = 15, Color = "Teal" },
		},
		Props = {
			{ Kind = "Bench", Side = "Left", Z = 30 },
			{ Kind = "TrashCan", Side = "Right", Z = 12 },
			{ Kind = "LampPost", Side = "Right", Z = 50 },
		},
	},
	{
		Name = "CrosswalkPlaza",
		Weight = 2,
		Left = {
			{ W = 24, H = 34, Color = "Concrete" },
			{ W = 24, H = 30, Color = "Sand" },
		},
		Right = {
			{ W = 26, H = 40, Color = "Slate" },
			{ W = 26, H = 26, Color = "Cream" },
		},
		Props = {
			{ Kind = "LampPost", Side = "Left", Z = 27 },
			{ Kind = "LampPost", Side = "Right", Z = 33 },
			{ Kind = "Bench", Side = "Right", Z = 50 },
		},
		Features = { "Crosswalk" },
	},
	{
		Name = "Overpass",
		Weight = 1.5,
		Left = {
			{ W = 20, H = 32, Color = "Concrete" },
			{ W = 20, H = 24, Color = "Slate" },
		},
		Right = {
			{ W = 20, H = 28, Color = "Slate" },
			{ W = 20, H = 34, Color = "Concrete" },
		},
		Props = {
			{ Kind = "Hydrant", Side = "Left", Z = 50 },
		},
		Features = { "Overpass" },
	},
	{
		Name = "Parkside",
		Weight = 2,
		Left = {
			{ W = 16, H = 10, Color = "Cream" },
		},
		Right = {
			{ W = 18, H = 16, Color = "Mint" },
			{ W = 18, H = 18, Color = "Sand" },
		},
		Props = {
			{ Kind = "Tree", Side = "Left", Z = 24 },
			{ Kind = "Tree", Side = "Left", Z = 36 },
			{ Kind = "Tree", Side = "Left", Z = 48 },
			{ Kind = "Bench", Side = "Left", Z = 30 },
			{ Kind = "Tree", Side = "Right", Z = 50 },
		},
	},
	{
		Name = "Industrial",
		Weight = 2,
		Left = {
			{ W = 30, H = 18, Color = "Rust" },
			{ W = 26, H = 22, Color = "Concrete" },
		},
		Right = {
			{ W = 28, H = 20, Color = "Slate" },
			{ W = 28, H = 16, Color = "Rust" },
		},
		Props = {
			{ Kind = "TrashCan", Side = "Left", Z = 8 },
			{ Kind = "TrashCan", Side = "Left", Z = 10 },
			{ Kind = "LampPost", Side = "Right", Z = 30 },
		},
		Features = { "Manholes" },
	},
	{
		Name = "Highrise",
		Weight = 2,
		Left = {
			{ W = 28, H = 80, Color = "Navy" },
			{ W = 28, H = 66, Color = "Slate" },
		},
		Right = {
			{ W = 30, H = 72, Color = "Teal" },
			{ W = 26, H = 90, Color = "Navy" },
		},
		Props = {
			{ Kind = "LampPost", Side = "Left", Z = 15 },
			{ Kind = "LampPost", Side = "Left", Z = 45 },
			{ Kind = "LampPost", Side = "Right", Z = 15 },
			{ Kind = "LampPost", Side = "Right", Z = 45 },
		},
	},
	{
		Name = "BusStop",
		Weight = 2,
		Left = {
			{ W = 14, H = 24, Color = "Coral" },
			{ W = 18, H = 30, Color = "Sand" },
			{ W = 14, H = 20, Color = "Brick" },
		},
		Right = {
			{ W = 20, H = 26, Color = "Concrete" },
			{ W = 20, H = 22, Color = "Mustard" },
		},
		Props = {
			{ Kind = "BusStop", Side = "Right", Z = 30 },
			{ Kind = "Hydrant", Side = "Left", Z = 12 },
			{ Kind = "TrashCan", Side = "Right", Z = 44 },
		},
		CoinRuns = {
			{ From = 22, To = 38, Step = 4 },
		},
	},
} :: { Template }

return ChunkConfig
