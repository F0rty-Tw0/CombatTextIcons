-- Replay gate for Core's hit route over a Forever capture: each CAST and HIT line goes through Core's own handlers, so
-- the tracker route (Tracker.Identify) runs as in game, unlike the Locked-only replays in checks_ticks_replay.lua.
-- Called by tests/checks_forever.lua with the same T table.

return function(T)
    local Check = T.Check
    local SWP, ReadMeter = T.SWP_RANKS, T.ReadMeter
    -- The helpful casts of the captures (Lesser Heal, Heal, Touch of Weakness, Inner Fire, PW:S, Renew): every other
    -- cast is harmful, as the harness answers by default.
    local HELPFUL = { 139, 17, 600, 2053, 2054, 2652, 588, 6074 }

    -- Feeds log `name` to a booted Forever whose store holds `seed` (the char DB at login). Counts each hit drawn as
    -- SW:P by its route: swpOnTickless, on a Mind Blast or Smite cast stamp (Ticks.TICKLESS); swpOnOwnCast, of those,
    -- on a stamp SW:P was cast on too, where it never ticks; swpTicks, off such stamps by the tracker (its real ticks).
    -- blastOnBlast counts the hits drawn as Mind Blast 8102 (`-> locked` or `-> tickless`) on a Mind Blast or Smite
    -- cast stamp (ticklessAt); ticklessHits lists each `-> tickless` draw { at = its frame's stamp, unit, id, onStamp
    -- (on such a stamp), onOwnCast (on a stamp where `id` was cast at `unit`) }, and hitCounts[at|unit|school] the hits
    -- that frame held on that plate in that school.
    local function Replay(name, seed)
        local ns = T.Boot(function(S)
            S.interface = 16001
            CombatTextIconsCharDB = seed
            for _, id in ipairs(HELPFUL) do S.harmful[id] = false end
        end)
        local S = T.State()
        ns.Teacher.area = "clear"
        local R = { swpOnTickless = 0, swpOnOwnCast = 0, swpTicks = 0, hits = 0, blastOnBlast = 0, ticklessHits = {},
            hitCounts = {}, schoolOf = ns.Ticks.TICKLESS }
        -- [stamp] = true: a Mind Blast or Smite cast, a SW:P cast there; aimAt[stamp|id]: the plate that cast aimed at;
        -- pending: the HIT whose PROBE line comes next
        local ticklessAt, swpAt, aimAt, fighting, pending = {}, {}, {}, false, nil
        -- A held hit prints its route when its frame ends, in the first handler call after it: `flushAt` is the stamp of
        -- the call before that one, the held hit's frame. A `-> tickless` line is followed by the hit's own draw.
        local flushAt, prevAt, drawing = nil, nil, nil
        ns.Display.Plate = function(plate)
            if not drawing then return end
            R.ticklessHits[#R.ticklessHits + 1] = { at = drawing.at, unit = plate.unit, id = drawing.id,
                onStamp = ticklessAt[drawing.at] == true,
                onOwnCast = aimAt[drawing.at .. "|" .. drawing.id] == plate.unit }
            drawing = nil
        end
        ns.Display.Player = function() end
        local route
        ns.Debug = function(format, ...)
            local line = string.format(format, ...)
            if line:find("^  %->") then route = line end
            local tickless = line:match("^  %-> tickless (%d+)")
            if tickless then drawing = { at = flushAt, id = tonumber(tickless) } end
        end
        -- Marks the next handler call: a held hit it flushes belongs to the frame at the previous call's stamp.
        local function Call(at)
            flushAt = prevAt
            prevAt = at or prevAt
        end

        local function Start()
            if fighting then return end
            fighting = true
            ns.Core.PLAYER_REGEN_DISABLED()
        end

        local function OnCast(at, castID, key)
            S.now = at
            if key ~= "nil" then S.target = key end
            if ns.Ticks.TICKLESS[castID] then ticklessAt[at], aimAt[at .. "|" .. castID] = true, key end
            if SWP[castID] then swpAt[at] = true end
            Start()
            Call(at)
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", castID)
        end

        -- the PROBE line after the HIT holds the meter read at that hit, so the hit waits for it (OnProbe)
        local function OnHit(at, rest, unit, school, flag)
            S.now = at
            if rest:find(" target=true$") then S.target = unit end
            local threat = rest:match(" threat=(%S+) ")
            S.threat[unit] = threat == "nil" and false or tonumber(threat)
            Start()
            pending = { unit = unit, school = tonumber(school), flag = flag, at = at }
        end

        -- Counts the route Core printed for `hit` at once (a held hit's comes at its frame's end, Display.Plate).
        local function CountRoute(hit)
            local named = route and tonumber(route:match("^  %-> %a+ (%d+)$"))
            if named == 8102 and ticklessAt[hit.at] and route:find("^  %-> locked ") then
                R.blastOnBlast = R.blastOnBlast + 1
            end
            if not (named and SWP[named]) then return end
            local onTickless = ticklessAt[hit.at]
            if onTickless then R.swpOnTickless = R.swpOnTickless + 1 end
            if onTickless and swpAt[hit.at] then R.swpOnOwnCast = R.swpOnOwnCast + 1 end
            if not onTickless and route:find("^  %-> tracker ") then R.swpTicks = R.swpTicks + 1 end
        end

        local function OnProbe(meter)
            local hit = pending
            pending, route = nil, nil
            ReadMeter(meter)
            local frameKey = hit.at .. "|" .. hit.unit .. "|" .. hit.school
            R.hitCounts[frameKey] = (R.hitCounts[frameKey] or 0) + 1
            Call(hit.at)
            ns.Core.UNIT_COMBAT(hit.unit, "WOUND", hit.flag, T.Secret(31), hit.school)
            R.hits = R.hits + 1
            CountRoute(hit)
        end

        local function OnTeach()
            fighting = false
            Call()
            ns.Core.PLAYER_REGEN_ENABLED()
            ticklessAt, swpAt, aimAt = {}, {}, {}
        end

        for line in io.lines(T.Root .. "/tests/fixtures/" .. name) do
            local stamp, rest = line:match("^(%d+%.%d+) (.*)$")
            local at = tonumber(stamp)
            local castID, key = rest:match("^CAST player (%d+) .*key=(%S+)$")
            local unit, school, flag = rest:match("^HIT (%S+) school=(%d+) amount=%S+ flag=(%S*) ")
            local meter = rest:match("^PROBE amount=%S+ meter=(%S+)")
            if castID then
                OnCast(at, tonumber(castID), key)
            elseif unit then
                OnHit(at, rest, unit, school, flag)
            elseif meter and pending then
                OnProbe(meter)
            elseif rest:match("^TEACH session") and fighting then
                OnTeach()
            end
        end
        Call()
        ns.Core.FlushMates()
        for _, drawn in ipairs(R.ticklessHits) do
            if drawn.id == 8102 and drawn.onStamp then R.blastOnBlast = R.blastOnBlast + 1 end
        end

        return R
    end

    -- S10 run 1 (Forever, 2026-11-07, solo): SW:P rank 3 (970) learned before login (run 9: 3.023), cast on Mind Blast
    -- 8102's stamp 13 times. In game 13 hits on a Mind Blast stamp went `-> tracker 970` (12 on SW:P's own cast stamp,
    -- from Tracker's cast-frame claim) and 80 hits off such stamps did; before the fix this replay drew 12 (11) and 81.
    local S10R1 = Replay("forever-s10-run1-2026-11-07.log", {
        learned = { [970] = { school = 32, kind = "dot", period = 3.023, misses = 0 } },
        lockedTicks = { [970] = { period = 3.023, kind = "damage", school = 32, misses = 0 } },
    })
    T.Note(string.format("CORE S10R1 hits=%d swpOnTickless=%d swpOnOwnCast=%d swpTicks=%d", S10R1.hits,
        S10R1.swpOnTickless, S10R1.swpOnOwnCast, S10R1.swpTicks))
    Check("core S10R1: no hit on a stamp where Mind Blast and SW:P were both cast is drawn as SW:P",
        S10R1.swpOnOwnCast == 0)
    -- The one left: 236083.502 holds two shadow hits, Mind Blast's and SW:P's first tick (cast 236080.543, 2.96 s
    -- before); the tracker names the first SW:P and the second draws '?', so one of them is right either way.
    Check("core S10R1: at most 1 hit on a Mind Blast or Smite stamp is drawn as SW:P", S10R1.swpOnTickless <= 1)
    -- Floor: measured 81 (2026-11-07, 80 in game), less 2.
    Check("core S10R1: at least 79 hits off a Mind Blast or Smite stamp drawn as SW:P by the tracker",
        S10R1.swpTicks >= 79)

    -- A Mind Blast alone on its cast stamp draws its icon (Locked.TicklessCast): 13 of the capture's 17 Mind Blast casts
    -- have a lone shadow hit on their plate there (3 have two, 1 none), 12 drawn `-> tickless 8102` at their frame's end
    -- and 1 `-> locked 8102` at once (a hit that the lock fit). The oracle is the log: every tickless draw is the only
    -- hit of its school on its plate in its frame, counted from the HIT lines, not from the code's own frame list, and
    -- sits on its own spell's cast stamp aimed at that plate, read from the CAST lines.
    local byId, notSole, offCast = {}, 0, 0
    for _, drawn in ipairs(S10R1.ticklessHits) do
        byId[drawn.id] = (byId[drawn.id] or 0) + 1
        local school = S10R1.schoolOf[drawn.id]
        if S10R1.hitCounts[drawn.at .. "|" .. drawn.unit .. "|" .. school] ~= 1 then notSole = notSole + 1 end
        if not drawn.onOwnCast then offCast = offCast + 1 end
    end
    T.Note(string.format("CORE S10R1 blastOnBlast=%d tickless 8102=%d tickless 598=%d notSole=%d offCast=%d",
        S10R1.blastOnBlast, byId[8102] or 0, byId[598] or 0, notSole, offCast))
    Check("core S10R1: the 13 of the capture's 17 Mind Blast casts with a lone shadow hit on their plate (3 have two,"
        .. " 1 none) draw Mind Blast on their stamp", S10R1.blastOnBlast == 13)
    Check("core S10R1: every tickless draw is the only hit of its school on its plate in its frame",
        #S10R1.ticklessHits > 0 and notSole == 0)
    Check("core S10R1: every tickless draw is on its own spell's cast stamp, on the plate that cast aimed at",
        #S10R1.ticklessHits > 0 and offCast == 0)
end
