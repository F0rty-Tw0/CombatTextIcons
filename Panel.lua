-- Combat Text Icons: learned panel. Panel.Rows builds the list the learned window
-- shows: every spell the addon can draw, its learn state and, for a fight, what it
-- drew. Sources are the Spells.lua table (shipped empty; one row per tick icon, since the tracker draws
-- table spells under their tick icon), the learned ticks, the tick candidates still
-- collecting votes, the direct-hit fingerprints, and the fight's own keys that none
-- of those names ("?<school>", an ID drawn by a route but known nowhere
-- else). The proc store (castless procs) is a source too: learned procs follow learned fingerprints,
-- proc candidates follow fingerprint candidates. A key in several sources gets one row; learned beats table beats learning.
-- Table rows show only for spells the character knows (or that drew in the fight);
-- candidates only once they have a vote. Totals and meter verdicts join on the key the addon drew with. Rows are plain
-- tables, sorted; building them reads state and changes nothing. Each row also says in plain words where it stands
-- (`status`, a dim `why`, a `tone`): "Knows it" and how, with a warning per strike towards a drop; "Learning: N more"
-- casts, tick starts or fights, each counter in its own unit, or "double-checking"; "Not learning: no meter row" for
-- a spell drawn this fight with no meter row and nothing learned; "Not named yet" for a '?' key. `check` is the meter
-- verdict in words; heals are never judged.
--
-- The window (/cti learned) shows those rows for one view: the open fight ("live")
-- or a saved fight, remembered by its `at`; each new fight takes the view, live and then saved.
-- The plain view shows Spell, Status, This fight (drawn amount and share of
-- the fight's drawn damage) and Meter check; the Details button swaps in the raw columns (ID, kind, state, hits,
-- meter, verdict) and is remembered in CombatTextIconsDB.panelDetails. Hovering a row shows its full raw state. A
-- summary line under the header gives the area, how much drawn damage is named and, for a saved fight, the read's
-- outcome (why it taught nothing). While shown it rebuilds every 0.5 s, so
-- live totals, late verdicts and fight-end learning appear by themselves; a rebuild
-- error prints once and stops the refresh, so the panel can never break combat.

local _, ns = ...
local Learn, Fingerprints, Procs, Ledger, Meter, Teacher = ns.Learn, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Meter,
    ns.Teacher

local Panel = {}
ns.Panel = Panel

local SECTIONS = { damage = 1, heal = 2 }
local GROUPS = { learned = 1, learning = 2, table = 3, unattributed = 4 }
local KINDS = { target = "dot", channel = "channel", area = "area", spread = "spread" } -- table mode -> row kind
-- fingerprint pattern -> row kind
local PATTERNS = { single = "direct", chain = "chain", ground = "ground", stack = "stack" }
-- row kind -> how a learned row knows the spell, shown after "Knows it"
local HOW = { dot = "tick rhythm", channel = "channel", direct = "hit", stack = "stacking DoT",
    ground = "ground", chain = "chain", proc = "proc", area = "area", spread = "spread" }
local CHECKS = { agree = "matches", over = "drew too much", under = "drew less" } -- meter verdict -> Meter check

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end
local function IsNumber(value) return Plain(value) and type(value) == "number" end

local function SpellName(spellID)
    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if Plain(name) and type(name) == "string" then return name end

    return "spell " .. spellID
end

-- The row name of a key: a spell name or the school of a "?" key.
local function KeyName(key)
    if type(key) == "number" then return SpellName(key) end
    local school = tostring(key):match("^%?(%d+)$")

    return school and ("? school " .. school) or "? school unknown"
end

-- Per tick icon of the table, the spell that owns its row: a row whose own icon it is beats a spreads[] entry,
-- then the lowest cast ID (pairs order is undefined). { [icon] = { rank, castID, kind } }
local function TableOwners()
    local owners = {}
    local function Offer(icon, castID, kind, own)
        local rank = own and 1 or 2
        local owner = owners[icon]
        if owner and (owner.rank < rank or owner.rank == rank and owner.castID < castID) then return end
        owners[icon] = { rank = rank, castID = castID, kind = kind }
    end
    for castID, row in pairs(ns.Spells) do
        Offer(row.icon or castID, castID, KINDS[row.mode], true)
        for _, spread in ipairs(row.spreads or {}) do
            if spread.icon then Offer(spread.icon, castID, "spread", false) end
        end
    end

    return owners
