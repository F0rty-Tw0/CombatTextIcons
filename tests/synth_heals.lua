-- Heal synth: fabricated score-format logs of heals on the player with a true spell ID per HEAL line, replayed as
-- tests/heals.lua replays the real ones and scored against that truth. Synthetic: it shows, never gates; the real
-- logs judge (tests/heals.lua).
--
--   lua tests/synth_heals.lua    each case's coverage of its own heals, wrong and foreign, per true ID
--
-- The player's health: MAX_HP, damage taken each second, every heal on the player in line order fills at most the
-- missing health. A row (TEACH heal) is the effective healing of its ID, as the meter's healing-done rows are; an ID
-- that only overhealed in a fight has no row. HEAL lines carry the raw amount, overheal included.
-- Sources (case.sources), each healing the player:
--   cast    a helpful cast (id) whose heal lands on its own stamp, logged the line before the CAST line, sized in
--           [low, high]; `with` = another helpful cast on the same stamp (a totem going out with Chain Heal)
--   fixed   a castless proc (id) of one size, `crit` its crit chance (a crit is twice the size); `on` = a cast
--           source's ID: it lands on that cast's stamp, else at random
--   train   ticks of `size` (jitter `spread`) every `period` s (each tick `late` s late at most), `ticks` of them
--           after each cast of `cast` (nil: castless, starting at random); `after` = a cast that starts the train
--           without being its spell (a proc of the cast under another ID: drawn under that cast, it is wrong)
--   leech   `ratio` of each of your hits, on the hit's stamp (`id` DAMAGE_ID: the damage spell heals, a drain)
--   foreign another player's heals on you (unit player) or on a party member (`unit`): never a row
-- Scored per heal: right (drawn under its true ID or its cast's), wrong (drawn under another ID, or a foreign heal
-- named at all), '?', hidden. Shares of each case's raw.

local Synth = dofile("tests/synth.lua")
local L = dofile("tests/score_lib.lua")
local Pct, Out = L.Pct, L.Out

local MAX_HP = 400000
local DAMAGE_ID, FIGHT, GAP = 100, 30, 20 -- your damage spell, a fight's seconds, seconds between fights

local CASES = {
    { name = "fixed procs", fights = 8, pressure = 0.04, sources = {
        { kind = "fixed", id = 1287908, size = 5763, crit = 0.3, rate = 4 },
        { kind = "fixed", id = 1263002, size = 11527, crit = 0, rate = 1 },
        { kind = "cast", id = 85673, low = 70000, high = 90000, crit = 0.2, rate = 3 },
        { kind = "foreign", size = { 20000, 60000 }, rate = 3 },
    } },
    { name = "one size, two IDs", fights = 8, pressure = 0.04, sources = {
        { kind = "fixed", id = 1263002, size = 11527, rate = 2 },
        { kind = "fixed", id = 1287908, size = 11527, rate = 2 },
    } },
    { name = "proc on a cast's stamp", fights = 8, pressure = 0.04, sources = {
        { kind = "cast", id = 85673, low = 70000, high = 90000, crit = 0.2, rate = 3 },
        { kind = "fixed", id = 1287665, size = 720, on = 85673, rate = 3 },
    } },
    { name = "overheal", fights = 8, pressure = 0.005, sources = {
        { kind = "fixed", id = 1287908, size = 5763, crit = 0.3, rate = 4 },
        { kind = "train", id = 5394, cast = 5394, size = 12000, spread = 0.1, period = 1.5, ticks = 12, rate = 1 },
        { kind = "cast", id = 1064, low = 40000, high = 130000, rate = 4 },
    } },
    { name = "totem with a cast", fights = 8, pressure = 0.06, sources = {
        { kind = "cast", id = 1064, low = 40000, high = 130000, rate = 4, with = 5394 },
        { kind = "train", id = 5394, cast = 5394, size = 12000, spread = 0.1, crit = 0.1, period = 1.5, ticks = 12 },
    } },
    { name = "leech", fights = 8, pressure = 0.04, sources = {
        { kind = "leech", id = 143924, ratio = 0.06 },
        { kind = "foreign", unit = "party1", size = { 20000, 60000 }, rate = 4 },
    } },
    -- Drain Life (lock3: 234153 heals 7 x each tick under its own ID) beside a foreign heal on you
    { name = "drain", fights = 8, pressure = 0.04, sources = {
        { kind = "leech", id = DAMAGE_ID, ratio = 7 },
        { kind = "foreign", size = { 20000, 60000 }, rate = 3 },
    } },
    -- A HoT's ticks after its own cast, beside a castless rune train, a fixed proc and foreign heals on you
    { name = "hot after its cast", fights = 8, pressure = 0.04, sources = {
        { kind = "train", id = 139, cast = 139, size = 9000, spread = 0.1, crit = 0.1, period = 1.5, late = 0.05,
            ticks = 8, rate = 2 },
        { kind = "train", id = 1287665, size = 720, period = 1, ticks = 10, rate = 1 },
        { kind = "fixed", id = 1287908, size = 5763, crit = 0.3, rate = 2 },
        { kind = "foreign", size = { 5000, 40000 }, rate = 6 },
    } },
    -- shamanheal: each totem goes out on a Chain Heal's stamp, and Chain Heal also goes out alone
    { name = "totem beside chain heal", fights = 8, pressure = 0.06, sources = {
        { kind = "cast", id = 1064, low = 40000, high = 130000, rate = 2 },
        { kind = "cast", id = 1064, low = 40000, high = 130000, rate = 1, with = 5394 },
        { kind = "train", id = 5394, cast = 5394, size = 14000, spread = 0.1, crit = 0.1, period = 1.5, late = 0.05,
            ticks = 12 },
        { kind = "foreign", size = { 5000, 30000 }, rate = 4 },
    } },
    -- paladin: Word of Glory starts a 720 rune train under the rune's ID, which also runs with no cast
    { name = "proc train on a cast", fights = 8, pressure = 0.04, sources = {
        { kind = "cast", id = 85673, low = 70000, high = 90000, crit = 0.2, rate = 3 },
        { kind = "train", id = 1287665, after = 85673, size = 720, period = 1, late = 0.02, ticks = 8 },
        { kind = "train", id = 1287665, size = 720, period = 1, ticks = 8, rate = 1 },
    } },
}

