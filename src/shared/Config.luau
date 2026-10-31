--!strict
-- Every tuning knob for the drone in one place.
-- Units: studs, seconds, radians (deg/s only where a name says Rate under Acro).

local Config = {
	-- Physics
	Gravity = 70, -- drone-only gravity; world gravity is cancelled on the drone
	ThrustToWeight = 4.5,
	DragQuadratic = 0.0065, -- drag accel = -(quadratic * |v| + linear) * v
	DragLinear = 0.08,
	TorquePerMass = 600, -- AngularVelocity.MaxTorque = AssemblyMass * this
	RateSmoothing = 0.035, -- seconds of lag on commanded rates (props spinning up)

	-- Self-levelling attitude controller (Aim and Angle modes)
	AttitudeGain = 12,
	MaxBodyRate = Vector3.new(11, 6, 11), -- pitch, yaw, roll

	GroundEffectHeight = 6,
	GroundEffectBoost = 0.2,
	CrashSpeed = 45, -- velocity lost in one frame that knocks the drone out (thrust alone can't exceed ~16)
	CrashRecover = 0.8,
	PropWash = 4, -- rad/s of wobble when sinking through your own downwash

	Aim = {
		CruiseSpeed = 90,
		BoostSpeed = 165,
		ClimbSpeed = 50,
		AccelGain = 3.2,
		BrakeGain = 1.8,
		MaxTilt = math.rad(55),
		BoostTilt = math.rad(72),
		MouseSensitivity = 0.0032, -- rad per pixel
		StickYaw = 3, -- gamepad aim rates
		StickPitch = 2.2,
	},

	Angle = {
		MaxTilt = math.rad(50),
		YawRate = 3.2,
		MouseYaw = 0.005,
		ClimbSpeed = 50,
		ClimbGain = 4,
	},

	Acro = {
		-- Betaflight "Actual" rates, deg/s
		CenterRate = 70,
		MaxRate = 670,
		YawCenterRate = 70,
		YawMaxRate = 480,
		Expo = 0.54,
		MouseSensitivity = 0.0045, -- rad per pixel
		ThrottleRamp = 0.9, -- keyboard throttle change per second
	},

	Camera = {
		ChaseDistance = 11,
		ChaseHeight = 2.6,
		FollowStiffness = 14,
		MaxLag = 7,
		BaseFov = 70,
		SpeedFov = 0.14,
		BoostFov = 6,
		MaxFov = 100,
		FpvFov = 92,
		OrbitFov = 55,
	},

	Audio = {
		Motor = "rbxassetid://99450653431986", -- Creator Store "drone_hover_loop" (GladGhost6)
		Wind = "rbxasset://sounds/action_falling.ogg",
		Launch = "rbxassetid://717392973", -- Creator Store "Missile Launch", marked free to use (frstee)
		LockBeep = "rbxassetid://9117060347", -- Pro Sound Effects "Nasa Transmission Beep 1"
		Explosion = "rbxasset://sounds/impact_explosion_03.mp3",
	},

	Battery = {
		Seconds = 300, -- flight time at full throttle
		FullVolts = 16.8,
		EmptyVolts = 13.6,
		SagVolts = 0.9,
		WeakThrust = 0.82, -- thrust multiplier on an empty pack
	},
}

return Config
