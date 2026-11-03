-- Unit checks for Volley.lua (a cast's burst of equal bolts): the learner Volley.Learn and the hit-time lookup
-- Volley.Name. Called by tests/checks.lua with the same T table (see its header).

return function(T)
    local Check = T.Check
    local SHADOW, CAST, BASE, ROW, OTHER = 32, 9001, 9000, 9002, 9003
    local BOLT = 2731

    -- A booted addon with its volley store on the booted char DB.
    local function Rig()
        local ns = T.Boot()
        ns.Volley.Init(T.Store())

        return ns
    end
    -- `count` casts of CAST 10 s apart, each followed by `bolts` Shadow bolts 0.1 s apart (the second a crit) and one
    -- lone Shadow co-hit of another size; returns the read and the bolts' sum.
    local function Read(count, bolts)
        local run, sum = { unknown = {}, casts = {}, tally = {} }, 0
        for cast = 1, count do
            local at = cast * 10
            run.casts[#run.casts + 1] = { spellID = CAST, base = BASE, at = at }
            for bolt = 1, bolts do
                local crit = bolt == 2
                local amount = crit and BOLT * 2 or BOLT
                run.unknown[#run.unknown + 1] = { at = at + bolt / 10, school = SHADOW, size = BOLT, amount = amount, crit = crit }
                sum = sum + amount
            end
            run.unknown[#run.unknown + 1] = { at = at + 0.15, school = SHADOW, size = 8000, amount = 8000, crit = false }
        end

        return run, sum
    end
    local function Learn(ns, run, rows)
        local open, rewritten, results = {}, {}, {}
        for index, row in ipairs(rows) do
            results[index] = { spellID = row.spellID, verdict = "unpaired" }
            open[#open + 1] = { row = row, index = index }
        end

        return ns.Volley.Learn(run, rows, open, rewritten, results, {}), results, rewritten
    end

    do -- three casts of five bolts: the bolts' sum learns the one row it fits, and its size band
        local ns = Rig()
        local run, sum = Read(3, 5)
        local rows = { { spellID = ROW, total = sum + 50 }, { spellID = OTHER, total = sum * 4 } }
        local ways, results, rewritten = Learn(ns, run, rows)
        local entry = ns.Volley.Get(CAST)
        Check("volley: three casts' bursts of equal bolts learn the one row their sum fits",
            #ways == 1 and ways[1].castID == CAST and ways[1].sum == sum and #ways[1].hits == 15
            and entry ~= nil and entry.row == ROW and entry.school == SHADOW and entry.lo == BOLT and entry.hi == BOLT
            and results[1].verdict == "under" and rewritten[1] == true and results[2].verdict == "unpaired")
        Check("volley: the store is the char DB's volleys table", T.Store().volleys[CAST] == entry)

        ns.Volley.NoteCast(CAST, 100)
        local first = ns.Volley.Name(SHADOW, BOLT, "", 100.1)
        local second = ns.Volley.Name(SHADOW, BOLT * 2, "CRITICAL", 100.2)
        local third = ns.Volley.Name(SHADOW, BOLT, "", 100.3)
        Check("volley: after its cast, a bolt whose size a bolt just before repeats draws the row; the first stays '?'",
            first == nil and second == ROW and third == ROW)
        Check("volley: a hit of another school or size, or past the gap, is no bolt",
            ns.Volley.Name(4, BOLT, "", 100.4) == nil and ns.Volley.Name(SHADOW, 8000, "", 100.45) == nil
            and ns.Volley.Name(SHADOW, 3000, "", 100.5) == nil and ns.Volley.Name(SHADOW, BOLT, "", 101.5) == nil)
        Check("volley: the window shuts SPAN after the cast",
            ns.Volley.Name(SHADOW, BOLT, "", 103.5) == nil and ns.Volley.Name(SHADOW, BOLT, "", 103.6) == nil)

        ns.Volley.Forget()
        Check("volley: /cti forget drops the learned volley", ns.Volley.Get(CAST) == nil)
    end

    do -- what learns nothing: two casts, two rows the sum fits, a row the cast owns, lone hits
        local ns = Rig()
        local run, sum = Read(2, 5)
        Check("volley: two casts learn nothing", #Learn(ns, run, { { spellID = ROW, total = sum } }) == 0)
        run, sum = Read(3, 5)
        Check("volley: a sum two rows fit learns nothing",
            #Learn(ns, run, { { spellID = ROW, total = sum }, { spellID = OTHER, total = sum + 10 } }) == 0)
        Check("volley: a cast with a row of its own learns nothing",
            #Learn(ns, run, { { spellID = ROW, total = sum }, { spellID = CAST, total = 1000 } }) == 0)
        run, sum = Read(3, 1)
        Check("volley: one hit per cast is no volley", #Learn(ns, run, { { spellID = ROW, total = sum } }) == 0)
        Check("volley: nothing learned, no store entry", ns.Volley.Get(CAST) == nil)
    end

    do -- a learned volley drawn past its row is dropped by the next clear read
        local ns = Rig()
        local run, sum = Read(3, 5)
        Learn(ns, run, { { spellID = ROW, total = sum } })
        local learned = ns.Volley.Get(CAST) ~= nil
        local judged = { unknown = {}, casts = {}, tally = { [ROW] = 9000 } }
        Learn(ns, judged, { { spellID = ROW, total = 5000 } })
        Check("volley: a clear read that finds the row drawn past it drops the volley", learned and ns.Volley.Get(CAST) == nil)
    end
end
