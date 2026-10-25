-- Combat Text Icons: damage meter. CTI never resets or reads the meter while you
-- fight; Teacher.lua reads its finished session after combat. This module keeps
-- the meter types, the question-mark icon and whether the meter is usable.

local ADDON, ns = ...

local Meter = {}
ns.Meter = Meter

Meter.DAMAGE_DONE, Meter.HEALING_DONE, Meter.DAMAGE_TAKEN = 0, 2, 7

local UNKNOWN_ICON = 134400 -- question mark, for a hit whose spell is not known
Meter.UNKNOWN_ICON = UNKNOWN_ICON

local issecretvalue = issecretvalue or function() return false end

local enabled = false
local warned = false        -- the chat notice is printed once per session

function Meter.Disable(reason)
    enabled = false
    if warned then return end
    warned = true
    print("|cff66ccffCombat Text Icons:|r damage meter unavailable, '?' for unlearned hits is off (" .. tostring(reason) .. ").")
end

-- Checked at login; a missing API, false, an error or a secret result turns the meter off.
function Meter.Init()
    local ok, available = false, nil
    if C_DamageMeter then ok, available = pcall(C_DamageMeter.IsDamageMeterAvailable) end
    enabled = ok and not issecretvalue(available) and available == true
    if not enabled then Meter.Disable("unavailable") end
end

function Meter.Available()
    return enabled
end
