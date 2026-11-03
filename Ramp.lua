-- Combat Text Icons: ramp pass. A DoT that ramps grows on every tick: run lock4 F15, Agony 980 cast at 36566.131
-- ticked its plate 2600 crit, 3465 crit, 2016, 2420, 2823, 3581, 4066 every ~1.47 s (one step of ~403 a tick until a
-- buff). Its school (Shadow) held four other rows there, Unstable Affliction's steady 3254s at the same period among
-- them, so the DoT pass (one school, one row) never learned it, no stream is born on ticks that change size past
-- Streams' SIZE_GUARD, and its row (12 % of lock4's meter) stayed '?' in every fight.
-- The proof: per cast spell with its own open row, a series starts on a hit FIRST seconds or less after a cast on the
-- cast's plate and takes, one period on (Streams.Slack), a hit of its school that steps up from the last one (Rises)
-- by one fixed step a normal tick (STEP_SPREAD), the period set by its first two ticks, until the spell's next cast on
-- that plate. A cast spell whose series hold TICKS ticks or more, all of one school, is learned as a ramp DoT
-- (Learn.Teach) when their sum is at most its own row and at least SHARE of it: the tracker then draws its ticks, the
-- ramp included (Tracker's RampStep and Phase's ramp band). With /cti debug each tried spell logs one TEACH ramp line.

local _, ns = ...
local Fingerprints, Streams, Chain = ns.Fingerprints, ns.Streams, ns.Chain

local Ramp = {}
ns.Ramp = Ramp

