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
end
