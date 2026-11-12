-- Replay gate for the Owner path over Combat Log lines: each HIT, HEAL, CLOG and CAST line of a Forever party capture goes
-- through Core's own handlers and Owner.Line, so the matcher, the held hits and their release run as in game. Called by
-- tests/checks.lua with the same T table. The Replay is private to this file.

return function(T)
    local Check = T.Check
    -- The cast ids of the captures that are heals or buffs (Prayer of Healing, Heal, Renew, Inner Focus, Hearthstone).
    -- They are inferred from the ids; a wrong one only changes which cast route runs.
    local HELPFUL = { 596, 6064, 6077, 14751, 8690 }
    local SEED_SCHOOLS = { [589] = 32, [585] = 2 }
    local GLOBALS = { "IsInRaid", "C_CombatLog", "Blizzard_CombatLog_Filters", "COMBATLOG" }

    local function Clean()
        for _, name in ipairs(GLOBALS) do _G[name] = nil end
    end

    -- Sets the Combat Log globals Owner reads: a party, the lines on, "My actions" picked, the Combat Log tab hidden.
    local function SetCombatLog()
        local on = false
        IsInRaid = function() return false end
        C_CombatLog = {
            AreFilteredEventsEnabled = function() return on end,
            SetFilteredEventsEnabled = function(value) on = value end,
        }
        Blizzard_CombatLog_Filters = { currentFilter = 1, filters = { { name = "My actions" } } }
        COMBATLOG = { IsShown = function() return false end }
    end

    -- Feeds `lines` to a booted Forever party and returns what happened. R.owned lists each HitRoute.Route call
    -- { unit, now (the hit's stamp), releasedAt (S.now at the call), clock (ns.Now() at the call) }, R.hits the HIT lines
    -- fed, R.hidden the "not yours" debug lines, R.plateDraws the Display.Plate calls. opts.owner == false leaves the
    -- Combat Log globals unset (Owner inactive); opts.schools seeds the own schools (SEED_SCHOOLS by default). No queued
    -- timer fires, so a held hit waits for the next line's Core entry or the tail flush, as in game.
    local function Replay(lines, opts)
        opts = opts or {}
        local locked = {}
        for id, school in pairs(opts.schools or SEED_SCHOOLS) do locked[id] = { school = school, strays = 0 } end
        Clean()
        local ns = T.Boot(function(S)
            S.interface = 16001
            S.group = true
            CombatTextIconsCharDB = { lockedSchools = locked }
            for _, id in ipairs(HELPFUL) do S.harmful[id] = false end
        end)
        local S = T.State()
        local R = { owned = {}, hits = 0, hidden = 0, plateDraws = 0 }
        ns.Teacher.area = "clear"
        ns.Display.Plate = function() R.plateDraws = R.plateDraws + 1 end
        ns.Display.Player = function() end
        ns.Display.Notice = function() end
        ns.Debug = function(format, ...)
            if string.format(format, ...) == "  -> HIDDEN (not yours)" then R.hidden = R.hidden + 1 end
        end
        local Route = ns.HitRoute.Route
        ns.HitRoute.Route = function(hit)
            R.owned[#R.owned + 1] = { unit = hit.unit, now = hit.now, releasedAt = S.now, clock = ns.Now() }

            return Route(hit)
        end
        if opts.owner ~= false then SetCombatLog() end

        local fighting, castIndex = false, 0
        -- The fight opens at the first fed line after a TEACH session, or the first fed line of all.
        local function Start()
            if fighting then return end
            fighting = true
            ns.Core.PLAYER_REGEN_DISABLED()
        end

        local function FeedHit(unit, school, flag, threat, target)
            S.threat[unit] = tonumber(threat) or false
            S.target = target == "true" and unit or nil
            Start()
            ns.Core.UNIT_COMBAT(unit, "WOUND", flag, T.Secret(31), tonumber(school))
            R.hits = R.hits + 1
        end

        local function FeedCast(id)
            castIndex = castIndex + 1
            Start()
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c" .. castIndex, tonumber(id))
        end

        -- One line, after S.now is set to its stamp. The other tags (PROBE, SWING, START, PHEAL, TEACH rows) are skipped.
        local function Feed(rest)
            local unit, school, flag, threat, target = rest:match(
                "^HIT (%S+) school=(%d+) amount=%S+ flag=(%S*) .-threat=(%S+) .-target=(%a+)$")
            local mate, mateSchool, mateFlag = rest:match("^HEAL (%S+) school=(%d+) amount=%S+ flag=(%S*)$")
            local order = rest:match("^CLOG .-order=(%d+)")
            local castID = rest:match("^CAST player (%d+) ")
            if unit then
                FeedHit(unit, school, flag, threat, target)
            elseif mate then
                Start()
                ns.Core.UNIT_COMBAT(mate, "HEAL", mateFlag, T.Secret(31), tonumber(mateSchool))
            elseif order then
                Start()
                ns.Owner.Line(tonumber(order), S.now)
            elseif castID then
                FeedCast(castID)
            elseif rest:match("^TEACH session") and fighting then
                fighting = false
                ns.Core.PLAYER_REGEN_ENABLED()
            end
        end

        local function Run()
            for _, line in ipairs(lines) do
                local stamp, rest = line:match("^(%d+%.%d+) (.*)$")
                if stamp then
                    S.now = tonumber(stamp)
                    Feed(rest)
                end
            end
            S.now = S.now + 1
            ns.Owner.Flush(S.now)
            ns.Core.FlushHeals(S.now)
            ns.Core.FlushMates(S.now)
            if fighting then ns.Core.PLAYER_REGEN_ENABLED() end
        end

        -- The globals go back even when a handler errors, or every later check file would see an active Owner.
        local ok, failure = pcall(Run)
        Clean()
        if not ok then error(failure, 0) end

        return R
    end

    local HIT = " HIT %s school=%d amount=? flag= fps=60 threat=0 group=true,true,false npc=secret target=%s"
    local function Hit(at, unit, school, target) return string.format("%.3f", at) .. string.format(HIT, unit, school, target) end
    local function Line(at, order) return string.format("%.3f CLOG text=/Ky1/k rgb=0.70,0.70,0.70 order=%d", at, order) end
    local MINI = {
        Hit(100.000, "nameplate1", 32, "true"), Hit(100.000, "nameplate2", 1, "false"), Line(100.000, 0), -- own school on target beats a stranger's
        Line(101.000, 1), Hit(101.000, "nameplate1", 32, "true"),                      -- a backlog line takes nothing
        Hit(102.000, "nameplate1", 32, "true"), Line(102.040, 0),                      -- late line, inside 0.05 s
        Line(103.000, 0), Hit(103.030, "nameplate1", 32, "true"),                      -- late hit, inside 0.05 s
        Hit(104.000, "nameplate1", 32, "true"), Line(104.060, 0),                      -- 0.06 s apart: nothing pairs
        "105.000 HEAL party1 school=1 amount=? flag=", "105.000 PHEAL party1 school=1 flag=",
        Hit(105.000, "nameplate2", 1, "false"), Line(105.000, 0),                      -- a party heal (3) beats an other-school hit off target (0)
    }
    local R = Replay(MINI)
    local seen = {}
    for _, route in ipairs(R.owned) do seen[#seen + 1] = string.format("%.3f %s", route.now, route.unit) end
    Check("owner replay: only the lines' hits route owned (100, 102, 103.03; not backlog, 0.06 s, party-heal stamp)",
        table.concat(seen, ",") == "100.000 nameplate1,102.000 nameplate1,103.030 nameplate1")
    Check("owner replay: 7 hits fed, 4 hidden as not yours, PHEAL not fed twice", R.hits == 7 and R.hidden == 4)
    local held, clocked = true, true
    for _, route in ipairs(R.owned) do
        held = held and route.releasedAt > route.now          -- the hit waited for a later line, not routed on arrival
        clocked = clocked and route.clock == route.now         -- route clock = the hit's own stamp
    end
    Check("owner replay: each owned hit releases after its stamp, under its own route clock", held and clocked)
    local control = Replay(MINI, { owner = false })
    Check("owner replay: Owner off (no Combat Log) -> nothing owned, nothing hidden, no plate draw",
        #control.owned == 0 and control.hidden == 0 and control.plateDraws == 0)

    -- Run 2 (Forever dungeon, 2026-11-12, party, filter "My actions"): the floor of the whole design.
    local function Fixture(name)
        local lines = {}
        for line in io.lines(T.Root .. "/tests/fixtures/" .. name) do lines[#lines + 1] = line end
        return lines
    end
    local function Stamps(lines) -- per "%.3f" stamp: candidate events and live lines, read from the log only
        local events, live, hits = {}, {}, 0
        for _, text in ipairs(lines) do
            local at, tag, rest = text:match("^(%d+%.%d+) (%u+) ?(.*)$")
            if tag == "HIT" or tag == "PHEAL" or (tag == "HEAL" and rest:find("^player")) then
                events[at] = (events[at] or 0) + 1
            end
            if tag == "HIT" then hits = hits + 1 end
            if tag == "CLOG" and rest:find("order=0", 1, true) then live[at] = (live[at] or 0) + 1 end
        end
        return events, live, hits
    end
    local lines = Fixture("forever-group-run2-2026-11-12.log")
    local events, live, hitCount = Stamps(lines)
    Check("owner replay run 2: the fixture is the save (1460 lines, 302 hits)", #lines == 1460 and hitCount == 302)

    local R2 = Replay(lines)
    local owned, clean, lineNear = #R2.owned, 0, 0
    for _, route in ipairs(R2.owned) do
        local key = string.format("%.3f", route.now)
        if (live[key] or 0) > 0 and events[key] <= live[key] then clean = clean + 1 end
        for key in pairs(live) do
            if math.abs(tonumber(key) - route.now) <= 0.05 + 1e-9 then lineNear = lineNear + 1 break end
        end
    end
    T.Note(string.format("OWNER REPLAY run2 owned=%d clean=%d hidden=%d plateDraws=%d", owned, clean, R2.hidden, R2.plateDraws))
    Check("owner replay run 2: owned hits within the offline matcher's 36 clean to 38 taken (0.05 s window)", owned >= 36 and owned <= 38)
    Check("owner replay run 2: at least 90% of owned hits are clean (offline 36 of 38)", owned > 0 and clean / owned >= 0.90)
    Check("owner replay run 2: every owned hit has a live line within 0.05 s in the log", lineNear == owned)
    Check("owner replay run 2: every hit ends owned or hidden (302)", R2.hits == 302 and owned + R2.hidden == 302)
    Check("owner replay run 2: strangers' hits stay off the screen (plate draws <= owned hits)", R2.plateDraws <= owned)
    local off = Replay(lines, { owner = false })
    Check("owner replay run 2: Owner inactive -> today's grouped behavior, nothing owned, nothing drawn on plates",
        #off.owned == 0 and off.plateDraws == 0)
end
