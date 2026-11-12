-- Combat Text Icons: the addon draws your combat numbers itself, each with the
-- icon of the spell behind it, and turns Blizzard's outgoing numbers off.
--
-- UNIT_COMBAT reports every hit (no source, no spell). Which hits are yours, and
-- with which spell, is worked out from what the addon learned: DoT and channel
-- ticks are matched to your casts by their timing (Tracker.lua) and a direct hit
-- by the cast that fits it (Casts.lua). Those draw at once, in a group too.
-- The addon never resets or reads the damage meter while you fight; after
-- combat the Teacher reads it to learn.
-- A hit nothing names is hidden, except solo on a mob fighting you: there it
-- draws the question mark at once while the area is clear (Teacher.AreaClear:
-- the last fight's meter read showed only your hits), else it stays hidden. A hit
-- on a training dummy no one fights waits for the end of its frame: a learned AoE
-- cast that drew in that frame may draw it (Core.FlushMates). An
-- unnamed heal on you decides the same way. A learned proc (Procs.lua) draws its own icon where
-- the question mark would, while no read found the area crowded (Teacher.NotCrowded: a map no read decided yet
-- counts). A learned direct heal (Heals.lua) names a heal on you in its
-- cast's frame, in a group too; so does a learned coupled heal in the frame of the hit it is a share of, and a
-- learned train (a HoT or totem a cast starts) on each tick due after that cast.
-- Damage you take is always shown, without an icon.

local ADDON, ns = ...
local Meter, Tracker, Display, Learn, Streams, Casts, Fingerprints, Procs, Ledger, Teacher, Progress, Panel, MinimapButton =
    ns.Meter, ns.Tracker, ns.Display, ns.Learn, ns.Streams, ns.Casts, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Teacher,
    ns.Progress, ns.Panel, ns.MinimapButton
local Heals = ns.Heals
-- The route itself lives by concern: Blizzard's text (BlizzardText.lua), the debug log (DebugLog.lua), enemy hits
-- (HitRoute.lua, with the Touch of Weakness hold in TowHold.lua), and heals and damage taken (PlayerHits.lua). This
-- file wires the game's events and the slash command to them.
local BlizzardText, DebugLog, HitRoute, TowHold, PlayerHits = ns.BlizzardText, ns.DebugLog, ns.HitRoute, ns.TowHold,
    ns.PlayerHits
local ShowValue, ShowBase, ShowApis = DebugLog.ShowValue, DebugLog.ShowBase, DebugLog.ShowApis
local InGroup, PlainGUID = HitRoute.InGroup, HitRoute.PlainGUID

local Core = {}
ns.Core = Core

Core.SuppressBlizzard = BlizzardText.Suppress
Core.RestoreBlizzard = BlizzardText.Restore
Core.SyncBlizzard = BlizzardText.Sync
Core.FlushMates = HitRoute.FlushMates
Core.FlushHeals = PlayerHits.FlushHeals
Core.Heal = PlayerHits.Heal

local PREFIX = "|cff66ccffCombat Text Icons:|r "
local TEST_SPELL = 6603 -- Auto Attack, for /cti test

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local db

-- [plate] = the unit token NAME_PLATE_UNIT_ADDED gave it, until NAME_PLATE_UNIT_REMOVED: for the debug log only
-- (Forever's plate frames have no namePlateUnitToken; S5 run 2 printed key=plate on every cast).
local plateUnits = {}

-- A cast's tick key for the log, no spaces: "player", the plate's unit token (the one it was added for, else
-- namePlateUnitToken), "plate" when neither is a plain string, or "nil".
local function ShowKey(key)
    if type(key) ~= "table" then return tostring(key) end
    local token = plateUnits[key] or key.namePlateUnitToken

    return Plain(token) and type(token) == "string" and token or "plate"
end

-- The event frame: its handlers are the Core functions below.
local events = CreateFrame("Frame")

-- Events ---------------------------------------------------------------------------

function Core.ADDON_LOADED(name)
    if name == ADDON then
        db = CombatTextIconsDB or {}
        if db.enabled == nil then db.enabled = true end
        db.meter = nil -- the meter mode is gone
        if type(db.showUnknown) ~= "boolean" then db.showUnknown = nil end
        if type(db.showProgress) ~= "boolean" then db.showProgress = nil end
        if type(db.panelDetails) ~= "boolean" then db.panelDetails = nil end -- the learned window's Details toggle
        CombatTextIconsDB = db
        BlizzardText.Init(db)
        DebugLog.Init(db)
        HitRoute.Init(db)
    elseif name == "Blizzard_CombatText" and db and db.enabled then
        BlizzardText.SetCombatTextShown(false)
    end
end

-- The player's spec ID, or nil while the client does not know it (early at login).
local function SpecID()
    local api = C_SpecializationInfo or {}
    local getIndex = api.GetSpecialization or GetSpecialization
    local getInfo = api.GetSpecializationInfo or GetSpecializationInfo
    if not (getIndex and getInfo) then return nil end
    local ok, index = pcall(getIndex)
    if not (ok and Plain(index) and type(index) == "number" and index > 0) then return nil end
    local okInfo, specID = pcall(getInfo, index)
    if okInfo and Plain(specID) and type(specID) == "number" and specID > 0 then return specID end
end

local spec = nil -- the spec whose store the modules use; 0 while the spec is unknown

-- Every learning module takes the store of the player's spec, CombatTextIconsCharDB.specs[spec ID]: a resto
-- shaman never draws with what elemental learned. Saved data is checked, never trusted. Until the client knows the
-- spec the store is specs[0]; the first known spec takes it over when it has no store yet, else it is dropped (it
-- holds at most what a fight before then taught). A swap drops the Teacher's judging under way (Teacher.Init).
local function UseSpec()
    local id = SpecID() or spec or 0
    if id == spec then return end
    local specs = CombatTextIconsCharDB.specs
    if spec == 0 then
        if specs[id] == nil then specs[id] = specs[0] end
        specs[0] = nil
    end
    if type(specs[id]) ~= "table" then specs[id] = {} end
    if ns.Debug then ns.Debug("SPEC %s -> %d", ShowValue(spec), id) end
    spec = id
    local store = specs[id]
    Learn.Init(store)
    Fingerprints.Init(store)
    Heals.Init(store)
    Casts.InitOwnRows(store)
    Procs.Init(store)
    ns.Locked.Init(store)
    ns.Ticks.Init(store)
    ns.LockedHeals.Init(store)
    ns.Volley.Init(store)
    ns.Link.Init(store)
    Ledger.Init(store)
    Teacher.Init(store)
    Tracker.Reset()
    Streams.Reset()
end

function Core.PLAYER_LOGIN()
    local fresh = type(CombatTextIconsCharDB) ~= "table" -- this character's first login with the addon
    -- a store from before the per-spec one holds only learning: it is dropped whole, once
    if fresh or type(CombatTextIconsCharDB.specs) ~= "table" then CombatTextIconsCharDB = { specs = {} } end
    Meter.Init()
    spec = nil
    UseSpec()
    BlizzardText.ResetSync()
    if ns.IsForever and db.enabled then ns.Owner.KeepLinesOn() end
    Core.SyncBlizzard()
    if fresh and db.enabled then
        print(PREFIX .. "'?' icons are hits it hasn't learned yet. Fight a few mobs solo and they turn into your spell icons."
            .. " /cti for options.")
    end
    MinimapButton.Init() -- last: a UI error here must not skip the combat setup above
end

-- Login, reload and every loading screen: the crowd verdict comes back on the map it was made on. A spec the
-- client did not know at login is known by now.
function Core.PLAYER_ENTERING_WORLD()
    UseSpec()
    Teacher.EnterWorld()
end

-- Fires for talent changes too; UseSpec swaps only when the spec ID changed. Before login nothing is loaded yet.
function Core.PLAYER_SPECIALIZATION_CHANGED()
    if spec then UseSpec() end
end

function Core.PLAYER_LOGOUT()
    ns.Owner.LinesOff()
    Core.RestoreBlizzard(false)
end

-- The fight ends: casts, ledger and the teacher's read close out.
function Core.PLAYER_REGEN_ENABLED()
    if not db.enabled then return end
    ns.Owner.Flush(nil)
    ns.Owner.Active()
    Core.SyncBlizzard() -- retries a write the fight may have refused
    Core.FlushHeals()
    Core.FlushMates()
    TowHold.Decide(GetTime(), true) -- a held Touch of Weakness candidate is decided at any age; the arm itself stays
    Casts.Flush(GetTime())
    Ledger.Finish(GetTime())
    Teacher.Finish(GetTime())
    ns.Locked.EndFight()
    ns.Ticks.EndFight()
end

-- The combat-start hook: the ledger opens a fight and the teacher starts tallying what
-- is drawn (same `now`, so the verdicts find the fight); Progress snapshots the learn state.
function Core.PLAYER_REGEN_DISABLED()
    if not db.enabled then return end
    if ns.IsForever then ns.Owner.KeepLinesOn() end
    ns.Owner.Active()
    local now = GetTime()
    Ledger.Start(now, InGroup())
    Teacher.Start(now, InGroup())
    Progress.Start()
end

function Core.UNIT_COMBAT(unit, event, flagText, amount, school)
    if not db.enabled then return end
    local now = GetTime()
    if not (Plain(unit) and Plain(event)) then return end
    ns.Owner.Flush(now)
    Core.FlushHeals(now)
    Core.FlushMates(now)
    TowHold.Decide(now)
    if unit:find("^nameplate%d+$") then
        HitRoute.EnemyHit(unit, event, flagText, amount, school, now)
    elseif event == "HEAL" and (unit == "player" or unit:find("^party[1-4]$")) then
        if ns.Owner.Active() then ns.Owner.Heal(unit, now) end
        Core.Heal(unit, flagText, amount, school, now)
    elseif unit == "player" then
        if event == "WOUND" then PlayerHits.Taken(flagText, amount) end
    end
end

-- The pet's harmful casts join the cast log too: the meter lists pet damage among the player's own rows
-- (Shadow Bite 54049, Bite 17253), so the teacher learns them like the player's. The player's other casts may be
-- heals: the frame's waiting heals get them (Core.FlushHeals), and the teacher too (Heals.lua).
function Core.UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)
    if not db.enabled then return end
    local now = GetTime()
    ns.Owner.Flush(now, true)
    Core.FlushHeals(now)
    Core.FlushMates(now)
    TowHold.Decide(now)
    local keyed = not InGroup() or ns.Owner.Active()
    local tickKey
    if (unit == "player" or unit == "pet") and Plain(spellID) then
        Procs.NoteCast(spellID, now) -- a rhythm's onset may follow any cast (a totem's is not harmful)
        ns.Volley.NoteCast(spellID, now)
        local harmful = C_Spell.IsSpellHarmful and C_Spell.IsSpellHarmful(spellID)
        if Plain(harmful) and harmful then
            local plate = Casts.NoteCast(spellID, now, castGUID, unit == "pet")
            Teacher.Cast(spellID, Casts.Base(spellID), now, plate, unit == "pet")
            ns.Link.NoteCast(spellID, now, plate)
            if unit == "player" then
                local plainPlate = Plain(plate) and plate or nil
                ns.Locked.NoteCast(spellID, now, plainPlate)
                if ns.IsForever then ns.Owner.Cast(now) end -- only Forever counts casts that bring no line
                tickKey = keyed and plainPlate or nil
                ns.Ticks.NoteCast(spellID, now, tickKey, "damage")
            end
        elseif Plain(harmful) and unit == "player" then
            PlayerHits.NoteHelpful(spellID, now)
            Teacher.Helped(spellID, now)
            ns.Tow.Note(spellID, now) -- a Touch of Weakness rank arms its proc (Tow.lua)
            Heals.Cast(spellID, now)
            tickKey = keyed and "player" or nil
            ns.Ticks.NoteCast(spellID, now, tickKey, "heal")
        end
    end
    -- Logged after the cast's modules so it carries the tick key Ticks got (a recast's "TICKS retired" now comes before
    -- it): the cast debug for S5's game-only `?` ticks, whose cast reached Ticks with no key or another (diagnosis
    -- 2026-11-06-s5, cause G).
    if ns.Debug then
        ns.Debug("CAST %s %s base=%s key=%s", unit, ShowValue(spellID), Plain(spellID) and ShowBase(spellID) or "?",
            ShowKey(tickKey))
    end
    Tracker.OnCast(unit, spellID, now)