local function Stamp(t) return string.format("%.3f", t) end

-- One fight's events from t0: { t, order, line, id (true ID, nil: foreign), unit, raw, crit, cast (a cast line) }.
local function FightEvents(case, rand, t0)
    local events = {}
    local function Add(event) event.order = #events events[#events + 1] = event return event end
    local hits = {}
    for t = t0 + 0.5, t0 + FIGHT, 1.5 do
        local stamp = math.floor(t * 1000 + rand() * 300) / 1000
        Add({ t = stamp, cast = DAMAGE_ID })
        hits[#hits + 1] = Add({ t = stamp + 0.2, hit = math.floor(8000 + rand() * 4000) })
    end
    local castStamps = {}
    local function At() return t0 + 1 + math.floor(rand() * (FIGHT - 2) * 1000) / 1000 end
    for _, source in ipairs(case.sources) do
        if source.kind == "cast" then
            castStamps[source.id] = {}
            for _ = 1, source.rate do
                local t = At()
                local crit = rand() < (source.crit or 0)
                local size = math.floor(source.low + rand() * (source.high - source.low))
                Add({ t = t, id = source.id, unit = "player", raw = crit and 2 * size or size, crit = crit })
                Add({ t = t, cast = source.id })
                if source.with then Add({ t = t, cast = source.with }) castStamps[source.with] = castStamps[source.with] or {} table.insert(castStamps[source.with], t) end
                table.insert(castStamps[source.id], t)
            end
        end
    end
    for _, source in ipairs(case.sources) do
        if source.kind == "fixed" then
            for index = 1, source.rate do
                local t = source.on and castStamps[source.on][index] or At()
                if t then
                    local crit = rand() < (source.crit or 0)
                    Add({ t = t, id = source.id, unit = "player", raw = crit and 2 * source.size or source.size, crit = crit })
                end
            end
        elseif source.kind == "train" then
            local starts = castStamps[source.cast or source.after] or {}
            if not (source.cast or source.after) then for _ = 1, source.rate do starts[#starts + 1] = At() end end
            if source.cast and #starts == 0 then
                for _ = 1, source.rate or 1 do
                    local t = At()
                    Add({ t = t, cast = source.cast })
                    starts[#starts + 1] = t
                end
            end
            for _, start in ipairs(starts) do
                for tick = 1, source.ticks do
                    local crit = rand() < (source.crit or 0)
                    local size = math.floor(source.size * (1 + (source.spread or 0) * (2 * rand() - 1)))
                    local late = source.late and rand() * source.late or 0
                    Add({ t = start + tick * source.period + late, id = source.id, unit = "player",
                        raw = crit and 2 * size or size, crit = crit })
                end
            end
        elseif source.kind == "leech" then
            for _, hit in ipairs(hits) do
                Add({ t = hit.t, id = source.id, unit = "player", raw = math.floor(hit.hit * source.ratio), crit = false })
            end
        elseif source.kind == "foreign" then
            for _ = 1, source.rate do
                Add({ t = At(), unit = source.unit or "player",
                    raw = math.floor(source.size[1] + rand() * (source.size[2] - source.size[1])) })
            end
        end
    end
    table.sort(events, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.order < b.order end)
    return events
end

-- The case's log lines and truth[line index] = the heal's true ID (false: foreign) for every HEAL line.
local function Generate(case, seed)
    local rand = Synth.Seeded(seed)
    local lines, truth, hp = {}, {}, MAX_HP
    for fight = 1, case.fights do
        local t0 = 1000 + (fight - 1) * (FIGHT + GAP)
        local effective, damage, lastT = {}, 0, t0
        for _, event in ipairs(FightEvents(case, rand, t0)) do
            hp = math.max(1, hp - (event.t - lastT) * case.pressure * MAX_HP)
            lastT = event.t
            if event.cast then
                lines[#lines + 1] = Stamp(event.t) .. " CAST player " .. event.cast .. " base=" .. event.cast .. "," .. event.cast
            elseif event.hit then
                damage = damage + event.hit
                lines[#lines + 1] = Stamp(event.t) .. " HIT nameplate1 school=4 amount=" .. event.hit
                    .. " flag= fps=60 threat=3 target=true"
            else
                lines[#lines + 1] = Stamp(event.t) .. " HEAL " .. event.unit .. " school=1 amount=" .. event.raw .. " flag="
                    .. (event.crit and "CRITICAL" or "")
                truth[#lines] = event.id or false
                if event.unit == "player" then
                    local gain = math.min(event.raw, MAX_HP - hp)
                    hp = hp + gain
                    if event.id then effective[event.id] = (effective[event.id] or 0) + gain end
                end
            end
        end
        local endAt = Stamp(t0 + FIGHT + 1)
        lines[#lines + 1] = endAt .. " TEACH clean seen=" .. damage .. " meter=" .. damage .. " -> clear"
        lines[#lines + 1] = endAt .. " TEACH " .. DAMAGE_ID .. " tally=0 meter=" .. damage .. " verdict=unpaired"
        local ids = {}
        for id, amount in pairs(effective) do if amount > 0 then ids[#ids + 1] = id end end
        table.sort(ids, function(a, b) return effective[a] > effective[b] end)
        for _, id in ipairs(ids) do
            lines[#lines + 1] = endAt .. " TEACH heal " .. id .. " meter=" .. math.floor(effective[id]) .. " over=0"
        end
        hp = MAX_HP
    end
    return lines, truth
end

-- The helpful cast IDs of a case and the IDs a heal of each true ID may be drawn under (its own, its train's cast).
local function CaseIDs(case)
    local helpful, accepts = {}, {}
    for _, source in ipairs(case.sources) do
        if source.kind == "cast" then helpful[#helpful + 1] = source.id end
        if source.with then helpful[#helpful + 1] = source.with end
        if source.kind == "train" and source.cast then helpful[#helpful + 1] = source.cast end
        if source.id then
            accepts[source.id] = { [source.id] = true }
            if source.cast then accepts[source.id][source.cast] = true end
        end
    end
    return helpful, accepts
end

local function NamedID(shown)
    return shown and type(shown.texture) == "string" and tonumber(shown.texture:match("^tex:(%d+)$")) or nil
end

local function NewScore() return { raw = 0, right = 0, wrong = 0, unknown = 0, hidden = 0 } end

local function Score(case, seed)
    local lines, truth = Generate(case, seed)
    local helpful, accepts = CaseIDs(case)
    local function setup(ns, S)
        for _, id in ipairs(helpful) do S.harmful[id], S.helpful[id] = false, true end
    end
    local total, byID = NewScore(), {}
    for _, run in ipairs(L.H.ReplayFights("x", { log = lines, fixture = { startArea = "unknown" }, setup = setup })) do
        for _, heal in ipairs(run.info.heals) do
            local id, amount = truth[heal.event.line], heal.event.amount
            local key = id or "foreign"
            local stat = byID[key] or NewScore()
            byID[key] = stat
            local named = NamedID(heal.shown)
            local field = named and ((id and accepts[id][named]) and "right" or "wrong")
                or heal.shown and "unknown" or "hidden"            for _, into in ipairs({ total, stat }) do
                into.raw, into[field] = into.raw + amount, into[field] + amount
            end
        end
    end
    return total, byID
end

local function Line(label, score)
    Out(string.format("  %-28s %10d  right %5.1f%%  wrong %5.2f%%  ? %5.1f%%  hidden %5.1f%%", label, score.raw,
        Pct(score.right, score.raw), Pct(score.wrong, score.raw), Pct(score.unknown, score.raw),
        Pct(score.hidden, score.raw)))
end

for index, case in ipairs(CASES) do
    local total, byID = Score(case, index)
    Line(case.name .. " (synthetic)", total)
    local keys = {}
    for key in pairs(byID) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do Line("    " .. tostring(key), byID[key]) end
end
