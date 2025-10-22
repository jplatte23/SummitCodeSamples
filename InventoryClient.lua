--[[
Full Inventory Client Script
]]--

-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local UIS               = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local SoundService      = game:GetService("SoundService")

-- // Remotes
local EquipEvent              = ReplicatedStorage:WaitForChild("EquipItemSlot")
local EquipVisualSelect       = ReplicatedStorage:WaitForChild("EquipVisualSelect", 2)
local PickupEvent             = ReplicatedStorage:WaitForChild("AddItemToInventory")
local CanPickupItem           = ReplicatedStorage:WaitForChild("CanPickupItem")
local IsHoldingItem           = ReplicatedStorage:WaitForChild("IsHoldingItem")
local updateSlotEvent         = ReplicatedStorage:WaitForChild("UpdateSlotUI")
local GetEquippedItem         = ReplicatedStorage:WaitForChild("GetEquippedItem")
local DropEvent               = ReplicatedStorage:WaitForChild("DropEquippedItem")
local BackpackStoreItem       = ReplicatedStorage:WaitForChild("BackpackStoreItem")
local BackpackInventoryUpdate = ReplicatedStorage:WaitForChild("BackpackInventoryUpdate")
local GetBackpackContents     = ReplicatedStorage:WaitForChild("GetBackpackContents")
local ToggleEquipUI           = ReplicatedStorage:WaitForChild("ToggleEquipUI")

-- // Player & UI refs
local player = Players.LocalPlayer
local playerGui
local inventoryUI
local controlsUI
local itemControlsUI
local inventoryFrame
local backpackFrame
local backpackPickupButton

local function refreshUIRefs()
	playerGui            = player:WaitForChild("PlayerGui")
	inventoryUI          = playerGui:WaitForChild("Inventory")
	controlsUI           = playerGui:WaitForChild("Controls")
	itemControlsUI       = controlsUI:WaitForChild("ItemControls")
	inventoryFrame       = inventoryUI:WaitForChild("InventorySlots")
	backpackFrame        = inventoryUI:WaitForChild("BackpackFrame")
	backpackPickupButton = backpackFrame:WaitForChild("BotMid")
	backpackFrame.Active = true
	backpackFrame.ClipsDescendants = false
end
refreshUIRefs()

-- Remember default Z for later (mobile overlay bump)
local invDefaultZ = inventoryFrame.ZIndex or 1
local function isMobile() return UIS.TouchEnabled and not UIS.KeyboardEnabled end
local function setHotbarFrontForMobile(front)
	if not isMobile() then return end
	inventoryFrame.ZIndex = front and 100 or invDefaultZ
end

-- // Mobile-aware placement
local camera = workspace.CurrentCamera
local MOBILE_ANCHOR           = Vector2.new(0.5, 1)
local MOBILE_POS_X_FRAC       = 0.55
local MOBILE_POS_X_OFFSET_PX  = 0
local MOBILE_BOTTOM_FRAC      = 0.05
local MOBILE_BOTTOM_OFFSET_PX = 8
local TWEEN_TIME              = 0.0
local MOVE_BACKPACK_TOO       = false

local invDefaultAP  = inventoryFrame.AnchorPoint
local invDefaultPos = inventoryFrame.Position
local bpDefaultAP   = backpackFrame and backpackFrame.AnchorPoint
local bpDefaultPos  = backpackFrame and backpackFrame.Position

local SELECT_SOUND_ID = "rbxassetid://9055474333"
local selectSFX
local function initSelectSFX()
	if selectSFX and selectSFX.Parent then return end
	selectSFX = Instance.new("Sound")
	selectSFX.Name = "SlotSelectSFX"
	selectSFX.SoundId = SELECT_SOUND_ID
	selectSFX.Volume = 0.6
	selectSFX.Parent = SoundService
end
local function playSelectSound()
	if not selectSFX or not selectSFX.Parent then initSelectSFX() end
	SoundService:PlayLocalSound(selectSFX)
end

local function applyMobilePlacement()
	if not inventoryFrame then return end
	local vh = (camera and camera.ViewportSize.Y) or 720
	local bottomOffsetPx = math.floor(vh * MOBILE_BOTTOM_FRAC) + MOBILE_BOTTOM_OFFSET_PX
	local goalAP  = MOBILE_ANCHOR
	local goalPos = UDim2.new(MOBILE_POS_X_FRAC, MOBILE_POS_X_OFFSET_PX, 1, -bottomOffsetPx)
	if TWEEN_TIME > 0 then
		TweenService:Create(inventoryFrame, TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			AnchorPoint = goalAP, Position = goalPos
		}):Play()
	else
		inventoryFrame.AnchorPoint = goalAP
		inventoryFrame.Position    = goalPos
	end
	if MOVE_BACKPACK_TOO and backpackFrame then
		backpackFrame.AnchorPoint = MOBILE_ANCHOR
		backpackFrame.Position    = UDim2.new(MOBILE_POS_X_FRAC, MOBILE_POS_X_OFFSET_PX, 1, -(bottomOffsetPx + 64))
	end
