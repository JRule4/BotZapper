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
local infractionSpeed = 150
local infractionLimit = 4
local reportableSuspicion = 5
local reinsertionTimer = 15

local whiteColor = ApolloColor.new("white")
local greenColor = ApolloColor.new("green")

-- Class name table
local tClasses = 	
{ 
	[GameLib.CodeEnumClass.Warrior]      = Apollo.GetString("ClassWarrior"),
	[GameLib.CodeEnumClass.Engineer]     = Apollo.GetString("ClassEngineer"),
	[GameLib.CodeEnumClass.Esper]        = Apollo.GetString("ClassESPER"),
	[GameLib.CodeEnumClass.Medic]        = Apollo.GetString("ClassMedic"),
	[GameLib.CodeEnumClass.Stalker]      = Apollo.GetString("ClassStalker"),
	[GameLib.CodeEnumClass.Spellslinger] = Apollo.GetString("ClassSpellslinger"),
} 

-- Faction name table
local tFactions =
{
	[Unit.CodeEnumFaction.DominionPlayer] 	= "Dominion",
	[Unit.CodeEnumFaction.ExilesPlayer] 	= "Exile",
}

-- Zone level limits for determining if a player is underleveled
local tZoneLimit = 
{
	[GameLib.MapZone.Whitevale] 		= 22,
	[75]			 					= 29, --Farside Biodome 3
	[75]			 					= 29, --Farside Biodome 4
	[28]			 					= 32, --Farside Moon
	[GameLib.MapZone.Wilderrun] 		= 35,
	[GameLib.MapZone.Malgrave] 			= 40,
	[GameLib.MapZone.Grimvault] 		= 46,
	[GameLib.MapZone.WesternGrimvault] 	= 46,
	[GameLib.MapZone.NorthernGrimvault] = 50,
}

local tPickAxeName =
{
	["EN"] = "Laser Pickaxe",
	["DE"] = "Laserspitzhacke",
	["FR"] = "Extracto-laser",
}

local tChainsawName =
{
	["EN"] = "Laser Chainsaw",
	["DE"] = "Lasersäge",
	["FR"] = "Tronçonneuse-laser",
}

local tRelicBlasterName =
{
	["EN"] = "Relic Blaster",
	["DE"] = "Reliktblaster",
	["FR"] = "Extracteur de reliques",
}

local ticketTypeText = Apollo.GetString(77542) --"Report Player"
local ticketSubTypeText = Apollo.GetString(77548) --"Bot / Cheater"
local harvestText = Apollo.GetString(4440) --"Harvest"

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
	self.reportableBotTable = {}
	self.currentTime = GameLib.GetGameTime()
	self.deltaTime = 0
	self.enabled = true
	self.reportDisplayID = -1
	
	self.currentLanguage= GetClientLanguage()
		
	
    Apollo.RegisterAddon(self, bHasConfigureFunction, strConfigureButtonText, tDependencies)	
	
	Apollo.RegisterEventHandler("UnitCreated", 		"OnUnitCreated", self)		
	Apollo.RegisterEventHandler("UnitDestroyed", 	"OnUnitDestroyed", self)
end

-----------------------------------------------------------------------------------------------
-- BotZapper OnLoad
-----------------------------------------------------------------------------------------------
function BotZapper:OnLoad()
		
    -- load our form file
	self.xmlDoc = XmlDoc.CreateFromFile("BotZapper.xml")
	self.xmlDoc:RegisterCallback("OnDocLoaded", self)


	Apollo.RegisterEventHandler("ChangeWorld",		"OnChangeWorld", self)
	
end

-----------------------------------------------------------------------------------------------
-- BotZapper OnDocLoaded
-----------------------------------------------------------------------------------------------
function BotZapper:OnDocLoaded()

	if self.xmlDoc ~= nil and self.xmlDoc:IsLoaded() then
		-- Report request form.
		self.wndReportRequest = Apollo.LoadForm(self.xmlDoc, "ReportRequestForm", nil, self)
		-- Toast form.
		self.wndBotToast = Apollo.LoadForm(self.xmlDoc, "BotToastForm", nil, self)
		
		self.wndInfo = Apollo.LoadForm(self.xmlDoc, "BotZapperInfo", nil, self)
		
		self.toastButton = self.wndBotToast:FindChild("Button")
		
		self.infoTextBox = self.wndReportRequest:FindChild("InfoBox")
		
		self.nearbyGrid = self.wndInfo:FindChild("NearbyGrid")
		self.watchGrid = self.wndInfo:FindChild("WatchGrid")
		self.ignoredGrid = self.wndInfo:FindChild("IgnoredGrid")
		
		self.nearbyButton = self.wndInfo:FindChild("NearbyButton")
		self.watchingButton = self.wndInfo:FindChild("WatchingButton")
		self.ignoredButton = self.wndInfo:FindChild("IgnoredButton")
		
		-- Hide all windows by default.
		self.wndReportRequest:Show(false, true)
		self.wndBotToast:Show(false, true)
		self.wndInfo:Show(false, true)

		-- Debug access.
		Apollo.RegisterSlashCommand("bz", "OnBotZapperOn", self)
		
		updateTimer = ApolloTimer.Create(.1, true, "OnTimerRefresh", self)
	end
