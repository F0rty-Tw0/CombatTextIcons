-- Checks for Owner (grouped Forever ownership by Combat Log lines). Called by tests/checks.lua with the same T table.
return function(T)
    local Check = T.Check

    -- 1.1 Own schools and the route clock
    do
        local ns = T.Boot(function()
            CombatTextIconsCharDB = { lockedSchools = {
                [589] = { school = 32, strays = 0 }, [17] = { school = 32, strays = 0 },
                [2061] = { school = 2, strays = 1, shared = true } } }
        end)
        local set = ns.Locked.Schools()
        Check("owner: Locked.Schools lists each saved school once, shared too", set[32] == true and set[2] == true and (function() local n = 0 for _ in pairs(set) do n = n + 1 end return n end)() == 2)
        set[99] = true
        Check("owner: Locked.Schools hands out a copy", ns.Locked.Schools()[99] == nil)
        local S = T.State()
        S.now = 10
        Check("owner: ns.Now is GetTime by default", ns.Now() == 10)
        ns.SetRouteClock(7.5)
        S.now = 11
        Check("owner: ns.Now answers the route clock while set", ns.Now() == 7.5)
        ns.SetRouteClock(nil)
        Check("owner: ns.Now returns to GetTime when cleared", ns.Now() == 11)
        local fresh = T.Boot()
        Check("owner: Locked.Schools is empty with nothing saved", next(fresh.Locked.Schools()) == nil)
    end

    -- 1.2 Matcher
    do
        local Match = T.Boot().Owner.Match
        local OWN = { [32] = true }
        local function H(now, school, isTarget) return { kind = "hit", now = now, school = school, isTarget = isTarget or false } end
        local function Heal(now) return { kind = "heal", now = now, school = 1, isTarget = false } end
        local taken, clean

        taken, clean = Match({ { now = 10 } }, { H(10, 1), H(10, 32, true) }, OWN)
        Check("match: the own-school target hit (7) takes the line over a stranger's", taken[2] == 1 and taken[1] == nil)
        Check("match: two events for one line is not clean", clean[1] == nil)
        taken, clean = Match({ { now = 10 } }, { H(10, 32, true) }, OWN)
        Check("match: one event, one line is clean", taken[1] == 1 and clean[1] == true)
        taken = Match({ { now = 10 } }, { H(10, 32), H(10, 32) }, OWN)
        Check("match: a tie takes the first arrival", taken[1] == 1 and taken[2] == nil)
        taken = Match({ { now = 10 }, { now = 10 } }, { H(10, 1), H(10, 32), H(10, 32, true) }, OWN)
        Check("match: n lines take the n best events", taken[3] == 1 and taken[2] == 2 and taken[1] == nil)
        taken = Match({ { now = 10 } }, { H(10, 1, true), Heal(10) }, OWN)
        Check("match: a heal (3) beats an other-school hit on target (2)", taken[2] == 1 and taken[1] == nil)
        taken = Match({ { now = 10 } }, { H(10, 32), Heal(10) }, OWN)
        Check("match: an own-school hit off target (4) beats a heal (3)", taken[1] == 1 and taken[2] == nil)
        taken = Match({ { now = 10 } }, { H(10, 1), Heal(10) }, OWN)
        Check("match: a heal takes the line from a stranger's hit (0)", taken[2] == 1)
        taken = Match({ { now = 10 } }, { H(10, 1), H(10, 5) }, nil)
        Check("match: own = nil scores every school own, ties keep arrival", taken[1] == 1)
        taken = Match({ { now = 10 } }, { Heal(10.03) }, OWN)
        Check("match: heals are pass-1 only", next(taken) == nil)
        taken, clean = Match({ { now = 10.03 } }, { H(10, 32) }, OWN)
        Check("match: a late line (hit 0.03 s before) pairs in pass 2, not clean", taken[1] == 1 and clean[1] == nil)
        taken = Match({ { now = 10 } }, { H(10.03, 32) }, OWN)
        Check("match: a late hit (0.03 s after the line) pairs in pass 2", taken[1] == 1)
        taken = Match({ { now = 10.05 } }, { H(10, 32) }, OWN)
        Check("match: exactly 0.05 s apart still pairs", taken[1] == 1)
        taken = Match({ { now = 10.06 } }, { H(10, 32) }, OWN)
        Check("match: 0.06 s apart pairs nothing", next(taken) == nil)
        taken = Match({ { now = 10.03 } }, { H(10, 32), H(10.02, 32), H(10.05, 32) }, OWN)
        Check("match: pass 2 takes the closest of equal scores", taken[2] == 1)
        taken = Match({ { now = 10 }, { now = 10.03 } }, { H(10, 32), H(10.03, 32) }, OWN)
        Check("match: pass 1 keeps each stamp's own hit, pass 2 does not steal", taken[1] == 1 and taken[2] == 2)
    end

    -- 1.3 Holding and release
    do
        local function Rig()
            local rig = { routes = {}, clocks = {}, heals = 0, log = {} }
            rig.ns = T.Boot(function() CombatTextIconsCharDB = { lockedSchools = { [589] = { school = 32, strays = 0 } } } end)
            rig.S = T.State()
            local ns = rig.ns
            ns.HitRoute.Route = function(hit) rig.routes[#rig.routes + 1] = hit rig.clocks[#rig.clocks + 1] = ns.Now() end
            ns.PlayerHits.FlushHeals = function(now) rig.heals = rig.heals + 1 rig.healAt = now end
            ns.Debug = function(fmt, ...) rig.log[#rig.log + 1] = string.format(fmt, ...) end
            return rig
        end
        local function Hit(rig, unit, now, school) rig.ns.Owner.Hit("plate-" .. unit, unit, "", 5, school or 32, now) end
        local function Logged(rig, text) for _, line in ipairs(rig.log) do if line:find(text, 1, true) then return true end end end
        local rig, Owner

        rig = Rig() Owner = rig.ns.Owner
        rig.S.timers = {}
        local before = #rig.S.timers
        Hit(rig, "nameplate1", 10)
        Check("owner: a held hit queues the frame-end flush", #rig.S.timers == before + 1)
        Hit(rig, "nameplate2", 10, 1)
        Check("owner: HIT debug line is written at arrival, owned or not", Logged(rig, "HIT nameplate1") and Logged(rig, "HIT nameplate2") and #rig.routes == 0)
        Owner.Line(0, 10)
        Owner.Flush(10.06)
        Check("owner: the own-school hit with a line routes owned, the stranger's drops", #rig.routes == 1 and rig.routes[1].unit == "nameplate1" and rig.routes[1].owned == true)
        Check("owner: a released hit routes on its own stamp (route clock)", rig.clocks[1] == 10 and rig.ns.Now() == rig.S.now)
        Check("owner: unowned hits log HIDDEN (not yours)", Logged(rig, "  -> HIDDEN (not yours)"))
        Check("owner: FlushHeals(now) runs after the stamp releases, with Flush's now", rig.heals == 1 and rig.healAt == 10.06)
        Check("owner: nothing waits after release", Owner.Waiting() == false and Owner.Pending(10) == false)

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10)
        Owner.Flush(10.03)
        Check("owner: a hit with no line waits inside 0.05 s", #rig.routes == 0 and Owner.Pending(10) == true and Owner.Waiting() == true)
        Owner.Line(0, 10.03)
        Owner.Flush(10.04)
        Check("owner: a late line owns the held hit (pass 2)", #rig.routes == 1)
        rig = Rig() Owner = rig.ns.Owner
        Owner.Line(0, 10)
        Hit(rig, "nameplate1", 10.03)
        Owner.Flush(10.04)
        Check("owner: a late hit takes the waiting line (pass 2)", #rig.routes == 1)
        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10)
        Owner.Flush(10.05)
        Check("owner: 0.05 s old is still held (strict past 0.05)", #rig.routes == 0 and Owner.Pending(10) == true)
        Owner.Flush(10.06)
        Check("owner: past 0.05 s the leftover is dropped", #rig.routes == 0 and Owner.Pending(10) == false and Owner.Waiting() == false)

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10, 1)          -- stamp A: no line, held
        Hit(rig, "nameplate2", 10.01)           -- stamp B: owned by its line
        Owner.Line(0, 10.01)
        Owner.Flush(10.03)
        Check("owner: a later owned stamp waits behind an older unreleased one", #rig.routes == 0)
        Owner.Flush(10.06)
        Check("owner: then A drops and B routes, in stamp order", #rig.routes == 1 and rig.routes[1].unit == "nameplate2")

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10)
        Owner.Flush(10.02, true)
        Check("owner: force releases every older stamp at once, leftovers dropped", #rig.routes == 0 and Owner.Pending(10) == false)
        Hit(rig, "nameplate1", 11) Owner.Line(0, 11)
        Owner.Flush(nil)
        Check("owner: Flush(nil) releases an unsettled stamp", #rig.routes == 1)

        rig = Rig() Owner = rig.ns.Owner
        Owner.Line(1, 10) Hit(rig, "nameplate1", 10) Owner.Flush(nil)
        Check("owner: a backlog line (order 1) pairs nothing", #rig.routes == 0)
        Hit(rig, "nameplate1", 12) Owner.Line(0, 12) Owner.PlateGone("plate-nameplate1") Owner.Flush(nil)
        Check("owner: a plate gone before release draws nothing", #rig.routes == 0)
        Hit(rig, "nameplate1", 13) Owner.Line(0, 13) Owner.Drop() Owner.Flush(nil)
        Check("owner: Drop forgets held hits without routing", #rig.routes == 0 and Owner.Waiting() == false)

        rig = Rig() Owner = rig.ns.Owner
        Owner.Heal("player", 10) Owner.Heal("player", 10) Owner.Heal("party1", 10)
        Owner.Line(0, 10)
        Owner.Flush(10.02)
        Check("owner: one line owns the first heal on you, the rest stay unowned", Owner.HealOwned(10, 1) == true and Owner.HealOwned(10, 2) == false)
        rig = Rig() Owner = rig.ns.Owner
        Owner.Heal("party1", 10) Hit(rig, "nameplate1", 10, 1) Owner.Line(0, 10)
        Owner.Flush(10.02)
        Check("owner: a party heal takes the stamp's line from a stranger's hit", #rig.routes == 0)

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10) Owner.Line(0, 10)
        rig.ns.HitRoute.Route = function(hit) rig.routes[#rig.routes + 1] = hit Owner.Flush(nil) end
        Owner.Flush(10.02)
        Check("owner: Flush called from inside a release does not recurse", #rig.routes == 1)
        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10) Hit(rig, "nameplate2", 10) Owner.Line(0, 10) Owner.Line(0, 10)
        local calls = 0
        rig.ns.HitRoute.Route = function() calls = calls + 1 if calls == 1 then error("route broke") end end
        rig.S.now = 10.02
        Owner.Flush(10.02)
        Check("owner: a failing route resets the clock and the next hit still routes", calls == 2 and rig.ns.Now() == 10.02)
    end

    -- 1.5 Pass 2 waits for the stamp to settle (run 2: a line spent on an older hit before its own stamp's hit came)
    do
        local function Rig()
            local rig = { routes = {} }
            rig.ns = T.Boot(function() CombatTextIconsCharDB = { lockedSchools = { [589] = { school = 32, strays = 0 } } } end)
            rig.ns.HitRoute.Route = function(hit) rig.routes[#rig.routes + 1] = hit end
            rig.ns.PlayerHits.FlushHeals = function() end
            return rig
        end
        local function Hit(rig, unit, now) rig.ns.Owner.Hit("plate-" .. unit, unit, "", 5, 32, now) end
        local rig, Owner

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10)
        Owner.Line(0, 10.034)
        Owner.Flush(10.034)
        Hit(rig, "nameplate2", 10.034)
        Owner.Flush(10.1)
        Check("owner: a line on an open stamp waits for its own hit, not an older one", #rig.routes == 1 and rig.routes[1].unit == "nameplate2")
        Check("owner: then nothing waits", Owner.Waiting() == false)

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10.02)
        Owner.Line(0, 10.03) Owner.Line(0, 10.03) Owner.Line(0, 10.03)
        Owner.Flush(10.03)
        Owner.Heal("party1", 10.03)
        Owner.Flush(10.03)
        Hit(rig, "nameplate2", 10.03)
        Owner.Flush(10.03)
        Owner.Heal("player", 10.03)
        Owner.Flush(10.1)
        Check("owner: three lines on an open stamp keep all three for its three events", Owner.HealOwned(10.03, 1) == true and #rig.routes == 1 and rig.routes[1].unit == "nameplate2")

        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10)
        Owner.Line(0, 10.03)
        Owner.Flush(10.04, true)
        Check("owner: a forced flush still pairs a settled late line first", #rig.routes == 1)
        rig = Rig() Owner = rig.ns.Owner
        Hit(rig, "nameplate1", 10)
        Owner.Line(0, 10.03)
        Owner.Flush(10.03, true)
        Hit(rig, "nameplate2", 10.03)
        Owner.Flush(10.1)
        Check("owner: a forced flush keeps a line on its own stamp open; the older hit drops", #rig.routes == 1 and rig.routes[1].unit == "nameplate2")
    end

    -- 1.4 Active, switch-on and liveness
    do
        local function Rig(interface, group)
            local rig = { on = false, setCalls = {}, syncs = 0, routes = 0, shown = false }
            IsInRaid, C_CombatLog, Blizzard_CombatLog_Filters, COMBATLOG = nil, nil, nil, nil -- clean boot: from Task 2.4 PLAYER_LOGIN calls Owner.KeepLinesOn
            rig.ns = T.Boot(function(S) S.interface = interface or 16001 S.group = group ~= false end)
            rig.S = T.State()
            IsInRaid = function() return false end
            C_CombatLog = {
                AreFilteredEventsEnabled = function() return rig.on end,
                SetFilteredEventsEnabled = function(value)
                    if rig.setError then error("refused") end
                    rig.on = value rig.setCalls[#rig.setCalls + 1] = value
                end,
            }
            Blizzard_CombatLog_Filters = { currentFilter = 1, filters = { { name = "My actions" } } }
            COMBATLOG = { IsShown = function() return rig.shown end }
            rig.ns.Core.SyncBlizzard = function() rig.syncs = rig.syncs + 1 end
            rig.ns.HitRoute.Route = function() rig.routes = rig.routes + 1 end
            rig.ns.PlayerHits.FlushHeals = function() end
            return rig
        end
        local function Clean() IsInRaid, C_CombatLog, Blizzard_CombatLog_Filters, COMBATLOG = nil, nil, nil, nil end
        local rig, Owner

        rig = Rig() Owner = rig.ns.Owner
        Check("active: lines never switched on -> not active", Owner.Active() == false)
        Check("active: KeepLinesOn switches them on and says so", Owner.KeepLinesOn() == "switched" and rig.on == true)
        Check("active: Forever, party, lines on, My actions -> active", Owner.Active() == true and Owner.IsActive() == true)
        Check("active: KeepLinesOn reports on when already on", Owner.KeepLinesOn() == "on")
        rig.syncs = 0
        Owner.Active()
        Check("active: an unchanged answer does not sync again", rig.syncs == 0)
        Blizzard_CombatLog_Filters.filters[1].name = "Everything"
        Check("active: IsActive is the cached read, no recompute", Owner.IsActive() == true)
        Check("active: another filter -> not active, and Blizzard sync ran", Owner.Active() == false and rig.syncs == 1)
        Blizzard_CombatLog_Filters = nil
        Check("active: no filter table -> not active", Owner.Active() == false)
        Blizzard_CombatLog_Filters = { currentFilter = 1, filters = { { name = "My actions" } } }
        IsInRaid = function() return true end
        Check("active: raid -> not active", Owner.Active() == false)
        IsInRaid = function() error("restricted") end
        Check("active: a failing IsInRaid counts as raid", Owner.Active() == false)
        IsInRaid = nil
        Check("active: no IsInRaid counts as raid", Owner.Active() == false)
        Clean()

        rig = Rig(120105) Owner = rig.ns.Owner Owner.KeepLinesOn()
        Check("active: retail -> never active", Owner.Active() == false)
        Clean()
        rig = Rig(16001, false) Owner = rig.ns.Owner Owner.KeepLinesOn()
        Check("active: solo -> not active", Owner.Active() == false)
        Clean()
        rig = Rig() Owner = rig.ns.Owner C_CombatLog = nil
        Check("active: C_CombatLog missing -> KeepLinesOn none, not active", Owner.KeepLinesOn() == "none" and Owner.Active() == false)
        Clean()
        rig = Rig() Owner = rig.ns.Owner rig.setError = true
        Check("active: switch-on refused -> err, not active", Owner.KeepLinesOn() == "err" and Owner.Active() == false)
        Clean()

        -- LinesOff
        rig = Rig() Owner = rig.ns.Owner Owner.KeepLinesOn() Owner.LinesOff()
        Check("lines: LinesOff switches off what Owner switched on", rig.setCalls[#rig.setCalls] == false)
        rig = Rig() Owner = rig.ns.Owner rig.on = true Owner.KeepLinesOn() Owner.LinesOff()
        Check("lines: LinesOff leaves lines Owner did not switch on", #rig.setCalls == 0)
        rig = Rig() Owner = rig.ns.Owner Owner.KeepLinesOn() rig.shown = true Owner.LinesOff()
        Check("lines: LinesOff leaves them on while the Combat Log tab shows", #rig.setCalls == 1)
        Clean()

        -- Liveness
        rig = Rig() Owner = rig.ns.Owner Owner.KeepLinesOn() Owner.Active()
        local S = rig.S
        S.timers = {}
        Owner.Cast(1) Owner.Cast(1.5)
        Check("live: two casts start no check", #S.timers == 0)
        Owner.Cast(2) Owner.Cast(2.5)
        Check("live: the third cast starts one 2 s check, no more", #S.timers == 1 and S.timers[1].delay == 2)
        S.timers[1].fn()
        Check("live: 3 casts and no line -> dead -> not active", Owner.Active() == false)
        Owner.Line(1, 5)
        Check("live: a backlog line does not revive", Owner.Active() == false)
        Owner.Line(0, 5)
        Check("live: a live line clears dead -> active again", Owner.Active() == true)
        S.timers = {}
        Owner.Cast(6) Owner.Cast(6.5) Owner.Cast(7)
        Owner.Line(0, 7.5)
        S.timers[1].fn()
        Check("live: a line between the casts and the check -> still active", Owner.Active() == true)
        Owner.Cast(8) Owner.Cast(8.5) Owner.Flush(nil)
        Owner.Cast(9)
        Check("live: Flush(nil) resets the cast count (fight end)", #S.timers == 1)

        -- Flip false mid-flush (Review Focus 4)
        rig = Rig() Owner = rig.ns.Owner Owner.KeepLinesOn() Owner.Active()
        Owner.Hit("p1", "nameplate1", "", 5, 32, 10) Owner.Line(0, 10) Owner.Hit("p2", "nameplate2", "", 5, 32, 10.0)
        local seen = {}
        rig.ns.HitRoute.Route = function(hit) seen[#seen + 1] = hit.unit Owner.Active() end
        Blizzard_CombatLog_Filters.filters[1].name = "Everything"
        rig.syncs = 0
        Check("active: turning false returns false", Owner.Active() == false)
        Check("active: flipping false routes the held owned hit once, no recursion", #seen == 1 and rig.syncs == 1)
        Check("active: the flip's flush left nothing waiting", Owner.Waiting() == false)
        Clean()
    end
end
