-- GuideMate's location — RATL v1.2.0 (WoW Forever 1.60.1)
-- Runtime-only position information, no disk log, no external requests.
-- Optional MateCompass integration: GuildmateMapDB.mateCompass (default ON).
local ADDON_NAME = ...
local GM = CreateFrame('Frame')
local PREFIX = 'RATL_GMAP'
local VERSION = 1
local EXPIRE = 75
local TX = 'Interface\\AddOns\\GuildmateMap\\Media\\'
local WHITE = 'Interface\\Buttons\\WHITE8X8'
local FONT = 'Fonts\\ARIALN.TTF'
local db, provider, badge, popup
local roster, positions, receiveTimes = {}, {}, {}
local lastBroadcast, lastRosterQuery, lastMapID, dirty = 0, 0, nil, true
local hoverOffset, visibleMembers = 0, {}
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local function normalize(s)
    if not s then return '' end
    return (tostring(s):match('^[^-]+') or tostring(s)):lower()
end
local function me() return normalize(UnitName('player')) end
local function chat(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffc4cbd6GuideMate's location|r  "..msg)
end
local function isValidPosition(x,y)
    return type(x) == 'number' and type(y) == 'number' and x >= 0 and x <= 1 and y >= 0 and y <= 1
end
local function getMapInfo(mapID)
    if not mapID or not C_Map or not C_Map.GetMapInfo then return nil end
    return C_Map.GetMapInfo(mapID)
end
local function isWithinMap(childID, viewedID)
    if not childID or not viewedID then return false end
    if childID == viewedID then return true end
    local seen = {}
    for _=1,15 do
        if seen[childID] then return false end
        seen[childID] = true
        local info = getMapInfo(childID)
        if not info or not info.parentMapID or info.parentMapID == 0 then return false end
        childID = info.parentMapID
        if childID == viewedID then return true end
    end
    return false
end
local function currentMap()
    if C_Map and C_Map.GetBestMapForUnit then return C_Map.GetBestMapForUnit('player') end
end
local function mapName(id)
    local info = getMapInfo(id)
    return info and info.name or UNKNOWN or 'Zone inconnue'
end
local function colorClass(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and c.r or .91, c and c.g or .33, c and c.b or .35
end
local function playerPosition()
    local id = currentMap()
    if not id or not C_Map.GetPlayerMapPosition then return id, nil, nil end
    local pt = C_Map.GetPlayerMapPosition(id, 'player')
    if not pt then return id, nil, nil end
    local x,y = pt:GetXY()
    if isValidPosition(x,y) then return id, x, y end
    return id, nil, nil
end
local function updateRoster()
    if not IsInGuild() or not GetNumGuildMembers or not GetGuildRosterInfo then
        roster = {}
        dirty = true
        return
    end
    local n = GetNumGuildMembers() or 0
    local nextRoster = {}
    for i=1,n do
        local name, rank, _, level, _, zone, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if name and online then
            local key = normalize(name)
            nextRoster[key] = {name=name, rank=rank or '', level=level or 0,
                zone=zone or '', class=classFile or nil}
        end
    end
    -- Include self even when roster synchronization has not arrived yet.
    local own = me()
    if own ~= '' and not nextRoster[own] then
        local id = currentMap()
        local _, class = UnitClass('player')
        nextRoster[own] = {name=UnitName('player'), rank='', level=UnitLevel('player'),
            zone=mapName(id), class=class}
    end
    roster = nextRoster
    for key in pairs(positions) do
        if not roster[key] then positions[key] = nil end
    end
    dirty = true
end
local function guildRosterRefresh()
    if not IsInGuild() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end
local function memberMap(record, key)
    if key == me() then
        local id = currentMap()
        return id, mapName(id)
    end
    local point = positions[key]
    if point and GetTime() - point.seen <= EXPIRE then
        return point.mapID, mapName(point.mapID)
    end
    return nil, record.zone
end
local function matchesMap(record, key, mapID, mapTitle)
    local targetID, targetZone = memberMap(record,key)
    if targetID then return isWithinMap(targetID,mapID) end
    -- A player without the addon can only be matched by roster zone name.
    -- This fallback is restricted to a zone map; never guess continent membership.
    local info = getMapInfo(mapID)
    if info and info.mapType == (Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3) then
        return normalize(targetZone) == normalize(mapTitle)
    end
    return false
end
local function entriesForMap(mapID)
    local result = {}
    if not mapID or not IsInGuild() then return result end
    local title = mapName(mapID)
    for key,record in pairs(roster) do
        if matchesMap(record,key,mapID,title) then
            local loc = positions[key]
            local precise = key == me() or (loc and GetTime()-loc.seen <= EXPIRE)
            result[#result+1] = {
                key=key, name=record.name, class=record.class,
                level=record.level, zone=memberMap(record,key),
                precise=not not precise, own=(key == me()),
            }
        end
    end
    table.sort(result,function(a,b)
        if a.own ~= b.own then return a.own end
        return a.name:lower() < b.name:lower()
    end)
    return result
end
local function projection(id,x,y,shownID)
    if id == shownID then return x,y end
    if not C_Map.GetWorldPosFromMapPos or not C_Map.GetMapPosFromWorldPos then return end
    local success, px, py = pcall(function()
        local continent, w = C_Map.GetWorldPosFromMapPos(id, {x=x,y=y})
        if not continent or not w then return nil,nil end
        local _, pt = C_Map.GetMapPosFromWorldPos(continent, w, shownID)
        if pt then return pt:GetXY() end
    end)
    if success and isValidPosition(px,py) then return px,py end
end

-- Pins are owned by the map's data-provider; they do not touch Blizzard player pins.
RATLGuildmateMapPinMixin = CreateFromMixins(MapCanvasPinMixin or {})
function RATLGuildmateMapPinMixin:OnLoad()
    self:UseFrameLevelType('PIN_FRAME_LEVEL_GROUP_MEMBER')
    self:SetScalingLimits(1, 1, 1.3)
    self.texture:SetTexture(TX..'member-pin.tga')
end
function RATLGuildmateMapPinMixin:OnAcquired(data)
    self.data = data
    self:SetPosition(data.x, data.y)
    local r,g,b = colorClass(data.class)
    self.texture:SetVertexColor(r,g,b,1)
    self:SetSize(23,23)
    self:Show()
end
function RATLGuildmateMapPinMixin:OnReleased() self.data=nil end
function RATLGuildmateMapPinMixin:OnMouseEnter()
    if not self.data then return end
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    GameTooltip:AddLine(self.data.name,1,.86,.70)
    GameTooltip:AddLine('RATL  •  Position partagée',.74,.78,.84)
    GameTooltip:Show()
end
function RATLGuildmateMapPinMixin:OnMouseLeave() GameTooltip:Hide() end
function RATLGuildmateMapPinMixin:OnMouseDown() end
function RATLGuildmateMapPinMixin:OnMouseUp() end
function RATLGuildmateMapPinMixin:OnClick() end

local DataProvider = CreateFromMixins(MapCanvasDataProviderMixin or {})
function DataProvider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate('RATLGuildmateMapPinTemplate')
end
function DataProvider:OnMapChanged()
    self:RefreshAllData()
    dirty=true
end
function DataProvider:RefreshAllData()
    self:RemoveAllData()
    if not db or db.showPins == false or not IsInGuild() then return end
    local worldMap = self:GetMap()
    local viewID = worldMap:GetMapID()
    if not viewID then return end
    for key,person in pairs(roster) do
        -- IMPORTANT: never add a self pin unless explicitly enabled.
        if (key ~= me() or db.showSelfPin == true) then
            local loc = positions[key]
            local id,x,y
            if key == me() then
                id,x,y = playerPosition()
            elseif loc and GetTime()-loc.seen <= EXPIRE then
                id,x,y = loc.mapID,loc.x,loc.y
            end
            if id and isValidPosition(x,y) and isWithinMap(id,viewID) then
                local dx,dy = projection(id,x,y,viewID)
                if isValidPosition(dx,dy) then
                    worldMap:AcquirePin('RATLGuildmateMapPinTemplate',
                        {name=person.name,class=person.class,x=dx,y=dy})
                end
            end
        end
    end
end
local function refreshMap()
    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    if provider then provider:RefreshAllData() end
end

local function rect(parent, point, x,y,w,h,r,g,b,a)
    local t = parent:CreateTexture(nil,'BACKGROUND')
    t:SetTexture(WHITE)
    t:SetVertexColor(r,g,b,a)
    t:SetPoint(point,parent,point,x,y)
    t:SetSize(w,h)
    return t
end
local function panelBackdrop(f)
    if f.SetBackdrop then
        f:SetBackdrop({bgFile=WHITE,edgeFile=WHITE,edgeSize=1,
            insets={left=1,right=1,top=1,bottom=1}})
        f:SetBackdropColor(.055,.070,.090,.985)
        f:SetBackdropBorderColor(.34,.37,.41,1)
    end
    local accent = f:CreateTexture(nil,'BORDER')
    accent:SetTexture(WHITE)
    accent:SetVertexColor(.93,.20,.24,1)
    accent:SetHeight(3)
    accent:SetPoint('TOPLEFT',f,'TOPLEFT',1,-1)
    accent:SetPoint('TOPRIGHT',f,'TOPRIGHT',-1,-1)
end
local function label(parent, text, pt, size, r,g,b)
    local fs = parent:CreateFontString(nil,'OVERLAY')
    fs:SetFont(FONT,size,'')
    fs:SetJustifyH('LEFT')
    fs:SetTextColor(r or 1,g or 1,b or 1)
    fs:SetText(text or '')
    return fs
end
local popupRows = {}
local function updatePopup()
    if not popup or not popup:IsShown() then return end
    local id=WorldMapFrame and WorldMapFrame:GetMapID()
    local members=entriesForMap(id)
    visibleMembers = members
    local n=#members
    hoverOffset=min(hoverOffset,max(0,n-12))
    popup.zone:SetText(mapName(id):upper())
    popup.total:SetText(tostring(n)..'  EN ZONE')
    popup.empty:SetShown(n==0)
    local shown=min(12,n)
    popup:SetHeight(91 + max(1,shown)*29 + (n>12 and 20 or 0))
    popup.body:SetHeight(max(1,shown)*29)
    for i=1,12 do
        local r=popupRows[i]
        local p=members[i+hoverOffset]
        if p then
            r:Show()
            r.name:SetText(p.name..(p.own and '  |cffeb525a(VOUS)|r' or ''))
            local cr,cg,cb=colorClass(p.class)
            r.dot:SetVertexColor(cr,cg,cb)
            if p.own then
                r.info:SetText('LOCAL')
            elseif p.precise then
                r.info:SetText('|cff75d9afGPS|r')
            else
                r.info:SetText('|cff87929eZONE|r')
            end
            r:SetWidth(244)
        else r:Hide() end
    end
    popup.scrollHint:SetShown(n>12)
    if n>12 then popup.scrollHint:SetText(('MOLETTE  •  %d–%d / %d'):format(hoverOffset+1,hoverOffset+shown,n)) end
end
local function createPopup()
    popup=CreateFrame('Frame',nil,WorldMapFrame,'BackdropTemplate')
    popup:SetFrameStrata('DIALOG')
    popup:SetFrameLevel(160)
    popup:SetWidth(282)
    popup:SetHeight(150)
    popup:SetPoint('TOPRIGHT',badge,'BOTTOMRIGHT',0,-8)
    popup:SetClampedToScreen(true)
    popup:EnableMouse(true)
    panelBackdrop(popup)
    local mark=popup:CreateTexture(nil,'ARTWORK')
    mark:SetTexture(TX..'ratl-logo.tga')
    mark:SetSize(47,47)
    mark:SetPoint('TOPLEFT',popup,'TOPLEFT',9,-9)
    local header=label(popup,"GUIDEMATE'S LOCATION",'TOPLEFT',14,1,.90,.87)
    header:SetPoint('TOPLEFT',popup,'TOPLEFT',61,-14)
    local sub=label(popup,'MEMBRES ACTIFS','TOPLEFT',10,.67,.70,.76)
    sub:SetPoint('TOPLEFT',popup,'TOPLEFT',61,-32)
    popup.zone=label(popup,'ZONE','TOPLEFT',12,1,.77,.63)
    popup.zone:SetPoint('TOPLEFT',popup,'TOPLEFT',15,-65)
    popup.zone:SetWidth(176)
    popup.total=label(popup,'0  EN ZONE','TOPRIGHT',11,.94,.28,.32)
    popup.total:SetPoint('TOPRIGHT',popup,'TOPRIGHT',-14,-65)
    popup.total:SetJustifyH('RIGHT')
    popup.body=CreateFrame('Frame',nil,popup)
    popup.body:SetPoint('TOPLEFT',popup,'TOPLEFT',14,-86)
    popup.body:SetSize(252,29)
    popup.empty=label(popup,'Aucun membre dans cette zone','TOPLEFT',12,.63,.68,.73)
    popup.empty:SetPoint('TOPLEFT',popup.body,'TOPLEFT',8,-11)
    for i=1,12 do
        local row=CreateFrame('Frame',nil,popup.body)
        row:SetPoint('TOPLEFT',popup.body,'TOPLEFT',0,-(i-1)*29)
        row:SetHeight(27)
        row:SetWidth(245)
        local bg=row:CreateTexture(nil,'BACKGROUND')
        bg:SetTexture(WHITE)
        bg:SetVertexColor(1,1,1,i%2==0 and .030 or .055)
        bg:SetAllPoints(row)
        row.dot=row:CreateTexture(nil,'OVERLAY')
        row.dot:SetTexture(WHITE)
        row.dot:SetSize(6,6)
        row.dot:SetPoint('LEFT',row,'LEFT',5,0)
        row.name=label(row,'','TOPLEFT',12,.93,.95,.97)
        row.name:SetPoint('LEFT',row,'LEFT',17,0)
        row.name:SetWidth(172)
        row.info=label(row,'','TOPRIGHT',10,.63,.68,.73)
        row.info:SetPoint('RIGHT',row,'RIGHT',-7,0)
        row.info:SetJustifyH('RIGHT')
        row.info:SetWidth(49)
        popupRows[i]=row
    end
    popup.scrollHint=label(popup,'','BOTTOMLEFT',10,.65,.68,.73)
    popup.scrollHint:SetPoint('BOTTOM',popup,'BOTTOM',0,9)
    popup.scrollHint:SetJustifyH('CENTER')
    popup:SetScript('OnMouseWheel',function(_,delta)
        hoverOffset=max(0,min(max(0,#visibleMembers-12), hoverOffset-(delta>0 and 1 or -1)))
        updatePopup()
    end)
    popup:EnableMouseWheel(true)
    popup:SetScript('OnShow',updatePopup)
    popup:Hide()
end
local function badgeUpdate()
    if not badge or not WorldMapFrame or not WorldMapFrame:IsShown() then return end
    local id=WorldMapFrame:GetMapID()
    local count=#entriesForMap(id)
    badge.number:SetText(count>99 and '99+' or tostring(count))
    local r,g,b= count>0 and .98 or .58, count>0 and .86 or .63, count>0 and .88 or .67
    badge.number:SetTextColor(r,g,b)
end
local function createBadge()
    local anchor=WorldMapFrame.GetCanvasContainer and WorldMapFrame:GetCanvasContainer() or WorldMapFrame
    badge=CreateFrame('Button',nil,anchor)
    badge:SetFrameLevel(anchor:GetFrameLevel()+50)
    badge:SetSize(35,35)
    -- The built-in filter is anchored -4px from TOPRIGHT; our badge sits just LEFT of it.
    badge:SetPoint('TOPRIGHT',anchor,'TOPRIGHT',-43,-1)
    badge:RegisterForClicks('LeftButtonUp','RightButtonUp')
    local ring=badge:CreateTexture(nil,'ARTWORK')
    ring:SetTexture(TX..'zone-count.tga')
    ring:SetAllPoints(badge)
    badge.number=label(badge,'0','CENTER',14,1,1,1)
    badge.number:SetPoint('CENTER',badge,'CENTER',0,1)
    badge.number:SetJustifyH('CENTER')
    badge:SetScript('OnEnter',function()
        hoverOffset=0
        popup:Show()
        updatePopup()
    end)
    badge:SetScript('OnClick',function(_,button)
        if button=='RightButton' then
            db.showSelfPin = not db.showSelfPin
            dirty=true
            chat('Pin personnel : '..(db.showSelfPin and '|cff69e4abactivé|r' or '|cffff6868masqué|r'))
            refreshMap()
        end
    end)
    createPopup()
end
local function broadcast(force)
    if not db or db.share == false or not IsInGuild() then return end
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    local now=GetTime()
    if not force and (now-lastBroadcast < 15) then return end
    lastBroadcast=now
    local mapID,x,y=playerPosition()
    local payload
    if mapID and isValidPosition(x,y) then
        payload=('1;%d;%.5f;%.5f'):format(mapID,x,y)
    else
        payload=('1;%d;-1;-1'):format(mapID or 0)
    end
    C_ChatInfo.SendAddonMessage(PREFIX,payload,'GUILD')
end
local function handleAddon(prefix,message,channel,sender)
    if prefix ~= PREFIX or not sender or type(message)~='string' then return end
    if channel ~= 'GUILD' and channel ~= 'PARTY' and channel ~= 'RAID' then return end
    if #message>120 then return end
    local key=normalize(sender)
    if key==me() or not roster[key] then return end
    local now=GetTime()
    if receiveTimes[key] and now-receiveTimes[key]<1 then return end
    receiveTimes[key]=now
    if message == 'OFF' then positions[key]=nil;dirty=true;return end
    local ver,id,xx,yy=message:match('^(%d+);(%d+);([%-0-9%.]+);([%-0-9%.]+)$')
    ver,id,xx,yy=tonumber(ver),tonumber(id),tonumber(xx),tonumber(yy)
    if ver~=VERSION or not id or id<=0 or id>100000 or not xx or not yy then return end
    if (xx == -1 and yy == -1) or isValidPosition(xx,yy) then
        positions[key]={mapID=id,x=xx==-1 and nil or xx,y=yy==-1 and nil or yy,seen=now}
        dirty=true
    end
end
local function tick()
    local now=GetTime()
    if IsInGuild() then
        if now-lastRosterQuery >= 30 then
            lastRosterQuery=now
            guildRosterRefresh()
        end
        broadcast(false)
    end
    for key,p in pairs(positions) do
        if now-p.seen>EXPIRE then positions[key]=nil;dirty=true end
    end
    if WorldMapFrame and WorldMapFrame:IsShown() and badge then
        local id=WorldMapFrame:GetMapID()
        if id~=lastMapID then
            lastMapID=id;dirty=true
        end
        if dirty then
            badgeUpdate()
            if popup and popup:IsShown() then updatePopup() end
            refreshMap()
            dirty=false
        end
        if popup and popup:IsShown() and not (popup:IsMouseOver() or badge:IsMouseOver()) then
            popup:Hide()
        end
    elseif popup then popup:Hide() end
end
local function initializeMap()
    if provider or not WorldMapFrame or not MapCanvasDataProviderMixin then return false end
    -- Some client builds load Blizzard_MapCanvas lazily. Populate any missing
    -- inherited methods when the world map becomes available.
    if MapCanvasPinMixin then
        for name,fn in pairs(MapCanvasPinMixin) do
            if RATLGuildmateMapPinMixin[name] == nil then RATLGuildmateMapPinMixin[name]=fn end
        end
    end
    if MapCanvasDataProviderMixin then
        for name,fn in pairs(MapCanvasDataProviderMixin) do
            if DataProvider[name] == nil then DataProvider[name]=fn end
        end
    end
    provider=CreateFromMixins(DataProvider)
    WorldMapFrame:AddDataProvider(provider)
    createBadge()
    dirty=true
    return true
end
local function callAddOn(method, legacy, name)
    local fn = (C_AddOns and C_AddOns[method]) or legacy
    if not fn then return nil end
    local ok, a, b = pcall(fn, name)
    if not ok then return nil end
    return a, b
end
local function isMateCompassInstalled()
    if C_AddOns and C_AddOns.DoesAddOnExist then
        local ok, exists = pcall(C_AddOns.DoesAddOnExist, 'MateCompass')
        if ok and type(exists) == 'boolean' then return exists end
    end
    local fn = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    if not fn then return true end
    local ok, name, _, _, _, reason = pcall(fn, 'MateCompass')
    if not ok then return true end
    if not name or name == '' or reason == 'MISSING' then return false end
    return true
end
local function applyMateCompass()
    if not db then return end
    local enabled = db.mateCompass ~= false
    if enabled and isMateCompassInstalled() then
        callAddOn('EnableAddOn', EnableAddOn, 'MateCompass')
        callAddOn('LoadAddOn', LoadAddOn, 'MateCompass')
    end
    local frame = _G.MateCompass
    if frame and frame.RefreshVisibility then
        pcall(frame.RefreshVisibility, frame)
    elseif frame then
        pcall(frame.SetShown, frame, enabled)
    end
end
local function setBool(flag,sub,which)
    if sub == 'on' or sub == 'oui' or sub == '1' then db[flag]=true
    elseif sub == 'off' or sub == 'non' or sub == '0' then db[flag]=false
    else chat('Usage : /gmap '..which..' on|off');return end
    if flag=='share' and not db.share and C_ChatInfo and IsInGuild() then
        C_ChatInfo.SendAddonMessage(PREFIX,'OFF','GUILD')
    end
    if flag=='mateCompass' then applyMateCompass() end
    dirty=true;refreshMap();badgeUpdate()
    chat(which..' : '..(db[flag] and '|cff69e4abON|r' or '|cffff6868OFF|r'))
end
SLASH_RATLGMAP1 = '/gmap'
SlashCmdList.RATLGMAP=function(msg)
    local cmd,arg=msg:lower():match('^%s*(%S*)%s*(%S*)')
    if cmd=='self' or cmd=='moi' then setBool('showSelfPin',arg,'self')
    elseif cmd=='share' then setBool('share',arg,'share')
    elseif cmd=='pins' then setBool('showPins',arg,'pins')
    elseif cmd=='compass' or cmd=='boussole' or cmd=='matecompass' then setBool('mateCompass',arg,'compass')
    elseif cmd=='status' then
        chat('Version 1.2.0 | Self pin: '..tostring(db.showSelfPin)..' | Partage: '..tostring(db.share)..' | Pins: '..tostring(db.showPins)..' | Compass: '..tostring(db.mateCompass ~= false))
    else
        chat('Carte : compteur rouge près du filtre. Survol = membres de la zone. Clic droit = pin personnel.')
        chat('/gmap self on|off  •  /gmap share on|off  •  /gmap pins on|off  •  /gmap compass on|off  •  /gmap status')
    end
end
local function init()
    GuildmateMapDB=type(GuildmateMapDB)=='table' and GuildmateMapDB or {}
    db=GuildmateMapDB
    -- Upgrade invariant: an unchecked former "show self" checkbox must never leak a self pin.
    if db.migratedToRATL11~=true then
        db.showSelfPin=false
        db.migratedToRATL11=true
    end
    if db.showPins==nil then db.showPins=true end
    if db.share==nil then db.share=true end
    if db.mateCompass==nil then db.mateCompass=true end
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end
    guildRosterRefresh()
    updateRoster()
    initializeMap()
    applyMateCompass()
    C_Timer.NewTicker(2,tick)
    C_Timer.After(5,function() initializeMap(); guildRosterRefresh(); broadcast(true) end)
    chat('v1.2.0 chargée. Badge RATL près des filtres de carte. Boussole MateCompass optionnelle (ON par défaut). |cff8f9aa6/gmap|r')
end
GM:SetScript('OnEvent',function(_,event,...)
    if event=='ADDON_LOADED' then
        local name=...
        if name==ADDON_NAME then init()
        elseif name=='Blizzard_WorldMap' then initializeMap() end
    elseif event=='CHAT_MSG_ADDON' then
        handleAddon(...)
    elseif event=='GUILD_ROSTER_UPDATE' then
        updateRoster()
    elseif event=='PLAYER_ENTERING_WORLD' or event=='ZONE_CHANGED_NEW_AREA' or event=='ZONE_CHANGED' then
        dirty=true
        broadcast(true)
    elseif event=='PLAYER_GUILD_UPDATE' then
        guildRosterRefresh();updateRoster()
    end
end)
for _,event in ipairs({'ADDON_LOADED','CHAT_MSG_ADDON','GUILD_ROSTER_UPDATE',
        'PLAYER_ENTERING_WORLD','ZONE_CHANGED_NEW_AREA','ZONE_CHANGED','PLAYER_GUILD_UPDATE'}) do
    GM:RegisterEvent(event)
end