end

local function restoreDesktopPlacement()
	if not inventoryFrame then return end
	if invDefaultAP  then inventoryFrame.AnchorPoint = invDefaultAP end
	if invDefaultPos then inventoryFrame.Position   = invDefaultPos end
	if MOVE_BACKPACK_TOO and backpackFrame then
		if bpDefaultAP  then backpackFrame.AnchorPoint = bpDefaultAP end
		if bpDefaultPos then backpackFrame.Position   = bpDefaultPos end
	end
end

local function placeForPlatform() if isMobile() then applyMobilePlacement() else restoreDesktopPlacement() end end
placeForPlatform()
if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(function() if isMobile() then applyMobilePlacement() end end) end
UIS.LastInputTypeChanged:Connect(placeForPlatform)
Players.LocalPlayer.CharacterAdded:Connect(function()
	task.defer(placeForPlatform)
	task.delay(0.2, placeForPlatform)
end)

-- // Inventory slot frames accessor (Slots 1..3 + BackpackSlot (4))
local function getSlotFrames()
	local invUI    = player:WaitForChild("PlayerGui"):WaitForChild("Inventory")
	local invFrame = invUI:WaitForChild("InventorySlots")
	return {
		invFrame:WaitForChild("Slot1"),
		invFrame:WaitForChild("Slot2"),
		invFrame:WaitForChild("Slot3"),
		invFrame:WaitForChild("BackpackSlot"),
	}
end

-- // Selection visuals
local NORMAL_SCALE   = 1
local SELECTED_SCALE = 1.12
local tweenIn  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local tweenOut = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local slotScales = {}
local selectedMainIndex = nil
local backpackSelected  = false

local slotContents = {}
local pendingSelectItemName, pendingSelectStamp = nil, 0
local function startPendingSelection(itemName)
	pendingSelectItemName = itemName
	pendingSelectStamp = os.clock()
	local myStamp = pendingSelectStamp
	task.delay(1.0, function() if pendingSelectStamp == myStamp then pendingSelectItemName = nil end end)
end

-- wrapper/scales
local function ensureSlotWrappers()
	inventoryFrame.ClipsDescendants = false
	local slots = getSlotFrames()
	for i, slot in ipairs(slots) do
		slot.ClipsDescendants = false
		slot.ZIndex = 1
		local wrapper = slot:FindFirstChild("ScaleWrapper")
		if not wrapper then
			wrapper = Instance.new("Frame")
			wrapper.Name = "ScaleWrapper"
			wrapper.BackgroundTransparency = 1
			wrapper.Size = UDim2.fromScale(1,1)
			wrapper.Parent = slot
			for _, child in ipairs(slot:GetChildren()) do
				if child ~= wrapper and child.ClassName ~= "UIListLayout" and child.Name ~= "HitArea" then
					child.Parent = wrapper
				end
			end
		end
		if i == 1 then wrapper.AnchorPoint = Vector2.new(0,0.5);   wrapper.Position = UDim2.fromScale(0,0.5)
		elseif i == 2 then wrapper.AnchorPoint = Vector2.new(0.5,0.5); wrapper.Position = UDim2.fromScale(0.5,0.5)
		else wrapper.AnchorPoint = Vector2.new(1,0.5);   wrapper.Position = UDim2.fromScale(1,0.5) end
		local s = wrapper:FindFirstChild("SelectionScale")
		if not s then s = Instance.new("UIScale"); s.Name="SelectionScale"; s.Scale = NORMAL_SCALE; s.Parent=wrapper end
		slotScales[i] = s
	end
end
local function getWrapperForIndex(i) local slot = getSlotFrames()[i]; return slot and slot:FindFirstChild("ScaleWrapper") or nil end
local REVEAL_NAMES = {"Frame"}
local function findRevealTargets(i)
	local slot = getSlotFrames()[i]; if not slot then return {} end
	local wrapper = getWrapperForIndex(i); local parent = wrapper or slot; local found = {}
	for _, n in ipairs(REVEAL_NAMES) do local obj = parent:FindFirstChild(n); if obj and obj:IsA("GuiObject") then table.insert(found, obj) end end
	for _, d in ipairs(parent:GetDescendants()) do if d:IsA("GuiObject") and d:GetAttribute("RevealOnSelect") then table.insert(found, d) end end
	return found
