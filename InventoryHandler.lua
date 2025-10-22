----------------------------------------------------------------------
-- InventoryHandler.lua  ·  2025-07-05
----------------------------------------------------------------------

local InventoryHandler   = {}
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UpdateSlotUI       = ReplicatedStorage:WaitForChild("UpdateSlotUI")
local HttpService        = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local ToggleEquipUI = game.ReplicatedStorage:WaitForChild("ToggleEquipUI")
local equippedBackpacks = {}
local EquipVisualSelect = ReplicatedStorage:WaitForChild("EquipVisualSelect")

-- Debug: Module load
print("[InventoryHandler] Module loaded from ReplicatedStorage")

-- Table of inventories indexed by Player instance
local playerInventories  = {}

----------------------------------------------------------------------
-- ▶ Ensure Weight stat exists on character ASAP (for UI sync!)
----------------------------------------------------------------------
game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		local w = char:FindFirstChild("Weight")
		if not w then
			w = Instance.new("NumberValue")
			w.Name  = "Weight"
			w.Value = 0
			w.Parent = char
			print("[InventoryHandler] (Auto-create) Weight stat for", player.Name)
		else
			print("[InventoryHandler] (Already exists) Weight stat for", player.Name)
		end
	end)
end)

----------------------------------------------------------------------
-- ▶ Utility helpers: backpack accessory
----------------------------------------------------------------------

-- Returns a BasePart you can attach a prompt to, or nil
local function getAttachPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
		-- Try common root names or any BasePart
		local main = inst:FindFirstChild("Main")
		if main and main:IsA("BasePart") then return main end
		local any = inst:FindFirstChildWhichIsA("BasePart")
		if any then return any end
	end
	return nil
end

-- Ensure a ProximityPrompt exists and is configured on either a Model or BasePart
local function ensureProximityPromptOnInstance(inst: Instance, itemName: string): ProximityPrompt?
	local part = getAttachPart(inst)
	if not part then
		warn(("[InventoryHandler] No attachable part for prompt on %s (%s)")
			:format(tostring(inst), typeof(inst)))
		return nil
	end

	-- Reuse existing or create new
	local prompt = part:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = part
	end

	-- Configure
	prompt.ActionText = (itemName == "Backpack") and "Open Backpack" or "Pick Up"
	prompt.ObjectText = itemName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.Enabled = true

	return prompt
end

local function clearPickedUpFlagDeep(model: Instance)
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("Instance") and inst:GetAttribute("PickedUp") ~= nil then
			inst:SetAttribute("PickedUp", false)
		end
	end
	if model:GetAttribute("PickedUp") ~= nil then
		model:SetAttribute("PickedUp", false)
	end
end

local function removeBackpack(player)
	local character = player.Character
	if not character then return end
	for _, inst in ipairs(character:GetChildren()) do
		if inst:IsA("Model") and inst.Name == "Backpack(Back)" then
			inst:Destroy()
		end
	end
end

