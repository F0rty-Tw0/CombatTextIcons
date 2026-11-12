-- Unit checks for LockedHeals.lua, the Forever heal router (spec 2026-11-05-forever-tick-heal-icons).
-- Called by tests/checks_forever.lua with the same T table.

return function(T)
    local Check, Secret = T.Check, T.Secret
    local function Load(interface)
        return T.Boot(function(S) S.interface = interface or 16001 CombatTextIconsCharDB = {} end)
    end
    -- Stub of ns.Ticks: Fits answers `rig.fits(at)` (a list of { spellID, slot }, default none) and records its args;
    -- Take records; IsOwnCast reads rig.own[id]. The store is at the current rows version, so Init keeps `saved`.
    local function Fresh(interface, saved)
        local ns = Load(interface)
        local store = { lockedHeals = saved, lockedHealsV = 2 }
        local rig = { ns = ns, store = store, taken = {}, fitCalls = {}, own = {}, log = {}, fits = function() return {} end }
        ns.Ticks = {
            Fits = function(key, kind, school, at) rig.fitCalls[#rig.fitCalls + 1] = { key, kind, school, at } return rig.fits(at) end,
            Take = function(id, slot) rig.taken[#rig.taken + 1] = id .. "|" .. slot end,
            IsOwnCast = function(id) return rig.own[id] == true end,
        }
        ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
        ns.LockedHeals.Init(store)
        return rig, ns.LockedHeals
    end
    local function Row(id) return { spellID = id, total = 20, overkill = 0 } end
    local function Has(log, line) for _, text in ipairs(log) do if text == line then return true end end return false end

    do -- Claim: each fit kind alone, two kinds together, several heals on a stamp
        local HOT = { { spellID = 139, slot = "139@10@1" } }
        local heal = { amount = Secret(9) }
        local check

        local rig, H = Fresh()
        check = H.Claim({ 17 }, { heal }, 10, false, true)
        Check("lockedheals claim: one helpful cast on the stamp is a direct fit",
            check[1] == 17 and #rig.taken == 0 and Has(rig.log, "LOCKEDHEAL 17 direct"))

        rig, H = Fresh()
        rig.fits = function() return HOT end
        check = H.Claim({}, { heal }, 10, false, true)
        Check("lockedheals claim: a HoT fit alone names that spell and takes its slot (castIDs empty: 70175.154)",
            check[1] == 139 and rig.taken[1] == "139|139@10@1" and Has(rig.log, "LOCKEDHEAL 139 hot")
            and rig.fitCalls[1][1] == "player" and rig.fitCalls[1][2] == "heal" and rig.fitCalls[1][3] == nil
            and rig.fitCalls[1][4] == 10)

        rig, H = Fresh(nil, { [1260198] = { strikes = 0 } })
        check = H.Claim({}, { heal }, 10, true, true)
        Check("lockedheals claim: one saved proc row, own hit on the stamp: a proc fit",
            check[1] == 1260198 and Has(rig.log, "LOCKEDHEAL 1260198 proc") and #rig.taken == 0)
        check = H.Claim({}, { heal }, 11, false, true)
        Check("lockedheals claim: no own hit on the stamp: no proc fit", check[1] == nil)

        rig, H = Fresh(nil, { [1260198] = { strikes = 0 }, [77] = { strikes = 0 } })
        check = H.Claim({}, { heal }, 10, true, true)
        Check("lockedheals claim: two saved proc rows: no proc fit", check[1] == nil)

        rig, H = Fresh()
        rig.fits = function() return HOT end
        check = H.Claim({ 17 }, { heal }, 10, false, true)
        Check("lockedheals claim: direct 17 and HoT 139 together: no claim, no slot taken",
            check[1] == nil and #rig.taken == 0 and #rig.log == 0)

        rig, H = Fresh()
        rig.fits = function() return HOT end
        check = H.Claim({ 139 }, { heal }, 10, false, true)
        Check("lockedheals claim: direct and HoT naming the same spell count once; the slot is taken",
            check[1] == 139 and #rig.taken == 1 and Has(rig.log, "LOCKEDHEAL 139 direct"))

        rig, H = Fresh()
        check = H.Claim({ 17, 2061 }, { heal }, 10, false, true)
        Check("lockedheals claim: two helpful casts on the stamp are no direct fit", check[1] == nil)

        rig, H = Fresh(nil, { [1260198] = { strikes = 0 } })
        rig.fits = function() return HOT end
        check = H.Claim({}, { heal }, 10, true, true)
        Check("lockedheals claim: HoT and proc together: no claim, no slot taken, no draw counted",
            check[1] == nil and #rig.taken == 0 and #rig.log == 0)

        rig, H = Fresh()
        local taken = false
        rig.fits = function() return taken and {} or HOT end
        rig.ns.Ticks.Take = function() taken = true end
        check = H.Claim({}, { heal, heal }, 10, false, true)
        Check("lockedheals claim: two heals, one HoT slot: the first takes it, the second is no claim",
            check[1] == 139 and check[2] == nil and #rig.fitCalls == 2)

        rig, H = Fresh(120105, { [1260198] = { strikes = 0 } })
        check = H.Claim({ 17 }, { heal }, 10, true, true)
        Check("lockedheals claim: off Forever it claims nothing and asks Ticks nothing",
            next(check) == nil and #rig.fitCalls == 0)

        rig, H = Fresh()
        check = H.Claim({ 17 }, { heal }, 10, false, false)
        Check("lockedheals claim: in a group one helpful cast on the stamp is no direct fit",
            check[1] == nil and #rig.log == 0)

        rig, H = Fresh(nil, { [1260198] = { strikes = 0 } })
        check = H.Claim({}, { heal }, 10, true, false)
        Check("lockedheals claim: in a group an own hit on the stamp is no proc fit", check[1] == nil and #rig.log == 0)

        rig, H = Fresh()
        rig.fits = function() return HOT end
        check = H.Claim({}, { heal }, 10, false, false)
        Check("lockedheals claim: in a group a HoT fit still names its spell (Ticks has no newest casts there)",
            check[1] == 139 and rig.taken[1] == "139|139@10@1")

        local ns = Load()
        ns.Ticks = { Fits = function() return {} end, Take = function() end, IsOwnCast = function() return false end }
        local ok, claimed = pcall(ns.LockedHeals.Claim, { 17 }, { heal }, 10, true, true)
        Check("lockedheals claim: before Init nothing is saved: a call fits no proc and does not error",
            ok and claimed[1] == 17)
    end

    do -- Init, Forget
        local rig, H = Fresh(nil, { [1] = { strikes = 0 }, x = { strikes = 0 }, [2] = { strikes = "a" }, [3] = 5 })
        Check("lockedheals init: keeps a valid entry, drops a non-number key, a bad strikes and a non-table",
            rig.store.lockedHeals[1] ~= nil and rig.store.lockedHeals.x == nil and rig.store.lockedHeals[2] == nil
            and rig.store.lockedHeals[3] == nil)
        H.Forget()
        Check("lockedheals forget: clears the saved rows", next(rig.store.lockedHeals) == nil)
        rig, H = Fresh()
        Check("lockedheals init: a store with no lockedHeals gets an empty table", type(rig.store.lockedHeals) == "table")

        -- rows saved before the damage-row rule (Bone-Apetit, 2026-11-10: Holy Nova 23455/23458 and Cannibalize 20578
        -- beside the drain) never drop, so a store without version 2 is emptied once
        local old = { lockedHeals = { [23455] = { strikes = 0 }, [1260198] = { strikes = 0 } } }
        Load().LockedHeals.Init(old)
        Check("lockedheals init: a store saved before version 2 is emptied and marked version 2",
            next(old.lockedHeals) == nil and old.lockedHealsV == 2)
        local current = { lockedHeals = { [1260198] = { strikes = 1 } }, lockedHealsV = 2 }
        Load().LockedHeals.Init(current)
        Check("lockedheals init: a version 2 store keeps its rows",
            current.lockedHeals[1260198] ~= nil and current.lockedHeals[1260198].strikes == 1 and current.lockedHealsV == 2)
    end

    do -- Learn: rows, strikes, nil reads, secrets, gate
        local PROC, OTHER = 1260198, 77
        local function Drawn(_, H) -- one proc draw: leaves drew[PROC] set
            H.Claim({}, { { amount = Secret(9) } }, 10, true, true)
        end

        local rig, H = Fresh()
        H.Learn({ Row(PROC) }, {}, {}, { Row(PROC) })
        Check("lockedheals learn: a heal row nothing of yours cast that is also a damage row is saved with strikes 0",
            rig.store.lockedHeals[PROC] ~= nil and rig.store.lockedHeals[PROC].strikes == 0 and Has(rig.log, "LOCKEDHEAL row " .. PROC))

        -- Bone-Apetit, 2026-11-10: Holy Nova rank 2 (cast 15430) heals under 23458, which has no damage row
        rig, H = Fresh()
        H.Learn({ Row(23458), Row(PROC) }, {}, { [15430] = true }, { Row(15430), Row(PROC) })
        Check("lockedheals learn: a heal row with no damage row of its ID is no proc row (Holy Nova heal 23458)",
            rig.store.lockedHeals[23458] == nil and rig.store.lockedHeals[PROC] ~= nil)

        rig, H = Fresh()
        H.Learn({ Row(PROC) }, {}, {}, nil)
        H.Learn({ Row(PROC) }, {}, {}, Secret({ Row(PROC) }))
        H.Learn({ Row(PROC) }, {}, {}, { Row(Secret(PROC)), Secret(Row(PROC)) })
        Check("lockedheals learn: a nil or secret damage read, a secret damage row or row ID saves nothing",
            next(rig.store.lockedHeals) == nil)

        rig, H = Fresh()
        H.Learn({ Row(139) }, { helps = { { spellID = 139, at = 5 } } }, {}, { Row(139) })
        Check("lockedheals learn: a row in helps is not saved", next(rig.store.lockedHeals) == nil)
        H.Learn({ Row(591) }, {}, { [591] = true }, { Row(591) })
        Check("lockedheals learn: a row in the harmful cast set is not saved", next(rig.store.lockedHeals) == nil)
        rig.own[17] = true
        H.Learn({ Row(17) }, nil, nil, { Row(17) })
        Check("lockedheals learn: a row Ticks.IsOwnCast knows is not saved; nil helps and cast do not error",
            next(rig.store.lockedHeals) == nil)

        rig, H = Fresh(nil, { [139] = { strikes = 1 } })
        rig.own[139] = true
        H.Learn({ Row(139) }, {}, {})
        Check("lockedheals learn: a saved row that is an own cast is deleted (Renew ticking into the next fight)",
            rig.store.lockedHeals[139] == nil and Has(rig.log, "LOCKEDHEAL drop 139"))

        rig, H = Fresh(nil, { [PROC] = { strikes = 1 } })
        H.Learn({ Row(PROC) }, {}, {})
        Check("lockedheals learn: a saved row not drawn keeps its strikes", rig.store.lockedHeals[PROC].strikes == 1)

        rig, H = Fresh(nil, { [PROC] = { strikes = 1 } })
        Drawn(rig, H)
        H.Learn({ Row(PROC) }, {}, {})
        Check("lockedheals learn: a drawn row present in the read resets strikes to 0", rig.store.lockedHeals[PROC].strikes == 0)

        -- a grouped fight's read changes no saved row (spec 2026-11-12 Saved state)
        local HOT = { { spellID = 139, slot = "139@10@1" } }
        rig, H = Fresh(nil, { [PROC] = { strikes = 0 } })
        local dropped = {}
        rig.ns.Ticks.DropHeal = function(id) dropped[#dropped + 1] = id end
        Drawn(rig, H) -- a proc draw: drew[PROC] ...
        rig.fits = function() return HOT end
        H.Claim({}, { { amount = Secret(9) } }, 103, false, false) -- ... and a HoT draw: hotDrew[139] = 103
        H.Learn({ Row(77) }, { group = true, at = 100, ended = 110 }, {}, { Row(77) })
        Check("lockedheals learn: a grouped read saves no new row, strikes no proc row, drops no HoT",
            rig.store.lockedHeals[77] == nil and rig.store.lockedHeals[PROC].strikes == 0 and #dropped == 0)
        H.Learn({ Row(77) }, { at = 100, ended = 110 }, {})
        Check("lockedheals learn: a grouped read clears the draws, so the next read strikes and drops nothing from them",
            rig.store.lockedHeals[PROC].strikes == 0 and #dropped == 0)
        rig, H = Fresh(nil, { [OTHER] = { strikes = 0 } })
        rig.own[OTHER] = true
        H.Learn({ Row(OTHER) }, { group = true }, {})
        Check("lockedheals learn: a grouped read keeps a saved row that is an own cast", rig.store.lockedHeals[OTHER] ~= nil)
        rig, H = Fresh(nil, { [PROC] = { strikes = 0 } })
        Drawn(rig, H)
        H.Learn({ Row(77) }, { at = 100, ended = 110 }, {})
        Check("lockedheals learn: guard, the same read ungrouped strikes the drawn proc row",
            rig.store.lockedHeals[PROC].strikes == 1)

        rig, H = Fresh(nil, { [PROC] = { strikes = 0 } })
        Drawn(rig, H)
        H.Learn({ Row(OTHER) }, {}, {})
        Check("lockedheals learn: a drawn row absent from a read with rows gets strikes + 1",
            rig.store.lockedHeals[PROC].strikes == 1)

        rig, H = Fresh(nil, { [PROC] = { strikes = 1 } })
        Drawn(rig, H)
        H.Learn({ Row(OTHER) }, {}, {})
        Check("lockedheals learn: the second strike deletes the row", rig.store.lockedHeals[PROC] == nil
            and Has(rig.log, "LOCKEDHEAL drop " .. PROC))

        for _, read in ipairs({ "nil", "empty" }) do
            rig, H = Fresh(nil, { [PROC] = { strikes = 0 } })
            Drawn(rig, H)
            local rows if read == "empty" then rows = {} end -- `x and nil or {}` is always {} in Lua
            H.Learn(rows, {}, {})
            local after = rig.store.lockedHeals[PROC].strikes
            H.Learn({ Row(OTHER) }, {}, {}, { Row(OTHER) })
            Check("lockedheals learn: a " .. read .. " read strikes nothing, saves nothing and clears drew (the next read does not strike)",
                after == 0 and rig.store.lockedHeals[PROC].strikes == 0 and rig.store.lockedHeals[OTHER] ~= nil)
        end

        rig, H = Fresh(nil, { [PROC] = { strikes = 0 } })
        Drawn(rig, H)
        H.Forget()
        rig.store.lockedHeals[PROC] = { strikes = 0 }
        H.Learn({ Row(OTHER) }, {}, {})
        Check("lockedheals forget: clears drew too", rig.store.lockedHeals[PROC].strikes == 0)

        rig, H = Fresh()
        local ok = pcall(H.Learn, Secret({}), {}, {}, { Row(5) })
        local ok2 = pcall(H.Learn, { Row(Secret(5)), Secret(1) }, {}, {}, { Row(5) })
        Check("lockedheals learn: a secret healRows, a secret row ID and a secret row do not error and save nothing",
            ok and ok2 and next(rig.store.lockedHeals) == nil)

        rig, H = Fresh(120105)
        H.Learn({ Row(PROC) }, {}, {}, { Row(PROC) })
        Check("lockedheals learn: off Forever it saves nothing", next(rig.store.lockedHeals) == nil)

        local ns = Load()
        Check("lockedheals learn: before Init it does not error", pcall(ns.LockedHeals.Learn, { Row(PROC) }, {}, {}))
    end

    do -- Learn drops a wrongly learned HoT: S11 run 1 (2026-11-07) drew 7 Devouring Plague self-heals as Touch of
       -- Weakness 19261 (a saved heal period of 3.03), yet the meter's heal rows never listed 19261
        local TOW, DP, FROM, TO = 19261, 2944, 100, 120
        -- Real Ticks on Forever with 19261 saved as a heal HoT and cast at 100; one heal at `at` claimed as a hot draw.
        local function HotDrawn(at)
            local ns = Load()
            T.Store().lockedTicks = { [TOW] = { period = 3.0, kind = "heal", misses = 0 } }
            ns.Ticks.Init(T.Store())
            ns.Ticks.NoteCast(TOW, 100, "player", "heal")
            ns.LockedHeals.Init(T.Store())
            local claims = ns.LockedHeals.Claim({}, { { amount = Secret(9) } }, at, false, true)

            return ns, claims
        end
        local function Saved() return T.Store().lockedTicks[TOW] ~= nil end

        local ns, claims = HotDrawn(103)
        ns.LockedHeals.Learn({ Row(DP) }, { at = FROM, ended = TO }, {})
        Check("lockedheals learn: a HoT drawn in the fight but absent from a read with rows is dropped from Ticks",
            claims[1] == TOW and not Saved())

        ns = HotDrawn(103)
        ns.LockedHeals.Learn({ Row(TOW), Row(DP) }, { at = FROM, ended = TO }, {})
        Check("lockedheals learn: a drawn HoT the read lists is kept", Saved())

        ns = HotDrawn(103)
        ns.LockedHeals.Learn({}, { at = FROM, ended = TO }, {})
        ns.LockedHeals.Learn(nil, { at = FROM, ended = TO }, {})
        Check("lockedheals learn: an empty or nil read drops no HoT", Saved())

        ns = HotDrawn(103)
        ns.LockedHeals.Learn({ Row(DP) }, { at = 104, ended = TO }, {})
        Check("lockedheals learn: a hot draw before the fight window is kept", Saved())
        ns.LockedHeals.Learn({ Row(DP) }, { at = FROM, ended = TO }, {})
        Check("lockedheals learn: the draws clear at every Learn (the next read has none to drop)", Saved())

        ns = HotDrawn(103)
        ns.LockedHeals.Learn({ Row(DP) }, {}, {})
        Check("lockedheals learn: no fight window given: no HoT dropped", Saved())

        ns = HotDrawn(103)
        ns.LockedHeals.Forget()
        ns.LockedHeals.Learn({ Row(DP) }, { at = FROM, ended = TO }, {})
        Check("lockedheals forget: clears the hot draws too", Saved())

        ns = Load()
        T.Store().lockedTicks = { [TOW] = { period = 3.0, kind = "damage", school = 32, misses = 0 } }
        ns.Ticks.Init(T.Store())
        ns.Ticks.DropHeal(TOW)
        Check("ticks dropheal: a damage entry is untouched", Saved())

        ns = Load(120105)
        T.Store().lockedTicks = { [TOW] = { period = 3.0, kind = "heal", misses = 0 } }
        ns.Ticks.Init(T.Store())
        ns.Ticks.DropHeal(TOW)
        Check("ticks dropheal: off Forever it drops nothing", Saved())
    end

    do -- Core wiring
        local PLATE = "nameplate1"
        -- Boots, spies on both Claims (call through), records Display.Player draws and debug lines.
        local function Wired(interface, saved)
            local ns = Load(interface)
            local rig = { ns = ns, S = T.State(), draws = {}, log = {}, claims = 0, heals = 0, args = nil }
            if saved then
                for id, entry in pairs(saved) do T.Store().lockedHeals[id] = entry end
                ns.LockedHeals.Init(T.Store())
            end
            ns.Teacher.area = "clear"
            ns.Display.Plate = function() end
            ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
            ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
            local claim, healsClaim = ns.LockedHeals.Claim, ns.Heals.Claim
            ns.LockedHeals.Claim = function(...) rig.claims = rig.claims + 1 rig.args = { ... } return claim(...) end
            ns.Heals.Claim = function(...) rig.heals = rig.heals + 1 return healsClaim(...) end
            function rig.Heal(at, amount) rig.S.now = at ns.Core.UNIT_COMBAT("player", "HEAL", "", amount, 1) end

            return rig
        end
        local function Texture(id) return (C_Spell.GetSpellTexture(id)) end

        local rig = Wired()
        rig.Heal(10, Secret(9))
        Check("lockedheals wiring: a Forever heal on you waits for its frame's end (nothing drawn yet)", #rig.draws == 0)
        rig.ns.Core.FlushHeals(11)
        Check("lockedheals wiring: Forever FlushHeals asks LockedHeals.Claim once and Heals.Claim never, and an unnamed heal draws ?",
            rig.claims == 1 and rig.heals == 0 and rig.draws[1] and rig.draws[1].texture == rig.ns.Meter.UNKNOWN_ICON
            and rig.args[3] == 10 and rig.args[4] == false and rig.args[5] == true and #rig.args[1] == 0)

        rig = Wired()
        rig.Heal(10, Secret(9))
        rig.S.harmful[17] = false
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", 17) -- the CAST line after the HEAL line, same stamp (70175.154)
        rig.ns.Core.FlushHeals(11)
        Check("lockedheals wiring: a HEAL logged before its own frame's CAST is judged at the frame's end: direct, icon drawn",
            rig.draws[1] and rig.draws[1].texture == Texture(17) and rig.args[1][1] == 17 and #rig.args[1] == 1
            and Has(rig.log, "LOCKEDHEAL 17 direct") and rig.log[#rig.log] == "  -> heal 17")

        rig = Wired()
        rig.S.group = true
        rig.Heal(10, Secret(9))
        rig.S.harmful[17] = false
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", 17)
        rig.ns.Core.FlushHeals(11)
        Check("lockedheals wiring: in a group a heal on your helpful cast's stamp is not yours: solo false, hidden",
            rig.args[5] == false and #rig.draws == 0 and not Has(rig.log, "LOCKEDHEAL 17 direct")
            and rig.log[#rig.log] == "  -> HIDDEN")

        -- Grouped on Forever Blizzard's heal numbers are on: a heal a claim names is tallied but not drawn (it showed
        -- twice); retail draws it.
        local function GroupedNamed(interface)
            local named = Wired(interface)
            named.S.group = true
            named.ns.LockedHeals.Claim = function() return { 17 } end
            named.ns.Heals.Claim = function() return { 17 } end
            named.ns.Heals.AnyLearned = function() return true end
            named.Heal(10, interface and 9 or Secret(9))
            named.ns.Core.FlushHeals(11)

            return named
        end
        local forever, retail = GroupedNamed(), GroupedNamed(120105)
        Check("lockedheals wiring: a named heal in a group draws nothing on Forever (route still heal 17), draws on retail",
            #forever.draws == 0 and forever.log[#forever.log] == "  -> heal 17"
            and retail.draws[1] and retail.draws[1].texture == Texture(17))

        rig = Wired(nil, { [1260198] = { strikes = 0 } })
        rig.S.now = 10
        rig.ns.Core.UNIT_COMBAT(PLATE, "WOUND", "", Secret(31), 32) -- your solo hit on the stamp
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", Secret(9), 1)
        rig.ns.Core.FlushHeals(11)
        Check("lockedheals wiring: a heal on a stamp with your solo hit gets ownAt true: the proc row's icon",
            rig.args[4] == true and rig.draws[#rig.draws] and rig.draws[#rig.draws].texture == Texture(1260198))

        rig = Wired(120105)
        rig.Heal(10, 9)
        Check("lockedheals wiring: retail, nothing learned: a heal draws at once (the AnyLearned gate), no Claim asked",
            #rig.draws == 1 and rig.claims == 0 and rig.heals == 0)

        rig = Wired(120105)
        rig.ns.Heals.AnyLearned = function() return true end
        rig.Heal(10, 9)
        rig.ns.Core.FlushHeals(11)
        Check("lockedheals wiring: retail, a heal learned: it waits and Heals.Claim names it, LockedHeals.Claim is never asked",
            rig.heals == 1 and rig.claims == 0)

        rig = Wired(nil, { [1260198] = { strikes = 0 } })
        SlashCmdList.COMBATTEXTICONS("forget")
        Check("lockedheals wiring: /cti forget clears the saved rows", next(T.Store().lockedHeals) == nil)
        local booted = T.Boot(function(S) S.interface = 16001 CombatTextIconsCharDB = { lockedHeals = { [1260198] = { strikes = 0 } }, lockedHealsV = 2 } end)
        Check("lockedheals wiring: boot hands LockedHeals the saved rows (the proc fit finds the row)",
            booted.LockedHeals.Claim({}, { {} }, 10, true, true)[1] == 1260198)
    end

    do -- Owner heals: per-stamp queue and owned heals (Phase 3)
        local CHANNEL = 234153
        local function Texture(id) return (C_Spell.GetSpellTexture(id)) end
        local function Has(log, line) for _, text in ipairs(log) do if text == line then return true end end return false end
        -- Forever, grouped by default, ns.Owner faked. opts.active = false: Owner off; opts.group = false: solo.
        local function OwnerRig(opts)
            opts = opts or {}
            local ns = Load()
            local rig = { ns = ns, S = T.State(), draws = {}, claims = {}, log = {}, flushes = {}, channelCalls = {},
                ledger = 0, active = opts.active ~= false, heldFrom = nil, owned = {}, channelAt = nil, waiting = false }
            rig.S.group = opts.group ~= false
            ns.Teacher.area = "clear"
            ns.Display.Plate = function() end
            ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
            ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
            ns.Ledger.Add = function() rig.ledger = rig.ledger + 1 end
            ns.Tracker.ChannelHeal = function(now)
                rig.channelCalls[#rig.channelCalls + 1] = now
                return rig.channelAt == now and CHANNEL or nil
            end
            local claim = ns.LockedHeals.Claim
            ns.LockedHeals.Claim = function(casts, heals, at, ownAt, solo)
                rig.claims[#rig.claims + 1] = { at = at, n = #heals, solo = solo }
                return claim(casts, heals, at, ownAt, solo)
            end
            local Owner = ns.Owner
            Owner.IsActive = function() return rig.active end
            Owner.Pending = function(at) return rig.heldFrom ~= nil and rig.heldFrom <= at end -- a hit on a stamp <= at is held
            Owner.HealOwned = function(at, index) return rig.owned[at .. ":" .. index] == true end
            Owner.Flush = function(now, force) rig.flushes[#rig.flushes + 1] = { now = now, force = force } end
            Owner.Waiting = function() return rig.waiting end
            function rig.Heal(at, amount) ns.PlayerHits.Heal("player", "", amount or Secret(9), 1, at) end
            return rig
        end

        local rig = OwnerRig()
        rig.heldFrom = 10 -- stamp 10's hits are held
        rig.Heal(10, Secret(9))
        rig.Heal(10.02, Secret(7)) -- its top FlushHeals(10.02) must not flush stamp 10's heal
        Check("owner heals: a later stamp's heal neither flushes nor relabels the held stamp's heals",
            #rig.claims == 0 and #rig.draws == 0)
        Check("owner heals: HealWaits reads every waiting stamp, not only the newest",
            rig.ns.PlayerHits.HealWaits(10) and rig.ns.PlayerHits.HealWaits(10.02) and not rig.ns.PlayerHits.HealWaits(10.5))
        rig.heldFrom = nil -- the release routed the hits
        rig.ns.PlayerHits.FlushHeals(nil)
        Check("owner heals: once released each stamp claims on its own, oldest first",
            #rig.claims == 2 and rig.claims[1].at == 10 and rig.claims[1].n == 1
            and rig.claims[2].at == 10.02 and rig.claims[2].n == 1)

        rig = OwnerRig()
        rig.Heal(10, Secret(9))
        rig.Heal(10.02, Secret(7))
        rig.heldFrom = 10.02 -- only the newer stamp's hits are held
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: the stop rule flushes the older stamp and keeps the pending one",
            #rig.claims == 1 and rig.claims[1].at == 10 and rig.ns.PlayerHits.HealWaits(10.02)
            and not rig.ns.PlayerHits.HealWaits(10))

        rig = OwnerRig({ active = false })
        rig.Heal(10, Secret(9))
        rig.Heal(10.02, Secret(7)) -- guard: nothing held, so a later stamp's heal still flushes the earlier one at once
        Check("owner heals: guard, nothing held: a heal on a later stamp flushes the earlier stamp as today",
            #rig.claims == 1 and rig.claims[1].at == 10)

        rig = OwnerRig()
        rig.waiting = true
        rig.Heal(10, Secret(9))
        local timers = rig.S.timers
        local queued, run = #timers, timers[#timers].fn
        rig.S.now = 10.04
        run()
        local last = rig.flushes[#rig.flushes]
        Check("owner heals: the queued flush calls Owner.Flush(GetTime()) first and re-queues while Owner waits",
            last and last.now == 10.04 and last.force == nil and #timers == queued + 1 and #rig.claims == 1)

        -- an owned heal on a lone helpful cast: direct fit, icon grouped; unowned: nothing
        rig = OwnerRig()
        rig.owned["10:1"] = true
        rig.Heal(10, Secret(9))
        rig.ns.PlayerHits.NoteHelpful(17, 10)
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: an owned heal on your helpful cast draws its icon grouped, Claim solo",
            #rig.draws == 1 and rig.draws[1].texture == Texture(17) and rig.claims[1].solo == true
            and rig.log[#rig.log] == "  -> heal 17")
        rig = OwnerRig()
        rig.Heal(10, Secret(9))
        rig.ns.PlayerHits.NoteHelpful(17, 10)
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: an unowned heal draws nothing, Claim not solo, route HIDDEN",
            #rig.draws == 0 and rig.claims[1].solo == false and rig.log[#rig.log] == "  -> HIDDEN")

        -- two heals, the second owned: two Claims (owned first), claims map back by index
        rig = OwnerRig()
        rig.owned["10:2"] = true
        rig.Heal(10, Secret(9))
        rig.Heal(10, Secret(8))
        rig.ns.PlayerHits.NoteHelpful(17, 10)
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: owned and unowned heals claim apart; the owned second heal gets the cast's icon",
            #rig.claims == 2 and rig.claims[1].solo == true and rig.claims[1].n == 1
            and rig.claims[2].solo == false and rig.claims[2].n == 1
            and #rig.draws == 1 and rig.draws[1].texture == Texture(17) and Has(rig.log, "  -> HIDDEN")
            and rig.log[#rig.log] == "  -> heal 17")

        -- nothing names an owned heal: '?'; an unowned one draws nothing
        rig = OwnerRig()
        rig.owned["10:2"] = true
        rig.Heal(10, Secret(9))
        rig.Heal(10, Secret(8))
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: an unnamed owned heal draws '?', the unowned one beside it nothing",
            #rig.draws == 1 and rig.draws[1].texture == rig.ns.Meter.UNKNOWN_ICON
            and rig.log[#rig.log] == "  -> unknown-solo")

        -- channel heal: the tick is still held at arrival, so no arrival-time ask; asked at flush
        rig = OwnerRig()
        rig.owned["10:1"] = true
        rig.Heal(10, Secret(5))
        Check("owner heals: with Owner on a heal skips the arrival Tracker.ChannelHeal ask and waits",
            #rig.channelCalls == 0 and #rig.draws == 0)
        rig.channelAt = 10 -- the tick was routed at the release
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: an owned channel heal draws the tick's icon at flush, no Claim, Ledger counts it",
            #rig.draws == 1 and rig.draws[1].texture == Texture(CHANNEL) and #rig.claims == 0
            and rig.ledger == 1 and rig.log[#rig.log] == "  -> channel")
        rig = OwnerRig()
        rig.Heal(10, Secret(5))
        rig.channelAt = 10
        rig.ns.PlayerHits.FlushHeals(11)
        Check("owner heals: an unowned channel heal draws nothing, no Claim, no Ledger entry",
            #rig.draws == 0 and #rig.claims == 0 and rig.ledger == 0)

        -- guard: Owner off, solo: a channel heal draws at arrival as today
        rig = OwnerRig({ active = false, group = false })
        rig.channelAt = 10
        rig.Heal(10, Secret(5))
        Check("owner heals: guard, Owner off: the channel heal draws at arrival", #rig.draws == 1 and #rig.channelCalls == 1)

        -- End to end with the real Owner: the Owner-on twin of checks_forever.lua "drain: grouped -> no plate draw for
        -- the hit". A shadow hit and its heal share stamp 100, two live lines own both, the wand cast forces the release.
        local DRAIN, WAND = 1260198, 5019
        local real = T.Boot(function(S)
            S.interface = 16001
            S.group = true
            S.harmful[2652], S.harmful[19261] = false, false
            CombatTextIconsCharDB = { lockedHealsV = 2, lockedHeals = { [DRAIN] = { strikes = 0 } },
                lockedSchools = { [589] = { school = 32, strays = 0 } } }
        end)
        local State, Core, Owner = T.State(), real.Core, real.Owner
        IsInRaid = function() return false end
        C_CombatLog = { AreFilteredEventsEnabled = function() return true end, SetFilteredEventsEnabled = function() end }
        Blizzard_CombatLog_Filters = { currentFilter = 1, filters = { { name = "My actions" } } }
        COMBATLOG = { IsShown = function() return false end }
        local plateTexture, healDrawn
        real.Teacher.area = "clear"
        real.Display.Plate = function(_, texture) plateTexture = texture end
        real.Display.Player = function(kind) if kind == "heal" then healDrawn = true end end
        real.Debug = function() end
        Check("owner heals: precondition, the real Owner is active in the grouped Forever rig",
            Owner.KeepLinesOn() ~= nil and Owner.Active() == true)
        State.now = 100
        Core.UNIT_COMBAT("nameplate1", "WOUND", "", Secret(31), 32)
        Core.UNIT_COMBAT("player", "HEAL", "", Secret(9), 1)
        Owner.Line(0, 100)
        Owner.Line(0, 100)
        State.now = 100.2
        Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", WAND)
        Check("owner heals: grouped drain with the real Owner draws the claimed row on the plate and the heal",
            plateTexture == Texture(DRAIN) and healDrawn == true)
        IsInRaid, C_CombatLog, Blizzard_CombatLog_Filters, COMBATLOG = nil, nil, nil, nil
    end
end
