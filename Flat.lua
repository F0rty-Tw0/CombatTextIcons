-- Combat Text Icons: flat pass. A cast whose own hit is learned (a fingerprint) may also leave a DoT on its target
-- that ticks for the size of that hit: run priest4 F1, Devouring Plague 335467 hit nameplate10 for 6921 at its cast
-- and ticked 6921 at +1.74 and +3.52 s, and 8517 three times 1.8 s apart after a later cast's 7491. Its school
-- (Shadow) held every other row of the log, so the DoT pass (one school, one row) never learned the ticks, the ramp
-- pass (Ramp.lua) wants a step up, and they stayed '?'.
-- The proof: per cast, a series starts on a hit FIRST seconds or less after the cast on the cast's plate, of the
-- learned hit's school and inside its size band (OwnSize), and takes, one period on (Streams.Slack), hits like-sized
-- with its first (LIKE), the period set by its first two ticks, until the spell's next cast on that plate. No
-- like-sized hit lands on that plate in the PRE seconds before the cast: a series that ran before it is no tick of
-- its. A cast spell whose series hold TICKS ticks or more on CASTS of its casts or more is learned as a flat DoT
-- (Learn.Teach, Learn.SetFlat) when their sum is at most its row's room (total, overkill and Judge's tolerance, less
-- what was drawn under it and what this read learned for it) and at least SHARE of the row.
-- The size band keeps other spells' series out: run priest3 F1, a learn without it took series of 2479, 2875 and 939
-- as Devouring Plague's (band 6592-7866), and run hunter2 F5 took six Shadow hits 1.04 s apart summing 7584, Black
-- Arrow 466930's rhythm, as 467718's (its own hits are 6545-7825). One cast is too little: it cost run lock4 454K
-- right and 17K wrong, run hunter2 106K right and 24K wrong. The pet's casts are not tried (the meter lists its spells
-- as its own rows), nor a channel's (Flat.Channel): its ticks come while it channels and the tracker's channel mode
-- draws them.
-- With /cti debug each tried spell logs one TEACH flat line.

local _, ns = ...
local Fingerprints, Streams, Steady = ns.Fingerprints, ns.Streams, ns.Steady

local Flat = {}
ns.Flat = Flat

