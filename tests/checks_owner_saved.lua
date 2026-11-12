-- Checks that a grouped fight Owner routes writes no saved table (Owner's hits run the solo routes, which would learn
-- from a group fight). Called by tests/checks.lua with the same T table.
return function(T)
    local Check, Secret = T.Check, T.Secret
    local Rig, _, P = dofile(T.Root .. "/tests/owner_rig.lua")(T)

    -- Forever booted with an empty character store; grouped when `group`, flipped after the boot (the guards read the
    -- group at call time). Returns the namespace and its store.
    local function Booted(group)
        local ns = T.Boot(function(S) S.interface = 16001 CombatTextIconsCharDB = {} end)
        T.State().group = group

        return ns, T.Store()
    end

    -- Meter session 69 holds the rows of `rows` ({ spellID, total } pairs), as the damage meter reports them.
    local function Meter(rows)
        C_DamageMeter.GetAvailableCombatSessions = function() return { { sessionID = 69 } } end
        C_DamageMeter.GetCombatSessionSourceFromID = function()
            local out = {}
            for index, row in ipairs(rows) do out[index] = { spellID = row[1], totalAmount = row[2] } end

            return { combatSpells = out }
        end
    end

    -- Locked bound to a fresh store holding `schools` (spellID -> entry), grouped or not.
    local function LockedFresh(group, schools)
        local ns = Booted(group)
        local store = { lockedSchools = schools or {} }
        ns.Locked.Init(store)

        return ns.Locked, store
    end

    -- Ticks bound to a fresh store holding `saved` (spellID -> entry), grouped or not.
    local function TicksFresh(saved, group)
        local ns = Booted(group)
        local store = { lockedTicks = saved or {} }
        ns.Ticks.Init(store)

        return ns.Ticks, store
    end

    -- A saved tick entry.
    local function Saved(period, kind, school) return { period = period, kind = kind, school = school, misses = 0 } end

    -- Procs bound to the store with rhythm 777 (school 106, band 300-400, period 1) learned, grouped or not. Returns Procs
    -- and the rhythm's row.
    local function ProcsFresh(group)
        local ns, store = Booted(group)
        ns.Procs.Init(store)
        ns.Procs.Teach(777, 106, 300, 400, 1, 0)

        return ns.Procs, store.procs[777]
    end

    local function Near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

    -- 3. Saved writes stay off while grouped (Owner's hits run the solo routes, which would learn from a group fight)
    do
        local function FirstHit(group)
            local L, store = LockedFresh(group)
            Meter({ { 591, 29 } })
            L.NoteCast(591, 10)
            local sole = L.Observe("p", 2, 10)

            return store, sole
        end
        local store, sole = FirstHit(false)
        Check("saved state: solo, the first hit's meter read teaches the spell its school (control)",
            store.lockedSchools[591] ~= nil and sole == 591)
        store, sole = FirstHit(true)
        Check("saved state: grouped, the first hit's meter read teaches nothing",
            next(store.lockedSchools) == nil and sole == nil)

        -- a stray: a hit of the entry's school with no cast of the spell in the window
        local function Stray(group)
            local L, store = LockedFresh(group, { [591] = { school = 2, strays = 1 } })
            Meter({})
            L.Observe("p", 2, 20)

            return store.lockedSchools[591]
        end
        local entry = Stray(false)
        Check("saved state: solo, a hit of the entry's school with no cast counts a stray and shares it (control)",
            entry.strays == 2 and entry.shared == true)
        entry = Stray(true)
        Check("saved state: grouped, the same stray changes the entry not at all",
            entry.strays == 1 and entry.shared == nil)

        local L, owned = LockedFresh(true, { [591] = { school = 2, strays = 0 } })
        Meter({})
        L.NoteCast(591, 10)
        local named, fits = L.Observe("p", 2, 10)
        Check("saved state: grouped, the own-school read still names the spell",
            named == 591 and fits == 1 and owned.lockedSchools[591].strays == 0)

        local function ThreeTicks(group)
            local X, store = TicksFresh(nil, group)
            X.NoteCast(594, 10, "p", "damage")
            X.Fits("p", "damage", 32, 13)
            X.Fits("p", "damage", 32, 16)

            return store.lockedTicks, X.Fits("p", "damage", 32, 19)
        end
        local saved, last = ThreeTicks(false)
        Check("saved state: solo, three cast-free ticks learn the period (control)", saved[594] ~= nil and #last == 1)
        saved, last = ThreeTicks(true)
        Check("saved state: grouped, the same ticks learn no period", next(saved) == nil and #last == 0)

        local function Refined(group)
            local X, store = TicksFresh({ [139] = Saved(3.034, "heal") }, group)
            X.NoteCast(139, 10, "player", "heal")
            for k = 1, 6 do
                local list = X.Fits("player", "heal", nil, 10 + 3 * k)
                if #list == 1 then X.Take(139, list[1].slot) end
            end

            return store.lockedTicks[139].period
        end
        Check("saved state: solo, taken ticks refine the period (control)", not Near(Refined(false), 3.034))
        Check("saved state: grouped, the same taken ticks leave the period alone", Near(Refined(true), 3.034))

        local function ThirdMiss(group)
            local X, store = TicksFresh({ [594] = Saved(3.0, "damage", 32) }, group)
            store.lockedTicks[594].misses = 2
            X.NoteCast(594, 10, "p", "damage")
            X.Fits("p", "damage", 32, 14.5)
            X.NoteCast(594, 20, "p", "damage")

            return store.lockedTicks[594]
        end
        local retired = ThirdMiss(false)
        Check("saved state: solo, a third missed cast retires the spell (control)", retired == nil)
        local kept = ThirdMiss(true)
        Check("saved state: grouped, the same missed cast counts no miss and retires nothing",
            kept and kept.misses == 2)

        local function Burst(group)
            local P, row = ProcsFresh(group)
            P.NoteCast(205180, 10)
            P.Drew(777, 11.5, 11.5)

            return row
        end
        local row = Burst(false)
        Check("saved state: solo, a burst's first tick learns the onset link of the cast that led it (control)",
            row.onset and row.onset[205180].n == 1)
        row = Burst(true)
        Check("saved state: grouped, the same burst learns no link", row.onset == nil)

        local function Lapsed(group)
            local P, row = ProcsFresh(group)
            row.onset = { [205180] = { lo = 1.5, hi = 1.5, n = 2 } }
            P.NoteCast(205180, 10)
            P.NameOnset(106, 350, "", 100)

            return row
        end
        row = Lapsed(false)
        Check("saved state: solo, a lead with no burst drops its link (control)", row.onset == nil)
        row = Lapsed(true)
        Check("saved state: grouped, the expired lead drops no link", row.onset ~= nil and row.onset[205180].n == 2)
    end

    -- Serializes a saved table with its keys sorted, so two states compare as text.
    local function Dump(value)
        if type(value) ~= "table" then return tostring(value) end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. Dump(value[key]) end

        return "{" .. table.concat(parts, ",") .. "}"
    end

    -- The saved tables learning writes: the schools, the tick periods and the rhythms.
    local function SavedState(store) return Dump(store.lockedSchools) .. Dump(store.lockedTicks) .. Dump(store.procs) end

    -- One fight on a Forever store holding a locked school, a saved tick period and a rhythm: casts at 100, 120 and 140,
    -- a tick, a school-2 stray, a no-fit hit, a rhythm burst after a lead cast and the fight's end (secret amounts, as on
    -- Forever, but the rhythm's). Grouped, Owner.Hit
    -- routes at once, as if every hit were owned. Returns the saved state before and after.
    local function Fight(solo)
        local rig = Rig({ solo = solo, off = solo, setup = function()
            local store = CombatTextIconsCharDB
            store.lockedSchools = { [591] = { school = 2, strays = 1 } }
            store.lockedTicks = { [589] = Saved(P, "damage", 32) }
        end })
        local ns = rig.ns
        if not solo then
            ns.Owner.Hit = function(plate, unit, flagText, amount, school, now)
                ns.HitRoute.Route({ kind = "hit", plate = plate, unit = unit, flagText = flagText, amount = amount,
                    school = school, now = now, isTarget = unit == rig.S.target, owned = true })
            end
        end
        ns.Procs.Teach(777, 106, 300, 400, 1, 0)
        local store = T.Store()
        local before = SavedState(store)
        rig.S.target = "nameplate1"
        rig.S.now = 99
        ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(100, "nameplate1", 589)
        rig.Hit(103.01, "nameplate1", Secret(31), 32)
        rig.Hit(110, "nameplate1", Secret(29), 2)
        rig.Cast(120, "nameplate1", 589)
        rig.Hit(124.5, "nameplate1", Secret(31), 32)
        rig.Cast(130, "nameplate1", 205180)
        rig.Hit(131.5, "nameplate1", 350, 106)
        rig.Cast(140, "nameplate1", 589)
        rig.S.now = 150
        ns.Core.PLAYER_REGEN_ENABLED()

        return before, SavedState(store)
    end

    do
        local before, after = Fight(false)
        local soloBefore, soloAfter = Fight(true)
        Check("owner wiring: a grouped fight with owned hits changes no saved table (Dump of lockedSchools, lockedTicks, procs equal before and after)",
            before == after)
        Check("owner wiring: the same fight solo does change the saved tables (the control is not vacuous)",
            soloBefore ~= soloAfter)
    end
end
