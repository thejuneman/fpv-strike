-- On-screen controls for phones and tablets: a move stick on the left, drag the right side of
-- the screen to aim, and buttons for fire, climb, descend and the weapon keys. They feed the same
-- inputs as a gamepad (stick, triggers) and the mouse (aim), so the flight code doesn't change.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ACCENT = Color3.fromRGB(62, 232, 255)
local WHITE = Color3.new(1, 1, 1)
local BOLD = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)
local STICK_RADIUS = 70
local LOOK_GAIN = 1.2 -- screen pixels of drag to mouse pixels

local Touch = {}
Touch.__index = Touch

export type Actions = {
	weapon: () -> (),
	flares: () -> (),
	camera: () -> (),
	detonate: () -> (),
	reset: () -> (),
}

-- Phones and tablets get the controls. In Studio, set the ForceTouch attribute on Workspace to
-- try them with the mouse.
function Touch.wanted(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
		or RunService:IsStudio() and workspace:GetAttribute("ForceTouch") == true
end

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

-- A finger is followed until it lifts; the mouse (testing in Studio) until the button comes up.
local function moves(active: InputObject?, input: InputObject): boolean
	if not active then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == Enum.UserInputType.MouseMovement
end

local function lifts(active: InputObject?, input: InputObject): boolean
	if not active then
		return false
	end
	if active.UserInputType == Enum.UserInputType.Touch then
		return input == active
	end
	return input.UserInputType == Enum.UserInputType.MouseButton1
end

-- Input positions and AbsolutePosition share a space (both leave out the top bar inset).
local function screen(input: InputObject): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

function Touch.new(actions: Actions)
	local self = setmetatable({}, Touch)
	self.stick = Vector2.zero -- gamepad convention: +Y is forward
	self.look = Vector2.zero -- accumulated drag, taken each frame
	self.fire = false
	self.up = false
	self.down = false
	self.holds = {} :: { [string]: InputObject }

	GuiService.TouchControlsEnabled = false -- Roblox's own stick and jump button would fight ours
	local gui = make("ScreenGui", {
		Name = "TouchControls",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 5,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))
	self.gui = gui

	-- Move stick
	local base = make("Frame", {
		Name = "Stick",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 40 + STICK_RADIUS, 1, -40 - STICK_RADIUS),
		Size = UDim2.fromOffset(STICK_RADIUS * 2, STICK_RADIUS * 2),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.6,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, base)
	make("UIStroke", { Color = ACCENT, Transparency = 0.5, Thickness = 2 }, base)
	local knob = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(58, 58),
		BackgroundColor3 = ACCENT,
		BackgroundTransparency = 0.25,
	}, base)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

	local stickInput: InputObject? = nil
	local function moveStick(input: InputObject)
		local offset = screen(input) - (base.AbsolutePosition + base.AbsoluteSize / 2)
		if offset.Magnitude > STICK_RADIUS then
			offset = offset.Unit * STICK_RADIUS
		end
		knob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
		local v = offset / STICK_RADIUS
		self.stick = if v.Magnitude < 0.12 then Vector2.zero else Vector2.new(v.X, -v.Y)
	end
	base.InputBegan:Connect(function(input)
		if isPress(input) and not stickInput then
			stickInput = input
			moveStick(input)
		end
	end)

	-- Aim: drag anywhere on the right side above the buttons
	local lookArea = make("Frame", {
		Name = "Look",
		Position = UDim2.fromScale(0.45, 0),
		Size = UDim2.new(0.55, 0, 1, -290),
		BackgroundTransparency = 1,
	}, gui)
	local lookInput: InputObject? = nil
	local lookFrom = Vector2.zero
	lookArea.InputBegan:Connect(function(input)
		if isPress(input) and not lookInput then
			lookInput = input
			lookFrom = screen(input)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if moves(stickInput, input) then
			moveStick(input)
		end
		if moves(lookInput, input) then
			local at = screen(input)
			self.look += (at - lookFrom) * LOOK_GAIN
			lookFrom = at
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if lifts(stickInput, input) then
			stickInput = nil
			self.stick = Vector2.zero
			knob.Position = UDim2.fromScale(0.5, 0.5)
		end
		if lifts(lookInput, input) then
			lookInput = nil
		end
		for name, held in self.holds do
			if lifts(held, input) then
				self.holds[name] = nil
				(self :: any)[name] = false
			end
		end
	end)

	-- Buttons, laid out from the bottom-right corner. Hold buttons stay down while the finger does.
	local function button(label: string, size: number, x: number, y: number, hold: string?, tap: (() -> ())?)
		local b = make("TextButton", {
			Name = label,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -x, 1, -y),
			Size = UDim2.fromOffset(size, size),
			AutoButtonColor = false,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.5,
			Text = label,
			FontFace = BOLD,
			TextSize = if size > 80 then 22 else 14,
			TextColor3 = WHITE,
		}, gui)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
		make("UIStroke", { Color = ACCENT, Transparency = 0.4, Thickness = 2 }, b)
		b.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			b.BackgroundColor3 = ACCENT
			task.delay(0.12, function()
				if not (hold and self.holds[hold]) then
					b.BackgroundColor3 = Color3.new(0, 0, 0)
				end
			end)
			if hold then
				self.holds[hold] = input;
				(self :: any)[hold] = true
			end
			if tap then
				tap()
			end
		end)
		if hold then
			UserInputService.InputEnded:Connect(function()
				if not self.holds[hold] then
					b.BackgroundColor3 = Color3.new(0, 0, 0)
				end
			end)
		end
		return b
	end
	button("FIRE", 112, 30, 30, "fire")
	button("UP", 66, 156, 104, "up")
	button("DOWN", 66, 156, 30, "down")
	button("WPN", 54, 30, 156, nil, actions.weapon)
	button("FLR", 54, 92, 156, nil, actions.flares)
	button("CAM", 54, 30, 218, nil, actions.camera)
	button("BOOM", 54, 92, 218, nil, actions.detonate)
	button("RESET", 54, 154, 218, nil, actions.reset)
	return self
end

-- The aim drag since the last frame, in mouse pixels.
function Touch:takeLook(): Vector2
	local look = self.look
	self.look = Vector2.zero
	return look
end

function Touch:setVisible(visible: boolean)
	self.gui.Enabled = visible
end

return Touch