end

-- A spell with a cast time began: its plate is the target now, not the one when it lands.
function Core.UNIT_SPELLCAST_START(unit, castGUID, spellID)
    if not db.enabled or unit ~= "player" then return end
    if ns.Debug then ns.Debug("START %s %s", unit, ShowValue(spellID)) end
    Casts.NoteStart(castGUID, spellID, GetTime())
end

function Core.UNIT_SPELLCAST_CHANNEL_START(unit, castGUID, spellID)
    if not db.enabled then return end
    ns.Flat.Channel(spellID)
    Tracker.OnChannelStart(spellID, GetTime(), castGUID)
end

function Core.UNIT_SPELLCAST_CHANNEL_STOP(unit, castGUID)
    ns.Owner.ChannelStop(GetTime(), castGUID)
end

function Core.GROUP_ROSTER_UPDATE()
    ns.Owner.Flush(nil)
    if ns.IsForever and db.enabled then ns.Owner.KeepLinesOn() end
    ns.Owner.Active()
    Tracker.OnRosterChanged()
    Core.SyncBlizzard()
end

-- Plate frames are recycled: nothing stays tied to this one. The Tracker parks the mob's DoT
-- state under its GUID until its plate shows again.
function Core.NAME_PLATE_UNIT_REMOVED(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit, false)
    if Plain(plate) then
        Tracker.OnPlateRemoved(plate, PlainGUID(unit), GetTime())
        Display.ReleasePlate(plate)
        HitRoute.PlateGone(plate)
        ns.Owner.PlateGone(plate)
        ns.Locked.PlateGone(plate)
        ns.Ticks.PlateGone(plate)
        plateUnits[plate] = nil
    end
