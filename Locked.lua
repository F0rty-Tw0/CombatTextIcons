-- Combat Text Icons: locked pass (WoW Forever only, where every hit amount is secret). For a solo secret hit it
-- answers which one spell fits: `sole, fits` (fits: how many different spells fit, sole: that spell when it is 1).
-- Rule 1, own school (saved per specialization): a spell owns a school when the school's hits come only from it. On a
-- fight's first hit the newest meter session is read once: when it is newer than the last one read and holds exactly
-- one row, a spell of that ID cast within OWN_WINDOW of the hit is taught the hit's school. The entry draws that spell
-- for its school's hits cast within OWN_WINDOW; a hit of its school with no such cast is a stray, and STRAYS_MAX
-- strays share the school, which retires the entry. A spell with an active entry for another school takes no lock
-- on this school.
-- Rule 2, the cast lock (live, never saved): a repeating cast's hits land at about the same delay after their cast
-- while range holds. Per (plate, spell, school) a lock learns that delay: until it has one it keeps the delay and cast
-- of its last KEPT_HITS hits, and a hit within DELAY_TOL of a kept one from a different cast (the repeat test: one
-- cast cannot lock) forms the lock at the mean of the two, pairing with the nearest. A hit fits a lock within
-- DELAY_TOL of it when its cast has not named a hit yet, and moves it. Each cast of the spell closes the period of the
-- one before it: a period without a fit is a miss, BREAK_CASTS misses clear the lock and its delays.
-- A cast is its timestamp: a second NoteCast of one spell on one stamp is the same cast.

local _, ns = ...
local Meter = ns.Meter

local Locked = {}
ns.Locked = Locked

local DELAY_TOL = 0.15 -- how far a delay may be from the lock (the window measured on the 2026-11-05 Forever captures)
local KEPT_HITS = 6    -- delays a lockless key keeps
local BREAK_CASTS = 3  -- casts without a fit that clear a lock
local FOLLOW = 0.25    -- how far a fit moves the lock toward its delay
local OWN_WINDOW = 1.5 -- a cast this close before a hit can own its school
local STRAYS_MAX = 2   -- strays that retire an own-school entry

local issecretvalue = issecretvalue or function() return false end
local function IsNumber(value) return not issecretvalue(value) and type(value) == "number" end

-- [spellID] = the spell's newest cast time
local casts = {}
-- [plate][spellID][school] = { lock, miss, fit, kept = { { delay, cast }, ... } }
local locks = {}
-- [spellID][castTime] = true: that cast named a hit, on any plate
local used = {}
-- [spellID] = { school = number, strays = number, shared = true or nil }: the store's own-school entries
local schools = {}
-- The newest meter session ID read at a first hit. In memory only: a load, a spec change or Forget leaves none.
local lastSession
-- Whether this fight's first hit has been read
local firstHitRead = false
-- [spellID] = how many hits drew that spell's icon from an answer of this module, live (never saved)
local counts = {}
-- The last fight's counts, held for Report until the next EndFight replaces them or Carry merges them into `counts`.
local lastFight = {}

local function Clear(set)
    for key in pairs(set) do set[key] = nil end
end

local function ClearLive()
    Clear(casts)
    Clear(counts)
    Clear(locks)
    Clear(used)
    firstHitRead = false
end

local function IsValidEntry(spellID, entry)
    if type(spellID) ~= "number" or type(entry) ~= "table" then return false end

    local sharedOk = entry.shared == nil or entry.shared == true

    return type(entry.school) == "number" and type(entry.strays) == "number" and sharedOk
end

-- Locked.Init(store): binds the store's own-school entries and drops the bad ones; a spec change runs it again.
function Locked.Init(store)
    ClearLive()
    Clear(lastFight)
    lastSession = nil
    if type(store.lockedSchools) ~= "table" then store.lockedSchools = {} end
    schools = store.lockedSchools

    for spellID, entry in pairs(schools) do
        if not IsValidEntry(spellID, entry) then schools[spellID] = nil end
    end
end

function Locked.Forget()
    ClearLive()
    Clear(lastFight)
    lastSession = nil
    Clear(schools)
end

