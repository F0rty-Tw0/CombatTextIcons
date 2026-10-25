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
        function rig.Cast(t, unit) S.now, S.target = t, unit ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", SWP) end
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
        function rig.Learned() return CombatTextIconsCharDB.learned[SWP] ~= nil end
        return rig
    end

    -- 1. Crit size ----------------------------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        Streams.Feed("k", 32, 31, "", "enemy", 0)
        Streams.Feed("k", 32, 47, "CRITICAL", "enemy", 3)
        Streams.Feed("k", 32, 31, "", "enemy", 6)
        Streams.Feed("k", 32, 31, "", "enemy", 9)
        Check("forever: 31, 47 CRITICAL, 31, 31 at 3 s gaps form one stream (crit x1.5)", #Streams.Live("k", 9) == 1)
        Check("forever: NormalAmount(45, CRITICAL) = 30", Streams.NormalAmount(45, "CRITICAL") == 30)

        local Retail = T.Boot().Streams
        Retail.Feed("r", 32, 31, "", "enemy", 0)
        Retail.Feed("r", 32, 62, "CRITICAL", "enemy", 3)
        Retail.Feed("r", 32, 31, "", "enemy", 6)
        Retail.Feed("r", 32, 31, "", "enemy", 9)
        Retail.Feed("x", 32, 31, "", "enemy", 0)
        Retail.Feed("x", 32, 47, "CRITICAL", "enemy", 3)
        Retail.Feed("x", 32, 31, "", "enemy", 6)
        Retail.Feed("x", 32, 31, "", "enemy", 9)
        Check("retail: crits stay x2 (31, 62 CRITICAL, 31, 31 pair; 31, 47 CRITICAL, 31, 31 do not)",
            #Retail.Live("r", 9) == 1 and #Retail.Live("x", 9) == 0 and Retail.NormalAmount(62, "CRITICAL") == 31)

        local function Chain(streams, key, hits)
            for index, hit in ipairs(hits) do streams.Feed(key, 32, hit[1], hit[2] or "", "enemy", (index - 1) * 3) end
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

        rig.S.now = 10
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", 500, 2)
        local heal = Last("^HEAL ")
        Check("debug: a heal logs HEAL <unit> school= amount= flag= and its route",
            heal == "HEAL player school=2 amount=500 flag=" and log[#log] == ROUTE_UNKNOWN)
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
        Check("crowd: a hit on a mob not fighting you still adds to seen",
            rig.ns.Teacher.fight.seen == 500 and texture == nil and rig.Route() == "  -> HIDDEN")

        rig = Crowd("clear")
        rig.Strike("WOUND", "nameplate1", Secret(500))
        Check("crowd: a secret wound amount adds nothing to seen and keeps its route",
            rig.ns.Teacher.fight.seen == 0 and rig.Route() == ROUTE_UNKNOWN)

        rig = Crowd("clear")
        texture = rig.Strike("HEAL", "player", 500)
        Check("crowd: clear -> an unexplained heal on you draws ? at once",
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
end
