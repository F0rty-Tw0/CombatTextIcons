-- Unit checks for Ticks.lua, the period rule (spec 2026-11-05-forever-tick-heal-icons, "Ticks.lua: the period rule").
-- Called by tests/checks_forever.lua with the same T table.

return function(T)
    local Check = T.Check
    -- Forever by default. `saved` becomes store.lockedTicks (nil: Init creates {}).
    local function Fresh(interface, saved)
        local ns = T.Boot(function(S) S.interface = interface or 16001 CombatTextIconsCharDB = {} end)
        local store = { lockedTicks = saved }
        ns.Ticks.Init(store)

        return ns.Ticks, store, ns
    end
    local function Saved(period, kind, school, misses)
        return { period = period, kind = kind or "damage", school = school, misses = misses or 0 }
    end
    -- Whether `list` is exactly one fit, of spell `id`.
    local function Only(list, id) return #list == 1 and list[1].spellID == id end
    -- Cast 594 at 10 on "p"; ticks at 13, 16, 19 (school 32). Returns the three Fits lists.
    local function ThreeTicks(X)
        X.NoteCast(594, 10, "p", "damage")

        return X.Fits("p", "damage", 32, 13), X.Fits("p", "damage", 32, 16), X.Fits("p", "damage", 32, 19)
    end
    local function Tick(X, now, school) return X.Fits("p", "damage", school or 32, now) end
    local function Heal(X, now) return X.Fits("player", "heal", nil, now) end
    local function Near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end
    local function Empty(store) return next(store.lockedTicks) == nil end
    local function Count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end

        return n
    end

    do
        local X, store = Fresh()
        local a, b, c = ThreeTicks(X)
        local e = store.lockedTicks[594]
        Check("ticks: three ticks learn the period; the third already fits",
            #a == 0 and #b == 0 and Only(c, 594) and e ~= nil and Near(e.period, 3.0) and e.kind == "damage"
                and e.school == 32 and e.misses == 0)
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13)
        Tick(X, 16)
        Check("ticks: two ticks save nothing", Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13.0)
        Tick(X, 16.0625)
        Tick(X, 19.125)
        local e = store.lockedTicks[594]
        Check("ticks: the period is the mean spacing from the first matched tick to the last",
            e ~= nil and Near(e.period, (9.125 - 3.0) / 2))
    end

    -- S7 run 1 (2026-11-07): SW:P 970's first tick landed 3.09 s after its cast, then ticked every 2.95-3.04 s, so
    -- 3 * 3.09 missed the third tick by 0.185 s and the learner saved 6.03 from the 6, 12 and 18 s ticks.
    do
        local X, store = Fresh()
        X.NoteCast(970, 10, "p", "damage")
        for _, at in ipairs({ 13.091, 16.045, 19.088, 22.079, 25.05, 27.998 }) do Tick(X, at) end
        local e = store.lockedTicks[970]
        Check("ticks: a first tick 0.09 s late still learns the tick spacing, not twice it",
            e ~= nil and Near(e.period, (9.088 - 3.091) / 2))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        for _, at in ipairs({ 13.2, 16.0, 22.0, 28.0 }) do Tick(X, at) end
        Check("ticks: a period with a cast-free delay near its half learns nothing", Empty(store))
    end

    -- S8 run 1 (2026-11-07): 970 learned 2.966 on a 3.0 s tick that lands about 0.1 s late, so its 4th and 5th ticks
    -- landed 0.18 and 0.24 s after k * period, fit nothing, and never refined the period.
    do
        local X = Fresh(nil, { [970] = Saved(2.966, "damage", 32) })
        X.NoteCast(970, 10, "p", "damage")
        local late = Tick(X, 10 + 4 * 2.966 + 0.177)
        X.NoteCast(970, 30, "p", "damage")
        local early = Tick(X, 30 + 2 * 2.966 - 0.2)
        Check("ticks: a tick up to LAG after k * period fits; one more than TOL before it doesn't",
            Only(late, 970) and #early == 0)
    end

    -- S7 run 1: PW:S 600, cast on Renew 6074's first tick, took Renew's next three ticks as its own period.
    do
        local X, store = Fresh()
        X.NoteCast(6074, 10, "player", "heal")
        X.NoteCast(600, 12.9, "player", "heal")
        for _, at in ipairs({ 12.9, 15.9, 18.9, 21.9 }) do Heal(X, at) end
        Check("ticks: a cast on an older unsaved cast's tick phase learns nothing from those ticks", Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(6074, 10, "player", "heal")
        X.NoteCast(600, 14.5, "player", "heal")
        for _, at in ipairs({ 17.5, 20.5, 23.5 }) do Heal(X, at) end
        Check("ticks: a cast off an older cast's tick phase still learns", store.lockedTicks[600] ~= nil)
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        for _, at in ipairs({ 11.0, 13.0, 16.0, 19.0, 22.0 }) do Tick(X, at) end
        local e = store.lockedTicks[594]
        Check("ticks: delay order: the first d1 that qualifies wins", e ~= nil and Near(e.period, 3.0))
    end

    -- Taken ticks refine the period (S5, 2026-11-06: Renew learned at 3.034 while it ticks every 3.00, so its 4th and
    -- 5th ticks fell outside TOL and one was drawn as the proc).
    do
        local X = Fresh(nil, { [139] = Saved(3.034, "heal") })
        X.NoteCast(139, 10, "player", "heal")
        local fitted = 0
        for k = 1, 6 do
            local list = Heal(X, 10 + 3 * k)
            if Only(list, 139) then
                X.Take(139, list[1].slot)
                fitted = fitted + 1
            end
        end
        Check("ticks: taken ticks every 3.00 s refine a period learned at 3.034, so ticks 4 to 6 still fit", fitted == 6)
    end

    do
        local X, store = Fresh(nil, { [139] = Saved(3.034, "heal") })
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 16)
        Check("ticks: a fit nobody takes leaves the period", Near(store.lockedTicks[139].period, 3.034))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13.0)
        Tick(X, 16.0625)
        local third = Tick(X, 19.125)
        X.Take(594, third[1].slot)
        Check("ticks: the tick that learned the period, taken, does not refine it (its delay is in the mean already)",
            Near(store.lockedTicks[594].period, (9.125 - 3.0) / 2))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(589, 10, "p", "damage")
        Tick(X, 13)
        Tick(X, 16)
        Tick(X, 19)
        Check("ticks: two casts on one stamp learn nothing", Empty(store))

        X.NoteCast(594, 20, "p", "damage")
        Tick(X, 23)
        Tick(X, 26)
        Tick(X, 29)
        Check("ticks: alone again on a later stamp learns", store.lockedTicks[594] ~= nil and store.lockedTicks[589] == nil)
    end

    do -- Spec 2026-11-07-forever-swp-stamp-partner: a tickless spell (Mind Blast, Smite) is no stamp partner
        local function Learns594(first, second)
            local X, store = Fresh()
            X.NoteCast(first, 10, "p", "damage")
            X.NoteCast(second, 10, "p", "damage")
            for _, at in ipairs({ 13, 16, 19 }) do Tick(X, at) end
            return store
        end
        local s = Learns594(8102, 594)
        Check("ticks: SW:P on Mind Blast's stamp learns its period", s.lockedTicks[594] and Near(s.lockedTicks[594].period, 3.0)
            and s.lockedTicks[8102] == nil)
        s = Learns594(594, 8102)
        Check("ticks: SW:P before Mind Blast on one stamp learns too", s.lockedTicks[594] and Near(s.lockedTicks[594].period, 3.0))
        s = Learns594(591, 594)
        Check("ticks: SW:P on Smite's stamp learns, Smite doesn't", s.lockedTicks[594] and s.lockedTicks[591] == nil)
        s = Learns594(14914, 594)
        Check("ticks: SW:P on an unlisted hard cast's stamp (Holy Fire) learns nothing", Empty(s))

        local X, store = Fresh()
        X.NoteCast(8102, 10, "p", "damage")
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 10.4) -- Mind Blast's own hit, lagged past CAST_GAP
        for _, at in ipairs({ 13, 16, 19 }) do Tick(X, at) end
        Check("ticks: a lagged Mind Blast hit doesn't stop SW:P learning",
            store.lockedTicks[594] and Near(store.lockedTicks[594].period, 3.0))

        X, store = Fresh()
        X.NoteCast(8102, 10, "p", "damage")
        for _, at in ipairs({ 13, 16, 19 }) do Tick(X, at) end
        Check("ticks: a lone Mind Blast learns nothing", Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(5019, 12.7, nil, "damage")
        Tick(X, 13)
        Tick(X, 16)
        Tick(X, 19)
        Check("ticks: a tick 0.3 s after a cast joins no delay", Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(5019, 12.5, nil, "damage")
        Tick(X, 13)
        Tick(X, 16)
        Tick(X, 19)
        Check("ticks: a tick 0.5 s after a cast joins", store.lockedTicks[594] ~= nil)
    end

    do -- S5 run 2 (2026-11-06): Shoot every 1.8 s put SW:P's ticks on or just after its casts, so SW:P never learned
        local X, store = Fresh()
        X.NoteHitSchool(5019, 64)
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13)
        X.NoteCast(5019, 15.8, "p", "damage")
        Tick(X, 16)
        X.NoteCast(5019, 19, "p", "damage")
        Tick(X, 19)
        local e = store.lockedTicks[594]
        Check("ticks: a Shoot known to hit arcane keeps no shadow tick out of the delays, 0.2 s after it or on its stamp",
            e ~= nil and Near(e.period, 3.0) and e.school == 32)
    end

    do
        local X, store = Fresh()
        X.NoteHitSchool(8092, 32)
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13)
        X.NoteCast(8092, 15.8, "p", "damage")
        Tick(X, 16)
        Tick(X, 19)
        Check("ticks: a tick 0.2 s after a cast known to hit its own school joins no delay", Empty(store))
    end

    do -- a wand rhythm after SW:P's first tick: Shoot every 1.8 s from 13.0, each hit 0.6 s after its cast, so the
        -- arcane hits land 3.6, 5.4, 7.2, 9.0, 10.8 s after SW:P's cast: 3.6, 2 * 3.6 and 3 * 3.6 among them
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13)
        for _, at in ipairs({ 13.0, 14.8, 16.6, 18.4, 20.2 }) do
            X.NoteCast(5019, at, "p", "damage")
            Tick(X, at + 0.6, 64)
        end
        local e = store.lockedTicks[594]
        Check("ticks: a steady Shoot rhythm teaches SW:P no arcane period", e == nil or e.school ~= 64)
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(5019, 12.8, nil, "damage")
        local ok, list = pcall(X.Fits, "p", "damage", 32, 13)
        Check("ticks: a harmful cast with no plate stays quiet", ok and #list == 0 and Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(139, 10, "player", "heal")
        X.NoteCast(5019, 16, nil, "damage")
        Heal(X, 13)
        Heal(X, 16)
        Heal(X, 19)
        Check("ticks: a heal on a cast's stamp joins nothing", Empty(store))
    end

    do -- an event that fits a saved spell on the key joins no new cast's delays
        local X, store = Fresh(16001, { [139] = Saved(3.0, "heal") })
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13)
        X.NoteCast(2061, 13.05, "player", "heal")
        local renew = true
        for _, at in ipairs({ 16, 19, 22, 25, 28 }) do renew = Only(Heal(X, at), 139) and renew end
        Check("ticks: Renew's ticks join no lone Flash Heal's delays: Flash Heal learns nothing, each tick fits 139 only",
            store.lockedTicks[2061] == nil and renew)

        X, store = Fresh(16001, { [589] = Saved(3.0, "damage", 32) })
        X.NoteCast(589, 10, "p", "damage")
        Tick(X, 13)
        X.NoteCast(8092, 13.05, "p", "damage")
        local swp = true
        for _, at in ipairs({ 16, 19, 22, 25, 28 }) do swp = Only(Tick(X, at), 589) and swp end
        Check("ticks: SW:P's ticks join no lone Mind Blast's delays: Mind Blast learns nothing, each tick fits 589 only",
            store.lockedTicks[8092] == nil and swp)
    end

    do
        local X, store = Fresh()
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13)
        Heal(X, 16)
        local c = Heal(X, 19)
        local e = store.lockedTicks[139]
        Check("ticks: heals learn a heal entry with no school",
            e ~= nil and e.kind == "heal" and e.school == nil and Near(e.period, 3.0) and Only(c, 139))
    end

    do
        local X, store = Fresh()
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13)
        Heal(X, 16)
        X.NoteCast(5019, 19, nil, "damage")
        Heal(X, 19)
        Check("ticks: a cast of the heal's own frame counts, logged first or after (F8)", Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13)
        Heal(X, 13)
        Heal(X, 16)
        Heal(X, 16)
        Heal(X, 19)
        local again = Heal(X, 19)
        local e = store.lockedTicks[139]
        Check("ticks: heals on one stamp join once",
            e ~= nil and Near(e.period, 3.0) and e.misses == 0 and Only(again, 139) and Count(store.lockedTicks) == 1)
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 10.5)
        Tick(X, 11.0)
        Tick(X, 11.5)
        Check("ticks: a period below MIN_PERIOD learns nothing", Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13)
        Heal(X, 16)
        X.NoteCast(5019, 18.875, nil, "damage")
        Heal(X, 19)
        Check("ticks: a heal is cast-free by its stamp, not by the gap", store.lockedTicks[139] ~= nil)
    end

    do
        local X, store = Fresh()
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13)
        for _ = 1, 17 do Heal(X, 16) end
        Heal(X, 19)
        Check("ticks: one stamp joins once against the 16-delay cap", store.lockedTicks[139] ~= nil)
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        local a, b, c = X.Fits("p", "heal", nil, 13), X.Fits("p", "heal", nil, 16), X.Fits("p", "heal", nil, 19)
        Check("ticks: a damage cast takes no heal events", #a == 0 and #b == 0 and #c == 0 and Empty(store))
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13, 32)
        Tick(X, 16, 2)
        Tick(X, 19, 32)
        Tick(X, 22, 32)
        Check("ticks: delays are per school: a hit of another school is not the missing tick", Empty(store))
    end

    -- S8 run 1 (2026-11-07): a wand hit (arcane 64) before the wand's lock formed was 970's first cast-free event; it
    -- fixed the cast's school, and SW:P's shadow ticks after it joined no delays in two fights.
    do
        local X, store = Fresh()
        X.NoteCast(970, 10, "p", "damage")
        Tick(X, 12.662, 64)
        for _, at in ipairs({ 13.047, 16.118, 19.082 }) do Tick(X, at, 32) end
        local e = store.lockedTicks[970]
        Check("ticks: a hit of another school first doesn't stop the shadow ticks learning",
            e ~= nil and e.school == 32 and Near(e.period, (9.082 - 3.047) / 2))
    end

    do
        local X = Fresh(16001, { [594] = Saved(3.0, "damage", 32) })
        X.NoteCast(594, 30, "p", "damage")
        local inside, outside = Tick(X, 33.25), Tick(X, 33.3125)
        local early, tooEarly = Tick(X, 32.875), Tick(X, 32.8125)
        Check("ticks: fit window edges are LAG after the tick and TOL before it",
            Only(inside, 594) and #outside == 0 and Only(early, 594) and #tooEarly == 0)

        local zero, kmax, past = Tick(X, 30.5), Tick(X, 66.0), Tick(X, 69.0)
        Check("ticks: k runs 1..KMAX", #zero == 0 and Only(kmax, 594) and #past == 0)

        Check("ticks: a fit needs its key and school",
            #X.Fits("q", "damage", 32, 33) == 0 and #X.Fits("p", "damage", 2, 33) == 0)
    end

    do
        local X = Fresh(16001, { [594] = Saved(3.0, "damage", 32) })
        X.NoteCast(594, 30, "p", "damage")
        local list = Tick(X, 33)
        local again = Tick(X, 33)
        X.Take(594, list[1].slot)
        local taken = Tick(X, 33)
        local later = Tick(X, 36)
        Check("ticks: a taken slot fits no more, the next k does",
            Only(list, 594) and Only(again, 594) and #taken == 0 and Only(later, 594))
    end

    do -- S6 run 3 (2026-11-06, s6-run3.sv.lua line 208): a Mind Blast hit on its cast's stamp, 30.138 s after an
        -- ended SW:P cast, fit SW:P's tick k=10 and drew SW:P's icon
        local X = Fresh(16001, { [594] = Saved(3.009, "damage", 32) })
        X.NoteCast(594, 176039.999, "p", "damage")
        X.NoteCast(8102, 176070.137, "p", "damage")
        local onStamp = Tick(X, 176070.137)
        Check("ticks: an event on the stamp of a cast that may hit its school fits nothing", #onStamp == 0)

        X = Fresh(16001, { [594] = Saved(3.0, "damage", 32) })
        X.NoteCast(594, 30, "p", "damage")
        X.NoteCast(8092, 32.8, "p", "damage")
        local after, past = Tick(X, 33), Tick(X, 36)
        Check("ticks: an event 0.2 s after such a cast fits nothing; its slot stays free, the next tick fits",
            #after == 0 and Only(past, 594))

        X = Fresh(16001, { [594] = Saved(3.0, "damage", 32) })
        X.NoteHitSchool(5019, 64)
        X.NoteCast(594, 30, "p", "damage")
        X.NoteCast(5019, 33, "p", "damage")
        Check("ticks: an event on the stamp of a cast known to hit another school still fits", Only(Tick(X, 33), 594))
    end

    do
        local X = Fresh()
        local ok, list = pcall(X.Fits, "p", "damage", 32, 5)
        Check("ticks: Fits before any cast is empty", ok and #list == 0)
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, nil, "damage")
        local a, b, c = Tick(X, 13), Tick(X, 16), Tick(X, 19)
        Check("ticks: a cast with no key learns nothing", #a == 0 and #b == 0 and #c == 0 and Empty(store))
    end

    do
        local X = Fresh(16001, { [9] = Saved(3, "heal"), [8] = Saved(3, "damage", 32) })
        X.NoteCast(7, 10, nil, "damage")
        Check("ticks: IsOwnCast is a noted ID or a saved heal",
            X.IsOwnCast(7) and X.IsOwnCast(9) and not X.IsOwnCast(8) and not X.IsOwnCast(4))
    end

    do
        local _, store = Fresh(16001, {
            [594] = Saved(3, "damage", 32),
            x = Saved(3, "damage", 32),
            [5] = { period = "3", kind = "damage", school = 32, misses = 0 },
            [6] = { period = 3, kind = "bogus", school = 32, misses = 0 },
            [7] = { period = 3, kind = "damage", misses = 0 },
            [10] = Saved(0, "damage", 32),
            [11] = { period = 3, kind = "damage", school = 32 },
        })
        Check("ticks: Init drops invalid entries", Count(store.lockedTicks) == 1 and store.lockedTicks[594] ~= nil)
    end

    do
        local _, nilStore = Fresh()
        local _, badStore = Fresh(16001, "bad")
        Check("ticks: Init makes the table",
            type(nilStore.lockedTicks) == "table" and type(badStore.lockedTicks) == "table")
    end

    do
        local X, store = Fresh()
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13)
        Tick(X, 16)
        X.Init(store)
        local list = Tick(X, 19)
        Check("ticks: Init clears the live state", #list == 0 and Empty(store))
    end

    do
        local X, store = Fresh()
        ThreeTicks(X)
        X.Forget()
        Check("ticks: Forget clears saved and live state",
            next(store.lockedTicks) == nil and #Tick(X, 22) == 0 and not X.IsOwnCast(594))
    end

    do
        local X, _, ns = Fresh()
        local lines = {}
        ns.Debug = function(format, ...) lines[#lines + 1] = string.format(format, ...) end
        ThreeTicks(X)
        Check("ticks: the learned line", #lines == 1 and lines[1] == "TICKS learned 594 period=3.000 kind=damage")
    end

    do
        local ns = T.Boot(function(S) S.interface = 16001 CombatTextIconsCharDB = {} end)
        ns.Ticks.NoteCast(594, 10, "p", "damage")
        local ok, list = pcall(ns.Ticks.Fits, "p", "damage", 32, 13)
        Check("ticks: calls before Init find nothing and do not error", ok and #list == 0)
    end

    do
        local X, store = Fresh(120105)
        local a, b, c = ThreeTicks(X)
        Check("ticks: retail does nothing",
            #a == 0 and #b == 0 and #c == 0 and Empty(store) and not X.IsOwnCast(594)
                and type(store.lockedTicks) == "table")
    end

    do
        -- Spec: every entry point except Init and Forget returns at once off Forever, so a retail NoteCast notes nothing.
        -- Turning Forever on afterwards exposes a cast that was noted anyway: it would learn and read as your own cast.
        local X, store, ns = Fresh(120105)
        X.NoteCast(594, 10, "p", "damage")
        ns.IsForever = true
        local a, b, c = Tick(X, 13), Tick(X, 16), Tick(X, 19)
        Check("ticks: retail NoteCast notes no cast",
            #a == 0 and #b == 0 and #c == 0 and Empty(store) and not X.IsOwnCast(594))
    end

    -- Lifecycle: miss, retire, EndFight, PlateGone, groups. Seeded with 594 (period 3, damage, school 32, misses M).
    local function Seeded(M, interface)
        return Fresh(interface, { [594] = Saved(3.0, "damage", 32, M) })
    end
    -- Cast 594 on "p" at `at`, then a Fits at `at + 3.5`: due, between the k = 1 and k = 2 windows, no fit, checked.
    local function CastDue(X, at)
        X.NoteCast(594, at, "p", "damage")
        X.Fits("p", "damage", 32, at + 3.5)
    end

    do
        local X, store = Seeded(0)
        CastDue(X, 10)
        X.NoteCast(594, 20, "p", "damage")
        Check("miss: a checked cast with no fit adds one miss", store.lockedTicks[594].misses == 1)
    end

    do
        local X, store = Seeded(0)
        local seen = {}
        for _, at in ipairs({ 10, 20, 30, 40 }) do
            CastDue(X, at)
            seen[#seen + 1] = store.lockedTicks[594] and store.lockedTicks[594].misses
        end
        Check("miss: one miss after the cast at 20, two after 30", seen[2] == 1 and seen[3] == 2)
        Check("miss: three checked casts without a fit retire the entry", store.lockedTicks[594] == nil)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        Check("miss: the event at 13.0 is a fit", Only(Tick(X, 13.0), 594))
        X.NoteCast(594, 20, "p", "damage")
        Check("miss: a fit resets the misses", store.lockedTicks[594].misses == 0)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(594, 20, "p", "damage")
        X.NoteCast(594, 30, "p", "damage")
        X.NoteCast(594, 40, "p", "damage")
        Check("miss: unchecked casts change nothing", store.lockedTicks[594] and store.lockedTicks[594].misses == 2)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        Check("miss: 0.1875 before the window is no fit", #Tick(X, 12.8125) == 0)
        X.NoteCast(594, 20, "p", "damage")
        Check("miss: an event before the window leaves the cast unchecked", store.lockedTicks[594].misses == 2)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        Check("miss: the window start is a fit", Only(Tick(X, 12.875), 594))
        X.NoteCast(594, 20, "p", "damage")
        Check("miss: the window start counts as checked, its fit resets", store.lockedTicks[594].misses == 0)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13.5)
        X.NoteCast(594, 20, "q", "damage")
        Check("miss: a recast on another key does not end the cast", store.lockedTicks[594].misses == 2)
    end

    do
        local X, store = Fresh(16001, { [594] = Saved(3.0, "damage", 32, 2), [139] = Saved(3.0, "heal", nil, 2) })
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(139, 10, "player", "heal")
        Tick(X, 13.5)
        Heal(X, 13.5)
        X.EndFight()
        Check("EndFight: a checked damage cast with no fit counts, and the third miss retires it",
            store.lockedTicks[594] == nil)
        Check("EndFight: the player key is not ended", store.lockedTicks[139] and store.lockedTicks[139].misses == 2)
        Check("EndFight: the player key still ticks", Only(Heal(X, 16), 139))
        Check("EndFight: the damage key is gone", #Tick(X, 13) == 0)
    end

    do
        local X, store = Seeded(0)
        CastDue(X, 10)
        X.EndFight()
        X.NoteCast(594, 30, "p", "damage")
        Check("EndFight: the cast ends once; a later recast does not count it again",
            store.lockedTicks[594].misses == 1)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        X.EndFight()
        Check("EndFight: an unchecked cast changes nothing", store.lockedTicks[594].misses == 2)
    end

    do
        local X, store = Fresh(16001, { [594] = Saved(3.0, "damage", 32, 2), [589] = Saved(3.0, "damage", 32, 0) })
        X.NoteCast(594, 10, "p", "damage")
        X.NoteCast(589, 10, "q", "damage")
        Tick(X, 13.5)
        X.PlateGone("p")
        Check("PlateGone: that plate's checked cast ends and retires the entry", store.lockedTicks[594] == nil)
        Check("PlateGone: another plate keeps its cast", Only(X.Fits("q", "damage", 32, 13), 589))
    end

    do
        local X = Seeded(0)
        X.NoteCast(594, 10, "p", "damage")
        X.PlateGone("p")
        Check("PlateGone: the key is forgotten", #Tick(X, 13) == 0)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        local list = Tick(X, 13)
        X.Take(594, list[1].slot)
        Check("slots: a taken slot is no fit", #Tick(X, 13) == 0)
        X.NoteCast(594, 10, "p", "damage")
        Check("slots: the ending cast's slots are removed (recast)", Only(Tick(X, 13), 594))
        X.Take(594, Tick(X, 13)[1].slot)
        X.PlateGone("p")
        X.NoteCast(594, 10, "p", "damage")
        Check("slots: the ending cast's slots are removed (PlateGone)",
            Only(Tick(X, 13), 594) and store.lockedTicks[594] ~= nil)
    end

    do
        local X, store = Seeded(2)
        X.NoteCast(594, 10, "p", "damage")
        Tick(X, 13.5)
        X.NoteCast(594, 20, nil, "damage")
        X.NoteCast(139, 21, nil, "heal")
        Check("group: a nil-key cast ends nothing and records no cast",
            store.lockedTicks[594] and store.lockedTicks[594].misses == 2)
        Check("group: the nil-key call still noted the ID", X.IsOwnCast(139))
    end

    do
        local X, store = Fresh(16001, { [139] = Saved(3.0, "heal", nil, 0) })
        X.NoteCast(139, 10, "player", "heal")
        Heal(X, 13.5)
        X.NoteCast(139, 20, "player", "heal")
        Check("heal recast: a checked heal cast with no fit counts", store.lockedTicks[139].misses == 1)
    end

    do
        local X, _, ns = Seeded(0)
        local lines = {}
        ns.Debug = function(format, ...) lines[#lines + 1] = string.format(format, ...) end
        for _, at in ipairs({ 10, 20, 30, 40 }) do CastDue(X, at) end
        Check("miss: one retired line", #lines == 1 and lines[1] == "TICKS retired 594")
    end

    do
        local X, store = Seeded(0, 120105)
        for _, at in ipairs({ 10, 20, 30, 40 }) do CastDue(X, at) end
        X.EndFight()
        X.PlateGone("p")
        Check("retail: the lifecycle does nothing", store.lockedTicks[594] and store.lockedTicks[594].misses == 0)
    end

    -- Task 1.3: Locked.Observe joins the tick fits. Modules direct, as checks_locked.lua.
    local function Join(saved, schools)
        local ns = T.Boot(function(S) S.interface = 16001 CombatTextIconsCharDB = {} end)
        local store = { lockedTicks = saved, lockedSchools = schools }
        ns.Locked.Init(store)
        ns.Ticks.Init(store)
        local takes, fitsCalls = {}, 0
        local take, fits = ns.Ticks.Take, ns.Ticks.Fits
        ns.Ticks.Take = function(id, slot) takes[#takes + 1] = id take(id, slot) end
        ns.Ticks.Fits = function(...) fitsCalls = fitsCalls + 1 return fits(...) end

        return ns, takes, function() return fitsCalls end
    end
    local function Is(spell, fits, sole, count) return sole == spell and count == fits end
    local function Taken(takes, id) return #takes == 1 and takes[1] == id end

    do
        local ns, takes, calls = Join({ [594] = Saved(3.0, "damage", 32) })
        ns.Ticks.NoteCast(594, 10, "p", "damage")
        Check("join: a tick-only sole fit names the spell and takes the slot",
            Is(594, 1, ns.Locked.Observe("p", 32, 13)) and Taken(takes, 594))
        Check("join: Observe calls Ticks.Fits once", calls() == 1)
        Check("join: one name per tick (the slot is taken)", Is(nil, 0, ns.Locked.Observe("p", 32, 13)))
    end

    do -- a cast lock's fit tells Ticks the spell's hit school: two Shoots lock at 0.6 s, the third hit fits
        local ns = Join()
        local L, X = ns.Locked, ns.Ticks
        for _, at in ipairs({ 4, 6, 8 }) do
            L.NoteCast(5019, at)
            X.NoteCast(5019, at, "p", "damage")
            L.Observe("p", 64, at + 0.6)
        end
        X.NoteCast(594, 10, "p", "damage")
        L.Observe("p", 32, 13)
        L.NoteCast(5019, 15.8)
        X.NoteCast(5019, 15.8, "p", "damage")
        L.Observe("p", 32, 16)
        L.NoteCast(5019, 19)
        X.NoteCast(5019, 19, "p", "damage")
        L.Observe("p", 32, 19)
        local fit = X.Fits("p", "damage", 32, 22)[1]
        Check("join: a Shoot's lock fit lets SW:P's shadow ticks 0.2 s after a Shoot, or on its stamp, teach 594",
            fit ~= nil and fit.spellID == 594)
    end

    -- Events in time order on "p": { "shoot", at } casts Shoot and observes its arcane hit 0.6 s later, { "swp", at }
    -- casts SW:P, { "tick", at } observes a shadow hit.
    local function Play(ns, events)
        for _, event in ipairs(events) do
            local what, at = event[1], event[2]
            if what == "tick" then ns.Locked.Observe("p", 32, at) else
                local id = what == "shoot" and 5019 or 594
                ns.Locked.NoteCast(id, at)
                ns.Ticks.NoteCast(id, at, "p", "damage")
                if id == 5019 then ns.Locked.Observe("p", 64, at + 0.6) end
            end
        end
    end
    local function Shoots(ats)
        local events = {}
        for i, at in ipairs(ats) do events[i] = { "shoot", at } end

        return events
    end

    do -- a locked wand's arcane hits 1.8, 3.6 and 5.4 s after SW:P are Shoot's own hits, not SW:P ticks
        local ns = Join()
        Play(ns, Shoots({ 4, 6, 8 }))
        Play(ns, { { "swp", 10 }, { "shoot", 11.2 }, { "tick", 13 }, { "shoot", 13.0 }, { "shoot", 14.8 }, { "tick", 16 },
            { "tick", 19 } })
        local fit = ns.Ticks.Fits("p", "damage", 32, 22)[1]
        Check("join: a Shoot hit its cast lock fits joins no SW:P delay, so SW:P learns its own 3.0 s shadow period",
            fit ~= nil and fit.spellID == 594)
    end

    do -- first fight: SW:P and the wand start together, so Shoot's lock forms only at its second hit
        local ns = Join()
        Play(ns, { { "swp", 10 } })
        Play(ns, Shoots({ 11.2, 13.0, 14.8, 16.6 }))
        local fit = ns.Ticks.Fits("p", "damage", 64, 19.0)[1]
        Check("join: a wand whose lock forms at its second hit teaches SW:P no arcane period", fit == nil)
    end

    do
        local ns, takes = Join({ [594] = Saved(3.0, "damage", 32), [589] = Saved(2.0, "damage", 32) })
        ns.Ticks.NoteCast(594, 10, "p", "damage")
        ns.Ticks.NoteCast(589, 11, "p", "damage")
        Check("join: two tick fits name nothing and take nothing",
            Is(nil, 2, ns.Locked.Observe("p", 32, 13)) and #takes == 0)
    end

    do
        local ns, takes = Join({ [594] = Saved(1.0, "damage", 32) }, { [594] = { school = 32, strays = 0 } })
        ns.Locked.NoteCast(594, 10)
        ns.Ticks.NoteCast(594, 10, "p", "damage")
        Check("join: a tick and Rule 1 on one spell count once",
            Is(594, 1, ns.Locked.Observe("p", 32, 11)) and Taken(takes, 594))
    end

    do
        local ns, takes = Join({ [589] = Saved(1.0, "damage", 32) }, { [594] = { school = 32, strays = 0 } })
        ns.Locked.NoteCast(594, 10)
        ns.Ticks.NoteCast(589, 10, "p", "damage")
        Check("join: a tick plus another spell's Rule 1 is two fits",
            Is(nil, 2, ns.Locked.Observe("p", 32, 11)) and #takes == 0)
    end

    do
        local ns, takes = Join({ [594] = Saved(0.9, "damage", 32) })
        local L = ns.Locked
        L.NoteCast(594, 10)
        L.Observe("p", 32, 10.9)
        L.NoteCast(594, 11.4)
        L.Observe("p", 32, 12.3)
        L.NoteCast(594, 15)
        ns.Ticks.NoteCast(594, 15, "p", "damage")
        Check("join: Rule 2 and a tick on one spell name it once and take the slot",
            Is(594, 1, L.Observe("p", 32, 15.9)) and Taken(takes, 594))
        Check("join: that slot is taken", #ns.Ticks.Fits("p", "damage", 32, 15.9) == 0)
    end

    do
        local ns, takes = Join({})
        local L = ns.Locked
        L.NoteCast(5019, 10)
        L.Observe("p", 32, 10.9)
        L.NoteCast(5019, 11.4)
        L.Observe("p", 32, 12.3)
        L.NoteCast(5019, 15.5)
        Check("join: Rule 2 alone takes nothing", Is(5019, 1, L.Observe("p", 32, 16.4)) and #takes == 0)
    end

    -- Core wiring: the hooks reach Ticks.
    do
        local PLATE_UNIT = "nameplate1"
        local function TWired(interface, setup)
            local ns = T.Boot(function(S)
                S.interface = interface or 16001
                if setup then setup(S) end
            end)
            local calls, args = {}, {}
            for _, name in ipairs({ "NoteCast", "Forget", "EndFight", "PlateGone" }) do
                local real = ns.Ticks[name]
                calls[name] = 0
                ns.Ticks[name] = function(...)
                    calls[name] = calls[name] + 1
                    args[name] = { ... }
                    return real(...)
                end
            end
            ns.Display.Plate = function() end
            ns.Display.Player = function() end

            return ns, T.State(), calls, args
        end
        local function SeedTicks() CombatTextIconsCharDB = { lockedTicks = { [594] = Saved(3.0, "damage", 32, 2) } } end
        local function Cast(ns, S, now, id, unit)
            S.now = now
            ns.Core.UNIT_SPELLCAST_SUCCEEDED(unit or "player", "c", id)
        end

        local ns, S, calls, args = TWired()
        C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false)
        S.target = PLATE_UNIT
        Cast(ns, S, 20, 5019)
        local plate = C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false)
        Check("ticks wiring: a harmful cast with a plate passes the plate and damage",
            calls.NoteCast == 1 and args.NoteCast[1] == 5019 and args.NoteCast[2] == 20 and args.NoteCast[3] == plate
            and args.NoteCast[4] == "damage")

        ns, S, calls, args = TWired()
        Cast(ns, S, 20, 5019)
        Check("ticks wiring: a harmful cast with no plate still calls with a nil key",
            calls.NoteCast == 1 and args.NoteCast[3] == nil and args.NoteCast[4] == "damage")

        ns, S, calls = TWired()
        Cast(ns, S, 20, 5019, "pet")
        Check("ticks wiring: a pet cast does not call NoteCast", calls.NoteCast == 0)

        ns, S, calls, args = TWired()
        S.harmful[139] = false
        Cast(ns, S, 20, 139)
        Check("ticks wiring: a helpful cast passes the player key and heal",
            calls.NoteCast == 1 and args.NoteCast[1] == 139 and args.NoteCast[2] == 20 and args.NoteCast[3] == "player"
            and args.NoteCast[4] == "heal")

        ns, S, calls, args = TWired()
        S.group = true
        S.target = PLATE_UNIT
        S.harmful[139] = false
        local ok = pcall(Cast, ns, S, 20, 5019)
        local harmfulArgs = args.NoteCast
        ok = pcall(Cast, ns, S, 21, 139) and ok
        Check("ticks wiring: in a group both kinds call with a nil key and do not error",
            ok and calls.NoteCast == 2 and harmfulArgs[3] == nil and harmfulArgs[4] == "damage"
            and args.NoteCast[3] == nil and args.NoteCast[4] == "heal")

        ns, S = TWired(16001, SeedTicks)
        C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false)
        S.target = PLATE_UNIT
        Cast(ns, S, 10, 594)
        S.now = 13.5
        ns.Core.UNIT_COMBAT(PLATE_UNIT, "WOUND", "", T.Secret(31), 32)
        S.group = true
        Cast(ns, S, 20, 594)
        Check("ticks wiring: a cast in a group mid-fight keeps the saved entry",
            T.Store().lockedTicks[594] ~= nil and T.Store().lockedTicks[594].misses == 2)

        ns, S = TWired(16001, SeedTicks)
        ns.Ticks.NoteCast(594, 10, "p", "damage")
        Check("ticks wiring: Boot hands Ticks the saved entries", Is(594, 1, ns.Locked.Observe("p", 32, 13)))

        ns, S = TWired()
        Check("ticks wiring: Init ran on Boot", type(T.Store().lockedTicks) == "table")

        ns, S, calls = TWired(16001, SeedTicks)
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("ticks wiring: /cti forget calls Ticks.Forget and empties the table",
            calls.Forget == 1 and next(T.Store().lockedTicks) == nil)

        ns, S, calls, args = TWired()
        S.now = 25
        ns.Core.PLAYER_REGEN_ENABLED()
        Check("ticks wiring: the fight's end calls EndFight once, with no args", calls.EndFight == 1 and #args.EndFight == 0)

        ns, S, calls, args = TWired()
        S.now = 25
        ns.Core.NAME_PLATE_UNIT_REMOVED(PLATE_UNIT)
        Check("ticks wiring: a removed plate calls PlateGone with the plate only",
            calls.PlateGone == 1 and args.PlateGone[1] == C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false)
            and #args.PlateGone == 1)

        do
            local index = {}
            for position, file in ipairs(T.TocFiles()) do index[file] = position end
            Check("ticks wiring: the toc loads Ticks.lua right before Locked.lua",
                index["Ticks.lua"] ~= nil and index["Ticks.lua"] == index["Locked.lua"] - 1)
        end

        -- End to end: three ticks teach the period, the fourth is named.
        local function Chain(interface)
            local cns, cS = TWired(interface)
            C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false)
            cS.target = PLATE_UNIT
            local returns = {}
            local observe = cns.Locked.Observe
            cns.Locked.Observe = function(...)
                local sole, fits = observe(...)
                returns[#returns + 1] = { sole, fits }

                return sole, fits
            end
            Cast(cns, cS, 10, 594)
            for _, at in ipairs({ 13, 16, 19, 22.0 }) do
                cS.now = at
                cns.Core.UNIT_COMBAT(PLATE_UNIT, "WOUND", "", T.Secret(31), 32)
            end

            return cns, returns
        end

        local cns, returns = Chain()
        local entry = T.Store().lockedTicks[594]
        local last = returns[#returns]
        Check("ticks wiring: end to end the third tick learns 3.0 and the fourth is named",
            entry ~= nil and math.abs(entry.period - 3.0) < 0.01 and last ~= nil and last[1] == 594 and last[2] == 1)

        cns, returns = Chain(120105)
        Check("ticks wiring: retail learns and names nothing",
            next(T.Store().lockedTicks or {}) == nil and #returns == 0
            and #cns.Ticks.Fits(C_NamePlate.GetNamePlateForUnit(PLATE_UNIT, false), "damage", 32, 22.0) == 0)
    end
end