-- The live counts move to `lastFight`, replacing it, so a re-pull before the read counts into fresh ones. The session
-- ID stays: the next first hit compares against it.
function Locked.EndFight()
    lastFight, counts = counts, {}
    ClearLive()
end

-- A re-pull inside the read delay: the last fight's read met the next fight and Teacher merged the two (Teacher.Read,
-- Carry), so the last fight's counts join the live ones and are reported at the merged read.
function Locked.Carry()
    for spellID, hits in pairs(lastFight) do counts[spellID] = (counts[spellID] or 0) + hits end
    Clear(lastFight)
end

-- The row total of `spellID` in `rows`, or nil when no plain row has that ID or its total is not a plain number.
local function RowTotal(rows, spellID)
    for _, row in ipairs(rows) do
        local id, total = row.spellID, row.total
        if IsNumber(id) and id == spellID and IsNumber(total) then return total end
    end
end

-- The debug line for each spell the last fight's routes drew, from the fight's own `rows` (after Growth, each
-- { spellID, total, overkill }). Always clears `lastFight`; prints only under ns.Debug.
function Locked.Report(rows)
    local fight = lastFight
    lastFight = {}
    if not ns.Debug then return end

    local spellIDs = {}
    for spellID in pairs(fight) do spellIDs[#spellIDs + 1] = spellID end
    table.sort(spellIDs)

    for _, spellID in ipairs(spellIDs) do
        local hits, total = fight[spellID], RowTotal(rows, spellID)
        local shownTotal, shownPer = "?", "?"
        if total then
            shownTotal = string.format("%.0f", total)
            shownPer = string.format("%.0f", total / hits)
        end
        ns.Debug("LOCKED %d hits=%d total=%s per=%s", spellID, hits, shownTotal, shownPer)
    end
end

function Locked.PlateGone(plate) locks[plate] = nil end

-- A hit drew `spellID`'s icon from the sole fit Observe answered.
function Locked.Drew(spellID)
    counts[spellID] = (counts[spellID] or 0) + 1
end

local function Entry(plate, spellID, school)
    locks[plate] = locks[plate] or {}
    locks[plate][spellID] = locks[plate][spellID] or {}
    local bySchool = locks[plate][spellID]
    bySchool[school] = bySchool[school] or { miss = 0, fit = false, kept = {} }

    return bySchool[school]
end

local function CloseMisses(entry)
    entry.miss = entry.fit and 0 or entry.miss + 1
    entry.fit = false
    if entry.miss < BREAK_CASTS then return end

    entry.lock, entry.miss = nil, 0
    Clear(entry.kept)
end

-- A cast of `spellID` at `now`: closes the last period of each of its locks, then it is the spell's newest cast.
function Locked.NoteCast(spellID, now)
    if not ns.IsForever then return end
    if casts[spellID] == now then return end

    for _, bySpell in pairs(locks) do
        for _, entry in pairs(bySpell[spellID] or {}) do
            if entry.lock then CloseMisses(entry) end
        end
    end
    casts[spellID] = now
end

local function IsUsed(spellID, castTime) return used[spellID] ~= nil and used[spellID][castTime] == true end

-- The kept delay from another cast nearest `delay` and within DELAY_TOL, or nil.
local function NearestKept(entry, delay, castTime)
    local nearest, gap = nil, DELAY_TOL

    for _, held in ipairs(entry.kept) do
        local apart = math.abs(held.delay - delay)
        if held.cast ~= castTime and apart <= gap then nearest, gap = held.delay, apart end
    end

    return nearest
end

local function Keep(entry, delay, castTime)
    entry.kept[#entry.kept + 1] = { delay = delay, cast = castTime }
    if #entry.kept > KEPT_HITS then table.remove(entry.kept, 1) end
end

-- A lockless key sees a hit: pairs it into a lock or keeps its delay. Never a fit.
local function Form(entry, delay, castTime)
    local partner = NearestKept(entry, delay, castTime)
    if not partner then return Keep(entry, delay, castTime) end

    entry.lock, entry.fit, entry.miss = (partner + delay) / 2, true, 0
    Clear(entry.kept)
end

-- Whether the hit fits this key's lock; a fit moves the lock.
local function Fit(entry, spellID, delay, castTime)
    local close = math.abs(delay - entry.lock) <= DELAY_TOL
    if not close or IsUsed(spellID, castTime) then return false end

    entry.lock = (1 - FOLLOW) * entry.lock + FOLLOW * delay
    entry.fit = true

    return true
end

local function Mark(spellID, castTime)
    used[spellID] = used[spellID] or {}
    used[spellID][castTime] = true
end

-- The highest plain session ID in the list, or nil when the list is secret or holds none. Never disables the meter.
local function NewestMeterSession()
    local sessions = C_DamageMeter.GetAvailableCombatSessions()
    if issecretvalue(sessions) or type(sessions) ~= "table" then return nil end

    local newest
    for _, session in ipairs(sessions) do
        local id = not issecretvalue(session) and session.sessionID
        if IsNumber(id) and (not newest or id > newest) then newest = id end
    end

    return newest
end

-- The spell ID of the session's only row, or nil when the read is secret or holds any other number of rows.
local function SoleRowSpell(session)
    local source = C_DamageMeter.GetCombatSessionSourceFromID(session, Meter.DAMAGE_DONE, UnitGUID("player"))
    if issecretvalue(source) or type(source) ~= "table" then return nil end

    local rows = source.combatSpells
    if issecretvalue(rows) or type(rows) ~= "table" or #rows ~= 1 then return nil end

    local row = rows[1]
    if issecretvalue(row) or type(row) ~= "table" then return nil end

    local spellID, total = row.spellID, row.totalAmount
    local isPlain = IsNumber(spellID) and not issecretvalue(total)

    return isPlain and spellID or nil
end

local function CastInWindow(spellID, now)
    local castTime = casts[spellID]
    if not castTime then return false end

    return now - castTime <= OWN_WINDOW
end

local function Teach(spellID, school)
    local entry = schools[spellID]
    if entry and (entry.shared or entry.school == school) then return end

    schools[spellID] = { school = school, strays = 0 }
end

-- A fight's first hit: reads the newest session once and teaches its only row's spell when every condition holds.
local function ReadFirstHit(school, now)
    local okSession, newest = pcall(NewestMeterSession)
    if not okSession or not newest then return end

    local previous = lastSession
    lastSession = newest
    if previous and newest <= previous then return end

    local okRow, spellID = pcall(SoleRowSpell, newest)
    if not okRow or not spellID or not CastInWindow(spellID, now) then return end

    Teach(spellID, school)
end

-- Entries of `school`: a spell cast in the window fits, any other adds a stray, and STRAYS_MAX strays share it.
local function ReadOwnSchools(school, now, fitting)
    for spellID, entry in pairs(schools) do
        if entry.school == school and not entry.shared then
            if CastInWindow(spellID, now) then
                fitting[spellID] = casts[spellID]
            else
                entry.strays = entry.strays + 1
                entry.shared = entry.strays >= STRAYS_MAX or nil
            end
        end
    end
end

local function OwnsOtherSchool(spellID, school)
    local entry = schools[spellID]

    return entry ~= nil and not entry.shared and entry.school ~= school
end

local function CountKeys(set)
    local count = 0
    for _ in pairs(set) do count = count + 1 end

    return count
end

-- A solo secret hit of `school` on `plate` at `now`: `sole, fits`. Moves locks and marks casts as it goes.
function Locked.Observe(plate, school, now)
    if not firstHitRead then
        firstHitRead = true
        ReadFirstHit(school, now)
    end

    local fitting = {}
    local lockFitting = {}
    ReadOwnSchools(school, now, fitting)

    for spellID, castTime in pairs(casts) do
        if not OwnsOtherSchool(spellID, school) then
            local entry = Entry(plate, spellID, school)
            local delay = now - castTime
            if not entry.lock then
                Form(entry, delay, castTime)
            elseif Fit(entry, spellID, delay, castTime) then
                fitting[spellID] = castTime
                lockFitting[spellID] = true
            end
        end
    end

    local fits = CountKeys(fitting)
    if fits ~= 1 then return nil, fits end

    local sole = next(fitting)
    if lockFitting[sole] then Mark(sole, fitting[sole]) end

    return sole, fits
end
