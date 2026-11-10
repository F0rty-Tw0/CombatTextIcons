-- Replay gate for Core's hit route over a Forever capture: each CAST and HIT line goes through Core's own handlers, so
-- the tracker route (Tracker.Identify) runs as in game, unlike the Locked-only replays in checks_ticks_replay.lua.
-- Called by tests/checks_forever.lua with the same T table.

return function(T)
    local Check = T.Check
    local SWP, ReadMeter = T.SWP_RANKS, T.ReadMeter
    -- The helpful casts of the captures (Lesser Heal, Heal, Touch of Weakness 2652 and 19261, Inner Fire, PW:S, Renew,
    -- and run 11's other buffs, all `key=player` in that log): every other cast is harmful, as the harness answers by
    -- default.
    local HELPFUL = { 139, 17, 600, 2053, 2054, 2652, 588, 6074, 19261, 7128, 3747, 6075, 2055, 1245, 426639, 426754 }

    -- Feeds log `name` to a booted Forever whose store holds `seed` (the char DB at login). Counts each hit drawn as
    -- SW:P by its route: swpOnTickless, on a Mind Blast or Smite cast stamp (Ticks.TICKLESS); swpOnOwnCast, of those,
    -- on a stamp SW:P was cast on too, where it never ticks; swpTicks, off such stamps by the tracker (its real ticks).
    -- blastOnBlast counts the hits drawn as Mind Blast 8102 (`-> locked` or `-> tickless`) on a Mind Blast or Smite
    -- cast stamp (ticklessAt); ticklessHits lists each `-> tickless` draw { at = its frame's stamp, unit, id, onStamp
    -- (on such a stamp), onOwnCast (on a stamp where `id` was cast at `unit`) }, and hitCounts[at|unit|school] the hits
    -- that frame held on that plate in that school. `tows` lists each `-> tow <id>` draw { at = the stamp of the
    -- `  .. tow` or `  .. drain` line before it, id }, `drains` each `-> drain <id>` draw the same way, `healAt` the
    -- stamps ("%.3f") of the log's `HEAL player` lines, `teachRows[id]` the log's TEACH lines of that spell (the
    -- meter's rows), `routes[kind]` the routes printed by kind (`-> <kind> ...`). Each `HEAL player` line goes
    -- through Core.UNIT_COMBAT as OnHit's hits do, and no queued timer fires (the stub has no clock): a held candidate
    -- waits for the log's next event or fight end. A seed's `lockedHeals` row 1260198 stays the only saved proc row
    -- (the drain hold needs exactly one): Teacher's fight-end read waits in `S.timers` (Teacher.lua:1909), which this
    -- replay never fires, so LockedHeals.Learn never runs; Boot wraps the seed as the spec store (run.lua:236-239).
    local function Replay(name, seed)
        local ns = T.Boot(function(S)
            S.interface = 16001
            CombatTextIconsCharDB = seed
            for _, id in ipairs(HELPFUL) do S.harmful[id] = false end
        end)
        local S = T.State()
        ns.Teacher.area = "clear"
        local R = { swpOnTickless = 0, swpOnOwnCast = 0, swpTicks = 0, hits = 0, blastOnBlast = 0, ticklessHits = {},
            hitCounts = {}, schoolOf = ns.Ticks.TICKLESS, tows = {}, drains = {}, healAt = {}, teachRows = {}, routes = {},
            dotOnOwnCast = 0 }
        -- [stamp] = true: a Mind Blast or Smite cast, a SW:P cast there; aimAt[stamp|id]: the plate that cast aimed at;
        -- dotAt[stamp|id]: SW:P or Devouring Plague `id` cast there (counted as dotOnOwnCast when a hit there draws it);
        -- pending: the HIT whose PROBE line comes next
        local ticklessAt, swpAt, aimAt, dotAt, fighting, pending = {}, {}, {}, {}, false, nil
        -- A held hit prints its route when its frame ends, in the first handler call after it: `flushAt` is the stamp of
        -- the call before that one, the held hit's frame. A `-> tickless` line is followed by the hit's own draw.
        local flushAt, prevAt, drawing, heldAt = nil, nil, nil, nil
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
            local kind = line:match("^  %-> (%S+)")
            if kind then R.routes[kind] = (R.routes[kind] or 0) + 1 end
            if line == "  .. tow" or line == "  .. drain" then heldAt = S.now end
            local tow = line:match("^  %-> tow (%d+)")
            if tow then R.tows[#R.tows + 1] = { at = heldAt, id = tonumber(tow) } end
            local drain = line:match("^  %-> drain (%d+)")
            if drain then R.drains[#R.drains + 1] = { at = heldAt, id = tonumber(drain) } end
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
            if castID == 970 or castID == 2944 then dotAt[at .. "|" .. castID] = true end
            Start()
            Call(at)
            ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", castID)
        end

        -- the PROBE line after the HIT holds the meter read at that hit, so the hit waits for it (OnProbe)
        local function OnHit(at, rest, unit, school, flag)
            S.now = at
            if rest:find(" target=true$") then S.target = unit end
            local threat = rest:match(" threat=(%S+) ")
            -- `threat=nil` is a mob that does not fight you (S.threat false); Lua's `x and false or y` would give y
            if threat == "nil" then S.threat[unit] = false else S.threat[unit] = tonumber(threat) end
            Start()
            pending = { unit = unit, school = tonumber(school), flag = flag, at = at }
        end

        -- Counts the route Core printed for `hit` at once (a held hit's comes at its frame's end, Display.Plate).
        local function CountRoute(hit)
            local named = route and tonumber(route:match("^  %-> %a+ (%d+)$"))
            if named == 8102 and ticklessAt[hit.at] and route:find("^  %-> locked ") then
                R.blastOnBlast = R.blastOnBlast + 1
            end
            if named and dotAt[hit.at .. "|" .. named] then R.dotOnOwnCast = R.dotOnOwnCast + 1 end
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

        local function OnHeal(at, flag)
            S.now = at
            R.healAt[string.format("%.3f", at)] = true
            Call(at)
            ns.Core.UNIT_COMBAT("player", "HEAL", flag, T.Secret(31), 1)
        end

        local function OnTeach()
            fighting = false
            Call()
            ns.Core.PLAYER_REGEN_ENABLED()
            ticklessAt, swpAt, aimAt, dotAt = {}, {}, {}, {}
        end

        for line in io.lines(T.Root .. "/tests/fixtures/" .. name) do
            local stamp, rest = line:match("^(%d+%.%d+) (.*)$")
            local at = tonumber(stamp)
            local castID, key = rest:match("^CAST player (%d+) .*key=(%S+)$")
            local unit, school, flag = rest:match("^HIT (%S+) school=(%d+) amount=%S+ flag=(%S*) ")
            local meter = rest:match("^PROBE amount=%S+ meter=(%S+)")
            local healFlag = rest:match("^HEAL player school=%d+ amount=%S+ flag=(%S*)$")
            local taught = rest:match("^TEACH (%d+) ")
            if castID then
                OnCast(at, tonumber(castID), key)
            elseif unit then
                OnHit(at, rest, unit, school, flag)
            elseif meter and pending then
                OnProbe(meter)
            elseif healFlag then
                OnHeal(at, healFlag)
            elseif rest:match("^TEACH session") and fighting then
                OnTeach()
            end
            if taught then R.teachRows[tonumber(taught)] = (R.teachRows[tonumber(taught)] or 0) + 1 end
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
        lockedHeals = { [1260198] = { strikes = 0 } }, lockedHealsV = 2,
    })
    T.Note(string.format("CORE S10R1 hits=%d swpOnTickless=%d swpOnOwnCast=%d swpTicks=%d", S10R1.hits,
        S10R1.swpOnTickless, S10R1.swpOnOwnCast, S10R1.swpTicks))
    Check("core S10R1: no hit on a stamp where Mind Blast and SW:P were both cast is drawn as SW:P",
        S10R1.swpOnOwnCast == 0)
    -- The one left: 236083.502 holds two shadow hits, Mind Blast's and SW:P's first tick (cast 236080.543, 2.96 s
    -- before); the tracker names the first SW:P and the second draws '?', so one of them is right either way.
    Check("core S10R1: at most 1 hit on a Mind Blast or Smite stamp is drawn as SW:P", S10R1.swpOnTickless <= 1)
    -- Floor: measured 80 (2026-11-07, 80 in game; 81 while the replay took a `threat=nil` mob for one that fights you),
    -- less 1.
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

    -- Touch of Weakness's proc draws its icon (TowHold.Hold): the hit is a shadow `?` with no `HEAL player` within
    -- 0.15 s and a buff cast armed it. The oracle is the meter: each TEACH row of the proc in the log is one proc, and
    -- the hit of each is the one the rule picks (run 10 rank 1 buff 2652 -> proc 2943, 2 rows; run 11 rank 2 buff 19261
    -- -> proc 19249, 5 rows, 3 of them with no shadow spell cast yet); no other hit draws as the proc.
    local function Stamps(replay)
        local stamps = {}
        for _, drawn in ipairs(replay.tows) do stamps[#stamps + 1] = string.format("%.3f", drawn.at) end

        return table.concat(stamps, " ")
    end
    local function AllProc(replay, proc)
        for _, drawn in ipairs(replay.tows) do if drawn.id ~= proc then return false end end

        return #replay.tows > 0
    end
    local function RouteNote(label, replay)
        local kinds = {}
        for kind, count in pairs(replay.routes) do kinds[#kinds + 1] = kind .. "=" .. count end
        table.sort(kinds)
        T.Note("CORE " .. label .. " routes " .. table.concat(kinds, " "))
    end

    local S11R1 = Replay("forever-s11-run1-2026-11-07.log", {
        learned = { [970] = { school = 32, kind = "dot", period = 3.023, misses = 0 } },
        lockedTicks = { [970] = { period = 3.023, kind = "damage", school = 32, misses = 0 } },
        lockedHeals = { [1260198] = { strikes = 0 } }, lockedHealsV = 2,
    })
    RouteNote("S10R1", S10R1)
    RouteNote("S11R1", S11R1)
    T.Note("CORE S10R1 tow " .. Stamps(S10R1))
    T.Note("CORE S11R1 tow " .. Stamps(S11R1))
    Check("core S10R1: exactly 2 hits draw as Touch of Weakness's proc 2943, as many as the meter's TEACH 2943 rows",
        AllProc(S10R1, 2943) and #S10R1.tows == S10R1.teachRows[2943] and Stamps(S10R1) == "236033.966 236100.566")
    Check("core S11R1: exactly 5 hits draw as Touch of Weakness's proc 19249, as many as the meter's TEACH 19249 rows",
        AllProc(S11R1, 19249) and #S11R1.tows == S11R1.teachRows[19249]
        and Stamps(S11R1) == "263408.478 263455.108 263478.957 263509.482 263653.758")

    -- S12 run 1 (Forever, 2026-11-08, solo, 8 fights): SW:P 970 and Devouring Plague 2944 deal nothing on their own
    -- cast stamp (Ticks.NO_OPENER), yet in game Tracker's cast-frame claim drew the shadow hit there as the DoT: the
    -- 1260198 drain (with its `HEAL player`) 5 times, and the Touch of Weakness proc at 279016.467 (no heal), so that
    -- fight's proc row 19249 had no tow draw. The oracle is the meter: 3 TEACH 19249 rows.
    local S12R1 = Replay("forever-s12-run1-2026-11-08.log", {
        learned = { [970] = { school = 32, kind = "dot", period = 3.004, misses = 0 },
            [2944] = { school = 32, kind = "dot", period = 3.0, misses = 0 } },
        lockedTicks = { [970] = { period = 3.004, kind = "damage", school = 32, misses = 0 },
            [2944] = { period = 3.0, kind = "damage", school = 32, misses = 0 } },
        lockedHeals = { [1260198] = { strikes = 0 } }, lockedHealsV = 2,
    })
    RouteNote("S12R1", S12R1)
    T.Note("CORE S12R1 tow " .. Stamps(S12R1) .. " dotOnOwnCast=" .. S12R1.dotOnOwnCast)
    Check("core S12R1: exactly 3 hits draw as Touch of Weakness's proc 19249, as many as the meter's TEACH 19249 rows",
        AllProc(S12R1, 19249) and #S12R1.tows == S12R1.teachRows[19249]
        and Stamps(S12R1) == "278948.988 279016.467 279045.228")
    Check("core S12R1: no hit on SW:P's or Devouring Plague's own cast stamp is drawn as that DoT",
        S12R1.dotOnOwnCast == 0)

    -- The drain's damage hit draws its heal's proc row (TowHold.Healed): with the one row 1260198 saved, a held lone
    -- shadow hit whose same-stamp heal is claimed as the row draws `-> drain 1260198`. The oracle is the log: each such
    -- draw sits on a stamp with a `HEAL player` line, read from the log's lines, not from the code's own frame list.
    local function Drains(replay) -- the count, and how many sit on a stamp with no HEAL player line in the log
        local off = 0
        for _, drawn in ipairs(replay.drains) do
            if not replay.healAt[string.format("%.3f", drawn.at)] then off = off + 1 end
        end

        return #replay.drains, off
    end
    local function AllRow(replay)
        for _, drawn in ipairs(replay.drains) do if drawn.id ~= 1260198 then return false end end

        return true
    end
    -- Floors: measured 11, 27 and 8 (2026-11-10), less 1 each. Ceilings: the measured counts, so a drain drawn for a
    -- heal the claim did not name fails here too (that leak drew 28 in S11R1).
    for _, case in ipairs({ { "S10R1", S10R1, 10, 11 }, { "S11R1", S11R1, 26, 27 }, { "S12R1", S12R1, 7, 8 } }) do
        local label, replay, floor, ceiling = case[1], case[2], case[3], case[4]
        local count, off = Drains(replay)
        T.Note(string.format("CORE %s drain=%d off=%d", label, count, off))
        Check("core " .. label .. ": every hit drawn as the drain sits on a stamp with a HEAL player line in the log",
            count > 0 and off == 0)
        Check("core " .. label .. ": every drain draw is the saved row 1260198", AllRow(replay))
        Check("core " .. label .. ": " .. floor .. " to " .. ceiling .. " hits draw as the drain 1260198",
            count >= floor and count <= ceiling)
    end
end