local FIRST = 2.5    -- a series' first tick lands at most this long after its cast (one slow period)
local TICKS = 2      -- ticks a series holds at least
local CASTS = 2      -- casts whose series a spell needs
local LIKE = 0.01    -- a flat tick's size agrees with the series' first within this share
local PRE = 3        -- seconds before a cast with no like-sized hit on its plate
local SHARE = 0.03   -- the series' sum is at least this share of the row: a stray run teaches nothing
local PERIOD_LO, PERIOD_HI = 0.5, 3 -- a period lies in this range (Ramp's)
local BLEND = 0.8    -- weight of the old period when a tick extends a series (Streams')
local HOLD = 0.02    -- the tracker holds a flat DoT's tick within this share of its last (Tracker's Phase)
Flat.HOLD = HOLD

local issecretvalue = issecretvalue or function() return false end

local channels = {} -- [spellID] = true for a spell seen channelling this session (it is no flat DoT)

-- A channel began (UNIT_SPELLCAST_CHANNEL_START): the spell's ticks are its channel's.
function Flat.Channel(spellID)
    if not issecretvalue(spellID) and type(spellID) == "number" then channels[spellID] = true end
end

-- Whether the spell was seen channelling this session (the train pass, Train.lua, skips it too).
function Flat.Channelled(spellID) return channels[spellID] == true end

local function Like(a, b) return math.abs(a - b) <= LIKE * math.max(a, b) end

-- The hit of `list` from `index` on that lands `period` after `last` (within Streams.Slack), like-sized with `size`,
-- nearest the due time; nil for none.
local function Next(list, index, last, period, size)
    local slack, due = Streams.Slack(period), last.at + period
    local found, error
    for position = index, #list do
        local hit = list[position]
        if hit.at > due + slack then break end
        local off = math.abs(hit.at - due)
        if off <= slack and Like(hit.size, size) and (not found or off < error) then found, error = position, off end
    end

    return found
end

-- Whether a hit like-sized with `size` lands on the plate (`list`) in the PRE seconds before `castAt`.
local function RanBefore(list, castAt, size)
    for _, hit in ipairs(list) do
        if hit.at >= castAt then break end
        if hit.at >= castAt - PRE and Like(hit.size, size) then return true end
    end

    return false
end

-- The longest flat series on one plate's normal hits of the school (`list`, oldest first) after a cast at `castAt`,
-- up to the spell's next cast on the plate at `stop`: { hits, sum, period }.
local function Walk(list, castAt, stop)
    local best
    for first = 1, #list do
        local head = list[first]
        if head.at > castAt + FIRST or head.at >= stop then break end
        if head.at > castAt and not RanBefore(list, castAt, head.size) then
            for second = first + 1, #list do
                local gap = list[second].at - head.at
                if gap > PERIOD_HI or list[second].at >= stop then break end
                if gap >= PERIOD_LO and Like(list[second].size, head.size) then
                    local series = { hits = { head, list[second] }, sum = head.amount + list[second].amount }
                    local period, position = gap, second
                    while true do
                        local found = Next(list, position + 1, list[position], period, head.size)
                        if not found or list[found].at >= stop then break end
                        period = BLEND * period + (1 - BLEND) * (list[found].at - list[position].at)
                        position = found
                        series.hits[#series.hits + 1], series.sum = list[found], series.sum + list[found].amount
                    end
                    series.period = period
                    if #series.hits >= TICKS and (not best or #series.hits > #best.hits) then best = series end
                end
            end
        end
    end

    return best
end

-- Whether `size` lies in the band of the cast's own learned hit (Fingerprints.Band), widened by Streams.SIZE_GUARD.
local function OwnSize(castID, size)
    local low, high = Fingerprints.Band(castID, castID)

    return low ~= nil and size >= (1 - Streams.SIZE_GUARD) * low and size * (1 - Streams.SIZE_GUARD) <= high
end
Flat.OwnSize = OwnSize -- the tracker's first flat tick (Tracker's Phase)

-- What this read drew and learned for `castID` before the flat pass: the fight's tally under it and the ways learned.
local function Claimed(castID, run, learned)
    local sum = run.tally and run.tally[castID] or 0
    for _, way in ipairs(learned) do
        if way.castID == castID then sum = sum + way.sum end
    end

    return sum
end

-- The flat pass of one read. `run` is the fight (its '?' hits and casts, each cast with its plate and whether the pet
-- cast it), `rows` the read's meter rows, `learned` the ways learned so far (their hits are spent). Returns the new
-- ways { castID, sum, hits }.
function Flat.Learn(run, rows, learned)
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
        if cast.plate ~= nil and byPlate[cast.plate] and not cast.pet and not channels[castID] then
            if not castsOf[castID] then castsOf[castID], order[#order + 1] = {}, castID end
            table.insert(castsOf[castID], cast)
        end
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local fp, row = Fingerprints.Get(castID), Steady.RowOf(castID, rows)
        if fp and fp.learned and row and not ns.Learn.Get(castID) then
            local taken, hits, sum, weighted, casts = {}, {}, 0, 0, 0
            for index, cast in ipairs(castsOf[castID]) do
                local stop = math.huge
                for later = index + 1, #castsOf[castID] do
                    local other = castsOf[castID][later]
                    if other.plate == cast.plate and other.at > cast.at then
                        stop = other.at
                        break
                    end
                end
                local list = {}
                for _, hit in ipairs(byPlate[cast.plate]) do
                    if hit.school == fp.school and OwnSize(castID, hit.size) then list[#list + 1] = hit end
                end
                local series = Walk(list, cast.at, stop)
                if series then casts = casts + 1 end
                for _, hit in ipairs(series and series.hits or {}) do
                    if not taken[hit] then
                        taken[hit], hits[#hits + 1], sum = true, hit, sum + hit.amount
                        weighted = weighted + series.period
                    end
                end
            end
            local room = row.total + row.overkill + math.max(1, row.total / 100) - Claimed(castID, run, learned)
            local outcome = casts < CASTS and "casts" or sum > room and "over" or sum < SHARE * row.total and "short"
                or "learned"
            local period = #hits > 0 and weighted / #hits * (1 + (ns.Learn.Haste() or 0) / 100)
            if outcome == "learned" and ns.Learn.Teach(castID, fp.school, period) then
                ns.Learn.SetFlat(castID)
                -- its biggest tick bounds its first ticks (Tracker's Oversized)
                for _, hit in ipairs(hits) do ns.Learn.Sized(castID, hit.size) end
                ways[#ways + 1] = { castID = castID, sum = sum, hits = hits }
            elseif outcome == "learned" then
                outcome = "refused"
            end
            if ns.Debug and #hits > 0 then
                local low, high = Fingerprints.Band(castID, castID)
                ns.Debug("TEACH flat %d casts=%d/%d school=%d band=%s-%s ticks=%d sum=%.0f room=%.0f period=%.3f -> %s",
                    castID, casts, #castsOf[castID], fp.school, tostring(low), tostring(high), #hits, sum, room, period,
                    outcome)
            end
        end
    end

    return ways
end
