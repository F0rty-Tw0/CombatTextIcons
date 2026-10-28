-- Unit checks for the learned panel: the Ledger (drawn totals per fight, the 5 saved fights, verdicts,
-- load validation), its wiring into Core and Teacher, and the panel's row builder. Called by tests/checks.lua
-- with the same T table. Every scenario boots its own rig; a Boot replaces the global stubs.

return function(T)
    local Check, Secret = T.Check, T.Secret

    -- A booted addon with the Ledger initialised on the character table. Returns Ledger and the stub state.
    local function Rig()
        local ns = T.Boot()
        ns.Ledger.Init(T.Store())

        return ns.Ledger, T.State()
    end

    -- A scenario that errors fails one named check instead of ending the file.
    local function Scenario(name, run)
        local ok, err = pcall(run)
        if not ok then Check("ledger: " .. name .. " ran without error: " .. tostring(err), false) end
    end

    local function Count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

    -- Row lookups: the first row with `key` (in `section`), how many rows carry `key`, and its position.
    local function FindIn(rows, section, key)
        for _, row in ipairs(rows) do
            if row.key == key and (section == nil or row.section == section) then return row end
        end

        return nil
    end
    local function Find(rows, key) return FindIn(rows, nil, key) end
    local function CountKey(rows, key)
        local n = 0
        for _, row in ipairs(rows) do
            if row.key == key then n = n + 1 end
        end

        return n
    end
    local function IndexOf(rows, key)
        for index, row in ipairs(rows) do
            if row.key == key then return index end
        end

        return nil
    end

    -- One valid saved fight; `extra` fields are copied over it.
    local function Saved(at, extra)
        local fight = { at = at, date = 1000, duration = 5, group = false,
            damage = { [591] = { amount = 10, hits = 1 } }, heal = {} }
        for key, value in pairs(extra or {}) do fight[key] = value end

        return fight
    end

    -- Ledger ----------------------------------------------------------------------------
    Scenario("save and totals", function()
        local L, S = Rig()
        S.now = 1234.7
        L.Start(10, false)
        L.Add("damage", 188196, 100)
        L.Add("damage", 188196, 50)
        L.Add("heal", 774, 30)
        L.Finish(14)
        local f = L.Fights()[1]
        Check("ledger: fight saved newest first", f ~= nil and f.at == 10 and f.duration == 4
            and f.meter == nil and f.group == false)
        Check("ledger: date comes from time()", f ~= nil and f.date == 1234)
        Check("ledger: totals per key", f ~= nil and f.damage[188196].amount == 150
            and f.damage[188196].hits == 2 and f.heal[774].amount == 30 and f.heal[774].hits == 1)
        Check("ledger: Current() is nil after Finish", L.Current() == nil)
    end)

    Scenario("cap and empty fight", function()
        local L = Rig()
        for index = 1, 6 do
            L.Start(index * 10, true)
            L.Add("damage", 591, 1)
            L.Finish(index * 10 + 1)
        end
        Check("ledger: cap 5", #L.Fights() == 5 and L.Fights()[1].at == 60 and L.Fights()[5].at == 20)
        Check("ledger: group flag kept", L.Fights()[1].group == true)
        L.Start(70, false)
        L.Finish(71)
        Check("ledger: empty fight not saved", #L.Fights() == 5 and L.Fights()[1].at == 60)
        Check("ledger: empty fight closes", L.Current() == nil)
    end)

    Scenario("secret values", function()
        local L = Rig()
        L.Start(80, false)
        L.Add("damage", 591, Secret(9))
        L.Add("damage", Secret(1), 5)
        L.Add("heal", "?", Secret(3))
        Check("ledger: secret key ignored", Count(L.Current().damage) == 1)
        L.Finish(81)
        local f = L.Fights()[1]
        Check("ledger: secret amount counts hit", f.damage[591].hits == 1 and f.damage[591].amount == 0)
        Check("ledger: secret school key ? kept", f.heal["?"].hits == 1 and f.heal["?"].amount == 0)
    end)

    Scenario("no open fight, restart, bad side", function()
        local L = Rig()
        L.Add("damage", 591, 5)
        L.Finish(3)
        Check("ledger: Add and Finish with no open fight ignored", L.Current() == nil and #L.Fights() == 0)
        L.Start(1, false)
        L.Add("damage", 1, 5)
        L.Start(2, false)
        L.Add("damage", 2, 7)
        L.Add("taken", 3, 7)
        L.Finish(3)
        local f = L.Fights()[1]
        Check("ledger: Start over an open fight discards it", #L.Fights() == 1 and f.at == 2
            and f.damage[1] == nil and f.damage[2].amount == 7)
        Check("ledger: unknown side ignored", f.damage[3] == nil and f.heal[3] == nil)
    end)

    Scenario("verdicts", function()
        local L = Rig()
        local function Result(spellID, verdict, meter) return { spellID = spellID, meterID = spellID, tally = 1, meter = meter, verdict = verdict } end
        L.Start(10, false)
        L.Add("damage", 591, 100)
        L.Finish(12)
        L.SetVerdicts({ Result(591, "unpaired", 0), Result(591, "agree", 100), Result(591, "over", 50), Result(8092, "under", 30) }, 99)
        Check("ledger: verdicts ignored on an at mismatch", L.Fights()[1].verdicts == nil)
        L.SetVerdicts({ Result(591, "unpaired", 0), Result(591, "agree", 100), Result(591, "over", 50), Result(8092, "under", 30) }, 10)
        local v = L.Fights()[1].verdicts
        Check("ledger: verdict attached by at", v ~= nil and v[8092].verdict == "under" and v[8092].meter == 30 and v[8092].meterID == 8092)
        Check("ledger: first non-unpaired verdict wins a shared spell", v ~= nil and v[591].verdict == "agree" and v[591].meter == 100)
        L.SetVerdicts({ Result(1, "over", 1) }, 10)
        Check("ledger: second read does not overwrite", L.Fights()[1].verdicts[1] == nil and L.Fights()[1].verdicts[591].verdict == "agree")

        L.Start(20, false)
        L.Add("damage", 591, 100)
        L.Finish(22)
        L.SetVerdicts({ Result(591, "unpaired", 0), Result(591, "unpaired", 7) }, 20)
        Check("ledger: all unpaired keeps the first", L.Fights()[1].verdicts[591].meter == 0)

        L.Start(40, false)
        L.Add("damage", 591, 100)
        L.Finish(42)
        L.SetVerdicts({ Result(Secret(1), "agree", 100), Result(591, "maybe", 100), Result(592, "agree", Secret(2)) }, 40)
        Check("ledger: bad result rows dropped", L.Fights()[1].verdicts == nil)
    end)

    Scenario("forget", function()
        local L = Rig()
        L.Start(10, false)
        L.Add("damage", 591, 5)
        L.Finish(11)
        L.Start(20, false)
        L.Add("damage", 592, 5)
        local live = L.Current()
        L.Forget()
        Check("ledger: Forget clears the saved table in place", L.Fights() == T.Store().fights
            and next(T.Store().fights) == nil)
        Check("ledger: Forget keeps the open fight", L.Current() == live and live.damage[592].hits == 1)
        L.Finish(21)
        Check("ledger: a fight saved after Forget lands in the same table", T.Store().fights[1] ~= nil
            and T.Store().fights[1].at == 20)
    end)

    Scenario("init validation", function()
        local ns = T.Boot()
        local fights = {
            Saved(60),
            "junk",
            Saved("x"),
            Saved(50, { group = "no" }),
            Saved(40, { damage = "bad" }),
            Saved(30, { extra = true, damage = {
                [591] = { amount = 10, hits = 2, unknown = 1 },
                [592] = { amount = -1, hits = 1 },
                [593] = { amount = 1, hits = 0 },
                [594] = { amount = 1, hits = 1.5 },
                ["meter"] = { amount = 4, hits = 1 },
                ["toolongkey"] = { amount = 1, hits = 1 },
                [true] = { amount = 1, hits = 1 },
                [595] = "x",
            }, verdicts = {
                [591] = { meter = 9, meterID = 591, verdict = "agree", extra = 1 },
                [592] = { meter = 9, meterID = 592, verdict = "maybe" },
                [593] = { meter = "9", meterID = 593, verdict = "agree" },
                ["x"] = { meter = 9, meterID = 1, verdict = "agree" },
            } }),
            Saved(20),
            Saved(10),
            Saved(5),
        }
        T.Store().fights = fights
        ns.Ledger.Init(T.Store())
        local kept = ns.Ledger.Fights()
        Check("ledger: Init prunes in place", kept == fights and T.Store().fights == fights)
        Check("ledger: Init drops junk fights and caps at 5", #kept == 5 and kept[1].at == 60 and kept[2].at == 30
            and kept[3].at == 20 and kept[4].at == 10 and kept[5].at == 5)
        local f = kept[2]
        Check("ledger: Init drops unknown fight fields", f.extra == nil and Count(f) == 7)
        Check("ledger: Init keeps valid totals, drops bad ones", f.damage[591].amount == 10 and f.damage[591].hits == 2
            and f.damage[591].unknown == nil and f.damage[592] == nil and f.damage[593] == nil and f.damage[594] == nil
            and f.damage.meter == nil and f.damage.toolongkey == nil and f.damage[true] == nil and f.damage[595] == nil)
        Check("ledger: Init keeps valid verdicts, drops bad ones", f.verdicts[591].verdict == "agree" and f.verdicts[591].extra == nil
            and f.verdicts[592] == nil and f.verdicts[593] == nil and f.verdicts.x == nil)
        Check("ledger: Init leaves Current() empty", ns.Ledger.Current() == nil)

        T.Store().fights = "x"
        ns.Ledger.Init(T.Store())
        Check("ledger: Init replaces a non-table fights", type(T.Store().fights) == "table"
            and ns.Ledger.Fights() == T.Store().fights and #ns.Ledger.Fights() == 0)
    end)

    Scenario("single mode: Start(now, grouped) and old meter fights", function()
        local L = Rig()
        L.Start(5, true)
        Check("ledger: Start(now, grouped)", L.Current().group == true and L.Current().meter == nil)

        local ns = T.Boot(function()
            CombatTextIconsCharDB = { fights = { Saved(7, { meter = true, group = true,
                damage = { meter = { amount = 400, hits = 4 }, [591] = { amount = 100, hits = 1 } } }) } }
        end)
        local f = ns.Ledger.Fights()[1]
        Check("migration: old fight loads without meter field or meter total",
            f ~= nil and f.meter == nil and f.damage.meter == nil and f.damage[591].amount == 100 and f.group == true)
    end)

    -- Ledger wiring ---------------------------------------------------------------------
    local SMITE, DRAIN_LIFE = 591, 234153

    local function Row(spellID, total)
        return { spellID = spellID, totalAmount = total, overkillAmount = 0, amountPerSecond = 0,
            combatSpellDetails = {}, creatureName = "", isAvoidable = false, isDeadly = false }
    end

    -- A booted addon with the real Core routes and Display stubbed to count what is drawn.
    -- `learned` = { [spellID] = school } gets a learned fingerprint each; `spells` loads the fixture table as ns.Spells.
    local function Wired(learned, spells)
        local rig = { drawn = 0 }
        rig.ns = T.Boot(nil, spells)
        rig.S = T.State()
        rig.L = rig.ns.Ledger
        rig.Core = rig.ns.Core
        rig.ns.Teacher.area = "clear"
        rig.ns.Display.Plate = function() rig.drawn = rig.drawn + 1 end
        rig.ns.Display.Player = function() rig.drawn = rig.drawn + 1 end
        for spellID, school in pairs(learned or {}) do
            for castAt = 1, 3 do
                rig.ns.Fingerprints.Add(spellID, { school = school, delay = 0.25, castAt = castAt, hops = 1 })
            end
        end
        -- One UNIT_COMBAT at t (area clear), so an unexplained solo hit counts as '?'.
        function rig.Event(t, unit, event, amount, school)
            rig.S.now = t
            rig.Core.UNIT_COMBAT(unit, event, "", amount, school)
        end
        function rig.Cast(t, unit, spellID)
            rig.S.now, rig.S.target = t, unit
            rig.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c" .. t, spellID)
        end
        function rig.Combat(t)
            rig.S.now = t
            rig.Core.PLAYER_REGEN_DISABLED()
        end
        function rig.EndCombat(t)
            rig.S.now = t
            rig.Core.PLAYER_REGEN_ENABLED()
        end
        -- The open fight's total for a side and key, or nil.
        function rig.Total(side, key)
            local fight = rig.L.Current()

            return fight and fight[side][key]
        end
        -- The open fight's keys of a side, sorted and comma-joined.
        function rig.Keys(side)
            local fight = rig.L.Current()
            local keys = {}
            for key in pairs(fight and fight[side] or {}) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)

            return table.concat(keys, ",")
        end
        -- Fires the oldest queued C_Timer.After callback.
        function rig.Fire()
            local timer = table.remove(rig.S.timers, 1)
            if timer then timer.fn() end
        end

        return rig
    end

    Scenario("wiring tracker key is the tick icon", function()
        local rig = Wired(nil, true)
        rig.Combat(0)
        rig.Cast(0, "nameplate1", 172) -- Corruption draws its tick icon 146739
        rig.Event(2, "nameplate1", "WOUND", 1000, 32)
        local tick = rig.Total("damage", 146739)
        Check("ledger wiring: Corruption tick lands under 146739, not 172",
            tick ~= nil and tick.hits == 1 and tick.amount == 1000 and rig.Total("damage", 172) == nil and rig.drawn == 1)
    end)

    Scenario("wiring unknown-solo keys", function()
        local rig = Wired()
        rig.Combat(10)
        rig.S.target = "nameplate1"
        rig.Event(11, "nameplate1", "WOUND", 100, 8.0) -- float school: "?8", never "?8.0"
        rig.Event(12, "nameplate1", "WOUND", 100, Secret(8))
        local eight, secret = rig.Total("damage", "?8"), rig.Total("damage", "?")
        Check("ledger wiring: unknown-solo school 8 lands under ?8",
            eight ~= nil and eight.hits == 1 and eight.amount == 100)
        Check("ledger wiring: unknown-solo secret school lands under ?", secret ~= nil and secret.hits == 1
            and rig.Keys("damage") == "?,?8" and rig.drawn == 2)
    end)

    Scenario("wiring keys", function()
        local rig = Wired({ [SMITE] = 2 }, true)
        rig.Combat(9)
        Check("ledger wiring: fight opens with the group flag and no meter field", rig.L.Current() ~= nil
            and rig.L.Current().meter == nil and rig.L.Current().group == false)
        rig.Cast(10, "nameplate7", SMITE)
        rig.Event(10.25, "nameplate7", "WOUND", 53, 2)
        local smite = rig.Total("damage", SMITE)
        Check("ledger wiring: learned fingerprint hit lands under its spell ID",
            smite ~= nil and smite.hits == 1 and smite.amount == 53)
        rig.Event(30, "nameplate3", "WOUND", 77, 8)
        rig.Event(31, "nameplate3", "WOUND", 78, Secret(8))
        Check("ledger wiring: unknown-solo lands under ?8 and ? (secret)",
            rig.Total("damage", "?8") ~= nil and rig.Total("damage", "?8").hits == 1
            and rig.Total("damage", "?8").amount == 77 and rig.Total("damage", "?") ~= nil
            and rig.Total("damage", "?").hits == 1 and rig.drawn == 3)
        rig.Cast(40, "nameplate1", 172)
        rig.Event(42, "nameplate1", "WOUND", 900, 32)
        Check("ledger wiring: tracker tick lands under the tick icon",
            rig.Total("damage", 146739) ~= nil and rig.Total("damage", 172) == nil)
    end)

    Scenario("wiring heal routes", function()
        local rig = Wired(nil, true)
        rig.Combat(80)
        rig.Cast(90, "nameplate5", DRAIN_LIFE)
        rig.Core.UNIT_SPELLCAST_CHANNEL_START("player", "Cast-4", DRAIN_LIFE)
        rig.Event(90.4, "nameplate5", "WOUND", 1178, 32)
        rig.Event(90.4, "player", "HEAL", 8246, 1)
        local heal = rig.Total("heal", DRAIN_LIFE)
        Check("ledger wiring: Drain Life channel heal lands under heal 234153",
            heal ~= nil and heal.hits == 1 and heal.amount == 8246)
        Check("ledger wiring: Drain Life tick lands under damage 234153",
            rig.Total("damage", DRAIN_LIFE) ~= nil and rig.Total("damage", DRAIN_LIFE).amount == 1178)
        rig.Event(95, "player", "HEAL", 100, 1) -- nothing names it: while the area is clear it draws '?' and is recorded
        Check("ledger wiring: an unnamed heal while clear is recorded under ?1", rig.Keys("heal") == "234153,?1")
    end)

    Scenario("wiring fight saved with the group flag, the Teacher read queued", function()
        local rig = Wired(nil, true)
        local S = rig.S
        S.group = true
        rig.Combat(100)
        rig.Cast(100, "nameplate1", 172) -- Corruption: a tick draws in a group too
        rig.Event(102, "nameplate1", "WOUND", 500, 32)
        rig.EndCombat(110)
        local fight = rig.L.Fights()[1]
        Check("ledger wiring: fight saved with group true and no meter field", fight ~= nil and fight.at == 100
            and fight.meter == nil and fight.group == true and fight.duration == 10 and fight.damage[146739].hits == 1)
        Check("ledger wiring: the open fight closes at combat end", rig.L.Current() == nil)
        Check("ledger wiring: the Teacher read of every fight is queued", #S.timers == 1 and rig.ns.Teacher.fight == nil)
    end)

    Scenario("wiring verdicts attach to the fight", function()
        local rig = Wired({ [SMITE] = 2 })
        rig.Combat(9)
        rig.Cast(10, "nameplate7", SMITE)
        rig.Event(10.25, "nameplate7", "WOUND", 53, 2)
        rig.EndCombat(130)
        Check("ledger wiring: fight saved at its start time", rig.L.Fights()[1] ~= nil
            and rig.L.Fights()[1].meter == nil and rig.L.Fights()[1].at == 9)
        Check("ledger wiring: no verdicts before the read", rig.L.Fights()[1] ~= nil
            and rig.L.Fights()[1].verdicts == nil)
        rig.S.sessions = { { sessionID = 1, rows = { Row(SMITE, 53) } } }
        rig.Fire()
        local fight = rig.L.Fights()[1]
        local verdicts = fight and fight.verdicts
        Check("ledger wiring: read attaches an agree verdict by spell ID",
            verdicts ~= nil and verdicts[SMITE] ~= nil and verdicts[SMITE].verdict == "agree"
            and verdicts[SMITE].meter == 53 and verdicts[SMITE].meterID == SMITE)
    end)

    Scenario("wiring empty fight read does not attach", function()
        local rig = Wired({ [SMITE] = 2 })
        rig.Combat(9)
        rig.Cast(10, "nameplate7", SMITE)
        rig.Event(10.25, "nameplate7", "WOUND", 53, 2)
        rig.EndCombat(130)
        rig.S.sessions = {}
        rig.Fire() -- fight A's read skips ("no sessions"): A keeps no verdicts
        Check("ledger wiring: skipped read leaves fight A without verdicts", rig.ns.Teacher.last.skip == "no sessions"
            and rig.L.Fights()[1] ~= nil and rig.L.Fights()[1].verdicts == nil)
        rig.Combat(200)
        rig.EndCombat(210) -- fight B draws nothing: not saved
        rig.S.sessions = { { sessionID = 2, rows = { Row(SMITE, 53) } } }
        rig.Fire()
        Check("ledger wiring: fight B's read ran", rig.ns.Teacher.last.rows ~= nil)
        Check("ledger wiring: empty fight B's read does not attach to fight A",
            #rig.L.Fights() == 1 and rig.L.Fights()[1].at == 9 and rig.L.Fights()[1].verdicts == nil)
    end)

    Scenario("wiring off, toggle and forget", function()
        local rig = Wired()
        local S = rig.S
        S.target = "nameplate1"
        rig.Combat(10)
        rig.Event(11, "nameplate1", "WOUND", 500, 1)
        S.now = 12
        SlashCmdList.COMBATTEXTICONS("off")
        Check("ledger wiring: /cti off mid-fight saves the fight", rig.L.Current() == nil
            and #rig.L.Fights() == 1 and rig.L.Fights()[1].at == 10 and rig.L.Fights()[1].duration == 2)
        SlashCmdList.COMBATTEXTICONS("on")
        rig.Combat(20)
        rig.Event(21, "nameplate1", "WOUND", 500, 1)
        S.now = 22
        SlashCmdList.COMBATTEXTICONS("") -- a bare toggle turns it off
        Check("ledger wiring: bare /cti toggle off mid-fight saves the fight", rig.L.Current() == nil
            and #rig.L.Fights() == 2 and rig.L.Fights()[1].at == 20)

        SlashCmdList.COMBATTEXTICONS("on")
        rig.Combat(30)
        rig.Event(31, "nameplate1", "WOUND", 500, 1)
        local live = rig.L.Current()
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("ledger wiring: /cti forget empties the saved fights in place",
            next(rig.L.Fights()) == nil and rig.L.Fights() == T.Store().fights)
        Check("ledger wiring: /cti forget keeps the open fight",
            live ~= nil and rig.L.Current() == live and live.damage["?1"].hits == 1)
    end)

    Scenario("wiring records nothing for misses, damage taken, test popup", function()
        local rig = Wired()
        _G.MISS = "Miss"
        rig.Combat(10)
        rig.Cast(60, "nameplate3", 686)
        rig.Event(60.5, "nameplate3", "MISS", nil, 32)
        rig.Event(61, "player", "WOUND", 4500, 32)
        rig.Event(62, "player", "WOUND", 4500, 32)
        SlashCmdList.COMBATTEXTICONS("test")
        Check("ledger wiring: miss, damage taken and /cti test drew popups", rig.drawn >= 4)
        Check("ledger wiring: miss, damage taken and /cti test record nothing", rig.L.Current() ~= nil
            and rig.Keys("damage") == "" and rig.Keys("heal") == "")
    end)

    -- Rows ------------------------------------------------------------------------------
    local CORRUPTION_TICK, IMMOLATE_TICK, WITHER_TICK = 146739, 157736, 445474
    local LIGHTNING, LAVA_BURST, PAIN, RENEW = 188196, 51505, 594, 774

    -- A booted addon whose character table holds: learned dot 594 (also a learned fingerprint) and hot 774, votes for
    -- 8092 (two sigs) and 8093 (three sigs tied on votes), fingerprints 188196 (learned) and 51505 (1 cast of 3). `spells` loads the fixture table as ns.Spells.
    local function RowsRig(spells)
        local function Sample(castAt) return { school = 4, delay = 0.25, castAt = castAt, hops = 1 } end
        local ns = T.Boot(function(S)
            S.spellNames = { [348] = "Immolate", [172] = "Corruption", [445468] = "Wither" }
            CombatTextIconsCharDB = {
                learned = { [PAIN] = { school = 32, period = 2, kind = "dot" }, [RENEW] = { school = 2, period = 3, kind = "hot" } },
                votes = {
                    [8092] = { casts = 6, sigs = {
                        { kind = "dot", school = 32, period = 3, votes = 1, expected = 0.2 },
                        { kind = "channel", school = 32, period = 2, votes = 2, expected = 0.8 },
                    } },
                    [8093] = { casts = 6, sigs = {
                        { kind = "dot", school = 32, period = 4, votes = 2, expected = 0.9 },
                        { kind = "dot", school = 32, period = 3, votes = 2, expected = 0.5 },
                        { kind = "dot", school = 32, period = 2, votes = 2, expected = 0.5 },
                    } },
                    [8094] = { casts = 3, sigs = { { kind = "dot", school = 32, period = 2, votes = 0, expected = 0.3 } } },
                },
                casts = {
                    [LIGHTNING] = { learned = true, pattern = "single", school = 4, delays = { 0.25, 0.25, 0.25 },
                        samples = { Sample(1), Sample(2), Sample(3) }, fights = 2, over = 0, strikes = 1, lastSeen = 3 },
                    [PAIN] = { learned = true, pattern = "single", school = 32, delays = { 0.25 },
                        samples = { Sample(1) }, fights = 1, over = 0, strikes = 0, lastSeen = 1 },
                    [LAVA_BURST] = { learned = false, pattern = "single", delays = {}, samples = { Sample(1), Sample(1) },
                        fights = 0, over = 0, strikes = 0, lastSeen = 1 },
                },
            }
        end, spells)

        return ns
    end

    Scenario("rows: learn state lists", function()
        local ns = RowsRig()
        local best, tied = nil, nil
        for _, entry in ipairs(ns.Learn.VoteList()) do
            if entry.spellID == 8092 then best = entry elseif entry.spellID == 8093 then tied = entry end
        end
        Check("rows: VoteList best sig is the one with most votes", best ~= nil and best.votes == 2 and best.kind == "channel"
            and best.period == 2 and best.expected == 0.8 and math.abs(best.p - ns.Learn.PoissonTail(0.8, 2)) < 1e-9)
        Check("rows: VoteList tie goes to lowest expected, then lowest period", tied ~= nil and tied.expected == 0.5
            and tied.period == 2)
        local list, byID = ns.Fingerprints.List(), {}
        for _, entry in ipairs(list) do byID[entry.spellID] = entry end
        Check("rows: Fingerprints.List learned entry", byID[LIGHTNING] ~= nil and byID[LIGHTNING].learned == true
            and byID[LIGHTNING].pattern == "single" and byID[LIGHTNING].school == 4 and byID[LIGHTNING].casts == 3
            and byID[LIGHTNING].fights == 2 and byID[LIGHTNING].strikes == 1)
        Check("rows: Fingerprints.List counts distinct casts, not samples", byID[LAVA_BURST] ~= nil
            and byID[LAVA_BURST].learned == false and byID[LAVA_BURST].school == nil and byID[LAVA_BURST].casts == 1)
        Check("rows: Fingerprints.List sorted by spell id", list[1].spellID == PAIN and list[#list].spellID == LIGHTNING)
    end)

    Scenario("rows: build", function()
        local ns = RowsRig(true)
        local fight = { at = 1, date = 1000, duration = 5, group = false, heal = {}, damage = {
            [CORRUPTION_TICK] = { amount = 500, hits = 5 },
            [LIGHTNING] = { amount = 300, hits = 3 },
            ["?8"] = { amount = 100, hits = 1 },
            [999] = { amount = 100, hits = 1 }, -- equal unattributed amounts: the order falls to the key tiebreak
        } }
        local rows = ns.Panel.Rows(fight)
        local corruption = Find(rows, CORRUPTION_TICK)
        Check("rows: Corruption total on 146739", corruption ~= nil and corruption.drawn == 500 and corruption.hits == 5
            and corruption.group == "table" and corruption.section == "damage" and corruption.kind == "dot"
            and corruption.state:find("Corruption") ~= nil) -- owned by Corruption 172, not by Seed's spread entry
        Check("rows: no row under the cast ID 172", Find(rows, 172) == nil)
        local immolate = Find(rows, IMMOLATE_TICK)
        Check("rows: table kind/state owner", immolate ~= nil and immolate.kind == "dot"
            and immolate.state:find("Immolate") ~= nil)
        Check("rows: shared spread icon one row", CountKey(rows, WITHER_TICK) == 1 and Find(rows, WITHER_TICK).kind == "dot"
            and Find(rows, WITHER_TICK).state:find("Wither") ~= nil)
        Check("rows: spread-only icon is a spread row", Find(rows, 1253171) ~= nil and Find(rows, 1253171).kind == "spread")
        local learned = Find(rows, LIGHTNING)
        Check("rows: learned fingerprint", learned ~= nil and learned.group == "learned" and learned.kind == "direct"
            and learned.state == "agreed in 2 fights, strikes 1" and learned.drawn == 300)
        Check("rows: unlearned fingerprint casts 1 of 3", Find(rows, LAVA_BURST) ~= nil
            and Find(rows, LAVA_BURST).group == "learning" and Find(rows, LAVA_BURST).state == "casts 1 of 3")
        local vote = Find(rows, 8092)
        Check("rows: vote best sig", vote ~= nil and vote.group == "learning" and vote.kind == "channel"
            and vote.state == "votes 2 of 2 (checking)")
        local pain = Find(rows, PAIN)
        Check("rows: learned tick wins over a fingerprint on the same ID", CountKey(rows, PAIN) == 1 and pain.group == "learned"
            and pain.kind == "dot" and pain.state == "period 2.00 s")
        Check("rows: ? + unknown id unattributed", Find(rows, 999).group == "unattributed"
            and Find(rows, "?8").group == "unattributed")
        Check("rows: unattributed names", Find(rows, "?8").name == "? school 8" and Find(rows, 999).name == "spell 999")
        local ok, again = pcall(ns.Panel.Rows, fight)
        Check("rows: mixed key order", ok and IndexOf(rows, 999) < IndexOf(rows, "?8")) -- numbers before strings in unattributed
        Check("rows: same input gives the same order", ok and #again == #rows and again[1].key == rows[1].key
            and again[#again].key == rows[#rows].key)
        Check("rows: order is group (learned, learning, table, unattributed), then drawn descending",
            IndexOf(rows, LIGHTNING) < IndexOf(rows, 8092) and IndexOf(rows, 8092) < IndexOf(rows, CORRUPTION_TICK)
            and IndexOf(rows, CORRUPTION_TICK) < IndexOf(rows, 999) and IndexOf(rows, LIGHTNING) < IndexOf(rows, PAIN))
        ns.Fingerprints.Get(LIGHTNING).strikes = 0
        for _, sig in ipairs(ns.Learn.Votes(8092).sigs) do sig.votes = 1 end
        local changed = ns.Panel.Rows(fight)
        Check("rows: learned fingerprint with no strikes is 'agreed in N fights' only",
            Find(changed, LIGHTNING).state == "agreed in 2 fights")
        Check("rows: tick votes below the need are 'votes n of need' (school 32 needs 2)",
            Find(changed, 8092).state == "votes 1 of 2")
    end)

    Scenario("rows: procs", function()
        local X, Y = 1287663, 1286716
        local ns = RowsRig(true)
        local function Proc(school, lo, hi, streak, learned, period)
            return { school = school, lo = lo, hi = hi, streak = streak, learned = learned, unpaired = 0, seen = 0, period = period }
        end
        T.Store().procs = {
            [X] = Proc(106, 339, 364, 3, true), [Y] = Proc(106, 5538, 5827, 3, true),
            [900001] = Proc(106, 100, 110, 2, false), [900002] = Proc(106, 100, 110, 0, false),
            [PAIN] = Proc(106, 100, 110, 3, true),      -- learned dot 594 owns the key
            [LIGHTNING] = Proc(106, 100, 110, 3, true), -- learned fingerprint owns the key
            [8092] = Proc(106, 100, 110, 1, false),     -- a vote candidate owns the key
            [900003] = Proc(32, 1000, 1100, 1, false, 1.5), [900004] = Proc(32, 1000, 1100, 2, true, 1.5), -- rhythm procs
        }
        ns.Procs.Init(T.Store())
        local fight = { at = 1, date = 1000, duration = 5, group = false, heal = {},
            damage = { [X] = { amount = 700, hits = 2 } } }
        local rows = ns.Panel.Rows(fight)
        local learned, band = Find(rows, X), Find(rows, Y)
        Check("procs panel: a learned proc is a 'learned' / 'proc' row with its school and size band",
            learned ~= nil and learned.group == "learned" and learned.kind == "proc" and learned.section == "damage"
            and learned.state == "school 106, size 339–364" and band ~= nil and band.state == "school 106, size 5538–5827")
        Check("procs panel: the fight's drawn total joins the proc row", learned.drawn == 700 and learned.hits == 2)
        local candidate = Find(rows, 900001)
        Check("procs panel: a candidate with a streak is a 'learning' / 'proc' row 'exact fights 2 of 3'",
            candidate ~= nil and candidate.group == "learning" and candidate.kind == "proc"
            and candidate.state == "exact fights 2 of 3")
        Check("procs panel: a candidate with streak 0 is not listed", Find(rows, 900002) == nil)
        ns.Procs.LEARN_STREAK = 5
        Check("procs panel: the 'of N' is Procs.LEARN_STREAK, not a copy", Find(ns.Panel.Rows(fight), 900001).state == "exact fights 2 of 5")
        ns.Procs.LEARN_STREAK = 3
        local rhythmCandidate, rhythmLearned = Find(rows, 900003), Find(rows, 900004)
        Check("procs panel: a rhythm candidate reads 'rhythm fights 1 of 2' (Procs.RHYTHM_STREAK), not the size proc's 'exact fights of 3'",
            rhythmCandidate ~= nil and rhythmCandidate.group == "learning" and rhythmCandidate.state == "rhythm fights 1 of 2")
        Check("procs panel: a learned rhythm proc shows its period with its band",
            rhythmLearned ~= nil and rhythmLearned.group == "learned" and rhythmLearned.state == "school 32, rhythm 1.50 s, size 1000–1100")
        Check("procs panel: first claim wins: learned dot 594, learned fingerprint 188196 and vote 8092 keep their rows",
            CountKey(rows, PAIN) == 1 and Find(rows, PAIN).state == "period 2.00 s" and Find(rows, PAIN).kind == "dot"
            and CountKey(rows, LIGHTNING) == 1 and Find(rows, LIGHTNING).state == "agreed in 2 fights, strikes 1"
            and CountKey(rows, 8092) == 1 and Find(rows, 8092).kind == "channel")
        Check("procs panel: learned procs sort with the learned group, candidates with the learning group",
            IndexOf(rows, X) < IndexOf(rows, 900001) and IndexOf(rows, Y) < IndexOf(rows, 900001)
            and IndexOf(rows, 900001) < IndexOf(rows, CORRUPTION_TICK))
    end)

    Scenario("rows: sections and verdicts", function()
        local ns = RowsRig(true)
        local fight2 = { at = 2, date = 1000, duration = 5, group = false,
            damage = { [DRAIN_LIFE] = { amount = 1178, hits = 1 } },
            heal = { [DRAIN_LIFE] = { amount = 8246, hits = 1 }, [4242] = { amount = 40, hits = 1 } },
            verdicts = { [DRAIN_LIFE] = { verdict = "agree", meter = 10, meterID = DRAIN_LIFE } } }
        local rows = ns.Panel.Rows(fight2)
        Check("rows: verdict only on damage section", FindIn(rows, "damage", DRAIN_LIFE).verdict == "agree"
            and FindIn(rows, "damage", DRAIN_LIFE).meter == 10 and FindIn(rows, "heal", DRAIN_LIFE).verdict == nil
            and FindIn(rows, "heal", DRAIN_LIFE).meter == nil)
        Check("rows: a key on both sides shows each side's total", FindIn(rows, "damage", DRAIN_LIFE).drawn == 1178
            and FindIn(rows, "heal", DRAIN_LIFE).drawn == 8246 and FindIn(rows, "heal", DRAIN_LIFE).group == "table")
        Check("rows: heal-only unknown id sits in the heal section", FindIn(rows, "heal", 4242) ~= nil
            and FindIn(rows, "damage", 4242) == nil and FindIn(rows, "heal", 4242).group == "unattributed")
        Check("rows: damage sections come before heal sections", IndexOf(rows, 1253171) < IndexOf(rows, 4242))
        local idle = ns.Panel.Rows(nil)
        Check("rows: nil fight", #idle > 0 and Find(idle, PAIN) ~= nil and Find(idle, PAIN).drawn == 0 and Find(idle, PAIN).hits == 0)
        Check("rows: hot kind with no totals sits in the heal section", FindIn(idle, "heal", RENEW) ~= nil
            and FindIn(idle, "damage", RENEW) == nil and FindIn(idle, "damage", DRAIN_LIFE) ~= nil
            and FindIn(idle, "heal", DRAIN_LIFE) == nil)
    end)

    -- A shaman knows no table spell: only table rows of spells the character knows, or that drew in the fight, show.
    Scenario("rows: filters", function()
        local ns = RowsRig(true)
        Check("rows: a candidate with 0 votes is not listed", Find(ns.Panel.Rows(nil), 8094) == nil
            and Find(ns.Panel.Rows(nil), 8092) ~= nil)
        IsPlayerSpell = function(id) return id == 172 end -- knows Corruption only
        local idle = ns.Panel.Rows(nil)
        local fight = { at = 1, date = 1000, duration = 5, group = false, heal = {},
            damage = { [IMMOLATE_TICK] = { amount = 50, hits = 1 } } }
        local drawn = ns.Panel.Rows(fight)
        IsPlayerSpell = function() return Secret(true) end
        local secret = ns.Panel.Rows(nil)
        IsPlayerSpell = nil
        Check("rows: a known table spell is listed", Find(idle, CORRUPTION_TICK) ~= nil
            and Find(idle, CORRUPTION_TICK).group == "table")
        Check("rows: an unknown table spell is not listed", Find(idle, IMMOLATE_TICK) == nil and Find(idle, WITHER_TICK) == nil
            and Find(idle, DRAIN_LIFE) == nil)
        Check("rows: an unknown table spell that drew is listed as table", Find(drawn, IMMOLATE_TICK) ~= nil
            and Find(drawn, IMMOLATE_TICK).group == "table" and Find(drawn, IMMOLATE_TICK).drawn == 50)
        Check("rows: learned rows do not depend on the spellbook", Find(idle, PAIN) ~= nil and Find(idle, LIGHTNING) ~= nil)
        Check("rows: a secret spellbook answer hides the table row", Find(secret, CORRUPTION_TICK) == nil)
    end)

    -- Window ----------------------------------------------------------------------------
    -- The harness frame stub records SetScript handlers, so the refresh, the step buttons and the drag are fired
    -- by hand; layout is checked in game only.
    local function Printed(S, text)
        for _, line in ipairs(S.prints) do
            if line:find(text, 1, true) then return true end
        end

        return false
    end

    Scenario("window: slash", function()
        local ns = T.Boot()
        local S = T.State()
        SlashCmdList.COMBATTEXTICONS("learned")
        Check("window: /cti learned opens", ns.Panel.IsOpen() == true)
        SlashCmdList.COMBATTEXTICONS("learned")
        Check("window: /cti learned closes", ns.Panel.IsOpen() == false)
        S.prints = {}
        SlashCmdList.COMBATTEXTICONS(" Learned Chat ")
        Check("window: /cti learned chat prints and leaves the window shut",
            #S.prints == 1 and Printed(S, "nothing learned") and ns.Panel.IsOpen() == false)
        SlashCmdList.COMBATTEXTICONS("off")
        SlashCmdList.COMBATTEXTICONS("learned")
        Check("window: addon disabled, /cti learned still toggles",
            CombatTextIconsDB.enabled == false and ns.Panel.IsOpen() == true)
        ns.Panel.frame.close.scripts.OnClick(ns.Panel.frame.close)
        Check("window: close button closes", ns.Panel.IsOpen() == false)
        S.prints = {}
        SlashCmdList.COMBATTEXTICONS("bogus")
        Check("window: usage line lists learned [chat]", Printed(S, "learned [chat]"))
    end)

    Scenario("window: saved position", function()
        local ns = T.Boot(function() CombatTextIconsDB = { panel = { point = 1 } } end)
        ns.Panel.Toggle()
        Check("window: saved panel = { point = 1 } dropped", CombatTextIconsDB.panel == nil)

        ns = T.Boot(function() CombatTextIconsDB = { panel = { point = "CENTER", x = 10, y = -5, junk = 1 } } end)
        ns.Panel.Toggle()
        local panel = CombatTextIconsDB.panel
        Check("window: valid saved panel kept, other fields dropped", panel ~= nil and panel.point == "CENTER"
            and panel.x == 10 and panel.y == -5 and panel.junk == nil)

        local frame = ns.Panel.frame
        frame.scripts.OnDragStop(frame) -- stub getters return tables: nothing saved, no error
        Check("window: drag stop with no plain position keeps the saved one", CombatTextIconsDB.panel.x == 10)
        frame.GetCenter = function() return 600, 400 end
        UIParent.GetCenter = function() return 500, 300 end
        frame.scripts.OnDragStop(frame)
        panel = CombatTextIconsDB.panel
        Check("window: drag stop saves the offset from the screen centre", panel.point == "CENTER"
            and panel.x == 100 and panel.y == 100)
    end)

    Scenario("window: view follows the fights", function()
        local ns = T.Boot()
        local S = T.State()
        local Core, Ledger, Panel = ns.Core, ns.Ledger, ns.Panel
        S.prints = {}
        Panel.Toggle()
        Check("window: opens empty with no fights", Panel.View() == nil)
        S.now = 100
        Core.PLAYER_REGEN_DISABLED()
        Ledger.Add("damage", 146739, 10)
        local frame = Panel.frame
        local tick = frame.scripts.OnUpdate
        tick(frame, 0.6)
        Check("window: empty view moves to live when a fight opens", Panel.View() == "live")

        S.now = 105
        Core.PLAYER_REGEN_ENABLED()
        tick(frame, 0.2)
        Check("window: refresh is throttled", Panel.View() == "live")
        tick(frame, 0.3)
        Check("window: live view moves to the saved fight when it ends", Panel.View() == 100)

        S.now = 200
        Core.PLAYER_REGEN_DISABLED()
        Ledger.Add("damage", "?8", 5)
        tick(frame, 0.6)
        Check("window: a saved view stays put when a new fight opens", Panel.View() == 100)
        frame.newer.scripts.OnClick(frame.newer)
        Check("window: > steps to the newer view (live)", Panel.View() == "live")
        frame.newer.scripts.OnClick(frame.newer)
        Check("window: > stops at live", Panel.View() == "live")
        frame.older.scripts.OnClick(frame.older)
        frame.older.scripts.OnClick(frame.older)
        Check("window: < steps to the older view and stops at the oldest", Panel.View() == 100)

        SlashCmdList.COMBATTEXTICONS("forget")
        tick(frame, 0.6)
        Check("window: forgotten view moves to live", Panel.View() == "live")
        Panel.Toggle()
        Panel.Toggle()
        Check("window: reopening during a fight shows live", Panel.View() == "live")
        Check("window: refresh ran without error", not Printed(S, "learned window"))
    end)

    Scenario("window: rebuild error", function()
        local ns = T.Boot()
        local S = T.State()
        ns.Panel.Toggle()
        local frame = ns.Panel.frame
        local tick = frame.scripts.OnUpdate
        ns.Panel.Rows = function() error("boom") end
        S.prints = {}
        tick(frame, 0.6)
        tick(frame, 0.6)
        Check("window: rebuild error prints once", #S.prints == 1 and Printed(S, "boom"))
        Check("window: rebuild error stops the refresh", frame.scripts.OnUpdate == nil)
    end)

    -- Minimap ---------------------------------------------------------------------------
    -- Clicks are fired through the button's recorded OnClick with S.shift / S.ctrl as the modifier keys.
    -- Placement on the ring and the tooltip layout are checked in game only.
    Scenario("minimap: clicks", function()
        local ns = T.Boot()
        local S = T.State()
        local button = ns.MinimapButton.button
        local click = button.scripts.OnClick
        click(button, "LeftButton")
        Check("minimap: left opens window", ns.Panel.IsOpen() == true)
        click(button, "LeftButton")
        Check("minimap: left again closes window", ns.Panel.IsOpen() == false)
        S.shift = true; click(button, "LeftButton"); S.shift = false
        Check("minimap: shift toggles addon", CombatTextIconsDB.enabled == false)
        S.ctrl = true; click(button, "RightButton"); S.ctrl = false
        Check("minimap: ctrl toggles debug", ns.Debug ~= nil)
        local enabledBefore, debugBefore = CombatTextIconsDB.enabled, ns.Debug ~= nil
        S.shift, S.ctrl = true, true; click(button, "LeftButton"); S.shift, S.ctrl = false, false
        Check("minimap: shift wins over ctrl", CombatTextIconsDB.enabled ~= enabledBefore and (ns.Debug ~= nil) == debugBefore
            and ns.Panel.IsOpen() == false)
    end)

    Scenario("minimap: dispatch table", function()
        local ns = T.Boot()
        local S = T.State()
        local button = ns.MinimapButton.button
        local sent = {}
        SlashCmdList.COMBATTEXTICONS = function(message) sent[#sent + 1] = message end
        for _, keys in ipairs({ { false, false }, { true, false }, { false, true }, { true, true } }) do
            for _, mouse in ipairs({ "LeftButton", "RightButton" }) do
                S.shift, S.ctrl = keys[1], keys[2]
                button.scripts.OnClick(button, mouse)
            end
        end
        S.shift, S.ctrl = false, false
        Check("minimap: every click dispatches its slash command, never forget",
            table.concat(sent, ",") == "learned,unknown off,,,debug,debug,,")
        CombatTextIconsDB.showUnknown = false
        sent = {}
        button.scripts.OnClick(button, "RightButton")
        Check("minimap: right with '?' icons off sends unknown on", sent[1] == "unknown on")
    end)

    Scenario("minimap: slash", function()
        local ns = T.Boot()
        local S = T.State()
        Check("minimap: shown by default", CombatTextIconsDB.minimap.hide == false and CombatTextIconsDB.minimap.angle == 225)
        SlashCmdList.COMBATTEXTICONS("minimap")
        Check("minimap: /cti minimap hides", CombatTextIconsDB.minimap.hide == true)
        SlashCmdList.COMBATTEXTICONS(" Minimap ")
        Check("minimap: /cti minimap again shows", CombatTextIconsDB.minimap.hide == false)
        SlashCmdList.COMBATTEXTICONS("off")
        SlashCmdList.COMBATTEXTICONS("minimap")
        Check("minimap: /cti minimap works while the addon is off", CombatTextIconsDB.minimap.hide == true
            and CombatTextIconsDB.enabled == false)
        S.prints = {}
        SlashCmdList.COMBATTEXTICONS("bogus")
        Check("minimap: usage line lists minimap", Printed(S, "minimap"))
        Check("minimap: button kept", ns.MinimapButton.button ~= nil)
    end)

    Scenario("unknown toggle: '?' icons", function()
        local rig = Wired()
        local ns, button = rig.ns, rig.ns.MinimapButton.button
        local shown = {}
        ns.Display.Plate = function(_, texture, text) shown.texture, shown.text = texture, text end
        button.scripts.OnClick(button, "RightButton")
        Check("unknown toggle: minimap right click turns '?' off", CombatTextIconsDB.showUnknown == false)
        rig.Combat(10)
        rig.S.target = "nameplate1"
        rig.Event(11, "nameplate1", "WOUND", 100, 8)
        Check("unknown off: '?' hit draws number, nil texture", shown.text ~= nil and shown.texture == nil)
        local ledgerUnknown = rig.Total("damage", "?8")
        Check("unknown off: Teacher.Unknown and Ledger still record",
            #ns.Teacher.fight.unknown == 1 and ledgerUnknown ~= nil and ledgerUnknown.hits == 1)
        button.scripts.OnClick(button, "RightButton")
        Check("unknown toggle: second right click turns it on", CombatTextIconsDB.showUnknown == true)
        rig.Event(12, "nameplate1", "WOUND", 100, 8)
        Check("unknown on: '?' hit draws the question mark", shown.texture == ns.Meter.UNKNOWN_ICON)
        T.Boot(function() CombatTextIconsDB = { showUnknown = "yes" } end)
        Check("unknown: junk saved value dropped", CombatTextIconsDB.showUnknown == nil)
        local S = T.State()
        S.prints = {}
        SlashCmdList.COMBATTEXTICONS("unknown maybe")
        Check("unknown: bad word prints usage", Printed(S, "usage: /cti unknown on|off"))
    end)

    Scenario("minimap: saved data", function()
        T.Boot(function() CombatTextIconsDB = { minimap = { angle = "x", hide = "yes" } } end)
        local saved = CombatTextIconsDB.minimap
        Check("minimap: invalid saved minimap -> defaults 225 / false", saved.angle == 225 and saved.hide == false)
        T.Boot(function() CombatTextIconsDB = { minimap = 7 } end)
        saved = CombatTextIconsDB.minimap
        Check("minimap: non-table saved minimap -> defaults", type(saved) == "table" and saved.angle == 225 and saved.hide == false)
        T.Boot(function() CombatTextIconsDB = { minimap = { angle = 90, hide = true, junk = 1 } } end)
        saved = CombatTextIconsDB.minimap
        Check("minimap: valid saved minimap kept, other fields dropped", saved.angle == 90 and saved.hide == true and saved.junk == nil)
        T.Boot(function() CombatTextIconsDB = { minimap = { angle = Secret(90) } } end)
        Check("minimap: secret saved angle -> default", CombatTextIconsDB.minimap.angle == 225)
    end)

    Scenario("minimap: drag", function()
        local ns = T.Boot()
        local button = ns.MinimapButton.button
        button.scripts.OnDragStart(button)
        button.scripts.OnDragStop(button) -- stub getters return tables: nothing saved, no error
        Check("minimap: drag stop with no plain cursor keeps the angle", CombatTextIconsDB.minimap.angle == 225)
        GetCursorPosition = function() return 200, 400 end
        Minimap.GetEffectiveScale = function() return 2 end
        Minimap.GetCenter = function() return 100, 100 end
        button.scripts.OnDragStart(button)
        button.scripts.OnUpdate(button, 0.1)
        button.scripts.OnDragStop(button)
        Check("minimap: drag saves the cursor angle around the minimap centre (atan2 order y, x)",
            math.abs(CombatTextIconsDB.minimap.angle - 90) < 1e-9)
        Check("minimap: drag stop ends the drag update", button.scripts.OnUpdate == nil)
        GetCursorPosition = function() return 200, 0 end -- straight below the centre: atan2 gives -90
        button.scripts.OnDragStop(button)
        Check("minimap: dragged angle is in [0, 360)", math.abs(CombatTextIconsDB.minimap.angle - 270) < 1e-9)
    end)

    Scenario("minimap: tooltip", function()
        local ns = T.Boot()
        local lines = {}
        GameTooltip.SetText = function(_, text) lines[#lines + 1] = text end
        GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
        ns.Learn.List = function() return { {}, {}, {} } end
        ns.Fingerprints.List = function() return { { learned = true }, { learned = false }, { learned = true, pattern = "chain" } } end
        local button = ns.MinimapButton.button
        button.scripts.OnEnter(button)
        local text = table.concat(lines, "\n")
        Check("minimap: tooltip title and state lines", lines[1] == "Combat Text Icons" and text:find("Addon: on", 1, true) ~= nil
            and text:find("'?' icons: on", 1, true) ~= nil and text:find("Debug log: off", 1, true) ~= nil)
        Check("minimap: tooltip counts learned ticks and direct prints", text:find("Learned: 3 ticks, 2 direct", 1, true) ~= nil)
        Check("minimap: tooltip lists the four click hints", select(2, text:gsub("click", "")) >= 4
            and text:find("forget", 1, true) == nil)
        button.scripts.OnLeave(button)
    end)
end
