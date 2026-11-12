-- Combat Text Icons: heals and damage taken, drawn over the player. Core.Heal and Core.FlushHeals are these.

local _, ns = ...
local Tracker, Display, Streams, Ledger, Teacher, Heals = ns.Tracker, ns.Display, ns.Streams, ns.Ledger, ns.Teacher,
    ns.Heals
local HitRoute, TowHold = ns.HitRoute, ns.TowHold
local ShowValue = ns.DebugLog.ShowValue
local HitText, SpellTexture, InGroup, MayQuestion = HitRoute.HitText, HitRoute.SpellTexture, HitRoute.InGroup,
    HitRoute.MayQuestion
local HiddenRoute, UnknownKey, UnknownTexture = HitRoute.HiddenRoute, HitRoute.UnknownKey, HitRoute.UnknownTexture

local PlayerHits = {}
ns.PlayerHits = PlayerHits

-- The heals on you waiting for their frame's end and the frame's own helpful casts (FlushHeals, Heal, below).
-- waiting = { at = the frame's stamp, heals = { { flagText, amount, school, size }, ... } }; frameCasts = { at, ids =
-- your helpful casts on that stamp, in cast order, each once (seen) }.
local waiting, frameCasts = { heals = {} }, { ids = {} }

-- Once a heal is learned or one sample from it (Heals.AnyLearned), and on Forever always (LockedHeals.Claim), a heal
-- on you that no channel named waits for the end of its frame (Core.FlushHeals): it lands before its own cast's
-- UNIT_SPELLCAST_SUCCEEDED in that frame
-- (shamanheal: the heal of each of 17 Chain Heal 1064 casts is logged on the cast's stamp, the line before the CAST
-- line), so only then does the frame know its casts; its hits (frameHits, HitRoute.FrameHits) come with them.
local flushQueued = false -- a flush waits on C_Timer.After(0)

