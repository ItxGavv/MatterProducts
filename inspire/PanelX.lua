wait(2)
script.Parent.NCD.Indicators.PowerLED.BrickColor = BrickColor.new("Lime green")
script.Parent.NCD.Indicators.PowerLED.Material = Enum.Material.Neon
PANEL.Screen.InspireDisplay.Enabled = true
local networkConfig = require(script.Parent.Parent.Parent.Parent.Global_Dependencies.Network_Configuration.NetworkConfig)
local Network = script.Parent.Parent.Parent.Parent.Comm
local Node_Settings = require(script.Parent.NodeConfig)

local panelVars = {
	InAlarm = false,
	silenced = false,
}
local TopBarColors = {
	Fire = Color3.new(1, 0.160784, 0.0117647),
	Trouble = Color3.new(0.92549, 0.92549, 0),
	Other = Color3.new(0, 0.827451, 0.827451),
	UIDisable = Color3.new(0.45098, 0.45098, 0.45098)

}

local frameLookup = {
	Fire = "Fire",
	CO = "COAlarm",
	Supervisory = "Supv",
	Trouble = "Fault",
	Disable = "Disable",
	Other = "Other"
}

local eventMemory = {} -- For event history
local loggedInUser = if game:GetService("RunService"):IsStudio() then {
	Code = 01010101, 
	UserName = "STUDIO MODE", 
	Permissions = { 
		"*"
	}
} else nil

local events = {

	firealarm = {
		count = 0,
		unacked = {},
		acked = {}
	},
	coalarm = {
		count = 0,
		unacked = {},
		acked = {}
	},
	supervisory = {
		count = 0,
		unacked = {},
		acked = {}
	},
	trouble = {
		count = 0,
		unacked = {},
		acked = {}
	},
	disable = {
		count = 0,
		unacked = {},
		acked = {}
	},
	other = {
		count = 0,
		unacked = {},
		acked = {}
	}
}

local AddressingInfo = {
	Detectors = 0,
	Monitors = 0,
	TotalDevs = 0,
	Loop = 1,
	maxDevicesPerSLC = 318,
	maxSLCs = 16,
	currentAddress = 1

}

function formatAddress(str)
	local node, loop, dev = string.match(str, "^(N%d+)L(%d+)D(%d+)$")
	if node and loop and dev then
		return node .. " L" .. loop .. " D" .. dev
	else
		return str -- fallback
	end
end

function AddressSLC()
	local slcFolder = script.Parent.Parent:WaitForChild("SLC")
	script.piezo_handler.Parent = script.Parent.NCD.Screen.Piezo
	script.Parent.NCD.Screen.InspireDisplay.Main.BG.Logo.Image = networkConfig.Banner_Image or "rbxassetid://14686597259"
	for _, device in pairs(slcFolder:GetChildren()) do
		if device:IsA("Model") and device:FindFirstChild("DeviceConfiguration") then
			local sett = require(device.DeviceConfiguration)
			local deviceType = sett.DeviceConfig.DeviceType

			local prefix = ""
			if deviceType == "Pull Station" then
				prefix = "M"
				AddressingInfo.Monitors += 1
			elseif deviceType == "Smoke Detector" then
				prefix = "D"
				AddressingInfo.Detectors += 1
			elseif deviceType == "Heat Detector" then
				prefix = "D"
				AddressingInfo.Detectors += 1
			elseif deviceType == "Beam Detector" then
				prefix = "D"
				AddressingInfo.Detectors += 1
			elseif deviceType == "Control Module" then
				prefix = "M"
				AddressingInfo.Monitors += 1
			elseif deviceType == "Monitor Module" then
				prefix = "M"
				AddressingInfo.Monitors += 1
			else
				if networkConfig.Debug then
					warn(string.format("Cannot process device %s",device.Name))
				end
			end

			local add = formatAddress("N"..tostring(string.format("%01d",script.Parent.Parent.Name)).."L"..tostring(string.format("%02d",AddressingInfo.Loop))..""..prefix..""..string.format("%03d",AddressingInfo.currentAddress))
			-- Set model name as PrefixX-X
			device.Name = add
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
			-- Prepare for next device
			AddressingInfo.currentAddress = AddressingInfo.currentAddress + 1
			AddressingInfo.TotalDevs += 1


			-- Move to next loop if needed
			if AddressingInfo.currentAddress > AddressingInfo.maxDevicesPerSLC then
				AddressingInfo.currentAddress = 1
				AddressingInfo.Loop += 1

				if AddressingInfo.currentSLC > AddressingInfo.maxSLCs then
					if networkConfig.Debug then
						warn("Max SLC loops reached. Stopping assignment.")
					end
					break
				end
			end
		end
	end
	if networkConfig.Debug then
		warn(string.format("[Notifier Inspire]: Addressing complete: %d devices processed (Monitors: %d, Detectors: %d)", AddressingInfo.TotalDevs, AddressingInfo.Monitors, AddressingInfo.Detectors))
	end
