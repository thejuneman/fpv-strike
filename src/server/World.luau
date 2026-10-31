--!strict
-- The range, matching the reference clip: Roblox's default grey baseplate with a studded
-- classic-brick house to fly through, plus the launch pad and the pilot's spot.
-- build() returns the CFrame drones spawn at.

local CollectionService = game:GetService("CollectionService")

local World = {}

local BRICK = Vector2.new(4, 3) -- largest wall brick, studs
local ACCENT = Color3.fromRGB(62, 232, 255)
local VERTICAL = CFrame.Angles(0, 0, math.rad(90))

-- Classic brick palette picked from the reference house
local CREAM = Color3.fromRGB(232, 222, 186)
local ROOF = Color3.fromRGB(196, 40, 28)
local TIMBER = Color3.fromRGB(124, 80, 52)
local ORANGE = Color3.fromRGB(218, 133, 65)
local GRASS = Color3.fromRGB(75, 151, 75)
local INTERIOR = Color3.fromRGB(32, 64, 112)
local FLOOR = Color3.fromRGB(88, 178, 170)
local STONE = Color3.fromRGB(99, 95, 98)

local STUDS = Enum.SurfaceType.Studs
local STUDDED_TOP = { TopSurface = STUDS }
local STUDDED = {
	TopSurface = STUDS,
	FrontSurface = STUDS,
	BackSurface = STUDS,
	LeftSurface = STUDS,
	RightSurface = STUDS,
}

type Props = { [string]: any }
type Hole = { number }

local folder: Folder

