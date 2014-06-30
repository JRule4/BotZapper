-----------------------------------------------------------------------------------------------
-- Client Lua Script for BotZapper
-- Copyright (c) NCsoft. All rights reserved
-----------------------------------------------------------------------------------------------

require "Window"
require "Apollo"
require "Unit"
require "ChatChannelLib"
require "ChatSystemLib"
require "MessageManagerLib"
require "PublicEvent"

-----------------------------------------------------------------------------------------------
-- BotZapper Module Definition
-----------------------------------------------------------------------------------------------
local BotZapper = {} 
 
-----------------------------------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------------------------------
local updateTimer = nil
local infractionSpeed = 1.5
local infractionLimit = 3
local reportableSuspicion = 5
local reinsertionTimer = 15

-- Class name table
local tClasses = 	
{ 
	[GameLib.CodeEnumClass.Warrior]      = { name = Apollo.GetString("ClassWarrior"), },
	[GameLib.CodeEnumClass.Engineer]     = { name = Apollo.GetString("ClassEngineer"), },
	[GameLib.CodeEnumClass.Esper]        = { name = Apollo.GetString("ClassESPER"), },
	[GameLib.CodeEnumClass.Medic]        = { name = Apollo.GetString("ClassMedic"), },
	[GameLib.CodeEnumClass.Stalker]      = { name = Apollo.GetString("ClassStalker"), },
	[GameLib.CodeEnumClass.Spellslinger] = { name = Apollo.GetString("ClassSpellslinger"), },
} 

-- Faction name table
local tFactions =
{
	[Unit.CodeEnumFaction.DominionPlayer] 	= { name = "Dominion", },
	[Unit.CodeEnumFaction.ExilesPlayer] 	= { name = "Exile", },
}

-- Zone level limits for determining if a player is underleveled
local tZoneLimit = 
{
	[GameLib.MapZone.Whitevale] 		= { level = 22 },
	[75]			 					= { level = 29 }, --Farside Biodome 3
	[75]			 					= { level = 29 }, --Farside Biodome 4
	[28]			 					= { level = 32 }, --Farside Moon
	[GameLib.MapZone.Wilderrun] 		= { level = 35 },
	[GameLib.MapZone.Whitevale] 		= { level = 40 },
	[GameLib.MapZone.Grimvault] 		= { level = 46 },
	[GameLib.MapZone.WesternGrimvault] 	= { level = 46 },
}

-----------------------------------------------------------------------------------------------
-- Initialization
-----------------------------------------------------------------------------------------------
function BotZapper:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self 
    return o
end

-----------------------------------------------------------------------------------------------
-- Initialization
-----------------------------------------------------------------------------------------------
function BotZapper:Init()
	local bHasConfigureFunction = false
	local strConfigureButtonText = ""
	local tDependencies = {}
	
	-- Get the ticket types for reporting a player bot
	self.ticketType = self:GetTicketType()
	self.ticketSubType = self:GetTicketSubType(self.ticketType)
	
	-- Other initialization.
	self.playerUnit = nil
	self.nearbyUnits = {}
	self.watchedUnits = {}
	self.ignoredUnits = {}
	self.botInfoQueue = List:new()
	self.currentTime = GameLib.GetGameTime()
	self.deltaTime = 0
	self.enabled = true
	
    Apollo.RegisterAddon(self, bHasConfigureFunction, strConfigureButtonText, tDependencies)
end

-----------------------------------------------------------------------------------------------
-- BotZapper OnLoad
-----------------------------------------------------------------------------------------------
function BotZapper:OnLoad()
		
    -- load our form file
	self.xmlDoc = XmlDoc.CreateFromFile("BotZapper.xml")
	self.xmlDoc:RegisterCallback("OnDocLoaded", self)
	
	
	Apollo.RegisterEventHandler("UnitCreated", 		"OnUnitCreated", self)		
	Apollo.RegisterEventHandler("UnitDestroyed", 	"OnUnitDestroyed", self)
	Apollo.RegisterEventHandler("ChangeWorld",		"OnChangeWorld", self)
	
