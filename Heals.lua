-- Combat Text Icons: heals. The per-spec store of your direct heals learned on yourself: a helpful cast whose heal
-- lands on you in the cast's own frame (Chain Heal, Riptide's first heal, Healing Wave). The meter cannot check them
-- as it checks damage: a HEAL line's amount is raw (overheal included) while the healing-done rows are effective,
-- on every target. So a heal is learned from timing and size alone, and the rows serve only as the list of IDs that
-- are your heals.
-- After a clear solo read (Teacher.lua) each of the fight's helpful casts that is the only helpful cast on its stamp
-- counts a cast; the largest heal on you on that stamp (normal scale) is its sample. A cast learns only once its ID
-- was a healing-done row in some read: a fight that only overheals has no row (shamanheal's Healing Wave casts in
-- its 3rd and 4th fights), and those casts still count toward the heal.
-- The largest: your own procs share the cast's frame (shamanheal: Healing Wave stamps hold 4453-16134 next to
-- 90650-231640). A stamp two different helpful casts share counts for the one of them that already has samples
-- (none when both or neither do), a sample only when its largest heal fits that cast's padded band: shamanheal's
-- Chain Heal goes out on a totem's stamp in 13 of its 17 casts.
-- A cast is learned once LEARN_CASTS of its casts left a sample (TWIN_CASTS of one size), at least HIT_SHARE of its
-- counted casts did, its ID was a heal row, and luck alone (some heal on the cast's stamp by chance, FRAME) gives
-- that many at most ALPHA often.
-- Fixed sizes: a castless proc that heals one size each time (Rune of Self-Mending 5763, its crit 11526; Holy
-- Retributor's Order 21535) has no cast to tie it, but its row tells its size: when a row equals the summed amount
-- of the fight's heals on you of one size (crits at normal scale), that size is the row's, a row that did not
-- overheal and healed only you in that fight (druid's Frenzied Regeneration row 217748 = 4 x 54437). Checked per row,
-- never assumed per fight: a healer's fight overheals, so its rows match no sum (shamanheal). SIZE_READS reads of
-- one size teach it; then each heal on you of that size is the row's, cast or not, unless two learned rows share it.
-- Core's waiting heals ask Heals.Claim which of a frame's heals a learned size or its helpful casts made.
-- Kept apart from the damage stores: an ID can be both a damage and a heal row (Healing Rain 73921).
-- Saved data is checked on load and never trusted.

local _, ns = ...

local Heals = {}
ns.Heals = Heals

local LEARN_CASTS = 3   -- samples from this many different casts teach a heal (Fingerprints.LEARN_CASTS)
-- Two samples of one size within TWIN teach at TWIN_CASTS: a heal of a share of your health lands the same each cast
-- (hunter's Exhilaration 87925, 87926, a cooldown with 4 casts in its log), where mastery spreads Chain Heal's
-- 40872-133149. The luck test still holds.
local TWIN_CASTS, TWIN = 2, 0.005
local HIT_SHARE = 0.8   -- share of its counted casts that must have left a sample: a heal on yourself solo always lands
local ALPHA = 0.01      -- learned when luck alone gives its samples this often or less (Learn.lua's value)
-- A frame's length in seconds for the luck test, at 20 fps: the logs' fps= read 90-105, so the true chance is lower.
local FRAME = 0.05
local SAMPLES = 16      -- sizes kept per heal, oldest dropped
local CAP = 32          -- heals kept; a pending one (no heal row yet) goes first, then the one seen least recently
-- A heal fits a learned cast from PAD_LO of its smallest to PAD_HI of its biggest sample, as a direct hit's band
-- (Casts.lua). Resto's mastery heals a hurt target for more, so one cast's heals vary: shamanheal's Chain Heal
-- 40872-133149.
local PAD_LO, PAD_HI = 0.7, 2
-- A fixed heal's sizes at normal scale agree within SIZE_TOL: the game rounds (Rune of Self-Mending 11526, 11527 and
-- a crit's half, 5763.5). A row matches a size's sum within SUM_TOL (the meter's own rounding).
local SIZE_TOL, SUM_TOL = 1, 1
local SIZE_READS = 2    -- reads whose row matched one size teach it
local SIZE_CAP = 32     -- sizes kept; the one seen least recently goes first

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end
local function IsCount(value) return IsNumber(value) and value >= 0 and value % 1 == 0 end
local function IsID(value) return IsNumber(value) and value > 0 and value % 1 == 0 end

-- the spec store's `heals` = { [cast spell ID] = { casts, hits, expected, sizes = { size, ... }, seen, pending } }:
-- casts counted, casts that left a sample, the samples luck alone would give, the kept sample sizes (normal scale),
-- the read that last counted it (an ever-growing number), and true while its ID was never a healing-done row
local heals = {}
-- the spec store's `healSizes` = { [heal row ID] = { size, reads, seen } }: the size its last matching read gave
-- (normal scale), the reads in a row that matched it, and the read that last matched it
local sizes = {}
local reads = 0

-- Whether two samples are a twin: the same size within TWIN of the bigger.
local function Twin(sizes)
    local a, b = sizes[1], sizes[2]
    return #sizes == 2 and math.abs(a - b) <= TWIN * math.max(a, b)
end

local function Learned(entry)
    local need = Twin(entry.sizes) and TWIN_CASTS or LEARN_CASTS
    return not entry.pending and entry.hits >= need and entry.hits >= HIT_SHARE * entry.casts
        and #entry.sizes >= need and ns.Learn.PoissonTail(entry.expected, entry.hits) <= ALPHA
end

function Heals.IsLearned(spellID)
    local entry = IsID(spellID) and heals[spellID]
    return entry and Learned(entry) or false
end

-- The row whose learned size `size` is, nil when none is or two are (two rows sharing a size name neither).
local function SizeRow(size)
    if size == nil then return nil end
    local found
    for spellID, entry in pairs(sizes) do
        if entry.reads >= SIZE_READS and math.abs(size - entry.size) <= SIZE_TOL then
            if found then return nil end
            found = spellID
        end
    end
    return found
end

-- Whether any heal or size is learned: only then do Core's heals on you wait for their frame.
function Heals.AnyLearned()
    for _, entry in pairs(heals) do
        if Learned(entry) then return true end
    end
    for _, entry in pairs(sizes) do
        if entry.reads >= SIZE_READS then return true end
    end
    return false
end

-- The smallest and biggest kept size of an entry with samples, else nil.
local function Range(entry)
    if not (entry and #entry.sizes > 0) then return nil end
    local low, high = math.huge, 0
    for _, size in ipairs(entry.sizes) do low, high = math.min(low, size), math.max(high, size) end

    return low, high
end

-- Whether `size` sits inside the padded band of the entry's samples.
local function Fits(entry, size)
    local low, high = Range(entry)
    return low ~= nil and size ~= nil and size >= PAD_LO * low and size <= PAD_HI * high
end

-- The smallest and biggest kept size of a learned heal, else nil.
local function Band(spellID)
    local entry = heals[spellID]
    if not (entry and Learned(entry)) then return nil end

    return Range(entry)
end

-- Which of one frame's waiting heals (each { size }) a learned size or its helpful casts made: claims[index] = spell
-- ID. A heal of a learned size is its row's first; then each learned cast, in cast order, takes the largest heal
-- inside its padded band that nothing took before.
function Heals.Claim(castIDs, waiting)
    local claims = {}
    for index, heal in ipairs(waiting) do claims[index] = SizeRow(heal.size) end
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

-- Drops a pending cast (no heal row yet) before a heal, then the one seen least recently.
local function Evict()
    local count, oldestID = 0, nil
    for spellID, entry in pairs(heals) do
        count = count + 1
        local oldest = heals[oldestID]
        if not oldest or (entry.pending and not oldest.pending)
            or (not entry.pending == not oldest.pending and (entry.seen < oldest.seen
                or (entry.seen == oldest.seen and spellID < oldestID))) then
            oldestID = spellID
        end
    end
    if count >= CAP then heals[oldestID] = nil end
end

-- One counted cast of `spellID`: `size` is the largest heal on its stamp (nil: none), `chance` that of some heal
-- on its stamp by luck, `row` whether its ID is one of this read's healing-done rows.
local function CountCast(spellID, size, chance, row)
    local entry = heals[spellID]
    if not entry then
        Evict()
        entry = { casts = 0, hits = 0, expected = 0, sizes = {}, seen = 0, pending = true }
        heals[spellID] = entry
    end
    if row then entry.pending = nil end
    entry.casts, entry.expected, entry.seen = entry.casts + 1, entry.expected + chance, reads
    if size then
        entry.hits = entry.hits + 1
        entry.sizes[#entry.sizes + 1] = size
        if #entry.sizes > SAMPLES then table.remove(entry.sizes, 1) end
    end
end

-- The fight's heals on you in runs of one size: sorted by size, a run grows while the next size is within SIZE_TOL
-- of its last. Returns { { size = its middle, sum = its amounts summed }, ... } of the runs spanning SIZE_TOL at most.
local function SizeRuns(fightHeals)
    local sorted = {}
    for _, heal in ipairs(fightHeals) do
        if IsNumber(heal.amount) then sorted[#sorted + 1] = heal end
    end
    table.sort(sorted, function(a, b) return a.size < b.size end)
    local runs, run = {}, nil
    for _, heal in ipairs(sorted) do
        if run and heal.size - run.last <= SIZE_TOL then
            run.last, run.sum = heal.size, run.sum + heal.amount
        else
            run = { first = heal.size, last = heal.size, sum = heal.amount }
            runs[#runs + 1] = run
        end
    end
    local kept = {}
    for _, each in ipairs(runs) do
        if each.last - each.first <= SIZE_TOL then kept[#kept + 1] = { size = (each.first + each.last) / 2, sum = each.sum } end
    end

    return kept
end

-- Drops the size seen least recently once SIZE_CAP are kept.
local function EvictSize()
    local count, oldestID = 0, nil
    for spellID, entry in pairs(sizes) do
        count = count + 1
        local oldest = sizes[oldestID]
        if not oldest or entry.seen < oldest.seen or (entry.seen == oldest.seen and spellID < oldestID) then
            oldestID = spellID
        end
    end
    if count >= SIZE_CAP then sizes[oldestID] = nil end
end

-- One read's sample of `spellID`'s size: the same size as its last adds a read, another starts over.
local function SampleSize(spellID, size)
    local entry = sizes[spellID]
    if entry and math.abs(entry.size - size) <= SIZE_TOL then
        entry.reads = entry.reads + 1
    else
        if not entry then EvictSize() end
        entry = { reads = 1 }
        sizes[spellID] = entry
    end
    entry.size, entry.seen = size, reads
    if ns.Debug then
        ns.Debug("TEACH healsize %d size=%.1f reads=%d -> %s", spellID, size, entry.reads,
            entry.reads >= SIZE_READS and "learned" or "open")
    end
end

-- Each of a clear read's heal rows that equals the sum of exactly one run of the fight's heals on you (SizeRuns),
-- a run no other row equals, samples that run's size for the row.
local function LearnSizes(fightHeals, rows)
    local runs = SizeRuns(fightHeals)
    local matches = {} -- by run index: the rows equal to its sum
    for _, row in ipairs(rows) do
        local total, found = row.total, nil
        if IsID(row.spellID) and IsNumber(total) and total > 0 then
            for index, run in ipairs(runs) do
                if math.abs(run.sum - total) <= SUM_TOL then found = found == nil and index or false end
            end
        end
        if found then
            matches[found] = matches[found] or {}
            table.insert(matches[found], row.spellID)
        end
    end
    for index, rowIDs in pairs(matches) do
        if #rowIDs == 1 then SampleSize(rowIDs[1], runs[index].size) end
    end
end

-- A clear solo read: the fight's heals on you ({ size, amount, at }), its helpful casts ({ spellID, at }), the
-- session's healing-done `rows` and the fight's `duration` in seconds.
function Heals.Learn(fightHeals, helps, rows, duration)
    if not (IsNumber(duration) and duration > 0) then return end
    reads = reads + 1
    LearnSizes(fightHeals, rows)
    local own = {}
    for _, row in ipairs(rows) do own[row.spellID] = true end
    -- by stamp: the largest heal no learned size names (a cast's own heal, not the proc on its stamp)
    local largest, stamped, stamps = {}, {}, 0
    for _, heal in ipairs(fightHeals) do
        if not stamped[heal.at] then stamped[heal.at], stamps = true, stamps + 1 end
        if not SizeRow(heal.size) then largest[heal.at] = math.max(largest[heal.at] or 0, heal.size) end
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
        if spellID then
            frames[cast.at] = nil -- one count per stamp
            CountCast(spellID, largest[cast.at], chance, own[spellID])
            counted[#counted + 1] = spellID
        end
    end
    -- a stamp two different casts share counts for the one with samples, a miss unless its band fits: counting only
    -- the stamps that fit would pass the luck test on picked hits
    local sharers = {} -- by shared stamp: its one cast with samples, or false when two have them
    for _, cast in ipairs(helps) do
        local at, spellID = cast.at, cast.spellID
        if frames[at] == false and Range(heals[spellID]) then
            local held = sharers[at]
            if held == nil then sharers[at] = spellID elseif held ~= spellID then sharers[at] = false end
        end
    end
    for _, cast in ipairs(helps) do
        local at, spellID = cast.at, sharers[cast.at]
        if spellID then
            sharers[at] = nil -- one count per stamp
            CountCast(spellID, Fits(heals[spellID], largest[at]) and largest[at] or nil, chance, own[spellID])
            counted[#counted + 1] = spellID
        end
    end
    if not ns.Debug then return end
    local said = {}
    for _, spellID in ipairs(counted) do
        local entry = heals[spellID]
        if entry and not said[spellID] then
            said[spellID] = true
            local verdict = Learned(entry) and "learned" or entry.pending and "no row" or "open"
            ns.Debug("TEACH healcast %d casts=%d hits=%d p=%.2g -> %s", spellID, entry.casts, entry.hits,
                ns.Learn.PoissonTail(entry.expected, entry.hits), verdict)
        end
    end
end

function Heals.Forget()
    for spellID in pairs(heals) do heals[spellID] = nil end
    for spellID in pairs(sizes) do sizes[spellID] = nil end
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

    return { casts = entry.casts, hits = entry.hits, expected = expected, sizes = sizes, seen = 0,
        pending = entry.pending == true or nil }
end

-- Keeps a saved size entry with a positive finite size and a whole count of reads from 1; drops the rest.
local function ValidSize(entry)
    if type(entry) ~= "table" or not (IsNumber(entry.size) and entry.size > 0 and entry.size < math.huge) then
        return nil
    end
    if not (IsCount(entry.reads) and entry.reads >= 1) then return nil end

    return { size = entry.size, reads = entry.reads, seen = 0 }
end

-- The saved entries of `saved` (a table, else none) whose spell ID is valid and `valid` keeps.
local function Kept(saved, valid)
    local kept = {}
    if type(saved) ~= "table" then return kept end
    for spellID, entry in pairs(saved) do
        if IsID(spellID) then kept[spellID] = valid(entry) end
    end

    return kept
end

function Heals.Init(charDB)
    heals, sizes, reads = Kept(charDB.heals, Valid), Kept(charDB.healSizes, ValidSize), 0
    charDB.heals, charDB.healSizes = heals, sizes
end
