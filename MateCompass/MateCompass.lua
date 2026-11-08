local PI = math.pi
local HALF = 300
local MEDIA = "Interface\\AddOns\\MateCompass\\media\\"
local db
local marks = {}
local headings = {}
local pulseCurves = {}
local cachedMap, mapWidth, mapHeight

local bar = CreateFrame("Frame", "MateCompass", UIParent)
bar:Hide()
bar:SetSize(660, 46)
bar:SetFrameStrata("MEDIUM")
bar:SetClampedToScreen(true)
bar:SetMovable(true)
bar:EnableMouse(true)
bar:RegisterForDrag("LeftButton")

local bg = bar:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetTexture(MEDIA .. "panel.png")

local function line(parent, point, width, height, r, g, b, a)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetPoint(unpack(point))
    t:SetSize(width, height)
    t:SetColorTexture(r, g, b, a)
    return t
end

line(bar, {"CENTER", 0, -2}, 600, 1, 0.62, 0.51, 0.34, 0.65)

for i = -18, 18 do
    line(bar, {"CENTER", i * (HALF / 18), -2}, 1, i % 3 == 0 and 7 or 3,
        0.64, 0.55, 0.4, i % 3 == 0 and 0.7 or 0.4)
end

local pointer = CreateFrame("Frame", nil, bar)
pointer:SetSize(16, 15)
pointer:SetPoint("TOP", bar, "TOP", 0, -1)
for i = 0, 6 do
    line(pointer, {"TOP", 0, -i * 2}, 15 - i * 2, 2, 1, 0.9, 0.65, 1)
end

for i = 0, 2 do
    line(bar, {"RIGHT", -9, 8 - i * 5}, 3, 3, 0.9, 0.7, 0.35, 1)
end

local grip = CreateFrame("Frame", nil, bar)
grip:SetSize(20, 46)
grip:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
grip:EnableMouse(true)
grip:RegisterForDrag("LeftButton")
grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Glisser pour redimensionner")
    GameTooltip:Show()
end)
grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
grip:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    local startX = GetCursorPosition()
    local startScale = bar:GetScale()
    self:SetScript("OnUpdate", function()
        local x = GetCursorPosition()
        local scale = startScale + 2 * (x - startX) / (bar:GetWidth() * UIParent:GetEffectiveScale())
        bar:SetScale(math.max(0.7, math.min(1.5, scale)))
    end)
end)
grip:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    db.scale = bar:GetScale()
end)

local note = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
note:SetPoint("CENTER", 0, 7)
note:SetText("Position indisponible")
note:SetTextColor(0.7, 0.65, 0.56)

for i, label in ipairs({"N", "NE", "E", "SE", "S", "SO", "O", "NO"}) do
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetText(label)
    text:SetTextColor(0.82, 0.66, 0.4)
    headings[i] = text
end

local function makeMark()
    local mark = CreateFrame("Frame", nil, bar)
    mark:SetSize(128, 20)
    mark.alpha = 1
    mark.targetAlpha = 1
    mark.diamond = mark:CreateTexture(nil, "OVERLAY")
    mark.diamond:SetSize(8, 8)
    mark.diamond:SetPoint("TOP", 0, 4)
    mark.diamond:SetColorTexture(1, 1, 1, 1)
    mark.diamond:SetRotation(PI / 4)
    mark.glow = mark:CreateTexture(nil, "ARTWORK")
    mark.glow:SetSize(16, 16)
    mark.glow:SetPoint("CENTER", mark.diamond)
    mark.glow:SetColorTexture(1, 0.08, 0.04, 1)
    mark.glow:SetAlpha(0)
    mark.name = mark:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mark.name:SetPoint("LEFT", mark, "LEFT", 4, 0)
    mark.name:SetWidth(73)
    mark.name:SetJustifyH("LEFT")
    mark.name:SetWordWrap(false)
    mark.distance = mark:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mark.distance:SetPoint("LEFT", mark.name, "RIGHT", 6, 0)
    mark.distance:SetWidth(42)
    mark.distance:SetJustifyH("LEFT")
    mark.border = mark:CreateTexture(nil, "OVERLAY")
    mark.border:SetAllPoints()
    mark.border:SetTexture(MEDIA .. "outline.png")
    mark.border:SetVertexColor(1, 0.12, 0.09, 0.95)
    mark:Hide()
    return mark
end

for i = 1, 4 do marks[i] = makeMark() end

local function fitText(font, maxWidth)
    font:SetWidth(maxWidth)
    local ok, width = pcall(font.GetStringWidth, font)
    if not ok or type(width) ~= "number" or (issecretvalue and issecretvalue(width)) then
        width = maxWidth
    end
    width = math.max(1, math.min(maxWidth, math.ceil(width)))
    font:SetWidth(width)
    return width
end

local visible = {}
local available, lastFacing
local layout

