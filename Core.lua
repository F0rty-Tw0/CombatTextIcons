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
-- the question mark would, while no read found the area crowded (Teacher.NotCrowded: a map no read decided yet
-- counts). A learned direct heal (Heals.lua) names a heal on you in its
-- cast's frame, in a group too; so does a learned coupled heal in the frame of the hit it is a share of, and a
-- learned train (a HoT or totem a cast starts) on each tick due after that cast.
-- Damage you take is always shown, without an icon.

local ADDON, ns = ...
local Meter, Tracker, Display, Learn, Streams, Casts, Fingerprints, Procs, Ledger, Teacher, Progress, Panel, MinimapButton =
    ns.Meter, ns.Tracker, ns.Display, ns.Learn, ns.Streams, ns.Casts, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Teacher,
    ns.Progress, ns.Panel, ns.MinimapButton
local Heals = ns.Heals

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
local DEBUG_MAX = 100000 -- an AoE pull fills 3000 lines in under a minute; 20000 cut a 12-minute run short

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

-- The base-spell answers for the log (override probe), no spaces:
-- C_SpellBook.FindBaseSpellByID,C_Spell.GetBaseSpell as a number / nil / secret / err / none.
local function ShowBase(spellID)
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

-- The event frame: its handlers are the Core functions below.
local events = CreateFrame("Frame")

