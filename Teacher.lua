-- Combat Text Icons: teacher. The addon draws hits from casts and learned data alone
-- and never touches the meter while you fight. This module keeps the per-fight tally
-- of what was drawn, one second after combat reads the meter's finished session (plain
-- per-spell rows), and judges each spell: the drawn total agrees with the meter,
-- overshoots it, or falls short. Agree and overshoot go to Fingerprints (two overshoots
-- in a row delete an entry); a short tally or an unpaired row changes nothing. The meter
-- may list a spell under another ID (Shoot 5019 is row Auto Shot 75): a saved
-- alias or a one-tally-one-row agreement pairs them. A cast is tallied and learned under
-- its base spell (Casts.Base): the meter files an override (Void Blast 450983) under its
-- base's row (Mind Blast 8092). The '?' hits one unlearned cast can explain are summed per
-- school; when a sum agrees with exactly one unpaired row (never one Procs tracks), those
-- hits become fingerprint samples. A hit whose frame also holds another cast has no sole cast, so
-- each cast's largest hit among those naming it a candidate is also summed against its own row.
-- Then the steady pass (Steady.lua) learns from '?' hits at a steady delay and size that no
-- sum explained, for unlearned bases and for the hits a learned base missed, bounded by the
-- meter row. A read that meets a
-- secret value or an error is skipped whole. The verdicts also unlearn DoTs, channels and
-- procs whose drawn total overshoots the meter or never pairs with a row, and go to the
-- Ledger, which attaches them and the read's outcome to the saved fight. A solo fight is also a crowd check: when
-- the wounds seen that may be yours (Teacher.Seen) fit the meter's rows the area is "clear" and
-- learning runs (the leftover '?' hits and still-open rows then go to Procs.Read, then to
-- Ground.Castless), else it
-- is "crowded" and that fight teaches nothing; seen below half the rows' total is "short" and
-- teaches nothing either. Each map keeps the verdict last decided on it, which comes back on entering the
-- world there (EnterWorld); a map with none starts "crowded". Mid-fight, seen wounds far past the best pace
-- a clear read measured make that fight crowded at once (Teacher.Seen), before its read. With /cti debug each
-- outcome logs TEACH lines.
-- Each fight's outcome, a read or a skip, ends with one Teacher.OnRead(Teacher.last) call
-- (Progress shows what the fight taught). A fight whose read meets the next fight is carried
-- into it (Carry) and has no outcome of its own. A fight whose newest session is the one read
-- last is judged on that session's growth since (Growth).

local _, ns = ...
local Meter, Fingerprints, Procs, Ledger, Streams = ns.Meter, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Streams
local Steady, Ground, Chain, Stack, Heals = ns.Steady, ns.Ground, ns.Chain, ns.Stack, ns.Heals

local Teacher = {}
ns.Teacher = Teacher

local READ_DELAY = 1 -- seconds after combat the session is read
-- The live crowd check: a fight's seen wounds past CROWD_PACE times the best pace a clear read measured (meter total
-- per second of fight) make it crowded at once, after its first CROWD_WAIT seconds (an opener burst is no crowd).
-- lock3 F3: the area was clear, then a world boss had strangers' wounds at 30x the best pace (clear fights peak below
-- 2.1x), and a learned proc drew 234195 against its row's 15682 before the read could turn the area crowded.
local CROWD_PACE, CROWD_WAIT = 4, 5
-- The DoT pass's slack: a stream records no tick before its birth, so a row may run past its school's ticks by the
-- fight's unseen damage, at most this share of the row. lock3 F1: Wither's streams held 91 % of its row.
local DOT_FIT = 0.1
-- A way pairs with a row of another ID only when its hits' delays after their casts span at most this (Ground's and
-- Chain's first-hit window). shaman6 F2: Earthquake's cand summed three castless 12-school hits at 0.10, 0.79 and
-- 1.29 s to row 157348 (20438 of 20408); its alias then drew 12 castless bursts as Earthquake in F3. The other
-- aliases of the fresh logs span at most 0.11 s, but hunter's 1264359 (hits 0.00 or 1.00 s after a cast) spans
-- 1.005 s in F1 and so learns each delay alone (F9, F11).
local ALIAS_SPREAD = 0.3

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

-- the open fight: { at, tally = { [spellID] = sum }, unknown = { entry, ... }, ticks = { tick, ... },
--   casts = { { spellID, base, at, plate }, ... }, streams = { [stream] = record }, seen = sum, live = this fight's
--   own seen (no carried fight's), crowded = the live crowd check fired, carried = seconds of fights carried in,
--   duration = seconds in combat (set at Finish), group, heals = { { size, at }, ... } on you, helps = { { spellID,
--   at }, ... } your helpful casts (for Heals.Learn) }
Teacher.fight = nil
Teacher.last = nil  -- latest read: { skip = reason } or { session, rows = { {...}, ... }, learned = { [castID] = hits }, area = "clear" | "crowded" | "group" | "short" }
Teacher.area = "crowded" -- the crowd check's state: "clear" or "crowded"; a read saves it with its map (SaveArea)
Teacher.OnRead = nil -- function(last), called once per fight when its outcome is final; Progress sets it

-- the spec's store; its `areas` = { [map ID] = "clear" | "crowded" } is each map's last read verdict, its `schools`
-- = { [school] = true } the schools clear reads saw (Teacher.OwnSchool), its `pace` the best meter total per second
-- of a clear read (the live crowd check's yardstick), its `paused` = { [spell ID] = true } the spells Pause holds back
local store = nil
local lastSession = nil -- ID of the session processed last
local lastRows = {}     -- that session's rows at its last read, by spell ID: { total, overkill }
local epoch = 0         -- counts Init calls: a read queued under an older one is dropped (a spec swap)
local jobs = {}         -- judgings waiting their turn, oldest first (sliced reads, below)
local judging = nil     -- the coroutine of the judging under way

local AREAS = { clear = true, crowded = true } -- a saved verdict's states

local function IsMap(map) return IsNumber(map) and map > 0 and map % 1 == 0 end
local function IsArea(state) return Plain(state) and AREAS[state] == true end

-- The map the player stands on as a plain positive integer, or nil.
local function CurrentMap()
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and IsMap(map) then return map end
end

-- Saved data is checked, never trusted: keeps each charDB.areas entry of a map ID and "clear" or "crowded", drops
-- the rest; an older save's single charDB.area = { state, map } joins them unless its map has its own; keeps each
-- charDB.schools entry of an integer school 1-127 marked true, each charDB.paused entry of a spell ID marked true;
-- keeps charDB.pace when it is a positive finite
-- number. The state itself waits for Teacher.EnterWorld
-- (a spec swap keeps it: the place did not change). charDB is a spec's store (Core's UseSpec): a swap drops the
-- judgings under way or waiting and the reads not fired yet, as a /reload does, so the spec before teaches nothing
-- into this one. The meter's last session (Growth) stays: it is the meter's, not the spec's.
function Teacher.Init(charDB)
    store, epoch, jobs, judging, Teacher.last = charDB, epoch + 1, {}, nil, nil
    local areas = {}
    if type(charDB.areas) == "table" then
        for map, state in pairs(charDB.areas) do
            if IsMap(map) and IsArea(state) then areas[map] = state end
        end
    end
    local old = charDB.area
    if type(old) == "table" and IsMap(old.map) and IsArea(old.state) and areas[old.map] == nil then
        areas[old.map] = old.state
    end
    charDB.area, charDB.areas = nil, next(areas) and areas or nil
    local schools = {}
    if type(charDB.schools) == "table" then
        for school, own in pairs(charDB.schools) do
            if IsNumber(school) and school >= 1 and school <= 127 and school % 1 == 0 and own == true then
                schools[school] = true
            end
        end
    end
    charDB.schools = next(schools) and schools or nil
    local paused = {}
    if type(charDB.paused) == "table" then
        for spellID, on in pairs(charDB.paused) do
            if IsNumber(spellID) and spellID > 0 and spellID % 1 == 0 and on == true then paused[spellID] = true end
        end
    end
    charDB.paused = next(paused) and paused or nil
    local pace = charDB.pace
    if not (IsNumber(pace) and pace > 0 and pace < math.huge) then charDB.pace = nil end
end

-- The player entered the world (login, reload, a loading screen): the map's own saved verdict, else "crowded".
function Teacher.EnterWorld()
    local map = CurrentMap()
    Teacher.area = map and store and store.areas and store.areas[map] or "crowded"
end

-- A read decided `area`: it is kept for the current map; with no map nothing is kept.
-- grug: no cap on maps; an entry is a few bytes and the game has a few thousand maps at most.
local function SaveArea(area)
    local map = CurrentMap()
    if not (store and map) then return end
    store.areas = store.areas or {}
    store.areas[map] = area
end

-- A group or crowded read would have dropped `spellID`: strangers' hits may be what it drew too much of, so its
-- learning is kept and it stops drawing (Teacher.Paused) until a solo fight starts on a clear map or a read is clear.
local function Pause(spellID)
    if not (store and IsNumber(spellID)) then return end
    store.paused = store.paused or {}
    store.paused[spellID] = true
    if ns.Debug then ns.Debug("TEACH pause %d", spellID) end
end

-- Whether `spellID` is paused (Pause): Core hides its hits.
function Teacher.Paused(spellID)
    return IsNumber(spellID) and store ~= nil and store.paused ~= nil and store.paused[spellID] == true
end

-- "agree" when the drawn total fits the meter's (overkill is damage the meter holds but the
-- number on screen may or may not show), "over" above it, "under" below it.
local function Judge(tally, total, overkill)
    local tol = math.max(1, total / 100)
    if tally < total - tol then return "under" end
    if tally > total + overkill + tol then return "over" end

    return "agree"
