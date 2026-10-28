-- Periodic hits no tracked spell claimed, grouped into streams, plus the log of
-- the player's own casts that Learn.lua matches streams against.
--
-- Per key (a plate frame, or a unit token for heals):
--   loose    the unclaimed hits of each school that extended no stream, kept for
--            20 s (at most 64);
--   streams  a stream is born from 4 hits of one school with 3 agreeing gaps,
--            then extended by later hits one or two periods on; it dies 2.5
--            periods after its last hit;
--   casts    the player's casts of the last 35 s, so a birth can name the casts
--            that landed in its birth window (its owners).
-- Core feeds unclaimed hits through Streams.Feed and Tracker logs casts through
-- Streams.LogCast; Streams reports births and casts to Learn.
-- Every value from the game API may be secret: school, castID, amount and flag are
-- checked before any comparison or use as a table key.

local ADDON, ns = ...

local Streams = {}
ns.Streams = Streams

local PERIOD_MIN, PERIOD_MAX = ns.Learn.PERIOD_MIN, ns.Learn.PERIOD_MAX -- a stream's period, in seconds
local LOOSE_CAP = 64                   -- loose hits kept per key and school (the age limit comes first)
local LOOSE_AGE = 2 * PERIOD_MAX       -- a loose hit older than this can no longer pair
local STREAMS_MAX = 6                  -- live streams per key
local DEATH = 2.5                      -- a stream dies this many periods after its last hit
local STEP_MAX = 1.5                   -- a buff steps a running stream's size by at most this factor (see Start)
local RAMP_STEP, RAMP_SHARE = 1.6, 0.2 -- RampStart: a ramp tick's step, and its fit within max(SLACK_MIN, 0.2 * period)
local SIZE_GUARD = 0.15                -- two hits pair only within this share of each other's size
local CAST_LOG = 35                    -- seconds a logged cast is kept
local WINDOW_FROM, WINDOW_TO = 1.2, 0.5 -- birth window: [birth - 1.2 P, birth - 0.5 P]
local SLACK_MIN, SLACK_SHARE = 0.1, 0.15 -- a hit fits a predicted time within max(0.1, 0.15 * period)
local BLEND = 0.8                      -- weight of the old period when a hit extends a stream
local WIDE_PLATES = 3                  -- plates a ground patch's frame hits at least (Ground.lua's MIN_PLATES)
-- A crit's size over a normal hit: x1.5 on Forever (SW:P 31 -> 46/47, measured 2026-10-23), x2.4 on retail
-- with spread. A crit and a normal hit agree when crit / normal is in [CRIT_LO, CRIT_HI]; CRIT_MID turns a
-- crit into a normal-scale size when no normal hit is known. CRIT_FACTOR serves NormalAmount only.
local CRIT_LO, CRIT_HI = ns.IsForever and 1.35 or 1.8, ns.IsForever and 1.65 or 2.7
local CRIT_MID = ns.IsForever and 1.5 or 2.25
local CRIT_FACTOR = ns.IsForever and 1.5 or 2
-- Read-only exports: Procs.lua groups and matches with the same numbers.
Streams.SIZE_GUARD, Streams.CRIT_LO, Streams.CRIT_HI = SIZE_GUARD, CRIT_LO, CRIT_HI
Streams.RAMP_STEP = RAMP_STEP -- Tracker.lua: a learned instance's ramp step

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local channelCast      -- the newest channel's cast-log entry; Streams.StopChannel stamps its `stop`
local current          -- [stream] = { school, sum, n, lo, hi }: this fight's share of each stream (Streams.NewFight)

-- Adds a hit to the stream's record in the current fight when shouldRecord. sum and n take every number; lo and
-- hi only a normal hit.
local function Note(stream, size, crit, shouldRecord)
    if not shouldRecord or not current or type(size) ~= "number" then return end
    local rec = current[stream]
    if not rec then
        rec = { school = stream.school, sum = 0, n = 0 }
        current[stream] = rec
    end
    rec.sum, rec.n = rec.sum + size, rec.n + 1
    if not crit and size > 0 then rec.lo, rec.hi = math.min(rec.lo or size, size), math.max(rec.hi or size, size) end
end

-- Starts a new fight record table, makes it current and returns it.
function Streams.NewFight()
    current = {}

    return current
end