-- frameHits = { at = a frame's stamp, list = the hits drawn with an icon on it, each { spellID, amount } }: a heal on
-- you in that frame may be a learned share of one (Heals.Claim)
local frameHits = { list = {} }

-- A hit was drawn with this spell's icon: the teacher tallies it, and the frame keeps it for its heals.
local function Drawn(spellID, amount)
    local now = GetTime()
    Teacher.Drawn(spellID, amount, now)
    if frameHits.at ~= now then frameHits = { at = now, list = {} } end
    frameHits.list[#frameHits.list + 1] = { spellID = spellID, amount = amount }
end

-- Why a solo unexplained hit or heal stays hidden when the area is not clear: no meter to
-- check it against, no read decided this map yet (Teacher.NotCrowded still holds), or the area is crowded.
local function HiddenRoute()
    if not Meter.Available() then return "HIDDEN (meter off)" end

    return Teacher.NotCrowded() and "HIDDEN (new area)" or "HIDDEN (crowded)"
end

-- A solo hit on a mob fighting you that a learned proc names, while the area is not crowded (Teacher.NotCrowded):
-- draws the proc's icon and tallies it. Returns whether it drew; false leaves the hit to the question-mark route.
-- An unlearned cast of another spell whose samples place a hit like it here (Casts.SampledAt) keeps it from the proc.
local function ProcWound(plate, school, amount, flagText, now)
    local procID = Teacher.NotCrowded() and Procs.Name(school, amount, flagText)
    if not procID or Casts.SampledAt(plate, now, school, Streams.NormalAmount(amount, flagText), procID) then
        return false
    end
    if ns.Debug then ns.Debug("  -> proc %s", ShowValue(procID)) end
    Drawn(procID, amount)
    Ledger.Add("damage", procID, amount)
    Display.Plate(plate, SpellTexture(procID), HitText(flagText, amount), flagText, school)

    return true
end

-- Draws a hit with a learned rhythm proc's icon and tallies it; returns true.
local function DrawRhythm(plate, rhythmID, school, amount, flagText)
    if ns.Debug then ns.Debug("  -> rhythm %s", ShowValue(rhythmID)) end
    Drawn(rhythmID, amount)
    Ledger.Add("damage", rhythmID, amount)
    Display.Plate(plate, SpellTexture(rhythmID), HitText(flagText, amount), flagText, school)

    return true
end

-- Draws a hit whose stream fits a learned rhythm proc (ticks that share no size band) with that row's icon; a
-- hit before its stream is born is named by a logged cast of the proc's row that its band holds (Procs.NameCast).
-- `candidates` is Casts.Candidates for the hit. Returns whether it drew.
local function RhythmWound(plate, stream, school, amount, flagText, candidates)
    local rhythmID = Teacher.NotCrowded()
        and (Procs.NameStream(stream) or Procs.NameCast(school, amount, flagText, candidates))
    if not rhythmID then return false end

    return DrawRhythm(plate, rhythmID, school, amount, flagText)
end

-- Draws a loose hit (no stream took it) that pairs with the tick one learned rhythm period before it on the plate
-- (Procs.NamePair), when no unlearned cast may have made it: a learned cast's own hit was claimed before (Casts.Claim).
-- Nor may a learned DoT's cast in the hit's window (Casts.TickerAt): an off-beat tick the tracker missed is the DoT's,
-- and run mage F6 paired Arcane Missiles 5143's as the mislearned proc 153626. `candidates` is Casts.Candidates for the
-- hit. Returns whether it drew.
local function PairWound(plate, stream, school, amount, flagText, candidates, now)
    if stream or not Teacher.NotCrowded() then return false end
    for _, cast in ipairs(candidates) do
        if not Fingerprints.IsLearned(cast.castID) then return false end
    end
    if Casts.TickerAt(plate, now, school) then return false end
    local rhythmID = Procs.NamePair(Streams.Loose(plate, school), school, amount, flagText, now)
    if not rhythmID then return false end

    return DrawRhythm(plate, rhythmID, school, amount, flagText)
end

-- The hit route: the tracker names DoT and channel ticks and a learned cast fingerprint
-- names a direct hit (Casts.Claim); both draw at once, in a group too. Two learned DoTs that
-- both fit draw the question mark at once. Whatever nothing names is fed to the streams; solo
-- on a mob fighting you a hit no proc names may tick a learned stack spell's series (Casts.StackTick)
-- and draw it, else it also goes to the teacher, and draws the question mark only while the
-- area is clear (Teacher.AreaClear); else it stays hidden (route "meter off" or "crowded"). In a group
-- such a hit on a mob fighting you may still tick a stack series; in a crowded fight no hit does. While the
-- area is not crowded (Teacher.NotCrowded) a learned proc that fits the hit (Procs.Name) draws its icon instead of
-- the question mark; so does a learned rhythm proc that fits the stream the hit extends or births
-- (Procs.NameStream), or that a recent cast of its row and the hit's size name before the stream is born
-- (Procs.NameCast), ranked below the Tracker and Casts; last, below the stack series, one whose tick a period
-- before the hit is still loose on the plate (Procs.NamePair).
-- The crowd check sees every wound that may be yours: one the tracker names, or one on a mob fighting
-- you, drawn or not. Strangers' wounds on other mobs never reach the teacher, so they count for nothing
-- (run 153349Z: strangers on 8 nearby dummies made both reads crowded).
local function Wound(plate, unit, flagText, amount, school, now)
    local fightsYou = FightsYou(unit, now)
    local grouped = InGroup()
    if grouped then Teacher.Grouped() end
    local solo = fightsYou and not grouped
    local text = HitText(flagText, amount)
    if ns.Debug then
        ns.Debug("HIT %s school=%s amount=%s flag=%s fps=%.0f threat=%s group=%s npc=%s target=%s", unit, ShowValue(school),
            ShowValue(amount), ShowValue(flagText), GetFramerate(), ShowThreat(unit), ShowGroup(), ShowNPC(unit),
            ShowIsTarget(unit))
    end
    -- A crowded fight draws only like-sized ticks (Tracker.Identify) and CrowdFits casts (Casts.Claim).
    local crowded = Teacher.fight and Teacher.fight.crowded
    local spellID = Tracker.Identify(plate, school, amount, flagText, now, crowded)
    if fightsYou or (spellID and spellID ~= Tracker.UNKNOWN) then Teacher.Seen(amount, now, school) end
    -- A learned proc (exact meter sums) outranks a learned DoT's answer (votes) or an ambiguous one.
    local voted = spellID == Tracker.UNKNOWN or (spellID and Learn.Get(spellID))
    if voted and solo and ProcWound(plate, school, amount, flagText, now) then return end
    local named = spellID and spellID ~= Tracker.UNKNOWN
    local kind, record, late, claimed
    crowded = Teacher.fight and Teacher.fight.crowded -- Teacher.Seen may have turned it crowded
    if named and Learn.Get(spellID) then
        -- A learned DoT's answer is votes; a learned cast fingerprint that fits the hit in its window is exact
        -- (Lightning Bolt hits drawn as a mislearned Lava Burst DoT): the cast wins. The one Claim serves both.
        kind, record, late = Casts.Claim(plate, school, now, Streams.NormalAmount(amount, flagText), crowded,
            flagText)
        claimed = true
        if kind == "learned" and not late and fightsYou and record.spellID ~= spellID then named = false end
    end
    if named then
        if ns.Debug then ns.Debug("  -> tracker %s", ShowValue(spellID)) end
        Drawn(spellID, amount)
        if Learn.Get(spellID) then Teacher.Ticked(school, amount, flagText) end
        Ledger.Add("damage", spellID, amount)
        return Display.Plate(plate, SpellTexture(spellID), text, flagText, school)
    end
    if not claimed then
        kind, record = Casts.Claim(plate, school, now, Streams.NormalAmount(amount, flagText), crowded,
            flagText)
    end
    if kind == "learned" and fightsYou then
        if ns.Debug then ns.Debug("  -> cast %s", ShowValue(record.spellID)) end
        Casts.Accept(record, plate, now)
        Drawn(record.base, amount) -- an override is tallied under the base spell's meter row
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
        if not InGroup() then
            Teacher.Unknown(plate, school, amount, now, Casts.SoleCast(plate, now, school), flagText,
                Casts.Candidates(plate, now, school))
        end
        Ledger.Add("damage", UnknownKey(school), amount)
        return Display.Plate(plate, UnknownTexture(), text, flagText, school)
    end
    -- A hit a learned proc names is no DoT tick: fed to the streams, its rhythm gave its votes to a cast
    -- in the proc's frame (Surging Totem's ~12K hits learned Lava Burst as a DoT, run 20261025T182530Z).
    local stream
    if not Procs.Name(school, amount, flagText) then
        stream = Streams.Feed(plate, school, amount, flagText, now, solo)
        -- A learned DoT spread to a plate it was never cast on takes the stream there (Tracker.AdoptSpread).
        if stream and solo and not crowded then Tracker.AdoptSpread(plate, stream, now) end
    end
    local candidates
    if solo then
        if ProcWound(plate, school, amount, flagText, now) then return end
        candidates = Casts.Candidates(plate, now, school) -- one list for both: drawing changes no cast log
        if RhythmWound(plate, stream, school, amount, flagText, candidates) then return end
    end
    -- A learned stack spell's tick (Casts.StackTick) takes a hit nothing named on a mob fighting you, after the
    -- streams saw it and, solo, the procs had it: lock2 fight 4, Agony 980's ticks agree with Unstable Affliction's
    -- one stack and draw as a rhythm proc. In a group it is the only route left (lock3 fight 4: 420524 of the row). Not
    -- in a crowded fight: strangers' hits on the plate pass for steps (lock3 fight 3).
    local stack = fightsYou and not crowded
        and Casts.StackTick(plate, school, now, Streams.NormalAmount(amount, flagText), flagText)
    if stack then
        if ns.Debug then ns.Debug("  -> stack %s", ShowValue(stack.spellID)) end
        Drawn(stack.base, amount)
        Ledger.Add("damage", stack.base, amount)
        return Display.Plate(plate, SpellTexture(stack.spellID), text, flagText, school)
    end
    -- A loose tick pairs with the one a learned rhythm period before it only after the stack spells had it: lock3
    -- F2, Unstable Affliction's 7821 (2 stacks x 3258 x 1.2) at 199540.864 sits in Darkglare's band.
    if solo and PairWound(plate, stream, school, amount, flagText, candidates, now) then return end
    if solo then
        Teacher.Unknown(plate, school, amount, now, Casts.SoleCast(plate, now, school), flagText, candidates)
        if not Teacher.AreaClear() then
            if ns.Debug then ns.Debug("  -> %s", HiddenRoute()) end
            return
        end
        -- no clear read ever saw this school: a stranger's (shamanally2: an ally's physical hits on a resto shaman)
        if not Teacher.OwnSchool(school) then
            if ns.Debug then ns.Debug("  -> HIDDEN (school)") end
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