end

-- "n <unit>", plural when n is not 1.
local function Count(n, unit) return string.format("%d %s%s", n, unit, n == 1 and "" or "s") end

-- A learned row's plain status: "Knows it" and how, with `warnings` strikes towards a drop.
local function KnowsIt(kind, warnings)
    if warnings > 0 then return "Knows it, " .. Count(warnings, "warning"), HOW[kind] or "", "warn" end

    return "Knows it", HOW[kind] or "", "ok"
end

-- A learning row's plain status: `left` more of `unit` (rounded up), or double-checking once none is left.
local function Learning(left, unit)
    if left <= 0 then return "Learning: double-checking", "", "warn" end

    return "Learning: " .. Count(math.ceil(left), "more " .. unit), "", "warn"
end

-- The learn state of a key no store names: a '?' key, or an ID drawn by a route but known nowhere now.
local function Unattributed(key)
    local status = type(key) == "number" and "Not known now" or "Not named yet"

    return { group = "unattributed", kind = "", state = "", status = status, why = "", tone = "dim" }
end

-- True when the character knows `castID`. No spellbook API (an old client) reads as known; a secret answer as not.
local function Knows(castID)
    if not IsPlayerSpell then return true end
    local known = IsPlayerSpell(castID)

    return Plain(known) and known == true
end

-- Every key with a learn state: { [key] = { group, kind, state, status, why, tone } }. Claimed in precedence order,
-- first claim wins: learned ticks, learned fingerprints, learned procs, the table, then the candidates (tick votes,
-- fingerprints, proc candidates). A table row shows only for a spell the character knows or one that drew in the
-- fight (`drew[key]`); a candidate only once it has a vote (a proc candidate, a streak). A learned row's warnings are
-- its strikes towards a drop: a tick spell's tickless casts and unpaired reads, a fingerprint's overshoots, a proc's
-- unpaired reads.
local function KnownSpells(drew)
    local known = {}
    local function Claim(key, group, kind, state, status, why, tone)
        if known[key] == nil then
            known[key] = { group = group, kind = kind, state = state, status = status, why = why, tone = tone }
        end
    end

    for _, entry in ipairs(Learn.List()) do
        Claim(entry.spellID, "learned", entry.kind, string.format("period %.2f s", entry.period),
            KnowsIt(entry.kind, entry.misses + entry.unpaired))
    end
    local prints = Fingerprints.List()
    for _, entry in ipairs(prints) do
        if entry.learned then
            local strikes = entry.strikes > 0 and string.format(", strikes %.0f", entry.strikes) or ""
            local kind = PATTERNS[entry.pattern]
            Claim(entry.spellID, "learned", kind, string.format("agreed in %.0f fights", entry.fights) .. strikes,
                KnowsIt(kind, entry.strikes))
        end
    end
    local procList = Procs.List()
    for _, entry in ipairs(procList) do
        if entry.learned then
            local rhythm = entry.period and string.format("rhythm %.2f s, ", entry.period) or ""
            Claim(entry.spellID, "learned", "proc",
                string.format("school %.0f, %ssize %.0f–%.0f", entry.school, rhythm, entry.lo, entry.hi),
                KnowsIt("proc", entry.unpaired))
        end
    end
    for icon, owner in pairs(TableOwners()) do
        if drew(icon) or Knows(owner.castID) then
            Claim(icon, "table", owner.kind, "table: " .. SpellName(owner.castID), "Knows it", "built-in table", "ok")
        end
    end
    for _, entry in ipairs(Learn.VoteList()) do
        local need = entry.school == 1 and Learn.VOTES_MIN_PHYSICAL or Learn.VOTES_MIN
        if entry.votes > 0 then
            local checking = entry.votes >= need and " (checking)" or "" -- enough votes, luck p still above ALPHA
            local state = string.format("votes %.0f of %d", entry.votes, need) .. checking
            Claim(entry.spellID, "learning", entry.kind, state, Learning(need - entry.votes, "tick start"))
        end
    end
    for _, entry in ipairs(prints) do
        if not entry.learned then
            Claim(entry.spellID, "learning", PATTERNS[entry.pattern],
                string.format("casts %.0f of %d", entry.casts, Fingerprints.LEARN_CASTS),
                Learning(Fingerprints.LEARN_CASTS - entry.casts, "cast"))
        end
    end

    for _, entry in ipairs(procList) do
        if not entry.learned and entry.streak > 0 then
            local label = entry.period and "rhythm fights" or "exact fights"
            local need = entry.period and Procs.RHYTHM_STREAK or Procs.LEARN_STREAK
            Claim(entry.spellID, "learning", "proc", string.format("%s %.0f of %d", label, entry.streak, need),
                Learning(need - entry.streak, "fight"))
        end
    end

    return known
