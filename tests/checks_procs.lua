-- Unit checks for Procs.lua (castless procs): the per-spec store, the post-fight learner
-- Procs.Read and the hit-time lookup Procs.Name. Called by tests/checks.lua with the same T table
-- (see its header).

return function(T)
    local Check, Secret = T.Check, T.Secret
    local AT = 100 -- run.at of every read below

    local function Count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

    -- A booted addon with Procs.lua loaded by hand (the .toc lists it from Phase 2 on); no Init yet.
    local function Load(setup)
        local ns = T.Boot(setup)
        if not ns.Procs then assert(loadfile(T.Root .. "/Procs.lua"))("CombatTextIcons", ns) end

        return ns
    end
    -- Load plus Init on the booted char DB; returns ns and the live store (the saved table).
    local function Rig(setup)
        local ns = Load(setup)
        ns.Procs.Init(T.Store())

        return ns, T.Store().procs
    end
    local function Entry(school, lo, hi, streak, learned)
        return { school = school, lo = lo, hi = hi, streak = streak or 0, learned = learned == true, unpaired = 0, seen = 0 }
    end

    -- Streams constants ----------------------------------------------------------------------
    do
        local Streams = T.Boot().Streams
        Check("procs streams: SIZE_GUARD, CRIT_LO and CRIT_HI are exported (retail 0.15, 1.8, 2.7)",
            Streams.SIZE_GUARD == 0.15 and Streams.CRIT_LO == 1.8 and Streams.CRIT_HI == 2.7)
        Streams = T.Boot(function(State) State.interface = 16001 end).Streams
        Check("procs streams: the Forever crit band is exported (1.35, 1.65)",
            Streams.SIZE_GUARD == 0.15 and Streams.CRIT_LO == 1.35 and Streams.CRIT_HI == 1.65)
    end

    -- Saved data is checked on load (spec 3.1) -----------------------------------------------
    do
        local secretKey = Secret(21)
        local ns = Load(function()
            CombatTextIconsCharDB = { procs = {
                [10] = { school = 106, lo = 339, hi = 364, streak = 3, learned = true, unpaired = 1, seen = 5 },
                [11] = { school = 32, lo = 100, hi = 120, streak = 2 },
                [12] = "text",
                ["13"] = { school = 106, lo = 339, hi = 364 },
                [14] = { school = 106, lo = 400, hi = 300 },
                [15] = { school = 106, lo = 0, hi = 10 },
                [16] = { school = 106, lo = -5, hi = 10 },
                [17] = { school = "fire", lo = 1, hi = 2 },
                [18] = { school = 106, lo = "a", hi = 2 },
                [19] = { school = 106, lo = 339, hi = Secret(364) },
                [20] = Secret({}),
                [22] = { school = 106, lo = 5, hi = 9, streak = "x", unpaired = -3, seen = "y", learned = "yes" },
                [23] = { school = 106, lo = 5, hi = 9, streak = 1.5, unpaired = 2.5, seen = -1, learned = false },
                [24] = { school = 8, lo = 100, hi = 120, floor = 40 },
                [25] = { school = 8, lo = 100, hi = 120, floor = 100 },
                [26] = { school = 8, lo = 100, hi = 120, floor = "x" },
            } }
            CombatTextIconsCharDB.procs[secretKey] = { school = 106, lo = 339, hi = 364 }
        end)
        local ok = pcall(ns.Procs.Init, T.Store())
        local procs = T.Store().procs
        Check("procs load: junk entries (string, string key, lo > hi, lo 0, lo < 0, string school or lo, secret hi, secret entry, secret key) raise no error", ok)
        local ids = {}
        for id in pairs(procs) do ids[#ids + 1] = type(id) == "number" and id or -1 end
        table.sort(ids)
        Check("procs load: only the valid entries 10, 11, 22-26 are kept", table.concat(ids, ",") == "10,11,22,23,24,25,26" and procs[secretKey] == nil)
        Check("procs load: a floor is kept only as a number under lo (40 kept; 100 = lo and 'x' dropped)",
            procs[24].floor == 40 and procs[25].floor == nil and procs[26].floor == nil)
        Check("procs load: a valid learned entry is kept as saved",
            procs[10] and procs[10].school == 106 and procs[10].lo == 339 and procs[10].hi == 364 and procs[10].streak == 3
            and procs[10].learned == true and procs[10].unpaired == 1 and procs[10].seen == 5)
        Check("procs load: a missing streak, unpaired, seen and learned become 0, 0, 0 and false (streak 2 is kept)",
            procs[11] and procs[11].streak == 2 and procs[11].unpaired == 0 and procs[11].seen == 0 and procs[11].learned == false)
        Check("procs load: a streak 'x' or 1.5, unpaired -3 or 2.5, seen 'y' or -1 become 0; learned 'yes' becomes false",
            procs[22] and procs[22].streak == 0 and procs[22].unpaired == 0 and procs[22].seen == 0 and procs[22].learned == false
            and procs[23] and procs[23].streak == 0 and procs[23].unpaired == 0 and procs[23].seen == 0 and procs[23].learned == false)

        ns = Load(function() CombatTextIconsCharDB = { procs = "junk" } end)
        ns.Procs.Init(T.Store())
        Check("procs load: a procs value that is not a table is replaced by an empty store",
            type(T.Store().procs) == "table" and next(T.Store().procs) == nil)
    end

    -- Get, Drop, Unpaired, Paired, Forget, List ------------------------------------------------
    do
        local ns, procs = Rig()
        local Procs = ns.Procs
        procs[7], procs[8] = Entry(106, 339, 364, 3, true), Entry(32, 100, 120, 2, false)
        Check("procs get: serves the learned entry itself; a candidate and an unknown id give nil",
            Procs.Get(7) == procs[7] and Procs.Get(8) == nil and Procs.Get(9) == nil)
        local okGet, secretGet, textGet = pcall(function() return Procs.Get(Secret(7)), Procs.Get("7") end)
        Check("procs get: a secret or non-number id gives nil and raises no error", okGet and secretGet == nil and textGet == nil)

        Procs.Unpaired(7)
        Check("procs unpaired: the first strike keeps a learned entry and counts 1", Procs.Get(7) ~= nil and procs[7].unpaired == 1)
        Procs.Paired(7)
        Check("procs paired: resets the strikes to 0", procs[7].unpaired == 0)
        Procs.Unpaired(7); Procs.Unpaired(7)
        Check("procs unpaired: the second strike in a row drops the entry", procs[7] == nil)

        procs[7] = Entry(106, 339, 364, 3, true)
        local okOther = pcall(function()
            Procs.Unpaired(8); Procs.Unpaired(8); Procs.Paired(8)
            Procs.Unpaired(99); Procs.Paired(99); Procs.Unpaired(Secret(7)); Procs.Paired(Secret(7)); Procs.Unpaired(nil)
        end)
        Check("procs unpaired / paired: a candidate, an unknown id and a secret id change nothing and raise no error",
            okOther and procs[8] ~= nil and procs[8].unpaired == 0 and procs[7].unpaired == 0)

        local okDrop = pcall(function() Procs.Drop(Secret(7)); Procs.Drop(nil); Procs.Drop(99) end)
        Procs.Drop(8)
        Check("procs drop: removes a candidate at once; secret, nil and unknown ids do nothing and raise no error",
            okDrop and procs[8] == nil and procs[7] ~= nil)

        procs[9], procs[3] = Entry(106, 339, 364, 3, true), Entry(32, 100, 120, 2, false)
        local list = Procs.List()
        local first, second = list[1], list[2]
        Check("procs list: every entry sorted by id (7 is learned too), with the six public fields",
            #list == 3 and first.spellID == 3 and first.school == 32 and first.lo == 100 and first.hi == 120 and first.streak == 2
            and first.learned == false and second.spellID == 7 and list[3].spellID == 9 and list[3].learned == true)
        first.lo = 0
        Check("procs list: the entries are copies (changing one leaves the store alone)", procs[3].lo == 100)
        procs[10] = { school = 32, lo = 1000, hi = 1100, period = 1.5, streak = 1, learned = false, unpaired = 0, seen = 0 }
        local withPeriod = {}
        for _, item in ipairs(Procs.List()) do withPeriod[item.spellID] = item end
        Check("procs list: a rhythm entry carries its period, a size entry has none",
            withPeriod[10].period == 1.5 and withPeriod[3].period == nil and withPeriod[9].period == nil)

        Procs.Forget()
        Check("procs forget: empties the store in place (the saved table stays the same table)",
            next(procs) == nil and T.Store().procs == procs)
    end

    -- Read helpers ---------------------------------------------------------------------------
    local function N(school, amount) return { school = school, amount = amount, crit = false } end
    local function C(school, amount) return { school = school, amount = amount, crit = true } end
    local function U(school, amount) return { school = school, amount = amount } end -- crit unknown (nil)
    -- A read whose '?' hits of a school all sit in exact pairs learns those pairs at once (Procs' Whole), so the checks of
    -- one exact pair below expect `learned`. Stray(school) is an unknown-flag hit no group holds: the school is not split
    -- whole and a pair only counts one fight, which the streak checks need.
    local function Stray(school) return U(school, 1) end

    -- The meter side of a read as Teacher.Verdicts builds it. spec = { id, total, overkill?, tally?, verdict? }:
    -- a row without `tally` is unpaired and listed in `open`.
    local function World(specs)
        local world = { rows = {}, results = {}, open = {} }
        for index, spec in ipairs(specs) do
            local row = { spellID = spec.id, total = spec.total, overkill = spec.overkill or 0 }
            world.rows[index] = row
            world.results[index] = { spellID = spec.id, meterID = spec.id, tally = spec.tally or 0, meter = spec.total,
                verdict = spec.verdict or "unpaired" }
            if not spec.tally then world.open[#world.open + 1] = { row = row, index = index } end
        end

        return world
    end
    -- One read on a fresh rig. seed(procs, ns) runs first. Returns the store, the world, the debug lines, ns.
    local function Once(hitList, specs, seed)
        local ns, procs = Rig()
        local lines = {}
        ns.Debug = function(format, ...) lines[#lines + 1] = string.format(format, ...) end
        if seed then seed(procs, ns) end
        local world = World(specs)
        ns.Procs.Read(hitList, world.open, world.results, world.rows, AT)

        return procs, world, lines, ns
    end
    local function Seed(id, school, lo, hi, streak, learned)
        return function(procs) procs[id] = Entry(school, lo, hi, streak, learned) end
    end
    local function Is(entry, school, lo, hi, streak, learned)
        return entry ~= nil and entry.school == school and entry.lo == lo and entry.hi == hi and entry.streak == streak
            and entry.learned == (learned == true)
    end

    -- Size groups (spec 3.1), seen through the candidate that a group's exact sum creates -------------
    do
        local procs = Once({ N(106, 118), N(106, 100), N(106, 116) }, { { id = 1, total = 216 }, { id = 2, total = 118 } })
        Check("procs read walk: 100 and 116 share a group (16 <= 15 % of 116), 118 starts one (18 > 15 % of 118)",
            Is(procs[1], 106, 100, 116, 1, true) and Is(procs[2], 106, 118, 118, 1, true))

        procs = Once({ N(106, 1000), N(106, 1100), C(106, 1810) }, { { id = 1, total = 3910 } })
        Check("procs read crit: a crit inside [smallest x 1.8, largest x 2.7] adds to the group's sum, not to its band",
            Is(procs[1], 106, 1000, 1100, 1, true))
        local low = Once({ N(106, 1000), N(106, 1100), C(106, 1790) }, { { id = 1, total = 2100 } })
        local high = Once({ N(106, 1000), N(106, 1100), C(106, 2980) }, { { id = 1, total = 2100 } })
        Check("procs read crit: a crit below (1790) or above (2980) every band is an orphan (the sum stays 2100)",
            Is(low[1], 106, 1000, 1100, 1) and Is(high[1], 106, 1000, 1100, 1))
        procs = Once({ N(106, 1000), N(106, 1400), N(106, 1500), C(106, 2600) }, { { id = 1, total = 1000 }, { id = 2, total = 2900 } })
        Check("procs read crit: a crit that fits two groups (2600 in [1800, 2700] and [2520, 4050]) is an orphan",
            Is(procs[1], 106, 1000, 1000, 1) and Is(procs[2], 106, 1400, 1500, 1))
        procs = Once({ N(106, 1000), N(106, 1100), U(106, 1050) }, { { id = 1, total = 2100 } })
        Check("procs read flag: a hit with an unknown crit flag is an orphan, never a normal member (sum 2100, not 3150)",
            Is(procs[1], 106, 1000, 1100, 1))

        -- Runs 20261025T180045Z/181738Z: proc 1287663 hits 343 early in a fight and 412 under a x1.2 buff; the
        -- walk splits them and neither half is the row, so its 343s fed the DoT learner and Wither won their votes.
        local stepped = { N(106, 343), N(106, 343), N(106, 343), N(106, 411), N(106, 412), N(106, 412) }
        procs = Once(stepped, { { id = 1287663, total = 2264 } })
        Check("procs read step: one school's groups spanning less than a crit (343-412) also count as one group",
            Is(procs[1287663], 106, 343, 412, 1, true) and Count(procs) == 1)
        -- Run 20261025T194314Z: a vote-learned DoT (Wither) drew half of proc 1287663's ticks, so no '?' group summed to the row.
        local ns, store = Rig()
        local world = World({ { id = 1287663, total = 2265 } })
        local unknownHalf, drawnHalf = { N(106, 343), N(106, 343), N(106, 412) }, { N(106, 343), N(106, 412), N(106, 412) }
        ns.Procs.Read(unknownHalf, world.open, world.results, world.rows, AT, drawnHalf)
        local withTicks = Is(store[1287663], 106, 343, 412, 1)
        Check("procs read ticks: a learned DoT's drawn ticks join their school's '?' hits in one more group (343-412, 2265);"
            .. " without them nothing matches", withTicks and next((Once(unknownHalf, { { id = 1287663, total = 2265 } }))) == nil)
        procs = Once({ N(106, 1000), N(106, 1000), N(106, 1800) }, { { id = 1, total = 3800 } })
        Check("procs read step: groups a crit apart or more (1000, 1800 = 1000 x 1.8) stay apart (no 3800 group; only the"
            .. " school's remainder pairs the row)", Is(procs[1], 106, 1000, 1800, 1, true) and procs[1].rest == true)
    end

    -- A proc that only crits (shamanele F3: 285452's four crits, 43116-56732, summed to its row 202282) -------------------
    do
        local crits = { C(4, 43116), C(4, 45727), C(4, 56707), C(4, 56732), Stray(4) }
        local procs = Once(crits, { { id = 285452, total = 202282 } })
        Check("procs read crit-only: a school's crits with no normal walk and run on their own; the band is their"
            .. " normal-scale size (21558-28366), critOnly", Is(procs[285452], 4, 21558, 28366, 1) and procs[285452].critOnly == true)
        local decoy = { N(4, 16764), C(4, 43116), C(4, 45727), C(4, 56707), C(4, 56732), Stray(4) }
        procs = Once(decoy, { { id = 285452, total = 202282 } })
        Check("procs read crit-only: a crit another spell's normal claims (43116 in 16764's crit window) still sums with"
            .. " the crits", Is(procs[285452], 4, 21558, 28366, 1) and procs[285452].critOnly == true)
        procs = Once({ C(8, 48447), Stray(8) }, { { id = 1259101, total = 48447 } })
        Check("procs read crit-only: one crit equal to a row is no group (too thin to learn a band from)", next(procs) == nil)
        local critOnly = function(p) p[7] = Entry(4, 21558, 28366, 1); p[7].critOnly = true end
        procs = Once({ N(4, 22000), N(4, 23000), Stray(4) }, { { id = 7, total = 45000 } }, critOnly)
        Check("procs read crit-only: a group with normals that overlaps a crit-only candidate grows it and clears critOnly",
            Is(procs[7], 4, 21558, 28366, 2) and procs[7].critOnly == nil)
        -- shaman3 loo: a crit-only group widened learned 1310088 off its hits until Unpaired dropped it
        local twoCrits = { C(4, 42000), C(4, 48000), Stray(4) } -- normal scale 21000-24000
        local open, _, openLines = Once(twoCrits, { { id = 7, total = 90000 } }, Seed(7, 4, 18000, 22000, 3, true))
        local under = { id = 7, total = 190000, tally = 100000, verdict = "under" } -- complement window [90000, 90000]
        local complement, _, underLines = Once(twoCrits, { under }, Seed(7, 4, 18000, 22000, 3, true))
        Check("procs read crit-only: a crit-only group widens no learned proc that has normals (open row or complement)",
            Is(open[7], 4, 18000, 22000, 3, true) and Is(complement[7], 4, 18000, 22000, 3, true) and #openLines + #underLines == 0)

        local ns = Load(function()
            CombatTextIconsCharDB = { procs = {
                [9] = { school = 4, lo = 21558, hi = 28366, streak = 3, learned = true, critOnly = true },
                [10] = { school = 8, lo = 100, hi = 120, critOnly = "yes" },
            } }
        end)
        local Procs = ns.Procs
        Procs.Init(T.Store())
        Check("procs load crit-only: a saved critOnly true is kept, anything else is dropped",
            T.Store().procs[9].critOnly == true and T.Store().procs[10].critOnly == nil)
        Check("procs name crit-only: draws a crit whose normal-scale size sits in the padded band (50000, unknown flag too)",
            Procs.Name(4, 50000, "CRITICAL") == 9 and Procs.Name(4, 50000, nil) == 9)
        Check("procs name crit-only: never a normal hit, even one of the band's size (25000)", Procs.Name(4, 25000, "") == nil)
        Check("procs name crit-only: no crit past the padded band (80000 / 2 > 28366 x 1.15; 36000 / 2 < 21558 x 0.85)",
            Procs.Name(4, 80000, "CRITICAL") == nil and Procs.Name(4, 36000, "CRITICAL") == nil)
    end

    -- A ticking proc's cut-short last tick and its walk-split runs (runs 20261025T192458Z, 194821Z: Surging Totem 73921) ---
    do
        local procs, _, lines = Once({ N(8, 2315), N(8, 11592), N(8, 11720), N(8, 11802), N(8, 12117) }, { { id = 73921, total = 49546 } })
        Check("procs read partial: a core of 3+ normals plus one lone hit below it sums to the row -> band 11592-12117, floor 2315",
            Is(procs[73921], 8, 11592, 12117, 1, true) and procs[73921].floor == 2315 and Count(procs) == 1
            and lines[1] == "TEACH proc 73921 school=8 band=11592-12117 floor=2315 streak=1 learned")
        procs = Once({ N(8, 9458), N(8, 11314), N(8, 11955), C(8, 22832) }, { { id = 73921, total = 55559 } })
        Check("procs read run: walk-split groups (9458 | 11314-11955) less than a crit apart are one group with the crits in its"
            .. " window (55559)", Is(procs[73921], 8, 9458, 11955, 1, true) and procs[73921].floor == nil)
        procs = Once({ N(8, 1000), N(8, 1000), N(8, 500) }, { { id = 1, total = 2500 } })
        Check("procs read partial: a core under 3 normals takes no lone hit (1000, 1000 + 500 is no 2500 group; only the"
            .. " school's remainder pairs the row)", Is(procs[1], 8, 500, 1000, 1, true) and procs[1].rest == true)

        local cast = { school = 106, amount = 700, crit = false, castID = 7 }
        procs = Once({ cast }, { { id = 7, total = 700 } })
        local candidate = Once({ { school = 106, amount = 700, crit = false, candidates = { { castID = 7 } } } }, { { id = 7, total = 700 } })
        Check("procs read cast: a row whose spell was cast near the '?' hits (sole cast or candidate) is never a proc candidate",
            next(procs) == nil and next(candidate) == nil)

        local under = { id = 7, total = 5000, tally = 4800, verdict = "under" } -- complement window [200, 200]
        procs, _, lines = Once({ N(106, 200) }, { under }, Seed(7, 106, 330, 360, 3, true))
        Check("procs read under: one lone hit below a learned band lowers only its floor (band 330-360, floor 200)",
            Is(procs[7], 106, 330, 360, 3, true) and procs[7].floor == 200
            and lines[1] == "TEACH proc 7 school=106 band=330-360 floor=200 streak=3 widen")
    end

    -- Remainder pass (L14): a school's '?' hits and drawn ticks no matched group holds, against the rows no group fits ---
    -- Wither 445468's row equalled its school's remainder exactly in 12 of 13 warlock fights (lock, lock2).
    do
        local function ReadWith(hitList, specs, ticks, seed)
            local ns, procs = Rig()
            if seed then seed(procs) end
            local world = World(specs)
            ns.Procs.Read(hitList, world.open, world.results, world.rows, AT, ticks)

            return procs, ns
        end
        -- 1000 | 2000 are a crit apart (no run), 9000 fits neither crit window, 500's flag is unknown, 700 is a drawn tick
        local mixed = { N(36, 1000), N(36, 2000), C(36, 9000), U(36, 500) }
        local procs, ns = ReadWith(mixed, { { id = 1, total = 13200 } }, { N(36, 700) })
        Check("procs read rest: the school's remainder (normals, orphan crit, unknown flag, drawn tick: 13200) pairs a row no group fits;"
            .. " band 700-2000 from its normals, marked rest, learned at once (an exact sum, overkill 0), so Has",
            Is(procs[1], 36, 700, 2000, 1, true) and procs[1].rest == true and ns.Procs.Has(1) == true and Count(procs) == 1)
        procs, ns = ReadWith({ N(36, 1000), N(36, 2000) }, { { id = 1, total = 2990, overkill = 20 } })
        Check("procs read rest: a remainder inside an overkill window (3000 in [2990, 3010]) is only a candidate, not Has",
            Is(procs[1], 36, 1000, 2000, 1) and procs[1].rest == true and ns.Procs.Has(1) == false)

        procs = ReadWith({ N(36, 1000), N(36, 2000), N(36, 22498) }, { { id = 1, total = 3000 }, { id = 2, total = 22498 } })
        Check("procs read rest: a hit a matched group holds (Malevolence 22498) leaves the remainder's sum and band (3000, 1000-2000)",
            Is(procs[1], 36, 1000, 2000, 1, true) and procs[1].rest == true and Is(procs[2], 36, 22498, 22498, 1) and procs[2].rest == nil)

        local candidate = { N(36, 1000), { school = 36, amount = 2000, crit = false, candidates = { { castID = 1 } } } }
        local sole = { N(36, 1000), { school = 36, amount = 2000, crit = false, castID = 1 } }
        local cast = ReadWith(candidate, { { id = 1, total = 3000 } })
        local solo = ReadWith(sole, { { id = 1, total = 3000 } })
        Check("procs read rest: a row cast near the hits joins the remainder pass; a row that is a '?' hit's sole cast does not",
            Is(cast[1], 36, 1000, 2000, 1, true) and cast[1].rest == true and next(solo) == nil)

        local twoRows = ReadWith({ N(36, 1000), N(36, 2000) }, { { id = 1, total = 3000 }, { id = 2, total = 3000 } })
        Check("procs read rest: one remainder fitting two rows pairs neither", next(twoRows) == nil)

        local under = { id = 7, total = 5000, tally = 3000, verdict = "under" } -- complement window [2000, 2000]
        procs = ReadWith({ N(106, 500), N(106, 1500) }, { under }, nil, Seed(7, 106, 330, 360, 3, true))
        Check("procs read rest: an under row's complement is no remainder target (remainder 2000, band stays 330-360)",
            Is(procs[7], 106, 330, 360, 3, true) and Count(procs) == 1)

        procs, ns = ReadWith({ N(36, 1000), N(36, 2000) }, { { id = 1, total = 3000 } }, nil,
            function(p) p[1] = Entry(36, 1000, 2000, 2); p[1].rest = true end)
        Check("procs read rest: a third exact remainder learns the row as a size proc, and Has counts it once learned",
            Is(procs[1], 36, 1000, 2000, 3, true) and ns.Procs.Has(1) == true and ns.Procs.Name(36, 1500, "") == 1)
    end

    -- Exact match and two-way uniqueness --------------------------------------------------------
    do
        local twoGroups = Once({ N(106, 400), N(32, 400) }, { { id = 1, total = 400 } })
        Check("procs read unique: two groups (schools 106 and 32) matching one row -> neither counts", next(twoGroups) == nil)
        local twoRows = Once({ N(106, 500) }, { { id = 1, total = 500 }, { id = 2, total = 500 } })
        Check("procs read unique: one group matching two rows -> neither counts", next(twoRows) == nil)
        local lone = Once({ N(106, 400), N(32, 300) }, { { id = 1, total = 400 } })
        Check("procs read unique: a lone match counts (control for the two checks above)", Is(lone[1], 106, 400, 400, 1, true) and Count(lone) == 1)

        local atEnd = Once({ N(106, 500) }, { { id = 1, total = 480, overkill = 20 } })
        local over = Once({ N(106, 501) }, { { id = 1, total = 480, overkill = 20 } })
        local under = Once({ N(106, 479) }, { { id = 1, total = 480, overkill = 20 } })
        Check("procs read match: the window is [total, total + overkill] with both ends in (500 in [480, 500]; 501 and 479 out)",
            atEnd[1] ~= nil and over[1] == nil and under[1] == nil)
        local near = Once({ N(106, 499) }, { { id = 1, total = 500 } })
        Check("procs read match: overkill 0 means exact equality (499 against 500 is no match, never a % tolerance)", near[1] == nil)
    end

    -- State x event table of spec 3.1 (row id 7; hits sum to the row's total) ----------------------
    do
        local procs, world, lines, ns = Once({ N(106, 340), N(106, 360), Stray(106) }, { { id = 7, total = 700 } })
        Check("procs read state: no entry + unique match -> candidate (school, band, streak 1, seen = run.at) and one debug line",
            Is(procs[7], 106, 340, 360, 1) and procs[7].seen == AT and procs[7].unpaired == 0
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=340-360 streak=1")

        procs, world, lines = Once({ N(106, 330), N(106, 370), Stray(106) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 1))
        Check("procs read state: candidate + same school + overlapping bands -> streak + 1, band = union",
            Is(procs[7], 106, 330, 370, 2) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=330-370 streak=2")

        procs, world, lines, ns = Once({ N(106, 330), N(106, 370) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 2))
        local row = world.results[1]
        Check("procs read state: streak 3 -> learned (unpaired 0, Procs.Get serves it) and the results row becomes agree with tally = sum",
            Is(procs[7], 106, 330, 370, 3, true) and procs[7].unpaired == 0 and ns.Procs.Get(7) == procs[7]
            and row.spellID == 7 and row.meterID == 7 and row.tally == 700 and row.meter == 700 and row.verdict == "agree"
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=330-370 streak=3 learned")

        procs, world, lines = Once({ N(106, 340), N(106, 360), Stray(106) }, { { id = 7, total = 700 } }, Seed(7, 32, 339, 364, 2))
        Check("procs read state: candidate + other school -> restart (streak 1, the group's school and band)",
            Is(procs[7], 106, 340, 360, 1) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=340-360 streak=1 restart")

        -- Malevolence 446285 hit 22498 in four lock2 fights and 18748 in F3: one off-size fight must not undo the streak
        procs, world, lines = Once({ N(106, 5500), Stray(106) }, { { id = 7, total = 5500 } }, Seed(7, 106, 339, 364, 2))
        Check("procs read state: candidate + same school but bands that do not overlap -> miss (streak and band kept, unpaired 1)",
            Is(procs[7], 106, 339, 364, 2) and procs[7].unpaired == 1
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=339-364 streak=2 miss")

        local missed = function(p) p[7] = Entry(106, 339, 364, 2); p[7].unpaired = 1 end
        procs, world, lines = Once({ N(106, 5500), Stray(106) }, { { id = 7, total = 5500 } }, missed)
        Check("procs read state: a second off-size fight in a row -> restart (streak 1, the group's band, unpaired 0)",
            Is(procs[7], 106, 5500, 5500, 1) and procs[7].unpaired == 0
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=5500-5500 streak=1 restart")

        procs, world, lines = Once({ N(106, 340), N(106, 360) }, { { id = 7, total = 700 } }, missed)
        Check("procs read state: a match in the band after a miss -> learned, the miss forgotten (unpaired 0)",
            Is(procs[7], 106, 339, 364, 3, true) and procs[7].unpaired == 0
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=339-364 streak=3 learned")

        procs, world, lines = Once({ N(106, 5500), Stray(106) }, { { id = 7, total = 5500 } }, Seed(7, 106, 339, 364, 0))
        Check("procs read state: streak 0 + off-size match -> restart at once (nothing to keep)",
            Is(procs[7], 106, 5500, 5500, 1) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=5500-5500 streak=1 restart")

        -- shamanele F3 then F6: 447419's crits paired its row at 35858-36336, then at 21142-22683 with school 4 split whole;
        -- the off-size miss kept the F3 band and nothing was learned
        procs, world, lines = Once({ N(106, 5500) }, { { id = 7, total = 5500 } }, Seed(7, 106, 339, 364, 2))
        Check("procs read state: candidate + off-size match that splits its school whole -> learned at the new band at once",
            Is(procs[7], 106, 5500, 5500, 1, true) and world.results[1].verdict == "agree"
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=5500-5500 streak=1 learned")

        procs, world, lines = Once({ N(106, 50) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 2))
        Check("procs read state: candidate + open row with overkill 0 and no unique match -> streak 0, band kept",
            Is(procs[7], 106, 339, 364, 0) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=339-364 streak=0 reset")

        procs, world, lines = Once({ N(106, 50) }, { { id = 7, total = 700, overkill = 10 } }, Seed(7, 106, 339, 364, 2))
        Check("procs read state: candidate + open row with overkill > 0 and no unique match -> unchanged, no line",
            Is(procs[7], 106, 339, 364, 2) and procs[7].seen == 0 and #lines == 0)

        local absent = Once({ N(106, 340), N(106, 360) }, {}, Seed(7, 106, 339, 364, 2))
        local paired, _, pairedLines = Once({ N(106, 340), N(106, 360) }, { { id = 7, total = 700, tally = 700, verdict = "agree" } },
            Seed(7, 106, 339, 364, 2))
        Check("procs read state: candidate + row absent, or row paired (even when the group sum equals its total) -> unchanged",
            Is(absent[7], 106, 339, 364, 2) and Is(paired[7], 106, 339, 364, 2) and #pairedLines == 0)

        procs, world, lines = Once({ N(106, 330), N(106, 370) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 3, true))
        Check("procs read state: learned + open row + unique match of its school with overlapping bands -> widen (union); the row stays unpaired",
            Is(procs[7], 106, 330, 370, 3, true) and world.results[1].verdict == "unpaired"
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=330-370 streak=3 widen")

        local otherSchool, _, l1 = Once({ N(32, 340), N(32, 360) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 3, true))
        local disjoint, _, l2 = Once({ N(106, 5500) }, { { id = 7, total = 5500 } }, Seed(7, 106, 339, 364, 3, true))
        local noMatch, _, l3 = Once({ N(106, 50) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 3, true))
        local inside, _, l4 = Once({ N(106, 345), N(106, 355) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 3, true))
        Check("procs read state: learned + other school, disjoint band, no match, or a group inside the band -> unchanged, no line, no new entry",
            Is(otherSchool[7], 106, 339, 364, 3, true) and Is(disjoint[7], 106, 339, 364, 3, true)
            and Is(noMatch[7], 106, 339, 364, 3, true) and Is(inside[7], 106, 339, 364, 3, true)
            and Count(otherSchool) == 1 and Count(disjoint) == 1 and #l1 + #l2 + #l3 + #l4 == 0)

        local under = { id = 7, total = 5000, tally = 3000, verdict = "under" } -- complement window [2000, 2000]
        procs, world, lines = Once({ N(106, 2000) }, { under }, Seed(7, 106, 330, 360, 3, true))
        Check("procs read state: learned + paired under + unique match with the complement -> widen with no overlap test (band 330-2000)",
            Is(procs[7], 106, 330, 2000, 3, true) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=330-2000 streak=3 widen")

        local otherUnder = Once({ N(32, 2000) }, { under }, Seed(7, 106, 330, 360, 3, true))
        local agreeRow = Once({ N(106, 2000) }, { { id = 7, total = 5000, tally = 5000, verdict = "agree" } }, Seed(7, 106, 330, 360, 3, true))
        local candidateUnder = Once({ N(106, 2000) }, { under }, Seed(7, 106, 330, 360, 2))
        Check("procs read state: a complement of another school, an agree row, or an under row of a candidate -> unchanged",
            Is(otherUnder[7], 106, 330, 360, 3, true) and Is(agreeRow[7], 106, 330, 360, 3, true)
            and Is(candidateUnder[7], 106, 330, 360, 2))
    end

    -- A school whose '?' hits split whole into exact pairs learns them at once (synthetic Outbreak: Virulent Plague and
    -- Dread Plague summed to their rows in F1; shaman2 F2: 1310088's two normals were school 8's whole '?' sum) ------
    do
        local split = { N(32, 1000), N(32, 1000), N(32, 1000), N(32, 5000), N(32, 5000) }
        local rows = { { id = 1, total = 3000 }, { id = 2, total = 10000 } }
        local procs, world = Once(split, rows)
        Check("procs read whole: two exact pairs holding every '?' hit of their school are learned at once, rows agree",
            Is(procs[1], 32, 1000, 1000, 1, true) and Is(procs[2], 32, 5000, 5000, 1, true)
            and world.results[1].verdict == "agree" and world.results[2].verdict == "agree")
        local stray = Once({ N(32, 1000), N(32, 1000), N(32, 1000), N(32, 5000), N(32, 5000), Stray(32) }, rows)
        Check("procs read whole: a hit no pair holds (unknown flag) keeps both pairs candidates",
            Is(stray[1], 32, 1000, 1000, 1) and Is(stray[2], 32, 5000, 5000, 1))
        local overkill = Once(split, { { id = 1, total = 3000 }, { id = 2, total = 9990, overkill = 20 } })
        Check("procs read whole: a pair inside an overkill window leaves the school unsure (both candidates)",
            Is(overkill[1], 32, 1000, 1000, 1) and Is(overkill[2], 32, 5000, 5000, 1))
        local ns, store = Rig()
        local ticked = World(rows)
        ns.Procs.Read(split, ticked.open, ticked.results, ticked.rows, AT, { N(32, 7000) })
        Check("procs read whole: a drawn tick of the school (votes, not the meter) leaves it unsure (both candidates)",
            Is(store[1], 32, 1000, 1000, 1) and Is(store[2], 32, 5000, 5000, 1))
    end

    -- One group fitting an open row and a learned-under complement: neither counts ----------------
    do
        local specs = { { id = 7, total = 1000, tally = 600, verdict = "under" }, { id = 8, total = 400 } } -- complement window [400, 400]
        local both = Once({ N(106, 400) }, specs, Seed(7, 106, 330, 360, 3, true))
        Check("procs read unique: a group fitting both the open row 8 and the complement of 7 neither widens 7 nor teaches 8",
            Is(both[7], 106, 330, 360, 3, true) and both[8] == nil)
        local complementOnly = Once({ N(106, 400) }, { specs[1] }, Seed(7, 106, 330, 360, 3, true))
        local openOnly = Once({ N(106, 400) }, { specs[2] }, Seed(7, 106, 330, 360, 3, true))
        Check("procs read unique: with the complement alone 7 widens to 330-400; with the open row alone 8 is learned (controls)",
            Is(complementOnly[7], 106, 330, 400, 3, true) and Is(openOnly[8], 106, 400, 400, 1, true) and Is(openOnly[7], 106, 330, 360, 3, true))
    end

    -- Excluded rows: a spell Learn or Fingerprints knows has one owner ---------------------------------
    do
        local function LearnOwns(_, ns)
            T.Store().learned[7] = { school = 32, period = 3, kind = "dot", misses = 0 }
            ns.Learn.Init(T.Store())
        end
        local function FingerprintOwns(_, ns)
            for castAt = 1, 3 do ns.Fingerprints.Add(7, { school = 106, delay = 0.25, castAt = castAt, hops = 1 }) end
        end
        local byLearn = Once({ N(106, 400) }, { { id = 7, total = 400 } }, LearnOwns)
        local byFingerprint, _, _, ns = Once({ N(106, 400) }, { { id = 7, total = 400 } }, FingerprintOwns)
        Check("procs read exclude: a row Learn.Get or Fingerprints.IsLearned knows is never a candidate",
            ns.Fingerprints.IsLearned(7) and byLearn[7] == nil and byFingerprint[7] == nil)
        local shared = Once({ N(106, 400) }, { { id = 7, total = 400 }, { id = 8, total = 400 } }, LearnOwns)
        Check("procs read exclude: an excluded row is removed before matching, so it does not make the group ambiguous (8 is taught)",
            shared[7] == nil and Is(shared[8], 106, 400, 400, 1, true))
    end

    -- Rev 4b: a row whose saved alias names a learned fingerprint is owned too ---------------------------
    do
        local function AliasToLearned(_, ns)
            for castAt = 1, 3 do ns.Fingerprints.Add(7, { school = 106, delay = 0.25, castAt = castAt, hops = 1 }) end
            ns.Fingerprints.SetAlias(8, 7)
        end
        local owned, _, _, ns = Once({ N(106, 400) }, { { id = 8, total = 400 } }, AliasToLearned)
        Check("procs read exclude: a row whose alias names a learned fingerprint (8 -> 7) is never a candidate",
            ns.Fingerprints.IsLearned(7) and ns.Fingerprints.Alias(8) == 7 and owned[8] == nil)
        local free = Once({ N(106, 400) }, { { id = 8, total = 400 } }, function(_, ns2) ns2.Fingerprints.SetAlias(8, 7) end)
        Check("procs read exclude: ... while an alias to an unlearned cast leaves the row free (control)", Is(free[8], 106, 400, 400, 1, true))
    end

    -- Targets' under-loop guards: a complement widens only a proc that has one owner and its own result -------
    do
        local under = { id = 7, total = 5000, tally = 3000, verdict = "under" } -- complement window [2000, 2000]
        local function LearnToo(procs, ns)
            procs[7] = Entry(106, 330, 360, 3, true)
            T.Store().learned[7] = { school = 32, period = 3, kind = "dot", misses = 0 }
            ns.Learn.Init(T.Store())
        end
        local function PrintToo(procs, ns)
            procs[7] = Entry(106, 330, 360, 3, true)
            for castAt = 1, 3 do ns.Fingerprints.Add(7, { school = 106, delay = 0.25, castAt = castAt, hops = 1 }) end
        end
        local byLearn, _, learnLines = Once({ N(106, 2000) }, { under }, LearnToo)
        local byPrint, _, printLines = Once({ N(106, 2000) }, { under }, PrintToo)
        Check("procs read under: a learned proc that Learn or Fingerprints also knows is not widened by its complement",
            Is(byLearn[7], 106, 330, 360, 3, true) and Is(byPrint[7], 106, 330, 360, 3, true) and #learnLines + #printLines == 0)

        local ns, procs = Rig()
        procs[7] = Entry(106, 330, 360, 3, true)
        local world = World({ under })
        world.results[1].spellID = 8 -- the result of another spell (a row paired through an alias)
        ns.Procs.Read({ N(106, 2000) }, world.open, world.results, world.rows, AT)
        Check("procs read under: an under result whose spellID is not its row's spellID does not widen the proc",
            Is(procs[7], 106, 330, 360, 3, true))
    end

    -- Hits with amount <= 0 never join a size group ------------------------------------------------------
    do
        local zero = Once({ N(106, 0) }, { { id = 1, total = 0 } })
        Check("procs read zero: a 0-amount hit against a row with total 0 creates no candidate", next(zero) == nil)
        local mixed = Once({ N(106, 0), N(106, 400) }, { { id = 1, total = 0 }, { id = 2, total = 400 } })
        Check("procs read zero: ... and a positive hit beside it still teaches its row (control)",
            mixed[1] == nil and Is(mixed[2], 106, 400, 400, 1, true))
    end

    -- Three reads teach; the store records the last change ----------------------------------------------
    do
        local ns, procs = Rig()
        local function Read(hitList, at)
            local world = World({ { id = 7, total = 700 } })
            ns.Procs.Read(hitList, world.open, world.results, world.rows, at)
        end
        Read({ N(106, 340), N(106, 360), Stray(106) }, 10)
        Read({ N(106, 335), N(106, 365), Stray(106) }, 20)
        Check("procs read chain: after two exact reads the entry is a candidate with streak 2 (Procs.Get gives nil)",
            Is(procs[7], 106, 335, 365, 2) and procs[7].seen == 20 and ns.Procs.Get(7) == nil)
        Read({ N(106, 338), N(106, 362), Stray(106) }, 30)
        Check("procs read chain: the third exact read learns it (streak 3, learned, seen 30)",
            Is(procs[7], 106, 335, 365, 3, true) and procs[7].seen == 30 and ns.Procs.Get(7) == procs[7])
    end

    -- The 64 cap on unlearned candidates ---------------------------------------------------------------
    do
        local function Crowded(procs)
            procs[1000] = Entry(106, 100, 120, 2, false); procs[1000].seen = 1
            for id = 1001, 1063 do procs[id] = Entry(106, 100, 120, 1, false); procs[id].seen = id - 999 end
            for id = 2000, 2002 do procs[id] = Entry(32, 100, 120, 3, true) end
        end
        local procs = Once({ N(106, 400), Stray(106) }, { { id = 5, total = 400 } }, Crowded)
        local candidates = 0
        for _, entry in pairs(procs) do
            if not entry.learned then candidates = candidates + 1 end
        end
        Check("procs read cap: a 65th candidate evicts the lowest streak, then the lowest seen (1001); 1000 (streak 2) and the learned stay",
            candidates == 64 and procs[1001] == nil and procs[1000] ~= nil and procs[1002] ~= nil and procs[5] ~= nil
            and procs[2000] ~= nil and procs[2001] ~= nil and procs[2002] ~= nil)
    end
    -- Procs.Name (spec 3.2): the fit rules at the 0.85 / 1.15 pads --------------------------------------
    do
        local ns, procs = Rig()
        local Name = ns.Procs.Name
        procs[7] = Entry(106, 339, 364, 3, true) -- normal pad [288.15, 418.6], crit pad [518.67, 1130.22]
        Check("procs name normal: [lo x 0.85, hi x 1.15] -> 289 and 418 fit, 288 and 419 do not (flag '')",
            Name(106, 289, "") == 7 and Name(106, 418, "") == 7 and Name(106, 288, "") == nil and Name(106, 419, "") == nil)
        Check("procs name crit: [lo x 0.85 x 1.8, hi x 1.15 x 2.7] -> 519 and 1130 fit, 518 and 1131 do not (flag CRITICAL)",
            Name(106, 519, "CRITICAL") == 7 and Name(106, 1130, "CRITICAL") == 7
            and Name(106, 518, "CRITICAL") == nil and Name(106, 1131, "CRITICAL") == nil)
        Check("procs name flag: a normal hit never fits the crit range (600, flag ''), a crit never the normal range (400, CRITICAL)",
            Name(106, 600, "") == nil and Name(106, 400, "CRITICAL") == nil)
        Check("procs name unknown crit: a nil flag fits either range (289, 600, 1130) and neither gap (450)",
            Name(106, 289, nil) == 7 and Name(106, 600, nil) == 7 and Name(106, 1130, nil) == 7 and Name(106, 450, nil) == nil)
        Check("procs name unknown crit: a secret flag behaves like a nil flag",
            Name(106, 289, Secret("CRITICAL")) == 7 and Name(106, 600, Secret("")) == 7 and Name(106, 450, Secret("")) == nil)

        procs[8] = Entry(106, 350, 400, 3, true) -- normal pad [297.5, 460]
        procs[9] = Entry(106, 350, 400, 2, false) -- a candidate: never served
        Check("procs name: 2 fitting entries -> nil (360 fits 7 and 8); 290 -> 7 only; 440 -> 8 only (the candidate 9 does not count)",
            Name(106, 360, "") == nil and Name(106, 290, "") == 7 and Name(106, 440, "") == 8)
        Check("procs name: another school -> nil", Name(32, 360, "") == nil and Name(4, 440, "") == nil)
        local okSecret, secretSchool, secretAmount = pcall(function() return Name(Secret(106), 360, ""), Name(106, Secret(360), "") end)
        Check("procs name: a secret school or amount gives nil and raises no error", okSecret and secretSchool == nil and secretAmount == nil)
        local okText, textSchool, textAmount, nothing = pcall(function() return Name("106", 360, ""), Name(106, "360", ""), Name(nil, nil, nil) end)
        Check("procs name: a non-number school or amount gives nil and raises no error",
            okText and textSchool == nil and textAmount == nil and nothing == nil)

        local forever, foreverProcs = Rig(function(State) State.interface = 16001 end)
        foreverProcs[7] = Entry(106, 339, 364, 3, true) -- Forever crit pad [389.0 .. 690.7] = [288.15 x 1.35, 418.6 x 1.65]
        Check("procs name crit: the band is Streams' (Forever 1.35-1.65 fits 390 and 690, not 388 or 691; retail 1.8-2.7 fits 390 nowhere)",
            forever.Procs.Name(106, 390, "CRITICAL") == 7 and forever.Procs.Name(106, 690, "CRITICAL") == 7
            and forever.Procs.Name(106, 388, "CRITICAL") == nil and forever.Procs.Name(106, 691, "CRITICAL") == nil
            and Name(106, 390, "CRITICAL") == nil)
    end
    -- Procs.Name and a floor: a cut-short tick may be the hit (runs 20261025T192458Z, 194821Z) ------------------
    do
        local ns, procs = Rig()
        local Name = ns.Procs.Name
        procs[73921] = Entry(8, 11078, 12929, 3, true)
        procs[73921].floor = 2315 -- floor zone: normal [1967.75, 9416.3), crit [3541.95, 16949.34)
        procs[1310088] = Entry(8, 4907, 5337, 3, true)
        Check("procs name floor: a normal hit inside a proc's own band beats a floor zone (4965 -> 1310088); the band itself"
            .. " still names (11646 -> 73921, 23359 crit -> 73921)",
            Name(8, 4965, "") == 1310088 and Name(8, 11646, "") == 73921 and Name(8, 23359, "CRITICAL") == 73921)
        Check("procs name floor: a floor zone hit outside the named band is nobody's (4600 normal, 13562 crit -> nil)",
            Name(8, 4600, "") == nil and Name(8, 13562, "CRITICAL") == nil)
        procs[73921].floor = nil
        Check("procs name floor: without the floor the padded hits name 1310088 (4600, 13562 crit)",
            Name(8, 4600, "") == 1310088 and Name(8, 13562, "CRITICAL") == 1310088)
    end
    -- Procs.Name and critSeen: shaman2 F3, 1310088 learned from two normals (5101-5310) drew crit 11941, not its own
    -- (its normals with crits 10433 and 9814 sum to the meter's 50489) -----------------------------------------
    do
        local ns, procs = Rig()
        local Name = ns.Procs.Name
        procs[1310088] = Entry(8, 5101, 5310, 1, true)
        procs[1310088].critSeen = false
        Check("procs name crit unseen: a crit draws only when its half sits in the band (10433 yes; 9814, 11941 no);"
            .. " normals keep the padded range (5279, 4907)",
            Name(8, 10433, "CRITICAL") == 1310088 and Name(8, 9814, "CRITICAL") == nil and Name(8, 11941, "CRITICAL") == nil
            and Name(8, 5279, "") == 1310088 and Name(8, 4907, "") == 1310088)
        procs[1310088].critSeen = true
        Check("procs name crit seen: once a crit paired the row the padded crit range is back (11941, 9814)",
            Name(8, 11941, "CRITICAL") == 1310088 and Name(8, 9814, "CRITICAL") == 1310088)

        local normals = Once({ N(8, 5101), N(8, 5310) }, { { id = 1310088, total = 10411 } })
        local withCrit = Once({ N(8, 5101), N(8, 5310), C(8, 10620) }, { { id = 1310088, total = 21031 } })
        Check("procs read crit seen: a pair of normals leaves critSeen false; a group holding a crit sets it",
            normals[1310088].critSeen == false and withCrit[1310088].critSeen == true)
        local under = { id = 7, total = 5000, tally = 1900, verdict = "under" } -- complement window [3100, 3100]
        local seed = function(p) p[7] = Entry(106, 1000, 1100, 3, true); p[7].critSeen = false end
        local crits, _, lines = Once({ N(106, 1050), C(106, 2050) }, { under }, seed)
        Check("procs read crit seen: a complement group inside the band that holds a crit sets critSeen ('crits' line)",
            Is(crits[7], 106, 1000, 1100, 3, true) and crits[7].critSeen == true
            and lines[1] == "TEACH proc 7 school=106 band=1000-1100 streak=3 crits")

        local saved = { procs = { [5] = Entry(8, 100, 200, 3, true), [6] = Entry(8, 100, 200, 3, true) } }
        saved.procs[6].critSeen = false
        ns.Procs.Init(saved)
        Check("procs init: a store saved before critSeen draws crits as before (nil -> true); a saved false stays",
            saved.procs[5].critSeen == true and saved.procs[6].critSeen == false)
    end
    -- Procs.Has (spec 3.1 Rev 4b): a learned entry, or a candidate with a streak -----------------------
    do
        local ns, procs = Rig()
        procs[7] = Entry(106, 339, 364, 3, true)
        procs[8] = Entry(106, 339, 364, 0, false)
        procs[9] = Entry(106, 339, 364, 1, false)
        procs[10] = Entry(106, 339, 364, 2, false)
        local ok, secret, text, nothing = pcall(function() return ns.Procs.Has(Secret(7)), ns.Procs.Has("7"), ns.Procs.Has(nil) end)
        Check("procs has: a learned entry and a candidate with streak >= 1 give true; a streak-0 candidate and an unknown id give false",
            ns.Procs.Has(7) == true and ns.Procs.Has(9) == true and ns.Procs.Has(10) == true
            and ns.Procs.Has(8) == false and ns.Procs.Has(99) == false)
        Check("procs has: a secret, string or nil id gives false and raises no error", ok and secret == false and text == false and nothing == false)
        procs[11] = Entry(106, 339, 364, 2, false)
        procs[11].rest = true
        procs[12] = Entry(106, 339, 364, 3, true)
        procs[12].rest = true
        Check("procs has: a remainder candidate (rest) gives false, so it blocks no cast learner; a learned one gives true",
            ns.Procs.Has(11) == false and ns.Procs.Has(12) == true)
        local saved = { procs = { [5] = Entry(36, 100, 200, 1), [6] = Entry(36, 100, 200, 1) } }
        saved.procs[5].rest, saved.procs[6].rest = "yes", true
        ns.Procs.Init(saved)
        Check("procs init: a saved rest is kept only as true", saved.procs[5].rest == nil and saved.procs[6].rest == true)
    end
    -- One rule, no copies: Procs exports the learn streak and the crit rule ----------------------------
    do
        local ns, procs = Rig()
        local function Crit(flag)
            if not ns.Procs.Crit then return "missing" end

            return ns.Procs.Crit(flag)
        end
        Check("procs export: LEARN_STREAK is 3", ns.Procs.LEARN_STREAK == 3)
        Check("procs export: Crit gives true for a plain 'CRITICAL', false for '' or any other plain flag",
            Crit("CRITICAL") == true and Crit("") == false and Crit("ABSORB") == false)
        local ok, secret, missing = pcall(function() return Crit(Secret("CRITICAL")), Crit(nil) end)
        Check("procs export: Crit gives nil for a nil or secret flag and raises no error", ok and secret == nil and missing == nil)
        procs[7] = Entry(106, 339, 364, 3, true)
        ns.Procs.Crit = function() return true end
        Check("procs export: Procs.Name asks Procs.Crit (a stub saying crit puts a 289 normal-range hit out of range)",
            ns.Procs.Name(106, 289, "") == nil)
    end

    -- Rhythm entries (a stored `period`): learned from tick streams, named only through a stream -----------
    local function Rhythm(school, lo, hi, period, learned)
        local entry = Entry(school, lo, hi, 1, learned)
        entry.period = period

        return entry
    end
    do
        local secretPeriod = Secret(1)
        local ns = Load(function()
            CombatTextIconsCharDB = { procs = {
                [1] = { school = 32, lo = 100, hi = 120, period = 1.5, learned = true },
                [2] = { school = 32, lo = 100, hi = 120, period = 0, learned = true },
                [3] = { school = 32, lo = 100, hi = 120, period = -1, learned = true },
                [4] = { school = 32, lo = 100, hi = 120, period = "x", learned = true },
                [5] = { school = 32, lo = 100, hi = 120, period = secretPeriod, learned = true },
                [6] = { school = 32, lo = 100, hi = 120, learned = true },
            } }
        end)
        ns.Procs.Init(T.Store())
        local procs = T.Store().procs
        Check("procs rhythm load: a period 1.5 is kept; period 0, -1, 'x' and a secret drop the whole entry; no period is unchanged",
            procs[1] and procs[1].period == 1.5 and procs[1].learned == true and procs[2] == nil and procs[3] == nil
            and procs[4] == nil and procs[5] == nil and procs[6] and procs[6].period == nil and procs[6].learned == true)
    end
    do
        local ns, procs = Rig()
        procs[1], procs[2] = Rhythm(32, 1000, 1100, 1, false), Rhythm(32, 1000, 1100, 1, true)
        procs[3] = Entry(32, 1000, 1100, 1, false)
        Check("procs rhythm has: a rhythm candidate is not tracked, a learned rhythm entry is, a size candidate with streak 1 is",
            ns.Procs.Has(1) == false and ns.Procs.Has(2) == true and ns.Procs.Has(3) == true)
        procs[1] = nil
        Check("procs rhythm name: a learned rhythm entry does not name a school-32 hit of 1050 by size", ns.Procs.Name(32, 1050, "") == nil)
    end
    do
        local procs, world, lines = Once({ N(32, 950), N(32, 1050) }, { { id = 5, total = 2000 } },
            function(store) store[5] = Rhythm(32, 1000, 1100, 1, true) end)
        local entry, taught = procs[5], false
        for _, line in ipairs(lines) do taught = taught or line:find("TEACH proc", 1, true) ~= nil end
        Check("procs rhythm read: a size group that fits a rhythm entry's row leaves it unchanged and logs no TEACH proc",
            entry.lo == 1000 and entry.hi == 1100 and entry.learned == true and entry.streak == 1 and not taught
            and world.results[1].verdict == "unpaired")
        local candidate = Once({ N(32, 950), N(32, 1050) }, { { id = 5, total = 2000 } },
            function(store) store[5] = Rhythm(32, 1000, 1100, 1, false) end)
        Check("procs rhythm read: a rhythm candidate is not stepped by a size group either",
            candidate[5].lo == 1000 and candidate[5].hi == 1100 and candidate[5].streak == 1)
    end
    do
        local procs = Once({ N(32, 500), N(32, 500) }, { { id = 1, total = 1500, tally = 500, verdict = "under" }, { id = 2, total = 1000 } },
            function(store) store[1] = Rhythm(32, 300, 400, 1, true) end)
        Check("procs rhythm under: a learned rhythm entry owns no 'under' window, so a 1000 group goes to the open row alone",
            Is(procs[2], 32, 500, 500, 1, true) and procs[1].lo == 300 and procs[1].hi == 400 and procs[1].streak == 1 and procs[1].period == 1)
    end
    do
        local ns, procs = Rig()
        local function Stream(school, period, lastAmount) return { school = school, period = period, lastAmount = lastAmount } end
        procs[7] = Rhythm(32, 1000, 1100, 1.0, true)
        local stream = Stream(32, 1.05, 1050)
        local id = ns.Procs.NameStream(stream)
        Check("procs namestream: a school-32 stream at period 1.05 and last hit 1050 names the entry and caches it on stream.procID",
            id == 7 and stream.procID == 7)
        Check("procs namestream: a school mismatch, a period 1.2 and amounts 1300 / 800 outside the padded band name nothing",
            ns.Procs.NameStream(Stream(4, 1.05, 1050)) == nil and ns.Procs.NameStream(Stream(32, 1.2, 1050)) == nil
            and ns.Procs.NameStream(Stream(32, 1.05, 1300)) == nil and ns.Procs.NameStream(Stream(32, 1.05, 800)) == nil)
        local ok, noAmount, noStream = pcall(function() return ns.Procs.NameStream(Stream(32, 1.05, nil)), ns.Procs.NameStream(nil) end)
        Check("procs namestream: a nil lastAmount or a nil stream gives nil and raises no error", ok and noAmount == nil and noStream == nil)
        procs[8] = Rhythm(32, 1000, 1100, 1.0, true)
        Check("procs namestream: two learned entries that both fit name nothing", ns.Procs.NameStream(Stream(32, 1.05, 1050)) == nil)
        procs[8] = Rhythm(32, 1000, 1100, 1.0, false)
        Check("procs namestream: a rhythm candidate never names", ns.Procs.NameStream(Stream(32, 1.05, 1050)) == 7)
        procs[7] = Rhythm(32, 1000, 1100, 1.0, false)
        Check("procs namestream: with only candidates left the answer is nil", ns.Procs.NameStream(Stream(32, 1.05, 1050)) == nil)
        procs[7], procs[8] = Rhythm(32, 1000, 1100, 1.0, true), nil
        local cached = Stream(32, 1.05, 1050)
        ns.Procs.NameStream(cached)
        ns.Procs.Drop(7)
        Check("procs namestream: after the entry is dropped a cached stream names nothing", ns.Procs.NameStream(cached) == nil)
        procs[9] = Rhythm(32, 1000, 1100, 1.0, true)
        Check("procs namestream: a stale cache is cleared, so a rhythm entry learned later is named on the same stream",
            ns.Procs.NameStream(cached) == 9 and cached.procID == 9)
        procs[9] = nil
        procs[7] = Rhythm(32, 1000, 1100, 1.0, true)
        cached = Stream(32, 1.05, 1050)
        ns.Procs.NameStream(cached)
        ns.Procs.Forget()
        Check("procs namestream: after Forget a cached stream names nothing", ns.Procs.NameStream(cached) == nil)
        procs[7] = Entry(32, 1000, 1100, 3, true)
        cached.procID = 7
        Check("procs namestream: a cached id whose entry has no period (a size proc) is not served", ns.Procs.NameStream(cached) == nil)
        Check("procs periodnear: 1.0 and 1.05 are near, 1.0 and 1.2 are not", ns.Procs.PeriodNear(1.0, 1.05) and not ns.Procs.PeriodNear(1.0, 1.2))
    end
    -- Rhythm pass of Read: a fight's tick streams paired with unpaired meter rows by sum ----------------------
    do
        -- Str({ school, period, sum, lo, hi, n? }, ...): this fight's per-stream records, keyed by their stream table.
        local function Str(...)
            local map = {}
            for _, spec in ipairs({ ... }) do
                map[{ period = spec[2] }] = { school = spec[1], sum = spec[3], lo = spec[4], hi = spec[5], n = spec[6] or 6 }
            end

            return map
        end
        local function Pass(ns, hitList, specs, streams, at)
            local world = World(specs)
            ns.Procs.Read(hitList, world.open, world.results, world.rows, at or AT, nil, streams)

            return world
        end
        local function Cand(entry, school, lo, hi, period, streak, learned)
            return entry ~= nil and entry.school == school and entry.lo == lo and entry.hi == hi and entry.period == period
                and entry.streak == streak and entry.learned == (learned == true)
        end
        local X = { { id = 5, total = 10000 } }

        local ns, procs = Rig()
        local lines = {}
        ns.Debug = function(format, ...) lines[#lines + 1] = string.format(format, ...) end
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm pass: a record of sum 9800 fits row 10000 and makes the candidate {32, p 1.0, 1600-1700, streak 1}",
            Cand(procs[5], 32, 1600, 1700, 1.0, 1, false) and procs[5].unpaired == 0 and procs[5].seen == AT)
        Check("procs rhythm pass: a change logs 'TEACH rhythm 5 school=32 p=1.00 band=1600-1700 streak=1'",
            lines[1] == "TEACH rhythm 5 school=32 p=1.00 band=1600-1700 streak=1")

        local world = Pass(ns, {}, X, Str({ 32, 1.08, 9900, 1550, 1750 }), AT + 1)
        Check("procs rhythm pass: the same school at period 1.08 (within 10 %) is streak 2: learned, band widened, seen moved",
            Cand(procs[5], 32, 1550, 1750, 1.0, 2, true) and procs[5].seen == AT + 1 and procs[5].unpaired == 0)
        Check("procs rhythm pass: learning writes the 'agree' result {tally = group sum, meter = row total} for the row",
            world.results[1].verdict == "agree" and world.results[1].tally == 9900 and world.results[1].meter == 10000
            and world.results[1].spellID == 5 and world.results[1].meterID == 5)
        Check("procs rhythm pass: learning logs ' learned'", lines[#lines] and lines[#lines]:find("streak=2 learned", 1, true) ~= nil)

        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 9400, 1600, 1700 }))
        Check("procs rhythm fit: a sum of 9400 (< 0.95 x 10000) fits nothing", next(procs) == nil)
        Pass(ns, {}, X, Str({ 32, 1.0, 9600, 1600, 1700 }))
        Check("procs rhythm fit: a sum of 9600 (>= 0.95 x 10000) fits", procs[5] ~= nil)

        ns, procs = Rig()
        Pass(ns, {}, { { id = 5, total = 10000, overkill = 200 } }, Str({ 32, 1.0, 10600, 1600, 1700 }))
        Check("procs rhythm fit: a sum of 10600 fits a row of 10000 with overkill 200 (<= 10200 + 500)", procs[5] ~= nil)
        ns, procs = Rig()
        Pass(ns, {}, { { id = 5, total = 10000, overkill = 200 } }, Str({ 32, 1.0, 10800, 1600, 1700 }))
        Check("procs rhythm fit: a sum of 10800 is past the window (> 10700)", next(procs) == nil)

        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Pass(ns, {}, X, {})
        Check("procs rhythm streak: a fight with no match leaves the streak at 1 (no reset)", Cand(procs[5], 32, 1600, 1700, 1.0, 1, false))
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm streak: the third fight matching again learns it (1, gap, 2)", Cand(procs[5], 32, 1600, 1700, 1.0, 2, true))

        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.05, 6000, 1900, 2000 }, { 32, 1.0, 3900, 1600, 1700 }))
        Check("procs rhythm group: records at periods 1.0 and 1.05 (sums 3900 + 6000) pair as one group of 9900; period stays 1.0",
            Cand(procs[5], 32, 1600, 2000, 1.0, 1, false))
        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 4000, 1600, 1700 }, { 4, 1.0, 6000, 1900, 2000 }))
        Check("procs rhythm group: records of different schools never join (4000 + 6000 across schools learns nothing)", next(procs) == nil)
        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 4000, 1600, 1700 }, { 32, 1.5, 6000, 1900, 2000 }))
        Check("procs rhythm group: records at periods 1.0 and 1.5 never join", next(procs) == nil)
        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 4000, 900, 950 }, { 32, 1.0, 6000, 5900, 6100 }))
        Check("procs rhythm group: records of hits 900 and 5900 at one period never join (the group would span a crit)",
            next(procs) == nil)

        ns, procs = Rig()
        Pass(ns, {}, { { id = 5, total = 10000 }, { id = 6, total = 10000 } }, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm unique: a group that fits two rows (two rows of 10000) teaches neither", next(procs) == nil)
        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }, { 4, 1.0, 9900, 1600, 1700 }))
        Check("procs rhythm unique: two groups that fit one row (9800 school 32 and 9900 school 4) teach nothing", next(procs) == nil)

        -- exact pairs: a group's sum inside the row's own window (total .. total + overkill)
        ns, procs = Rig()
        world = Pass(ns, {}, X, Str({ 32, 1.0, 10000, 1600, 1700 }))
        Check("procs rhythm exact: a group summing to a row of no overkill exactly (10000) learns at once, with its 'agree' result",
            Cand(procs[5], 32, 1600, 1700, 1.0, 1, true) and world.results[1].verdict == "agree"
            and world.results[1].tally == 10000)
        ns, procs = Rig()
        Pass(ns, {}, { { id = 5, total = 10000, overkill = 200 } }, Str({ 32, 1.0, 10100, 1600, 1700 }))
        Check("procs rhythm exact: an exact sum inside a row's overkill (10100 in 10000-10200) stays a streak-1 candidate",
            Cand(procs[5], 32, 1600, 1700, 1.0, 1, false))
        ns, procs = Rig()
        Pass(ns, {}, { { id = 5, total = 10000 }, { id = 6, total = 10400 } }, Str({ 32, 1.0, 10000, 1600, 1700 }))
        Check("procs rhythm exact: a group exact for row 10000 that also fits row 10400's widened window pairs the exact row only",
            Cand(procs[5], 32, 1600, 1700, 1.0, 1, true) and procs[6] == nil)
        ns, procs = Rig()
        Pass(ns, {}, { { id = 5, total = 10000 }, { id = 6, total = 10400 } },
            Str({ 32, 1.0, 10000, 1600, 1700 }, { 4, 2.0, 10300, 3000, 3100 }))
        Check("procs rhythm exact: the rows and groups exact pairs leave pair in the widened windows (10300 for row 10400)",
            Cand(procs[5], 32, 1600, 1700, 1.0, 1, true) and Cand(procs[6], 4, 3000, 3100, 2.0, 1, false))
        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 10000, 1600, 1700 }, { 4, 1.0, 10000, 1600, 1700 }))
        Check("procs rhythm exact: two groups exact for one row (10000 school 32 and school 4) teach nothing", next(procs) == nil)

        -- replacement and widening
        ns, procs = Rig()
        procs[5] = Rhythm(32, 1600, 1700, 1.0, false)
        Pass(ns, {}, X, Str({ 4, 1.0, 9800, 1000, 1100 }))
        Check("procs rhythm replace: a candidate and a match of school 4 are replaced by a school-4 candidate, streak 1",
            Cand(procs[5], 4, 1000, 1100, 1.0, 1, false))
        procs[5] = Rhythm(32, 1600, 1700, 1.0, false)
        Pass(ns, {}, X, Str({ 32, 1.5, 9800, 1000, 1100 }))
        Check("procs rhythm replace: a candidate at period 1.0 and a same-school match at period 1.5 are replaced (period 1.5, streak 1)",
            Cand(procs[5], 32, 1000, 1100, 1.5, 1, false))
        procs[5] = Rhythm(32, 1600, 1700, 1.0, true)
        procs[5].streak = 2
        Pass(ns, {}, X, Str({ 4, 1.0, 9800, 1000, 1100 }))
        Check("procs rhythm learned: a match of another school is ignored", Cand(procs[5], 32, 1600, 1700, 1.0, 2, true) and procs[5].seen == 0)
        Pass(ns, {}, X, Str({ 32, 1.5, 9800, 1000, 1100 }))
        Check("procs rhythm learned: a match of another period is ignored", Cand(procs[5], 32, 1600, 1700, 1.0, 2, true) and procs[5].seen == 0)
        world = Pass(ns, {}, X, Str({ 32, 1.02, 9800, 1500, 1750 }), AT + 2)
        Check("procs rhythm learned: a same-school, same-period match widens the band (streak stays 2) and writes no 'agree' result",
            Cand(procs[5], 32, 1500, 1750, 1.0, 2, true) and procs[5].seen == AT + 2 and world.results[1].verdict == "unpaired")

        -- which rows are targets
        ns, procs = Rig()
        Pass(ns, { { school = 32, amount = 100, crit = false, castID = 5 } }, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm target: the row of a spell in hits as a cast (castID = 5) is still a rhythm target", procs[5] ~= nil and procs[5].period == 1.0)

        ns, procs = Rig()
        for castAt = 1, 3 do ns.Fingerprints.Add(5, { school = 106, delay = 0.25, castAt = castAt, hops = 1 }) end
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm target: a row Fingerprints owns gets no entry", ns.Fingerprints.IsLearned(5) and procs[5] == nil)

        ns, procs = Rig()
        procs[5] = Entry(32, 100, 200, 3, true)
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm target: a learned size proc's row is skipped (entry unchanged, no period)",
            Is(procs[5], 32, 100, 200, 3, true) and procs[5].period == nil)

        ns, procs = Rig()
        procs[5] = Entry(32, 100, 200, 2, false)
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm target: a size candidate on the row is replaced by the rhythm candidate",
            Cand(procs[5], 32, 1600, 1700, 1.0, 1, false))

        ns, procs = Rig()
        Pass(ns, { N(32, 10000) }, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        Check("procs rhythm target: a row the size pass matched in the same Read is skipped (a size proc, no period)",
            Is(procs[5], 32, 10000, 10000, 1, true) and procs[5].period == nil)

        ns, procs = Rig()
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, nil, nil }))
        Check("procs rhythm group: a record without lo (crits only) is never grouped", next(procs) == nil)

        ns, procs = Rig()
        for id = 100, 163 do procs[id] = Entry(32, 100, 200, 1, false) end
        Pass(ns, {}, X, Str({ 32, 1.0, 9800, 1600, 1700 }))
        local kept = 0
        for _, entry in pairs(procs) do if not entry.learned then kept = kept + 1 end end
        Check("procs rhythm evict: a new candidate past the cap of 64 evicts the weakest (lowest streak, seen, id: 100); the new one stays",
            kept == 64 and procs[100] == nil and procs[101] ~= nil and procs[5] ~= nil)

        -- no streams: nothing for the rhythm pass to do
        ns, procs = Rig()
        Pass(ns, { N(32, 10000) }, X, nil)
        local sizeOnly = Once({ N(32, 10000) }, X)
        Check("procs rhythm pass: with streams = nil the store is what a size-only Read makes",
            Is(procs[5], 32, 10000, 10000, 1, true) and procs[5].period == nil and Is(sizeOnly[5], 32, 10000, 10000, 1, true))
        ns, procs = Rig()
        Pass(ns, {}, X, nil)
        Check("procs rhythm pass: with streams = nil and no hits the store stays empty", next(procs) == nil)
    end
end
