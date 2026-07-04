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

    -- Blacklist of low-rank / utility enchant IDs (CLA §4b). Enchant IDs are globally unique, so
    -- CLA's per-slot keying is flattened here to one ID → label map (a listed ID is flagged on any
    -- slot). The value IS the display label (CLA's short text) — GetItemInfo can't resolve enchant
    -- names. Used for any slot without an enchantAllow list. Grouped by CLA category for review.
    enchantBad = {
        [2841] = "Heavy Knothide Kit", [2792] = "Knothide Kit",
        -- Chest — low Health / Mana / Stats / Absorb
        [908] = "50 HP", [850] = "35 HP", [254] = "25 HP", [242] = "15 HP", [41] = "5 HP",
        [913] = "65 Mana", [857] = "50 Mana", [843] = "30 Mana", [246] = "20 Mana", [24] = "5 Mana",
        [928] = "3 Stats", [866] = "2 Stats", [847] = "1 Stats", [1891] = "4 Stats", [1893] = "100 Mana",
        [63] = "25 Absorb", [44] = "10 Absorb",
        -- Low single-stat enchants (Agi / Sta / Str / Spi / Int / Def)
        [904] = "5 Agi", [849] = "3 Agi", [247] = "1 Agi", [1887] = "7 Agi",
        [852] = "5 Sta", [724] = "3 Sta", [66] = "1 Sta", [929] = "7 Sta", [1886] = "9 Sta",
        [927] = "7 Str", [856] = "5 Str", [823] = "3 Str", [248] = "1 Str", [1885] = "9 Str",
        [907] = "7 Spi", [851] = "5 Spi", [255] = "3 Spi",
        [905] = "5 Int", [723] = "3 Int",
        [923] = "3 Def", [925] = "2 Def", [924] = "1 Def", [2503] = "3 Def",
        -- Boots / gloves utility + gathering
        [464] = "Mount Speed", [930] = "Mount Speed", [911] = "Minor Speed",
        [909] = "5 Herb", [845] = "3 Herb", [906] = "5 Mining", [844] = "3 Mining",
        [865] = "5 Skinn", [846] = "2 Fishing", [2934] = "Blasting",
        -- Cloak / resistance / armor
        [910] = "Stealth", [903] = "3 Res", [65] = "1 Res", [2463] = "7 FR", [256] = "5 FR",
        [2938] = "Spell Pen",
        [1889] = "70 Armor", [884] = "50 Armor", [848] = "30 Armor", [744] = "20 Armor", [783] = "10 Armor",
        [1843] = "40 Armor", [18] = "32 Armor", [17] = "24 Armor", [16] = "16 Armor", [15] = "8 Armor",
        -- Shield spikes
        [1704] = "Thorium Spike", [463] = "Mithril Spike", [43] = "Iron Spike",
        -- Weapon — low damage / stats / cheap procs
        [1896] = "9 Dmg", [963] = "7 Dmg", [943] = "3 Dmg", [241] = "2 Dmg", [805] = "4 Dmg",
        [1903] = "9 Spi", [1904] = "9 Int", [2646] = "25 Agi", [2568] = "22 Int", [2669] = "40 SP",
        [2443] = "7 Frost", [1899] = "Unholy", [1898] = "Lifesteal", [803] = "Fiery", [854] = "Elemental",
        [1900] = "Crusader",
        -- Legs threads
        [2745] = "Silver Thread", [2747] = "Mystic Thread", [3010] = "40 AP / 10 Crit",
        -- Shoulder inscriptions (ZG / Scryer & Aldor honored)
        [2606] = "ZG shoulder", [2605] = "ZG shoulder", [2604] = "ZG shoulder",
        [2996] = "Scryer Honored", [2990] = "Scryer Honored", [2992] = "Scryer Honored", [2994] = "Scryer Honored",
        [2981] = "Aldor Honored", [2979] = "Aldor Honored", [2983] = "Aldor Honored", [2977] = "Aldor Honored",
        -- ZG head/legs enchants
        [2583] = "ZG head/legs", [2591] = "ZG head/legs", [2586] = "ZG head/legs", [2588] = "ZG head/legs",
        [2584] = "ZG head/legs", [2590] = "ZG head/legs", [2585] = "ZG head/legs", [2587] = "ZG head/legs",
        [2589] = "ZG head/legs",
    },

    -- Reserved for allowlist-mode display labels; the blacklist above carries its own labels.
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
