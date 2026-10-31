--!strict
-- Builds the range and its targets, gives every player a drone on a launch pad of their own,
-- and starts the server's weapon simulation and the air defences.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local DroneBuilder = require(ReplicatedStorage.Shared.DroneBuilder)
local World = require(script.Parent.World)
local Targets = require(script.Parent.Targets)
local Combat = require(script.Parent.Combat)
local Defenses = require(script.Parent.Defenses)

local pads = World.build()
local padOwners: { [number]: Player } = {}
Targets.build()

local drones = Instance.new("Folder")
drones.Name = "Drones"
drones.Parent = workspace
Combat.start(drones)
Defenses.start(drones)

-- The first free pad. ponytail: past five players the rest share the main pad.
local function claimPad(player: Player): CFrame
	for i, pad in pads do
		if not padOwners[i] then
			padOwners[i] = player
			return pad
		end
	end
	return pads[1]
end

local function spawnDrone(player: Player)
	local spawnCFrame = claimPad(player)
	local drone = DroneBuilder.build()
	drone.Name = player.Name
	drone:SetAttribute("OwnerId", player.UserId)
	drone:SetAttribute("SpawnCFrame", spawnCFrame)
	drone:SetAttribute("Health", Config.Health)
	drone:SetAttribute("Down", false)
	drone:PivotTo(spawnCFrame)
	drone.Parent = drones
	-- The owner's client simulates the drone: input feels instant and physics replicates for free.
	local root = drone.PrimaryPart :: BasePart
	root:SetNetworkOwner(player)
end

-- The character is the pilot standing behind the pad; the drone gets every input.
local function pinPilot(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 0
	humanoid.JumpHeight = 0
	humanoid.JumpPower = 0
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(pinPilot)
	if player.Character then
		task.spawn(pinPilot, player.Character)
	end
	spawnDrone(player)
end

Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local drone = drones:FindFirstChild(player.Name)
	if drone then
		drone:Destroy()
	end
	for i, owner in padOwners do
		if owner == player then
			padOwners[i] = nil
		end
	end
end)
