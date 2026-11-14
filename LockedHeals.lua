-- Combat Text Icons: Forever heal router. Names the spell behind each heal on you once its frame ends. Four fits:
-- a lone helpful cast on the stamp (direct), a learned HoT period (hot), a self-heal of your own hit on the stamp
-- (self: Vampiric Embrace's window, a Devouring Plague tick), else the one saved proc row when your own hit landed
-- (proc). Direct, self and proc fit only solo: in a group a heal on your stamp may be another player's.

local _, ns = ...

local LockedHeals = {}
ns.LockedHeals = LockedHeals

local STRIKES_MAX = 2 -- strikes that drop a saved proc row
local LOCKED_HEALS_V = 2 -- the saved rows' learning rule; a store saved under another is emptied once (Init)

-- Vampiric Embrace (Forever): while it is on your target each of your shadow hits heals you on the hit's stamp (meter
-- row 15290). Run 13 (2026-11-14): 150 of 215 own shadow hits within its window had a heal on their stamp, 145 of 535
-- outside it; the rate fell to the outside one about 21 s after the cast. The proc fit named every one of those
-- heals the 1260198 drain (299 heals drawn as it against about 23 meter procs) and the drain hold drew their hits
-- as the drain (55 against about 23).
local VE_CAST = 15286
local VE_WINDOW = 21

-- Devouring Plague (Forever) heals you on each of its ticks (run 13: meter heal row 19277 beside its damage row); the
-- proc fit named those heals the drain too. 2944 and 19277 are from logs, the other ranks Classic data.
LockedHeals.SELF_DOTS = { -- read-only
    [2944] = true, [19276] = true, [19277] = true, [19278] = true, [19279] = true, [19280] = true,
}

-- Your Vampiric Embrace cast's time, or nil: NoteCast arms it, EndFight clears it (the next pull is another mob).
local veAt

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
    -- once per store: rows saved before version 2 learned without the damage-row test (Learn) and hold heal-only
    -- IDs that never drop; the drain relearns on its next solo fight
    if store.lockedHealsV ~= LOCKED_HEALS_V then
        store.lockedHeals = {}
        store.lockedHealsV = LOCKED_HEALS_V
    end
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
    veAt = nil
end

-- A harmful player cast of `spellID` at `now`: Vampiric Embrace arms its window (or re-arms it).
function LockedHeals.NoteCast(spellID, now)
    if ns.IsForever and spellID == VE_CAST then veAt = now end
end

-- The fight is over: Vampiric Embrace's window ends with its mob.
function LockedHeals.EndFight()
    veAt = nil
end

-- The only saved proc row's ID, or nil when none or several are saved
local function OnlyRow()
    local id = next(saved)
    if id ~= nil and next(saved, id) == nil then return id end
end
LockedHeals.OnlyRow = OnlyRow

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

-- The spells whose own hit on the stamp `at` heals you: Vampiric Embrace inside its window, and each of `dots` (the
-- Devouring Plague ranks whose tick landed on the stamp; PlayerHits.SelfDots).
local function SelfHeals(at, dots)
    local ids = {}
    if veAt and at >= veAt and at - veAt <= VE_WINDOW then ids[#ids + 1] = VE_CAST end
    for _, id in ipairs(dots or {}) do ids[#ids + 1] = id end

    return ids
end

-- Returns claims[index] = spellID for each heal that exactly one spell fits. castIDs: your helpful casts on the stamp;
-- ownAt: whether your own hit landed on it; solo: not in a group (direct, self and proc fit only then); dots: the
-- self-healing DoTs whose tick landed on the stamp (SelfHeals). A self-heal source on the stamp replaces the proc fit:
-- the drain's heal hides among them, so its row names none of them.
function LockedHeals.Claim(castIDs, heals, at, ownAt, solo, dots)
    local claims = {}
    if not ns.IsForever then return claims end
    local selfIDs = solo and ownAt and SelfHeals(at, dots) or {}
    for index = 1, #heals do
        local kinds, slots, ids = {}, {}, {}
        if solo and #castIDs == 1 then Fit(kinds, ids, castIDs[1], "direct") end
        for _, fit in ipairs(ns.Ticks.Fits("player", "heal", nil, at)) do
            Fit(kinds, ids, fit.spellID, "hot")
            slots[fit.spellID] = slots[fit.spellID] or fit.slot
        end
        for _, id in ipairs(selfIDs) do Fit(kinds, ids, id, "self") end
        local row = #selfIDs == 0 and solo and ownAt and OnlyRow()
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

-- [spellID] = true for each meter row of `list` with a plain spell ID; a nil or secret list gives none.
local function PlainIDs(list)
    local ids = {}
    if issecretvalue(list) or type(list) ~= "table" then return ids end
    for _, row in ipairs(list) do
        local isTable = not issecretvalue(row) and type(row) == "table"
        local isPlainRow = isTable and IsNumber(row.spellID)
        if isPlainRow then ids[row.spellID] = true end
    end

    return ids
end

-- Reads the heal rows of a fight: saves as a proc row a heal row nothing of yours cast that is also a damage row of
-- the same read, drops a saved row that is your own cast, and strikes a proc row that named a heal but is absent from
-- a read that has rows. The damage-row test is what tells the proc from a cast's heal under its own effect ID: the
-- drain 1260198 heals and hits under one ID in every read, while Holy Nova (casts 15237/15430, heals 23455/23458) and
-- Cannibalize (20577, heals 20578) only heal; saved, those jammed the proc fit for good (OnlyRow needs one row).
-- A nil or empty read strikes nothing. A learned HoT that named a heal inside the fight (run.at..run.ended) yet is
-- absent from a read with rows was a wrong rhythm (S11 run 1: Devouring Plague's self-heals read as Touch of
-- Weakness): Ticks drops it.
-- run: the teacher's run (helps, at, ended); cast: fight.cast (harmful IDs and bases); damageRows: the read's full
-- damage rows (nil or secret saves nothing new); any may be nil.
function LockedHeals.Learn(healRows, run, cast, damageRows)
    if not ns.IsForever then return end
    local fight = type(run) == "table" and run or {}
    -- A grouped fight never learns: its draws came from owned heals, while Blizzard's numbers and other players' heals
    -- share the meter's rows. Forget the draws so the next read does not judge them.
    if fight.group then
        Clear(drew)
        Clear(hotDrew)

        return
    end
    local rows = PlainIDs(healRows)
    local damage = PlainIDs(damageRows)
    local harmful = type(cast) == "table" and cast or {}
    for id in pairs(rows) do
        if saved[id] then
            if ns.Ticks.IsOwnCast(id) then Drop(id) end
        elseif damage[id] and not InHelps(fight.helps, id) and not harmful[id] and not ns.Ticks.IsOwnCast(id) then
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
