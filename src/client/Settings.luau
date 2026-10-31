-- Settings (M): sliders for feel, the Acro rates with a live Betaflight rate-curve graph, and
-- toggles. Sliders write straight into the shared Config table, which the controller and the
-- cameras read every frame, so a change is felt the moment you let go.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local FlightModel = require(Shared:WaitForChild("FlightModel"))

local Settings = {}
Settings.__index = Settings

local ACCENT = Color3.fromRGB(62, 232, 255)
local DIM = Color3.fromRGB(150, 158, 170)
local TRACK = Color3.fromRGB(40, 44, 52)
local WHITE = Color3.new(1, 1, 1)
local FONT = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium)
local BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)

local GRAPH = Vector2.new(250, 170)
local GRAPH_TOP = 1200 -- deg/s at the top of the graph
local SEGMENTS = 32

-- label, table, key, min, max, format
local SLIDERS = {
	{ "Mouse sensitivity", Config.Aim, "MouseSensitivity", 0.001, 0.008, "%.4f" },
	{ "Chase camera FOV", Config.Camera, "BaseFov", 55, 90, "%d°" },
	{ "FPV camera FOV", Config.Camera, "FpvFov", 70, 120, "%d°" },
	{ "Acro center rate", Config.Acro, "CenterRate", 20, 250, "%d°/s" },
	{ "Acro max rate", Config.Acro, "MaxRate", 300, 1200, "%d°/s" },
	{ "Acro expo", Config.Acro, "Expo", 0, 0.95, "%.2f" },
}

