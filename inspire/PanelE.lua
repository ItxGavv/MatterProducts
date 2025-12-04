-- Notifier Inspire - Optimized Panel Core (drop-in)
-- Keeps all features; fixes subtle bugs; improves safety & performance.

-- == Boot / Globals ==
script.Checksum.Enabled = true
task.wait(2)

local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")

local ROOT = script.Parent
local PANEL = ROOT.NCD
local DISPLAY = PANEL.Screen.InspireDisplay
local MAIN = DISPLAY.Main
local STATUS_BAR = MAIN.StatusBar
local STATUS_FRAME = MAIN.StatusFrame
local EVENTS_FRAME = MAIN.Events
local TEMPLATES = MAIN.Objects.EventTemplates
local BTN_ACK = MAIN.Ack
local BTN_SILENCE = MAIN.Silence
local BTN_RESET = MAIN.Reset
local BTN_MENU = MAIN.MenuFrame.MainMenu
local BG = MAIN.BG
local INSTRUCTION = MAIN.InstructionBar
local RED_BG_BAR = MAIN.RedBGBar
local PIEZO = PANEL.Screen.Piezo
local PIEZO_HANDLER = script.piezo_handler

-- Power LED on (unchanged)
PANEL.Indicators.PowerLED.BrickColor = BrickColor.new("Lime green")
PANEL.Indicators.PowerLED.Material = Enum.Material.Neon

-- External deps / config
local networkConfig = require(ROOT.Parent.Parent.Parent.Global_Dependencies.Network_Configuration.NetworkConfig)
local Network = ROOT.Parent.Parent.Parent.Comm
local Node_Settings = require(ROOT.NodeConfig)

-- == State ==
local panelVars = {
	InAlarm = false,
	silenced = false,
	menuOpt = "home",
}

local TopBarColors = {
	Fire = Color3.new(1, 0.160784, 0.0117647),
	Trouble = Color3.new(0.92549, 0.92549, 0),
	Other = Color3.new(0, 0.827451, 0.827451),
	UIDisable = Color3.new(0.45098, 0.45098, 0.45098),
	CO = Color3.new(0, 0.827451, 0.827451),
	Supervisory = Color3.new(0.92549, 0.92549, 0),
	Disable = Color3.fromRGB(75, 75, 75),
	Security = Color3.fromRGB(0, 211, 211),
}

local frameLookup = {
	Fire = "Fire",
	CO = "COAlarm",
	Supervisory = "Supv",
	Trouble = "Fault",
	Disable = "Disable",
	Other = "Other",
	Security = "Other", -- UI shares "Other"
}

-- Map incoming EventType -> events key
local EVENT_KEY = {
	Fire = "firealarm",
	CO = "coalarm",
	Supervisory = "supervisory",
	Trouble = "trouble",
	Disable = "disable",
	Other = "other",
	Security = "other",
}

local events = {
	firealarm = { count = 0, unacked = {}, acked = {} },
	coalarm = { count = 0, unacked = {}, acked = {} },
	supervisory = { count = 0, unacked = {}, acked = {} },
	trouble = { count = 0, unacked = {}, acked = {} },
	disable = { count = 0, unacked = {}, acked = {} },
	other = { count = 0, unacked = {}, acked = {} },
}

local eventMemory = {} -- event history

local activeLatches = {}
-- Studio convenience user (code as string for safety)
local loggedInUser = nil

-- == Addressing ==
local AddressingInfo = {
	Detectors = 0,
	Monitors = 0,
	TotalDevs = 0,
	Loop = 1,
	maxDevicesPerSLC = 318,
	maxSLCs = 3,
	currentAddress = 1,
}

local function formatAddressForDisplay(node, loop, prefix, addr)
	-- Returns "N## L## D?###"
	return string.format("N%02d L%02d D%s%03d", node, loop, prefix, addr)
end

local function formatAddressInternal(node, loop, prefix, addr)
	-- Model name (compact, searchable)
	return string.format("N%02dL%02d%s%03d", node, loop, prefix, addr)
end

local function classifyDeviceType(deviceType)
	-- Returns prefix ("D"/"M") and counters to bump
	if deviceType == "Pull Station" then
		return "M", "Monitors"
	elseif deviceType == "Control Module" or deviceType == "Monitor Module" then
		return "M", "Monitors"
	elseif deviceType == "Smoke Detector" or deviceType == "Heat Detector" or deviceType == "Beam Detector" then
		return "D", "Detectors"
	end
	return nil, nil
end