end

-----------------------------------------------------------------------------------------------
-- BotZapper OnDocLoaded
-----------------------------------------------------------------------------------------------
function BotZapper:OnDocLoaded()

	if self.xmlDoc ~= nil and self.xmlDoc:IsLoaded() then
		-- Debug form.
	    self.wndMain = Apollo.LoadForm(self.xmlDoc, "BotZapperForm", nil, self)
		-- Report request form.
		self.wndReportRequest = Apollo.LoadForm(self.xmlDoc, "ReportRequestForm", nil, self)
		-- Toast form.
		self.wndBotToast = Apollo.LoadForm(self.xmlDoc, "BotToastForm", nil, self)
		if self.wndMain == nil then
			Apollo.AddAddonErrorText(self, "Could not load the main window for some reason.")
			return
		end
		
		-- Hide all windows by default.
	    self.wndMain:Show(false, true)
		self.wndReportRequest:Show(false, true)
		self.wndBotToast:Show(false, true)

		-- Debug access.
		Apollo.RegisterSlashCommand("bz", "OnBotZapperOn", self)
		
		updateTimer = ApolloTimer.Create(0.1, true, "OnTimerRefresh", self)
	end
end

-----------------------------------------------------------------------------------------------
-- Called when changing maps.
-----------------------------------------------------------------------------------------------
function BotZapper:OnChangeWorld()

	-- Clear lists.
	self.nearbyUnits = {}
	self.watchedUnits = {}
	self.botInfoQueue = List:new()
	
	-- Close windows.
	self.wndMain:Close()
	self.wndBotToast:Close()
	self.wndReportRequest:Close()
	
	--Determine if we should run this addon or not.
	local zoneInfo = GameLib.GetCurrentZoneMap()
	GameLib.IsInWorldZone(zoneInfo.id)
	if zoneInfo  == nil or GameLib.IsInWorldZone(zoneInfo.id) == false or zoneInfo.id == GameLib.MapZone.Illium or zoneInfo.id == GameLib.MapZone.Thayd then
		self.enabled = false		
		Apollo.RemoveEventHandler("UnitCreated", self)		
		Apollo.RemoveEventHandler("UnitDestroyed", self)
	else
		self.enabled = true
		Apollo.RegisterEventHandler("UnitCreated", 		"OnUnitCreated", self)		
		Apollo.RegisterEventHandler("UnitDestroyed", 	"OnUnitDestroyed", self)
	end
		
end

-----------------------------------------------------------------------------------------------
-- Called when a unit is created. Setup basic info for UnitData.
-----------------------------------------------------------------------------------------------
function BotZapper:OnUnitCreated(unit)

	-- We only want to run on player units if we are enabled.
	if self.enabled and unit:GetType() ~= "Player" then
		return
	end	
	
	local unit_ID = unit:GetId()
	
	-- If they exist in the ignore table, ignore them.
	if self.ignoredUnits[unit_ID] ~= nil then
		return
	end
	
	-- Automatically add friends and groupmembers to the ignore list.
	if unit:IsAccountFriend() or unit:IsFriend() or unit:IsInYourGroup() then
		self.ignoredUnits[unit_ID] = { id = unit_ID }
		return
	end

	-- Setup basic data for a new unit.
	self.nearbyUnits[unit_ID] = {
									lastPos = unit:GetPosition(),
									creationTime = GameLib.GetGameTime(),
									speedInfractions = 0,
									topSpeed = 0,
									harvestCount = 0,
								}

end

