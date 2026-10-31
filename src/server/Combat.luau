--!strict
-- Server side of the weapons. Validates every shot, flies the authoritative missiles with the
-- shared Missile code, decides hits and damage, and tells every client what happened.
-- Clients draw their own shots instantly but never decide a hit.
-- Also runs everything that fights back: enemy missiles, flares and the decoy rule, evasive
-- enemy drones, drone damage, kamikaze runs and walls that blow apart.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Weapons = require(Shared.Weapons)
local Missile = require(Shared.Missile)
local Flares = require(Shared.Flares)
local TargetPaths = require(Shared.TargetPaths)
local Targets = require(script.Parent.Targets)

local Combat = {}

local remotes = ReplicatedStorage.Remotes
local fireRemote = remotes.FireWeapon :: RemoteEvent
local actionRemote = remotes.DroneAction :: RemoteEvent
local missileRemote = remotes.Missiles :: RemoteEvent

local LAUNCH_SLACK = 30 -- studs a claimed launch point may sit from our view of the drone
local LATENCY_GRACE = 0.25 -- seconds of reload credit for a shot still crossing the network
local ARM_TIME = 0.1 -- warhead can't go off this soon after launch
local BREAK_RANGE = 260 -- an enemy drone breaks and flares when your seeker gets this close
local BREAK_COOLDOWN = 6
local REACQUIRE_CONE = math.rad(40) -- a missile let go by a flare finds its target again inside this
local WALL_REBUILD = 20 -- seconds before blown-out bricks are back in the wall

type Flight = {
	id: string,
	name: string,
	spec: Weapons.Spec,
	state: Missile.State,
	owner: Player?, -- nil for enemy missiles
	launcher: Instance?, -- what an enemy missile mustn't hit on its way out
	target: Model?,
	decoy: Flares.Flare?,
	lastSeen: Vector3?,
}
type Blast = { Damage: number, BlastRadius: number }
type Salvo = {
	list: { Flares.Flare },
	carrier: Model, -- who dropped them: only missiles homing on it can be fooled
	chance: number,
	burnout: number,
	tried: { [string]: boolean }, -- one roll per missile per salvo
}

local flights: { [string]: Flight } = {}
local slots: { [Player]: { [string]: Weapons.Slot } } = {}
local salvos: { [string]: Salvo } = {}
local drones: Folder
local enemyShots = 0
local random = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local wallParams = OverlapParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Include

-- Targets and drones alike: still there, not destroyed, not between lives.
local function alive(model: Model?): boolean
	return model ~= nil
		and model.Parent ~= nil
		and model.PrimaryPart ~= nil
		and (model:GetAttribute("Health") :: number) > 0
		and not model:GetAttribute("Down")
end
Combat.alive = alive

local function slotFor(player: Player, name: string, spec: Weapons.Magazine, now: number): Weapons.Slot
	local mine = slots[player]
	if not mine then
		mine = {}
		slots[player] = mine
	end
	local slot = mine[name]
	if not slot then
		slot = Weapons.newSlot(spec, now)
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

-- Knocks loose every wall brick the blast reaches; they fly, then the wall rebuilds itself.
local function breakWalls(at: Vector3, radius: number)
	for _, brick in workspace:GetPartBoundsInRadius(at, radius * 0.55, wallParams) do
		if brick.Anchored and CollectionService:HasTag(brick, "Breakable") then
			local away = brick.Position - at
			brick.Anchored = false
			brick.AssemblyLinearVelocity = (if away.Magnitude > 1e-3 then away.Unit else Vector3.yAxis) * random:NextNumber(30, 80)
				+ Vector3.new(0, 20, 0)
			brick.AssemblyAngularVelocity = random:NextUnitVector() * 6
			task.delay(WALL_REBUILD + random:NextNumber(0, 3), function()
				brick.Anchored = true
				brick.CFrame = brick:GetAttribute("Home") :: CFrame
			end)
		end
	end
end

-- Takes a drone out of the fight; the server hands its pilot a fresh one after DownTime.
local function down(drone: Model)
	drone:SetAttribute("Health", 0)
	drone:SetAttribute("Down", true)
	task.delay(Config.DownTime, function()
		if drone.Parent then
			drone:SetAttribute("Health", Config.Health)
			drone:SetAttribute("Down", false)
		end
	end)
end

