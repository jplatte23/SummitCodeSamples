local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local ClimbRopeMovement = ReplicatedStorage:WaitForChild("ClimbRopeMovement")
local RopeSegmentsUpdate = ReplicatedStorage:WaitForChild("RopeSegmentsUpdate") -- optional

local climbAnimId = "rbxassetid://120484211656915"
local climbingTracks = {}

-- Player state storage
local climbingPlayers = {}

function broadcastCFrameToOthers(sender, cframe)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= sender then
			ClimbRopeMovement:FireClient(player, "BroadcastPosition", {
				userId = sender.UserId,
				cframe = cframe
			})
		end
	end
end

ClimbRopeMovement.OnServerEvent:Connect(function(player, action, data)
	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end

	local humanoid = character:WaitForChild("Humanoid")
	local hrp = character.HumanoidRootPart

	if action == "StartClimbing" then
		-- Mark player as climbing
		if climbingTracks[player] then
			climbingTracks[player]:Stop()
			climbingTracks[player]:Destroy()
			climbingTracks[player] = nil
		end
		local anim = Instance.new("Animation")
		anim.AnimationId = climbAnimId
		local track = humanoid:LoadAnimation(anim)
		track.Looped = true
		track:Play()
		climbingTracks[player] = track
		
		climbingPlayers[player] = true
		--hrp.Anchored = true

	elseif action == "StopClimbing" then
		-- Unmark player
		if climbingTracks[player] then
			climbingTracks[player]:Stop()
			climbingTracks[player]:Destroy()
			climbingTracks[player] = nil
		end
		ClimbRopeMovement:FireAllClients("StopClimbingFor", player.UserId)
		climbingPlayers[player] = nil
		--hrp.Anchored = false

	elseif action == "UpdatePosition" then
		if climbingPlayers[player] and typeof(data) == "CFrame" then
			-- Update HRP on the server
			--hrp.CFrame = data
			broadcastCFrameToOthers(player, data)
		end
	end
end)


-- Clean up on player leave
Players.PlayerRemoving:Connect(function(player)
	climbingPlayers[player] = nil
	if climbingTracks[player] then
		climbingTracks[player]:Stop()
		climbingTracks[player]:Destroy()
		climbingTracks[player] = nil
	end
end)