-----------------------------------------------------------------------------------------------
-- Called when a unit is destroyed. This is where we implement logic to determine if a unit is a bot or not.
-----------------------------------------------------------------------------------------------
function BotZapper:OnUnitDestroyed(unit)
	
	-- We only want to run on player units if we are enabled.
	if self.enabled and unit:GetType() ~= "Player" then
		return
	end	
	
	local unit_ID = unit:GetId()
	
	-- If they exist in the ignore table, ignore them.
	if self.ignoredUnits[unit_ID] ~= nil then
		return
	end
	
	local unitData = self.nearbyUnits[unit_ID]
	
	-- For some reason they don't exist in the nearby units table, bail out.
	if unitData == nil then
		return
	end
	
	-- Suspicion is gained through activities bots do.
	local suspicionLevel = 0

	-- Hacker speed is required to generate any suspicion.
	if unitData.speedInfractions >= infractionLimit then
	
		suspicionLevel = suspicionLevel + 1
		
		--Speeding A LOT of times will generate extra suspicion.
		if unitData.speedInfractions >= (infractionLimit + 2) then
			suspicionLevel = suspicionLevel + 1
		end
		
		local buffs = self:GetBuffNames(unit:GetBuffs().arBeneficial)
	
		-- Having no buffs generates suspicion. Most normal players have at least a housing buff.
		if buffs:len() == 0 then
			suspicionLevel = suspicionLevel + 1
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "No buffs, added suspicion")-- DEBUG
		end
		
		-- If the player is outside of the level range, they're super suspicious. 
		if tZoneLimit[GameLib.GetCurrentZoneMap().id] ~= nil and (tZoneLimit[GameLib.GetCurrentZoneMap().id].level - unit:GetLevel()) >= 5 then
			suspicionLevel = suspicionLevel + 2
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Underleveld for the zone, added suspicion "..unit:GetLevel())-- DEBUG
		end
		
		-- If they're harvesting, they're suspicious. But remember, this only gets hit if they've also been speeding.
		if unitData.harvestCount > 0 then
			suspicionLevel = suspicionLevel + 1
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Did harvest, added suspicion")-- DEBUG
		end
		
		-- If, by chance, we get in here on a false positive - check for an authenticator. 
		-- Authenticators are pretty good signs of legit players as no bots seem to run with authenticators.
		if buffs:find("Authentication Dividends") ~= nil then
			suspicionLevel = 1
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Has authenticator, reduced suspicion")-- DEBUG
		end	
	 
		-- If unit doesn't exist in the watch list.
		if self.watchedUnits[unit_ID] == nil then
			
			-- Compile a new case against the user.
			self.watchedUnits[unit_ID] = 
			{
				name = unit:GetName(),
				level = unit:GetLevel(),
				faction = tFactions[unit:GetFaction()].name,
				class = tClasses[unit:GetClassId()].name,
				zone = GameLib.GetCurrentZoneMap().strName,
				suspicion = suspicionLevel,
				unitID = unit:GetId(),
				eventCount = 1,
				didHarvest = unitData.harvestCount > 0,
				speedInfractions = unitData.speedInfractions,
				topSpeed = unitData.topSpeed,
				
				-- If we can't generate enough suspicion to report within one "seeing" of a unit, we'll keep multiple.
				events = 
				{
					[0] = 	{
								time = os.date("!%c").." UTC",
								position = self:PositionString(unit:GetPosition()),
								buffs = self:GetBuffNames(unit:GetBuffs().arBeneficial),
								debuffs = self:GetBuffNames(unit:GetBuffs().arHarmful),
								didHarvest = unitData.harvestCount > 0
							},
				},
			}	
		
		else -- Unit is already being watched.
		
			--Update the watch unit information.
			local watchUnit = self.watchedUnits[unit_ID]
			watchUnit.suspicion = watchUnit.suspicion + suspicionLevel
			
			watchUnit.speedInfractions = watchUnit.speedInfractions + unitData.speedInfractions
			watchUnit.topSpeed = math.max(watchUnit.topSpeed, unitData.topSpeed)
			watchUnit.events[watchUnit.eventCount] = 	
			{
				time = os.date("!%c").." UTC",
				position = self:PositionString(unit:GetPosition()),
				buffs = self:GetBuffNames(unit:GetBuffs().arBeneficial),
				debuffs = self:GetBuffNames(unit:GetBuffs().arHarmful),
				didHarvest = unitData.harvestCount > 0,					
			}
			watchUnit.eventCount = watchUnit.eventCount + 1
		
		end
	
		--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Total Suspicion = "..self.watchedUnits[unit_ID].suspicion) --DEBUG
		
		-- We've reched the point that which we will report this player.
		if self.watchedUnits[unit_ID].suspicion >= reportableSuspicion then
		
			 -- DEBUG
			ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName())-- .. "=============================", "BotZapper")
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " Buffs = "..self:GetBuffNames(unit:GetBuffs().arBeneficial), "BotZapper" )
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " topSpeed = "..unitData.topSpeed, "BotZapper" )
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " speedInfractions = "..unitData.speedInfractions, "BotZapper" )	
			-- DEBUG	
		
			--Add them to the botQueue and popup a toast for the player.
			List:push(self.botInfoQueue, unit_ID)
			self.wndBotToast:Invoke()
		end
		
	end
	
	-- Remove the nearbyUnit since it has been destroyed.
	self.nearbyUnits[unit_ID] = nil
