--[[
	MapOfScars - a World of Warcraft (1.12.1) compass AddOn
	Original: Lanrutcon, backported by moh / yutsuku
	https://github.com/yutsuku/MapOfScars

	This revision adds *optional* integration with a few 1.12 client mods.
	Everything degrades gracefully if a mod isn't loaded - the addon still
	works exactly like stock MapOfScars with none of them installed.

	  - ClassicAPI  https://github.com/brues-code/ClassicAPI
	                Does the heavy lifting here, and turns out to cover
	                everything the unit-tracking feature needs on its own:
	                  * GetPlayerFacing() - native facing, replaces the old
	                    "hidden minimap + 0-scale player-arrow model" hack.
	                  * C_Map.GetPlayerMapPosition(uiMapID, unit) - map-percent
	                    position for ANY visible/synced unit (target, mouseover,
	                    nameplates, party/raid), not just "player". Far more
	                    reliable than hoping the stock GetPlayerMapPosition
	                    accepts a non-player token.
	                  * UnitDistanceSquared(unit) - real yard distance,
	                    self-contained (no sibling DLL needed).
	                  * UnitInLineOfSight(unit) - real terrain+WMO line of
	                    sight, self-contained, and documented to route
	                    through UnitXP_SP3's own hook when that's ALSO
	                    loaded, so the two never fight over the same check.
	                  * C_Timer.NewTicker - used to throttle the POI
	                    distance/LoS refresh to 5/sec instead of every frame.
	                We deliberately never call the bare global UnitPosition()
	                here: ClassicAPI and SuperWoW both register a function
	                under that exact name with different return shapes, and
	                whichever loads last silently wins - a real, documented
	                footgun. Everything above sidesteps it entirely.

	  - UnitXP_SP3  https://codeberg.org/konaka/UnitXP_SP3
	                UnitXP("distanceBetween", ...) / UnitXP("inSight", ...).
	                Kept only as the FALLBACK for distance/LoS when
	                ClassicAPI isn't installed - with ClassicAPI present,
	                its own UnitDistanceSquared/UnitInLineOfSight are used
	                instead (see above), so UnitXP_SP3 is no longer
	                required for this addon's features, just still supported.

	  - SuperWoW    https://github.com/balakethelock/SuperWoW
	                UnitExists(unit) returns a GUID as its 2nd value when
	                SuperWoW is loaded. Used to key unit-tracked POIs so a
	                stale/reused unit id can't hijack someone else's marker.

	  - nampower    https://github.com/brues-code/nampower
	  - VanillaHelpers https://github.com/isfir/VanillaHelpers
	  - WeirdUtils  https://codeberg.org/MarcelineVQ/WeirdUtils
	                None of the three expose anything a compass addon can
	                use: nampower is spell-cast queueing, VanillaHelpers is
	                texture/model swapping + file IO, and WeirdUtils' only
	                position-related feature (WorldMarker) is gated to raid
	                leader/assist and returns nil otherwise - not usable as
	                a general "where is this unit" query. All three are only
	                reported by /mosstatus for debugging, never used.
]]

local Addon = CreateFrame('Frame')
local compass

local POITable = {}

local pi = math.pi
local halfPi = pi/2 -- ~1.57
local quarterPi = pi/4 -- ~0.785
local threeHalfPi = 3*pi/2 -- ~4.71
local twoPi = 2*pi -- ~6.28
local fiveQuarterPi = 5*pi/4 -- ~3.925
local threeQuarterPi = 3*pi/4 -- ~2.355
local sevenQuarterPi = 7*pi/4 -- ~5.495

local floor = math.floor
local sqrt = math.sqrt
local arctan2 = math.atan2
local pairs = pairs
local select = select

local GetPlayerMapPosition = GetPlayerMapPosition

local playerX, playerY
local playerAngle = 0

local FADE_IN = 0.3
local FADE_OUT = 0.3
local OPACITY_COMPASS = 0.7
local OPACITY_LABELS = 0.5

---------------------------------------------
-- Mod detection
---------------------------------------------

-- Captured BEFORE we define our own local GetPlayerFacing below.
-- On stock 1.12 this is nil. If ClassicAPI (or another mod that
-- backports the modern API) is loaded, this is the real engine function.
local NativeGetPlayerFacing = GetPlayerFacing

local HAS_CLASSICAPI = type(NativeGetPlayerFacing) == 'function'

-- ClassicAPI's C_Map namespace. GetPlayerMapPosition here works for any
-- visible/synced unit, not just "player" - see header comment.
local HAS_CMAP = (type(C_Map) == 'table'
	and type(C_Map.GetPlayerMapPosition) == 'function'
	and type(C_Map.GetBestMapForUnit) == 'function')

