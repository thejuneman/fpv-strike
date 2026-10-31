--!strict
-- Server side of the weapons. Validates every shot, flies the authoritative missiles with the
-- shared Missile code, decides hits and damage, and tells every client what happened.
-- Clients draw their own shots instantly but never decide a hit.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Weapons = require(Shared.Weapons)
local Missile = require(Shared.Missile)
local TargetPaths = require(Shared.TargetPaths)
local Targets = require(script.Parent.Targets)

local Combat = {}

local fireRemote = ReplicatedStorage.Remotes.FireWeapon :: RemoteEvent
local missileRemote = ReplicatedStorage.Remotes.Missiles :: RemoteEvent

local LAUNCH_SLACK = 30 -- studs a claimed launch point may sit from our view of the drone
local LATENCY_GRACE = 0.25 -- seconds of reload credit for a shot still crossing the network
local ARM_TIME = 0.1 -- warhead can't go off this soon after launch

type Flight = {
	id: string,
	name: string,
	spec: Weapons.Spec,
	state: Missile.State,
	owner: Player,
	target: Model?,
	lastSeen: Vector3?,
}

local flights: { [string]: Flight } = {}
local slots: { [Player]: { [string]: Weapons.Slot } } = {}
local drones: Folder
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function slotFor(player: Player, name: string, now: number): Weapons.Slot
	local mine = slots[player]
	if not mine then
		mine = {}
		slots[player] = mine
	end
	local slot = mine[name]
	if not slot then
		slot = Weapons.newSlot(Weapons.Specs[name], now)
		mine[name] = slot
	end
	return slot
end

-- Distance from a point to a target's hitbox (0 inside it).
local function boxDistance(model: Model, point: Vector3): number
	local root = model.PrimaryPart :: BasePart
	local p = root.CFrame:PointToObjectSpace(point)
	local half = root.Size / 2
	return Vector3.new(
		math.max(math.abs(p.X) - half.X, 0),
		math.max(math.abs(p.Y) - half.Y, 0),
		math.max(math.abs(p.Z) - half.Z, 0)
	).Magnitude
end

local function detonate(f: Flight, at: Vector3)
	flights[f.id] = nil
	local result: string? = nil
	for _, target in CollectionService:GetTagged("Target") do
		local d = boxDistance(target, at)
		if d < f.spec.BlastRadius then
			local hit, killed = Targets.damage(target, f.spec.Damage * (1 - 0.7 * d / f.spec.BlastRadius))
			if killed then
				result = "kill"
			elseif hit and not result then
				result = "hit"
			end
		end
	end
	missileRemote:FireAllClients("boom", f.id, at, f.name, f.owner.UserId, result)
end

local function onFire(player: Player, name: unknown, shotId: unknown, origin: unknown, direction: unknown, target: unknown)
	-- Everything from the client is untrusted: check types, NaNs and ranges before use.
	if typeof(name) ~= "string" or not Weapons.Specs[name] then
		return
	end
	if typeof(shotId) ~= "number" or typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	if origin ~= origin or direction ~= direction or direction.Magnitude < 0.5 then
		return
	end
	local id = `{player.UserId}:{shotId}`
	if flights[id] then
		return
	end
	local spec = Weapons.Specs[name]
	local drone = drones:FindFirstChild(player.Name)
	local root = drone and (drone :: Model).PrimaryPart
	if not root then
		return
	end

	local now = workspace:GetServerTimeNow()
	local slot = slotFor(player, name, now)
	local guided = spec.Guidance ~= "None"
	local validTarget = typeof(target) == "Instance"
		and CollectionService:HasTag(target, "Target")
		and not (spec.Guidance == "TopAttack" and target:GetAttribute("Kind") == "Drone")
	local nearDrone = (origin - root.Position).Magnitude < LAUNCH_SLACK + root.AssemblyLinearVelocity.Magnitude * 0.3
	if not nearDrone or (guided and not validTarget) or not Weapons.tryFire(slot, spec, now, LATENCY_GRACE) then
		missileRemote:FireClient(player, "cancel", id, name, slot.ammo)
		return
	end

	local forward = direction.Unit
	local velocity = root.AssemblyLinearVelocity + forward * spec.LaunchSpeed
	local targetModel = if guided then target :: Model else nil
	flights[id] = {
		id = id,
		name = name,
		spec = spec,
		state = Missile.new(origin, velocity, forward),
		owner = player,
		target = targetModel,
		lastSeen = targetModel and (targetModel.PrimaryPart :: BasePart).Position,
	}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			missileRemote:FireClient(other, "spawn", id, name, origin, velocity, forward, targetModel)
		end
	end
end

local function step(dt: number)
	local now = workspace:GetServerTimeNow()
	TargetPaths.animate(now)
	for _, f in flights do
		local s = f.state
		local target = f.target
		local aimPos, aimVel = nil, nil
		if target and target.Parent and (target:GetAttribute("Health") :: number) > 0 then
			f.lastSeen = (target.PrimaryPart :: BasePart).Position
			aimPos, aimVel = f.lastSeen, TargetPaths.velocity(target, now)
		elseif f.lastSeen then
			aimPos, aimVel = f.lastSeen, Vector3.zero -- target gone: fly to where it was
		end

		local before = s.pos
		Missile.step(s, f.spec, dt, aimPos, aimVel)
		local travel = s.pos - before
		rayParams.FilterDescendantsInstances = { drones:FindFirstChild(f.owner.Name) :: Instance }
		local impact = if s.age > ARM_TIME and travel.Magnitude > 1e-3
			then workspace:Spherecast(before, 0.5, travel, rayParams)
			else nil
		local closest = if aimPos then Missile.closestOnSegment(before, s.pos, aimPos) else nil

		if impact then
			detonate(f, impact.Position)
		elseif closest and f.spec.Fuse > 0 and (closest - (aimPos :: Vector3)).Magnitude < f.spec.Fuse then
			detonate(f, closest)
		elseif s.age > f.spec.Lifetime then
			detonate(f, s.pos)
		end
	end
end

function Combat.start(droneFolder: Folder)
	drones = droneFolder
	fireRemote.OnServerEvent:Connect(onFire)
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(player)
		slots[player] = nil
	end)
end

return Combat
