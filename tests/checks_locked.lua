-- Unit checks for Locked.lua Rule 2, the cast lock, and Rule 1, own school (spec 2026-11-05-forever-icon-learner).
-- Called by tests/checks_forever.lua with the same T table.

return function(T)
    local Check = T.Check
    local function Fresh(interface)
        local ns = T.Boot(function(S) S.interface = interface or 16001 CombatTextIconsCharDB = {} end)
        local store = {}
        ns.Locked.Init(store)

        return ns.Locked, store, ns
    end
    -- rows: list of { spellID, totalAmount }. session nil: GetAvailableCombatSessions errors. Call after Fresh: Boot
    -- rebuilds C_DamageMeter (tests/run.lua:116), so no restore is needed.
    local function Meter(session, rows)
        C_DamageMeter.GetAvailableCombatSessions = function()
            if session == nil then error("no sessions") end
            return { { sessionID = session } }
        end
        C_DamageMeter.GetCombatSessionSourceFromID = function()
            local out = {}
            for i, r in ipairs(rows or {}) do out[i] = { spellID = r[1], totalAmount = r[2] } end
            return { combatSpells = out }
        end
    end
    -- A lock at 0.9 s for ("p", spellID, school), by default (5019, 32). Both hits return nil, 0 while the spell has
    -- no own-school entry. Returns both answers for the first row to check.
    local function Lock(L, spellID, school)
        spellID, school = spellID or 5019, school or 32
        L.NoteCast(spellID, 10)
        local a, b = L.Observe("p", school, 10.9)
        L.NoteCast(spellID, 11.4)
        local c, d = L.Observe("p", school, 12.3)

        return a, b, c, d
    end
    -- Session 69 teaches 591 on school 2. The hit returns 591, 1.
    local function Teach(L)
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 10)

        return L.Observe("p", 2, 10)
    end
    local TWO_ROWS = { { 591, 29 }, { 589, 15 } }
    -- Whether nothing is saved in `store`.
    local function Empty(store) return next(store.lockedSchools) == nil end
    -- Whether `L.Observe` answered `spell, fits`.
    local function Is(spell, fits, sole, count) return sole == spell and count == fits end

    do
        local L = Fresh()
        local a, b, c, d = Lock(L)
        L.NoteCast(5019, 15.5)
        Check("locked: forming draws nothing, then names; uneven gaps don't matter",
            a == nil and b == 0 and c == nil and d == 0 and Is(5019, 1, L.Observe("p", 32, 16.4)))
    end

    do
        local L = Fresh()
        L.NoteCast(5019, 10)
        L.Observe("p", 32, 10.5)
        L.Observe("p", 32, 10.6)
        L.NoteCast(5019, 11.4)
        Check("locked: two hits off one cast form no lock", Is(nil, 0, L.Observe("p", 32, 11.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 15.5)
        local named = Is(5019, 1, L.Observe("p", 32, 16.4))
        Check("locked: one name per cast", named and Is(nil, 0, L.Observe("p", 32, 16.45)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 20)
        local named = Is(5019, 1, L.Observe("p", 32, 21.0))
        L.NoteCast(5019, 22)
        Check("locked: a fit moves the lock", named and Is(5019, 1, L.Observe("p", 32, 23.06)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 20)
        Check("locked: tolerance edge", Is(nil, 0, L.Observe("p", 32, 21.2)))
    end

    do
        local L = Fresh()
        Lock(L)
        for _, at in ipairs({ 13, 14, 15 }) do L.NoteCast(5019, at) end
        Check("locked: break, 2 misses keep the lock", Is(5019, 1, L.Observe("p", 32, 15.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        for _, at in ipairs({ 13, 14, 15, 16 }) do L.NoteCast(5019, at) end
        local cleared = Is(nil, 0, L.Observe("p", 32, 16.9))
        L.NoteCast(5019, 17)
        local forming = Is(nil, 0, L.Observe("p", 32, 17.9))
        L.NoteCast(5019, 18)
        Check("locked: break, 3 misses clear the lock and its delays",
            cleared and forming and Is(5019, 1, L.Observe("p", 32, 18.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 13)
        L.NoteCast(5019, 14)
        local named = Is(5019, 1, L.Observe("p", 32, 14.9))
        for _, at in ipairs({ 15, 16, 17 }) do L.NoteCast(5019, at) end
        Check("locked: a fit resets misses", named and Is(5019, 1, L.Observe("p", 32, 17.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 15)
        Check("locked: plate keys", Is(nil, 0, L.Observe("q", 32, 15.9)))
        L = Fresh()
        Lock(L)
        L.NoteCast(5019, 15)
        Check("locked: school keys", Is(nil, 0, L.Observe("p", 2, 15.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.PlateGone("p")
        L.NoteCast(5019, 15)
        Check("locked: PlateGone forgets", Is(nil, 0, L.Observe("p", 32, 15.9)))
    end

    -- Inherited delay (spec 2026-11-07-forever-carried-lock): a lock fit that names its spell alone leaves its delay
    -- inherited by a new key on the plate the spell's newest cast was aimed at. Steps: { "cast", at, plate, spell }
    -- (spell 5019 when nil), { "end" }, or { "hit", plate, at, spell, fits } on school 64. Returns whether every hit
    -- answered as listed.
    do
        local function Run(L, steps)
            local ok = true
            for _, step in ipairs(steps) do
                if step[1] == "cast" then L.NoteCast(step[4] or 5019, step[2], step[3])
                elseif step[1] == "end" then L.EndFight()
                else ok = Is(step[4], step[5], L.Observe(step[2], 64, step[3])) and ok end
            end

            return ok
        end
        local FORM = { { "cast", 10, "p" }, { "hit", "p", 10.9, nil, 0 }, { "cast", 12, "p" }, { "hit", "p", 12.9, nil, 0 } }
        -- Forms 0.9 on "p", names a hit with it (so 0.9 is inherited), then the fight ends.
        local NAMED = { FORM[1], FORM[2], FORM[3], FORM[4], { "cast", 14, "p" }, { "hit", "p", 14.9, 5019, 1 }, { "end" } }
        local function AfterNamed(...)
            local L = Fresh()
            local ok = Run(L, NAMED)
            for _, steps in ipairs({ ... }) do ok = Run(L, steps) and ok end

            return ok, L
        end

        Check("locked inherit: a new plate the cast aims at inherits a named lock",
            AfterNamed({ { "cast", 20, "q" }, { "hit", "q", 20.9, 5019, 1 } }))
        -- 1.08 is 0.136 from the lock the fits moved (0.944), 0.155 from the first named one (0.925)
        Check("locked inherit: each named fit moves the inherited delay", Run(Fresh(), { FORM[1], FORM[2], FORM[3], FORM[4],
            { "cast", 14, "p" }, { "hit", "p", 15.0, 5019, 1 }, { "cast", 16, "p" }, { "hit", "p", 17.0, 5019, 1 },
            { "end" }, { "cast", 20, "q" }, { "hit", "q", 21.08, 5019, 1 } }))
        Check("locked inherit: a lock that formed but never named leaves nothing inherited",
            Run(Fresh(), { FORM[1], FORM[2], FORM[3], FORM[4], { "end" }, { "cast", 20, "q" }, { "hit", "q", 20.9, nil, 0 } }))
        -- 5019 and 8102 both form 0.9 on "p", so the hit at 14.9 fits both locks and names neither.
        Check("locked inherit: a lock fit shared with another spell leaves nothing inherited", Run(Fresh(), {
            { "cast", 10, "p" }, { "cast", 10, "p", 8102 }, { "hit", "p", 10.9, nil, 0 },
            { "cast", 12, "p" }, { "cast", 12, "p", 8102 }, { "hit", "p", 12.9, nil, 0 },
            { "cast", 14, "p" }, { "cast", 14, "p", 8102 }, { "hit", "p", 14.9, nil, 2 },
            { "end" }, { "cast", 20, "q" }, { "hit", "q", 20.9, nil, 0 } }))
        Check("locked inherit: a cast aimed at another plate inherits nothing",
            AfterNamed({ { "cast", 20, "p2" }, { "hit", "q", 20.9, nil, 0 } }))
        Check("locked inherit: a cast with no plate inherits nothing", AfterNamed({ { "cast", 20 }, { "hit", "q", 20.9, nil, 0 } }))
        local relearned, L = AfterNamed({ { "cast", 20, "q" }, { "hit", "q", 21.2, nil, 0 }, { "cast", 22, "q" },
            { "hit", "q", 22.2, nil, 0 }, { "cast", 24, "q" }, { "hit", "q", 24.2, nil, 0 }, { "cast", 26, "q" },
            { "hit", "q", 26.2, 5019, 1 } })
        Check("locked inherit: an inherited lock that doesn't fit re-learns as a lockless key would", relearned)
        Check("locked inherit: the re-learned delay is inherited next",
            Run(L, { { "end" }, { "cast", 40, "r" }, { "hit", "r", 40.2, 5019, 1 } }))
        -- Re-lock (run 6, 2026-11-13): Shoots moved from 0.9 s to 0.24 s and the old lock never let go. 0.2 misses the
        -- lock (kept); cast 26 closes a missed period, so the second 0.2 re-locks there and names; 0.2 then fits.
        Check("locked relock: after a missed period, two hits nothing fits from different casts move the lock",
            AfterNamed({ { "cast", 20, "q" }, { "hit", "q", 20.9, 5019, 1 }, { "cast", 22, "q" }, { "hit", "q", 22.9, 5019, 1 },
                { "cast", 24, "q" }, { "hit", "q", 24.2, nil, 0 }, { "cast", 26, "q" }, { "hit", "q", 26.2, 5019, 1 },
                { "cast", 28, "q" }, { "hit", "q", 28.2, 5019, 1 } }))
        -- A tick the tracker doesn't know, at 0.2 after each cast, while the Shoots still fit 0.9.
        Check("locked relock: a lock its casts still fit keeps it, whatever else misses",
            AfterNamed({ { "cast", 20, "q" }, { "hit", "q", 20.9, 5019, 1 }, { "cast", 22, "q" }, { "hit", "q", 22.2, nil, 0 },
                { "hit", "q", 22.9, 5019, 1 }, { "cast", 24, "q" }, { "hit", "q", 24.2, nil, 0 }, { "hit", "q", 24.9, 5019, 1 },
                { "cast", 26, "q" }, { "hit", "q", 26.2, nil, 0 }, { "hit", "q", 26.9, 5019, 1 } }))
        Check("locked relock: two misses off one cast don't move the lock",
            AfterNamed({ { "cast", 20, "q" }, { "hit", "q", 20.9, 5019, 1 }, { "cast", 22, "q" }, { "cast", 24, "q" },
                { "hit", "q", 24.2, nil, 0 }, { "hit", "q", 24.3, nil, 0 }, { "cast", 25, "q" }, { "hit", "q", 25.9, 5019, 1 } }))
        -- Run 7 (2026-11-13): a DoT tick at 0.9 after each cast taught the wand key its delay. Ticks.Fits names SW:P
        -- for the hits at 10.9 and 12.9, so they teach no lock and 14.9 only starts a pair.
        local L, _, ns = Fresh()
        local tickAt = { [10.9] = true, [12.9] = true }
        ns.Ticks.Fits = function(_, _, _, now) return tickAt[now] and { { spellID = 589, slot = 1 } } or {} end
        ns.Ticks.Take = function() end
        Check("locked: a hit a DoT tick slot fits teaches no lock", Run(L, {
            { "cast", 10, "p" }, { "hit", "p", 10.9, 589, 1 }, { "cast", 12, "p" }, { "hit", "p", 12.9, 589, 1 },
            { "cast", 14, "p" }, { "hit", "p", 14.9, nil, 0 } }))
        -- F1 (run 6): 5019 and 8102 both lock 0.9, so hits 14.9-18.9 fit both and name neither; those fits no longer
        -- keep the locks, so casts 16-20 break them and 20.9 only starts a new pair.
        Check("locked: a fit that names no spell alone doesn't keep the lock", Run(Fresh(), {
            { "cast", 10, "p" }, { "cast", 10, "p", 8102 }, { "hit", "p", 10.9, nil, 0 },
            { "cast", 12, "p" }, { "cast", 12, "p", 8102 }, { "hit", "p", 12.9, nil, 0 },
            { "cast", 14, "p" }, { "cast", 14, "p", 8102 }, { "hit", "p", 14.9, nil, 2 },
            { "cast", 16, "p" }, { "cast", 16, "p", 8102 }, { "hit", "p", 16.9, nil, 2 },
            { "cast", 18, "p" }, { "cast", 18, "p", 8102 }, { "hit", "p", 18.9, nil, 2 },
            { "cast", 20, "p" }, { "cast", 20, "p", 8102 }, { "hit", "p", 20.9, nil, 0 } }))
        local AIM_Q = { { "cast", 20, "q" }, { "hit", "q", 20.9, nil, 0 } }
        local _
        _, L = AfterNamed()
        L.Forget()
        Check("locked inherit: Forget clears the inherited delay", Run(L, AIM_Q))
        _, L = AfterNamed()
        L.Init({})
        Check("locked inherit: Init clears the inherited delay", Run(L, AIM_Q))
        _, L = AfterNamed({ { "cast", 20, "q" } })
        L.PlateGone("q")
        Check("locked inherit: PlateGone forgets the plate a cast aimed at", Run(L, { { "hit", "q", 20.9, nil, 0 } }))
        _, L = AfterNamed()
        L.PlateGone("x")
        L.PlateGone("p")
        Check("locked inherit: PlateGone keeps the inherited delay",
            Run(L, { { "cast", 20, "q" }, { "hit", "q", 20.9, 5019, 1 } }))

        -- Aim (run 5, 2026-11-13): SW:P's ticks on a second mob, timed from Shoots at the first, formed a wand lock there.
        Check("locked aim: hits on a plate the casts don't aim at form no lock", Run(Fresh(), {
            { "cast", 10, "p" }, { "hit", "q", 10.6, nil, 0 }, { "cast", 12, "p" }, { "hit", "q", 12.6, nil, 0 },
            { "cast", 14, "p" }, { "hit", "q", 14.6, nil, 0 } }))
        Check("locked aim: hits on the cast's own stamp form a lock on any plate (Holy Nova)", Run(Fresh(), {
            { "cast", 10, "p" }, { "hit", "q", 10, nil, 0 }, { "cast", 12, "p" }, { "hit", "q", 12, nil, 0 },
            { "cast", 14, "p" }, { "hit", "q", 14, 5019, 1 } }))
        Check("locked inherit: a key first seen off-aim inherits at its first aimed hit",
            AfterNamed({ { "cast", 20, "p" }, { "hit", "q", 20.5, nil, 0 }, { "cast", 22, "q" }, { "hit", "q", 22.9, 5019, 1 } }))
        Check("locked inherit: a stamp delay is inherited on a plate the cast doesn't aim at", Run(Fresh(), {
            { "cast", 10, "p" }, { "hit", "p", 10, nil, 0 }, { "cast", 12, "p" }, { "hit", "p", 12, nil, 0 },
            { "cast", 14, "p" }, { "hit", "p", 14, 5019, 1 }, { "end" }, { "cast", 20, "p" }, { "hit", "q", 20, 5019, 1 } }))
    end

    do
        local L = Fresh()
        Lock(L)
        L.EndFight()
        local noCast = Is(nil, 0, L.Observe("p", 32, 12.9))
        L.NoteCast(5019, 15)
        Check("locked: EndFight forgets locks and casts", noCast and Is(nil, 0, L.Observe("p", 32, 15.9)))
    end

    do
        local L = Fresh()
        for _, at in ipairs({ 10, 11.4 }) do
            L.NoteCast(5019, at)
            L.NoteCast(8092, at)
            L.Observe("p", 32, at == 10 and 10.9 or 12.3)
        end
        L.NoteCast(5019, 15)
        L.NoteCast(8092, 15)
        local sole, fits = L.Observe("p", 32, 15.9)
        local sole2, fits2 = L.Observe("p", 32, 15.95)
        Check("locked: two fits use no cast", sole == nil and fits == 2 and sole2 == nil and fits2 == 2)
    end

    do
        local L = Fresh()
        local delays = { 0.5, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0 }
        for i, delay in ipairs(delays) do
            local at = i * 10
            L.NoteCast(5019, at)
            L.Observe("p", 32, at + delay)
        end
        L.NoteCast(5019, 100)
        local first = Is(nil, 0, L.Observe("p", 32, 100.5))
        L.NoteCast(5019, 110)
        local second = Is(nil, 0, L.Observe("p", 32, 110.5))
        L.NoteCast(5019, 120)
        Check("locked: KEPT_HITS drops the oldest delay", first and second and Is(5019, 1, L.Observe("p", 32, 120.5)))
    end

    local function Spaced(delays, probe)
        local L = Fresh()
        for i, delay in ipairs(delays) do
            L.NoteCast(5019, i * 10)
            L.Observe("p", 32, i * 10 + delay)
        end
        local at = (#delays + 1) * 10
        L.NoteCast(5019, at)

        return L.Observe("p", 32, at + probe)
    end
    Check("locked: nearest pair", Is(5019, 1, Spaced({ 0.50, 0.70, 0.62 }, 0.79)))
    Check("locked: nearest beats newest", Is(5019, 1, Spaced({ 0.50, 0.70, 0.58 }, 0.43)))

    do
        local L = Fresh()
        L.NoteCast(5019, 10)
        L.Observe("p", 32, 10.9)
        L.Observe("q", 32, 10.9)
        L.NoteCast(5019, 11.4)
        L.Observe("p", 32, 12.3)
        L.Observe("q", 32, 12.3)
        L.NoteCast(5019, 15)
        local onP = Is(5019, 1, L.Observe("p", 32, 15.9))
        local onQ = Is(5019, 1, L.Observe("q", 32, 15.9))
        Check("locked: a cast is used once per plate, a repeat hit on either plate stays unnamed",
            onP and onQ and Is(nil, 0, L.Observe("p", 32, 15.95)) and Is(nil, 0, L.Observe("q", 32, 15.95)))
    end

    do
        -- Holy Nova (15431, school 2) hits four plates on its cast stamp: every plate names it, not just the first
        local L = Fresh()
        local plates = { "a", "b", "c", "d" }
        for _, castTime in ipairs({ 10, 11.4 }) do
            L.NoteCast(15431, castTime)
            for _, plate in ipairs(plates) do L.Observe(plate, 2, castTime + 0.9) end
        end
        L.NoteCast(15431, 15)
        local named = 0
        for _, plate in ipairs(plates) do
            if Is(15431, 1, L.Observe(plate, 2, 15.9)) then named = named + 1 end
        end
        Check("locked: an area cast names its spell on every plate it hit", named == 4)
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 20)
        local named = Is(5019, 1, L.Observe("p", 32, 21.0))
        local again = Is(nil, 0, L.Observe("p", 32, 21.05))
        L.NoteCast(5019, 22)
        Check("locked: a used hit doesn't move the lock", named and again and Is(5019, 1, L.Observe("p", 32, 22.78)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.NoteCast(5019, 15)
        local named = Is(5019, 1, L.Observe("p", 32, 15.9))
        local other = Is(nil, 0, L.Observe("q", 32, 15.95))
        L.NoteCast(5019, 17)
        local forming = Is(nil, 0, L.Observe("q", 32, 17.9))
        L.NoteCast(5019, 19)
        Check("locked: a used cast still keeps on an unlocked plate",
            named and other and forming and Is(5019, 1, L.Observe("q", 32, 19.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        L.PlateGone("p")
        L.NoteCast(5019, 15)
        L.Observe("p", 32, 15.9)
        L.NoteCast(5019, 16)
        Check("locked: PlateGone forgets kept delays", Is(nil, 0, L.Observe("p", 32, 16.9)))
    end

    do
        -- a lockless plate holds one kept delay (0.9); the plate goes, the same key returns with a second 0.9
        local L = Fresh()
        L.NoteCast(5019, 10)
        L.Observe("p", 32, 10.9)
        L.PlateGone("p")
        L.NoteCast(5019, 11.4)
        L.Observe("p", 32, 12.3)
        L.NoteCast(5019, 15.5)
        Check("locked: PlateGone forgets a kept delay on a lockless plate, so the pair forms later",
            Is(nil, 0, L.Observe("p", 32, 16.4)))
    end

    do
        local L = Fresh()
        L.NoteCast(5019, 10)
        L.Observe("p", 32, 10.9)
        L.EndFight()
        L.NoteCast(5019, 15)
        L.Observe("p", 32, 15.9)
        L.NoteCast(5019, 16)
        local forming = Is(nil, 0, L.Observe("p", 32, 16.9))
        L.NoteCast(5019, 17)
        Check("locked: EndFight forgets kept delays", forming and Is(5019, 1, L.Observe("p", 32, 17.9)))
    end

    do
        local L = Fresh()
        Lock(L)
        for _, at in ipairs({ 13, 14, 15, 15 }) do L.NoteCast(5019, at) end
        Check("locked: one stamp, one cast", Is(5019, 1, L.Observe("p", 32, 15.9)))
    end

    do
        local L = Fresh()
        Check("locked: a hit with no cast", Is(nil, 0, L.Observe("p", 32, 5)))
    end

    do
        local L = Fresh(120105)
        Lock(L)
        L.NoteCast(5019, 15)
        Check("locked: retail notes no cast", Is(nil, 0, L.Observe("p", 32, 15.9)))
    end

    -- Rule 1: own school -------------------------------------------------------------------------------------------

    do
        local L, store = Fresh()
        local taught = Is(591, 1, Teach(L))
        local entry = store.lockedSchools[591]
        Check("own school: teaches, and the teaching hit fits",
            taught and entry ~= nil and entry.school == 2 and entry.strays == 0 and entry.shared == nil)
    end

    do
        local L, store = Fresh()
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 10)
        local inside = Is(591, 1, L.Observe("p", 2, 11.5))
        Check("own school: a cast 1.5 s before the hit teaches", inside and store.lockedSchools[591] ~= nil)
        L, store = Fresh()
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 10)
        Check("own school: a cast 1.6 s before the hit does not",
            Is(nil, 0, L.Observe("p", 2, 11.6)) and Empty(store))
    end

    local function NothingTaught(name, session, rows, spellID)
        local L, store = Fresh()
        Meter(session, rows)
        L.NoteCast(spellID or 591, 10)
        local ok = pcall(L.Observe, "p", 2, 10.5)
        Check("own school: " .. name .. " teaches nothing", ok and Empty(store))
    end
    NothingTaught("a row ID that differs from the cast ID", 69, { { 75, 20 } }, 5019)
    NothingTaught("several rows", 69, TWO_ROWS)
    NothingTaught("zero rows", 69, {})
    NothingTaught("secret rows", 69, { { T.Secret(1), T.Secret(1) } })
    NothingTaught("a secret total", 69, { { 591, T.Secret(1) } })
    NothingTaught("a secret session ID", T.Secret(69), { { 591, 29 } })

    do
        local L, store = Fresh()
        store.lockedSchools[591] = { school = 2, strays = 1 }
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 10)
        L.Observe("p", 2, 10)
        Check("own school: the same school is no change", store.lockedSchools[591].strays == 1)
    end

    do
        local L, store = Fresh()
        Teach(L)
        L.EndFight()
        Meter(70, TWO_ROWS)
        L.Observe("p", 2, 20)
        local counted = store.lockedSchools[591].strays == 1
        local sole, fits = L.Observe("p", 2, 21)
        local shared = store.lockedSchools[591].shared == true
        L.NoteCast(591, 30)
        local drawn, count = L.Observe("p", 2, 30)
        Check("own school: a stray counts", counted)
        Check("own school: STRAYS_MAX shares the entry, which never draws again",
            shared and sole == nil and fits == 0 and drawn == nil and count == 0)
        L.Observe("p", 2, 60)
        Check("own school: a shared entry counts no strays", store.lockedSchools[591].strays == 2)
    end

    do
        local L = Fresh()
        Teach(L)
        local other = {}
        L.Init(other)
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 30)
        L.Observe("p", 2, 30)
        Check("own school: Init drops the last session and the first-hit flag", other.lockedSchools[591] ~= nil)
    end

    do
        local L, store, ns = Fresh()
        local disabled = false
        ns.Meter.Disable = function() disabled = true end
        Meter(nil)
        L.NoteCast(591, 10)
        local ok, sole, fits = pcall(L.Observe, "p", 2, 10)
        Check("own school: a read that throws teaches nothing and never disables the meter",
            ok and sole == nil and fits == 0 and Empty(store) and not disabled)
    end

    do
        local L, store = Fresh()
        Meter(69, { { 591, 29 } })
        C_DamageMeter.GetCombatSessionSourceFromID = function() return nil end
        L.NoteCast(591, 10)
        local ok = pcall(L.Observe, "p", 2, 10)
        Check("own school: a nil source teaches nothing", ok and Empty(store))
    end

    do
        local L = Fresh()
        Meter(69, { { 591, 29 } })
        local reads = 0
        local read = C_DamageMeter.GetAvailableCombatSessions
        C_DamageMeter.GetAvailableCombatSessions = function()
            reads = reads + 1
            return read()
        end
        L.Observe("p", 2, 10)
        L.Observe("p", 2, 11)
        local first = reads
        L.EndFight()
        L.Observe("p", 2, 20)
        Check("own school: only the first hit of a fight reads", first == 1 and reads == 2)
    end

    do
        local L, store = Fresh()
        Teach(L)
        L.EndFight()
        Meter(69, { { 589, 15 } })
        L.NoteCast(589, 20)
        L.Observe("p", 32, 20)
        Check("own school: a stale session teaches nothing", store.lockedSchools[589] == nil)
    end

    do
        local L, store = Fresh()
        Meter(70, TWO_ROWS)
        L.NoteCast(591, 10)
        L.Observe("p", 2, 10.5)
        L.EndFight()
        Meter(70, { { 591, 29 } })
        L.NoteCast(591, 20)
        L.Observe("p", 2, 20)
        Check("own school: a failed read still stores its session", store.lockedSchools[591] == nil)
    end

    do
        local L, store = Fresh()
        Teach(L)
        L.EndFight()
        Meter(70, { { 589, 15 } })
        L.NoteCast(589, 20)
        L.Observe("p", 32, 20)
        local entry = store.lockedSchools[589]
        Check("own school: a newer session teaches", entry ~= nil and entry.school == 32)
    end

    do
        -- the list holds 70 before 69, and each session's only row is a different spell, both cast
        local L, store = Fresh()
        C_DamageMeter.GetAvailableCombatSessions = function() return { { sessionID = 70 }, { sessionID = 69 } } end
        C_DamageMeter.GetCombatSessionSourceFromID = function(session)
            local row = { spellID = session == 70 and 591 or 589, totalAmount = 29 }

            return { combatSpells = { row } }
        end
        L.NoteCast(591, 10)
        L.NoteCast(589, 10)
        L.Observe("p", 2, 10)
        Check("own school: the highest session ID teaches, not the last one listed",
            store.lockedSchools[591] ~= nil and store.lockedSchools[589] == nil)
    end

    do
        local L, store = Fresh()
        store.lockedSchools[591] = { school = 2, strays = 1 }
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 10)
        L.Observe("p", 32, 10)
        local entry = store.lockedSchools[591]
        Check("own school: another school replaces the entry and resets strays",
            entry.school == 32 and entry.strays == 0 and entry.shared == nil)
    end

    do
        local L, store = Fresh()
        store.lockedSchools[591] = { school = 2, strays = 0, shared = true }
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 10)
        L.Observe("p", 32, 10)
        local entry = store.lockedSchools[591]
        Check("own school: a shared entry is left alone", entry.shared == true and entry.school == 2)
    end

    do
        local L, store = Fresh()
        Teach(L)
        local fit = Is(591, 1, L.Observe("p", 2, 11))
        Check("own school: a hit of its school in the window fits", fit and store.lockedSchools[591].strays == 0)
        L.Observe("p", 32, 40)
        Check("own school: a hit of another school is no stray", store.lockedSchools[591].strays == 0)
    end

    do
        local L, store = Fresh()
        store.lockedSchools[591] = { school = 2, strays = 0 }
        store.lockedSchools[8092] = { school = 2, strays = 0 }
        L.NoteCast(591, 10)
        L.NoteCast(8092, 10)
        Check("own school: two spells of one school both fit", Is(nil, 2, L.Observe("p", 2, 10.5)))
    end

    do
        local L, store = Fresh()
        store.lockedSchools[591] = { school = 2, strays = 0 }
        Lock(L, 591, 32)
        L.NoteCast(591, 15)
        Check("own school: an entry for another school takes no lock", Is(nil, 0, L.Observe("p", 32, 15.9)))
        L, store = Fresh()
        store.lockedSchools[591] = { school = 2, strays = 0, shared = true }
        Lock(L, 591, 32)
        L.NoteCast(591, 15)
        Check("own school: a shared entry has no guard", Is(591, 1, L.Observe("p", 32, 15.9)))
    end

    do
        local L, store = Fresh()
        store.lockedSchools[5019] = { school = 32, strays = 0 }
        Lock(L)
        L.NoteCast(5019, 15)
        Check("own school: a spell that fits both ways counts once", Is(5019, 1, L.Observe("p", 32, 15.9)))
    end

    do
        -- a lock at 2.0 s for (p, 591, school 2) forms before 591 owns school 2; then a cast's own-school fit at 0.1 s
        -- and its lock fit at 2.0 s, past OWN_WINDOW
        local L, store = Fresh()
        L.NoteCast(591, 10)
        L.Observe("p", 2, 12)
        L.NoteCast(591, 13)
        L.Observe("p", 2, 15)
        store.lockedSchools[591] = { school = 2, strays = 0 }
        L.NoteCast(591, 20)
        local own = Is(591, 1, L.Observe("p", 2, 20.1))
        Check("own school: an own-school fit leaves its cast free, only a lock's fit marks it used",
            own and Is(591, 1, L.Observe("p", 2, 22)))
    end

    do
        local L, store = Fresh()
        local saved = {
            [1] = "x",
            [2] = { school = "a", strays = 0 },
            [3] = { school = 2 },
            [4] = { school = 2, strays = 0, shared = 1 },
            [5] = { school = 2, strays = 0 },
        }
        store.lockedSchools = saved
        L.Init(store)
        local kept = 0
        for _ in pairs(store.lockedSchools) do kept = kept + 1 end
        Check("own school: load drops bad entries", kept == 1 and store.lockedSchools[5] ~= nil)
    end

    do
        local L, store = Fresh()
        Teach(L)
        L.Forget()
        Meter(69, TWO_ROWS)
        L.NoteCast(591, 30)
        Check("own school: Forget clears the saved entries", Empty(store) and Is(nil, 0, L.Observe("p", 2, 30)))
    end

    do
        local L, store = Fresh()
        Teach(L)
        L.Forget()
        Meter(69, { { 591, 29 } })
        L.NoteCast(591, 30)
        L.Observe("p", 2, 30)
        Check("own school: Forget drops the last session", store.lockedSchools[591] ~= nil)
    end

    do
        local L = Fresh()
        Lock(L)
        L.Init({})
        L.NoteCast(5019, 15)
        Check("own school: a spec change clears the live locks", Is(nil, 0, L.Observe("p", 32, 15.9)))
    end

    -- Replay of capture 3, five fights. This priest's harmful casts, hand-written: 139 and 17 are helpful casts and
    -- CAST lines don't say.
    do
        local HARMFUL = { [5019] = true, [589] = true, [591] = true }
        local L, store = Fresh()
        local lines = {}
        for line in io.lines(T.Root .. "/tests/fixtures/forever-secret-2026-11-05.log") do lines[#lines + 1] = line end

        local named, shadow, shoots, two, holyNamed, holy = 0, 0, 0, 0, 0, 0
        local fight, perFight = 1, { 0 }
        local lastShoot, perShoot, maxPerShoot = nil, {}, 0
        for i, line in ipairs(lines) do
            local at, rest = line:match("^(%d+%.%d+) (.*)$")
            at = tonumber(at)
            local cast = tonumber(rest:match("^CAST %S+ (%d+)"))
            local school = tonumber(rest:match("^HIT %S+ school=(%d+)"))
            if cast and HARMFUL[cast] then
                L.NoteCast(cast, at, T.PlateOf(lines, i))
                if cast == 5019 then lastShoot, shoots = at, shoots + 1 end
            elseif school then
                T.ReadMeter(lines[i + 1]:match("meter=(%S+)"))
                local sole, fits = L.Observe(rest:match("^HIT (%S+)"), school, at)
                if school == 32 then
                    shadow = shadow + 1
                    if sole then
                        named, perFight[fight] = named + 1, perFight[fight] + 1
                        if sole == 5019 then
                            perShoot[lastShoot] = (perShoot[lastShoot] or 0) + 1
                            maxPerShoot = math.max(maxPerShoot, perShoot[lastShoot])
                        end
                    end
                    if fits >= 2 then two = two + 1 end
                elseif school == 2 then
                    holy = holy + 1
                    if sole then holyNamed = holyNamed + 1 end
                end
            elseif rest:match("^TEACH session") then
                L.EndFight()
                fight = fight + 1
                perFight[fight] = 0
            end
        end
        perFight[fight] = nil
        local wandNamed = 0
        for _, n in pairs(perShoot) do wandNamed = wandNamed + n end

        T.Note(string.format("LOCKED REPLAY named=%d shadow=%d share=%.2f shoots=%d perShoot=%.2f two=%d maxPerShoot=%d " ..
            "perFight=%s holy=%d/%d", named, shadow, named / shadow, shoots, wandNamed / shoots, two, maxPerShoot,
            table.concat(perFight, ","), holyNamed, holy))

        local saved = store.lockedSchools[591]
        local savedCount = 0
        for _ in pairs(store.lockedSchools) do savedCount = savedCount + 1 end
        Check("replay: 58 Shadow hits and 37 Shoots in the capture", shadow == 58 and shoots == 37)
        Check("replay: gate 1, a lock names at least a third of the Shadow hits", named * 3 >= shadow)
        Check("replay: gate 3, no Shoot has more than one named wand hit", maxPerShoot <= 1)
        Check("replay: only 591 is saved on school 2",
            savedCount == 1 and saved ~= nil and saved.school == 2 and saved.strays == 0)
    end

    -- Core wiring: the hooks reach Locked, and `Wound` asks only a solo secret hit of a plain school.
    do
        local PLATE_UNIT = "nameplate1"
        -- Boots (Forever by default) and spies on Locked: calls count in `calls[name]`, args in `args[name]`.
        local function Wired(interface, setup)
            local ns = T.Boot(function(S)
                S.interface = interface or 16001
                if setup then setup(S) end
            end)
            local calls, args = {}, {}
            for _, name in ipairs({ "Observe", "NoteCast", "PlateGone", "EndFight", "Forget" }) do
                local real = ns.Locked[name]
                calls[name] = 0
                ns.Locked[name] = function(...)
                    calls[name] = calls[name] + 1
                    args[name] = { ... }
                    return real(...)
                end
            end
            ns.Display.Plate = function() end
            ns.Display.Player = function() end

            return ns, T.State(), calls, args
        end
        local function Hit(ns, S, amount, school)
            S.now = 20
            ns.Core.UNIT_COMBAT(PLATE_UNIT, "WOUND", "", amount, school)
        end

        local ns, S, calls, args = Wired()
        Hit(ns, S, T.Secret(31), 32)
        local plate = C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false)
        Check("wiring: a solo secret hit calls Observe once with the plate, school and now",
            calls.Observe == 1 and args.Observe[1] == plate and args.Observe[2] == 32 and args.Observe[3] == 20)

        ns, S, calls = Wired()
        Hit(ns, S, 31, 32)
        Check("wiring: a plain amount does not call Observe", calls.Observe == 0)

        ns, S, calls = Wired(120105)
        Hit(ns, S, T.Secret(31), 32)
        Check("wiring: retail does not call Observe", calls.Observe == 0)

        ns, S, calls = Wired()
        local ok = pcall(Hit, ns, S, T.Secret(31), T.Secret(32))
        Check("wiring: a secret school does not call Observe and does not error", ok and calls.Observe == 0)

        ns, S, calls = Wired()
        S.group = true
        ok = pcall(Hit, ns, S, T.Secret(31), 32)
        Check("wiring: a grouped hit does not call Observe and does not error", ok and calls.Observe == 0)

        ns, S, calls = Wired()
        S.threat[PLATE_UNIT] = false
        Hit(ns, S, T.Secret(31), 32)
        Check("wiring: a hit from a mob not fighting you does not call Observe", calls.Observe == 0)

        -- the harness answers every spell harmful unless S.harmful[id] is false (tests/run.lua)
        ns, S, calls = Wired()
        S.now = 20
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", 5019)
        local playerCasts = calls.NoteCast
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("pet", "c", 5019)
        Check("wiring: a harmful player cast calls NoteCast, a pet cast does not",
            playerCasts == 1 and calls.NoteCast == 1)

        ns, S, calls = Wired()
        S.harmful[5019] = false
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", 5019)
        Check("wiring: a helpful cast does not call NoteCast", calls.NoteCast == 0)

        ns, S, calls, args = Wired()
        ns.Core.NAME_PLATE_UNIT_REMOVED(PLATE_UNIT)
        Check("wiring: a removed plate calls PlateGone with the plate",
            calls.PlateGone == 1 and args.PlateGone[1] == C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false))

        ns, S, calls = Wired()
        ns.Core.PLAYER_REGEN_ENABLED()
        Check("wiring: the fight's end calls EndFight once", calls.EndFight == 1)

        ns, S, calls = Wired()
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("wiring: /cti forget calls Locked.Forget", calls.Forget == 1)

        ns, S, calls = Wired(16001, function()
            CombatTextIconsCharDB = { lockedSchools = { [591] = { school = 2, strays = 0 } } }
        end)
        S.now = 10
        ns.Locked.NoteCast(591, 10)
        Check("wiring: Boot hands Locked the saved entries (a cast and a hit of the school name the spell)",
            Is(591, 1, ns.Locked.Observe("p", 2, 10)))

        ns, S, calls = Wired()
        SlashCmdList.COMBATTEXTICONS("off")
        Hit(ns, S, T.Secret(31), 32)
        Check("wiring: /cti off mid-fight keeps the hit away from Observe", calls.Observe == 0)
    end

    -- Routes: a secret solo hit draws the answer Observe gave (spec 2026-11-05-forever-icon-learner, One-fit decision)
    do
        local SWP, OTHER, PLATE_UNIT = 594, 5019, "nameplate1"
        local ROUTE_UNKNOWN, ROUTE_LOCKED = "  -> unknown-solo", "  -> locked 5019"

        -- A booted Forever with Shadow Word: Pain learned. `options`: tracker (what Tracker.Identify names, "UNKNOWN" for
        -- Tracker.UNKNOWN), observe
        -- ({ sole, fits }; nil keeps the real Observe), area (Teacher.area, "clear" by default), setup (run after boot).
        -- Records on the rig: plate draws, debug log, Drew calls, and the Teacher.Drawn and Ledger.Add calls.
        local function Routed(options)
            local rig = { draws = {}, log = {}, drew = {}, drawn = {}, ledger = {} }
            local ns = T.Boot(function(S)
                S.interface = 16001
                CombatTextIconsCharDB = { learned = { [SWP] = { school = 32, kind = "dot", period = 3.01, misses = 0 } } }
            end)
            rig.ns, rig.S = ns, T.State()
            ns.Teacher.area = options.area or "clear"
            if options.setup then options.setup() end

            ns.Display.Plate = function(_, texture, text) rig.draws[#rig.draws + 1] = { texture = texture, text = text } end
            ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
            if options.tracker ~= nil then
                local named = options.tracker == "UNKNOWN" and ns.Tracker.UNKNOWN or options.tracker
                ns.Tracker.Identify = function() return named end
            end
            if options.observe then ns.Locked.Observe = function() return options.observe[1], options.observe[2] end end
            local drew = ns.Locked.Drew
            ns.Locked.Drew = function(spellID) rig.drew[#rig.drew + 1] = spellID return drew(spellID) end
            local drawn = ns.Teacher.Drawn
            ns.Teacher.Drawn = function(spellID, ...) rig.drawn[#rig.drawn + 1] = spellID return drawn(spellID, ...) end
            local add = ns.Ledger.Add
            ns.Ledger.Add = function(side, key, ...) rig.ledger[#rig.ledger + 1] = side .. ":" .. tostring(key) return add(side, key, ...) end

            function rig.Hit(at)
                rig.S.now = at or 20
                local before = #rig.draws
                ns.Core.UNIT_COMBAT(PLATE_UNIT, "WOUND", "", T.Secret(31), 32)
                return #rig.draws > before and rig.draws[#rig.draws] or nil
            end
            function rig.Route()
                for index = #rig.log, 1, -1 do
                    if rig.log[index]:find("^  %->") then return rig.log[index] end
                end
            end

            return rig
        end
        local function Texture(spellID) return (C_Spell.GetSpellTexture(spellID)) end

        local rig = Routed({ tracker = SWP, observe = { OTHER, 1 } })
        local draw = rig.Hit()
        -- run 5 (2026-11-13): a Shoot 0.16 s after its cast, named as Devouring Plague's tick due 0.27 s later
        Check("route: a hit the tracker names as a DoT tick but only another spell's lock fits draws that spell",
            draw and draw.texture == Texture(OTHER) and rig.Route() == ROUTE_LOCKED and #rig.drew == 1
            and rig.drew[1] == OTHER)

        rig = Routed({ tracker = SWP, observe = { nil, 2 } })
        draw = rig.Hit()
        Check("route: a tick of the DoT that two spells fit draws ?",
            draw and draw.texture == rig.ns.Meter.UNKNOWN_ICON and #rig.drew == 0)

        rig = Routed({ tracker = SWP, observe = { SWP, 1 } })
        draw = rig.Hit()
        Check("route: a tick of the DoT that only it fits draws it and counts the draw",
            draw and draw.texture == Texture(SWP) and Texture(SWP) ~= rig.ns.Meter.UNKNOWN_ICON
            and #rig.drew == 1 and rig.drew[1] == SWP)

        rig = Routed({ tracker = SWP, observe = { nil, 0 } })
        draw = rig.Hit()
        Check("route: a tick of the DoT that nothing fits draws it and counts nothing",
            draw and draw.texture == Texture(SWP) and #rig.drew == 0)

        rig = Routed({ tracker = nil, observe = { OTHER, 1 } })
        draw = rig.Hit()
        Check("route: Question with one fit draws that spell's icon and a number",
            draw and draw.texture == Texture(OTHER) and Texture(OTHER) ~= rig.ns.Meter.UNKNOWN_ICON and draw.text ~= nil
            and rig.Route() == ROUTE_LOCKED)
        Check("route: Question with one fit adds the spell to the ledger, tallies it, and counts the draw",
            rig.ledger[#rig.ledger] == "damage:" .. OTHER and rig.drawn[#rig.drawn] == OTHER
            and #rig.drew == 1 and rig.drew[1] == OTHER)

        rig = Routed({ tracker = nil, observe = { OTHER, 1 }, setup = function() T.Store().schools = { [4] = true } end })
        draw = rig.Hit()
        Check("route: Question with one fit stays hidden in a school no clear read saw",
            draw == nil and #rig.drew == 0)

        rig = Routed({ tracker = nil, observe = { nil, 2 } })
        draw = rig.Hit()
        Check("route: Question with two fits draws ?", draw and draw.texture == rig.ns.Meter.UNKNOWN_ICON
            and rig.Route() == ROUTE_UNKNOWN and #rig.drew == 0)

        rig = Routed({ tracker = nil, observe = { nil, 0 } })
        draw = rig.Hit()
        Check("route: Question with no fit draws ?", draw and draw.texture == rig.ns.Meter.UNKNOWN_ICON and #rig.drew == 0)

        rig = Routed({ tracker = nil, observe = { OTHER, 1 }, area = "crowded" })
        draw = rig.Hit()
        Check("route: Question with one fit in a crowded area stays hidden", draw == nil and #rig.drew == 0)

        rig = Routed({ tracker = SWP, observe = { OTHER, 1 }, area = "crowded" })
        draw = rig.Hit()
        Check("route: a demoted tick in a crowded area stays hidden", draw == nil and #rig.drew == 0)

        rig = Routed({ tracker = "UNKNOWN", observe = { OTHER, 1 } })
        draw = rig.Hit()
        Check("route: an UNKNOWN tracker answer draws ? even with one fit",
            draw and draw.texture == rig.ns.Meter.UNKNOWN_ICON and #rig.drew == 0)

        -- Real Locked, no stubs: three casts and hits at one delay; the lock forms on the second hit and names the third.
        rig = Routed({})
        local textures = {}
        for index, castAt in ipairs({ 10, 11.4, 15.5 }) do
            rig.S.now = castAt
            rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", OTHER)
            local drawn = rig.Hit(castAt + 0.9)
            textures[index] = drawn and drawn.texture
        end
        Check("route: three casts and hits at one delay draw ?, ?, then the spell",
            textures[1] == rig.ns.Meter.UNKNOWN_ICON and textures[2] == rig.ns.Meter.UNKNOWN_ICON
            and textures[3] == Texture(OTHER) and rig.drew[1] == OTHER and #rig.drew == 1)

        -- A harmful player cast hands Locked the plate Casts aimed it at, so a new key there can inherit a delay.
        rig = Routed({})
        local aimed, plates = "plateX", {}
        rig.ns.Casts.NoteCast = function() return aimed end
        rig.ns.Locked.NoteCast = function(_, _, plate) plates[#plates + 1] = plate or "none" end
        rig.S.now = 10
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", OTHER)
        aimed, rig.S.now = nil, 12
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", OTHER)
        Check("route: Core passes the cast's plate to Locked.NoteCast, nil without one",
            plates[1] == "plateX" and plates[2] == "none" and #plates == 2)
    end

    -- The debug line: counts of drawn hits against the fight's own row total, printed at the read (Teacher.Judging)
    do
        local SMITE, WAND, WAND_ROW = 591, 5019, 75
        local function RowOf(spellID, total) return { spellID = spellID, total = total, overkill = 0 } end
        -- A booted Forever whose Debug records its LOCKED lines in `lines`.
        local function Logged()
            local L, _, ns = Fresh()
            local lines = {}
            ns.Debug = function(format, ...)
                local line = string.format(format, ...)
                if line:find("^LOCKED ") then lines[#lines + 1] = line end
            end

            return L, lines, ns
        end
        local function DrewTimes(L, spellID, times)
            for _ = 1, times do L.Drew(spellID) end
        end

        local L, lines = Logged()
        DrewTimes(L, SMITE, 2)
        L.EndFight()
        L.Report({ RowOf(SMITE, 50) })
        Check("report: a drawn spell prints its hits, the row total and the total per hit",
            #lines == 1 and lines[1] == "LOCKED 591 hits=2 total=50 per=25")

        L, lines = Logged()
        DrewTimes(L, WAND, 2)
        L.EndFight()
        L.Report({ RowOf(WAND_ROW, 84) })
        Check("report: a cast with no row of its ID prints ? for the total and the per-hit",
            #lines == 1 and lines[1] == "LOCKED 5019 hits=2 total=? per=?")

        lines[1] = nil
        L.Report({ RowOf(WAND_ROW, 84) })
        Check("report: a second Report prints nothing, it clears what it printed", #lines == 0)

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        L.Report({ RowOf(SMITE, 50), RowOf(589, 40) })
        Check("report: a row with no hit of its own prints no line", #lines == 1 and lines[1]:find("^LOCKED 591 "))

        L, lines = Logged()
        DrewTimes(L, 589, 1)
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        L.Report({ RowOf(SMITE, 30), RowOf(589, 20) })
        Check("report: several spells print one line each, in spell ID order",
            #lines == 2 and lines[1] == "LOCKED 589 hits=1 total=20 per=20" and lines[2] == "LOCKED 591 hits=1 total=30 per=30")

        L, lines = Logged()
        DrewTimes(L, SMITE, 3)
        L.EndFight()
        L.Report({ RowOf(SMITE, 10) })
        Check("report: per is a whole number, not Lua 5.4's 3.3333333333333", lines[1] == "LOCKED 591 hits=3 total=10 per=3")

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        L.Report({ { spellID = SMITE, total = T.Secret(50), overkill = 0 } })
        Check("report: a secret total prints ? and does not error", #lines == 1 and lines[1] == "LOCKED 591 hits=1 total=? per=?")

        local rows = { RowOf(SMITE, 50) }
        local ns
        L, lines, ns = Logged()
        local debug = ns.Debug
        ns.Debug = nil
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        local quiet = pcall(L.Report, rows)
        ns.Debug = debug
        L.Report(rows)
        Check("report: with Debug off it does not error, prints nothing, and still clears what was kept",
            quiet and #lines == 0)

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        DrewTimes(L, SMITE, 2)
        L.Report({ RowOf(SMITE, 50) })
        Check("report: a re-pull inside the read delay counts into fresh counts, kept apart",
            #lines == 1 and lines[1] == "LOCKED 591 hits=1 total=50 per=50")

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        DrewTimes(L, 589, 1)
        L.EndFight()
        L.Report({ RowOf(SMITE, 50), RowOf(589, 40) })
        Check("report: the next fight's EndFight replaces a skipped read's counts, it does not add to them",
            #lines == 1 and lines[1]:find("^LOCKED 589 "))

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        L.Init({})
        L.Report({ RowOf(SMITE, 50) })
        Check("report: Init drops the kept counts", #lines == 0)

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.Init({})
        L.EndFight()
        L.Report({ RowOf(SMITE, 50) })
        Check("report: Init drops the live counts", #lines == 0)

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.EndFight()
        L.Forget()
        L.Report({ RowOf(SMITE, 50) })
        Check("report: Forget drops the kept counts", #lines == 0)

        L, lines = Logged()
        DrewTimes(L, SMITE, 1)
        L.Forget()
        L.EndFight()
        L.Report({ RowOf(SMITE, 50) })
        Check("report: Forget drops the live counts", #lines == 0)
    end

    -- Through Teacher: the line follows the fight's read and the growth of a continued session
    do
        local SMITE = 591
        local function Session(id, total)
            local row = { spellID = SMITE, totalAmount = total, overkillAmount = 0, amountPerSecond = 0,
                combatSpellDetails = {}, creatureName = "", isAvoidable = false, isDeadly = false }
            return { { sessionID = id, name = "Dark Neophyte", durationSeconds = 13, rows = { row } } }
        end
        local L, _, ns = Fresh()
        local S, lines = T.State(), {}
        ns.Teacher.area = "clear"
        ns.Debug = function(format, ...)
            local line = string.format(format, ...)
            if line:find("^LOCKED ") then lines[#lines + 1] = line end
        end
        -- One fight whose read is queued, not run: `hits` drawn, then the fight's end as Core runs it.
        local function Fight(id, total, hits)
            S.sessions = Session(id, total)
            ns.Teacher.Start(10)
            ns.Teacher.Seen(total)
            for _ = 1, hits do L.Drew(SMITE) end
            ns.Teacher.Finish(20)
            L.EndFight()
        end
        local function Fire() table.remove(S.timers, 1).fn() end

        Fight(5, 50, 2)
        local before = #lines
        Fire()
        Check("through Teacher: one LOCKED line after the read, none before it",
            before == 0 and #lines == 1 and lines[1] == "LOCKED 591 hits=2 total=50 per=25")

        lines[1] = nil
        Fight(5, 50, 2)
        Fire()
        Check("through Teacher: a duplicate-session read prints no line", #lines == 0)

        Fight(5, 80, 3)
        Fire()
        Check("through Teacher: a continued session reports the fight's growth, not the session total",
            #lines == 1 and lines[1] == "LOCKED 591 hits=3 total=30 per=10")

        -- A re-pull inside the read delay: the first fight's read meets the next fight (secret) and is carried into
        -- it, so the merged read's line counts both fights' draws against the one session total.
        lines[1] = nil
        Fight(6, 50, 2)
        ns.Teacher.Start(22)
        L.Drew(SMITE) -- the re-pull draws before the carry, so the carry must add to live counts, not replace them
        S.sessionsFail = "secret"
        Fire()
        S.sessionsFail = nil
        S.sessions = Session(6, 80)
        ns.Teacher.Seen(30)
        L.Drew(SMITE)
        ns.Teacher.Finish(30)
        L.EndFight()
        local carried = #lines
        Fire()
        Check("through Teacher: a carried fight's draws count at the merged read",
            carried == 0 and #lines == 1 and lines[1] == "LOCKED 591 hits=4 total=80 per=20")
    end
end
