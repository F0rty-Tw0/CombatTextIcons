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

        -- delay ring of 8 and samples of 8: new delays widen at once, old ones age out
        for index = 1, 8 do F.Add(593, Sample(2, 0.2, index)) end
        F.Add(593, Sample(2, 0.5, 9))
        Check("fingerprints: a slower delay widens the range at once",
            F.Get(593).delayHi == 0.5 and F.Get(593).delayLo == 0.2 and #F.Get(593).delays == 8)
        for index = 10, 17 do F.Add(593, Sample(2, 0.2, index)) end
        Check("fingerprints: after 8 more samples the slow delay has aged out",
            F.Get(593).delayHi == 0.2 and #F.Get(593).delays == 8 and #F.Get(593).samples == 8)

        -- pattern: chain while a sample with hops >= 2 is among the last 8
        for index = 1, 3 do F.Add(594, Sample(2, 0.2, index)) end
        Check("fingerprints: single hops -> pattern single", F.Get(594).pattern == "single")
        F.Add(594, Sample(2, 0.2, 4, 3))
        Check("fingerprints: a sample with 3 hops -> pattern chain", F.Get(594).pattern == "chain")
        for index = 5, 12 do F.Add(594, Sample(2, 0.2, index)) end
        Check("fingerprints: the chain sample aged out of the 8 -> pattern single again", F.Get(594).pattern == "single")

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
    Scenario("claim: wrong school, wrong plate, too early or too late is nil", function()
        local ns, S = Rig(Wand)
        Cast(ns, S, WAND, 10, "nameplate1")
        local p1, p2 = Plate("nameplate1"), Plate("nameplate2")
        return ns.Casts.Claim(p1, 32, 10.2) == nil and ns.Casts.Claim(p2, 4, 10.2) == nil
            and ns.Casts.Claim(p1, 4, 10.12) == nil and ns.Casts.Claim(p1, 4, 10.28) == nil
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
        F.Init({ casts = { [1] = { learned = true, pattern = "single", school = 32, delays = { 0.2 },
            samples = { { school = 32, delay = 0.2, castAt = 1, hops = 1, spell = VOID_BLAST } } } } })
        Check("fingerprints: a saved sample keeps its cast spell", select(2, F.Window(1, VOID_BLAST)) == 0.2
            and F.Get(1).samples[1].spell == VOID_BLAST)
    end
end
