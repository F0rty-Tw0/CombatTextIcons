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
-- Coupled heals: a spell that heals you a fixed share k of each of its hits, on the hit's stamp (Devouring Plague
-- 335467 heals 0.3 x its hit, priest3; Drain Life 234153 heals 7 x its tick, lock3). When a clear read's hits drawn
-- under an ID that is also one of its heal rows share one k with the heals on you on their stamps (the raw amounts:
-- a crit hit heals twice), that k is a sample; COUPLE_READS reads of one k teach it, and a heal on you that is k x a
-- hit drawn under that ID in its frame is that ID's, unless another learned ID's k fits a hit of the frame too. A
-- heal under another ID than its hit's is not learned: lock's Drain Life heals log under 1272114, a row the
-- player's raw cannot sum (it heals the pet too), and each read lists the same three rows.
-- Core's waiting heals ask Heals.Claim which of a frame's heals a learned size, coupled hit, helpful cast or running
-- train made.
-- Trains: a HoT or totem a helpful cast starts heals you in ticks phase-locked to that cast (Stormstream 1267068
-- under Healing Stream Totem 5394, Healing Tide 108280: a first tick PERIOD_LO-PERIOD_HI after the cast, then one
-- each period, SLACK either side, each within STEP of the last). A clear read's cast walks its ticks; a walk is none
-- when a tick of its size ran a period before the cast, when its ticks are all one size (a castless proc's: paladin's
-- Word of Glory starts a 720 rune train under the rune's ID 1287665), or when luck gives it more than WALK_ALPHA
-- often. TRAIN_WALKS agreeing walks, TRAIN_SHARE of the cast's counted casts, learn it under the cast's heal row
-- (else its base's); then each cast starts the train, and its due ticks are that row's.
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
-- A coupled heal is k x its hit within COUPLE_TOL (the game rounds: 0.3 x 2391 heals 717). COUPLE_PAIRS heals of one k
-- in a read sample it: priest3's clear fights hold 1 to 9 heals next to a hit drawn 335467.
local COUPLE_TOL, COUPLE_PAIRS = 1, 3
local COUPLE_READS = 2  -- reads of one k teach it
local COUPLE_CAP = 32   -- couples kept; the one seen least recently goes first
-- Trains: a cast's ticks on you every period from the cast, the first a period after it (shamanheal: Healing Tide
-- Totem 108280 ticks 28-37K every 1.7 s, 6 ticks; Stormstream Totem 1267068 12-18K every 1.5 s, 12 ticks). A tick is
-- due SLACK either side of the cast's stamp plus whole periods (the period re-measured at each tick); a tick heals
-- within STEP of the last (resto's mastery heals a hurt target for more, so the ticks drift as you fill up).
local SLACK, STEP = 0.15, 1.35
local PERIOD_LO, PERIOD_HI = 0.8, 3.5
local MISSES = 2        -- missed ticks in a row end a train
local TRAIN_TICKS = 5   -- a walk of fewer ticks is no train
local WALK_ALPHA = 0.01 -- a walk luck alone gives this often or less is a train
-- Walks agree on one train within PERIOD_TOL s and their middle sizes within AGREE x; TRAIN_WALKS agreeing walks,
-- TRAIN_SHARE of the cast's counted casts, teach it.
local PERIOD_TOL, AGREE = 0.1, 2
local TRAIN_WALKS, TRAIN_SHARE = 2, 0.6
local TRAIN_CAP = 32    -- casts kept; the one seen least recently goes first

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
-- the spec store's `healCouples` = { [spell ID] = { lo, hi, reads, seen } }: the span of k its reads agreed on, the
-- reads in a row that sampled it, and the read that last did
local couples = {}
-- the spec store's `healTrains` = { [cast spell ID] = { row, walks = { walk, ... }, seen } }: the heal row its ticks
-- draw under (its own ID, else its base's; nil until one was a heal row), its newest SAMPLES counted casts, each
-- { with = the other helpful casts on its stamp, and when it walked a train: period, size (the middle tick), low,
-- high, ticks }, and the read that last counted it
local trains = {}
local ready = {} -- by cast ID: its learned train { row, period, size, low, high, ticks } (Judge), rebuilt per read
-- the trains running now: { castID, at = the cast's stamp, last = its last tick's, k = that tick's slot, misses,
-- size = that tick's size }
local live = {}
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

-- The ID whose learned k makes a heal of `amount` (raw) from one of `hits` ({ spellID, amount }, the frame's drawn
-- hits), nil when none does or two IDs do.
local function CoupleRow(amount, hits)
    if not IsNumber(amount) then return nil end
    local found
    for _, hit in ipairs(hits) do
        local entry, hitAmount = couples[hit.spellID], hit.amount
        if entry and entry.reads >= COUPLE_READS and IsNumber(hitAmount) and hitAmount > 0
            and amount >= entry.lo * hitAmount - COUPLE_TOL and amount <= entry.hi * hitAmount + COUPLE_TOL then
            if found and found ~= hit.spellID then return nil end
            found = hit.spellID
        end
    end
    return found
end

-- Whether any heal, size, couple or train is learned: only then do Core's heals on you wait for their frame.
function Heals.AnyLearned()
    for _, entry in pairs(heals) do
        if Learned(entry) then return true end
    end
    for _, entry in pairs(sizes) do
        if entry.reads >= SIZE_READS then return true end
    end
    for _, entry in pairs(couples) do
        if entry.reads >= COUPLE_READS then return true end
    end
    return next(ready) ~= nil
end

function Heals.IsTrainLearned(spellID)
    return IsID(spellID) and ready[spellID] ~= nil
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

-- Whether two sizes are within STEP of each other.
local function Near(a, b)
    return a <= STEP * b and b <= STEP * a
end

-- How far `size` is from `to`, as a ratio either way.
local function Off(size, to)
    return math.abs(math.log(size / to))
end

-- Your helpful cast of `spellID` at `now`: its learned train starts; a recast restarts it.
function Heals.Cast(spellID, now)
    if not (IsID(spellID) and IsNumber(now) and ready[spellID]) then return end
    for index = #live, 1, -1 do
        if live[index].castID == spellID then table.remove(live, index) end
    end
    live[#live + 1] = { castID = spellID, at = now, last = now, k = 0, misses = 0 }
end

-- Each running train whose tick is due at `at` (SLACK either side) takes the heal nothing took before inside its
-- padded band and within STEP of its last tick, the nearest that tick's size (the first: the band's middle). A train
-- past its due tick counts a miss; MISSES in a row, or its learned ticks counted, end it.
local function ClaimTicks(waiting, claims, at)
    local kept = {}
    for _, run in ipairs(live) do
        local train = ready[run.castID]
        local running, due = train ~= nil, nil
        while running do
            local period = run.k > 0 and (run.last - run.at) / run.k or train.period
            due = run.last + period * (1 + run.misses)
            if at <= due + SLACK then break end
            run.misses = run.misses + 1
            running = run.misses < MISSES and run.k + run.misses < train.ticks
        end
        if running and at >= due - SLACK then
            local to, best = run.size or train.size, nil
            for index, heal in ipairs(waiting) do
                local size = heal.size
                if not claims[index] and size and size >= PAD_LO * train.low and size <= STEP * train.high
                    and (not run.size or Near(size, run.size)) and (not best or Off(size, to) < Off(waiting[best].size, to)) then
                    best = index
                end
            end
            if best then
                claims[best] = train.row
                run.k, run.misses, run.last, run.size = run.k + 1 + run.misses, 0, at, waiting[best].size
                running = run.k < train.ticks
            end
        end
        if running then kept[#kept + 1] = run end
    end
    live = kept
end

-- Which of one frame's waiting heals (each { size, amount }) at `at` (nil: no train is due) a learned size, its drawn
-- hits (`hits`, each { spellID, amount }; nil: none), its helpful casts or a running train made: claims[index] = spell
-- ID. A heal of a learned size is its row's first, then one a learned k makes from a drawn hit is that hit's; then
-- each learned cast, in cast order, takes the largest heal inside its padded band that nothing took before; then each
-- running train due in the frame takes its tick (ClaimTicks).
function Heals.Claim(castIDs, waiting, hits, at)
    local claims = {}
    for index, heal in ipairs(waiting) do claims[index] = SizeRow(heal.size) or CoupleRow(heal.amount, hits or {}) end
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
    if IsNumber(at) then ClaimTicks(waiting, claims, at) end

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

-- Drops the entry of `entries` seen least recently once `cap` are kept.
local function EvictOldest(entries, cap)
    local count, oldestID = 0, nil
    for spellID, entry in pairs(entries) do
        count = count + 1
        local oldest = entries[oldestID]
        if not oldest or entry.seen < oldest.seen or (entry.seen == oldest.seen and spellID < oldestID) then
            oldestID = spellID
        end
    end
    if count >= cap then entries[oldestID] = nil end
end

-- One read's sample of `spellID`'s size: the same size as its last adds a read, another starts over.
local function SampleSize(spellID, size)
    local entry = sizes[spellID]
    if entry and math.abs(entry.size - size) <= SIZE_TOL then
        entry.reads = entry.reads + 1
    else
        if not entry then EvictOldest(sizes, SIZE_CAP) end
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

-- The k most of `list` ({ heal, hit } amounts) share: the span [lo, hi] inside the band of every one of them (heal
-- +- COUPLE_TOL over hit), and how many they are.
local function SharedShare(list)
    local edges = {}
    for _, pair in ipairs(list) do
        edges[#edges + 1] = { at = (pair.heal - COUPLE_TOL) / pair.hit, step = 1 }
        edges[#edges + 1] = { at = (pair.heal + COUPLE_TOL) / pair.hit, step = -1 }
    end
    table.sort(edges, function(a, b) return a.at < b.at or (a.at == b.at and a.step > b.step) end)
    local count, best, lo, hi = 0, 0, nil, nil
    for index, edge in ipairs(edges) do
        count = count + edge.step
        if edge.step == 1 and count > best then best, lo, hi = count, edge.at, edges[index + 1].at end
    end

    return best, lo, hi
end

-- One read's sample of `spellID`'s k span: a span that meets its last adds a read and keeps their overlap, another
-- starts over.
local function SampleCouple(spellID, lo, hi, count)
    local entry = couples[spellID]
    if entry and lo <= entry.hi and hi >= entry.lo then
        entry.lo, entry.hi, entry.reads = math.max(lo, entry.lo), math.min(hi, entry.hi), entry.reads + 1
    else
        if not entry then EvictOldest(couples, COUPLE_CAP) end
        entry = { lo = lo, hi = hi, reads = 1 }
        couples[spellID] = entry
    end
    entry.seen = reads
    if ns.Debug then
        ns.Debug("TEACH healcouple %d k=%.4f-%.4f pairs=%d reads=%d -> %s", spellID, entry.lo, entry.hi, count,
            entry.reads, entry.reads >= COUPLE_READS and "learned" or "open")
    end
end

-- Each ID of a clear read's drawn hits (`drawn`, each { spellID, amount, at }) that is also one of its heal rows
-- (`own`): when COUPLE_PAIRS of the heals on you on its hits' stamps share one k, that k is a sample.
local function LearnCouples(fightHeals, drawn, own)
    local healsAt = {} -- by stamp: the raw amounts of the heals on you
    for _, heal in ipairs(fightHeals) do
        if IsNumber(heal.amount) and heal.amount > 0 then
            healsAt[heal.at] = healsAt[heal.at] or {}
            table.insert(healsAt[heal.at], heal.amount)
        end
    end
    local byID = {} -- by hit ID: its { heal, hit } pairs
    for _, hit in ipairs(drawn) do
        local spellID, amount = hit.spellID, hit.amount
        if own[spellID] and IsNumber(amount) and amount > 0 then
            for _, heal in ipairs(healsAt[hit.at] or {}) do
                byID[spellID] = byID[spellID] or {}
                table.insert(byID[spellID], { heal = heal, hit = amount })
            end
        end
    end
    for spellID, list in pairs(byID) do
        local count, lo, hi = SharedShare(list)
        if count >= COUPLE_PAIRS then SampleCouple(spellID, lo, hi, count) end
    end
end

-- The index of the first heal of `sorted` (by time) at `at` or later.
local function From(sorted, at)
    local lo, hi = 1, #sorted + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if sorted[mid].at < at then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- The heal of `sorted` due SLACK either side of `due` within STEP of `size`, the nearest that size; nil when none.
local function TickAt(sorted, due, size)
    local best
    for index = From(sorted, due - 2 * SLACK), #sorted do
        local heal = sorted[index]
        if heal.at > due + 2 * SLACK then break end
        if math.abs(heal.at - due) <= SLACK and Near(heal.size, size)
            and (not best or Off(heal.size, size) < Off(best.size, size)) then
            best = heal
        end
    end
    return best
end

-- The walk of a cast at `at` from its first tick `first` (a period after the cast): { period, size (the middle
-- tick), low, high, ticks }. Nil when a tick of its size was due a period before the cast (a train already running:
-- a rune's, a totem cast before), or when its ticks are all one size: a castless proc's (Fixed sizes), and paladin's
-- Word of Glory starts a 720 rune train under the rune's ID (1287665).
local function WalkFrom(sorted, at, first)
    local period = first.at - at
    if TickAt(sorted, at - period, first.size) then return nil end
    local sizes, last, k, misses = { first.size }, first, 1, 0
    while misses < MISSES do
        local tick = TickAt(sorted, last.at + (last.at - at) / k * (1 + misses), last.size)
        if tick then
            sizes[#sizes + 1] = tick.size
            k, misses, last = k + 1 + misses, 0, tick
        else
            misses = misses + 1
        end
    end
    table.sort(sizes)
    if sizes[#sizes] - sizes[1] <= 2 * SIZE_TOL then return nil end

    return { period = (last.at - at) / k, size = sizes[math.ceil(#sizes / 2)], low = sizes[1], high = sizes[#sizes],
        ticks = #sizes }
end

-- A cast's longest walk of TRAIN_TICKS or more that luck alone gives WALK_ALPHA often at most, else nil. Luck: any of
-- the heals a period range after the cast may be the first tick, then each later tick is a heal of its size inside
-- its 2 x SLACK window, at the fight's rate of heals that size.
local function Walk(sorted, at, duration)
    local best, firsts = nil, 0
    for index = From(sorted, at), #sorted do
        local heal = sorted[index]
        local period = heal.at - at
        if period > PERIOD_HI then break end
        if period >= PERIOD_LO then
            firsts = firsts + 1
            local walk = WalkFrom(sorted, at, heal)
            if walk and walk.ticks >= TRAIN_TICKS and (not best or walk.ticks > best.ticks) then best = walk end
        end
    end
    if not best then return nil end
    local near = 0
    for _, heal in ipairs(sorted) do
        if Near(heal.size, best.size) then near = near + 1 end
    end
    local chance = 1 - math.exp(-near / duration * 2 * SLACK)

    return firsts * chance ^ (best.ticks - 1) <= WALK_ALPHA and best or nil
end

-- Whether a heal cast has samples on its own stamps: a direct heal, no train's cast.
local function Direct(spellID)
    return Range(heals[spellID]) ~= nil
end

-- A cast's learned train, else nil. Its counted casts are those whose stamp's other helpful casts are all direct
-- heals (shamanheal casts each totem with Chain Heal on its stamp: the totem's walks count once Chain Heal, cast alone
-- too, has samples; Chain Heal's walks on those stamps never count). Learned when TRAIN_WALKS of its walks agree,
-- TRAIN_SHARE of its counted casts, it has a heal row and it is no direct heal itself.
local function Judge(castID, entry)
    if not entry.row or Direct(castID) then return nil end
    local counted, walks = 0, {}
    for _, walk in ipairs(entry.walks) do
        local alone = true
        for _, other in ipairs(walk.with) do alone = alone and Direct(other) end
        if alone then
            counted = counted + 1
            if walk.period then walks[#walks + 1] = walk end
        end
    end
    local best
    for _, center in ipairs(walks) do
        local group = {}
        for _, walk in ipairs(walks) do
            if math.abs(walk.period - center.period) <= PERIOD_TOL
                and math.max(walk.size, center.size) <= AGREE * math.min(walk.size, center.size) then
                group[#group + 1] = walk
            end
        end
        if not best or #group > #best then best = group end
    end
    if not best or #best < TRAIN_WALKS or #best < TRAIN_SHARE * counted then return nil end
    local train = { row = entry.row, period = 0, low = math.huge, high = 0, ticks = 0 }
    for _, walk in ipairs(best) do
        train.period = train.period + walk.period / #best
        train.low, train.high = math.min(train.low, walk.low), math.max(train.high, walk.high)
        train.ticks = math.max(train.ticks, walk.ticks)
    end
    train.size = math.sqrt(train.low * train.high)

    return train
end

local function Ready()
    ready = {}
    for castID, entry in pairs(trains) do ready[castID] = Judge(castID, entry) end
end

-- Each helpful cast of a clear read counts its stamp's walk (one per stamp, nil: none) with the stamp's other casts.
-- Returns the cast IDs counted.
local function LearnTrains(fightHeals, helps, own, duration)
    local sorted = {}
    for _, heal in ipairs(fightHeals) do
        if IsNumber(heal.size) and heal.size > 0 and IsNumber(heal.at) then sorted[#sorted + 1] = heal end
    end
    table.sort(sorted, function(a, b) return a.at < b.at end)
    local stamps, order = {}, {} -- by stamp: its helpful cast IDs, each once; the stamps in cast order
    for _, cast in ipairs(helps) do
        local ids = stamps[cast.at]
        if not ids then
            ids = {}
            stamps[cast.at], order[#order + 1] = ids, cast.at
        end
        local listed = false
        for _, spellID in ipairs(ids) do listed = listed or spellID == cast.spellID end
        if not listed then ids[#ids + 1] = cast.spellID end
    end
    local counted = {}
    for _, at in ipairs(order) do
        local walk = Walk(sorted, at, duration) or {}
        for _, castID in ipairs(stamps[at]) do
            local entry = trains[castID]
            if not entry then
                EvictOldest(trains, TRAIN_CAP)
                entry = { walks = {} }
                trains[castID] = entry
            end
            local base = ns.Casts.Base(castID)
            entry.row = entry.row or (own[castID] and castID) or (own[base] and base) or nil
            local with = {}
            for _, other in ipairs(stamps[at]) do
                if other ~= castID then with[#with + 1] = other end
            end
            table.insert(entry.walks, { with = with, period = walk.period, size = walk.size, low = walk.low,
                high = walk.high, ticks = walk.ticks })
            if #entry.walks > SAMPLES then table.remove(entry.walks, 1) end
            entry.seen = reads
            counted[#counted + 1] = castID
        end
    end

    return counted
end

-- A clear solo read: the fight's heals on you ({ size, amount, at }), its helpful casts ({ spellID, at }), the
-- session's healing-done `rows`, the fight's `duration` in seconds and its drawn hits (`drawn`, each { spellID,
-- amount, at }; nil: none).
function Heals.Learn(fightHeals, helps, rows, duration, drawn)
    if not (IsNumber(duration) and duration > 0) then return end
    reads = reads + 1
    LearnSizes(fightHeals, rows)
    local own = {}
    for _, row in ipairs(rows) do own[row.spellID] = true end
    LearnCouples(fightHeals, drawn or {}, own)
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
    local walked = LearnTrains(fightHeals, helps, own, duration)
    Ready()
    if not ns.Debug then return end
    local told = {}
    for _, castID in ipairs(walked) do
        local entry = trains[castID]
        if entry and not told[castID] then
            told[castID] = true
            local walk = entry.walks[#entry.walks]
            ns.Debug("TEACH healtrain %d row=%s period=%s ticks=%s -> %s", castID, tostring(entry.row),
                walk.period and string.format("%.2f", walk.period) or "none", tostring(walk.ticks),
                ready[castID] and "learned" or "open")
        end
    end
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
    for spellID in pairs(couples) do couples[spellID] = nil end
    for spellID in pairs(trains) do trains[spellID] = nil end
    ready, live = {}, {}
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

-- Keeps a saved couple with a finite span 0 < lo <= hi and a whole count of reads from 1; drops the rest.
local function ValidCouple(entry)
    if type(entry) ~= "table" or not (IsNumber(entry.lo) and IsNumber(entry.hi)) then return nil end
    if not (entry.lo > 0 and entry.lo <= entry.hi and entry.hi < math.huge) then return nil end
    if not (IsCount(entry.reads) and entry.reads >= 1) then return nil end

    return { lo = entry.lo, hi = entry.hi, reads = entry.reads, seen = 0 }
end

local function Positive(value)
    return IsNumber(value) and value > 0 and value < math.huge
end

-- Keeps a saved counted cast with a list of the other casts' IDs (junk IDs dropped) and, when it walked, positive
-- finite sizes low <= size <= high, a positive period and a whole tick count; drops the rest.
local function ValidWalk(walk)
    if type(walk) ~= "table" or type(walk.with) ~= "table" then return nil end
    local with = {}
    for _, spellID in ipairs(walk.with) do
        if IsID(spellID) then with[#with + 1] = spellID end
    end
    if walk.period == nil then return { with = with } end
    if not (Positive(walk.period) and Positive(walk.size) and Positive(walk.low) and Positive(walk.high)
        and walk.low <= walk.size and walk.size <= walk.high and IsCount(walk.ticks) and walk.ticks > 0) then
        return nil
    end

    return { with = with, period = walk.period, size = walk.size, low = walk.low, high = walk.high, ticks = walk.ticks }
end

-- Keeps a saved train with a valid row (or none yet) and its valid counted casts (the newest SAMPLES); drops the rest.
local function ValidTrain(entry)
    if type(entry) ~= "table" or type(entry.walks) ~= "table" then return nil end
    if entry.row ~= nil and not IsID(entry.row) then return nil end
    local walks = {}
    for _, walk in ipairs(entry.walks) do walks[#walks + 1] = ValidWalk(walk) end
    while #walks > SAMPLES do table.remove(walks, 1) end

    return { row = entry.row, walks = walks, seen = 0 }
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
    couples, trains, live = Kept(charDB.healCouples, ValidCouple), Kept(charDB.healTrains, ValidTrain), {}
    charDB.heals, charDB.healSizes, charDB.healCouples, charDB.healTrains = heals, sizes, couples, trains
    Ready()
end
