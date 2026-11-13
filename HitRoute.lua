-- Combat Text Icons: the enemy-hit route. A hit or miss on an enemy plate (Core.UNIT_COMBAT) is named by the tracker,
-- a learned cast, proc, stack, volley, link, twin or echo, held to its frame's end (Hold*, Core.FlushMates), or left to
-- the question mark route (Question); Core.lua's header tells the whole route. Core.FlushMates is HitRoute.FlushMates.
-- The Touch of Weakness hold is TowHold.lua's; the heals on you are PlayerHits.lua's.

local _, ns = ...
local Meter, Tracker, Display, Learn, Streams, Casts, Fingerprints, Procs, Ledger, Teacher =
    ns.Meter, ns.Tracker, ns.Display, ns.Learn, ns.Streams, ns.Casts, ns.Fingerprints, ns.Procs, ns.Ledger, ns.Teacher
local Heals = ns.Heals
local DebugLog = ns.DebugLog
local ShowValue, ShowRaw, ShowIsTarget, ShowThreat, ShowGroup, ShowNPC = DebugLog.ShowValue, DebugLog.ShowRaw,
    DebugLog.ShowIsTarget, DebugLog.ShowThreat, DebugLog.ShowGroup, DebugLog.ShowNPC

local HitRoute = {}
ns.HitRoute = HitRoute

local MINE_WAIT = 1.5   -- a held hit no mate explains may be a learned proc's on a plate yours drew on this long before

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

local db

-- The saved variables the '?' icon option lives in (Core.ADDON_LOADED).
function HitRoute.Init(saved)
    db = saved
end

local MISSES = { MISS = true, DODGE = true, PARRY = true, BLOCK = true, RESIST = true, IMMUNE = true,
    EVADE = true, DEFLECT = true, REFLECT = true }
local MITIGATED = { ABSORB = true, BLOCK = true, RESIST = true }

-- A hit fully absorbed, blocked or resisted shows Blizzard's word instead of "0".
local function HitText(flagText, amount)
    if Plain(amount) and amount == 0 and Plain(flagText) and MITIGATED[flagText] then
        return _G[flagText] or flagText
    end
    return amount
end

local function InGroup()
    local inGroup = IsInGroup()
    return not Plain(inGroup) or inGroup -- unknown counts as grouped
end

-- Every popup over an enemy plate goes through here. On Forever while grouped it draws nothing: Blizzard's numbers are
-- back there (BlizzardText.Sync) and the addon names only DoT ticks (2026-11-10 dungeon log: 50 of 2861 hits), so a
-- drawn tick showed twice. The routes still run: learning and the ledger are untouched. While Owner is active
-- (ns.Owner.IsActive) the hits it released are yours and draw, grouped or not.
local function DrawPlate(...)
    if ns.IsForever and InGroup() and not ns.Owner.IsActive() then return end
    return Display.Plate(...)
end

local function IsTarget(unit)
    local ok, isTarget = pcall(UnitIsUnit, unit, "target")
    return ok and Plain(isTarget) and isTarget
end

-- The HIT debug line of a hit, written at its arrival (Wound; Owner.Hit for a grouped hit it holds). The offline replay
-- (tests/checks_owner_replay.lua) parses this exact line.
function HitRoute.LogHit(unit, school, amount, flagText)
    if not ns.Debug then return end
    ns.Debug("HIT %s school=%s amount=%s flag=%s fps=%.0f threat=%s group=%s npc=%s target=%s", unit, ShowValue(school),
        ShowValue(amount), ShowValue(flagText), GetFramerate(), ShowThreat(unit), ShowGroup(), ShowNPC(unit),
        ShowIsTarget(unit))
end

