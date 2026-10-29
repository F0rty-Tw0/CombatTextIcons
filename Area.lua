-- Combat Text Icons: area pass. A learned direct-hit spell draws one hit per cast on its target's plate, while its
-- meter row may also hold the same cast's hits on the plates around it: an AoE's other targets. The row's residual
-- (its total, overkill and Judge's tolerance, less what was drawn under it this fight) bounds them. Per base learned
-- before this read (single pattern) that drew this fight, the '?' hits of its school inside its padded size band on
-- another plate than its cast's, AREA_SLACK below its learned window to Casts.SPLASH past its top after its newest
-- cast, are summed. When the sum fits the residual and explains at least SHARE of it, with MIN_HITS hits or more,
-- the base is marked area (Fingerprints.SetArea): its records then take such hits on other plates (Casts.lua).
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

-- Whether `hit` after `cast` of `castID` lands in the area span and band.
local function InArea(castID, cast, hit)
    local low, high = Fingerprints.Window(castID, cast.spellID)
    if not low then return false end
    local delay = hit.at - cast.at

    return delay >= low - AREA_SLACK and delay <= high + Casts.SPLASH and Casts.InBand(castID, cast.spellID, hit.size)
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
            local way = { castID = castID, sum = 0, hits = {} }
            for _, hit in ipairs(run.unknown) do
                local fresh = not spent[hit] and hit.school == fp.school
                local cast = fresh and OtherPlateCast(castsOf[castID], hit.at, hit.plate, fp.delayHi + Casts.SPLASH)
                if cast and InArea(castID, cast, hit) then
                    way.sum = way.sum + hit.amount
                    way.hits[#way.hits + 1] = hit
                end
            end
            local fits = #way.hits >= MIN_HITS and way.sum <= room and way.sum >= SHARE * room
            if fits then
                Fingerprints.SetArea(castID)
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
