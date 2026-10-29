-- Combat Text Icons: area pass. A learned direct-hit spell draws one hit per cast on its target's plate, while its
-- meter row may also hold the same cast's hits on the plates around it: an AoE's other targets. The row's residual
-- (its total, overkill and Judge's tolerance, less what was drawn under it this fight) bounds them. Per base learned
-- before this read (single pattern) that drew this fight, the '?' hits of its school inside its padded size band on
-- another plate than its cast's, AREA_SLACK below its learned window to Casts.SPLASH past its top after its newest
-- cast, are summed. When the sum fits the residual and explains at least SHARE of it, with MIN_HITS hits or more,
-- the base is marked area (Fingerprints.SetArea): its records then take such hits on other plates (Casts.lua).
-- When it does not, the hits from Casts.AREA_LO of its smallest size are summed instead: run paladin2's Hammer of
-- Light 427453 splashed 25-29K beside its 45-46K target hit, none in the padded band. Only then, as the lower floor
-- also takes other spells' hits: druid2 F1's Swipe 106785 summed 21 hits (209345) in a room of 212108, the lower floor
-- added a 4765 one (214110), and paladin2's 53600 went from 5 hits (12741, room 12971) to 8 (16493). Of those hits
-- the ones that share their frame with another on another plate must explain the residual too (Framed), and their
-- sum must not be another row's with nothing drawn under it (OtherRowSum). A base marked so is areaLow
-- (Fingerprints.SetArea).
-- Run shaman6 F2: Lava Burst 51505 (learned, window 0.12-0.28 s) drew 570245 of its 1183551 row; 9 Fire hits on 4
-- other plates in that span summed 613306 against a residual of 625142. Hunter F3's Kill Command 17253 drew 22960 of
-- 29658, and Beast Cleave's 84 hits on 4 plates (151786) are far past its residual: no area.
-- Learned hits leave the '?' that Procs.Read then sees. With /cti debug each tried base logs one TEACH area line.

local _, ns = ...
local Fingerprints, Casts = ns.Fingerprints, ns.Casts

local Area = {}
ns.Area = Area

local SHARE = 0.5       -- of the residual the other plates' hits must explain at least
local MIN_HITS = 2      -- other-plate hits at least
local AREA_SLACK = 0.05 -- a hit may land this far below the learned window (Casts' SLACK)

-- The newest of `casts` at or before `at` within `reach`, when it was cast at a plate other than `plate`, else nil.
local function OtherPlateCast(casts, at, plate, reach)
    local newest
    for _, cast in ipairs(casts) do
        if cast.at <= at and at - cast.at <= reach and (not newest or cast.at > newest.at) then newest = cast end
    end
    if newest and newest.plate ~= nil and newest.plate ~= plate then return newest end
end

-- Whether `hit` after `cast` of `castID` lands in the area span and in its band from `floor` (Casts.InBand).
local function InArea(castID, cast, hit, floor)
    local low, high = Fingerprints.Window(castID, cast.spellID)
    if not low then return false end
    local delay = hit.at - cast.at

    return delay >= low - AREA_SLACK and delay <= high + Casts.SPLASH
        and Casts.InBand(castID, cast.spellID, hit.size, floor)
end

-- The fresh '?' hits of `fp`'s school on other plates than `castID`'s casts that land InArea from `floor`:
-- { castID, sum, hits }.
local function Gather(run, castID, fp, casts, spent, floor)
    local way = { castID = castID, sum = 0, hits = {} }
    for _, hit in ipairs(run.unknown) do
        local fresh = not spent[hit] and hit.school == fp.school
        local cast = fresh and OtherPlateCast(casts, hit.at, hit.plate, fp.delayHi + Casts.SPLASH)
        if cast and InArea(castID, cast, hit, floor) then
            way.sum = way.sum + hit.amount
            way.hits[#way.hits + 1] = hit
        end
    end

    return way
end

-- `way` with only its hits that share their frame with another of its hits on another plate: an AoE's splash lands on
-- the plates around its target at once. Run paladin2 F2: Hammer of Light 427453's 12 hits under PAD_LO came 4 to a
-- frame, one frame per cast (0.59-0.60 s after it). Run priest4 F2: Devouring Plague 335467 summed 51 such hits
-- (169593, room 336534: 50.4 %), 10 of them alone in their frame; the fight's Psychic Link 199486 row (759021) likely
-- holds them, and the marked plague then drew Shadow hits on other plates in F3-F17 (Vampiric Touch 34914 lost a 5736
-- in F16). Its 41 framed hits (131289) explain too little.
local function Framed(way)
    local plates = {}
    for _, hit in ipairs(way.hits) do
        plates[hit.at] = plates[hit.at] or {}
        plates[hit.at][hit.plate] = true
    end
    local framed = { castID = way.castID, sum = 0, hits = {} }
    for _, hit in ipairs(way.hits) do
        local others = false
        for plate in pairs(plates[hit.at]) do others = others or plate ~= hit.plate end
        if others then
            framed.sum = framed.sum + hit.amount
            framed.hits[#framed.hits + 1] = hit
        end
    end

    return framed
end

-- Whether `way`'s hits sum to a row of another ID than `own` with nothing drawn under it (Teacher's Judge: within 1 %
-- of its total, overkill above it): that row's hits, which Procs.Read then learns. Run druid F10: the lower floor
-- gathered Ravage 441591's 8 hits on other plates in its casts' frames (17596-51399, 0.54-0.79 of its smallest),
-- 259771 in a room of 401762; the meter files them under Ferocious Bite 22568, 259771 exactly, and without them
-- Ferocious Bite's splashes in F11-F12 stayed '?'.
local function OtherRowSum(way, own, rows, tally)
    for _, row in ipairs(rows) do
        local tol = math.max(1, row.total / 100)
        if row.spellID ~= own.spellID and not tally[row.spellID] and way.sum >= row.total - tol
            and way.sum <= row.total + row.overkill + tol then
            return true
        end
    end

    return false
end

-- The area pass of one read. `learned` holds the ways this read learned (their hits are spent, their bases skipped).
-- Returns the ways it marked area { castID, sum, hits }.
function Area.Learn(run, rows, learned)
    local spent, learnedNow = {}, {}
    for _, way in ipairs(learned) do
        learnedNow[way.castID] = true
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local castsOf, order = {}, {}
    for _, cast in ipairs(run.casts or {}) do
        if not castsOf[cast.base] then
            castsOf[cast.base] = {}
            order[#order + 1] = cast.base
        end
        table.insert(castsOf[cast.base], cast)
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local fp, drawn = Fingerprints.Get(castID), run.tally[castID] or 0
        local row = ns.Steady.RowOf(castID, rows)
        if fp and fp.learned and fp.pattern == "single" and fp.delayHi and not fp.area and not learnedNow[castID]
            and drawn > 0 and row then
            local room = row.total + row.overkill + math.max(1, row.total / 100) - drawn
            local function Explains(way) return #way.hits >= MIN_HITS and way.sum <= room and way.sum >= SHARE * room end
            local way = Gather(run, castID, fp, castsOf[castID], spent)
            local low = not Explains(way)
            if low then way = Gather(run, castID, fp, castsOf[castID], spent, Casts.AREA_LO) end
            local fits = Explains(way)
                and not (low and (not Explains(Framed(way)) or OtherRowSum(way, row, rows, run.tally)))
            if fits then
                Fingerprints.SetArea(castID, low)
                ways[#ways + 1] = way
            end
            if ns.Debug and #way.hits > 0 then
                ns.Debug("TEACH area %d hits=%d sum=%d room=%d -> %s", castID, #way.hits, math.floor(way.sum),
                    math.floor(room), fits and "learned" or "refused")
            end
        end
    end

    return ways
end
