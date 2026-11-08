-- Combat Text Icons: Forever heal router. Names the spell behind each heal on you once its frame ends. Three fits:
-- a lone helpful cast on the stamp (direct), a learned HoT period (hot), the one saved proc row when your own hit
-- landed (proc). Direct and proc fit only solo: in a group a heal on your stamp may be another player's.

local _, ns = ...

local LockedHeals = {}
ns.LockedHeals = LockedHeals

local STRIKES_MAX = 2 -- strikes that drop a saved proc row

local issecretvalue = issecretvalue or function() return false end
local function IsNumber(value) return not issecretvalue(value) and type(value) == "number" end

-- [spellID] = { strikes = number }: the store's saved proc rows
local saved = {}
-- [spellID] = true: a proc row named a heal since the last read
local drew = {}
-- [spellID] = stamp: a learned HoT named a heal at that stamp since the last read
local hotDrew = {}

local function Clear(list) for key in pairs(list) do list[key] = nil end end

function LockedHeals.Init(store)
    if type(store.lockedHeals) ~= "table" then store.lockedHeals = {} end
    for id, row in pairs(store.lockedHeals) do
        if not IsNumber(id) or type(row) ~= "table" or not IsNumber(row.strikes) then store.lockedHeals[id] = nil end
    end
    saved = store.lockedHeals
    Clear(drew)
    Clear(hotDrew)
end

function LockedHeals.Forget()
    Clear(saved)
    Clear(drew)
    Clear(hotDrew)
end

-- The only saved proc row's ID, or nil when none or several are saved
local function OnlyRow()
    local id = next(saved)
    if id ~= nil and next(saved, id) == nil then return id end
end

-- Adds a fit of `kind` for `id` to this heal's tally; `ids` lists each distinct spell once, in first-fit order
local function Fit(kinds, ids, id, kind)
    if not kinds[id] then
        kinds[id] = {}
        ids[#ids + 1] = id
    end
    kinds[id][#kinds[id] + 1] = kind
end

local function HasKind(list, kind)
    for _, name in ipairs(list) do if name == kind then return true end end

    return false
end

-- Returns claims[index] = spellID for each heal that exactly one spell fits. castIDs: your helpful casts on the stamp;
-- ownAt: whether your own hit landed on it; solo: not in a group (direct and proc fit only then).
function LockedHeals.Claim(castIDs, heals, at, ownAt, solo)
    local claims = {}
    if not ns.IsForever then return claims end
    for index = 1, #heals do
        local kinds, slots, ids = {}, {}, {}
        if solo and #castIDs == 1 then Fit(kinds, ids, castIDs[1], "direct") end
        for _, fit in ipairs(ns.Ticks.Fits("player", "heal", nil, at)) do
            Fit(kinds, ids, fit.spellID, "hot")
            slots[fit.spellID] = slots[fit.spellID] or fit.slot
        end
        local row = solo and ownAt and OnlyRow()
        if row then Fit(kinds, ids, row, "proc") end
        if #ids == 1 then
            local id = ids[1]
            claims[index] = id
            if HasKind(kinds[id], "hot") then
                ns.Ticks.Take(id, slots[id])
                hotDrew[id] = at
            end
            if HasKind(kinds[id], "proc") then drew[id] = true end
            if ns.Debug then ns.Debug("LOCKEDHEAL %s %s", id, kinds[id][1]) end
        end
    end

    return claims
end

local function InHelps(helps, id)
    if issecretvalue(helps) or type(helps) ~= "table" then return false end
    for _, help in ipairs(helps) do
        local isTable = not issecretvalue(help) and type(help) == "table"
        local isOwnHelp = isTable and IsNumber(help.spellID) and help.spellID == id
        if isOwnHelp then return true end
    end

    return false
end

local function Drop(id)
    saved[id] = nil
    if ns.Debug then ns.Debug("LOCKEDHEAL drop %s", id) end
end

-- A drawn proc row's read: present resets its strikes, absent adds one; STRIKES_MAX strikes drop it.
local function Strike(id, row, present)
    if present then
        row.strikes = 0
    else
        row.strikes = row.strikes + 1
        if row.strikes >= STRIKES_MAX then Drop(id) end
    end
end

-- Ticks drops each learned HoT that named a heal inside the fight (from..to) yet is absent from `rows`.
local function DropWrongHots(rows, from, to)
    local hasWindow = IsNumber(from) and IsNumber(to)
    if not hasWindow then return end

    for id, at in pairs(hotDrew) do
        local inWindow = from <= at and at <= to
        if inWindow and not rows[id] then ns.Ticks.DropHeal(id) end
    end
end

-- Reads the heal rows of a fight: saves a row nothing of yours cast as a proc row, drops a saved row that is your
-- own cast, and strikes a proc row that named a heal but is absent from a read that has rows. A nil or empty read
-- strikes nothing. A learned HoT that named a heal inside the fight (run.at..run.ended) yet is absent from a read with
-- rows was a wrong rhythm (S11 run 1: Devouring Plague's self-heals read as Touch of Weakness): Ticks drops it.
-- run: the teacher's run (helps, at, ended); cast: fight.cast (harmful IDs and bases); either may be nil.
function LockedHeals.Learn(healRows, run, cast)
    if not ns.IsForever then return end
    local fight = type(run) == "table" and run or {}
    local rows = {}
    if not issecretvalue(healRows) and type(healRows) == "table" then
        for _, row in ipairs(healRows) do
            local isTable = not issecretvalue(row) and type(row) == "table"
            local isPlainRow = isTable and IsNumber(row.spellID)
            if isPlainRow then rows[row.spellID] = true end
        end
    end
    local harmful = type(cast) == "table" and cast or {}
    for id in pairs(rows) do
        if saved[id] then
            if ns.Ticks.IsOwnCast(id) then Drop(id) end
        elseif not InHelps(fight.helps, id) and not harmful[id] and not ns.Ticks.IsOwnCast(id) then
            saved[id] = { strikes = 0 }
            if ns.Debug then ns.Debug("LOCKEDHEAL row %s", id) end
        end
    end
    if next(rows) ~= nil then
        for id in pairs(drew) do
            if saved[id] then Strike(id, saved[id], rows[id]) end
        end
        DropWrongHots(rows, fight.at, fight.ended)
    end
    Clear(drew)
    Clear(hotDrew)
end
