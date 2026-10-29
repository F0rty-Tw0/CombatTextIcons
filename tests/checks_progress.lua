-- Unit checks for the fight-end learning popups: Progress (snapshot at fight start, diff when the
-- Teacher's read is done, priority, cap, area notices, skip and group, /cti progress, re-snapshot) and
-- Display.Notice (own 4 s life, top-of-screen row layout, batches, pooled reuse). Called by tests/checks.lua with
-- the same T table.
-- Every scenario boots its own rig; a Boot replaces the global stubs.

return function(T)
    local Check = T.Check
    local CLEAR, CROWDED, MORE = "area clear: '?' shown", "crowded: '?' hidden", "(/cti learned)"

    -- A scenario that errors fails one named check instead of ending the file.
    local function Scenario(name, run)
        local ok, err = pcall(run)
        if not ok then Check("progress: " .. name .. " ran without error: " .. tostring(err), false) end
    end

    -- A booted addon (`db` is the saved CombatTextIconsDB, `spells` loads the fixture table) with the
    -- area clear. Display.Notice records each popup as "<i> <text> <texture>"; rig.Read joins them with "; ".
    local function Rig(db, spells)
        local rig = { notices = {} }
        local ns = T.Boot(function() CombatTextIconsDB = db or { enabled = true } end, spells)
        rig.ns, rig.S = ns, T.State()
        rig.UNKNOWN = ns.Meter.UNKNOWN_ICON
        ns.Teacher.area = "clear"
        ns.Display.Notice = function(texture, text, i)
            rig.notices[#rig.notices + 1] = i .. " " .. text .. " " .. tostring(texture)
        end
        local char, castAt = T.Store(), 0
        -- `n` more fingerprint samples of `spellID`, one per new cast (school 4): 3 casts learn it.
        function rig.Casts(spellID, n)
            for _ = 1, n do
                castAt = castAt + 1
                ns.Fingerprints.Add(spellID, { school = 4, delay = 0.25, castAt = castAt, hops = 1 })
            end
        end
        -- A tick candidate with one sig of `votes` votes (school 32 needs 2, school 1 needs 3).
        function rig.Votes(spellID, votes, school)
            char.votes[spellID] = { casts = 6, sigs = { { kind = "dot", school = school or 32, period = 2, votes = votes,
                expected = 0.5 } } }
        end
        function rig.Tick(spellID, learned)
            char.learned[spellID] = learned and { school = 32, period = 2, kind = "dot", misses = 0, unpaired = 0 } or nil
        end
        function rig.Proc(id, streak, learned, period)
            char.procs[id] = { school = 106, lo = 100, hi = 110, streak = streak, learned = learned == true, unpaired = 0,
                seen = 0, period = period }
        end
        function rig.Unlearn(spellID) char.casts[spellID] = nil end
        -- Teacher.OnRead with `last` (default: a solo read of the current area); returns the popups shown.
        function rig.Read(last)
            rig.notices = {}
            ns.Teacher.OnRead(last or { session = 1, rows = {}, learned = {}, area = ns.Teacher.area })
            return table.concat(rig.notices, "; ")
        end
        -- One fight: Progress.Start, `during` changes the stores, then the read.
        function rig.Fight(during, last)
            ns.Progress.Start()
            if during then during() end
            return rig.Read(last)
        end
        -- A first read with nothing learned, so later reads show no first-read area notice.
        function rig.Warm()
            rig.Fight()
            return rig
        end
        function rig.Tex(id) return "tex:" .. id end
        return rig
    end

    Scenario("wiring", function()
        local rig = Rig()
        Check("progress wiring: Progress sets Teacher.OnRead at load", rig.ns.Teacher.OnRead ~= nil)
        Check("progress wiring: Display.MAX_NOTICES is 4", rig.ns.Display.MAX_NOTICES == 4)
        Check("progress wiring: the .toc loads Progress.lua between Display.lua and Panel.lua", (function()
            local files, at = T.TocFiles(), {}
            for index, file in ipairs(files) do at[file] = index end
            return at["Progress.lua"] ~= nil and at["Progress.lua"] == at["Display.lua"] + 1
                and at["Panel.lua"] == at["Progress.lua"] + 1
        end)())
        Check("progress wiring: no read without a fight start (idle)", rig.Read() == "")
    end)

    Scenario("core and teacher", function()
        -- The real path: combat start snapshots, a fingerprint learns mid-fight, the read's timer fires.
        local rig = Rig()
        local function Row(spellID, total)
            return { spellID = spellID, totalAmount = total, overkillAmount = 0 }
        end
        rig.S.sessions = { { sessionID = 5, name = "Mob", durationSeconds = 9, rows = { Row(77777, 100) } } }
        rig.Casts(591, 2)
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Casts(591, 1)
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        rig.notices = {}
        local timer = table.remove(rig.S.timers, 1)
        local ok = timer ~= nil and pcall(timer.fn)
        Check("progress core: combat start + Teacher read -> area notice, then learned! with the spell's icon",
            ok and table.concat(rig.notices, "; ") == "1 " .. CLEAR .. " " .. rig.UNKNOWN .. "; 2 learned! tex:591")

        rig = Rig()
        rig.ns.Meter.Disable("test")
        rig.ns.Core.PLAYER_REGEN_DISABLED()
        rig.Casts(591, 3)
        rig.notices = {}
        rig.ns.Core.PLAYER_REGEN_ENABLED()
        Check("progress core: a meter-off skip shows nothing", #rig.notices == 0)
    end)

    Scenario("area", function()
        local rig = Rig()
        Check("progress area: the first solo read since login always shows the area result (clear)",
            rig.Fight() == "1 " .. CLEAR .. " " .. rig.UNKNOWN)
        Check("progress area: a later read with the same area shows nothing", rig.Fight() == "")
        Check("progress area: a later read that turns the area crowded says so",
            rig.Fight(function() rig.ns.Teacher.area = "crowded" end) == "1 " .. CROWDED .. " " .. rig.UNKNOWN)
        Check("progress area: still crowded -> nothing", rig.Fight() == "")
        Check("progress area: crowded -> clear says so",
            rig.Fight(function() rig.ns.Teacher.area = "clear" end) == "1 " .. CLEAR .. " " .. rig.UNKNOWN)

        rig = Rig()
        rig.ns.Teacher.area = "crowded"
        Check("progress area: the first solo read since login, crowded",
            rig.Fight() == "1 " .. CROWDED .. " " .. rig.UNKNOWN)

        rig = Rig()
        rig.ns.Teacher.area = "unknown" -- a map no read decided yet (a group or short read keeps it)
        Check("progress area: the first solo read since login, area not decided yet",
            rig.Fight() == "1 new area: '?' hidden " .. rig.UNKNOWN)
    end)

    Scenario("skip and group", function()
        local rig = Rig()
        local all = true
        for _, reason in ipairs({ "no fight", "meter off", "read failed", "secret", "duplicate session" }) do
            all = all and rig.Fight(function() rig.Casts(9001, 1) end, { skip = reason }) == ""
        end
        Check("progress skip: a skipped read (any reason) shows nothing", all)
        Check("progress skip: the skip disarmed: a second read shows nothing", rig.Read() == "")
        Check("progress group: a group fight shows nothing",
            rig.Fight(function() rig.Casts(9002, 1) end, { session = 2, rows = {}, learned = {}, area = "group" }) == "")
        Check("progress group: skips and group reads leave the first-read area notice for the next solo read",
            rig.Fight() == "1 " .. CLEAR .. " " .. rig.UNKNOWN)
    end)

    Scenario("change kinds", function()
        local rig = Rig().Warm()
        local A, B, C, D, E, F, G, H, J, K = 9001, 9002, 9003, 9004, 9005, 9006, 9007, 9008, 9009, 9010
        rig.Casts(A, 2)
        Check("progress kinds: fingerprint 2 -> 3 casts is learned!", rig.Fight(function() rig.Casts(A, 1) end)
            == "1 learned! " .. rig.Tex(A))
        Check("progress kinds: an unchanged learned spell shows nothing", rig.Fight() == "")
        Check("progress kinds: a learned fingerprint that is gone is dropped",
            rig.Fight(function() rig.Unlearn(A) end) == "1 dropped " .. rig.Tex(A))
        rig.Casts(B, 1)
        Check("progress kinds: fingerprint 1 -> 2 casts is learning 2/3", rig.Fight(function() rig.Casts(B, 1) end)
            == "1 learning 2/3 " .. rig.Tex(B))
        Check("progress kinds: an ID absent before counts as n = 0 (learning 1/3)",
            rig.Fight(function() rig.Casts(C, 1) end) == "1 learning 1/3 " .. rig.Tex(C))
        rig.Votes(D, 1)
        Check("progress kinds: tick votes -> learned is learned!", rig.Fight(function() rig.Tick(D, true) end)
            == "1 learned! " .. rig.Tex(D))
        Check("progress kinds: a learned tick that is gone is dropped", rig.Fight(function() rig.Tick(D, false) end)
            == "1 dropped " .. rig.Tex(D))
        Check("progress kinds: physical tick votes 0 -> 1 is learning 1/3 (VOTES_MIN_PHYSICAL)",
            rig.Fight(function() rig.Votes(E, 1, 1) end) == "1 learning 1/3 " .. rig.Tex(E))
        Check("progress kinds: tick votes reaching the need, not learned, is learning (checking)",
            rig.Fight(function() rig.Votes(F, 2) end) == "1 learning (checking) " .. rig.Tex(F))
        rig.Proc(G, 1)
        Check("progress kinds: proc streak 1 -> 2 is learning 2/3", rig.Fight(function() rig.Proc(G, 2) end)
            == "1 learning 2/3 " .. rig.Tex(G))
        Check("progress kinds: proc streak 2 -> learned is learned!", rig.Fight(function() rig.Proc(G, 3, true) end)
            == "1 learned! " .. rig.Tex(G))
        Check("progress kinds: a learned proc that is gone is dropped",
            rig.Fight(function() T.Store().procs[G] = nil end) == "1 dropped " .. rig.Tex(G))
        Check("progress kinds: a rhythm proc candidate counts toward Procs.RHYTHM_STREAK (learning 1/2)",
            rig.Fight(function() rig.Proc(K, 1, false, 1.5) end) == "1 learning 1/2 " .. rig.Tex(K))
        rig.Proc(H, 2)
        Check("progress kinds: n fell (proc streak 2 -> 0) shows nothing", rig.Fight(function() rig.Proc(H, 0) end) == "")
        rig.Casts(J, 1)
        Check("progress kinds: n unchanged shows nothing", rig.Fight() == "")
    end)

    Scenario("precedence", function()
        local rig = Rig().Warm()
        rig.Tick(9001, true)
        Check("progress precedence: a learned tick owns its ID: a fingerprint candidate on it rising shows nothing",
            rig.Fight(function() rig.Casts(9001, 1) end) == "")
        rig.Votes(9002, 1)
        rig.Casts(9002, 1)
        Check("progress precedence: tick votes own the ID before a fingerprint candidate",
            rig.Fight(function() rig.Casts(9002, 1) end) == "")
        rig.Casts(9003, 1)
        rig.Proc(9003, 1)
        Check("progress precedence: a fingerprint candidate owns the ID before a proc candidate",
            rig.Fight(function() rig.Proc(9003, 2) end) == "")
        rig.Votes(9004, 0)
        rig.Casts(9004, 1)
        Check("progress precedence: a 0-vote tick candidate claims nothing (as the panel): the fingerprint shows",
            rig.Fight(function() rig.Casts(9004, 1) end) == "1 learning 2/3 " .. rig.Tex(9004))

        rig = Rig(nil, true).Warm()
        local CORRUPTION_TICK = 146739 -- a Spells.lua (fixture) tick icon
        Check("progress precedence: table rows are excluded: tick votes on a table icon show",
            rig.Fight(function() rig.Votes(CORRUPTION_TICK, 1) end) == "1 learning 1/2 " .. rig.Tex(CORRUPTION_TICK))
    end)

    Scenario("priority and cap", function()
        local rig = Rig().Warm()
        rig.Casts(500, 2)
        rig.Casts(400, 2)
        rig.Tick(300, true)
        rig.Casts(200, 1)
        Check("progress priority: learned (lower ID first), then dropped, then learning; 4 changes fit",
            rig.Fight(function()
                rig.Casts(500, 1)
                rig.Casts(400, 1)
                rig.Tick(300, false)
                rig.Casts(200, 1)
            end) == "1 learned! tex:400; 2 learned! tex:500; 3 dropped tex:300; 4 learning 2/3 tex:200")

        rig = Rig().Warm()
        rig.Casts(500, 2)
        rig.Casts(400, 2)
        rig.Tick(300, true)
        Check("progress cap: 6 changes -> 3 popups and '+3 more (/cti learned)' with the '?' icon",
            rig.Fight(function()
                rig.Casts(500, 1)
                rig.Casts(400, 1)
                rig.Tick(300, false)
                rig.Casts(200, 1)
                rig.Casts(210, 1)
                rig.Casts(220, 1)
            end) == "1 learned! tex:400; 2 learned! tex:500; 3 dropped tex:300; 4 +3 more " .. MORE .. " " .. rig.UNKNOWN)

        rig = Rig()
        rig.Casts(500, 2)
        rig.Casts(400, 2)
        rig.Tick(300, true)
        Check("progress cap: the first-read area notice ranks first, never folded into '+K more'",
            rig.Fight(function()
                rig.Casts(500, 1)
                rig.Casts(400, 1)
                rig.Tick(300, false)
                rig.Casts(200, 1)
            end) == "1 " .. CLEAR .. " " .. rig.UNKNOWN .. "; 2 learned! tex:400; 3 learned! tex:500; 4 +2 more "
                .. MORE .. " " .. rig.UNKNOWN)
    end)

    Scenario("toggle", function()
        local rig = Rig()
        local S = rig.S
        local function Slash(message) SlashCmdList.COMBATTEXTICONS(message) end
        Check("progress toggle: on by default (showProgress nil)", CombatTextIconsDB.showProgress == nil)
        Slash("progress off")
        Check("progress toggle: /cti progress off saves showProgress = false and prints",
            CombatTextIconsDB.showProgress == false and S.prints[#S.prints]:find("progress popups off", 1, true) ~= nil)
        Check("progress toggle: off ignores the fight start and the read", rig.Fight(function() rig.Casts(9001, 1) end) == "")
        Slash("progress on")
        Check("progress toggle: /cti progress on saves showProgress = true", CombatTextIconsDB.showProgress == true)
        Check("progress toggle: on -> idle: a read without a fight start shows nothing", rig.Read() == "")
        Check("progress toggle: on: the next fight shows its popups",
            rig.Fight(function() rig.Casts(9002, 1) end) == "1 " .. CLEAR .. " " .. rig.UNKNOWN .. "; 2 learning 1/3 tex:9002")
        rig.ns.Progress.Start()
        rig.Casts(9003, 1)
        Slash("progress off")
        Check("progress toggle: off while armed disarms", rig.Read() == "")
        Slash("progress on")
        Check("progress toggle: on again after the disarm stays idle", rig.Read() == "")
        rig.ns.Progress.Start()
        Slash("progress on")
        Check("progress toggle: on while armed keeps the snapshot",
            (function() rig.Casts(9004, 1) return rig.Read() end)() == "1 learning 1/3 tex:9004")
        local before = CombatTextIconsDB.showProgress
        Slash("progress maybe")
        Check("progress toggle: a bad word prints the usage and changes nothing",
            S.prints[#S.prints]:find("usage: /cti progress on|off", 1, true) ~= nil and CombatTextIconsDB.showProgress == before)
        Slash("bogus")
        Check("progress toggle: the /cti usage line lists progress", S.prints[#S.prints]:find("|progress|", 1, true) ~= nil)

        rig = Rig({ enabled = true, showProgress = "yes" })
        Check("progress toggle: a saved non-boolean showProgress loads as nil (on)", CombatTextIconsDB.showProgress == nil
            and rig.Fight() == "1 " .. CLEAR .. " " .. rig.UNKNOWN)
        rig = Rig({ enabled = true, showProgress = false })
        Check("progress toggle: a saved off stays off", rig.Fight() == "")
        rig = Rig({ enabled = false })
        Slash("progress off")
        Check("progress toggle: works while the addon is off", CombatTextIconsDB.showProgress == false)

        -- Minimap tooltip: the OnEnter handler's lines.
        rig = Rig()
        local lines = {}
        GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
        local button = rig.ns.MinimapButton.button
        local function Has(text)
            for _, line in ipairs(lines) do if line == text then return true end end
            return false
        end
        button.scripts.OnEnter(button)
        local onShown = Has("Progress popups: on")
        lines = {}
        Slash("progress off")
        button.scripts.OnEnter(button)
        Check("progress toggle: the minimap tooltip shows 'Progress popups: on|off'", onShown and Has("Progress popups: off"))
    end)

    Scenario("re-snapshot", function()
        local rig = Rig().Warm()
        rig.ns.Progress.Start()
        rig.Casts(9001, 1)
        rig.ns.Progress.Start() -- a fight that starts before the previous read fired
        rig.Casts(9002, 1)
        Check("progress re-snapshot: a second fight start re-snapshots; the earlier change is lost",
            rig.Read() == "1 learning 1/3 tex:9002")
    end)

    -- Display.Notice on the real Display.lua (frame stubs recording points, alpha, shown and text; a text is 7
    -- pixels wide per character).
    -- User, 2026-10-28: each row centred on its own under the character, so the icons zigzagged. Rows now sit at the
    -- top of the screen, every icon at one x, the text left-justified right of it, the block centred on its widest row.
    Scenario("display notice", function()
        local ns = T.Boot()
        local S = T.State()
        local frames, createFrame = {}, CreateFrame
        CreateFrame = function(...)
            local frame = createFrame(...)
            frame.SetPoint = function(self, point, anchor, relativePoint, x, y)
                self.at = { point = point, anchor = anchor, relativePoint = relativePoint, x = x, y = y }
            end
            frame.SetAlpha = function(self, value) self.alpha = value end
            frame.Show = function(self) self.shown = true end
            frame.Hide = function(self) self.shown = false end
            frame.CreateFontString = function(self)
                local text = T.Generic()
                text.SetTextColor = function(_, r, g, b) self.color = { r, g, b } end
                text.SetText = function(_, value) self.label = value end
                text.SetPoint = function(_, point, anchor, relativePoint, x)
                    self.textAt = { point = point, anchor = anchor, relativePoint = relativePoint, x = x }
                end
                text.GetStringWidth = function() return 7 * #self.label end
                return text
            end
            frames[#frames + 1] = frame
            return frame
        end
        local born = S.now
        local lines = { "learned!", "learning 1/3", "learning (checking)", "+2 more (/cti learned)" }
        for i = 1, 4 do ns.Display.Notice("tex:" .. i, lines[i], i) end
        ns.Display.Plate(T.Plate("nameplate1"), "tex", 1000, "", 36)
        local plate = frames[5]
        local function Near(a, b) return type(a) == "number" and math.abs(a - b) <= 1e-6 end
        local layout = #frames == 5
        for i = 1, 4 do
            local at, textAt = frames[i].at, frames[i].textAt
            layout = layout and at.anchor == UIParent and at.point == "LEFT" and at.relativePoint == "TOP"
                and Near(at.x, -(22 + 3 + 7 * 22) / 2) and Near(at.y, -200 - (i - 1) * 26)
                and textAt.point == "LEFT" and textAt.anchor == frames[i] and textAt.relativePoint == "LEFT"
                and textAt.x == 25 and frames[i].label == lines[i]
                and frames[i].color[1] == 1 and frames[i].color[2] == 1 and frames[i].color[3] == 1
        end
        Check("notice: row i's LEFT at UIParent TOP, y = NOTICE_Y - (i - 1) * ROW, one x centring the widest row "
            .. "(icon + gap + 154 px), text 25 right of the popup's left, white", layout)
        ns.Display.Update(born + 2)
        Check("notice: alive at 2 s, no rise, full alpha; the plate popup (1.2 s life) is gone",
            frames[1].shown and Near(frames[1].at.y, -200) and Near(frames[1].alpha, 1) and plate.shown == false)
        ns.Display.Update(born + 3.825)
        Check("notice: fades out over its own 4 s life (alpha 0.5 at 3.825 s)", frames[4].shown and Near(frames[4].alpha, 0.5))
        ns.Display.Update(born + 4)
        Check("notice: released at 4 s", not frames[1].shown and not frames[4].shown)

        -- Popups are pooled: row 1's frame comes back for a plate hit and must centre on the plate as before.
        local plate2 = T.Plate("nameplate2")
        ns.Display.Plate(plate2, "tex", 1000, "", 36)
        local reused = frames[1]
        Check("notice: a notice's frame reused for a plate centres again (text CENTER 12.5 right of the popup)",
            #frames == 5 and reused.shown and reused.at.anchor == plate2 and reused.at.point == "BOTTOM"
            and reused.textAt.point == "CENTER" and reused.textAt.anchor == reused and reused.textAt.x == 12.5)
        ns.Display.Update(born + 6)

        S.now = born + 10
        for i = 1, 4 do ns.Display.Notice("tex", "old " .. i, i) end
        ns.Display.Notice("tex", "new 1", 1)
        CreateFrame = createFrame
        local shown, newShown = 0, false
        for _, frame in ipairs(frames) do
            if frame.shown then
                shown = shown + 1
                newShown = frame.label == "new 1"
            end
        end
        Check("notice: i = 1 starts a new batch: the previous notices are released (pooled frames reused)",
            shown == 1 and newShown and #frames == 5)
    end)

    -- User, 2026-10-28: the text started at the plate's centre with the icon left of it, not centred as a whole. The
    -- text centres (ICON_SIZE 22 + ICON_GAP 3) / 2 right of the popup's centre and the icon hangs off its left, so the
    -- pair centres without reading the text's width; with no icon the text centres alone.
    Scenario("display centres icon and text together", function()
        local ns = T.Boot()
        local createFrame, popups = CreateFrame, {}
        CreateFrame = function(...)
            local frame = createFrame(...)
            frame.CreateFontString = function()
                local text = T.Generic()
                text.SetPoint = function(self, point, anchor, relativePoint, x)
                    self.at = { point = point, anchor = anchor, relativePoint = relativePoint, x = x }
                end
                frame.text = text
                return text
            end
            frame.CreateTexture = function()
                local icon = T.Generic()
                icon.SetPoint = function(self, point, anchor, relativePoint, x)
                    self.at = { point = point, anchor = anchor, relativePoint = relativePoint, x = x }
                end
                icon.SetShown = function(self, shown) self.shown = shown end
                return icon
            end
            popups[#popups + 1] = frame
            return frame
        end
        ns.Display.Plate(T.Plate("nameplate1"), "tex", 1000, "", 36)
        ns.Display.Plate(T.Plate("nameplate2"), nil, 1000, "", 36)
        CreateFrame = createFrame
        local withIcon, bare = popups[#popups - 1], popups[#popups]
        local text, icon = withIcon.text.at, withIcon.icon.at
        Check("display: the text centres 12.5 right of the popup, the icon hangs 3 off its left; no icon: x 0",
            text.point == "CENTER" and text.anchor == withIcon and text.x == 12.5
            and icon.point == "RIGHT" and icon.anchor == withIcon.text and icon.relativePoint == "LEFT" and icon.x == -3
            and bare.text.at.point == "CENTER" and bare.text.at.x == 0)
    end)
end
