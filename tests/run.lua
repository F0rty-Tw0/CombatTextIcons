-- Offline harness for Combat Text Icons (Lua 5.4, stubbed WoW API).
--
--   lua tests/run.lua           replay the probe fixtures and the shaman .sv.lua logs, run unit checks, print the
--                               report; exit code 1 if an acceptance threshold fails (criteria 9 and 10 gate the
--                               shaman replays; criterion 11 allows no "?" on a hidden-labeled hit in a group
--                               replay, and only notes the count for solo replays, where "?" is expected;
--                               criteria 3 and 7 print as NOTE: measured, no threshold yet)
--   lua tests/run.lua --haste   print each fixture's haste estimate from labels.lua
--   lua tests/run.lua --wrong   also list every wrong, noise-shown or "?" hit
--
-- The addon files listed in CombatTextIcons.toc are loaded as WoW would load
-- them (`ADDON, ns` varargs). Meter, Tracker and Core run for real; Display is
-- replaced by a recorder for the replays and smoke-tested on its own. The replays
-- run the shipped, empty ns.Spells; unit checks opt into tests/fixture_spells.lua.

local ROOT = (arg[0]:match("^(.*)[/\\]tests[/\\][^/\\]*$") or ".")
local FIXTURES = ROOT .. "/tests/fixtures/"
local ADDON = "CombatTextIcons"
local OPTIONS = {}
for _, value in ipairs(arg) do OPTIONS[value] = true end

local labels = dofile(FIXTURES .. "labels.lua")

-- Stubbed WoW API ------------------------------------------------------------------

local S -- stub state, rebuilt by Boot()

-- Secret values for the unit checks: any comparison or arithmetic on them errors.
local secretMeta = {}
local function Refuse() error("secret value used in comparison or arithmetic", 2) end
for _, name in ipairs({ "__lt", "__le", "__add", "__sub", "__mul", "__div", "__mod", "__unm", "__concat", "__len", "__eq" }) do
    secretMeta[name] = Refuse
end
local function Secret(value) return setmetatable({ secretValue = value }, secretMeta) end
local function IsSecret(value) return getmetatable(value) == secretMeta end

-- Any frame-like object: every method is a no-op returning another such object.
-- SetScript handlers are kept so tests can fire them.
local function Generic()
    local object = { scripts = {} }
    return setmetatable(object, {
        __index = function(_, key)
            if key == "SetScript" then
                return function(self, name, handler) self.scripts[name] = handler end
            end
            return function() return Generic() end
        end,
    })
end

local function Plate(unit)
    return { unit = unit, IsForbidden = function() return false end }
end

