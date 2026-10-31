--!strict
-- Pure flight math. No instances or services, so it also runs under Lune for tests.
-- Body frame matches Roblox: +X right, +Y up, -Z nose.
-- Body rates are Vector3(pitch, yaw, roll) = rotation about X, Y, Z in rad/s.

local FlightModel = {}

export type Limits = {
	gravity: number,
	maxThrust: number, -- acceleration at full throttle
	maxTilt: number,
	quadratic: number,
	linear: number,
}

-- Betaflight "Actual" rates. stick in [-1, 1]; center/max in deg/s; expo in [0, 1].
function FlightModel.actualRate(stick: number, center: number, max: number, expo: number): number
	local curve = math.abs(stick) * (stick ^ 5 * expo + stick * (1 - expo))
	return stick * center + math.max(0, max - center) * curve
end

function FlightModel.drag(v: Vector3, quadratic: number, linear: number): Vector3
	return -v * (quadratic * v.Magnitude + linear)
end

function FlightModel.yawOf(cf: CFrame): number
	local look = cf.LookVector
	return math.atan2(-look.X, -look.Z)
end

-- Attitude whose up axis is `up`, with the nose as close to `heading` as that allows.
function FlightModel.attitudeFrom(up: Vector3, heading: Vector3): CFrame
	local nose = heading - up * heading:Dot(up)
	if nose.Magnitude < 1e-4 then
		local other = if math.abs(up.Y) < 0.9 then Vector3.new(0, 1, 0) else Vector3.new(1, 0, 0)
		nose = other:Cross(up)
	end
	nose = nose.Unit
	return CFrame.fromMatrix(Vector3.new(), nose:Cross(up), up)
end

-- Proportional attitude control on SO(3): turn along the shortest arc toward `target`.
-- Clamping per axis lets tilt win over yaw, like a real flight controller.
function FlightModel.attitudeRates(current: CFrame, target: CFrame, gain: number, maxRates: Vector3): Vector3
	local axis, angle = (current.Rotation:Inverse() * target.Rotation):ToAxisAngle()
	if angle > math.pi then
		angle -= 2 * math.pi
	end
	if math.abs(angle) < 1e-6 then
		return Vector3.new()
	end
	local r = axis * (angle * gain)
	return Vector3.new(
		math.clamp(r.X, -maxRates.X, maxRates.X),
		math.clamp(r.Y, -maxRates.Y, maxRates.Y),
		math.clamp(r.Z, -maxRates.Z, maxRates.Z)
	)
end

-- World-space thrust acceleration that moves the drone toward vDesired, the way a real
-- velocity controller does it: by tilting the thrust vector. Lift wins over horizontal
-- push and tilt is capped, so the drone banks into turns but never flips.
function FlightModel.thrustFor(v: Vector3, vDesired: Vector3, gain: number, lim: Limits): Vector3
	local accel = (vDesired - v) * gain
	local t = accel + Vector3.new(0, lim.gravity, 0) - FlightModel.drag(v, lim.quadratic, lim.linear)
	local lift = math.max(t.Y, lim.gravity * 0.25)
	local push = Vector3.new(t.X, 0, t.Z)
	local maxPush = lift * math.tan(lim.maxTilt)
	if push.Magnitude > maxPush then
		push = push.Unit * maxPush
	end
	t = Vector3.new(push.X, lift, push.Z)
	if t.Magnitude > lim.maxThrust then
		t = t.Unit * lim.maxThrust
	end
	return t
end

-- Thrust only acts along the body's up axis, so project the wanted thrust onto it.
function FlightModel.throttleFor(thrust: Vector3, up: Vector3, maxThrust: number): number
	return math.clamp(thrust:Dot(up) / maxThrust, 0, 1)
end

return FlightModel
