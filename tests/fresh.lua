-- Fresh scoreboard: replays the six in-game logs of 2026-10-27 and the death knight's, mage's and warrior's of
-- 2026-10-28 (each class right after /cti forget, the user's run shape: dummies, dungeon, dummies, open world) and
-- scores what the addon drew against each fight's meter rows, the same way as tests/score.lua. Group fights stay in
-- the meter: they are real play and teach nothing by design.
--
--   lua tests/fresh.lua                 per log: right, right from its 4th fight on, wrong; tuned and hold-out totals
--   lua tests/fresh.lua --game          also what the game drew, from each HIT's logged route (the code of that day)
--   lua tests/fresh.lua --rows          also each log's rows that lose the most damage
--   lua tests/fresh.lua --save <file>   writes the numbers as a gate baseline
--   lua tests/fresh.lua --gate <file>   KEEP or REJECT against a saved baseline (exit code 1 on REJECT)
--
-- Druid, paladin, hunter, death knight, mage and warrior are the hold-out classes: scored, never tuned on.

local L = dofile("tests/score_lib.lua")
local ScoreFight, NewScore, Add, Pct, Line, Out = L.ScoreFight, L.NewScore, L.Add, L.Pct, L.Line, L.Out

local FRESH = {
    { log = "lock3", class = "warlock" },
    { log = "shaman5", class = "shaman" },
    { log = "priest3", class = "priest" },
    { log = "druid2", class = "druid", holdout = true },
    { log = "paladin", class = "paladin", holdout = true },
    { log = "hunter", class = "hunter", holdout = true },
    { log = "dk", class = "deathknight", holdout = true },
    { log = "mage", class = "mage", holdout = true },
    { log = "warrior", class = "warrior", holdout = true },
    { log = "shaman6", class = "shaman", holdout = true },
    { log = "shamanresto", class = "shaman", holdout = true },
    { log = "shamanele", class = "shaman", holdout = true }, -- 2026-10-29, elemental spec
    { log = "lock4", class = "warlock", holdout = true },    -- 2026-10-29, affliction, dummies/world/dungeon
    { log = "hunter2", class = "hunter", holdout = true },   -- 2026-10-29, beast mastery, dummies/world/dungeon
    { log = "paladin2", class = "paladin", holdout = true }, -- 2026-10-29, retribution, dummies/world/dungeon
    { log = "priest4", class = "priest", holdout = true },   -- 2026-10-29, shadow, dummies/world/dungeon
}
local STEP = 0.05 -- the smallest move of a percentage that counts
local LATE = 4    -- "late" scores a log's fights from this one on: what a player sees once learning had a chance

local OPTIONS, savePath, gatePath = {}, nil, nil
for index, value in ipairs(arg) do
    OPTIONS[value] = true
    if value == "--save" then savePath = arg[index + 1] end
    if value == "--gate" then gatePath = arg[index + 1] end
end

-- The icons the game drew, per fight: each HIT's route line (tracker, cast, proc, rhythm) names the ID its amount was
-- tallied under (a cast route under the cast's base spell, unless the meter showed a row of the cast's own ID: Casts.Base
-- keeps an ID with its own row). fights[i] = { tally, aliases }, closed at TEACH clean. Run shamanresto: CAST lines log
-- Lava Burst 51505 with base=73899, and its draws were scored wrong under 73899 though 51505 has its own meter row.
local function GameFights(lines)
    local bases, rowIDs = {}, {}
    for _, line in ipairs(lines) do
        local id, base = line:match(" CAST player (%d+) base=(%d+)")
        if id then bases[tonumber(id)] = tonumber(base) end
        local row = line:match(" TEACH row (%d+)")
        if row then rowIDs[tonumber(row)] = true end
    end
    local fights, tally, amount, closed = {}, {}, nil, nil
    for _, text in ipairs(lines) do
        local hit = text:match("^[%d%.]+ HIT %S+ school=%d+ amount=(%d+)")
        local kind, id = text:match("^[%d%.]+   %-> (%a+) (%d+)$")
        local aliasID, meterID = text:match("^[%d%.]+ TEACH (%d+) tally=%d+ meter=%d+ verdict=%a+ row=(%d+)$")
        if hit then
            amount = tonumber(hit)
        elseif kind and amount and (kind == "tracker" or kind == "cast" or kind == "proc" or kind == "rhythm") then
            id = tonumber(id)
            if kind == "cast" and not rowIDs[id] then id = bases[id] or id end
            tally[id] = (tally[id] or 0) + amount
            amount = nil
        elseif text:match("^[%d%.]+ HEAL ") then
            amount = nil
        elseif text:match("^[%d%.]+ TEACH clean ") then
            closed = { tally = tally, aliases = {} }
            fights[#fights + 1] = closed
            tally = {}
        elseif aliasID and closed then
            closed.aliases[#closed.aliases + 1] = { spellID = tonumber(aliasID), meterID = tonumber(meterID) }
        end
    end
    return fights
end

-- The meter rows of each read in file order, as tests/run.lua's ParseTeach reads them.
local function ReadRows(lines)
    local reads, open = {}, nil
    for _, text in ipairs(lines) do
        if text:match("^[%d%.]+ TEACH clean ") then
            open = {}
            reads[#reads + 1] = open
        end
        local id, meter, row = text:match("^[%d%.]+ TEACH (%d+) tally=%d+ meter=(%d+) verdict=%a+ ?r?o?w?=?(%d*)$")
        if id and open and tonumber(meter) > 0 then
            open[#open + 1] = { spellID = tonumber(row ~= "" and row or id), totalAmount = tonumber(meter) }
        end
    end
    return reads
end

-- Scores a list of { rows, tally, last, record } fights into an all-fights and a late score.
local function ScoreLog(label, fights)
    local all, late, scored = NewScore(label), NewScore(label .. " late"), 0
    for _, fight in ipairs(fights) do
        if fight.rows and #fight.rows > 0 then
            scored = scored + 1
            local one = NewScore("")
            ScoreFight(fight.rows, fight.tally, fight.last, one, fight.record)
            Add(all, one)
            if scored >= LATE then Add(late, one) end
        end
    end
    return all, late
end

local function Replayed(spec, lines)
    local tallies, records = {}, {}
    local opts = { log = lines, fixture = { startArea = "unknown", replayThreat = true },
        setup = L.Setup(spec.class, {}, tallies, records) }
    local fights = {}
    for index, run in ipairs(L.H.ReplayFights("x", opts)) do
        fights[index] = { rows = run.rows, tally = tallies[index], last = run.last, record = records[index] }
    end
    return ScoreLog(spec.log, fights)
end

local function InGame(spec, lines)
    local fights, reads = GameFights(lines), ReadRows(lines)
    local scored = {}
    for index, fight in ipairs(fights) do
        scored[index] = { rows = reads[index], tally = fight.tally, last = { rows = fight.aliases } }
    end
    return ScoreLog(spec.log .. " in game", scored)
end

local tuned, holdout = NewScore("TUNED"), NewScore("HOLD-OUT")
local numbers = { wrong = {} }
local results, games = {}, {}
for _, spec in ipairs(FRESH) do
    local lines = L.ReadLines(L.DIR .. spec.log .. ".txt")
    local all, late = Replayed(spec, lines)
    results[#results + 1] = { spec = spec, all = all, late = late }
    Add(spec.holdout and holdout or tuned, all)
    numbers.wrong[spec.log] = Pct(all.wrong, all.meter)
    if OPTIONS["--game"] then games[#games + 1] = { InGame(spec, lines) } end
end
numbers.tunedRight, numbers.holdoutRight = Pct(tuned.right, tuned.meter), Pct(holdout.right, holdout.meter)

local function Late(late) return string.format("  late %5.1f%%", Pct(late.right, late.meter)) end
Out("log                        fights  meter")
for _, result in ipairs(results) do Line(result.all, Late(result.late)) end
Out("")
Line(tuned)
Line(holdout)
if #games > 0 then
    Out("")
    for _, game in ipairs(games) do Line(game[1], Late(game[2])) end
end

if OPTIONS["--rows"] then
    for _, result in ipairs(results) do
        local score, ids = result.all, {}
        for id in pairs(score.byRow) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b)
            local x, y = score.byRow[a], score.byRow[b]
            return x.unknown + x.wrong > y.unknown + y.wrong
        end)
        Out("")
        Out(score.label .. ": rows by lost damage ('?' + wrong), share of the log's meter")
        for index = 1, math.min(10, #ids) do
            local stat = score.byRow[ids[index]]
            Out(string.format("  %8d  lost %5.1f%%  meter %5.1f%%  right %5.1f%%  wrong %5.1f%%  over %5.2f%%", ids[index],
                Pct(stat.unknown + stat.wrong, score.meter), Pct(stat.meter, score.meter), Pct(stat.right, score.meter),
                Pct(stat.wrong, score.meter), Pct(stat.over, score.meter)))
        end
    end
end

-- KEEP when no log's wrong rose and neither right total fell past STEP, and something got better past STEP.
local function Judge(base, now)
    local reasons, improved = {}, false
    local function Check(label, delta, lowerIsBetter)
        if lowerIsBetter then delta = -delta end
        if delta <= -STEP then reasons[#reasons + 1] = string.format("%s %+.2f", label, lowerIsBetter and -delta or delta) end
        improved = improved or delta >= STEP
    end
    Check("tunedRight", now.tunedRight - base.tunedRight, false)
    Check("holdoutRight", now.holdoutRight - base.holdoutRight, false)
    for _, spec in ipairs(FRESH) do
        Check("wrong " .. spec.log, now.wrong[spec.log] - assert(base.wrong[spec.log], "baseline lacks " .. spec.log), true)
    end
    if not improved then reasons[#reasons + 1] = "nothing improved" end
    return #reasons == 0 and "KEEP" or "REJECT", reasons
end

do -- self-check
    local wrong = {}
    for _, spec in ipairs(FRESH) do wrong[spec.log] = 1 end
    local base = { tunedRight = 10, holdoutRight = 10, wrong = wrong }
    local function With(tunedRight, holdoutRight, log, w)
        local copy = {}
        for key, value in pairs(wrong) do copy[key] = value end
        if log then copy[log] = w end
        return { tunedRight = tunedRight, holdoutRight = holdoutRight, wrong = copy }
    end
    assert(Judge(base, With(10, 10)) == "REJECT", "Judge: no change rejects")
    assert(Judge(base, With(10.1, 10)) == "KEEP", "Judge: tuned right up keeps")
    assert(Judge(base, With(10, 10, "hunter", 0.9)) == "KEEP", "Judge: a log's wrong down keeps")
    local verdict, reasons = Judge(base, With(11, 9.9))
    assert(verdict == "REJECT" and reasons[1] == "holdoutRight -0.10", "Judge: a hold-out drop rejects")
    verdict, reasons = Judge(base, With(11, 10, "lock3", 1.1))
    assert(verdict == "REJECT" and reasons[1] == "wrong lock3 +0.10", "Judge: a log's wrong up rejects")
end

if savePath then
    local parts = {}
    for _, spec in ipairs(FRESH) do parts[#parts + 1] = string.format("%s = %.4f", spec.log, numbers.wrong[spec.log]) end
    local file = assert(io.open(savePath, "w"))
    file:write(string.format("return { tunedRight = %.4f, holdoutRight = %.4f, wrong = { %s } }\n", numbers.tunedRight,
        numbers.holdoutRight, table.concat(parts, ", ")))
    file:close()
    Out("saved " .. savePath)
end
if gatePath then
    local verdict, reasons = Judge(dofile(gatePath), numbers)
    Out("")
    Out("GATE " .. verdict .. (#reasons > 0 and (": " .. table.concat(reasons, "; ")) or ""))
    if verdict == "REJECT" then os.exit(1) end
end