local function AddressSLC()
	local slcFolder = ROOT.Parent:WaitForChild("SLC")
	PIEZO_HANDLER.Parent = PIEZO
	MAIN.BG.Logo.Image = networkConfig.Banner_Image or "rbxassetid://14686597259"

	local nodeId = tonumber(ROOT.Parent.Name) or 1

	for _, device in ipairs(slcFolder:GetChildren()) do
		if device:IsA("Model") and device:FindFirstChild("DeviceConfiguration") then
			local sett = require(device.DeviceConfiguration)
			local deviceType = sett.DeviceConfig.DeviceType
			local prefix, counterKey = classifyDeviceType(deviceType)

			if not prefix then
				if networkConfig.Debug then
					warn(string.format("Cannot process device %s (unknown type: %s)", device.Name, tostring(deviceType)))
				end
			else
				AddressingInfo[counterKey] += 1

				local displayAddress = formatAddressForDisplay(nodeId, AddressingInfo.Loop, prefix, AddressingInfo.currentAddress)
				local internalAddress = formatAddressInternal(nodeId, AddressingInfo.Loop, prefix, AddressingInfo.currentAddress)

				-- Name model (internal); store a readable tag too if desired
				device.Name = internalAddress

				-- Dep folder (unchanged behavior)
				local inst = Instance.new("Folder")
				inst.Name = "Dep"
				local b1 = Instance.new("BoolValue")
				b1.Name = "Poll"
				b1.Parent = inst
				local b2 = Instance.new("StringValue")
				b2.Name = "Type"
				b2.Value = networkConfig.Pro_Features.Polling_Mode
				b2.Parent = inst
				inst.Parent = device

				-- Optional: write display address onto a StringValue for UI/reference
				if not device:FindFirstChild("DisplayAddress") then
					local da = Instance.new("StringValue")
					da.Name = "DisplayAddress"
					da.Value = displayAddress
					da.Parent = device
				end

				-- Advance address counters
				AddressingInfo.currentAddress += 1
				AddressingInfo.TotalDevs += 1

				-- Roll to next loop
				if AddressingInfo.currentAddress > AddressingInfo.maxDevicesPerSLC then
					AddressingInfo.currentAddress = 1
					AddressingInfo.Loop += 1
					if AddressingInfo.Loop > AddressingInfo.maxSLCs then
						if networkConfig.Debug then
							warn("Max SLC loops reached. Stopping assignment.")
						end
						break
					end
				end
			end
		end
	end

	if networkConfig.Debug then
		warn(string.format(
			"[Notifier Inspire]: Addressing complete: %d devices processed (Monitors: %d, Detectors: %d)",
			AddressingInfo.TotalDevs, AddressingInfo.Monitors, AddressingInfo.Detectors
			))
	end
end

-- == Auth / Permissions ==
local function hasPermission(permission)
	if not loggedInUser or not loggedInUser.Permissions then
		return false
	end
	for _, p in ipairs(loggedInUser.Permissions) do
		if p == "*" or p == permission then
			return true
		end
	end
	return false
end

local function authenticate(code)
	for _, account in ipairs(Node_Settings.Access_Codes) do
		if tostring(account.Code) == tostring(code) then
			loggedInUser = account
			print("[AUTH] Logged in as", account.UserName)
			return true
		end
	end
	print("[AUTH] Invalid access code")
	return false
end

-- == UI helpers ==
local function setStatusBarForEventType(eventType)
	local color = TopBarColors[eventType] or TopBarColors.Other
	STATUS_BAR.BackgroundColor3 = color

	-- Status line text
	local line = "FIRE ALARM"
	if eventType == "CO" then line = "CARBON MONOXIDE"
	elseif eventType == "Supervisory" then line = "SUPERVISORY"
	elseif eventType == "Disable" then line = "DISABLEMENT"
	elseif eventType == "Trouble" then line = "SYSTEM TROUBLE"
	elseif eventType == "Other" or eventType == "Security" then line = "OTHER EVENT"
	end
	STATUS_BAR.StatusLine.Text = line

	-- Icons
	for _, v in ipairs(STATUS_BAR:GetChildren()) do
		if v:IsA("ImageLabel") then v.Visible = false end
	end
	local iconName = (frameLookup[eventType] or "Other") .. "Icon"
	local icon = STATUS_BAR:FindFirstChild(iconName)
	if icon then icon.Visible = true end
end

local function setButtonState(btn, interactable, bgColor, textColor)
	btn.Interactable = interactable
	if bgColor then btn.BackgroundColor3 = bgColor end
	if textColor then btn.TextColor3 = textColor end
end

