-- Flight and weapons HUD: mode, telemetry, aim reticle, flight-path marker, weapon panel,
-- seeker circle and lock diamonds, hit markers, the radar warning with its threat arrow, the
-- damage vignette, and analog video breakup (a weak link, or "signal lost"). In FPV the panels
-- give way to the goggles OSD.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local Osd = require(script.Parent:WaitForChild("Osd"))

local Hud = {}
Hud.__index = Hud

local ACCENT = Color3.fromRGB(62, 232, 255)
local WARN = Color3.fromRGB(255, 92, 92)
local AMBER = Color3.fromRGB(255, 186, 64)
local LOCK = Color3.fromRGB(255, 74, 90)
local DIM = Color3.fromRGB(150, 158, 170)
local WHITE = Color3.new(1, 1, 1)
local FONT = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium)
local BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
local METERS_PER_STUD = 0.28 -- also makes studs/s read almost exactly as km/h

local HINTS = {
	Aim = "MOUSE aim · WASD move · SPACE/CTRL up/down · SHIFT boost",
	Angle = "WASD tilt · MOUSE or Q/E yaw · SPACE/CTRL climb",
	Acro = "MOUSE pitch/roll · A/D yaw · W/S throttle · SHIFT full",
}
local COMMON = " · LMB fire · H controls"

-- The controls card: up when you join, gone once you launch, back on H.
local HELP = {
	{
		"FLY",
		{
			{ "Mouse", "aim" },
			{ "W A S D", "move" },
			{ "Space / Ctrl", "up, down" },
			{ "Shift", "boost" },
			{ "T", "flight mode: Aim, Angle, Acro" },
		},
	},
	{
		"FIGHT",
		{
			{ "Left mouse", "fire" },
			{ "1 2 3", "rockets, seeker, top-attack" },
			{ "G", "flares" },
			{ "R", "detonate the drone" },
		},
	},
	{
		"VIEW",
		{ { "F", "chase, FPV or orbit camera" }, { "V", "missile cam" }, { "P", "replay the last 20 seconds" } },
	},
	{
		"MORE",
		{ { "M", "settings" }, { "F2", "debug overlay" }, { "Backspace", "back to the pad" }, { "H", "this card" } },
	},
}
local STATIC_ROWS, STATIC_COLS = 48, 3

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function round(parent: Instance, radius: UDim?)
	make("UICorner", { CornerRadius = radius or UDim.new(1, 0) }, parent)
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextColor3 = WHITE,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	for k, v in props do
		(label :: any)[k] = v
	end
	return label
end

local function panel(parent: Instance, props: { [string]: any }): Frame
	local frame = make(
		"Frame",
		{ BackgroundColor3 = Color3.fromRGB(8, 10, 14), BackgroundTransparency = 0.35, BorderSizePixel = 0 },
		parent
	)
	round(frame, UDim.new(0, 6))
	make("UIStroke", { Color = ACCENT, Transparency = 0.75 }, frame)
	for k, v in props do
		(frame :: any)[k] = v
	end
	return frame
end

