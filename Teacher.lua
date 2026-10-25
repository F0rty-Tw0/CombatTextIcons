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
-- hits become fingerprint samples. A read that meets a
-- secret value or an error is skipped whole. The verdicts also unlearn DoTs, channels and
-- procs whose drawn total overshoots the meter or never pairs with a row, and go to the
-- Ledger, which attaches them to the saved fight. A solo fight is also a crowd check: when
-- the enemy-plate wounds seen (Teacher.Seen) fit the meter's rows the area is "clear" and
-- learning runs (the leftover '?' hits and still-open rows then go to Procs.Read), else it
-- is "crowded" and that fight teaches nothing. With /cti debug each outcome logs TEACH lines.
-- Each fight's outcome, a read or a skip, ends with one Teacher.OnRead(Teacher.last) call
-- (Progress shows what the fight taught).

local _, ns = ...
local Meter, Fingerprints, Procs, Ledger = ns.Meter, ns.Fingerprints, ns.Procs, ns.Ledger

local Teacher = {}
ns.Teacher = Teacher

local READ_DELAY = 1 -- seconds after combat the session is read

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

Teacher.fight = nil -- the open fight: { at, tally = { [spellID] = sum }, unknown = { entry, ... }, seen = sum, group }
Teacher.last = nil  -- latest read: { skip = reason } or { session, rows = { {...}, ... }, learned = { [castID] = hits }, area = "clear" | "crowded" | "group" }
Teacher.area = "crowded" -- the crowd check's state: "clear" or "crowded"; never saved
Teacher.OnRead = nil -- function(last), called once per fight when its outcome is final; Progress sets it

local lastSession = nil -- ID of the session processed last, never read twice

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
    if newest == lastSession then return nil, "duplicate session" end

    return newest
end

-- The player's damage-done rows of a session as { { spellID, total, overkill }, ... }, one per
-- spell, or nil and a skip reason. The meter may list a spell in several rows: they are merged
-- (total and overkill summed) at the first one's place.
local function ReadRows(sessionID)
    local okGuid, guid = pcall(UnitGUID, "player")
    if not (okGuid and Plain(guid) and type(guid) == "string") then return nil, "read failed" end

    local ok, source = pcall(C_DamageMeter.GetCombatSessionSourceFromID, sessionID, Meter.DAMAGE_DONE, guid)
    if not ok then
        Meter.Disable(source) -- the error text

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
-- exactly one still-unpaired row and that row agrees with no other group.
local function Groups(unknown)
    local byKey, list = {}, {}
    for _, hit in ipairs(unknown) do
        if hit.castID then
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
-- one-hit row by chance.
local function Pairs(group, way, row, owners)
    if row.spellID ~= group.castID
        and (way ~= group or Procs.Has(row.spellID) or owners.rows[group.castID] or owners.casts[row.spellID]) then
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
                        castAt = hit.castAt, hops = 1 })
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
-- with then try `top`. Returns the learned ways ({ castID, sum, hits }) and the set of `open` positions
-- rewritten.
local function Learn(run, results, open, rows)
    local groups = Groups(run.unknown)
    local owners = Owners(groups, rows)
    local seen, learned, rewritten = { rows = {}, groups = {} }, {}, {}
    Pass(groups, open, owners, function(group) return group end, seen, results, learned, rewritten)
    Pass(groups, open, owners, function(group) return group.top end, seen, results, learned, rewritten)

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

-- The fight's outcome is final: report it and hand it to Teacher.OnRead.
local function Done()
    Report(Teacher.last)
    if Teacher.OnRead then Teacher.OnRead(Teacher.last) end
end

-- The crowd check: "group" (the state is kept) for a group fight, else "clear" when the
-- enemy-plate wounds seen fit the meter's rows (their total plus overkill, within the judge's
-- tolerance), else "crowded". Also returns the rows' total.
local function CrowdCheck(run, rows)
    local total, overkill = 0, 0
    for _, row in ipairs(rows) do
        total, overkill = total + row.total, overkill + row.overkill
    end

    local grouped = run.group or InGroup()
    if grouped then return "group", total end

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

-- The timer callback of one fight: read the newest session and judge it.
local function Read(run)
    local sessionID, reason = NewestSession()
    local rows
    if sessionID then rows, reason = ReadRows(sessionID) end
    if not rows then
        Teacher.last = { skip = reason }
        if reason == "duplicate session" then Ledger.Drop(run.at) end
        Done()
        return
    end

    lastSession = sessionID
    local results, open = Verdicts(run.tally, rows)
    SafetyNet(results)
    Teacher.last = { session = sessionID, rows = results, learned = {} }

    local area, total = CrowdCheck(run, rows)
    if area ~= "group" then Teacher.area = area end
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
end

-- Combat began: open a fight (an unfinished one is replaced).
function Teacher.Start(now, group)
    Teacher.fight = { at = now, tally = {}, unknown = {}, seen = 0, group = group }
end

-- An enemy-plate wound of this size was seen, drawn or not.
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
-- when the flag is unknown.
function Teacher.Unknown(plate, school, amount, now, cast, flagText)
    local fight = Teacher.fight
    if not (fight and plate ~= nil and IsNumber(school) and IsNumber(amount) and IsNumber(now)) then return end

    local entry = { school = school, amount = amount, at = now, plate = plate, crit = Procs.Crit(flagText) }
    if cast and not Fingerprints.IsLearned(cast.base) then
        entry.castID, entry.castAt = cast.base, cast.at
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
