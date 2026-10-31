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
}

local function entryOf(model: Model): Entry?
	return TargetPaths.List[model:GetAttribute("Path") :: number]
end

function TargetPaths.place(model: Model, now: number)
	local entry = entryOf(model)
	local root = model.PrimaryPart
	if entry and root then
		root.CFrame = entry.at(now) * CFrame.new(0, model:GetAttribute("Lift") :: number, 0)
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
function TargetPaths.velocity(model: Model, now: number): Vector3
	local entry = entryOf(model)
	if not entry or not entry.moving or (model:GetAttribute("Health") :: number) <= 0 then
		return Vector3.zero
	end
	return (entry.at(now + 0.05).Position - entry.at(now - 0.05).Position) / 0.1
end

return TargetPaths
