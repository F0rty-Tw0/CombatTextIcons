-- Bench: the scoreboard's replays under scenarios that vary the order the addon learns in. A harness for the fix
-- loop: deterministic (a local Park-Miller Rng, never math.random), no scenario touches the addon.
--
--   lua tests/bench.lua [--only id[,id...]] [--json path] [--k N]
--
-- --json writes every scenario that ran (class -> right, wrong, unknown, fights, min, mean, max, maxWrong, curve), the
-- base runs, the flakes and the seconds as sorted-key JSON.
--
--   base     tests/score.lua's runs (fresh and start), rebuilt on cached slices and checked against score_lib's path
--   shuffle  each log's fights in K seeded orders from an empty store, times shifted so the clock never runs back
--   chain    each class's logs' fights in log order as one session from an empty store (per-fight right % curve)
--   loo      leave-one-out: a class's other logs chained first, then the held-out log's fights, scored on those alone
--   flake    two child runs of base: the per-run lines must match (flakes: 0), else one `flake: <label>` each
--
-- The druid is the hold-out class: shown, never in TOTAL.

local function Rng(seed) -- Park-Miller: the same numbers on every Lua version (checks_streams.lua)
    local state = seed
    return function() state = (state * 16807) % 2147483647 return state / 2147483647 end
end