-- Whether the hit was on your target: an owned hit (Owner's release) answers with the target it had at arrival, since
-- the target may have changed by the release; any other hit asks the unit now.
local function OnTarget(unit, owned)
    if owned then return owned.isTarget == true end

    return IsTarget(unit)
end

-- The unit's GUID when plain, else nil.
local function PlainGUID(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if ok and Plain(guid) then return guid end
end

-- Creature IDs whose units keep no threat list (training dummies), learned this session from
-- the target; `probe` is the one targeted unit being tested: { guid, first, hits }.
local noThreatList, probe = {}, nil
local DUMMY_HITS, DUMMY_SPAN = 5, 2 -- a target answering "no threat list" this often, this long

-- A plain GUID's creature ID, or nil for anything that is not a creature.
local function CreatureID(guid)
    return guid and guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
end

-- The target answered "no threat list" after your hit: counts toward learning its creature ID.
local function ProbeDummy(guid, npcID, now)
    if noThreatList[npcID] then return end
    if not probe or probe.guid ~= guid then probe = { guid = guid, first = now, hits = 0 } end
    probe.hits = probe.hits + 1
    if probe.hits >= DUMMY_HITS and now - probe.first >= DUMMY_SPAN then
        noThreatList[npcID], probe = true, nil
    end
end

-- A mob fighting you has you on its threat list; strangers' mobs do not. When that cannot
-- be read only your target counts, plus units of a learned training-dummy ID (dummies keep
-- no threat list: plain nil on the target for 5 hits over 2 s learns its creature ID; any
-- threat answer from that ID un-learns it). Spec 2026-10-25-dummies.
local function FightsYou(unit, now)
    local ok, threat = pcall(UnitThreatSituation, "player", unit)
    local guid = PlainGUID(unit)
    local npcID = CreatureID(guid)
    local dummy = npcID ~= nil and noThreatList[npcID] == true
    if not ok or issecretvalue(threat) then return IsTarget(unit) or dummy end
    if threat ~= nil then
        if npcID then noThreatList[npcID] = nil end
        if probe and probe.guid == guid then probe = nil end
        return true
    end
    if IsTarget(unit) then
        if npcID then ProbeDummy(guid, npcID, now) end
        return true
    end
    return dummy
end

-- Whether `unit` is a creature that keeps no threat list (plain nil): a training dummy, yours or a stranger's.
local function NoThreatList(unit)
    local ok, threat = pcall(UnitThreatSituation, "player", unit)

    return ok and not issecretvalue(threat) and threat == nil and CreatureID(PlainGUID(unit)) ~= nil
end

local function SpellTexture(spellID)
    return (C_Spell.GetSpellTexture(spellID))
end

-- The Ledger key of a hit no spell could be named for: "?<school>", or "?" when the school is secret
-- (or not a whole number; "%d" would raise on a fraction).
local function UnknownKey(school)
    if Plain(school) and type(school) == "number" and school % 1 == 0 then return string.format("?%d", school) end

    return "?"
end

-- The question mark icon, or nil (number only) when the user turned '?' icons off.
local function UnknownTexture()
    if db.showUnknown == false then return nil end

    return Meter.UNKNOWN_ICON
end

-- frameHits = { at = a frame's stamp, list = its hits on enemy plates, each { amount, school, flagText, plate,
-- spellID = the icon it drew, nil when none } }: a heal on you in that frame may be a learned share of one
-- (Heals.Claim), a held hit like one drawn is that spell's (LikeDrawn)
local frameHits = { list = {} }

-- mine[plate] = the stamp of the newest hit drawn with your icon on that plate (Drawn); a removed plate forgets it.
local mine = {}

-- Whether a hit of yours drew on the plate in the MINE_WAIT before `now`.
local function MineRecently(plate, now)
    local at = mine[plate]

    return at ~= nil and now - at <= MINE_WAIT
end

-- A hit on an enemy plate at `now`: its frame keeps it for the frame's heals (Drawn names it). Heals and held hits
-- (Core.FlushMates) of an earlier frame still waiting are drawn first, before their frame's hits give way.
local function FrameHit(amount, school, now, flagText, plate)
    if frameHits.at ~= now then
        ns.PlayerHits.FlushHeals(now)
        HitRoute.FlushMates(now)
        frameHits = { at = now, list = {} }
    end
    frameHits.list[#frameHits.list + 1] = { amount = amount, school = school, flagText = flagText, plate = plate }
end

-- A hit was drawn with this spell's icon: the teacher tallies it, a running heal train of its row ticks
-- (Heals.Struck), and its frame entry (FrameHit) takes the ID: the newest, or for a hit held to its frame's end
-- (`at`, Core.FlushMates) the newest unnamed one of its amount, or `entry` itself when the caller kept it
-- (TowHold.Decide; `at` is then its stamp, and no amount is compared: a frame's other amounts may be secret).
local function Drawn(spellID, amount, at, entry)
    local now = at or ns.Now() -- the route clock holds a released hit's stamp, else the game clock
    local hit = entry
    if not entry and frameHits.at == now then
        for index = #frameHits.list, 1, -1 do
            local entry = frameHits.list[index]
            if not at or (entry.amount == amount and not entry.spellID) then
                hit = entry
                break
            end
        end
    end
    Teacher.Drawn(spellID, amount, now, hit and hit.school)
    Heals.Struck(spellID, now)
    if hit then
        hit.spellID = spellID
        mine[hit.plate] = now
    end
end

-- Why a solo unexplained hit or heal stays hidden when the area is not clear: no meter to
-- check it against, no read decided this map yet (Teacher.NotCrowded still holds), or the area is crowded.
local function HiddenRoute()
    if not Meter.Available() then return "HIDDEN (meter off)" end

    return Teacher.NotCrowded() and "HIDDEN (new area)" or "HIDDEN (crowded)"
end

-- Whether a hit of `school` like this one (normal-scale sizes within Procs.TWIN) landed on another plate earlier in
-- its frame (frameHits): a split hit's other share, which a proc's twin band needs (Procs.Name).
local function FrameTwin(plate, school, amount, flagText, now)
    local size = Streams.NormalAmount(amount, flagText)
    if not size or frameHits.at ~= now then return false end
    for index = 1, #frameHits.list - 1 do
        local entry = frameHits.list[index]
        local other = entry.school == school and entry.plate ~= plate
            and Streams.NormalAmount(entry.amount, entry.flagText)
        if other and math.abs(other - size) <= Procs.TWIN * size then return true end
    end

    return false
end

-- A solo hit on a mob fighting you that a learned proc names, while the area is not crowded (Teacher.NotCrowded):
-- draws the proc's icon and tallies it. Returns whether it drew; false leaves the hit to the question-mark route.
-- An unlearned cast of another spell whose samples place a hit like it here (Casts.SampledAt) keeps it from the proc.
-- `held`: the hit was held to its frame's end (DrawMate), so Drawn names its frame entry by amount.
local function ProcWound(plate, school, amount, flagText, now, held)
    local twin = FrameTwin(plate, school, amount, flagText, now)
    local procID = Teacher.NotCrowded() and Procs.Name(school, amount, flagText, twin)
    if not procID or Casts.SampledAt(plate, now, school, Streams.NormalAmount(amount, flagText), procID) then
        return false
    end
    if ns.Debug then ns.Debug("  -> proc %s", ShowValue(procID)) end
    Drawn(procID, amount, held and now or nil)
    Ledger.Add("damage", procID, amount)
    DrawPlate(plate, SpellTexture(procID), HitText(flagText, amount), flagText, school)

    return true
end

-- Draws a hit with a learned rhythm proc's icon and tallies it; returns true. `onsetAt` is the first tick of the
-- burst the hit belongs to, when known: the onset links learn from it (Procs.Drew). `held`: a hit held to its frame's
-- end (Core.FlushMates), tallied at its own stamp.
local function DrawRhythm(plate, rhythmID, school, amount, flagText, now, onsetAt, held)
    if ns.Debug then ns.Debug("  -> rhythm %s", ShowValue(rhythmID)) end
    Procs.Drew(rhythmID, now, onsetAt)
    Drawn(rhythmID, amount, held and now or nil)
    Ledger.Add("damage", rhythmID, amount)
    DrawPlate(plate, SpellTexture(rhythmID), HitText(flagText, amount), flagText, school)

    return true
end

-- Draws a hit whose stream fits a learned rhythm proc (ticks that share no size band, or its steady fall) with that
-- row's icon; a hit before its stream is born is named by a logged cast of the proc's row that its band holds
-- (Procs.NameCast).
-- `candidates` is Casts.Candidates for the hit. Returns whether it drew.
local function RhythmWound(plate, stream, school, amount, flagText, candidates, now)
    if not Teacher.NotCrowded() then return false end
    local rhythmID = Procs.NameStream(stream)
    local onsetAt = stream and not stream.procFell and stream.birth or nil
    if not rhythmID then rhythmID, onsetAt = Procs.NameCast(school, amount, flagText, candidates), now end
    if not rhythmID then return false end

    return DrawRhythm(plate, rhythmID, school, amount, flagText, now, onsetAt)
end

-- Draws a loose hit (no stream took it) that a learned rhythm's onset link names (Procs.NameOnset): the burst's
-- first tick, at its link's delay after the cast that leads it. Returns whether it drew.
local function OnsetWound(plate, stream, school, amount, flagText, now)
    if stream or not Teacher.NotCrowded() then return false end
    local rhythmID = Procs.NameOnset(school, amount, flagText, now)
    if not rhythmID then return false end

    return DrawRhythm(plate, rhythmID, school, amount, flagText, now)
end

-- Draws a loose hit (no stream took it) that pairs with the tick one learned rhythm period before it on the plate
-- (Procs.NamePair), or that ends a learned rhythm's steady fall over the plate's loose ticks (Procs.NameFall), when no
-- unlearned cast may have made it: a learned cast's own hit was claimed before (Casts.Claim).
-- Nor may a learned DoT's cast in the hit's window (Casts.TickerAt): an off-beat tick the tracker missed is the DoT's,
-- and run mage F6 paired Arcane Missiles 5143's as the mislearned proc 153626. `candidates` is Casts.Candidates for the
-- hit; `held`: a frame mate's (DrawMate). Returns whether it drew.
local function PairWound(plate, stream, school, amount, flagText, candidates, now, held)
    if stream or not Teacher.NotCrowded() then return false end
    for _, cast in ipairs(candidates) do
        if not Fingerprints.IsLearned(cast.castID) then return false end
    end
    if Casts.TickerAt(plate, now, school) then return false end
    local loose = Streams.Loose(plate, school)
    local rhythmID, partnerAt = Procs.NamePair(loose, school, amount, flagText, now)
    -- a collapse's tick under the band (Procs.NameFall) teaches no onset link: none names a hit under the band
    if not rhythmID then rhythmID, partnerAt = Procs.NameFall(loose, school, amount, flagText, now), nil end
    if not rhythmID then return false end

    return DrawRhythm(plate, rhythmID, school, amount, flagText, now, partnerAt, held)
end

-- Draws a hit on your target that a learned swing entry names (Procs.NameSwing) and tallies it; returns whether it drew.
-- A hit on a cast's stamp (`candidates`, Casts.Candidates) is the cast's to explain, never a swing.
local function SwingWound(plate, unit, school, amount, flagText, candidates, now, owned)
    if not (Teacher.NotCrowded() and OnTarget(unit, owned)) then return false end
    for _, cast in ipairs(candidates) do
        if cast.castAt == now then return false end
    end
    local swingID = Procs.NameSwing(plate, school, amount, flagText, now)
    if not swingID then return false end
    if ns.Debug then ns.Debug("  -> swing %s", ShowValue(swingID)) end
    Drawn(swingID, amount)
    Ledger.Add("damage", swingID, amount)
    DrawPlate(plate, SpellTexture(swingID), HitText(flagText, amount), flagText, school)

    return true
end

-- The next frame flushes what waits for its frame's end (PlayerHits.QueueFlush, which loads after this file).
local function QueueFlush() ns.PlayerHits.QueueFlush() end

-- A hit on a creature with no threat list that does not fight you (a dummy you do not target, of an ID the dummy
-- probe has not learned) waits for the end of its frame (held): an AoE's hit on it is often logged before its target
-- hit in that frame. Run warrior F3: Thunder Clap 6343's 614887 on nameplate4 (npc 107483) came the line before its
-- 1176829 on the target, and its row 2899923 held both. At the frame's end it is a mate when a solo hit of its school
-- on a mob fighting you shares the frame (ownFrame): a learned cast that claimed it (its area, Casts.lua) and drew in
-- that frame draws it (DrawMate), else the area pass may weigh it (Teacher.Mate). A mate is never a '?', no '?' hit the other passes learn from, and
-- no wound of the crowd check: fed to the '?' hits, mates cut shaman5's right from 22.5 % to 15.0 % (its Earthquake
-- ground ticks). A hit with no such hit in its frame is a stranger's and stays hidden, unless a learned proc names it
-- on a plate yours drew on just before (DrawMate).
-- ownFrame = { at = a frame's stamp, schools = { [school] = true } }; held = { at = the frame's stamp, hits = { {
-- plate, school, amount, flagText, kind, record }, ... } } (kind, record: its Casts.Claim answer; a held share has
-- `share` instead, HoldShare, a held ground crit `ground`, its record, HoldGround, a held splash `spread`, its
-- record, HoldSpread, a held chain hop `hop`, its record, HoldHop, and a held hit on a Mind Blast or Smite's cast
-- stamp `tickless`, that spell's ID, HoldTickless).
local ownFrame, held = { schools = {} }, { hits = {} }

-- A solo hit of `school` landed on a mob fighting you at `now`: its frame's held hits of that school are mates.
local function OwnHit(school, now)
    if ownFrame.at ~= now then ownFrame = { at = now, schools = {} } end
    ownFrame.schools[school] = true
end

-- Whether a hit of `base` was drawn in the frame of stamp `at` (frameHits).
local function DrawnInFrame(base, at)
    if frameHits.at ~= at then return false end
    for _, hit in ipairs(frameHits.list) do
        if hit.spellID == base then return true end
    end

    return false
end

-- The one spell a held hit is like: the ID every hit of its school drawn in its frame within Streams.SIZE_GUARD of
-- its normal-scale size drew, while no unclaimed hit like that drawn hit landed on another plate than its own in the
-- QUIET before (Casts.QuietNear), else nil. Run warrior F3: Thunder Clap 6343, learned on a lone target, drew 561131
-- and 1176829 (crit) on its target while its 547076 and 614887 on the dummy beside it hid; the area pass learned it
-- only at the fight's end, the log's last.
local function LikeDrawn(hit)
    local base, size = nil, Streams.NormalAmount(hit.amount, hit.flagText)
    for _, entry in ipairs(frameHits.at == hit.at and frameHits.list or {}) do
        local own = entry.spellID and entry.school == hit.school and Streams.NormalAmount(entry.amount, entry.flagText)
        if own and math.abs(own - size) <= Streams.SIZE_GUARD * math.max(own, size)
            and Casts.QuietNear(entry.plate, hit.school, own, hit.at) then
            if base ~= nil and base ~= entry.spellID then return nil end
            base = entry.spellID
        end
    end

    return base
end

-- Draws a hit held to its frame's end as the learned cast `record` (`route` for /cti debug) and tallies it.
-- `accepted`: the record took the hit when it was claimed (HoldTick).
local function DrawHeld(hit, record, route, accepted)
    if ns.Debug then ns.Debug("  -> %s %s", route, ShowValue(record.spellID)) end
    if not accepted then Casts.Accept(record, hit.plate, hit.at, Streams.NormalAmount(hit.amount, hit.flagText)) end
    Tracker.OnDirectHit(hit.plate, record.spellID, hit.at)
    Streams.Landed(hit.plate, record.spellID, hit.at)
    Drawn(record.base, hit.amount, hit.at)
    Ledger.Add("damage", record.base, hit.amount)
    DrawPlate(hit.plate, SpellTexture(record.spellID), HitText(hit.flagText, hit.amount), hit.flagText, hit.school)
end

-- A held hit at its frame's end, when `mated`: drawn when a learned cast claimed it and drew a hit in its frame (an
-- AoE lands on its target and the plates around at once) while no unclaimed hit like it landed on another plate in
-- the QUIET before (Casts.Quiet), or when it is LikeDrawn, else given to the area pass. Run shaman5 F2: 470057's 4 crits on other dummies came
-- in the frame of its own 50953 on the target, and draw. Run mage F7: Arcane Blast 30451's record took 3 Arcane hits on
-- 3 other dummies (1152-2387) as its Splash, 0.45 s after its own hit, in the frame of an Arcane Missiles 5143 tick on
-- the target; drawn, their 4701 ran past its row (mage over 0.46 % -> 0.68 %). Run druid2 F3: another spell's ~10.5K
-- hits on all 5 dummies came 0.67 s before Primal Wrath 285381's cast, and its 4 mates of that size drew its row 7690
-- over (druid2 over 0.00 % -> 0.06 %).
-- A mated held hit that is like none pairs on its own plate with the tick a learned rhythm period before it (PairWound,
-- with its plate's casts): run lock3 F2, Darkglare 205231's second beams on 4 dummies hid while its target's went '?'
-- (an unlearned Agony 980 cast at the target 0.6 s before may have made that one).
-- A held hit with no mate is drawn when a learned proc names it (ProcWound) on a plate one of your hits drew on in the
-- MINE_WAIT before (MineRecently), else hidden, and kept for the teacher as a stranger (Teacher.Stranger): an AoE's
-- splash a frame apart from its target hit is one too. Run warrior F3: proc 435791's 697818 on a dummy came 0.03 s after
-- 435222's mate on that dummy, alone in its frame, and hid (row 1403166 drew half). Run druid F11: a stranger's holy hits
-- (2.5-3.2K) on dummies you never drew on fit learned proc 1260076's band; with no plate test they drew wrong (0.1 %).
-- `ticked[base]`: a ground cast's held hits of the frame draw as its tick (FlushMates).
local function DrawMate(hit, mated, ticked)
    if not mated then
        if MineRecently(hit.plate, hit.at) and ProcWound(hit.plate, hit.school, hit.amount, hit.flagText, hit.at, true) then return end
        Teacher.Stranger(hit.plate, hit.school, hit.amount, hit.at, hit.flagText)
        if ns.Debug then ns.Debug("  -> HIDDEN") end
        return
    end
    local claimed = hit.kind == "learned" and (DrawnInFrame(hit.record.base, hit.at) or ticked[hit.record.base])
        and Casts.Quiet(hit.record, hit.school, hit.at)
    if not claimed then
        local base = LikeDrawn(hit)
        if base then
            if ns.Debug then ns.Debug("  -> like %s", ShowValue(base)) end
            Drawn(base, hit.amount, hit.at)
            Ledger.Add("damage", base, hit.amount)
            DrawPlate(hit.plate, SpellTexture(base), HitText(hit.flagText, hit.amount), hit.flagText, hit.school)
            return
        end
        if PairWound(hit.plate, hit.stream, hit.school, hit.amount, hit.flagText,
            Casts.Candidates(hit.plate, hit.at, hit.school), hit.at, true) then return end
        Teacher.Mate(hit.plate, hit.school, hit.amount, hit.at, hit.flagText)
        if ns.Debug then ns.Debug("  -> HIDDEN (mate)") end
        return
    end
    DrawHeld(hit, hit.record, "mate")
end

-- Whether a solo hit or heal of `amount` may draw the question mark: while the area is clear, or on Forever when the
-- amount is secret and the area is not crowded. Forever's amounts are all secret (Bone-Apetit's capture, 2026-11-05: 70
-- of 70), so every read is "short", no read decides the area, and with Blizzard's numbers off your hits showed nothing.
local function MayQuestion(amount)
    return Teacher.AreaClear() or ns.IsForever and issecretvalue(amount) and Teacher.NotCrowded()
end

-- A solo hit on a mob fighting you that nothing named: the teacher learns from it (Teacher.Unknown), and it draws the
-- question mark while MayQuestion holds and the school is one a clear read saw. `cast` is Casts.SoleCast at the hit.
-- `sole` (Locked.Observe from Wound, or Locked.TicklessCast via DrawTickless) is the one spell that fits the hit: it
-- draws that spell's icon instead, under the debug `route` ("locked" by default; DrawTickless passes "tickless",
-- TowHold.Decide "tow"). `entry`: the hit's frame entry, when the caller kept it (TowHold.Decide): `now` is then its
-- stamp and Drawn tags `entry` itself.
local function Question(plate, school, amount, flagText, now, cast, candidates, sole, route, entry)
    Teacher.Unknown(plate, school, amount, now, cast, flagText, candidates)
    if not MayQuestion(amount) then
        if ns.Debug then ns.Debug("  -> %s", HiddenRoute()) end
        return
    end
    -- no clear read ever saw this school: a stranger's (shamanally2: an ally's physical hits on a resto shaman)
    if not Teacher.OwnSchool(school) then
        if ns.Debug then ns.Debug("  -> HIDDEN (school)") end
        return
    end
    if sole then
        if ns.Debug then ns.Debug("  -> %s %s", route or "locked", ShowValue(sole)) end
        Drawn(sole, amount, entry and now, entry)
        ns.Locked.Drew(sole)
        Ledger.Add("damage", sole, amount)

        return DrawPlate(plate, SpellTexture(sole), HitText(flagText, amount), flagText, school)
    end
    if ns.Debug then ns.Debug("  -> unknown-solo") end
    Ledger.Add("damage", UnknownKey(school), amount)
    DrawPlate(plate, UnknownTexture(), HitText(flagText, amount), flagText, school)
