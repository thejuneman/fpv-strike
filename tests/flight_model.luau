-- lune run tests/flight_model
-- Checks the flight math, then flies a simulated drone with the Aim-mode controller.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Vector3, CFrame = roblox.Vector3, roblox.CFrame
local env = setmetatable({ Vector3 = Vector3, CFrame = CFrame }, { __index = getfenv() })
local FlightModel = luau.load(fs.readFile("src/shared/FlightModel.luau"), { environment = env })()

local function near(actual: number, expected: number, eps: number, what: string)
	assert(math.abs(actual - expected) <= eps, `{what}: expected {expected}, got {actual}`)
end

-- Betaflight "Actual" rates hit their endpoints
near(FlightModel.actualRate(0, 70, 670, 0.54), 0, 1e-9, "rate at centre")
near(FlightModel.actualRate(1, 70, 670, 0.54), 670, 1e-6, "rate at full stick")
near(FlightModel.actualRate(-1, 70, 670, 0.54), -670, 1e-6, "rate at full negative stick")

-- Attitude keeps the requested up axis and points the nose along the heading
local up = Vector3.new(0.3, 1, -0.2).Unit
local attitude = FlightModel.attitudeFrom(up, Vector3.new(0, 0, -1))
near((attitude.UpVector - up).Magnitude, 0, 1e-5, "attitude up axis")
assert(attitude.LookVector.Z < -0.9, "nose follows heading")

-- Attitude controller turns the right way, and yaw is clamped harder than tilt
local rates = FlightModel.attitudeRates(CFrame.new(), CFrame.Angles(0.2, 0, 0), 10, Vector3.new(20, 20, 20))
near(rates.X, 2, 1e-4, "pitch rate toward target")
rates = FlightModel.attitudeRates(CFrame.new(), CFrame.Angles(0, 3, 0), 10, Vector3.new(11, 6, 11))
near(rates.Y, 6, 1e-4, "yaw rate clamp")

-- Closed loop: from a hover, fly forward at cruise speed for 4 s
local g, maxThrust = 70, 70 * 4.5
local limits = { gravity = g, maxThrust = maxThrust, maxTilt = math.rad(55), quadratic = 0.0065, linear = 0.08 }
local cf, v, pos = CFrame.new(), Vector3.new(), Vector3.new()
local want = Vector3.new(0, 0, -90)
local dt = 1 / 240
local maxTilt = 0
for _ = 1, 4 * 240 do
	local thrust = FlightModel.thrustFor(v, want, 3.2, limits)
	local target = FlightModel.attitudeFrom(thrust.Unit, Vector3.new(0, 0, -1))
	local w = FlightModel.attitudeRates(cf, target, 12, Vector3.new(11, 6, 11))
	if w.Magnitude > 0 then
		cf = cf * CFrame.fromAxisAngle(w.Unit, w.Magnitude * dt)
	end
	local throttle = FlightModel.throttleFor(thrust, cf.UpVector, maxThrust)
	local a = cf.UpVector * (throttle * maxThrust) + Vector3.new(0, -g, 0) + FlightModel.drag(v, 0.0065, 0.08)
	v += a * dt
	pos += v * dt
	maxTilt = math.max(maxTilt, math.acos(math.clamp(cf.UpVector.Y, -1, 1)))
end
near((v - want).Magnitude, 0, 3, "reaches cruise speed")
near(pos.Y, 0, 4, "holds altitude while accelerating")
assert(maxTilt <= math.rad(58), `tilt stayed under the cap ({math.deg(maxTilt)} deg)`)
print(`flight model ok: {math.floor(v.Magnitude)} studs/s, {string.format("%.2f", pos.Y)} studs drift, {math.floor(math.deg(maxTilt))} deg max tilt`)