end
local function setRevealVisible(i, visible) for _, obj in ipairs(findRevealTargets(i)) do obj.Visible = visible end end
local function growVisual(i) local slots=getSlotFrames(); if slotScales[i] then setRevealVisible(i,true); TweenService:Create(slotScales[i],tweenIn,{Scale=SELECTED_SCALE}):Play(); slots[i].ZIndex=5; playSelectSound() end end
local function shrinkVisual(i) local slots=getSlotFrames(); if slotScales[i] then setRevealVisible(i,false); TweenService:Create(slotScales[i],tweenOut,{Scale=NORMAL_SCALE}):Play(); slots[i].ZIndex=1 end end
local function ensureSelectedVisual(i)
	if i>=1 and i<=3 then
		if selectedMainIndex ~= i then if selectedMainIndex then shrinkVisual(selectedMainIndex) end; selectedMainIndex=i; growVisual(i) end
	elseif i==4 then
		if selectedMainIndex then shrinkVisual(selectedMainIndex); selectedMainIndex=nil end
		if not backpackSelected then growVisual(4); backpackSelected=true end
	end
end
local function selectSlotVisual(i)
	if i>=1 and i<=3 then
		if selectedMainIndex==i then shrinkVisual(i); selectedMainIndex=nil; return end
		if selectedMainIndex then shrinkVisual(selectedMainIndex) end
		selectedMainIndex=i; growVisual(i)
		if backpackSelected then shrinkVisual(4); backpackSelected=false end
	elseif i==4 then
		if selectedMainIndex then shrinkVisual(selectedMainIndex); selectedMainIndex=nil end
		if backpackSelected then shrinkVisual(4); backpackSelected=false else growVisual(4); backpackSelected=true end
	end
end

-- Click/tap hookups for main hotbar slots
local clickConns = {}
local function getClickableForSlot(slot) if slot:IsA("GuiButton") then return slot end; return slot:FindFirstChild("HitArea") end
local function setAllSlotHitAreasActive(active)
	for _, slot in ipairs(getSlotFrames()) do
		if slot:IsA("GuiButton") then slot.Active = active; slot.ZIndex = active and 5 or 1 end
		local hit = slot:FindFirstChild("HitArea")
		if hit then hit.Visible = active; hit.Active = active; hit.ZIndex = active and 1 or 0 end
	end
end
local function hookSlotClickConnections()
	for _, c in ipairs(clickConns) do if c.Connected then c:Disconnect() end end
	table.clear(clickConns)
	for i, slot in ipairs(getSlotFrames()) do
		local btn = getClickableForSlot(slot)
		if btn and btn.Activated then
			table.insert(clickConns, btn.Activated:Connect(function() selectSlotVisual(i); EquipEvent:FireServer(i) end))
		elseif btn and btn.MouseButton1Click then
			table.insert(clickConns, btn.MouseButton1Click:Connect(function() selectSlotVisual(i); EquipEvent:FireServer(i) end))
		end
	end
end

local function ensureSlotTouchTargets()
	for _, slot in ipairs(getSlotFrames()) do
		if slot:IsA("GuiButton") then
			slot.AutoButtonColor=false; slot.ClipsDescendants=false; slot.ZIndex=5
		else
			local hit = slot:FindFirstChild("HitArea")
			if not hit then
				hit = Instance.new("TextButton")
				hit.Name="HitArea"; hit.Text=""; hit.BackgroundTransparency=1; hit.AutoButtonColor=false
				hit.ZIndex=1; hit.Size=UDim2.fromScale(1,1); hit.Active=true; hit.Visible=true; hit.Parent=slot
			else
				hit.ZIndex=1; hit.Active=true; hit.Visible=true
			end
		end
	end
end

ensureSlotWrappers()
ensureSlotTouchTargets()
hookSlotClickConnections()

-- Reset visuals on respawn
player.CharacterAdded:Connect(function()
	task.wait(0.5)
	refreshUIRefs()
	ensureSlotTouchTargets()
	ensureSlotWrappers()
	hookSlotClickConnections()
	if selectedMainIndex then shrinkVisual(selectedMainIndex) end
	if backpackSelected then shrinkVisual(4) end
	selectedMainIndex=nil; backpackSelected=false
	if typeof(_G.__RefreshBackpackRefs)=="function" then _G.__RefreshBackpackRefs() end
	invDefaultZ = inventoryFrame.ZIndex or invDefaultZ
end)

