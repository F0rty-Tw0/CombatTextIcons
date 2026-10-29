-- Unit checks for the post-fight teacher (matcher v2b-1, Phase 4): tally, session read, verdicts,
-- aliases, learning from "?" hits, TEACH lines and the Core wiring. Called by tests/checks.lua with
-- the same T table. Every scenario boots its own rig; a Boot replaces the global stubs.

return function(T)
    local Check, Secret = T.Check, T.Secret
    local DAMAGE = 0
    local SMITE, MIND_BLAST, WAND, HOLY_FIRE = 591, 8092, 5019, 14914
    local AUTO_SHOT, SWP, GRAVE, BARBED = 75, 594, 1260198, 217200
    local nextSession = 100 -- rig.Judge reads a new session ID each call
    local BALANCE = 999999 -- a meter row nobody drew (Balanced)

    local function Count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

    -- A meter row as the probe saved it (every field the real row carries).
    local function Row(spellID, total, overkill)
        return { spellID = spellID, totalAmount = total, overkillAmount = overkill or 0, amountPerSecond = 0,
            combatSpellDetails = {}, creatureName = "", isAvoidable = false, isDeadly = false }
    end
    -- `rows` plus a BALANCE row for whatever the tally ({ [spellID] = { amount, ... } }) passes them by: rig.Fight
    -- counts every drawn hit as seen, so an over read would be crowded and freeze instead of judge (a solo over among
    -- many rows reads clear: the other rows' damage covers the overshoot).
    local function Balanced(tally, rows)
        local excess = 0
        for _, amounts in pairs(tally) do
            for _, amount in ipairs(amounts) do excess = excess + amount end
        end
        for _, row in ipairs(rows) do excess = excess - row.totalAmount - row.overkillAmount end
        if excess <= 0 then return rows end
        local balanced = { Row(BALANCE, excess) }
        for index, row in ipairs(rows) do balanced[index + 1] = row end

        return balanced
    end
    -- A session as GetAvailableCombatSessions lists it, plus `rows` for the harness stub to serve.
    local function Session(id, rows)
        return { sessionID = id, name = "Dark Neophyte", durationSeconds = 13, rows = rows }
    end
    -- The entry of Teacher.last.rows for a spell, or nil.
    local function Find(last, spellID)
        for _, row in ipairs(last and last.rows or {}) do
            if row.spellID == spellID then return row end
        end
    end

    -- A booted addon. `learned` = { [spellID] = school }: each gets a learned fingerprint (3 samples,
    -- delay 0.25 s). Display.Plate records the texture drawn. `spells` loads the fixture table as ns.Spells.
    local function Rig(learned, spells)
        local rig = { draws = {} }
        rig.ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end, spells)
        local ns, S = rig.ns, T.State()
        rig.S = S
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(_, texture) rig.draws[#rig.draws + 1] = texture end
        for spellID, school in pairs(learned) do
            for castAt = 1, 3 do
                ns.Fingerprints.Add(spellID, { school = school, delay = 0.25, castAt = castAt, hops = 1 })
            end
        end
        function rig.Plate(unit) return C_NamePlate.GetNamePlateForUnit(unit, false) end
        -- A harmful player cast at t with `unit` targeted (nil = no target).
        function rig.Cast(t, unit, spellID)
            S.now, S.target = t, unit
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c" .. t, spellID)
        end
        -- One UNIT_COMBAT WOUND at t (area clear, flag "" unless given); returns the texture drawn, or nil
        -- when nothing was drawn.
        function rig.Hit(t, unit, amount, school, flag)
            S.now = t
            local before = #rig.draws
            ns.Core.UNIT_COMBAT(unit, "WOUND", flag or "", amount, school)
            return #rig.draws > before and rig.draws[#rig.draws] or nil
        end
        -- Teacher fight without Core: tally = { [spellID] = { amount, ... } }, each hit drawn and seen, plus
        -- `seen` more wounds drawn by nothing; the read is queued, not run.
        function rig.Fight(tally, sessions, seen)
            S.sessions = sessions
            ns.Teacher.Start(10)
            for spellID, amounts in pairs(tally) do
                for _, amount in ipairs(amounts) do
                    ns.Teacher.Drawn(spellID, amount)
                    ns.Teacher.Seen(amount)
                end
            end
            if seen then ns.Teacher.Seen(seen) end
            ns.Teacher.Finish(20)
        end
        -- Fires the oldest queued C_Timer.After callback.
        function rig.Fire()
            local timer = table.remove(S.timers, 1)
            if timer then timer.fn() end
        end
        -- Fight + fire; returns whether firing raised no error, and Teacher.last.
        function rig.Read(tally, sessions)
            rig.Fight(tally, sessions)
            local ok = pcall(rig.Fire)
            return ok, ns.Teacher.last
        end
        -- One spell's whole fight against a one-row session; returns that entry's verdict.
        function rig.Judge(spellID, tally, total, overkill)
            nextSession = nextSession + 1
            local amounts = { [spellID] = { tally } }
            local rows = Balanced(amounts, { Row(spellID, total, overkill) })
            local ok, last = rig.Read(amounts, { Session(nextSession, rows) })
            local row = Find(last, spellID)
            return ok and row and row.verdict
        end
        return rig
    end

    do -- queue, newest session, agree, unpaired rows, over / under
        local rig = Rig({ [SMITE] = 2 })
        local S, Teacher, F = rig.S, rig.ns.Teacher, rig.ns.Fingerprints
        local probe = { Session(1, { Row(AUTO_SHOT, 189) }),
            Session(2, { Row(AUTO_SHOT, 87), Row(SWP, 81), Row(GRAVE, 56), Row(SMITE, 53) }) }
        -- 100 seen undrawn (Auto Shot, Touch of the Grave): 234 of the rows' 277 is a clear read, not short
        rig.Fight({ [SMITE] = { 30, 23 }, [SWP] = { 81 } }, probe, 100)
        Check("teacher: Finish queues one read after 1 s and reads nothing before it",
            #S.timers == 1 and S.timers[1].delay == 1 and #S.sourceCalls == 0 and Teacher.last == nil
            and Teacher.fight == nil)
        local ok = pcall(rig.Fire)
        local last, call = Teacher.last, S.sourceCalls[1]
        Check("teacher: reads the highest session ID (2 of [1, 2]) for the player's damage done (a clear read then its heals)",
            ok and last and last.session == 2 and #S.sourceCalls == 2 and call.id == 2 and call.meterType == DAMAGE
            and call.guid == S.guid and S.sourceCalls[2].id == 2 and S.sourceCalls[2].meterType ~= DAMAGE)
        local smite = Find(last, SMITE)
        Check("teacher: Smite 30 + 23 = 53 against the meter's 53 -> agree, one fight, no strikes",
            smite and smite.tally == 53 and smite.meter == 53 and smite.verdict == "agree"
            and F.Get(SMITE).fights == 1 and F.Get(SMITE).strikes == 0)
        Check("teacher: rows nobody drew (Touch of the Grave, Auto Shot) are unpaired and make no fingerprint",
            Find(last, GRAVE).verdict == "unpaired" and Find(last, GRAVE).tally == 0 and Find(last, GRAVE).meter == 56
            and Find(last, AUTO_SHOT).verdict == "unpaired" and F.Get(GRAVE) == nil and F.Get(AUTO_SHOT) == nil)
        Check("teacher: a spell without a fingerprint (Pain 594) gets a verdict but no fingerprint",
            Find(last, SWP).verdict == "agree" and F.Get(SWP) == nil)

        local ok2, last2 = rig.Read({ [SMITE] = { 60 } },
            { Session(4, Balanced({ [SMITE] = { 60 } }, { Row(SMITE, 53) })), Session(3, { Row(SMITE, 999) }) })
        Check("teacher: the highest ID wins whatever the list order ([4, 3] reads 4)", ok2 and last2.session == 4)
        Check("teacher: Smite 60 against 53 (TOL 1, upper 54) -> over: over 1, still one agreed fight",
            Find(last2, SMITE).verdict == "over" and F.Get(SMITE).over == 1 and F.Get(SMITE).fights == 1)
        Check("teacher: Smite 40 against 53 -> under changes nothing",
            rig.Judge(SMITE, 40, 53) == "under" and F.Get(SMITE).over == 1 and F.Get(SMITE).fights == 1)
    end

    do -- agree range: TOL = max(1, 1 %), overkill, strikes
        local rig = Rig({ [MIND_BLAST] = 32, [WAND] = 4, [HOLY_FIRE] = 2 })
        local F = rig.ns.Fingerprints
        Check("teacher: total 1000 -> TOL 10: 1010 and 990 agree, 1011 over, 989 under",
            rig.Judge(MIND_BLAST, 1010, 1000) == "agree" and rig.Judge(MIND_BLAST, 1011, 1000) == "over"
            and rig.Judge(MIND_BLAST, 990, 1000) == "agree" and rig.Judge(MIND_BLAST, 989, 1000) == "under")
        Check("teacher: overkill 100 widens the top: 1110 agrees, 1111 is over",
            rig.Judge(MIND_BLAST, 1110, 1000, 100) == "agree" and rig.Judge(MIND_BLAST, 1111, 1000, 100) == "over")
        Check("teacher: Mind Blast after 3 agrees and 2 non-consecutive overs: fights 3, over 2, entry kept",
            F.Get(MIND_BLAST) and F.Get(MIND_BLAST).fights == 3 and F.Get(MIND_BLAST).over == 2)
        rig.Judge(WAND, 100, 87) -- TOL 1, upper 88 -> over
        local afterOne = F.Get(WAND) ~= nil
        rig.Judge(WAND, 100, 87)
        Check("teacher: one over keeps the entry, 2 overs in a row delete it", afterOne and F.Get(WAND) == nil)
        rig.Judge(HOLY_FIRE, 100, 87)
        rig.Judge(HOLY_FIRE, 87, 87) -- agree resets the strikes
        rig.Judge(HOLY_FIRE, 100, 87)
        local kept = F.Get(HOLY_FIRE) ~= nil
        rig.Judge(HOLY_FIRE, 100, 87)
        Check("teacher: over, agree, over keeps the entry; the next over deletes it", kept and F.Get(HOLY_FIRE) == nil)
    end

    do -- skipped reads never touch the fingerprints (Review Focus 4)
        local rig = Rig({ [SMITE] = 2 })
        local S, Teacher, F = rig.S, rig.ns.Teacher, rig.ns.Fingerprints
        local good = { Session(1, { Row(SMITE, 53) }) }
        local function Skip(flags, sessions)
            S.sessionsFail, S.sourceFail = flags.sessions, flags.source
            local ok, last = rig.Read({ [SMITE] = { 53 } }, sessions or good)
            S.sessionsFail, S.sourceFail = nil, nil
            return ok, last and last.skip
        end
        local ok1, r1 = Skip({ sessions = "error" })
        rig.ns.Meter.Init() -- a read error switched the meter off; the next fight needs it back on
        local ok2, r2 = Skip({ source = "error" })
        Check("teacher: a failing sessions or source call skips the fight ('read failed') without error",
            ok1 and ok2 and r1 == "read failed" and r2 == "read failed")
        local lines, errorText = 0, false
        for _, line in ipairs(S.prints) do
            if line:find("damage meter unavailable", 1, true) then
                lines = lines + 1
                errorText = line:find("sessions broke", 1, true) ~= nil
            end
        end
        Check("stamp: two read errors print one chat line and leave the meter off",
            lines == 1 and not rig.ns.Meter.Available())
        Check("teacher: the chat line of a read error carries the error text", errorText)
        local timersBefore = #S.timers
        rig.Fight({ [SMITE] = { 53 } }, good)
        Check("stamp: no read is queued while the meter is off", #S.timers == timersBefore)
        Check("teacher: Finish with the meter off reports the skip ('meter off')",
            rig.ns.Teacher.last ~= nil and rig.ns.Teacher.last.skip == "meter off")
        rig.ns.Meter.Init() -- the secret checks below need the meter back on
        local ok3, r3 = Skip({ sessions = "secret" })
        local ok4, r4 = Skip({ source = "secret" })
        local ok5, r5 = Skip({}, { Session(1, { Row(SMITE, Secret(53)) }) })
        local ok6, r6 = Skip({}, { Session(1, { Row(Secret(SMITE), 53) }) })
        Check("teacher: a secret sessions list, source, row amount or row spell ID skips ('secret') without error",
            ok3 and ok4 and ok5 and ok6 and r3 == "secret" and r4 == "secret" and r5 == "secret" and r6 == "secret")
        local ok7, r7 = Skip({}, {})
        Check("teacher: no session at all skips ('no sessions')", ok7 and r7 == "no sessions")
        Check("teacher: no skipped read changed the fingerprint",
            F.Get(SMITE).fights == 0 and F.Get(SMITE).over == 0 and F.Get(SMITE).strikes == 0)

        local okA, lastA = rig.Read({ [SMITE] = { 53 } }, good)
        local okB, lastB = rig.Read({ [SMITE] = { 53 } }, good)
        Check("teacher: the same newest session twice is read once ('duplicate session'), fights counted once",
            okA and okB and lastA.session == 1 and lastB.skip == "duplicate session" and F.Get(SMITE).fights == 1)

        do -- a re-pull inside the meter's session (probe6 fights 3-4): the same session grew; only the growth is judged
            local again = Rig({ [SMITE] = 2 })
            again.Read({ [SMITE] = { 53 } }, { Session(7, { Row(SMITE, 53), Row(GRAVE, 20) }) })
            local okG, grown = again.Read({ [SMITE] = { 40 } }, { Session(7, { Row(SMITE, 93), Row(GRAVE, 20) }) })
            local smite = Find(grown, SMITE)
            Check("teacher: the same session read again judges what it grew: Smite 93 - 53 = 40 agrees, Grave (no growth) is no row",
                okG and grown.session == 7 and smite and smite.meter == 40 and smite.verdict == "agree"
                and Find(grown, GRAVE) == nil and again.ns.Fingerprints.Get(SMITE).fights == 2 and grown.area == "clear")
        end

        do -- leftover ticks re-enter combat for a moment: the meter starts no session, so that fight is not saved
            local tiny = Rig({})
            local L = tiny.ns.Ledger
            local function Saved(at, amount)
                L.Start(at)
                L.Add("damage", "?32", amount)
                L.Finish(at + 0.7)
            end
            Saved(1, 500000)
            tiny.Read({}, good)
            Saved(10, 1377) -- the rig's Teacher fight starts at 10
            tiny.Read({}, good)
            local fights = L.Fights()
            Check("teacher: a fight the meter gives no new session ('duplicate session') is dropped from the saved fights",
                #fights == 1 and fights[1].at == 1)
            Saved(10, 1377)
            tiny.Read({}, { Session(2, { Row(SMITE, 53) }) })
            Check("teacher: a fight with a new session stays saved (control)", #L.Fights() == 2 and L.Fights()[1].at == 10)
        end

        Teacher.Finish(5)
        Check("teacher: Finish with no fight started queues nothing ('no fight')",
            #S.timers == 0 and Teacher.last and Teacher.last.skip == "no fight")
    end

    do -- quick re-pull (run 102226Z): the read meets the next fight ('secret'); the game folds both into one session
        local rig = Rig({ [SMITE] = 2 })
        local S, Teacher, F = rig.S, rig.ns.Teacher, rig.ns.Fingerprints
        local calls = 0
        Teacher.OnRead = function() calls = calls + 1 end
        Teacher.Start(10)
        Teacher.Drawn(SMITE, 30)
        Teacher.Seen(30)
        Teacher.Unknown("plate", 32, 100, 15, nil, "")
        Teacher.Finish(20)
        Teacher.Start(20.4) -- pulled again before the read
        Teacher.Unknown("plate", 32, 200, 21, nil, "")
        S.sessionsFail = "secret"
        rig.Fire()
        S.sessionsFail = nil
        local fight = Teacher.fight
        Check("teacher: a read that meets the next fight carries its tally, seen and '?' hits (oldest first) into it",
            calls == 0 and fight and fight.at == 20.4 and fight.tally[SMITE] == 30 and fight.seen == 30
            and #fight.unknown == 2 and fight.unknown[1].at == 15 and fight.unknown[2].at == 21)
        Teacher.Drawn(SMITE, 23)
        Teacher.Seen(23)
        Teacher.Finish(25)
        S.sessions = { Session(1, { Row(SMITE, 53) }) }
        rig.Fire()
        local smite = Find(Teacher.last, SMITE)
        Check("teacher: the next read judges both fights against the one session: Smite 30 + 23 agrees with 53, area clear",
            calls == 1 and smite and smite.tally == 53 and smite.verdict == "agree" and F.Get(SMITE).fights == 1
            and Teacher.last.area == "clear")

        do -- the fights' stream records ride the carry too
            local carry = Rig({ [SMITE] = 2 })
            local CT, CS = carry.ns.Teacher, carry.S
            local function Repull(first, second)
                CT.Start(10)
                CT.fight.streams = first
                CT.Finish(20)
                CT.Start(20.4)
                CT.fight.streams = second
                CS.sessionsFail = "secret"
                carry.Fire()
                CS.sessionsFail = nil
                return CT.fight.streams
            end
            local S1, S2 = {}, {}
            local merged = Repull({ [S1] = { school = 32, sum = 100, n = 1, lo = 100, hi = 100 }, [S2] = { school = 32, sum = 50, n = 2, lo = 20, hi = 30 } },
                { [S1] = { school = 32, sum = 200, n = 2, lo = 90, hi = 110 } })
            local both, only = merged[S1], merged[S2]
            Check("teacher: a carry adds a shared stream's sum and n and widens lo/hi (300, 3, 90..110)",
                both and both.sum == 300 and both.n == 3 and both.lo == 90 and both.hi == 110)
            Check("teacher: a carry copies a stream only the earlier fight had", only and only.sum == 50 and only.n == 2 and only.lo == 20)
            local ok, bare = pcall(Repull, { [S1] = { school = 32, sum = 100, n = 1 } }, nil)
            Check("teacher: a carry into a fight whose streams are nil does not error and copies the record",
                ok and bare and bare[S1] and bare[S1].sum == 100)
        end
    end

    do -- tally and unknown hits
        local rig = Rig({ [SMITE] = 2 }, true)
        local Teacher = rig.ns.Teacher
        local P1 = rig.Plate("nameplate1")
        local outside = pcall(function() Teacher.Drawn(SMITE, 5) Teacher.Unknown(P1, 32, 5, 1) Teacher.Finish(2) end)
        Check("teacher: Drawn and Unknown outside a fight are ignored without error", outside and Teacher.fight == nil)

        Teacher.Start(10)
        Teacher.Drawn(SMITE, 30)
        Teacher.Drawn(SMITE, 23)
        Check("teacher: Drawn adds amounts per spell ID (30 + 23 = 53)", Teacher.fight.tally[SMITE] == 53)
        local ok = pcall(function()
            Teacher.Drawn(Secret(SMITE), 5)
            Teacher.Drawn(SMITE, Secret(5))
            Teacher.Drawn("x", 5)
            Teacher.Drawn(SMITE, "x")
        end)
        Check("teacher: a secret or non-number spell ID or amount is ignored without error (Review Focus 4)",
            ok and Teacher.fight.tally[SMITE] == 53 and Count(Teacher.fight.tally) == 1)

        local SoleCast = rig.ns.Casts.SoleCast -- Core finds the cast at hit time and passes it
        rig.Cast(60, "nameplate1", MIND_BLAST)
        Teacher.Unknown(P1, 32, 120, 60.25, SoleCast(P1, 60.25))
        local entry = Teacher.fight.unknown[1]
        Check("teacher: Unknown keeps {school, amount, at, plate} and the lone unlearned cast as castID / castAt",
            entry and entry.school == 32 and entry.amount == 120 and entry.at == 60.25 and entry.plate == P1
            and entry.castID == MIND_BLAST and entry.castAt == 60)
        rig.Cast(70, "nameplate1", SMITE)
        Teacher.Unknown(P1, 2, 53, 70.25, SoleCast(P1, 70.25))
        rig.Cast(80, "nameplate1", 980) -- Curse of Agony, a tracker spell
        Teacher.Unknown(P1, 32, 5, 80.25, SoleCast(P1, 80.25))
        Teacher.Unknown(P1, 32, 70, 90, SoleCast(P1, 90)) -- no cast in the last 1.5 s
        local unknown = Teacher.fight.unknown
        Check("teacher: Unknown gives castID nil for a learned cast, a tracker cast and no cast",
            #unknown == 4 and unknown[2].castID == nil and unknown[3].castID == nil and unknown[4].castID == nil)
        local okSecret = pcall(function()
            Teacher.Unknown(P1, Secret(32), 5, 91)
            Teacher.Unknown(P1, 32, Secret(5), 91)
        end)
        Check("teacher: a secret school or amount into Unknown is not stored and does not error",
            okSecret and #Teacher.fight.unknown == 4)
    end

    do -- run 20261025T192458Z F2: Lightning Bolt's whole group held 15 Surging Totem ticks (~11K among ~55K bolts)
       -- and summed within 1 % of its row, so its fingerprint learned the totem's size and drew its ticks
        local BOLT = 188196
        local rig = Rig({})
        local Teacher, SoleCast, P1 = rig.ns.Teacher, rig.ns.Casts.SoleCast, rig.Plate("nameplate1")
        rig.S.sessions = { Session(1, { Row(BOLT, 198000) }) }
        Teacher.Start(5)
        for castAt = 10, 30, 10 do
            rig.Cast(castAt, "nameplate1", BOLT)
            for _, hit in ipairs({ { 0.45, 55000 }, { 0.9, 11000 } }) do
                local at = castAt + hit[1]
                Teacher.Seen(hit[2])
                Teacher.Unknown(P1, 8, hit[2], at, SoleCast(P1, at), "")
            end
        end
        Teacher.Finish(40)
        rig.Fire()
        local small = false
        for _, sample in ipairs((rig.ns.Fingerprints.Get(BOLT) or { samples = {} }).samples) do
            small = small or (sample.size or 0) < 20000
        end
        Check("teacher mixed: a whole sum mixing sizes more than a crit apart (11K, 55K) never pairs, so no 11K sample",
            Teacher.last.area == "clear" and not small and Find(Teacher.last, BOLT).verdict ~= "agree")
    end

    do -- ele log F3: Lightning Bolt 188196's row held each bolt and its Elemental Overload on the bolt's plate
       -- (63230 + 28817 + 64483 + 26106 + 25821 = 208457): the proven way teaches 2 hits a cast (sizes here within
       -- CRIT_LO of each other, so the whole group may pair)
        local BOLT = 188196
        local rig = Rig({})
        local Teacher, SoleCast, P1 = rig.ns.Teacher, rig.ns.Casts.SoleCast, rig.Plate("nameplate1")
        rig.S.sessions = { Session(1, { Row(BOLT, 3 * (60000 + 40000)) }) }
        Teacher.Start(5)
        for castAt = 10, 30, 10 do
            rig.Cast(castAt, "nameplate1", BOLT)
            for _, hit in ipairs({ { 0.45, 60000 }, { 0.6, 40000 } }) do
                local at = castAt + hit[1]
                Teacher.Seen(hit[2])
                Teacher.Unknown(P1, 8, hit[2], at, SoleCast(P1, at), "")
            end
        end
        Teacher.Finish(40)
        rig.Fire()
        local fp = rig.ns.Fingerprints.Get(BOLT)
        Check("teacher per cast: a proven way with a bolt and its overload on each cast's plate teaches 2 hits a cast",
            fp ~= nil and fp.learned and fp.perCast == 2)
    end

    do -- alias pairing and the new-alias rule (teacher read driven directly)
        local rig = Rig({ [WAND] = 4 })
        local F = rig.ns.Fingerprints
        F.SetAlias(AUTO_SHOT, WAND)
        local ok, last = rig.Read({ [WAND] = { 120 } }, { Session(1, Balanced({ [WAND] = { 120 } }, { Row(AUTO_SHOT, 100) })) })
        local row = Find(last, WAND)
        Check("teacher alias: row 75 pairs with the cast spell 5019 through a saved alias (120 > 100 + TOL 1 -> over)",
            ok and row and row.verdict == "over" and row.meterID == AUTO_SHOT and row.meter == 100 and F.Get(WAND).over == 1)

        rig = Rig({ [WAND] = 4 })
        F = rig.ns.Fingerprints
        ok, last = rig.Read({ [WAND] = { 87 } }, { Session(1, { Row(AUTO_SHOT, 87), Row(GRAVE, 56) }) })
        Check("teacher alias: one unpaired tally and the one agreeing unpaired row make alias 75 -> 5019 (Touch of the Grave ignored)",
            ok and Find(last, WAND).verdict == "agree" and F.Alias(AUTO_SHOT) == WAND and F.Get(WAND).fights == 1
            and Find(last, GRAVE).verdict == "unpaired")

        rig = Rig({ [WAND] = 4 })
        F = rig.ns.Fingerprints
        ok, last = rig.Read({ [WAND] = { 87 } }, { Session(1, { Row(AUTO_SHOT, 87), Row(76, 87) }) })
        Check("teacher alias: two rows agreeing with the one tally make no alias and no verdict",
            ok and F.Alias(AUTO_SHOT) == nil and F.Alias(76) == nil and Find(last, WAND).verdict == "unpaired"
            and F.Get(WAND).fights == 0)

        rig = Rig({ [WAND] = 4 })
        F = rig.ns.Fingerprints
        ok, last = rig.Read({ [WAND] = { 87 } }, { Session(1, { Row(AUTO_SHOT, 200) }) })
        Check("teacher alias: a row that disagrees with the tally makes no alias and strikes nothing",
            ok and F.Alias(AUTO_SHOT) == nil and F.Get(WAND).fights == 0 and F.Get(WAND).over == 0
            and Find(last, WAND).verdict == "unpaired")
    end

    -- A whole fight through Core: two Smites (learned), a Barbed Shot tick (tracker), three Mind
    -- Blasts and three wand shots (unlearned -> "?"), then the read of a session whose Mind Blast row is
    -- `mbRow`. /cti debug is on so the TEACH lines land in CombatTextIconsDB.debugLog.
    local function Pull(mbRow)
        local rig = Rig({ [SMITE] = 2 }, true)
        local S, Core = rig.S, rig.ns.Core
        SlashCmdList.COMBATTEXTICONS("debug")
        S.now = 9
        Core.PLAYER_REGEN_DISABLED()
        local seen = { mb = {}, wand = {} }
        rig.Cast(10, "nameplate7", SMITE); seen.smite1 = rig.Hit(10.25, "nameplate7", 30, 2)
        rig.Cast(20, "nameplate8", SMITE); seen.smite2 = rig.Hit(20.25, "nameplate8", 23, 2)
        rig.Cast(50, "nameplate2", BARBED); seen.tick = rig.Hit(52, "nameplate2", 800, 1)
        for index, amount in ipairs({ 120, 135, 98 }) do
            local unit, t = ({ "nameplate1", "nameplate3", "nameplate4" })[index], 50 + index * 10
            rig.Cast(t, unit, MIND_BLAST)
            seen.mb[index] = rig.Hit(t + 0.25, unit, amount, 32)
        end
        for index, amount in ipairs({ 20, 31, 36 }) do
            local unit, t = ({ "nameplate5", "nameplate6", "nameplate9" })[index], 80 + index * 10
            rig.Cast(t, unit, WAND)
            seen.wand[index] = rig.Hit(t + 0.5, unit, amount, 4)
        end
        S.now = 130
        Core.PLAYER_REGEN_ENABLED()
        S.sessions = { Session(1, { Row(AUTO_SHOT, 87), Row(MIND_BLAST, mbRow), Row(GRAVE, 56), Row(SMITE, 53),
            Row(BARBED, 800) }) }
        seen.queued = #S.timers
        pcall(rig.Fire)
        return rig, seen
    end
    local function Logged(text)
        for _, line in ipairs(CombatTextIconsDB.debugLog) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    -- Procs store seeded with one entry: a learned proc (streak 3) or a candidate (streak 2), school 106, band 339-364.
    local function SeedProc(rig, id, learned)
        T.Store().procs = { [id] = { school = 106, lo = 339, hi = 364, streak = learned and 3 or 2,
            learned = learned, unpaired = 0, seen = 0 } }
        rig.ns.Procs.Init(T.Store())
    end

    do -- the whole loop through Core
        local rig, seen = Pull(353)
        local ns, S = rig.ns, rig.S
        local F, Teacher = ns.Fingerprints, ns.Teacher
        local last = Teacher.last
        Check("teacher wiring: the fight queues one read; Smite and the tracker tick draw their icons, unlearned hits draw '?'",
            seen.queued == 1 and seen.smite1 == "tex:591" and seen.smite2 == "tex:591" and seen.tick == "tex:217200"
            and seen.mb[1] == ns.Meter.UNKNOWN_ICON and seen.mb[3] == ns.Meter.UNKNOWN_ICON
            and seen.wand[1] == ns.Meter.UNKNOWN_ICON and seen.wand[3] == ns.Meter.UNKNOWN_ICON)
        Check("teacher wiring: Smite 30 + 23 = 53 agrees (one fight); the tracker tick 800 agrees and makes no fingerprint",
            Find(last, SMITE).verdict == "agree" and F.Get(SMITE).fights == 1
            and Find(last, BARBED).verdict == "agree" and F.Get(BARBED) == nil)
        Check("teacher learn: three Mind Blast '?' hits (120 + 135 + 98 = 353) match the 353 row -> learned, school 32, delay 0.25",
            F.IsLearned(MIND_BLAST) and F.Get(MIND_BLAST).school == 32 and F.Get(MIND_BLAST).delayLo == 0.25
            and F.Get(MIND_BLAST).delayHi == 0.25 and last.learned[MIND_BLAST] == 3 and F.Alias(MIND_BLAST) == nil)
        Check("teacher learn: each sample keeps the spell cast (Mind Blast), for its own window",
            F.Get(MIND_BLAST).samples[1].spell == MIND_BLAST and F.Get(MIND_BLAST).samples[3].spell == MIND_BLAST)
        Check("teacher learn: three wand '?' hits (20 + 31 + 36 = 87) match Auto Shot 87 -> Shoot 5019 learned, delay 0.5, alias 75 -> 5019",
            F.IsLearned(WAND) and F.Get(WAND).school == 4 and F.Get(WAND).delayLo == 0.5 and F.Get(WAND).delayHi == 0.5
            and F.Alias(AUTO_SHOT) == WAND and last.learned[WAND] == 3)
        Check("teacher TEACH: one line per spell with tally, meter and verdict",
            Logged("TEACH 591 tally=53 meter=53 verdict=agree") and Logged("TEACH 217200 tally=800 meter=800 verdict=agree")
            and Logged("TEACH 1260198 tally=0 meter=56 verdict=unpaired")
            and Logged("TEACH 8092 tally=353 meter=353 verdict=agree") and Logged("TEACH 5019 tally=87 meter=87 verdict=agree"))
        Check("teacher TEACH: a row paired under another ID names its meter row (row=75); a spell's own row does not",
            Logged("TEACH 5019 tally=87 meter=87 verdict=agree row=75") and not Logged("verdict=agree row=8092"))

        ns.Teacher.Start(300)
        ns.Teacher.Finish(301)
        pcall(rig.Fire)
        Check("teacher TEACH: a second fight reading the same newest session is skipped and logged",
            Teacher.last.skip == "duplicate session" and Logged("TEACH skip duplicate session"))

        S.now = 199
        ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(200, "nameplate5", WAND)
        local drawn = rig.Hit(200.5, "nameplate5", 30, 4)
        Check("teacher learn: the wand learned from '?' hits now draws its own icon and is tallied",
            drawn == "tex:5019" and Teacher.fight.tally[WAND] == 30)
        Check("teacher learn: samples learned from '?' hits keep the hit size",
            F.Get(MIND_BLAST).samples[1].size == 120 and F.Get(MIND_BLAST).samples[3].size == 98
            and F.Get(WAND).samples[1].size == 20)
    end

    do -- Teacher.Unknown keeps the hit's normal-scale size
        local rig = Rig({})
        local ns = rig.ns
        local cast = { base = MIND_BLAST, at = 10, spellID = MIND_BLAST }
        ns.Teacher.Start(10)
        ns.Teacher.Unknown(rig.Plate("nameplate1"), 32, 40000, 10.2, cast, "CRITICAL")
        ns.Teacher.Unknown(rig.Plate("nameplate1"), 32, 40000, 10.3, cast)
        ns.Teacher.Unknown(rig.Plate("nameplate1"), 32, 0, 10.4, cast, "")
        local unknown = ns.Teacher.fight.unknown
        Check("teacher size: a crit '?' hit keeps its normal-scale size; no flag keeps none; a 0 hit is not kept",
            unknown[1].size == 20000 and unknown[2].size == nil and #unknown == 2)
    end

    -- Short real-mob fights: each kill takes one Mind Blast, the meter row carries overkill. Returns
    -- the texture each hit drew.
    local function ShortFight(rig, t, session, hits, total, overkill)
        local S, Core = rig.S, rig.ns.Core
        S.now = t - 1
        Core.PLAYER_REGEN_DISABLED()
        rig.Cast(t, "nameplate1", MIND_BLAST)
        local drawn = {}
        for index, hit in ipairs(hits) do drawn[index] = rig.Hit(t + 0.2, "nameplate1", hit[1], 32, hit[2]) end
        S.now = t + 5
        Core.PLAYER_REGEN_ENABLED()
        S.sessions = { Session(session, { Row(MIND_BLAST, total, overkill) }) }
        pcall(rig.Fire)
        return drawn
    end

    do -- short fights add to learning (memory cti-short-fights)
        local rig = Rig({}, true)
        local F = rig.ns.Fingerprints
        ShortFight(rig, 100, 301, { { 19000 } }, 19000, 4000)
        ShortFight(rig, 200, 302, { { 40000, "CRITICAL" } }, 40000, 6000)
        local entry = F.Get(MIND_BLAST)
        Check("teacher short fights: two one-cast kills add sized samples (crit at normal scale) and strike nothing",
            entry and not entry.learned and #entry.samples == 2 and entry.samples[1].size == 19000
            and entry.samples[2].size == 20000 and entry.over == 0)
        ShortFight(rig, 300, 303, { { 21000 } }, 21000, 3000)
        local low, high = F.Band(MIND_BLAST, MIND_BLAST)
        Check("teacher short fights: the third kill teaches Mind Blast with band 19000-21000",
            F.IsLearned(MIND_BLAST) and low == 19000 and high == 21000)
        local drawn = ShortFight(rig, 400, 304, { { 900 }, { 22000 } }, 22900, 0)
        Check("teacher short fights: then a 900 tick in its window is not Mind Blast, the 22000 hit is",
            drawn[1] ~= "tex:8092" and drawn[2] == "tex:8092")
    end

    do -- pet damage is the player's own (2026-10-28): the meter lists the pet's spells among the player's rows
        local BITE = 54049 -- Shadow Bite: the pet's cast and its hit share a frame (lock3)
        -- One kill by the pet: its cast at t on the player's target, its hit at t; the session holds the pet's row.
        local function PetKill(rig, t, session, amount)
            local S, Core = rig.S, rig.ns.Core
            S.now = t - 1
            Core.PLAYER_REGEN_DISABLED()
            S.now, S.target = t, "nameplate1"
            Core.UNIT_SPELLCAST_SUCCEEDED("pet", "p" .. t, BITE)
            local drawn = rig.Hit(t, "nameplate1", amount, 32)
            S.now = t + 5
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(session, { Row(BITE, amount) }) }
            pcall(rig.Fire)
            return drawn
        end
        local function Taught(petTarget)
            local rig = Rig({})
            for index = 1, 3 do PetKill(rig, 100 * index, 600 + index, 3000 + 50 * index) end
            rig.S.petTarget = petTarget
            return rig, PetKill(rig, 400, 604, 3100)
        end
        local rig, drawn = Taught(true)
        Check("teacher pet: three one-cast pet kills teach the pet's spell; its next hit draws the pet spell's icon",
            rig.ns.Fingerprints.IsLearned(BITE) and drawn == "tex:" .. BITE)
        rig, drawn = Taught(false)
        Check("teacher pet: a pet cast while the pet attacks another mob than the target names no hit on the target",
            rig.ns.Fingerprints.IsLearned(BITE) and drawn ~= "tex:" .. BITE)

        -- A pet cast between the player's cast start and its finish keeps the start's plate (run 134732Z's retarget).
        rig = Rig({ [MIND_BLAST] = 32 })
        local S, Core = rig.S, rig.ns.Core
        S.now, S.target = 30, "nameplate4"
        Core.UNIT_SPELLCAST_START("player", "g1", MIND_BLAST)
        S.now = 30.5
        Core.UNIT_SPELLCAST_SUCCEEDED("pet", "p30", BITE)
        S.now, S.target = 31.5, "nameplate6"
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "g1", MIND_BLAST)
        Check("teacher pet: a pet cast mid-cast does not take the player's cast start",
            rig.Hit(31.75, "nameplate4", 20000, 32) == "tex:" .. MIND_BLAST)
    end

    do -- a learned spell's killing blow: tally above the meter total, within its overkill
        local rig = Rig({})
        local F = rig.ns.Fingerprints
        for castAt, size in ipairs({ 18000, 21000, 25000 }) do
            F.Add(MIND_BLAST, { school = 32, delay = 0.2, castAt = castAt, hops = 1, spell = MIND_BLAST, size = size })
        end
        local drawn = ShortFight(rig, 10, 501, { { 25000 } }, 20000, 5000)
        Check("teacher short fights: a killing blow (25000 drawn, meter 20000 + 5000 overkill) agrees and strikes nothing",
            drawn[1] == "tex:8092" and Find(rig.ns.Teacher.last, MIND_BLAST).verdict == "agree"
            and F.Get(MIND_BLAST).fights == 1 and F.Get(MIND_BLAST).strikes == 0)
    end

    do -- short fights whose hit shares its frame with another cast learn through the candidates (run lock F1)
        local OTHER = 1234567
        local rig = Rig({}, true)
        local F, S, Core = rig.ns.Fingerprints, rig.S, rig.ns.Core
        -- One kill: Mind Blast at t, another harmful cast at t + 0.1 on the same plate (so the hit has no sole cast),
        -- Mind Blast's hit at t + 0.2; the session holds Mind Blast's row with `overkill`.
        local function SharedKill(t, session, amount, flag, total, overkill)
            S.now = t - 1
            Core.PLAYER_REGEN_DISABLED()
            rig.Cast(t, "nameplate1", MIND_BLAST)
            rig.Cast(t + 0.1, "nameplate1", OTHER)
            rig.Hit(t + 0.2, "nameplate1", amount, 32, flag)
            S.now = t + 5
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(session, { Row(MIND_BLAST, total, overkill) }) }
            pcall(rig.Fire)
        end
        SharedKill(100, 601, 19000, nil, 19000, 4000)
        SharedKill(200, 602, 40000, "CRITICAL", 40000, 6000)
        local entry = F.Get(MIND_BLAST)
        Check("teacher short fights, shared frame: two one-cast kills add sized samples at 0.2 s under Mind Blast, none for the other cast",
            entry and not entry.learned and #entry.samples == 2 and entry.samples[2].size == 20000
            and math.abs(entry.samples[1].delay - 0.2) < 1e-6 and entry.samples[1].spell == MIND_BLAST and F.Get(OTHER) == nil
            and entry.over == 0)
        SharedKill(300, 603, 25000, nil, 20000, 5000)
        local low, high = F.Band(MIND_BLAST, MIND_BLAST)
        Check("teacher short fights, shared frame: a killing blow (25000 on screen, meter 20000 + 5000 overkill) teaches Mind Blast",
            F.IsLearned(MIND_BLAST) and low == 19000 and high == 25000 and F.Get(OTHER) == nil)
        local drawn = ShortFight(rig, 400, 604, { { 22000 } }, 22000, 0)
        Check("teacher short fights, shared frame: a later lone kill's hit draws Mind Blast and agrees",
            drawn[1] == "tex:8092" and Find(rig.ns.Teacher.last, MIND_BLAST).verdict == "agree")
    end

    do -- a rowless cast after a learned spell leaves its killing blow to it (run shaman4 F2, Totemic Projection 108287)
        local OTHER = 1234567
        local rig = Rig({})
        local F, S, Core = rig.ns.Fingerprints, rig.S, rig.ns.Core
        for castAt, size in ipairs({ 18000, 21000, 25000 }) do
            F.Add(MIND_BLAST, { school = 32, delay = 0.2, castAt = castAt, hops = 1, spell = MIND_BLAST, size = size })
        end
        -- One short fight: Mind Blast at t (unless `alone`), OTHER at t + 0.1, Mind Blast's 25000 killing blow at t + 0.2;
        -- the session holds Mind Blast's row 20000 + 5000 overkill (`alone`: a Smite row only). Returns the hit's texture.
        local function Kill(t, session, alone)
            S.now = t - 1
            Core.PLAYER_REGEN_DISABLED()
            if not alone then rig.Cast(t, "nameplate1", MIND_BLAST) end
            rig.Cast(t + 0.1, "nameplate1", OTHER)
            local drawn = not alone and rig.Hit(t + 0.2, "nameplate1", 25000, 32) or nil
            S.now = t + 5
            Core.PLAYER_REGEN_ENABLED()
            local row = alone and Row(SMITE, 1000) or Row(MIND_BLAST, 20000, 5000)
            S.sessions = { Session(session, { row }) }
            pcall(rig.Fire)
            return drawn
        end
        local before = Kill(100, 701)
        Kill(200, 702, true)
        local drawn = Kill(300, 703)
        Check("teacher short fights: OTHER spoils Mind Blast's killing blow until a read shows OTHER rowless, then it draws Mind Blast and agrees",
            before ~= "tex:8092" and rig.ns.Learn.Rowless(OTHER) and drawn == "tex:8092"
            and Find(rig.ns.Teacher.last, MIND_BLAST).verdict == "agree")
    end

    do -- a sum that does not match the row teaches nothing
        local rig = Pull(300)
        local F = rig.ns.Fingerprints
        Check("teacher learn: Mind Blast hits summing to 353 against a 300 row (room 303) learn nothing; the wand still does",
            not F.IsLearned(MIND_BLAST) and F.Get(MIND_BLAST) == nil and F.IsLearned(WAND) and F.Alias(AUTO_SHOT) == WAND)
    end

    do -- group: the learned match draws and is tallied (spec C1); the unexplained hit stays hidden
        local rig = Rig({ [SMITE] = 2 })
        local Teacher = rig.ns.Teacher
        rig.S.now = 9
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.S.group = true
        rig.Cast(10, "nameplate7", SMITE)
        local smite = rig.Hit(10.25, "nameplate7", 53, 2)
        rig.Cast(20, "nameplate1", MIND_BLAST)
        local blast = rig.Hit(20.25, "nameplate1", 120, 32)
        Check("teacher wiring: in a group the learned match draws and is tallied; the unknown hit stays hidden and is not counted",
            smite == "tex:" .. SMITE and blast == nil and Teacher.fight.tally[SMITE] == 53 and #Teacher.fight.unknown == 0)
    end

    do -- the crowd check (spec 4.3): seen against the meter's rows decides clear / crowded; groups keep the state
        local fresh = T.Boot() -- not the rig: Rig sets area = "clear"
        Check("crowd: a fresh boot is unknown: procs may draw, '?' may not",
            fresh.Teacher.area == "unknown" and fresh.Teacher.NotCrowded() and not fresh.Teacher.AreaClear())

        -- One Mind Blast '?' hit of `amount` after a lone cast at t 10, handed to the open fight.
        local function Unknown(rig, amount)
            rig.Cast(10, "nameplate1", MIND_BLAST)
            local plate = rig.Plate("nameplate1")
            rig.ns.Teacher.Unknown(plate, 32, amount, 10.25, rig.ns.Casts.SoleCast(plate, 10.25))
        end

        -- A fight on a rig that starts in `area`: Smite drawn 53, a Mind Blast '?' hit of 120, `seen` summed
        -- by Seen; the session holds a Smite 53 row and a Mind Blast 120 row. `group` is the Start argument,
        -- `grouped` the IsInGroup answer at read time. Returns the rig, whether the read raised no error,
        -- Teacher.last and whether the Mind Blast '?' hit was learned (one sample; a fingerprint needs three).
        local function Crowd(area, seen, group, grouped, prep)
            local rig = Rig({ [SMITE] = 2 }, true)
            local S, Teacher = rig.S, rig.ns.Teacher
            Teacher.area = area
            if prep then prep(rig) end
            S.sessions = { Session(1, { Row(SMITE, 53), Row(MIND_BLAST, 120) }) }
            Teacher.Start(9, group)
            Teacher.Drawn(SMITE, 53)
            Unknown(rig, 120)
            Teacher.Seen(seen)
            Teacher.Finish(20)
            S.group = grouped or false
            local ok = pcall(rig.Fire)

            return rig, ok, Teacher.last, Teacher.last.learned ~= nil and Teacher.last.learned[MIND_BLAST] == 1
        end

        -- One Smite row of `total` (and `overkill`, default 0) against the same drawn and `seen`;
        -- returns Teacher.last.area.
        local function AreaAt(seen, total, overkill)
            local rig = Rig({ [SMITE] = 2 })
            local Teacher = rig.ns.Teacher
            rig.S.sessions = { Session(1, { Row(SMITE, total, overkill) }) }
            Teacher.Start(10)
            Teacher.Drawn(SMITE, total)
            Teacher.Seen(seen)
            Teacher.Finish(20)
            pcall(rig.Fire)

            return Teacher.last.area
        end

        -- seen 53 vs one row 53 -> clear; the '?' group (53) agrees with the unpaired Mind Blast row
        do
            local rig = Rig({}, true)
            local Teacher = rig.ns.Teacher
            rig.S.sessions = { Session(1, { Row(MIND_BLAST, 53) }) }
            Teacher.Start(9)
            Unknown(rig, 53)
            Teacher.Seen(53)
            Teacher.Finish(20)
            pcall(rig.Fire)
            Check("crowd: a solo read whose seen fits the meter turns clear and learns",
                Teacher.last.area == "clear" and Teacher.area == "clear" and Teacher.last.learned[MIND_BLAST] == 1)
        end

        Check("crowd: seen = total + overkill + 1 % is still clear", AreaAt(1010, 1000) == "clear")
        Check("crowd: one more than the tolerance is crowded", AreaAt(1011, 1000) == "crowded")
        -- overkill is damage the meter holds that the plate may show: row 1000 + overkill 50, tolerance 10
        Check("crowd: seen = total + overkill + 1 % (1060) is clear", AreaAt(1060, 1000, 50) == "clear")
        Check("crowd: seen one above total + overkill + 1 % (1061) is crowded", AreaAt(1061, 1000, 50) == "crowded")
        -- run 102226Z read seen 20306 against meter 4211377; clean solo reads were at most ~5 % short
        Check("crowd: seen half the meter (500 of 1000) is still clear", AreaAt(500, 1000) == "clear")
        Check("crowd: seen below half the meter (499 of 1000) is short", AreaAt(499, 1000) == "short")
        do -- shamanally2: a 3 s blip right after a crowded read (seen 0, meter 0) read "clear" and saved it
            local rig = Rig({ [SMITE] = 2 })
            local Teacher = rig.ns.Teacher
            Teacher.area = "crowded"
            rig.S.sessions = { Session(1, { Row(SMITE, 0) }) }
            Teacher.Start(10)
            Teacher.Finish(13)
            pcall(rig.Fire)
            Check("crowd: a read with nothing seen and a zero meter is short and keeps the state",
                Teacher.last.area == "short" and Teacher.area == "crowded")
        end

        do -- own schools: a clear read proves its seen wounds were yours, so their schools are; '?' of any other
            -- school is a stranger's (shamanally2: an ally's 873 physical hits drew '?' on a resto shaman's dummy)
            -- A read of one 1000 row against seen `hits` = { { amount, school }, ... }; returns the rig.
            local function SchoolRead(hits, prep)
                local rig = Rig({ [SMITE] = 2 })
                if prep then prep(rig) end
                rig.S.sessions = { Session(1, { Row(SMITE, 1000) }) }
                rig.ns.Teacher.Start(10)
                for _, hit in ipairs(hits) do rig.ns.Teacher.Seen(hit[1], 11, hit[2]) end
                rig.ns.Teacher.Finish(20)
                pcall(rig.Fire)
                return rig
            end
            local rig = SchoolRead({ { 990, 8 }, { 5, 1 }, { 12, 4 } })
            local schools = T.Store().schools
            Check("schools: a clear read records the schools seen above 1 % of the meter",
                rig.ns.Teacher.last.area == "clear" and schools and schools[8] and schools[4] and schools[1] == nil)
            Check("schools: a recorded school is yours, an unrecorded one is not",
                rig.ns.Teacher.OwnSchool(8) and not rig.ns.Teacher.OwnSchool(1) and not rig.ns.Teacher.OwnSchool(nil))
            rig = SchoolRead({ { 990, 8 }, { 2000, 1 } })
            Check("schools: a crowded read records nothing",
                rig.ns.Teacher.last.area == "crowded" and T.Store().schools == nil)
            rig = SchoolRead({ { 300, 1 } })
            Check("schools: a short read records nothing",
                rig.ns.Teacher.last.area == "short" and T.Store().schools == nil)
            rig = SchoolRead({ { 995, 1 } }, function() T.Store().schools = { [8] = true } end)
            Check("schools: a clear read adds to the schools already recorded",
                T.Store().schools[8] and T.Store().schools[1])
            rig = Rig({})
            Check("schools: with none recorded yet every school counts as yours",
                rig.ns.Teacher.OwnSchool(1) and rig.ns.Teacher.OwnSchool(64))

            local ns = T.Boot(function()
                CombatTextIconsCharDB = { schools = { [8] = true, [0] = true, [128] = true, ["4"] = true, [2] = "yes",
                    [2.5] = true, [64] = Secret(true) } }
            end)
            Check("schools: saved schools keep only an integer 1-127 marked true",
                Count(T.Store().schools) == 1 and T.Store().schools[8] == true and ns.Teacher.OwnSchool(8))
            ns = T.Boot(function() CombatTextIconsCharDB = { schools = "8" } end)
            Check("schools: saved schools that are no table are dropped", T.Store().schools == nil)

            rig = Rig({})
            T.Store().schools = { [8] = true }
            rig.ns.Teacher.Start(10)
            local stranger, own = rig.Hit(11, "nameplate1", 5000, 1), rig.Hit(12, "nameplate1", 5000, 8)
            Check("schools: a solo unexplained hit of an unrecorded school stays hidden, one of yours draws '?'",
                stranger == nil and own == rig.ns.Meter.UNKNOWN_ICON)
            Check("schools: the hidden one still reaches the teacher", #rig.ns.Teacher.fight.unknown == 2)
        end
        for _, area in ipairs({ "clear", "crowded" }) do
            local rig, ok, last, learned = Crowd(area, 86)
            Check("crowd: a short read keeps the state (" .. area .. ") and skips learning",
                ok and rig.ns.Teacher.area == area and last.area == "short" and not learned)
        end

        do
            local rig, ok, last, learned = Crowd("clear", 300)
            Check("crowd: a crowded read from clear turns crowded, skips learning, still applies verdicts",
                ok and rig.ns.Teacher.area == "crowded" and last.area == "crowded" and not learned
                and Find(last, SMITE).verdict == "agree")
            rig, ok, last, learned = Crowd("crowded", 173)
            Check("crowd: a clear read from crowded turns clear and learns",
                ok and rig.ns.Teacher.area == "clear" and last.area == "clear" and learned)
            rig, ok, last, learned = Crowd("clear", 173)
            Check("crowd: a clear read from clear stays clear and learns",
                ok and rig.ns.Teacher.area == "clear" and last.area == "clear" and learned)

            for _, area in ipairs({ "clear", "crowded" }) do
                rig, ok, last, learned = Crowd(area, 300, true)
                Check("crowd: a group fight (run.group) keeps the state (" .. area .. ") and skips learning",
                    ok and rig.ns.Teacher.area == area and not learned and last.area == "group"
                    and Find(last, SMITE).verdict == "agree")
                rig, ok, last, learned = Crowd(area, 173, false, true)
                -- priest3: joining the dungeon group 2 s after a solo dummy fight lost that fight's read
                Check("crowd: grouped only at read time is still a solo fight: it reads clear and learns (" .. area .. ")",
                    ok and rig.ns.Teacher.area == "clear" and last.area == "clear" and learned)
            end
        end

        -- one per skip reason the rig can produce, run from clear and from crowded
        local good = { Session(1, { Row(SMITE, 53) }) }
        local skips = {
            { "no fight", function(rig) rig.ns.Teacher.Finish(20) end },
            { "meter off", function(rig)
                rig.ns.Meter.Disable("test")
                rig.Fight({ [SMITE] = { 53 } }, good)
            end },
            { "secret", function(rig)
                rig.S.sessionsFail = "secret"
                rig.Read({ [SMITE] = { 53 } }, good)
            end },
            { "read failed", function(rig)
                rig.S.sourceFail = "error"
                rig.Read({ [SMITE] = { 53 } }, good)
            end },
            { "no sessions", function(rig) rig.Read({ [SMITE] = { 53 } }, {}) end },
            { "duplicate session", function(rig, area)
                rig.Read({ [SMITE] = { 53 } }, good)
                rig.ns.Teacher.area = area -- the first read decided; the second is the one under test
                rig.Read({ [SMITE] = { 53 } }, good)
            end },
        }
        for _, skip in ipairs(skips) do
            local reason, run = skip[1], skip[2]
            for _, area in ipairs({ "clear", "crowded" }) do
                local rig = Rig({ [SMITE] = 2 })
                rig.ns.Teacher.area = area
                local ok = pcall(run, rig, area)
                Check("crowd: a skipped read (" .. reason .. ") leaves the state unchanged from " .. area,
                    ok and rig.ns.Teacher.last.skip == reason and rig.ns.Teacher.area == area)
            end
        end

        do
            local rig = Rig({})
            local Teacher = rig.ns.Teacher
            local ok = pcall(Teacher.Seen, 5)
            Check("crowd: Seen without an open fight does nothing and raises no error", ok and Teacher.fight == nil)

            Teacher.Start(10, true)
            Teacher.Seen(7)
            ok = pcall(function()
                Teacher.Seen(Secret(5))
                Teacher.Seen("x")
                Teacher.Seen(nil)
            end)
            Check("crowd: Seen ignores a secret or non-number amount", ok and Teacher.fight.seen == 7)
            Teacher.Seen(3)
            Check("crowd: Seen adds amounts (7 + 3 = 10); Start opens the fight with seen 0 and its group flag",
                Teacher.fight.seen == 10 and Teacher.fight.group == true)
        end

        do
            local rig = Rig({})
            rig.ns.Teacher.area = "clear"
            local before = rig.ns.Teacher.AreaClear()
            rig.ns.Meter.Disable("test")
            Check("crowd: clear but meter disabled -> AreaClear false",
                before and rig.ns.Teacher.area == "clear" and not rig.ns.Teacher.AreaClear())
        end

        do -- the live crowd check: lock3 F3, a world boss after clear dummies, drew a learned proc on strangers' hits
            -- A clear read of one Smite row `total` over the fight 10..`finish` saves the pace (total per second).
            local function PaceAfter(total, finish, preset)
                local rig = Rig({ [SMITE] = 2 })
                T.Store().pace = preset
                rig.ns.Teacher.Init(T.Store())
                rig.S.sessions = { Session(1, { Row(SMITE, total) }) }
                rig.ns.Teacher.Start(10)
                rig.ns.Teacher.Drawn(SMITE, total)
                rig.ns.Teacher.Seen(total, 11)
                rig.ns.Teacher.Finish(finish)
                pcall(rig.Fire)
                return T.Store().pace
            end
            Check("crowd live: a clear read saves its pace (1000 over 10 s = 100)", PaceAfter(1000, 20) == 100)
            Check("crowd live: a faster clear read raises the pace, a slower one keeps it",
                PaceAfter(1000, 20, 50) == 100 and PaceAfter(1000, 20, 400) == 400)
            Check("crowd live: a saved pace that is not a positive number is dropped on load",
                PaceAfter(1000, 20, "fast") == 100 and PaceAfter(1000, 20, -5) == 100
                and PaceAfter(1000, 20, 1 / 0) == 100)

            local PROC = 1287663
            -- A clear-area fight from t 10 at saved pace `pace`: a proc hit (350, school 106) at 11, a stranger's wound
            -- of `crowd` at 12, then a proc hit at 13 and at 30. Returns what the last three proc hits drew.
            local function Boss(pace, crowd)
                local rig = Rig({})
                SeedProc(rig, PROC, true)
                T.Store().pace = pace
                rig.ns.Teacher.Init(T.Store())
                SlashCmdList.COMBATTEXTICONS("debug")
                rig.S.now = 10
                rig.ns.Core.PLAYER_REGEN_DISABLED()
                local first = rig.Hit(11, "nameplate1", 350, 106)
                rig.Hit(12, "nameplate1", crowd, 1)
                return first, rig.Hit(13, "nameplate1", 350, 106), rig.ns.Teacher.AreaClear()
            end
            local tex = "tex:" .. PROC
            -- pace 100: the bound is 4 x 100 x 5 s (the wait) = 2000 at 13 s; seen there is 350 + crowd + 350 (the
            -- hit itself)
            local first, after, clear = Boss(100, 1301)
            Check("crowd live: seen at the bound (2001 > 2000) turns the fight crowded: the proc no longer draws",
                first == tex and after == nil and not clear and Logged("TEACH crowd live seen=2001 pace=100"))
            first, after, clear = Boss(100, 1300)
            Check("crowd live: seen at the bound (2000) keeps the fight clear", first == tex and after == tex and clear)
            first, after = Boss(nil, 100000)
            Check("crowd live: with no saved pace (no clear read yet) nothing turns crowded",
                first == tex and after == tex)
            local rig = Rig({})
            rig.ns.Teacher.Start(10)
            rig.ns.Teacher.fight.crowded = true
            rig.ns.Teacher.Finish(12)
            rig.ns.Teacher.Start(20)
            Check("crowd live: the next fight starts clear again", rig.ns.Teacher.AreaClear())
        end

        do -- each map keeps the verdict last decided on it, restored on entering the world there (shamanresto 17:53:
            -- the one saved verdict was for map 2537, so a fight on 2266 drew no proc and no '?')
            -- A boot whose saved spec store holds `areas` (or an older save's single `area`) and whose player stands on
            -- `map` (nil: the API answers nothing).
            local function BootArea(areas, map, area)
                return T.Boot(function(S)
                    S.map = map
                    CombatTextIconsCharDB = { areas = areas, area = area }
                end)
            end
            local MAP, OTHER = 2022, 2537

            for _, state in ipairs({ "clear", "crowded" }) do
                local ns = BootArea({ [MAP] = state }, MAP)
                Check("crowd saved: the same map restores " .. state,
                    ns.Teacher.area == state and ns.Teacher.AreaClear() == (state == "clear")
                    and T.Store().areas[MAP] == state)
            end

            local ns = BootArea({ [MAP] = "clear" }, MAP + 1)
            Check("crowd saved: a map with no verdict boots unknown, and the saved one stays for its own map",
                ns.Teacher.area == "unknown" and T.Store().areas[MAP] == "clear" and T.Store().areas[MAP + 1] == nil)

            for _, case in ipairs({ { MAP, "clear" }, { OTHER, "crowded" } }) do
                ns = BootArea({ [MAP] = "clear", [OTHER] = "crowded" }, case[1])
                Check("crowd saved: of two saved maps, map " .. case[1] .. " restores its own " .. case[2],
                    ns.Teacher.area == case[2] and T.Store().areas[MAP] == "clear"
                    and T.Store().areas[OTHER] == "crowded")
            end

            for label, map in pairs({ nil_ = false, text = "2022", secret = Secret(MAP), zero = 0, fraction = 2022.5 }) do
                ns = BootArea({ [MAP] = "clear" }, map or nil)
                Check("crowd saved: a current map that is " .. label .. " boots unknown", ns.Teacher.area == "unknown")
            end

            local bad = { state = { [MAP] = "maybe" }, tableState = { [MAP] = { state = "clear" } },
                textMap = { ["2022"] = "clear" }, zero = { [0] = "clear" }, fraction = { [2022.5] = "clear" },
                negative = { [-1] = "clear" } }
            for label, areas in pairs(bad) do
                areas[OTHER] = "clear"
                ns = BootArea(areas, MAP)
                local count = 0
                for _ in pairs(T.Store().areas) do count = count + 1 end
                Check("crowd saved: a saved verdict that is " .. label .. " is dropped on load, the good one kept",
                    count == 1 and T.Store().areas[OTHER] == "clear" and ns.Teacher.area == "unknown")
            end
            ns = BootArea("clear", MAP)
            Check("crowd saved: saved areas that are no table are dropped",
                T.Store().areas == nil and ns.Teacher.area == "unknown")

            ns = BootArea(nil, MAP, { state = "clear", map = MAP })
            Check("crowd saved: an older save's single verdict is kept for its map",
                ns.Teacher.area == "clear" and T.Store().areas[MAP] == "clear" and T.Store().area == nil)
            ns = BootArea({ [MAP] = "crowded" }, MAP, { state = "clear", map = MAP })
            Check("crowd saved: a map's own verdict beats an older save's single one", ns.Teacher.area == "crowded")
            local badOld = { text = "clear", state = { state = "maybe", map = MAP }, noMap = { state = "clear" },
                fraction = { state = "clear", map = 2022.5 } }
            for label, area in pairs(badOld) do
                ns = BootArea(nil, MAP, area)
                Check("crowd saved: an older save's single verdict that is " .. label .. " is dropped",
                    T.Store().area == nil and T.Store().areas == nil and ns.Teacher.area == "unknown")
            end

            ns = BootArea(nil, MAP)
            Check("crowd saved: no saved area boots unknown and saves nothing",
                ns.Teacher.area == "unknown" and T.Store().areas == nil)

            for _, case in ipairs({ { "crowded", 173, "clear" }, { "clear", 300, "crowded" } }) do
                local rig = Crowd(case[1], case[2])
                Check("crowd saved: a " .. case[3] .. " read saves its verdict for the current map",
                    rig.S.map ~= nil and T.Store().areas[rig.S.map] == case[3])
            end

            local function Preset(rig) T.Store().areas = { [7] = "clear" } end
            local function Unchanged()
                local areas = T.Store().areas
                return areas and areas[7] == "clear" and next(areas, next(areas)) == nil
            end
            Crowd("clear", 86, nil, nil, Preset)
            Check("crowd saved: a short read saves nothing new", Unchanged())
            Crowd("clear", 300, true, nil, Preset)
            Check("crowd saved: a group read saves nothing new", Unchanged())
            local groupedLate = Crowd("clear", 173, false, true, Preset)
            Check("crowd saved: a solo read grouped only at read time saves its clear verdict",
                T.Store().areas[groupedLate.S.map] == "clear" and T.Store().areas[7] == "clear")
            Crowd("crowded", 173, nil, nil, function(rig) Preset(rig) rig.S.map = nil end)
            Check("crowd saved: a read with no map saves nothing and keeps the other maps' verdicts", Unchanged())

            local rig = Crowd("crowded", 173)
            local first = rig.S.map
            SlashCmdList.COMBATTEXTICONS("forget")
            Check("crowd saved: /cti forget keeps the saved areas",
                T.Store().areas[first] == "clear" and rig.ns.Teacher.area == "clear")
            rig.S.map = first + 1
            rig.ns.Core.PLAYER_ENTERING_WORLD()
            Check("crowd saved: a loading screen onto another map turns unknown", rig.ns.Teacher.area == "unknown")
            rig.S.map = first
            rig.ns.Core.PLAYER_ENTERING_WORLD()
            Check("crowd saved: a loading screen back onto a judged map restores its verdict",
                rig.ns.Teacher.area == "clear")
        end

        -- The debug log: the clean line comes before the row lines; a fractional seen is floored.
        local function ReadLogged(seen)
            local rig = Rig({ [SMITE] = 2 })
            SlashCmdList.COMBATTEXTICONS("debug")
            rig.S.sessions = { Session(1, { Row(SMITE, 53) }) }
            rig.ns.Teacher.Start(10)
            rig.ns.Teacher.Drawn(SMITE, 53)
            rig.ns.Teacher.Seen(seen)
            rig.ns.Teacher.Finish(20)
            local ok = pcall(rig.Fire)
            local at = {}
            for index, line in ipairs(CombatTextIconsDB.debugLog) do
                for key, text in pairs({ clean = "TEACH clean ", row = "TEACH 591 tally=53" }) do
                    if line:find(text, 1, true) then at[key] = index end
                end
            end

            return ok, at, CombatTextIconsDB.debugLog[at.clean]
        end
        local _, at = ReadLogged(53)
        Check("crowd: the debug log gets TEACH clean seen=53 meter=53 -> clear before the row lines",
            at.clean and at.row and at.clean < at.row and Logged("TEACH clean seen=53 meter=53 -> clear"))
        local okFloat, _, line = ReadLogged(54.5)
        Check("crowd: a fractional seen logs floored and raises no error (54.5 vs 53 -> seen=54 crowded)",
            okFloat and line and line:find("TEACH clean seen=54 meter=53 -> crowded", 1, true) ~= nil)
    end

    do -- crowd check on real data: five fights the probe recorded (spec 7.4), each paired with its meter dump
        local FIXTURE = T.Root .. "/tests/fixtures/probe6-2026-10-24.lua"
        local env = {}
        local chunk = loadfile(FIXTURE, "t", env)
        local loaded = chunk and pcall(chunk)
        local db = loaded and env.CTIProbeDB or { seq = {}, rows = {} }
        -- fight start -> dump time, from the spec table (oracle, not computed)
        local FIGHTS = {
            { 207031.741, 207044.851 }, { 207044.561, 207048.979 }, { 207065.017, 207082.554 },
            { 207084.289, 207088.627 }, { 207162.525, 207213.762 },
        }

        -- The plate WOUND amounts of the fight that starts at `startAt`, up to the next START.
        -- The fixture has CRLF lines, so a trailing carriage return is stripped before splitting.
        local function FightAmounts(startAt)
            local amounts, inFight = {}, false
            for _, line in ipairs(db.seq) do
                local fields = {}
                for field in line:gsub("\r$", ""):gmatch("%S+") do fields[#fields + 1] = field end
                if fields[3] == "START" then inFight = tonumber(fields[2]) == startAt end
                local isWound = fields[3] == "U" and (fields[4] or ""):find("^nameplate") and fields[5] == "WOUND"
                if inFight and isWound then amounts[#amounts + 1] = tonumber(fields[7]) end
            end

            return amounts
        end
        -- The meter session of the dump taken at `at`; "?" values become secrets.
        local function DumpSession(id, at)
            local rows = {}
            for _, dump in ipairs(db.rows) do
                if dump.at == at then
                    for _, line in ipairs(dump[0]) do
                        local spellID = line:match("spellID=(%S+)")
                        local total = line:match("totalAmount=(%S+)")
                        local overkill = line:match("overkillAmount=(%S+)")
                        if not line:find("^source%.") and spellID then
                            local isSecret = total == "?"
                            rows[#rows + 1] = Row(tonumber(spellID) or 0,
                                isSecret and Secret("total") or tonumber(total),
                                isSecret and Secret("overkill") or tonumber(overkill))
                        end
                    end
                end
            end

            return Session(id, rows)
        end

        local rig = Rig({})
        rig.ns.Teacher.area = "crowded"
        local seen, outcomes, areaAfterFirst = {}, {}, nil
        -- each fight's meter session ID (probe events M <type> <id>): fights 1-2 share 3, fights 3-4 share 4
        local SESSION_IDS = { 3, 3, 4, 4, 5 }
        -- Fires the read of fight `index` against its dump; records its outcome ("carried" when it has none).
        local function ReadFight(index)
            rig.S.sessions = { DumpSession(SESSION_IDS[index], FIGHTS[index][2]) }
            pcall(rig.Fire)
            local last = rig.ns.Teacher.last
            outcomes[index] = not last and "carried" or last.skip and ("skip:" .. last.skip) or last.area
            if index == 1 then areaAfterFirst = rig.ns.Teacher.area end
        end
        for index, pair in ipairs(FIGHTS) do
            local amounts = FightAmounts(pair[1])
            local total = 0
            rig.ns.Teacher.Start(pair[1], false)
            if index > 1 and pair[1] < FIGHTS[index - 1][2] then ReadFight(index - 1) end -- pulled before that read
            for _, amount in ipairs(amounts) do
                rig.ns.Teacher.Seen(amount)
                total = total + amount
            end
            rig.ns.Teacher.Finish(pair[2])
            local nextFight = FIGHTS[index + 1]
            if not (nextFight and nextFight[1] < pair[2]) then ReadFight(index) end
            seen[index] = string.format("%d", total)
        end
        local seenList, outcomeList = table.concat(seen, ","), table.concat(outcomes, ",")
        Check("crowd probe6: seen totals are 450307, 221409, 1026076, 191434, 34506472", seenList == "450307,221409,1026076,191434,34506472")
        -- fight 1's read meets fight 2 (carried: 671716 seen of 777938); fight 4 reads what session 4 grew since
        -- fight 3's read (1240519 - 1038269 = 202250 against 191434 seen)
        Check("crowd probe6: reads give carried, clear, clear, clear, crowded [" .. outcomeList .. "]",
            outcomeList == "carried,clear,clear,clear,crowded")
        Check("crowd probe6: the state stays crowded through the carried first read", areaAfterFirst == "crowded")
    end

    do -- safety net (spec 3.3): learned DoTs and channels are judged by every read
        local TRIGGER, VT = 1227280, 34914 -- Tentacle Slam (no meter row of its own), Vampiric Touch (row 34914)
        local function Seed(rig, id)
            T.Store().learned[id] = { school = 32, period = 3, kind = "dot", misses = 0 }
            rig.ns.Learn.Init(T.Store())
        end
        -- One read of a fresh session; tally = { [id] = total }. Returns Teacher.last.
        local function Step(rig, tally, rows)
            nextSession = nextSession + 1
            local amounts = {}
            for id, total in pairs(tally) do amounts[id] = { total } end
            local ok, last = rig.Read(amounts, { Session(nextSession, Balanced(amounts, rows)) })
            assert(ok, last)
            return last
        end
        local function Kept(rig, id) return rig.ns.Learn.Get(id) ~= nil end
        local function Strike(rig, id) return Step(rig, { [id] = 500 }, { Row(GRAVE, 56) }) end -- drawn, no row, no agreeing row

        do -- rule 1: over drops at once; under keeps
            local rig = Rig({}); Seed(rig, TRIGGER)
            Step(rig, { [TRIGGER] = 60 }, { Row(TRIGGER, 100) }) -- 60 seen of 100: clear, not short
            Check("net: an under read (60 vs 100) keeps the learned spell", Kept(rig, TRIGGER))
            Step(rig, { [TRIGGER] = 200 }, { Row(TRIGGER, 100) })
            Check("net: an over read (200 vs 100 + TOL 1) drops it at once", not Kept(rig, TRIGGER))
        end

        do -- rule 3: first unpaired read keeps, second drops
            local rig = Rig({}); Seed(rig, TRIGGER)
            local last = Strike(rig, TRIGGER)
            Check("net: one unpaired read (drawn, no row) keeps the spell", Kept(rig, TRIGGER) and Find(last, TRIGGER).verdict == "unpaired")
            Strike(rig, TRIGGER)
            Check("net: a second unpaired read drops it", not Kept(rig, TRIGGER))
        end

        do -- rule 4: a paired read (under, then agree) resets the count
            local rig = Rig({}); Seed(rig, TRIGGER)
            Strike(rig, TRIGGER)
            Step(rig, { [TRIGGER] = 60 }, { Row(TRIGGER, 100) }) -- under (60 seen of 100: clear, not short)
            Strike(rig, TRIGGER)
            Check("net: strike, under, strike keeps the spell", Kept(rig, TRIGGER))
            Step(rig, { [TRIGGER] = 100 }, { Row(TRIGGER, 100) }) -- agree
            Strike(rig, TRIGGER)
            Check("net: strike, agree, strike keeps the spell", Kept(rig, TRIGGER))
            Strike(rig, TRIGGER)
            Check("net: two strikes in a row after the reset drop it", not Kept(rig, TRIGGER))
        end

        do -- a pairing through a saved alias counts as paired (row 34914 -> cast 1227280)
            local rig = Rig({}); Seed(rig, TRIGGER)
            Strike(rig, TRIGGER)
            rig.ns.Fingerprints.SetAlias(VT, TRIGGER)
            local last = Step(rig, { [TRIGGER] = 6000 }, { Row(VT, 6000) })
            Strike(rig, TRIGGER)
            Check("net: alias pairing (agree) resets the strikes", Find(last, TRIGGER).verdict == "agree" and Kept(rig, TRIGGER))
        end

        do -- Review Focus 4: a learned spell not drawn, and a skipped read, leave the count unchanged
            local rig = Rig({}); Seed(rig, TRIGGER)
            Strike(rig, TRIGGER)
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50) }) -- another spell's read, TRIGGER not drawn
            Check("net: a read where the learned spell was not drawn adds no strike", Kept(rig, TRIGGER))
            rig.S.sessionsFail = "secret"
            local _, skipped = rig.Read({ [TRIGGER] = { 500 } }, { Session(1, { Row(GRAVE, 56) }) })
            rig.S.sessionsFail = nil
            Check("net: a skipped read ('secret') changes nothing", skipped.skip == "secret" and Kept(rig, TRIGGER))
            Strike(rig, TRIGGER)
            Check("net: undrawn and skipped reads kept the one strike, so the next unpaired read is the second and drops it",
                not Kept(rig, TRIGGER))

            rig = Rig({}); Seed(rig, TRIGGER)
            Strike(rig, TRIGGER)
            Step(rig, {}, { Row(TRIGGER, 300) }) -- its own row, tally 0
            Check("net: a read with the spell's own row but tally 0 adds no strike", Kept(rig, TRIGGER))
            Strike(rig, TRIGGER)
            Check("net: ... so the next unpaired read is the second and drops it", not Kept(rig, TRIGGER))
        end

        do -- a learned spell cast this fight that drew nothing and has no row is struck (twins tie, so neither draws)
            local FS_TWIN = 470411 -- cast in Flame Shock's frame, no meter row (run shaman4)
            local function Cast(rig, id, at) rig.ns.Learn.OnCast(id, at) end -- every rig fight starts at 10
            local rig = Rig({}); Seed(rig, FS_TWIN)
            Cast(rig, FS_TWIN, 5)
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50) })
            Check("net: undrawn and cast before the fight began: no strike", Kept(rig, FS_TWIN))
            Cast(rig, FS_TWIN, 15)
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50), Row(FS_TWIN, 300) })
            Check("net: undrawn, cast this fight, its own row listed: no strike", Kept(rig, FS_TWIN))
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50) })
            Check("net: undrawn, cast this fight, no row: one strike keeps it", Kept(rig, FS_TWIN))
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50) })
            Check("net: ... and the second such read drops it", not Kept(rig, FS_TWIN))

            rig = Rig({})
            T.Store().learned[FS_TWIN] = { school = 2, period = 3, kind = "hot", misses = 0 }
            rig.ns.Learn.Init(T.Store())
            Cast(rig, FS_TWIN, 15)
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50) })
            Step(rig, { [WAND] = 50 }, { Row(WAND, 50) })
            Check("net: a hot has no damage row, so two such reads keep it", Kept(rig, FS_TWIN))
        end

        do -- the meter may list one spell in two rows: they are one row (sum of total and overkill)
            local rig = Rig({}); Seed(rig, TRIGGER)
            local last = Step(rig, { [TRIGGER] = 1000 }, { Row(TRIGGER, 900), Row(TRIGGER, 100) })
            local entries = 0
            for _, entry in ipairs(last.rows) do
                if entry.spellID == TRIGGER then entries = entries + 1 end
            end
            Check("net: duplicate rows (900 + 100) for a tally of 1000 read as one agreeing row and keep the spell",
                entries == 1 and Find(last, TRIGGER).verdict == "agree" and Find(last, TRIGGER).meter == 1000 and Kept(rig, TRIGGER))
            last = Step(rig, { [TRIGGER] = 1100 }, { Row(TRIGGER, 900, 60), Row(TRIGGER, 100, 50) })
            Check("net: duplicate rows sum their overkill too (1100 within 1000 + 110 overkill)",
                Find(last, TRIGGER).verdict == "agree" and Kept(rig, TRIGGER))
        end

        do -- rule 2: no alias for a learned spell to the row of a spell you cast; it is struck instead
            local rig = Rig({}); Seed(rig, TRIGGER)
            local F = rig.ns.Fingerprints
            rig.ns.Learn.OnCast(VT, 5) -- Vampiric Touch is a cast of yours: its row is its own
            local last = Step(rig, { [TRIGGER] = 6000 }, { Row(VT, 6000) }) -- the row agrees with the trigger's tally
            Check("net rule 2: one learned tally and one agreeing row make no alias and no pairing",
                F.Alias(VT) == nil and Find(last, TRIGGER).verdict == "unpaired" and Find(last, VT).verdict == "unpaired"
                and Find(last, VT).tally == 0)
            Check("net rule 2: the learned spell got one strike (kept now)", Kept(rig, TRIGGER))
            Step(rig, { [TRIGGER] = 6000 }, { Row(VT, 6000) })
            Check("net rule 2: the same read again is the second strike and drops it", not Kept(rig, TRIGGER))

            rig = Rig({})
            Step(rig, { [WAND] = 6000 }, { Row(VT, 6000) })
            Check("net rule 2: an unlearned spell with the same shape still gets its alias", rig.ns.Fingerprints.Alias(VT) == WAND)
        end

        do -- Review Focus 3: two missing tallies, one learned -> nothing aliases, the learned one is struck
            local rig = Rig({}); Seed(rig, TRIGGER)
            rig.ns.Learn.OnCast(VT, 5)
            local last = Step(rig, { [TRIGGER] = 6000, [WAND] = 6000 }, { Row(VT, 6000) })
            Check("net rule 2: two missing tallies (learned X, unlearned Y) both agreeing with the row -> no alias",
                rig.ns.Fingerprints.Alias(VT) == nil and Find(last, TRIGGER).verdict == "unpaired"
                and Find(last, WAND).verdict == "unpaired" and Find(last, VT).verdict == "unpaired")
            Check("net rule 2: ... and the learned X is kept after one such read", Kept(rig, TRIGGER))
            Step(rig, { [TRIGGER] = 6000, [WAND] = 6000 }, { Row(VT, 6000) })
            Check("net rule 2: ... and struck again by the second, so it is dropped", not Kept(rig, TRIGGER))
        end

        do -- run mage: Arcane Missiles 5143, learned as a DoT by votes, drew its ticks; the meter files them as 7268
            local MISSILES, TICKS, OTHER = 5143, 7268, 210833
            -- One clear read: `tally` drawn, `unknown` = { { school, amount }, ... } '?' hits on a plate, and the rest of
            -- the rows' damage seen undrawn.
            local function Step(rig, tally, rows, unknown)
                local Teacher = rig.ns.Teacher
                nextSession = nextSession + 1
                local seen, total = 0, 0
                for _, row in ipairs(rows) do total = total + row.totalAmount end
                rig.S.sessions = { Session(nextSession, rows) }
                Teacher.Start(10)
                for id, amount in pairs(tally) do
                    Teacher.Drawn(id, amount)
                    seen = seen + amount
                end
                for _, hit in ipairs(unknown or {}) do
                    Teacher.Unknown(rig.Plate("nameplate1"), hit[1], hit[2], 12)
                    seen = seen + hit[2]
                end
                Teacher.Seen(math.max(seen, total))
                Teacher.Finish(20)
                assert(pcall(rig.Fire))
                return Teacher.last
            end
            local ARCANE = { { 32, 113000 } } -- the ticks on the plates the DoT never drew: '?' of its school
            local rig = Rig({}); Seed(rig, MISSILES)
            local F = rig.ns.Fingerprints
            local last = Step(rig, { [MISSILES] = 48508 }, { Row(TICKS, 161687), Row(OTHER, 14263) }, ARCANE)
            local entry = Find(last, MISSILES)
            Check("tick row: a learned DoT drawn with no row takes the one open row it fits that no cast of yours has",
                F.Alias(TICKS) == MISSILES and entry and entry.meterID == TICKS and entry.verdict == "under"
                and Find(last, OTHER).verdict == "unpaired")
            Step(rig, { [MISSILES] = 24885 }, { Row(TICKS, 133301) })
            Step(rig, { [MISSILES] = 30000 }, { Row(TICKS, 130004) })
            Check("tick row: ... so its later reads pair through the alias and strike nothing", Kept(rig, MISSILES))

            rig = Rig({}); Seed(rig, MISSILES)
            last = Step(rig, { [MISSILES] = 48508 }, { Row(TICKS, 161687), Row(OTHER, 50000) }, ARCANE)
            Check("tick row: two open rows it fits -> no alias, an unpaired strike",
                rig.ns.Fingerprints.Alias(TICKS) == nil and Find(last, MISSILES).verdict == "unpaired")

            rig = Rig({}); Seed(rig, MISSILES)
            Step(rig, { [MISSILES] = 48508 }, { Row(TICKS, 161687) }, { { 1, 113000 } })
            Check("tick row: a row its school's hits cannot fill is never taken (a pet's melee row)",
                rig.ns.Fingerprints.Alias(TICKS) == nil)

            rig = Rig({}); Seed(rig, MISSILES)
            rig.ns.Learn.OnCast(TICKS, 5)
            Step(rig, { [MISSILES] = 48508 }, { Row(TICKS, 161687) }, ARCANE)
            Check("tick row: the row of a spell you cast is never taken", rig.ns.Fingerprints.Alias(TICKS) == nil)

            rig = Rig({}); Seed(rig, MISSILES)
            last = Step(rig, { [MISSILES] = 48508, [WAND] = 30000 }, { Row(TICKS, 40000) }, ARCANE)
            Check("tick row: a row the tally overshoots is never taken, though one other rowless tally fits it:"
                .. " an unpaired strike, not an over",
                rig.ns.Fingerprints.Alias(TICKS) == nil and Find(last, MISSILES).meterID == MISSILES
                and Find(last, MISSILES).verdict == "unpaired" and Kept(rig, MISSILES))

            rig = Rig({}); Seed(rig, MISSILES)
            Step(rig, { [MISSILES] = 48508, [WAND] = 30000 }, { Row(TICKS, 161687) }, ARCANE)
            Check("tick row: another drawn spell with no row fits it too -> no alias",
                rig.ns.Fingerprints.Alias(TICKS) == nil)
        end

        do -- a group, crowded or short read is frozen: it judges for the Ledger, changes no learned state
            local BIG, VOTER = 777, 48181 -- a row the fight barely saw (a short read); an unlearned cast collecting votes
            -- One fight read as `area`: `drawn` = { [id] = amount }, each drawn and seen, against `rows`; a group or
            -- crowded fight also sees far more than the meter holds (strangers), a short one sees under half of it.
            local function Frozen(rig, area, drawn, rows, during)
                local Teacher = rig.ns.Teacher
                nextSession = nextSession + 1
                rig.S.sessions = { Session(nextSession, rows) }
                Teacher.Start(10, area == "group")
                for id, amount in pairs(drawn) do
                    Teacher.Drawn(id, amount)
                    Teacher.Seen(amount)
                end
                if area ~= "short" then Teacher.Seen(1e9) end
                if during then during() end
                Teacher.Finish(20)
                local ok, problem = pcall(rig.Fire)
                assert(ok, problem)
                return Teacher.last
            end

            for _, area in ipairs({ "group", "crowded", "short" }) do
                local rig = Rig({ [SMITE] = 2 }); Seed(rig, TRIGGER)
                local F = rig.ns.Fingerprints
                local rows = { Row(BIG, 1e6), Row(TRIGGER, 100), Row(SMITE, 100), Row(AUTO_SHOT, 87) }
                local last
                for _ = 1, 2 do last = Frozen(rig, area, { [TRIGGER] = 500, [SMITE] = 500, [WAND] = 87 }, rows) end
                Check("frozen (" .. area .. "): two over reads are still judged for the Ledger",
                    last.area == area and Find(last, TRIGGER).verdict == "over" and Find(last, SMITE).verdict == "over")
                Check("frozen (" .. area .. "): two over reads keep the learned DoT with no strike",
                    Kept(rig, TRIGGER) and rig.ns.Learn.List()[1].unpaired == 0)
                Check("frozen (" .. area .. "): two over reads keep the fingerprint with no over and no strike",
                    F.Get(SMITE) ~= nil and F.Get(SMITE).over == 0 and F.Get(SMITE).strikes == 0)
                Check("frozen (" .. area .. "): the one tally and one agreeing row save no alias",
                    Find(last, WAND).verdict == "agree" and F.Alias(AUTO_SHOT) == nil)
                Frozen(rig, area, { [SMITE] = 100 }, { Row(BIG, 1e6), Row(SMITE, 100) })
                Check("frozen (" .. area .. "): an agreeing read counts no fight",
                    F.Get(SMITE) ~= nil and F.Get(SMITE).fights == 0)

                rig = Rig({}); Seed(rig, TRIGGER)
                local Learn = rig.ns.Learn
                local function CastBoth() Learn.OnCast(TRIGGER, 12); Learn.OnCast(VOTER, 12) end
                for _ = 1, 2 do Frozen(rig, area, {}, { Row(GRAVE, 56) }, CastBoth) end
                Check("frozen (" .. area .. "): a learned DoT cast with no row and nothing drawn survives two reads",
                    Kept(rig, TRIGGER) and Learn.List()[1].unpaired == 0)
                -- the meter's rows are yours alone, strangers or not: a cast with no row votes no DoT (synthetic group
                -- lock: Malevolence 442726 voted on through crowded reads, was learned and drew other DoTs' ticks)
                Check("frozen (" .. area .. "): a voting cast with no row is rowless all the same",
                    Learn.Votes(VOTER) ~= nil and Learn.Rowless(VOTER))
            end

            for _, area in ipairs({ "group", "crowded" }) do
                local rig = Rig({ [SMITE] = 2 }); Seed(rig, TRIGGER)
                local F = rig.ns.Fingerprints
                -- TRIGGER drawn with no row (unpaired), Smite drawn over its row
                Frozen(rig, area, { [TRIGGER] = 500, [SMITE] = 500 }, { Row(GRAVE, 56), Row(SMITE, 100) })
                local last = Step(rig, { [TRIGGER] = 500, [SMITE] = 200 }, { Row(GRAVE, 56), Row(SMITE, 100) })
                Check("frozen (" .. area .. "): its read leaves no strike for the next clear one: one strike each, kept",
                    last.area == "clear" and Kept(rig, TRIGGER) and rig.ns.Learn.List()[1].unpaired == 1
                    and F.Get(SMITE) ~= nil and F.Get(SMITE).strikes == 1)

                rig = Rig({}); Seed(rig, TRIGGER)
                Strike(rig, TRIGGER)
                Frozen(rig, area, { [TRIGGER] = 100 }, { Row(TRIGGER, 100) }) -- would agree
                Strike(rig, TRIGGER)
                Check("frozen (" .. area .. "): an agreeing read resets no strike: clear strike, " .. area
                    .. " agree, clear strike drops", not Kept(rig, TRIGGER))
            end

            local rig = Rig({ [SMITE] = 2 })
            local S, Core = rig.S, rig.ns.Core
            for _ = 1, 2 do Frozen(rig, "group", { [SMITE] = 500 }, { Row(SMITE, 100) }) end
            S.group, S.now = true, 99
            Core.PLAYER_REGEN_DISABLED()
            rig.Cast(100, "nameplate7", SMITE)
            local drawn = rig.Hit(100.25, "nameplate7", 30, 2)
            Check("frozen: after two group over reads your learned cast still draws and is tallied in a group (Core)",
                drawn == "tex:" .. SMITE and rig.ns.Teacher.fight.tally[SMITE] == 30)

            T.Store().paused = { [SMITE] = true }
            rig.ns.Teacher.Init(T.Store())
            Check("frozen: an older save's paused spells are discarded on load", T.Store().paused == nil)
        end

        do -- fingerprints keep their own rules; spells Learn does not know are untouched
            local rig = Rig({ [TRIGGER] = 32 }); Seed(rig, TRIGGER)
            local F = rig.ns.Fingerprints
            Step(rig, { [TRIGGER] = 200 }, { Row(TRIGGER, 100) })
            Check("net: dropping a learned spell leaves its fingerprint (over 1 from Fingerprints' own rule)",
                not Kept(rig, TRIGGER) and F.Get(TRIGGER) ~= nil and F.Get(TRIGGER).over == 1 and F.Get(TRIGGER).fights == 0)

            rig = Rig({ [SMITE] = 2 })
            for _ = 1, 3 do Strike(rig, SMITE) end
            Check("net: a fingerprinted spell Learn does not know is never struck: no entry, fingerprint unchanged",
                #rig.ns.Learn.List() == 0 and rig.ns.Fingerprints.Get(SMITE).fights == 0 and rig.ns.Fingerprints.Get(SMITE).over == 0)
        end

        do -- procs: the net judges learned procs by the same rules (spec 3.3)
            local PROC = 1287663
            local function Gone(rig) return rig.ns.Procs.Get(PROC) == nil end

            local rig = Rig({}); SeedProc(rig, PROC, true)
            Step(rig, { [PROC] = 60 }, { Row(PROC, 100) }) -- 60 seen of 100: clear, not short
            Check("net proc: an under read keeps the learned proc", not Gone(rig))
            Step(rig, { [PROC] = 200 }, { Row(PROC, 100) })
            Check("net proc: an over read drops it at once", Gone(rig))

            rig = Rig({}); SeedProc(rig, PROC, true)
            Strike(rig, PROC)
            Check("net proc: one unpaired read keeps it", not Gone(rig))
            Strike(rig, PROC)
            Check("net proc: the second unpaired read drops it", Gone(rig))

            rig = Rig({}); SeedProc(rig, PROC, true)
            Strike(rig, PROC)
            Step(rig, { [PROC] = 100 }, { Row(PROC, 100) }) -- agree
            Strike(rig, PROC)
            Check("net proc: strike, agree, strike keeps it", not Gone(rig))
            Strike(rig, PROC)
            Check("net proc: two strikes in a row after the reset drop it", Gone(rig))

            rig = Rig({}); SeedProc(rig, PROC, true)
            local last = Step(rig, { [PROC] = 6000 }, { Row(VT, 6000) }) -- the row agrees with the proc's tally
            Check("net proc rule 2: a learned proc is never given an alias: no alias, no pairing",
                rig.ns.Fingerprints.Alias(VT) == nil and Find(last, PROC).verdict == "unpaired"
                and Find(last, VT).verdict == "unpaired" and Find(last, VT).tally == 0)
            Check("net proc rule 2: it got one strike (kept now)", not Gone(rig))
            Step(rig, { [PROC] = 6000 }, { Row(VT, 6000) })
            Check("net proc rule 2: the same read again is the second strike and drops it", Gone(rig))

            rig = Rig({}); Seed(rig, PROC); SeedProc(rig, PROC, true) -- one ID known to Learn and to Procs
            Step(rig, { [PROC] = 200 }, { Row(PROC, 100) })
            Check("net proc: an over read drops the ID from both modules", Gone(rig) and rig.ns.Learn.Get(PROC) == nil)
            rig = Rig({}); Seed(rig, PROC); SeedProc(rig, PROC, true)
            Strike(rig, PROC); Strike(rig, PROC)
            Check("net proc: two strikes drop the ID from both modules", Gone(rig) and rig.ns.Learn.Get(PROC) == nil)

            rig = Rig({}); SeedProc(rig, PROC, false) -- a candidate: Procs.Get is nil, the net leaves it alone
            for _ = 1, 3 do Strike(rig, PROC) end
            local list = rig.ns.Procs.List()
            Check("net proc: a candidate is never struck or dropped (three unpaired reads, still streak 2)",
                #list == 1 and list[1].spellID == PROC and list[1].streak == 2 and not list[1].learned)

            rig = Rig({}); SeedProc(rig, PROC, true)
            Strike(rig, PROC)
            Step(rig, {}, { Row(PROC, 300) }) -- its own row, tally 0
            Check("net proc: a read with the proc's own row but tally 0 adds no strike", not Gone(rig))
            Strike(rig, PROC)
            Check("net proc: ... so the next unpaired read is the second and drops it", Gone(rig))
        end

        do -- a cast cast this fight with no meter row of its own loses its dot votes at the read: a DoT learned under it is always struck
            local WITHER, WITHER_ROW = 442726, 445468 -- the cast has no row; its ticks pay under another ID
            local function Votes(rig)
                T.Store().votes[WITHER] = { casts = 1, sigs = { { kind = "dot", school = 36, period = 1.0, votes = 1, expected = 0.06 } } }
                rig.ns.Learn.Init(T.Store())
            end
            -- One fight at `at`: the cast (and 5 school-36 hits 1.0 s apart when `hits`, else the rows' total seen
            -- undrawn, so the read is clear, not short), then its read against `rows`.
            local function Fight(rig, at, hits, rows)
                nextSession = nextSession + 1
                rig.S.sessions = { Session(nextSession, rows) }
                rig.ns.Teacher.Start(at)
                rig.Cast(at + 1, "nameplate1", WITHER)
                if hits then
                    for k = 1, 5 do rig.Hit(at + 1 + k, "nameplate1", 1000, 36) end
                else
                    local total = 0
                    for _, row in ipairs(rows) do total = total + row.totalAmount end
                    rig.ns.Teacher.Seen(total)
                end
                rig.ns.Teacher.Finish(at + 20)
                assert(pcall(rig.Fire))
            end

            local rig = Rig({}); Votes(rig)
            Fight(rig, 10, false, { Row(WITHER_ROW, 5000) })
            Check("net votes: a cast with no row of its own loses its dot sig at the read", #rig.ns.Learn.Votes(WITHER).sigs == 0)
            -- The ticks' row stays off their sum (5500 against 5 x 1000) in the fights with ticks: five ticks that are
            -- their school's whole '?' sum to the unit would learn the row as a castless proc at once (Procs' Whole)
            -- and draw them before any vote.
            Fight(rig, 100, true, { Row(WITHER_ROW, 5500) })
            Check("net votes: ... and its next cast and rhythm gets no vote, so nothing is learned",
                rig.ns.Learn.Get(WITHER) == nil and #rig.ns.Learn.Votes(WITHER).sigs == 0)
            -- The own row is more than the ticks pay (9000 against 5000), so the teacher's DoT pass leaves it to the
            -- votes.
            Fight(rig, 200, false, { Row(WITHER, 9000), Row(WITHER_ROW, 5500) })
            Fight(rig, 300, true, { Row(WITHER, 9000), Row(WITHER_ROW, 5500) })
            Check("net votes: ... until a read lists the cast's own row, after which its rhythm votes again",
                #rig.ns.Learn.Votes(WITHER).sigs == 1 and rig.ns.Learn.Votes(WITHER).sigs[1].votes == 1)

            rig = Rig({}); Votes(rig)
            Fight(rig, 10, false, { Row(WITHER, 5000), Row(WITHER_ROW, 5000) })
            Check("net votes: control, a cast whose own row is in the read keeps its sig", #rig.ns.Learn.Votes(WITHER).sigs == 1)
            Fight(rig, 100, true, { Row(WITHER, 5000), Row(WITHER_ROW, 5000) })
            Check("net votes: ... and its next cast and rhythm is the second vote and learns it", rig.ns.Learn.Get(WITHER) ~= nil)

            rig = Rig({}); Votes(rig)
            local sigs = T.Store().votes[WITHER].sigs
            sigs[2] = { kind = "hot", school = 2, period = 3.0, votes = 1, expected = 0.1 }
            Fight(rig, 10, false, { Row(WITHER_ROW, 5000) })
            local left = rig.ns.Learn.Votes(WITHER).sigs
            Check("net votes: a hot sig survives the read (heals have no damage row); the dot sig goes",
                #left == 1 and left[1].kind == "hot")

            rig = Rig({}); Votes(rig)
            Fight(rig, 10, false, { Row(WITHER_ROW, 5000) })
            rig.S.sessions = { Session(nextSession + 1, { Row(WITHER_ROW, 5000) }) }
            nextSession = nextSession + 1
            T.Store().votes[WITHER].sigs[1] = { kind = "dot", school = 36, period = 1.0, votes = 1, expected = 0.06 }
            rig.ns.Teacher.Start(100); rig.ns.Teacher.Finish(120)
            assert(pcall(rig.Fire))
            Check("net votes: a spell not cast this fight keeps its sigs (no cast since the fight began)",
                #rig.ns.Learn.Votes(WITHER).sigs == 1)
        end
    end

    do -- castless procs: what Teacher hands to Procs.Read (spec 3.1 inputs, 3.3) and the crit flag on '?' hits
        local X, Y = 1287663, 1286716
        local function ReadWith(rig, hits, rows, seen, group)
            nextSession = nextSession + 1
            local P1, meter, total = rig.Plate("nameplate1"), {}, 0
            for _, row in ipairs(rows) do
                meter[#meter + 1] = Row(row[1], row[2])
                total = total + row[2]
            end
            rig.S.sessions = { Session(nextSession, meter) }
            rig.ns.Teacher.Start(10, group)
            for _, hit in ipairs(hits) do
                local plate = hit[7] and rig.Plate(hit[7]) or P1
                rig.ns.Teacher.Unknown(plate, hit[1], hit[2], hit[5] or 60.25, hit[4], hit[3] or "", hit[6])
            end
            rig.ns.Teacher.Seen(seen or total)
            rig.ns.Teacher.Finish(20)
            return pcall(rig.Fire)
        end
        -- Records the arguments of the last Procs.Read call and still runs it.
        local function Spy(rig)
            local spy, read = { calls = 0 }, rig.ns.Procs.Read
            rig.ns.Procs.Read = function(hits, open, results, rows, at)
                spy.calls, spy.hits, spy.open, spy.results, spy.rows, spy.at = spy.calls + 1, hits, open, results, rows, at
                return read(hits, open, results, rows, at)
            end
            return spy
        end
        local function Candidate(rig, id)
            for _, entry in ipairs(rig.ns.Procs.List()) do
                if entry.spellID == id then return entry end
            end
        end
        local THREE = { { 106, 339 }, { 106, 350 }, { 106, 364 } } -- one size group, sum 1053

        do -- wiring: the .toc order and the login Init
            local order, position = {}, 0
            for line in io.lines(T.Root .. "/CombatTextIcons.toc") do
                position = position + 1
                order[(line:gsub("%s+$", ""))] = position
            end
            Check("procs wiring: the .toc lists Procs.lua after Fingerprints.lua and before Teacher.lua",
                order["Procs.lua"] and order["Procs.lua"] > order["Fingerprints.lua"] and order["Procs.lua"] < order["Teacher.lua"])
            local ns = T.Boot(function()
                CombatTextIconsCharDB = { procs = { [X] = { school = 106, lo = 339, hi = 364, streak = 3, learned = true,
                    unpaired = 0, seen = 0 } } }
            end)
            Check("procs wiring: PLAYER_LOGIN runs Procs.Init on the saved table (a saved learned proc is live)",
                ns.Procs ~= nil and ns.Procs.Get(X) ~= nil)
        end

        do -- the arguments of Procs.Read
            local rig = Rig({})
            local spy = Spy(rig)
            ReadWith(rig, THREE, { { X, 1053 } })
            local last = rig.ns.Teacher.last
            Check("procs wiring: a clear read calls Procs.Read once with the '?' hits (crit false), the open row, results, the meter rows, run.at",
                spy.calls == 1 and #spy.hits == 3 and spy.hits[1].school == 106 and spy.hits[1].amount == 339
                and spy.hits[1].crit == false and #spy.open == 1 and spy.open[1].row.spellID == X and spy.open[1].index == 1
                and spy.results == last.rows and #spy.rows == 1 and spy.rows[1].spellID == X and spy.at == 10)
            -- the three hits are their school's whole '?' sum, so the exact pair learns at once (Procs' Whole)
            Check("procs wiring: 339 + 350 + 364 = 1053 meets the row exactly and is the school's whole '?' sum: learned, streak 1",
                Candidate(rig, X) and Candidate(rig, X).streak == 1 and Candidate(rig, X).learned
                and Find(last, X).verdict == "agree")
        end

        do -- the fight's stream records reach Procs.Read as its 7th argument
            local rig = Rig({})
            local seventh, read = nil, rig.ns.Procs.Read
            rig.ns.Procs.Read = function(hits, open, results, rows, at, ticks, streams)
                seventh = streams
                return read(hits, open, results, rows, at, ticks, streams)
            end
            rig.S.sessions = { Session(1, { Row(X, 1053) }) }
            rig.ns.Teacher.Start(10)
            local record = rig.ns.Teacher.fight.streams
            for _, at in ipairs({ 0, 2, 4, 6 }) do rig.ns.Streams.Feed("k", 32, 1000, "", "enemy", at, true) end
            local count = 0
            for _ in pairs(record or {}) do count = count + 1 end
            Check("procs wiring: Start gives the fight a streams table that a recorded stream lands in", type(record) == "table" and count == 1)
            rig.ns.Teacher.Seen(1053)
            rig.ns.Teacher.Finish(20)
            rig.Fire()
            Check("procs wiring: Procs.Read gets the fight's streams table as its 7th argument", seventh ~= nil and seventh == record)
        end

        do -- Review Focus 3: a cast-pass-learned group is spent, the same cast's other-school group is not
            local rig = Rig({})
            local spy = Spy(rig)
            -- three Mind Blast casts (a fingerprint needs three distinct ones), each 0.25 s before its hit
            local function Cast(at) return { spellID = MIND_BLAST, base = MIND_BLAST, at = at } end
            ReadWith(rig, { { 32, 120, "", Cast(60), 60.25 }, { 32, 135, "", Cast(70), 70.25 }, { 32, 98, "", Cast(80), 80.25 },
                { 106, 350, "", Cast(60), 60.25 }, { 106, 350, "", Cast(60), 60.25 } },
                { { MIND_BLAST, 353 }, { X, 700 }, { Y, 704 } })
            Check("procs wiring: the cast pass still learns Mind Blast (120 + 135 + 98 = 353)", rig.ns.Fingerprints.IsLearned(MIND_BLAST))
            Check("procs wiring: Procs.Read gets the school-106 hits only, and the rows 700 and 704 only (spent hits and the learned row are gone)",
                spy.calls == 1 and #spy.hits == 2 and spy.hits[1].school == 106 and spy.hits[2].school == 106
                and #spy.open == 2 and spy.open[1].row.spellID == X and spy.open[2].row.spellID == Y)
            Check("procs wiring: 350 + 350 = 700 fits row 700 exactly and row 704 not: a candidate for 700 only (the cast pass saw two rows within 1 %)",
                Candidate(rig, X) and Candidate(rig, X).streak == 1 and Candidate(rig, Y) == nil)
        end

        do -- Rev 4: the cast pass never aliases a row Procs tracks; a cast's own row still pairs
            local function Cast(at) return { spellID = MIND_BLAST, base = MIND_BLAST, at = at } end
            local ONE = { { 106, 5551, "", Cast(60), 60.25 } } -- one Mind Blast hit, 5551
            local function Seed(rig, id, lo)
                T.Store().procs = { [id] = { school = 106, lo = lo, hi = 5827, streak = 1, learned = false,
                    unpaired = 0, seen = 0 } }
                rig.ns.Procs.Init(T.Store())
            end

            local rig = Rig({})
            Seed(rig, Y, 5814)
            local spy = Spy(rig)
            ReadWith(rig, ONE, { { Y, 5551 } })
            local F = rig.ns.Fingerprints
            local candidate = Candidate(rig, Y)
            Check("procs cast pass: a row Procs tracks is never aliased to a cast; its hit reaches Procs.Read (candidate 1286716: streak 2, band 5551-5827)",
                F.Alias(Y) == nil and F.Get(MIND_BLAST) == nil
                and spy.calls == 1 and #spy.hits == 1 and spy.hits[1].amount == 5551 and #spy.open == 1
                and spy.open[1].row.spellID == Y
                and candidate and candidate.streak == 2 and candidate.lo == 5551 and candidate.hi == 5827)

            rig = Rig({})
            spy = Spy(rig)
            ReadWith(rig, ONE, { { Y, 5551 } })
            Check("procs cast pass: with no Procs entry the cast pass still aliases the row (control)",
                rig.ns.Fingerprints.Alias(Y) == MIND_BLAST and #spy.hits == 0 and Candidate(rig, Y) == nil)

            rig = Rig({})
            Seed(rig, MIND_BLAST, 5814)
            ReadWith(rig, ONE, { { MIND_BLAST, 5551 } })
            local first = rig.ns.Teacher.last.rows[1]
            Check("procs cast pass: a cast's own row is not an alias and still pairs when Procs tracks that ID",
                rig.ns.Fingerprints.Get(MIND_BLAST) ~= nil and first.verdict == "agree" and first.spellID == MIND_BLAST)

            local Z = 1234567
            rig = Rig({})
            Seed(rig, Y, 5814)
            ReadWith(rig, ONE, { { Y, 5551 }, { Z, 5551 } })
            Check("procs cast pass: the skipped row does not make the group ambiguous (the other exact row 5551 is aliased)",
                rig.ns.Fingerprints.Alias(Z) == MIND_BLAST and rig.ns.Fingerprints.Alias(Y) == nil)
        end

        do -- Rev 5 (in-game 2026-10-25): a row belongs to its own spell, so the cast pass never aliases it away
            local function Cast(id, at) return { spellID = id, base = id, at = at } end

            -- Holy Retributor's Order: one holy proc hit 2364 inside a Mind Blast cast window, Mind Blast's own row present
            local rig = Rig({})
            ReadWith(rig, { { 2, 2364, "", Cast(MIND_BLAST, 60), 60.25 } }, { { MIND_BLAST, 192182 }, { Y, 2364 } })
            Check("cast pass: a cast whose own ID is a row this session gets no alias (proc 2364 is not Mind Blast's)",
                rig.ns.Fingerprints.Alias(Y) == nil and rig.ns.Fingerprints.Get(MIND_BLAST) == nil)

            -- Void Torrent: Void Blast's hits sum to the row of Void Torrent, which was cast in the same fight
            local Z = 1234567
            rig = Rig({})
            ReadWith(rig, { { 32, 5551, "", Cast(MIND_BLAST, 60), 60.25 }, { 32, 999, "", Cast(Z, 61), 61.25 } }, { { Z, 5551 } })
            Check("cast pass: the own row of another cast this fight is never aliased (Void Torrent's row is not Void Blast's)",
                rig.ns.Fingerprints.Alias(Z) == nil and rig.ns.Fingerprints.Get(MIND_BLAST) == nil)
        end

        do -- coverage (run 153349Z): a cross-ID pair needs the group in at least half the cast's casts
            local function Cast(id, at) return { spellID = id, base = id, at = at } end
            local Z, W = 1234567, 1234568
            -- Z cast at 60 .. last, a school-32 hit 100 after each; a holy 2364 lands only after the cast at 61
            local function Volley(last)
                local hits = {}
                for t = 60, last do hits[#hits + 1] = { 32, 100, "", Cast(Z, t), t + 0.25 } end
                hits[#hits + 1] = { 2, 2364, "", Cast(Z, 61), 61.25 }
                return hits
            end

            local rig = Rig({})
            ReadWith(rig, Volley(63), { { Y, 2364 } })
            local F = rig.ns.Fingerprints
            -- the holy hit is its school's whole '?' sum and equals the row: a castless proc at once (Procs' Whole), as
            -- Holy Retributor's Order 1260076 is (priest3 F1: one holy 2365 against its row 2365)
            Check("cast pass coverage: one holy hit after 1 of 4 casts makes no alias and no fingerprint; the row is the proc's",
                F.Alias(Y) == nil and F.Get(Z) == nil and rig.ns.Procs.Get(Y) ~= nil
                and Find(rig.ns.Teacher.last, Y).verdict == "agree")

            rig = Rig({})
            ReadWith(rig, Volley(61), { { Y, 2364 } })
            Check("cast pass coverage: 1 of 2 casts is half and still pairs under another ID",
                rig.ns.Fingerprints.Alias(Y) == Z)

            rig = Rig({})
            ReadWith(rig, Volley(62), { { Y, 2364 } })
            Check("cast pass coverage: 1 of 3 casts is below half: no alias", rig.ns.Fingerprints.Alias(Y) == nil)

            rig = Rig({})
            local hits = Volley(63)
            hits[#hits + 1] = { 2, 2364, "", Cast(W, 70), 70.25 }
            ReadWith(rig, hits, { { Y, 2364 } })
            Check("cast pass coverage: a blocked group is no agreement, so the one cast that covers its casts pairs alone",
                rig.ns.Fingerprints.Alias(Y) == W)
        end

        do -- base spell (in-game forget5): the meter files Void Blast under Mind Blast's row 8092
            local VOID_BLAST = 450983
            local rig = Rig({})
            local ns, S, F = rig.ns, rig.S, rig.ns.Fingerprints
            local keys = {}
            local add = ns.Ledger.Add
            ns.Ledger.Add = function(side, key, amount) keys[key] = true return add(side, key, amount) end
            -- One fight through Core, each cast { t, spellID, amount } at nameplate1 with its school-32 hit 0.25 s
            -- later, against a session of `rows`. Returns the textures drawn and the fight's tally.
            local function Fight(casts, rows)
                nextSession = nextSession + 1
                S.sessions, S.now = { Session(nextSession, rows) }, casts[1][1] - 1
                ns.Core.PLAYER_REGEN_DISABLED()
                local drawn, tally = {}, ns.Teacher.fight.tally
                for _, cast in ipairs(casts) do
                    rig.Cast(cast[1], "nameplate1", cast[2])
                    drawn[#drawn + 1] = rig.Hit(cast[1] + 0.25, "nameplate1", cast[3], 32) or false
                end
                S.now = S.now + 1
                ns.Core.PLAYER_REGEN_ENABLED()
                while #S.timers > 0 do rig.Fire() end
                return drawn, tally
            end

            local ok = pcall(Fight, { { 10, MIND_BLAST, 100 }, { 20, VOID_BLAST, 200 }, { 30, MIND_BLAST, 150 } },
                { Row(MIND_BLAST, 450) })
            local last = ns.Teacher.last
            Check("base spell: Mind Blast and Void Blast '?' hits (100 + 200 + 150) sum to row 8092 -> fingerprint 8092 learned, no alias",
                ok and last.learned[MIND_BLAST] == 3 and F.IsLearned(MIND_BLAST) and F.Get(VOID_BLAST) == nil
                and next(T.Store().castAliases) == nil and Find(last, MIND_BLAST).verdict == "agree")

            keys = {}
            local okLater, drawn, tally = pcall(Fight, { { 50, VOID_BLAST, 300 } }, { Row(MIND_BLAST, 300) })
            Check("base spell: a later Void Blast hit draws Void Blast's icon, tallies and ledgers under 8092, and agrees",
                okLater and drawn[1] == "tex:" .. VOID_BLAST and tally[MIND_BLAST] == 300 and tally[VOID_BLAST] == nil
                and keys[MIND_BLAST] and not keys[VOID_BLAST] and Find(ns.Teacher.last, MIND_BLAST).verdict == "agree"
                and F.Get(MIND_BLAST).fights == 1)
        end

        do -- one hit per cast (in-game forget5): a cast's window also takes untracked DoT ticks on its target
            local function Cast(id, at) return { spellID = id, base = id, at = at } end
            -- three Mind Blast casts, each with its direct hit; two windows also hold a 300 tick
            local HITS = { { 32, 1200, "", Cast(MIND_BLAST, 60), 60.25 }, { 32, 300, "", Cast(MIND_BLAST, 60), 61.0 },
                { 32, 1350, "", Cast(MIND_BLAST, 70), 70.25 }, { 32, 300, "", Cast(MIND_BLAST, 70), 71.0 },
                { 32, 980, "", Cast(MIND_BLAST, 80), 80.25 } }

            local rig = Rig({})
            local spy = Spy(rig)
            ReadWith(rig, HITS, { { MIND_BLAST, 3530 } })
            local last = rig.ns.Teacher.last
            Check("one hit per cast: 1200 + 300 + 1350 + 300 + 980 overshoots row 3530, each cast's largest (1200 + 1350 + 980) meets it -> learned from 3 hits",
                rig.ns.Fingerprints.IsLearned(MIND_BLAST) and last.learned[MIND_BLAST] == 3
                and Find(last, MIND_BLAST).verdict == "agree" and Find(last, MIND_BLAST).tally == 3530)
            Check("one hit per cast: the two ticks are not spent, Procs.Read gets them",
                spy.calls == 1 and #spy.hits == 2 and spy.hits[1].amount == 300 and spy.hits[2].amount == 300)

            local Z = 1234567
            rig = Rig({})
            ReadWith(rig, HITS, { { Z, 3530 } })
            Check("one hit per cast: each cast's largest never aliases a row of another ID",
                rig.ns.Fingerprints.Alias(Z) == nil and rig.ns.Fingerprints.Get(MIND_BLAST) == nil)
        end

        do -- each cast's largest by candidates (run lock F1): a hit whose frame holds another cast has no sole cast
            local Z, W = 1234567, 1234568
            local function Candidate(id, at) return { castID = id, castAt = at, castSpell = id } end
            -- Z cast at 60, 70 and 80, W 0.3 s after each: Z's 1060 / 1070 / 1080 hit and a 200 tick name both casts
            local HITS = {}
            for _, t in ipairs({ 60, 70, 80 }) do
                local candidates = { Candidate(Z, t), Candidate(W, t + 0.3) }
                HITS[#HITS + 1] = { 32, 1000 + t, "", nil, t + 0.5, candidates }
                HITS[#HITS + 1] = { 32, 200, "", nil, t + 1.0, candidates }
            end

            local rig = Rig({})
            ReadWith(rig, HITS, { { Z, 3210 } })
            local F, last = rig.ns.Fingerprints, rig.ns.Teacher.last
            local delays = {}
            for _, sample in ipairs(F.Get(Z) and F.Get(Z).samples or {}) do delays[#delays + 1] = sample.delay end
            Check("candidates: no hit has a sole cast; Z's largest per cast (1060 + 1070 + 1080) meets row 3210 -> Z learned from 3 hits at 0.5 s, W nothing",
                F.IsLearned(Z) and last.learned[Z] == 3 and Find(last, Z).verdict == "agree" and F.Get(W) == nil
                and #delays == 3 and math.abs(delays[1] - 0.5) < 1e-9 and math.abs(delays[3] - 0.5) < 1e-9)

            rig = Rig({})
            ReadWith(rig, HITS, { { Y, 3210 } })
            Check("candidates: each cast's largest never pairs a row of another ID (no alias, no fingerprint)",
                rig.ns.Fingerprints.Alias(Y) == nil and rig.ns.Fingerprints.Get(Z) == nil and rig.ns.Fingerprints.Get(W) == nil)

            -- Z cast at 60 and 61: the 1100 hit names both casts and goes to the newest, so 1000 + 1100 meets row 2100
            rig = Rig({})
            ReadWith(rig, { { 32, 1000, "", nil, 60.5, { Candidate(Z, 60) } },
                { 32, 1100, "", nil, 61.2, { Candidate(Z, 60), Candidate(Z, 61) } } }, { { Z, 2100 } })
            Check("candidates: a hit naming two casts of one base counts for the newest only (1000 + 1100 meets 2100, not 1100 twice)",
                rig.ns.Teacher.last.learned[Z] == 2 and #rig.ns.Fingerprints.Get(Z).samples == 2)

            -- Run shaman5: Lava Burst learned on an AoE pack (~42K at 0.20-0.28 s) missed a lone dummy's 69K hit at 0.12 s
            -- and its row matched it. Z learned at 0.5 s from 1000-1100: a 1500 hit at 0.1 s alone meets its row.
            local function Learned(r)
                for index, size in ipairs({ 1000, 1050, 1100 }) do
                    r.ns.Fingerprints.Add(Z, { school = 32, delay = 0.5, castAt = index, hops = 1, spell = Z, size = size })
                end
            end
            rig = Rig({})
            Learned(rig)
            ReadWith(rig, { { 32, 1500, "", nil, 60.1, { Candidate(Z, 60) } } }, { { Z, 1500 } })
            last = rig.ns.Teacher.last
            Check("candidates: a learned base's missed in-band hit meets its own row -> one more sample at 0.1 s",
                last.learned[Z] == 1 and Find(last, Z).verdict == "agree" and #rig.ns.Fingerprints.Get(Z).samples == 4
                and math.abs(rig.ns.Fingerprints.Get(Z).samples[4].delay - 0.1) < 1e-9)
            rig = Rig({})
            Learned(rig)
            ReadWith(rig, { { 32, 5000, "", nil, 60.1, { Candidate(Z, 60) } } }, { { Z, 5000 } })
            Check("candidates: a learned base's hit out of its padded band (5000 over 2 x 1100) learns nothing though its row meets it",
                rig.ns.Teacher.last.learned[Z] == nil and #rig.ns.Fingerprints.Get(Z).samples == 3)

            -- Run shaman5 F1: rowless Voltaic Blaze 470057 hit 5 plates in its cast frame, 3 casts, and only the
            -- target's hit named the cast; all 15 summed to row 1259101 (789844 of 789850). Z cast at 60, 70, 80 hits 3 plates
            -- (1000 on the target, 1020 and 980 beside it); a 200 hit of another spell shares each frame on nameplate2.
            local AREA = {}
            for _, t in ipairs({ 60, 70, 80 }) do
                AREA[#AREA + 1] = { 32, 1000, "", nil, t, { Candidate(Z, t) } }
                AREA[#AREA + 1] = { 32, 1020, "", nil, t, nil, "nameplate2" }
                AREA[#AREA + 1] = { 32, 980, "", nil, t, nil, "nameplate3" }
                AREA[#AREA + 1] = { 32, 200, "", nil, t, nil, "nameplate2" }
            end
            rig = Rig({})
            ReadWith(rig, AREA, { { Y, 9000 } })
            F, last = rig.ns.Fingerprints, rig.ns.Teacher.last
            Check("candidates: a cast's largest and its like-sized frame mates on other plates (3 x 3000) meet row 9000 of "
                .. "another ID -> alias, Z learned from 9 hits as a chain; the 200 hits are no mates",
                F.Alias(Y) == Z and F.IsLearned(Z) and F.Get(Z).pattern == "chain" and last.learned[Z] == 9
                and Find(last, Z).verdict == "agree")
            rig = Rig({})
            ReadWith(rig, AREA, { { Y, 9600 } })
            Check("candidates: frame mates of another size never join the sum (9600 counts the 200 hits): nothing learned",
                rig.ns.Fingerprints.Alias(Y) == nil and rig.ns.Fingerprints.Get(Z) == nil)
            rig = Rig({})
            ReadWith(rig, { AREA[1], AREA[2], AREA[3], AREA[5], AREA[9] }, { { Y, 5000 } })
            Check("candidates: a cast whose largest has no frame mate keeps the top-only rule: no row of another ID (5000)",
                rig.ns.Fingerprints.Alias(Y) == nil)

            -- Run shaman6 F2: Earthquake's cand met row 157348 of another ID from hits at 0.10, 0.79 and 1.29 s after
            -- its casts, then drew castless bursts as Earthquake. The same 9 hits 0.1 / 0.8 / 1.3 s after Z's casts.
            local LATE = {}
            for index, hit in ipairs(AREA) do
                local delay = ({ 0.1, 0.8, 1.3 })[math.ceil(index / 4)]
                LATE[index] = { hit[1], hit[2], hit[3], hit[4], hit[5] + delay, hit[6], hit[7] }
            end
            rig = Rig({})
            ReadWith(rig, LATE, { { Y, 9000 } })
            Check("candidates: frame mates whose delays span 1.2 s (past 0.3) meet row 9000 of another ID -> no alias",
                rig.ns.Fingerprints.Alias(Y) == nil and rig.ns.Fingerprints.Get(Z) == nil)

            -- Ele log F3: Lightning Bolt 188196's row held each bolt and its ~0.45x Elemental Overloads, and Lava Burst
            -- shared its cast stamp. Z cast with W on each stamp (Z alone if `alone`): a 1000 bolt at 0.2 s and a 450
            -- overload at 0.6 s.
            local function Bolts(times, alone)
                local hits = {}
                for _, t in ipairs(times) do
                    local candidates = alone and { Candidate(Z, t) } or { Candidate(Z, t), Candidate(W, t) }
                    hits[#hits + 1] = { 32, 1000, "", nil, t + 0.2, candidates }
                    hits[#hits + 1] = { 32, 450, "", nil, t + 0.6, candidates }
                end
                return hits
            end
            rig = Rig({})
            ReadWith(rig, Bolts({ 60, 65, 70 }), { { Z, 4350 } })
            F, last = rig.ns.Fingerprints, rig.ns.Teacher.last
            Check("candidates: a 3-cast kill's bolts and overloads (3 x 1450) meet row 4350, each cast's largest "
                .. "(3000) falls under -> Z learned from all 6 hits, W nothing",
                F.IsLearned(Z) and last.learned[Z] == 6 and Find(last, Z).verdict == "agree" and #F.Get(Z).samples == 6
                and F.Get(W) == nil)
            rig = Rig({})
            ReadWith(rig, Bolts({ 60, 65, 70, 75 }, true), { { Z, 5800 } })
            F, last = rig.ns.Fingerprints, rig.ns.Teacher.last
            Check("candidates: with 4 casts every hit's sum (5800) stays out for the steady pass -> "
                .. "Z learns its 4 bolts",
                last.learned[Z] == 4 and #F.Get(Z).samples == 4 and F.Get(Z).samples[4].size == 1000)
        end

        do -- Rev 4b: the saved-alias pass and rule 2 never pair a row Procs tracks
            local function Meter(rig, id)
                nextSession = nextSession + 1
                return rig.Read({ [MIND_BLAST] = { 5551 } }, { Session(nextSession, { Row(id, 5551) }) })
            end

            local rig = Rig({})
            rig.ns.Fingerprints.SetAlias(Y, MIND_BLAST)
            SeedProc(rig, Y, true)
            local _, last = Meter(rig, Y)
            local row, drawn = Find(last, Y), Find(last, MIND_BLAST)
            Check("procs alias pass: a saved alias Y -> Mind Blast does not pair the row of a learned proc Y (Y open, Mind Blast missing)",
                row and row.verdict == "unpaired" and drawn and drawn.verdict == "unpaired" and drawn.meterID == MIND_BLAST
                and drawn.meter == 0)

            rig = Rig({})
            rig.ns.Fingerprints.SetAlias(Y, MIND_BLAST)
            _, last = Meter(rig, Y)
            drawn = Find(last, MIND_BLAST)
            Check("procs alias pass: with no proc the same saved alias pairs the row (control)",
                drawn and drawn.verdict == "agree" and drawn.meterID == Y)

            -- Run shaman6 F3: Voltaic Blaze aliased to two rows met one exactly and was judged against the other.
            rig = Rig({})
            rig.ns.Fingerprints.SetAlias(Y, MIND_BLAST)
            rig.ns.Fingerprints.SetAlias(X, MIND_BLAST)
            nextSession = nextSession + 1
            _, last = rig.Read({ [MIND_BLAST] = { 5551 } }, { Session(nextSession, { Row(Y, 5551), Row(X, 300) }) })
            drawn = Find(last, MIND_BLAST)
            Check("alias pass: a cast aliased to two open rows pairs the one that agrees (5551 with Y, not 300 with X)",
                drawn and drawn.verdict == "agree" and drawn.meterID == Y)

            rig = Rig({})
            SeedProc(rig, Y, false) -- candidate, streak 2
            _, last = Meter(rig, Y)
            Check("procs rule 2: the only agreeing row is a candidate's (streak >= 1): no alias, nothing paired",
                rig.ns.Fingerprints.Alias(Y) == nil and Find(last, Y) and Find(last, Y).verdict == "unpaired"
                and Find(last, MIND_BLAST) and Find(last, MIND_BLAST).verdict == "unpaired")

            rig = Rig({})
            T.Store().procs = { [Y] = { school = 106, lo = 339, hi = 364, streak = 0, learned = false, unpaired = 0, seen = 0 } }
            rig.ns.Procs.Init(T.Store())
            Meter(rig, Y)
            Check("procs rule 2: a streak-0 candidate does not block the alias (Rev 4b)", rig.ns.Fingerprints.Alias(Y) == MIND_BLAST)

            rig = Rig({})
            Meter(rig, Y)
            Check("procs rule 2: with no Procs entry the row is aliased to the drawn spell (control)",
                rig.ns.Fingerprints.Alias(Y) == MIND_BLAST)
        end

        do -- the crit rule is Procs.Crit
            local rig = Rig({})
            local seenFlag
            rig.ns.Procs.Crit = function(flag) seenFlag = flag; return "stub" end
            rig.ns.Teacher.Start(10)
            rig.ns.Teacher.Unknown(rig.Plate("nameplate1"), 106, 350, 1, nil, "CRITICAL")
            Check("procs wiring: Teacher.Unknown takes the entry's crit from Procs.Crit",
                seenFlag == "CRITICAL" and rig.ns.Teacher.fight.unknown[1].crit == "stub")
        end

        do -- only clear reads learn
            local rig = Rig({})
            local spy = Spy(rig)
            ReadWith(rig, THREE, { { X, 1053 } }, 1e9)
            Check("procs wiring: a crowded read does not call Procs.Read", rig.ns.Teacher.last.area == "crowded"
                and spy.calls == 0 and Candidate(rig, X) == nil)
            ReadWith(rig, THREE, { { X, 1053 } }, nil, true)
            Check("procs wiring: a group fight does not call Procs.Read", rig.ns.Teacher.last.area == "group"
                and spy.calls == 0 and Candidate(rig, X) == nil)
        end

        do -- Review Focus 4: clear at hit time, crowded at read time: no learning; the frozen read strikes nothing
            local cases = { { total = 100, verdict = "over" }, { total = 350, verdict = "agree" } }
            for _, case in ipairs(cases) do
                local rig = Rig({}); SeedProc(rig, X, true)
                local spy = Spy(rig)
                nextSession = nextSession + 1
                rig.S.sessions = { Session(nextSession, { Row(X, case.total) }) }
                rig.ns.Teacher.Start(10)
                rig.ns.Teacher.Drawn(X, 350) -- what the proc route drew while the area was clear
                rig.ns.Teacher.Seen(1e9)
                rig.ns.Teacher.Finish(20)
                pcall(rig.Fire)
                Check("procs wiring: crowded read, drawn 350 against " .. case.total .. " -> " .. case.verdict
                    .. ", proc kept with no strike, Procs.Read not called",
                    rig.ns.Teacher.last.area == "crowded" and Find(rig.ns.Teacher.last, X).verdict == case.verdict
                    and rig.ns.Procs.Get(X) ~= nil and rig.ns.Procs.Get(X).unpaired == 0 and spy.calls == 0)
            end
        end

        do -- the crit flag on the stored '?' entry (spec 3.1)
            local rig = Rig({})
            local Teacher, P1 = rig.ns.Teacher, rig.Plate("nameplate1")
            Teacher.Start(10)
            Teacher.Unknown(P1, 106, 350, 1, nil, "")
            Teacher.Unknown(P1, 106, 700, 1, nil, "CRITICAL")
            Teacher.Unknown(P1, 106, 50, 1, nil, "ABSORB")
            local u = Teacher.fight.unknown
            Check("procs wiring: a plain flag gives crit false ('') or true ('CRITICAL'); any other plain flag is false",
                #u == 3 and u[1].crit == false and u[2].crit == true and u[3].crit == false)
            Teacher.Unknown(P1, 106, 350, 1, nil, Secret("CRITICAL"))
            Teacher.Unknown(P1, 106, 350, 1, nil, nil)
            Teacher.Unknown(P1, 106, 350, 1)
            u = Teacher.fight.unknown
            Check("procs wiring: a secret, nil or missing flag gives crit nil (an orphan for the learner)",
                #u == 6 and u[4].crit == nil and u[5].crit == nil and u[6].crit == nil)
        end

        do -- one spell, one owner: a row a fingerprint-learned spell owns never becomes a proc candidate
            local rig = Rig({ [SMITE] = 2 })
            ReadWith(rig, THREE, { { SMITE, 1053 } })
            Check("procs wiring: guard: the open row of a learned fingerprint (591) makes no proc candidate",
                rig.ns.Teacher.last.area == "clear" and #rig.ns.Procs.List() == 0)
        end

        do -- three clear fights with the same exact row learn the proc; the learned row reads as agree
            -- (a stray 50000 hit no row explains keeps the school from splitting whole, so each pair counts one fight)
            local rig = Rig({})
            SlashCmdList.COMBATTEXTICONS("debug")
            local fights = {
                { { 106, 339 }, { 106, 350 }, { 106, 364 }, { 106, 50000 } },
                { { 106, 340 }, { 106, 352 }, { 106, 361 }, { 106, 50000 } },
                { { 106, 345 }, { 106, 348 }, { 106, 360 }, { 106, 50000 } },
            }
            local streaks = {}
            for index, hits in ipairs(fights) do
                ReadWith(rig, hits, { { X, 1053 } })
                streaks[index] = Candidate(rig, X) and Candidate(rig, X).streak
            end
            Check("procs wiring: streaks after fights 1, 2, 3 are 1, 2, 3",
                streaks[1] == 1 and streaks[2] == 2 and streaks[3] == 3)
            local row = Find(rig.ns.Teacher.last, X)
            Check("procs wiring: after fight 3 the proc is learned (Procs.Get) and its row reads agree, tally 1053",
                rig.ns.Procs.Get(X) ~= nil and row.verdict == "agree" and row.tally == 1053 and row.meter == 1053)
            local line = false
            for _, text in ipairs(CombatTextIconsDB.debugLog) do
                if text:find("TEACH proc " .. X, 1, true) and text:find("learned", 1, true) then line = true end
            end
            Check("procs wiring: the debug log holds a 'TEACH proc 1287663 ... learned' line", line)
        end
    end
    do -- castless procs: the Core route (spec 3.2)
        local X = 1287663
        -- A solo fight, proc X learned (school 106, normals 339-364), debug on, the fight open.
        local function ProcRig()
            local rig = Rig({})
            SlashCmdList.COMBATTEXTICONS("debug")
            SeedProc(rig, X, true)
            rig.S.now = 9
            rig.ns.Core.PLAYER_REGEN_DISABLED()
            return rig
        end
        -- One school-106 WOUND on nameplate1; returns the texture drawn, or nil when it stayed hidden.
        local function Wound(rig, amount, flag)
            local before = #rig.draws
            rig.S.now = rig.S.now + 1
            rig.ns.Core.UNIT_COMBAT("nameplate1", "WOUND", flag or "", amount, 106)
            return #rig.draws > before and rig.draws[#rig.draws] or nil
        end

        local rig = ProcRig()
        local ICON, UNKNOWN = "tex:" .. X, rig.ns.Meter.UNKNOWN_ICON
        local drawn = { Wound(rig, 350), Wound(rig, 700, "CRITICAL"), Wound(rig, 700), Wound(rig, 200),
            Wound(rig, 350, Secret("")), Wound(rig, 700, Secret("")) }
        Check("procs route: icon by fit: 350 normal, 700 crit and a secret flag (350, 700) draw the proc; 700 normal and 200 draw ?",
            drawn[1] == ICON and drawn[2] == ICON and drawn[3] == UNKNOWN and drawn[4] == UNKNOWN
            and drawn[5] == ICON and drawn[6] == ICON)
        local fight, current = rig.ns.Teacher.fight, rig.ns.Ledger.Current()
        Check("procs route: proc hits are tallied and in the Ledger (4 hits, 2100), the two ? hits are Unknown entries, all six count as seen",
            fight.tally[X] == 2100 and #fight.unknown == 2 and fight.unknown[1].amount == 700 and fight.unknown[2].amount == 200
            and current.damage[X].amount == 2100 and current.damage[X].hits == 4 and current.damage["?106"].hits == 2
            and fight.seen == 3000)
        Check("procs route: the debug log holds the proc route line and the ? route line", Logged("  -> proc " .. X)
            and Logged("  -> unknown-solo"))

        rig = ProcRig()
        rig.ns.Teacher.area = "crowded"
        local hidden, hiddenCrit = Wound(rig, 350), Wound(rig, 350, "CRITICAL")
        local u = rig.ns.Teacher.fight.unknown
        Check("procs route: crowded -> the proc hit stays hidden and is an Unknown entry (crit false, then true), not tallied, no proc route",
            hidden == nil and hiddenCrit == nil and #u == 2 and u[1].crit == false and u[2].crit == true
            and rig.ns.Teacher.fight.tally[X] == nil and Logged("HIDDEN (crowded)") and not Logged("-> proc"))

        rig = ProcRig()
        rig.ns.Teacher.area = "unknown" -- a map no read decided yet
        local procHit, stray = Wound(rig, 350), Wound(rig, 200)
        Check("procs route: a new area -> the proc hit draws and is tallied; a hit no proc names stays hidden",
            procHit == ICON and stray == nil and rig.ns.Teacher.fight.tally[X] == 350
            and #rig.ns.Teacher.fight.unknown == 1 and Logged("HIDDEN (new area)") and not Logged("-> unknown-solo"))
        rig = ProcRig()
        rig.ns.Teacher.area = "unknown"
        rig.ns.Teacher.fight.crowded = true -- the live crowd check fired
        Check("procs route: a new area whose fight turned crowded hides the proc hit",
            Wound(rig, 350) == nil and Logged("HIDDEN (crowded)") and not Logged("-> proc"))

        rig = ProcRig()
        Wound(rig, 350)
        local soloGroup = rig.ns.Teacher.fight.group
        rig = ProcRig()
        rig.S.group = true
        Check("procs route: in a group the proc hit stays hidden and unrecorded",
            Wound(rig, 350) == nil and #rig.ns.Teacher.fight.unknown == 0 and rig.ns.Teacher.fight.tally[X] == nil
            and not Logged("-> proc"))
        Check("group: a wound while grouped makes the fight a group fight; a solo wound does not",
            not soloGroup and rig.ns.Teacher.fight.group == true)

        rig = ProcRig()
        rig.S.threat.nameplate1 = false
        Check("procs route: a mob not fighting you gets no proc icon",
            Wound(rig, 350) == nil and rig.ns.Teacher.fight.tally[X] == nil and not Logged("-> proc"))

        rig = ProcRig()
        rig.ns.Meter.Disable("test")
        Check("procs route: meter off -> hidden, an Unknown entry, no proc icon",
            Wound(rig, 350) == nil and #rig.ns.Teacher.fight.unknown == 1 and Logged("HIDDEN (meter off)")
            and not Logged("-> proc"))

        rig = ProcRig()
        local flagSeen
        local unknown = rig.ns.Teacher.Unknown
        rig.ns.Teacher.Unknown = function(plate, school, amount, now, cast, flagText)
            flagSeen = flagText
            return unknown(plate, school, amount, now, cast, flagText)
        end
        rig.ns.Tracker.Identify = function() return rig.ns.Tracker.UNKNOWN end
        local trackerUnknown = Wound(rig, 700, "CRITICAL")
        local unnamed = Wound(rig, 5000, "CRITICAL")
        Check("procs route: a learned proc beats the Tracker UNKNOWN answer (700 crit); a hit it does not name draws ? and hands flagText to Teacher.Unknown",
            trackerUnknown == ICON and rig.ns.Teacher.fight.tally[X] == 700 and unnamed == UNKNOWN and flagSeen == "CRITICAL")

        -- Run 20261025T194314Z: Wither 445468, cast in the opener's frame, learned castless proc X's ticks by votes;
        -- the tracker then drew them before the proc could, so the proc's row went unpaired.
        rig = ProcRig()
        local VOTED, OTHER = 445468, 446285
        rig.ns.Learn.Get = function(id) if id == VOTED then return { school = 106, period = 1, kind = "dot", misses = 0 } end end
        rig.ns.Tracker.Identify = function() return VOTED end
        local stolen, ticked = Wound(rig, 350), Wound(rig, 5000)
        rig.ns.Tracker.Identify = function() return OTHER end
        local kept = Wound(rig, 350)
        local ticks = rig.ns.Teacher.fight.ticks
        Check("procs route: a learned proc beats a vote-learned DoT's answer (350); the DoT draws what the proc does not name (5000)"
            .. " and keeps it as a tick for Procs; a tracker answer Learn does not hold still draws",
            stolen == ICON and ticked == "tex:" .. VOTED and #ticks == 1 and ticks[1].amount == 5000 and ticks[1].school == 106
            and kept == "tex:" .. OTHER)

        rig = ProcRig() -- X learned; add a candidate
        T.Store().procs[900001] = { school = 106, lo = 100, hi = 110, streak = 1, learned = false, unpaired = 0, seen = 0 }
        rig.ns.Procs.Init(T.Store())
        local before = #rig.ns.Procs.List()
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("procs forget: /cti forget clears learned procs and candidates (2 before), in the saved table too",
            before == 2 and rig.ns.Procs.Get(X) == nil and #rig.ns.Procs.List() == 0 and next(T.Store().procs) == nil)
    end
    do -- rhythm procs: the Core route (a hit that extends or births a stream fitting a learned rhythm entry)
        local X = 1262710
        local function RhythmRig()
            local rig = Rig({})
            SlashCmdList.COMBATTEXTICONS("debug")
            T.Store().procs = { [X] = { school = 106, period = 1.0, lo = 340, hi = 365, learned = true,
                streak = 2, unpaired = 0, seen = 0 } }
            rig.ns.Procs.Init(T.Store())
            rig.S.now = 9
            rig.ns.Core.PLAYER_REGEN_DISABLED()
            return rig
        end
        -- One school-106 WOUND of 350 on nameplate1, one second after the last; returns the texture drawn or nil.
        local function Wound(rig) return rig.Hit(rig.S.now + 1, "nameplate1", 350, 106) end

        local rig = RhythmRig()
        local ICON, UNKNOWN = "tex:" .. X, rig.ns.Meter.UNKNOWN_ICON
        local drawn = { Wound(rig), Wound(rig), Wound(rig), Wound(rig) }
        Check("rhythm route: 4 wounds of 350 one second apart -> the first draws ?, the 2nd and 3rd pair with the loose tick"
            .. " a period before (Procs.NamePair), the 4th (the stream's birth) draws by its stream",
            drawn[1] == UNKNOWN and drawn[2] == ICON and drawn[3] == ICON and drawn[4] == ICON)
        Check("rhythm route: the rhythm hits are tallied (3 x 350) and in the Ledger (3 hits), and the debug log holds the rhythm route line",
            rig.ns.Teacher.fight.tally[X] == 1050 and rig.ns.Ledger.Current().damage[X].hits == 3 and Logged("  -> rhythm " .. X))

        rig = RhythmRig()
        local fifth = { Wound(rig), Wound(rig), Wound(rig), Wound(rig) }
        rig.ns.Procs.Forget()
        Check("rhythm route: Procs.Forget mid-stream -> the next hit draws ?, no further tally",
            fifth[4] == ICON and Wound(rig) == UNKNOWN and rig.ns.Teacher.fight.tally[X] == 1050)

        -- The pair route's guards: the loose tick a period before must be like-sized, the band's only hit since, not
        -- physical, and no unlearned cast may have made the hit.
        local function Pair(r, first, second, gap, school, unit2)
            r.Hit(10, "nameplate1", first, school or 106)
            return r.Hit(10 + (gap or 1), unit2 or "nameplate1", second, school or 106)
        end
        rig = RhythmRig()
        Check("rhythm pair: a second in-band hit one period after the first on the plate draws the rhythm icon",
            Pair(rig, 350, 350) == ICON and rig.ns.Teacher.fight.tally[X] == 350)
        rig = RhythmRig()
        Check("rhythm pair: two periods apart (no tick between) -> ?", Pair(rig, 350, 350, 2) == UNKNOWN)
        rig = RhythmRig()
        Check("rhythm pair: the first tick on another plate -> ?", Pair(rig, 350, 350, 1, nil, "nameplate2") == UNKNOWN)
        rig = RhythmRig()
        rig.ns.Procs.Forget()
        T.Store().procs = { [X] = { school = 106, period = 1.0, lo = 300, hi = 400, learned = true,
            streak = 2, unpaired = 0, seen = 0 } }
        rig.ns.Procs.Init(T.Store())
        Check("rhythm pair: both in the band but not like-sized (300 then 395, past SIZE_GUARD) -> ?",
            Pair(rig, 300, 395) == UNKNOWN)
        rig = RhythmRig()
        rig.Hit(10, "nameplate1", 350, 106)
        rig.Hit(10.5, "nameplate1", 355, 106)
        Check("rhythm pair: another in-band hit since the tick a period before (a crowd) -> ?",
            rig.Hit(11, "nameplate1", 350, 106) == UNKNOWN)
        rig = RhythmRig()
        T.Store().procs[X].school = 1
        rig.ns.Procs.Init(T.Store())
        Check("rhythm pair: a physical rhythm never pairs (swings and GCD strikes pair a period apart)",
            Pair(rig, 350, 350, 1, 1) ~= ICON and rig.ns.Teacher.fight.tally[X] == nil)
        rig = RhythmRig()
        rig.Hit(10, "nameplate1", 350, 106)
        rig.Cast(10.6, "nameplate1", 8092)
        Check("rhythm pair: an unlearned cast at the plate in the hit's window -> ?",
            rig.Hit(11, "nameplate1", 350, 106) == UNKNOWN)
        -- run mage F6: Arcane Missiles 5143, once a learned DoT, left the cast list, so its off-beat ticks paired as
        -- the mislearned rhythm proc 153626 (8312 -> 15198 wrong).
        local MISSILES = 5143
        rig = RhythmRig()
        T.Store().learned = { [MISSILES] = { school = 106, period = 3, kind = "dot", misses = 0 } }
        rig.ns.Learn.Init(T.Store())
        rig.Hit(10, "nameplate1", 350, 106)
        rig.Cast(10.6, "nameplate1", MISSILES)
        Check("rhythm pair: a learned DoT's cast at the plate in the hit's window, of the hit's school -> ?",
            rig.Hit(11, "nameplate1", 350, 106) == UNKNOWN and rig.ns.Teacher.fight.tally[X] == nil)

        rig = RhythmRig()
        rig.ns.Teacher.area = "crowded"
        for _ = 1, 4 do Wound(rig) end
        Check("rhythm route: crowded -> no rhythm route", rig.ns.Teacher.fight.tally[X] == nil and not Logged("-> rhythm"))

        rig = RhythmRig()
        rig.S.group = true
        for _ = 1, 4 do Wound(rig) end
        Check("rhythm route: in a group -> no rhythm route", rig.ns.Teacher.fight.tally[X] == nil and not Logged("-> rhythm"))

        rig = RhythmRig()
        rig.S.threat.nameplate1 = false
        for _ = 1, 4 do Wound(rig) end
        Check("rhythm route: a mob not fighting you -> no rhythm route", rig.ns.Teacher.fight.tally[X] == nil and not Logged("-> rhythm"))

        -- A lone hit before any stream is born: a logged cast of the entry's ID, 0.4 s earlier, names it.
        local function CastRig(castID, castUnit)
            local r = RhythmRig()
            if castID then r.Cast(10, castUnit or "nameplate1", castID) end
            return r
        end
        local function Lone(r, amount, flag) return r.Hit(10.4, "nameplate1", amount, 106, flag) end

        rig = CastRig(X)
        Check("rhythm cast: a lone in-band hit 0.4 s after a cast of the entry's ID draws the rhythm icon, tallied, with the route line",
            Lone(rig, 350) == ICON and rig.ns.Teacher.fight.tally[X] == 350 and Logged("  -> rhythm " .. X))
        rig = CastRig(nil)
        Check("rhythm cast: the same hit with no cast draws ?", Lone(rig, 350) == UNKNOWN and not Logged("-> rhythm"))
        rig = CastRig(8092)
        Check("rhythm cast: a cast of another ID draws ?", Lone(rig, 350) == UNKNOWN and not Logged("-> rhythm"))
        rig = CastRig(X)
        Check("rhythm cast: an out-of-band hit (200) draws ? despite the cast", Lone(rig, 200) == UNKNOWN and not Logged("-> rhythm"))
        rig = CastRig(X)
        Check("rhythm cast: a crit at twice the band (700, flag CRITICAL) with the cast draws the rhythm icon",
            Lone(rig, 700, "CRITICAL") == ICON and Logged("  -> rhythm " .. X))
        rig = CastRig(X)
        rig.S.threat.nameplate1, rig.S.target = false, nil -- the cast targeted the mob, which would make it fight you
        Lone(rig, 350)
        Check("rhythm cast: a mob not fighting you gets no rhythm icon", rig.ns.Teacher.fight.tally[X] == nil and not Logged("-> rhythm"))
        rig = CastRig(X)
        rig.ns.Teacher.area = "crowded"
        Lone(rig, 350)
        Check("rhythm cast: crowded -> no rhythm route", rig.ns.Teacher.fight.tally[X] == nil and not Logged("-> rhythm"))
    end

    do -- Teacher.OnRead: called once per fight with Teacher.last, at the end of Read and on every skip path
        local function HookRig()
            local rig = Rig({ [SMITE] = 2 })
            rig.calls, rig.teach = {}, {}
            rig.ns.Debug = function(format, ...)
                local line = string.format(format, ...)
                if line:find("^TEACH ") then rig.teach[#rig.teach + 1] = line end
            end
            rig.ns.Teacher.OnRead = function(last)
                rig.calls[#rig.calls + 1] = { last = last, current = rig.ns.Teacher.last, teach = #rig.teach,
                    verdicts = rig.ns.Ledger.Fights()[1] and rig.ns.Ledger.Fights()[1].verdicts }
            end
            return rig
        end

        local rig = HookRig()
        rig.ns.Ledger.Start(10, false)
        rig.ns.Ledger.Add("damage", SMITE, 53)
        rig.ns.Ledger.Finish(20)
        rig.Fight({ [SMITE] = { 53 } }, { Session(nextSession + 1, { Row(SMITE, 53) }) })
        nextSession = nextSession + 1
        local queued = #rig.calls
        rig.Fire()
        local call = rig.calls[1]
        Check("teacher OnRead: not called before the read fires, then once with Teacher.last",
            queued == 0 and #rig.calls == 1 and call.last == call.current and call.last.rows ~= nil
            and call.last.area == "clear")
        Check("teacher OnRead: called after Ledger.SetVerdicts and the TEACH report",
            call.teach > 0 and call.verdicts ~= nil and call.verdicts[SMITE] ~= nil)
        rig.Fire()
        Check("teacher OnRead: once per fight (no second call)", #rig.calls == 1)

        rig = HookRig()
        rig.Fight({ [SMITE] = { 53 } }, {})
        rig.Fire()
        Check("teacher OnRead: Read's skip (no sessions) calls it once with that skip's Teacher.last",
            #rig.calls == 1 and rig.calls[1].last == rig.calls[1].current and rig.calls[1].last.skip == "no sessions")

        rig = HookRig()
        rig.ns.Teacher.Finish(20)
        Check("teacher OnRead: Finish's 'no fight' skip calls it once",
            #rig.calls == 1 and rig.calls[1].last == rig.calls[1].current and rig.calls[1].last.skip == "no fight")

        rig = HookRig()
        rig.ns.Meter.Disable("test")
        rig.ns.Teacher.Start(10)
        rig.ns.Teacher.Finish(20)
        Check("teacher OnRead: Finish's 'meter off' skip calls it once",
            #rig.calls == 1 and rig.calls[1].last == rig.calls[1].current and rig.calls[1].last.skip == "meter off")

        rig = HookRig()
        C_Timer.After = function() error("timer broke") end
        rig.ns.Teacher.Start(10)
        rig.ns.Teacher.Finish(20)
        Check("teacher OnRead: Finish's 'read failed' skip calls it once",
            #rig.calls == 1 and rig.calls[1].last == rig.calls[1].current and rig.calls[1].last.skip == "read failed")
    end

    do -- heal probe (gap 3): /cti debug logs the healing-done rows after the damage TEACH lines
        local HEAL_ID = 19236
        local function HealRig(debug)
            local rig = Rig({})
            rig.teach = {}
            if debug then
                rig.ns.Debug = function(format, ...)
                    local line = string.format(format, ...)
                    if line:find("^TEACH ") then rig.teach[#rig.teach + 1] = line end
                end
            end
            return rig
        end
        local function HealSession()
            nextSession = nextSession + 1
            local session = Session(nextSession, { Row(SMITE, 53) })
            session.healRows = { Row(HEAL_ID, 900, 120) }
            return session
        end

        local rig = HealRig(true)
        local ok = rig.Read({ [SMITE] = { 53 } }, { HealSession() })
        local teach = rig.teach
        Check("heal probe: debug on logs 'TEACH heal <id> meter=<total> over=<overkill>' last, after the damage rows",
            ok and teach[#teach] == "TEACH heal 19236 meter=900 over=120" and teach[#teach - 1]:find("^TEACH 591 ") ~= nil)
        Check("heal probe: the heal read asks for healing done (type 2) after the damage read",
            #rig.S.sourceCalls == 2 and rig.S.sourceCalls[1].meterType == DAMAGE and rig.S.sourceCalls[2].meterType == 2)

        rig = HealRig(false)
        rig.Read({ [SMITE] = { 53 } }, { HealSession() })
        Check("heal probe: debug off, a clear read still reads the heal rows once (Heals.Learn)",
            rig.ns.Teacher.last.area == "clear" and #rig.S.sourceCalls == 2 and rig.S.sourceCalls[2].meterType == 2)

        rig = HealRig(true)
        rig.S.sourceFail = "heal error"
        ok = rig.Read({ [SMITE] = { 53 } }, { HealSession() })
        Check("heal probe: a heal read that errors logs 'TEACH heal skip read failed' and leaves the meter on",
            ok and rig.teach[#rig.teach] == "TEACH heal skip read failed" and rig.ns.Meter.Available()
            and Find(rig.ns.Teacher.last, SMITE).verdict == "agree")
    end

    do -- steady pass (plan 2026-10-25-steady-learning): long fights learn from a steady delay and size
        local SWD, VOID_BLAST, SWP_ROW = 32379, 450983, 589
        -- One solo fight on nameplate1 with /cti debug on: `events` (time order) are { t, spellID } casts and
        -- { t, nil, amount, flag } school-32 hits; the session holds `rows`. `before(rig)` runs first and
        -- `during(rig)` before combat ends. Returns rig, Teacher.last.
        local function SteadyFight(events, rows, before, during)
            local rig = Rig({}, true)
            local S, Core = rig.S, rig.ns.Core
            if before then before(rig) end
            SlashCmdList.COMBATTEXTICONS("debug")
            S.now = events[1][1] - 1
            Core.PLAYER_REGEN_DISABLED()
            for _, event in ipairs(events) do
                if event[2] then rig.Cast(event[1], "nameplate1", event[2])
                else rig.Hit(event[1], "nameplate1", event[3], event[5] or 32, event[4]) end
            end
            if during then during(rig) end
            S.now = events[#events][1] + 5
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(nextSession, rows) }
            nextSession = nextSession + 1
            pcall(rig.Fire)
            return rig, rig.ns.Teacher.last
        end
        -- The outcome after "->" of the last TEACH steady line for castID 8092 and `castSpell`, or nil.
        local function Outcome(castSpell)
            local found
            for _, line in ipairs(CombatTextIconsDB.debugLog) do
                found = line:match("TEACH steady 8092 spell=" .. castSpell .. " .*%-> (%S+)$") or found
            end
            return found
        end
        local function Learned(last) return last and last.learned and last.learned[MIND_BLAST] end
        -- Run 140233Z's shape: Mind Blast casts 5 s apart, each with a Shadow Word: Death `offsets[i]` s before it,
        -- the MB hit `delays[i]` s after, ticks at +1.1 on the first three casts; `extra` adds a hit per MB hit frame.
        local function Rotation(offsets, extra)
            local events, delays, sizes = {}, { 0.29, 0.30, 0.31, 0.30 }, { 19000, 20500, 21000, 22000 }
            for index, t in ipairs({ 10, 15, 20, 25 }) do
                events[#events + 1] = { t - offsets[index], SWD }
                events[#events + 1] = { t, MIND_BLAST }
                events[#events + 1] = { t + delays[index], nil, sizes[index] }
                if extra then events[#events + 1] = { t + delays[index], nil, extra } end
                if index <= 3 then events[#events + 1] = { t + 1.1, nil, ({ 2000, 3000, 4500 })[index] } end
            end
            return events
        end
        local VARIED = { 0.3, 0.6, 0.9, 1.1 }

        local rig, last = SteadyFight(Rotation(VARIED), { Row(MIND_BLAST, 92000) })
        local entry, delaysOk = rig.ns.Fingerprints.Get(MIND_BLAST), true
        for _, sample in ipairs(entry and entry.samples or {}) do
            delaysOk = delaysOk and sample.delay >= 0.29 - 1e-6 and sample.delay <= 0.31 + 1e-6
        end
        Check("steady (b): 4 MB casts with another cast near each, steady at ~0.30 s, ticks at 1.1 s -> 8092 learns 4",
            last.area == "clear" and Learned(last) == 4 and rig.ns.Fingerprints.IsLearned(MIND_BLAST)
            and #entry.samples == 4 and delaysOk and Outcome(MIND_BLAST) == "learned")

        rig, last = SteadyFight(Rotation(VARIED, 15000), { Row(MIND_BLAST, 152000) })
        Check("steady (c): a like-sized co-hit (within 1.5 x) in every MB hit's frame -> no cast counts, none learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "none")

        -- Run 20261025T180045Z: Shadow Bolt's hits often shared their frame with a 412 proc tick (s106).
        -- `frames` picks the MB hits (1-4) that get a `size` co-hit of `school` (default: the 412 s106 tick).
        local function CoHits(frames, size, school)
            local events, hits = {}, 0
            for _, event in ipairs(Rotation(VARIED)) do
                events[#events + 1] = event
                if event[3] and event[3] >= 19000 then
                    hits = hits + 1
                    if frames[hits] then events[#events + 1] = { event[1], nil, size or 412, nil, school or 106 } end
                end
            end
            return events
        end
        rig, last = SteadyFight(CoHits({ true, false, true, false }), { Row(MIND_BLAST, 92000), Row(1287663, 2 * 412) })
        Check("steady (c2): a co-hit of another school in 2 of 4 MB hit frames spoils no cast -> 8092 learns 4",
            last.area == "clear" and Learned(last) == 4 and Outcome(MIND_BLAST) == "learned")
        rig, last = SteadyFight(CoHits({ true, true, true, true }), { Row(MIND_BLAST, 92000), Row(1287663, 4 * 412) })
        Check("steady (c3): a co-hit of another school after every MB cast is a second cluster -> nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "clusters=2")

        -- MB samples of `rig` all `low` or more (no co-hit learned in their place).
        local function SamplesFrom(rig, low)
            local ok = true
            for _, sample in ipairs((rig.ns.Fingerprints.Get(MIND_BLAST) or { samples = {} }).samples) do
                ok = ok and sample.size >= low
            end
            return ok
        end
        -- Run shaman5: two of 57984's ~36K hits shared their delay with a ~4K one: the window fell 2 casts short.
        rig, last = SteadyFight(CoHits({ true, false, true, false }, 5000, 32), { Row(MIND_BLAST, 102000) })
        Check("steady (c4): a same-school co-hit a quarter the size in 2 of 4 MB hit frames spoils no cast -> learns 4",
            last.area == "clear" and Learned(last) == 4 and SamplesFrom(rig, 19000)
            and Outcome(MIND_BLAST) == "learned")
        rig, last = SteadyFight(CoHits({ true, false, true, false }, 15000, 32), { Row(MIND_BLAST, 122000) })
        Check("steady (c5): a like-sized same-school co-hit in 2 of 4 MB hit frames spoils both casts -> none learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "none")
        rig, last = SteadyFight(CoHits({ false, true, false, false }, 60000, 32),
            { Row(MIND_BLAST, 92000), Row(1287663, 60000) })
        Check("steady (c6): a big foreign hit beside one MB hit is its cast's pick, out of band -> learns the other 3",
            last.area == "clear" and Learned(last) == 3 and SamplesFrom(rig, 19000)
            and Outcome(MIND_BLAST) == "learned")

        local spread = {}
        for index, t in ipairs({ 10, 15, 20, 25, 30, 35 }) do
            spread[#spread + 1] = { t, MIND_BLAST }
            spread[#spread + 1] = { t + (index <= 3 and 0.30 or 0.80), nil, 20000 }
        end
        rig, last = SteadyFight(spread, { Row(MIND_BLAST, 150000) })
        Check("steady (d): 3 of 6 casts at 0.30 and 3 at 0.80 -> each under the 60 % share, nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "none")

        local twice = {}
        for _, t in ipairs({ 10, 15, 20, 25 }) do
            twice[#twice + 1] = { t, MIND_BLAST }
            twice[#twice + 1] = { t + 0.30, nil, 20000 }
            twice[#twice + 1] = { t + 0.80, nil, 20000 }
        end
        rig, last = SteadyFight(twice, { Row(MIND_BLAST, 200000) })
        Check("steady (d2): every cast steady at both 0.30 and 0.80, like sums -> two clusters, nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "clusters=2")

        -- Run shaman5 fight 1: Lava Burst's ~85K crits at 0.20-0.28 s, its overload row's ~28K ones at 0.65-0.73 s.
        local echo = {}
        for _, t in ipairs({ 10, 15, 20, 25 }) do
            echo[#echo + 1] = { t, MIND_BLAST }
            echo[#echo + 1] = { t + 0.30, nil, 20000 }
            echo[#echo + 1] = { t + 0.80, nil, 5000 }
        end
        rig, last = SteadyFight(echo, { Row(MIND_BLAST, 120000) })
        local echoOk = true
        for _, sample in ipairs((rig.ns.Fingerprints.Get(MIND_BLAST) or { samples = {} }).samples) do
            echoOk = echoOk and math.abs(sample.delay - 0.30) < 1e-6 and sample.size == 20000
        end
        Check("steady (d3): steady at 0.30 (20000s) and 0.80 (5000s): the 0.30 cluster sums 4 x the other -> learns its 4 alone",
            last.area == "clear" and Learned(last) == 4 and echoOk and Outcome(MIND_BLAST) == "learned")

        -- Run warrior F1: Shield Slam 23922 hit 0.165 s after each cast, ~600-870K, but one 204K. One MB cast a
        -- `sizes[i]` hit at 0.30 s each, a Shadow Word: Death before each at a varied offset (no sole cast).
        local function Odd(sizes)
            local events = {}
            for index, size in ipairs(sizes) do
                local t = 5 + 5 * index
                events[#events + 1] = { t - 0.2 - 0.15 * index, SWD }
                events[#events + 1] = { t, MIND_BLAST }
                events[#events + 1] = { t + 0.30, nil, size }
            end
            return events
        end
        rig, last = SteadyFight(Odd({ 19000, 20500, 5000, 21000, 22000 }), { Row(MIND_BLAST, 90000) })
        Check("steady (d4): 4 of 5 casts steady at 0.30 s, the 5th's hit there a quarter the size -> learns the 4",
            last.area == "clear" and Learned(last) == 4 and SamplesFrom(rig, 19000)
            and Outcome(MIND_BLAST) == "learned")
        rig, last = SteadyFight(Odd({ 20000, 5000, 21000, 5200, 22000, 5400 }), { Row(MIND_BLAST, 80000) })
        Check("steady (d5): 3 of 6 casts' hits at 0.30 s like-sized, 3 a quarter the size -> under the 60 % share",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "none")

        -- Priest Devouring Plague 335467 (lead L24): 5 MB casts beside a ~1/s ~1K shadow DoT stream; the first tick
        -- after 3 of them falls at ~0.94 s by coincidence. 3 of 5 across the 15 delay windows is luck, not a pattern.
        local ticks, casts = {}, { 10.56, 15.55, 20.564, 25.2, 30.8 }
        for index = 0, 25 do ticks[#ticks + 1] = { 10.5 + index, nil, 900 + (index * 70) % 201 } end
        for _, t in ipairs(casts) do ticks[#ticks + 1] = { t, MIND_BLAST } end
        table.sort(ticks, function(a, b) return a[1] < b[1] end)
        rig, last = SteadyFight(ticks, { Row(MIND_BLAST, 30000) })
        local luckOutcome = Outcome(MIND_BLAST)
        Check("steady (l): 3 of 5 casts with a DoT tick at the same delay among a 1/s stream is luck -> nothing learned",
            last.area == "clear" and Learned(last) == nil and not rig.ns.Fingerprints.IsLearned(MIND_BLAST)
            and luckOutcome ~= nil and luckOutcome:find("^luck=") ~= nil)

        rig, last = SteadyFight(Rotation(VARIED), { Row(MIND_BLAST, 74250), Row(SWP_ROW, 17750) })
        Check("steady (e1): the MB hits sum over the 8092 row -> meter, nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "meter")
        rig, last = SteadyFight(Rotation(VARIED), { Row(SWP_ROW, 92000) })
        Check("steady (e2): no 8092 row -> meter, nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "meter")
        -- Run dk F11's shape: Death Coil 47541's 3 counted hits summed to its row 47632 (4105), its only meter ID
        local OTHER_ROW = 47632
        rig, last = SteadyFight(Rotation(VARIED), { Row(OTHER_ROW, 82500), Row(SWP_ROW, 9500) })
        Check("steady (e3): no 8092 row, every cast counted, the sum agrees with one other-ID row -> learns, aliases",
            last.area == "clear" and Learned(last) == 4 and Outcome(MIND_BLAST) == "learned"
            and rig.ns.Fingerprints.Alias(OTHER_ROW) == MIND_BLAST)
        rig, last = SteadyFight(Rotation(VARIED), { Row(OTHER_ROW, 82500), Row(SWP_ROW, 82000) })
        Check("steady (e4): two rows of other IDs agree with the sum -> meter, nothing learned, no alias",
            Learned(last) == nil and Outcome(MIND_BLAST) == "meter" and rig.ns.Fingerprints.Alias(OTHER_ROW) == nil)
        local late = Rotation(VARIED) -- plus a 5th cast steady at 0.30 s and a 6th whose hit lands at 0.70 s
        local extra = { { 30, MIND_BLAST }, { 30.3, nil, 20000 }, { 35, MIND_BLAST }, { 35.7, nil, 20000 } }
        for _, event in ipairs(extra) do late[#late + 1] = event end
        rig, last = SteadyFight(late, { Row(OTHER_ROW, 102500), Row(SWP_ROW, 29500) })
        Check("steady (e5): 5 of 6 casts counted, their sum agrees with a row of another ID -> meter, nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "meter"
            and rig.ns.Fingerprints.Alias(OTHER_ROW) == nil)

        rig, last = SteadyFight(Rotation({ 0.5, 0.5, 0.5, 0.5 }), { Row(MIND_BLAST, 92000) })
        Check("steady (f): Shadow Word: Death always 0.5 s before is steady on the same hits -> shared, neither learns",
            last.area == "clear" and Learned(last) == nil and last.learned[SWD] == nil and Outcome(MIND_BLAST) == "shared")

        local both = {}
        for _, t in ipairs({ 10, 15, 20 }) do
            both[#both + 1] = { t, VOID_BLAST }
            both[#both + 1] = { t + 0.2, MIND_BLAST }
            both[#both + 1] = { t + 0.5, nil, 20000 }
        end
        rig, last = SteadyFight(both, { Row(MIND_BLAST, 75000) })
        Check("steady (f2): Void Blast and Mind Blast of one base count the same hits -> shared, 8092 learns nothing",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "shared")

        local sole = {}
        for index, t in ipairs({ 10, 15, 20 }) do
            sole[#sole + 1] = { t, MIND_BLAST }
            sole[#sole + 1] = { t + 0.2, nil, ({ 19000, 20000, 21000 })[index] }
        end
        rig, last = SteadyFight(sole, { Row(MIND_BLAST, 60000) })
        local logged = false
        for _, line in ipairs(CombatTextIconsDB.debugLog) do logged = logged or line:find("TEACH steady 8092", 1, true) ~= nil end
        Check("steady (g): sole casts whose sum matches learn by the exact sum; the steady pass skips 8092",
            last.area == "clear" and Learned(last) == 3 and #rig.ns.Fingerprints.Get(MIND_BLAST).samples == 3 and not logged)

        local doubled = {}
        for index, t in ipairs({ 10, 15, 20 }) do
            doubled[#doubled + 1] = { t - ({ 0.3, 0.7, 1.1 })[index], SWD }
            doubled[#doubled + 1] = { t, VOID_BLAST }
            doubled[#doubled + 1] = { t, VOID_BLAST }
            doubled[#doubled + 1] = { t, nil, ({ 21000, 22000, 23000 })[index] }
        end
        rig, last = SteadyFight(doubled, { Row(MIND_BLAST, 82500) })
        local voidSamples = 0
        for _, sample in ipairs((rig.ns.Fingerprints.Get(MIND_BLAST) or { samples = {} }).samples) do
            if sample.spell == VOID_BLAST then voidSamples = voidSamples + 1 end
        end
        Check("steady (k): Void Blast logged twice in its frame is one cast -> 8092 learns 3 Void Blast samples",
            last.area == "clear" and Learned(last) == 3 and voidSamples == 3)

        -- Learned-base mode: Mind Blast learned at a far dummy (0.30 s), only Mind Blast samples; Void Blast lands
        -- in its cast frame, so no record claims it (window 0.30 by fallback), with a small co-hit in each frame.
        local function FarMindBlast(rig)
            for castAt, size in ipairs({ 20942, 20962, 21730 }) do
                rig.ns.Fingerprints.Add(MIND_BLAST, { school = 32, delay = 0.30, castAt = castAt, hops = 1,
                    spell = MIND_BLAST, size = size })
            end
        end
        local blasts = {}
        for index, t in ipairs({ 10, 15, 20 }) do
            blasts[#blasts + 1] = { t, VOID_BLAST }
            blasts[#blasts + 1] = { t, nil, ({ 22090, 22574, 22978 })[index] }
            blasts[#blasts + 1] = { t, nil, ({ 2000, 4000, 6000 })[index] }
        end
        rig, last = SteadyFight(blasts, { Row(MIND_BLAST, 79642) }, FarMindBlast)
        local voidDelays = {}
        for _, sample in ipairs(rig.ns.Fingerprints.Get(MIND_BLAST).samples) do
            if sample.spell == VOID_BLAST then voidDelays[#voidDelays + 1] = sample.delay end
        end
        local based = false
        for _, line in ipairs(CombatTextIconsDB.debugLog) do
            based = based or line:find("TEACH steady 8092 spell=450983 mode=base", 1, true) ~= nil
        end
        rig.S.now = 40
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(40, "nameplate1", VOID_BLAST)
        local drawn = rig.Hit(40, "nameplate1", 22500, 32)
        Check("steady (h): a learned base learns Void Blast's in-frame hits it missed (co-hits out of band); then claims one",
            last.area == "clear" and Learned(last) == 3 and #voidDelays == 3 and voidDelays[1] == 0 and voidDelays[3] == 0
            and based and Outcome(VOID_BLAST) == "learned" and drawn == "tex:" .. VOID_BLAST)

        -- Haunt 48181 in run 20261025T180045Z's first log: an exact sum left 2 samples (22336, 27095); the next
        -- fight's casts each had a 1.6K tick in the hit's frame. Two kept sized samples band the pairs.
        local function TwoSamples(r)
            for castAt, size in ipairs({ 19000, 22000 }) do
                r.ns.Fingerprints.Add(MIND_BLAST, { school = 32, delay = 0.30, castAt = castAt, hops = 1, spell = MIND_BLAST,
                    size = size })
            end
        end
        -- a 50K co-hit past the padded band (2 x 22000) in every frame: without the band it would be each cast's hit
        rig, last = SteadyFight(Rotation(VARIED, 50000), { Row(MIND_BLAST, 92000), Row(1287663, 4 * 50000) },
            TwoSamples)
        Check("steady (n): an unlearned base with 2 sized samples pairs only hits in their school and padded band -> 8092 learns 4",
            last.area == "clear" and Learned(last) == 4 and rig.ns.Fingerprints.IsLearned(MIND_BLAST)
            and Outcome(MIND_BLAST) == "learned")
        rig, last = SteadyFight(Rotation(VARIED, 15000), { Row(MIND_BLAST, 152000) }, function(r)
            r.ns.Fingerprints.Add(MIND_BLAST, { school = 32, delay = 0.30, castAt = 1, hops = 1, spell = MIND_BLAST, size = 19000 })
        end)
        Check("steady (n2): with 1 sized sample a like-sized co-hit in every frame still blocks every cast",
            last.area == "clear" and Learned(last) == nil and Outcome(MIND_BLAST) == "none")

        rig, last = SteadyFight(blasts, { Row(MIND_BLAST, 79642) }, FarMindBlast,
            function(r) r.ns.Teacher.Drawn(MIND_BLAST, 79642) end)
        Check("steady (i): a learned base whose drawn tally already fills its row -> meter, nothing learned",
            last.area == "clear" and Learned(last) == nil and Outcome(VOID_BLAST) == "meter")

        -- Run shaman3 fresh F1: Lava Burst 51505 casts key by API base 73899 until a read shows row 51505;
        -- the meter has no 73899 row, so the first fight's steady cluster went "-> meter" and was lost.
        local LAVA_BURST, LAVA_BASE = 51505, 73899
        local lavas = {}
        for index, t in ipairs({ 10, 15, 20, 25 }) do
            lavas[#lavas + 1] = { t - VARIED[index], SWD }
            lavas[#lavas + 1] = { t, LAVA_BURST }
            lavas[#lavas + 1] = { t + 0.30, nil, ({ 52000, 55000, 58000, 61000 })[index], 4 }
        end
        rig, last = SteadyFight(lavas, { Row(LAVA_BURST, 226000) },
            function(r) r.S.baseSpells[LAVA_BURST] = LAVA_BASE end)
        Check("steady (j): a first fight keyed by API base 73899 learns under its own row 51505 (before: -> meter)",
            last.area == "clear" and last.learned and last.learned[LAVA_BURST] == 4
            and rig.ns.Fingerprints.IsLearned(LAVA_BURST))

        -- Run shaman3 start F1: a stale save learned 51505 as a Nature DoT, which drew 260K of other Nature hits under
        -- 51505. Its draws take no room from the Fire hits, and the learned Fire fingerprint drops the DoT. The DoT is
        -- seeded at the fight's end: with no Nature ticks here, two tickless casts would drop it first (Learn.Missed).
        local fires = {}
        for _, event in ipairs(lavas) do
            fires[#fires + 1] = event[2] and event or { event[1], nil, event[3], "", 4 }
        end
        local function StaleDotDrew(r)
            T.Store().learned[LAVA_BURST] = { school = 8, period = 1.65, kind = "dot", misses = 0 }
            r.ns.Learn.Init(T.Store())
            r.ns.Teacher.Drawn(LAVA_BURST, 150000)
        end
        rig, last = SteadyFight(fires, { Row(LAVA_BURST, 226000) }, nil, StaleDotDrew)
        Check("steady (o): a stale Nature DoT's 150K under 51505 leaves the 4 Fire hits room -> learned, DoT dropped",
            last.area == "clear" and last.learned and last.learned[LAVA_BURST] == 4
            and rig.ns.Fingerprints.IsLearned(LAVA_BURST) and rig.ns.Learn.Get(LAVA_BURST) == nil)
        rig, last = SteadyFight(fires, { Row(LAVA_BURST, 200000), Row(SWP_ROW, 26000) }, nil, StaleDotDrew)
        Check("steady (o2): Fire hits (226K) over the row (200K) still -> meter: nothing learned, the DoT kept",
            last.area == "clear" and not (last.learned and last.learned[LAVA_BURST])
            and not rig.ns.Fingerprints.IsLearned(LAVA_BURST) and rig.ns.Learn.Get(LAVA_BURST) ~= nil)
    end

    do -- ground pass (Ground.lua): a rowless cast's ticks on many plates, bounded by one open row of another ID
        -- Run shaman5 F1: Earthquake 462620 has no row; each cast's first tick lands ~1.02 s later on 5 plates, then
        -- one every ~0.98 s, 6 ticks, all in row 77478. Here 4 casts 10 s apart tick 6 times on 3 plates, 1.0 s
        -- after the cast and then every 1.0 s: 4 x 6 x 19500 = 468000 seen. The casts target no plate (a ground spell
        -- aims at the floor; a target ticked like this would learn the spell as its DoT first).
        local EARTHQUAKE, QUAKE_ROW, OTHER_ROW = 462620, 77478, 188443
        local SIZES = { nameplate1 = 6400, nameplate2 = 6500, nameplate3 = 6600 }
        -- `crits`: the ticks k (0-5) whose every hit crits (x2, flagged), or (3) whose nameplate1 hit alone crits x3;
        -- `half`: a like frame 0.5 s after tick 0.
        local function QuakeFight(rig, casts, rows, before, crits, half)
            local S, Core = rig.S, rig.ns.Core
            SlashCmdList.COMBATTEXTICONS("debug")
            S.now = casts[1] - 2
            Core.PLAYER_REGEN_DISABLED()
            if before then before() end
            for _, t in ipairs(casts) do
                rig.Cast(t, nil, EARTHQUAKE)
                for k = 0, 5 do
                    for _, unit in ipairs({ "nameplate1", "nameplate2", "nameplate3" }) do
                        if crits and crits[k] == 3 and unit == "nameplate1" then
                            rig.Hit(t + 1 + k, unit, 3 * SIZES[unit], 8, "CRITICAL")
                        elseif crits and crits[k] == true then
                            rig.Hit(t + 1 + k, unit, 2 * SIZES[unit], 8, "CRITICAL")
                        else
                            rig.Hit(t + 1 + k, unit, SIZES[unit], 8)
                        end
                    end
                    if half and k == 0 then
                        for _, unit in ipairs({ "nameplate1", "nameplate2", "nameplate3" }) do
                            rig.Hit(t + 1.5, unit, SIZES[unit], 8)
                        end
                    end
                end
            end
            S.now = casts[#casts] + 10
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(nextSession, rows) }
            nextSession = nextSession + 1
            pcall(rig.Fire)
            return rig.ns.Teacher.last
        end
        local function Outcome()
            local found
            for _, line in ipairs(CombatTextIconsDB.debugLog) do
                found = line:match("TEACH ground " .. EARTHQUAKE .. " casts=%d+ %-> (%S+)") or found
            end
            return found
        end
        local CASTS = { 10, 20, 30, 40 }

        local rig = Rig({})
        local last = QuakeFight(rig, CASTS, { Row(QUAKE_ROW, 600000) })
        local F = rig.ns.Fingerprints
        local entry = F.Get(EARTHQUAKE)
        Check("ground (a): 4 rowless casts, 6 ticks 1.0 s apart on 3 plates (468000) under row 600000 -> learned as "
            .. "ground, row aliased",
            Outcome() == "learned" and F.IsLearned(EARTHQUAKE) and entry.pattern == "ground" and entry.ticks == 6
            and math.abs(entry.period - 1) < 1e-6 and F.Alias(QUAKE_ROW) == EARTHQUAKE
            and Find(last, EARTHQUAKE).verdict == "under" and last.learned[EARTHQUAKE] == 72)
        rig.S.now = 99
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(100, nil, EARTHQUAKE)
        Check("ground (a2): the next cast, no target, draws its ticks on any plate, not a hit between two ticks",
            rig.Hit(101, "nameplate2", 6500, 8) == "tex:" .. EARTHQUAKE
            and rig.Hit(101.5, "nameplate3", 6500, 8) ~= "tex:" .. EARTHQUAKE
            and rig.Hit(102, "nameplate3", 6550, 8) == "tex:" .. EARTHQUAKE)

        rig = Rig({})
        QuakeFight(rig, CASTS, { Row(QUAKE_ROW, 400000), Row(OTHER_ROW, 300000) })
        Check("ground (b): the ticks (468000) over every open row (400000, 300000) -> nothing learned, no alias",
            Outcome() == "rows=0" and rig.ns.Fingerprints.Get(EARTHQUAKE) == nil
            and rig.ns.Fingerprints.Alias(QUAKE_ROW) == nil)

        rig = Rig({})
        -- Fight 1: rows of at least D were 188443 and 51505 too, both cast that fight; 77478 alone was free.
        QuakeFight(rig, CASTS, { Row(OTHER_ROW, 600000) }, function() rig.Cast(9, nil, OTHER_ROW) end)
        Check("ground (c): the one row that bounds the ticks is a spell cast this fight -> not free, nothing learned",
            Outcome() == "rows=0" and rig.ns.Fingerprints.Get(EARTHQUAKE) == nil
            and rig.ns.Fingerprints.Alias(OTHER_ROW) == nil)

        rig = Rig({})
        QuakeFight(rig, { 10, 20 }, { Row(QUAKE_ROW, 600000) })
        Check("ground (d): 2 casts are under MIN_CASTS -> the pass never tries the spell",
            Outcome() == nil and rig.ns.Fingerprints.Get(EARTHQUAKE) == nil)

        -- Synthetic Death and Decay (43265 -> row 52212, SimC death_and_decay_base_t: 11 ticks 1 s apart, crits x2):
        -- 4 plates crit together in one frame, so a crit-only tick frame came every few casts; the walk ended on two
        -- in a row, D fell far under the row and the pass found rows=0. Here ticks 1 and 2 of every cast all crit:
        -- 4 x (4 x 19500 + 2 x 39000) = 624000 seen under row 700000.
        rig = Rig({})
        QuakeFight(rig, CASTS, { Row(QUAKE_ROW, 700000) }, nil, { [1] = true, [2] = true })
        entry = rig.ns.Fingerprints.Get(EARTHQUAKE)
        Check("ground (e): crit-only tick frames after a seen first tick keep the walk -> learned, 6 ticks",
            Outcome() == "learned" and entry ~= nil and entry.ticks == 6
            and rig.ns.Fingerprints.Alias(QUAKE_ROW) == EARTHQUAKE and entry.crit == nil)

        -- Shaman5 F1: Earthquake's crits were ~3x its normals (~19.5K beside 6.2-7.3K). Here nameplate1 crits x3 on
        -- tick 1 of every cast (19200, halved 9600) beside 6500-6600 normals: crit scale 9600 / 6500.
        rig = Rig({})
        QuakeFight(rig, CASTS, { Row(QUAKE_ROW, 650000) }, nil, { [1] = 3 })
        entry = rig.ns.Fingerprints.Get(EARTHQUAKE)
        Check("ground (g): a crit x3 beside normal ticks in its frame -> learned with crit scale 9600 / 6500",
            Outcome() == "learned" and entry ~= nil and entry.crit ~= nil and math.abs(entry.crit - 9600 / 6500) < 1e-6)

        -- A like-sized frame on the 3 plates half a period after each first tick ties the period search at 0.5 s
        -- (its ties go to the shorter gap); the walks then step two slots at a time. The frames (4 x 19500) are a
        -- never-cast row's (5740), so the quake's row is bounded as in (a).
        rig = Rig({})
        QuakeFight(rig, CASTS, { Row(QUAKE_ROW, 600000), Row(5740, 78000) }, nil, nil, true)
        entry = rig.ns.Fingerprints.Get(EARTHQUAKE)
        Check("ground (f): a frame half a period after each first tick -> learned at 1.0 s, not 0.5",
            Outcome() == "learned" and entry ~= nil and math.abs(entry.period - 1) < 0.05)
    end

    do -- DoT pass (Teacher.lua): a cast whose ticks run only on plates it never targeted is learned from its own row
        -- Run lock3 F1: Wither 445468 was cast once and Seed of Corruption spread it to 5 plates; no birth window held
        -- the cast, so it never voted, and its row (772071) held every school-36 '?' hit (740626). Here one cast on
        -- nameplate1 and 8 ticks 1.4 s apart on 3 other plates: 3 x 8 x 5000 = 120000 '?' in school 36.
        local WITHER = 445468
        local function WitherFight(rig, at, rows, series)
            local S, Core = rig.S, rig.ns.Core
            SlashCmdList.COMBATTEXTICONS("debug")
            S.now = at - 2
            Core.PLAYER_REGEN_DISABLED()
            rig.Cast(at, "nameplate1", WITHER)
            for k = 0, 7 do
                for _, unit in ipairs({ "nameplate2", "nameplate3", "nameplate4" }) do
                    rig.Hit(at + 1.5 + 1.4 * k, unit, 5000, 36)
                end
                -- a second series of the row: 12000 every 1.0 s on the given plates
                for _, unit in ipairs(k < 6 and series or {}) do rig.Hit(at + 2.2 + k, unit, 12000, 36) end
            end
            S.now = at + 20
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(nextSession, rows) }
            nextSession = nextSession + 1
            pcall(rig.Fire)
            return rig.ns.Teacher.last
        end
        local function Outcome()
            local found
            for _, line in ipairs(CombatTextIconsDB.debugLog) do
                found = line:match("TEACH dot " .. WITHER .. " school=36 .* %-> (%S+)") or found
            end
            return found
        end

        local rig = Rig({})
        local last = WitherFight(rig, 10, { Row(WITHER, 125000) })
        local entry = rig.ns.Learn.Get(WITHER)
        Check("dot (a): ticks (120000) only on plates the cast never targeted, own row 125000 -> learned school-36 DoT",
            Outcome() == "learned" and entry and entry.mode == "target" and entry.school == 36
            and math.abs(entry.period - 1.4) < 0.05 and Find(last, WITHER).verdict == "under")
        rig.S.now = 99
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(100, "nameplate1", WITHER)
        Check("dot (a2): the next cast draws its own tick on the target",
            rig.Hit(101.4, "nameplate1", 5000, 36) == "tex:" .. WITHER)

        rig = Rig({})
        WitherFight(rig, 10, { Row(WITHER, 200000) })
        Check("dot (b): the row (200000) is far over the ticks (120000) -> nothing learned",
            Outcome() == nil and rig.ns.Learn.Get(WITHER) == nil)

        rig = Rig({})
        -- Agony 980's row (never cast here, so never free) keeps the fight clear: seen 120000 under meter 150000.
        WitherFight(rig, 10, { Row(WITHER, 100000), Row(980, 50000) })
        Check("dot (c): the school's '?' hits (120000) are over the row (100000) -> nothing learned",
            rig.ns.Teacher.last.area == "clear" and Outcome() == nil and rig.ns.Learn.Get(WITHER) == nil)

        -- Run lock3 F1: Wither's stacks also collapsed at ~1.0 s (4060-5637) beside its 1.4 s ticks, all in its row;
        -- in F2 those went by as '?'. Here 6 ticks of 12000 1.0 s apart on 2 plates join the row: 264000 under 270000.
        rig = Rig({})
        WitherFight(rig, 10, { Row(WITHER, 270000) }, { "nameplate2", "nameplate3" })
        local series = rig.ns.Procs.Get(WITHER)
        Check("dot (d): a 1.0 s series of another size on 2 plates in the row -> learned as the row's rhythm (" ..
            tostring(series and series.period) .. ")", Outcome() == "learned" and series ~= nil and series.school == 36
            and math.abs(series.period - 1) < 0.05 and series.lo == 12000 and series.hi == 12000)
        rig.S.now = 99
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        local drawn
        for k = 0, 3 do drawn = rig.Hit(100 + k, "nameplate5", 12000, 36) end
        Check("dot (d2): the series' stream on a plate never cast on draws the row (" .. tostring(drawn) .. ")",
            drawn == "tex:" .. WITHER)

        rig = Rig({})
        WitherFight(rig, 10, { Row(WITHER, 197000) }, { "nameplate2" })
        Check("dot (e): the series on one plate only -> the DoT is learned, no rhythm",
            Outcome() == "learned" and rig.ns.Procs.Get(WITHER) == nil)
    end

    do -- castless pass (Ground.Castless): a never-cast row's ticks on many plates at once, every period
        -- Run lock3 F1: Shadow of Nathreza 1262710 hit 4 plates every ~1.0 s for 40 ticks (1379 on three, 1655 on
        -- the fourth), never cast, 289020 seen under its row 291805. Here 15 ticks 1.0 s apart on 4 plates, no cast:
        -- 15 x (3 x 2000 + 2400) = 126000 '?' in school 32, in a fight a lone fire hit at 60 s stretches to 50 s.
        local NATHREZA, FILLER = 1262710, 5740
        local SIZES = { nameplate1 = 2000, nameplate2 = 2000, nameplate3 = 2000, nameplate4 = 2400 }
        local function AuraFight(rig, total, filler, before)
            local S, Core = rig.S, rig.ns.Core
            SlashCmdList.COMBATTEXTICONS("debug")
            S.now = 8
            Core.PLAYER_REGEN_DISABLED()
            if before then before() end
            for k = 0, 14 do
                for _, unit in ipairs({ "nameplate1", "nameplate2", "nameplate3", "nameplate4" }) do
                    rig.Hit(10 + k, unit, SIZES[unit], 32)
                end
            end
            rig.Hit(60, "nameplate1", 1000, 4)
            S.now = 70
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(nextSession, { Row(NATHREZA, total), Row(FILLER, filler) }) }
            nextSession = nextSession + 1
            pcall(rig.Fire)
            return rig.ns.Teacher.last
        end
        local function Outcome()
            local found
            for _, line in ipairs(CombatTextIconsDB.debugLog) do
                found = line:match("TEACH castless school=32 .* %-> (%S+)") or found
            end
            return found
        end

        local rig = Rig({})
        local last = AuraFight(rig, 130000, 1000)
        local entry = rig.ns.Procs.Get(NATHREZA)
        Check("castless (a): 15 ticks 1.0 s apart on 4 plates (126000), no cast, row 130000 -> learned rhythm proc",
            Outcome() == tostring(NATHREZA) and entry and entry.school == 32 and math.abs(entry.period - 1) < 0.05
            and entry.lo == 2000 and entry.hi == 2400 and Find(last, NATHREZA).verdict == "under")
        rig.S.now = 99
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        for k = 0, 2 do rig.Hit(100 + k, "nameplate2", 2000, 32) end
        Check("castless (a2): the next fight's steady 2000 ticks on a plate draw the row's icon once their stream runs",
            rig.Hit(103, "nameplate2", 2000, 32) == "tex:" .. NATHREZA)

        rig = Rig({})
        AuraFight(rig, 122000, 5000)
        Check("castless (b): the ticks (126000) are over the row (122000) -> no row bounds them, nothing learned",
            Outcome() == "rows=0" and rig.ns.Procs.Get(NATHREZA) == nil)

        rig = Rig({})
        AuraFight(rig, 130000, 1000, function()
            T.Store().learned[445468] = { school = 32, period = 1.4, kind = "dot", misses = 0 }
            rig.ns.Learn.Init(T.Store())
        end)
        Check("castless (c): a learned DoT ticks in the school -> the pass never walks it, nothing learned",
            Outcome() == nil and rig.ns.Procs.Get(NATHREZA) == nil)
    end

    do -- chain pass (Chain.lua): a cast's hops from plate to plate, under its own row that no sum agrees with
        -- Run shaman5 F1: Chain Lightning 188443's hard casts hit the target 0.20-0.22 s after the cast, then one new
        -- plate every ~0.1 s; its row also holds overload chains and instant casts, so no sum agrees. Here 5 casts
        -- 10 s apart hit 4 plates 0.2-0.5 s after the cast (20 hits, 271000) under row 400000, among 35 lone hits of
        -- the same size 1 s apart (another row's), so a hop finds a like hit on another plate by luck 15 / 55 of the
        -- time.
        local CHAIN_LIGHTNING, OTHER_ROW = 188443, 77478
        local CHAIN = { { "nameplate1", 11000 }, { "nameplate2", 11200 }, { "nameplate3", 10900 },
            { "nameplate4", 11100 } }
        local function ChainFight(rig, casts, rows)
            local S, Core = rig.S, rig.ns.Core
            SlashCmdList.COMBATTEXTICONS("debug")
            S.now = casts[1] - 2
            Core.PLAYER_REGEN_DISABLED()
            for index, t in ipairs(casts) do
                rig.Cast(t, "nameplate1", CHAIN_LIGHTNING)
                -- every other first hit crits (36K, 3.3x): no steady size, so the steady pass learns nothing
                local crit = index % 2 == 0
                rig.Hit(t + 0.2, "nameplate1", crit and 36000 or CHAIN[1][2], 8, crit and "CRITICAL" or nil)
                for hop = 2, #CHAIN do rig.Hit(t + 0.1 + 0.1 * hop, CHAIN[hop][1], CHAIN[hop][2], 8) end
                for k = 2, 8 do rig.Hit(t + k, "nameplate" .. (k % 4 + 1), 11000, 8) end
            end
            S.now = casts[#casts] + 10
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(nextSession, rows) }
            nextSession = nextSession + 1
            pcall(rig.Fire)
            return rig.ns.Teacher.last
        end
        local function Outcome()
            local found
            for _, line in ipairs(CombatTextIconsDB.debugLog) do
                found = line:match("TEACH chain " .. CHAIN_LIGHTNING .. " casts=%d+ %-> (%S+)") or found
            end
            return found
        end

        local rig = Rig({})
        local last = ChainFight(rig, { 10, 20, 30, 40, 50 }, { Row(CHAIN_LIGHTNING, 400000), Row(OTHER_ROW, 400000) })
        local F = rig.ns.Fingerprints
        local entry = F.Get(CHAIN_LIGHTNING)
        Check("chain (a): 5 casts hop over 4 plates 0.1 s apart (271000) under their own row 400000 -> learned as a "
            .. "chain at the first hit's delay",
            Outcome() == "learned" and F.IsLearned(CHAIN_LIGHTNING) and entry.pattern == "chain"
            and math.abs(entry.delayHi - 0.2) < 1e-3 and Find(last, CHAIN_LIGHTNING).verdict == "under"
            and last.learned[CHAIN_LIGHTNING] == 20)
        rig.S.now = 99
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Cast(100, "nameplate1", CHAIN_LIGHTNING)
        local tex = "tex:" .. CHAIN_LIGHTNING
        -- shaman5 F3: Earthquake's 8.1-8.9K ticks landed 0.02-0.04 s after a hop, inside the padded band (7.6K up)
        Check("chain (a2): the next cast draws its hops; a smaller hit in a later frame is no hop, one in the hop's "
            .. "own frame is",
            rig.Hit(100.2, "nameplate1", 11000, 8) == tex and rig.Hit(100.3, "nameplate2", 11000, 8) == tex
            and rig.Hit(100.33, "nameplate3", 8500, 8) ~= tex and rig.Hit(100.4, "nameplate3", 11000, 8) == tex
            and rig.Hit(100.4, "nameplate4", 8500, 8) == tex)

        rig = Rig({})
        ChainFight(rig, { 10, 20, 30, 40, 50 }, { Row(CHAIN_LIGHTNING, 150000), Row(OTHER_ROW, 600000) })
        Check("chain (b): the chains (271000) over the own row (150000) -> nothing learned",
            Outcome() == "over" and not rig.ns.Fingerprints.IsLearned(CHAIN_LIGHTNING))
    end

    do -- stack pass (Stack.lua): a DoT whose casts add stacks ticks live stacks x one stack's size
        -- Run lock F3: the seed's size-blind chain liked 0.734 s, the walk took Unstable Affliction 1259790's ticks
        -- ~1.47 s apart, two periods each, and learned 0.739. Here casts add 8 s stacks of 3000 that tick every 1.4 s
        -- from 1.3 s after the first cast, and a stranger's 900-1500 hits land 0.7 s after each tick.
        local UA, STRANGER = 1259790, 5740
        local CASTS = { 10, 11.5, 15, 16.2, 22, 23.4, 24.6, 31, 32.5, 38 }
        local rig = Rig({})
        local S, Core = rig.S, rig.ns.Core
        SlashCmdList.COMBATTEXTICONS("debug")
        S.now = 8
        Core.PLAYER_REGEN_DISABLED()
        local sum, noise, next = 0, 0, 1
        for k = 0, 26 do
            local at = 11.3 + 1.4 * k
            while CASTS[next] and CASTS[next] <= at - 0.05 do
                rig.Cast(CASTS[next], "nameplate1", UA)
                next = next + 1
            end
            local stacks = 0
            for _, castAt in ipairs(CASTS) do
                if at - castAt >= 0 and at - castAt <= 8 then stacks = stacks + 1 end
            end
            if stacks > 0 then
                rig.Hit(at, "nameplate1", 3000 * stacks, 32)
                sum = sum + 3000 * stacks
            end
            rig.Hit(at + 0.7, "nameplate1", 900 + 23 * ((7 * k) % 27), 32)
            noise = noise + 900 + 23 * ((7 * k) % 27)
        end
        S.now = 60
        Core.PLAYER_REGEN_ENABLED()
        S.sessions = { Session(nextSession, { Row(UA, sum + 5000), Row(STRANGER, noise) }) }
        nextSession = nextSession + 1
        pcall(rig.Fire)
        local period
        for _, line in ipairs(CombatTextIconsDB.debugLog) do
            period = line:match("TEACH stack " .. UA .. " casts=%d+ %-> learned .* period=([%d%.]+)") or period
        end
        Check("stack (a): ticks every 1.4 s with a stranger's hits 0.7 s after each -> learned at 1.4 s, not 0.7",
            period ~= nil and math.abs(tonumber(period) - 1.4) < 0.05)

        -- Run lock3 F1: Darkglare stepped Unstable Affliction's stack from 3258 to 3910 at 199127.838 while stacks
        -- lived, and every recast's first tick fell on the running timer's phase, outside the first cast's delay
        -- window; the walk restarted nowhere and missed its luck test. Here a x1.2 buff holds ticks 5-9 and 15-19,
        -- and each recast lands at a new phase of the 1.4 s timer: only a step (another stack count, the same size a
        -- stack) restarts the series after each buff edge.
        CASTS = { 10, 13.1, 15.9, 19.5, 22.1, 25.7, 28.3, 31.1, 34.5, 37.3, 40.9, 43.5 }
        -- The buffed fight on a new rig, ended with its read queued (session `id` holds its row).
        local function BuffFight(id)
            local buffed = Rig({})
            local S, Core = buffed.S, buffed.ns.Core
            SlashCmdList.COMBATTEXTICONS("debug")
            S.now = 8
            Core.PLAYER_REGEN_DISABLED()
            local sum, next = 0, 1
            for k = 0, 26 do
                local at = 11.3 + 1.4 * k
                while CASTS[next] and CASTS[next] <= at - 0.05 do
                    buffed.Cast(CASTS[next], "nameplate1", UA)
                    next = next + 1
                end
                local stacks = 0
                for _, castAt in ipairs(CASTS) do
                    if at - castAt >= 0 and at - castAt <= 8 then stacks = stacks + 1 end
                end
                local unit = ((k >= 5 and k <= 9) or (k >= 15 and k <= 19)) and 3600 or 3000
                if stacks > 0 then
                    buffed.Hit(at, "nameplate1", unit * stacks, 32)
                    sum = sum + unit * stacks
                end
            end
            S.now = 60
            Core.PLAYER_REGEN_ENABLED()
            S.sessions = { Session(id, { Row(UA, sum + 5000) }) }
            return buffed
        end
        -- The TEACH stack line of UA's learning, or nil.
        local function Taught()
            local found
            for _, line in ipairs(CombatTextIconsDB.debugLog) do
                found = line:match("TEACH stack " .. UA .. " casts=%d+ %-> learned .*") or found
            end
            return found
        end
        rig = BuffFight(nextSession)
        nextSession = nextSession + 1
        pcall(rig.Fire)
        local whole, wholeLast = Taught(), rig.ns.Teacher.last
        local wholeSamples = #rig.ns.Fingerprints.Get(UA).samples
        -- Without the steps the walks break at each buff edge and the best is a 27 s life that keeps 14 ticks.
        Check("stack (b): a x1.2 buff twice while stacks live -> the steps restart the walk, learned with an 8 s life",
            whole ~= nil and whole:match(" life=(%d+)") == "8")

        -- BugSack 2026-10-28: "script ran too long" in Stacks and Stack.Multiple under Stack.Learn, one read's work in
        -- one C_Timer callback. The same fight read with a clock that moves 1 ms per look: each call runs one slice
        -- (Teacher's SLICE_MS = 10 looks past the slice's first), and the judging learns what the whole read did. A
        -- fight that opens mid-judging pauses it; its own read is judged after. WoW's Lua 5.1 cannot yield inside a
        -- pcall, so a yield under one fails the check.
        local looks, depth, yieldsInPcall = 0, 0, 0
        local pcallBefore, yieldBefore = pcall, coroutine.yield
        local outcomes, calls, most, paused, pausedLast, samples = {}, 0, 0, nil, nil, nil
        local ran, problem = pcall(function()
            local sliced = BuffFight(nextSession)
            nextSession = nextSession + 1
            local Teacher = sliced.ns.Teacher
            Teacher.OnRead = function(last) outcomes[#outcomes + 1] = last end
            debugprofilestop = function()
                looks = looks + 1
                return looks
            end
            pcall = function(...)
                depth = depth + 1
                local results = table.pack(pcallBefore(...))
                depth = depth - 1
                return table.unpack(results, 1, results.n)
            end
            coroutine.yield = function(...)
                if depth > 0 then yieldsInPcall = yieldsInPcall + 1 end
                return yieldBefore(...)
            end
            local function Call()
                looks, calls = 0, calls + 1
                sliced.Fire()
                most = math.max(most, looks)
            end
            Call()
            Teacher.Start(70)
            Call()
            paused = looks == 0 and #outcomes == 0
            Teacher.Finish(80)
            pausedLast = Teacher.last
            while #sliced.S.timers > 0 do Call() end
            samples = #sliced.ns.Fingerprints.Get(UA).samples
        end)
        debugprofilestop, pcall, coroutine.yield = nil, pcallBefore, yieldBefore
        local first, second = outcomes[1], outcomes[2]
        Check("sliced read: no call runs past its slice, the judging spans calls, no yield under a pcall, and it "
            .. "learns what the whole read did (" .. tostring(problem or calls .. " calls, " .. most .. " looks") .. ")",
            ran and calls > 3 and most <= 11 and yieldsInPcall == 0 and Taught() == whole and first ~= nil
            and wholeLast.learned[UA] ~= nil and first.learned[UA] == wholeLast.learned[UA] and Find(first, UA).verdict == Find(wholeLast, UA).verdict
            and samples == wholeSamples)
        Check("sliced read: a fight that opens mid-judging pauses it; its end resumes it, and its own read is judged "
            .. "after (the same session: a duplicate)",
            ran and paused and pausedLast == nil and #outcomes == 2 and second.skip == "duplicate session")
    end

    do -- own row: a read that shows Lava Burst's own row (51505) keys its next cast by 51505, not API base 73899
        local LAVA_BURST, LAVA_BASE = 51505, 73899
        local rig = Rig({})
        local P1 = rig.Plate("nameplate1")
        rig.S.baseSpells[LAVA_BURST] = LAVA_BASE
        rig.Cast(5, "nameplate1", LAVA_BURST)
        local before = (rig.ns.Casts.SoleCast(P1, 5.1) or {}).base
        rig.Read({}, { Session(1, { Row(LAVA_BURST, 538223) }) })
        rig.Cast(30, "nameplate1", LAVA_BURST)
        Check("own row: after a read with row 51505 the next Lava Burst files under 51505 (before: 73899)",
            before == LAVA_BASE and (rig.ns.Casts.SoleCast(P1, 30.1) or {}).base == LAVA_BURST)
    end

    -- Spec stores (user report 2026-10-28: a resto shaman drew with what elemental learned). Each spec learns into and
    -- draws from its own store; a swap back brings the first spec's learning back.
    local SPEC_A, SPEC_B = 262, 264
    local function Swap(rig, spec)
        rig.S.spec = spec
        rig.ns.Core.PLAYER_SPECIALIZATION_CHANGED("player")
    end
    do
        local rig = Rig({ [SMITE] = 2 })
        local ns = rig.ns
        SlashCmdList.COMBATTEXTICONS("debug")
        T.Store().learned[SWP] = { school = 32, period = 3, kind = "dot", misses = 0 }
        local storeA = T.Store()
        -- Smite's direct hit at t + 0.25 (its icon or nil), and whether SW:P's DoT and Smite's fingerprint are learned.
        local function Shown(t)
            rig.Cast(t, "nameplate1", SMITE)
            return rig.Hit(t + 0.25, "nameplate1", 30, 2), ns.Learn.Get(SWP) ~= nil, ns.Fingerprints.IsLearned(SMITE)
        end
        local drawnA, dotA, fpA = Shown(10)
        Swap(rig, SPEC_B)
        local drawnB, dotB, fpB = Shown(20)
        local logged
        for _, line in ipairs(CombatTextIconsDB.debugLog) do logged = line:match("^[%d%.]+ SPEC .*") or logged end
        SlashCmdList.COMBATTEXTICONS("forget")
        Swap(rig, SPEC_A)
        local drawnBack, dotBack, fpBack = Shown(30)
        Check("spec stores: spec A draws Smite and holds SW:P; spec B draws neither and learned nothing",
            drawnA == "tex:591" and dotA and fpA and drawnB ~= "tex:591" and not dotB and not fpB
            and #ns.Learn.List() == 1)
        Check("spec stores: back in spec A (after /cti forget in B) its own store and learning are back",
            drawnBack == "tex:591" and dotBack and fpBack and T.Store() == storeA
            and CombatTextIconsCharDB.specs[SPEC_B] ~= storeA)
        Check("spec stores: the swap logs a SPEC line (" .. tostring(logged) .. ")",
            logged ~= nil and logged:find(" SPEC 262 %-> 264$") ~= nil)
    end
    do -- a spec unknown at login learns into specs[0]; the first known spec takes that store over
        local ns = T.Boot(function(S) S.spec = nil end)
        local unknown = T.Store()
        unknown.learned[SWP] = { school = 32, period = 3, kind = "dot", misses = 0 }
        T.State().spec = SPEC_A
        ns.Core.PLAYER_ENTERING_WORLD()
        Check("spec stores: the store made before the spec was known becomes the spec's, still learned",
            unknown ~= nil and T.Store() == unknown and CombatTextIconsCharDB.specs[0] == nil
            and ns.Learn.Get(SWP) ~= nil)
    end

    -- A judging in flight across a swap teaches the new spec nothing: a read still queued, and a judging that has
    -- yielded mid-way (sliced reads), are both dropped, as by a /reload.
    do
        local rig = Rig({ [SMITE] = 2 })
        local outcomes = 0
        rig.ns.Teacher.OnRead = function() outcomes = outcomes + 1 end
        rig.Fight({ [SMITE] = { 30 } }, { Session(1, { Row(SMITE, 30) }) })
        Swap(rig, SPEC_B)
        while #rig.S.timers > 0 do rig.Fire() end
        local storeB = T.Store()
        Check("spec swap: a read queued before the swap is dropped (no outcome, nothing saved in the new spec)",
            outcomes == 0 and rig.ns.Teacher.last == nil and storeB.areas == nil and next(storeB.ownRows) == nil)

        rig = Rig({ [SMITE] = 2 })
        outcomes = 0
        rig.ns.Teacher.OnRead = function() outcomes = outcomes + 1 end
        local storeA, looks = T.Store(), 0
        debugprofilestop = function() -- each look is past the slice: the judging yields at its first Teacher.Yield
            looks = looks + 1
            return looks * 100
        end
        rig.Fight({ [SMITE] = { 30 } }, { Session(1, { Row(SMITE, 30) }) })
        local ran = pcall(rig.Fire)
        local paused = outcomes == 0 and #rig.S.timers == 1 and storeA.areas ~= nil
        Swap(rig, SPEC_B)
        local drained = pcall(function() while #rig.S.timers > 0 do rig.Fire() end end)
        debugprofilestop = nil
        storeB = T.Store()
        Check("spec swap: a judging paused mid-way is dropped; what it taught before the swap stays in the old spec",
            ran and paused and drained and outcomes == 0 and rig.ns.Teacher.last == nil and storeB.areas == nil
            and storeB.pace == nil and next(storeB.ownRows) == nil and storeA.ownRows[SMITE] == true)
    end
end
