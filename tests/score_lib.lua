-- Scoreboard library: the replay, scoring and printing code shared by tests/score.lua and the tests that replay the
-- saved in-game logs in other orders. Returns the table L of its parts.

local DIR = "tests/score/"
local SLACK = 1.05

-- Loads tests/run.lua up to its scoring section: the stubbed WoW API, the parsers, SplitFights, ReplaySlices and ReplayFights.
local source = assert(io.open("tests/run.lua")):read("a")
local cut = assert(source:find("%-%- Scoring %-%-%-"), "tests/run.lua has no Scoring section")
local H = assert(load(source:sub(1, cut - 1) .. "\nreturn { ReplayFights = ReplayFights, SplitFights = SplitFights, ReplaySlices = ReplaySlices }\n",
    "=run.lua"))()

-- C_Spell.IsSpellHarmful answers per class: the casts that are buffs, forms or utility (the log does not record it).
local HELPFUL = {
    shaman = { 1298679, 179950, 378081, 61295, 2645, 442726, 416250, 111400 },
    druid = { 768, 5487, 783, 8690, 5217, 252216, 77764 }, -- forms, Hearthstone, Tiger's Fury, Tiger Dash, Stampeding Roar
}
local NOT_HARMFUL = { shaman = { 444995 } } -- neither harmful nor helpful

local RUNS = {
    { class = "warlock", log = "lock" },
    { class = "warlock", log = "lock2" },
    { class = "shaman", log = "shaman2" },
    { class = "shaman", log = "shaman3" },
    { class = "shaman", log = "shaman4" },
    { class = "druid", log = "druid", holdout = true },
}
local PRIEST = { "shadow-dots-2026-10-24", "priest-dummy-2026-10-24", "shadow-forget5-2026-10-25",
    "shadow-steady-2026-10-25", "shadow-steady2-2026-10-25" }