-- Self-contained ClassicAPI distance/LoS backports. Neither needs
-- UnitXP_SP3, and UnitInLineOfSight is documented to cooperate with it
-- (routes through UnitXP_SP3's own hook) rather than conflict.
local HAS_UNITDISTSQ = (type(UnitDistanceSquared) == 'function')
local HAS_LOS = (type(UnitInLineOfSight) == 'function')

local HAS_CTIMER = (type(C_Timer) == 'table' and type(C_Timer.NewTicker) == 'function')

-- UnitXP_SP3's own documented existence check. Kept as fallback for
-- distance/LoS when the ClassicAPI equivalents above aren't available.
local HAS_UNITXP3 = (type(UnitXP) == 'function') and pcall(UnitXP, 'nop', 'nop')

local HAS_SUPERWOW = (SUPERWOW_VERSION ~= nil)

-- Not used for anything functional here - see header comment - just
-- surfaced through /mosstatus so you can confirm what's actually loaded.
local HAS_NAMPOWER = (type(nampower) == 'table') or (type(NAMPOWER_VERSION) ~= 'nil')
local HAS_VANILLAHELPERS = (type(ReadFile) == 'function' and type(SetUnitBlip) == 'function')
-- WeirdUtils ships its own clean version-query API, so no guessing needed.
local HAS_WEIRDUTILS = (type(GetWeirdUtilsVersion) == 'function')

---------------------------------------------
-- Useful functions
---------------------------------------------
local function round(num, idp)
	local mult = 10^(idp or 0)
	return floor(num * mult + 0.5) / mult
end

---------------------------------------------
local function createCardinalDirection(direction)
	local fontFrame = CreateFrame('Frame', 'MapOfScars'..direction, compass)
	fontFrame:SetWidth(340)
	fontFrame:SetHeight(30)
	fontFrame:SetPoint('CENTER', compass)
	fontFrame.font = compass:CreateFontString('MapOfScars'..direction..'Font', 'ARTWORK', 'GameFontNormal')
	fontFrame.font:SetFont([[Interface\AddOns\MapOfScars\Futura-Condensed-Normal.TTF]], 19)
	fontFrame.font:SetTextColor(0.8, 0.8, 0.8, OPACITY_LABELS)
	fontFrame.font:SetText(direction)
	fontFrame.font:SetPoint('CENTER', fontFrame, 'CENTER', 0, 0)
	return fontFrame;
end

local function createPOIIcon(ID, texture, width, height)
	local frame = CreateFrame('Frame', 'MapOfScarsPOI'..ID, compass)
	local icon = texture or [[Interface\AddOns\MapOfScars\Icons\Marker]]
	frame.ID = ID
	frame.width = width or 50
	frame.height = height or 50
	frame:SetWidth(frame.width)
	frame:SetHeight(frame.height)
	frame:SetPoint('CENTER', compass)
	frame.texture = frame:CreateTexture('MapOfScarsPOI'..ID..'Texture')
	frame.texture:SetAllPoints(frame)
	frame.texture:SetTexture(icon)
	frame.texture:SetBlendMode('BLEND')
	frame.texture:SetVertexColor(1, 1, 1, 1)
	frame.texture:SetDrawLayer('OVERLAY', 5)
	frame:SetFrameStrata('HIGH')
	frame:Hide()
	return frame
end

local function createCompass()
	compass = CreateFrame('Frame', 'MapOfScars', UIParent)
	compass:SetWidth(512)
	compass:SetHeight(64)
	compass:SetPoint('TOP', 0, -30)
	compass.texture = compass:CreateTexture('MapOfScarsBg')
	compass.texture:SetAllPoints(compass)
	compass.texture:SetTexture([[Interface\AddOns\MapOfScars\Compass-512]])
	compass.texture:SetBlendMode('BLEND')
	compass.texture:SetVertexColor(0.9, 0.9, 1, OPACITY_COMPASS)

	compass.north = createCardinalDirection('N')
	compass.south = createCardinalDirection('S')
	compass.west = createCardinalDirection('W')
	compass.east = createCardinalDirection('E')
end

local function getPlayerPosition()
	local x, y = GetPlayerMapPosition('player')
	return round(x*100,3), round(y*100,3) --, GetZoneText();
end

--used to measure angles for raw x/y POI points (minimap pings, etc)
local function getDistanceTo(x, y)
	return sqrt((x-playerX)^2+(y-playerY)^2)
end

-- Map-percent position of ANY unit, not just "player". Prefers ClassicAPI's
-- C_Map.GetPlayerMapPosition (documented to work for any visible/synced
-- unit token). Without ClassicAPI, best-effort fallback on the stock
-- global, which is only reliably documented for "player" - it may just
-- return nothing for other tokens on plain 1.12.
local function getUnitMapPosition(unit)
	if HAS_CMAP then
		local uiMapID = C_Map.GetBestMapForUnit('player')
		if uiMapID then
			local pos = C_Map.GetPlayerMapPosition(uiMapID, unit)
			if pos then
				local ux, uy = pos:GetXY()
				if ux and uy then
					return round(ux*100, 3), round(uy*100, 3)
				end
			end
		end
		return nil
	end

	local ok, ux, uy = pcall(GetPlayerMapPosition, unit)
	if ok and ux and uy and (ux ~= 0 or uy ~= 0) then
		return round(ux*100, 3), round(uy*100, 3)
	end
	return nil
end

-- Distance (yards) + line-of-sight for a tracked unit. Priority:
-- ClassicAPI's self-contained UnitDistanceSquared/UnitInLineOfSight first,
-- then UnitXP_SP3, then a plain map-percent distance as last resort.
-- fallbackX/fallbackY should be the POI's last known map-percent position.
local function getUnitDistanceAndLOS(unit, fallbackX, fallbackY)
	local dist, hidden

	if HAS_UNITDISTSQ then
		local distSq, checked = UnitDistanceSquared(unit)
		if checked then
			dist = sqrt(distSq)
		end
	end
	if not dist and HAS_UNITXP3 then
		local ok, d = pcall(UnitXP, 'distanceBetween', 'player', unit)
		if ok and d then dist = d end
	end
	if not dist then
		dist = getDistanceTo(fallbackX, fallbackY)
	end

	if HAS_LOS then
		local ok, visible = pcall(UnitInLineOfSight, unit)
		hidden = ok and (visible == false)
	elseif HAS_UNITXP3 then
		local ok, inSight = pcall(UnitXP, 'inSight', 'camera', unit)
		hidden = ok and not inSight
	else
		hidden = false
	end

	return dist, hidden
end

---------------------------------------------
-- Facing: native when available, hack as fallback
---------------------------------------------

-- Legacy fallback: only built and used when ClassicAPI (or anything else
-- that provides a native GetPlayerFacing) is NOT loaded.
local playerModel
local function LegacyGetPlayerFacing()
	local map;
	if not MapOfScarsGetPlayerFacing then
		map = CreateFrame('Minimap', 'MapOfScarsGetPlayerFacing', UIParent)
		map:SetWidth(0)
		map:SetHeight(0)
		map:SetPoint('TOPRIGHT', 0, 0)
		map:Show()
	else
		map = MapOfScarsGetPlayerFacing
	end

	if not playerModel then
		-- create custom minimap and try to hide everything from player
		-- needed due to player arrow not updating while original minimap
		-- is closed or hidden and the worldmap player arrow updates only
		-- when shown
		local model;
		for _,v in ipairs({map:GetChildren()}) do
			if v:GetFrameType() == 'Model' then
				model = v
				if not model:GetName() then
					if strfind(model:GetModel(), 'Minimap\\MinimapArrow') then
						playerModel = model
					end
					model:SetModelScale(0)
				end
			end
		end
	end

	return playerModel:GetFacing()
end

local RawGetPlayerFacing
if HAS_CLASSICAPI then
	RawGetPlayerFacing = NativeGetPlayerFacing
else
	RawGetPlayerFacing = LegacyGetPlayerFacing
end

local function getPlayerFacing()
	local angle = threeHalfPi-RawGetPlayerFacing()
	if angle < 0 then
		return angle + twoPi
	end
	return angle
end

--angle to a certain point
local function getPlayerFacingAngle(x, y)
	local angle = arctan2(x-playerX, y-playerY)
	if angle > halfPi then
		angle = angle-halfPi
	else
		angle = halfPi-angle
	end

	if playerX < x and playerY > y then
		angle = twoPi-angle;
		if angle > threeHalfPi and playerAngle < halfPi then
			angle = angle - twoPi;
		end
	elseif playerX < x and playerY < y then
		if playerAngle > threeHalfPi then
			playerAngle = playerAngle - twoPi
		end
	end

	return angle-playerAngle
end

local function hideOtherCardinals(cardinal)
	compass.north.font:Hide()
	compass.south.font:Hide()
	compass.west.font:Hide()
	compass.east.font:Hide()
	cardinal.font:Show()
end

local function setCardinalDirections()
	if playerAngle < quarterPi then
		compass.east:SetPoint('CENTER', compass, 'CENTER', (-playerAngle) * 210, 0)
		hideOtherCardinals(compass.east)
	elseif playerAngle > sevenQuarterPi then
		compass.east:SetPoint('CENTER', compass, 'CENTER', (twoPi-playerAngle) * 210, 0)
		hideOtherCardinals(compass.east)
	elseif playerAngle < threeQuarterPi and playerAngle > quarterPi then
		compass.south:SetPoint('CENTER', compass, 'CENTER', (halfPi-playerAngle) * 210, 0)
		hideOtherCardinals(compass.south)
	elseif playerAngle < fiveQuarterPi and playerAngle > threeQuarterPi then
		compass.west:SetPoint('CENTER', compass, 'CENTER', (pi-playerAngle) * 210, 0)
		hideOtherCardinals(compass.west)
	else
		compass.north:SetPoint('CENTER', compass, 'CENTER', (threeHalfPi-playerAngle) * 210, 0)
		hideOtherCardinals(compass.north)
	end
end

---------------------------------------------
-- POI handling
---------------------------------------------

local function setPOIIcons(elapsed)
	for index, poi in pairs(POITable) do
		local angle = getPlayerFacingAngle(poi.x, poi.y)
		local skip = false

		if poi.expire and poi.time then
			poi.time = poi.time + elapsed
			if poi.time > poi.expire then
				UIFrameFadeOut(poi.frame, FADE_OUT, 1.0, 0.0)
				POITable[index] = nil
				skip = true
			end
		end

		if poi.frame and not skip then
			-- UnitXP_SP3 line-of-sight: hide unit-tracked POIs the camera
			-- genuinely can't see, instead of just clock-angle culling them.
			if poi.hiddenLOS then
				poi.frame:Hide()
			elseif angle < quarterPi and angle > -quarterPi then
				poi.frame:SetPoint('CENTER', compass, 'CENTER', angle * 210, 0)
				local factor = poi.dist
				if factor > 100 then factor = 100 end
				poi.frame:SetWidth(poi.frame.width-factor/5)
				poi.frame:SetHeight(poi.frame.height-factor/5)
				poi.frame:Show()
			elseif poi.sticky then
				if angle > quarterPi then
					angle = quarterPi
				elseif angle < -quarterPi then
					angle = -quarterPi
				end
				poi.frame:SetPoint('CENTER', compass, 'CENTER', angle * 210, 0)
				local factor = poi.dist
				if factor > 100 then factor = 100 end
				poi.frame:SetWidth(poi.frame.width-factor/5)
				poi.frame:SetHeight(poi.frame.height-factor/5)
				poi.frame:Show()
			else
				poi.frame:Hide()
			end
		end
	end
end

local function updatePOIDistances()
	for i = 1, table.getn(POITable) do
		local poi = POITable[i]
		if poi then
			if poi.unit and UnitExists(poi.unit) then
				-- keep the marker's screen x/y current
				local ux, uy = getUnitMapPosition(poi.unit)
				if ux then
					poi.x, poi.y = ux, uy
				end
				poi.dist, poi.hiddenLOS = getUnitDistanceAndLOS(poi.unit, poi.x, poi.y)
			elseif poi.unit then
				-- tracked unit is gone (dead, out of range, guid stale) - drop it
				POITable[i] = nil
			else
				poi.dist = getDistanceTo(poi.x, poi.y)
			end
		end
	end
end

local function addPOI(index, x, y, texture, width, height, sticky, expire)
	local index = index or 1
	if not POITable[index] then
		POITable[index] = {};
	end
	POITable[index].x = x
	POITable[index].y = y
	POITable[index].unit = nil
	POITable[index].dist = getDistanceTo(x, y)

	if not POITable[index].frame then
		POITable[index].frame = createPOIIcon(index, texture, width, height)
	end
	if sticky then
		POITable[index].sticky = true
	end
	if expire then
		POITable[index].time = 0
		POITable[index].expire = expire
	end
end

-- New: track a live unit instead of a fixed point. Position comes from
-- getUnitMapPosition (ClassicAPI's C_Map when available, so this works for
-- "target", "mouseover", nameplates, party/raid - not just "player");
-- distance/LoS from getUnitDistanceAndLOS. Uses SuperWoW's GUID (if
-- present) so the POI can't be silently hijacked if the unit id gets
-- reused for a different mob.
local function addPOIForUnit(unit, texture, width, height, sticky, expire)
	if not UnitExists(unit) then return false end

	local guid
	if HAS_SUPERWOW then
		local _, g = UnitExists(unit)
		guid = g
	end
	local index = guid or ('unit:'..unit)

	if not POITable[index] then
		POITable[index] = {};
	end
	local ux, uy = getUnitMapPosition(unit)
	POITable[index].x = ux or 0
	POITable[index].y = uy or 0
	POITable[index].unit = unit
	POITable[index].dist = getDistanceTo(POITable[index].x, POITable[index].y)

	if not POITable[index].frame then
		POITable[index].frame = createPOIIcon(index, texture, width, height)
	end
	if sticky then
		POITable[index].sticky = true
	end
	if expire then
		POITable[index].time = 0
		POITable[index].expire = expire
	end
	return true