function Hud.new()
	local self = setmetatable({}, Hud)
	local gui = make("ScreenGui", {
		Name = "DroneHud",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))

	local top = panel(gui, { Position = UDim2.fromOffset(16, 16), Size = UDim2.fromOffset(260, 30) })
	self.status = text(
		top,
		{ Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0), FontFace = BOLD, TextColor3 = ACCENT }
	)

	local title = panel(
		gui,
		{ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 16), Size = UDim2.fromOffset(210, 46) }
	)
	text(title, {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 18),
		Text = "FPV STRIKE",
		FontFace = BOLD,
		TextSize = 16,
		TextColor3 = ACCENT,
	})
	text(title, {
		Position = UDim2.fromOffset(12, 25),
		Size = UDim2.new(1, -24, 0, 14),
		Text = "flight model · PN guidance",
		TextSize = 11,
		TextColor3 = DIM,
	})

	local tele = panel(
		gui,
		{ AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(200, 126) }
	)
	self.telemetry = text(tele, {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, 90),
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
		LineHeight = 1.15,
	})
	local barBack = make("Frame", {
		Position = UDim2.new(0, 12, 1, -18),
		Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = Color3.fromRGB(40, 44, 52),
		BorderSizePixel = 0,
	}, tele)
	round(barBack)
	self.throttleBar =
		make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, barBack)
	round(self.throttleBar)

	self.hints = text(gui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.new(1, -480, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		TextWrapped = true,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(205, 214, 224),
		TextStrokeTransparency = 0.6,
	})

	self.prompt = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.84),
		Size = UDim2.fromOffset(620, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 18,
		TextStrokeTransparency = 0.5,
		ZIndex = 60, -- readable over video breakup
	})

	-- Where the mouse is aiming
	self.reticle = make(
		"Frame",
		{ AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(28, 28), BackgroundTransparency = 1 },
		gui
	)
	round(self.reticle)
	make("UIStroke", { Color = ACCENT, Thickness = 1.5, Transparency = 0.1 }, self.reticle)
	local dot = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
	}, self.reticle)
	round(dot)

	-- Where the drone is actually going (flight-path marker, as on a jet's HUD)
	self.flightPath = make(
		"Frame",
		{ AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1 },
		gui
	)
	round(self.flightPath)
	make("UIStroke", { Color = WHITE, Thickness = 1.5, Transparency = 0.2 }, self.flightPath)
	local function tick(position: UDim2, size: Vector2, anchor: Vector2)
		make("Frame", {
			AnchorPoint = anchor,
			Position = position,
			Size = UDim2.fromOffset(size.X, size.Y),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
		}, self.flightPath)
	end
	tick(UDim2.new(0, -2, 0.5, 0), Vector2.new(8, 2), Vector2.new(1, 0.5))
	tick(UDim2.new(1, 2, 0.5, 0), Vector2.new(8, 2), Vector2.new(0, 0.5))
	tick(UDim2.new(0.5, 0, 0, -2), Vector2.new(2, 6), Vector2.new(0.5, 1))

	-- Weapons panel: one row per weapon (and the flares) with ammo and a reload bar
	local rows = table.clone(Weapons.Order)
	table.insert(rows, "Flares")
	local arms = panel(gui, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(210, 16 + #rows * 28),
	})
	self.rows = {}
	for i, name in rows do
		local spec = Weapons.Specs[name]
		local row = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 8 + (i - 1) * 28),
			Size = UDim2.new(1, -24, 0, 24),
		}, arms)
		local back = make("Frame", {
			Position = UDim2.fromOffset(0, 19),
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = Color3.fromRGB(40, 44, 52),
			BorderSizePixel = 0,
		}, row)
		self.rows[name] = {
			label = text(
				row,
				{ Size = UDim2.new(1, 0, 0, 16), Text = if spec then `{i}  {spec.Label}` else "G  FLARES" }
			),
			ammo = text(
				row,
				{ Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Right, FontFace = BOLD }
			),
			fill = make(
				"Frame",
				{ Size = UDim2.fromScale(1, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 },
				back
			),
		}
	end

	-- Seeker field of view, sized from the cone angle so it matches what can actually lock
	self.seeker = make(
		"Frame",
		{ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1 },
		gui
	)
	round(self.seeker)
	make("UIStroke", { Color = ACCENT, Thickness = 1, Transparency = 0.6 }, self.seeker)
	self.lockCount = text(self.seeker, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 6),
		Size = UDim2.fromOffset(120, 14),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextSize = 11,
		FontFace = BOLD,
		TextColor3 = ACCENT,
	})

	self.feed = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(420, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 20,
		TextStrokeTransparency = 0.5,
	})

	-- Radar warning: the threat's name, and an arrow around the reticle pointing at it
	-- (top = ahead, bottom = behind you).
	self.warning = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromOffset(420, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 22,
		TextStrokeTransparency = 0.4,
	})
	self.arrow = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(30, 30),
		Text = "▲",
		TextXAlignment = Enum.TextXAlignment.Center,
		TextSize = 26,
		TextStrokeTransparency = 0.4,
	})

	-- Red vignette when you take damage: four edge bars fading inward.
	self.hurt = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 40 }, gui)
	self.hurtBars = {}
	for _, edge in { { 0, 0, 1, 0.22, 90 }, { 0, 0.78, 1, 0.22, -90 }, { 0, 0, 0.16, 1, 0 }, { 0.84, 0, 0.16, 1, 180 } } do
		local bar = make("Frame", {
			Position = UDim2.fromScale(edge[1], edge[2]),
			Size = UDim2.fromScale(edge[3], edge[4]),
			BackgroundColor3 = Color3.fromRGB(255, 30, 30),
			BorderSizePixel = 0,
			BackgroundTransparency = 1,
			ZIndex = 40,
		}, self.hurt)
		make("UIGradient", { Rotation = edge[5], Transparency = NumberSequence.new(0, 1) }, bar)
		table.insert(self.hurtBars, bar)
	end
	self.hurtAt = -math.huge

	-- Analog video breakup when the drone is lost: rows of noise blocks that roll and tear.
	self.static = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(14, 14, 16),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 50,
	}, gui)
	self.bands = {}
	for _ = 1, STATIC_ROWS * STATIC_COLS do
		table.insert(self.bands, make("Frame", { BorderSizePixel = 0, ZIndex = 51 }, self.static))
	end
	self.lost = text(self.static, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(500, 50),
		Text = "SIGNAL LOST",
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 40,
		TextStrokeTransparency = 0.2,
		ZIndex = 52,
	})
	self.staticFrom, self.staticUntil = 0, 0

	-- Hit marker: four ticks round the centre, white for a hit, red and bigger for a kill.
	self.hit = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)
	self.hitTicks = {}
	for i = 0, 3 do
		local angle = math.rad(45 + 90 * i)
		table.insert(
			self.hitTicks,
			make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.5, 0.5 + math.sin(angle) * 0.5),
				Size = UDim2.fromOffset(12, 3),
				Rotation = math.deg(angle),
				BorderSizePixel = 0,
			}, self.hit)
		)
	end

	self.camLabel = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 20),
		Size = UDim2.fromOffset(300, 24),
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 18,
		TextStrokeTransparency = 0.4,
		Text = "● MISSILE CAM",
		TextColor3 = WARN,
	})

	self.help = panel(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(640, 330),
		BackgroundTransparency = 0.12,
		ZIndex = 20, -- above the target markers
	})
	text(self.help, {
		Position = UDim2.fromOffset(28, 22),
		Size = UDim2.fromOffset(300, 24),
		Text = "FPV STRIKE",
		FontFace = BOLD,
		TextSize = 22,
		TextColor3 = ACCENT,
	})
	text(self.help, {
		Position = UDim2.fromOffset(28, 50),
		Size = UDim2.new(1, -56, 0, 18),
		Text = "Fly a strike drone with real flight physics. Lock on, fire, and keep clear of the SAM sites.",
		TextColor3 = DIM,
		TextSize = 13,
	})
	for i, group in HELP do
		local column = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(28 + ((i - 1) % 2) * 300, 86 + (i - 1) // 2 * 116),
			Size = UDim2.fromOffset(290, 110),
		}, self.help)
		text(
			column,
			{ Size = UDim2.new(1, 0, 0, 16), Text = group[1], FontFace = BOLD, TextSize = 13, TextColor3 = ACCENT }
		)
		for j, line in group[2] do
			text(column, {
				Position = UDim2.fromOffset(0, 2 + j * 17),
				Size = UDim2.new(1, 0, 0, 16),
				RichText = true,
				TextSize = 13,
				Text = `<b>{line[1]}</b>  <font color="#969eaa">{line[2]}</font>`,
			})
		end
	end
	text(self.help, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(400, 18),
		Text = "SPACE to launch  ·  H to hide",
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 14,
		TextColor3 = ACCENT,
	})
	self.launched = false

	self.osd = Osd.new(gui)
	self.panels = { top, title, tele, arms, self.hints }
	self.gui = gui
	self.markers = {}
	return self
