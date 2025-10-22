--=============================================================
--  Climber v4.0
--  • PC: Hold LMB to arm. Latch only when in range (no teleport).
--  • On latch: tiny one-shot upward nudge (seamless). NO auto climb.
--  • Jump = Lunge (up/side), with freeze-direction camera.
--  • Stamina: EXTERNAL AUTHORITY. This script never changes stamina;
--    it only sets flags: ClimbingActive / IsLunging.
--=============================================================

------------------------------ Services ------------------------
local Players            = game:GetService("Players")
local player             = Players.LocalPlayer
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ForceStopClimb     = ReplicatedStorage:WaitForChild("ForceStopClimb")
local SoundFolder        = ReplicatedStorage:WaitForChild("ItemUseSounds")
local DetachFromPitonEvent = ReplicatedStorage:WaitForChild("DetachFromPiton")

------------------------------ Config --------------------------
-- External stamina authority toggle (keeps UI smooth, avoids jitter)
local STAMINA_MANAGED_EXTERNALLY = true

local MAX_STAMINA            = 100
local CLIMB_TAG              = "Climbable"
local MIN_STAMINA_TO_CLIMB   = 0     -- only used as a gate (READ-ONLY)

-- (kept for compatibility; only used when STAMINA_MANAGED_EXTERNALLY=false)
local CLIMB_START_COST       = 2
local CLIMB_DRAIN_PER_SEC    = 6
local LOW_STAMINA_COOLDOWN   = 0.3

-- Collision safety
local WALL_CLEARANCE         = 2.2
local CEILING_CLEARANCE      = 2.6
local PULL_OUT_PROBE         = 6

-- Lunge tuning
local LUNGE_UP_DIST          = 8
local LUNGE_SIDE_DIST        = 8
local LUNGE_TIME             = 0.32
local LUNGE_EASING_STYLE     = Enum.EasingStyle.Sine
local LUNGE_EASING_DIR       = Enum.EasingDirection.Out
local LUNGE_POST_HOLD        = 0.08

-- Camera & cling smoothness
local CLING_SMOOTH_K         = 12.0
local POST_LUNGE_SMOOTH_TIME = 0.15
local MICRO_TWEEN_TIME       = 0.06

-- Freeze-camera blend timings
local CAM_IN_RAMP            = 0.05
local CAM_OUT_RAMP           = 0.05
local CAM_TRANSLATE_TIME     = 0.10

-- Climb movement tuning
local BASE_CLIMB_SPEED       = 7
local BASE_SIDE_SPEED        = 8

-- Controller deadzone
local GP_DEADZONE            = 0.25

-- Input styles
local PC_HOLD_TO_ARM         = true

-- Seamless latch nudge (one-shot, not auto-up)
local ENTRY_NUDGE_UP         = 1.15   -- studs
local ENTRY_NUDGE_TIME       = 0.12   -- seconds

-- Animations
local ANIM_IDS = {
	R6 = { UP="rbxassetid://110407001635344", DOWN="rbxassetid://110407001635344",
		LEFT="rbxassetid://110407001635344", RIGHT="rbxassetid://110407001635344",
		IDLE="rbxassetid://75966194863867", LUNGE="rbxassetid://101618269573413" },
	R15= { UP="rbxassetid://110407001635344", DOWN="rbxassetid://110407001635344",
		LEFT="rbxassetid://110407001635344", RIGHT="rbxassetid://110407001635344",
		IDLE="rbxassetid://75966194863867", LUNGE="rbxassetid://101618269573413" }
}

--------------------------- Helper values ----------------------
local character        = player.Character or player.CharacterAdded:Wait()
local multVal          = character:FindFirstChild("ClimbSpeedMultiplier")
local climbMultiplier  = multVal and multVal.Value or 1

local CLIMB_SPEED      = BASE_CLIMB_SPEED * climbMultiplier
local SIDE_SPEED       = BASE_SIDE_SPEED  * climbMultiplier

local climbSound       = nil
local lmbHeld          = false        -- PC arm flag
local pcClimbArmed     = false

local pitonReleaseCooldownUntil = 0
local lowStaminaCooldownUntil   = 0

------------------------------ Sounds --------------------------
local function playClimbSound()
	local char = player.Character; if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head"); if not root then return end
	if climbSound and climbSound.Parent == root then
		if not climbSound.IsPlaying then climbSound:Play() end
		return
	end
	local soundTemplate = SoundFolder:FindFirstChild("ClimbSound")
	if not soundTemplate then warn("ClimbSound not found in SoundFolder"); return end
	climbSound = soundTemplate:Clone(); climbSound.Looped = true; climbSound.Parent = root; climbSound:Play()
