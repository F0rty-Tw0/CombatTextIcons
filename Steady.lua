-- Combat Text Icons: steady pass. In a long rotation the exact-sum learning of Teacher.lua rarely
-- holds (one lost or extra hit spoils the sum), so after it the teacher asks this pass: did one cast
-- spell leave one '?' hit at a steady delay with a steady size after most of its casts? Every '?'
-- hit keeps its candidate casts (Casts.Candidates). Per cast spell, a window of SPREAD seconds over
-- the hits' delays, in one school, counts each cast whose biggest hit of that school in it has no co-hit of that
-- school within SIZE_SPREAD of its size (a co-hit of another school spoils nothing: Shadow Bolt's frame often holds a
-- 412 s106 proc tick, run 20261025T180045Z); a window qualifies when at least MIN_CASTS and SHARE of the casts count
-- with hits at most SIZE_SPREAD apart (an odd-sized hit leaves its own cast uncounted). Overlapping qualifying
-- windows are one cluster; two clusters teach nothing, unless one of one school sums DOMINANT times
-- each other's (Dominant): it alone teaches. A hit
-- counted for two cast spells or two bases teaches neither. The meter judges last: the counted hits
-- must fit the base's row (total + overkill + tolerance, less what was drawn under it, unless a learned
-- DoT of another school drew it); a base with no row of its own needs every cast counted and the sum to agree
-- with exactly one row of another ID, which it then aliases (OtherRow). Learned
-- hits become fingerprint samples. A base learned before the fight keeps learning the hits it
-- missed (Void Blast in its cast frame, Mind Blast at a new distance): its pairs need its school and
-- the padded size band. A cluster also needs more than luck: a steady '?' stream (two DoT series)
-- puts a like-sized hit in one delay window after 3 of 5 casts by chance (Devouring Plague 335467),
-- so a cluster that a Poisson tail (times the windows tried) cannot tell from luck learns nothing
-- and marks no hit shared. With /cti debug each cast spell seen MIN_CASTS times logs
-- one TEACH steady line.

local _, ns = ...
local Fingerprints, Procs, Casts = ns.Fingerprints, ns.Procs, ns.Casts

local Steady = {}
ns.Steady = Steady

