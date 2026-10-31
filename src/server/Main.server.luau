--!strict
-- Builds the range and its targets, gives every player a drone on the launch pad, and starts
-- the server's weapon simulation and the air defences.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local DroneBuilder = require(ReplicatedStorage.Shared.DroneBuilder)
local World = require(script.Parent.World)
local Targets = require(script.Parent.Targets)
local Combat = require(script.Parent.Combat)
local Defenses = require(script.Parent.Defenses)

local spawnCFrame = World.build()
Targets.build()

local drones = Instance.new("Folder")
drones.Name = "Drones"
drones.Parent = workspace
Combat.start(drones)
Defenses.start(drones)

-- ponytail: every drone spawns on the one pad; give players their own pads when multiplayer matters
local function spawnDrone(player: Player)
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

Players.PlayerRemoving:Connect(function(player)
	local drone = drones:FindFirstChild(player.Name)
	if drone then
		drone:Destroy()
	end
end)