end

local function stopClimbSound()
	if climbSound then
		climbSound:Stop(); if climbSound.Parent then climbSound:Destroy() end
		climbSound = nil
	end
end

------------------------------ Utils ---------------------------
local function getTotalStamina(char)
	local main  = char:FindFirstChild("Stamina")
	local bonus = char:FindFirstChild("BonusStamina")
	return (main and main.Value or 0) + (bonus and bonus.Value or 0)
end

local function isClimbable(part)
	return CollectionService:HasTag(part, CLIMB_TAG) or part:IsA("Terrain")
end

local function makeRayParams(char)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {char}
	params.FilterType = Enum.RaycastFilterType.Exclude
	return params
end

local function wallRaycast(char, dist)
	local root = char:FindFirstChild("HumanoidRootPart"); if not root then return nil end
	local res = workspace:Raycast(root.Position, root.CFrame.LookVector * dist, makeRayParams(char))
	return (res and isClimbable(res.Instance)) and res or nil
end

local function standUpright(root)
	local pos, look = root.Position, root.CFrame.LookVector
	root.CFrame      = CFrame.lookAt(pos, pos + Vector3.new(look.X,0,look.Z), Vector3.new(0,1,0))
	root.RotVelocity = Vector3.new()
end

local function getRig(char)
	local h = char:FindFirstChildOfClass("Humanoid")
	return (h and h.RigType == Enum.HumanoidRigType.R15) and "R15" or "R6"
end

local function ceilingLimitedOffset(char, root, offset)
	if offset.Y <= 0 then return offset end
	local up = Vector3.new(0,1,0)
	local castDist = offset.Y + CEILING_CLEARANCE
	local hit = workspace:Raycast(root.Position, up * castDist, makeRayParams(char))
	if hit then
		local allowed = math.max(0, hit.Distance - CEILING_CLEARANCE)
		if allowed < offset.Y then offset = Vector3.new(offset.X, allowed, offset.Z) end
	end
	return offset
end

