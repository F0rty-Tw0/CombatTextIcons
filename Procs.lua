-- Procs: castless procs (trinket and talent damage that no cast or learned DoT explains).
--
-- Two entry points. Read learns a proc from exact size-group sums of the '?' hits, or from a tick
-- stream's fight total (a rhythm proc), against the meter rows after a fight; Name draws a learned
-- proc at hit time. The store is per character (charDB.procs), checked on load and never trusted.
-- No spell or class tables: every proc is learned.

local _, ns = ...
local Streams = ns.Streams

local Procs = {}
ns.Procs = Procs

local LEARN_STREAK = 3 -- exact fights in a row before a candidate is learned
local CAP = 64         -- unlearned candidates kept
local UNPAIRED_MAX = 2 -- unpaired reads in a row drop a learned proc
local SIZE_GUARD, CRIT_LO, CRIT_HI = Streams.SIZE_GUARD, Streams.CRIT_LO, Streams.CRIT_HI
local PARTIAL_CORE = 3 -- normals a group needs before lone hits below it may be its cut-short last ticks
local PAD_LO, PAD_HI = 0.85, 1.15 -- draw pads; two bands are also the same proc's when each, shrunk by PAD_LO, reaches the other
local RHYTHM_PERIOD = 0.1 -- two tick periods are one rhythm when they differ by at most this share of the longer
local RHYTHM_FIT = 0.05 -- a rhythm group's sum may fall short of a row's total, or pass its overkill, by this share of the total
local RHYTHM_STREAK = 2 -- fights a row's rhythm must pair in (gaps allowed) before it is learned; an exact pair: one

-- Whether two tick periods are one rhythm.
local function PeriodNear(a, b)
    return math.abs(a - b) <= RHYTHM_PERIOD * math.max(a, b)
end

Procs.LEARN_STREAK = LEARN_STREAK
Procs.RHYTHM_STREAK = RHYTHM_STREAK
Procs.PeriodNear = PeriodNear

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

-- [spellID] = { school, lo, hi, streak, learned, unpaired, seen, period, floor }; the saved table itself.
-- period is set on a rhythm proc only; floor is the lowest cut-short tick seen, kept only below lo.
local procs = {}

local function Count(value) return IsNumber(value) and value >= 0 and value == math.floor(value) and value or 0 end

local function Valid(id, entry)
    if not IsNumber(id) or not Plain(entry) or type(entry) ~= "table" then return false end
    local school, lo, hi = entry.school, entry.lo, entry.hi
    if not (IsNumber(school) and IsNumber(lo) and IsNumber(hi)) then return false end
    local period = entry.period
    if period ~= nil and not (IsNumber(period) and period > 0) then return false end

    return lo > 0 and lo <= hi
end

