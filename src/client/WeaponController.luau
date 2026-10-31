-- Weapon selection, the lock-on seeker, firing, flares, the kamikaze switch and the radar
-- warning receiver. Shots are drawn on this client the moment you fire and sent to the server,
-- which re-flies them and has the final word on hits.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local Flares = require(Shared:WaitForChild("Flares"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireRemote = remotes:WaitForChild("FireWeapon") :: RemoteEvent
local actionRemote = remotes:WaitForChild("DroneAction") :: RemoteEvent
local missileRemote = remotes:WaitForChild("Missiles") :: RemoteEvent

local WeaponController = {}
WeaponController.__index = WeaponController

local player = Players.LocalPlayer
local random = Random.new()

function WeaponController.new(drone: Model, fx)
	local self = setmetatable({}, WeaponController)
	local root = drone.PrimaryPart :: BasePart
	local now = workspace:GetServerTimeNow()
	self.drone = drone
	self.root = root
	self.fx = fx
	self.selected = Weapons.Order[1]
	self.slots = {}
	for _, name in Weapons.Order do
		self.slots[name] = Weapons.newSlot(Weapons.Specs[name], now)
	end
	self.slots.Flares = Weapons.newSlot(Weapons.Flares, now)
	self.salvos = 0
	self.threat, self.threatAt = nil, nil -- "RADAR" or "MISSILE", and where it's coming from
	self.lastGuided = nil -- id of your newest seeker or top-attack, for the missile cam
	self.hitAt, self.hitKill = -math.huge, false -- for the hit marker
	self.onKill = nil :: ((id: string, at: Vector3) -> ())?
	self.locks = {} -- confirmed locks, in the order they were made
	self.candidate = nil -- target currently being locked
	self.progress = 0
	self.queue = {} -- volley shots waiting their turn
	self.shots = 0
	self.side = 0
	self.triggerWas = false
	self.message, self.messageAt, self.messageWarn = "", -math.huge, false
	self.kills = 0

	local seekerRails = { root:WaitForChild("RailLeft"), root:WaitForChild("RailRight") }
	self.launchers = {
		Rockets = { root:WaitForChild("PodLeft"), root:WaitForChild("PodRight") },
		Seeker = seekerRails,
		TopAttack = seekerRails,
	}
	self.railParts = {}
	for _, p in drone:GetDescendants() do
		if p:IsA("BasePart") and p:GetAttribute("Rail") then
			table.insert(self.railParts, p)
		end
	end

	self.ray = RaycastParams.new()
	self.ray.FilterType = Enum.RaycastFilterType.Exclude
	self.beep = Instance.new("Sound")
	self.beep.SoundId = Config.Audio.LockBeep
	self.beep.Volume = 0.3
	self.beep.Parent = SoundService
	self.beepAt = 0
	self.warn = self.beep:Clone()
	self.warn.Volume = 0.45
	self.warn.Parent = SoundService
	self.warnAt = 0

	missileRemote.OnClientEvent:Connect(function(kind: string, ...)
		self:_onServer(kind, ...)
	end)
	return self
end

function WeaponController:select(name: string)
	if name ~= self.selected then
		self.selected = name
		self:_clearLocks()
	end
end

function WeaponController:cycle()
	local i = table.find(Weapons.Order, self.selected) or 1
	self:select(Weapons.Order[i % #Weapons.Order + 1])
end

function WeaponController:_clearLocks()
	table.clear(self.locks)
	self.candidate = nil
	self.progress = 0
end

function WeaponController:_say(text: string, warn: boolean?)
	self.message, self.messageAt, self.messageWarn = text, os.clock(), warn == true
end

-- Angle off the reticle if the seeker can see the target inside `cone`, else nil.
function WeaponController:_visible(target: Model, eye: CFrame, cone: number, range: number): number?
	local root = target.PrimaryPart
	if not root or (target:GetAttribute("Health") :: number) <= 0 then
		return nil
	end
	if Weapons.Specs[self.selected].Guidance == "TopAttack" and target:GetAttribute("Kind") == "Drone" then
		return nil -- a top-down dive can't catch an aircraft
	end
	local offset = root.Position - eye.Position
	local dist = offset.Magnitude
	if dist > range then
		return nil
	end
	local angle = math.acos(math.clamp(eye.LookVector:Dot(offset / dist), -1, 1))
	if angle > cone then
		return nil
	end
	local hit = workspace:Raycast(eye.Position, offset, self.ray)
	if hit and not hit.Instance:IsDescendantOf(target) then
		return nil
	end
	return angle
end

function WeaponController:_updateSeeker(dt: number, eye: CFrame)
	local spec = Weapons.Specs[self.selected]
	if spec.MaxLocks == 0 then
		self:_clearLocks()
		return
	end
	-- Locks survive inside the wide tracking cone; new ones must start near the reticle.
	for i = #self.locks, 1, -1 do
		if not self:_visible(self.locks[i], eye, spec.TrackCone, spec.Range) then
			table.remove(self.locks, i)
		end
	end
	local best, bestAngle = nil, math.huge
	if #self.locks < spec.MaxLocks then
		for _, target in CollectionService:GetTagged("Target") do
			if not table.find(self.locks, target) then
				local angle = self:_visible(target, eye, spec.SeekerCone, spec.Range)
				if angle and angle < bestAngle then
					best, bestAngle = target, angle
				end
			end
		end
	end
	if best ~= self.candidate then
		self.candidate, self.progress = best, 0
	end
	if best then
		self.progress += dt / spec.LockTime
		if self.progress >= 1 then
			table.insert(self.locks, best)
			self.candidate, self.progress = nil, 0
		end
	end
end

-- Beeps quicken as a lock builds, then hold a fast high tone once something is locked.
function WeaponController:_updateTone()
	local interval, pitch
	if self.candidate then
		interval, pitch = 0.32 - 0.22 * self.progress, 1 + 0.3 * self.progress
	elseif #self.locks > 0 then
		interval, pitch = 0.08, 1.6
	else
		return
	end
	if os.clock() - self.beepAt >= interval then
		self.beepAt = os.clock()
		self.beep.PlaybackSpeed = pitch
		self.beep:Play()
	end
end

-- Radar warning receiver: a slow low tone while a SAM holds a lock on you, a frantic one once
-- its missile is in the air.
function WeaponController:_updateWarning()
	local missile = self.fx:threat(self.drone)
	local radar = nil
	if not missile then
		for _, site in CollectionService:GetTagged("Target") do
			if site:GetAttribute("Tracking") == player.UserId and site.PrimaryPart then
				radar = site.PrimaryPart.Position
				break
			end
		end
	end
	self.threat = if missile then "MISSILE" elseif radar then "RADAR" else nil
	self.threatAt = missile or radar
	if self.threat then
		local interval = if missile then 0.11 else 0.5
		if os.clock() - self.warnAt >= interval then
			self.warnAt = os.clock()
			self.warn.PlaybackSpeed = if missile then 0.8 else 0.55
			self.warn:Play()
		end
	end
end

function WeaponController:dropFlares()
	local cfg = Weapons.Flares
	local now = workspace:GetServerTimeNow()
	if self.drone:GetAttribute("Down") or not Weapons.tryFire(self.slots.Flares, cfg, now, 0) then
		return
	end
	self.salvos += 1
	local root = self.root
	local origin = root.Position - root.CFrame.UpVector
	local list = Flares.salvo(origin, root.CFrame, root.AssemblyLinearVelocity, cfg.PerSalvo, now, random)
	local kicks = {}
	for i, flare in list do
		kicks[i] = flare.velocity
	end
	self.fx:flares(`{player.UserId}:f{self.salvos}`, list)
	actionRemote:FireServer("flares", self.salvos, origin, kicks, now)
	self:_say("FLARES")
end

-- Kamikaze: the server sets off the warhead where we say the drone is. Returns whether it went.
function WeaponController:detonate(): boolean
	if self.drone:GetAttribute("Down") then
		return false
	end
	actionRemote:FireServer("detonate", self.root.Position)
	self:_clearLocks()
	return true
end

function WeaponController:_launchDirection(spec: Weapons.Spec, origin: Vector3): Vector3
	local eye = workspace.CurrentCamera.CFrame
	if spec.Guidance == "None" then
		-- Converge on whatever sits under the reticle, with a little salvo spread.
		local hit = workspace:Raycast(eye.Position, eye.LookVector * spec.Range, self.ray)
		local aim = if hit then hit.Position else eye.Position + eye.LookVector * spec.Range
		local cone = CFrame.lookAt(Vector3.zero, aim - origin)
			* CFrame.Angles(0, 0, random:NextNumber(0, math.pi * 2))
			* CFrame.Angles(random:NextNumber(0, spec.Spread), 0, 0)
		return cone.LookVector
	end
	-- Top-attack climbs from the horizon whatever you aim at; the seeker kicks up off the aim line.
	local flat = Vector3.new(eye.LookVector.X, 0, eye.LookVector.Z)
	local base = if spec.Guidance == "TopAttack" and flat.Magnitude > 0.1 then flat else eye.LookVector
	return (CFrame.lookAt(Vector3.zero, base) * CFrame.Angles(spec.LaunchPitch, 0, 0)).LookVector
end

function WeaponController:_fire(name: string, target: Model?, now: number)
	local spec = Weapons.Specs[name]
	if not Weapons.tryFire(self.slots[name], spec, now, 0) then
		return
	end
	local launchers = self.launchers[name]
	self.side = self.side % #launchers + 1
	local origin = launchers[self.side].WorldPosition
	local direction = self:_launchDirection(spec, origin)
	self.shots += 1
	local id = `{player.UserId}:{self.shots}`
	local velocity = self.root.AssemblyLinearVelocity + direction * spec.LaunchSpeed
	self.fx:spawn(id, name, origin, velocity, direction, target, true)
	if spec.Guidance ~= "None" then
		self.lastGuided = id
	end
	fireRemote:FireServer(name, self.shots, origin, direction, target)
end

-- One missile per lock, rippled off the rails.
function WeaponController:_volley(now: number)
	local spec = Weapons.Specs[self.selected]
	if #self.locks == 0 then
		self:_say("NO LOCK", true)
		return
	end
	local slot = self.slots[self.selected]
	Weapons.refill(slot, spec, now)
	if slot.ammo < 1 then
		self:_say("RELOADING", true)
		return
	end
	for i, target in self.locks do
		if i > slot.ammo then
			break
		end
		table.insert(
			self.queue,
			{ weapon = self.selected, target = target, at = now + (i - 1) * (spec.Interval + 0.01) }
		)
	end
	self:_clearLocks()
end

function WeaponController:update(dt: number)
	local now = workspace:GetServerTimeNow()
	local eye = workspace.CurrentCamera.CFrame
	self.ray.FilterDescendantsInstances = { workspace:FindFirstChild("Drones"), self.fx.folder, player.Character }
	self:_updateSeeker(dt, eye)
	self:_updateTone()
	self:_updateWarning()

	local spec = Weapons.Specs[self.selected]
	local trigger = not UserInputService:GetFocusedTextBox()
		and not self.drone:GetAttribute("Down")
		and not self.blocked -- the settings menu is open
		and (
			UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR1)
		)
	if spec.Guidance == "None" then
		if trigger then
			self:_fire(self.selected, nil, now)
		end
	elseif trigger and not self.triggerWas then
		self:_volley(now)
	end
	self.triggerWas = trigger

	while self.queue[1] and self.queue[1].at <= now do
		local shot = table.remove(self.queue, 1)
		if (shot.target:GetAttribute("Health") :: number) > 0 then
			self:_fire(shot.weapon, shot.target, now)
		end
	end

	-- Rail missiles vanish as they're spent.
	local railWeapon = if spec.Guidance == "None" then "Seeker" else self.selected
	Weapons.refill(self.slots[railWeapon], Weapons.Specs[railWeapon], now)
	local ammo = self.slots[railWeapon].ammo
	for _, p in self.railParts do
		p.LocalTransparencyModifier = if ammo >= p:GetAttribute("Rail") then 0 else 1
	end
end

function WeaponController:_onServer(kind: string, ...)
	if kind == "spawn" then
		self.fx:spawn(...)
	elseif kind == "flares" then
		self.fx:flares(...)
	elseif kind == "decoy" then
		self.fx:decoy(...)
	elseif kind == "release" then
		self.fx:release(...)
	elseif kind == "boom" then
		local id, at, radius, ownerId, result = ...
		self.fx:boom(id, at, radius)
		if ownerId == player.UserId and result == "kill" then
			self.kills += 1
		end
		if ownerId == player.UserId and result then
			self:_say(if result == "kill" then "TARGET DESTROYED" else "HIT")
			self.beep.PlaybackSpeed = if result == "kill" then 2.2 else 1.9
			self.beep:Play()
			self.hitAt, self.hitKill = os.clock(), result == "kill"
			if result == "kill" and self.onKill then
				self.onKill(id, at)
			end
		end
	elseif kind == "cancel" then
		local id, name, ammo = ...
		self.fx:cancel(id)
		self.slots[name].ammo = ammo -- the server's count wins
	end
end

return WeaponController
