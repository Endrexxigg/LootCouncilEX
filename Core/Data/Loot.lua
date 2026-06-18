-- ── LootCouncil EX — Data/Loot.lua ───────────────────────────────────────────
-- SHIPPED STATIC DATA — phase → raid → boss → {itemIDs}. This is a STUB sample for the Phase-6
-- scaffolding: a couple of raids/bosses with a few REAL TBC itemIDs (so icons/tooltips resolve
-- in testing). The boss→item mapping is illustrative, not yet accurate — populating the real
-- per-phase tables is Phase 7 content work, and rides this same shape unchanged.
--
-- Shape (PROJECT.md §6.6): Loot[phase].raids[raid][boss] = { itemID, ... }. Each raid also
-- carries an `_order` array giving boss kill order (Lua hash tables don't preserve insertion
-- order; the accessors in DataAPI.lua honor `_order`, falling back to alphabetical).

local LCEX = LootCouncilEX

LCEX.Loot = {
    ["P2"] = {
        raids = {
            ["Serpentshrine Cavern"] = {
                _order = { "Hydross the Unstable", "Leotheras the Blind", "Lady Vashj" },
                ["Hydross the Unstable"] = { 28830, 29918 },
                ["Leotheras the Blind"]  = { 30055 },
                ["Lady Vashj"]           = { 30185, 30619 },
            },
            ["Tempest Keep"] = {
                _order = { "Al'ar", "Void Reaver", "Kael'thas Sunstrider" },
                ["Al'ar"]                = { 32837 },
                ["Void Reaver"]          = { 29381 },
                ["Kael'thas Sunstrider"] = { 28040, 29918 },
            },
        },
    },
}