end

-- Question for a held hit (Hold*): its fields are the route's, `sole` and `route` as Question's. With no `sole`, the
-- hit's own `sole` (the lock's answer TowHold.Hold kept) is the answer.
local function QuestionHeld(hit, sole, route)
    return Question(hit.plate, hit.school, hit.amount, hit.flagText, hit.at, hit.cast, hit.candidates, sole or hit.sole,
        route, hit.entry)
end

-- A held share (HoldShare) at its frame's end: drawn as its proc when a later share in its frame drew it (that one
-- had this one for its twin, Procs.Name), else the question mark route it was held from (Question).
local function DrawShare(hit)
    if not DrawnInFrame(hit.share, hit.at) then return QuestionHeld(hit) end
    if ns.Debug then ns.Debug("  -> share %s", ShowValue(hit.share)) end
    Drawn(hit.share, hit.amount, hit.at)
    Ledger.Add("damage", hit.share, hit.amount)
    DrawPlate(hit.plate, SpellTexture(hit.share), HitText(hit.flagText, hit.amount), hit.flagText, hit.school)
end

-- A hit held on a Mind Blast or Smite's cast stamp (HoldTickless) at its frame's end: that spell's own when it is the
-- only hit of its school on its plate in the frame (frameHits counts hits the tracker named too), else the question mark
-- route it was held from (Question), since a second hit there may be a DoT's tick.
local function DrawTickless(hit)
    local hits, frameList = 0, frameHits.at == hit.at and frameHits.list or {}
    for _, entry in ipairs(frameList) do
        if Plain(entry.school) and entry.school == hit.school and entry.plate == hit.plate then hits = hits + 1 end
    end
    if hits ~= 1 then return QuestionHeld(hit) end

    return QuestionHeld(hit, hit.tickless, "tickless")
