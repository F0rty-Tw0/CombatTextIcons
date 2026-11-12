-- Combat Text Icons: who owns a grouped hit. The Combat Log's own-action lines (lines) and the meter's events (events)
-- are paired by their stamps (Owner.Match, a pure function). A grouped hit waits here (Owner.Hit) until a line owns it
-- or its stamp is too old, then goes to HitRoute (Owner.Flush).
-- Run 2, replayed offline by the script clog_match.lua: 36 lines paired cleanly on one stamp, 1 needed the ranking and
-- 1 needed the 0.05 s window.

local _, ns = ...

local Owner = {}
ns.Owner = Owner

local SAME = 0.0005 -- two stamps this close are one stamp
local LATE = 0.05 -- a line and a hit this far apart still pair when nothing shares their stamp
local SLACK = 1e-9 -- float stamps like 10.05 - 10.0 must still count as 0.05

local HEAL_SCORE, OWN_SCORE, TARGET_SCORE, BOTH_SCORE = 3, 4, 2, 1

-- A heal scores 3. A hit scores 4 for an own school (every school when own is nil), 2 for the target, and 1 more for both.
local function Score(event, own)
    if event.kind == "heal" then return HEAL_SCORE end
    local isOwn = own == nil or own[event.school]
    local score = isOwn and OWN_SCORE or 0
    if event.isTarget then score = score + TARGET_SCORE end
    if isOwn and event.isTarget then score = score + BOTH_SCORE end

    return score
end

local function IsSame(a, b)
    return math.abs(a - b) < SAME
end

local function CountSame(items, now)
    local count = 0
    for _, item in ipairs(items) do
        if IsSame(item.now, now) then count = count + 1 end
    end

    return count
end

-- The untaken event on the line's stamp with the best score, the earliest arrival on a tie.
local function BestSame(line, events, own, taken)
    local best, bestScore
    for index, event in ipairs(events) do
        local score = Score(event, own)
        local isCandidate = not taken[index] and IsSame(event.now, line.now)
        local beatsBest = bestScore == nil or score > bestScore
        if isCandidate and beatsBest then best, bestScore = index, score end
    end

    return best
end

-- Each line takes the best event on its own stamp. A line is clean when it took one and no other event shares the stamp
-- beyond the lines that do.
local function PassOne(lines, events, own, taken, clean)
    for lineIndex, line in ipairs(lines) do
        local eventIndex = BestSame(line, events, own, taken)
        if eventIndex then taken[eventIndex] = lineIndex end
        local fitsStamp = CountSame(events, line.now) <= CountSame(lines, line.now)
        if eventIndex and fitsStamp then clean[lineIndex] = true end
    end
end

-- Whether a beats b by score, then by distance to the line, then by stamp. Equal keys keep the earlier arrival.
local function IsCloser(a, b, lineNow)
    if a.score ~= b.score then return a.score > b.score end
    local distA, distB = math.abs(a.event.now - lineNow), math.abs(b.event.now - lineNow)
    if distA ~= distB then return distA < distB end

    return a.event.now < b.event.now
end

local function BestLate(line, events, own, taken)
    local best
    for index, event in ipairs(events) do
        local gap = event.now - line.now
        local isInWindow = math.abs(gap) <= LATE + SLACK
        local candidate = { index = index, event = event, score = Score(event, own) }
        local isCandidate = not taken[index] and event.kind == "hit" and isInWindow
        if isCandidate and (best == nil or IsCloser(candidate, best, line.now)) then best = candidate end
    end

    return best and best.index
end

-- A line that took nothing takes the best untaken hit within 0.05 s of its stamp. Heals never pair here.
local function PassTwo(lines, events, own, taken)
    local paired = {}
    for _, lineIndex in pairs(taken) do paired[lineIndex] = true end
    for lineIndex, line in ipairs(lines) do
        local eventIndex = not paired[lineIndex] and BestLate(line, events, own, taken)
        if eventIndex then taken[eventIndex] = lineIndex end
    end
end

