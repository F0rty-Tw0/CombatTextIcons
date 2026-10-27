-- Synth: score-format debug logs whose meter rows are true, for bench's synth scenario. Perturbed copies of the real
-- logs (tests/score/*.txt) and small fabricated logs. Every number it yields is synthetic: it shows, never gates.
-- Pure text in, text out: no addon, no run.lua, no score_lib.lua; all randomness from a seeded Park-Miller (never
-- math.random).
--
--   lua tests/synth.lua    runs the start-up asserts and prints nothing

local S = {}

S.ALIAS_OFFSET = 9000000 -- an aliased row reads row=<spell ID + this>

-- Line grammar for emitted lines, stricter than what run.lua's ParseLog and ParseTeach (read by SplitFights) accept.
local PATTERN = {
    CAST = "^%d+%.%d%d%d CAST player (%d+) base=(%d+),(%d+)$",
    HIT = "^%d+%.%d%d%d HIT (nameplate%d) school=(%d+) amount=(%d+) flag= fps=60 threat=(%d+) target=(%a+)$",
    CLEAN = "^%d+%.%d%d%d TEACH clean seen=(%d+) meter=(%d+) %-> clear$",
    ROW = "^%d+%.%d%d%d TEACH (%d+) tally=(%d+) meter=(%d+) verdict=%a+$",
}

-- Two fights and a tail: a route line, a TEACH clean of each area, a row with row=, a row of an uncast spell, rows of
-- spell 111 with a tally (the addon drew it) beside rows of 222 and 555 without.
local CANNED = {
    "10.000 CAST player 111 base=111,111",
    "10.400 HIT nameplate1 school=4 amount=1000 flag= fps=60 threat=3 target=true",
    "10.400   -> HIDDEN (crowded)",
    "11.000 CAST player 222 base=222,222",
    "11.400 HIT nameplate2 school=32 amount=500 flag= fps=60 threat=3 target=false",
    "14.000 HIT nameplate1 school=4 amount=1200 flag= fps=60 threat=3 target=true",
    "15.000 TEACH clean seen=2700 meter=2700 -> clear",
    "15.000 TEACH 111 tally=2200 meter=2200 verdict=unpaired",
    "15.000 TEACH 222 tally=0 meter=500 verdict=unpaired",
    "40.000 CAST player 111 base=111,111",
    "40.400 HIT nameplate1 school=4 amount=900 flag= fps=60 threat=3 target=true",
    "41.000 HIT nameplate3 school=8 amount=300 flag= fps=60 threat=3 target=false",
    "44.000 TEACH clean seen=1277 meter=1277 -> clear",
    "44.000 TEACH 111 tally=900 meter=900 verdict=unpaired",
    "44.000 TEACH 333 tally=77 meter=77 verdict=agree row=444",
    "44.000 TEACH 555 tally=0 meter=300 verdict=unpaired",
    "50.000 CAST player 111 base=111,111",
}

function S.Rng(seed) -- Park-Miller: the same numbers on every Lua version (checks_streams.lua)
    local state = seed
    return function() state = (state * 16807) % 2147483647 return state / 2147483647 end
end

-- Park-Miller from a small seed starts tiny and correlated across seeds, so the seed is spread (bench's Permute too).
function S.Seeded(seed)
    return S.Rng(seed * 1103515245 % 2147483646 + 1)
end

local function Time(line)
    return tonumber(line:match("^([%d%.]+)"))
end

local function Stamp(t)
    return string.format("%.3f", t)
end

-- A unit is one line plus every following route line (run.lua's ParseLog attaches a route to the line before it).
local function Units(lines)
    local units = {}
    for _, line in ipairs(lines) do
        local isRoute = line:match("^[%d%.]+   %-> ") ~= nil
        local unit = units[#units]
        assert(unit or not isRoute, "route line with no line before it")
        if isRoute then
            unit.lines[#unit.lines + 1] = line
        else
            units[#units + 1] = { t = Time(line), lines = { line }, index = #units + 1 }
        end
    end

    return units
end

-- Units and inserted `extra` units in one total order (t, inserted last, index), flattened. Neither input changes.
local function Merge(units, extra)
    local entries = {}
    for _, unit in ipairs(units) do
        entries[#entries + 1] = { t = unit.t, inserted = false, index = unit.index, lines = unit.lines }
    end
    for position, unit in ipairs(extra) do
        entries[#entries + 1] = { t = unit.t, inserted = true, index = unit.index or position, lines = unit.lines }
    end
    table.sort(entries, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if a.inserted ~= b.inserted then return b.inserted end

        return a.index < b.index
    end)

    local merged = {}
    for _, entry in ipairs(entries) do
        table.move(entry.lines, 1, #entry.lines, #merged + 1, merged)
    end

    return merged
end

-- Unit index ranges, each ending at a TEACH clean of any area; the tail after the last one is not a fight.
local function Fights(units)
    local fights, from = {}, 1
    for index, unit in ipairs(units) do
        if unit.lines[1]:match("^[%d%.]+ TEACH clean seen=%d+ meter=%d+ %-> %a+$") then
            fights[#fights + 1] = { from = from, to = index }
            from = index + 1
        end
    end

    return fights
end

local function Uniform(rand, low, high)
    return low + (high - low) * rand()
end

-- The units of one fight that are HITs, with their plate, in order: { unit, plate, threat, target }.
local function FightHits(units, fight)
    local hits = {}
    for index = fight.from, fight.to do
        local unit = units[index]
        local first = unit.lines[1]
        local plate, threat, target = first:match("^[%d%.]+ HIT (%S+) "), first:match(" threat=(%S+) "), first:match(" target=(%a+)$")
        if plate and threat and target then hits[#hits + 1] = { unit = unit, plate = plate, threat = threat, target = target } end
    end

    return hits
end

-- Plates in first-appearance order, each with its HITs in order.
local function ByPlate(hits)
    local plates, byPlate = {}, {}
    for _, hit in ipairs(hits) do
        if not byPlate[hit.plate] then
            byPlate[hit.plate] = {}
            plates[#plates + 1] = hit.plate
        end
        table.insert(byPlate[hit.plate], hit)
    end

    return plates, byPlate
end

local SCHOOLS = { 1, 4, 8, 16, 32, 64 }
local SHIFTS = { 0.1, 0.2, 0.3, 0.6 }
local AMOUNT_LOW, AMOUNT_HIGH = 300, 20000

-- One draw: an item of `list`.
local function Pick(rand, list)
    return list[1 + math.floor(rand() * #list)]
end

-- One draw: a whole number, log-uniform between `low` and `high`.
local function LogUniform(rand, low, high)
    return math.floor(math.exp(math.log(low) + rand() * (math.log(high) - math.log(low))))
end

-- Strangers: other players' HITs on a plate, 1.5-3 s apart between its first and last HIT of a fight; each copies the
-- threat and target of the plate's nearest HIT before it.
local function Group(lines, rand)
    local units = Units(lines)
    local extra = {}
    for _, fight in ipairs(Fights(units)) do
        local plates, byPlate = ByPlate(FightHits(units, fight))
        for _, plate in ipairs(plates) do
            local hits = byPlate[plate]
            local first, last = hits[1].unit.t, hits[#hits].unit.t
            local s = #hits >= 2 and first + Uniform(rand, 1.5, 3) or math.huge
            while s <= last do
                local school = Pick(rand, SCHOOLS)
                local amount = LogUniform(rand, AMOUNT_LOW, AMOUNT_HIGH)
                local near = hits[1]
                for _, hit in ipairs(hits) do
                    if hit.unit.t <= s then near = hit end
                end
                local line = Stamp(s) .. " HIT " .. plate .. " school=" .. school .. " amount=" .. amount
                    .. " flag= fps=60 threat=" .. near.threat .. " target=" .. near.target
                extra[#extra + 1] = { t = s, lines = { line } }
                s = s + Uniform(rand, 1.5, 3)
            end
        end
    end
    if #extra == 0 then return nil end

    return Merge(units, extra)
end

-- Each fight with a CAST: every HIT of one plate after the first cast moves by one of SHIFTS seconds, route lines with
-- it; a HIT that would reach the fight's clean stays. Nil when no fight has a plate hit after its first cast.
local function Distance(lines, rand)
    local units = Units(lines)
    local drew = false
    for _, fight in ipairs(Fights(units)) do
        local firstCast
        for index = fight.from, fight.to do
            if not firstCast and units[index].lines[1]:match("^[%d%.]+ CAST player ") then firstCast = units[index].t end
        end
        local after = {}
        for _, hit in ipairs(FightHits(units, fight)) do
            if firstCast and hit.unit.t > firstCast then after[#after + 1] = hit end
        end
        local plates, byPlate = ByPlate(after)
        if #plates > 0 then
            drew = true
            local plate = Pick(rand, plates)
            local d = Pick(rand, SHIFTS)
            local cleanT = units[fight.to].t
            for _, hit in ipairs(byPlate[plate]) do
                local unit = hit.unit
                if unit.t + d < cleanT then
                    unit.t = unit.t + d
                    for i, line in ipairs(unit.lines) do
                        unit.lines[i] = Stamp(unit.t) .. line:match("^[%d%.]+(.*)$")
                    end
                end
            end
        end
    end
    if not drew then return nil end

    return Merge(units, {})
end

-- Among the cast spells the addon drew (rows without row= whose tally sums above 0 over the log), the one with the
-- most meter gets row= on every such row (an unpaired row now claims a row); a tie goes to the smaller ID.
local function Alias(lines)
    local cast, meters, tallies, ids = {}, {}, {}, {}
    for _, line in ipairs(lines) do
        local id = line:match("^[%d%.]+ CAST %S+ (%d+)")
        if id then cast[id] = true end
        local rowId, tally, meter = line:match(PATTERN.ROW)
        if rowId then
            if not meters[rowId] then ids[#ids + 1] = rowId end
            meters[rowId] = (meters[rowId] or 0) + tonumber(meter)
            tallies[rowId] = (tallies[rowId] or 0) + tonumber(tally)
        end
    end
    table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)

    local chosen
    for _, id in ipairs(ids) do
        local drawn = cast[id] and tallies[id] > 0
        if drawn and (not chosen or meters[id] > meters[chosen]) then chosen = id end
    end
    if not chosen then return nil end

    local aliased = {}
    for index, line in ipairs(lines) do
        local rowId = line:match(PATTERN.ROW)
        aliased[index] = rowId == chosen and line .. " row=" .. (tonumber(chosen) + S.ALIAS_OFFSET) or line
    end

    return aliased
end

local PERTURBS = { group = Group, distance = Distance, alias = Alias }
S.PERTURB_CASES = { "group", "distance", "alias" }

-- Lines perturbed by `case`, or nil when no fight (group, distance) or no drawn cast spell (alias) is a candidate;
-- distance may return the lines unchanged when every HIT would reach its clean. Every HIT counts as the player's.
function S.Perturb(lines, case, seed)
    local perturb = PERTURBS[case]
    assert(perturb, "unknown perturb case " .. tostring(case))

    return perturb(lines, S.Seeded(seed))
end

local SPELL_A, SPELL_B, SPELL_C = 990001, 990002, 990003
local WINDOW = 40
S.FIGHTS = 6 -- fights in a fabricated log

local function Amount(rand, base)
    return math.floor(base * (0.9 + 0.2 * rand()))
end

-- Events of a fight: { t, line } for a cast, { t, line, spell, amount } for a HIT.
local function AddCast(events, t, id)
    events[#events + 1] = { t = t, line = Stamp(t) .. " CAST player " .. id .. " base=" .. id .. "," .. id }
end

local function AddHit(events, t, plate, school, amount, spell)
    local target = plate == 1 and "true" or "false"
    local line = Stamp(t) .. " HIT nameplate" .. plate .. " school=" .. school .. " amount=" .. amount
        .. " flag= fps=60 threat=3 target=" .. target
    events[#events + 1] = { t = t, line = line, spell = spell, amount = amount }
end

-- Spell A cast twice 0.2-0.5 s apart (school 32), spell B (school 4) cast alone between the pairs.
local function Doublecast(rand, start, events)
    local c = start
    while true do
        local offset = Uniform(rand, 0.2, 0.5)
        local amountA = Amount(rand, 8000)
        local amountTwin = Amount(rand, 8000)
        local gap = Uniform(rand, 6, 10)
        AddCast(events, c, SPELL_A)
        AddHit(events, c + 0.4, 1, 32, amountA, SPELL_A)
        AddCast(events, c + offset, SPELL_A)
        AddHit(events, c + offset + 0.4, 1, 32, amountTwin, SPELL_A)
        local following = c + gap
        if following + 0.9 >= start + WINDOW then return end

        local middle = (c + following) / 2
        AddCast(events, middle, SPELL_B)
        AddHit(events, middle + 0.4, 1, 4, Amount(rand, 3000), SPELL_B)
        c = following
    end
end

-- A fight body of AoE casts 5-8 s apart: each cast gets 3-5 HITs on nameplate1..n, `low`-`high` s from one HIT to the
-- next.
local function AreaCasts(low, high)
    return function(rand, start, events)
        local c = start
        while c + 0.4 + 5 * high < start + WINDOW do
            AddCast(events, c, SPELL_C)
            local count = 3 + math.floor(rand() * 3)
            local t = c + 0.4
            for plate = 1, count do
                if plate > 1 then t = t + Uniform(rand, low, high) end
                AddHit(events, t, plate, 4, Amount(rand, 5000), SPELL_C)
            end
            c = c + Uniform(rand, 5, 8)
        end
    end
end

local FABRICATES = { doublecast = Doublecast, aoe = AreaCasts(0.05, 0.12), ["aoe-spread"] = AreaCasts(0.3, 0.6) }
S.FABRICATE_CASES = { "doublecast", "aoe", "aoe-spread" }

-- S.FIGHTS fights of `case`, each ending in a TEACH clean and one true row per spell. Same seed, same lines.
function S.Fabricate(case, seed)
    local body = FABRICATES[case]
    assert(body, "unknown fabricate case " .. tostring(case))

    local rand, units, start = S.Seeded(seed), {}, 100
    local function Push(t, line) units[#units + 1] = { t = t, lines = { line }, index = #units + 1 } end
    for _ = 1, S.FIGHTS do
        local events = {}
        body(rand, start, events)

        local totals, spells, sum, last = {}, {}, 0, 0
        for _, event in ipairs(events) do
            Push(event.t, event.line)
            if event.spell then
                if not totals[event.spell] then spells[#spells + 1] = event.spell end
                totals[event.spell] = (totals[event.spell] or 0) + event.amount
                sum = sum + event.amount
                last = math.max(last, event.t)
            end
        end
        table.sort(spells)

        local clean = last + 1
        Push(clean, Stamp(clean) .. " TEACH clean seen=" .. sum .. " meter=" .. sum .. " -> clear")
        for _, spell in ipairs(spells) do
            Push(clean, Stamp(clean) .. " TEACH " .. spell .. " tally=0 meter=" .. totals[spell] .. " verdict=unpaired")
        end
        start = clean + 20
    end

    return Merge(units, {})
end

-- Start-up asserts' helpers -------------------------------------------------------------------------------------
local TOLERANCE = 0.001

local function Join(lines)
    return table.concat(lines, "\n")
end

local function Has(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end

    return false
end

-- Every line of `source` not in `edited` (a set of indexes) appears in `out`, in order.
local function KeepsOrder(out, source, edited)
    local at = 1
    for index, line in ipairs(source) do
        if not edited[index] then
            while out[at] ~= line do
                at = at + 1
                if at > #out then return false end
            end
            at = at + 1
        end
    end

    return true
end

local function Only(lines, pattern)
    local only = {}
    for _, line in ipairs(lines) do
        if line:match(pattern) then only[#only + 1] = line end
    end

    return only
end

local function Rest(line)
    return line:match("^[%d%.]+(.*)$")
end

-- How many TEACH clean lines come before lines[index].
local function CleanBefore(lines, index)
    local count = 0
    for i = 1, index - 1 do
        if lines[i]:match(PATTERN.CLEAN) then count = count + 1 end
    end

    return count
end

-- Spell A casts come in pairs 0.2-0.5 s apart, spell B casts sit 1.5 s clear of every A cast and A HIT.
local function CheckDoublecast(label, casts, hits)
    local aCasts = {}
    for _, cast in ipairs(casts) do
        if cast.id == SPELL_A then aCasts[#aCasts + 1] = cast.t end
    end
    for _, cast in ipairs(casts) do
        if cast.id == SPELL_B then
            for _, t in ipairs(aCasts) do assert(math.abs(cast.t - t) >= 1.5 - TOLERANCE, label .. "B cast near an A cast at " .. cast.t) end
            for _, hit in ipairs(hits) do
                if hit.school == 32 then assert(math.abs(cast.t - hit.t) >= 1.5 - TOLERANCE, label .. "B cast near an A HIT at " .. cast.t) end
            end
        end
    end
    local pairsSeen = 0
    -- consecutive A casts are "first, second" twins
    for i = 1, #aCasts - 1, 2 do
        local gap = aCasts[i + 1] - aCasts[i]
        assert(gap >= 0.2 - TOLERANCE and gap <= 0.5 + TOLERANCE, label .. "A casts come in pairs 0.2-0.5 s apart, got " .. gap)
        pairsSeen = pairsSeen + 1
    end
    assert(#aCasts % 2 == 0 and pairsSeen > 0, label .. "A casts come in pairs")
end

-- Every cast is spell C with 3-5 HITs on nameplate1..n, the first 0.4 s after it and each next `low`-`high` s later.
local function CheckArea(label, casts, hits, low, high)
    for index, cast in ipairs(casts) do
        assert(cast.id == SPELL_C, label .. "every cast is spell " .. SPELL_C)
        local nextAt = casts[index + 1] and casts[index + 1].at or #hits
        local group = {}
        for i = cast.at + 1, nextAt do group[#group + 1] = hits[i] end
        assert(#group >= 3 and #group <= 5, label .. "3-5 HITs per cast, got " .. #group)
        assert(math.abs(group[1].t - cast.t - 0.4) <= TOLERANCE, label .. "the first HIT is 0.4 s after the cast")
        for j, hit in ipairs(group) do
            assert(hit.plate == "nameplate" .. j, label .. "HIT " .. j .. " is on nameplate" .. j)
            assert((hit.target == "true") == (j == 1), label .. "only the first HIT is the target")
            assert(hit.school == 4, label .. "school 4")
            if j > 1 then
                local hop = hit.t - group[j - 1].t
                assert(hop >= low - TOLERANCE and hop <= high + TOLERANCE, label .. "hop " .. hop .. " outside " .. low .. "-" .. high)
            end
        end
    end
end

do -- start-up asserts: Rng, Units, Merge, Fights
    assert(S.Rng(1)() == 16807 / 2147483647, "Rng: seed 1 starts at 16807 / 2147483647")
    local one, two = S.Rng(7), S.Rng(7)
    for i = 1, 5 do assert(one() == two(), "Rng: the same seed gives the same stream (value " .. i .. ")") end
    assert(S.Seeded(1)() == S.Rng(1103515246)() and S.Seeded(1)() ~= S.Seeded(2)(), "Seeded: the seed is spread, seeds differ")

    local function UnitOf(units, text)
        for index, unit in ipairs(units) do
            if unit.lines[1] == text then return index end
        end
    end

    local units = Units(CANNED)
    assert(#units == 16, "Units: 17 lines, the route joins its HIT: 16 units")
    assert(#units[2].lines == 2 and units[2].lines[2] == CANNED[3], "Units: unit 2 is the HIT and its route")
    assert(units[2].t == 10.4 and units[2].index == 2, "Units: t and index")
    assert(table.concat(Merge(units, {}), "\n") == table.concat(CANNED, "\n"), "Merge: no extras returns the input")

    local hit = "10.400 HIT nameplate1 school=4 amount=777 flag= fps=60 threat=3 target=true"
    local merged = Merge(units, { { t = 10.4, lines = { hit } } })
    assert(#merged == 18 and merged[4] == hit and merged[3] == CANNED[3], "Merge: an extra at the same t lands after the route")
    assert(merged[2] == CANNED[2] and merged[5] == CANNED[4], "Merge: the rest keeps its order")

    local moved = Units(CANNED)
    moved[2].t = 11.5
    local expect = { CANNED[1], CANNED[4], CANNED[5], CANNED[2], CANNED[3] }
    table.move(CANNED, 6, 17, 6, expect)
    assert(table.concat(Merge(moved, {}), "\n") == table.concat(expect, "\n"), "Merge: a unit moves whole with its route")

    local twin = Merge(Units({ "1.000 A" }), { { t = 1, lines = { "1.000 B" } }, { t = 1, lines = { "1.000 C" } } })
    assert(table.concat(twin, ",") == "1.000 A,1.000 B,1.000 C", "Merge: extras without index keep their order")

    local fights = Fights(units)
    assert(#fights == 2, "Fights: 2 fights, the tail is none")
    assert(fights[1].from == 1 and fights[1].to == UnitOf(units, CANNED[7]), "Fights: the first ends at the first clean")
    assert(fights[2].from == fights[1].to + 1 and fights[2].to == UnitOf(units, CANNED[13]), "Fights: the second ends at the second clean")
    assert(fights[2].to < #units, "Fights: line 17 is in neither")

    local other = Fights(Units({ "1.000 HIT x", "2.000 TEACH clean seen=1 meter=1 -> short", "3.000 TEACH clean seen=0 meter=0 -> crowded" }))
    assert(#other == 2, "Fights: a clean of any area ends a fight")
end

do -- start-up asserts: Perturb cases
    for _, case in ipairs(S.PERTURB_CASES) do
        assert(PERTURBS[case], "Perturb: a function for case " .. case)
        assert(Join(S.Perturb(CANNED, case, 1)) == Join(S.Perturb(CANNED, case, 1)), case .. ": the same seed gives the same lines")
    end
end

do -- start-up asserts: Perturb group
    assert(Join(S.Perturb(CANNED, "group", 1)) ~= Join(S.Perturb(CANNED, "group", 2)), "group: seed 2 differs from seed 1")

    local group = S.Perturb(CANNED, "group", 1)
    assert(#group >= #CANNED and KeepsOrder(group, CANNED, {}), "group: never removes a line")
    assert(Join(Only(group, " TEACH ")) == Join(Only(CANNED, " TEACH ")), "group: TEACH lines identical and in order")
    local added = 0
    for _, line in ipairs(group) do
        local isNew = true
        for _, old in ipairs(CANNED) do isNew = isNew and old ~= line end
        if isNew then
            added = added + 1
            local plate, school, amount, threat, target = line:match(PATTERN.HIT)
            local t = Time(line)
            assert(plate == "nameplate1" and threat == "3" and target == "true", "group: a stranger copies plate, threat, target: " .. line)
            assert(t > 10.4 and t <= 14.0, "group: a stranger lies inside the plate's first-to-last span: " .. line)
            assert(Has(SCHOOLS, tonumber(school)), "group: school in the set: " .. line)
            assert(tonumber(amount) >= AMOUNT_LOW and tonumber(amount) <= AMOUNT_HIGH, "group: amount in " .. AMOUNT_LOW .. ".." .. AMOUNT_HIGH .. ": " .. line)
        end
    end
    assert(added >= 1 and #group == #CANNED + added, "group: at least one stranger, nothing else added")
    local at2 = 0
    for index, line in ipairs(group) do
        if line == CANNED[2] then at2 = index end
    end
    assert(group[at2 + 1] == CANNED[3], "group: a route still directly follows its HIT")

    -- a plate whose threat and target change: a stranger copies the nearest HIT before it, not the plate's first
    local switching = { CANNED[1],
        "10.000 HIT nameplate1 school=4 amount=1 flag= fps=60 threat=3 target=true",
        "20.000 HIT nameplate1 school=4 amount=1 flag= fps=60 threat=1 target=false",
        "30.000 HIT nameplate1 school=4 amount=1 flag= fps=60 threat=3 target=true",
        "31.000 TEACH clean seen=3 meter=3 -> clear" }
    for seed = 1, 5 do
        local lateStrangers = 0
        for _, line in ipairs(S.Perturb(switching, "group", seed)) do
            local _, _, _, threat, target = line:match(PATTERN.HIT)
            local t = Time(line)
            if threat and t > 10 and t < 20 then
                assert(threat == "3" and target == "true", "group: before the switch a stranger carries 3/true, seed " .. seed .. ": " .. line)
            elseif threat and t > 20 and t < 30 then
                lateStrangers = lateStrangers + 1
                assert(threat == "1" and target == "false", "group: after the switch a stranger carries 1/false, seed " .. seed .. ": " .. line)
            end
        end
        assert(lateStrangers >= 1, "group: strangers after the switch, seed " .. seed)
    end

    local onePlate = { CANNED[1], CANNED[2], CANNED[7], CANNED[8] }
    assert(S.Perturb(onePlate, "group", 1) == nil, "group: one HIT per plate adds no stranger")
end

do -- start-up asserts: Perturb distance
    assert(Join(S.Perturb(CANNED, "distance", 1)) ~= Join(S.Perturb(CANNED, "distance", 2)), "distance: seed 2 differs from seed 1")

    local shifts = { 0, table.unpack(SHIFTS) }
    local movedAny = false
    for seed = 1, 20 do
        local out = S.Perturb(CANNED, "distance", seed)
        assert(#out == #CANNED, "distance: same line count, seed " .. seed)
        assert(Join(Only(out, " TEACH ")) == Join(Only(CANNED, " TEACH ")), "distance: TEACH lines identical, seed " .. seed)
        assert(out[17] == CANNED[17], "distance: the tail is unchanged, seed " .. seed)
        for index, line in ipairs(out) do
            if line:match(" HIT ") then
                local source
                for old, text in ipairs(CANNED) do
                    if Rest(text) == Rest(line) then source = old end
                end
                assert(source, "distance: a HIT keeps its text after the stamp: " .. line)
                assert(CleanBefore(out, index) == CleanBefore(CANNED, source), "distance: a HIT stays between the same cleans: " .. line)
                local shift = Time(line) - Time(CANNED[source])
                local near = false
                for _, d in ipairs(shifts) do near = near or math.abs(shift - d) < 0.0005 end
                assert(near, "distance: shift " .. shift .. " is none of " .. table.concat(shifts, ", "))
                movedAny = movedAny or shift > 0.0005
                if CANNED[source + 1]:match("^[%d%.]+   %-> ") then
                    assert(out[index + 1] == Stamp(Time(line)) .. Rest(CANNED[source + 1]), "distance: the route follows its HIT with the same stamp")
                end
            end
        end
    end
    assert(movedAny, "distance: over 20 seeds at least one HIT moved")

    local late = { CANNED[1], "14.950 HIT nameplate1 school=4 amount=5 flag= fps=60 threat=3 target=true", CANNED[7] }
    for seed = 1, 10 do
        assert(Join(S.Perturb(late, "distance", seed)) == Join(late), "distance: a HIT that would pass the clean stays, seed " .. seed)
    end

    -- a HIT before the fight's first CAST is no candidate, even on the plate that is moved
    local early = { "5.000 HIT nameplate1 school=4 amount=5 flag= fps=60 threat=3 target=true", CANNED[1], CANNED[2], CANNED[3], CANNED[7] }
    local movedLater = false
    for seed = 1, 10 do
        local out = S.Perturb(early, "distance", seed)
        assert(out[1] == early[1], "distance: a HIT before the first CAST never moves, seed " .. seed)
        movedLater = movedLater or Join(out) ~= Join(early)
    end
    assert(movedLater, "distance: the HIT after the first CAST moves for some seed")

    assert(S.Perturb({ CANNED[2], CANNED[7] }, "distance", 1) == nil, "distance: no CAST, no plate")
end

do -- start-up asserts: Perturb alias
    local alias = S.Perturb(CANNED, "alias", 1)
    assert(#alias == #CANNED, "alias: same line count")
    for index, line in ipairs(alias) do
        local expect = CANNED[index]
        if index == 8 then expect = "15.000 TEACH 111 tally=2200 meter=2200 verdict=unpaired row=9000111" end
        if index == 14 then expect = "44.000 TEACH 111 tally=900 meter=900 verdict=unpaired row=9000111" end
        assert(line == expect, "alias: line " .. index .. " is " .. expect .. ", got " .. line)
    end
    assert(KeepsOrder(alias, CANNED, { [8] = true, [14] = true }), "alias: never removes a line")
    assert(Join(S.Perturb(CANNED, "alias", 1)) == Join(S.Perturb(CANNED, "alias", 2)), "alias: the seed is ignored")

    -- a cast ID the addon never drew (tally 0 in every row) loses to a smaller-meter one it drew
    local undrawn = { "1.000 CAST player 10 base=10,10", "1.000 CAST player 20 base=20,20",
        "2.000 TEACH 10 tally=0 meter=5000 verdict=unpaired", "2.000 TEACH 20 tally=5 meter=100 verdict=unpaired" }
    local picked = S.Perturb(undrawn, "alias", 1)
    assert(picked[3] == undrawn[3] and picked[4] == undrawn[4] .. " row=" .. 20 + S.ALIAS_OFFSET, "alias: a cast ID with tally 0 everywhere is not chosen")
    -- equal summed meter: the smaller ID, whichever row comes first
    local tied = { "1.000 CAST player 30 base=30,30", "1.000 CAST player 20 base=20,20",
        "2.000 TEACH 30 tally=5 meter=100 verdict=unpaired", "2.000 TEACH 20 tally=5 meter=100 verdict=unpaired" }
    local chosen = S.Perturb(tied, "alias", 1)
    assert(chosen[3] == tied[3] and chosen[4] == tied[4] .. " row=" .. 20 + S.ALIAS_OFFSET, "alias: equal meters pick the smaller ID")

    assert(S.Perturb({ CANNED[13], CANNED[15], CANNED[16] }, "alias", 1) == nil, "alias: no CAST line, no cast-paired row")
end

do -- start-up asserts: Fabricate
    local SPELL_OF = { doublecast = { [32] = SPELL_A, [4] = SPELL_B } }
    local HOP = { aoe = { 0.05, 0.12 }, ["aoe-spread"] = { 0.3, 0.6 } }

    for _, case in ipairs(S.FABRICATE_CASES) do
        local label = case .. ": "
        local lines = S.Fabricate(case, 1)
        assert(table.concat(lines, "\n") == table.concat(S.Fabricate(case, 1), "\n"), label .. "the same seed gives the same lines")
        assert(table.concat(lines, "\n") ~= table.concat(S.Fabricate(case, 2), "\n"), label .. "seed 2 differs from seed 1")

        -- grammar, order, and per-fight truth in one walk
        local cleans, previous, previousClean = 0, -1, -1
        local totals, sum, casts, hits = {}, 0, {}, {}
        local rows = {}
        for index, line in ipairs(lines) do
            local isRow = line:match(PATTERN.ROW)
            local cast, hit, clean = line:match(PATTERN.CAST), line:match(PATTERN.HIT), line:match(PATTERN.CLEAN)
            assert(cast or hit or clean or isRow, label .. "line " .. index .. " matches no pattern: " .. line)
            assert(not line:match(" row="), label .. "no row= in " .. line)
            local t = Time(line)
            assert(t >= previous, label .. "t never decreases at line " .. index)
            previous = t
            if hit then
                local plate, school, amount = line:match(PATTERN.HIT)
                assert(t > previousClean, label .. "a HIT after the previous clean: " .. line)
                local spell = SPELL_OF[case] and SPELL_OF[case][tonumber(school)] or SPELL_C
                totals[spell] = (totals[spell] or 0) + tonumber(amount)
                sum = sum + tonumber(amount)
                hits[#hits + 1] = { t = t, plate = plate, target = line:match("target=(%a+)$"), school = tonumber(school), spell = spell }
            elseif cast then
                casts[#casts + 1] = { t = t, id = tonumber(cast), at = #hits }
            elseif clean then
                cleans = cleans + 1
                local seen, meter = line:match(PATTERN.CLEAN)
                assert(tonumber(seen) == sum and tonumber(meter) == sum, label .. "clean seen = meter = the fight's HIT sum: " .. line)
                assert(t > hits[#hits].t, label .. "the clean is after the fight's last HIT")
                previousClean, rows = t, {}
            elseif isRow then
                local id, _, meter = line:match(PATTERN.ROW)
                assert(t == previousClean, label .. "a row shares its clean's stamp: " .. line)
                assert(tonumber(meter) == totals[tonumber(id)], label .. "row " .. id .. " meter is the spell's HIT sum: " .. line)
                rows[#rows + 1] = tonumber(id)
                if index == #lines or not lines[index + 1]:match(PATTERN.ROW) then
                    local expect = {}
                    for spell in pairs(totals) do expect[#expect + 1] = spell end
                    table.sort(expect)
                    assert(table.concat(rows, ",") == table.concat(expect, ","), label .. "one row per spell with a total, ascending ID")
                    totals, sum = {}, 0
                end
            end
        end
        assert(cleans == S.FIGHTS, label .. S.FIGHTS .. " fights, got " .. cleans)
        assert(#hits > 0 and #casts > 0, label .. "has casts and HITs")

        if case == "doublecast" then
            CheckDoublecast(label, casts, hits)
        else
            CheckArea(label, casts, hits, HOP[case][1], HOP[case][2])
        end
    end
end

return S