-- A curve keeps secret combat health inside Blizzard's UI pipeline.
if C_CurveUtil and Enum and Enum.LuaCurveType then
    for phase, alpha in ipairs({1, 0.25}) do
        local curve = C_CurveUtil.CreateCurve()
        curve:SetType(Enum.LuaCurveType.Step)
        curve:AddPoint(0, alpha)
        curve:AddPoint(0.299, alpha)
        curve:AddPoint(0.3, 0)
        curve:AddPoint(1, 0)
        pulseCurves[phase] = curve
    end
end

local function relative(angle, facing)
    return (facing - angle + PI) % (2 * PI) - PI
end

local function readFacing()
    if GetPlayerFacing then
        local ok, facing = pcall(GetPlayerFacing)
        if ok and type(facing) == "number" and not (issecretvalue and issecretvalue(facing)) then return facing end
    end
    local compass = _G.MinimapCompassTexture
    if compass then
        local ok, facing = pcall(compass.GetRotation, compass)
        if ok and type(facing) == "number" and not (issecretvalue and issecretvalue(facing)) then return facing end
    end
end

local function readPosition(mapID, unit)
    local pos = C_Map.GetPlayerMapPosition(mapID, unit)
    if not pos then return end
    local x, y = pos:GetXY()
    if issecretvalue and (issecretvalue(x) or issecretvalue(y)) then return end
    if not x or not y or (x == 0 and y == 0) then return end
    return x, y
end

local function readDistance(unit)
    if not UnitDistanceSquared then return "?" end
    local ok, text = pcall(function()
        local square, checked = UnitDistanceSquared(unit)
        if not checked or not square or square < 0 then return "?" end
        return string.format("%d m", math.floor(math.sqrt(square) * 0.9144 + 0.5))
    end)
    return ok and text or "?"
end

local function readMapSize(mapID)
    if mapID == cachedMap then return mapWidth, mapHeight end
    cachedMap, mapWidth, mapHeight = mapID, 1, 1
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return 1, 1 end
    local ok, width, height = pcall(function()
        local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
        if not a or not b then return end
        local ax, ay = a:GetXY()
        local bx, by = b:GetXY()
        return math.abs(bx - ax), math.abs(by - ay)
    end)
    if ok and width and height and width > 0 and height > 0 then
        mapWidth, mapHeight = width, height
    end
    return mapWidth, mapHeight
end

local function paintMark(mark, unit, phase, hasBearing)
    mark:Show()

    local nameOK = pcall(function() mark.name:SetText(UnitName(unit)) end)
    if not nameOK then mark.name:SetText(unit) end
    local colorOK, color = pcall(function()
        local _, class = UnitClass(unit)
        return class and RAID_CLASS_COLORS[class]
    end)
    if not colorOK then color = nil end
    local r, g, b = 0.9, 0.85, 0.72
    if color then r, g, b = color.r, color.g, color.b end
    mark.name:SetTextColor(r, g, b)
    mark.distance:SetTextColor(r, g, b)
    mark.diamond:SetColorTexture(r, g, b, 1)
    mark.distance:SetText(readDistance(unit))
    mark.width = fitText(mark.name, 73) + fitText(mark.distance, 42) + 14
    mark:SetWidth(mark.width)

    local combatOK, combat = pcall(function() return UnitAffectingCombat(unit) == true end)
    mark.border:SetShown(combatOK and combat == true)
    local visibleOK, inWorld = pcall(function() return UnitIsVisible(unit) == true end)
    mark.targetAlpha = (hasBearing and (not visibleOK or inWorld)) and 1 or 0.48

    local deadOK, dead = pcall(function() return UnitIsDeadOrGhost(unit) == true end)
    if deadOK and dead then
        mark.name:SetTextColor(0.55, 0.55, 0.55)
        mark.diamond:SetColorTexture(0.55, 0.55, 0.55, 1)
        mark.glow:SetAlpha(0)
        return
    end

    if pulseCurves[phase] and UnitHealthPercent then
        local healthOK = pcall(function()
            mark.glow:SetAlpha(UnitHealthPercent(unit, false, pulseCurves[phase]))
        end)
        if not healthOK then mark.glow:SetAlpha(0) end
    else
        mark.glow:SetAlpha(0)
    end
end

