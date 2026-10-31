-- Draws missiles, flares and explosions. Every missile here is flown by the shared Missile code,
-- so it tracks the server's copy closely. Your own shots predict their impacts so they never
-- visibly sail through a target; the server's "boom" has the final say and corrects a wrong guess.
-- Flares follow the shared closed-form path, so they need no updates after launch.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local Missile = require(Shared:WaitForChild("Missile"))
local Flares = require(Shared:WaitForChild("Flares"))
local TargetPaths = require(Shared:WaitForChild("TargetPaths"))

local MissileFx = {}
MissileFx.__index = MissileFx

local FORWARD = CFrame.Angles(0, math.rad(90), 0)
local VERTICAL = CFrame.Angles(0, 0, math.rad(90))
local SPEED_OF_SOUND = 1225 -- studs/s (343 m/s at 0.28 m per stud)
local TEXTURES = "rbxasset://textures/particles/"
local random = Random.new()

local LOOKS = {
	Rockets = { length = 1.2, diameter = 0.22, body = Color3.fromRGB(200, 202, 208), nose = Color3.fromRGB(60, 62, 70), smoke = 0.7, flame = 0.35 },
	Seeker = { length = 2.2, diameter = 0.32, body = Color3.fromRGB(236, 236, 240), nose = Color3.fromRGB(226, 52, 64), smoke = 2.2, flame = 0.55 },
	TopAttack = { length = 2.6, diameter = 0.42, body = Color3.fromRGB(96, 104, 70), nose = Color3.fromRGB(40, 42, 38), smoke = 2.8, flame = 0.6 },
	-- A fat, lingering smoke column so you can see a SAM coming from far off.
	SAM = { length = 3.4, diameter = 0.5, body = Color3.fromRGB(214, 208, 192), nose = Color3.fromRGB(70, 72, 60), smoke = 5, flame = 0.8, trail = 1.6 },
}

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for k, v in props do
		(p :: any)[k] = v
	end
	return p
end

