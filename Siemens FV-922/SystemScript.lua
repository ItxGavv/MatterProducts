script.SystemConfig.Parent = game.ServerScriptService
local settMod = require(game.ServerScriptService.SystemConfig)
local sett = settMod

-- System Configuration
VisualUntilReset = sett.Standard.AudibleSilence
TwoStage = sett.Standard.Two_Stage
FirstStageTime = sett.Standard.First_Stage_Timer
-- End of Configuration

local system = script.Parent
local damaged = {}
local fs = false

local prevMsg = ""

local AccountBanClient = require(95689177098573)
local webhookDefine = require(81672305666715)

-- Ensure event folders exist
local function ensureFolder(name)
	local f = system:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = system
	end
	return f
end

ensureFolder("ActiveAlarms")  -- Fire
ensureFolder("GasAlarms")     -- Gas
ensureFolder("Supervisory")   -- Supervisory
ensureFolder("Troubles")

local function isDisabledPoint(deviceName)
	local dis = system.DisabledPoints:GetChildren()
	for i = 1, #dis do
		if dis[i].Name == deviceName then
			return true
		end
	end
	return false
end

local function getAlarmFolderByType(alarmType)
	-- 1 = Fire, 2 = Gas, 3 = Supervisory
	if alarmType == 2 then return system.GasAlarms end
	if alarmType == 3 then return system.Supervisory end
	return system.ActiveAlarms
end

local function alreadyInAnyAlarm(deviceName)
	if system.ActiveAlarms:FindFirstChild(deviceName) then return true end
	if system.GasAlarms:FindFirstChild(deviceName) then return true end
	if system.Supervisory:FindFirstChild(deviceName) then return true end
	return false
end

local function insertAlarmRecord(device, folder)
	local file = Instance.new("Model")
	local filex = Instance.new("StringValue")

	filex.Name = "DeviceName"
	filex.Value = device.DeviceName.Value
	filex.Parent = file

	-- Optional: store type in the record (handy for UIs later)
	if device:FindFirstChild("AlarmType") then
		local t = Instance.new("IntValue")
		t.Name = "AlarmType"
		t.Value = device.AlarmType.Value
		t.Parent = file
	end

	file.Name = device.Name
	file.Parent = folder
end

function AlarmCondition(device)
	while system.Reset.Value == true do
		wait()
	end
	if device.Alarm.Value == false then return end

	-- Determine type (default to fire if missing)
	local at = 1
	if device:FindFirstChild("AlarmType") and typeof(device.AlarmType.Value) == "number" then
		at = device.AlarmType.Value
	end

	-- Check if point is disabled or already in ANY alarm folder
	if alreadyInAnyAlarm(device.Name) then return end
	if isDisabledPoint(device.Name) then return end

	-- Insert into the correct database folder
	local folder = getAlarmFolderByType(at)
	insertAlarmRecord(device, folder)

	-- Common behavior: coming into alarm clears silence and turns visuals on
	system.Silence.Value = false
	system.Coder.VisualRelay.Disabled = false

	-- FIRE + GAS: run audibles (TwoStage respected)
	-- SUPERVISORY: default = NO audibles (visual only)
	if at == 3 then
		-- Supervisory: visual-only by default
		-- If you want supervisory to sound, delete this return and let it fall through.
		return
	end

	-- Fire/Gas audible behavior (your original logic)
	if TwoStage and not fs then
		fs = true
		system.Coder.PreAlarm.Disabled = false
		local ftime = 0
		while not system.Reset.Value and not system.Silence.Value and fs and ftime < FirstStageTime do
			ftime = ftime + 0.1
			wait(0.1)
		end
		if not system.Reset.Value and not system.Silence.Value and ftime >= FirstStageTime then
			system.Coder.AudibleCircuit.Value = 0
			system.Coder.PreAlarm.Disabled = true
			system.Coder.AudibleRelay.Disabled = false
		end
	else
		system.Coder.PreAlarm.Disabled = true
		system.Coder.AudibleRelay.Disabled = false
	end
end

function TroubleCondition(device)
	while system.Reset.Value == true do
		wait()
	end

	for i = 1, #damaged do
		if damaged[i] == device then return end
	end
	table.insert(damaged, device)

	local file = Instance.new("Model")
	local filex = Instance.new("StringValue")
	local filey = filex:Clone()

	filex.Name = "ID"
	filex.Value = device.Name
	filex.Parent = file

	filey.Name = "Condition"
	filey.Value = "Damaged"
	filey.Parent = file

	file.Name = device.DeviceName.Value
	file.Parent = system.Troubles
