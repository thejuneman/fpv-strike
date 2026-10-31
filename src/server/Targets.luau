--!strict
-- Range targets: trucks, tanks, aerial target drones and SAM sites. Health lives in attributes so every
-- client can show it; only this module changes it. Each target is one anchored hitbox with
-- welded visuals, so a move replicates as a single CFrame.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TargetPaths = require(ReplicatedStorage.Shared.TargetPaths)

local Targets = {}

local OLIVE = Color3.fromRGB(92, 98, 64)
local TARP = Color3.fromRGB(110, 106, 78)
local DARK = Color3.fromRGB(38, 40, 36)
local ORANGE = Color3.fromRGB(255, 120, 40)
local WHITE = Color3.fromRGB(236, 236, 240)
local CHAR = Color3.fromRGB(20, 18, 16)

local CONCRETE = Color3.fromRGB(120, 118, 112)
local RED = Color3.fromRGB(255, 50, 50)

local VERTICAL = CFrame.Angles(0, 0, math.rad(90))
local FORWARD = CFrame.Angles(0, math.rad(90), 0)

type Kind = { health: number, hitbox: Vector3, grounded: boolean, respawn: number, build: (add: Adder, root: Part) -> () }
type Adder = (size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?) -> Part

local KINDS: { [string]: Kind } = {
	Truck = {
		health = 100,
		hitbox = Vector3.new(6.4, 6, 14),
		grounded = true,
		respawn = 8,
		build = function(add)
			add(Vector3.new(6, 0.8, 13.5), CFrame.new(0, -1.6, 0), DARK)
			add(Vector3.new(6, 3.4, 4), CFrame.new(0, 0.3, -4.6), OLIVE)
			add(Vector3.new(5.2, 1.4, 0.1), CFrame.new(0, 1, -6.62), Color3.fromRGB(20, 24, 30), Enum.Material.Glass)
			add(Vector3.new(6.2, 4.2, 8.5), CFrame.new(0, 0.7, 1.9), TARP, Enum.Material.Fabric)
			for _, side in { -1, 1 } do
				add(Vector3.new(0.6, 0.4, 0.1), CFrame.new(side * 2.2, -0.5, -6.62), Color3.fromRGB(255, 236, 190), Enum.Material.Neon)
				for _, z in { -4.2, 0.8, 3.8 } do
					add(Vector3.new(0.9, 2.2, 2.2), CFrame.new(side * 3.05, -1.9, z), DARK, Enum.Material.Rubber, Enum.PartType.Cylinder)
				end
			end
		end,
	},
	Tank = {
		health = 220,
		hitbox = Vector3.new(9, 5, 13),
		grounded = true,
		respawn = 8,
		build = function(add)
			add(Vector3.new(8, 2.4, 12.5), CFrame.new(0, -0.9, 0), OLIVE)
			for _, side in { -1, 1 } do
				add(Vector3.new(1.6, 2.2, 13), CFrame.new(side * 4.2, -1.4, 0), DARK, Enum.Material.DiamondPlate)
			end
			add(Vector3.new(5.4, 1.8, 5.6), CFrame.new(0, 1.2, 0.5), OLIVE)
			add(Vector3.new(7, 0.5, 0.5), CFrame.new(0, 1.3, -5.6) * FORWARD, DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
			add(Vector3.new(0.3, 1.2, 1.2), CFrame.new(1.2, 2.2, 1.4) * VERTICAL, DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
		end,
	},
	Drone = {
		health = 60,
		hitbox = Vector3.new(12, 2.4, 10),
		grounded = false,
		respawn = 8,
		build = function(add)
			add(Vector3.new(9, 1.3, 1.3), FORWARD, ORANGE, nil, Enum.PartType.Cylinder)
			add(Vector3.new(1.3, 1.3, 1.3), CFrame.new(0, 0, -4.5), WHITE, nil, Enum.PartType.Ball)
			add(Vector3.new(11.5, 0.2, 2.2), CFrame.new(0, 0, 0.3), WHITE)
			add(Vector3.new(0.2, 1.8, 1.4), CFrame.new(0, 0.9, 4), ORANGE)
			add(Vector3.new(4, 0.2, 1.2), CFrame.new(0, 0, 4.1), ORANGE)
			add(Vector3.new(0.5, 0.5, 0.3), CFrame.new(0, 0, 4.6), Color3.fromRGB(255, 160, 80), Enum.Material.Neon)
		end,
	},
	-- Vertical-launch SAM site: four-cell launcher, radar mast with a sweeping dish.
	SAM = {
		health = 160,
		hitbox = Vector3.new(12, 9, 12),
		grounded = true,
		respawn = 20,
		build = function(add, root)
			add(Vector3.new(12, 1, 12), CFrame.new(0, -4, 0), CONCRETE, Enum.Material.Concrete)
			add(Vector3.new(5, 4.5, 5), CFrame.new(-2.5, -1.25, 0), OLIVE)
			for _, x in { -1.25, 1.25 } do
				for _, z in { -1.25, 1.25 } do
					add(Vector3.new(0.2, 1.8, 1.8), CFrame.new(-2.5 + x, 1.05, z) * VERTICAL, DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
				end
			end
			add(Vector3.new(3, 2.5, 4), CFrame.new(3.5, -2.25, 2.5), OLIVE) -- generator
			add(Vector3.new(7, 0.8, 0.8), CFrame.new(3.5, 0, -2.5) * VERTICAL, DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
			add(Vector3.new(0.7, 0.7, 0.7), CFrame.new(3.5, 3.6, -2.5), RED, Enum.Material.Neon, Enum.PartType.Ball)
			-- The dish hangs off a Motor6D so clients can sweep it without touching the hitbox.
			local dish = add(Vector3.new(0.4, 3.2, 5), CFrame.new(3.5, 2.6, -2.5) * CFrame.Angles(0, 0, math.rad(-20)), WHITE, Enum.Material.Metal)
			dish:FindFirstChildOfClass("WeldConstraint"):Destroy()
			local spin = Instance.new("Motor6D")
			spin.Name = "DishSpin"
			spin.Part0 = root
			spin.Part1 = dish
			spin.C0 = CFrame.new(3.5, 2.6, -2.5)
			spin.C1 = CFrame.Angles(0, 0, math.rad(20))
			spin.Parent = root
		end,
	},
}

local folder = Instance.new("Folder")
folder.Name = "Targets"

local function build(kindName: string): Model
	local kind = KINDS[kindName]
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "Hitbox"
	root.Size = kind.hitbox
	root.Transparency = 1
	root.Anchored = true
	root.Parent = model
	model.PrimaryPart = root

	kind.build(function(size, cf, color, material, shape): Part
		local p = Instance.new("Part")
		p.Shape = shape or Enum.PartType.Block
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p:SetAttribute("BaseColor", color)
		p.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
		return p
	end, root)

	model:SetAttribute("Kind", kindName)
	model:SetAttribute("MaxHealth", kind.health)
	model:SetAttribute("Health", kind.health)
	model:SetAttribute("Lift", if kind.grounded then kind.hitbox.Y / 2 else 0)
	return model
end

local function wreck(model: Model)
	local root = model.PrimaryPart :: BasePart
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p ~= root then
			p.Color = (p:GetAttribute("BaseColor") :: Color3):Lerp(CHAR, 0.8)
		end
	end
	local fire = Instance.new("Fire")
	fire.Size = 7
	fire.Heat = 12
	fire.Parent = root
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(40, 40, 40)
	smoke.Opacity = 0.35
	smoke.RiseVelocity = 14
	smoke.Size = 5
	smoke.Parent = root
	if model:GetAttribute("Kind") == "Drone" then
		root.Anchored = false -- shot-down drones fall out of the sky
	end
end

local function restore(model: Model)
	local root = model.PrimaryPart :: BasePart
	for _, child in root:GetChildren() do
		if child:IsA("Fire") or child:IsA("Smoke") then
			child:Destroy()
		end
	end
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p ~= root then
			p.Color = p:GetAttribute("BaseColor") :: Color3
		end
	end
	root.Anchored = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	model:SetAttribute("Health", model:GetAttribute("MaxHealth"))
	model:SetAttribute("BreakAt", nil)
	TargetPaths.place(model, workspace:GetServerTimeNow())
end

-- Returns (took damage, destroyed it).
function Targets.damage(model: Model, amount: number): (boolean, boolean)
	local health = model:GetAttribute("Health") :: number
	if health <= 0 then
		return false, false
	end
	health = math.max(health - amount, 0)
	model:SetAttribute("Health", health)
	if health > 0 then
		return true, false
	end
	wreck(model)
	task.delay(KINDS[model:GetAttribute("Kind") :: string].respawn, restore, model)
	return true, true
end

function Targets.build()
	-- Welds only carry parts along inside the workspace, so parent before placing.
	folder.Parent = workspace
	local now = workspace:GetServerTimeNow()
	for i, entry in TargetPaths.List do
		local model = build(entry.kind)
		model.Name = `{entry.kind}{i}`
		model:SetAttribute("Path", i)
		model.Parent = folder
		TargetPaths.place(model, now)
		CollectionService:AddTag(model, "Target")
	end
end

return Targets
