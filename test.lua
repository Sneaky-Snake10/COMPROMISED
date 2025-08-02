-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")


-- SETTINGS
local BLOCK_SIZE = 3
local CHUNK_SIZE = 16
local LOAD_RADIUS = 12
local UNLOAD_RADIUS = 14
local NOISE_SCALE = 0.02
local HEIGHT_MULT = 8
local LOADS_PER_STEP = 2
local UNLOADS_PER_STEP = 1
local BLOCKS_PER_STEP = 4

local LOD_HIGH_RADIUS = 20
local LOD_MEDIUM_RADIUS = 40
local LOD_LOW_RADIUS = 60
local WORLD_BOTTOM_Y = -60 -- Define the bottom of the world here

-- STATE
local playerChunks = {}
local loadedChunks = {} -- chunkKey → true
local chunkParts = {} -- chunkKey → {Part, ...}
local loadQueue = {} -- chunkKey → Vector2(cx, cz)
local unloadQueue = {} -- chunkKey → Vector2(cx, cz)
local chunkTasks = {} -- chunkKey → { block jobs... }
local playerInfos = {} -- Now a global table accessible to all tasks

-- UTILITIES
local function chunkKey(cx, cz) return cx..","..cz end
local function terrainHeight(x,z)
	return math.floor(math.noise(x * NOISE_SCALE, z * NOISE_SCALE) * HEIGHT_MULT + 0.5)
end

local function worldToChunk(coord)
	return math.floor(coord / (BLOCK_SIZE * CHUNK_SIZE))
end

-- New function to determine the block's material type
local function getBlockMaterial(y, topHeight)
	if y == topHeight then
		return "Grass"
	elseif y * BLOCK_SIZE < -10 then
		return "DiamondPlate"
	elseif y * BLOCK_SIZE < 0 then
		return "Rock"
	else
		-- For layers below the top, we want a different material to mesh them separately
		return "Soil"
	end
end

-- New function for creating merged blocks
local function createMergedBlock(x, z, y, sxlen, szlen, materialName)
	local part = Instance.new("Part")
	-- Size is based on the dimensions of the merged rectangle
	part.Size = Vector3.new(sxlen * BLOCK_SIZE, BLOCK_SIZE, szlen * BLOCK_SIZE)

	-- Position is the center of the merged block
	part.Position = Vector3.new(
		(x * BLOCK_SIZE) + (part.Size.X / 2),
		(y * BLOCK_SIZE) + (BLOCK_SIZE / 2),
		(z * BLOCK_SIZE) + (part.Size.Z / 2)
	)

	part.Anchored = true
	part.Massless = true

	-- Determine material based on the passed-in material name
	if materialName == "Grass" then
		part.Material = Enum.Material.Grass
		part.Color = Color3.fromRGB(30, 180, 30)
	elseif materialName == "DiamondPlate" then
		part.Material = Enum.Material.DiamondPlate
		part.Color = Color3.fromRGB(100, 100, 100)
	elseif materialName == "Rock" then
		part.Material = Enum.Material.Rock
		part.Color = Color3.fromRGB(120, 100, 90)
	else -- "Soil"
		part.Material = Enum.Material.Grass
		part.Color = Color3.fromRGB(70, 50, 40) -- Use a dark color to represent soil
	end

	part.Parent = workspace

	return part
end


-- VISUAL & LOD
local function generateChunkTasks(cx, cz)
	local key = chunkKey(cx,cz)
	if loadedChunks[key] then return end
	loadedChunks[key] = true
	chunkParts[key] = {}
	local queue = {}

	-- First, get the terrain heights for the whole chunk
	local heights = {}
	local maxHeight = -math.huge
	for x = 0, CHUNK_SIZE - 1 do
		heights[x] = {}
		for z = 0, CHUNK_SIZE - 1 do
			local wx, wz = cx*CHUNK_SIZE + x, cz*CHUNK_SIZE + z
			heights[x][z] = terrainHeight(wx, wz)
			if heights[x][z] > maxHeight then
				maxHeight = heights[x][z]
			end
		end
	end

	-- Iterate top-down for greedy meshing
	for y = maxHeight, WORLD_BOTTOM_Y, -1 do
		local visited = {}
		-- Initialize visited grid for this layer
		for x = 0, CHUNK_SIZE - 1 do
			visited[x] = {}
			for z = 0, CHUNK_SIZE - 1 do
				visited[x][z] = false
			end
		end

		for x = 0, CHUNK_SIZE - 1 do
			for z = 0, CHUNK_SIZE - 1 do
				local topHeightForColumn = heights[x][z]

				-- Check if this voxel exists and hasn't been visited
				if y <= topHeightForColumn and not visited[x][z] then

					-- Get the material for the starting block
					local materialToMatch = getBlockMaterial(y, topHeightForColumn)

					-- Start greedy meshing

					-- Expand in Z direction
					local dz = 1
					while z + dz < CHUNK_SIZE and not visited[x][z+dz] do
						local nextBlockTopHeight = heights[x][z+dz]
						if y <= nextBlockTopHeight and getBlockMaterial(y, nextBlockTopHeight) == materialToMatch then
							dz += 1
						else
							break
						end
					end
					local dx = 1
					local rowIsUniform = true
					while x + dx < CHUNK_SIZE and rowIsUniform do
						for zz = z, z + dz - 1 do
							local nextBlockTopHeight = heights[x+dx][zz]
							-- Check if the new row is solid, unvisited, and has the same material
							if visited[x+dx][zz] or y > nextBlockTopHeight or getBlockMaterial(y, nextBlockTopHeight) ~= materialToMatch then
								rowIsUniform = false
								break
							end
						end
						if rowIsUniform then
							dx += 1
						end
					end
					for xx = x, x + dx - 1 do
						for zz = z, z + dz - 1 do
							visited[xx][zz] = true
						end
					end
					local wx, wz = cx * CHUNK_SIZE + x, cz * CHUNK_SIZE + z
					table.insert(queue, {wx, wz, dx, dz, y, materialToMatch})
				end
			end
		end
	end

	chunkTasks[key] = queue
