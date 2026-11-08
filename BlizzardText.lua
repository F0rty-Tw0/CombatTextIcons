-- Combat Text Icons: Blizzard's own combat text. The addon turns Blizzard's outgoing numbers off while it draws them
-- and gives them back on /cti off, at logout, and on Forever while grouped (SyncBlizzard). Core.SuppressBlizzard,
-- Core.RestoreBlizzard and Core.SyncBlizzard are these.

local _, ns = ...

local BlizzardText = {}
ns.BlizzardText = BlizzardText

local InGroup = ns.HitRoute.InGroup

-- Blizzard's floating numbers this addon replaces.
local CVARS = {
    "floatingCombatTextCombatDamage_v2",
    "floatingCombatTextCombatLogPeriodicSpells_v2",
    "floatingCombatTextPetMeleeDamage_v2",
    "floatingCombatTextPetSpellDamage_v2",
    "floatingCombatTextCombatHealing_v2",
}

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local db

-- The saved variables the remembered CVar values live in (Core.ADDON_LOADED).
function BlizzardText.Init(saved)
    db = saved
end

-- Blizzard's own scrolling text (Blizzard_CombatText, load-on-demand). Hiding
-- it also hides its buff/proc notices.
function BlizzardText.SetCombatTextShown(shown)
    if CombatText then CombatText:SetShown(shown) end
end

local SetCombatTextShown = BlizzardText.SetCombatTextShown

-- Turns the CVars off, remembering each value the first time it is not "0".
-- A CVar already at "0" with nothing remembered (a restore that did not
-- stick, or Blizzard text off before) remembers its default instead, so a
-- later restore brings Blizzard text back. A remembered value is never
-- replaced, so a login after a crash keeps the value from before it.
-- Returns false when a write failed (SetCVar errored or returned nothing).
function BlizzardText.Suppress()
    db.savedCVars = db.savedCVars or {}
    local failed = false
    for _, name in ipairs(CVARS) do
        if db.savedCVars[name] == nil then
            local value = C_CVar.GetCVar(name)
            if Plain(value) and value == "0" then value = C_CVar.GetCVarDefault(name) end
            if Plain(value) and value ~= "0" then db.savedCVars[name] = value end
        end
        local ok, success = pcall(C_CVar.SetCVar, name, "0")
        if not (ok and success) then failed = true end
    end
    SetCombatTextShown(false)

    return not failed
end

-- Writes the remembered values back (SetCVar returns nothing on failure) and
-- returns whether every write succeeded (true when nothing is remembered).
-- With `forget` (/cti off) each written entry is dropped; at logout they all
-- stay, so a crash before the write is saved still finds them at the next
-- login. A failed write stays remembered and is retried on the next enable,
-- disable or logout.
local function WriteSaved(forget)
    local saved = db.savedCVars
    if not saved then return true end
    local failed = false
    for name, value in pairs(saved) do
        local ok, success = pcall(C_CVar.SetCVar, name, value)
        if not (ok and success) then
            failed = true
        elseif forget then
            saved[name] = nil
        end
    end
    if forget and not failed then db.savedCVars = nil end

    return not failed
end

function BlizzardText.Restore(forget)
    WriteSaved(forget)
    SetCombatTextShown(true)
end

-- The mode Sync last applied ("blizzard", "addon", or nil for none yet) and whether that apply had a failed
-- write. Live only: login and /cti on|off reset them.
local applied, pending

function BlizzardText.ResetSync()
    applied, pending = nil, false
end

-- On Forever every amount is secret, so the addon names nothing in a group: while grouped Blizzard's numbers come
-- back (the remembered values; its scrolling self-text stays hidden, the addon draws damage you take). It switches
-- only when the mode changes, so an option the player sets while grouped stays, and retries a failed write
-- (spec 2026-11-07-forever-group-blizzard-text).
function BlizzardText.Sync()
    if not db.enabled then return end
    local wanted = ns.IsForever and InGroup() and "blizzard" or "addon"
    if wanted == applied and not pending then return end

    local ok
    if wanted == "blizzard" then
        ok = WriteSaved(false)
        SetCombatTextShown(false)
    else
        ok = BlizzardText.Suppress()
    end
    applied, pending = wanted, not ok
end