local function block(size: Vector3, cf: CFrame, color: Color3, props: Props?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.Plastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Size = size -- after props, so a Shape change can't resize it
	p.Parent = folder
	return p
end

-- A flat wall in its local XY plane (x from the left edge, y up from the base) with
-- rectangular holes {x, y, width, height}. Its outer face sits `inset` behind the origin plane
-- and it runs `thickness` further inward (-Z); `margin` trims both ends so layers meet flush at
-- the corners. Cuts the wall on every hole edge and lays each solid cell in bricks.
-- ponytail: a part per brick; split cells only when a blast reaches them if part count bites.
local function wall(origin: CFrame, width: number, height: number, holes: { Hole }, color: Color3, inset: number, thickness: number, margin: number, props: Props?)
	local xs, ys = { margin, width - margin }, { 0, height }
	for _, h in holes do
		table.insert(xs, h[1])
		table.insert(xs, h[1] + h[3])
		table.insert(ys, h[2])
		table.insert(ys, h[2] + h[4])
	end
	table.sort(xs)
	table.sort(ys)
	for i = 1, #xs - 1 do
		for j = 1, #ys - 1 do
			local x0, x1, y0, y1 = xs[i], xs[i + 1], ys[j], ys[j + 1]
			local inside = x0 >= margin - 1e-3 and x1 <= width - margin + 1e-3
			if inside and x1 - x0 > 0.01 and y1 - y0 > 0.01 then
				local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
				local solid = true
				for _, h in holes do
					if cx > h[1] and cx < h[1] + h[3] and cy > h[2] and cy < h[2] + h[4] then
						solid = false
						break
					end
				end
				if solid then
					-- Laid brick by brick so explosions can knock holes in it (Combat rebuilds them).
					local nx = math.ceil((x1 - x0) / BRICK.X - 1e-3)
					local ny = math.ceil((y1 - y0) / BRICK.Y - 1e-3)
					local bw, bh = (x1 - x0) / nx, (y1 - y0) / ny
					for bx = 0, nx - 1 do
						for by = 0, ny - 1 do
							local cf = origin * CFrame.new(x0 + (bx + 0.5) * bw - width / 2, y0 + (by + 0.5) * bh, -inset - thickness / 2)
							local brick = block(Vector3.new(bw, bh, thickness), cf, color, props)
							brick:SetAttribute("Home", cf)
							CollectionService:AddTag(brick, "Breakable")
						end
					end
				end
			end
		end
	end
end

-- Timber frame lining an opening on the outside, with an orange brick lintel over doors.
local function trim(origin: CFrame, width: number, hole: Hole, door: boolean)
	local x, y, w, h = hole[1], hole[2], hole[3], hole[4]
	local at = function(dx: number, dy: number, dz: number): CFrame
		return origin * CFrame.new(x + w / 2 - width / 2 + dx, y + dy, dz)
	end
	local t, depth = 0.8, 1.8
	block(Vector3.new(t, h, depth), at(-w / 2 + t / 2, h / 2, -0.6), TIMBER)
	block(Vector3.new(t, h, depth), at(w / 2 - t / 2, h / 2, -0.6), TIMBER)
	block(Vector3.new(w, t, depth), at(0, h - t / 2, -0.6), TIMBER)
	if door then
		for row = 0, 1 do
			block(Vector3.new(w + 2, 1, 1.2), at(0, h + 0.5 + row, 0.1), ORANGE, STUDDED_TOP)
		end
	else
		block(Vector3.new(w + 1, t, 2.4), at(0, t / 2, -0.4), TIMBER, STUDDED_TOP)
	end
end

local function house(base: CFrame)
	local W, D, H = 44, 32, 18
	local floor = base * CFrame.new(0, 1, 0)

	block(Vector3.new(W + 8, 1, D + 8), base * CFrame.new(0, 0.5, 0), GRASS, STUDDED_TOP)
	block(Vector3.new(W - 3, 0.4, D - 3), floor * CFrame.new(0, 0.2, 0), FLOOR, STUDDED_TOP)
	block(Vector3.new(W - 3, 0.4, D - 3), floor * CFrame.new(0, H - 0.2, 0), Color3.fromRGB(238, 238, 232))

	-- Walls: cream studded outside, blue inside. Front/back run full width; the sides fit between.
	local sideWidth = D - 3
	local walls: { { cf: CFrame, width: number, holes: { Hole }, doors: { boolean } } } = {
		{ cf = floor * CFrame.new(0, 0, D / 2), width = W, holes = { { 7, 5, 9, 7 }, { 26, 0, 9, 12 } }, doors = { false, true } },
		{ cf = floor * CFrame.new(0, 0, -D / 2) * CFrame.Angles(0, math.pi, 0), width = W, holes = { { 8, 5, 10, 7 }, { 27, 0, 9, 12 } }, doors = { false, true } },
		{ cf = floor * CFrame.new(-W / 2, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), width = sideWidth, holes = { { sideWidth / 2 - 5, 5, 10, 7 } }, doors = { false } },
		{ cf = floor * CFrame.new(W / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), width = sideWidth, holes = { { sideWidth / 2 - 5, 5, 10, 7 } }, doors = { false } },
	}
	for _, w in walls do
		local inner = if w.width == W then 1.5 else 0
		wall(w.cf, w.width, H, w.holes, CREAM, 0, 1, 0, STUDDED)
		wall(w.cf, w.width, H, w.holes, INTERIOR, 1, 0.5, inner)
		for i, hole in w.holes do
			trim(w.cf, w.width, hole, w.doors[i])
		end
	end
	-- Partition with a doorway, so there are two rooms to thread
	local partition = floor * CFrame.new(6, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
	wall(partition, sideWidth, H, { { sideWidth / 2 - 5, 0, 10, 12 } }, INTERIOR, -0.5, 1, 0)

	-- Stepped gable roof: red rim bricks on every step, cream gable fill between them.
	local roof = floor * CFrame.new(0, H, 0)
	local layer, depth = 0, D + 4
	while depth > 0 do
		local y = 1 + 2 * layer
		if depth <= 6 then
			block(Vector3.new(W + 4, 2, depth), roof * CFrame.new(0, y, 0), ROOF, STUDDED_TOP)
			break
		end
		for _, side in { -1, 1 } do
			block(Vector3.new(W + 4, 2, 2), roof * CFrame.new(0, y, side * (depth / 2 - 1)), ROOF, STUDDED_TOP)
		end
		block(Vector3.new(W, 2, depth - 4), roof * CFrame.new(0, y, 0), CREAM, STUDDED)
		layer += 1
		depth -= 4
	end
	block(Vector3.new(4, 12, 4), roof * CFrame.new(W / 4, 12, -D / 4), ROOF, STUDDED)
	block(Vector3.new(5, 1, 5), roof * CFrame.new(W / 4, 18.5, -D / 4), Color3.fromRGB(60, 58, 56), STUDDED_TOP)

	-- Furniture to fly around
	block(Vector3.new(14, 0.1, 10), floor * CFrame.new(-9, 0.45, 2), Color3.fromRGB(170, 60, 60))
	block(Vector3.new(6, 0.5, 4), floor * CFrame.new(-9, 3.1, 2), TIMBER, STUDDED_TOP)
	for _, lx in { -2.5, 2.5 } do
		for _, lz in { -1.5, 1.5 } do
			block(Vector3.new(0.6, 2.6, 0.6), floor * CFrame.new(-9 + lx, 1.6, 2 + lz), TIMBER)
		end
	end
	block(Vector3.new(11, 2, 3.5), floor * CFrame.new(-10, 1.4, -D / 2 + 4), Color3.fromRGB(70, 104, 166), STUDDED_TOP)
	block(Vector3.new(11, 3.5, 1), floor * CFrame.new(-10, 2.6, -D / 2 + 2), Color3.fromRGB(70, 104, 166))
	block(Vector3.new(9, 10, 2), floor * CFrame.new(W / 2 - 7, 5.4, -D / 2 + 2.5), TIMBER, STUDDED_TOP)
	for shelf = 1, 3 do
		block(Vector3.new(8, 1.6, 1.2), floor * CFrame.new(W / 2 - 7, 0.4 + shelf * 2.7, -D / 2 + 3.2), Color3.fromHSV(shelf * 0.27 % 1, 0.6, 0.75))
	end
	for _, roomX in { -8, 14 } do
		local lamp = block(Vector3.new(0.3, 3, 3), floor * CFrame.new(roomX, H - 0.55, 0) * VERTICAL, Color3.fromRGB(255, 240, 210), {
			Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Neon,
			CanCollide = false,
		})
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 226, 190)
		light.Range = 30
		light.Brightness = 1.3
		light.Shadows = true
		light.Parent = lamp
	end

	-- Garden path and bushes by the front door
	local doorX = 26 + 4.5 - W / 2
	block(Vector3.new(7, 0.3, 14), base * CFrame.new(doorX, 0.15, D / 2 + 4 + 7), STONE, STUDDED_TOP)
	for _, side in { -1, 1 } do
		block(Vector3.one * 5, base * CFrame.new(doorX + side * 7, 3.2, D / 2 + 2.4), Color3.fromRGB(58, 125, 62), { Shape = Enum.PartType.Ball })
	end
end

local function baseplate()
	-- Same as Studio's default Baseplate template, so the range matches the reference clip.
	local plate = block(Vector3.new(2048, 16, 2048), CFrame.new(0, -8, 0), Color3.fromRGB(91, 91, 91), { Name = "Baseplate", Locked = true })
	local grid = Instance.new("Texture")
	grid.Texture = "rbxassetid://6372755229"
	grid.Face = Enum.NormalId.Top
	grid.Color3 = Color3.new(0, 0, 0)
	grid.Transparency = 0.8
	grid.StudsPerTileU = 8
	grid.StudsPerTileV = 8
	grid.Parent = plate
end

function World.build(): CFrame
	for _, name in { "Baseplate", "SpawnLocation" } do
		local default = workspace:FindFirstChild(name)
		if default then
			default:Destroy()
		end
	end
	folder = Instance.new("Folder")
	folder.Name = "Range"

	baseplate()

	-- Launch pad and the pilot's spot behind it
	block(Vector3.new(0.3, 17.2, 17.2), CFrame.new(0, 0.14, 0) * VERTICAL, ACCENT, { Shape = Enum.PartType.Cylinder, Material = Enum.Material.Neon })
	block(Vector3.new(0.3, 16, 16), CFrame.new(0, 0.15, 0) * VERTICAL, Color3.fromRGB(40, 42, 48), { Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal })
	local pilot = Instance.new("SpawnLocation")
	pilot.Name = "PilotSpawn"
	pilot.Anchored = true
	pilot.Neutral = true
	pilot.Size = Vector3.new(6, 1, 6)
	pilot.CFrame = CFrame.new(0, 0.5, 16)
	pilot.Color = Color3.fromRGB(32, 34, 40)
	pilot.Material = Enum.Material.DiamondPlate
	pilot.Duration = 0
	pilot.Parent = folder

	house(CFrame.new(0, 0, -90))

	folder.Parent = workspace
	return CFrame.new(0, 0.85, 0)
end

return World
