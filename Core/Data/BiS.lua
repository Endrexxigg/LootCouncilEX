-- ── LootCouncil EX — Data/BiS.lua ────────────────────────────────────────────
-- SHIPPED STATIC DATA — class → spec → phase → slot → {itemIDs}. STUB sample for Phase 6
-- (one class/spec, a few slots, real TBC itemIDs). Real BiS lists are Phase 7 content.
--
-- Shape (PROJECT.md §6.6): BiS[CLASS][spec][phase][slot] = { itemID, altID, ... }. Slot keys
-- are the canonical lowercase set in LCEX.BIS_SLOT_ORDER (DataAPI.lua). CLASS is the WoW class
-- token (e.g. "MAGE") so it matches UnitClass's 2nd return.

local LCEX = LootCouncilEX

LCEX.BiS = {
    ["MAGE"] = {
        ["Fire"] = {
            ["P2"] = {
                head  = { 28830 },
                neck  = { 29918 },
                hands = { 30055 },
            },
        },
        ["Frost"] = {
            ["P2"] = {
                head = { 28830 },
                neck = { 29918 },
            },
        },
    },
}
