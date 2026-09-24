--!strict
--[[
	Pool
	Keeps unused instances parked out of sight so they can be reused instead
	of being destroyed and re-created. Parked instances stay in Workspace
	(under a holding folder far below the map): re-parenting to ServerStorage
	would make every client delete and re-download them on each reuse, which
	is exactly the churn pooling is meant to avoid.
]]

local Pool = {}
Pool.__index = Pool

export type Pool = typeof(setmetatable(
	{} :: {
		_factory: () -> PVInstance,
		_free: { PVInstance },
		_inUse: { [PVInstance]: true },
		_folder: Folder,
		_holding: CFrame,
	},
	Pool
))

function Pool.new(name: string, factory: () -> PVInstance, holdingParent: Instance, holding: CFrame): Pool
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = holdingParent
	return setmetatable({
		_factory = factory,
		_free = {},
		_inUse = {},
		_folder = folder,
		_holding = holding,
	}, Pool)
end

-- Returns a pooled instance (or a new one). The caller positions and parents it.
function Pool.Acquire(self: Pool): PVInstance
	local instance = table.remove(self._free) or self._factory()
	self._inUse[instance] = true
	return instance
end

function Pool.Release(self: Pool, instance: PVInstance)
	-- Releasing twice would put one instance in the free list twice, and two
	-- later Acquire calls would then hand out the SAME instance: two chunks
	-- sharing one model. Fail loudly instead.
	assert(self._inUse[instance], "Pool: instance released twice or not from this pool")
	self._inUse[instance] = nil
	instance:PivotTo(self._holding)
	instance.Parent = self._folder
	table.insert(self._free, instance)
end

function Pool.Stats(self: Pool): (number, number)
	local inUse = 0
	for _ in self._inUse do
		inUse += 1
	end
	return inUse, #self._free
end

return Pool
