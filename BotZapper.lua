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

local tClasses = 	
{ 
	[GameLib.CodeEnumClass.Warrior]      = { name = Apollo.GetString("ClassWarrior"), },
	[GameLib.CodeEnumClass.Engineer]     = { name = Apollo.GetString("ClassEngineer"), },
	[GameLib.CodeEnumClass.Esper]        = { name = Apollo.GetString("ClassESPER"), },
	[GameLib.CodeEnumClass.Medic]        = { name = Apollo.GetString("ClassMedic"), },
	[GameLib.CodeEnumClass.Stalker]      = { name = Apollo.GetString("ClassStalker"), },
	[GameLib.CodeEnumClass.Spellslinger] = { name = Apollo.GetString("ClassSpellslinger"), },
} 

local tFactions =
{
	[Unit.CodeEnumFaction.DominionPlayer] 	= { name = "Dominion", },
	[Unit.CodeEnumFaction.ExilesPlayer] 	= { name = "Exile", },
}

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
	local tDependencies = {
		-- "UnitOrPackageName",
	}
	
	self.ticketType = self:GetTicketType()
	self.ticketSubType = self:GetTicketSubType(self.ticketType)
	
    Apollo.RegisterAddon(self, bHasConfigureFunction, strConfigureButtonText, tDependencies)
end
 

-----------------------------------------------------------------------------------------------
-- BotZapper OnLoad
-----------------------------------------------------------------------------------------------
function BotZapper:OnLoad()
	
	self.playerUnit = nil
	self.nearbyUnits = {}
	self.watchedUnits = {}
	self.ignoredUnits = {}
	self.botInfoQueue = List:new()
	self.currentTime = GameLib.GetGameTime()
	self.deltaTime = 0
	self.enabled = true
	
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
	    self.wndMain = Apollo.LoadForm(self.xmlDoc, "BotZapperForm", nil, self)
		self.wndReportRequest = Apollo.LoadForm(self.xmlDoc, "ReportRequestForm", nil, self)
		self.wndBotToast = Apollo.LoadForm(self.xmlDoc, "BotToastForm", nil, self)
		if self.wndMain == nil then
			Apollo.AddAddonErrorText(self, "Could not load the main window for some reason.")
			return
		end
		
	    self.wndMain:Show(false, true)
		self.wndReportRequest:Show(false, true)
		self.wndBotToast:Show(false, true)

		Apollo.RegisterSlashCommand("bz", "OnBotZapperOn", self)
		
		self.currentTime = GameLib.GetGameTime()
		self.deltaTime = 0
		updateTimer = ApolloTimer.Create(0.1, true, "OnTimerRefresh", self)
	end
end

-----------------------------------------------------------------------------------------------
-- on SlashCommand "/bz"
-----------------------------------------------------------------------------------------------
function BotZapper:OnBotZapperOn()
	self.wndMain:Invoke() -- show the window
end

-----------------------------------------------------------------------------------------------
-- Called when changing maps.
-----------------------------------------------------------------------------------------------
function BotZapper:OnChangeWorld()

	self.nearbyUnits = {}
	self.watchedUnits = {}
	self.botInfoQueue = List:new()
	
	self.wndMain:Close()
	self.wndBotToast:Close()
	self.wndReportRequest:Close()
	
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

	if self.enabled and unit:GetType() ~= "Player" then
		return
	end	
	
	local unit_ID = unit:GetId()
	
	if self.ignoredUnits[unit_ID] ~= nil then
		return
	end
	
	if unit:IsAccountFriend() or unit:IsFriend() or unit:IsInYourGroup() then
		self.ignoredUnits[unit_ID] = { id = unit_ID }
		return
	end

	
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
	
	if self.enabled and unit:GetType() ~= "Player" then
		return
	end	
	
	local unit_ID = unit:GetId()
	
	if self.ignoredUnits[unit_ID] ~= nil then
		return
	end
	
		
	local unitData = self.nearbyUnits[unit_ID]
	
	if unitData == nil then
		return
	end
	
	local suspicionLevel = 0

	if unitData.speedInfractions >= infractionLimit then
	
		suspicionLevel = suspicionLevel + 1
		
		if unitData.speedInfractions >= (infractionLimit + 2) then
			suspicionLevel = suspicionLevel + 1
		end
		
		local buffs = self:GetBuffNames(unit:GetBuffs().arBeneficial)
	
		if buffs:len() == 0 then
			suspicionLevel = suspicionLevel + 1
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "No buffs, added suspicion")-- DEBUG
		end
		
		if tZoneLimit[GameLib.GetCurrentZoneMap().id] ~= nil and (tZoneLimit[GameLib.GetCurrentZoneMap().id].level - unit:GetLevel()) > 5 then
			suspicionLevel = suspicionLevel + 2
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Underleveld for the zone, added suspicion "..unit:GetLevel())-- DEBUG
		end
		
		if unitData.harvestCount > 0 then
			suspicionLevel = suspicionLevel + 1
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Did harvest, added suspicion")-- DEBUG
		end
		
		if buffs:find("Authentication Dividends") ~= nil then
			suspicionLevel = 1
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Has authenticator, reduced suspicion")-- DEBUG
		end	
	 
		
		if self.watchedUnits[unit_ID] == nil then
		
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
		
		else
		
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
		
		if self.watchedUnits[unit_ID].suspicion >= reportableSuspicion then
		
			 -- DEBUG
			ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName())-- .. "=============================", "BotZapper")
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " Buffs = "..self:GetBuffNames(unit:GetBuffs().arBeneficial), "BotZapper" )
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " topSpeed = "..unitData.topSpeed, "BotZapper" )
			--ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, "Bot Detected: " .. unit:GetName() .. " speedInfractions = "..unitData.speedInfractions, "BotZapper" )	
			-- DEBUG	
		
			List:push(self.botInfoQueue, unit_ID)
			self.wndBotToast:Invoke()
		end
		
	end
	
	self.nearbyUnits[unit_ID] = nil