local SPREAD = 0.1      -- a window spans this many seconds of delay
local SHARE = 0.6       -- of a cast spell's casts a window must count
local MIN_CASTS = 3     -- casts a window must count at least
local SIZE_SPREAD = 1.5 -- the biggest counted hit at most this times the smallest
local EPS = 1e-6        -- float slack on window edges
local ALPHA = 0.01      -- a cluster learns when luck alone gives it this often or less (Learn.lua's value)
local WINDOWS = 15      -- delay windows the scan tries (Casts' UNKNOWN_WAIT 1.5 / SPREAD): the multiple comparisons
local DOMINANT = 2      -- one cluster's counted sum at least this times each other's speaks for the cast spell

-- How the pass treats a base this read: "new" (unlearned), "base" (learned before this read: it
-- learns the hits it missed), or nil (learned by this read's exact-sum passes, or a ground spell: skipped). A ground
-- spell's target plate leaves one '?' tick at its first tick's delay per cast, and those samples would push out the
-- tick-tagged ones its period lives in (Ground.lua).
local function Mode(castID, learnedNow)
    if learnedNow[castID] then return nil end
    local fp = Fingerprints.Get(castID)
    if fp and fp.learned and fp.pattern == "ground" then return nil end

    return Fingerprints.IsLearned(castID) and "base" or "new"
end

-- Whether a learned base may take `hit` as a hit of `spell`: in the base's school and inside the
-- padded size band of the spell (Casts.InBand), so DoT ticks and small co-hits in Void Blast's
-- frame are no pairs.
local function BaseFits(castID, spell, hit)
    return hit.school == Fingerprints.Get(castID).school and Casts.InBand(castID, spell, hit.size)
end

-- Whether an unlearned base may take `hit` as a hit of `spell`: with two or more sized samples kept
-- (an exact sum left them), the hit needs their school and their padded size band, so co-hits in the
-- cast frame (Haunt 48181 beside a 1.6K tick, run 20261025T180045Z) are no pairs. Fewer: any hit.
local function NewFits(castID, spell, hit)
    local entry = Fingerprints.Get(castID)
    if not entry then return true end
    local low, high, school, sized
    for _, ofSpell in ipairs({ true, false }) do
        low, high, school, sized = nil, nil, nil, 0
        for _, sample in ipairs(entry.samples) do
            if sample.size and (sample.spell == spell or not ofSpell) then
                if school and sample.school ~= school then return true end
                school, sized = sample.school, sized + 1
                low, high = math.min(low or sample.size, sample.size), math.max(high or sample.size, sample.size)
            end
        end
        if sized > 0 then break end
    end
    if sized < 2 then return true end

    return hit.school == school and Casts.InSizes(low, high, hit.size)
end

-- The considered hits' pairs by cast spell: { castAt, delay, hit }, plus each cast spell's casts
-- (distinct castAt), base and mode.
local function PairsBySpell(hits, learnedNow)
    local pairsOf, castsOf, baseOf, modeOf = {}, {}, {}, {}
    for _, hit in ipairs(hits) do
        for _, candidate in ipairs(hit.candidates) do
            local spell, castID = candidate.castSpell, candidate.castID
            local mode = Mode(castID, learnedNow)
            if mode then
                pairsOf[spell] = pairsOf[spell] or {}
                castsOf[spell] = castsOf[spell] or {}
                baseOf[spell], modeOf[spell] = castID, mode
                castsOf[spell][candidate.castAt] = true
                if (mode == "new" and NewFits(castID, spell, hit)) or (mode == "base" and BaseFits(castID, spell, hit)) then
                    local list = pairsOf[spell]
                    list[#list + 1] = { castAt = candidate.castAt, delay = hit.at - candidate.castAt, hit = hit }
                end
            end
        end
    end

    return pairsOf, castsOf, baseOf, modeOf
end

-- The pairs W(d, school) counts, in pair order: per cast, its biggest pair of `school` whose delay is in
-- [d, d + SPREAD], when it is the only one or more than SIZE_SPREAD times the size of each other one. A co-hit that
-- small is no rival for the size band (Qualifies), a like-sized one is: run shaman5, two of 57984's ~36K hits shared
-- their delay with a ~4K hit, and the window fell those two casts short of the share.
local function Window(list, d, school)
    local perCast, order = {}, {}
    for _, pair in ipairs(list) do
        if pair.hit.school == school and pair.delay >= d - EPS and pair.delay <= d + SPREAD + EPS then
            local cast = perCast[pair.castAt]
            if not cast then
                perCast[pair.castAt] = { top = pair }
                order[#order + 1] = pair.castAt
            elseif pair.hit.size > cast.top.hit.size then
                cast.top, cast.second = pair, cast.top.hit.size
            else
                cast.second = math.max(cast.second or 0, pair.hit.size)
            end
        end
    end
    local counted = {}
    for _, castAt in ipairs(order) do
        local cast = perCast[castAt]
        if not cast.second or cast.top.hit.size > SIZE_SPREAD * cast.second then counted[#counted + 1] = cast.top end
    end

    return counted
end

-- The most pairs of `counted` whose sizes stay within SIZE_SPREAD (tie: the smallest sizes), in pair order, when
-- they are `need` or more, else nil. An odd-sized hit drops out alone: run warrior F1, Shield Slam 23922 hit
-- 0.159-0.167 s after each of 7 casts, ~600-870K normal-scale, but one 204K, and that one kept the window from
-- learning (its 6.1M row of F2 went by as '?').
local function Qualifies(counted, need)
    if #counted < need then return nil end
    local sizes = {}
    for _, pair in ipairs(counted) do sizes[#sizes + 1] = pair.hit.size end
    table.sort(sizes)
    local bestLow, bestCount, first = nil, 0, 1
    for last = 1, #sizes do
        while sizes[last] > SIZE_SPREAD * sizes[first] do first = first + 1 end
        if last - first + 1 > bestCount then bestLow, bestCount = sizes[first], last - first + 1 end
    end
    if bestCount < need then return nil end
    local kept = {}
    for _, pair in ipairs(counted) do
        if pair.hit.size >= bestLow and pair.hit.size <= SIZE_SPREAD * bestLow then kept[#kept + 1] = pair end
    end

    return kept
end

local function Overlaps(hitsA, hitsB)
    for hit in pairs(hitsA) do
        if hitsB[hit] then return true end
    end

    return false
end

-- The qualifying windows of one cast spell joined into clusters (windows whose counted hits overlap,
-- directly or through a chain). Each cluster answers its window with the most counted casts (tie:
-- the smallest d).
local function Clusters(list, need)
    local clusters = {}
    for _, pair in ipairs(list) do
        local counted = Qualifies(Window(list, pair.delay, pair.hit.school), need)
        if counted then
            local merged = { best = { d = pair.delay, counted = counted }, hits = {} }
            for _, item in ipairs(counted) do merged.hits[item.hit] = true end
            for index = #clusters, 1, -1 do
                local other = clusters[index]
                if Overlaps(other.hits, merged.hits) then
                    for hit in pairs(other.hits) do merged.hits[hit] = true end
                    local a, b = merged.best, other.best
                    if #b.counted > #a.counted or (#b.counted == #a.counted and b.d < a.d) then merged.best = b end
                    table.remove(clusters, index)
                end
            end
            clusters[#clusters + 1] = merged
        end
    end

    return clusters
end

local function Count(set)
    local count = 0
    for _ in pairs(set) do count = count + 1 end

    return count
end

-- The meter row of `castID` (its own, or one aliased to it, never a proc's), or nil.
local function RowOf(castID, rows)
    for _, row in ipairs(rows) do
        if (row.spellID == castID or Fingerprints.Alias(row.spellID) == castID) and not Procs.Has(row.spellID) then
            return row
        end
    end
end
Steady.RowOf = RowOf -- the area pass (Area.lua) bounds by the same row

-- Whether the counted hits of `castID` fit its row: total + overkill + Judge's tolerance, less what
-- was drawn under it this fight. A learned DoT of the cast in another school than the hits drew by votes, not by the
-- meter, so its draws take no room: a stale save's Nature DoT under Lava Burst 51505 drew 260K of other Nature hits,
-- and the 6 Fire hits that sum to the row learned nothing until a fight later (run shaman3 start, fight 1).
local function Fits(castID, hits, rows, tally)
    local row = RowOf(castID, rows)
    if not row then return false end
    local dot, sum, dotSchool = ns.Learn.Get(castID), 0, false
    for _, pair in ipairs(hits) do
        sum = sum + pair.hit.amount
        if dot and pair.hit.school == dot.school then dotSchool = true end
    end
    local drawn = (dot and not dotSchool) and 0 or (tally[castID] or 0)
    local room = row.total + row.overkill + math.max(1, row.total / 100) - drawn

    return sum <= room
end

-- The one row of another ID that the counted hits of a cast with no row of its own sum to (Teacher's Judge: within
-- 1 % of the total, overkill above it), or nil. Every cast of the base must count, so the sum is all it dealt on
-- its target. A row owned by a cast of this fight, tracked by Procs, drawn under or aliased is no match. Run dk F11:
-- the meter files Death Coil 47541 under 47632; its 3 casts left one Shadow hit each at 0.125-0.139 s summing to
-- 4105, the row's 4105, and the pass said "meter" for want of a 47541 row (Scourge Strike 55090: row 207311).
local function OtherRow(castID, base, rows, tally, owned)
    local sum = 0
    for _, result in ipairs(base.results) do
        if #result.counted < result.casts then return nil end
    end
    for _, pair in ipairs(base.hits) do sum = sum + pair.hit.amount end
    local found
    for _, row in ipairs(rows) do
        local id, tol = row.spellID, math.max(1, row.total / 100)
        if id ~= castID and not owned[id] and not Procs.Has(id) and not tally[id] and not Fingerprints.Alias(id)
            and sum >= row.total - tol and sum <= row.total + row.overkill + tol then
            if found then return nil end
            found = row
        end
    end

    return found
end

-- How often luck alone gives `counted`'s count: each of `casts` casts finds a hit of the counted
-- school and size range in one window with chance (like hits * SPREAD / span of the fight's '?' hits),
-- the tail of that count, times the WINDOWS tried.
local function Luck(counted, casts, hits, span)
    local school, low, high = counted[1].hit.school, nil, nil
    for _, pair in ipairs(counted) do
        low, high = math.min(low or pair.hit.size, pair.hit.size), math.max(high or pair.hit.size, pair.hit.size)
    end
    local like = 0
    for _, hit in ipairs(hits) do
        if hit.school == school and hit.size >= low and hit.size <= high then like = like + 1 end
    end
    local chance = span > 0 and math.min(1, like / span * SPREAD) or 1

    return math.min(1, ns.Learn.PoissonTail(casts * chance, #counted) * WINDOWS)
end

-- The cluster that speaks for all of `clusters`: the only one, or one whose counted hits sum to DOMINANT times each
-- other's when all share its school, else nil. Run shaman5 fight 1: every Lava Burst 51505 left ~85K crits on its
-- target at 0.20-0.28 s (424K for 5 casts) and ~28K ones at 0.65-0.73 s (150K), the size of the hits its Overload
-- row 285452 holds (~31K on each of 6 dummies a cast); like sums (two hits of one cast) still teach nothing.
local function Dominant(clusters)
    local top, sums = nil, {}
    for index, cluster in ipairs(clusters) do
        if cluster.best.counted[1].hit.school ~= clusters[1].best.counted[1].hit.school then return nil end
        sums[index] = 0
        for _, pair in ipairs(cluster.best.counted) do sums[index] = sums[index] + pair.hit.amount end
        if not top or sums[index] > sums[top] then top = index end
    end
    for index in ipairs(clusters) do
        if index ~= top and sums[top] < DOMINANT * sums[index] then return nil end
    end

    return clusters[top]
end

-- One cast spell's result: { spell, castID, casts, counted (nil without a Dominant cluster, or when luck
-- explains it: then luckCounted), outcome }.
local function SpellResults(hits, learnedNow, span)
    local pairsOf, castsOf, baseOf, modeOf = PairsBySpell(hits, learnedNow)
    local spells = {}
    for spell in pairs(pairsOf) do spells[#spells + 1] = spell end
    table.sort(spells)
    local results = {}
    for _, spell in ipairs(spells) do
        local casts = Count(castsOf[spell])
        local clusters = Clusters(pairsOf[spell], math.max(MIN_CASTS, math.ceil(SHARE * casts - EPS)))
        local result = { spell = spell, castID = baseOf[spell], mode = modeOf[spell], casts = casts, outcome = "none" }
        local dominant = Dominant(clusters)
        if dominant then result.counted = dominant.best.counted end
        if result.counted then
            local p = Luck(result.counted, casts, hits, span)
            if p > ALPHA then
                result.luckCounted, result.counted, result.outcome = result.counted, nil, string.format("luck=%.2g", p)
            end
        end
        if #clusters >= 2 and not dominant then result.outcome = "clusters=" .. #clusters end
        results[#results + 1] = result
    end

    return results
end

-- Marks the outcome of every cast spell with a cluster: "shared" when one of its hits is counted
-- twice (two cast spells or two bases), "meter" when its base's hits do not fit the row (or, with no row of
-- its own, agree with no single row of another ID: OtherRow, kept as `other`), else "learned". Returns the bases
-- that learn, with their counted pairs.
local function Gate(results, rows, run)
    local tally, owned = run.tally, {}
    for _, cast in ipairs(run.casts or {}) do owned[cast.spellID], owned[cast.base] = true, true end
    for _, result in ipairs(results) do owned[result.spell], owned[result.castID] = true, true end
    local owners, byBase = {}, {}
    for _, result in ipairs(results) do
        for _, pair in ipairs(result.counted or {}) do owners[pair.hit] = (owners[pair.hit] or 0) + 1 end
        if result.counted then
            byBase[result.castID] = byBase[result.castID] or { results = {}, hits = {} }
            local base = byBase[result.castID]
            base.results[#base.results + 1] = result
            for _, pair in ipairs(result.counted) do base.hits[#base.hits + 1] = pair end
        end
    end
    for castID, base in pairs(byBase) do
        local outcome = "learned"
        for _, pair in ipairs(base.hits) do
            if owners[pair.hit] > 1 then outcome = "shared" end
        end
        if outcome == "learned" and not Fits(castID, base.hits, rows, tally) then
            base.other = not RowOf(castID, rows) and OtherRow(castID, base, rows, tally, owned)
            if not base.other then outcome = "meter" end
        end
        for _, result in ipairs(base.results) do result.outcome = outcome end
        if outcome ~= "learned" then byBase[castID] = nil end
    end

    return byBase
end

-- "lo-hi" of one field over the counted pairs, or "-".
local function Range(counted, Field)
    if not counted then return "-" end
    local low, high
    for _, pair in ipairs(counted) do
        local value = Field(pair)
        low, high = math.min(low or value, value), math.max(high or value, value)
    end

    return (string.format("%.3f-%.3f", low, high):gsub("%.000", ""))
end

local function Report(results)
    if not ns.Debug then return end
    for _, result in ipairs(results) do
        if result.casts >= MIN_CASTS then
            local counted = result.counted or result.luckCounted
            ns.Debug("TEACH steady %d spell=%d mode=%s counted=%d/%d delay=%s size=%s -> %s", result.castID, result.spell,
                result.mode, counted and #counted or 0, result.casts,
                Range(counted, function(pair) return pair.delay end),
                Range(counted, function(pair) return pair.hit.size end), result.outcome)
        end
    end
end

-- The steady pass of one read. `learned` holds the ways the exact-sum passes learned; their hits
-- are spent and their bases skipped. Adds the samples and returns the new ways { castID, sum, hits }.
function Steady.Learn(run, rows, learned)
    local spent, learnedNow = {}, {}
    for _, way in ipairs(learned) do
        learnedNow[way.castID] = true
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local hits = {}
    for _, hit in ipairs(run.unknown) do
        if hit.size and hit.candidates and not spent[hit] then hits[#hits + 1] = hit end
    end

    local first, last
    for _, hit in ipairs(run.unknown) do
        first, last = math.min(first or hit.at, hit.at), math.max(last or hit.at, hit.at)
    end

    local results = SpellResults(hits, learnedNow, first and last - first or 0)
    local bases = Gate(results, rows, run)
    Report(results)

    local ways, castIDs = {}, {}
    for castID in pairs(bases) do castIDs[#castIDs + 1] = castID end
    table.sort(castIDs)
    for _, castID in ipairs(castIDs) do
        local way = { castID = castID, sum = 0, hits = {} }
        if bases[castID].other then Fingerprints.SetAlias(bases[castID].other.spellID, castID) end
        for _, result in ipairs(bases[castID].results) do
            for _, pair in ipairs(result.counted) do
                local hit = pair.hit
                Fingerprints.Add(castID, { school = hit.school, delay = pair.delay, castAt = pair.castAt, hops = 1,
                    spell = result.spell, size = hit.size })
                way.sum = way.sum + hit.amount
                way.hits[#way.hits + 1] = hit
            end
        end
        ways[#ways + 1] = way
    end

    return ways
end