end

function BotZapper:Disable()

	if self.enabled == false then
		return
	end
	self.enabled = false		
	Apollo.RemoveEventHandler("UnitCreated", self)		
	Apollo.RemoveEventHandler("UnitDestroyed", self)
	
	-- Clear lists.
	self.nearbyUnits = {}
	self.watchedUnits = {}
	self.reportableBotTable = {}
	
	-- Clear grids
	self.nearbyGrid:DeleteAll()
	self.watchGrid:DeleteAll()
	self.ignoredGrid:DeleteAll()
		
	-- Close windows.
	self.wndBotToast:Close()
	self.wndReportRequest:Close()
	self.wndInfo:Close()
end

-----------------------------------------------------------------------------------------------
-- Called when changing maps.
-----------------------------------------------------------------------------------------------
function BotZapper:OnChangeWorld()
	self:Disable()		
end

function BotZapper:UpdateZone()
	--Determine if we should run this addon or not.
	local zoneInfo = GameLib.GetCurrentZoneMap()
	
	if zoneInfo == nil then
		--if self.enabled == true then ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "ZoneInfo is Null") end
		self:Disable()	
	elseif zoneInfo.id == GameLib.MapZone.Illium or zoneInfo.id == GameLib.MapZone.Thayd then
		--if self.enabled == true then ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "IsInTown is True") end
		self:Disable()
	elseif self.enabled == false then
		--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "self.enabled = true")
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
	if self.enabled == false or unit:GetType() ~= "Player" then
		return
	end	
	
	local unit_ID = unit:GetId()
	
	-- If they exist in the ignore table, ignore them.
	if self.ignoredUnits[unit_ID] ~= nil then
		return
	end
	
	-- Automatically add friends and groupmembers to the ignore list.
	if unit:IsAccountFriend() or unit:IsFriend() or unit:IsInYourGroup() then
		self.ignoredUnits[unit_ID] = { name = unit:GetName(), action = "Friend" }
		return
	end	
	
	if self.nearbyGrid ~= nil then
		self.nearbyGrid:AddRow(unit:GetName(), "", unit_ID)
	end

		
	-- Setup basic data for a new unit.
	self.nearbyUnits[unit_ID] = {
									lastPos = unit:GetPosition(),
									creationTime = GameLib.GetGameTime(),
									speedInfractions = 0,
									topSpeed = 0,
									harvestCount = 0,
									speed = 0,
									totalDistance = 0
								}
end