-- // Item images
local itemImageMap = {
	["Piton"]        = "rbxassetid://104884394292614",
	["Antidote"]     = "rbxassetid://111723780700309",
	["Bandage"]      = "rbxassetid://101489139322577",
	["Lantern"]      = "rbxassetid://85727031081648",
	["Medkit"]       = "rbxassetid://77599533288567",
	["Rope"]         = "rbxassetid://118023743231153",
	["Banana"]       = "rbxassetid://117520612684749",
	["Coconut"]      = "rbxassetid://100106431106864",
	["RopeCannon"]   = "rbxassetid://85549731953748",
	["Thin Mints"]   = "rbxassetid://122857064088494",
	["TrailMix"]     = "rbxassetid://124253410800806",
	["Energy Drink"] = "rbxassetid://104322099279315",
	["Sports Drink"] = "rbxassetid://140585674053924",
	["Mushroom"]     = "rbxassetid://85584998475946",
	["Airline Food"] = "rbxassetid://109561829369209",
	["Red Berry"]    = "rbxassetid://128911817867887",
	["Egg"]          = "rbxassetid://112399441062404"
}

-- // Backpack UI state
local holdingE = false
local currentBackpackPrompt = nil
local hasPickedUpBackpack = false
local currentBackpackItem = nil
local slotHasItem, originalColors = {}, {}

-- Track the current overlay key (may be temp fallback before real ID arrives)
local currentOverlayKey = nil

-- // Backpack refs (slots/labels)
local backpackSlots, backpackLabels
local function refreshBackpackRefs()
	backpackSlots = {
		backpackFrame:WaitForChild("BotLeft"),
		backpackFrame:WaitForChild("BotRight"),
		backpackFrame:WaitForChild("TopLeft"),
		backpackFrame:WaitForChild("TopRight"),
	}
	backpackLabels = {
		backpackFrame:WaitForChild("HoverBotLeft"),
		backpackFrame:WaitForChild("HoverBotRight"),
		backpackFrame:WaitForChild("HoverTopLeft"),
		backpackFrame:WaitForChild("HoverTopRight"),
	}
end
refreshBackpackRefs()
_G.__RefreshBackpackRefs = function() refreshBackpackRefs(); if typeof(_G.__EnsureTapOverlays)=="function" then _G.__EnsureTapOverlays() end end

ToggleEquipUI.OnClientEvent:Connect(function(shouldShow) itemControlsUI.Visible = shouldShow end)

-- ---------- World position helpers (fix Model.Position nil + LOS flicker) ----------
local function getPartPosition(part)
	return (part and part:IsA("BasePart")) and part.Position or nil
end

local function getModelPosition(model)
	if model and model:IsA("Model") then
		local ok, cf = pcall(function() return model:GetPivot() end)
		if ok and typeof(cf) == "CFrame" then
			return cf.Position
		end
		-- Fallback to PrimaryPart, if set
		if model.PrimaryPart then
			return model.PrimaryPart.Position
		end
	end
	return nil
end

local function getPromptWorldPosition(prompt, item)
	-- Prefer ProximityPrompt.Adornee if present
	if prompt and prompt.Adornee then
		local p = getPartPosition(prompt.Adornee)
		if p then return p end
	end
	-- Next, try the prompt's parent if it's a BasePart
	if prompt and prompt.Parent then
		local p = getPartPosition(prompt.Parent)
		if p then return p end
	end
	-- Finally, get model pivot
	return getModelPosition(item)
end

-- ---------- Safe BackpackID getter (tolerates late replication) ----------
local function getBackpackID(model)
	local id = model:GetAttribute("BackpackID")
	if not id and model.PrimaryPart then
		id = model.PrimaryPart:GetAttribute("BackpackID")
	end
	if id then return id end
	local t0 = os.clock()
	while not id and os.clock() - t0 < 0.5 do
		RunService.Heartbeat:Wait()
		id = model:GetAttribute("BackpackID")
			or (model.PrimaryPart and model.PrimaryPart:GetAttribute("BackpackID"))
	end
	return id
end

-- ---------- Overlay tap helpers (unchanged) ----------
local function assignItemToSlot(slotButton, itemName)
	local slotName = slotButton.Name
	if not currentBackpackItem then return end
	if itemName ~= "Backpack" then
		BackpackStoreItem:FireServer(currentBackpackItem, slotName, itemName)
	end
end

local function collapseBackpackSelection()
	if backpackSelected then shrinkVisual(4); backpackSelected=false end
end

