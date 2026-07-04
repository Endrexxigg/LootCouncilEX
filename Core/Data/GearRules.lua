-- ── LootCouncil EX — Data/GearRules.lua ──────────────────────────────────────
-- SHIPPED STATIC DATA driving the gear-issue detector (Core/GearIssues.lua, Feature G).
-- HAND-MAINTAINED (unlike Loot/BiS, which the converter generates) — the model is adapted
-- from CLA's "gear issues" sheet, documented in docs/CLA_gear_issues_findings.md.
--
-- Shape (PROJECT.md §6.8):
--   minGemQuality  — filled gems below this itemQuality are flagged (3 = rare; meta gems are
--                    epic-quality so they're naturally exempt).
--   enchantable    — inventory slots that SHOULD carry an enchant → a bare slot flags [no enchant].
--                    Conservative set: only slots every raider enchants regardless of class or
--                    profession. Off-hand (17, conditional) and rings (11/12, enchanter-only) are
--                    deliberately omitted for now to avoid false positives.
--   enchantAllow   — OPTIONAL per-slot allowlist of acceptable enchant IDs. When a slot has one,
--                    the detector runs in ALLOWLIST mode for that slot (any enchant NOT listed is
--                    flagged — fail-safe, CLA §6). Empty for now: needs a curated good-enchant list.
--   enchantBad     — fallback BLACKLIST of suboptimal enchant IDs (CLA §4b real data). Used for a
--                    slot with no allowlist. Empty for now; populated in a follow-up commit.
--   enchantLabel   — display name for a flagged enchant ID (GetItemInfo can't resolve enchant names).
--   excludeItems   — itemIDs that must NEVER be flagged for a missing enchant/gem (fishing poles,
--                    off-set/utility items, un-enchantable BiS weapons) — CLA §4c, 37 entries.
--
-- Inventory slot numbers are WoW's 1-based INVSLOT_* (matching gearCache's slot keys), already
-- remapped from CLA's 0-based WarcraftLogs indices (docs/CLA_gear_issues_findings.md §3).

local LCEX = LootCouncilEX

LCEX.GearRules = {
    minGemQuality = 3, -- rare

    -- 1=Head 3=Shoulder 5=Chest 7=Legs 8=Feet 9=Wrist 10=Hands 15=Back 16=Main-hand
    enchantable = {
        [1] = true, [3] = true, [5] = true, [7] = true, [8] = true,
        [9] = true, [10] = true, [15] = true, [16] = true,
    },

    -- Per-slot allowlists (empty → the slot falls back to enchantBad). Fill as good-enchant
    -- lists are compiled, e.g. enchantAllow[1] = { [2999] = true, ... } for head.
    enchantAllow = {},

    -- Blacklist of low/utility enchant IDs (CLA §4b). Filled in a follow-up commit. Shape:
    -- flat { [enchantID] = true } (slot-agnostic) — the detector checks it for any slot lacking
    -- an allowlist.
    enchantBad = {},

    -- Names for flagged enchants (there is no API from enchant ID → name).
    enchantLabel = {},

    -- Never flag these for a missing enchant/gem (CLA §4c). Fishing poles, off-set weapons,
    -- profession-crafted gathering gear, and un-enchantable BiS.
    excludeItems = {
        -- Fishing poles + off-set / utility weapons
        [15138] = true, [9449]  = true, [19022] = true, [19970] = true, [25978] = true,
        [6365]  = true, [12225] = true, [6367]  = true, [6366]  = true, [6256]  = true,
        [38175] = true,
        -- Tailoring / profession-crafted armor that can't (or shouldn't) be enchanted
        [21864] = true, [21865] = true, [21868] = true, [23509] = true, [23512] = true,
        [21867] = true, [23511] = true, [21863] = true, [28301] = true, [31938] = true,
        [27449] = true, [29495] = true, [29489] = true, [29497] = true, [29491] = true,
        [21866] = true, [29496] = true, [29490] = true, [30831] = true,
        -- Warglaives / Sunwell un-enchantable set weapons (Warp Slicer … Netherstrand Longbow)
        [30311] = true, [30312] = true, [30313] = true, [30314] = true, [30316] = true,
        [30317] = true, [30318] = true,
    },
}