-----------------------------------------------------------------------------------------------
-- Called when a unit is destroyed. This is where we implement logic to determine if a unit is a bot or not.
-----------------------------------------------------------------------------------------------
function BotZapper:OnUnitDestroyed(unit)
	
	-- We only want to run on player units if we are enabled.
	if self.enabled == false or unit:GetType() ~= "Player" then
		return
	end	
	
	local unit_ID = unit:GetId()
	
	self.nearbyGrid:DeleteRowsByData(unit_ID)
	
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
		if tZoneLimit[GameLib.GetCurrentZoneMap().id] ~= nil and (tZoneLimit[GameLib.GetCurrentZoneMap().id] - unit:GetLevel()) >= 5 then
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
				faction = tFactions[unit:GetFaction()],
				class = tClasses[unit:GetClassId()],
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
					[1] = 	{
								time = os.date("!%c").." UTC",
								position = PositionString(unit:GetPosition()),
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
			watchUnit.eventCount = watchUnit.eventCount + 1
			watchUnit.events[watchUnit.eventCount] = 	
			{
				time = os.date("!%c").." UTC",
				position = PositionString(unit:GetPosition()),
				buffs = self:GetBuffNames(unit:GetBuffs().arBeneficial),
				debuffs = self:GetBuffNames(unit:GetBuffs().arHarmful),
				didHarvest = unitData.harvestCount > 0,					
			}
		
		end
	
		--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Total Suspicion = "..self.watchedUnits[unit_ID].suspicion) --DEBUG
		
		-- We've reched the point that which we will report this player.
		if self.watchedUnits[unit_ID].suspicion >= reportableSuspicion then
		
			 -- DEBUG
			ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. "========", "BotZapper")
			ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " Buffs = "..self:GetBuffNames(unit:GetBuffs().arBeneficial), "BotZapper" )
			ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " topSpeed = "..unitData.topSpeed, "BotZapper" )
			ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " speedInfractions = "..unitData.speedInfractions, "BotZapper" )	
			-- DEBUG	
		
			--Add them to the table
			if self.reportableBotTable[unit_ID] == nil then
				self.reportableBotTable[unit_ID] = self.currentTime
			end
			--popup a toast for the player if another menu isn't already up.
			if self.wndReportRequest:IsShown() == false then
				self.wndBotToast:Invoke()
			end			
		end
		
		self:UpdateWatchedUnitInfo(unit_ID)
		
	end
	
	-- Remove the nearbyUnit since it has been destroyed.
	self.nearbyUnits[unit_ID] = nil
end

-----------------------------------------------------------------------------------------------
-- Update "loop"
-----------------------------------------------------------------------------------------------
function BotZapper:OnTimerRefresh()

	self:UpdateZone()
	-- Update time first, so we can use it in the updates.
	local currentTime = GameLib.GetGameTime()
	self.deltaTime = currentTime - self.currentTime 
	self.currentTime = currentTime
	
	if self.wndBotToast:IsShown() then
		self.toastButton:SetBGColor(LerpColor(whiteColor, greenColor, (math.sin(self.currentTime*5) + 1) / 2))
	end

	-- Loop through all nearbyUnits and update them so that we can generate info on them.
	for index,unitData in pairs(self.nearbyUnits) do
		local unit = GameLib.GetUnitById(index)
		if unit ~= nil then
			self:UpdateUnit(unit)
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Updates our nearby units
-----------------------------------------------------------------------------------------------
function BotZapper:UpdateUnit(unit)

	local unit_ID = unit:GetId()
	local unitData = self.nearbyUnits[unit_ID]	
	
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
		local distance = VectorDistance(unitData.lastPos, unitPosition)
		unitData.speed = distance / self.deltaTime
		unitData.totalDistance = unitData.totalDistance + distance
		unitData.topSpeed = math.max(unitData.topSpeed, unitData.speed)

		if unitData.speed > infractionSpeed then
			unitData.speedInfractions = unitData.speedInfractions + 1
									
			--unit:ShowHintArrow()
		end
		
		-- Watching for gathering.
		if self:IsGathering(unit) then
			unitData.harvestCount = unitData.harvestCount + 1
		end
		
	end

	-- Update positional data for next update.
	self.nearbyUnits[unit_ID].lastPos = unitPosition;
	self.nearbyUnits[unit_ID].lastPosTime = self.currentTime;
	self:UpdateNearbyUnitInfo(unit_ID)
end

---------------------------------------------------------------------------
-- on SlashCommand "/bz"
-----------------------------------------------------------------------------------------------
function BotZapper:OnBotZapperOn()
	self.wndInfo:Invoke()
	self:OnDisplayNearby()

	self.nearbyButton:SetCheck(true)
	self.watchingButton:SetCheck(false)
	self.ignoredButton:SetCheck(false)
end

-----------------------------------------------------------------------------------------------
-- Request screen to the player for reporing a player. Gives some information.
-----------------------------------------------------------------------------------------------
function BotZapper:RequestReport(unit_ID)
	
	--Open up the request report screen and fill out the text.
	self.infoTextBox:SetText(self:GetReportText(unit_ID))
	self.reportDisplayID = unit_ID
	
	self.wndReportRequest:Invoke()
	
end