local function tryPickupBackpack()
	if not currentBackpackItem then return end
	hasPickedUpBackpack = true
	local backpackId = currentBackpackItem:GetAttribute("BackpackID")
	if not backpackId then hasPickedUpBackpack=false; return end
	_G.backpackPickupLocks = _G.backpackPickupLocks or {}
	if _G.backpackPickupLocks[backpackId] then hasPickedUpBackpack=false; return end
	_G.backpackPickupLocks[backpackId] = true
	local itemName  = currentBackpackItem:GetAttribute("ItemName")
	if not itemName then _G.backpackPickupLocks[backpackId]=nil; hasPickedUpBackpack=false; return end
	local canPickup = CanPickupItem:InvokeServer(itemName)
	local isHolding = IsHoldingItem:InvokeServer()
	if canPickup then
		PickupEvent:FireServer(itemName, currentBackpackItem, false)
		collapseBackpackSelection()
	elseif not isHolding and itemName ~= "Backpack" then
		PickupEvent:FireServer(itemName, currentBackpackItem, true)
		collapseBackpackSelection()
	else
		warn("[DEBUG] Inventory full and already holding an item:", itemName)
	end
	backpackFrame.Visible=false
	holdingE=false
	setAllSlotHitAreasActive(true)
	setHotbarFrontForMobile(false)
	task.delay(1, function() _G.backpackPickupLocks[backpackId]=nil end)
	hasPickedUpBackpack=false
end

local function actOnBackpackSlot(slotIndex)
	if not backpackFrame.Visible then return end
	local button = backpackSlots[slotIndex]; if not button then return end

	local heldItem = GetEquippedItem:InvokeServer()
	local backpackId = currentBackpackItem and currentBackpackItem:GetAttribute("BackpackID")
	local slotOccupied = backpackId and slotHasItem[backpackId] and slotHasItem[backpackId][slotIndex]

	if slotOccupied then
		ReplicatedStorage.BackpackTakeItem:FireServer(currentBackpackItem, button.Name)
	elseif heldItem and heldItem ~= "" then
		assignItemToSlot(button, heldItem)
	else
		ReplicatedStorage.BackpackTakeItem:FireServer(currentBackpackItem, button.Name)
	end

	backpackFrame.Visible=false
	holdingE=false
	setAllSlotHitAreasActive(true)
	setHotbarFrontForMobile(false)
	collapseBackpackSelection()
end

-- PC click on slot images
for _, button in ipairs(backpackSlots) do
	local idx = table.find(backpackSlots, button)
	if idx then
		local function handleClick() actOnBackpackSlot(idx) end
		if button.Activated then button.Activated:Connect(handleClick)
		else button.MouseButton1Click:Connect(handleClick) end
	end
end

-- Hover highlights (PC)
local originalColor = backpackPickupButton.ImageColor3
local highlightColor = Color3.fromRGB(255,255,200)
for i = 1, 4 do
	local label = backpackLabels[i]; local button = backpackSlots[i]
	label.Active = true
	label.BackgroundTransparency = 1
	label.ZIndex = 10
	label.MouseEnter:Connect(function() button.ImageColor3=highlightColor; button.ImageTransparency=0.2 end)
	label.MouseLeave:Connect(function()
		local id = currentBackpackItem and currentBackpackItem:GetAttribute("BackpackID")
		if id and slotHasItem[id] and slotHasItem[id][i] then
			backpackSlots[i].ImageColor3 = Color3.new(1,1,1); backpackSlots[i].ImageTransparency=0.4
		else
			backpackSlots[i].ImageColor3 = (originalColors[id] and originalColors[id][i]) or Color3.new(1,1,1)
			backpackSlots[i].ImageTransparency=0.7
		end
	end)
end
backpackPickupButton.MouseEnter:Connect(function()
	backpackPickupButton.ImageColor3=highlightColor; backpackPickupButton.ImageTransparency=0.2
end)
backpackPickupButton.MouseLeave:Connect(function()
	backpackPickupButton.ImageColor3=originalColor; backpackPickupButton.ImageTransparency=0.4
end)

-- MOBILE TAP overlays
local slotTapDebounce = {}
local function makeTapOverlay(host, z, onActivated)
	local tap = host:FindFirstChild("Tap")
	if not tap then
		tap = Instance.new("TextButton")
		tap.Name="Tap"; tap.Text=""; tap.BackgroundTransparency=1; tap.AutoButtonColor=false
		tap.Size=UDim2.fromScale(1,1); tap.Position=UDim2.fromScale(0,0)
		tap.Active=true; tap.ZIndex = z; tap.Selectable=false; tap.Parent=host
	end
	if not tap:GetAttribute("Wired") then
		if tap.Activated then tap.Activated:Connect(onActivated) else tap.MouseButton1Click:Connect(onActivated) end
		tap:SetAttribute("Wired", true)
	end
	return tap
end

