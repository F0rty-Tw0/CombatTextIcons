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
-- hits become fingerprint samples. Then the steady pass (Steady.lua) learns from '?' hits at a
-- steady delay and size that no sum explained, for unlearned bases and for the hits a learned
-- base missed, bounded by the meter row. A read that meets a
-- secret value or an error is skipped whole. The verdicts also unlearn DoTs, channels and
-- procs whose drawn total overshoots the meter or never pairs with a row, and go to the
-- Ledger, which attaches them to the saved fight. A solo fight is also a crowd check: when
-- the wounds seen that may be yours (Teacher.Seen) fit the meter's rows the area is "clear" and
-- learning runs (the leftover '?' hits and still-open rows then go to Procs.Read), else it
-- is "crowded" and that fight teaches nothing; seen below half the rows' total is "short" and
-- teaches nothing either. With /cti debug each outcome logs TEACH lines.
-- Each fight's outcome, a read or a skip, ends with one Teacher.OnRead(Teacher.last) call
-- (Progress shows what the fight taught). A fight whose read meets the next fight is carried
-- into it (Carry) and has no outcome of its own. A fight whose newest session is the one read
-- last is judged on that session's growth since (Growth).

local _, ns = ...
local Meter, Fingerprints, Procs, Ledger, Streams = ns.Meter, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Streams
local Steady = ns.Steady

local Teacher = {}
ns.Teacher = Teacher

local READ_DELAY = 1 -- seconds after combat the session is read

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

Teacher.fight = nil -- the open fight: { at, tally = { [spellID] = sum }, unknown = { entry, ... }, seen = sum, group }
Teacher.last = nil  -- latest read: { skip = reason } or { session, rows = { {...}, ... }, learned = { [castID] = hits }, area = "clear" | "crowded" | "group" | "short" }
Teacher.area = "crowded" -- the crowd check's state: "clear" or "crowded"; never saved
Teacher.OnRead = nil -- function(last), called once per fight when its outcome is final; Progress sets it

local lastSession = nil -- ID of the session processed last
local lastRows = {}     -- that session's rows at its last read, by spell ID: { total, overkill }

local function InGroup()
    local inGroup = IsInGroup()
    return not Plain(inGroup) or inGroup -- unknown counts as grouped
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

-- Judges one paired spell and tells Fingerprints: agree counts a fight, over is a strike.
local function Apply(entry, castID, row)
    entry.verdict = Judge(entry.tally, row.total, row.overkill)
    if entry.verdict == "agree" then
        Fingerprints.Agree(castID)
    elseif entry.verdict == "over" then
        Fingerprints.Over(castID)
    end
end

