-- Combat Text Icons: casts. This module holds the cast log (the harmful casts that
-- can explain a hit) and the open records: a cast whose fingerprint is learned waits
-- for its hit, and Claim and Accept turn that hit into a direct-hit icon.
-- An override cast (Void Blast 450983 over Mind Blast 8092) is filed by the meter under
-- its base spell's row, so every entry and record keeps both: `spellID` (the cast, for
-- the icon) and `base` (Casts.Base, for fingerprints and the teacher).

local ADDON, ns = ...
local Learn, Tracker, Fingerprints = ns.Learn, ns.Tracker, ns.Fingerprints

local Casts = {}
ns.Casts = Casts

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

-- The spell `castID` overrides, else `castID` itself: C_SpellBook.FindBaseSpellByID (retail
-- 12.0.0+, Forever 1.60.1), else the deprecated global. A missing API, an error or a nil,
-- secret or non-number answer leaves the cast its own base.
function Casts.Base(castID)
    local find = (C_SpellBook and C_SpellBook.FindBaseSpellByID) or FindBaseSpellByID
    if not find then return castID end
    local ok, base = pcall(find, castID)
    if ok and IsNumber(base) then return base end

    return castID
end

-- A learned chain fingerprint (Chain Lightning): its later hits land on new plates.
local CHAIN_GAP = 0.15   -- each later hit lands this long after the previous one at most
local CHAIN_MAX = 5      -- hits one chain shows at most

local UNKNOWN_WAIT = 1.5 -- a hit is explained by a cast at most this long before it
local LOG_MAX = 20       -- cast log entries kept at most
local log = {}           -- harmful player casts, oldest first: { spellID, base, at, plate, tracker }

-- Open records: a learned cast waiting for its hit. A hit that fits one is drawn with the
-- cast's icon; Claim only reads, Accept is the only writer.
local SLACK = 0.05      -- a window edge may be this far off
local RECORD_MAX = 20   -- open records at most; the oldest is dropped
local records = {}      -- oldest first: { spellID, base, at, plate, hops, plates, last }

-- The fingerprint (its base's) a record still waits on, or nil when the record is dead: its
-- fingerprint is gone or unlearned, or `now` is past its window (a chain record
-- that took a hop lives CHAIN_GAP past its last hop, if that is later).
local function Live(record, now)
    local fp = Fingerprints.Get(record.base)
    if not (fp and fp.learned) then return nil end
    local _, high = Fingerprints.Window(record.base, record.spellID)
    local limit = record.at + high + SLACK
    if fp.pattern == "chain" and record.hops >= 1 then limit = math.max(limit, record.last + CHAIN_GAP) end
    if now <= limit then return fp end
end

local function SweepRecords(now)
    for index = #records, 1, -1 do
        if not Live(records[index], now) then table.remove(records, index) end
    end
end

-- Fight over: drop the records whose window has passed.
function Casts.Flush(now)
    SweepRecords(now)
end

function Casts.NoteCast(castID, now)
    SweepRecords(now)
    local base = Casts.Base(castID)
    local entry = { spellID = castID, base = base, at = now, plate = Tracker.TargetPlate(),
        tracker = Learn.IsKnownIcon(castID) }
    log[#log + 1] = entry
    while now - log[1].at > UNKNOWN_WAIT or #log > LOG_MAX do table.remove(log, 1) end

    if entry.plate and Fingerprints.IsLearned(base) then
        records[#records + 1] = { spellID = castID, base = base, at = now, plate = entry.plate, hops = 0, plates = {},
            last = now }
        if #records > RECORD_MAX then table.remove(records, 1) end
    end
end

-- Does `record` still wait for a hit of `school` on `plate` at `now`? Its first hit
-- lands on the cast's plate inside the learned delay window; a chain's later hits
-- land on new plates, each within CHAIN_GAP of the one before and CHAIN_MAX in all.
local function Fits(record, fp, plate, school, now)
    if school ~= fp.school then return false end
    if record.hops == 0 then
        local age = now - record.at
        local low, high = Fingerprints.Window(record.base, record.spellID)
        return plate == record.plate and age >= low - SLACK and age <= high + SLACK
    end
    return fp.pattern == "chain" and not record.plates[plate] and now - record.last <= CHAIN_GAP
        and record.hops < CHAIN_MAX
end

-- A harmful non-tracker cast on `plate` within UNKNOWN_WAIT that no fingerprint knows
-- could just as well have made the hit.
local function UnlearnedCastAt(plate, now)
    for _, entry in ipairs(log) do
        if now - entry.at <= UNKNOWN_WAIT and not entry.tracker and entry.plate == plate
            and not Fingerprints.IsLearned(entry.base) then
            return true
        end
    end
    return false
end

-- Whose hit is this? "learned", record: the open records that fit are all casts of one spell
-- (the oldest answers; Void Blast can fire twice in one frame) and no unlearned cast is on the
-- plate. "ambiguous": records of two spells fit, or an unlearned cast is on the plate (spec 6.1
-- read literally: that alone spoils the answer, fit or not). nil: nothing to say. Changes
-- nothing; Accept is the only writer.
function Casts.Claim(plate, school, now)
    if not (Plain(plate) and Plain(school) and Plain(now)) then return nil end
    local found, fits = nil, 0
    for _, record in ipairs(records) do
        local fp = Live(record, now)
        if fp and Fits(record, fp, plate, school, now) then
            if found and found.spellID ~= record.spellID then fits = fits + 1 end
            found, fits = found or record, math.max(fits, 1)
        end
    end
    if fits >= 2 or UnlearnedCastAt(plate, now) then return "ambiguous" end
    if fits == 1 then return "learned", found end
end

-- The hit is drawn: the record has taken one more hit.
function Casts.Accept(record, plate, now)
    record.hops, record.plates[plate], record.last = record.hops + 1, true, now
end

-- The one harmful cast that can explain a hit on `plate` at `at`: the log entries in
-- [at - UNKNOWN_WAIT, at] share one base spell (the newest of them answers), not a tracker
-- spell, cast at `plate`. Else nil. The teacher learns under the entry's `base`.
function Casts.SoleCast(plate, at)
    if plate == nil then return nil end
    local found
    for _, entry in ipairs(log) do
        if at - UNKNOWN_WAIT <= entry.at and entry.at <= at then
            if found and found.base ~= entry.base then return nil end
            found = entry
        end
    end
    if found and not found.tracker and found.plate == plate then return found end
end

-- Forgets what was learned: the fingerprints (and their aliases).
function Casts.Forget()
    ns.Fingerprints.Forget()
end
