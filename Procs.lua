-- Procs: castless procs (trinket and talent damage that no cast or learned DoT explains).
--
-- Two entry points. Read learns a proc from exact size-group sums of the '?' hits, or from a tick
-- stream's fight total (a rhythm proc), against the meter rows after a fight; Name draws a learned
-- proc at hit time. The store is per spec (charDB.procs), checked on load and never trusted.
-- No spell or class tables: every proc is learned.

local _, ns = ...
local Streams = ns.Streams

local Procs = {}
ns.Procs = Procs

local LEARN_STREAK = 3 -- exact fights in a row before a candidate is learned
local CAP = 64         -- unlearned candidates kept
local UNPAIRED_MAX = 2 -- unpaired clear reads in a row drop a learned proc
local SIZE_GUARD, CRIT_LO, CRIT_HI = Streams.SIZE_GUARD, Streams.CRIT_LO, Streams.CRIT_HI
local PARTIAL_CORE = 3 -- normals a group needs before lone hits below it may be its cut-short last ticks
local PAD_LO, PAD_HI = 0.85, 1.15 -- draw pads; two bands are also the same proc's when each, shrunk by PAD_LO, reaches the other
local RHYTHM_PERIOD = 0.1 -- two tick periods are one rhythm when they differ by at most this share of the longer
local RHYTHM_FIT = 0.05 -- a rhythm group's sum may fall short of a row's total, or pass its overkill, by this share of the total
local RHYTHM_STREAK = 2 -- fights a row's rhythm must pair in (gaps allowed) before it is learned; an exact pair: one
local TWIN = 0.002     -- two hits of one frame on two plates are one split hit's shares when their sizes differ by at
                       -- most this share
local SPLITS_MAX = 4   -- extra size bands (splits) a learned size proc keeps
local SHARES_MAX = 8   -- plates a split proc's rule (Rule) predicts a share size for
local PREDICT_PAD = 0.02 -- a predicted share size's slack, each way

-- Whether two tick periods are one rhythm.
local function PeriodNear(a, b)
    return math.abs(a - b) <= RHYTHM_PERIOD * math.max(a, b)
end

Procs.LEARN_STREAK = LEARN_STREAK
Procs.RHYTHM_STREAK = RHYTHM_STREAK
Procs.PeriodNear = PeriodNear
Procs.TWIN = TWIN

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

-- [spellID] = { school, lo, hi, streak, learned, unpaired, seen, period, floor, critSeen, fall }; the saved table itself.
-- fall: a rhythm proc's steady fall per tick (Procs.Teach), nil for none.
-- period is set on a rhythm proc only; floor is the lowest cut-short tick seen, kept only below lo. critSeen: a group
-- that paired the proc's row held a crit (false: none yet, so Name draws no crit; a store saved before it: true).
-- splits: a learned size proc's extra bands { lo, hi, twin, k } (Split), nil for none. k (the entry's and each split's):
-- the plates each hit of its band landed on with its like shares (Shares), nil when unknown or mixed.
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

-- A rhythm's saved onset links (Onset links, below), or nil when none survive: each a cast ID with plain delays and
-- a burst count.
local function ValidLinks(links)
    if not (Plain(links) and type(links) == "table") then return nil end
    local kept
    for castID, link in pairs(links) do
        local ok = IsNumber(castID) and Plain(link) and type(link) == "table" and IsNumber(link.lo) and IsNumber(link.hi)
            and IsNumber(link.n) and link.lo >= 0 and link.lo <= link.hi and link.n >= 1
        if ok then
            kept = kept or {}
            kept[castID] = { lo = link.lo, hi = link.hi, n = math.floor(link.n) }
        end
    end

    return kept
end

-- A saved steady fall (Procs.Teach): a share above 0 and at most Streams.FALL_MAX, else nil.
local function ValidFall(fall)
    return IsNumber(fall) and fall > 0 and fall <= Streams.FALL_MAX and fall or nil
end

-- A saved plate count (Shares, below): a whole number from 1, else nil.
local function ValidK(k)
    return IsNumber(k) and k >= 1 and k == math.floor(k) and k or nil
end

