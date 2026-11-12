-- Checks for the owned hits' route (Owner -> HitRoute.Route): what Wound does with a hit Owner released. Called by
-- tests/checks.lua with the same T table. Every scenario boots its own rig; a Boot replaces the global stubs.
return function(T)
    local Check, Secret = T.Check, T.Secret
    local SWP, P = 594, 3.011735764150819 -- Shadow Word: Pain as learned in game (school 32)

    -- Forever (opts.interface: another build) with SW:P learned. Grouped unless opts.solo. Owner stubbed active (rig.on;
    -- opts.off starts inactive).
    -- Unless opts.realOwner, Owner.Hit only records its packed arguments in rig.taken. opts.setup(S) runs before load.
    local function Rig(opts)
        opts = opts or {}
        local rig = { draws = {}, log = {}, taken = {}, on = opts.off ~= true }
        rig.ns = T.Boot(function(S)
            S.interface = opts.interface or 16001
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

    -- 4. Core wires Owner in (Core.lua, BlizzardText.lua, PlayerHits.lua)

    -- Registers the frames CreateFrame makes in rec.frames, each keeping the events it registered in .registered. The
    -- event `failEvent` raises an error when registered, as the client does for an event it does not know.
    local function RecordFrames(rec, failEvent)
        local make = CreateFrame
        rec.frames = {}
        local function Register(frame, event)
            if event == failEvent then error("unknown event " .. event) end
            frame.registered[event] = true
        end
        CreateFrame = function(...)
            local frame = make(...)
            frame.registered, frame.RegisterEvent, frame.RegisterUnitEvent = {}, Register, Register
            rec.frames[#rec.frames + 1] = frame

            return frame
        end
    end

    -- The frame Core registered its events on.
    local function CoreFrame(rec)
        for _, frame in ipairs(rec.frames) do
            if frame.registered.PLAYER_LOGIN then return frame end
        end
    end

    -- A Rig whose Owner, Core, TowHold, Locked and Ticks entry points record each call in rig.calls as
    -- { name, args... } (Owner.Active and Owner.Waiting answer rig.on and rig.waiting; KeepLinesOn runs on). The
    -- PlayerHits and HitRoute flush entry points QueueFlush calls are "QueueHeals" and "QueueMates".
    local function Wired(opts)
        local rig = Rig(opts)
        local ns = rig.ns
        rig.calls, rig.waiting = {}, false

        local function Spy(owner, field, name, answer, through)
            local original = owner[field]
            owner[field] = function(...)
                rig.calls[#rig.calls + 1] = table.pack(name, ...)
                if answer then return answer() end
                if through then return original(...) end
            end
        end
        for _, field in ipairs({ "Flush", "Heal", "Cast", "LinesOff", "PlateGone", "Drop", "Line" }) do
            Spy(ns.Owner, field, field)
        end
        Spy(ns.Owner, "KeepLinesOn", "KeepLinesOn", nil, true)
        Spy(ns.Owner, "Active", "Active", function() return rig.on end)
        Spy(ns.Owner, "Waiting", "Waiting", function() return rig.waiting end)
        Spy(ns.Core, "FlushHeals", "FlushHeals")
        Spy(ns.Core, "FlushMates", "FlushMates")
        Spy(ns.Core, "Heal", "CoreHeal")
        Spy(ns.Core, "SyncBlizzard", "SyncBlizzard")
        Spy(ns.PlayerHits, "FlushHeals", "QueueHeals")
        Spy(ns.HitRoute, "FlushMates", "QueueMates")
        Spy(ns.TowHold, "Decide", "Decide")
        Spy(ns.Locked, "NoteCast", "NoteCast")
        Spy(ns.Ticks, "NoteCast", "TickCast")

        -- The index of the first call named `name`.
        function rig.Index(name)
            for index, call in ipairs(rig.calls) do
                if call[1] == name then return index end
            end
        end

        -- Whether the first call named `first` comes before the first named `second`.
        function rig.Before(first, second)
            local a, b = rig.Index(first), rig.Index(second)

            return a ~= nil and b ~= nil and a < b
        end

        function rig.Call(name) return rig.calls[rig.Index(name)] end

        function rig.Count(name)
            local count = 0
            for _, call in ipairs(rig.calls) do
                if call[1] == name then count = count + 1 end
            end

            return count
        end

        return rig
    end

    do
        local rig = Wired()
        rig.S.now = 100
        rig.ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 31, 32)
        local flush = rig.Call("Flush")
        Check("wiring: UNIT_COMBAT flushes Owner before the heals",
            flush and flush[2] == 100 and flush[3] == nil and rig.Before("Flush", "FlushHeals")
            and rig.Before("Flush", "FlushMates") and rig.Before("Flush", "Decide"))

        rig = Wired()
        rig.S.now = 100
        rig.ns.Core.UNIT_COMBAT("party2", "HEAL", "", 50, 2)
        local healCall = rig.Call("Heal")
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", 50, 2)
        Check("wiring: a HEAL on party2 is fed to Owner.Heal(unit, now) while Active",
            healCall and healCall[2] == "party2" and healCall[3] == 100 and rig.Before("Heal", "CoreHeal")
            and rig.Count("Heal") == 2 and rig.calls[rig.Index("CoreHeal") - 1][1] == "Heal")

        rig = Wired({ off = true })
        rig.S.now = 100
        rig.ns.Core.UNIT_COMBAT("party2", "HEAL", "", 50, 2)
        Check("wiring: no Owner.Heal feed while Owner is inactive", rig.Count("Heal") == 0 and rig.Count("CoreHeal") == 1)

        rig = Wired()
        rig.Cast(100, "nameplate1")
        local forced = rig.Call("Flush")
        Check("wiring: a player cast flushes Owner with force before FlushHeals/FlushMates/TowHold.Decide",
            forced and forced[2] == 100 and forced[3] == true and rig.Before("Flush", "FlushHeals")
            and rig.Before("Flush", "FlushMates") and rig.Before("Flush", "Decide") and rig.Before("Flush", "NoteCast"))

        Check("wiring: a harmful player cast calls Owner.Cast once, with no argument",
            rig.Count("Cast") == 1 and rig.Call("Cast").n == 1)
        rig.S.harmful[139] = false
        rig.Cast(101, "nameplate1", 139)
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("pet", "c", SWP)
        Check("wiring: neither a helpful player cast nor a pet cast calls Owner.Cast", rig.Count("Cast") == 1)

        -- the tick keys: the plate and "player" while Owner is active, nil grouped and inactive, as before solo
        local function Keys(options)
            local keyed = Wired(options)
            keyed.S.harmful[139] = false
            keyed.Cast(100, "nameplate1")
            keyed.Cast(101, "nameplate1", 139)
            local harmful, helpful = keyed.calls[keyed.Index("TickCast")], nil
            for index = keyed.Index("TickCast") + 1, #keyed.calls do
                if keyed.calls[index][1] == "TickCast" then helpful = keyed.calls[index] end
            end

            return harmful, helpful, keyed.Plate("nameplate1")
        end
        local harmful, helpful, plate = Keys()
        local idleHarmful, idleHelpful = Keys({ off = true })
        local soloHarmful, soloHelpful, soloPlate = Keys({ solo = true, off = true })
        Check("wiring: grouped with Owner active the tick key is the plate; inactive it stays nil",
            harmful[4] == plate and harmful[5] == "damage" and helpful[4] == "player" and helpful[5] == "heal"
            and idleHarmful[4] == nil and idleHarmful[5] == "damage" and idleHelpful[4] == nil
            and idleHelpful[5] == "heal" and soloHarmful[4] == soloPlate and soloHelpful[4] == "player")

        rig = Wired()
        rig.S.now = 100
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        local startOrder = rig.Before("KeepLinesOn", "Active")
        local startCalls = #rig.calls
        rig.calls = {}
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        local endFlush = rig.Call("Flush")
        Check("wiring: PLAYER_REGEN_DISABLED on Forever calls KeepLinesOn then Active; PLAYER_REGEN_ENABLED calls Flush(nil) then Active",
            startOrder and startCalls == 2 and endFlush and endFlush[2] == nil and endFlush.n == 2
            and rig.Before("Flush", "Active") and rig.Before("Active", "SyncBlizzard")
            and rig.Before("Active", "FlushHeals"))

        rig = Wired()
        rig.S.now = 100
        rig.ns.Core.GROUP_ROSTER_UPDATE()
        local rosterFlush = rig.Call("Flush")
        Check("wiring: GROUP_ROSTER_UPDATE calls Flush(nil), KeepLinesOn, Active in that order",
            rosterFlush and rosterFlush[2] == nil and rosterFlush.n == 2 and rig.Before("Flush", "KeepLinesOn")
            and rig.Before("KeepLinesOn", "Active") and rig.Before("Active", "SyncBlizzard"))

        rig = Wired()
        rig.ns.Core.PLAYER_LOGIN()
        Check("wiring: PLAYER_LOGIN on Forever calls KeepLinesOn before SyncBlizzard",
            rig.Before("KeepLinesOn", "SyncBlizzard") and rig.Count("KeepLinesOn") == 1)

        -- retail never switches the Combat Log lines; the same events on Forever do (the control)
        local clog
        local function Lines(interface)
            clog = {}
            local lines = Wired({ interface = interface, setup = function() T.CombatLogLive(clog) end })
            clog.setCalls, clog.on = {}, false -- the boot may have switched them on; count only the events below
            lines.ns.Core.GROUP_ROSTER_UPDATE()
            lines.ns.Core.PLAYER_REGEN_DISABLED()
            lines.ns.Core.PLAYER_LOGIN()
            lines.Cast(100, "nameplate1")

            return lines
        end
        local retail = Lines(120105)
        local retailSet = #clog.setCalls
        local forever = Lines(16001)
        T.CombatLogClear()
        Check("wiring: on retail GROUP_ROSTER_UPDATE and PLAYER_REGEN_DISABLED never call KeepLinesOn (the C_CombatLog.SetFilteredEventsEnabled stub is not called)",
            retail.Count("KeepLinesOn") == 0 and retailSet == 0 and forever.Count("KeepLinesOn") == 3 and #clog.setCalls > 0)

        Check("wiring: on retail a player cast never calls Owner.Cast (no cast count, no check timer)",
            retail.Count("Cast") == 0 and forever.Count("Cast") == 1)

        rig = Wired()
        rig.S.now = 100
        CombatTextIconsDB.enabled = false
        rig.ns.Core.GROUP_ROSTER_UPDATE()
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.ns.Core.PLAYER_LOGIN()
        Check("wiring: a disabled addon never switches the Combat Log lines on", rig.Count("KeepLinesOn") == 0)

        rig = Wired()
        rig.ns.Core.NAME_PLATE_UNIT_REMOVED("nameplate1")
        local gone = rig.Call("PlateGone")
        Check("wiring: NAME_PLATE_UNIT_REMOVED calls Owner.PlateGone(plate)",
            rig.Count("PlateGone") == 1 and gone[2] == rig.Plate("nameplate1"))

        rig = Wired()
        rig.ns.Core.PLAYER_LOGOUT()
        Check("wiring: PLAYER_LOGOUT calls Owner.LinesOff", rig.Count("LinesOff") == 1)

        rig = Wired()
        SlashCmdList.COMBATTEXTICONS("off")
        Check("wiring: /cti off calls Owner.Drop then Owner.LinesOff",
            rig.Count("Drop") == 1 and rig.Count("LinesOff") == 1 and rig.Before("Drop", "LinesOff"))

        rig = Wired()
        rig.S.now = 100
        local ok = pcall(function() rig.ns.Core.COMBAT_LOG_MESSAGE("You hit", 1, 1, 1, 0) end)
        local line = rig.Call("Line")
        SlashCmdList.COMBATTEXTICONS("off")
        rig.calls = {}
        local offOk = pcall(function() rig.ns.Core.COMBAT_LOG_MESSAGE("You hit", 1, 1, 1, 0) end)
        Check("wiring: COMBAT_LOG_MESSAGE hands Owner.Line(order, GetTime()); a disabled addon hands it nothing",
            ok and line and line[2] == 0 and line[3] == 100 and offOk and rig.Count("Line") == 0)

        local rec = {}
        rig = Wired({ setup = function() RecordFrames(rec) end })
        local core = CoreFrame(rec)
        rig.S.now = 100
        pcall(core.scripts.OnEvent, core, "COMBAT_LOG_MESSAGE", "You hit", 1, 1, 1, 0)
        local sourceCore = assert(io.open(T.Root .. "/Core.lua", "rb")):read("a")
        Check("wiring: the addon registers COMBAT_LOG_MESSAGE (CreateFrame recorder) and keeps GROUP_ROSTER_UPDATE",
            core.registered.COMBAT_LOG_MESSAGE and core.registered.GROUP_ROSTER_UPDATE and rig.Count("Line") == 1
            and sourceCore:find('RegisterEvent("GROUP_ROSTER_UPDATE")', 1, true) ~= nil)

        rec = {}
        local loaded, failed = pcall(Wired, { setup = function() RecordFrames(rec, "COMBAT_LOG_MESSAGE") end })
        core = CoreFrame(rec)
        Check("wiring: a client without COMBAT_LOG_MESSAGE still loads and registers the other events",
            loaded and failed ~= nil and core ~= nil and not core.registered.COMBAT_LOG_MESSAGE
            and core.registered.GROUP_ROSTER_UPDATE and core.registered.UNIT_COMBAT)

        -- the frame callback QueueFlush queues
        rig = Wired()
        rig.S.now = 100
        rig.S.timers = {}
        rig.ns.PlayerHits.QueueFlush()
        local queued = #rig.S.timers
        rig.S.timers[1].fn()
        local flushCall = rig.Call("Flush")
        local idle = #rig.S.timers == 1
        rig.waiting = true
        rig.S.timers[1].fn()
        Check("wiring: QueueFlush callback flushes Owner then re-queues while Owner.Waiting()",
            queued == 1 and flushCall and flushCall[2] == 100 and flushCall.n == 2 and rig.Before("Flush", "QueueHeals")
            and rig.Before("QueueHeals", "QueueMates") and idle and #rig.S.timers == 2)

        -- the CVar Blizzard's own numbers use: "0" in addon mode, the player's value in blizzard mode
        local cvar = "floatingCombatTextCombatDamage_v2"
        local function Mode(options)
            options.setup = function(S) S.cvars[cvar] = "1" end

            return Rig(options)
        end
        rig = Mode({})
        local bootedGrouped = rig.S.cvars[cvar]
        rig.on = true
        rig.ns.BlizzardText.Sync()
        local whileActive = rig.S.cvars[cvar]
        rig.on = false
        rig.ns.BlizzardText.Sync()
        local afterwards = rig.S.cvars[cvar]
        local soloMode = Mode({ solo = true, off = true })
        Check("wiring: BlizzardText mode is 'addon' in a Forever group while Owner.IsActive, 'blizzard' when not",
            bootedGrouped == "1" and whileActive == "0" and afterwards == "1" and soloMode.S.cvars[cvar] == "0")
    end

    -- Owner holds a hit of nameplate1 (the target) and, unless `single`, one of nameplate2, both stamped 100, and has
    -- one line at 100. rig.routes counts HitRoute.Route; rig.order lists the Route and NoteCast calls.
    local function Held(single)
        local rig = Rig({ realOwner = true })
        rig.routes, rig.order = 0, {}
        local Route, NoteCast = rig.ns.HitRoute.Route, rig.ns.Locked.NoteCast
        rig.ns.HitRoute.Route = function(hit)
            rig.routes = rig.routes + 1
            rig.order[#rig.order + 1] = "Route"

            return Route(hit)
        end
        rig.ns.Locked.NoteCast = function(...)
            rig.order[#rig.order + 1] = "NoteCast"

            return NoteCast(...)
        end
        rig.S.target = "nameplate1"
        rig.Hit(100, "nameplate1", 31, 32)
        if not single then rig.Hit(100, "nameplate2", 31, 32) end
        rig.ns.Owner.Line(0, 100)

        return rig
    end

    do
        local rig = Held()
        rig.Cast(100.02, "nameplate1")
        Check("owner wiring: a cast 0.02 s after a held hit routes the hit before the cast is noted",
            rig.routes == 1 and rig.order[1] == "Route" and rig.order[2] == "NoteCast")

        local control = Held(true)
        control.ns.Owner.Flush(nil)
        rig = Held(true)
        SlashCmdList.COMBATTEXTICONS("off")
        rig.ns.Owner.Flush(nil)
        Check("owner wiring: /cti off with hits held routes none",
            control.routes == 1 and rig.routes == 0 and not rig.ns.Owner.Waiting())

        rig = Held(true)
        rig.ns.Core.NAME_PLATE_UNIT_REMOVED("nameplate1")
        rig.ns.Owner.Flush(nil)
        Check("owner wiring: a plate removed before release routes none of its hits",
            control.routes == 1 and rig.routes == 0)
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