end

-- Number keys first, ascending; then string keys by tostring. Never `<` between a number and a string.
local function KeyBefore(a, b)
    local aNumber = type(a) == "number"
    if aNumber ~= (type(b) == "number") then return aNumber end
    if aNumber then return a < b end

    return tostring(a) < tostring(b)
end

-- Section, then group, then drawn amount descending, then key.
local function Before(a, b)
    if a.section ~= b.section then return SECTIONS[a.section] < SECTIONS[b.section] end
    if a.group ~= b.group then return GROUPS[a.group] < GROUPS[b.group] end
    if a.drawn ~= b.drawn then return a.drawn > b.drawn end

    return KeyBefore(a.key, b.key)
end

-- The Meter check words of a row: its damage verdict ("unpaired" is either a meter row nothing was drawn for, or a
-- drawn spell with no meter row: meter 0). Heals are never judged.
local function MeterCheck(section, verdict, hits)
    if section == "heal" then return hits > 0 and "heals aren't checked" or "" end
    if not verdict then return "" end
    if verdict.verdict == "unpaired" then return verdict.meter > 0 and "drew nothing" or "no meter row" end

    return CHECKS[verdict.verdict] or ""
end

-- The summed amount of a side's totals, and the part under spell IDs (named, not '?').
local function Drawn(totals)
    local all, named = 0, 0
    for key, total in pairs(totals) do
        all = all + total.amount
        if type(key) == "number" then named = named + total.amount end
    end

    return all, named
end

-- The rows for `fight` (nil lists the learn state with empty totals): { { section, group, key, name, kind, state,
-- status, why, tone, drawn, hits, share, meter, verdict, check }, ... }
-- A key drawn on both sides gets a row in each section. Only damage rows carry a verdict: the Teacher reads damage
-- rows. `share` is a damage row's part of the fight's drawn damage, nil when it drew nothing. A row neither learned
-- nor in the table that drew with no meter row reads "Not learning: no meter row".
function Panel.Rows(fight)
    local damage, heal = fight and fight.damage or {}, fight and fight.heal or {}
    local verdicts = fight and fight.verdicts or {}
    local damageTotal = Drawn(damage)
    local rows = {}
    local function Add(section, key, info, total)
        local verdict = section == "damage" and verdicts[key] or nil
        local drawn, hits = total and total.amount or 0, total and total.hits or 0
        local status, why, tone = info.status, info.why, info.tone
        local noRow = verdict and verdict.verdict == "unpaired" and verdict.meter == 0
        if noRow and info.group ~= "learned" and info.group ~= "table" then
            status, why, tone = "Not learning", "no meter row", "bad"
        end
        rows[#rows + 1] = { section = section, group = info.group, key = key, name = KeyName(key), kind = info.kind,
            state = info.state, status = status, why = why, tone = tone, drawn = drawn, hits = hits,
            share = section == "damage" and hits > 0 and damageTotal > 0 and drawn / damageTotal or nil,
            meter = verdict and verdict.meter, verdict = verdict and verdict.verdict,
            check = MeterCheck(section, verdict, hits) }
    end

    local known = KnownSpells(function(key) return damage[key] ~= nil or heal[key] ~= nil end)
    for key, info in pairs(known) do
        local drewDamage, drewHeal = damage[key], heal[key]
        if drewDamage then Add("damage", key, info, drewDamage) end
        if drewHeal then Add("heal", key, info, drewHeal) end
        if not drewDamage and not drewHeal then Add("damage", key, info, nil) end
    end
    for key, total in pairs(damage) do
        if not known[key] then Add("damage", key, Unattributed(key), total) end
    end
    for key, total in pairs(heal) do
        if not known[key] then Add("heal", key, Unattributed(key), total) end
    end
    table.sort(rows, Before)

    return rows
