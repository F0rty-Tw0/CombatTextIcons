-- Unit checks for the post-fight teacher (matcher v2b-1, Phase 4): tally, session read, verdicts,
-- aliases, learning from "?" hits, TEACH lines and the Core wiring. Called by tests/checks.lua with
-- the same T table. Every scenario boots its own rig; a Boot replaces the global stubs.

return function(T)
    local Check, Secret = T.Check, T.Secret
    local DAMAGE = 0
    local SMITE, MIND_BLAST, WAND, HOLY_FIRE = 591, 8092, 5019, 14914
    local AUTO_SHOT, SWP, GRAVE, BARBED = 75, 594, 1260198, 217200
    local nextSession = 100 -- rig.Judge reads a new session ID each call

    local function Count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

    -- A meter row as the probe saved it (every field the real row carries).
    local function Row(spellID, total, overkill)
        return { spellID = spellID, totalAmount = total, overkillAmount = overkill or 0, amountPerSecond = 0,
            combatSpellDetails = {}, creatureName = "", isAvoidable = false, isDeadly = false }
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
        -- One UNIT_COMBAT WOUND at t (area clear); returns the texture drawn, or nil when nothing was drawn.
        function rig.Hit(t, unit, amount, school)
            S.now = t
            local before = #rig.draws
            ns.Core.UNIT_COMBAT(unit, "WOUND", "", amount, school)
            return #rig.draws > before and rig.draws[#rig.draws] or nil
        end
        -- Teacher fight without Core: tally = { [spellID] = { amount, ... } }; the read is queued, not run.
        function rig.Fight(tally, sessions)
            S.sessions = sessions
            ns.Teacher.Start(10)
            for spellID, amounts in pairs(tally) do
                for _, amount in ipairs(amounts) do ns.Teacher.Drawn(spellID, amount) end
            end
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
            local ok, last = rig.Read({ [spellID] = { tally } }, { Session(nextSession, { Row(spellID, total, overkill) }) })
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
        rig.Fight({ [SMITE] = { 30, 23 }, [SWP] = { 81 } }, probe)
        Check("teacher: Finish queues one read after 1 s and reads nothing before it",
            #S.timers == 1 and S.timers[1].delay == 1 and #S.sourceCalls == 0 and Teacher.last == nil
            and Teacher.fight == nil)
        local ok = pcall(rig.Fire)
        local last, call = Teacher.last, S.sourceCalls[1]
        Check("teacher: reads the highest session ID (2 of [1, 2]) for the player's damage done",
            ok and last and last.session == 2 and #S.sourceCalls == 1 and call.id == 2 and call.meterType == DAMAGE
            and call.guid == S.guid)
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
            { Session(4, { Row(SMITE, 53) }), Session(3, { Row(SMITE, 999) }) })
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

    do -- alias pairing and the new-alias rule (teacher read driven directly)
        local rig = Rig({ [WAND] = 4 })
        local F = rig.ns.Fingerprints
        F.SetAlias(AUTO_SHOT, WAND)
        local ok, last = rig.Read({ [WAND] = { 120 } }, { Session(1, { Row(AUTO_SHOT, 100) }) })
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
        CombatTextIconsCharDB.procs = { [id] = { school = 106, lo = 339, hi = 364, streak = learned and 3 or 2,
            learned = learned, unpaired = 0, seen = 0 } }
        rig.ns.Procs.Init(CombatTextIconsCharDB)
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
        local drawn = rig.Hit(200.5, "nameplate5", 91, 4)
        Check("teacher learn: the wand learned from '?' hits now draws its own icon and is tallied",
            drawn == "tex:5019" and Teacher.fight.tally[WAND] == 91)
    end

    do -- a sum that does not match the row teaches nothing
        local rig = Pull(400)
        local F = rig.ns.Fingerprints
        Check("teacher learn: Mind Blast hits summing to 353 against a 400 row (TOL 4) learn nothing; the wand still does",
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
        Check("crowd: a fresh boot is crowded", fresh.Teacher.area == "crowded" and not fresh.Teacher.AreaClear())

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
        local function Crowd(area, seen, group, grouped)
            local rig = Rig({ [SMITE] = 2 }, true)
            local S, Teacher = rig.S, rig.ns.Teacher
            Teacher.area = area
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
                Check("crowd: grouped only at read time counts as a group fight (" .. area .. ")",
                    ok and rig.ns.Teacher.area == area and last.area == "group" and not learned)
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
        for index, pair in ipairs(FIGHTS) do
            local amounts = FightAmounts(pair[1])
            local total = 0
            rig.S.sessions = { DumpSession(900 + index, pair[2]) }
            rig.ns.Teacher.Start(pair[1], false)
            for _, amount in ipairs(amounts) do
                rig.ns.Teacher.Seen(amount)
                total = total + amount
            end
            rig.ns.Teacher.Finish(pair[2])
            pcall(rig.Fire)
            local last = rig.ns.Teacher.last
            seen[index] = string.format("%d", total)
            outcomes[index] = last.skip and ("skip:" .. last.skip) or last.area
            if index == 1 then areaAfterFirst = rig.ns.Teacher.area end
        end
        local seenList, outcomeList = table.concat(seen, ","), table.concat(outcomes, ",")
        Check("crowd probe6: seen totals are 450307, 221409, 1026076, 191434, 34506472", seenList == "450307,221409,1026076,191434,34506472")
        Check("crowd probe6: reads give skip, clear, clear, clear, crowded", outcomeList == "skip:secret,clear,clear,clear,crowded")
        Check("crowd probe6: the state stays crowded through the skipped first read", areaAfterFirst == "crowded")
    end

    do -- safety net (spec 3.3): learned DoTs and channels are judged by every read
        local TRIGGER, VT = 1227280, 34914 -- Tentacle Slam (no meter row of its own), Vampiric Touch (row 34914)
        local function Seed(rig, id)
            CombatTextIconsCharDB.learned[id] = { school = 32, period = 3, kind = "dot", misses = 0 }
            rig.ns.Learn.Init()
        end
        -- One read of a fresh session; tally = { [id] = total }. Returns Teacher.last.
        local function Step(rig, tally, rows)
            nextSession = nextSession + 1
            local amounts = {}
            for id, total in pairs(tally) do amounts[id] = { total } end
            local ok, last = rig.Read(amounts, { Session(nextSession, rows) })
            assert(ok, last)
            return last
        end
        local function Kept(rig, id) return rig.ns.Learn.Get(id) ~= nil end
        local function Strike(rig, id) return Step(rig, { [id] = 500 }, { Row(GRAVE, 56) }) end -- drawn, no row, no agreeing row

        do -- rule 1: over drops at once; under keeps
            local rig = Rig({}); Seed(rig, TRIGGER)
            Step(rig, { [TRIGGER] = 40 }, { Row(TRIGGER, 100) })
            Check("net: an under read (40 vs 100) keeps the learned spell", Kept(rig, TRIGGER))
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
            Step(rig, { [TRIGGER] = 40 }, { Row(TRIGGER, 100) }) -- under
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

        do -- rule 2: no alias for a learned spell; it is struck instead
            local rig = Rig({}); Seed(rig, TRIGGER)
            local F = rig.ns.Fingerprints
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
            local last = Step(rig, { [TRIGGER] = 6000, [WAND] = 6000 }, { Row(VT, 6000) })
            Check("net rule 2: two missing tallies (learned X, unlearned Y) both agreeing with the row -> no alias",
                rig.ns.Fingerprints.Alias(VT) == nil and Find(last, TRIGGER).verdict == "unpaired"
                and Find(last, WAND).verdict == "unpaired" and Find(last, VT).verdict == "unpaired")
            Check("net rule 2: ... and the learned X is kept after one such read", Kept(rig, TRIGGER))
            Step(rig, { [TRIGGER] = 6000, [WAND] = 6000 }, { Row(VT, 6000) })
            Check("net rule 2: ... and struck again by the second, so it is dropped", not Kept(rig, TRIGGER))
        end

        do -- every area applies the net
            for _, group in ipairs({ false, true }) do
                local rig = Rig({}); Seed(rig, TRIGGER)
                local Teacher = rig.ns.Teacher
                for read = 1, 2 do
                    nextSession = nextSession + 1
                    rig.S.sessions = { Session(nextSession, { Row(GRAVE, 56) }) }
                    Teacher.Start(10, group)
                    Teacher.Drawn(TRIGGER, 500)
                    Teacher.Seen(1e9) -- far above the meter: crowded (solo) or group
                    Teacher.Finish(20)
                    pcall(rig.Fire)
                    if read == 1 then Check("net: first strike keeps it (" .. Teacher.last.area .. ")", Kept(rig, TRIGGER)) end
                end
                Check("net: the second strike drops it (" .. Teacher.last.area .. ")",
                    not Kept(rig, TRIGGER) and Teacher.last.area == (group and "group" or "crowded"))
            end
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
            Step(rig, { [PROC] = 40 }, { Row(PROC, 100) })
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
            for _, hit in ipairs(hits) do rig.ns.Teacher.Unknown(P1, hit[1], hit[2], hit[5] or 60.25, hit[4], hit[3] or "") end
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
            Check("procs wiring: 339 + 350 + 364 = 1053 meets the row exactly: candidate, streak 1, not learned",
                Candidate(rig, X) and Candidate(rig, X).streak == 1 and not Candidate(rig, X).learned)
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
                CombatTextIconsCharDB.procs = { [id] = { school = 106, lo = lo, hi = 5827, streak = 1, learned = false,
                    unpaired = 0, seen = 0 } }
                rig.ns.Procs.Init(CombatTextIconsCharDB)
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
                and next(CombatTextIconsCharDB.castAliases) == nil and Find(last, MIND_BLAST).verdict == "agree")

            keys = {}
            local okLater, drawn, tally = pcall(Fight, { { 50, VOID_BLAST, 300 } }, { Row(MIND_BLAST, 300) })
            Check("base spell: a later Void Blast hit draws Void Blast's icon, tallies and ledgers under 8092, and agrees",
                okLater and drawn[1] == "tex:" .. VOID_BLAST and tally[MIND_BLAST] == 300 and tally[VOID_BLAST] == nil
                and keys[MIND_BLAST] and not keys[VOID_BLAST] and Find(ns.Teacher.last, MIND_BLAST).verdict == "agree"
                and F.Get(MIND_BLAST).fights == 1)
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

            rig = Rig({})
            SeedProc(rig, Y, false) -- candidate, streak 2
            _, last = Meter(rig, Y)
            Check("procs rule 2: the only agreeing row is a candidate's (streak >= 1): no alias, nothing paired",
                rig.ns.Fingerprints.Alias(Y) == nil and Find(last, Y) and Find(last, Y).verdict == "unpaired"
                and Find(last, MIND_BLAST) and Find(last, MIND_BLAST).verdict == "unpaired")

            rig = Rig({})
            CombatTextIconsCharDB.procs = { [Y] = { school = 106, lo = 339, hi = 364, streak = 0, learned = false, unpaired = 0, seen = 0 } }
            rig.ns.Procs.Init(CombatTextIconsCharDB)
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

        do -- Review Focus 4: clear at hit time, crowded at read time: no learning, the net still judges the drawn tally
            for _, case in ipairs({ { total = 100, verdict = "over", kept = false }, { total = 350, verdict = "agree", kept = true } }) do
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
                    .. ", proc " .. (case.kept and "kept" or "dropped") .. ", Procs.Read not called",
                    rig.ns.Teacher.last.area == "crowded" and Find(rig.ns.Teacher.last, X).verdict == case.verdict
                    and (rig.ns.Procs.Get(X) ~= nil) == case.kept and spy.calls == 0)
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
            local rig = Rig({})
            SlashCmdList.COMBATTEXTICONS("debug")
            local fights = {
                { { 106, 339 }, { 106, 350 }, { 106, 364 } },
                { { 106, 340 }, { 106, 352 }, { 106, 361 } },
                { { 106, 345 }, { 106, 348 }, { 106, 360 } },
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
        rig.S.group = true
        Check("procs route: in a group the proc hit stays hidden and unrecorded",
            Wound(rig, 350) == nil and #rig.ns.Teacher.fight.unknown == 0 and rig.ns.Teacher.fight.tally[X] == nil
            and not Logged("-> proc"))

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
        Check("procs route: the Tracker UNKNOWN path draws ? (never the proc) and hands flagText to Teacher.Unknown",
            trackerUnknown == UNKNOWN and flagSeen == "CRITICAL" and rig.ns.Teacher.fight.tally[X] == nil)

        rig = ProcRig() -- X learned; add a candidate
        CombatTextIconsCharDB.procs[900001] = { school = 106, lo = 100, hi = 110, streak = 1, learned = false, unpaired = 0, seen = 0 }
        rig.ns.Procs.Init(CombatTextIconsCharDB)
        local before = #rig.ns.Procs.List()
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("procs forget: /cti forget clears learned procs and candidates (2 before), in the saved table too",
            before == 2 and rig.ns.Procs.Get(X) == nil and #rig.ns.Procs.List() == 0 and next(CombatTextIconsCharDB.procs) == nil)
    end
end