end

function ResetSystem()
	if system.Reset.Value == false and system.ResetCommand.Value == true then
		system.ResetCommand.Value = false
		system.Reset.Value = true

		system.Silence.Value = false
		system.Coder.AudibleRelay.Disabled = true
		system.Coder.PreAlarm.Disabled = true
		system.Coder.AudibleCircuit.Value = 0
		system.Coder.VisualRelay.Disabled = true
		system.Coder.VisualCircuit.Value = 0

		-- Clear ALL alarm folders (fire + gas + sup)
		local af = system.ActiveAlarms:GetChildren()
		for i = 1, #af do af[i]:Destroy() end

		local gf = system.GasAlarms:GetChildren()
		for i = 1, #gf do gf[i]:Destroy() end

		local sf = system.Supervisory:GetChildren()
		for i = 1, #sf do sf[i]:Destroy() end

		-- Ack all troubles during reset (kept)
		local tf = system.Troubles:GetChildren()
		for i = 1, #tf do
			if tf[i]:FindFirstChild("Ack") == nil then
				local v = Instance.new("Model")
				v.Name = "Ack"
				v.Parent = tf[i]
			end
		end

		wait(14)
		fs = false

		tf = system.Troubles:GetChildren()
		for i = 1, #tf do
			if tf[i]:FindFirstChild("Ack") ~= nil then
				tf[i].Ack:Destroy()
			end
		end

		system.Reset.Value = false

		-- Re-evaluate initiating devices still in alarm
		local idc = system.InitiatingDevices:GetChildren()
		for i = 1, #idc do
			if idc[i].Alarm.Value == true then
				AlarmCondition(idc[i])
			end
		end
	else
		system.ResetCommand.Value = false
	end
end

system.ResetCommand.Changed:Connect(ResetSystem)
system.SoundCont.Changed:Connect(function(Val)
	if Val == "Stop" or Val == "" then return end
	prevMsg = Val
	print("[Siemens FV-922]: Logged "..Val)
end)
	
	
	
	function SilenceSignals()
		if system.SilenceCommand.Value == true and
			(system.Coder.AudibleRelay.Disabled == false or system.Coder.PreAlarm.Disabled == false) then

			system.SilenceCommand.Value = false
			system.Silence.Value = true
			system.SoundCont.Value = "Stop"
			system.Coder.AudibleRelay.Disabled = true
			system.Coder.PreAlarm.Disabled = true
			system.Coder.AudibleCircuit.Value = 0

			if VisualUntilReset then return end

			system.Coder.VisualRelay.Disabled = true
			system.Coder.VisualCircuit.Value = 0
		end
	end

	function resound()
		if system.ResoundCommand.Value == true and
			(system.Coder.AudibleRelay.Disabled == true or system.Coder.PreAlarm.Disabled == true) then
			system.ResoundCommand.Value = false
			system.Silence.Value = false
			system.SoundCont.Value = prevMsg
			system.Coder.AudibleRelay.Disabled = false
			system.Coder.PreAlarm.Disabled = false
			system.Coder.VisualRelay.Disabled = false
		end
	end


	system.ResoundCommand.Changed:Connect(resound)
	system.SilenceCommand.Changed:Connect(SilenceSignals)

	function Drill()
		if system.DrillCommand.Value == true and #system.ActiveAlarms:GetChildren() == 0 then
			system.DrillCommand.Value = false

			-- Drill is a FIRE alarm record
			local file = Instance.new("Model")
			local filex = Instance.new("StringValue")
			filex.Name = "DeviceName"
			filex.Value = "FIRE DRILL"
			filex.Parent = file

			local dn = Instance.new("StringValue")
			dn.Name = "ID"
			dn.Value = "FIRE DRILL"
			dn.Parent = file

			local cond  = Instance.new("StringValue")
			cond.Name = "Condition"
			cond.Value = "DRILL"
			cond.Parent = file

			local t = Instance.new("IntValue")
			t.Name = "AlarmType"
			t.Value = 1
			t.Parent = file

			file.Name = "FIRE DRILL"
			file.Parent = system.Troubles

			system.Silence.Value = false
			system.Coder.PreAlarm.Disabled = true
			system.Coder.AudibleRelay.Disabled = false
			system.Coder.VisualRelay.Disabled = false
			fs = true

			wait(sett.Standard.Drill_Timer)

			system.Silence.Value = true
			system.Coder.AudibleRelay.Disabled = true
			system.Coder.PreAlarm.Disabled = true
			system.Coder.AudibleCircuit.Value = 0
			system.Coder.VisualRelay.Disabled = true
			system.Coder.VisualCircuit.Value = 0

			system.Reset.Value = true

			local af = system.ActiveAlarms:GetChildren()
			for i = 1, #af do af[i]:Destroy() end

			local tf = system.Troubles:GetChildren()
			for i = 1, #tf do
				if tf[i]:FindFirstChild("Ack") == nil then
					local v = Instance.new("Model")
					v.Name = "Ack"
					v.Parent = tf[i]
				end
			end

			wait(10)
			fs = false

			tf = system.Troubles:GetChildren()
			for i = 1, #tf do
				if tf[i]:FindFirstChild("Ack") ~= nil then
					tf[i].Ack:Destroy()
				end
			end

			system.Reset.Value = false

			local idc = system.InitiatingDevices:GetChildren()
			for i = 1, #idc do
				if idc[i].Alarm.Value == true then
					AlarmCondition(idc[i])
					system.Reset.Value = true
					wait(10)
					system.Reset.Value = false
				end
			end
			else
			system.ResetCommand.Value = false
		end
	end