end


-- A held crit that may start a ground cast's first tick (HoldGround) at its frame's end: drawn as that cast when its
-- frame is the first tick (Casts.GroundStarts, `plates` the plates its frame's held crits of that record hit), else
-- the question mark route it was held from (Question).
local function DrawGround(hit, plates)
    if not Casts.GroundStarts(hit.ground, hit.at, plates) then return QuestionHeld(hit) end
    DrawHeld(hit, hit.ground, "ground")
end

-- A held hit that may be a cast's even splash (HoldSpread) at its frame's end: drawn as that cast when its frame's
-- held hits of the record are its splash (Casts.Spreads, `spreads[record]` = their sizes on each plate and count),
-- else the question mark route it was held from (Question).
local function DrawSpread(hit, spreads)
    local group = spreads[hit.spread]
    if group.splash == nil then
        group.splash = Casts.Spreads(hit.spread, hit.school, hit.at, group.sizes, group.count)
    end
    if not group.splash then return QuestionHeld(hit) end
    DrawHeld(hit, hit.spread, "spread")
    Teacher.Spread(hit.plate, hit.school, hit.amount, hit.at, hit.flagText, hit.spread.base)
end

-- A held hit that may be a chain's hop logged ahead of its own first hit (HoldHop) at its frame's end: drawn as the
-- chain when its frame held the record's own first hit and the plate is its hop's (Casts.HopsAhead), else the question
-- mark route it was held from (Question).
local function DrawHop(hit, plates)
    if not Casts.HopsAhead(hit.hop, hit.plate, hit.at, plates) then return QuestionHeld(hit) end
    DrawHeld(hit, hit.hop, "hop")
end

-- A ground cast's hit held to its frame's end (HoldTick): drawn as the cast when its frame is a tick (`ticked`), else
-- the frame was none (Casts.Overrun) and the hit is the question mark solo, hidden in a group.
local function DrawTick(hit, ticked)
    if ticked[hit.tick.base] then return DrawHeld(hit, hit.tick, "cast", true) end
    if hit.solo then return QuestionHeld(hit) end
    if ns.Debug then ns.Debug("  -> HIDDEN") end
end

-- The ground bases whose held hits (HoldTick) of the frame at `at` draw as their tick, as a set: those whose frame is
-- one (Casts.Overrun); the records of the others step back (Casts.Unstep).
local function Ticks(hits, at)
    local counts = {} -- counts[base][plate] = the base's held hits on the plate
    for _, hit in ipairs(hits) do
        local base = hit.tick and hit.tick.base
        if base then
            counts[base] = counts[base] or {}
            counts[base][hit.plate] = (counts[base][hit.plate] or 0) + 1
        end
    end
    local ticked = {}
    for base, plates in pairs(counts) do
        if Casts.Overrun(base, at, plates) then
            if ns.Debug then ns.Debug("  .. no tick %s", ShowValue(base)) end
            Casts.Unstep(base, at)
        else
            ticked[base] = true
        end
    end

    return ticked
end

-- Ends the held hits' frame once `now` is past its stamp, or with nil (the fight ended; the replays end each frame
-- with it too): each is a mate or a stranger's (DrawMate), a split proc's share (DrawShare), a crit that may start
-- a ground cast's first tick (DrawGround), a cast's splash (DrawSpread), a chain's hop logged ahead of its own first
-- hit (DrawHop, `plates[record]` the plates its frame's held hops of that record hit), a hit on a Mind Blast or Smite's
-- cast stamp (DrawTickless), or a ground cast's hit (DrawTick).
function HitRoute.FlushMates(now)
    local hits = held.hits
    if #hits == 0 or (now and now <= held.at) then return end
    local own = ownFrame.at == held.at and ownFrame.schools or {}
    local ticked = Ticks(hits, held.at)
    held = { hits = {} }
    local plates, seen = {}, {} -- plates[record] = plates its held crits or hops hit; seen[record][plate] = true
    local spreads = {}          -- spreads[record] = { sizes = { [plate] = normal-scale size }, count } (HoldSpread)
    for _, hit in ipairs(hits) do
        local record = hit.ground or hit.hop
        if record then
            seen[record] = seen[record] or {}
            if not seen[record][hit.plate] then
                seen[record][hit.plate], plates[record] = true, (plates[record] or 0) + 1
            end
        end
        if hit.spread then
            local group = spreads[hit.spread] or { sizes = {}, count = 0 }
            group.sizes[hit.plate], group.count = Streams.NormalAmount(hit.amount, hit.flagText), group.count + 1
            spreads[hit.spread] = group
        end
    end
    for _, hit in ipairs(hits) do
        if hit.share then
            DrawShare(hit)
        elseif hit.tickless then
            DrawTickless(hit)
        elseif hit.spread then
            DrawSpread(hit, spreads)
        elseif hit.ground then
            DrawGround(hit, plates[hit.ground])
        elseif hit.hop then
            DrawHop(hit, plates[hit.hop])
        elseif hit.tick then
            DrawTick(hit, ticked)
        else
            DrawMate(hit, own[hit.school] == true, ticked)
        end
    end
end

-- Holds a hit on a creature with no threat list that does not fight you until its frame ends (held). `stream`: the
-- stream that took it (Streams.Feed), if any.
local function Hold(plate, flagText, amount, school, now, kind, record, stream)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        kind = kind, record = record, stream = stream }
    if ns.Debug then ns.Debug("  .. held") end
    QueueFlush()
