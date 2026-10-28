-- Popups: a spell icon with the number (or miss word) to its right.
-- Enemy hits rise from above the enemy's nameplate; heals and damage taken
-- stack in a column under the player, newest on top, older ones pushed down. Amounts may be secret values:
-- those go straight into SetText/SetFormattedText, never into Lua math. Fight-end notices
-- (Progress.lua) are a batch of up to MAX_NOTICES still rows at the top of the screen, row 1 on
-- top, icons in one column and text left-justified beside them, the block centred on its widest
-- row; they live NOTICE_LIFE seconds; each popup carries its own life.
--
-- Motion is driven from one OnUpdate (SetPoint/SetAlpha/SetScale) rather than
-- AnimationGroups: a Translation animation on these WorldFrame popups drew the
-- number away from its icon in game.

local ADDON, ns = ...

local Display = {}
ns.Display = Display

local ICON_SIZE = 22
local ICON_GAP = 3 -- pixels between the icon and its text
local FONT_SIZE = 18
local CRIT_SCALE = 1.6   -- crit font size multiplier
local POP_START = 1 / CRIT_SCALE -- crit popups are born at normal-hit size
local POP_PEAK = 1.7     -- then punch up to this
local POP_UP = 0.07      -- seconds to reach the peak
local POP_TIME = 0.15    -- seconds until the crit has settled back to 1
local FADE_IN = 0.05     -- seconds to fade in
local FADE_OUT = 0.35    -- seconds of fade-out at the end of life
local LIFE = 1.2         -- seconds a plate or player popup lives
local NOTICE_LIFE = 4    -- seconds a fight-end notice lives
local RISE = 35          -- pixels a normal plate popup rises
local CRIT_RISE = 10     -- crits barely rise
local JITTER = 30        -- random x offset of plate popups, +/- pixels
local PLATE_Y = 26       -- plate popups start this far above the plate, clear of its debuff row
-- Without a personal nameplate the player's spot on screen cannot be read;
-- this is below the screen centre, under where the default camera keeps the
-- character's feet.
local PLAYER_Y = -160
local ROW = 26           -- player column spacing; older rows move down
local MAX_VISIBLE = 40
local MAX_PER_PLATE = 3  -- a plate's oldest popup is recycled beyond this
local MAX_COLUMN = 6     -- player column rows; older rows are released
local MAX_NOTICES = 4    -- fight-end notice rows
-- Notice row 1's centre, below the screen's top: clear of UIErrorsFrame ("Not enough rage", TOP -122, 60 tall) at
-- any UI scale. Raid warnings may share the spot, but notices only follow solo fights.
local NOTICE_Y = -200
-- Above the nameplates, below most of the UI. The strata of Blizzard's
-- nameplate frames could not be confirmed offline; LOW would do if they are
-- BACKGROUND (in game: /run print(NamePlate1:GetFrameStrata())).
local STRATA = "MEDIUM"

Display.MAX_NOTICES = MAX_NOTICES -- Progress shows at most this many notices

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

local SCHOOL_COLORS = {
    [1] = { 1, 1, 0.6 },        -- physical: white-yellow
    [2] = { 1, 0.9, 0.2 },      -- holy: yellow
    [4] = { 1, 0.5, 0 },        -- fire: orange
    [8] = { 0.3, 1, 0.3 },      -- nature: green
    [16] = { 0.5, 0.85, 1 },    -- frost: light blue
    [32] = { 0.7, 0.4, 1 },     -- shadow: purple
    [64] = { 1, 0.5, 1 },       -- arcane: pink
}
-- Multi-school masks whose lowest bit is not the colour they are known by.
local SCHOOL_OVERRIDES = {
    [36] = SCHOOL_COLORS[32],   -- shadowflame: shadow purple, not fire orange
}
local WHITE = { 1, 1, 1 }
local HEAL_COLOR = { 0.2, 1, 0.2 }
local TAKEN_COLOR = { 1, 0.2, 0.2 }