end

-----------------------------------------------------------------------------------------------
-- Update "loop"
-----------------------------------------------------------------------------------------------
function BotZapper:OnTimerRefresh()
	local currentTime = GameLib.GetGameTime()
	self.deltaTime = currentTime - self.currentTime 
	self.currentTime = currentTime
	
	local grid = self.wndMain:FindChild("Grid")
				
	grid:DeleteAll()

	for _,unitData in pairs(self.nearbyUnits) do
		
		local unit = GameLib.GetUnitById(_)
		if unit ~= nil then
			self:AddGridUnit(grid, unit)
			self:UpdateUnit(unit)
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Request screen to the player for reporing a player. Gives some information.
-----------------------------------------------------------------------------------------------
function BotZapper:RequestReport(unit_ID)
	
	local infoBox = self.wndReportRequest:FindChild("InfoBox")
	infoBox:SetText(self:GetReportText(unit_ID))
	
	self.wndReportRequest:Invoke()
	
end

-----------------------------------------------------------------------------------------------
-- Returns a vector's length, ignoring the Y
-----------------------------------------------------------------------------------------------
function BotZapper:VectorDistance(pointA, pointB)

	if pointA.x == 0 and pointA.y == 0 and pointA.z == 0 then
		return 0
	end
	if pointB.x == 0 and pointB.y == 0 and pointB.z == 0 then
		return 0
	end
	
	local deltaX = pointA.x - pointB.x
	--local deltaY = pointA.y - pointB.y
	local deltaZ = pointA.z - pointB.z
	
	--return math.sqrt((deltaX * deltaX) + (deltaY * deltaY) + (deltaZ * deltaZ))
	return math.sqrt((deltaX * deltaX) + (deltaZ * deltaZ))

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
-- Updates our nearby units
-----------------------------------------------------------------------------------------------
function BotZapper:UpdateUnit(unit)

	local unitData = self.nearbyUnits[unit:GetId()]	
	
	if self.currentTime - unitData.creationTime > 15 then
		self:OnUnitDestroyed(unit)
		self:OnUnitCreated(unit)
		return
	end
	
	local unitPosition = unit:GetPosition()
	
	if unit:IsMounted() == false then
		local speed = self:VectorDistance(unitData.lastPos, unitPosition)
		
		if speed * self.deltaTime > infractionSpeed then
			unitData.speedInfractions = unitData.speedInfractions + 1
			unitData.topSpeed = math.max(unitData.topSpeed, speed)
			--unit:ShowHintArrow()
		end
		
	end
	
	if self:IsGathering(unit) then
		unitData.harvestCount = unitData.harvestCount + 1
	end

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
-- Retruns a string based on a given buff table
-----------------------------------------------------------------------------------------------
function BotZapper:GetBuffNames(buffs)
	local buffNames = ""
	
	for _, buff in pairs(buffs) do
		buffNames = buffNames..buff.splEffect:GetName().."|"
	end
	
	if buffNames:len() > 0 then
		buffNames = buffNames:sub(1, buffNames:len() - 1)
	end
	
	return buffNames
end

-----------------------------------------------------------------------------------------------
-- Returns a string based on a given vector3
-----------------------------------------------------------------------------------------------
function BotZapper:PositionString(position)
	return "X: "..math.floor(position.x).." | Y: "..math.floor(position.y).." | Z: "..math.floor(position.z)
