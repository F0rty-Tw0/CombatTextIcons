-- Heal scoreboard: replays every saved in-game log that holds HEAL lines, from an empty store, and scores what the
-- addon drew over the player for each logged heal on the player or a party member. Round 0 of the heal teacher: it
-- measures, it never tunes.
--
--   lua tests/heals.lua          per log, tuned and hold-out totals: coverage, wrong, control
--   lua tests/heals.lua --rows   also each log's heal IDs: the meter's heal rows and every ID a heal was drawn under
--
-- Coverage, a share of the log's raw heal amount (a HEAL line's amount includes overheal):
--   named   drawn with a spell's icon        ?    drawn with the question mark (or as '?' with '?' icons off)
--   hidden  replayed, drawn nothing          out  in a heal-only read: SplitFights makes no slice of it, never replayed
-- named + ? + hidden + out = 100 %.
--   wrong    named under an ID no player cast ties to (Ties) in that ID's life before the heal (or 0.01 s after: a
--            cast on the same stamp later in the line order), or under an ID that is no "TEACH heal" row anywhere in
--            that log (strict orphan); a share of the raw amount, inside named
--   control  named on a party unit in a log whose player heals nobody but itself (not `healer`): an ally's heal, so
--            anything here is wrong; a share of the raw amount, must stay 0
-- The meter's heal rows are EFFECTIVE healing on every target, the HEAL lines RAW healing on player and party: the two
-- sums never compare, so the rows serve only as the list of the player's own heal IDs. Blind spot: the log never says
-- which heal of a frame a cast made, so a named heal on its cast's stamp scores right even when it was a proc's.
--
-- shamanheal is the 2026-10-28 resto capture (tests/score/shaman4.txt is an older, different run). shamanresto and
-- priest3 are the hold-out logs: scored, never tuned on.

local L = dofile("tests/score_lib.lua")
local Pct, Out, ReadLines = L.Pct, L.Out, L.ReadLines

local WINDOW = 30 -- s a cast can still heal when TRUTH lists no life; Earth Shield (974) lasts longer

-- What ties a drawn heal ID to the player's casts, past its own CAST lines (Ties), and for how long. Test-only, as
-- tests/score_truth.lua; editing it changes the measure. life: seconds a cast can still heal under the ID (WINDOW
-- when not listed); casts: cast IDs that heal under it although no CAST line names it.
local TRUTH = {
    -- Chain Heal, Healing Wave: direct, no HoT, so the heal lands on its cast's stamp: in shamanheal each of the 17
    -- Chain Heal and 4 Healing Wave stamps holds a HEAL of 40872 or more. A cast 0.01 s away at most, no WINDOW: a
    -- Chain Heal icon on a heal 5 s after the cast is wrong.
    [1064] = { life = 0.01 },
    [77472] = { life = 0.01 },
    -- Healing Rain: the meter's row is 73921 while its CAST lines read `444995 base=73920,73920` (shamanheal line 12)
    [73921] = { casts = { 444995, 73920 } },
    -- The trains, a cast's life a little past its last tick on the player in shamanheal: Healing Stream Totem's
    -- 1267068 at 279467.759 ticks every ~1.5 s, 12 ticks to +18.08 s; Healing Tide Totem's at 279666.642 every
    -- ~1.7 s to +10.04 s; Riptide's HoT at 279632.060 every ~2.6 s to +18.06 s.
    [5394] = { life = 20 },
    [108280] = { life = 12 },
    [61295] = { life = 20 },
}