-- A size proc's saved splits (Split, below), or nil when none survive: each a plain band lo <= hi above 0, twin
-- true or false, and its plate count k or nil.
local function ValidSplits(splits)
    if not (Plain(splits) and type(splits) == "table") then return nil end
    local kept
    for _, band in ipairs(splits) do
        local ok = Plain(band) and type(band) == "table" and IsNumber(band.lo) and IsNumber(band.hi) and band.lo > 0
            and band.lo <= band.hi and #(kept or {}) < SPLITS_MAX
        if ok then
            kept = kept or {}
            kept[#kept + 1] = { lo = band.lo, hi = band.hi, twin = band.twin == true, k = ValidK(band.k) }
        end
    end

    return kept
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
            entry.critSeen = entry.critSeen ~= false
            entry.critOnly = entry.critOnly == true or nil
            entry.onset = entry.period and ValidLinks(entry.onset) or nil
            entry.fall = entry.period and ValidFall(entry.fall) or nil
            entry.splits = not entry.period and ValidSplits(entry.splits) or nil
            entry.k = not entry.period and ValidK(entry.k) or nil
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

-- Procs.Unpaired(id): a learned proc a clear read did not pair; the second strike in a row drops it.
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

-- Procs.List(): copies of every entry (candidates too), sorted by spellID. A learned proc's `unpaired` is its strikes
-- towards a drop (the panel's warnings).
function Procs.List()
    local list = {}
    for id, entry in pairs(procs) do
        list[#list + 1] = { spellID = id, school = entry.school, lo = entry.lo, hi = entry.hi, streak = entry.streak,
            learned = entry.learned, period = entry.period, unpaired = entry.unpaired }
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
            current = { school = school, lo = amount, hi = amount, floor = amount, sum = amount, base = amount,
                count = 1, critCount = 0 }
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
    local run = { school = walked[i].school, lo = walked[i].lo, hi = walked[j].hi, floor = walked[i].lo, sum = 0,
        count = 0, critCount = 0 }
    for k = i, j do run.sum, run.count = run.sum + walked[k].base, run.count + walked[k].count end
    for _, amount in ipairs(crits) do
        if run.lo * CRIT_LO <= amount and amount <= run.hi * CRIT_HI then
            run.sum, run.critCount = run.sum + amount, run.critCount + 1
        end
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
                    groups[#groups + 1] = { school = core.school, lo = core.lo, hi = core.hi, floor = one.lo,
                        sum = core.sum + one.base, count = core.count + 1, critCount = core.critCount }
                    for b = a + 1, #lone do
                        groups[#groups + 1] = { school = core.school, lo = core.lo, hi = core.hi, floor = one.lo,
                            sum = core.sum + one.base + lone[b].base, count = core.count + 2,
                            critCount = core.critCount }
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

-- A proc that only ever crits has no normal for its crits to fit, and another spell's normal may claim them (shamanele
-- F3: four crits, 43116-56732, summed to 285452's row 202282 exactly, and 43116 sat in normal 16764's crit window).
-- So a school's crits are also walked and run on their own, as normals are; a group of two or more is one more group,
-- its band their normal-scale size, critOnly: Name draws only its crits. A lone crit is no group: one hit that equals
-- a row is too thin to learn a band from (1259101's 48447 did, then drew another spell's crits in shamanele F6).
local function CritOnly(groups, school, crits)
    table.sort(crits)
    local own = Walk(school, crits)
    local made = {}
    for _, group in ipairs(own) do made[#made + 1] = group end
    Ticking(made, own, {})
    for _, group in ipairs(made) do
        group.lo, group.hi = Streams.NormalAmount(group.lo, "CRITICAL"), Streams.NormalAmount(group.hi, "CRITICAL")
        group.floor, group.critCount, group.critOnly = group.lo, group.count, true
        if group.count >= 2 then groups[#groups + 1] = group end
    end
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
            if group then group.sum, group.critCount = group.sum + amount, group.critCount + 1 end
        end
        for _, group in ipairs(walked) do groups[#groups + 1] = group end
        Ticking(groups, walked, bySchool[school].crits)
        bySchool[school].walked = walked
        CritOnly(groups, school, bySchool[school].crits)
    end
    -- A learned DoT's drawn ticks were named by votes, not the meter: one more group per school sums them with its
    -- '?' groups (Wither 445468 learned castless proc 1287663's ticks from the opener's frame, run 20261025T194314Z).
    local drawn, drawnSchools = {}, {}
    for _, tick in ipairs(ticks or {}) do
        local school, amount = tick.school, tick.amount
        if IsNumber(school) and IsNumber(amount) and amount > 0 then
            local extra = drawn[school]
            if not extra then
                extra = { school = school, sum = 0, critCount = 0 }
                drawn[school], drawnSchools[#drawnSchools + 1] = extra, school
                for _, group in ipairs(bySchool[school] and bySchool[school].walked or {}) do
                    extra.sum, extra.critCount = extra.sum + group.sum, extra.critCount + group.critCount
                    extra.lo, extra.hi = math.min(extra.lo or group.lo, group.lo), math.max(extra.hi or group.hi, group.hi)
                end
            end
            extra.sum = extra.sum + amount
            if tick.crit == true then extra.critCount = extra.critCount + 1 end
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
-- A group's plate count (Shares) as a band's own: a plain size group's only.
local function KOf(group) return not (group.rest or group.drawn or group.critOnly) and group.k or nil end
-- A band seen again keeps its plate count only when the group's is the same.
local function SameK(band, group) if band.k ~= KOf(group) then band.k = nil end end
local function Union(entry, group)
    local floor = math.min(Floor(entry), group.floor or group.lo)
    entry.lo, entry.hi = math.min(entry.lo, group.lo), math.max(entry.hi, group.hi)
    SetFloor(entry, floor)
    entry.critSeen = entry.critSeen or group.critCount > 0
    entry.critOnly = entry.critOnly and group.critOnly or nil
end

-- A counted pair for a candidate: one more exact fight, or a restart when the group is another proc's. An off-size
-- group of the same school is first a miss that keeps the streak and band (Malevolence 446285 hit 22498 in four lock2
-- fights, 18748 in F3); a candidate's unpaired counts misses in a row, and the UNPAIRED_MAX-th one restarts it.
local function Grow(entry, group, sure)
    local sameSchool = entry.school == group.school
    if sameSchool and Overlaps(entry, group) then
        Union(entry, group)
        SameK(entry, group)
        entry.streak, entry.unpaired = entry.streak + 1, 0
        if entry.streak < LEARN_STREAK and not sure then return "" end
        entry.learned = true

        return " learned"
    end
    entry.unpaired = entry.unpaired + 1
    if sameSchool and entry.streak > 0 and entry.unpaired < UNPAIRED_MAX and not sure then return " miss" end
    entry.school, entry.lo, entry.hi, entry.streak, entry.unpaired = group.school, group.lo, group.hi, 1, 0
    entry.critSeen, entry.critOnly, entry.k = group.critCount > 0, group.critOnly, KOf(group)
    SetFloor(entry, group.floor or group.lo)
    if sure then
        entry.learned = true

        return " learned"
    end

    return " restart"
end

-- A learned size proc's row paired exactly by a group of its school off its band: one more band of the proc (a split).
-- A proc that splits one hit's damage over the plates it hits lands one size per plate count, each plate's share
-- the same: run priest4, 1291657 hit 62639 on each of 2 plates (learned), 96370 alone and 45774 on each of 4 (rows
-- exactly, '?'); run paladin2, 1276284 learned 7104 alone, then hit 3894 on each of 3 plates (F5-F7, '?').
-- A group whose every normal has a like share in its frame on another plate (group.twin) draws only so (Name).
-- A band the group's padded band meets grows to hold it; a lone sighting keeps it drawing lone, unless `missed`: the
-- shares the draws left of a row they paired under (their twins drew).
local function Split(entry, group, missed)
    local splits = entry.splits or {}
    for _, band in ipairs(splits) do
        if Overlaps(band, group) then
            band.lo, band.hi = math.min(band.lo, group.lo), math.max(band.hi, group.hi)
            band.twin = band.twin and (group.twin or missed == true)
            if not missed then SameK(band, group) end
            return " split"
        end
    end
    if #splits >= SPLITS_MAX then return nil end
    splits[#splits + 1] = { lo = group.lo, hi = group.hi, twin = group.twin == true, k = KOf(group) }
    entry.splits = splits

    return " split"
end

-- Whether one of the entry's splits meets the group's band (Overlaps).
local function SplitMeets(entry, group)
    for _, band in ipairs(entry.splits or {}) do
        if Overlaps(band, group) then return true end
    end

    return false
end

-- The state x event table for one target; returns the log suffix of a change, nil when nothing changed.
-- A crit-only group never widens a proc that has normals: its crits are halved to normal scale on a guess, and widening
-- learned 1310088 (shaman3) with one moved its band off its hits until Unpaired dropped it.
local function Step(entry, group, target, sure)
    local crossed = group ~= nil and group.critOnly and not entry.critOnly
    if target.kind == "under" then
        if not (group and entry.school == group.school) or crossed then return nil end
        if not Widens(entry, group) then
            if entry.critSeen or group.critCount == 0 then return nil end
            entry.critSeen = true

            return " crits"
        end
        -- the shares of a split the draws missed (a split hit's first share has no twin yet) grow that split
        if not Overlaps(entry, group) and SplitMeets(entry, group) then return Split(entry, group, true) end
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
    if not entry.learned then return Grow(entry, group, sure) end
    if crossed or entry.school ~= group.school then return nil end
    if not Overlaps(entry, group) then
        local plain = not (group.rest or group.drawn or group.critOnly)
        return plain and target.overkill == 0 and Split(entry, group) or nil
    end
    local k = entry.k
    SameK(entry, group)
    if not Widens(entry, group) then return k ~= entry.k and " k" or nil end
    Union(entry, group)

    return " widen"
end

-- Apply(target, group): creates a candidate or steps the existing entry; returns the log suffix of a change.
-- A school's remainder that equals an open row exactly (overkill 0) is learned at once: its spell is often cast once
-- a fight (Wither 445468), so waiting LEARN_STREAK fights lost F1-F3 of every warlock run. Inside an overkill window
-- it stays a candidate. A learned rhythm entry is never stepped. A sure pair (its school split whole into exact sums)
-- settles a rhythm candidate's row, since the pair takes the row (taken) and the rhythm pass never sees it: the fight
-- would teach neither (run shaman2: 73921's F1 rhythm candidate blocked its F2 group, which summed to the row exactly,
-- 449019, and the row waited to F3). A group of the candidate's school whose band meets its band is the same proc seen
-- by size: the candidate is learned as a rhythm, which names a hit only in a stream of its period. Run hunter2: Auto
-- Shot 75 (school 32, p 2.62) learned by size in F4 drew four row-less school-32 hits of its size in F5 (8223 x3,
-- 16444 crit; 41113 over) and the safety net dropped it. A group with another band or school replaces the candidate
-- with a size proc. A pair that is not sure leaves a candidate of its school: priest4's Shadow Word: Pain 589 grew a
-- size candidate to learned from three such pairs and drew wrong. One of another school takes the row as if it had no
-- entry (a size candidate): the row's hits summed to it exactly in a school the candidate's ticks are not, so the
-- stream was another spell's. Run hunter2: Black Arrow 466930's school-32 ticks (p 1.0) made row 344572's F1
-- candidate; F4's lone physical 9641 hit was the row exactly, yet the candidate kept the row, learned from the ticks
-- in F5 and drew them.
local function Apply(target, group, sure)
    local entry = procs[target.id]
    local otherSchool = entry ~= nil and group ~= nil and group.school ~= entry.school
    if entry and entry.period and (entry.learned or not (sure or otherSchool)) then return nil end
    if entry and entry.period and entry.school == group.school and Overlaps(entry, group) then
        entry.lo, entry.hi = math.min(entry.lo, group.lo), math.max(entry.hi, group.hi)
        entry.learned, entry.unpaired = true, 0

        return " learned"
    end
    if entry and not entry.period then return Step(entry, group, target, sure) end
    if not group then return nil end
    local learned = (group.rest == true or sure == true) and target.overkill == 0
    procs[target.id] = { school = group.school, lo = group.lo, hi = group.hi, streak = 1, learned = learned, unpaired = 0, seen = 0,
        rest = group.rest, critSeen = group.critCount > 0, critOnly = group.critOnly, k = KOf(group) }
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
            rest = { school = school, sum = 0, count = 0, rest = true, critCount = 0 }
            bySchool[school], schools[#schools + 1] = rest, school
        end
        rest.sum, rest.count = rest.sum + amount, rest.count + 1
        if crit == true then rest.critCount = rest.critCount + 1 end
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

-- The schools whose '?' hits the size pairs split whole: every hit held by a group that pairs an open row with no
-- overkill to the unit, and those groups' sums add up to the school's '?' sum, with no remainder or drawn group
-- among them and no drawn tick of the school. Each such pair is learned at once, as an exact remainder is: one exact
-- sum can be luck, a school split whole into exact sums is not (synthetic Outbreak: Virulent Plague 191587 on 4 plates
-- and Dread Plague 1240996 on the target summed to their rows in F1, yet waited LEARN_STREAK fights).
local function Whole(hits, ticks, matches, targets)
    local taken, covered = {}, {}
    for index, group in pairs(matches) do
        local target = targets[index]
        if target.kind == "open" and target.overkill == 0 and not group.rest and not group.drawn then
            taken[group.school] = taken[group.school] or {}
            table.insert(taken[group.school], group)
            covered[group.school] = (covered[group.school] or 0) + group.sum
        else
            covered[group.school] = false
        end
    end
    for _, tick in ipairs(ticks or {}) do covered[tick.school] = false end
    local sums = {}
    for _, hit in ipairs(hits) do
        local school, amount = hit.school, hit.amount
        if IsNumber(school) and IsNumber(amount) and amount > 0 then
            sums[school] = (sums[school] or 0) + amount
            if not (Plain(hit.crit) and Held(taken, school, amount, hit.crit)) then covered[school] = false end
        end
    end
    local whole = {}
    for school, sum in pairs(covered) do whole[school] = sum ~= false and sums[school] == sum end

    return whole
end

-- The group's shares: for each normal '?' hit it holds, the plates in its frame with a hit like it (TWIN; a crit by its
-- normal-scale size), its own plate included. Returns whether every normal has another (twin: a split hit's shares,
-- Split), and k, that plate count when every normal has the same one (nil when they differ or none is held).
local function Shares(hits, group)
    local function Like(hit, size)
        local other = hit.crit == true and Streams.NormalAmount(hit.amount, "CRITICAL") or hit.amount
        return IsNumber(other) and math.abs(other - size) <= TWIN * size
    end
    local twin, k = true, nil
    for _, hit in ipairs(hits) do
        local amount = hit.amount
        local held = hit.crit == false and hit.school == group.school and IsNumber(amount)
            and (group.floor or group.lo) <= amount and amount <= group.hi
        if held then
            local plates, count = {}, 1
            if hit.at ~= nil and hit.plate ~= nil then plates[hit.plate] = true end
            for _, other in ipairs(hits) do
                if plates[hit.plate] and other.at == hit.at and other.school == hit.school and other.plate ~= nil
                    and not plates[other.plate] and Like(other, amount) then
                    plates[other.plate], count = true, count + 1
                end
            end
            twin = twin and count >= 2
            if k ~= nil and k ~= count then k = false end
            if k == nil then k = count end
        end
    end
    if k == nil then return false, nil end

    return twin, k or nil
end

-- Read: the size pass, the remainder pass, then the rhythm pass when the fight's streams are given.
function Procs.Read(hits, open, results, rows, at, ticks, streams)
    local targets = Targets(open, results, rows, Cast(hits))
    local groups = Groups(hits, ticks)
    local matches = Matches(groups, targets)
    RemainderMatches(hits, ticks, groups, targets, matches, open, results, rows)
    local whole = Whole(hits, ticks, matches, targets)
    local taken = {}
    for index in pairs(matches) do
        if targets[index].kind == "open" then taken[targets[index].id] = true end
    end
    for index, target in ipairs(targets) do
        local group, isNew = matches[index], procs[target.id] == nil
        local sure = group ~= nil and target.kind == "open" and target.overkill == 0 and whole[group.school] == true
        if group then group.twin, group.k = Shares(hits, group) end
        local suffix = Apply(target, group, sure)
        if suffix then
            local entry = procs[target.id]
            entry.seen = at
            if ns.Debug then
                local splits = {}
                for _, band in ipairs(entry.splits or {}) do
                    splits[#splits + 1] = band.lo .. "-" .. band.hi .. (band.twin and "x" or "")
                end
                ns.Debug("TEACH proc %s school=%s band=%s-%s%s%s streak=%s%s", target.id, entry.school, entry.lo,
                    entry.hi, entry.floor and (" floor=" .. entry.floor) or "",
                    #splits > 0 and (" splits=" .. table.concat(splits, ",")) or "", entry.streak, suffix)
            end
            if suffix == " learned" then
                results[target.index] = Agree(target, group.sum)
            end
            if isNew then Evict() end
        end
    end
    if streams then RhythmPass(open, results, rows, at, streams, taken) end
end

-- Procs.Teach(id, school, lo, hi, period, at, fall): the castless pass (Ground.Castless) proved a rhythm on many plates
-- under the open row id, or the DoT pass a learned DoT's second series under its row (Teacher's SecondSeries): learned
-- at once, as an exact rhythm pair is, and drawn by Procs.NameStream. `fall`: the series' steady fall (Streams' Fall),
-- nil for none.
function Procs.Teach(id, school, lo, hi, period, at, fall)
    local plain = IsNumber(id) and IsNumber(school) and IsNumber(lo) and IsNumber(hi) and IsNumber(period)
    if not (plain and lo > 0 and lo <= hi and period > 0) then return end
    procs[id] = { school = school, lo = lo, hi = hi, period = period, streak = RHYTHM_STREAK, learned = true,
        unpaired = 0, seen = IsNumber(at) and at or 0, fall = ValidFall(fall) }
end

-- Name ---------------------------------------------------------------------------------------------------
-- Whether a crit fits the padded band [lo, hi]: its normal-scale size (Streams.NormalAmount) at least lo, the crit at
-- most hi x CRIT_HI. A crit is a full crit factor over its own roll, so one whose roll would sit under the band is no
-- crit of it; above, crit-damage talents stretch past the factor. Run paladin2: 1276284's F1 row was 7104 + a 14207
-- crit exactly, beside three 11.0-11.3K crits not its own; at the old floor (lo x 0.85 x CRIT_LO, 1.53x) it drew
-- 11151-11781 crits of that kind in F2-F7.
local function CritFits(amount, lo, hi)
    local size = Streams.NormalAmount(amount, "CRITICAL")

    return size ~= nil and lo <= size and amount <= hi * CRIT_HI
end

-- Whether a hit may be the entry's crit: CritFits once a crit paired its row; before that, only a crit whose
-- normal-scale size sits in the band itself. Shaman2 F3: 1310088 (learned from two normals, 5101-5310)
-- drew crits 10433 and 9814, its own (with its normals they sum to the meter's 50489), and 11941, which was not
-- (2.25x); now only 10433 draws (9814 / 2 sits under the band: a '?', not a wrong icon).
local function Big(entry, amount, lo, hi)
    local size = Streams.NormalAmount(amount, "CRITICAL")
    if entry.critOnly then return size ~= nil and lo <= size and size <= hi end
    if entry.critSeen ~= false then return CritFits(amount, lo, hi) end

    return size ~= nil and entry.lo <= size and size <= entry.hi
end

-- Whether a hit sits inside the entry's own learned sizes, unpadded: a normal hit by its size (never a crit-only
-- entry's), a crit by its normal-scale size (Streams.NormalAmount). A hit of unknown flag sits in none.
local function Own(entry, amount, crit)
    if crit == nil or (not crit and entry.critOnly) then return false end
    local size = crit and Streams.NormalAmount(amount, "CRITICAL") or amount

    return size ~= nil and entry.lo <= size and size <= entry.hi
end

-- The share size a split proc lands on k plates, from its bands' plate counts (Shares): each hit's damage d spread
-- over k plates with a bonus per plate past the first lands total T(k) = a + b x k, a share of a / k + b. Two bands of
-- distinct k fix a and b; every other band must sit on that line within PREDICT_PAD, else nil (no rule). Run priest4:
-- 1291657 learned 62639 on 2 plates (F3) and 45774 on 4 (F10): a 67460, b 28909, and alone 96369 (F15 hit 96370).
local function Rule(entry)
    local points = {}
    if entry.k then points[1] = { k = entry.k, size = (entry.lo + entry.hi) / 2 } end
    for _, band in ipairs(entry.splits or {}) do
        if band.k then points[#points + 1] = { k = band.k, size = (band.lo + band.hi) / 2 } end
    end
    local first, second
    for _, point in ipairs(points) do
        if not first then first = point elseif not second and point.k ~= first.k then second = point end
    end
    if not second then return nil end
    local a = (first.size - second.size) / (1 / first.k - 1 / second.k)
    local b = first.size - a / first.k
    if a <= 0 then return nil end
    for _, point in ipairs(points) do
        if math.abs(a / point.k + b - point.size) > PREDICT_PAD * point.size then return nil end
    end

    return a, b, points
end

-- Whether the hit fits a share size the entry's rule (Rule) gives for a plate count no band has seen, within
-- PREDICT_PAD: alone (k 1) any hit, on 2..SHARES_MAX plates only one with a twin in its frame. A crit by its
-- normal-scale size.
local function Predicted(entry, amount, crit, twin)
    if not (entry.k or entry.splits) then return false end
    local a, b, points = Rule(entry)
    if not a then return false end
    local size = crit and Streams.NormalAmount(amount, "CRITICAL") or amount
    if size == nil then return false end
    for k = 1, twin and SHARES_MAX or 1 do
        local seen = false
        for _, point in ipairs(points) do seen = seen or point.k == k end
        local share = a / k + b
        if not seen and share > 0 and math.abs(size - share) <= PREDICT_PAD * share then return true end
    end

    return false
end

-- Whether the hit fits the entry's rule (Predicted, its own size then) or a split band (Split) whose padded range holds
-- it, twin bands only for a hit with a twin in its frame (`twin`), and whether that band's own sizes hold it; nil when
-- none does.
local function SplitFits(entry, amount, crit, twin)
    if crit ~= nil and Predicted(entry, amount, crit, twin) then return true, true end
    for _, band in ipairs(entry.splits or {}) do
        if twin or not band.twin then
            local lo, hi = band.lo * PAD_LO, band.hi * PAD_HI
            local normal = lo <= amount and amount <= hi
            local big = entry.critSeen ~= false and CritFits(amount, lo, hi)
            if (crit ~= true and normal) or (crit ~= false and big) then
                local size = crit and Streams.NormalAmount(amount, "CRITICAL") or amount
                return true, crit ~= nil and size ~= nil and band.lo <= size and size <= band.hi
            end
        end
    end

    return nil
end

-- Procs.Name(school, amount, flagText, twin): the one learned proc whose padded range holds the hit, or nil for none.
-- A plain flag picks the normal or the crit range (Big); a nil or secret flag fits either (as Streams.Size).
-- When several padded ranges hold it, the one whose own sizes hold it (Own) names it; none or several: nil. The pads
-- are drift slack, the own sizes are the hits the row paired: run shamanele F6, crit-only 285452 (13017-13460) and
-- 447419 (10571-11342) both held the fixed 22680 crits (11340 a normal, 447419's own top), which stayed '?'.
-- A proc's split bands (SplitFits) are ranges too; `twin`: a like hit of the school landed on another plate in the
-- hit's frame (Core), which a twin band needs.
function Procs.Name(school, amount, flagText, twin)
    if not (IsNumber(school) and IsNumber(amount)) then return nil end
    local crit = Procs.Crit(flagText) -- nil: unknown
    local found, contested, several, owner, owners = nil, false, false, nil, 0
    for id, entry in pairs(procs) do
        if entry.learned == true and not entry.period and entry.school == school then
            local lo, hi, floor = entry.lo * PAD_LO, entry.hi * PAD_HI, Floor(entry) * PAD_LO
            local normal = not entry.critOnly and lo <= amount and amount <= hi
            local big = Big(entry, amount, lo, hi)
            local split, splitOwn = SplitFits(entry, amount, crit, twin)
            if (crit ~= true and normal) or (crit ~= false and big) or split then
                several = several or found ~= nil
                found = found or id
                if Own(entry, amount, crit) or splitOwn then owner, owners = id, owners + 1 end
            end
            -- below the band down to its floor a cut-short tick of this proc may be the hit: no proc names it
            local short = floor <= amount and amount < lo
            local shortBig = floor * CRIT_LO <= amount and amount < lo * CRIT_LO
            if (crit ~= true and short) or (crit ~= false and shortBig) then contested = true end
        end
    end
    if several then
        if owners ~= 1 then return nil end
        found = owner
    end
    -- a normal hit inside a proc's own band (unpadded) is that proc's, cut-short ticks or not
    local own = found and crit == false and (procs[found].lo <= amount and amount <= procs[found].hi
        or select(2, SplitFits(procs[found], amount, crit, twin)))
    if contested and not own then return nil end

    return found
end

-- Whether the entry's padded band holds a hit: the normal range, or the crit range (CritFits); crit nil (unknown)
-- fits either.
local function InBand(entry, amount, crit)
    local lo, hi = entry.lo * PAD_LO, entry.hi * PAD_HI
    local normal = lo <= amount and amount <= hi
    local big = CritFits(amount, lo, hi)

    return (crit ~= true and normal) or (crit ~= false and big)
end

-- Whether a stream's steady fall (Streams' Fall: FALL_TICKS shares in a row) is the entry's learned one, within
-- FALL_SPREAD, with its last hit at most the entry's padded top: a collapse falls out of the band it starts in.
-- Run lock4: Wither 445468's collapse series started at 4523-6031 by its stacks and fell x0.982 a tick to 3222.
local function FallsAs(entry, stream, amount)
    local fall = entry.fall
    if not (fall and stream.fall and (stream.falls or 0) >= Streams.FALL_TICKS) then return false end

    return math.abs(stream.fall - fall) <= Streams.FALL_SPREAD and amount <= entry.hi * PAD_HI
end

-- Procs.NameStream(stream): the one learned rhythm entry whose school and period match the stream and whose
-- padded band holds its last hit, or whose steady fall the stream falls at (FallsAs), or nil for none or several.
-- A positive answer is cached on stream.procID and served only while that entry is still a learned rhythm entry;
-- once it is not, the stream is looked up afresh. stream.procFell: the fall named it, not the band; its first tick
-- sits under the band, where no onset link names a hit (Core passes no onset for it).
function Procs.NameStream(stream)
    if not stream then return nil end
    if stream.procID then
        local cached = Procs.Get(stream.procID)
        if cached and cached.period then return stream.procID end
        stream.procID = nil -- the entry is gone or no longer a rhythm proc: look the stream up afresh
    end
    local school, period, amount = stream.school, stream.period, stream.lastAmount
    if not (IsNumber(school) and IsNumber(period) and IsNumber(amount)) then return nil end
    local found, fell
    for id, entry in pairs(procs) do
        local isRhythm = entry.learned == true and entry.period and entry.school == school
        local inBand = entry.lo * PAD_LO <= amount and amount <= entry.hi * PAD_HI
        if isRhythm and PeriodNear(entry.period, period) and (inBand or FallsAs(entry, stream, amount)) then
            if found then return nil end
            found, fell = id, not inBand
        end
    end
    stream.procID, stream.procFell = found, found and fell or nil

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
                if InBand(entry, amount, crit) then
                    if found then return nil end
                    found = id
                end
            end
            id, nextID = nextID, nil
        end
    end

    return found
end

-- Procs.NamePair(loose, school, amount, flagText, now): the one learned rhythm entry of the school whose padded band
-- holds the hit and one loose hit of the plate (Streams.Loose, oldest first) one period before it, within the stream
-- slack, the band's only hit since, and that hit's time (the onset links learn from it); nil for none or several.
-- Names a known rhythm's ticks from its second on, where a
-- stream is born only on the fourth: run lock3 F2, Darkglare 205231's first beams (199520.955, 199522.823,
-- 199524.681, 8.5-10.3K, 1.77 s) hit 5 plates each and went by as '?' until the stream at 199526.558. The band is
-- the size test: the two ticks need not be within SIZE_GUARD of each other. Run lock4 F3: Darkglare's 12322 then
-- 9656 on nameplate8 1.64 s apart (21.6 % apart, its beam grows with the target's DoTs) stayed '?' (lock4 right
-- 33.3 % -> 33.7 %, wrong unchanged).
-- Never physical: melee swings and GCD-paced strikes pair one period apart (old druid F10/F12, 3576-24815).
function Procs.NamePair(loose, school, amount, flagText, now)
    local crit = Procs.Crit(flagText)
    if not (IsNumber(school) and IsNumber(amount) and IsNumber(now)) or crit == nil or school == 1 then return nil end
    local found, foundAt
    for id, entry in pairs(procs) do
        if entry.learned == true and entry.period and entry.school == school and InBand(entry, amount, crit) then
            local slack = Streams.Slack(entry.period)
            local inBand, partnerAt = 0, nil
            for _, hit in ipairs(loose or {}) do
                local gap = now - hit.at
                if gap > 0 and gap <= entry.period + slack and hit.amount and InBand(entry, hit.amount, hit.crit) then
                    inBand = inBand + 1
                    if gap >= entry.period - slack then partnerAt = partnerAt or hit.at end
                end
            end
            -- a crowd's in-band hits come denser than one a period
            if partnerAt and inBand == 1 then
                if found then return nil end
                found, foundAt = id, partnerAt
            end
        end
    end

    return found, foundAt
end

-- The normal loose hit (Streams.Loose) one or two of `period`s before `at`, within the stream slack, whose share per
-- period to `size` is `fall` within Streams.FALL_SPREAD, else nil; the newest such hit wins (a tick one period back
-- before a tick two back, which would skip it).
local function FallPartner(loose, period, fall, at, size)
    local slack = Streams.Slack(period)
    for index = #loose, 1, -1 do
        local hit = loose[index]
        local gap = at - hit.at
        for multiple = 1, 2 do
            local fits = gap > 0 and math.abs(gap - multiple * period) <= slack and not hit.crit and hit.amount
                and hit.amount > 0 and math.abs((size / hit.amount) ^ (1 / multiple) - fall) <= Streams.FALL_SPREAD
            if fits then return hit end
        end
    end

    return nil
end

-- Procs.NameFall(loose, school, amount, flagText, now): the one learned rhythm entry of the school with a steady fall
-- (Procs.Teach) that a normal hit at most its padded top ends: the hit and Streams.FALL_TICKS loose hits of the plate
-- (oldest first) before it, each one period (or two) after the last, each falling by the entry's share per period;
-- nil for none or several. Names a collapse's ticks from its third, where its stream is born only on the fourth, or
-- later when a tick lands off its beat: run lock4 F5, Wither 445468's 3475 -> 3410 -> 3347 -> 3283 came 1.02, 0.90 and
-- 1.09 s apart (x0.981 each), and no stream was born before 3222.
function Procs.NameFall(loose, school, amount, flagText, now)
    local crit = Procs.Crit(flagText)
    if not (IsNumber(school) and IsNumber(amount) and IsNumber(now)) or crit ~= false or amount <= 0 then return nil end
    local found
    for id, entry in pairs(procs) do
        local fits = entry.learned == true and entry.period and entry.fall and entry.school == school
            and amount <= entry.hi * PAD_HI
        local at, size, ticks = now, amount, 0
        while fits and ticks < Streams.FALL_TICKS do
            local partner = FallPartner(loose or {}, entry.period, entry.fall, at, size)
            if not partner then break end
            at, size, ticks = partner.at, partner.amount, ticks + 1
        end
        if fits and ticks >= Streams.FALL_TICKS then
            if found then return nil end
            found = id
        end
    end

    return found
end

-- Onset links ----------------------------------------------------------------------------------------
-- A burst's first tick has no tick a period before it (NamePair) and no stream yet, so it drew '?': Surging Totem
-- 73921's first pulse on 5 plates 1.68-1.79 s after each cast of 444995 (shamanresto F2, F4), Darkglare 205231's
-- first beams 1.83-1.91 s after each Summon Darkglare 205180 (lock4 F3, F7, F13). A cast that led every burst of a
-- learned rhythm by one delay is the burst's onset: its link names an in-band hit at that delay (NameOnset). Learned
-- by watching (Drew): at each burst's start, the casts ONSET_SPAN before its first tick; a link survives only while
-- every burst finds its cast at its delay again, and a cast with no burst after it in that window drops its link
-- (Malevolence 442726 came 0.43-0.48 s before each Darkglare onset, yet was cast 11 times to Darkglare's 6).
-- entry.onset = { [castID] = { lo, hi, n } }: the delays seen and the bursts it led.
local ONSET_SPAN = 2.5  -- seconds a cast may lead its rhythm's first tick
local ONSET_SLACK = 0.15 -- seconds a delay may stray from a link's learned delays
local ONSET_SURE = 2    -- bursts a link must lead before it names a hit
local BURST_GAP = 3     -- periods with no draw that end a rhythm's burst
local CAST_KEEP = 12    -- seconds a cast is kept for the links (a burst may start being drawn a stream later)

-- recent = { { id, at }, ... } this session's casts, oldest first; lastDrawn[id] = the rhythm's last draw;
-- pending = { { id, cast, at }, ... } casts of a link whose burst has not shown yet.
local recent, lastDrawn, pending = {}, {}, {}

local function Link(id, castID)
    local entry = procs[id]

    return entry and entry.learned == true and entry.period and entry.onset and entry.onset[castID], entry
end

-- A pending lead whose window closed with no burst of its rhythm: the cast leads it no more. The window runs to the
-- stream's birth (the fourth tick) and a period more, the latest a burst's first draw comes.
local function Expire(now)
    local kept = {}
    for _, lead in ipairs(pending) do
        local link, entry = Link(lead.id, lead.cast)
        if link and now - lead.at <= link.hi + ONSET_SLACK + (BURST_GAP + 1) * entry.period then
            kept[#kept + 1] = lead
        elseif link then
            entry.onset[lead.cast] = nil
            if next(entry.onset) == nil then entry.onset = nil end
        end
    end
    pending = kept
end

-- Procs.NoteCast(castID, now): a cast of the player or the pet, harmful or not (a totem's is not).
function Procs.NoteCast(castID, now)
    if not (IsNumber(castID) and IsNumber(now)) then return end
    Expire(now)
    local kept = {}
    for _, cast in ipairs(recent) do
        if now - cast.at <= CAST_KEEP then kept[#kept + 1] = cast end
    end
    kept[#kept + 1] = { id = castID, at = now }
    recent = kept
    for id in pairs(procs) do
        if Link(id, castID) then pending[#pending + 1] = { id = id, cast = castID, at = now } end
    end
end

-- The casts ONSET_SPAN before `onsetAt`: castID -> its delay (the nearest cast of an ID).
local function Leads(onsetAt)
    local delays = {}
    for _, cast in ipairs(recent) do
        local delay = onsetAt - cast.at
        if delay >= 0 and delay <= ONSET_SPAN then delays[cast.id] = delay end
    end

    return delays
end

-- A burst's first tick at `onsetAt`: each cast that leads it counts one more burst for its link at that delay (a
-- link at another delay starts over), a new one starts a link. A burst no cast leads changes no link: a rhythm whose
-- targets ran out of reach resumes with no cast (shamanresto F3: 73921 at 265011.190).
local function Learn(entry, onsetAt)
    for castID, delay in pairs(Leads(onsetAt)) do
        entry.onset = entry.onset or {}
        local link = entry.onset[castID]
        if link and delay >= link.lo - ONSET_SLACK and delay <= link.hi + ONSET_SLACK then
            link.lo, link.hi, link.n = math.min(link.lo, delay), math.max(link.hi, delay), link.n + 1
        else
            entry.onset[castID] = { lo = delay, hi = delay, n = 1 }
        end
    end
end

-- Procs.Drew(id, now, onsetAt): the rhythm `id` drew a hit at `now`. A draw BURST_GAP periods past its last starts a
-- burst: its pending leads are met, and `onsetAt` (its first tick: the stream's birth, the pair's partner) teaches
-- the links; nil (a hit its link named) teaches none.
function Procs.Drew(id, now, onsetAt)
    local entry = Procs.Get(id)
    if not (entry and entry.period and IsNumber(now)) then return end
    local last = lastDrawn[id]
    lastDrawn[id] = now
    if last and now - last <= BURST_GAP * entry.period then return end
    local first = IsNumber(onsetAt) and onsetAt or now
    local kept = {}
    for _, lead in ipairs(pending) do
        local link = lead.id == id and Link(id, lead.cast)
        local delay = first - lead.at
        local met = link and delay >= link.lo - ONSET_SLACK and delay <= link.hi + ONSET_SLACK
        if not met then kept[#kept + 1] = lead end
    end
    pending = kept
    if not IsNumber(onsetAt) then return end
    Learn(entry, onsetAt)
    if ns.Debug then
        local links = {}
        for castID, link in pairs(entry.onset or {}) do
            links[#links + 1] = string.format("%s@%.2f-%.2fx%d", castID, link.lo, link.hi, link.n)
        end
        table.sort(links)
        ns.Debug("TEACH onset %s at %.3f links=%s", id, onsetAt, table.concat(links, " "))
    end
end

-- Procs.NameOnset(school, amount, flagText, now): the one learned rhythm entry of the school whose padded band holds
-- the hit and one of whose sure links (ONSET_SURE bursts) has its cast at its delay before `now`; nil for none or
-- several.
function Procs.NameOnset(school, amount, flagText, now)
    if not (IsNumber(school) and IsNumber(amount) and IsNumber(now)) then return nil end
    Expire(now)
    local crit = Procs.Crit(flagText)
    local found
    for id, entry in pairs(procs) do
        if entry.learned == true and entry.period and entry.onset and entry.school == school and InBand(entry, amount, crit) then
            local led = false
            for _, cast in ipairs(recent) do
                local link, delay = entry.onset[cast.id], now - cast.at
                if link and link.n >= ONSET_SURE and delay >= link.lo - ONSET_SLACK and delay <= link.hi + ONSET_SLACK then
                    led = true
                end
            end
            if led then
                if found then return nil end
                found = id
            end
        end
    end

    return found
end
