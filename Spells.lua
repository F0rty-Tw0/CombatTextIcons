-- Periodic, channelled and ground-effect spells the tracker can attribute ticks to,
-- keyed by the cast spell ID that UNIT_SPELLCAST_SUCCEEDED / _CHANNEL_START report.
-- Empty on every client: each character learns its own spells (Learn.lua). The
-- Tracker still serves rows of this shape (icon, school, period, hasted, duration,
-- mode target | spread | area | channel, spreads, heals); tests/fixture_spells.lua
-- holds the former Warlock and Hunter rows for the unit checks.

local ADDON, ns = ...

ns.Spells = {}
