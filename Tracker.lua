-- DoT and channel ticks the damage meter cannot see (a tick opens no meter
-- session), matched to the player's casts by timing.
--
-- A cast of a spell Learn.lua learned (or of a Spells.lua row; that table ships empty) creates an expectation:
--   target   an instance on the target's plate; its first tick is due one
--            period after the cast, later ticks one (or two) periods after
--            the last matched tick;
--   spread   a 20 s window; plates the meter saw the player hit inside it are
--            "armed", and the first tick of a spread school on an armed plate
--            creates an instance there;
--   area     a window in which any plate's tick of that school matches;
--   channel  an instance on the target's plate until the channel stops;
--   hot      an instance on the heal unit (player or group member), like target.
-- A tick is attributed only when exactly one expectation fits it. Spells learned in one
-- burst of casts (a macro, a talent that casts two) share one instance. A learned spell
-- that owns a running Streams stream (a cast during it, or learning it) adopts it. When several
-- expectations fit, or a burst instance's spells show different textures, the answer is
-- Tracker.UNKNOWN: the hit is yours, the spell is not known.
-- DoTs may tick faster than UnitSpellHaste explains: a first tick that misses
-- its expected time is remembered, and a later tick repeating its gap confirms
-- the real period, learned per tick spell for the casts that follow.

local ADDON, ns = ...

local Tracker = {}
ns.Tracker = Tracker
Tracker.UNKNOWN = {} -- answer of Identify / IdentifyHeal: yours, but which spell is not known

local Spells = ns.Spells
local Learn = ns.Learn
local Streams = ns.Streams

local FIRST_TICK_SLACK = 1.5   -- a new instance lives this long past its first due tick
local CHANNEL_DEADLINE = 10    -- default life of a learned channel that has no duration
-- DoTs can tick faster than UnitSpellHaste explains (Wither every 1.48 s
-- against 2 s / 1.077 = 1.86 s in game). An unmatched same-school hit at least
-- this fraction of a period after the cast is remembered; a later hit that
-- repeats its gap confirms that gap as the period.
local RHYTHM_EARLY = 0.5
-- A plate where an unattributed hit of the same school landed this recently
-- before the cast already carries a ticking DoT of that school; its rhythm
-- would be mistaken for ours, so no rhythm is learned there.
local RHYTHM_BUSY = 3
local SPEED_MIN, SPEED_MAX = 0.5, 1.5 -- bounds of the learned period factor
local SPREAD_WINDOW = 20       -- seconds a spread cast arms plates for
local AREA_SLACK = 0.5         -- an area window outlives the effect by this
local CAST_BURST = 0.1         -- learned casts this close share one instance
local SPREAD_PERIOD = 2        -- default base period (hasted) of a spread's ticks
local MISS_WINDOW = 1.5        -- a miss is matched to a harmful cast this recent
local AMOUNT_LOW, AMOUNT_HIGH = 0.4, 2.5 -- allowed tick-to-tick amount ratio (crits scaled by Streams.NormalAmount)
local PARK_LIFE = 30           -- seconds a hidden plate's instances wait for its mob's plate to show again

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local instances = {}   -- [plate or unit token] = { instance, ... }
local areas = {}       -- { castID, icon, school, period, ends }
local spreads = {}     -- { castID, spreads, ends, armed = { [plate] = true } }
local channel          -- the channel instance (also listed under its plate)
local channelTickAt    -- time of the last tick matched to the channel
local missCasts = {}   -- recent harmful player casts: { castID, at }
local speeds = {}      -- [tick icon] = learned real period / haste-adjusted table period
local loose = {}       -- [plate or unit token] = { [school] = time of the last unattributed hit }
local parked = {}      -- [mob GUID] = { at, instances, loose, streams } of a hidden plate

-- Haste ----------------------------------------------------------------------------

local function Clamp(value) return math.min(SPEED_MAX, math.max(SPEED_MIN, value)) end

