-- Learn: the per-spec store of tick rhythms the addon learned itself.
--
-- A DoT, channel or HoT that Spells.lua does not know (it ships empty: every spell) is learned from Streams:
-- each stream birth (a ground patch's wide one aside) gives every spell cast just before it a vote (`votes`),
-- plus an expected count of the votes luck alone would give it. A spell is
-- learned when its votes beat that luck (PoissonTail); a physical one also over all its physical births
-- (`physical`, see OnBirth). Sig and learned periods
-- are haste-free bases. Learned spells are served to the Tracker like table
-- rows. Two consecutive casts without a tick drop a spell again, as do the
-- teacher's meter reads (two unpaired reads in a row, or at once when over). Saved data is
-- checked on load and never trusted.

local _, ns = ...

local Learn = {}
ns.Learn = Learn

-- Forever reuses retail spell IDs for vanilla spells (172 Corruption, 980 Curse
-- of Agony) whose ticks differ from retail's, so any Spells.lua rows are dropped
-- there (the shipped table is empty everywhere). This runs before the icon index
-- below; files loading after this one see ns.IsForever.
local interface = select(4, GetBuildInfo())
ns.IsForever = type(interface) == "number" and interface >= 16000 and interface <= 19999
if ns.IsForever then ns.Spells = {} end

local PERIOD_MIN, PERIOD_MAX = 0.5, 10 -- seconds; anything outside is not a tick rhythm
local MAX_MISSES = 2                   -- consecutive tickless casts that drop a learned spell
local UNPAIRED_MAX = 2                  -- consecutive meter reads without the spell's ticks that drop it
local MODES = { dot = "target", channel = "channel", hot = "hot" } -- kind -> Tracker mode
local SIG_AGREE = 0.25                 -- a vote sig and a new base period may differ by this share
local RATE_WINDOW = 12                 -- seconds of cast log counted towards luck
local ALPHA = 0.01                     -- learned when luck alone gives these votes less often than this
local VOTES_MIN, VOTES_MIN_PHYSICAL = 2, 3 -- votes needed; school 1 (physical) needs more
local SIGS_MAX = 4                     -- rhythms kept per spell
local VOTE_SPELLS = 128                -- spells kept in the vote store
local BASE_EMA = 0.1                   -- weight of one tick sample in a learned base period
local CHANCE_RATE = 0.7                -- chance one cast in the rate window matches a stream: 0.7 P / RATE_WINDOW

local issecretvalue = issecretvalue or function() return false end
local function Plain(value) return not issecretvalue(value) and value ~= nil end

Learn.PERIOD_MIN, Learn.PERIOD_MAX = PERIOD_MIN, PERIOD_MAX -- Streams pairs hits only inside these
Learn.VOTES_MIN, Learn.VOTES_MIN_PHYSICAL = VOTES_MIN, VOTES_MIN_PHYSICAL -- the panel and Progress show "n of need"

-- Whether two base periods agree: they differ by at most SIG_AGREE of the larger.
function Learn.PeriodsAgree(a, b) return math.abs(a - b) <= SIG_AGREE * math.max(a, b) end

-- The in-memory tables are the saved ones once Init ran.
local learned, votes = {}, {}
local castAt = {} -- [learned spell id] = its last cast (Learn.OnCast), for RowsRead; this session's clock, never saved
local icons = {} -- [spell id or icon] = true, every id the Spells.lua table knows

for spellID, row in pairs(ns.Spells) do
    icons[spellID] = true
    if row.icon then icons[row.icon] = true end
    for _, spread in ipairs(row.spreads or {}) do
        if spread.icon then icons[spread.icon] = true end
    end
end

local function IsId(value) return Plain(value) and type(value) == "number" end

local function ValidEntry(entry)
    if type(entry) ~= "table" then return false end
    local school, period = entry.school, entry.period
    if type(school) ~= "number" or school <= 0 or school % 1 ~= 0 then return false end
    if type(period) ~= "number" or period < PERIOD_MIN or period > PERIOD_MAX then return false end

    return MODES[entry.kind] ~= nil
end

local function ValidSig(sig)
    if not ValidEntry(sig) then return false end

    return type(sig.votes) == "number" and sig.votes >= 0 and type(sig.expected) == "number" and sig.expected >= 0
end

local function ValidTally(tally)
    if type(tally) ~= "table" then return false end

    return type(tally.votes) == "number" and tally.votes >= 0 and type(tally.expected) == "number"
        and tally.expected >= 0
end

-- Rebuilds `entry.sigs` from its valid sigs, the SIGS_MAX with the most votes. An invalid or missing `physical`
-- tally (a save from before it) starts from the kept physical sigs. False when the entry is invalid.
local function PruneVoteEntry(entry)
    if type(entry) ~= "table" or type(entry.sigs) ~= "table" then return false end
    if type(entry.casts) ~= "number" or not (entry.casts >= 0) then return false end
    entry.lastCast = nil -- a cast time is this session's clock; it is not kept across a load
    local kept = {}
    for _, sig in ipairs(entry.sigs) do
        if ValidSig(sig) then kept[#kept + 1] = sig end
    end
    table.sort(kept, function(a, b) return a.votes > b.votes end)
    while #kept > SIGS_MAX do kept[#kept] = nil end
    entry.sigs = kept
    if ValidTally(entry.physical) then
        entry.physical = { votes = entry.physical.votes, expected = entry.physical.expected }
    else
        entry.physical = { votes = 0, expected = 0 }
        for _, sig in ipairs(kept) do
            if sig.school == 1 then
                entry.physical.votes = entry.physical.votes + sig.votes
                entry.physical.expected = entry.physical.expected + sig.expected
            end
        end
    end

    return true
end

-- Drops every invalid vote entry of `tbl` in place, then the spells with the fewest casts beyond VOTE_SPELLS.
local function PruneVotes(tbl)
    local ids = {}
    for key, entry in pairs(tbl) do
        if type(key) == "number" and PruneVoteEntry(entry) then ids[#ids + 1] = key else tbl[key] = nil end
    end
    if #ids <= VOTE_SPELLS then return end
    table.sort(ids, function(a, b) return tbl[a].casts > tbl[b].casts or tbl[a].casts == tbl[b].casts and a < b end)
    for position = VOTE_SPELLS + 1, #ids do tbl[ids[position]] = nil end
end

-- Drops every invalid key and entry of `tbl` in place.
local function Prune(tbl)
    for key, entry in pairs(tbl) do
        if type(key) ~= "number" or not ValidEntry(entry) then tbl[key] = nil end
    end
end

-- Learn.Init(db): adopts a spec's store (Core's UseSpec) and forgets the casts seen under the spec before.
function Learn.Init(db)
    if type(db.learned) ~= "table" then db.learned = {} end
    if type(db.votes) ~= "table" then db.votes = {} end
    learned, votes, castAt = db.learned, db.votes, {}
    Prune(learned)
    PruneVotes(votes)
    for _, entry in pairs(learned) do
        entry.misses = 0
        local unpaired = entry.unpaired
        if type(unpaired) ~= "number" or unpaired < 0 or unpaired % 1 ~= 0 then entry.unpaired = 0 end
    end
end

function Learn.Get(spellID)
    if not IsId(spellID) then return nil end
    local entry = learned[spellID]
    if not entry then return nil end

    return { icon = spellID, school = entry.school, period = entry.period, hasted = true, mode = MODES[entry.kind] }
end

function Learn.Missed(spellID)
    if not IsId(spellID) then return end
    local entry = learned[spellID]
    if not entry then return end
    entry.misses = entry.misses + 1
    if entry.misses >= MAX_MISSES then Learn.Drop(spellID) end
end

function Learn.Hit(spellID)
    if not IsId(spellID) then return end
    local entry = learned[spellID]
    if entry then entry.misses = 0 end
end

-- Forgets a learned spell and its votes at once.
function Learn.Drop(spellID)
    if not IsId(spellID) then return end
    learned[spellID] = nil
    votes[spellID] = nil
end

-- A meter read found no ticks for the spell's trigger: the second strike in a row drops it.
function Learn.Unpaired(spellID)
    if not IsId(spellID) then return end
    local entry = learned[spellID]
    if not entry then return end
    entry.unpaired = (entry.unpaired or 0) + 1
    if entry.unpaired >= UNPAIRED_MAX then Learn.Drop(spellID) end
end

-- A meter read matched the spell's ticks: the strikes start over.
function Learn.Paired(spellID)
    if not IsId(spellID) then return end
    local entry = learned[spellID]
    if entry then entry.unpaired = 0 end
end

-- The teacher's DoT pass (Teacher.lua) learned `spellID` from its meter row: a DoT of `school` at base period `base`.
-- Its votes give way. False when an argument is not a plain number or the period is no tick rhythm.
function Learn.Teach(spellID, school, base)
    if not (IsId(spellID) and IsId(school) and IsId(base)) then return false end
    if base < PERIOD_MIN or base > PERIOD_MAX then return false end
    learned[spellID] = { school = school, period = base, kind = "dot", misses = 0, unpaired = 0 }
    votes[spellID] = nil

    return true
end

function Learn.Forget()
    for spellID in pairs(learned) do learned[spellID] = nil end
    for spellID in pairs(votes) do votes[spellID] = nil end
end

-- Learned spells, sorted by spell id.
function Learn.List()
    local list = {}
    for spellID, entry in pairs(learned) do
        list[#list + 1] = { spellID = spellID, school = entry.school, period = entry.period, kind = entry.kind }
    end
    table.sort(list, function(a, b) return a.spellID < b.spellID end)

    return list
end

-- Whether `spellID` is a spell or tick icon the addon already serves.
function Learn.IsKnownIcon(spellID)
    if not IsId(spellID) then return false end

    return icons[spellID] == true or learned[spellID] ~= nil
end

-- Haste -----------------------------------------------------------------------------------

-- The player's spell haste in percent; nil when the API errors or answers a secret value (not the same as 0).
function Learn.Haste()
    local ok, haste = pcall(UnitSpellHaste, "player")
    if ok and IsId(haste) then return haste end

    return nil
end

-- Luck test -------------------------------------------------------------------------------

-- P(Poisson(lambda) >= count): how often luck alone gives that many votes.
function Learn.PoissonTail(lambda, count)
    local term, below = math.exp(-lambda), 0
    for k = 0, count - 1 do
        below = below + term
        term = term * lambda / (k + 1)
    end

    return math.max(0, 1 - below)
end

-- Vote store ------------------------------------------------------------------------------

function Learn.Votes(spellID)
    if not IsId(spellID) then return nil end

    return votes[spellID]
end

-- The vote store as a list sorted by spell id: each spell's best sig (most votes, then lowest expected, then
-- lowest period) with its luck p. Read-only copies; a spell with no sig is left out.
function Learn.VoteList()
    local list = {}
    for spellID, entry in pairs(votes) do
        local best
        for _, sig in ipairs(entry.sigs) do
            local ahead = not best or sig.votes > best.votes
                or sig.votes == best.votes and (sig.expected < best.expected
                or sig.expected == best.expected and sig.period < best.period)
            if ahead then best = sig end
        end
        if best then
            list[#list + 1] = { spellID = spellID, kind = best.kind, school = best.school, period = best.period,
                votes = best.votes, expected = best.expected, p = Learn.PoissonTail(best.expected, best.votes) }
        end
    end
    table.sort(list, function(a, b) return a.spellID < b.spellID end)

    return list
end

-- A cast some meter row aliases to never votes: a DoT learned under it is judged against that row, so it can only score over.
local function CanVote(spellID)
    return IsId(spellID) and not Learn.IsKnownIcon(spellID) and not ns.Fingerprints.IsAliasTarget(spellID)
end

-- Drops the spell with the fewest casts (lowest id on ties) that is not in `keep`.
local function EvictVoteSpell(keep)
    local worst
    for spellID, entry in pairs(votes) do
        local fewer = worst and (entry.casts < votes[worst].casts or entry.casts == votes[worst].casts and spellID < worst)
        if not keep[spellID] and (not worst or fewer) then worst = spellID end
    end
    if worst then votes[worst] = nil end
end

-- The spell's entry, created on demand; a full store first drops a spell outside `keep`.
local function VoteEntry(spellID, keep)
    local entry = votes[spellID]
    if entry then return entry end
    local count = 0
    for _ in pairs(votes) do count = count + 1 end
    if count >= VOTE_SPELLS then EvictVoteSpell(keep) end
    entry = { casts = 0, sigs = {}, physical = { votes = 0, expected = 0 } }
    votes[spellID] = entry

    return entry
end

function Learn.OnCast(castID, now)
    if IsId(castID) and learned[castID] then castAt[castID] = now end
    if not CanVote(castID) then return end
    local entry = VoteEntry(castID, { [castID] = true })
    entry.casts = entry.casts + 1
    entry.lastCast = now
end

-- A DoT learned under a cast with no meter row of its own is always struck by the net later, so a read drops the non-hot
-- sigs of every spell cast since `since` that the meter has no row for (heals have no damage row, so hot sigs stay) and
-- stops its dot and channel votes, in this fight too, until a read lists its row.
-- A learned dot or channel cast since `since` that drew nothing (`tally`, the fight's drawn totals) and has no row is
-- struck as unpaired too: the net only judges drawn spells, and twins cast in one frame tie on every tick, so neither
-- draws (Flame Shock 188389 and its rowless twin 470411 kept Flame Shock '?' for all 4 fights of run shaman4).
function Learn.RowsRead(rows, since, tally)
    if type(since) ~= "number" then return end
    local listed = {}
    for _, row in ipairs(rows) do
        listed[row.spellID] = true
        if votes[row.spellID] then votes[row.spellID].rowless = nil end
    end
    for spellID, entry in pairs(learned) do
        local cast, drawn = castAt[spellID], tally and tally[spellID]
        if entry.kind ~= "hot" and type(cast) == "number" and cast >= since and not listed[spellID] and not drawn then
            Learn.Unpaired(spellID)
        end
    end
    for spellID, entry in pairs(votes) do
        local cast = entry.lastCast
        if type(cast) == "number" and cast >= since and not listed[spellID] and not learned[spellID] then
            local kept = {}
            for _, sig in ipairs(entry.sigs) do
                if sig.kind == "hot" then kept[#kept + 1] = sig end
            end
            entry.sigs = kept
            entry.rowless = true
        end
    end
end

-- Whether a read found `spellID` cast with no meter row of its own (RowsRead) and no read has listed it since.
function Learn.Rowless(spellID)
    local entry = IsId(spellID) and votes[spellID]

    return type(entry) == "table" and entry.rowless == true
end

-- The sig of `entry` closest to (kind, school, base) within SIG_AGREE, else a new one
-- (a full entry first drops its fewest-votes sig, lowest expected on ties).
local function FindSig(entry, kind, school, base)
    local best, bestGap
    for _, sig in ipairs(entry.sigs) do
        local gap = math.abs(sig.period - base)
        local agrees = sig.kind == kind and sig.school == school and Learn.PeriodsAgree(sig.period, base)
        if agrees and (not best or gap < bestGap) then best, bestGap = sig, gap end
    end
    if best then return best, true end

    if #entry.sigs >= SIGS_MAX then
        local worst = 1
        for index, sig in ipairs(entry.sigs) do
            local other = entry.sigs[worst]
            if sig.votes < other.votes or sig.votes == other.votes and sig.expected < other.expected then worst = index end
        end
        table.remove(entry.sigs, worst)
    end
    local sig = { kind = kind, school = school, period = base, votes = 0, expected = 0 }
    entry.sigs[#entry.sigs + 1] = sig

    return sig, false
end

-- The votable spells cast in the key's rate window up to the birth: { [id] = { n, kind } }, and their cast order.
local function WindowCasts(key, stream)
    local rows, order = {}, {}
    for _, cast in ipairs(ns.Streams.CastLog(key)) do
        local inside = cast.at >= stream.birth - RATE_WINDOW and cast.at <= stream.birth
        local rowless = cast.kind ~= "hot" and votes[cast.castID] and votes[cast.castID].rowless -- RowsRead
        if inside and not rowless and CanVote(cast.castID) then
            local row = rows[cast.castID]
            if not row then
                row = { n = 0 }
                rows[cast.castID] = row
                order[#order + 1] = cast.castID
            end
            row.n = row.n + 1
            row.kind = stream.ownerKind[cast.castID] or cast.kind
        end
    end

    return rows, order
end

-- A wide stream (Streams.Feed: its frames hit many plates at once) is a ground patch's, never a target DoT's: the
-- Tracker would draw it under the cast, whose row is another ID's, until two unpaired reads drop it (synthetic Blood
-- DK: Death and Decay ticks on all 4 plates each second, learned as a DoT in fight 1). Ground.lua learns those.
-- Melee noise gives physical births all fight long (run druid F6: hits of 4263, 3914, 4292 on the GCD's beat), so a
-- physical cast tries many rhythms and one can win by luck: run druid F11, Ravage 441591 (a direct hit) won a physical
-- 1.30 s sig with 4 votes against 0.82 expected (births of 1.0 to 1.6 s in F6, F7, F9, F11), while its casts owned 9
-- physical births against 8.1 expected over all its sigs. It then drew 16 melee hits (89K) under its icon in F11-F12
-- and its row stayed under the meter, so no read struck it. So a physical sig also needs the cast's physical tally
-- (all its physical births, kept across sigs) to beat luck.
function Learn.OnBirth(key, stream, now)
    if stream.wide then return end
    if ns.Tracker.ExplainsHits(key, stream.school, stream.hits, stream.period) then return end
    local base = stream.period * (1 + (Learn.Haste() or 0) / 100)
    if base < PERIOD_MIN or base > PERIOD_MAX then return end -- not a tick rhythm; Init would drop the sig

    local physical = stream.school == 1
    local rows, order = WindowCasts(key, stream)
    local sigs, entries, keep = {}, {}, {}
    for _, spellID in ipairs(order) do
        local row = rows[spellID]
        local chance = math.min(1, row.n * CHANCE_RATE * stream.period / RATE_WINDOW)
        keep[spellID] = true
        local entry = VoteEntry(spellID, keep)
        local sig, existed = FindSig(entry, row.kind, stream.school, base)
        if existed then
            local weight = sig.votes + sig.expected
            sig.period = (weight * sig.period + chance * base) / (weight + chance)
        end
        sig.expected = sig.expected + chance
        if physical then entry.physical.expected = entry.physical.expected + chance end
        sigs[spellID], entries[spellID] = sig, entry
    end

    local voted = {}
    for _, spellID in ipairs(stream.owners) do
        local sig = sigs[spellID]
        -- One cast votes once per sig: dense noise puts it in several births' owner windows.
        local castAt = stream.ownerAt and stream.ownerAt[spellID]
        if sig and not voted[spellID] and (castAt == nil or sig.lastCast ~= castAt) then
            sig.votes = sig.votes + 1
            sig.lastCast = castAt
            voted[spellID] = sig
            if physical then entries[spellID].physical.votes = entries[spellID].physical.votes + 1 end
        end
    end

    local need = physical and VOTES_MIN_PHYSICAL or VOTES_MIN
    local won = {}
    for spellID, sig in pairs(voted) do
        local tally = entries[spellID].physical
        local lucky = Learn.PoissonTail(sig.expected, sig.votes) > ALPHA
            or physical and Learn.PoissonTail(tally.expected, tally.votes) > ALPHA
        if sig.votes >= need and not lucky then won[#won + 1] = spellID end
    end
    table.sort(won)
    for _, spellID in ipairs(won) do
        local sig = voted[spellID]
        learned[spellID] = { school = sig.school, period = sig.period, kind = sig.kind, misses = 0 }
        votes[spellID] = nil
    end
    for _, spellID in ipairs(won) do ns.Tracker.OnLearned(spellID, now) end
end

-- One tick's base-period sample moves a learned base; a sample far from the base is ignored.
function Learn.Nudge(spellID, sample)
    if not IsId(spellID) or not IsId(sample) then return end
    local entry = learned[spellID]
    if not entry then return end
    if not Learn.PeriodsAgree(sample, entry.period) then return end
    entry.period = (1 - BASE_EMA) * entry.period + BASE_EMA * sample
end
