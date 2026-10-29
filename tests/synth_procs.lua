-- Proc synth: fabricated score-format logs of the player's damage with a true spell ID per HIT line, replayed as
-- tests/fresh.lua replays the real ones and scored against that truth. Synthetic: it shows, never gates; the real logs
-- judge (tests/fresh.lua).
--
--   lua tests/synth_procs.lua    each case's right, wrong and '?' per true ID, shares of the case's damage
--
-- A fight is FIGHT s on nameplate1 (the target) and up to three more plates; its meter rows are each true ID's sum.
-- Sources (case.sources):
--   cast   a harmful cast (id) every `every` s, its hit 0.4 s later on the target, sized in [low, high], a crit twice
--          that at `crit` chance
--   proc   a castless proc (id): `rate` times a fight at random, sized `size` x [1, 1 + spread], a crit twice that at
--          `crit` chance (1: it only crits, as shamanele's 285452), on `plates` plates on one stamp at one size;
--          `skip` = fights it does not fire in
-- Scored per hit: right (drawn under its true ID), wrong (drawn under another ID), '?' (the question mark, or nothing).

local Synth = dofile("tests/synth.lua")
local L = dofile("tests/score_lib.lua")
local Pct, Out = L.Pct, L.Out

local FIGHT, GAP = 30, 20 -- a fight's seconds, seconds between fights

local CASES = {
    -- shamanele F3: four crits, 43116-56732 (1.32x), summed to 285452's row; 43116 sat in a cast's crit window
    { name = "crit-only proc beside a cast", fights = 8, sources = {
        { kind = "cast", id = 51505, school = 4, low = 16000, high = 18000, crit = 0.25, every = 2.5 },
        { kind = "proc", id = 285452, school = 4, size = 21500, spread = 0.32, crit = 1, rate = 5, skip = { 4 } },
    } },
    -- hunter 118459 (inferred): one size on several plates in one frame
    { name = "crit-only proc on three plates", fights = 8, sources = {
        { kind = "cast", id = 51505, school = 4, low = 16000, high = 18000, crit = 0.25, every = 2.5 },
        { kind = "proc", id = 447419, school = 4, size = 18000, spread = 0.05, crit = 1, rate = 3, plates = 3 },
    } },
    -- a proc that crits once a fight is too thin to learn from: it must stay '?', never draw another's crits
    { name = "one crit a fight", fights = 8, sources = {
        { kind = "cast", id = 51505, school = 4, low = 16000, high = 18000, crit = 0.25, every = 2.5 },
        { kind = "proc", id = 1259101, school = 8, size = 24000, spread = 0.7, crit = 1, rate = 1 },
        { kind = "proc", id = 447425, school = 8, size = 26000, spread = 0.1, crit = 1, rate = 4, skip = { 2, 5 } },
    } },
}

local function Stamp(t) return string.format("%.3f", t) end

-- One fight's events from t0: { t, order, cast } or { t, order, id, school, amount, crit, plate }.
local function FightEvents(case, fight, rand, t0)
    local events = {}
    local function Add(event) event.order = #events events[#events + 1] = event end
    local function Sized(low, high, critChance)
        local crit = rand() < critChance
        local size = math.floor(low + rand() * (high - low))
        return crit and 2 * size or size, crit
    end
    for _, source in ipairs(case.sources) do
        local skipped = false
        for _, index in ipairs(source.skip or {}) do skipped = skipped or index == fight end
        if source.kind == "cast" then
            for t = t0 + 0.5, t0 + FIGHT, source.every do
                local stamp = math.floor(t * 1000 + rand() * 300) / 1000
                local amount, crit = Sized(source.low, source.high, source.crit)
                Add({ t = stamp, cast = source.id })
                Add({ t = stamp + 0.4, id = source.id, school = source.school, amount = amount, crit = crit, plate = 1 })
            end
        elseif source.kind == "proc" and not skipped then
            for _ = 1, source.rate do
                local stamp = t0 + 1 + math.floor(rand() * (FIGHT - 2) * 1000) / 1000
                local amount, crit = Sized(source.size, source.size * (1 + source.spread), source.crit)
                for plate = 1, source.plates or 1 do
                    Add({ t = stamp, id = source.id, school = source.school, amount = amount, crit = crit, plate = plate })
                end
            end
        end
    end
    table.sort(events, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.order < b.order end)
    return events
end

-- The case's log lines and truth[line index] = the hit's true ID.
local function Generate(case, seed)
    local rand = Synth.Seeded(seed)
    local lines, truth = {}, {}
    for fight = 1, case.fights do
        local t0 = 1000 + (fight - 1) * (FIGHT + GAP)
        local totals, sum = {}, 0
        for _, event in ipairs(FightEvents(case, fight, rand, t0)) do
            if event.cast then
                lines[#lines + 1] = Stamp(event.t) .. " CAST player " .. event.cast .. " base=" .. event.cast .. "," .. event.cast
            else
                lines[#lines + 1] = Stamp(event.t) .. " HIT nameplate" .. event.plate .. " school=" .. event.school .. " amount="
                    .. event.amount .. " flag=" .. (event.crit and "CRITICAL" or "") .. " fps=60 threat=3 target="
                    .. tostring(event.plate == 1)
                truth[#lines] = event.id
                totals[event.id] = (totals[event.id] or 0) + event.amount
                sum = sum + event.amount
            end
        end
        local endAt = Stamp(t0 + FIGHT + 1)
        lines[#lines + 1] = endAt .. " TEACH clean seen=" .. sum .. " meter=" .. sum .. " -> clear"
        local ids = {}
        for id in pairs(totals) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return totals[a] > totals[b] end)
        for _, id in ipairs(ids) do
            lines[#lines + 1] = endAt .. " TEACH " .. id .. " tally=0 meter=" .. totals[id] .. " verdict=unpaired"
        end
    end
    return lines, truth
end

local function NamedID(shown)
    return shown and type(shown.texture) == "string" and tonumber(shown.texture:match("^tex:(%d+)$")) or nil
end

local function NewScore() return { raw = 0, right = 0, wrong = 0, unknown = 0 } end

local function Score(case, seed)
    local lines, truth = Generate(case, seed)
    local total, byID = NewScore(), {}
    for _, run in ipairs(L.H.ReplayFights("x", { log = lines, fixture = { startArea = "crowded" } })) do
        for _, hit in ipairs(run.hits) do
            local id, amount = truth[hit.event.line], hit.event.amount
            if id then
                local stat = byID[id] or NewScore()
                byID[id] = stat
                local named = NamedID(hit.shown)
                local field = named and (named == id and "right" or "wrong") or "unknown"
                for _, into in ipairs({ total, stat }) do
                    into.raw, into[field] = into.raw + amount, into[field] + amount
                end
            end
        end
    end
    return total, byID
end

local function Line(label, score)
    Out(string.format("  %-34s %10d  right %5.1f%%  wrong %5.2f%%  ? %5.1f%%", label, score.raw, Pct(score.right, score.raw),
        Pct(score.wrong, score.raw), Pct(score.unknown, score.raw)))
end

for index, case in ipairs(CASES) do
    local total, byID = Score(case, index)
    Line(case.name .. " (synthetic)", total)
    local keys = {}
    for key in pairs(byID) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do Line("    " .. key, byID[key]) end
end