-- The table period adjusted for UnitSpellHaste only (none when the read is secret).
local function BasePeriod(period, hasted)
    local haste = hasted and Learn.Haste()
    if haste then return period / (1 + haste / 100) end
    return period
end

-- Learned per tick spell: talents speed some DoTs and not others.
local function EffectivePeriod(period, hasted, icon) return BasePeriod(period, hasted) * (speeds[icon] or 1) end

-- A new instance's period. A learned period is a haste-free base: haste only, never the `speeds` factor.
local function InstancePeriod(spell, learned)
    if learned then return BasePeriod(spell.period, spell.hasted) end

    return EffectivePeriod(spell.period, spell.hasted, spell.icon)
end

local function Tolerance(period) return math.max(0.25, 0.2 * period) end

-- The period a remembered hit and `now` agree on: the remembered hit's gap to
-- the cast and `now`'s gap to the remembered hit are the same within tolerance.
local function RhythmPeriod(instance, now)
    for _, seen in ipairs(instance.seen or {}) do
        local period = seen - instance.castAt
        if math.abs((now - seen) - period) <= Tolerance(period) then return period end
    end
end

-- Whether a hit could be the first tick of an instance still waiting for it.
local function MaybeFirstTick(instance, school, now)
    if instance.lastTick or instance.channel or instance.busy or instance.school ~= school then return false end
    local gap = now - instance.castAt
    return gap >= RHYTHM_EARLY * instance.period and gap <= instance.period + Tolerance(instance.period)
end