-- Pairs the tally with the meter rows and applies the verdicts. Order: same spell ID; a saved
-- alias (meter row ID -> cast spell); a new alias when exactly one tally and exactly one
-- agreeing row are left. Rows with no tally stay "unpaired" and are returned in `open`, with
-- their place in `results`, for the learning pass.
local function Verdicts(tally, rows)
    local results, open, paired = {}, {}, {}
    for _, row in ipairs(rows) do
        local drawn = tally[row.spellID]
        local entry = { spellID = row.spellID, meterID = row.spellID, tally = drawn or 0, meter = row.total }
        results[#results + 1] = entry
        if drawn then
            paired[row.spellID] = true
            Apply(entry, row.spellID, row)
        else
            entry.verdict = "unpaired"
            open[#open + 1] = { row = row, index = #results }
        end
    end

    -- A saved alias names the cast spell a meter row belongs to. A learned proc owns its row, even
    -- against an alias saved before it was learned.
    for position = #open, 1, -1 do
        local row, index = open[position].row, open[position].index
        local castID = Fingerprints.Alias(row.spellID)
        if castID and tally[castID] and not paired[castID] and not Procs.Get(row.spellID) then
            paired[castID] = true
            local entry = { spellID = castID, meterID = row.spellID, tally = tally[castID], meter = row.total }
            results[index] = entry
            Apply(entry, castID, row)
            table.remove(open, position)
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
            Apply(entry, castID, row)
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
-- every '?' hit of that cast, any school), for Pairs.
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

-- Whether the cast pass may pair `way` (a group, or its `top`) with a row: the sum agrees, and a
-- row of another ID belongs to no one else. It is not a row Procs tracks (a castless proc's own;
-- spec 3.1 Rev 4), the cast has no row of its own this session, and the row is not the own row
-- of another cast this fight (`owners.rows`, `owners.casts`; Rev 5). A cast's own row still pairs.
-- A `top` pairs only with the cast's own row: one largest hit often equals some other spell's
-- one-hit row by chance. A row of another ID also needs the group in at least half the cast's casts:
-- a castless proc's lone hit in one of many cast frames is no hit of the cast (run 153349Z: one holy
-- 2364 after 1 of 6 Void Volley casts equalled the proc's row 1260076).
local function Pairs(group, way, row, owners)
    if row.spellID ~= group.castID
        and (way ~= group or Procs.Has(row.spellID) or owners.rows[group.castID] or owners.casts[row.spellID]
            or 2 * group.covered < group.casts) then
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
                    Fingerprints.Add(group.castID, { school = hit.school, delay = hit.at - hit.castAt,
                        castAt = hit.castAt, hops = 1, spell = hit.castSpell, size = hit.size })
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

-- Learning from '?' hits (spec 6.5): rewrites the learned rows of `results` against the
-- session's meter `rows`. Whole sums pair first; a row and a group that no whole sum agreed
-- with then try `top`; last, the steady pass (Steady.lua) learns from steady hits no sum explained.
-- Returns the learned ways ({ castID, sum, hits }) and the set of `open` positions rewritten.
local function Learn(run, results, open, rows)
    local groups = Groups(run.unknown)
    local owners = Owners(groups, rows)
    local seen, learned, rewritten = { rows = {}, groups = {} }, {}, {}
    Pass(groups, open, owners, function(group) return group end, seen, results, learned, rewritten)
    Pass(groups, open, owners, function(group) return group.top end, seen, results, learned, rewritten)
    for _, way in ipairs(Steady.Learn(run, rows, learned)) do learned[#learned + 1] = way end

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

-- grug: temporary probe for '?' heals (gap 3): /cti debug logs the session's healing-done rows
-- after the damage rows, to set against the fight's HEAL lines (does a heal's amount include
-- overheal?). Remove once heals are learned.
local function ReportHeals(sessionID)
    if not ns.Debug then return end
    local rows, reason = ReadRows(sessionID, Meter.HEALING_DONE)
    if not rows then
        ns.Debug("TEACH heal skip %s", reason)
        return
    end
    for _, row in ipairs(rows) do ns.Debug("TEACH heal %s meter=%s over=%s", row.spellID, row.total, row.overkill) end
end

-- The fight's outcome is final: report it and hand it to Teacher.OnRead.
local function Done()
    Report(Teacher.last)
    if Teacher.OnRead then Teacher.OnRead(Teacher.last) end
end

-- The crowd check: "group" (the state is kept) for a group fight; "short" (the state is kept)
-- when the wounds seen are below half the meter's total, so the session holds damage this fight
-- never saw (run 102226Z: 20306 seen against 4211377); else "clear" when the wounds
-- seen fit the meter's rows (their total plus overkill, within the judge's tolerance), else
-- "crowded". Also returns the rows' total.
local function CrowdCheck(run, rows)
    local total, overkill = 0, 0
    for _, row in ipairs(rows) do
        total, overkill = total + row.total, overkill + row.overkill
    end

    local grouped = run.group or InGroup()
    if grouped then return "group", total end
    if run.seen < total / 2 then return "short", total end

    local tolerance = math.max(1, total / 100)
    local fits = run.seen <= total + overkill + tolerance

    return fits and "clear" or "crowded", total
end

-- Safety net (spec 3.3): learned spells and procs face the meter on every read. A drawn
-- total (tally > 0) that overshoots drops the spell, two unpaired reads in a row drop it,
-- a paired read (agree or under) resets the count. Undrawn spells change nothing. An ID
-- both stores know is judged by both.
local function SafetyNet(results)
    for _, entry in ipairs(results) do
        for _, store in ipairs({ ns.Learn, Procs }) do
            if entry.tally > 0 and store.Get(entry.spellID) then
                if entry.verdict == "over" then
                    store.Drop(entry.spellID)
                elseif entry.verdict == "unpaired" then
                    store.Unpaired(entry.spellID)
                else
                    store.Paired(entry.spellID)
                end
            end
        end
    end