-- Once a heal is learned (Heals.AnyLearned), a heal on you that no channel named waits for the end of
-- its frame (Core.FlushHeals): it lands before its own cast's UNIT_SPELLCAST_SUCCEEDED in that frame (shamanheal:
-- the heal of each of 17 Chain Heal 1064 casts is logged on the cast's stamp, the line before the CAST line), so only
-- then does the frame know its casts; its drawn hits (frameHits) come with them.
-- waiting = { at = the frame's stamp, heals = { { flagText, amount, school, size }, ... } }; frameCasts = { at, ids =
-- your helpful casts on that stamp, in cast order, each once (seen) }.
local waiting, frameCasts = { heals = {} }, { ids = {} }
local flushQueued = false -- a flush waits on C_Timer.After(0)

-- A heal on you no channel named is drawn: with the icon of the spell that claimed it (Heals.Claim: its frame's
-- helpful cast, a learned size or share, or the tick of a running train), else as any unexplained heal on you: the question mark solo while the area is clear, else hidden.
local function DrawOwnHeal(heal, castID)
    local route = "HIDDEN"
    if castID then
        route = "heal " .. castID
        Ledger.Add("heal", castID, heal.amount)
        Display.Player("heal", SpellTexture(castID), heal.amount, heal.flagText)
    elseif not InGroup() and Teacher.AreaClear() then
        route = "unknown-solo"
        Ledger.Add("heal", UnknownKey(heal.school), heal.amount)
        Display.Player("heal", UnknownTexture(), heal.amount, heal.flagText)
    elseif not InGroup() then
        route = HiddenRoute()
    end
    if ns.Debug then ns.Debug("  -> %s", route) end
