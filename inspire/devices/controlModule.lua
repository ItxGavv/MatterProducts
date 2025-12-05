local DeviceDependencies = {}
DeviceDependencies.Network = script.Parent.Parent.Parent.Parent.Parent.Comm
DeviceDependencies.Config = require(script.Parent.DeviceConfiguration)
DeviceDependencies.Tripped = false

DeviceDependencies.Network.Event:Connect(function(...)
	local packet = {...}
	for i,v,f in pairs(DeviceDependencies.Config.RelayConfiguration) do
		if packet[1] == "Relay" and packet[2] == v then
			script.Parent.Output.Relay.Value = true
			if script.Parent.Dep.Type.Value == "FLASH" then
				script.Parent.LED.Material = Enum.Material.Neon
				script.Parent.LED.BrickColor = BrickColor.new("Lime green")
			elseif script.Parent.Dep.Type.Value == "CLIP" then
				script.Parent.LED.Material = Enum.Material.Neon
				script.Parent.LED.BrickColor = BrickColor.new("Really red")
			end
		end
	end
end)


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
		script.Parent.Dep.Poll.Value = false
		wait(.01)
		script.Parent.LED.Material = Enum.Material.Glass
		script.Parent.LED.BrickColor = BrickColor.new("Medium stone grey")
	end
end)