end

-- A quick re-pull: the read met the next fight (in combat the meter answers secret), and the
-- game extends one meter session over both (run 102226Z: the next read held this fight's rows).
-- This fight's tally, seen and '?' hits join the open one, oldest first, and are judged at its
-- read; this fight gets no outcome of its own.
local function Carry(run, into)
    for spellID, amount in pairs(run.tally) do into.tally[spellID] = (into.tally[spellID] or 0) + amount end
    for index, hit in ipairs(run.unknown) do table.insert(into.unknown, index, hit) end
    into.seen = into.seen + run.seen
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

-- The timer callback of one fight: read the newest session and judge it.
local function Read(run)
    local sessionID, reason = NewestSession()
    local rows
    if sessionID then rows, reason = ReadRows(sessionID) end
    if not rows and reason == "secret" and Teacher.fight then
        Carry(run, Teacher.fight)
        return
    end
    if not rows then
        Teacher.last = { skip = reason }
        Done()
        return
    end

    local full, again = rows, sessionID == lastSession
    if again then rows = Growth(full) end
    if #rows == 0 and again then
        -- leftover ticks re-entered combat for a moment and dealt nothing the meter counts
        Teacher.last = { skip = "duplicate session" }
        Ledger.Drop(run.at)
        Done()
        return
    end
    lastSession, lastRows = sessionID, {}
    for _, row in ipairs(full) do lastRows[row.spellID] = { total = row.total, overkill = row.overkill } end
    ns.Casts.NoteRows(full) -- the next fight's casts key by the meter's own rows; this fight keeps its keys
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
    local results, open = Verdicts(run.tally, rows)
    SafetyNet(results)
    Teacher.last = { session = sessionID, rows = results, learned = {} }

    local area, total = CrowdCheck(run, rows)
    if area ~= "group" and area ~= "short" then Teacher.area = area end
    Teacher.last.area = area
    if ns.Debug then
        ns.Debug("TEACH clean seen=%d meter=%d -> %s", math.floor(run.seen), math.floor(total), area)
    end
    if area == "clear" then
        local learnedGroups, rewritten = Learn(run, results, open, rows)
        for _, group in ipairs(learnedGroups) do Teacher.last.learned[group.castID] = #group.hits end
        local hits, openRows = Leftover(run.unknown, learnedGroups), StillOpen(open, rewritten)
        Procs.Read(hits, openRows, results, rows, run.at)
    end
    Ledger.SetVerdicts(Teacher.last.rows, run.at)
    Done()
    ReportHeals(sessionID)
end

-- Combat began: open a fight (an unfinished one is replaced).
function Teacher.Start(now, group)
    Teacher.fight = { at = now, tally = {}, unknown = {}, seen = 0, group = group }
end

-- A wound of this size that may be yours was seen, drawn or not (Core's Wound decides which count).
function Teacher.Seen(amount)
    local fight = Teacher.fight
    if not (fight and IsNumber(amount)) then return end
    fight.seen = fight.seen + amount
end

-- The last solo fight's wounds fit the meter and the meter is readable.
function Teacher.AreaClear()
    return Teacher.area == "clear" and Meter.Available()
end

-- A hit was drawn with this spell's icon.
function Teacher.Drawn(spellID, amount)
    local fight = Teacher.fight
    if not (fight and IsNumber(spellID) and IsNumber(amount)) then return end
    fight.tally[spellID] = (fight.tally[spellID] or 0) + amount
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
    if not fight then
        Teacher.last = { skip = "no fight" }
        Done()
        return
    end
    if not Meter.Available() then
        Teacher.last = { skip = "meter off" }
        Done()
        return
    end

    if not pcall(C_Timer.After, READ_DELAY, function() Read(fight) end) then
        Teacher.last = { skip = "read failed" }
        Done()
    end
end
