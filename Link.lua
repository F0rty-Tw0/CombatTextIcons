-- Combat Text Icons: link pass. A cast may fill a meter row of another ID with its hits on the plates around its
-- target: run druid F8-F10, each Ravage 441591 cast (a row of its own; the game names Ferocious Bite 22568 its base)
-- put like-sized hits on the other plates in its cast's frame or the next (22347 on 4 plates, 51398 crits), and the
-- fights with no Bite cast held exactly those under Bite's row (294980, 389455, 259771). Ravage's own splash on those
-- plates is a third their size.
-- Learning (a clear read, after every other pass, on the '?' hits they left): a cast's own row is its spell's row, else
-- its base's. An open row B that is no cast's own row nor a cast spell of this read, no learned proc, no alias names
-- and nothing drew under; a cast A (its own row's ID), each cast with a plate. A's hits are the '?' hits on another
-- plate than a cast's own, SPLASH or less after that cast. Sorted by size, one window of them (the largest within
-- SPREAD of the smallest) of one school must meet B exactly (its total up to its overkill, ROUND either way), hold a
-- hit of every cast of A, and be the only such window of any A for B, meeting no other open row. Each such read is
-- one fight of evidence for A -> B; LEARN_FIGHTS of them, A and school the same, learn the link. Evidence of another
-- cast or school starts over. One exact read is luck: run druid2 F1 and F9's castless proc 1260076 was a lone holy hit
-- after one cast of 1822, and in F4 of 1243807.
-- Drawing (Link.Name): after a cast of a learned link's A or of its base family (a cast whose game base,
-- Casts.GameBase, is A or A's: druid F11's Bite casts put the same hits around their target as Ravage's), a solo hit
-- nothing else named, of the link's school, on another plate than the cast's, inside the learned delays (SLACK either
-- way) and near the learned sizes (Streams.SIZE_GUARD), draws as B. A clear read that finds B drawn past its row (or
-- B drawn with no row) drops the link. With /cti debug each evidence logs one TEACH link line.

local _, ns = ...
local Streams, Fingerprints, Procs, Casts = ns.Streams, ns.Fingerprints, ns.Procs, ns.Casts

local Link = {}
ns.Link = Link

local SPREAD = 1.5     -- a window's largest hit over its smallest at most (the cand pass's COVER_SPREAD)
local ROUND = 1        -- the meter's rounding: a sum this far off its row still meets it
local LEARN_FIGHTS = 2 -- clear reads of exact evidence that learn a link
local SLACK = 0.05     -- a drawn hit's delay may be this far past the learned delays (Casts' window SLACK)

local issecretvalue = issecretvalue or function() return false end
local function IsNumber(value) return not issecretvalue(value) and type(value) == "number" end
local function Positive(value) return IsNumber(value) and value > 0 end

