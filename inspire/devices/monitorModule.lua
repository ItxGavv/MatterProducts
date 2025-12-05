local DeviceDependencies = {}
DeviceDependencies.Network = script.Parent.Parent.Parent.Parent.Parent.Comm
DeviceDependencies.Config = require(script.Parent.DeviceConfiguration)
DeviceDependencies.Devices = script.Parent.Devices
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

function Poll()
	if DeviceDependencies.Tripped then return end
	for i,v in pairs(DeviceDependencies.Devices:GetChildren()) do
		if v.Alarm.Value == true then
			if DeviceDependencies.Tripped == false then
				DeviceDependencies.Network:Fire("API_Input",EventInformation,thing)
				DeviceDependencies.Tripped = true
				if script.Parent.Dep.Type.Value == "FLASH" then
					script.Parent.LED.Material = Enum.Material.Neon
					script.Parent.LED.BrickColor = BrickColor.new("Lime green")
				elseif script.Parent.Dep.Type.Value == "CLIP" then
					script.Parent.LED.Material = Enum.Material.Neon
					script.Parent.LED.BrickColor = BrickColor.new("Really red")
				end
			end
		end
	end
end

script.Parent.Dep.Poll.Changed:Connect(function(poll)
	if poll then
		if DeviceDependencies.Tripped then return end
		if script.Parent.Dep.Type.Value == "FLASH" then
			script.Parent.LED.Material = Enum.Material.Neon
			script.Parent.LED.BrickColor = BrickColor.new("Lime green")
		elseif script.Parent.Dep.Type.Value == "CLIP" then
			script.Parent.LED.Material = Enum.Material.Neon
			script.Parent.LED.BrickColor = BrickColor.new("Really red")
		end
		wait(0.1)
		Poll()
		script.Parent.Dep.Poll.Value = false
		wait(.01)
		script.Parent.LED.Material = Enum.Material.Glass
		script.Parent.LED.BrickColor = BrickColor.new("Medium stone grey")
	end
end)
