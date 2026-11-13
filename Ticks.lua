-- Combat Text Icons: tick periods (WoW Forever only, where every amount is secret). A DoT or HoT ticks at a steady
-- period after its cast, so a spell cast alone teaches its period: a key (a plate for damage, "player" for heals on
-- you) whose cast-free events land at delays d1, d1 + p and d1 + 2 * p, with d1 about p (up to LAG late), has learned
-- a period (saved per specialization in store.lockedTicks). Spacing, not k * d1: a first tick 0.1 s late put the
-- third 0.185 s off 3 * d1 (S7 run 1, 2026-11-07), and a period with a delay near its half is twice the real one.
-- A cast keeps its delays per school, so a stray hit of another school (a wand hit before its lock forms, S8 run 1)
-- can't shut the DoT's own school out. An event then fits a saved spell when it lands near a whole number of periods
-- after that spell's newest cast on the key; such an event is that spell's tick and joins no other cast's delays.
-- Fits answers which spells fit; the caller takes the slot of a sole fit.
-- A taken tick refines the saved period: at k >= 2 periods after its cast, its own estimate age / k moves the period
-- by REFINE of the gap. The learned period carries the first delays' jitter (S5, 2026-11-06: learned 3.034 on a 3.00
-- tick), and k * that error pushes later ticks past TOL; age / k divides a tick's jitter by k instead. The event that
-- learned is not counted twice, and a fit nobody takes (another spell's tick, or no sole fit) moves nothing.
-- A damage event within CAST_GAP after a cast is not cast-free (it may be that cast's own hit) unless every cast on
-- that stamp is of a spell known to hit another school: the school of its last hit that a cast lock fit (Locked.lua
-- Rule 2 calls Ticks.NoteHitSchool). S5 run 2 (2026-11-06): Shoot, every 1.8 s and arcane, put SW:P's shadow ticks on
-- or just after its casts, so a tick the learner needed was dropped on 5 of 9 casts and SW:P never learned.
-- Such an event fits no tick either: it counts as a fit for the cast's misses, but Fits leaves it out and its slot
-- stays free. S6 run 3 (2026-11-06): a Mind Blast hit on its cast's stamp fit an ended SW:P's tick k=10 and drew SW:P.
-- A damage event that fits another spell's cast lock (Fits' `hitOf`) is that spell's own hit: it joins no other
-- cast's delays, so a wand's arcane hits one swing apart teach SW:P no period. Before the wand's lock forms (its
-- first two hits) they still can.
-- A cast is its timestamp: casts and events share one clock (GetTime).

local _, ns = ...

local Ticks = {}
ns.Ticks = Ticks

local TOL = 0.15        -- how far an event may be from a whole number of periods
local CAST_GAP = 0.35   -- a damage event this close after a cast of yours that may hit its school is not cast-free
local MIN_PERIOD = 1.0  -- shortest period learned
local MAX_PERIOD = 10   -- longest period learned
local NEED = 3          -- ticks (d1, d1 + p, d1 + 2 * p) that learn a period
local LAG = 0.25        -- how late a cast's first tick may land after one tick spacing (S7 run 1: 3.09 s on 2.95)
local KMAX = 12         -- most periods after the cast that an event may fit
local MISS_CASTS = 3    -- checked casts in a row with no fit that retire a saved spell
local MAX_DELAYS = 16   -- delays a cast keeps, oldest dropped
local REFINE = 0.25     -- share of the gap to a taken tick's estimate that the saved period moves

-- Direct-damage spells with no DoT: Mind Blast and Smite (every rank, since Forever doesn't fold ranks; capture:
-- `CAST player 8102 base=8102,8102`), and Forever's 1309595 nuke (both ranks). A listed spell on a cast stamp is no partner, so
-- the instant cast queued with it (SW:P after Mind Blast) is still alone and learns; a listed spell never learns. A
-- list, not "has a cast bar": a hard cast with its own DoT (Holy Fire) would teach its partner that DoT (spec
-- 2026-11-07-forever-swp-stamp-partner).
-- The value is the spell's school (Mind Blast shadow 32, Smite holy 2): Locked.TicklessCast names a lone hit of that
-- school on the cast's stamp as the spell's own.
local TICKLESS = {
    [8092] = 32, [8102] = 32, [8103] = 32, [8104] = 32, [8105] = 32, [8106] = 32,
    [10945] = 32, [10946] = 32, [10947] = 32, -- Mind Blast
    [585] = 2, [591] = 2, [598] = 2, [984] = 2, [1004] = 2, [6060] = 2,
    [10933] = 2, [10934] = 2, -- Smite
    [1309595] = 32, -- a Forever instant shadow nuke (runs 6-7, 2026-11-13: one hit on its cast stamp, ~350 per cast)
    [1309633] = 32, -- its rank 2 (run 8, 2026-11-13: one hit on its cast stamp, ~490 per cast, 0 of 7 named)
}
Ticks.TICKLESS = TICKLESS -- read-only

