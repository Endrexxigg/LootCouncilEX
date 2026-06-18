-- ── LootCouncil EX — Data/TierTokens.lua ─────────────────────────────────────
-- SHIPPED STATIC DATA — tier-token itemID → the per-class tier piece it turns into. STUB
-- sample for Phase 6 (a couple of tokens). Real token tables are Phase 7 content.
--
-- Shape (PROJECT.md §6.6): TierTokens[tokenID] = { name = <display>, pieces = { CLASS = pieceID } }.
-- Used to cross-reference loot/BiS items: a token that drops shows which class gets which piece.

local LCEX = LootCouncilEX

LCEX.TierTokens = {
    [29753] = {
        name = "Helm of the Fallen Champion",
        pieces = { ["WARRIOR"] = 29021, ["PALADIN"] = 29061, ["PRIEST"] = 29049 },
    },
    [29761] = {
        name = "Helm of the Fallen Hero",
        pieces = { ["HUNTER"] = 29081, ["MAGE"] = 29076, ["WARLOCK"] = 28963 },
    },
}