-- Joins fight record tables: `from`'s records are added into `into` (a stream both hold sums), returns `into`.
function Streams.JoinFight(into, from)
    for stream, rec in pairs(from) do
        local joined = into[stream]
        if not joined then
            into[stream] = rec
        else
            joined.sum, joined.n = joined.sum + rec.sum, joined.n + rec.n
            if rec.lo then joined.lo, joined.hi = math.min(joined.lo or rec.lo, rec.lo), math.max(joined.hi or rec.hi, rec.hi) end
        end
    end

    return into
end

local state = {}   -- [key] = { casts = { { at, castID, kind } }, loose = { [school] = { { at, amount, crit } } }, streams = {} }
-- [at] = { [school] = { [plate key] = true } }: the plates each school's fed plate hits landed on, per frame of the
-- last LOOSE_AGE seconds; `frameTimes` lists those frames oldest first, for pruning.
local frames, frameTimes = {}, {}

local function State(key)
    local entry = state[key]
    if not entry then
        entry = { casts = {}, loose = {}, streams = {} }
        state[key] = entry
    end

    return entry
end

-- A hit's size and crit flag, plain only: size is nil when amount or flag is secret or not a number.
local function Size(amount, flagText)
    if not (Plain(amount) and Plain(flagText)) or type(amount) ~= "number" then return nil, false end

    return amount, flagText == "CRITICAL"
end

-- Crit flag and amount, plain only. Crits are divided by CRIT_FACTOR to compare with normal ticks.
function Streams.NormalAmount(amount, flagText)
    local size, crit = Size(amount, flagText)
    if size and crit then return size / CRIT_FACTOR end

    return size
end

-- Size guard: a missing or zero amount agrees with anything; one crit and one normal hit agree
-- within the crit band, two of a kind within SIZE_GUARD.
local function Agree(x, xCrit, y, yCrit)
    if not x or not y or x == 0 or y == 0 then return true end
    if xCrit == yCrit then return math.abs(x - y) <= SIZE_GUARD * math.max(x, y) end
    local crit, normal = x, y
    if yCrit then crit, normal = y, x end
    local ratio = crit / normal

    return ratio >= CRIT_LO and ratio <= CRIT_HI
end

-- A birth's normal-scale size from its hits ({ amount, crit }, oldest first): the newest normal
-- hit, else the newest crit over CRIT_MID.
local function BirthAmount(list)
    for index = #list, 1, -1 do
        local hit = list[index]
        if not hit.crit and hit.amount and hit.amount > 0 then return hit.amount end
    end
    for index = #list, 1, -1 do
        local hit = list[index]
        if hit.crit and hit.amount and hit.amount > 0 then return hit.amount / CRIT_MID end
    end
end

-- How far a hit may land from a time predicted with `period` and still fit it.
function Streams.Slack(period) return math.max(SLACK_MIN, SLACK_SHARE * period) end

-- The shortest gap a birth pairs: PERIOD_MIN less its slack, the jitter every other gap is allowed. A rhythm at
-- ~0.50 s jitters both ways (run shaman3, proc 1297908: gaps 0.512 / 0.506 / 0.496 / 0.499), so a hard 0.5 on one
-- gap kept its stream unborn.
local GAP_MIN = PERIOD_MIN - Streams.Slack(PERIOD_MIN)

-- Pruning ----------------------------------------------------------------------------

