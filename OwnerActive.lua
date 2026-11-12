-- Combat Text Icons: whether the Owner path is live. Forever, in a party, with the Combat Log's own-action lines on and
-- its "My actions" filter picked, and the lines still arriving. Owner.lua calls OnLine and OnFlushAll (set here) when a
-- live line arrives and when the fight's end settles everything.

local _, ns = ...

local Owner = ns.Owner

local MY_ACTIONS = "My actions"
local CAST_LIMIT = 3 -- casts with no line in between that mean the lines have stopped
local CHECK_DELAY = 2 -- seconds after the third cast before a missing line counts as dead

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local active = false
local switchedOn -- Owner switched the lines on, so Owner switches them off again
local lastState -- KeepLinesOn's last answer: on / switched / err / none
local count = 0 -- casts since the last live line
local dead = false -- the lines stopped while casts went on
local checkQueued = false

-- The lines' state, switching them on when off: on / switched / err / none (no C_CombatLog call).
local function SwitchOn()
    local log = C_CombatLog
    if not (log and log.SetFilteredEventsEnabled and log.AreFilteredEventsEnabled) then return "none" end
    local ok, on = pcall(log.AreFilteredEventsEnabled)
    if ok and Plain(on) and on == true then return "on" end
    if not pcall(log.SetFilteredEventsEnabled, true) then return "err" end
    switchedOn = true

    return "switched"
end

function Owner.KeepLinesOn()
    lastState = SwitchOn()

    return lastState
end

local function IsLogShown()
    local ok, showing = pcall(function() return _G.COMBATLOG:IsShown() end)

    return ok and Plain(showing) and showing == true
end

-- Switches the lines back off when Owner switched them on and the Combat Log tab is hidden.
function Owner.LinesOff()
    if switchedOn and not IsLogShown() then pcall(C_CombatLog.SetFilteredEventsEnabled, false) end
    switchedOn = nil
end

local function IsParty()
    if not (ns.HitRoute.InGroup() and IsInRaid) then return false end
    local ok, raid = pcall(IsInRaid)

    return ok and Plain(raid) and raid == false
end

local function IsMyActions()
    local all = _G.Blizzard_CombatLog_Filters
    local filters = type(all) == "table" and all.filters
    local filter = type(filters) == "table" and filters[all.currentFilter]

    return type(filter) == "table" and filter.name == MY_ACTIONS
end

local function Conditions()
    local linesOn = lastState == "on" or lastState == "switched"

    return ns.IsForever and IsParty() and linesOn and IsMyActions()
end

local function Compute()
    return Conditions() and not dead
end

-- Recomputes and caches the answer. A flip to false releases everything held, then Blizzard's text is synced; the cache
-- is stored first so a route that asks again inside the release gets the new answer.
function Owner.Active()
    local value = Compute()
    if value == active then return active end
    active = value
    if not value then Owner.Flush(nil) end
    ns.Core.SyncBlizzard()

    return active
end

function Owner.IsActive()
    return active
end

local function Check()
    checkQueued = false
    if count >= CAST_LIMIT and Conditions() then
        dead = true
        Owner.Active()
    end
end

-- A cast of yours. The third one with no line since asks again 2 s later whether a line came.
function Owner.Cast()
    count = count + 1
    if count == CAST_LIMIT and not checkQueued then
        checkQueued = true
        C_Timer.After(CHECK_DELAY, Check)
    end
end

function Owner.OnLine()
    count = 0
    if not dead then return end
    dead = false
    Owner.Active()
end

function Owner.OnFlushAll()
    count = 0
end