-- Procs.Init(charDB): adopts charDB.procs as the live store, dropping and repairing bad saved data.
function Procs.Init(charDB)
    if type(charDB.procs) ~= "table" then charDB.procs = {} end
    procs = charDB.procs
    local bad = {}
    for id, entry in pairs(procs) do
        if Valid(id, entry) then
            entry.streak, entry.unpaired = Count(entry.streak), Count(entry.unpaired)
            entry.seen = IsNumber(entry.seen) and entry.seen >= 0 and entry.seen or 0
            entry.learned = entry.learned == true
            entry.rest = entry.rest == true or nil
            entry.floor = IsNumber(entry.floor) and entry.floor > 0 and entry.floor < entry.lo and entry.floor or nil
        else
            bad[#bad + 1] = id
        end
    end
    for i = 1, #bad do procs[bad[i]] = nil end
end

-- Procs.Get(id): the learned entry, or nil (a candidate is not served).
function Procs.Get(id)
    if not IsNumber(id) then return nil end
    local entry = procs[id]

    return entry and entry.learned and entry or nil
end

-- Procs.Has(id): whether the store tracks id: a learned proc, or a size candidate with a streak (a streak-0
-- candidate has just failed an exact fight and owns nothing yet; spec 3.1 Rev 4b). A rhythm candidate is
-- not tracked, so a false sum candidate cannot block the alias, cast and Steady passes.
function Procs.Has(id)
    if not IsNumber(id) then return false end
    local entry = procs[id]

    return entry ~= nil and (entry.learned or (entry.streak > 0 and not entry.period and not entry.rest))
end

-- true / false for a plain flag text, nil (unknown) for a nil or secret one: the crit rule of Streams.Size.
function Procs.Crit(flagText)
    if not Plain(flagText) then return nil end

    return flagText == "CRITICAL"
end

function Procs.Drop(id)
    if IsNumber(id) then procs[id] = nil end
end

-- Procs.Unpaired(id): a learned proc the meter did not pair; the second strike in a row drops it.
function Procs.Unpaired(id)
    local entry = Procs.Get(id)
    if not entry then return end
    entry.unpaired = entry.unpaired + 1
    if entry.unpaired >= UNPAIRED_MAX then Procs.Drop(id) end
end

function Procs.Paired(id)
    local entry = Procs.Get(id)
    if entry then entry.unpaired = 0 end
end

-- Procs.List(): copies of every entry (candidates too), sorted by spellID.
function Procs.List()
    local list = {}
    for id, entry in pairs(procs) do
        list[#list + 1] = { spellID = id, school = entry.school, lo = entry.lo, hi = entry.hi, streak = entry.streak,
            learned = entry.learned, period = entry.period }
    end
    table.sort(list, function(a, b) return a.spellID < b.spellID end)

    return list
end

function Procs.Forget()
    for id in pairs(procs) do procs[id] = nil end
end

-- Read ---------------------------------------------------------------------------------------------
-- Procs.Read(hits, open, results, rows, at, ticks, streams): the post-fight learner (spec 3.1). The '?' hits are
-- split into size groups; a group's exact sum is matched against the unpaired meter rows (open) and the complement
-- of learned procs that came out 'under'. A pair counts only when it is unique both ways. The rhythm pass (below
-- Read's helpers) then pairs this fight's tick-stream groups with the open rows the size pass left.

-- A spell Learn or Fingerprints knows has one owner, and so has a row whose saved alias names a learned fingerprint.
local function Owned(id)
    return ns.Learn.Get(id) or ns.Fingerprints.IsLearned(id) or ns.Fingerprints.IsLearned(ns.Fingerprints.Alias(id))
end

-- The spells cast near the '?' hits (their sole cast and every candidate): a row of one is no castless proc
-- (Lightning Bolt 188196 summed exactly to its row in runs 20261025T192458Z and 194821Z).
local function Cast(hits)
    local cast = {}
    for _, hit in ipairs(hits) do
        if hit.castID then cast[hit.castID] = true end
        for _, candidate in ipairs(hit.candidates or {}) do cast[candidate.castID] = true end
    end

    return cast
end

-- The windows a group's sum can fill: every unowned open row, then the complement of every learned 'under' row.
local function Targets(open, results, rows, cast)
    local targets = {}
    for _, item in ipairs(open) do
        local row = item.row
        local id, overkill = row.spellID, row.overkill or 0
        if IsNumber(id) and not Owned(id) and not cast[id] then
            targets[#targets + 1] = { id = id, kind = "open", lo = row.total, hi = row.total + overkill, index = item.index, total = row.total, overkill = overkill }
        end
    end
    for index = 1, #rows do
        local row, result = rows[index], results[index]
        local id = row.spellID
        local isUnder = result and result.verdict == "under" and IsNumber(result.tally) and result.tally > 0
        local learned = Procs.Get(id)
        local isSizeUnder = isUnder and learned and not learned.period
        if isSizeUnder and IsNumber(id) and result.spellID == id and not Owned(id) then
            local lo = row.total - result.tally
            targets[#targets + 1] = { id = id, kind = "under", lo = lo, hi = lo + (row.overkill or 0), index = index }
        end
    end

    return targets
end

-- Normal hits of one school, sorted: a hit joins the current group while it is within SIZE_GUARD of its size.
local function Walk(school, amounts)
    local groups, current = {}, nil
    for _, amount in ipairs(amounts) do
        if current and amount - current.lo <= SIZE_GUARD * amount then
            current.hi, current.sum, current.base, current.count = amount, current.sum + amount, current.base + amount, current.count + 1
        else
            current = { school = school, lo = amount, hi = amount, floor = amount, sum = amount, base = amount, count = 1 }
            groups[#groups + 1] = current
        end
    end

    return groups
end

-- The one group a crit fits (smallest x CRIT_LO .. largest x CRIT_HI), or nil for none or several.
local function Fit(groups, amount)
    local found
    for _, group in ipairs(groups) do
        if group.lo * CRIT_LO <= amount and amount <= group.hi * CRIT_HI then
            if found then return nil end
            found = group
        end
    end

    return found
end

-- Walked groups i..j as one group: their normals, and every crit in the run's own crit window (a crit that
-- fits two of its groups is an orphan for each, but it is the run's).
local function Run(walked, i, j, crits)
    local run = { school = walked[i].school, lo = walked[i].lo, hi = walked[j].hi, floor = walked[i].lo, sum = 0, count = 0 }
    for k = i, j do run.sum, run.count = run.sum + walked[k].base, run.count + walked[k].count end
    for _, amount in ipairs(crits) do
        if run.lo * CRIT_LO <= amount and amount <= run.hi * CRIT_HI then run.sum = run.sum + amount end
    end

    return run
end

-- A ticking proc (Surging Totem 73921: ~12K every 1.7 s) splits two ways (runs 20261025T192458Z, 194821Z):
-- its size steps under a buff (x1.2, less than a crit: 1287663 hits 343, then 412) or the 15 % walk cuts its
-- run, so every run of walked groups spanning less than a crit is one more group; and each instance's last
-- tick is cut short (2315..9458 against 11-13K), a lone hit below the rest. A core of PARTIAL_CORE normals or
-- more also counts with one or two lone hits below it (their normal amount); the band stays the core's and the
-- lowest lone hit is the group's floor.
local function Ticking(groups, walked, crits)
    local lone = {}
    for i = 1, #walked do
        for j = i, #walked do
            if walked[j].hi >= walked[i].lo * CRIT_LO then break end
            local core = i == j and walked[i] or Run(walked, i, j, crits)
            if i < j then groups[#groups + 1] = core end
            if core.count >= PARTIAL_CORE then
                for a = 1, #lone do
                    local one = lone[a]
                    groups[#groups + 1] = { school = core.school, lo = core.lo, hi = core.hi, floor = one.lo, sum = core.sum + one.base, count = core.count + 1 }
                    for b = a + 1, #lone do
                        groups[#groups + 1] = { school = core.school, lo = core.lo, hi = core.hi, floor = one.lo,
                            sum = core.sum + one.base + lone[b].base, count = core.count + 2 }
                    end
                end
            end
        end
        if walked[i].count == 1 then lone[#lone + 1] = walked[i] end
    end
end

-- Equal sums of one school are the same hits reached two ways (a run, or a core and its lone hits): one group,
-- with the narrowest core (a lone hit inside a run is a cut-short tick too) and the lowest floor.
local function Distinct(groups)
    local kept, bySum = {}, {}
    for _, group in ipairs(groups) do
        local key = group.school .. ":" .. group.sum
        local other = bySum[key]
        if other then
            other.lo, other.hi, other.floor = math.max(other.lo, group.lo), math.max(other.hi, group.hi), math.min(other.floor, group.floor)
        else
            bySum[key] = group
            kept[#kept + 1] = group
        end
    end

    return kept
end

-- Groups per school ascending. A crit adds to the one group it fits; a hit whose crit flag is not plain
-- true or false is an orphan, like a crit that fits none or two. A hit of 0 or less joins no group.
local function Groups(hits, ticks)
    local bySchool, schools = {}, {}
    for _, hit in ipairs(hits) do
        local school, amount, crit = hit.school, hit.amount, hit.crit
        if IsNumber(school) and IsNumber(amount) and amount > 0 and Plain(crit) and (crit == true or crit == false) then
            if not bySchool[school] then
                bySchool[school] = { normals = {}, crits = {} }
                schools[#schools + 1] = school
            end
            local list = crit and bySchool[school].crits or bySchool[school].normals
            list[#list + 1] = amount
        end
    end
    table.sort(schools)
    local groups = {}
    for _, school in ipairs(schools) do
        table.sort(bySchool[school].normals)
        local walked = Walk(school, bySchool[school].normals)
        for _, amount in ipairs(bySchool[school].crits) do
            local group = Fit(walked, amount)
            if group then group.sum = group.sum + amount end
        end
        for _, group in ipairs(walked) do groups[#groups + 1] = group end
        Ticking(groups, walked, bySchool[school].crits)
        bySchool[school].walked = walked
    end
    -- A learned DoT's drawn ticks were named by votes, not the meter: one more group per school sums them with its
    -- '?' groups (Wither 445468 learned castless proc 1287663's ticks from the opener's frame, run 20261025T194314Z).
    local drawn, drawnSchools = {}, {}
    for _, tick in ipairs(ticks or {}) do
        local school, amount = tick.school, tick.amount
        if IsNumber(school) and IsNumber(amount) and amount > 0 then
            local extra = drawn[school]
            if not extra then
                extra = { school = school, sum = 0 }
                drawn[school], drawnSchools[#drawnSchools + 1] = extra, school
                for _, group in ipairs(bySchool[school] and bySchool[school].walked or {}) do
                    extra.sum = extra.sum + group.sum
                    extra.lo, extra.hi = math.min(extra.lo or group.lo, group.lo), math.max(extra.hi or group.hi, group.hi)
                end
            end
            extra.sum = extra.sum + amount
            if tick.crit == false then extra.lo, extra.hi = math.min(extra.lo or amount, amount), math.max(extra.hi or amount, amount) end
        end
    end
    table.sort(drawnSchools)
    for _, school in ipairs(drawnSchools) do
        if drawn[school].lo then
            drawn[school].floor, drawn[school].drawn = drawn[school].lo, true
            groups[#groups + 1] = drawn[school]
        end
    end

    return Distinct(groups)
end

-- target index -> group, for the pairs that are unique both ways.
local function Matches(groups, targets)
    local fits, perGroup, perTarget = {}, {}, {}
    for groupIndex, group in ipairs(groups) do
        for targetIndex, target in ipairs(targets) do
            if target.lo <= group.sum and group.sum <= target.hi then
                fits[#fits + 1] = { groupIndex, targetIndex }
                perGroup[groupIndex] = (perGroup[groupIndex] or 0) + 1
                perTarget[targetIndex] = (perTarget[targetIndex] or 0) + 1
            end
        end
    end
    local matches = {}
    for _, fit in ipairs(fits) do
        local groupIndex, targetIndex = fit[1], fit[2]
        if perGroup[groupIndex] == 1 and perTarget[targetIndex] == 1 then matches[targetIndex] = groups[groupIndex] end
    end

    return matches
end

-- An entry's floor (the lowest cut-short tick seen) is saved only below its band.
local function Floor(entry) return entry.floor or entry.lo end
local function SetFloor(entry, floor) entry.floor = floor < entry.lo and floor or nil end
local function Overlaps(entry, group) return entry.lo * PAD_LO <= group.hi and group.lo * PAD_LO <= entry.hi end
local function Widens(entry, group) return group.lo < entry.lo or group.hi > entry.hi or (group.floor or group.lo) < Floor(entry) end
local function Union(entry, group)
    local floor = math.min(Floor(entry), group.floor or group.lo)
    entry.lo, entry.hi = math.min(entry.lo, group.lo), math.max(entry.hi, group.hi)
    SetFloor(entry, floor)
end

-- A counted pair for a candidate: one more exact fight, or a restart when the group is another proc's. An off-size
-- group of the same school is first a miss that keeps the streak and band (Malevolence 446285 hit 22498 in four lock2
-- fights, 18748 in F3); a candidate's unpaired counts misses in a row, and the UNPAIRED_MAX-th one restarts it.
local function Grow(entry, group)
    local sameSchool = entry.school == group.school
    if sameSchool and Overlaps(entry, group) then
        Union(entry, group)
        entry.streak, entry.unpaired = entry.streak + 1, 0
        if entry.streak < LEARN_STREAK then return "" end
        entry.learned = true

        return " learned"
    end
    entry.unpaired = entry.unpaired + 1
    if sameSchool and entry.streak > 0 and entry.unpaired < UNPAIRED_MAX then return " miss" end
    entry.school, entry.lo, entry.hi, entry.streak, entry.unpaired = group.school, group.lo, group.hi, 1, 0
    SetFloor(entry, group.floor or group.lo)

    return " restart"
end

-- The state x event table for one target; returns the log suffix of a change, nil when nothing changed.
local function Step(entry, group, target)
    if target.kind == "under" then
        if not (group and entry.school == group.school and Widens(entry, group)) then return nil end
        -- one lone hit below the band is a cut-short tick: it lowers the floor, not the band
        if group.count == 1 and group.hi < entry.lo then
            SetFloor(entry, math.min(Floor(entry), group.lo))

            return " widen"
        end
        Union(entry, group)

        return " widen"
    end
    if not group then
        if entry.learned or target.overkill ~= 0 or entry.streak == 0 then return nil end
        entry.streak = 0

        return " reset"
    end
    if not entry.learned then return Grow(entry, group) end
    if not (entry.school == group.school and Overlaps(entry, group) and Widens(entry, group)) then return nil end
    Union(entry, group)

    return " widen"
end

-- Apply(target, group): creates a candidate or steps the existing entry; returns the log suffix of a change.
-- A school's remainder that equals an open row exactly (overkill 0) is learned at once: its spell is often cast once
-- a fight (Wither 445468), so waiting LEARN_STREAK fights lost F1-F3 of every warlock run. Inside an overkill window
-- it stays a candidate.
local function Apply(target, group)
    local entry = procs[target.id]
    if entry and entry.period then return nil end
    if entry then return Step(entry, group, target) end
    if not group then return nil end
    local learned = group.rest == true and target.overkill == 0
    procs[target.id] = { school = group.school, lo = group.lo, hi = group.hi, streak = 1, learned = learned, unpaired = 0, seen = 0,
        rest = group.rest }
    SetFloor(procs[target.id], group.floor or group.lo)

    return learned and " learned" or ""
end

local function Weaker(idA, a, idB, b)
    if a.streak ~= b.streak then return a.streak < b.streak end
    if a.seen ~= b.seen then return a.seen < b.seen end

    return idA < idB
end

-- Candidates past CAP go: lowest streak, then lowest seen, then lowest id. Learned entries stay.
local function Evict()
    while true do
        local count, weakestID, weakest = 0, nil, nil
        for id, entry in pairs(procs) do
            if not entry.learned then
                count = count + 1
                if not weakest or Weaker(id, entry, weakestID, weakest) then weakestID, weakest = id, entry end
            end
        end
        if count <= CAP then return end
        procs[weakestID] = nil
    end
end

-- The verdict a learned proc gives its meter row: the group's sum agrees with the row's total.
local function Agree(target, sum)
    return { spellID = target.id, meterID = target.id, tally = sum, meter = target.total, verdict = "agree" }
end

-- Rhythm groups: this fight's stream records that hold a normal hit, sorted by school, period, sum. Every
-- prefix of a run of one school whose periods sit near the run's first is a group: the fight total of one
-- proc that ticked as several streams. A run ends before a record that would make its hits span a crit.
local function RhythmGroups(streams)
    local list = {}
    for stream, rec in pairs(streams) do
        if rec.lo then
            list[#list + 1] = { school = rec.school, period = stream.period, sum = rec.sum, n = rec.n, lo = rec.lo, hi = rec.hi }
        end
    end
    table.sort(list, function(a, b)
        if a.school ~= b.school then return a.school < b.school end
        if a.period ~= b.period then return a.period < b.period end

        return a.sum < b.sum
    end)
    local groups = {}
    for i, first in ipairs(list) do
        local sum, count, lo, hi = 0, 0, first.lo, first.hi
        for j = i, #list do
            local rec = list[j]
            if rec.school ~= first.school or not PeriodNear(first.period, rec.period) then break end
            local low, high = math.min(lo, rec.lo), math.max(hi, rec.hi)
            if j > i and high >= low * CRIT_LO then break end -- a crit apart: two procs, not one
            sum, count, lo, hi = sum + rec.sum, count + rec.n, low, high
            groups[#groups + 1] = { school = first.school, period = first.period, sum = sum, count = count, lo = lo, hi = hi }
        end
    end

    return groups
end

-- target index -> group, for the pairs that are unique both ways, and target index -> true for the exact ones. Exact
-- pairs come first: a group's sum inside a row's own window (total .. total + overkill). The groups and rows they leave
-- then pair in each row's window widened by RHYTHM_FIT of its total (a DoT's last tick may be cut short, a meter row
-- counts overkill apart). Darkglare 205231's five beams summed to its row exactly in lock3 F1, yet also fit Wither
-- 445468's widened window (4.9 % off), so neither row paired.
local function RhythmMatches(groups, targets)
    local matches, exact, used = {}, {}, {}
    for index, group in pairs(Matches(groups, targets)) do
        matches[index], exact[index], used[group] = group, true, true
    end
    local restGroups, windows, at = {}, {}, {}
    for _, group in ipairs(groups) do
        if not used[group] then restGroups[#restGroups + 1] = group end
    end
    for index, target in ipairs(targets) do
        if not exact[index] then
            windows[#windows + 1] = { lo = target.lo * (1 - RHYTHM_FIT), hi = target.hi + target.lo * RHYTHM_FIT }
            at[#windows] = index
        end
    end
    for i, group in pairs(Matches(restGroups, windows)) do matches[at[i]] = group end

    return matches, exact
end

-- The state x event table for one open row and its rhythm group; returns the entry, nil when nothing changed.
-- An exact pair on a row with no overkill learns at once, as the remainder pass does (Darkglare 205231 summed to
-- its row to the unit in lock3 F1, and its next clear fights were the big ones).
local function RhythmStep(target, group, at, results, exact)
    local entry = procs[target.id]
    local isRhythm = entry and entry.period
    local same = isRhythm and entry.school == group.school and PeriodNear(entry.period, group.period)
    if isRhythm and entry.learned and not same then return nil end
    if same then
        entry.lo, entry.hi = math.min(entry.lo, group.lo), math.max(entry.hi, group.hi)
        entry.seen = at
        if not entry.learned then entry.streak = entry.streak + 1 end
    else
        entry = { school = group.school, lo = group.lo, hi = group.hi, period = group.period, streak = 1, learned = false,
            unpaired = 0, seen = at }
        procs[target.id] = entry
    end
    if not entry.learned and (entry.streak >= RHYTHM_STREAK or exact and target.overkill == 0) then
        entry.learned, entry.unpaired = true, 0
        results[target.index] = Agree(target, group.sum)
    end

    return entry
end

-- The rhythm pass of Read: the open rows the size pass left (taken[id]) against this fight's stream groups.
-- A learned size proc's row is its own; a row with no unique match is left as it is (no streak reset).
local function RhythmPass(open, results, rows, at, streams, taken)
    local targets = {}
    for _, target in ipairs(Targets(open, results, rows, {})) do
        local entry = procs[target.id]
        local isLearnedSize = entry and entry.learned and not entry.period
        local isFree = target.kind == "open" and target.lo > 0 and not taken[target.id]
        if isFree and not isLearnedSize then
            targets[#targets + 1] = target
        end
    end
    local matches, exact = RhythmMatches(RhythmGroups(streams), targets)
    for index, target in ipairs(targets) do
        local group = matches[index]
        local isNew = procs[target.id] == nil
        local entry = group and RhythmStep(target, group, at, results, exact[index])
        if entry then
            if ns.Debug then
                ns.Debug("TEACH rhythm %s school=%s p=%.2f band=%s-%s streak=%s%s", target.id, entry.school, entry.period, entry.lo,
                    entry.hi, entry.streak, entry.learned and " learned" or "")
            end
            if isNew then Evict() end
        end
    end
end

-- Remainder pass (L14) ------------------------------------------------------------------------------
-- Wither 445468's growing ticks split into many size groups, yet its row equalled its school's remainder exactly in
-- 12 of 13 warlock fights (lock, lock2): every '?' hit and drawn tick of school 36 no matched group held.

-- Whether a matched group of the hit's school holds it: a normal in [floor, hi], a crit in the group's crit window.
local function Held(taken, school, amount, crit)
    for _, group in ipairs(taken[school] or {}) do
        if crit == false and (group.floor or group.lo) <= amount and amount <= group.hi then return true end
        if crit == true and group.lo * CRIT_LO <= amount and amount <= group.hi * CRIT_HI then return true end
    end

    return false
end

-- One remainder group per school (rest = true): every '?' hit no matched group holds and every drawn tick, its band
-- from their normals. A school with no normal left, or whose drawn group matched, has none.
local function Remainders(hits, ticks, matches)
    local taken, whole = {}, {}
    for _, group in pairs(matches) do
        if group.drawn then whole[group.school] = true end
        taken[group.school] = taken[group.school] or {}
        table.insert(taken[group.school], group)
    end
    local bySchool, schools = {}, {}
    local function Add(school, amount, crit)
        if not (IsNumber(school) and IsNumber(amount) and amount > 0) or whole[school] then return end
        local rest = bySchool[school]
        if not rest then
            rest = { school = school, sum = 0, count = 0, rest = true }
            bySchool[school], schools[#schools + 1] = rest, school
        end
        rest.sum, rest.count = rest.sum + amount, rest.count + 1
        if crit == false then rest.lo, rest.hi = math.min(rest.lo or amount, amount), math.max(rest.hi or amount, amount) end
    end
    for _, hit in ipairs(hits) do
        if not Held(taken, hit.school, hit.amount, hit.crit) then Add(hit.school, hit.amount, hit.crit) end
    end
    for _, tick in ipairs(ticks or {}) do Add(tick.school, tick.amount, tick.crit) end
    table.sort(schools)
    local list = {}
    for _, school in ipairs(schools) do
        local rest = bySchool[school]
        if rest.lo then
            rest.floor = rest.lo
            list[#list + 1] = rest
        end
    end

    return list
end

-- The open rows no size group fits (a row cast near the hits too, but not a '?' hit's sole cast) against each school's
-- remainder, both ways unique; a pair joins matches, and a row the size pass did not list joins targets only then.
local function RemainderMatches(hits, ticks, groups, targets, matches, open, results, rows)
    local listed, candidates = {}, {}
    for index, target in ipairs(targets) do
        listed[target.id] = true
        candidates[#candidates + 1] = { target = target, index = index }
    end
    local sole = {}
    for _, hit in ipairs(hits) do
        if hit.castID then sole[hit.castID] = true end
    end
    for _, target in ipairs(Targets(open, results, rows, sole)) do
        if not listed[target.id] then candidates[#candidates + 1] = { target = target } end
    end
    local free, at = {}, {}
    for _, item in ipairs(candidates) do
        local target, fits = item.target, false
        for _, group in ipairs(groups) do
            if target.lo <= group.sum and group.sum <= target.hi then fits = true break end
        end
        if target.kind == "open" and not fits then free[#free + 1], at[#free + 1] = target, item.index end
    end
    for i, group in pairs(Matches(Remainders(hits, ticks, matches), free)) do
        local index = at[i]
        if not index then
            targets[#targets + 1] = free[i]
            index = #targets
        end
        matches[index] = group
    end
end

-- Read: the size pass, the remainder pass, then the rhythm pass when the fight's streams are given.
function Procs.Read(hits, open, results, rows, at, ticks, streams)
    local targets = Targets(open, results, rows, Cast(hits))
    local groups = Groups(hits, ticks)
    local matches = Matches(groups, targets)
    RemainderMatches(hits, ticks, groups, targets, matches, open, results, rows)
    local taken = {}
    for index in pairs(matches) do
        if targets[index].kind == "open" then taken[targets[index].id] = true end
    end
    for index, target in ipairs(targets) do
        local group, isNew = matches[index], procs[target.id] == nil
        local suffix = Apply(target, group)
        if suffix then
            local entry = procs[target.id]
            entry.seen = at
            if ns.Debug then
                ns.Debug("TEACH proc %s school=%s band=%s-%s%s streak=%s%s", target.id, entry.school, entry.lo, entry.hi,
                    entry.floor and (" floor=" .. entry.floor) or "", entry.streak, suffix)
            end
            if suffix == " learned" then
                results[target.index] = Agree(target, group.sum)
            end
            if isNew then Evict() end
        end
    end
    if streams then RhythmPass(open, results, rows, at, streams, taken) end
end

-- Procs.Teach(id, school, lo, hi, period, at): the castless pass (Ground.Castless) proved a rhythm on many plates under
-- the open row id, or the DoT pass a learned DoT's second series under its row (Teacher's SecondSeries): learned at
-- once, as an exact rhythm pair is, and drawn by Procs.NameStream.
function Procs.Teach(id, school, lo, hi, period, at)
    local plain = IsNumber(id) and IsNumber(school) and IsNumber(lo) and IsNumber(hi) and IsNumber(period)
    if not (plain and lo > 0 and lo <= hi and period > 0) then return end
    procs[id] = { school = school, lo = lo, hi = hi, period = period, streak = RHYTHM_STREAK, learned = true,
        unpaired = 0, seen = IsNumber(at) and at or 0 }
end

-- Name ---------------------------------------------------------------------------------------------------
-- Procs.Name(school, amount, flagText): the one learned proc whose padded range holds the hit, or nil for none
-- or several. A plain flag picks the normal or the crit range; a nil or secret flag fits either (as Streams.Size).
function Procs.Name(school, amount, flagText)
    if not (IsNumber(school) and IsNumber(amount)) then return nil end
    local crit = Procs.Crit(flagText) -- nil: unknown
    local found, contested
    for id, entry in pairs(procs) do
        if entry.learned == true and not entry.period and entry.school == school then
            local lo, hi, floor = entry.lo * PAD_LO, entry.hi * PAD_HI, Floor(entry) * PAD_LO
            local normal = lo <= amount and amount <= hi
            local big = lo * CRIT_LO <= amount and amount <= hi * CRIT_HI
            if (crit ~= true and normal) or (crit ~= false and big) then
                if found then return nil end
                found = id
            end
            -- below the band down to its floor a cut-short tick of this proc may be the hit: no proc names it
            local short = floor <= amount and amount < lo
            local shortBig = floor * CRIT_LO <= amount and amount < lo * CRIT_LO
            if (crit ~= true and short) or (crit ~= false and shortBig) then contested = true end
        end
    end
    -- a normal hit inside a proc's own band (unpadded) is that proc's, cut-short ticks or not
    local own = found and crit == false and procs[found].lo <= amount and amount <= procs[found].hi
    if contested and not own then return nil end

    return found
end

-- Procs.NameStream(stream): the one learned rhythm entry whose school and period match the stream and whose
-- padded band holds its last hit, or nil for none or several. A positive answer is cached on stream.procID and
-- served only while that entry is still a learned rhythm entry; once it is not, the stream is looked up afresh.
function Procs.NameStream(stream)
    if not stream then return nil end
    if stream.procID then
        local cached = Procs.Get(stream.procID)
        if cached and cached.period then return stream.procID end
        stream.procID = nil -- the entry is gone or no longer a rhythm proc: look the stream up afresh
    end
    local school, period, amount = stream.school, stream.period, stream.lastAmount
    if not (IsNumber(school) and IsNumber(period) and IsNumber(amount)) then return nil end
    local found
    for id, entry in pairs(procs) do
        local isRhythm = entry.learned == true and entry.period and entry.school == school
        if isRhythm and PeriodNear(entry.period, period) and entry.lo * PAD_LO <= amount and amount <= entry.hi * PAD_HI then
            if found then return nil end
            found = id
        end
    end
    stream.procID = found

    return found
end

-- Procs.NameCast(school, amount, flagText, candidates): the one learned rhythm entry, keyed by a cast that may
-- have made the hit (Casts.Candidates), whose school matches and whose padded band holds the hit (the normal or
-- crit test of Procs.Name), or nil for none or several. Names the ticks before the stream is born.
function Procs.NameCast(school, amount, flagText, candidates)
    if not (IsNumber(school) and IsNumber(amount)) then return nil end
    local crit = Procs.Crit(flagText) -- nil: unknown
    local found
    for _, cast in ipairs(candidates or {}) do
        -- the cast's base, then its own spell; no base, nothing (runs per hit, so no table per cast)
        local id, nextID = cast.castID, cast.castSpell
        while id ~= nil do
            local entry = procs[id]
            if id ~= found and entry and entry.learned == true and entry.period and entry.school == school then
                local lo, hi = entry.lo * PAD_LO, entry.hi * PAD_HI
                local normal = lo <= amount and amount <= hi
                local big = lo * CRIT_LO <= amount and amount <= hi * CRIT_HI
                if (crit ~= true and normal) or (crit ~= false and big) then
                    if found then return nil end
                    found = id
                end
            end
            id, nextID = nextID, nil
        end
    end

    return found
end