local function microTweenRootCF(root, toCF, timeSec)
	local tw = TweenService:Create(root, TweenInfo.new(timeSec, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {CFrame = toCF})
	tw:Play(); tw.Completed:Wait()
end

local function pullOutFromWall(char, root, lastNormal)
	if not lastNormal then return nil end
	local probeStart = root.Position + lastNormal * PULL_OUT_PROBE
	local cast = workspace:Raycast(probeStart, -lastNormal * (PULL_OUT_PROBE*2), makeRayParams(char))
	if cast and isClimbable(cast.Instance) then
		local safeCF = CFrame.lookAt(cast.Position + cast.Normal * WALL_CLEARANCE, cast.Position, Vector3.new(0,1,0))
		if (safeCF.Position - root.CFrame.Position).Magnitude > 0.05 then
			microTweenRootCF(root, safeCF, MICRO_TWEEN_TIME)
		end
		return cast
	end
	return nil
end

--------------------------- Anim cache -------------------------
local animCache = {}
local function animatorOf(h) return h:FindFirstChildOfClass("Animator") or h end
local function loadAnim(h,id)
	animCache[h] = animCache[h] or {}
	if animCache[h][id] then return animCache[h][id] end
	local a = Instance.new("Animation"); a.AnimationId = id
	local t = animatorOf(h):LoadAnimation(a); t.Priority = Enum.AnimationPriority.Action
	animCache[h][id] = t; return t
end
local function playAnim(h,id,force)
	if not id or id=="" then return end
	animCache[h] = animCache[h] or {}
	for k,t in pairs(animCache[h]) do if k~=id and t.IsPlaying then t:Stop() end end
	local tr = loadAnim(h,id); if tr and (force or not tr.IsPlaying) then tr.Looped=true; tr:Play() end
end
local function stopAnims(h) if animCache[h] then for _,t in pairs(animCache[h]) do t:Stop() end end end

------------------------------ State ---------------------------
local climbing, lungeActive, canLunge = false, false, true
local justLungedUntil, lastWallNormal = 0, nil
local targetCF = {value=nil}

-- Keyboard flags
local mUp,mDn,mLt,mRt = false,false,false,false

local suppressLerpUntil = 0
local postLungeSmoothUntil = 0

-- Mobile toggle (touch UI only)
local climbArmed = false
local MobileUI
local BtnClimb

-- Controller: hold to climb (RT/RB)
local controllerHoldClimb = false

---------------------------- Flags -----------------------------
local function boolFlag(char,name)
	local v = char:FindFirstChild(name)
	if not v then v = Instance.new("BoolValue"); v.Name=name; v.Parent=char end
	return v
end
local function setClimb(val)
	climbing = val
	if player.Character then boolFlag(player.Character,"ClimbingActive").Value = val end
end
local function setLunge(val)
	lungeActive = val
	if player.Character then boolFlag(player.Character,"IsLunging").Value = val end
end

local function pitonActive(char)
	local f = char and char:FindFirstChild("PitonClimbingActive")
	return f and f.Value == true
end
local function ropeActive(char)
	local f = char and char:FindFirstChild("RopeClimbingActive")
	return f and f.Value == true
end

----------------------- Stop / Start climb ---------------------
local function stopClimbing()
	stopClimbSound()
	if not climbing then return end
	local char = player.Character; if not char then return end
	local h    = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if h and root then
		h.PlatformStand=false
		root.Anchored=false
		standUpright(root)
		local push,drop=10,-8
		if lastWallNormal then root.Velocity=lastWallNormal*push+Vector3.new(0,drop,0) else root.Velocity=Vector3.new(0,drop,0) end
		stopAnims(h)
	end
	setLunge(false); setClimb(false)
end
ForceStopClimb.Event:Connect(stopClimbing)

local function startClimbing()
	local char=player.Character
	if not char or climbing then return false end

	if pitonActive(char) then
		if DetachFromPitonEvent then pcall(function() DetachFromPitonEvent:Fire() end) end
		pitonReleaseCooldownUntil = tick() + 0.2
		return false
	end
	if ropeActive(char) then return false end
	if tick() < lowStaminaCooldownUntil then return false end

	-- READ-ONLY stamina gating (no writes from this script)
	if getTotalStamina(char) < MIN_STAMINA_TO_CLIMB then
		lowStaminaCooldownUntil = tick() + LOW_STAMINA_COOLDOWN
		return false
	end

	local root=char:FindFirstChild("HumanoidRootPart"); if not root then return false end
	local hit=wallRaycast(char,3); if not hit then return false end
	local h=char:FindFirstChildOfClass("Humanoid"); if not h then return false end

	-- Do NOT deduct start cost if externally managed
	if not STAMINA_MANAGED_EXTERNALLY then
		-- legacy path (kept for optional offline testing)
		local main = char:FindFirstChild("Stamina")
		if main then main.Value = math.max(0, main.Value - CLIMB_START_COST) end
	end

	playClimbSound()
	setClimb(true)
	h.PlatformStand=true; root.Anchored=true
	targetCF.value=CFrame.lookAt(hit.Position+hit.Normal*WALL_CLEARANCE, hit.Position, Vector3.new(0,1,0))
	lastWallNormal=hit.Normal
	playAnim(h,ANIM_IDS[getRig(char)].IDLE,true)
	setLunge(false)

	-- One-time seamless upward nudge (not auto-climb)
	if ENTRY_NUDGE_UP > 0 then
		local nudge = ceilingLimitedOffset(char, root, Vector3.new(0, ENTRY_NUDGE_UP, 0))
		if nudge.Magnitude > 0 then
			local toCF = root.CFrame + nudge
			local tw = TweenService:Create(root, TweenInfo.new(ENTRY_NUDGE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {CFrame = toCF})
			tw:Play(); tw.Completed:Wait()
		end
	end

	return true
end

-------------------------- Intents & Lunge ---------------------
local function currentIntents()
	-- Keyboard
	local kUp,kDn,kLt,kRt = mUp,mDn,mLt,mRt

	-- Mobile (camera-relative via MoveDirection)
	local tUp,tDn,tLt,tRt = false,false,false,false
	if UserInputService.TouchEnabled then
		local char=player.Character; if char then
			local h=char:FindFirstChildOfClass("Humanoid")
			if h then
				local mv = h.MoveDirection
				local cam = workspace.CurrentCamera
				local camLook = cam and cam.CFrame.LookVector or Vector3.new(0,0,-1)
				local fwd2D  = Vector3.new(camLook.X,0,camLook.Z); if fwd2D.Magnitude>0 then fwd2D=fwd2D.Unit end
				local rgt2D  = Vector3.new(-fwd2D.Z,0,fwd2D.X)
				local dpF = mv:Dot(fwd2D)
				local dpR = mv:Dot(rgt2D)
				local TH = 0.3
				tUp = dpF >  TH; tDn = dpF < -TH; tRt = dpR >  TH; tLt = dpR < -TH
			end
		end
	end

	-- Controller stick
	local cUp,cDn,cLt,cRt = false,false,false,false
	do
		local states = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
		for _, io in ipairs(states) do
			if io.KeyCode == Enum.KeyCode.Thumbstick1 then
				local x,y = io.Position.X, io.Position.Y
				local TH  = GP_DEADZONE
				if math.abs(x) > TH or math.abs(y) > TH then
					cUp =  y >  TH; cDn =  y < -TH; cRt = x >  TH; cLt = x < -TH
				end
			end
		end
	end

	local up    = kUp or tUp or cUp
	local down  = kDn or tDn or cDn
	local left  = kLt or tLt or cLt
	local right = kRt or tRt or cRt

	return up,down,left,right
end

-------------------- Freeze-direction camera lock ---------------
local camLockActive    = false
local camReleaseActive = false
local lockStartTime    = 0
local releaseEndTime   = 0
local camInfluence     = 0

local savedCamCF       = nil
local relOffset        = nil
local camSpringVel     = Vector3.new()
local lastCamInputTime = 0

UserInputService.InputChanged:Connect(function(io)
	if io.UserInputType == Enum.UserInputType.MouseMovement then
		if math.abs(io.Delta.X) > 0.01 or math.abs(io.Delta.Y) > 0.01 then lastCamInputTime = tick() end
	elseif io.UserInputType == Enum.UserInputType.Gamepad1 and io.KeyCode == Enum.KeyCode.Thumbstick2 then
		local p = io.Position
		if p and (math.abs(p.X) > 0.02 or math.abs(p.Y) > 0.02) then lastCamInputTime = tick() end
	elseif io.UserInputType == Enum.UserInputType.Touch then
		if io.Delta and (math.abs(io.Delta.X) > 0.01 or math.abs(io.Delta.Y) > 0.01) then lastCamInputTime = tick() end
	end
	if camLockActive and (tick() - lastCamInputTime) < 0.02 then
		camLockActive = false
		camReleaseActive = true
		releaseEndTime = tick() + CAM_OUT_RAMP
	end
end)

local function beginCameraLock(root)
	local cam = workspace.CurrentCamera
	if not cam then return end
	savedCamCF = cam.CFrame
	relOffset  = savedCamCF.Position - root.Position
	camSpringVel = Vector3.new()
	camInfluence  = 0
	lockStartTime = tick()
	camLockActive = true
	camReleaseActive = false
end

local function endCameraLock()
	if not camLockActive and not camReleaseActive then return end
	camLockActive = false
	camReleaseActive = true
	releaseEndTime = tick() + CAM_OUT_RAMP
end

-------------------------- Lunge action ------------------------
local function performLunge()
	if not climbing or not canLunge or not lastWallNormal then return end
	local char=player.Character
	local h=char and char:FindFirstChildOfClass("Humanoid")
	local root=char and char:FindFirstChild("HumanoidRootPart")
	if not (h and root) then return end

	local up,down,left,right = currentIntents()
	beginCameraLock(root)

	local offset = Vector3.new()
	if up then offset += Vector3.new(0, LUNGE_UP_DIST, 0) end
	local rightVec = root.CFrame.RightVector; rightVec = Vector3.new(rightVec.X,0,rightVec.Z).Unit
	if left  then offset -= rightVec * LUNGE_SIDE_DIST end
	if right then offset += rightVec * LUNGE_SIDE_DIST end
	if offset.Magnitude == 0 then offset = Vector3.new(0, LUNGE_UP_DIST, 0) end

	offset = ceilingLimitedOffset(char, root, offset)

	canLunge=false; setLunge(true)
	local rig = getRig(char)
	h.AutoRotate=false; h.PlatformStand=true
	root.Anchored=true; root.RotVelocity=Vector3.new()
	stopAnims(h)
	local tr=loadAnim(h,ANIM_IDS[rig].LUNGE); if tr then tr.Looped=false; tr:Play() end

	local targetCF_lunge = root.CFrame + offset
	local tw = TweenService:Create(root, TweenInfo.new(LUNGE_TIME, LUNGE_EASING_STYLE, LUNGE_EASING_DIR), {CFrame = targetCF_lunge})
	tw:Play(); tw.Completed:Wait()

	local cast = pullOutFromWall(char, root, lastWallNormal)
	local rehit = wallRaycast(char,3)
	if rehit then
		targetCF.value = CFrame.lookAt(rehit.Position + rehit.Normal * WALL_CLEARANCE, rehit.Position, Vector3.new(0,1,0))
		lastWallNormal = rehit.Normal
	elseif cast then
		targetCF.value = CFrame.lookAt(cast.Position + cast.Normal * WALL_CLEARANCE, cast.Position, Vector3.new(0,1,0))
		lastWallNormal = cast.Normal
	else
		targetCF.value = root.CFrame
	end

	local now = tick()
	suppressLerpUntil     = now + 0.05
	postLungeSmoothUntil  = now + POST_LUNGE_SMOOTH_TIME

	setLunge(false); setClimb(true)
	justLungedUntil = now + (0.2 + LUNGE_POST_HOLD)
	task.delay(0.35,function() canLunge=true end)
	h.AutoRotate=true

	endCameraLock()
end

-------------------- JumpRequest -> Lunge ----------------------
UserInputService.JumpRequest:Connect(function()
	if climbing then performLunge() end
end)

-------------------- InputBegan / InputEnded -------------------
UserInputService.InputBegan:Connect(function(inp,proc)
	if proc then return end

	-- PC: hold LMB = arm (no auto-up)
	if inp.UserInputType == Enum.UserInputType.MouseButton1 then
		if not UserInputService.TouchEnabled and PC_HOLD_TO_ARM then
			lmbHeld      = true
			pcClimbArmed = true
			local char = player.Character
			if pitonActive(char) then
				if DetachFromPitonEvent then pcall(function() DetachFromPitonEvent:Fire() end) end
				pitonReleaseCooldownUntil = tick() + 0.2
				pcClimbArmed = false
			elseif ropeActive(char) then
				pcClimbArmed = false
			end
		end
		return
	end

	-- PC WASD flags (only while climbing)
	if climbing then
		if     inp.KeyCode==Enum.KeyCode.W or inp.KeyCode==Enum.KeyCode.Up    then mUp=true
		elseif inp.KeyCode==Enum.KeyCode.S or inp.KeyCode==Enum.KeyCode.Down  then mDn=true
		elseif inp.KeyCode==Enum.KeyCode.A or inp.KeyCode==Enum.KeyCode.Left  then mLt=true
		elseif inp.KeyCode==Enum.KeyCode.D or inp.KeyCode==Enum.KeyCode.Right then mRt=true end
	end

	-- CONTROLLER — HOLD to arm (RT/RB), drop on B
	if inp.UserInputType == Enum.UserInputType.Gamepad1 then
		if inp.KeyCode == Enum.KeyCode.ButtonR2 or inp.KeyCode == Enum.KeyCode.ButtonR1 then
			controllerHoldClimb = true
			return
		end
		if inp.KeyCode == Enum.KeyCode.ButtonB then
			if climbing then stopClimbing() end
			return
		end
	end
end)

UserInputService.InputEnded:Connect(function(inp,proc)
	if proc then return end

	if inp.UserInputType == Enum.UserInputType.MouseButton1 then
		if not UserInputService.TouchEnabled and PC_HOLD_TO_ARM then
			lmbHeld      = false
			pcClimbArmed = false
			if climbing then stopClimbing() end
		end
		return
	end

	-- PC WASD releases
	if     inp.KeyCode==Enum.KeyCode.W or inp.KeyCode==Enum.KeyCode.Up    then mUp=false
	elseif inp.KeyCode==Enum.KeyCode.S or inp.KeyCode==Enum.KeyCode.Down  then mDn=false
	elseif inp.KeyCode==Enum.KeyCode.A or inp.KeyCode==Enum.KeyCode.Left  then mLt=false
	elseif inp.KeyCode==Enum.KeyCode.D or inp.KeyCode==Enum.KeyCode.Right then mRt=false end

	-- CONTROLLER unlatch on RT/RB release
	if inp.UserInputType == Enum.UserInputType.Gamepad1 then
		if inp.KeyCode == Enum.KeyCode.ButtonR2 or inp.KeyCode == Enum.KeyCode.ButtonR1 then
			controllerHoldClimb = false
			if climbing then stopClimbing() end
			return
		end
	end
end)

----------------------- Per-frame update (gameplay) ------------
RunService.RenderStepped:Connect(function(dt)
	local char=player.Character; if not char then return end
	local h=char:FindFirstChildOfClass("Humanoid")
	local root=char:FindFirstChild("HumanoidRootPart")
	if not h or not root then return end

	-- PC: while LMB-held (armed), start only when within normal grab range
	if PC_HOLD_TO_ARM and not UserInputService.TouchEnabled then
		if pcClimbArmed and not climbing and tick() >= pitonReleaseCooldownUntil then
			if not pitonActive(char) and not ropeActive(char) then
				-- READ-ONLY stamina check; no writes here.
				if getTotalStamina(char) >= MIN_STAMINA_TO_CLIMB then
					local hit = wallRaycast(char, 3)
					if hit then startClimbing() end
				end
			end
		end
	end

	-- TOUCH-ONLY: mobile toggle
	if UserInputService.TouchEnabled and climbArmed and not climbing and tick() >= pitonReleaseCooldownUntil then
		if not pitonActive(char) and not ropeActive(char) then
			local hit = wallRaycast(char, 3)
			if hit then startClimbing() end
		end
	end

	-- CONTROLLER: while RT/RB held, start when in range
	if controllerHoldClimb and not climbing and tick() >= pitonReleaseCooldownUntil then
		if not pitonActive(char) and not ropeActive(char) then
			if getTotalStamina(char) >= MIN_STAMINA_TO_CLIMB then
				local hit = wallRaycast(char, 3)
				if hit then startClimbing() end
			end
		end
	end

	-- DO NOT DRAIN STAMINA HERE (external authority)
	if not STAMINA_MANAGED_EXTERNALLY then
		if climbing then
			local main = char:FindFirstChild("Stamina")
			if main then main.Value = math.max(0, main.Value - CLIMB_DRAIN_PER_SEC * dt) end
			if getTotalStamina(char) <= 0 then
				lowStaminaCooldownUntil = tick() + LOW_STAMINA_COOLDOWN
				stopClimbing(); return
			end
		end
	else
		-- Optional: if stamina hits 0, drop (read-only; no writes)
		if climbing and getTotalStamina(char) <= 0 then
			lowStaminaCooldownUntil = tick() + LOW_STAMINA_COOLDOWN
			stopClimbing(); return
		end
	end

	-- Update while climbing
	if climbing and lungeActive then
		local res=wallRaycast(char,3); if res then lastWallNormal=res.Normal end
	elseif climbing then
		local hit=wallRaycast(char,3)
		if hit then
			targetCF.value=CFrame.lookAt(hit.Position + hit.Normal * WALL_CLEARANCE, hit.Position, Vector3.new(0,1,0))
			root.RotVelocity=Vector3.new(); lastWallNormal=hit.Normal
		end

		if targetCF.value and tick() >= suppressLerpUntil then
			local alpha = 1 - math.exp(-CLING_SMOOTH_K * dt)
			root.CFrame = root.CFrame:Lerp(targetCF.value, alpha)
		end

		local up,down,left,right = currentIntents()

		local vel=Vector3.new()
		local vUp=Vector3.new(0,1,0)
		local rgt=root.CFrame.RightVector; rgt=Vector3.new(rgt.X,0,rgt.Z).Unit
		local sideOnly=(left or right) and not (up or down)
		if up then vel+=vUp*CLIMB_SPEED end
		if down then vel-=vUp*CLIMB_SPEED end
		if left then vel-=rgt*SIDE_SPEED end
		if right then vel+=rgt*SIDE_SPEED end

		local rig=getRig(char)
		local anim=ANIM_IDS[rig].IDLE
		if up then anim=ANIM_IDS[rig].UP
		elseif down then anim=ANIM_IDS[rig].DOWN end
		if sideOnly then if left then anim=ANIM_IDS[rig].LEFT end; if right then anim=ANIM_IDS[rig].RIGHT end end
		playAnim(h,anim)

		local useKinematic = (tick() < postLungeSmoothUntil)
		if sideOnly or useKinematic then
			root.Anchored=true
			root.CFrame = root.CFrame + vel * dt
		else
			root.Anchored=false
			root.Velocity = (vel.Magnitude>0) and vel or Vector3.new()
			if vel.Magnitude==0 then root.Anchored=true end
		end

		-- If we drift off the wall and we're past the lunge hold, drop
		if not wallRaycast(char,3) and tick()>justLungedUntil then
			stopClimbing()
		end
	end
end)

----------------------------------------------------------------
-- CAMERA UPDATE (after Roblox camera): freeze orientation, translate only
----------------------------------------------------------------
local CAM_STEP_NAME = "Climb_FreezeLungeCamera"
RunService:UnbindFromRenderStep(CAM_STEP_NAME)

local function smoothDampVec3(current, target, velocity, smoothTime, dt, maxSpeed)
	smoothTime = math.max(0.0001, smoothTime)
	local omega = 2 / smoothTime
	local x = omega * dt
	local exp = 1 / (1 + x + 0.48*x*x + 0.235*x*x*x)
	local change = current - target
	local maxChange = (maxSpeed or 1e8) * smoothTime
	local mag = change.Magnitude
	if mag > maxChange then change = change * (maxChange / mag) end
	local temp = (velocity + change * omega) * dt
	local newVel = (velocity - temp * omega) * exp
	local newPos = target + (change + temp) * exp
	return newPos, newVel
end

local camLockActive    = false
local camReleaseActive = false
local lockStartTime    = 0
local releaseEndTime   = 0
local camInfluence     = 0
local savedCamCF       = nil
local relOffset        = nil
local camSpringVel     = Vector3.new()
local lastCamInputTime = 0

local function cameraStep(dt)
	local cam = workspace.CurrentCamera
	local char = player.Character
	if not cam or not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	if not camLockActive and not camReleaseActive then return end

	-- Influence ramp
	if camLockActive then
		local t = math.clamp((tick() - lockStartTime) / CAM_IN_RAMP, 0, 1)
		camInfluence = (t < 1) and (1 - (1 - t)^3) or 1
	else
		local remain = releaseEndTime - tick()
		if remain <= 0 then
			camReleaseActive = false
			camInfluence = 0
			return
		else
			camInfluence = math.max(0, math.min(camInfluence, remain / CAM_OUT_RAMP))
		end
	end

	-- Keep original view direction; only translate with the character
	local targetPos = root.Position + (relOffset or Vector3.new(0,0,0))
	local newPos; newPos, camSpringVel = smoothDampVec3(cam.CFrame.Position, targetPos, camSpringVel, CAM_TRANSLATE_TIME, dt, 1e8)
	local ourCF = CFrame.lookAt(newPos, newPos + (savedCamCF and savedCamCF.LookVector or cam.CFrame.LookVector), savedCamCF and savedCamCF.UpVector or Vector3.new(0,1,0))

	-- Blend
	cam.CFrame = cam.CFrame:Lerp(ourCF, camInfluence)
end

RunService:BindToRenderStep(CAM_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, cameraStep)
script.Destroying:Connect(function()
	pcall(function() RunService:UnbindFromRenderStep(CAM_STEP_NAME) end)
end)

-------------------- Character init ----------------------------
local function watchFlagStopOnEnable(c, name)
	local f = c:FindFirstChild(name)
	if not f then f = Instance.new("BoolValue"); f.Name = name; f.Value = false; f.Parent = c end
	f:GetPropertyChangedSignal("Value"):Connect(function()
		if f.Value and climbing then stopClimbing() end
	end)
	return f
end

local function onChar(c)
	local function bool(name) boolFlag(c,name).Value=false end
	bool("ClimbingActive"); bool("IsLunging")
	watchFlagStopOnEnable(c, "PitonClimbingActive")
	watchFlagStopOnEnable(c, "RopeClimbingActive")

	-- Ensure default camera is Custom/subject at spawn
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType    = Enum.CameraType.Custom
		cam.CameraSubject = c:FindFirstChildOfClass("Humanoid") or c
	end
end
player.CharacterAdded:Connect(onChar)
if player.Character then onChar(player.Character) end

-- Respect jump min stamina (read-only)
RunService.RenderStepped:Connect(function()
	local char=player.Character; if not char then return end
	local h=char:FindFirstChildOfClass("Humanoid")
	if not h then return end
	-- If another system zeroes stamina, block jump locally
	if h.Jump and getTotalStamina(char) < 0.0001 then h.Jump=false end
end)

--------------------------- MOBILE UI --------------------------
-- Place a tiny toggle near existing buttons (unchanged)
local RIGHT_MARGIN_PX        = 20
local MIN_BOTTOM_MARGIN_PX   = 6
local STACK_SPACING_PX       = 18
local ABOVE_JUMP_SPACING_PX  = 14
local EXTRA_LOWER_PX         = 40

local INTERACT_NAMES = { "UseItemButton", "ItemInteractButton", "UseButton", "BtnUseItem", "Use", "Interact" }
local SPRINT_NAMES   = { "SprintButton", "RunButton", "Sprint", "Run", "Dash", "ShiftButton" }
local JUMP_NAMES     = { "JumpButton", "Jump", "MobileJump", "TouchJump" }

local MobileUI, BtnClimb
local function uiMakeRound(inst)
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(1, 0); corner.Parent = inst
	local stroke = Instance.new("UIStroke"); stroke.Thickness = 2; stroke.Color = Color3.fromRGB(220,220,220); stroke.Transparency = 0.25; stroke.Parent = inst
end
local function uiFindByNames(nameList)
	local pg = player:FindFirstChild("PlayerGui"); if not pg then return nil end
	for _, sg in ipairs(pg:GetChildren()) do
		if sg:IsA("ScreenGui") then
			for _, n in ipairs(nameList) do
				local obj = sg:FindFirstChild(n, true)
				if obj and obj:IsA("GuiObject") then return obj end
			end
		end
	end
	return nil
end
local function uiFindSprintButton()   return uiFindByNames(SPRINT_NAMES)   end
local function uiFindJumpButton()     return uiFindByNames(JUMP_NAMES)     end
local function uiGapFromBottom(inst)
	if not inst or not inst.AbsoluteSize then return nil end
	local gui = inst:FindFirstAncestorOfClass("ScreenGui"); if not gui then return nil end
	return gui.AbsoluteSize.Y - (inst.AbsolutePosition.Y + inst.AbsoluteSize.Y)
end
local function placeInteractButton(btn)
	if not btn then return end
	btn.AnchorPoint     = Vector2.new(1,1)
	btn.AutomaticSize   = Enum.AutomaticSize.None
	btn.SizeConstraint  = Enum.SizeConstraint.RelativeXY
	local h_u = (btn.AbsoluteSize.Y > 0) and btn.AbsoluteSize.Y or 68

	local sprint = uiFindSprintButton()
	local jump   = uiFindJumpButton()

	local minGap = MIN_BOTTOM_MARGIN_PX
	if jump and jump.Visible and jump.AbsoluteSize.Magnitude > 0 then
		local g_j = uiGapFromBottom(jump) or 12
		local h_j = (jump.AbsoluteSize.Y > 0) and jump.AbsoluteSize.Y or 84
		minGap = math.max(minGap, g_j + h_j + ABOVE_JUMP_SPACING_PX)
	end

	local maxGap = math.huge
	if sprint and sprint.Visible and sprint.AbsoluteSize.Magnitude > 0 then
		local g_s = uiGapFromBottom(sprint) or 140
		maxGap = math.max(MIN_BOTTOM_MARGIN_PX, g_s - STACK_SPACING_PX - h_u - EXTRA_LOWER_PX)
	end

	local bottomGap = math.max(MIN_BOTTOM_MARGIN_PX, math.min(maxGap, minGap))
	btn.Position = UDim2.new(1, -RIGHT_MARGIN_PX, 1, -bottomGap)
end
local function hookReflowSignals(rootGui)
	rootGui.DescendantAdded:Connect(function()
		task.defer(function() placeInteractButton(BtnClimb) end)
	end)
	rootGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		placeInteractButton(BtnClimb)
	end)
end

local function createMobileUI()
	if not UserInputService.TouchEnabled then return end
	local pg = player:WaitForChild("PlayerGui")

	if pg:FindFirstChild("ClimbMobileUI") then
		MobileUI = pg:FindFirstChild("ClimbMobileUI")
		BtnClimb = MobileUI:FindFirstChild("BtnClimb")
		placeInteractButton(BtnClimb)
		hookReflowSignals(MobileUI)
		return
	end

	MobileUI = Instance.new("ScreenGui")
	MobileUI.Name = "ClimbMobileUI"
	MobileUI.ResetOnSpawn = false
	MobileUI.IgnoreGuiInset = true
	MobileUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	MobileUI.Parent = pg

	BtnClimb = Instance.new("TextButton")
	BtnClimb.Name = "BtnClimb"
	BtnClimb.Text = "CLIMB: OFF"
	BtnClimb.TextScaled = true
	BtnClimb.Font = Enum.Font.GothamBold
	BtnClimb.Size = UDim2.fromOffset(68, 68)
	BtnClimb.AnchorPoint = Vector2.new(1,1)
	BtnClimb.Position = UDim2.new(1, -20, 1, -260)
	BtnClimb.BackgroundColor3 = Color3.fromRGB(45,45,45)
	BtnClimb.TextColor3 = Color3.fromRGB(255,255,255)
	BtnClimb.AutoButtonColor = true
	BtnClimb.Active = true
	BtnClimb.Parent = MobileUI
	uiMakeRound(BtnClimb)

	placeInteractButton(BtnClimb)
	hookReflowSignals(MobileUI)

	BtnClimb.Activated:Connect(function()
		climbArmed = not climbArmed
		BtnClimb.Text = (climbArmed and "CLIMB: ON" or "CLIMB: OFF")
		BtnClimb.BackgroundColor3 = climbArmed and Color3.fromRGB(70,180,100) or Color3.fromRGB(45,45,45)

		if climbArmed and not climbing and tick() >= pitonReleaseCooldownUntil then
			if not pitonActive(player.Character) and not ropeActive(player.Character) then
				local hit = wallRaycast(player.Character, 3)
				if hit then startClimbing() end
			end
		end
		if not climbArmed and climbing then
			stopClimbing()
		end
	end)
end

createMobileUI()
UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(function()
	if UserInputService.TouchEnabled then
		createMobileUI()
	elseif MobileUI then
		MobileUI:Destroy(); MobileUI = nil; BtnClimb = nil
	end
end)