local LOGS = { -- log: tests/score/<log>.txt; fixture: tests/fixtures/<fixture>.sv.lua, replayed as tests/score.lua does
    { log = "shamanheal", class = "shaman", healer = true },
    { log = "lock3", class = "warlock" },
    { log = "shaman5", class = "shaman" },
    { log = "druid2", class = "druid" },
    { log = "paladin", class = "paladin" },
    { log = "hunter", class = "hunter" },
    { log = "dk", class = "deathknight" },
    { log = "mage", class = "mage" },
    { log = "warrior", class = "warrior" },
    { log = "lock", class = "warlock" },
    { log = "lock2", class = "warlock" },
    { log = "shaman3", class = "shaman" },
    { log = "shaman4", class = "shaman" },
    { log = "druid", class = "druid" },
    { log = "shadow-dots", fixture = "shadow-dots-2026-10-24", class = "priest" },
    { log = "priest-dummy", fixture = "priest-dummy-2026-10-24", class = "priest" },
    { log = "shadow-forget5", fixture = "shadow-forget5-2026-10-25", class = "priest" },
    { log = "shadow-steady", fixture = "shadow-steady-2026-10-25", class = "priest" },
    { log = "shadow-steady2", fixture = "shadow-steady2-2026-10-25", class = "priest" },
    { log = "shamanresto", class = "shaman", healer = true, holdout = true },
    { log = "priest3", class = "priest", holdout = true },
}

-- The logs' heal casts, which the game answers as not harmful (C_Spell.IsSpellHarmful), so Core takes them as your
-- helpful casts. tests/score_lib.lua's HELPFUL leaves them harmful: the damage boards keep their measure.
local HEAL_CASTS = {
    shaman = { 1064, 77472, 5394, 108280, 974 }, -- Chain Heal, Healing Wave, the two healing totems, Earth Shield
    priest = { 2061, 19236, 17 },                -- Flash Heal, Desperate Prayer, Power Word: Shield
    paladin = { 85673 },                         -- Word of Glory
    hunter = { 109304 },                         -- Exhilaration
}

local OPTIONS = {}
for _, value in ipairs(arg) do OPTIONS[value] = true end

local function NewHeals(label)
    return { label = label, heals = 0, raw = 0, named = 0, unknown = 0, hidden = 0, out = 0, wrong = 0, control = 0,
        byID = {} }
end