end

-- Draws the waiting heals once their frame is over: `now` past its stamp, or nil (the fight ended; the replays end
-- each frame with it too). Each waits for at most one frame: an event of a later one flushes them first.
function Core.FlushHeals(now)
    local heals = waiting.heals
    if #heals == 0 or (now and now <= waiting.at) then return end
    local casts = frameCasts.at == waiting.at and frameCasts.ids or {}
    local hits, at = frameHits.at == waiting.at and frameHits.list or {}, waiting.at
    waiting = { heals = {} }
    local claims = Heals.Claim(casts, heals, hits, at)
    for index, heal in ipairs(heals) do DrawOwnHeal(heal, claims[index]) end
end

-- The game's next frame flushes the waiting heals; a callback still on their own stamp waits again.
local function QueueFlush()
    if flushQueued then return end
    flushQueued = pcall(C_Timer.After, 0, function()
        flushQueued = false
        Core.FlushHeals(GetTime())
        if #waiting.heals > 0 then QueueFlush() end
    end)
end

-- A heal on you or a party member. On you: the heal of a channel (Drain Life) whose damage tick landed in this same
-- frame; else once any heal is learned it waits for its frame's casts, hits and running trains, which may name it
-- (waiting); a heal on you nothing names draws the question mark when solo and the area is clear. A heal on a party
-- member stays hidden. A HoT's ticks are a learned train's (Heals.lua): the tick tracker's own HoT instances took
-- like-timed heals of any size and outlived the HoT (synthetic: foreign heals and a 720 rune drawn under Renew 139,
-- 4.6 % of the case's heals; the real heal logs: no heal named that way). Heals do not count toward the crowd check
-- (overheal).
function Core.Heal(unit, flagText, amount, school, now)
    Core.FlushHeals(now)
    if ns.Debug then
        ns.Debug("HEAL %s school=%s amount=%s flag=%s", unit, ShowValue(school), ShowValue(amount), ShowValue(flagText))
    end
    if unit == "player" then Teacher.Healed(amount, flagText, now) end
    local spellID = unit == "player" and Tracker.ChannelHeal(now) or nil
    local texture = spellID and SpellTexture(spellID) or nil
    if texture ~= nil then
        Ledger.Add("heal", spellID, amount)
        Display.Player("heal", texture, amount, flagText)
        if ns.Debug then ns.Debug("  -> channel") end
    elseif unit == "player" then
        local heal = { flagText = flagText, amount = amount, school = school,
            size = Streams.NormalAmount(amount, flagText) }
        if not Heals.AnyLearned() then return DrawOwnHeal(heal) end
        waiting.at = now
        waiting.heals[#waiting.heals + 1] = heal
        QueueFlush()
    elseif ns.Debug then
        ns.Debug("  -> HIDDEN")
    end
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
        if type(db.panelDetails) ~= "boolean" then db.panelDetails = nil end -- the learned window's Details toggle
        CombatTextIconsDB = db
    elseif name == "Blizzard_CombatText" and db and db.enabled then
        SetCombatTextShown(false)
    end
end

-- The player's spec ID, or nil while the client does not know it (early at login).
local function SpecID()
    local api = C_SpecializationInfo or {}
    local getIndex = api.GetSpecialization or GetSpecialization
    local getInfo = api.GetSpecializationInfo or GetSpecializationInfo
    if not (getIndex and getInfo) then return nil end
    local ok, index = pcall(getIndex)
    if not (ok and Plain(index) and type(index) == "number" and index > 0) then return nil end
    local okInfo, specID = pcall(getInfo, index)
    if okInfo and Plain(specID) and type(specID) == "number" and specID > 0 then return specID end
end

local spec = nil -- the spec whose store the modules use; 0 while the spec is unknown

-- Every learning module takes the store of the player's spec, CombatTextIconsCharDB.specs[spec ID]: a resto
-- shaman never draws with what elemental learned. Saved data is checked, never trusted. Until the client knows the
-- spec the store is specs[0]; the first known spec takes it over when it has no store yet, else it is dropped (it
-- holds at most what a fight before then taught). A swap drops the Teacher's judging under way (Teacher.Init).
local function UseSpec()
    local id = SpecID() or spec or 0
    if id == spec then return end
    local specs = CombatTextIconsCharDB.specs
    if spec == 0 then
        if specs[id] == nil then specs[id] = specs[0] end
        specs[0] = nil
    end
    if type(specs[id]) ~= "table" then specs[id] = {} end
    if ns.Debug then ns.Debug("SPEC %s -> %d", ShowValue(spec), id) end
    spec = id
    local store = specs[id]
    Learn.Init(store)
    Fingerprints.Init(store)
    Heals.Init(store)
    Casts.InitOwnRows(store)
    Procs.Init(store)
    Ledger.Init(store)
    Teacher.Init(store)
    Tracker.Reset()
    Streams.Reset()
end

function Core.PLAYER_LOGIN()
    local fresh = type(CombatTextIconsCharDB) ~= "table" -- this character's first login with the addon
    -- a store from before the per-spec one holds only learning: it is dropped whole, once
    if fresh or type(CombatTextIconsCharDB.specs) ~= "table" then CombatTextIconsCharDB = { specs = {} } end
    Meter.Init()
    spec = nil
    UseSpec()
    if db.enabled then Core.SuppressBlizzard() end
    if fresh and db.enabled then
        print(PREFIX .. "'?' icons are hits it hasn't learned yet. Fight a few mobs solo and they turn into your spell icons."
            .. " /cti for options.")
    end
    MinimapButton.Init() -- last: a UI error here must not skip the combat setup above
end

-- Login, reload and every loading screen: the crowd verdict comes back on the map it was made on. A spec the
-- client did not know at login is known by now.
function Core.PLAYER_ENTERING_WORLD()
    UseSpec()
    Teacher.EnterWorld()
end

-- Fires for talent changes too; UseSpec swaps only when the spec ID changed. Before login nothing is loaded yet.
function Core.PLAYER_SPECIALIZATION_CHANGED()
    if spec then UseSpec() end
end

function Core.PLAYER_LOGOUT()
    Core.RestoreBlizzard(false)
end

-- The fight ends: casts, ledger and the teacher's read close out.
function Core.PLAYER_REGEN_ENABLED()
    if not db.enabled then return end
    Core.FlushHeals()
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
    Core.FlushHeals(now)
    if unit:find("^nameplate%d+$") then
        EnemyHit(unit, event, flagText, amount, school, now)
    elseif event == "HEAL" and (unit == "player" or unit:find("^party[1-4]$")) then
        Core.Heal(unit, flagText, amount, school, now)
    elseif event == "WOUND" and unit == "player" then
        Taken(flagText, amount)
    end
end

-- The pet's harmful casts join the cast log too: the meter lists pet damage among the player's own rows
-- (Shadow Bite 54049, Bite 17253), so the teacher learns them like the player's. The player's other casts may be
-- heals: the frame's waiting heals get them (Core.FlushHeals), and the teacher too (Heals.lua).
function Core.UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)
    if not db.enabled then return end
    Core.FlushHeals(GetTime())
    if ns.Debug then
        ns.Debug("CAST %s %s base=%s", unit, ShowValue(spellID), Plain(spellID) and ShowBase(spellID) or "?")
    end
    local now = GetTime()
    if (unit == "player" or unit == "pet") and Plain(spellID) then
        local harmful = C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(spellID)
        if Plain(harmful) and harmful then
            local plate = Casts.NoteCast(spellID, now, castGUID, unit == "pet")
            Teacher.Cast(spellID, Casts.Base(spellID), now, plate)
        elseif Plain(harmful) and unit == "player" then
            if frameCasts.at ~= now then frameCasts = { at = now, ids = {}, seen = {} } end
            if not frameCasts.seen[spellID] then
                frameCasts.seen[spellID] = true
                frameCasts.ids[#frameCasts.ids + 1] = spellID
            end
            Teacher.Helped(spellID, now)
            Heals.Cast(spellID, now)
        end
    end
    Tracker.OnCast(unit, spellID, now)
end

-- A spell with a cast time began: its plate is the target now, not the one when it lands.
function Core.UNIT_SPELLCAST_START(unit, castGUID, spellID)
    if not db.enabled or unit ~= "player" then return end
    if ns.Debug then ns.Debug("START %s %s", unit, ShowValue(spellID)) end
    Casts.NoteStart(castGUID, spellID, GetTime())
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
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("UNIT_COMBAT")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
events:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
events:SetScript("OnEvent", function(_, event, ...) Core[event](...) end)

-- Slash commands --------------------------------------------------------------------

-- /cti toggles the addon, /cti on and /cti off set it; /cti test shows a
-- sample popup on your target's nameplate; /cti learned opens the learned window
-- (works while the addon is off), /cti learned chat lists the spells the addon
-- learned by itself in chat and /cti forget clears them (the current spec's only).
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
        Heals.Forget()
        Procs.Forget()
        Ledger.Forget()
        print(PREFIX .. "forgot this spec's learned spells")
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
