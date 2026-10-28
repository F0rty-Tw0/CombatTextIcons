-- Unit checks for the cast backbone (matcher v2b-1): the cast log, fingerprints, open records and the
-- one hit route (no meter reads or resets). Called by tests/checks.lua with the same T table. Every
-- scenario boots its own rig; a Boot replaces the global stubs, so a rig is dead once the next one boots.

return function(T)
    local Check = T.Check
    local RENEW, BARBED = 139, 217200

    -- A booted addon with Display stubbed and the crowd check's area clear. `spells` loads the fixture table
    -- as ns.Spells.
    local function Rig(spells)
        local rig = {}
        local ns = T.Boot(function(S)
            S.harmful[RENEW], S.helpful[RENEW] = false, true
            CombatTextIconsDB = { enabled = true }
        end, spells)
        local S = T.State()
        rig.ns, rig.S = ns, S
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(_, texture, text) rig.last = { kind = "plate", texture = texture, text = text } end
        ns.Display.Player = function(kind, texture, text) rig.last = { kind = kind, texture = texture, text = text } end
        function rig.Slash(text) SlashCmdList.COMBATTEXTICONS(text) end
        function rig.Cast(t, id, target)
            S.now, S.target = t, target
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-" .. t, id)
        end
        -- The draw this hit made (nil: hidden); an unexplained solo hit draws '?' in the call while clear.
        function rig.Hit(t, unit, event, amount, school, flag)
            S.now, rig.last = t, nil
            ns.Core.UNIT_COMBAT(unit, event, flag or "", amount, school)
            return rig.last
        end
        return rig
    end

    do -- nothing resets or reads the meter (Review Focus 2 and 3)
        local rig = Rig(true)
        local S, ns = rig.S, rig.ns
        Check("single mode: login does not reset the meter", S.resets == 0)
        rig.Slash("off")
        rig.Slash("on")
        ns.Core.PLAYER_REGEN_ENABLED()
        local hit = rig.Hit(10, "nameplate1", "WOUND", 5000, 32)
        Check("meter off: /cti off, /cti on, regen and a hit never reset the meter", S.resets == 0)
        Check("meter off: an unattributed solo hit on a mob fighting you draws '?'",
            hit and hit.texture == ns.Meter.UNKNOWN_ICON and hit.text == 5000)
        S.group = true
        Check("meter off: the same hit in a group stays hidden", rig.Hit(11, "nameplate1", "WOUND", 5000, 32) == nil)
        S.group = false

        S.haste = 0
        rig.Cast(50, BARBED, "nameplate2")
        local tick = rig.Hit(52, "nameplate2", "WOUND", 800, 1)
        Check("meter off: a tracked tick still draws its spell icon", tick and tick.texture == "tex:" .. BARBED)

        local taken = rig.Hit(100, "player", "WOUND", 4500, 32)
        Check("meter off: damage taken still shows, without an icon",
            taken and taken.kind == "taken" and taken.texture == nil and taken.text == 4500)

        CombatTextIconsCharDB.learned[RENEW] = { school = 2, period = 3, kind = "hot", misses = 0 }
        ns.Learn.Init()
        rig.Cast(200, RENEW, nil)
        local heals = {}
        for k = 1, 3 do heals[k] = rig.Hit(200 + 3 * k, "player", "HEAL", 800, 2) end
        Check("meter off: a learned HoT still draws every tick over the player", heals[1] and heals[2] and heals[3]
            and heals[1].kind == "heal" and heals[1].texture == "tex:" .. RENEW and heals[3].texture == "tex:" .. RENEW)

        local ok = pcall(function()
            rig.Hit(300, "player", "HEAL", 800, 2) -- a heal nothing explains
            rig.Hit(301, "nameplate1", "MISS", nil, 32)
        end)
        Check("meter off: heals nothing explains and misses raise no error", ok)

        local identify, feed, fed = ns.Tracker.Identify, ns.Streams.Feed, 0
        ns.Tracker.Identify = function() return ns.Tracker.UNKNOWN end
        ns.Streams.Feed = function(...) fed = fed + 1 return feed(...) end
        local solo = rig.Hit(310, "nameplate1", "WOUND", 5000, 32)
        S.group = true
        local grouped = rig.Hit(311, "nameplate1", "WOUND", 5000, 32)
        S.group = false
        ns.Tracker.Identify, ns.Streams.Feed = identify, feed
        Check("meter off: an UNKNOWN tracker answer draws '?' solo and in a group (spec C9), and feeds no stream",
            solo and solo.texture == ns.Meter.UNKNOWN_ICON and grouped and grouped.texture == ns.Meter.UNKNOWN_ICON
            and fed == 0)

        Check("meter off: after all of it still no meter reset", S.resets == 0)
    end

    do -- run 20261025T182530Z: Surging Totem's ~12K Nature hits (learned proc 73921) taught Lava Burst, cast in its frame, as a DoT
        local rig = Rig()
        local ns = rig.ns
        CombatTextIconsCharDB.procs = { [73921] = { school = 8, lo = 11612, hi = 11871, streak = 3, learned = true,
            unpaired = 0, seen = 0 } }
        ns.Procs.Init(CombatTextIconsCharDB)
        local feed, fed = ns.Streams.Feed, {}
        ns.Streams.Feed = function(plate, school, amount, ...)
            fed[#fed + 1] = amount
            return feed(plate, school, amount, ...)
        end
        local proc = rig.Hit(10, "nameplate1", "WOUND", 12007, 8)
        rig.Hit(11.6, "nameplate1", "WOUND", 5000, 8)
        ns.Teacher.area = "crowded"
        rig.Hit(13.2, "nameplate1", "WOUND", 11887, 8)
        ns.Streams.Feed = feed
        Check("streams: a hit a learned proc names is never fed to the streams, clear or crowded (12007, 11887); others are (5000)",
            proc and proc.texture == "tex:73921" and #fed == 1 and fed[1] == 5000)
    end

    do -- Lightning Bolt hits 0.33-0.47 s after its cast drew as a mislearned Lava Burst DoT: a learned cast fingerprint wins
        local DOT, BOLT = 51505, 188196
        local function Run(boltLearned, delay)
            local rig = Rig()
            local ns = rig.ns
            CombatTextIconsCharDB.learned = { [DOT] = { school = 8, period = 1.65, kind = "dot", misses = 0 } }
            ns.Learn.Init(CombatTextIconsCharDB)
            if boltLearned then
                for castAt = 1, 3 do ns.Fingerprints.Add(BOLT, { school = 8, delay = 0.4, castAt = castAt, hops = 1 }) end
            end
            rig.Cast(10, DOT, "nameplate1")
            rig.Cast(11.65 - delay, BOLT, "nameplate1")
            local bolt = rig.Hit(11.65, "nameplate1", "WOUND", 90, 8)

            return bolt and bolt.texture
        end
        Check("core: a hit a learned cast fingerprint fits in its window draws the cast, not a learned DoT's answer",
            Run(true, 0.4) == "tex:" .. BOLT)
        Check("core: with no learned fingerprint the learned DoT still answers the hit", Run(false, 0.4) == "tex:" .. DOT)
        Check("core: a hit the fingerprint fits only late (0.9 s of a 0.4 s window) stays with the learned DoT",
            Run(true, 0.9) == "tex:" .. DOT)
    end

    do
        local rig = Rig()
        Check("core: PLAYER_REGEN_DISABLED exists and runs",
            type(rig.ns.Core.PLAYER_REGEN_DISABLED) == "function" and pcall(rig.ns.Core.PLAYER_REGEN_DISABLED))
    end

    -- Boots the addon (solo, default stubs; `spells` loads the fixture table as ns.Spells); Display.Plate records the texture drawn.
    local function CastRig(setup, spells)
        local rig = { draws = {} }
        rig.ns = T.Boot(setup, spells)
        rig.S = T.State()
        local ns, S = rig.ns, rig.S
        ns.Display.Plate = function(plate, texture) rig.draws[#rig.draws + 1] = texture end
        function rig.Plate(unit) return C_NamePlate.GetNamePlateForUnit(unit, false) end
        -- A harmful player cast at t with `unit` targeted (nil = no target).
        function rig.Cast(t, unit, spellID)
            S.now, S.target = t, unit
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c" .. t, spellID)
        end
        return rig
    end

    do -- Task 2.1: cast log and SoleCast
        local rig = CastRig(nil, true)
        local Casts, S = rig.ns.Casts, rig.S
        local P1, P2 = rig.Plate("nameplate1"), rig.Plate("nameplate2")

        S.target = "nameplate1"
        local atTarget = rig.ns.Tracker.TargetPlate()
        S.target = nil
        Check("tracker: TargetPlate returns the targeted plate, nil without a target",
            atTarget == P1 and rig.ns.Tracker.TargetPlate() == nil)

        rig.Cast(10, "nameplate1", 591)
        local sole = Casts.SoleCast(P1, 10.5)
        Check("soleCast: one non-tracker cast on the plate returns its log entry",
            sole and sole.spellID == 591 and sole.at == 10 and sole.plate == P1 and sole.tracker == false)
        Check("soleCast: a hit on another plate -> nil", Casts.SoleCast(P2, 10.5) == nil)
        Check("soleCast: window is [at - 1.5, at], start inclusive",
            Casts.SoleCast(P1, 11.5) ~= nil and Casts.SoleCast(P1, 11.51) == nil)

        rig.Cast(20, "nameplate1", 980) -- Curse of Agony: a tracker spell
        Check("soleCast: a tracker cast alone -> nil (no sample from it)", Casts.SoleCast(P1, 20.25) == nil)

        rig.Cast(30, "nameplate1", 591); rig.Cast(30.25, "nameplate1", 8092)
        Check("soleCast: a second harmful cast in the window -> nil", Casts.SoleCast(P1, 30.5) == nil)
        rig.Cast(40, "nameplate1", 591); rig.Cast(41.75, "nameplate1", 8092)
        Check("soleCast: the older cast aged out of the window -> the newer one",
            (Casts.SoleCast(P1, 41.75) or {}).spellID == 8092)

        -- Run shaman3 start: a stale save learned Lava Burst 51505 as a Nature DoT; its Fire hits sat unexplained.
        CombatTextIconsCharDB.learned = { [51505] = { school = 8, period = 1.65, kind = "dot", misses = 0 } }
        rig.ns.Learn.Init(CombatTextIconsCharDB)
        rig.Cast(50, "nameplate1", 51505)
        local function Named(list) return #list == 1 and list[1].castSpell == 51505 end
        Check("soleCast: a learned DoT's cast stays the cast for a hit of another school (Fire 4 vs its Nature 8 ticks)",
            (Casts.SoleCast(P1, 50.4, 4) or {}).spellID == 51505 and Casts.SoleCast(P1, 50.4, 8) == nil
            and Casts.SoleCast(P1, 50.4) == nil and Named(Casts.Candidates(P1, 50.4, 4))
            and #Casts.Candidates(P1, 50.4, 8) == 0)
        Check("soleCast: a table tracker spell (no learned school) hides hits of every school",
            Casts.SoleCast(P1, 20.25, 4) == nil)

        S.harmful[2061] = false
        rig.Cast(50, "nameplate1", 2061)
        Check("soleCast: a non-harmful cast is not logged", Casts.SoleCast(P1, 50.25) == nil)

        rig.Cast(60, nil, 591)
        Check("soleCast: a cast with no target plate gives nothing, not even for a nil plate",
            Casts.SoleCast(nil, 60.25) == nil and Casts.SoleCast(P1, 60.25) == nil)

        rig.Cast(70, "nameplate1", 591); rig.Cast(70.5, "nameplate1", 8092)
        Check("soleCast: a cast after `at` is not counted", (Casts.SoleCast(P1, 70.25) or {}).spellID == 591)

        rig.Cast(80, "nameplate1", 450983) -- Void Blast, an override of Mind Blast
        local override = Casts.SoleCast(P1, 80.25) or {}
        Check("soleCast: an override cast keeps its own spellID and names its base (Void Blast 450983 -> base 8092)",
            override.spellID == 450983 and override.base == 8092 and sole.base == 591)

        -- In game (2026-10-25) two Mind Blasts or Void Blasts within 1.5 s left their hit castless, so 8092 never paired.
        rig.Cast(90, "nameplate1", 8092); rig.Cast(90.4, "nameplate1", 8092)
        local twice = Casts.SoleCast(P1, 90.6) or {}
        rig.Cast(100, "nameplate1", 8092); rig.Cast(100.4, "nameplate1", 450983)
        local mixed = Casts.SoleCast(P1, 100.6) or {}
        Check("soleCast: casts of one base in the window count as one, the newest answers (8092 twice; 8092 then 450983)",
            twice.at == 90.4 and mixed.spellID == 450983 and mixed.base == 8092)
    end

    do -- base spell: Casts.Base asks the client which spell a cast overrides; any doubt answers the cast itself
        local VOID_BLAST, MIND_BLAST = 450983, 8092
        local ns = T.Boot()
        -- Casts.Base(id) with C_SpellBook.FindBaseSpellByID replaced by `find` (nil: no C_SpellBook) and the
        -- deprecated global FindBaseSpellByID set to `global`; false when Base raised.
        local function BaseWith(find, global, id)
            local spellBook = C_SpellBook
            C_SpellBook, FindBaseSpellByID = find and { FindBaseSpellByID = find }, global
            local ok, base = pcall(ns.Casts.Base, id or VOID_BLAST)
            C_SpellBook, FindBaseSpellByID = spellBook, nil
            return ok and base
        end
        local function Map(id) return id == VOID_BLAST and MIND_BLAST or id end
        Check("base: an override answers its base spell (450983 -> 8092), any other cast answers itself",
            BaseWith(Map) == MIND_BLAST and BaseWith(Map, nil, 591) == 591)
        Check("base: without C_SpellBook the deprecated global FindBaseSpellByID answers",
            BaseWith(nil, Map) == MIND_BLAST)
        Check("base: with neither API the cast is its own base", BaseWith(nil, nil) == VOID_BLAST)
        Check("base: an erroring API answers the cast itself",
            BaseWith(function() error("restricted") end) == VOID_BLAST)
        Check("base: a secret, nil or non-number answer is the cast itself",
            BaseWith(function() return T.Secret(MIND_BLAST) end) == VOID_BLAST
            and BaseWith(function() return nil end) == VOID_BLAST
            and BaseWith(function() return "8092" end) == VOID_BLAST)
    end

    do -- base memory: run 20261025T162725Z, a window's last Void Blast (5931.198) read base=450983 and its hit drew '?'
        local VOID_BLAST, MIND_BLAST = 450983, 8092
        local ns = T.Boot()
        local function BaseWith(find, id)
            local spellBook = C_SpellBook
            C_SpellBook = { FindBaseSpellByID = find }
            local ok, base = pcall(ns.Casts.Base, id or VOID_BLAST)
            C_SpellBook = spellBook
            return ok and base
        end
        local function Map(id) return id == VOID_BLAST and MIND_BLAST or id end
        local function Self(id) return id end
        Check("base memory: an override seen once keeps its base when the API later answers the cast itself (450983 -> 8092)",
            BaseWith(Map) == MIND_BLAST and BaseWith(Self) == MIND_BLAST)
        Check("base memory: a cast never seen overridden answers itself (591)", BaseWith(Self, 591) == 591)
        Check("base memory: an erroring API still answers the cast itself",
            BaseWith(function() error("restricted") end) == VOID_BLAST)

        local rig = CastRig(nil, true)
        local S, P1 = rig.S, rig.Plate("nameplate1")
        rig.Cast(10, "nameplate1", VOID_BLAST)
        S.baseSpells[VOID_BLAST] = nil
        rig.Cast(20, "nameplate1", VOID_BLAST)
        S.baseSpells[VOID_BLAST] = MIND_BLAST
        Check("base memory: a Void Blast cast after its override ended files under 8092",
            (rig.ns.Casts.SoleCast(P1, 20.25) or {}).base == MIND_BLAST)
    end

    do -- own row: run 20261025T175419Z, Lava Burst 51505 (API base 73899) has its own meter row and no 73899 row
        local LAVA_BURST, LAVA_BASE, VOID_BLAST, MIND_BLAST = 51505, 73899, 450983, 8092
        local ns = T.Boot()
        local S = T.State()
        S.baseSpells[LAVA_BURST] = LAVA_BASE
        local before = ns.Casts.Base(LAVA_BURST)
        ns.Casts.NoteRows({ { spellID = LAVA_BURST, total = 538223, overkill = 0 },
            { spellID = MIND_BLAST, total = 1000, overkill = 0 } })
        Check("own row: a cast keys by its API base until the meter shows a row of its own (51505: 73899 -> 51505)",
            before == LAVA_BASE and ns.Casts.Base(LAVA_BURST) == LAVA_BURST)
        Check("own row: a row of a base changes nothing for its override (row 8092, Void Blast stays 8092)",
            ns.Casts.Base(VOID_BLAST) == MIND_BLAST)
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("own row: saved per character and kept by /cti forget", CombatTextIconsCharDB.ownRows[LAVA_BURST] == true
            and ns.Casts.Base(LAVA_BURST) == LAVA_BURST)

        ns = T.Boot(function(S)
            S.baseSpells[LAVA_BURST] = LAVA_BASE
            CombatTextIconsCharDB = { ownRows = { [LAVA_BURST] = true, ["188196"] = true, [188443] = 1 } }
        end)
        local saved = CombatTextIconsCharDB.ownRows
        Check("own row: login keeps a saved row and drops a string key and a non-true value",
            ns.Casts.Base(LAVA_BURST) == LAVA_BURST and saved[LAVA_BURST] == true and saved["188196"] == nil
            and saved[188443] == nil)
        T.Boot(function() CombatTextIconsCharDB = { ownRows = "x" } end)
        Check("own row: login replaces a non-table ownRows", type(CombatTextIconsCharDB.ownRows) == "table")
    end

    do -- Task 2.2: Fingerprints
        local function Sample(school, delay, castAt, hops) return { school = school, delay = delay, castAt = castAt, hops = hops or 1 } end
        local function Count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

        -- learn rule (spec 6.2): 3 samples from 3 DIFFERENT castAt sharing a school
        local F = T.Boot().Fingerprints
        local charDB = {}
        F.Init(charDB)
        F.Add(591, Sample(2, 0.20, 10)); F.Add(591, Sample(2, 0.25, 20)); F.Add(591, Sample(2, 0.30, 20))
        Check("fingerprints: first sample creates an unlearned entry; 3 samples from 2 casts do not learn",
            F.Get(591) and F.Get(591).learned == false and not F.IsLearned(591) and #F.Get(591).samples == 3)
        F.Add(591, Sample(2, 0.22, 30))
        local e = F.Get(591)
        Check("fingerprints: learned at the third distinct cast: school fixed, delays kept, range 0.20-0.30, pattern single",
            F.IsLearned(591) and e.school == 2 and #e.delays == 4 and e.delayLo == 0.20 and e.delayHi == 0.30
            and e.pattern == "single" and e.lastSeen == 30 and e.samples[#e.samples].castAt == 30)
        Check("fingerprints: the entry lives in charDB.casts", charDB.casts[591] == e)

        -- two schools: only a school with 3 distinct casts learns, then it is fixed
        for index, school in ipairs({ 2, 4, 2, 4 }) do F.Add(592, Sample(school, 0.2, index)) end
        Check("fingerprints: 2 + 2 samples of two schools do not learn", not F.IsLearned(592))
        F.Add(592, Sample(2, 0.2, 5))
        local before = #F.Get(592).samples
        Check("fingerprints: the school with 3 casts is learned", F.IsLearned(592) and F.Get(592).school == 2)
        F.Add(592, Sample(4, 0.9, 6))
        Check("fingerprints: a later sample of another school is ignored",
            #F.Get(592).samples == before and F.Get(592).delayHi == 0.2)

        -- delay ring of 8 and samples of 16: new delays widen at once, old ones age out
        for index = 1, 8 do F.Add(593, Sample(2, 0.2, index)) end
        F.Add(593, Sample(2, 0.5, 9))
        Check("fingerprints: a slower delay widens the range at once",
            F.Get(593).delayHi == 0.5 and F.Get(593).delayLo == 0.2 and #F.Get(593).delays == 8)
        for index = 10, 17 do F.Add(593, Sample(2, 0.2, index)) end
        Check("fingerprints: after 8 more samples the slow delay has aged out of the delays; 16 samples kept",
            F.Get(593).delayHi == 0.2 and #F.Get(593).delays == 8 and #F.Get(593).samples == 16
            and F.Get(593).samples[1].castAt == 2)

        -- pattern: chain while a sample with hops >= 2 is among the last 16
        for index = 1, 3 do F.Add(594, Sample(2, 0.2, index)) end
        Check("fingerprints: single hops -> pattern single", F.Get(594).pattern == "single")
        F.Add(594, Sample(2, 0.2, 4, 3))
        Check("fingerprints: a sample with 3 hops -> pattern chain", F.Get(594).pattern == "chain")
        for index = 5, 19 do F.Add(594, Sample(2, 0.2, index)) end
        Check("fingerprints: the chain sample is still among the last 16 -> pattern chain", F.Get(594).pattern == "chain")
        F.Add(594, Sample(2, 0.2, 20))
        Check("fingerprints: the chain sample aged out of the 16 -> pattern single again", F.Get(594).pattern == "single")

        -- teacher verdicts: strikes in a row
        F.Agree(591)
        Check("fingerprints: Agree counts a fight, strikes 0", F.Get(591).fights == 1 and F.Get(591).strikes == 0)
        F.Over(591)
        Check("fingerprints: one Over = over 1, strike 1, entry kept",
            F.Get(591).over == 1 and F.Get(591).strikes == 1)
        F.Agree(591); F.Over(591)
        Check("fingerprints: an Agree between two Overs resets the strikes (kept)", F.Get(591) ~= nil and F.Get(591).strikes == 1)
        F.Over(591)
        Check("fingerprints: 2 strikes in a row delete the entry", F.Get(591) == nil)
        Check("fingerprints: Agree / Over on a missing spell do nothing", pcall(F.Agree, 999) and pcall(F.Over, 999))

        -- cap 64: unlearned entry with the oldest lastSeen goes first, a learned one only when all 64 are learned
        local cap = {}
        F.Init(cap)
        for castAt = 1, 3 do F.Add(1, Sample(2, 0.2, castAt)) end        -- spell 1: learned, lastSeen 3 (the oldest)
        for id = 2, 64 do F.Add(id, Sample(2, 0.2, 100 + id)) end        -- 63 unlearned
        F.Add(65, Sample(2, 0.2, 200))
        Check("fingerprints: cap 64 evicts the oldest unlearned entry, keeps the older learned one",
            Count(cap.casts) == 64 and F.Get(2) == nil and F.IsLearned(1) and F.Get(3) and F.Get(65))
        local full = {}
        F.Init(full)
        for id = 1, 64 do for k = 1, 3 do F.Add(id, Sample(2, 0.2, id * 10 + k)) end end
        for id = 2, 64 do F.Agree(id) end
        F.Add(65, Sample(2, 0.2, 900))
        Check("fingerprints: with 64 learned, the one with fewest fights goes",
            Count(full.casts) == 64 and F.Get(1) == nil and F.IsLearned(2) and F.Get(65) and not F.IsLearned(65))

        -- aliases
        local aliases = {}
        F.Init(aliases)
        F.SetAlias(75, 5019)
        F.SetAlias("x", 1); F.SetAlias(76, "y")
        Check("fingerprints: alias 75 -> 5019; bad types are not stored",
            F.Alias(75) == 5019 and F.Alias(76) == nil and Count(aliases.castAliases) == 1)

        -- secret values: nothing stored, nothing errors
        local secretDB = {}
        F.Init(secretDB)
        local ok1 = pcall(F.Add, T.Secret(591), Sample(2, 0.2, 1))
        local ok2 = pcall(F.Add, 591, Sample(T.Secret(2), 0.2, 1))
        local ok3 = pcall(F.Add, 591, Sample(2, T.Secret(0.2), 1))
        local ok4 = pcall(F.SetAlias, T.Secret(75), 5019)
        Check("fingerprints: a secret spell, school or delay is ignored without error",
            ok1 and ok2 and ok3 and ok4 and next(secretDB.casts) == nil and next(secretDB.castAliases) == nil)

        -- load validation (Review Focus 5): through the real login
        local good = { learned = true, school = 2, pattern = "single", delays = { 0.1, 0.2 }, samples = {}, fights = 0,
            over = 0, strikes = 0, lastSeen = 1 }
        local function Copy(extra) local c = {} for k, v in pairs(good) do c[k] = v end for k, v in pairs(extra or {}) do c[k] = v end return c end
        T.Boot(function()
            CombatTextIconsCharDB = { casts = {
                [591] = Copy(),
                foo = Copy(),                                  -- string key
                [592] = Copy({ learned = "yes" }),             -- non-boolean learned
                [593] = Copy({ delays = {} }),                 -- learned, empty delays
                [594] = Copy({ school = "x" }),                -- learned, school not a number
                [595] = Copy({ pattern = "aoe" }),             -- unknown pattern
            }, castAliases = { [75] = "x", [76] = 5019, abc = 3 } }
        end)
        local loaded = CombatTextIconsCharDB
        Check("fingerprints: garbage entries are pruned on login, the valid one stays with its range recomputed",
            Count(loaded.casts) == 1 and loaded.casts[591] and loaded.casts[591].delayLo == 0.1 and loaded.casts[591].delayHi == 0.2)
        Check("fingerprints: only number -> number aliases survive", Count(loaded.castAliases) == 1 and loaded.castAliases[76] == 5019)
        T.Boot(function() CombatTextIconsCharDB = { casts = "x", castAliases = 5 } end)
        Check("fingerprints: non-table casts / castAliases are replaced by empty tables",
            type(CombatTextIconsCharDB.casts) == "table" and type(CombatTextIconsCharDB.castAliases) == "table")

        -- /cti forget clears the fingerprints and aliases in place
        local ns = T.Boot()
        ns.Fingerprints.Add(591, Sample(2, 0.2, 1)); ns.Fingerprints.SetAlias(75, 5019)
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("fingerprints: /cti forget empties casts and castAliases",
            next(CombatTextIconsCharDB.casts) == nil and next(CombatTextIconsCharDB.castAliases) == nil
            and ns.Fingerprints.Get(591) == nil)
    end

do -- Phase 3: records and Claim
    local WAND, CL, AGONY, UNLEARNED = 5019, 188443, 980, 589
    local function Scenario(name, fn) local ok, result = pcall(fn) T.Check(name, ok and result == true) end
    local function Learn3(ns, id, school, delay, hops) -- three samples, three distinct castAt: learned
        for index = 1, 3 do ns.Fingerprints.Add(id, { school = school, delay = delay, castAt = index, hops = hops or 1 }) end
    end
    local function Rig(learn, spells)
        local ns = T.Boot(nil, spells)
        if learn then learn(ns) end
        return ns, T.State()
    end
    local function Cast(ns, S, id, t, unit) S.now, S.target = t, unit ns.Casts.NoteCast(id, t) end
    local function Plate(unit) return C_NamePlate.GetNamePlateForUnit(unit, false) end
    local Wand = function(ns) Learn3(ns, WAND, 4, 0.2) end -- window [0.15, 0.25] after the cast
    -- Shadow samples of `castSpell` under `id`, one per cast, with sizes (and delays, default 0.2).
    local function LearnSized(ns, id, castSpell, sizes, delays)
        for castAt, size in ipairs(sizes) do
            ns.Fingerprints.Add(id, { school = 32, delay = delays and delays[castAt] or 0.2, castAt = castAt, hops = 1,
                spell = castSpell, size = size })
        end
    end

    Scenario("band: the min / max size of the cast spell's samples", function()
        local ns = Rig(function(n) LearnSized(n, 8092, 8092, { 18000, 21000, 25000 }) end)
        local low, high = ns.Fingerprints.Band(8092, 8092)
        return low == 18000 and high == 25000
    end)
    Scenario("band: a cast spell with no sized sample (Void Blast) falls back to the whole entry's sizes", function()
        local ns = Rig(function(n) LearnSized(n, 8092, 8092, { 18000, 21000, 25000 }) end)
        local low, high = ns.Fingerprints.Band(8092, 450983)
        return low == 18000 and high == 25000
    end)
    Scenario("band: none without sized samples or before the spell is learned", function()
        local ns = Rig(function(n) Wand(n); LearnSized(n, 8092, 8092, { 18000, 21000 }) end)
        return ns.Fingerprints.Band(WAND, WAND) == nil and ns.Fingerprints.Band(8092, 8092) == nil
    end)
    Scenario("band: a size of 0, below 0 or not a number keeps the sample without a size", function()
        local ns = Rig()
        for castAt, size in ipairs({ 0, -5, "x" }) do
            ns.Fingerprints.Add(8092, { school = 32, delay = 0.2, castAt = castAt, hops = 1, size = size })
        end
        local samples = ns.Fingerprints.Get(8092).samples
        return #samples == 3 and samples[1].size == nil and samples[2].size == nil and samples[3].size == nil
    end)
    Scenario("band: saved samples with a bad size lose it on load and stay", function()
        local function Saved(castAt, size) return { school = 32, delay = 0.2, castAt = castAt, hops = 1, size = size } end
        T.Boot(function()
            CombatTextIconsCharDB = { casts = { [8092] = { learned = true, pattern = "single", school = 32, delays = { 0.2 },
                samples = { Saved(1, 20000), Saved(2, "x"), Saved(3, -5) } } } }
        end)
        local samples = CombatTextIconsCharDB.casts[8092].samples
        return #samples == 3 and samples[1].size == 20000 and samples[2].size == nil and samples[3].size == nil
    end)
    Scenario("samples: a saved entry with 20 samples loads as its last 16", function()
        local saved = {}
        for castAt = 1, 20 do saved[castAt] = { school = 32, delay = 0.2, castAt = castAt, hops = 1 } end
        T.Boot(function()
            CombatTextIconsCharDB = { casts = { [8092] = { learned = true, pattern = "single", school = 32, delays = { 0.2 },
                samples = saved } } }
        end)
        local samples = CombatTextIconsCharDB.casts[8092].samples
        return #samples == 16 and samples[1].castAt == 5 and samples[16].castAt == 20
    end)
    Scenario("InBand: by base and cast spell, the padded band of the spell's samples, else the whole entry's", function()
        local ns = Rig(function(n) LearnSized(n, 8092, 8092, { 20942, 20962, 21730 }) end)
        local InBand = ns.Casts.InBand
        return InBand(8092, 450983, 22090) and not InBand(8092, 8092, 3857) and InBand(8092, 8092, nil)
            and InBand(591, 591, 5)
    end)
    Scenario("Candidates: the non-tracker casts on the plate in the last 1.5 s, one per spell and time, learned ones too", function()
        local ns, S = Rig(function(n) LearnSized(n, 8092, 8092, { 20942, 20962, 21730 }) end, true)
        Cast(ns, S, 8092, 10.0, "nameplate1"); Cast(ns, S, 450983, 10.5, "nameplate1")
        Cast(ns, S, 32379, 10.6, "nameplate2"); Cast(ns, S, AGONY, 10.7, "nameplate1")
        Cast(ns, S, 450983, 10.9, "nameplate1"); Cast(ns, S, 450983, 10.9, "nameplate1")
        local list = ns.Casts.Candidates(Plate("nameplate1"), 11.0)
        local later = ns.Casts.Candidates(Plate("nameplate1"), 11.6)
        local function Is(c, castID, castAt, castSpell)
            return c and c.castID == castID and c.castAt == castAt and c.castSpell == castSpell
        end
        return #list == 3 and Is(list[1], 8092, 10.0, 8092) and Is(list[2], 8092, 10.5, 450983)
            and Is(list[3], 8092, 10.9, 450983) and #later == 2 and Is(later[1], 8092, 10.5, 450983)
            and #ns.Casts.Candidates(nil, 11.0) == 0
    end)

    -- Run 125009Z: Mind Blast learned at 18-25K, 0.17-0.23 s after the cast (padded band 12600-50000).
    local MindBlast = function(ns) LearnSized(ns, 8092, 8092, { 18000, 21000, 25000 }, { 0.17, 0.2, 0.23 }) end
    Scenario("band: a small DoT tick in Mind Blast's window is not claimed; the real hit in the same frame is", function()
        local ns, S = Rig(MindBlast)
        Cast(ns, S, 8092, 10, "nameplate1")
        local tick = ns.Casts.Claim(Plate("nameplate1"), 32, 10.224, 894)
        local kind, record = ns.Casts.Claim(Plate("nameplate1"), 32, 10.224, 19102)
        return tick == nil and kind == "learned" and record.spellID == 8092
    end)
    Scenario("band: a crit tick (5048, normal-scale 2524) is not claimed; the 18444 hit after it is", function()
        local ns, S = Rig(MindBlast)
        Cast(ns, S, 8092, 20, "nameplate1")
        local tick = ns.Casts.Claim(Plate("nameplate1"), 32, 20.146, 5048 / 2)
        local kind = ns.Casts.Claim(Plate("nameplate1"), 32, 20.177, 18444)
        return tick == nil and kind == "learned"
    end)
    Scenario("band: the top edge is twice the biggest size", function()
        local ns, S = Rig(MindBlast)
        Cast(ns, S, 8092, 60, "nameplate1")
        return ns.Casts.Claim(Plate("nameplate1"), 32, 60.2, 50001) == nil
            and ns.Casts.Claim(Plate("nameplate1"), 32, 60.2, 50000) == "learned"
    end)
    -- Run 20261025T180045Z: Shadow Bolt learned at 9923-12782; s32 hits of 6068-6518 (0.61-0.66 x) landed
    -- ~0.15 s before the bolt, took its record and left the bolt '?'.
    Scenario("band: the bottom edge is 0.7 x the smallest size", function()
        local ns, S = Rig(MindBlast)
        Cast(ns, S, 8092, 60, "nameplate1")
        return ns.Casts.Claim(Plate("nameplate1"), 32, 60.2, 12599) == nil
            and ns.Casts.Claim(Plate("nameplate1"), 32, 60.2, 12600) == "learned"
    end)
    Scenario("band: no size, a 0 size or no band claims on time alone", function()
        local ns, S = Rig(function(n) MindBlast(n); Wand(n) end)
        Cast(ns, S, 8092, 40, "nameplate1")
        local unsized = ns.Casts.Claim(Plate("nameplate1"), 32, 40.2, nil)
        Cast(ns, S, 8092, 50, "nameplate1")
        local zero = ns.Casts.Claim(Plate("nameplate1"), 32, 50.2, 0)
        Cast(ns, S, WAND, 70, "nameplate2")
        local wand = ns.Casts.Claim(Plate("nameplate2"), 4, 70.2, 5)
        return unsized == "learned" and zero == "learned" and wand == "learned"
    end)
    Scenario("band: a crit through Core is compared at normal scale (60000 crit -> 30000 fits)", function()
        local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
        local S = T.State()
        MindBlast(ns)
        local drawn
        ns.Display.Plate = function(_, texture) drawn = texture end
        S.now, S.target = 30, "nameplate1"
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c30", 8092)
        S.now = 30.2
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "CRITICAL", 60000, 32)
        return drawn == "tex:8092"
    end)
    -- lock3 fight 3: an open-world boss in a crowd; strangers' Shadow hits filled Shadow Bolt's padded band and its
    -- 4 casts drew 118730 against a row of 76384. A crowded fight claims only hits in the learned window and within
    -- SIZE_GUARD of the learned sizes (18000-25000: 15300-29411 here).
    Scenario("crowd: a crowded fight's cast draws only hits in the learned window and near the learned sizes", function()
        local function Hits(crowded, hits)
            local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
            local S = T.State()
            MindBlast(ns)
            ns.Teacher.Start(29)
            ns.Teacher.fight.crowded = crowded
            local drawn = {}
            ns.Display.Plate = function(_, texture) drawn[#drawn + 1] = texture end
            S.now, S.target = 30, "nameplate1"
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c30", 8092)
            for _, hit in ipairs(hits) do
                S.now = hit[1]
                ns.Core.UNIT_COMBAT("nameplate1", "WOUND", hit[3] or "", hit[2], 32)
            end
            return drawn[#drawn]
        end
        local MB = "tex:8092"
        return Hits(false, { { 30.2, 45000 } }) == MB and Hits(true, { { 30.2, 45000 } }) ~= MB
            and Hits(false, { { 30.2, 90000, "CRITICAL" } }) == MB and Hits(true, { { 30.2, 90000, "CRITICAL" } }) ~= MB
            and Hits(true, { { 30.2, 45000 }, { 30.21, 21000 } }) == MB
            and Hits(true, { { 30.2, 50000, "CRITICAL" } }) == MB
            and Hits(false, { { 30.4, 21000 } }) == MB and Hits(true, { { 30.4, 21000 } }) ~= MB
    end)
    -- shaman5 fight 5: Lava Burst 51505 learned on its target hit 4 other dummies 0.13-0.45 s after its target hit, at
    -- its learned sizes; hunter fight 18's pet left like-sized hits on other plates before a Kill Command's own hit too.
    Scenario("splash: after its own hit a cast claims like-sized hits on other plates, unless they landed there before",
        function()
            local function Last(hits)
                local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
                local S = T.State()
                MindBlast(ns)
                local drawn
                ns.Display.Plate = function(_, texture) drawn = texture end
                S.now, S.target = 30, "nameplate1"
                ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c30", 8092)
                for _, hit in ipairs(hits) do
                    S.now, drawn = hit[1], nil
                    ns.Core.UNIT_COMBAT(hit[3], "WOUND", "", hit[2], 32)
                end
                return drawn
            end
            local MB, own = "tex:8092", { 30.2, 21000, "nameplate1" }
            return Last({ own, { 30.4, 20000, "nameplate2" } }) == MB
                and Last({ { 30.4, 20000, "nameplate2" } }) ~= MB
                and Last({ own, { 30.2, 20000, "nameplate2" } }) ~= MB
                and Last({ own, { 30.4, 12000, "nameplate2" } }) ~= MB
                and Last({ { 30.05, 20000, "nameplate3" }, own, { 30.4, 20000, "nameplate2" } }) ~= MB
        end)
    -- shaman5 fight 1: Earthquake 462620 learned as ground (Ground.lua) ticks on every plate in its patch, first
    -- ~1.02 s after the cast, then every ~0.98 s; three 16.5K crits of another spell on one plate (200335.220, 8.2K
    -- halved) landed in a cast's first-tick window ahead of its real tick. Learned here: first tick 1.0 s, period 1.0,
    -- 6 ticks. Once a tick was seen, a crit near the sizes on the next one draws (synthetic Death and Decay: all 4
    -- plates crit in one frame).
    Scenario("ground: a ground cast draws its ticks on any plate, a period apart; a crit anchors no first tick",
        function()
            local function Last(hits)
                local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
                local S = T.State()
                for castAt = 1, 3 do
                    ns.Fingerprints.Add(462620, { school = 8, delay = 1, castAt = castAt, hops = 1, size = 6400,
                        tick = 0 })
                    ns.Fingerprints.Add(462620, { school = 8, delay = 6, castAt = castAt, hops = 1, size = 6600,
                        tick = 5 })
                end
                local drawn
                ns.Display.Plate = function(_, texture) drawn = texture end
                S.now, S.target = 30, nil
                ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c30", 462620)
                for _, hit in ipairs(hits) do
                    S.now, drawn = hit[1], nil
                    ns.Core.UNIT_COMBAT(hit[3], "WOUND", hit[4] or "", hit[2], 8)
                end
                return drawn
            end
            local EQ, first = "tex:462620", { 31, 6500, "nameplate2" }
            local ticks = { first }
            for k = 1, 6 do ticks[#ticks + 1] = { 31 + k, 6500, "nameplate" .. (2 + k % 3) } end
            return Last({ first }) == EQ
                and Last({ { 31, 13000, "nameplate2", "CRITICAL" } }) ~= EQ
                and Last({ first, { 31, 19500, "nameplate3", "CRITICAL" } }) == EQ
                and Last({ first, { 32, 6500, "nameplate3" } }) == EQ
                and Last({ first, { 32, 13000, "nameplate3", "CRITICAL" } }) == EQ
                and Last({ first, { 31.5, 13000, "nameplate3", "CRITICAL" } }) ~= EQ
                and Last({ first, { 32, 39000, "nameplate3", "CRITICAL" } }) ~= EQ
                and Last({ first, { 31.5, 6500, "nameplate3" } }) ~= EQ
                and Last({ first, { 33, 6500, "nameplate3" } }) == EQ
                and Last({ first, { 34, 6500, "nameplate3" } }) ~= EQ
                and Last({ table.unpack(ticks, 1, 6) }) == EQ and Last(ticks) ~= EQ
        end)

    -- Run 134732Z: Mind Blast cast at nameplate4, the target moved on to the next mob before the cast
    -- finished, the killing hit landed on nameplate4 -> '?'. The cast's plate is the target at its start.
    local function Retarget(startGUID, castGUID)
        local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
        local S = T.State()
        MindBlast(ns)
        local drawn
        ns.Display.Plate = function(_, texture) drawn = texture end
        S.now, S.target = 30, "nameplate4"
        ns.Core.UNIT_SPELLCAST_START("player", startGUID, 8092)
        S.now, S.target = 31.5, "nameplate6"
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", castGUID, 8092)
        S.now = 31.67
        ns.Core.UNIT_COMBAT("nameplate4", "WOUND", "", 20592, 32)
        return drawn
    end
    Scenario("cast start: a hit on the plate targeted when the cast started is claimed after a retarget mid-cast",
        function() return Retarget("g1", "g1") == "tex:8092" end)
    Scenario("cast start: a start of another cast (interrupted, then cast again) does not name the plate",
        function() return Retarget("g1", "g2") ~= "tex:8092" end)
    Scenario("cast start: a secret cast GUID falls back to the spell ID", function()
        return Retarget(T.Secret("g1"), T.Secret("g1")) == "tex:8092"
    end)

    Scenario("claim: a hit inside a learned cast's window, on its plate, is 'learned' with that record", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        local kind, record = ns.Casts.Claim(Plate("nameplate1"), 4, 10.17)
        local kind2 = ns.Casts.Claim(Plate("nameplate1"), 4, 10.23)
        return kind == "learned" and record.spellID == WAND and record.hops == 0 and kind2 == "learned"
    end)
    Scenario("claim: an override cast (Void Blast) opens a record under its base's learned fingerprint (Mind Blast)", function()
        local ns, S = Rig(function(n) Learn3(n, 8092, 32, 0.2) end)
        Cast(ns, S, 450983, 10, "nameplate1")
        local kind, record = ns.Casts.Claim(Plate("nameplate1"), 32, 10.2)
        return kind == "learned" and record.spellID == 450983 and record.base == 8092
    end)
    Scenario("claim: wrong school, wrong plate, too early or past twice the window top (0.45 s) is nil", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        local p1, p2 = Plate("nameplate1"), Plate("nameplate2")
        return ns.Casts.Claim(p1, 32, 10.2) == nil and ns.Casts.Claim(p2, 4, 10.2) == nil
            and ns.Casts.Claim(p1, 4, 10.12) == nil and ns.Casts.Claim(p1, 4, 10.46) == nil
    end)
    -- Shadow Bolt 686 learned at 1.104-1.155 s; the next fight it lands at ~0.98-1.0 s (run 20261025T180045Z).
    local SB = 686
    local function LearnBolt(n) LearnSized(n, SB, SB, { 10064, 12503, 10126 }, { 1.104, 1.13, 1.155 }) end
    -- Under the window, only a size inside the learned 10064-12503 is drawn (early); 9000 is in the padded band only.
    local UNDER = 9000
    Scenario("early: a first hit up to WATCH under the window, sized inside the learned sizes, is drawn (LB 0.37-0.44 s of 0.50-0.60 s)", function()
        local function Under(delay, size)
            local ns, S = Rig(LearnBolt)
            Cast(ns, S, SB, 100, "nameplate1")
            return ns.Casts.Claim(Plate("nameplate1"), 32, 100 + delay, size)
        end
        return Under(0.98, 10321) == "learned" and Under(0.85, 10321) == nil and Under(0.98, UNDER) == nil
    end)
    -- 0.85 s is under the early range of the learned window, inside it once the centre moves to ~1.0 s.
    local PROBE = 0.85
    Scenario("centre: one hit seen under the window moves the next cast's window to it (1.0 s of 1.10-1.16 s)", function()
        local ns, S = Rig(LearnBolt)
        local p1 = Plate("nameplate1")
        Cast(ns, S, SB, 100, "nameplate1")
        local under = ns.Casts.Claim(p1, 32, 100.98, UNDER)
        Cast(ns, S, SB, 101.5, "nameplate1")
        local kind, record = ns.Casts.Claim(p1, 32, 101.5 + PROBE, 10273)
        return under == nil and kind == "learned" and record.at == 101.5
    end)
    Scenario("centre: two hits seen in the watch range move nothing", function()
        local ns, S = Rig(LearnBolt)
        local p1 = Plate("nameplate1")
        Cast(ns, S, SB, 100, "nameplate1")
        ns.Casts.Claim(p1, 32, 100.95, UNDER)
        ns.Casts.Claim(p1, 32, 101.0, UNDER + 200)
        Cast(ns, S, SB, 101.5, "nameplate1")
        return ns.Casts.Claim(p1, 32, 101.5 + PROBE, 10273) == nil
    end)
    Scenario("centre: a centre older than CENTRE_AGE (10 s, cast to cast) or from an ended fight is ignored", function()
        local ns, S = Rig(LearnBolt)
        local p1 = Plate("nameplate1")
        Cast(ns, S, SB, 100, "nameplate1")
        ns.Casts.Claim(p1, 32, 100.98, UNDER)
        Cast(ns, S, SB, 111, "nameplate1")
        local stale = ns.Casts.Claim(p1, 32, 111 + PROBE, 10273)
        Cast(ns, S, SB, 120, "nameplate1")
        ns.Casts.Claim(p1, 32, 120.98, UNDER)
        ns.Casts.Flush(121.5)
        Cast(ns, S, SB, 122, "nameplate1")
        return stale == nil and ns.Casts.Claim(p1, 32, 122 + PROBE, 10273) == nil
    end)
    Scenario("late: a record that saw a hit near its window takes no late hit (Darkglare's beam after a spoiled bolt)", function()
        local ns, S = Rig(LearnBolt)
        local p1 = Plate("nameplate1")
        Cast(ns, S, SB, 200, "nameplate1")
        ns.Casts.Claim(p1, 32, 200.98, UNDER)
        return ns.Casts.Claim(p1, 32, 202.0, 7821) == nil
    end)
    Scenario("late: a record that saw nothing near its window still takes a late hit", function()
        local ns, S = Rig(LearnBolt)
        Cast(ns, S, SB, 200, "nameplate1")
        return ns.Casts.Claim(Plate("nameplate1"), 32, 201.6, 10321) == "learned"
    end)
    Scenario("claim: no side effects (record, plates and a second answer unchanged)", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        local p1 = Plate("nameplate1")
        local _, first = ns.Casts.Claim(p1, 4, 10.2)
        local kind, second = ns.Casts.Claim(p1, 4, 10.2)
        return kind == "learned" and second == first and first.hops == 0 and next(first.plates) == nil and first.last == 10
    end)
    Scenario("claim: an unlearned non-tracker cast on the plate makes it 'ambiguous'; other plate, age > 1.5 s or a tracker cast do not", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        Cast(ns, S, UNLEARNED, 10.05, "nameplate1")
        local ambiguous = ns.Casts.Claim(Plate("nameplate1"), 4, 10.2) == "ambiguous"
        local function Kind(setup) -- fresh rig: WAND at 10 plus the extra cast
            local n, s = Rig(Wand, true)
            setup(n, s)
            Cast(n, s, WAND, 10, "nameplate1")
            return (n.Casts.Claim(Plate("nameplate1"), 4, 10.2))
        end
        return ambiguous
            and Kind(function(n, s) Cast(n, s, UNLEARNED, 9.9, "nameplate2") end) == "learned"
            and Kind(function(n, s) Cast(n, s, UNLEARNED, 8.0, "nameplate1") end) == "learned"
            and Kind(function(n, s) Cast(n, s, AGONY, 9.9, "nameplate1") end) == "learned"
    end)
    -- Run 20261025T172757Z: Void Eruption 0.23 s and SW:Death 1 s before a Void Blast, and SW:Death in the
    -- Void Blast's own frame, turned 4 Mind Blast / Void Blast hits into '?'.
    Scenario("claim: an unlearned cast before the learned one, or in its frame, does not spoil the claim", function()
        local ns, S = Rig(MindBlast)
        Cast(ns, S, UNLEARNED, 9.9, "nameplate1")
        Cast(ns, S, 8092, 10, "nameplate1")
        local before = ns.Casts.Claim(Plate("nameplate1"), 32, 10.2, 20000)
        Cast(ns, S, 8092, 20, "nameplate1")
        Cast(ns, S, UNLEARNED, 20, "nameplate1")
        local frame = ns.Casts.Claim(Plate("nameplate1"), 32, 20.2, 20000)
        return before == "learned" and frame == "learned"
    end)
    -- Run shaman4 fight 2: Totemic Projection 108287 (no meter row) 0.26 s after a Lava Burst turned its 113K hit into '?'.
    -- Mind Blast learned at 0.2 s with sizes 18000-25000; OTHER is cast 0.05 s after it.
    local OTHER, OTHER_BASE = 1234567, 7654321
    local function AfterOther(setup, at, size)
        local ns, S = Rig(function(n) LearnSized(n, 8092, 8092, { 18000, 21000, 25000 }) end)
        if setup then setup(ns, S) end
        Cast(ns, S, 8092, 10, "nameplate1")
        Cast(ns, S, OTHER, 10.05, "nameplate1")
        return (ns.Casts.Claim(Plate("nameplate1"), 32, at or 10.2, size or 20000))
    end
    local function Rowless(ns) -- a read found OTHER cast with no row (Learn.RowsRead)
        ns.Learn.OnCast(OTHER, 1)
        ns.Learn.RowsRead({ { spellID = 8092 } }, 0)
    end
    Scenario("claim: a cast after the learned one that a read showed rowless spoils no hit inside the learned window and sizes", function()
        return AfterOther(Rowless) == "learned" and AfterOther() == "ambiguous"
    end)
    Scenario("claim: a rowless cast still spoils a hit in the padded sizes only, a late hit, or when its base is an own row", function()
        local function OwnBase(ns, S)
            S.baseSpells[OTHER] = OTHER_BASE
            Rowless(ns)
            ns.Casts.NoteRows({ { spellID = OTHER_BASE } })
        end
        return AfterOther(Rowless, 10.2, 14000) == "ambiguous" and AfterOther(Rowless, 10.32) == "ambiguous"
            and AfterOther(OwnBase) == "ambiguous"
    end)
    Scenario("claim: a cast whose row is a learned proc of another school spoils no sure hit; of the hit's school it does", function()
        local function WithProc(school)
            return AfterOther(function(n)
                CombatTextIconsCharDB.procs = { [OTHER] = { school = school, lo = 3000, hi = 6000, learned = true } }
                n.Procs.Init(CombatTextIconsCharDB)
            end)
        end
        return WithProc(12) == "learned" and WithProc(32) == "ambiguous"
    end)
    Scenario("claim: two learned records that both fit are 'ambiguous' with no record", function()
        local ns, S = Rig(function(n) Wand(n) Learn3(n, 585, 4, 0.2) end)
        Cast(ns, S, WAND, 10, "nameplate1")
        Cast(ns, S, 585, 10.01, "nameplate1")
        local kind, record = ns.Casts.Claim(Plate("nameplate1"), 4, 10.21)
        return kind == "ambiguous" and record == nil
    end)
    Scenario("accept: a chain record takes hops on new plates within CHAIN_GAP and stops at CHAIN_MAX or a repeated plate", function()
        local ns, S = Rig(function(n) Learn3(n, CL, 8, 0.2, 3) end)
        Cast(ns, S, CL, 20, "nameplate1")
        local P = function(i) return Plate("nameplate" .. i) end
        local _, record = ns.Casts.Claim(P(1), 8, 20.2)
        ns.Casts.Accept(record, P(1), 20.2)
        local second = ns.Casts.Claim(P(2), 8, 20.3)
        local repeated = ns.Casts.Claim(P(1), 8, 20.3)
        local tooLate = ns.Casts.Claim(P(2), 8, 20.5)
        for hop = 2, 5 do ns.Casts.Accept(record, P(hop), 20.2 + 0.05 * (hop - 1)) end
        return record.hops == 5 and record.last == 20.2 + 0.05 * 4 and second == "learned" and repeated == nil
            and tooLate == nil and ns.Casts.Claim(P(6), 8, 20.41) == nil
    end)
    Scenario("accept: a single-pattern record takes no second hit", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        local _, record = ns.Casts.Claim(Plate("nameplate1"), 4, 10.2)
        ns.Casts.Accept(record, Plate("nameplate1"), 10.2)
        return record.hops == 1 and ns.Casts.Claim(Plate("nameplate2"), 4, 10.22) == nil
    end)
    Scenario("records: at most 20 open, the oldest dropped", function()
        local ns, S = Rig(Wand)
        for i = 1, 21 do Cast(ns, S, WAND, 30 + i * 0.001, "nameplate" .. i) end
        local oldest = ns.Casts.Claim(Plate("nameplate1"), 4, 30.2)
        local second = ns.Casts.Claim(Plate("nameplate2"), 4, 30.2)
        local newest = ns.Casts.Claim(Plate("nameplate21"), 4, 30.2)
        return oldest == nil and second == "learned" and newest == "learned"
    end)
    Scenario("claim: a secret school answers nil without error and leaves the record unchanged", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        local ok, kind = pcall(ns.Casts.Claim, Plate("nameplate1"), T.Secret(4), 10.2)
        local _, record = ns.Casts.Claim(Plate("nameplate1"), 4, 10.2)
        return ok and kind == nil and record.hops == 0 and next(record.plates) == nil
    end)
end

do -- Phase 3: Core hit route
    local WAND = 5019
    local function Scenario(name, fn) local ok, result = pcall(fn); T.Check(name, ok and result == true) end
    local function Rig()
        local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
        local S = T.State()
        local rig = { ns = ns, S = S }
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(_, texture) rig.last = texture end
        ns.Display.Player = function() end
        for index = 1, 3 do ns.Fingerprints.Add(WAND, { school = 4, delay = 0.2, castAt = index, hops = 1 }) end
        function rig.Cast(t, id, unit) S.now, S.target = t, unit or "nameplate1"; ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", id or WAND) end
        function rig.Hit(t, unit, school)
            S.now, rig.last = t, nil
            ns.Core.UNIT_COMBAT(unit or "nameplate1", "WOUND", "", 90, school or 4)
            return rig.last
        end
        return rig
    end
    Scenario("core meter off: a learned cast's hit draws the cast spell's icon once, then '?' for a second hit", function()
        local r = Rig()
        r.Cast(10)
        local first = r.Hit(10.2)
        return first == "tex:" .. WAND and r.Hit(10.22) == r.ns.Meter.UNKNOWN_ICON
    end)
    Scenario("core meter off: in a group a learned match draws the cast spell's icon and takes the record (spec C1)", function()
        local r = Rig()
        r.Cast(10)
        r.S.group = true
        local drawn = r.Hit(10.2)
        r.S.group = false
        return drawn == "tex:" .. WAND and r.Hit(10.22) == r.ns.Meter.UNKNOWN_ICON
    end)
    Scenario("core meter off: a mob that does not fight you stays hidden", function()
        local r = Rig()
        r.Cast(10)
        r.S.threat["nameplate1"] = false
        r.S.target = nil -- a targeted mob without a threat list counts as yours (training dummy)
        return r.Hit(10.2) == nil
    end)
    Scenario("core meter off: an unlearned cast on the plate makes the hit '?' (solo)", function()
        local r = Rig()
        r.Cast(10)
        r.Cast(10.05, 589)
        return r.Hit(10.2) == r.ns.Meter.UNKNOWN_ICON
    end)
    Scenario("core meter off: a school the fingerprint does not have draws '?' (solo)", function()
        local r = Rig()
        r.Cast(10)
        return r.Hit(10.2, "nameplate1", 32) == r.ns.Meter.UNKNOWN_ICON
    end)
    Scenario("core meter off: no ResetAllCombatSessions from login, casts and hits", function()
        local r = Rig()
        r.Cast(10) r.Hit(10.2) r.Hit(10.3, "nameplate2", 32)
        return r.S.resets == 0
    end)
end

    do -- one base, two casts (run 115649Z): Void Blast 450983 lands in the cast frame, Mind Blast 8092 ~0.17 s later
        local MIND_BLAST, VOID_BLAST = 8092, 450983
        local rig = Rig()
        local ns, F = rig.ns, rig.ns.Fingerprints
        rig.S.baseSpells[VOID_BLAST] = MIND_BLAST
        for castAt = 1, 3 do F.Add(MIND_BLAST, { school = 32, delay = 0, castAt = castAt, hops = 1, spell = VOID_BLAST }) end
        for castAt = 4, 6 do F.Add(MIND_BLAST, { school = 32, delay = 0.17, castAt = castAt, hops = 1, spell = MIND_BLAST }) end
        local voidLo, voidHi = F.Window(MIND_BLAST, VOID_BLAST)
        local mindLo, mindHi = F.Window(MIND_BLAST, MIND_BLAST)
        local otherLo, otherHi = F.Window(MIND_BLAST, 99999)
        Check("fingerprints: each cast of one base has its own window (Void Blast 0-0, Mind Blast 0.17-0.17)",
            voidLo == 0 and voidHi == 0 and mindLo == 0.17 and mindHi == 0.17)
        Check("fingerprints: a cast with no samples of its own gets the base's whole window (0-0.17)",
            otherLo == 0 and otherHi == 0.17)
        rig.Cast(100, MIND_BLAST, "nameplate1")
        local tick = rig.Hit(100, "nameplate1", "WOUND", 2914, 32)
        local blast = rig.Hit(100.17, "nameplate1", "WOUND", 18729, 32)
        Check("casts: a Mind Blast cast leaves a DoT tick in its cast frame and takes the hit 0.17 s later",
            not (tick and tick.texture == "tex:" .. MIND_BLAST) and blast and blast.texture == "tex:" .. MIND_BLAST)
        rig.S.now, rig.S.target = 200, "nameplate1" -- Void Blast fires twice in one frame (run 121944Z)
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-a", VOID_BLAST)
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-b", VOID_BLAST)
        local first = rig.Hit(200, "nameplate1", "WOUND", 24696, 32)
        local second = rig.Hit(200, "nameplate1", "WOUND", 24031, 32)
        Check("casts: two open casts of one spell that both fit are not ambiguous: each takes one hit",
            first and first.texture == "tex:" .. VOID_BLAST and second and second.texture == "tex:" .. VOID_BLAST)
        -- Mind Blast travel varies (0.17-0.34 s across runs 115649Z-123754Z): window 0.17 s, late up to 2 x 0.17 + 0.05
        rig.Cast(300, MIND_BLAST, "nameplate1")
        local late = rig.Hit(300.29, "nameplate1", "WOUND", 21009, 32)
        rig.Cast(311, MIND_BLAST, "nameplate1") -- 11 s after the 300 cast: its centre (0.29 s) is stale
        local tooLate = rig.Hit(311.5, "nameplate1", "WOUND", 21009, 32)
        rig.Cast(320, MIND_BLAST, "nameplate1")
        local inWindow = rig.Hit(320.17, "nameplate1", "WOUND", 19000, 32)
        local after = rig.Hit(320.3, "nameplate1", "WOUND", 2000, 32)
        Check("casts: a cast with no hit yet takes a late hit up to twice its window top (0.29 s of 0.17)",
            late and late.texture == "tex:" .. MIND_BLAST)
        Check("casts: past twice the window top (0.5 s) it takes nothing",
            not (tooLate and tooLate.texture == "tex:" .. MIND_BLAST))
        Check("casts: a cast that took its hit in the window takes no late hit",
            inWindow and inWindow.texture == "tex:" .. MIND_BLAST and not (after and after.texture == "tex:" .. MIND_BLAST))
        F.Init({ casts = { [1] = { learned = true, pattern = "single", school = 32, delays = { 0.2 },
            samples = { { school = 32, delay = 0.2, castAt = 1, hops = 1, spell = VOID_BLAST } } } } })
        Check("fingerprints: a saved sample keeps its cast spell", select(2, F.Window(1, VOID_BLAST)) == 0.2
            and F.Get(1).samples[1].spell == VOID_BLAST)
    end

    do -- a learned stack spell (Stack.lua): Unstable Affliction 1259790 ticks every ~1.33 s, live stacks x one stack
        local UA, HAUNT = 1259790, 48181
        local function StackRig(setup)
            local rig = Rig()
            for castAt = 1, 3 do
                rig.ns.Fingerprints.Add(UA, { school = 32, delay = 1.3, castAt = castAt, hops = 1, tick = 0, period = 1.33,
                    life = 8 })
            end
            if setup then setup(rig) end
            return rig
        end
        local function Drew(hit, id) return hit ~= nil and hit.texture == "tex:" .. id end
        -- lock3 fight 4: one stack's ticks then two stacks' (10925 crit, 21851 crit), the same unit at a new count
        local function Steps(setup, first, second)
            local rig = StackRig(setup)
            rig.Cast(100, UA, "nameplate1")
            local seed = rig.Hit(101.33, "nameplate1", "WOUND", first, 32)
            rig.Cast(102, UA, "nameplate1")
            local step = rig.Hit(102.66, "nameplate1", "WOUND", second, 32)
            local after = rig.Hit(103.99, "nameplate1", "WOUND", second, 32)
            return Drew(seed, UA), Drew(step, UA), Drew(after, UA)
        end
        local seed, step, after = Steps(nil, 3258, 6517)
        Check("stack: a hit in a cast's window starts no series; one a period on at another stack count and the same "
            .. "unit does, and the next tick extends it", not seed and step and after)
        local _, stranger = Steps(nil, 1655, 3607)
        Check("stack: a stranger's 1655 then Agony's 3607 at one stack more (9 % off a stack's size) start no series "
            .. "(lock2)", stranger == false)
        local _, grouped = Steps(function(r) r.S.group = true end, 3258, 6517)
        Check("stack: in a group the stack spell's step still draws (lock3 fight 4)", grouped)
        local _, crowded = Steps(function(r)
            r.ns.Teacher.Start(99)
            r.ns.Teacher.fight.crowded = true
        end, 3258, 6517)
        Check("stack: in a crowded fight no stack tick draws (lock3 fight 3)", crowded == false)
        -- lock2 fight 5: Haunt cast, Unstable Affliction cast 0.25 s later, then 1278047's 43366 in Haunt's window
        local spoil = StackRig(function(r)
            for castAt = 1, 3 do
                r.ns.Fingerprints.Add(HAUNT, { school = 32, delay = 0.55, castAt = castAt, hops = 1, size = 24000 })
            end
        end)
        spoil.Cast(200, HAUNT, "nameplate1")
        spoil.Cast(200.25, UA, "nameplate1")
        local proc = spoil.Hit(200.55, "nameplate1", "WOUND", 43366, 32)
        Check("stack: a learned stack spell's cast still spoils another cast's claim, as an unlearned one did",
            proc ~= nil and proc.texture == spoil.ns.Meter.UNKNOWN_ICON)
    end
end