end

-----------------------------------------------------------------------------------------------
-- Update "loop"
-----------------------------------------------------------------------------------------------
function BotZapper:OnTimerRefresh()
	
	-- Update time first, so we can use it in the updates.
	local currentTime = GameLib.GetGameTime()
	self.deltaTime = currentTime - self.currentTime 
	self.currentTime = currentTime
	
	local grid = self.wndMain:FindChild("Grid") -- DEBUG
				
	grid:DeleteAll() -- DEBUG

	-- Loop through all nearbyUnits and update them so that we can generate info on them.
	for index,unitData in pairs(self.nearbyUnits) do
		local unit = GameLib.GetUnitById(index)
		if unit ~= nil then
			self:AddGridUnit(grid, unit) -- DEBUG
			self:UpdateUnit(unit)
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Updates our nearby units
-----------------------------------------------------------------------------------------------
function BotZapper:UpdateUnit(unit)

	local unitData = self.nearbyUnits[unit:GetId()]	
	
	-- We want to remove and re-add a player occasionally.
	-- If you're around a player for long enough, they may trigger speed traps too many times.
	-- No normal player should trigger enough times in a 10-25 second duration.
	if self.currentTime - unitData.creationTime > reinsertionTimer then
		self:OnUnitDestroyed(unit)
		self:OnUnitCreated(unit)
		return
	end
	
	local unitPosition = unit:GetPosition()
	
	-- Ignore mounted units... What bots use mounts? Zero.
	if unit:IsMounted() == false then
		local speed = self:VectorDistance(unitData.lastPos, unitPosition)
		
		if speed * self.deltaTime > infractionSpeed then
			unitData.speedInfractions = unitData.speedInfractions + 1
			unitData.topSpeed = math.max(unitData.topSpeed, speed)
			--unit:ShowHintArrow()
		end
		
		-- Watching for gathering.
		if self:IsGathering(unit) then
			unitData.harvestCount = unitData.harvestCount + 1
		end
		
	end

	-- Update positional data for next update.
	self.nearbyUnits[unit:GetId()].lastPos = unitPosition;
	self.nearbyUnits[unit:GetId()].lastPosTime = self.currentTime;

end

