local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

-- The external moderation API URL
local MODERATION_API_URL = "https://api.matterrbx.com/modAPI/api/moderate?simple=1"

-- Function to extract and format flagged categories
local function summarizeCategories(categories)
	if not categories or typeof(categories) ~= "table" then
		return "No flagged categories"
	end

	local flaggedCategories = {}
	for category, isFlagged in pairs(categories) do
		if isFlagged == true then
			table.insert(flaggedCategories, category)
		end
	end

	if #flaggedCategories > 0 then
		return table.concat(flaggedCategories, ", ")
	else
		return "No flagged categories"
	end
end

--- Calls the external Moderation API with the provided text input.
-- The results are printed to the console.
local function modApiCheck(inputText)
	local success, response = pcall(function()
		local body = HttpService:JSONEncode({ input = inputText })
		return HttpService:RequestAsync({
			Url = MODERATION_API_URL,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json"
			},
			Body = body,
		})
	end)

	if not success then
		warn("Moderation API Request Failed (Network Error):", response)
		return { flagged = false, reason = "API Request Failed", verdicts = {} }
	end

	if response.StatusCode ~= 200 then
		warn(string.format("Moderation API HTTP Error %d", response.StatusCode))
		return { flagged = false, reason = string.format("API HTTP Error %d", response.StatusCode), verdicts = {} }
	end

	local data
	local decodeSuccess = pcall(function()
		data = HttpService:JSONDecode(response.Body)
	end)

	if not decodeSuccess or not data then
		warn("Moderation API Response Decode Error")
		return { flagged = false, reason = "API Response Decode Error", verdicts = {} }
	end

	local verdicts = data.verdicts
	if typeof(verdicts) ~= "table" then
		verdicts = {}
	end

	local flagged = false
	local top = verdicts[1] or {}
	local reason = "No flagged categories"

	for _, verdict in ipairs(verdicts) do
		if verdict and verdict.flagged == true then
			flagged = true
			break
		end
	end

	if flagged then
		reason = summarizeCategories(top.categories)
	end

	-- LOGGING WHAT WAS FLAGGED AND WHY
	-- This log is included inside the API check as requested in the previous turn.
	print(string.format("[API Check] Text: \"%s\" | Flagged: %s | Reason: %s", 
		inputText, tostring(flagged), reason))

	return { 
		flagged = flagged, 
		reason = reason, 
		verdicts = verdicts 
	}
end

--- Bans the user
-- @param player Player The player you wish to ban.
-- @param duration is how long you wish to ban the user. nil for perm.
-- @param reason for banning.
function ban(player, duration, reason)
	local duration = duration or -1 -- Creator-implemented logic
	local config: BanConfigType = {
		UserIds = { player.UserId },
		Duration = duration,
		DisplayReason = "[Automod]: You were banned for: "..tostring(reason),
		PrivateReason = "Banned by AutoMod - Reason: "..tostring(reason),
		ExcludeAltAccounts = false,
		ApplyToUniverse = true,
	}

	local success, err = pcall(function()
		return Players:BanAsync(config)
	end)
	print(success, err)
end

--- Main function called when a player chats.
-- @param player Player The player object who sent the message.
-- @param message string The raw string content of the message.
local function handlePlayerChat(player, message)
	print(string.format("Player %s chatted: \"%s\"", player.Name, message))

	-- Call the moderation check function
	local result = modApiCheck(message)

	if result.flagged then
		print(string.format("!!! ACTION REQUIRED: %s's chat was flagged for: %s", 
			player.Name, result.reason))
		-- Example action: You could kick the player, mute them, or log the incident to a database here.
		ban(player,nil,result.reason)
		
	end
end

--- Connects the 'Chatted' event for a newly added player.
local function onPlayerAdded(player)
	-- 'Chatted' provides the raw string message content
	player.Chatted:Connect(function(message)
		handlePlayerChat(player, message)
	end)
end

-- Connect the handler for all players already in the game
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- Connect the handler for any players who join after the script runs
Players.PlayerAdded:Connect(onPlayerAdded)