local function ensureTapOverlays()
	for _, slot in ipairs(backpackSlots) do
		local img = slot:FindFirstChild("ImageLabel")
		if img and img:IsA("ImageLabel") then
			img.Active = false
			img.ZIndex = (slot.ZIndex or 10) - 1
		end
	end
	for i, label in ipairs(backpackLabels) do
		label.Active = UIS.KeyboardEnabled
		label.ZIndex = label.ZIndex > 0 and label.ZIndex or 10
		makeTapOverlay(label, label.ZIndex + 1, function()
			if slotTapDebounce[i] then return end
			slotTapDebounce[i] = true
			actOnBackpackSlot(i)
			task.delay(0.12, function() slotTapDebounce[i] = nil end)
		end)
	end
	backpackPickupButton.Active = true
	backpackPickupButton.ZIndex = backpackPickupButton.ZIndex > 0 and backpackPickupButton.ZIndex or 10
	makeTapOverlay(backpackPickupButton, backpackPickupButton.ZIndex + 1, function()
		if hasPickedUpBackpack then return end
		tryPickupBackpack()
	end)
end
_G.__EnsureTapOverlays = ensureTapOverlays
ensureTapOverlays()

backpackPickupButton.MouseButton1Click:Connect(function()
	if not hasPickedUpBackpack then tryPickupBackpack() end
end)

-- ---------- Overlay lifecycle (with safe distance watchdog) ----------
local distanceConn -- RenderStepped connection for close-on-distance

local function closeOverlayUI()
	holdingE = false
	backpackFrame.Visible = false
	setAllSlotHitAreasActive(true)
	setHotbarFrontForMobile(false)
	if distanceConn then distanceConn:Disconnect() distanceConn = nil end
end

local function openBackpackOverlay(item, prompt)
	-- 1) fetch contents safely
	local ok, contents = pcall(function()
		return GetBackpackContents:InvokeServer(item)
	end)
	if not ok then contents = nil end

	-- 2) clear visuals
	for _, slot in ipairs(backpackSlots) do
		local imageLabel = slot:FindFirstChild("ImageLabel")
		if imageLabel then imageLabel.Image=""; imageLabel.Visible=false end
	end

	-- 3) resolve an ID (may be late)
	local currentID = getBackpackID(item)
	if not currentID then
		currentID = tostring(item:GetDebugId())
	end
	currentOverlayKey = currentID

	-- 4) guard tables and fill
	slotHasItem[currentID]    = slotHasItem[currentID] or {}
	originalColors[currentID] = originalColors[currentID] or {}

	for i, slot in ipairs(backpackSlots) do
		local imageLabel = slot:FindFirstChild("ImageLabel")
		local slotName   = slot.Name
		local nm         = contents and contents[slotName]
		if nm and itemImageMap[nm] then
			imageLabel.Image = itemImageMap[nm]; imageLabel.Visible=true
			slot.ImageColor3 = Color3.new(1,1,1); slotHasItem[currentID][i] = true
			originalColors[currentID][i] = Color3.new(1,1,1); slot.ImageTransparency=0.4
		else
			if imageLabel then imageLabel.Image=""; imageLabel.Visible=false end
			slotHasItem[currentID][i] = false
			originalColors[currentID][i] = slot.ImageColor3
			slot.ImageColor3 = originalColor; slot.ImageTransparency=0.7
		end
	end

	currentBackpackItem   = item
	hasPickedUpBackpack   = false
	currentBackpackPrompt = prompt
	holdingE              = true
	backpackFrame.Visible = true
	ensureTapOverlays()

	-- Keep hotbar usable on mobile
	if isMobile() then
		setAllSlotHitAreasActive(true)
		setHotbarFrontForMobile(true)
	else
		setAllSlotHitAreasActive(false)
	end

	-- 5) (Re)start distance watchdog (disconnect any previous)
	if distanceConn then distanceConn:Disconnect() distanceConn = nil end
	distanceConn = RunService.RenderStepped:Connect(function()
		if not backpackFrame.Visible then return end
		local character = player.Character
		if not character or not character:FindFirstChild("HumanoidRootPart") then return end

		local playerPos = character.HumanoidRootPart.Position
		local packPos   = getPromptWorldPosition(prompt, item)

		if not packPos then
			-- If we truly can't resolve a position, don't auto-close
			return
		end

		if (playerPos - packPos).Magnitude > 10 then
			closeOverlayUI()
		end
	end)
end

