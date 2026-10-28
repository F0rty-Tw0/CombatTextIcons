-- Combat Text Icons: stack pass. A stacking DoT: each cast adds a stack that lasts its own life, one tick timer per
-- plate runs while any stack lives, and each tick is the live stacks times one stack's size. Run lock3 fight 1:
-- Unstable Affliction 1259790 cast at 199119.892 and 199120.523 ticked its plate every ~1.33 s from 1.32 s after the
-- first cast: 6517, 6517 (2 stacks of 3258.5), 21019 (a crit of 3, x2.15, after the cast at 199123.109), 13035 (4),
-- 16293 (5); each stack ends 8 s after its cast (199129.180: 11731 is 3 stacks under Darkglare's x1.2, 199131.826: 7820
-- is 2). A recast keeps the phase and every tick changes size past Streams' SIZE_GUARD, so no stream is born, no cast's
-- window holds its ticks, and its row (12.9 % of the log) stayed '?'.
-- The proof: per cast spell with its own open row, a seed is a hit of one school on a cast's plate within WAIT of the
-- cast; its period is the gap that chains the most hits one (or two) periods apart from it on that plate. Then, per
-- life (LIFE_LO to LIFE_HI whole seconds, LIFE_TICKS periods at least), each plate of the spell's casts is walked:
-- with no series running, a series starts on a hit in the seed's delay window (SPREAD) after a cast; a running one
-- takes each hit one or two periods after its last tick (Streams.Slack) whose size over the live stacks (the casts
-- within the life) agrees with the last tick's within SIZE_GUARD. The draw route (Casts.StackTick) continues a series
-- the same way but starts one only on a step: one hit at a time has no luck test to guard its start. A walk that took
-- most of its ticks two periods apart walks again at twice the period, else learns nothing (half a period draws hits
-- between the ticks).
-- MIN_STEPS ticks or more must change the stack count (a steady DoT is no stack), and the ticks must beat luck: each
-- tick's next slots find a hit by luck with the plate's rate of the school's hits * the slots' width * the share of
-- them that agree with the predicted size, Poisson tail times the patterns tried. The meter bounds from below only, as
-- the chain pass: the ticks' sum is at most the own row (lock3 F1: 0.40 of UA's row was in the streams it owns, the
-- rest '?'). Learned, each cast with a stack in a taken tick keeps a sample with the period and the life: tick 0 at
-- its delay for a cast that started a series (the window), tick 1 for the others. With /cti debug each tried spell
-- logs one TEACH stack line.

local _, ns = ...
local Fingerprints, Streams, Chain = ns.Fingerprints, ns.Streams, ns.Chain

local Stack = {}
ns.Stack = Stack

