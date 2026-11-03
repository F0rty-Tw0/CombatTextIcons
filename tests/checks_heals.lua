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

    do -- the sample that teaches a cast names its heal before the read: hunter F9's Exhilaration twins F7's 87926
        local EXHILARATION, TOTEM = 109304, 5394
        local ns = T.Boot()
        local H = ns.Heals
        local heals, helps = Fight(EXHILARATION, 1, function() return { 87926 } end)
        H.Learn(heals, helps, { Row(EXHILARATION) }, 100)
        local frame = { { size = 5000 }, { size = 87925 } }
        local claims = H.Claim({ EXHILARATION }, frame, nil, nil, true)
        Check("heals: a solo cast's heal that twins its one sample names it before the read",
            not H.IsLearned(EXHILARATION) and H.AnyLearned() and claims[2] == EXHILARATION and claims[1] == nil)
        Check("heals: in a group or a crowd the teaching sample names nothing",
            next(H.Claim({ EXHILARATION }, frame, nil, nil, false)) == nil
            and next(H.Claim({ EXHILARATION }, frame)) == nil)
        Check("heals: a heal 0.65 % off the one sample teaches nothing, so it names nothing",
            next(H.Claim({ EXHILARATION }, { { size = 88500 } }, nil, nil, true)) == nil)
        Check("heals: the teaching sample is the frame's one cast with samples; beside a cast with none it still is",
            H.Claim({ TOTEM, EXHILARATION }, frame, nil, nil, true)[2] == EXHILARATION)
        heals, helps = Fight(TOTEM, 1)
        H.Learn(heals, helps, { Row(TOTEM) }, 100)
        Check("heals: beside another cast with samples the teaching sample names nothing",
            next(H.Claim({ TOTEM, EXHILARATION }, frame, nil, nil, true)) == nil)

        -- shamanheal F4: Chain Heal's 3rd sample, 2 from F3 (59910, 61971 at normal scale)
        ns = T.Boot()
        H = ns.Heals
        heals, helps = Fight(CHAIN_HEAL, 2, function(k) return { k == 1 and 59910 or 61971 } end)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("heals: the third sample inside the band names the cast; one below 0.7 x the smallest does not",
            H.Claim({ CHAIN_HEAL }, { { size = 42138 } }, nil, nil, true)[1] == CHAIN_HEAL
            and next(H.Claim({ CHAIN_HEAL }, { { size = 41895 } }, nil, nil, true)) == nil)
        heals, helps = Fight(RIPTIDE, 2)
        H.Learn(heals, helps, {}, 100)
        Check("heals: a cast whose ID was never a heal row names nothing",
            next(H.Claim({ RIPTIDE }, { { size = 40000 } }, nil, nil, true)) == nil)
    end

    do -- fixed sizes: a row equal to the sum of the fight's heals of one size teaches that size
        local RUNE, ORDER = 1287908, 1260079
        local function Sized(spellID, total) return { spellID = spellID, total = total, overkill = 0 } end
        -- Rune of Self-Mending heals once, 5763, beside a 40000
        local function RuneHeals()
            return { { size = 5763, amount = 5763, at = 10 }, { size = 40000, amount = 40000, at = 40 } }
        end
        local ns = T.Boot()
        local H = ns.Heals
        H.Learn(RuneHeals(), {}, { Sized(RUNE, 5763), Sized(CHAIN_HEAL, 39000) }, 100)
        Check("sizes: one read whose row is one heal's size teaches nothing yet",
            not H.AnyLearned() and SizeOf(RUNE).reads == 1 and SizeOf(CHAIN_HEAL).size == nil)
        H.Learn(RuneHeals(), {}, { Sized(RUNE, 5764) }, 100)
        Check("sizes: a second read of that size learns it", H.AnyLearned() and SizeOf(RUNE).reads == 2)
        local claims = H.Claim({}, { { size = 5763 }, { size = 5764 }, { size = 5766 }, { size = nil } })
        Check("sizes: a heal of the learned size is its row's with no cast; another size or none is not",
            claims[1] == RUNE and claims[2] == RUNE and claims[3] == nil and claims[4] == nil)

        H.Learn(RuneHeals(), {}, { Sized(ORDER, 5763), Sized(RUNE, 5763) }, 100)
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

        -- paladin F3: the rune row 1287665 sums 16 heals of 720; one read teaches it
        H.Forget()
        local many = {}
        for k = 1, 16 do many[k] = { size = 720, amount = 720, at = k } end
        H.Learn(many, {}, { Sized(1287665, 11520) }, 100)
        Check("sizes: one read whose row sums SURE_RUN heals of one size teaches it alone",
            SizeOf(1287665).reads == 2 and H.Claim({}, { { size = 720 } })[1] == 1287665)
        -- druid2 F8: the Holy Retributor's Order row 57728 sums two heals of 28864; priest3 F8: the rune row 23053 sums
        -- 5763, 5763 and a 11527 crit (5763.5 at normal scale)
        H.Learn({ { size = 28864, amount = 28864, at = 10 }, { size = 28864, amount = 28864, at = 20 },
            { size = 40000, amount = 40000, at = 30 } }, {}, { Sized(ORDER, 57728) }, 100)
        Check("sizes: one read whose row sums two heals of one size teaches it alone",
            SizeOf(ORDER).reads == 2 and H.Claim({}, { { size = 28864 } })[1] == ORDER)
        H.Learn({ { size = 5763, amount = 5763, at = 10 }, { size = 5763.5, amount = 11527, at = 20 },
            { size = 5763, amount = 5763, at = 30 } }, {}, { Sized(RUNE, 23053) }, 100)
        Check("sizes: one read whose row sums three heals of one size, a crit at normal scale, teaches it alone",
            SizeOf(RUNE).reads == 2 and H.Claim({}, { { size = 5763 } })[1] == RUNE)

        -- shamanheal: the 1263002 row reads 11527 over 2 heals of 11527 (F1), 11526 over 3 (F5), 23053 over 5 (F6)
        H.Forget()
        local function Procs(count, size)
            local heals = { { size = 40000, amount = 40000, at = 50 } }
            for k = 1, count do heals[#heals + 1] = { size = size, amount = size, at = k } end
            return heals
        end
        H.Learn(Procs(2, 11527), {}, { Sized(1263002, 11527) }, 100)
        Check("sizes: a row that is one of a run's heals (the rest overhealed) samples its size, one read",
            SizeOf(1263002).reads == 1 and SizeOf(1263002).size == 11527 and not H.AnyLearned())
        H.Learn(Procs(3, 11526), {}, { Sized(1263002, 11526) }, 100)
        Check("sizes: a second read of a part learns the size",
            SizeOf(1263002).reads == 2 and H.Claim({}, { { size = 11527 } })[1] == 1263002)
        H.Learn(Procs(5, 11527), {}, { Sized(ORDER, 23053), Sized(RUNE, 23053) }, 100)
        Check("sizes: two rows that are a part of one run sample neither",
            SizeOf(ORDER).size == nil and SizeOf(RUNE).size == nil)
        H.Learn(Procs(3, 11527), {}, { Sized(ORDER, 34581), Sized(RUNE, 23054) }, 100)
        Check("sizes: a part of a run another row sums samples nothing", SizeOf(ORDER).size == 11527
            and SizeOf(RUNE).size == nil)
        H.Learn(Procs(3, 11527), {}, { Sized(RUNE, 17290) }, 100)
        Check("sizes: a row between two parts of a run samples nothing", SizeOf(RUNE).size == nil)
        H.Learn(Procs(16, 720), {}, { Sized(1287665, 4322) }, 100)
        Check("sizes: a part of a run of a small size, near some part by luck, samples nothing",
            SizeOf(1287665).size == nil)

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

        -- priest3: Devouring Plague's 0.3 learned from its drawn shadow hits names a heal 0.3 x a shadow hit no icon
        -- drew; a hit of another school, or drawn under another ID, is none of its
        local function ShadowRead(school)
            heals, drawn = DrainRead({ 33310, 7490, 6670 }, 0.3)
            for index, hit in ipairs(drawn) do
                hit.spellID, hit.school = PLAGUE, school and school(index) or 32
            end
            H.Learn(heals, {}, Rows(PLAGUE), 100, drawn)
        end
        H.Forget()
        ShadowRead()
        ShadowRead()
        local heal = { { size = 9996, amount = 9996 } }
        Check("couples: a learned couple keeps its hits' school", CoupleOf(PLAGUE).school == 32)
        Check("couples: a heal of k x an undrawn hit of the couple's school is the couple's",
            H.Claim({}, heal, { { amount = 33320, school = 32 } })[1] == PLAGUE)
        Check("couples: an undrawn hit of another school, or one drawn under another ID, claims nothing",
            next(H.Claim({}, heal, { { amount = 33320, school = 4 } })) == nil
            and next(H.Claim({}, heal, { { amount = 33320, school = 32, spellID = OTHER } })) == nil)
        H.Forget()
        ShadowRead()
        ShadowRead(function(index) return index == 1 and 4 or 32 end)
        Check("couples: a couple whose reads' hits mixed schools names only drawn hits", CoupleOf(PLAGUE).reads == 2
            and CoupleOf(PLAGUE).school == nil and next(H.Claim({}, heal, { { amount = 33320, school = 32 } })) == nil
            and H.Claim({}, heal, { { amount = 33320, school = 32, spellID = PLAGUE } })[1] == PLAGUE)

        -- priest3 F4: Devouring Plague's ticks draw nothing, and their 0.3 heals back the k its 3 drawn hits share, so
        -- one read teaches it; ticks of another school, or heals off the k, back nothing
        local function BackedRead(share, school)
            heals, drawn = DrainRead({ 33310, 7490, 6670 }, 0.3)
            for _, hit in ipairs(drawn) do hit.spellID, hit.school = PLAGUE, 32 end
            local ticks = {}
            for k, tick in ipairs({ 2391, 2400, 4782, 2410, 2388, 2395 }) do
                local at = 100 + k
                ticks[k] = { amount = tick, at = at, school = school }
                heals[#heals + 1] = { size = 5000, amount = 5000, at = at }
                heals[#heals + 1] = { size = share * tick, amount = math.floor(share * tick + 0.5), at = at }
            end
            H.Learn(heals, {}, Rows(PLAGUE), 100, drawn, { hits = ticks })
        end
        H.Forget()
        BackedRead(0.3, 32)
        Check("couples: a read whose undrawn hits of its school back its k beyond luck teaches it alone",
            CoupleOf(PLAGUE).reads == 2 and H.Claim({}, heal, { { amount = 33320, school = 32 } })[1] == PLAGUE)
        H.Forget()
        BackedRead(0.3, 4)
        Check("couples: undrawn hits of another school back nothing", CoupleOf(PLAGUE).reads == 1 and not H.AnyLearned())
        H.Forget()
        BackedRead(0.25, 32)
        Check("couples: undrawn hits whose heals are off the k back nothing",
            CoupleOf(PLAGUE).reads == 1 and not H.AnyLearned())

        -- the saved couples are checked, never trusted
        ns = T.Boot(function()
            CombatTextIconsCharDB = { healCouples = { [DRAIN] = { lo = 6.9999, hi = 7.0001, reads = 2, school = 0.5 },
                [77472] = { lo = 0.2999, hi = 0.3001, reads = 2, school = 32 },
                [PLAGUE] = { lo = 0.31, hi = 0.29, reads = 2 }, [OTHER] = { lo = 0, hi = 1, reads = 2 },
                [5394] = { lo = 1, hi = 1, reads = 0 }, [0.5] = { lo = 1, hi = 1, reads = 2 }, [1064] = "junk" } }
        end)
        local saved = T.Store().healCouples or {}
        Check("couples: a valid saved couple loads learned", ns.Heals.Claim({}, { { size = 9891, amount = 9891 } },
            { { spellID = DRAIN, amount = 1413 } })[1] == DRAIN)
        Check("couples: a saved school loads; a bad one is dropped alone", saved[77472].school == 32
            and saved[DRAIN] ~= nil and saved[DRAIN].school == nil)
        Check("couples: saved couples with a bad span, read count or ID, or junk, are dropped", saved[PLAGUE] == nil
            and saved[OTHER] == nil and saved[5394] == nil and saved[0.5] == nil and saved[1064] == nil)
    end

    -- Trains: a read of one cast of each of `casts` (IDs on one stamp) at t = 10 and its train's `ticks` ticks (8)
    -- every 1.5 s from the cast, sized 12000 - 300 x tick (`size(tick)` when given). opts: `rows` (default: each
    -- cast's), `before` (the train also ticked 1.5 s before the cast), `direct` (a heal of that size on the cast's
    -- stamp), `filler` (a heal of 11000 every 0.5 s all fight long), `sparse` (a heal of 11000 every 3 s all fight
    -- long, each between two ticks: luck gives a 5 tick walk ~4e-4 often), `damage` (Heals.Learn's damage side).
    local TIDE, TOTEM = 108280, 5394
    local function TrainRead(H, casts, opts)
        opts = opts or {}
        local heals, helps, rows = {}, {}, opts.rows
        if not rows then
            rows = {}
            for index, spellID in ipairs(casts) do rows[index] = Row(spellID) end
        end
        for _, spellID in ipairs(casts) do helps[#helps + 1] = { spellID = spellID, at = 10 } end
        if opts.direct then heals[#heals + 1] = { size = opts.direct, amount = opts.direct, at = 10 } end
        if opts.before then heals[#heals + 1] = { size = 12300, amount = 12300, at = 8.5 } end
        for tick = 1, opts.ticks or 8 do
            local size = opts.size and opts.size(tick) or 12000 - 300 * tick
            heals[#heals + 1] = { size = size, amount = size, at = 10 + 1.5 * tick }
        end
        if opts.filler or opts.sparse then
            local from, step = opts.filler and 0.25 or 0.75, opts.filler and 0.5 or 3
            for t = from, 100, step do heals[#heals + 1] = { size = 11000, amount = 11000, at = t } end
            table.sort(heals, function(a, b) return a.at < b.at end)
        end
        H.Learn(heals, helps, rows, 100, opts.drawn, opts.damage, opts.ended)
    end

    do -- trains: learning
        local ns = T.Boot()
        local H = ns.Heals
        TrainRead(H, { TIDE }, { ticks = 5, sparse = true })
        Check("trains: one cast's walk that luck gives over 1e-4 often teaches nothing yet",
            not H.IsTrainLearned(TIDE) and not H.AnyLearned())
        TrainRead(H, { TIDE }, { ticks = 5, sparse = true })
        Check("trains: a second cast whose ticks walk the same train teaches it", H.IsTrainLearned(TIDE)
            and H.AnyLearned() and #T.Store().healTrains[TIDE].walks == 2)

        -- shamanheal: Healing Tide's first walk (5 ticks every 1.76 s) luck 2.1e-05, its log 3 casts long
        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { TIDE })
        Check("trains: one walk luck gives 1e-4 often at most teaches alone", H.IsTrainLearned(TIDE)
            and #T.Store().healTrains[TIDE].walks == 1 and T.Store().healTrains[TIDE].walks[1].luck < 1e-4)

        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { TIDE }, { rows = {} })
        TrainRead(H, { TIDE }, { rows = {} })
        Check("trains: a cast that is no healing-done row learns no train", not H.IsTrainLearned(TIDE))
        TrainRead(H, { TIDE }, { ticks = 4 })
        Check("trains: walks counted before the cast's ID was a heal row teach once a read lists it; a walk under 5 "
            .. "ticks is none", H.IsTrainLearned(TIDE) and T.Store().healTrains[TIDE].row == TIDE
            and T.Store().healTrains[TIDE].walks[3].period == nil)
        -- shamanheal F3: Stormstream healed you twice, then stopped; its F2 walk was sure, and F4's ticks drew '?'
        TrainRead(H, { TIDE }, { ticks = 4 })
        Check("trains: casts that walked no train (ticks cut short) are no count against it",
            H.IsTrainLearned(TIDE) and #T.Store().healTrains[TIDE].walks == 4)
        local function Big(tick) return 30000 - 300 * tick end
        TrainRead(H, { TIDE }, { size = Big })
        TrainRead(H, { TIDE }, { size = Big })
        Check("trains: 2 agreeing walks of 4 walked casts are below the train share", not H.IsTrainLearned(TIDE))

        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { TIDE }, { before = true })
        TrainRead(H, { TIDE }, { before = true })
        Check("trains: ticks that ran a period before the cast are no train of it", not H.IsTrainLearned(TIDE))

        -- paladin: Word of Glory starts a 720 rune train under the rune's ID (1287665)
        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { 85673 }, { size = function(tick) return tick % 2 == 0 and 721 or 720 end })
        TrainRead(H, { 85673 }, { size = function(tick) return tick % 2 == 0 and 721 or 720 end })
        Check("trains: ticks all of one size (a castless proc's) are no cast's train", not H.IsTrainLearned(85673))

        -- hunter: Exhilaration heals 87925 on its stamp, then 4396 (1/20 of it) each tick under its own row
        local EXHILARATION = 109304
        local function Tail(tick) return tick % 2 == 0 and 4397 or 4396 end
        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { EXHILARATION }, { direct = 87925, ticks = 6, size = Tail })
        Check("tails: one walk of one size after a direct heal teaches nothing yet",
            not H.IsTrainLearned(EXHILARATION) and T.Store().healTrains[EXHILARATION].walks[1].share ~= nil)
        TrainRead(H, { EXHILARATION }, { direct = 87925, ticks = 6, size = Tail })
        H.Cast(EXHILARATION, 100)
        local head = H.Claim({ EXHILARATION }, { { size = 87925 } }, nil, 100)
        Check("tails: two walks of one size at one share of the direct heal teach its tail under its row",
            H.IsTrainLearned(EXHILARATION) and head[1] == EXHILARATION
            and H.Claim({}, { { size = 4396 } }, nil, 101.5)[1] == EXHILARATION
            and H.Claim({}, { { size = 4397 } }, nil, 103)[1] == EXHILARATION)

        -- a rune of 720 ticking after a direct heal that heals 60000, then 80000: no one share
        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { 85673 }, { direct = 60000, size = function(tick) return tick % 2 == 0 and 721 or 720 end })
        TrainRead(H, { 85673 }, { direct = 80000, size = function(tick) return tick % 2 == 0 and 721 or 720 end })
        Check("tails: one-size walks after a direct heal at shares that differ are no tail", not H.IsTrainLearned(85673))

        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { TIDE }, { filler = true })
        TrainRead(H, { TIDE }, { filler = true })
        Check("trains: a walk luck explains (heals of its size every 0.5 s) is no train", not H.IsTrainLearned(TIDE))

        ns = T.Boot()
        H = ns.Heals
        -- shamanheal: Riptide heals on its stamp, then its HoT ticks 3.6-5.5K every ~2.6 s, the size drifting
        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { RIPTIDE }, { direct = 60000 })
        Check("trains: one walk of ticks that vary after a direct heal teaches nothing yet",
            not H.IsTrainLearned(RIPTIDE) and T.Store().heals[RIPTIDE].hits == 1)
        TrainRead(H, { RIPTIDE }, { direct = 60000 })
        H.Cast(RIPTIDE, 100)
        Check("trains: two walks of ticks that vary after a direct heal teach them as its HoT under its row",
            H.IsTrainLearned(RIPTIDE) and T.Store().heals[RIPTIDE].hits == 2
            and H.Claim({}, { { size = 11700 } }, nil, 101.5)[1] == RIPTIDE)

        -- shamanheal: each totem goes out on a Chain Heal's stamp; Chain Heal also goes out alone
        ns = T.Boot()
        H = ns.Heals
        TrainRead(H, { TOTEM, CHAIN_HEAL })
        TrainRead(H, { TOTEM, CHAIN_HEAL })
        Check("trains: walks on a stamp shared with a cast that has no samples count for neither",
            not H.IsTrainLearned(TOTEM) and not H.IsTrainLearned(CHAIN_HEAL))
        local heals, helps = Fight(CHAIN_HEAL, 1)
        H.Learn(heals, helps, { Row(CHAIN_HEAL) }, 100)
        Check("trains: once the stamps' other cast has samples (a direct heal), the walks count for the totem",
            H.IsTrainLearned(TOTEM) and not H.IsTrainLearned(CHAIN_HEAL))

        -- shamanheal: Stormstream Totem casts as 1267068 (base 5394); its ticks draw under 5394, a heal row
        ns = T.Boot(function(S) S.baseSpells[1267068] = TOTEM end)
        H = ns.Heals
        TrainRead(H, { 1267068 }, { rows = { Row(TOTEM) } })
        TrainRead(H, { 1267068 }, { rows = { Row(TOTEM) } })
        H.Cast(1267068, 100)
        Check("trains: a cast that is no heal row trains under its base's row",
            H.IsTrainLearned(1267068) and H.Claim({}, { { size = 11700 } }, nil, 101.5)[1] == TOTEM)
        H.Forget()
        Check("trains: /cti forget drops the trains", not H.IsTrainLearned(1267068)
            and next(T.Store().healTrains or {}) == nil and not H.AnyLearned())
    end

    do -- trains: shamanheal's Healing Rain casts as 444995 (base 73920) and 1298679 on one stamp, neither a heal row;
        -- its heal and damage row is 73921, and its ticks share their frames with its hits on the mobs
        local RAIN, TWIN, ROW, OTHER = 444995, 1298679, 73921, 999002
        local function Boot() return T.Boot(function(S) S.baseSpells[RAIN] = 73920 end).Heals end
        local function Damage(opts)
            local hits = {}
            for tick = 1, 8 do hits[tick] = { at = 10 + 1.5 * tick + (opts.off or 0) } end
            return { rows = opts.rows or { Row(ROW) }, cast = opts.cast or {}, hits = hits }
        end
        local function Read(H, damage)
            TrainRead(H, { RAIN, TWIN }, { rows = { Row(ROW), Row(OTHER) }, sparse = true, damage = damage })
        end

        local H = Boot()
        Read(H, Damage({}))
        H.Cast(RAIN, 100)
        H.Cast(TWIN, 100)
        local frame = H.Claim({}, { { size = 11700 }, { size = 11600 } }, nil, 101.5)
        Check("trains: twin casts with no heal row learn one train under the heal and damage row their ticks hit with",
            H.IsTrainLearned(RAIN) and not H.IsTrainLearned(TWIN) and frame[1] == nil and frame[2] == ROW)
        TrainRead(H, { RAIN, TWIN }, { rows = { Row(RAIN) }, sparse = true })
        Check("trains: a read that lists a cast's own ID as a heal row moves its train there",
            T.Store().healTrains[RAIN].row == RAIN)

        H = Boot()
        Read(H, Damage({ off = 0.5 }))
        Check("trains: hits off the ticks' frames give no row", not H.IsTrainLearned(RAIN) and not H.IsTrainLearned(TWIN))
        H = Boot()
        Read(H, Damage({ cast = { [ROW] = true } }))
        Check("trains: a heal and damage row that is a cast's own is no row of another cast", not H.IsTrainLearned(RAIN))
        H = Boot()
        Read(H, Damage({ rows = { Row(ROW), Row(OTHER) } }))
        Check("trains: two rows that heal and damage name neither", not H.IsTrainLearned(RAIN))

        -- shamanresto: 73921 is no heal row (its ticks overheal), and each read holds more castless damage rows
        -- (F1: 1307222, 1310088); the hits drawn or learned under 73921 share the ticks' frames
        local PROC, PROC2 = 1307222, 1310088
        local function Under(spellID, off, ticks)
            local hits = {}
            for tick = 1, ticks or 8 do hits[tick] = { spellID = spellID, at = 10 + 1.5 * tick + (off or 0) } end
            return hits
        end
        local function Mixed(named)
            local damage = Damage({ rows = { Row(PROC), Row(ROW), Row(PROC2) } })
            damage.named = named
            return damage
        end
        local function Learns(opts)
            local learner = Boot()
            TrainRead(learner, { RAIN, TWIN }, { rows = { Row(OTHER) }, sparse = opts.sparse, drawn = opts.drawn,
                damage = Mixed(opts.named) })
            return learner.IsTrainLearned(RAIN) and T.Store().healTrains[RAIN].row or nil
        end
        Check("trains: of three castless damage rows none a heal row, the one whose learned hits share the ticks' "
            .. "frames is the row, in a fight whose heals are all the walk's", Learns({ named = Under(ROW) }) == ROW)
        Check("trains: so is the one whose drawn hits share them", Learns({ sparse = true, drawn = Under(ROW) }) == ROW)
        local both = Under(ROW)
        for _, hit in ipairs(Under(PROC)) do both[#both + 1] = hit end
        Check("trains: two castless damage rows whose hits share the ticks' frames name neither",
            Learns({ named = both }) == nil)
        Check("trains: hits of a row off the ticks' frames name no row", Learns({ named = Under(ROW, 0.5) }) == nil)

        -- shamanresto F2: the last Healing Rain healed you 9 ticks, then hit the mobs on 3 more before the fight's end
        H = Boot()
        TrainRead(H, { RAIN, TWIN }, { rows = { Row(ROW), Row(OTHER) }, sparse = true, damage = Damage({}),
            drawn = Under(ROW, 0, 12) })
        Check("trains: a walk's ticks run on through the hits drawn under its row past its last heal on you",
            T.Store().healTrains[RAIN].walks[1].ticks == 12)

        -- shamanresto F2: you stood outside the first Healing Rain for 5 ticks while it hit the mobs
        local function Outside(spellID)
            local learner = Boot()
            Read(learner, Damage({}))
            learner.Cast(RAIN, 100)
            for tick = 1, 4 do learner.Struck(spellID, 100 + 1.5 * tick) end
            return learner, learner.Claim({}, { { size = 11000 } }, nil, 107.5)[1]
        end
        local outside, fifth = Outside(ROW)
        Check("trains: ticks drawn only on the mobs under the train's row are no misses: its 5th tick on you is its own",
            fifth == ROW)
        outside.Struck(ROW, 109)
        Check("trains: a heal in the frame of a tick the mobs' hit already counted is that tick's",
            outside.Claim({}, { { size = 11000 } }, nil, 109)[1] == ROW)
        local _, foreign = Outside(OTHER)
        Check("trains: hits drawn under another ID keep no train running", foreign == nil)
    end

    do -- trains: the claim of a running train's ticks (learned: 9600-11700 every 1.5 s, 8 ticks)
        local ns = T.Boot()
        local H = ns.Heals
        TrainRead(H, { TIDE })
        TrainRead(H, { TIDE })
        H.Cast(TIDE, 100)
        local early = H.Claim({}, { { size = 11700 } }, nil, 100.5)
        local first = H.Claim({}, { { size = 5000 }, { size = 11700 } }, nil, 101.55)
        local second = H.Claim({}, { { size = 11400 } }, nil, 103.05)
        Check("trains: a running train names the heal in its band on each due tick, nothing between ticks",
            next(early) == nil and first[1] == nil and first[2] == TIDE and second[1] == TIDE)
        local off = H.Claim({}, { { size = 7000 } }, nil, 104.55) -- in the band, past STEP of 11400
        local late = H.Claim({}, { { size = 11000 } }, nil, 107.7)
        Check("trains: a heal off its last tick's size is no tick; two missed ticks end the train",
            next(off) == nil and next(late) == nil)
        H.Cast(TIDE, 200)
        local again = H.Claim({}, { { size = 11700 } }, nil, 201.5)
        H.Cast(TIDE, 202)
        local oldPhase = H.Claim({}, { { size = 11700 } }, nil, 203)
        Check("trains: a later cast starts the train again; a recast while it runs restarts it from the recast",
            again[1] == TIDE and next(oldPhase) == nil and H.Claim({}, { { size = 11700 } }, nil, 203.5)[1] == TIDE)
        Check("trains: a claim with no frame stamp leaves the trains out",
            next(H.Claim({}, { { size = 11400 } })) == nil and H.Claim({}, { { size = 11400 } }, nil, 205)[1] == TIDE)
    end

    do -- trains: walks of 8, 8 and 16 ticks (one ran on into heals past its train) learn 8 ticks
        local ns = T.Boot()
        local H = ns.Heals
        local function size(tick) return 12000 - 300 * ((tick - 1) % 8 + 1) end
        TrainRead(H, { TIDE }, { size = size })
        TrainRead(H, { TIDE }, { size = size, ticks = 16 })
        TrainRead(H, { TIDE }, { size = size })
        H.Cast(TIDE, 100)
        local claimed = 0
        for tick = 1, 8 do
            if H.Claim({}, { { size = size(tick) } }, nil, 100 + 1.5 * tick)[1] == TIDE then claimed = claimed + 1 end
        end
        local ninth = H.Claim({}, { { size = 9400 } }, nil, 113.5)
        Check("trains: the learned tick count is the walks' median; a heal a period past the 8th tick is no tick",
            H.IsTrainLearned(TIDE) and claimed == 8 and next(ninth) == nil)
    end

    do -- trains: walks of 8 and 5 ticks; the fight ended 1 s after the 5th (shamanresto F2's last Healing Rain)
        local function Ticks(ended)
            local H = T.Boot().Heals
            TrainRead(H, { TIDE })
            TrainRead(H, { TIDE }, { ticks = 5, ended = ended })
            H.Cast(TIDE, 100)
            local claimed = 0
            for tick = 1, 9 do
                if H.Claim({}, { { size = 11000 } }, nil, 100 + 1.5 * tick)[1] == TIDE then claimed = claimed + 1 end
            end
            return claimed, T.Store().healTrains[TIDE].walks[2].cut
        end
        local cut, flagged = Ticks(18.5)
        local whole, unflagged = Ticks(nil)
        Check("trains: a walk the fight's end cut short gives no tick count while a whole walk does (" .. cut .. " vs "
            .. whole .. ")", cut == 8 and flagged == true and whole == 5 and unflagged == nil)
    end

    do -- the saved store is checked, never trusted
        local ns = T.Boot(function()
            local walk = { with = {}, period = 1.5, size = 10500, low = 9600, high = 11700, ticks = 8 }
            CombatTextIconsCharDB = { healTrains = {
                [TIDE] = { row = TIDE, walks = { walk, walk } },
                [TOTEM] = { row = 0.5, walks = { walk, walk } },
                [CHAIN_HEAL] = "junk",
                [77472] = { row = 77472, walks = { walk, { with = { "x", CHAIN_HEAL } },
                    { with = {}, period = 1.5, size = 5, low = 9, high = 10, ticks = 8 } } },
                [61295] = { row = 61295, walks = { { with = {}, period = 1.5, size = 10500, low = 9600, high = 11700,
                    ticks = 8, luck = 1e-6 } } },
                [1267068] = { row = 1267068, walks = { { with = {}, period = 1.5, size = 10500, low = 9600,
                    high = 11700, ticks = 8, luck = -1 } } },
                [109304] = { row = 109304, walks = { { with = {}, period = 1, size = 4396, low = 4396, high = 4397,
                    ticks = 6, share = 0.05 }, { with = {}, period = 1, size = 4396, low = 4396, high = 4397, ticks = 6,
                    share = 2 } } },
                [974] = { row = 974, walks = { { with = {}, period = 1.5, size = 10500, low = 9600, high = 11700,
                    ticks = 8, cut = true }, { with = {}, period = 1.5, size = 10500, low = 9600, high = 11700,
                    ticks = 8, cut = "yes" } } },
            } }
        end)
        local saved = T.Store().healTrains
        Check("trains: a valid saved train loads learned", ns.Heals.IsTrainLearned(TIDE))
        Check("trains: a saved sure walk teaches alone; a bad luck is dropped and its walk counts as WALK_ALPHA",
            ns.Heals.IsTrainLearned(61295) and not ns.Heals.IsTrainLearned(1267068)
            and #saved[1267068].walks == 1 and saved[1267068].walks[1].luck == nil)
        Check("trains: saved trains with a bad row or junk are dropped", saved[TOTEM] == nil and saved[CHAIN_HEAL] == nil)
        Check("trains: a saved train keeps its valid walks, each with only valid IDs", #saved[77472].walks == 2
            and saved[77472].walks[2].with[1] == CHAIN_HEAL and #saved[77472].walks[2].with == 1)
        Check("tails: a saved walk keeps a share from 0 to 1; a walk with another share is dropped; none is no share",
            #saved[109304].walks == 1 and saved[109304].walks[1].share == 0.05 and saved[TIDE].walks[1].share == nil)
        Check("trains: a saved walk keeps a cut of true; any other cut, or none (older saves), is none",
            saved[974].walks[1].cut == true and saved[974].walks[2].cut == nil and saved[TIDE].walks[1].cut == nil)
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

        -- a clear read whose Rune of Self-Mending row is its heals' amounts summed: 5763 + a 11527 crit
        ns = T.Boot()
        ns.Teacher.area = "clear"
        S = T.State()
        local runeSession = Session({})
        runeSession.healRows = { { spellID = 1287908, totalAmount = 17290, overkillAmount = 0 } }
        S.sessions = { runeSession }
        ns.Teacher.Start(1)
        ns.Teacher.Seen(53)
        ns.Teacher.Healed(5763, "", 10)
        ns.Teacher.Healed(11527, "CRITICAL", 20)
        ns.Teacher.Finish(100)
        FireAll(S)
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

        -- a clear read of one Healing Rain cast: 8 heal ticks every 1.5 s, each frame with a '?' hit of 73921, a heal
        -- and damage row; a heal of 11000 every 3 s between the ticks
        ns = T.Boot()
        ns.Teacher.area = "clear"
        S = T.State()
        local session = Session({ 73921 })
        session.rows[2] = { spellID = 73921, totalAmount = 8, overkillAmount = 0 }
        S.sessions = { session }
        ns.Teacher.Start(1)
        ns.Teacher.Seen(53)
        ns.Teacher.Helped(444995, 10)
        for tick = 1, 8 do
            ns.Teacher.Healed(12000 - 300 * tick, "", 10 + 1.5 * tick)
            ns.Teacher.Unknown("nameplate1", 8, 1, 10 + 1.5 * tick)
        end
        for t = 0.75, 100, 3 do ns.Teacher.Healed(11000, "", t) end
        local learn, ended = ns.Heals.Learn, nil
        ns.Heals.Learn = function(...)
            ended = select(7, ...)
            return learn(...)
        end
        ns.Teacher.Finish(100)
        FireAll(S)
        Check("heals: the fight's damage rows and '?' hits reach the teacher, and a pulsing walk takes their one row",
            ns.Heals.IsTrainLearned(444995) and T.Store().healTrains[444995].row == 73921)
        Check("heals: the fight's end stamp reaches the teacher", ended == 100)
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

    do -- a saved couple (a proc of ID 777 heals you 7 x its hit): its hit drawn in a frame names that frame's heal
        local PROC_ID = 777
        local draws = {}
        local ns = T.Boot(function()
            CombatTextIconsCharDB = { healCouples = { [PROC_ID] = { lo = 7, hi = 7, reads = 2, school = 32 } } }
        end)
        local S = T.State()
        ns.Teacher.area = "clear"
        S.plates.nameplate1, S.target = T.Plate("nameplate1"), "nameplate1"
        ns.Procs.Name = function(_, amount) return amount == 1413 and PROC_ID or nil end
        ns.Display.Plate = function() end
        ns.Display.Player = function(kind, texture) if kind == "heal" then draws[#draws + 1] = texture end end
        ns.Core.PLAYER_REGEN_DISABLED()
        S.now = 50
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 1413, 32)
        ns.Core.UNIT_COMBAT("player", "HEAL", "", 9891, 1)
        ns.Core.UNIT_COMBAT("player", "HEAL", "", 5000, 1)
        S.now = 51
        ns.Core.UNIT_COMBAT("player", "HEAL", "", 9891, 1)
        S.now = 52
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 2000, 32) -- no icon draws it
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 3000, 4)
        ns.Core.UNIT_COMBAT("player", "HEAL", "", 14000, 1)
        ns.Core.UNIT_COMBAT("player", "HEAL", "", 21000, 1)
        ns.Core.FlushHeals()
        Check("heals core: a heal of the learned share of its frame's drawn hit is named; others and a later frame's "
            .. "are '?'", draws[1] == "tex:777" and draws[2] == ns.Meter.UNKNOWN_ICON
            and draws[3] == ns.Meter.UNKNOWN_ICON)
        Check("heals core: the share of an undrawn hit of the couple's school is named, of another school's is not",
            draws[4] == "tex:777" and draws[5] == ns.Meter.UNKNOWN_ICON and #draws == 5)
        Check("heals core: the drawn hit reaches the fight with its stamp and school",
            ns.Teacher.fight.drawn[1].spellID == PROC_ID and ns.Teacher.fight.drawn[1].at == 50
            and ns.Teacher.fight.drawn[1].school == 32)
    end

    do -- a learned train (Healing Tide Totem): its cast starts it, and a heal on its due tick is named
        local rig = CoreRig(false)
        rig.S.harmful[TIDE] = false
        TrainRead(rig.ns.Heals, { TIDE })
        TrainRead(rig.ns.Heals, { TIDE })
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(100, TIDE)
        rig.Heal(101.5, 11700)
        rig.Heal(102.2, 11700)
        rig.Frame(102.3)
        Check("heals core: a learned train's cast names the heal on its due tick; a heal between ticks draws '?'",
            rig.draws[1] == "tex:108280" and rig.draws[2] == rig.ns.Meter.UNKNOWN_ICON and #rig.draws == 2)
    end
end
