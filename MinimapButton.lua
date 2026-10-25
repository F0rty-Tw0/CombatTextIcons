-- Combat Text Icons: minimap button. A round button on the minimap ring opens the
-- learned window and switches the addon, the '?' icons and the debug log. Every
-- click goes through the slash handler, so a click and its /cti command share one
-- code path. Shift beats Ctrl beats the mouse button; forget is never on a click
-- (destructive, slash only). A left drag moves the button around the ring.
--
-- CombatTextIconsDB.minimap keeps { angle = degrees on the ring, hide = boolean };
-- /cti minimap shows or hides the button. The button is always created.

local _, ns = ...
local Learn, Fingerprints, Meter = ns.Learn, ns.Fingerprints, ns.Meter

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local DEFAULT_ANGLE = 225 -- degrees, counter-clockwise from the right: bottom left
local SIZE = 31
local RING_GAP = 10 -- the button centre sits this far outside the minimap edge
local HINTS = {
    "Left click: learned window",
    "Right click: '?' icons on/off",
    "Shift-click: addon on/off",
    "Ctrl-click: debug log on/off",
}

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

local button -- built by the first Init

-- CombatTextIconsDB.minimap is kept only as { angle = number, hide = boolean }; each bad field falls back to
-- its default (225, false), other fields are dropped.
local function Saved()
    local saved = CombatTextIconsDB.minimap
    if type(saved) ~= "table" then saved = {} end
    CombatTextIconsDB.minimap = { angle = IsNumber(saved.angle) and saved.angle or DEFAULT_ANGLE, hide = saved.hide == true }

    return CombatTextIconsDB.minimap
end

-- The button's centre on the ring at `angle` degrees.
-- grug: square minimap shapes not handled
local function Place(angle)
    local width = Minimap:GetWidth()
    if not IsNumber(width) then return end
    local radius, radians = width / 2 + RING_GAP, math.rad(angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(radians), radius * math.sin(radians))
end

-- The cursor's angle around the minimap centre in degrees, [0, 360); nil unless every getter gave a plain number.
-- The cursor is in screen pixels; dividing by the minimap's own effective scale puts it in the space of
-- Minimap:GetCenter() even when Edit Mode scales the minimap apart from UIParent.
-- WoW's Lua 5.1 has math.atan2 (its math.atan ignores a second argument); Lua 5.4 dropped it for math.atan(y, x).
local function CursorAngle()
    local x, y = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local centerX, centerY = Minimap:GetCenter()
    if not (IsNumber(x) and IsNumber(y) and IsNumber(scale) and scale > 0 and IsNumber(centerX) and IsNumber(centerY)) then
        return nil
    end
    local atan2 = math.atan2 or math.atan

    return math.deg(atan2(y / scale - centerY, x / scale - centerX)) % 360
end

local function Drag()
    local angle = CursorAngle()
    if angle then Place(angle) end
end

local function StartDrag(self)
    self:SetScript("OnUpdate", Drag)
end

-- Drag stop saves the angle. The frame stub's getters return tables, so this only saves on a real drag.
local function StopDrag(self)
    self:SetScript("OnUpdate", nil)
    local angle = CursorAngle()
    if not angle then return end
    CombatTextIconsDB.minimap.angle = angle
    Place(angle)
end

local function OnOff(on)
    return on and "on" or "off"
end

-- Fingerprints learned as direct hits, single and chain alike.
local function LearnedDirect()
    local count = 0
    for _, entry in ipairs(Fingerprints.List()) do
        if entry.learned then count = count + 1 end
    end

    return count
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText("Combat Text Icons")
    GameTooltip:AddLine("Addon: " .. OnOff(CombatTextIconsDB.enabled), 1, 1, 1)
    GameTooltip:AddLine("'?' icons: " .. OnOff(CombatTextIconsDB.showUnknown ~= false), 1, 1, 1)
    GameTooltip:AddLine("Debug log: " .. OnOff(ns.Debug ~= nil), 1, 1, 1)
    GameTooltip:AddLine(string.format("Learned: %d ticks, %d direct", #Learn.List(), LearnedDirect()), 1, 1, 1)
    GameTooltip:AddLine(" ")
    for _, hint in ipairs(HINTS) do GameTooltip:AddLine(hint, 0.2, 1, 0.2) end
    GameTooltip:Show()
end

-- Shift: addon on/off, Ctrl: debug log, else left: learned window, right: '?' icons on/off.
local function Click(self, mouseButton)
    local message
    if IsShiftKeyDown() then
        message = ""
    elseif IsControlKeyDown() then
        message = "debug"
    elseif mouseButton == "RightButton" then
        message = CombatTextIconsDB.showUnknown ~= false and "unknown off" or "unknown on"
    else
        message = "learned"
    end
    SlashCmdList.COMBATTEXTICONS(message)
    if GameTooltip:IsOwned(self) then ShowTooltip(self) end -- the state lines follow the click
end

local function Build()
    local frame = CreateFrame("Button", "CombatTextIconsMinimapButton", Minimap)
    frame:SetSize(SIZE, SIZE)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(8)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame:RegisterForDrag("LeftButton")
    frame:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -5)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(Meter.UNKNOWN_ICON)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -6)
    local border = frame:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)

    frame:SetScript("OnClick", Click)
    frame:SetScript("OnDragStart", StartDrag)
    frame:SetScript("OnDragStop", StopDrag)
    frame:SetScript("OnEnter", ShowTooltip)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return frame
end

-- Called from Core.PLAYER_LOGIN after the saved data loaded.
function MinimapButton.Init()
    local saved = Saved()
    button = button or Build()
    MinimapButton.button = button
    Place(saved.angle)
    MinimapButton.Apply()
end

-- Shows or hides the button from CombatTextIconsDB.minimap.hide.
function MinimapButton.Apply()
    if CombatTextIconsDB.minimap.hide then
        button:Hide()
    else
        button:Show()
    end
end