-- An unattributed hit of `school` on `plate`: remember it in each instance
-- still waiting for its first tick that it might be the first tick of.
local function Remember(plate, school, now)
    loose[plate] = loose[plate] or {}
    loose[plate][school] = now
    for _, instance in ipairs(instances[plate] or {}) do
        if MaybeFirstTick(instance, school, now) then
            instance.seen = instance.seen or {}
            instance.seen[#instance.seen + 1] = now
            -- live long enough for the hit that would repeat this gap
            local gap = now - instance.castAt
            instance.deadline = math.max(instance.deadline, now + gap + Tolerance(gap))
        end
    end
end

-- State helpers --------------------------------------------------------------------

local function TargetPlate()
    local plate = C_NamePlate.GetNamePlateForUnit("target", false)
    if Plain(plate) and not plate:IsForbidden() then return plate end
end
Tracker.TargetPlate = TargetPlate

-- The unit a helpful cast lands on: the targeted player or party member; the
-- player (self-cast) with no target or a hostile one. nil for a friendly
-- target outside the party (raid member, NPC) or an answer that errors or is secret.
function Tracker.HealUnit()
    for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
        local ok, isTarget = pcall(UnitIsUnit, unit, "target")
        if ok and Plain(isTarget) and isTarget then return unit end
    end
    -- nil from UnitExists is a plain "no target", not an unclear answer.
    local ok, exists = pcall(UnitExists, "target")
    if not ok or issecretvalue(exists) then return nil end
    if not exists then return "player" end
    local okAttack, hostile = pcall(UnitCanAttack, "player", "target")
    if okAttack and Plain(hostile) and hostile == true then return "player" end

    return nil
end

local function AddInstance(plate, instance)
    local list = instances[plate]
    if not list then
        list = {}
        instances[plate] = list
    end
    list[#list + 1] = instance
end

local function RemoveInstance(plate, instance)
    local list = instances[plate]
    if not list then return end
    for index = #list, 1, -1 do
        if list[index] == instance then table.remove(list, index) end
    end
    if not list[1] then instances[plate] = nil end
end

local function SpellsOf(instance) return instance.icons or { instance.castID } end

local function HasIcon(instance, id)
    for _, icon in ipairs(instance.icons or {}) do
        if icon == id then return true end
    end
    return false
end

local function FindInstance(plate, castID)
    for _, instance in ipairs(instances[plate] or {}) do
        if instance.castID == castID or HasIcon(instance, castID) then return instance end
    end
end

local function DropChannel()
    if channel then RemoveInstance(channel.plate, channel) end
    channel, channelTickAt = nil, nil
end

-- Cast log -------------------------------------------------------------------------
-- Casts feed Streams.CastLog; Learn.OnCast / OnBirth turn them into votes.

-- Wand Shoot, Auto Shot; the API may be missing on Forever.
local function IsAutoRepeat(castID)
    if not C_Spell.IsAutoRepeatSpell then return false end
    local ok, repeating = pcall(C_Spell.IsAutoRepeatSpell, castID)
    return ok and Plain(repeating) and repeating == true
end

-- Logs a harmful cast as a dot on the target plate, a helpful one as a hot on the heal unit.
local function LogCast(castID, now, harmful, helpful)
    if IsAutoRepeat(castID) then return end
    if Plain(harmful) and harmful then
        local plate = TargetPlate()
        if plate then Streams.LogCast(plate, castID, "dot", now) end
    elseif Plain(helpful) and helpful then
        local unit = Tracker.HealUnit()
        if unit then Streams.LogCast(unit, castID, "hot", now) end
    end
end

local function Housekeeping(now)
    for plate, list in pairs(instances) do
        for index = #list, 1, -1 do
            local instance = list[index]
            if instance.deadline < now then
                table.remove(list, index)
                if instance == channel then channel, channelTickAt = nil, nil end
                -- A learned DoT whose first tick never came, and could have shown itself, is a miss.
                -- Same-school hits on its plate (busy: before the cast, seen: after it) are not:
                -- a refresh whose ticks keep an older phase lands them off the cast + P time.
                if instance.learned and not instance.channel and not instance.lastTick
                    and not instance.missed and not instance.ambiguous and not instance.busy and not instance.seen then
                    for _, spellID in ipairs(SpellsOf(instance)) do Learn.Missed(spellID) end
                end
            end
        end
        if not list[1] then instances[plate] = nil end
    end
    for index = #areas, 1, -1 do
        if areas[index].ends < now then table.remove(areas, index) end
    end
    for index = #spreads, 1, -1 do
        if spreads[index].ends < now then table.remove(spreads, index) end
    end
    for index = #missCasts, 1, -1 do
        if now - missCasts[index].at > MISS_WINDOW then table.remove(missCasts, index) end
    end
end

-- Matching -------------------------------------------------------------------------

-- Which multiple of the period a tick at `now` lands on (1 or 2; 0 for the tick
-- after a recast, at restartAt + period), or nil. Callers test `if multiple`;
-- 0 still counts as a match. HoT ticks skip the amount test: partial overheal
-- makes their sizes unreliable.
local function Phase(instance, school, amount, flagText, now)
    if instance.school ~= school then return nil end
    local tolerance = Tolerance(instance.period)
    local restarted = instance.restartAt and math.abs(now - (instance.restartAt + instance.period)) <= tolerance
    if not instance.lastTick then
        if instance.channel then return 1 end
        if math.abs(now - (instance.castAt + instance.period)) <= tolerance then return 1 end
        if restarted then return 0 end
        if RhythmPeriod(instance, now) then return 1 end
        return nil
    end
    for multiple = 1, 2 do
        if math.abs(now - (instance.lastTick + multiple * instance.period)) <= tolerance then
            local normal = Streams.NormalAmount(amount, flagText)
            local last = instance.lastAmount
            local tested = not instance.hot and normal and last and last > 0
            if tested and (normal < AMOUNT_LOW * last or normal > AMOUNT_HIGH * last) then
                return nil
            end
            return multiple
        end
    end
    if restarted then return 0 end
end

-- The instances under `key` (plate or unit token) a hit fits, each with its multiple.
local function InstanceCandidates(key, school, amount, flagText, now)
    local found = {}
    for _, instance in ipairs(instances[key] or {}) do
        local multiple = Phase(instance, school, amount, flagText, now)
        if multiple then found[#found + 1] = { instance = instance, multiple = multiple } end
    end

    return found
end

-- True when one instance under `key` explains every time in `hits`: each lies within
-- Streams.Slack(P) of base + k * period for some k >= 1 (P is the stream's period).
function Tracker.ExplainsHits(key, school, hits, P)
    if not Plain(school) then return false end
    local tolerance = Streams.Slack(P)
    for _, instance in ipairs(instances[key] or {}) do
        local base, period = instance.lastTick or instance.castAt, instance.period
        if instance.school == school and base and period and period > 0 then
            local explained = true
            for _, t in ipairs(hits) do
                local k = math.max(1, math.floor((t - base) / period + 0.5))
                if math.abs(t - (base + k * period)) > tolerance then explained = false break end
            end
            if explained then return true end
        end
    end

    return false
end

-- Every expectation a hit on `plate` fits: its instances, then areas and armed spreads.
local function Candidates(plate, school, amount, flagText, now)
    local found = InstanceCandidates(plate, school, amount, flagText, now)
    for _, area in ipairs(areas) do
        if area.school == school then found[#found + 1] = { area = area } end
    end
    for _, spread in ipairs(spreads) do
        if spread.armed[plate] and not FindInstance(plate, spread.castID) then
            for _, entry in ipairs(spread.spreads) do
                if entry.school == school then found[#found + 1] = { spread = spread, entry = entry } end
            end
        end
    end
    return found
end

-- Whether every spell in `ids` shows the same texture. A failing call, a nil or a
-- secret texture counts as different.
local function SameTexture(ids)
    local function Texture(id)
        local ok, texture = pcall(C_Spell.GetSpellTexture, id)
        if ok and Plain(texture) then return texture end
    end
    local first
    for _, id in ipairs(ids) do
        if id ~= ids[1] then
            first = first or Texture(ids[1])
            if first == nil or Texture(id) ~= first then return false end
        end
    end

    return true
end

-- The icons a candidate would draw: a learned instance's spells (a burst has several).
local function CandidateIcons(candidate)
    if candidate.instance then return candidate.instance.icons or { candidate.instance.icon } end
    if candidate.area then return { candidate.area.icon } end

    return { candidate.entry.icon }
end

-- The first candidate's icon when every icon of every candidate looks alike; else UNKNOWN.
local function Pick(found)
    local ids = {}
    for _, candidate in ipairs(found) do
        for _, icon in ipairs(CandidateIcons(candidate)) do ids[#ids + 1] = icon end
    end
    if SameTexture(ids) then return ids[1] end

    return Tracker.UNKNOWN
end

-- A learned instance's first matched tick resets its spells' miss counts. An adopted
-- instance starts with a lastTick, so `hitDue` stands in for its first tick.
local function Ticked(instance, multiple, amount, flagText, now)
    if instance.learned and (not instance.lastTick or instance.hitDue) then
        for _, spellID in ipairs(SpellsOf(instance)) do Learn.Hit(spellID) end
    end
    instance.hitDue = nil
    instance.restartAt = nil
    if multiple == 0 then
        -- a tick after a recast: that gap is not a period, so nothing is smoothed
    elseif instance.lastTick then
        instance.period = 0.8 * instance.period + 0.2 * ((now - instance.lastTick) / multiple)
    elseif not instance.channel then
        local period = RhythmPeriod(instance, now)
        if period then
            instance.period = period
            if not instance.fromLearn then speeds[instance.icon] = Clamp(period / instance.base) end
        end
    end
    instance.seen = nil
    -- A learned spell's base follows the real tick gap, undone for haste.
    if instance.fromLearn and instance.lastTick and multiple >= 1 then
        local haste = Learn.Haste()
        if haste then
            local sample = ((now - instance.lastTick) / multiple) * (1 + haste / 100)
            for _, spellID in ipairs(SpellsOf(instance)) do Learn.Nudge(spellID, sample) end
        end
    end
    instance.lastTick = now
    -- A 0 tick (absorbed, full overheal) says nothing about the tick size.
    local normal = Streams.NormalAmount(amount, flagText)
    if normal and normal > 0 then instance.lastAmount = normal end
    instance.deadline = now + 3 * instance.period
    if instance == channel then channelTickAt = now end
end

-- Casts ----------------------------------------------------------------------------

-- A learned spell cast in the same burst as a learned instance of the same kind,
-- school and base period (a macro, one button casting two) joins that instance:
-- one set of ticks, not two competing ones. Returns whether it joined.
local function MergeBurst(key, castID, spell, hot, now)
    local base = BasePeriod(spell.period, spell.hasted)
    for _, instance in ipairs(instances[key] or {}) do
        if instance.icons and not instance.channel and instance.hot == hot and instance.school == spell.school
            and math.abs(now - instance.castAt) <= CAST_BURST and Learn.PeriodsAgree(instance.base, base) then
            instance.icons[#instance.icons + 1] = castID
            return true
        end
    end

    return false
end

-- Adoption: a learned spell that owns a running stream takes it over, so its instance
-- keeps the stream's phase and the next tick is already shown.

-- Whether learned spell `castID` (entry `spell`) could own `stream`: same school, one of
-- its owners, and a period that agrees with the spell's real one.
local function Fits(stream, castID, spell)
    if stream.school ~= spell.school or not Learn.PeriodsAgree(stream.period, BasePeriod(spell.period, spell.hasted)) then
        return false
    end
    for _, owner in ipairs(stream.owners) do
        if owner == castID then return true end
    end

    return false
end

-- The key's live stream that `castID` fits best (closest period), or nil.
local function StreamFor(key, castID, spell, now)
    local base = BasePeriod(spell.period, spell.hasted)
    local best, bestGap
    for _, stream in ipairs(Streams.Live(key, now)) do
        local gap = math.abs(stream.period - base)
        if Fits(stream, castID, spell) and (not bestGap or gap < bestGap) then best, bestGap = stream, gap end
    end

    return best
end

-- The stream's instance, only while it is still listed (a dead one must not swallow icons).
local function AliveInstance(stream)
    for _, listed in ipairs(instances[stream.key] or {}) do
        if listed == stream.instance then return listed end
    end
end

-- `sorted` (OnLearned) keeps the icons in castID order, whichever spell was learned first.
local function AddIcon(instance, spellID, sorted)
    if HasIcon(instance, spellID) then return end
    instance.icons[#instance.icons + 1] = spellID
    if sorted then
        table.sort(instance.icons)
        instance.icon = instance.icons[1]
    end
end

-- A learned instance on a running stream. It starts with the stream's last hit as its
-- lastTick, so a refresh or a dead target never counts as a miss; its first matched
-- tick still counts as a hit (`hitDue`).
local function AdoptInstance(key, castID, spell, stream, castAt, now)
    local hot = spell.mode == "hot"
    local instance = { castID = castID, icon = spell.icon, school = spell.school, period = stream.period,
        base = BasePeriod(spell.period, spell.hasted), castAt = castAt, deadline = now + 3 * stream.period,
        lastTick = stream.lastAt, lastAmount = stream.lastAmount, learned = not hot, hot = hot,
        fromLearn = true, icons = { castID }, stream = stream, hitDue = true }
    stream.instance = instance
    AddInstance(key, instance)
end

-- A learned cast on a key with a stream it owns: join the stream's instance (its next
-- tick is a hit for the new spell too), or adopt the stream. Returns whether it did.
local function JoinStream(key, castID, spell, now)
    local stream = StreamFor(key, castID, spell, now)
    if not stream then return false end
    local alive = AliveInstance(stream)
    if alive then
        AddIcon(alive, castID)
        alive.hitDue = true
    else
        AdoptInstance(key, castID, spell, stream, now, now)
    end

    return true
end

function Tracker.OnCast(unit, castID, now)
    if not Plain(castID) then return end
    Housekeeping(now)
    if unit == "player" then
        -- A missing API reads as not harmful: no miss cast, no log entry.
        local harmful = C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(castID)
        if Plain(harmful) and harmful then missCasts[#missCasts + 1] = { castID = castID, at = now } end
        local helpful = C_Spell.IsSpellHelpful and C_Spell.IsSpellHelpful(castID)
        LogCast(castID, now, harmful, helpful)
    end
    -- The entry came from Learn.Get.
    local learned = Spells[castID] == nil
    local spell = Spells[castID] or Learn.Get(castID)
    if not spell then return end
    if spell.mode == "target" or spell.mode == "hot" then
        local hot = spell.mode == "hot"
        -- A HoT's key is the heal unit's token, a DoT's the target plate.
        local key
        if hot then key = Tracker.HealUnit() else key = TargetPlate() end
        if not key then return end
        local instance = FindInstance(key, castID)
        if instance and learned then
            -- Recast: the next tick may keep the phase or restart it at now + period.
            instance.deadline = math.max(instance.deadline, now + 3 * instance.period)
            instance.restartAt = now
        elseif instance then
            -- Refresh of a table spell: the running tick timer is kept.
            instance.deadline = math.max(instance.deadline, now + spell.duration + instance.period)
        elseif learned and (MergeBurst(key, castID, spell, hot, now) or JoinStream(key, castID, spell, now)) then
            return
        else
            local period = InstancePeriod(spell, learned)
            local lastLoose = loose[key] and loose[key][spell.school]
            -- A HoT never counts misses.
            AddInstance(key, { castID = castID, icon = spell.icon, school = spell.school, period = period,
                base = BasePeriod(spell.period, spell.hasted), castAt = now, deadline = now + period + FIRST_TICK_SLACK,
                busy = lastLoose ~= nil and now - lastLoose <= RHYTHM_BUSY, learned = learned and not hot, hot = hot,
                fromLearn = learned, icons = learned and { castID } or nil })
        end
    elseif spell.mode == "spread" then
        -- A recast while the window is open restarts it (one window per spell).
        for _, spread in ipairs(spreads) do
            if spread.castID == castID then
                spread.ends = now + SPREAD_WINDOW
                return
            end
        end
        spreads[#spreads + 1] = { castID = castID, spreads = spell.spreads, ends = now + SPREAD_WINDOW, armed = {} }
    elseif spell.mode == "area" then
        local ends = now + spell.duration + AREA_SLACK
        for _, area in ipairs(areas) do
            if area.castID == castID then
                area.ends = math.max(area.ends, ends)
                return
            end
        end
        areas[#areas + 1] = { castID = castID, icon = spell.icon, school = spell.school,
            period = EffectivePeriod(spell.period, spell.hasted, spell.icon), ends = ends }
    end
    -- channel spells start in OnChannelStart
end

-- `castGUID` (kept when plain) ties the channel to its own CHANNEL_STOP.
function Tracker.OnChannelStart(castID, now, castGUID)
    if not Plain(castID) then return end
    Housekeeping(now)
    local plate = TargetPlate()
    if plate then Streams.LogCast(plate, castID, "channel", now) end
    local spell = Spells[castID] or Learn.Get(castID)
    if not spell then return end
    if spell.mode ~= "channel" then return end
    DropChannel()
    if not plate then return end
    local learned = Spells[castID] == nil
    local period = InstancePeriod(spell, learned)
    channel = { castID = castID, icon = spell.icon, school = spell.school, period = period, castAt = now,
        deadline = now + (spell.duration or CHANNEL_DEADLINE) + FIRST_TICK_SLACK, channel = true, heals = spell.heals,
        plate = plate, castGUID = Plain(castGUID) and castGUID or nil, learned = learned, fromLearn = learned,
        icons = learned and { castID } or nil }
    AddInstance(plate, channel)
end

-- Whether a CHANNEL_STOP's `castGUID` names a cast other than `record`'s.
local function NamesOtherCast(record, castGUID)
    return record.castGUID ~= nil and Plain(castGUID) and castGUID ~= record.castGUID
end

-- A stop naming another cast (a late stop of an earlier channel) is ignored.
function Tracker.OnChannelStop(now, castGUID)
    if channel and NamesOtherCast(channel, castGUID) then return end
    -- A learned channel that lasted past its first due tick and never ticked is a miss.
    if channel and channel.learned and not channelTickAt
        and now - channel.castAt >= channel.period + Tolerance(channel.period) then
        Learn.Missed(channel.castID)
    end
    DropChannel()
end

-- Hits -----------------------------------------------------------------------------

-- The meter saw the player hit `plate`: arm it in every open spread window.
function Tracker.OnMeterHit(plate, now)
    for _, spread in ipairs(spreads) do
        if spread.ends >= now then spread.armed[plate] = true end
    end
end

-- A miss event hit `plate`: a learned DoT still waiting for its first tick, cast
-- just before, may have been resisted. It must not count as a missing tick.
function Tracker.OnMiss(plate, now)
    for _, instance in ipairs(instances[plate] or {}) do
        if instance.learned and not instance.lastTick and now - instance.castAt <= MISS_WINDOW then
            instance.missed = true
        end
    end
end

-- Whether a hit on `plate` falls on the tick timing of one of its instances.
function Tracker.QualifiesByPhase(plate, school, amount, flagText, now)
    Housekeeping(now)
    if not Plain(school) then return false end
    for _, instance in ipairs(instances[plate] or {}) do
        if Phase(instance, school, amount, flagText, now) then return true end
    end
    return false
end

-- The tick spell ID behind a hit, when exactly one expectation fits (the first of a
-- burst whose spells look alike); Tracker.UNKNOWN when it is yours but the spell
-- cannot be told (several fit, or a burst's textures differ); nil when none fits.
function Tracker.Identify(plate, school, amount, flagText, now)
    Housekeeping(now)
    if not Plain(school) then return nil end
    local found = Candidates(plate, school, amount, flagText, now)
    local match = found[1]
    if #found ~= 1 then
        -- A first tick that fits several spells is no evidence against any of them;
        -- an instance it did not fit learns nothing from it.
        if #found >= 2 then
            for _, candidate in ipairs(found) do
                local instance = candidate.instance
                if instance and instance.learned and not instance.lastTick then instance.ambiguous = true end
            end
        end
        Remember(plate, school, now)
        if #found >= 2 then return Pick(found) end
        return nil
    end
    if match.instance then
        Ticked(match.instance, match.multiple, amount, flagText, now)
        return Pick(found)
    elseif match.spread then
        local entry = match.entry
        local basePeriod, hasted = entry.period or SPREAD_PERIOD, entry.period == nil or entry.hasted
        local period = EffectivePeriod(basePeriod, hasted, entry.icon)
        -- Its first tick stands in for the cast, so the next tick can still
        -- teach the rhythm when the expected period is off.
        AddInstance(plate, { castID = match.spread.castID, icon = entry.icon, school = school, period = period,
            base = BasePeriod(basePeriod, hasted), castAt = now,
            lastAmount = Streams.NormalAmount(amount, flagText), deadline = now + 3 * period })
    end
    return Pick(found)
end

-- The HoT tick spell ID behind a heal on `unit` (a group token), when exactly one
-- instance there fits; Tracker.UNKNOWN when several fit or a burst's textures differ;
-- else nil. Only that unit's instances count: never areas or spreads, which belong
-- to enemy plates.
function Tracker.IdentifyHeal(unit, school, amount, flagText, now)
    Housekeeping(now)
    if not Plain(school) then return nil end
    local found = InstanceCandidates(unit, school, amount, flagText, now)
    if #found ~= 1 then
        Remember(unit, school, now)
        if #found >= 2 then return Pick(found) end
        return nil
    end
    local match = found[1]
    Ticked(match.instance, match.multiple, amount, flagText, now)
    return Pick(found)
end

-- The group changed: party tokens point at other people now. The player stays.
function Tracker.OnRosterChanged()
    for index = 1, 4 do
        local unit = "party" .. index
        instances[unit], loose[unit] = nil, nil
        Streams.Drop(unit)
    end
end

-- A harmful player cast at most 1.5 s old not yet used for a miss (oldest first).
function Tracker.TakeMissCast(now)
    Housekeeping(now)
    local cast = table.remove(missCasts, 1)
    return cast and cast.castID
end

-- The channel's tick spell when its tick landed in this same frame (Drain Life
-- heals right after its damage tick); else nil.
function Tracker.ChannelHeal(now)
    if channel and channel.heals and channelTickAt == now then return channel.icon end
end

-- Plates hide (camera, range, line of sight) while their mob lives on. With a plain
-- GUID, a plate's instances (not the channel), loose hits and stream state are parked
-- under it for PARK_LIFE seconds and follow the mob to the plate frame it shows on next.

local function PruneParked(now)
    for guid, entry in pairs(parked) do
        if now - entry.at > PARK_LIFE then parked[guid] = nil end
    end
end

-- `guid`: the plate's mob, plain, or nil (nothing is parked).
function Tracker.OnPlateRemoved(plate, guid, now)
    if guid ~= nil then
        PruneParked(now)
        local list = {}
        for _, instance in ipairs(instances[plate] or {}) do
            if instance ~= channel then list[#list + 1] = instance end
        end
        parked[guid] = { at = now, instances = list, loose = loose[plate], streams = Streams.Take(plate) }
    end
    instances[plate] = nil
    loose[plate] = nil
    Streams.Drop(plate)
    for _, spread in ipairs(spreads) do spread.armed[plate] = nil end
    if channel and channel.plate == plate then channel, channelTickAt = nil, nil end
end

-- The mob `guid` (plain) shows on `plate`: what was parked for it moves there. An instance
-- still waiting for its first tick counts no miss, since that tick may have landed unseen;
-- one whose deadline passed while hidden goes at the next Housekeeping.
function Tracker.OnPlateAdded(plate, guid, now)
    PruneParked(now)
    local entry = parked[guid]
    if not entry then return end
    parked[guid] = nil
    for _, instance in ipairs(entry.instances) do
        if not instance.lastTick then instance.missed = true end
        AddInstance(plate, instance)
    end
    loose[plate] = entry.loose
    Streams.Put(plate, entry.streams)
end

function Tracker.Reset()
    instances, areas, spreads, missCasts, loose, parked = {}, {}, {}, {}, {}, {}
    channel, channelTickAt = nil, nil
    Streams.Reset()
end

-- Called when Learn stores a new spell (ascending ids): every live stream the spell owns
-- gets an instance, or the spell's icon on the one already there. A channel waits for
-- its next CHANNEL_START.
function Tracker.OnLearned(spellID, now)
    local spell = Learn.Get(spellID)
    if not spell or (spell.mode ~= "target" and spell.mode ~= "hot") then return end
    local hot = spell.mode == "hot"
    for _, key in ipairs(Streams.Keys()) do
        -- unit tokens are strings, plates are frames
        if (type(key) == "string") == hot then
            for _, stream in ipairs(Streams.Live(key, now)) do
                if Fits(stream, spellID, spell) then
                    local alive = AliveInstance(stream)
                    if alive then AddIcon(alive, spellID, true) else AdoptInstance(key, spellID, spell, stream, stream.birth, now) end
                end
            end
        end
    end
end
