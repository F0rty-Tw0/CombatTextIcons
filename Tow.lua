-- Combat Text Icons: Touch of Weakness (WoW Forever only). Its cast arms the buff's proc ID for 600 s; Core holds a
-- shadow `?` hit while armed and draws it as the proc when no heal on you comes with it (Core.HoldTow). Not a lock: no
-- Locked.Observe. Note arms, Armed reads the arm, Spent clears the arm a drawn proc used.

local _, ns = ...

local Tow = {}
ns.Tow = Tow

-- Touch of Weakness (Forever): the buff's cast ID -> the ID of the proc row the meter names (S10 run 1 and S11 run 1:
-- 2652 -> 2943 and 19261 -> 19249, 7 of 7 procs; the other ranks are Classic data, unconfirmed: a wrong pair only
-- changes which icon the proc draws).
local TOW_PROCS = { [2652] = 2943, [19261] = 19249, [19262] = 19251, [19264] = 19252, [19265] = 19253, [19266] = 19254 }
local TOW_ARM = 600 -- the buff's duration in seconds (S11 run 1: `AURA player add id=19261 ... dur=600`)

-- The armed Touch of Weakness { proc = the proc's spell ID, cast = its cast time }, or nil. Session-only: a fight's end
-- keeps it, since 3 of S11 run 1's 5 buffs were cast before the pull.
local armed

-- A player cast of `spellID` at `now`: a Touch of Weakness rank arms (or re-arms) its proc; any other spell changes
-- nothing.
function Tow.Note(spellID, now)
    if not ns.IsForever then return end

    local proc = TOW_PROCS[spellID]
    if proc then armed = { proc = proc, cast = now } end
end

-- The proc ID armed at `now`, or nil when none is armed or the buff's 600 s are over.
function Tow.Armed(now)
    if not ns.IsForever then return end
    if not armed or now - armed.cast > TOW_ARM then return end

    return armed.proc
end

-- A hit held at `heldAt` was drawn as `procID`: the arm that named it is spent, unless a recast came after the hit
-- (that cast's buff is a new charge).
function Tow.Spent(procID, heldAt)
    if not ns.IsForever then return end
    if armed and armed.proc == procID and armed.cast <= heldAt then armed = nil end
end
