-- Goggles-style on-screen display for the FPV camera, laid out like Betaflight's: white pixel
-- text with a black outline round the edges of the picture, an artificial horizon, a home
-- arrow, and blinking warnings in the middle. Shown instead of the HUD panels while flying FPV.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Osd = {}
Osd.__index = Osd

local PIXEL = Font.fromEnum(Enum.Font.Arcade)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local METERS_PER_STUD = 0.28
local CAPACITY = 1500 -- mAh in the pack
local HOME = Vector3.new(0, 0, 16) -- the pilot's spot
local MODES = { Aim = "AIM", Angle = "ANGL", Acro = "ACRO" }
local SHORT = { Rockets = "RKT", Seeker = "SKR", TopAttack = "TOP" }

local function label(parent: Instance, anchor: Vector2, position: UDim2, align: Enum.TextXAlignment, size: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = anchor
	l.Position = position
	l.Size = UDim2.fromOffset(340, 24)
	l.FontFace = PIXEL
	l.TextSize = size or 19 -- smaller and the pixel font's 8 reads as an S
	l.TextColor3 = WHITE
	l.TextStrokeColor3 = BLACK
	l.TextStrokeTransparency = 0
	l.TextXAlignment = align
	l.Parent = parent
	return l
end

local function bar(parent: Instance, x: number, width: number): Frame
	local f = Instance.new("Frame")
	f.Position = UDim2.fromOffset(x, 0)
	f.Size = UDim2.new(0, width, 1, 0)
	f.BackgroundColor3 = WHITE
	f.BorderSizePixel = 0
	local stroke = Instance.new("UIStroke")
	stroke.Color = BLACK
	stroke.Parent = f
	f.Parent = parent
	return f
end

function Osd.new(gui: ScreenGui)
	local self = setmetatable({}, Osd)
	local root = Instance.new("Frame")
	root.Name = "Osd"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.ZIndex = 60 -- the flight controller draws the OSD over the video, so it stays crisp in the noise
	root.Parent = gui
	self.root = root

	-- The top and bottom of a small FPV camera's picture fall off toward black. (Side bars
	-- read as haze against the bright sky, so there are none.)
	for _, edge in { { 0, 0, 1, 0.18, 90 }, { 0, 0.82, 1, 0.18, -90 } } do
		local shade = Instance.new("Frame")
		shade.Position = UDim2.fromScale(edge[1], edge[2])
		shade.Size = UDim2.fromScale(edge[3], edge[4])
		shade.BackgroundColor3 = BLACK
		shade.BackgroundTransparency = 0.45
		shade.BorderSizePixel = 0
		local fade = Instance.new("UIGradient")
		fade.Rotation = edge[5]
		fade.Color = ColorSequence.new(BLACK)
		fade.Transparency = NumberSequence.new(0, 1)
		fade.Parent = shade
		shade.Parent = root
	end

	local left, center, right = Enum.TextXAlignment.Left, Enum.TextXAlignment.Center, Enum.TextXAlignment.Right
	self.battery = label(root, Vector2.new(0, 0), UDim2.fromScale(0.06, 0.07), left)
	self.mode = label(root, Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0.07), center)
	self.timer = label(root, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0.07, 28), center)
	self.link = label(root, Vector2.new(1, 0), UDim2.fromScale(0.94, 0.07), right)
	self.speed = label(root, Vector2.new(0, 0.5), UDim2.fromScale(0.14, 0.5), left)
	self.altitude = label(root, Vector2.new(1, 0.5), UDim2.fromScale(0.86, 0.5), right)
	self.power = label(root, Vector2.new(0, 1), UDim2.fromScale(0.06, 0.93), left)
	self.home = label(root, Vector2.new(0.5, 1), UDim2.fromScale(0.5, 0.93), center)
	self.arms = label(root, Vector2.new(1, 1), UDim2.fromScale(0.94, 0.93), right)
	self.warning = label(root, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.66), center, 26)
	self.cross = label(root, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), center, 19)
	self.cross.Text = "-+-"

	self.arrow = label(root, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 0.93, -24), center, 20)
	self.arrow.FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
	self.arrow.Size = UDim2.fromOffset(24, 24)
	self.arrow.Text = "▲"

	-- Artificial horizon: a split line that rolls and pitches with the camera.
	self.horizon = Instance.new("Frame")
	self.horizon.AnchorPoint = Vector2.new(0.5, 0.5)
	self.horizon.Size = UDim2.fromOffset(260, 2)
	self.horizon.BackgroundTransparency = 1
	self.horizon.Parent = root
	bar(self.horizon, 0, 100)
	bar(self.horizon, 160, 100)

	self.flown = 0
	return self