-- Forever DoTs with no opening hit: their cast frame deals nothing, so Tracker gives them no hit there (S12 run 1:
-- the 1260198 drain and a Touch of Weakness proc on SW:P's or Devouring Plague's cast stamp drew as the DoT). DoTs that
-- open with a hit (Holy Fire, Immolate, Moonfire, Flame Shock) are not listed. 970 and 2944 are from logs; the other
-- ranks are Classic data.
Ticks.NO_OPENER = { -- read-only
    [589] = true, [594] = true, [970] = true, [992] = true, [2767] = true, [10892] = true, [10893] = true,
    [10894] = true, -- Shadow Word: Pain
    [2944] = true, [19276] = true, [19277] = true, [19278] = true, [19279] = true, [19280] = true, -- Devouring Plague
}

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
-- [spellID] = the school of the spell's last hit that a cast lock fit (Ticks.NoteHitSchool), since load
local hitSchools = {}
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
    Clear(hitSchools)
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

-- Whether `delay` lands from TOL before `target` to LAG after it: where a tick may land.
local function TickNear(delay, target)
    return delay >= target - TOL and delay <= target + LAG
end

-- The period of the ticks d1, d2 = d1 + p, then a delay near each d1 + k * p up to NEED ticks, where p = d2 - d1 is in
-- [MIN_PERIOD, MAX_PERIOD] and d1 lands near p; nil otherwise. The period is the mean spacing, first tick to last.
local function ChainPeriod(delays, d1, d2)
    local spacing = d2 - d1
    if spacing < MIN_PERIOD or spacing > MAX_PERIOD or not TickNear(d1, spacing) then return nil end

    local last = d2
    for k = 2, NEED - 1 do
        last = DelayNear(delays, d1 + k * spacing)
        if not last then return nil end
    end

    return (last - d1) / (NEED - 1)
end

-- Whether a delay lands half a period before the chain's first tick at d1 or halfway between two of its ticks: a
-- rhythm twice as fast, so the period is twice the real one (ticks between dropped), or the chain is every other hit
-- of a wand before its lock forms (Shoot every 1.8 s puts arcane hits 3.6, 5.4, 7.2 s after a cast).
local function HasHalf(delays, d1, period)
    for j = 0, NEED - 1 do
        local mid = d1 + (j - 0.5) * period
        for _, delay in ipairs(delays) do
            if TickNear(delay, mid) then return true end
        end
    end

    return false
end

-- The period the delays teach and its first tick's delay, or nil: the first chain (ChainPeriod) in delay order with no
-- delay at a half step (HasHalf).
local function PeriodOf(delays)
    for i, d1 in ipairs(delays) do
        for j = i + 1, #delays do
            local period = ChainPeriod(delays, d1, delays[j])
            if period and not HasHalf(delays, d1, period) then return period, d1 end
        end
    end
end

-- Whether another unsaved cast of the kind on the key, older than `cast` and not tickless, lands m in 1..KMAX periods
-- before the chain's first tick at `firstAt`: the ticks may be that cast's, so `cast` learns nothing from them. S7 run
-- 1 (2026-11-07): PW:S 600, cast on a Renew tick, saw Renew's next three ticks as its own.
local function OlderOwns(casts, cast, kind, school, firstAt, period)
    for otherID, other in pairs(casts) do
        local older = other ~= cast and other.at < cast.at and other.kind == kind and not saved[otherID]
            and not TICKLESS[otherID]
        local schoolOk = kind ~= "damage" or hitSchools[otherID] == nil or hitSchools[otherID] == school
        if older and schoolOk then
            local age = firstAt - other.at
            local m = math.floor(age / period + 0.5)
            if m >= 1 and m <= KMAX and TickNear(age, m * period) then return true end
        end
    end

    return false
end