-----------------------------------------------------------------------------------------------
-- Adds grid info for debugging. - DEBUG
-----------------------------------------------------------------------------------------------
function BotZapper:AddGridUnit(grid, unit)

	local unitData = self.nearbyUnits[unit:GetId()]
	local unitPosition = unit:GetPosition()
	local rowIndex = grid:AddRow("")
	
	grid:SetCellText(rowIndex, 1, unit:GetName())
	if tClasses[unit:GetClassId()] ~= nil then
		grid:SetCellText(rowIndex, 2, tClasses[unit:GetClassId()].name)
	end
	if unit:GetLevel() ~= nil then
		grid:SetCellText(rowIndex, 3, unit:GetLevel())
	end
	if unit:GetAffiliationName() ~= nil then
		grid:SetCellText(rowIndex, 4, unit:GetAffiliationName())
	end
	
	local speed = self:VectorDistance(unitData.lastPos, unitPosition) * self.deltaTime
	grid:SetCellText(rowIndex, 5, speed)
	
	if tFactions[unit:GetFaction()] ~= nil then
		grid:SetCellText(rowIndex, 6, tFactions[unit:GetFaction()].name)
	end
	--grid:SetCellText(rowIndex, 6, self.currentTime - unitData.creationTime)
	
	local unitPosition = unit:GetPosition()
	grid:SetCellText(rowIndex, 7, self:PositionString(unitPosition))
		
	--if unit:GetTarget() ~= nil then
		grid:SetCellText(rowIndex, 8, unitData.speedInfractions)
	--end
	--grid:SetCellText(rowIndex, 8, GameLib.GetCurrentZoneMap().id)
		
end

-----------------------------------------------------------------------------------------------
-- on SlashCommand "/bz" DEBUG
-----------------------------------------------------------------------------------------------
function BotZapper:OnBotZapperOn()
	self.wndMain:Invoke() -- show the window
end

-----------------------------------------------------------------------------------------------
-- when the OK button is clicked - DEBUG
-----------------------------------------------------------------------------------------------
function BotZapper:OnOK()
	self.wndMain:Close() -- hide the window
end

-----------------------------------------------------------------------------------------------
-- when the Cancel button is clicked - DEBUG
-----------------------------------------------------------------------------------------------
function BotZapper:OnCancel()
	self.wndMain:Close() -- hide the window
end

-----------------------------------------------------------------------------------------------
-- Request screen to the player for reporing a player. Gives some information.
-----------------------------------------------------------------------------------------------
function BotZapper:RequestReport(unit_ID)
	
	--Open up the request report screen and fill out the text.
	local infoBox = self.wndReportRequest:FindChild("InfoBox")
	infoBox:SetText(self:GetReportText(unit_ID))
	
	self.wndReportRequest:Invoke()
	
end

---------------------------------------------------------------------------------------------------
-- Handles the generate report button from the toast window.
---------------------------------------------------------------------------------------------------
function BotZapper:OnGenerateReportButton( wndHandler, wndControl, eMouseButton )

	-- Pop them from the queue
	local unit_ID = List:pop(self.botInfoQueue)
	--PlayerTicketDialog_Report(self.ticketType, self.ticketSubType, self:GetReportText(unit_ID))
	ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, self:GetReportText(unit_ID))-- DEBUG
	
	-- Add them to the ignored units. Clear them out from any other tables.
	self.ignoredUnits[unit_ID] = { id = unit_ID }
	self.watchedUnits[unit_ID] = nil
	self.nearbyUnits[unit_ID] = nil
	self.wndReportRequest:Close()
	
	-- If we have more in queue, push them up.
	if List:getLength(self.botInfoQueue) > 0 then
		self.wndBotToast:Invoke()
	end

end

---------------------------------------------------------------------------------------------------
-- Handles the ignore button in the report request screen. 
-- Removes the unit from the queue, adds them to the ignore table. and moves to the next.
---------------------------------------------------------------------------------------------------
function BotZapper:OnIgnoreUnitButton( wndHandler, wndControl, eMouseButton )

	-- Pop them from the queue, but do nothing with it other than table work.
	local unit_ID = List:pop(self.botInfoQueue)
	
	-- Add them to the ignored units. Clear them out from any other tables.
	self.ignoredUnits[unit_ID] = { id = unit_ID }
	self.watchedUnits[unit_ID] = nil
	self.nearbyUnits[unit_ID] = nil
	self.wndReportRequest:Close()
	
	-- If we have more in queue, push them up.
	if List:getLength(self.botInfoQueue) > 0 then
		self.wndBotToast:Invoke()
	end
	
end