local function tween(inst: Instance, time: number, goal: { [string]: any })
	TweenService:Create(inst, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

local function numbers(...: number): NumberSequence
	local args = { ... }
	local points = {}
	for i, v in args do
		table.insert(points, NumberSequenceKeypoint.new((i - 1) / (#args - 1), v))
	end
	return NumberSequence.new(points)
end

-- One airframe per weapon, cloned for every shot.
local templates: { [string]: Model } = {}
local function template(name: string): Model
	if templates[name] then
		return templates[name]
	end
	local look = LOOKS[name]
	local d, half = look.diameter, look.length / 2
	local model = Instance.new("Model")
	local root = part({ Name = "Root", Size = Vector3.one * 0.1, Transparency = 1 })
	root.Parent = model
	model.PrimaryPart = root
	local function add(props: { [string]: any }): Part
		local p = part(props)
		p.Anchored = false
		p.Massless = true
		p.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
		return p
	end

	add({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(look.length, d, d), CFrame = FORWARD, Color = look.body, Material = Enum.Material.Metal })
	add({ Shape = Enum.PartType.Ball, Size = Vector3.one * d, CFrame = CFrame.new(0, 0, -half), Color = look.nose })
	for i = 0, 3 do
		local cf = CFrame.new(0, 0, half - d * 0.6) * CFrame.Angles(0, 0, i * math.pi / 2) * CFrame.new(d * 0.8, 0, 0)
		add({ Size = Vector3.new(d * 1.6, 0.03, d * 1.2), CFrame = cf, Color = look.nose })
	end
	local flame = add({
		Name = "Flame",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * look.flame,
		CFrame = CFrame.new(0, 0, half + look.flame * 0.4),
		Color = Color3.fromRGB(255, 190, 110),
		Material = Enum.Material.Neon,
		Transparency = 1,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 90)
	light.Range = look.flame * 25
	light.Brightness = 2
	light.Enabled = false
	light.Parent = flame

	local trailHalf = look.trail or d * 0.9
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, trailHalf, half)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -trailHalf, half)
	a1.Parent = root
	local trail = Instance.new("Trail")
	trail.Name = "Smoke"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = true
	trail.Lifetime = look.smoke
	trail.MinLength = 0.1
	trail.Texture = TEXTURES .. "smoke_main.dds"
	trail.Color = ColorSequence.new(Color3.fromRGB(240, 240, 240), Color3.fromRGB(175, 175, 180))
	trail.Transparency = numbers(0.12, 1)
	trail.WidthScale = numbers(1, 7)
	trail.Enabled = false
	trail.Parent = root

	templates[name] = model
	return model
end

function MissileFx.new(onExplosion: (Vector3, number) -> ())
	local self = setmetatable({}, MissileFx)
	self.folder = Instance.new("Folder")
	self.folder.Name = "MissileFx"
	self.folder.Parent = workspace
	self.flights = {}
	self.salvos = {}
	self.onExplosion = onExplosion
	self.ray = RaycastParams.new()
	self.ray.FilterType = Enum.RaycastFilterType.Exclude
	self.ray.FilterDescendantsInstances = { workspace:WaitForChild("Drones"), self.folder }
	return self
end

-- `predict` is for your own shots: draw their impacts without waiting for the server.
function MissileFx:spawn(id: string, name: string, origin: Vector3, velocity: Vector3, direction: Vector3, target: Model?, predict: boolean?)
	if self.flights[id] then
		return
	end
	local model = template(name):Clone()
	local root = model.PrimaryPart :: BasePart
	root.CFrame = CFrame.lookAt(origin, origin + direction)
	model.Parent = self.folder

	local launch = Instance.new("Sound")
	launch.SoundId = Config.Audio.Launch
	launch.Volume = if name == "Rockets" then 0.3 else 0.8
	launch.PlaybackSpeed = if name == "Rockets" then random:NextNumber(1.4, 1.6) elseif name == "SAM" then 0.7 else 1
	launch.RollOffMaxDistance = if name == "SAM" then 1500 else 600
	launch.Parent = root
	launch:Play()

	local flame = model:FindFirstChild("Flame") :: BasePart
	self.flights[id] = {
		spec = Weapons.Specs[name],
		state = Missile.new(origin, velocity, direction),
		model = model,
		root = root,
		flame = flame,
		light = flame:FindFirstChildOfClass("PointLight"),
		trail = root:FindFirstChild("Smoke"),
		target = target,
		lastSeen = target and target.PrimaryPart and target.PrimaryPart.Position,
		predict = predict == true,
		done = false,
		born = os.clock(),
	}
end

-- A flare salvo: burning balls with a light and a smoke trail, placed every frame from the
-- shared path. `list` is the same table the server decoys against.
function MissileFx:flares(id: string, list: { Flares.Flare })
	if self.salvos[id] then
		return
	end
	local balls = {}
	for i, flare in list do
		local ball = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.2, CFrame = CFrame.new(flare.origin), Color = Color3.fromRGB(255, 240, 210), Material = Enum.Material.Neon, Transparency = 1 })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 200, 140)
		light.Range = 24
		light.Brightness = 3
		light.Enabled = false
		light.Parent = ball
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.4, 0)
		a0.Parent = ball
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.4, 0)
		a1.Parent = ball
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.FaceCamera = true
		trail.Lifetime = 1.6
		trail.Texture = TEXTURES .. "smoke_main.dds"
		trail.Color = ColorSequence.new(Color3.fromRGB(255, 250, 240), Color3.fromRGB(190, 190, 195))
		trail.Transparency = numbers(0.2, 1)
		trail.WidthScale = numbers(1, 5)
		trail.Enabled = false
		trail.Parent = ball
		ball.Parent = self.folder
		balls[i] = { part = ball, light = light, trail = trail }
	end
	self.salvos[id] = { list = list, balls = balls }

	local pop = Instance.new("Sound")
	pop.SoundId = Config.Audio.Launch
	pop.Volume = 0.35
	pop.PlaybackSpeed = 2.4
	pop.Parent = balls[1].part
	pop:Play()
end

-- The server pulled a missile onto a flare, or the flare burnt out and let it go.
function MissileFx:decoy(id: string, salvoId: string, index: number)
	local f, salvo = self.flights[id], self.salvos[salvoId]
	if f and salvo then
		f.decoy = salvo.list[index]
	end
end

function MissileFx:release(id: string, keep: boolean)
	local f = self.flights[id]
	if f and f.decoy then
		f.lastSeen = Flares.at(f.decoy, workspace:GetServerTimeNow())
		f.decoy = nil
		if not keep then
			f.target = nil
		end
	end
end

