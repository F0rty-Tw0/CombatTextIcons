-- Unit checks for learned spells: the Forever gate, the Learn store, the feed
-- into streams, the cast log, learned DoT / channel / HoT instances and the heal path. Called by
-- tests/checks.lua with the same T table (see its header).

return function(T)
    local Check, Secret = T.Check, T.Secret

    -- Writes a learned entry straight into the saved table (Learn.Get serves it like a table row).
    local function SeedLearned(id, school, period, kind)
        CombatTextIconsCharDB.learned[id] = { school = school, period = period, kind = kind, misses = 0 }
    end

    -- Forever gate and harness stubs ------------------------------------------------------
    do
        for interface, expected in pairs({ [120105] = false, [15999] = false, [16000] = true, [16001] = true,
            [19999] = true, [20000] = false }) do
            local ns = T.Boot(function(S) S.interface = interface end)
            Check("forever: ns.IsForever for interface " .. interface, ns.IsForever == expected)
        end
        local ns = T.Boot(function(S) S.interface = 16001 end)
        Check("forever: ns.Spells is empty", next(ns.Spells) == nil)
        -- the Forever gate (Learn.lua) also drops rows a table would bring
        ns = T.BootSpells(function(S) S.interface = 16001 end)
        local S = T.State()
        local shown
        ns.Display.Plate = function(_, texture) shown = texture end
        S.target, S.now, S.group = "nameplate1", 0, true -- in a group an unidentified hit stays hidden
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-1", 172)
        S.now, S.pending, S.pendingTag = 2, {}, "t"
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 1000, 32)
        Check("forever: fixture rows dropped, cast 172 is not a retail Corruption instance", next(ns.Spells) == nil and shown == nil)

        ns = T.Boot()
        S = T.State()
        shown = nil
        ns.Display.Plate = function(_, texture) shown = texture end
        S.target, S.now = "nameplate1", 0
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-1", 172)
        S.now, S.pending, S.pendingTag = 2, {}, "t"
        ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 1000, 32)
        Check("retail: the shipped ns.Spells is empty, and cast 172 draws no Corruption tick",
            next(ns.Spells) == nil and shown ~= "tex:146739")

        S.helpful[5], S.autoRepeat[6] = true, true
        Check("harness: helpful / auto-repeat stubs", C_Spell.IsSpellHelpful(5) == true and C_Spell.IsSpellHelpful(7) == false
            and C_Spell.IsAutoRepeatSpell(6) == true and select(4, GetBuildInfo()) == 120105)
        CombatTextIconsCharDB = { learned = { [1] = { school = 32, period = 3, kind = "dot" } } }
        T.Boot()
        Check("harness: Boot resets CombatTextIconsCharDB", next(CombatTextIconsCharDB.learned) == nil)
    end

    -- Learn store ----------------------------------------------------------------------------
    do
        local files, index = T.TocFiles(), {}
        for position, file in ipairs(files) do index[file] = position end
        Check("toc: Learn.lua loads after Spells.lua and before Tracker.lua",
            index["Learn.lua"] and index["Learn.lua"] > index["Spells.lua"] and index["Learn.lua"] < index["Tracker.lua"])
        local handle = assert(io.open(T.Root .. "/CombatTextIcons.toc", "rb"))
        local toc = handle:read("a")
        handle:close()
        Check("toc: Interface 120105, 16001", toc:find("## Interface: 120105, 16001", 1, true) ~= nil)
        Check("toc: per-character saved variable",
            toc:find("## SavedVariablesPerCharacter: CombatTextIconsCharDB", 1, true) ~= nil)

        local ns = T.BootSpells()
        local Learn, db = ns.Learn, CombatTextIconsCharDB
        Check("learn: Init creates learned and votes and no pending", type(db.learned) == "table" and type(db.votes) == "table" and db.pending == nil)
        SeedLearned(589, 32, 3.0, "dot")
        local entry = Learn.Get(589)
        Check("learn: Get serves a learned entry", entry and entry.icon == 589 and entry.school == 32 and entry.period == 3.0
            and entry.mode == "target" and entry.duration == nil)
        SeedLearned(4, 32, 1.0, "channel"); SeedLearned(5, 8, 3.0, "hot")
        Check("learn: channel and hot map to their modes", Learn.Get(4).mode == "channel" and Learn.Get(5).mode == "hot")

        db.votes[589] = { casts = 2, sigs = { { kind = "dot", school = 32, period = 3, votes = 1, expected = 0.1 } } }
        Learn.Missed(589)
        Check("learn: one miss keeps the spell", Learn.Get(589) ~= nil)
        Learn.Hit(589)
        Learn.Missed(589)
        Check("learn: a hit resets the miss count", Learn.Get(589) ~= nil)
        Learn.Missed(589)
        Check("learn: two consecutive misses clear learned and votes", Learn.Get(589) == nil and Learn.Votes(589) == nil)
        Learn.Missed(999)
        Learn.Hit(999)
        Check("learn: Missed/Hit on an unknown id do nothing", Learn.Get(999) == nil)

        local list = Learn.List()
        Check("learn: List is sorted learned entries", #list == 2 and list[1].spellID == 4 and list[2].spellID == 5
            and list[2].school == 8 and list[2].period == 3.0 and list[2].kind == "hot")

        Check("learn: IsKnownIcon sees table keys, icons and spread icons",
            Learn.IsKnownIcon(172) and Learn.IsKnownIcon(146739) and Learn.IsKnownIcon(1253171) and not Learn.IsKnownIcon(31))
        Check("learn: IsKnownIcon sees learned keys", Learn.IsKnownIcon(4))
        Check("learn: secret ids are ignored, not errors", Learn.IsKnownIcon(Secret(4)) == false and Learn.Get(Secret(4)) == nil)

        db.votes[4] = { casts = 1, sigs = {} }
        local learnedRef, votesRef = db.learned, db.votes
        Learn.Forget()
        Check("learn: Forget clears learned and votes in place", Learn.Get(4) == nil and next(db.learned) == nil
            and next(db.votes) == nil and db.learned == learnedRef and db.votes == votesRef)

        -- saved data is validated on load, never trusted
        ns = T.Boot(function()
            CombatTextIconsCharDB = {
                learned = {
                    [100] = { school = 32, period = 3, kind = "dot" },
                    [101] = { school = 0, period = 3, kind = "dot" },
                    [102] = { school = 32.5, period = 3, kind = "dot" },
                    [103] = { school = 32, period = 0.4, kind = "dot" },
                    [104] = { school = 32, period = 10.5, kind = "dot" },
                    [105] = { school = 32, period = 3, kind = "aura" },
                    [106] = "junk",
                    [107] = { school = 32, period = 3, kind = "channel", misses = 5 },
                    x = { school = 32, period = 3, kind = "dot" },
                },
                pending = { [200] = { school = 32, period = 3, kind = "hot" }, [201] = { school = 32, period = 99, kind = "hot" } },
            }
        end)
        Learn = ns.Learn
        Learn.Init()
        local kept = {}
        for _, row in ipairs(Learn.List()) do kept[#kept + 1] = row.spellID end
        Check("saved data: invalid learned entries dropped", table.concat(kept, ",") == "100,107")
        Check("saved data: the old pending table is deleted", CombatTextIconsCharDB.pending == nil)
        Learn.Missed(107)
        Check("saved data: misses restart at 0 on load", Learn.Get(107) ~= nil)
        ns = T.Boot(function() CombatTextIconsCharDB = { learned = 5 } end)
        ns.Learn.Init()
        Check("saved data: a non-table learned is replaced",
            type(CombatTextIconsCharDB.learned) == "table" and type(CombatTextIconsCharDB.votes) == "table")
        ns = T.Boot(function() CombatTextIconsCharDB = "junk" end)
        ns.Learn.Init()
        Check("saved data: a non-table db is replaced", type(CombatTextIconsCharDB) == "table")
    end

    -- Learn.Drop / Unpaired / Paired (spec 3.3) -----------------------------------------------
    do
        local ns = T.BootSpells()
        local Learn, db = ns.Learn, CombatTextIconsCharDB
        SeedLearned(589, 32, 3.0, "dot")
        db.votes[589] = { casts = 2, sigs = { { kind = "dot", school = 32, period = 3, votes = 1, expected = 0.1 } } }
        Learn.Drop(589)
        Check("learn: Drop clears learned and votes at once", Learn.Get(589) == nil and Learn.Votes(589) == nil)
        Check("learn: Drop, Unpaired and Paired on an unknown or secret id do nothing and raise no error",
            pcall(function()
                Learn.Drop(999); Learn.Drop(Secret(589)); Learn.Drop(nil)
                Learn.Unpaired(999); Learn.Unpaired(Secret(589)); Learn.Paired(999); Learn.Paired(Secret(589))
            end))

        SeedLearned(589, 32, 3.0, "dot") -- no `unpaired` field, like a fresh entry from OnBirth
        db.votes[589] = { casts = 2, sigs = {} }
        Learn.Unpaired(589)
        Check("learn: one Unpaired keeps a fresh entry (nil counts as 0)", Learn.Get(589) ~= nil)
        Learn.Unpaired(589)
        Check("learn: the second Unpaired drops the spell and its votes", Learn.Get(589) == nil and Learn.Votes(589) == nil)

        SeedLearned(589, 32, 3.0, "dot")
        Learn.Unpaired(589); Learn.Paired(589); Learn.Unpaired(589)
        Check("learn: Paired resets the strikes (strike, pair, strike keeps the spell)", Learn.Get(589) ~= nil)
        Learn.Unpaired(589)
        Check("learn: two strikes in a row after the reset drop it", Learn.Get(589) == nil)

        -- saved data: a valid count survives a load, a missing or invalid one restarts at 0
        ns = T.Boot(function()
            CombatTextIconsCharDB = { learned = {
                [100] = { school = 32, period = 3, kind = "dot", unpaired = 1 },
                [101] = { school = 32, period = 3, kind = "dot", unpaired = -3 },
                [102] = { school = 32, period = 3, kind = "dot", unpaired = "x" },
                [103] = { school = 32, period = 3, kind = "dot", unpaired = 1.5 },
            } }
        end)
        Learn = ns.Learn
        Learn.Init()
        for id = 100, 103 do Learn.Unpaired(id) end
        Check("saved data: unpaired = 1 survives the load (one more strike drops it)", Learn.Get(100) == nil)
        Check("saved data: unpaired -3, 'x' and 1.5 restart at 0 (one strike keeps them)",
            Learn.Get(101) ~= nil and Learn.Get(102) ~= nil and Learn.Get(103) ~= nil)
    end

    -- Learned table wiring and slash commands ----------------------------------------------
    do
        local ns = T.Boot(function(S)
            S.spellNames = { [589] = "Shadow Word: Pain" }
            CombatTextIconsCharDB = { learned = {
                [589] = { school = 32, period = 3, kind = "dot" },
                [17] = { school = 0, period = 3, kind = "dot" },
            } }
        end)
        local S = T.State()
        local Learn, db = ns.Learn, CombatTextIconsDB
        Check("core: PLAYER_LOGIN loads and validates the saved learned table",
            Learn.Get(589) ~= nil and Learn.Get(17) == nil)

        SeedLearned(700, 4, 2.0, "channel") -- no spell name known
        local resets = S.resets
        S.prints = {}
        SlashCmdList.COMBATTEXTICONS(" Learned Chat ")
        local text = table.concat(S.prints, "\n")
        Check("slash: /cti learned lists name, period and kind",
            text:find("Shadow Word: Pain", 1, true) and text:find("3.00 s", 1, true) and text:find("dot", 1, true) ~= nil)
        Check("slash: /cti learned falls back to the id when no name", text:find("spell 700", 1, true) ~= nil)
        Check("slash: /cti learned does not toggle the addon", db.enabled == true and S.resets == resets)

        S.prints = {}
        CombatTextIconsCharDB.votes[701] = { casts = 1, sigs = {} }
        SlashCmdList.COMBATTEXTICONS("FORGET")
        Check("slash: /cti forget clears learned and votes", Learn.Get(589) == nil and Learn.Get(700) == nil
            and next(CombatTextIconsCharDB.learned) == nil and next(CombatTextIconsCharDB.votes) == nil)
        Check("slash: /cti forget confirms and does not toggle the addon",
            #S.prints == 1 and S.prints[1]:find("forgot", 1, true) ~= nil and db.enabled == true and S.resets == resets)

        S.prints = {}
        SlashCmdList.COMBATTEXTICONS("learned chat")
        Check("slash: /cti learned with nothing learned says so",
            #S.prints == 1 and S.prints[1]:find("nothing learned", 1, true) ~= nil and db.enabled == true)
    end

    -- Learned lookup -----------------------------------------------------------------
    do
        local ns = T.BootSpells()
        local S = T.State()
        local Tracker = ns.Tracker
        local P = T.Plate("nameplate1")
        S.plates.nameplate1, S.haste, S.target = P, 0, "nameplate1"
        SeedLearned(9001, 32, 3.0, "dot")
        SeedLearned(9002, 32, 1.0, "channel")
        SeedLearned(9003, 32, 3.0, "hot")
        SeedLearned(980, 32, 5.0, "dot") -- a Forever-style collision with a retail table key

        Tracker.OnCast("player", 9001, 100)
        Check("lookup: learned DoT first tick one period after the cast", Tracker.Identify(P, 32, 1000, "", 103.0) == 9001)
        Check("lookup: learned DoT keeps ticking", Tracker.Identify(P, 32, 1000, "", 106.0) == 9001)
        Check("lookup: recast of a learned DoT (no duration field) does not error", pcall(Tracker.OnCast, "player", 9001, 107))

        Tracker.OnCast("player", 980, 200)
        Check("lookup: the retail table wins over a learned entry of the same ID (period 2, not 5)",
            Tracker.Identify(P, 32, 1000, "", 202.0) == 980)

        Check("lookup: learned channel starts without a duration field", pcall(Tracker.OnChannelStart, 9002, 300))
        Check("lookup: learned channel ticks", Tracker.Identify(P, 32, 500, "", 301.0) == 9002
            and Tracker.Identify(P, 32, 500, "", 302.0) == 9002)
        Tracker.OnChannelStop(303)
        Check("lookup: learned channel gone after the stop", Tracker.Identify(P, 32, 500, "", 303.0) == nil)
        Tracker.OnChannelStart(9002, 400)
        Check("lookup: learned channel lives until the stop (default 10 s), first tick late", Tracker.Identify(P, 32, 500, "", 409.0) == 9002)

        Check("lookup: learned HoT is not a plate instance", pcall(Tracker.OnCast, "player", 9003, 500)
            and not Tracker.QualifiesByPhase(P, 32, 1000, "", 503.0))
    end

    -- A learned DoT's own hit in its cast frame (runs 20261025T192458Z, 194821Z: Flame Shock's initial damage was '?') ----
    do
        local ns = T.BootSpells()
        local S = T.State()
        local Tracker = ns.Tracker
        local P = T.Plate("nameplate1")
        S.plates.nameplate1, S.haste, S.target = P, 0, "nameplate1"
        SeedLearned(9001, 32, 3.0, "dot")
        SeedLearned(980, 32, 5.0, "dot")

        Tracker.OnCast("player", 9001, 100)
        Check("lookup direct: a same-school hit in a learned DoT's cast frame is that DoT's, once",
            Tracker.Identify(P, 32, 1500, "", 100) == 9001 and Tracker.Identify(P, 32, 1500, "", 100) == nil)
        Tracker.OnCast("player", 9001, 200)
        Check("lookup direct: another school, or a later frame, is not claimed",
            Tracker.Identify(P, 4, 1500, "", 200) == nil and Tracker.Identify(P, 32, 1500, "", 200.5) == nil)
        Tracker.OnCast("player", 980, 300)
        Check("lookup direct: a retail table DoT claims no cast-frame hit", Tracker.Identify(P, 32, 1500, "", 300) == nil)
    end

    -- Rig and feed boundary -------------------------------------------------------------
    -- Rig(spells): the addon on fresh stubs, Display.Plate recording the icon drawn; `spells` loads the
    -- fixture table (tests/fixture_spells.lua) as ns.Spells for the scenarios that use table spells.
    --   rig.Cast(t, id, unit)                     UNIT_SPELLCAST_SUCCEEDED, target plate `unit`
    --   rig.Channel(t, id, unit, reversed)        SUCCEEDED + CHANNEL_START (reversed: CHANNEL_START first)
    --   rig.Stop(t)                               CHANNEL_STOP of the last channel
    --   rig.Hit(t, amount, school, unit, flag)    a WOUND on a plate; returns the icon drawn or nil
    --   rig.Heal(t, unit, amount, school)         a HEAL on a group token; returns the icon drawn or nil
    --   rig.Miss(t, event)                        a MISS-type event on nameplate1
    --   rig.Seed(id, school, period, kind)        a learned entry, written directly
    --   rig.Streams(unit)                         the live streams of that plate or token
    --   rig.Votes(id)                             the vote entry of a spell
    --   rig.Fed()                                 the recorded Streams.Feed calls { key, school, amount, flag, kind, now }
    --   rig.Learned(id)                           the saved learned entry
    --   rig.Drawn(id)                             icons drawn so far for spell `id`
    local function Rig(spells)
        local ns = T.Boot(nil, spells)
        local S = T.State()
        local rig = { ns = ns, S = S, icons = {} }
        S.haste, S.target = 0, "nameplate1"
        ns.Display.Plate = function(_, texture)
            rig.last = texture
            rig.icons[#rig.icons + 1] = texture
        end
        function rig.Cast(t, id, unit)
            S.now, S.target = t, unit or "nameplate1"
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-" .. t, id)
        end
        function rig.Channel(t, id, unit, reversed)
            S.now, S.target = t, unit or "nameplate1"
            rig.guid = "Cast-" .. t
            if reversed then
                ns.Core.UNIT_SPELLCAST_CHANNEL_START("player", rig.guid, id)
                ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", rig.guid, id)
            else
                ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", rig.guid, id)
                ns.Core.UNIT_SPELLCAST_CHANNEL_START("player", rig.guid, id)
            end
        end
        function rig.Stop(t)
            S.now = t
            ns.Core.UNIT_SPELLCAST_CHANNEL_STOP("player", rig.guid)
        end
        function rig.Hit(t, amount, school, unit, flag)
            S.now, S.pending, rig.last = t, {}, nil
            ns.Core.UNIT_COMBAT(unit or "nameplate1", "WOUND", flag or "", amount, school)
            return rig.last
        end
        function rig.Miss(t, event)
            S.now, S.pending = t, {}
            ns.Core.UNIT_COMBAT("nameplate1", event, "", nil, 32)
        end
        rig.Seed = SeedLearned
        function rig.Learned(id) return CombatTextIconsCharDB.learned[id] end
        function rig.Drawn(id)
            local count = 0
            for _, texture in ipairs(rig.icons) do if texture == "tex:" .. id then count = count + 1 end end
            return count
        end
        local function Key(unit) return unit:find("^nameplate") and C_NamePlate.GetNamePlateForUnit(unit) or unit end
        rig.fed = {}
        local feed = ns.Streams.Feed
        ns.Streams.Feed = function(key, school, amount, flagText, kind, now)
            rig.fed[#rig.fed + 1] = { key = key, school = school, amount = amount, flag = flagText, kind = kind, now = now }
            return feed(key, school, amount, flagText, kind, now)
        end
        function rig.Fed() return rig.fed end
        function rig.Streams(unit) return ns.Streams.Live(Key(unit or "nameplate1"), S.now) end
        function rig.Votes(id) return ns.Learn.Votes(id) end
        ns.Display.Player = function(_, texture) rig.lastHeal = texture end
        function rig.Heal(t, unit, amount, school)
            S.now, S.pending, rig.lastHeal = t, {}, nil
            ns.Core.UNIT_COMBAT(unit, "HEAL", "", amount, school or 2)
            return rig.lastHeal
        end
        return rig
    end

    -- Feed boundary (Review Focus 1): only unclaimed hits reach Streams.Feed
    do
        local rig = Rig()
        for _, t in ipairs({ 0, 2, 4, 6 }) do rig.Hit(t, 1000, 32) end
        Check("feed: four unclaimed periodic hits are fed and form one stream",
            #rig.Fed() == 4 and rig.Fed()[1].kind == "enemy" and #rig.Streams() == 1)

        -- guards (green before and after): claimed hits never reach the feed
        rig = Rig(true)
        rig.ns.Tracker.OnCast("player", 980, 0) -- Agony: ticks 2, 4, 6
        for _, t in ipairs({ 2, 4, 6 }) do rig.Hit(t, 1000, 32) end
        Check("feed: ticks claimed by an instance are never fed", rig.Drawn(980) == 3 and #rig.Fed() == 0 and #rig.Streams() == 0)
        rig = Rig(true)
        rig.ns.Tracker.OnCast("player", 5740, 0) -- Rain of Fire (area, school 4)
        for _, t in ipairs({ 2, 3, 4 }) do rig.Hit(t, 900, 4) end
        Check("feed: ticks claimed by an area are never fed", rig.Drawn(42223) == 3 and #rig.Fed() == 0)
        rig = Rig(true)
        rig.ns.Tracker.OnCast("player", 27243, 0) -- Seed of Corruption (spread)
        rig.ns.Tracker.OnMeterHit(C_NamePlate.GetNamePlateForUnit("nameplate1"), 0.2)
        for _, t in ipairs({ 3, 5, 7 }) do rig.Hit(t, 1500, 36) end
        Check("feed: ticks claimed by a spread are never fed", rig.Drawn(445474) == 3 and #rig.Fed() == 0)

        -- heals: kind "heal", size guard skipped (overheal), never when claimed
        rig = Rig()
        for k, amount in ipairs({ 800, 200, 0, 500 }) do rig.Heal(3 * k, "party2", amount) end
        Check("feed: unclaimed heals are fed as kind heal; amounts 800 / 200 / 0 / 500 still form a stream",
            #rig.Fed() == 4 and rig.Fed()[1].kind == "heal" and rig.Fed()[1].key == "party2" and #rig.Streams("party2") == 1)
        rig = Rig()
        rig.Seed(139, 2, 3.0, "hot")
        rig.S.harmful[139], rig.S.helpful[139] = false, true
        rig.Cast(100, 139, "party2")
        Check("feed: a learned HoT tick is shown and never fed", rig.Heal(103, "party2", 800) == "tex:139" and #rig.Fed() == 0)

        -- Core boundary of the size guard (old spec 6): amount and flag reach Feed in the right slots
        for _, row in ipairs({
            { "crit in the band: 1000 / 1000 / 1000 / CRITICAL 2400", { 1000, 1000, 1000, 2400 }, { "", "", "", "CRITICAL" }, true },
            { "plain 1000 / 1000 / 1000 / 2000 rejected", { 1000, 1000, 1000, 2000 }, nil, false },
            { "1000 / 1150 / 1150 / 1150 within 15 %", { 1000, 1150, 1150, 1150 }, nil, true },
            { "1000 / 1200 / 1200 / 1200 outside 15 %", { 1000, 1200, 1200, 1200 }, nil, false },
            { "0 / 700 / 700 / 700: zero skips the guard", { 0, 700, 700, 700 }, nil, true },
            { "344 / 344 / 344 / 700 rejected", { 344, 344, 344, 700 }, nil, false },
            { "secret amounts skip the guard", { Secret(344), Secret(700), Secret(700), Secret(700) }, nil, true },
        }) do
            rig = Rig()
            for k, amount in ipairs(row[2]) do rig.Hit(2 * k, amount, 32, nil, row[3] and row[3][k]) end
            Check("feed: " .. row[1], (#rig.Streams() == 1) == row[4])
        end
        rig = Rig()
        rig.Hit(2, 1000, 32)
        rig.Hit(4, 1000, 32)
        Check("feed: a secret school raises no error and forms nothing",
            pcall(rig.Hit, 6, 1000, T.Secret(32)) and #rig.Streams() == 0)
    end

    -- Removed API and saved data (Review Focus 5)
    do
        local ns = T.Boot()
        Check("api: Tracker.Probes, Tracker.probesCreated and Learn.Observe are gone",
            ns.Tracker.Probes == nil and ns.Tracker.probesCreated == nil and ns.Learn.Observe == nil)
        ns = T.Boot(function()
            CombatTextIconsCharDB = {
                learned = { [589] = { school = 32, period = 3.1, kind = "dot", misses = 1 } }, -- old probe learner: a real period
                pending = { [200] = { school = 32, period = 3, kind = "hot" } },
            }
        end)
        local db = CombatTextIconsCharDB
        Check("saved: pending is deleted on load, valid learned entries load unchanged",
            db.pending == nil and type(db.votes) == "table" and ns.Learn.Get(589) ~= nil and ns.Learn.Get(589).period == 3.1)
        T.State().target = "nameplate1"
        ns.Tracker.OnCast("player", 589, 100)
        Check("saved: an old learned DoT still serves its tick (cast 100, tick 103.1)",
            ns.Tracker.Identify(C_NamePlate.GetNamePlateForUnit("nameplate1"), 32, 1000, "", 103.1) == 589)
    end

    -- a table DoT whose first tick is 0 (absorbed) keeps showing its later ticks
    do
        local rig = Rig(true)
        rig.Cast(0, 980)
        rig.Hit(2, 0, 32)
        local second, third = rig.Hit(4, 1000, 32), rig.Hit(6, 1000, 32)
        Check("amount: Agony ticks 0 / 1000 / 1000 -> both 1000 ticks shown", second == "tex:980" and third == "tex:980")
    end

    -- Learned DoT lifetime, recast and misses -------------------------------------------
    -- Review Focus 2: ticks keep showing past 3 * period while they keep coming
    do
        local rig = Rig()
        rig.Seed(9001, 32, 3.0, "dot")
        rig.Cast(0, 9001)
        for t = 3, 30, 3 do rig.Hit(t, 1000, 32) end
        Check("focus 2: a learned DoT shows all 10 ticks over 30 s (deadline slides; " .. rig.Drawn(9001) .. "/10)", rig.Drawn(9001) == 10)
    end

    -- spec 9: recast on the same plate; the next tick at the kept phase or at recast + period is shown
    do
        local rig = Rig()
        rig.Seed(9001, 32, 3.0, "dot")
        rig.Cast(0, 9001)
        rig.Hit(3, 1000, 32)
        rig.Hit(6, 1000, 32)
        rig.Cast(7.5, 9001)
        rig.Hit(9, 1000, 32)
        rig.S.group = true -- in a group a hit nothing identifies stays hidden (solo it draws "?")
        Check("spec 9: after a kept-phase tick restartAt is cleared (10.5 hidden)", rig.Hit(10.5, 1000, 32) == nil)
        rig.S.group = false
        rig.Hit(12, 1000, 32)
        Check("spec 9: recast, next tick at the kept phase (9.0, 12.0) shown (" .. rig.Drawn(9001) .. "/4)", rig.Drawn(9001) == 4)

        rig = Rig()
        rig.Seed(9001, 32, 3.0, "dot")
        rig.Cast(0, 9001)
        rig.Hit(3, 1000, 32)
        rig.Hit(6, 1000, 32)
        rig.Cast(7.5, 9001)
        rig.Hit(10.5, 1000, 32)
        Check("spec 9: recast, next tick at recast + period (10.5) shown", rig.Drawn(9001) == 3)
        -- spec 9b: that tick left the period at 3.0 (a smoothed 3.3 would also accept 14.4)
        local Tracker, P = rig.ns.Tracker, C_NamePlate.GetNamePlateForUnit("nameplate1")
        Check("spec 9b: a tick matched through restartAt leaves the period unchanged",
            Tracker.QualifiesByPhase(P, 32, 1000, "", 13.5) and not Tracker.QualifiesByPhase(P, 32, 1000, "", 14.4))
        rig.Hit(13.5, 1000, 32)
        Check("spec 9: the tick after a restart tick follows the new phase (13.5)", rig.Drawn(9001) == 4)

        rig = Rig()
        rig.Seed(9001, 32, 3.0, "dot")
        rig.Cast(0, 9001)
        rig.Cast(1, 9001) -- recast before the first tick
        rig.Hit(4, 1000, 32)
        Check("spec 9: recast before the first tick, first tick at recast + period shown", rig.Drawn(9001) == 1)

        rig = Rig(true)
        rig.Cast(0, 980)
        rig.Cast(1, 980) -- a table DoT keeps the retail rule: no restart phase (Agony, period 2: due 2.0, not 3.0)
        rig.Hit(3, 1000, 32)
        Check("spec 9: a recast of a table DoT does not open a restart phase", rig.Drawn(980) == 0)
    end

    -- spec 10: a wrong learned entry is removed after two consecutive misses it could have seen
    do
        local function Fresh()
            local rig = Rig(true)
            rig.Seed(9001, 32, 3.0, "dot")
            return rig, rig.ns.Tracker, C_NamePlate.GetNamePlateForUnit("nameplate1")
        end
        local rig, Tracker, P = Fresh()
        rig.Cast(0, 9001)
        rig.Cast(20, 9001)
        Check("spec 10: one first tick that never came is one miss (still learned)", rig.Learned(9001) ~= nil)
        Tracker.QualifiesByPhase(P, 32, 1000, "", 40)
        Check("spec 10: two casts whose first tick never comes -> removed from learned and votes",
            not rig.Learned(9001) and rig.Votes(9001) == nil)

        rig, Tracker, P = Fresh()
        rig.Cast(0, 9001)
        rig.Cast(20, 9001)
        rig.Hit(23, 1000, 32)   -- the first tick of the second cast comes: the streak resets
        rig.Cast(40, 9001)
        Tracker.QualifiesByPhase(P, 32, 1000, "", 60)
        Check("spec 10: a matched first tick resets the miss count", rig.Learned(9001) ~= nil)

        rig, Tracker, P = Fresh()
        rig.Cast(0, 9001)
        Tracker.OnPlateRemoved(P)
        rig.Cast(20, 9001)
        Tracker.OnPlateRemoved(P)
        rig.Cast(40, 9001)
        Tracker.QualifiesByPhase(P, 32, 1000, "", 60)
        Check("spec 10: not a miss - the plate was removed before the deadline", rig.Learned(9001) ~= nil)

        rig, Tracker, P = Fresh()
        rig.Cast(0, 9001)
        rig.Miss(0.3, "RESIST")
        rig.Cast(20, 9001)
        rig.Miss(20.3, "RESIST")
        Tracker.QualifiesByPhase(P, 32, 1000, "", 40)
        Check("spec 10: not a miss - a RESIST hit the plate 0.3 s after the cast", rig.Learned(9001) ~= nil)

        rig, Tracker, P = Fresh()
        for _, start in ipairs({ 0, 20 }) do
            rig.Cast(start, 9001)         -- 9001 is due at start + 3.0
            rig.Cast(start + 1, 980)      -- Agony is due at start + 3.0 too: the hit fits both
            rig.Hit(start + 3, 1000, 32)
        end
        Tracker.QualifiesByPhase(P, 32, 1000, "", 40)
        Check("spec 10: not a miss - the first-tick hit was ambiguous", rig.Learned(9001) ~= nil and rig.Drawn(9001) == 0)

        -- Agony and UA make each school-32 hit ambiguous; the learned school-4 DoT
        -- on the same plate had no part in it and still misses twice
        rig, Tracker, P = Fresh()
        rig.Seed(9020, 4, 3.0, "dot")
        for _, start in ipairs({ 0, 20 }) do
            rig.Cast(start, 9020)
            rig.Cast(start, 980)
            rig.Cast(start, 1259790)
            rig.Hit(start + 2, 1000, 32)
        end
        Tracker.QualifiesByPhase(P, 4, 1000, "", 40)
        Check("spec 10: an ambiguous hit of another school does not excuse a tickless learned DoT",
            rig.Drawn(980) == 0 and rig.Drawn(1259790) == 0 and not rig.Learned(9020))

        rig, Tracker, P = Fresh()
        rig.Seed(9002, 32, 1.0, "channel")
        for _, start in ipairs({ 0, 10 }) do
            rig.Channel(start, 9002)
            rig.Stop(start + 1.0)
        end
        Check("spec 10: not a miss - a channel stopped before period + tolerance (1.0 s < 1.25 s)", rig.Learned(9002) ~= nil)
        for _, start in ipairs({ 20, 30 }) do
            rig.Channel(start, 9002)
            rig.Stop(start + 1.3)
        end
        Check("spec 10: a channel that lasted 1.3 s with no tick, twice -> removed", not rig.Learned(9002) and rig.Votes(9002) == nil)
        Check("spec 10: the channel miss never touched the DoT entry", rig.Learned(9001) ~= nil)
    end

    -- Learning scenarios (Task 2.3). Events are played in time order; a "do" step runs a Check mid-run.
    do
        local function At(events, t, fn) events[#events + 1] = { t = t, fn = fn } end
        local function Play(events)
            for index, event in ipairs(events) do event.order = index end
            table.sort(events, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.order < b.order end)
            for _, event in ipairs(events) do event.fn() end
        end
        -- cast(s) at t0 on `unit`, then `ticks` unclaimed hits `period` apart
        local function Dot(rig, events, t0, ids, unit, period, school, ticks)
            for _, id in ipairs(ids) do At(events, t0, function() rig.Cast(t0, id, unit) end) end
            for k = 1, ticks do At(events, t0 + k * period, function() rig.Hit(t0 + k * period, 1000, school, unit) end) end
        end
        local function Sig(rig, id) local v = rig.Votes(id) return v and v.sigs[1] end
        local function Near(a, b, tolerance) return a ~= nil and math.abs(a - b) <= tolerance end

        -- FS-like: school 12, P 1.7, a same-frame twin, fresh plate every 20 s
        local rig, events = Rig(), {}
        for k = 0, 2 do Dot(rig, events, 20 * k, { 9001, 9002 }, "nameplate" .. (k + 1), 1.7, 12, 4) end
        At(events, 27, function()   -- births at 6.8, 26.8, 46.8
            local sig = Sig(rig, 9001)
            Check("fs-like: two fresh plates -> 2 votes, expected 0.198, not learned (p 0.0173)",
                sig and sig.votes == 2 and Near(sig.expected, 0.1983, 0.003) and sig.kind == "dot" and sig.school == 12
                and not rig.Learned(9001) and not rig.Learned(9002))
        end)
        Play(events)
        Check("fs-like: the third fresh plate learns both twins (p 0.0035)", rig.Learned(9001) and rig.Learned(9002)
            and rig.Learned(9001).kind == "dot" and rig.Learned(9001).school == 12 and Near(rig.Learned(9001).period, 1.7, 0.03)
            and rig.Votes(9001) == nil)

        -- spec 1/2 replacement: school 32, P 3, four fresh plates
        rig, events = Rig(), {}
        for k = 0, 3 do Dot(rig, events, 20 * k, { 9004 }, "nameplate" .. (k + 1), 3, 32, 4) end
        At(events, 53, function()   -- births at 12, 32, 52, 72
            Check("spec 1/2: three plates -> 3 votes, expected 0.525, not learned (p 0.0164)",
                Sig(rig, 9004) and Sig(rig, 9004).votes == 3 and Near(Sig(rig, 9004).expected, 0.525, 0.005) and not rig.Learned(9004))
        end)
        Play(events)
        Check("spec 1/2: the fourth plate learns it (expected 0.7, p 0.0058), period 3", rig.Learned(9004)
            and Near(rig.Learned(9004).period, 3.0, 0.05) and rig.Drawn(9004) == 0)

        -- multi-dot: casts 3.5 s apart on 4 plates, each recast every 15 s while the ticks run on
        rig, events = Rig(), {}
        for k = 0, 3 do
            local t0, unit = 3.5 * k, "nameplate" .. (k + 1)
            Dot(rig, events, t0, { 9003 }, unit, 3, 32, 6)
            At(events, t0 + 15, function() rig.Cast(t0 + 15, 9003, unit) end)
        end
        At(events, 22, function()   -- births at 12, 15.5, 19, 22.5
            Check("multi-dot: before the 4th plate's birth (22.5) -> 3 votes, not learned", Sig(rig, 9003) and Sig(rig, 9003).votes == 3
                and not rig.Learned(9003))
        end)
        Play(events)
        Check("multi-dot: learned at the 4th plate's birth; recasts added no births", rig.Learned(9003) ~= nil)

        -- HoT: Renew-like, school 2, P 2.5, five group units, recast every 12 s
        rig, events = Rig(), {}
        rig.S.harmful[139], rig.S.helpful[139] = false, true
        for k, unit in ipairs({ "party1", "party2", "party3", "party4", "player" }) do
            local t0 = 4 * (k - 1)
            At(events, t0, function() rig.Cast(t0, 139, unit) end)
            At(events, t0 + 12, function() rig.Cast(t0 + 12, 139, unit) end)
            for j = 1, 6 do At(events, t0 + 2.5 * j, function() rig.Heal(t0 + 2.5 * j, unit, 800) end) end
        end
        At(events, 14.1, function()   -- births at t0 + 10: 10, 14, 18, ...
            Check("hot: two units -> 2 votes, expected 0.292, not learned (p 0.0351)",
                Sig(rig, 139) and Sig(rig, 139).votes == 2 and Near(Sig(rig, 139).expected, 0.2917, 0.004) and not rig.Learned(139))
        end)
        -- no check after the 3rd unit: p 0.0101 is just above ALPHA
        Play(events)
        Check("hot: the fourth unit learns it as a hot, period 2.5 (p 0.0030)", rig.Learned(139) and rig.Learned(139).kind == "hot"
            and rig.Learned(139).school == 2 and Near(rig.Learned(139).period, 2.5, 0.05))
        rig = Rig()
        rig.S.harmful[139], rig.S.helpful[139] = false, true
        rig.Cast(0, 139, "party2")
        for j = 1, 4 do rig.Heal(2.5 * j, "party3", 800) end
        Check("hot: a foreign HoT stream on another unit gets no votes and no expected",
            #rig.Streams("party3") == 1 and rig.Votes(139).casts == 1 and #rig.Votes(139).sigs == 0)

        -- rowless: a read found the cast with no meter row (Learn.RowsRead), so its dot rhythms stop voting; a hot still votes
        for _, row in ipairs({ { "dot", false }, { "dot", true }, { "hot", true } }) do
            local kind, rowless = row[1], row[2]
            rig = Rig()
            if kind == "hot" then
                rig.S.harmful[139], rig.S.helpful[139] = false, true
                rig.Cast(0, 139, "party2")
                rig.Votes(139).rowless = rowless or nil
                for j = 1, 4 do rig.Heal(2.5 * j, "party2", 800) end
            else
                rig.Cast(0, 205180)
                rig.Votes(205180).rowless = rowless or nil
                for k = 1, 5 do rig.Hit(k * 1.69, 1000, 32) end
            end
            local id = kind == "hot" and 139 or 205180
            local votes = Sig(rig, id) and Sig(rig, id).votes or 0
            Check("rowless: a " .. kind .. " cast" .. (rowless and " a read found no row for" or " with a row") .. " gets "
                .. (rowless and kind == "dot" and "no vote" or "its vote"), votes == (rowless and kind == "dot" and 0 or 1))
        end

        -- physical: school 1 needs 3 votes, the school-32 control learns at 2 (p 0.0063); P 1.0, plates at 0 / 20 / 40
        for _, row in ipairs({ { 1, 9006 }, { 32, 9007 } }) do
            rig, events = Rig(), {}
            local school, id = row[1], row[2]
            for k = 0, 2 do Dot(rig, events, 20 * k, { id }, "nameplate" .. (k + 1), 1.0, school, 4) end
            At(events, 30, function()   -- two plates done (births created at 4 and 24)
                if school == 1 then
                    Check("physical: school 1 with 2 votes (expected 0.117) is not learned",
                        Sig(rig, id) and Sig(rig, id).votes == 2 and Near(Sig(rig, id).expected, 0.1167, 0.003) and not rig.Learned(id))
                else
                    Check("physical: the school-32 control is learned with 2 votes", rig.Learned(id) ~= nil)
                end
            end)
            Play(events)
            Check("physical: school " .. school .. " is learned after the third plate (p 0.0008)", rig.Learned(id) ~= nil)
        end

        -- alias target: 205180 has 2 votes at P 1.69; a third cast and stream learns it, unless row 446285 aliases to it
        -- (its draws would be judged against that row, so they could only score over)
        for _, aliased in ipairs({ false, true }) do
            rig = Rig()
            if aliased then rig.ns.Fingerprints.SetAlias(446285, 205180) end
            CombatTextIconsCharDB.votes[205180] = { casts = 2, sigs = { { kind = "dot", school = 32, period = 1.69, votes = 2, expected = 0.2 } } }
            rig.Cast(0, 205180)
            for k = 1, 5 do rig.Hit(k * 1.69, 1000, 32) end
            if aliased then
                Check("alias target: a cast that row 446285 aliases to gets no vote, so it is not learned",
                    rig.Learned(205180) == nil and rig.Votes(205180).casts == 2 and Sig(rig, 205180).votes == 2)
            else
                Check("alias target: control, the same spell with no alias on it is learned by the third vote",
                    rig.Learned(205180) ~= nil and Near(rig.Learned(205180).period, 1.69, 0.03))
            end
        end

        -- channel: Mind Flay-like, P 1.0, both event orders; one entry and one count per channel
        for _, reversed in ipairs({ false, true }) do
            local name = "channel" .. (reversed and " (CHANNEL_START first)" or "")
            rig = Rig()
            for k = 0, 1 do
                local t0 = 20 * k
                rig.Channel(t0, 9002, "nameplate1", reversed)
                for j = 1, 4 do rig.Hit(t0 + j, 800, 32) end
                rig.Stop(t0 + 4)
                if k == 0 then
                    Check(name .. ": one channel -> 1 count, 1 vote, not learned", rig.Votes(9002).casts == 1 and Sig(rig, 9002).votes == 1
                        and Sig(rig, 9002).kind == "channel" and not rig.Learned(9002) and rig.Drawn(9002) == 0)
                end
            end
            Check(name .. ": the second channel learns it as a channel, period 1 (p 0.0063)", rig.Learned(9002)
                and rig.Learned(9002).kind == "channel" and Near(rig.Learned(9002).period, 1.0, 0.03))
        end

        -- explained away: Agony's missed ticks (amount 300 < 0.4 x its last tick 1000) form a stream on its predicted ticks
        -- Agony cast at 0 (first tick 2, amount 1000), the unknown 9005 cast at `castAt` (inside the stream's birth
        -- window [first hit - 2.4, first hit - 1.0]), Agony refreshed at 5 (keeps the instance alive), then four
        -- hits at 4 / 6 / 8 / 10 plus `offset`.
        local function Explained(withAgony, castAt, offset, amount)
            local run, steps = Rig(true), {}
            if withAgony then
                At(steps, 0, function() run.Cast(0, 980) end)
                At(steps, 2, function() run.Hit(2, 1000, 32) end)
                At(steps, 5, function() run.Cast(5, 980) end)
            end
            At(steps, castAt, function() run.Cast(castAt, 9005) end)
            for _, t in ipairs({ 4, 6, 8, 10 }) do At(steps, t + offset, function() run.Hit(t + offset, amount, 32) end) end
            Play(steps)
            return run
        end
        rig = Explained(true, 2.5, 0, 300)   -- 300 < 0.4 x 1000: Agony's instance does not claim them
        Check("explained away: a stream on a live Agony's predicted ticks gives the unknown cast no votes, no expected",
            rig.Drawn(980) == 1 and #rig.Streams() == 1 and rig.Votes(9005).casts == 1 and #rig.Votes(9005).sigs == 0)
        rig = Explained(false, 2.5, 0, 300)
        Check("explained away: control, no Agony -> the unknown cast gets the vote (expected 0.117)",
            Sig(rig, 9005) and Sig(rig, 9005).votes == 1 and Near(Sig(rig, 9005).expected, 0.1167, 0.003))
        rig = Explained(true, 3.0, 0.7, 1000)   -- window [2.3, 3.7]; 0.7 s off Agony's ticks (> 0.3)
        Check("explained away by phase: a same-signature stream 0.7 s off Agony's ticks does vote",
            Sig(rig, 9005) and Sig(rig, 9005).votes == 1)

        -- a stranger's stream with no cast in its birth window: expected only, no vote (old spec 4)
        rig = Rig()
        rig.Cast(0, 9008)
        for _, t in ipairs({ 0.4, 3.4, 6.4, 9.4 }) do rig.Hit(t, 1000, 32) end
        Check("stranger: a cast outside the birth window gets expected 0.175 and no vote",
            Sig(rig, 9008) and Sig(rig, 9008).votes == 0 and Near(Sig(rig, 9008).expected, 0.175, 0.003) and not rig.Learned(9008))
    end

    -- Learned channels -------------------------------------------------------------------
    -- spec 7: Mind Flay-like channel (school 32, period 1.0 from the channel start), learned entry
    for _, reversed in ipairs({ false, true }) do
        local rig = Rig()
        rig.Seed(9002, 32, 1.0, "channel")
        rig.Channel(0, 9002, "nameplate1", reversed)
        for _, dt in ipairs({ 1, 2, 3 }) do rig.Hit(dt, 800, 32) end
        local name = "spec 7" .. (reversed and " (CHANNEL_START first)" or "")
        Check(name .. ": a learned channel shows its ticks (" .. rig.Drawn(9002) .. "/3)", rig.Drawn(9002) == 3)
        rig.Stop(3)
        rig.S.group = true -- in a group a hit nothing identifies stays hidden (solo it draws "?")
        Check(name .. ": CHANNEL_STOP ends it (a later hit is hidden)", rig.Hit(4, 800, 32) == nil)
    end

    -- An unknown channel whose first tick lands in its cast frame (Void Torrent 263165: 3 s, ticks 0 / 0.9 / 1.8 / 2.7)
    for _, reversed in ipairs({ false, true }) do
        local function Torrents(stopAfter)
            local rig = Rig()
            for _, start in ipairs({ 0, 30, 60 }) do
                rig.Channel(start, 9600, "nameplate1", reversed)
                for _, dt in ipairs({ 0, 0.9, 1.8 }) do rig.Hit(start + dt, 7000, 32) end
                if stopAfter < 2.7 then rig.Stop(start + stopAfter) end
                rig.Hit(start + 2.7, 7000, 32)
                if stopAfter >= 2.7 then rig.Stop(start + stopAfter) end
            end
            return rig.Learned(9600)
        end
        local name = "channel owner" .. (reversed and " (CHANNEL_START first)" or "")
        local learned = Torrents(2.75)
        Check(name .. ": ticks inside the channel teach it as a channel", learned ~= nil and learned.kind == "channel")
        Check(name .. ": a CHANNEL_STOP before the 4th tick leaves the channel unlearned", Torrents(2.0) == nil)
    end

    -- Haste for learned spells (Task 3.1): saved periods are haste-free bases, expected = base / (1 + h/100)
    do -- learned at 10 % (real 2.0 -> base 2.2), cast at 40 %: ticks every 2.2 / 1.4 = 1.571 s
        local rig = Rig()
        rig.S.haste = 40
        rig.Seed(9001, 32, 2.2, "dot")
        rig.Cast(100, 9001)
        rig.Hit(101.571, 1000, 32)
        rig.Hit(103.143, 1000, 32)
        Check("haste: base 2.2 cast at 40 %: the 1.571 s first tick and the next are shown (" .. rig.Drawn(9001) .. "/2)",
            rig.Drawn(9001) == 2)
        Check("haste: no miss counted", rig.Learned(9001) ~= nil and rig.Learned(9001).misses == 0)
    end
    do -- non-hasted DoT (real 2.0 at any haste): learned at 10 % (base 2.2), cast at 20 %
        local rig = Rig()
        rig.S.haste = 20
        rig.Seed(9001, 32, 2.2, "dot")
        rig.Cast(100, 9001)                                 -- expectation 2.2 / 1.2 = 1.833, tolerance 0.367
        local first = rig.Hit(102, 1000, 32)                -- error 0.167: shown
        for k = 2, 21 do rig.Hit(100 + 2 * k, 1000, 32) end -- 20 matched ticks, each sample 2.0 * 1.2 = 2.4
        local base = rig.Learned(9001).period
        Check("haste: the 1.833 expectation still shows the 2.0 s first tick", first == "tex:9001")
        Check("haste: after 20 nudges at 20 % the base is within 2 % of 2.4 (" .. base .. ")", math.abs(base - 2.4) < 0.048)
        Check("haste: base = 2.4 - 0.2 * 0.9^20 (by hand 2.376)", math.abs(base - (2.4 - 0.2 * 0.9 ^ 20)) < 1e-6)
    end
    do -- UnitSpellHaste secret: h = 0, ticks at the saved base, no nudge
        local rig = Rig()
        rig.Seed(9001, 32, 2.2, "dot")
        rig.S.haste = Secret(40)
        local ok = pcall(function()
            rig.Cast(100, 9001)
            for k = 1, 5 do rig.Hit(100 + 2.2 * k, 1000, 32) end
        end)
        Check("haste: secret UnitSpellHaste: no error, 5/5 ticks, base untouched",
            ok and rig.Drawn(9001) == 5 and rig.Learned(9001).period == 2.2)
    end
    do -- run lock3 F3, crowded: a stranger's hit inside a learned DoT's window must not shrink its period
        local rig = Rig()
        rig.Seed(9001, 32, 0.8, "dot")
        rig.Cast(100, 9001)
        rig.Hit(100.8, 1000, 32)
        rig.Hit(101.6, 1000, 32)
        local stranger = rig.Hit(102.16, 1000, 32)          -- 0.56 s on: inside the 0.25 s tolerance, 30 % short
        rig.Hit(102.4, 1000, 32)                            -- the DoT's own tick, 0.24 s after the stranger: no match
        Check("ticks: a learned instance smooths in no gap 30 % under its base (0.56 on 0.8): the tick 1.04 s on still"
            .. " matches", stranger == "tex:9001" and rig.Hit(103.2, 1000, 32) == "tex:9001")
    end
    do -- run lock3 F3, crowded: Agony's windows took strangers' Shadow hits 0.47-2.5x the tick before
        local function Draws(crowded, amount)
            local rig = Rig()
            rig.ns.Teacher.Start(99)
            rig.ns.Teacher.fight.crowded = crowded
            rig.Seed(9001, 32, 0.8, "dot")
            rig.Cast(100, 9001)
            rig.Hit(100.8, 1000, 32)
            local stranger = rig.Hit(101.6, amount, 32)
            return stranger, rig.Hit(102.4, 1000, 32)
        end
        local clear = Draws(false, 2000)
        local crowd, own = Draws(true, 2000)
        Check("ticks: a crowded fight's learned instance draws only a tick within SIZE_GUARD of the last (1150 on 1000,"
            .. " not 2000; clear: 2000 too); its own tick two periods on still matches",
            clear == "tex:9001" and crowd ~= "tex:9001" and own == "tex:9001" and Draws(true, 1150) == "tex:9001")
    end
    do -- run lock3 F3, crowded: like-sized strangers 0.17-0.25 s early took each of Agony's windows
        local function Draw(crowded, at)
            local rig = Rig()
            rig.ns.Teacher.Start(99)
            rig.ns.Teacher.fight.crowded = crowded
            rig.Seed(9001, 32, 1.0, "dot")
            rig.Cast(100, 9001)
            rig.Hit(101, 1000, 32)
            return rig.Hit(at, 1000, 32)
        end
        Check("ticks: a crowded fight's learned instance draws a tick only within half its tolerance (0.12 s early, not"
            .. " 0.2 s; clear: 0.2 s too)", Draw(true, 101.88) == "tex:9001" and Draw(true, 101.8) ~= "tex:9001"
            and Draw(false, 101.8) == "tex:9001")
    end
    do -- run lock3 F2: a 1.0 s series' hit 0.24 s before Agony's tick took its window, and the instance followed it
        local function Ticks(second, ownAt, first)
            local rig = Rig()
            rig.Seed(9001, 32, 1.0, "dot")
            rig.Cast(100, 9001)
            rig.Hit(101, first or 1000, 32)
            rig.Hit(102, second, 32)
            rig.Hit(102.8, 600, 32)                         -- a stranger 0.2 s early at 0.6x: drawn (clear fight)
            return rig.Hit(ownAt or 103.02, second, 32), rig.Hit(103.65, 600, 32), rig.Hit(104.02, second, 32)
        end
        local own, stranger, after = Ticks(1000)
        local mixed = Ticks(1000, nil, 1300)                -- 0.77x the tick before: neither steady nor rising
        -- run lock3 F2 558.837: the gaps grew 1.33 -> 1.48 s, so the own tick came 0.11 s late, behind a stranger
        -- 0.04 s early; still within the 0.25 s tolerance it goes back, 0.3 s late it does not
        local later = Ticks(1000, 103.22)
        local outside = Ticks(1000, 103.3)
        Check("ticks: a steady learned instance goes back to its own like-sized tick on its lattice (103.02 after 600 at"
            .. " 102.8, or 0.22 s late), not on to the stranger's next (103.65); not 0.3 s late, nor in a mixed one",
            own == "tex:9001" and stranger ~= "tex:9001" and after == "tex:9001" and mixed ~= "tex:9001"
            and later == "tex:9001" and outside ~= "tex:9001")
    end
    do -- run lock3 F4: Agony's ramp 1953 -> 2930, then a 1.0 s series' 2182 hit 0.19 s early took its window
        local function Own(rig, opening, at)
            rig.Seed(9001, 32, 1.0, "dot")
            rig.Cast(100, 9001)
            for k, amount in ipairs(opening) do rig.Hit(100 + k, amount, 32) end
            local n = #opening
            rig.Hit(100 + n + 0.81, 0.75 * opening[n], 32)  -- the stranger: drawn (clear fight), a drop
            return rig.Hit(at or 100 + n + 1.05, 1.44 * opening[n], 32)
        end
        local rising = Own(Rig(), { 1000, 1500 })
        local flat = Own(Rig(), { 1000, 1000 })              -- 1.44x a flat tick: not its series
        local late = Own(Rig(), { 1000, 1200, 1440, 1728, 2074, 2488, 2986 }) -- the 7th tick: past the ramp
        Check("ticks: a learned instance rising a ramp step goes back to its own next ramp tick (1.44x) after a drop;"
            .. " not after a flat series, nor past its first 6 ticks", rising == "tex:9001" and flat ~= "tex:9001"
            and late ~= "tex:9001")
    end
    do -- learned instances never touch `speeds`: a rhythm-learned period must not shorten the next cast
        local rig = Rig()
        rig.Seed(9001, 32, 2.2, "dot")
        rig.Cast(0, 9001)
        rig.Hit(1.2, 1000, 32)                              -- remembered (early), not shown
        rig.Hit(2.4, 1000, 32)                              -- first tick; the rhythm path finds period 1.2
        rig.Cast(20, 9001)                                  -- speeds[9001] would make this 2.2 * 0.545 = 1.2
        Check("haste: the next cast still expects the saved base (22.2 shown)", rig.Hit(22.2, 1000, 32) == "tex:9001")
    end

    -- Cast log hooks (Task 2.1). Review Focus 3: both channel orders give one entry and one `casts` count.
    do
        local function Key(unit) return unit:find("^nameplate") and C_NamePlate.GetNamePlateForUnit(unit) or unit end
        local function Log(rig, unit) return rig.ns.Streams.CastLog(Key(unit or "nameplate1")) end
        local function Casts(rig, id) local v = rig.ns.Learn.Votes(id) return v and v.casts or 0 end

        local rig = Rig()
        rig.Cast(0, 9008)
        Check("castlog: a harmful unknown cast logs a dot entry on the plate and counts once",
            #Log(rig) == 1 and Log(rig)[1].castID == 9008 and Log(rig)[1].kind == "dot" and Log(rig)[1].at == 0
            and Casts(rig, 9008) == 1)
        rig.ns.Tracker.OnCast("pet", 9008, 5)
        pcall(rig.ns.Tracker.OnCast, "player", T.Secret(9008), 6)
        Check("castlog: pet casts and secret ids log nothing and raise no error", #Log(rig) == 1)
        rig.Cast(0, 9008, "none")
        Check("castlog: no target plate -> no entry", #Log(rig, "none") == 0 and #Log(rig) == 1)
        rig.S.harmful[9010] = false
        rig.Cast(1, 9010)
        Check("castlog: neither harmful nor helpful -> no entry", #Log(rig) == 1)
        rig.S.autoRepeat[5019] = true
        rig.Cast(2, 5019)
        Check("castlog: an auto-repeat spell (wand Shoot) is not logged", #Log(rig) == 1)
        C_Spell.IsAutoRepeatSpell = nil
        rig.Cast(3, 5019)
        Check("castlog: without IsAutoRepeatSpell the cast is logged", #Log(rig) == 2)

        rig = Rig(true)
        rig.Seed(9009, 32, 3.0, "dot")
        rig.Cast(0, 980); rig.Cast(1, 445474); rig.Cast(2, 9009)
        Check("castlog: table, icon-only and learned casts are logged but cannot vote",
            #Log(rig) == 3 and rig.ns.Learn.Votes(980) == nil and rig.ns.Learn.Votes(445474) == nil
            and rig.ns.Learn.Votes(9009) == nil)
        local saved = C_Spell.IsSpellHarmful
        C_Spell.IsSpellHarmful = nil
        local before = #Log(rig)
        Check("castlog: missing IsSpellHarmful logs nothing and raises no error",
            pcall(rig.Cast, 5, 9013) and #Log(rig) == before)
        C_Spell.IsSpellHarmful = saved

        -- helpful casts: the heal unit's hot entry
        rig = Rig()
        rig.S.harmful[139], rig.S.helpful[139] = false, true
        rig.Cast(0, 139, "party2")
        rig.S.target = nil
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-n", 139)
        Check("castlog: a helpful cast logs hot on the group target, or on the player with no target",
            #Log(rig, "party2") == 1 and Log(rig, "party2")[1].kind == "hot" and #Log(rig, "player") == 1
            and #Log(rig) == 0)
        rig.S.target, rig.S.attackable.raid7 = "raid7", false
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-r", 139)
        Check("castlog: a friendly target outside the party logs nothing", #Log(rig, "player") == 1)

        -- channels, both arrival orders: exactly one entry (kind channel), one `casts`
        for _, reversed in ipairs({ false, true }) do
            local order = reversed and "CHANNEL_START first" or "SUCCEEDED first"
            rig = Rig()
            rig.Channel(0, 9002, "nameplate1", reversed)
            Check("castlog: " .. order .. " -> one channel entry, one count, nothing on the player",
                #Log(rig) == 1 and Log(rig)[1].kind == "channel" and Casts(rig, 9002) == 1 and #Log(rig, "player") == 0)
            rig.Channel(10, 9002, "nameplate1", reversed)
            Check("castlog: " .. order .. " -> a later channel is a new cast (2 entries, 2 counts)",
                #Log(rig) == 2 and Casts(rig, 9002) == 2)
            rig = Rig()
            rig.S.harmful[9030], rig.S.helpful[9030] = false, true
            rig.Channel(0, 9030, "nameplate1", reversed)
            Check("castlog: helpful channel at an enemy, " .. order .. " -> only the channel entry, hot twin gone",
                #Log(rig) == 1 and Log(rig)[1].kind == "channel" and #Log(rig, "player") == 0 and Casts(rig, 9030) == 1)
            rig = Rig()
            rig.Cast(0, 9007)
            rig.Channel(0, 9002, "nameplate1", reversed)
            Check("castlog: " .. order .. " -> another spell cast in the same frame is kept (twins match castID only)",
                #Log(rig) == 2 and Casts(rig, 9007) == 1 and Casts(rig, 9002) == 1)
        end

        -- lifecycle
        rig = Rig()
        rig.S.harmful[139], rig.S.helpful[139] = false, true
        rig.Cast(0, 9008)
        rig.Cast(1, 139, "party2")
        rig.Cast(2, 139, "player")
        rig.ns.Tracker.OnPlateRemoved(C_NamePlate.GetNamePlateForUnit("nameplate1"))
        Check("castlog: plate removal drops that plate's log only", #Log(rig) == 0 and #Log(rig, "party2") == 1)
        rig.ns.Core.GROUP_ROSTER_UPDATE()
        Check("castlog: a roster change drops party logs and keeps the player's",
            #Log(rig, "party2") == 0 and #Log(rig, "player") == 1)
        rig.ns.Tracker.Reset()
        Check("castlog: Tracker.Reset clears every log", #Log(rig, "player") == 0)
    end

    -- Retail safety checks -------------------------------------------------------------
    -- spec 11: the in-game Wither log (same data as the "Wither replay" block), fed in time order
    do
        local rig = Rig(true)
        rig.S.haste = 7.7259
        rig.Cast(0, 445474)
        Check("spec 11: 445474 (a tick icon, not a table key) alone gets no vote", rig.Votes(445474) == nil)
        rig.Cast(0, 445468)
        Check("spec 11: the Wither pair (445474 icon, then 445468 key) in one frame gets no vote",
            rig.Votes(445474) == nil and rig.Votes(445468) == nil)
        local hits = { { 0, 683, 36 }, { 0, 5490, 4 } }
        for _, tick in ipairs({ { 1.438, 1469 }, { 2.900, 1471 }, { 4.452, 1483 }, { 5.938, 1442 }, { 7.351, 1488 },
            { 8.911, 3403 }, { 10.382, 1496 }, { 11.885, 1509 } }) do hits[#hits + 1] = { tick[1], tick[2], 36 } end
        for _, t in ipairs({ 1.036, 1.968, 3.021, 3.990, 5.029, 7.029, 8.021, 9.045, 10.020, 11.025, 12.032 }) do
            hits[#hits + 1] = { t, 343, 106 }      -- the item proc series: same size, ~1 s apart
        end
        for index, hit in ipairs(hits) do hit.index = index end
        table.sort(hits, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a.index < b.index end)
        for _, hit in ipairs(hits) do rig.Hit(hit[1], hit[2], hit[3]) end
        Check("spec 11: Wither ticks still shown 7 of 8 (" .. rig.Drawn(445474) .. ")", rig.Drawn(445474) == 7)
        Check("spec 11: the school-106 item series teaches nothing (learned empty)",
            next(CombatTextIconsCharDB.learned) == nil)
    end

    -- spec 12: retail Agony ticking, then an unknown harmful cast on the same plate
    do
        local function Run(withUnknown)
            local rig = Rig(true)
            rig.Cast(0, 980)                          -- Agony, period 2.0 at haste 0
            for t = 2, 20, 2 do
                rig.Hit(t, 1000, 32)
                -- an unknown harmful cast on that plate
                if withUnknown and t == 2 then rig.Cast(3, 9013) end
            end
            return rig
        end
        local base = Run(false)
        local rig = Run(true)
        Check("spec 12: Agony ticks are unchanged by an unknown cast on the plate (" .. rig.Drawn(980) .. " vs " .. base.Drawn(980) .. ")",
            rig.Drawn(980) == base.Drawn(980) and rig.Drawn(980) == 10)
        Check("spec 12: nothing learned from Agony's ticks", next(CombatTextIconsCharDB.learned) == nil)
        Check("spec 12: Agony's ticks are not fed; the unknown cast is counted but gets no sig",
            #rig.Fed() == 0 and rig.Votes(9013).casts == 1 and #rig.Votes(9013).sigs == 0)
    end

    -- HoT cast log and learned HoT instances ----------------------------------------------
    do
        local RENEW, FLASH, HOLY = 139, 2061, 2
        local function Fresh()
            local ns, S = T.Boot(), T.State()
            for _, id in ipairs({ RENEW, FLASH }) do S.harmful[id], S.helpful[id] = false, true end
            return ns, S
        end
        local function Log(ns, key) return ns.Streams.CastLog(key) end
        local function Learned(ns, S)
            CombatTextIconsCharDB.learned[RENEW] = { school = HOLY, period = 3, kind = "hot", misses = 0 }
            ns.Learn.Init()
        end

        do -- heal unit
            local ns, S = Fresh()
            S.target = "party2"
            Check("hot: heal unit is the group target", ns.Tracker.HealUnit() == "party2")
            S.target = "nameplate1"
            Check("hot: hostile target -> player", ns.Tracker.HealUnit() == "player")
            S.target = nil
            Check("hot: no target -> player", ns.Tracker.HealUnit() == "player")
            local real = UnitIsUnit
            UnitIsUnit = function() return Secret(true) end
            Check("hot: secret UnitIsUnit -> player", ns.Tracker.HealUnit() == "player")
            UnitIsUnit = real
            S.target, S.attackable.raid7 = "raid7", false
            Check("hot: friendly target outside the party -> nil", ns.Tracker.HealUnit() == nil)
            S.attackable.raid7 = "error"
            Check("hot: UnitCanAttack error -> nil", ns.Tracker.HealUnit() == nil)
            S.attackable.raid7 = Secret(true)
            Check("hot: secret UnitCanAttack -> nil", ns.Tracker.HealUnit() == nil)
            local realExists = UnitExists
            UnitExists = function() return Secret(false) end
            Check("hot: secret UnitExists -> nil", ns.Tracker.HealUnit() == nil)
            UnitExists = realExists
        end

        do -- a friendly target outside the party: no log entry, no learned HoT instance
            local ns, S = Fresh()
            S.target, S.attackable.raid7 = "raid7", false
            ns.Tracker.OnCast("player", FLASH, 100)
            Check("hot: friendly raid target -> no cast-log entry", #ns.Streams.CastLog("player") == 0)
            Learned(ns, S)
            ns.Tracker.OnCast("player", RENEW, 200)
            Check("hot: friendly raid target -> no learned HoT instance",
                not ns.Tracker.QualifiesByPhase("player", HOLY, 800, "", 203.0))
        end

        do -- cast log
            local ns, S = Fresh()
            S.target = "party2"
            ns.Tracker.OnCast("player", RENEW, 100)
            Check("hot: Renew logs a hot entry on party2 only",
                #Log(ns, "party2") == 1 and Log(ns, "party2")[1].kind == "hot" and Log(ns, "party2")[1].castID == RENEW
                and #Log(ns, "party1") == 0 and #Log(ns, "player") == 0)
            ns, S = Fresh()
            ns.Tracker.OnCast("player", RENEW, 100)
            Check("hot: no group target -> logged on player", #Log(ns, "player") == 1)
            ns, S = Fresh()
            S.target = "party2"
            ns.Tracker.OnCast("pet", RENEW, 100)
            Check("hot: pet cast logs nothing", #Log(ns, "party2") == 0)
            S.harmful[RENEW] = true
            ns.Tracker.OnCast("player", RENEW, 110)
            Check("hot: a harmful spell logs no hot", #Log(ns, "party2") == 0)
            ns, S = Fresh()
            S.target = "party2"
            ns.Tracker.OnCast("player", RENEW, 100)
            ns.Tracker.OnCast("player", FLASH, 101)
            Check("hot: Flash Heal 1 s after Renew on the same unit -> 2 entries in cast order",
                #Log(ns, "party2") == 2 and Log(ns, "party2")[1].castID == RENEW and Log(ns, "party2")[2].castID == FLASH)
            ns, S = Fresh()
            C_Spell.IsSpellHelpful = nil
            S.target = "party2"
            Check("hot: missing IsSpellHelpful -> nothing logged, no error",
                pcall(ns.Tracker.OnCast, "player", RENEW, 100) and #Log(ns, "party2") == 0)
        end

        do -- known / learned casts are logged but cannot vote
            local ns, S = Fresh()
            Learned(ns, S)
            S.target = "party2"
            ns.Tracker.OnCast("player", FLASH, 100)
            ns.Tracker.OnCast("player", RENEW, 100) -- learned, same frame as an unknown one
            Check("hot: learned and unknown casts in one frame are both logged (unknown first)",
                #Log(ns, "party2") == 2 and ns.Learn.Votes(RENEW) == nil)
            ns.Tracker.Reset()
            ns.Tracker.OnCast("player", RENEW, 200)
            ns.Tracker.OnCast("player", FLASH, 200)
            Check("hot: learned and unknown casts in one frame are both logged (learned first)",
                #Log(ns, "party2") == 2 and ns.Learn.Votes(RENEW) == nil)
            ns.Tracker.Reset()
            ns.Tracker.OnCast("player", RENEW, 300)
            Check("hot: a learned cast is logged and gets no vote", #Log(ns, "party2") == 1 and ns.Learn.Votes(RENEW) == nil)
        end

        do -- learned HoT instance on the heal unit
            local ns, S = Fresh()
            Learned(ns, S)
            S.target = "party2"
            ns.Tracker.OnCast("player", RENEW, 300)
            local Q = ns.Tracker.QualifiesByPhase
            Check("hot: first tick at castAt + period on party2", Q("party2", HOLY, 800, "", 303.0) and not Q("party2", HOLY, 800, "", 301.5))
            Check("hot: not on another unit or school", not Q("party1", HOLY, 800, "", 303.0) and not Q("party2", 4, 800, "", 303.0))
            Check("hot: instance ticks identify with the learned icon", ns.Tracker.Identify("party2", HOLY, 800, "", 303.0) == RENEW)
            ns.Tracker.OnCast("player", RENEW, 304) -- recast keeps the instance, sets restartAt
            Check("hot: recast: kept phase fits", Q("party2", HOLY, 800, "", 306.0))
            Check("hot: recast: restart phase fits", Q("party2", HOLY, 800, "", 307.0))
            Check("hot: recast: off both phases does not", not Q("party2", HOLY, 800, "", 304.5))
            ns.Tracker.Reset()
            Check("hot: Reset clears HoT instances and the cast log", not Q("party2", HOLY, 800, "", 306.0) and #Log(ns, "party2") == 0)
        end

        do -- a HoT never counts misses
            local ns, S = Fresh()
            Learned(ns, S)
            S.target = "party2"
            ns.Tracker.OnCast("player", RENEW, 100)
            ns.Tracker.OnCast("player", RENEW, 120)
            ns.Tracker.QualifiesByPhase("party2", HOLY, 800, "", 140)
            Check("hot: learned HoT casts whose ticks never come are not misses", ns.Learn.Get(RENEW) ~= nil)
        end
    end

    -- Heal path ---------------------------------------------------------------------------
    do
        local RENEW, FLASH, HOLY, HEALING = 139, 2061, 2, 2
        local function Fresh(spells)
            local ns, S = T.Boot(nil, spells), T.State()
            for _, id in ipairs({ RENEW, FLASH }) do S.harmful[id], S.helpful[id] = false, true end
            local api = { ns = ns, S = S }
            ns.Display.Player = function(kind, texture, text) api.shown = { kind = kind, texture = texture, text = text } end
            function api.Cast(t, id, target)
                S.now, S.target = t, target
                ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-" .. t, id)
            end
            function api.Heal(t, unit, amount, read, school)
                S.now, S.pending, S.pendingTag = t, read or {}, "h" .. t
                api.shown = nil
                ns.Core.UNIT_COMBAT(unit, "HEAL", "", amount, school or HOLY)
                return api.shown
            end
            function api.Log(key) return ns.Streams.CastLog(key) end
            function api.Cycle(t, target, tickUnit, amounts, castID)  -- cast, then ticks 3 s apart
                api.Cast(t, castID or RENEW, target)
                local out = {}
                for k, amount in ipairs(amounts) do out[k] = api.Heal(t + 3 * k, tickUnit, amount) end
                return out
            end
            return api
        end
        local function Preload(api)
            CombatTextIconsCharDB.learned[RENEW] = { school = HOLY, period = 3, kind = "hot", misses = 0 }
            api.ns.Learn.Init()
        end

        do -- Renew on party2: logged there only; a learned Renew shows every tick of the next cast
            local api = Fresh()
            Preload(api)
            local third = api.Cycle(300, "party2", "party2", { 800, 800, 800 })
            Check("hot: Renew is logged on party2 only", #api.Log("party2") == 1 and #api.Log("party1") == 0 and #api.Log("player") == 0)
            Check("hot: third cast: every tick shown with the Renew icon, first included",
                third[1] and third[2] and third[3] and third[1].kind == "heal" and third[1].texture == "tex:" .. RENEW
                and third[3].texture == "tex:" .. RENEW)
        end

        do -- no group target: logged on player, player heals show every tick
            local api = Fresh()
            Preload(api)
            local ticks = api.Cycle(200, nil, "player", { 800, 800, 800 })
            Check("hot: no group target -> logged on player", #api.Log("player") == 1 and #api.Log("party2") == 0)
            Check("hot: player heals: every tick shown with the Renew icon, first included",
                ticks[1] and ticks[2] and ticks[3] and ticks[1].texture == "tex:" .. RENEW and ticks[3].texture == "tex:" .. RENEW)
        end

        do -- learned HoT tick sizes swing with overheal: a 0 or small first tick keeps the rest
            local api = Fresh()
            Preload(api)
            local ticks = api.Cycle(100, "party2", "party2", { 0, 800, 800 })
            Check("hot: ticks 0 / 800 / 800 -> both 800 ticks shown with the Renew icon", ticks[2] and ticks[3]
                and ticks[2].texture == "tex:" .. RENEW and ticks[3].texture == "tex:" .. RENEW)
            api = Fresh()
            Preload(api)
            ticks = api.Cycle(100, "party2", "party2", { 200, 800, 800 })
            Check("hot: ticks 200 / 800 / 800 -> both 800 ticks shown with the Renew icon", ticks[2] and ticks[3]
                and ticks[2].texture == "tex:" .. RENEW and ticks[3].texture == "tex:" .. RENEW)
        end

        do -- a roster change drops the unit's cast log and stream
            local api = Fresh()
            api.Cast(100, RENEW, "party2")
            for k = 1, 4 do api.Heal(100 + 3 * k, "party2", 800) end
            Check("hot: four unexplained heals after a cast form a stream on party2",
                #api.Log("party2") == 1 and #api.ns.Streams.Live("party2", api.S.now) == 1)
            api.ns.Core.GROUP_ROSTER_UPDATE()
            Check("hot: a roster change drops the party2 log and streams",
                #api.Log("party2") == 0 and #api.ns.Streams.Live("party2", api.S.now) == 0)
        end

        do -- no meter heal in the frame: the tick is shown (single mode, spec A)
            local api = Fresh()
            Preload(api)
            api.Cast(100, RENEW, "party2")
            local control = api.Heal(103.0, "party2", 800)
            Check("hot: control: the tick without a meter heal is shown", control and control.texture == "tex:" .. RENEW)
        end

        do -- roster change drops party logs and instances, keeps player
            local api = Fresh()
            Preload(api)
            api.Cast(100, RENEW, "party2")
            api.Cast(100.5, RENEW, nil)
            api.ns.Core.GROUP_ROSTER_UPDATE()
            Check("hot: roster change drops the party2 instance", api.Heal(103, "party2", 800) == nil)
            Check("hot: roster change keeps the player instance", (api.Heal(103.5, "player", 800) or {}).texture == "tex:" .. RENEW)
            api = Fresh()
            api.Cast(100, RENEW, "party2")
            api.Cast(101, FLASH, nil)
            api.ns.Core.GROUP_ROSTER_UPDATE()
            Check("hot: roster change drops the party2 log, keeps the player log", #api.Log("party2") == 0 and #api.Log("player") == 1)
            local source = assert(io.open(T.Root .. "/Core.lua", "rb")):read("a")
            Check("core: GROUP_ROSTER_UPDATE registered", source:find('RegisterEvent("GROUP_ROSTER_UPDATE")', 1, true) ~= nil)
        end

        do -- Review Focus 4: a fire-school heal during Rain of Fire is not the area
            local api = Fresh(true)
            api.Cast(100, 5740, "nameplate1")
            local plate = C_NamePlate.GetNamePlateForUnit("nameplate1")
            Check("hot: fire-school heal during Rain of Fire hidden", api.Heal(101, "player", 500, nil, 4) == nil
                and select(2, pcall(api.ns.Tracker.IdentifyHeal, "player", 4, 500, "", 101.5)) == nil)
            Check("hot: Rain of Fire still ticks on plates", api.ns.Tracker.Identify(plate, 4, 900, "", 102) == 42223)
            Check("hot: secret heal values give nil without error",
                select(2, pcall(api.ns.Tracker.IdentifyHeal, "party2", Secret(2), Secret(5), Secret(""), 103)) == nil)
            Check("core: Core.Heal exported", type(api.ns.Core.Heal) == "function")
        end
    end

    -- Burst merge, UNKNOWN and the question mark (Task 3.2) ---------------------------------
    local function ApplyDot(rig, t0, plate, ids, period, ticks)
        for _, id in ipairs(ids) do rig.Cast(t0, id, plate) end
        for k = 1, ticks do rig.Hit(t0 + period * k, 1000, 32, plate) end
    end
    local function EqualTextures(twin, of) -- spell `twin` shows `of`'s texture
        local texture = C_Spell.GetSpellTexture
        C_Spell.GetSpellTexture = function(id) return texture(id == twin and of or id) end
    end
    local function Count(rig, texture)
        local n = 0
        for _, icon in ipairs(rig.icons) do if icon == texture then n = n + 1 end end
        return n
    end

    for _, equal in ipairs({ false, true }) do -- tie: 2 unknown spells always cast together
        local rig = Rig()
        rig.S.group = true -- in a group unidentified ticks stay hidden, so only the tracker's "?" is counted
        if equal then EqualTextures(9402, 9401) end
        for plate = 1, 4 do ApplyDot(rig, 20 * (plate - 1), "nameplate" .. plate, { 9401, 9402 }, 3, 4) end
        local label = equal and "equal textures" or "differing textures"
        Check("tie (" .. label .. "): both spells learned after 4 applications", rig.Learned(9401) and rig.Learned(9402))
        local before = Count(rig, rig.ns.Meter.UNKNOWN_ICON)
        rig.S.group = false -- single mode (spec A): solo, the tracker's UNKNOWN draws '?'
        ApplyDot(rig, 80, "nameplate5", { 9401, 9402 }, 3, 4)      -- 5th application: one instance per burst
        if equal then
            Check("tie (equal textures): one instance ticks 4/4 with that icon (" .. rig.Drawn(9401) .. ")", rig.Drawn(9401) == 4)
        else
            Check("tie (differing textures): 4/4 ticks drawn as UNKNOWN, none as an own icon",
                Count(rig, rig.ns.Meter.UNKNOWN_ICON) - before == 4 and rig.Drawn(9401) == 0 and rig.Drawn(9402) == 0)
        end
    end
    for _, gap in ipairs({ 0.017, 0.2 }) do -- burst straddle and its control
        local rig = Rig()
        EqualTextures(9402, 9401)
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 3, "dot")
        rig.Cast(100, 9401); rig.Cast(100 + gap, 9402)
        for k = 1, 4 do rig.Hit(100 + 3 * k + gap / 2, 1000, 32) end
        if gap < 0.1 then
            Check("burst: casts 17 ms apart merge into one instance (4/4 ticks, " .. rig.Drawn(9401) .. ")", rig.Drawn(9401) == 4)
        else
            Check("burst: casts 0.2 s apart do not merge (two instances, none ticked, " .. rig.Drawn(9401) .. " < 4)", rig.Drawn(9401) < 4)
        end
    end
    do -- a merged instance's tickless first tick is a miss for both spells; a tick resets both
        local rig = Rig()
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 3, "dot")
        local P = C_NamePlate.GetNamePlateForUnit("nameplate1")
        for _, start in ipairs({ 0, 20 }) do rig.Cast(start, 9401); rig.Cast(start, 9402) end
        rig.ns.Tracker.QualifiesByPhase(P, 32, 1000, "", 40)
        Check("burst: two tickless merged casts remove both spells", not rig.Learned(9401) and not rig.Learned(9402))
        rig = Rig()
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 3, "dot")
        for _, start in ipairs({ 0, 20 }) do rig.Cast(start, 9401); rig.Cast(start, 9402) end
        rig.Hit(23, 1000, 32)
        Check("burst: a first tick resets the miss count of both spells",
            rig.Learned(9401).misses == 0 and rig.Learned(9402).misses == 0)
    end
    do -- a recast of either burst spell finds the shared instance: no second instance, no miss
        local rig = Rig()
        EqualTextures(9402, 9401)
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 3, "dot")
        local P = C_NamePlate.GetNamePlateForUnit("nameplate1")
        rig.Cast(100, 9401); rig.Cast(100, 9402)
        rig.Hit(103, 1000, 32)
        rig.Cast(110, 9402)
        rig.ns.Tracker.QualifiesByPhase(P, 32, 1000, "", 130)
        Check("burst: recasting the second spell refreshes the shared instance (no miss for it)",
            rig.Learned(9402).misses == 0 and rig.Learned(9401).misses == 0)
    end
    do -- casts in one burst join only when school and base period agree
        local rig = Rig()
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 4, 3, "dot")
        rig.Cast(100, 9401); rig.Cast(100.02, 9402)
        rig.Hit(103, 1000, 4)
        Check("burst: another school does not merge (the school-4 tick is its own)", rig.Drawn(9402) == 1)
        rig = Rig()
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 6, "dot")
        rig.Cast(100, 9401); rig.Cast(100.02, 9402)
        rig.Hit(106, 1000, 32)
        Check("burst: a base period 2x apart does not merge (the 6 s tick is its own)", rig.Drawn(9402) == 1)
        rig = Rig()
        rig.Seed(9501, 32, 3, "channel"); rig.Seed(9402, 32, 3, "dot")
        rig.Channel(100, 9501); rig.Cast(100.02, 9402); rig.Stop(101)
        rig.Hit(103, 1000, 32)
        Check("burst: a DoT cast with a channel start does not merge into the channel", rig.Drawn(9402) == 1)
    end
    do -- a secret texture counts as "differs"
        local rig = Rig()
        local texture = C_Spell.GetSpellTexture
        C_Spell.GetSpellTexture = function(id) if id == 9402 then return Secret("tex") end return texture(id) end
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 3, "dot")
        rig.Cast(100, 9401); rig.Cast(100.5, 9402)
        local P = C_NamePlate.GetNamePlateForUnit("nameplate1")
        Check("unknown: a secret texture differs -> UNKNOWN, no error",
            rig.ns.Tracker.UNKNOWN ~= nil and rig.ns.Tracker.Identify(P, 32, 1000, "", 103.2) == rig.ns.Tracker.UNKNOWN)
    end
    do -- two secret textures cannot be compared: UNKNOWN, no error
        local rig = Rig()
        C_Spell.GetSpellTexture = function() return Secret("tex") end
        rig.Seed(9401, 32, 3, "dot"); rig.Seed(9402, 32, 3, "dot")
        rig.Cast(100, 9401); rig.Cast(100.5, 9402)
        local P = C_NamePlate.GetNamePlateForUnit("nameplate1")
        local ok, answer = pcall(rig.ns.Tracker.Identify, P, 32, 1000, "", 103.2)
        Check("unknown: two secret textures -> UNKNOWN, no error", ok and answer == rig.ns.Tracker.UNKNOWN)
    end
    do -- two learned HoTs both due: the player column draws the question mark
        local rig = Rig()
        for _, id in ipairs({ 139, 2061 }) do rig.S.harmful[id], rig.S.helpful[id] = false, true end
        rig.Seed(139, 2, 3, "hot"); rig.Seed(2061, 2, 3, "hot")
        local drawn
        rig.ns.Display.Player = function(_, texture) drawn = texture end
        rig.Cast(100, 139, "party2"); rig.Cast(100.5, 2061, "party2")
        rig.S.now, rig.S.pending = 103.2, {}
        rig.ns.Core.UNIT_COMBAT("party2", "HEAL", "", 800, 2)
        Check("heal: two learned HoTs fit -> UNKNOWN_ICON", drawn ~= nil and drawn == rig.ns.Meter.UNKNOWN_ICON)
    end

    -- Adoption and OnLearned (Task 3.3)
    local function AdoptionRig() -- unknown twins 9101 / 9102 (school 12, period 1.7) form a stream, then both become learned
        local rig = Rig()
        EqualTextures(9102, 9101)
        rig.Cast(0, 9101, "nameplate1"); rig.Cast(0, 9102, "nameplate1")
        for _, t in ipairs({ 1.7, 3.4, 5.1 }) do rig.Hit(t, 1000, 12) end      -- stream, owners { 9101, 9102 }
        rig.Seed(9101, 12, 1.7, "dot"); rig.Seed(9102, 12, 1.7, "dot")          -- learned after the fact: no instance yet
        rig.Hit(6.8, 1000, 12)                                                   -- hidden, extends the stream (lastAt 6.8)
        return rig
    end
    do -- adoption: a recast mid-stream keeps the stream's phase (Review Focus 2)
        local rig = AdoptionRig()
        rig.Cast(8.0, 9101); rig.Cast(8.3, 9102)                 -- the first adopts the stream, the twin joins it
        for _, t in ipairs({ 8.5, 10.2, 11.9 }) do rig.Hit(t, 1000, 12) end
        rig.Cast(12.5, 9101); rig.Cast(12.5, 9102)               -- recast again: no second instance
        for _, t in ipairs({ 13.6, 15.3, 17.0 }) do rig.Hit(t, 1000, 12) end
        Check("adoption: next tick at the stream's phase (8.5) and 6/6 ticks, one instance (" .. rig.Drawn(9101) .. ")",
            rig.Drawn(9101) == 6)
        rig = AdoptionRig()
        rig.Cast(8.0, 9101)                                      -- adopted, then the target dies: no tick ever comes
        rig.ns.Tracker.QualifiesByPhase(C_NamePlate.GetNamePlateForUnit("nameplate1"), 12, 1000, "", 60)
        Check("adoption: an adopted instance that never ticks again is not a miss",
            rig.Learned(9101) and rig.Learned(9101).misses == 0)
    end
    do -- an adopted cast that ticks resets the miss count, like a plain cast that ticks
        local rig = Rig()
        local P = C_NamePlate.GetNamePlateForUnit("nameplate1")
        rig.Cast(0, 9101)
        for _, t in ipairs({ 1.7, 3.4, 5.1 }) do rig.Hit(t, 1000, 12) end   -- stream on nameplate1, owner 9101
        rig.Seed(9101, 12, 1.7, "dot")
        rig.Cast(6.0, 9101, "nameplate2")                                    -- never ticks: miss 1
        rig.Hit(6.8, 1000, 12); rig.Hit(8.5, 1000, 12)
        rig.ns.Tracker.QualifiesByPhase(P, 12, 1000, "", 9.5)
        local missedOnce = rig.Learned(9101) ~= nil and rig.Learned(9101).misses == 1
        rig.Hit(10.2, 1000, 12)
        rig.Cast(10.5, 9101)                                                 -- adopts the nameplate1 stream
        for _, t in ipairs({ 11.9, 13.6, 15.3 }) do rig.Hit(t, 1000, 12) end
        Check("adoption: an adopted cast's first tick resets the miss count",
            missedOnce and rig.Drawn(9101) == 3 and rig.Learned(9101) ~= nil and rig.Learned(9101).misses == 0)
        rig.Cast(20, 9101, "nameplate3")                                     -- tickless again
        rig.ns.Tracker.QualifiesByPhase(P, 12, 1000, "", 30)
        Check("adoption: miss, adopted ticking cast, miss keeps the learned spell", rig.Learned(9101) ~= nil)

        rig = AdoptionRig()
        rig.Cast(8.0, 9101)                                                  -- adopts the stream
        rig.Hit(8.5, 1000, 12)
        rig.Learned(9102).misses = 1
        rig.Cast(9.0, 9102)                                                  -- the twin joins the ticking instance
        rig.Hit(10.2, 1000, 12)
        Check("adoption: a spell joining a ticking adopted instance has its miss count reset by the next tick",
            rig.Drawn(9101) == 2 and rig.Learned(9102).misses == 0)
    end
    do -- OnLearned: three applications on three plates, learned at the 3rd birth; every live stream gets an instance
        local rig = Rig()
        EqualTextures(9102, 9101)
        local hits = {}
        for plate = 1, 3 do
            local cast = 0.5 * (plate - 1)
            rig.Cast(cast, 9101, "nameplate" .. plate); rig.Cast(cast, 9102, "nameplate" .. plate)
            for k = 1, 8 do hits[#hits + 1] = { t = cast + 1.7 * k, plate = "nameplate" .. plate } end
        end
        table.sort(hits, function(a, b) return a.t < b.t end)
        for index, hit in ipairs(hits) do
            rig.Hit(hit.t, 1000, 12, hit.plate)
            if index == 11 then Check("onlearned: not learned after 2 births (7.3)", rig.Learned(9101) == nil) end
        end
        Check("onlearned: learned at the 3rd birth (7.8)", rig.Learned(9101) and rig.Learned(9102))
        Check("onlearned: the next 4 ticks on each of the 3 plates are shown, one instance per stream ("
            .. rig.Drawn(9101) .. "/12)", rig.Drawn(9101) == 12)
    end
    do -- OnLearned takes only streams the spell owns
        local rig = Rig()
        rig.Cast(0, 9501, "nameplate1")
        for _, t in ipairs({ 1.7, 3.4, 5.1, 6.8 }) do rig.Hit(t, 1000, 12) end
        rig.Seed(9502, 12, 1.7, "dot")                           -- learned, but not an owner of the stream
        rig.ns.Tracker.OnLearned(9502, 6.9)
        rig.S.group = true -- in a group a hit nothing identifies stays hidden (solo it draws "?")
        Check("onlearned: a non-owner gets no instance (8.5 stays hidden)", rig.Hit(8.5, 1000, 12) == nil)
        rig.S.group = false
        rig.Seed(9501, 12, 1.7, "dot")
        rig.ns.Tracker.OnLearned(9501, 8.6)
        Check("onlearned: the owner's next tick (10.2) is shown", rig.Hit(10.2, 1000, 12) == "tex:9501")
    end
    do -- OnLearned adopts only a stream that matches the spell: school, period, and not a channel
        for _, case in ipairs({ { "school", 32, 1.7, "dot", 32 }, { "period", 12, 4.0, "dot", 12 }, { "channel", 12, 1.7, "channel", 12 } }) do
            local rig = Rig()
            rig.Cast(0, 9501, "nameplate1")
            for _, t in ipairs({ 1.7, 3.4, 5.1, 6.8 }) do rig.Hit(t, 1000, 12) end
            rig.Seed(9501, case[2], case[3], case[4])
            rig.ns.Tracker.OnLearned(9501, 6.9)
            rig.S.group = true -- in a group a hit nothing identifies stays hidden (solo it draws "?")
            Check("onlearned: a stream that differs in " .. case[1] .. " is not adopted", rig.Hit(8.5, 1000, case[5]) == nil)
        end
    end
    do -- OnLearned on a heal unit: a Renew-like HoT (school 2, period 2.5) on party2
        local rig = Rig()
        rig.S.harmful[9701], rig.S.helpful[9701] = false, true
        local shown
        rig.ns.Display.Player = function(_, texture) shown = texture end
        local function Heal(t) rig.S.now, rig.S.pending, shown = t, {}, nil; rig.ns.Core.UNIT_COMBAT("party2", "HEAL", "", 800, 2); return shown end
        rig.Cast(0, 9701, "party2")
        Heal(2.5); Heal(5.0); Heal(7.5); Heal(10.0)              -- the fourth heal creates the stream on "party2"
        rig.Seed(9701, 2, 2.5, "hot")
        rig.ns.Tracker.OnLearned(9701, 10.1)
        Check("onlearned: HoT stream on party2 -> the next heal (12.5) is shown", Heal(12.5) == "tex:9701")
    end
    do -- spec 1/2 replacement, the shown part: unknown school-32 DoT (period 3), learned after 4 fresh plates
        local rig = Rig()
        for plate = 1, 4 do ApplyDot(rig, 20 * (plate - 1), "nameplate" .. plate, { 9001 }, 3, 4) end
        Check("spec 1/2: learned after the 4th plate (expected 0.7, p 0.006)", rig.Learned(9001) ~= nil)
        ApplyDot(rig, 80, "nameplate5", { 9001 }, 3, 3)
        Check("spec 1/2: the next cast shows all 3 ticks with its icon (" .. rig.Drawn(9001) .. "/3)", rig.Drawn(9001) == 3)
    end
    do -- spec 5 flips: SW:P (9201) at t0 and DP (9202) at t0 + 1.7, both school 32, period 3, a fresh plate per round
        local rig = Rig()
        local swRound, dpRound, before
        for round = 1, 10 do
            local t0, plate = 20 * (round - 1), "nameplate" .. round
            before = { rig.Drawn(9201), rig.Drawn(9202) }
            rig.Cast(t0, 9201, plate); rig.Cast(t0 + 1.7, 9202, plate)
            local hits = {}
            for k = 1, 4 do
                hits[#hits + 1] = t0 + 3 * k
                hits[#hits + 1] = t0 + 1.7 + 3 * k
            end
            table.sort(hits)
            for _, t in ipairs(hits) do rig.Hit(t, 1000, 32, plate) end
            if not swRound and rig.Learned(9201) then swRound = round end
            if not dpRound and rig.Learned(9202) then dpRound = round end
            if round == 9 or round == 10 then
                Check("spec 5: round " .. round .. " shows 4/4 ticks of each, own icons",
                    rig.Drawn(9201) - before[1] == 4 and rig.Drawn(9202) - before[2] == 4)
            end
        end
        Check("spec 5: SW:P learned in round 7, DP in round 8 (" .. tostring(swRound) .. ", " .. tostring(dpRound) .. ")",
            swRound == 7 and dpRound == 8)
        Check("spec 5: both bases are 3", math.abs(rig.Learned(9201).period - 3) < 0.05 and math.abs(rig.Learned(9202).period - 3) < 0.05)
    end
end