export type Toggle = { label: string, get: () -> boolean, flip: () -> () }

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local label = make("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextColor3 = WHITE,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	for k, v in props do
		(label :: any)[k] = v
	end
	return label
end

local function round(parent: Instance, radius: number)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

function Settings.new(toggles: { Toggle })
	local self = setmetatable({}, Settings)
	self.open = false
	self.toggles = toggles

	local gui = make("ScreenGui", {
		Name = "Settings",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 10,
		Enabled = false,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))
	self.gui = gui

	local panel = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 400),
		BackgroundColor3 = Color3.fromRGB(8, 10, 14),
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	}, gui)
	round(panel, 8)
	make("UIStroke", { Color = ACCENT, Transparency = 0.6 }, panel)
	text(panel, {
		Position = UDim2.fromOffset(24, 18),
		Size = UDim2.fromOffset(300, 22),
		Text = "SETTINGS",
		FontFace = BOLD,
		TextSize = 18,
		TextColor3 = ACCENT,
	})
	text(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -24, 0, 21),
		Size = UDim2.fromOffset(240, 18),
		Text = "M to close · changes apply live",
		TextColor3 = DIM,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- Sliders, left column
	self.sliders = {}
	local dragging = nil
	for i, def in SLIDERS do
		local row = make("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(24, 58 + (i - 1) * 46),
			Size = UDim2.fromOffset(300, 40),
		}, panel)
		text(row, { Size = UDim2.new(1, 0, 0, 16), Text = def[1] })
		local value = text(row, {
			Size = UDim2.new(1, 0, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Right,
			FontFace = BOLD,
			TextColor3 = ACCENT,
		})
		local track = make("Frame", {
			Position = UDim2.fromOffset(0, 24),
			Size = UDim2.new(1, 0, 0, 6),
			BackgroundColor3 = TRACK,
			BorderSizePixel = 0,
			Active = true,
		}, row)
		round(track, 3)
		local fill =
			make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, track)
		round(fill, 3)
		local knob = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
		}, track)
		round(knob, 7)
		local slider = { def = def, value = value, track = track, fill = fill, knob = knob }
		table.insert(self.sliders, slider)
		track.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = slider
				self:_drag(slider, input.Position.X)
			end
		end)
	end
	UserInputService.InputChanged:Connect(function(input)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			self:_drag(dragging, input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = nil
		end
	end)

	-- Rate curve, right column: roll/pitch rate against stick deflection.
	text(panel, {
		Position = UDim2.fromOffset(360, 58),
		Size = UDim2.fromOffset(260, 16),
		Text = "ACRO RATE CURVE (roll / pitch)",
	})
	local graph = make("Frame", {
		Position = UDim2.fromOffset(366, 84),
		Size = UDim2.fromOffset(GRAPH.X, GRAPH.Y),
		BackgroundColor3 = Color3.fromRGB(16, 19, 25),
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, panel)
	for _, rate in { 400, 800 } do
		local y = GRAPH.Y - rate / GRAPH_TOP * GRAPH.Y
		make("Frame", {
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = TRACK,
			BorderSizePixel = 0,
		}, graph)
		text(graph, {
			Position = UDim2.fromOffset(4, y - 14),
			Size = UDim2.fromOffset(60, 12),
			Text = `{rate}°/s`,
			TextSize = 10,
			TextColor3 = DIM,
		})
	end
	text(panel, {
		Position = UDim2.fromOffset(366, 84 + GRAPH.Y + 2),
		Size = UDim2.fromOffset(GRAPH.X, 14),
		Text = "stick →",
		TextSize = 11,
		TextColor3 = DIM,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	self.segments = {}
	for i = 1, SEGMENTS do
		self.segments[i] = make(
			"Frame",
			{ AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = ACCENT, BorderSizePixel = 0 },
			graph
		)
	end
	self.curveNote = text(panel, {
		Position = UDim2.fromOffset(366, 84 + GRAPH.Y + 18),
		Size = UDim2.fromOffset(GRAPH.X, 16),
		TextColor3 = DIM,
		TextSize = 12,
	})

	-- Toggles under the graph
	self.buttons = {}
	for i, toggle in toggles do
		local button = make("TextButton", {
			Position = UDim2.fromOffset(366, 84 + GRAPH.Y + 46 + (i - 1) * 34),
			Size = UDim2.fromOffset(GRAPH.X, 28),
			BackgroundColor3 = TRACK,
			BorderSizePixel = 0,
			FontFace = BOLD,
			TextSize = 13,
			AutoButtonColor = true,
		}, panel)
		round(button, 4)
		button.Activated:Connect(function()
			toggle.flip()
			self:_refresh()
		end)
		self.buttons[i] = button
	end

	self:_refresh()
	return self
end

function Settings:_drag(slider, x: number)
	local def = slider.def
	local alpha = math.clamp((x - slider.track.AbsolutePosition.X) / slider.track.AbsoluteSize.X, 0, 1)
	def[2][def[3]] = def[4] + (def[5] - def[4]) * alpha
	self:_refresh()
end

function Settings:_refresh()
	for _, slider in self.sliders do
		local def = slider.def
		local v = def[2][def[3]]
		local alpha = (v - def[4]) / (def[5] - def[4])
		slider.value.Text = string.format(def[6], v)
		slider.fill.Size = UDim2.fromScale(alpha, 1)
		slider.knob.Position = UDim2.fromScale(alpha, 0.5)
	end

	-- Redraw the curve as straight segments between samples.
	local cfg = Config.Acro
	local function point(i: number): Vector2
		local stick = i / SEGMENTS
		local rate = FlightModel.actualRate(stick, cfg.CenterRate, cfg.MaxRate, cfg.Expo)
		return Vector2.new(stick * GRAPH.X, GRAPH.Y - rate / GRAPH_TOP * GRAPH.Y)
	end
	for i, seg in self.segments do
		local a, b = point(i - 1), point(i)
		local d = b - a
		seg.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
		seg.Size = UDim2.fromOffset(d.Magnitude + 1, 2)
		seg.Rotation = math.deg(math.atan2(d.Y, d.X))
	end
	local half = FlightModel.actualRate(0.5, cfg.CenterRate, cfg.MaxRate, cfg.Expo)
	self.curveNote.Text = string.format("half stick %d°/s · full stick %d°/s", half, cfg.MaxRate)

	for i, toggle in self.toggles do
		local on = toggle.get()
		self.buttons[i].Text = `{toggle.label}: {if on then "ON" else "OFF"}`
		self.buttons[i].TextColor3 = if on then ACCENT else DIM
	end
end

function Settings:toggle()
	self.open = not self.open
	self.gui.Enabled = self.open
	if self.open then
		self:_refresh()
	end
end

return Settings
