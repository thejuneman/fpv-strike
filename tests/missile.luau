-- lune run tests/missile
-- Flies each weapon against a scripted target with the same code the game uses.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Vector3, CFrame = roblox.Vector3, roblox.CFrame
local env = setmetatable({ Vector3 = Vector3, CFrame = CFrame }, { __index = getfenv() })
local function load(path: string)
	return luau.load(fs.readFile(path), { environment = env })()
end
local Weapons = load("src/shared/Weapons.luau")
local Missile = load("src/shared/Missile.luau")

local DT = 1 / 60 -- server Heartbeat

-- Flies until the proximity fuse trips or the missile times out.
local function fly(spec, origin, forward, targetAt: (number) -> any)
	local s = Missile.new(origin, forward * spec.LaunchSpeed, forward)
	local t, peak = 0, origin.Y
	while t < spec.Lifetime do
		local before = s.pos
		local velocity = (targetAt(t + 0.05) - targetAt(t - 0.05)) / 0.1
		Missile.step(s, spec, DT, targetAt(t), velocity)
		t += DT
		peak = math.max(peak, s.pos.Y)
		if s.pos.Y < 0 then
			return false, t, s, peak -- flew into the ground
		end
		local target = targetAt(t)
		if (Missile.closestOnSegment(before, s.pos, target) - target).Magnitude < (if spec.Fuse > 0 then spec.Fuse else 4) then -- 4: inside a tank hitbox
			return true, t, s, peak
		end
	end
	return false, t, s, peak
end

-- Seeker leads a target crossing at 50 studs/s (PN, not pure pursuit)
local seeker = Weapons.Specs.Seeker
local hit, t = fly(seeker, Vector3.new(0, 30, 0), Vector3.new(0, 0, -1), function(time)
	return Vector3.new(-200 + 50 * time, 2, -650)
end)
assert(hit, "seeker intercepts a crossing target")
print(string.format("seeker: crossing target hit after %.2f s", t))

-- Seeker turns onto a target well off the nose
hit, t = fly(seeker, Vector3.new(0, 30, 0), Vector3.new(0, 0, -1), function()
	return Vector3.new(350, 5, -300)
end)
assert(hit, "seeker turns onto an off-boresight target")
print(string.format("seeker: 50 deg off-boresight target hit after %.2f s", t))

-- Seeker fired from the launch pad at a truck driving across the field doesn't plough into the dirt
local kick = CFrame.Angles(seeker.LaunchPitch, 0, 0).LookVector
hit, t = fly(seeker, Vector3.new(0, 0.66, 0), kick, function(time)
	return Vector3.new(-150 + 30 * time, 3, -350)
end)
assert(hit, "seeker from the pad reaches a ground target")
print(string.format("seeker: ground target from the pad hit after %.2f s", t))

-- Top-attack lofts above the target and dives steeply onto it
local top = Weapons.Specs.TopAttack
local launch = CFrame.Angles(top.LaunchPitch, 0, 0).LookVector
for _, range in { 150, 340, 600, 1000 } do
	local hitTop, tTop, sTop, peak = fly(top, Vector3.new(0, 0.62, 0), launch, function()
		return Vector3.new(20, 2.5, -range)
	end)
	local dive = math.deg(math.asin(-sTop.vel.Unit.Y))
	assert(hitTop, `top-attack reaches a target {range} studs away`)
	assert(dive > 45, `top-attack dives steeply at {range} studs (got {dive} deg)`)
	print(string.format("top-attack @%d: hit after %.2f s, peak %.0f studs, %.0f deg dive", range, tTop, peak, dive))
end

-- Rockets fly true with a little drop
local rockets = Weapons.Specs.Rockets
local s = Missile.new(Vector3.zero, Vector3.new(0, 0, -rockets.LaunchSpeed), Vector3.new(0, 0, -1))
for _ = 1, 60 do
	Missile.step(s, rockets, DT, nil, nil)
end
assert(math.abs(s.pos.X) < 1e-6 and s.pos.Y > -15 and s.pos.Z < -300, `rocket path {s.pos}`)
print(string.format("rockets: %.0f studs in 1 s, %.1f studs drop", -s.pos.Z, -s.pos.Y))

-- Ammo: four shots, empty, then one round back after a reload
local slot = Weapons.newSlot(seeker, 0)
for i = 1, 4 do
	assert(Weapons.tryFire(slot, seeker, i * 0.2, 0), `shot {i}`)
end
assert(not Weapons.tryFire(slot, seeker, 1.0, 0), "empty magazine refuses")
assert(Weapons.tryFire(slot, seeker, 0.2 + seeker.Reload + 0.01, 0), "a round comes back after one reload")
assert(not Weapons.tryFire(slot, seeker, 0.2 + seeker.Reload + 0.05, 0), "fire interval holds")
print("ammo ok")