---------------------------------------------------------------------------------------------------
-- Handles the "Gather more info" button in the report request.
-- Removes the unit from the queue, and moves to the next. 
-- The unit will pop up a dialogue again when it it seen next time.
---------------------------------------------------------------------------------------------------
function BotZapper:OnWaitReportButton( wndHandler, wndControl, eMouseButton )
	
	-- Pop them from the queue, so that they're added back to the end next time. 
	-- Do nothing with the return.
	List:pop(self.botInfoQueue)
	
	self.wndReportRequest:Close()
		
	-- If we have more in queue, push them up.
	if List:getLength(self.botInfoQueue) > 0 then
		self.wndBotToast:Invoke()
	end
end

---------------------------------------------------------------------------------------------------
-- Generates and returns a report text blob based on the unit ID
---------------------------------------------------------------------------------------------------
function BotZapper:GetReportText(unit_ID)
	local reportText = ""
	local watchUnit = self.watchedUnits[unit_ID]
	
	--Player information.
	reportText = reportText .."Player: ".. watchUnit.name
	reportText = reportText .."\nUnit ID: ".. watchUnit.unitID
	
	--We can report if they have an authenticator or not.
	reportText = reportText .."\nHas Authenticator: "
	if watchUnit.events[0].buffs:find("Authentication Dividends") then
		reportText = reportText .."True"
	else
		reportText = reportText .."False"
	end	
	
	--We report if they're underleveled for the zone.
	reportText = reportText .."\nLevel: ".. watchUnit.level
	if tZoneLimit[GameLib.GetCurrentZoneMap().id] ~= nil and (tZoneLimit[GameLib.GetCurrentZoneMap().id].level - watchUnit.level) > 5 then
		reportText = reportText .." (underleveled for this zone)"
	end
	
	-- More Player information.
	reportText = reportText .."\nFaction: ".. watchUnit.faction
	reportText = reportText .."\nClass: ".. watchUnit.class
	reportText = reportText .."\nZone: ".. watchUnit.zone
	reportText = reportText .."\nServer: ".. GameLib.GetRealmName()
	
	-- Top speed just for cheat info.
	reportText = reportText .."\nTop Speed: ".. math.floor(watchUnit.topSpeed*100)/100 .. " units per second"
	
	-- Loop through our events and report our sightings.
	for index, event in ipairs(watchUnit.events) do
	
		-- Info on each sighting.
		reportText = reportText .."\n\n======= Witness Event #".. index .. " ======="
		reportText = reportText .."\nTime: ".. event.time
		reportText = reportText .."\nPosition: ".. event.position
		reportText = reportText .."\nBuffs: ".. event.buffs
		reportText = reportText .."\nDebuffs: ".. event.debuffs
		reportText = reportText .."\nSaw Gathering: "

		if event.didHarvest then
			reportText = reportText.."True"
		else
			reportText = reportText.."False"
		end
	end
	
	return reportText
end

---------------------------------------------------------------------------------------------------
-- Handles the View bot info button. Opens the report request window with more information.
---------------------------------------------------------------------------------------------------
function BotZapper:OnViewBotInfo( wndHandler, wndControl, eMouseButton )
	-- Open up more info.
	self.wndBotToast:Close()
	self:RequestReport(self.botInfoQueue[self.botInfoQueue.first])
end

---------------------------------------------------------------------------------------------------
-- Gets the report player ticket index.
---------------------------------------------------------------------------------------------------
function BotZapper:GetTicketType()
	-- Loop through the ticket types and return the index for the one that matches our desired ticket type.
	local errorTypes = PlayerTicket_GetErrorTypeList()	
	for _, currentError in ipairs(errorTypes) do
		if currentError.localizedText == "Report Player" then
			return currentError.index
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Gets the report bot/cheater subticket index.
---------------------------------------------------------------------------------------------------
function BotZapper:GetTicketSubType(type)
	-- Loop through the ticket subtypes and return the index for the one that matches our desired ticket subtype.
	local subTypes = PlayerTicket_GetSubtype(type)
	for _, currentError in ipairs(subTypes) do
		if currentError.localizedText == "Bot / Cheater" then
			return currentError.index
		end			
	end