local FIRST = 2.5    -- a series' first tick lands at most this long after its cast (one slow period)
local TICKS = 4      -- ticks a series holds at least: three steps up
-- The series' sum is at least this share of the row: a stray rise teaches nothing. Small, since a fight on many plates
-- shows a ramp only on the plates its ticks are seen on (lock4 F2: 4 % of Agony's row).
local SHARE = 0.03
local PERIOD_LO, PERIOD_HI = 0.5, 3 -- a period lies in this range (Stack's)
local BLEND = 0.8    -- weight of the old period when a tick extends a series (Streams')
-- A step with a crit may dip this far: a crit is halved on a guess (Streams.NormalAmount: x2; lock4's are x2.15).
local CRIT_DIP = 0.9
-- A ramp adds one fixed amount a tick: normal ticks' steps per tick are above zero and agree within this share, and a
-- series holds STEPS like steps past its first (lock4 F8: Agony showed three normal ticks between crits). Run priest4
-- F1: Void Torrent 263165's channel ticks rose 17 times at 2.2 s by no fixed step and walked as a ramp without the law
-- (its row then went 0.8 % wrong as a DoT).
local STEP_SPREAD = 0.15
local STEPS = 1
-- A ramp's stacks start at its cast: its normal ticks' line, taken back to the cast, lies at most this share of its
-- first normal tick (lock4 Agony: 0.3-0.4). Rake 1822 (druid F11, 2744 to 4052) and Void Torrent 263165
-- (shadow-steady2 F1, 1826 to 2575) rose by a fixed step from 0.8-0.95, and dk F1's 343294 by rounding (73, 74, 77),
-- and each walked as a ramp without it.
local FROM_CAST = 0.6

-- Whether hit `b` steps up from hit `a`: bigger, by at most Streams.RAMP_STEP.
local function Rises(a, b)
    local low = (a.crit or b.crit) and CRIT_DIP or 1

    return b.size > low * a.size and b.size <= Streams.RAMP_STEP * a.size
end

-- Whether `hit` continues `series` ({ hits, normal = its last normal tick's index, step }): it steps up from the last
-- tick, and a normal one by the series' step per tick (within STEP_SPREAD) once two normal ticks set it. Returns the
-- step per tick from the last normal tick (nil for a crit or the first normal tick).
local function Continues(series, hit)
    local last = series.hits[#series.hits]
    if hit.school ~= last.school or not Rises(last, hit) then return false end
    if hit.crit or not series.normal then return true end
    local normal = series.hits[series.normal]
    local step = (hit.size - normal.size) / (#series.hits + 1 - series.normal)
    if step <= 0 or series.step and math.abs(step - series.step) > STEP_SPREAD * series.step then return false end

    return true, step
end

-- Adds `hit` to `series`: a normal tick sets the step on the first one after a normal tick, counts one more like step
-- after that.
local function Extend(series, hit, step)
    series.hits[#series.hits + 1], series.sum = hit, series.sum + hit.amount
    if hit.crit then return end
    if step and series.step then series.steps = series.steps + 1 end
    series.step = series.step or step
    series.normal, series.base, series.baseAt = #series.hits, series.base or hit.size, series.baseAt or hit.at
end

-- The hit of `list` from `index` on that lands `period` after the series' last tick (within Streams.Slack) and
-- continues it, nearest the due time, and its step; nil for none.
local function Next(list, index, series, period)
    local last = series.hits[#series.hits]
    local slack, due = Streams.Slack(period), last.at + period
    local found, error, foundStep
    for position = index, #list do
        local hit = list[position]
        if hit.at > due + slack then break end
        local off = math.abs(hit.at - due)
        if off <= slack and (not found or off < error) then
            local continues, step = Continues(series, hit)
            if continues then found, error, foundStep = position, off, step end
        end
    end

    return found, foundStep
end

-- The longest series on one plate's hits (`list`, oldest first) after a cast at `castAt`, up to the spell's next cast
-- on the plate at `stop`: { hits, sum, period, school, steps }. A step after a recast is a stack's, not a ramp's: run
-- lock4 F1, Unstable Affliction 1259790's ticks rose with each of its 9 casts' stacks and walked as a ramp without the
-- stop.
local function Walk(list, castAt, stop)
    local best
    for first = 1, #list do
        local head = list[first]
        if head.at > castAt + FIRST or head.at > stop then break end
        for second = first + 1, #list do
            local gap = list[second].at - head.at
            if gap > PERIOD_HI or list[second].at > stop then break end
            local series = { hits = { head }, sum = head.amount, steps = 0, normal = not head.crit and 1 or nil,
                base = not head.crit and head.size or nil, baseAt = not head.crit and head.at or nil,
                school = head.school }
            local continues, step = Continues(series, list[second])
            if head.at > castAt and gap >= PERIOD_LO and continues then
                Extend(series, list[second], step)
                local period, position = gap, second
                while true do
                    local found, foundStep = Next(list, position + 1, series, period)
                    if not found or list[found].at > stop then break end
                    period = BLEND * period + (1 - BLEND) * (list[found].at - series.hits[#series.hits].at)
                    position = found
                    Extend(series, list[found], foundStep)
                end
                series.period = period
                local fits = #series.hits >= TICKS and series.steps >= STEPS
                    and series.base - series.step * (series.baseAt - castAt) / period <= FROM_CAST * series.base
                if fits and (not best or #series.hits > #best.hits) then best = series end
            end
        end
    end

    return best
end

-- The ramp pass of one read. `run` is the fight (its '?' hits and casts, each cast with its plate), `open` and
-- `rewritten` the unpaired rows and the ones paired, `results` the read's verdicts, `learned` the ways learned so far
-- (their hits are spent). Pairs each learned ramp with its own row (verdict "under") and returns the new ways
-- { castID, sum, hits }.
function Ramp.Learn(run, open, rewritten, results, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local byPlate = {} -- [plate] = its hits, oldest first
    for _, hit in ipairs(run.unknown) do
        if hit.size and hit.size > 0 and hit.plate ~= nil and not spent[hit] then
            byPlate[hit.plate] = byPlate[hit.plate] or {}
            table.insert(byPlate[hit.plate], hit)
        end
    end
    local castsOf, order = {}, {}
    for _, cast in ipairs(run.casts or {}) do
        local castID = cast.spellID
        if cast.plate ~= nil and byPlate[cast.plate] then
            if not castsOf[castID] then castsOf[castID], order[#order + 1] = {}, castID end
            table.insert(castsOf[castID], cast)
        end
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local position = Chain.OwnRow(castID, open, rewritten)
        local free = not Fingerprints.IsLearned(castID) and not ns.Learn.Get(castID)
        if position and free then
            local taken, hits, sum, weighted, school, outcome = {}, {}, 0, 0, nil, "none"
            for index, cast in ipairs(castsOf[castID]) do
                local stop = math.huge
                for later = index + 1, #castsOf[castID] do
                    local other = castsOf[castID][later]
                    if other.plate == cast.plate and other.at > cast.at then
                        stop = other.at
                        break
                    end
                end
                local series = Walk(byPlate[cast.plate], cast.at, stop)
                if series and school and series.school ~= school then outcome = "schools" end
                school = school or (series and series.school)
                for _, hit in ipairs(series and series.hits or {}) do
                    if not taken[hit] then
                        taken[hit], hits[#hits + 1], sum = true, hit, sum + hit.amount
                        weighted = weighted + series.period
                    end
                end
            end
            local row = open[position].row
            local tol = math.max(1, row.total / 100)
            if #hits > 0 and outcome == "none" then
                outcome = sum > row.total + row.overkill + tol and "over" or sum < SHARE * row.total and "short" or "learned"
            end
            local period = #hits > 0 and weighted / #hits * (1 + (ns.Learn.Haste() or 0) / 100)
            if outcome == "learned" and ns.Learn.Teach(castID, school, period, true) then
                -- its biggest tick bounds its first ticks (Tracker's Oversized) and its school in the castless pass
                for _, hit in ipairs(hits) do ns.Learn.Sized(castID, hit.size) end
                rewritten[position] = true
                results[open[position].index] = { spellID = castID, meterID = castID, tally = sum, meter = row.total,
                    verdict = "under" }
                ways[#ways + 1] = { castID = castID, sum = sum, hits = hits }
            elseif outcome == "learned" then
                outcome = "refused"
            end
            if ns.Debug and #hits > 0 then
                ns.Debug("TEACH ramp %d casts=%d school=%s ticks=%d sum=%.0f period=%.3f -> %s", castID,
                    #castsOf[castID], tostring(school), #hits, sum, period, outcome)
            end
        end
    end

    return ways
end
