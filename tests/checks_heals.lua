-- Unit checks for the learned direct heals and fixed sizes (Heals.lua): learning from a clear read's heals, helpful
-- casts and rows, the claim of a frame's heals, the saved store's checks. Called by tests/checks.lua with the same T
-- table. Every scenario boots its own rig; a Boot replaces the global stubs.

return function(T)
    local Check = T.Check
    local CHAIN_HEAL, RIPTIDE, PROC = 1064, 61295, 999001

    local function Row(spellID) return { spellID = spellID, total = 1, overkill = 0 } end
    -- The saved size entry of `spellID`, {} when none: a store with no sizes fails a check, not the whole file.
    local function SizeOf(spellID) return (T.Store().healSizes or {})[spellID] or {} end

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
        local heals, helps = Fight(CHAIN_HEAL, 2, function(k) return { 40000 + 1000 * k } end)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: two casts with heals of two sizes on their stamps teach nothing yet", not H.IsLearned(CHAIN_HEAL))
        heals, helps = Fight(CHAIN_HEAL, 1)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: a third cast in a later clear read learns the heal", H.IsLearned(CHAIN_HEAL) and H.AnyLearned())
        local entry = T.Store().heals[CHAIN_HEAL]
        Check("heals: the sample is the largest heal on the cast's stamp, not the proc beside it",
            entry.casts == 3 and entry.hits == 3 and #entry.sizes == 3 and entry.sizes[1] == 41000)

        -- hunter's Exhilaration heals a share of your health: 87925, then 87926
        local EXHILARATION = 109304
        heals, helps = Fight(EXHILARATION, 2, function(k) return { 87924 + k } end)
        H.Learn(heals, helps, { Row(EXHILARATION) }, 100)
        Check("heals: two casts whose samples are one size (within 0.5 %) learn the heal", H.IsLearned(EXHILARATION))
        heals, helps = Fight(RIPTIDE, 2, function(k) return { k == 1 and 87925 or 88500 } end) -- 0.65 % apart
        H.Learn(heals, helps, { Row(RIPTIDE) }, 100)
        Check("heals: two samples 0.65 % apart teach nothing yet", not H.IsLearned(RIPTIDE))
        H.Forget()

        heals, helps = Fight(RIPTIDE, 4)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: a cast that is no healing-done row learns nothing", not H.IsLearned(RIPTIDE))
        heals, helps = Fight(RIPTIDE, 1)
        H.Learn(heals, helps, { Row(RIPTIDE) }, 100)
        Check("heals: casts counted before their ID was a heal row learn once a later read lists it",
            H.IsLearned(RIPTIDE) and T.Store().heals[RIPTIDE].casts == 5)

        -- shamanheal: Healing Wave's 3rd and 4th fight casts only overheal (no row), its 6th fight lists it
        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(77472, 2)
        H.Learn(heals, helps, {}, 100)
        heals, helps = Fight(77472, 1)
        H.Learn(heals, helps, { Row(77472) }, 100)
        Check("heals: a fight with no heal row still counts its casts toward the heal", H.IsLearned(77472)
            and T.Store().heals[77472].casts == 3 and T.Store().heals[77472].pending == nil)

        -- the store is full (CAP 32): Chain Heal learned in read 1, 31 casts that never were a heal row in read 2
        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(CHAIN_HEAL, 3)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        helps = {}
        for k = 1, 32 do helps[k] = { spellID = PROC + k, at = 10 * k } end
        H.Learn({}, helps, {}, 400)
        Check("heals: a full store drops a cast with no heal row before a learned heal seen longer ago",
            H.IsLearned(CHAIN_HEAL) and T.Store().heals[PROC + 1] == nil and T.Store().heals[PROC + 32] ~= nil)

        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(RIPTIDE, 6, function(k) return k <= 3 and { 40000 } or {} end)
        for _, heal in ipairs(heals) do
            if heal.size == 5000 and heal.at > 30 then heal.at = heal.at + 1 end -- the last 3 stamps hold no heal
        end
        H.Learn(heals, helps, { Row(RIPTIDE) }, 100)
        Check("heals: 3 samples of 6 counted casts are below the hit share: not learned", not H.IsLearned(RIPTIDE))

        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(CHAIN_HEAL, 3)
        for k = 1, 3 do helps[#helps + 1] = { spellID = RIPTIDE, at = 10 * k } end
        H.Learn(heals, helps, { Row(CHAIN_HEAL), Row(RIPTIDE) }, 100)
        Check("heals: a stamp with two different helpful casts, neither with samples, counts for neither",
            T.Store().heals[CHAIN_HEAL] == nil and T.Store().heals[RIPTIDE] == nil)

        -- shamanheal: Chain Heal goes out on a healing totem's stamp (5394) in 13 of its 17 casts
        local TOTEM = 5394
        local rows = { Row(CHAIN_HEAL), Row(TOTEM) }
        -- a read of Fight(spellID, casts, heal) with a totem cast on each of its stamps
        local function TotemRead(H, spellID, casts, heal)
            local heals, helps = Fight(spellID, casts, heal)
            for k = 1, casts do helps[#helps + 1] = { spellID = TOTEM, at = 10 * k } end
            H.Learn(heals, helps, rows, 100)
        end
        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(CHAIN_HEAL, 1)
        H.Learn(heals, helps, rows, 100)
        TotemRead(H, CHAIN_HEAL, 2)
        local entry = T.Store().heals[CHAIN_HEAL]
        Check("heals: a stamp shared with a cast that has no samples counts for the one with samples",
            H.IsLearned(CHAIN_HEAL) and entry.casts == 3 and entry.hits == 3 and T.Store().heals[TOTEM] == nil)
        TotemRead(H, CHAIN_HEAL, 1, function() return { 200000 } end) -- past 2 x 40000
        Check("heals: a shared stamp whose largest heal is past the band counts a cast with no sample",
            entry.casts == 4 and entry.hits == 3 and #entry.sizes == 3)
        heals, helps = Fight(TOTEM, 1)
        H.Learn(heals, helps, rows, 100)
        TotemRead(H, CHAIN_HEAL, 1)
        Check("heals: a stamp shared by two casts that both have samples counts for neither",
            entry.casts == 4 and T.Store().heals[TOTEM].casts == 1)

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

    do -- fixed sizes: a row equal to the sum of the fight's heals of one size teaches that size
        local RUNE, ORDER = 1287908, 1260079
        local function Sized(spellID, total) return { spellID = spellID, total = total, overkill = 0 } end
        -- priest3 F9: Rune of Self-Mending heals 5763, 5763 and a 11526 crit (5763 at normal scale) beside a 40000
        local function RuneHeals()
            return { { size = 5763, amount = 5763, at = 10 }, { size = 5763.5, amount = 11527, at = 20 },
                { size = 5763, amount = 5763, at = 30 }, { size = 40000, amount = 40000, at = 40 } }
        end
        local ns = T.Boot()
        local H = ns.Heals
        H.Learn(RuneHeals(), {}, { Sized(RUNE, 23053), Sized(CHAIN_HEAL, 39000) }, 100)
        Check("sizes: one read whose row is one size's sum teaches nothing yet",
            not H.AnyLearned() and SizeOf(RUNE).reads == 1 and SizeOf(CHAIN_HEAL).size == nil)
        H.Learn(RuneHeals(), {}, { Sized(RUNE, 23054) }, 100)
        Check("sizes: a second read of that size learns it", H.AnyLearned() and SizeOf(RUNE).reads == 2)
        local claims = H.Claim({}, { { size = 5763 }, { size = 5764 }, { size = 5766 }, { size = nil } })
        Check("sizes: a heal of the learned size is its row's with no cast; another size or none is not",
            claims[1] == RUNE and claims[2] == RUNE and claims[3] == nil and claims[4] == nil)

        H.Learn(RuneHeals(), {}, { Sized(ORDER, 23053), Sized(RUNE, 23053) }, 100)
        Check("sizes: two rows equal to one size's sum sample neither", SizeOf(ORDER).size == nil
            and SizeOf(RUNE).reads == 2)
        H.Learn(RuneHeals(), {}, { Sized(RUNE, 20000) }, 100)
        Check("sizes: a row that is no size's sum (it overhealed) samples nothing",
            SizeOf(RUNE).reads == 2)

        -- 1263002 and Rune of Self-Mending both 11527 in one store
        H.Learn({ { size = 11527, amount = 11527, at = 10 } }, {}, { Sized(1263002, 11527) }, 100)
        H.Learn({ { size = 11527, amount = 11527, at = 10 } }, {}, { Sized(1263002, 11527) }, 100)
        Check("sizes: a second row learns its own size", H.Claim({}, { { size = 11527 } })[1] == 1263002)
        for _ = 1, 2 do
            H.Learn({ { size = 11526, amount = 11526, at = 10 } }, {}, { Sized(ORDER, 11526) }, 100)
        end
        Check("sizes: a size two learned rows share names neither", next(H.Claim({}, { { size = 11527 } })) == nil)
        H.Learn({ { size = 6046, amount = 6046, at = 10 } }, {}, { Sized(ORDER, 6046) }, 100)
        Check("sizes: a read of another size starts the row over, unlearned",
            SizeOf(ORDER).reads == 1 and SizeOf(ORDER).size == 6046
            and H.Claim({}, { { size = 11527 } })[1] == 1263002)

        -- a learned size claims before a cast, and is no cast's sample: paladin's Word of Glory stamps hold a proc
        ns = T.Boot()
        H = ns.Heals
        for _ = 1, 2 do H.Learn({ { size = 50000, amount = 50000, at = 5 } }, {}, { Sized(ORDER, 50000) }, 100) end
        local heals, helps = Fight(CHAIN_HEAL, 3)
        for k = 1, 3 do heals[#heals + 1] = { size = 50000, amount = 50000, at = 10 * k } end
        H.Learn(heals, helps, { Sized(CHAIN_HEAL, 1) }, 100)
        Check("sizes: a cast's sample is the largest heal on its stamp that no learned size names",
            T.Store().heals[CHAIN_HEAL].sizes[1] == 40000 and H.IsLearned(CHAIN_HEAL))
        claims = H.Claim({ CHAIN_HEAL }, { { size = 50000 }, { size = 40000 } })
        Check("sizes: a heal of a learned size goes to its row; the cast takes the next in its band",
            claims[1] == ORDER and claims[2] == CHAIN_HEAL)
        H.Forget()
        Check("sizes: /cti forget drops the learned sizes", not H.AnyLearned() and next(T.Store().healSizes or {}) == nil)

        -- the saved sizes are checked, never trusted
        ns = T.Boot(function()
            CombatTextIconsCharDB = { healSizes = { [RUNE] = { size = 5763, reads = 2 }, [ORDER] = { size = -1, reads = 2 },
                [CHAIN_HEAL] = { size = 40000, reads = 0.5 }, [0.5] = { size = 5763, reads = 2 }, [5394] = "junk" } }
        end)
        local saved = T.Store().healSizes or {}
        Check("sizes: a valid saved size loads learned", ns.Heals.Claim({}, { { size = 5763 } })[1] == RUNE)
        Check("sizes: saved sizes with a bad size, read count or ID, or junk, are dropped",
            saved[ORDER] == nil and saved[CHAIN_HEAL] == nil and saved[0.5] == nil and saved[5394] == nil)
    end

    do -- coupled heals: a drawn hit's ID that is a heal row and heals you one share k of the hit on its stamp
        local DRAIN, PLAGUE, OTHER = 234153, 335467, 1287908
        local function Rows(...)
            local rows = {}
            for index, id in ipairs({ ... }) do rows[index] = Row(id) end
            return rows
        end
        local function CoupleOf(spellID) return (T.Store().healCouples or {})[spellID] or {} end
        -- lock3: Drain Life ticks of `ticks` sizes, each healing you 7 x the tick on its stamp (a crit tick heals
        -- twice), beside a 5000 heal on every stamp; `share` overrides 7. Returns heals, drawn.
        local function DrainRead(ticks, share)
            local heals, drawn = {}, {}
            for k, tick in ipairs(ticks) do
                local at = 10 * k
                drawn[#drawn + 1] = { spellID = DRAIN, amount = tick, at = at }
                heals[#heals + 1] = { size = 5000, amount = 5000, at = at }
                heals[#heals + 1] = { size = (share or 7) * tick, amount = (share or 7) * tick, at = at }
            end
            return heals, drawn
        end
        local ns = T.Boot()
        local H = ns.Heals
        local heals, drawn = DrainRead({ 1413, 2827, 1414 })
        H.Learn(heals, {}, Rows(DRAIN), 100, drawn)
        Check("couples: one read of three heals at 7 x their hits teaches nothing yet",
            CoupleOf(DRAIN).reads == 1 and not H.AnyLearned())
        heals, drawn = DrainRead({ 1281, 2562, 1281 })
        H.Learn(heals, {}, Rows(DRAIN, OTHER), 100, drawn)
        local entry = CoupleOf(DRAIN)
        Check("couples: a second read of the same k learns it, its span inside both reads' shares",
            entry.reads == 2 and H.AnyLearned() and entry.lo <= 7 and entry.hi >= 7 and entry.hi - entry.lo < 0.001)
        local hits = { { spellID = DRAIN, amount = 1413 } }
        local claims = H.Claim({}, { { size = 9891, amount = 9891 }, { size = 9900, amount = 9900 },
            { size = 5000, amount = 5000 } }, hits)
        Check("couples: a heal of k x a frame's drawn hit is that hit's; another amount is not",
            claims[1] == DRAIN and claims[2] == nil and claims[3] == nil)
        Check("couples: a frame with no drawn hit of the ID claims nothing",
            next(H.Claim({}, { { size = 9891, amount = 9891 } }, { { spellID = OTHER, amount = 1413 } })) == nil
            and next(H.Claim({}, { { size = 9891, amount = 9891 } })) == nil)

        -- Devouring Plague's 0.3: its hit of 33320 and Drain Life's tick of 1428 both make a 9996 heal
        for _ = 1, 2 do
            heals, drawn = DrainRead({ 33310, 7490, 6670 }, 0.3)
            for _, hit in ipairs(drawn) do hit.spellID = PLAGUE end
            H.Learn(heals, {}, Rows(PLAGUE), 100, drawn)
        end
        claims = H.Claim({}, { { size = 9996, amount = 9996 }, { size = 9891, amount = 9891 } },
            { { spellID = PLAGUE, amount = 33320 }, { spellID = DRAIN, amount = 1428 }, { spellID = DRAIN, amount = 1413 } })
        Check("couples: a heal two learned IDs' k both fit is neither's; one only Drain Life's k fits is its",
            claims[1] == nil and claims[2] == DRAIN)
        for _ = 1, 2 do H.Learn({ { size = 9891, amount = 9891, at = 5 } }, {}, { { spellID = OTHER, total = 9891,
            overkill = 0 } }, 100) end
        Check("couples: a learned size claims before a couple", H.Claim({}, { { size = 9891, amount = 9891 } },
            { { spellID = DRAIN, amount = 1413 } })[1] == OTHER)

        heals, drawn = DrainRead({ 1413, 1500, 1600 }, 5)
        H.Learn(heals, {}, Rows(DRAIN), 100, drawn)
        Check("couples: a read of another k starts the ID over, unlearned",
            CoupleOf(DRAIN).reads == 1 and CoupleOf(DRAIN).lo > 4.99)
        H.Forget()
        Check("couples: /cti forget drops the couples", next(T.Store().healCouples or {}) == nil and not H.AnyLearned())

        heals, drawn = DrainRead({ 1413, 2827, 1414 })
        H.Learn(heals, {}, Rows(OTHER), 100, drawn)
        Check("couples: a hit ID that is no heal row of the read samples nothing", CoupleOf(DRAIN).reads == nil)
        heals, drawn = DrainRead({ 1413, 2827 })
        H.Learn(heals, {}, Rows(DRAIN), 100, drawn)
        Check("couples: two heals at one k sample nothing", CoupleOf(DRAIN).reads == nil)
        heals, drawn = DrainRead({ 1413, 2827, 1414 })
        heals[4].amount = 9000 -- the 2nd stamp's heal is no 7 x 2827
        H.Learn(heals, {}, Rows(DRAIN), 100, drawn)
        Check("couples: a heal off its share leaves two of one k: nothing", CoupleOf(DRAIN).reads == nil)

        -- the saved couples are checked, never trusted
        ns = T.Boot(function()
            CombatTextIconsCharDB = { healCouples = { [DRAIN] = { lo = 6.9999, hi = 7.0001, reads = 2 },
                [PLAGUE] = { lo = 0.31, hi = 0.29, reads = 2 }, [OTHER] = { lo = 0, hi = 1, reads = 2 },
                [5394] = { lo = 1, hi = 1, reads = 0 }, [0.5] = { lo = 1, hi = 1, reads = 2 }, [1064] = "junk" } }
        end)
        local saved = T.Store().healCouples or {}
        Check("couples: a valid saved couple loads learned", ns.Heals.Claim({}, { { size = 9891, amount = 9891 } },
            { { spellID = DRAIN, amount = 1413 } })[1] == DRAIN)
        Check("couples: saved couples with a bad span, read count or ID, or junk, are dropped", saved[PLAGUE] == nil
            and saved[OTHER] == nil and saved[5394] == nil and saved[0.5] == nil and saved[1064] == nil)
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
                [108280] = { casts = 3, hits = 3, expected = 0, sizes = { 40000, 41000, 42000 }, pending = true },
            } }
        end)
        local saved = T.Store().heals
        Check("heals: a valid saved heal loads learned", ns.Heals.IsLearned(CHAIN_HEAL))
        Check("heals: saved entries with more hits than casts, a negative expected count, junk or a bad ID are dropped",
            saved[RIPTIDE] == nil and saved[PROC] == nil and saved[5394] == nil and saved[0.5] == nil)
        Check("heals: a saved entry keeps only its positive finite sizes",
            saved[77472] and #saved[77472].sizes == 3 and ns.Heals.IsLearned(77472))
        Check("heals: a saved cast whose ID never was a heal row loads still waiting for one",
            saved[108280] and saved[108280].pending == true and not ns.Heals.IsLearned(108280))
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

        -- two clear reads whose Rune of Self-Mending row is its heals' amounts summed: 5763 + a 11527 crit
        ns = T.Boot()
        ns.Teacher.area = "clear"
        S = T.State()
        for _ = 1, 2 do
            local session = Session({})
            session.healRows = { { spellID = 1287908, totalAmount = 17290, overkillAmount = 0 } }
            S.sessions = { session }
            ns.Teacher.Start(1)
            ns.Teacher.Seen(53)
            ns.Teacher.Healed(5763, "", 10)
            ns.Teacher.Healed(11527, "CRITICAL", 20)
            ns.Teacher.Finish(100)
            FireAll(S)
        end
        Check("heals: the fight's heal amounts reach the teacher, and a row of one size's sum learns it",
            SizeOf(1287908).reads == 2 and ns.Heals.AnyLearned())

        -- two clear reads of Drain Life ticks drawn with its icon, each healing you 7 x the tick on its stamp, and one
        -- tick drawn with no stamp (it tallies, it pairs with nothing)
        ns = T.Boot()
        ns.Teacher.area = "clear"
        S = T.State()
        for _ = 1, 2 do
            local session = Session({})
            session.healRows = { { spellID = 234153, totalAmount = 1, overkillAmount = 0 } }
            S.sessions = { session }
            ns.Teacher.Start(1)
            ns.Teacher.Seen(53)
            for k, tick in ipairs({ 1413, 2827, 1414 }) do
                ns.Teacher.Drawn(234153, tick, 10 * k)
                ns.Teacher.Healed(7 * tick, "", 10 * k)
            end
            ns.Teacher.Drawn(234153, 1413)
            ns.Teacher.Finish(100)
            FireAll(S)
        end
        local couple = (T.Store().healCouples or {})[234153] or {}
        Check("heals: the fight's drawn hits reach the teacher, and two reads of one k learn the couple",
            couple.reads == 2 and ns.Heals.AnyLearned())
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
