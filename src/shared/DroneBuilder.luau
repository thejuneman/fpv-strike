--!strict
-- Builds the quad from primitive parts so the whole asset lives in source control.
-- Only Root collides and carries mass; every other part is welded, massless and non-colliding.
-- Layout: +X right, +Y up, -Z nose.

local DroneBuilder = {}

local CARBON = Color3.fromRGB(28, 29, 34)
local CARBON_LIGHT = Color3.fromRGB(52, 54, 62)
local ANODIZED = Color3.fromRGB(226, 52, 64)
local ACCENT = Color3.fromRGB(62, 232, 255)
local REAR_LIGHT = Color3.fromRGB(255, 64, 88)
local SILVER = Color3.fromRGB(190, 194, 200)

local ARM_REACH = 1.25
local PROP_RADIUS = 0.95
local CAMERA_UPTILT = math.rad(25)

local VERTICAL = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y
local FORWARD = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis X -> -Z

-- Shared with the controller and visuals so motor order is defined once. Props-out spin.
DroneBuilder.Motors = {
	{ name = "FrontLeft", x = -1, z = -1, spin = 1 },
	{ name = "FrontRight", x = 1, z = -1, spin = -1 },
	{ name = "RearLeft", x = -1, z = 1, spin = -1 },
	{ name = "RearRight", x = 1, z = 1, spin = 1 },
}

local function newPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

local function attachment(parent: Instance, name: string, cframe: CFrame): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = cframe
	a.Parent = parent
	return a
end

