--!strict
-- Where every range target is at a given server time. The server and every client evaluate
-- the same paths, so moving targets glide smoothly on screen and the server's hit checks agree.

local CollectionService = game:GetService("CollectionService")

local TargetPaths = {}

export type Entry = { kind: string, moving: boolean, at: (number) -> CFrame }

local function parked(x: number, z: number, yaw: number): Entry
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0)
	return {
		kind = "",
		moving = false,
		at = function()
			return cf
		end,
	}
end

-- An ellipse driven at constant-ish speed, facing along the path, optionally banked.
local function loop(center: Vector3, rx: number, rz: number, speed: number, bank: number?): Entry
	local w = speed / ((rx + rz) / 2)
	return {
		kind = "",
		moving = true,
		at = function(t: number)
			local a = t * w
			local pos = center + Vector3.new(math.cos(a) * rx, 0, math.sin(a) * rz)
			local tangent = Vector3.new(-math.sin(a) * rx, 0, math.cos(a) * rz)
			return CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(0, 0, bank or 0)
		end,
	}
end

local function kind(name: string, entry: Entry): Entry
	entry.kind = name
	return entry
end

-- Laid out around the house at (0, 0, -90); the pad is at the origin.
TargetPaths.List = {
	kind("Tank", parked(-70, -5, 25)),
	kind("Truck", parked(85, -10, -25)),
	kind("Tank", parked(30, -210, 180)),
	kind("Truck", parked(120, -150, 70)),
	kind("Truck", loop(Vector3.new(0, 0, -90), 100, 70, 28)),
	kind("Tank", loop(Vector3.new(-175, 0, -110), 45, 45, 12)),
	kind("Drone", loop(Vector3.new(0, 70, -90), 120, 120, 45, math.rad(-20))),
	kind("Drone", loop(Vector3.new(-40, 110, -300), 170, 100, 55, math.rad(-25))),
	-- Air defence out past the range: it wakes up when you fly within reach.
	kind("SAM", parked(380, -520, 200)),
	kind("SAM", parked(-430, -600, 140)),
}

-- Evasive break: a hard sidestep-and-dive that rejoins the path. The server starts one by
-- setting BreakAt/BreakSide, and every client plays the identical manoeuvre from them.
TargetPaths.BreakTime = 2.4
local BREAK_SIZE = 50

local function entryOf(model: Model): Entry?
	return TargetPaths.List[model:GetAttribute("Path") :: number]
end

local function pose(model: Model, entry: Entry, t: number): CFrame
	local cf = entry.at(t)
	local breakAt = model:GetAttribute("BreakAt") :: number?
	if breakAt and t > breakAt and t < breakAt + TargetPaths.BreakTime then
		local u = (t - breakAt) / TargetPaths.BreakTime
		local side = model:GetAttribute("BreakSide") :: number
		local s = math.sin(math.pi * u) ^ 2 -- 0 → 1 → 0 with zero slope at both ends: no jumps
		local roll = -side * math.sin(2 * math.pi * u) * math.rad(70)
		cf *= CFrame.new(side * BREAK_SIZE * s, -BREAK_SIZE * 0.5 * s, 0) * CFrame.Angles(0, 0, roll)
	end
	return cf
end

function TargetPaths.place(model: Model, now: number)
	local entry = entryOf(model)
	local root = model.PrimaryPart
	if entry and root then
		root.CFrame = pose(model, entry, now) * CFrame.new(0, model:GetAttribute("Lift") :: number, 0)
	end
end

-- Moves every live, moving target. Clients call this every frame, the server every Heartbeat.
function TargetPaths.animate(now: number)
	for _, model in CollectionService:GetTagged("Target") do
		local entry = entryOf(model)
		if entry and entry.moving and (model:GetAttribute("Health") :: number) > 0 then
			TargetPaths.place(model, now)
		end
	end
end

-- Exact path velocity (central difference), free of the noise you'd get sampling replication.
-- Anything without a path (a player's drone) reports its physics velocity.
function TargetPaths.velocity(model: Model, now: number): Vector3
	local entry = entryOf(model)
	if not entry then
		local root = model.PrimaryPart
		return if root then root.AssemblyLinearVelocity else Vector3.zero
	end
	if not entry.moving or (model:GetAttribute("Health") :: number) <= 0 then
		return Vector3.zero
	end
	return (pose(model, entry, now + 0.05).Position - pose(model, entry, now - 0.05).Position) / 0.1
end

return TargetPaths
