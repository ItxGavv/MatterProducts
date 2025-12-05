alarm = script.Parent.Parent.Alarm
pulled = script.Parent.Pulled
coveropen = script.Parent.CoverOpen

script.Parent.PrimaryPart = script.Parent.Hinge

local DeviceDependencies = {}
DeviceDependencies.Network = script.Parent.Parent.Parent.Parent.Parent.Parent.Comm
DeviceDependencies.Config = require(script.Parent.Parent.DeviceConfiguration)
DeviceDependencies.Tripped = false

local EventInformation = {
	EventType = DeviceDependencies.Config.EventConfig.EventType, -- You can have custom events. It'll show under Other events.
	DeviceDetails = {
		DeviceName = DeviceDependencies.Config.DeviceConfig.DeviceName,
		DeviceType = DeviceDependencies.Config.DeviceConfig.DeviceType,
		DeviceZone = DeviceDependencies.Config.DeviceConfig.DeviceZone -- can be formatted as 001 or 1. 
	},
	SendToPulsar = true, -- Report condition to Pulsar?
}

local thing = {
	Address = script.Parent.Name
}


pulled.Changed:Connect(function()
	if pulled.Value == true then
		alarm.Value = true		
		if not DeviceDependencies.Tripped then
			DeviceDependencies.Network:Fire("API_Input",EventInformation,thing)
			DeviceDependencies.Tripped = true
		end
	else
		if coveropen.Value == false then
			alarm.Value = false	
			DeviceDependencies.Tripped = false
		end
	end
end)

coveropen.Changed:Connect(function()
	if coveropen.Value == true then
		alarm.Value = true		
		if not DeviceDependencies.Tripped then
			DeviceDependencies.Network:Fire("API_Input",EventInformation,thing)
			DeviceDependencies.Tripped = true
		end
	else
		if pulled.Value == false then
			alarm.Value = false		
			DeviceDependencies.Tripped = false
		end
	end
end)

pulled = script.Parent.Pulled
coveropen = script.Parent.CoverOpen
cooldown = false

function Open()
	coveropen.Value = true
	for i = 1, 18 do
		script.Parent:SetPrimaryPartCFrame(script.Parent.PrimaryPart.CFrame * CFrame.Angles(0, math.rad(-5), 0))
		wait()
	end	
end

function Close()
	for i = 1, 18 do
		script.Parent:SetPrimaryPartCFrame(script.Parent.PrimaryPart.CFrame * CFrame.Angles(0, math.rad(5), 0))
		wait()
		coveropen.Value = false
	end		
end

script.Parent.Lock.Touched:connect(function(hit)
	if hit.Parent == nil then return end
	if hit.Parent.Name ~= "ResetKey" then return end
	if cooldown == false then
		cooldown = true
		if coveropen.Value == false then
			Open()
			wait(1)
			cooldown = false
		else
			Close()
			wait(1)
			cooldown = false
		end
	end
	script.Parent.Parent.Parent.Parent.Parent.Parent.Comm:Fire("SystemCommand","Device_First_Reset",script.Parent.Parent.Name)

end)
