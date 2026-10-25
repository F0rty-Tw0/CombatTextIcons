-- Combat Text Icons: the addon draws your combat numbers itself, each with the
-- icon of the spell behind it, and turns Blizzard's outgoing numbers off.
--
-- UNIT_COMBAT reports every hit (no source, no spell). Which hits are yours, and
-- with which spell, is worked out from what the addon learned: DoT and channel
-- ticks are matched to your casts by their timing (Tracker.lua) and a direct hit
-- by the cast that fits it (Casts.lua). Those draw at once, in a group too.
-- The addon never resets or reads the damage meter while you fight; after
-- combat the Teacher reads it to learn.
-- A hit nothing names is hidden, except solo on a mob fighting you: there it
-- draws the question mark at once while the area is clear (Teacher.AreaClear:
-- the last fight's meter read showed only your hits), else it stays hidden. An
-- unnamed heal on you decides the same way. A learned proc (Procs.lua) draws its own icon where
-- the question mark would, while the area is clear.
-- Damage you take is always shown, without an icon.

local ADDON, ns = ...
local Meter, Tracker, Display, Learn, Streams, Casts, Fingerprints, Procs, Ledger, Teacher, Progress, Panel, MinimapButton =
    ns.Meter, ns.Tracker, ns.Display, ns.Learn, ns.Streams, ns.Casts, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Teacher,
    ns.Progress, ns.Panel, ns.MinimapButton

local Core = {}
ns.Core = Core

local PREFIX = "|cff66ccffCombat Text Icons:|r "
local TEST_SPELL = 6603 -- Auto Attack, for /cti test
-- Blizzard's floating numbers this addon replaces.
local CVARS = {
    "floatingCombatTextCombatDamage_v2",
    "floatingCombatTextCombatLogPeriodicSpells_v2",
    "floatingCombatTextPetMeleeDamage_v2",
    "floatingCombatTextPetSpellDamage_v2",
    "floatingCombatTextCombatHealing_v2",
}

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local db

-- Blizzard text --------------------------------------------------------------------

-- Blizzard's own scrolling text (Blizzard_CombatText, load-on-demand). Hiding
-- it also hides its buff/proc notices.
local function SetCombatTextShown(shown)
    if CombatText then CombatText:SetShown(shown) end
end

-- Turns the CVars off, remembering each value the first time it is not "0".
-- A CVar already at "0" with nothing remembered (a restore that did not
-- stick, or Blizzard text off before) remembers its default instead, so a
-- later restore brings Blizzard text back. A remembered value is never
-- replaced, so a login after a crash keeps the value from before it.
function Core.SuppressBlizzard()
    db.savedCVars = db.savedCVars or {}
    for _, name in ipairs(CVARS) do
        if db.savedCVars[name] == nil then
            local value = C_CVar.GetCVar(name)
            if Plain(value) and value == "0" then value = C_CVar.GetCVarDefault(name) end
            if Plain(value) and value ~= "0" then db.savedCVars[name] = value end
        end
        pcall(C_CVar.SetCVar, name, "0")
    end
    SetCombatTextShown(false)
end

-- Writes the remembered values back (SetCVar returns nothing on failure).
-- With `forget` (/cti off) each written entry is dropped; at logout they all
-- stay, so a crash before the write is saved still finds them at the next
-- login. A failed write stays remembered and is retried on the next enable,
-- disable or logout.
function Core.RestoreBlizzard(forget)
    local saved = db.savedCVars
    if saved then
        local failed = false
        for name, value in pairs(saved) do
            local ok, success = pcall(C_CVar.SetCVar, name, value)
            if not (ok and success) then
                failed = true
            elseif forget then
                saved[name] = nil
            end
        end
        if forget and not failed then db.savedCVars = nil end
    end
    SetCombatTextShown(true)
end

-- Enemy hits -----------------------------------------------------------------------

local MISSES = { MISS = true, DODGE = true, PARRY = true, BLOCK = true, RESIST = true, IMMUNE = true,
    EVADE = true, DEFLECT = true, REFLECT = true }
local MITIGATED = { ABSORB = true, BLOCK = true, RESIST = true }

-- A hit fully absorbed, blocked or resisted shows Blizzard's word instead of "0".
local function HitText(flagText, amount)
    if Plain(amount) and amount == 0 and Plain(flagText) and MITIGATED[flagText] then
        return _G[flagText] or flagText
    end
    return amount
end

local function InGroup()
    local inGroup = IsInGroup()
    return not Plain(inGroup) or inGroup -- unknown counts as grouped
end

local function IsTarget(unit)
    local ok, isTarget = pcall(UnitIsUnit, unit, "target")
    return ok and Plain(isTarget) and isTarget
end

-- The unit's GUID when plain, else nil.
local function PlainGUID(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if ok and Plain(guid) then return guid end
end

-- Creature IDs whose units keep no threat list (training dummies), learned this session from
-- the target; `probe` is the one targeted unit being tested: { guid, first, hits }.
local noThreatList, probe = {}, nil
local DUMMY_HITS, DUMMY_SPAN = 5, 2 -- a target answering "no threat list" this often, this long

-- A plain GUID's creature ID, or nil for anything that is not a creature.
local function CreatureID(guid)
    return guid and guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
end

-- The target answered "no threat list" after your hit: counts toward learning its creature ID.
local function ProbeDummy(guid, npcID, now)
    if noThreatList[npcID] then return end
    if not probe or probe.guid ~= guid then probe = { guid = guid, first = now, hits = 0 } end
    probe.hits = probe.hits + 1
    if probe.hits >= DUMMY_HITS and now - probe.first >= DUMMY_SPAN then
        noThreatList[npcID], probe = true, nil
    end
end

-- A mob fighting you has you on its threat list; strangers' mobs do not. When that cannot
-- be read only your target counts, plus units of a learned training-dummy ID (dummies keep
-- no threat list: plain nil on the target for 5 hits over 2 s learns its creature ID; any
-- threat answer from that ID un-learns it). Spec 2026-10-25-dummies.
local function FightsYou(unit, now)
    local ok, threat = pcall(UnitThreatSituation, "player", unit)
    local guid = PlainGUID(unit)
    local npcID = CreatureID(guid)
    local dummy = npcID ~= nil and noThreatList[npcID] == true
    if not ok or issecretvalue(threat) then return IsTarget(unit) or dummy end
    if threat ~= nil then
        if npcID then noThreatList[npcID] = nil end
        if probe and probe.guid == guid then probe = nil end
        return true
    end
    if IsTarget(unit) then
        if npcID then ProbeDummy(guid, npcID, now) end
        return true
    end
    return dummy
end

-- grug: temporary probe for missing direct hits (Lightning Bolt): /cti debug logs
-- hits, teacher verdicts and casts to CombatTextIconsDB.debugLog. Remove after the in-game run.
local DEBUG_MAX = 20000 -- an AoE pull fills 3000 lines in under a minute

local function Debug(format, ...)
    local log = db.debugLog
    if #log >= DEBUG_MAX then return end
    log[#log + 1] = string.format("%.3f ", GetTime()) .. string.format(format, ...)
end

local function ShowValue(value)
    return Plain(value) and tostring(value) or "?"
end

-- IsTarget's raw answer for the log: true / false, "secret" or "err".
local function ShowIsTarget(unit)
    local ok, isTarget = pcall(UnitIsUnit, unit, "target")
    if not ok then return "err" end
    if issecretvalue(isTarget) then return "secret" end
    return tostring(isTarget)
end

-- UnitThreatSituation's raw answer for the log: a number, "nil", "secret" or "err" (does
-- FightsYou fall back to the target on retail mobs? gap 2).
local function ShowThreat(unit)
    local ok, threat = pcall(UnitThreatSituation, "player", unit)
    if not ok then return "err" end
    if issecretvalue(threat) then return "secret" end
    return tostring(threat)
end

-- IsInGroup's raw answers for the log, no spaces: any,home,instance as true / false / secret / err.
local function ShowGroup()
    local answers = {}
    for index, category in ipairs({ false, LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE }) do
        local ok, inGroup
        if category then ok, inGroup = pcall(IsInGroup, category) else ok, inGroup = pcall(IsInGroup) end
        answers[index] = not ok and "err" or issecretvalue(inGroup) and "secret" or tostring(inGroup)
    end
    return table.concat(answers, ",")
end

-- The unit's creature ID from UnitGUID for the log (dummy probe): the number, nil, secret, err,
-- or the GUID's type word when it is not a creature.
local function ShowNPC(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok then return "err" end
    if issecretvalue(guid) then return "secret" end
    if guid == nil then return "nil" end
    return guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-") or guid:match("^(%a+)") or "?"
end

local function SpellTexture(spellID)
    return (C_Spell.GetSpellTexture(spellID))
end

-- The Ledger key of a hit no spell could be named for: "?<school>", or "?" when the school is secret
-- (or not a whole number; "%d" would raise on a fraction).
local function UnknownKey(school)
    if Plain(school) and type(school) == "number" and school % 1 == 0 then return string.format("?%d", school) end

    return "?"
end

-- The question mark icon, or nil (number only) when the user turned '?' icons off.
local function UnknownTexture()
    if db.showUnknown == false then return nil end

    return Meter.UNKNOWN_ICON
end

-- The icon for a Tracker answer: the question mark when the tracker cannot tell which spell.
local function TrackerTexture(spellID)
    if spellID == Tracker.UNKNOWN then return UnknownTexture() end
    return SpellTexture(spellID)
end

-- The event frame: its handlers are the Core functions below.
local events = CreateFrame("Frame")

-- Why a solo unexplained hit or heal stays hidden when the area is not clear: no meter to
-- check it against, or the area is crowded.
local function HiddenRoute()
    return Meter.Available() and "HIDDEN (crowded)" or "HIDDEN (meter off)"
end

-- A solo hit on a mob fighting you that a learned proc names, while the area is clear: draws the
-- proc's icon and tallies it. Returns whether it drew; false leaves the hit to the question-mark route.
local function ProcWound(plate, school, amount, flagText)
    local procID = Teacher.AreaClear() and Procs.Name(school, amount, flagText)
    if not procID then return false end
    if ns.Debug then ns.Debug("  -> proc %s", ShowValue(procID)) end
    Teacher.Drawn(procID, amount)
    Ledger.Add("damage", procID, amount)
    Display.Plate(plate, SpellTexture(procID), HitText(flagText, amount), flagText, school)

    return true
end

-- The hit route: the tracker names DoT and channel ticks and a learned cast fingerprint
-- names a direct hit (Casts.Claim); both draw at once, in a group too. Two learned DoTs that
-- both fit draw the question mark at once. Whatever nothing names is fed to the streams; solo
-- on a mob fighting you it also goes to the teacher, and draws the question mark only while the
-- area is clear (Teacher.AreaClear); else it stays hidden (route "meter off" or "crowded"). While the
-- area is clear a learned proc that fits the hit (Procs.Name) draws its icon instead of the question mark.
local function Wound(plate, unit, flagText, amount, school, now)
    Teacher.Seen(amount) -- every enemy-plate wound counts toward the crowd check, drawn or not
    local text = HitText(flagText, amount)
    if ns.Debug then
        ns.Debug("HIT %s school=%s amount=%s flag=%s fps=%.0f threat=%s group=%s npc=%s target=%s", unit, ShowValue(school),
            ShowValue(amount), ShowValue(flagText), GetFramerate(), ShowThreat(unit), ShowGroup(), ShowNPC(unit),
            ShowIsTarget(unit))
    end
    local spellID = Tracker.Identify(plate, school, amount, flagText, now)
    if spellID and spellID ~= Tracker.UNKNOWN then
        if ns.Debug then ns.Debug("  -> tracker %s", ShowValue(spellID)) end
        Teacher.Drawn(spellID, amount)
        Ledger.Add("damage", spellID, amount)
        return Display.Plate(plate, SpellTexture(spellID), text, flagText, school)
    end
    local fightsYou = FightsYou(unit, now)
    local kind, record = Casts.Claim(plate, school, now)
    if kind == "learned" and fightsYou then
        if ns.Debug then ns.Debug("  -> cast %s", ShowValue(record.spellID)) end
        Casts.Accept(record, plate, now)
        Teacher.Drawn(record.base, amount) -- an override is tallied under the base spell's meter row
        Ledger.Add("damage", record.base, amount)
        return Display.Plate(plate, SpellTexture(record.spellID), text, flagText, school)
    end
    -- An UNKNOWN answer is not fed: the tracker already holds the candidates. The teacher
    -- learns from it only solo.
    if spellID == Tracker.UNKNOWN then
        if not fightsYou then
            if ns.Debug then ns.Debug("  -> HIDDEN") end
            return
        end
        if ns.Debug then ns.Debug("  -> tracker unknown") end
        if not InGroup() then Teacher.Unknown(plate, school, amount, now, Casts.SoleCast(plate, now), flagText) end
        Ledger.Add("damage", UnknownKey(school), amount)
        return Display.Plate(plate, UnknownTexture(), text, flagText, school)
    end
    Streams.Feed(plate, school, amount, flagText, "enemy", now)
    if fightsYou and not InGroup() then
        if ProcWound(plate, school, amount, flagText) then return end
        Teacher.Unknown(plate, school, amount, now, Casts.SoleCast(plate, now), flagText)
        if not Teacher.AreaClear() then
            if ns.Debug then ns.Debug("  -> %s", HiddenRoute()) end
            return
        end
        if ns.Debug then ns.Debug("  -> unknown-solo") end
        Ledger.Add("damage", UnknownKey(school), amount)
        return Display.Plate(plate, UnknownTexture(), text, flagText, school)
    end
    if ns.Debug then ns.Debug("  -> HIDDEN") end
end

-- Misses carry no amount; shown only solo, on the target, for a recent harmful cast.
local function Miss(plate, unit, event, now)
    if InGroup() or not IsTarget(unit) then return end
    local castID = Tracker.TakeMissCast(now)
    if castID then
        Display.Plate(plate, SpellTexture(castID), _G[event] or event)
    end
end

-- Friendly and personal plates report hits too; only enemies get popups.
local function CanAttack(unit)
    local ok, canAttack = pcall(UnitCanAttack, "player", unit)
    return ok and Plain(canAttack) and canAttack == true
end

local function EnemyHit(unit, event, flagText, amount, school, now)
    if not CanAttack(unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit, false)
    if not Plain(plate) or plate:IsForbidden() then return end
    if event == "WOUND" then
        Wound(plate, unit, flagText, amount, school, now)
    elseif MISSES[event] then
        Tracker.OnMiss(plate, now)
        Miss(plate, unit, event, now)
    end
end

-- Heals and damage taken (drawn over the player) -------------------------------------

-- Your heal on yourself or a party member: the heal of a channel (Drain Life) whose
-- damage tick landed in this same frame, or a learned HoT's tick. A heal on you that
-- nothing explains draws the question mark when solo and the area is clear; every other
-- unexplained heal stays hidden. Heals do not count toward the crowd check (overheal).
function Core.Heal(unit, flagText, amount, school, now)
    if ns.Debug then
        ns.Debug("HEAL %s school=%s amount=%s flag=%s", unit, ShowValue(school), ShowValue(amount), ShowValue(flagText))
    end
    local route, key = "HIDDEN", nil -- key: the Ledger key of the drawn heal
    local texture -- nil on the '?' route when '?' icons are off: the route decides whether it draws
    if unit == "player" then
        local spellID = Tracker.ChannelHeal(now)
        if spellID then texture, route, key = SpellTexture(spellID), "channel", spellID end
    end
    if texture == nil then
        local spellID = Tracker.IdentifyHeal(unit, school, amount, flagText, now)
        if spellID then
            texture = TrackerTexture(spellID)
            route = spellID == Tracker.UNKNOWN and "unknown" or "tracker " .. ShowValue(spellID)
            key = spellID == Tracker.UNKNOWN and UnknownKey(school) or spellID
        end
    end
    if texture ~= nil or route == "unknown" then
        Ledger.Add("heal", key, amount)
        Display.Player("heal", texture, amount, flagText)
    else
        Streams.Feed(unit, school, amount, flagText, "heal", now)
        route = "HIDDEN"
        local solo = unit == "player" and not InGroup()
        if solo and Teacher.AreaClear() then
            route = "unknown-solo"
            Ledger.Add("heal", UnknownKey(school), amount)
            Display.Player("heal", UnknownTexture(), amount, flagText)
        elseif solo then
            route = HiddenRoute()
        end
    end
    if ns.Debug then ns.Debug("  -> %s", route) end
end

-- Damage you take is always shown, as a number: no icon.
local function Taken(flagText, amount)
    Display.Player("taken", nil, HitText(flagText, amount), flagText)
end

-- Events ---------------------------------------------------------------------------

function Core.ADDON_LOADED(name)
    if name == ADDON then
        db = CombatTextIconsDB or {}
        if db.enabled == nil then db.enabled = true end
        db.meter = nil -- the meter mode is gone
        if type(db.showUnknown) ~= "boolean" then db.showUnknown = nil end
        if type(db.showProgress) ~= "boolean" then db.showProgress = nil end
        CombatTextIconsDB = db
    elseif name == "Blizzard_CombatText" and db and db.enabled then
        SetCombatTextShown(false)
    end
end

function Core.PLAYER_LOGIN()
    Meter.Init()
    Learn.Init()
    -- Learn.Init made the character table; saved data is checked, never trusted.
    local charDB = CombatTextIconsCharDB
    charDB.chainSchools = nil -- the chain route's saved schools are gone
    Fingerprints.Init(charDB)
    Procs.Init(charDB)
    Ledger.Init(charDB)
    if db.enabled then Core.SuppressBlizzard() end
    MinimapButton.Init() -- last: a UI error here must not skip the combat setup above
end

function Core.PLAYER_LOGOUT()
    Core.RestoreBlizzard(false)
end

-- The fight ends: casts, ledger and the teacher's read close out.
function Core.PLAYER_REGEN_ENABLED()
    if not db.enabled then return end
    Casts.Flush(GetTime())
    Ledger.Finish(GetTime())
    Teacher.Finish(GetTime())
end

-- The combat-start hook: the ledger opens a fight and the teacher starts tallying what
-- is drawn (same `now`, so the verdicts find the fight); Progress snapshots the learn state.
function Core.PLAYER_REGEN_DISABLED()
    if not db.enabled then return end
    local now = GetTime()
    Ledger.Start(now, InGroup())
    Teacher.Start(now, InGroup())
    Progress.Start()
end

function Core.UNIT_COMBAT(unit, event, flagText, amount, school)
    if not db.enabled then return end
    local now = GetTime()
    if not (Plain(unit) and Plain(event)) then return end
    if unit:find("^nameplate%d+$") then
        EnemyHit(unit, event, flagText, amount, school, now)
    elseif event == "HEAL" and (unit == "player" or unit:find("^party[1-4]$")) then
        Core.Heal(unit, flagText, amount, school, now)
    elseif event == "WOUND" and unit == "player" then
        Taken(flagText, amount)
    end
end

function Core.UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)
    if not db.enabled then return end
    if ns.Debug then ns.Debug("CAST %s %s", unit, ShowValue(spellID)) end
    local now = GetTime()
    if unit == "player" and Plain(spellID) then
        local harmful = C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(spellID)
        if Plain(harmful) and harmful then Casts.NoteCast(spellID, now) end
    end
    Tracker.OnCast(unit, spellID, now)
end

function Core.UNIT_SPELLCAST_CHANNEL_START(unit, castGUID, spellID)
    if not db.enabled then return end
    Tracker.OnChannelStart(spellID, GetTime(), castGUID)
end

function Core.UNIT_SPELLCAST_CHANNEL_STOP(unit, castGUID)
    Tracker.OnChannelStop(GetTime(), castGUID)
end

function Core.GROUP_ROSTER_UPDATE()
    Tracker.OnRosterChanged()
end

-- Plate frames are recycled: nothing stays tied to this one. The Tracker parks the mob's DoT
-- state under its GUID until its plate shows again.
function Core.NAME_PLATE_UNIT_REMOVED(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit, false)
    if Plain(plate) then
        Tracker.OnPlateRemoved(plate, PlainGUID(unit), GetTime())
        Display.ReleasePlate(plate)
    end
end

function Core.NAME_PLATE_UNIT_ADDED(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit, false)
    local guid = PlainGUID(unit)
    if Plain(plate) and guid then Tracker.OnPlateAdded(plate, guid, GetTime()) end
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("UNIT_COMBAT")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
events:SetScript("OnEvent", function(_, event, ...) Core[event](...) end)

-- Slash commands --------------------------------------------------------------------

-- /cti toggles the addon, /cti on and /cti off set it; /cti test shows a
-- sample popup on your target's nameplate; /cti learned opens the learned window
-- (works while the addon is off), /cti learned chat lists the spells the addon
-- learned by itself in chat and /cti forget clears them.
-- /cti minimap shows or hides the minimap button (works while the addon is off).
-- /cti unknown on|off shows or hides the '?' icon of a hit no spell could be named for
-- (the number stays; works while the addon is off).
-- /cti progress on|off shows or hides the fight-end learning popups (works while the addon is off).
SLASH_COMBATTEXTICONS1 = "/cti"

local function SpellName(spellID)
    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if Plain(name) and type(name) == "string" then return name end

    return "spell " .. spellID
end

local function PrintLearned()
    local list = Learn.List()
    if #list == 0 then
        print(PREFIX .. "nothing learned yet")
        return
    end
    for _, row in ipairs(list) do
        print(PREFIX .. SpellName(row.spellID) .. " (" .. row.spellID .. "): school " .. row.school .. ", "
            .. string.format("%.2f", row.period) .. " s, " .. row.kind)
    end
end

SlashCmdList.COMBATTEXTICONS = function(message)
    if not db then return end
    message = strtrim(message or ""):lower()
    if message == "test" then
        local plate = C_NamePlate.GetNamePlateForUnit("target", false)
        if not Plain(plate) then
            print(PREFIX .. "target an enemy with a visible nameplate first.")
            return
        end
        Display.Plate(plate, C_Spell.GetSpellTexture(TEST_SPELL), 12345, "CRITICAL", 1)
        return
    end
    if message == "forget" then
        Learn.Forget()
        Casts.Forget()
        Procs.Forget()
        Ledger.Forget()
        print(PREFIX .. "forgot all learned spells")
        return
    end
    if message == "learned" then
        Panel.Toggle()
        return
    end
    if message == "learned chat" then
        PrintLearned()
        return
    end
    if message == "minimap" then
        db.minimap.hide = not db.minimap.hide
        MinimapButton.Apply()
        print(PREFIX .. "minimap button " .. (db.minimap.hide and "hidden; /cti minimap shows it" or "shown"))
        return
    end
    if message:sub(1, 7) == "unknown" then
        local word = strtrim(message:sub(8))
        if word ~= "on" and word ~= "off" then
            print(PREFIX .. "usage: /cti unknown on|off")
            return
        end
        db.showUnknown = word == "on"
        print(PREFIX .. "'?' icons " .. word)
        return
    end
    if message:sub(1, 8) == "progress" then
        local word = strtrim(message:sub(9))
        if word ~= "on" and word ~= "off" then
            print(PREFIX .. "usage: /cti progress on|off")
            return
        end
        Progress.SetShown(word == "on")
        print(PREFIX .. "progress popups " .. word)
        return
    end
    if message == "debug" then
        if ns.Debug then
            ns.Debug = nil
            print(PREFIX .. "debug log off, " .. #db.debugLog .. " lines kept; /reload to save them")
        else
            db.debugLog = {}
            ns.Debug = Debug
            print(PREFIX .. "debug log on (cleared)")
        end
        return
    end
    local enable = not db.enabled
    if message == "on" then
        enable = true
    elseif message == "off" then
        enable = false
    elseif message ~= "" then
        print(PREFIX .. "usage: /cti [on|off|learned [chat]|minimap|unknown|progress|forget|debug|test]")
        return
    end
    if enable == db.enabled then
        print(PREFIX .. "already " .. (enable and "on" or "off"))
        return
    end
    db.enabled = enable
    if db.enabled then
        Core.SuppressBlizzard()
    else
        Core.RestoreBlizzard(true)
        Tracker.Reset()
        Ledger.Finish(GetTime())
        Teacher.fight = nil -- a cut-short fight is not read
    end
    print(PREFIX .. (db.enabled and "on" or "off"))
end
