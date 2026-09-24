--!strict
-- Server entry point: build the chunk templates, set up pooling, then start
-- simulating runners.

local ChunkManager = require(script.Parent.ChunkManager)
local PlayerRunner = require(script.Parent.PlayerRunner)
local TerrainChunk = require(script.Parent.TerrainChunk)

ChunkManager.Init(TerrainChunk.LoadTemplates())
PlayerRunner.Start()