end

function Hud:toggleHelp()
	self.help.Visible = not self.help.Visible
end

function Hud:signalLost(seconds: number)
	local now = os.clock()
	if now > self.staticUntil then
		self.staticFrom = now
	end
	self.staticUntil = math.max(self.staticUntil, now + seconds)
end

function Hud:damaged()
	self.hurtAt = os.clock()
end

function Hud:_updateEffects(weapons, link, fpv: boolean)
	local now = os.clock()
	local hurt = math.clamp((now - self.hurtAt) / 0.6, 0, 1)
	for _, bar in self.hurtBars do
		bar.BackgroundTransparency = 0.35 + 0.65 * hurt
	end

	-- Video breakup: total while the drone is lost, otherwise as much as the link is weak. A
	-- weak link drops random rows of noise over the picture; a lost one buries it.
	local lost = if now < self.staticUntil then math.clamp((self.staticUntil - now) / 0.5, 0, 1) else 0
	local noise = math.max(lost, link:noise())
	self.static.Visible = noise > 0.01
	if self.static.Visible then
		local roll = (now * 3) % 1
		local i = 0
		for row = 1, STATIC_ROWS do
			-- Each row is a few blocks of random width, the whole row torn sideways a little.
			local x = math.random(-8, 0) / 100
			local shown = lost > 0 or math.random() < noise * 0.7
			for col = 1, STATIC_COLS do
				i += 1
				local band = self.bands[i]
				local width = if col == STATIC_COLS then 1.1 - x else math.random(5, 50) / 100
				local grey = math.random(10, 240)
				band.Position = UDim2.fromScale(x, ((row - 1) / STATIC_ROWS + roll) % 1)
				band.Size = UDim2.new(width, 0, 1 / STATIC_ROWS, 1)
				band.BackgroundColor3 = Color3.fromRGB(grey, grey, math.min(grey + math.random(0, 25), 255))
				-- Even light breakup gets some solid tears, or it just reads as haze.
				band.BackgroundTransparency = if shown then 1 - (0.3 + 0.7 * noise) * math.random(40, 95) / 100 else 1
				x += width
			end
		end
		self.static.BackgroundTransparency = 1 - lost
		self.lost.Visible = lost > 0
		self.lost.TextTransparency = 1 - lost
		self.lost.TextStrokeTransparency = 1 - lost * 0.8
		self.lost.TextColor3 = if math.floor(now * 4) % 2 == 0 then WHITE else WARN
	end

	local age = now - weapons.hitAt
	local life = if weapons.hitKill then 0.5 else 0.3
	self.hit.Visible = age < life
	if self.hit.Visible then
		local size = (if weapons.hitKill then 34 else 26) + age * 30
		self.hit.Size = UDim2.fromOffset(size, size)
		for _, tick in self.hitTicks do
			tick.BackgroundColor3 = if weapons.hitKill then LOCK else WHITE
			tick.BackgroundTransparency = age / life
		end
	end

	local cam = workspace.CurrentCamera
	local threat = weapons.threat
	self.warning.Visible = threat ~= nil and not fpv -- the OSD has its own
	self.arrow.Visible = threat ~= nil and weapons.threatAt ~= nil
	if threat == "MISSILE" then
		local blink = math.floor(now * 8) % 2 == 0
		self.warning.Text = "MISSILE  ·  G FLARES"
		self.warning.TextColor3 = WARN
		self.warning.TextTransparency = if blink then 0 else 0.5
	elseif threat == "RADAR" then
		self.warning.Text = "RADAR LOCK"
		self.warning.TextColor3 = AMBER
		self.warning.TextTransparency = 0
	end
	if self.arrow.Visible then
		local rel = cam.CFrame:PointToObjectSpace(weapons.threatAt)
		local bearing = math.atan2(rel.X, -rel.Z)
		local center = cam.ViewportSize / 2
		self.arrow.Position = UDim2.fromOffset(center.X + math.sin(bearing) * 120, center.Y - math.cos(bearing) * 120)
		self.arrow.Rotation = math.deg(bearing)
		self.arrow.TextColor3 = if threat == "MISSILE" then WARN else AMBER
	end
