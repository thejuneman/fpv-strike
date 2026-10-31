-- Replay (P): the last 20 seconds, played back through an automatic director.
--
-- The recorder samples your drone, every missile, every burning flare and the targets 30 times a
-- second, and logs each explosion. Playback rebuilds them as local stand-ins (the real world
-- carries on untouched, your drone hovering where you left it) and cuts between a chase cam, a
-- long-lens tower cam on the ground, a slow orbit, and a missile cam whenever something
-- launches. C cuts to the next shot, P leaves.
--
-- Like a sports replay it goes straight to the action: playback starts a few seconds before the
-- first launch or explosion on the tape, and pressing P with missiles still in the air waits for
-- them to land so the tape has the hits.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Smooth = require(Shared:WaitForChild("Smooth"))

local Replay = {}
Replay.__index = Replay

local RATE = 30 -- samples per second
local SECONDS = 20
local SHOT_TIME = 3.5
local SHOTS = { "Chase", "Tower", "Orbit" }
local LINGER = 1.2 -- seconds to hold on the blast after a followed missile goes off
local LEAD_IN = 3 -- seconds of tape before the first action
local MAX_WAIT = 4 -- longest a replay request waits for missiles to land
local RED = Color3.fromRGB(255, 70, 80)
local BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
local random = Random.new()

