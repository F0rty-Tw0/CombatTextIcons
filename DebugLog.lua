-- Combat Text Icons: the /cti debug log (CombatTextIconsDB.debugLog) and how its lines show the values the client
-- answers with, secret or not. /cti debug sets ns.Debug to DebugLog.Debug.

local _, ns = ...

local DebugLog = {}
ns.DebugLog = DebugLog

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local db

-- The saved variables the log lives in (Core.ADDON_LOADED).
function DebugLog.Init(saved)
    db = saved
end

-- grug: temporary probe for missing direct hits (Lightning Bolt): /cti debug logs
-- hits, teacher verdicts and casts to CombatTextIconsDB.debugLog. Remove after the in-game run.
local DEBUG_MAX = 100000 -- an AoE pull fills 3000 lines in under a minute; 20000 cut a 12-minute run short

function DebugLog.Debug(format, ...)
    local log = db.debugLog
    if #log >= DEBUG_MAX then return end
    log[#log + 1] = string.format("%.3f ", GetTime()) .. string.format(format, ...)
end

function DebugLog.ShowValue(value)
    return Plain(value) and tostring(value) or "?"
end

-- grug: Forever probe (2026-11-05), the two below: remove once the Forever fix is chosen.
-- What an unreadable value really is: "secret", or its type ("nil" when the event gave none).
function DebugLog.ShowRaw(value)
    return issecretvalue(value) and "secret" or type(value)
end

-- Which other sources of combat numbers this client has, as name=true / false pairs.
function DebugLog.ShowApis()
    local answers = {}
    for _, name in ipairs({ "issecretvalue", "CombatLogGetCurrentEventInfo", "C_CombatLog", "C_DamageMeter" }) do
        answers[#answers + 1] = name .. "=" .. tostring(_G[name] ~= nil)
    end
    local ok, valid = pcall(function() return C_EventUtils.IsEventValid("COMBAT_LOG_EVENT_UNFILTERED") end)
    answers[#answers + 1] = "cleu=" .. (ok and tostring(valid) or "err")

    return table.concat(answers, " ")
end

-- grug: Forever probe (2026-11-11), the block below: remove once the Combat Log's lines are judged.
-- COMBAT_LOG_MESSAGE hands addons each line the Combat Log prints, its words secret. On the default "My actions"
-- filter only your own actions print one, so a line in a hit's frame may mark the hit yours (the idea behind
-- Shuklock's Scrolling Battle Text). The game makes these lines only while they are switched on, which the Combat
-- Log tab does when it shows; C_CombatLog.SetFilteredEventsEnabled keeps them on. /cti debug logs each line
-- (CLOG) and swing (SWING) beside the HIT lines, to judge in game whether they pair. v2 (2026-11-12, after the
-- dungeon run) adds heals on party members (PHEAL: a heal of yours on them prints a line too) and the meter's fields
-- after each fight (PROBE meterfields).
local lineFrame -- made on the first /cti debug
local switchedOn -- this probe switched the lines on

local function Valid(event)
    local ok, valid = pcall(function() return C_EventUtils.IsEventValid(event) end)
    return ok and Plain(valid) and valid == true
end

-- The lines' state, switching them on when off: on / switched / err / none (no C_CombatLog call).
local function KeepLinesOn()
    local log = C_CombatLog
    if not (log and log.SetFilteredEventsEnabled and log.AreFilteredEventsEnabled) then return "none" end
    local ok, on = pcall(log.AreFilteredEventsEnabled)
    if ok and Plain(on) and on == true then return "on" end
    if not pcall(log.SetFilteredEventsEnabled, true) then return "err" end
    switchedOn = true
    return "switched"
end

-- The Combat Log's picked filter as index:name (spaces as _), or none before Blizzard_CombatLog loads.
local function ShowFilter()
    local all = _G.Blizzard_CombatLog_Filters
    if type(all) ~= "table" or type(all.filters) ~= "table" then return "none" end
    local current = all.filters[all.currentFilter]
    local name = type(current) == "table" and type(current.name) == "string" and current.name or "?"
    return tostring(all.currentFilter) .. ":" .. (name:gsub("%s", "_"))
end

local function ShowText(text)
    if issecretvalue(text) then return "secret" end
    if type(text) ~= "string" then return type(text) end
    return (text:sub(1, 60):gsub("|", "/"))
end

local function ShowShade(value)
    if Plain(value) and type(value) == "number" then return string.format("%.2f", value) end
    return DebugLog.ShowValue(value)
end

-- A meter value for the log: secret, a scalar as text, or (to `depth` levels) a table as {key=value,...} sorted.
local function ShowField(value, depth)
    if issecretvalue(value) then return "secret" end
    if type(value) ~= "table" then return tostring(value) end
    if depth <= 0 then return "table" end
    local parts = {}
    for key, field in pairs(value) do parts[#parts + 1] = tostring(key) .. "=" .. ShowField(field, depth - 1) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

-- 2026-11-12: does the meter hold a per-spell hit count (a ground truth for grouped ownership)? Logs every field of
-- the newest session's player source after a fight, its spell rows two levels deep.
local function LogMeterFields()
    if not ns.Debug then return end
    local ok, text = pcall(function()
        local newest
        for _, session in ipairs(C_DamageMeter.GetAvailableCombatSessions()) do
            if not newest or session.sessionID > newest then newest = session.sessionID end
        end
        if not newest then return "no-sessions" end
        local source = C_DamageMeter.GetCombatSessionSourceFromID(newest, ns.Meter.DAMAGE_DONE, UnitGUID("player"))
        return "session:" .. newest .. " " .. ShowField(source, 4) -- source > combatSpells > row > row's tables
    end)
    ns.Debug("PROBE meterfields %s", ok and text or "err " .. tostring(text))
end

local function OnLineEvent(_, event, ...)
    if not ns.Debug then return end
    if event == "COMBAT_LOG_MESSAGE" then
        local text, r, g, b, order = ...
        ns.Debug("CLOG text=%s rgb=%s,%s,%s order=%s", ShowText(text), ShowShade(r), ShowShade(g), ShowShade(b),
            DebugLog.ShowValue(order))
    elseif event == "PLAYER_SWING" then
        local first, kind = ...
        ns.Debug("SWING %s kind=%s", DebugLog.ShowValue(first), DebugLog.ShowValue(kind))
    elseif event == "UNIT_COMBAT" then -- 2026-11-12: a heal on a party member, whose line a heal of yours prints
        local unit, action, flag, _, school = ...
        local isParty = Plain(unit) and type(unit) == "string" and unit:match("^party%d$")
        if isParty and Plain(action) and action == "HEAL" then
            ns.Debug("PHEAL %s school=%s flag=%s", unit, DebugLog.ShowValue(school), DebugLog.ShowValue(flag))
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        C_Timer.After(1, LogMeterFields) -- the meter's rows settle after the fight
    else -- PLAYER_REGEN_DISABLED: the Combat Log tab hiding switches the lines off again
        local state = KeepLinesOn()
        if state ~= "on" then ns.Debug("PROBE clog lines=%s filter=%s", state, ShowFilter()) end
    end
end

-- Starts the line probe; returns what the client allowed, for the log's PROBE clog line.
function DebugLog.StartLines()
    lineFrame = lineFrame or CreateFrame("Frame")
    lineFrame:SetScript("OnEvent", OnLineEvent)
    local answers = {}
    for _, event in ipairs({ "COMBAT_LOG_MESSAGE", "PLAYER_SWING", "PLAYER_REGEN_DISABLED", "UNIT_COMBAT",
        "PLAYER_REGEN_ENABLED" }) do
        local registered = Valid(event) and pcall(lineFrame.RegisterEvent, lineFrame, event)
        answers[#answers + 1] = event .. "=" .. tostring(registered and true or false)
    end
    answers[#answers + 1] = "lines=" .. KeepLinesOn()
    answers[#answers + 1] = "filter=" .. ShowFilter()
    return table.concat(answers, " ")
end

-- Stops it, switching the lines back off when this probe switched them on and the Combat Log tab is hidden.
function DebugLog.StopLines()
    if lineFrame then lineFrame:UnregisterAllEvents() end
    local log = _G.COMBATLOG
    local ok, showing = pcall(function() return log:IsShown() end)
    if switchedOn and not (ok and Plain(showing) and showing) then pcall(C_CombatLog.SetFilteredEventsEnabled, false) end
    switchedOn = nil
end

-- IsTarget's raw answer for the log: true / false, "secret" or "err".
function DebugLog.ShowIsTarget(unit)
    local ok, isTarget = pcall(UnitIsUnit, unit, "target")
    if not ok then return "err" end
    if issecretvalue(isTarget) then return "secret" end
    return tostring(isTarget)
end

-- UnitThreatSituation's raw answer for the log: a number, "nil", "secret" or "err" (does
-- FightsYou fall back to the target on retail mobs? gap 2).
function DebugLog.ShowThreat(unit)
    local ok, threat = pcall(UnitThreatSituation, "player", unit)
    if not ok then return "err" end
    if issecretvalue(threat) then return "secret" end
    return tostring(threat)
end

-- IsInGroup's raw answers for the log, no spaces: any,home,instance as true / false / secret / err.
function DebugLog.ShowGroup()
    local answers = {}
    for index, category in ipairs({ false, LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE }) do
        local ok, inGroup
        if category then ok, inGroup = pcall(IsInGroup, category) else ok, inGroup = pcall(IsInGroup) end
        answers[index] = not ok and "err" or issecretvalue(inGroup) and "secret" or tostring(inGroup)
    end
    return table.concat(answers, ",")
end

-- The base-spell answers for the log (override probe), no spaces:
-- C_SpellBook.FindBaseSpellByID,C_Spell.GetBaseSpell as a number / nil / secret / err / none.
function DebugLog.ShowBase(spellID)
    local answers = {}
    local finds = { C_SpellBook and C_SpellBook.FindBaseSpellByID or false, C_Spell.GetBaseSpell or false }
    for index, find in ipairs(finds) do
        local ok, base = false, nil
        if find then ok, base = pcall(find, spellID) end
        answers[index] = not find and "none" or not ok and "err" or issecretvalue(base) and "secret" or tostring(base)
    end
    return table.concat(answers, ",")
end

-- The unit's creature ID from UnitGUID for the log (dummy probe): the number, nil, secret, err,
-- or the GUID's type word when it is not a creature.
function DebugLog.ShowNPC(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok then return "err" end
    if issecretvalue(guid) then return "secret" end
    if guid == nil then return "nil" end
    return guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-") or guid:match("^(%a+)") or "?"
end
