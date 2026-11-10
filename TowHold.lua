-- Combat Text Icons: the Touch of Weakness and drain hold (WoW Forever only). A solo secret shadow hit nothing named
-- waits to see whether a heal on you comes with it while the proc is armed (Tow.lua) or one proc row is saved
-- (LockedHeals.OnlyRow): the 1260198 drain's heal does, the proc's does not. The hit route (HitRoute.lua) asks Hold;
-- Decide, Release and Healed draw the held hit through its question mark route (HitRoute.QuestionHeld), as the proc,
-- as the drain's row or as '?'.

local _, ns = ...

local HitRoute = ns.HitRoute

local TowHold = {}
ns.TowHold = TowHold

-- The one solo secret shadow hit held while Touch of Weakness is armed or one proc row is saved (Hold), kept apart from
-- the route's held hits so Core.FlushMates never draws it: { at, plate, school, amount, flagText, cast, candidates, proc
-- (the proc ID armed when it was held, or nil), entry (its frameHits entry, which Decide tags), healed (a heal on its
-- stamp came; Healed draws it when that heal is flushed), healAt (that heal's stamp) }, or nil. Decide draws it as the
-- proc, Release gives it back to the question mark or marks it healed, Healed draws a healed one as the row that
-- claimed its heal, and `/cti off` drops it (Drop).
local towHeld

-- A Touch of Weakness proc's hit and the 1260198 drain are both shadow hits `?`; the drain's `HEAL player` line comes
-- on its hit's stamp (32 of 35) or 0.096-0.107 s later (3), every proc's had none within 0.5 s (S10 + S11 run 1).
local TOW_DRAIN = 0.15 -- a heal this soon after the held hit is the drain's
local TOW_TIMER = 0.2  -- decides a held hit no event has: later than TOW_DRAIN, so it never fires early

-- The held candidate (towHeld) leaves the hold first, so it is decided once. A healed one draws '?' (Healed settles it
-- before an event gets here); an unhealed one with a proc ID is Touch of Weakness's proc: drawn through Question with
-- the proc's ID, and the arm spent unless a recast came after the hold; any other draws '?'. Decides only when `now` is
-- more than TOW_DRAIN past the hit, or at any age with `fightEnd`.
function TowHold.Decide(now, fightEnd)
    local candidate = towHeld
    if not candidate then return end
    if not fightEnd and now - candidate.at <= TOW_DRAIN then return end

    towHeld = nil
    if candidate.healed or not candidate.proc then return HitRoute.QuestionHeld(candidate) end

    HitRoute.QuestionHeld(candidate, candidate.proc, "tow")
    ns.Tow.Spent(candidate.proc, candidate.at)
end

-- A `HEAL player` came within TOW_DRAIN of the held candidate. A later stamp is not its heal (the proc fit needs an own
-- hit on the heal's stamp, which is another hit), nor is any heal when no row is saved: it draws as any unexplained hit
-- (Question) and Touch of Weakness stays armed. A heal on its own stamp with one row saved may be the drain's: the
-- candidate is marked healed and waits for that heal's flush (Healed). A healed one ignores further heals.
function TowHold.Release(now)
    local candidate = towHeld
    if not candidate or candidate.healed or now - candidate.at > TOW_DRAIN then return end

    local row = ns.LockedHeals.OnlyRow()
    if row and now <= candidate.at then
        candidate.healed, candidate.healAt = true, now

        return
    end

    towHeld = nil
    HitRoute.QuestionHeld(candidate)
end

-- The flush of the heals on stamp `at` (PlayerHits.FlushHeals). `claimedRow`: the one saved proc row when a claim of that
-- frame named it, else nil. A healed candidate waiting on that stamp draws as that row (route `drain`), or '?' without
-- one. Touch of Weakness stays armed either way.
function TowHold.Healed(at, claimedRow)
    local candidate = towHeld
    if not candidate or not candidate.healed or candidate.healAt ~= at then return end

    towHeld = nil
    if claimedRow then return HitRoute.QuestionHeld(candidate, claimedRow, "drain") end

    HitRoute.QuestionHeld(candidate)
end

-- Holds a solo secret shadow hit nothing named, to see whether a heal on you comes with it (Decide, Release, Healed),
-- and returns true when it holds the hit, false when the route goes on. It is held while Touch of Weakness is armed
-- or exactly one proc row is saved, and no candidate is held yet. A heal on you already waiting on the hit's own stamp
-- (S10 run 1 235793.592: the drain's heal is logged before its hit) blocks the hold unless a row is saved; then the
-- candidate is healed at once. `entry`: the hit's frame entry, the newest (Wound added it).
function TowHold.Hold(plate, school, amount, flagText, now, cast, candidates, entry)
    if school ~= 32 or towHeld then return false end

    local proc = ns.Tow.Armed(now)
    local row = ns.LockedHeals.OnlyRow()
    local healWaits = ns.PlayerHits.HealWaits(now)
    if not (proc or row) or (healWaits and not row) then return false end

    towHeld = { at = now, plate = plate, school = school, amount = amount, flagText = flagText, cast = cast,
        candidates = candidates, proc = proc, entry = entry, healed = healWaits, healAt = healWaits and now or nil }
    if ns.Debug then ns.Debug(proc and "  .. tow" or "  .. drain") end
    pcall(C_Timer.After, TOW_TIMER, function() TowHold.Decide(GetTime()) end)

    return true
end

-- `/cti off` drops the held candidate: the timer then decides nothing.
function TowHold.Drop()
    towHeld = nil
end