end

function Core.NAME_PLATE_UNIT_ADDED(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit, false)
    local guid = PlainGUID(unit)
    if Plain(plate) then plateUnits[plate] = unit end
    if Plain(plate) and guid then Tracker.OnPlateAdded(plate, guid, GetTime()) end
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("UNIT_COMBAT")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
pcall(events.RegisterEvent, events, "COMBAT_LOG_MESSAGE") -- a client without the event raises
events:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
events:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
events:SetScript("OnEvent", function(_, event, ...) Core[event](...) end)

-- One of your Combat Log lines (the lines Owner pairs with the hits).
function Core.COMBAT_LOG_MESSAGE(text, r, g, b, order)
    if not db.enabled then return end
    ns.Owner.Line(order, GetTime())
end

-- Slash commands --------------------------------------------------------------------

-- /cti toggles the addon, /cti on and /cti off set it; /cti test shows a
-- sample popup on your target's nameplate; /cti learned opens the learned window
-- (works while the addon is off), /cti learned chat lists the spells the addon
-- learned by itself in chat and /cti forget clears them (the current spec's only).
-- /cti minimap shows or hides the minimap button (works while the addon is off).
-- /cti unknown on|off shows or hides the '?' icon of a hit no spell could be named for
-- (the number stays; works while the addon is off).
-- /cti progress on|off shows or hides the fight-end learning popups (works while the addon is off).
SLASH_COMBATTEXTICONS1 = "/cti"

local function SpellName(spellID)
    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if Plain(name) and type(name) == "string" then return name end

    return "spell " .. spellID
end

local function PrintLearned()
    local list = Learn.List()
    if #list == 0 then
        print(PREFIX .. "nothing learned yet")
        return
    end
    for _, row in ipairs(list) do
        print(PREFIX .. SpellName(row.spellID) .. " (" .. row.spellID .. "): school " .. row.school .. ", "
            .. string.format("%.2f", row.period) .. " s, " .. row.kind)
    end
end

SlashCmdList.COMBATTEXTICONS = function(message)
    if not db then return end
    message = strtrim(message or ""):lower()
    if message == "test" then
        local plate = C_NamePlate.GetNamePlateForUnit("target", false)
        if not Plain(plate) then
            print(PREFIX .. "target an enemy with a visible nameplate first.")
            return
        end
        Display.Plate(plate, C_Spell.GetSpellTexture(TEST_SPELL), 12345, "CRITICAL", 1)
        return
    end
    if message == "forget" then
        Learn.Forget()
        Casts.Forget()
        Heals.Forget()
        Procs.Forget()
        ns.Locked.Forget()
        ns.LockedHeals.Forget()
        ns.Ticks.Forget()
        ns.Volley.Forget()
        ns.Link.Forget()
        Ledger.Forget()
        print(PREFIX .. "forgot this spec's learned spells")
        return
    end
    if message == "learned" then
        Panel.Toggle()
        return
    end
    if message == "learned chat" then
        PrintLearned()
        return
    end
    if message == "minimap" then
        db.minimap.hide = not db.minimap.hide
        MinimapButton.Apply()
        print(PREFIX .. "minimap button " .. (db.minimap.hide and "hidden; /cti minimap shows it" or "shown"))
        return
    end
    if message:sub(1, 7) == "unknown" then
        local word = strtrim(message:sub(8))
        if word ~= "on" and word ~= "off" then
            print(PREFIX .. "usage: /cti unknown on|off")
            return
        end
        db.showUnknown = word == "on"
        print(PREFIX .. "'?' icons " .. word)
        return
    end
    if message:sub(1, 8) == "progress" then
        local word = strtrim(message:sub(9))
        if word ~= "on" and word ~= "off" then
            print(PREFIX .. "usage: /cti progress on|off")
            return
        end
        Progress.SetShown(word == "on")
        print(PREFIX .. "progress popups " .. word)
        return
    end
    if message == "debug" then
        if ns.Debug then
            ns.Debug = nil
            DebugLog.StopLines()
            print(PREFIX .. "debug log off, " .. #db.debugLog .. " lines kept; /reload to save them")
        else
            db.debugLog = {}
            ns.Debug = DebugLog.Debug
            DebugLog.Debug("PROBE api %s", ShowApis())
            DebugLog.Debug("PROBE clog %s", DebugLog.StartLines())
            print(PREFIX .. "debug log on (cleared)")
        end
        return
    end
    local enable = not db.enabled
    if message == "on" then
        enable = true
    elseif message == "off" then
        enable = false
    elseif message ~= "" then
        print(PREFIX .. "usage: /cti [on|off|learned [chat]|minimap|unknown|progress|forget|debug|test]")
        return
    end
    if enable == db.enabled then
        print(PREFIX .. "already " .. (enable and "on" or "off"))
        return
    end
    db.enabled = enable
    BlizzardText.ResetSync()
    if db.enabled then
        Core.SyncBlizzard()
    else
        Core.RestoreBlizzard(true)
        Tracker.Reset()
        Ledger.Finish(GetTime())
        Teacher.fight = nil -- a cut-short fight is not read
        TowHold.Drop() -- the 0.2 s timer then decides nothing
        ns.Owner.Drop() -- the held hits are neither routed nor drawn
        ns.Owner.LinesOff()
    end
    print(PREFIX .. (db.enabled and "on" or "off"))
end
