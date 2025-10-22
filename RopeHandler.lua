-- RopeHandler.client.lua 

-- [ SERVICES ]
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")

local ForceStopClimb     = ReplicatedStorage:WaitForChild("ForceStopClimb")
local RequestLatchRope   = ReplicatedStorage:WaitForChild("RequestLatchRope")
local RequestDetachRope  = ReplicatedStorage:WaitForChild("RequestDetachRope")
local ClimbRopeMovement  = ReplicatedStorage:WaitForChild("ClimbRopeMovement")
local RopeSegmentsUpdate = ReplicatedStorage:WaitForChild("RopeSegmentsUpdate")

-- Mobile PLACE button bindable (create if absent so handler always has it)
local PlaceRopeNow = ReplicatedStorage:FindFirstChild("PlaceRopeNow")
if not PlaceRopeNow then
	PlaceRopeNow = Instance.new("BindableEvent")
	PlaceRopeNow.Name = "PlaceRopeNow"
	PlaceRopeNow.Parent = ReplicatedStorage
end

-- [ PLAYER ]
local player   = Players.LocalPlayer
local mouse    = player:GetMouse()
local camera   = workspace.CurrentCamera

-- Detect pure touch device — prevents mouse click placement on phones/tablets
local isTouchDevice = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- [ CONSTANTS ]
local toolName        = "Rope"
local toolName2       = "RopeCannon"
local previewTemplate = ReplicatedStorage:WaitForChild("RopePreview")
local finalRope       = ReplicatedStorage:WaitForChild("Rope")

local MAX_DISTANCE_MAP = {
	Rope       = 10,
	RopeCannon = 100,
}

local climbSpeed    = 30
local lastSent      = 0
local SEND_INTERVAL = 0.05

-- Mobile climb intent tuning
local MOBILE_DEADZONE  = 0.25 -- thumbstick deadzone magnitude for up/down intent

-- [ VALIDATION CONSTANTS ]
local MIN_VERTICAL_DELTA    = -0.5
local WALL_NORMAL_THRESHOLD = 0.4
local TOP_OFFSET            = 0.1
local DOWNCAST_LENGTH       = 5

-- [ STATE ]
local preview = nil
local updateConnection = nil
local clickConnection  = nil
local placeConnection  = nil
local activeTool       = nil

-- NEW (mobile aim): track last touch position & connections
local mobileAimPos = nil
local activeTouchId = nil
local touchTapConn, touchBeganConn, touchMovedConn, touchEndedConn = nil, nil, nil, nil

local InventoryHandler = require(ReplicatedStorage:WaitForChild("InventoryHandler"))

local character        = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
local humanoid         = character:WaitForChild("Humanoid")

local climbingOnRope = false
local currentRope    = nil
local ropeSegments   = {}
local currentSegmentIndex = 1
local movingUp, movingDown = false, false
local playerClones   = {}

-- Mobile DETACH UI
local detachGui, btnDetach

-- [ ROPE CLIMB ANIMATION ]
local climbAnimId    = "rbxassetid://120484211656915"
local climbAnimTrack = nil

local function playClimbAnim()
	if climbAnimTrack then
		climbAnimTrack:Stop()
		climbAnimTrack:Destroy()
		climbAnimTrack = nil
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = climbAnimId
	climbAnimTrack = humanoid:LoadAnimation(anim)
	climbAnimTrack.Looped = true
	climbAnimTrack:Play()
end

local function stopClimbAnim()
	if climbAnimTrack then
		climbAnimTrack:Stop()
		climbAnimTrack:Destroy()
		climbAnimTrack = nil
	end
end

local function setClimbAnimSpeed(speed)
	if climbAnimTrack then
		climbAnimTrack:AdjustSpeed(speed)
	end
end

humanoid.Died:Connect(stopClimbAnim)

-- ===================== HRP HIDE FIX (strong, sticky) =====================
local hrpLockConns = {}

