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
-- A cast seen overriding keeps that base for the session: when its override ends in the
-- cast's own frame the API answers the cast itself (run 20261025T162725Z, a window's last
-- Void Blast at 5931.198 read 450983 and its hit drew '?').
local remembered = {}   -- castID -> the base it was seen overriding; never saved

function Casts.Base(castID)
    local find = (C_SpellBook and C_SpellBook.FindBaseSpellByID) or FindBaseSpellByID
    if not find then return castID end
    local ok, base = pcall(find, castID)
    if not (ok and IsNumber(base)) then return castID end
    if base ~= castID then remembered[castID] = base end

    return remembered[castID] or base
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
local LATE = 2          -- a cast with no hit yet takes a late one up to this times its window top
local PAD_LO, PAD_HI = 0.5, 2 -- a sized hit fits a cast's band from half its smallest to twice its biggest learned size
local RECORD_MAX = 20   -- open records at most; the oldest is dropped
local records = {}      -- oldest first: { spellID, base, at, plate, hops, plates, last }

-- The fingerprint (its base's) a record still waits on, or nil when the record is dead: its
-- fingerprint is gone or unlearned, or `now` is past its window (a chain record
-- that took a hop lives CHAIN_GAP past its last hop, if that is later).
local function Live(record, now)
    local fp = Fingerprints.Get(record.base)
    if not (fp and fp.learned) then return nil end
    local _, high = Fingerprints.Window(record.base, record.spellID)
    local limit = record.at + LATE * high + SLACK
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

-- The cast in progress (UNIT_SPELLCAST_START): a spell with a cast time keeps the target it started
-- on, so a retarget mid-cast (to the next mob, run 134732Z) must not move its plate.
local START_MAX = 10    -- a start older than this names no plate
local started = nil     -- { guid, spellID, plate, at }

function Casts.NoteStart(castGUID, spellID, now)
    started = { guid = castGUID, spellID = spellID, plate = Tracker.TargetPlate(), at = now }
end

-- The plate the finished cast `castID` started on: the start with the same plain cast GUID (any
-- secret: the same spell ID) within START_MAX. Else the target now (an instant cast).
local function CastPlate(castID, castGUID, now)
    local start = started
    started = nil
    if not (start and start.plate and now - start.at <= START_MAX) then return Tracker.TargetPlate() end
    local plainGUIDs = Plain(castGUID) and Plain(start.guid)
    local same = plainGUIDs and castGUID == start.guid or not plainGUIDs and start.spellID == castID
    if same then return start.plate end

    return Tracker.TargetPlate()
end

function Casts.NoteCast(castID, now, castGUID)
    SweepRecords(now)
    local base = Casts.Base(castID)
    local entry = { spellID = castID, base = base, at = now, plate = CastPlate(castID, castGUID, now),
        tracker = Learn.IsKnownIcon(castID) }
    log[#log + 1] = entry
    while now - log[1].at > UNKNOWN_WAIT or #log > LOG_MAX do table.remove(log, 1) end

    if entry.plate and Fingerprints.IsLearned(base) then
        records[#records + 1] = { spellID = castID, base = base, at = now, plate = entry.plate, hops = 0, plates = {},
            last = now }
        if #records > RECORD_MAX then table.remove(records, 1) end
    end
end

-- Does `record` still wait for a hit of `school` on `plate` at `now`? "in": its first hit
-- lands on the cast's plate inside the learned delay window, or a chain's later hit lands on a
-- new plate within CHAIN_GAP of the one before (CHAIN_MAX in all). "late": a first hit past the
-- window, up to LATE times its top (Mind Blast's travel varies with distance). Else false.
local function Fits(record, fp, plate, school, now)
    if school ~= fp.school then return false end
    if record.hops == 0 then
        local age = now - record.at
        local low, high = Fingerprints.Window(record.base, record.spellID)
        if plate ~= record.plate or age < low - SLACK then return false end
        if age <= high + SLACK then return "in" end

        return age <= LATE * high + SLACK and "late"
    end
    return fp.pattern == "chain" and not record.plates[plate] and now - record.last <= CHAIN_GAP
        and record.hops < CHAIN_MAX and "in"
end

-- Adds a fitting record to a claim count: records of one spell count once (the first, oldest,
-- answers); a record of another spell makes it two.
local function Count(found, fits, record)
    if found and found.spellID ~= record.spellID then fits = fits + 1 end

    return found or record, math.max(fits, 1)
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

-- Does a hit of normal-scale `size` fit the learned size band (padded) of `castSpell` under `base`? A
-- Shadow DoT tick (0.9-6K) is not Mind Blast (18-25K) though it lands in its window. No size (nil, 0)
-- or no band (unlearned, or saved before sizes were kept) fits.
function Casts.InBand(base, castSpell, size)
    if not (IsNumber(size) and size > 0) then return true end
    local low, high = Fingerprints.Band(base, castSpell)
    if not low then return true end

    return size >= PAD_LO * low and size <= PAD_HI * high
end

-- Whose hit is this? "learned", record: the open records that fit (InBand, then Fits) are all
-- casts of one spell (the oldest answers; Void Blast can fire twice in one frame) and no
-- unlearned cast is on the plate. Records that fit late answer only when none fits in its window. "ambiguous": records of two spells fit, or an unlearned cast is on the plate (spec 6.1
-- read literally: that alone spoils the answer, fit or not). nil: nothing to say. `size` is the
-- hit's normal-scale size (Streams.NormalAmount), nil when unknown. Changes nothing; Accept is the only writer.
function Casts.Claim(plate, school, now, size)
    if not (Plain(plate) and Plain(school) and Plain(now)) then return nil end
    local found, fits, late, lateFits = nil, 0, nil, 0
    for _, record in ipairs(records) do
        local fp = Live(record, now)
        local fit = fp and Casts.InBand(record.base, record.spellID, size) and Fits(record, fp, plate, school, now)
        if fit == "in" then
            found, fits = Count(found, fits, record)
        elseif fit == "late" then
            late, lateFits = Count(late, lateFits, record)
        end
    end
    if fits == 0 then found, fits = late, lateFits end
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

-- Every cast that may have made a hit on `plate` at `at`, for the steady pass (Steady.lua): the
-- non-tracker log entries cast at `plate` in [at - UNKNOWN_WAIT, at], learned bases too, oldest
-- first, as { castID = base, castAt, castSpell }. A spell logged twice in one frame (Void Blast) is
-- one cast. Empty when `plate` is nil.
function Casts.Candidates(plate, at)
    local list, seen = {}, {}
    if plate == nil then return list end
    for _, entry in ipairs(log) do
        local key = entry.spellID .. "@" .. entry.at
        if at - UNKNOWN_WAIT <= entry.at and entry.at <= at and entry.plate == plate and not entry.tracker
            and not seen[key] then
            seen[key] = true
            list[#list + 1] = { castID = entry.base, castAt = entry.at, castSpell = entry.spellID }
        end
    end

    return list
end

-- Forgets what was learned: the fingerprints (and their aliases).
function Casts.Forget()
    ns.Fingerprints.Forget()
end
