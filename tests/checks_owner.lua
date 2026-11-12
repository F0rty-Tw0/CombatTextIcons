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
end