local function InstallStubs()
    S = {
        now = 0, pending = {}, pendingTag = "", resets = 0, meterAvailable = true, meterError = false,
        plates = {}, target = nil, petTarget = true, group = false, haste = 0, harmful = {},
        cvars = {}, cvarFail = {}, cvarDefaults = {}, prints = {}, guid = "Player-1-00000001", attackable = {},
        interface = 120105, helpful = {}, autoRepeat = {}, spellNames = {}, guids = {}, threat = {},
        sessions = {}, timers = {}, sourceCalls = {}, frames = {},
        baseSpells = { [450983] = 8092 }, -- override cast -> its base spell (Void Blast -> Mind Blast)
    }
    issecretvalue = IsSecret
    bit = { band = function(a, b) return a & b end }
    GetTime = function() return S.now end
    GetFramerate = function() return 60 end
    GetBuildInfo = function() return "12.0.5", "70448", "Oct 21 2026", S.interface end
    -- guids[unit] when set (a plate's mob), else S.guid.
    UnitGUID = function(unit)
        if S.guids[unit] ~= nil then return S.guids[unit] end
        return S.guid
    end
    -- attackable[unit]: nil = enemy, false = friendly, "error" = restricted, or any value to return.
    -- "target" reads the entry of the unit S.target names.
    UnitCanAttack = function(_, unit)
        if unit == "target" then unit = S.target end
        local value = S.attackable[unit]
        if value == nil then return true end
        if value == "error" then error("restricted") end
        return value
    end
    UnitExists = function(unit)
        if unit == "target" then return S.target ~= nil end
        if unit == "pet" then return not S.noPet end
        return true
    end
    -- threat[unit]: nil = the mob fights you (1), false = not on its threat list, "error" = restricted,
    -- or any value to return. Fixtures hold no threat data, so replays treat every mob as yours.
    UnitThreatSituation = function(_, unit)
        local value = S.threat[unit]
        if value == nil then return 1 end
        if value == "error" then error("restricted") end
        if value == false then return nil end
        return value
    end
    IsInGroup = function() return S.group end
    UnitSpellHaste = function() return S.haste end
    UnitIsUnit = function(a, b)
        if b == "pettarget" then
            if S.petTarget == "error" then error("restricted") end
            return S.petTarget
        end
        if b == "target" then return S.target ~= nil and S.target == a end
        return a == b
    end
    C_DamageMeter = {
        IsDamageMeterAvailable = function() return S.meterAvailable, "" end,
        GetCombatSessionSourceFromType = function(_, meterType)
            if S.meterError then error("meter broke") end
            local spells = {}
            for index = 1, S.pending[meterType] or 0 do
                spells[index] = { spellID = "meter:" .. S.pendingTag .. ":" .. meterType .. ":" .. index }
            end
            return { combatSpells = spells, maxAmount = 0, totalAmount = 0 }
        end,
        ResetAllCombatSessions = function() S.pending = {}; S.resets = S.resets + 1 end,
        GetAvailableCombatSessions = function()
            if S.sessionsFail == "error" then error("sessions broke") end
            if S.sessionsFail == "secret" then return Secret("sessions") end
            local list = {}
            for index, session in ipairs(S.sessions) do
                list[index] = { sessionID = session.sessionID, name = session.name, durationSeconds = session.durationSeconds }
            end
            return list
        end,
        GetCombatSessionSourceFromID = function(sessionID, meterType, guid)
            S.sourceCalls[#S.sourceCalls + 1] = { id = sessionID, meterType = meterType, guid = guid }
            if S.sourceFail == "error" then error("source broke") end
            if S.sourceFail == "secret" then return Secret("source") end
            for _, session in ipairs(S.sessions) do
                if session.sessionID == sessionID then
                    return { combatSpells = session.rows, maxAmount = 0, totalAmount = 0 }
                end
            end
        end,
    }
    time = function() return math.floor(S.now or 0) end
    C_Timer = { After = function(delay, fn) S.timers[#S.timers + 1] = { delay = delay, fn = fn } end }
    C_Spell = {
        GetSpellTexture = function(id)
            if IsSecret(id) then return Secret("tex") end
            return "tex:" .. tostring(id), "original"
        end,
        IsSpellHarmful = function(id) return S.harmful[id] ~= false end,
        GetSpellName = function(id) return S.spellNames[id] end,
        IsSpellHelpful = function(id) return S.helpful[id] == true end,
        IsAutoRepeatSpell = function(id) return S.autoRepeat[id] == true end,
    }
    -- An override cast answers its base spell (S.baseSpells), any other ID itself; the deprecated global is unset.
    C_SpellBook = { FindBaseSpellByID = function(id) return S.baseSpells[id] or id end }
    FindBaseSpellByID = nil
    C_NamePlate = {
        GetNamePlateForUnit = function(unit)
            if unit == "target" then unit = S.target end
            if not unit or not unit:find("^nameplate%d+$") then return nil end
            S.plates[unit] = S.plates[unit] or Plate(unit)
            return S.plates[unit]
        end,
    }
    C_CVar = {
        GetCVar = function(name) return S.cvars[name] end,
        SetCVar = function(name, value)
            if S.cvarFail[name] == "error" then error("cvar locked") end
            if S.cvarFail[name] then return end -- the real SetCVar returns nothing on failure
            S.cvars[name] = value
            return true
        end,
        GetCVarDefault = function(name) return S.cvarDefaults[name] end,
    }
    CombatText = { shown = true, SetShown = function(self, shown) self.shown = shown end }
    -- Every frame made is kept in S.frames, so a check can find one by its scripts.
    CreateFrame = function()
        local frame = Generic()
        S.frames[#S.frames + 1] = frame
        return frame
    end
    WorldFrame, UIParent = Generic(), Generic()
    Minimap = Generic()
    Minimap.GetWidth = function() return 140 end -- MinimapButton.Init places the button on every Boot
    GameTooltip = Generic()
    IsShiftKeyDown = function() return S.shift == true end
    IsControlKeyDown = function() return S.ctrl == true end
    GetCursorPosition = function() return Generic() end -- like the frame getters: no plain position
    STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
    AbbreviateNumbers = function(value) return tostring(value) end
    SlashCmdList = {}
    strtrim = function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
    CombatTextIconsDB = nil
    CombatTextIconsCharDB = nil
    print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
        S.prints[#S.prints + 1] = table.concat(parts, " ")
    end
end

local realPrint = print
local function Out(...) realPrint(...) end

local function TocFiles()
    local files = {}
    for line in io.lines(ROOT .. "/" .. ADDON .. ".toc") do
        if line:match("^[^#%s].*%.lua%s*$") then files[#files + 1] = line:match("^(.-)%s*$") end
    end
    return files
end

-- The test-only spell table (the shipped ns.Spells is empty). The replays read it only
-- to know which recorded casts were channels, as the game knows without any table.
local FIXTURE_SPELLS = ROOT .. "/tests/fixture_spells.lua"
local fixtureSpells = dofile(FIXTURE_SPELLS)

-- Fresh stubs and a fresh addon namespace, loaded in .toc order. `setup(S)`,
-- if given, adjusts the stub state before the addon loads. `withSpells` loads a
-- fresh copy of the fixture table into ns.Spells right after Spells.lua, before
-- Learn.lua indexes it and Tracker.lua keeps a reference to it.
local function Boot(setup, withSpells)
    InstallStubs()
    if setup then setup(S) end
    local ns = {}
    for _, file in ipairs(TocFiles()) do
        local chunk = assert(loadfile(ROOT .. "/" .. file))
        chunk(ADDON, ns)
        if withSpells and file == "Spells.lua" then ns.Spells = dofile(FIXTURE_SPELLS) end
    end
    ns.Core.ADDON_LOADED(ADDON)
    ns.Core.PLAYER_LOGIN()
    return ns
end

local UNKNOWN_ICON = Boot().Meter.UNKNOWN_ICON -- the question mark
local ROUTE_UNKNOWN, ROUTE_CROWDED = "  -> unknown-solo", "  -> HIDDEN (crowded)" -- Core's debug route lines

-- Fixtures -------------------------------------------------------------------------

local function ParseFixture(name)
    local events, phase, lineNumber = {}, 0, 0
    for line in io.lines(FIXTURES .. name .. ".log") do
        lineNumber = lineNumber + 1
        if line:match("^MARK") then
            phase = phase + 1
        else
            local t, kind, rest = line:match("^f%d+ ([%d%.]+) (%a) ?(.*)$")
            assert(t, "unparsed fixture line " .. name .. ":" .. lineNumber)
            local event = { line = lineNumber, t = tonumber(t), kind = kind, phase = phase, order = lineNumber }
            if kind == "U" then
                local unit, ev, flag, amount, school = rest:match("^(%S+) (%S+) (%S+) (%S+) (%S+)$")
                event.unit, event.event, event.flag = unit, ev, flag == "_" and "" or flag
                event.amount, event.school = tonumber(amount), tonumber(school)
            elseif kind == "R" or kind == "M" or kind == "O" then
                local meterType, count = rest:match("^(%d+) n=(%-?%d+)")
                event.meterType, event.count = tonumber(meterType), math.max(tonumber(count), 0)
            elseif kind == "C" then
                local unit, id = rest:match("^(%S+) (%d+)$")
                event.unit, event.id = unit, tonumber(id)
            end
            events[#events + 1] = event
        end
    end
    -- The probe read the meter right after each hit: its R line is that hit's read.
    for index, event in ipairs(events) do
        local nextEvent = events[index + 1]
        if event.kind == "U" and nextEvent and nextEvent.kind == "R" and nextEvent.t == event.t then
            event.read = nextEvent
            nextEvent.paired = true
        end
    end
    return events
end

-- Parses a /cti debug log (the lines of CombatTextIconsDB.debugLog) into the events ParseFixture
-- makes. `line` is the 1-based index in the log (= file line - 11 in a SavedVariables file);
-- `order` = line. Only damage reads are replayed: a read's heal and taken counts (priest logs)
-- and HEAL lines with their routes are skipped. STAMP and RESOLVE lines (an older log's gate) and
-- TEACH lines are skipped.
local function ParseLog(name, log)
    local events, lastHit, pendingRead = {}, nil, nil -- lastHit: the HIT a route line belongs to; false after a HEAL
    for index, text in ipairs(log) do
        local t, rest = text:match("^([%d%.]+) (.*)$")
        assert(t, "unparsed log line " .. name .. ":" .. index)
        local event = { line = index, order = index, t = tonumber(t), phase = 0 }
        local route = rest:match("^  %-> (.+)$")
        local unit, id = rest:match("^CAST (%S+) (%d+)$")
        local readOrigin, dmg = rest:match("^READ (%a+) dmg=(%d+) heal=%d+ taken=%d+$")
        local hitUnit, school, amount, flag = rest:match("^HIT (%S+) school=(%d+) amount=(%d+) flag=(%S*) fps=")
        local hitTarget = rest:match("^HIT .*target=(%a+)$")
        local skipped = rest:match("^STAMP %d+$") or rest:match("^RESOLVE ")
        if route then
            assert(lastHit ~= nil, "route line with no HIT " .. name .. ":" .. index)
            if lastHit then lastHit.route = route end          -- report only
        elseif skipped or rest:match("^TEACH ") then
            -- an older log's gate lines and the teacher's verdicts: report only
        elseif rest:match("^HEAL ") then
            lastHit = false
        elseif unit then
            event.kind, event.unit, event.id = "C", unit, tonumber(id)
            events[#events + 1] = event
        elseif readOrigin then
            event.meterType, event.count = 0, tonumber(dmg)
            if readOrigin == "hit" then
                event.kind, pendingRead = "R", event            -- pairs with the NEXT HIT of this frame
            else
                event.kind = "M"                                -- READ event: Replay sends it to the meter-event handler
            end
            events[#events + 1] = event
        elseif hitUnit then
            event.kind, event.unit, event.event, event.flag = "U", hitUnit, "WOUND", flag
            event.amount, event.school = tonumber(amount), tonumber(school)
            event.target = hitTarget and hitTarget == "true"    -- nil when the log has no target= (older logs)
            if pendingRead and pendingRead.t == event.t then
                event.read, pendingRead.paired, pendingRead = pendingRead, true, nil
            end
            lastHit = event
            events[#events + 1] = event
        else
            error("unparsed log line " .. name .. ":" .. index .. ": " .. text)
        end
    end
    return events
end

-- Loads a /cti debug SavedVariables file and returns its debugLog lines.
local function LoadLog(file)
    local env = {}
    assert(loadfile(FIXTURES .. file, "t", env))()
    return env.CombatTextIconsDB.debugLog
end

-- Parses a /cti debug SavedVariables log (`file`, default labels[name].log) with ParseLog.
local function ParseSvLog(name, file)
    return ParseLog(name, LoadLog(file or labels[name].log))
end

-- Splits a debug log at its Teacher reads. A "TEACH clean seen=.. meter=.. -> area" line ends a fight; the
-- "TEACH <id> tally=.. meter=<n> verdict=.." lines after it with n > 0 are its meter rows (file order, a
-- spell may repeat). A row paired under another ID carries ` row=<meter ID>`; a log older than that prints the
-- cast ID, and `rowIDs[fight]["<printed id>:<meter>"]` names the real row. "TEACH proc" lines are skipped.
-- fights[i] = { endLine, seen, meter, area, rows = { { spellID, totalAmount, overkillAmount } } }.
local function ParseTeach(lines, rowIDs)
    local fights, open = {}, nil
    for index, text in ipairs(lines) do
        local seen, meter, area = text:match("^[%d%.]+ TEACH clean seen=(%d+) meter=(%d+) %-> (%a+)$")
        local id, rowMeter, rowID = text:match("^[%d%.]+ TEACH (%d+) tally=%d+ meter=(%d+) verdict=%a+ ?r?o?w?=?(%d*)$")
        if seen then
            open = { endLine = index, seen = tonumber(seen), meter = tonumber(meter), area = area, rows = {} }
            fights[#fights + 1] = open
        elseif text:match("^[%d%.]+ TEACH proc ") then
            -- Procs' streak lines sit between the clean line and the rows: report only
        elseif id and open then
            local amount = tonumber(rowMeter)
            local fixes = rowIDs and rowIDs[#fights] or {}
            local spellID = tonumber(fixes[id .. ":" .. rowMeter] or (rowID ~= "" and rowID) or id)
            if amount > 0 then open.rows[#open.rows + 1] = { spellID = spellID, totalAmount = amount, overkillAmount = 0 } end
        else
            open = nil
        end
    end
    return fights
end

-- Plate the player targets at time t: the last timeline entry with from <= t.
local function TargetAt(targets, t)
    local plate
    for _, entry in ipairs(targets) do
        if t >= entry.from then plate = entry.plate end
    end
    return plate
end

local function IsPlate(unit) return unit and unit:find("^nameplate%d+$") ~= nil end

-- The target timeline of a log whose HITs carry target=true|false (see TargetAt). The first target holds from
-- the start; a switch starts at the first player cast after the old target's last flagged hit (the cast
-- before the switch belongs to the new target); a flagged-false hit on the target clears it. HITs with no
-- target= never change it.
local function TargetsFromLog(events)
    local targets, plate, pendingCast = {}, nil, nil
    for _, event in ipairs(events) do
        if event.kind == "C" and event.unit == "player" then
            pendingCast = pendingCast or event.t
        elseif event.kind == "U" and IsPlate(event.unit) then
            if event.target == true and event.unit ~= plate then
                local from = (#targets == 0 and -math.huge) or pendingCast or event.t
                targets[#targets + 1] = { from = from, plate = event.unit }
                plate = event.unit
            elseif event.target == false and event.unit == plate then
                targets[#targets + 1] = { from = event.t, plate = nil }
                plate = nil
            end
            if event.target == true then pendingCast = nil end
        end
    end
    return targets
end

local function LabelOf(fixtureLabels, event)
    if event.read and event.read.count > 0 then return "meter" end
    local label = fixtureLabels.lines[event.line]
        or fixtureLabels.keys[event.phase .. " " .. event.unit .. " " .. event.school]
        or (fixtureLabels.schools and fixtureLabels.schools[event.school])
    if label == nil then
        error(string.format("labels.lua: no label for line %d (phase %d %s school %d)", event.line, event.phase, event.unit, event.school))
    end
    return label
end

-- Channel stops: the next player cast, or the spell's duration, whichever is first.
local function AddChannelStops(events, spells)
    local stops = {}
    for index, event in ipairs(events) do
        local spell = event.kind == "C" and event.unit == "player" and spells[event.id]
        if spell and spell.mode == "channel" then
            local stopAt, order = event.t + spell.duration, nil
            for later = index + 1, #events do
                local other = events[later]
                if other.t > stopAt then break end
                if other.kind == "C" and other.unit == "player" then stopAt, order = other.t, other.order - 0.25 break end
            end
            stops[#stops + 1] = { kind = "STOP", t = stopAt, id = event.id, castGUID = "Cast-" .. event.line,
                phase = event.phase, order = order or math.huge }
        end
    end
    for _, stop in ipairs(stops) do events[#events + 1] = stop end
end

-- Teammate hits for the noise test (spec: Testing / Noise test). `mode` (optional): noSameFrame drops the
-- stranger at each own read; crowd replaces all noise with three fixed strangers (school 1, amount 1000) per
-- recorded type-0 stamp, at t, t + 0.05 and t + 0.08 (event.crowd = 0, 1, 2), on the plate of the hit the stamp
-- belongs to (an R stamp: the hit before it; an M stamp: the own plate hit of that frame), else the phase's first plate.
local function AddNoise(events, seed, minPhase, mode)
    mode = mode or {}
    math.randomseed(seed)
    local schools = { 1, 4, 32, 36 }
    local function NoiseHit(t, unit, phase, order)
        local school = schools[math.random(4)]
        local amount = math.floor(math.exp(math.log(300) + math.random() * (math.log(20000) - math.log(300))))
        local crit = math.random() < 0.2
        return { kind = "U", noise = true, t = t, unit = unit, event = "WOUND", flag = crit and "CRITICAL" or "",
            amount = crit and amount * 2 or amount, school = school, phase = phase, order = order }
    end
    local spans, phases = {}, {}
    for _, event in ipairs(events) do
        if event.phase >= minPhase and event.kind ~= "STOP" then
            local span = spans[event.phase]
            if not span then
                span = { from = event.t, to = event.t, plates = {} }
                spans[event.phase] = span
                phases[#phases + 1] = event.phase
            end
            span.from, span.to = math.min(span.from, event.t), math.max(span.to, event.t)
            if event.kind == "U" and IsPlate(event.unit) then span.plates[event.unit] = true end
        end
    end
    table.sort(phases)
    local added, firstPlate = {}, {}
    for _, phase in ipairs(phases) do
        local span, plates = spans[phase], {}
        for unit in pairs(span.plates) do plates[#plates + 1] = unit end
        table.sort(plates)
        firstPlate[phase] = plates[1]
        for _, unit in ipairs(mode.crowd and {} or plates) do
            local slot = span.from
            while slot < span.to do
                added[#added + 1] = NoiseHit(slot + math.random(), unit, phase, -1)
                slot = slot + 1
            end
        end
    end
    local function OwnPlate(stamp, index)
        local hit = stamp.kind == "R" and events[index - 1]
        if hit and hit.kind == "U" and IsPlate(hit.unit) then return hit.unit end
        if stamp.kind == "M" then
            for _, other in ipairs(events) do
                if other.kind == "U" and other.t == stamp.t and IsPlate(other.unit) then return other.unit end
            end
        end
        return firstPlate[stamp.phase]
    end
    for index, event in ipairs(events) do
        local isStamp = event.phase >= minPhase and event.meterType == 0 and (event.kind == "M" or (event.kind == "R" and event.count > 0))
        if mode.crowd and isStamp then
            local unit = OwnPlate(event, index)
            for crowd, delay in ipairs({ 0, 0.05, 0.08 }) do
                if unit then
                    added[#added + 1] = { kind = "U", noise = true, crowd = crowd - 1, t = event.t + delay, unit = unit, event = "WOUND",
                        flag = "", amount = 1000, school = 1, phase = event.phase, order = delay == 0 and event.order + 0.5 or -1 }
                end
            end
        elseif not mode.crowd and not mode.noSameFrame and event.kind == "R" and event.count > 0 and event.phase >= minPhase then
            local hit = events[index - 1]
            local unit = hit and hit.kind == "U" and IsPlate(hit.unit) and hit.unit or firstPlate[event.phase]
            if unit then added[#added + 1] = NoiseHit(event.t, unit, event.phase, event.order + 0.5) end
        end
    end
    for _, event in ipairs(added) do events[#events + 1] = event end
end

-- Replay ---------------------------------------------------------------------------

local allResets = 0 -- the meter resets of every replay (criterion 6)

local MISSING = setmetatable({}, { __index = function() return 0 end })

-- A shallow copy of a saved table.
local function Copy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function DeepCopy(source)
    if type(source) ~= "table" then return source end
    local copy = {}
    for key, value in pairs(source) do copy[key] = DeepCopy(value) end
    return copy
end

-- Replays one fixture; returns the scored hits, the labels and an info table (info.learnLog: every
-- Tracker.OnLearned call as { id, t, phase }; info.events: the replayed events; info.haste: the stub haste).
-- Single mode: no meter is read, so S.pending stays empty. Recorded meter events draw nothing. The fight
-- opens with PLAYER_REGEN_DISABLED and closes with PLAYER_REGEN_ENABLED (the Teacher's read waits in S.timers).
-- opts.group: the player is in a group. opts.charDB: the carried CombatTextIconsCharDB.
-- opts.noise = seed: stranger hits (opts.noSameFrame: none at each own read); opts.crowd: three at each
-- recorded type-0 stamp (see AddNoise); opts.minPhase: the first phase that gets strangers.
-- opts.area ("clear" | "crowded", default "clear"): the crowd check's state when the fight starts; every
-- replay was written for "an unexplained solo hit draws '?'", so clear is the default.
-- opts.noSeen: the crowd check is off (Teacher.Seen does nothing).
-- opts.meter: the Teacher's read runs (the timers fire) against S.sessions = opts.sessionRows, or none; opts.seen
-- overwrites Teacher.fight.seen before the fight ends. opts.labels / opts.events replace the fixture's labels
-- and events (a slice of a log); info.charDB is the char DB after the fight.
-- Each UNIT_COMBAT hit records its last "  -> " debug line as hit.route; info.teacher is the booted Teacher.
local function Replay(name, opts)
    local fixtureLabels = opts.labels or labels[name]
    local ns = Boot(function()
        CombatTextIconsDB = { meter = false }
        if opts.charDB then CombatTextIconsCharDB = opts.charDB end
    end)
    ns.Teacher.area = opts.area or "clear"
    if opts.noSeen then
        -- the test session holds only the labeled hits, not the whole meter, so the crowd check cannot judge it
        ns.Teacher.Seen = function() end
    end
    local route -- the last "  -> " debug line of the UNIT_COMBAT being replayed
    ns.Debug = function(format, ...)
        local line = string.format(format, ...)
        if line:find("^  %->") then route = line end
    end
    S.haste = opts.haste or fixtureLabels.haste
    S.group = opts.group == true
    S.petTarget = true
    local castPlates = {}
    for line, unit in pairs(fixtureLabels.castPlates) do castPlates[line] = unit end
    for line, unit in pairs(opts.variant and opts.variant.castPlates or {}) do castPlates[line] = unit end

    local targets = fixtureLabels.targets
    local events = opts.events or (targets and ParseSvLog(name) or ParseFixture(name))
    AddChannelStops(events, fixtureSpells)
    if opts.noise or opts.crowd then AddNoise(events, opts.noise or 1, opts.minPhase or 1, opts) end
    table.sort(events, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.order < b.order
    end)

    local Core = ns.Core
    local draws = {} -- every draw since the list was last emptied
    ns.Display.Plate = function(plate, texture, text, flagText, school)
        draws[#draws + 1] = { plate = plate, texture = texture, text = text }
    end
    ns.Display.Player = function(kind, texture, text, flagText)
        draws[#draws + 1] = { kind = kind, texture = texture, text = text }
    end
    ns.Display.Notice = function() end -- fight-end popups are not hits: the replays draw nothing new
    local function Show(hit, draw)
        hit.shown, hit.via = draw, draw.texture == ns.Meter.UNKNOWN_ICON and "unknown" or "tracker"
    end
    local info = { uncovered = {}, group = S.group, learnLog = {}, births = {}, events = events, haste = S.haste, teacher = ns.Teacher }
    local phase -- of the event being replayed, for the learn log
    local onLearned = ns.Tracker.OnLearned
    ns.Tracker.OnLearned = function(spellID, now)
        info.learnLog[#info.learnLog + 1] = { id = spellID, t = now, phase = phase }
        return onLearned(spellID, now)
    end
    local onBirth = ns.Learn.OnBirth
    ns.Learn.OnBirth = function(key, stream, now)
        info.births[#info.births + 1] = { key = key, school = stream.school, period = stream.period, at = now }
        return onBirth(key, stream, now)
    end

    local excluded = fixtureLabels.excludePhases or {}
    local hits = {}
    S.now = events[1].t
    Core.PLAYER_REGEN_DISABLED()
    for _, event in ipairs(events) do
        S.now, phase = event.t, event.phase
        if targets then S.target = TargetAt(targets, event.t) end
        S.pending, S.pendingTag = {}, ""
        if event.kind == "U" then
            draws = {}
            route = nil
            Core.UNIT_COMBAT(event.unit, event.event, event.flag, event.amount, event.school)
            local hit, draw = { event = event, noise = event.noise, route = route }, draws[#draws]
            draws = {}
            if draw then Show(hit, draw) end
            if not excluded[event.phase] then hits[#hits + 1] = hit end
        elseif event.kind == "M" or event.kind == "R" or event.kind == "O" then
            -- meter reads and other lines draw nothing
        elseif event.kind == "C" and (event.unit == "player" or event.unit == "pet") then
            -- an unknown player cast with no plate for the cast log
            local plate = targets and TargetAt(targets, event.t) or castPlates[event.line]
            local isUncovered = event.unit == "player" and not ns.Spells[event.id] and not plate
            if isUncovered then info.uncovered[#info.uncovered + 1] = event.line end
            S.target = plate
            if Core.UNIT_SPELLCAST_SUCCEEDED then
                Core.UNIT_SPELLCAST_SUCCEEDED(event.unit, "Cast-" .. event.line, event.id)
                local spell = fixtureSpells[event.id]
                if event.unit == "player" and spell and spell.mode == "channel" then
                    Core.UNIT_SPELLCAST_CHANNEL_START("player", "Cast-" .. event.line, event.id)
                end
            end
        elseif event.kind == "STOP" then
            if Core.UNIT_SPELLCAST_CHANNEL_STOP then Core.UNIT_SPELLCAST_CHANNEL_STOP("player", event.castGUID, event.id) end
        end
    end
    if opts.seen and ns.Teacher.fight then ns.Teacher.fight.seen = opts.seen end
    Core.PLAYER_REGEN_ENABLED() -- the fight ends: buffered samples commit, the read is queued
    if opts.meter then
        S.sessions = opts.sessionRows and { { sessionID = 1, name = "Current", durationSeconds = 60, rows = opts.sessionRows } } or {}
        for _, timer in ipairs(S.timers) do timer.fn() end
    end
    info.resets = S.resets
    allResets = allResets + S.resets
    info.casts = DeepCopy(CombatTextIconsCharDB.casts)
    info.castAliases = DeepCopy(CombatTextIconsCharDB.castAliases)
    info.learned = Copy(CombatTextIconsCharDB.learned)
    info.votes = {}
    for id, votes in pairs(CombatTextIconsCharDB.votes) do
        local sigs = {}
        for key, sig in pairs(votes.sigs or {}) do sigs[key] = Copy(sig) end
        info.votes[id] = { casts = votes.casts, sigs = sigs }
    end
    info.charDB = DeepCopy(CombatTextIconsCharDB)
    return hits, fixtureLabels, info
end

local SHADOW_DOTS, PRIEST_DUMMY = "shadow-dots-2026-10-24", "priest-dummy-2026-10-24" -- the TEACH-bearing fixtures
local FORGET5 = "shadow-forget5-2026-10-25" -- /cti forget, then 5 solo fights (Voidweaver-era shadow priest)
local TRIGGER_ID = 1227280 -- Tentacle Slam: applies VT, has no meter row of its own (TEACH ... meter=0 in both fixtures)
local FIGHT_FIXTURES = { -- startArea: each log's first unexplained route (shadow-dots "-> unknown-solo", priest-dummy "-> HIDDEN (crowded)")
    [SHADOW_DOTS] = { startArea = "clear" },
    [PRIEST_DUMMY] = { startArea = "crowded" },
    -- rowIDs: the rows that log printed under the cast it was aliased to. 263165 (Void Torrent) never prints as its
    -- own ID; F4's 1231479 and 263165 are confirmed by the char SV's saved verdicts (meterID), the rest inferred.
    [FORGET5] = { startArea = "crowded", rowIDs = {
        { ["450983:93761"] = 263165, ["8092:2364"] = 1260076 },
        { ["450983:93551"] = 263165, ["335467:7382"] = 451435 },
        { ["450983:148859"] = 263165, ["1227280:47499"] = 413231 },
        { ["450983:61896"] = 263165, ["8092:53675"] = 1231479 },
    } },
}
-- Replays a TEACH-bearing log one fight at a time with the meter on. Each fight is the slice of events after
-- the previous TEACH clean line up to its own; the tail after the last one is a run with no rows (its read
-- skips). The char DB and the crowd area carry from fight to fight; opts.charDB seeds the first, opts.haste
-- reaches the stub. runs[i] = { hits, info, last = Teacher.last }.
local function ReplayFights(name, opts)
    local fixture = assert(FIGHT_FIXTURES[name], "no fight fixture " .. name)
    local log = LoadLog(name .. ".sv.lua")
    local fights, all = ParseTeach(log, fixture.rowIDs), ParseLog(name, log)
    local runs, charDB, area, prevEnd = {}, opts.charDB, fixture.startArea, 0
    for i = 1, #fights + 1 do
        local fight = fights[i]
        local endLine = fight and fight.endLine or math.huge
        local slice = {}
        for _, event in ipairs(all) do
            if event.line > prevEnd and event.line < endLine then slice[#slice + 1] = event end
        end
        if #slice == 0 then break end
        local hits, _, info = Replay(name, {
            labels = { haste = 0, castPlates = {}, targets = TargetsFromLog(slice) }, events = slice,
            haste = opts.haste, meter = true, sessionRows = fight and fight.rows, seen = fight and fight.seen,
            area = area, charDB = charDB and DeepCopy(charDB),
        })
        runs[#runs + 1] = { hits = hits, info = info, last = info.teacher.last }
        charDB, area, prevEnd = info.charDB, info.teacher.area, endLine
    end
    return runs
end

-- Scoring --------------------------------------------------------------------------

local function Accepts(label, texture)
    for alternative in tostring(label):gmatch("[^|]+") do
        if texture == "tex:" .. alternative then return true end
    end
    return false
end

-- Verdict of one real plate WOUND: "correct", "wrong", "hidden" (missed), or
-- "unscored" (a meter entry crossed to another hit of the same frame).
-- "a|b" = either icon is right.
local function Verdict(label, hit)
    if label == "excluded" then return "unscored" end
    if not hit.shown then return label == "hidden" and "correct" or "hidden" end
    if hit.via == "unknown" then return tostring(label):find("|", 1, true) and "correct" or "unknown" end
    if hit.via == "meter" then return label == "meter" and "correct" or "wrong" end
    if hit.via == "meter-other" then return label == "meter" and "correct" or "unscored" end
    if hit.via == "early" then return label == "pet" and "correct" or "wrong" end
    if label == "meter" then return "unscored" end
    return Accepts(label, hit.shown.texture) and "correct" or "wrong"
end

local function NewTally() return { correct = 0, wrong = 0, hidden = 0, unknown = 0, unscored = 0, total = 0 } end

local function Score(name, hits, fixtureLabels, runName, report)
    local run = { name = runName, byLabel = {}, wrong = {}, unscored = {}, unknown = {}, school106 = 0, hiddenUnknown = 0,
        phases = {}, heals = {}, taken = { shown = 0, total = 0 }, hits = hits, labels = fixtureLabels }
    for _, hit in ipairs(hits) do
        local event = hit.event
        if event.unit == "player" then
            if event.event == "HEAL" then
                local key = not hit.shown and "hidden" or (hit.via == "meter" and "meter")
                    or (hit.shown.texture == "tex:234153" and "drain life") or ("other " .. tostring(hit.shown.texture))
                run.heals[key] = (run.heals[key] or 0) + 1
            elseif event.event == "WOUND" then
                run.taken.total = run.taken.total + 1
                if hit.shown then run.taken.shown = run.taken.shown + 1 end
            end
        elseif IsPlate(event.unit) and event.event == "WOUND" and not hit.noise then
            local label = LabelOf(fixtureLabels, event)
            local verdict = Verdict(label, hit)
            local key = tostring(label)
            run.byLabel[key] = run.byLabel[key] or NewTally()
            local tally = run.byLabel[key]
            tally[verdict], tally.total = tally[verdict] + 1, tally.total + 1
            local phaseKey = event.phase .. " " .. key
            run.phases[phaseKey] = run.phases[phaseKey] or NewTally()
            run.phases[phaseKey][verdict], run.phases[phaseKey].total = run.phases[phaseKey][verdict] + 1, run.phases[phaseKey].total + 1
            if event.school == 106 and hit.shown and hit.via ~= "unknown" then
                run.school106 = run.school106 + 1
            end
            if label == "hidden" and hit.via == "unknown" then run.hiddenUnknown = run.hiddenUnknown + 1 end
            if verdict == "wrong" or verdict == "unscored" or verdict == "unknown" then
                local list = (verdict == "wrong" and run.wrong) or (verdict == "unknown" and run.unknown) or run.unscored
                list[#list + 1] = string.format("%s line %d t=%.3f %s school %d amount %d: label %s, shown %s via %s, recorded route %s",
                    name, event.line, event.t, event.unit, event.school, event.amount, key,
                    tostring(hit.shown and hit.shown.texture), tostring(hit.via), tostring(event.route or "-"))
            end
        end
    end
    report[#report + 1] = run
    return run
end

-- Criterion 12 score of one single-mode replay against `direct.lines` (debug-log index -> spell ID or
-- "excluded"). Denominator = plate hits labeled with a spell ID, drawn or not. right = shown with the
-- label's cast-spell icon; wrong = shown with any other icon but the question mark; "?" and hidden
-- are neither. unlabeledDrawn = unlabeled hits drawn with a spell icon (information only).
-- missed = every labeled hit that is not right, for the --wrong listing.
local function ScoreDirect(lines, hits)
    local score = { den = 0, right = 0, wrong = 0, hidden = 0, unknown = 0, unlabeledDrawn = 0, missed = {} }
    for _, hit in ipairs(hits) do
        local event = hit.event
        if IsPlate(event.unit) and event.event == "WOUND" then
            local label = lines[event.line]
            local texture = hit.shown and hit.shown.texture
            if label == nil then
                if texture and texture ~= UNKNOWN_ICON then score.unlabeledDrawn = score.unlabeledDrawn + 1 end
            elseif label ~= "excluded" then
                score.den = score.den + 1
                local kind = (texture == "tex:" .. label and "right") or (texture == UNKNOWN_ICON and "unknown")
                    or (texture and "wrong") or "hidden"
                score[kind] = score[kind] + 1
                if kind ~= "right" then
                    score.missed[#score.missed + 1] = { kind = kind, line = event.line, t = event.t, unit = event.unit,
                        school = event.school, amount = event.amount, label = label, shown = texture, route = event.route }
                end
            end
        end
    end
    return score
end

local function Share(tally) return tally.total > 0 and tally.correct / tally.total or 0 end

-- Criterion 8 rule: whether learned entry `entry` of spell `id` is right for a replay (`info` from Replay).
-- Right = the player cast `id` in that fixture, and the plate WOUND hits labeled `id` (or its fixture tick
-- icon) give: entry.school among their schools; entry.kind "channel" when the fixture row of `id` is a
-- channel, else "dot"; entry.period / (1 + haste) within 25 % (Learn's SIG_AGREE) of the median gap between
-- consecutive labeled hits on one plate (gaps 0.1-10 s: no same-frame pairs, no pauses). Returns ok and the reason.
local function LearnedRight(id, entry, info, fixtureLabels)
    local cast = false
    for _, event in ipairs(info.events) do
        if event.kind == "C" and event.unit == "player" and event.id == id then cast = true break end
    end
    if not cast then return false, "never cast" end
    local row = fixtureSpells[id]
    local accepted = { [tostring(id)] = true, [tostring(row and row.icon or id)] = true }
    local excluded, schools, last, gaps = fixtureLabels.excludePhases or {}, {}, {}, {}
    for _, event in ipairs(info.events) do
        if event.kind == "U" and not event.noise and IsPlate(event.unit) and event.event == "WOUND" and not excluded[event.phase]
            and accepted[tostring(LabelOf(fixtureLabels, event))] then
            schools[event.school] = true
            local gap = last[event.unit] and event.t - last[event.unit]
            if gap and gap >= 0.1 and gap <= 10 then gaps[#gaps + 1] = gap end
            last[event.unit] = event.t
        end
    end
    if #gaps == 0 then return false, "no labeled ticks" end
    if not schools[entry.school] then return false, "school " .. tostring(entry.school) end
    local kind = row and row.mode == "channel" and "channel" or "dot"
    if entry.kind ~= kind then return false, "kind " .. tostring(entry.kind) .. ", ticks say " .. kind end
    table.sort(gaps)
    local median, expected = gaps[math.floor((#gaps + 1) / 2)], entry.period / (1 + (info.haste or 0) / 100)
    if math.abs(expected - median) > 0.25 * math.max(expected, median) then
        return false, string.format("period %.3f s at haste %.1f %%, ticks %.3f s", expected, info.haste or 0, median)
    end
    return true, "ok"
end

-- Criteria 3 and 7 (learning only, measured, no threshold yet): for one spell of a scored run (`run.hits`,
-- `run.labels`, `run.info`), when one of `ids` was first learned, the wrong attributions, and the share of
-- its labeled hits (in `phases`) drawn with its own icon before and after that moment.
local function LearningLine(run, name, label, ids, phases)
    local learnedAt
    for _, entry in ipairs(run.info.learnLog) do
        if ids[entry.id] then learnedAt = entry break end
    end
    local before, after, count, firstAfter, foreign = NewTally(), NewTally(), 0, nil, 0
    for _, hit in ipairs(run.hits) do
        local event = hit.event
        if IsPlate(event.unit) and event.event == "WOUND" and not hit.noise then
            local key = tostring(LabelOf(run.labels, event))
            if key == label and phases[event.phase] then
                count = count + 1
                local late = learnedAt ~= nil and event.t >= learnedAt.t
                if late and not firstAfter then firstAfter = count end
                local tally, verdict = late and after or before, Verdict(LabelOf(run.labels, event), hit)
                tally[verdict], tally.total = tally[verdict] + 1, tally.total + 1
            elseif key ~= label and hit.shown and hit.shown.texture == "tex:" .. label then
                foreign = foreign + 1
            end
        end
    end
    local when = "never"
    if learnedAt then
        when = string.format("%d at t=%.3f (phase %s, hit %s of %d)", learnedAt.id, learnedAt.t, tostring(learnedAt.phase),
            firstAfter and tostring(firstAfter) or "none after", count)
    end
    local votes = {}
    for id in pairs(ids) do
        local entry = run.info.votes[id]
        if entry then
            local best
            for _, sig in pairs(entry.sigs) do if not best or sig.votes > best.votes then best = sig end end
            votes[#votes + 1] = string.format("%d casts %d%s", id, entry.casts, best
                and string.format(" best %s/%s v%d e%.3f", tostring(best.kind), tostring(best.school), best.votes, best.expected) or "")
        end
    end
    table.sort(votes)
    local function Rate(tally)
        return tally.total > 0 and string.format("%d/%d = %.1f %%", tally.correct, tally.total, Share(tally) * 100) or "-"
    end
    return string.format("%s: learned %s; votes %s; wrong %d (+%d other hits drawn with its icon); own icon before %s, after %s",
        name, when, #votes > 0 and table.concat(votes, ", ") or "none", before.wrong + after.wrong, foreign, Rate(before), Rate(after))
end

local LABEL_NAMES = { ["980"] = "Agony", ["1259790"] = "Unstable Affliction", ["445474"] = "Wither",
    ["234153"] = "Drain Life", ["686"] = "Shadow Bolt", meter = "meter (own read)", pet = "pet melee", hidden = "hidden (not ours / not attributable)",
    ["188443"] = "Chain Lightning", ["188389|470411"] = "Flame Shock (188389|470411)", excluded = "excluded (v2b, unscored)" }

-- "id (school S, P s, kind)" per learned entry, sorted by id.
local function Describe(entries)
    local parts = {}
    for id, entry in pairs(entries) do
        parts[#parts + 1] = { id = id, text = string.format("%s (school %s, %s s, %s)", tostring(id),
            tostring(entry.school), tostring(entry.period), tostring(entry.kind)) }
    end
    table.sort(parts, function(a, b) return a.id < b.id end)
    local texts = {}
    for index, part in ipairs(parts) do texts[index] = part.text end
    return #texts > 0 and table.concat(texts, "; ") or "none"
end

local function PrintRun(run)
    Out(string.format("  %s", run.name))
    local keys = {}
    for key in pairs(run.byLabel) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local tally = run.byLabel[key]
        Out(string.format("    %-38s n=%-4d correct=%-4d wrong=%-3d hidden=%-4d unknown=%-3d unscored=%d",
            LABEL_NAMES[key] or key, tally.total, tally.correct, tally.wrong, tally.hidden, tally.unknown, tally.unscored))
    end
    local heals = {}
    for key, count in pairs(run.heals) do heals[#heals + 1] = key .. "=" .. count end
    table.sort(heals)
    Out(string.format("    heals on player: %s | damage taken shown %d/%d",
        #heals > 0 and table.concat(heals, " ") or "none", run.taken.shown, run.taken.total))
    if run.info then
        Out(string.format("    learned: %s", Describe(run.info.learned)))
    end
    for index, line in ipairs(run.unknown) do
        if index > 5 then
            Out(string.format("    (%d more)", #run.unknown - 5))
            break
        end
        Out("    UNKNOWN " .. line)
    end
    if run.showVotes and run.info then
        local ids = {}
        for id in pairs(run.info.votes) do ids[#ids + 1] = id end
        table.sort(ids)
        local parts = {}
        for _, id in ipairs(ids) do
            local entry, sigs = run.info.votes[id], {}
            for _, sig in pairs(entry.sigs) do
                sigs[#sigs + 1] = string.format("%s/%s v%s e%.3f", tostring(sig.kind), tostring(sig.school), tostring(sig.votes), tonumber(sig.expected) or 0)
            end
            parts[#parts + 1] = string.format("%d: casts %d [%s]", id, entry.casts, table.concat(sigs, ", "))
        end
        Out("    votes: " .. table.concat(parts, "; "))
    end
    if OPTIONS["--wrong"] then
        for _, line in ipairs(run.wrong) do Out("    WRONG " .. line) end
        for _, line in ipairs(run.unscored) do Out("    UNSCORED " .. line) end
    end
end

-- Haste estimate from labels (spec: median Wither/Agony interval).
local function HasteEstimate(name)
    local fixtureLabels = labels[name]
    local excluded = fixtureLabels.excludePhases or {}
    local last, gaps = {}, {}
    for _, event in ipairs(ParseFixture(name)) do
        if event.kind == "U" and IsPlate(event.unit) and event.event == "WOUND" and not excluded[event.phase] then
            local label = LabelOf(fixtureLabels, event)
            if label == 980 or label == 445474 then
                local key = event.unit .. " " .. event.school
                if last[key] then
                    local gap = event.t - last[key]
                    if gap > 0.9 and gap < 2.0 then gaps[#gaps + 1] = gap end
                end
                last[key] = event.t
            end
        end
    end
    table.sort(gaps)
    local median = gaps[math.floor((#gaps + 1) / 2)]
    return (2 / median - 1) * 100, median, #gaps
end

-- Unit checks ----------------------------------------------------------------------

local checks = { passed = 0, failed = {} }
local function Check(name, condition)
    if condition then checks.passed = checks.passed + 1 else checks.failed[#checks.failed + 1] = name end
end

-- Lines printed under the criteria list as "note: ..."; checks use them for measured numbers that are not asserted.
local notes = {}

-- Runs one check file with the stubs table `T`. An error inside it fails one named check
-- instead of ending the run, so the criteria still print.
local function RunCheckFile(file, T)
    local ok, err = pcall(function() dofile(ROOT .. "/tests/" .. file)(T) end)
    if not ok then Check("tests/" .. file .. " ran without error: " .. tostring(err), false) end
end

-- The checks live in tests/checks.lua (which runs the other check files through T.RunFile);
-- they get the stubs through this table.
local function RunChecks()
    local T
    T = {
        Boot = Boot, BootSpells = function(setup) return Boot(setup, true) end, Check = Check, Secret = Secret, Generic = Generic, Plate = Plate, TocFiles = TocFiles,
        Note = function(text) notes[#notes + 1] = text end,
        State = function() return S end, Root = ROOT,
        RunFile = function(file) RunCheckFile(file, T) end,
    }
    RunCheckFile("checks.lua", T)
end

-- Harness self-checks: the SavedVariables parser, target timelines, labels and verdicts,
-- against numbers counted from the three shaman .sv.lua files themselves; the priest
-- logs only have to parse.
local SV_NAMES = { "shaman-fs-forget", "shaman-cl-instants", "shaman-cl-clean" }
local PRIEST_LOGS = { "priest-direct-2026-10-23", "priest-level-2026-10-23", "priest-renew-2026-10-23",
    "priest-swp-learn-2026-10-23" }
local SV_ORACLE = {
    ["shaman-fs-forget"] = { casts = 38, hits = 165, readHit = 80, readEvent = 15, first = 23276.305, last = 23328.519,
        routes = { AMBIGUOUS = 1, HIDDEN = 36, chain = 48, meter = 80 },
        labels = { meter = 81, ["188443"] = 45, ["188389|470411"] = 36, excluded = 3 }, chainStarts = 16, firstHits = 0, fsDirect = 5, chainSchool8 = 48 },
    ["shaman-cl-instants"] = { casts = 15, hits = 49, readHit = 18, readEvent = 6, first = 22575.696, last = 22594.523,
        routes = { HIDDEN = 18, chain = 13, meter = 18 },
        labels = { meter = 18, ["188443"] = 21, ["188389|470411"] = 10 }, chainStarts = 5, firstHits = 0, fsDirect = 2, chainSchool8 = 12 },
    ["shaman-cl-clean"] = { casts = 11, hits = 33, readHit = 0, readEvent = 11, first = 21511.385, last = 21528.749,
        routes = { HIDDEN = 33 }, labels = { ["188443"] = 33 }, chainStarts = 0, firstHits = 11, fsDirect = 0, chainSchool8 = 0 },
}
local DIRECT_NAMES = { "priest-direct", "priest-wand", "priest-retest", "shaman-cl-clean", "shaman-cl-instants" }
local DIRECT_ORACLE = { -- casts / hits: grep of the .sv.lua; spells / excluded: hand review (Task 3.1)
    ["priest-direct"]      = { casts = 16, hits = 16, spells = { [591] = 10, [8092] = 3, [5019] = 2 }, excluded = 0, perCast = true },
    ["priest-wand"]        = { casts = 14, hits = 15, spells = { [5019] = 14 }, excluded = 1, perCast = true },
    ["priest-retest"]      = { casts = 12, hits = 32, spells = { [5019] = 3 }, excluded = 0, perCast = true },
    ["shaman-cl-clean"]    = { casts = 11, hits = 33, spells = { [188443] = 33 }, excluded = 0, chain = true },
    ["shaman-cl-instants"] = { casts = 15, hits = 49, spells = { [188443] = 12 }, excluded = 4, chain = true },
}

local function HarnessChecks()
    local function Shown(texture, via) return { shown = { texture = texture }, via = via or "tracker" } end
    Check("verdict: either alternative icon is correct, another icon is wrong",
        Verdict("188389|470411", Shown("tex:188389")) == "correct" and Verdict("188389|470411", Shown("tex:470411")) == "correct"
        and Verdict("188389|470411", Shown("tex:188443")) == "wrong")
    Check("verdict: '?' under an alternatives label is correct", Verdict("188389|470411", Shown(UNKNOWN_ICON, "unknown")) == "correct")
    Check("verdict: '?' under any other label is unknown, not wrong",
        Verdict("meter", Shown(UNKNOWN_ICON, "unknown")) == "unknown" and Verdict(188443, Shown(UNKNOWN_ICON, "unknown")) == "unknown"
        and Verdict("hidden", Shown(UNKNOWN_ICON, "unknown")) == "unknown")
    Check("verdict: an excluded line is unscored, shown or not", Verdict("excluded", Shown("tex:470411")) == "unscored" and Verdict("excluded", {}) == "unscored")
    Check("verdict: the existing rules are unchanged", Verdict(980, Shown("tex:980")) == "correct" and Verdict(980, Shown("tex:1")) == "wrong"
        and Verdict(980, {}) == "hidden" and Verdict("hidden", {}) == "correct")

    for _, name in ipairs(SV_NAMES) do
        local entry = labels[name]
        local ok = entry ~= nil and type(entry.log) == "string" and entry.haste == 0 and type(entry.targets) == "table"
            and #entry.targets >= 1 and type(entry.schools) == "table" and type(entry.lines) == "table"
        Check("labels: " .. name .. " has log, haste, targets, schools and lines", ok)
        if ok then
            local o, events = SV_ORACLE[name], ParseSvLog(name)
            local count = { C = 0, U = 0, R = 0, M = 0 }
            local routes, paired, pairedOk = {}, 0, true
            for _, event in ipairs(events) do
                count[event.kind] = count[event.kind] + 1
                if event.kind == "U" then
                    routes[event.route] = (routes[event.route] or 0) + 1
                    if event.read then
                        paired = paired + 1
                        pairedOk = pairedOk and event.read.t == event.t and event.read.line == event.line - 1 and event.read.paired == true
                    end
                end
            end
            local routesOk = true
            for route, n in pairs(o.routes) do routesOk = routesOk and routes[route] == n end
            Check(name .. ": parse counts (casts, hits, READ hit, READ event) and first / last time",
                count.C == o.casts and count.U == o.hits and count.R == o.readHit and count.M == o.readEvent
                and events[1].t == o.first and events[#events].t == o.last)
            Check(name .. ": recorded routes counted per HIT", routesOk)
            Check(name .. ": every READ hit pairs with the HIT on the next line, same frame (never the previous HIT)",
                paired == o.readHit and pairedOk)

            -- Labels
            local tally, labelErrors, chain8 = {}, 0, 0
            for _, event in ipairs(events) do
                if event.kind == "U" then
                    local ok2, label = pcall(LabelOf, entry, event)
                    if ok2 then
                        tally[tostring(label)] = (tally[tostring(label)] or 0) + 1
                        if event.route == "chain" and event.school == 8 and (tostring(label) == "188443" or label == "excluded") then chain8 = chain8 + 1 end
                    else
                        labelErrors = labelErrors + 1
                    end
                end
            end
            local tallyOk = labelErrors == 0
            for label, n in pairs(o.labels) do tallyOk = tallyOk and tally[label] == n end
            Check(name .. ": every HIT has a label and the tallies match the counted fixture", tallyOk)
            Check(name .. ": every recorded school-8 chain hit is 188443 (or excluded)", chain8 == o.chainSchool8)

            -- Timeline: every chain start / FS direct hit / (cl-clean) first hit lands on the target plate
            local starts, direct, firsts, misplaced = 0, 0, 0, 0
            for index, cast in ipairs(events) do
                if cast.kind == "C" then
                    local plate = TargetAt(entry.targets, cast.t)
                    for later = index + 1, #events do
                        local event = events[later]
                        if event.t - cast.t > 0.6 then break end
                        if event.kind == "U" then
                            local wanted
                            if cast.id == 188443 and o.chainStarts > 0 then wanted = event.route == "chain"
                            elseif cast.id == 188443 then wanted = true
                            elseif cast.id == 188389 then wanted = event.school == 12 and event.read ~= nil and event.t - cast.t <= 0.1 end
                            if wanted then
                                if cast.id == 188443 and o.chainStarts > 0 then starts = starts + 1
                                elseif cast.id == 188443 then firsts = firsts + 1
                                else direct = direct + 1 end
                                if event.unit ~= plate then misplaced = misplaced + 1 end
                                break
                            end
                        end
                    end
                end
            end
            Check(name .. ": timeline - " .. o.chainStarts .. " chain starts, " .. o.firstHits .. " first hits after a CL cast and "
                .. o.fsDirect .. " FS direct hits all land on the target plate",
                misplaced == 0 and starts == o.chainStarts and firsts == o.firstHits and direct == o.fsDirect)

            -- Replay support
            local hits, _, info = Replay(name, {})
            Check(name .. ": replay returns one hit per HIT, no uncovered cast, a votes snapshot",
                #hits == o.hits and #info.uncovered == 0 and type(info.votes) == "table")
        end
    end
    -- Direct labels (Task 3.1): each fixture's hand-reviewed `direct.lines` against numbers counted from its log.
    for _, name in ipairs(DIRECT_NAMES) do
        local entry, o = labels[name], DIRECT_ORACLE[name]
        local shape = entry ~= nil and type(entry.log) == "string" and entry.haste == 0 and type(entry.targets) == "table"
            and #entry.targets >= 1 and type(entry.keys) == "table" and type(entry.castPlates) == "table"
            and type(entry.direct) == "table" and type(entry.direct.lines) == "table"
        Check("direct labels: " .. name .. " has log, haste 0, targets, keys, castPlates and direct.lines", shape)
        if shape then
            local events, byLine, casts, hits = ParseSvLog(name), {}, {}, 0
            for _, e in ipairs(events) do
                if e.kind == "C" and e.unit == "player" then casts[#casts + 1] = e end
                if e.kind == "U" then
                    hits = hits + 1
                    byLine[e.line] = e
                end
            end
            local tally, excluded, den, structural = {}, 0, 0, true
            for line, label in pairs(entry.direct.lines) do
                local hit = byLine[line]
                structural = structural and hit ~= nil and IsPlate(hit.unit)
                if label == "excluded" then excluded = excluded + 1
                elseif hit then
                    tally[label], den = (tally[label] or 0) + 1, den + 1
                    local near = false -- a CAST of the labeled spell 0-1.5 s before, and the hit is on the target plate
                    for _, c in ipairs(casts) do near = near or (c.id == label and hit.t - c.t >= 0 and hit.t - c.t <= 1.5) end
                    structural = structural and near and (o.chain == true or hit.unit == TargetAt(entry.targets, hit.t))
                end
            end
            local tallyOk = excluded == o.excluded
            for spell, n in pairs(o.spells) do tallyOk = tallyOk and tally[spell] == n end
            for spell in pairs(tally) do tallyOk = tallyOk and o.spells[spell] ~= nil end
            Check(name .. ": parse counts match the grep (" .. o.casts .. " casts, " .. o.hits .. " hits)", #casts == o.casts and hits == o.hits)
            Check(name .. ": direct tallies match the hand review and the denominator is > 0", tallyOk and den > 0)
            Check(name .. ": every direct line is a plate HIT, follows a CAST of its spell within 1.5 s and lands on the target plate (chain fixtures: any plate)", structural)
            if o.perCast then Check(name .. ": one target entry per CAST", #entry.targets == o.casts) end
        end
    end
    -- Priest logs (Forever) parse: reads with heal or taken counts, every HIT routed.
    for _, name in ipairs(PRIEST_LOGS) do
        local ok, events = pcall(ParseSvLog, name, name .. ".sv.lua")
        local hits, routed = 0, ok
        for _, event in ipairs(ok and events or {}) do
            if event.kind == "U" then
                hits = hits + 1
                routed = routed and event.route ~= nil
            end
        end
        Check(name .. ": parses, " .. hits .. " HITs, each with a route" .. (ok and "" or (": " .. tostring(events))),
            ok and hits > 0 and routed)
    end

    local fs = labels["shaman-fs-forget"]
    if fs then
        Check("timeline: TargetAt switches to nameplate5 at 23318.0 (inclusive) and never returns nil inside a log",
            TargetAt(fs.targets, 23276.305) == "nameplate10" and TargetAt(fs.targets, 23317.983) == "nameplate10"
            and TargetAt(fs.targets, 23318.0) == "nameplate5" and TargetAt(fs.targets, 23328.519) == "nameplate5"
            and TargetAt(labels["shaman-cl-instants"].targets, 22594.523) == "nameplate8"
            and TargetAt(labels["shaman-cl-clean"].targets, 21511.385) == "nameplate2")
        local events = ParseSvLog("shaman-fs-forget")
        local function At(line) for _, e in ipairs(events) do if e.line == line then return e end end end
        local spoiled, crit, first, cast, fresh = At(13), At(24), At(2), At(1), At(348)
        Check("parse: line 13 is the 23277.994 school-12 hit with its 2-entry read on line 12 and route AMBIGUOUS",
            spoiled and spoiled.kind == "U" and spoiled.t == 23277.994 and spoiled.unit == "nameplate10" and spoiled.event == "WOUND"
            and spoiled.school == 12 and spoiled.amount == 4864 and spoiled.flag == "" and spoiled.route == "AMBIGUOUS"
            and spoiled.read and spoiled.read.count == 2 and spoiled.read.meterType == 0 and spoiled.read.line == 12)
        Check("parse: line 24 is a CRITICAL 5725 hit with no read, line 2 a READ event (kind M), line 1 the player's 188443 cast",
            crit and crit.flag == "CRITICAL" and crit.amount == 5725 and crit.read == nil and crit.route == "HIDDEN"
            and first and first.kind == "M" and first.meterType == 0 and first.count == 1
            and cast and cast.kind == "C" and cast.unit == "player" and cast.id == 188443 and cast.t == 23276.305)
        Check("parse: line 348 (23317.173) has route meter and no READ hit of its own", fresh and fresh.read == nil and fresh.route == "meter" and fresh.school == 8)
    end

    -- An older log's gate lines (PENDING route, STAMP, RESOLVE) are skipped; the HIT keeps its place.
    local ok, events = pcall(ParseLog, "inline", {
        "10.000 HIT nameplate1 school=32 amount=500 flag= fps=60 target=true",
        "10.000   -> PENDING",
        "10.000 STAMP 0",
        "10.017 RESOLVE 10.000 damage -> unknown-solo",
    })
    local kinds = {}
    for _, event in ipairs(ok and events or {}) do kinds[#kinds + 1] = event.kind end
    Check("parse: an older log's PENDING / RESOLVE / STAMP lines are skipped" .. (ok and "" or (": " .. tostring(events))),
        ok and #kinds == 1 and kinds[1] == "U")
end

local function Try(name, fn) local ok, result = pcall(fn); Check(name, ok and result == true) end
local function Criterion12Checks()
    Try("criterion 12 harness: ScoreDirect counts right / wrong / hidden / '?', skips excluded, reports unlabeled drawn", function()
        local lines = { [1] = 5019, [2] = 5019, [3] = 5019, [4] = 5019, [5] = "excluded" }
        local function H(line, texture)
            return { event = { unit = "nameplate1", event = "WOUND", line = line }, shown = texture and { texture = texture } or nil }
        end
        local r = ScoreDirect(lines, { H(1, "tex:5019"), H(2, "tex:75"), H(3, nil), H(4, UNKNOWN_ICON), H(5, "tex:5019"), H(6, "tex:5019") })
        return r.den == 4 and r.right == 1 and r.wrong == 1 and r.hidden == 1 and r.unknown == 1 and r.unlabeledDrawn == 1
    end)
    Try("criterion 12 harness: a replay makes no reset (shaman-cl-clean)", function()
        local _, _, info = Replay("shaman-cl-clean", {})
        return info.resets == 0
    end)
    Try("criterion 12 harness: an empty store draws no spell icon (shaman-cl-clean)", function()
        local hits = Replay("shaman-cl-clean", { charDB = { casts = {}, castAliases = {} } })
        for _, hit in ipairs(hits) do if hit.shown and hit.shown.texture == "tex:188443" then return false end end
        return #hits == 33
    end)
end

-- The criterion 8 rule against the v5 replay (`info`, `fixtureLabels`): right and wrong learned entries.
local function LearnRuleChecks(info, fixtureLabels)
    local function Right(id, school, period, kind)
        return (LearnedRight(id, { school = school, period = period, kind = kind }, info, fixtureLabels))
    end
    Check("criterion 8 rule: Agony as cast (school 32, 2 s base, dot) is right", Right(980, 32, 2, "dot"))
    -- its ticks come every 0.47 s at haste 35.4 %, faster than the old table row (1 s base) says: base 0.47 * 1.354
    Check("criterion 8 rule: Drain Life with the base of its ticks (school 32, 0.64 s, channel) is right", Right(234153, 32, 0.64, "channel")
        and not Right(234153, 32, 1, "channel"))
    Check("criterion 8 rule: Agony with a wrong period, school or kind is wrong",
        not Right(980, 32, 3, "dot") and not Right(980, 36, 2, "dot") and not Right(980, 32, 2, "channel"))
    Check("criterion 8 rule: a cast with no labeled ticks (Shadow Bolt, Seed) or a spell never cast is wrong",
        not Right(686, 32, 2, "dot") and not Right(27243, 36, 2, "dot") and not Right(9999, 32, 2, "dot"))
end

local function ReplayFightsChecks()
    local ORACLE = { -- counted from each .sv.lua's TEACH lines (python over the debugLog, 2026-10-24)
        [SHADOW_DOTS] = { ends = "877,1098,1212", rows = "21,14,11", meter = "1008807,288870,110391",
            seen = "1049437,285831,108545", area = "crowded,clear,clear", absentIn = 1, runs = 3 },
        [PRIEST_DUMMY] = { ends = "114,246,870", rows = "8,9,19", meter = "86690,93844,858342",
            seen = "69092,92104,852051", area = "clear,clear,clear", absentIn = 3, runs = 4 },
    }
    local function Column(list, pick) local out = {} for i, item in ipairs(list) do out[i] = pick(item) end return table.concat(out, ",") end
    local function Sum(rows, field) local n = 0 for _, row in ipairs(rows) do n = n + row[field] end return n end
    for _, name in ipairs({ SHADOW_DOTS, PRIEST_DUMMY }) do
        local o, fights = ORACLE[name], ParseTeach(LoadLog(name .. ".sv.lua"))
        Check(name .. ": ParseTeach ends each fight at its TEACH clean line", Column(fights, function(f) return f.endLine end) == o.ends)
        Check(name .. ": ParseTeach keeps the meter>0 rows; their sum is the clean line's meter",
            Column(fights, function(f) return #f.rows end) == o.rows and Column(fights, function(f) return f.meter end) == o.meter
            and Column(fights, function(f) return Sum(f.rows, "totalAmount") end) == o.meter)
        Check(name .. ": ParseTeach reads seen and area of each clean line",
            Column(fights, function(f) return f.seen end) == o.seen and Column(fights, function(f) return f.area end) == o.area)
        local absent = true
        for _, row in ipairs(fights[o.absentIn].rows) do
            if row.spellID == 450983 or row.spellID == TRIGGER_ID then absent = false end
        end
        Check(name .. ": meter=0 rows (450983, " .. TRIGGER_ID .. ") are not meter rows; overkill is 0", absent and fights[o.absentIn].rows[1].overkillAmount == 0)
    end

    local parsed = ParseLog("t", { "1.000 HIT nameplate1 school=32 amount=10 flag= fps=60 target=true",
        "2.000 HIT nameplate2 school=32 amount=10 flag= fps=60 target=false", "3.000 HIT nameplate1 school=32 amount=10 flag= fps=60 queue=[]" })
    Check("parse: a HIT's target= flag is kept (true / false) and is nil when the log has none",
        parsed[1].target == true and parsed[2].target == false and parsed[3].target == nil)
    local targets = TargetsFromLog({
        { kind = "U", unit = "nameplate5", target = true, t = 1 }, { kind = "C", unit = "player", t = 2 },
        { kind = "U", unit = "nameplate4", target = false, t = 2.5 }, { kind = "U", unit = "nameplate4", target = true, t = 3 },
        { kind = "U", unit = "nameplate4", target = false, t = 4 } })
    Check("TargetsFromLog: first target holds from the start, a switch starts at the first cast after the old target's last flagged hit, a flagged-false hit on the target clears it",
        TargetAt(targets, 0) == "nameplate5" and TargetAt(targets, 1.9) == "nameplate5" and TargetAt(targets, 2) == "nameplate4"
        and TargetAt(targets, 3.5) == "nameplate4" and TargetAt(targets, 4.5) == nil)

    local function Mirrors(runs, name) -- each fight's read ran, saw the logged area and the logged meter total
        local fights = ParseTeach(LoadLog(name .. ".sv.lua"))
        for i, fight in ipairs(fights) do
            local last = runs[i] and runs[i].last
            if not (last and last.skip == nil and last.area == fight.area and Sum(last.rows, "meter") == fight.meter) then return false end
        end
        return true
    end
    local function Carried(runs) -- the seeded char DB (charDB = { carried = true }) survives into every fight's info.charDB
        for _, run in ipairs(runs) do if not (run.info.charDB and run.info.charDB.carried == true) then return false end end
        return #runs >= 2
    end
    local shadow, shadow0 = ReplayFights(SHADOW_DOTS, { haste = 25, charDB = { carried = true } }), ReplayFights(SHADOW_DOTS, { haste = 0 })
    Check(SHADOW_DOTS .. ": 3 runs, no tail", #shadow == ORACLE[SHADOW_DOTS].runs)
    Check(SHADOW_DOTS .. ": every read ran, area and meter total equal the log's", Mirrors(shadow, SHADOW_DOTS))
    Check(SHADOW_DOTS .. ": the char DB is carried from fight to fight", Carried(shadow))
    Check(SHADOW_DOTS .. ": opts.haste reaches the stub (25 and 0)", shadow[1].info.haste == 25 and shadow0[1].info.haste == 0)
    local priest = ReplayFights(PRIEST_DUMMY, { haste = 25, charDB = { carried = true } })
    Check(PRIEST_DUMMY .. ": 3 fights + a tail whose read skips with 'no sessions' and does not error",
        #priest == ORACLE[PRIEST_DUMMY].runs and priest[4].last and priest[4].last.skip == "no sessions" and #priest[4].hits >= 965)
    Check(PRIEST_DUMMY .. ": every read ran, area and meter total equal the log's", Mirrors(priest, PRIEST_DUMMY))
    Check(PRIEST_DUMMY .. ": the char DB is carried from fight to fight", Carried(priest))
end

-- Main -----------------------------------------------------------------------------

if OPTIONS["--haste"] then
    for _, name in ipairs({ "v4", "v5" }) do
        local haste, median, count = HasteEstimate(name)
        Out(string.format("%s: haste %.1f %% (median %.3f s over %d gaps)", name, haste, median, count))
    end
    return
end

local report = {}
Out("Combat Text Icons offline harness")
Out("Replays (plate WOUND hits, by ground-truth label):")
local v4Runs = {}
for _, variant in ipairs(labels.v4.variants) do
    local hits, fixtureLabels, info = Replay("v4", { variant = variant })
    v4Runs[#v4Runs + 1] = Score("v4", hits, fixtureLabels, "v4 (" .. variant.name .. ")", report)
    v4Runs[#v4Runs].info = info
    PrintRun(v4Runs[#v4Runs])
end
local hitsV5, labelsV5, infoV5 = Replay("v5", {})
local v5 = Score("v5", hitsV5, labelsV5, "v5 (phases 2-7)", report)
v5.info = infoV5
PrintRun(v5)

-- The fixtures' haste is fitted to the tick gaps (~36 %), but UnitSpellHaste
-- read 7.7 % in game on 2026-10-21: DoTs tick faster than it explains, and the
-- tracker must learn that rhythm. Replay everything again at the in-game value.
local IN_GAME_HASTE = 7.7
for _, variant in ipairs(labels.v4.variants) do
    local hits, fixtureLabels, info = Replay("v4", { variant = variant, haste = IN_GAME_HASTE })
    local run = Score("v4", hits, fixtureLabels, "v4 (" .. variant.name .. ", in-game haste)", report)
    run.info = info
    PrintRun(run)
end
local hitsReal, labelsReal, infoReal = Replay("v5", { haste = IN_GAME_HASTE })
local v5Real = Score("v5", hitsReal, labelsReal, "v5 (phases 2-7, in-game haste)", report)
v5Real.info = infoReal
PrintRun(v5Real)

-- The crowd steps (criterion 13) run back to back, before any other Replay or Boot: every Boot rebuilds the
-- global S, and S.timers must be the one the clear replay's fight queued its read on.
-- 1. v5 with three strangers at each own stamp, area clear: the unexplained set U (own plate hits that took the
--    '?' route or the crowded route) must all draw '?'.
local clearHits, _, clearInfo = Replay("v5", { minPhase = 2, crowd = true })
-- 2. The read of that fight: the meter stand-in is the own hits only (in v5 solo every non-noise plate hit is the
--    player's), so the strangers' hits make the seen total exceed it and the area turns crowded.
local ownTotal, seenTotal = 0, 0
for _, event in ipairs(clearInfo.events) do
    if event.kind == "U" and IsPlate(event.unit) and event.event == "WOUND" then
        seenTotal = seenTotal + event.amount
        if not event.noise then ownTotal = ownTotal + event.amount end
    end
end
local ownRow = { spellID = 1, totalAmount = ownTotal }
local ownSession = { sessionID = 1, name = "Current", durationSeconds = 60, rows = { ownRow } }
S.sessions = { ownSession }
for _, timer in ipairs(S.timers) do timer.fn() end
-- 3. The next fight starts from that state: no hit takes the unexplained '?' route.
local crowdHits = Replay("v5", { minPhase = 2, crowd = true, area = clearInfo.teacher.area })

-- Noise runs: the group run (criterion 11) has the same-frame stranger at each own read; the solo run
-- (criterion 5) only the random 1/s slots, with the area crowded.
local noiseHits, _, noiseInfo = Replay("v5", { noise = 1, minPhase = 2, group = true })
local soloHits = Replay("v5", { noise = 1, minPhase = 2, group = false, noSameFrame = true, area = "crowded" })
local noise = { total = 0, shown = 0, via = {} }
local realShown, realTotal, soloUnknown = 0, 0, 0
for _, hit in ipairs(soloHits) do
    if hit.route == ROUTE_UNKNOWN then soloUnknown = soloUnknown + 1 end
    if hit.noise then
        noise.total = noise.total + 1
        if hit.shown then
            noise.shown = noise.shown + 1
            noise.via[hit.via] = (noise.via[hit.via] or 0) + 1
        end
    elseif IsPlate(hit.event.unit) and hit.event.event == "WOUND" then
        local label = LabelOf(labelsV5, hit.event)
        if label ~= "hidden" then
            realTotal = realTotal + 1
            if Verdict(label, hit) == "correct" then realShown = realShown + 1 end
        end
    end
end
local noiseScore = Score("v5+noise", noiseHits, labelsV5, "v5 + noise (seed 1, in group)", {})
noiseScore.info = noiseInfo
local soloScore = Score("v5+noise solo", soloHits, labelsV5, "v5 + noise (seed 1, solo)", {})

-- Shaman recordings (/cti debug logs), each from an empty store. Scored apart from `report`,
-- so criteria 1-8 keep their inputs.
Out("")
Out("Shaman recordings (empty store, target timelines from labels.lua):")
local shamanReport, shamanRuns = {}, {}
for _, name in ipairs(SV_NAMES) do
    local hits, fixtureLabels, info = Replay(name, {})
    local run = Score(name, hits, fixtureLabels, name, shamanReport)
    run.info, run.hits, run.showVotes = info, hits, true
    shamanRuns[name] = run
    PrintRun(run)
end

RunChecks()
local harnessOk, harnessErr = pcall(HarnessChecks)
if not harnessOk then Check("HarnessChecks ran without error: " .. tostring(harnessErr), false) end
local c12Ok, c12Err = pcall(Criterion12Checks)
if not c12Ok then Check("Criterion12Checks ran without error: " .. tostring(c12Err), false) end
local rfOk, rfErr = pcall(ReplayFightsChecks)
if not rfOk then Check("ReplayFightsChecks ran without error: " .. tostring(rfErr), false) end
local ruleOk, ruleErr = pcall(LearnRuleChecks, infoV5, labelsV5)
if not ruleOk then Check("LearnRuleChecks ran without error: " .. tostring(ruleErr), false) end

-- Criteria -------------------------------------------------------------------------

local results = {}
local function Criterion(number, text, pass, detail)
    results[#results + 1] = { number = number, text = text, pass = pass, detail = detail }
end
-- A measured criterion with no threshold yet: printed as NOTE, never fails the run.
local function Measured(number, text, detail)
    results[#results + 1] = { number = number, text = text, pass = true, note = true, detail = detail }
end

local wrongTotal, wrongParts = 0, {}
for _, run in ipairs(report) do
    wrongTotal = wrongTotal + #run.wrong
    wrongParts[#wrongParts + 1] = run.name .. " " .. #run.wrong
end
Criterion(1, "wrong attributions = 0 (v4 both UA plates, v5 phases 2-7)", wrongTotal == 0, table.concat(wrongParts, ", "))

local school106, parts106 = 0, {}
for _, run in ipairs(report) do
    school106 = school106 + run.school106
    parts106[#parts106 + 1] = run.name .. " " .. run.school106
end
Criterion(2, "school-106 hits shown with a wrong icon (not '?') = 0", school106 == 0,
    table.concat(parts106, ", "))

-- 3 and 7: the shipped table is empty, so Agony and Wither show only once learned. Thresholds wait for the
-- user (2026-10-24: "measure, then set"); until then the numbers print and nothing is asserted.
local AGONY_PHASES = { [3] = true, [4] = true, [7] = true }
local WITHER_PHASES = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }
local function LearningDetail(run)
    return LearningLine(run, "Agony (phases 3,4,7)", "980", { [980] = true }, AGONY_PHASES) .. "\n     "
        .. LearningLine(run, "Wither (phases 2-7)", "445474", { [445468] = true, [445474] = true }, WITHER_PHASES)
end
Measured(3, "v5 learning only: Agony and Wither, when learned, wrong, own icon before / after (thresholds pending user approval)",
    LearningDetail(v5))

local petPass, petParts = true, {}
for _, run in ipairs(v4Runs) do
    local pet = run.byLabel.pet or NewTally()
    petPass = petPass and pet.wrong == 0
    petParts[#petParts + 1] = string.format("%s wrong %d, '?' on pet hits %d/%d (NOTE: drawn while the area is clear; pet melee is unexplained own damage)",
        run.name, pet.wrong, pet.unknown, pet.total)
end
Criterion(4, "v4 pet melee never wrong (spell icon on a pet hit = 0)", petPass, table.concat(petParts, ", "))

local noiseShare = noise.total > 0 and noise.shown / noise.total or 0
local noiseVia = {}
for via, count in pairs(noise.via) do noiseVia[#noiseVia + 1] = via .. "=" .. count end
table.sort(noiseVia)
Criterion(5, "no '?' while crowded, solo: unexplained-route '?' = 0 (v5 + noise, area crowded; tracker-unknown '?' allowed, D3)",
    soloUnknown == 0,
    string.format("unexplained-route '?' on own and noise hits %d; noise drawn by any route %d/%d = %.1f %% (%s); real-hit recall under noise %d/%d = %.1f %%; real wrong under noise %d",
        soloUnknown, noise.shown, noise.total, noiseShare * 100, table.concat(noiseVia, " "), realShown, realTotal,
        realTotal > 0 and realShown / realTotal * 100 or 0, #soloScore.wrong))

Measured(7, "v5 at in-game haste, learning only: Agony and Wither, when learned, wrong, own icon before / after (thresholds pending user approval)",
    LearningDetail(v5Real))

-- 8: every learned entry passes LearnedRight; with an empty table every player cast is unknown and needs a castPlate.
local learnParts, learnPass = {}, true
local learnRuns = { table.unpack(report) }
learnRuns[#learnRuns + 1] = { name = "v5 + noise (seed 1)", info = noiseInfo, labels = labelsV5 }
for _, run in ipairs(learnRuns) do
    local wrongParts = {}
    for id, entry in pairs(run.info.learned) do
        local ok, reason = LearnedRight(id, entry, run.info, run.labels)
        if not ok then wrongParts[#wrongParts + 1] = id .. " " .. reason end
    end
    table.sort(wrongParts)
    learnPass = learnPass and #wrongParts == 0 and #run.info.uncovered == 0
    learnParts[#learnParts + 1] = string.format("%s: learned %s, wrong %d%s, uncovered casts %d", run.name, Describe(run.info.learned),
        #wrongParts, #wrongParts > 0 and (" (" .. table.concat(wrongParts, ", ") .. ")") or "", #run.info.uncovered)
end
Criterion(8, "nothing wrong learned (each learned spell was cast and fits its labeled ticks), and every unknown cast has a castPlate",
    learnPass, table.concat(learnParts, "; "))

-- 9: shaman-fs-forget (spec §Testing; by-hand values in §Learn "Check by hand")
local fs = shamanRuns["shaman-fs-forget"]
local function DotSig(id)                       -- the school-12 dot sig of a spell
    for _, sig in ipairs(fs.info.votes[id] and fs.info.votes[id].sigs or {}) do
        if sig.kind == "dot" and sig.school == 12 then return sig end
    end
end
local function Votes(id)                        -- the votes on the school-12 dot sig of a spell
    local sig = DotSig(id)
    return sig and sig.votes or 0
end
local function Near(value, expected, tolerance) return value ~= nil and math.abs(value - expected) <= tolerance end
local flame, twin = DotSig(188389), DotSig(470411)
local spoiledHit
for _, hit in ipairs(fs.hits) do
    if hit.event.t == 23277.994 and hit.event.unit == "nameplate10" and hit.event.school == 12 then spoiledHit = hit end
end
local questionMark = spoiledHit ~= nil and spoiledHit.shown ~= nil and spoiledHit.shown.texture == UNKNOWN_ICON
local excluded = fs.byLabel.excluded
Criterion(9, "shaman-fs-forget: 188389 and 470411 hold 2 votes (expected ~0.19), 188443 holds 1 school-12 vote, nothing learned, wrong = 0, the spoiled hit shows ?",
    flame ~= nil and flame.votes == 2 and Near(flame.expected, 0.1935, 0.005)
    and twin ~= nil and twin.votes == 2 and Near(twin.expected, 0.1935, 0.005)
    and Votes(188443) == 1 and next(fs.info.learned) == nil
    and #fs.wrong == 0 and excluded ~= nil and excluded.total == 3 and questionMark,
    string.format("votes 188389 %s, 470411 %s, 188443 %d; learned %s; wrong %d; excluded %d; '?' at 23277.994: %s",
        flame and string.format("%d @ %.3f", flame.votes, flame.expected) or "none",
        twin and string.format("%d @ %.3f", twin.votes, twin.expected) or "none", Votes(188443),
        Describe(fs.info.learned), #fs.wrong, excluded and excluded.total or 0, tostring(questionMark)))

-- 10: shaman-cl-instants and shaman-cl-clean
local tenParts, tenPass = {}, true
for _, name in ipairs({ "shaman-cl-instants", "shaman-cl-clean" }) do
    local run, scored = shamanRuns[name], 0
    for _, tally in pairs(run.byLabel) do scored = scored + tally.total end
    local timeline = #labels[name].targets > 0 and TargetAt(labels[name].targets, run.hits[1].event.t) ~= nil
    local ok = #run.wrong == 0 and run.info.learned[188443] == nil and run.info.learned[188196] == nil
        and timeline and scored > 0 and scored == #run.hits
    tenPass = tenPass and ok
    tenParts[#tenParts + 1] = string.format("%s: wrong %d, scored %d/%d, learned %s, timeline entries %d",
        name, #run.wrong, scored, #run.hits, Describe(run.info.learned), #labels[name].targets)
end
Criterion(10, "shaman-cl-instants and shaman-cl-clean: wrong = 0, 188443 and 188196 not learned, target timeline not empty",
    tenPass, table.concat(tenParts, "; "))

-- 11: Verdict scores "?" under a hidden label as unknown, not wrong, so no other criterion sees it.
-- Solo, a hit nothing identifies draws "?" by design: those replays only report their count.
local hiddenUnknown, hiddenParts, soloParts = 0, {}, {}
local everyRun = { table.unpack(report) }
everyRun[#everyRun + 1] = noiseScore
for _, name in ipairs(SV_NAMES) do everyRun[#everyRun + 1] = shamanRuns[name] end
for _, run in ipairs(everyRun) do
    if run.info.group then
        hiddenUnknown = hiddenUnknown + run.hiddenUnknown
        hiddenParts[#hiddenParts + 1] = run.name .. " " .. run.hiddenUnknown
    else
        soloParts[#soloParts + 1] = run.name .. " " .. run.hiddenUnknown
    end
end
Criterion(11, "'?' shown on hidden-labeled hits (other players' or unattributable) = 0 in every group replay",
    hiddenUnknown == 0, table.concat(hiddenParts, ", "))
notes[#notes + 1] = "solo replays, '?' on hidden-labeled hits (expected solo, not asserted): " .. table.concat(soloParts, ", ")

-- 12: single-mode two-pass replay. Pass 1 learns: its fight ends with the Teacher's read queued, which
-- fires against a session built from the labeled hits (one player row per labeled spell). Pass 2 (that
-- store carried over) draws direct hits from the casts alone. Bars: priest fixtures right >= 80 %, wrong
-- <= 2 %, per fixture and in total over the priest fixtures; every fixture wrong <= 2 %; shaman-cl right is
-- printed, not asserted (C6). Both passes make no reset.
local function Percent(n, d) return d > 0 and n / d * 100 or 0 end
local function SortedKeys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end
-- The meter session of one fixture: a player source row per labeled spell, its total the labeled hits' amounts.
local function LabeledSession(lines, info)
    local totals = {}
    for _, event in ipairs(info.events) do
        local label = event.kind == "U" and not event.noise and IsPlate(event.unit) and event.event == "WOUND" and lines[event.line]
        if type(label) == "number" then totals[label] = (totals[label] or 0) + event.amount end
    end
    local rows = {}
    for _, id in ipairs(SortedKeys(totals)) do rows[#rows + 1] = { spellID = id, totalAmount = totals[id] } end
    return { sessionID = 1, name = "Current", durationSeconds = 60, rows = rows }
end
local c12 = { pass = true, heads = {}, lines = {}, missed = {} }
local c12Total = { den = 0, right = 0, wrong = 0 }
for _, name in ipairs(DIRECT_NAMES) do
    local lines, priest = labels[name].direct.lines, name:find("^priest") ~= nil
    local _, _, one = Replay(name, { noSeen = true })
    S.sessions = { LabeledSession(lines, one) }
    for _, timer in ipairs(S.timers) do timer.fn() end
    one.casts, one.castAliases = DeepCopy(CombatTextIconsCharDB.casts), DeepCopy(CombatTextIconsCharDB.castAliases)
    local hits, _, two = Replay(name, { charDB = { casts = one.casts, castAliases = one.castAliases or {} } })
    local score = ScoreDirect(lines, hits)
    if priest then
        c12Total.den, c12Total.right, c12Total.wrong = c12Total.den + score.den, c12Total.right + score.right, c12Total.wrong + score.wrong
    end
    c12.pass = c12.pass and score.den > 0 and score.wrong / score.den <= 0.02 and one.resets == 0 and two.resets == 0
    if priest then c12.pass = c12.pass and score.right / score.den >= 0.8 end
    c12.heads[#c12.heads + 1] = string.format("%s %d/%d w%d", name, score.right, score.den, score.wrong)
    local learned = {}
    for _, id in ipairs(SortedKeys(one.casts)) do if one.casts[id].learned then learned[#learned + 1] = tostring(id) end end
    c12.lines[#c12.lines + 1] = string.format(
        "  %s: right %d/%d = %.1f %%%s, wrong %d/%d = %.1f %%, hidden %d, '?' %d, unlabeled drawn %d, learned %s, resets %d / %d",
        name, score.right, score.den, Percent(score.right, score.den), priest and "" or " (NOTE, until B/C)",
        score.wrong, score.den, Percent(score.wrong, score.den), score.hidden, score.unknown, score.unlabeledDrawn,
        #learned > 0 and table.concat(learned, " ") or "none", one.resets, two.resets)
    c12.missed[name] = score.missed
end
c12.pass = c12.pass and c12Total.den > 0 and c12Total.right / c12Total.den >= 0.8 and c12Total.wrong / c12Total.den <= 0.02
local c12Detail = { table.concat(c12.heads, " | ") .. string.format(" | priest total %d/%d w%d", c12Total.right, c12Total.den, c12Total.wrong) }
for _, line in ipairs(c12.lines) do c12Detail[#c12Detail + 1] = line end
Criterion(12, "single-mode two-pass replay: the Teacher learns pass 1, pass 2 draws direct hits from casts alone; priest right >= 80 % (per fixture and priest total), all wrong <= 2 % (shaman-cl right NOTE until B/C) (pass 1: crowd check off, the labeled session is not the whole meter)",
    c12.pass, table.concat(c12Detail, "\n     "))

-- 13: the crowd (steps 1-3 ran above, before any other Replay). While the area is clear, every own plate hit that
-- reached the unexplained set U draws '?' (the strangers' hits that draw are the accepted leak, spec 2): printed,
-- not asserted. Then the read of that fight turns the area crowded, and the next fight draws no unexplained '?'.
local unexplained, unexplainedDrawn, strangersDrawn = 0, 0, 0
for _, hit in ipairs(clearHits) do
    local ownUnexplained = not hit.noise and IsPlate(hit.event.unit) and hit.event.event == "WOUND"
        and (hit.route == ROUTE_UNKNOWN or hit.route == ROUTE_CROWDED)
    if hit.noise then
        if hit.route == ROUTE_UNKNOWN then strangersDrawn = strangersDrawn + 1 end
    elseif ownUnexplained then
        unexplained = unexplained + 1
        if hit.route == ROUTE_UNKNOWN and hit.shown and hit.shown.texture == UNKNOWN_ICON then
            unexplainedDrawn = unexplainedDrawn + 1
        end
    end
end
local readLast, readArea = clearInfo.teacher.last, clearInfo.teacher.area
local crowdedUnknown = 0
for _, hit in ipairs(crowdHits) do
    if hit.route == ROUTE_UNKNOWN then crowdedUnknown = crowdedUnknown + 1 end
end
Criterion(13, "crowd: while clear 100 % of own unexplained solo hits draw '?'; the read of that crowded fight turns crowded; then 0 '?' on the unexplained route",
    unexplained > 0 and unexplainedDrawn == unexplained and readLast ~= nil and readLast.area == "crowded"
        and readArea == "crowded" and crowdedUnknown == 0,
    string.format("while clear: own unexplained %d, drawn '?' %d = %.1f %% (strangers drawn, accepted leak: %d); read: seen %d, meter %d, strangers %d -> %s; next fight: '?' on the unexplained route %d",
        unexplained, unexplainedDrawn, Percent(unexplainedDrawn, unexplained), strangersDrawn, seenTotal, ownTotal,
        seenTotal - ownTotal, readLast and readLast.area or "no read", crowdedUnknown))

-- Plan criterion 3 (spec 5.3): per-fight, meter-on replays of the two 2026-10-24 fixtures, each at haste 25 and 0.
local DOT_FIXTURES = { SHADOW_DOTS, PRIEST_DUMMY }
local DOT_HASTES = { 25, 0 }

local function EachRow(runs, fn)
    for fight, run in ipairs(runs) do
        for _, entry in ipairs(run.last and run.last.rows or {}) do fn(fight, entry) end
    end
end

-- Wrong icons judged by the meter's own rows: `over`, or `unpaired` with a tally, except a spell the
-- safety net learned and then unlearned within 2 drawn fights (<= 2 such fights, ever learned, not learned at the end;
-- a never-learned unpaired spell is a wrong icon).
local function MeterWrong(runs, learnedEnd)
    local wrong, unpaired, everLearned = {}, {}, {}
    for _, run in ipairs(runs) do
        for _, call in ipairs(run.info.learnLog) do everLearned[call.id] = true end
    end
    EachRow(runs, function(fight, entry)
        if entry.verdict == "over" then
            wrong[#wrong + 1] = string.format("F%d %d over (%d vs %d)", fight, entry.spellID, entry.tally, entry.meter)
        elseif entry.verdict == "unpaired" and entry.tally > 0 then
            unpaired[entry.spellID] = (unpaired[entry.spellID] or 0) + 1
        end
    end)
    for id, count in pairs(unpaired) do
        if count > 2 or learnedEnd[id] or not everLearned[id] then
            wrong[#wrong + 1] = string.format("%d unpaired in %d drawn fights, learned at end: %s", id, count, tostring(learnedEnd[id] ~= nil))
        end
    end
    return wrong
end

-- End state: TRIGGER_ID not learned; no dot/channel learned whose own row (meterID == spellID, meter > 0)
-- is absent from every fight in which it was drawn.
local function EndStateBad(runs, learnedEnd)
    local drawn, own, bad = {}, {}, {}
    EachRow(runs, function(_, entry)
        if entry.tally > 0 then
            drawn[entry.spellID] = true
            if entry.meterID == entry.spellID and entry.meter > 0 then own[entry.spellID] = true end
        end
    end)
    for id, entry in pairs(learnedEnd) do
        local channelOrDot = entry.kind == "dot" or entry.kind == "channel"
        if id == TRIGGER_ID or (channelOrDot and drawn[id] and not own[id]) then bad[#bad + 1] = id end
    end
    table.sort(bad)
    return bad
end

local function HasBirth(births, period)
    for _, birth in ipairs(births) do
        if birth.school == 32 and math.abs(birth.period - period) <= 0.15 then return true end
    end
    return false
end

local dotWrong, dotBad, dotDetector, dotParts, detParts = 0, 0, true, {}, {}
local dotOk, dotErr = pcall(function()
    for _, name in ipairs(DOT_FIXTURES) do
        for _, haste in ipairs(DOT_HASTES) do
            local runs = ReplayFights(name, { haste = haste })
            assert(#runs >= 3, name .. " h" .. haste .. ": the replay ran fewer than 3 fights") -- kills the 'ignores haste 0' mutant: both haste runs must really run
            local learnedEnd = runs[#runs].info.charDB.learned
            local wrong, bad = MeterWrong(runs, learnedEnd), EndStateBad(runs, learnedEnd)
            dotWrong, dotBad = dotWrong + #wrong, dotBad + #bad
            dotParts[#dotParts + 1] = string.format("%s h%d: wrong %d%s, end-state bad [%s], learned [%s]", name, haste, #wrong,
                #wrong > 0 and (" (" .. table.concat(wrong, "; ") .. ")") or "", table.concat(bad, ","), Describe(learnedEnd))
            if name == PRIEST_DUMMY then
                local births = runs[2].info.births
                local swp, vt = HasBirth(births, 1.57), HasBirth(births, 2.70)
                dotDetector = dotDetector and swp and vt
                detParts[#detParts + 1] = string.format("h%d: SW:P 1.57 %s, VT 2.70 %s, %d births in F2", haste, tostring(swp), tostring(vt), #births)
            end
        end
    end
end)
if not dotOk then Check("dot-detector criteria ran without error: " .. tostring(dotErr), false) end
Criterion(14, "new fixtures at haste 25 and 0: meter-consistent icons 0 wrong; end state: " .. TRIGGER_ID .. " not learned, no dot/channel learned without its own row",
    dotOk and dotWrong == 0 and dotBad == 0, table.concat(dotParts, "\n     "))
Criterion(15, "priest-dummy F2 (haste 25 and 0): streams born at 1.57 +- 0.15 s and at 2.70 +- 0.15 s (school 32, not named)",
    dotOk and dotDetector, table.concat(detParts, "\n     "))

do -- Plan criteria 3, 4, 6 (spec 5.3, 5.4, 5.6): chained learn, draw check, route lines. Oracles: the table above.
    local PROC_IDS = { 1287663, 1286716 }
    local PROC_ROWS = { -- spec 1: chain index -> meter row; every other fight has no row
        [1287663] = { [1] = 11820, [2] = 2548, [3] = 1404, [6] = 10403 },
        [1286716] = { [1] = 28557, [2] = 34910, [3] = 5551, [6] = 46306 },
    }
    local function FightName(index) return index <= 3 and ("shadow F" .. index) or ("priest F" .. (index - 3)) end

    local function RowVerdict(run, id) -- verdict, tally, meter of id's row in this run's read (nil: no entry)
        for _, entry in ipairs(run.last and run.last.rows or {}) do
            if entry.spellID == id then return entry.verdict, entry.tally, entry.meter end
        end
    end

    -- shadow-dots, then priest-dummy seeded with its end DB (haste h both). chain = the 6 fight runs;
    -- endDB = the DB after the priest tail (the same DB as after F3: the tail's read skips).
    local function ProcChain(haste)
        local shadow = ReplayFights(SHADOW_DOTS, { haste = haste })
        assert(#shadow == 3, "shadow-dots ran " .. #shadow .. " fights")
        local priest = ReplayFights(PRIEST_DUMMY, { haste = haste, charDB = shadow[#shadow].info.charDB })
        assert(#priest >= 3, "priest-dummy ran " .. #priest .. " fights")
        local chain = { shadow[1], shadow[2], shadow[3], priest[1], priest[2], priest[3] }
        return chain, priest[#priest].info.charDB
    end

    -- id -> first chain index whose end-of-fight char DB holds it learned
    local function ProcLearnedAt(chain)
        local at = {}
        for index, run in ipairs(chain) do
            for id, entry in pairs(run.info.charDB.procs or {}) do
                if entry.learned == true and not at[id] then at[id] = index end
            end
        end
        return at
    end

    local learnOk, drawOk, routeOk, learnParts, drawParts, routeParts = true, true, true, {}, {}, {}
    local procOk, procErr = pcall(function()
        for _, haste in ipairs(DOT_HASTES) do
            local chain, endDB = ProcChain(haste)
            local at, others = ProcLearnedAt(chain), {}
            for _, id in ipairs(PROC_IDS) do
                learnOk = learnOk and at[id] == 6 -- after priest F3, not before
                for fight, run in ipairs(chain) do -- the replay saw the spec's meter rows (oracle sanity)
                    local _, _, meter = RowVerdict(run, id)
                    learnOk = learnOk and (meter or 0) == (PROC_ROWS[id][fight] or 0)
                end
            end
            for id, index in pairs(at) do
                local entry = endDB.procs[id] or {} -- dropped later: band shown as nil
                if id ~= PROC_IDS[1] and id ~= PROC_IDS[2] then
                    others[#others + 1] = string.format("%d@%s (school %s, band %s-%s)", id, FightName(index), tostring(entry.school), tostring(entry.lo), tostring(entry.hi))
                end
            end
            table.sort(others)
            learnParts[#learnParts + 1] = string.format("h%d: %d@%s, %d@%s; other learns [%s]", haste, PROC_IDS[1],
                at[PROC_IDS[1]] and FightName(at[PROC_IDS[1]]) or "never", PROC_IDS[2], at[PROC_IDS[2]] and FightName(at[PROC_IDS[2]]) or "never", table.concat(others, "; "))

            -- criterion 4: the whole priest-dummy again, seeded with the criterion-3 DB of the same haste
            local again = ReplayFights(PRIEST_DUMMY, { haste = haste, charDB = endDB })
            assert(#again >= 3, "draw replay ran " .. #again .. " fights")
            local procIds = {} -- every ID learned as a proc in the seed or in any run's end DB
            for id, entry in pairs(endDB.procs or {}) do if entry.learned then procIds[id] = true end end
            for _, run in ipairs(again) do
                for id, entry in pairs(run.info.charDB.procs or {}) do if entry.learned then procIds[id] = true end end
            end
            local verdicts, routes = {}, {}
            for _, id in ipairs(PROC_IDS) do
                local verdict, tally = RowVerdict(again[3], id)
                drawOk = drawOk and verdict == "agree" and (tally or 0) > 0
                verdicts[#verdicts + 1] = string.format("%d F3 %s tally %s", id, tostring(verdict), tostring(tally))
                local count = 0
                for _, hit in ipairs(again[3].hits) do if hit.route == "  -> proc " .. id then count = count + 1 end end
                routeOk = routeOk and count > 0
                routes[#routes + 1] = string.format("%d: %d proc routes in F3", id, count)
            end
            local procWrong, otherWrong = {}, {}
            for _, text in ipairs(MeterWrong(again, again[#again].info.charDB.learned)) do
                local rowID = tonumber(text:match("^F%d+ (%d+) over") or text:match("^(%d+) unpaired"))
                local mine = rowID ~= nil and procIds[rowID] == true -- the line's own ID (MeterWrong formats, run.lua:1612, :1619), never a substring
                local list = mine and procWrong or otherWrong
                list[#list + 1] = text
            end
            drawOk = drawOk and #procWrong == 0
            drawParts[#drawParts + 1] = string.format("h%d: %s; proc wrong %d%s; other wrong, not judged here [%s]", haste, table.concat(verdicts, ", "),
                #procWrong, #procWrong > 0 and (" (" .. table.concat(procWrong, "; ") .. ")") or "", table.concat(otherWrong, "; "))
            routeParts[#routeParts + 1] = string.format("h%d: %s", haste, table.concat(routes, ", "))
        end
    end)
    if not procOk then Check("castless-procs criteria ran without error: " .. tostring(procErr), false) end
    Criterion(16, "chained replay shadow-dots then priest-dummy (haste 25 and 0): 1287663 and 1286716 learned by Procs after priest F3, not before; every other learn listed",
        procOk and learnOk, table.concat(learnParts, "\n     "))
    Criterion(17, "priest-dummy replayed again, seeded with that DB (same haste): both procs draw with verdict agree in F3, no proc ID in MeterWrong",
        procOk and drawOk, table.concat(drawParts, "\n     "))
    Criterion(18, "the draw replay's debug routes hold '-> proc <id>' lines for both procs in F3 (haste 25 and 0)",
        procOk and routeOk, table.concat(routeParts, "\n     "))
end

do -- Rev 5 (in-game 2026-10-25): the forget5 run made 4 wrong aliases; only 413231 -> Tentacle Slam may stay
    local ALLOWED = { [413231] = TRIGGER_ID }
    local aliasOk, parts = true, {}
    local ok, err = pcall(function()
        for _, haste in ipairs(DOT_HASTES) do
            local runs = ReplayFights(FORGET5, { haste = haste })
            assert(#runs >= 4, "forget5 ran " .. #runs .. " fights")
            local db, aliases, procs, prints = runs[#runs].info.charDB, {}, {}, {}
            for rowID, castID in pairs(db.castAliases or {}) do
                aliasOk = aliasOk and ALLOWED[rowID] == castID
                aliases[#aliases + 1] = rowID .. ">" .. castID
            end
            for id, entry in pairs(db.procs or {}) do
                procs[#procs + 1] = string.format("%d s%d %d-%d %s", id, entry.school, entry.lo, entry.hi,
                    entry.learned and "learned" or ("streak " .. entry.streak))
            end
            for id, entry in pairs(db.casts or {}) do
                if entry.learned then prints[#prints + 1] = id .. " s" .. tostring(entry.school) end
            end
            table.sort(aliases); table.sort(procs); table.sort(prints)
            parts[#parts + 1] = string.format("h%d: %d fights; aliases [%s]; procs [%s]; fingerprints [%s]; ticks [%s]", haste, #runs,
                table.concat(aliases, ", "), table.concat(procs, "; "), table.concat(prints, ", "), Describe(db.learned))
        end
    end)
    if not ok then Check("forget5 criterion ran without error: " .. tostring(err), false) end
    Criterion(19, "forget5 replay (haste 25 and 0): no cast alias except 413231 -> " .. TRIGGER_ID .. " (Rev 5)",
        ok and aliasOk, table.concat(parts, "\n     "))
end

-- Last replay done: no replay of the run reset the meter.
Check("every replay: no meter reset", allResets == 0)
Criterion(6, "unit checks pass; no replay resets the meter", #checks.failed == 0,
    string.format("%d passed, %d failed%s; meter resets in all replays %d", checks.passed, #checks.failed,
        #checks.failed > 0 and (": " .. table.concat(checks.failed, "; ")) or "", allResets))

table.sort(results, function(a, b) return a.number < b.number end)
Out("")
Out("Acceptance criteria (offline):")
local allPass = true
for _, result in ipairs(results) do
    allPass = allPass and result.pass
    Out(string.format("  %d. %s  %s", result.number, result.note and "NOTE" or (result.pass and "PASS" or "FAIL"), result.text))
    Out("     " .. result.detail)
end
for _, note in ipairs(notes) do Out("  note: " .. note) end
if OPTIONS["--wrong"] then
    for _, line in ipairs(noiseScore.wrong) do Out("  NOISE-RUN WRONG " .. line) end
    for _, name in ipairs(DIRECT_NAMES) do
        for _, miss in ipairs(c12.missed[name]) do
            Out(string.format("  C12 %s %s line %d t=%.3f %s school %d amount %d: label %s, shown %s, recorded route %s",
                string.upper(miss.kind), name, miss.line, miss.t, miss.unit, miss.school, miss.amount, tostring(miss.label),
                tostring(miss.shown), tostring(miss.route or "-")))
        end
    end
end
Out("")
Out(allPass and "ALL PASS" or "FAILED")
os.exit(allPass and 0 or 1)