end

-- The newest session's ID from the sessions list, or nil and a skip reason.
local function NewestSession()
    local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
    if not ok then
        Meter.Disable(sessions) -- the error text

        return nil, "read failed"
    end
    if issecretvalue(sessions) then return nil, "secret" end
    if type(sessions) ~= "table" or #sessions == 0 then return nil, "no sessions" end

    local newest
    for _, session in ipairs(sessions) do
        if not (Plain(session) and type(session) == "table" and IsNumber(session.sessionID)) then
            return nil, "secret"
        end
        if not newest or session.sessionID > newest then newest = session.sessionID end
    end

    return newest
end

-- The player's rows of a session for `meterType` (damage done unless given) as
-- { { spellID, total, overkill }, ... }, one per spell, or nil and a skip reason. The meter may
-- list a spell in several rows: they are merged (total and overkill summed) at the first one's
-- place. Only a damage read that errors turns the meter off.
local function ReadRows(sessionID, meterType)
    meterType = meterType or Meter.DAMAGE_DONE
    local okGuid, guid = pcall(UnitGUID, "player")
    if not (okGuid and Plain(guid) and type(guid) == "string") then return nil, "read failed" end

    local ok, source = pcall(C_DamageMeter.GetCombatSessionSourceFromID, sessionID, meterType, guid)
    if not ok then
        if meterType == Meter.DAMAGE_DONE then Meter.Disable(source) end -- the error text

        return nil, "read failed"
    end
    if issecretvalue(source) then return nil, "secret" end
    if type(source) ~= "table" then return nil, "read failed" end

    local spells = source.combatSpells
    if issecretvalue(spells) then return nil, "secret" end
    if type(spells) ~= "table" then return nil, "read failed" end

    local rows, bySpell = {}, {}
    for _, row in ipairs(spells) do
        if not (Plain(row) and type(row) == "table") then return nil, "secret" end
        local overkill = row.overkillAmount
        if overkill == nil then overkill = 0 end
        if not (IsNumber(row.spellID) and IsNumber(row.totalAmount) and IsNumber(overkill)) then
            return nil, "secret"
        end
        local merged = bySpell[row.spellID]
        if merged then
            merged.total, merged.overkill = merged.total + row.totalAmount, merged.overkill + overkill
        else
            merged = { spellID = row.spellID, total = row.totalAmount, overkill = overkill }
            bySpell[row.spellID] = merged
            rows[#rows + 1] = merged
        end
    end

    return rows
end

-- A re-pull within a few seconds continues the meter session read last (probe6: fights 3 and 4
-- share session 4). The rows' growth since that read is this fight's: rows that grew, by how much.
local function Growth(rows)
    local grown = {}
    for _, row in ipairs(rows) do
        local before = lastRows[row.spellID]
        local total = row.total - (before and before.total or 0)
        if total > 0 then
            grown[#grown + 1] = { spellID = row.spellID, total = total,
                overkill = math.max(0, row.overkill - (before and before.overkill or 0)) }
        end
    end

    return grown
end

-- Judges one paired spell and tells Fingerprints: agree counts a fight, over is a strike. With `keep` (a group or
-- crowded read) the strike that would delete the fingerprint pauses it (Pause).
local function Apply(entry, castID, row, keep)
    entry.verdict = Judge(entry.tally, row.total, row.overkill)
    if entry.verdict == "agree" then
        Fingerprints.Agree(castID)
    elseif entry.verdict == "over" then
        if Fingerprints.Over(castID, keep) then Pause(castID) end
    end
end

-- Pairs the tally with the meter rows and applies the verdicts. Order: same spell ID; a saved
-- alias (meter row ID -> cast spell); a new alias when exactly one tally and exactly one
-- agreeing row are left. Rows with no tally stay "unpaired" and are returned in `open`, with
-- their place in `results`, for the learning pass. `keep`: see Apply.
local function Verdicts(tally, rows, keep)
    local results, open, paired = {}, {}, {}
    for _, row in ipairs(rows) do
        local drawn = tally[row.spellID]
        local entry = { spellID = row.spellID, meterID = row.spellID, tally = drawn or 0, meter = row.total }
        results[#results + 1] = entry
        if drawn then
            paired[row.spellID] = true
            Apply(entry, row.spellID, row, keep)
        else
            entry.verdict = "unpaired"
            open[#open + 1] = { row = row, index = #results }
        end
    end

    -- A saved alias names the cast spell a meter row belongs to. A learned proc owns its row, even
    -- against an alias saved before it was learned. A cast with several aliased rows open pairs first
    -- with one that agrees: shaman6 F2 aliased Voltaic Blaze 470057 to rows 157331 and 1259101, and F3's
    -- tally 546080 met 1259101 exactly yet was judged against 157331 (32944), striking a right fingerprint.
    for _, agreeing in ipairs({ true, false }) do
        for position = #open, 1, -1 do
            local row, index = open[position].row, open[position].index
            local castID = Fingerprints.Alias(row.spellID)
            if castID and tally[castID] and not paired[castID] and not Procs.Get(row.spellID)
                and (not agreeing or Judge(tally[castID], row.total, row.overkill) == "agree") then
                paired[castID] = true
                local entry = { spellID = castID, meterID = row.spellID, tally = tally[castID], meter = row.total }
                results[index] = entry
                Apply(entry, castID, row, keep)
                table.remove(open, position)
            end
        end
    end

    -- Drawn but absent from the meter: never counts for or against the fingerprint.
    local missing = {}
    for spellID in pairs(tally) do
        if not paired[spellID] then missing[#missing + 1] = spellID end
    end
    table.sort(missing)

    -- One spell left and one row that agrees with it: the meter lists that spell under its own ID.
    -- A learned spell is never given an alias: its trigger draws a DoT's ticks, so a
    -- row that agrees is the DoT's own, and the safety net strikes the trigger instead.
    -- A proc is its own row's ID, so it always pairs directly and never needs an alias. A row Procs
    -- tracks (a learned proc, or a candidate with a streak) is a proc's own, so it is no match.
    if #missing == 1 and not ns.Learn.Get(missing[1]) and not Procs.Get(missing[1]) then
        local castID = missing[1]
        local match, matches = nil, 0
        for position, item in ipairs(open) do
            if not Procs.Has(item.row.spellID) and Judge(tally[castID], item.row.total, item.row.overkill) == "agree" then
                match, matches = position, matches + 1
            end
        end
        if matches == 1 then
            local row, index = open[match].row, open[match].index
            Fingerprints.SetAlias(row.spellID, castID)
            local entry = { spellID = castID, meterID = row.spellID, tally = tally[castID], meter = row.total }
            results[index] = entry
            Apply(entry, castID, row, keep)
            table.remove(open, match)
            missing = {}
        end
    end

    for _, spellID in ipairs(missing) do
        results[#results + 1] = { spellID = spellID, meterID = spellID, tally = tally[spellID], meter = 0,
            verdict = "unpaired" }
    end

    return results, open
end

-- Groups the '?' hits that one unlearned cast can explain by school and base spell, in a
-- fixed order. A group { castID, school, sum, hits } also keeps `top`, the same for only each
-- cast's largest hit: the meter row holds one direct hit per cast, while a cast's window may
-- also take untracked DoT ticks on its target. A group is learned when one way's sum agrees with
-- exactly one still-unpaired row and that row agrees with no other group. A group also counts the
-- casts it covers (`covered`, distinct cast times) of all its cast's casts this fight (`casts`, over
-- every '?' hit of that cast, any school), for Pairs. A group whose normal-scale sizes span more than a
-- crit is `mixed`: other hits share its cast windows (Surging Totem's ~11K ticks among ~55K Lightning
-- Bolts summed within 1 % of the bolt's row, run 20261025T192458Z), so only its `top` may pair.
local function Groups(unknown)
    local byKey, list, castTimes = {}, {}, {}
    for _, hit in ipairs(unknown) do
        if hit.castID then
            castTimes[hit.castID] = castTimes[hit.castID] or {}
            castTimes[hit.castID][hit.castAt] = true
            local key = hit.castID .. ":" .. hit.school
            local group = byKey[key]
            if not group then
                group = { castID = hit.castID, school = hit.school, sum = 0, hits = {}, topOf = {} }
                byKey[key] = group
                list[#list + 1] = group
            end
            group.sum = group.sum + hit.amount
            group.hits[#group.hits + 1] = hit
            local top = group.topOf[hit.castAt]
            if not top or hit.amount > top.amount then group.topOf[hit.castAt] = hit end
        end
    end
    for _, group in ipairs(list) do
        group.covered, group.casts = 0, 0
        for _ in pairs(group.topOf) do group.covered = group.covered + 1 end
        for _ in pairs(castTimes[group.castID]) do group.casts = group.casts + 1 end
        local low, high
        for _, hit in ipairs(group.hits) do
            if hit.size then low, high = math.min(low or hit.size, hit.size), math.max(high or hit.size, hit.size) end
        end
        group.mixed = low ~= nil and high > low * Streams.CRIT_LO
        group.top = { castID = group.castID, sum = 0, hits = {} }
        for _, hit in ipairs(group.hits) do
            if group.topOf[hit.castAt] == hit then
                group.top.sum = group.top.sum + hit.amount
                group.top.hits[#group.top.hits + 1] = hit
            end
        end
    end
    table.sort(list, function(a, b)
        if a.castID ~= b.castID then return a.castID < b.castID end

        return a.school < b.school
    end)

    return list
end

-- Groups each base's '?' hits by school through their candidates (Casts.Candidates), not the sole
-- cast: a hit whose frame also holds another spell's cast has no sole cast, so its own cast's group misses it
-- (run lock F1: both Haunt 48181 hits shared a frame with Darkglare or Unstable Affliction, and the two summed
-- to its row exactly). A learned base takes only hits of its school in its padded band (Casts.InBand), the hits
-- it missed: run shaman5 learned Lava Burst 51505 on an AoE pack (~42K at 0.20-0.28 s), then a lone dummy's 69K
-- hit at 0.12 s met its row and was never learned. A hit goes to the newest candidate cast of each base; each
-- cast keeps its largest hit, plus its frame mates: the '?' hits of its school in its frame on other plates within
-- Streams.SIZE_GUARD of its size. Casts are logged on the target's plate only, so an AoE cast's other plates name no
-- cast: run shaman5 F1, rowless Voltaic Blaze 470057 hit 5 plates in its cast frame 3 times, and the 15 hits summed
-- to row 1259101 (789844 of 789850); the 1.4K hits of another spell in one of those frames are no mates.
-- A group { castID, school, cand = { castID, sum, hits, castOf, mates, area, covered, casts } } pairs only with the
-- cast's own row unless `area` (every counted cast had a mate; Pairs); `castOf[hit]` is the candidate that hit is
-- learned under, `mates[hit]` marks a mate (learned as a chain hop). Hits in `spent` are skipped.
local function CandidateGroups(unknown, spent)
    local byKey, list = {}, {}
    for _, hit in ipairs(unknown) do
        local newest = {}
        for _, candidate in ipairs(not spent[hit] and hit.candidates or {}) do
            local castID = candidate.castID
            local older = newest[castID]
            local fp = Fingerprints.IsLearned(castID) and Fingerprints.Get(castID)
            local fits = not fp or hit.school == fp.school and ns.Casts.InBand(castID, candidate.castSpell, hit.size)
            if fits and (not older or candidate.castAt > older.castAt) then
                newest[castID] = candidate
            end
        end
        for castID, candidate in pairs(newest) do
            local key = castID .. ":" .. hit.school
            local group = byKey[key]
            if not group then
                group = { castID = castID, school = hit.school, topOf = {}, castOf = {} }
                byKey[key] = group
                list[#list + 1] = group
            end
            local top = group.topOf[candidate.castAt]
            if not top or hit.amount > top.amount then
                group.topOf[candidate.castAt] = hit
                group.castOf[hit] = candidate
            end
        end
    end
    local frames = {} -- "at:school" -> the '?' hits of that school in that frame
    for _, hit in ipairs(unknown) do
        local key = hit.at .. ":" .. hit.school
        frames[key] = frames[key] or {}
        table.insert(frames[key], hit)
    end
    for _, group in ipairs(list) do
        local cand = { castID = group.castID, sum = 0, hits = {}, castOf = group.castOf, mates = {}, area = true,
            covered = 0, casts = 0 }
        group.cand = cand
        local function Take(hit)
            cand.sum = cand.sum + hit.amount
            cand.hits[#cand.hits + 1] = hit
        end
        for _, hit in ipairs(unknown) do
            local candidate = group.castOf[hit]
            if candidate and group.topOf[candidate.castAt] == hit then
                Take(hit)
                cand.covered = cand.covered + 1
                local mated = false
                for _, mate in ipairs(frames[hit.at .. ":" .. hit.school]) do
                    local like = mate.size and hit.size
                        and math.abs(mate.size - hit.size) <= Streams.SIZE_GUARD * math.max(mate.size, hit.size)
                    if like and mate.plate ~= hit.plate and not spent[mate] and not group.castOf[mate] then
                        group.castOf[mate], cand.mates[mate], mated = candidate, true, true
                        Take(mate)
                    end
                end
                cand.area = cand.area and mated
            end
        end
    end
    local castsOf = {}
    for _, hit in ipairs(unknown) do
        for _, candidate in ipairs(hit.candidates or {}) do
            castsOf[candidate.castID] = castsOf[candidate.castID] or {}
            castsOf[candidate.castID][candidate.castAt] = true
        end
    end
    for _, group in ipairs(list) do
        for _ in pairs(castsOf[group.castID] or {}) do group.cand.casts = group.cand.casts + 1 end
    end
    table.sort(list, function(a, b)
        if a.castID ~= b.castID then return a.castID < b.castID end

        return a.school < b.school
    end)

    return list
end

-- Whether the cast pass may pair `way` (a group, its `top`, or a `cand`) with a row: the sum agrees, and a
-- row of another ID belongs to no one else. It is not a row Procs tracks (a castless proc's own;
-- spec 3.1 Rev 4), the cast has no row of its own this session, and the row is not the own row
-- of another cast this fight (`owners.rows`, `owners.casts`; Rev 5). A cast's own row still pairs.
-- A `top` or a `cand` pairs only with the cast's own row: one largest hit often equals some other spell's
-- one-hit row by chance. An `area` cand (each cast's largest with its frame mates) is a whole sum and may.
-- A row of another ID also needs the way in at least half the cast's casts:
-- a castless proc's lone hit in one of many cast frames is no hit of the cast (run 153349Z: one holy
-- 2364 after 1 of 6 Void Volley casts equalled the proc's row 1260076). Its delays span at most ALIAS_SPREAD.
local function DelaySpan(way)
    local low, high = math.huge, -math.huge
    for _, hit in ipairs(way.hits) do
        local cast = way.castOf and way.castOf[hit] or hit
        local delay = hit.at - cast.castAt
        low, high = math.min(low, delay), math.max(high, delay)
    end

    return high - low
end

local function Pairs(group, way, row, owners)
    if way == group and group.mixed then return false end
    local whole = way == group or way.area
    if row.spellID ~= group.castID
        and (not whole or Procs.Has(row.spellID) or owners.rows[group.castID] or owners.casts[row.spellID]
            or 2 * way.covered < way.casts or DelaySpan(way) > ALIAS_SPREAD) then
        return false
    end

    return Judge(way.sum, row.total, row.overkill) == "agree"
end

-- The IDs that own a meter row this session and the cast IDs of this fight's groups.
local function Owners(groups, rows)
    local owners = { rows = {}, casts = {} }
    for _, row in ipairs(rows) do owners.rows[row.spellID] = true end
    for _, group in ipairs(groups) do owners.casts[group.castID] = true end

    return owners
end

-- One pairing pass over the rows and groups `seen` does not hold yet: `WayOf(group)` is the
-- group's sum to try. A row and a group that agree only with each other are learned; every row
-- and group that agreed with anything goes into `seen`, so a later pass never revisits them.
local function Pass(groups, open, owners, WayOf, seen, results, learned, rewritten)
    local groupsOf, rowsOf = {}, {}
    for position, item in ipairs(open) do
        for groupIndex, group in ipairs(groups) do
            if not seen.rows[position] and not seen.groups[groupIndex]
                and Pairs(group, WayOf(group), item.row, owners) then
                groupsOf[position] = (groupsOf[position] or 0) + 1
                rowsOf[groupIndex] = (rowsOf[groupIndex] or 0) + 1
            end
        end
    end

    for position, item in ipairs(open) do
        for groupIndex, group in ipairs(groups) do
            local row, way = item.row, WayOf(group)
            if groupsOf[position] == 1 and rowsOf[groupIndex] == 1 and Pairs(group, way, row, owners) then
                for _, hit in ipairs(way.hits) do
                    local cast = way.castOf and way.castOf[hit] or { castAt = hit.castAt, castSpell = hit.castSpell }
                    local hops = way.mates and way.mates[hit] and 2 or 1
                    Fingerprints.Add(group.castID, { school = hit.school, delay = hit.at - cast.castAt,
                        castAt = cast.castAt, hops = hops, spell = cast.castSpell, size = hit.size })
                end
                if row.spellID ~= group.castID then Fingerprints.SetAlias(row.spellID, group.castID) end
                learned[#learned + 1] = way
                rewritten[position] = true
                results[item.index] = { spellID = group.castID, meterID = row.spellID, tally = way.sum,
                    meter = row.total, verdict = "agree" }
            end
        end
    end
    for position in pairs(groupsOf) do seen.rows[position] = true end
    for groupIndex in pairs(rowsOf) do seen.groups[groupIndex] = true end
end

-- The DoT pass: a spell cast this fight whose own row stayed open, and one school with tick streams that row
-- bounds both ways: the school's '?' hits no learned way took sum to at most the row, and the row to at most those
-- hits and to at most its stream ticks (no rhythm proc's), each plus the fight's unseen damage (meter total - seen)
-- capped at DOT_FIT of the row. Each must be the only one of the other. The spell is learned as that school's DoT at
-- the rhythm most of the stream ticks keep (Procs.PeriodNear), its votes set aside, and a second series in those
-- streams as the row's rhythm proc (SecondSeries).
-- Run lock3 F1: Wither 445468 was cast once, Seed of Corruption spread it to 5 plates and no birth window held the
-- cast, so it had no vote; it voted only in F5, after 1.4M of its 2.2M had gone by as '?'. Its row (772071) held
-- every school-36 '?' hit (740626, 96 %) and its streams (704829, 91 %): 144 ticks at 1.32-1.51 s, 57 at ~1.0 s under
-- Malevolence 442726. Either sum alone fits rows by chance. Streams: paladin F2 holy 136937 against Judgment 20271's
-- 139520, holy '?' in the millions; shaman2 F1 fire 572431 against Flame Shock 188389 with 16473 of fire left '?'
-- (learned at 4.96 s it cost shaman2 3.3 pt). '?' hits: hunter F10 physical 95314 against 466930, streams 23451.
local function DotPeriod(records)
    table.sort(records, function(a, b) return a.period < b.period end)
    local best, most = nil, 0
    for _, anchor in ipairs(records) do
        local ticks, weighted = 0, 0
        for _, rec in ipairs(records) do
            if Procs.PeriodNear(anchor.period, rec.period) then
                ticks, weighted = ticks + rec.n, weighted + rec.n * rec.period
            end
        end
        if ticks > most then best, most = weighted / ticks, ticks end
    end

    return best
end

-- The DoT pass's second series: the same bounds that make a school's streams one row's make every series in them
-- that row's. Run lock3 F1: Wither 445468's 57 ticks at ~1.0 s (4060-5637, its stacks collapsing after Malevolence
-- 442726) beside its own 1445-2171 ticks at 1.32-1.51 s; in F2 such ticks went by as '?' (319424 of its 666459 row).
-- Returns the period, lo and hi of the records the DoT's `period` does not keep (Procs.PeriodNear), clustered as
-- DotPeriod clusters them, with the most ticks, when that cluster spans two streams or more and its normal sizes
-- miss the DoT's band (else it is the DoT's own ticks, a stream that skipped some); else nil.
local function SecondSeries(records, period)
    local ownLo, ownHi, others = math.huge, 0, {}
    for _, rec in ipairs(records) do
        if Procs.PeriodNear(period, rec.period) then
            ownLo, ownHi = math.min(ownLo, rec.lo or ownLo), math.max(ownHi, rec.hi or ownHi)
        elseif rec.lo then
            others[#others + 1] = rec
        end
    end
    local best, most = nil, 0
    for _, anchor in ipairs(others) do
        local series = { ticks = 0, weighted = 0, streams = 0, lo = anchor.lo, hi = anchor.hi }
        for _, rec in ipairs(others) do
            if Procs.PeriodNear(anchor.period, rec.period) then
                series.ticks, series.weighted = series.ticks + rec.n, series.weighted + rec.n * rec.period
                series.streams = series.streams + 1
                series.lo, series.hi = math.min(series.lo, rec.lo), math.max(series.hi, rec.hi)
            end
        end
        if series.ticks > most then best, most = series, series.ticks end
    end
    if not best or best.streams < 2 or (best.lo <= ownHi and best.hi >= ownLo) then return nil end

    return best.weighted / best.ticks, best.lo, best.hi
end

local function DotPass(run, rows, open, rewritten, results, learned)
    local schools, order = {}, {}
    local function School(id)
        local school = schools[id]
        if not school then
            school = { sum = 0, unknown = 0, records = {} }
            schools[id], order[#order + 1] = school, id
        end

        return school
    end
    for stream, rec in pairs(run.streams or {}) do
        if not stream.procID and rec.n > 0 then
            local school = School(rec.school)
            school.sum = school.sum + rec.sum
            school.records[#school.records + 1] = { period = stream.period, n = rec.n, lo = rec.lo, hi = rec.hi }
        end
    end
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    for _, hit in ipairs(run.unknown) do
        if not spent[hit] and schools[hit.school] then
            schools[hit.school].unknown = schools[hit.school].unknown + hit.amount
        end
    end
    table.sort(order)
    local cast, total = {}, 0
    for _, item in ipairs(run.casts or {}) do cast[item.spellID], cast[item.base] = true, true end
    for _, row in ipairs(rows) do total = total + row.total end
    local unseen = math.max(0, total - run.seen)
    local function Fits(position, school)
        local row, id = open[position].row, open[position].row.spellID
        local free = not rewritten[position] and cast[id] and not ns.Learn.Get(id) and not Procs.Has(id)
            and not Fingerprints.IsLearned(id) and not Fingerprints.IsAliasTarget(id)
        local tol = math.max(1, row.total / 100)

        return free and school.unknown <= row.total + row.overkill + tol
            and row.total <= math.min(school.sum, school.unknown) + math.min(unseen, DOT_FIT * row.total) + tol
    end
    local schoolsOf, rowsOf = {}, {}
    for position in ipairs(open) do
        for _, id in ipairs(order) do
            if Fits(position, schools[id]) then
                schoolsOf[position] = (schoolsOf[position] or 0) + 1
                rowsOf[id] = (rowsOf[id] or 0) + 1
            end
        end
    end
    for position, item in ipairs(open) do
        for _, id in ipairs(order) do
            local school, row = schools[id], item.row
            if schoolsOf[position] == 1 and rowsOf[id] == 1 and Fits(position, school) then
                local raw = DotPeriod(school.records)
                local period = raw * (1 + (ns.Learn.Haste() or 0) / 100)
                if ns.Learn.Teach(row.spellID, id, period) then
                    rewritten[position] = true
                    results[item.index] = { spellID = row.spellID, meterID = row.spellID, tally = school.sum,
                        meter = row.total, verdict = "under" }
                    -- its second series draws as a rhythm proc of the row (Procs.NameStream)
                    local rate, lo, hi = SecondSeries(school.records, raw)
                    if rate then Procs.Teach(row.spellID, id, lo, hi, rate, run.at) end
                    if rate and ns.Debug then
                        ns.Debug("TEACH dot series %d school=%d p=%.2f band=%d-%d", row.spellID, id, rate, lo, hi)
                    end
                end
                if ns.Debug then
                    ns.Debug("TEACH dot %d school=%d streams=%.0f unknown=%.0f period=%.3f -> %s", row.spellID, id,
                        school.sum, school.unknown, period, rewritten[position] and "learned" or "refused")
                end
            end
        end
    end
end

-- Learning from '?' hits (spec 6.5): rewrites the learned rows of `results` against the
-- session's meter `rows`. Whole sums pair first; a row and a group that no whole sum agreed
-- with then try `top`; then each cast's largest hit by candidates (CandidateGroups) tries the cast's
-- own row; then the steady pass (Steady.lua) learns from steady hits no sum explained; then the ground pass
-- (Ground.lua) learns a rowless cast's ticks on many plates, bounded by one open row; then the chain pass (Chain.lua)
-- learns a cast's hops from plate to plate under its own open row, before the DoT pass: a proven chain is direct hits,
-- so they leave the school's '?' sum the DoT pass bounds; then the DoT pass learns a cast's DoT from its school's
-- streams, bounded by its own open row; last, the stack pass (Stack.lua) learns a stacking DoT's ticks on its cast's
-- plate under its own open row.
-- A fingerprint learned under a learned DoT of another school drops the DoT: the cast's own hits own its row, so
-- the DoT's draws were other spells' (a stale save's Nature DoT under Lava Burst 51505 drew Surging Totem's ticks).
-- Returns the learned ways ({ castID, sum, hits }) and the set of `open` positions rewritten.
local function Learn(run, results, open, rows)
    local groups = Groups(run.unknown)
    local owners = Owners(groups, rows)
    local seen, learned, rewritten = { rows = {}, groups = {} }, {}, {}
    Pass(groups, open, owners, function(group) return group end, seen, results, learned, rewritten)
    Pass(groups, open, owners, function(group) return group.top end, seen, results, learned, rewritten)
    Teacher.Yield()
    local spent = {}
    for _, way in ipairs(learned) do
        for _, hit in ipairs(way.hits) do spent[hit] = true end
    end
    Pass(CandidateGroups(run.unknown, spent), open, owners, function(group) return group.cand end,
        { rows = seen.rows, groups = {} }, results, learned, rewritten)
    Teacher.Yield()
    for _, way in ipairs(Steady.Learn(run, rows, learned)) do learned[#learned + 1] = way end
    Teacher.Yield()
    for _, way in ipairs(Ground.Learn(run, rows, open, rewritten, results, learned)) do learned[#learned + 1] = way end
    Teacher.Yield()
    for _, way in ipairs(Chain.Learn(run, open, rewritten, results, learned)) do learned[#learned + 1] = way end
    Teacher.Yield()
    DotPass(run, rows, open, rewritten, results, learned)
    Teacher.Yield()
    for _, way in ipairs(Stack.Learn(run, open, rewritten, results, learned)) do learned[#learned + 1] = way end
    for _, way in ipairs(learned) do
        local dot, fp = ns.Learn.Get(way.castID), Fingerprints.Get(way.castID)
        if dot and fp and fp.learned and fp.school ~= dot.school then ns.Learn.Drop(way.castID) end
    end

    return learned, rewritten
end

-- The '?' hits no learned way took (a `top` leaves its group's other hits). Groups are keyed
-- castID:school, so a cast's other-school group stays (spec 3.1).
local function Leftover(unknown, learnedGroups)
    local spent = {}
    for _, group in ipairs(learnedGroups) do
        for _, hit in ipairs(group.hits) do spent[hit] = true end
    end

    local hits = {}
    for _, hit in ipairs(unknown) do
        if not spent[hit] then hits[#hits + 1] = hit end
    end

    return hits
end

-- The open rows the cast pass did not rewrite.
local function StillOpen(open, rewritten)
    local rows = {}
    for position, item in ipairs(open) do
        if not rewritten[position] then rows[#rows + 1] = item end
    end

    return rows
end

-- One TEACH debug line per outcome: the skip reason, or each spell's tally, meter and verdict,
-- plus `row=<meter ID>` when the spell was paired with a row of another ID (an alias).
local function Report(last)
    if not ns.Debug then return end
    if last.skip then
        ns.Debug("TEACH skip %s", last.skip)
        return
    end
    for _, row in ipairs(last.rows) do
        local alias = row.meterID ~= row.spellID and (" row=" .. row.meterID) or ""
        ns.Debug("TEACH %s tally=%s meter=%s verdict=%s%s", row.spellID, row.tally, row.meter, row.verdict, alias)
    end
end

-- grug: temporary probe for '?' heals (gap 3): /cti debug logs the session's healing-done rows (`rows`, else the
-- skip `reason`) after the damage rows, to set against the fight's HEAL lines (does a heal's amount include
-- overheal?). tests/heals.lua reads these lines as its logs' heal rows.
local function ReportHeals(rows, reason)
    if not ns.Debug then return end
    if not rows then
        ns.Debug("TEACH heal skip %s", reason)
        return
    end
    for _, row in ipairs(rows) do ns.Debug("TEACH heal %s meter=%s over=%s", row.spellID, row.total, row.overkill) end
end

-- The fight's outcome `last` is final: it becomes Teacher.last, is reported and goes to Teacher.OnRead.
local function Done(last)
    Teacher.last = last
    Report(last)
    if Teacher.OnRead then Teacher.OnRead(last) end
end

-- The fight started at `at` is not read for `reason`: the Ledger keeps it as skipped.
local function Skipped(at, reason)
    Ledger.SetOutcome(at, "skipped")
    Done({ skip = reason })
end

-- The crowd check: "group" (the state is kept) for a fight that started grouped or saw a wound while
-- grouped; the group state at read time does not count (priest3: joining the dungeon group 2 s after a
-- solo dummy fight lost that fight's whole read); "short" (the state is kept)
-- when the meter's total is 0, or the wounds seen are below half of it, so the session holds damage this fight
-- never saw (run 102226Z: 20306 seen against 4211377); else "clear" when the wounds
-- seen fit the meter's rows (their total plus overkill, within the judge's tolerance), else
-- "crowded". Also returns the rows' total.
local function CrowdCheck(run, rows)
    local total, overkill = 0, 0
    for _, row in ipairs(rows) do
        total, overkill = total + row.total, overkill + row.overkill
    end

    if run.group then return "group", total end
    -- an empty read tells nothing about the area (shamanally2: a 3 s blip after a crowded read saved "clear")
    if total <= 0 or run.seen < total / 2 then return "short", total end

    local tolerance = math.max(1, total / 100)
    local fits = run.seen <= total + overkill + tolerance

    return fits and "clear" or "crowded", total
end

-- Safety net (spec 3.3): learned spells and procs face the meter on every read. A drawn
-- total (tally > 0) that overshoots drops the spell, two unpaired reads in a row drop it,
-- a paired read (agree or under) resets the count. Undrawn spells change nothing here (a learned
-- one cast this fight with no row is struck by Learn.RowsRead). An ID both stores know is judged by both.
-- With `keep` (a group or crowded read: strangers' hits may be the overshoot) a drop is a pause (Pause) instead.
local function SafetyNet(results, keep)
    for _, entry in ipairs(results) do
        for _, store in ipairs({ ns.Learn, Procs }) do
            if entry.tally > 0 and store.Get(entry.spellID) then
                if entry.verdict == "over" then
                    if keep then Pause(entry.spellID) else store.Drop(entry.spellID) end
                elseif entry.verdict == "unpaired" then
                    if store.Unpaired(entry.spellID, keep) then Pause(entry.spellID) end
                else
                    store.Paired(entry.spellID)
                end
            end
        end
    end
end

-- A quick re-pull: the read met the next fight (in combat the meter answers secret), and the
-- game extends one meter session over both (run 102226Z: the next read held this fight's rows).
-- This fight's tally, seen, '?' hits, ticks and stream records join the open one, oldest first, and are
-- judged at its read; this fight gets no outcome of its own.
local function Carry(run, into)
    for spellID, amount in pairs(run.tally) do into.tally[spellID] = (into.tally[spellID] or 0) + amount end
    for index, hit in ipairs(run.unknown) do table.insert(into.unknown, index, hit) end
    for index, tick in ipairs(run.ticks or {}) do table.insert(into.ticks, index, tick) end
    for index, cast in ipairs(run.casts or {}) do table.insert(into.casts, index, cast) end
    for index, heal in ipairs(run.heals or {}) do table.insert(into.heals, index, heal) end
    for index, help in ipairs(run.helps or {}) do table.insert(into.helps, index, help) end
    into.seen = into.seen + run.seen
    for school, sum in pairs(run.schools or {}) do into.schools[school] = (into.schools[school] or 0) + sum end
    into.carried = (into.carried or 0) + (run.duration or 0)
    into.streams = Streams.JoinFight(into.streams or {}, run.streams or {})
    into.group = into.group or run.group
    if ns.Debug then ns.Debug("TEACH carry %d hits seen=%d", #run.unknown, math.floor(run.seen)) end
end

-- grug: session probe (2026-10-25): the read session's listed duration ("again" when only its
-- growth is judged), to confirm in game that a quick re-pull's session spans both fights. Remove
-- once confirmed.
local function ReportSession(sessionID, again)
    local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
    if not (ok and Plain(sessions) and type(sessions) == "table") then return end
    for _, session in ipairs(sessions) do
        if Plain(session) and type(session) == "table" and session.sessionID == sessionID then
            local duration = session.durationSeconds
            ns.Debug("TEACH session %d dur=%s%s", sessionID, issecretvalue(duration) and "secret" or tostring(duration),
                again and " again" or "")
        end
    end
end

-- A clear read's meter `total` over `duration` seconds of combat raises the saved pace when it beats it.
local function SavePace(total, duration)
    if not (store and IsNumber(duration) and duration > 0) then return end
    local pace = total / duration
    if not store.pace or pace > store.pace then store.pace = pace end
end

-- A clear read's seen `schools` ({ [school] = sum }) are yours: each past 1 % of the meter's `total` is recorded
-- (a clear read lets strangers' wounds reach that tolerance, no more).
local function SaveSchools(schools, total)
    if not store then return end
    for school, sum in pairs(schools or {}) do
        if sum > total / 100 then
            store.schools = store.schools or {}
            store.schools[school] = true
        end
    end
end

-- Sliced reads. BugSack 2026-10-28: "script ran too long" twice after a fight, in Stack.lua's Stacks and
-- Stack.Multiple under one read's Stack.Learn (7 casts on one plate, life 27 of 2-30): the read ran every pass in one
-- C_Timer callback, and WoW stops a script that runs past its time limit; the replays' slowest read took 5.9 s of Lua
-- (druid fight 11). So a fight's judging runs in a coroutine that yields at its hot loops (Teacher.Yield) once
-- SLICE_MS of the frame are spent, and resumes on the next frame. One judging runs at a time, in the order the
-- fights' reads fired. A judging that has yielded waits while a fight is open (Teacher.fight) and goes on when it
-- ends (Teacher.Finish), so what is learned never changes mid-fight. The meter is still read when the read fires: a
-- read that meets the next fight still carries into it, and one judged late keeps its own session's rows. A /reload
-- or a spec swap (Teacher.Init) drops a judging under way: what its finished passes taught stays, the rest of that
-- fight teaches nothing and it has no outcome.
local SLICE_MS = 10
local sliceEnd = nil   -- the debugprofilestop() time past which the running slice yields
local resuming = false -- a slice waits on C_Timer.After(0)

-- Yields the judging under way once its slice is spent; else does nothing (outside a judging, or with no
-- debugprofilestop, as in the test harness unless a check sets one).
function Teacher.Yield()
    local clock = debugprofilestop
    if clock and judging and coroutine.running() == judging and clock() >= sliceEnd then coroutine.yield() end
end

local Slice

-- Queues a slice on the next frame while a judging is under way or waiting.
local function Later()
    if resuming or not (judging or jobs[1]) then return end
    resuming = pcall(C_Timer.After, 0, function()
        resuming = false
        Slice()
    end)
end

-- Runs one slice: the judging under way goes on unless a fight is open, else the oldest waiting one starts (with
-- `now`, even mid-fight, as a read did before). An error ends that judging and goes on to the caller.
function Slice(now)
    if not judging then
        if not jobs[1] or (Teacher.fight and not now) then return end
        judging = coroutine.create(table.remove(jobs, 1))
    elseif Teacher.fight then
        return
    end
    local clock = debugprofilestop
    sliceEnd = clock and clock() + SLICE_MS
    local thread = judging
    local ok, problem = coroutine.resume(thread)
    if coroutine.status(thread) == "dead" then judging = nil end
    Later()
    local trace = debug and debug.traceback -- the judging's own stack, for BugSack
    if not ok then error(trace and trace(thread, tostring(problem)) or problem, 0) end
end

-- Queues a judging; with none under way or waiting it starts at once.
local function Judge(job)
    jobs[#jobs + 1] = job
    if not judging and #jobs == 1 then Slice(true) end
end

-- One fight's judging of the session read for it: `sessionID` and its `rows`, else the skip `reason`.
local function Judging(run, sessionID, rows, reason)
    if not rows then
        Skipped(run.at, reason)
        return
    end

    local full, again = rows, sessionID == lastSession
    if again then rows = Growth(full) end
    if #rows == 0 and again then
        -- leftover ticks re-entered combat for a moment and dealt nothing the meter counts
        Ledger.Drop(run.at)
        Done({ skip = "duplicate session" })
        return
    end
    lastSession, lastRows = sessionID, {}
    for _, row in ipairs(full) do lastRows[row.spellID] = { total = row.total, overkill = row.overkill } end
    ns.Casts.NoteRows(full) -- the next fight's casts key by the meter's own rows
    ns.Casts.Rekey(run.unknown, full) -- and so do this fight's unexplained hits
    ns.Learn.RowsRead(full, run.at, run.tally) -- this fight's casts with no row: no dot votes; learned, a strike
    if ns.Debug then
        ReportSession(sessionID, again)
        -- grug: override probe (2026-10-25): what each meter row's spell turns into right now.
        for _, row in ipairs(rows) do
            local get = C_Spell.GetOverrideSpell
            local ok, override = false, nil
            if get then ok, override = pcall(get, row.spellID) end
            ns.Debug("TEACH row %d total=%d overkill=%d override=%s", row.spellID, math.floor(row.total), math.floor(row.overkill),
                not get and "none" or not ok and "err" or issecretvalue(override) and "secret" or tostring(override))
        end
    end
    local area, total = CrowdCheck(run, rows)
    local keep = area == "group" or area == "crowded"
    -- the healing-done rows, only a list of your heals' IDs (Heals.lua): for a clear read's Heals.Learn and the probe
    local healRows, healReason
    if area == "clear" or ns.Debug then healRows, healReason = ReadRows(sessionID, Meter.HEALING_DONE) end
    local results, open = Verdicts(run.tally, rows, keep)
    SafetyNet(results, keep)
    -- a fight that ends while this judging waits clears Teacher.last: this one keeps its own until Done
    local last = { session = sessionID, rows = results, learned = {} }
    Teacher.last = last

    if area ~= "group" and area ~= "short" then
        Teacher.area = area
        SaveArea(area)
    end
    if area == "clear" and store then store.paused = nil end
    last.area = area
    Ledger.SetOutcome(run.at, area, total)
    if ns.Debug then
        ns.Debug("TEACH clean seen=%d meter=%d -> %s", math.floor(run.seen), math.floor(total), area)
    end
    if area == "clear" then
        SavePace(total, run.duration)
        SaveSchools(run.schools, total)
        local learnedGroups, rewritten = Learn(run, results, open, rows)
        for _, group in ipairs(learnedGroups) do last.learned[group.castID] = #group.hits end
        local hits, openRows = Leftover(run.unknown, learnedGroups), StillOpen(open, rewritten)
        Teacher.Yield()
        Procs.Read(hits, openRows, results, rows, run.at, run.ticks, run.streams)
        Teacher.Yield()
        Ground.Castless(run, hits, openRows, rows, results)
        if healRows then Heals.Learn(run.heals, run.helps, healRows, run.duration) end
    end
    Ledger.SetVerdicts(last.rows, run.at)
    Done(last)
    ReportHeals(healRows, healReason)
end

-- The timer callback of one fight: read the newest session now, then judge it (Judge).
local function Read(run)
    local sessionID, reason = NewestSession()
    local rows
    if sessionID then rows, reason = ReadRows(sessionID) end
    if not rows and reason == "secret" and Teacher.fight then
        Carry(run, Teacher.fight)
        return
    end
    Judge(function() Judging(run, sessionID, rows, reason) end)
end

-- Combat began: open a fight (an unfinished one is replaced). A solo fight on a clear map ends every pause: its
-- read judges those spells again.
function Teacher.Start(now, group)
    if store and not group and Teacher.area == "clear" then store.paused = nil end
    local streams = Streams.NewFight()
    Teacher.fight = { at = now, tally = {}, unknown = {}, ticks = {}, casts = {}, seen = 0, live = 0, schools = {},
        group = group, streams = streams, heals = {}, helps = {} }
end

-- A wound landed while the player was grouped: the fight's read will not learn.
function Teacher.Grouped()
    if Teacher.fight then Teacher.fight.group = true end
end

-- A wound of this size and `school` that may be yours was seen at `now`, drawn or not (Core's Wound decides which
-- count). Past the live crowd check's bound (CROWD_PACE) the fight is crowded until it ends.
function Teacher.Seen(amount, now, school)
    local fight = Teacher.fight
    if not (fight and IsNumber(amount)) then return end
    fight.seen, fight.live = fight.seen + amount, fight.live + amount
    if IsNumber(school) then fight.schools[school] = (fight.schools[school] or 0) + amount end
    local pace = store and store.pace
    if fight.crowded or not (pace and IsNumber(now)) then return end
    if fight.live > CROWD_PACE * pace * math.max(now - fight.at, CROWD_WAIT) then
        fight.crowded = true
        if ns.Debug then ns.Debug("TEACH crowd live seen=%d pace=%d", math.floor(fight.live), math.floor(pace)) end
    end
end

-- A clear read saw wounds of `school`, or none has recorded any school yet (nothing to tell yours from others').
function Teacher.OwnSchool(school)
    local schools = store and store.schools
    if not schools then return true end

    return IsNumber(school) and schools[school] == true
end

-- The last solo fight's wounds fit the meter, the meter is readable, and the open fight is not crowded.
function Teacher.AreaClear()
    local fight = Teacher.fight
    return Teacher.area == "clear" and Meter.Available() and not (fight and fight.crowded)
end

-- A harmful cast of the player or the pet (`base` is Casts.Base of `spellID`), for the ground pass; `plate` (the
-- cast's, nil when none) for the stack pass.
function Teacher.Cast(spellID, base, now, plate)
    local fight = Teacher.fight
    if not (fight and IsNumber(spellID) and IsNumber(base) and IsNumber(now)) then return end
    fight.casts[#fight.casts + 1] = { spellID = spellID, base = base, at = now, plate = plate }
end

-- A heal of `amount` (`flagText` its crit flag) landed on you, drawn or not: Heals.Learn takes the largest per stamp.
function Teacher.Healed(amount, flagText, now)
    local fight = Teacher.fight
    local size = Streams.NormalAmount(amount, flagText)
    if not (fight and size and IsNumber(now)) then return end
    fight.heals[#fight.heals + 1] = { size = size, at = now }
end

-- A helpful cast of yours, for Heals.Learn.
function Teacher.Helped(spellID, now)
    local fight = Teacher.fight
    if not (fight and IsNumber(spellID) and IsNumber(now)) then return end
    fight.helps[#fight.helps + 1] = { spellID = spellID, at = now }
end

-- A hit was drawn with this spell's icon.
function Teacher.Drawn(spellID, amount)
    local fight = Teacher.fight
    if not (fight and IsNumber(spellID) and IsNumber(amount)) then return end
    fight.tally[spellID] = (fight.tally[spellID] or 0) + amount
end

-- A hit a learned DoT drew: its votes named it, not the meter, so Procs.Read also sums it with its school's '?' hits.
function Teacher.Ticked(school, amount, flagText)
    local fight = Teacher.fight
    if not (fight and IsNumber(school) and IsNumber(amount)) then return end
    fight.ticks[#fight.ticks + 1] = { school = school, amount = amount, crit = Procs.Crit(flagText) }
end

-- A solo unexplained hit on a mob fighting you (drawn '?', or hidden while the meter is off or
-- the area is crowded). `cast` is Casts.SoleCast at the hit's time. `castID` (the cast's base
-- spell) / `castAt` name it when it is unlearned, for the teacher to learn from after the
-- fight. `crit` (from the hit's flag text, as Streams.Size) feeds Procs: true, false, or nil
-- when the flag is unknown. `size` is the hit's normal-scale size for the cast's band. `candidates`
-- (Casts.Candidates) are every cast that may have made the hit, for the steady pass.
function Teacher.Unknown(plate, school, amount, now, cast, flagText, candidates)
    local fight = Teacher.fight
    if not (fight and plate ~= nil and IsNumber(school) and IsNumber(amount) and IsNumber(now)) then return end

    local entry = { school = school, amount = amount, at = now, plate = plate, crit = Procs.Crit(flagText),
        size = Streams.NormalAmount(amount, flagText), candidates = candidates }
    if cast and not Fingerprints.IsLearned(cast.base) then
        entry.castID, entry.castAt, entry.castSpell = cast.base, cast.at, cast.spellID
    end
    fight.unknown[#fight.unknown + 1] = entry
end

-- Combat ended: close the fight and queue its read.
function Teacher.Finish(now)
    local fight = Teacher.fight
    Teacher.fight = nil
    Teacher.last = nil
    Later() -- a judging that waited for this fight goes on
    if not fight then
        Judge(function() Done({ skip = "no fight" }) end)
        return
    end
    if IsNumber(now) then fight.duration = now - fight.at + (fight.carried or 0) end
    if not Meter.Available() then
        Judge(function() Skipped(fight.at, "meter off") end)
        return
    end

    local queued = epoch
    if not pcall(C_Timer.After, READ_DELAY, function() if queued == epoch then Read(fight) end end) then
        Judge(function() Skipped(fight.at, "read failed") end)
    end
end