-- The heal IDs one "CAST player <castID> base=<a>,<b>" line ties: its own ID, its base IDs (Healing Wave's lines read
-- `77472 base=8004,8004`: an icon of either is that cast's), and each TRUTH row that lists castID.
local function Ties(castID, bases)
    local ids = { castID }
    for base in (bases or ""):gmatch("%d+") do ids[#ids + 1] = tonumber(base) end
    for id, truth in pairs(TRUTH) do
        for _, listed in ipairs(truth.casts or {}) do
            if listed == castID then ids[#ids + 1] = id end
        end
    end
    return ids
end

local function AddTime(times, id, t)
    times[id] = times[id] or {}
    table.insert(times[id], t)
end

-- What the log itself says: casts[id] = the times of its "CAST player <id>" lines, ties[id] = the times of the casts
-- that tie a heal drawn under id (Ties), meter[id] = its "TEACH heal <id>" rows summed over the reads, raw = the
-- summed amount of its HEAL lines on the player or a party unit.
local function LogFacts(lines)
    local facts = { casts = {}, ties = {}, meter = {}, raw = 0, heals = 0 }
    for _, line in ipairs(lines) do
        local t, castID = line:match("^([%d%.]+) CAST player (%d+)")
        local healID, meter = line:match("^[%d%.]+ TEACH heal (%d+) meter=(%d+) ")
        local unit, amount = line:match("^[%d%.]+ HEAL (%S+) school=%d+ amount=(%d+) ")
        if castID then
            castID, t = tonumber(castID), tonumber(t)
            AddTime(facts.casts, castID, t)
            for _, id in ipairs(Ties(castID, line:match(" base=(%S+)"))) do AddTime(facts.ties, id, t) end
        elseif healID then
            healID = tonumber(healID)
            facts.meter[healID] = (facts.meter[healID] or 0) + tonumber(meter)
        elseif unit and (unit == "player" or unit:find("^party[1-4]$")) then
            facts.raw, facts.heals = facts.raw + tonumber(amount), facts.heals + 1
        end
    end
    return facts
end

-- The spell ID a drawn heal's icon names (the stub's texture is "tex:<id>"), nil for '?' or nothing drawn.
local function NamedID(shown)
    return shown and type(shown.texture) == "string" and tonumber(shown.texture:match("^tex:(%d+)$")) or nil
end

-- Whether a cast tied to `id` happened in id's life before `t`, or up to 0.01 s after it.
local function CastWithin(times, id, t)
    local life = TRUTH[id] and TRUTH[id].life or WINDOW
    for _, castAt in ipairs(times or {}) do
        if castAt >= t - life and castAt <= t + 0.01 then return true end
    end
    return false
end

-- Scores the replayed heals (Replay's info.heals entries) of one log into `into`; `out` gets the log's heal amount
-- the replay never saw. byID[id] = { named, wrong, control } per drawn ID.
local function ScoreHeals(heals, facts, healer, into)
    local replayed = 0
    for _, heal in ipairs(heals) do
        local unit, amount = heal.event.unit, heal.event.amount
        if unit == "player" or unit:find("^party[1-4]$") then
            replayed = replayed + amount
            local id = NamedID(heal.shown)
            if id then
                local stat = into.byID[id] or { named = 0, wrong = 0, control = 0 }
                into.byID[id] = stat
                into.named, stat.named = into.named + amount, stat.named + amount
                if not facts.meter[id] or not CastWithin(facts.ties[id], id, heal.event.t) then
                    into.wrong, stat.wrong = into.wrong + amount, stat.wrong + amount
                end
                if not healer and unit ~= "player" then
                    into.control, stat.control = into.control + amount, stat.control + amount
                end
            elseif heal.shown then
                into.unknown = into.unknown + amount
            else
                into.hidden = into.hidden + amount
            end
        end
    end
    into.heals, into.raw = into.heals + facts.heals, into.raw + facts.raw
    into.out = into.out + facts.raw - replayed
end

local function AddHeals(into, score)
    for _, key in ipairs({ "heals", "raw", "named", "unknown", "hidden", "out", "wrong", "control" }) do
        into[key] = into[key] + score[key]
    end
end

do -- self-check: casts of 10 at 100; rows 10; heals of 100 each on the player unless said
    local facts = { ties = { [10] = { 100 } }, meter = { [10] = 1 }, raw = 800, heals = 8 }
    local function Heal(t, texture, unit) return { event = { t = t, unit = unit or "player", amount = 100 },
        shown = texture ~= false and { texture = texture } or nil } end
    local heals = { Heal(101, "tex:10"), Heal(100 + WINDOW + 0.02, "tex:10"), Heal(101, "tex:20"), Heal(101, 134400),
        Heal(101, nil), Heal(101, false), Heal(101, "tex:10", "party1"), Heal(99.995, "tex:10") }
    local check = NewHeals("check")
    ScoreHeals(heals, facts, false, check)
    assert(check.named == 500 and check.unknown == 200 and check.hidden == 100 and check.out == 0,
        "heals self-check: a tex:<id> draw is named, the '?' icon and a nil texture are '?', no draw is hidden")
    assert(check.wrong == 200 and check.byID[10].wrong == 100 and check.byID[20].wrong == 100,
        "heals self-check: a cast WINDOW + 0.02 s before is wrong (0.005 s after is not), an ID with no row is wrong")
    assert(check.control == 100 and check.byID[10].control == 100, "heals self-check: a named party heal is control")
    local healer = NewHeals("healer")
    ScoreHeals({ Heal(101, "tex:10", "party1") }, { ties = facts.ties, meter = facts.meter, raw = 300, heals = 3 },
        true, healer)
    assert(healer.control == 0 and healer.wrong == 0 and healer.out == 200,
        "heals self-check: a healer's party heal is no control; heals the replay never saw are out")
    local tied = LogFacts({ "100.000 CAST player 77472 base=8004,8004", "200.000 CAST player 444995 base=73920,73920",
        "300.000 CAST player 1064 base=1064,1064", "1.0 TEACH heal 8004 meter=1 over=0",
        "1.0 TEACH heal 73921 meter=1 over=0", "1.0 TEACH heal 1064 meter=1 over=0" })
    local truth = NewHeals("truth")
    ScoreHeals({ Heal(100, "tex:8004"), Heal(201, "tex:73921"), Heal(300.005, "tex:1064"), Heal(301, "tex:1064") },
        tied, false, truth)
    assert(truth.named == 400 and truth.wrong == 100 and truth.byID[1064].wrong == 100,
        "heals self-check: a cast ties its base= IDs and TRUTH's rows; a direct heal's cast 1 s before is wrong")
end

-- The fixture logs' debug lines, as tests/score_lib.lua's ReadLines keeps them.
local function FixtureLines(fixture)
    local env = {}
    assert(loadfile("tests/fixtures/" .. fixture .. ".sv.lua", "t", env))()
    local lines = {}
    for _, line in ipairs(env.CombatTextIconsDB.debugLog) do
        if line:match("^[%d%.]+ ") then lines[#lines + 1] = line end
    end
    return lines
end

local function Replayed(spec)
    local lines = spec.fixture and FixtureLines(spec.fixture) or ReadLines(L.DIR .. spec.log .. ".txt")
    -- the game's base spells as the log's CAST lines answered them: Healing Stream Totem casts as `1267068 base=5394`
    local classSetup = L.Setup(spec.class, L.BaseSpells(lines), {}, {})
    local function setup(ns, S)
        classSetup(ns, S)
        for _, id in ipairs(HEAL_CASTS[spec.class] or {}) do S.harmful[id], S.helpful[id] = false, true end
    end
    local opts = spec.fixture and { setup = setup }
        or { log = lines, fixture = { startArea = "crowded", replayThreat = true }, setup = setup }
    local heals = {}
    for _, run in ipairs(L.H.ReplayFights(spec.fixture or "x", opts)) do
        table.move(run.info.heals, 1, #run.info.heals, #heals + 1, heals)
    end
    local facts, score = LogFacts(lines), NewHeals(spec.log .. (spec.holdout and " (hold-out)" or ""))
    ScoreHeals(heals, facts, spec.healer, score)
    return score, facts
end

local function Line(score)
    Out(string.format("  %-26s %5d %10d  named %5.1f%%  ? %5.1f%%  hidden %5.1f%%  out %5.1f%%  wrong %5.2f%%"
        .. "  control %5.2f%%", score.label, score.heals, score.raw, Pct(score.named, score.raw),
        Pct(score.unknown, score.raw), Pct(score.hidden, score.raw), Pct(score.out, score.raw),
        Pct(score.wrong, score.raw), Pct(score.control, score.raw)))
end

local tuned, holdout, results = NewHeals("TUNED"), NewHeals("HOLD-OUT"), {}
for _, spec in ipairs(LOGS) do
    local score, facts = Replayed(spec)
    if facts.heals > 0 then
        results[#results + 1] = { score = score, facts = facts }
        AddHeals(spec.holdout and holdout or tuned, score)
    end
end

Out("log                        heals        raw")
for _, result in ipairs(results) do Line(result.score) end
Out("")
Line(tuned)
Line(holdout)

if OPTIONS["--rows"] then
    for _, result in ipairs(results) do
        local score, facts, ids, seen = result.score, result.facts, {}, {}
        for id in pairs(facts.meter) do ids[#ids + 1], seen[id] = id, true end
        for id in pairs(score.byID) do
            if not seen[id] then ids[#ids + 1] = id end
        end
        table.sort(ids, function(a, b) return (facts.meter[a] or 0) > (facts.meter[b] or 0) or
            ((facts.meter[a] or 0) == (facts.meter[b] or 0) and a < b) end)
        if #ids > 0 then
            Out("")
            Out(score.label .. ": heal IDs (meter: summed TEACH heal rows, effective; the rest: share of raw)")
            for _, id in ipairs(ids) do
                local stat = score.byID[id] or { named = 0, wrong = 0, control = 0 }
                Out(string.format("  %8d  meter %10d  casts %4d  named %5.1f%%  wrong %5.2f%%  control %5.2f%%", id,
                    facts.meter[id] or 0, #(facts.casts[id] or {}), Pct(stat.named, score.raw),
                    Pct(stat.wrong, score.raw), Pct(stat.control, score.raw)))
            end
        end
    end
end
