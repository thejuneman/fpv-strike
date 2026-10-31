-- Turns input into thrust and body rates for the three flight modes, then drives the
-- drone's VectorForce and AngularVelocity. Runs on the owning client; the math is in FlightModel.
--
--   Aim    mouse picks a direction, the autopilot tilts the thrust vector to fly there
--   Angle  sticks command tilt, the drone self-levels and holds altitude
--   Acro   sticks command rotation rates (Betaflight rates), nothing is automatic

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local FlightModel = require(Shared:WaitForChild("FlightModel"))
local Smooth = require(Shared:WaitForChild("Smooth"))
local DroneBuilder = require(Shared:WaitForChild("DroneBuilder"))

local Controller = {}
Controller.__index = Controller
Controller.Modes = { "Aim", "Angle", "Acro" }

local GAMEPAD = Enum.UserInputType.Gamepad1

local function key(code: Enum.KeyCode): number
	return if UserInputService:IsKeyDown(code) then 1 else 0
end

local function deadzone(stick: Vector2): Vector2
	local m = stick.Magnitude
	if m < 0.15 then
		return Vector2.zero
	end
	return stick.Unit * math.min((m - 0.15) / 0.85, 1)
end

local function readPad()
	local pad = { left = Vector2.zero, right = Vector2.zero, lt = 0, rt = 0, boost = false }
	if not UserInputService:GetGamepadConnected(GAMEPAD) then
		return pad
	end
	for _, input in UserInputService:GetGamepadState(GAMEPAD) do
		local p = input.Position
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			pad.left = deadzone(Vector2.new(p.X, p.Y))
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			pad.right = deadzone(Vector2.new(p.X, p.Y))
		elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
			pad.lt = p.Z
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
			pad.rt = p.Z
		end
	end
	pad.boost = UserInputService:IsGamepadButtonDown(GAMEPAD, Enum.KeyCode.ButtonL1)
	return pad
end

local function readKeys()
	if UserInputService:GetFocusedTextBox() then
		return { forward = 0, side = 0, vertical = 0, yaw = 0, boost = false }
	end
	return {
		forward = key(Enum.KeyCode.W) - key(Enum.KeyCode.S),
		side = key(Enum.KeyCode.D) - key(Enum.KeyCode.A),
		vertical = key(Enum.KeyCode.Space) - key(Enum.KeyCode.LeftControl),
		yaw = key(Enum.KeyCode.E) - key(Enum.KeyCode.Q),
		boost = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift),
	}
end

function Controller.new(drone: Model)
	local root = drone.PrimaryPart :: BasePart
	local self = setmetatable({}, Controller)
	self.drone = drone
	self.root = root
	self.force = root:WaitForChild("Thrust") :: VectorForce
	self.rate = root:WaitForChild("Rate") :: AngularVelocity
	self.mode = "Aim"
	self.motors = { 0, 0, 0, 0 } -- per-motor output 0..1, read by the visuals
	self.ray = RaycastParams.new()
	self.ray.FilterType = Enum.RaycastFilterType.Exclude
	self.ray.FilterDescendantsInstances = { drone }
	self:reset(true)
	return self
end

-- Puts the drone back on the pad, disarmed with a full battery.
function Controller:reset(stayInPlace: boolean?)
	if not stayInPlace then
		self.root.AssemblyLinearVelocity = Vector3.zero
		self.root.AssemblyAngularVelocity = Vector3.zero
		self.drone:PivotTo(self.drone:GetAttribute("SpawnCFrame"))
	end
	self.armed = false
	self.boosting = false
	self.throttle = 0
	self.throttleSet = 0
	self.battery = 1
	self.crashTimer = 0
	self.height = 0
	self.clock = 0
	self.bodyRate = Vector3.zero
	self.mouseRate = Vector3.zero
	self.lastVelocity = Vector3.zero
	self:_syncHeading()
end

function Controller:_syncHeading()
	self.aimYaw = FlightModel.yawOf(self.root.CFrame)
	self.aimPitch = 0
	self.headingYaw = self.aimYaw
end

