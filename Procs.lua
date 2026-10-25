-- Procs: castless procs (trinket and talent damage that no cast or tick rhythm explains).
--
-- Two entry points. Read learns a proc from exact size-group sums of the '?' hits against the
-- meter rows after a fight; Name draws a learned proc at hit time. The store is per character
-- (charDB.procs), checked on load and never trusted. No spell or class tables: every proc is learned.

local _, ns = ...
local Streams = ns.Streams

local Procs = {}
ns.Procs = Procs

local LEARN_STREAK = 3 -- exact fights in a row before a candidate is learned
local CAP = 64         -- unlearned candidates kept
local UNPAIRED_MAX = 2 -- unpaired reads in a row drop a learned proc
local SIZE_GUARD, CRIT_LO, CRIT_HI = Streams.SIZE_GUARD, Streams.CRIT_LO, Streams.CRIT_HI
local PAD_LO, PAD_HI = 0.85, 1.15 -- draw pads; two bands are also the same proc's when each, shrunk by PAD_LO, reaches the other

Procs.LEARN_STREAK = LEARN_STREAK

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

local procs = {} -- [spellID] = { school, lo, hi, streak, learned, unpaired, seen }; the saved table itself

local function Count(value) return IsNumber(value) and value >= 0 and value == math.floor(value) and value or 0 end

local function Valid(id, entry)
    if not IsNumber(id) or not Plain(entry) or type(entry) ~= "table" then return false end
    local school, lo, hi = entry.school, entry.lo, entry.hi
    if not (IsNumber(school) and IsNumber(lo) and IsNumber(hi)) then return false end

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

-- Procs.Has(id): whether the store tracks id: a learned proc, or a candidate with a streak (a streak-0
-- candidate has just failed an exact fight and owns nothing yet; spec 3.1 Rev 4b).
function Procs.Has(id)
    if not IsNumber(id) then return false end
    local entry = procs[id]

    return entry ~= nil and (entry.learned or entry.streak > 0)
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
        list[#list + 1] = { spellID = id, school = entry.school, lo = entry.lo, hi = entry.hi, streak = entry.streak, learned = entry.learned }
    end
    table.sort(list, function(a, b) return a.spellID < b.spellID end)

    return list
end

function Procs.Forget()
    for id in pairs(procs) do procs[id] = nil end
end

-- Read ---------------------------------------------------------------------------------------------
-- Procs.Read(hits, open, results, rows, at): the post-fight learner (spec 3.1). The '?' hits are split into
-- size groups; a group's exact sum is matched against the unpaired meter rows (open) and the complement of
-- learned procs that came out 'under'. A pair counts only when it is unique both ways.

-- A spell Learn or Fingerprints knows has one owner, and so has a row whose saved alias names a learned fingerprint.
local function Owned(id)
    return ns.Learn.Get(id) or ns.Fingerprints.IsLearned(id) or ns.Fingerprints.IsLearned(ns.Fingerprints.Alias(id))
end

-- The windows a group's sum can fill: every unowned open row, then the complement of every learned 'under' row.
local function Targets(open, results, rows)
    local targets = {}
    for _, item in ipairs(open) do
        local row = item.row
        local id, overkill = row.spellID, row.overkill or 0
        if IsNumber(id) and not Owned(id) then
            targets[#targets + 1] = { id = id, kind = "open", lo = row.total, hi = row.total + overkill, index = item.index, total = row.total, overkill = overkill }
        end
    end
    for index = 1, #rows do
        local row, result = rows[index], results[index]
        local id = row.spellID
        local isUnder = result and result.verdict == "under" and IsNumber(result.tally) and result.tally > 0
        if isUnder and IsNumber(id) and result.spellID == id and Procs.Get(id) and not Owned(id) then
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
            current.hi, current.sum = amount, current.sum + amount
        else
            current = { school = school, lo = amount, hi = amount, sum = amount }
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

-- Groups per school ascending. A crit adds to the one group it fits; a hit whose crit flag is not plain
-- true or false is an orphan, like a crit that fits none or two. A hit of 0 or less joins no group.
local function Groups(hits)
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
    end

    return groups
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

local function Overlaps(entry, group) return entry.lo * PAD_LO <= group.hi and group.lo * PAD_LO <= entry.hi end
local function Widens(entry, group) return group.lo < entry.lo or group.hi > entry.hi end
local function Union(entry, group) entry.lo, entry.hi = math.min(entry.lo, group.lo), math.max(entry.hi, group.hi) end

-- A counted pair for a candidate: one more exact fight, or a restart when the group is another proc's.
local function Grow(entry, group)
    if entry.school ~= group.school or not Overlaps(entry, group) then
        entry.school, entry.lo, entry.hi, entry.streak = group.school, group.lo, group.hi, 1

        return " restart"
    end
    Union(entry, group)
    entry.streak = entry.streak + 1
    if entry.streak < LEARN_STREAK then return "" end
    entry.learned, entry.unpaired = true, 0

    return " learned"
end

-- The state x event table for one target; returns the log suffix of a change, nil when nothing changed.
local function Step(entry, group, target)
    if target.kind == "under" then
        if not (group and entry.school == group.school and Widens(entry, group)) then return nil end
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
local function Apply(target, group)
    local entry = procs[target.id]
    if entry then return Step(entry, group, target) end
    if not group then return nil end
    procs[target.id] = { school = group.school, lo = group.lo, hi = group.hi, streak = 1, learned = false, unpaired = 0, seen = 0 }

    return ""
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

function Procs.Read(hits, open, results, rows, at)
    local targets = Targets(open, results, rows)
    local groups = Groups(hits)
    local matches = Matches(groups, targets)
    for index, target in ipairs(targets) do
        local group, isNew = matches[index], procs[target.id] == nil
        local suffix = Apply(target, group)
        if suffix then
            local entry = procs[target.id]
            entry.seen = at
            if ns.Debug then ns.Debug("TEACH proc %s school=%s band=%s-%s streak=%s%s", target.id, entry.school, entry.lo, entry.hi, entry.streak, suffix) end
            if suffix == " learned" then
                results[target.index] = { spellID = target.id, meterID = target.id, tally = group.sum, meter = target.total, verdict = "agree" }
            end
            if isNew then Evict() end
        end
    end
end

-- Name ---------------------------------------------------------------------------------------------------
-- Procs.Name(school, amount, flagText): the one learned proc whose padded range holds the hit, or nil for none
-- or several. A plain flag picks the normal or the crit range; a nil or secret flag fits either (as Streams.Size).
function Procs.Name(school, amount, flagText)
    if not (IsNumber(school) and IsNumber(amount)) then return nil end
    local crit = Procs.Crit(flagText) -- nil: unknown
    local found
    for id, entry in pairs(procs) do
        if entry.learned == true and entry.school == school then
            local lo, hi = entry.lo * PAD_LO, entry.hi * PAD_HI
            local normal = lo <= amount and amount <= hi
            local big = lo * CRIT_LO <= amount and amount <= hi * CRIT_HI
            if (crit ~= true and normal) or (crit ~= false and big) then
                if found then return nil end
                found = id
            end
        end
    end

    return found
end
