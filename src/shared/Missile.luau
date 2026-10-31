--!strict
-- Missile flight: motor burn, drag, gravity and guidance. Pure math (no instances), so the
-- server, every client and the Lune tests all fly exactly the same missile.

local Missile = {}

export type State = {
	pos: Vector3,
	vel: Vector3,
	forward: Vector3, -- where the nose points; the motor pushes along it
	age: number,
	terminal: boolean, -- top-attack: done climbing, now diving
	loft: number?, -- top-attack: climb height, fixed from the range at first guidance
	-- What guidance did last step, for the debug overlay
	aim: Vector3?, -- the point it steered at
	steer: Vector3?, -- the lateral acceleration it commanded
}

-- The fields of Weapons.Spec this module reads.
type Spec = {
	Guidance: string,
	IgnitionDelay: number,
	BoostTime: number,
	BoostAccel: number,
	SustainTime: number,
	SustainAccel: number,
	Drag: number,
	Gravity: number,
	NavGain: number,
	MaxG: number,
	LoftHeight: number,
	LoftBias: number,
	DiveAngle: number,
}

-- Keeps guidance steering while the motor is still spinning up and closing speed is tiny.
local MIN_CLOSING = 60
-- Past this angle off the nose PN is too weak to turn the missile (it flies almost sideways to
-- the target, so closing speed is tiny); pull max G toward the target instead. Set lower, a
-- vertically launched SAM hovers at the switchover, orbiting its target until it hits the ground.
local TURN_OVER = math.cos(math.rad(45))

function Missile.new(origin: Vector3, velocity: Vector3, forward: Vector3): State
	return { pos = origin, vel = velocity, forward = forward.Unit, age = 0, terminal = false }
end

function Missile.thrustAt(spec: Spec, age: number): number
	local burn = age - spec.IgnitionDelay
	if burn < 0 then
		return 0
	elseif burn < spec.BoostTime then
		return spec.BoostAccel
	elseif burn < spec.BoostTime + spec.SustainTime then
		return spec.SustainAccel
	end
	return 0
end

-- True proportional navigation: accelerate across the line of sight in proportion to how fast
-- that line is turning. Holding the line of sight still means you are on a collision course,
-- so the missile leads a moving target instead of chasing its tail.
function Missile.proportionalNav(pos: Vector3, vel: Vector3, targetPos: Vector3, targetVel: Vector3, gain: number): Vector3
	local r = targetPos - pos
	local dist = r.Magnitude
	if dist < 1e-3 then
		return Vector3.zero
	end
	local los = r / dist
	local rel = targetVel - vel
	local closing = math.max(-rel:Dot(los), MIN_CLOSING)
	local across = rel - los * rel:Dot(los) -- relative velocity perpendicular to the line of sight
	return across * (gain * closing / dist)
end

function Missile.step(s: State, spec: Spec, dt: number, targetPos: Vector3?, targetVel: Vector3?)
	s.age += dt
	local gravity = Vector3.new(0, -spec.Gravity, 0)
	local thrust = Missile.thrustAt(spec, s.age)
	local accel = s.forward * thrust + gravity - s.vel * (spec.Drag * s.vel.Magnitude)

	local lit = s.age >= spec.IgnitionDelay
	if lit and targetPos and spec.Guidance ~= "None" then
		local aimPos, aimVel = targetPos, targetVel or Vector3.zero
		-- Aim above the target by a share of the remaining range: the missile arcs over and
		-- comes down onto ground targets instead of skimming in and catching the dirt.
		aimPos += Vector3.new(0, (targetPos - s.pos).Magnitude * spec.LoftBias, 0)
		if spec.Guidance == "TopAttack" and not s.terminal then
			-- Climb to where a DiveAngle dive onto the target begins, then dive once the target
			-- sits that steeply below. Aiming straight above it instead overshoots: by the time
			-- the angle is steep enough the missile is too close and too fast to turn down.
			local toTarget = targetPos - s.pos
			local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
			local loft = s.loft or math.min(spec.LoftHeight, flat.Magnitude * 0.35)
			s.loft = loft
			local shortOf = if flat.Magnitude > 1e-3 then flat.Unit * (loft / math.tan(spec.DiveAngle)) else Vector3.zero
			local diveStart = targetPos + Vector3.new(0, loft, 0) - shortOf
			-- Tip over one turn radius early, or the missile sails past the dive point.
			local turnRadius = s.vel.Magnitude ^ 2 / spec.MaxG
			if toTarget.Unit.Y < -math.sin(spec.DiveAngle) or (diveStart - s.pos).Magnitude < turnRadius then
				s.terminal = true
			else
				aimPos = diveStart
			end
		end

		local los = (aimPos - s.pos).Unit
		local steer
		if los:Dot(s.forward) < TURN_OVER then
			-- Target far off the nose: PN can't turn a missile around, so pull hard toward it.
			local across = los - s.forward * los:Dot(s.forward)
			steer = if across.Magnitude > 1e-3 then across.Unit * spec.MaxG else Vector3.zero
		else
			-- Fins only steer; cancel gravity and drop anything along the nose (that's the motor's job).
			steer = Missile.proportionalNav(s.pos, s.vel, aimPos, aimVel, spec.NavGain) - gravity
			steer -= s.forward * steer:Dot(s.forward)
			if steer.Magnitude > spec.MaxG then
				steer = steer.Unit * spec.MaxG
			end
		end
		accel += steer
		s.aim, s.steer = aimPos, steer
	end

	s.vel += accel * dt
	s.pos += s.vel * dt
	if lit and s.vel.Magnitude > 1 then
		s.forward = s.vel.Unit
	end
end

function Missile.closestOnSegment(a: Vector3, b: Vector3, p: Vector3): Vector3
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-9 then
		return a
	end
	return a + ab * math.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
end

return Missile