-- Owner.Match(lines, events, own): taken[eventIndex] = lineIndex, clean[lineIndex] = true.
-- lines = { { now }, ... }; events = { { kind = "hit" | "heal", now, school, isTarget }, ... }; own = a set of schools,
-- or nil for every school.
function Owner.Match(lines, events, own)
    local taken, clean = {}, {}
    PassOne(lines, events, own, taken, clean)
    PassTwo(lines, events, own, taken)

    return taken, clean
end

local DebugLog = ns.DebugLog
local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local lines = {} -- the Combat Log's own-action lines, { now }, in arrival order
local hits = {} -- grouped hits held until their stamp settles, in arrival order
local heals = {} -- heals not yet decided: { kind = "heal", now, school, onYou, index }
local decided = {} -- decided[at][index] = whether a line owned the index-th heal on you at `at`
local flushing = false

-- The own schools for the matcher: every school counts as own when none is locked yet.
local function Own()
    local schools = ns.Locked.Schools()
    if next(schools) == nil then return nil end

    return schools
end

local function Select(items, isKept)
    local kept = {}
    for _, item in ipairs(items) do
        if isKept(item) then kept[#kept + 1] = item end
    end

    return kept
end

local function IsTarget(unit)
    local ok, isTarget = pcall(UnitIsUnit, unit, "target")

    return ok and Plain(isTarget) and isTarget == true
end

local function LogHit(hit)
    if not ns.Debug then return end
    local unit = hit.unit
    ns.Debug("HIT %s school=%s amount=%s flag=%s fps=%.0f threat=%s group=%s npc=%s target=%s", unit,
        DebugLog.ShowValue(hit.school), DebugLog.ShowValue(hit.amount), DebugLog.ShowValue(hit.flagText), GetFramerate(),
        DebugLog.ShowThreat(unit), DebugLog.ShowGroup(), DebugLog.ShowNPC(unit), DebugLog.ShowIsTarget(unit))
end

-- A Combat Log line of yours. Only order 0 (this frame's) counts; a backlog line pairs nothing. The flush is queued so
-- a line that comes before any hit still gets its frame-end release.
function Owner.Line(order, now)
    if not Plain(order) or not Plain(now) or order ~= 0 then return end
    lines[#lines + 1] = { now = now }
    ns.PlayerHits.QueueFlush()
end

-- A grouped hit, held until its stamp settles. Its HIT line is written now, as HitRoute would have written it.
function Owner.Hit(plate, unit, flagText, amount, school, now)
    local hit = { kind = "hit", plate = plate, unit = unit, flagText = flagText, amount = amount, school = school,
        now = now, isTarget = IsTarget(unit) }
    hits[#hits + 1] = hit
    LogHit(hit)
    ns.PlayerHits.QueueFlush()
end

-- How many heals on you already sit on the stamp, held or decided.
local function CountOnYou(now)
    local held = Select(heals, function(heal) return heal.onYou and heal.now == now end)

    return #held + #(decided[now] or {})
end

-- A heal on `unit`. Only a heal on you takes an index (1-based per stamp); the others still compete for a line.
function Owner.Heal(unit, now)
    local onYou = unit == "player"
    local index = onYou and 1 + CountOnYou(now) or nil
    heals[#heals + 1] = { kind = "heal", now = now, school = 1, onYou = onYou, index = index }
end

local function Decide(heal)
    if not heal.onYou then return end
    decided[heal.now] = decided[heal.now] or {}
    decided[heal.now][heal.index] = heal.owned == true
end

-- Pass 1 over the settled stamps (before `cut`): lines pair with the hits and heals on their own stamp. Every settled
-- heal is decided and leaves; a taken line is spent.
local function PassOneSettled(cut)
    local settledLines = Select(lines, function(line) return line.now < cut end)
    local settledHeals = Select(heals, function(heal) return heal.now < cut end)
    local events = Select(hits, function(hit) return not hit.owned and hit.now < cut end)
    for _, heal in ipairs(settledHeals) do events[#events + 1] = heal end
    local taken = {}
    PassOne(settledLines, events, Own(), taken, {})
    local spent = {}
    for eventIndex, lineIndex in pairs(taken) do
        events[eventIndex].owned = true
        spent[settledLines[lineIndex]] = true
    end
    for _, heal in ipairs(settledHeals) do Decide(heal) end
    heals = Select(heals, function(heal) return heal.now >= cut end)
    lines = Select(lines, function(line) return not spent[line] end)
end

-- Pass 2 over everything left, unsettled stamps too; then the lines still unpaired and too old to pair are dropped.
local function PassTwoLeft(cut)
    local open = Select(hits, function(hit) return not hit.owned end)
    local taken = {}
    PassTwo(lines, open, Own(), taken)
    local spent = {}
    for eventIndex, lineIndex in pairs(taken) do
        open[eventIndex].owned = true
        spent[lines[lineIndex]] = true
    end
    lines = Select(lines, function(line) return not spent[line] and cut - line.now <= LATE + SLACK end)
end

local function OldestStamp()
    local oldest = hits[1].now
    for _, hit in ipairs(hits) do
        if hit.now < oldest then oldest = hit.now end
    end

    return oldest
end

local function IsOwned(hit) return hit.owned == true end

-- Whether the oldest stamp may leave: it is before `cut`, and forced, final, fully owned or too old to wait.
local function CanRelease(stamp, cut, now, force)
    if stamp >= cut then return false end
    local atStamp = Select(hits, function(hit) return hit.now == stamp end)
    local isOwned = #Select(atStamp, IsOwned) == #atStamp
    local isLate = cut - stamp > LATE + SLACK

    return force or now == nil or isOwned or isLate
end

-- A hit is judged at the time it happened (the route clock); a route that throws is logged and the release goes on.
local function Route(hit, stamp)
    ns.SetRouteClock(stamp)
    local ok, err = pcall(ns.HitRoute.Route, hit)
    ns.SetRouteClock(nil)
    if not ok and ns.Debug then ns.Debug("ROUTE error %s", tostring(err)) end
end

local function ReleaseStamp(stamp)
    local atStamp = Select(hits, function(hit) return hit.now == stamp end)
    hits = Select(hits, function(hit) return hit.now ~= stamp end)
    for _, hit in ipairs(atStamp) do
        if hit.owned then
            Route(hit, stamp)
        elseif ns.Debug then
            ns.Debug("  -> HIDDEN (not yours)")
        end
    end
end

-- Oldest stamp first; the first one that cannot leave holds the younger ones back. Each released stamp lets the waiting
-- heals draw (FlushHeals keeps a heal on a stamp not yet over).
local function Release(cut, now, force)
    while #hits > 0 do
        local stamp = OldestStamp()
        if not CanRelease(stamp, cut, now, force) then return end
        ReleaseStamp(stamp)
        ns.PlayerHits.FlushHeals(now)
    end
end

local DECIDED_KEEP = 2 -- seconds a decided heal stays readable

local function Prune(now)
    if not now then return end
    for at in pairs(decided) do
        if now - at > DECIDED_KEEP then decided[at] = nil end
    end
end

local function Run(now, force)
    local cut = now or math.huge
    PassOneSettled(cut)
    PassTwoLeft(cut)
    Release(cut, now, force)
    Prune(now)
end

-- The frame's end (`now`), a forced release, or the fight's end (`now` nil: everything settles). A call from inside a
-- release returns at once; a throw still frees the guard.
function Owner.Flush(now, force)
    if flushing then return end
    flushing = true
    local ok, err = pcall(Run, now, force)
    flushing = false
    if not ok then error(err, 0) end
end

-- Whether a hit held on a stamp up to `at` still waits.
function Owner.Pending(at)
    return #Select(hits, function(hit) return hit.now <= at end) > 0
end

function Owner.HealOwned(at, index)
    return decided[at] ~= nil and decided[at][index] == true
end

function Owner.Waiting()
    return #hits > 0 or #lines > 0 or #heals > 0
end

function Owner.PlateGone(plate)
    hits = Select(hits, function(hit) return hit.plate ~= plate end)
end

function Owner.Drop()
    lines, hits, heals, decided = {}, {}, {}, {}
end
