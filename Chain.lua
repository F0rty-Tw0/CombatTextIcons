-- Combat Text Icons: chain pass. A chain spell's cast hits its target, then hops to a new plate every ~0.1 s; the
-- meter files it under the cast's own row, with hits no plate shows. Run shaman5 fight 1: Chain Lightning 188443's
-- hard casts (200221.723, 200223.529, 200226.687, 200234.315) hit the target 0.20-0.22 s after the cast, then one new
-- plate every 0.08-0.12 s, 5 plates, 11K normals and 34-36K crits. No sum agrees with its row (2550570): the row also
-- holds each cast's overload chains (cast 200221.723: a second chain of 12-13K from the target at 0.41 s, interleaved)
-- and the instant casts, whose hits land on every plate in the cast's own frame.
-- The proof: per cast spell with its own open row and school, a seed window of SPREAD from each delay of a hit on the
-- cast's plate within WAIT; each cast is walked as the draw route walks a chain (Casts.lua): its first hit on its plate
-- in the window, then each hop the oldest like-sized hit on a new plate within Casts.CHAIN_GAP of the last,
-- Casts.CHAIN_MAX hits at most, but here in a later frame only: a burst on every plate in one frame (Earthquake's
-- ticks, Voltaic Blaze) is no chain. The hops must beat luck: each tried hop finds one by luck with the fight's share
-- of hits that a like hit on another plate follows that way (0.22 in fight 1), Poisson tail times the seeds tried.
-- The meter bounds from below only: the hits the chained walks take (D) are at most the row. The row holds more than
-- the walks can take (the overload chains, the instant casts, the hops on mobs with no plate), so row - D bounds
-- nothing: fight 1 walks 5 chains (D 527541) and row - D is 2.02M, past the fight's unseen damage (1.90M). Learned,
-- each chained cast keeps two samples at its first hit's delay (a hop's delay is no window delay), the smallest and the
-- biggest size it took, the second with its hops. With /cti debug each tried spell logs one TEACH chain line.

local _, ns = ...
local Fingerprints, Procs, Casts = ns.Fingerprints, ns.Procs, ns.Casts

local Chain = {}
ns.Chain = Chain