-- [row B] = { castID, base, school, lo, hi, delayLo, delayHi, fights }, the saved per-spec store once Init ran; base
-- (A's base spell, nil when A is its own) names the casts of A's family
local links = {}
local recent = {} -- [row B] = { { at, plate }, ... } this session's casts that open learned link B, newest last

local function Valid(rowID, entry)
    if not (IsNumber(rowID) and type(entry) == "table") then return false end
    local fights = entry.fights

    return IsNumber(entry.castID) and (entry.base == nil or IsNumber(entry.base)) and Positive(entry.school) and Positive(entry.lo) and Positive(entry.hi)
        and entry.lo <= entry.hi and IsNumber(entry.delayLo) and IsNumber(entry.delayHi)
        and entry.delayLo <= entry.delayHi and Positive(fights) and fights % 1 == 0
end

local function Learned(entry) return entry.fights >= LEARN_FIGHTS end

-- Link.Init(charDB): adopts charDB.links as the live store, dropping bad saved data (a save from before links has none).
function Link.Init(charDB)
    if type(charDB.links) ~= "table" then charDB.links = {} end
    links = charDB.links
    for rowID, entry in pairs(links) do
        if not Valid(rowID, entry) then links[rowID] = nil end
    end
    recent = {}
end

-- The link filed under row `rowID` (learned or still gathering evidence), or nil.
function Link.Get(rowID) return IsNumber(rowID) and links[rowID] or nil end

function Link.Forget()
    for rowID in pairs(links) do links[rowID] = nil end
    recent = {}
end

-- A harmful cast of `spellID` on `plate` (nil: none) at `now`: kept under each learned link it opens (A itself, or a
-- cast of A's base family, Casts.GameBase) while that link's draws may follow it.
function Link.NoteCast(spellID, now, plate)
    if not (IsNumber(spellID) and IsNumber(now) and plate ~= nil) then return end
    local base = Casts.GameBase(spellID)
    for rowID, entry in pairs(links) do
        local family = entry.castID == spellID or entry.castID == base or entry.base ~= nil and entry.base == base
        if Learned(entry) and family then
            local list = recent[rowID] or {}
            recent[rowID] = list
            list[#list + 1] = { at = now, plate = plate }
            while list[1].at < now - Casts.SPLASH - 1 do table.remove(list, 1) end
        end
    end
end

-- Whether normal-scale `size` lies within Streams.SIZE_GUARD of `lo`-`hi` (two hits of a kind).
local function Near(entry, size)
    local guard = 1 - Streams.SIZE_GUARD

    return size >= guard * entry.lo and size * guard <= entry.hi
end

-- Link.Name(plate, school, amount, flagText, now): the row B of the one learned link a hit fits, else nil (see header).
function Link.Name(plate, school, amount, flagText, now)
    local size = Streams.NormalAmount(amount, flagText)
    if not (plate ~= nil and IsNumber(school) and size and IsNumber(now)) then return nil end
    local found
    for rowID, entry in pairs(links) do
        local fits = false
        if Learned(entry) and entry.school == school and Near(entry, size) then
            for _, cast in ipairs(recent[rowID] or {}) do
                local delay = now - cast.at
                fits = fits or cast.plate ~= plate and delay >= entry.delayLo - SLACK and delay <= entry.delayHi + SLACK
            end
        end
        if fits then
            if found then return nil end
            found = rowID
        end
    end

    return found
end

-- Learning ------------------------------------------------------------------------------------------------------------

-- Whether `sum` meets `row` exactly, to the meter's rounding.
local function Meets(sum, row) return sum >= row.total - ROUND and sum <= row.total + (row.overkill or 0) + ROUND end

-- A learned link a clear read finds drawn past its row (or drawn with no row) is dropped.
local function Judge(rows, tally)
    for rowID, entry in pairs(links) do
        local drawn, row = tally[rowID] or 0, nil
        for _, item in ipairs(rows) do
            if item.spellID == rowID then row = item end
        end
        local top = row and row.total + (row.overkill or 0) + math.max(1, row.total / 100)
        if Learned(entry) and drawn > 0 and (not top or drawn > top) then
            links[rowID] = nil
            if ns.Debug then ns.Debug("TEACH link %d cast=%d drawn=%d -> dropped", rowID, entry.castID, drawn) end
        end
    end
end

-- The row a cast fills itself this read: its spell's row, else its base's, else nil.
local function OwnRow(cast, ownRow)
    if ownRow[cast.spellID] then return cast.spellID end

    return ownRow[cast.base] and cast.base or nil
end

-- The casts of each own row this read, every one with a plate: { [own row] = { cast, ... } }.
local function CastsWithRows(casts, ownRow)
    local byRow, plateless = {}, {}
    for _, cast in ipairs(casts or {}) do
        local own = OwnRow(cast, ownRow)
        if own then
            byRow[own] = byRow[own] or {}
            table.insert(byRow[own], cast)
            if cast.plate == nil then plateless[own] = true end
        end
    end
    for own in pairs(plateless) do byRow[own] = nil end

    return byRow
end

-- The windows of `casts`' hits around their target (see header) that meet `row`: { { school, sum, hits, castOf } }.
local function Windows(casts, unknown, row)
    local bySchool, castOf = {}, {}
    for _, hit in ipairs(unknown) do
        local newest
        for _, cast in ipairs(casts) do
            local delay = hit.at - cast.at
            if hit.size and hit.plate ~= cast.plate and delay >= 0 and delay <= Casts.SPLASH
                and (not newest or cast.at > newest.at) then
                newest = cast
            end
        end
        if newest then
            castOf[hit] = newest
            bySchool[hit.school] = bySchool[hit.school] or {}
            table.insert(bySchool[hit.school], hit)
        end
    end
    local found = {}
    for school, hits in pairs(bySchool) do
        table.sort(hits, function(a, b)
            if a.size ~= b.size then return a.size < b.size end

            return a.at < b.at
        end)
        for first = 1, #hits do
            local sum, covered, count = 0, {}, 0
            for last = first, #hits do
                if hits[last].size > SPREAD * hits[first].size then break end
                sum = sum + hits[last].amount
                local cast = castOf[hits[last]]
                if not covered[cast] then covered[cast], count = true, count + 1 end
                if count == #casts and Meets(sum, row) then
                    local way = { school = school, sum = sum, hits = {}, castOf = castOf }
                    for index = first, last do way.hits[#way.hits + 1] = hits[index] end
                    found[#found + 1] = way
                end
            end
        end
    end

    return found
end

-- One read's evidence for row `rowID` from cast `castID`'s `way`: a new or longer streak, widened sizes and delays.
local function Note(rowID, castID, way)
    local entry = links[rowID]
    if not (entry and entry.castID == castID and entry.school == way.school) then
        entry = { castID = castID, school = way.school, fights = 0 }
    end
    local base = Casts.GameBase(castID)
    entry.base = base ~= castID and base or entry.base
    for _, hit in ipairs(way.hits) do
        local delay = hit.at - way.castOf[hit].at
        entry.lo, entry.hi = math.min(entry.lo or hit.size, hit.size), math.max(entry.hi or hit.size, hit.size)
        entry.delayLo, entry.delayHi = math.min(entry.delayLo or delay, delay), math.max(entry.delayHi or delay, delay)
    end
    entry.fights = entry.fights + 1
    links[rowID] = entry

    return entry
end

-- Link.Learn(run, rows, open, rewritten, results, learned): the link pass of one clear read, after the passes whose
-- ways are `learned` (their hits are spent). The row a link learns goes to `results`. Returns the ways learned
-- ({ castID, sum, hits }).
function Link.Learn(run, rows, open, rewritten, results, learned)
    local tally = run.tally or {}
    Judge(rows, tally)
    local spent, unknown, owned, ownRow = {}, {}, {}, {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    for _, hit in ipairs(run.unknown) do
        if not spent[hit] then unknown[#unknown + 1] = hit end
    end
    for _, row in ipairs(rows) do ownRow[row.spellID] = true end
    for _, cast in ipairs(run.casts or {}) do owned[cast.spellID], owned[OwnRow(cast, ownRow) or cast.base] = true, true end
    local byRow = CastsWithRows(run.casts, ownRow)
    local ways = {}
    for position, item in ipairs(open) do
        local row = item.row
        local rowID = row.spellID
        local free = not rewritten[position] and not owned[rowID] and not Procs.Get(rowID)
            and not Fingerprints.Alias(rowID) and not (tally[rowID] and tally[rowID] > 0)
        local castID, way, count = nil, nil, 0
        for own, casts in pairs(free and byRow or {}) do
            for _, found in ipairs(Windows(casts, unknown, row)) do
                castID, way, count = own, found, count + 1
            end
        end
        local metOther = false
        for other, otherItem in ipairs(count == 1 and open or {}) do
            metOther = metOther or other ~= position and Meets(way.sum, otherItem.row)
        end
        if count == 1 and not metOther then
            local entry = Note(rowID, castID, way)
            if Learned(entry) and entry.fights == LEARN_FIGHTS then
                rewritten[position] = true
                results[item.index] = { spellID = rowID, meterID = rowID, tally = way.sum, meter = row.total,
                    verdict = "agree" }
                ways[#ways + 1] = { castID = castID, sum = way.sum, hits = way.hits }
            end
            if ns.Debug then
                ns.Debug("TEACH link %d cast=%d school=%d hits=%d sum=%d size=%.0f-%.0f delay=%.3f-%.3f fights=%d -> %s",
                    rowID, castID, way.school, #way.hits, way.sum, entry.lo, entry.hi, entry.delayLo, entry.delayHi,
                    entry.fights, Learned(entry) and "learned" or "evidence")
            end
        end
    end

    return ways
end
