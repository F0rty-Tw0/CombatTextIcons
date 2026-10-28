-- Unit checks (acceptance criterion 6). Called by tests/run.lua with its stubs:
-- T.Boot() reloads the addon on fresh stubs (the shipped, empty ns.Spells),
-- T.Boot(setup, true) or T.BootSpells(setup) does the same with tests/fixture_spells.lua as ns.Spells, T.State() is the stub state,
-- T.Check(name, condition) records a result, T.RunFile(file) runs another check file
-- (an error in it fails one named check).

return function(T)
    local Check, Secret = T.Check, T.Secret
    local DAMAGE, TAKEN = 0, 7

    -- Lua 5.1 syntax: luac 5.4 accepts operators WoW's Lua 5.1 rejects, and library calls it lacks
    -- (table.move in Streams' Prune raised "attempt to call a nil value" in game, 5761a25).
    local LIB_52 = { "table%.unpack", "table%.move", "table%.pack", "utf8%.", "math%.type", "math%.tointeger",
        "string%.pack", "string%.unpack", "coroutine%.isyieldable" }
    do
        for _, file in ipairs(T.TocFiles()) do
            local handle = assert(io.open(T.Root .. "/" .. file, "rb"))
            local source = handle:read("a")
            handle:close()
            local code = source:gsub("%-%-%[(=*)%[.-%]%1%]", ""):gsub("%-%-[^\n]*", "")
            code = code:gsub("%[(=*)%[.-%]%1%]", '""'):gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
            local bad = code:match("%f[%w_]goto%f[^%w_]") or code:match("//") or code:match("[&|]")
                or code:match("<<") or code:match(">>") or code:match("~[^=]")
            for _, call in ipairs(LIB_52) do bad = bad or code:match(call) end
            Check("Lua 5.1 syntax: " .. file .. (bad and (" uses " .. bad) or ""), not bad)
        end
    end

    -- CVar save/restore -------------------------------------------------------------
    do
        local ns = T.Boot()
        local S = T.State()
        local Core = ns.Core
        local db = CombatTextIconsDB
        Check("db: enabled defaults to true", db.enabled == true)
        S.cvars = {
            floatingCombatTextCombatDamage_v2 = "1",
            floatingCombatTextCombatLogPeriodicSpells_v2 = "0",
            floatingCombatTextPetMeleeDamage_v2 = "1",
            floatingCombatTextPetSpellDamage_v2 = "1",
            floatingCombatTextCombatHealing_v2 = "2",
        }
        db.savedCVars = nil
        Core.SuppressBlizzard()
        local saved = db.savedCVars
        Check("cvar: non-zero value stored", saved.floatingCombatTextCombatDamage_v2 == "1" and saved.floatingCombatTextCombatHealing_v2 == "2")
        Check("cvar: value \"0\" never stored", saved.floatingCombatTextCombatLogPeriodicSpells_v2 == nil)
        local allZero = true
        for _, value in pairs(S.cvars) do allZero = allZero and value == "0" end
        Check("cvar: all five set to 0 on enable", allZero)
        Check("cvar: Blizzard CombatText hidden on enable", CombatText.shown == false)
        Core.SuppressBlizzard()
        Check("cvar: double enable keeps the first stored values", db.savedCVars.floatingCombatTextCombatDamage_v2 == "1"
            and db.savedCVars.floatingCombatTextCombatHealing_v2 == "2")

        -- a failed SetCVar returns nothing (not false): the entry must stay
        S.cvarFail.floatingCombatTextCombatHealing_v2 = true
        Core.RestoreBlizzard(true)
        Check("cvar: successful writes restored", S.cvars.floatingCombatTextCombatDamage_v2 == "1"
            and S.cvars.floatingCombatTextPetMeleeDamage_v2 == "1")
        Check("cvar: restored entries removed, failed write (no return value) kept", db.savedCVars ~= nil
            and db.savedCVars.floatingCombatTextCombatDamage_v2 == nil and db.savedCVars.floatingCombatTextCombatHealing_v2 == "2")
        Check("cvar: Blizzard CombatText shown on disable", CombatText.shown == true)
        S.cvarFail.floatingCombatTextCombatHealing_v2 = "error"
        Core.RestoreBlizzard(true)
        Check("cvar: erroring write kept", db.savedCVars and db.savedCVars.floatingCombatTextCombatHealing_v2 == "2")
        Core.SuppressBlizzard()
        Check("cvar: enable with a pending restore keeps the stored value", db.savedCVars.floatingCombatTextCombatHealing_v2 == "2")
        S.cvarFail.floatingCombatTextCombatHealing_v2 = nil
        Core.PLAYER_LOGOUT()
        Check("cvar: logout restores every value and keeps savedCVars", S.cvars.floatingCombatTextCombatHealing_v2 == "2"
            and S.cvars.floatingCombatTextCombatDamage_v2 == "1" and db.savedCVars ~= nil
            and db.savedCVars.floatingCombatTextCombatHealing_v2 == "2" and db.savedCVars.floatingCombatTextCombatDamage_v2 == "1")
        -- crash: the logout write never reached the settings, the CVars still read "0"
        for name in pairs(S.cvars) do S.cvars[name] = "0" end
        S.cvarDefaults.floatingCombatTextCombatLogPeriodicSpells_v2 = "0"
        Core.PLAYER_LOGIN()
        Check("cvar: login after a crash keeps the stored values", db.savedCVars.floatingCombatTextCombatDamage_v2 == "1"
            and db.savedCVars.floatingCombatTextCombatHealing_v2 == "2")
        Check("cvar: \"0\" with no stored value and a default \"0\" stays unstored",
            db.savedCVars.floatingCombatTextCombatLogPeriodicSpells_v2 == nil)
        db.savedCVars.floatingCombatTextCombatDamage_v2 = nil
        S.cvarDefaults.floatingCombatTextCombatDamage_v2 = "1"
        S.cvarDefaults.floatingCombatTextCombatLogPeriodicSpells_v2 = Secret("1")
        Core.SuppressBlizzard()
        Check("cvar: \"0\" with no stored value stores the default", db.savedCVars.floatingCombatTextCombatDamage_v2 == "1")
        Check("cvar: secret default not stored", db.savedCVars.floatingCombatTextCombatLogPeriodicSpells_v2 == nil)

        -- /cti toggles and keeps the CVars in step
        SlashCmdList.COMBATTEXTICONS("")
        Check("slash: /cti turns off", db.enabled == false)
        SlashCmdList.COMBATTEXTICONS("")
        Check("slash: /cti turns on and suppresses", db.enabled == true and S.cvars.floatingCombatTextCombatDamage_v2 == "0")
        SlashCmdList.COMBATTEXTICONS("")
        Check("slash: /cti off restores", S.cvars.floatingCombatTextCombatDamage_v2 == "1" and db.savedCVars == nil)
        SlashCmdList.COMBATTEXTICONS("")
        SlashCmdList.COMBATTEXTICONS(" Off ")
        Check("slash: /cti off sets off", db.enabled == false)
        SlashCmdList.COMBATTEXTICONS("off")
        Check("slash: /cti off while off stays off", db.enabled == false)
        SlashCmdList.COMBATTEXTICONS("on")
        Check("slash: /cti on sets on", db.enabled == true and S.cvars.floatingCombatTextCombatDamage_v2 == "0")
        SlashCmdList.COMBATTEXTICONS("metter on")
        Check("slash: an unknown word does not toggle", db.enabled == true)
        CombatText.shown = true
        Core.ADDON_LOADED("Blizzard_CombatText")
        Check("load-on-demand CombatText hidden while enabled", CombatText.shown == false)
        local shownTest
        ns.Display.Plate = function(plate, texture) shownTest = texture end
        S.target = nil
        SlashCmdList.COMBATTEXTICONS("test")
        Check("slash: /cti test without a target plate shows nothing", shownTest == nil)
        S.target = "nameplate3"
        SlashCmdList.COMBATTEXTICONS("test")
        Check("slash: /cti test shows on the target plate", shownTest ~= nil)
    end

    -- Single mode (spec A): the meter is never reset or queued; one route, learned data only ------
    do
        local ns = T.Boot(function() CombatTextIconsDB = { enabled = true, meter = true } end)
        local S = T.State()
        local Core = ns.Core
        Check("single mode: db.meter nil after load", CombatTextIconsDB.meter == nil)

        local plate = T.Plate("nameplate1")
        S.plates.nameplate1, S.target = plate, "nameplate1"
        local last
        ns.Display.Plate = function(_, texture, text) last = { kind = "plate", texture = texture, text = text } end
        ns.Display.Player = function(kind, texture, text) last = { kind = kind, texture = texture, text = text } end
        SlashCmdList.COMBATTEXTICONS("off")
        SlashCmdList.COMBATTEXTICONS("on")
        S.now, S.pending = 10, { [DAMAGE] = 1 }
        Core.UNIT_COMBAT("nameplate1", "WOUND", "", 5000, 32)
        Core.PLAYER_REGEN_DISABLED()
        Core.PLAYER_REGEN_ENABLED()
        Check("single mode: ResetAllCombatSessions never called", S.resets == 0)

        last, S.now, S.pending = nil, 20, { [TAKEN] = 1 }
        Core.UNIT_COMBAT("player", "WOUND", "", 4500, 32)
        Check("single mode: taken has no icon", last and last.kind == "taken" and last.texture == nil and last.text == 4500)

        S.prints = {}
        SlashCmdList.COMBATTEXTICONS("meter off")
        Check("single mode: /cti meter off prints usage, saves nothing",
            table.concat(S.prints, "\n"):find("usage", 1, true) ~= nil and CombatTextIconsDB.meter == nil)

        local exports = {}
        for key in pairs(ns.Meter) do exports[#exports + 1] = key end
        table.sort(exports)
        Check("single mode: Meter exports only Init, Available, Disable, UNKNOWN_ICON and the type constants",
            table.concat(exports, " ") == "Available DAMAGE_DONE DAMAGE_TAKEN Disable HEALING_DONE Init UNKNOWN_ICON")
    end
    do -- a save from before the per-spec stores holds only learning: login drops it whole, once
        local ns = T.Boot(function(S)
            S.oldSave = true
            CombatTextIconsCharDB = { chainSchools = { [188443] = 8 }, pending = {},
                learned = { [589] = { school = 32, period = 3, kind = "dot" } },
                votes = { [589] = { casts = 1, sigs = {} } },
                casts = {}, castAliases = { [75] = 5019 }, ownRows = { [51505] = true },
                procs = { [10] = { school = 106, lo = 339, hi = 364, streak = 3, learned = true } },
                fights = {}, area = { state = "clear", map = 1 }, pace = 5000 }
        end)
        local keys = {}
        for key in pairs(CombatTextIconsCharDB) do keys[#keys + 1] = key end
        local spec = T.Store()
        Check("migration: an old save's learning is dropped at login; only the spec stores stay",
            table.concat(keys, ",") == "specs" and ns.Learn.Get(589) == nil and ns.Procs.Get(10) == nil
            and ns.Fingerprints.Alias(75) == nil and spec.area == nil and spec.pace == nil
            and next(spec.ownRows) == nil)
        ns.Core.PLAYER_LOGIN()
        Check("migration: a login with spec stores keeps them", T.Store() == spec)
    end
    do -- first-login hint: once per character, only with the addon on
        local function Hints(S)
            local count = 0
            for _, line in ipairs(S.prints) do
                if line:find("'?' icons are hits it hasn't learned yet", 1, true) then count = count + 1 end
            end
            return count
        end
        local ns = T.Boot()
        local S = T.State()
        local fresh = Hints(S)
        ns.Core.PLAYER_LOGIN()
        Check("hint: a new character's first login prints the hint once; a second login (reload) does not",
            fresh == 1 and Hints(S) == 1)
        T.Boot(function() CombatTextIconsCharDB = {} end)
        Check("hint: a character with saved data gets no hint", Hints(T.State()) == 0)
        T.Boot(function() CombatTextIconsDB = { enabled = false } end)
        Check("hint: a new character with the addon off gets no hint, and its table is made",
            Hints(T.State()) == 0 and type(T.Store()) == "table")
    end
    do
        -- learned fingerprint cast, solo, no SetMeterOn call: its record opens and claims the hit
        local ns, S = T.Boot(), nil
        S = T.State()
        for index = 1, 3 do ns.Fingerprints.Add(5019, { school = 4, delay = 0.2, castAt = index, hops = 1 }) end
        S.now, S.target = 10, "nameplate1"
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-wand", 5019)
        local kind = ns.Casts.Claim(C_NamePlate.GetNamePlateForUnit("nameplate1", false), 4, 10.2)
        Check("single mode: claim records open at login", kind == "learned")
    end

    -- Meter module -------------------------------------------------------------------
    do
        local ns = T.Boot()
        Check("meter: available at login", ns.Meter.Available())
        Check("meter: UNKNOWN_ICON exported (134400)", ns.Meter.UNKNOWN_ICON == 134400)
    end
    do
        local ns = T.Boot()
        T.State().meterAvailable = false
        ns.Meter.Init()
        Check("meter: unavailable at load stays off", not ns.Meter.Available())
    end

    do
        local ns, S = T.Boot(function(S) S.meterAvailable = false; CombatTextIconsCharDB = {} end), T.State()
        ns.Meter.Init()
        Check("stamp: unavailable meter prints one chat line with the reason, not again on a second Init",
            #S.prints == 1 and S.prints[1]:find("'?' for unlearned hits is off (unavailable)", 1, true) ~= nil)
    end
    do -- spec §4.6: a client with no meter API at all
        local ok, ns = pcall(T.Boot, function() C_DamageMeter = nil; CombatTextIconsCharDB = {} end)
        local S = T.State()
        Check("meter: no C_DamageMeter at login raises no error and turns the meter off ('unavailable')",
            ok and not ns.Meter.Available() and #S.prints == 1 and S.prints[1]:find("(unavailable)", 1, true) ~= nil)
    end

    -- Hit routes (spec §4.1): an unexplained solo hit draws '?' at once while the area is clear ----
    do
        local WAND, BARBED = 5019, 217200
        local UNKNOWN_ICON = 134400 -- Meter.UNKNOWN_ICON, checked under "meter:"
        local resets = 0
        -- A fresh addon, solo, on a mob that fights you, nothing learned, the crowd check's area clear
        -- (`spells` loads the fixture table). Display.Plate / Display.Player record every draw in g.draws.
        local function Solo(setup, spells)
            local g = { draws = {} }
            g.ns = T.Boot(setup, spells)
            g.S = T.State()
            local ns, S = g.ns, g.S
            ns.Teacher.area = "clear"
            ns.Display.Plate = function(plate, texture, text) g.draws[#g.draws + 1] = { plate = plate, texture = texture, text = text } end
            ns.Display.Player = function(kind, texture, text) g.draws[#g.draws + 1] = { kind = kind, texture = texture, text = text } end
            function g.Hit(t, unit, school, amount)
                S.now = t
                ns.Core.UNIT_COMBAT(unit or "nameplate1", "WOUND", "", amount or 5000, school or 32)
            end
            function g.Heal(t)
                S.now = t
                ns.Core.UNIT_COMBAT("player", "HEAL", "", 800, 2)
            end
            function g.Cast(t, id, unit)
                S.now, S.target = t, unit or "nameplate1"
                ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-" .. t, id)
            end
            function g.Last() return g.draws[#g.draws] end
            return g
        end
        -- Runs one scenario; an error counts as a failed check, not a dead file.
        local function Scenario(fn)
            local ok, a, b = pcall(fn)
            if not ok then return false end
            return true, a, b
        end
        local function Done(g) resets = resets + g.S.resets end

        local ok, shown, before
        ok, before = Scenario(function()
            local g = Solo(nil, true)
            g.S.haste = 0
            g.Cast(50, BARBED, "nameplate2") -- Barbed Shot: 2 s unhasted, school 1
            g.Hit(52, "nameplate2", 1, 800)
            Done(g)
            return g.Last()
        end)
        Check("gate: learned tick draws in its own frame", ok and before ~= nil and before.texture == "tex:" .. BARBED)

        ok, shown = Scenario(function()
            local g = Solo()
            for index = 1, 3 do g.ns.Fingerprints.Add(WAND, { school = 4, delay = 0.2, castAt = index, hops = 1 }) end
            g.S.group = true
            g.Cast(10, WAND)
            g.Hit(10.2, "nameplate1", 4, 90)
            Done(g)
            return g.Last()
        end)
        Check("gate: learned claim draws in a group", ok and shown ~= nil and shown.texture == "tex:" .. WAND)

        local unknownCount
        ok, shown, unknownCount = Scenario(function()
            local g = Solo()
            g.S.now = 9
            g.ns.Core.PLAYER_REGEN_DISABLED()
            g.S.group = true
            g.ns.Tracker.Identify = function() return g.ns.Tracker.UNKNOWN end -- two learned DoTs fit
            g.Hit(10)
            Done(g)
            return g.Last(), #g.ns.Teacher.fight.unknown
        end)
        Check("gate: tracker UNKNOWN '?' in a group, no Teacher.Unknown",
            ok and shown ~= nil and shown.texture == UNKNOWN_ICON and unknownCount == 0)

        ok, shown = Scenario(function()
            local g = Solo()
            g.S.group = true
            g.Hit(10.00)
            Done(g)
            return g.Last()
        end)
        Check("crowd: an unexplained group hit while clear stays hidden", ok and shown == nil)

        ok, shown = Scenario(function()
            local g = Solo()
            g.S.sessionsFail = "error"
            g.S.now = 1
            g.ns.Core.PLAYER_REGEN_DISABLED()
            g.S.now = 2
            g.ns.Core.PLAYER_REGEN_ENABLED()
            for _, timer in ipairs(g.S.timers) do timer.fn() end
            g.S.now = 9
            g.ns.Core.PLAYER_REGEN_DISABLED()
            g.Hit(10.00)
            Done(g)
            return g.Last()
        end)
        Check("crowd: after a Teacher read error (meter disabled) the next hit is hidden", ok and shown == nil)

        ok, shown = Scenario(function()
            local g = Solo(function() CombatTextIconsDB = { enabled = true, showUnknown = false } end)
            g.Hit(10.00)
            Done(g)
            return g.Last()
        end)
        Check("crowd: '?' off, clear: an unexplained hit draws the number only",
            ok and shown ~= nil and shown.texture == nil and shown.text ~= nil)

        local skip, timers
        ok, skip, timers = Scenario(function()
            local g = Solo()
            g.S.now = 9
            g.ns.Core.PLAYER_REGEN_DISABLED()
            g.Hit(10.00)
            SlashCmdList.COMBATTEXTICONS("off")
            SlashCmdList.COMBATTEXTICONS("on")
            g.S.now = 11
            g.ns.Core.PLAYER_REGEN_ENABLED()
            Done(g)
            return g.ns.Teacher.last and g.ns.Teacher.last.skip, #g.S.timers
        end)
        Check("gate: /cti off closes the teacher's fight (no read of the cut-short fight)",
            ok and skip == "no fight" and timers == 0)

        ok, shown = Scenario(function()
            local g = Solo(function() CombatTextIconsDB = { enabled = true, showUnknown = false } end)
            g.Heal(10.00)
            Done(g)
            return g.Last()
        end)
        Check("crowd: '?' off, clear: an own heal draws the number only",
            ok and shown ~= nil and shown.kind == "heal" and shown.texture == nil and shown.text == 800)

        Check("gate: no reset in any gate scenario", resets == 0)
    end

    -- Display smoke test (real Display.lua on frame stubs) -----------------------------
    do
        local ns = T.Boot()
        local created = 0
        local createFrame = CreateFrame
        CreateFrame = function(...) created = created + 1 return createFrame(...) end
        local plate = T.Plate("nameplate1")
        local ok, err = pcall(function()
            for index = 1, 5 do ns.Display.Plate(plate, "tex", index * 1000, "", 36) end
        end)
        Check("display: at most 3 popups per plate, oldest recycled", ok and created == 3)
        ok, err = pcall(function()
            for index = 1, 10 do ns.Display.Player("taken", "tex", index, "") end
        end)
        Check("display: player column at most 6 rows", ok and created == 3 + 6)
        ok, err = pcall(function()
            for index = 1, 45 do
                ns.Display.Plate(T.Plate("nameplate" .. index), "tex", index * 1000, index % 2 == 0 and "CRITICAL" or "", 36)
            end
            ns.Display.Plate(plate, Secret("tex"), Secret(5), Secret("CRITICAL"), Secret(32))
            ns.Display.Plate(plate, "tex", "Miss")
            ns.Display.Player("heal", "tex", 1234, "CRITICAL")
            ns.Display.Player("heal", Secret("tex"), Secret(5), Secret(""))
            ns.Display.Player("taken", nil, 999, "")
            ns.Display.ReleasePlate(plate)
        end)
        Check("display: popups draw without errors" .. (ok and "" or (" (" .. tostring(err) .. ")")), ok)
        Check("display: at most 40 popup frames", created == 40)
        ok, err = pcall(function()
            ns.Display.Update(T.State().now + 0.6)
            ns.Display.Update(T.State().now + 5)
            for index = 1, 40 do ns.Display.Plate(T.Plate("nameplate" .. index), "tex", index, "", 36) end
        end)
        Check("display: expired popups return to the pool" .. (ok and "" or (" (" .. tostring(err) .. ")")),
            ok and created == 40)
    end

    -- Display motion (recorded SetScale / SetAlpha) ------------------------------------
    do
        local ns = T.Boot()
        local frames, createFrame = {}, CreateFrame
        CreateFrame = function(...)
            local frame = createFrame(...)
            frame.SetScale = function(self, value) self.scale = value end
            frame.SetAlpha = function(self, value) self.alpha = value end
            frames[#frames + 1] = frame
            return frame
        end
        local plate = T.Plate("nameplate1")
        local born = T.State().now
        ns.Display.Plate(plate, "tex", 1000, "CRITICAL", 36)         -- frames[1]: crit
        ns.Display.Plate(plate, "tex", 1000, "", 36)                 -- frames[2]: normal
        ns.Display.Plate(plate, "tex", 1000, Secret("CRITICAL"), 36) -- frames[3]: secret flag
        CreateFrame = createFrame
        local crit, normal, secret = frames[1], frames[2], frames[3]
        local function Near(a, b) return type(a) == "number" and math.abs(a - b) <= 1e-6 end
        local samples = {}
        for _, age in ipairs({ 0, 0.07, 0.3, 0.6, 1.025 }) do
            ns.Display.Update(born + age)
            samples[age] = { crit = crit.scale, normal = normal.scale, secret = secret.scale, alpha = normal.alpha,
                critAlpha = crit.alpha }
        end
        Check("motion: three popup frames recorded", #frames == 3)
        Check("motion: crit starts at normal-hit size (scale 1 / 1.6)", Near(samples[0].crit, 1 / 1.6))
        Check("motion: crit peaks at 1.7 at age 0.07", Near(samples[0.07].crit, 1.7))
        Check("motion: crit settled to 1 at age 0.3", Near(samples[0.3].crit, 1))
        Check("motion: normal scale 1 at every age", Near(samples[0].normal, 1) and Near(samples[0.07].normal, 1)
            and Near(samples[0.3].normal, 1) and Near(samples[0.6].normal, 1) and Near(samples[1.025].normal, 1))
        Check("motion: secret flag is not a crit (no pop)", Near(samples[0.07].secret, 1))
        Check("motion: alpha 0 at birth", Near(samples[0].alpha, 0) and Near(samples[0].critAlpha, 0))
        Check("motion: alpha 1 mid-life", Near(samples[0.6].alpha, 1))
        Check("motion: alpha 0.5 halfway through the fade-out", Near(samples[1.025].alpha, 0.5))
    end

    -- Tracker ------------------------------------------------------------------------
    do
        local ns = T.BootSpells()
        local S = T.State()
        local Tracker = ns.Tracker
        local P, Q = T.Plate("nameplate1"), T.Plate("nameplate2")
        S.plates.nameplate1, S.plates.nameplate2 = P, Q
        S.haste = 0
        S.target = "nameplate1"

        -- target mode: period 2 s, tolerance max(0.25, 0.2 * 2) = 0.4 s
        Tracker.OnCast("player", 980, 100)
        Check("tracker: no tick before castAt + period", Tracker.Identify(P, 32, 1000, "", 101.0) == nil)
        Check("tracker: first tick at castAt + period", Tracker.Identify(P, 32, 1000, "", 102.3) == 980)
        Check("tracker: next tick one period later", Tracker.Identify(P, 32, 1100, "", 104.3) == 980)
        Check("tracker: tick two periods later (one missed)", Tracker.Identify(P, 32, 1200, "", 108.3) == 980)
        Check("tracker: off-phase hit not matched", Tracker.Identify(P, 32, 1200, "", 109.3) == nil)
        Check("tracker: amount gate rejects x2.5+", Tracker.Identify(P, 32, 3100, "", 110.3) == nil)
        Check("tracker: amount gate halves crits", Tracker.Identify(P, 32, 2600, "CRITICAL", 110.3) == 980)
        Check("tracker: amount gate rejects below x0.4", Tracker.Identify(P, 32, 400, "", 112.3) == nil)
        Check("tracker: secret amount skips the gate", Tracker.Identify(P, 32, Secret(1), "", 112.3) == 980)
        Check("tracker: QualifiesByPhase on the next due tick", Tracker.QualifiesByPhase(P, 32, 1300, "", 114.3)
            and not Tracker.QualifiesByPhase(P, 32, 1300, "", 113.3))
        Check("tracker: other plate, other school not matched", Tracker.Identify(Q, 32, 1300, "", 114.3) == nil
            and Tracker.Identify(P, 4, 1300, "", 114.3) == nil)
        Check("tracker: secret school gives no candidates", pcall(Tracker.Identify, P, Secret(32), 1300, "", 114.3)
            and Tracker.Identify(P, Secret(32), 1300, "", 114.3) == nil)
        Check("tracker: instance expires 3 periods after its last tick", Tracker.Identify(P, 32, 1300, "", 120.3) == nil)

        -- the period nudges toward the observed interval
        Tracker.OnCast("player", 980, 200)
        Tracker.Identify(P, 32, 1000, "", 202.0)
        Tracker.Identify(P, 32, 1000, "", 203.7) -- 1.7 s: period 0.8 * 2 + 0.2 * 1.7 = 1.94
        Check("tracker: period nudged (1.94 s fits, 2.4 s does not)", Tracker.QualifiesByPhase(P, 32, 1000, "", 205.64)
            and not Tracker.QualifiesByPhase(P, 32, 1000, "", 206.1))
        -- a recast refreshes without restarting the tick timer
        Tracker.OnCast("player", 980, 204.5)
        Check("tracker: refresh keeps the tick timer", Tracker.Identify(P, 32, 1000, "", 205.64) == 980)
        -- a second DoT of the same school in phase makes the hit ambiguous
        Tracker.OnCast("player", 1259790, 205.64 - 0.1)
        Check("tracker: two fitting instances with differing textures -> UNKNOWN",
            Tracker.UNKNOWN ~= nil and Tracker.Identify(P, 32, 1000, "", 207.55) == Tracker.UNKNOWN)
        Tracker.OnPlateRemoved(P)
        Check("tracker: plate removal drops its instances", not Tracker.QualifiesByPhase(P, 32, 1000, "", 209.5))

        -- haste shortens a hasted period at creation
        S.haste = 100
        Tracker.OnCast("player", 980, 300)
        Check("tracker: hasted first tick at castAt + period / (1 + haste)", Tracker.Identify(P, 32, 1000, "", 301.0) == 980)
        S.haste = Secret(10)
        Tracker.OnCast("player", 1259790, 310)
        Check("tracker: secret haste falls back to the base period", Tracker.Identify(P, 32, 1000, "", 312.0) == 1259790)
        S.haste = 0
        Tracker.OnPlateRemoved(P)
        Tracker.OnCast("player", Secret(980), 320)
        Check("tracker: secret cast ID ignored", Tracker.TakeMissCast(320.1) == nil
            and not Tracker.QualifiesByPhase(P, 32, 1000, "", 322.0))
        S.target = nil
        Tracker.OnCast("player", 980, 330)
        Check("tracker: no target plate, no instance", not Tracker.QualifiesByPhase(P, 32, 1000, "", 332.0))
        S.target = "nameplate1"

        -- spread: Seed arms plates the meter saw hit; the first spread tick creates the instance
        Tracker.OnCast("player", 27243, 400)
        Check("tracker: spread tick on an unarmed plate hidden", Tracker.Identify(P, 36, 1500, "", 410) == nil)
        Tracker.OnMeterHit(P, 412)
        Check("tracker: spread tick on an armed plate creates Wither", Tracker.Identify(P, 36, 1500, "", 413.5) == 445474)
        Check("tracker: created instance keeps ticking", Tracker.Identify(P, 36, 1500, "", 415.5) == 445474)
        Check("tracker: spread school 32 blocked once the plate has the spread instance", Tracker.Identify(P, 32, 1500, "", 415.6) == nil)
        Tracker.OnMeterHit(Q, 416)
        Check("tracker: spread school 32 on another armed plate -> Corruption", Tracker.Identify(Q, 32, 1500, "", 417) == 146739)
        local R = T.Plate("nameplate3")
        Tracker.OnMeterHit(R, 419)
        Check("tracker: spread window closes after 20 s", Tracker.Identify(R, 36, 1500, "", 421) == nil)
        Tracker.OnPlateRemoved(Q)
        Tracker.OnCast("player", 27243, 430)
        Tracker.OnMeterHit(Q, 431)
        Tracker.OnPlateRemoved(Q)
        Check("tracker: plate removal drops its arming", Tracker.Identify(Q, 36, 1500, "", 432) == nil)

        -- area: any plate, that school, until duration + 0.5 s
        Tracker.OnCast("player", 5740, 500)
        Check("tracker: area tick on any plate", Tracker.Identify(Q, 4, 900, "", 503) == 42223)
        Check("tracker: area other school hidden", Tracker.Identify(Q, 1, 900, "", 503) == nil)
        Check("tracker: area window ends", Tracker.Identify(Q, 4, 900, "", 508.6) == nil)

        -- channel: first tick by school alone; the heal pairs with a same-frame tick
        Tracker.OnChannelStart(234153, 600)
        Check("tracker: channel tick on the target plate", Tracker.Identify(P, 32, 500, "", 600.3) == 234153)
        Check("tracker: channel heal paired in the same frame", Tracker.ChannelHeal(600.3) == 234153)
        Check("tracker: channel heal not paired a frame later", Tracker.ChannelHeal(600.4) == nil)
        Tracker.OnChannelStop(601)
        Check("tracker: channel gone after stop", Tracker.Identify(P, 32, 500, "", 601.0) == nil and Tracker.ChannelHeal(601.0) == nil)
        Tracker.OnChannelStart(686, 602)
        Check("tracker: non-table channel ignored", Tracker.Identify(P, 32, 500, "", 602.3) == nil)
        -- a late stop of an earlier channel does not end the current one
        Tracker.OnChannelStart(234153, 603, "Cast-B")
        Tracker.OnChannelStop(603.1, "Cast-A")
        Check("tracker: stop with another castGUID ignored", Tracker.Identify(P, 32, 500, "", 603.3) == 234153)
        Tracker.OnChannelStop(603.5, "Cast-B")
        Check("tracker: stop with the channel's castGUID ends it", Tracker.Identify(P, 32, 500, "", 603.6) == nil)
        Tracker.OnChannelStart(234153, 604, "Cast-C")
        Tracker.OnChannelStop(604.1, Secret("Cast-A"))
        Check("tracker: stop with a secret castGUID ends it", Tracker.Identify(P, 32, 500, "", 604.3) == nil)

        -- misses: a harmful player cast <= 1.5 s old, each used once
        Tracker.OnCast("player", 686, 700)
        Tracker.OnCast("pet", 54049, 700)
        Check("tracker: miss takes the recent player cast", Tracker.TakeMissCast(700.5) == 686)
        Check("tracker: miss cast used once (pet casts not kept)", Tracker.TakeMissCast(700.6) == nil)
        Tracker.OnCast("player", 686, 800)
        Check("tracker: miss cast expires after 1.5 s", Tracker.TakeMissCast(801.6) == nil)
        S.harmful[1234] = false
        Tracker.OnCast("player", 1234, 900)
        Check("tracker: helpful casts not kept for misses", Tracker.TakeMissCast(900.1) == nil)
    end

    -- Wither replay (in-game log 2026-10-21: 7.73% haste, ticks every ~1.48 s) ------
    do
        local ns = T.BootSpells()
        local S = T.State()
        local Core = ns.Core
        local shown = 0
        ns.Display.Plate = function(plate, texture) if texture == "tex:445474" then shown = shown + 1 end end
        S.haste, S.target = 7.7259, "nameplate1"
        local function Hit(t, amount, school, unit)
            S.now, S.pending = t, {}
            Core.UNIT_COMBAT(unit or "nameplate1", "WOUND", "", amount, school)
        end
        S.now = 0
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "cast", 445474)
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "cast", 445468)
        Hit(0, 683, 36)
        Hit(0, 5490, 4)
        local ticks = { { 1.438, 1469 }, { 2.900, 1471 }, { 4.452, 1483 }, { 5.938, 1442 }, { 7.351, 1488 },
            { 8.911, 3403 }, { 10.382, 1496 }, { 11.885, 1509 } }
        for _, tick in ipairs(ticks) do Hit(tick[1], tick[2], 36) end
        for _, t in ipairs({ 1.036, 1.968, 3.021, 3.990, 5.029, 7.029, 8.021, 9.045, 10.020, 11.025, 12.032 }) do
            Hit(t, 343, 106)
        end
        -- the first tick only teaches the rhythm; every later tick is shown
        Check("wither: faster-than-haste ticks learned from the rhythm (" .. shown .. "/7)", shown == 7)
        -- the learned speed carries to the next cast: its first tick is shown too
        shown, S.target, S.now = 0, "nameplate2", 30
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "cast", 445468)
        for index = 1, 4 do Hit(30 + 1.48 * index, 1480, 36, "nameplate2") end
        Check("wither: learned speed shows the next cast's first tick (" .. shown .. "/4)", shown == 4)
    end

    -- Core hits -----------------------------------------------------------------------
    do
        local ns = T.BootSpells()
        local S = T.State()
        local Core = ns.Core
        local last
        ns.Teacher.area = "clear" -- the crowd check's area: an unexplained solo hit draws '?'
        ns.Display.Plate = function(plate, texture, text) last = { plate = plate, texture = texture, text = text } end
        ns.Display.Player = function(kind, texture, text) last = { kind = kind, texture = texture, text = text } end
        -- One hit: an unexplained solo hit draws '?' in the call while the area is clear.
        local function Hit(t, unit, event, amount, school, flag)
            S.now, last = t, nil
            Core.UNIT_COMBAT(unit, event, flag or "", amount, school)
            return last
        end
        -- A hit while in a group, where one nothing identifies stays hidden (solo it draws "?").
        local function GroupHit(...)
            S.group = true
            local shown = Hit(...)
            S.group = false
            return shown
        end

        Check("core: teammate hit (nothing identifies it) hidden", GroupHit(11, "nameplate1", "WOUND", 5000, 32) == nil)
        local unexplained = Hit(12, "nameplate1", "WOUND", 5000, 32)
        Check("core: an unexplained solo hit on a mob fighting you draws '?'",
            unexplained and unexplained.texture == ns.Meter.UNKNOWN_ICON) -- single mode (spec A)

        -- friendly and personal plates: the hit is skipped
        S.attackable.nameplate6, S.attackable.nameplate7, S.attackable.nameplate8 = false, "error", Secret(true)
        Check("core: friendly plate hit skipped", Hit(13, "nameplate6", "WOUND", 5000, 32) == nil)
        Check("core: plate with UnitCanAttack error or secret skipped", Hit(13.5, "nameplate7", "WOUND", 5000, 32) == nil
            and Hit(13.6, "nameplate8", "WOUND", 5000, 32) == nil)

        -- fully mitigated hits show Blizzard's word instead of "0"
        _G.BLOCK, _G.RESIST = "Block", nil
        local shown = Hit(14, "nameplate1", "WOUND", 0, 1, "BLOCK")
        Check("core: fully blocked enemy hit shows the word", shown and shown.text == "Block")
        shown = Hit(15, "nameplate1", "WOUND", 0, 32, "RESIST")
        Check("core: word falls back to the flag", shown and shown.text == "RESIST")
        shown = Hit(16, "nameplate1", "WOUND", 0, 32, "")
        Check("core: unflagged 0 stays a number", shown and shown.text == 0)
        shown = Hit(17, "player", "WOUND", 0, 1, "BLOCK")
        Check("core: fully blocked damage taken shows the word", shown and shown.kind == "taken" and shown.text == "Block")

        -- a tracked physical tick keeps its icon; an off-phase hit has no meter entry to take
        S.haste, S.target = 0, "nameplate2"
        S.now = 50
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-1", 217200) -- Barbed Shot: 2 s unhasted, school 1
        shown = Hit(52, "nameplate2", "WOUND", 800, 1)
        Check("core: tracked tick shown with its spell", shown and shown.texture == "tex:217200")
        local offPhase = Hit(52.6, "nameplate2", "WOUND", 997, 1)
        Check("core: off-phase physical hit draws '?', no early entry",
            offPhase and offPhase.texture == ns.Meter.UNKNOWN_ICON) -- single mode (spec A)

        -- misses: solo, on the target, recent harmful cast
        _G.MISS = "Miss"
        S.target, S.group = "nameplate3", false
        S.now = 60
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-2", 686)
        shown = Hit(60.5, "nameplate3", "MISS", nil, 32)
        Check("core: miss shown solo on the target with the cast icon", shown and shown.texture == "tex:686" and shown.text == "Miss")
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-3", 686)
        Check("core: miss on a non-target plate hidden", Hit(60.7, "nameplate4", "DODGE", nil, 1) == nil)
        S.group = true
        Check("core: miss in a group hidden", Hit(60.8, "nameplate3", "PARRY", nil, 1) == nil)
        S.group = false

        -- heals: the channel's heal paired with its same-frame tick; others' heals stay hidden
        local ownHeal = Hit(82, "player", "HEAL", 3000, 2)
        Check("crowd: clear, solo: an unnamed heal on you draws '?'; a party member's stays hidden",
            ownHeal and ownHeal.texture == ns.Meter.UNKNOWN_ICON
            and Hit(82.1, "party1", "HEAL", 3000, 2) == nil)
        Check("core: heals on other tokens not drawn", Hit(83, "target", "HEAL", 3000, 2) == nil)
        S.target = "nameplate5"
        S.now = 90
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-4", 234153)
        Core.UNIT_SPELLCAST_CHANNEL_START("player", "Cast-4", 234153)
        shown = Hit(90.4, "nameplate5", "WOUND", 1178, 32)
        Check("core: Drain Life tick shown with its icon", shown and shown.texture == "tex:234153")
        shown = Hit(90.4, "player", "HEAL", 8246, 1)
        Check("core: Drain Life heal paired with the tick of the same frame", shown and shown.kind == "heal" and shown.texture == "tex:234153")
        local unpaired = Hit(90.5, "player", "HEAL", 8246, 1)
        Check("core: heal a frame after the tick not paired (draws '?' while clear)",
            unpaired and unpaired.texture == ns.Meter.UNKNOWN_ICON)
        Core.UNIT_SPELLCAST_CHANNEL_STOP("player", "Cast-4", 234153)

        -- damage taken: always shown, as a number
        shown = Hit(100, "player", "WOUND", 4500, 32)
        Check("core: damage taken shown without an icon", shown and shown.kind == "taken" and shown.texture == nil and shown.text == 4500)
        _G.ABSORB = "Absorb"
        shown = Hit(102, "player", "WOUND", 0, 32, "ABSORB")
        Check("core: fully absorbed hit shows the word", shown and shown.text == "Absorb")
        shown = Hit(103, "player", "WOUND", Secret(4500), Secret(32), Secret(""))
        Check("core: secret damage taken passes through", shown and issecretvalue(shown.text))

        -- in combat the hit's values are secret: the '?' is drawn with them as is
        S.target = "nameplate1"
        shown = Hit(110, "nameplate1", "WOUND", Secret(5000), Secret(32), Secret("CRITICAL"))
        Check("core: secret hit values drawn with '?'", shown and shown.texture == ns.Meter.UNKNOWN_ICON
            and issecretvalue(shown.text)) -- single mode (spec A)
        local okHeal = pcall(Hit, 111, "player", "HEAL", Secret(5000), Secret(2), Secret(""))
        Check("core: secret heal raises no error", okHeal)

        -- disabled: nothing drawn, no meter reset
        SlashCmdList.COMBATTEXTICONS("")
        local resets = S.resets
        Check("core: disabled draws nothing and leaves the meter alone",
            Hit(70, "nameplate1", "WOUND", 5000, 32) == nil and S.resets == resets)
        SlashCmdList.COMBATTEXTICONS("")
    end

    -- Several tracker candidates: "?" when nothing else claims the hit
    do
        local ns = T.BootSpells()
        local S = T.State()
        local Core = ns.Core
        local last
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(plate, texture) last = texture end
        local function Hit(t, unit, amount, school)
            S.now, last = t, nil
            Core.UNIT_COMBAT(unit, "WOUND", "", amount, school)
            return last
        end
        S.haste, S.target = 0, "nameplate1"
        S.now = 100
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-Agony", 980)
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "Cast-Corruption", 172)
        Check("core: a hit fitting two DoTs that nothing else claims draws '?'",
            Hit(104, "nameplate1", 5000, 32) == ns.Meter.UNKNOWN_ICON)
    end

    -- Casts module: the chain route and the sampler are gone --------------------------
    do
        local ns = T.Boot()
        local Casts = ns.Casts
        Check("casts: module exposes NoteCast / Claim / Accept / SoleCast / Flush / Forget", Casts ~= nil
            and type(Casts.NoteCast) == "function" and type(Casts.Claim) == "function"
            and type(Casts.Accept) == "function" and type(Casts.SoleCast) == "function"
            and type(Casts.Flush) == "function" and type(Casts.Forget) == "function")
        Check("casts: no chain route, sampler or mode switch left", Casts.CastsAt == nil and Casts.Chain == nil
            and Casts.Init == nil and Casts.NoteProven == nil and Casts.SetMeterOn == nil)

        for _, file in ipairs({ "Core.lua", "Casts.lua" }) do
            local handle = assert(io.open(T.Root .. "/" .. file, "rb"))
            local source = handle:read("a")
            handle:close()
            local leftover
            for _, name in ipairs({ "castFrames", "NoteHarmfulCast", "HarmfulCastsAt", "ChainCast", "ChainTexture",
                "CHAIN_FIRST", "meterOn" }) do
                if source:find(name, 1, true) then leftover = name end
            end
            Check("casts: " .. file .. " keeps no chain locals" .. (leftover and (" (still has " .. leftover .. ")") or ""),
                not leftover)
        end
    end

    T.RunFile("checks_learn.lua")
    T.RunFile("checks_streams.lua")
    T.RunFile("checks_forever.lua")
    T.RunFile("checks_casts.lua")
    T.RunFile("checks_teacher.lua")
    T.RunFile("checks_procs.lua")
    T.RunFile("checks_panel.lua")
    T.RunFile("checks_progress.lua")
end
