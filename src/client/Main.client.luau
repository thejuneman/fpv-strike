-- Finds this player's drone, wires input, and runs one ordered update per frame:
-- targets -> video link -> flight controller -> weapons -> missiles -> camera -> visuals -> HUD
-- -> debug overlay -> replay recorder. While a replay plays, it runs instead.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Weapons = require(Shared:WaitForChild("Weapons"))
local TargetPaths = require(Shared:WaitForChild("TargetPaths"))
local Controller = require(script.Parent:WaitForChild("DroneController"))
local CameraRig = require(script.Parent:WaitForChild("CameraRig"))
local DroneVisuals = require(script.Parent:WaitForChild("DroneVisuals"))
local MissileFx = require(script.Parent:WaitForChild("MissileFx"))
local WeaponController = require(script.Parent:WaitForChild("WeaponController"))
local VideoLink = require(script.Parent:WaitForChild("VideoLink"))
local Hud = require(script.Parent:WaitForChild("Hud"))
local DebugOverlay = require(script.Parent:WaitForChild("DebugOverlay"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Replay = require(script.Parent:WaitForChild("Replay"))
local TouchControls = require(script.Parent:WaitForChild("TouchControls"))

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
local link = VideoLink.new(drone)
local hud = Hud.new()
local overlay = DebugOverlay.new(controller, fx, link)
local replay = Replay.new(drone, controller, fx)
local settings = Settings.new({
	{
		label = "Debug overlay (F2)",
		get = function()
			return overlay.enabled
		end,
		flip = function()
			overlay:toggle()
		end,
	},
	{
		label = "Missile cam (V)",
		get = function()
			return rig.missileCam
		end,
		flip = function()
			rig:toggleMissileCam()
		end,
	},
})

-- A missile-cam kill gets the kill cam: the camera hangs round the wreck in slow motion.
weapons.onKill = function(_, at: Vector3)
	if rig.watching then
		rig:killCam(at)
		fx:slowMotion(at)
	end
end

local function detonate()
	if weapons:detonate() then
		-- The feed dies with the drone, like a real FPV strike. Motors cut until it's confirmed.
		hud:signalLost(Config.DownTime)
		controller.armed = false
	end
end

local touch = if TouchControls.wanted()
	then TouchControls.new({
		weapon = function()
			weapons:cycle()
		end,
		flares = function()
			weapons:dropFlares()
		end,
		camera = function()
			rig:cycle()
		end,
		detonate = detonate,
		reset = function()
			controller:reset()
		end,
	})
	else nil
if touch then
	controller.touch = touch
	weapons.touch = touch
	hud:setTouch()
end

local mouseDelta = Vector2.zero
UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement and not touch then
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
	if code == Enum.KeyCode.P or code == Enum.KeyCode.ButtonSelect then
		if replay.playing then
			replay:stop()
		elseif replay:request() then
			if overlay.enabled then
				overlay:toggle() -- its lines would freeze over the replay
			end
			weapons:_say("REPLAY")
		end
		return
	elseif replay.playing then
		if code == Enum.KeyCode.C or code == Enum.KeyCode.ButtonY then
			replay:nextShot()
		end
		return -- the replay has the controls
	elseif code == Enum.KeyCode.M then
		settings:toggle()
		return
	elseif code == Enum.KeyCode.F2 then
		overlay:toggle()
		return
	elseif code == Enum.KeyCode.H then
		hud:toggleHelp()
		return
	end

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
	elseif code == Enum.KeyCode.G or code == Enum.KeyCode.ButtonB then
		weapons:dropFlares()
	elseif code == Enum.KeyCode.V or code == Enum.KeyCode.DPadRight then
		weapons:_say(if rig:toggleMissileCam() then "MISSILE CAM ON" else "MISSILE CAM OFF")
	elseif code == Enum.KeyCode.R or code == Enum.KeyCode.ButtonL3 then
		detonate()
	end
end)

-- Shot down or detonated: static over the feed, and a fresh drone waits on the pad.
drone:GetAttributeChangedSignal("Down"):Connect(function()
	if drone:GetAttribute("Down") then
		hud:signalLost(Config.DownTime)
		controller:reset()
		weapons:_clearLocks()
	end
end)

local lastHealth = drone:GetAttribute("Health")
drone:GetAttributeChangedSignal("Health"):Connect(function()
	local health = drone:GetAttribute("Health")
	if health < lastHealth and health > 0 then
		hud:damaged()
		rig:shake(0.9)
	end
	lastHealth = health
end)

-- Radar dishes sweep, and stop to stare at you while they hold a lock (cosmetic, local only).
local function sweepDishes()
	local sweep = os.clock() * 2.5
	for _, site in CollectionService:GetTagged("Target") do
		local root = site.PrimaryPart
		local spin = root and root:FindFirstChild("DishSpin")
		if spin and site:GetAttribute("Health") > 0 then
			local yaw = sweep
			if site:GetAttribute("Tracking") == player.UserId then
				local rel = root.CFrame:PointToObjectSpace(drone.PrimaryPart.Position)
				yaw = math.atan2(-rel.Z, rel.X)
			end
			spin.Transform = CFrame.Angles(0, yaw, 0)
		end
	end
end

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
		elseif command == "flares" then
			weapons:dropFlares()
		elseif command == "camera" then
			rig.mode = arg
		elseif command == "replay" then
			replay:request()
		elseif command == "debug" then
			overlay:toggle()
		elseif command == "settings" then
			settings:toggle()
		end
		local threatAt = weapons.threatAt
		return {
			locks = #weapons.locks,
			candidate = weapons.candidate and weapons.candidate.Name,
			progress = weapons.progress,
			ammo = weapons.slots[weapons.selected].ammo,
			message = weapons.message,
			threat = weapons.threat,
			threatRange = threatAt and (threatAt - drone.PrimaryPart.Position).Magnitude,
			health = drone:GetAttribute("Health"),
			link = link.quality,
			failsafe = link.failsafe,
			watching = rig.watching,
			killCam = rig.kill ~= nil,
			replaying = replay.playing,
			shot = replay.shot,
			tape = #replay.frames,
		}
	end
	hook.Parent = script
end

-- Runs right after Roblox's default camera so ours wins.
RunService:BindToRenderStep("Drone", Enum.RenderPriority.Camera.Value + 1, function(dt)
	-- The settings menu frees the mouse; everything else flies with it locked.
	-- On phones there is no mouse to lock; aim comes from dragging the right side of the screen.
	UserInputService.MouseBehavior = if settings.open or touch
		then Enum.MouseBehavior.Default
		else Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = settings.open
	if touch then
		mouseDelta += touch:takeLook()
		touch:setVisible(not replay.playing)
	end
	local mouse = if settings.open then Vector2.zero else mouseDelta
	mouseDelta = Vector2.zero

	-- During a replay the drone holds position out of sight while the stand-ins fly the tape.
	controller.locked = settings.open or replay.playing
	if replay.playing then
		link:update(dt)
		controller:step(dt, Vector2.zero)
		fx:update(dt)
		replay:update(dt)
		hud.gui.Enabled = not replay.playing
		return
	end
	hud.gui.Enabled = true

	TargetPaths.animate(workspace:GetServerTimeNow())
	sweepDishes()
	link:update(dt)
	controller.failsafe = link.failsafe
	controller:step(dt, if rig.mode == "Orbit" then Vector2.zero else mouse)
	weapons.blocked = settings.open
	weapons:update(dt)
	fx:update(dt)
	rig:update(dt, controller, mouse, fx.flights[weapons.lastGuided])
	visuals:update(dt, controller, rig.mode == "Fpv" and not rig.watching)
	hud:update(dt, controller, rig, weapons, link)
	overlay:update(dt)
	replay:record()
end)
