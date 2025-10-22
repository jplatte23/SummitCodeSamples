-- BackpackInventoryHandler (ModuleScript)
local BackpackInventoryHandler = {}

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local CollectionService   = game:GetService("CollectionService")
local HttpService         = game:GetService("HttpService")

local BackpackInventoryUpdate = ReplicatedStorage:WaitForChild("BackpackInventoryUpdate")
local BackpackStoreItem       = ReplicatedStorage:WaitForChild("BackpackStoreItem")
local BackpackTakeItem        = ReplicatedStorage:WaitForChild("BackpackTakeItem")
local UpdateSlotUI            = ReplicatedStorage:WaitForChild("UpdateSlotUI")
local GetBackpackContents     = ReplicatedStorage:WaitForChild("GetBackpackContents")

local InventoryHandler = require(ReplicatedStorage:WaitForChild("InventoryHandler"))

-- All backpack inventories indexed by BackpackID
local backpackInventories = {}

---------------------------------------------------------------------
-- :: Remote-function so client UIs can fetch a backpack’s contents ::
---------------------------------------------------------------------
GetBackpackContents.OnServerInvoke = function(player, backpack)
	if not backpack then return nil end
	local id = backpack:GetAttribute("BackpackID")
	if not id then return nil end
	return backpackInventories[id]
end

------------------------------------------------
-- :: Helper to create / register a backpack ::
------------------------------------------------
function BackpackInventoryHandler.InitializeBackpack(backpack)
	if not backpack:GetAttribute("BackpackID") then
		backpack:SetAttribute("BackpackID", HttpService:GenerateGUID(false))
	end

	local id = backpack:GetAttribute("BackpackID")
	if not backpackInventories[id] then
		backpackInventories[id] = {
			TopLeft  = nil,
			TopRight = nil,
			BotLeft  = nil,
			BotRight = nil
		}
	end
end

-------------------------------
-- :: Public-facing getter  ::
-------------------------------
function BackpackInventoryHandler.GetInventory(backpack)
	local id = backpack:GetAttribute("BackpackID")
	return id and backpackInventories[id]
end

function BackpackInventoryHandler:GetBackpackWeight(backpackInstance)
	if not backpackInstance or typeof(backpackInstance) ~= "Instance" then
		warn("[BackpackWeight] Invalid backpack:", backpackInstance)
		return 0
	end

	local id = backpackInstance:GetAttribute("BackpackID")
	if not id then return 0 end

	local contents = backpackInventories[id]
	if not contents then return 0 end

	local templates = ReplicatedStorage:FindFirstChild("ItemTemplatesNonAnchored")
	local totalWeight = 0

	print("gothere1")
	for _, itemName in pairs(contents) do
		if itemName and templates then
			local tpl = templates:FindFirstChild(itemName)
			if tpl then
				local weight = tpl:GetAttribute("Weight") or 0
				totalWeight += weight
			end
		end
	end
	print("gothere2")
	print(totalWeight)
	return totalWeight
end

-------------------------------------------
-- :: Wire everything up on server start ::
-------------------------------------------
function BackpackInventoryHandler.Init()
	-- Any new model tagged “Backpack” gets registered automatically
	CollectionService:GetInstanceAddedSignal("Backpack"):Connect(function(backpack)
		BackpackInventoryHandler.InitializeBackpack(backpack)
	end)

	------------------------------------------------------
	-- :: PLAYER STORES AN ITEM INSIDE A BACKPACK SLOT ::
	------------------------------------------------------
	BackpackStoreItem.OnServerEvent:Connect(function(player, backpackInstance, slotName, itemName)
		if not backpackInstance or not itemName or not slotName then return end
		if not backpackInstance:IsDescendantOf(workspace) then return end

		local backpackID = backpackInstance:GetAttribute("BackpackID")
		if not backpackID then return end

		-- Guarantee inventory table exists
		backpackInventories[backpackID] = backpackInventories[backpackID] or {
			TopLeft  = nil,
			TopRight = nil,
			BotLeft  = nil,
			BotRight = nil
		}
		local backpackInventory = backpackInventories[backpackID]

		-- Don’t overwrite an occupied slot
		if backpackInventory[slotName] ~= nil then
			print("[DEBUG] Slot", slotName, "is already occupied!")
			return
		end

		------------------------------------------------
		-- Remove item from player inventory / hotbar --
		------------------------------------------------
		local playerInventory = InventoryHandler:GetInventory(player)
		local removed = false

		if playerInventory.handItem == itemName then
			playerInventory.handItem = nil
			InventoryHandler:EquipSlot(player, nil)
			removed = true

		elseif playerInventory.backpack == itemName then
			playerInventory.backpack = nil
			UpdateSlotUI:FireClient(player, 4, itemName, true)
			InventoryHandler:EquipSlot(player, nil)
			removed = true

		else -- search normal slots
			for i = 1, #playerInventory.slots do
				if playerInventory.slots[i] == itemName then
					playerInventory.slots[i] = nil
					UpdateSlotUI:FireClient(player, i, itemName, true)
					InventoryHandler:EquipSlot(player, nil)
					removed = true
					break
				end
			end
		end

		----------------------------------------------------------
		-- If removed == true the item now sits in the backpack  --
		----------------------------------------------------------
		if removed then
			backpackInventory[slotName] = itemName

			-- Re-calculate total carried weight ==> stamina GUI updates
			InventoryHandler:UpdatePlayerWeightStat(player)

			-- Broadcast new backpack state to all clients
			BackpackInventoryUpdate:FireAllClients(backpackInstance, backpackInventory)
		end
	end)

	------------------------------------------------------
	-- :: PLAYER TAKES AN ITEM OUT OF A BACKPACK SLOT  ::
	------------------------------------------------------
	BackpackTakeItem.OnServerEvent:Connect(function(player, backpack, slotName)
		local inventory = InventoryHandler:GetInventory(player)
		if not inventory then return end

		local backpackID = backpack:GetAttribute("BackpackID")
		if not backpackID then return end

		local contents = backpackInventories[backpackID]
		if not contents then return end

		local itemName = contents[slotName]
		if not itemName then return end

		-- Block if player is already holding something
		if inventory.handItem then return end

		-- Physically move item to player’s hand and clear slot
		contents[slotName] = nil
		local isHandItem = true
		for i = 1, 3 do
			if inventory.slots[i] == nil then
				isHandItem = false
				break
			end
		end
		InventoryHandler:AddItem(player, itemName, nil, isHandItem)

		print(player.Name .. " took out item:", itemName, "from slot:", slotName)

		-----------------------------------------------------------------
		-- NEW: Re-run the weight calculation so stamina GUI is correct --
		-----------------------------------------------------------------
		InventoryHandler:UpdatePlayerWeightStat(player)

		-- Send the fresh backpack contents to that player’s client
		BackpackInventoryUpdate:FireClient(player, backpack, contents)
	end)
end

return BackpackInventoryHandler