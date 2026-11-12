-- Combat Text Icons: who owns a grouped hit. The Combat Log's own-action lines (lines) and the meter's events (events)
-- are paired by their stamps, as a pure function with no game calls.
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