local function attachBackpack(player)
	local character = player.Character
	if not character then return end

	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not torso then return end

	-- PREVENT DUPLICATES
	removeBackpack(player)

	local templateFolder = ReplicatedStorage:WaitForChild("ItemTemplatesNonAnchored")
	local modelTemplate  = templateFolder:WaitForChild("Backpack(Back)")

	local backpack = modelTemplate:Clone()
	backpack.Name = "Backpack(Back)"

	if not backpack.PrimaryPart then
		warn("Backpack model needs a PrimaryPart!")
		return
	end

	-- Make sure parts can be welded/moved
	for _, p in ipairs(backpack:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
		end
	end

	backpack.Parent = character
	backpack:PivotTo(torso.CFrame * CFrame.new(0, 0, 1.6))

	local weld = Instance.new("WeldConstraint")
	weld.Part0  = torso
	weld.Part1  = backpack.PrimaryPart
	weld.Parent = backpack.PrimaryPart
end

----------------------------------------------------------------------
-- ▶ Core inventory API
----------------------------------------------------------------------
function InventoryHandler:GetInventory(player)
	playerInventories[player] = playerInventories[player] or {
		slots    = { nil, nil, nil }, -- 1-3
		backpack = nil,               -- slot 4
		equipped = nil,               -- which slot is in hand
		handItem = nil                -- ad-hoc carried item
	}
	return playerInventories[player]
end

----------------------------------------------------------------------
-- ▶ Inventory WEIGHT system
----------------------------------------------------------------------

function InventoryHandler:SetCurrentBackpack(player, backpackInstance)
	if player and backpackInstance then
		equippedBackpacks[player] = backpackInstance
	end
end

function InventoryHandler:GetEquippedBackpack(player)
	return equippedBackpacks[player]
end

function InventoryHandler:UnsetCurrentBackpack(player)
	equippedBackpacks[player] = nil
end

function InventoryHandler:GetTotalWeight(player)
	local inv   = self:GetInventory(player)
	local total = 0

	local function weightOf(itemName)
		if not itemName then return 0 end
		local templates = ReplicatedStorage:FindFirstChild("ItemTemplatesNonAnchored")
		local tpl       = templates and templates:FindFirstChild(itemName)
		local w         = tpl and tpl:GetAttribute("Weight") or 0
		return w
	end

	for _, itemName in pairs(inv.slots) do
		total += weightOf(itemName)
	end
	total += weightOf(inv.backpack)
	total += weightOf(inv.handItem)
	
	local equippedBackpack = self:GetEquippedBackpack(player)
	if equippedBackpack then
		local BackpackInventoryHandler = require(ReplicatedStorage:WaitForChild("BackpackInventoryHandler"))
		local backpackWeight = BackpackInventoryHandler:GetBackpackWeight(equippedBackpack)
		total += backpackWeight
	end
	
	print("[GetTotalWeight] Player:", player.Name, "TotalWeight:", total)
	return total
end

function InventoryHandler:UpdatePlayerWeightStat(player)
	local char = player.Character
	if not char then
		print("[UpdatePlayerWeightStat] No character for", player.Name)
		return
	end
	local w = char:FindFirstChild("Weight")
	if not w then
		w = Instance.new("NumberValue")
		w.Name  = "Weight"
		w.Parent = char
		print("[UpdatePlayerWeightStat] Created Weight stat for", player.Name)
	end
	w.Value = self:GetTotalWeight(player)
	print("[UpdatePlayerWeightStat] Set Weight for", player.Name, "to", w.Value)
end

----------------------------------------------------------------------
-- ▶ Equip / unequip logic
----------------------------------------------------------------------
function InventoryHandler:EquipItemToHand(player, itemName, isHandItem, isUnequipping)
	local character = player.Character
	if not character then return end
	local inv       = self:GetInventory(player)

	local humanoid  = character:FindFirstChildOfClass("Humanoid")
	local backpack  = player:FindFirstChild("Backpack")
	if not humanoid or not backpack then return end

	local equippedTool = humanoid:FindFirstChildOfClass("Tool")
	if equippedTool and equippedTool.Name == itemName then
		humanoid:UnequipTools()
		equippedTool:Destroy()
		return
	end

	local isInventoryFull = isHandItem
	humanoid:UnequipTools()

	local existingTool = backpack:FindFirstChild(itemName)
	if existingTool then existingTool:Destroy() end

	local toolTemplateFolder = ReplicatedStorage:FindFirstChild("Tools")
	if not toolTemplateFolder then
		warn("Missing Tools folder in ReplicatedStorage")
		return
	end

	local toolTemplate = toolTemplateFolder:FindFirstChild(itemName)
	if not toolTemplate then
		warn("Tool not found:", itemName)
		return
	end

	local toolClone = toolTemplate:Clone()

	if itemName == "Backpack" then
		if isUnequipping then
			attachBackpack(player)
		else
			removeBackpack(player)
		end
	end

	for _, part in toolClone:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end
	if not toolClone:FindFirstChild("Handle") then
		local fallback = toolClone:FindFirstChild("Main")
			or toolClone.PrimaryPart
			or toolClone:FindFirstChildWhichIsA("BasePart")
		if fallback then fallback.Name = "Handle" else
			warn("No valid Handle found for", itemName)
			return
		end
	end

	toolClone.Parent = backpack
	if isInventoryFull then inv.handItem = itemName end

	task.defer(function()
		if humanoid and backpack:FindFirstChild(toolClone.Name) then
			humanoid:EquipTool(toolClone)
		end
	end)
end

----------------------------------------------------------------------
-- ▶ Adding / removing inventory items
----------------------------------------------------------------------
function InventoryHandler:AddItem(player, itemName, item, isHandItem)
	print("[AddItem] Called for", player.Name, itemName, isHandItem and "(HandItem)" or "")

	-- Validate inputs
	if type(itemName) ~= "string" or itemName == "" then
		warn("[AddItem] Invalid itemName:", itemName)
		return false
	end

	local hasWorldInstance = (typeof(item) == "Instance")

	-- If coming from the world, mark and guard against double-pickup
	if hasWorldInstance then
		if item:GetAttribute("PickedUp") then
			return false
		end
		item:SetAttribute("PickedUp", true)
	end

	local inv = self:GetInventory(player)

	-- If we're holding a temporary hand item, drop it first (keeps previous logic)
	if inv.handItem then
		self:DropItem(player)
	end

	----------------------------------------------------------------------
	-- Hand item flow (immediate equip, not placed in slots 1–3)
	----------------------------------------------------------------------
	if isHandItem then
		inv.handItem = itemName
		self:EquipItemToHand(player, itemName, true)

		if hasWorldInstance then
			item:Destroy() -- destroy world model only if it exists
		end

		self:UpdatePlayerWeightStat(player)
		print("[AddItem] (HandItem) Weight updated for", player.Name)
		return true
	end

	----------------------------------------------------------------------
	-- Backpack slot (slot 4)
	----------------------------------------------------------------------
	if itemName == "Backpack" then
		inv.backpack = itemName

		-- Preserve/assign BackpackID
		local idFromWorld = hasWorldInstance and item:GetAttribute("BackpackID") or nil
		if idFromWorld then
			inv.backpackID = idFromWorld
		else
			inv.backpackID = inv.backpackID or HttpService:GenerateGUID(false)
		end

		-- Track the equipped backpack *instance* only if we have one
		if hasWorldInstance then
			self:SetCurrentBackpack(player, item)
		end

		UpdateSlotUI:FireClient(player, 4, itemName, false)

		if hasWorldInstance then
			item:Destroy()
		end

		-- Auto-wear on the back if not holding something else
		if not inv.handItem then
			attachBackpack(player)
		end

		self:UpdatePlayerWeightStat(player)
		print("[AddItem] (Inventory/Backpack) Weight updated for", player.Name)
		return true
	end

	----------------------------------------------------------------------
	-- Normal items → first free slot (1..3), then auto-equip that slot
	----------------------------------------------------------------------
	for i = 1, 3 do
		if not inv.slots[i] then
			inv.slots[i] = itemName

			-- Auto-equip that slot
			self:EquipSlot(player, i)
			self:UpdatePlayerWeightStat(player)
			UpdateSlotUI:FireClient(player, i, itemName, false)

			if hasWorldInstance then
				item:Destroy()
			end

			print("[AddItem] (Inventory) Weight updated for", player.Name)
			return true
		end
	end

	-- No free slot
	warn("[AddItem] Inventory full for", player.Name, "while adding", itemName)
	return false
end


function InventoryHandler:RemoveItem(player, itemName)
	print("[RemoveItem] Called for", player.Name, itemName)
	local inv = self:GetInventory(player)

	if inv.handItem == itemName then
		inv.handItem = nil
		if itemName == "Backpack" then
			self:UpdatePlayerWeightStat(player)
			print("[RemoveItem] (HandItem/Backpack) Weight updated for", player.Name)
			return
		end
	end

	if itemName == "Backpack" then
		inv.backpack = nil
		UpdateSlotUI:FireClient(player, 4, itemName, true)
		removeBackpack(player)
	elseif inv.equipped and inv.slots[inv.equipped] == itemName then
		inv.slots[inv.equipped] = nil
		UpdateSlotUI:FireClient(player, inv.equipped, itemName, true)
	end

	self:UpdatePlayerWeightStat(player)
	print("[RemoveItem] (Post-Remove) Weight updated for", player.Name)
end

----------------------------------------------------------------------
-- ▶ Selecting / toggling equipped slot
----------------------------------------------------------------------
function InventoryHandler:EquipSlot(player, slotNumber)
	local inv           = self:GetInventory(player)
	local isUnequipping = false

	if inv.handItem then self:DropItem(player) end

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local backpack = player:FindFirstChild("Backpack")
		if humanoid and backpack then
			humanoid:UnequipTools()
			for _, t in ipairs(backpack:GetChildren()) do
				if t:IsA("Tool") then t:Destroy() end
			end
		end
	end


	if inv.equipped == slotNumber then inv.equipped = nil end
	if slotNumber == nil then
		ToggleEquipUI:FireClient(player, false)
	elseif inv.slots[slotNumber] ~= nil then
		ToggleEquipUI:FireClient(player, true)
	end
	if slotNumber == nil and inv.backpack ~= nil then
		isUnequipping = true
		attachBackpack(player)
	end

	inv.handItem = nil
	inv.equipped = slotNumber

	local itemName
	if slotNumber == 4 then
		itemName = inv.backpack
		removeBackpack(player)
	elseif slotNumber == 5 then
		itemName = inv.handItem
	else
		itemName = inv.slots[slotNumber]
	end

	if itemName then
		self:EquipItemToHand(player, itemName, false, isUnequipping)
		EquipVisualSelect:FireClient(player, slotNumber)
	end
end

----------------------------------------------------------------------
-- ▶ Public query helpers
----------------------------------------------------------------------
function InventoryHandler:GetEquippedItem(player)
	local inv = self:GetInventory(player)
	if inv.handItem then return inv.handItem end
	if inv.equipped == 4 then return inv.backpack
	elseif inv.equipped then return inv.slots[inv.equipped] end
	return nil
end

----------------------------------------------------------------------
-- ▶ Dropping items
----------------------------------------------------------------------
function InventoryHandler:DropItem(player)
	print("[DropItem] Called for", player.Name)
	local character = player.Character
	if not character then return end

	local inv      = self:GetInventory(player)
	local itemName = self:GetEquippedItem(player)
	if not itemName then
		print("[DropItem] No item equipped to drop for", player.Name)
		return
	end

	local templateFolder = ReplicatedStorage:WaitForChild("ItemTemplatesNonAnchored")
	local template       = templateFolder:FindFirstChild(itemName)
	if not template then
		warn("Template not found for: " .. itemName)
		return
	end

	local itemClone = template:Clone()
	itemClone.Parent = workspace

	itemClone:SetAttribute("PickedUp", false)
	clearPickedUpFlagDeep(itemClone)

	-- Ensure it actually has a ProximityPrompt for the client to hook up
	ensureProximityPromptOnInstance(itemClone, itemName)

	game:GetService("CollectionService"):AddTag(itemClone, "Equippable")
	itemClone:SetAttribute("ItemName", itemName)

	if itemName == "Backpack" and inv.handItem == nil then
		self:UnsetCurrentBackpack(player)
		removeBackpack(player)
	end	
	if itemName == "Backpack" then
		CollectionService:AddTag(itemClone, "Backpack")

		local inv = self:GetInventory(player)
		if inv.backpackID then
			itemClone:SetAttribute("BackpackID", inv.backpackID)
		else
			itemClone:SetAttribute("BackpackID", HttpService:GenerateGUID(false))
		end

		if itemClone.PrimaryPart then
			itemClone.PrimaryPart:SetAttribute("BackpackID", itemClone:GetAttribute("BackpackID"))
			itemClone.PrimaryPart:SetAttribute("PickedUp", false)
		end
		itemClone:SetAttribute("PickedUp", false)

		local backpackInventoryScript = require(ReplicatedStorage:WaitForChild("BackpackInventoryHandler"))
		backpackInventoryScript.InitializeBackpack(itemClone)
	end

	local function weldModel(model)
		local primary = model.PrimaryPart
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") and p ~= primary then
				p.Anchored = false
				local weld = Instance.new("WeldConstraint")
				weld.Part0  = primary
				weld.Part1  = p
				weld.Parent = primary
			end
		end
	end

	local function removeExistingWelds(model)
		for _, obj in ipairs(model:GetDescendants()) do
			if obj:IsA("WeldConstraint") then
				obj:Destroy()
			elseif obj:IsA("BasePart") then
				obj.Anchored = false
			end
		end
	end

	local rootPart
	if itemClone:IsA("Model") then
		if not itemClone.PrimaryPart then
			itemClone.PrimaryPart =
				itemClone:FindFirstChild("Main") or itemClone:FindFirstChildWhichIsA("BasePart")
		end
		rootPart = itemClone.PrimaryPart
	elseif itemClone:IsA("BasePart") then
		rootPart = itemClone
	else
		warn("Dropped item is neither Model nor BasePart")
		return
	end

	removeExistingWelds(itemClone)
	if itemClone:IsA("Model") then weldModel(itemClone) end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and rootPart then
		local dropCF = hrp.CFrame * CFrame.new(0, 0, -3)
		if itemClone:IsA("Model") then
			itemClone:SetPrimaryPartCFrame(dropCF)
		else
			rootPart.CFrame = dropCF
		end
	end

	self:RemoveItem(player, itemName)
	self:EquipSlot(player, nil)
	ToggleEquipUI:FireClient(player, false)
	self:UpdatePlayerWeightStat(player)
	print("[DropItem] (Post-drop) Weight updated for", player.Name)
end

----------------------------------------------------------------------
return InventoryHandler