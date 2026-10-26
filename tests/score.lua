-- Scoreboard: replays every saved in-game log and scores what the addon drew against the log's meter rows.
--
--   lua tests/score.lua           per run, per class and total: right %, wrong %, '?' % of own meter damage
--   lua tests/score.lua --rows    also the rows that lose the most damage ('?' + wrong), per class
--
-- Truth is the damage meter, per fight and spell row (M = its total); T is what the replay drew under that row's
-- icon (Teacher.Drawn amounts, paired to rows by ID or by the replay's own alias). Per row:
--   right = min(T, M)   '?' = M - right   wrong = T beyond M * 1.05; a drawn ID with no row is wrong in full.
-- Each is a share of the summed M. right + '?' = 100 %; wrong is extra. Blind spot: two equal-sized spells that
-- swap icons still score right. Hidden hits (crowded) draw nothing, so they count as '?'.
--
-- Each log replays from an empty store, and also from tests/score/<log>.start.lua when one exists: the char save
-- written at the end of the class's previous log (the store as that log began, unless /cti forget ran between).
-- The druid is the hold-out class: scored, never in TOTAL, never tuned on.

local OPTIONS = {}
for _, value in ipairs(arg) do OPTIONS[value] = true end
local DIR = "tests/score/"
local SLACK = 1.05

-- Loads tests/run.lua up to its scoring section: the stubbed WoW API, the parsers and ReplayFights.
local source = assert(io.open("tests/run.lua")):read("a")
local cut = assert(source:find("%-%- Scoring %-%-%-"), "tests/run.lua has no Scoring section")
local H = assert(load(source:sub(1, cut - 1) .. "\nreturn { ReplayFights = ReplayFights, FIGHT_FIXTURES = FIGHT_FIXTURES }\n",
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

local scores, classes, order = {}, {}, {}
local function Record(class, holdout, score)
    scores[#scores + 1] = score
    if not classes[class] then
        classes[class] = NewScore(class .. (holdout and " (hold-out)" or ""))
        classes[class].holdout = holdout
        order[#order + 1] = class
    end
    Add(classes[class], score)
end

-- One replay: ReplayFights boots once per fight, so runs[i] pairs with tallies[i]. The tail after the last
-- read has no rows and is not scored.
local function Run(label, name, opts, class, holdout, bases)
    local score, tallies = NewScore(label), {}
    opts.setup = Setup(class, bases, tallies)
    for index, run in ipairs(H.ReplayFights(name, opts)) do
        if run.rows and #run.rows > 0 then ScoreFight(run.rows, tallies[index], run.last, score) end
    end
    Record(class, holdout, score)
end

for _, spec in ipairs(RUNS) do
    local lines = ReadLines(DIR .. spec.log .. ".txt")
    local bases = BaseSpells(lines)
    local fixture = { startArea = "crowded" }
    Run(spec.log .. " fresh", "x", { log = lines, fixture = fixture }, spec.class, spec.holdout, bases)
    local start = LoadCharDB(DIR .. spec.log .. ".start.lua")
    if start then
        Run(spec.log .. " start", "x", { log = lines, fixture = fixture, charDB = start }, spec.class, spec.holdout, bases)
    end
end
for _, name in ipairs(PRIEST) do
    Run(name:gsub("%-2026.*", "") .. " fresh", name, {}, "priest", false, {})
end

-- --game: the same score for what the addon drew in game, from the log's own TEACH lines (the code of that day).
local games = {}
if OPTIONS["--game"] then
    for _, spec in ipairs(RUNS) do
        local score, open = NewScore(spec.log .. " in game"), nil
        local function Close()
            if open and #open.rows > 0 then ScoreFight(open.rows, open.tally, { rows = open.aliases }, score) end
            open = nil
        end
        for _, line in ipairs(ReadLines(DIR .. spec.log .. ".txt")) do
            local id, t, m, rowID = line:match("^[%d%.]+ TEACH (%d+) tally=(%d+) meter=(%d+) verdict=%a+ ?r?o?w?=?(%d*)$")
            if line:match("^[%d%.]+ TEACH clean ") then
                Close()
                open = { rows = {}, tally = {}, aliases = {} }
            elseif id and open then
                id, t, m = tonumber(id), tonumber(t), tonumber(m)
                local meterID = rowID ~= "" and tonumber(rowID) or id
                if m > 0 then open.rows[#open.rows + 1] = { spellID = meterID, totalAmount = m } end
                if t > 0 then open.tally[id] = t end
                if meterID ~= id then open.aliases[#open.aliases + 1] = { spellID = id, meterID = meterID } end
            elseif open and not line:match("^[%d%.]+ TEACH ") then
                Close()
            end
        end
        Close()
        games[#games + 1] = score
    end
end

local function Out(text) io.write(text, "\n") end -- the stubbed API replaces print
local function Pct(part, whole) return whole > 0 and 100 * part / whole or 0 end
local function Line(score)
    Out(string.format("  %-26s %3d %10d  right %5.1f%%  wrong %5.1f%%  ? %5.1f%%", score.label, score.fights, score.meter,
        Pct(score.right, score.meter), Pct(score.wrong, score.meter), Pct(score.unknown, score.meter)))
end

Out("run                        fights  meter")
for _, score in ipairs(scores) do Line(score) end
Out("")
local total = NewScore("TOTAL (no hold-out)")
for _, class in ipairs(order) do
    Line(classes[class])
    if not classes[class].holdout then Add(total, classes[class]) end
end
Line(total)
if #games > 0 then
    Out("")
    for _, score in ipairs(games) do Line(score) end
end

if OPTIONS["--rows"] then
    for _, class in ipairs(order) do
        local score, ids = classes[class], {}
        for id in pairs(score.byRow) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b)
            local x, y = score.byRow[a], score.byRow[b]
            return x.unknown + x.wrong > y.unknown + y.wrong
        end)
        Out("")
        Out(score.label .. ": rows by lost damage ('?' + wrong), share of the class's meter")
        for index = 1, math.min(12, #ids) do
            local stat = score.byRow[ids[index]]
            Out(string.format("  %8d  lost %5.1f%%  meter %5.1f%%  right %5.1f%%  ? %5.1f%%  wrong %5.1f%%", ids[index],
                Pct(stat.unknown + stat.wrong, score.meter), Pct(stat.meter, score.meter), Pct(stat.right, score.meter),
                Pct(stat.unknown, score.meter), Pct(stat.wrong, score.meter)))
        end
    end
end
