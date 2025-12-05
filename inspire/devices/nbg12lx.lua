a = false
s = script.Parent
click = s.Cover.Click
parts = s.Cover.Parts
pushed = s.Cover.HandlePushed
pushedparts = s.Cover.HandlePushed.Parts:GetChildren()
pulled = s.Cover.HandlePulled
pulledparts = s.Cover.HandlePulled.Parts:GetChildren()
normal = s.Cover.HandleNormal
normalparts = s.Cover.HandleNormal.Parts:GetChildren()
Polling = true
IsPulled = false
IsPushed = false
pollcolor = "Green"
local fol = script.Parent:WaitForChild("Dep",10)
local Poll = fol:WaitForChild("Poll",10)
if fol then
	print("Found dependencies")
end
if Poll then
	print("Found Poll val")
end

local DeviceDependencies = {}
DeviceDependencies.Network = script.Parent.Parent.Parent.Parent.Parent.Comm
DeviceDependencies.Config = require(script.Parent.DeviceConfiguration)
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

click.ClickDetector.MouseClick:connect(function()--PULL DOWN
	if IsPushed == true and IsPulled == false then
		-----------------------------------------------------
		for i = 1, #pushedparts do--MAKE PUSH IN INVISIBLE
			pushedparts[i].Transparency = 1
		end
		pushed.BP.Transparency = 1
		pushed.S1.Icon.Transparency = 1
		pushed.S2.Icon.Transparency = 1
		pushed.T1.SurfaceGui.Enabled = false
		pushed.T2.SurfaceGui.Enabled = false
		-----------------------------------------------------
		for i = 1, #normalparts do--MAKE NORMAL INVISIBLE
			normalparts[i].Transparency = 1
		end
		normal.BP.Transparency = 1
		normal.S1.Icon.Transparency = 1
		normal.S2.Icon.Transparency = 1
		normal.T1.SurfaceGui.Enabled = false
		normal.T2.SurfaceGui.Enabled = false
		-----------------------------------------------------	
		IsPulled = true
		for i = 1, #pulledparts do--MAKE PULLED VISIBLE
			pulledparts[i].Transparency = 0
		end
		pulled.BP.Transparency = 0.1
		pulled.S1.Icon.Transparency = 0
		pulled.S2.Icon.Transparency = 0
		pulled.T1.SurfaceGui.Enabled = true
		pulled.T2.SurfaceGui.Enabled = true
		click.P:Play()	
	end
end)

click.ClickDetector.MouseClick:connect(function()--PUSH
	if IsPushed then return end
	if IsPulled then return end
	-----------------------------------------------------
	for i = 1, #pushedparts do--MAKE PUSH IN VISIBLE
		pushedparts[i].Transparency = 0
	end
	pushed.BP.Transparency = 0.1
	pushed.S1.Icon.Transparency = 0
	pushed.S2.Icon.Transparency = 0
	pushed.T1.SurfaceGui.Enabled = true
	pushed.T2.SurfaceGui.Enabled = true
	-----------------------------------------------------
	for i = 1, #normalparts do--MAKE NORMAL INVISIBLE
		normalparts[i].Transparency = 1
	end
	normal.BP.Transparency = 1
	normal.S1.Icon.Transparency = 1
	normal.S2.Icon.Transparency = 1
	normal.T1.SurfaceGui.Enabled = false
	normal.T2.SurfaceGui.Enabled = false
	wait(.1)
	IsPushed = true
	-----------------------------------------------------
	wait(3)--WAIT AMOUNT OF TIME BEFORE RETURNING TO UNPUSHED
	IsPushed = false
	if IsPulled then return end
	-----------------------------------------------------
	for i = 1, #normalparts do--MAKE NORMAL VISIBLE
		normalparts[i].Transparency = 0
	end
	normal.BP.Transparency = 0.1
	normal.S1.Icon.Transparency = 0
	normal.S2.Icon.Transparency = 0
	normal.T1.SurfaceGui.Enabled = true
	normal.T2.SurfaceGui.Enabled = true
	-----------------------------------------------------
	for i = 1, #pushedparts do--MAKE PUSH IN INVISIBLE
		pushedparts[i].Transparency = 1
	end
	pushed.BP.Transparency = 1
	pushed.S1.Icon.Transparency = 1
	pushed.S2.Icon.Transparency = 1
	pushed.T1.SurfaceGui.Enabled = false
	pushed.T2.SurfaceGui.Enabled = false
end)