---------------------------------------------------------------------------------------------------
-- Handles the generate report button from the toast window.
---------------------------------------------------------------------------------------------------
function BotZapper:OnGenerateReportButton( wndHandler, wndControl, eMouseButton )

	-- Grab the oldest one
	local unit_ID = self.reportDisplayID
	
	if unit_ID == -1 then
		self.wndReportRequest:Close()
		return
	end
	
	PlayerTicketDialog_Report(self.ticketType, self.ticketSubType, self:GetReportText(unit_ID))
	--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, self:GetReportText(unit_ID))-- DEBUG
	
	-- Add them to the ignored units. Clear them out from any other tables.
	self.ignoredUnits[unit_ID] = { name = unit:GetName(), action = "Reported" }
	self.watchedUnits[unit_ID] = nil
	self.nearbyUnits[unit_ID] = nil
	self.reportableBotTable[unit_ID] = nil
	self.nearbyGrid:DeleteRowsByData(unit_ID)
	self.watchGrid:DeleteRowsByData(unit_ID)
	self:UpdateIgnoredInfo(unit_ID)
	self.wndReportRequest:Close()
	
	-- If we have more in the table, popup a new window.
	if self:GetFirstReportableBot() ~= -1 then
		self.wndBotToast:Invoke()
	end
	
	self.reportDisplayID = -1

end

---------------------------------------------------------------------------------------------------
-- Handles the ignore button in the report request screen. 
-- Removes the unit from the reportable bot table, adds them to the ignore table. and moves to the next.
---------------------------------------------------------------------------------------------------
function BotZapper:OnIgnoreUnitButton( wndHandler, wndControl, eMouseButton )

	-- Grab the oldest one
	local unit_ID = self.reportDisplayID
	
	if unit_ID == -1 then
		self.wndReportRequest:Close()
		return
	end
		
	-- Add them to the ignored units. Clear them out from any other tables.
	self.ignoredUnits[unit_ID] = { name = self.watchedUnits[unit_ID].name, action = "Ignored" }
	self.watchedUnits[unit_ID] = nil
	self.nearbyUnits[unit_ID] = nil
	self.reportableBotTable[unit_ID] = nil
	self.nearbyGrid:DeleteRowsByData(unit_ID)
	self.watchGrid:DeleteRowsByData(unit_ID)
	self:UpdateIgnoredInfo(unit_ID)
	self.wndReportRequest:Close()
	
	-- If we have more in the table, popup a new window.
	if self:GetFirstReportableBot() ~= -1 then
		self.wndBotToast:Invoke()
	end
	
	self.reportDisplayID = -1
	
end

---------------------------------------------------------------------------------------------------
-- Handles the "Gather more info" button in the report request.
-- Removes the unit from the reportable bot table, and moves to the next. 
-- The unit will pop up a dialogue again when it it seen next time.
---------------------------------------------------------------------------------------------------
function BotZapper:OnWaitReportButton( wndHandler, wndControl, eMouseButton )
	
	-- Grab the oldest one
	local unit_ID = self.reportDisplayID
	
	if unit_ID == -1 then
		self.wndReportRequest:Close()
		return
	end
	
	self.reportableBotTable[unit_ID] = nil
	
	self.wndReportRequest:Close()
		
	-- If we have more in the table, popup a new window.
	if self:GetFirstReportableBot() ~= -1 then
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
	reportText = reportText .."\nUnitID: ".. watchUnit.unitID
	
	--We can report if they have an authenticator or not.
	reportText = reportText .."\nAuthenticator: "
	if watchUnit.events[1].buffs:find("Authentication Dividends") then
		reportText = reportText .."True"
	else
		reportText = reportText .."False"
	end	
	
	--We report if they're underleveled for the zone.
	reportText = reportText .."\nLevel: ".. watchUnit.level
	if tZoneLimit[GameLib.GetCurrentZoneMap().id] ~= nil and (tZoneLimit[GameLib.GetCurrentZoneMap().id] - watchUnit.level) > 5 then
		reportText = reportText .." (underleveled for this zone)"
	end
	
	-- More Player information.
	reportText = reportText .."\nFaction: ".. watchUnit.faction
	reportText = reportText .."\nClass: ".. watchUnit.class
	reportText = reportText .."\nZone: ".. watchUnit.zone
	reportText = reportText .."\nServer: ".. GameLib.GetRealmName()
	
	-- Top speed just for cheat info.
	reportText = reportText .."\nTop Speed: ".. math.floor(watchUnit.topSpeed*100)/100 .. " units/sec"
	
	-- Loop through our events and report our sightings.
	for index, event in ipairs(watchUnit.events) do
	
		--if index > 2 then
		--	break
		--end
		-- Info on each sighting.
		reportText = reportText .."\n\n== Event ".. index .. " =="
		reportText = reportText .."\nTime: ".. event.time
		reportText = reportText .."\nPosition: ".. event.position
		reportText = reportText .."\nBuffs: ".. event.buffs
		reportText = reportText .."\nDebuffs: ".. event.debuffs
		reportText = reportText .."\nGathering: "

		if event.didHarvest then
			reportText = reportText.."True"
		else
			reportText = reportText.."False"
		end
	end
	
	reportText = reportText .."\n\nReported by BotZapper"
	
	return reportText
