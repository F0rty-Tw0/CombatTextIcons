-- Combat Text Icons: tick periods (WoW Forever only, where every amount is secret). A DoT or HoT ticks at a steady
-- period after its cast, so a spell cast alone teaches its period: a key (a plate for damage, "player" for heals on
-- you) whose cast-free events land at delays d1, then about 2 * d1 and 3 * d1 has learned a period (saved per
-- specialization in store.lockedTicks). An event then fits a saved spell when it lands near a whole number of periods
-- after that spell's newest cast on the key; such an event is that spell's tick and joins no other cast's delays.
-- Fits answers which spells fit; the caller takes the slot of a sole fit.
-- A taken tick refines the saved period: at k >= 2 periods after its cast, its own estimate age / k moves the period
-- by REFINE of the gap. The learned period carries the first delays' jitter (S5, 2026-11-06: learned 3.034 on a 3.00
-- tick), and k * that error pushes later ticks past TOL; age / k divides a tick's jitter by k instead. The event that
-- learned is not counted twice, and a fit nobody takes (another spell's tick, or no sole fit) moves nothing.
-- A cast is its timestamp: casts and events share one clock (GetTime).

local _, ns = ...

local Ticks = {}
ns.Ticks = Ticks

local TOL = 0.15        -- how far an event may be from a whole number of periods
local CAST_GAP = 0.35   -- a damage event this close after any cast of yours is not cast-free
local MIN_PERIOD = 1.0  -- shortest period learned
local MAX_PERIOD = 10   -- longest period learned
local NEED = 3          -- delays (d1, 2 * d1, 3 * d1) that learn a period
local KMAX = 12         -- most periods after the cast that an event may fit
local MISS_CASTS = 3    -- checked casts in a row with no fit that retire a saved spell
local MAX_DELAYS = 16   -- delays a cast keeps, oldest dropped
local REFINE = 0.25     -- share of the gap to a taken tick's estimate that the saved period moves

local issecretvalue = issecretvalue or function() return false end
local function IsNumber(value) return not issecretvalue(value) and type(value) == "number" end

-- [spellID] = { period, kind, school, misses }: the store's entries
local saved = {}
-- [key][spellID] = { at, kind, alone, school, delays, fits, checked, learnedAt }: the spell's newest cast on that key
local newest = {}
-- [slot] = true: that tick has named a hit or heal; slot is spellID .. "@" .. at .. "@" .. k
local used = {}
-- [slot] = age / k for each fit at k >= 2 of the last Fits call: Take refines the saved period from it
local estimates = {}
-- The casts seen on the newest cast stamp, for the alone test
local stamp = { at = nil, ids = {}, n = 0, casts = {} }
-- [spellID] = true for every ID NoteCast has seen since load
local castIDs = {}
local lastCastAt = -math.huge
-- The stamp of the last heal event that learned: heals on one stamp join delays once
local healLearnAt

local function Clear(set)
    for key in pairs(set) do set[key] = nil end
end

local function ClearLive()
    Clear(newest)
    Clear(used)
    Clear(estimates)
    stamp = { at = nil, ids = {}, n = 0, casts = {} }
    lastCastAt = -math.huge
    healLearnAt = nil
end

local function IsValidEntry(spellID, entry)
    if type(spellID) ~= "number" or type(entry) ~= "table" then return false end

    local kind = entry.kind
    local kindOk = kind == "heal" or (kind == "damage" and type(entry.school) == "number")

    return type(entry.period) == "number" and entry.period > 0 and type(entry.misses) == "number" and kindOk
end

-- Ticks.Init(store): binds the store's entries and drops the bad ones; a spec change runs it again.
function Ticks.Init(store)
    ClearLive()
    if type(store.lockedTicks) ~= "table" then store.lockedTicks = {} end
    saved = store.lockedTicks

    for spellID, entry in pairs(saved) do
        if not IsValidEntry(spellID, entry) then saved[spellID] = nil end
    end
end

function Ticks.Forget()
    ClearLive()
    Clear(castIDs)
    Clear(saved)
end

function Ticks.IsOwnCast(spellID)
    if not ns.IsForever then return false end

    local entry = saved[spellID]

    return castIDs[spellID] == true or (entry ~= nil and entry.kind == "heal")
end

-- The first delay within TOL of `target`, or nil.
local function DelayNear(delays, target)
    for _, delay in ipairs(delays) do
        if math.abs(delay - target) <= TOL then return delay end
    end
end

-- The mean of d1 and each matched d_k / k for k = 2..NEED, or nil when some k * d1 has no delay near it.
local function MeanPeriod(delays, d1)
    local sum = d1
    for k = 2, NEED do
        local found = DelayNear(delays, k * d1)
        if not found then return nil end
        sum = sum + found / k
    end

    return sum / NEED
end

-- The period the delays teach, or nil: the first d1 in [MIN_PERIOD, MAX_PERIOD] that has a delay near each
-- k * d1 for k = 2..NEED; the period is the mean of the matched d_k / k.
local function PeriodOf(delays)
    for _, d1 in ipairs(delays) do
        local period = d1 >= MIN_PERIOD and d1 <= MAX_PERIOD and MeanPeriod(delays, d1)
        if period then return period end
    end
end

-- A newest cast ends (a recast, the key gone, the fight over). Only a checked cast of a saved spell counts: no fit is
-- a miss, a fit clears the misses; MISS_CASTS misses retire the spell. Its slots leave `used`.
local function EndCast(spellID, cast)
    local entry = saved[spellID]

    if entry and cast.checked then
        entry.misses = cast.fits == 0 and entry.misses + 1 or 0
        if entry.misses >= MISS_CASTS then
            saved[spellID] = nil
            if ns.Debug then ns.Debug("TICKS retired %d", spellID) end
        end
    end

    local prefix = spellID .. "@" .. cast.at .. "@"
    for slot in pairs(used) do
        if string.sub(slot, 1, #prefix) == prefix then used[slot] = nil end
    end
end

-- Ends every cast on the key and forgets it.
local function EndKey(key)
    for spellID, cast in pairs(newest[key] or {}) do EndCast(spellID, cast) end
    newest[key] = nil
end

-- Ticks.NoteCast(spellID, now, key, kind): every call, with a key or without, moves the last cast and the stamp.
function Ticks.NoteCast(spellID, now, key, kind)
    if not ns.IsForever or not IsNumber(spellID) or not IsNumber(now) then return end

    lastCastAt = now
    castIDs[spellID] = true
    if stamp.at ~= now then stamp = { at = now, ids = {}, n = 0, casts = {} } end
    if not stamp.ids[spellID] then
        stamp.ids[spellID] = true
        stamp.n = stamp.n + 1
    end

    if key then
        local cast = { at = now, kind = kind, alone = true, delays = {}, fits = 0 }
        newest[key] = newest[key] or {}
        if newest[key][spellID] then EndCast(spellID, newest[key][spellID]) end
        newest[key][spellID] = cast
        stamp.casts[#stamp.casts + 1] = cast
    end

    if stamp.n > 1 then
        for _, cast in ipairs(stamp.casts) do cast.alone = false end
    end
end

local function CastFree(kind, now)
    if kind == "heal" then return lastCastAt ~= now end

    return now - lastCastAt > CAST_GAP
end

-- The tick slot an event at `now` takes of a saved spell's newest cast and its k, or nil: the event is of the spell's
-- school (damage), lands within TOL of the k-th period for k in 1..KMAX, and no event has taken that slot yet.
local function FitSlot(id, entry, cast, school, now)
    local age = now - cast.at
    local k = math.floor(age / entry.period + 0.5)
    local slot = id .. "@" .. cast.at .. "@" .. k
    local schoolFits = entry.kind ~= "damage" or entry.school == school
    local onTick = k >= 1 and k <= KMAX and math.abs(age - k * entry.period) <= TOL

    if schoolFits and onTick and not used[slot] then return slot, k end
end

-- Whether the event fits a saved spell of its kind on the key, as Fits would answer.
local function AnyFit(casts, kind, school, now)
    for id, cast in pairs(casts) do
        local entry = saved[id]
        if entry and entry.kind == kind and FitSlot(id, entry, cast, school, now) then return true end
    end

    return false
end

-- A cast-free event at `now` that fits no saved spell on the key (a saved spell's tick is that spell's): each unsaved
-- alone cast of the kind on the key adds its delay, then may learn.
local function Learn(casts, kind, school, now)
    if kind == "heal" then
        if healLearnAt == now then return end
        healLearnAt = now
    end
    if AnyFit(casts, kind, school, now) then return end

    for id, cast in pairs(casts) do
        if cast.kind == kind and cast.alone and not saved[id] then
            if kind == "damage" and cast.school == nil then cast.school = school end

            if cast.school == school then
                local delays = cast.delays
                delays[#delays + 1] = now - cast.at
                if #delays > MAX_DELAYS then table.remove(delays, 1) end

                local period = PeriodOf(delays)
                if period then
                    saved[id] = { period = period, kind = kind, school = cast.school, misses = 0 }
                    cast.learnedAt = now
                    if ns.Debug then ns.Debug("TICKS learned %d period=%.3f kind=%s", id, period, kind) end
                end
            end
        end
    end
end

-- Ticks.Fits(key, kind, school, now): learns first when the event is cast-free, then returns the saved spells the
-- event fits, as { spellID, slot } (never nil).
function Ticks.Fits(key, kind, school, now)
    local fits = {}
    estimates = {}
    if not ns.IsForever or not IsNumber(now) then return fits end
    if kind == "damage" and not IsNumber(school) then return fits end

    local casts = newest[key]
    if not casts then return fits end

    if CastFree(kind, now) then Learn(casts, kind, school, now) end

    for id, cast in pairs(casts) do
        local entry = saved[id]
        if entry and entry.kind == kind then
            if now - cast.at >= entry.period - TOL then cast.checked = true end
            local slot, k = FitSlot(id, entry, cast, school, now)
            if slot then
                cast.fits = cast.fits + 1
                fits[#fits + 1] = { spellID = id, slot = slot }
                if k >= 2 and cast.learnedAt ~= now then estimates[slot] = (now - cast.at) / k end
            end
        end
    end

    return fits
end

-- Ticks.Take(spellID, slot): the caller's sole fit takes its tick, drawn or not, and refines the period when the last
-- Fits call gave that slot an estimate.
function Ticks.Take(spellID, slot)
    if not ns.IsForever then return end

    used[slot] = true
    local entry, estimate = saved[spellID], estimates[slot]
    if entry and estimate then entry.period = entry.period + REFINE * (estimate - entry.period) end
end

-- Ticks.PlateGone(plate): that plate's casts end.
function Ticks.PlateGone(plate)
    if ns.IsForever then EndKey(plate) end
end

-- Ticks.EndFight(): every damage key's casts end; "player" stays, a HoT ticks on out of combat.
function Ticks.EndFight()
    if not ns.IsForever then return end

    for key in pairs(newest) do
        if key ~= "player" then EndKey(key) end
    end
end