end

-- Distance/LoS checks (UnitDistanceSquared, UnitInLineOfSight, or the
-- UnitXP_SP3 equivalents) are comparatively expensive - with C_Timer
-- available we refresh them 5x/sec on a ticker instead of every single
-- OnUpdate frame. Facing and cardinal-letter sliding still happen every
-- frame either way, so turning stays perfectly smooth.
if HAS_CTIMER then
	C_Timer.NewTicker(0.2, updatePOIDistances)
end

Addon:SetScript('OnUpdate', function()
	playerAngle = getPlayerFacing()
	playerX, playerY = getPlayerPosition()
	if not HAS_CTIMER then
		updatePOIDistances()
	end
	setCardinalDirections()
	setPOIIcons(arg1)
end)

Addon:SetScript('OnEvent', function()
	if event == 'PLAYER_ENTERING_WORLD' then
		playerX, playerY = getPlayerPosition()
		playerAngle = getPlayerFacing()
	elseif event == 'PLAYER_LOGIN' then
		createCompass()
	elseif event == 'MINIMAP_PING' then
		local x = arg2;
		local y = arg3;
		local pX, pY = getPlayerPosition()
		x = pX + ((x * 100)/2)
		y = pY + (-(y * 100)/2) -- this is either inaccurate or my hand are too shaky for pinging
		addPOI('ping', x, y, [[Interface\AddOns\MapOfScars\Icons\Enemy]], 16, 16, true, 6)
	end
end)