local function closeOverlayAndMaybeAct(item, prompt)
	-- PC convenience: release over BotMid or Hover* regions
	local mouse    = player:GetMouse()
	local absPos   = backpackPickupButton.AbsolutePosition
	local absSize  = backpackPickupButton.AbsoluteSize
	local mousePos = Vector2.new(mouse.X, mouse.Y)
	local withinPickup =
		mousePos.X >= absPos.X and mousePos.X <= absPos.X + absSize.X and
		mousePos.Y >= absPos.Y and mousePos.Y <= absPos.Y + absSize.Y
	if withinPickup and not hasPickedUpBackpack then
		tryPickupBackpack()
	else
		for i, label in ipairs(backpackLabels) do
			local hPos, hSize = label.AbsolutePosition, label.AbsoluteSize
			if mousePos.X >= hPos.X and mousePos.X <= hPos.X + hSize.X and mousePos.Y >= hPos.Y and mousePos.Y <= hPos.Y + hSize.Y then
				actOnBackpackSlot(i); break
			end
		end
		closeOverlayUI()
		collapseBackpackSelection()
	end
end

local function handleBackpackUI(item, prompt)
	-- Open on hold begin
	prompt.PromptButtonHoldBegan:Connect(function(plr)
		if plr ~= player then return end
		if backpackFrame.Visible then return end
		openBackpackOverlay(item, prompt)
	end)

	-- Close/act on hold end
	prompt.PromptButtonHoldEnded:Connect(function(plr)
		if plr ~= player then return end
		if not backpackFrame.Visible then return end
		closeOverlayAndMaybeAct(item, prompt)
	end)

	-- Fallback: HoldDuration == 0 (Triggered immediately)
	prompt.Triggered:Connect(function(plr)
		if plr ~= player then return end
		if not backpackFrame.Visible then
			openBackpackOverlay(item, prompt)
		end
	end)

	-- DO NOT auto-close on PromptHidden (LOS flicker on slopes). Distance watchdog will handle.
	prompt.PromptHidden:Connect(function() end)

	-- Also allow E-release to close if opened via 0s hold
	UIS.InputEnded:Connect(function(input, gp)
		if not backpackFrame.Visible then return end
		if input.KeyCode == Enum.KeyCode.E then
			closeOverlayAndMaybeAct(item, prompt)
		end
	end)
end

BackpackInventoryUpdate.OnClientEvent:Connect(function(backpack, contents)
	-- If no overlay is open, nothing to refresh
	if not currentBackpackItem then return end

	-- Resolve real ID (late replication safe)
	local realIncomingID = getBackpackID(backpack)
	if not realIncomingID then return end

	-- If we opened with a temporary key, switch to the real ID once it arrives
	if currentOverlayKey ~= realIncomingID then
		currentOverlayKey = realIncomingID
		slotHasItem[currentOverlayKey]    = slotHasItem[currentOverlayKey] or {}
		originalColors[currentOverlayKey] = originalColors[currentOverlayKey] or {}
	end

	-- Paint fresh contents
	for i, slot in ipairs(backpackSlots) do
		local imageLabel = slot:FindFirstChild("ImageLabel")
		if imageLabel then imageLabel.Image=""; imageLabel.Visible=false end
		slotHasItem[currentOverlayKey][i] = false
		originalColors[currentOverlayKey][i] = slot.ImageColor3
	end
	for slotName, itemName in pairs(contents) do
		for i, slot in ipairs(backpackSlots) do
			if slot.Name == slotName then
				local imageLabel = slot:FindFirstChild("ImageLabel")
				if itemName and itemImageMap[itemName] then
					imageLabel.Image = itemImageMap[itemName]; imageLabel.Visible=true
					slot.ImageColor3 = Color3.new(1,1,1)
					slotHasItem[currentOverlayKey][i] = true
					originalColors[currentOverlayKey][i] = Color3.new(1,1,1)
				end
			end
		end
	end
	ensureTapOverlays()
end)

-- // Keybinds (equip + visuals)
UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.One then selectSlotVisual(1); EquipEvent:FireServer(1)
	elseif input.KeyCode == Enum.KeyCode.Two then selectSlotVisual(2); EquipEvent:FireServer(2)
	elseif input.KeyCode == Enum.KeyCode.Three then selectSlotVisual(3); EquipEvent:FireServer(3)
	elseif input.KeyCode == Enum.KeyCode.Four then selectSlotVisual(4); EquipEvent:FireServer(4)
	elseif input.KeyCode == Enum.KeyCode.Q then DropEvent:FireServer() end
end)