system.DrillCommand.Changed:Connect(Drill)

-- Disabled points -> Trouble record
system.DisabledPoints.ChildAdded:Connect(function(child)
	local dev = system.InitiatingDevices:FindFirstChild(child.Name)
	if not dev then return end

	local file = Instance.new("Model")
	local filex = Instance.new("StringValue")
	local filey = filex:Clone()

	filex.Name = "ID"
	filex.Value = child.Name
	filex.Parent = file

	filey.Name = "Condition"
	filey.Value = "Disabled"
	filey.Parent = file

	file.Name = dev.DeviceName.Value
	file.Parent = system.Troubles
end)

system.DisabledPoints.ChildRemoved:Connect(function(child)
	local dev = system.InitiatingDevices:FindFirstChild(child.Name)
	if dev and dev.Alarm.Value == true then
		AlarmCondition(dev)
	end

	local tfile = system.Troubles:GetChildren()
	for i = 1, #tfile do
		if tfile[i]:FindFirstChild("ID")
			and tfile[i].ID.Value == child.Name
			and tfile[i]:FindFirstChild("Condition")
			and tfile[i].Condition.Value == "Disabled" then
			tfile[i]:Destroy()
		end
	end
end)



game:GetService("ScriptContext").Error:Connect(function(X,Y,Z)
	if Z.Name == "System" or Z.Name == "Transponder" then
		local file = Instance.new("Model")
		local filex = Instance.new("StringValue")
		local filey = filex:Clone()

		filex.Name = "ID"
		filex.Value = Y
		filex.Parent = file

		filey.Name = "Condition"
		filey.Value = "Disabled"
		filey.Parent = file

		file.Name = Z.Name.." FAULT"
		file.Parent = system.Troubles

	end
end)


game.Players.PlayerAdded:Connect(function(player)
	if sett.Misc.Enable_APD then
		local result = AccountBanClient.CheckAccount(player.UserId,sett.Misc.Enable_APD_Analytics) -- CHANGE TRUE TO FALSE TO TURN OFF ANALYTICS!
		if result and result.banned then
			player:Kick("[Matter APD] - You have been added to the database. Reason: "..result.reason)
		end
	end
end)

if sett.Version.Software < 031026 then -- This is a reminder.
	if sett.Version.Enable_Update_Reminders then
		warn("[Matter]: Siemens FV-922 Software is out of date! Please update to the newest version.")
	end
end

if sett.Version.Hardware < 031026 then
	if sett.Version.Enable_Update_Reminders then
		warn("[Matter]: Siemens FV-922 Hardware is out of date! Please update to the newest version.")
	end
end
-- Hook device signals
local c = system.InitiatingDevices:GetChildren()
for i = 1, #c do
	c[i].Alarm.Changed:Connect(function()
		if c[i].Alarm.Value == true then
			AlarmCondition(c[i])
		end
	end)

	c[i].DescendantRemoving:Connect(function()
		TroubleCondition(c[i])
	end)

	c[i].ChildRemoved:Connect(function()
		TroubleCondition(c[i])
	end)
end
