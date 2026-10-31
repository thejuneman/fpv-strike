-- Debug overlay (F2): draws what the code is thinking, out in the world.
--   every missile   velocity (green), line of sight to the point it's steering at (yellow),
--                   and the lateral acceleration guidance is commanding (magenta)
--   your drone      velocity, thrust (orange) and, in Aim mode, the velocity the autopilot is
--                   chasing (blue)
--   targets         path velocity, one second ahead; SAM sites draw their radar range, and a
--                   line to you while they hold a lock
-- A readout in the corner covers the flight controller and the link.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Weapons"))
local TargetPaths = require(Shared:WaitForChild("TargetPaths"))
local Smooth = require(Shared:WaitForChild("Smooth"))

local DebugOverlay = {}
DebugOverlay.__index = DebugOverlay

local COLORS = {
	velocity = Color3.fromRGB(80, 255, 120),
	sight = Color3.fromRGB(255, 220, 60),
	steer = Color3.fromRGB(255, 70, 220),
	thrust = Color3.fromRGB(255, 150, 40),
	wanted = Color3.fromRGB(70, 200, 255),
	radar = Color3.fromRGB(255, 186, 64),
}
local LEGEND = '<font color="#50ff78">velocity</font>  <font color="#ffdc3c">line of sight</font>  '
	.. '<font color="#ff46dc">guidance accel</font>  <font color="#ff9628">thrust</font>  '
	.. '<font color="#46c8ff">autopilot target</font>'

local player = Players.LocalPlayer

-- A line with a small head, so direction reads at a glance.
local function arrow(pen: WireframeHandleAdornment, from: Vector3, vec: Vector3)
	local length = vec.Magnitude
	if length < 0.05 then
		return
	end
	local to = from + vec
	pen:AddLine(from, to)
	local side = vec:Cross(if math.abs(vec.Unit.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis).Unit
	local head = math.min(length * 0.25, 2)
	pen:AddLine(to, to - vec.Unit * head + side * head * 0.5)
	pen:AddLine(to, to - vec.Unit * head - side * head * 0.5)
end

local function cross(pen: WireframeHandleAdornment, at: Vector3, size: number)
	pen:AddLine(at - Vector3.xAxis * size, at + Vector3.xAxis * size)
	pen:AddLine(at - Vector3.yAxis * size, at + Vector3.yAxis * size)
	pen:AddLine(at - Vector3.zAxis * size, at + Vector3.zAxis * size)
end

local function ring(pen: WireframeHandleAdornment, center: Vector3, radius: number)
	local points = {}
	for i = 0, 63 do
		local a = i / 64 * math.pi * 2
		table.insert(points, Vector3.new(center.X + math.cos(a) * radius, 1, center.Z + math.sin(a) * radius))
	end
	pen:AddPath(points, true)
end

function DebugOverlay.new(ctrl, fx, link)
	local self = setmetatable({}, DebugOverlay)
	self.ctrl, self.fx, self.link = ctrl, fx, link
	self.enabled = false
	self.fps = 60

	local gui = player:WaitForChild("PlayerGui")
	self.pens = {}
	for name, color in COLORS do
		local pen = Instance.new("WireframeHandleAdornment")
		pen.Name = "Debug_" .. name
		pen.Adornee = workspace.Terrain -- world space
		pen.Color3 = color
		pen.AlwaysOnTop = true
		pen.Thickness = 3
		pen.Visible = false
		pen.Parent = gui
		self.pens[name] = pen
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "Debug"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 5
	screen.Enabled = false
	screen.Parent = gui
	local readout = Instance.new("TextLabel")
	readout.Position = UDim2.fromOffset(16, 60)
	readout.Size = UDim2.fromOffset(560, 100)
	readout.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	readout.BackgroundTransparency = 0.35
	readout.BorderSizePixel = 0
	readout.FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json")
	readout.TextSize = 13
	readout.TextColor3 = Color3.new(1, 1, 1)
	readout.TextXAlignment = Enum.TextXAlignment.Left
	readout.TextYAlignment = Enum.TextYAlignment.Top
	readout.RichText = true
	readout.Parent = screen
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingTop = UDim.new(0, 10), UDim.new(0, 8)
	pad.Parent = readout
	self.screen, self.readout = screen, readout
	return self
end

function DebugOverlay:toggle(): boolean
	self.enabled = not self.enabled
	self.screen.Enabled = self.enabled
	for _, pen in self.pens do
		pen:Clear()
		pen.Visible = self.enabled
	end
	return self.enabled
end

function DebugOverlay:update(dt: number)
	if not self.enabled then
		return
	end
	local p = self.pens
	for _, pen in p do
		pen:Clear()
	end

	local ctrl = self.ctrl
	local root = ctrl.root
	local at = root.Position
	arrow(p.velocity, at, root.AssemblyLinearVelocity * 0.25)
	arrow(p.thrust, at, root.CFrame.UpVector * ctrl.throttle * 12)
	if ctrl.wanted then
		arrow(p.wanted, at, ctrl.wanted * 0.25)
	end

	local missiles = 0
	for _, f in self.fx.flights do
		if not f.done then
			missiles += 1
			local s = f.state
			arrow(p.velocity, s.pos, s.vel * 0.05)
			if s.aim then
				p.sight:AddLine(s.pos, s.aim)
				cross(p.sight, s.aim, 2)
			end
			if s.steer then
				arrow(p.steer, s.pos, s.steer * 0.02)
			end
		end
	end

	local now = workspace:GetServerTimeNow()
	for _, target in CollectionService:GetTagged("Target") do
		local troot = target.PrimaryPart
		if troot and target:GetAttribute("Health") > 0 then
			arrow(p.velocity, troot.Position, TargetPaths.velocity(target, now))
			if target:GetAttribute("Kind") == "SAM" then
				ring(p.radar, troot.Position, Weapons.Specs.SAM.Range)
				if target:GetAttribute("Tracking") == player.UserId then
					p.radar:AddLine(troot.Position, at)
				end
			end
		end
	end

	self.fps = Smooth.damp(self.fps, 1 / math.max(dt, 1e-3), 4, dt)
	local cf = root.CFrame
	local actual = cf:VectorToObjectSpace(root.AssemblyAngularVelocity)
	local cmd = ctrl.bodyRate
	local link = self.link
	self.readout.Text = string.format(
		"<b>DEBUG</b>  F2 to hide       fps %3d\n"
			.. "ctrl   %-5s  throttle %3d%%  tilt %2d°  motors %3d %3d %3d %3d\n"
			.. "rates  cmd %6.2f %6.2f %6.2f   actual %6.2f %6.2f %6.2f  rad/s\n"
			.. "link   %3d%%  %4d studs  %s\n"
			.. "missiles in the air  %d\n%s",
		math.round(self.fps),
		ctrl.mode,
		math.round(ctrl.throttle * 100),
		math.round(math.deg(math.acos(math.clamp(cf.UpVector.Y, -1, 1)))),
		math.round(ctrl.motors[1] * 100),
		math.round(ctrl.motors[2] * 100),
		math.round(ctrl.motors[3] * 100),
		math.round(ctrl.motors[4] * 100),
		cmd.X,
		cmd.Y,
		cmd.Z,
		actual.X,
		actual.Y,
		actual.Z,
		math.round(link.quality * 100),
		math.round(link.distance),
		if link.blocked then "wall in the way" else "clear",
		missiles,
		LEGEND
	)
end

return DebugOverlay