end

-- Holds a solo '?' hit that a learned proc's twin split band holds (Procs.Name) until its frame ends: a split hit's
-- first share has no twin yet, its later shares in the frame do (run paladin2 F6: 1276284's 3894 on 3 plates, the
-- first of each frame left '?'). DrawShare decides.
local function HoldShare(plate, school, amount, flagText, now, procID, cast, candidates)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        share = procID, cast = cast, candidates = candidates }
    if ns.Debug then ns.Debug("  .. share") end
    QueueFlush()
end

-- Holds a solo secret hit that is the school of the Mind Blast or Smite `spellID` (Locked.TicklessCast) cast on this
-- stamp and aimed at its plate until its frame ends: the frame shows whether it is the only hit of that school there.
-- DrawTickless decides.
local function HoldTickless(plate, school, amount, flagText, now, spellID, cast, candidates)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        tickless = spellID, cast = cast, candidates = candidates }
    if ns.Debug then ns.Debug("  .. tickless") end
    QueueFlush()
end

-- Holds a solo '?' crit that may start the first tick of the ground cast `record` (Casts.GroundFirst) until its frame
-- ends: a normal later in the frame, or crits on enough plates, prove the tick. DrawGround decides.
local function HoldGround(plate, school, amount, flagText, now, record, cast, candidates)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        ground = record, cast = cast, candidates = candidates }
    if ns.Debug then ns.Debug("  .. ground") end
    QueueFlush()