-- Damage with falloff, broken walls, and a "boom" for every client. A player's blast hurts
-- targets; an enemy blast (no owner) hurts drones.
local function explode(id: string, at: Vector3, blast: Blast, owner: Player?)
	local function falloff(d: number): number
		return blast.Damage * (1 - 0.7 * d / blast.BlastRadius)
	end
	local result: string? = nil
	if owner then
		for _, target in CollectionService:GetTagged("Target") do
			local d = boxDistance(target, at)
			if d < blast.BlastRadius then
				local hit, killed = Targets.damage(target, falloff(d))
				if killed then
					result = "kill"
				elseif hit and not result then
					result = "hit"
				end
			end
		end
	else
		for _, child in drones:GetChildren() do
			local drone = child :: Model
			if alive(drone) then
				local d = math.max(((drone.PrimaryPart :: BasePart).Position - at).Magnitude - 1.5, 0)
				if d < blast.BlastRadius then
					local health = (drone:GetAttribute("Health") :: number) - falloff(d)
					if health <= 0 then
						down(drone)
					else
						drone:SetAttribute("Health", health)
					end
				end
			end
		end
	end
	breakWalls(at, blast.BlastRadius)
	missileRemote:FireAllClients("boom", id, at, blast.BlastRadius, if owner then owner.UserId else 0, result)
end

local function detonate(f: Flight, at: Vector3)
	flights[f.id] = nil
	explode(f.id, at, f.spec, f.owner)
end

