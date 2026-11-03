-- Combat Text Icons: train pass. A cast whose own hit is learned (a fingerprint) may also leave a DoT on its target
-- that ticks for a size of its own, far from the hit's: run hunter2 F1, Black Arrow 466930 hit nameplate1 for 14588
-- 0.37 s after its cast and its DoT ticked 1185 every 1.0 s from +1.29 s on, through four recasts, about 20 ticks a
-- cast. Its school (Shadow) held every other row of the log, so the DoT pass (one school, one row) never learned the
-- ticks, the flat pass (Flat.lua) wants them the hit's size, and the live votes (Learn.OnBirth) learned it only in F6.
-- The proof: on the plate of a cast that ran no like-sized series in the PRE seconds before it, a train starts on a
-- hit FIRST seconds or less after the cast, of the learned hit's school and outside its size band, and takes, one or
-- two periods on (Streams.Slack), hits like-sized with its first (LIKE), the period set by its first two ticks, through
-- the spell's recasts until it misses two ticks. A cast spell whose trains hold TICKS ticks or more and span CASTS of
-- its casts or more is learned as a DoT (Learn.Teach) when their sum is at most its row's room (total, overkill and
-- Judge's tolerance, less what was drawn under it and what this read learned for it) and at least SHARE of the row.
-- With /cti debug each tried spell logs one TEACH train line.

local _, ns = ...
local Fingerprints, Streams, Steady = ns.Fingerprints, ns.Streams, ns.Steady

local Train = {}
ns.Train = Train