end

-- Holds a solo '?' hit that may be the learned cast `record`'s even splash (Casts.SpreadFirst) until its frame ends:
-- the frame's other held hits of the record tell a splash on the plates around from a stray hit. DrawSpread decides.
local function HoldSpread(plate, school, amount, flagText, now, record, cast, candidates)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        spread = record, cast = cast, candidates = candidates }
    if ns.Debug then ns.Debug("  .. spread") end
    QueueFlush()
end

-- Holds a solo '?' hit that may be the learned chain `record`'s hop logged ahead of its own first hit (Casts.HopFirst)
-- until its frame ends: the frame shows whether the chain's own hit came. DrawHop decides.
local function HoldHop(plate, school, amount, flagText, now, record, cast, candidates)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        hop = record, cast = cast, candidates = candidates }
    if ns.Debug then ns.Debug("  .. hop") end
    QueueFlush()
end

-- Holds a hit a learned ground cast claimed (`record`, which took it: Casts.Accept) until its frame ends: the frame's
-- hits on each plate tell a tick from another spell's burst on its lattice (Casts.Overrun). DrawTick decides. `solo`,
-- `cast`, `candidates`: the question mark route's, should the frame be no tick.
local function HoldTick(plate, school, amount, flagText, now, record, solo, cast, candidates)
    HitRoute.FlushMates(now)
    if held.at ~= now then held = { at = now, hits = {} } end
    held.hits[#held.hits + 1] = { plate = plate, school = school, amount = amount, flagText = flagText, at = now,
        tick = record, solo = solo, cast = cast, candidates = candidates }
    if ns.Debug then ns.Debug("  .. held") end
    QueueFlush()
end