-- // World Equippables (ProximityPrompt) wiring
local function handleEquippableItem(item)
	local itemName = item:GetAttribute("ItemName")
	if not item:IsDescendantOf(workspace) or not CollectionService:HasTag(item, "Equippable") then return end
	local function waitForPrompt(it, timeout)
		local start = os.clock()
		while os.clock() - start < (timeout or 10) do
			if not it:IsDescendantOf(workspace) then task.wait(); continue end
			local prompt = it:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt then return prompt end
			task.wait(0.2)
		end
		return nil
	end
	local prompt = waitForPrompt(item)
	if prompt then
		if itemName == "Backpack" then
			handleBackpackUI(item, prompt)
		else
			prompt.Triggered:Connect(function(playerWhoTriggered)
				local canPickup = CanPickupItem:InvokeServer(itemName)
				local isHolding = IsHoldingItem:InvokeServer()
				if canPickup then PickupEvent:FireServer(itemName, item, false); startPendingSelection(itemName)
				elseif not isHolding then PickupEvent:FireServer(itemName, item, true); startPendingSelection(itemName)
				else warn("[DEBUG] Inventory full and already holding an item:", itemName) end
			end)
		end
	else
		warn("[DEBUG] No ProximityPrompt found on:", item, itemName)
	end
end

local function findEquippableAncestor(instance)
	local current = instance
	while current and current.Parent do
		if current:IsA("Model") and CollectionService:HasTag(current, "Equippable") then return current end
		current = current.Parent
	end
	return nil
end

local function processPrompt(prompt)
	local equippableModel = findEquippableAncestor(prompt.Parent)
	if equippableModel then
		local itemName = equippableModel:GetAttribute("ItemName") or equippableModel.Name
		if itemName == "Backpack" then
			handleBackpackUI(equippableModel, prompt)
		else
			prompt.Triggered:Connect(function(playerWhoTriggered)
				local canPickup = CanPickupItem:InvokeServer(itemName)
				local isHolding = IsHoldingItem:InvokeServer()
				if canPickup then PickupEvent:FireServer(itemName, equippableModel, false); startPendingSelection(itemName)
				elseif not isHolding then PickupEvent:FireServer(itemName, equippableModel, true); startPendingSelection(itemName)
				else warn("[DEBUG] Inventory full and already holding an item:", itemName) end
			end)
		end
	end
end

workspace.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("ProximityPrompt") then processPrompt(descendant) end
end)
for _, descendant in ipairs(workspace:GetDescendants()) do
	if descendant:IsA("ProximityPrompt") then processPrompt(descendant) end
end
task.delay(3, function() for _, item in pairs(workspace:GetDescendants()) do handleEquippableItem(item) end end)
CollectionService:GetInstanceAddedSignal("Equippable"):Connect(function(item) handleEquippableItem(item) end)

-- // Slot imagery updates (+ complete pending visual select on pickup)
updateSlotEvent.OnClientEvent:Connect(function(slotIndex, itemName, isDropping)
	local slotFrames = getSlotFrames(); local frame = slotFrames[slotIndex]
	if isDropping then slotContents[slotIndex] = nil else slotContents[slotIndex] = itemName end
	if isDropping then
		if slotIndex >= 1 and slotIndex <= 3 and selectedMainIndex == slotIndex then
			shrinkVisual(slotIndex)
			selectedMainIndex = nil
		elseif slotIndex == 4 and backpackSelected then
			shrinkVisual(4)
			backpackSelected = false
		end
	end
	if frame then
		local wrapper = frame:FindFirstChild("ScaleWrapper"); local searchParent = wrapper or frame
		local imageLabel = searchParent:FindFirstChild("ImageLabel")
		if imageLabel then
			if isDropping then
				if itemImageMap[itemName] then imageLabel.Visible=false
				elseif slotIndex == 4 then imageLabel.ImageColor3 = Color3.new(0,0,0); imageLabel.ImageTransparency=0.5 end
			else
				if itemImageMap[itemName] then imageLabel.Image=itemImageMap[itemName]; imageLabel.Visible=true
				elseif slotIndex == 4 then imageLabel.ImageColor3 = Color3.new(1,1,1); imageLabel.ImageTransparency=0 end
			end
		else
			warn("[DEBUG] No ImageLabel found in slot frame:", frame.Name)
		end
	else
		warn("[DEBUG] Invalid slot index for inventory UI:", slotIndex)
	end
	if not isDropping and pendingSelectItemName and itemName == pendingSelectItemName then
		pendingSelectItemName=nil; ensureSelectedVisual(slotIndex)
	end
end)

-- // Visual-only equip sync from server (ignore while backpack overlay is open)
local function isBackpackOverlayOpen() return backpackFrame and backpackFrame.Visible end
if EquipVisualSelect then
	EquipVisualSelect.OnClientEvent:Connect(function(i)
		if isBackpackOverlayOpen() then return end
		if i == nil then
			if selectedMainIndex then shrinkVisual(selectedMainIndex); selectedMainIndex=nil end
			if backpackSelected then shrinkVisual(4); backpackSelected=false end
		else ensureSelectedVisual(i) end
	end)
else
	warn("[InventoryClient] EquipVisualSelect missing; visual sync disabled")
end