end

-- One marker per target: a box that becomes a spinning diamond while locking and a red
-- diamond once locked, with a range tag and health bar.
function Hud:_marker(target: Model)
	local m = self.markers[target]
	if m then
		return m
	end
	local holder = make(
		"Frame",
		{ AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(80, 80), BackgroundTransparency = 1 },
		self.gui
	)
	local box = make(
		"Frame",
		{ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1 },
		holder
	)
	local barBack = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 22),
		Size = UDim2.fromOffset(34, 3),
		BackgroundColor3 = Color3.fromRGB(30, 30, 34),
		BorderSizePixel = 0,
	}, holder)
	m = {
		holder = holder,
		box = box,
		stroke = make("UIStroke", { Thickness = 1.5 }, box),
		tag = text(holder, {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 0.5, -22),
			Size = UDim2.fromOffset(140, 14),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextSize = 11,
			FontFace = BOLD,
			TextStrokeTransparency = 0.6,
		}),
		barBack = barBack,
		bar = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = LOCK, BorderSizePixel = 0 }, barBack),
	}
	self.markers[target] = m
	return m
end

function Hud:_updateWeapons(weapons, rig)
	local cam = workspace.CurrentCamera
	local now = workspace:GetServerTimeNow()
	for name, row in self.rows do
		local spec = Weapons.Specs[name] or Weapons.Flares
		local slot = weapons.slots[name]
		Weapons.refill(slot, spec, now)
		local selected = name == weapons.selected
		row.label.TextColor3 = if selected then ACCENT else DIM
		row.label.FontFace = if selected then BOLD else FONT
		row.ammo.Text = tostring(slot.ammo)
		row.ammo.TextColor3 = if slot.ammo == 0 then WARN elseif selected then WHITE else DIM
		row.fill.Size = UDim2.fromScale(if slot.ammo >= spec.Ammo then 1 else slot.timer / spec.Reload, 1)
		row.fill.BackgroundTransparency = if slot.ammo >= spec.Ammo then 0.6 else 0
	end

	local spec = Weapons.Specs[weapons.selected]
	self.seeker.Visible = spec.MaxLocks > 0 and rig.mode ~= "Orbit" and not rig.watching
	if self.seeker.Visible then
		local radius = math.tan(spec.SeekerCone) / math.tan(math.rad(cam.FieldOfView) / 2) * cam.ViewportSize.Y / 2
		self.seeker.Size = UDim2.fromOffset(radius * 2, radius * 2)
		self.lockCount.Text = `LOCKS {#weapons.locks}/{spec.MaxLocks}`
	end

	local age = os.clock() - weapons.messageAt
	self.feed.Text = weapons.message
	self.feed.TextColor3 = if weapons.messageWarn then WARN else ACCENT
	self.feed.TextTransparency = math.clamp((age - 0.8) / 0.6, 0, 1)
	self.feed.TextStrokeTransparency = 0.5 + 0.5 * self.feed.TextTransparency

	local eye = cam.CFrame.Position
	for _, target in CollectionService:GetTagged("Target") do
		local m = self:_marker(target)
		local root = target.PrimaryPart
		local health = (target:GetAttribute("Health") or 0) / (target:GetAttribute("MaxHealth") or 1)
		local screen, onScreen = Vector3.zero, false
		if root and health > 0 then
			screen, onScreen = cam:WorldToViewportPoint(root.Position)
		end
		local dist = if root then (root.Position - eye).Magnitude else math.huge
		m.holder.Visible = onScreen and dist < 1500
		if m.holder.Visible then
			local locked = table.find(weapons.locks, target) ~= nil
			local locking = weapons.candidate == target
			local size, rotation, color, label = 12, 0, WHITE, ""
			if target:GetAttribute("Kind") == "SAM" then
				size, color, label = 16, AMBER, `SAM {math.round(dist * METERS_PER_STUD)}m` -- threats stand out
			end
			if locked then
				size, rotation, color, label = 26, 45, LOCK, `LOCK {math.round(dist * METERS_PER_STUD)}m`
			elseif locking then
				local p = weapons.progress
				size, rotation, color, label = 70 - 44 * p, 45 + 180 * (1 - p), ACCENT, `{math.floor(p * 100)}%`
			end
			m.holder.Position = UDim2.fromOffset(screen.X, screen.Y)
			m.box.Size = UDim2.fromOffset(size, size)
			m.box.Rotation = rotation
			m.stroke.Color = color
			m.stroke.Thickness = if locked then 2 else 1.5
			m.stroke.Transparency = if locked or locking or color == AMBER then 0 else 0.55
			m.tag.Text = label
			m.tag.TextColor3 = color
			m.barBack.Visible = locked or locking or health < 1
			m.bar.Size = UDim2.fromScale(health, 1)
		end
	end
