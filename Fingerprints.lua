-- Combat Text Icons: fingerprints. The per-character store of what the addon
-- learned about each of your direct-hit spells: its school, how long after the
-- cast its hit lands (a ring of recent delays), and whether it hits once or
-- hops from plate to plate (chain). A spell is learned when 3 different casts
-- sharing a school each left a sample; after that its school is fixed and the
-- post-fight teacher (Teacher.lua) only counts fights it agreed with or
-- overshot. Two overshoots in a row delete the entry. Samples keep the hit's normal-scale
-- size (crits divided by CRIT_FACTOR); a claim needs a hit inside the padded band (Casts.lua).
-- `castAliases` maps a meter row ID to the cast ID (Auto Shot 75 -> Shoot 5019).
-- Saved data is checked on load and never trusted.

local _, ns = ...

local Fingerprints = {}
ns.Fingerprints = Fingerprints

local CAP = 64        -- entries kept; the least useful one goes first
local SAMPLES = 16    -- samples kept per entry, oldest dropped (one steady fight can add 11: Void Blast + Mind Blast)
local DELAYS = 8      -- delays kept per learned entry, oldest dropped
local LEARN_CASTS = 3 -- samples from this many different casts, one school, teach a spell
local STRIKES = 2     -- teacher overshoots in a row that delete an entry

Fingerprints.LEARN_CASTS = LEARN_CASTS -- the panel shows "casts n of LEARN_CASTS"

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end
local function HitSize(value) return IsNumber(value) and value > 0 and value or nil end -- a plain size above 0, else nil

-- The in-memory tables are the saved ones once Init ran.
local casts, aliases = {}, {}

-- Recomputes delayLo / delayHi from `delays` and `pattern` from the kept samples.
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

-- Whether `school` has LEARN_CASTS samples from different casts among the kept ones.
local function SchoolLearned(entry, school)
    local seen, distinct = {}, 0
    for _, sample in ipairs(entry.samples) do
        if sample.school == school and not seen[sample.castAt] then
            seen[sample.castAt] = true
            distinct = distinct + 1
        end
    end

    return distinct >= LEARN_CASTS
end

local function MarkLearned(entry, school)
    entry.learned, entry.school = true, school
    entry.delays = {}
    for _, sample in ipairs(entry.samples) do
        if sample.school == school then entry.delays[#entry.delays + 1] = sample.delay end
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
    entry.samples[#entry.samples + 1] = { school = school, delay = delay, castAt = castAt, hops = hops, spell = spell,
        size = HitSize(sample.size) }
    if #entry.samples > SAMPLES then table.remove(entry.samples, 1) end
    entry.lastSeen = castAt
    if entry.learned then
        entry.delays[#entry.delays + 1] = delay
        if #entry.delays > DELAYS then table.remove(entry.delays, 1) end
    elseif SchoolLearned(entry, school) then
        MarkLearned(entry, school)
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
        if sample.spell == castSpell and sample.school == entry.school then
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

function Fingerprints.SetAlias(meterID, castID)
    if IsNumber(meterID) and IsNumber(castID) then aliases[meterID] = castID end
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

function Fingerprints.Forget()
    for spellID in pairs(casts) do casts[spellID] = nil end
    for meterID in pairs(aliases) do aliases[meterID] = nil end
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
                spell = spell, size = size }
        end
    end
    while #kept > SAMPLES do table.remove(kept, 1) end

    return kept
end

-- Whether a saved entry can be kept: a learned one needs a school and delays, any needs a known pattern.
local function ValidEntry(entry)
    if type(entry) ~= "table" or type(entry.learned) ~= "boolean" then return false end
    if entry.pattern ~= "single" and entry.pattern ~= "chain" then return false end
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
    Refresh(entry)
end

function Fingerprints.Init(charDB)
    if type(charDB.casts) ~= "table" then charDB.casts = {} end
    if type(charDB.castAliases) ~= "table" then charDB.castAliases = {} end
    casts, aliases = charDB.casts, charDB.castAliases
    for key, entry in pairs(casts) do
        if type(key) == "number" and ValidEntry(entry) then Repair(entry) else casts[key] = nil end
    end
    for meterID, castID in pairs(aliases) do
        if type(meterID) ~= "number" or type(castID) ~= "number" then aliases[meterID] = nil end
    end
end
