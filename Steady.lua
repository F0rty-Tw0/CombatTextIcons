-- Combat Text Icons: steady pass. In a long rotation the exact-sum learning of Teacher.lua rarely
-- holds (one lost or extra hit spoils the sum), so after it the teacher asks this pass: did one cast
-- spell leave one '?' hit at a steady delay with a steady size after most of its casts? Every '?'
-- hit keeps its candidate casts (Casts.Candidates). Per cast spell, a window of SPREAD seconds over
-- the hits' delays counts each cast that has exactly one hit in it; a window qualifies when it counts
-- at least MIN_CASTS and SHARE of the casts, in one school, the biggest hit at most SIZE_SPREAD times
-- the smallest. Overlapping qualifying windows are one cluster; two clusters teach nothing. A hit
-- counted for two cast spells or two bases teaches neither. The meter judges last: the counted hits
-- must fit the base's row (total + overkill + tolerance, less what was drawn under it). Learned
-- hits become fingerprint samples. With /cti debug each cast spell seen MIN_CASTS times logs one
-- TEACH steady line.

local _, ns = ...
local Fingerprints, Procs, Casts = ns.Fingerprints, ns.Procs, ns.Casts

local Steady = {}
ns.Steady = Steady

local SPREAD = 0.1      -- a window spans this many seconds of delay
local SHARE = 0.6       -- of a cast spell's casts a window must count
local MIN_CASTS = 3     -- casts a window must count at least
local SIZE_SPREAD = 1.5 -- the biggest counted hit at most this times the smallest
local EPS = 1e-6        -- float slack on window edges

-- How the pass treats a base this read: "new" (unlearned), or nil (learned, here or before).
local function Mode(castID, learnedNow)
    if learnedNow[castID] or Fingerprints.IsLearned(castID) then return nil end

    return "new"
end

-- The considered hits' pairs by cast spell: { castAt, delay, hit }, plus each cast spell's casts
-- (distinct castAt) and base.
local function PairsBySpell(hits, learnedNow)
    local pairsOf, castsOf, baseOf = {}, {}, {}
    for _, hit in ipairs(hits) do
        for _, candidate in ipairs(hit.candidates) do
            local spell = candidate.castSpell
            if Mode(candidate.castID, learnedNow) then
                pairsOf[spell] = pairsOf[spell] or {}
                castsOf[spell] = castsOf[spell] or {}
                baseOf[spell] = candidate.castID
                castsOf[spell][candidate.castAt] = true
                local list = pairsOf[spell]
                list[#list + 1] = { castAt = candidate.castAt, delay = hit.at - candidate.castAt, hit = hit }
            end
        end
    end

    return pairsOf, castsOf, baseOf
end

-- The pairs W(d) counts: each cast with exactly one pair whose delay is in [d, d + SPREAD], in pair
-- order. nil when the counted hits span two schools.
local function Window(list, d)
    local perCast, order = {}, {}
    for _, pair in ipairs(list) do
        if pair.delay >= d - EPS and pair.delay <= d + SPREAD + EPS then
            if perCast[pair.castAt] == nil then
                perCast[pair.castAt] = pair
                order[#order + 1] = pair.castAt
            else
                perCast[pair.castAt] = false
            end
        end
    end
    local counted, school = {}, nil
    for _, castAt in ipairs(order) do
        local pair = perCast[castAt]
        if pair then
            if school and pair.hit.school ~= school then return nil end
            school = pair.hit.school
            counted[#counted + 1] = pair
        end
    end

    return counted
end

-- Whether `counted` holds `need` casts whose sizes stay within SIZE_SPREAD.
local function Qualifies(counted, need)
    if not counted or #counted < need then return false end
    local low, high
    for _, pair in ipairs(counted) do
        low, high = math.min(low or pair.hit.size, pair.hit.size), math.max(high or pair.hit.size, pair.hit.size)
    end

    return high <= SIZE_SPREAD * low
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
        local counted = Window(list, pair.delay)
        if Qualifies(counted, need) then
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

-- Whether the counted hits of `castID` fit its row: total + overkill + Judge's tolerance, less what
-- was drawn under it this fight.
local function Fits(castID, hits, rows, tally)
    local row = RowOf(castID, rows)
    if not row then return false end
    local sum = 0
    for _, pair in ipairs(hits) do sum = sum + pair.hit.amount end
    local room = row.total + row.overkill + math.max(1, row.total / 100) - (tally[castID] or 0)

    return sum <= room
end

-- One cast spell's result: { spell, castID, casts, counted (nil without one cluster), outcome }.
local function SpellResults(hits, learnedNow)
    local pairsOf, castsOf, baseOf = PairsBySpell(hits, learnedNow)
    local spells = {}
    for spell in pairs(pairsOf) do spells[#spells + 1] = spell end
    table.sort(spells)
    local results = {}
    for _, spell in ipairs(spells) do
        local casts = Count(castsOf[spell])
        local clusters = Clusters(pairsOf[spell], math.max(MIN_CASTS, math.ceil(SHARE * casts - EPS)))
        local result = { spell = spell, castID = baseOf[spell], casts = casts, outcome = "none" }
        if #clusters == 1 then result.counted = clusters[1].best.counted end
        if #clusters >= 2 then result.outcome = "clusters=" .. #clusters end
        results[#results + 1] = result
    end

    return results
end

-- Marks the outcome of every cast spell with a cluster: "shared" when one of its hits is counted
-- twice (two cast spells or two bases), "meter" when its base's hits do not fit the row, else
-- "learned". Returns the bases that learn, with their counted pairs.
local function Gate(results, rows, tally)
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
        if outcome == "learned" and not Fits(castID, base.hits, rows, tally) then outcome = "meter" end
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
            ns.Debug("TEACH steady %d spell=%d mode=new counted=%d/%d delay=%s size=%s -> %s", result.castID, result.spell,
                result.counted and #result.counted or 0, result.casts,
                Range(result.counted, function(pair) return pair.delay end),
                Range(result.counted, function(pair) return pair.hit.size end), result.outcome)
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

    local results = SpellResults(hits, learnedNow)
    local bases = Gate(results, rows, run.tally)
    Report(results)

    local ways, castIDs = {}, {}
    for castID in pairs(bases) do castIDs[#castIDs + 1] = castID end
    table.sort(castIDs)
    for _, castID in ipairs(castIDs) do
        local way = { castID = castID, sum = 0, hits = {} }
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
