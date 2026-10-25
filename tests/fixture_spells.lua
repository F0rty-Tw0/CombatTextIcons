-- Test-only spell table: the Warlock and Hunter rows the addon shipped in
-- Spells.lua until 2026-10-24, kept to drive the Tracker's table modes in the
-- unit checks. The shipped ns.Spells is empty; T.Boot(setup, true) (or T.BootSpells) loads this
-- table into ns.Spells before Learn.lua reads it, and the replays use it only to
-- know which recorded casts were channels. Never loaded by the addon.
-- Keyed by the cast spell ID that UNIT_SPELLCAST_SUCCEEDED / _CHANNEL_START report.
-- From the researched table (SimC midnight branch, WoW 12.1.5.70448); spells
-- without a cast of their own, pet-cast spells and direct-only spells are left out.
--   icon     spell ID of the ticks (used for the icon)
--   school   school mask of the ticks
--   period   base seconds between ticks; hasted = shortened by spell haste
--   duration base seconds the effect lasts
--   mode     target | spread | area | channel
--   spreads  (spread) what the spread applies, per school; period defaults to 2 s hasted
--   heals    (channel) each tick also heals the caster in the same frame

return {
    -- Warlock
    -- Corruption: SimC warlock.txt; sc_warlock_actions.cpp (corruption_t), confirmed
    [172] = { icon = 146739, school = 32, period = 2, hasted = true, duration = 14, mode = "target" },
    -- Immolate: SimC warlock.txt; sc_warlock_init.cpp (immolate_old 348, immolate_dot 157736), confirmed
    [348] = { icon = 157736, school = 4, period = 3, hasted = true, duration = 18, mode = "target" },
    -- Agony: SimC warlock.txt; sc_warlock_actions.cpp (agony_t), confirmed
    [980] = { icon = 980, school = 32, period = 2, hasted = true, duration = 18, mode = "target" },
    -- Rain of Fire: SimC warlock.txt; sc_warlock_actions.cpp (rain_of_fire_t, ground_aoe pulse_time * spell_haste), confirmed
    [5740] = { icon = 42223, school = 4, period = 1, hasted = true, duration = 8, mode = "area" },
    -- Seed of Corruption: SimC warlock.txt; sc_warlock_actions.cpp (seed_of_corruption_t / seed_of_corruption_aoe_t), confirmed
    [27243] = { icon = 27285, school = 32, period = 12, hasted = false, duration = 12, mode = "spread", spreads = { { school = 36, icon = 445474 }, { school = 32, icon = 146739 } } },
    -- Haunt: SimC warlock.txt; sc_warlock.cpp (debuffs.haunt tick callback); sc_warlock_actions.cpp (shadow_of_nathreza_dmg_t), confirmed
    [48181] = { icon = 1262710, school = 32, period = 1, hasted = false, duration = 18, mode = "target" },
    -- Cataclysm: SimC warlock.txt; sc_warlock_actions.cpp (cataclysm_t), confirmed
    [152108] = { icon = 157736, school = 4, period = 3, hasted = true, duration = 18, mode = "spread", spreads = { { school = 4, icon = 157736, period = 3, hasted = true }, { school = 36, icon = 445474 } } },
    -- Channel Demonfire: SimC warlock.txt; sc_warlock_actions.cpp (channel_demonfire_t), confirmed
    [196447] = { icon = 196448, school = 4, period = 0.2, hasted = true, duration = 3, mode = "channel" },
    -- Drain Soul: SimC warlock.txt; sc_warlock_init.cpp, confirmed
    [198590] = { icon = 198590, school = 32, period = 1, hasted = true, duration = 5, mode = "channel" },
    -- Drain Life: SimC warlock.txt; sc_warlock_actions.cpp (drain_life_t), confirmed
    [234153] = { icon = 234153, school = 32, period = 1, hasted = true, duration = 5, mode = "channel", heals = true },
    -- Wither: SimC warlock.txt; sc_warlock_init.cpp (hero.wither_direct = 445468, hero.wither_dot = 445474); sc_warlock_actions.cpp (wither_t), confirmed
    [445468] = { icon = 445474, school = 36, period = 2, hasted = true, duration = 18, mode = "target" },
    -- Rain of Fire (on target): SimC warlock.txt; sc_warlock_init.cpp, confirmed
    [1214467] = { icon = 42223, school = 4, period = 1, hasted = true, duration = 8, mode = "area" },
    -- Dark Harvest: SimC warlock.txt; sc_warlock_actions.cpp (dark_harvest_t), confirmed
    [1257052] = { icon = 1257065, school = 36, period = 1, hasted = true, duration = 3, mode = "channel", heals = true },
    -- Unstable Affliction: SimC warlock.txt; sc_warlock_init.cpp (talents.unstable_affliction = 1259790), confirmed
    [1259790] = { icon = 1259790, school = 32, period = 2, hasted = true, duration = 8, mode = "target" },
    -- Malefic Grasp: SimC warlock.txt; sc_warlock_actions.cpp (malefic_grasp_t), confirmed
    [1261153] = { icon = 1261153, school = 32, period = 1, hasted = true, duration = 4, mode = "channel" },

    -- Hunter
    -- Explosive Shot: SimC hunter.txt; sc_hunter.cpp (explosive_shot_base_t), confirmed
    [212431] = { icon = 212431, school = 4, period = 1, hasted = false, duration = 3, mode = "target" },
    -- Barbed Shot: SimC hunter.txt; sc_hunter.cpp (barbed_shot_base_t), confirmed
    [217200] = { icon = 217200, school = 1, period = 2, hasted = false, duration = 12, mode = "target" },
    -- Rapid Fire: SimC hunter.txt; sc_hunter.cpp (rapid_fire_t, talents.rapid_fire_tick = 257045), confirmed
    [257044] = { icon = 257045, school = 1, period = 0.333, hasted = true, duration = 2, mode = "channel" },
    -- Wildfire Bomb: SimC hunter.txt; sc_hunter.cpp (wildfire_bomb_base_t::bomb_damage_t), confirmed
    [259495] = { icon = 269747, school = 4, period = 1, hasted = false, duration = 6, mode = "spread", spreads = { { school = 4, icon = 269747, period = 1, hasted = false }, { school = 1, icon = 1253171, period = 1, hasted = false } } },
    -- Volley: SimC hunter.txt; sc_hunter.cpp (volley_t), confirmed
    [260243] = { icon = 260247, school = 1, period = 0.5, hasted = false, duration = 6, mode = "area" },
    -- Black Arrow: SimC hunter.txt; sc_hunter.cpp (black_arrow_base_t), confirmed
    [466930] = { icon = 468572, school = 32, period = 1, hasted = false, duration = 8, mode = "target" },
    -- Boomstick: SimC hunter.txt; sc_hunter.cpp (boomstick_t), confirmed
    [1261193] = { icon = 1261215, school = 1, period = 1, hasted = true, duration = 3, mode = "channel" },
}
