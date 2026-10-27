-- Test-only table for the strict score (tests/score_lib.lua): which spells a drawn amount can belong to, by meter row.
-- A hit drawn under row R is an orphan when no cast of R's `casts` happened within R's `life` before the draw (or up
-- to 0.01 s after it, a cast on the same stamp later in the line order). Rows not listed here are never checked.
-- Never loaded by the addon; editing it changes the measure, so it needs its own rebaseline (see the strict-score spec).
--   casts  the row's cast IDs: its base ID plus each override ID a log's `CAST player <id> base=<base>` line shows
--   life   seconds a cast can still produce a draw under the row: channel = duration * 1.5 + 1,
--          DoT = duration * 1.5 + 2, direct = 3 (generous on purpose: a window too wide only loses sensitivity)
-- Keyed by the meter row's spell ID. Source per row: SimC midnight branch (engine/class_modules) and Wowhead, as of 2026-10-27.

return {
    -- Agony: DoT 18 s, life 29. SimC sc_warlock_actions.cpp (agony_t), tests/fixture_spells.lua:23-24 (duration = 18)
    [980] = { casts = { 980 }, life = 29 },
    -- Lava Burst: direct, life 3. SimC sc_shaman.cpp lava_burst_t (spell_power_mod.direct from spell 285452, no dot);
    -- Wowhead 51505: 2 s cast, duration n/a, no periodic effect. The logs' CAST lines read `player 51505 base=73899`:
    -- 73899 is the API base, never cast itself, so it stays out of `casts`
    [51505] = { casts = { 51505 }, life = 3 },
    -- Primal Wrath: direct, life 3 (the Rip it applies is its own row, 1079). SimC sc_druid.cpp primal_wrath_t
    -- (composite_da_multiplier, rip_t from spell 1079 as a secondary action); Wowhead 285381: instant, School Damage (Physical)
    [285381] = { casts = { 285381 }, life = 3 },
    -- Void Torrent: channel 3 s, life 5.5. SimC priest/sc_priest_shadow.cpp void_torrent_t (channeled = true,
    -- dot_duration = data().duration()); Wowhead 263165: channeled, duration 3 s
    [263165] = { casts = { 263165 }, life = 5.5 },

    -- Shadow Bolt: direct, life 3. Wowhead 686: 2 s cast, one School Damage (Shadow) effect, duration n/a
    [686] = { casts = { 686 }, life = 3 },
    -- Haunt: direct hit + 18 s debuff, life 29 (the DoT window covers both). Wowhead 48181: duration 18 s, School Damage (Shadow)
    [48181] = { casts = { 48181 }, life = 29 },
    -- Lightning Bolt: direct, life 3. Wowhead 188196: 2.5 s cast, one Nature damage effect, duration n/a
    [188196] = { casts = { 188196 }, life = 3 },
    -- Flame Shock: DoT 18 s, life 29. Wowhead 188389: duration 18 s, Apply Aura: Periodic Damage every 2 s
    [188389] = { casts = { 188389 }, life = 29 },
    -- Mind Blast: direct, life 3; Void Blast (450983) is its override, from the logs' `CAST player 450983 base=8092`.
    -- Wowhead 8092: 1.5 s cast, School Damage (Shadow), duration n/a
    [8092] = { casts = { 8092, 450983 }, life = 3 },
    -- Mind Flay: channel 4.5 s, life 7.75. tests/fixture_spells.lua:68 (SimC mind_flay_base_t, Wowhead 15407: 4.5 s)
    [15407] = { casts = { 15407 }, life = 7.75 },
}
