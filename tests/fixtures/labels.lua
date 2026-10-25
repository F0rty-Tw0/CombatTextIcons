-- Ground truth for the probe fixtures (solo Warlock, Affliction Hellcaller, on dummies).
--
-- A plate hit whose own meter read held an entry is labelled "meter" by the
-- harness before anything here applies. Every other WOUND on a nameplate gets
--   lines[lineNumber]                       (per-line override), else
--   keys["phase plate school"]              ("pet", a tick spell ID, or "hidden").
-- A hit with no label is an error in this file (the harness stops).
--
-- Line numbers are 1-based lines of the .log file (= CTIProbeDB.seq index).
-- Phases are counted by MARK lines (the first MARK starts phase 1).
--
-- haste: from the median interval of unread Agony/Wither ticks on one plate
-- (gaps 0.9-2.0 s), haste = (2 / median - 1) * 100. Recompute with
-- `lua tests/run.lua --haste` after changing labels.
--
-- castPlates: the target plate of every player cast. Taken from where that
-- cast's own ticks or hits land. run.lua Criterion 8 fails on a player cast of a
-- spell outside Spells.lua (shipped empty: every spell) that has no castPlate:
-- the learner's cast log needs it.
-- variants: alternative cast plates where the plate is unknown; the
-- fixture is replayed once per variant and every run must pass.
--
-- Shaman entries (from /cti debug SavedVariables logs, no .log probe) carry
--   log        the .sv.lua file; lines are indices into CombatTextIconsDB.debugLog (= file line - 11)
--   haste      0: the logs do not record UnitSpellHaste and every check is haste-invariant
--   targets    { { from = t, plate = "nameplateN" }, ... }: the plate the player targets from time t
--   schools    label by school for hits with no READ hit and no lines[] override
--   lines      per-index override; "excluded" = unscored (v2b's bug, listed)
-- A label "a|b" counts either icon (or "?") as correct. Shaman replays score into their own report.
--
-- direct (v2b-1 criterion 12, meter-blanked replay): direct.lines[debugLogIndex] =
--   a spell ID   the hit is a direct hit of that cast spell (the cast ID: Shoot 5019, never the meter row 75)
--   "excluded"   a rule-assigned hit hand review removed (the reason is a comment on the line); unscored
--   absent       the rule assigned nothing (two or more casts in the window, no cast, a tracker cast); unscored
-- Built by the spec 9 rule from the log alone: hits whose route is not "-> tracker"; rule A = exactly one CAST
-- in [t - 1.5, t], not a tracker spell, cast plate == hit plate; rule B = a chain hop (previous labeled hit of
-- that cast, same school, new plate, <= 0.15 s, < 5 hits). Denominators (labeled, excluded):
--   priest-direct 15 (0), priest-wand 14 (1), priest-retest 3 (0), shaman-cl-clean 33 (0), shaman-cl-instants 12 (4)
-- The three priest entries carry no schools / lines (never scored by Score); their targets hold one entry per
-- CAST (from = the cast's time, plate = the plate of that cast's own hit; for a tracker cast with no hit of its
-- own, the first hit or tick that follows before the next cast), so TargetAt(t) is the plate of the latest cast.

local AGONY, UA, WITHER, DRAIN_LIFE, SHADOW_BOLT = 980, 1259790, 445474, 234153, 686
local SHAMAN_SCHOOLS = { [8] = 188443, [12] = "188389|470411" } -- Chain Lightning; Flame Shock or its twin
local CL, SMITE, MIND_BLAST, SHOOT = 188443, 591, 8092, 5019 -- cast spell IDs of the direct labels

return {
    v4 = {
        haste = 37.9,
        castPlates = {
            [43] = "nameplate1",    -- Agony (phase 2)
            [185] = "nameplate9",   -- Seed of Corruption (phase 4): target not logged; its explosion hits 7, 9 and 10 in one
                                    -- frame; the next cast's plate (Haunt, line 295). Every output line is the same with 7 or 10.
            [295] = "nameplate9",   -- Haunt: its direct hit lands on nameplate9 (line 296)
            [503] = "nameplate9",   -- Agony; Shared Agony copies it to nameplate10 (no cast there)
            [704] = "nameplate9",   -- Haunt
            [1027] = "nameplate9",  -- Agony refresh; Shared Agony starts a new ramp on nameplate2
            [1350] = "nameplate1",  -- Drain Life
            [1424] = "nameplate1",  -- Drain Life
            -- unknown casts: the cast log records them; plates from each cast's own hit
            [71] = "nameplate1",    -- Shadow Bolt; hit line 72
            [108] = "nameplate1",   -- Shadow Bolt; hit line 111
            [131] = "nameplate1",   -- Shadow Bolt; hit line 137
            [298] = "nameplate9",   -- Malevolence (442726); burst target
            [327] = "nameplate9",   -- Summon Darkglare (205180); burst target
            [472] = "nameplate9",   -- Summon Felhunter (691); burst target
            [865] = "nameplate9",   -- Shadow Bolt; hit line 883
            [1023] = "nameplate9",  -- Shadow Bolt; hit line 1030
            [1096] = "nameplate9",  -- Shadow Bolt; hit line 1100
            [1333] = "nameplate1",  -- 416250 (phase 6); Drain Life follows on nameplate1
        },
        -- Unstable Affliction casts: the probe did not log their target.
        variants = {
            { name = "UA on nameplate9", castPlates = { [546] = "nameplate9", [622] = "nameplate9", [666] = "nameplate9",
                [754] = "nameplate9", [803] = "nameplate9", [862] = "nameplate9", [959] = "nameplate9" } },
            { name = "UA on nameplate10", castPlates = { [546] = "nameplate10", [622] = "nameplate10", [666] = "nameplate10",
                [754] = "nameplate10", [803] = "nameplate10", [862] = "nameplate10", [959] = "nameplate10" } },
        },
        keys = {
            -- 1: Felhunter on one dummy
            ["1 nameplate1 1"] = "pet",
            -- 2: Agony
            ["2 nameplate1 32"] = AGONY,
            -- 3: Shadow Bolt; school 106 = item proc (Rune of Lingering), never the tracker's
            ["3 nameplate1 106"] = "hidden",
            -- 4: Seed of Corruption on a pack: explosion (meter) applies Wither on 7, 9, 10;
            --    the fire ticks on 3-8 come from no cast of the player's
            ["4 nameplate1 106"] = "hidden",
            ["4 nameplate3 4"] = "hidden",
            ["4 nameplate4 4"] = "hidden",
            ["4 nameplate5 4"] = "hidden",
            ["4 nameplate6 4"] = "hidden",
            ["4 nameplate8 4"] = "hidden",
            ["4 nameplate7 36"] = WITHER,
            ["4 nameplate9 36"] = WITHER,
            ["4 nameplate10 36"] = WITHER,
            -- 5: burst on nameplate9 (Haunt, Malevolence, Darkglare, Agony, UA x7, Shadow Bolt).
            --    Agony ramps +541 per tick on 9 (Haunt +20 %) and +451 on Shared-Agony 10;
            --    UA is a separate series on 9 (3910, 7820, 11731, 15642, ... crit x2.15),
            --    split out per line below.
            ["5 nameplate9 32"] = AGONY,
            ["5 nameplate10 32"] = AGONY,
            ["5 nameplate2 32"] = AGONY,
            ["5 nameplate9 1"] = "pet",
            ["5 nameplate5 36"] = WITHER,
            ["5 nameplate7 36"] = WITHER,
            ["5 nameplate9 36"] = WITHER,
            ["5 nameplate10 36"] = WITHER,
            -- 6: 416250 then Drain Life x2 on nameplate1; leftovers of phase 5 on 9 and 8
            ["6 nameplate1 1"] = "pet",
            ["6 nameplate1 32"] = DRAIN_LIFE,
            ["6 nameplate8 36"] = WITHER,
            ["6 nameplate9 1"] = "pet",
            ["6 nameplate9 32"] = AGONY,
            ["6 nameplate9 36"] = WITHER,
            -- 7: Felhunter re-summoned; Wither still on 8
            ["7 nameplate1 1"] = "pet",
            ["7 nameplate8 36"] = WITHER,
        },
        lines = {
            [137] = SHADOW_BOLT, -- a Shadow Bolt hit the meter read missed (cast at line 131)
            -- phase 5, nameplate9: Unstable Affliction ticks (amount series, ~1.45 s cadence)
            [589] = UA, [623] = UA, [657] = UA, [702] = UA, [740] = UA, [768] = UA, [815] = UA,
            [863] = UA, [915] = UA, [957] = UA, [1004] = UA, [1054] = UA, [1100] = UA, [1139] = UA,
            [1170] = UA,
            -- 27486 at 101.888: off both series' cadence and amount (likely a Wrath of
            -- Nathreza proc); no cast of the player's explains it
            [735] = "hidden",
            -- 306 at 112.012: Agony's partial last tick on nameplate10 (18.0 s after line 503)
            [1037] = AGONY,
        },
    },
    v5 = {
        haste = 35.4,
        excludePhases = { [1] = true }, -- aborted attempt; its Agony was cast before logging
        castPlates = {
            [216] = "nameplate1",  -- Agony
            [435] = "nameplate1",  -- Agony
            [703] = "nameplate3",  -- Drain Life (ticks on nameplate3)
            [782] = "nameplate1",  -- Drain Life (ticks on nameplate1)
            [1128] = "nameplate1", -- Agony
            [152] = "nameplate1",  -- Seed of Corruption (phase 2): its explosion hits nameplate1 only
            [608] = "nameplate3",  -- Seed of Corruption (phase 5): target not logged; its explosion hits 2, 3 and 5 in one
                                   -- frame; the next cast's plate (Drain Life, line 703). Every output line is the same with 2 or 5.
            -- unknown casts: the cast log records them
            [114] = "nameplate1",  -- Shadow Bolt (phase 1, not scored); hit line 121
            [398] = "nameplate1",  -- Shadow Bolt; hit line 408
            [967] = "nameplate1",  -- Summon Felhunter (691)
        },
        keys = {
            -- 2: Seed of Corruption on one dummy: explosion (meter) applies Wither
            ["2 nameplate1 106"] = "hidden",
            ["2 nameplate1 36"] = WITHER,
            -- 3: Agony
            ["3 nameplate1 106"] = "hidden",
            ["3 nameplate1 32"] = AGONY,
            ["3 nameplate1 36"] = WITHER,
            -- 4: Shadow Bolt (meter) + Agony
            ["4 nameplate1 106"] = "hidden",
            ["4 nameplate1 32"] = AGONY,
            ["4 nameplate1 36"] = WITHER,
            -- 5: Seed of Corruption on three dummies
            ["5 nameplate2 36"] = WITHER,
            ["5 nameplate3 36"] = WITHER,
            ["5 nameplate5 36"] = WITHER,
            -- 6: Drain Life on nameplate3, then on nameplate1
            ["6 nameplate1 106"] = "hidden",
            ["6 nameplate1 32"] = DRAIN_LIFE,
            ["6 nameplate1 36"] = WITHER,
            ["6 nameplate2 36"] = WITHER,
            ["6 nameplate3 32"] = DRAIN_LIFE,
            ["6 nameplate3 36"] = WITHER,
            ["6 nameplate5 36"] = WITHER,
            -- 7: Felhunter + Agony
            ["7 nameplate1 1"] = "pet",
            ["7 nameplate1 106"] = "hidden",
            ["7 nameplate1 32"] = AGONY,
            ["7 nameplate1 36"] = WITHER,
            ["7 nameplate2 36"] = WITHER,
            ["7 nameplate3 36"] = WITHER,
        },
        lines = {},
    },

    ["shaman-fs-forget"] = {
        log = "shaman-fs-forget-2026-10-22.sv.lua",
        haste = 0,
        targets = { { from = 0, plate = "nameplate10" }, { from = 23318.0, plate = "nameplate5" } },
        schools = SHAMAN_SCHOOLS,
        -- debugLog indices (file line - 11): 348 = 23317.173 (event entry taken as fresh); 211/213/215 = the CL bounces v2b owns
        lines = { [348] = "meter", [211] = "excluded", [213] = "excluded", [215] = "excluded" },
        keys = {}, castPlates = {},
    },
    ["shaman-cl-instants"] = {
        log = "shaman-cl-instants-2026-10-22.sv.lua",
        haste = 0,
        targets = { { from = 0, plate = "nameplate8" } },
        schools = SHAMAN_SCHOOLS,
        lines = {},
        keys = {}, castPlates = {},
        direct = { lines = { -- Chain Lightning, 12 labeled + 4 excluded; every other hit has two or more casts in its window
            [3] = CL, [5] = CL, [7] = CL,           -- cast 22575.696 (chain: nameplate8, 2, 5)
            [40] = CL, [42] = CL, [44] = CL,        -- cast 22582.221 (chain)
            [46] = "excluded",                      -- Flame Shock tick (school 12) in the CL frame; the cast's school is 8
            [73] = "excluded",                      -- Flame Shock tick (school 12) in the CL frame
            [75] = CL, [77] = CL, [79] = CL,        -- cast 22587.691 (chain)
            [110] = CL, [112] = CL, [114] = CL,     -- cast 22591.489 (chain)
            [120] = "excluded",                     -- Elemental Overload copy on nameplate8, which this cast already hit (110)
            [125] = "excluded",                     -- Flame Shock tick (school 12) in the CL frame
            -- 117 and 123 get no entry: rule B refuses plates the cast already hit (112, 114)
        } },
    },
    ["shaman-cl-clean"] = {
        log = "shaman-cl-clean-2026-10-22.sv.lua",
        haste = 0,
        targets = { { from = 0, plate = "nameplate2" } },
        schools = SHAMAN_SCHOOLS,
        lines = {},
        keys = {}, castPlates = {},
        direct = { lines = { -- Chain Lightning: 11 casts x 3 hops (nameplate2, 3, 4), all 33 hits labeled
            [3] = CL, [5] = CL, [7] = CL,
            [11] = CL, [13] = CL, [15] = CL,
            [19] = CL, [21] = CL, [23] = CL,
            [27] = CL, [29] = CL, [31] = CL,
            [35] = CL, [37] = CL, [39] = CL,
            [43] = CL, [45] = CL, [47] = CL,
            [51] = CL, [53] = CL, [55] = CL,
            [59] = CL, [61] = CL, [63] = CL,
            [67] = CL, [69] = CL, [71] = CL,
            [75] = CL, [77] = CL, [79] = CL,
            [83] = CL, [85] = CL, [87] = CL,
        } },
    },

    -- Priest (Forever client, /cti debug logs). Targets: one entry per CAST player line, see the header.
    ["priest-direct"] = {
        log = "priest-direct-2026-10-23.sv.lua",
        haste = 0,
        targets = {
            { from = 94644.227, plate = "nameplate1" }, { from = 94646.488, plate = "nameplate1" },
            { from = 94652.094, plate = "nameplate1" }, { from = 94658.300, plate = "nameplate1" },
            { from = 94659.546, plate = "nameplate1" }, { from = 94666.736, plate = "nameplate2" },
            { from = 94668.447, plate = "nameplate2" }, { from = 94670.316, plate = "nameplate2" },
            { from = 94692.520, plate = "nameplate1" }, { from = 94694.189, plate = "nameplate1" },
            { from = 94699.952, plate = "nameplate1" }, { from = 94701.570, plate = "nameplate1" },
            { from = 94703.307, plate = "nameplate1" }, { from = 94706.624, plate = "nameplate3" },
            { from = 94709.519, plate = "nameplate3" }, { from = 94712.714, plate = "nameplate3" },
        },
        keys = {}, castPlates = {},
        direct = { lines = { -- 15 labeled; index 21 (Mind Blast 1.2 s after a Smite: two casts in its window) has no entry
            [3] = SMITE, [17] = SMITE, [25] = SMITE, [30] = SMITE, [43] = SMITE,
            [47] = SMITE, [51] = SMITE, [55] = SMITE, [63] = SMITE, [69] = SMITE,
            [7] = MIND_BLAST, [39] = MIND_BLAST, [59] = MIND_BLAST,
            [13] = SHOOT, [35] = SHOOT,
        } },
    },
    ["priest-wand"] = {
        log = "priest-wand-2026-10-23.sv.lua",
        haste = 0,
        targets = {
            { from = 98946.227, plate = "nameplate7" }, { from = 98948.257, plate = "nameplate7" },
            { from = 98952.240, plate = "nameplate3" }, { from = 98954.255, plate = "nameplate3" },
            { from = 98958.266, plate = "nameplate7" }, { from = 98961.004, plate = "nameplate3" },
            { from = 98963.010, plate = "nameplate3" }, { from = 98968.219, plate = "nameplate1" },
            { from = 98970.241, plate = "nameplate1" }, { from = 98972.843, plate = "nameplate1" },
            { from = 98975.982, plate = "nameplate2" }, { from = 98977.988, plate = "nameplate2" },
            { from = 98980.007, plate = "nameplate2" }, { from = 98982.008, plate = "nameplate2" },
        },
        keys = {}, castPlates = {},
        direct = { lines = { -- 14 wand hits, 0.6-1.4 s after each cast
            [3] = "excluded", -- Touch of the Grave (school 32) in the first wand frame: castless proc, HEAL 56 mirrors its amount; the wand's school is 4
            [7] = SHOOT, [11] = SHOOT, [15] = SHOOT, [19] = SHOOT, [25] = SHOOT, [29] = SHOOT, [33] = SHOOT,
            [37] = SHOOT, [41] = SHOOT, [46] = SHOOT, [50] = SHOOT, [54] = SHOOT, [58] = SHOOT, [62] = SHOOT,
        } },
    },
    ["priest-retest"] = {
        log = "priest-retest-2026-10-23.sv.lua",
        haste = 0,
        targets = { -- the nine 594 casts (tracker) take the plate of the first hit that follows; the three Shoot casts their own hit's
            { from = 98189.667, plate = "nameplate1" }, { from = 98209.690, plate = "nameplate1" },
            { from = 98214.504, plate = "nameplate1" }, { from = 98218.778, plate = "nameplate2" },
            { from = 98225.445, plate = "nameplate2" }, { from = 98226.967, plate = "nameplate1" },
            { from = 98228.954, plate = "nameplate2" }, { from = 98230.452, plate = "nameplate2" },
            { from = 98246.405, plate = "nameplate1" }, { from = 98248.809, plate = "nameplate4" },
            { from = 98250.811, plate = "nameplate4" }, { from = 98252.830, plate = "nameplate4" },
        },
        keys = {}, castPlates = {},
        direct = { lines = { -- only the three Shoot hits: every other hit sits in a tracker (594) window or has no cast
            [103] = SHOOT, [110] = SHOOT, [118] = SHOOT,
        } },
    },
}
