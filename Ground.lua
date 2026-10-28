-- Combat Text Icons: ground pass. A ground spell is a cast with no meter row of its own, then a patch on the floor
-- that hits every plate in it once a period, for a few ticks; its damage sits in a row of another ID. Run shaman5
-- fight 1: Earthquake 462620 has no row; each cast's first tick lands ~1.02 s later on 5 plates, then one every
-- ~0.98 s, 6 ticks, normals 6.2-7.3K and crits ~3x, all in row 77478 (2279208). No other pass learns it: Steady wants
-- one hit per cast, a cast's window is 1.5 s, and no sum can agree with the row, since ticks on mobs with no plate
-- never show (the plated ticks sum to ~1.74M).
-- The proof: per rowless cast spell and school, a seed frame (MIN_PLATES plates of like-sized normal hits within WAIT
-- of a cast) gives a first-tick delay window of SPREAD and a size band; the casts with such a frame there (SHARE of
-- them, MIN_CASTS at least) give the period, the gap that puts a wide frame (MIN_PLATES plates in the band) one and
-- two periods after the most first ticks. Each cast is then walked as the draw route walks it (Casts.lua): its first
-- tick in the window, each later one a period after the last tick seen within the slack, MISSES missed in a row end
-- it; the median walk gives the ticks. The walk must beat luck: its wide frames against a Poisson count from the
-- fight's rate of wide frames in the band, times the TRIES tried. A stream already running one period before the
-- first tick of half the casts is no ground spell: a pet or totem stream steps with any cast that starts on it.
-- The meter judges last, as a bound: the band hits the walks take (D) fit exactly one open row that no cast of this
-- fight owns, no proc tracks and no other cast is aliased to, with D <= row and row - D <= the fight's unseen damage
-- (meter total - seen): every hit on a plate was seen, so what the row holds past D is unseen damage or D's misses.
-- Fight 1: rows of at least D are 188443 and 51505 (cast this fight) and 77478 alone. Learned, the cast spell keeps
-- samples tagged by tick (Fingerprints.lua) and the row is aliased to it; with /cti debug each tried spell logs one
-- TEACH ground line.

local _, ns = ...
local Fingerprints, Procs, Streams, Casts = ns.Fingerprints, ns.Procs, ns.Streams, ns.Casts

local Ground = {}
ns.Ground = Ground

