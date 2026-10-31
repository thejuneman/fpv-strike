--!strict
-- Air defence. Each SAM site picks the nearest drone it can see, holds a radar lock on it for a
-- moment (the pilot hears it), then cold-launches a missile that flies the same PN code as
-- yours. Drones hugging the ground hide in the radar's ground clutter; the house blocks it.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Weapons = require(ReplicatedStorage.Shared.Weapons)
local Combat = require(script.Parent.Combat)

local Defenses = {}

local SPEC = Weapons.Specs.SAM
local CLUTTER = 12 -- studs: below this the radar can't pick a drone out of the ground
local MAST = Vector3.new(3.5, 3, -2.5) -- the radar, in the site's hitbox space
local CELL = Vector3.new(-2.5, 3, 0) -- top of the launcher

type Site = { lock: Model?, since: number, ready: number }
local sites: { [Model]: Site } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function canSee(eye: Vector3, drone: Model): boolean
	if not Combat.alive(drone) then
		return false
	end
	local at = (drone.PrimaryPart :: BasePart).Position
	if at.Y < CLUTTER or (at - eye).Magnitude > SPEC.Range then
		return false
	end
	local hit = workspace:Raycast(eye, at - eye, rayParams)
	return hit == nil or hit.Instance:IsDescendantOf(drone)
end

local function update(site: Model, drones: Folder, now: number)
	local state = sites[site]
	if not state then
		state = { lock = nil, since = now, ready = now }
		sites[site] = state
	end
	local root = site.PrimaryPart :: BasePart
	local eye = root.CFrame * MAST
	local best: Model?, bestDist = nil, math.huge
	if (site:GetAttribute("Health") :: number) > 0 then
		for _, child in drones:GetChildren() do
			local drone = child :: Model
			if canSee(eye, drone) then
				-- Hold an existing lock rather than flicking between drones.
				local dist = if drone == state.lock then 0 else ((drone.PrimaryPart :: BasePart).Position - eye).Magnitude
				if dist < bestDist then
					best, bestDist = drone, dist
				end
			end
		end
	end
	if best ~= state.lock then
		state.lock, state.since = best, now
		site:SetAttribute("Tracking", if best then best:GetAttribute("OwnerId") else nil)
	end
	if best and now - state.since >= SPEC.LockTime and now >= state.ready then
		state.ready = now + SPEC.Reload
		local toward = (best.PrimaryPart :: BasePart).Position - root.Position
		local flat = Vector3.new(toward.X, 0, toward.Z)
		-- Straight up out of the cell, leaning a little toward the target.
		local forward = (Vector3.yAxis + (if flat.Magnitude > 1e-3 then flat.Unit * 0.2 else Vector3.zero)).Unit
		Combat.launch("SAM", root.CFrame * CELL, forward, best, site)
	end
end

function Defenses.start(drones: Folder)
	rayParams.FilterDescendantsInstances = { workspace:WaitForChild("Targets") }
	local sweep = 0
	RunService.Heartbeat:Connect(function(dt)
		sweep += dt
		if sweep < 0.1 then
			return -- the radar sweeps ten times a second
		end
		sweep = 0
		local now = workspace:GetServerTimeNow()
		for _, target in CollectionService:GetTagged("Target") do
			if target:GetAttribute("Kind") == "SAM" then
				update(target, drones, now)
			end
		end
	end)
end

return Defenses