end

local function project(gui: GuiObject, point: Vector3)
	local screen, onScreen = workspace.CurrentCamera:WorldToViewportPoint(point)
	gui.Visible = onScreen
	gui.Position = UDim2.fromOffset(screen.X, screen.Y)
end

function Hud:update(dt: number, ctrl, rig, weapons, link)
	local fpv = rig.mode == "Fpv" and not rig.watching
	self:_updateWeapons(weapons, rig)
	self:_updateEffects(weapons, link, fpv)
	self.osd:update(dt, ctrl, rig, weapons, link)
	if os.clock() < self.staticUntil then
		self.osd.root.Visible = false -- no video at all: the OSD goes with it
	end
	for _, p in self.panels do
		p.Visible = not fpv
	end
	self.camLabel.Visible = rig.watching and math.floor(os.clock() * 2) % 2 == 0
	if ctrl.armed and not self.launched then
		self.launched = true
		self.help.Visible = false -- first launch: they've read it
	end
	local bat = Config.Battery
	local volts = bat.EmptyVolts + (bat.FullVolts - bat.EmptyVolts) * ctrl.battery - bat.SagVolts * ctrl.throttle
	local v = ctrl.root.AssemblyLinearVelocity
	local batColor = if ctrl.battery < 0.2 then "#ff5c5c" else "#ffffff"
	local health = ctrl.drone:GetAttribute("Health") or Config.Health
	local hpColor = if health <= 40 then "#ff5c5c" else "#ffffff"

	local kills = `{weapons.kills} KILL{if weapons.kills == 1 then "" else "S"}`
	self.status.Text = `{string.upper(ctrl.mode)}  ·  {string.upper(rig.mode)}  ·  {kills}`
	self.telemetry.Text = string.format(
		'SPD  <b>%3d</b> km/h\nALT  <b>%5.1f</b> m\nTHR  <b>%3d</b> %%\nBAT  <font color="%s"><b>%4.1f</b> V</font>\nHP   <font color="%s"><b>%3d</b></font>',
		math.round(v.Magnitude),
		math.max(ctrl.height, 0) * METERS_PER_STUD,
		math.round(ctrl.throttle * 100),
		batColor,
		volts,
		hpColor,
		math.ceil(health)
	)
	self.throttleBar.Size = UDim2.fromScale(ctrl.throttle, 1)
	self.hints.Text = HINTS[ctrl.mode] .. COMMON

	if link.failsafe then
		self.prompt.Text = "FAILSAFE · OUT OF RANGE · BACKSPACE TO RESET"
		self.prompt.TextColor3 = WARN
	elseif not ctrl.armed then
		self.prompt.Text = if ctrl.mode == "Acro" then "W  TO SPOOL UP" else "SPACE  TO LAUNCH"
		self.prompt.TextColor3 = ACCENT
	elseif ctrl.crashTimer > 0 then
		self.prompt.Text = "IMPACT"
		self.prompt.TextColor3 = WARN
	elseif ctrl.battery < 0.2 then
		self.prompt.Text = "LOW BATTERY · BACKSPACE TO SWAP"
		self.prompt.TextColor3 = WARN
	else
		self.prompt.Text = ""
	end

	local eye = workspace.CurrentCamera.CFrame.Position
	if ctrl.mode == "Aim" and rig.mode ~= "Orbit" and not rig.watching then
		project(self.reticle, eye + ctrl:aimDirection() * 1000)
	else
		self.reticle.Visible = false
	end
	if v.Magnitude > 8 and rig.mode ~= "Orbit" and not rig.watching then
		project(self.flightPath, eye + v.Unit * 1000)
	else
		self.flightPath.Visible = false
	end
end

return Hud
