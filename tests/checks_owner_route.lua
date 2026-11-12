-- Checks for the owned hits' route (Owner -> HitRoute.Route): what Wound does with a hit Owner released. Called by
-- tests/checks.lua with the same T table. Every scenario boots its own rig; a Boot replaces the global stubs.
return function(T)
    local Check, Secret = T.Check, T.Secret
    local SWP, P = 594, 3.011735764150819 -- Shadow Word: Pain as learned in game (school 32)

    -- Forever with SW:P learned. Grouped unless opts.solo. Owner stubbed active (rig.on; opts.off starts inactive).
    -- Unless opts.realOwner, Owner.Hit only records its packed arguments in rig.taken. opts.setup(S) runs before load.
    local function Rig(opts)
        opts = opts or {}
        local rig = { draws = {}, log = {}, taken = {}, on = opts.off ~= true }
        rig.ns = T.Boot(function(S)
            S.interface = 16001
            S.group = opts.solo ~= true
            CombatTextIconsCharDB = { learned = { [SWP] = { school = 32, kind = "dot", period = P, misses = 0 } } }
            if opts.setup then opts.setup(S) end
        end)
        rig.S = T.State()
        local ns, S = rig.ns, rig.S
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(plate, texture) rig.draws[#rig.draws + 1] = { plate = plate, texture = texture } end
        ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
        ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
        ns.Owner.Active = function() return rig.on end
        ns.Owner.IsActive = function() return rig.on end
        if not opts.realOwner then ns.Owner.Hit = function(...) rig.taken[#rig.taken + 1] = table.pack(...) end end

        -- The plate the client holds for `unit`.
        function rig.Plate(unit) return C_NamePlate.GetNamePlateForUnit(unit) end

        -- Casts `spellID` (SW:P by default) at `t` aimed at `unit`.
        function rig.Cast(t, unit, spellID)
            S.now, S.target = t, unit
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", spellID or SWP)
        end

        -- A WOUND event on `unit` at `t`, as the client sends it; returns the texture drawn or nil.
        function rig.Hit(t, unit, amount, school, flag)
            S.now = t
            local before = #rig.draws
            ns.Core.UNIT_COMBAT(unit, "WOUND", flag or "", amount or 31, school or 32)

            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        -- A hit as Owner releases it.
        function rig.Snap(t, unit, amount, school, isTarget)
            return { kind = "hit", plate = rig.Plate(unit), unit = unit, flagText = "", amount = amount, school = school,
                now = t, isTarget = isTarget, owned = true }
        end

        -- The texture HitRoute.Route draws for a released hit, or nil when it stayed hidden.
        function rig.Route(hit)
            local before = #rig.draws
            ns.HitRoute.Route(hit)

            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        -- Whether a debug line starts with `prefix`.
        function rig.Logged(prefix)
            for _, line in ipairs(rig.log) do
                if line:sub(1, #prefix) == prefix then return true end
            end

            return false
        end

        -- The last route line ("  ->") of the debug log.
        function rig.LastRoute()
            for index = #rig.log, 1, -1 do
                if rig.log[index]:find("^  %->") then return rig.log[index] end
            end
        end

        return rig
    end

    -- What Teacher.Seen gets as its isTarget when a snapshot saying `isTarget` is routed while the unit token answers
    -- `targetNow` (the unit the player targets, or nil).
    local function SeenTarget(isTarget, targetNow)
        local rig = Rig()
        local seen
        local Seen = rig.ns.Teacher.Seen
        rig.ns.Teacher.Seen = function(amount, now, school, plate, target)
            seen = target

            return Seen(amount, now, school, plate, target)
        end
        rig.S.target = targetNow
        rig.Route(rig.Snap(300, "nameplate1", Secret(31), 32, isTarget))

        return seen
    end

    -- 1. Owned hits go through Wound as solo
    do
        local rig = Rig()
        local amount = Secret(31)
        rig.S.target = "nameplate1"
        rig.Hit(100, "nameplate1", amount, 32, "CRITICAL")
        local args = rig.taken[1]
        Check("owner route: an active Owner takes a plate WOUND at arrival, with Owner.Hit's arguments",
            #rig.taken == 1 and args[1] == rig.Plate("nameplate1") and args[2] == "nameplate1" and args[3] == "CRITICAL"
            and rawequal(args[4], amount) and args[5] == 32 and args[6] == 100)
        Check("owner route: Wound has not run for it (no frame entry, no draw, no HIT line)",
            #rig.ns.HitRoute.FrameHits(100) == 0 and #rig.draws == 0 and not rig.Logged("HIT "))

        rig = Rig()
        rig.ns.Core.UNIT_COMBAT("nameplate1", "MISS", "", 0, 0)
        Check("owner route: a miss never goes to Owner", #rig.taken == 0)

        rig = Rig({ off = true })
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("owner route: an inactive Owner leaves the hit to Wound, which draws nothing grouped",
            #rig.taken == 0 and rig.Logged("HIT nameplate1") and #rig.draws == 0 and rig.LastRoute() == "  -> HIDDEN")

        -- an owned grouped tracker tick draws what the same hit draws solo
        rig = Rig()
        rig.Cast(100, "nameplate1")
        rig.S.now = 100 + P + 0.05
        local owned = rig.Route(rig.Snap(100 + P, "nameplate1", 31, 32, true))
        local solo = Rig({ solo = true, off = true })
        solo.Cast(100, "nameplate1")
        solo.Hit(100 + P, "nameplate1", 31, 32)
        Check("owner route: an owned grouped tracker tick draws SW:P, as solo",
            owned == "tex:" .. SWP and solo.draws[1] and solo.draws[1].texture == "tex:" .. SWP)

        rig = Rig()
        rig.S.threat.nameplate3 = false -- a mob that does not fight you: still yours once owned
        local question = rig.Route(rig.Snap(200, "nameplate3", Secret(31), 1, false))
        Check("owner route: an owned grouped hit nothing names draws '?' (route unknown-solo)",
            question == rig.ns.Meter.UNKNOWN_ICON and rig.LastRoute() == "  -> unknown-solo")

        rig = Rig()
        rig.S.threat.nameplate3 = false
        local counted = 0
        local Seen = rig.ns.Teacher.Seen
        rig.ns.Teacher.Seen = function(...)
            counted = counted + 1

            return Seen(...)
        end
        rig.Route(rig.Snap(200, "nameplate3", Secret(31), 1, false))
        Check("owner route: an owned hit counts for the crowd check though its mob has no threat on you", counted == 1)

        rig = Rig()
        rig.Cast(100, "nameplate1")
        rig.on = false
        Check("owner route: an owned hit routed after Owner turned inactive draws nothing",
            rig.Route(rig.Snap(100 + P, "nameplate1", 31, 32, true)) == nil)

        rig = Rig({ solo = true })
        rig.S.now = 50
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        local startedSolo = rig.ns.Teacher.fight.group == false
        rig.S.group = true
        rig.Route(rig.Snap(51, "nameplate1", Secret(31), 32, true))
        Check("owner route: an owned hit still marks the fight grouped (Teacher.Grouped)",
            startedSolo and rig.ns.Teacher.fight.group == true)

        Check("owner route: Teacher.Seen gets the snapshot's isTarget, not the unit token's answer at release",
            SeenTarget(true, nil) == true and SeenTarget(false, "nameplate1") == false)

        rig = Rig()
        rig.Route(rig.Snap(300, "nameplate1", Secret(31), 32, true))
        Check("owner route: Wound writes no HIT line for an owned hit", not rig.Logged("HIT "))

        -- the full path with the real Owner: Core -> Owner.Hit (held) -> line -> release -> solo route
        rig = Rig({ realOwner = true })
        rig.Cast(100, "nameplate1")
        rig.Hit(100 + P, "nameplate1", Secret(31), 32)
        rig.ns.Owner.Line(0, 100 + P)
        rig.S.now = 100 + P + 0.06
        rig.ns.Owner.Flush(100 + P + 0.06)
        local viaOwner = rig.draws[#rig.draws] and rig.draws[#rig.draws].texture
        Check("owner route: an owned grouped hit draws a learned cast as solo",
            viaOwner == "tex:" .. SWP and viaOwner == solo.draws[1].texture)
    end

    -- Routes a released SW:P tick stamped `at` while the game clock reads at + 0.05; the route clock is set to `at`
    -- when `clock`. Returns the spellID on the frame entry at `at`, the `now` Teacher.Drawn and Heals.Struck got, `at`.
    local function Released(clock)
        local rig = Rig()
        local drewAt, struckAt
        local Drawn, Struck = rig.ns.Teacher.Drawn, rig.ns.Heals.Struck
        rig.ns.Teacher.Drawn = function(spellID, amount, now, school)
            drewAt = now

            return Drawn(spellID, amount, now, school)
        end
        rig.ns.Heals.Struck = function(spellID, now)
            struckAt = now

            return Struck(spellID, now)
        end
        rig.Cast(100, "nameplate1")
        local at = 100 + P
        rig.S.now = at + 0.05
        if clock then rig.ns.SetRouteClock(at) end
        rig.Route(rig.Snap(at, "nameplate1", 31, 32, true))
        rig.ns.SetRouteClock(nil)
        local entry = rig.ns.HitRoute.FrameHits(at)[1]

        return entry and entry.spellID, drewAt, struckAt, at
    end

    -- 2. A released hit is judged at its own stamp
    do
        local tagged, drewAt, struckAt, at = Released(true)
        Check("route clock: a released hit's Drawn tags its own frame entry", tagged == SWP)
        Check("route clock: Teacher.Drawn and Heals.Struck get the hit's stamp, not the release time",
            drewAt == at and struckAt == at)
        tagged, drewAt = Released(false)
        Check("route clock: with no clock set Drawn still reads the game clock (the release time misses the entry)",
            tagged == nil and drewAt ~= at)
        local source = assert(io.open(T.Root .. "/HitRoute.lua", "rb")):read("a")
        Check("route clock: HitRoute.lua reads no GetTime of its own", not source:find("GetTime", 1, true))
    end

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
end