parts.Lock.Touched:connect(function(hit)
	--print("Reset")
	if hit.Parent == nil then return end
	if hit.Parent.Name ~= "ResetKey" and script.Parent.Reset.Value == false then return end
	script.Parent.Reset.Value = true
	wait(.15)--WAITS BEFORE RESETTING THE HANDLE (MORE REALISTIC BECAUSE IRL YOU OPEN IT THEN IT SPRINGS BACK UP)
	-----------------------------------------------------
	for i = 1, #normalparts do--MAKE NORMAL VISIBLE
		normalparts[i].Transparency = 0
	end
	normal.BP.Transparency = 0.1
	normal.S1.Icon.Transparency = 0
	normal.S2.Icon.Transparency = 0
	normal.T1.SurfaceGui.Enabled = true
	normal.T2.SurfaceGui.Enabled = true
	-----------------------------------------------------
	for i = 1, #pushedparts do--MAKE PUSH IN INVISIBLE
		pushedparts[i].Transparency = 1
	end
	pushed.BP.Transparency = 1
	pushed.S1.Icon.Transparency = 1
	pushed.S2.Icon.Transparency = 1
	pushed.T1.SurfaceGui.Enabled = false
	pushed.T2.SurfaceGui.Enabled = false
	-----------------------------------------------------
	IsPulled = false
	for i = 1, #pulledparts do--MAKE PULLED INVISIBLE
		pulledparts[i].Transparency = 1
	end
	pulled.BP.Transparency = 1
	pulled.S1.Icon.Transparency = 1
	pulled.S2.Icon.Transparency = 1
	pulled.T1.SurfaceGui.Enabled = false
	pulled.T2.SurfaceGui.Enabled = false
end)

script.Parent.Dep.Poll.Changed:Connect(function()
	if script.Parent.Alarm.Value == true then
		script.Parent.LED.Material = "Neon"	
		script.Parent.LED.Transparency = 0.1
		script.Parent.LED.BrickColor = BrickColor.new('Really red')
		if not DeviceDependencies.Tripped then
			DeviceDependencies.Network:Fire("API_Input",EventInformation,thing)
			DeviceDependencies.Tripped = true
		end
	end
	
	if script.Parent.Dep.Poll.Value == true and script.Parent.Alarm.Value == false then
		script.Parent.LED.Material = "Neon"	
		script.Parent.LED.Transparency = 0.1
		if pollcolor == "Red" and script.Parent.Alarm.Value == false and IsPulled == false then
			script.Parent.LED.BrickColor = BrickColor.new('Really red')
		elseif pollcolor == "Green" and script.Parent.Alarm.Value == false and IsPulled == false then
			script.Parent.LED.BrickColor = BrickColor.new('Lime green')
		end
		if IsPulled == true then
			s.Alarm.Value = true	
			script.Parent.LED.Material = "Neon"	
			script.Parent.LED.Transparency = 0.1
			script.Parent.LED.BrickColor = BrickColor.new('Really red')	
		end
	end
	if script.Parent.Dep.Poll.Value == false and script.Parent.Alarm.Value == false then
		script.Parent.LED.Material = "Glass"	
		script.Parent.LED.Transparency = 0.5
		script.Parent.LED.BrickColor = BrickColor.new('Medium stone grey')
	end	
	wait(.4)
	script.Parent.Dep.Poll.Value = false
end)

