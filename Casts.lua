-- Combat Text Icons: casts. This module holds the cast log (the harmful casts, the player's
-- and the pet's, that can explain a hit) and the open records: a cast whose fingerprint is learned waits
-- for its hit, and Claim and Accept turn that hit into a direct-hit icon.
-- An override cast (Void Blast 450983 over Mind Blast 8092) is filed by the meter under
-- its base spell's row, so every entry and record keeps both: `spellID` (the cast, for
-- the icon) and `base` (Casts.Base, for fingerprints and the teacher).

local ADDON, ns = ...
local Learn, Tracker, Fingerprints, Procs, Streams = ns.Learn, ns.Tracker, ns.Fingerprints, ns.Procs, ns.Streams

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
-- A cast the meter files under its own ID keys by it, whatever the API says (Lava Burst 51505
-- has its own row and none for its base 73899, run 20261025T175419Z; Wither 445468 over
-- Corruption 172, run 20261025T180045Z). Void Blast never shows a row of its own, so it stays 8092.
local remembered = {}   -- castID -> the base it was seen overriding; never saved
local ownRows = {}      -- spellID -> true: the meter showed a row of this ID; CombatTextIconsCharDB.ownRows

function Casts.Base(castID)
    if ownRows[castID] then return castID end
    local find = (C_SpellBook and C_SpellBook.FindBaseSpellByID) or FindBaseSpellByID
    if not find then return castID end
    local ok, base = pcall(find, castID)
    if not (ok and IsNumber(base)) then return castID end
    if base ~= castID then remembered[castID] = base end

    return remembered[castID] or base
end

-- Login: the saved own rows, checked (only number keys with the value true stay).
-- /cti forget keeps them: they record how the meter files a spell, not what was learned.
function Casts.InitOwnRows(charDB)
    if type(charDB.ownRows) ~= "table" then charDB.ownRows = {} end
    ownRows = charDB.ownRows
    for spellID, value in pairs(ownRows) do
        if type(spellID) ~= "number" or value ~= true then ownRows[spellID] = nil end
    end
end

