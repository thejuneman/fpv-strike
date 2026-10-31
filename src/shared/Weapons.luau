--!strict
-- Weapon specs, plus the ammo/reload rule shared by the server (which enforces it) and the
-- client (which shows it). Units: studs, seconds, studs/s² for accelerations.

export type Guidance = "None" | "PN" | "TopAttack"

export type Spec = {
	Label: string,
	Guidance: Guidance,
	-- magazine
	Ammo: number,
	Reload: number, -- seconds per round, rounds come back one at a time
	Interval: number, -- minimum seconds between shots
	-- launch
	LaunchSpeed: number, -- ejection speed added to the drone's velocity
	LaunchPitch: number, -- nose-up launch angle (from the horizon for top-attack, else from the aim)
	Spread: number, -- cone half-angle for unguided rockets
	-- motor and airframe
	IgnitionDelay: number, -- drop clear of the drone before the motor lights
	BoostTime: number,
	BoostAccel: number,
	SustainTime: number,
	SustainAccel: number,
	Drag: number, -- quadratic
	Gravity: number,
	-- guidance
	NavGain: number, -- proportional navigation constant N
	MaxG: number, -- lateral acceleration the fins can pull
	LoftHeight: number, -- top-attack climb above the target
	LoftBias: number, -- aim this share of the remaining range above the target
	DiveAngle: number, -- top-attack switches to terminal homing below this line-of-sight angle
	-- seeker
	LockTime: number,
	MaxLocks: number,
	SeekerCone: number, -- half-angle a new lock must start inside
	TrackCone: number, -- half-angle an existing lock survives inside
	Range: number,
	-- warhead
	Fuse: number, -- proximity fuse radius (0 = impact only)
	Lifetime: number,
	Damage: number,
	BlastRadius: number,
}

export type Slot = { ammo: number, timer: number, updated: number, lastShot: number }

local Weapons = {}

Weapons.Order = { "Rockets", "Seeker", "TopAttack" }

local specs: { [string]: Spec } = {
	-- Unguided salvo from the two pods, converging on the reticle.
	Rockets = {
		Label = "ROCKETS",
		Guidance = "None",
		Ammo = 16,
		Reload = 0.4,
		Interval = 0.085,
		LaunchSpeed = 160,
		LaunchPitch = 0,
		Spread = math.rad(1.4),
		IgnitionDelay = 0,
		BoostTime = 0.25,
		BoostAccel = 900,
		SustainTime = 0,
		SustainAccel = 0,
		Drag = 0.0012,
		Gravity = 18,
		NavGain = 0,
		MaxG = 0,
		LoftHeight = 0,
		LoftBias = 0,
		DiveAngle = 0,
		LockTime = 0,
		MaxLocks = 0,
		SeekerCone = 0,
		TrackCone = 0,
		Range = 1200,
		Fuse = 0,
		Lifetime = 3.5,
		Damage = 30,
		BlastRadius = 8,
	},
	-- Fast lock-on missile flying proportional navigation; locks up to four targets.
	Seeker = {
		Label = "SEEKER",
		Guidance = "PN",
		Ammo = 4,
		Reload = 2.5,
		Interval = 0.18,
		LaunchSpeed = 15,
		LaunchPitch = math.rad(8), -- just enough kick to cancel the drop off the rail
		Spread = 0,
		IgnitionDelay = 0.15,
		BoostTime = 0.9,
		BoostAccel = 520,
		SustainTime = 2.5,
		SustainAccel = 140,
		Drag = 0.0011,
		Gravity = 30,
		NavGain = 4,
		MaxG = 1100,
		LoftHeight = 0,
		LoftBias = 0.12,
		DiveAngle = 0,
		LockTime = 0.6,
		MaxLocks = 4,
		SeekerCone = math.rad(14),
		TrackCone = math.rad(45),
		Range = 900,
		Fuse = 6,
		Lifetime = 7,
		Damage = 100,
		BlastRadius = 14,
	},
	-- Soft-launched anti-armour missile: climbs, then dives onto the roof.
	TopAttack = {
		Label = "TOP-ATTACK",
		Guidance = "TopAttack",
		Ammo = 2,
		Reload = 6,
		Interval = 0.5,
		LaunchSpeed = 30,
		LaunchPitch = math.rad(35),
		Spread = 0,
		IgnitionDelay = 0.25,
		BoostTime = 0.7,
		BoostAccel = 320,
		SustainTime = 4,
		SustainAccel = 70,
		Drag = 0.0018,
		Gravity = 30,
		NavGain = 4.5,
		MaxG = 950,
		LoftHeight = 90,
		LoftBias = 0,
		DiveAngle = math.rad(60),
		LockTime = 1.3,
		MaxLocks = 1,
		SeekerCone = math.rad(10),
		TrackCone = math.rad(40),
		Range = 1200,
		Fuse = 0, -- contact fuse: anti-armour rounds go off on the roof, not above it
		Lifetime = 14,
		Damage = 230,
		BlastRadius = 16,
	},
}
Weapons.Specs = specs

function Weapons.newSlot(spec: Spec, now: number): Slot
	return { ammo = spec.Ammo, timer = 0, updated = now, lastShot = -math.huge }
end

function Weapons.refill(slot: Slot, spec: Spec, now: number)
	if slot.ammo >= spec.Ammo then
		slot.timer = 0
	else
		slot.timer += now - slot.updated
		while slot.timer >= spec.Reload and slot.ammo < spec.Ammo do
			slot.timer -= spec.Reload
			slot.ammo += 1
		end
	end
	slot.updated = now
end

-- Spends a round if one is ready. `grace` credits reload time that passed while the shot was
-- crossing the network (server only; the client passes 0).
function Weapons.tryFire(slot: Slot, spec: Spec, now: number, grace: number): boolean
	Weapons.refill(slot, spec, now)
	if now - slot.lastShot < spec.Interval - math.min(grace, spec.Interval * 0.5) then
		return false
	end
	if slot.ammo < 1 then
		if slot.timer + grace < spec.Reload then
			return false
		end
		slot.ammo, slot.timer = 1, 0
	end
	slot.ammo -= 1
	slot.lastShot = now
	return true
end

return Weapons
