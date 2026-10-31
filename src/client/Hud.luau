-- Flight and weapons HUD: mode, telemetry, aim reticle, flight-path marker, weapon panel,
-- seeker circle and lock diamonds. The full goggles-style OSD comes in milestone 4.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))

local Hud = {}
Hud.__index = Hud

local ACCENT = Color3.fromRGB(62, 232, 255)
local WARN = Color3.fromRGB(255, 92, 92)
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
local COMMON = " · LMB fire · 1-3 weapon · T mode · F camera · BACKSPACE reset"

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
	local frame = make("Frame", { BackgroundColor3 = Color3.fromRGB(8, 10, 14), BackgroundTransparency = 0.35, BorderSizePixel = 0 }, parent)
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
	self.status = text(top, { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0), FontFace = BOLD, TextColor3 = ACCENT })

	local title = panel(gui, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 16), Size = UDim2.fromOffset(210, 46) })
	text(title, { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 18), Text = "FPV STRIKE", FontFace = BOLD, TextSize = 16, TextColor3 = ACCENT })
	text(title, { Position = UDim2.fromOffset(12, 25), Size = UDim2.new(1, -24, 0, 14), Text = "flight model · PN guidance", TextSize = 11, TextColor3 = DIM })

	local tele = panel(gui, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(200, 108) })
	self.telemetry = text(tele, {
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, 72),
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
	self.throttleBar = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, barBack)
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
		Size = UDim2.fromOffset(420, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		FontFace = BOLD,
		TextSize = 18,
		TextStrokeTransparency = 0.5,
	})

	-- Where the mouse is aiming
	self.reticle = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(28, 28), BackgroundTransparency = 1 }, gui)
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
	self.flightPath = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1 }, gui)
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

	-- Weapons panel: one row per weapon with ammo and a reload bar
	local arms = panel(gui, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(210, 16 + #Weapons.Order * 28),
	})
	self.rows = {}
	for i, name in Weapons.Order do
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
			label = text(row, { Size = UDim2.new(1, 0, 0, 16), Text = `{i}  {Weapons.Specs[name].Label}` }),
			ammo = text(row, { Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Right, FontFace = BOLD }),
			fill = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, back),
		}
	end

	-- Seeker field of view, sized from the cone angle so it matches what can actually lock
	self.seeker = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1 }, gui)
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

	self.gui = gui
	self.markers = {}
	return self
end

-- One marker per target: a box that becomes a spinning diamond while locking and a red
-- diamond once locked, with a range tag and health bar.
function Hud:_marker(target: Model)
	local m = self.markers[target]
	if m then
		return m
	end
	local holder = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(80, 80), BackgroundTransparency = 1 }, self.gui)
	local box = make("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1 }, holder)
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
		local spec = Weapons.Specs[name]
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
	self.seeker.Visible = spec.MaxLocks > 0 and rig.mode ~= "Orbit"
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
			m.stroke.Transparency = if locked or locking then 0 else 0.55
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

function Hud:update(ctrl, rig, weapons)
	self:_updateWeapons(weapons, rig)
	local bat = Config.Battery
	local volts = bat.EmptyVolts + (bat.FullVolts - bat.EmptyVolts) * ctrl.battery - bat.SagVolts * ctrl.throttle
	local v = ctrl.root.AssemblyLinearVelocity
	local batColor = if ctrl.battery < 0.2 then "#ff5c5c" else "#ffffff"

	local kills = `{weapons.kills} KILL{if weapons.kills == 1 then "" else "S"}`
	self.status.Text = `{string.upper(ctrl.mode)}  ·  {string.upper(rig.mode)}  ·  {kills}`
	self.telemetry.Text = string.format(
		'SPD  <b>%3d</b> km/h\nALT  <b>%5.1f</b> m\nTHR  <b>%3d</b> %%\nBAT  <font color="%s"><b>%4.1f</b> V</font>',
		math.round(v.Magnitude),
		math.max(ctrl.height, 0) * METERS_PER_STUD,
		math.round(ctrl.throttle * 100),
		batColor,
		volts
	)
	self.throttleBar.Size = UDim2.fromScale(ctrl.throttle, 1)
	self.hints.Text = HINTS[ctrl.mode] .. COMMON

	if not ctrl.armed then
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
	if ctrl.mode == "Aim" and rig.mode ~= "Orbit" then
		project(self.reticle, eye + ctrl:aimDirection() * 1000)
	else
		self.reticle.Visible = false
	end
	if v.Magnitude > 8 and rig.mode ~= "Orbit" then
		project(self.flightPath, eye + v.Unit * 1000)
	else
		self.flightPath.Visible = false
	end
end

return Hud