end

---------------------------------------------------------------------------------------------------
-- Gets the first bot in a list sorted by time.
---------------------------------------------------------------------------------------------------
function BotZapper:GetFirstReportableBot()
	for key,value in spairs(self.reportableBotTable, function(t,a,b) return t[b] > t[a] end) do
		return key
	end
	
	return -1
end

---------------------------------------------------------------------------------------------------
-- Handles the View bot info button. Opens the report request window with more information.
---------------------------------------------------------------------------------------------------
function BotZapper:OnViewBotInfo( wndHandler, wndControl, eMouseButton )
	-- Open up more info.
	self.wndBotToast:Close()
	self:RequestReport(self:GetFirstReportableBot())
end

---------------------------------------------------------------------------------------------------
-- Gets the report player ticket index.
---------------------------------------------------------------------------------------------------
function BotZapper:GetTicketType()
	-- Loop through the ticket types and return the index for the one that matches our desired ticket type.
	local errorTypes = PlayerTicket_GetErrorTypeList()	
	for _, currentError in ipairs(errorTypes) do
		if currentError.localizedText == ticketTypeText then
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
		if currentError.localizedText == ticketSubTypeText then
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
function VectorDistance(pointA, pointB)

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
function PositionString(position)
	-- Returns an easy to read position string.
	return "X:"..math.floor(position.x).."|Y:"..math.floor(position.y).."|Z:"..math.floor(position.z)
end

-----------------------------------------------------------------------------------------------
-- Retruns true if using a gathering tool, or if targetting a harvest node and casting anything.
-----------------------------------------------------------------------------------------------
function BotZapper:IsGathering(unit)

	-- Have to be casting to gather.
	if unit:IsCasting() then
		
		-- Relic Hunter
		if unit:GetCastName():find(tRelicBlasterName[self.currentLanguage]) ~= nil then
			return true
		end
		
		-- Survivalist
		if unit:GetCastName():find(tChainsawName[self.currentLanguage]) ~= nil then
			return true
		end
		
		-- Mining
		if unit:GetCastName():find(tPickAxeName[self.currentLanguage]) ~= nil then
			return true
		end
		
		-- Farming, but this doesn't seem to work on bots for some reason. I'll leave it in just incase it works some day.
		if unit:GetTarget() ~= nil and unit:GetTarget():GetType() == harvestText then
			return true
		end
			
	end
	
	return false

end

-----------------------------------------------------------------------------------------------
-- Interpolate between two colors
-----------------------------------------------------------------------------------------------
function LerpColor(colorA, colorB, t)
	return ApolloColor.new(colorA.r + (colorB.r - colorA.r) * t, colorA.g + (colorB.g - colorA.g) * t, colorA.b + (colorB.b - colorA.b) * t)
end

-----------------------------------------------------------------------------------------------
-- Returns a given table's length
-----------------------------------------------------------------------------------------------
function TableLength(tArray)
	
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
-- Use for sorting tables.
-- Returns an interator sorted by the function
-----------------------------------------------------------------------------------------------
function spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys 
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

-----------------------------------------------------------------------------------------------
-- Returns the client language
-----------------------------------------------------------------------------------------------
function GetClientLanguage()

	local strCancel = Apollo.GetString(1)

	-- German
	if strCancel == "Abbrechen" then 
		return "DE"
	end

	-- French
	if strCancel == "Annuler" then
		return "FR"
	end

	return "EN"
	
end

-----------------------------------------------------------------------------------------------
-- Logs data to the chat window
-----------------------------------------------------------------------------------------------
function Log(output)
	ChatSystemLib.PostOnChannel(ChatSystemLib.ChatChannel_Debug, output, "BotZapper")
end

---------------------------------------------------------------------------------------------------
-- BotZapperInfo Functions
---------------------------------------------------------------------------------------------------

function BotZapper:OnDisplayNearby( wndHandler, wndControl, eMouseButton )	
	self.nearbyGrid:Show(true, false)
	self.watchGrid:Show(false, false)
	self.ignoredGrid:Show(false, false)
end

