-- Combat Text Icons: area pass. A learned direct-hit spell draws one hit per cast on its target's plate, while its
-- meter row may also hold the same cast's hits on the plates around it: an AoE's other targets. The row's residual
-- (its total, overkill and Judge's tolerance, less what was drawn under it this fight) bounds them. Per base learned
-- before this read (single pattern) that drew this fight, or learned at it by the steady pass alone (its counted hits
-- stand for the drawn: Area.Learn), the '?' hits and frame mates (Teacher.Mate: hits on dummies no one fights, in a
-- solo hit's frame) of its school inside its padded size band on
-- another plate than its cast's, AREA_SLACK below its learned window to Casts.SPLASH past its top after its newest
-- cast, are summed. When the sum fits the residual and explains at least SHARE of it, with MIN_HITS hits or more,
-- the base is marked area (Fingerprints.SetArea): its records then take such hits on other plates (Casts.lua). One
-- padded-band hit is enough when it lands in an own hit's frame and closes the row (Area.Learn).
-- When it does not, the hits from Casts.AREA_LO of its smallest size are summed instead: run paladin2's Hammer of
-- Light 427453 splashed 25-29K beside its 45-46K target hit, none in the padded band. Only then, as the lower floor
-- also takes other spells' hits: druid2 F1's Swipe 106785 summed 21 hits (209345) in a room of 212108, the lower floor
-- added a 4765 one (214110), and paladin2's 53600 went from 5 hits (12741, room 12971) to 8 (16493). Of those hits
-- the ones that share their frame with another on another plate or an own hit must explain the residual too (Framed),
-- and their sum must not be another row's with nothing drawn under it (OtherRowSum). A base marked so is areaLow
-- (Fingerprints.SetArea).
-- Run shaman6 F2: Lava Burst 51505 (learned, window 0.12-0.28 s) drew 570245 of its 1183551 row; 9 Fire hits on 4
-- other plates in that span summed 613306 against a residual of 625142. Hunter F3's Kill Command 17253 drew 22960 of
-- 29658, and Beast Cleave's 84 hits on 4 plates (151786) are far past its residual: no area.
-- Learned hits leave the '?' that Procs.Read then sees. With /cti debug each tried base logs one TEACH area line.
-- The twin pass (Area.Twins) does the same for a learned DoT or channel's ticks: their fixed share on other plates.

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

-- The fresh '?' hits, and with `mates` the frame mates (Teacher.Mate), of `fp`'s school on other plates than
-- `castID`'s casts that land InArea from `floor`: { castID, sum, hits }.
local function Gather(run, castID, fp, casts, spent, floor, mates)
    local way = { castID = castID, sum = 0, hits = {} }
    for _, hits in ipairs({ run.unknown, mates and run.mates or {} }) do
        for _, hit in ipairs(hits) do
            local fresh = not spent[hit] and hit.school == fp.school
            local cast = fresh and OtherPlateCast(casts, hit.at, hit.plate, fp.delayHi + Casts.SPLASH)
            if cast and InArea(castID, cast, hit, floor) then
                way.sum = way.sum + hit.amount
                way.hits[#way.hits + 1] = hit
            end
        end
    end

    return way
end

-- `way` with only its hits that share their frame with another of its hits on another plate: an AoE's splash lands on
-- the plates around its target at once. Run paladin2 F2: Hammer of Light 427453's 12 hits under PAD_LO came 4 to a
-- frame, one frame per cast (0.59-0.60 s after it). Run priest4 F2: Devouring Plague 335467 summed 51 such hits
-- (169593, room 336534: 50.4 %), 10 of them alone in their frame; the fight's Psychic Link 199486 row (759021) likely
-- holds them, and the marked plague then drew Shadow hits on other plates in F3-F17 (Vampiric Touch 34914 lost a 5736
-- in F16). Its 41 framed hits (131289) explain too little. A hit in the frame of an own hit of its cast (`own`,
-- OwnStamps) is framed too: its target took the same cast at once. Run mage F5: 44425's 5 held hits (30077, room 55982)
-- were refused as unframed until its own hits counted, and F7 then drew its 5268 splash.
local function Framed(way, own)
    local plates = {}
    for _, hit in ipairs(way.hits) do
        plates[hit.at] = plates[hit.at] or {}
        plates[hit.at][hit.plate] = true
    end
    local framed = { castID = way.castID, sum = 0, hits = {} }
    for _, hit in ipairs(way.hits) do
        local others = own[hit.at] == true
        for plate in pairs(plates[hit.at]) do others = others or plate ~= hit.plate end
        if others then
            framed.sum = framed.sum + hit.amount
            framed.hits[#framed.hits + 1] = hit
        end
    end

    return framed
end

-- The stamps of `castID`'s own hits this fight: drawn under it (run.drawn), or counted by the steady pass (`ways`).
local function OwnStamps(run, castID, ways)
    local stamps = {}
    for _, hit in ipairs(run.drawn or {}) do
        if hit.spellID == castID then stamps[hit.at] = true end
    end
    for _, way in ipairs(ways) do
        if way.castID == castID then
            for _, hit in ipairs(way.hits) do stamps[hit.at] = true end
        end
    end

    return stamps
end

-- Whether every hit of `way` shares its frame with an own hit of its cast (`own`, OwnStamps).
local function Beside(way, own)
    for _, hit in ipairs(way.hits) do
        if not own[hit.at] then return false end
    end

    return #way.hits > 0
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

-- The area pass of one read. `learned` holds the ways this read learned (their hits are spent, their bases skipped),
-- but a base only the steady pass learned (way.steady) is tried too, its way's sum counted as drawn under its row: run
-- paladin F3, Steady learned Hammer of Light 427453's target hits at the read, and its splash (26119 + 27007, one
-- frame on 2 other plates, room 56073) taught areaLow then, so F8 drew its 22023 splash beside its 40397 target hit.
-- Such a base drew nothing yet, so its hits are held as the lower floor's are (Framed, OtherRowSum): run shaman5 F1,
-- the Fire Elemental's 57984 (learned at 0 s) had 3 lone 37K hits on one other plate in its padded band, its pet's
-- other target, and marked area they made Lava Burst 51505's splash crits in F5 ambiguous.
-- Fewer than MIN_HITS hits explain only as one padded-band way whose every hit shares an own hit's frame and that
-- brings the drawn up to the row's total (Judge's lower bound): run warrior F1, 435222's one other-plate hit (1259725)
-- closed its row (room 1316791), so F3 drew its 1307148 splash too. Run hunter F16: Kill Command 17253's one 2610 hit
-- beside its own, in a room of 3949, left the row open; marked area, F18 drew 65865 over its row.
-- A way that does not explain with its frame mates is tried on its '?' hits alone: run paladin2 F2, 4 Physical mates
-- (17385) pushed 408385's 111 hits (519945) past its room of 526678, and its F4-F7 splashes went '?'.
-- Returns the ways it marked area { castID, sum, hits }.
function Area.Learn(run, rows, learned)
    local spent, learnedNow, steady = {}, {}, {}
    for _, way in ipairs(learned) do
        if way.steady then
            steady[way.castID] = (steady[way.castID] or 0) + way.sum
        else
            learnedNow[way.castID] = true
        end
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
        local fp, drawn = Fingerprints.Get(castID), (run.tally[castID] or 0) + (steady[castID] or 0)
        local row = ns.Steady.RowOf(castID, rows)
        if fp and fp.learned and fp.pattern == "single" and fp.delayHi and not fp.area and not learnedNow[castID]
            and drawn > 0 and row then
            local tol = math.max(1, row.total / 100)
            local room = row.total + row.overkill + tol - drawn
            local own = OwnStamps(run, castID, learned)
            local function Explains(way, lone)
                local closes = drawn + way.sum >= row.total - tol
                return (#way.hits >= MIN_HITS or lone and closes and Beside(way, own)) and way.sum <= room
                    and way.sum >= SHARE * room
            end
            -- frame mates may be another spell's of the school: a way they push past the room tries without them
            local function Way(floor)
                local way = Gather(run, castID, fp, castsOf[castID], spent, floor, true)
                if Explains(way, not floor) then return way end
                local bare = Gather(run, castID, fp, castsOf[castID], spent, floor, false)

                return Explains(bare, not floor) and bare or way
            end
            local way = Way(nil)
            local low = not Explains(way, true)
            if low then way = Way(Casts.AREA_LO) end
            local held = low or steady[castID] ~= nil
            local fits = Explains(way, not low)
                and not (held and (not Explains(Framed(way, own), not low) or OtherRowSum(way, row, rows, run.tally)))
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

-- The twin pass of one read: a learned DoT or channel (Learn.lua) whose ticks the tracker drew this fight (run.ticks
-- with a place) may also strike the plates around its target for a fixed share of each tick. Each fresh '?' hit of its
-- school on another plate, at most one learned period after one of its ticks, pairs with the newest such tick; their
-- sizes' ratio (normal scale) is the share it would show. The share most ratios agree with (within Streams.SIZE_GUARD)
-- is taught (Learn.SetTwin) when TWIN_MIN hits or more agree and their sum fits the row's room (total, overkill and
-- Judge's tolerance, less the drawn ticks). Run mage F2: Arcane Missiles 5143 drew 48508 of row 7268's 161687; 59 hits
-- at 0.47-0.53 of the tick before them on other plates summed 64330 (room 113179). Run priest3 F3: Void Torrent
-- 263165's twins came at 0.20 of its ticks, beside other Shadow hits at 0.13 and 0.30-0.36.
-- Returns the ways it taught { castID, sum, hits }.
local TWIN_MIN = 4
function Area.Twins(run, rows, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local ticksOf, order = {}, {}
    for _, tick in ipairs(run.ticks or {}) do
        if tick.spellID and tick.at and tick.plate ~= nil and tick.size and tick.size > 0 then
            if not ticksOf[tick.spellID] then
                ticksOf[tick.spellID] = {}
                order[#order + 1] = tick.spellID
            end
            table.insert(ticksOf[tick.spellID], tick)
        end
    end
    table.sort(order)

    local ways = {}
    for _, spellID in ipairs(order) do
        local dot, row = ns.Learn.Get(spellID), ns.Steady.RowOf(spellID, rows)
        if dot and row then
            local matched = {}
            for _, hit in ipairs(run.unknown) do
                local newest
                if not spent[hit] and hit.school == dot.school and hit.size and hit.size > 0 then
                    for _, tick in ipairs(ticksOf[spellID]) do
                        local gap = hit.at - tick.at
                        if tick.plate ~= hit.plate and gap >= 0 and gap <= dot.period then newest = tick end
                    end
                end
                if newest then matched[#matched + 1] = { hit = hit, ratio = hit.size / newest.size } end
            end
            local best, bestCount = nil, 0
            for _, pair in ipairs(matched) do
                local count = 0
                for _, other in ipairs(matched) do
                    if math.abs(other.ratio - pair.ratio) <= ns.Streams.SIZE_GUARD * pair.ratio then count = count + 1 end
                end
                if count > bestCount then best, bestCount = pair.ratio, count end
            end
            local way = { castID = spellID, sum = 0, hits = {} }
            for _, pair in ipairs(best and matched or {}) do
                if math.abs(pair.ratio - best) <= ns.Streams.SIZE_GUARD * best then
                    way.sum = way.sum + pair.hit.amount
                    way.hits[#way.hits + 1] = pair.hit
                end
            end
            local room = row.total + row.overkill + math.max(1, row.total / 100) - (run.tally[spellID] or 0)
            local fits = #way.hits >= TWIN_MIN and way.sum <= room and ns.Learn.SetTwin(spellID, best)
            if fits then ways[#ways + 1] = way end
            if ns.Debug and #way.hits > 0 then
                ns.Debug("TEACH twin %d hits=%d sum=%d room=%d share=%.2f -> %s", spellID, #way.hits,
                    math.floor(way.sum), math.floor(room), best, fits and "learned" or "refused")
            end
        end
    end

    return ways
end