-- A newest cast ends (a recast, the key gone, the fight over). Only a checked cast of a saved spell counts: no fit is
-- a miss, a fit clears the misses; MISS_CASTS misses retire the spell. Its slots leave `used`.
local function EndCast(spellID, cast)
    local entry = saved[spellID]

    if entry and cast.checked and not ns.HitRoute.InGroup() then
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
        if not TICKLESS[spellID] then stamp.n = stamp.n + 1 end
    end

    if key then
        local cast = { at = now, kind = kind, alone = not TICKLESS[spellID], delays = {}, fits = 0 }
        newest[key] = newest[key] or {}
        if newest[key][spellID] then EndCast(spellID, newest[key][spellID]) end
        newest[key][spellID] = cast
        stamp.casts[#stamp.casts + 1] = cast
    end

    if stamp.n > 1 then
        for _, cast in ipairs(stamp.casts) do cast.alone = false end
    end
end

local function CastFree(kind, school, now)
    if kind == "heal" then return lastCastAt ~= now end
    if now - lastCastAt > CAST_GAP then return true end

    for spellID in pairs(stamp.ids) do
        local known = hitSchools[spellID]
        if known == nil or known == school then return false end
    end

    return true
end

-- The tick slot an event at `now` takes of a saved spell's newest cast and its k, or nil: the event is of the spell's
-- school (damage), lands near (TickNear) the k-th period for k in 1..KMAX, and no event has taken that slot yet. LAG,
-- not TOL, after it: ticks land about 0.1 s late, and with a period learned 0.03 s short the 5th tick of S8 run 1
-- (2026-11-07) landed 0.24 s after 5 * period, fit nothing, and so never refined the period.
local function FitSlot(id, entry, cast, school, now)
    local age = now - cast.at
    local k = math.floor(age / entry.period + 0.5)
    local slot = id .. "@" .. cast.at .. "@" .. k
    local schoolFits = entry.kind ~= "damage" or entry.school == school
    local onTick = k >= 1 and k <= KMAX and TickNear(age, k * entry.period)

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

-- Whether `hitOf` (a set of spellIDs) holds a spell other than `id`.
local function HitOfOther(hitOf, id)
    for spellID in pairs(hitOf) do
        if spellID ~= id then return true end
    end

    return false
end

-- A cast-free event at `now` that fits no saved spell on the key (a saved spell's tick is that spell's): each unsaved
-- alone cast of the kind on the key adds its delay, then may learn, unless the event is another spell's own hit.
local function Learn(casts, kind, school, now, hitOf)
    if kind == "heal" then
        if healLearnAt == now then return end
        healLearnAt = now
    end
    if AnyFit(casts, kind, school, now) then return end

    for id, cast in pairs(casts) do
        if cast.kind == kind and cast.alone and not saved[id] and not HitOfOther(hitOf, id) then
            local bucket = school or "heal"
            cast.delays[bucket] = cast.delays[bucket] or {}
            local delays = cast.delays[bucket]
            delays[#delays + 1] = now - cast.at
            if #delays > MAX_DELAYS then table.remove(delays, 1) end

            local period, d1 = PeriodOf(delays)
            local older = period and OlderOwns(casts, cast, kind, school, cast.at + d1, period)
            if period and not older and not ns.HitRoute.InGroup() then
                saved[id] = { period = period, kind = kind, school = school, misses = 0 }
                cast.learnedAt = now
                if ns.Debug then ns.Debug("TICKS learned %d period=%.3f kind=%s", id, period, kind) end
            end
        end
    end
end

-- Ticks.Fits(key, kind, school, now, hitOf): learns first when the event is cast-free, then returns the saved spells
-- the event fits, as { spellID, slot } (never nil). `hitOf` (optional, [spellID] = any): the spells whose cast lock the
-- event fits (Locked.lua Rule 2), so it is their own hit and joins no other spell's delays.
function Ticks.Fits(key, kind, school, now, hitOf)
    local fits = {}
    estimates = {}
    if not ns.IsForever or not IsNumber(now) then return fits end
    if kind == "damage" and not IsNumber(school) then return fits end

    local casts = newest[key]
    if not casts then return fits end

    local free = CastFree(kind, school, now)
    if free then Learn(casts, kind, school, now, hitOf or {}) end
    -- a damage event that may be a fresh cast's own hit names no tick: it keeps the cast alive, but the slot stays free
    local named = free or kind == "heal"

    for id, cast in pairs(casts) do
        local entry = saved[id]
        if entry and entry.kind == kind then
            if now - cast.at >= entry.period - TOL then cast.checked = true end
            local slot, k = FitSlot(id, entry, cast, school, now)
            if slot then
                cast.fits = cast.fits + 1
                if named then
                    fits[#fits + 1] = { spellID = id, slot = slot }
                    if k >= 2 and cast.learnedAt ~= now then estimates[slot] = (now - cast.at) / k end
                end
            end
        end
    end

    return fits
end

-- Ticks.NoteHitSchool(spellID, school): a cast lock fit a hit of that spell (its own hit), so its casts hit that school.
function Ticks.NoteHitSchool(spellID, school)
    if ns.IsForever and IsNumber(spellID) and IsNumber(school) then hitSchools[spellID] = school end
end

-- Ticks.Take(spellID, slot): the caller's sole fit takes its tick, drawn or not, and refines the period when the last
-- Fits call gave that slot an estimate.
function Ticks.Take(spellID, slot)
    if not ns.IsForever then return end

    used[slot] = true
    local entry, estimate = saved[spellID], estimates[slot]
    if entry and estimate and not ns.HitRoute.InGroup() then
        entry.period = entry.period + REFINE * (estimate - entry.period)
    end
end

-- Ticks.DropHeal(spellID): forgets a saved heal HoT the meter never listed (a harmful cast's self-heals landed on its
-- rhythm: S11 run 1, Devouring Plague on Touch of Weakness); a damage entry stays.
function Ticks.DropHeal(spellID)
    local entry = saved[spellID]
    if not ns.IsForever or not entry or entry.kind ~= "heal" then return end

    saved[spellID] = nil
    if ns.Debug then ns.Debug("TICKS dropped %d", spellID) end
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