local MIN_CASTS = 3   -- casts with a stack in a taken tick at least (Steady's)
local MIN_STEPS = 3   -- taken ticks whose stack count differs from the tick before, at least
local WAIT = 1.5      -- a seed lands at most this long after its cast (Casts' UNKNOWN_WAIT)
local SPREAD = 0.3    -- a series' first tick's delay window (Ground's)
local PERIOD_LO, PERIOD_HI = 0.5, 3 -- a period lies in this range (Ground's)
local LIFE_LO, LIFE_HI = 2, 30      -- a stack's life, in whole seconds, lies in this range
-- A stack lives through this many periods at least, so its ticks test the size law: a life near one period holds one
-- tick per cast and its stack count steps on every tick (hunter fight 10: Barbed Shot 217200, life 3 at period 2.335).
local LIFE_TICKS = 3
local BLEND = 0.8     -- weight of the old period when a tick extends a series (Streams')
local ALPHA = 0.01    -- the walks learn when luck alone gives them this often or less (Learn.lua's value)
local EPS = 1e-6

-- Series rules, shared with the draw route (Casts.StackTick) ---------------------------------------------------------

-- Whether two one-stack sizes agree: within `guard` of each other, else Streams.SIZE_GUARD (two hits of a kind).
function Stack.Agree(a, b, guard) return math.abs(a - b) <= (guard or Streams.SIZE_GUARD) * math.max(a, b) end

-- Whether `series` still runs at `at`: its tick two periods on is still due.
function Stack.Running(series, at)
    return series ~= nil and at - series.at <= 2 * series.period + Streams.Slack(series.period)
end

-- The multiple (1 or 2) of the series' period that puts a hit at `at` on its next tick, within Streams.Slack; else nil.
function Stack.Multiple(series, at)
    local slack = Streams.Slack(series.period)
    for multiple = 1, 2 do
        if math.abs(at - series.at - multiple * series.period) <= slack then return multiple end
    end
end

-- The series after a tick at `at` of normal-scale `size` over `n` live stacks: a start at `period` when `multiple` is
-- nil, else an extension of `series` whose gap blends into its period.
function Stack.Tick(series, at, size, n, multiple, period)
    if multiple then period = BLEND * series.period + (1 - BLEND) * (at - series.at) / multiple end

    return { at = at, unit = size / n, n = n, period = period }
end

-- Learning ----------------------------------------------------------------------------------------------------------

local function Median(list)
    if #list == 0 then return nil end
    table.sort(list)

    return list[math.ceil(#list / 2)]
end

-- The stacks of `times` (cast times, oldest first) live at `at` for `life`, and the newest cast whose age at `at` lies
-- in [from, to] (a series start), or nil.
local function Stacks(times, at, life, from, to)
    local n, start = 0, nil
    for _, castAt in ipairs(times) do
        local age = at - castAt
        if age >= -EPS and age <= life + EPS then n = n + 1 end
        if from and age >= from - EPS and age <= to + EPS then start = castAt end
    end

    return n, start
end

-- The first index of `sorted` whose value is at least `value`.
local function Bisect(sorted, value)
    local low, high = 1, #sorted + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        if sorted[middle] < value then low = middle + 1 else high = middle end
    end

    return low
end

-- The share of `sorted` (a plate's sizes) that agrees with `size`.
local function Share(sorted, size)
    if #sorted == 0 then return 0 end
    local guard = 1 - Streams.SIZE_GUARD

    return (Bisect(sorted, size / guard + EPS) - Bisect(sorted, size * guard - EPS)) / #sorted
end

-- The gaps from `list[index]` the period search tries, and the one that chains the most later hits of `list` one or
-- two periods apart (ties: the shorter), with that count.
local function Period(list, index)
    local seed, best, most, tried = list[index], nil, 0, 0
    for other = index + 1, #list do
        local gap = list[other].at - seed.at
        if gap > PERIOD_HI + EPS then break end
        if gap >= PERIOD_LO - EPS then
            tried = tried + 1
            local series, count = { at = seed.at, period = gap }, 0
            for later = index + 1, #list do
                local hit = list[later]
                if not Stack.Running(series, hit.at) then break end
                local multiple = Stack.Multiple(series, hit.at)
                if multiple then
                    series = Stack.Tick(series, hit.at, 1, 1, multiple)
                    count = count + 1
                end
            end
            if count > most then best, most = gap, count end
        end
    end

    return best, most, tried
end

-- One plate's walk as the draw route takes it, added into `walk`: { hits, sum, extended, ones (the extensions one
-- period on), steps, expected, gaps, casts = { [castAt] = delay of the first taken tick it had a stack in },
-- starts = { [castAt] = true } }.
local function Walk(plate, pattern, walk)
    local series
    for _, hit in ipairs(plate.list) do
        local slack = Streams.Slack(series and series.period or pattern.period)
        local n, start = Stacks(plate.times, hit.at, pattern.life, pattern.low - slack, pattern.low + SPREAD + slack)
        local tick
        if n > 0 and Stack.Running(series, hit.at) then
            local multiple = Stack.Multiple(series, hit.at)
            if multiple and Stack.Agree(hit.size / n, series.unit) then
                tick = Stack.Tick(series, hit.at, hit.size, n, multiple)
                walk.extended = walk.extended + 1
                if multiple == 1 then walk.ones = walk.ones + 1 end
                walk.gaps[#walk.gaps + 1] = (hit.at - series.at) / multiple
                if n ~= series.n then walk.steps = walk.steps + 1 end
            end
        elseif start then
            tick = Stack.Tick(nil, hit.at, hit.size, n, nil, pattern.period)
            walk.starts[start] = true
        end
        if tick then
            series = tick
            walk.hits[#walk.hits + 1] = hit
            walk.sum = walk.sum + hit.amount
            for _, castAt in ipairs(plate.times) do
                local age = hit.at - castAt
                local live = age >= -EPS and age <= pattern.life + EPS
                if live and not walk.casts[castAt] then walk.casts[castAt] = age end
            end
            -- the next slots, one and two periods on, find an agreeing hit by luck
            local width = 4 * Streams.Slack(series.period)
            local ahead = Stacks(plate.times, hit.at + series.period, pattern.life)
            if ahead > 0 then
                local share = Share(plate.sizes, series.unit * ahead)
                walk.expected = walk.expected + math.min(1, plate.rate * width * share)
            end
        end
    end
end

-- The pattern { low, period, life, walk } walked over every plate of `plates`.
local function Walked(plates, low, period, life)
    local pattern = { low = low, period = period, life = life }
    pattern.walk = { hits = {}, sum = 0, extended = 0, ones = 0, steps = 0, expected = 0, gaps = {}, casts = {},
        starts = {} }
    for _, plate in ipairs(plates) do Walk(plate, pattern, pattern.walk) end

    return pattern
end

-- The best pattern of one cast spell's `plates` (smallest luck past every test), or nil, with the outcome.
local function Best(plates)
    local candidates, tries = {}, 0
    for _, plate in ipairs(plates) do
        local keys = {}
        for _, castAt in ipairs(plate.times) do
            for index, hit in ipairs(plate.list) do
                local delay = hit.at - castAt
                local key = string.format("%.3f", delay)
                if delay > EPS and delay <= WAIT + EPS and not keys[key] then
                    keys[key] = true
                    local period, count, tried = Period(plate.list, index)
                    tries = tries + tried * (LIFE_HI - LIFE_LO + 1)
                    if period and count >= MIN_STEPS then
                        candidates[#candidates + 1] = { low = delay, period = period }
                    end
                end
            end
        end
    end
    local best, luck = nil, nil
    for _, candidate in ipairs(candidates) do
        for life = math.max(LIFE_LO, math.ceil(LIFE_TICKS * candidate.period - EPS)), LIFE_HI do
            local pattern = Walked(plates, candidate.low, candidate.period, life)
            -- A walk that took most of its ticks two periods apart runs on half its series' period: it walks at twice
            -- that, else it learns nothing. Run lock F3: the seed's chain (size-blind) liked 0.734 s, the walk took
            -- all 12 of Unstable Affliction's ticks ~1.47 s apart and learned 0.739: the draw would take hits between.
            local twice = 2 * candidate.period
            if 2 * pattern.walk.ones < pattern.walk.extended and twice <= PERIOD_HI + EPS
                and life >= LIFE_TICKS * twice - EPS then
                pattern = Walked(plates, candidate.low, twice, life)
            end
            local walk, casts = pattern.walk, 0
            for _ in pairs(walk.casts) do casts = casts + 1 end
            local whole = 2 * walk.ones >= walk.extended
            if whole and walk.steps >= MIN_STEPS and casts >= MIN_CASTS and next(walk.starts) then
                local p = math.min(1, ns.Learn.PoissonTail(walk.expected, walk.extended) * tries)
                if p > ALPHA then
                    luck = math.min(luck or p, p)
                elseif not best or p < best.p then
                    pattern.p, pattern.period = p, Median(walk.gaps) or pattern.period
                    best = pattern
                end
            end
        end
    end

    return best, best and "pattern" or luck and string.format("luck=%.2g", luck) or "none"
end

-- Each cast with a stack in a taken tick leaves a sample with the period and the life: one that started a series at
-- its first tick's delay (tick 0: the window), the others tick 1. The starts go last, so the sample cap keeps them.
local function Teach(castID, spellOf, school, pattern)
    local times = {}
    for castAt in pairs(pattern.walk.casts) do times[#times + 1] = castAt end
    table.sort(times)
    for _, starts in ipairs({ false, true }) do
        for _, castAt in ipairs(times) do
            local delay = pattern.walk.casts[castAt]
            if (pattern.walk.starts[castAt] == true) == starts then
                Fingerprints.Add(castID, { school = school, delay = delay, castAt = castAt, hops = 1,
                    spell = spellOf[castAt], tick = starts and 0 or 1, period = pattern.period, life = pattern.life })
            end
        end
    end
end

-- The stack pass of one read. `run` is the fight (its '?' hits and casts, each cast with its plate), `open` and
-- `rewritten` the unpaired rows and the ones paired, `results` the read's verdicts, `learned` the ways learned so far
-- (their hits are spent). Pairs each learned stack with its own row (verdict "under") and returns the new ways
-- { castID, sum, hits }.
function Stack.Learn(run, open, rewritten, results, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local byPlate = {} -- [plate] = { [school] = { hits, oldest first } }
    for _, hit in ipairs(run.unknown) do
        if hit.size and hit.size > 0 and not spent[hit] then
            local schools = byPlate[hit.plate] or {}
            byPlate[hit.plate] = schools
            schools[hit.school] = schools[hit.school] or {}
            table.insert(schools[hit.school], hit)
        end
    end

    -- A cast keys by the row of its own ID (Casts.Rekey's rule): the cast spell's, else its base's.
    local rowOf, timesOf, spellOf, order = {}, {}, {}, {}
    for _, item in ipairs(open) do rowOf[item.row.spellID] = true end
    for _, cast in ipairs(run.casts or {}) do
        local castID = rowOf[cast.spellID] and cast.spellID or rowOf[cast.base] and cast.base
        if castID and cast.plate ~= nil then
            if not timesOf[castID] then
                timesOf[castID], spellOf[castID] = {}, {}
                order[#order + 1] = castID
            end
            timesOf[castID][cast.plate] = timesOf[castID][cast.plate] or {}
            local times = timesOf[castID][cast.plate]
            if times[#times] ~= cast.at then times[#times + 1] = cast.at end
            spellOf[castID][cast.at] = cast.spellID
        end
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local spell, count = nil, 0
        for _, id in pairs(spellOf[castID]) do spell, count = id, count + 1 end
        local free = not Fingerprints.IsLearned(castID) and not ns.Learn.Get(spell) and not ns.Learn.IsKnownIcon(spell)
        local position = Chain.OwnRow(castID, open, rewritten)
        if free and position and count >= MIN_CASTS then
            local best, outcome, school = nil, "none", nil
            local schools, seen = {}, {}
            for plate in pairs(timesOf[castID]) do
                for id in pairs(byPlate[plate] or {}) do
                    if not seen[id] then schools[#schools + 1], seen[id] = id, true end
                end
            end
            table.sort(schools)
            for _, id in ipairs(schools) do
                local plates = {}
                for plate, times in pairs(timesOf[castID]) do
                    local list = byPlate[plate] and byPlate[plate][id]
                    if list and #list >= 2 then
                        local sizes = {}
                        for index, hit in ipairs(list) do sizes[index] = hit.size end
                        table.sort(sizes)
                        local span = math.max(1, list[#list].at - list[1].at)
                        plates[#plates + 1] = { list = list, times = times, sizes = sizes, rate = #list / span }
                    end
                end
                local pattern, result = Best(plates)
                if pattern and (not best or pattern.p < best.p) then
                    best, school = pattern, id
                elseif not best and result ~= "none" then
                    outcome = result
                end
            end
            if best then
                local row = open[position].row
                local tol = math.max(1, row.total / 100)
                if best.walk.sum <= row.total + row.overkill + tol then
                    outcome = "learned"
                    Teach(castID, spellOf[castID], school, best)
                    rewritten[position] = true
                    results[open[position].index] = { spellID = castID, meterID = castID, tally = best.walk.sum,
                        meter = row.total, verdict = "under" }
                    ways[#ways + 1] = { castID = castID, sum = best.walk.sum, hits = best.walk.hits }
                else
                    outcome = "over"
                end
            end
            if ns.Debug then
                local detail = best and string.format(" school=%d first=%.3f+%.1f period=%.3f life=%d ticks=%d "
                    .. "steps=%d exp=%.2f p=%.2g sum=%.0f", school, best.low, SPREAD, best.period, best.life,
                    #best.walk.hits, best.walk.steps, best.walk.expected, best.p, best.walk.sum) or ""
                ns.Debug("TEACH stack %d casts=%d -> %s%s", castID, count, outcome, detail)
            end
        end
    end

    return ways
end
