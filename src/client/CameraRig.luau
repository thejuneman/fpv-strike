-- Chase, FPV and orbit cameras. Every bit of smoothing is framerate independent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local FlightModel = require(Shared:WaitForChild("FlightModel"))
local Smooth = require(Shared:WaitForChild("Smooth"))

local CameraRig = {}
CameraRig.__index = CameraRig
CameraRig.Modes = { "Chase", "Fpv", "Orbit" }

function CameraRig.new(drone: Model)
	local self = setmetatable({}, CameraRig)
	local root = drone.PrimaryPart :: BasePart
	local yaw = FlightModel.yawOf(root.CFrame)
	self.camera = workspace.CurrentCamera
	self.root = root
	self.mount = root:WaitForChild("FpvCamera") :: Attachment
	self.mode = "Chase"
	self.focus = root.Position
	self.focusVelocity = Vector3.zero
	self.basis = CFrame.fromOrientation(-0.22, yaw, 0)
	self.roll = 0
	self.trauma = 0
	self.fov = Config.Camera.BaseFov
	self.chaseDistance = Config.Camera.ChaseDistance
	self.orbitYaw = yaw + math.pi * 0.75
	self.orbitPitch = -0.35
	self.orbitDistance = 9
	self.ray = RaycastParams.new()
	self.ray.FilterType = Enum.RaycastFilterType.Exclude
	return self
end

function CameraRig:cycle()
	local i = table.find(CameraRig.Modes, self.mode) or 1
	self.mode = CameraRig.Modes[i % #CameraRig.Modes + 1]
end

-- Trauma-based shake: hits add trauma, shake grows with its square and decays on its own.
function CameraRig:shake(amount: number)
	self.trauma = math.min(self.trauma + amount, 1)
end

function CameraRig:zoom(direction: number)
	if self.mode == "Orbit" then
		self.orbitDistance = math.clamp(self.orbitDistance + direction * 1.5, 4, 40)
	else
		self.chaseDistance = math.clamp(self.chaseDistance + direction * 1.2, 6, 24)
	end
end

-- Pulls the camera in front of walls so flying indoors never clips through geometry.
function CameraRig:_unblocked(from: Vector3, to: Vector3): Vector3
	self.ray.FilterDescendantsInstances = { workspace:FindFirstChild("Drones"), Players.LocalPlayer.Character }
	local offset = to - from
	local hit = workspace:Spherecast(from, 0.4, offset, self.ray)
	if hit then
		return from + offset.Unit * math.max(hit.Distance - 0.2, 0.5)
	end
	return to
end

function CameraRig:update(dt: number, ctrl, mouse: Vector2)
	local cam = self.camera
	local cfg = Config.Camera
	local cf = self.root.CFrame
	local speed = self.root.AssemblyLinearVelocity.Magnitude
	cam.CameraType = Enum.CameraType.Scriptable

	local targetFov
	if self.mode == "Fpv" then
		-- Rigid like a real FPV camera, plus a faint high-frequency buzz from the motors.
		local t = os.clock() * 37
		local buzz = 0.0035 * ctrl.throttle
		cam.CFrame = self.mount.WorldCFrame * CFrame.Angles(math.noise(t, 0.5) * buzz, math.noise(t, 3.7) * buzz, 0)
		targetFov = cfg.FpvFov
	else
		-- A spring follows the drone; capping the lag keeps a sense of speed without losing it.
		self.focus, self.focusVelocity = Smooth.spring(self.focus, self.focusVelocity, cf.Position, cfg.FollowStiffness, dt)
		local lag = self.focus - cf.Position
		if lag.Magnitude > cfg.MaxLag then
			self.focus = cf.Position + lag.Unit * cfg.MaxLag
		end

		if self.mode == "Orbit" then
			self.orbitYaw -= mouse.X * 0.005
			self.orbitPitch = math.clamp(self.orbitPitch - mouse.Y * 0.005, -1.45, 1.2)
			local look = CFrame.fromOrientation(self.orbitPitch, self.orbitYaw, 0).LookVector
			cam.CFrame = CFrame.lookAt(self:_unblocked(self.focus, self.focus - look * self.orbitDistance), self.focus)
			targetFov = cfg.OrbitFov
		else
			if ctrl.mode == "Aim" then
				-- Locked to the aim: the mouse is already smooth and any lag here reads as input lag.
				self.basis = CFrame.fromOrientation(ctrl.aimPitch, ctrl.aimYaw, 0)
			else
				local behind = CFrame.fromOrientation(-0.22, FlightModel.yawOf(cf), 0)
				self.basis = self.basis:Lerp(behind, Smooth.alpha(6, dt))
			end
			-- Lean a little with the drone's bank so turns read on screen.
			local bank = math.asin(math.clamp(self.basis:VectorToObjectSpace(cf.RightVector).Y, -1, 1))
			self.roll = Smooth.damp(self.roll, bank * 0.15, 8, dt)
			local rot = self.basis * CFrame.Angles(0, 0, self.roll)
			local pivot = self.focus + Vector3.new(0, 0.6, 0)
			local wanted = pivot + rot.UpVector * cfg.ChaseHeight - rot.LookVector * self.chaseDistance
			cam.CFrame = CFrame.new(self:_unblocked(pivot, wanted)) * rot
			local boost = if ctrl.boosting then cfg.BoostFov else 0
			targetFov = math.min(cfg.BaseFov + math.max(speed - 25, 0) * cfg.SpeedFov + boost, cfg.MaxFov)
		end
	end
	self.trauma = math.max(self.trauma - dt * 1.4, 0)
	if self.trauma > 0 then
		local t = os.clock() * 25
		local s = self.trauma * self.trauma * 0.06
		cam.CFrame *= CFrame.Angles(math.noise(t, 11) * s, math.noise(t, 23) * s, math.noise(t, 37) * s)
	end
	self.fov = Smooth.damp(self.fov, targetFov, 5, dt)
	cam.FieldOfView = self.fov
end

return CameraRig