layout = function(facing)
    local directional = available and facing ~= nil
    note:SetShown(not directional)
    pointer:SetShown(directional)
    for i, text in ipairs(headings) do
        text:SetShown(directional)
        if directional then
            local x = relative(-(i - 1) * PI / 4, facing) / PI * HALF
            text:ClearAllPoints()
            text:SetPoint("CENTER", bar, "CENTER", x, 7)
        end
    end

    for i, item in ipairs(visible) do
        local x = directional and item.bearing and relative(item.bearing, facing) / PI * HALF
            or item.fallbackX or -225 + (i - 1) * 150
        item.x = math.max(-HALF + 5, math.min(HALF - 5, x))
    end
    if directional then
        table.sort(visible, function(a, b) return a.x < b.x end)
    end

    -- Keep labels legible when members share a bearing.
    for i, item in ipairs(visible) do
        local width = item.mark.width
        item.labelX = math.max(-HALF + width / 2, item.x)
        if i > 1 then
            local prev = visible[i - 1]
            item.labelX = math.max(item.labelX,
                prev.labelX + (prev.mark.width + width) / 2 + 2)
        end
    end
    if #visible > 0 and visible[#visible].labelX > HALF - visible[#visible].mark.width / 2 then
        visible[#visible].labelX = HALF - visible[#visible].mark.width / 2
        for i = #visible - 1, 1, -1 do
            visible[i].labelX = math.min(visible[i].labelX,
                visible[i + 1].labelX - (visible[i].mark.width + visible[i + 1].mark.width) / 2 - 2)
        end
    end
    for _, item in ipairs(visible) do
        local mark = item.mark
        mark:ClearAllPoints()
        mark:SetPoint("CENTER", bar, "CENTER", item.labelX, -11)
        mark.diamond:ClearAllPoints()
        mark.diamond:SetPoint("CENTER", bar, "CENTER", item.x, -3)
        mark.diamond:SetShown(directional and item.bearing ~= nil)
    end
end

local function updateData()
    local facing = readFacing()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local px, py
    if facing and mapID and C_Map.GetPlayerMapPosition then
        local ok, x, y = pcall(readPosition, mapID, "player")
        if ok then px, py = x, y end
    end
    available = px ~= nil and py ~= nil
    local width, height = 1, 1
    if available then width, height = readMapSize(mapID) end
    visible = {}
    if IsInGroup() and not IsInRaid() then
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local item = { unit = unit, mark = marks[#visible + 1], fallbackX = -225 + #visible * 150 }
                local ok, x, y
                if available then ok, x, y = pcall(readPosition, mapID, unit) end
                if available and ok and x and y then
                    item.bearing = math.atan2(-(x - px) * width, (py - y) * height)
                end
                visible[#visible + 1] = item
            end
        end
    end
    local phase = math.floor(GetTime() * 2) % 2 + 1
    for i, mark in ipairs(marks) do
        if visible[i] then paintMark(mark, visible[i].unit, phase, visible[i].bearing ~= nil)
        else mark:Hide() end
    end
    lastFacing = facing
    layout(facing)
end

bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
bar:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x, y = self:GetCenter()
    local factor = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
    x, y = x * factor, y * factor
    db.x, db.y = x, y
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
end)

local elapsed = 0
bar:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= 0.05 then
        elapsed = elapsed % 0.05
        updateData()
    else
        local facing = readFacing()
        if facing ~= lastFacing then
            lastFacing = facing
            layout(facing)
        end
    end
    for _, item in ipairs(visible) do
        local mark = item.mark
        mark.alpha = mark.alpha + (mark.targetAlpha - mark.alpha) * math.min(1, dt * 8)
        mark.name:SetAlpha(mark.alpha)
        mark.distance:SetAlpha(mark.alpha)
        mark.diamond:SetAlpha(mark.alpha)
    end
end)

function bar:RefreshVisibility()
    local enabled = not GuildmateMapDB or GuildmateMapDB.mateCompass ~= false
    local show = db ~= nil and enabled and IsInGroup() and not IsInRaid()
    self:SetShown(show)
    if show then updateData() end
end

bar:RegisterEvent("ADDON_LOADED")
bar:RegisterEvent("GROUP_ROSTER_UPDATE")
bar:RegisterEvent("PLAYER_ENTERING_WORLD")
bar:SetScript("OnEvent", function(self, event, addon)
    if event ~= "ADDON_LOADED" or addon == "GuildmateMap" then
        self:RefreshVisibility()
        return
    end
    if addon ~= "MateCompass" then return end
    MateCompassDB = MateCompassDB or {}
    db = MateCompassDB
    if db.layoutVersion ~= 2 then
        db.x, db.y = nil, nil
        db.layoutVersion = 2
    end
    bar:SetScale(type(db.scale) == "number" and math.max(0.7, math.min(1.5, db.scale)) or 1)
    bar:ClearAllPoints()
    if db.x and db.y then bar:SetPoint("CENTER", UIParent, "BOTTOMLEFT", db.x, db.y)
    else bar:SetPoint("TOP", UIParent, "TOP", 0, -28) end
    self:RefreshVisibility()
end)

SLASH_MATECOMPASS1 = "/matecompass"
SLASH_MATECOMPASS2 = "/mc"
SLASH_MATECOMPASS3 = "/boussole"
SlashCmdList.MATECOMPASS = function(command)
    if command == "reset" then
        bar:ClearAllPoints()
        bar:SetPoint("TOP", UIParent, "TOP", 0, -28)
        db.x, db.y = nil, nil
        db.scale = 1
        bar:SetScale(1)
    else
        print("|cffffd27aMateCompass:|r glisser la barre pour déplacer, les points à droite pour redimensionner ; /mc reset pour réinitialiser.")
    end
end