-- Fisher-Yates on a copy. Park-Miller from a small seed starts tiny and correlated across seeds, so the seed is spread.
local function Permute(list, seed)
    local copy, rand = table.move(list, 1, #list, 1, {}), Rng(seed * 1103515245 % 2147483646 + 1)
    for i = #copy, 2, -1 do
        local j = 1 + math.floor(rand() * i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    return copy
end

-- New slices (and event copies) laid end to end: each slice's first t is the previous slice's last t + 60, gaps
-- inside a slice and every `line` unchanged. Replay sets the clock from t and saved learning keeps times.
local function Shift(slices)
    local shifted, top = {}, nil
    for index, slice in ipairs(slices) do
        local first = slice.events[1]
        local offset = (top and first) and top + 60 - first.t or 0
        local copy = {}
        for key, value in pairs(slice) do copy[key] = value end
        copy.events = {}
        for i, event in ipairs(slice.events) do
            local clone = {}
            for key, value in pairs(event) do clone[key] = value end
            clone.t = event.t + offset
            copy.events[i] = clone
            top = math.max(top or clone.t, clone.t)
        end
        shifted[index] = copy
    end
    return shifted
end

do -- start-up asserts
    local function Slice(...)
        local events = {}
        for i, t in ipairs({ ... }) do events[i] = { t = t, line = i } end
        return { events = events }
    end
    local input = { Slice(10, 10, 12), Slice(5, 7), Slice(1) }
    local out = Shift(input)
    assert(out[1].events[1].t == 10 and out[1].events[3].t == 12, "Shift: slice 1 unshifted")
    assert(out[2].events[1].t == 72 and out[2].events[2].t == 74, "Shift: slice 2 starts at 72, keeps its 2 s gap")
    assert(out[3].events[1].t == 134, "Shift: slice 3 starts at 134")
    assert(out[2].events[2].line == 2 and out[3].events[1].line == 1, "Shift: line unchanged")
    assert(input[2].events[1].t == 5 and input[2].events[2].t == 7 and input[3].events[1].t == 1, "Shift copies, never mutates")
    assert(out[2].events[1] ~= input[2].events[1], "Shift: events are copies")

    local one, two = Permute({ 1, 2, 3, 4, 5 }, 1), Permute({ 1, 2, 3, 4, 5 }, 1)
    assert(table.concat(one, ",") == table.concat(two, ","), "Permute: the same seed gives the same order")
    local sorted = table.move(one, 1, 5, 1, {})
    table.sort(sorted)
    assert(table.concat(sorted, ",") == "1,2,3,4,5", "Permute: a permutation of 1..5")
    assert(table.concat(Permute({ 1, 2, 3, 4, 5 }, 2), ",") ~= table.concat(one, ","), "Permute: seed 2 differs from seed 1")
end

-- JSON text of a value: object keys sorted (the same bytes every run), an empty table is [], floats to 0.01.
local function Encode(value)
    local kind = type(value)
    if kind == "number" then
        if math.type(value) == "integer" then return string.format("%d", value) end
        return (string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", ""))
    elseif kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(char) return string.format("\\u%04x", char:byte()) end) .. '"'
    elseif kind == "boolean" then
        return tostring(value)
    end
    assert(kind == "table", "Encode: unsupported " .. kind)
    local count, parts = 0, {}
    for _ in pairs(value) do count = count + 1 end
    if count == 0 then return "[]" end
    if count == #value then
        for index, item in ipairs(value) do parts[index] = Encode(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for index, key in ipairs(keys) do parts[index] = Encode(tostring(key)) .. ":" .. Encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
assert(Encode({ c = { d = "x" }, b = { 1, 2 }, a = 1.5, e = {} }) == '{"a":1.5,"b":[1,2],"c":{"d":"x"},"e":[]}',
    "Encode: sorted keys, arrays, [] for an empty table")
assert(Encode({ 1, 2, x = 3 }) == '{"1":1,"2":2,"x":3}', "Encode: a mixed table is an object, number keys as strings")
assert(Encode({ [2] = "v" }) == '{"2":"v"}', "Encode: a table with a hole is an object")

-- The per-run lines of a base run's output: labels in output order, and label -> line. They sit between the
-- `run  fights  meter` header and the next blank line, in score_lib's Line format. A child with none is an error:
-- two empty parses would match and pass the flake check for nothing.
local function ParseRuns(text)
    local labels, lines, inside = {}, {}, false
    for line in text:gmatch("([^\n]*)\n") do
        if inside and line == "" then break end
        local label = inside and line:match("^%s*(.-)%s+%d+%s+%d+%s+right")
        if label then
            labels[#labels + 1], lines[label] = label, line
        end
        inside = inside or line:match("^run%s+fights%s+meter") ~= nil
    end
    assert(#labels > 0, "flake: no per-run lines in the child's output")
    return labels, lines
end
do
    local canned = "== base ==\nrun                        fights  meter\n  lock fresh                   3    3478242  right   2.9%  wrong   5.9%  ?  97.1%\n"
        .. "  lock2 start                  5    6879333  right  24.0%  wrong   5.1%  ?  76.0%\n\n  warlock   13   17236908  right  18.3%\n"
    local labels, lines = ParseRuns(canned)
    assert(#labels == 2 and labels[1] == "lock fresh" and labels[2] == "lock2 start", "ParseRuns: the per-run labels, in order")
    assert(lines["lock fresh"]:find("2.9%", 1, true), "ParseRuns: label -> its line")
    assert(not pcall(ParseRuns, "== base ==\nBENCH done in 1 s\n"), "ParseRuns: output with no per-run lines is an error")
end

local ONLY, JSON, K = nil, nil, 8
do
    local index = 1
    while index <= #arg do
        local flag = arg[index]
        if flag == "--only" then
            ONLY, index = {}, index + 1
            for id in assert(arg[index], "--only needs ids"):gmatch("[^,]+") do ONLY[id] = true end
        elseif flag == "--json" then
            index = index + 1
            JSON = assert(arg[index], "--json needs a path")
        elseif flag == "--k" then
            index = index + 1
            K = assert(tonumber(arg[index]), "--k needs a number")
            assert(K >= 1 and K == math.floor(K), "--k must be a positive whole number")
        else
            error("unknown option " .. flag)
        end
        index = index + 1
    end
end

local wallStart = os.time()
local L = dofile("tests/score_lib.lua")
local H, Setup = L.H, L.Setup
local ScoreFight, NewScore, NewTotal, ClassLabel, Add, Pct, Line, Out = L.ScoreFight, L.NewScore, L.NewTotal, L.ClassLabel, L.Add,
    L.Pct, L.Line, L.Out

-- Every log once: slices (tail included, for base), fights (slices with rows), the class's start save when there is one.
local LOGS = L.LoadLogs()
for _, log in ipairs(LOGS) do
    log.slices = H.SplitFights(log.name, { log = log.opts.log, fixture = log.opts.fixture, label = log.log })
    log.fights = {}
    for _, slice in ipairs(log.slices) do
        if slice.rows and #slice.rows > 0 then log.fights[#log.fights + 1] = slice end
    end
end

local function SameBases(bases, count)
    local list = {}
    for i = 1, count do list[i] = bases end
    return list
end

-- The classes in LOGS order, each with its logs; Chain(logs) -> the logs' fights end to end and each slice's bases.
local classOrder, byClass = {}, {}
for _, log in ipairs(LOGS) do
    if not byClass[log.class] then
        byClass[log.class] = {}
        classOrder[#classOrder + 1] = log.class
    end
    table.insert(byClass[log.class], log)
end
local function Chain(logs)
    local slices, bases = {}, {}
    for _, log in ipairs(logs) do
        for _, fight in ipairs(log.fights) do
            slices[#slices + 1] = fight
            bases[#slices] = log.bases
        end
    end
    return slices, bases
end
do -- the label is what tells a chain's logs apart (RUNS all split under the name "x") and resets the area between them
    local slices = Chain(byClass.shaman)
    local seen = false
    for _, slice in ipairs(slices) do seen = seen or slice.log == "shaman3" end
    assert(slices[1].log == "shaman2" and seen, "Chain: shaman starts at shaman2 and holds shaman3 slices")
end

-- Replays `slices` in order and scores each fight with rows from slice opts.first (default 1) on; the earlier ones
-- only teach. bases[i] is slice i's base spells; opts.charDB seeds the first slice. score.curve[n] = { pos = the
-- slice's index, right, meter, wrong, unknown } of the n-th scored fight, for a per-position curve.
local function ScoreSession(class, slices, bases, opts)
    local score, tallies, boots = NewScore(opts.label or class), {}, 0
    score.curve = {}
    local runs = H.ReplaySlices(slices, { charDB = opts.charDB, setup = function(ns, S)
        boots = boots + 1
        Setup(class, bases[boots], tallies)(ns, S)
    end })
    for index = opts.first or 1, #runs do
        local run = runs[index]
        if run.rows and #run.rows > 0 then
            local fight = NewScore("fight")
            ScoreFight(run.rows, tallies[index], run.last, fight)
            Add(score, fight)
            score.curve[#score.curve + 1] = { pos = index, right = fight.right, meter = fight.meter, wrong = fight.wrong,
                unknown = fight.unknown }
        end
    end
    return score
end

-- A score's headline numbers, the JSON-ready record of one line.
local function Summary(score)
    return { label = score.label, fights = score.fights, meter = score.meter, right = Pct(score.right, score.meter),
        wrong = Pct(score.wrong, score.meter), unknown = Pct(score.unknown, score.meter) }
end

local results = {} -- scenario id -> its numbers, for the JSON writer

-- base ------------------------------------------------------------------------------------------------------
-- Whether two scores differ: fights and meter exactly (integer sums), the three shares by more than 0.005 points.
local function Differs(a, b)
    if a.fights ~= b.fights or a.meter ~= b.meter then return true end
    for _, field in ipairs({ "right", "wrong", "unknown" }) do
        if math.abs(Pct(a[field], a.meter) - Pct(b[field], b.meter)) > 0.005 then return true end
    end
    return false
end
do -- start-up asserts: equal shares are not enough
    local function Score(fights, meter, right)
        local score = NewScore("check")
        score.fights, score.meter, score.right, score.unknown = fights, meter, right, meter - right
        return score
    end
    assert(not Differs(Score(3, 100, 50), Score(3, 100, 50)), "Differs: equal scores match")
    assert(Differs(Score(3, 100, 50), Score(3, 100, 60)), "Differs: a different share")
    assert(Differs(Score(3, 100, 50), Score(3, 200, 100)), "Differs: the same shares of a different meter")
    assert(Differs(Score(3, 100, 50), Score(4, 100, 50)), "Differs: the same shares over a different fight count")
end

local function RunBase()
    local base = L.Collect(LOGS, function(log, charDB)
        return ScoreSession(log.class, log.slices, SameBases(log.bases, #log.slices), { charDB = charDB })
    end)
    Out("run                        fights  meter")
    for _, run in ipairs(base.runs) do Line(run.score) end
    Out("")
    for _, class in ipairs(base.order) do Line(base.classes[class]) end
    Line(base.total)

    local reference = L.Collect(LOGS, L.Run) -- score.lua's own path
    for index, run in ipairs(base.runs) do
        assert(not Differs(run.score, reference.runs[index].score), "base differs from score_lib on " .. run.score.label)
    end
    for _, class in ipairs(base.order) do
        assert(not Differs(base.classes[class], reference.classes[class]), "base differs from score_lib on class " .. class)
    end
    assert(not Differs(base.total, reference.total), "base differs from score_lib on TOTAL")

    local record = { runs = {}, classes = {}, order = base.order, total = Summary(base.total) }
    for index, run in ipairs(base.runs) do
        record.runs[index] = Summary(run.score)
        record.runs[index].class, record.runs[index].holdout = run.class, run.holdout
    end
    for _, class in ipairs(base.order) do record.classes[class] = Summary(base.classes[class]) end
    results.base = record
end

-- shuffle ---------------------------------------------------------------------------------------------------
-- Seed 1..K: every log's fights in that seed's order, times shifted, from an empty store. A class's score per seed
-- is its logs summed; the spread is over seeds, the line's numbers are the seeds pooled (per seed: fights, meter).
local function Spread(values)
    local low, high, sum = math.huge, -math.huge, 0
    for _, value in ipairs(values) do
        low, high, sum = math.min(low, value), math.max(high, value), sum + value
    end
    return { min = low, mean = sum / #values, max = high }
end

local function RunShuffle()
    local perSeed, order, holdout = {}, {}, {}
    for seed = 1, K do
        local classes, total = {}, NewTotal()
        for _, log in ipairs(LOGS) do
            if #log.fights == 0 then
                if seed == 1 then Out("skip " .. log.log .. ": no fights") end
            else
                local shuffled = Shift(Permute(log.fights, seed))
                local score = ScoreSession(log.class, shuffled, SameBases(log.bases, #shuffled), {})
                if not classes[log.class] then
                    classes[log.class] = NewScore(ClassLabel(log.class, log.holdout))
                    if seed == 1 then order[#order + 1] = log.class end
                end
                holdout[log.class] = log.holdout
                Add(classes[log.class], score)
            end
        end
        for _, class in ipairs(order) do
            if not holdout[class] then Add(total, classes[class]) end
        end
        classes.TOTAL = total
        perSeed[seed] = classes
    end

    local record = { k = K, classes = {}, order = order }
    local function Block(name)
        local pooled, rights, wrongs = NewScore(perSeed[1][name].label), {}, {}
        for seed = 1, K do
            local score = perSeed[seed][name]
            rights[seed], wrongs[seed] = Pct(score.right, score.meter), Pct(score.wrong, score.meter)
            pooled.right, pooled.wrong, pooled.unknown = pooled.right + score.right / K, pooled.wrong + score.wrong / K,
                pooled.unknown + score.unknown / K
            pooled.fights, pooled.meter = score.fights, score.meter
        end
        local right, maxWrong = Spread(rights), math.max(table.unpack(wrongs))
        Line(pooled, string.format("  min %5.1f mean %5.1f max %5.1f maxWrong %5.1f", right.min, right.mean, right.max, maxWrong))
        local summary = Summary(pooled)
        summary.min, summary.mean, summary.max, summary.maxWrong, summary.perSeed = right.min, right.mean, right.max, maxWrong, rights
        return summary
    end
    for _, class in ipairs(order) do record.classes[class] = Block(class) end
    record.total = Block("TOTAL")
    results.shuffle = record
end

-- chain -----------------------------------------------------------------------------------------------------
local function RunChain()
    local record, total = { classes = {}, order = classOrder }, NewTotal()
    for _, class in ipairs(classOrder) do
        local slices, bases = Chain(byClass[class])
        local score = ScoreSession(class, Shift(slices), bases, { label = ClassLabel(class, byClass[class][1].holdout) })
        local curve, text = {}, {}
        for index, fight in ipairs(score.curve) do
            curve[index] = Pct(fight.right, fight.meter)
            text[index] = string.format("%.1f", curve[index])
        end
        Line(score)
        Out(string.format("  curve %s: %s", class, table.concat(text, " ")))
        record.classes[class] = Summary(score)
        record.classes[class].curve = curve
        if not byClass[class][1].holdout then Add(total, score) end
    end
    Line(total)
    record.total = Summary(total)
    results.chain = record
end

-- loo -------------------------------------------------------------------------------------------------------
-- Each log of a class held out in turn: the class's other logs chained from an empty store, then the held-out log's
-- fights; one Shift keeps the clock forward and one session carries the store. Only the held-out fights are scored.
local function ScoreHeld(class, logs, held)
    local others = {}
    for _, log in ipairs(logs) do
        if log ~= held then others[#others + 1] = log end
    end
    local slices, bases = Chain(others)
    local first = #slices + 1
    local heldSlices, heldBases = Chain({ held })
    for index, slice in ipairs(heldSlices) do
        local at = first + index - 1
        slices[at], bases[at] = slice, heldBases[index]
    end
    return ScoreSession(class, Shift(slices), bases, { first = first })
end

local function RunLoo()
    local record, total = { classes = {}, order = classOrder }, NewTotal()
    for _, class in ipairs(classOrder) do
        local logs = byClass[class]
        local label = ClassLabel(class, logs[1].holdout)
        if #logs < 2 then
            Out("  " .. label .. ": n/a")
            record.classes[class] = { na = true }
        else
            local pooled = NewScore(label)
            for _, held in ipairs(logs) do
                if #held.fights == 0 then
                    Out("skip " .. held.log .. ": no fights")
                else
                    Add(pooled, ScoreHeld(class, logs, held))
                end
            end
            Line(pooled)
            record.classes[class] = Summary(pooled)
            if not logs[1].holdout then Add(total, pooled) end
        end
    end
    Line(total)
    record.total = Summary(total)
    results.loo = record
end

-- flake ------------------------------------------------------------------------------------------------------
-- Two child runs of base, their per-run lines compared by label: a replay that depends on anything but the logs differs.
local function RunFlake()
    local function Child()
        local pipe = io.popen("lua tests/bench.lua --only base 2>&1")
        local text = pipe and pipe:read("a")
        if pipe then pipe:close() end
        if not text or not text:find("BENCH done", 1, true) then
            Out("flake: subprocess failed")
            os.exit(1)
        end
        return ParseRuns(text)
    end
    local labels, first = Child()
    local more, second = Child()
    for _, label in ipairs(more) do
        if first[label] == nil then labels[#labels + 1] = label end
    end
    local flakes = {}
    for _, label in ipairs(labels) do
        if first[label] ~= second[label] then
            flakes[#flakes + 1] = label
            Out("flake: " .. label)
        end
    end
    if #flakes == 0 then Out("flakes: 0") end
    results.flakes = flakes
end

local SCENARIOS = { { id = "base", run = RunBase }, { id = "shuffle", run = RunShuffle }, { id = "chain", run = RunChain },
    { id = "loo", run = RunLoo }, { id = "flake", run = RunFlake } }
if ONLY then
    local known = {}
    for _, scenario in ipairs(SCENARIOS) do known[scenario.id] = true end
    for id in pairs(ONLY) do assert(known[id], "unknown scenario " .. id) end
end
for _, scenario in ipairs(SCENARIOS) do
    if not ONLY or ONLY[scenario.id] then
        Out("")
        Out("== " .. scenario.id .. (scenario.id == "shuffle" and " (K = " .. K .. ")" or "") .. " ==")
        scenario.run()
    end
end

-- The JSON record: per scenario and class the pooled right/wrong/unknown with its spread over samples (a one-sample
-- scenario's spread is its own numbers), base's runs, the flakes, the wall seconds.
local function Entry(summary)
    if summary.na then return { na = true } end
    return { right = summary.right, wrong = summary.wrong, unknown = summary.unknown, fights = summary.fights,
        min = summary.min or summary.right, mean = summary.mean or summary.right, max = summary.max or summary.right,
        maxWrong = summary.maxWrong or summary.wrong, curve = summary.curve }
end
local function Export()
    local out = {}
    for _, id in ipairs({ "base", "shuffle", "chain", "loo" }) do
        local record = results[id]
        if record then
            out[id] = { TOTAL = Entry(record.total) }
            for class, summary in pairs(record.classes) do out[id][class] = Entry(summary) end
        end
    end
    if results.base then
        out.runs = {}
        for _, run in ipairs(results.base.runs) do
            out.runs[run.label] = { right = run.right, wrong = run.wrong, unknown = run.unknown }
        end
    end
    out.flakes = results.flakes
    out.seconds = os.time() - wallStart
    return out
end
if JSON then
    local file = assert(io.open(JSON, "w"))
    file:write(Encode(Export()), "\n")
    file:close()
end
Out("")
Out(string.format("BENCH done in %d s", os.time() - wallStart)) -- wall time: os.clock is CPU and misses the flake children
