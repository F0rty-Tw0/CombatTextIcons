-- Combat Text Icons: ledger. Records what the addon DREW in each fight, per key and
-- side (damage, heal): the summed amount and the hit count. A key is the ID the route
-- drew its icon with, or "?<school>" / "?" for hits no spell could be named for. Fights end up in
-- CombatTextIconsCharDB.fights, newest first by position (never sorted by time: the
-- clock restarts with the client), at most 5. A fight with no drawn hit is not saved, nor is one
-- the meter started no session for (the Teacher drops it after its read).
-- After a post-fight meter read the Teacher hands its verdicts over; they attach to the
-- newest saved fight only when it is the same fight. Saved data is checked on
-- load: bad fights, totals and verdicts are dropped, unknown fields too. The ledger only
-- records; it changes nothing about which hits draw.

local _, ns = ...

local Ledger = {}
ns.Ledger = Ledger

local MAX_FIGHTS = 5
local MAX_KEY_LENGTH = 8 -- "?8", "?"
local VERDICTS = { agree = true, over = true, under = true, unpaired = true }

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

local fights = {}  -- the saved fights, newest first; the table inside CombatTextIconsCharDB after Init
local current = nil -- the open fight: { at, date, group, damage = {}, heal = {} }

local function ValidKey(key)
    if IsNumber(key) then return true end

    return Plain(key) and type(key) == "string" and key ~= "meter" and #key <= MAX_KEY_LENGTH
end

local function ValidTotal(total)
    if type(total) ~= "table" then return false end
    local amount, hits = total.amount, total.hits

    return IsNumber(amount) and amount >= 0 and IsNumber(hits) and hits >= 1 and hits % 1 == 0
end

-- A copy of `totals` holding only the valid entries, or nil when it is not a table.
local function CleanTotals(totals)
    if type(totals) ~= "table" then return nil end
    local clean = {}
    for key, total in pairs(totals) do
        if ValidKey(key) and ValidTotal(total) then clean[key] = { amount = total.amount, hits = total.hits } end
    end

    return clean
end

local function ValidVerdict(verdict)
    return type(verdict) == "table" and IsNumber(verdict.meter) and IsNumber(verdict.meterID)
        and Plain(verdict.verdict) and VERDICTS[verdict.verdict] == true
end

-- A copy of `verdicts` holding only the valid entries; nil when none is left.
local function CleanVerdicts(verdicts)
    if type(verdicts) ~= "table" then return nil end
    local clean
    for spellID, verdict in pairs(verdicts) do
        if IsNumber(spellID) and ValidVerdict(verdict) then
            clean = clean or {}
            clean[spellID] = { meter = verdict.meter, meterID = verdict.meterID, verdict = verdict.verdict }
        end
    end

    return clean
end

-- A copy of `fight` holding only the listed fields, or nil when it is not a valid fight.
local function CleanFight(fight)
    if type(fight) ~= "table" then return nil end
    if not (IsNumber(fight.at) and IsNumber(fight.date) and IsNumber(fight.duration)) then return nil end
    if type(fight.group) ~= "boolean" then return nil end
    local damage, heal = CleanTotals(fight.damage), CleanTotals(fight.heal)
    if not (damage and heal) then return nil end

    return { at = fight.at, date = fight.date, duration = fight.duration,
        group = fight.group, damage = damage, heal = heal, verdicts = CleanVerdicts(fight.verdicts) }
end

function Ledger.Init(charDB)
    if type(charDB.fights) ~= "table" then charDB.fights = {} end
    fights = charDB.fights
    local clean = {}
    for _, fight in ipairs(fights) do
        local kept = #clean < MAX_FIGHTS and CleanFight(fight)
        if kept then clean[#clean + 1] = kept end
    end
    for key in pairs(fights) do fights[key] = nil end
    for index, fight in ipairs(clean) do fights[index] = fight end
end

-- Opens a fight; a fight still open is discarded.
function Ledger.Start(now, grouped)
    current = { at = IsNumber(now) and now or 0, date = time(), group = grouped == true, damage = {}, heal = {} }
end

-- One drawn hit. `amount` adds only when plain; the hit counts either way.
function Ledger.Add(side, key, amount)
    if not current or not ValidKey(key) then return end
    local totals = (side == "damage" or side == "heal") and current[side]
    if not totals then return end
    local total = totals[key]
    if not total then
        total = { amount = 0, hits = 0 }
        totals[key] = total
    end
    total.hits = total.hits + 1
    if IsNumber(amount) and amount >= 0 then total.amount = total.amount + amount end
end

function Ledger.Finish(now)
    local fight = current
    current = nil
    if not fight then return end
    if next(fight.damage) == nil and next(fight.heal) == nil then return end
    fight.duration = IsNumber(now) and now - fight.at or 0
    table.insert(fights, 1, fight)
    for index = #fights, MAX_FIGHTS + 1, -1 do fights[index] = nil end
end

-- Attaches the Teacher's verdicts (rows { spellID, meterID, meter, verdict, ... }) to the newest
-- saved fight when that is the fight started at `at` and holds none yet. One spell in
-- several rows: the first row that is not "unpaired" wins, else the first.
function Ledger.SetVerdicts(results, at)
    local fight = fights[1]
    if not (fight and IsNumber(at) and fight.at == at and fight.verdicts == nil) then return end
    if type(results) ~= "table" then return end
    local verdicts
    for _, result in ipairs(results) do
        if type(result) == "table" and IsNumber(result.spellID) and ValidVerdict(result) then
            local held = verdicts and verdicts[result.spellID]
            if not held or (held.verdict == "unpaired" and result.verdict ~= "unpaired") then
                verdicts = verdicts or {}
                verdicts[result.spellID] = { meter = result.meter, meterID = result.meterID, verdict = result.verdict }
            end
        end
    end
    fight.verdicts = verdicts
end

-- Drops the newest saved fight when it is the fight started at `at`: the meter started no session
-- for it (leftover ticks re-entering combat for a moment), so it would only push real fights out.
function Ledger.Drop(at)
    local fight = fights[1]
    if fight and IsNumber(at) and fight.at == at then table.remove(fights, 1) end
end

-- Clears the saved fights in place (the table lives in the character's saved variables); the open fight stays.
function Ledger.Forget()
    for key in pairs(fights) do fights[key] = nil end
end

function Ledger.Current() return current end

function Ledger.Fights() return fights end