local FIRST = 2.5    -- a train's first tick lands at most this long after its cast (one slow period)
local TICKS = 8      -- ticks one train holds at least
local SPAN = 2       -- casts of the spell one train spans at least (a recast keeps a DoT's train running)
local COVER = 0.5    -- share of the spell's casts on the trains' plates that the trains span at least
local LIKE = 0.01    -- a tick's size agrees with the train's first within this share
local PRE = 3        -- seconds before an opening cast with no like-sized hit on its plate
local SHARE = 0.03   -- the trains' sum is at least this share of the row: a stray run teaches nothing
local PERIOD_LO, PERIOD_HI = 0.5, 3 -- a period lies in this range (Ramp's)
local BLEND = 0.8    -- weight of the old period when a tick extends a train (Streams')

local function Like(a, b) return math.abs(a - b) <= LIKE * math.max(a, b) end

-- The hit of `list` from `index` on that lands one or two periods after `last` (within Streams.Slack), like-sized with
-- `size`, nearest its due time; nil for none. A crit tick (not in `list`) leaves a period empty.
local function Next(list, index, last, period, size)
    local slack = Streams.Slack(period)
    for multiple = 1, 2 do
        local due = last.at + multiple * period
        local found, error
        for position = index, #list do
            local hit = list[position]
            if hit.at > due + slack then break end
            local off = math.abs(hit.at - due)
            if off <= slack and Like(hit.size, size) and (not found or off < error) then found, error = position, off end
        end
        if found then return found end
    end
end

-- Whether a hit like-sized with `size` lands on the plate (`list`) in the PRE seconds before `castAt`, other than a
-- tick of the spell's own train before (`taken`): its DoT ran out and the cast opens it again.
local function RanBefore(list, castAt, size, taken)
    for _, hit in ipairs(list) do
        if hit.at >= castAt then break end
        if hit.at >= castAt - PRE and Like(hit.size, size) and not taken[hit] then return true end
    end

    return false
end

-- Whether a train whose first tick lands at `at` ticks on from one of the cast's own hits (`landings`, their times):
-- one period after it, within Streams.Slack.
local function Anchored(landings, at, period)
    for _, landed in ipairs(landings) do
        if math.abs(at - landed - period) <= Streams.Slack(period) then return true end
    end

    return false
end

-- The longest train on one plate's hits of the school (`list`, oldest first) opening after a cast at `castAt`, one
-- period after one of the cast's own hits (`landings`): { hits, sum, period }, or nil.
local function Walk(list, castAt, landings, taken)
    local best
    for first = 1, #list do
        local head = list[first]
        if head.at > castAt + FIRST then break end
        if head.at > castAt and not taken[head] and not RanBefore(list, castAt, head.size, taken) then
            for second = first + 1, #list do
                local gap = list[second].at - head.at
                if gap > PERIOD_HI then break end
                if gap >= PERIOD_LO and Like(list[second].size, head.size) then
                    local train = { hits = { head, list[second] }, sum = head.amount + list[second].amount }
                    local period, position = gap, second
                    while true do
                        local found = Next(list, position + 1, list[position], period, head.size)
                        if not found then break end
                        local step = list[found].at - list[position].at
                        if step > 1.5 * period then step = step / 2 end
                        period = BLEND * period + (1 - BLEND) * step
                        position = found
                        train.hits[#train.hits + 1], train.sum = list[found], train.sum + list[found].amount
                    end
                    train.period = period
                    local anchored = Anchored(landings, head.at, period)
                    if anchored and (not best or #train.hits > #best.hits) then best = train end
                end
            end
        end
    end

    return best
end

-- The times of the cast's own hits in the FIRST seconds after it: its drawn hits and its plate's '?' hits in its
-- learned size band (Flat.OwnSize).
local function Landings(run, castID, cast)
    local times = {}
    for _, hit in ipairs(run.drawn or {}) do
        if hit.spellID == castID and hit.at >= cast.at and hit.at <= cast.at + FIRST then times[#times + 1] = hit.at end
    end
    for _, hit in ipairs(run.unknown) do
        if hit.plate == cast.plate and hit.at >= cast.at and hit.at <= cast.at + FIRST and hit.size
            and ns.Flat.OwnSize(castID, hit.size) then
            times[#times + 1] = hit.at
        end
    end

    return times
end

-- How many hits like-sized with `size` (LIKE) of the school land on plates the spell was never cast on this fight
-- (`castPlates`), solo '?' hits, frame mates and strangers alike: a size that ticks there is no DoT of that cast's.
local function Elsewhere(run, castPlates, school, size)
    local count = 0
    for _, list in ipairs({ run.unknown, run.mates or {}, run.strangers or {} }) do
        for _, hit in ipairs(list) do
            if hit.plate ~= nil and not castPlates[hit.plate] and hit.school == school and hit.size and not hit.crit
                and Like(hit.size, size) then
                count = count + 1
            end
        end
    end

    return count
end

-- What this read drew and learned for `castID` before the train pass: the fight's tally under it and the ways learned.
local function Claimed(castID, run, learned)
    local sum = run.tally and run.tally[castID] or 0
    for _, way in ipairs(learned) do
        if way.castID == castID then sum = sum + way.sum end
    end

    return sum
end

-- The train pass of one read. `run` is the fight (its '?' hits and casts, each cast with its plate and whether the pet
-- cast it), `rows` the read's meter rows, `learned` the ways learned so far (their hits are spent). Returns the new
-- ways { castID, sum, hits }.
function Train.Learn(run, rows, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local byPlate = {} -- [plate] = its normal hits, oldest first
    for _, hit in ipairs(run.unknown) do
        if hit.size and hit.size > 0 and not hit.crit and hit.plate ~= nil and not spent[hit] then
            byPlate[hit.plate] = byPlate[hit.plate] or {}
            table.insert(byPlate[hit.plate], hit)
        end
    end
    local castsOf, order = {}, {}
    for _, cast in ipairs(run.casts or {}) do
        local castID = cast.spellID
        if cast.plate ~= nil and byPlate[cast.plate] and not cast.pet and not ns.Flat.Channelled(castID) then
            if not castsOf[castID] then castsOf[castID], order[#order + 1] = {}, castID end
            table.insert(castsOf[castID], cast)
        end
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local fp, row = Fingerprints.Get(castID), Steady.RowOf(castID, rows)
        if fp and fp.learned and row and not ns.Learn.Get(castID) then
            local taken, hits, sum, weighted, casts, longest = {}, {}, 0, 0, 0, 0
            local lists, castPlates, trained = {}, {}, {}
            for _, cast in ipairs(castsOf[castID]) do castPlates[cast.plate] = true end
            for _, cast in ipairs(castsOf[castID]) do
                local list = lists[cast.plate]
                if not list then
                    list = {}
                    for _, hit in ipairs(byPlate[cast.plate]) do
                        if hit.school == fp.school and not ns.Flat.OwnSize(castID, hit.size) then list[#list + 1] = hit end
                    end
                    lists[cast.plate] = list
                end
                local train = Walk(list, cast.at, Landings(run, castID, cast), taken)
                local span = 0
                if train and not taken[train.hits[1]] then
                    local first, last = train.hits[1].at, train.hits[#train.hits].at
                    for _, other in ipairs(castsOf[castID]) do
                        if other.plate == cast.plate and other.at >= first - FIRST and other.at <= last then
                            span = span + 1
                        end
                    end
                end
                if train then longest = math.max(longest, #train.hits) end
                if span >= SPAN and #train.hits >= TICKS
                    and Elsewhere(run, castPlates, fp.school, train.hits[1].size) < #train.hits / 2 then
                    for _, hit in ipairs(train.hits) do
                        if not taken[hit] then
                            taken[hit], hits[#hits + 1], sum = true, hit, sum + hit.amount
                            weighted = weighted + train.period
                        end
                    end
                    casts, trained[cast.plate] = casts + span, true
                end
            end
            local room = row.total + row.overkill + math.max(1, row.total / 100) - Claimed(castID, run, learned)
            local tried = 0
            for _, cast in ipairs(castsOf[castID]) do
                if trained[cast.plate] then tried = tried + 1 end
            end
            local outcome = #hits == 0 and "none" or casts < COVER * tried and "cover" or sum > room and "over"
                or sum < SHARE * row.total and "short" or "learned"
            local period = #hits > 0 and weighted / #hits * (1 + (ns.Learn.Haste() or 0) / 100) or 0
            if outcome == "learned" and ns.Learn.Teach(castID, fp.school, period) then
                -- its biggest tick bounds its first ticks (Tracker's Oversized)
                for _, hit in ipairs(hits) do ns.Learn.Sized(castID, hit.size) end
                ways[#ways + 1] = { castID = castID, sum = sum, hits = hits }
            elseif outcome == "learned" then
                outcome = "refused"
            end
            if ns.Debug and longest >= 2 then
                local low, high = math.huge, 0
                for _, hit in ipairs(hits) do low, high = math.min(low, hit.size), math.max(high, hit.size) end
                ns.Debug("TEACH train %d casts=%d/%d school=%d ticks=%d longest=%d size=%.0f-%.0f sum=%.0f room=%.0f period=%.3f -> %s",
                    castID, casts, #castsOf[castID], fp.school, #hits, longest, low, high, sum, room, period, outcome)
            end
        end
    end

    return ways
end
