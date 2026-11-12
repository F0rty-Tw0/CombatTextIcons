-- Checks for the owned hits' route (Owner -> HitRoute.Route): what Wound does with a hit Owner released. Called by
-- tests/checks.lua with the same T table. Every scenario boots its own rig; a Boot replaces the global stubs.
return function(T)
    local Check, Secret = T.Check, T.Secret
    local SWP, P = 594, 3.011735764150819 -- Shadow Word: Pain as learned in game (school 32)

    -- Forever with SW:P learned. Grouped unless opts.solo. Owner stubbed active (rig.on; opts.off starts inactive).
    -- Unless opts.realOwner, Owner.Hit only records its packed arguments in rig.taken. opts.setup(S) runs before load.
    local function Rig(opts)
        opts = opts or {}
        local rig = { draws = {}, log = {}, taken = {}, on = opts.off ~= true }
        rig.ns = T.Boot(function(S)
            S.interface = 16001
            S.group = opts.solo ~= true
            CombatTextIconsCharDB = { learned = { [SWP] = { school = 32, kind = "dot", period = P, misses = 0 } } }
            if opts.setup then opts.setup(S) end
        end)
        rig.S = T.State()
        local ns, S = rig.ns, rig.S
        ns.Teacher.area = "clear"
        ns.Display.Plate = function(plate, texture) rig.draws[#rig.draws + 1] = { plate = plate, texture = texture } end
        ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
        ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
        ns.Owner.Active = function() return rig.on end
        ns.Owner.IsActive = function() return rig.on end
        if not opts.realOwner then ns.Owner.Hit = function(...) rig.taken[#rig.taken + 1] = table.pack(...) end end

        -- The plate the client holds for `unit`.
        function rig.Plate(unit) return C_NamePlate.GetNamePlateForUnit(unit) end

        -- Casts `spellID` (SW:P by default) at `t` aimed at `unit`.
        function rig.Cast(t, unit, spellID)
            S.now, S.target = t, unit
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", spellID or SWP)
        end

        -- A WOUND event on `unit` at `t`, as the client sends it; returns the texture drawn or nil.
        function rig.Hit(t, unit, amount, school, flag)
            S.now = t
            local before = #rig.draws
            ns.Core.UNIT_COMBAT(unit, "WOUND", flag or "", amount or 31, school or 32)

            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        -- A hit as Owner releases it.
        function rig.Snap(t, unit, amount, school, isTarget)
            return { kind = "hit", plate = rig.Plate(unit), unit = unit, flagText = "", amount = amount, school = school,
                now = t, isTarget = isTarget, owned = true }
        end

        -- The texture HitRoute.Route draws for a released hit, or nil when it stayed hidden.
        function rig.Route(hit)
            local before = #rig.draws
            ns.HitRoute.Route(hit)

            return #rig.draws > before and rig.draws[#rig.draws].texture or nil
        end

        -- Whether a debug line starts with `prefix`.
        function rig.Logged(prefix)
            for _, line in ipairs(rig.log) do
                if line:sub(1, #prefix) == prefix then return true end
            end

            return false
        end

        -- The last route line ("  ->") of the debug log.
        function rig.LastRoute()
            for index = #rig.log, 1, -1 do
                if rig.log[index]:find("^  %->") then return rig.log[index] end
            end
        end

        return rig
    end

    -- What Teacher.Seen gets as its isTarget when a snapshot saying `isTarget` is routed while the unit token answers
    -- `targetNow` (the unit the player targets, or nil).
    local function SeenTarget(isTarget, targetNow)
        local rig = Rig()
        local seen
        local Seen = rig.ns.Teacher.Seen
        rig.ns.Teacher.Seen = function(amount, now, school, plate, target)
            seen = target

            return Seen(amount, now, school, plate, target)
        end
        rig.S.target = targetNow
        rig.Route(rig.Snap(300, "nameplate1", Secret(31), 32, isTarget))

        return seen
    end

    -- 1. Owned hits go through Wound as solo
    do
        local rig = Rig()
        local amount = Secret(31)
        rig.S.target = "nameplate1"
        rig.Hit(100, "nameplate1", amount, 32, "CRITICAL")
        local args = rig.taken[1]
        Check("owner route: an active Owner takes a plate WOUND at arrival, with Owner.Hit's arguments",
            #rig.taken == 1 and args[1] == rig.Plate("nameplate1") and args[2] == "nameplate1" and args[3] == "CRITICAL"
            and rawequal(args[4], amount) and args[5] == 32 and args[6] == 100)
        Check("owner route: Wound has not run for it (no frame entry, no draw, no HIT line)",
            #rig.ns.HitRoute.FrameHits(100) == 0 and #rig.draws == 0 and not rig.Logged("HIT "))

        rig = Rig()
        rig.ns.Core.UNIT_COMBAT("nameplate1", "MISS", "", 0, 0)
        Check("owner route: a miss never goes to Owner", #rig.taken == 0)

        rig = Rig({ off = true })
        rig.Hit(100, "nameplate1", Secret(31), 32)
        Check("owner route: an inactive Owner leaves the hit to Wound, which draws nothing grouped",
            #rig.taken == 0 and rig.Logged("HIT nameplate1") and #rig.draws == 0 and rig.LastRoute() == "  -> HIDDEN")

        -- an owned grouped tracker tick draws what the same hit draws solo
        rig = Rig()
        rig.Cast(100, "nameplate1")
        rig.S.now = 100 + P + 0.05
        local owned = rig.Route(rig.Snap(100 + P, "nameplate1", 31, 32, true))
        local solo = Rig({ solo = true, off = true })
        solo.Cast(100, "nameplate1")
        solo.Hit(100 + P, "nameplate1", 31, 32)
        Check("owner route: an owned grouped tracker tick draws SW:P, as solo",
            owned == "tex:" .. SWP and solo.draws[1] and solo.draws[1].texture == "tex:" .. SWP)

        rig = Rig()
        rig.S.threat.nameplate3 = false -- a mob that does not fight you: still yours once owned
        local question = rig.Route(rig.Snap(200, "nameplate3", Secret(31), 1, false))
        Check("owner route: an owned grouped hit nothing names draws '?' (route unknown-solo)",
            question == rig.ns.Meter.UNKNOWN_ICON and rig.LastRoute() == "  -> unknown-solo")

        rig = Rig()
        rig.S.threat.nameplate3 = false
        local counted = 0
        local Seen = rig.ns.Teacher.Seen
        rig.ns.Teacher.Seen = function(...)
            counted = counted + 1

            return Seen(...)
        end
        rig.Route(rig.Snap(200, "nameplate3", Secret(31), 1, false))
        Check("owner route: an owned hit counts for the crowd check though its mob has no threat on you", counted == 1)

        rig = Rig()
        rig.Cast(100, "nameplate1")
        rig.on = false
        Check("owner route: an owned hit routed after Owner turned inactive draws nothing",
            rig.Route(rig.Snap(100 + P, "nameplate1", 31, 32, true)) == nil)

        rig = Rig({ solo = true })
        rig.S.now = 50
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        local startedSolo = rig.ns.Teacher.fight.group == false
        rig.S.group = true
        rig.Route(rig.Snap(51, "nameplate1", Secret(31), 32, true))
        Check("owner route: an owned hit still marks the fight grouped (Teacher.Grouped)",
            startedSolo and rig.ns.Teacher.fight.group == true)

        Check("owner route: Teacher.Seen gets the snapshot's isTarget, not the unit token's answer at release",
            SeenTarget(true, nil) == true and SeenTarget(false, "nameplate1") == false)

        rig = Rig()
        rig.Route(rig.Snap(300, "nameplate1", Secret(31), 32, true))
        Check("owner route: Wound writes no HIT line for an owned hit", not rig.Logged("HIT "))

        -- the full path with the real Owner: Core -> Owner.Hit (held) -> line -> release -> solo route
        rig = Rig({ realOwner = true })
        rig.Cast(100, "nameplate1")
        rig.Hit(100 + P, "nameplate1", Secret(31), 32)
        rig.ns.Owner.Line(0, 100 + P)
        rig.S.now = 100 + P + 0.06
        rig.ns.Owner.Flush(100 + P + 0.06)
        local viaOwner = rig.draws[#rig.draws] and rig.draws[#rig.draws].texture
        Check("owner route: an owned grouped hit draws a learned cast as solo",
            viaOwner == "tex:" .. SWP and viaOwner == solo.draws[1].texture)
    end
end