local MIN_CASTS = 3   -- chained casts at least (Steady's)
local MIN_HOPS = 2    -- hops a chained cast takes at least: 3 plates
local WAIT = 1.5      -- a first hit lands at most this long after its cast (Casts' UNKNOWN_WAIT)
local SPREAD = 0.3    -- the first hits' delay window (Ground's)
local LIKE = 2        -- a hop's normal-scale size is within this factor of the first hit's: Chain Lightning's crits are
                      -- ~3.1x its normals (36K over 11K), 1.6x on that scale
local ALPHA = 0.01    -- the walks learn when luck alone gives them this often or less (Learn.lua's value)
local EPS = 1e-6

local function Like(a, b) return math.max(a, b) <= LIKE * math.min(a, b) end

-- The share of `list` (one school's sized '?' hits, oldest first) that a Like hit on another plate follows in a later
-- frame within Casts.CHAIN_GAP: the chance a tried hop finds one by luck.
local function HopRate(list)
    if #list == 0 then return 1 end
    local found = 0
    for index, hit in ipairs(list) do
        for later = index + 1, #list do
            local other = list[later]
            local gap = other.at - hit.at
            if gap > Casts.CHAIN_GAP + EPS then break end
            if gap > EPS and other.plate ~= hit.plate and Like(hit.size, other.size) then
                found = found + 1
                break
            end
        end
    end

    return found / #list
end

-- One cast's walk as the draw route takes it: { cast, hits, tried } (tried: the hops looked for). `cast.own` holds
-- the cast's '?' hits on its plate, `list` the school's, both oldest first; `at` maps a hit to its place in `list`.
local function Walk(cast, school, low, list, at)
    local walk, first = { cast = cast, hits = {}, tried = 0 }, nil
    for _, hit in ipairs(cast.own) do
        local delay = hit.at - cast.at
        if hit.school == school and delay >= low - EPS and delay <= low + SPREAD + EPS then
            first = hit
            break
        end
    end
    if not first then return walk end
    walk.hits[1] = first
    local plates, last = { [first.plate] = true }, first
    while #walk.hits < Casts.CHAIN_MAX do
        walk.tried = walk.tried + 1
        local hop
        for index = at[last] + 1, #list do
            local hit = list[index]
            local gap = hit.at - last.at
            if gap > Casts.CHAIN_GAP + EPS then break end
            if gap > EPS and not plates[hit.plate] and Like(first.size, hit.size) then
                hop = hit
                break
            end
        end
        if not hop then break end
        walk.hits[#walk.hits + 1] = hop
        plates[hop.plate], last = true, hop
    end

    return walk
end

-- The best pattern of one cast spell (smallest luck past every test), or nil, with the outcome for the report. `casts`
-- are { at, own }, `lists` and `rates` per school, `at` maps a hit to its place in its school's list.
local function Best(casts, lists, rates, at)
    local seeds, keys = {}, {}
    for _, cast in ipairs(casts) do
        for _, hit in ipairs(cast.own) do
            local delay = hit.at - cast.at
            local key = hit.school .. ":" .. delay
            if lists[hit.school] and delay >= -EPS and delay <= WAIT + EPS and not keys[key] then
                keys[key] = true
                seeds[#seeds + 1] = { school = hit.school, low = delay }
            end
        end
    end
    local best, luck = nil, nil
    for _, seed in ipairs(seeds) do
        local walks, chained, hops, expected = {}, 0, 0, 0
        for index, cast in ipairs(casts) do
            local walk = Walk(cast, seed.school, seed.low, lists[seed.school], at)
            walks[index] = walk
            if #walk.hits - 1 >= MIN_HOPS then chained = chained + 1 end
            hops = hops + math.max(0, #walk.hits - 1)
            expected = expected + walk.tried * rates[seed.school]
        end
        if chained >= MIN_CASTS then
            local p = math.min(1, ns.Learn.PoissonTail(expected, hops) * #seeds)
            if p > ALPHA then
                luck = math.min(luck or p, p)
            elseif not best or p < best.p then
                best = { school = seed.school, low = seed.low, walks = walks, p = p, hops = hops,
                    expected = expected }
            end
        end
    end

    return best, best and "pattern" or luck and string.format("luck=%.2g", luck) or "none"
end

-- The walks with MIN_HOPS hops or more, the hits they take and their sum.
local function Taken(pattern)
    local chained, hits, sum = {}, {}, 0
    for _, walk in ipairs(pattern.walks) do
        if #walk.hits - 1 >= MIN_HOPS then
            chained[#chained + 1] = walk
            for _, hit in ipairs(walk.hits) do
                hits[#hits + 1] = hit
                sum = sum + hit.amount
            end
        end
    end

    return chained, hits, sum
end

-- Each chained walk leaves two samples at its first hit's delay: the smallest size it took (hops 1) and the biggest
-- (its hit count as hops: 2 or more makes the entry a chain).
local function Teach(castID, pattern)
    for _, walk in ipairs(pattern.chained) do
        local small, big
        for _, hit in ipairs(walk.hits) do
            small, big = math.min(small or hit.size, hit.size), math.max(big or hit.size, hit.size)
        end
        local cast = walk.cast
        local delay = walk.hits[1].at - cast.at
        Fingerprints.Add(castID, { school = pattern.school, delay = delay, castAt = cast.at, hops = 1,
            spell = cast.spellID, size = small })
        Fingerprints.Add(castID, { school = pattern.school, delay = delay, castAt = cast.at, hops = #walk.hits,
            spell = cast.spellID, size = big })
    end
end

-- The open row of `castID` (its own ID) that no pass rewrote, no proc tracks and no other cast is aliased to: its
-- position, or nil.
local function OwnRow(castID, open, rewritten)
    for position, item in ipairs(open) do
        local row = item.row
        if row.spellID == castID and not rewritten[position] and not Procs.Has(castID)
            and not Fingerprints.Alias(castID) then
            return position
        end
    end
end

-- The chain pass of one read. `run` is the fight (its '?' hits and casts), `open` and `rewritten` the cast pass's
-- unpaired rows and the ones paired, `results` the read's verdicts, `learned` the ways learned so far (their hits are
-- spent). Pairs each learned chain with its own row (verdict "under") and returns the new ways { castID, sum, hits }.
function Chain.Learn(run, open, rewritten, results, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local lists, at, ownOf = {}, {}, {}
    for _, hit in ipairs(run.unknown) do
        if hit.size and hit.size > 0 and not spent[hit] then
            local list = lists[hit.school] or {}
            lists[hit.school] = list
            list[#list + 1] = hit
            at[hit] = #list
            for _, candidate in ipairs(hit.candidates or {}) do
                local key = tostring(candidate.castSpell) .. "@" .. candidate.castAt
                ownOf[key] = ownOf[key] or {}
                table.insert(ownOf[key], hit)
            end
        end
    end
    local rates = {}
    for school, list in pairs(lists) do rates[school] = HopRate(list) end

    -- A cast keys by the row of its own ID (Casts.Rekey's rule): the cast spell's, else its base's.
    local rowOf, castsOf, order = {}, {}, {}
    for _, item in ipairs(open) do rowOf[item.row.spellID] = true end
    for _, cast in ipairs(run.casts or {}) do
        local castID = rowOf[cast.spellID] and cast.spellID or rowOf[cast.base] and cast.base
        if castID then
            if not castsOf[castID] then
                castsOf[castID] = {}
                order[#order + 1] = castID
            end
            local list = castsOf[castID]
            if not (list[#list] and list[#list].at == cast.at) then
                list[#list + 1] = { at = cast.at, spellID = cast.spellID,
                    own = ownOf[cast.spellID .. "@" .. cast.at] or {} }
            end
        end
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local casts = castsOf[castID]
        local spell = casts[1].spellID
        local free = not Fingerprints.IsLearned(castID) and not ns.Learn.Get(spell) and not ns.Learn.IsKnownIcon(spell)
        local position = OwnRow(castID, open, rewritten)
        if free and position and #casts >= MIN_CASTS then
            local pattern, outcome = Best(casts, lists, rates, at)
            if pattern then
                pattern.chained, pattern.hits, pattern.sum = Taken(pattern)
                local row = open[position].row
                local tol = math.max(1, row.total / 100)
                if pattern.sum <= row.total + row.overkill + tol then
                    outcome = "learned"
                    Teach(castID, pattern)
                    rewritten[position] = true
                    results[open[position].index] = { spellID = castID, meterID = castID, tally = pattern.sum,
                        meter = row.total, verdict = "under" }
                    ways[#ways + 1] = { castID = castID, sum = pattern.sum, hits = pattern.hits }
                else
                    outcome = "over"
                end
            end
            if ns.Debug then
                local detail = pattern and string.format(" school=%d first=%.3f+%.1f chains=%d hops=%d rate=%.2f "
                    .. "exp=%.2f p=%.2g sum=%.0f", pattern.school, pattern.low, SPREAD, #pattern.chained, pattern.hops,
                    rates[pattern.school], pattern.expected, pattern.p, pattern.sum) or ""
                ns.Debug("TEACH chain %d casts=%d -> %s%s", castID, #casts, outcome, detail)
            end
        end
    end

    return ways
end
