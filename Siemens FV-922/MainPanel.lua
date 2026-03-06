local trans  = script.Parent
local system = trans.Parent
local SystemConfig = require(system.System.SystemConfig)
local HttpService = game:GetService("HttpService")
local conf = SystemConfig

system.System.SystemConfig:Destroy()
warn("[Siemens FV-922]: System Settings Initialized.")
-- ─────────────────────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────────────────────
local input       = ""
local capacity    = 0
local numpaden    = false
local numprefix   = ""
local home        = true
local locked      = false
local trtr        = false
local ServerStarted = false

local newalarm     = ""
local newalarmType = ""

local sounderMode   = "OFF"
local sounderThread = nil
local ledFlashThreads = {}

local accessLevel    = 0
local accessTimeout  = nil
local PIN_LEVEL2     = conf.Users.LEVEL_2
local PIN_LEVEL3     = conf.Users.LEVEL_3
local pinEcon        = nil
local pinOnSuccess   = nil

local title = conf.Preferences.System_Title or "Siemens FV-922"
local WEBHOOK_URL = conf.Communicator.Webhook_URL or nil
local COLOR_MAP = {
	[1] = 16711680, -- Red    (#FF0000)
	[2] = 16744272, -- Orange (#FF6810)
	[3] = 16776960, -- Yellow (#FFFF00)
	[4] = 255,      -- Blue   (#0000FF)
}


local backlightThread  = nil
local BACKLIGHT_TIMEOUT = 300

local eventMemory    = {}
local EVENT_MEMORY_MAX = 500
local eventMemPage   = 1
local EVENT_LINES_PER_PAGE = 6

local ackIndex       = 1
local ackFolderIndex = 1
local ackPending     = false

local ackFolders = {
	{ folderName = "ActiveAlarms", label = "ALARM"   },
	{ folderName = "GasAlarms",    label = "GAS"     },
	{ folderName = "Supervisory",  label = "SUP"     },
	{ folderName = "Troubles",     label = "TROUBLE" },
}

local buzzerVolume      = 3
local displayBrightness = 3
local walkTestActive    = false
local walkTestDevices   = {}

local softkey1Action = nil
local softkey2Action = nil
local softkey3Action = nil

local econTable = {}

-- ─────────────────────────────────────────────────────────────
-- FOLDER SETUP
-- ─────────────────────────────────────────────────────────────
local function ensureFolder(name)
	local f = system:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = system
	end
	return f
end
ensureFolder("GasAlarms")
ensureFolder("Supervisory")
ensureFolder("DisabledPoints")
ensureFolder("Troubles")
ensureFolder("ActiveAlarms")
ensureFolder("InitiatingDevices")
ensureFolder("Peripherals")

-- ─────────────────────────────────────────────────────────────
-- UTILITY
-- ─────────────────────────────────────────────────────────────
local function setLine(n, v)
	trans.Display["Line"..n].Value = tostring(v)
end
local function clearLines(from, to)
	for i = from, to do setLine(i, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~") end
end
local function disconnectEcon()
	if econ ~= nil then econ:Disconnect(); econ = nil end
end
local function disconnectAll()
	disconnectEcon()
	for _, c in ipairs(econTable) do pcall(function() c:Disconnect() end) end
	econTable = {}
	if pinEcon then pinEcon:Disconnect(); pinEcon = nil end
end
local function countEvents()
	local function c(name)
		local f = system:FindFirstChild(name)
		return f and #f:GetChildren() or 0
	end
	return c("ActiveAlarms"), c("GasAlarms"), c("Supervisory"), c("Troubles")
end
local function folderChildren(name)
	local f = system:FindFirstChild(name)
	if not f then return {} end
	return f:GetChildren()
end
local function hasUnackInFolder(name)
	for _, ev in ipairs(folderChildren(name)) do
		if ev:FindFirstChild("Ack") == nil then return true end
	end
	return false
end
local function hasAnyUnack()
	return hasUnackInFolder("ActiveAlarms") or hasUnackInFolder("GasAlarms")
		or hasUnackInFolder("Supervisory")  or hasUnackInFolder("Troubles")
end
local function pickHomeMode(alm, gas, sup, tbl)
	if alm > 0 then return "ALARM" end
	if gas > 0 then return "GAS" end
	if sup > 0 then return "SUP" end
	if tbl > 0 then return "TROUBLE" end
	return nil
end
local function fmtCount(n)
	local s = tostring(n)
	return string.rep("0", math.max(0, 3 - #s)) .. s
end
local function buildStatusHeader(alm, gas, sup, tbl)
	return "~~~~~~"..fmtCount(alm).."~ALM~~"..fmtCount(gas).."~GAS~~"..fmtCount(sup).."~SUP~~"..fmtCount(tbl).."~TBL~~~~~~"
end
local function logEvent(evType, deviceName, condition)
	if #eventMemory >= EVENT_MEMORY_MAX then table.remove(eventMemory, 1) end
	table.insert(eventMemory, { type=evType, device=deviceName, condition=condition, timestamp=os.time() })
end
local function accessLevelName(lvl)
	if lvl == 0 then return "Guest"
	elseif lvl == 1 then return "Operator"
	elseif lvl == 2 then return "Maintenance"
	elseif lvl == 3 then return "Engineer" end
	return "Unknown"
end


local function sendDiscordEmbed(EventType, ColorCode, DeviceAddress, DeviceName)
	local color = COLOR_MAP[ColorCode] or 0 -- Falls back to black if invalid code

	local embedData = {
		embeds = {
			{
				title = EventType,
				color = color,
				fields = {
					{
						name = "Device Name",
						value = DeviceName,
						inline = true
					},
					{
						name = "Device Address",
						value = DeviceAddress,
						inline = true
					},
				},
				timestamp = DateTime.now():ToIsoDate()
			}
		}
	}

	local success, err = pcall(function()
		HttpService:PostAsync(
			WEBHOOK_URL,
			HttpService:JSONEncode(embedData),
			Enum.HttpContentType.ApplicationJson
		)
	end)

	if not success then
		warn("Failed to send Discord embed: " .. tostring(err))
	end
end
-- ─────────────────────────────────────────────────────────────
-- BACKLIGHT
-- ─────────────────────────────────────────────────────────────
local function activateBacklight()
	local bl = trans:FindFirstChild("BacklightActive")
	if bl then bl.Value = true end
	if backlightThread then task.cancel(backlightThread); backlightThread = nil end
	if not hasAnyUnack() then
		backlightThread = task.delay(BACKLIGHT_TIMEOUT, function()
			local b = trans:FindFirstChild("BacklightActive")
			if b then b.Value = false end
		end)
	end
end

-- ─────────────────────────────────────────────────────────────
-- LED CONTROL
-- ─────────────────────────────────────────────────────────────
local function stopLEDFlash(ledName)
	if ledFlashThreads[ledName] then task.cancel(ledFlashThreads[ledName]); ledFlashThreads[ledName] = nil end
end
local function ledActivate(led, state)
	if not led then return end
	if led:FindFirstChild("Activate") then led.Activate.Value = state end
end
local function setLEDSteady(led)
	if not led then return end
	stopLEDFlash(led.Name)
	ledActivate(led, true)
end
local function setLEDOff(led)
	if not led then return end
	stopLEDFlash(led.Name)
	ledActivate(led, false)
end
local function setLEDFlash(led, interval)
	if not led then return end
	stopLEDFlash(led.Name)
	local on = true
	ledFlashThreads[led.Name] = task.spawn(function()
		while true do
			ledActivate(led, on)
			on = not on
			task.wait(interval or 0.5)
		end
	end)
end
local function getLED(name)
	local leds = trans:FindFirstChild("LEDs")
	if not leds then return nil end
	return leds:FindFirstChild(name)
end

local function updateAllLEDs()
	local alm, gas, sup, tbl = countEvents()

	local almLED = getLED("AlarmLED")
	if almLED then
		if alm > 0 then (hasUnackInFolder("ActiveAlarms") and setLEDFlash or setLEDSteady)(almLED, 0.5)
		else setLEDOff(almLED) end
	end

	local gasLED = getLED("GasLED")
	if gasLED then
		if gas > 0 then (hasUnackInFolder("GasAlarms") and setLEDFlash or setLEDSteady)(gasLED, 0.5)
		else setLEDOff(gasLED) end
	end

	local supLED = getLED("SupvLED")
	if supLED then
		if sup > 0 then (hasUnackInFolder("Supervisory") and setLEDFlash or setLEDSteady)(supLED, 0.5)
		else setLEDOff(supLED) end
	end

	local tblLED = getLED("TroubleLED")
	if tblLED then
		if tbl > 0 then (hasUnackInFolder("Troubles") and setLEDFlash or setLEDSteady)(tblLED, 0.5)
		else setLEDOff(tblLED) end
	end

	local disLED = getLED("DisableLED")
	if disLED then
		local dp = system:FindFirstChild("DisabledPoints")
		if dp and #dp:GetChildren() > 0 then setLEDSteady(disLED) else setLEDOff(disLED) end
	end

	local ackLED = getLED("AckLED")
	if ackLED then
		if hasAnyUnack() then setLEDFlash(ackLED, 0.25) else setLEDOff(ackLED) end
	end

	local rstLED = getLED("ResetLED")
	if rstLED then
		local total = alm + gas + sup + tbl
		if total > 0 and not hasAnyUnack() then setLEDFlash(rstLED, 0.25) else setLEDOff(rstLED) end
	end

	local audLED = getLED("AudiblesLED")
	if audLED then
		local silenced = system:FindFirstChild("Silenced")
		local isSil = silenced and silenced.Value == true
		if (alm > 0 or gas > 0) and not isSil then setLEDSteady(audLED) else setLEDOff(audLED) end
	end

	local silLED = getLED("SilencedLED")
	if silLED then
		local silenced = system:FindFirstChild("Silenced")
		if silenced and silenced.Value == true then setLEDSteady(silLED) else setLEDOff(silLED) end
	end

	local gndLED = getLED("GroundLED")
	if gndLED then
		local gf = system:FindFirstChild("GroundFault")
		if gf and gf.Value == true then setLEDFlash(gndLED, 0.5) else setLEDOff(gndLED) end
	end

	local pwrLED = trans:FindFirstChild("PowerLED")
	if pwrLED then
		local onBat = system:FindFirstChild("OnBattery")
		if onBat and onBat.Value == true then setLEDFlash(pwrLED, 1.0) else setLEDSteady(pwrLED) end
	end
end

-- ─────────────────────────────────────────────────────────────
-- SOUNDER
-- ─────────────────────────────────────────────────────────────
local function getSoundObject()
	local s = trans:FindFirstChild("Sounder")
	if s then
		local p = s:FindFirstChild("Piezo")
		if p and p:IsA("Sound") then return p end
		if s:IsA("Sound") then return s end
	end
	s = trans:FindFirstChild("LEDPiezo")
	if s and s:IsA("Sound") then return s end
	if s then local c = s:FindFirstChildWhichIsA("Sound"); if c then return c end end
	return nil
end
local function stopSounder()
	if sounderThread then task.cancel(sounderThread); sounderThread = nil end
	sounderMode = "OFF"
	local snd = getSoundObject()
	if snd then pcall(function() snd:Stop() end) end
end
local function updateSounder()
	local alm, gas, sup, tbl = countEvents()
	local snd = getSoundObject()
	local silenced = system:FindFirstChild("Silenced")
	if silenced and silenced.Value == true then stopSounder(); return end
	local unackFire = hasUnackInFolder("ActiveAlarms") or hasUnackInFolder("GasAlarms")
	local unackSup  = hasUnackInFolder("Supervisory")  or hasUnackInFolder("Troubles")
	if unackFire then
		if sounderMode ~= "STEADY" then
			stopSounder(); sounderMode = "STEADY"
			if snd then pcall(function() snd.Looped = true; snd:Play() end) end
		end
	elseif unackSup then
		if sounderMode ~= "PULSE" then
			stopSounder(); sounderMode = "PULSE"
			sounderThread = task.spawn(function()
				while sounderMode == "PULSE" do
					if snd then pcall(function() snd:Play() end) end
					task.wait(1)
					if snd then pcall(function() snd:Stop() end) end
					task.wait(3)
				end
			end)
		end
	elseif (alm + gas + sup + tbl) == 0 then
		stopSounder()
	end
end

-- ─────────────────────────────────────────────────────────────
-- ACCESS LEVEL
-- ─────────────────────────────────────────────────────────────
local function clearAccessTimeout()
	if accessTimeout then task.cancel(accessTimeout); accessTimeout = nil end
end
local function logoutAccess()
	accessLevel = 0; clearAccessTimeout()
end
local function resetAccessTimeout()
	clearAccessTimeout()
	accessTimeout = task.delay(300, function() logoutAccess() end)
end
local function cancelPINInput()
	if pinEcon then pinEcon:Disconnect(); pinEcon = nil end
	pinOnSuccess = nil; numpaden = false; input = ""
end

-- ─────────────────────────────────────────────────────────────
-- FORWARD DECLARATIONS
-- ─────────────────────────────────────────────────────────────
local HomeDisplay, ShowMainMenu, ShowLoginLogout, ShowFunctionsMenu
local ShowBypassMenu, BypassZone, BypassDetector, BypassRemoteTransmission, BypassAlarmActivation, ShowAllZones
local ShowTestMenu, RunDetectorTest, RunWalkTest, RunInstallationTest, RunControlTest, RunLEDTest, RunNACTest
local ShowActivateMenu, ActivateAlarmIndicator, DeactivateAlarmDevices, ActivateResetZone, ActivateEvacControls, RunFireDrill
local ShowInformationMenu, ShowAlarmCounters, ShowZoneInfo, ShowSystemStatus, ShowVersion
local ShowConfigMenu, ShowCodingOptions, AutoConfigurePanel, AutoConfigureCircuit, ChangeCustomerText
local ShowMaintenanceMenu, ShowPointList, ConfirmDeleteEventMemory, ShowSensorSensitivity, ArmDisarmDetectors, ShowMaintenanceReport
local ShowFavorites, ShowTopology, ShowDetectionTree, ShowHardwareTree, ShowControlTree, ShowNetworkTree, ShowOperatingTree
local ShowElementSearch, ShowSearchByCategory
local ShowEventMemory, ShowMessageSummary
local ShowSettingsAdmin, ShowChangePIN, ShowCreatePIN, ShowDeletePIN, ShowSetBuzzerVolume, ShowDisplaySettings
local ShowChangeBrightness, ShowChangeContrast, ShowSystemCommands
local SelectDevice, FetchDevice, TogglePoint, TogglePeripheral

-- ─────────────────────────────────────────────────────────────
-- PIN DIALOG  (spec 5.1, 6.6.1)
-- ─────────────────────────────────────────────────────────────
local function ShowPINDialog(onSuccess, onCancel)
	disconnectAll()
	home = false
	numpaden = true; capacity = 8; input = ""; numprefix = ""
	pinOnSuccess = onSuccess

	setLine(1,  "Login~/~Change~Access~Level~~~~~~~~~~~~~")
	setLine(2,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,  "Enter~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,  "Current:~Level~" .. accessLevel .. "~(" .. accessLevelName(accessLevel) .. ")")
	setLine(6,  "PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(8,  "No~PIN~+~ok~=~Operator~/~Guest~logout~~~")
	setLine(9,  "Delete~with~Clear.~Cancel~with~Exit.~~~~")
	setLine(10, "~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")

	pinEcon = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		local entered = input
		cancelPINInput()
		if entered == "" then
			if accessLevel > 0 then
				logoutAccess()
				setLine(5, "Logged~out.~Level:~0~(Guest)~~~~~~~~~~~~")
			else
				accessLevel = 1; resetAccessTimeout()
				setLine(5, "Level~1~(Operator)~Granted~~~~~~~~~~~~~~")
			end
			setLine(6, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			task.wait(1.5)
			HomeDisplay(); return
		end
		local granted = 0
		if entered == PIN_LEVEL3 then granted = 3
		elseif entered == PIN_LEVEL2 then granted = 2 end
		if granted > 0 then
			accessLevel = granted; resetAccessTimeout()
			setLine(3, "Level~" .. granted .. "~(" .. accessLevelName(granted) .. ")~Granted~~~~~~~~~~~~~~~~")
			setLine(6, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			task.wait(1.5)
			local fn = pinOnSuccess; pinOnSuccess = nil
			if fn then fn() else HomeDisplay() end
		else
			setLine(3, "Incorrect~PIN.~~Please~try~again.~~~~~~~")
			setLine(6, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			task.wait(2)
			if onCancel then onCancel() else HomeDisplay() end
		end
	end)
end

local function requireAccessLevel(needed, onSuccess)
	if accessLevel >= needed then onSuccess(); return end
	ShowPINDialog(function()
		if accessLevel >= needed then onSuccess() else HomeDisplay() end
	end, HomeDisplay)
end

-- ─────────────────────────────────────────────────────────────
-- KEYPAD
-- ─────────────────────────────────────────────────────────────
function NumButtonPress(n)
	if locked then return end
	activateBacklight()
	if not numpaden or string.len(input) > (capacity - 1) then return end
	input = input .. tostring(n)
	if pinEcon then
		setLine(6, "PIN:~" .. string.rep("*", #input))
	else
		setLine(6, tostring(numprefix .. input))
	end
end

local tclax = trans.Buttons:GetChildren()
for i = 1, #tclax do
	if string.sub(tclax[i].Name, 1, 6) == "Button" then
		tclax[i].CD.MouseClick:Connect(function()
			NumButtonPress(string.sub(tclax[i].Name, 7))
		end)
	end
end

trans.Buttons.BTN_Clear.CD.MouseClick:Connect(function()
	if locked then return end
	activateBacklight()
	if not numpaden or string.len(input) == 0 then return end
	input = string.sub(input, 1, string.len(input) - 1)
	if pinEcon then
		setLine(6, "PIN:~" .. string.rep("*", #input))
	else
		setLine(6, tostring(numprefix .. input))
	end
end)

-- ─────────────────────────────────────────────────────────────
-- HOME DISPLAY
-- ─────────────────────────────────────────────────────────────
HomeDisplay = function()
	disconnectAll()
	activateBacklight()
	home = true; input = ""; capacity = 0; numpaden = false; numprefix = ""
	updateAllLEDs(); updateSounder()
	softkey1Action = function() ShowMessageSummary() end
	softkey2Action = function() ShowEventMemory(1) end
	softkey3Action = function() RunLEDTest() end

	if system.Reset.Value == true then
		home = false; newalarm = ""; newalarmType = ""
		setLine(1, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(2, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(3, "Execute~command~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(4, "Reset~Fire~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		clearLines(5, 10); task.wait(2)
		setLine(7, "Command~execution~successful~~~~~~~~~~~~"); task.wait(2)
		setLine(1, "System~Resetting~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(2, title)
		setLine(3, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(4, "~~~~~~~~~~~~~~~~SIEMENS~~~~~~~~~~~~~~~~~")
		clearLines(5, 8)
		setLine(9, "~~~~~Message~~~~~~~Event~~~~~~~LED~~~~~~")
		setLine(10,"~~~~~summary~~~~~~~memory~~~~~~test~~~~~")
		if conf.Communicator.Enabled then
			if conf.Communicator.Reports.System_Reset then
				sendDiscordEmbed("System Reset",4,"Node","Node Operation")
			end
		end
		task.wait(4.5); home = true; return
	end

	local alm, gas, sup, tbl = countEvents()
	local modeLabel = pickHomeMode(alm, gas, sup, tbl)

	if newalarm ~= "" then
		setLine(1, buildStatusHeader(alm, gas, sup, tbl))
		setLine(2, "~~~~~~MN1~ALARM~~GAS~~MN2~~SUP~~TBL~MNT~")
		setLine(3, "!Zone~~~~~~~~~~~~~~~~~~~~~~~~~" .. (newalarmType == "TROUBLE" and "TROUBLE~~~IN" or newalarmType .. "~~~IN"))
		setLine(4, "~Building~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		clearLines(5, 7)
		setLine(8, newalarm)
		setLine(9, "~~~~~Execute~~~~~~Details~~~~~~More~~~~~")
		setLine(10,"~~~~~Commands~~~~~view~~~~~Options~~~~~")
		return
	end

	if modeLabel == nil then
		setLine(1,  "000~~" .. os.date("%m/%d/%Y~~%I:%M~%p"))
		setLine(2,  title)
		setLine(3,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(4,  "~~~~~~~~~~~~~~~~SIEMENS~~~~~~~~~~~~~~~~~")
		setLine(5,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(6,  "~Level:~" .. accessLevel .. "~(" .. accessLevelName(accessLevel) .. ")~~~~~~~~~~~~~~~~~~")
		setLine(7,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(8,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(9,  "~~~~~Message~~~~~~~Event~~~~~~~LED~~~~~~")
		setLine(10, "~~~~~summary~~~~~~~memory~~~~~~test~~~~~")
		return
	end

	setLine(1, buildStatusHeader(alm, gas, sup, tbl))
	setLine(2, "~~~~~~MN1~ALARM~~GAS~~MN2~~SUP~~TBL~MNT~")
	setLine(3, "!Zone~~~~~~~~~~~~~~~~~~~~~~~~~" .. (modeLabel == "TROUBLE" and "TROUBLE~~~IN" or modeLabel .. "~~~IN"))
	setLine(4, "~Building~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(5, 8)
	setLine(9, "~~~~~Execute~~~~~~Details~~~~~~More~~~~~")
	setLine(10,"~~~~~Commands~~~~~view~~~~~Options~~~~~")
end

-- ─────────────────────────────────────────────────────────────
-- MAIN MENU  (spec 3.6)
-- ─────────────────────────────────────────────────────────────
ShowMainMenu = function()
	if locked then return end
	activateBacklight()
	if accessLevel == 0 then
		ShowPINDialog(ShowMainMenu, HomeDisplay); return
	end
	home = false; disconnectAll()
	numpaden = true; capacity = 1; input = ""; numprefix = ""

	setLine(1,  "Main~Menu~~~~~~~~~~~~~Exit~with~Cancel~~")
	setLine(2,  "Level:~" .. accessLevel .. "~(" .. accessLevelName(accessLevel) .. ")~~~~~~~~~~~~~~~~~")
	setLine(3,  "(1)~Message~summary~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,  "(2)~Functions~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,  "(3)~Favorites~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,  "(4)~Topology~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,  "(5)~Element~search~~~~~~~~~~~~~~~~~~~~~~")
	setLine(8,  "(6)~Event~memory~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(9,  "(7)~Login~/~Logout~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10, "(8)~Settings~/~Administration~~~~~~~~~~~")

	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false
		if v == 1 then ShowMessageSummary()
		elseif v == 2 then ShowFunctionsMenu()
		elseif v == 3 then ShowFavorites()
		elseif v == 4 then ShowTopology()
		elseif v == 5 then ShowElementSearch()
		elseif v == 6 then ShowEventMemory(1)
		elseif v == 7 then ShowLoginLogout()
		elseif v == 8 then ShowSettingsAdmin()
		else HomeDisplay() end
	end)
end
trans.Buttons.BTN_Menu.CD.MouseClick:Connect(ShowMainMenu)

-- ─────────────────────────────────────────────────────────────
-- LOGIN / LOGOUT  (spec 5.1)
-- ─────────────────────────────────────────────────────────────
ShowLoginLogout = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""

	setLine(1,  "Login~/~Logout~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,  "Current:~Level~" .. accessLevel .. "~(" .. accessLevelName(accessLevel) .. ")")
	setLine(3,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,  "(1)~Operator~(no~PIN)~~~~~~~~~~~~~~~~~~~")
	setLine(5,  "(2)~Maintenance~(PIN)~~~~~~~~~~~~~~~~~~~")
	setLine(6,  "(3)~Engineer~(PIN)~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,  "(4)~Logout~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(8,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(9,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10, "~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~Select~~")

	softkey1Action = ShowMainMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then
			accessLevel = 1; resetAccessTimeout()
			setLine(2, "Level~1~(Operator)~Granted~~~~~~~~~~~~~~"); task.wait(1.5); HomeDisplay()
		elseif v == 2 then
			ShowPINDialog(function() setLine(2, "Level~2~Granted.~~~~~~~~~~~~~~~~~~~~~"); task.wait(1.5); HomeDisplay() end, ShowMainMenu)
		elseif v == 3 then
			ShowPINDialog(function() setLine(2, "Level~3~Granted.~~~~~~~~~~~~~~~~~~~~~"); task.wait(1.5); HomeDisplay() end, ShowMainMenu)
		elseif v == 4 then
			logoutAccess(); setLine(2, "Logged~out.~Level:~0~(Guest)~~~~~~~~~~~"); task.wait(1.5); HomeDisplay()
		else HomeDisplay() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- MESSAGE SUMMARY
-- ─────────────────────────────────────────────────────────────
ShowMessageSummary = function()
	disconnectAll(); home = false
	local alm, gas, sup, tbl = countEvents()
	local dp = system:FindFirstChild("DisabledPoints") and #system.DisabledPoints:GetChildren() or 0
	local gf = system:FindFirstChild("GroundFault") and system.GroundFault.Value and 1 or 0

	setLine(1,  "Message~Summary~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,  "~Fire~Alarms:~~~~~~~~~~~~~~~~~~~~" .. string.format("%3d", alm))
	setLine(4,  "~Gas~Alarms:~~~~~~~~~~~~~~~~~~~~~" .. string.format("%3d", gas))
	setLine(5,  "~Supervisory:~~~~~~~~~~~~~~~~~~~~" .. string.format("%3d", sup))
	setLine(6,  "~Troubles:~~~~~~~~~~~~~~~~~~~~~~~" .. string.format("%3d", tbl))
	setLine(7,  "~Disabled~Points:~~~~~~~~~~~~~~~~" .. string.format("%3d", dp))
	setLine(8,  "~Ground~Faults:~~~~~~~~~~~~~~~~~~" .. string.format("%3d", gf))
	setLine(9,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10, "~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Refresh~")
	softkey1Action = HomeDisplay; softkey3Action = ShowMessageSummary
end

-- ─────────────────────────────────────────────────────────────
-- FUNCTIONS MENU
-- ─────────────────────────────────────────────────────────────
ShowFunctionsMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""

	setLine(1,  "Functions~~~~~~~~~~~~~~~~~~~~~~~~~~AL:" .. accessLevel)
	setLine(2,  "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,  "(1)~Enable~/~Bypass~(AL2)~~~~~~~~~~~~~~~")
	setLine(4,  "(2)~Test~~~~~~~~~~~~~~~~~~~~~(AL2)~~~~~~")
	setLine(5,  "(3)~Activate~/~Deactivate~~~(AL2)~~~~~~~")
	setLine(6,  "(4)~Information~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,  "(5)~Configuration~~~~~~~~~~~(AL3)~~~~~~~")
	setLine(8,  "(6)~Maintenance~~~~~~~~~~~~~(AL2)~~~~~~~")
	clearLines(9, 9)
	setLine(10, "~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")

	softkey1Action = ShowMainMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then requireAccessLevel(2, ShowBypassMenu)
		elseif v == 2 then requireAccessLevel(2, ShowTestMenu)
		elseif v == 3 then requireAccessLevel(2, ShowActivateMenu)
		elseif v == 4 then ShowInformationMenu()
		elseif v == 5 then requireAccessLevel(3, ShowConfigMenu)
		elseif v == 6 then requireAccessLevel(2, ShowMaintenanceMenu)
		else HomeDisplay() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- ENABLE / BYPASS MENU
-- ─────────────────────────────────────────────────────────────
ShowBypassMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""

	setLine(1,  "Enable~/~Bypass~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,  "Select~element~category:~~~~~~~~~~~~~~~~")
	setLine(3,  "(1)~Zone~(Detector~Zone)~~~~~~~~~~~~~~~~")
	setLine(4,  "(2)~Detector~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,  "(3)~Remote~Transmission~Fire~~~~~~~~~~~~")
	setLine(6,  "(4)~Bypass~Alarm~Activation~~~~~~~~~~~~~")
	clearLines(7, 9)
	setLine(10, "~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")

	softkey1Action = ShowFunctionsMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then BypassZone()
		elseif v == 2 then BypassDetector()
		elseif v == 3 then BypassRemoteTransmission()
		elseif v == 4 then BypassAlarmActivation()
		else ShowBypassMenu() end
	end)
end

BypassZone = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Zone~ID:~"

	setLine(1, "Enable~/~Bypass~-~Zone~~~~~~~~~~~~~~~~~~")
	setLine(2, "Enter~address~(ok~for~all):~~~~~~~~~~~~~")
	clearLines(3, 5)
	setLine(6, "Zone~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7, 9)
	setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")

	softkey1Action = ShowBypassMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		if input == "" then ShowAllZones()
		else TogglePoint(input); task.wait(1.5); ShowBypassMenu() end
	end)
end

BypassDetector = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Det~ID:~"

	setLine(1, "Enable~/~Bypass~-~Detector~~~~~~~~~~~~~~")
	setLine(2, "Enter~detector~address:~~~~~~~~~~~~~~~~~")
	clearLines(3, 5); setLine(6, "Det~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7, 9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")

	softkey1Action = ShowBypassMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		if input ~= "" then TogglePoint(input); task.wait(1.5) end
		ShowBypassMenu()
	end)
end

BypassRemoteTransmission = function()
	disconnectAll(); home = false
	local rtVal = system:FindFirstChild("RemoteTransmissionBypassed")
	if not rtVal then
		rtVal = Instance.new("BoolValue"); rtVal.Name = "RemoteTransmissionBypassed"; rtVal.Parent = system
	end
	rtVal.Value = not rtVal.Value
	setLine(1, "Remote~Transmission~Fire~~~~~~~~~~~~~~~~")
	setLine(3, "Command~executed:~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4, "Remote~TX~Fire:~" .. (rtVal.Value and "BYPASSED" or "ENABLED~"))
	clearLines(2,2); clearLines(5,9); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	task.wait(2); ShowBypassMenu()
end

BypassAlarmActivation = function()
	disconnectAll(); home = false
	local aaVal = system:FindFirstChild("AlarmActivationBypassed")
	if not aaVal then
		aaVal = Instance.new("BoolValue"); aaVal.Name = "AlarmActivationBypassed"; aaVal.Parent = system
	end
	aaVal.Value = not aaVal.Value
	setLine(1, "Alarm~Activation~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3, "Command~executed:~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4, "Alarm~Activation:~" .. (aaVal.Value and "BYPASSED" or "ENABLED~"))
	clearLines(2,2); clearLines(5,9); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	task.wait(2); ShowBypassMenu()
end

ShowAllZones = function()
	disconnectAll(); home = false
	local devices = system.InitiatingDevices:GetChildren()
	local dp = system.DisabledPoints
	setLine(1, "All~Zones~-~Enable~/~Bypass~~~~~~~~~~~~~")
	setLine(2, "ID~~~~~~~Status~~~Name~~~~~~~~~~~~~~~~~~~")
	if #devices == 0 then
		setLine(3, "~No~initiating~devices~configured.~~~~~~"); clearLines(4,9)
	else
		for i = 1, math.min(7, #devices) do
			local dev = devices[i]; local id = dev.Name
			local status = dp:FindFirstChild(id) and "BYPASSED" or "ACTIVE~~"
			local name = (dev:FindFirstChild("DeviceName") and dev.DeviceName.Value) or id
			setLine(i+2, string.sub(id.."~~"..status.."~~"..name, 1, 40))
		end
		if #devices > 7 then setLine(10,"~~("..(#devices-7).."+~more~-~use~SD~button)~~~~~~~~~~")
		else clearLines(#devices+3, 10) end
	end
	softkey1Action = ShowBypassMenu
end

-- ─────────────────────────────────────────────────────────────
-- TEST MENU
-- ─────────────────────────────────────────────────────────────
ShowTestMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""

	setLine(1, "Test~Menu~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2, "(1)~Detector~test~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3, "(2)~Walk~test~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4, "(3)~Installation~test~~~~~~~~~~~~~~~~~~~")
	setLine(5, "(4)~Control~test~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6, "(5)~Test~Indicators~(LED~test)~~~~~~~~~~")
	setLine(7, "(6)~Audible~&~Visual~NAC~Test~~~~~~~~~~~")
	clearLines(8,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")

	softkey1Action = ShowFunctionsMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then RunDetectorTest()
		elseif v == 2 then RunWalkTest()
		elseif v == 3 then RunInstallationTest()
		elseif v == 4 then RunControlTest()
		elseif v == 5 then RunLEDTest()
		elseif v == 6 then RunNACTest()
		else ShowTestMenu() end
	end)
end

RunDetectorTest = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Det~ID:~"
	setLine(1, "Detector~Test~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2, "Enter~detector~ID~to~test:~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Det~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowTestMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		local id = input; local dev = system.InitiatingDevices:FindFirstChild(id)
		if dev then
			setLine(1, "Detector~Test~-~ACTIVE~~~~~~~~~~~~~~~~~~")
			setLine(4, "Testing:~"..(dev:FindFirstChild("DeviceName") and dev.DeviceName.Value or id))
			local testAlm = Instance.new("Model"); testAlm.Name = "TEST_"..id
			local dn = Instance.new("StringValue"); dn.Name = "DeviceName"
			dn.Value = "[TEST]~"..(dev:FindFirstChild("DeviceName") and dev.DeviceName.Value or id)
			dn.Parent = testAlm; testAlm.Parent = system.ActiveAlarms
			task.wait(5); testAlm:Destroy()
			setLine(4, "Test~Complete.~~Result:~OK~~~~~~~~~~~~~~"); task.wait(2)
		else
			setLine(6, "ID~"..id.."~invalid."); task.wait(2)
		end
		ShowTestMenu()
	end)
end

RunWalkTest = function()
	disconnectAll(); home = false
	walkTestActive = true; walkTestDevices = {}
	setLine(1, "Walk~Test~-~ACTIVE~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2, "Activate~each~detector~individually.~~~~")
	setLine(3, "Alarms~will~NOT~activate~outputs.~~~~~~~")
	setLine(4, "System~will~not~transmit~alarms.~~~~~~~~")
	setLine(5, "Devices~tested:~0~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(6,9); setLine(10,"~~~~~End~Walk~Test~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = function()
		walkTestActive = false; walkTestDevices = {}
		setLine(1, "Walk~Test~Complete~~~~~~~~~~~~~~~~~~~~~~"); task.wait(2); ShowTestMenu()
	end
end

RunInstallationTest = function()
	disconnectAll(); home = false
	setLine(1, "Installation~Test~~~~~~~~~~~~~~~~~~~AL3")
	if accessLevel < 3 then
		setLine(4, "Access~Level~3~required.~~~~~~~~~~~~~~~~"); task.wait(2); ShowTestMenu(); return
	end
	setLine(2, "Testing~all~outputs.~Please~wait.~~~~~~~"); clearLines(3,9); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	task.wait(3); setLine(3,"Audible~outputs:~OK~~~~~~~~~~~~~~~~~~~~~"); task.wait(2)
	setLine(4,"Visual~outputs:~OK~~~~~~~~~~~~~~~~~~~~~~"); task.wait(2)
	setLine(5,"Installation~Test~Complete.~~~~~~~~~~~~~"); task.wait(2); ShowTestMenu()
end

RunControlTest = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1, "Control~Test~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2, "(1)~Test~Audible~Relay~~~~~~~~~~~~~~~~~~~")
	setLine(3, "(2)~Test~Visual~Relay~~~~~~~~~~~~~~~~~~~~")
	setLine(4, "(3)~Test~Both~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(5,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowTestMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 or v == 3 then
			setLine(5, "Audible~relay~test~active~~~~~~~~~~~~~~~")
			pcall(function() system.Coder.AudibleRelay.Disabled = false end)
			task.wait(10)
			pcall(function() system.Coder.AudibleRelay.Disabled = true end)
			setLine(5, "Audible~relay~complete.~~~~~~~~~~~~~~~~~")
		end
		if v == 2 or v == 3 then
			setLine(6, "Visual~relay~test~active~~~~~~~~~~~~~~~~")
			pcall(function() system.Coder.VisualRelay.Disabled = false end)
			task.wait(10)
			pcall(function() system.Coder.VisualRelay.Disabled = true end)
			setLine(6, "Visual~relay~complete.~~~~~~~~~~~~~~~~~~")
		end
		task.wait(1.5); ShowTestMenu()
	end)
end

RunLEDTest = function()
	disconnectAll(); home = false
	setLine(1, "LED~Test~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2, "Phase~1:~All~LEDs~ON~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,9); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	for _, led in ipairs(trans.LEDs:GetDescendants()) do
		pcall(function() if led:FindFirstChild("Activate") then led.Activate.Value = true end end)
	end
	local pwrLED = trans:FindFirstChild("PowerLED")
	if pwrLED and pwrLED:IsA("BasePart") then pwrLED.BrickColor = BrickColor.new("Lime green") end
	task.wait(3)
	setLine(2, "Phase~2:~All~LEDs~OFF~~~~~~~~~~~~~~~~~~~")
	for _, led in ipairs(trans.LEDs:GetDescendants()) do
		pcall(function() if led:FindFirstChild("Activate") then led.Activate.Value = false end end)
	end
	if pwrLED and pwrLED:IsA("BasePart") then pwrLED.BrickColor = BrickColor.new("Really black") end
	task.wait(3)
	setLine(2, "LED~Test~Complete.~~~~~~~~~~~~~~~~~~~~~~"); task.wait(2)
	updateAllLEDs(); HomeDisplay()
end

RunNACTest = function()
	disconnectAll(); home = false
	setLine(1, "AUDIBLE~AND~VISUAL~NAC~TEST~IN~PROGRESS~"); clearLines(2,10); task.wait(3)
	setLine(2, "AUDIBLE~PORTION~ACTIVE~~~~~~~~~~~~~~~~~~")
	pcall(function() system.Coder.AudibleRelay.Disabled = false end); task.wait(10)
	pcall(function() system.Coder.AudibleRelay.Disabled = true end)
	setLine(2, "AUDIBLE~PORTION~COMPLETED~~~~~~~~~~~~~~~")
	setLine(3, "VISUAL~PORTION~ACTIVE~~~~~~~~~~~~~~~~~~~")
	pcall(function() system.Coder.VisualRelay.Disabled = false end); task.wait(10)
	pcall(function() system.Coder.VisualRelay.Disabled = true end)
	setLine(3, "VISUAL~PORTION~COMPLETED~~~~~~~~~~~~~~~~")
	setLine(4, "SYSTEM~WILL~RESET~~~~~~~~~~~~~~~~~~~~~~~"); task.wait(3)
	system.Reset.Value = true; task.wait(8.5); system.Reset.Value = false
end

-- ─────────────────────────────────────────────────────────────
-- ACTIVATE / DEACTIVATE MENU
-- ─────────────────────────────────────────────────────────────
ShowActivateMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1, "Activate~/~Deactivate~~~~~~~~~~~~~~~~~~~")
	setLine(2, "(1)~Activate~Alarm~Indicator~~~~~~~~~~~~")
	setLine(3, "(2)~Deactivate~Alarm~Devices~~~~~~~~~~~~")
	setLine(4, "(3)~Activate~/~Reset~Zone~~~~~~~~~~~~~~~")
	setLine(5, "(4)~Activate~Evac~Controls~~~~~~~~~~~~~~")
	setLine(6, "(5)~Fire~Drill~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowFunctionsMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ActivateAlarmIndicator()
		elseif v == 2 then DeactivateAlarmDevices()
		elseif v == 3 then ActivateResetZone()
		elseif v == 4 then ActivateEvacControls()
		elseif v == 5 then RunFireDrill()
		else ShowActivateMenu() end
	end)
end

ActivateAlarmIndicator = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Zone~ID:~"
	setLine(1,"Activate~Alarm~Indicator~~~~~~~~~~~~~~~~")
	setLine(2,"Enter~zone~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Zone~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowActivateMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		if input ~= "" then
			local ev = Instance.new("Model"); ev.Name = "ManualAct_"..input
			local dn = Instance.new("StringValue"); dn.Name = "DeviceName"; dn.Value = "Manual~Act~Zone~"..input; dn.Parent = ev
			ev.Parent = system.Supervisory; task.wait(1)
			setLine(7, "Command~executed~successfully.~~~~~~~~~~"); task.wait(1.5)
		end
		ShowActivateMenu()
	end)
end

DeactivateAlarmDevices = function()
	disconnectAll(); home = false
	setLine(1,"Deactivate~Alarm~Devices~~~~~~~~~~~~~~~~")
	setLine(2,"Silence~all~active~outputs.~~~~~~~~~~~~~")
	setLine(3,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"Press~OK~to~confirm,~Cancel~to~abort.~~~")
	clearLines(5,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowActivateMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; disconnectEcon()
		system.SilenceCommand.Value = true
		local silVal = system:FindFirstChild("Silenced")
		if not silVal then silVal = Instance.new("BoolValue"); silVal.Name = "Silenced"; silVal.Parent = system end
		silVal.Value = true; stopSounder(); updateAllLEDs()
		setLine(4,"Alarm~devices~deactivated.~~~~~~~~~~~~~~"); task.wait(2); ShowActivateMenu()
	end)
end

ActivateResetZone = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Zone~ID:~"
	setLine(1,"Activate~/~Reset~Zone~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Enter~zone~address:~~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Zone~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowActivateMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		if input ~= "" then
			for _, folder in ipairs({"ActiveAlarms","GasAlarms"}) do
				local f = system:FindFirstChild(folder)
				if f then
					for _, ev in ipairs(f:GetChildren()) do
						local zn = ev:FindFirstChild("Zone")
						if zn and zn.Value == input then ev:Destroy() end
					end
				end
			end
			setLine(6,"Zone~"..input.."~reset.~~~~~~~~~~~~~~~~~~"); task.wait(1.5)
		end
		ShowActivateMenu()
	end)
end

ActivateEvacControls = function()
	disconnectAll(); home = false
	setLine(1,"Activate~Evac~Controls~~~~~~~~~~~~~~~~~~")
	setLine(2,"Activates~evacuation~outputs.~~~~~~~~~~~")
	setLine(4,"Press~OK~to~confirm,~Cancel~to~abort.~~~")
	clearLines(3,3); clearLines(5,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowActivateMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; disconnectEcon()
		local evacuCmd = system:FindFirstChild("EvacCommand")
		if not evacuCmd then evacuCmd = Instance.new("BoolValue"); evacuCmd.Name = "EvacCommand"; evacuCmd.Parent = system end
		evacuCmd.Value = true; task.wait(0.1); evacuCmd.Value = false
		setLine(4,"Evac~controls~activated.~~~~~~~~~~~~~~~~"); task.wait(2); ShowActivateMenu()
	end)
end

RunFireDrill = function()
	disconnectAll(); home = false
	setLine(1,"FIRE~DRILL~IN~PROGRESS~~~~~~~~~~~~~~~~~~")
	setLine(2,"ALL~AUDIBLES~AND~VISUALS~WILL~SOUND~~~~~")
	setLine(3,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"Press~Reset~to~end~drill.~~~~~~~~~~~~~~~")
	clearLines(5,10); task.wait(3)
	system.DrillCommand.Value = true
end

-- ─────────────────────────────────────────────────────────────
-- INFORMATION MENU
-- ─────────────────────────────────────────────────────────────
ShowInformationMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Information~~~~~~~~~~~~~~~~~~~~~AL:"..accessLevel)
	setLine(2,"(1)~Alarm~Counters~/~Remote~Trans.~~~~~~~")
	setLine(3,"(2)~Device~Information~~~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Zone~Information~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"(4)~System~Status~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"(5)~Show~Version~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowFunctionsMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowAlarmCounters()
		elseif v == 2 then SelectDevice()
		elseif v == 3 then ShowZoneInfo()
		elseif v == 4 then ShowSystemStatus()
		elseif v == 5 then ShowVersion()
		else ShowInformationMenu() end
	end)
end

ShowAlarmCounters = function()
	disconnectAll(); home = false
	local alm,gas,sup,tbl = countEvents()
	local rtBypassed = system:FindFirstChild("RemoteTransmissionBypassed") and system.RemoteTransmissionBypassed.Value
	setLine(1,"Alarm~Counters~/~Remote~Transmission~~~~")
	setLine(2,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"~Fire~Alarm~Count:~"..string.format("%5d",alm))
	setLine(4,"~Gas~Alarm~Count:~~"..string.format("%5d",gas))
	setLine(5,"~Supervisory~Count:~"..string.format("%4d",sup))
	setLine(6,"~Trouble~Count:~~~~"..string.format("%5d",tbl))
	setLine(7,"~Event~Memory:~~~~~"..string.format("%5d",#eventMemory).."~entries")
	setLine(8,"~Remote~TX~Fire:~"..(rtBypassed and "BYPASSED" or "ENABLED~"))
	setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Refresh~")
	softkey1Action = ShowInformationMenu; softkey3Action = ShowAlarmCounters
end

ShowZoneInfo = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Zone~ID:~"
	setLine(1,"Zone~Information~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Enter~zone~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Zone~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowInformationMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		local id = input; local found = 0
		for _, dev in ipairs(system.InitiatingDevices:GetChildren()) do
			local zn = dev:FindFirstChild("Zone")
			if zn and zn.Value == id then found += 1 end
		end
		setLine(3,"Zone~"..id..":~"..found.."~device(s)~found.")
		setLine(4,"Bypassed:~"..(system.DisabledPoints:FindFirstChild(id) and "YES" or "NO"))
		task.wait(2); ShowInformationMenu()
	end)
end

ShowSystemStatus = function()
	disconnectAll(); home = false
	local alm,gas,sup,tbl = countEvents()
	local dp = system:FindFirstChild("DisabledPoints") and #system.DisabledPoints:GetChildren() or 0
	local onBat = system:FindFirstChild("OnBattery") and system.OnBattery.Value
	local gf = system:FindFirstChild("GroundFault") and system.GroundFault.Value
	local silenced = system:FindFirstChild("Silenced") and system.Silenced.Value
	setLine(1,"System~Status~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"~Access~Level:~"..accessLevel.."~("..accessLevelName(accessLevel)..")")
	setLine(4,"~AC~Power:~"..(onBat and "BATTERY~BACKUP" or "NORMAL~~~~~~~~~"))
	setLine(5,"~Ground~Fault:~"..(gf and "YES" or "NO~"))
	setLine(6,"~Audibles:~"..(silenced and "SILENCED" or "ACTIVE~~"))
	setLine(7,"~Disabled~Points:~"..dp)
	setLine(8,"~Walk~Test:~"..(walkTestActive and "ACTIVE" or "OFF~~~"))
	setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Refresh~")
	softkey1Action = ShowInformationMenu; softkey3Action = ShowSystemStatus
end

ShowVersion = function()
	disconnectAll(); home = false
	setLine(1,"Version~Information~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"Panel~HW:~FV-922~Transponder~~~~~~~~~~~~~")
	setLine(4,"Panel~SW:~FS920~MP-UL~3.1~~~~~~~~~~~~~~~~")
	setLine(5,"Config~Data:~Version~1.0~~~~~~~~~~~~~~~~~")
	setLine(6,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,"Document:~A6V10333380_a_en_US~~~~~~~~~~~~")
	setLine(8,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowInformationMenu
end

-- ─────────────────────────────────────────────────────────────
-- CONFIGURATION MENU  (AL3)
-- ─────────────────────────────────────────────────────────────
ShowConfigMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Configuration~~~~~~~~~~~~~~~~~~~AL:3~~~")
	setLine(2,"(1)~Alter~Coding~Options~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Auto-configure~Panel~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Auto-configure~Circuit~~~~~~~~~~~~~~")
	setLine(5,"(4)~Enter~/~Change~Customer~Text~~~~~~~~")
	clearLines(6,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowFunctionsMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowCodingOptions()
		elseif v == 2 then AutoConfigurePanel()
		elseif v == 3 then AutoConfigureCircuit()
		elseif v == 4 then ChangeCustomerText()
		else ShowConfigMenu() end
	end)
end

ShowCodingOptions = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = "Code:~"
	setLine(1,"Coding~Options~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"0:~Continuous~~~~~~~1:~Temporal~~~~~~~~~")
	setLine(3,"2:~Fast~March~~~~~~~3:~Sync~~~~~~~~~~~~~")
	setLine(4,"4:~Slow~March~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"Code:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowConfigMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		local v = tonumber(input)
		if v and v >= 0 and v <= 4 then
			pcall(function() system.Coder.Coding.Value = v end)
			setLine(6,"Coding~set~to~"..v.."~successfully.~~~~~~~~~~"); task.wait(1.5)
		end
		ShowConfigMenu()
	end)
end

AutoConfigurePanel = function()
	disconnectAll(); home = false
	setLine(1,"Auto-configure~Panel~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Scanning~loop~for~devices...~~~~~~~~~~~~")
	clearLines(3,9); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); task.wait(4)
	local count = #system.InitiatingDevices:GetChildren()
	setLine(3,"Found~"..count.."~initiating~device(s).~~~~~~~~~~~")
	setLine(4,"Auto-configuration~complete.~~~~~~~~~~~~"); task.wait(2); ShowConfigMenu()
end

AutoConfigureCircuit = function()
	disconnectAll(); home = false
	setLine(1,"Auto-configure~Circuit~~~~~~~~~~~~~~~~~~")
	setLine(2,"Scanning~SLC~circuit...~~~~~~~~~~~~~~~~~")
	clearLines(3,9); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); task.wait(3)
	setLine(3,"Circuit~scan~complete.~~~~~~~~~~~~~~~~~~")
	setLine(4,"No~wiring~faults~detected.~~~~~~~~~~~~~~"); task.wait(2); ShowConfigMenu()
end

ChangeCustomerText = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 20; input = ""; numprefix = "Text:~"
	setLine(1,"Enter~/~Change~Customer~Text~~~~~~~~~~~~")
	setLine(2,"Current:~"..title)
	setLine(3,"Enter~new~building~title:~~~~~~~~~~~~~~~")
	clearLines(4,5); setLine(6,"Text:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowConfigMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		if input ~= "" then
			title = input
			setLine(2,"Updated:~"..input)
			setLine(6,"Customer~text~saved~successfully.~~~~~~~"); task.wait(1.5)
		end
		ShowConfigMenu()
	end)
end

-- ─────────────────────────────────────────────────────────────
-- MAINTENANCE MENU
-- ─────────────────────────────────────────────────────────────
ShowMaintenanceMenu = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Maintenance~Menu~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Point~List~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Poll~Event~Memory~~~~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Delete~Event~Memory~~~~~~~~~~~~~~~~~")
	setLine(5,"(4)~Sensor~Sensitivity~~~~~~~~~~~~~~~~~~")
	setLine(6,"(5)~Arm~/~Disarm~Detectors~~~~~~~~~~~~~~")
	setLine(7,"(6)~Maintenance~Report~~~~~~~~~~~~~~~~~~")
	clearLines(8,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowFunctionsMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowPointList()
		elseif v == 2 then ShowEventMemory(1)
		elseif v == 3 then ConfirmDeleteEventMemory()
		elseif v == 4 then ShowSensorSensitivity()
		elseif v == 5 then ArmDisarmDetectors()
		elseif v == 6 then ShowMaintenanceReport()
		else ShowMaintenanceMenu() end
	end)
end

ShowPointList = function()
	disconnectAll(); home = false
	local total = #system.InitiatingDevices:GetChildren()
	local disabled = system.DisabledPoints and #system.DisabledPoints:GetChildren() or 0
	local perips = system.Peripherals and #system.Peripherals:GetChildren() or 0
	setLine(1,"Point~List~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"Total~Addressable~Points:~~"..string.format("%4d",total))
	setLine(4,"Active~Points:~~~~~~~~~~~~~"..string.format("%4d",total-disabled))
	setLine(5,"Disabled~Points:~~~~~~~~~~~"..string.format("%4d",disabled))
	setLine(6,"Total~Peripheral~Modules:~~"..string.format("%4d",perips))
	setLine(7,"Total~Conventional~Zones:~~"..string.format("%4d",0))
	setLine(8,"Event~Memory~Entries:~~~~~~"..string.format("%4d",#eventMemory))
	setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowMaintenanceMenu
end

ConfirmDeleteEventMemory = function()
	disconnectAll(); home = false
	setLine(1,"Delete~Event~Memory~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"WARNING:~This~permanently~deletes~all~~~")
	setLine(3,"stored~event~records.~~~~~~~~~~~~~~~~~~~")
	setLine(4,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"Current~entries:~"..#eventMemory)
	setLine(6,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,"Press~OK~to~confirm,~Cancel~to~abort.~~~")
	clearLines(8,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowMaintenanceMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; disconnectEcon()
		eventMemory = {}
		setLine(5,"Event~memory~deleted~successfully.~~~~~~"); task.wait(2); ShowMaintenanceMenu()
	end)
end

ShowSensorSensitivity = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 5; input = ""; numprefix = "Det~ID:~"
	setLine(1,"Sensor~Sensitivity~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Enter~detector~ID:~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Det~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowMaintenanceMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		local id = input; local dev = system.InitiatingDevices:FindFirstChild(id)
		if dev then
			setLine(3,"Detector:~"..(dev:FindFirstChild("DeviceName") and dev.DeviceName.Value or id))
			setLine(4,"Sensitivity:~"..(dev:FindFirstChild("Sensitivity") and dev.Sensitivity.Value or "Normal"))
			setLine(5,"Last~Check:~N/A~~~~~~~~~~~~~~~~~~~~~~~~~")
		else setLine(6,"ID~"..id.."~not~found.") end
		task.wait(2); ShowMaintenanceMenu()
	end)
end

ArmDisarmDetectors = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Arm~/~Disarm~Detectors~~~~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Arm~all~detectors~~~~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Disarm~all~detectors~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Arm~single~detector~~~~~~~~~~~~~~~~~")
	setLine(5,"(4)~Disarm~single~detector~~~~~~~~~~~~~~")
	clearLines(6,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowMaintenanceMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then
			for _, dp in ipairs(system.DisabledPoints:GetChildren()) do dp:Destroy() end
			setLine(6,"All~detectors~armed.~~~~~~~~~~~~~~~~~~~~"); updateAllLEDs(); task.wait(2)
		elseif v == 2 then
			for _, dev in ipairs(system.InitiatingDevices:GetChildren()) do
				if not system.DisabledPoints:FindFirstChild(dev.Name) then
					local d = Instance.new("Model"); d.Name = dev.Name; d.Parent = system.DisabledPoints
				end
			end
			setLine(6,"All~detectors~disarmed.~~~~~~~~~~~~~~~~~"); updateAllLEDs(); task.wait(2)
		elseif v == 3 then
			BypassDetector()  -- reuse
		elseif v == 4 then
			BypassDetector()
		end
		ShowMaintenanceMenu()
	end)
end

ShowMaintenanceReport = function()
	disconnectAll(); home = false
	local total = #system.InitiatingDevices:GetChildren()
	local disabled = system.DisabledPoints and #system.DisabledPoints:GetChildren() or 0
	local alm,gas,sup,tbl = countEvents()
	setLine(1,"Maintenance~Report~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Generated:~"..os.date("%m/%d/%Y"))
	setLine(3,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"~Total~points:~~~~~"..string.format("%4d",total))
	setLine(5,"~Active:~~~~~~~~~~~"..string.format("%4d",total-disabled))
	setLine(6,"~Disabled:~~~~~~~~~"..string.format("%4d",disabled))
	setLine(7,"~Current~alarms:~~~"..string.format("%4d",alm+gas))
	setLine(8,"~Current~troubles:~"..string.format("%4d",tbl+sup))
	setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowMaintenanceMenu
end

-- ─────────────────────────────────────────────────────────────
-- FAVORITES
-- ─────────────────────────────────────────────────────────────
ShowFavorites = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Favorites~~~~~~~~~~~~~~~~~~~~~~~~~~~AL:"..accessLevel)
	setLine(2,"(1)~Message~Summary~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Event~Memory~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Enable~/~Bypass~(AL2)~~~~~~~~~~~~~~~")
	setLine(5,"(4)~System~Status~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"(5)~LED~Test~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(7,"(6)~Point~List~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(8,"(7)~Walk~Test~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(9,"(8)~Login~/~Logout~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowMainMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowMessageSummary()
		elseif v == 2 then ShowEventMemory(1)
		elseif v == 3 then requireAccessLevel(2, ShowBypassMenu)
		elseif v == 4 then ShowSystemStatus()
		elseif v == 5 then RunLEDTest()
		elseif v == 6 then ShowPointList()
		elseif v == 7 then requireAccessLevel(2, RunWalkTest)
		elseif v == 8 then ShowLoginLogout()
		else ShowMainMenu() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- TOPOLOGY
-- ─────────────────────────────────────────────────────────────
ShowTopology = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Topology~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Detection~Tree~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Hardware~Tree~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Control~Tree~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"(4)~Network~Tree~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"(5)~Operating~Tree~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowMainMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowDetectionTree()
		elseif v == 2 then ShowHardwareTree()
		elseif v == 3 then ShowControlTree()
		elseif v == 4 then ShowNetworkTree()
		elseif v == 5 then ShowOperatingTree()
		else ShowTopology() end
	end)
end

ShowDetectionTree = function()
	disconnectAll(); home = false
	local devices = system.InitiatingDevices:GetChildren()
	setLine(1,"Detection~Tree~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Total~Devices:~"..#devices)
	if #devices == 0 then setLine(3,"~No~devices~configured.~~~~~~~~~~~~~~~~~"); clearLines(4,9)
	else
		for i = 1, math.min(7,#devices) do
			local d = devices[i]
			setLine(i+2, string.sub(d.Name.."~~"..(d:FindFirstChild("DeviceName") and d.DeviceName.Value or d.Name), 1, 40))
		end
		if #devices > 7 then setLine(10,"~~...~("..(#devices-7).."~more)~use~SD~for~details~")
		else clearLines(#devices+3, 10) end
	end
	softkey1Action = ShowTopology
end

ShowHardwareTree = function()
	disconnectAll(); home = false
	setLine(1,"Hardware~Tree~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Panel:~"..trans.DeviceName.Value)
	setLine(3,"Type:~~FV-922~Transponder~~~~~~~~~~~~~~~~")
	setLine(4,"ID:~~~~0"..string.sub(trans.Name, 12))
	setLine(5,"State:~Online~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"Peripherals:~"..(system.Peripherals and #system.Peripherals:GetChildren() or 0))
	clearLines(7,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowTopology
end

ShowControlTree = function()
	disconnectAll(); home = false
	setLine(1,"Control~Tree~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Alarming~Control~Group~~~~~~~~~~~~~~~~~~")
	setLine(3,"~ALARM~ct:~Configured~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"~Evac~ct:~Configured~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"~Fire~ct:~Configured~~~~~~~~~~~~~~~~~~~~~")
	clearLines(6,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowTopology
end

ShowNetworkTree = function()
	disconnectAll(); home = false
	setLine(1,"Network~Tree~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Panel~Network:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(3,"~This~transponder:~ID~0"..string.sub(trans.Name, 12))
	setLine(4,"~Network~nodes:~1~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"~Status:~Online~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(6,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowTopology
end

ShowOperatingTree = function()
	disconnectAll(); home = false
	setLine(1,"Operating~Tree~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Access~Level:~"..accessLevel.."~("..accessLevelName(accessLevel)..")")
	setLine(3,"Walk~Test:~"..(walkTestActive and "ACTIVE" or "OFF"))
	setLine(4,"Silenced:~"..(system:FindFirstChild("Silenced") and system.Silenced.Value and "YES" or "NO"))
	setLine(5,"Reset~Active:~"..(system.Reset.Value and "YES" or "NO"))
	clearLines(6,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	softkey1Action = ShowTopology
end

-- ─────────────────────────────────────────────────────────────
-- ELEMENT SEARCH
-- ─────────────────────────────────────────────────────────────
ShowElementSearch = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Element~Search~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Start~with~category~~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Start~with~address~~~~~~~~~~~~~~~~~~")
	clearLines(4,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowMainMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowSearchByCategory()
		elseif v == 2 then SelectDevice()
		else ShowElementSearch() end
	end)
end

ShowSearchByCategory = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Select~Element~Category~~~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Zone~(Initiating~Device)~~~~~~~~~~~~")
	setLine(3,"(2)~Section~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Area~(Building)~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"(4)~Audible~(NAC)~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"(5)~Physical~Channel~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowElementSearch
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowAllZones()
		elseif v == 2 then setLine(1,"Sections:~Not~configured~~~~~~~~~~~~~~~~"); task.wait(2); ShowSearchByCategory()
		elseif v == 3 then setLine(1,"Area:~Building~(1~area~configured)~~~~~~"); task.wait(2); ShowSearchByCategory()
		elseif v == 4 then setLine(1,"Audibles:~NAC~circuit~1~configured~~~~~~"); task.wait(2); ShowSearchByCategory()
		else ShowElementSearch() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- EVENT MEMORY
-- ─────────────────────────────────────────────────────────────
ShowEventMemory = function(page)
	disconnectAll(); home = false
	page = tonumber(page) or 1
	local total = #eventMemory
	local totalPages = math.max(1, math.ceil(total / EVENT_LINES_PER_PAGE))
	page = math.max(1, math.min(page, totalPages))
	eventMemPage = page

	setLine(1,"Event~Memory~~~~"..page.."/"..totalPages.."~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Type~~~~~Time~~~~~Device/Condition~~~~~~")
	if total == 0 then
		setLine(3,"~No~events~in~memory~~~~~~~~~~~~~~~~~~~~"); clearLines(4,9)
	else
		for i = 1, EVENT_LINES_PER_PAGE do
			local idx = (page-1)*EVENT_LINES_PER_PAGE + i
			if idx <= total then
				local e = eventMemory[total-idx+1]
				local line = string.sub(e.type.."~"..os.date("%m/%d~%H:%M", e.timestamp).."~"..e.device, 1, 40)
				setLine(i+2, line)
			else setLine(i+2,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~") end
		end
	end
	setLine(9, "~~~~~Prev~~~~~~~Del~All~~~~~~~~Next~~~~~~")
	setLine(10,"~~~~~Page~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")

	softkey1Action = function() ShowEventMemory(page-1) end
	softkey2Action = ConfirmDeleteEventMemory
	softkey3Action = function() ShowEventMemory(page+1) end

	econTable[1] = trans.Buttons.BTN_U4.CD.MouseClick:Connect(function() ShowEventMemory(eventMemPage-1) end)
	econTable[2] = trans.Buttons.BTN_U5.CD.MouseClick:Connect(function() ShowEventMemory(eventMemPage+1) end)
end

-- ─────────────────────────────────────────────────────────────
-- SETTINGS / ADMINISTRATION
-- ─────────────────────────────────────────────────────────────
ShowSettingsAdmin = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Settings~/~Administration~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Change~PIN~~~(AL2)~~~~~~~~~~~~~~~~~~")
	setLine(3,"(2)~Create~PIN~~~(AL3)~~~~~~~~~~~~~~~~~~")
	setLine(4,"(3)~Delete~PIN~~~(AL3)~~~~~~~~~~~~~~~~~~")
	setLine(5,"(4)~LED~Test~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(6,"(5)~Set~Buzzer~Volume~~~~~~~~~~~~~~~~~~~~")
	setLine(7,"(6)~Display~Settings~~~~~~~~~~~~~~~~~~~~")
	setLine(8,"(7)~System~Commands~(Date/Time)~~~~~~~~~")
	setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowMainMenu
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then requireAccessLevel(2, ShowChangePIN)
		elseif v == 2 then requireAccessLevel(3, ShowCreatePIN)
		elseif v == 3 then requireAccessLevel(3, ShowDeletePIN)
		elseif v == 4 then RunLEDTest()
		elseif v == 5 then ShowSetBuzzerVolume()
		elseif v == 6 then ShowDisplaySettings()
		elseif v == 7 then ShowSystemCommands()
		else ShowMainMenu() end
	end)
end

ShowChangePIN = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 8; input = ""; numprefix = ""
	local step = 1; local oldPIN = ""; local newPIN = ""
	setLine(1,"Change~PIN~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Enter~current~PIN:~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Current~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowSettingsAdmin
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		if step == 1 then
			oldPIN = input; input = ""
			local correct = (accessLevel == 2 and oldPIN == PIN_LEVEL2) or (accessLevel >= 3 and oldPIN == PIN_LEVEL3)
			if correct then
				step = 2; setLine(2,"Enter~new~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(6,"New~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			else
				numpaden = false; disconnectEcon()
				setLine(2,"Incorrect~current~PIN.~~~~~~~~~~~~~~~~~~"); task.wait(1.5); ShowSettingsAdmin()
			end
		elseif step == 2 then
			newPIN = input; input = ""; step = 3
			setLine(2,"Confirm~new~PIN:~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(6,"Confirm:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		elseif step == 3 then
			if input == newPIN then
				if accessLevel == 2 then PIN_LEVEL2 = newPIN else PIN_LEVEL3 = newPIN end
				numpaden = false; disconnectEcon()
				setLine(2,"PIN~changed~successfully.~~~~~~~~~~~~~~~"); task.wait(2); ShowSettingsAdmin()
			else
				input = ""; step = 2
				setLine(2,"PINs~do~not~match.~Try~again.~~~~~~~~~~~"); task.wait(1.5)
				setLine(2,"Enter~new~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(6,"New~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			end
		end
	end)
end

ShowCreatePIN = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 8; input = ""; numprefix = ""
	setLine(1,"Create~PIN~(Level~2~-~Maintenance)~~~~~~")
	setLine(2,"Enter~new~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"New~PIN:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowSettingsAdmin
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		if input ~= "" then PIN_LEVEL2 = input; setLine(2,"PIN~created~successfully.~~~~~~~~~~~~~~~"); task.wait(2) end
		ShowSettingsAdmin()
	end)
end

ShowDeletePIN = function()
	disconnectAll(); home = false
	setLine(1,"Delete~PIN~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Removes~the~Level~2~PIN.~~~~~~~~~~~~~~~~")
	setLine(3,"Level~2~access~will~require~no~PIN.~~~~~")
	setLine(4,"Press~OK~to~confirm,~Cancel~to~abort.~~~")
	clearLines(5,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowSettingsAdmin
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; disconnectEcon()
		PIN_LEVEL2 = ""
		setLine(4,"Level~2~PIN~deleted~successfully.~~~~~~~"); task.wait(2); ShowSettingsAdmin()
	end)
end

ShowSetBuzzerVolume = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = "Vol:~"
	setLine(1,"Set~Buzzer~Volume~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Current:~"..buzzerVolume)
	setLine(3,"1=Quiet~~~2=Low~~~3=Medium~~4=Loud~~~~~~")
	setLine(4,"5=Max~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(5,5); setLine(6,"Vol~(1-5):~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowSettingsAdmin
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		local v = tonumber(input)
		if v and v >= 1 and v <= 5 then
			buzzerVolume = v
			local snd = getSoundObject()
			if snd then pcall(function() snd.Volume = v/5 end) end
			setLine(2,"Volume~set~to~"..v); task.wait(1.5)
		end
		ShowSettingsAdmin()
	end)
end

ShowDisplaySettings = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"Display~Settings~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"(1)~Change~Display~Brightness~~~~~~~~~~~")
	setLine(3,"(2)~Change~Display~Contrast~~~~~~~~~~~~~")
	clearLines(4,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowSettingsAdmin
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then ShowChangeBrightness()
		elseif v == 2 then ShowChangeContrast()
		else ShowDisplaySettings() end
	end)
end

ShowChangeBrightness = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = "Brightness:~"
	setLine(1,"Change~Display~Brightness~~~~~~~~~~~~~~~")
	setLine(2,"Current:~"..displayBrightness)
	setLine(3,"Enter~1~(dim)~to~5~(bright):~~~~~~~~~~~~")
	clearLines(4,5); setLine(6,"Brightness:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowDisplaySettings
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		local v = tonumber(input)
		if v and v >= 1 and v <= 5 then displayBrightness = v; setLine(2,"Brightness~set~to~"..v); task.wait(1.5) end
		ShowDisplaySettings()
	end)
end

ShowChangeContrast = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = "Contrast:~"
	setLine(1,"Change~Display~Contrast~~~~~~~~~~~~~~~~~")
	setLine(2,"Enter~1~(low)~to~5~(high):~~~~~~~~~~~~~~")
	clearLines(3,5); setLine(6,"Contrast:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	clearLines(7,9); setLine(10,"~~~~~Cancel~~~~~~~~~~~~~~~~~~~~~OK~~~~~~")
	softkey1Action = ShowDisplaySettings
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; disconnectEcon()
		setLine(2,"Contrast~updated."); task.wait(1.5); ShowDisplaySettings()
	end)
end

ShowSystemCommands = function()
	disconnectAll(); home = false
	numpaden = true; capacity = 1; input = ""; numprefix = ""
	setLine(1,"System~Commands~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(2,"Current~Date/Time:~"..os.date("%m/%d/%Y~%H:%M"))
	setLine(3,"(1)~Set~Date~/~Time~~~~~~~~~~~~~~~~~~~~~~")
	setLine(4,"(2)~Restart~System~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5,"(3)~Factory~Reset~(AL3)~~~~~~~~~~~~~~~~~")
	clearLines(6,9); setLine(10,"~~~~~Back~~~~~~~~~~~~~~~~~~~~~~~Select~~")
	softkey1Action = ShowSettingsAdmin
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end
		local v = tonumber(input); numpaden = false; disconnectEcon()
		if v == 1 then
			setLine(3,"Date/Time:~Set~by~server~(auto)~~~~~~~~~"); task.wait(2); ShowSettingsAdmin()
		elseif v == 2 then
			setLine(3,"Restarting~system...~~~~~~~~~~~~~~~~~~~~"); task.wait(2); system.ResetCommand.Value = true
		elseif v == 3 then
			requireAccessLevel(3, function()
				setLine(3,"Factory~reset~initiated.~~~~~~~~~~~~~~~~")
				eventMemory = {}; PIN_LEVEL2 = "1234"; PIN_LEVEL3 = "9999"
				task.wait(2); system.ResetCommand.Value = true
			end)
		else ShowSettingsAdmin() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- ACKNOWLEDGE
-- ─────────────────────────────────────────────────────────────
local function ackDisplay(info, ev)
	local alm,gas,sup,tbl = countEvents()
	setLine(1, buildStatusHeader(alm,gas,sup,tbl))
	setLine(2, "~~~~~~MN1~ALARM~~GAS~~MN2~~SUP~~TBL~MNT~")
	local devName = (ev:FindFirstChild("DeviceName") and ev.DeviceName.Value) or ev.Name
	local zone = ev:FindFirstChild("Zone") and ("Zone:~"..ev.Zone.Value) or "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	setLine(3, "!Zone~~~~~~~~~~~~~~~~~~~~~~~~~"..(info.label == "TROUBLE" and "TROUBLE~~~IN" or info.label.."~~~IN"))
	setLine(4, "~Building~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(5, zone)
	setLine(6, ev:FindFirstChild("Ack") and "[~ACKNOWLEDGED~]~~~~~~~~~~~~~~~~~~~~~~~~" or "[~PRESS~ACK~TO~CONFIRM~]~~~~~~~~~~~~~~~~")
	setLine(7, "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
	setLine(8, "~"..tostring(devName))
	setLine(9, "~~~~~Execute~~~~~~Details~~~~~~More~~~~~")
	setLine(10,"~~~~~Commands~~~~~view~~~~~Options~~~~~")
	updateAllLEDs()
end

local function AckAny()
	if locked then return end
	if not home then return end
	disconnectAll(); activateBacklight(); resetAccessTimeout()

	local tries = 0
	while tries < #ackFolders do
		local info = ackFolders[ackFolderIndex]
		local events = folderChildren(info.folderName)
		if #events > 0 then
			if ackIndex > #events then ackIndex = 1 end
			local ev = events[ackIndex]
			if ev:FindFirstChild("Ack") == nil and not ackPending then
				ackPending = true; ackDisplay(info, ev); return
			elseif ackPending then
				ackPending = false
				if ev:FindFirstChild("Ack") == nil then
					local ackfile = Instance.new("Model"); ackfile.Name = "Ack"; ackfile.Parent = ev
					logEvent(info.label, (ev:FindFirstChild("DeviceName") and ev.DeviceName.Value) or ev.Name, "Acknowledged")
				end
			else
				ackIndex += 1
				if ackIndex > #events then
					ackIndex = 1; ackFolderIndex += 1
					if ackFolderIndex > #ackFolders then ackFolderIndex = 1 end
				end
			end
			events = folderChildren(info.folderName)
			if #events > 0 then
				if ackIndex > #events then ackIndex = 1 end
				ackDisplay(info, events[ackIndex])
			else HomeDisplay() end
			updateAllLEDs(); updateSounder(); return
		else
			ackFolderIndex += 1
			if ackFolderIndex > #ackFolders then ackFolderIndex = 1 end
			ackIndex = 1; ackPending = false
		end
		tries += 1
	end
	ackIndex = 1; ackFolderIndex = 1; ackPending = false; HomeDisplay()
end

trans.Buttons.BTN_Ack.CD.MouseClick:Connect(AckAny)

-- ─────────────────────────────────────────────────────────────
-- SILENCE
-- ─────────────────────────────────────────────────────────────
trans.Buttons.BTN_Silence.CD.MouseClick:Connect(function()
	if locked then return end
	activateBacklight(); resetAccessTimeout()
	system.SilenceCommand.Value = true
	local silVal = system:FindFirstChild("Silenced")
	if not silVal then silVal = Instance.new("BoolValue"); silVal.Name = "Silenced"; silVal.Parent = system end
	silVal.Value = true; stopSounder(); updateAllLEDs()
	setLine(1,"Audibles~Silenced~~~~~~~~~~~~~~~~~~~~~~~"); setLine(2,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); clearLines(3,10)
	task.wait(1.5)
	if home then HomeDisplay() end
end)

-- ─────────────────────────────────────────────────────────────
-- RESET
-- ─────────────────────────────────────────────────────────────
trans.Buttons.BTN_Reset.CD.MouseClick:Connect(function()
	if locked then return end
	activateBacklight(); resetAccessTimeout()
	system.ResetCommand.Value = true
	local silVal = system:FindFirstChild("Silenced"); if silVal then silVal.Value = false end
	newalarm = ""; newalarmType = ""
	ackIndex = 1; ackFolderIndex = 1; ackPending = false
	updateAllLEDs(); updateSounder()
end)

if trans.Buttons:FindFirstChild("BTN_MNSReset") then
	trans.Buttons.BTN_MNSReset.CD.MouseClick:Connect(function()
		if locked then return end
		activateBacklight(); stopSounder()
		local silVal = system:FindFirstChild("Silenced"); if silVal then silVal.Value = false end
		updateAllLEDs()
		if home then HomeDisplay() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- SELECT DEVICE  (BTN_SD)
-- ─────────────────────────────────────────────────────────────
TogglePeripheral = function(id)
	local perp = system.Peripherals:FindFirstChild(id); if not perp then return end
	perp.Enabled.Value = not perp.Enabled.Value
	setLine(6, "ID~"..id..(perp.Enabled.Value and "" or "~-Disabled-")); updateAllLEDs()
end

TogglePoint = function(id)
	local dp = system.DisabledPoints
	if dp:FindFirstChild(id) then
		dp:FindFirstChild(id):Destroy(); setLine(6,"ID~"..id.."~-~Enabled")
	else
		local d = Instance.new("Model"); d.Name = id; d.Parent = dp; setLine(6,"ID~"..id.."~-~Disabled")
	end
	updateAllLEDs()
end

FetchDevice = function()
	setLine(1,"POINT~INFORMATION~~~~~~~~~~~~~~~~~~~~~~~"); disconnectEcon()
	local devInput = input
	if string.sub(devInput,1,3) == "000" then
		local perp = system.Peripherals:FindFirstChild(devInput)
		if perp then
			setLine(2, perp.DeviceName.Value); setLine(3,"Type:~Peripheral~Module~~~~~~~~~~~~~~~~~")
			setLine(4,"Status:~"..(perp.Enabled.Value and "ENABLED" or "DISABLED"))
			setLine(6,"ID~"..devInput..(perp.Enabled.Value and "" or "~-Disabled-"))
			setLine(9,"~~~~~Enable/Disable~~~~~~~~~~~~~~~~~~~~~"); setLine(10,"~~~~~(BTN_ED)~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			econ = trans.Buttons.BTN_ED.CD.MouseClick:Connect(function()
				if locked then return end; requireAccessLevel(2, function() TogglePeripheral(devInput) end)
			end)
		else setLine(6,"ID~"..devInput.."~invalid.") end
	elseif string.sub(devInput,1,2) == "00" then
		local ann = system:FindFirstChild("Annunciator"..string.sub(devInput,3))
		if ann then setLine(2,ann.DeviceName.Value); setLine(3,"Type:~Annunciator~Module~~~~~~~~~~~~~~~~"); setLine(6,"ID~"..devInput)
		else setLine(6,"ID~"..devInput.."~invalid.") end
	elseif string.sub(devInput,1,1) == "0" then
		local trp = system:FindFirstChild("Transponder"..string.sub(devInput,2))
		if trp then setLine(2,trp.DeviceName.Value); setLine(3,"Type:~Transponder~~~~~~~~~~~~~~~~~~~~~~~"); setLine(6,"ID~"..devInput)
		else setLine(6,"ID~"..devInput.."~invalid.") end
	else
		local dev = system.InitiatingDevices:FindFirstChild(devInput)
		if dev then
			setLine(2,(dev:FindFirstChild("DeviceName") and dev.DeviceName.Value) or devInput)
			setLine(3,"Type:~"..(dev:FindFirstChild("Type") and dev.Type.Value or "Initiating~Device"))
			setLine(4,(dev:FindFirstChild("Zone") and "Zone:~"..dev.Zone.Value) or "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			setLine(5,(dev:FindFirstChild("Location") and "Loc:~"..dev.Location.Value) or "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			setLine(6,"ID~"..devInput..(system.DisabledPoints:FindFirstChild(devInput) and "~-Disabled-" or ""))
			setLine(7,(dev:FindFirstChild("LastAlarm") and "Last~Alm:~"..dev.LastAlarm.Value) or "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			setLine(8,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			setLine(9,"~~~~~Enable/Disable~~~~~~~~~~~~~~~~~~~~~"); setLine(10,"~~~~~(BTN_ED)~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
			disconnectEcon()
			econ = trans.Buttons.BTN_ED.CD.MouseClick:Connect(function()
				if locked then return end; requireAccessLevel(2, function() TogglePoint(devInput) end)
			end)
		else setLine(6,"ID~"..devInput.."~invalid.") end
	end
end

SelectDevice = function()
	if locked then return end; activateBacklight()
	home = false; numpaden = true; capacity = 5; input = ""; numprefix = "Enter~ID:~"
	setLine(1,"ENTER~POINT~ID~~~~~~~~~~~~~~~~~~~~~~~~~~"); clearLines(2,5)
	setLine(6,"Enter~ID:~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); clearLines(7,10)
	disconnectEcon()
	econ = trans.Buttons.BTN_Enter.CD.MouseClick:Connect(function()
		if locked then return end; numpaden = false; FetchDevice()
	end)
end

trans.Buttons.BTN_SD.CD.MouseClick:Connect(SelectDevice)

-- ─────────────────────────────────────────────────────────────
-- SOFTKEYS
-- ─────────────────────────────────────────────────────────────
if trans.Buttons:FindFirstChild("BTN_C1") then
	trans.Buttons.BTN_C1.CD.MouseClick:Connect(function()
		if locked then return end; activateBacklight()
		if softkey1Action then softkey1Action() end
	end)
end
if trans.Buttons:FindFirstChild("BTN_C2") then
	trans.Buttons.BTN_C2.CD.MouseClick:Connect(function()
		if locked then return end; activateBacklight()
		if softkey2Action then softkey2Action() end
	end)
end
if trans.Buttons:FindFirstChild("BTN_C3") then
	trans.Buttons.BTN_C3.CD.MouseClick:Connect(function()
		if locked then return end; activateBacklight()
		if softkey3Action then softkey3Action() end
	end)
end

-- ─────────────────────────────────────────────────────────────
-- USER BUTTONS
-- ─────────────────────────────────────────────────────────────
for i = 1, 10 do
	if i ~= 8 then
		local btn = trans.Buttons:FindFirstChild("BTN_U"..i)
		if btn then
			local ci = i
			btn.CD.MouseClick:Connect(function()
				if locked then return end; activateBacklight(); resetAccessTimeout()
				local userLEDs = trans.LEDs:FindFirstChild("UserLEDs")
				if userLEDs then
					local led = userLEDs:FindFirstChild("User"..ci.."LED")
					if led and led:FindFirstChild("Activate") then led.Activate.Value = not led.Activate.Value end
				end
				local cmd = system:FindFirstChild("User"..ci.."Command")
				if cmd then cmd.Value = true; task.wait(0.1); cmd.Value = false end
			end)
		end
	end
end

-- ─────────────────────────────────────────────────────────────
-- EXIT BUTTON
-- ─────────────────────────────────────────────────────────────
local function ExitButton()
	activateBacklight()
	local userLEDs = trans.LEDs:FindFirstChild("UserLEDs")
	local u8led = userLEDs and userLEDs:FindFirstChild("User8LED")
	if u8led and u8led:IsA("BasePart") then u8led.BrickColor = BrickColor.new("Deep orange") end
	disconnectAll(); numpaden = false; input = ""; home = true; newalarm = ""; newalarmType = ""; ackPending = false
	HomeDisplay()
	task.wait(0.5)
	if u8led and u8led:IsA("BasePart") then u8led.BrickColor = BrickColor.new("Really black") end
end
trans.Buttons.BTN_U8.CD.MouseClick:Connect(ExitButton)

-- ─────────────────────────────────────────────────────────────
-- NEW EVENT HANDLING
-- ─────────────────────────────────────────────────────────────
local function NewEvent(prefix, model)
	local d = (model:FindFirstChild("DeviceName") and model.DeviceName.Value) or model.Name
	if prefix == "ALM" then newalarmType = "ALARM"
	elseif prefix == "GAS" then newalarmType = "GAS"
	elseif prefix == "SUP" then newalarmType = "SUP"
	elseif prefix == "TBL" then newalarmType = "TROUBLE"
	else newalarmType = "ALARM" end
	newalarm = prefix.."~"..d
	logEvent(newalarmType, d, "Active")
	updateAllLEDs(); updateSounder(); activateBacklight()
	if home then HomeDisplay() end
end

local eventFolders = {
	{name="ActiveAlarms",prefix="ALM"}, {name="GasAlarms",prefix="GAS"},
	{name="Supervisory",prefix="SUP"}, {name="Troubles",prefix="TBL"},
}
for _, f in ipairs(eventFolders) do
	local folder = system:FindFirstChild(f.name)
	if folder then
		folder.ChildAdded:Connect(function(m) 
			NewEvent(f.prefix, m) 
			if folder.Name == "ActiveAlarms" then
				sendDiscordEmbed("Fire Alarm",1,m.Name,m.DeviceName.Value)
			elseif folder.Name == "Supervisory" then
				sendDiscordEmbed("System Supervisory",2,m.Name,m.DeviceName.Value)
			elseif folder.Name == "Trouble" then
				sendDiscordEmbed("System Trouble",3,m.Name,m.DeviceName.Value)
			elseif folder.Name == "GasAlarms" then
				sendDiscordEmbed("Gas Alarm",2,m.Name,m.DeviceName.Value)	
			end
		end)
		folder.ChildRemoved:Connect(function()
			newalarm = ""; newalarmType = ""
			ackIndex = 1; ackFolderIndex = 1; ackPending = false
			updateAllLEDs(); updateSounder()
			if home then HomeDisplay() end
		end)
		
	end
end

-- ─────────────────────────────────────────────────────────────
-- SYSTEM WATCHERS
-- ─────────────────────────────────────────────────────────────
system.Reset.Changed:Connect(function() if home then HomeDisplay() end end)

local gf = system:FindFirstChild("GroundFault")
if gf then gf.Changed:Connect(function() updateAllLEDs(); if gf.Value then logEvent("TROUBLE","Ground~Fault","Active") end end) end

local bat = system:FindFirstChild("OnBattery")
if bat then bat.Changed:Connect(function() updateAllLEDs(); if bat.Value then logEvent("TROUBLE","Battery~Backup","AC~Loss") end end) end

local silWatch = system:FindFirstChild("Silenced")
if silWatch then silWatch.Changed:Connect(function() updateAllLEDs() end) end

-- ─────────────────────────────────────────────────────────────
-- TRANSPONDER DAMAGE
-- ─────────────────────────────────────────────────────────────
trans.ChildRemoved:Connect(function()
	if trtr then return end
	while system.Reset.Value == true do task.wait() end
	trtr = true
	local file = Instance.new("Model")
	local filex = Instance.new("StringValue"); filex.Name = "ID"; filex.Value = "0"..string.sub(trans.Name,12); filex.Parent = file
	local filey = Instance.new("StringValue"); filey.Name = "Condition"; filey.Value = "Damaged"; filey.Parent = file
	file.Name = trans.DeviceName.Value; file.Parent = system.Troubles
end)

-- ─────────────────────────────────────────────────────────────
-- STARTUP
-- ─────────────────────────────────────────────────────────────
game.Players.PlayerAdded:Connect(function()
	if not ServerStarted then
		ServerStarted = true
		for i = 1, 10 do setLine(i,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~") end
		task.wait(10)
		setLine(1,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(2,"~~~~~~~~~~~~~SIEMENS~~~~~~~~~~~~~~~~~~~~")
		setLine(3,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(4,"~~FS920~Fire~Control~Panel~~~~~~~~~~~~~~")
		setLine(5,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(6,"~~~~~~~~~Initializing...~~~~~~~~~~~~~~~~")
		setLine(7,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(8,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		setLine(9,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"); setLine(10,"~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
		task.wait(3); script.Parent.Parent.ResetCommand.Value = true
		sendDiscordEmbed("System Started",4,"Node","Node")
	end
end)

-- ─────────────────────────────────────────────────────────────
-- FINAL INIT
-- ─────────────────────────────────────────────────────────────
HomeDisplay()
local pwrLED = trans:FindFirstChild("PowerLED")
if pwrLED then
	if pwrLED:FindFirstChild("Activate") then pwrLED.Activate.Value = true
	elseif pwrLED:IsA("BasePart") then pwrLED.BrickColor = BrickColor.new("Lime green") end
		
end
updateAllLEDs()
