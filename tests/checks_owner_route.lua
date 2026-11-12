-- Checks for the owned hits' route (Owner -> HitRoute.Route): what Wound does with a hit Owner released. Called by
-- tests/checks.lua with the same T table. Every scenario boots its own rig (tests/owner_rig.lua); a Boot replaces the
-- global stubs.
return function(T)
    local Check, Secret = T.Check, T.Secret
    local Rig, SWP, P = dofile(T.Root .. "/tests/owner_rig.lua")(T)

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

    -- Routes a released SW:P tick stamped `at` while the game clock reads at + 0.05; the route clock is set to `at`
    -- when `clock`. Returns the spellID on the frame entry at `at`, the `now` Teacher.Drawn and Heals.Struck got, `at`.
    local function Released(clock)
        local rig = Rig()
        local drewAt, struckAt
        local Drawn, Struck = rig.ns.Teacher.Drawn, rig.ns.Heals.Struck
        rig.ns.Teacher.Drawn = function(spellID, amount, now, school)
            drewAt = now

            return Drawn(spellID, amount, now, school)
        end
        rig.ns.Heals.Struck = function(spellID, now)
            struckAt = now

            return Struck(spellID, now)
        end
        rig.Cast(100, "nameplate1")
        local at = 100 + P
        rig.S.now = at + 0.05
        if clock then rig.ns.SetRouteClock(at) end
        rig.Route(rig.Snap(at, "nameplate1", 31, 32, true))
        rig.ns.SetRouteClock(nil)
        local entry = rig.ns.HitRoute.FrameHits(at)[1]

        return entry and entry.spellID, drewAt, struckAt, at
    end

    -- 2. A released hit is judged at its own stamp
    do
        local tagged, drewAt, struckAt, at = Released(true)
        Check("route clock: a released hit's Drawn tags its own frame entry", tagged == SWP)
        Check("route clock: Teacher.Drawn and Heals.Struck get the hit's stamp, not the release time",
            drewAt == at and struckAt == at)
        tagged, drewAt = Released(false)
        Check("route clock: with no clock set Drawn still reads the game clock (the release time misses the entry)",
            tagged == nil and drewAt ~= at)
        local source = assert(io.open(T.Root .. "/HitRoute.lua", "rb")):read("a")
        Check("route clock: HitRoute.lua reads no GetTime of its own", not source:find("GetTime", 1, true))
    end
end