function Controller:cycleMode()
	local i = table.find(Controller.Modes, self.mode) or 1
	self.mode = Controller.Modes[i % #Controller.Modes + 1]
	self:_syncHeading()
	self.throttleSet = self.throttle
	self.mouseRate = Vector3.zero
end

function Controller:aimDirection(): Vector3
	return CFrame.fromOrientation(self.aimPitch, self.aimYaw, 0).LookVector
end

function Controller:_limits(maxThrust: number, maxTilt: number): FlightModel.Limits
	return {
		gravity = Config.Gravity,
		maxThrust = maxThrust,
		maxTilt = maxTilt,
		quadratic = Config.DragQuadratic,
		linear = Config.DragLinear,
	}
end

function Controller:_aim(dt, mouse: Vector2, kb, pad, cf: CFrame, v: Vector3, maxThrust: number)
	local cfg = Config.Aim
	self.aimYaw -= mouse.X * cfg.MouseSensitivity + pad.right.X * cfg.StickYaw * dt
	self.aimPitch = math.clamp(self.aimPitch - mouse.Y * cfg.MouseSensitivity + pad.right.Y * cfg.StickPitch * dt, -1.35, 1.35)

	local forward = math.clamp(kb.forward + pad.left.Y, -1, 1)
	local side = math.clamp(kb.side + pad.left.X, -1, 1)
	local vertical = math.clamp(kb.vertical + pad.rt - pad.lt, -1, 1)
	local flatRight = Vector3.new(math.cos(self.aimYaw), 0, -math.sin(self.aimYaw))
	local move = self:aimDirection() * forward + flatRight * side
	if move.Magnitude > 1 then
		move = move.Unit
	end

	local speed = if self.boosting then cfg.BoostSpeed else cfg.CruiseSpeed
	local wanted = move * speed + Vector3.new(0, vertical * cfg.ClimbSpeed, 0)
	-- Braking is gentler than accelerating so the drone carries momentum like a real quad.
	local gain = if move.Magnitude > 0.05 or vertical ~= 0 then cfg.AccelGain else cfg.BrakeGain
	local tilt = if self.boosting then cfg.BoostTilt else cfg.MaxTilt
	local thrust = FlightModel.thrustFor(v, wanted, gain, self:_limits(maxThrust, tilt))

	local heading = Vector3.new(-math.sin(self.aimYaw), 0, -math.cos(self.aimYaw))
	local target = FlightModel.attitudeFrom(thrust.Unit, heading)
	return FlightModel.attitudeRates(cf, target, Config.AttitudeGain, Config.MaxBodyRate),
		FlightModel.throttleFor(thrust, cf.UpVector, maxThrust)
end

function Controller:_angle(dt, mouse: Vector2, kb, pad, cf: CFrame, v: Vector3, maxThrust: number)
	local cfg = Config.Angle
	self.headingYaw -= mouse.X * cfg.MouseYaw + math.clamp(kb.yaw + pad.left.X, -1, 1) * cfg.YawRate * dt

	local stick = Vector2.new(kb.side + pad.right.X, kb.forward + pad.right.Y)
	if stick.Magnitude > 1 then
		stick = stick.Unit
	end
	local target = CFrame.Angles(0, self.headingYaw, 0)
	if stick.Magnitude > 1e-3 then
		local toward = Vector3.new(stick.X, 0, -stick.Y)
		target *= CFrame.fromAxisAngle(Vector3.yAxis:Cross(toward).Unit, stick.Magnitude * cfg.MaxTilt)
	end

	-- Altitude hold: throttle chases a climb rate, compensating for tilt and drag.
	local climb = math.clamp(kb.vertical + pad.left.Y, -1, 1) * cfg.ClimbSpeed
	local drag = FlightModel.drag(v, Config.DragQuadratic, Config.DragLinear)
	local lift = (climb - v.Y) * cfg.ClimbGain + Config.Gravity - drag.Y
	local throttle = math.clamp(lift / (math.max(cf.UpVector.Y, 0.3) * maxThrust), 0, 1)
	return FlightModel.attitudeRates(cf, target, Config.AttitudeGain, Config.MaxBodyRate), throttle
end

function Controller:_acro(dt, mouse: Vector2, kb, pad)
	local cfg = Config.Acro
	-- The mouse turns the drone like an FPS camera; sticks go through Betaflight rates.
	local mouseRate = Vector3.new(-mouse.Y, 0, -mouse.X) * (cfg.MouseSensitivity / dt)
	self.mouseRate = Smooth.damp(self.mouseRate, mouseRate, 25, dt)
	local yaw = math.clamp(kb.side + pad.left.X, -1, 1)
	local rates = Vector3.new(
		-math.rad(FlightModel.actualRate(pad.right.Y, cfg.CenterRate, cfg.MaxRate, cfg.Expo)),
		-math.rad(FlightModel.actualRate(yaw, cfg.YawCenterRate, cfg.YawMaxRate, cfg.Expo)),
		-math.rad(FlightModel.actualRate(pad.right.X, cfg.CenterRate, cfg.MaxRate, cfg.Expo))
	) + self.mouseRate

	local ramp = math.clamp(kb.forward + kb.vertical, -1, 1)
	self.throttleSet = math.clamp(self.throttleSet + ramp * cfg.ThrottleRamp * dt, 0, 1)
	local throttle = if pad.rt > 0.02 then pad.rt else self.throttleSet
	if self.boosting then
		throttle = 1
	end
	return rates, throttle
end

function Controller:step(dt: number, mouse: Vector2)
	dt = math.min(dt, 1 / 20)
	self.clock += dt
	local root = self.root
	if root.Position.Y < -40 then
		self:reset() -- fell off the world
	end
	local cf = root.CFrame
	local v = root.AssemblyLinearVelocity
	local kb, pad = readKeys(), readPad()
	self.boosting = kb.boost or pad.boost

	local hit = workspace:Raycast(cf.Position, Vector3.new(0, -50, 0), self.ray)
	self.height = if hit then hit.Distance - root.Size.Y / 2 else 50

	if not self.armed and (kb.vertical > 0 or kb.forward > 0 or pad.rt > 0.2 or pad.left.Magnitude > 0.3) then
		self.armed = true
	end
	-- A hard hit kills the motors for a moment and lets the quad tumble.
	if self.armed and (v - self.lastVelocity).Magnitude > Config.CrashSpeed then
		self.crashTimer = Config.CrashRecover
	end
	self.lastVelocity = v
	self.crashTimer = math.max(self.crashTimer - dt, 0)

	local bat = Config.Battery
	local maxThrust = Config.Gravity * Config.ThrustToWeight * (bat.WeakThrust + (1 - bat.WeakThrust) * self.battery)
	local rates, throttle
	if self.mode == "Aim" then
		rates, throttle = self:_aim(dt, mouse, kb, pad, cf, v, maxThrust)
	elseif self.mode == "Angle" then
		rates, throttle = self:_angle(dt, mouse, kb, pad, cf, v, maxThrust)
	else
		rates, throttle = self:_acro(dt, mouse, kb, pad)
	end
	if not self.armed or self.crashTimer > 0 then
		rates, throttle = Vector3.zero, 0
	end

	-- Props take a moment to spin up, so commanded rates never land instantly.
	self.bodyRate = Smooth.damp(self.bodyRate, rates, 1 / Config.RateSmoothing, dt)
	local commanded = self.bodyRate

	-- Prop wash: sinking through your own downwash at low airspeed shakes the quad.
	local bodyV = cf:VectorToObjectSpace(v)
	local sink = math.clamp((-bodyV.Y - 12) / 30, 0, 1)
	local still = math.clamp(1 - Vector2.new(bodyV.X, bodyV.Z).Magnitude / 45, 0, 1)
	local wash = sink * still * math.clamp(throttle * 3, 0, 1)
	if wash > 0 then
		local t = self.clock * 9
		commanded += Vector3.new(math.noise(t, 1.3), 0, math.noise(t, 7.1)) * (Config.PropWash * 2 * wash)
	end

	self.throttle = throttle
	self.battery = math.max(self.battery - dt * (0.1 + throttle) / bat.Seconds, 0)

	local cushion = math.clamp(1 - self.height / Config.GroundEffectHeight, 0, 1)
	local groundEffect = 1 + Config.GroundEffectBoost * cushion * cushion
	local mass = root.AssemblyMass
	local accel = cf.UpVector * (throttle * maxThrust * groundEffect)
		+ FlightModel.drag(v, Config.DragQuadratic, Config.DragLinear)
		+ Vector3.new(0, workspace.Gravity - Config.Gravity, 0)
	self.force.Force = accel * mass
	self.rate.Enabled = self.crashTimer <= 0
	self.rate.MaxTorque = mass * Config.TorquePerMass
	self.rate.AngularVelocity = commanded

	-- Rough X-quad motor mix, only for the visuals: the props that do the turning spin harder.
	local spin = cf:VectorToObjectSpace(root.AssemblyAngularVelocity)
	local demand = (commanded - spin) * 0.08
	for i, m in DroneBuilder.Motors do
		local out = throttle - demand.X * m.z + demand.Z * m.x + demand.Y * m.spin * 0.5
		local target = if self.armed and self.crashTimer <= 0 then math.clamp(out, 0.06, 1) else 0
		self.motors[i] = Smooth.damp(self.motors[i], target, 20, dt)
	end
end

return Controller