end

-- Teacher.area -> summary words
local AREA_TEXT = { clear = "clear, '?' shown", crowded = "crowded, '?' hidden", unknown = "new, '?' hidden" }
local OUTCOME_TEXT = { -- a saved fight's read outcome (Ledger.SetOutcome) -> summary words
    clear = "Clear: learning ran", crowded = "Crowded: nothing learned", group = "Group fight: nothing learned",
    short = "Short read: nothing learned", skipped = "Not read: nothing learned",
}

-- The summary line for `fight` (nil: none): the area now, how much of the fight's drawn damage is named (and of the
-- meter's damage total, when its read saved one) and, for a saved fight with an outcome, what its read did.
function Panel.Summary(fight)
    local parts = { "Area: " .. (AREA_TEXT[Teacher.area] or "unknown") }
    if fight then
        local all, named = Drawn(fight.damage)
        if all > 0 then
            local ofMeter = fight.meterTotal and fight.meterTotal > 0
                and string.format(", %.0f %% of the meter's", 100 * named / fight.meterTotal) or ""
            parts[#parts + 1] = string.format("Named %.0f %% of drawn damage", 100 * named / all) .. ofMeter
        end
        if fight.outcome then parts[#parts + 1] = OUTCOME_TEXT[fight.outcome] end
    end

    return table.concat(parts, "  ·  ")
end

-- The player's spec name, or nil while the client does not know it (Core's SpecID, the info call's second answer).
local function SpecName()
    local api = C_SpecializationInfo or {}
    local getIndex = api.GetSpecialization or GetSpecialization
    local getInfo = api.GetSpecializationInfo or GetSpecializationInfo
    if not (getIndex and getInfo) then return nil end
    local ok, index = pcall(getIndex)
    if not (ok and IsNumber(index) and index > 0) then return nil end
    local okInfo, _, name = pcall(getInfo, index)
    if okInfo and Plain(name) and type(name) == "string" and name ~= "" then return name end

    return nil
end

-- The window title: the addon and the spec whose learning it shows.
function Panel.Title()
    local spec = SpecName()

    return spec and "Combat Text Icons — " .. spec or "Combat Text Icons"
end

-- Window ---------------------------------------------------------------------------

local PREFIX = "|cff66ccffCombat Text Icons:|r "
local REFRESH = 0.5 -- seconds between rebuilds while shown
local ROW_HEIGHT = 18
local CONTENT_WIDTH = 720
local WIDTH, HEIGHT = CONTENT_WIDTH + 46, 440 -- 12 left of the list, 34 right for the scroll bar
local SECTION_TITLES = { damage = "Damage", heal = "Heal" }
local GROUP_TITLES = { learned = "Learned", learning = "Learning", table = "Built-in table", unattributed = "Not named" }
-- Text columns after the icon; x is the offset from the row's left edge. The plain view's, then Details' (Name and
-- Kind give State room for a rhythm proc's "school 8, rhythm 1.61 s, size 11281–12345"; hovering shows it whole).
local PLAIN_COLUMNS = {
    { label = "Spell", x = 20, width = 160 },
    { label = "Status", x = 186, width = 300 },
    { label = "This fight", x = 490, width = 106, justify = "RIGHT" },
    { label = "Meter check", x = 606, width = 114 },
}
local DETAIL_COLUMNS = {
    { label = "Name", x = 20, width = 130 },
    { label = "ID", x = 154, width = 56, justify = "RIGHT" },
    { label = "Kind", x = 216, width = 44 },
    { label = "State", x = 264, width = 240 },
    { label = "Drawn (hits)", x = 508, width = 78, justify = "RIGHT" },
    { label = "Meter", x = 590, width = 64, justify = "RIGHT" },
    { label = "Verdict", x = 662, width = 58 },
}
local TONES = { ok = { 0.4, 1, 0.4 }, warn = { 1, 0.82, 0 }, bad = { 1, 0.4, 0.4 }, dim = { 0.6, 0.6, 0.6 } }
local DIM = "|cff999999" -- the colour of a status's why and of the heal rows' Meter check
local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local open = false -- Panel.IsOpen(); the harness frame stub cannot answer IsShown
local window       -- built on the first open
local content      -- the scroll child the rows sit on
local rowPool = {} -- row frames by line, reused on every rebuild
local view         -- "live", a saved fight's `at`, or nil (no fights at all)
local followed     -- the first view Resolve last saw (Views()[1]); a new one moves `view` to it
local broken = false

local function Amount(amount)
    return AbbreviateNumbers and AbbreviateNumbers(amount) or tostring(amount)
end

local function RowIcon(key)
    if type(key) ~= "number" then return Meter.UNKNOWN_ICON end
    local texture = C_Spell.GetSpellTexture(key)
    if Plain(texture) then return texture end

    return Meter.UNKNOWN_ICON
end

-- The views `<` `>` step through: "live" while a fight is open, then each saved fight's `at`, newest first.
local function Views()
    local views = {}
    if Ledger.Current() then views[1] = "live" end
    for _, fight in ipairs(Ledger.Fights()) do views[#views + 1] = fight.at end

    return views
end

local function Position(views, wanted)
    for index, value in ipairs(views) do
        if value == wanted then return index end
    end

    return nil
end

-- A new first view (a fight opened, or the open one was saved) takes the window: it always shows the current fight,
-- and `<` `>` browse until the next one. Else keeps the viewed fight while it is listed; else the newest saved fight,
-- else live, else nothing. Returns the views and the fight shown (nil when there is none).
local function Resolve()
    local views = Views()
    if views[1] ~= followed then view, followed = views[1], views[1] end
    if view == nil or not Position(views, view) then
        local newest = Ledger.Fights()[1]
        view = newest and newest.at or views[1]
    end
    if view == "live" then return views, Ledger.Current() end
    for _, fight in ipairs(Ledger.Fights()) do
        if fight.at == view then return views, fight end
    end

    return views, nil
end

local function HeaderText(views, fight)
    if not fight then return "no fights yet" end
    local when, duration = "live", GetTime() - fight.at
    if view ~= "live" then
        when = type(date) == "function" and date("%H:%M", fight.date) or tostring(fight.date)
        duration = fight.duration
    end

    return string.format("%s, %.0f s, %s   (%d of %d)", when, duration, fight.group and "group" or "solo",
        Position(views, view), #views)
end

-- One font string per column of `columns` on `line`.
local function Cells(line, columns)
    local cells = {}
    for column, spec in ipairs(columns) do
        local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("LEFT", line, "LEFT", spec.x, 0)
        cell:SetWidth(spec.width)
        cell:SetJustifyH(spec.justify or "LEFT")
        cell:SetWordWrap(false)
        cells[column] = cell
    end

    return cells
end

-- Hovering a row shows its name and full raw state (Details' State column cuts a long one off).
local function ShowTip(line)
    local row = line.row
    if not row then return end
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    GameTooltip:SetText(row.name)
    if row.state ~= "" then GameTooltip:AddLine(row.state, 1, 1, 1, true) end
    GameTooltip:Show()
end

-- The row frame for line `index`, made on first use: the plain view's cells and Details' cells. It takes hovers,
-- not clicks, so a drag on it still moves the window.
local function Line(index)
    local line = rowPool[index]
    if line then return line end
    line = CreateFrame("Frame", nil, content)
    line:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    line:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    line:SetMouseMotionEnabled(true)
    line:SetMouseClickEnabled(false)
    line:SetScript("OnEnter", ShowTip)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)
    line.icon = line:CreateTexture(nil, "ARTWORK")
    line.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
    line.icon:SetPoint("LEFT", line, "LEFT", 0, 0)
    line.plain, line.details = Cells(line, PLAIN_COLUMNS), Cells(line, DETAIL_COLUMNS)
    rowPool[index] = line

    return line
end

-- Shows the cells of the view in use, hides the other view's, and returns the shown ones.
local function ViewCells(line, details)
    for _, cell in ipairs(line.plain) do cell:SetShown(not details) end
    for _, cell in ipairs(line.details) do cell:SetShown(details) end

    return details and line.details or line.plain
end

-- A title line: gold for a section, pale blue for a group inside it.
local function ShowTitle(line, title, r, g, b, details)
    line.row = nil
    line.icon:Hide()
    local cells = ViewCells(line, details)
    for column, cell in ipairs(cells) do cell:SetText(column == 1 and title or "") end
    cells[1]:SetTextColor(r, g, b)
    line:Show()
end

-- This fight's cell: the drawn amount and, for damage, its share of the fight's drawn damage.
local function FightText(row)
    if row.hits == 0 then return "" end
    local share = row.share and string.format(" · %.0f %%", 100 * row.share) or ""

    return Amount(row.drawn) .. share
end

local function ShowRow(line, row, details)
    line.row = row
    line.icon:SetTexture(RowIcon(row.key))
    line.icon:Show()
    local cells = ViewCells(line, details)
    cells[1]:SetTextColor(1, 1, 1)
    cells[1]:SetText(row.name)
    if details then
        cells[2]:SetText(type(row.key) == "number" and tostring(row.key) or "")
        cells[3]:SetText(row.kind)
        cells[4]:SetText(row.state)
        cells[5]:SetText(row.hits > 0 and string.format("%s (%.0f)", Amount(row.drawn), row.hits) or "")
        cells[6]:SetText(row.meter and Amount(row.meter) or "")
        cells[7]:SetText(row.verdict or "")
    else
        local tone = TONES[row.tone]
        cells[2]:SetTextColor(tone[1], tone[2], tone[3])
        cells[2]:SetText(row.why ~= "" and row.status .. "  " .. DIM .. row.why .. "|r" or row.status)
        cells[3]:SetText(FightText(row))
        cells[4]:SetText(row.section == "heal" and row.check ~= "" and DIM .. row.check .. "|r" or row.check)
    end
    line:Show()
end

-- A title line before each section and each group inside it; unused pooled lines are hidden. The view (plain or
-- Details) follows CombatTextIconsDB.panelDetails on every rebuild.
local function Rebuild()
    local details = CombatTextIconsDB.panelDetails == true
    local views, fight = Resolve()
    window.title:SetText(Panel.Title())
    window.header:SetText(HeaderText(views, fight))
    window.summary:SetText(Panel.Summary(fight))
    window.details:SetText(details and "Simple" or "Details")
    for _, label in ipairs(window.plainLabels) do label:SetShown(not details) end
    for _, label in ipairs(window.detailLabels) do label:SetShown(details) end
    local used, section, group = 0, nil, nil
    for _, row in ipairs(Panel.Rows(fight)) do
        if row.section ~= section then
            section, group = row.section, nil
            used = used + 1
            ShowTitle(Line(used), SECTION_TITLES[section], 1, 0.82, 0, details)
        end
        if row.group ~= group then
            group = row.group
            used = used + 1
            ShowTitle(Line(used), "  " .. GROUP_TITLES[group], 0.55, 0.75, 1, details)
        end
        used = used + 1
        ShowRow(Line(used), row, details)
    end
    for index = used + 1, #rowPool do rowPool[index]:Hide() end
    content:SetHeight(math.max(used, 1) * ROW_HEIGHT)
end

local function Refresh()
    if broken then return end
    local ok, err = pcall(Rebuild)
    if ok then return end
    broken = true
    window:SetScript("OnUpdate", nil)
    print(PREFIX .. "learned window stopped refreshing: " .. tostring(err))
end

-- `<` goes to older fights (delta 1), `>` to newer ones and live (delta -1); both stop at the ends.
local function Step(delta)
    local views = Resolve()
    local index = Position(views, view)
    if index and views[index + delta] ~= nil then
        view = views[index + delta]
        Refresh()
    end
end

-- CombatTextIconsDB.panel is kept only as { point = string, x = number, y = number }; else dropped (opens centred).
local function SavedPosition()
    local saved = CombatTextIconsDB.panel
    if type(saved) == "table" and type(saved.point) == "string" and IsNumber(saved.x) and IsNumber(saved.y) then
        CombatTextIconsDB.panel = { point = saved.point, x = saved.x, y = saved.y }
    else
        CombatTextIconsDB.panel = nil
    end

    return CombatTextIconsDB.panel
end

-- Drag stop saves the window centre's offset from the screen centre. The frame stub's getters return tables,
-- so this only runs on a real drag, never at build time.
local function SavePosition(frame)
    frame:StopMovingOrSizing()
    frame:SetUserPlaced(false) -- CombatTextIconsDB.panel is the only saved position
    local x, y = frame:GetCenter()
    local parentX, parentY = UIParent:GetCenter()
    if not (IsNumber(x) and IsNumber(y) and IsNumber(parentX) and IsNumber(parentY)) then return end
    CombatTextIconsDB.panel = { point = "CENTER", x = x - parentX, y = y - parentY }
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x - parentX, y - parentY)
end

local function StepButton(frame, label, delta, x)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(24, 20)
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -28)
    button:SetText(label)
    button:SetScript("OnClick", function() Step(delta) end)

    return button
end

local function Build()
    local frame = CreateFrame("Frame", "CombatTextIconsPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", SavePosition)
    local saved = SavedPosition()
    if saved then
        frame:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    if frame.SetBackdrop then
        frame:SetBackdrop(BACKDROP)
        frame:SetBackdropColor(0, 0, 0, 0.85)
    end

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10) -- its text, the spec's, is set on every rebuild
    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    frame.close:SetScript("OnClick", function() Panel.Toggle() end) -- through Toggle, so `open` follows
    frame.older = StepButton(frame, "<", 1, 12)
    frame.newer = StepButton(frame, ">", -1, 38)
    frame.header = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.header:SetPoint("LEFT", frame.newer, "RIGHT", 10, 0)
    frame.details = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.details:SetSize(64, 20)
    frame.details:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -34, -28)
    frame.details:SetScript("OnClick", function()
        CombatTextIconsDB.panelDetails = CombatTextIconsDB.panelDetails ~= true
        Refresh()
    end)
    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -54)
    frame.summary:SetWidth(CONTENT_WIDTH)
    frame.summary:SetJustifyH("LEFT")
    frame.summary:SetWordWrap(false)

    frame.plainLabels, frame.detailLabels = {}, {}
    for _, set in ipairs({ { PLAIN_COLUMNS, frame.plainLabels }, { DETAIL_COLUMNS, frame.detailLabels } }) do
        for _, spec in ipairs(set[1]) do
            local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + spec.x, -72)
            label:SetWidth(spec.width)
            label:SetJustifyH(spec.justify or "LEFT")
            label:SetText(spec.label)
            set[2][#set[2] + 1] = label
        end
    end

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -88)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 12)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT_WIDTH, ROW_HEIGHT)
    scroll:SetScrollChild(content)

    local sinceRefresh = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        sinceRefresh = sinceRefresh + elapsed
        if sinceRefresh < REFRESH then return end
        sinceRefresh = 0
        Refresh()
    end)

    return frame
end

-- Opens on live while a fight is open, else the newest saved fight, else the empty state.
function Panel.Toggle()
    open = not open
    if not open then
        window:Hide()
        return
    end
    window = window or Build()
    Panel.frame = window
    view = Ledger.Current() and "live" or nil
    window:Show()
    Refresh()
end

function Panel.IsOpen()
    return open
end

-- The viewed fight: "live", a saved fight's `at`, or nil (no fights).
function Panel.View()
    return view
end