end

local function applyLOD(parts, distChunks)
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			if distChunks <= LOD_HIGH_RADIUS then
				part.CastShadow = true
				--part.Material = Enum.Material.LeafyGrass
				part.CanCollide = true
			elseif distChunks <= LOD_MEDIUM_RADIUS then
				part.CastShadow = false
				--part.Material = Enum.Material.Grass
				part.CanCollide = true
			else
				part.CastShadow = false
				--part.Material = Enum.Material.SmoothPlastic
				part.CanCollide = false
			end
		end
	end
end

-- TASK QUEUE BUILDERS
local function enqueueLoad(cx, cz)
	local key = chunkKey(cx,cz)
	if not loadedChunks[key] and not loadQueue[key] and not chunkTasks[key] then
		loadQueue[key] = Vector2.new(cx, cz)
	end
end

local function enqueueUnload(cx, cz)
	local key = chunkKey(cx,cz)
	if loadedChunks[key] and not unloadQueue[key] then
		unloadQueue[key] = Vector2.new(cx, cz)
	end
end

-- MAIN PLAYER-UPDATE LOOP
task.spawn(function()
	while true do
		-- Reset playerChunks and playerInfos tables for this loop
		playerChunks = {}
		playerInfos = {}

		for _, pl in ipairs(Players:GetPlayers()) do
			local c = pl.Character
			local hrp = c and c:FindFirstChild("HumanoidRootPart")
			if hrp then
				local cx, cz = worldToChunk(hrp.Position.X), worldToChunk(hrp.Position.Z)
				table.insert(playerChunks, Vector2.new(cx, cz))
				playerInfos[pl] = hrp
				for dx = -LOAD_RADIUS, LOAD_RADIUS do
					for dz = -LOAD_RADIUS, LOAD_RADIUS do
						if dx*dx + dz*dz <= LOAD_RADIUS*LOAD_RADIUS then
							enqueueLoad(cx + dx, cz + dz)
						end
					end
				end
			end
		end

		-- Enqueue unloads
		for key,_ in pairs(loadedChunks) do
			local sx, sz = key:match("(-?%d+),(-?%d+)")
			local cx, cz = tonumber(sx), tonumber(sz)
			local needed = false
			for _, pc in ipairs(playerChunks) do
				if (cx - pc.X)^2 + (cz - pc.Y)^2 <= UNLOAD_RADIUS^2 then
					needed = true; break
				end
			end
			if not needed then enqueueUnload(cx, cz) end
		end

		-- Update LOD
		for key, parts in pairs(chunkParts) do
			local sx, sz = key:match("(-?%d+),(-?%d+)")
			local cx, cz = tonumber(sx), tonumber(sz)
			local mind = math.huge

			for _, hrp in pairs(playerInfos) do
				local dx = cx - worldToChunk(hrp.Position.X)
				local dz = cz - worldToChunk(hrp.Position.Z)
				local dist = math.sqrt(dx^2 + dz^2)
				mind = math.min(mind, dist)
			end

			applyLOD(parts, mind)
		end

		task.wait(3)
	end
end)

local function getDistanceToNearestPlayer(cx, cz, playerChunks)
	local minDist = math.huge
	for _, pChunk in ipairs(playerChunks) do
		local dx, dz = cx - pChunk.X, cz - pChunk.Y
		local dist = dx*dx + dz*dz
		if dist < minDist then
			minDist = dist
		end
	end
	return minDist
end

-- LOADING PROCESSOR
task.spawn(function()
	while true do
		local entries = {}
		for key, vec in pairs(loadQueue) do
			table.insert(entries, {key = key, vec = vec})
		end

		table.sort(entries, function(a, b)
			return getDistanceToNearestPlayer(a.vec.X, a.vec.Y, playerChunks) < getDistanceToNearestPlayer(b.vec.X, b.vec.Y, playerChunks)
		end)

		local count = 0
		for _, entry in ipairs(entries) do
			if count >= LOADS_PER_STEP then break end
			loadQueue[entry.key] = nil
			generateChunkTasks(entry.vec.X, entry.vec.Y)
			count += 1
		end
		task.wait(0.1)
	end
end)


