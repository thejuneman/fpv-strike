-- The radio link from the pilot (standing behind the pad) to the drone. Distance and walls in
-- between cut link quality; the analog video breaks up as it drops, and once it's gone the quad
-- fails safe and cuts its motors, as a real one does.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Smooth = require(Shared:WaitForChild("Smooth"))

local VideoLink = {}
VideoLink.__index = VideoLink

local PILOT = Vector3.new(0, 5, 16) -- the pilot's goggles antenna, until the character loads

function VideoLink.new(drone: Model)
	local self = setmetatable({}, VideoLink)
	self.root = drone.PrimaryPart :: BasePart
	self.quality = 1 -- 0..1, shown as LQ
	self.distance = 0
	self.blocked = false
	self.failsafe = false
	self.ray = RaycastParams.new()
	self.ray.FilterType = Enum.RaycastFilterType.Exclude
	return self
end

-- How much the picture should break up, 0..1.
function VideoLink:noise(): number
	return math.clamp((0.75 - self.quality) / 0.65, 0, 1)
end

function VideoLink:update(dt: number)
	local cfg = Config.Link
	local character = Players.LocalPlayer.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	local pilot = if head then head.Position else PILOT
	local offset = self.root.Position - pilot
	self.distance = offset.Magnitude

	-- A wall between pilot and drone soaks up signal. Hits right next to the drone (the pad
	-- it's sitting on) don't count.
	self.ray.FilterDescendantsInstances =
		{ workspace:FindFirstChild("Drones"), workspace:FindFirstChild("MissileFx"), character }
	local hit = workspace:Raycast(pilot, offset, self.ray)
	self.blocked = hit ~= nil and hit.Distance < self.distance - 3

	local wanted = 1 - math.clamp((self.distance - cfg.FullRange) / (cfg.MaxRange - cfg.FullRange), 0, 1)
	if self.blocked then
		wanted -= cfg.WallLoss
	end
	self.quality = Smooth.damp(self.quality, math.clamp(wanted, 0, 1), 3, dt)
	-- Hysteresis, so the link doesn't chatter on and off at the edge.
	if self.quality < 0.02 then
		self.failsafe = true
	elseif self.quality > 0.15 then
		self.failsafe = false
	end
end

return VideoLink