-- Multi-school masks take the colour of their lowest set bit (Lua 5.1: no bit operators).
local function SchoolColor(school)
    if not Plain(school) or type(school) ~= "number" then return WHITE end
    if SCHOOL_OVERRIDES[school] then return SCHOOL_OVERRIDES[school] end
    local bitValue = 1
    while bitValue <= 64 do
        if school % (bitValue * 2) >= bitValue then return SCHOOL_COLORS[bitValue] end
        bitValue = bitValue * 2
    end
    return WHITE
end

local function FormatAmount(amount)
    if type(amount) ~= "number" then return amount end
    return AbbreviateNumbers and AbbreviateNumbers(amount) or tostring(amount)
end

local pool = {}
local active = {}  -- visible popups, oldest first
local column = {}  -- player popups, newest first
local notices = {} -- the current batch of fight-end notices
local driver = CreateFrame("Frame")
driver:Hide()

local function Remove(list, popup)
    for index = #list, 1, -1 do
        if list[index] == popup then table.remove(list, index) end
    end
end

local function Release(popup)
    popup:Hide()
    popup:ClearAllPoints()
    popup.plate = nil
    popup.anchor = nil
    Remove(active, popup)
    Remove(column, popup)
    Remove(notices, popup)
    pool[#pool + 1] = popup
end

local function NewPopup()
    local popup = CreateFrame("Frame", nil, WorldFrame)
    popup:SetSize(ICON_SIZE, ICON_SIZE)
    popup:SetFrameStrata(STRATA)
    popup.text = popup:CreateFontString(nil, "OVERLAY")
    -- the icon hangs off the text's left, so icon and text centre on the popup together without measuring the text
    -- (a secret amount's width cannot be read); Acquire centres the text alone when there is no icon, and
    -- re-anchors it on every use because a notice pins it to the popup's left
    popup.icon = popup:CreateTexture(nil, "ARTWORK")
    popup.icon:SetSize(ICON_SIZE, ICON_SIZE)
    popup.icon:SetPoint("RIGHT", popup.text, "LEFT", -ICON_GAP, 0)
    popup.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trims the icon's baked-in border
    return popup
end

-- Moves, fades and scales a popup `age` seconds into its life (`popup.life`). Crits punch up
-- from normal-hit size to a peak, then settle. Offsets are divided by the
-- scale because SetPoint offsets are in the popup's own scale.
local function Place(popup, age)
    local scale = 1
    if popup.crit and age < POP_UP then
        scale = POP_START + (POP_PEAK - POP_START) * age / POP_UP
    elseif popup.crit and age < POP_TIME then
        scale = POP_PEAK - (POP_PEAK - 1) * (age - POP_UP) / (POP_TIME - POP_UP)
    end
    popup:SetScale(scale)
    local alpha = 1
    if age < FADE_IN then
        alpha = age / FADE_IN
    elseif age > popup.life - FADE_OUT then
        alpha = (popup.life - age) / FADE_OUT
    end
    popup:SetAlpha(alpha)
    local y = popup.y + popup.rise * age / popup.life
    popup:SetPoint(popup.point, popup.anchor, popup.relativePoint, popup.x / scale, y / scale)
end

-- Exposed for the OnUpdate and the offline tests.
function Display.Update(now)
    for index = #active, 1, -1 do
        local popup = active[index]
        local age = now - popup.born
        if age >= popup.life then Release(popup) else Place(popup, age) end
    end
    if not active[1] then driver:Hide() end
end

driver:SetScript("OnUpdate", function() Display.Update(GetTime()) end)

-- Fills a popup and starts its life at `point` of `anchor`; `rise` pixels over its life
-- (`life` seconds, LIFE by default).
local function Acquire(texture, text, flagText, color, prefix, anchor, point, relativePoint, x, y, rise, life)
    if #active >= MAX_VISIBLE then Release(active[1]) end
    local popup = table.remove(pool) or NewPopup()
    local crit = Plain(flagText) and flagText == "CRITICAL"
    popup.icon:SetTexture(texture)
    local iconShown = issecretvalue(texture) or texture ~= nil
    popup.icon:SetShown(iconShown)
    popup.text:ClearAllPoints()
    popup.text:SetPoint("CENTER", popup, "CENTER", iconShown and (ICON_SIZE + ICON_GAP) / 2 or 0, 0)
    popup.text:SetFont(STANDARD_TEXT_FONT, crit and FONT_SIZE * CRIT_SCALE or FONT_SIZE, "OUTLINE")
    popup.text:SetTextColor(color[1], color[2], color[3])
    local shown = Plain(text) and FormatAmount(text) or text
    if prefix then
        popup.text:SetFormattedText(prefix .. "%s", shown)
    else
        popup.text:SetText(shown)
    end
    popup.crit, popup.born = crit, GetTime()
    popup.anchor, popup.point, popup.relativePoint = anchor, point, relativePoint
    popup.x, popup.y, popup.rise, popup.life = x, y, rise, life or LIFE
    Place(popup, 0)
    popup:Show()
    active[#active + 1] = popup
    driver:Show()
    return popup
end

-- An enemy hit (or miss) over `plate`. `text` is the amount (plain or secret) or a miss word.
function Display.Plate(plate, texture, text, flagText, school)
    local count, oldest = 0, nil
    for index = 1, #active do
        if active[index].plate == plate then
            count = count + 1
            oldest = oldest or active[index]
        end
    end
    if count >= MAX_PER_PLATE then Release(oldest) end
    local popup = Acquire(texture, text, flagText, SchoolColor(school), nil,
        plate, "BOTTOM", "TOP", math.random(-JITTER, JITTER), PLATE_Y, RISE)
    popup.plate = plate
    popup.rise = popup.crit and CRIT_RISE or RISE
end

-- The personal resource nameplate when Blizzard shows one, else nil.
local function PersonalPlate()
    local plate = C_NamePlate.GetNamePlateForUnit("player", false)
    if Plain(plate) and not plate:IsForbidden() then return plate end
end

-- A heal ("heal") or damage taken ("taken") over the player.
function Display.Player(kind, texture, text, flagText)
    local heal = kind == "heal"
    while #column >= MAX_COLUMN do Release(column[#column]) end
    local popup = Acquire(texture, text, flagText, heal and HEAL_COLOR or TAKEN_COLOR, heal and "+" or nil,
        UIParent, "CENTER", "CENTER", 0, 0, 0)
    table.insert(column, 1, popup)
    local plate = PersonalPlate()
    local now = GetTime()
    for index, entry in ipairs(column) do
        if plate then
            entry.anchor, entry.point, entry.relativePoint = plate, "TOP", "BOTTOM"
            entry.y = -(index - 1) * ROW
        else
            entry.anchor, entry.point, entry.relativePoint = UIParent, "CENTER", "CENTER"
            entry.y = PLAYER_Y - (index - 1) * ROW
        end
        entry:ClearAllPoints()
        Place(entry, now - entry.born)
    end
end

-- Fight-end notice row `i` (1 = highest priority, at the top): `text` is a plain string. i = 1
-- starts a new batch and releases the previous notices. The popup's square holds the icon and the
-- text starts right of it, so every row's icon shares one x; the batch is re-centred on its widest
-- text each time a row joins. The text is plain, but a pooled font string that held a secret amount
-- may still answer with a secret width; a width that cannot be read counts as 0.
function Display.Notice(texture, text, i)
    if i == 1 then
        while notices[1] do Release(notices[1]) end
    end
    local popup = Acquire(texture, text, nil, WHITE, nil, UIParent, "LEFT", "TOP", 0,
        NOTICE_Y - (i - 1) * ROW, 0, NOTICE_LIFE)
    popup.text:ClearAllPoints()
    popup.text:SetPoint("LEFT", popup, "LEFT", ICON_SIZE + ICON_GAP, 0)
    notices[#notices + 1] = popup
    local widest = 0
    for _, entry in ipairs(notices) do
        local width = entry.text:GetStringWidth()
        if IsNumber(width) then widest = math.max(widest, width) end
    end
    local now = GetTime()
    for _, entry in ipairs(notices) do
        entry.x = -(ICON_SIZE + ICON_GAP + widest) / 2
        entry:ClearAllPoints()
        Place(entry, now - entry.born)
    end
end

-- The plate's unit is gone; its popups go with it.
function Display.ReleasePlate(plate)
    for index = #active, 1, -1 do
        local popup = active[index]
        if popup.plate == plate then Release(popup) end
    end
end
