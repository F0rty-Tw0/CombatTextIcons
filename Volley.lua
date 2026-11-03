-- Combat Text Icons: volley pass. A cast that fires a volley lands a burst of equal bolts on its target after it: one
-- size per cast (crits twice it), a bolt every ~0.1 s for about a second, filed under a meter row of another ID. Run
-- priest3 F4: each of five Void Volley 1242173 casts (base 228260) left 9-17 bolts of 2731-2732 (crits 5462-5465) in
-- the 1.1 s after it, and the fight's 60 such hits summed to row 1242189 (185773) exactly; the steady pass counts one
-- hit per cast and a like-sized co-hit spoils the cast, so it learned nothing, and the proc pass's 15 % size walk
-- joined the bolts with other Shadow hits.
-- Learning (a clear read): per cast spell with no row of its own, cast MIN_CASTS times or more, each cast's window runs
-- SPAN seconds to its next cast; a '?' hit is a bolt when a hit of its school and size (TWIN, crits by their
-- normal-scale size) lands within GAP of it on another stamp of the window. A cast volleys when one size holds
-- VOLLEY_MIN bolts or more; SHARE of the casts must volley, in one school. The bolts' sum must fit exactly one open row
-- no one owns (total + overkill + 1 %) and explain COVER of it: the volley learns that row and its size band.
-- Drawing (Volley.Name): after a learned volley's cast, a solo hit nothing else named, inside the padded band, whose
-- size a hit of its school GAP or less before it repeats (another stamp), is a bolt: the volley's first bolt stays '?'.
-- A clear read that finds the row drawn past it (or gone) drops the volley. With /cti debug each tried cast spell
-- logs one TEACH volley line.

local _, ns = ...
local Streams, Fingerprints, Procs = ns.Streams, ns.Fingerprints, ns.Procs

local Volley = {}
ns.Volley = Volley