end

local function hasPermission(permission)
	if not loggedInUser or not loggedInUser.Permissions then return false end
	for _, p in pairs(loggedInUser.Permissions) do
		if p == "*" or p == permission then
			return true
		end
	end
	return false
end

local function authenticate(code)
	for _, account in pairs(Node_Settings.Access_Codes) do
		if account.Code == code then
			loggedInUser = account
			print("[AUTH] Logged in as", account.UserName)
			return true
		end
	end
	print("[AUTH] Invalid access code")
	return false
end


AddressSLC()

Network.Event:Connect(function(...)
	local Pkt = {...}
	if Pkt[1] == "API_Input" then
		local EventInformation = Pkt[2]
		local EventType = nil
		local DeviceDetails = nil
		local DeviceZone = nil
		local Address = nil
		if EventInformation.EventType then
			EventType = EventInformation.EventType
		else
			EventType = "N/A"
		end
		if EventInformation.DeviceDetails then
			DeviceDetails = EventInformation.DeviceDetails
		else
			DeviceDetails = "N/A"
		end
		if DeviceDetails.DeviceZone then
			DeviceZone = DeviceDetails.DeviceZone
		else
			DeviceZone = "N/A"
		end
		if Pkt[3].Address then
			Address = Pkt[3].Address
		else
			Address = "N/A"
		end

		local eventsFrame = script.Parent.NCD.Screen.InspireDisplay.Main.Events
		local template = script.Parent.NCD.Screen.InspireDisplay.Main.Objects.EventTemplates.Template
		local statusFrame = script.Parent.NCD.Screen.InspireDisplay.Main.StatusFrame
		local statusBar = script.Parent.NCD.Screen.InspireDisplay.Main.StatusBar
		eventsFrame.Visible = true

		local keyName = frameLookup[EventType] or "Fault"
		local eventKey = string.lower(EventType) .. "s"
		local eventTable = events[eventKey] or events.other
		eventTable.count += 1

		-- Add to memory
		table.insert(eventMemory, {
			type = EventType,
			zone = DeviceZone,
			address = Address,
			deviceName = DeviceDetails.DeviceName,
			time = os.time(),
			acked = false
		})

		local full = eventsFrame:FindFirstChild("Unacked" .. keyName .. "Full")
		local half = eventsFrame:FindFirstChild("Unacked" .. keyName .. "Half")

		script.Parent.NCD.Screen.InspireDisplay.Main.Ack.Interactable = true
		script.Parent.NCD.Screen.InspireDisplay.Main.Ack.TextColor3 = Color3.new(1, 1, 1)
		script.Parent.NCD.Screen.InspireDisplay.Main.Ack.BackgroundColor3 = TopBarColors.Other


		local function cloneToContainer(container)
			local cln = template:Clone()
			cln.Name = EventType .. "_" .. eventTable.count
			cln.Zone.Text = "Z" .. string.format("%03d", DeviceZone) or "Undefined"
			cln.DeviceNumber.Text = Address or "Undefined"
			cln.DeviceLocation.Text = DeviceDetails.DeviceName or "Undefined"
			cln.Time.Text = os.date("%I:%M:%S ")..string.upper(os.date("%p")) or "Undefined"
			cln.Date.Text = os.date("%a %x") or "Undefined"
			cln.DeviceType.Text = DeviceDetails.DeviceType or "Undefined"
			cln.Parent = container
			cln.Visible = true
		end

		if full and #full:GetChildren() < 3 then
			cloneToContainer(full)
			full.Visible = true
		else
			if full then
				for _, v in pairs(full:GetChildren()) do
					if v:IsA("Frame") and v.Name == "Template" then
						v.Parent = half
					end
				end
				full:Destroy()
			end
			cloneToContainer(half)
			half.Visible = true
		end

		-- UI StatusFrame
		local frame = statusFrame:FindFirstChild(frameLookup[EventType])
		if frame then
			frame.BackgroundColor3 = TopBarColors[EventType] or TopBarColors.Other
			frame.NumBubble.Visible = true
			frame.FA_Status.Visible = true
			frame.FA_Status.Text = tostring(eventTable.count)
		end

		-- Top Bar
		if not panelVars.InAlarm or EventType == "Fire" then
			statusBar.BackgroundColor3 = TopBarColors[EventType] or TopBarColors.Other
			statusBar.StatusLine.Text = (EventType == "CO" and "CARBON MONOXIDE")
				or (EventType == "Supervisory" and "SUPERVISORY")
				or (EventType == "Disable" and "DISABLEMENT")
				or (EventType == "Trouble" and "SYSTEM TROUBLE")
				or (EventType == "Other" and "OTHER EVENT")
				or "FIRE ALARM"

			for _, v in pairs(statusBar:GetChildren()) do
				if v:IsA("ImageLabel") then v.Visible = false end
			end

			local iconName = frameLookup[EventType] .. "Icon"
			local icon = statusBar:FindFirstChild(iconName)
			if icon then icon.Visible = true end
		end

		-- Piezo Logic for Fire
		if EventType == "Fire" then
			panelVars.InAlarm = true
			Network:Fire("Outputs","Trip",true)
			script.Parent.NCD.Screen.Piezo.piezo_handler.Enabled = true
			script.Parent.NCD.Screen.InspireDisplay.Main.BG.Visible = false
			script.Parent.NCD.Screen.InspireDisplay.Main.InstructionBar.Visible = true
		end
	elseif Pkt[1] == "SystemCommand" then
		local statusFrame = script.Parent.NCD.Screen.InspireDisplay.Main.StatusFrame
		if Pkt[2] == "Silence" then
			if Pkt[3] == true then
				Network:Fire("Outputs","Trip",false)
				local sigSil = statusFrame:FindFirstChild("SigSil")
				if sigSil then
					sigSil.BackgroundColor3 = Color3.new(0.831373, 0.831373, 0)
				end
			elseif Pkt[3] == false then
				Network:Fire("Outputs","Trip",true)
				local sigSil = statusFrame:FindFirstChild("SigSil")
				if sigSil then
					sigSil.BackgroundColor3 = Color3.new(0.254902, 0.254902, 0.254902)
				end
			end
		elseif Pkt[2] == "Reset" then
			for i = #eventMemory, 1, -1 do
				table.remove(eventMemory, i)
			end
			panelVars.InAlarm = false
			panelVars.silenced = false
			script.Parent.NCD.Screen.Piezo.piezo_handler.Enabled = false
			script.Parent.NCD.Screen.Piezo:Stop()
			script.Parent.NCD.Screen.InspireDisplay.Main.BG.Visible = true
			script.Parent.NCD.Screen.InspireDisplay.Main.InstructionBar.Visible = false
			for i,v in pairs(script.Parent.NCD.Screen.InspireDisplay.Main.Events:GetChildren()) do
				if v:IsA("ScrollingFrame") then
					for z,d in pairs(v:GetChildren()) do
						if d.Name ~= "UIListLayout" then
							if d.Name ~= "UnackedEvents" then
								d:Destroy()
							end
						end
					end
				end
			end
			script.Parent.NCD.Screen.InspireDisplay.Main.Events.Visible = false
			script.Parent.NCD.Screen.InspireDisplay.Main.StatusBar.BackgroundColor3 = Color3.new(0.27451, 0.27451, 0.27451)
			for u,w in pairs(script.Parent.NCD.Screen.InspireDisplay.Main.StatusBar:GetChildren()) do
				if w:IsA("ImageLabel") then
					w.Visible = false
				end
			end
			script.Parent.NCD.Screen.InspireDisplay.Main.StatusBar.StatusLine.Text = "System Normal"
			for m,n in pairs(script.Parent.NCD.Screen.InspireDisplay.Main.StatusFrame:GetChildren()) do
				n.BackgroundColor3 = Color3.new(0.254902, 0.254902, 0.254902)
				n.NumBubble.Visible = false
				n["FA_Status"].Text = "0"
				n["FA_Status"].Visible = false
				n.Icon.ImageColor3 = Color3.new(0.294118, 0.294118, 0.294118)
			end
			script.Parent.NCD.Screen.InspireDisplay.Main.RedBGBar.Visible = true
		end
	end
end)