local function resetUIToNormal()
	-- Clear events UI
	for _, scroller in ipairs(EVENTS_FRAME:GetChildren()) do
		if scroller:IsA("ScrollingFrame") then
			for _, child in ipairs(scroller:GetChildren()) do
				if child:IsA("Frame") and child.Name ~= "UIListLayout" and child.Name ~= "UnackedEvents" then
					child:Destroy()
				end
			end
		end
	end
	EVENTS_FRAME.Visible = false

	-- Status bar to normal
	STATUS_BAR.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
	for _, v in ipairs(STATUS_BAR:GetChildren()) do
		if v:IsA("ImageLabel") then v.Visible = false end
	end
	STATUS_BAR.StatusLine.Text = "System Normal"

	-- Status frame tiles
	for _, tile in ipairs(STATUS_FRAME:GetChildren()) do
		if tile:IsA("TextButton") then
			tile.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
			if tile:FindFirstChild("NumBubble") then tile.NumBubble.Visible = false end
			if tile:FindFirstChild("FA_Status") then
				tile.FA_Status.Text = "0"
				tile.FA_Status.Visible = false
			end
			if tile:FindFirstChild("Icon") then
				tile.Icon.ImageColor3 = Color3.fromRGB(75, 75, 75)
			end
		end
	end

	BG.Visible = true
	INSTRUCTION.Visible = false
	RED_BG_BAR.Visible = true
end

-- == Addressing pass ==
AddressSLC()

-- == Network handling ==
Network.Event:Connect(function(...)
	local Pkt = { ... }
	local topic = Pkt[1]

	if topic == "API_Input" then
		local EventInformation = Pkt[2] or {}
		local payload3 = Pkt[3] or {}

		local EventType = EventInformation.EventType or "Other"
		local DeviceDetails = EventInformation.DeviceDetails or {}
		local DeviceZone = DeviceDetails.DeviceZone or "N/A"
		local Address = payload3.Address or DeviceDetails.Address or "N/A"

		-- Prepare UI containers
		local template = TEMPLATES.Template
		local statusFrame = STATUS_FRAME
		local eventsFrame = EVENTS_FRAME
		eventsFrame.Visible = true

		-- Which events bucket?
		local keyName = frameLookup[EventType] or "Fault"
		local eventKey = EVENT_KEY[EventType] or "other"
		local eventTable = events[eventKey]
		eventTable.count += 1

		-- Track memory
		table.insert(eventMemory, {
			type = EventType,
			zone = DeviceZone,
			address = Address,
			deviceName = DeviceDetails.DeviceName,
			deviceType = DeviceDetails.DeviceType,
			time = os.time(),
			acked = false,
		})


		if DeviceDetails.DeviceType == "Pull Station" then
			table.insert(activeLatches,{
				type = EventType,
				zone = DeviceZone,
				address = Address,
				deviceName = DeviceDetails.DeviceName,
				deviceType = DeviceDetails.DeviceType,
				time = os.time(),
				acked = false,
			})
		end


		-- Enable ACK
		setButtonState(BTN_ACK, true, TopBarColors.Other, Color3.new(1, 1, 1))

		-- Instantiate a line item (prefer Unacked<keyName>Full, fall back to Half)
		local full = eventsFrame:FindFirstChild("Unacked" .. keyName .. "Full")
		local half = eventsFrame:FindFirstChild("Unacked" .. keyName .. "Half")

		local function addEventRow(container)
			local cln = template:Clone()
			cln.Name = EventType .. "_" .. eventTable.count
			cln.Zone.Text = "Z" .. string.format("%03d", tonumber(DeviceZone) or 0)
			cln.DeviceNumber.Text = tostring(Address)
			cln.DeviceLocation.Text = DeviceDetails.DeviceName or "Undefined"
			cln.Time.Text = os.date("%I:%M:%S ") .. string.upper(tostring(os.date("%p")))
			cln.Date.Text = os.date("%a %x")
			cln.DeviceType.Text = DeviceDetails.DeviceType or "Undefined"
			cln.Visible = true
			cln.Parent = container
		end

		if full and #full:GetChildren() < 3 then
			addEventRow(full)
			full.Visible = true
		else
			if full then full.Visible = false end
			if half then
				addEventRow(half)
				half.Visible = true
			end
		end

		-- Status tile and top bar
		local tileName = frameLookup[EventType]
		if tileName then
			local tile = statusFrame:FindFirstChild(tileName)
			if tile then
				tile.BackgroundColor3 = TopBarColors[EventType] or TopBarColors.Other
				if tile:FindFirstChild("NumBubble") then tile.NumBubble.Visible = true end
				if tile:FindFirstChild("FA_Status") then
					tile.FA_Status.Visible = true
					tile.FA_Status.Text = tostring(eventTable.count)
				end
			end
		end

		-- Top bar prefers Fire or the first non-normal event
		if not panelVars.InAlarm or EventType == "Fire" then
			setStatusBarForEventType(EventType)
		end

		-- Piezo / outputs for Fire
		if EventType == "Fire" then
			panelVars.InAlarm = true
			Network:Fire("Outputs", "Trip", true)
			PIEZO_HANDLER.Enabled = true
			BG.Visible = false
			INSTRUCTION.Visible = true
		elseif EventType == "Trouble" then
			script.Parent.NCD.Indicators.TroubleLED.Material = Enum.Material.Neon
			script.Parent.NCD.Indicators.TroubleLED.BrickColor = BrickColor.new("New Yeller")
		end

	elseif topic == "SystemCommand" then
		local cmd = Pkt[2]
		if cmd == "Silence" then
			local on = Pkt[3] == true
			Network:Fire("Outputs", "Trip", not on)

			local sigSil = STATUS_FRAME:FindFirstChild("SigSil")
			if sigSil then
				sigSil.BackgroundColor3 = on and Color3.fromRGB(212, 212, 0) or Color3.fromRGB(65, 65, 65)
			end

		elseif cmd == "Reset" then
			-- Clear memory
			table.clear(eventMemory)
			-- Reset states
			panelVars.InAlarm = false
			panelVars.silenced = false
			PIEZO_HANDLER.Enabled = false
			PIEZO:Stop()
			resetUIToNormal()

			-- Reset buttons
			setButtonState(BTN_ACK, false, TopBarColors.UIDisable, Color3.fromRGB(225,225,225))
			setButtonState(BTN_SILENCE, false, TopBarColors.UIDisable, Color3.fromRGB(225,225,225))
			setButtonState(BTN_RESET, false, TopBarColors.UIDisable, Color3.fromRGB(225,225,225))

			-- Clear event counters
			for k, v in pairs(events) do
				v.count = 0
				table.clear(v.unacked)
				table.clear(v.acked)
			end

			if #activeLatches > 0 then
				for i,v in pairs(activeLatches) do
					local EventInformation = {
						EventType = v.type,
						DeviceName = v.deviceName,
						DeviceType = v.deviceType,
						DeviceZone = v.zone
					}
					local add = {
						Address = v.address
					}
					
					wait(8)
					Network:Fire("API_Input",EventInformation,add)
				end
			end

		elseif cmd == "Device_First_Reset" then
			local dev = Pkt[3]
			if table.find(activeLatches,dev) then
				table.remove(activeLatches,dev)
			end
		end
	
	end
end)