local SPAN = 3         -- seconds a cast's window runs at most (its next cast ends it sooner)
local GAP = 0.4        -- seconds between two bolts of one size at most: past a bolt's ~0.1-0.35 s, under a DoT's tick
local TWIN = 0.002     -- two bolts are one size when they differ by at most this share (Procs' TWIN)
local VOLLEY_MIN = 3   -- bolts a cast needs to volley
local MIN_CASTS = 3    -- casts a spell needs in the read
local SHARE = 0.6      -- of a spell's casts that must volley
local COVER = 0.5      -- of the row the bolts must explain
local PAD_LO, PAD_HI = 0.85, 1.15 -- draw pads of the learned band (Procs' pads)

local issecretvalue = issecretvalue or function() return false end
local function IsNumber(value) return not issecretvalue(value) and type(value) == "number" end

local volleys = {} -- [cast spellID] = { row, school, lo, hi }, the saved per-spec store once Init ran
local live = {}    -- [cast spellID] = { at = last cast, recent = { { at, size, school } } }, this session's clock

local function Valid(id, entry)
    if not (IsNumber(id) and type(entry) == "table") then return false end
    local row, school, lo, hi = entry.row, entry.school, entry.lo, entry.hi

    return IsNumber(row) and IsNumber(school) and school > 0 and IsNumber(lo) and IsNumber(hi) and lo > 0 and lo <= hi
end

-- Volley.Init(charDB): adopts charDB.volleys as the live store, dropping bad saved data.
function Volley.Init(charDB)
    if type(charDB.volleys) ~= "table" then charDB.volleys = {} end
    volleys = charDB.volleys
    for id, entry in pairs(volleys) do
        if not Valid(id, entry) then volleys[id] = nil end
    end
    live = {}
end

function Volley.Get(castID) return IsNumber(castID) and volleys[castID] or nil end

function Volley.Forget()
    for id in pairs(volleys) do volleys[id] = nil end
    live = {}
end

-- A cast of the player or the pet: a learned volley's window opens (bolts of the cast before keep their partners).
function Volley.NoteCast(spellID, now)
    if not (IsNumber(spellID) and volleys[spellID] and IsNumber(now)) then return end
    local state = live[spellID] or { recent = {} }
    state.at, live[spellID] = now, state
end

local function SameSize(a, b) return math.abs(a - b) <= TWIN * math.max(a, b) end

-- Volley.Name(school, amount, flagText, now): the meter row of the one learned volley whose window holds the hit and
-- whose band holds its normal-scale size, when a hit of its school and size landed GAP or less before it on another
-- stamp; nil otherwise. Every hit offered joins the windows it fits, as the next bolt's partner.
function Volley.Name(school, amount, flagText, now)
    local size = Streams.NormalAmount(amount, flagText)
    if not (IsNumber(school) and size and IsNumber(now)) then return nil end
    local found, several
    for castID, state in pairs(live) do
        local entry = volleys[castID]
        local open = entry and now - state.at <= SPAN and entry.school == school
            and size >= entry.lo * PAD_LO and size <= entry.hi * PAD_HI
        if open then
            local kept, paired = {}, false
            for _, bolt in ipairs(state.recent) do
                if now - bolt.at <= GAP then
                    kept[#kept + 1] = bolt
                    paired = paired or (bolt.at ~= now and SameSize(bolt.size, size))
                end
            end
            kept[#kept + 1] = { at = now, size = size }
            state.recent = kept
            if paired then
                several = found ~= nil
                found = found or entry.row
            end
        elseif not entry then
            live[castID] = nil
        end
    end

    return not several and found or nil
end

-- Learning ------------------------------------------------------------------------------------------------------------

-- The casts of each cast spell this read, by spellID, in time order.
local function CastsBySpell(casts)
    local bySpell, order = {}, {}
    for _, cast in ipairs(casts or {}) do
        if not bySpell[cast.spellID] then bySpell[cast.spellID], order[#order + 1] = {}, cast.spellID end
        table.insert(bySpell[cast.spellID], cast)
    end
    for _, list in pairs(bySpell) do table.sort(list, function(a, b) return a.at < b.at end) end

    return bySpell, order
end

-- The bolts of one window: hits with a like hit (school, SameSize) within GAP on another stamp, grouped by size.
-- Returns the size group with the most bolts ({ school, size, hits }), or nil.
local function WindowVolley(hits)
    local bolts = {}
    for _, hit in ipairs(hits) do
        for _, partner in ipairs(hits) do
            if partner.school == hit.school and partner.at ~= hit.at and math.abs(partner.at - hit.at) <= GAP
                and SameSize(partner.size, hit.size) then
                bolts[#bolts + 1] = hit
                break
            end
        end
    end
    local best
    for _, bolt in ipairs(bolts) do
        local group = { school = bolt.school, size = bolt.size, hits = {} }
        for _, other in ipairs(bolts) do
            if other.school == bolt.school and SameSize(other.size, bolt.size) then group.hits[#group.hits + 1] = other end
        end
        if not best or #group.hits > #best.hits then best = group end
    end

    return best
end

-- One spell's volley over its casts: { school, lo, hi, sum, hits, volleyed, casts }, or nil when fewer than SHARE of
-- the casts (and MIN_CASTS) volley in one school.
local function SpellVolley(casts, unknown)
    local volley = { sum = 0, hits = {}, volleyed = 0, casts = #casts }
    for index, cast in ipairs(casts) do
        local stop = math.min(cast.at + SPAN, casts[index + 1] and casts[index + 1].at or math.huge)
        local window = {}
        for _, hit in ipairs(unknown) do
            if hit.at > cast.at and hit.at <= stop and hit.size then window[#window + 1] = hit end
        end
        local group = WindowVolley(window)
        if group and #group.hits >= VOLLEY_MIN then
            if volley.school and volley.school ~= group.school then return nil end
            volley.school, volley.volleyed = group.school, volley.volleyed + 1
            for _, hit in ipairs(group.hits) do
                volley.sum, volley.hits[#volley.hits + 1] = volley.sum + hit.amount, hit
                if hit.crit ~= true then
                    volley.lo, volley.hi = math.min(volley.lo or hit.size, hit.size), math.max(volley.hi or hit.size, hit.size)
                end
            end
        end
    end
    if volley.volleyed < math.max(MIN_CASTS, math.ceil(SHARE * #casts)) or not volley.lo then return nil end

    return volley
end

-- The positions in `open` (not rewritten) of the rows the volley's sum fits: total + overkill + 1 %, and COVER of
-- the total, a row no cast of this read owns, no proc tracks, nothing drew under, nor an alias names.
local function Rows(volley, open, rewritten, owned, tally)
    local found = {}
    for position, item in ipairs(open) do
        local row = item.row
        local id = row.spellID
        local free = not rewritten[position] and not owned[id] and not Procs.Has(id) and not (tally[id] and tally[id] > 0)
            and not Fingerprints.Alias(id)
        local top = row.total + (row.overkill or 0) + math.max(1, row.total / 100)
        if free and volley.sum <= top and volley.sum >= COVER * row.total then found[#found + 1] = position end
    end

    return found
end

-- A learned volley a clear read finds drawn past its row (or drawn with no row) is dropped.
local function Judge(rows, tally)
    for castID, entry in pairs(volleys) do
        local drawn, row = tally[entry.row] or 0, nil
        for _, item in ipairs(rows) do
            if item.spellID == entry.row then row = item end
        end
        local top = row and row.total + (row.overkill or 0) + math.max(1, row.total / 100)
        if drawn > 0 and (not top or drawn > top) then
            volleys[castID], live[castID] = nil, nil
            if ns.Debug then ns.Debug("TEACH volley %d row=%d drawn=%d -> dropped", castID, entry.row, drawn) end
        end
    end
end

-- A learned volley's undrawn bolts that fit what its row has left (total + overkill + 1 %, less the drawn) widen its
-- band: the bolts' size follows the player's buffs from fight to fight (Void Volley 2552-3311 over runs priest3, priest4).
local function Widen(entry, volley, rows, tally)
    for _, row in ipairs(rows) do
        local top = row.total + (row.overkill or 0) + math.max(1, row.total / 100)
        if row.spellID == entry.row and volley.school == entry.school and volley.sum <= top - (tally[entry.row] or 0) then
            entry.lo, entry.hi = math.min(entry.lo, volley.lo), math.max(entry.hi, volley.hi)
            if ns.Debug then ns.Debug("TEACH volley %d size=%.0f-%.0f -> widen", entry.row, entry.lo, entry.hi) end
        end
    end
end

-- Volley.Learn(run, rows, open, rewritten, results, learned): the volley pass of one clear read, after the passes
-- whose ways are `learned` (their hits are spent). A learned row's verdict goes to `results`. Returns the ways learned
-- ({ castID, sum, hits }).
function Volley.Learn(run, rows, open, rewritten, results, learned)
    local tally = run.tally or {}
    Judge(rows, tally)
    local spent, unknown, owned, ownRow = {}, {}, {}, {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    for _, hit in ipairs(run.unknown) do
        if not spent[hit] then unknown[#unknown + 1] = hit end
    end
    for _, cast in ipairs(run.casts or {}) do owned[cast.spellID], owned[cast.base] = true, true end
    for _, row in ipairs(rows) do ownRow[row.spellID] = true end
    local bySpell, order = CastsBySpell(run.casts)
    local ways = {}
    for _, spellID in ipairs(order) do
        local casts = bySpell[spellID]
        local base = casts[1].base
        local skip = #casts < MIN_CASTS or ownRow[spellID] or ownRow[base]
            or Fingerprints.IsLearned(spellID) or Fingerprints.IsLearned(base)
        local volley = not skip and SpellVolley(casts, unknown)
        if volley and volleys[spellID] then
            Widen(volleys[spellID], volley, rows, tally)
        elseif volley then
            local positions = Rows(volley, open, rewritten, owned, tally)
            local item = #positions == 1 and open[positions[1]]
            if item then
                volleys[spellID] = { row = item.row.spellID, school = volley.school, lo = volley.lo, hi = volley.hi }
                rewritten[positions[1]] = true
                results[item.index] = { spellID = item.row.spellID, meterID = item.row.spellID, tally = volley.sum,
                    meter = item.row.total, verdict = "under" }
                ways[#ways + 1] = { castID = spellID, sum = volley.sum, hits = volley.hits }
            end
            if ns.Debug then
                ns.Debug("TEACH volley %d casts=%d/%d size=%.0f-%.0f sum=%.0f -> %s", spellID, volley.volleyed,
                    volley.casts, volley.lo, volley.hi, volley.sum, item and item.row.spellID or "rows=" .. #positions)
            end
        end
    end

    return ways
end