function DroneBuilder.build(): Model
	local model = Instance.new("Model")
	model.Name = "Drone"

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(2.6, 1, 2.6) -- tall enough that pods and rails clear the ground
	root.Transparency = 1
	root.CanTouch = false
	root.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.2)
	root.Parent = model
	model.PrimaryPart = root

	local welded: { BasePart } = {}
	local function add(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
		local p = newPart(model, name, size, cf, color, material, shape)
		table.insert(welded, p)
		return p
	end

	-- Frame: two plates on anodized standoffs
	add("BottomPlate", Vector3.new(1, 0.08, 2.1), CFrame.new(0, -0.14, 0), CARBON)
	add("TopPlate", Vector3.new(0.9, 0.06, 1.35), CFrame.new(0, 0.2, 0.05), CARBON)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local cf = CFrame.new(sx * 0.36, 0.035, sz * 0.52) * VERTICAL
			add("Standoff", Vector3.new(0.27, 0.08, 0.08), cf, ANODIZED, Enum.Material.Metal, Enum.PartType.Cylinder)
		end
	end
	add("StatusLed", Vector3.new(0.08, 0.03, 0.08), CFrame.new(0.32, 0.245, -0.52), Color3.fromRGB(80, 255, 120), Enum.Material.Neon)

	-- Arms, motors and props
	for _, m in DroneBuilder.Motors do
		local motorPos = Vector3.new(m.x * ARM_REACH, -0.1, m.z * ARM_REACH)
		local armLength = Vector3.new(motorPos.X, 0, motorPos.Z).Magnitude
		local armCf = CFrame.new(motorPos * Vector3.new(0.5, 1, 0.5)) * CFrame.Angles(0, math.atan2(m.x, m.z), 0)
		add(m.name .. "Arm", Vector3.new(0.3, 0.1, armLength + 0.2), armCf, CARBON)
		local ledColor = if m.z < 0 then ACCENT else REAR_LIGHT
		add(m.name .. "Led", Vector3.new(0.08, 0.04, armLength * 0.6), armCf * CFrame.new(0, -0.07, 0), ledColor, Enum.Material.Neon)

		local function at(y: number): CFrame
			return CFrame.new(motorPos + Vector3.new(0, y, 0)) * VERTICAL
		end
		add(m.name .. "Stator", Vector3.new(0.08, 0.5, 0.5), at(0.09), CARBON_LIGHT, Enum.Material.Metal, Enum.PartType.Cylinder)
		add(m.name .. "Bell", Vector3.new(0.26, 0.46, 0.46), at(0.26), ANODIZED, Enum.Material.Metal, Enum.PartType.Cylinder)
		add(m.name .. "Cap", Vector3.new(0.05, 0.22, 0.22), at(0.415), SILVER, Enum.Material.Metal, Enum.PartType.Cylinder)
		add(m.name .. "Foot", Vector3.new(0.35, 0.16, 0.16), at(-0.225), CARBON, Enum.Material.Rubber, Enum.PartType.Cylinder)

		-- Tri-blade prop on a Motor6D so the client can spin it through Transform
		local hubPos = motorPos + Vector3.new(0, 0.49, 0)
		local hub = newPart(model, m.name .. "Hub", Vector3.new(0.1, 0.18, 0.18), at(0.49), SILVER, Enum.Material.Metal, Enum.PartType.Cylinder)
		for i = 0, 2 do
			local bladeCf = CFrame.new(hubPos)
				* CFrame.Angles(0, i * math.pi * 2 / 3, 0)
				* CFrame.new(0, 0, -(PROP_RADIUS / 2 + 0.04))
				* CFrame.Angles(0, 0, math.rad(14) * m.spin)
			local blade = newPart(hub, "Blade", Vector3.new(0.17, 0.03, PROP_RADIUS - 0.08), bladeCf, ACCENT)
			blade.Transparency = 0.15
			weld(hub, blade)
		end
		local joint = Instance.new("Motor6D")
		joint.Name = m.name .. "Prop"
		joint.Part0 = root
		joint.Part1 = hub
		joint.C0 = CFrame.new(hubPos)
		joint.C1 = VERTICAL:Inverse()
		joint.Parent = root

		-- Motion-blur disc, faded in by the client as the prop spins up
		local disc = add(m.name .. "Disc", Vector3.new(0.02, PROP_RADIUS * 2, PROP_RADIUS * 2), at(0.5), Color3.fromRGB(205, 245, 255), nil, Enum.PartType.Cylinder)
		disc.Transparency = 1
		disc.CastShadow = false
	end

	-- FPV camera, tilted up like a real freestyle quad
	for _, sx in { -1, 1 } do
		add("CameraCage", Vector3.new(0.05, 0.36, 0.44), CFrame.new(sx * 0.31, 0.03, -0.92), CARBON_LIGHT)
	end
	local camCf = CFrame.new(0, 0.03, -0.94) * CFrame.Angles(CAMERA_UPTILT, 0, 0)
	add("CameraBody", Vector3.new(0.44, 0.38, 0.38), camCf, CARBON)
	add("CameraLensRing", Vector3.new(0.05, 0.34, 0.34), camCf * CFrame.new(0, 0, -0.2) * FORWARD, ACCENT, Enum.Material.Neon, Enum.PartType.Cylinder)
	local lens = add("CameraLens", Vector3.new(0.12, 0.28, 0.28), camCf * CFrame.new(0, 0, -0.24) * FORWARD, Color3.fromRGB(8, 10, 14), Enum.Material.Glass, Enum.PartType.Cylinder)
	lens.Reflectance = 0.35
	attachment(root, "FpvCamera", camCf * CFrame.new(0, 0, -0.32))

	-- Battery and strap
	add("Battery", Vector3.new(0.62, 0.42, 1.2), CFrame.new(0, 0.44, 0.08), Color3.fromRGB(36, 37, 42))
	add("BatteryLabel", Vector3.new(0.64, 0.18, 0.86), CFrame.new(0, 0.46, 0.08), Color3.fromRGB(245, 196, 40))
	add("Strap", Vector3.new(0.68, 0.46, 0.14), CFrame.new(0, 0.43, -0.16), ANODIZED, Enum.Material.Fabric)

	-- Video antenna, raked back
	add("AntennaMount", Vector3.new(0.22, 0.1, 0.2), CFrame.new(0, 0.28, 0.8), CARBON_LIGHT)
	local rake = Vector3.new(0, math.cos(math.rad(35)), math.sin(math.rad(35)))
	local antennaBase = Vector3.new(0, 0.32, 0.84)
	add("Antenna", Vector3.new(0.8, 0.05, 0.05), CFrame.fromMatrix(antennaBase + rake * 0.4, rake, Vector3.new(1, 0, 0)), CARBON, nil, Enum.PartType.Cylinder)
	add("AntennaTip", Vector3.new(0.16, 0.16, 0.16), CFrame.new(antennaBase + rake * 0.82), ANODIZED, nil, Enum.PartType.Ball)

	-- Rocket pods under the front arms, missile rails under the body. Launch points are
	-- attachments the client reads when it fires; rail missiles carry a Rail index so the
	-- client can hide them as they're spent.
	for _, sx in { -1, 1 } do
		local side = if sx < 0 then "Left" else "Right"
		add("Pod", Vector3.new(1, 0.3, 0.3), CFrame.new(sx * 0.78, -0.3, -0.8) * FORWARD, CARBON_LIGHT, Enum.Material.Metal, Enum.PartType.Cylinder)
		add("PodRing", Vector3.new(0.06, 0.32, 0.32), CFrame.new(sx * 0.78, -0.3, -1.28) * FORWARD, ANODIZED, Enum.Material.Metal, Enum.PartType.Cylinder)
		add("PodFace", Vector3.new(0.02, 0.24, 0.24), CFrame.new(sx * 0.78, -0.3, -1.31) * FORWARD, Color3.fromRGB(10, 10, 12), nil, Enum.PartType.Cylinder)
		attachment(root, "Pod" .. side, CFrame.new(sx * 0.78, -0.3, -1.35))

		add("Rail", Vector3.new(0.08, 0.06, 1.2), CFrame.new(sx * 0.4, -0.21, 0.05), CARBON_LIGHT, Enum.Material.Metal)
		local rail = if sx < 0 then 1 else 2
		local body = add("RailMissile", Vector3.new(1.3, 0.16, 0.16), CFrame.new(sx * 0.4, -0.32, 0.05) * FORWARD, Color3.fromRGB(232, 232, 236), nil, Enum.PartType.Cylinder)
		local nose = add("RailMissileNose", Vector3.new(0.16, 0.16, 0.16), CFrame.new(sx * 0.4, -0.32, -0.6), ANODIZED, nil, Enum.PartType.Ball)
		local fin = add("RailMissileFin", Vector3.new(0.3, 0.02, 0.2), CFrame.new(sx * 0.4, -0.32, 0.62), CARBON)
		for _, p in { body, nose, fin } do
			p:SetAttribute("Rail", rail)
		end
		attachment(root, "Rail" .. side, CFrame.new(sx * 0.4, -0.34, -0.65))
	end

	-- Underglow
	local glow = Instance.new("PointLight")
	glow.Name = "Underglow"
	glow.Color = ACCENT
	glow.Range = 9
	glow.Brightness = 0.5
	glow.Shadows = false
	glow.Parent = attachment(root, "Glow", CFrame.new(0, -0.3, 0))

	-- Light trails off the rear motors
	for _, m in DroneBuilder.Motors do
		if m.z > 0 then
			local base = Vector3.new(m.x * ARM_REACH, 0.15, m.z * ARM_REACH + 0.1)
			local trail = Instance.new("Trail")
			trail.Name = m.name .. "Trail"
			trail.Attachment0 = attachment(root, m.name .. "TrailTop", CFrame.new(base + Vector3.new(0, 0.12, 0)))
			trail.Attachment1 = attachment(root, m.name .. "TrailBottom", CFrame.new(base - Vector3.new(0, 0.12, 0)))
			trail.FaceCamera = true
			trail.Lifetime = 0.45
			trail.MinLength = 0.05
			trail.LightEmission = 1
			trail.LightInfluence = 0
			trail.Color = ColorSequence.new(ACCENT, Color3.fromRGB(190, 250, 255))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
			trail.Enabled = false
			trail.Parent = root
		end
	end

	-- Actuators the owning client drives every frame
	local center = attachment(root, "Center", CFrame.new())
	local thrust = Instance.new("VectorForce")
	thrust.Name = "Thrust"
	thrust.Attachment0 = center
	thrust.RelativeTo = Enum.ActuatorRelativeTo.World
	thrust.ApplyAtCenterOfMass = true
	thrust.Force = Vector3.zero
	thrust.Parent = root

	local rate = Instance.new("AngularVelocity")
	rate.Name = "Rate"
	rate.Attachment0 = center
	rate.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	rate.MaxTorque = 0
	rate.AngularVelocity = Vector3.zero
	rate.Parent = root

	for _, p in welded do
		weld(root, p)
	end
	return model
end

return DroneBuilder