-- Keeps the entries `keep` accepts, in order.
local function Filter(list, keep)
    local kept = {}
    for _, item in ipairs(list) do
        if keep(item) then kept[#kept + 1] = item end
    end
    return kept
end

-- Keeps the entries `keep(item, now)` accepts, in order. Runs on every Feed, and mostly nothing expires: then
-- `list` itself comes back, with no new table.
local function Prune(list, keep, now)
    for index, item in ipairs(list) do
        if not keep(item, now) then
            local kept = {}
            for earlier = 1, index - 1 do kept[earlier] = list[earlier] end
            for later = index + 1, #list do
                if keep(list[later], now) then kept[#kept + 1] = list[later] end
            end
            return kept
        end
    end
    return list
end

local function CastFresh(cast, now) return now - cast.at <= CAST_LOG end
local function StreamAlive(stream, now) return now <= stream.lastAt + DEATH * stream.period end

local function PruneCasts(entry, now)
    entry.casts = Prune(entry.casts, CastFresh, now)
end

-- Loose lists are oldest first, so the expired hits are a prefix: shift them out in place.
local function PruneLoose(entry, now)
    for _, hits in pairs(entry.loose) do
        local count, drop = #hits, 0
        while drop < count and now - hits[drop + 1].at > LOOSE_AGE do drop = drop + 1 end
        if drop > 0 then
            for index = 1, count - drop do hits[index] = hits[index + drop] end
            for index = count - drop + 1, count do hits[index] = nil end
        end
    end
end

local function PruneDead(entry, now)
    entry.streams = Prune(entry.streams, StreamAlive, now)
end

-- Notes a plate hit's frame after dropping the frames older than LOOSE_AGE.
local function NoteFrame(key, school, now)
    while frameTimes[1] and now - frameTimes[1] > LOOSE_AGE do frames[table.remove(frameTimes, 1)] = nil end
    local frame = frames[now]
    if not frame then
        frame = {}
        frames[now] = frame
        frameTimes[#frameTimes + 1] = now
    end
    frame[school] = frame[school] or {}
    frame[school][key] = true
end

-- Whether every frame in `times` holds hits of `school` on WIDE_PLATES plates or more.
local function Wide(school, times)
    for _, at in ipairs(times) do
        local count = 0
        for _ in pairs(frames[at] and frames[at][school] or {}) do count = count + 1 end
        if count < WIDE_PLATES then return false end
    end

    return true
end

-- Stream rules -----------------------------------------------------------------------

-- The live stream of `school` that `now` extends, and by how many periods (1 or 2);
-- the smallest timing error wins.
local function FindExtension(entry, school, size, crit, heal, now)
    local best, bestMultiple, bestError
    for _, stream in ipairs(entry.streams) do
        if stream.school == school and (heal or Agree(size, crit, stream.lastAmount, false)) then
            for multiple = 1, 2 do
                local err = math.abs(now - (stream.lastAt + multiple * stream.period))
                if err <= Streams.Slack(stream.period) and (not bestError or err < bestError) then
                    best, bestMultiple, bestError = stream, multiple, err
                end
            end
        end
    end

    return best, bestMultiple
end

-- Size guard over a birth's hits ({ amount, crit }): `hit` agrees with x and, when given, y and z.
-- Each hit is checked against every later one, so all pairs of the four face it (spec 3.2). Heals
-- skip the guard (overheal).
local function AgreesWithAll(heal, hit, x, y, z)
    if heal then return true end
    if not Agree(hit.amount, hit.crit, x.amount, x.crit) then return false end
    if y and not Agree(hit.amount, hit.crit, y.amount, y.crit) then return false end

    return not z or Agree(hit.amount, hit.crit, z.amount, z.crit)
end

-- A set with timing error `err` and first hit at `at` beats the best so far (bestError, bestAt):
-- the smaller error wins, a tie goes to the later first hit.
local function Better(err, at, bestError, bestAt)
    return not bestError or err < bestError or (err == bestError and at > bestAt)
end

-- For the hit c = hits[third] and the period `gap`: the best loose hits (a, b) before it, as
-- indexes, and their timing error. b and a each sit one gap before the next within the slack;
-- each walk goes back from the newer hit and stops once the gap is too long. No gap is under GAP_MIN.
local function BestPair(hits, third, gap, new, heal)
    local c, slack = hits[third], Streams.Slack(gap)
    local low = math.max(gap - slack, GAP_MIN)
    local bestA, bestB, bestError
    for second = third - 1, 1, -1 do
        local b = hits[second]
        local bGap = c.at - b.at
        if bGap > gap + slack then break end
        if bGap >= low and AgreesWithAll(heal, b, c, new) then
            for first = second - 1, 1, -1 do
                local a = hits[first]
                local aGap = b.at - a.at
                if aGap > gap + slack then break end
                if aGap >= low and AgreesWithAll(heal, a, b, c, new) then
                    local err = math.abs(bGap - gap) + math.abs(aGap - gap)
                    if Better(err, a.at, bestError, bestA and hits[bestA].at) then
                        bestA, bestB, bestError = first, second, err
                    end
                end
            end
        end
    end

    return bestA, bestB, bestError
end

-- The loose hits (a, b, c) of `school` that the new hit completes, as indexes into `hits` (oldest
-- first): g = now - c is a period and BestPair finds a and b. The smallest timing error wins, a tie
-- goes to the latest a. The walk back from the newest hit stops once g is out of range.
local function FindBirth(hits, new, heal, now)
    local bestA, bestB, bestC, bestError
    for third = #hits, 1, -1 do
        local gap = now - hits[third].at
        if gap > PERIOD_MAX then break end
        if gap >= GAP_MIN and AgreesWithAll(heal, hits[third], new) then
            local first, second, err = BestPair(hits, third, gap, new, heal)
            if first and Better(err, hits[first].at, bestError, bestA and hits[bestA].at) then
                bestA, bestB, bestC, bestError = first, second, third, err
            end
        end
    end

    return bestA, bestB, bestC
end

-- Distinct castIDs of the key's casts inside the birth window, in cast order, with
-- their kinds. A plate stream's owners are dots and channels, a heal unit's are hots.
local function Owners(entry, birth, period, heal)
    local owners, ownerKind, ownerAt = {}, {}, {}
    for _, cast in ipairs(entry.casts) do
        local own = heal and cast.kind == "hot" or not heal and cast.kind ~= "hot"
        local inside = cast.at >= birth - WINDOW_FROM * period and cast.at <= birth - WINDOW_TO * period
        if own and inside and not ownerKind[cast.castID] then
            owners[#owners + 1] = cast.castID
            ownerKind[cast.castID] = cast.kind
            ownerAt[cast.castID] = cast.at
        end
    end

    return owners, ownerKind, ownerAt
end

-- A birth whose hits all land inside the key's newest own channel, from its start to `now` with no stop between, is
-- that channel's alone: a channel's ticks exist only while it channels. Void Torrent 263165 (3 s, 4 ticks, the first
-- in its cast frame) never had an owner: the birth window ends half a period before the first hit. Returns the owner
-- lists Owners returns, holding only that channel, else nil.
local function ChannelOwners(entry, first, now)
    local cast = channelCast
    if not cast or cast.at > first or (cast.stop and cast.stop < now) then return nil end
    for _, logged in ipairs(entry.casts) do
        if logged == cast then return { cast.castID }, { [cast.castID] = "channel" }, { [cast.castID] = cast.at } end
    end
end

-- Where a birth at `birth` with `period` really starts: loose hits of its school one period apart, two or more,
-- walked back from it are its first ticks, before a size step broke them off (too few for a stream). The owners
-- are the casts before that first tick. Run 20261025T181738Z: Haunt's damage-taken buff (+21 %) stepped Wither's
-- opener ticks 1451 -> 1753 past SIZE_GUARD one period after every Haunt cast, and the birth window taught Haunt
-- a DoT; Devouring Plague's ticks change size on a refresh the same way.
-- Each such tick is a normal hit that agrees with the other ticks and sits a buff's step (x1 to x1.5) from `amount`.
-- Returns that start and the ticks walked back (lead ticks, newest first), however few.
local function Start(entry, school, birth, period, amount)
    local slack, hits = Streams.Slack(period), entry.loose[school] or {}
    local function Step(hit)
        if hit.crit or not hit.amount or hit.amount <= 0 or not amount then return false end
        local ratio = math.max(hit.amount, amount) / math.min(hit.amount, amount)

        return ratio > 1 and ratio <= STEP_MAX
    end
    local at, lead = birth, {}
    while true do
        local found
        for _, hit in ipairs(hits) do
            local err = math.abs(at - period - hit.at)
            if err <= slack and Step(hit) and (not lead[1] or Agree(hit.amount, false, lead[1].amount, false))
                and (not found or err < math.abs(at - period - found.at)) then
                found = hit
            end
        end
        if not found then break end
        at, lead[#lead + 1] = found.at, found
    end

    return #lead >= 2 and at or birth, lead
end

-- Where a ramping DoT's birth at `birth` really starts, for its owners alone; `birth` when there is no ramp.
-- A DoT that ramps steps up on every tick: run lock3 F2, Agony 980 went 1353 -> 1803 -> 2706 -> 3247 -> 3787 -> 4328
-- (x1.14 to x1.50) with one gap 0.25 s off its 1.38 s period, and its stream was born only on the flat 4328s.
-- So the walk compares each tick with the newer tick it walked from (the birth's first hit to start): it agrees with
-- it, or sits a buff's step (x1 to x1.6) below it; a crit on its normal scale (over CRIT_MID). Sizes never step up
-- walking back. A walk that ends on a hit more than a step below its last tick may stop mid-ramp: run lock2 F1, Agony
-- 1503 -> 2705 (x1.8) left the start on 2705, whose window held Haunt and Darkglare. Then the birth keeps its own
-- window. The walked ticks stay loose and out of the record: noted, Agony's ramp on run lock2 changed the stream
-- groups, and the rhythm proc that teaches Agony there (F3, band 3006-4329) never formed.
local function RampStart(entry, school, birth, period, amount)
    local slack, hits = math.max(SLACK_MIN, RAMP_SHARE * period), entry.loose[school] or {}
    local newer = amount
    -- newer over the hit's normal-scale size, nil when either is missing.
    local function Ratio(hit)
        if not hit.amount or hit.amount <= 0 or not newer then return nil end

        return newer / (hit.crit and hit.amount / CRIT_MID or hit.amount)
    end
    local function Step(hit)
        local ratio = Ratio(hit)
        if not ratio then return false end

        return Agree(hit.amount, hit.crit, newer, false) or ratio > 1 and ratio <= RAMP_STEP
    end
    local at, walked, cut = birth, 0, false
    while true do
        local found
        cut = false
        for _, hit in ipairs(hits) do
            local err = math.abs(at - period - hit.at)
            if err <= slack and Step(hit) and (not found or err < math.abs(at - period - found.at)) then found = hit end
            if err <= slack and (Ratio(hit) or 0) > RAMP_STEP then cut = true end
        end
        if not found then break end
        at, walked = found.at, walked + 1
        if not found.crit then newer = found.amount end
    end

    return walked >= 2 and not cut and at or birth
end

-- Drops the stream with the oldest last hit while the key holds too many.
local function CapStreams(entry)
    while #entry.streams > STREAMS_MAX do
        local oldest = 1
        for position, stream in ipairs(entry.streams) do
            if stream.lastAt < entry.streams[oldest].lastAt then oldest = position end
        end
        table.remove(entry.streams, oldest)
    end
end

-- Public -----------------------------------------------------------------------------

-- An unclaimed hit. `kind` is "enemy" (plate) or "heal" (unit token). Only `shouldRecord` adds the hit to the
-- current fight's records. Returns the stream the hit extended or created, else nil.
function Streams.Feed(key, school, amount, flagText, kind, now, shouldRecord)
    if key == nil or not Plain(school) or type(school) ~= "number" then return end
    local entry = State(key)
    PruneCasts(entry, now)
    PruneLoose(entry, now)
    PruneDead(entry, now)
    local size, crit = Size(amount, flagText)
    local heal = kind == "heal"   -- overheal makes heal sizes meaningless
    if not heal then NoteFrame(key, school, now) end

    local stream, multiple = FindExtension(entry, school, size, crit, heal, now)
    if stream then
        stream.period = BLEND * stream.period + (1 - BLEND) * ((now - stream.lastAt) / multiple)
        stream.lastAt = now
        stream.count = stream.count + 1
        if not crit and size and size > 0 then stream.lastAmount = size end
        Note(stream, size, crit, shouldRecord)

        return stream
    end

    local hit = { at = now, amount = size, crit = crit }
    local hits = entry.loose[school] or {}
    entry.loose[school] = hits
    local first, second, third = FindBirth(hits, hit, heal, now)
    if first then
        local a, b, c = hits[first], hits[second], hits[third]
        local period = (now - a.at) / 3
        local amount = BirthAmount({ a, b, c, hit })
        local start, lead = a.at, {}
        if not heal then
            start, lead = Start(entry, school, a.at, period, amount)
            start = math.min(start, RampStart(entry, school, a.at, period, BirthAmount({ a })))
        end
        local owners, ownerKind, ownerAt
        if not heal then owners, ownerKind, ownerAt = ChannelOwners(entry, a.at, now) end
        if not owners then owners, ownerKind, ownerAt = Owners(entry, start, period, heal) end
        stream = {
            school = school, period = period, birth = a.at, lastAt = now, count = 4,
            lastAmount = BirthAmount({ a, b, c, hit }),
            hits = { a.at, b.at, c.at, now }, owners = owners, ownerKind = ownerKind, ownerAt = ownerAt, key = key,
            -- the birth's first three frames (the newest one's other plates may land after this hit) each hit
            -- WIDE_PLATES plates: a ground patch's ticks, which Learn gives no votes (Learn.OnBirth)
            wide = not heal and Wide(school, { a.at, b.at, c.at }),
            -- instance: set by Tracker when a live instance adopts the stream
        }
        table.remove(hits, third)
        table.remove(hits, second)
        table.remove(hits, first)
        entry.streams[#entry.streams + 1] = stream
        CapStreams(entry)
        for _, h in ipairs({ a, b, c, hit }) do Note(stream, h.amount, h.crit, shouldRecord) end
        -- The lead ticks are the stream's own first ticks: the record counts them (one is enough for the sum; the
        -- owners move only on two) and the loose list gives them up (Darkglare 205231's first beam, run lock2 F3).
        if #lead > 0 then
            for _, h in ipairs(lead) do Note(stream, h.amount, h.crit, shouldRecord) end
            entry.loose[school] = Filter(entry.loose[school], function(h)
                for _, tick in ipairs(lead) do
                    if tick == h then return false end
                end
                return true
            end)
        end
        ns.Learn.OnBirth(key, stream, now)

        return stream
    end

    hits[#hits + 1] = hit
    if #hits > LOOSE_CAP then table.remove(hits, 1) end
end

-- The player's cast, as Tracker saw it. kind: "dot" and "channel" key to the target
-- plate, "hot" to the heal unit. A channel's SUCCEEDED and CHANNEL_START events may
-- arrive in either order and must leave one entry and one Learn.OnCast.
function Streams.LogCast(key, castID, kind, now)
    if key == nil or not Plain(castID) or type(castID) ~= "number" then return end
    local entry = State(key)
    PruneCasts(entry, now)

    if kind ~= "channel" then
        for _, other in pairs(state) do
            for _, cast in ipairs(other.casts) do
                if cast.kind == "channel" and cast.at == now and cast.castID == castID then return end
            end
        end
        entry.casts[#entry.casts + 1] = { at = now, castID = castID, kind = kind }
        ns.Learn.OnCast(castID, now)

        return
    end

    -- A same-frame dot (this key) or hot (another key) entry is the same cast: the
    -- dot becomes the channel entry in place, the hot is removed. It already called
    -- Learn.OnCast, so this one does not.
    local swapped, removed = false, false
    for _, cast in ipairs(entry.casts) do
        if cast.kind == "dot" and cast.at == now and cast.castID == castID then
            cast.kind = "channel"
            swapped = true
            channelCast = cast
            break
        end
    end
    for otherKey, other in pairs(state) do
        if otherKey ~= key then
            local before = #other.casts
            other.casts = Filter(other.casts, function(cast)
                return not (cast.kind == "hot" and cast.at == now and cast.castID == castID)
            end)
            if #other.casts < before then removed = true end
        end
    end
    if not swapped then
        channelCast = { at = now, castID = castID, kind = "channel" }
        entry.casts[#entry.casts + 1] = channelCast
    end
    if not (swapped or removed) then ns.Learn.OnCast(castID, now) end
end

-- The player's channel stopped (CHANNEL_STOP): the newest channel owns no hit after `now`.
function Streams.StopChannel(now)
    if channelCast and not channelCast.stop then channelCast.stop = now end
end

-- The key's logged casts, oldest first (callers never mutate).
function Streams.CastLog(key)
    local entry = state[key]

    return entry and entry.casts or {}
end

-- The key's live streams after the death sweep.
function Streams.Live(key, now)
    local entry = state[key]
    if not entry then return {} end
    PruneDead(entry, now)

    return entry.streams
end

-- Keys that hold streams (as of their last Feed or Live call).
function Streams.Keys()
    local keys = {}
    for key, entry in pairs(state) do
        if #entry.streams > 0 then keys[#keys + 1] = key end
    end
    return keys
end

function Streams.Drop(key)
    if key ~= nil then state[key] = nil end
end

-- The key's state, removed from it (nil when it has none). Put hands it to another key:
-- the plate frame a hidden mob shows on again.
function Streams.Take(key)
    if key == nil then return nil end
    local entry = state[key]
    state[key] = nil

    return entry
end

function Streams.Put(key, entry)
    if key == nil or entry == nil then return end
    for _, stream in ipairs(entry.streams) do stream.key = key end
    state[key] = entry
end

function Streams.Reset() state, frames, frameTimes = {}, {}, {} end
