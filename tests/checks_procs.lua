-- Unit checks for Procs.lua (castless procs): the per-character store, the post-fight learner
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
        ns.Procs.Init(CombatTextIconsCharDB)

        return ns, CombatTextIconsCharDB.procs
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
            } }
            CombatTextIconsCharDB.procs[secretKey] = { school = 106, lo = 339, hi = 364 }
        end)
        local ok = pcall(ns.Procs.Init, CombatTextIconsCharDB)
        local procs = CombatTextIconsCharDB.procs
        Check("procs load: junk entries (string, string key, lo > hi, lo 0, lo < 0, string school or lo, secret hi, secret entry, secret key) raise no error", ok)
        local ids = {}
        for id in pairs(procs) do ids[#ids + 1] = type(id) == "number" and id or -1 end
        table.sort(ids)
        Check("procs load: only the valid entries 10, 11, 22 and 23 are kept", table.concat(ids, ",") == "10,11,22,23" and procs[secretKey] == nil)
        Check("procs load: a valid learned entry is kept as saved",
            procs[10] and procs[10].school == 106 and procs[10].lo == 339 and procs[10].hi == 364 and procs[10].streak == 3
            and procs[10].learned == true and procs[10].unpaired == 1 and procs[10].seen == 5)
        Check("procs load: a missing streak, unpaired, seen and learned become 0, 0, 0 and false (streak 2 is kept)",
            procs[11] and procs[11].streak == 2 and procs[11].unpaired == 0 and procs[11].seen == 0 and procs[11].learned == false)
        Check("procs load: a streak 'x' or 1.5, unpaired -3 or 2.5, seen 'y' or -1 become 0; learned 'yes' becomes false",
            procs[22] and procs[22].streak == 0 and procs[22].unpaired == 0 and procs[22].seen == 0 and procs[22].learned == false
            and procs[23] and procs[23].streak == 0 and procs[23].unpaired == 0 and procs[23].seen == 0 and procs[23].learned == false)

        ns = Load(function() CombatTextIconsCharDB = { procs = "junk" } end)
        ns.Procs.Init(CombatTextIconsCharDB)
        Check("procs load: a procs value that is not a table is replaced by an empty store",
            type(CombatTextIconsCharDB.procs) == "table" and next(CombatTextIconsCharDB.procs) == nil)
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

        Procs.Forget()
        Check("procs forget: empties the store in place (the saved table stays the same table)",
            next(procs) == nil and CombatTextIconsCharDB.procs == procs)
    end

    -- Read helpers ---------------------------------------------------------------------------
    local function N(school, amount) return { school = school, amount = amount, crit = false } end
    local function C(school, amount) return { school = school, amount = amount, crit = true } end
    local function U(school, amount) return { school = school, amount = amount } end -- crit unknown (nil)

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
            Is(procs[1], 106, 100, 116, 1) and Is(procs[2], 106, 118, 118, 1))

        procs = Once({ N(106, 1000), N(106, 1100), C(106, 1810) }, { { id = 1, total = 3910 } })
        Check("procs read crit: a crit inside [smallest x 1.8, largest x 2.7] adds to the group's sum, not to its band",
            Is(procs[1], 106, 1000, 1100, 1))
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
    end

    -- Exact match and two-way uniqueness --------------------------------------------------------
    do
        local twoGroups = Once({ N(106, 400), N(32, 400) }, { { id = 1, total = 400 } })
        Check("procs read unique: two groups (schools 106 and 32) matching one row -> neither counts", next(twoGroups) == nil)
        local twoRows = Once({ N(106, 500) }, { { id = 1, total = 500 }, { id = 2, total = 500 } })
        Check("procs read unique: one group matching two rows -> neither counts", next(twoRows) == nil)
        local lone = Once({ N(106, 400), N(32, 300) }, { { id = 1, total = 400 } })
        Check("procs read unique: a lone match counts (control for the two checks above)", Is(lone[1], 106, 400, 400, 1) and Count(lone) == 1)

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
        local procs, world, lines, ns = Once({ N(106, 340), N(106, 360) }, { { id = 7, total = 700 } })
        Check("procs read state: no entry + unique match -> candidate (school, band, streak 1, seen = run.at) and one debug line",
            Is(procs[7], 106, 340, 360, 1) and procs[7].seen == AT and procs[7].unpaired == 0
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=340-360 streak=1")

        procs, world, lines = Once({ N(106, 330), N(106, 370) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 1))
        Check("procs read state: candidate + same school + overlapping bands -> streak + 1, band = union",
            Is(procs[7], 106, 330, 370, 2) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=330-370 streak=2")

        procs, world, lines, ns = Once({ N(106, 330), N(106, 370) }, { { id = 7, total = 700 } }, Seed(7, 106, 339, 364, 2))
        local row = world.results[1]
        Check("procs read state: streak 3 -> learned (unpaired 0, Procs.Get serves it) and the results row becomes agree with tally = sum",
            Is(procs[7], 106, 330, 370, 3, true) and procs[7].unpaired == 0 and ns.Procs.Get(7) == procs[7]
            and row.spellID == 7 and row.meterID == 7 and row.tally == 700 and row.meter == 700 and row.verdict == "agree"
            and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=330-370 streak=3 learned")

        procs, world, lines = Once({ N(106, 340), N(106, 360) }, { { id = 7, total = 700 } }, Seed(7, 32, 339, 364, 2))
        Check("procs read state: candidate + other school -> restart (streak 1, the group's school and band)",
            Is(procs[7], 106, 340, 360, 1) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=340-360 streak=1 restart")

        procs, world, lines = Once({ N(106, 5500) }, { { id = 7, total = 5500 } }, Seed(7, 106, 339, 364, 2))
        Check("procs read state: candidate + same school but bands that do not overlap -> restart",
            Is(procs[7], 106, 5500, 5500, 1) and #lines == 1 and lines[1] == "TEACH proc 7 school=106 band=5500-5500 streak=1 restart")

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

    -- One group fitting an open row and a learned-under complement: neither counts ----------------
    do
        local specs = { { id = 7, total = 1000, tally = 600, verdict = "under" }, { id = 8, total = 400 } } -- complement window [400, 400]
        local both = Once({ N(106, 400) }, specs, Seed(7, 106, 330, 360, 3, true))
        Check("procs read unique: a group fitting both the open row 8 and the complement of 7 neither widens 7 nor teaches 8",
            Is(both[7], 106, 330, 360, 3, true) and both[8] == nil)
        local complementOnly = Once({ N(106, 400) }, { specs[1] }, Seed(7, 106, 330, 360, 3, true))
        local openOnly = Once({ N(106, 400) }, { specs[2] }, Seed(7, 106, 330, 360, 3, true))
        Check("procs read unique: with the complement alone 7 widens to 330-400; with the open row alone 8 becomes a candidate (controls)",
            Is(complementOnly[7], 106, 330, 400, 3, true) and Is(openOnly[8], 106, 400, 400, 1) and Is(openOnly[7], 106, 330, 360, 3, true))
    end

    -- Excluded rows: a spell Learn or Fingerprints knows has one owner ---------------------------------
    do
        local function LearnOwns(_, ns)
            CombatTextIconsCharDB.learned[7] = { school = 32, period = 3, kind = "dot", misses = 0 }
            ns.Learn.Init()
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
            shared[7] == nil and Is(shared[8], 106, 400, 400, 1))
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
        Check("procs read exclude: ... while an alias to an unlearned cast leaves the row free (control)", Is(free[8], 106, 400, 400, 1))
    end

    -- Targets' under-loop guards: a complement widens only a proc that has one owner and its own result -------
    do
        local under = { id = 7, total = 5000, tally = 3000, verdict = "under" } -- complement window [2000, 2000]
        local function LearnToo(procs, ns)
            procs[7] = Entry(106, 330, 360, 3, true)
            CombatTextIconsCharDB.learned[7] = { school = 32, period = 3, kind = "dot", misses = 0 }
            ns.Learn.Init()
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
            mixed[1] == nil and Is(mixed[2], 106, 400, 400, 1))
    end

    -- Three reads teach; the store records the last change ----------------------------------------------
    do
        local ns, procs = Rig()
        local function Read(hitList, at)
            local world = World({ { id = 7, total = 700 } })
            ns.Procs.Read(hitList, world.open, world.results, world.rows, at)
        end
        Read({ N(106, 340), N(106, 360) }, 10)
        Read({ N(106, 335), N(106, 365) }, 20)
        Check("procs read chain: after two exact reads the entry is a candidate with streak 2 (Procs.Get gives nil)",
            Is(procs[7], 106, 335, 365, 2) and procs[7].seen == 20 and ns.Procs.Get(7) == nil)
        Read({ N(106, 338), N(106, 362) }, 30)
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
        local procs = Once({ N(106, 400) }, { { id = 5, total = 400 } }, Crowded)
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
end
