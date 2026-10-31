-- Finds this player's drone, wires input, and runs one ordered update per frame:
-- targets -> flight controller -> weapons -> missiles -> camera -> visuals -> HUD.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Weapons"))
local TargetPaths = require(Shared:WaitForChild("TargetPaths"))
local Controller = require(script.Parent:WaitForChild("DroneController"))
local CameraRig = require(script.Parent:WaitForChild("CameraRig"))
local DroneVisuals = require(script.Parent:WaitForChild("DroneVisuals"))
local MissileFx = require(script.Parent:WaitForChild("MissileFx"))
local WeaponController = require(script.Parent:WaitForChild("WeaponController"))
local Hud = require(script.Parent:WaitForChild("Hud"))

local player = Players.LocalPlayer

local function findDrone(): Model
	local drones = workspace:WaitForChild("Drones")
	while true do
		for _, drone in drones:GetChildren() do
			if drone:GetAttribute("OwnerId") == player.UserId then
				return drone :: Model
			end
		end
		drones.ChildAdded:Wait()
	end
end

local drone = findDrone()
drone:WaitForChild("Root")

local controller = Controller.new(drone)
local rig = CameraRig.new(drone)
local visuals = DroneVisuals.new(drone)
local fx = MissileFx.new(function(at: Vector3, radius: number)
	local distance = (at - workspace.CurrentCamera.CFrame.Position).Magnitude
	rig:shake(math.clamp(1 - distance / (radius * 18), 0, 1) * 0.7)
end)
local weapons = WeaponController.new(drone, fx)
local hud = Hud.new()

local mouseDelta = Vector2.zero
UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDelta += Vector2.new(input.Delta.X, input.Delta.Y)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		rig:zoom(-input.Position.Z)
	end
end)

local WEAPON_KEYS = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3 }

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local code = input.KeyCode
	if code == Enum.KeyCode.F or code == Enum.KeyCode.ButtonY then
		rig:cycle()
	elseif code == Enum.KeyCode.T or code == Enum.KeyCode.ButtonX then
		controller:cycleMode()
	elseif code == Enum.KeyCode.Backspace or code == Enum.KeyCode.DPadDown then
		controller:reset()
	elseif WEAPON_KEYS[code] then
		weapons:select(Weapons.Order[WEAPON_KEYS[code]])
	elseif code == Enum.KeyCode.DPadUp then
		weapons:cycle()
	end
end)

-- Studio-only hook so automated playtests can aim and read state without a mouse.
if RunService:IsStudio() then
	local hook = Instance.new("BindableFunction")
	hook.Name = "TestHook"
	hook.OnInvoke = function(command: string, arg: any)
		if command == "aimAt" then
			local look = (arg - workspace.CurrentCamera.CFrame.Position).Unit
			controller.aimYaw = math.atan2(-look.X, -look.Z)
			controller.aimPitch = math.asin(look.Y)
		elseif command == "select" then
			weapons:select(arg)
		end
		return {
			locks = #weapons.locks,
			candidate = weapons.candidate and weapons.candidate.Name,
			progress = weapons.progress,
			ammo = weapons.slots[weapons.selected].ammo,
			message = weapons.message,
		}
	end
	hook.Parent = script
end

-- Runs right after Roblox's default camera so ours wins.
RunService:BindToRenderStep("Drone", Enum.RenderPriority.Camera.Value + 1, function(dt)
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
	local mouse = mouseDelta
	mouseDelta = Vector2.zero

	TargetPaths.animate(workspace:GetServerTimeNow())
	controller:step(dt, if rig.mode == "Orbit" then Vector2.zero else mouse)
	weapons:update(dt)
	fx:update(dt)
	rig:update(dt, controller, mouse)
	visuals:update(dt, controller, rig.mode == "Fpv")
	hud:update(controller, rig, weapons)
end)
