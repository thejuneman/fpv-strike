--!strict
-- Flare paths. Like the target paths, they are pure functions of time: the server and every
-- client agree on where each flare is without sending a single position after launch.
-- Drag is linear, so the path has a closed form.

local Flares = {}

export type Flare = { origin: Vector3, velocity: Vector3, born: number }

Flares.Burn = 2.6 -- seconds a flare burns, and can hold a seeker
local DRAG = 1.1 -- 1/s
local GRAVITY = Vector3.new(0, -28, 0) -- once slowed, flares sink at GRAVITY / DRAG
local TERMINAL = GRAVITY / DRAG

-- dv/dt = g - k·v  →  v(t) = g/k + (v0 - g/k)·e^(-kt)
function Flares.velocity(f: Flare, now: number): Vector3
	local t = math.max(now - f.born, 0)
	return TERMINAL + (f.velocity - TERMINAL) * math.exp(-DRAG * t)
end

function Flares.at(f: Flare, now: number): Vector3
	local t = math.max(now - f.born, 0)
	return f.origin + TERMINAL * t + (f.velocity - TERMINAL) * ((1 - math.exp(-DRAG * t)) / DRAG)
end

-- A fan of flares kicked out sideways, back and down from a moving aircraft, rippled off one
-- after another.
function Flares.salvo(origin: Vector3, carrier: CFrame, carrierVelocity: Vector3, count: number, now: number, random: Random): { Flare }
	local list = {}
	for i = 1, count do
		local side = i - (count + 1) / 2
		local kick = carrier.RightVector * (side * 22 + random:NextNumber(-6, 6))
			- carrier.LookVector * random:NextNumber(10, 25)
			- Vector3.new(0, random:NextNumber(5, 20), 0)
		table.insert(list, { origin = origin, velocity = carrierVelocity * 0.7 + kick, born = now + (i - 1) * 0.12 })
	end
	return list
end

return Flares
