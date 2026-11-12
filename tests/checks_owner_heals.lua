-- Unit checks for Owner's heals: the per-stamp queue in PlayerHits and the heals a Combat Log line owns (Phase 3 of the
-- Owner work). Called by tests/checks.lua with the same T table.

return function(T)
    local Check, Secret = T.Check, T.Secret
    local function Load(interface)
        return T.Boot(function(S) S.interface = interface or 16001 CombatTextIconsCharDB = {} end)
    end

    local CHANNEL = 234153
    local function Texture(id) return (C_Spell.GetSpellTexture(id)) end
    local function Has(log, line) for _, text in ipairs(log) do if text == line then return true end end return false end
    -- Forever, grouped by default, ns.Owner faked. opts.active = false: Owner off; opts.group = false: solo.
    local function OwnerRig(opts)
        opts = opts or {}
        local ns = Load()
        local rig = { ns = ns, S = T.State(), draws = {}, claims = {}, log = {}, flushes = {}, channelCalls = {},
            ledger = 0, active = opts.active ~= false, heldFrom = nil, owned = {}, channelAt = nil, waiting = false }
        rig.S.group = opts.group ~= false
        ns.Teacher.area = "clear"
        ns.Display.Plate = function() end
        ns.Display.Player = function(kind, texture) rig.draws[#rig.draws + 1] = { kind = kind, texture = texture } end
        ns.Debug = function(format, ...) rig.log[#rig.log + 1] = string.format(format, ...) end
        ns.Ledger.Add = function() rig.ledger = rig.ledger + 1 end
        ns.Tracker.ChannelHeal = function(now)
            rig.channelCalls[#rig.channelCalls + 1] = now
            return rig.channelAt == now and CHANNEL or nil
        end
        local claim = ns.LockedHeals.Claim
        ns.LockedHeals.Claim = function(casts, heals, at, ownAt, solo)
            rig.claims[#rig.claims + 1] = { at = at, n = #heals, solo = solo }
            return claim(casts, heals, at, ownAt, solo)
        end
        local Owner = ns.Owner
        Owner.IsActive = function() return rig.active end
        Owner.Pending = function(at) return rig.heldFrom ~= nil and rig.heldFrom <= at end -- a hit on a stamp <= at is held
        Owner.HealOwned = function(at, index) return rig.owned[at .. ":" .. index] == true end
        Owner.Flush = function(now, force) rig.flushes[#rig.flushes + 1] = { now = now, force = force } end
        Owner.Waiting = function() return rig.waiting end
        function rig.Heal(at, amount) ns.PlayerHits.Heal("player", "", amount or Secret(9), 1, at) end
        return rig
    end

    local rig = OwnerRig()
    rig.heldFrom = 10 -- stamp 10's hits are held
    rig.Heal(10, Secret(9))
    rig.Heal(10.02, Secret(7)) -- its top FlushHeals(10.02) must not flush stamp 10's heal
    Check("owner heals: a later stamp's heal neither flushes nor relabels the held stamp's heals",
        #rig.claims == 0 and #rig.draws == 0)
    Check("owner heals: HealWaits reads every waiting stamp, not only the newest",
        rig.ns.PlayerHits.HealWaits(10) and rig.ns.PlayerHits.HealWaits(10.02) and not rig.ns.PlayerHits.HealWaits(10.5))
    rig.heldFrom = nil -- the release routed the hits
    rig.ns.PlayerHits.FlushHeals(nil)
    Check("owner heals: once released each stamp claims on its own, oldest first",
        #rig.claims == 2 and rig.claims[1].at == 10 and rig.claims[1].n == 1
        and rig.claims[2].at == 10.02 and rig.claims[2].n == 1)

    rig = OwnerRig()
    rig.Heal(10, Secret(9))
    rig.Heal(10.02, Secret(7))
    rig.heldFrom = 10.02 -- only the newer stamp's hits are held
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: the stop rule flushes the older stamp and keeps the pending one",
        #rig.claims == 1 and rig.claims[1].at == 10 and rig.ns.PlayerHits.HealWaits(10.02)
        and not rig.ns.PlayerHits.HealWaits(10))

    rig = OwnerRig({ active = false })
    rig.Heal(10, Secret(9))
    rig.Heal(10.02, Secret(7)) -- guard: nothing held, so a later stamp's heal still flushes the earlier one at once
    Check("owner heals: guard, nothing held: a heal on a later stamp flushes the earlier stamp as today",
        #rig.claims == 1 and rig.claims[1].at == 10)

    rig = OwnerRig()
    rig.waiting = true
    rig.Heal(10, Secret(9))
    local timers = rig.S.timers
    local queued, run = #timers, timers[#timers].fn
    rig.S.now = 10.04
    run()
    local last = rig.flushes[#rig.flushes]
    Check("owner heals: the queued flush calls Owner.Flush(GetTime()) first and re-queues while Owner waits",
        last and last.now == 10.04 and last.force == nil and #timers == queued + 1 and #rig.claims == 1)

    -- an owned heal on a lone helpful cast: direct fit, icon grouped; unowned: nothing
    rig = OwnerRig()
    rig.owned["10:1"] = true
    rig.Heal(10, Secret(9))
    rig.ns.PlayerHits.NoteHelpful(17, 10)
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: an owned heal on your helpful cast draws its icon grouped, Claim solo",
        #rig.draws == 1 and rig.draws[1].texture == Texture(17) and rig.claims[1].solo == true
        and rig.log[#rig.log] == "  -> heal 17")
    rig = OwnerRig()
    rig.Heal(10, Secret(9))
    rig.ns.PlayerHits.NoteHelpful(17, 10)
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: an unowned heal draws nothing, Claim not solo, route HIDDEN",
        #rig.draws == 0 and rig.claims[1].solo == false and rig.log[#rig.log] == "  -> HIDDEN")

    -- two heals, the second owned: two Claims (owned first), claims map back by index
    rig = OwnerRig()
    rig.owned["10:2"] = true
    rig.Heal(10, Secret(9))
    rig.Heal(10, Secret(8))
    rig.ns.PlayerHits.NoteHelpful(17, 10)
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: owned and unowned heals claim apart; the owned second heal gets the cast's icon",
        #rig.claims == 2 and rig.claims[1].solo == true and rig.claims[1].n == 1
        and rig.claims[2].solo == false and rig.claims[2].n == 1
        and #rig.draws == 1 and rig.draws[1].texture == Texture(17) and Has(rig.log, "  -> HIDDEN")
        and rig.log[#rig.log] == "  -> heal 17")

    -- nothing names an owned heal: '?'; an unowned one draws nothing
    rig = OwnerRig()
    rig.owned["10:2"] = true
    rig.Heal(10, Secret(9))
    rig.Heal(10, Secret(8))
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: an unnamed owned heal draws '?', the unowned one beside it nothing",
        #rig.draws == 1 and rig.draws[1].texture == rig.ns.Meter.UNKNOWN_ICON
        and rig.log[#rig.log] == "  -> unknown-solo")

    -- channel heal: the tick is still held at arrival, so no arrival-time ask; asked at flush
    rig = OwnerRig()
    rig.owned["10:1"] = true
    rig.Heal(10, Secret(5))
    Check("owner heals: with Owner on a heal skips the arrival Tracker.ChannelHeal ask and waits",
        #rig.channelCalls == 0 and #rig.draws == 0)
    rig.channelAt = 10 -- the tick was routed at the release
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: an owned channel heal draws the tick's icon at flush, no Claim, Ledger counts it",
        #rig.draws == 1 and rig.draws[1].texture == Texture(CHANNEL) and #rig.claims == 0
        and rig.ledger == 1 and rig.log[#rig.log] == "  -> channel")
    rig = OwnerRig()
    rig.Heal(10, Secret(5))
    rig.channelAt = 10
    rig.ns.PlayerHits.FlushHeals(11)
    Check("owner heals: an unowned channel heal draws nothing, no Claim, no Ledger entry",
        #rig.draws == 0 and #rig.claims == 0 and rig.ledger == 0)

    -- guard: Owner off, solo: a channel heal draws at arrival as today
    rig = OwnerRig({ active = false, group = false })
    rig.channelAt = 10
    rig.Heal(10, Secret(5))
    Check("owner heals: guard, Owner off: the channel heal draws at arrival", #rig.draws == 1 and #rig.channelCalls == 1)

    -- End to end with the real Owner: the Owner-on twin of checks_forever.lua "drain: grouped -> no plate draw for
    -- the hit". A shadow hit and its heal share stamp 100, two live lines own both, the wand cast forces the release.
    local DRAIN, WAND = 1260198, 5019
    local real = T.Boot(function(S)
        S.interface = 16001
        S.group = true
        S.harmful[2652], S.harmful[19261] = false, false
        CombatTextIconsCharDB = { lockedHealsV = 2, lockedHeals = { [DRAIN] = { strikes = 0 } },
            lockedSchools = { [589] = { school = 32, strays = 0 } } }
    end)
    local State, Core, Owner = T.State(), real.Core, real.Owner
    T.CombatLogLive({ on = true })
    local plateTexture, healDrawn
    real.Teacher.area = "clear"
    real.Display.Plate = function(_, texture) plateTexture = texture end
    real.Display.Player = function(kind) if kind == "heal" then healDrawn = true end end
    real.Debug = function() end
    Check("owner heals: precondition, the real Owner is active in the grouped Forever rig",
        Owner.KeepLinesOn() ~= nil and Owner.Active() == true)
    State.now = 100
    Core.UNIT_COMBAT("nameplate1", "WOUND", "", Secret(31), 32)
    Core.UNIT_COMBAT("player", "HEAL", "", Secret(9), 1)
    Owner.Line(0, 100)
    Owner.Line(0, 100)
    State.now = 100.2
    Core.UNIT_SPELLCAST_SUCCEEDED("player", "c", WAND)
    Check("owner heals: grouped drain with the real Owner draws the claimed row on the plate and the heal",
        plateTexture == Texture(DRAIN) and healDrawn == true)
    T.CombatLogClear()
end