-- ACK / RESET button bindings with permission check
script.Parent.NCD.Screen.InspireDisplay.Main.Ack.MouseButton1Click:Connect(function()
	if not hasPermission("USER") then
		return
	end
	for _, event in pairs(eventMemory) do
		event.acked = true
	end
	script.Parent.NCD.Screen.InspireDisplay.Main.Ack.Interactable = false
	script.Parent.NCD.Screen.InspireDisplay.Main.Ack.TextColor3 = Color3.new(0.882353, 0.882353, 0.882353)
	script.Parent.NCD.Screen.InspireDisplay.Main.Ack.BackgroundColor3 = TopBarColors.UIDisable

	script.Parent.NCD.Screen.InspireDisplay.Main.Silence.Interactable = true
	script.Parent.NCD.Screen.InspireDisplay.Main.Silence.TextColor3 = Color3.new(1, 1, 1)
	script.Parent.NCD.Screen.InspireDisplay.Main.Silence.BackgroundColor3 = TopBarColors.Other
end)

script.Parent.NCD.Screen.InspireDisplay.Main.Silence.MouseButton1Click:Connect(function()
	if not hasPermission("USER") then
		return
	end
	Network:Fire("SystemCommand","Silence",true)
	script.Parent.NCD.Screen.InspireDisplay.Main.Silence.Interactable = false
	script.Parent.NCD.Screen.InspireDisplay.Main.Silence.TextColor3 = Color3.new(0.882353, 0.882353, 0.882353)
	script.Parent.NCD.Screen.InspireDisplay.Main.Silence.BackgroundColor3 = TopBarColors.UIDisable

	script.Parent.NCD.Screen.InspireDisplay.Main.Reset.Interactable = true
	script.Parent.NCD.Screen.InspireDisplay.Main.Reset.TextColor3 = Color3.new(1, 1, 1)
	script.Parent.NCD.Screen.InspireDisplay.Main.Reset.BackgroundColor3 = TopBarColors.Other
end)


script.Parent.NCD.Screen.InspireDisplay.Main.Reset.MouseButton1Click:Connect(function()
	if not hasPermission("ADUSER") and not hasPermission("SUUSER") and not hasPermission("*") then
		print("[PERMISSION] RESET denied. ADUSER or higher required.")
		return
	end
	Network:Fire("SystemCommand","Reset")
end)








