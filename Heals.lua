-- Combat Text Icons: heals. The per-spec store of your direct heals learned on yourself: a helpful cast whose heal
-- lands on you in the cast's own frame (Chain Heal, Riptide's first heal, Healing Wave). The meter cannot check them
-- as it checks damage: a HEAL line's amount is raw (overheal included) while the healing-done rows are effective,
-- on every target. So a heal is learned from timing and size alone, and the rows serve only as the list of IDs that
-- are your heals.
-- After a clear solo read (Teacher.lua) each of the fight's helpful casts that is a healing-done row, and is the
-- only helpful cast on its stamp, counts a cast; the largest heal on you on that stamp (normal scale) is its sample.
-- The largest: your own procs share the cast's frame (shamanheal: Healing Wave stamps hold 4453-16134 next to
-- 90650-231640). A cast is learned once LEARN_CASTS of its casts left a sample, at least HIT_SHARE of its counted
-- casts did, and luck alone (some heal on the cast's stamp by chance, FRAME) gives that many at most ALPHA often.
-- Core's waiting heals ask Heals.Claim which of a frame's heals its helpful casts made.
-- Kept apart from the damage stores: an ID can be both a damage and a heal row (Healing Rain 73921).
-- Saved data is checked on load and never trusted.

local _, ns = ...

local Heals = {}
ns.Heals = Heals

local LEARN_CASTS = 3   -- samples from this many different casts teach a heal (Fingerprints.LEARN_CASTS)
local HIT_SHARE = 0.8   -- share of its counted casts that must have left a sample: a heal on yourself solo always lands
local ALPHA = 0.01      -- learned when luck alone gives its samples this often or less (Learn.lua's value)
-- A frame's length in seconds for the luck test, at 20 fps: the logs' fps= read 90-105, so the true chance is lower.
local FRAME = 0.05
local SAMPLES = 16      -- sizes kept per heal, oldest dropped
local CAP = 32          -- heals kept; the one seen least recently goes first
-- A heal fits a learned cast from PAD_LO of its smallest to PAD_HI of its biggest sample, as a direct hit's band
-- (Casts.lua). Resto's mastery heals a hurt target for more, so one cast's heals vary: shamanheal's Chain Heal
-- 40872-133149.
local PAD_LO, PAD_HI = 0.7, 2

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end
local function IsCount(value) return IsNumber(value) and value >= 0 and value % 1 == 0 end
local function IsID(value) return IsNumber(value) and value > 0 and value % 1 == 0 end

-- the spec store's `heals` = { [cast spell ID] = { casts, hits, expected, sizes = { size, ... }, seen } }: casts
-- counted, casts that left a sample, the samples luck alone would give, the kept sample sizes (normal scale), and
-- the read that last counted it (an ever-growing number)
local heals = {}
local reads = 0

local function Learned(entry)
    return entry.hits >= LEARN_CASTS and entry.hits >= HIT_SHARE * entry.casts and #entry.sizes >= LEARN_CASTS
        and ns.Learn.PoissonTail(entry.expected, entry.hits) <= ALPHA
end

function Heals.IsLearned(spellID)
    local entry = IsID(spellID) and heals[spellID]
    return entry and Learned(entry) or false
end

-- Whether any heal is learned: only then do Core's heals on you wait for their frame's casts.
function Heals.AnyLearned()
    for _, entry in pairs(heals) do
        if Learned(entry) then return true end
    end
    return false
end

-- The smallest and biggest kept size of a learned heal, else nil.
local function Band(spellID)
    local entry = heals[spellID]
    if not (entry and Learned(entry)) then return nil end
    local low, high = math.huge, 0
    for _, size in ipairs(entry.sizes) do low, high = math.min(low, size), math.max(high, size) end

    return low, high
end

-- Which of one frame's waiting heals (each { size }) its helpful casts made: claims[index] = cast ID. Each learned
-- cast, in cast order, takes the largest heal inside its padded band that no cast took before.
function Heals.Claim(castIDs, waiting)
    local claims = {}
    for _, castID in ipairs(castIDs) do
        local low, high = Band(castID)
        local best
        for index, heal in ipairs(low and waiting or {}) do
            local size = heal.size
            if not claims[index] and size and size >= PAD_LO * low and size <= PAD_HI * high
                and (not best or size > waiting[best].size) then
                best = index
            end
        end
        if best then claims[best] = castID end
    end

    return claims
end

local function Evict()
    local count, oldestID = 0, nil
    for spellID, entry in pairs(heals) do
        count = count + 1
        if not oldestID or entry.seen < heals[oldestID].seen
            or (entry.seen == heals[oldestID].seen and spellID < oldestID) then
            oldestID = spellID
        end
    end
    if count >= CAP then heals[oldestID] = nil end
end

-- One counted cast of `spellID`: `size` is the largest heal on its stamp (nil: none), `chance` that of some heal
-- on its stamp by luck.
local function CountCast(spellID, size, chance)
    local entry = heals[spellID]
    if not entry then
        Evict()
        entry = { casts = 0, hits = 0, expected = 0, sizes = {}, seen = 0 }
        heals[spellID] = entry
    end
    entry.casts, entry.expected, entry.seen = entry.casts + 1, entry.expected + chance, reads
    if size then
        entry.hits = entry.hits + 1
        entry.sizes[#entry.sizes + 1] = size
        if #entry.sizes > SAMPLES then table.remove(entry.sizes, 1) end
    end
end

-- A clear solo read: the fight's heals on you ({ size, at }), its helpful casts ({ spellID, at }), the session's
-- healing-done `rows` and the fight's `duration` in seconds.
function Heals.Learn(fightHeals, helps, rows, duration)
    if not (IsNumber(duration) and duration > 0) then return end
    reads = reads + 1
    local own = {}
    for _, row in ipairs(rows) do own[row.spellID] = true end
    local largest, stamps = {}, 0 -- by stamp: the largest heal
    for _, heal in ipairs(fightHeals) do
        if not largest[heal.at] then stamps = stamps + 1 end
        largest[heal.at] = math.max(largest[heal.at] or 0, heal.size)
    end
    local chance = math.min(1, stamps * FRAME / duration)
    local frames = {} -- by stamp: its one helpful cast's ID, or false when two differ
    for _, cast in ipairs(helps) do
        local held = frames[cast.at]
        if held == nil then frames[cast.at] = cast.spellID elseif held ~= cast.spellID then frames[cast.at] = false end
    end
    local counted = {}
    for _, cast in ipairs(helps) do
        local spellID = frames[cast.at]
        if spellID and own[spellID] then
            frames[cast.at] = nil -- one count per stamp
            CountCast(spellID, largest[cast.at], chance)
            counted[#counted + 1] = spellID
        end
    end
    if not ns.Debug then return end
    local said = {}
    for _, spellID in ipairs(counted) do
        local entry = heals[spellID]
        if entry and not said[spellID] then
            said[spellID] = true
            ns.Debug("TEACH healcast %d casts=%d hits=%d p=%.2g -> %s", spellID, entry.casts, entry.hits,
                ns.Learn.PoissonTail(entry.expected, entry.hits), Learned(entry) and "learned" or "open")
        end
    end
end

function Heals.Forget()
    for spellID in pairs(heals) do heals[spellID] = nil end
end

-- Keeps each saved entry of a spell ID with whole counts (hits no more than casts), a finite expected count from 0
-- and positive finite sizes (the newest SAMPLES); drops the rest.
local function Valid(entry)
    if type(entry) ~= "table" or not (IsCount(entry.casts) and IsCount(entry.hits) and entry.hits <= entry.casts) then
        return nil
    end
    local expected = entry.expected
    if not (IsNumber(expected) and expected >= 0 and expected < math.huge and type(entry.sizes) == "table") then
        return nil
    end
    local sizes = {}
    for _, size in ipairs(entry.sizes) do
        if IsNumber(size) and size > 0 and size < math.huge then sizes[#sizes + 1] = size end
    end
    while #sizes > SAMPLES do table.remove(sizes, 1) end

    return { casts = entry.casts, hits = entry.hits, expected = expected, sizes = sizes, seen = 0 }
end

function Heals.Init(charDB)
    local kept = {}
    if type(charDB.heals) == "table" then
        for spellID, entry in pairs(charDB.heals) do
            if IsID(spellID) then kept[spellID] = Valid(entry) end
        end
    end
    heals, reads = kept, 0
    charDB.heals = kept
end