-- The hit route: the tracker names DoT and channel ticks and a learned cast fingerprint
-- names a direct hit (Casts.Claim); both draw at once, in a group too, except a learned ground cast's hit, which
-- draws at its frame's end once the frame shows a tick (HoldTick). Two learned DoTs that
-- both fit draw the question mark at once. Whatever nothing names is fed to the streams; solo
-- on a mob fighting you a hit no proc names may tick a learned stack spell's series (Casts.StackTick)
-- and draw it, else it also goes to the teacher, and draws the question mark only while the
-- area is clear (Teacher.AreaClear); else it stays hidden (route "meter off" or "crowded"). In a group
-- such a hit on a mob fighting you may still tick a stack series; in a crowded fight no hit does. While the
-- area is not crowded (Teacher.NotCrowded) a learned proc that fits the hit (Procs.Name) draws its icon instead of
-- the question mark; so does a learned rhythm proc that fits the stream the hit extends or births
-- (Procs.NameStream), or that a recent cast of its row and the hit's size name before the stream is born
-- (Procs.NameCast), ranked below the Tracker and Casts; last, below the stack series, one whose tick a period
-- before the hit is still loose on the plate (Procs.NamePair) or whose steady fall the plate's loose ticks keep
-- (Procs.NameFall), then one whose onset link's cast leads the hit
-- (Procs.NameOnset: a burst's first tick). A learned swing on your target (SwingWound) ranks just below the size procs,
-- above the rhythm ones. Solo, a hit on a creature with no threat list that does
-- not fight you, which the tracker does not name, waits for its frame's end instead of hiding (Hold, Core.FlushMates),
-- and so does a solo '?' hit a learned proc's twin split band holds (HoldShare), or a solo '?' crit that may start a
-- learned ground cast's first tick (HoldGround), or a solo '?' hit that may be a learned cast's even splash on the
-- plates around (HoldSpread), or a solo '?' hit that may be a learned chain's hop logged ahead of its own first hit in
-- its frame (HoldHop), or a solo secret hit of the school of the Mind Blast or Smite cast on its stamp and aimed at its
-- plate that no lock fits (HoldTickless: it draws that spell when it is its school's only hit on the plate in the
-- frame, else '?'). The crowd check sees every wound that may be yours: one the tracker names, or one on a mob fighting
-- you, drawn or not. Strangers' wounds on other mobs never reach the teacher, so they count for nothing
-- (run 153349Z: strangers on 8 nearby dummies made both reads crowded). Frame mates reach the area pass only
-- (Teacher.Mate), never the crowd check.
-- `owned`: the hit Owner released as yours (grouped Forever, HitRoute.Route). It is solo whatever the group and the
-- threat list say, but the fight stays marked grouped (Teacher.Grouped), so its read never learns. Owner logged its
-- HIT line at arrival.
local function Wound(plate, unit, flagText, amount, school, now, owned)
    FrameHit(amount, school, now, flagText, plate)
    local fightsYou = owned ~= nil or FightsYou(unit, now)
    local grouped = InGroup()
    if grouped then Teacher.Grouped() end
    local solo = (fightsYou and not grouped) or owned ~= nil
    -- a dummy's hit no one fights waits for its frame's end (held), plain school and amount only (its mate check)
    local holds = not fightsYou and not grouped and type(school) == "number" and type(amount) == "number"
        and Plain(school) and Plain(amount) and NoThreatList(unit)
    if solo and Plain(school) then OwnHit(school, now) end
    local sole, fits = nil, 0
    local asksLocked = ns.IsForever and solo and Plain(school) and not Plain(amount)
    if asksLocked then
        sole, fits = ns.Locked.Observe(plate, school, now)
    end
    local text = HitText(flagText, amount)
    if ns.Debug then
        if not owned then HitRoute.LogHit(unit, school, amount, flagText) end
        if not Plain(amount) then ns.Debug("PROBE amount=%s meter=%s", ShowRaw(amount), Teacher.ProbeMeter()) end
    end
    -- A crowded fight draws only like-sized ticks (Tracker.Identify) and CrowdFits casts (Casts.Claim).
    local crowded = Teacher.fight and Teacher.fight.crowded
    local spellID = Tracker.Identify(plate, school, amount, flagText, now, crowded)
    local named = spellID and spellID ~= Tracker.UNKNOWN
    if fightsYou or named then
        Teacher.Seen(amount, now, school, plate, OnTarget(unit, owned))
    end
    -- A learned proc (exact meter sums) outranks a learned DoT's answer (votes) or an ambiguous one.
    local voted = spellID == Tracker.UNKNOWN or (spellID and Learn.Get(spellID))
    if voted and solo and ProcWound(plate, school, amount, flagText, now) then return end
    local kind, record, late, claimed
    crowded = Teacher.fight and Teacher.fight.crowded -- Teacher.Seen may have turned it crowded
    if named and Learn.Get(spellID) then
        -- A learned DoT's answer is votes; a learned cast fingerprint that fits the hit in its window is exact
        -- (Lightning Bolt hits drawn as a mislearned Lava Burst DoT): the cast wins. The one Claim serves both.
        kind, record, late = Casts.Claim(plate, school, now, Streams.NormalAmount(amount, flagText), crowded,
            flagText)
        claimed = true
        if kind == "learned" and not late and fightsYou and record.spellID ~= spellID then named = false end
    end
    -- A tick that a lock gives to another spell, or that several spells fit, is no sure DoT tick (Locked.Observe): it
    -- runs the later routes, and when none of them names it, Question draws the question mark or keeps it hidden (a
    -- crowded area, a school no clear read saw). The one other spell that fits (`lockSole`) is Question's answer once the
    -- holds pass: run 5 (2026-11-13) drew a Shoot 0.16 s after its cast as Devouring Plague's tick due 0.27 s later.
    local lockSole = named and fits == 1 and sole ~= spellID and sole or nil
    local doubted = fits >= 2 or (fits == 1 and sole ~= spellID)
    if named and doubted then named, sole = false, nil end
    if named then
        if ns.Debug then ns.Debug("  -> tracker %s", ShowValue(spellID)) end
        if sole == spellID then ns.Locked.Drew(spellID) end
        Drawn(spellID, amount)
        if Learn.Get(spellID) then Teacher.Ticked(school, amount, flagText, spellID, now, plate) end
        Ledger.Add("damage", spellID, amount)
        return DrawPlate(plate, SpellTexture(spellID), text, flagText, school)
    end
    if not claimed then
        kind, record = Casts.Claim(plate, school, now, Streams.NormalAmount(amount, flagText), crowded,
            flagText)
    end
    if kind == "learned" and fightsYou and Casts.IsGround(record) then
        Casts.Accept(record, plate, now, Streams.NormalAmount(amount, flagText))
        local cast = solo and Casts.SoleCast(plate, now, school)
        return HoldTick(plate, school, amount, flagText, now, record, solo, cast,
            solo and Casts.Candidates(plate, now, school))
    end
    if kind == "learned" and fightsYou then
        if ns.Debug then ns.Debug("  -> cast %s", ShowValue(record.spellID)) end
        if Casts.Accept(record, plate, now, Streams.NormalAmount(amount, flagText)) and solo then
            Teacher.Own(record.base, record.spellID, plate, school, amount, now, flagText)
        end
        Tracker.OnDirectHit(plate, record.spellID, now) -- a learned DoT of the cast may tick from this hit on
        Streams.Landed(plate, record.spellID, now) -- and an unlearned one's ticks name the cast from it (Owners)
        Drawn(record.base, amount) -- an override is tallied under the base spell's meter row
        Ledger.Add("damage", record.base, amount)
        return DrawPlate(plate, SpellTexture(record.spellID), text, flagText, school)
    end
    -- An UNKNOWN answer is not fed: the tracker already holds the candidates. The teacher
    -- learns from it only solo.
    if spellID == Tracker.UNKNOWN then
        if holds then return Hold(plate, flagText, amount, school, now, kind, record) end
        if not fightsYou then
            if ns.Debug then ns.Debug("  -> HIDDEN") end
            return
        end
        if ns.Debug then ns.Debug("  -> tracker unknown") end
        if not InGroup() then
            Teacher.Unknown(plate, school, amount, now, Casts.SoleCast(plate, now, school), flagText,
                Casts.Candidates(plate, now, school))
        end
        Ledger.Add("damage", UnknownKey(school), amount)
        return DrawPlate(plate, UnknownTexture(), text, flagText, school)
    end
    -- A hit a learned proc names is no DoT tick: fed to the streams, its rhythm gave its votes to a cast
    -- in the proc's frame (Surging Totem's ~12K hits learned Lava Burst as a DoT, run 20261025T182530Z).
    local stream, loose
    if not Procs.Name(school, amount, flagText, FrameTwin(plate, school, amount, flagText, now)) then
        stream, loose = Streams.Feed(plate, school, amount, flagText, now, solo)
        -- A learned DoT spread to a plate it was never cast on takes the stream there (Tracker.AdoptSpread).
        if stream and solo and not crowded then Tracker.AdoptSpread(plate, stream, now) end
    end
    local candidates
    if solo then
        if ProcWound(plate, school, amount, flagText, now) then return end
        candidates = Casts.Candidates(plate, now, school) -- one list for all: drawing changes no cast log
        -- a learned swing's hit, in its tight band and rhythm on your target (Procs.NameSwing), before a rhythm proc's
        -- padded band takes it
        if SwingWound(plate, unit, school, amount, flagText, candidates, now, owned) then return end
        if RhythmWound(plate, stream, school, amount, flagText, candidates, now) then return end
    end
    -- A learned stack spell's tick (Casts.StackTick) takes a hit nothing named on a mob fighting you, after the
    -- streams saw it and, solo, the procs had it: lock2 fight 4, Agony 980's ticks agree with Unstable Affliction's
    -- one stack and draw as a rhythm proc. In a group it is the only route left (lock3 fight 4: 420524 of the row). Not
    -- in a crowded fight: strangers' hits on the plate pass for steps (lock3 fight 3).
    local stack = fightsYou and not crowded
        and Casts.StackTick(plate, school, now, Streams.NormalAmount(amount, flagText), flagText)
    if stack then
        if ns.Debug then ns.Debug("  -> stack %s", ShowValue(stack.spellID)) end
        -- a loose tick the stack drew: a stream born of three such is the stack's, and no rhythm names it (Streams.Feed)
        if loose then loose.stackID = stack.base end
        Drawn(stack.base, amount)
        Ledger.Add("damage", stack.base, amount)
        return DrawPlate(plate, SpellTexture(stack.spellID), text, flagText, school)
    end
    -- A loose tick pairs with the one a learned rhythm period before it only after the stack spells had it: lock3
    -- F2, Unstable Affliction's 7821 (2 stacks x 3258 x 1.2) at 199540.864 sits in Darkglare's band.
    if solo and PairWound(plate, stream, school, amount, flagText, candidates, now) then return end
    -- A burst's first tick, which no tick a period before pairs, is named by the cast that leads it (onset link).
    if solo and OnsetWound(plate, stream, school, amount, flagText, now) then return end
    -- A bolt of a learned volley (Volley.Name): a hit its cast's window holds whose size a bolt just before repeats.
    local volleyID = solo and Teacher.NotCrowded() and ns.Volley.Name(school, amount, flagText, now)
    if volleyID then
        if ns.Debug then ns.Debug("  -> volley %s", ShowValue(volleyID)) end
        Drawn(volleyID, amount)
        Ledger.Add("damage", volleyID, amount)
        return DrawPlate(plate, SpellTexture(volleyID), text, flagText, school)
    end
    -- A learned link's hit (Link.Name): a cast's like-sized hit on the plates around its target, filed under another row.
    local linkID = solo and Teacher.NotCrowded() and ns.Link.Name(plate, school, amount, flagText, now)
    if linkID then
        if ns.Debug then ns.Debug("  -> link %s", ShowValue(linkID)) end
        ns.Volley.Spent(amount, flagText, now)
        Drawn(linkID, amount)
        Ledger.Add("damage", linkID, amount)
        return DrawPlate(plate, SpellTexture(linkID), text, flagText, school)
    end
    -- A learned DoT's twin (Tracker.Twin), then a cast's echo, are the last solo routes before the question mark: the
    -- meter taught their shares.
    local twinID = solo and Tracker.Twin(plate, school, amount, flagText, now)
    if twinID then
        if ns.Debug then ns.Debug("  -> twin %s", ShowValue(twinID)) end
        ns.Volley.Spent(amount, flagText, now)
        Drawn(twinID, amount)
        Ledger.Add("damage", twinID, amount)
        return DrawPlate(plate, SpellTexture(twinID), text, flagText, school)
    end
    -- A learned cast's echo (Casts.Echo): a hit on its plate soon after its own hit, at its learned share of that hit.
    local echo = solo and Teacher.NotCrowded()
        and Casts.Echo(plate, school, now, Streams.NormalAmount(amount, flagText))
    if echo then
        if ns.Debug then ns.Debug("  -> echo %s", ShowValue(echo.spellID)) end
        ns.Volley.Spent(amount, flagText, now)
        Drawn(echo.base, amount)
        Ledger.Add("damage", echo.base, amount)
        return DrawPlate(plate, SpellTexture(echo.spellID), text, flagText, school)
    end
    if solo then
        local cast = Casts.SoleCast(plate, now, school)
        -- a split proc's first share in its frame waits for a twin (HoldShare)
        local share = Teacher.NotCrowded() and not Procs.Name(school, amount, flagText, false)
            and Procs.Name(school, amount, flagText, true)
        if share then return HoldShare(plate, school, amount, flagText, now, share, cast, candidates) end
        -- a crit no claim named that may start a ground cast's first tick waits for its frame (HoldGround)
        local ground = kind == nil and Casts.GroundFirst(plate, school, now, Streams.NormalAmount(amount, flagText),
            flagText)
        if ground then return HoldGround(plate, school, amount, flagText, now, ground, cast, candidates) end
        -- a hit no claim named that may be a learned cast's even splash on the plates around waits for its frame
        -- (HoldSpread)
        local spread = kind == nil and Teacher.NotCrowded()
            and Casts.SpreadFirst(plate, school, now, Streams.NormalAmount(amount, flagText))
        if spread then return HoldSpread(plate, school, amount, flagText, now, spread, cast, candidates) end
        -- a hit no claim named that may be a learned chain's hop logged ahead of its own first hit waits for its
        -- frame (HoldHop)
        local hop = kind == nil and Teacher.NotCrowded()
            and Casts.HopFirst(plate, school, now, Streams.NormalAmount(amount, flagText))
        if hop then return HoldHop(plate, school, amount, flagText, now, hop, cast, candidates) end

        -- a lone secret hit of a Mind Blast or Smite's school on its cast stamp is that spell's (HoldTickless)
        local lockedAsk = asksLocked and sole == nil
        local tickless = lockedAsk and ns.Locked.TicklessCast(plate, school, now)
        if tickless then return HoldTickless(plate, school, amount, flagText, now, tickless, cast, candidates) end

        -- a lone secret shadow hit while Touch of Weakness is armed may be its proc, unless a heal on you comes with it;
        -- with one proc row saved it may be the drain's, which that row's heal names (TowHold.Hold)
        local held = lockedAsk and ns.TowHold.Hold(plate, school, amount, flagText, now, cast, candidates,
            frameHits.list[#frameHits.list], lockSole)
        if held then return end

        return Question(plate, school, amount, flagText, now, cast, candidates, sole or lockSole)
    end
    if holds then return Hold(plate, flagText, amount, school, now, kind, record, stream) end
    if ns.Debug then ns.Debug("  -> HIDDEN") end
end

-- Misses carry no amount and no source: shown only solo, while the area is clear, on the target, for a recent harmful
-- cast. Another player's dodge or parry on your target looks the same as yours, so with strangers around it would draw
-- your last cast's icon with "Miss" (in-game report 2026-10-29: learned spells showed "Miss" often near others).
local function Miss(plate, unit, event, now)
    if InGroup() or not Teacher.AreaClear() or not IsTarget(unit) then return end
    local castID = Tracker.TakeMissCast(now)
    if castID then
        DrawPlate(plate, SpellTexture(castID), _G[event] or event)
    end
end

-- Friendly and personal plates report hits too; only enemies get popups.
local function CanAttack(unit)
    local ok, canAttack = pcall(UnitCanAttack, "player", unit)
    return ok and Plain(canAttack) and canAttack == true
end

local function EnemyHit(unit, event, flagText, amount, school, now)
    if not CanAttack(unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit, false)
    if not Plain(plate) or plate:IsForbidden() then return end
    if event == "WOUND" and ns.Owner.Active() then
        ns.Owner.Hit(plate, unit, flagText, amount, school, now)
    elseif event == "WOUND" then
        Wound(plate, unit, flagText, amount, school, now)
    elseif MISSES[event] then
        Tracker.OnMiss(plate, now)
        Miss(plate, unit, event, now)
    end
end

-- A hit Owner released as yours (Owner.Flush): `hit` is its arrival snapshot, routed as a solo hit at its own stamp.
function HitRoute.Route(hit)
    Wound(hit.plate, hit.unit, hit.flagText, hit.amount, hit.school, hit.now, hit)
end

-- A removed plate forgets the hits yours drew on it (Core.NAME_PLATE_UNIT_REMOVED).
function HitRoute.PlateGone(plate)
    mine[plate] = nil
end

-- The hits on enemy plates in the frame of stamp `at` (frameHits), or an empty list when another frame's are kept.
function HitRoute.FrameHits(at)
    return frameHits.at == at and frameHits.list or {}
end

-- Whether a solo hit of yours on a mob fighting you landed in the frame of stamp `at` (ownFrame).
function HitRoute.OwnFrameAt(at)
    return ownFrame.at == at
end

-- Whether hits wait for their frame's end (held; PlayerHits.QueueFlush queues another flush while they do).
function HitRoute.Holding()
    return #held.hits > 0
end

HitRoute.EnemyHit = EnemyHit
HitRoute.InGroup = InGroup
HitRoute.PlainGUID = PlainGUID
HitRoute.HitText = HitText
HitRoute.SpellTexture = SpellTexture
HitRoute.UnknownKey = UnknownKey
HitRoute.UnknownTexture = UnknownTexture
HitRoute.HiddenRoute = HiddenRoute
HitRoute.MayQuestion = MayQuestion
HitRoute.QuestionHeld = QuestionHeld