-- The nearest enemy missile homing on `drone`, for the missile warning.
function MissileFx:threat(drone: Model): Vector3?
	local best, bestDist = nil, math.huge
	for _, f in self.flights do
		if not f.done and f.target == drone and not f.decoy then
			local dist = (f.state.pos - drone.PrimaryPart.Position).Magnitude
			if dist < bestDist then
				best, bestDist = f.state.pos, dist
			end
		end
	end
	return best
end

local function updateSalvos(salvos, now: number)
	for id, salvo in salvos do
		local over = true
		for i, flare in salvo.list do
			local ball = salvo.balls[i]
			local age = now - flare.born
			local burning = age >= 0 and age < Flares.Burn
			over = over and age > Flares.Burn + ball.trail.Lifetime
			ball.part.CFrame = CFrame.new(Flares.at(flare, now))
			ball.part.Transparency = if burning then 0 else 1
			ball.part.Size = Vector3.one * (if burning then 1.1 - 0.6 * age / Flares.Burn else 0.1)
			ball.light.Enabled = burning
			ball.trail.Enabled = burning
		end
		if over then
			for _, ball in salvo.balls do
				ball.part:Destroy()
			end
			salvos[id] = nil
		end
	end
end

-- Stops drawing the airframe but lets its smoke trail drift and fade.
function MissileFx:_retire(f)
	f.done = true
	for _, p in f.model:GetDescendants() do
		if p:IsA("BasePart") then
			p.Transparency = 1
		end
	end
	f.light.Enabled = false
	f.trail.Enabled = false
	Debris:AddItem(f.model, f.trail.Lifetime)
end

function MissileFx:update(dt: number)
	local now = workspace:GetServerTimeNow()
	updateSalvos(self.salvos, now)
	for id, f in self.flights do
		if f.done then
			if os.clock() - f.born > f.spec.Lifetime + 5 then
				self.flights[id] = nil -- never heard back; stop waiting
			end
			continue
		end
		local target = f.target
		local aimPos, aimVel = nil, nil
		if f.decoy then
			aimPos, aimVel = Flares.at(f.decoy, now), Flares.velocity(f.decoy, now)
		elseif target and target.Parent and target.PrimaryPart and target:GetAttribute("Health") > 0 and not target:GetAttribute("Down") then
			f.lastSeen = target.PrimaryPart.Position
			aimPos, aimVel = f.lastSeen, TargetPaths.velocity(target, now)
		elseif f.lastSeen then
			aimPos, aimVel = f.lastSeen, Vector3.zero
		end

		local s = f.state
		local before = s.pos
		Missile.step(s, f.spec, dt, aimPos, aimVel)
		f.root.CFrame = CFrame.lookAt(s.pos, s.pos + s.forward)
		local burning = Missile.thrustAt(f.spec, s.age) > 0
		f.flame.Transparency = if burning then 0 else 1
		f.light.Enabled = burning
		f.trail.Enabled = s.age >= f.spec.IgnitionDelay

		-- Predict the impact so the shooter sees it now rather than a round trip later. Anyone
		-- else's missile (a SAM coming for you) just stops there and waits for the server's boom.
		local travel = s.pos - before
		local hit = if s.age > 0.1 and travel.Magnitude > 1e-3 then workspace:Spherecast(before, 0.5, travel, self.ray) else nil
		local at = hit and hit.Position
		if not at and aimPos and f.spec.Fuse > 0 then
			local closest = Missile.closestOnSegment(before, s.pos, aimPos)
			if (closest - aimPos).Magnitude < f.spec.Fuse then
				at = closest
			end
		end
		if at and f.predict then
			f.predicted = at
			self:_retire(f)
			self:explode(at, f.spec.BlastRadius)
		elseif at then
			self:_retire(f)
		elseif s.age > f.spec.Lifetime + 1 then
			self:_retire(f)
		end
	end
end

-- The server's verdict. Skip the explosion if our prediction already put one here.
function MissileFx:boom(id: string, at: Vector3, radius: number)
	local f = self.flights[id]
	self.flights[id] = nil
	if f and not f.done then
		self:_retire(f)
	end
	if not (f and f.predicted and (f.predicted - at).Magnitude < 25) then
		self:explode(at, radius)
	end
end

function MissileFx:cancel(id: string)
	local f = self.flights[id]
	if f then
		self.flights[id] = nil
		f.model:Destroy()
	end