-- BLOCK GENERATION PROCESSOR
task.spawn(function()
	while true do
		for key, queue in pairs(chunkTasks) do
			local cnt = 0

			-- Skip if the chunk was unloaded mid-generation
			if not chunkParts[key] then
				chunkTasks[key] = nil
				continue
			end

			while cnt < BLOCKS_PER_STEP and #queue > 0 do
				local b = table.remove(queue, 1)
				-- Pass the determined material name (b[6]) to the createMergedBlock function
				local part = createMergedBlock(b[1], b[2], b[5], b[3], b[4], b[6])
				if chunkParts[key] then  -- safeguard in case unloaded mid-loop
					table.insert(chunkParts[key], part)
				else
					part:Destroy()
				end
				cnt += 1
			end

			if #queue == 0 then
				chunkTasks[key] = nil
			end
		end
		task.wait(0.1)
	end
end)


-- UNLOAD PROCESSOR
task.spawn(function()
	while true do
		local cnt = 0
		for key, vec in pairs(unloadQueue) do
			if cnt >= UNLOADS_PER_STEP then break end
			unloadQueue[key] = nil
			if chunkParts[key] then
				for _, p in ipairs(chunkParts[key]) do
					p:Destroy()
					task.wait(0.1)
				end
				chunkParts[key] = nil
			end
			loadedChunks[key] = nil
			cnt += 1
			task.wait(0.4)
		end
		task.wait(20)
	end
end)


-- In your server Script:

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local virtualStartSeconds = 43200 -- 00:00:00 in seconds
local timeMultiplier = 36 -- 100 real seconds = 3600 in-game seconds (1 in-game hour)
local startTime = tick()

local function formatTime(totalSeconds)
	totalSeconds = totalSeconds % 86400 -- Wrap around 24h
	local hours = math.floor(totalSeconds / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = math.floor(totalSeconds % 60)
	return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

local function isNight(clockHour)
	return clockHour < 6 or clockHour >= 18
end

RunService.Heartbeat:Connect(function()
	local realElapsed = tick() - startTime
	local virtualSeconds = virtualStartSeconds + realElapsed * timeMultiplier
	local timeString = formatTime(virtualSeconds)

	-- Update Lighting
	Lighting.TimeOfDay = timeString
	local clockTime = (virtualSeconds / 3600) % 24
	Lighting.ClockTime = clockTime

	local yRotation = clockTime * 15
	if Lighting:FindFirstChild("Sky") then
		Lighting.Sky.SkyboxOrientation = Vector3.new(0, yRotation, 0)
	end

	Lighting.Brightness = isNight(clockTime) and 0.2 or 0.8
end)



-- Remove existing Sky if it exists
if Lighting:FindFirstChildOfClass("Sky") then
	Lighting:FindFirstChildOfClass("Sky"):Destroy()
end

-- Create and configure new Skybox
local sky = Instance.new("Sky")
sky.Name = "Sky"

sky.SkyboxBk = "rbxassetid://129876530632297"
sky.SkyboxDn = "rbxassetid://108406529909981"
sky.SkyboxFt = "rbxassetid://104400530594543"
sky.SkyboxLf = "rbxassetid://73372229972523"
sky.SkyboxRt = "rbxassetid://87408857415924"
sky.SkyboxUp = "rbxassetid://137817405681365"

sky.CelestialBodiesShown = true -- Show sun/moon (sun will be tiny!)
sky.MoonAngularSize = 2
sky.SunAngularSize = 0 -- Basically invisible sun
sky.StarCount = 0 --  Starless Night
sky.Parent = Lighting
for _, v in pairs(Lighting:GetChildren()) do
	if v:IsA("BloomEffect") then
		v:Destroy()
	end
end

local bloom = Instance.new("BloomEffect")
bloom.Enabled = true
bloom.Intensity = 10
bloom.Size = 56 -- Optional: tweak bloom spread
bloom.Threshold = 0.8 -- Optional: tweak brightness sensitivity
bloom.Parent = Lighting

local function cleanSounds(char)
	local rootPart = char:WaitForChild("HumanoidRootPart", 5)
	if rootPart then
		for _, sound in pairs(rootPart:GetChildren()) do
			if sound:IsA("Sound") and (sound.Name == "Running" or sound.Name == "Jumping") then
				sound:Destroy()
			end
		end
	end
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(cleanSounds)
end)

-- Clean up current players too
for _, player in pairs(Players:GetPlayers()) do
	if player.Character then
		cleanSounds(player.Character)
	end
	player.CharacterAdded:Connect(cleanSounds)
end

local existing = SoundService:FindFirstChild("music1")
if existing then
	existing:Destroy()
end
local music = Instance.new("Sound")
music.Name = "music1"
music.SoundId = "rbxassetid://84014724488068"
music.Looped = true
music.Playing = true
music.Volume = 0.5 -- Optional: change for chillness
music.Parent = SoundService
