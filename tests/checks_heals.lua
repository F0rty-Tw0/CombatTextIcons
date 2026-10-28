-- Unit checks for the learned direct heals (Heals.lua): learning from a clear read's heals and helpful casts, the
-- claim of a frame's heals, the saved store's checks. Called by tests/checks.lua with the same T table.
-- Every scenario boots its own rig; a Boot replaces the global stubs.

return function(T)
    local Check = T.Check
    local CHAIN_HEAL, RIPTIDE, PROC = 1064, 61295, 999001

    local function Row(spellID) return { spellID = spellID, total = 1, overkill = 0 } end

    -- A fight of `casts` helpful casts of `spellID`, one per 10 s from t = 10; `heal(k)` is the k-th cast's
    -- heals on its stamp ({ size, ... }), after a 5000 proc on every stamp (shamanheal's Healing Wave frames log
    -- the proc first: 4453, then 120814). Returns heals, helps.
    local function Fight(spellID, casts, heal)
        local heals, helps = {}, {}
        for k = 1, casts do
            local at = 10 * k
            heals[#heals + 1] = { size = 5000, at = at }
            for _, size in ipairs(heal and heal(k) or { 40000 }) do heals[#heals + 1] = { size = size, at = at } end
            helps[#helps + 1] = { spellID = spellID, at = at }
        end
        return heals, helps
    end

    do -- learning
        local ns = T.Boot()
        local H = ns.Heals
        local heals, helps = Fight(CHAIN_HEAL, 2)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: two casts with a heal on their stamp teach nothing yet", not H.IsLearned(CHAIN_HEAL))
        heals, helps = Fight(CHAIN_HEAL, 1)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: a third cast in a later clear read learns the heal", H.IsLearned(CHAIN_HEAL) and H.AnyLearned())
        local entry = T.Store().heals[CHAIN_HEAL]
        Check("heals: the sample is the largest heal on the cast's stamp, not the proc beside it",
            entry.casts == 3 and entry.hits == 3 and #entry.sizes == 3 and entry.sizes[1] == 40000)

        heals, helps = Fight(RIPTIDE, 4)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: a cast that is no healing-done row learns nothing", not H.IsLearned(RIPTIDE))

        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(RIPTIDE, 6, function(k) return k <= 3 and { 40000 } or {} end)
        for _, heal in ipairs(heals) do
            if heal.size == 5000 and heal.at > 30 then heal.at = heal.at + 1 end -- the last 3 stamps hold no heal
        end
        H.Learn(heals, helps, { Row(RIPTIDE) }, 100)
        Check("heals: 3 samples of 6 counted casts are below the hit share: not learned", not H.IsLearned(RIPTIDE))

        heals, helps = Fight(CHAIN_HEAL, 3)
        for k = 1, 3 do helps[#helps + 1] = { spellID = RIPTIDE, at = 10 * k } end
        H.Learn(heals, helps, { Row(CHAIN_HEAL), Row(RIPTIDE) }, 100)
        Check("heals: a stamp with two different helpful casts counts for neither",
            T.Store().heals[CHAIN_HEAL] == nil and T.Store().heals[RIPTIDE].casts == 6)

        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(CHAIN_HEAL, 3)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 0.3)
        Check("heals: heals on every frame of the fight (luck explains the samples): not learned",
            not H.IsLearned(CHAIN_HEAL) and T.Store().heals[CHAIN_HEAL].hits == 3)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 0)
        Check("heals: a read with no duration counts nothing", T.Store().heals[CHAIN_HEAL].casts == 3)
    end

    do -- the claim of a frame's heals
        local ns = T.Boot()
        local H = ns.Heals
        local heals, helps = Fight(CHAIN_HEAL, 3, function(k) return { 40000 + 5000 * k } end) -- 45000-55000
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        local frame = { { size = 5000 }, { size = 60000 }, { size = 32000 } }
        local claims = H.Claim({ CHAIN_HEAL }, frame)
        Check("heals: a learned cast claims the largest heal of its frame inside its padded band",
            claims[2] == CHAIN_HEAL and claims[1] == nil and claims[3] == nil)
        claims = H.Claim({ CHAIN_HEAL }, { { size = 5000 }, { size = 30000 }, { size = 111000 } })
        Check("heals: no heal inside the band (0.7 x 45000 to 2 x 55000): nothing is claimed", next(claims) == nil)
        claims = H.Claim({ RIPTIDE, CHAIN_HEAL, CHAIN_HEAL }, { { size = 50000 }, { size = 40000 } })
        Check("heals: an unlearned cast claims nothing; a cast twice claims the next heal",
            claims[1] == CHAIN_HEAL and claims[2] == CHAIN_HEAL)
        claims = H.Claim({ CHAIN_HEAL }, { { size = nil }, { size = 50000 } })
        Check("heals: a heal with no plain size is never claimed", claims[1] == nil and claims[2] == CHAIN_HEAL)
        H.Forget()
        Check("heals: /cti forget drops the learned heals", not H.IsLearned(CHAIN_HEAL) and not H.AnyLearned()
            and next(T.Store().heals) == nil)
    end

    do -- the saved store is checked, never trusted
        local ns = T.Boot(function()
            CombatTextIconsCharDB = { heals = {
                [CHAIN_HEAL] = { casts = 3, hits = 3, expected = 0.1, sizes = { 40000, 41000, 42000 } },
                [RIPTIDE] = { casts = 2, hits = 3, expected = 0, sizes = { 1 } },
                [PROC] = { casts = 3, hits = 3, expected = -1, sizes = {} },
                [5394] = "junk",
                [77472] = { casts = 3, hits = 3, expected = 0, sizes = { 40000, "big", -5, 0 / 0, 41000, 42000 } },
                [0.5] = { casts = 3, hits = 3, expected = 0, sizes = { 40000, 41000, 42000 } },
            } }
        end)
        local saved = T.Store().heals
        Check("heals: a valid saved heal loads learned", ns.Heals.IsLearned(CHAIN_HEAL))
        Check("heals: saved entries with more hits than casts, a negative expected count, junk or a bad ID are dropped",
            saved[RIPTIDE] == nil and saved[PROC] == nil and saved[5394] == nil and saved[0.5] == nil)
        Check("heals: a saved entry keeps only its positive finite sizes",
            saved[77472] and #saved[77472].sizes == 3 and ns.Heals.IsLearned(77472))
    end

    -- Teacher wiring: a fight's heals on you and helpful casts reach Heals.Learn on a clear read only. Each fight
    -- sees a 53 hit against a one-row damage session (clear unless `seen` says more) with the heal rows `healIDs`.
    local nextSession = 0
    local function Session(healIDs)
        nextSession = nextSession + 1
        local healRows = {}
        for index, id in ipairs(healIDs) do healRows[index] = { spellID = id, totalAmount = 1, overkillAmount = 0 } end
        return { sessionID = nextSession, name = "x", durationSeconds = 13, healRows = healRows,
            rows = { { spellID = 591, totalAmount = 53, overkillAmount = 0 } } }
    end
    local function Feed(ns, heals, helps, flag)
        for _, heal in ipairs(heals) do ns.Teacher.Healed(heal.size, flag or "", heal.at) end
        for _, help in ipairs(helps) do ns.Teacher.Helped(help.spellID, help.at) end
    end
    local function FireAll(S)
        while #S.timers > 0 do table.remove(S.timers, 1).fn() end
    end
    local function TeacherFight(ns, heals, helps, opts)
        local S = T.State()
        S.sessions = { Session({ CHAIN_HEAL }) }
        ns.Teacher.Start(1, opts.group)
        ns.Teacher.Seen(opts.seen or 53)
        Feed(ns, heals, helps, opts.flag)
        ns.Teacher.Finish(100)
        FireAll(S)
    end

    do
        local ns = T.Boot()
        ns.Teacher.area = "clear"
        local heals, helps = Fight(CHAIN_HEAL, 3, function() return { 80000 } end)
        TeacherFight(ns, heals, helps, { group = true })
        Check("heals: a grouped fight's read teaches no heal", T.Store().heals[CHAIN_HEAL] == nil)
        TeacherFight(ns, heals, helps, { seen = 500 })
        Check("heals: a crowded read teaches no heal", ns.Teacher.last.area == "crowded"
            and T.Store().heals[CHAIN_HEAL] == nil)
        TeacherFight(ns, heals, helps, { flag = "CRITICAL" })
        Check("heals: a clear solo read teaches the fight's heals, crits at normal scale",
            ns.Teacher.last.area == "clear" and ns.Heals.IsLearned(CHAIN_HEAL)
            and T.Store().heals[CHAIN_HEAL].sizes[3] == 40000)

        ns = T.Boot()
        ns.Teacher.area = "clear"
        local S = T.State()
        S.sessions = { Session({ CHAIN_HEAL }) }
        heals, helps = Fight(CHAIN_HEAL, 2)
        ns.Teacher.Start(1)
        Feed(ns, heals, helps)
        ns.Teacher.Finish(30)
        ns.Teacher.Start(31) -- a quick re-pull: the read meets it and the meter answers secret
        S.sourceFail = "secret"
        FireAll(S)
        S.sourceFail = nil
        heals, helps = Fight(CHAIN_HEAL, 1)
        heals[1].at, heals[2].at, helps[1].at = 40, 40, 40
        ns.Teacher.Seen(53)
        Feed(ns, heals, helps)
        ns.Teacher.Finish(60)
        FireAll(S)
        Check("heals: a carried fight's heals and casts join the next fight's read", ns.Heals.IsLearned(CHAIN_HEAL)
            and T.Store().heals[CHAIN_HEAL].casts == 3)
    end

    -- Core wiring: once Chain Heal is learned (saved: 40000-42000, padded 28000-84000), a heal on you waits for its
    -- frame's end, and the frame's Chain Heal cast names the largest heal in its band. Draws record each
    -- Display.Player("heal") texture.
    local function CoreRig(learned)
        local rig = { draws = {} }
        rig.ns = T.Boot(function(S)
            S.harmful[CHAIN_HEAL] = false
            if learned ~= false then
                CombatTextIconsCharDB = { heals = {
                    [CHAIN_HEAL] = { casts = 3, hits = 3, expected = 0, sizes = { 40000, 41000, 42000 } } } }
            end
        end)
        rig.S = T.State()
        rig.ns.Teacher.area = "clear"
        rig.ns.Display.Player = function(kind, texture)
            if kind == "heal" then rig.draws[#rig.draws + 1] = texture or "none" end
        end
        function rig.Heal(t, amount, flag)
            rig.S.now = t
            rig.ns.Core.UNIT_COMBAT("player", "HEAL", flag or "", amount, 1)
        end
        function rig.Cast(t, spellID)
            rig.S.now = t
            rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c" .. t, spellID)
        end
        -- the game's next frame at `t`: the C_Timer.After(0) callbacks queued before it run (one queued now waits)
        function rig.Frame(t)
            rig.S.now = t
            local queued = rig.S.timers
            rig.S.timers = {}
            for _, timer in ipairs(queued) do timer.fn() end
        end
        return rig
    end

    do
        local rig = CoreRig()
        local UNKNOWN = rig.ns.Meter.UNKNOWN_ICON
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Heal(50, 45000)
        rig.Heal(50, 5000)
        rig.Cast(50, CHAIN_HEAL)
        Check("heals core: a heal on you waits for its frame's end once a heal is learned", #rig.draws == 0)
        rig.Frame(50)
        Check("heals core: a flush still on the heals' own stamp draws nothing and waits again",
            #rig.draws == 0 and #rig.S.timers == 1)
        rig.Frame(50.02)
        Check("heals core: the frame's Chain Heal names its largest heal in band; the proc beside it draws '?'",
            rig.draws[1] == "tex:1064" and rig.draws[2] == UNKNOWN and #rig.draws == 2)
        Check("heals core: the fight records the heals on you and the helpful cast for the teacher",
            #rig.ns.Teacher.fight.heals == 2 and rig.ns.Teacher.fight.helps[1].spellID == CHAIN_HEAL
            and #rig.ns.Teacher.fight.casts == 0)

        rig.draws = {}
        rig.Heal(60, 45000)
        rig.Heal(61, 200000)
        rig.Cast(61, CHAIN_HEAL)
        rig.Heal(61.5, 90000, "CRITICAL") -- 45000 at normal scale; 90000 itself is past the band
        rig.Cast(61.5, CHAIN_HEAL)
        rig.Frame(62)
        Check("heals core: a heal with no cast in its frame, or out of the band, draws '?'; a crit in band is named",
            rig.draws[1] == UNKNOWN and rig.draws[2] == UNKNOWN and rig.draws[3] == "tex:1064")

        rig.draws = {}
        rig.S.group = true
        rig.Heal(70, 45000)
        rig.Cast(70, CHAIN_HEAL)
        rig.Heal(71, 45000)
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        Check("heals core: in a group the cast's heal is named and a heal with no cast stays hidden; the fight's end "
            .. "flushes", rig.draws[1] == "tex:1064" and #rig.draws == 1)
    end

    do
        local rig = CoreRig(false)
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Heal(50, 45000)
        Check("heals core: with no heal learned a heal on you draws '?' in its own call, as before",
            rig.draws[1] == rig.ns.Meter.UNKNOWN_ICON and #rig.S.timers == 0)
    end
end
