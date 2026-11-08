-- Combat Text Icons: the Touch of Weakness hold (WoW Forever only). A solo secret shadow hit nothing named while the
-- proc is armed (Tow.lua) waits to see whether a heal on you comes with it: the drain's does, the proc's does not.
-- The hit route (HitRoute.lua) asks Proc and Hold; Decide and Release draw the held hit through its question mark
-- route (HitRoute.QuestionHeld).

local _, ns = ...

local HitRoute = ns.HitRoute

local TowHold = {}
ns.TowHold = TowHold

-- The one solo secret shadow hit held while Touch of Weakness is armed (Hold), kept apart from the route's held hits
-- so Core.FlushMates never draws it: { at, plate, school, amount, flagText, cast, candidates, proc (the proc ID armed
-- when it was held), entry (its frameHits entry, which Decide tags) }, or nil. Decide draws it as the proc, Core.Heal
-- gives it back to the question mark (Release), and `/cti off` drops it (Drop).
local towHeld

-- A Touch of Weakness proc's hit and the 1260198 drain are both shadow hits `?`; the drain's `HEAL player` line comes
-- on its hit's stamp (32 of 35) or 0.096-0.107 s later (3), every proc's had none within 0.5 s (S10 + S11 run 1).
local TOW_DRAIN = 0.15 -- a heal this soon after the held hit is the drain's
local TOW_TIMER = 0.2  -- decides a held hit no event has: later than TOW_DRAIN, so it never fires early

-- The held Touch of Weakness candidate (towHeld) is the proc: drawn through Question with the proc's ID, and the arm
-- spent unless a recast came after the hold. It leaves the hold first, so it is decided once. Decides only when `now`
-- is more than TOW_DRAIN past the hit, or at any age with `fightEnd`.
function TowHold.Decide(now, fightEnd)
    local candidate = towHeld
    if not candidate then return end
    if not fightEnd and now - candidate.at <= TOW_DRAIN then return end

    towHeld = nil
    HitRoute.QuestionHeld(candidate, candidate.proc, "tow")
    ns.Tow.Spent(candidate.proc, candidate.at)
end

-- The held candidate is the drain's: a `HEAL player` came within TOW_DRAIN of it. It draws as any unexplained hit
-- (Question) and Touch of Weakness stays armed.
function TowHold.Release(now)
    local candidate = towHeld
    if not candidate or now - candidate.at > TOW_DRAIN then return end

    towHeld = nil
    HitRoute.QuestionHeld(candidate)
end

-- The proc ID a solo secret shadow hit at `now` may be, or nil: Touch of Weakness is armed, no candidate is held yet,
-- and no `HEAL player` already waits on the hit's own stamp (S10 run 1 235793.592: the drain's heal is logged before
-- its hit).
function TowHold.Proc(school, now)
    local proc = school == 32 and ns.Tow.Armed(now)
    local healWaits = ns.PlayerHits.HealWaits(now)
    if not proc or towHeld or healWaits then return end

    return proc
end

-- Holds a solo secret shadow hit nothing named, while Touch of Weakness is armed, to see whether a heal on you comes
-- with it (Decide, Release). `proc`: Proc's answer. `entry`: the hit's frame entry, the newest (Wound added it).
function TowHold.Hold(plate, school, amount, flagText, now, cast, candidates, proc, entry)
    towHeld = { at = now, plate = plate, school = school, amount = amount, flagText = flagText, cast = cast,
        candidates = candidates, proc = proc, entry = entry }
    if ns.Debug then ns.Debug("  .. tow") end
    pcall(C_Timer.After, TOW_TIMER, function() TowHold.Decide(GetTime()) end)
end

-- `/cti off` drops the held candidate: the timer then decides nothing.
function TowHold.Drop()
    towHeld = nil
end
