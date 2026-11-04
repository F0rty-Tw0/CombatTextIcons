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
-- and their sum must not be the row of a spell the fight cast with nothing drawn under it (OtherRowSum). A base
-- marked so is areaLow (Fingerprints.SetArea).
-- Run shaman6 F2: Lava Burst 51505 (learned, window 0.12-0.28 s) drew 570245 of its 1183551 row; 9 Fire hits on 4
-- other plates in that span summed 613306 against a residual of 625142. Hunter F3's Kill Command 17253 drew 22960 of
-- 29658, and Beast Cleave's 84 hits on 4 plates (151786) are far past its residual: no area.
-- Learned hits leave the '?' that Procs.Read then sees. With /cti debug each tried base logs one TEACH area line.
-- The twin pass (Area.Twins) does the same for a learned DoT or channel's ticks: their fixed share on other plates.
-- The echo pass (Area.Echoes) does it for a learned cast's later hits on its own plate at a fixed share of its own hit.

local _, ns = ...
local Fingerprints, Casts = ns.Fingerprints, ns.Casts

local Area = {}
ns.Area = Area

local SHARE = 0.5       -- of the residual the other plates' hits must explain at least
local MIN_HITS = 2      -- other-plate hits at least
local AREA_SLACK = 0.05 -- a hit may land this far below the learned window (Casts' SLACK)
local SIZED = 0.05      -- one cast's splash hits on the plates around agree in size within this share (Sized)
local SIZED_SHARE = 0.15 -- of the residual a held way's sized hits must explain at least

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
-- `castID`'s casts that land InArea from `floor`, with the cast's splash hits drawn before its area was marked
-- (Teacher.Spread: they would have been '?'): { castID, sum, hits, castOf = { [hit] = its cast } }.
local function Gather(run, castID, fp, casts, spent, floor, mates)
    local way = { castID = castID, sum = 0, hits = {}, castOf = {} }
    local spreads = run.spreads or {}
    for _, hits in ipairs({ run.unknown, mates and run.mates or {}, spreads }) do
        for _, hit in ipairs(hits) do
            local own = hits ~= spreads or hit.castID == castID
            local fresh = own and not spent[hit] and hit.school == fp.school
            local cast = fresh and OtherPlateCast(casts, hit.at, hit.plate, fp.delayHi + Casts.SPLASH)
            if cast and InArea(castID, cast, hit, floor) then
                way.sum = way.sum + hit.amount
                way.hits[#way.hits + 1] = hit
                way.castOf[hit] = cast
            end
        end
    end

    return way
end

-- Whether `hits` (one cast's in a way) are a travelling splash: one hit on each of two or more plates, all of one
-- size within SIZED (normal scale), over more than one frame (a same-frame group is Framed's).
local function Travelled(hits)
    local plates, first, last, low, high = {}, math.huge, -math.huge, math.huge, 0
    for _, hit in ipairs(hits) do
        if plates[hit.plate] then return false end
        plates[hit.plate] = true
        first, last = math.min(first, hit.at), math.max(last, hit.at)
        local size = hit.size or hit.amount
        low, high = math.min(low, size), math.max(high, size)
    end

    return #hits >= 2 and last > first and high <= (1 + SIZED) * low
end

-- `way` with only the hits of its casts whose hits are a travelling splash (Travelled), when MIN_HITS casts or more
-- are, else an empty way: a projectile's splash strikes each plate around once for one size, a frame or more apart
-- per plate. Run hunter F1: Black Arrow 466930 (learned at 11220-13464) put one 5815-5917 hit on each of 4 other
-- plates over 0.24 s after a cast, 4820-4973 after the next; 11 of its 21 low-floor hits shared a frame (76623 in a
-- room of 481697). Run priest4 F2: Devouring Plague 335467's like-sized Shadow hits on 4 plates came in one frame
-- (likely Psychic Link's, see Framed) or several to a plate: no travel. Run mage F2: Arcane Blast 30451's one
-- like-sized pair (4688) is one cast, too few; marked area it drew other Arcane hits wrong.
local function Sized(way)
    local byCast, order = {}, {}
    for _, hit in ipairs(way.hits) do
        local cast = way.castOf[hit]
        if not byCast[cast] then
            byCast[cast] = {}
            order[#order + 1] = cast
        end
        table.insert(byCast[cast], hit)
    end
    local sized, casts = { castID = way.castID, sum = 0, hits = {} }, 0
    for _, cast in ipairs(order) do
        if Travelled(byCast[cast]) then
            casts = casts + 1
            for _, hit in ipairs(byCast[cast]) do
                sized.sum = sized.sum + hit.amount
                sized.hits[#sized.hits + 1] = hit
            end
        end
    end
    if casts < MIN_HITS then return { castID = way.castID, sum = 0, hits = {} } end

    return sized
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

-- The stamps of `castID`'s own hits this fight: drawn under it (run.drawn) but not as its splash (run.spreads), or
-- counted by the steady pass (`ways`).
local function OwnStamps(run, castID, ways)
    local stamps, spread = {}, {} -- spread[stamp .. ":" .. amount] = splash hits drawn so, not yet matched
    for _, hit in ipairs(run.spreads or {}) do
        local key = hit.at .. ":" .. hit.amount
        if hit.castID == castID then spread[key] = (spread[key] or 0) + 1 end
    end
    for _, hit in ipairs(run.drawn or {}) do
        local key = hit.at .. ":" .. hit.amount
        if hit.spellID == castID and (spread[key] or 0) > 0 then
            spread[key] = spread[key] - 1
        elseif hit.spellID == castID then
            stamps[hit.at] = true
        end
    end
    for _, way in ipairs(ways) do
        if way.castID == castID then
            for _, hit in ipairs(way.hits) do stamps[hit.at] = true end
        end
    end

    return stamps
end

-- `way` with only its hits in the frame of an own hit of its cast (`own`, OwnStamps), when such hits share at least
-- SHARE of its own frames (an AoE strikes the plates around at each cast), else an empty way.
local function OwnFramed(way, own)
    local beside, frames, shared = { castID = way.castID, sum = 0, hits = {} }, 0, {}
    for _ in pairs(own) do frames = frames + 1 end
    for _, hit in ipairs(way.hits) do
        if own[hit.at] then
            beside.sum = beside.sum + hit.amount
            beside.hits[#beside.hits + 1] = hit
            shared[hit.at] = true
        end
    end
    local count = 0
    for _ in pairs(shared) do count = count + 1 end
    if count < math.max(MIN_HITS, SHARE * frames) then return { castID = way.castID, sum = 0, hits = {} } end

    return beside
end

-- Whether every hit of `way` shares its frame with an own hit of its cast (`own`, OwnStamps).
local function Beside(way, own)
    for _, hit in ipairs(way.hits) do
        if not own[hit.at] then return false end
    end

    return #way.hits > 0
end

-- Whether `way`'s hits sum to a row of another ID than `own` with nothing drawn under it (Teacher's Judge: within 1 %
-- of its total, overkill above it) whose spell this fight cast, by its ID, its base or the spell it overrides
-- (`named`): that row's hits, which Procs.Read then learns. Run druid F10: the lower floor gathered Ravage 441591's
-- 8 hits on other plates in its casts' frames (17596-51399, 0.54-0.79 of its smallest), 259771 in a room of 401762;
-- the meter files them under Ferocious Bite 22568, the spell Ravage overrides, 259771 exactly, and without them
-- Ferocious Bite's splashes in F11-F12 stayed '?'. A row of a spell no cast of the fight names is no such owner: in a fight that drew
-- nothing yet every row has nothing under it, and one may sit within 1 % of the sum by chance. Run dk F2: Epidemic
-- 207317's 75 splash hits on the dummies around (48103, room 87215) met row 1300330's 48052, a row also dealt in F1
-- with no Epidemic cast; refused, F3's splash went '?'.
local function OtherRowSum(way, own, rows, tally, named)
    for _, row in ipairs(rows) do
        local tol = math.max(1, row.total / 100)
        if row.spellID ~= own.spellID and named[row.spellID] and not tally[row.spellID] and way.sum >= row.total - tol
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
-- (17385) pushed 408385's 111 hits (519945) past its room of 526678, and its F4-F7 splashes went '?'. One that still
-- does not is tried on the hits in its own hits' frames alone (OwnFramed), and a base they mark is areaFrame: run
-- druid2 F3, Swipe 106785's span held 108 hits (1136262) in a room of 641187, other bleeds' and strikes' among them,
-- and its F5 splash (210K) went '?'.
-- A held way refused so still marks area by its '?' hits of travelling-splash casts (Sized) when they fit the room
-- and explain SIZED_SHARE of it, and are no other row's sum: one size per plate per cast is the cast's own share, so
-- less of a row swollen by its DoT's ticks on the same plates is enough. Run hunter F1: Black Arrow 466930's 16 such
-- hits (90738) in a room of 481697; F2-F18 then drew its splash, the row 8.0 -> 10.5 % of the log's meter.
-- A cast's splash Core drew as it before its area was marked (run.spreads, Casts.Spreads) counts as its '?' hits, not
-- as drawn: run paladin2 F2, Hammer of Light 427453's 12 splash hits (370897) drawn so still marked it areaLow, and
-- F3's lone splash on one plate drew.
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
    local castsOf, order, named, spread = {}, {}, {}, {}
    for _, hit in ipairs(run.spreads or {}) do spread[hit.castID] = (spread[hit.castID] or 0) + hit.amount end
    for _, item in ipairs(run.casts or {}) do
        named[item.spellID], named[item.base], named[Casts.Overridden(item.spellID)] = true, true, true
    end
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
        local fp = Fingerprints.Get(castID)
        local drawn = (run.tally[castID] or 0) + (steady[castID] or 0) - (spread[castID] or 0)
        local row = ns.Steady.RowOf(castID, rows)
        if fp and fp.learned and fp.pattern == "single" and fp.delayHi and not fp.area and not learnedNow[castID]
            and drawn > 0 and row then
            local tol = math.max(1, row.total / 100)
            local room = row.total + row.overkill + tol - drawn
            local own = OwnStamps(run, castID, learned)
            local function Explains(way, lone, share)
                local closes = drawn + way.sum >= row.total - tol
                return (#way.hits >= MIN_HITS or lone and closes and Beside(way, own)) and way.sum <= room
                    and way.sum >= (share or SHARE) * room
            end
            -- frame mates may be another spell's of the school: a way they push past the room tries without them
            local function Way(floor)
                local way = Gather(run, castID, fp, castsOf[castID], spent, floor, true)
                if Explains(way, not floor) then return way end
                local bare = Gather(run, castID, fp, castsOf[castID], spent, floor, false)
                if Explains(bare, not floor) then return bare end
                local beside = OwnFramed(way, own)
                beside.framed = true

                return Explains(beside, not floor) and beside or way
            end
            local way = Way(nil)
            local low = not Explains(way, true)
            if low then way = Way(Casts.AREA_LO) end
            local held = low or steady[castID] ~= nil
            local fits = Explains(way, not low) and not (held
                and (not Explains(Framed(way, own), not low) or OtherRowSum(way, row, rows, run.tally, named)))
            if not fits and held then
                local sized = Sized(Gather(run, castID, fp, castsOf[castID], spent, low and Casts.AREA_LO or nil, false))
                if Explains(sized, false, SIZED_SHARE) and not OtherRowSum(sized, row, rows, run.tally, named) then
                    way, fits = sized, true
                end
            end
            if fits then
                Fingerprints.SetArea(castID, low, way.framed)
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
-- sizes' ratio (normal scale), or their amounts' as they landed, is the share it would show: run priest3 F8, Void
-- Torrent's 14398 crit tick put 2879 hits, 0.20 of it as landed, where its normal ticks put 0.20 of theirs (run mage:
-- Arcane Missiles' twins kept 0.5 of a crit tick's normal size). Of the shares whose agreeing hits (within
-- Streams.SIZE_GUARD) sum to at most the row's room (total, overkill and Judge's tolerance, less the drawn ticks), the
-- one most pairs agree with is taught (Learn.SetTwin) when TWIN_MIN hits or more agree. Run mage F2: Arcane Missiles 5143
-- drew 48508 of row 7268's 161687; 59 hits at 0.47-0.53 of the tick before them on other plates summed 64330 (room
-- 113179). Run priest3 F3: Void Torrent 263165's twins came at 0.20 of its ticks, beside other Shadow hits at 0.13 and
-- 0.30-0.36; run priest4 F12: six Shadow hits at 0.24-0.39 of its ticks outnumbered its five twins and passed the room.
-- A share taught before stays while TWIN_MIN of its hits fit the room: run priest3 F8, 14 Shadow hits at 0.27 of Void
-- Torrent's ticks outnumbered its twins at 0.19 and taught 0.27 in their place.
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
        -- a ramping DoT's ticks on other plates are their own ramps, at no fixed share of its own (run lock4 F5: Agony
        -- 980 taught 0.83 and drew Drain Life 234153's 1281s in F7 as its twins, then went over its row and dropped).
        -- A flat DoT (Learn.Flat) learns no twins either: run priest3's Devouring Plague 335467 took twins and the
        -- heals named on that log fell 4.2 -> 3.8 % (its heal is 0.3 x a hit, taught by the hits nothing drew).
        if dot and row and not ns.Learn.Ramp(spellID) and not ns.Learn.Flat(spellID) then
            local matched = {}
            for _, hit in ipairs(run.unknown) do
                local newest
                if not spent[hit] and hit.school == dot.school and hit.size and hit.size > 0 then
                    for _, tick in ipairs(ticksOf[spellID]) do
                        local gap = hit.at - tick.at
                        if tick.plate ~= hit.plate and gap >= 0 and gap <= dot.period then newest = tick end
                    end
                end
                if newest then
                    local landed = (newest.amount or 0) > 0 and hit.amount / newest.amount or nil
                    matched[#matched + 1] = { hit = hit, ratios = { hit.size / newest.size, landed } }
                end
            end
            local function Agrees(pair, share)
                for _, ratio in ipairs(pair.ratios) do
                    if math.abs(ratio - share) <= ns.Streams.SIZE_GUARD * share then return true end
                end
                return false
            end
            local room = row.total + row.overkill + math.max(1, row.total / 100) - (run.tally[spellID] or 0)
            local function Way(share)
                local way = { castID = spellID, sum = 0, hits = {} }
                for _, pair in ipairs(matched) do
                    if Agrees(pair, share) then
                        way.sum = way.sum + pair.hit.amount
                        way.hits[#way.hits + 1] = pair.hit
                    end
                end
                return way
            end
            -- the share taught before while TWIN_MIN of its hits fit the room; else the share most pairs agree with
            -- among those whose sum fits the room; else the most agreed one (refused)
            local way, best
            local taught = ns.Learn.Twin(spellID)
            local kept = taught and Way(taught)
            if kept and #kept.hits >= TWIN_MIN and kept.sum <= room then way, best = kept, taught end
            for _, pair in ipairs(not way and matched or {}) do
                for _, ratio in ipairs(pair.ratios) do
                    local candidate = Way(ratio)
                    local fitsRoom = candidate.sum <= room
                    local better = not way or (fitsRoom and way.sum > room)
                        or (fitsRoom == (way.sum <= room) and #candidate.hits > #way.hits)
                    if better then way, best = candidate, ratio end
                end
            end
            way = way or { castID = spellID, sum = 0, hits = {} }
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

-- The echo pass of one read: a learned single cast's own hit (run.owns, Teacher.Own) may be followed on its plate by
-- hits at a fixed share of it. Each fresh '?' hit of its school on that plate, at most Casts.ECHO_SPAN after the
-- newest own hit of the cast there and outside the cast's padded band (the band's hits are its records'), pairs with
-- that hit; their sizes' ratio (normal scale) is the share it would show. The share most pairs agree with (within
-- Casts.ECHO_GUARD) among those whose hits fit the row's room (total, overkill and Judge's tolerance, less the drawn)
-- shows when ECHO_SERIES of them or more follow one own hit (a run: an echo repeats like-sized). Two runs in the fight
-- teach it (Fingerprints.SetEcho); one run notes it (NoteEcho), and teaches it when the share a run of an earlier
-- fight noted agrees: a share that like-sized hits met by chance does not come back. Run hunter F10: Black Arrow
-- 466930's 27180 crit was followed by 8153 (a crit), 4075, 4075, 4075 (0.300 of its 13590 normal) 0.12-0.74 s later,
-- 20378 in a room of 32896, noted; F12's two runs taught it, and F14 and F18 drew theirs. A share of 1 or more is no
-- echo: run hunter F18, Kill Command 34026's own hits were followed by 1264485's 11355s (2.0 of them). Kill Command
-- 17253's own hits were followed by Physical hits at 0.22 of them one or two at a time, no run. Run druid F8: Swipe
-- 106785's 8793 was followed by 4011, 4046 and 4002 (0.455-0.460 of it), like-sized only within 1.1 %: within 1 % of
-- one share they taught it, and it drew 4 such hits over its row in F9-F12; inside ECHO_GUARD they make no run.
-- Returns the ways it taught { castID, sum, hits }.
local ECHO_SERIES = 3
function Area.Echoes(run, rows, learned)
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    local ownsOf, order = {}, {}
    for _, own in ipairs(run.owns or {}) do
        if not ownsOf[own.base] then
            ownsOf[own.base] = {}
            order[#order + 1] = own.base
        end
        table.insert(ownsOf[own.base], own)
    end
    table.sort(order)

    local ways = {}
    for _, castID in ipairs(order) do
        local fp, row = Fingerprints.Get(castID), ns.Steady.RowOf(castID, rows)
        if fp and fp.learned and fp.pattern == "single" and row then
            local matched = {}
            for _, hit in ipairs(run.unknown) do
                local newest
                if not spent[hit] and hit.school == fp.school and hit.size and hit.size > 0 then
                    for _, own in ipairs(ownsOf[castID]) do
                        local gap = hit.at - own.at
                        if own.plate == hit.plate and gap > 0 and gap <= Casts.ECHO_SPAN then newest = own end
                    end
                end
                if newest and hit.size < newest.size and not Casts.InBand(castID, newest.spellID, hit.size) then
                    matched[#matched + 1] = { hit = hit, own = newest, ratio = hit.size / newest.size }
                end
            end
            local room = row.total + row.overkill + math.max(1, row.total / 100) - (run.tally[castID] or 0)
            local function Way(share)
                local way, per = { castID = castID, sum = 0, hits = {}, series = 0, runs = 0 }, {}
                for _, pair in ipairs(matched) do
                    if math.abs(pair.ratio - share) <= Casts.ECHO_GUARD * share then
                        way.sum = way.sum + pair.hit.amount
                        way.hits[#way.hits + 1] = pair.hit
                        per[pair.own] = (per[pair.own] or 0) + 1
                        way.series = math.max(way.series, per[pair.own])
                        if per[pair.own] == ECHO_SERIES then way.runs = way.runs + 1 end
                    end
                end
                return way
            end
            -- the share most pairs agree with among those whose sum fits the room; else the most agreed one (refused)
            local way, best
            for _, pair in ipairs(matched) do
                local candidate = Way(pair.ratio)
                local fitsRoom = candidate.sum <= room
                local better = not way or (fitsRoom and way.sum > room)
                    or (fitsRoom == (way.sum <= room) and #candidate.hits > #way.hits)
                if better then way, best = candidate, pair.ratio end
            end
            -- a series that fits the room is noted; two this fight, or one at the share an earlier fight noted, teach
            local shown = way ~= nil and way.runs >= 1 and way.sum <= room
            local seen = shown and Fingerprints.EchoSeen(castID)
            local again = seen and math.abs(seen - best) <= Casts.ECHO_GUARD * best
            local fits = shown and (way.runs >= 2 or again) and Fingerprints.SetEcho(castID, best, way.series)
            if shown and not fits then Fingerprints.NoteEcho(castID, best) end
            if fits then ways[#ways + 1] = way end
            if ns.Debug and way then
                ns.Debug("TEACH echo %d hits=%d series=%d runs=%d sum=%d room=%d share=%.4f -> %s", castID, #way.hits,
                    way.series, way.runs, math.floor(way.sum), math.floor(room), best,
                    fits and "learned" or shown and "noted" or "refused")
            end
        end
    end

    return ways
end