end

-----------------------------------------------------------------------------------------------
-- Retruns a string based on a given buff table
-----------------------------------------------------------------------------------------------
function BotZapper:GetBuffNames(buffs)
	
	-- Add all buff names to a single string.
	local buffNames = ""
	for _, buff in pairs(buffs) do
		buffNames = buffNames..buff.splEffect:GetName().."|"
	end
	
	-- Remove the trailing "|"
	if buffNames:len() > 0 then
		buffNames = buffNames:sub(1, buffNames:len() - 1)
	end
	
	return buffNames
end

-----------------------------------------------------------------------------------------------
-- Returns a vector's length, ignoring the Y
-----------------------------------------------------------------------------------------------
function BotZapper:VectorDistance(pointA, pointB)

	-- People from cross faction tend to have a zero'd out position if they're not in line of sight.
	-- For this reason, we don't want to create a vector to the origin. Ignore their speed while either A or B are origin.
	if pointA.x == 0 and pointA.y == 0 and pointA.z == 0 then
		return 0
	end
	if pointB.x == 0 and pointB.y == 0 and pointB.z == 0 then
		return 0
	end
	
	--Ignoring Y as falling can generate fast movements. This will rule out false positives from falling.
	local deltaX = pointA.x - pointB.x
	local deltaZ = pointA.z - pointB.z
	
	--Ignoring Y as falling can generate fast movements. This will rule out false positives from falling.
	return math.sqrt((deltaX * deltaX) + (deltaZ * deltaZ))

end

-----------------------------------------------------------------------------------------------
-- Returns a string based on a given vector3
-----------------------------------------------------------------------------------------------
function BotZapper:PositionString(position)
	-- Returns an easy to read position string.
	return "X: "..math.floor(position.x).." | Y: "..math.floor(position.y).." | Z: "..math.floor(position.z)
end

-----------------------------------------------------------------------------------------------
-- Retruns true if using a gathering tool, or if targetting a harvest node and casting anything.
-----------------------------------------------------------------------------------------------
function BotZapper:IsGathering(unit)

	-- Have to be casting to gather.
	if unit:IsCasting() then
		
		-- Relic Hunter
		if unit:GetCastName():find("Relic Blaster") ~= nil then
			return true
		end
		
		-- Survivalist
		if unit:GetCastName():find("Laser Chainsaw") ~= nil then
			return true
		end
		
		-- Mining
		if unit:GetCastName():find("Laser Pickaxe") ~= nil then
			return true
		end
		
		-- Farming, but this doesn't seem to work on bots for some reason. I'll leave it in just incase it works some day.
		if unit:GetTarget() ~= nil and unit:GetTarget():GetType() == "Harvest" then
			return true
		end
			
	end
	
	return false

end

-----------------------------------------------------------------------------------------------
-- Returns a given table's lengt
------------------------------------------------------------------------------------------------
function BotZapper:TableLength(tArray)
	
	if tArray == nil then
		return -1
	end
	
	local nCount = 0
	for _ in pairs(tArray) do 
		nCount = nCount + 1 
	end
	return nCount
	
end

-----------------------------------------------------------------------------------------------
-- BotZapper Instance
-----------------------------------------------------------------------------------------------
local BotZapperInst = BotZapper:new()
BotZapperInst:Init()

-----------------------------------------------------------------------------------------------
-- Lua queue
-----------------------------------------------------------------------------------------------
List = {}
function List:new ()
  return {first = 0, last = -1}
end

function List:push (list, value)
  local last = list.last + 1
  list.last = last
  list[last] = value
end

function List:pop (list)
  local first = list.first
  if first > list.last then error("list is empty") end
  local value = list[first]
  list[first] = nil        -- to allow garbage collection
  list.first = first + 1
  return value
end

function List:getLength (list)
	return list.last - list.first + 1
end
