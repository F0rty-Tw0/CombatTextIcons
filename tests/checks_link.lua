-- Unit checks for Link.lua (a cast's hits on the plates around its target, filed under a row of another ID): the
-- learner Link.Learn, the hit-time lookup Link.Name, its saved store, and the Core route that draws a learned link.
-- Called by tests/checks.lua with the same T table (see its header).

return function(T)
    local Check = T.Check
    local PHYSICAL, CAST, ROW, OTHER = 1, 9101, 9100, 9102
    local HIT = 1000

    -- A booted addon with its link store on the booted char DB; the game names ROW the base of CAST (an override).
    local function Rig()
        local ns = T.Boot()
        T.State().baseSpells[CAST] = ROW
        ns.Link.Init(T.Store())

        return ns
    end
    -- Two casts of CAST (base ROW, the game's override pair) on plate "p1", 10 s apart; each puts its own hit on
    -- "p1", one like-sized hit on each of "p2" and "p3" in its frame (the second cast's "p3" hit a crit) and a small
    -- splash on "p2". Returns the read, the like-sized hits' sum and the casts' own sum.
    local function Read(plateless)
        local run, sum, own = { unknown = {}, casts = {}, tally = {} }, 0, 0
        for cast = 1, 2 do
            local at = cast * 10
            run.casts[#run.casts + 1] = { spellID = CAST, base = ROW, at = at, plate = not plateless and "p1" or nil }
            local function Add(plate, size, crit, delay)
                local amount = crit and size * 2 or size
                run.unknown[#run.unknown + 1] = { at = at + delay, school = PHYSICAL, size = size, amount = amount,
                    crit = crit, plate = plate }
                return amount
            end
            own = own + Add("p1", 3000, false, 0)
            sum = sum + Add("p2", HIT + cast * 10, false, 0) + Add("p3", HIT, cast == 2, 0.1)
            Add("p2", 300, false, 0.05)
        end

        return run, sum, own
    end
    local function Learn(ns, run, rows)
        local open, rewritten, results = {}, {}, {}
        for index, row in ipairs(rows) do
            results[index] = { spellID = row.spellID, verdict = "unpaired" }
            open[#open + 1] = { row = row, index = index }
        end

        return ns.Link.Learn(run, rows, open, rewritten, results, {}), results, rewritten
    end
    -- The fight's rows: the casts' own (the splash under it is past the window) and the like-sized hits' row.
    local function Rows(run, sum, own)
        return { { spellID = CAST, total = own + 600 }, { spellID = ROW, total = sum } }
    end

    do -- two fights of exact evidence learn the link; the first is evidence only
        local ns = Rig()
        local run, sum, own = Read()
        local ways, results, rewritten = Learn(ns, run, Rows(run, sum, own))
        local entry = ns.Link.Get(ROW)
        Check("link: one fight whose hits around the target meet a row of another ID is evidence, not a link",
            #ways == 0 and entry ~= nil and entry.castID == CAST and entry.fights == 1 and results[2].verdict == "unpaired"
            and not rewritten[2])
        Check("link: the store is the char DB's links table", T.Store().links[ROW] == entry)

        ways, results, rewritten = Learn(ns, run, Rows(run, sum, own))
        entry = ns.Link.Get(ROW)
        Check("link: the second exact fight learns the link: its 4 like-sized hits meet the row, the row agrees",
            #ways == 1 and ways[1].castID == CAST and ways[1].sum == sum and #ways[1].hits == 4
            and entry.fights == 2 and entry.base == ROW and entry.school == PHYSICAL and entry.lo == HIT and entry.hi == HIT + 20
            and entry.delayLo == 0 and math.abs(entry.delayHi - 0.1) < 1e-9
            and results[2].verdict == "agree" and results[2].spellID == ROW and rewritten[2] == true
            and results[1].verdict == "unpaired")

        ns.Link.NoteCast(CAST, 100, "p1")
        Check("link: after the cast, a like-sized hit on another plate inside the learned delays draws the row",
            ns.Link.Name("p2", PHYSICAL, HIT, "", 100.05) == ROW and ns.Link.Name("p3", PHYSICAL, HIT * 2, "CRITICAL", 100.1) == ROW)
        Check("link: a hit on the cast's own plate, of another school or size, or past the delays is not the link's",
            ns.Link.Name("p1", PHYSICAL, HIT, "", 100.05) == nil and ns.Link.Name("p2", 4, HIT, "", 100.05) == nil
            and ns.Link.Name("p2", PHYSICAL, 300, "", 100.05) == nil and ns.Link.Name("p2", PHYSICAL, HIT, "", 100.3) == nil)
        ns.Link.NoteCast(OTHER, 200, "p1")
        Check("link: a cast of another spell keeps no draw window", ns.Link.Name("p2", PHYSICAL, HIT, "", 200.05) == nil)
        ns.Link.NoteCast(ROW, 300, "p1")
        Check("link: a cast of A's base family (the base itself) opens the window too",
            ns.Link.Name("p2", PHYSICAL, HIT, "", 300.05) == ROW)

        ns.Link.Forget()
        Check("link: /cti forget drops the link", ns.Link.Get(ROW) == nil)
    end

    do -- what learns nothing: the row's spell cast this fight, two rows the window meets, a plateless cast
        local ns = Rig()
        local run, sum, own = Read()
        run.casts[#run.casts + 1] = { spellID = ROW, base = ROW, at = 30, plate = "p1" }
        Learn(ns, run, Rows(run, sum, own))
        Check("link: a row whose own spell is cast this fight gathers no evidence", ns.Link.Get(ROW) == nil)

        run, sum, own = Read()
        local rows = Rows(run, sum, own)
        rows[3] = { spellID = OTHER, total = sum }
        Learn(ns, run, rows)
        Check("link: a window two open rows meet gathers no evidence",
            ns.Link.Get(ROW) == nil and ns.Link.Get(OTHER) == nil)

        run, sum, own = Read(true)
        Learn(ns, run, Rows(run, sum, own))
        Check("link: a cast with no plate gathers no evidence", ns.Link.Get(ROW) == nil)

        run, sum, own = Read()
        rows = Rows(run, sum, own)
        rows[2].total = sum + 500
        Learn(ns, run, rows)
        Check("link: a sum short of the row gathers no evidence", ns.Link.Get(ROW) == nil)
    end

    do -- a learned link drawn past its row is dropped by the next clear read
        local ns = Rig()
        local run, sum, own = Read()
        Learn(ns, run, Rows(run, sum, own))
        Learn(ns, run, Rows(run, sum, own))
        local learned = ns.Link.Get(ROW) ~= nil
        Learn(ns, { unknown = {}, casts = {}, tally = { [ROW] = sum * 2 } }, Rows(run, sum, own))
        Check("link: a clear read that finds the row drawn past it drops the link", learned and ns.Link.Get(ROW) == nil)
    end

    do -- saved data: a save from before links loads, and a bad entry is dropped
        local ns = T.Boot()
        local store = T.Store()
        store.links = nil
        ns.Link.Init(store)
        Check("link: a save with no links table loads with an empty one", type(store.links) == "table" and next(store.links) == nil)
        local good = { castID = CAST, school = PHYSICAL, lo = HIT, hi = HIT, delayLo = 0, delayHi = 0.1, fights = 2 }
        store.links = { [ROW] = good, [OTHER] = { castID = "x", school = PHYSICAL, fights = 2 }, [7] = "bad" }
        ns.Link.Init(store)
        Check("link: Init keeps a valid saved link and drops malformed ones",
            ns.Link.Get(ROW) == good and store.links[OTHER] == nil and store.links[7] == nil)
    end

    do -- the hit route: a learned link's hit on a plate next to the cast's target draws the row
        local ns = T.Boot(function() CombatTextIconsDB = { enabled = true } end)
        local S = T.State()
        ns.Teacher.area = "clear"
        local drawn = {}
        local inner = ns.Teacher.Drawn
        ns.Teacher.Drawn = function(spellID, amount, ...)
            drawn[#drawn + 1] = spellID
            return inner(spellID, amount, ...)
        end
        T.Store().links = { [ROW] = { castID = CAST, school = PHYSICAL, lo = HIT, hi = HIT, delayLo = 0, delayHi = 0.1,
            fights = 2 } }
        ns.Link.Init(T.Store())
        S.now, S.target = 50, "nameplate1"
        ns.Core.UNIT_SPELLCAST_SUCCEEDED("player", "c50", CAST)
        S.now = 50.05
        ns.Core.UNIT_COMBAT("nameplate2", "WOUND", "", HIT, PHYSICAL)
        Check("link route: after the cast, a like-sized hit on the next plate draws the linked row",
            drawn[#drawn] == ROW)
    end
end
