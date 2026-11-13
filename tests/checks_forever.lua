-- Unit checks for the WoW Forever priest fixes (2026-10-23): crit size, the miss
-- rule, plates hidden and shown again, the debug lines and "?" on solo hits.
-- Called by tests/checks.lua with the same T table.

return function(T)
    local Check, Secret = T.Check, T.Secret
    local SWP, P = 594, 3.011735764150819 -- Shadow Word: Pain as learned in game (school 32)
    -- Core's debug route lines
    local ROUTE_UNKNOWN, ROUTE_CROWDED = "  -> unknown-solo", "  -> HIDDEN (crowded)"
    local ROUTE_METER_OFF = "  -> HIDDEN (meter off)"

    -- Forever (interface 16001) with SW:P learned, `setup(S)` run before the addon loads. The crowd
    -- check's area is clear. Draws and learned-spell misses are recorded on the returned rig;
    -- with `debug` the Debug lines go to rig.log.
    local function Rig(setup, debug)
        local rig = { draws = {}, misses = 0, log = {} }
        rig.ns = T.Boot(function(S)
            S.interface = 16001
            CombatTextIconsCharDB = { learned = { [SWP] = { school = 32, kind = "dot", period = P, misses = 0 } } }
            if setup then setup(S) end
        end)
        rig.S = T.State()
        local ns, S = rig.ns, rig.S
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(plate, texture) rig.draws[#rig.draws + 1] = { plate = plate, texture = texture } end
        ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
        local missed = ns.Learn.Missed
        ns.Learn.Missed = function(id) rig.misses = rig.misses + 1 missed(id) end
        if debug then ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end end
        -- Casts `spellID` (SW:P by default) at `t` aimed at `unit`.
        function rig.Cast(t, unit, spellID)
            S.now, S.target = t, unit
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", spellID or SWP)
        end
        -- The texture drawn for this hit, or nil when it stayed hidden (the draw happens in the call).
        function rig.Hit(t, unit, amount, school, flag)
            S.now = t
            local before = #rig.draws
            ns.Core.UNIT_COMBAT(unit, "WOUND", flag or "", amount or 31, school or 32)
            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end
        -- The last route line ("  -> ...") of the debug log.
        function rig.Route()
            for index = #rig.log, 1, -1 do
                if rig.log[index]:find("^  %->") then return rig.log[index] end
            end
        end
        function rig.Remove(t, unit) S.now = t ns.Core.NAME_PLATE_UNIT_REMOVED(unit) S.plates[unit] = nil end
        function rig.Add(t, unit)
            S.now = t
            if ns.Core.NAME_PLATE_UNIT_ADDED then ns.Core.NAME_PLATE_UNIT_ADDED(unit) end
        end
        function rig.Learned() return T.Store().learned[SWP] ~= nil end
        return rig
    end

    -- 1. Crit size ----------------------------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        Streams.Feed("k", 32, 31, "", 0)
        Streams.Feed("k", 32, 47, "CRITICAL", 3)
        Streams.Feed("k", 32, 31, "", 6)
        Streams.Feed("k", 32, 31, "", 9)
        Check("forever: 31, 47 CRITICAL, 31, 31 at 3 s gaps form one stream (crit x1.5)", #Streams.Live("k", 9) == 1)
        Check("forever: NormalAmount(45, CRITICAL) = 30", Streams.NormalAmount(45, "CRITICAL") == 30)

        local Retail = T.Boot().Streams
        Retail.Feed("r", 32, 31, "", 0)
        Retail.Feed("r", 32, 62, "CRITICAL", 3)
        Retail.Feed("r", 32, 31, "", 6)
        Retail.Feed("r", 32, 31, "", 9)
        Retail.Feed("x", 32, 31, "", 0)
        Retail.Feed("x", 32, 47, "CRITICAL", 3)
        Retail.Feed("x", 32, 31, "", 6)
        Retail.Feed("x", 32, 31, "", 9)
        Check("retail: crits stay x2 (31, 62 CRITICAL, 31, 31 pair; 31, 47 CRITICAL, 31, 31 do not)",
            #Retail.Live("r", 9) == 1 and #Retail.Live("x", 9) == 0 and Retail.NormalAmount(62, "CRITICAL") == 31)

        local function Chain(streams, key, hits)
            for index, hit in ipairs(hits) do streams.Feed(key, 32, hit[1], hit[2] or "", (index - 1) * 3) end
            return streams.Live(key, (#hits - 1) * 3)
        end
        local C = "CRITICAL"
        Check("forever: the crit band is [1.35, 1.65] (1.3, 1.7 and 2.0 disagree)",
            #Chain(Streams, "f13", { { 1000 }, { 1300, C }, { 1000 }, { 1000 } }) == 0 and #Chain(Streams, "f17", { { 1000 }, { 1700, C }, { 1000 }, { 1000 } }) == 0
            and #Chain(Streams, "f20", { { 1000 }, { 2000, C }, { 1000 }, { 1000 } }) == 0)
        Check("forever: the band edges 1.35 and 1.65 agree",
            #Chain(Streams, "f135", { { 1000 }, { 1350, C }, { 1000 }, { 1000 } }) == 1 and #Chain(Streams, "f165", { { 1000 }, { 1650, C }, { 1000 }, { 1000 } }) == 1)
        Check("forever: crit-only birth: lastAmount = newest crit / 1.5 (1500 -> 1000)",
            math.abs(Chain(Streams, "fco", { { 1500, C }, { 1500, C }, { 1500, C }, { 1500, C } })[1].lastAmount - 1000) < 1e-9)
    end

    -- 2. Miss rule ----------------------------------------------------------------------
    do
        -- Debugger scenario S4: churn wipes the instance, the DoT is refreshed twice on the
        -- same mob and its ticks keep the old phase (none at cast + P).
        local rig = Rig()
        rig.Cast(100, "nameplate1")
        rig.Hit(100 + P, "nameplate1"); rig.Hit(100 + 2 * P, "nameplate1")
        rig.Remove(107, "nameplate1")
        rig.Hit(100 + 3 * P, "nameplate1")
        rig.Cast(110, "nameplate1")
        for k = 4, 6 do rig.Hit(100 + k * P, "nameplate1") end
        rig.Cast(116.5, "nameplate1")
        for k = 7, 9 do rig.Hit(100 + k * P, "nameplate1") end
        rig.Hit(130, "nameplate3", 5, 1)
        Check("miss rule: refreshes after churn whose ticks keep the old phase count no miss (S4, spell kept)",
            rig.misses == 0 and rig.Learned())

        -- A same-school hit after the cast that is not its first tick (remembered as `seen`).
        rig = Rig()
        rig.Cast(100, "nameplate1"); rig.Hit(102, "nameplate1"); rig.Hit(106, "nameplate3", 5, 1)
        rig.Cast(110, "nameplate2"); rig.Hit(112, "nameplate2"); rig.Hit(116, "nameplate3", 5, 1)
        Check("miss rule: a cast whose plate took same-school hits after it counts no miss", rig.misses == 0 and rig.Learned())

        -- Debugger scenario S2: no tick at all on a quiet plate, twice.
        rig = Rig()
        rig.Cast(100, "nameplate1"); rig.Hit(105, "nameplate3", 5, 1)
        rig.Cast(110, "nameplate2"); rig.Hit(115, "nameplate3", 5, 1)
        Check("miss rule: two tickless casts on quiet plates still count 2 misses and drop the spell",
            rig.misses == 2 and not rig.Learned())
    end

    -- 3. Plates hidden and shown again ----------------------------------------------------
    do
        -- `guid2` is the GUID nameplate2 shows after nameplate1 (GUID A) hides.
        local function Churn(guidA, guid2, reset)
            local rig = Rig(function(S) S.guids.nameplate1, S.guids.nameplate2 = guidA, guid2 end)
            rig.Cast(100, "nameplate1")
            local first = rig.Hit(100 + P, "nameplate1")
            rig.Remove(104, "nameplate1")
            if reset then rig.ns.Tracker.Reset() end
            rig.Add(104.5, "nameplate2")
            return rig, first, rig.Hit(100 + 2 * P, "nameplate2")
        end
        local rig, first, again = Churn("Creature-A", "Creature-A")
        Check("plates: a tick before the plate hides is shown", first == "tex:594")
        Check("plates: the same mob on a new plate frame keeps its instance (next tick shown)", again == "tex:594")
        local log = rig.ns.Streams.CastLog(rig.S.plates.nameplate2)
        Check("plates: the same mob's cast log follows it to the new plate", #log == 1 and log[1].castID == SWP)
        rig, first, again = Churn("Creature-A", "Creature-B")
        Check("plates: another mob's plate gets no instance", again ~= "tex:594")
        rig, first, again = Churn(Secret("Creature-A"), Secret("Creature-A"))
        Check("plates: a secret GUID parks nothing (instances wiped as before)", again ~= "tex:594")
        rig, first, again = Churn("Creature-A", "Creature-A", true)
        Check("plates: Tracker.Reset drops parked instances", again ~= "tex:594")

        -- Hidden through its first tick and past its deadline: never a miss.
        rig = Rig(function(S) S.guids.nameplate1, S.guids.nameplate2 = "Creature-A", "Creature-A" end)
        rig.Cast(100, "nameplate1"); rig.Remove(101, "nameplate1")
        rig.Add(112, "nameplate2"); rig.Hit(113, "nameplate3", 5, 1)
        Check("plates: an instance hidden through its first tick counts no miss", rig.misses == 0 and rig.Learned())

        rig = Rig(function(S) S.guids.nameplate1, S.guids.nameplate2 = "Creature-A", "Creature-A" end)
        rig.Cast(100, "nameplate1"); rig.Remove(101, "nameplate1"); rig.Add(131.5, "nameplate2")
        Check("plates: nothing parked comes back after 30 s", #rig.ns.Streams.CastLog(rig.S.plates.nameplate2) == 0)
    end

    -- Cast-frame hits: a learned DoT cast on a Mind Blast or Smite stamp (Ticks.TICKLESS) claims no hit there --------
    do
        -- S10 run 1: SW:P 970 queued behind Mind Blast 8102 fired on its stamp; in game 12 Mind Blast hits there drew SW:P.
        local HOLY_FIRE = 14914
        local rig = Rig(function()
            CombatTextIconsCharDB.learned[HOLY_FIRE] = { school = 2, kind = "dot", period = 2, misses = 0 }
        end)
        rig.Cast(100, "nameplate1", 8102)
        rig.Cast(100, "nameplate1")
        local blast = rig.Hit(100, "nameplate1")
        Check("cast frame: Mind Blast's hit on the stamp SW:P was cast on is not SW:P's", blast ~= "tex:" .. SWP)
        rig.Cast(200, "nameplate1", 585)
        rig.Cast(200, "nameplate1", HOLY_FIRE)
        local smite = rig.Hit(200, "nameplate1", 31, 2)
        Check("cast frame: Smite's hit on the stamp a holy DoT was cast on is not the DoT's", smite ~= "tex:" .. HOLY_FIRE)
        rig.Cast(300, "nameplate1", HOLY_FIRE)
        Check("cast frame: a hit on a learned DoT's own lone cast stamp is still the DoT's (Holy Fire opens with a hit)",
            rig.Hit(300, "nameplate1", 31, 2) == "tex:" .. HOLY_FIRE)
        -- S12 run 1: SW:P deals nothing on its cast stamp, so the drain or a Touch of Weakness proc there is not SW:P's
        rig.Cast(400, "nameplate1")
        Check("cast frame: a hit on SW:P's own lone cast stamp is not SW:P's (Ticks.NO_OPENER)",
            rig.Hit(400, "nameplate1") ~= "tex:" .. SWP)

        -- retail: Mind Blast 8092 lands 0.17 s after its cast frame, so that frame's hit stays the DoT's own
        local ns = T.Boot(function()
            CombatTextIconsCharDB = { learned = { [SWP] = { school = 32, kind = "dot", period = P, misses = 0 } } }
        end)
        local S = T.State()
        ns.Teacher.area = "clear"
        local drawn
        ns.Display.Plate = function(_, texture) drawn = texture end
        S.now, S.target = 100, "nameplate1"
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", 8092)
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", SWP)
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 31, 32)
        Check("cast frame: on retail a learned DoT still claims its cast frame's hit next to Mind Blast", drawn == "tex:" .. SWP)
    end

    -- A Mind Blast or Smite alone on its cast stamp draws its icon (Locked.TicklessCast) ---------------------------------
    do
        local MIND_BLAST, SMITE = 8102, 585
        local TICKLESS_ROUTE = "  -> tickless " .. MIND_BLAST
        -- Casts `ids` at `t` aimed at `plate`; each secret hit of `hits` ({ plate, school }) lands at `t`, then the frame ends.
        -- Returns the textures drawn (hidden hits draw nothing).
        local function Frame(rig, t, plate, ids, hits)
            for _, id in ipairs(ids) do rig.Cast(t, plate, id) end
            local before = #rig.draws
            for _, hit in ipairs(hits) do rig.Hit(t, hit[1], Secret(31), hit[2]) end
            rig.ns.Core.FlushMates()
            local textures = {}
            for index = before + 1, #rig.draws do textures[#textures + 1] = rig.draws[index].texture end

            return textures
        end
        local function Drew(textures, texture)
            for _, drawn in ipairs(textures) do if drawn == texture then return true end end

            return false
        end

        local rig = Rig(nil, true)
        local drew = Frame(rig, 100, "nameplate1", { MIND_BLAST, SWP }, { { "nameplate1", 32 } })
        Check("tickless: Mind Blast's lone shadow hit on its cast stamp draws Mind Blast", drew[1] == "tex:" .. MIND_BLAST)
        Check("tickless: its debug route is 'tickless <id>'", rig.Route() == TICKLESS_ROUTE)

        drew = Frame(rig, 200, "nameplate1", { MIND_BLAST, SWP }, { { "nameplate1", 32 }, { "nameplate1", 32 } })
        Check("tickless: two shadow hits on the stamp's plate name neither Mind Blast", not Drew(drew, "tex:" .. MIND_BLAST))

        -- a learned SW:P tick on the stamp counts toward the frame's 2: the tracker names one, the other stays unnamed
        local ticking = Rig(function()
            CombatTextIconsCharDB.lockedTicks = { [SWP] = { period = P, kind = "damage", school = 32, misses = 0 } }
        end, true)
        Frame(ticking, 250 - 3 * P, "nameplate1", { SWP }, {})
        ticking.Hit(250 - 2 * P, "nameplate1", Secret(31), 32)
        ticking.Hit(250 - P, "nameplate1", Secret(31), 32)
        local logged = #ticking.log
        drew = Frame(ticking, 250, "nameplate1", { MIND_BLAST, SWP }, { { "nameplate1", 32 }, { "nameplate1", 32 } })
        local trackerNamed = false
        for index = logged + 1, #ticking.log do
            if ticking.log[index] == "  -> tracker " .. SWP then trackerNamed = true end
        end
        Check("tickless: the tracker names one of the stamp's two shadow hits SW:P", trackerNamed)
        Check("tickless: a tick the tracker names on the stamp still counts as a second shadow hit",
            not Drew(drew, "tex:" .. MIND_BLAST))

        -- Run 7 (2026-11-13): the lone hit of the 1309595 nuke drew as the SW:P tick due on its stamp. Alone in its
        -- frame, it is the cast's.
        ticking = Rig(function()
            CombatTextIconsCharDB.lockedTicks = { [SWP] = { period = P, kind = "damage", school = 32, misses = 0 } }
        end, true)
        Frame(ticking, 250 - 3 * P, "nameplate1", { SWP }, {})
        ticking.Hit(250 - 2 * P, "nameplate1", Secret(31), 32)
        ticking.Hit(250 - P, "nameplate1", Secret(31), 32)
        drew = Frame(ticking, 250, "nameplate1", { MIND_BLAST }, { { "nameplate1", 32 } })
        Check("tickless: a lone hit on the stamp draws the cast, not the tick the tracker names there",
            drew[1] == "tex:" .. MIND_BLAST)

        -- Rig re-Boots the harness (GetTime, plates): the checks below need a rig newer than `ticking`
        rig = Rig(nil, true)
        drew = Frame(rig, 300, "nameplate1", { MIND_BLAST }, { { "nameplate2", 32 } })
        Check("tickless: a shadow hit on another plate than the cast's aim is not Mind Blast's", not Drew(drew, "tex:" .. MIND_BLAST))
        drew = Frame(rig, 400, "nameplate1", { MIND_BLAST }, { { "nameplate1", 64 } })
        Check("tickless: a hit of another school than Mind Blast's is not Mind Blast's", not Drew(drew, "tex:" .. MIND_BLAST))
        drew = Frame(rig, 450, "nameplate1", { SMITE }, { { "nameplate1", 32 } })
        Check("tickless: a shadow hit on Smite's stamp is not Smite's", not Drew(drew, "tex:" .. SMITE))
        drew = Frame(rig, 500, "nameplate1", { SMITE }, { { "nameplate1", 2 } })
        Check("tickless: Smite's lone holy hit on its cast stamp draws Smite", drew[1] == "tex:" .. SMITE)

        rig.Cast(600, "nameplate1", MIND_BLAST)
        local before = #rig.draws
        rig.Hit(600, "nameplate1")
        rig.ns.Core.FlushMates()
        Check("tickless: a hit with a plain amount is not named by the cast stamp",
            not (#rig.draws > before and rig.draws[#rig.draws].texture == "tex:" .. MIND_BLAST))

        -- rule 1: the cast's own stamp only
        rig.Cast(700, "nameplate1", MIND_BLAST)
        drew = Frame(rig, 701, "nameplate1", {}, { { "nameplate1", 32 } })
        Check("tickless: a lone shadow hit a second after Mind Blast's cast stamp is not Mind Blast's",
            not Drew(drew, "tex:" .. MIND_BLAST))
        -- only the cast's plate counts: a shadow hit on another plate in the frame leaves Mind Blast's hit alone on its own
        drew = Frame(rig, 800, "nameplate1", { MIND_BLAST, SWP }, { { "nameplate1", 32 }, { "nameplate2", 32 } })
        Check("tickless: a shadow hit on another plate in the frame does not stop Mind Blast's own",
            Drew(drew, "tex:" .. MIND_BLAST))
        -- Run 9 (2026-11-13): a tick logged on the stamp before the cast (log order H C H) left the nuke's hit as '?'.
        -- In runs 7-9 every nuke stamp with a hit had one logged after its cast, so a hit logged before it is not the cast's.
        rig.Hit(900, "nameplate1", Secret(31), 32)
        drew = Frame(rig, 900, "nameplate1", { MIND_BLAST }, { { "nameplate1", 32 } })
        Check("tickless: a shadow hit logged on the stamp before the cast does not stop Mind Blast's own",
            Drew(drew, "tex:" .. MIND_BLAST))

        -- the one spell a lock fits (Locked.Observe's sole) wins over the cast stamp
        local locked = Rig(nil, true)
        locked.ns.Locked.Observe = function() return 5019, 1 end
        drew = Frame(locked, 100, "nameplate1", { MIND_BLAST }, { { "nameplate1", 32 } })
        Check("tickless: a hit a lock names on Mind Blast's stamp draws the lock's spell", drew[1] == "tex:5019")
        Check("tickless: its route stays 'locked <id>'", locked.Route() == "  -> locked 5019")

        -- Run 8 (2026-11-13): a hit the tracker can't split (UNKNOWN) drew '?' though one lock fit it.
        local unsplit = Rig(nil, true)
        unsplit.ns.Tracker.Identify = function() return unsplit.ns.Tracker.UNKNOWN end
        unsplit.ns.Locked.Observe = function() return 15407, 1 end
        drew = Frame(unsplit, 100, "nameplate1", {}, { { "nameplate1", 32 } })
        Check("unknown: a hit the tracker can't split draws the one spell a lock fits", drew[1] == "tex:15407")
        Check("unknown: its route is 'unknown-locked <id>'", unsplit.Route() == "  -> unknown-locked 15407")
        unsplit.ns.Locked.Observe = function() return nil, 2 end
        drew = Frame(unsplit, 200, "nameplate1", {}, { { "nameplate1", 32 } })
        Check("unknown: two lock fits keep the tracker's '?'",
            drew[1] == unsplit.ns.Meter.UNKNOWN_ICON and unsplit.Route() == "  -> tracker unknown")
    end

    -- The route lines ("  -> ...") the debug log gained since `mark`, a #rig.log.
    local function RoutesSince(rig, mark)
        local routes = {}
        for index = mark + 1, #rig.log do
            if rig.log[index]:find("^  %->") then routes[#routes + 1] = rig.log[index] end
        end

        return routes
    end
    local function Has(routes, line)
        for _, route in ipairs(routes) do if route == line then return true end end

        return false
    end
    local function Heal(rig, t)
        rig.S.now = t
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", Secret(9), 1)
    end
    -- The 0.2 s callbacks Core queued, fired at `t`.
    local function FireTimers(rig, t)
        rig.S.now = t
        for _, timer in ipairs(rig.S.timers) do if timer.delay == 0.2 then timer.fn() end end
    end

    -- Touch of Weakness: a lone shadow hit after the buff cast, with no self-heal near it, draws the proc's icon ------
    -- (spec 2026-11-07-forever-tow-proc; runs 10 and 11: 7 procs, each a shadow hit `?` with no heal on you within
    -- 0.5 s, where the 1260198 drain's heal comes on its hit's stamp or 0.107 s later)
    do
        local TOW1, PROC1, TOW2, PROC2, WAND = 2652, 2943, 19261, 19249, 5019
        local TOW_ROUTE = "  -> tow " .. PROC2
        local function TowRig()
            return Rig(function(S) S.harmful[TOW1], S.harmful[TOW2] = false, false end, true)
        end
        local function HasTow(routes)
            for _, route in ipairs(routes) do if route:find("^  %-> tow") then return true end end

            return false
        end

        local rig = TowRig()
        local Tow = rig.ns.Tow
        rig.Cast(90, "nameplate1", TOW2)
        Check("tow: casting a mapped Touch of Weakness rank arms its proc ID", Tow.Armed(91) == PROC2)
        rig.Cast(95, "nameplate1", TOW1)
        Check("tow: a recast re-arms with the new rank's proc ID", Tow.Armed(96) == PROC1)
        rig.Cast(96, "nameplate1", WAND)
        Check("tow: an unmapped spell cast changes nothing", Tow.Armed(97) == PROC1)
        Check("tow: the arm still holds 600 s after the cast", Tow.Armed(95 + 600) == PROC1)
        Check("tow: the arm is over 601 s after the cast", Tow.Armed(95 + 601) == nil)

        rig = TowRig()
        local taught = {}
        local drawn = rig.ns.Teacher.Drawn
        rig.ns.Teacher.Drawn = function(spellID, amount, at, school)
            taught[#taught + 1] = { spellID = spellID, at = at }

            return drawn(spellID, amount, at, school)
        end
        rig.Cast(90, "nameplate1", TOW2)
        local mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("tow: a candidate is held, not drawn and routes nothing yet", #rig.draws == 0
            and #RoutesSince(rig, mark) == 0)
        Check("tow: the held candidate leaves ToW armed until it is decided", rig.ns.Tow.Armed(100) == PROC2)
        local held = false
        for index = mark + 1, #rig.log do held = held or rig.log[index] == "  .. tow" end
        Check("tow: the hold logs the route line '  .. tow'", held)
        rig.Cast(100.2, "nameplate1", WAND)
        local routes = RoutesSince(rig, mark)
        Check("tow: no heal near it -> the next event past 0.15 s draws it as Touch of Weakness's proc",
            Has(routes, TOW_ROUTE) and rig.draws[1] and rig.draws[1].texture == "tex:" .. PROC2)
        Check("tow: the ToW draw disarms", rig.ns.Tow.Armed(101) == nil)
        Check("tow: the teacher is told the proc at the held hit's stamp, not the deciding event's",
            #taught == 1 and taught[1].spellID == PROC2 and taught[1].at == 100)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Hit(100.3, "nameplate1", Secret(31), 2)
        Check("tow: a hit event past 0.15 s decides the held candidate before it routes its own hit",
            RoutesSince(rig, mark)[1] == TOW_ROUTE)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        routes = RoutesSince(rig, mark)
        Check("tow: a heal on the hit's stamp after it -> '?', ToW stays armed",
            #routes == 1 and routes[1] == ROUTE_UNKNOWN and rig.ns.Tow.Armed(100) == PROC2)
        rig.Cast(101, "nameplate1", WAND)
        Check("tow: ... and nothing is drawn as ToW later", not HasTow(RoutesSince(rig, mark)))

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100.107)
        routes = RoutesSince(rig, mark)
        Check("tow: a heal 0.107 s after the hit -> '?', ToW stays armed",
            #routes == 1 and routes[1] == ROUTE_UNKNOWN and rig.ns.Tow.Armed(101) == PROC2)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        Heal(rig, 100)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        routes = RoutesSince(rig, mark)
        Check("tow: a heal logged on the stamp before the hit -> '?' at once, ToW stays armed",
            #routes == 1 and routes[1] == ROUTE_UNKNOWN and rig.ns.Tow.Armed(100) == PROC2)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        rig.Hit(100, "nameplate1", Secret(31), 32)
        mark = #rig.log
        rig.Hit(100.05, "nameplate1", Secret(31), 32)
        routes = RoutesSince(rig, mark)
        Check("tow: a second candidate while one is held -> '?' at once",
            #routes == 1 and routes[1] == ROUTE_UNKNOWN)
        rig.Cast(100.3, "nameplate1", WAND)
        Check("tow: ... and the first one still decides as ToW's proc", Has(RoutesSince(rig, mark), TOW_ROUTE))

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 2)
        Check("tow: a hit of another school than shadow is not a candidate",
            RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN and rig.ns.Tow.Armed(100) == PROC2)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        rig.ns.Locked.Observe = function() return WAND, 1 end
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("tow: a hit a lock names (sole set) keeps its route and ToW armed",
            RoutesSince(rig, mark)[1] == "  -> locked " .. WAND and rig.ns.Tow.Armed(100) == PROC2)

        rig = TowRig()
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("tow: not armed -> '?' as today", RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(691, "nameplate1", Secret(31), 32)
        Check("tow: armed 601 s ago -> '?' as today", RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN)
        rig.Cast(700, "nameplate1", WAND)
        Check("tow: ... and the expired arm draws nothing as ToW", not HasTow(RoutesSince(rig, mark)))

        rig = TowRig()
        rig.ns.IsForever = false
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Cast(101, "nameplate1", WAND)
        Check("tow: off Forever ToW never arms and no hit is held", rig.ns.Tow.Armed(100) == nil
            and not HasTow(RoutesSince(rig, mark)))

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.S.now = 100.01
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        Check("tow: fight end decides a held candidate as ToW whatever its age and disarms",
            Has(RoutesSince(rig, mark), TOW_ROUTE) and rig.ns.Tow.Armed(101) == nil)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        rig.S.now = 100
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        Check("tow: fight end with nothing held does not disarm", rig.ns.Tow.Armed(101) == PROC2)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Cast(100.05, "nameplate1", TOW1)
        rig.Cast(100.3, "nameplate1", WAND)
        Check("tow: a recast after the hold -> the held proc ID draws and the new arm stays",
            Has(RoutesSince(rig, mark), TOW_ROUTE) and rig.ns.Tow.Armed(101) == PROC1)

        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        FireTimers(rig, 100.1)
        Check("tow: the 0.2 s timer decides nothing before 0.15 s have passed", not HasTow(RoutesSince(rig, mark)))
        FireTimers(rig, 100.2)
        Check("tow: the 0.2 s timer decides a held candidate as ToW", Has(RoutesSince(rig, mark), TOW_ROUTE))
        FireTimers(rig, 100.4)
        Check("tow: a candidate is decided once", #RoutesSince(rig, mark) == 1)

        -- a second secret hit on the held hit's stamp: the decision tags the held frame entry without comparing amounts
        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Hit(100, "nameplate2", Secret(40), 2)
        local decided, err = pcall(rig.Cast, 100.3, "nameplate1", WAND)
        Check("tow: a second secret hit on the held hit's stamp does not break the decision"
            .. (decided and "" or (" (" .. tostring(err) .. ")")), decided)
        Check("tow: ... and the held hit still draws as the proc", Has(RoutesSince(rig, mark), TOW_ROUTE))
        Check("tow: ... and the arm is spent", rig.ns.Tow.Armed(101) == nil)

        -- /cti off inside the 0.2 s window: the held hit is dropped, the timer draws nothing
        rig = TowRig()
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.S.now = 100.1
        SlashCmdList.COMBATTEXTICONS("off")
        FireTimers(rig, 100.25)
        Check("tow: /cti off while a candidate is held draws it as nothing", #rig.draws == 0
            and not HasTow(RoutesSince(rig, mark)))
        SlashCmdList.COMBATTEXTICONS("on")
    end

    -- The 1260198 drain: a lone shadow hit held while exactly one proc row is saved draws that row's icon when a heal on
    -- its stamp is claimed as the row (spec 2026-11-10-forever-drain-hit) -------------------------------------------
    do
        local TOW2, PROC2, WAND, DRAIN, OTHER = 19261, 19249, 5019, 1260198, 23455
        local DRAIN_ROUTE = "  -> drain " .. DRAIN
        -- Forever, solo unless `group`, with the proc rows `rows` saved and Touch of Weakness castable
        local function DrainRig(rows, group)
            return Rig(function(S)
                S.harmful[2652], S.harmful[TOW2] = false, false
                S.group = group == true
                CombatTextIconsCharDB.lockedHealsV = 2
                CombatTextIconsCharDB.lockedHeals = {}
                for _, id in ipairs(rows) do CombatTextIconsCharDB.lockedHeals[id] = { strikes = 0 } end
            end, true)
        end
        local function PlateTexture(rig)
            for index = #rig.draws, 1, -1 do
                if rig.draws[index].plate then return rig.draws[index].texture end
            end
        end
        local function Logged(rig, line)
            for _, logged in ipairs(rig.log) do if logged == line then return true end end

            return false
        end

        local rig = DrainRig({ DRAIN })
        local mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: a lone shadow hit with a heal on its stamp draws the one saved proc row",
            Has(RoutesSince(rig, mark), DRAIN_ROUTE) and PlateTexture(rig) == "tex:" .. DRAIN)

        rig = DrainRig({ DRAIN })
        mark = #rig.log
        Heal(rig, 100)
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: a heal logged on the stamp before the hit draws the same",
            Has(RoutesSince(rig, mark), DRAIN_ROUTE) and PlateTexture(rig) == "tex:" .. DRAIN)

        rig = DrainRig({ DRAIN })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100.1)
        local routes = RoutesSince(rig, mark)
        Check("drain: a heal 0.1 s after the hit draws it '?' at the heal", #routes == 1 and routes[1] == ROUTE_UNKNOWN)
        rig.Cast(100.3, "nameplate1", WAND)
        Check("drain: ... and no hit draws as the drain later", not Has(RoutesSince(rig, mark), DRAIN_ROUTE))

        rig = DrainRig({ DRAIN })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("drain: no heal, Touch of Weakness not armed -> the hit is held and logs '  .. drain'",
            #RoutesSince(rig, mark) == 0 and Logged(rig, "  .. drain"))
        FireTimers(rig, 100.2)
        Check("drain: ... and the 0.2 s timer draws it '?'", RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN)

        -- The tracker names SW:P, only the wand's lock fits (run 5's Shoot): the hold runs first, the wand replaces '?'.
        local function DoubtedRig()
            local doubted = DrainRig({ DRAIN })
            doubted.ns.Tracker.Identify = function() return SWP end
            doubted.ns.Locked.Observe = function() return WAND, 1 end
            return doubted
        end
        rig = DoubtedRig()
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        FireTimers(rig, 100.2)
        Check("drain: a hit the tracker names SW:P but only the wand's lock fits is held, then drawn as the wand",
            Logged(rig, "  .. drain") and RoutesSince(rig, mark)[1] == "  -> locked " .. WAND)
        rig = DoubtedRig()
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: ... and with a heal on its stamp it draws the drain, not the wand",
            Has(RoutesSince(rig, mark), DRAIN_ROUTE) and not Has(RoutesSince(rig, mark), "  -> locked " .. WAND))

        rig = DrainRig({ DRAIN })
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: Touch of Weakness armed, no heal -> the proc draws as before",
            Has(RoutesSince(rig, mark), "  -> tow " .. PROC2))

        rig = DrainRig({ DRAIN })
        rig.Cast(90, "nameplate1", TOW2)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: Touch of Weakness armed, heal on the stamp -> the drain draws and the arm stays",
            Has(RoutesSince(rig, mark), DRAIN_ROUTE) and rig.ns.Tow.Armed(100.2) == PROC2)

        rig = Rig(nil, true)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("drain: no row saved -> '?' at once and no hold", RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN
            and not Logged(rig, "  .. drain"))

        rig = DrainRig({ DRAIN, OTHER })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("drain: two rows saved -> '?' at once", RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN)

        rig = DrainRig({ DRAIN }, true)
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: grouped -> no plate draw for the hit", PlateTexture(rig) == nil)

        rig = DrainRig({ DRAIN })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 1)
        Check("drain: a physical hit is not held", RoutesSince(rig, mark)[1] == ROUTE_UNKNOWN)

        rig = DrainRig({ DRAIN })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.Hit(100.1, "nameplate2", Secret(31), 32)
        Heal(rig, 100.1)
        rig.Cast(100.3, "nameplate1", WAND)
        Check("drain: a heal claimed for a later own hit does not name the earlier held hit",
            not Has(RoutesSince(rig, mark), DRAIN_ROUTE) and PlateTexture(rig) ~= "tex:" .. DRAIN)

        rig = DrainRig({ DRAIN })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        rig.S.now = 100.05
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        Check("drain: fight end right after the same-stamp heal draws the drain", Has(RoutesSince(rig, mark), DRAIN_ROUTE))

        rig = Rig(function(S)
            S.harmful[2652], S.harmful[TOW2], S.harmful[2061] = false, false, false
            S.group = false
            CombatTextIconsCharDB.lockedHealsV = 2
            CombatTextIconsCharDB.lockedHeals = { [DRAIN] = { strikes = 0 } }
        end, true)
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Heal(rig, 100)
        rig.Cast(100, "nameplate1", 2061)
        rig.Cast(100.2, "nameplate1", WAND)
        Check("drain: a same-stamp heal the claim does not name draws the hit '?', not the drain",
            not Has(RoutesSince(rig, mark), DRAIN_ROUTE) and Has(RoutesSince(rig, mark), ROUTE_UNKNOWN))

        -- A channel heal on the hit's stamp marks it healed but never waits (PlayerHits.Heal: Release, then the
        -- channel draw); the Release call stands in for it. A later heal claimed for another own hit must not name it.
        rig = DrainRig({ DRAIN })
        mark = #rig.log
        rig.Hit(100, "nameplate1", Secret(31), 32)
        rig.ns.TowHold.Release(100)
        rig.Hit(100.1, "nameplate2", Secret(31), 32)
        Heal(rig, 100.1)
        rig.Cast(100.3, "nameplate1", WAND)
        Check("drain: a hit healed by a heal that never waits is not named by a later stamp's claim",
            not Has(RoutesSince(rig, mark), DRAIN_ROUTE))
    end

    -- 4. Debug lines ------------------------------------------------------------------------
    do
        local rig = Rig(nil, true)
        local log = rig.log
        local function Last(pattern)
            for index = #log, 1, -1 do if log[index]:find(pattern) then return log[index] end end
        end
        rig.S.target = "nameplate1"
        rig.Hit(1, "nameplate1")
        local onTarget = Last("^HIT nameplate1")
        rig.Hit(2, "nameplate2")
        local offTarget = Last("^HIT nameplate2")
        local unitIsUnit = UnitIsUnit
        UnitIsUnit = function(a, b) if b == "target" then return Secret(true) end return unitIsUnit(a, b) end
        rig.Hit(3, "nameplate1")
        local secret = Last("^HIT nameplate1")
        UnitIsUnit = function(a, b) if b == "target" then error("restricted") end return unitIsUnit(a, b) end
        rig.Hit(4, "nameplate1")
        local failed = Last("^HIT nameplate1")
        UnitIsUnit = unitIsUnit
        Check("debug: the HIT line ends with target=true / false / secret / err",
            onTarget and onTarget:find(" target=true$") and offTarget and offTarget:find(" target=false$")
            and secret and secret:find(" target=secret$") and failed and failed:find(" target=err$"))

        local threatSituation, threats = UnitThreatSituation, {}
        for index, answer in ipairs({ function() return 1 end, function() return nil end,
            function() return Secret(1) end, function() error("restricted") end }) do
            UnitThreatSituation = answer
            rig.Hit(4 + index, "nameplate1")
            threats[index] = Last("^HIT nameplate1"):match(" threat=(%S+) group=%S+ npc=%S+ target=")
        end
        UnitThreatSituation = threatSituation
        Check("debug: the HIT line logs threat=1 / nil / secret / err before target= (gap 2 probe)",
            threats[1] == "1" and threats[2] == "nil" and threats[3] == "secret" and threats[4] == "err")

        local isInGroup, groups = IsInGroup, {}
        for index, answer in ipairs({ function() return false end, function(category) return category == 2 end,
            function() return Secret(true) end }) do
            IsInGroup = answer
            rig.Hit(8 + index, "nameplate1")
            groups[index] = Last("^HIT nameplate1"):match(" group=(%S+) npc=%S+ target=")
        end
        IsInGroup = isInGroup
        Check("debug: the HIT line logs IsInGroup any,home,instance raw before target= (solo-hidden probe)",
            groups[1] == "false,false,false" and groups[2] == "false,false,true"
            and groups[3] == "secret,secret,secret")

        local unitGUID, npcs = UnitGUID, {}
        for index, answer in ipairs({ function() return "Creature-0-3767-2552-1234-225983-0000ABCDEF" end,
            function() return "Player-1305-0ABCDEF1" end, function() return nil end,
            function() return Secret("Creature-0-1-2-3-4-5") end, function() error("restricted") end }) do
            UnitGUID = answer
            rig.Hit(11 + index, "nameplate1")
            npcs[index] = Last("^HIT nameplate1"):match(" npc=(%S+) target=")
        end
        UnitGUID = unitGUID
        Check("debug: the HIT line logs npc=<creature ID> / type / nil / secret / err before target= (dummy probe)",
            npcs[1] == "225983" and npcs[2] == "Player" and npcs[3] == "nil" and npcs[4] == "secret" and npcs[5] == "err")

        rig.Cast(9, "nameplate1")
        local cast = Last("^CAST ")
        Check("debug: a cast logs CAST <unit> <id> base=<FindBaseSpellByID>,<GetBaseSpell> (override probe)",
            cast ~= nil and cast:find("^CAST player 594 base=594,%S+ ") ~= nil)
        rig.Cast(9.5, nil)
        local keyless = Last("^CAST ")
        Check("debug: the CAST line ends with the cast's tick key: key=<plate unit> solo on a plate, key=nil with none",
            cast ~= nil and cast:find(" key=nameplate1$") ~= nil and keyless ~= nil and keyless:find(" key=nil$") ~= nil)
        C_NamePlate.GetNamePlateForUnit("nameplate2", false).namePlateUnitToken = nil
        rig.Add(9.6, "nameplate2")
        rig.Cast(9.7, "nameplate2")
        local tokenless = Last("^CAST ")
        Check("debug: a plate frame with no namePlateUnitToken (Forever, S5 run 2 printed key=plate) logs the unit it was "
            .. "added for", tokenless ~= nil and tokenless:find(" key=nameplate2$") ~= nil)

        rig.S.now = 10
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", 500, 2)
        rig.ns.Core.FlushHeals(nil)
        local heal = Last("^HEAL ")
        Check("debug: a heal logs HEAL <unit> school= amount= flag= and its route",
            heal == "HEAL player school=2 amount=500 flag=" and log[#log] == ROUTE_UNKNOWN)
    end

    -- The Forever probe: what an unreadable amount is, and the meter's rows at that moment ---------
    do
        local rig = Rig(nil, true)
        local function Probes()
            local lines = {}
            for _, line in ipairs(rig.log) do
                if line:find("^PROBE") then lines[#lines + 1] = line end
            end
            return lines
        end
        local sessions, source = C_DamageMeter.GetAvailableCombatSessions, C_DamageMeter.GetCombatSessionSourceFromID
        local total = 88
        C_DamageMeter.GetAvailableCombatSessions = function() return { { sessionID = 4 }, { sessionID = 7 } } end
        C_DamageMeter.GetCombatSessionSourceFromID = function(id)
            return { combatSpells = { { spellID = 75, totalAmount = total }, { spellID = 589, totalAmount = id } } }
        end
        local available = rig.ns.Meter.Disable
        local disabled = false
        rig.ns.Meter.Disable = function() disabled = true end
        rig.Hit(1, "nameplate1", 31)
        local plain = #Probes()
        rig.Hit(2, "nameplate1", Secret(31))
        rig.ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", nil, 32)
        total = Secret(88)
        rig.Hit(3, "nameplate1", Secret(31))
        C_DamageMeter.GetAvailableCombatSessions = function() error("sessions broke") end
        rig.Hit(4, "nameplate1", Secret(31))
        local lines = Probes()
        C_DamageMeter.GetAvailableCombatSessions = function() return {} end
        local empty = rig.ns.Teacher.ProbeMeter()
        C_DamageMeter.GetAvailableCombatSessions, C_DamageMeter.GetCombatSessionSourceFromID = sessions, source
        rig.ns.Meter.Disable = available
        Check("probe: a plain amount logs no probe line", plain == 0)
        Check("probe: a secret amount logs secret and the newest session's rows",
            lines[1] == "PROBE amount=secret meter=session:7,75:88,589:7")
        Check("probe: a missing amount logs nil", lines[2] == "PROBE amount=nil meter=session:7,75:88,589:7")
        Check("probe: a secret total shows as secret, its spell ID stays plain",
            lines[3] == "PROBE amount=secret meter=session:7,75:secret,589:7")
        Check("probe: a failed read logs err, and never turns the meter off",
            lines[4] ~= nil and lines[4]:find("meter=err .*sessions broke") ~= nil and not disabled)
        Check("probe: a meter with no sessions says so", empty == "no-sessions")

        local slash = Rig()
        SlashCmdList.COMBATTEXTICONS("debug")
        local first = CombatTextIconsDB.debugLog[1]
        Check("probe: /cti debug starts the log with the client's combat APIs", first ~= nil
            and first:find("PROBE api issecretvalue=true CombatLogGetCurrentEventInfo=%a+ C_CombatLog=%a+ C_DamageMeter=true cleu=%a+$") ~= nil)
        local second = CombatTextIconsDB.debugLog[2]
        Check("probe: a client without the Combat Log's lines says so and registers nothing", second ~= nil
            and second:find("PROBE clog COMBAT_LOG_MESSAGE=false PLAYER_SWING=false PLAYER_REGEN_DISABLED=false "
            .. "UNIT_COMBAT=false PLAYER_REGEN_ENABLED=false lines=none filter=none$") ~= nil)
        slash.ns.Debug = nil
    end

    -- Probe (2026-11-11): /cti debug logs the Combat Log's lines and switches them on, and back off when it stops ---
    do
        local rig = Rig()
        local enabled = false
        C_EventUtils = { IsEventValid = function() return true end }
        C_CombatLog = {
            AreFilteredEventsEnabled = function() return enabled end,
            SetFilteredEventsEnabled = function(on) enabled = on end,
        }
        Blizzard_CombatLog_Filters = { currentFilter = 1, filters = { { name = "My actions" } } }
        SlashCmdList.COMBATTEXTICONS("debug")
        local probe = rig.S.frames[#rig.S.frames] -- made by /cti debug, after every frame the addon made at load
        local log = CombatTextIconsDB.debugLog
        Check("probe: the lines are switched on and the picked filter is named", log[2] ~= nil
            and log[2]:find("PROBE clog COMBAT_LOG_MESSAGE=true PLAYER_SWING=true PLAYER_REGEN_DISABLED=true "
            .. "UNIT_COMBAT=true PLAYER_REGEN_ENABLED=true lines=switched filter=1:My_actions$") ~= nil and enabled == true)
        probe.scripts.OnEvent(probe, "COMBAT_LOG_MESSAGE", Secret("text"), 1, 0.5, Secret(0), 2)
        probe.scripts.OnEvent(probe, "PLAYER_SWING", false, 1)
        Check("probe: a line logs its words as secret and its plain colour",
            log[3] ~= nil and log[3]:find("CLOG text=secret rgb=1.00,0.50,%? order=2$") ~= nil)
        Check("probe: a swing logs its kind", log[4] ~= nil and log[4]:find("SWING false kind=1$") ~= nil)
        enabled = false
        probe.scripts.OnEvent(probe, "PLAYER_REGEN_DISABLED")
        Check("probe: a fight start switches the lines back on when the tab turned them off",
            log[5] ~= nil and log[5]:find("PROBE clog lines=switched filter=1:My_actions$") ~= nil and enabled)

        -- v2 (2026-11-12): heals on party members, and the meter's fields after the fight
        probe.scripts.OnEvent(probe, "UNIT_COMBAT", "party2", "HEAL", "CRITICAL", Secret(900), 2)
        probe.scripts.OnEvent(probe, "UNIT_COMBAT", "nameplate1", "HEAL", "", Secret(900), 2)
        probe.scripts.OnEvent(probe, "UNIT_COMBAT", "party1", "WOUND", "", Secret(900), 1)
        Check("probe: a heal on a party member logs its unit, school and flag; other units and wounds log nothing",
            log[6] ~= nil and log[6]:find("PHEAL party2 school=2 flag=CRITICAL$") ~= nil and log[7] == nil)
        local sessions, source = C_DamageMeter.GetAvailableCombatSessions, C_DamageMeter.GetCombatSessionSourceFromID
        C_DamageMeter.GetAvailableCombatSessions = function() return { { sessionID = 3 }, { sessionID = 9 } } end
        C_DamageMeter.GetCombatSessionSourceFromID = function(id)
            return { combatSpells = { { spellID = 589, totalAmount = Secret(40), details = { hits = 3 } } }, name = "me" }
        end
        local queued = #rig.S.timers
        probe.scripts.OnEvent(probe, "PLAYER_REGEN_ENABLED")
        Check("probe: a fight end logs nothing at once", log[7] == nil and #rig.S.timers == queued + 1)
        rig.S.timers[#rig.S.timers].fn()
        Check("probe: a second after a fight the newest session's fields log, nested and secret-safe", log[7] ~= nil
            and log[7]:find("PROBE meterfields session:9 {combatSpells={1={details={hits=3},spellID=589,totalAmount=secret}},"
            .. "name=me}$", 1, false) ~= nil)
        C_DamageMeter.GetAvailableCombatSessions = function() error("sessions broke") end
        rig.S.timers[#rig.S.timers].fn()
        Check("probe: a failed meter read logs err", log[8] ~= nil and log[8]:find("PROBE meterfields err .*sessions broke") ~= nil)
        C_DamageMeter.GetAvailableCombatSessions, C_DamageMeter.GetCombatSessionSourceFromID = sessions, source
        SlashCmdList.COMBATTEXTICONS("debug")
        Check("probe: /cti debug off switches the lines back off", enabled == false)
        C_EventUtils, C_CombatLog, Blizzard_CombatLog_Filters = nil, nil, nil
    end

    -- Forever's amounts are secret: no read decides the area, yet your hits and heals still draw --------
    do
        local function Unknown(forever, area, amount)
            local rig = Rig()
            rig.ns.IsForever, rig.ns.Teacher.area = forever, area
            return rig.Hit(1, "nameplate1", amount) == rig.ns.Meter.UNKNOWN_ICON
        end
        Check("secret: a secret hit in an undecided area draws ? on Forever", Unknown(true, "unknown", Secret(31)))
        Check("secret: a plain hit in an undecided area stays hidden", not Unknown(true, "unknown", 31))
        Check("secret: a secret hit in a crowded area stays hidden", not Unknown(true, "crowded", Secret(31)))
        Check("secret: off Forever a secret hit in an undecided area stays hidden", not Unknown(false, "unknown", Secret(31)))

        local rig = Rig()
        rig.ns.Teacher.area = "unknown"
        rig.S.now = 1
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", Secret(9), 1)
        rig.ns.Core.FlushHeals(nil)
        local heal = rig.draws[#rig.draws]
        Check("secret: a secret heal on you in an undecided area draws ?", heal ~= nil and heal.kind == "heal"
            and heal.texture == rig.ns.Meter.UNKNOWN_ICON)
    end

    -- Forever's rhythm votes: casts on one stamp can't be told apart, and no read corrects a wrong one -----
    do
        local SMITE, PAIN = 591, 589
        local function Birth(forever, painAt)
            local voter = Rig()
            local Learn, Streams = voter.ns.Learn, voter.ns.Streams
            voter.ns.IsForever = forever
            Streams.LogCast("k", SMITE, "dot", 10)
            Streams.LogCast("k", PAIN, "dot", painAt)
            Learn.OnBirth("k", { owners = { SMITE, PAIN }, ownerAt = { [SMITE] = 10, [PAIN] = painAt },
                ownerKind = { [SMITE] = "dot", [PAIN] = "dot" }, landed = {}, school = 32, period = 3, birth = 16,
                hits = { 10, 13, 16 } }, 16)
            local function Votes(spellID)
                local entry = Learn.Votes(spellID)
                return entry and entry.sigs[1] and entry.sigs[1].votes
            end
            return Votes(SMITE), Votes(PAIN)
        end
        local smite, pain = Birth(true, 10)
        Check("forever votes: two casts on one stamp give a birth no vote", smite == 0 and pain == 0)
        smite, pain = Birth(true, 11)
        Check("forever votes: casts on their own stamps both vote", smite == 1 and pain == 1)
        smite, pain = Birth(false, 10)
        Check("forever votes: off Forever two casts on one stamp still vote", smite == 1 and pain == 1)
    end

    -- 5. "?" on unidentified hits when solo ---------------------------------------------------
    do
        local function Unclaimed(group)
            local rig = Rig(function(S) S.group = group end, true)
            local fed = 0
            local feed = rig.ns.Streams.Feed
            rig.ns.Streams.Feed = function(...) fed = fed + 1 return feed(...) end
            return rig.Hit(1, "nameplate1", 500, 4), fed, rig
        end
        local texture, fed, rig = Unclaimed(false)
        Check("solo: a hit nothing identifies draws ? and is still fed to streams",
            texture == rig.ns.Meter.UNKNOWN_ICON and fed == 1)
        Check("solo: its debug route is -> unknown-solo", rig.Route() == ROUTE_UNKNOWN)
        texture, fed, rig = Unclaimed(true)
        Check("group: a hit nothing identifies stays hidden and is fed to streams", texture == nil and fed == 1)
        Check("group: its debug route is -> HIDDEN", rig.Route() == "  -> HIDDEN")

        -- Solo but not alone: strangers' hits on mobs that are not fighting you stay hidden.
        local function Solo(threat, target)
            local rig = Rig(function(S) S.threat.nameplate1, S.target = threat, target end)
            local fed = 0
            local feed = rig.ns.Streams.Feed
            rig.ns.Streams.Feed = function(...) fed = fed + 1 return feed(...) end
            return rig.Hit(1, "nameplate1", 500, 4), fed, rig
        end
        texture, fed = Solo(false)
        Check("solo: a hit on a mob without you on its threat list stays hidden and is fed", texture == nil and fed == 1)
        texture, _, rig = Solo(false, "nameplate1")
        Check("solo: a targeted mob without a threat list (training dummy) draws ?", texture == rig.ns.Meter.UNKNOWN_ICON)
        texture, fed, rig = Solo(3)
        Check("solo: a hit on a mob you tank draws ?", texture == rig.ns.Meter.UNKNOWN_ICON and fed == 1)
        texture, _, rig = Solo(Secret(1), "nameplate1")
        local onTarget = texture == rig.ns.Meter.UNKNOWN_ICON
        texture = Solo(Secret(1), "nameplate2")
        Check("solo: secret threat falls back to the target (target ?, other mob hidden)", onTarget and texture == nil)
        texture, _, rig = Solo("error", "nameplate1")
        onTarget = texture == rig.ns.Meter.UNKNOWN_ICON
        texture = Solo("error")
        Check("solo: a restricted threat answer falls back to the target", onTarget and texture == nil)
    end

    -- 5b. Training dummies: creature IDs learned live (spec 2026-10-25-dummies) ---------------------
    do
        -- Creature-0-<server>-<instance>-<zone>-<npcID>-<spawn>
        local A1, A2 = "Creature-0-1-2-3-242759-00000A1", "Creature-0-1-2-3-242759-00000A2"
        local A3, B = "Creature-0-1-2-3-242759-00000A3", "Creature-0-1-2-3-242758-000000B"
        local LEARN = { 1, 1.5, 2, 2.5, 3.1 } -- 5 hits over 2.1 s
        -- A debug rig whose plates show `guids` (plate -> GUID) and answer "no threat list".
        local function Dummies(guids)
            return Rig(function(S)
                for plate, guid in pairs(guids) do S.guids[plate], S.threat[plate] = guid, false end
            end, true)
        end
        -- Hits `plate` as the target at each of `times` (school 4: the tracker names none).
        local function Strike(rig, plate, times)
            rig.S.target = plate
            for _, t in ipairs(times) do rig.Hit(t, plate, 500, 4) end
        end
        -- A non-target hit on nameplate2 at `t`, its frame ended (a dummy's hit no one fights waits for that): its
        -- route line and the texture drawn.
        local function Other(rig, t)
            rig.S.target = "nameplate1"
            local before = #rig.draws
            rig.Hit(t, "nameplate2", 500, 4)
            rig.ns.Core.FlushMates()
            return rig.Route(), #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        local rig = Dummies({ nameplate1 = A1, nameplate2 = A2 })
        Strike(rig, "nameplate1", LEARN)
        local route, texture = Other(rig, 3.2)
        Check("dummies: 5 target hits over 2 s with no threat list learn the ID; another dummy of it draws ?",
            route == ROUTE_UNKNOWN and texture == rig.ns.Meter.UNKNOWN_ICON)

        rig = Dummies({ nameplate1 = A1, nameplate2 = A2 })
        Strike(rig, "nameplate1", { 1, 1.2, 1.4, 1.6, 1.8 })
        Check("dummies: 5 hits within 2 s learn nothing (the other dummy stays hidden)", Other(rig, 1.9) == "  -> HIDDEN")

        rig = Dummies({ nameplate1 = A1, nameplate2 = A2 })
        Strike(rig, "nameplate1", LEARN)
        rig.S.threat.nameplate2 = 3
        Other(rig, 3.2)
        rig.S.threat.nameplate2 = false
        Check("dummies: a threat answer from a unit of the learned ID un-learns it", Other(rig, 3.3) == "  -> HIDDEN")

        rig = Dummies({ nameplate1 = A1, nameplate2 = B })
        Strike(rig, "nameplate1", LEARN)
        Check("dummies: another creature ID, never targeted, stays hidden", Other(rig, 3.2) == "  -> HIDDEN")

        rig = Dummies({ nameplate1 = "Player-1-0ABC", nameplate2 = "Player-1-0ABD" })
        Strike(rig, "nameplate1", LEARN)
        Check("dummies: a unit without a creature GUID never learns", Other(rig, 3.2) == "  -> HIDDEN")

        rig = Dummies({ nameplate1 = A1, nameplate2 = A2, nameplate3 = A3 })
        Strike(rig, "nameplate1", { 1, 1.5, 2, 2.5 })
        Strike(rig, "nameplate3", { 3.1 })
        Check("dummies: hits on two spawns of one ID do not add up", Other(rig, 3.2) == "  -> HIDDEN")

        rig = Dummies({ nameplate1 = Secret(A1), nameplate2 = A2 })
        local ok = pcall(Strike, rig, "nameplate1", LEARN)
        Check("dummies: a secret target GUID neither learns nor errors", ok and Other(rig, 3.2) == "  -> HIDDEN")

        rig = Dummies({ nameplate1 = A1, nameplate2 = A2 })
        Strike(rig, "nameplate1", LEARN)
        rig.Cast(10, "nameplate2")
        rig.S.target = "nameplate1"
        Check("dummies: a learned DoT's tick on a learned dummy still draws its icon",
            rig.Hit(10 + P, "nameplate2") == "tex:594")
    end

    -- 6. The crowd check: '?' by the area state (spec 2026-10-24, sections 4.1, 4.2, 5) -----------
    do
        -- A rig in `area` ("clear" | "crowded") with a fight open and a debug log; `rig.rows` counts
        -- Ledger.Add calls. Strike calls UNIT_COMBAT once and returns the texture drawn by that call.
        local function Crowd(area, setup)
            local rig = Rig(setup, true)
            rig.ns.Teacher.area = area
            rig.rows = 0
            local add = rig.ns.Ledger.Add
            rig.ns.Ledger.Add = function(...) rig.rows = rig.rows + 1 return add(...) end
            rig.ns.Core.PLAYER_REGEN_DISABLED()
            function rig.Strike(event, unit, amount)
                rig.S.now = 1
                local before = #rig.draws
                rig.ns.Core.UNIT_COMBAT(unit, event, "", amount, event == "HEAL" and 2 or 4)
                rig.ns.Core.FlushHeals(nil)
                return #rig.draws > before and rig.draws[#rig.draws].texture or nil
            end
            return rig
        end

        local rig = Crowd("clear")
        local texture = rig.Strike("WOUND", "nameplate1", 500)
        Check("crowd: clear -> an unexplained solo hit on a mob fighting you draws ? in the same call",
            texture == rig.ns.Meter.UNKNOWN_ICON and rig.Route() == ROUTE_UNKNOWN and rig.rows == 1)

        rig = Crowd("crowded")
        texture = rig.Strike("WOUND", "nameplate1", 500)
        Check("crowd: crowded -> the same hit draws nothing, adds no Ledger row, still reaches Teacher.Unknown",
            texture == nil and rig.rows == 0 and #rig.ns.Teacher.fight.unknown == 1 and rig.Route() == ROUTE_CROWDED)

        rig = Crowd("clear", function(S) S.threat.nameplate1 = false end)
        texture = rig.Strike("WOUND", "nameplate1", 500)
        Check("crowd: a hit on a mob not fighting you adds nothing to seen",
            rig.ns.Teacher.fight.seen == 0 and texture == nil and rig.Route() == "  -> HIDDEN")

        rig = Crowd("clear")
        rig.Strike("WOUND", "nameplate1", Secret(500))
        Check("crowd: a secret wound amount adds nothing to seen and keeps its route",
            rig.ns.Teacher.fight.seen == 0 and rig.Route() == ROUTE_UNKNOWN)

        rig = Crowd("clear")
        texture = rig.Strike("HEAL", "player", 500)
        Check("crowd: clear -> an unexplained heal on you draws ? at its frame's end",
            texture == rig.ns.Meter.UNKNOWN_ICON and rig.Route() == ROUTE_UNKNOWN and rig.rows == 1)

        rig = Crowd("crowded")
        texture = rig.Strike("HEAL", "player", 500)
        Check("crowd: crowded -> that heal stays hidden",
            texture == nil and rig.rows == 0 and rig.Route() == ROUTE_CROWDED)

        -- A wound drawn by a known spell (SW:P's first tick, learned) is still a wound seen.
        rig = Crowd("clear")
        rig.Cast(100, "nameplate1")
        texture = rig.Hit(100 + P, "nameplate1", 31)
        Check("crowd: a wound drawn by a known spell still adds to seen",
            texture == "tex:594" and rig.ns.Teacher.fight.seen == 31)

        -- The tracker names your DoT's tick on a mob that is neither your target nor fighting you: still yours.
        rig = Crowd("clear", function(S) S.threat.nameplate1 = false end)
        rig.Cast(100, "nameplate1")
        rig.S.target = nil
        texture = rig.Hit(100 + P, "nameplate1", 31)
        Check("crowd: a wound the tracker names adds to seen on a mob not fighting you",
            texture == "tex:594" and rig.ns.Teacher.fight.seen == 31)

        rig = Crowd("clear")
        rig.Strike("HEAL", "player", 500)
        Check("crowd: heals never add to seen", rig.ns.Teacher.fight.seen == 0)

        rig = Crowd("clear")
        texture = rig.Strike("HEAL", "party1", 500)
        Check("crowd: a party member's heal stays hidden even while clear", texture == nil and rig.Route() == "  -> HIDDEN")

        rig = Crowd("clear", function(S) S.group = true end)
        Check("crowd: in a group a hit and a heal stay hidden even while clear",
            rig.Strike("WOUND", "nameplate1", 500) == nil and rig.Route() == "  -> HIDDEN"
            and rig.Strike("HEAL", "player", 500) == nil and rig.Route() == "  -> HIDDEN")

        -- Grouped, Blizzard's numbers are on: a learned DoT's ticks the tracker names draw nothing, or they showed
        -- twice (2026-11-10 dungeon log: the addon drew only DoT ticks, 50 of 2861 hits).
        local function TickDraws(group)
            local ticks = Rig(function(S) S.group = group end)
            ticks.Cast(100, "nameplate1")
            local drawn = 0
            for k = 1, 3 do
                if ticks.Hit(100 + k * P, "nameplate1") then drawn = drawn + 1 end
            end

            return drawn
        end
        Check("group: a learned DoT's ticks draw solo but draw nothing in a group on Forever",
            TickDraws(false) == 3 and TickDraws(true) == 0)

        rig = Crowd("clear")
        rig.ns.Meter.Disable()
        Check("crowd: clear but meter disabled -> no ?",
            rig.Strike("WOUND", "nameplate1", 500) == nil and rig.Strike("HEAL", "player", 500) == nil)

        rig = Crowd("clear")
        rig.ns.Meter.Disable()
        texture = rig.Strike("WOUND", "nameplate1", 500)
        Check("crowd: clear but meter disabled -> a solo hit logs HIDDEN (meter off), nothing drawn",
            texture == nil and rig.Route() == ROUTE_METER_OFF and rig.rows == 0)

        rig = Crowd("clear")
        rig.ns.Meter.Disable()
        texture = rig.Strike("HEAL", "player", 500)
        Check("crowd: clear but meter disabled -> an own heal logs HIDDEN (meter off), nothing drawn",
            texture == nil and rig.Route() == ROUTE_METER_OFF and rig.rows == 0)

        for _, area in ipairs({ "clear", "crowded" }) do
            rig = Crowd(area)
            SlashCmdList.COMBATTEXTICONS("forget")
            Check("crowd: /cti forget leaves the state unchanged (" .. area .. " stays " .. area .. ")",
                rig.ns.Teacher.area == area)
            SlashCmdList.COMBATTEXTICONS("off")
            Check("crowd: /cti off leaves the state unchanged (" .. area .. " stays " .. area .. ")",
                rig.ns.Teacher.area == area and rig.ns.Teacher.fight == nil)
        end
    end

    do -- Blizzard's numbers follow group mode on Forever (spec 2026-11-07-forever-group-blizzard-text)
        local DAMAGE, HEALING = "floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatHealing_v2"
        local function Seed()
            return { [DAMAGE] = "1", floatingCombatTextCombatLogPeriodicSpells_v2 = "1",
                floatingCombatTextPetMeleeDamage_v2 = "1", floatingCombatTextPetSpellDamage_v2 = "1", [HEALING] = "2" }
        end
        local function Zeroed()
            local zeroed = {}
            for name in pairs(Seed()) do zeroed[name] = "0" end

            return zeroed
        end
        local function Same(a, b)
            for name, value in pairs(Seed()) do
                if a[name] ~= (b == "0" and "0" or value) then return false end
            end

            return true
        end
        -- Boots Forever (or retail with `retail`), grouped or solo, with `cvars` (default Seed()) and `saved`
        -- (CombatTextIconsDB, default none).
        local function Boot(group, cvars, saved, retail)
            local ns = T.Boot(function(S)
                if not retail then S.interface = 16001 end
                S.group = group
                S.cvars = cvars or Seed()
                CombatTextIconsDB = saved
            end)

            return ns, T.State()
        end

        local ns, S = Boot(false)
        Check("blizzard group: solo login zeroes the numbers and hides the scroll",
            Same(S.cvars, "0") and CombatText.shown == false and CombatTextIconsDB.savedCVars[HEALING] == "2")
        S.group = true
        ns.Core.GROUP_ROSTER_UPDATE()
        Check("blizzard group: joining a group writes the remembered numbers back, keeps them, the scroll stays hidden",
            Same(S.cvars) and CombatTextIconsDB.savedCVars[DAMAGE] == "1"
            and CombatTextIconsDB.savedCVars[HEALING] == "2" and CombatText.shown == false)
        S.group = false
        ns.Core.GROUP_ROSTER_UPDATE()
        Check("blizzard group: leaving the group zeroes them again with the same remembered values",
            Same(S.cvars, "0") and CombatTextIconsDB.savedCVars[DAMAGE] == "1"
            and CombatTextIconsDB.savedCVars[HEALING] == "2")

        _, S = Boot(true, Zeroed(), { enabled = true, savedCVars = Seed() })
        Check("blizzard group: a grouped login writes the remembered numbers and hides the scroll",
            Same(S.cvars) and CombatText.shown == false)

        ns, S = Boot(false)
        S.group = true
        ns.Core.GROUP_ROSTER_UPDATE()
        local applied = S.cvars[DAMAGE] == "1"
        S.cvars[DAMAGE] = "3"
        ns.Core.GROUP_ROSTER_UPDATE()
        ns.Core.PLAYER_REGEN_ENABLED()
        Check("blizzard group: a change made while grouped stays (it switches only on a mode change)",
            applied and S.cvars[DAMAGE] == "3")

        for _, failure in ipairs({ true, "error" }) do
            ns, S = Boot(false)
            S.cvarFail[HEALING] = failure
            S.group = true
            ns.Core.GROUP_ROSTER_UPDATE()
            local failed = S.cvars[HEALING] == "0"
            S.cvarFail[HEALING] = nil
            ns.Core.PLAYER_REGEN_ENABLED()
            Check("blizzard group: a failed write (" .. tostring(failure) .. ") is retried when the fight ends",
                failed and S.cvars[HEALING] == "2")
        end

        ns, S = Boot(true, nil, nil, true)
        local writes, set = 0, C_CVar.SetCVar
        C_CVar.SetCVar = function(...) writes = writes + 1 return set(...) end
        ns.Core.GROUP_ROSTER_UPDATE()
        ns.Core.PLAYER_REGEN_ENABLED()
        Check("blizzard group: retail keeps the numbers off in a group and writes nothing after login",
            Same(S.cvars, "0") and writes == 0)

        ns, S = Boot(true)
        SlashCmdList.COMBATTEXTICONS("off")
        local off = Same(S.cvars)
        ns.Core.GROUP_ROSTER_UPDATE()
        S.group = false
        ns.Core.GROUP_ROSTER_UPDATE()
        local untouched = Same(S.cvars)
        S.group = true
        SlashCmdList.COMBATTEXTICONS("on")
        Check("blizzard group: with the addon off nothing re-zeroes; /cti on in a group writes the numbers, scroll hidden",
            off and untouched and Same(S.cvars) and CombatText.shown == false)

        local ok
        ok, ns = pcall(Boot, true, {})
        S = T.State()
        Check("blizzard group: a first login in a group with nothing remembered writes nothing",
            ok and next(S.cvars) == nil)
    end

    T.RunFile("checks_locked.lua")
    T.RunFile("checks_ticks.lua")
    T.RunFile("checks_lockedheals.lua")
    T.RunFile("checks_ticks_replay.lua")
    T.RunFile("checks_core_replay.lua")
end
