-- Replay gate for Ticks.lua, Locked.lua and LockedHeals.lua over the four Forever captures (spec 2026-11-05-forever-tick-heal-icons).
-- Called by tests/checks_forever.lua with the same T table.

return function(T)
    local Check = T.Check
    local HARMFUL = { [5019] = true, [585] = true, [589] = true, [591] = true, [594] = true, [8092] = true }
    local LOGS = { "forever-secret-2026-11-05.log", "forever-s4-run1-2026-11-05.log", "forever-s4-run2-2026-11-05.log",
        "forever-s4-run3-2026-11-05.log" }

    -- Forever (interface 16001) with Locked, Ticks and LockedHeals on one store, as Core's Init wires them.
    local function Fresh()
        local ns = T.Boot(function(S) S.interface = 16001 CombatTextIconsCharDB = {} end)
        local store = {}
        ns.Locked.Init(store)
        ns.Ticks.Init(store)
        ns.LockedHeals.Init(store)

        return ns, store
    end

    -- rows: list of { spellID, totalAmount }. session nil: GetAvailableCombatSessions errors.
    local function Meter(session, rows)
        C_DamageMeter.GetAvailableCombatSessions = function()
            if session == nil then error("no sessions") end
            return { { sessionID = session } }
        end
        C_DamageMeter.GetCombatSessionSourceFromID = function()
            local out = {}
            for i, r in ipairs(rows or {}) do out[i] = { spellID = r[1], totalAmount = r[2] } end
            return { combatSpells = out }
        end
    end

    -- "session:68,591:29" or "session:68,secret:secret,..." -> the session ID, then rows, each part secret or a number.
    local function ReadMeter(text)
        local function Part(word) return word == "secret" and T.Secret(1) or tonumber(word) end
        local rows = {}
        for spell, total in text:gmatch(",(%w+):(%w+)") do rows[#rows + 1] = { Part(spell), Part(total) } end
        Meter(tonumber(text:match("session:(%d+)")), rows)
    end

    local function ReadLines(name)
        local lines = {}
        for line in io.lines(T.Root .. "/tests/fixtures/" .. name) do lines[#lines + 1] = line end

        return lines
    end

    -- The unit of the first HIT with target=true at or after line `from`, in the same fight; nil when none.
    local function PlateOf(lines, from)
        for i = from, #lines do
            local rest = lines[i]:match("^%d+%.%d+ (.*)$")
            if rest:match("^TEACH session") then return nil end
            local unit = rest:match("^HIT (%S+) .*target=true")
            if unit then return unit end
        end
    end

    -- The `TEACH heal <id> meter=<n> over=<n>` rows at stamp `at` after line `from`; nil when none.
    local function HealRows(lines, from, at)
        local rows = {}
        for i = from + 1, #lines do
            local stamp, rest = lines[i]:match("^(%d+%.%d+) (.*)$")
            if tonumber(stamp) ~= at then break end
            local id, total, over = rest:match("^TEACH heal (%d+) meter=(%d+) over=(%d+)")
            if id then rows[#rows + 1] = { spellID = tonumber(id), total = tonumber(total), overkill = tonumber(over) } end
        end

        return #rows > 0 and rows or nil
    end

    -- Adds the IDs of `saved` not yet in `seen` to `seen` and to `list`, sorted within one call.
    local function Remember(saved, seen, list)
        local fresh = {}
        for id in pairs(saved) do
            if not seen[id] then seen[id], fresh[#fresh + 1] = true, id end
        end
        table.sort(fresh)
        for _, id in ipairs(fresh) do list[#list + 1] = id end
    end

    -- Feeds the four logs, in order, to one set of modules; returns the gate's counters.
    local function Replay()
        local ns, store = Fresh()
        local R = { hits594 = 0, heals139 = 0, heals1260198 = 0, noHitStamp1260198 = 0, healHarmful = 0, hitWrong = 0,
            two = 0, learned = {}, procEver = {} }
        local learnedIDs, procIDs = {}, {}
        local helps, cast = {}, {}
        local helpAt, hitAt = {}, {}
        local heals, healAt = {}, nil

        local function Flush()
            if #heals == 0 then return end
            local claims = ns.LockedHeals.Claim(helpAt[healAt] or {}, heals, healAt, hitAt[healAt] == true, true)
            for index = 1, #heals do
                local id = claims[index]
                if id == 139 then R.heals139 = R.heals139 + 1 end
                if id == 1260198 then R.heals1260198 = R.heals1260198 + 1 end
                if id == 1260198 and not hitAt[healAt] then R.noHitStamp1260198 = R.noHitStamp1260198 + 1 end
                if id and HARMFUL[id] then R.healHarmful = R.healHarmful + 1 end
            end
            heals = {}
        end

        local function OnCast(lines, i, at, rest)
            local id = tonumber(rest:match("^CAST player (%d+)"))
            if not id then return end
            if HARMFUL[id] then
                ns.Locked.NoteCast(id, at)
                ns.Ticks.NoteCast(id, at, PlateOf(lines, i), "damage")
                cast[id] = true
                local base = tonumber(rest:match(" base=(%d+)"))
                if base then cast[base] = true end
                return
            end
            ns.Ticks.NoteCast(id, at, "player", "heal")
            helpAt[at] = helpAt[at] or {}
            helpAt[at][#helpAt[at] + 1] = id
            helps[#helps + 1] = { spellID = id, at = at }
        end

        local function OnHit(lines, i, at, rest)
            local school = tonumber(rest:match("^HIT %S+ school=(%d+)"))
            local meter = lines[i + 1] and lines[i + 1]:match("meter=(%S+)")
            if meter then ReadMeter(meter) end
            hitAt[at] = true
            local sole, fits = ns.Locked.Observe(rest:match("^HIT (%S+)"), school, at)
            if sole == 594 then R.hits594 = R.hits594 + 1 end
            if sole == 139 or sole == 1260198 then R.hitWrong = R.hitWrong + 1 end
            if fits >= 2 then R.two = R.two + 1 end
        end

        local function OnFightEnd(lines, i, at)
            Flush()
            ns.Locked.EndFight()
            ns.Ticks.EndFight()
            ns.LockedHeals.Learn(HealRows(lines, i, at), helps, cast)
            helps, cast, helpAt, hitAt = {}, {}, {}, {}
        end

        for _, name in ipairs(LOGS) do
            local lines = ReadLines(name)
            for i, line in ipairs(lines) do
                local stamp, rest = line:match("^(%d+%.%d+) (.*)$")
                local at = tonumber(stamp)
                if healAt and at > healAt then Flush() end
                if rest:match("^CAST ") then OnCast(lines, i, at, rest)
                elseif rest:match("^HIT ") then OnHit(lines, i, at, rest)
                elseif rest:match("^HEAL player") then heals[#heals + 1], healAt = { at = at }, at
                elseif rest:match("^TEACH session") then OnFightEnd(lines, i, at)
                end
                Remember(store.lockedTicks, R.learned, learnedIDs)
                Remember(store.lockedHeals, R.procEver, procIDs)
            end
            Flush()
        end

        R.learnedCount, R.learnedList, R.procList = #learnedIDs, table.concat(learnedIDs, ","), table.concat(procIDs, ",")

        return R
    end

    local R = Replay()

    T.Note(string.format("TICKS REPLAY learned=%s hits594=%d heals139=%d heals1260198=%d noHitStamp1260198=%d procEver=%s "
        .. "healHarmful=%d hitWrong=%d two=%d", R.learnedList, R.hits594, R.heals139, R.heals1260198,
        R.noHitStamp1260198, R.procList, R.healHarmful, R.hitWrong, R.two))

    Check("ticks replay: periods learned for 594 and 139 and no other spell (run 3: no 8092 from SW:P ticks on its plate)",
        R.learned[594] and R.learned[139] and R.learnedCount == 2)
    Check("ticks replay: at least 10 hits drawn as 594", R.hits594 >= 10)
    Check("ticks replay: at least 15 heals drawn as 139", R.heals139 >= 15)
    Check("ticks replay: at least 8 heals drawn as 1260198", R.heals1260198 >= 8)
    Check("ticks replay: no heal on a stamp without a HIT is drawn as 1260198", R.noHitStamp1260198 == 0)
    Check("ticks replay: 139 and 17 are never saved as proc rows", not R.procEver[139] and not R.procEver[17])
    Check("ticks replay: no heal is drawn as a harmful spell", R.healHarmful == 0)
    Check("ticks replay: no hit is drawn as 139 or 1260198", R.hitWrong == 0)
end
