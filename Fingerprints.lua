-- Combat Text Icons: fingerprints. The per-spec store of what the addon
-- learned about each of your direct-hit spells: its school, how long after the
-- cast its hit lands (a ring of recent delays), and whether it hits once or
-- hops from plate to plate (chain). A spell is learned when 3 different casts
-- sharing a school each left a sample, or when 1 cast left `exact` samples (the
-- teacher summed its hits to the meter row of its own ID; the school's other samples
-- then go); after that its school is fixed and the
-- post-fight teacher (Teacher.lua) only counts fights it agreed with or
-- overshot. Two overshoots in a row delete the entry. Samples keep the hit's normal-scale
-- size (crits divided by CRIT_FACTOR); a claim needs a hit inside the padded band (Casts.lua).
-- `castAliases` maps a meter row ID to the cast ID (Auto Shot 75 -> Shoot 5019); `aliasFills` marks the row IDs
-- whose alias a filled sum set (Steady's OtherRow): their cast draws its crits in the near sizes only (Casts.Claim).
-- A ground spell's samples
-- (Ground.lua) carry `tick`: 0 for its first tick, whose delays alone give the window, k for its kth tick after that;
-- they make the pattern "ground" with a `period` and `ticks` (Casts.lua walks them); a first tick's sample may carry
-- `crit`, its walk's crits' size over its normal ticks' (the median is the entry's `crit`). A stack spell's samples
-- (Stack.lua) carry its `period` and a stack's `life` (tick 0: a cast that started a series, whose delays give the
-- window; tick 1: the others); they make the pattern "stack" with the medians.
-- A meter-proven way may teach `perCast` (hits one cast lands on its plate, SetPerCast) and the area pass `area` (its
-- casts also hit the plates around their target, SetArea, Area.lua), with `areaLow` when only the hits from
-- Casts.AREA_LO of its smallest showed it; Casts.lua reads them.
-- Saved data is checked on load and never trusted.

local _, ns = ...

local Fingerprints = {}
ns.Fingerprints = Fingerprints

local CAP = 64        -- entries kept; the least useful one goes first
local SAMPLES = 16    -- samples kept per entry, oldest dropped (one steady fight can add 11: Void Blast + Mind Blast)
local DELAYS = 8      -- delays kept per learned entry, oldest dropped
local LEARN_CASTS = 3 -- samples from this many different casts, one school, teach a spell
-- ... or `exact` samples from this many casts: the teacher paired their hits with the meter row of the cast's own ID.
-- Run druid2: Ravage 441591 is cast once a fight; its hits summed to its own row in F5 and F7 and it never learned.
local EXACT_CASTS = 1
local STRIKES = 2     -- teacher overshoots in a row that delete an entry
local PER_CAST_MAX = 4 -- own-plate hits one cast's record takes at most (SetPerCast)
local PATTERNS = { single = true, chain = true, ground = true, stack = true } -- the patterns a saved entry may hold

Fingerprints.LEARN_CASTS = LEARN_CASTS -- the panel shows "casts n of LEARN_CASTS"

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end
local function HitSize(value) return IsNumber(value) and value > 0 and value or nil end -- a plain size above 0, else nil
-- a ground tick index (a whole number from 0), else nil
local function Tick(value) return IsNumber(value) and value >= 0 and value % 1 == 0 and value or nil end
local function Positive(value) return IsNumber(value) and value > 0 and value or nil end -- a plain number above 0

-- The in-memory tables are the saved ones once Init ran.
local casts, aliases, fills = {}, {}, {}

-- Whether `sample` is a ground spell's later tick, whose delay is no window delay.
local function LaterTick(sample) return sample.tick ~= nil and sample.tick > 0 end

