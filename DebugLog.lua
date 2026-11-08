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