function BotZapper:OnDisplayWatch( wndHandler, wndControl, eMouseButton )
	self.nearbyGrid:Show(false, false)
	self.watchGrid:Show(true, false)
	self.ignoredGrid:Show(false, false)
end

function BotZapper:OnDisplayIgnored( wndHandler, wndControl, eMouseButton )
	self.nearbyGrid:Show(false, false)
	self.watchGrid:Show(false, false)
	self.ignoredGrid:Show(true, false)
end


function BotZapper:OnClickWatched( wndHandler, wndControl, eMouseButton, nLastRelativeMouseX, nLastRelativeMouseY )
	
	if eMouseButton ~= 0 then
		return
	end
	
	local focusRow = self.watchGrid:GetFocusRow()
	
	if focusRow ~= nil then
		self.watchGrid:SetCurrentRow(0)
		self:RequestReport(self.watchGrid:GetCellLuaData(focusRow, 1))
	end
	
end

function BotZapper:OnCloseInfoButton( wndHandler, wndControl, eMouseButton )
	self.wndInfo:Close()
end

-----------------------------------------------------------------------------------------------
-- Updates a nearby unit in the nearby grid.
-----------------------------------------------------------------------------------------------
function BotZapper:UpdateNearbyUnitInfo(unit_ID)

	local grid = self.nearbyGrid	local rowIndex = -1
	
	for i=0, grid:GetRowCount() do
		if grid:GetCellLuaData(i, 1) == unit_ID then
			rowIndex = i
			break
		end
	end
	
	local unitData = self.nearbyUnits[unit_ID]
	local unit = GameLib.GetUnitById(unit_ID)
	
	if rowIndex == -1 then
		rowIndex = grid:AddRow(unit:GetName(), "", unit_ID)
		grid:SetCellLuaData(rowIndex, 1, unit_ID)
	end
	
	 
	grid:SetCellText(rowIndex, 2, unit:GetLevel())
	grid:SetCellText(rowIndex, 3, math.floor(unitData.speed))
	grid:SetCellText(rowIndex, 4, math.floor(unitData.topSpeed))
	grid:SetCellText(rowIndex, 5, unitData.speedInfractions)
	if unitData.harvestCount > 0 then 
		grid:SetCellText(rowIndex, 6, "True")
	else
		grid:SetCellText(rowIndex, 6, "False")
	end
	grid:SetCellText(rowIndex, 7, math.floor(unitData.totalDistance))
	
end

-----------------------------------------------------------------------------------------------
-- Updates a nearby unit in the nearby grid.
-----------------------------------------------------------------------------------------------
function BotZapper:UpdateWatchedUnitInfo(unit_ID)

	local grid = self.watchGrid
	local rowIndex = -1
	
	for i=0, grid:GetRowCount() do
		if grid:GetCellLuaData(i, 1) == unit_ID then
			rowIndex = i
			break
		end
	end
	
	local watchedData = self.watchedUnits[unit_ID]
		
	if rowIndex == -1 then
		rowIndex = grid:AddRow(watchedData.name, "", unit_ID)
		grid:SetCellLuaData(rowIndex, 1, unit_ID)
	end
	
	 
	grid:SetCellText(rowIndex, 2, watchedData.level)
	grid:SetCellText(rowIndex, 3, math.floor(watchedData.topSpeed))
	grid:SetCellText(rowIndex, 4, watchedData.speedInfractions)
	if watchedData.didHarvest then 
		grid:SetCellText(rowIndex, 5, "True")
	else
		grid:SetCellText(rowIndex, 5, "False")
	end
	grid:SetCellText(rowIndex, 6, watchedData.suspicion)
	grid:SetCellText(rowIndex, 7, watchedData.eventCount)
	
end

function BotZapper:UpdateIgnoredInfo(unit_ID)

	local grid = self.ignoredGrid
	local rowIndex = -1
	
	for i=0, grid:GetRowCount() do
		if grid:GetCellLuaData(i, 1) == unit_ID then
			rowIndex = i
			break
		end
	end
	
	local ignoredData = self.ignoredUnits[unit_ID]

	if rowIndex == -1 then
		rowIndex = grid:AddRow(ignoredData.name, "", unit_ID)
		grid:SetCellLuaData(rowIndex, 1, unit_ID)
	end
	
	grid:SetCellText(rowIndex, 2, ignoredData.action)

end


-----------------------------------------------------------------------------------------------
-- BotZapper Instance
-----------------------------------------------------------------------------------------------
local BotZapperInst = BotZapper:new()
BotZapperInst:Init()