-- A meter read: every row's spell ID files under itself from now on. `rows` are
-- { spellID, total, overkill } (Teacher's rows, plain after combat).
function Casts.NoteRows(rows)
    for _, row in ipairs(rows) do ownRows[row.spellID] = true end
end

-- The same read for the fight it ends: its unexplained hits (and their candidates) keyed by an API
-- base with no row of its own move to their cast's row (Lava Burst 73899 -> 51505), so the first
-- fight that shows a row can learn it.
function Casts.Rekey(hits, rows)
    local own = {}
    for _, row in ipairs(rows) do own[row.spellID] = true end
    local function Move(cast)
        if cast.castSpell and own[cast.castSpell] and not own[cast.castID] then cast.castID = cast.castSpell end
    end
    for _, hit in ipairs(hits) do
        Move(hit)
        for _, candidate in ipairs(hit.candidates or {}) do Move(candidate) end
    end
end

-- A learned chain fingerprint (Chain Lightning): its later hits land on new plates.
local CHAIN_GAP = 0.15   -- each later hit lands this long after the previous one at most
local CHAIN_MAX = 5      -- hits one chain shows at most

local UNKNOWN_WAIT = 1.5 -- a hit is explained by a cast at most this long before it
local LOG_MAX = 20       -- cast log entries kept at most
local log = {}           -- harmful player and pet casts, oldest first: { spellID, base, at, plate, tracker }

-- Open records: a learned cast waiting for its hit. A hit that fits one is drawn with the
-- cast's icon; Accept is the only writer of hops. Claim only notes what each record saw (its centre).
local SLACK = 0.05      -- a window edge may be this far off
local LATE = 2          -- a cast with no hit yet takes a late one up to this times its window top
local PAD_LO, PAD_HI = 0.7, 2 -- a sized hit fits a cast's band from 0.7 of its smallest to twice its biggest learned size
local RECORD_MAX = 20   -- open records at most; the oldest is dropped
local records = {}      -- oldest first: { spellID, base, at, plate, hops, plates, last, seen, settled }
local SPLASH = 0.5      -- a cast's splash lands on other plates at most this long after its own hit (Splash)
local QUIET = 1.5       -- and only when no unclaimed hit like it landed on another plate this long before that hit
local wounds = {}       -- the hits Claim was asked about lately, oldest first: { plate, school, size, at, claimed }

-- Travel time follows distance, and distance changes per fight: Shadow Bolt 686 learned at 1.10-1.16 s
-- landed at 0.92-1.09 s the next fight, 1.12-1.26 s the one after (run 20261025T180045Z). So each cast
-- spell keeps a delay centre per plate for the fight. A record watches its window widened by WATCH;
-- once past that, exactly one hit seen there (its school, its plate, in band) moves the centre ALPHA of
-- the way to that hit's delay (the first sets it). A cast within CENTRE_AGE of the centre's last cast
-- widens its learned window to cover the centre (learned width around it); it never narrows.
local WATCH = 0.2       -- a record watches this far below and above its window
local ALPHA = 0.5       -- a seen hit moves the centre this share of the way to its delay
local CENTRE_AGE = 10   -- a centre older than this (cast to cast) is ignored and restarts
local centres = {}      -- "base:spell@plate" -> { delay, at }; cleared when the fight ends

local function CentreKey(record) return record.base .. ":" .. record.spellID .. "@" .. tostring(record.plate) end

-- The delay window of `record`: the learned one, widened to the learned width around a fresh centre.
local function RecordWindow(record)
    local low, high = Fingerprints.Window(record.base, record.spellID)
    local centre = centres[CentreKey(record)]
    if not (low and centre and record.at - centre.at <= CENTRE_AGE) then return low, high end
    local half = (high - low) / 2

    return math.min(low, centre.delay - half), math.max(high, centre.delay + half)
end

-- Once `now` is past the record's watch range, its one seen hit (if exactly one) moves the centre.
local function Settle(record, now)
    if record.settled then return end
    local _, high = RecordWindow(record)
    if high and now <= record.at + high + WATCH then return end
    record.settled = true
    if not (record.seen and #record.seen == 1) then return end
    local key, delay = CentreKey(record), record.seen[1]
    local centre = centres[key]
    if centre and record.at - centre.at <= CENTRE_AGE then
        centre.delay = centre.delay + ALPHA * (delay - centre.delay)
    else
        centre = { delay = delay }
        centres[key] = centre
    end
    centre.at = record.at
end

-- The fingerprint (its base's) a record still waits on, or nil when the record is dead: its
-- fingerprint is gone or unlearned, or `now` is past its window (a chain record
-- that took a hop lives CHAIN_GAP past its last hop, if that is later).
local function Live(record, now)
    local fp = Fingerprints.Get(record.base)
    if not (fp and fp.learned) then return nil end
    local _, high = RecordWindow(record)
    local limit = record.at + LATE * high + SLACK
    if fp.pattern == "chain" and record.hops >= 1 then limit = math.max(limit, record.last + CHAIN_GAP) end
    if now <= limit then return fp end
end

local function SweepRecords(now)
    for index = #records, 1, -1 do
        local record = records[index]
        Settle(record, now)
        if not Live(record, now) then
            Settle(record, math.huge)
            table.remove(records, index)
        end
    end
end

-- Fight over: the open records settle, the ones whose window has passed are dropped, the centres go.
function Casts.Flush(now)
    for _, record in ipairs(records) do Settle(record, math.huge) end
    SweepRecords(now)
    centres, wounds = {}, {}
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

-- A pet's cast lands on the pet's target: the player's target plate while the pet attacks it (UnitIsUnit plain true),
-- else no plate, so its hits name no cast. It never takes the player's cast start.
local function PetPlate()
    local ok, same = pcall(UnitIsUnit, "target", "pettarget")
    if ok and Plain(same) and same then return Tracker.TargetPlate() end
end

-- A harmful cast of the player, or of the pet when `pet` (the meter files pet damage under the player's own rows).
function Casts.NoteCast(castID, now, castGUID, pet)
    SweepRecords(now)
    local base = Casts.Base(castID)
    local learned = Learn.Get(castID)
    local plate
    if pet then plate = PetPlate() else plate = CastPlate(castID, castGUID, now) end
    local entry = { spellID = castID, base = base, at = now, plate = plate,
        tracker = Learn.IsKnownIcon(castID), ticks = learned and learned.school }
    log[#log + 1] = entry
    while now - log[1].at > UNKNOWN_WAIT or #log > LOG_MAX do table.remove(log, 1) end

    if entry.plate and Fingerprints.IsLearned(base) then
        records[#records + 1] = { spellID = castID, base = base, at = now, plate = entry.plate, hops = 0, plates = {},
            last = now }
        if #records > RECORD_MAX then table.remove(records, 1) end
    end
end

-- Whether normal-scale `size` lies inside the learned sizes of the record's cast spell, unpadded.
local function InLearnedSizes(record, size)
    local small, big = Fingerprints.Band(record.base, record.spellID)

    return small ~= nil and IsNumber(size) and small <= size and size <= big
end

-- Whether normal-scale `size` lies within Streams.SIZE_GUARD of the learned sizes of the record's cast spell (two hits
-- of a kind), not the padded band.
local function NearSizes(record, size)
    local small, big = Fingerprints.Band(record.base, record.spellID)
    local guard = 1 - Streams.SIZE_GUARD

    return small ~= nil and IsNumber(size) and size >= guard * small and size * guard <= big
end

-- Whether a hit of `school` on `plate`, another plate than the cast's, is the cast's splash: a plate it has not hit
-- yet, NearSizes, in a later frame than the first hit the record saw on its own plate (Watch) and at most SPLASH after
-- it, while no unclaimed hit of its school NearSizes landed on another plate in the QUIET before that own hit (wounds).
-- Run shaman5 fight 5: Lava Burst 51505 learned at 0.20-0.28 s on its target hit 4 other dummies 0.13-0.45 s after its
-- target hit, with 37-48K (learned 39.8-44.7K): 994K of its row's 2.14M that no claim took. Hits of its school and size
-- that land on other plates anyway are no splash: lock3 fight 2 drew 8.5-10K Shadow hits on 4 plates 1.67 s after a
-- Shadow Bolt 686's own hit, and on another plate in the own hit's frame; hunter fight 18's pet left ~5K Physical hits
-- on every plate around, before and after a Kill Command 34026's own hit.
local function Splash(record, plate, school, now, size)
    if not record.seen or record.plates[plate] then return false end
    local own = record.at + record.seen[1]
    if now <= own or now - own > SPLASH or not NearSizes(record, size) then return false end
    for _, wound in ipairs(wounds) do
        if not wound.claimed and wound.plate ~= record.plate and wound.school == school and wound.at < own
            and own - wound.at <= QUIET and NearSizes(record, wound.size) then
            return false
        end
    end

    return true
end

-- Does `record` still wait for a hit of `school` on `plate` at `now`? "in": its first hit
-- lands on the cast's plate inside its delay window (RecordWindow), or a chain's later hit lands on a
-- new plate within CHAIN_GAP of the one before (CHAIN_MAX in all). "late": a first hit past the
-- window, up to LATE times its top (Mind Blast's travel varies with distance), while the record has
-- seen no hit in its watch range: one it saw was its own, spoiled (Darkglare's beam took Shadow Bolt's
-- late slot after an ambiguous hit, run 20261025T180045Z). An early first hit, up to WATCH under the
-- window, fits the same weak way when `size` is inside the learned sizes, unpadded: Lava Burst learned
-- at 0.50-0.60 s in a first fight landed at 0.37-0.44 s in every later one. A hit on another plate fits a
-- non-chain record the same weak way when it is the cast's Splash. Else false.
local function Fits(record, fp, plate, school, now, size)
    if school ~= fp.school then return false end
    if plate ~= record.plate and fp.pattern ~= "chain" then
        return Splash(record, plate, school, now, size) and "late"
    end
    if record.hops == 0 then
        local age = now - record.at
        local low, high = RecordWindow(record)
        if plate ~= record.plate then return false end
        if age < low - SLACK then
            return not record.seen and age >= low - WATCH and InLearnedSizes(record, size) and "late"
        end
        if age <= high + SLACK then return "in" end

        return not record.seen and age <= LATE * high + SLACK and "late"
    end
    return fp.pattern == "chain" and not record.plates[plate] and now - record.last <= CHAIN_GAP
        and record.hops < CHAIN_MAX and "in"
end

-- A first hit of the record's school on its plate, in band, within WATCH of its window: one more seen.
local function Watch(record, fp, plate, school, now, size)
    if record.settled or record.hops > 0 or plate ~= record.plate or school ~= fp.school then return end
    local low, high = RecordWindow(record)
    local age = now - record.at
    if age < low - WATCH or age > high + WATCH or not Casts.InBand(record.base, record.spellID, size) then return end
    record.seen = record.seen or {}
    record.seen[#record.seen + 1] = age
end

-- Adds a fitting record to a claim count: records of one spell count once (the first, oldest,
-- answers); a record of another spell makes it two.
local function Count(found, fits, record)
    if found and found.spellID ~= record.spellID then fits = fits + 1 end

    return found or record, math.max(fits, 1)
end

-- Whether the logged cast `entry` cannot have made a hit of `school`, on what the meter taught: its base's row is a
-- learned proc of another school (Flame Shock's school-12 hits, cast after a Lava Burst), or the meter showed the
-- cast rowless (Learn.Rowless) and its base is no own row (Totemic Projection 108287 after a Lava Burst, run shaman4
-- fight 2).
local function Harmless(entry, school)
    local proc = Procs.Get(entry.base)
    if proc then return proc.school ~= school end

    return Learn.Rowless(entry.spellID) and not ownRows[entry.base]
end

-- A harmful non-tracker cast on `plate` within UNKNOWN_WAIT, after `since`, that no fingerprint
-- knows could just as well have made the hit. One cast before the learned cast (or in its frame)
-- does not: run 20261025T172757Z lost 4 Void Blast hits to Void Eruption and SW:Death that way.
-- When `sure`, neither does a cast the meter says cannot have made a hit of `school` (Harmless).
local function UnlearnedCastAt(plate, now, since, sure, school)
    for _, entry in ipairs(log) do
        if now - entry.at <= UNKNOWN_WAIT and entry.at > since and not entry.tracker and entry.plate == plate
            and not Fingerprints.IsLearned(entry.base) and not (sure and Harmless(entry, school)) then
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

    return Casts.InSizes(low, high, size)
end

-- Whether normal-scale `size` (nil or 0: any) fits the padded band of sizes `low`-`high`.
function Casts.InSizes(low, high, size)
    if not (IsNumber(size) and size > 0) then return true end

    return size >= PAD_LO * low and size <= PAD_HI * high
end

-- Whether a hit at `now` of normal-scale `size` fits `record` on its learned evidence alone: inside the
-- learned window (no centre) and the learned sizes.
local function Sure(record, now, size)
    local low, high = Fingerprints.Window(record.base, record.spellID)
    local age = now - record.at

    return low ~= nil and age >= low - SLACK and age <= high + SLACK and InLearnedSizes(record, size)
end

-- Whether a hit at `now` of normal-scale `size` fits `record` in a crowd: inside the learned window (no centre) and
-- within Streams.SIZE_GUARD of the learned sizes (two hits of a kind), not the padded band. A fight's sizes drift a
-- little (lock3 fight 3: Shadow Bite learned at 2975-3123 hit 2774-3315).
local function CrowdFits(record, now, size)
    local low, high = Fingerprints.Window(record.base, record.spellID)
    local age = now - record.at

    return low ~= nil and age >= low - SLACK and age <= high + SLACK and NearSizes(record, size)
end

-- Whose hit is this? "learned", record: the open records that fit (InBand, then Fits) are all
-- casts of one spell (the oldest answers; Void Blast can fire twice in one frame) and no
-- unlearned cast is on the plate. Records that fit late answer only when none fits in its window. "ambiguous": records of two spells fit, or an unlearned cast is on the plate (spec 6.1
-- read literally: that alone spoils the answer, fit or not), unless the hit is Sure for the one record and the meter
-- says that cast cannot have made it (Harmless). nil: nothing to say. `size` is the
-- hit's normal-scale size (Streams.NormalAmount), nil when unknown. A "learned" answer's third value is true when
-- the record fit only late. Draws nothing; Accept is the only writer of hops. Each hit asked about stays a wound for
-- QUIET + SPLASH (Splash).
-- When `strict` (Core: the fight turned crowded), a record fits only a hit it CrowdFits: strangers' hits of its school
-- land in every padded window (lock3 fight 3: 4 Shadow Bolt casts drew 118730 against a row of 76384; three of the
-- four drawn hits lay outside the learned sizes, two of them crits of twice the biggest).
function Casts.Claim(plate, school, now, size, strict)
    if not (Plain(plate) and Plain(school) and Plain(now)) then return nil end
    local found, fits, late, lateFits = nil, 0, nil, 0
    for _, record in ipairs(records) do
        Settle(record, now)
        local fp = Live(record, now)
        local fit = fp and Casts.InBand(record.base, record.spellID, size) and Fits(record, fp, plate, school, now, size)
        if strict and not (fit == "in" and CrowdFits(record, now, size)) then fit = false end
        if fp then Watch(record, fp, plate, school, now, size) end
        if fit == "in" then
            found, fits = Count(found, fits, record)
        elseif fit == "late" then
            late, lateFits = Count(late, lateFits, record)
        end
    end
    wounds[#wounds + 1] = { plate = plate, school = school, size = size, at = now }
    while now - wounds[1].at > QUIET + SPLASH do table.remove(wounds, 1) end
    local lateOnly = fits == 0 and late ~= nil
    if lateOnly then found, fits = late, lateFits end
    local sure = fits == 1 and not lateOnly and Sure(found, now, size)
    if fits >= 2 or UnlearnedCastAt(plate, now, found and found.at or -math.huge, sure, school) then
        return "ambiguous"
    end
    if fits == 1 then return "learned", found, lateOnly end
end

-- The hit is drawn: the record has taken one more hit, and the hit (Claim's last wound) is claimed. A splash while the
-- record's own first hit is unclaimed (ambiguous) leaves that hit open.
function Casts.Accept(record, plate, now)
    local wound = wounds[#wounds]
    if wound and wound.plate == plate and wound.at == now then wound.claimed = true end
    record.plates[plate] = true
    if plate ~= record.plate and record.hops == 0 then return end
    record.hops, record.last = record.hops + 1, now
end

-- Whether a tracker cast's ticks explain a hit of `school`: a learned DoT only its own school's
-- (a stale save learned Lava Burst as a Nature DoT and hid its Fire hits, run shaman3 start);
-- a table spell, or a hit of unknown school, every school.
local function Ticks(entry, school)
    return entry.tracker and (entry.ticks == nil or school == nil or entry.ticks == school)
end

-- The one harmful cast that can explain a hit of `school` on `plate` at `at`: the log entries in
-- [at - UNKNOWN_WAIT, at] share one base spell (the newest of them answers), whose ticks don't
-- explain the hit, cast at `plate`. Else nil. The teacher learns under the entry's `base`.
function Casts.SoleCast(plate, at, school)
    if plate == nil then return nil end
    local found
    for _, entry in ipairs(log) do
        if at - UNKNOWN_WAIT <= entry.at and entry.at <= at then
            if found and found.base ~= entry.base then return nil end
            found = entry
        end
    end
    if found and not Ticks(found, school) and found.plate == plate then return found end
end

-- Every cast that may have made a hit of `school` on `plate` at `at`, for the steady pass (Steady.lua):
-- the log entries whose ticks don't explain it, cast at `plate` in [at - UNKNOWN_WAIT, at], learned bases too, oldest
-- first, as { castID = base, castAt, castSpell }. A spell logged twice in one frame (Void Blast) is
-- one cast. Empty when `plate` is nil.
function Casts.Candidates(plate, at, school)
    local list, seen = {}, nil -- seen: made on the first cast that passes (most hits have none)
    if plate == nil then return list end
    for _, entry in ipairs(log) do
        if at - UNKNOWN_WAIT <= entry.at and entry.at <= at and entry.plate == plate and not Ticks(entry, school) then
            local key = entry.spellID .. "@" .. entry.at
            seen = seen or {}
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = { castID = entry.base, castAt = entry.at, castSpell = entry.spellID }
            end
        end
    end

    return list
end

-- Forgets what was learned: the fingerprints (and their aliases).
function Casts.Forget()
    ns.Fingerprints.Forget()
end