local function addSalvo(id: string, list: { Flares.Flare }, carrier: Model, chance: number)
	salvos[id] = { list = list, carrier = carrier, chance = chance, burnout = list[#list].born + Flares.Burn, tried = {} }
end

-- A missile homing on whoever dropped a salvo gets one roll against it, the first moment a
-- burning flare sits near its nose and close enough to fool it. So flares popped as a SAM
-- leaves the rail still work once it tips over toward you. Clients hear about every decoy so
-- they keep flying the same missile.
local function decoys(now: number)
	local cfg = Weapons.Flares
	for salvoId, salvo in salvos do
		if now > salvo.burnout then
			salvos[salvoId] = nil
			continue
		end
		for _, f in flights do
			if f.target ~= salvo.carrier or f.decoy or salvo.tried[f.id] then
				continue
			end
			for index, flare in salvo.list do
				local age = now - flare.born
				local toFlare = Flares.at(flare, now) - f.state.pos
				if age >= 0 and age < Flares.Burn and toFlare.Magnitude < cfg.Range and toFlare.Unit:Dot(f.state.forward) > math.cos(cfg.Cone) then
					salvo.tried[f.id] = true
					if random:NextNumber() < salvo.chance then
						f.decoy = flare
						missileRemote:FireAllClients("decoy", f.id, salvoId, index)
					end
					break
				end
			end
		end
	end
end

-- Enemy drones fight back against seekers: a hard break and a fan of flares.
local function evade(target: Model, now: number)
	local last = target:GetAttribute("BreakAt") :: number?
	if last and now - last < BREAK_COOLDOWN then
		return
	end
	target:SetAttribute("BreakAt", now)
	target:SetAttribute("BreakSide", if random:NextNumber() < 0.5 then -1 else 1)
	local root = target.PrimaryPart :: BasePart
	enemyShots += 1
	local id = `t{enemyShots}`
	local list = Flares.salvo(root.Position, root.CFrame, TargetPaths.velocity(target, now), Weapons.Flares.PerSalvo, now, random)
	addSalvo(id, list, target, Weapons.Flares.EnemyDecoy)
	missileRemote:FireAllClients("flares", id, list)
end

-- Where a missile steers this frame. A flare that burns out lets go of its missile: it finds
-- its real target again if that's still near the nose, else flies on to where the flare was.
local function aim(f: Flight, now: number): (Vector3?, Vector3?)
	local flare = f.decoy
	if flare then
		local pos = Flares.at(flare, now)
		if now - flare.born < Flares.Burn then
			return pos, Flares.velocity(flare, now)
		end
		f.decoy = nil
		f.lastSeen = pos
		local target = f.target
		local keep = target ~= nil
			and alive(target)
			and ((target.PrimaryPart :: BasePart).Position - f.state.pos).Unit:Dot(f.state.forward) > math.cos(REACQUIRE_CONE)
		if not keep then
			f.target = nil
		end
		missileRemote:FireAllClients("release", f.id, keep)
	end
	local target = f.target
	if target and alive(target) then
		f.lastSeen = (target.PrimaryPart :: BasePart).Position
		return f.lastSeen, TargetPaths.velocity(target, now)
	end
	return f.lastSeen, if f.lastSeen then Vector3.zero else nil -- target gone: fly to where it was
end

local function onFire(player: Player, name: unknown, shotId: unknown, origin: unknown, direction: unknown, target: unknown)
	-- Everything from the client is untrusted: check types, NaNs and ranges before use.
	if typeof(name) ~= "string" or not table.find(Weapons.Order, name) then
		return -- also keeps players off enemy-only specs
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
	local drone = drones:FindFirstChild(player.Name) :: Model?
	local root = drone and drone.PrimaryPart
	if not drone or not root or drone:GetAttribute("Down") then
		return
	end

	local now = workspace:GetServerTimeNow()
	local slot = slotFor(player, name, spec, now)
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

-- Flares and the kamikaze detonation. Same rules: never trust what the client sends.
local function onAction(player: Player, action: unknown, a: unknown, b: unknown, c: unknown, d: unknown)
	local drone = drones:FindFirstChild(player.Name) :: Model?
	local root = drone and drone.PrimaryPart
	if not drone or not root or drone:GetAttribute("Down") then
		return
	end
	local slack = LAUNCH_SLACK + root.AssemblyLinearVelocity.Magnitude * 0.3
	local now = workspace:GetServerTimeNow()

	if action == "detonate" then
		-- Go off where the pilot saw it, if that's plausibly where we think the drone is.
		local at = if typeof(a) == "Vector3" and a == a and (a - root.Position).Magnitude < slack then a else root.Position
		down(drone)
		explode(`{player.UserId}:kamikaze`, at, Weapons.Kamikaze, player)
	elseif action == "flares" then
		local cfg = Weapons.Flares
		if typeof(a) ~= "number" or typeof(b) ~= "Vector3" or typeof(c) ~= "table" or typeof(d) ~= "number" then
			return
		end
		local id = `{player.UserId}:f{a}`
		if salvos[id] or b ~= b or d ~= d or (b - root.Position).Magnitude > slack then
			return
		end
		-- The client picks the fan so its flares appear instantly; we only bound it.
		local kicks = c :: { unknown }
		local base = root.AssemblyLinearVelocity * 0.7
		local born = if math.abs(d - now) < 0.5 then d else now
		local list: { Flares.Flare } = {}
		for i = 1, cfg.PerSalvo do
			local v = kicks[i]
			if typeof(v) ~= "Vector3" or v ~= v or (v - base).Magnitude > 80 then
				return
			end
			list[i] = { origin = b, velocity = v, born = born + (i - 1) * 0.12 }
		end
		if not Weapons.tryFire(slotFor(player, "Flares", cfg, now), cfg, now, LATENCY_GRACE) then
			return
		end
		addSalvo(id, list, drone, cfg.Decoy)
		for _, other in Players:GetPlayers() do
			if other ~= player then
				missileRemote:FireClient(other, "flares", id, list)
			end
		end
	end
end

-- Enemy launch (SAM sites).
function Combat.launch(name: string, origin: Vector3, forward: Vector3, target: Model, launcher: Instance)
	local spec = Weapons.Specs[name]
	enemyShots += 1
	local id = `e{enemyShots}`
	local velocity = forward * spec.LaunchSpeed
	flights[id] = {
		id = id,
		name = name,
		spec = spec,
		state = Missile.new(origin, velocity, forward),
		launcher = launcher,
		target = target,
		lastSeen = (target.PrimaryPart :: BasePart).Position,
	}
	missileRemote:FireAllClients("spawn", id, name, origin, velocity, forward, target)
end

local function step(dt: number)
	local now = workspace:GetServerTimeNow()
	TargetPaths.animate(now)
	decoys(now)
	for _, f in flights do
		local s = f.state
		local aimPos, aimVel = aim(f, now)
		local target = f.target
		if f.owner and target and not f.decoy and target:GetAttribute("Kind") == "Drone" and aimPos and (aimPos - s.pos).Magnitude < BREAK_RANGE then
			evade(target, now)
		end

		local before = s.pos
		Missile.step(s, f.spec, dt, aimPos, aimVel)
		local travel = s.pos - before
		rayParams.FilterDescendantsInstances = { (if f.owner then drones:FindFirstChild(f.owner.Name) else f.launcher) :: Instance }
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
	wallParams.FilterDescendantsInstances = { workspace:WaitForChild("Range") }
	fireRemote.OnServerEvent:Connect(onFire)
	actionRemote.OnServerEvent:Connect(onAction)
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(player)
		slots[player] = nil
	end)
end

return Combat
