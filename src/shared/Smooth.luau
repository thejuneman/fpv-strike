--!strict
-- Framerate-independent smoothing. `rate` and `omega` are 1/seconds; higher = snappier.
-- Works on numbers and Vector3s alike.

local Smooth = {}

function Smooth.alpha(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

-- Exponential approach. Unlike lerp(a, b, 0.1) it behaves the same at 30 and 240 fps.
function Smooth.damp(current: any, target: any, rate: number, dt: number): any
	return current + (target - current) * Smooth.alpha(rate, dt)
end

-- Critically damped spring, solved exactly, so it never overshoots or blows up on a long frame.
function Smooth.spring(x: any, v: any, target: any, omega: number, dt: number): (any, any)
	local offset = x - target
	local k = v + offset * omega
	local decay = math.exp(-omega * dt)
	return target + (offset + k * dt) * decay, (v - k * (omega * dt)) * decay
end

return Smooth