local function bar(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for k, v in props do
		(f :: any)[k] = v
	end
	f.Parent = parent
	return f
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = BOLD
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextSize = 16
	for k, v in props do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

function Replay.new(drone: Model, ctrl, fx)
	local self = setmetatable({}, Replay)
	self.drone, self.ctrl, self.fx = drone, ctrl, fx
	self.frames = {}
	self.events = {}
	self.sampleAt = 0
	self.playing = false

	-- Log every explosion as it's drawn (but not the ones the replay itself redraws).
	local explode = fx.explode
	fx.explode = function(fxSelf, at: Vector3, radius: number)
		if not self.playing then
			table.insert(self.events, { t = os.clock(), at = at, radius = radius })
		end
		return explode(fxSelf, at, radius)
	end

	-- Letterbox, a REPLAY tag, the shot name and a timeline.
	local ui = Instance.new("ScreenGui")
	ui.Name = "Replay"
	ui.IgnoreGuiInset = true
	ui.ResetOnSpawn = false
	ui.DisplayOrder = 8
	ui.Enabled = false
	ui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	local black = Color3.new(0, 0, 0)
	local top = bar(ui, { Size = UDim2.fromScale(1, 0.1), BackgroundColor3 = black })
	local bottom = bar(ui, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.1),
		BackgroundColor3 = black,
	})
	self.tag = label(top, {
		Position = UDim2.new(0, 28, 0.5, -10),
		Size = UDim2.fromOffset(140, 20),
		Text = "● REPLAY",
		TextColor3 = RED,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	self.shotLabel = label(top, {
		Position = UDim2.new(0, 170, 0.5, -10),
		Size = UDim2.fromOffset(300, 20),
		TextSize = 14,
		TextColor3 = Color3.fromRGB(180, 186, 196),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local track = bar(bottom, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.new(1, -56, 0, 4),
		BackgroundColor3 = Color3.fromRGB(50, 54, 62),
	})
	self.timeline = bar(track, { Size = UDim2.fromScale(0, 1), BackgroundColor3 = RED })
	label(bottom, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromOffset(400, 16),
		TextSize = 12,
		Text = "C next camera  ·  P exit",
		TextColor3 = Color3.fromRGB(150, 158, 170),
	})
	self.ui = ui
	return self
end

-- Start now, or as soon as the missiles in the air have landed. Returns false if it can't.
function Replay:request(): boolean
	if self.playing or #self.frames < RATE then
		return false -- under a second of tape
	end
	self.pendingUntil = os.clock() + MAX_WAIT
	return true
end

function Replay:record()
	local now = os.clock()
	if self.playing or now < self.sampleAt then
		return
	end
	self.sampleAt = now + 1 / RATE

	local missiles = {}
	local flying = false
	for id, f in self.fx.flights do
		if not f.done then
			missiles[id] = { name = f.name, cf = f.root.CFrame }
			flying = flying or f.predict -- your own shots
		end
	end
	local flares = {}
	for _, salvo in self.fx.salvos do
		for _, ball in salvo.balls do
			if ball.part.Transparency < 1 then
				table.insert(flares, ball.part.Position)
			end
		end
	end
	local targets = {}
	for _, target in CollectionService:GetTagged("Target") do
		local root = target.PrimaryPart
		if root and root.Anchored then
			targets[target] = root.CFrame
		end
	end
	table.insert(self.frames, {
		t = now,
		drone = self.ctrl.root.CFrame,
		throttle = self.ctrl.throttle,
		missiles = missiles,
		flares = flares,
		targets = targets,
	})
	-- ponytail: shifting a 600-entry array each sample; a ring buffer if replays get longer
	while #self.frames > RATE * SECONDS do
		table.remove(self.frames, 1)
	end
	while self.events[1] and now - self.events[1].t > SECONDS do
		table.remove(self.events, 1)
	end

	-- A pending request starts once the last blast has had a moment to play out.
	local lastBlast = self.events[#self.events]
	local settled = not flying and not (lastBlast and now - lastBlast.t < 1.8)
	if self.pendingUntil and (settled or now > self.pendingUntil) then
		self.pendingUntil = nil
		self:start()
	end
end

-- The live drone hides while its stand-in flies the replay.
function Replay:_hideLive(hidden: boolean)
	for _, p in self.drone:GetDescendants() do
		if p:IsA("BasePart") then
			p.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

-- A visual-only copy of the drone: no forces, no sounds, no collisions.
function Replay:_ghost(): Model
	local ghost = self.drone:Clone()
	self.props = {}
	for _, d in ghost:GetDescendants() do
		if d:IsA("Constraint") or d:IsA("Sound") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanCollide, d.CanQuery, d.CanTouch = false, false, false
			d.LocalTransparencyModifier = 0
		elseif d:IsA("Motor6D") and d.Name:match("Prop$") then
			table.insert(self.props, d)
		end
	end
	ghost.PrimaryPart.Anchored = true
	ghost.Parent = self.folder
	return ghost
end

function Replay:start(): boolean
	if self.playing or #self.frames < RATE then
		return false -- under a second of tape
	end
	self.tape = table.clone(self.frames)
	self.tapeEvents = table.clone(self.events)
	self.t0 = self.tape[1].t
	self.duration = self.tape[#self.tape].t - self.t0
	self.head, self.cursor, self.eventCursor = 0, 1, 1

	-- Skip the quiet stretch: begin a little before the first launch or explosion.
	local first = self.tapeEvents[1] and self.tapeEvents[1].t
	for _, frame in self.tape do
		if next(frame.missiles) then
			first = math.min(first or frame.t, frame.t)
			break
		end
	end
	if first then
		self.head = math.max(first - LEAD_IN - self.t0, 0)
	end
	while self.tapeEvents[self.eventCursor] and self.tapeEvents[self.eventCursor].t < self.t0 + self.head do
		self.eventCursor += 1 -- before the playback starts
	end
	self.folder = Instance.new("Folder")
	self.folder.Name = "Replay"
	self.folder.Parent = workspace
	self.ghost = self:_ghost()
	-- Put the stand-in where playback starts before its trails can streak across the map.
	while self.cursor < #self.tape - 1 and self.tape[self.cursor + 1].t <= self.t0 + self.head do
		self.cursor += 1
	end
	self.ghost:PivotTo(self.tape[self.cursor].drone)
	for _, trail in self.ghost:GetDescendants() do
		if trail:IsA("Trail") then
			trail:Clear()
		end
	end
	self.missiles, self.balls = {}, {}
	self.spin = 0
	self.shotIndex = 0
	self.playing = true
	self:nextShot()
	self:_hideLive(true)
	self.ui.Enabled = true
	return true
end

function Replay:stop()
	self.playing = false
	self.folder:Destroy()
	self.ui.Enabled = false
	self:_hideLive(false)
end

-- Cut to the next shot in the rotation.
function Replay:nextShot()
	self.shotIndex = self.shotIndex % #SHOTS + 1
	self.shot = SHOTS[self.shotIndex]
	self.shotUntil = self.head + SHOT_TIME
	self.cut = true
	self.follow, self.lingerUntil = nil, nil
	if self.shot == "Tower" then
		-- Plant a camera on the ground off to one side of where the drone is heading.
		local cf = self.ghost.PrimaryPart.CFrame
		local heading = self.velocity or cf.LookVector * 20
		local flat = Vector3.new(heading.X, 0, heading.Z)
		local ahead = if flat.Magnitude > 1 then flat.Unit else Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
		local side = ahead:Cross(Vector3.yAxis) * (if random:NextNumber() < 0.5 then -1 else 1)
		local spot = cf.Position + ahead * 50 + side * random:NextNumber(35, 60)
		self.tower = Vector3.new(spot.X, 3, spot.Z)
	end
end

function Replay:_camera(dt: number, at: CFrame)
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	local pos = at.Position
	local wanted, fov
	local velocity = self.velocity or Vector3.zero
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local heading = if flat.Magnitude > 5 then flat.Unit else Vector3.new(at.LookVector.X, 0, at.LookVector.Z).Unit

	if self.shot == "Missile" then
		local model = self.missiles[self.follow]
		if model then
			local m = model.PrimaryPart.CFrame
			wanted, fov =
				CFrame.lookAt(m.Position - m.LookVector * 10 + Vector3.new(0, 2.5, 0), m.Position + m.LookVector * 30),
				60
			self.lastMissileCam = wanted
		else
			-- The missile went off: hold where we were and watch the blast.
			self.lingerUntil = self.lingerUntil or self.head + LINGER
			wanted, fov = self.lastMissileCam or cam.CFrame, 60
			if self.head > self.lingerUntil then
				self:nextShot()
				self:_camera(dt, at)
				return
			end
		end
	elseif self.shot == "Chase" then
		wanted, fov = CFrame.lookAt(pos - heading * 16 + Vector3.new(0, 5, 0), pos + heading * 12), 72
	elseif self.shot == "Orbit" then
		self.spin += dt * 0.45
		local around = Vector3.new(math.cos(self.spin), 0, math.sin(self.spin))
		wanted, fov = CFrame.lookAt(pos + around * 22 + Vector3.new(0, 7, 0), pos), 58
	else -- Tower: a long lens that zooms to keep the drone about the same size in frame
		local dist = (pos - self.tower).Magnitude
		wanted = CFrame.lookAt(self.tower, pos)
		fov = math.clamp(math.deg(2 * math.atan(14 / dist)), 6, 60)
	end

	if self.cut or self.shot == "Tower" then
		self.camCF, self.fov = wanted, fov
		self.cut = false
	else
		-- Stay locked to the subject's position (a fast drone would leave a lagging camera far
		-- behind) and only ease the rotation.
		local turn =
			self.camCF.Rotation:Lerp(wanted.Rotation, Smooth.alpha(if self.shot == "Missile" then 20 else 6, dt))
		self.camCF = CFrame.new(wanted.Position) * turn
		self.fov = Smooth.damp(self.fov, fov, 6, dt)
	end
	cam.CFrame = self.camCF
	cam.FieldOfView = self.fov
end

function Replay:update(dt: number)
	self.head += dt
	if self.head >= self.duration then
		self:stop()
		return
	end
	local tape = self.tape
	local t = self.t0 + self.head
	while self.cursor < #tape - 1 and tape[self.cursor + 1].t <= t do
		self.cursor += 1
	end
	local a = tape[self.cursor]
	local b = tape[self.cursor + 1] or a
	local alpha = if b.t > a.t then math.clamp((t - a.t) / (b.t - a.t), 0, 1) else 0

	-- Drone, with its props spun from the recorded throttle.
	local droneCF = a.drone:Lerp(b.drone, alpha)
	self.velocity = if b.t > a.t then (b.drone.Position - a.drone.Position) / (b.t - a.t) else Vector3.zero
	self.ghost:PivotTo(droneCF)
	self.propAngle = ((self.propAngle or 0) + (0.3 + a.throttle) * 140 * dt) % (math.pi * 2)
	for i, prop in self.props do
		prop.Transform = CFrame.Angles(0, self.propAngle * (if i % 2 == 0 then 1 else -1), 0)
	end

	-- Targets: the real models, moved locally until the replay ends.
	for model, cf in a.targets do
		local root = model.PrimaryPart
		if root and root.Anchored then
			root.CFrame = cf:Lerp(b.targets[model] or cf, alpha)
		end
	end

	-- Missiles: stand-ins appear on launch and leave their smoke behind when they go off.
	local launched = nil
	for id, m in a.missiles do
		local model = self.missiles[id]
		if not model then
			model = self.fx.template(m.name):Clone()
			model.PrimaryPart:FindFirstChild("Smoke").Enabled = true
			model:FindFirstChild("Flame").Transparency = 0
			model:PivotTo(m.cf)
			model.Parent = self.folder
			self.missiles[id] = model
			if m.name ~= "Rockets" then
				launched = id -- guided ones are worth following; a salvo would cut 16 times
			end
		end
		local nextCF = if b.missiles[id] then b.missiles[id].cf else m.cf
		model:PivotTo(m.cf:Lerp(nextCF, alpha))
	end
	for id, model in self.missiles do
		if not a.missiles[id] then
			model.PrimaryPart:FindFirstChild("Smoke").Enabled = false
			for _, p in model:GetDescendants() do
				if p:IsA("BasePart") then
					p.Transparency = 1
				end
			end
			Debris:AddItem(model, 4)
			self.missiles[id] = nil
		end
	end
	if launched then
		self.shot, self.follow, self.lingerUntil, self.cut = "Missile", launched, nil, true
	end

	-- Flares as plain burning balls.
	for i, pos in a.flares do
		local ball = self.balls[i]
		if not ball then
			ball = Instance.new("Part")
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.one
			ball.Material = Enum.Material.Neon
			ball.Color = Color3.fromRGB(255, 240, 210)
			ball.Anchored, ball.CanCollide, ball.CanQuery, ball.CanTouch = true, false, false, false
			ball.Parent = self.folder
			self.balls[i] = ball
		end
		ball.Transparency = 0
		ball.Position = pos
	end
	for i = #a.flares + 1, #self.balls do
		self.balls[i].Transparency = 1
	end

	-- Explosions, redrawn when the tape reaches them.
	local events = self.tapeEvents
	while events[self.eventCursor] and events[self.eventCursor].t <= t do
		local e = events[self.eventCursor]
		self.fx:explode(e.at, e.radius)
		self.eventCursor += 1
	end

	if self.shot ~= "Missile" and self.head > self.shotUntil then
		self:nextShot()
	end
	self:_camera(dt, droneCF)
	self.shotLabel.Text = string.upper(self.shot) .. " CAM"
	self.tag.TextTransparency = if math.floor(os.clock() * 2) % 2 == 0 then 0 else 0.4
	self.timeline.Size = UDim2.fromScale(self.head / self.duration, 1)
end

return Replay
