-- Checks that Core, BlizzardText and PlayerHits wire Owner in (Core.lua, BlizzardText.lua, PlayerHits.lua). Called by
-- tests/checks.lua with the same T table.
return function(T)
    local Check = T.Check
    local Rig, SWP = dofile(T.Root .. "/tests/owner_rig.lua")(T)

    -- Registers the frames CreateFrame makes in rec.frames, each keeping the events it registered in .registered. The
    -- event `failEvent` raises an error when registered, as the client does for an event it does not know.
    local function RecordFrames(rec, failEvent)
        local make = CreateFrame
        rec.frames = {}
        local function Register(frame, event)
            if event == failEvent then error("unknown event " .. event) end
            frame.registered[event] = true
        end
        CreateFrame = function(...)
            local frame = make(...)
            frame.registered, frame.RegisterEvent, frame.RegisterUnitEvent = {}, Register, Register
            rec.frames[#rec.frames + 1] = frame

            return frame
        end
    end

    -- The frame Core registered its events on.
    local function CoreFrame(rec)
        for _, frame in ipairs(rec.frames) do
            if frame.registered.PLAYER_LOGIN then return frame end
        end
    end

    -- A Rig whose Owner, Core, TowHold, Locked and Ticks entry points record each call in rig.calls as
    -- { name, args... } (Owner.Active and Owner.Waiting answer rig.on and rig.waiting; KeepLinesOn runs on). The
    -- PlayerHits and HitRoute flush entry points QueueFlush calls are "QueueHeals" and "QueueMates".
    local function Wired(opts)
        local rig = Rig(opts)
        local ns = rig.ns
        rig.calls, rig.waiting = {}, false

        local function Spy(owner, field, name, answer, through)
            local original = owner[field]
            owner[field] = function(...)
                rig.calls[#rig.calls + 1] = table.pack(name, ...)
                if answer then return answer() end
                if through then return original(...) end
            end
        end
        for _, field in ipairs({ "Flush", "Heal", "Cast", "LinesOff", "PlateGone", "Drop", "Line" }) do
            Spy(ns.Owner, field, field)
        end
        Spy(ns.Owner, "KeepLinesOn", "KeepLinesOn", nil, true)
        Spy(ns.Owner, "Active", "Active", function() return rig.on end)
        Spy(ns.Owner, "Waiting", "Waiting", function() return rig.waiting end)
        Spy(ns.Core, "FlushHeals", "FlushHeals")
        Spy(ns.Core, "FlushMates", "FlushMates")
        Spy(ns.Core, "Heal", "CoreHeal")
        Spy(ns.Core, "SyncBlizzard", "SyncBlizzard")
        Spy(ns.PlayerHits, "FlushHeals", "QueueHeals")
        Spy(ns.HitRoute, "FlushMates", "QueueMates")
        Spy(ns.TowHold, "Decide", "Decide")
        Spy(ns.Locked, "NoteCast", "NoteCast")
        Spy(ns.Ticks, "NoteCast", "TickCast")

        -- The index of the first call named `name`.
        function rig.Index(name)
            for index, call in ipairs(rig.calls) do
                if call[1] == name then return index end
            end
        end

        -- Whether the first call named `first` comes before the first named `second`.
        function rig.Before(first, second)
            local a, b = rig.Index(first), rig.Index(second)

            return a ~= nil and b ~= nil and a < b
        end

        function rig.Call(name) return rig.calls[rig.Index(name)] end

        function rig.Count(name)
            local count = 0
            for _, call in ipairs(rig.calls) do
                if call[1] == name then count = count + 1 end
            end

            return count
        end

        return rig
    end

    do
        local rig = Wired()
        rig.S.now = 100
        rig.ns.Core.UNIT_COMBAT("nameplate1", "WOUND", "", 31, 32)
        local flush = rig.Call("Flush")
        Check("wiring: UNIT_COMBAT flushes Owner before the heals",
            flush and flush[2] == 100 and flush[3] == nil and rig.Before("Flush", "FlushHeals")
            and rig.Before("Flush", "FlushMates") and rig.Before("Flush", "Decide"))

        rig = Wired()
        rig.S.now = 100
        rig.ns.Core.UNIT_COMBAT("party2", "HEAL", "", 50, 2)
        local healCall = rig.Call("Heal")
        rig.ns.Core.UNIT_COMBAT("player", "HEAL", "", 50, 2)
        Check("wiring: a HEAL on party2 is fed to Owner.Heal(unit, now) while Active",
            healCall and healCall[2] == "party2" and healCall[3] == 100 and rig.Before("Heal", "CoreHeal")
            and rig.Count("Heal") == 2 and rig.calls[rig.Index("CoreHeal") - 1][1] == "Heal")

        rig = Wired({ off = true })
        rig.S.now = 100
        rig.ns.Core.UNIT_COMBAT("party2", "HEAL", "", 50, 2)
        Check("wiring: no Owner.Heal feed while Owner is inactive", rig.Count("Heal") == 0 and rig.Count("CoreHeal") == 1)

        rig = Wired()
        rig.Cast(100, "nameplate1")
        local forced = rig.Call("Flush")
        Check("wiring: a player cast flushes Owner with force before FlushHeals/FlushMates/TowHold.Decide",
            forced and forced[2] == 100 and forced[3] == true and rig.Before("Flush", "FlushHeals")
            and rig.Before("Flush", "FlushMates") and rig.Before("Flush", "Decide") and rig.Before("Flush", "NoteCast"))

        Check("wiring: a harmful player cast calls Owner.Cast once, with no argument",
            rig.Count("Cast") == 1 and rig.Call("Cast").n == 1)
        rig.S.harmful[139] = false
        rig.Cast(101, "nameplate1", 139)
        rig.ns.Core.UNIT_SPELLCAST_SUCCEEDED("pet", "c", SWP)
        Check("wiring: neither a helpful player cast nor a pet cast calls Owner.Cast", rig.Count("Cast") == 1)

        -- the tick keys: the plate and "player" while Owner is active, nil grouped and inactive, as before solo
        local function Keys(options)
            local keyed = Wired(options)
            keyed.S.harmful[139] = false
            keyed.Cast(100, "nameplate1")
            keyed.Cast(101, "nameplate1", 139)
            local harmful, helpful = keyed.calls[keyed.Index("TickCast")], nil
            for index = keyed.Index("TickCast") + 1, #keyed.calls do
                if keyed.calls[index][1] == "TickCast" then helpful = keyed.calls[index] end
            end

            return harmful, helpful, keyed.Plate("nameplate1")
        end
        local harmful, helpful, plate = Keys()
        local idleHarmful, idleHelpful = Keys({ off = true })
        local soloHarmful, soloHelpful, soloPlate = Keys({ solo = true, off = true })
        Check("wiring: grouped with Owner active the tick key is the plate; inactive it stays nil",
            harmful[4] == plate and harmful[5] == "damage" and helpful[4] == "player" and helpful[5] == "heal"
            and idleHarmful[4] == nil and idleHarmful[5] == "damage" and idleHelpful[4] == nil
            and idleHelpful[5] == "heal" and soloHarmful[4] == soloPlate and soloHelpful[4] == "player")

        rig = Wired()
        rig.S.now = 100
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        local startOrder = rig.Before("KeepLinesOn", "Active")
        local startCalls = #rig.calls
        rig.calls = {}
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        local endFlush = rig.Call("Flush")
        Check("wiring: PLAYER_REGEN_DISABLED on Forever calls KeepLinesOn then Active; PLAYER_REGEN_ENABLED calls Flush(nil) then Active",
            startOrder and startCalls == 2 and endFlush and endFlush[2] == nil and endFlush.n == 2
            and rig.Before("Flush", "Active") and rig.Before("Active", "SyncBlizzard")
            and rig.Before("Active", "FlushHeals"))

        rig = Wired()
        rig.S.now = 100
        rig.ns.Core.GROUP_ROSTER_UPDATE()
        local rosterFlush = rig.Call("Flush")
        Check("wiring: GROUP_ROSTER_UPDATE calls Flush(nil), KeepLinesOn, Active in that order",
            rosterFlush and rosterFlush[2] == nil and rosterFlush.n == 2 and rig.Before("Flush", "KeepLinesOn")
            and rig.Before("KeepLinesOn", "Active") and rig.Before("Active", "SyncBlizzard"))

        rig = Wired()
        rig.ns.Core.PLAYER_LOGIN()
        Check("wiring: PLAYER_LOGIN on Forever calls KeepLinesOn before SyncBlizzard",
            rig.Before("KeepLinesOn", "SyncBlizzard") and rig.Count("KeepLinesOn") == 1)

        -- retail never switches the Combat Log lines; the same events on Forever do (the control)
        local clog
        local function Lines(interface)
            clog = {}
            local lines = Wired({ interface = interface, setup = function() T.CombatLogLive(clog) end })
            clog.setCalls, clog.on = {}, false -- the boot may have switched them on; count only the events below
            lines.ns.Core.GROUP_ROSTER_UPDATE()
            lines.ns.Core.PLAYER_REGEN_DISABLED()
            lines.ns.Core.PLAYER_LOGIN()
            lines.Cast(100, "nameplate1")

            return lines
        end
        local retail = Lines(120105)
        local retailSet = #clog.setCalls
        local forever = Lines(16001)
        T.CombatLogClear()
        Check("wiring: on retail GROUP_ROSTER_UPDATE and PLAYER_REGEN_DISABLED never call KeepLinesOn (the C_CombatLog.SetFilteredEventsEnabled stub is not called)",
            retail.Count("KeepLinesOn") == 0 and retailSet == 0 and forever.Count("KeepLinesOn") == 3 and #clog.setCalls > 0)

        Check("wiring: on retail a player cast never calls Owner.Cast (no cast count, no check timer)",
            retail.Count("Cast") == 0 and forever.Count("Cast") == 1)

        rig = Wired()
        rig.S.now = 100
        CombatTextIconsDB.enabled = false
        rig.ns.Core.GROUP_ROSTER_UPDATE()
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.ns.Core.PLAYER_LOGIN()
        Check("wiring: a disabled addon never switches the Combat Log lines on", rig.Count("KeepLinesOn") == 0)

        rig = Wired()
        rig.ns.Core.NAME_PLATE_UNIT_REMOVED("nameplate1")
        local gone = rig.Call("PlateGone")
        Check("wiring: NAME_PLATE_UNIT_REMOVED calls Owner.PlateGone(plate)",
            rig.Count("PlateGone") == 1 and gone[2] == rig.Plate("nameplate1"))

        rig = Wired()
        rig.ns.Core.PLAYER_LOGOUT()
        Check("wiring: PLAYER_LOGOUT calls Owner.LinesOff", rig.Count("LinesOff") == 1)

        rig = Wired()
        SlashCmdList.COMBATTEXTICONS("off")
        Check("wiring: /cti off calls Owner.Drop then Owner.LinesOff",
            rig.Count("Drop") == 1 and rig.Count("LinesOff") == 1 and rig.Before("Drop", "LinesOff"))

        rig = Wired()
        rig.S.now = 100
        local ok = pcall(function() rig.ns.Core.COMBAT_LOG_MESSAGE("You hit", 1, 1, 1, 0) end)
        local line = rig.Call("Line")
        SlashCmdList.COMBATTEXTICONS("off")
        rig.calls = {}
        local offOk = pcall(function() rig.ns.Core.COMBAT_LOG_MESSAGE("You hit", 1, 1, 1, 0) end)
        Check("wiring: COMBAT_LOG_MESSAGE hands Owner.Line(order, GetTime()); a disabled addon hands it nothing",
            ok and line and line[2] == 0 and line[3] == 100 and offOk and rig.Count("Line") == 0)

        local rec = {}
        rig = Wired({ setup = function() RecordFrames(rec) end })
        local core = CoreFrame(rec)
        rig.S.now = 100
        pcall(core.scripts.OnEvent, core, "COMBAT_LOG_MESSAGE", "You hit", 1, 1, 1, 0)
        local sourceCore = assert(io.open(T.Root .. "/Core.lua", "rb")):read("a")
        Check("wiring: the addon registers COMBAT_LOG_MESSAGE (CreateFrame recorder) and keeps GROUP_ROSTER_UPDATE",
            core.registered.COMBAT_LOG_MESSAGE and core.registered.GROUP_ROSTER_UPDATE and rig.Count("Line") == 1
            and sourceCore:find('RegisterEvent("GROUP_ROSTER_UPDATE")', 1, true) ~= nil)

        rec = {}
        local loaded, failed = pcall(Wired, { setup = function() RecordFrames(rec, "COMBAT_LOG_MESSAGE") end })
        core = CoreFrame(rec)
        Check("wiring: a client without COMBAT_LOG_MESSAGE still loads and registers the other events",
            loaded and failed ~= nil and core ~= nil and not core.registered.COMBAT_LOG_MESSAGE
            and core.registered.GROUP_ROSTER_UPDATE and core.registered.UNIT_COMBAT)

        -- the frame callback QueueFlush queues
        rig = Wired()
        rig.S.now = 100
        rig.S.timers = {}
        rig.ns.PlayerHits.QueueFlush()
        local queued = #rig.S.timers
        rig.S.timers[1].fn()
        local flushCall = rig.Call("Flush")
        local idle = #rig.S.timers == 1
        rig.waiting = true
        rig.S.timers[1].fn()
        Check("wiring: QueueFlush callback flushes Owner then re-queues while Owner.Waiting()",
            queued == 1 and flushCall and flushCall[2] == 100 and flushCall.n == 2 and rig.Before("Flush", "QueueHeals")
            and rig.Before("QueueHeals", "QueueMates") and idle and #rig.S.timers == 2)

        -- the CVar Blizzard's own numbers use: "0" in addon mode, the player's value in blizzard mode
        local cvar = "floatingCombatTextCombatDamage_v2"
        local function Mode(options)
            options.setup = function(S) S.cvars[cvar] = "1" end

            return Rig(options)
        end
        rig = Mode({})
        local bootedGrouped = rig.S.cvars[cvar]
        rig.on = true
        rig.ns.BlizzardText.Sync()
        local whileActive = rig.S.cvars[cvar]
        rig.on = false
        rig.ns.BlizzardText.Sync()
        local afterwards = rig.S.cvars[cvar]
        local soloMode = Mode({ solo = true, off = true })
        Check("wiring: BlizzardText mode is 'addon' in a Forever group while Owner.IsActive, 'blizzard' when not",
            bootedGrouped == "1" and whileActive == "0" and afterwards == "1" and soloMode.S.cvars[cvar] == "0")
    end

    -- Owner holds a hit of nameplate1 (the target) and, unless `single`, one of nameplate2, both stamped 100, and has
    -- one line at 100. rig.routes counts HitRoute.Route; rig.order lists the Route and NoteCast calls.
    local function Held(single)
        local rig = Rig({ realOwner = true })
        rig.routes, rig.order = 0, {}
        local Route, NoteCast = rig.ns.HitRoute.Route, rig.ns.Locked.NoteCast
        rig.ns.HitRoute.Route = function(hit)
            rig.routes = rig.routes + 1
            rig.order[#rig.order + 1] = "Route"

            return Route(hit)
        end
        rig.ns.Locked.NoteCast = function(...)
            rig.order[#rig.order + 1] = "NoteCast"

            return NoteCast(...)
        end
        rig.S.target = "nameplate1"
        rig.Hit(100, "nameplate1", 31, 32)
        if not single then rig.Hit(100, "nameplate2", 31, 32) end
        rig.ns.Owner.Line(0, 100)

        return rig
    end

    do
        local rig = Held()
        rig.Cast(100.02, "nameplate1")
        Check("owner wiring: a cast 0.02 s after a held hit routes the hit before the cast is noted",
            rig.routes == 1 and rig.order[1] == "Route" and rig.order[2] == "NoteCast")

        local control = Held(true)
        control.ns.Owner.Flush(nil)
        rig = Held(true)
        SlashCmdList.COMBATTEXTICONS("off")
        rig.ns.Owner.Flush(nil)
        Check("owner wiring: /cti off with hits held routes none",
            control.routes == 1 and rig.routes == 0 and not rig.ns.Owner.Waiting())

        rig = Held(true)
        rig.ns.Core.NAME_PLATE_UNIT_REMOVED("nameplate1")
        rig.ns.Owner.Flush(nil)
        Check("owner wiring: a plate removed before release routes none of its hits",
            control.routes == 1 and rig.routes == 0)
    end
end