local function Median(list)
    table.sort(list)

    return list[math.ceil(#list / 2)]
end

-- A ground entry's period and ticks from its samples: per cast, (a later tick's delay - its first tick's) / tick, and
-- that tick + 1; the medians. nil when no cast kept both.
local function Ground(entry)
    local firsts, periods, counts = {}, {}, {}
    for _, sample in ipairs(entry.samples) do
        if sample.tick == 0 then firsts[sample.castAt] = sample.delay end
    end
    for _, sample in ipairs(entry.samples) do
        local first = firsts[sample.castAt]
        if LaterTick(sample) and first then
            periods[#periods + 1] = (sample.delay - first) / sample.tick
            counts[#counts + 1] = sample.tick + 1
        end
    end
    if #periods == 0 then return nil end

    return Median(periods), Median(counts)
end

-- Recomputes delayLo / delayHi from `delays`, and `pattern` (with a ground entry's `period` and `ticks`) from the
-- kept samples.
local function Refresh(entry)
    local low, high
    for _, delay in ipairs(entry.delays) do
        if not low or delay < low then low = delay end
        if not high or delay > high then high = delay end
    end
    entry.delayLo, entry.delayHi = low, high
    entry.pattern = "single"
    for _, sample in ipairs(entry.samples) do
        if sample.hops >= 2 then entry.pattern = "chain" end
    end
    entry.period, entry.ticks = Ground(entry)
    if entry.period and entry.period > 0 then entry.pattern = "ground" end
    local crits = {}
    for _, sample in ipairs(entry.samples) do
        if sample.crit then crits[#crits + 1] = sample.crit end
    end
    entry.crit = #crits > 0 and Median(crits) or nil
    local periods, lives = {}, {}
    for _, sample in ipairs(entry.samples) do
        if sample.period and sample.life then
            periods[#periods + 1], lives[#lives + 1] = sample.period, sample.life
        end
    end
    if #lives > 0 then
        entry.pattern, entry.period, entry.life = "stack", Median(periods), Median(lives)
    else
        entry.life = nil
    end
end

-- Whether `entry` goes before `other` when the table is full: unlearned before learned, then
-- fewest fights (learned only), then oldest lastSeen.
local function GoesFirst(entry, other)
    if entry.learned ~= other.learned then return not entry.learned end
    if entry.learned and entry.fights ~= other.fights then return entry.fights < other.fights end

    return entry.lastSeen < other.lastSeen
end

local function EvictOne()
    local victimID, victim
    for spellID, entry in pairs(casts) do
        if not victim or GoesFirst(entry, victim) then victimID, victim = spellID, entry end
    end
    if victim then casts[victimID] = nil end
end

local function Size()
    local count = 0
    for _ in pairs(casts) do count = count + 1 end

    return count
end

local function NewEntry()
    return { learned = false, pattern = "single", delays = {}, samples = {}, fights = 0, over = 0, strikes = 0,
        lastSeen = 0 }
end

-- How `school` is learned among the kept samples: "casts" with samples from LEARN_CASTS different casts, else "exact"
-- with exact samples from EXACT_CASTS different casts, else nil.
local function SchoolLearned(entry, school)
    local seen, seenExact, distinct, exact = {}, {}, 0, 0
    for _, sample in ipairs(entry.samples) do
        if sample.school == school and not seen[sample.castAt] then
            seen[sample.castAt] = true
            distinct = distinct + 1
        end
        if sample.school == school and sample.exact and not seenExact[sample.castAt] then
            seenExact[sample.castAt] = true
            exact = exact + 1
        end
    end
    if distinct >= LEARN_CASTS then return "casts" end
    if exact >= EXACT_CASTS then return "exact" end

    return nil
end

-- An "exact" learn keeps only the school's exact samples: the others reached no LEARN_CASTS, so they prove nothing,
-- and they would widen the window and the band. Run druid2: Ravage 441591's run-5 `all` way (every hit in its cast's
-- windows, 2270 to 45028) left samples, its run-7 exact hit (57184) taught it, and with those samples kept it drew
-- three 3.7K-10.6K hits 0.4-0.8 s after its run-9 cast, 4404 past its row.
local function MarkLearned(entry, school, how)
    entry.learned, entry.school = true, school
    if how == "exact" then
        local kept = {}
        for _, sample in ipairs(entry.samples) do
            if sample.school ~= school or sample.exact then kept[#kept + 1] = sample end
        end
        entry.samples = kept
    end
    entry.delays = {}
    for _, sample in ipairs(entry.samples) do
        if sample.school == school and not LaterTick(sample) then entry.delays[#entry.delays + 1] = sample.delay end
    end
end

-- One sample of a hit that a cast `delay` seconds earlier explains. Anything not plain is ignored.
function Fingerprints.Add(spellID, sample)
    if not IsNumber(spellID) or type(sample) ~= "table" then return end
    local school, delay, castAt = sample.school, sample.delay, sample.castAt
    local plainSample = IsNumber(school) and IsNumber(delay) and IsNumber(castAt)
    if not plainSample then return end
    local entry = casts[spellID]
    if not entry and Size() >= CAP then EvictOne() end
    if not entry then
        entry = NewEntry()
        casts[spellID] = entry
    end
    if entry.learned and school ~= entry.school then return end
    local hops = IsNumber(sample.hops) and sample.hops or 1
    local spell = IsNumber(sample.spell) and sample.spell or nil
    local kept = { school = school, delay = delay, castAt = castAt, hops = hops, spell = spell,
        size = HitSize(sample.size), tick = Tick(sample.tick), period = Positive(sample.period),
        life = Positive(sample.life), crit = Positive(sample.crit), exact = sample.exact == true or nil }
    entry.samples[#entry.samples + 1] = kept
    if #entry.samples > SAMPLES then table.remove(entry.samples, 1) end
    entry.lastSeen = castAt
    if entry.learned and LaterTick(kept) then
        Refresh(entry)
        return
    end
    if entry.learned then
        entry.delays[#entry.delays + 1] = delay
        if #entry.delays > DELAYS then table.remove(entry.delays, 1) end
    else
        local how = SchoolLearned(entry, school)
        if how then MarkLearned(entry, school, how) end
    end
    Refresh(entry)
end

function Fingerprints.Get(spellID)
    if not IsNumber(spellID) then return nil end

    return casts[spellID]
end

function Fingerprints.IsLearned(spellID)
    local entry = Fingerprints.Get(spellID)

    return entry ~= nil and entry.learned
end

-- The delay window (low, high) of a learned entry for a hit of `castSpell`. Casts of one base can
-- land apart (Void Blast 450983 in its cast frame, Mind Blast 8092 ~0.17 s later), so the kept
-- samples of that cast spell give its window; with none (saved before samples kept the spell, or a
-- cast never seen while learning) the whole entry's window answers. nil when not learned.
function Fingerprints.Window(spellID, castSpell)
    local entry = Fingerprints.Get(spellID)
    if not (entry and entry.learned) then return nil end
    local low, high
    for _, sample in ipairs(entry.samples) do
        if sample.spell == castSpell and sample.school == entry.school and not LaterTick(sample) then
            if not low or sample.delay < low then low = sample.delay end
            if not high or sample.delay > high then high = sample.delay end
        end
    end
    if not low then return entry.delayLo, entry.delayHi end

    return low, high
end

-- The size band (low, high) of a learned entry for a hit of `castSpell`: the smallest and biggest
-- size among its kept sized samples of that cast spell, else among all its sized samples (as
-- Window). nil when not learned or when no kept sample has a size (saved before sizes were kept).
function Fingerprints.Band(spellID, castSpell)
    local entry = Fingerprints.Get(spellID)
    if not (entry and entry.learned) then return nil end
    for _, ofSpell in ipairs({ true, false }) do
        local low, high
        for _, sample in ipairs(entry.samples) do
            if sample.size and sample.school == entry.school and (sample.spell == castSpell or not ofSpell) then
                if not low or sample.size < low then low = sample.size end
                if not high or sample.size > high then high = sample.size end
            end
        end
        if low then return low, high end
    end
end

-- The most distinct casts that left a kept sample in any one school: the count SchoolLearned tests.
local function BestCasts(entry)
    local perSchool, best = {}, 0
    for _, sample in ipairs(entry.samples) do
        local seen = perSchool[sample.school] or {}
        perSchool[sample.school] = seen
        seen[sample.castAt] = true
        local distinct = 0
        for _ in pairs(seen) do distinct = distinct + 1 end
        if distinct > best then best = distinct end
    end

    return best
end

-- Every entry as a read-only copy sorted by spell id; an unlearned entry has no school.
function Fingerprints.List()
    local list = {}
    for spellID, entry in pairs(casts) do
        list[#list + 1] = { spellID = spellID, learned = entry.learned, pattern = entry.pattern, school = entry.school,
            casts = BestCasts(entry), fights = entry.fights, strikes = entry.strikes }
    end
    table.sort(list, function(a, b) return a.spellID < b.spellID end)

    return list
end

-- The teacher saw this spell's drawn total agree with the meter in one fight.
function Fingerprints.Agree(spellID)
    local entry = Fingerprints.Get(spellID)
    if not entry then return end
    entry.fights = entry.fights + 1
    entry.strikes = 0
end

-- The teacher saw more drawn than the meter holds; STRIKES in a row delete the entry.
function Fingerprints.Over(spellID)
    local entry = Fingerprints.Get(spellID)
    if not entry then return end
    entry.over = entry.over + 1
    entry.strikes = entry.strikes + 1
    if entry.strikes >= STRIKES then casts[spellID] = nil end
end

-- A way the meter proved (Teacher's exact sums) held `count` hits of one cast on its plate: the entry's records take
-- that many from now on (Casts.lua), the most any proof showed, at most PER_CAST_MAX. Lightning Bolt 188196's row holds
-- the bolt and its Elemental Overloads on the bolt's plate (ele log F3: 63230 + 28817 + 64483 + 26106 + 25821 = 208457).
function Fingerprints.SetPerCast(spellID, count)
    local entry = Fingerprints.Get(spellID)
    if not (entry and IsNumber(count) and count >= 2) then return end
    entry.perCast = math.min(PER_CAST_MAX, math.max(entry.perCast or 1, math.floor(count)))
end

-- The meter showed a cast's row holding its hits on the plates around its target (Area.lua): its records take them.
-- `low`: the hits from Casts.AREA_LO of its smallest showed it, so its records take such hits from there (Casts.Claim).
function Fingerprints.SetArea(spellID, low)
    local entry = Fingerprints.Get(spellID)
    if entry then entry.area, entry.areaLow = true, low == true or nil end
end

-- `filled`: the alias rests on a filled sum (Steady's CastSum), so Filled answers for its cast; an alias set again
-- without it drops the mark.
function Fingerprints.SetAlias(meterID, castID, filled)
    if not (IsNumber(meterID) and IsNumber(castID)) then return end
    aliases[meterID], fills[meterID] = castID, filled == true or nil
end

function Fingerprints.Alias(meterID)
    if not IsNumber(meterID) then return nil end

    return aliases[meterID]
end

function Fingerprints.IsAliasTarget(castID)
    for _, target in pairs(aliases) do
        if target == castID then return true end
    end

    return false
end

-- Whether a row aliased to `castID` got its alias from a filled sum (SetAlias).
function Fingerprints.Filled(castID)
    for meterID in pairs(fills) do
        if aliases[meterID] == castID then return true end
    end

    return false
end

function Fingerprints.Forget()
    for spellID in pairs(casts) do casts[spellID] = nil end
    for meterID in pairs(aliases) do aliases[meterID] = nil end
    for meterID in pairs(fills) do fills[meterID] = nil end
end

local function CountOrZero(value) return type(value) == "number" and value or 0 end

-- Keeps the number items of `list` (capped to the newest `limit`), in place.
local function KeepNumbers(list, limit)
    local kept = {}
    for _, value in ipairs(list) do
        if type(value) == "number" then kept[#kept + 1] = value end
    end
    while #kept > limit do table.remove(kept, 1) end

    return kept
end

local function ValidSample(sample)
    if type(sample) ~= "table" then return false end

    return type(sample.school) == "number" and type(sample.delay) == "number" and type(sample.castAt) == "number"
end

local function KeepSamples(list)
    local kept = {}
    for _, sample in ipairs(list) do
        if ValidSample(sample) then
            local hops = type(sample.hops) == "number" and sample.hops or 1
            local spell = type(sample.spell) == "number" and sample.spell or nil
            local size = type(sample.size) == "number" and sample.size > 0 and sample.size or nil
            kept[#kept + 1] = { school = sample.school, delay = sample.delay, castAt = sample.castAt, hops = hops,
                spell = spell, size = size, tick = Tick(sample.tick), period = Positive(sample.period),
                life = Positive(sample.life), crit = Positive(sample.crit), exact = sample.exact == true or nil }
        end
    end
    while #kept > SAMPLES do table.remove(kept, 1) end

    return kept
end

-- Whether a saved entry can be kept: a learned one needs a school and delays, any needs a known pattern.
local function ValidEntry(entry)
    if type(entry) ~= "table" or type(entry.learned) ~= "boolean" then return false end
    if not PATTERNS[entry.pattern] then return false end
    if not entry.learned then return true end
    local hasDelays = type(entry.delays) == "table" and #KeepNumbers(entry.delays, DELAYS) > 0

    return type(entry.school) == "number" and hasDelays
end

-- Repairs a kept entry in place: lists cleaned, counters numbers, range and pattern recomputed.
local function Repair(entry)
    entry.delays = KeepNumbers(type(entry.delays) == "table" and entry.delays or {}, DELAYS)
    entry.samples = KeepSamples(type(entry.samples) == "table" and entry.samples or {})
    entry.fights, entry.over = CountOrZero(entry.fights), CountOrZero(entry.over)
    entry.strikes, entry.lastSeen = CountOrZero(entry.strikes), CountOrZero(entry.lastSeen)
    local perCast = entry.perCast
    entry.perCast = type(perCast) == "number" and perCast >= 2 and perCast <= PER_CAST_MAX and perCast % 1 == 0
        and perCast or nil
    entry.area = entry.area == true or nil
    entry.areaLow = entry.area and entry.areaLow == true or nil
    Refresh(entry)
end

function Fingerprints.Init(charDB)
    if type(charDB.casts) ~= "table" then charDB.casts = {} end
    if type(charDB.castAliases) ~= "table" then charDB.castAliases = {} end
    if type(charDB.aliasFills) ~= "table" then charDB.aliasFills = {} end
    casts, aliases, fills = charDB.casts, charDB.castAliases, charDB.aliasFills
    for key, entry in pairs(casts) do
        if type(key) == "number" and ValidEntry(entry) then Repair(entry) else casts[key] = nil end
    end
    for meterID, castID in pairs(aliases) do
        if type(meterID) ~= "number" or type(castID) ~= "number" then aliases[meterID] = nil end
    end
    for meterID, value in pairs(fills) do
        if value ~= true or aliases[meterID] == nil then fills[meterID] = nil end
    end
end
