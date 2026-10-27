-- Scoreboard: replays every saved in-game log and scores what the addon drew against the log's meter rows.
--
--   lua tests/score.lua           per run, per class and total: right %, wrong %, '?' % of own meter damage
--   lua tests/score.lua --rows    also the rows that lose the most damage ('?' + wrong), per class
--
-- Truth is the damage meter, per fight and spell row (M = its total); T is what the replay drew under that row's
-- icon (Teacher.Drawn amounts, paired to rows by ID or by the replay's own alias). Per row:
--   o = the drawn amount no cast of the row could explain (strict, below)   T' = T - o
--   right = min(T', M)   '?' = M - right   wrong = o + T' beyond M * 1.05; a drawn ID with no row is wrong in full.
-- Each is a share of the summed M. right + '?' = 100 %; wrong is extra; `strict` is the summed o over M (inside wrong).
-- Strict: a hit drawn under a row in tests/score_truth.lua with no cast of that row within its life before it (and at
-- least one player cast in the fight) is an orphan. Rows not in the table are never checked. Blind spot: two spells
-- that swap icons inside each other's cast window still score right. Hidden hits (crowded) draw nothing: '?'.
--
-- Each log replays from an empty store, and also from tests/score/<log>.start.lua when one exists: the char save
-- written at the end of the class's previous log (the store as that log began, unless /cti forget ran between).
-- The druid is the hold-out class: scored, never in TOTAL, never tuned on.

local OPTIONS = {}
for _, value in ipairs(arg) do OPTIONS[value] = true end
local L = dofile("tests/score_lib.lua")
local RUNS, DIR, ReadLines = L.RUNS, L.DIR, L.ReadLines
local ScoreFight, NewScore, Pct, Line, Out = L.ScoreFight, L.NewScore, L.Pct, L.Line, L.Out

local board = L.Collect(L.LoadLogs(), L.Run)

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

Out("run                        fights  meter")
for _, run in ipairs(board.runs) do Line(run.score) end
Out("")
for _, class in ipairs(board.order) do Line(board.classes[class]) end
Line(board.total)
if #games > 0 then
    Out("")
    for _, score in ipairs(games) do Line(score) end
end

if OPTIONS["--rows"] then
    for _, class in ipairs(board.order) do
        local score, ids = board.classes[class], {}
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
