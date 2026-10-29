-- Unit checks for streams, votes and the Tracker hooks of matcher v2a. Called by
-- tests/checks.lua after checks_learn.lua with the same T table.

return function(T)
    local Check, Secret = T.Check, T.Secret

    -- Records "<name> exported"; false means the block needing it must not run.
    local function Has(name, owner, field)
        local ok = type(owner) == "table" and type(owner[field]) == "function"
        Check(name .. " exported", ok)
        return ok
    end

    -- A fresh addon whose Learn hooks only record (Task 1.3 checks use the real store).
    local function Rig()
        local ns = T.Boot()
        local rig = { ns = ns, births = {}, casts = {} }
        ns.Learn.OnBirth = function(key, stream, now) rig.births[#rig.births + 1] = { key = key, stream = stream, now = now } end
        ns.Learn.OnCast = function(castID) rig.casts[#rig.casts + 1] = castID end
        function rig.Hit(key, t, amount, school, flag)
            ns.Streams.Feed(key, school or 32, amount or 1000, flag or "", t)
        end
        return rig
    end

    local index = {}
    for position, file in ipairs(T.TocFiles()) do index[file] = position end
    Check("toc: Streams.lua loads right after Learn.lua, before Meter.lua and Tracker.lua",
        index["Streams.lua"] ~= nil and index["Streams.lua"] == (index["Learn.lua"] or -1) + 1
        and index["Streams.lua"] < index["Meter.lua"] and index["Streams.lua"] < index["Tracker.lua"])
    local module = T.Boot().Streams
    if not (Has("streams: Feed", module, "Feed") and Has("streams: LogCast", module, "LogCast")
        and Has("streams: CastLog", module, "CastLog") and Has("streams: Live", module, "Live")
        and Has("streams: Drop", module, "Drop") and Has("streams: Reset", module, "Reset")
        and Has("streams: Keys", module, "Keys")) then return end

    -- Birth: 4 hits, 3 agreeing gaps ------------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        rig.Hit("k", 0); rig.Hit("k", 2)
        Check("streams: 2 hits form no stream", #Streams.Live("k", 2) == 0 and #rig.births == 0)
        rig.Hit("k", 4)
        Check("streams: 3 agreeing hits form no stream", #Streams.Live("k", 4) == 0 and #rig.births == 0)
        rig.Hit("k", 6)
        local stream = Streams.Live("k", 6)[1]
        Check("streams: the 4th hit forms a stream (period 2, birth 0, lastAt 6, count 4, hits 0/2/4/6) and calls OnBirth once",
            stream and stream.period == 2 and stream.birth == 0 and stream.lastAt == 6 and stream.count == 4
            and stream.school == 32 and stream.hits[1] == 0 and stream.hits[2] == 2 and stream.hits[3] == 4 and stream.hits[4] == 6
            and stream.key == "k" and #rig.births == 1 and rig.births[1].stream == stream
            and rig.births[1].key == "k" and rig.births[1].now == 6)
        rig.Hit("k", 8)
        local born = rig.births[1]
        Check("streams: OnBirth reports each birth (key, school, period, at) and no extension",
            #rig.births == 1 and born.key == "k" and born.stream.school == 32 and born.stream.period == 2 and born.now == 6)
        rig = Rig(); Streams = rig.ns.Streams
        rig.Hit("g", 0); rig.Hit("g", 2); rig.Hit("g", 5); rig.Hit("g", 8)         -- gaps 2 / 3 / 3
        rig.Hit("f", 0); rig.Hit("f", 0.3); rig.Hit("f", 0.6); rig.Hit("f", 0.9)   -- gaps under PERIOD_MIN less its slack
        Check("streams: disagreeing gaps and gaps under 0.4 s form nothing", #Streams.Live("g", 8) == 0 and #Streams.Live("f", 0.9) == 0)
        rig.Hit("j", 0); rig.Hit("j", 0.512); rig.Hit("j", 1.018); rig.Hit("j", 1.514) -- gaps 0.512 / 0.506 / 0.496 (shaman3)
        local jit = Streams.Live("j", 1.514)[1]
        Check("streams: a ~0.5 s rhythm with one gap jittered under 0.5 s is born at its 4th hit",
            jit ~= nil and math.abs(jit.period - 0.5047) < 0.001 and jit.birth == 0)
        rig.Hit("u", 0); rig.Hit("u", 0.45); rig.Hit("u", 0.81); rig.Hit("u", 1.26) -- gaps 0.45 / 0.36 / 0.45
        Check("streams: a gap under PERIOD_MIN less its slack forms nothing", #Streams.Live("u", 1.26) == 0)
        -- run mage: Arcane Missiles 7268 landed every ~0.3 s (gaps 0.34 / 0.25 alternating) and was born at every other
        -- missile, 0.53-0.62 s
        rig = Rig(); Streams = rig.ns.Streams
        local missiles = { 0, 0.34, 0.59, 0.93, 1.18, 1.52, 1.77 }
        for _, t in ipairs(missiles) do rig.Hit("m", t) end
        local fast = Streams.Live("m", 1.77)[1]
        Check("streams: a rhythm under 0.4 s is born at its 7th hit at half the paired period, holding all 7 hits",
            #Streams.Live("m", 1.77) == 1 and fast and math.abs(fast.period - 1.77 / 6) < 1e-9 and fast.halved
            and fast.count == 7 and #fast.hits == 7 and fast.hits[2] == 0.34 and fast.hits[6] == 1.52 and #rig.births == 1)
        rig.Hit("m", 2.11)
        Check("streams: a halved stream extends one short tick on", fast.count == 8 and fast.lastAt == 2.11)
        rig = Rig(); Streams = rig.ns.Streams
        for _, t in ipairs({ 0, 0.6, 1.2, 1.8 }) do rig.Hit("e", t) end
        for index, t in ipairs({ 0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8 }) do rig.Hit("o", t, index == 2 and 2000 or 1000) end
        local even, odd = Streams.Live("e", 1.8)[1], Streams.Live("o", 1.8)[1]
        Check("streams: a birth with no hit, or an unlike-sized one, in the middle of a gap keeps its period",
            even and math.abs(even.period - 0.6) < 1e-9 and not even.halved and even.count == 4
            and odd and math.abs(odd.period - 0.6) < 1e-9 and not odd.halved and odd.count == 4)

        -- several sets fit: the smaller timing error wins; a tie goes to the latest a
        rig = Rig(); Streams = rig.ns.Streams
        for _, t in ipairs({ 0, 0.1, 2.0, 4.0, 6.0 }) do rig.Hit("w", t) end
        Check("streams: of two fitting sets the smaller timing error wins (a = 0, error 0, not 0.1)",
            Streams.Live("w", 6)[1] and Streams.Live("w", 6)[1].birth == 0)
        rig = Rig(); Streams = rig.ns.Streams
        for _, t in ipairs({ 0.25, 0.75, 2.5, 4.5, 6.5 }) do rig.Hit("t", t) end
        local tie = Streams.Live("t", 6.5)[1]
        Check("streams: equal errors (0.25 each) go to the latest a (0.75): hits 0.75 / 2.5 / 4.5 / 6.5",
            tie and tie.birth == 0.75 and tie.hits[1] == 0.75 and tie.hits[2] == 2.5 and tie.hits[3] == 4.5 and tie.hits[4] == 6.5)
    end

    -- Fight records: a stream's share of this fight, kept only for recorded hits ----------
    do
        local function Fed(rig, key, times, amount, record, flag)
            local last
            for _, t in ipairs(times) do
                last = rig.ns.Streams.Feed(key, 32, amount, flag or "", t, record)
            end
            return last
        end
        local rig = Rig()
        local Streams = rig.ns.Streams
        local fight = Streams.NewFight()
        local early = {}
        for _, t in ipairs({ 0, 2, 4 }) do early[#early + 1] = Streams.Feed("a", 32, 1000, "", t, true) end
        local stream = Streams.Feed("a", 32, 1000, "", 6, true)
        local rec = fight[stream]
        Check("streams: record: hits 1-3 return nil, the 4th returns the stream", #early == 0 and stream == Streams.Live("a", 6)[1])
        Check("streams: record: a birth notes all 4 hits (sum 4000, n 4, lo 1000, hi 1000, school 32)",
            rec and rec.sum == 4000 and rec.n == 4 and rec.lo == 1000 and rec.hi == 1000 and rec.school == 32)
        local extended = Streams.Feed("a", 32, 1100, "", 8, true)
        Check("streams: record: an extension returns the same stream and grows sum, n and hi",
            extended == stream and rec.sum == 5100 and rec.n == 5 and rec.lo == 1000 and rec.hi == 1100)
        Streams.Feed("a", 32, 2400, "CRITICAL", 10, true)
        Check("streams: record: a crit adds to sum and n but not to lo or hi",
            rec.sum == 7500 and rec.n == 6 and rec.lo == 1000 and rec.hi == 1100)

        -- Run lock2 F3: Darkglare's first beam (10461) came a period before a stream born at 13502, a step up as the
        -- DoTs it counts went on; left loose, it put the stream's sum 5.9 % under the 205231 row.
        local function Led(key, lead)
            rig = Rig(); Streams = rig.ns.Streams
            fight = Streams.NewFight()
            Streams.Feed(key, 32, lead, "", 0, true)
            local born = Fed(rig, key, { 2, 4, 6, 8 }, 13502, true)

            return born and fight[born]
        end
        rec = Led("g1", 10461)
        Check("streams: record: a birth's lead tick, a period back and a buff's step smaller (10461 -> 13502), is noted too",
            rec and rec.sum == 4 * 13502 + 10461 and rec.n == 5 and rec.lo == 10461 and rec.hi == 13502)
        rec = Led("g2", 8000)
        Check("streams: record: a tick more than x1.5 smaller (8000 -> 13502) is no lead tick",
            rec and rec.sum == 4 * 13502 and rec.n == 4 and rec.lo == 13502)

        for _, record in ipairs({ false, "nil" }) do
            rig = Rig(); Streams = rig.ns.Streams
            fight = Streams.NewFight()
            local arg = record
            if record == "nil" then arg = nil end
            Fed(rig, "b", { 0, 2, 4, 6 }, 1000, arg)
            Check("streams: record: record " .. tostring(record) .. " records nothing", next(fight) == nil and #Streams.Live("b", 6) == 1)
        end

        rig = Rig(); Streams = rig.ns.Streams
        local ok = pcall(Fed, rig, "c", { 0, 2, 4, 6, 8 }, 1000, true)
        Check("streams: record: hits before any NewFight record nothing and do not error", ok and #Streams.Live("c", 8) == 1)

        rig = Rig(); Streams = rig.ns.Streams
        local old = Streams.NewFight()
        stream = Fed(rig, "d", { 0, 2, 4, 6 }, 1000, true)
        local new = Streams.NewFight()
        Streams.Feed("d", 32, 900, "", 8, true)
        Check("streams: record: a second NewFight gives the next extension a fresh record; the old table is unchanged",
            new ~= old and new[stream] and new[stream].sum == 900 and new[stream].n == 1
            and old[stream].sum == 4000 and old[stream].n == 4)

        rig = Rig(); Streams = rig.ns.Streams
        fight = Streams.NewFight()
        local amounts = { Secret(1000), Secret(1000), 1000, 1000 }
        ok = pcall(function() for i, t in ipairs({ 0, 2, 4, 6 }) do stream = Streams.Feed("e", 32, amounts[i], "", t, true) end end)
        rec = stream and fight[stream]
        Check("streams: record: secret hits form a stream and only the plain ones are noted (sum 2000, n 2, lo 1000, hi 1000)",
            ok and rec and rec.sum == 2000 and rec.n == 2 and rec.lo == 1000 and rec.hi == 1000)
    end

    -- JoinFight: one fight's records added into another's -----------------------------------
    do
        local Streams = Rig().ns.Streams
        local S1, S2 = {}, {}
        local into = { [S1] = { school = 32, sum = 100, n = 1, lo = 100, hi = 100 } }
        local joined = Streams.JoinFight(into, { [S1] = { school = 32, sum = 200, n = 2, lo = 90, hi = 110 },
            [S2] = { school = 32, sum = 50, n = 2, lo = 20, hi = 30 } })
        Check("streams: join: returns into; a shared stream adds sum and n and widens lo/hi (300, 3, 90..110)",
            joined == into and into[S1].sum == 300 and into[S1].n == 3 and into[S1].lo == 90 and into[S1].hi == 110)
        Check("streams: join: a stream only `from` holds is copied (sum 50, n 2, lo 20)",
            into[S2] and into[S2].sum == 50 and into[S2].n == 2 and into[S2].lo == 20)
        local bare = Streams.JoinFight({ [S1] = { school = 32, sum = 100, n = 1 } }, { [S1] = { school = 32, sum = 5, n = 1, lo = 5, hi = 6 } })
        Check("streams: join: a record with no lo/hi takes the other's range (sum 105, lo 5, hi 6)",
            bare[S1].sum == 105 and bare[S1].lo == 5 and bare[S1].hi == 6)
        local keep = Streams.JoinFight({ [S1] = { school = 32, sum = 100, n = 1, lo = 80, hi = 90 } }, { [S1] = { school = 32, sum = 5, n = 1 } })
        Check("streams: join: a record with no lo/hi leaves into's range alone (sum 105, lo 80, hi 90)",
            keep[S1].sum == 105 and keep[S1].lo == 80 and keep[S1].hi == 90)
    end

    -- Size guard, crits, heals, secrets ---------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        rig.Hit("a", 0, 1000); rig.Hit("a", 2, 2000); rig.Hit("a", 4, 1000); rig.Hit("a", 6, 1000)
        Check("streams: a 2x size jump rejects the set", #Streams.Live("a", 6) == 0)
        rig.Hit("p", 0, 1000); rig.Hit("p", 2, 1140); rig.Hit("p", 4, 1300); rig.Hit("p", 6, 1480)
        Check("streams: every pair of the four hits faces the size guard (each step within 15 %, ends 48 % apart: no stream)",
            #Streams.Live("p", 6) == 0)
        rig.Hit("b", 0, 1000); rig.Hit("b", 2, 2000, 32, "CRITICAL"); rig.Hit("b", 4, 1000); rig.Hit("b", 6, 1000)
        Check("streams: a crit within the band agrees (2000 CRITICAL with 1000)", #Streams.Live("b", 6) == 1)
        rig.Hit("b", 8, 2000, 32, "CRITICAL")
        Check("streams: lastAmount is the newest normal amount (1000)", Streams.Live("b", 8)[1].lastAmount == 1000
            and Streams.Live("b", 8)[1].count == 5)
        rig.Hit("c", 0, 1000); rig.Hit("c", 2, 1000); rig.Hit("c", 4, 1000); rig.Hit("c", 6, 1000)
        rig.Hit("c", 8, 2000)
        Check("streams: a 2x size does not extend a stream", Streams.Live("c", 8)[1].count == 4 and Streams.Live("c", 8)[1].lastAt == 6)
        rig.Hit("c", 8.05, 1000)
        local stream = Streams.Live("c", 8.05)[1]
        Check("streams: a fitting hit extends (count 5, lastAt 8.05, period 0.8*2 + 0.2*2.05 = 2.01)",
            stream.count == 5 and stream.lastAt == 8.05 and math.abs(stream.period - 2.01) < 1e-9)
        local ok = pcall(function()
            rig.Hit("s", 0, Secret(1000)); rig.Hit("s", 2, Secret(1000)); rig.Hit("s", 4, 1000, 32, Secret("CRITICAL")); rig.Hit("s", 6, 1000)
        end)
        Check("streams: secret amounts / flags never error and skip the size guard", ok and #Streams.Live("s", 6) == 1)
        ok = pcall(function() for _, t in ipairs({ 0, 2, 4, 6 }) do rig.Hit("t", t, 1000, Secret(32)) end end)
        Check("streams: a secret school is ignored without error", ok and #Streams.Live("t", 6) == 0)
    end

    -- Crit range (spec 3.1): a crit agrees with a normal hit when crit / normal is in [1.8, 2.7] ------
    do
        local C = "CRITICAL"
        local function Chain(rig, key, hits)
            for index, hit in ipairs(hits) do rig.Hit(key, (index - 1) * 2, hit[1], 32, hit[2]) end
            return rig.ns.Streams.Live(key, (#hits - 1) * 2)
        end
        local rig = Rig()
        local Streams = rig.ns.Streams
        Check("streams: crit 2400 over normal 1000 (ratio 2.4) agrees", #Chain(rig, "r24", { { 1000 }, { 2400, C }, { 1000 }, { 1000 } }) == 1)
        Check("streams: ratios 1.5 and 3.0 disagree",
            #Chain(rig, "r15", { { 1000 }, { 1500, C }, { 1000 }, { 1000 } }) == 0 and #Chain(rig, "r30", { { 1000 }, { 3000, C }, { 1000 }, { 1000 } }) == 0)
        Check("streams: the band edges 1.8 and 2.7 agree",
            #Chain(rig, "e18", { { 1000 }, { 1800, C }, { 1000 }, { 1000 } }) == 1 and #Chain(rig, "e27", { { 1000 }, { 2700, C }, { 1000 }, { 1000 } }) == 1)
        Check("streams: just outside the band (1.79 and 2.71) disagrees",
            #Chain(rig, "o18", { { 1000 }, { 1790, C }, { 1000 }, { 1000 } }) == 0 and #Chain(rig, "o27", { { 1000 }, { 2710, C }, { 1000 }, { 1000 } }) == 0)
        Check("streams: two crits use the 15 % rule (2000 / 2200 agree, 2000 / 2600 do not)",
            #Chain(rig, "cc1", { { 2000, C }, { 2200, C }, { 2000, C }, { 2000, C } }) == 1 and #Chain(rig, "cc2", { { 2000, C }, { 2600, C }, { 2000, C }, { 2000, C } }) == 0)
        Check("streams: a plain amount with a secret flag has no size (5000 agrees with 1000)",
            #Chain(rig, "sf", { { 1000 }, { 1000 }, { 5000, Secret("CRITICAL") }, { 1000 } }) == 1)

        Chain(rig, "e", { { 1000 }, { 1000 }, { 1000 }, { 1000 } })   -- born at 6, lastAmount 1000
        rig.Hit("e", 8, 2400, 32, C)
        local stream = Streams.Live("e", 8)[1]
        Check("streams: an extending crit counts but leaves lastAmount (count 5, lastAt 8, lastAmount 1000)",
            stream.count == 5 and stream.lastAt == 8 and stream.lastAmount == 1000)
        rig.Hit("e", 10, 1100)
        Check("streams: an extending normal hit sets lastAmount (count 6, 1100)", stream.count == 6 and stream.lastAmount == 1100)
        rig.Hit("e", 12, 3000, 32, C)
        Check("streams: a crit outside the band does not extend (3000 over 1100 = 2.73)", stream.count == 6 and stream.lastAt == 10)

        Check("streams: birth lastAmount is the newest normal hit (1000, 2400C, 1100, 1050 and 1000, 1100, 1050, 2400C both give 1050)",
            Chain(rig, "n1", { { 1000 }, { 2400, C }, { 1100 }, { 1050 } })[1].lastAmount == 1050
            and Chain(rig, "n2", { { 1000 }, { 1100 }, { 1050 }, { 2400, C } })[1].lastAmount == 1050)
        Check("streams: crit-only birth: lastAmount = newest crit / 2.25 (2475 -> 1100)",
            math.abs(Chain(rig, "co", { { 2250, C }, { 2300, C }, { 2475, C }, { 2475, C } })[1].lastAmount - 1100) < 1e-9)
    end

    -- Extension at m = 2, death, caps -----------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        rig.Hit("k", 0); rig.Hit("k", 2); rig.Hit("k", 4); rig.Hit("k", 6); rig.Hit("k", 10.1) -- one tick skipped
        local stream = Streams.Live("k", 10.1)[1]
        Check("streams: a hit two periods on extends (m = 2): count 5, lastAt 10.1, period 0.8*2 + 0.2*2.05",
            stream and stream.count == 5 and stream.lastAt == 10.1 and math.abs(stream.period - 2.01) < 1e-9)
        rig = Rig(); Streams = rig.ns.Streams
        rig.Hit("d", 0); rig.Hit("d", 2); rig.Hit("d", 4); rig.Hit("d", 6)
        Check("streams: alive at lastAt + 2.5 P (6 + 5 = 11)", #Streams.Live("d", 11) == 1)
        Check("streams: dead after 2.5 P, and gone from Keys", #Streams.Live("d", 11.1) == 0 and #Streams.Keys() == 0)

        rig = Rig(); Streams = rig.ns.Streams
        for round = 0, 3 do for index = 0, 6 do rig.Hit("c", round * 6 + index * 0.3, 1000, 2 + index) end end   -- period 6 keeps four hits inside 20 s
        local schools = {}
        for _, live in ipairs(Streams.Live("c", 19.8)) do schools[live.school] = true end
        Check("streams: a 7th stream drops the oldest lastAt (6 live, school 2 gone, school 8 kept)",
            #Streams.Live("c", 19.8) == 6 and not schools[2] and schools[8])

    end

    -- Loose memory: by age, capped at 64 (spec 3.2) ---------------------------------------
    do
        local function Feed(rig, key, events)
            table.sort(events, function(a, b) return a.t < b.t end)
            for _, event in ipairs(events) do rig.Hit(key, event.t, event.amount) end
        end
        -- junk sizes 3000 * 2^k never agree with each other or with 1000
        local rig = Rig()
        local events = {}
        for _, t in ipairs({ 0, 2.7, 5.4, 8.1 }) do events[#events + 1] = { t = t, amount = 1000 } end
        for k = 0, 39 do events[#events + 1] = { t = 0.05 + 0.2 * k, amount = 3000 * 2 ^ k } end
        Feed(rig, "slow", events)
        local slow = rig.ns.Streams.Live("slow", 8.1)
        Check("streams: a slow rhythm (P 2.7) is born with 40 unrelated same-school hits between its ticks",
            #slow == 1 and slow[1].birth == 0 and math.abs(slow[1].period - 2.7) < 1e-9)

        local function Capped(junk)
            local r = Rig()
            local list = { { t = 0, amount = 1000 }, { t = 5, amount = 1000 }, { t = 10, amount = 1000 } }
            for k = 0, junk - 1 do list[#list + 1] = { t = 0.1 + 0.2 * k, amount = 3000 * 2 ^ k } end
            Feed(r, "cap", list)
            r.Hit("cap", 15, 1000)
            return #r.ns.Streams.Live("cap", 15)
        end
        Check("streams: 64 loose hits are kept (a, b, c + 61 junk still pair with the next hit)", Capped(61) == 1)
        Check("streams: the 65th loose hit drops the oldest (a, b, c + 62 junk: no stream)", Capped(62) == 0)

        rig = Rig()
        for _, t in ipairs({ 0, 6.65, 13.35, 20.1 }) do rig.Hit("o", t) end
        for _, t in ipairs({ 0, 6.65, 13.35, 20 }) do rig.Hit("p", t) end
        Check("streams: loose hits older than 20 s are dropped before the search (20.1 no, 20.0 yes)",
            #rig.ns.Streams.Live("o", 20.1) == 0 and #rig.ns.Streams.Live("p", 20) == 1)
    end

    -- Cast log and owners -----------------------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        for _, cast in ipairs({ { 7.0, 9003, "dot" }, { 7.8, 9005, "dot" }, { 8.0, 9001, "dot" }, { 8.2, 9006, "channel" },
            { 8.6, 9001, "dot" }, { 9.5, 9002, "dot" } }) do
            Streams.LogCast("k", cast[2], cast[3], cast[1])
            if cast[1] == 8.6 then Streams.StopChannel(8.6) end -- the next cast stops the channel, as in the game
        end
        local log = Streams.CastLog("k")
        Check("cast log: oldest first with at / castID / kind; every logged cast calls Learn.OnCast",
            #log == 6 and log[1].castID == 9003 and log[1].at == 7.0 and log[1].kind == "dot" and log[4].kind == "channel"
            and #rig.casts == 6)
        rig.Hit("k", 10); rig.Hit("k", 12); rig.Hit("k", 14); rig.Hit("k", 16)
        local stream = Streams.Live("k", 16)[1] -- window [10 - 2.4, 10 - 1.0] = [7.6, 9.0]
        Check("owners: distinct casts inside [birth - 1.2 P, birth - 0.5 P], cast order, with their kinds",
            stream and table.concat(stream.owners, ",") == "9005,9001,9006"
            and stream.ownerKind[9005] == "dot" and stream.ownerKind[9006] == "channel")

        -- Run 20261025T181738Z: Haunt's +21 % stepped Wither's opener ticks past SIZE_GUARD one period after Haunt's cast.
        local function Stepped(key, early, earlyCount)
            Streams.LogCast(key, 445468, "dot", 100); Streams.LogCast(key, 48181, "dot", 106.5)
            for n = 1, earlyCount do rig.Hit(key, 108 - 2 * n, early) end
            for _, t in ipairs({ 108, 110, 112, 114 }) do rig.Hit(key, t, 1753) end
            local live = Streams.Live(key, 114)[1]

            return live and table.concat(live.owners, ",")
        end
        Check("owners: a birth one period after two or more loose ticks a buff's step smaller (1451 -> 1753) takes the owners"
            .. " of their first tick (Wither 445468, not Haunt 48181)", Stepped("w1", 1451, 3) == "445468")
        Check("owners: one loose tick, or ticks more than x1.5 apart (900 -> 1753), leave the birth window's owners",
            Stepped("w2", 1451, 1) == "48181" and Stepped("w3", 900, 3) == "48181")
        -- Run lock3 F2: Agony 980 ramped x1.14 to x1.50 a tick (1353 -> 4328) and was born only on its flat ticks.
        local fight = Streams.NewFight()
        Streams.LogCast("r1", 980, "dot", 100); Streams.LogCast("r1", 48181, "dot", 108.5)
        for n, size in ipairs({ 1000, 1400, 1960, 2744 }) do
            Streams.Feed("r1", 32, size, "", 100 + 2 * n, true)
        end
        local ramped
        for _, t in ipairs({ 110, 112, 114, 116 }) do ramped = Streams.Feed("r1", 32, 3842, "", t, true) end
        Check("owners: a birth on a ramp's flat ticks (x1.4 a tick, 1000 -> 3842) takes the owners of the ramp's first"
            .. " tick (980, not 48181); of the ramp only the step-sized lead tick 2744 joins its record (n 5)",
            ramped and table.concat(ramped.owners, ",") == "980" and fight[ramped] and fight[ramped].n == 5)
        -- Void Torrent 263165: 3 s channel, first tick in its cast frame (run shadow-steady: 0 / 0.87 / 1.77 / 2.63)
        local function Torrent(key, stop)
            Streams.LogCast(key, 9007, "dot", 9.2) -- inside [10 - 1.08, 10 - 0.45]
            Streams.LogCast(key, 263165, "channel", 10)
            if stop then Streams.StopChannel(stop) end
            for _, t in ipairs({ 10, 10.9, 11.8, 12.7 }) do rig.Hit(key, t) end
            local live = Streams.Live(key, 12.7)[1]

            return live and table.concat(live.owners, ",")
        end
        Check("owners: a birth whose hits all land inside one own channel has that channel as its only owner",
            Torrent("vt1") == "263165" and Streams.Live("vt1", 12.7)[1].ownerKind[263165] == "channel")
        Check("owners: a channel stopped before the birth's last hit leaves the birth window's owners",
            Torrent("vt2", 12.5) == "9007")
        Streams.LogCast("r", 1, "dot", 0); Streams.LogCast("r", 2, "dot", 35); Streams.LogCast("r", 3, "dot", 36)
        log = Streams.CastLog("r")
        Check("cast log: entries older than 35 s are dropped (35 stays, 0 goes)", #log == 2 and log[1].castID == 2)
        local before = #rig.casts
        local ok = pcall(function() Streams.LogCast("r", Secret(7), "dot", 37); Streams.LogCast(nil, 7, "dot", 37) end)
        Check("cast log: a secret castID or a nil key logs nothing and never errors", ok and #rig.casts == before and #Streams.CastLog("r") == 2)
    end

    -- Channel twin rules, both arrival orders ----------------------------------------------
    do
        local function Run(first, second)
            local rig = Rig()
            local Streams = rig.ns.Streams
            Streams.LogCast(first[1], 100, first[2], 5)
            Streams.LogCast(second[1], 100, second[2], 5)
            return rig, Streams
        end
        local rig, Streams = Run({ "plate", "dot" }, { "plate", "channel" })
        Check("twin: SUCCEEDED then CHANNEL_START -> one channel entry, one OnCast",
            #Streams.CastLog("plate") == 1 and Streams.CastLog("plate")[1].kind == "channel" and #rig.casts == 1)
        rig, Streams = Run({ "plate", "channel" }, { "plate", "dot" })
        Check("twin: CHANNEL_START then SUCCEEDED -> one channel entry, one OnCast",
            #Streams.CastLog("plate") == 1 and Streams.CastLog("plate")[1].kind == "channel" and #rig.casts == 1)
        rig, Streams = Run({ "player", "hot" }, { "plate", "channel" })
        Check("twin: a same-frame hot entry on another key is removed by the channel (one OnCast)",
            #Streams.CastLog("player") == 0 and #Streams.CastLog("plate") == 1 and #rig.casts == 1)
        rig, Streams = Run({ "plate", "channel" }, { "player", "hot" })
        Check("twin: a hot SUCCEEDED after the channel is not logged", #Streams.CastLog("player") == 0 and #rig.casts == 1)
        rig = Rig(); Streams = rig.ns.Streams
        Streams.LogCast("plate", 100, "dot", 5); Streams.LogCast("plate", 100, "channel", 6)
        Check("twin: different frames are two casts", #Streams.CastLog("plate") == 2 and #rig.casts == 2)
    end

    -- Drop, Reset, Keys -------------------------------------------------------------------
    do
        local rig = Rig()
        local Streams = rig.ns.Streams
        rig.Hit("x", 0); rig.Hit("x", 2); rig.Hit("x", 4); rig.Hit("x", 6); Streams.LogCast("x", 1, "dot", 6)
        rig.Hit("y", 0); rig.Hit("y", 2); rig.Hit("y", 4); rig.Hit("y", 6)
        Check("streams: Keys lists keys with live streams", #Streams.Keys() == 2)
        Streams.Drop("x")
        Check("streams: Drop clears that key's streams, loose hits and cast log",
            #Streams.Live("x", 6) == 0 and #Streams.CastLog("x") == 0 and #Streams.Live("y", 6) == 1 and #Streams.Keys() == 1)
        Streams.Reset()
        Check("streams: Reset clears every key", #Streams.Keys() == 0 and #Streams.Live("y", 6) == 0)
    end

    -- Tracker.ExplainsHits and the OnLearned hook ---------------------------------------------
    do
        local ns = T.BootSpells()
        local S, Tracker = T.State(), ns.Tracker
        if Has("tracker: ExplainsHits", Tracker, "ExplainsHits") and Has("tracker: OnLearned", Tracker, "OnLearned") then
            local P = T.Plate("nameplate1")
            S.plates.nameplate1, S.haste, S.target = P, 0, "nameplate1"
            Tracker.OnCast("player", 980, 100) -- Agony: castAt 100, period 2
            Check("explains: ticks on castAt + k * period are explained", Tracker.ExplainsHits(P, 32, { 102.1, 104, 106.25 }, 2))
            Check("explains: 0.35 off is outside max(0.1, 0.15 P) = 0.3", not Tracker.ExplainsHits(P, 32, { 102.1, 104, 106.35 }, 2))
            Check("explains: the tolerance comes from the stream's P, not the instance (P 0.5 -> 0.1)",
                not Tracker.ExplainsHits(P, 32, { 102.15, 104, 106 }, 0.5))
            Check("explains: another school or another key is not explained",
                not Tracker.ExplainsHits(P, 4, { 102, 104, 106 }, 2) and not Tracker.ExplainsHits(T.Plate("nameplate2"), 32, { 102, 104, 106 }, 2))
            Check("explains: a secret school never errors and explains nothing",
                select(2, pcall(Tracker.ExplainsHits, P, Secret(32), { 102, 104, 106 }, 2)) == false)
            Tracker.Identify(P, 32, 1000, "", 102.0) -- first tick: lastTick = 102
            Check("explains: after a tick the base is lastTick (104, 106, 108 explained)", Tracker.ExplainsHits(P, 32, { 104, 106, 108 }, 2))
            Check("explains: k >= 1, so a hit at lastTick itself is not explained", not Tracker.ExplainsHits(P, 32, { 102, 104, 106 }, 2))
            Check("tracker: OnLearned exists and does not error", pcall(Tracker.OnLearned, 9001, 100))
        end
    end

    -- Vote store ------------------------------------------------------------------------------
    local function Near(a, b, tolerance) return a ~= nil and math.abs(a - b) <= tolerance end
    local function Fresh(setup, spells) -- real Learn + Streams; Tracker.OnLearned recorded; `spells`: fixture ns.Spells
        local ns = T.Boot(setup, spells)
        local rig = { ns = ns, S = T.State(), learnedCalls = {} }
        rig.S.haste = 0
        ns.Tracker.OnLearned = function(id, now) rig.learnedCalls[#rig.learnedCalls + 1] = { id, now } end
        function rig.Cast(key, t, id, kind) ns.Streams.LogCast(key, id, kind or "dot", t) end
        function rig.Hit(key, t, amount, school, flag)
            ns.Streams.Feed(key, school, amount or 2800, flag or "", t)
        end
        function rig.Sig(id, number) local v = ns.Learn.Votes(id); return v and v.sigs[number or 1] end
        -- Trial: the next fresh key and time slot, one cast at t, then 4 hits one period apart (birth at t + period, found at t + 4 * period)
        local trials = 0
        function rig.Trial(school, id, period, kind, key)
            trials = trials + 1
            key = key or ("t" .. trials)
            local t = 100 * trials
            rig.Cast(key, t, id, kind)
            for step = 1, 4 do rig.Hit(key, t + step * period, 1000, school, "") end
        end
        return rig
    end
    do
        local Learn = T.Boot().Learn
        if not (Has("learn: PoissonTail", Learn, "PoissonTail") and Has("learn: Haste", Learn, "Haste")
            and Has("learn: OnCast", Learn, "OnCast") and Has("learn: OnBirth", Learn, "OnBirth")
            and Has("learn: Votes", Learn, "Votes") and Has("learn: Nudge", Learn, "Nudge")) then return end

        -- luck test values from the spec
        Check("poisson: P(Poisson(0.194) >= 2) = 0.0165 (> ALPHA)", Near(Learn.PoissonTail(0.194, 2), 0.0165, 0.0002))
        Check("poisson: P(Poisson(0.29) >= 3) = 0.003 (<= ALPHA)", Near(Learn.PoissonTail(0.29, 3), 0.003, 0.0005))
        Check("poisson: P-3 DoT, 3 votes at expected 0.525 = 0.016; 4 votes at 0.7 = 0.006",
            Near(Learn.PoissonTail(0.525, 3), 0.016, 0.0007) and Near(Learn.PoissonTail(0.7, 4), 0.006, 0.0005))
        Check("poisson: HoT, 3 votes at expected 0.438 = 0.0101, just above ALPHA", Learn.PoissonTail(0.438, 3) > 0.01
            and Near(Learn.PoissonTail(0.438, 3), 0.0101, 0.0002))
        Check("poisson: 0 votes -> 1, no expectation and 1 vote -> 0", Learn.PoissonTail(0.5, 0) == 1 and Learn.PoissonTail(0, 1) == 0)

        -- Learn.Haste
        local S = T.State()
        S.haste = 25
        Check("haste: plain UnitSpellHaste is returned", Learn.Haste() == 25)
        S.haste = Secret(25)
        local ok, haste = pcall(Learn.Haste)
        Check("haste: a secret value reads as nil, no error", ok and haste == nil)
        UnitSpellHaste = function() error("restricted") end
        ok, haste = pcall(Learn.Haste)
        Check("haste: an erroring API reads as nil", ok and haste == nil)
    end

    -- shaman-fs-forget by hand: 3 fresh plates ------------------------------------------------
    do
        local rig = Fresh()
        local Learn = rig.ns.Learn
        -- birth 1, nameplate10: ticks 23279.594 / 23281.380 (crit) / 23283.057 / 23284.7885, P = 1.7315, chance 0.101
        rig.Cast("np10", 23276.305, 188443); rig.Cast("np10", 23277.994, 188443)
        rig.Cast("np10", 23277.994, 188389); rig.Cast("np10", 23277.994, 470411)
        rig.Hit("np10", 23279.594, 2800, 12); rig.Hit("np10", 23281.380, 5725, 12, "CRITICAL"); rig.Hit("np10", 23283.057, 2800, 12)
        rig.Hit("np10", 23284.7885, 2800, 12)
        local fs, cl = rig.Sig(188389), rig.Sig(188443)
        Check("fs birth 1: FS 1 vote, expected 0.101, base period 1.7315, casts 1; CL 1 vote, expected 0.202, casts 2",
            fs and fs.kind == "dot" and fs.school == 12 and fs.votes == 1 and Near(fs.expected, 0.101, 0.0005)
            and Near(fs.period, 1.7315, 0.001) and Learn.Votes(188389).casts == 1
            and cl and cl.votes == 1 and Near(cl.expected, 0.202, 0.001) and Learn.Votes(188443).casts == 2
            and rig.Sig(470411) and rig.Sig(470411).votes == 1)
        -- birth 2, nameplate5: ticks 23320.192 / 23321.814 (crit) / 23323.363 / 23324.9485, P = 1.5855, chance 0.0925, agrees (8 %)
        rig.Cast("np5", 23318.493, 188389); rig.Cast("np5", 23318.493, 470411)
        rig.Hit("np5", 23320.192, 3000, 12); rig.Hit("np5", 23321.814, 6052, 12, "CRITICAL"); rig.Hit("np5", 23323.363, 3000, 12)
        rig.Hit("np5", 23324.9485, 3000, 12)
        fs = rig.Sig(188389)
        Check("fs birth 2: same sig, 2 votes, expected 0.1935, period merged to 1.7202 (weight 1 + 0.101), casts 2",
            fs and #Learn.Votes(188389).sigs == 1 and fs.votes == 2 and Near(fs.expected, 0.1935, 0.0005)
            and Near(fs.period, 1.7202, 0.001) and Learn.Votes(188389).casts == 2)
        Check("fs birth 2: luck p = 0.0165 > ALPHA -> nothing learned, CL still 1 vote",
            Near(Learn.PoissonTail(fs.expected, fs.votes), 0.0165, 0.0002) and Learn.Get(188389) == nil
            and Learn.Get(470411) == nil and rig.Sig(188443).votes == 1 and #rig.learnedCalls == 0)
        -- birth 3: a third fresh plate, P = 1.6, chance 0.0933 -> votes 3, expected 0.2868, p = 0.0032
        rig.Cast("np7", 23356.2, 188389); rig.Cast("np7", 23356.2, 470411)
        rig.Hit("np7", 23358.0, 2800, 12); rig.Hit("np7", 23359.6, 2800, 12); rig.Hit("np7", 23361.2, 2800, 12); rig.Hit("np7", 23362.8, 2800, 12)
        local entry = Learn.Get(188389)
        Check("fs birth 3: learned (school 12, dot, base ~1.715), votes deleted, 188443 still unlearned",
            entry and entry.school == 12 and entry.mode == "target" and entry.period > 1.70 and entry.period < 1.73
            and Learn.Votes(188389) == nil and Learn.Get(470411) ~= nil and Learn.Get(188443) == nil
            and rig.Sig(188443).votes == 1 and Learn.IsKnownIcon(188389))
        Check("fs birth 3: OnLearned called per spell, ascending id, at the creation time",
            #rig.learnedCalls == 2 and rig.learnedCalls[1][1] == 188389 and rig.learnedCalls[2][1] == 470411
            and Near(rig.learnedCalls[1][2], 23362.8, 1e-6))
    end

    -- Expected from non-owners, chance cap, explained away, known icons -----------------------
    do
        local rig = Fresh()
        local Learn = rig.ns.Learn
        rig.Cast("no", 5, 9301) -- in the rate window only
        rig.Hit("no", 10, 1000, 32)
        rig.Cast("no", 11, 9303) -- after the birth
        rig.Hit("no", 12, 1000, 32); rig.Hit("no", 14, 1000, 32); rig.Hit("no", 16, 1000, 32)
        Check("expected: a cast in the rate window but outside the owner window adds chance 0.7 P / 12, no vote",
            rig.Sig(9301) and rig.Sig(9301).votes == 0 and Near(rig.Sig(9301).expected, 0.7 * 2 / 12, 1e-9)
            and Learn.Votes(9303).casts == 1 and #Learn.Votes(9303).sigs == 0)
        for _, t in ipairs({ 10, 11, 12, 13, 14, 15, 16, 18, 18.5 }) do rig.Cast("mc", t, 9302) end -- n = 9
        rig.Hit("mc", 20, 1000, 32); rig.Hit("mc", 22, 1000, 32); rig.Hit("mc", 24, 1000, 32); rig.Hit("mc", 26, 1000, 32)
        Check("expected: chance is capped at 1 (9 * 0.7 * 2 / 12 = 1.05), and an owner cast twice votes once",
            rig.Sig(9302).expected == 1 and rig.Sig(9302).votes == 1)

        local explained = Fresh()
        local seen
        explained.ns.Tracker.ExplainsHits = function(key, school, hits, P) seen = { key, school, #hits, P }; return true end
        explained.Cast("ea", 8, 9304)
        explained.Hit("ea", 10, 1000, 32); explained.Hit("ea", 12, 1000, 32); explained.Hit("ea", 14, 1000, 32); explained.Hit("ea", 16, 1000, 32)
        Check("explained away: ExplainsHits gets (key, school, 4 hits, P); no sig, no vote, no expected",
            seen and seen[1] == "ea" and seen[2] == 32 and seen[3] == 4 and seen[4] == 2
            and explained.ns.Learn.Votes(9304) and #explained.ns.Learn.Votes(9304).sigs == 0)

        local known = Fresh(nil, true)
        local KL = known.ns.Learn
        T.Store().learned[9801] = { school = 32, period = 3.0, kind = "dot", misses = 0 } -- learned
        known.Cast("k", 8, 445474); known.Cast("k", 8, 980); known.Cast("k", 8, 9801); known.Cast("k", 8, 9802)
        local ok = pcall(KL.OnCast, Secret(5))
        Check("can vote: table keys, tick icons (445474) and learned spells never get an entry; unknown ones do; secret ids are ignored",
            ok and KL.Votes(445474) == nil and KL.Votes(980) == nil and KL.Votes(9801) == nil and KL.Votes(9802).casts == 1)
    end

    -- Wide streams: a ground patch's ticks vote for no cast ------------------------------------
    -- Synthetic Blood DK (dk_blood): Death and Decay 43265's ticks land on all 4 plates in one frame each second and
    -- were learned as the target's DoT in fight 1. `plates` hit each frame, the target first; `lag` delays the others.
    do
        local function Votes(id, plates, lag)
            local rig = Fresh()
            rig.Cast("p1", 10, id)
            for step = 1, 4 do
                for index = 1, plates do rig.Hit("p" .. index, 10 + step + (index > 1 and lag or 0), 5000, 32) end
            end
            local sig = rig.Sig(id)
            return sig and sig.votes or 0
        end
        Check("wide: ticks on 3 plates in each frame give the cast no vote; 2 plates, or 3 a frame apart, still vote",
            Votes(9601, 3, 0) == 0 and Votes(9602, 2, 0) == 1 and Votes(9603, 3, 0.02) == 1)
    end

    -- Thresholds: VOTES_MIN, VOTES_MIN_PHYSICAL, kinds, haste at birth ------------------------
    do
        local rig = Fresh()
        local Learn = rig.ns.Learn
        rig.Trial(32, 9401, 1); rig.Trial(32, 9401, 1) -- chance 0.0583 each: p(2 votes, 0.1167) = 0.0063
        Check("votes: school 32 is learned at 2 votes when p <= 0.01", Learn.Get(9401) ~= nil)
        rig.Trial(1, 9402, 1); rig.Trial(1, 9402, 1)
        Check("votes: school 1 (physical) is not learned at 2 votes although p = 0.0063", Learn.Get(9402) == nil and rig.Sig(9402).votes == 2)
        rig.Trial(1, 9402, 1)
        Check("votes: school 1 is learned at 3 votes (p = 0.0008)", Learn.Get(9402) ~= nil)
        rig.Trial(32, 9403, 1, "channel"); rig.Trial(32, 9403, 1, "channel")
        Check("votes: kinds carry over (channel -> mode channel)", Learn.Get(9403) and Learn.Get(9403).mode == "channel")
        -- a halved birth (Streams' HalfTicks) votes its ticks' period: run mage, Arcane Missiles 5143 learned 0.55 s
        -- from every other missile and the Tracker named every other one
        for trial = 1, 2 do
            local key, t = "half" .. trial, 1000 * trial
            rig.Cast(key, t - 0.05, 9404, "channel")
            for step = 1, 7 do rig.Hit(key, t + 0.3 * step, 1000, 64) end
        end
        Check("votes: a 0.3 s rhythm, born from every other hit, is learned at 0.3 s",
            Learn.Get(9404) ~= nil and Near(Learn.Get(9404).period, 0.3, 1e-6))

        local hasted = Fresh()
        hasted.S.haste = 25
        hasted.Trial(32, 9405, 1)
        Check("haste: a sig stores the base, P * (1 + h / 100) = 1.25", Near(hasted.Sig(9405).period, 1.25, 1e-9))
        local secret = Fresh()
        secret.S.haste = Secret(25)
        local ok = pcall(secret.Trial, 32, 9406, 1)
        Check("haste: a secret haste at birth stores the real period and never errors", ok and Near(secret.Sig(9406).period, 1, 1e-9))
    end

    -- Physical tally: a cast that owns melee noise births only by luck learns no rhythm ----------------------------
    -- Run druid F11: Ravage 441591 (a direct hit) won a physical 1.30 s sig with 4 votes against 0.82 expected while it
    -- owned 9 physical births against 8.1 expected over all its sigs. Here 10 births at P 4 land on plates the spell
    -- was cast on 6 s earlier (in its rate window, outside the owner window: 0.233 expected each, no vote), then three
    -- P 1 trials vote for it: the sig's p is 0.0008, its physical tally 3 votes against 2.5 expected.
    do
        local function Noisy(school, id)
            local rig = Fresh()
            for index = 1, 10 do
                local key, t = "n" .. index, 5000 + 100 * index
                rig.Cast(key, t, id)
                for step = 0, 3 do rig.Hit(key, t + 6 + 4 * step, 1000, school) end
            end
            for _ = 1, 3 do rig.Trial(school, id, 1) end
            return rig
        end
        local melee, spell = Noisy(1, 9411), Noisy(32, 9412)
        local tally = melee.ns.Learn.Votes(9411) and melee.ns.Learn.Votes(9411).physical
        Check("physical tally: a 3-vote sig (p 0.0008) is not learned while the physical tally is luck",
            melee.ns.Learn.Get(9411) == nil and melee.Sig(9411, 2) and melee.Sig(9411, 2).votes == 3)
        Check("physical tally: 3 votes against 2.5 expected (10 noise births at 0.233, 3 trials at 0.058)",
            tally and tally.votes == 3 and Near(tally.expected, 10 * 0.7 * 4 / 12 + 3 * 0.7 / 12, 1e-9))
        Check("physical tally: the same births of school 32 still learn (only physical noise needs it)",
            spell.ns.Learn.Get(9412) ~= nil)
        local saved = Fresh(function()
            CombatTextIconsCharDB = { learned = {}, votes = {
                [9413] = { casts = 2, sigs = { { kind = "dot", school = 1, period = 1, votes = 2, expected = 0.3 },
                    { kind = "dot", school = 1, period = 4, votes = 0, expected = 2 },
                    { kind = "dot", school = 32, period = 2, votes = 1, expected = 0.1 } } },
                [9414] = { casts = 2, sigs = {}, physical = { votes = 5, expected = 9 } },
                [9415] = { casts = 2, sigs = {}, physical = { votes = -1, expected = 9 } } } }
        end).ns.Learn
        local old, kept, bad = saved.Votes(9413).physical, saved.Votes(9414).physical, saved.Votes(9415).physical
        Check("physical tally: a save without one starts from its physical sigs; a valid one is kept, a bad one reset",
            old and kept and bad and old.votes == 2 and Near(old.expected, 2.3, 1e-9) and kept.votes == 5
            and kept.expected == 9 and bad.votes == 0 and bad.expected == 0)
    end

    -- Caps and eviction -----------------------------------------------------------------------
    do
        local rig = Fresh()
        local Learn = rig.ns.Learn
        for _, period in ipairs({ 1, 1, 2, 4, 6, 0.6 }) do rig.Trial(1, 9501, period) end
        local sigs, has1, has06 = Learn.Votes(9501).sigs, false, false
        for _, sig in ipairs(sigs) do
            has1 = has1 or (Near(sig.period, 1, 1e-9) and sig.votes == 2)
            has06 = has06 or (Near(sig.period, 0.6, 1e-9) and sig.votes == 1)
        end
        Check("caps: at most 4 sigs per spell; the fewest-votes sig goes, the new one and the 2-vote one stay",
            #sigs == 4 and has1 and has06)
        local capped = Fresh().ns.Learn
        for id = 10001, 10128 do capped.OnCast(id) end
        for _ = 1, 4 do capped.OnCast(10001) end
        capped.OnCast(20000)
        local present = 0
        for id = 10001, 10128 do if capped.Votes(id) then present = present + 1 end end
        Check("caps: 128 spells; the 129th evicts a fewest-casts spell, never itself nor the 5-cast one",
            present == 127 and capped.Votes(20000) and capped.Votes(20000).casts == 1 and capped.Votes(10001).casts == 5)
    end

    -- One cast, one vote ----------------------------------------------------------------------
    do
        local ns = T.Boot(function(S) S.group = true end)
        local K = "nameplate1"
        ns.Streams.LogCast(K, 9501, "dot", 0)
        -- Two strangers, same school and period 0.6, different sizes: the one cast sits in both owner windows.
        for _, hit in ipairs({ { 0.45, 1000 }, { 0.50, 5000 }, { 1.05, 1000 }, { 1.10, 5000 }, { 1.65, 1000 }, { 1.70, 5000 }, { 2.25, 1000 }, { 2.30, 5000 } }) do
            ns.Streams.Feed(K, 8, hit[2], "", hit[1])
        end
        local votes = ns.Learn.Votes(9501)
        local sig = votes and votes.sigs[1]
        Check("votes: one cast inside the owner windows of two same-school same-period births gets 1 vote, not a learn",
            #ns.Streams.Live(K, 2.3) == 2 and sig and sig.votes == 1 and ns.Learn.Get(9501) == nil)
    end

    -- Init validation, Forget, Missed, Nudge ----------------------------------------------------
    do
        local function Good() return { kind = "dot", school = 32, period = 3, votes = 1, expected = 0.2 } end
        local function Sig(votes, period) return { kind = "dot", school = 32, period = period, votes = votes, expected = 0.1 } end
        local rig = Fresh(function()
            local saved = {
                [100] = { casts = 3, sigs = { Good() } },
                [101] = { casts = -1, sigs = {} },
                [102] = { casts = 1, sigs = { { kind = "aura", school = 32, period = 3, votes = 1, expected = 0.2 }, Good() } },
                [103] = "junk",
                [104] = { casts = 1, sigs = "junk" },
                [106] = { casts = 1, sigs = { Sig(5, 1), Sig(4, 2), Sig(3, 3), Sig(2, 4), Sig(1, 5) } },
                x = { casts = 1, sigs = {} },
            }
            CombatTextIconsCharDB = { learned = {}, pending = {}, votes = saved }
        end)
        local Learn = rig.ns.Learn
        Check("init: invalid vote entries dropped (casts < 0, junk, non-table sigs, non-number key); a bad sig is dropped alone",
            Learn.Votes(100) and #Learn.Votes(100).sigs == 1 and Learn.Votes(101) == nil and Learn.Votes(103) == nil
            and Learn.Votes(104) == nil and T.Store().votes.x == nil and #Learn.Votes(102).sigs == 1)
        local periods = {}
        for _, sig in ipairs(Learn.Votes(106).sigs) do periods[#periods + 1] = sig.period end
        table.sort(periods)
        Check("init: more than 4 sigs keep the 4 with the most votes", table.concat(periods, ",") == "1,2,3,4")
        local many = Fresh(function()
            local saved = {}
            for id = 1000, 1129 do saved[id] = { casts = id - 999, sigs = {} } end
            CombatTextIconsCharDB = { learned = {}, pending = {}, votes = saved }
        end)
        local count = 0
        for id = 1000, 1129 do if many.ns.Learn.Votes(id) then count = count + 1 end end
        Check("init: more than 128 saved spells keep the 128 with the most casts",
            count == 128 and many.ns.Learn.Votes(1000) == nil and many.ns.Learn.Votes(1129) ~= nil)

        rig = Fresh()
        Learn = rig.ns.Learn
        rig.Trial(32, 9601, 1)
        local votesRef = T.Store().votes
        Learn.Forget()
        Check("forget: clears votes in place", Learn.Votes(9601) == nil and next(T.Store().votes) == nil
            and T.Store().votes == votesRef)
        T.Store().learned[9602] = { school = 32, period = 3.0, kind = "dot", misses = 0 }
        T.Store().votes[9602] = { casts = 1, sigs = {} }
        Learn.Missed(9602)
        Check("missed: one miss keeps learned and votes", Learn.Get(9602) ~= nil and Learn.Votes(9602) ~= nil)
        Learn.Missed(9602)
        Check("missed: the second miss clears learned and votes", Learn.Get(9602) == nil and Learn.Votes(9602) == nil)

        T.Store().learned[9701] = { school = 32, period = 2.2, kind = "dot", misses = 0 }
        local saved = T.Store().learned[9701]
        Learn.Nudge(9701, 2.4)
        Check("nudge: base <- 0.9 * 2.2 + 0.1 * 2.4 = 2.22", Near(saved.period, 2.22, 1e-9))
        Learn.Nudge(9701, 5.0); Learn.Nudge(9701, 3.0); Learn.Nudge(9999, 2.4)
        local ok = pcall(Learn.Nudge, 9701, Secret(2))
        Check("nudge: samples beyond 25 % (5.0, 3.0), unknown ids and secret samples change nothing", ok and Near(saved.period, 2.22, 1e-9))
        Learn.Nudge(9701, 2.76)
        Check("nudge: a sample within 25 % of the larger (2.76) is taken", Near(saved.period, 0.9 * 2.22 + 0.1 * 2.76, 1e-9))
    end

    -- Raid sim (Monte Carlo, seeded) ---------------------------------------------------------
    do
        local RAID_TRIALS, DURATION, KEY = 1000, 300, "nameplate1"
        local SETTINGS = { { perMinute = 1, seed = 20261022 }, { perMinute = 3, seed = 31415926 }, { perMinute = 6, seed = 27182818 } }
        local CASTERS = { { id = 9101, every = 2, jitter = 0.15 }, { id = 9102, every = 4, jitter = 0.5 }, { id = 9103, every = 30, jitter = 5 } }
        local SWINGS = { 3000, 4500, 7000 }

        -- Park-Miller: the same numbers on every Lua version (math.random differs between 5.3 and 5.4).
        local function Rng(seed)
            local state = seed
            return function() state = (state * 16807) % 2147483647 return state / 2147483647 end
        end

        -- One trial's events, sorted by time: { t, cast = id } or { t, school, amount, flag }. Also returns the stranger-stream count.
        local function Trial(rand, perMinute)
            local events, strangers = {}, 0
            local function Jitter(width) return (rand() * 2 - 1) * width end
            local arrival, k = 0, 0
            while true do
                arrival = arrival - math.log(1 - rand()) / (perMinute / 60)
                if arrival >= DURATION then break end
                strangers = strangers + 1
                local amount = math.floor(1000 * 1.3 ^ (k % 12))
                k = k + 1
                for tick = 0, 5 do events[#events + 1] = { t = arrival + 2 * tick + Jitter(0.02), school = 32, amount = amount, flag = "" } end
            end
            for _, base in ipairs(SWINGS) do
                local t = rand() * 2.6
                while t < DURATION do
                    if rand() >= 0.05 then
                        local amount = math.floor(base * (0.9 + 0.2 * rand()) + 0.5)
                        local crit = rand() < 0.15
                        events[#events + 1] = { t = t + Jitter(0.02), school = 1, amount = crit and amount * 2 or amount, flag = crit and "CRITICAL" or "" }
                    end
                    t = t + 2.6
                end
            end
            for _, caster in ipairs(CASTERS) do
                local t = rand() * caster.every
                while t < DURATION do events[#events + 1] = { t = t, cast = caster.id } t = t + caster.every + Jitter(caster.jitter) end
            end
            table.sort(events, function(a, b) return a.t < b.t end)
            return events, strangers
        end

        -- Runs `trials` trials; { perTrial = { learnedCount, ... }, strangers, births }.
        local function RunSetting(setting, trials)
            local ns = T.Boot()
            local out, rand = { perTrial = {}, strangers = 0, births = 0 }, Rng(setting.seed)
            local onBirth = ns.Learn.OnBirth
            ns.Learn.OnBirth = function(...) out.births = out.births + 1 return onBirth(...) end
            for trial = 1, trials do
                ns.Learn.Forget(); ns.Streams.Reset()
                local events, strangers = Trial(rand, setting.perMinute)
                out.strangers = out.strangers + strangers
                for _, e in ipairs(events) do
                    if e.cast then ns.Streams.LogCast(KEY, e.cast, "dot", e.t)
                    else ns.Streams.Feed(KEY, e.school, e.amount, e.flag, e.t) end
                end
                local count = 0
                for _ in pairs(T.Store().learned) do count = count + 1 end
                out.perTrial[trial] = count
            end
            return out
        end

        local started = os.clock()
        local notes = {}
        for _, setting in ipairs(SETTINGS) do
            local run = RunSetting(setting, RAID_TRIALS)
            local learnedTrials = 0
            for _, count in ipairs(run.perTrial) do if count > 0 then learnedTrials = learnedTrials + 1 end end
            local again = RunSetting(setting, 3)
            Check(string.format("raid sim %d/min: %d of %d trials learned something (limit 2 %%)", setting.perMinute, learnedTrials, RAID_TRIALS),
                learnedTrials <= 0.02 * RAID_TRIALS)
            Check(string.format("raid sim %d/min: fixed seed %d, the first trial learns nothing", setting.perMinute, setting.seed), run.perTrial[1] == 0)
            Check(string.format("raid sim %d/min: the same seed gives the same first 3 trials (no hidden randomness)", setting.perMinute),
                again.perTrial[1] == run.perTrial[1] and again.perTrial[2] == run.perTrial[2] and again.perTrial[3] == run.perTrial[3])
            local expected = setting.perMinute * DURATION / 60 * RAID_TRIALS
            Check(string.format("raid sim %d/min: generator makes about %d stranger streams, and the learner sees a birth for most of them", setting.perMinute, expected),
                math.abs(run.strangers - expected) <= 0.08 * expected and run.births >= 0.8 * run.strangers)
            notes[#notes + 1] = string.format("%d/min %d/%d (%.1f %%)", setting.perMinute, learnedTrials, RAID_TRIALS, learnedTrials / RAID_TRIALS * 100)
        end
        T.Note(string.format("raid sim, learned something in: %s; %.1f s", table.concat(notes, ", "), os.clock() - started))
    end
end
