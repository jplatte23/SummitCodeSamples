local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sashFolder = ReplicatedStorage:WaitForChild("ClassSashes")
local classEvent = ReplicatedStorage:WaitForChild("SetClassFromTeleport")
local InventoryHandler = require(ReplicatedStorage:WaitForChild("InventoryHandler"))

local playerClassMap = {}
local connectionMap = {}
local lastCharacterMap = {}  -- Track last character we initialized for each player

local classItems = {
	["Boy Scout"] = { "TrailMix" },
	["Girl Scout"] = { "Thin Mints" },
	["Shroom Scout"] = { "Mushroom", "Mushroom", "Mushroom" },
	["Medic Scout"] = { "Medkit" },
	["Athletic Scout"] = { "Sports Drink" },
	["Gourmand Scout"] = { "Airline Food", "Thin Mints", "TrailMix" },
	["Energetic Scout"] = { "Energy Drink" },
	["Monke Scout"] = { "Banana" },
	["Giant Scout"] = { "Coconut" },
	["Blessed Scout"] = {},
	["Sticky Scout"] = { "Piton", "Piton" },
	["Sated Scout"] = {},
	["Goat Scout"] = { "Thin Mint", "RopeCannon" },
	["Scoutmaster"] = { "Airline Food", "RopeCannon" },
}

local function attachSash(player, className)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local sash = sashFolder:FindFirstChild(className .. "Sash")
	if sash then
		local accessory = sash:Clone()
		humanoid:AddAccessory(accessory)
	end
end

local function onCharacterAdded(player, character)
	-- Prevent double initialization per character
	if lastCharacterMap[player.UserId] == character then
		return
	end
	lastCharacterMap[player.UserId] = character

	local humanoid = character:WaitForChild("Humanoid")
	local itemTemplates = ReplicatedStorage:WaitForChild("ItemTemplatesNonAnchored")
	local playerClass = playerClassMap[player.UserId] or "Baby Scout"

	-- Add class items once per spawn
	local items = classItems[playerClass]
	if items then
		for _, itemName in ipairs(items) do
			local template = itemTemplates:FindFirstChild(itemName)
			if template then
				InventoryHandler:AddItem(player, itemName, template:Clone(), false)
			end
		end
	end

	-- Add class-specific stats (same as your code)
	if playerClass == "Baby Scout" then
		local climbSpeed = Instance.new("NumberValue")
		climbSpeed.Name = "ClimbSpeedMultiplier"
		climbSpeed.Value = 1.0
		climbSpeed.Parent = character
	elseif playerClass == "Medic Scout" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.15)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end
	elseif playerClass == "Athletic Scout" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.20)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end
	elseif playerClass == "Energetic Scout" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.20)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end
	elseif playerClass == "Monke Scout" then
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = 18

		local climbSpeed = Instance.new("NumberValue")
		climbSpeed.Name = "ClimbSpeedMultiplier"
		climbSpeed.Value = 1.15
		climbSpeed.Parent = character
	elseif playerClass == "Giant Scout" then
		humanoid.BodyHeightScale.Value = 1.5
		humanoid.BodyWidthScale.Value = 1.5
		humanoid.BodyDepthScale.Value = 1.5
		humanoid.HeadScale.Value = 1.5
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.20)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end
	elseif playerClass == "Blessed Scout" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.40)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end
	elseif playerClass == "Sticky Scout" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.20)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end
	elseif playerClass == "Goat Scout" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.15)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end

		local climbSpeed = Instance.new("NumberValue")
		climbSpeed.Name = "ClimbSpeedMultiplier"
		climbSpeed.Value = 1.15
		climbSpeed.Parent = character
	elseif playerClass == "Scoutmaster" then
		local staminaMax = character:WaitForChild("StaminaMax", 3)
		local stamina = character:WaitForChild("Stamina", 3)
		if staminaMax and stamina then
			local bonus = math.floor(staminaMax.Value * 0.30)
			staminaMax.Value += bonus
			stamina.Value = staminaMax.Value 
		end

		local climbSpeed = Instance.new("NumberValue")
		climbSpeed.Name = "ClimbSpeedMultiplier"
		climbSpeed.Value = 1.3
		climbSpeed.Parent = character
	end

	attachSash(player, playerClass)
end

classEvent.OnServerEvent:Connect(function(player, className)
	if typeof(className) ~= "string" then return end

	playerClassMap[player.UserId] = className
	player:SetAttribute("ScoutClass", className)

	-- Disconnect old connection if exists
	if connectionMap[player.UserId] then
		connectionMap[player.UserId]:Disconnect()
	end

	-- Connect new CharacterAdded event
	connectionMap[player.UserId] = player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	-- Call manually ONLY if character exists and we haven't already processed it
	local character = player.Character
	if character and lastCharacterMap[player.UserId] ~= character then
		onCharacterAdded(player, character)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	if connectionMap[userId] then
		connectionMap[userId]:Disconnect()
		connectionMap[userId] = nil
	end
	playerClassMap[userId] = nil
	lastCharacterMap[userId] = nil
end)