end

function MissileFx:explode(at: Vector3, radius: number)
	local holder = part({ Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(at) })
	holder.Parent = self.folder

	local flash = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * radius * 0.5, CFrame = CFrame.new(at), Color = Color3.fromRGB(255, 214, 150), Material = Enum.Material.Neon, Transparency = 0.1 })
	flash.Parent = holder
	tween(flash, 0.3, { Size = Vector3.one * radius * 1.2, Transparency = 1 })

	-- Shockwave ring only for missile-sized blasts; a rocket salvo would stack into a white disc.
	if radius >= 12 then
		local ring = part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, radius * 0.6, radius * 0.6), CFrame = CFrame.new(at) * VERTICAL, Color = Color3.fromRGB(255, 240, 220), Material = Enum.Material.Neon, Transparency = 0.45 })
		ring.Parent = holder
		tween(ring, 0.45, { Size = Vector3.new(0.2, radius * 3.5, radius * 3.5), Transparency = 1 })
	end

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 90)
	light.Range = radius * 2.5
	light.Brightness = radius * 0.6
	light.Parent = holder
	tween(light, 0.6, { Brightness = 0 })

	local emitterAt = Instance.new("Attachment")
	emitterAt.Parent = holder
	local function burst(count: number, props: { [string]: any })
		local e = Instance.new("ParticleEmitter")
		e.Rate = 0
		e.SpreadAngle = Vector2.new(180, 180)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-90, 90)
		for k, v in props do
			(e :: any)[k] = v
		end
		e.Parent = emitterAt
		e:Emit(count)
	end
	burst(24, {
		Texture = TEXTURES .. "fire_main.dds",
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 226, 160)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 110, 40)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(70, 30, 20)),
		}),
		LightEmission = 1,
		Size = numbers(radius * 0.25, radius * 0.7),
		Transparency = numbers(0.1, 1),
		Lifetime = NumberRange.new(0.35, 0.7),
		Speed = NumberRange.new(radius * 1.5, radius * 4),
		Drag = 4,
	})
	burst(14, {
		Texture = TEXTURES .. "smoke_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(70, 68, 66), Color3.fromRGB(40, 40, 40)),
		Size = numbers(radius * 0.35, radius * 1.3),
		Transparency = numbers(0.25, 1),
		Lifetime = NumberRange.new(1.8, 3),
		Speed = NumberRange.new(radius * 0.6, radius * 1.6),
		Drag = 2,
		Acceleration = Vector3.new(0, 5, 0),
	})
	burst(30, {
		Texture = TEXTURES .. "sparkles_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 200, 120)),
		LightEmission = 1,
		Size = numbers(0.4, 0),
		Lifetime = NumberRange.new(0.4, 0.9),
		Speed = NumberRange.new(radius * 4, radius * 9),
		Drag = 1.5,
		Acceleration = Vector3.new(0, -60, 0),
	})

	-- A few chunks thrown out (client-only physics)
	for _ = 1, math.round(radius / 3) do
		local chunk = part({ Size = Vector3.one * random:NextNumber(0.3, 0.8), CFrame = CFrame.new(at), Color = Color3.fromRGB(40, 38, 36) })
		chunk.Anchored = false
		chunk.CanCollide = true
		chunk.Parent = self.folder
		chunk.AssemblyLinearVelocity = random:NextUnitVector() * random:NextNumber(radius * 3, radius * 6) + Vector3.new(0, radius * 3, 0)
		chunk.AssemblyAngularVelocity = random:NextUnitVector() * 20
		Debris:AddItem(chunk, 3)
	end

	-- Sound travels: far explosions are seen before they're heard.
	local sound = Instance.new("Sound")
	sound.SoundId = Config.Audio.Explosion
	sound.Volume = 0.9
	sound.PlaybackSpeed = random:NextNumber(0.9, 1.1) * (if radius < 10 then 1.25 else 1)
	sound.RollOffMinDistance = 20
	sound.RollOffMaxDistance = 1200
	sound.Parent = holder
	task.delay((at - workspace.CurrentCamera.CFrame.Position).Magnitude / SPEED_OF_SOUND, function()
		sound:Play()
	end)

	Debris:AddItem(holder, 4)
	self.onExplosion(at, radius)
end

return MissileFx