end

function Osd:update(dt: number, ctrl, rig, weapons, link)
	local visible = rig.mode == "Fpv" and not rig.watching
	self.root.Visible = visible
	if ctrl.armed then
		self.flown += dt
	elseif ctrl.battery >= 0.999 then
		self.flown = 0 -- fresh pack
	end
	if not visible then
		return
	end

	local cam = workspace.CurrentCamera
	local root = ctrl.root
	local blink = math.floor(os.clock() * 3) % 2 == 0
	local bat = Config.Battery
	local volts = bat.EmptyVolts + (bat.FullVolts - bat.EmptyVolts) * ctrl.battery - bat.SagVolts * ctrl.throttle

	self.battery.Text = string.format("4S %.1fV", volts)
	self.battery.Visible = ctrl.battery >= 0.2 or blink
	self.mode.Text = if ctrl.armed then MODES[ctrl.mode] else "DISARMED"
	self.timer.Text = string.format("%02d:%02d", self.flown // 60, self.flown % 60)
	self.link.Text = string.format("LQ %3d", math.round(link.quality * 100))
	self.link.Visible = link.quality >= 0.3 or blink
	self.speed.Text = string.format("%dKM/H", math.round(root.AssemblyLinearVelocity.Magnitude))
	self.altitude.Text = string.format("%.1fM", math.max(ctrl.height, 0) * METERS_PER_STUD)
	local amps = 0.8 + ctrl.throttle ^ 1.5 * 70
	self.power.Text = string.format("%.1fA %dMAH", amps, math.round((1 - ctrl.battery) * CAPACITY))

	-- Home arrow: which way the pilot is, relative to where the camera points.
	local toHome = HOME - root.Position
	local rel = cam.CFrame:VectorToObjectSpace(toHome)
	self.arrow.Rotation = math.deg(math.atan2(rel.X, -rel.Z))
	self.home.Text = string.format("%dM", math.round(Vector3.new(toHome.X, 0, toHome.Z).Magnitude * METERS_PER_STUD))

	local name = weapons.selected
	local health = ctrl.drone:GetAttribute("Health") or Config.Health
	self.arms.Text = string.format("%s %d  FLR %d  HP %d", SHORT[name], weapons.slots[name].ammo, weapons.slots.Flares.ammo, math.ceil(health))

	local warning = if link.failsafe then "FAILSAFE"
		elseif weapons.threat == "MISSILE" then "MISSILE"
		elseif link.quality < 0.3 then "LQ LOW"
		elseif ctrl.battery < 0.2 then "LOW BATTERY"
		elseif weapons.threat == "RADAR" then "RADAR"
		else ""
	self.warning.Text = warning
	self.warning.Visible = blink or warning == "FAILSAFE"

	-- The horizon is where world directions with zero height land on screen: a line through
	-- the point nearest the centre, turned by the camera's roll.
	local c = cam.CFrame
	local half = cam.ViewportSize / 2
	local tanV = math.tan(math.rad(cam.FieldOfView) / 2)
	local r, u = c.RightVector.Y, c.UpVector.Y
	local n = r * r + u * u
	if n > 1e-4 then
		local k = -c.LookVector.Y * half.Y / tanV / n
		local x, y = k * r, -k * u
		self.horizon.Visible = math.abs(x) < half.X and math.abs(y) < half.Y
		self.horizon.Position = UDim2.fromOffset(half.X + x, half.Y + y)
		self.horizon.Rotation = math.deg(math.atan2(r, u))
	else
		self.horizon.Visible = false -- looking straight up or down
	end
end

return Osd
