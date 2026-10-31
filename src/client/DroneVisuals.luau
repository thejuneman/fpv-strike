-- Spinning props with motion blur, speed-scaled trails, underglow and wind audio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local DroneBuilder = require(Shared:WaitForChild("DroneBuilder"))

local DroneVisuals = {}
DroneVisuals.__index = DroneVisuals

local PROP_SPEED = 140 -- on-screen rad/s at full throttle; above ~60 blades blur into a disc

local function loop(parent: Instance, name: string, soundId: string): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = parent
	sound:Play()
	return sound
end

function DroneVisuals.new(drone: Model)
	local self = setmetatable({}, DroneVisuals)
	local root = drone.PrimaryPart :: BasePart
	self.root = root

	self.props = {}
	for i, m in DroneBuilder.Motors do
		local joint = root:WaitForChild(m.name .. "Prop") :: Motor6D
		local blades = {}
		for _, child in (joint.Part1 :: BasePart):GetChildren() do
			if child:IsA("BasePart") then
				table.insert(blades, child)
			end
		end
		self.props[i] = {
			joint = joint,
			blades = blades,
			disc = drone:WaitForChild(m.name .. "Disc") :: BasePart,
			spin = m.spin,
			angle = math.random() * math.pi * 2,
		}
	end

	self.trails = {}
	for _, child in root:GetChildren() do
		if child:IsA("Trail") then
			table.insert(self.trails, child)
		end
	end
	self.glow = root:WaitForChild("Glow"):WaitForChild("Underglow") :: PointLight

	self.motor = loop(root, "Motor", Config.Audio.Motor)
	self.wind = loop(root, "Wind", Config.Audio.Wind)
	return self
end

function DroneVisuals:update(dt: number, ctrl, fpv: boolean)
	-- From the FPV camera the props sit right beside the lens; keep only a ghost of them.
	local ghost = if fpv then 0.93 else 0
	for i, prop in self.props do
		local omega = ctrl.motors[i] * PROP_SPEED
		prop.angle = (prop.angle + omega * dt * prop.spin) % (math.pi * 2)
		prop.joint.Transform = CFrame.Angles(0, prop.angle, 0)
		local blur = math.clamp((omega - 12) / 50, 0, 1)
		for _, blade in prop.blades do
			blade.Transparency = 0.15 + 0.8 * blur
			blade.LocalTransparencyModifier = ghost
		end
		prop.disc.Transparency = 1 - 0.24 * blur
		prop.disc.LocalTransparencyModifier = ghost
	end

	local speed = self.root.AssemblyLinearVelocity.Magnitude
	local width = math.clamp(speed / 110, 0.25, 1.3)
	for _, trail in self.trails do
		trail.Enabled = speed > 30
		trail.WidthScale = NumberSequence.new(width, 0.1)
	end

	self.glow.Brightness = if ctrl.armed then 0.5 + ctrl.throttle * 1.6 else 0.3

	-- Motor pitch follows the average prop speed, so turns and punches are audible.
	local rpm = (ctrl.motors[1] + ctrl.motors[2] + ctrl.motors[3] + ctrl.motors[4]) / 4
	self.motor.Volume = if rpm > 0.01 then 0.25 + rpm * 0.45 else 0
	self.motor.PlaybackSpeed = 0.75 + rpm * 0.9
	self.wind.Volume = math.clamp((speed - 20) / 140, 0, 1) * 0.6
	self.wind.PlaybackSpeed = 0.8 + math.clamp(speed / 200, 0, 0.6)
end

return DroneVisuals