Addon:RegisterEvent('PLAYER_LOGIN')
Addon:RegisterEvent('PLAYER_ENTERING_WORLD')
Addon:RegisterEvent('MINIMAP_PING')

---------------------------------------------
-- Debug / status
---------------------------------------------
SLASH_MAPOFSCARSSTATUS1 = '/mosstatus'
SlashCmdList['MAPOFSCARSSTATUS'] = function()
	local function line(name, has, note)
		local color = has and '|cff40ff40' or '|cffff4040'
		DEFAULT_CHAT_FRAME:AddMessage(color..name..': '..(has and 'detected' or 'not detected')..'|r'..(note and ' - '..note or ''))
	end
	DEFAULT_CHAT_FRAME:AddMessage('|cffffd200MapOfScars|r mod status:')
	line('ClassicAPI', HAS_CLASSICAPI, HAS_CLASSICAPI and 'using native GetPlayerFacing()' or 'using hidden-model facing hack')
	line('  - C_Map', HAS_CMAP, HAS_CMAP and 'unit POIs track any unit token (target/mouseover/etc)' or 'unit POIs limited to whatever GetPlayerMapPosition accepts')
	line('  - UnitDistanceSquared', HAS_UNITDISTSQ, HAS_UNITDISTSQ and 'unit POI distance is real yards' or 'unit POI distance falls back to UnitXP_SP3 or map-percent')
	line('  - UnitInLineOfSight', HAS_LOS, HAS_LOS and 'unit POIs hide when actually occluded' or 'LoS hiding falls back to UnitXP_SP3 or is disabled')
	line('  - C_Timer', HAS_CTIMER, HAS_CTIMER and 'POI distance/LoS refreshed 5x/sec via ticker' or 'POI distance/LoS refreshed every frame')
	line('UnitXP_SP3', HAS_UNITXP3, (HAS_UNITDISTSQ and HAS_LOS) and 'installed, but ClassicAPI covers distance/LoS already' or 'used as distance/LoS fallback')
	line('SuperWoW', HAS_SUPERWOW, HAS_SUPERWOW and 'unit POIs keyed by GUID' or 'unit POIs keyed by unit id')
	line('nampower', HAS_NAMPOWER, 'not used by this addon (spell queueing)')
	line('VanillaHelpers', HAS_VANILLAHELPERS, 'not used by this addon (textures/models)')
	line('WeirdUtils', HAS_WEIRDUTILS, 'not used by this addon (its only position feature is raid-lead gated)')
end

-- expose the unit-tracking helper for other addons/macros:
-- /run MapOfScars_AddPOIForUnit("target")
MapOfScars_AddPOIForUnit = addPOIForUnit