-- == Buttons ==
BTN_ACK.MouseButton1Click:Connect(function()
	if not hasPermission("USER") then return end

	for _, ev in ipairs(eventMemory) do
		ev.acked = true
	end

	setButtonState(BTN_ACK, false, TopBarColors.UIDisable, Color3.fromRGB(225,225,225))
	setButtonState(BTN_SILENCE, true, TopBarColors.Other, Color3.new(1,1,1))
end)

BTN_SILENCE.MouseButton1Click:Connect(function()
	if not hasPermission("USER") then return end

	Network:Fire("SystemCommand", "Silence", true)

	setButtonState(BTN_SILENCE, false, TopBarColors.UIDisable, Color3.fromRGB(225,225,225))
	setButtonState(BTN_RESET, true, TopBarColors.Other, Color3.new(1,1,1))
end)

BTN_RESET.MouseButton1Click:Connect(function()
	if not (hasPermission("ADUSER") or hasPermission("SUUSER") or hasPermission("*")) then
		print("[PERMISSION] RESET denied. ADUSER or higher required.")
		return
	end
	Network:Fire("SystemCommand", "Reset")
end)

BTN_MENU.MouseButton1Click:Connect(function()
	if panelVars.InAlarm then return end
	if panelVars.menuOpt ~= "home" then
		BG.Visible = true
		MAIN.MainMenu.Visible = false
		panelVars.menuOpt = "home"
	else
		BG.Visible = false
		MAIN.MainMenu.Visible = true
		panelVars.menuOpt = "main"
	end
end)

-- == Checksum / Fail-safe ==
ScriptContext.Error:Connect(function(msg, trace, scr)
	if scr and scr.Name == "PanelLite" then
		MAIN.Visible = false
		DISPLAY.Err.Information.Info.Text = msg
		DISPLAY.Err.Visible = true

		local warnled = PANEL.Indicators:FindFirstChild("TroubleLED")
		if warnled then
			warnled.Material = Enum.Material.Neon
			warnled.BrickColor = BrickColor.new("New Yeller")
		end
	end
end)