local function disconnectHRPLocks()
	for _, c in ipairs(hrpLockConns) do
		if c then c:Disconnect() end
	end
	table.clear(hrpLockConns)
end

local function forceHideHRP(hrp: BasePart?)
	if not hrp then return end
	hrp.CanCollide = false
	hrp.CastShadow = false
	hrp.Transparency = 1
	hrp.LocalTransparencyModifier = 1
end

local function lockHideHRP(char: Model)
	disconnectHRPLocks()

	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then return end

	-- Apply immediately
	forceHideHRP(hrp)

	-- Re-apply whenever someone tampers
	table.insert(hrpLockConns, hrp:GetPropertyChangedSignal("Transparency"):Connect(function()
		if hrp.Transparency ~= 1 then hrp.Transparency = 1 end
	end))
	table.insert(hrpLockConns, hrp:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
		if hrp.LocalTransparencyModifier ~= 1 then hrp.LocalTransparencyModifier = 1 end
	end))
	table.insert(hrpLockConns, hrp:GetPropertyChangedSignal("CanCollide"):Connect(function()
		if hrp.CanCollide ~= false then hrp.CanCollide = false end
	end))
	table.insert(hrpLockConns, hrp:GetPropertyChangedSignal("CastShadow"):Connect(function()
		if hrp.CastShadow ~= false then hrp.CastShadow = false end
	end))

	-- If HRP gets replaced (rare but can happen), rebind
	table.insert(hrpLockConns, char.ChildAdded:Connect(function(child)
		if child.Name == "HumanoidRootPart" and child:IsA("BasePart") then
			lockHideHRP(char)
		end
	end))
end
-- =========================================================================