local MIN_PLATES = 3     -- plates a wide frame hits at least
local MIN_CASTS = 3      -- casts with a first tick at least (Steady's)
local SHARE = 0.6        -- of a cast spell's casts the first ticks must cover (Steady's)
local WAIT = 1.5         -- a first tick lands at most this long after its cast (Casts' UNKNOWN_WAIT)
local SPREAD = 0.3       -- the first ticks' delay window: shaman5 F3 Earthquake first ticks at 0.82-1.11 s
local SIZE_SPREAD = 1.5  -- the biggest first-tick hit at most this times the smallest (Steady's)
local PERIOD_LO, PERIOD_HI = 0.5, 3 -- a period lies in this range
local MISSES = 2         -- missed ticks in a row that end a walk
local TICKS_MAX = 30     -- a walk tries at most this many ticks
local ALPHA = 0.01       -- the walk learns when luck alone gives it this often or less (Learn.lua's value)
local TRIES = 900        -- seeds the scan tries: 5 delay windows x 14 size classes (x1.5, 1K-300K) x 13 periods
local EPS = 1e-6

-- A tick lands within this of a period after the last one: Streams' max(0.1, 0.15 * period).
function Ground.Slack(period) return math.max(0.1, 0.15 * period) end

local function Median(list)
    if #list == 0 then return nil end
    table.sort(list)

    return list[math.ceil(#list / 2)]
end

-- The '?' hits of `hits` grouped by frame and school, oldest first: { at, school, hits }.
local function Frames(hits)
    local byKey, list = {}, {}
    for _, hit in ipairs(hits) do
        local key = hit.at .. ":" .. hit.school
        local frame = byKey[key]
        if not frame then
            frame = { at = hit.at, school = hit.school, hits = {} }
            byKey[key] = frame
            list[#list + 1] = frame
        end
        frame.hits[#frame.hits + 1] = hit
    end
    table.sort(list, function(a, b)
        if a.at ~= b.at then return a.at < b.at end

        return a.school < b.school
    end)

    return list
end

-- The most plates whose normal hits in `frame` lie within Streams.SIZE_GUARD of the smallest of them, with their
-- smallest and biggest size. Crits are left out: Earthquake's are ~3x its normals, past Streams.CRIT_HI.
local function Like(frame)
    local best, low, high = 0, nil, nil
    for _, anchor in ipairs(frame.hits) do
        if anchor.crit ~= true then
            local top, plates, count, big = anchor.size / (1 - Streams.SIZE_GUARD), {}, 0, anchor.size
            for _, hit in ipairs(frame.hits) do
                if hit.crit ~= true and hit.size >= anchor.size and hit.size <= top then
                    if not plates[hit.plate] then plates[hit.plate], count = true, count + 1 end
                    big = math.max(big, hit.size)
                end
            end
            if count > best then best, low, high = count, anchor.size, big end
        end
    end

    return best, low, high
end

-- The hits of `frame` in the padded band `low`-`high` (Casts.InSizes, crits on their normal scale) and their plates.
local function InBand(frame, low, high)
    local hits, plates, count = {}, {}, 0
    for _, hit in ipairs(frame.hits) do
        if Casts.InSizes(low, high, hit.size) then
            hits[#hits + 1] = hit
            if not plates[hit.plate] then plates[hit.plate], count = true, count + 1 end
        end
    end

    return hits, count
end

-- Whether `size` lies within Streams.SIZE_GUARD of the sizes `low`-`high` (Casts' NearSizes): a tick is anchored
-- only by such a normal hit. Shaman5 F3: a 14.4K stream (2 hits on each of 5 plates) in Earthquake's padded band
-- (6.3-7.3K learned) took a cast's first-tick window and then every tick of it at 0.95 s; three 16.5K crits on one
-- plate (200335.220, 8.2K halved: Earthquake's crits are ~3x) took the next cast's first tick from its real one.
local function Near(low, high, size)
    local guard = 1 - Streams.SIZE_GUARD

    return size >= guard * low and size * guard <= high
end

-- The frames of `school` with a hit in the band, each { at, hits (in band), wide, anchor (a normal hit Near) }, oldest
-- first.
local function BandFrames(frames, school, low, high)
    local list = {}
    for _, frame in ipairs(frames) do
        if frame.school == school then
            local hits, plates = InBand(frame, low, high)
            local anchor = false
            for _, hit in ipairs(hits) do anchor = anchor or hit.crit ~= true and Near(low, high, hit.size) end
            if #hits > 0 then
                list[#list + 1] = { at = frame.at, hits = hits, wide = plates >= MIN_PLATES, anchor = anchor }
            end
        end
    end

    return list
end

-- The frame of `list` closest to `at` in [from, to] (`wide` only when asked), or nil.
local function Find(list, from, to, at, wide)
    local best
    for _, frame in ipairs(list) do
        local inside = frame.at >= from - EPS and frame.at <= to + EPS and (frame.wide or not wide)
        if inside and (not best or math.abs(frame.at - at) < math.abs(best.at - at)) then best = frame end
    end

    return best
end

-- The oldest frame of `list` in [from, to] that a normal hit Near anchors, or nil: the draw route takes the first one
-- it meets.
local function Earliest(list, from, to)
    for _, frame in ipairs(list) do
        if frame.anchor and frame.at >= from - EPS and frame.at <= to + EPS then return frame end
    end
end

-- One cast's walk over the band frames, as the draw route claims: { castAt, ticks = { { k, frame } }, tried }.
local function Walk(castAt, pattern, list, limit)
    local slack = Ground.Slack(pattern.period)
    local middle = castAt + (pattern.first + pattern.last) / 2
    local first = Earliest(list, castAt + pattern.first - slack, castAt + pattern.last + slack)
    local walk = { castAt = castAt, ticks = {}, tried = 1 }
    local anchorAt, anchorK = middle, 0
    if first then
        walk.ticks[1] = { k = 0, frame = first }
        anchorAt = first.at
    end
    for k = 1, limit - 1 do
        local due = anchorAt + (k - anchorK) * pattern.period
        local frame = Earliest(list, due - slack, due + slack)
        walk.tried = walk.tried + 1
        if frame then
            walk.ticks[#walk.ticks + 1] = { k = k, frame = frame }
            anchorAt, anchorK = frame.at, k
        elseif k - anchorK >= MISSES then
            break
        end
    end

    return walk
end

-- The period that puts a wide band frame one and two periods after the most first ticks (ties: the shortest).
local function Period(firsts, list)
    local gaps = {}
    for _, first in ipairs(firsts) do
        for _, frame in ipairs(list) do
            local gap = frame.at - first.at
            if frame.wide and gap >= PERIOD_LO - EPS and gap <= PERIOD_HI + EPS then gaps[#gaps + 1] = gap end
        end
    end
    table.sort(gaps)
    local best, bestCount = nil, 0
    for _, gap in ipairs(gaps) do
        local slack, count = Ground.Slack(gap), 0
        for _, first in ipairs(firsts) do
            local once = Find(list, first.at + gap - slack, first.at + gap + slack, first.at + gap, true)
            local twice = Find(list, first.at + 2 * gap - slack, first.at + 2 * gap + slack, first.at + 2 * gap, true)
            if once and twice then count = count + 1 end
        end
        if count > bestCount then best, bestCount = gap, count end
    end

    return best, bestCount
end

-- The walks' own period: the median of each step between two ticks (its time / its ticks).
local function Steps(walks)
    local steps = {}
    for _, walk in ipairs(walks) do
        for index = 2, #walk.ticks do
            local older, newer = walk.ticks[index - 1], walk.ticks[index]
            steps[#steps + 1] = (newer.frame.at - older.frame.at) / (newer.k - older.k)
        end
    end

    return Median(steps)
end

-- How often luck alone gives the walks' wide ticks: each tried tick finds a wide band frame with chance (the fight's
-- rate of them * the tick's window), the Poisson tail of that count, times TRIES.
local function Luck(walks, pattern, list, span)
    local wideFrames, wideTicks, expected = 0, 0, 0
    for _, frame in ipairs(list) do
        if frame.wide then wideFrames = wideFrames + 1 end
    end
    local rate = span > 0 and wideFrames / span or math.huge
    local slack = Ground.Slack(pattern.period)
    for _, walk in ipairs(walks) do
        for _, tick in ipairs(walk.ticks) do
            if tick.frame.wide then wideTicks = wideTicks + 1 end
        end
        local firstWindow = math.min(1, rate * (pattern.last - pattern.first + 2 * slack))
        expected = expected + firstWindow + (walk.tried - 1) * math.min(1, rate * 2 * slack)
    end

    return math.min(1, ns.Learn.PoissonTail(expected, wideTicks) * TRIES)
end

-- Whether a wide band frame lands one period before the first tick of half the anchored walks or more.
local function Running(walks, pattern, list)
    local slack, anchored, before = Ground.Slack(pattern.period), 0, 0
    for _, walk in ipairs(walks) do
        local first = walk.ticks[1]
        if first and first.k == 0 then
            anchored = anchored + 1
            local due = first.frame.at - pattern.period
            if Find(list, due - slack, due + slack, due, true) then before = before + 1 end
        end
    end

    return 2 * before >= anchored
end

-- The seeds of one cast spell: a frame of MIN_PLATES like-sized normal plates within WAIT of a cast; each gives the
-- casts with a like frame in its delay window, earliest per cast: { school, low, high, firsts = { at, delay } }.
local function Seeds(castTimes, frames)
    local candidates = {}
    for _, castAt in ipairs(castTimes) do
        for _, frame in ipairs(frames) do
            local delay = frame.at - castAt
            if delay >= 0 and delay <= WAIT then
                local plates, low, high = Like(frame)
                if plates >= MIN_PLATES then
                    candidates[#candidates + 1] = { castAt = castAt, delay = delay, frame = frame, low = low,
                        high = high }
                end
            end
        end
    end
    local seeds = {}
    for _, seed in ipairs(candidates) do
        local byCast, low, high = {}, seed.low, seed.high
        for _, other in ipairs(candidates) do
            local inWindow = other.frame.school == seed.frame.school and other.delay >= seed.delay - EPS
                and other.delay <= seed.delay + SPREAD + EPS
            local like = math.max(other.high, seed.high) <= SIZE_SPREAD * math.min(other.low, seed.low)
            local earlier = byCast[other.castAt] and byCast[other.castAt].delay <= other.delay
            if inWindow and like and not earlier then byCast[other.castAt] = other end
        end
        local firsts = {}
        for _, castAt in ipairs(castTimes) do
            local first = byCast[castAt]
            if first then
                firsts[#firsts + 1] = { at = first.frame.at, delay = first.delay }
                low, high = math.min(low, first.low), math.max(high, first.high)
            end
        end
        seeds[#seeds + 1] = { school = seed.frame.school, low = low, high = high, firsts = firsts }
    end

    return seeds
end

-- The best pattern of one cast spell (smallest luck past every test), or nil, with the outcome for the report.
local function Best(castTimes, frames, span)
    local need = math.max(MIN_CASTS, math.ceil(SHARE * #castTimes - EPS))
    local best, outcome = nil, "none"
    for _, seed in ipairs(Seeds(castTimes, frames)) do
        if #seed.firsts >= need and seed.high <= SIZE_SPREAD * seed.low then
            local list = BandFrames(frames, seed.school, seed.low, seed.high)
            local period, count = Period(seed.firsts, list)
            if period and count >= need then
                local first, last
                for _, item in ipairs(seed.firsts) do
                    first, last = math.min(first or item.delay, item.delay), math.max(last or item.delay, item.delay)
                end
                local pattern = { school = seed.school, low = seed.low, high = seed.high, period = period,
                    first = first, last = last }
                local walks, lengths = {}, {}
                for index, castAt in ipairs(castTimes) do walks[index] = Walk(castAt, pattern, list, TICKS_MAX) end
                pattern.period = Steps(walks) or period
                for _, castAt in ipairs(castTimes) do
                    local walk = Walk(castAt, pattern, list, TICKS_MAX)
                    if walk.ticks[1] and walk.ticks[1].k == 0 then
                        lengths[#lengths + 1] = walk.ticks[#walk.ticks].k + 1
                    end
                end
                pattern.ticks = Median(lengths) or 0
                for index, castAt in ipairs(castTimes) do walks[index] = Walk(castAt, pattern, list, pattern.ticks) end
                pattern.walks, pattern.p = walks, Luck(walks, pattern, list, span)
                if pattern.ticks < 2 then
                    outcome = outcome == "none" and "ticks" or outcome
                elseif pattern.p > ALPHA then
                    outcome = string.format("luck=%.2g", pattern.p)
                elseif Running(walks, pattern, list) then
                    outcome = "running"
                elseif not best or pattern.p < best.p then
                    best = pattern
                end
            end
        end
    end

    return best, best and "pattern" or outcome
end

-- The hits the walks take, each once, and their sum.
local function Taken(pattern)
    local hits, seen, sum = {}, {}, 0
    for _, walk in ipairs(pattern.walks) do
        for _, tick in ipairs(walk.ticks) do
            for _, hit in ipairs(tick.frame.hits) do
                if not seen[hit] then
                    seen[hit], sum = true, sum + hit.amount
                    hits[#hits + 1] = hit
                end
            end
        end
    end

    return hits, sum
end

-- The open rows (`open` positions not `rewritten`) that bound `sum`: no proc tracks it, no cast of this fight owns its
-- ID (`owned`), no cast spell is aliased to it, sum <= total + overkill + tolerance and total <= sum + unseen +
-- tolerance. Returns the positions.
local function Bounds(sum, open, rewritten, owned, unseen)
    local positions = {}
    for position, item in ipairs(open) do
        local row = item.row
        local tol = math.max(1, row.total / 100)
        local free = not rewritten[position] and not Procs.Has(row.spellID) and not owned[row.spellID]
            and not Fingerprints.Alias(row.spellID)
        if free and sum <= row.total + row.overkill + tol and row.total <= sum + unseen + tol then
            positions[#positions + 1] = position
        end
    end

    return positions
end

-- Each walked cast leaves two samples: its first tick (tick 0, the smallest normal size its ticks took) and its last
-- (its tick index, the biggest), so the kept samples hold the delay window, the period, the ticks and the band.
local function Teach(castID, castSpell, pattern)
    for _, walk in ipairs(pattern.walks) do
        local first, last = walk.ticks[1], walk.ticks[#walk.ticks]
        if first and first.k == 0 and last.k > 0 then
            local small, big
            for _, tick in ipairs(walk.ticks) do
                for _, hit in ipairs(tick.frame.hits) do
                    if hit.crit ~= true and Near(pattern.low, pattern.high, hit.size) then
                        small, big = math.min(small or hit.size, hit.size), math.max(big or hit.size, hit.size)
                    end
                end
            end
            local castAt = walk.castAt
            Fingerprints.Add(castID, { school = pattern.school, delay = first.frame.at - castAt, castAt = castAt,
                hops = 1, spell = castSpell, size = small, tick = 0 })
            Fingerprints.Add(castID, { school = pattern.school, delay = last.frame.at - castAt, castAt = castAt,
                hops = 1, spell = castSpell, size = big, tick = last.k })
        end
    end
end

-- The ground pass of one read. `run` is the fight (its '?' hits, casts and seen), `rows` the session's rows, `open`
-- and `rewritten` the cast pass's unpaired rows and the ones it paired, `results` the read's verdicts, `learned` the
-- ways learned so far (their hits are spent). Pairs each learned pattern's row (alias, verdict "under") and returns
-- the new ways { castID, sum, hits }.
function Ground.Learn(run, rows, open, rewritten, results, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local hits, first, last = {}, nil, nil
    for _, hit in ipairs(run.unknown) do
        first, last = math.min(first or hit.at, hit.at), math.max(last or hit.at, hit.at)
        if hit.size and hit.size > 0 and not spent[hit] then hits[#hits + 1] = hit end
    end
    local frames = Frames(hits)

    local owned, total = {}, 0
    for _, row in ipairs(rows) do total = total + row.total end
    local timesOf, spellOf, order = {}, {}, {}
    for _, cast in ipairs(run.casts or {}) do
        owned[cast.spellID], owned[cast.base] = true, true
        if not timesOf[cast.base] then
            timesOf[cast.base] = {}
            order[#order + 1] = cast.base
        end
        local times = timesOf[cast.base]
        if times[#times] ~= cast.at then times[#times + 1] = cast.at end
        spellOf[cast.base] = cast.spellID
    end
    table.sort(order)
    local rowOf = {}
    for _, row in ipairs(rows) do rowOf[row.spellID] = true end

    local found = {}
    for _, castID in ipairs(order) do
        local spell = spellOf[castID]
        local rowless = not rowOf[castID] and not rowOf[spell]
        local free = not Fingerprints.IsLearned(castID) and not ns.Learn.Get(spell) and not ns.Learn.IsKnownIcon(spell)
        if rowless and free and #timesOf[castID] >= MIN_CASTS then
            local pattern, outcome = Best(timesOf[castID], frames, first and last - first or 0)
            if pattern then
                pattern.castID, pattern.spell = castID, spell
                pattern.hits, pattern.sum = Taken(pattern)
                pattern.rows = Bounds(pattern.sum, open, rewritten, owned, math.max(0, total - run.seen))
                found[#found + 1] = pattern
                outcome = #pattern.rows == 1 and "learned" or ("rows=" .. #pattern.rows)
            end
            if ns.Debug then
                local detail = pattern and string.format(
                    " school=%d size=%.0f-%.0f first=%.3f-%.3f period=%.3f ticks=%d p=%.2g sum=%.0f", pattern.school,
                    pattern.low, pattern.high, pattern.first, pattern.last, pattern.period, pattern.ticks, pattern.p,
                    pattern.sum) or ""
                ns.Debug("TEACH ground %d casts=%d -> %s%s", castID, #timesOf[castID], outcome, detail)
            end
        end
    end

    local claims = {}
    for _, pattern in ipairs(found) do
        if #pattern.rows == 1 then claims[pattern.rows[1]] = (claims[pattern.rows[1]] or 0) + 1 end
    end
    local ways = {}
    for _, pattern in ipairs(found) do
        local position = #pattern.rows == 1 and pattern.rows[1]
        if position and claims[position] == 1 then
            local item = open[position]
            Teach(pattern.castID, pattern.spell, pattern)
            Fingerprints.SetAlias(item.row.spellID, pattern.castID)
            rewritten[position] = true
            results[item.index] = { spellID = pattern.castID, meterID = item.row.spellID, tally = pattern.sum,
                meter = item.row.total, verdict = "under" }
            ways[#ways + 1] = { castID = pattern.castID, sum = pattern.sum, hits = pattern.hits }
        end
    end

    return ways
end