local function ReadLines(file)
    local lines = {}
    for line in io.lines(file) do
        if line:match("^[%d%.]+ ") then lines[#lines + 1] = line end
    end
    return lines
end

local function LoadCharDB(file)
    local handle = io.open(file)
    if not handle then return nil end
    handle:close()
    local env = {}
    assert(loadfile(file, "t", env))()
    return env.CombatTextIconsCharDB
end

-- The base spell of each override cast, as the game answered it in the log's CAST lines.
local function BaseSpells(lines)
    local bases = {}
    for _, line in ipairs(lines) do
        local id, base = line:match(" CAST player (%d+) base=(%d+)")
        if id and id ~= base then bases[tonumber(id)] = tonumber(base) end
    end
    return bases
end

-- The replay's setup hook, run at each fight's boot: class stubs, and a new tally of the fight's draws in `tallies`.
local function Setup(class, bases, tallies)
    return function(ns, S)
        for id, base in pairs(bases) do S.baseSpells[id] = base end
        for _, id in ipairs(HELPFUL[class] or {}) do S.harmful[id], S.helpful[id] = false, true end
        for _, id in ipairs(NOT_HARMFUL[class] or {}) do S.harmful[id] = false end
        local tally = {}
        tallies[#tallies + 1] = tally
        local drawn = ns.Teacher.Drawn
        ns.Teacher.Drawn = function(spellID, amount)
            if type(spellID) == "number" and type(amount) == "number" then
                tally[spellID] = (tally[spellID] or 0) + amount
            end
            return drawn(spellID, amount)
        end
    end
end

-- Scores one fight into `into` (and its per-row table). rows: the log's meter rows; tally: drawn amount per ID;
-- last: the replay's Teacher read, whose rows name the aliases it paired (drawn ID -> meter row ID).
local function ScoreFight(rows, tally, last, into)
    local meter, toRow = {}, {}
    for _, row in ipairs(rows) do meter[row.spellID] = (meter[row.spellID] or 0) + row.totalAmount end
    for _, entry in ipairs(last and last.rows or {}) do
        if entry.meterID ~= entry.spellID and meter[entry.meterID] then toRow[entry.spellID] = entry.meterID end
    end
    local drawn = {}
    for id, amount in pairs(tally) do
        local rowID = meter[id] and id or toRow[id]
        if rowID then
            drawn[rowID] = (drawn[rowID] or 0) + amount
        else
            into.wrong = into.wrong + amount
            local stat = into.byRow[id] or { meter = 0, right = 0, unknown = 0, wrong = 0 }
            stat.wrong = stat.wrong + amount
            into.byRow[id] = stat
        end
    end
    for id, m in pairs(meter) do
        local t = drawn[id] or 0
        local right, wrong = math.min(t, m), math.max(0, t - m * SLACK)
        into.meter, into.right, into.unknown, into.wrong = into.meter + m, into.right + right, into.unknown + m - right,
            into.wrong + wrong
        local stat = into.byRow[id] or { meter = 0, right = 0, unknown = 0, wrong = 0 }
        stat.meter, stat.right, stat.unknown, stat.wrong = stat.meter + m, stat.right + right, stat.unknown + m - right,
            stat.wrong + wrong
        into.byRow[id] = stat
    end
    into.fights = into.fights + 1
end

local function NewScore(label) return { label = label, fights = 0, meter = 0, right = 0, unknown = 0, wrong = 0, byRow = {} } end

do -- self-check: A over by 20 (15 beyond slack), C drawn with no row, D an alias of B
    local check = NewScore("check")
    ScoreFight({ { spellID = 1, totalAmount = 100 }, { spellID = 2, totalAmount = 50 } }, { [1] = 120, [3] = 10, [4] = 40 },
        { rows = { { spellID = 4, meterID = 2 } } }, check)
    assert(check.meter == 150 and check.right == 140 and check.unknown == 10 and check.wrong == 25, "ScoreFight self-check")
end

local function Add(into, score)
    into.fights, into.meter, into.right, into.unknown, into.wrong = into.fights + score.fights,
        into.meter + score.meter, into.right + score.right, into.unknown + score.unknown, into.wrong + score.wrong
    for id, stat in pairs(score.byRow) do
        local to = into.byRow[id] or { meter = 0, right = 0, unknown = 0, wrong = 0 }
        for key, value in pairs(stat) do to[key] = to[key] + value end
        into.byRow[id] = to
    end
end

local function Out(text) io.write(text, "\n") end -- the stubbed API replaces print
local function Pct(part, whole) return whole > 0 and 100 * part / whole or 0 end
-- bench.lua's flake parser reads this format back; a suffix is appended as is.
local function Line(score, suffix)
    Out(string.format("  %-26s %3d %10d  right %5.1f%%  wrong %5.1f%%  ? %5.1f%%", score.label, score.fights, score.meter,
        Pct(score.right, score.meter), Pct(score.wrong, score.meter), Pct(score.unknown, score.meter)) .. (suffix or ""))
end

local function ClassLabel(class, holdout) return class .. (holdout and " (hold-out)" or "") end
local function NewTotal() return NewScore("TOTAL (no hold-out)") end

-- Every log the scoreboard replays, in its order: RUNS (with the class's start save when there is one), then PRIEST.
local function LoadLogs()
    local logs = {}
    for _, spec in ipairs(RUNS) do
        local lines = ReadLines(DIR .. spec.log .. ".txt")
        logs[#logs + 1] = { class = spec.class, log = spec.log, holdout = spec.holdout, bases = BaseSpells(lines), name = "x",
            opts = { log = lines, fixture = { startArea = "crowded" } }, start = LoadCharDB(DIR .. spec.log .. ".start.lua") }
    end
    for _, name in ipairs(PRIEST) do
        logs[#logs + 1] = { class = "priest", log = (name:gsub("%-2026.*", "")), holdout = false, bases = {}, name = name, opts = {} }
    end
    return logs
end

-- One replay: ReplayFights boots once per fight, so runs[i] pairs with tallies[i]. The tail after the last read
-- has no rows and is not scored.
local function Run(log, charDB)
    local score, tallies = NewScore(""), {}
    local opts = { log = log.opts.log, fixture = log.opts.fixture, charDB = charDB, setup = Setup(log.class, log.bases, tallies) }
    for index, run in ipairs(H.ReplayFights(log.name, opts)) do
        if run.rows and #run.rows > 0 then ScoreFight(run.rows, tallies[index], run.last, score) end
    end
    return score
end

-- Every run in the scoreboard's order (each log fresh, then from its start save), summed per class and into TOTAL.
-- Replay(log, charDB) -> score; Run is the scoreboard's own.
local function Collect(logs, Replay)
    local runs, classes, order = {}, {}, {}
    local function Record(log, label, charDB)
        local score = Replay(log, charDB)
        score.label = label
        runs[#runs + 1] = { score = score, class = log.class, holdout = log.holdout }
        if not classes[log.class] then
            classes[log.class] = NewScore(ClassLabel(log.class, log.holdout))
            classes[log.class].holdout = log.holdout
            order[#order + 1] = log.class
        end
        Add(classes[log.class], score)
    end
    for _, log in ipairs(logs) do
        Record(log, log.log .. " fresh")
        if log.start then Record(log, log.log .. " start", log.start) end
    end
    local total = NewTotal()
    for _, class in ipairs(order) do
        if not classes[class].holdout then Add(total, classes[class]) end
    end
    return { runs = runs, classes = classes, order = order, total = total }
end

return { H = H, RUNS = RUNS, DIR = DIR, ReadLines = ReadLines, Setup = Setup, ScoreFight = ScoreFight, NewScore = NewScore,
    NewTotal = NewTotal, ClassLabel = ClassLabel, Add = Add, Pct = Pct, Line = Line, Out = Out, LoadLogs = LoadLogs, Run = Run,
    Collect = Collect }