-- ===================== Preview helpers (color/aim/validation) =====================
local function updatePreviewColor(isValid)
	if not preview then return end
	local color = isValid and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0)
	for _, part in ipairs(preview:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "Brick" then
			part.Color = color
			part.Transparency = 0.4
		end
	end
end

-- PC uses mouse; Mobile uses LAST TOUCH (fallback: screen center until first touch)
local function getScreenPoint()
	if not isTouchDevice then
		local p = UserInputService:GetMouseLocation()
		return Vector2.new(p.X, p.Y)
	else
		if mobileAimPos then return mobileAimPos end
		local vps = camera and camera.ViewportSize or Vector2.new(1920,1080)
		return Vector2.new(vps.X * 0.5, vps.Y * 0.5)
	end
end

local function isStrictPlacementAllowed(result)
	if not result or not result.Instance or not result.Instance.CanCollide then
		return false
	end

	local surfacePos = result.Position
	local normal     = result.Normal

	-- reject horizontal-ish surfaces (floors/slopes)
	if normal.Y > WALL_NORMAL_THRESHOLD then
		return false
	end

	-- reject if below current player height
	local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	if surfacePos.Y < rootPart.Position.Y + MIN_VERTICAL_DELTA then
		return false
	end

	-- ensure solid geometry under the rope top
	local halfHeight = preview.PrimaryPart.Size.Y / 2
	local offset     = normal * (halfHeight + TOP_OFFSET)
	local topPoint   = surfacePos + offset
	local downParams = RaycastParams.new()
	downParams.FilterType = Enum.RaycastFilterType.Exclude
	downParams.FilterDescendantsInstances = {player.Character, preview}
	local downHit = workspace:Raycast(topPoint + Vector3.new(0,0.1,0), Vector3.new(0, -DOWNCAST_LENGTH, 0), downParams)
	if not downHit then
		return false
	end

	return true
end

local function computeVisibleCFrameFromResult(result)
	local surfacePos = result.Position
	local normal     = result.Normal
	local orientation
	if math.abs(normal.Y) < 0.7 then
		orientation = CFrame.lookAt(surfacePos, surfacePos + normal, Vector3.new(0,1,0))
	else
		orientation = CFrame.new(surfacePos)
	end
	local halfHeight = preview.PrimaryPart.Size.Y / 2
	local offset     = normal * (halfHeight + TOP_OFFSET)
	local visiblePos = surfacePos + offset
	return CFrame.new(visiblePos, visiblePos + orientation.LookVector)
end

-- Raycast from our chosen screen point
local function raycastFromScreenPoint(ignoreList, dist)
	local sp = getScreenPoint()
	local ray = camera:ViewportPointToRay(sp.X, sp.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList
	return workspace:Raycast(ray.Origin, ray.Direction * (dist or 200), params)
end

-- ===================== Placement attempt (PC click or Mobile button) =====================
local function attemptPlace(tool)
	if not (tool and preview and preview.PrimaryPart) then return end

	local result = raycastFromScreenPoint({player.Character, preview}, 200)
	if result and isStrictPlacementAllowed(result) then
		local surfacePos = result.Position
		local normal     = result.Normal
		local halfHeight = preview.PrimaryPart.Size.Y / 2
		local offset     = normal * (halfHeight + TOP_OFFSET)
		local placementTop = surfacePos + offset

		local facingCF = CFrame.lookAt(surfacePos, surfacePos + normal, Vector3.new(0,1,0))
		local placementCFrame = CFrame.new(placementTop, placementTop + facingCF.LookVector)

		preview:SetPrimaryPartCFrame(placementCFrame)

		local removeItemEvent = ReplicatedStorage:WaitForChild("RequestRemoveItem")
		local placeRopeEvent  = ReplicatedStorage:WaitForChild("PlaceRope")

		if tool.Name == toolName then
			removeItemEvent:FireServer(toolName)
			placeRopeEvent:FireServer(placementCFrame, toolName)
		else
			removeItemEvent:FireServer(toolName2)
			placeRopeEvent:FireServer(placementCFrame, toolName2)
		end
	end
end

-- ===================== Mobile aim handlers =====================
local function disconnectMobileAim()
	if touchTapConn   then touchTapConn:Disconnect();   touchTapConn   = nil end
	if touchBeganConn then touchBeganConn:Disconnect(); touchBeganConn = nil end
	if touchMovedConn then touchMovedConn:Disconnect(); touchMovedConn = nil end
	if touchEndedConn then touchEndedConn:Disconnect(); touchEndedConn = nil end
	activeTouchId = nil
end

local function attachMobileAim()
	disconnectMobileAim()

	-- Single tap updates aim (no placement)
	touchTapConn = UserInputService.TouchTap:Connect(function(touchPositions, processed)
		if processed then return end
		if touchPositions and touchPositions[1] then
			mobileAimPos = touchPositions[1]
		end
	end)

	-- Drag to aim
	touchBeganConn = UserInputService.InputBegan:Connect(function(io, processed)
		if processed then return end
		if io.UserInputType == Enum.UserInputType.Touch then
			activeTouchId = io.TouchId
			mobileAimPos  = io.Position
		end
	end)
	touchMovedConn = UserInputService.InputChanged:Connect(function(io, processed)
		if processed then return end
		if io.UserInputType == Enum.UserInputType.Touch and activeTouchId and io.TouchId == activeTouchId then
			mobileAimPos = io.Position
		end
	end)
	touchEndedConn = UserInputService.InputEnded:Connect(function(io, processed)
		if io.UserInputType == Enum.UserInputType.Touch and activeTouchId and io.TouchId == activeTouchId then
			activeTouchId = nil
			-- keep last mobileAimPos so preview stays where last touched
		end
	end)
end

local detachFromRope

-- === Mobile Detach Button (UI) ===
local function buildDetachUI()
	if detachGui then return end
	detachGui = Instance.new("ScreenGui")
	detachGui.Name = "RopeDetachUI"
	detachGui.ResetOnSpawn = false
	detachGui.IgnoreGuiInset = true
	detachGui.Enabled = false
	detachGui.Parent = player:WaitForChild("PlayerGui")

	btnDetach = Instance.new("TextButton")
	btnDetach.Name = "BtnDetach"
	btnDetach.Size = UDim2.fromOffset(86, 42)
	btnDetach.AnchorPoint = Vector2.new(1, 1)
	-- Bottom-right; tweak to fit your HUD
	btnDetach.Position = UDim2.new(1, -10, 1, -140)
	btnDetach.Text = "DETACH"
	btnDetach.TextScaled = true
	btnDetach.Font = Enum.Font.GothamBold
	btnDetach.TextColor3 = Color3.new(1, 1, 1)
	btnDetach.BackgroundColor3 = Color3.fromRGB(150, 45, 45)
	btnDetach.AutoButtonColor = true
	btnDetach.Parent = detachGui

	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 12); corner.Parent = btnDetach
	local stroke = Instance.new("UIStroke"); stroke.Thickness = 2; stroke.Color = Color3.fromRGB(255, 255, 255); stroke.Transparency = 0.25; stroke.Parent = btnDetach

	btnDetach.Activated:Connect(function()
		if climbingOnRope then
			detachFromRope()
		end
	end)
end

local function showDetachUI(show)
	-- Only show on touch devices
	if not UserInputService.TouchEnabled then return end
	buildDetachUI()
	detachGui.Enabled = show and true or false
end
-- === end Mobile Detach Button ===

-- ===================== Preview lifecycle =====================
local function stopPreview()
	if updateConnection then updateConnection:Disconnect() updateConnection = nil end
	if clickConnection  then clickConnection:Disconnect()  clickConnection  = nil end
	if placeConnection  then placeConnection:Disconnect()  placeConnection  = nil end
	if isTouchDevice    then disconnectMobileAim() end
	if preview then preview:Destroy() preview = nil end
	activeTool = nil
end

local function startPreview(tool)
	if preview then return end
	activeTool = tool

	preview = previewTemplate:Clone()
	assert(preview.PrimaryPart, "RopePreview must have a PrimaryPart")
	preview.Parent = workspace

	for _, part in ipairs(preview:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.Massless = true
		end
	end

	-- Move + color preview every frame
	updateConnection = RunService.RenderStepped:Connect(function()
		if not camera or not preview or not preview.PrimaryPart then return end
		local result = raycastFromScreenPoint({player.Character, preview}, 200)
		if result then
			local visibleCF = computeVisibleCFrameFromResult(result)
			preview:SetPrimaryPartCFrame(visibleCF)
			updatePreviewColor(isStrictPlacementAllowed(result))
		else
			preview:SetPrimaryPartCFrame(CFrame.new(0, -10000, 0))
			updatePreviewColor(false)
		end
	end)

	-- PC click to place (disabled on pure touch devices)
	if not isTouchDevice then
		clickConnection = mouse.Button1Down:Connect(function()
			attemptPlace(tool)
		end)
	end

	-- Mobile PLACE button -> place now
	placeConnection = PlaceRopeNow.Event:Connect(function()
		attemptPlace(tool)
	end)

	-- Mobile: track aim from touch
	if isTouchDevice then
		attachMobileAim()
	end

	tool.Unequipped:Connect(stopPreview)
	tool.AncestryChanged:Connect(function(_, parent)
		if not parent then stopPreview() end
	end)
	tool.Destroying:Connect(stopPreview)
end

-- Hook tools
local function hookTool(tool)
	if tool:IsA("Tool") and (tool.Name == toolName or tool.Name == toolName2) then
		if tool.Parent == player.Character then startPreview(tool) end
		tool.Equipped:Connect(function() startPreview(tool) end)
	end
end

-- [ CHARACTER & BACKPACK HANDLING ]
local function onCharacterAdded(char)
	character = char
	humanoidRootPart = character:WaitForChild("HumanoidRootPart")
	humanoid = character:WaitForChild("Humanoid")
	climbingOnRope = false
	currentRope = nil
	ropeSegments = {}
	currentSegmentIndex = 1

	-- HRP hide fix applied on spawn and enforced every frame
	lockHideHRP(character)

	task.wait(0.2)
	for _, item in ipairs(character:GetChildren()) do hookTool(item) end
	character.ChildAdded:Connect(hookTool)
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then onCharacterAdded(player.Character) end
local backpack = player:WaitForChild("Backpack")
backpack.ChildAdded:Connect(hookTool)
for _, tool in ipairs(backpack:GetChildren()) do hookTool(tool) end

-- ======================= Your existing rope climbing logic =======================
local function getOrderedRopeSegments(ropeModel)
	local segments = {}
	for _, part in ipairs(ropeModel:GetChildren()) do
		if part:IsA("BasePart") and part.Name == "RopeSegment" then
			table.insert(segments, part)
		end
	end
	table.sort(segments, function(a, b)
		return a.Position.Y < b.Position.Y -- Bottom to top
	end)
	return segments
end

detachFromRope = function()
	-- re-enable prompts (fix precedence)
	for _, prompt in ipairs(workspace:GetDescendants()) do
		if prompt:IsA("ProximityPrompt") and (prompt.Name == "PitonPrompt" or prompt.Name == "RopePrompt") then
			prompt.Enabled = true
		end
	end

	ClimbRopeMovement:FireServer("StopClimbing")
	stopClimbAnim()

	local ropeFlag = character:FindFirstChild("RopeClimbingActive")
	if ropeFlag then
		ropeFlag.Value = false
	end

	if currentRope then
		for _, part in ipairs(currentRope:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "Top" then
				part.CanCollide = true
				part.Anchored = false
			end
		end
	end

	if not climbingOnRope then
		showDetachUI(false)
		return
	end

	climbingOnRope = false
	currentRope = nil
	ropeSegments = {}
	currentSegmentIndex = 1
	humanoid.PlatformStand = false
	humanoidRootPart.Anchored = false

	-- Keep HRP hidden on detach too
	lockHideHRP(character)
	-- hide mobile DETACH
	showDetachUI(false)
end

local function latchToRope(ropePart)
	local char = player.Character
	local pitonFlag = char:FindFirstChild("PitonClimbingActive")
	if not char or (pitonFlag and pitonFlag.Value == true) then return end

	-- disable prompts while climbing
	for _, prompt in ipairs(workspace:GetDescendants()) do
		if prompt:IsA("ProximityPrompt") and (prompt.Name == "PitonPrompt" or prompt.Name == "RopePrompt") then
			prompt.Enabled = false
		end
	end

	ClimbRopeMovement:FireServer("StartClimbing")

	local ropeFlag = character:FindFirstChild("RopeClimbingActive")
	if not ropeFlag then
		ropeFlag = Instance.new("BoolValue")
		ropeFlag.Name = "RopeClimbingActive"
		ropeFlag.Parent = character
	end
	ropeFlag.Value = true

	if climbingOnRope then return end
	climbingOnRope = true
	currentRope = ropePart.Parent or ropePart
	ropeSegments = getOrderedRopeSegments(currentRope)

	if #ropeSegments == 0 then
		warn("No segments on rope.")
		return
	end

	-- Find closest segment
	local closestIndex, closestDist = 1, math.huge
	local pos = humanoidRootPart.Position
	for i, segment in ipairs(ropeSegments) do
		local dist = (segment.Position - pos).Magnitude
		if dist < closestDist then
			closestDist = dist
			closestIndex = i
		end
	end
	currentSegmentIndex = closestIndex

	for _, part in ipairs(currentRope:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Anchored = true
		end
	end

	ForceStopClimb:Fire()
	playClimbAnim()
	setClimbAnimSpeed(0)

	task.delay(0.05, function()
		local seg = ropeSegments[currentSegmentIndex]
		local newPos = Vector3.new(seg.Position.X, humanoidRootPart.Position.Y, seg.Position.Z)

		local dir
		if currentSegmentIndex < #ropeSegments then
			dir = (ropeSegments[currentSegmentIndex + 1].Position - seg.Position).Unit
		elseif currentSegmentIndex > 1 then
			dir = (seg.Position - ropeSegments[currentSegmentIndex - 1].Position).Unit
		else
			dir = Vector3.new(0, 1, 0)
		end

		humanoidRootPart.CFrame = CFrame.lookAt(newPos, newPos + dir, Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(-90), 0, 0)
		humanoid.PlatformStand = true
		humanoidRootPart.Anchored = true

		-- Keep HRP hidden while on rope
		lockHideHRP(character)
	end)

	-- Show mobile DETACH while latched
	showDetachUI(true)
end

-- Convert mobile MoveDirection into up/down climb intent
local function updateMobileClimbIntent()
	if not (UserInputService.TouchEnabled and climbingOnRope) then
		return
	end

	-- Use the player's current MoveDirection relative to camera forward
	local md = humanoid.MoveDirection
	if md.Magnitude < MOBILE_DEADZONE then
		movingUp, movingDown = false, false
		return
	end

	local forward = (camera and camera.CFrame.LookVector) or Vector3.new(0, 0, -1)
	local dot = md.Unit:Dot(forward)  -- forward positive, backward negative
	movingUp  = (dot >  MOBILE_DEADZONE)
	movingDown = (dot < -MOBILE_DEADZONE)
end

-- [ INPUT HANDLING ] (climbing)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if climbingOnRope then
		if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
			movingUp = true
		elseif input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.Down then
			movingDown = true
		elseif input.KeyCode == Enum.KeyCode.E then
			detachFromRope()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
		movingUp = false
	elseif input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.Down then
		movingDown = false
	end
end)

-- Remote-driven clone broadcasting (unchanged from your version)
ClimbRopeMovement.OnClientEvent:Connect(function(action, data)
	if action == "BroadcastPosition" then
		if data.userId == player.UserId then return end

		local otherPlayer = Players:GetPlayerByUserId(data.userId)
		if not otherPlayer or not otherPlayer.Character then return end

		-- Create clone if needed and hide real character
		if not playerClones[otherPlayer.UserId] then
			otherPlayer.Character.Archivable = true
			for _, inst in ipairs(otherPlayer.Character:GetDescendants()) do
				inst.Archivable = true
			end
			local ok, clone = pcall(function() return otherPlayer.Character:Clone() end)
			if ok and clone then
				clone.Name = "ClimbingClone_" .. otherPlayer.Name
				clone.Parent = workspace
				playerClones[otherPlayer.UserId] = clone

				local humanoidClone = clone:FindFirstChildOfClass("Humanoid")
				if humanoidClone then
					local animator = humanoidClone:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoidClone)
					local anim = Instance.new("Animation"); anim.AnimationId = climbAnimId
					local track = animator:LoadAnimation(anim)
					track.Looped = true
					track:Play()
				end

				local root = clone:FindFirstChild("HumanoidRootPart")
				if root then
					clone.PrimaryPart = root
					root.Anchored = true
					root.Transparency = 1
				end
				for _, part in ipairs(clone:GetDescendants()) do
					if part:IsA("BasePart") and part ~= clone.PrimaryPart then
						part.Anchored = false
						part.CanCollide = false
					end
				end
			end
			-- hide real character
			for _, part in ipairs(otherPlayer.Character:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					part.LocalTransparencyModifier = 1
					part.Transparency = 1
				elseif part:IsA("Decal") or part:IsA("BillboardGui") then
					part.Enabled = false
				end
			end
		end

		local clone = playerClones[otherPlayer.UserId]
		if clone and clone.PrimaryPart then
			clone:SetPrimaryPartCFrame(data.cframe)
		end

	elseif action == "StopClimbingFor" then
		local userId = data
		local clone = playerClones[userId]
		local otherPlayer = Players:GetPlayerByUserId(userId)

		if userId == player.UserId then
			return
		end
		
		if clone then
			local targetCF = clone.PrimaryPart and clone.PrimaryPart.CFrame
			if otherPlayer and otherPlayer.Character and otherPlayer.Character.PrimaryPart and targetCF then
				otherPlayer.Character:SetPrimaryPartCFrame(targetCF)
			end
			if clone:FindFirstChild("HumanoidRootPart") then
				clone.HumanoidRootPart:Destroy()
			end
			clone:Destroy()
			playerClones[userId] = nil
		end
		-- unhide real character
		if otherPlayer and otherPlayer.Character then
			for _, part in ipairs(otherPlayer.Character:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					part.LocalTransparencyModifier = 0
					part.Transparency = 0
				elseif part:IsA("Decal") or part:IsA("BillboardGui") then
					part.Enabled = true
				end
			end
		end
	end
end)

-- Climbing simulation tick
RunService.RenderStepped:Connect(function(dt)
	-- NEW: update thumbstick → climb intent for mobile
	updateMobileClimbIntent()

	if not climbingOnRope then return end

	local pos = humanoidRootPart.Position
	local isMoving = false

	if movingUp and currentSegmentIndex < #ropeSegments then
		isMoving = true
		local nextSeg = ropeSegments[currentSegmentIndex + 1]
		local dir = (nextSeg.Position - pos).Unit
		local dist = (nextSeg.Position - pos).Magnitude
		local moveDist = climbSpeed * dt
		if moveDist >= dist then
			currentSegmentIndex += 1
			local target = nextSeg.Position
			humanoidRootPart.CFrame = CFrame.lookAt(target, target + dir, Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(-90), 0, 0)
		else
			local newPos = pos + dir * moveDist
			humanoidRootPart.CFrame = CFrame.lookAt(newPos, newPos + dir, Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(-90), 0, 0)
		end
	elseif movingDown and currentSegmentIndex > 1 then
		isMoving = true
		local prevSeg = ropeSegments[currentSegmentIndex - 1]
		local dir = (prevSeg.Position - pos).Unit
		local dist = (prevSeg.Position - pos).Magnitude
		local moveDist = climbSpeed * dt
		if moveDist >= dist then
			currentSegmentIndex -= 1
			local target = prevSeg.Position
			humanoidRootPart.CFrame = CFrame.lookAt(target, target + dir, Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(90), math.rad(180), 0)
		else
			local newPos = pos + dir * moveDist
			humanoidRootPart.CFrame = CFrame.lookAt(newPos, newPos + dir, Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(90), math.rad(180), 0)
		end
	end

	if isMoving then
		ClimbRopeMovement:FireServer("UpdatePosition", humanoidRootPart.CFrame)
	end

	if climbAnimTrack then
		climbAnimTrack:AdjustSpeed(isMoving and 1 or 0)
	end
end)

-- [ PROXIMITY PROMPTS ]
local function addPromptsToRope(ropeModel)
	for _, part in ipairs(ropeModel:GetDescendants()) do
		if part:IsA("BasePart") then
			if not part:FindFirstChildOfClass("ProximityPrompt") then
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Climb Rope"
				prompt.ObjectText = "Rope"
				prompt.KeyboardKeyCode = Enum.KeyCode.E
				prompt.HoldDuration = 0
				prompt.MaxActivationDistance = 8
				prompt.RequiresLineOfSight = false
				prompt.Name = "RopePrompt"
				prompt.Parent = part

				prompt.Triggered:Connect(function(triggeringPlayer)
					if triggeringPlayer == player then
						if climbingOnRope then
							detachFromRope()
						else
							latchToRope(part)
						end
					end
				end)
			end
		end
	end
end

local function addPromptsToAllRopes()
	for _, rope in ipairs(workspace:GetChildren()) do
		if rope.Name == "Rope" then
			addPromptsToRope(rope)
		end
	end
end

workspace.ChildAdded:Connect(function(child)
	if child.Name == "Rope" then
		addPromptsToRope(child)
	end
end)

addPromptsToAllRopes()
