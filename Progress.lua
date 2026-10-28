-- Combat Text Icons: learning progress. When combat starts (Progress.Start, from Core) a
-- snapshot records each spell's learn state, one state per ID in the learned panel's claim
-- order (learned ticks, learned fingerprints, learned procs, tick votes, fingerprint
-- candidates, proc candidates; the Spells.lua table is left out). When the Teacher's outcome
-- for that fight is final (Teacher.OnRead) the state is taken again and what moved shows as
-- fight-end popups (Display.Notice), at most Display.MAX_NOTICES rows at the top of the screen
-- with their icons in one column, in priority order from the top: the area result of the first
-- solo read since login (always) or a later area change, "learned!", "dropped", "learning n/m".
-- More changes than rows fold the rest into "+K more". A skipped read or a group fight shows
-- nothing. A fight that starts before the previous read is done takes a new snapshot; that
-- earlier fight's changes are lost. A fight that starts while a read is still judged (Teacher's
-- sliced reads) pauses it: that read then shows what it changed after the new snapshot, and the
-- new fight's own read shows nothing.
--
-- /cti progress on|off sets CombatTextIconsDB.showProgress (nil = on). Off ignores fight
-- starts and reads; turning it off also drops a snapshot taken.

local _, ns = ...
local Learn, Fingerprints, Procs, Teacher, Display, Meter = ns.Learn, ns.Fingerprints, ns.Procs, ns.Teacher, ns.Display,
    ns.Meter

local Progress = {}
ns.Progress = Progress

local AREA_TEXT = { clear = "area clear: '?' shown", crowded = "crowded: '?' hidden" }
local RANKS = { area = 1, learned = 2, dropped = 3, learning = 4 } -- change kind -> priority, 1 first

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local before = nil       -- the snapshot taken at fight start while armed, else nil (idle or off)
local areaShown = false  -- the first solo read's area result was shown; never saved

-- Each ID's learn state { n, m, learned, checking }, first claim wins (Panel KnownSpells' order).
-- A candidate is listed only once it has a vote or a streak, as in the panel.
local function Snapshot()
    local ids = {}
    local function Claim(id, state)
        if ids[id] == nil then ids[id] = state end
    end

    for _, entry in ipairs(Learn.List()) do Claim(entry.spellID, { learned = true }) end
    local prints, procList = Fingerprints.List(), Procs.List()
    for _, entry in ipairs(prints) do
        if entry.learned then Claim(entry.spellID, { learned = true }) end
    end
    for _, entry in ipairs(procList) do
        if entry.learned then Claim(entry.spellID, { learned = true }) end
    end
    for _, entry in ipairs(Learn.VoteList()) do
        local need = entry.school == 1 and Learn.VOTES_MIN_PHYSICAL or Learn.VOTES_MIN
        if entry.votes > 0 then
            Claim(entry.spellID, { n = entry.votes, m = need, checking = entry.votes >= need })
        end
    end
    for _, entry in ipairs(prints) do
        if not entry.learned then Claim(entry.spellID, { n = entry.casts, m = Fingerprints.LEARN_CASTS }) end
    end
    for _, entry in ipairs(procList) do
        if not entry.learned and entry.streak > 0 then
            Claim(entry.spellID, { n = entry.streak, m = entry.period and Procs.RHYTHM_STREAK or Procs.LEARN_STREAK })
        end
    end

    return { ids = ids, area = Teacher.area }
end

local function SpellIcon(spellID)
    local texture = C_Spell.GetSpellTexture(spellID)
    if Plain(texture) then return texture end

    return Meter.UNKNOWN_ICON
end

-- The changes from `old` to `new` as { rank, id, texture, text }, sorted by rank, then ID. An ID
-- absent from a snapshot counts as n = 0, not learned.
local function Changes(old, new)
    local changes, none = {}, { n = 0 }
    local function Add(kind, id, texture, text)
        changes[#changes + 1] = { rank = RANKS[kind], id = id, texture = texture, text = text }
    end

    if not areaShown or new.area ~= old.area then Add("area", 0, Meter.UNKNOWN_ICON, AREA_TEXT[new.area]) end
    local seen = {}
    for _, snapshot in ipairs({ old, new }) do
        for id in pairs(snapshot.ids) do
            if not seen[id] then
                seen[id] = true
                local was, is = old.ids[id] or none, new.ids[id] or none
                if is.learned and not was.learned then
                    Add("learned", id, SpellIcon(id), "learned!")
                elseif was.learned and not is.learned then
                    Add("dropped", id, SpellIcon(id), "dropped")
                elseif not is.learned and is.n > was.n then
                    local text = is.checking and "learning (checking)" or string.format("learning %d/%d", is.n, is.m)
                    Add("learning", id, SpellIcon(id), text)
                end
            end
        end
    end
    table.sort(changes, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end

        return a.id < b.id
    end)

    return changes
end

-- The read of the armed fight is final: show what it changed, then go idle.
local function OnRead(last)
    local old = before
    if not old then return end
    before = nil
    if last.skip or last.area == "group" then return end

    local changes = Changes(old, Snapshot())
    areaShown = true
    local max = Display.MAX_NOTICES
    local shown = #changes > max and max - 1 or #changes
    for i = 1, shown do Display.Notice(changes[i].texture, changes[i].text, i) end
    if #changes > max then
        Display.Notice(Meter.UNKNOWN_ICON, string.format("+%d more (/cti learned)", #changes - shown), max)
    end
end

Teacher.OnRead = OnRead

-- Combat began: snapshot the learn state (again, when a snapshot is still waiting for its read).
function Progress.Start()
    if CombatTextIconsDB.showProgress == false then return end
    before = Snapshot()
end

-- /cti progress on|off. Off drops a waiting snapshot; on waits for the next fight start.
function Progress.SetShown(on)
    CombatTextIconsDB.showProgress = on
    if not on then before = nil end
end