-- A named heal on you (a claim or a channel's). On Forever while grouped it draws nothing: Blizzard's heal numbers are
-- back there (BlizzardText.Sync), so a self-heal would show twice, like the plate hits (HitRoute's DrawPlate).
local function DrawHeal(texture, amount, flagText)
    if ns.IsForever and InGroup() then return end
    Display.Player("heal", texture, amount, flagText)
end

-- A heal on you no channel named is drawn: with the icon of the spell that claimed it (on Forever
-- LockedHeals.Claim: a direct, HoT or proc fit; else Heals.Claim: its frame's
-- helpful cast, a learned size or share, or the tick of a running train), else as any unexplained heal on you: the question mark solo while the area is clear, else hidden.
local function DrawOwnHeal(heal, castID)
    local route = "HIDDEN"
    if castID then
        route = "heal " .. castID
        Ledger.Add("heal", castID, heal.amount)
        DrawHeal(SpellTexture(castID), heal.amount, heal.flagText)
    elseif not InGroup() and MayQuestion(heal.amount) then
        route = "unknown-solo"
        Ledger.Add("heal", UnknownKey(heal.school), heal.amount)
        Display.Player("heal", UnknownTexture(), heal.amount, heal.flagText)
    elseif not InGroup() then
        route = HiddenRoute()
    end
    if ns.Debug then ns.Debug("  -> %s", route) end
end

-- The one saved proc row's ID when a claim of the frame's heals names it, else nil (TowHold.Healed).
local function ProcClaim(claims, count)
    local row = ns.LockedHeals.OnlyRow()
    if not row then return end
    for index = 1, count do
        if claims[index] == row then return row end
    end
end

-- Draws the waiting heals once their frame is over: `now` past its stamp, or nil (the fight ended; the replays end
-- each frame with it too). Each waits for at most one frame: an event of a later one flushes them first. On Forever
-- the frame's claims then settle the drain hit TowHold holds for them (TowHold.Healed).
function PlayerHits.FlushHeals(now)
    local heals = waiting.heals
    if #heals == 0 or (now and now <= waiting.at) then return end
    local casts = frameCasts.at == waiting.at and frameCasts.ids or {}
    local hits, at = HitRoute.FrameHits(waiting.at), waiting.at
    waiting = { heals = {} }
    local claims
    if ns.IsForever then
        claims = ns.LockedHeals.Claim(casts, heals, at, HitRoute.OwnFrameAt(at), not InGroup())
        TowHold.Healed(at, ProcClaim(claims, #heals))
    else
        claims = Heals.Claim(casts, heals, hits, at, not InGroup() and Teacher.AreaClear())
    end
    for index, heal in ipairs(heals) do DrawOwnHeal(heal, claims[index]) end
end

-- The game's next frame flushes Owner's held hits, the waiting heals and the held frame mates; a callback still on their
-- own stamp waits again.
local function QueueFlush()
    if flushQueued then return end
    flushQueued = pcall(C_Timer.After, 0, function()
        flushQueued = false
        ns.Owner.Flush(GetTime())
        PlayerHits.FlushHeals(GetTime())
        HitRoute.FlushMates(GetTime())
        if #waiting.heals > 0 or HitRoute.Holding() or ns.Owner.Waiting() then QueueFlush() end
    end)
end

PlayerHits.QueueFlush = QueueFlush

-- Whether a heal on you already waits on the stamp `now` (TowHold.Hold).
function PlayerHits.HealWaits(now)
    return waiting.at == now and #waiting.heals > 0
end

-- Your helpful cast of `spellID` at `now`: the frame's waiting heals may be its (frameCasts, FlushHeals).
function PlayerHits.NoteHelpful(spellID, now)
    if frameCasts.at ~= now then frameCasts = { at = now, ids = {}, seen = {} } end
    if not frameCasts.seen[spellID] then
        frameCasts.seen[spellID] = true
        frameCasts.ids[#frameCasts.ids + 1] = spellID
    end
end

-- A heal on you or a party member. On you: the heal of a channel (Drain Life) whose damage tick landed in this same
-- frame; else once any heal is learned it waits for its frame's casts, hits and running trains, which may name it
-- (waiting). On Forever every heal on you waits, and its frame's casts, your own hit on its stamp and learned HoT
-- ticks may name it (LockedHeals.Claim). A heal on you nothing names draws the question mark when solo and the area
-- is clear. A heal on a party member stays hidden. A HoT's ticks are a learned train's (Heals.lua): the tick
-- tracker's own HoT instances took like-timed heals of any size and outlived the HoT (synthetic: foreign heals and a
-- 720 rune drawn under Renew 139, 4.6 % of the case's heals; the real heal logs: no heal named that way). Heals do not
-- count toward the crowd check (overheal).
function PlayerHits.Heal(unit, flagText, amount, school, now)
    PlayerHits.FlushHeals(now)
    if ns.Debug then
        ns.Debug("HEAL %s school=%s amount=%s flag=%s", unit, ShowValue(school), ShowValue(amount), ShowValue(flagText))
    end
    if unit == "player" then
        TowHold.Release(now)
        Teacher.Healed(amount, flagText, now)
    end
    local spellID = unit == "player" and Tracker.ChannelHeal(now) or nil
    local texture = spellID and SpellTexture(spellID) or nil
    if texture ~= nil then
        Ledger.Add("heal", spellID, amount)
        DrawHeal(texture, amount, flagText)
        if ns.Debug then ns.Debug("  -> channel") end
    elseif unit == "player" then
        local heal = { flagText = flagText, amount = amount, school = school,
            size = Streams.NormalAmount(amount, flagText) }
        local waits = ns.IsForever or Heals.AnyLearned()
        if not waits then return DrawOwnHeal(heal) end
        waiting.at = now
        waiting.heals[#waiting.heals + 1] = heal
        QueueFlush()
    elseif ns.Debug then
        ns.Debug("  -> HIDDEN")
    end
end

-- Damage you take is always shown, as a number: no icon.
function PlayerHits.Taken(flagText, amount)
    Display.Player("taken", nil, HitText(flagText, amount), flagText)
end
