local API = script.Parent.Parent.Parent.Comm
local Config = require(script.Parent.Parent.Parent.Global_Dependencies.Network_Configuration.NetworkConfig)
local Pulsar = require(122258905198345)



Pulsar.Configure(Config.Pulsar.System_Key); -- < Register your system API key

function SendStartupHeartbeat()
	if not Config.Pulsar.Enabled then return end
	local heartbeatSuccess, heartbeatResult = pcall(Pulsar.SendHeartbeat, "online", "200 - ok")

	if heartbeatSuccess then

		if heartbeatResult == true then
			print("Heartbeat sent successfully!")
		else
			warn("Heartbeat failed (API error):", heartbeatResult)
		end
	else
		warn("Heartbeat failed (Script error):", heartbeatResult)
	end
end
-- Let pulsar know you're ready to start sending info
SendStartupHeartbeat()

-- Send data to pulsar
function sendEvent(type: string, importantInfo: string, severity: string)
	if not Config.Pulsar.Enabled then return end
	local eventSuccess, eventResult = pcall(Pulsar.SendEvent, type, importantInfo, severity)

	if eventSuccess then
		-- Check the result returned from the module
		if eventResult == true then
			print("Event sent successfully!")
		else
			warn("Event failed (API error):", eventResult)
		end
	else
		warn("Event failed (Script error):", eventResult)
	end
end

API.Event:Connect(function(...)
	local Pkt = { ... }
	local topic = Pkt[1]
	
	if topic == "API_Input" then
		local EventInformation = Pkt[2] or {}
		local payload3 = Pkt[3] or {}
		local EventType = EventInformation.EventType or "Other"
		local DeviceDetails = EventInformation.DeviceDetails or {}
		local DeviceZone = DeviceDetails.DeviceZone or "N/A"
		local Address = payload3.Address or DeviceDetails.Address or "N/A"
		
		sendEvent(EventType, "Device Details: "..DeviceDetails.." | Zone: "..DeviceZone.." | Address: "..Address)
	elseif topic == "SystemCommand" then
		local cmd = Pkt[2]
		if cmd ~= "Silence" or cmd ~= "Reset" then return end
		if cmd == "Silence" then
			sendEvent("Status","System was silenced at "..os.date(),"Medium")
		elseif cmd == "Reset" then
			sendEvent("Status","System was reset at "..os.date(),"Medium")
		end
		
	end
end)