end

-----------------------------------------------------------------------------------------------
-- Retruns true if using a gathering tool, or if targetting a harvest node and casting anything.
-----------------------------------------------------------------------------------------------
function BotZapper:IsGathering(unit)

	if unit:IsCasting() then
		
		if unit:GetCastName():find("Relic Blaster") ~= nil then
			return true
		end
		if unit:GetCastName():find("Laser Chainsaw") ~= nil then
			return true
		end
		if unit:GetCastName():find("Laser Pickaxe") ~= nil then
			return true
		end
		

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
		return 0
	end
	
	local nCount = 0
	for _ in pairs(tArray) do 
		nCount = nCount + 1 
	end
	return nCount
	
end

---------------------------------------------------------------------------------------------------
-- ReportRequestForm Functions
---------------------------------------------------------------------------------------------------

function BotZapper:GetTicketType()
	local errorTypes = PlayerTicket_GetErrorTypeList()	
	for _, currentError in ipairs(errorTypes) do
		if currentError.localizedText == "Report Player" then
			return currentError.index
		end
	end
end

function BotZapper:GetTicketSubType(type)
	local subTypes = PlayerTicket_GetSubtype(type)
	for _, currentError in ipairs(subTypes) do
		if currentError.localizedText == "Bot / Cheater" then
			return currentError.index
		end			
	end
end

function BotZapper:OnGenerateReportButton( wndHandler, wndControl, eMouseButton )

	local unit_ID = List:pop(self.botInfoQueue)
	
	
	--PlayerTicketDialog_Report()
	
	ChatSystemLib.PostOnChannel( ChatSystemLib.ChatChannel_Debug, self:GetReportText(unit_ID))-- DEBUG
	
	self.ignoredUnits[unit_ID] = { id = unit_ID }
	self.watchedUnits[unit_ID] = nil
	self.nearbyUnits[unit_ID] = nil
	self.wndReportRequest:Close()
	
	if List:getLength(self.botInfoQueue) > 0 then
		self.wndBotToast:Invoke()
	end

end

function BotZapper:GetReportText(unit_ID)
	local reportText = ""
	local watchUnit = self.watchedUnits[unit_ID]
	
	reportText = reportText .."Player: ".. watchUnit.name
	reportText = reportText .."\nUnit ID: ".. watchUnit.unitID
	
	reportText = reportText .."\nHas Authenticator: "
	if watchUnit.events[0].buffs:find("Authentication Dividends") then
		reportText = reportText .."True"
	else
		reportText = reportText .."False"
	end	
	
	reportText = reportText .."\nLevel: ".. watchUnit.level
	if tZoneLimit[GameLib.GetCurrentZoneMap().id] ~= nil and (tZoneLimit[GameLib.GetCurrentZoneMap().id].level - watchUnit.level) > 5 then
		reportText = reportText .." (underleveled for this zone)"
	end

	reportText = reportText .."\nFaction: ".. watchUnit.faction
	reportText = reportText .."\nClass: ".. watchUnit.class
	reportText = reportText .."\nZone: ".. watchUnit.zone
	reportText = reportText .."\nServer: ".. GameLib.GetRealmName()
	
	reportText = reportText .."\nTop Speed: ".. math.floor(watchUnit.topSpeed*100)/100
	
	for index, event in ipairs(watchUnit.events) do
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

function BotZapper:OnIgnoreUnitButton( wndHandler, wndControl, eMouseButton )

	local unit_ID = List:pop(self.botInfoQueue)
	
	self.ignoredUnits[unit_ID] = { id = unit_ID }
	self.watchedUnits[unit_ID] = nil
	self.nearbyUnits[unit_ID] = nil
	self.wndReportRequest:Close()
	
	if List:getLength(self.botInfoQueue) > 0 then
		self.wndBotToast:Invoke()
	end
	
end

function BotZapper:OnWaitReportButton( wndHandler, wndControl, eMouseButton )
	List:pop(self.botInfoQueue)
	
	if List:getLength(self.botInfoQueue) > 0 then
		self.wndBotToast:Invoke()
	end
	
	self.wndReportRequest:Close()
end

---------------------------------------------------------------------------------------------------
-- BotToast Functions
---------------------------------------------------------------------------------------------------

function BotZapper:OnViewBotInfo( wndHandler, wndControl, eMouseButton )
	self.wndBotToast:Close()
	self:RequestReport(self.botInfoQueue[self.botInfoQueue.first])
end

-----------------------------------------------------------------------------------------------
-- BotZapper Instance
-----------------------------------------------------------------------------------------------
local BotZapperInst = BotZapper:new()
BotZapperInst:Init()
