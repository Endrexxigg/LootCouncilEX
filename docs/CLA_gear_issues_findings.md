# CLA "Gear Issues" — Reference Model for LCEX

**Purpose:** spec the gear-issue detection model used by CLA (WoW Classic TBC *Combat Log Analytics* by Lars Maag, v1.6.0b) so it can be adapted into LootCouncil EX. This documents *what CLA counts as an issue*, the config data that drives it, and where LCEX should deviate because it runs in-game rather than parsing WarcraftLogs after the fact.

---

## 1. Data model

CLA reads each player's gear from the WarcraftLogs `combatantinfo` event. Key consequences:

- Gear is captured **only at the start of each boss pull** — one snapshot per player per boss. Gear swaps mid-fight are invisible; boss-conditional checks (e.g. meta-gem activation) are therefore evaluated **per boss**, not once per player.
- Output is one row per player, with each problem rendered as a separate cell in the form `Item name [issue reason]`.
- CLA only sees what the combat log exposes: item IDs, enchant IDs, gem IDs, socket data. It has no direct access to live tooltip state, so several checks are **inference/heuristic-based** to work around that.

**LCEX does not share these limitations.** In-game it can read live gear, exact enchant IDs, socket fill state, and gem quality directly (`GetInventoryItemLink`, item string enchant/gem fields, `C_Item`/tooltip socket queries). The taxonomy below is worth adopting wholesale; the *heuristics* CLA uses to compensate for WCL are not.

---

## 2. Issue taxonomy (detection rules)

| Issue tag | Trigger | Notes for LCEX |
|---|---|---|
| `[no enchant]` | Enchantable slot has no enchant ID. | Skip if item is on the excluded-gear list (§4). |
| `[no gem used]` | Item has an open socket. | In-game you can detect empty sockets exactly; no inference needed. |
| `[uncommon gem used]` / `[common gem used]` | Gem quality is below the configured minimum (`rare`). Meta gems are exempt from this quality check. | Replace the quality heuristic with true socket-color matching if desired. |
| `[meta gem inactive on <boss>]` | Meta gem's color/socket requirement is unmet, so it grants nothing. | Evaluate once against current gear at loot time — the per-boss split is a WCL artifact. |
| `[<enchant name>]` e.g. `[+10 Critical Strike]`, `[4 All Stats]`, `[+4 Weapon Damage]` | Applied enchant ID is on the "cheap/bad enchants" blacklist (§4). Prints the offending enchant instead of a generic tag. | Keep as blacklist, or invert to a per-slot allowlist (see §6). |
| `[vs. non-undead]` and related | Boss-conditional "useless item": item does nothing on this encounter. Family covers **undead-only**, **demon-only**, **PvP trinkets**, and **engineering** items ("smart engi"). | Highest-value / least-obvious check. Recommended to adopt. |

Report-scope toggles present in CLA: `list players with no issues?`, and per-boss opt-outs such as `exclude Mother Shahraz` (suppresses false positives on specific fights).

---

## 3. Slot index mapping

CLA's enchant blacklist keys entries by **WarcraftLogs 0-based gear-array slot index**. LCEX must remap these to WoW's 1-based `INVSLOT_*` constants:

| WCL slot | Equipment slot | `INVSLOT_*` |
|---|---|---|
| 0 | Head | `INVSLOT_HEAD` (1) |
| 1 | Neck | `INVSLOT_NECK` (2) |
| 2 | Shoulder | `INVSLOT_SHOULDER` (3) |
| 4 | Chest | `INVSLOT_CHEST` (5) |
| 5 | Waist | `INVSLOT_WAIST` (6) |
| 6 | Legs | `INVSLOT_LEGS` (7) |
| 7 | Feet | `INVSLOT_FEET` (8) |
| 8 | Wrist | `INVSLOT_WRIST` (9) |
| 9 | Hands | `INVSLOT_HAND` (10) |
| 14 | Back | `INVSLOT_BACK` (15) |
| 16 | Off-hand / Shield | `INVSLOT_OFFHAND` (17) |

---

## 4. Config data (the lists that drive detection)

### 4a. Minimum gem quality
Single setting. CLA value: **`rare`**. Any gem below rare (uncommon/common) is flagged. Meta gems excluded.

### 4b. Cheap / bad enchants — blacklist (~136 entries)
Format: `enchantID [WCL slot]` + label. If an equipped item's enchant ID matches (respecting slot where a slot index is given), it's flagged as suboptimal. These are the low/mid ranks of each enchant plus profession/utility enchants that shouldn't appear on raid gear.

**Slot-keyed entries:**

- **Head** (slot 0): 2841 (Heavy Knothide Kit)
- **Shoulder** (slot 2): 2841 (Heavy Knothide Kit)
- **Chest** (slot 4): 908 (50 HP), 850 (35 HP), 254 (25 HP), 242 (15 HP), 41 (5 HP), 913 (65 Mana), 857 (50 Mana), 843 (30 Mana), 246 (20 Mana), 24 (5 Mana), 928 (3 Stats), 866 (2 Stats), 847 (1 Stats), 63 (25 Absorb), 44 (10 Absorb), 1891 (4 Stats), 1893 (100 Mana), 2841 (Heavy Knothide Kit)
- **Legs** (slot 6): 2583 (ZG head/legs), 2841 (Heavy Knothide Kit)
- **Feet** (slot 7): 255 (3 Spi), 904 (5 Agi), 849 (3 Agi), 247 (1 Agi), 852 (5 Sta), 724 (3 Sta), 66 (1 Sta), 1887 (7 Agi), 929 (7 Sta), 2841 (Heavy Knothide Kit), 464 (Mount Speed)
- **Wrist** (slot 8): 927 (7 Str), 856 (5 Str), 823 (3 Str), 248 (1 Str), 929 (7 Sta), 852 (5 Sta), 724 (3 Sta), 66 (1 Sta), 41 (5 HP), 907 (7 Spi), 851 (5 Spi), 255 (3 Spi), 905 (5 Int), 723 (3 Int), 923 (3 Def), 925 (2 Def), 924 (1 Def), 1886 (9 Sta), 1885 (9 Str)
- **Hands** (slot 9): 1887 (7 Agi), 904 (5 Agi), 856 (5 Str), 909 (5 Herb), 845 (3 Herb), 906 (5 Mining), 844 (3 Mining), 865 (5 Skinn), 846 (2 Fishing), 2934 (Blasting), 927 (7 Str), 930 (Mount Speed)
- **Back** (slot 14): 910 (Stealth), 903 (3 Res), 65 (1 Res), 2463 (7 FR), 256 (5 FR), 1889 (70 Armor), 884 (50 Armor), 848 (30 Armor), 744 (20 Armor), 783 (10 Armor), 247 (1 Agi), 2938 (Spell Pen)
- **Off-hand/Shield** (slot 16): 852 (5 Sta), 724 (3 Sta), 66 (1 Sta), 907 (7 Spi), 851 (5 Spi), 255 (3 Spi), 848 (30 Armor), 1704 (Thorium Spike), 463 (Mithril Spike), 43 (Iron Spike), 929 (7 Sta)

**Slot-agnostic entries** (matched by enchant ID regardless of slot — weapon enchants, generic armor kits/leg armors, ZG/faction shoulder inscriptions):

- Generic armor: 2503 (3 Def), 1843 (40 Armor), 18 (32 Armor), 17 (24 Armor), 16 (16 Armor), 15 (8 Armor)
- Weapon: 1903 (9 Spi), 255 (3 Spi), 1904 (9 Int), 723 (3 Int), 1896 (9 Dmg), 963 (7 Dmg), 943 (3 Dmg), 241 (2 Dmg), 2443 (7 Frost), 1899 (Unholy), 1898 (Lifesteal), 803 (Fiery), 854 (Elemental), 805 (4 Dmg), 2646 (25 Agi), 2568 (22 Int), 1900 (Crusader), 2669 (40 SP)
- Legs: 2745 (Silver Thread), 2747 (Mystic Thread), 3010 (40 AP / 10 Crit)
- Shoulder inscriptions: 2606/2605/2604 (ZG), 2996/2990/2992/2994 (Scryer Honored), 2981/2979/2983/2977 (Aldor Honored)
- ZG head/legs: 2591, 2586, 2588, 2584, 2590, 2585, 2587, 2589
- Kits / misc: 2792 (Knothide Kit), 911 (Boots - Minor Speed)

> Note: some IDs (e.g. 927, 1887, 929, 852, 724, 66, 255) recur across slots because enchant IDs are shared; CLA disambiguates via the slot index. When an entry has no slot index, it matches on ID alone.

### 4c. Excluded gear — whitelist (37 itemIDs)
Items that must never be flagged for missing enchant/gem (fishing poles, off-set/utility items, profession-crafted gathering gear, un-enchantable BiS weapons):

15138 Onyxia Scale Cloak · 9449 Manual Crowd Pummeler · 19022 Nat Pagle's Extreme Angler FC-5000 · 19970 Arcanite Fishing Pole · 25978 Seth's Graphite Fishing Pole · 6365 Strong Fishing Pole · 12225 Blump Family Fishing Pole · 6367 Big Iron Fishing Pole · 6366 Darkwood Fishing Pole · 6256 Fishing Pole · 38175 The Horseman's Blade · 21864 Soulcloth Shoulders · 21865 Soulcloth Vest · 21868 Arcanoweave Robe · 23509 Enchanted Adamantite Breastplate · 23512 Enchanted Adamantite Leggings · 21867 Arcanoweave Boots · 23511 Enchanted Adamantite Boots · 21863 Soulcloth Gloves · 28301 Syrannis' Mystic Sheen · 31938 Enigmatic Cloak · 27449 Blood Knight Defender · 29495 Enchanted Clefthoof Leggings · 29489 Enchanted Felscale Leggings · 29497 Enchanted Clefthoof Boots · 29491 Enchanted Felscale Boots · 21866 Arcanoweave Bracers · 29496 Enchanted Clefthoof Gloves · 29490 Enchanted Felscale Gloves · 30831 Cloak of Arcane Evasion · 30311 Warp Slicer · 30312 Infinity Blade · 30313 Staff of Disintegration · 30314 Phaseshift Bulwark · 30316 Devastation · 30317 Cosmic Infuser · 30318 Netherstrand Longbow

---

## 5. Evaluation order

CLA effectively runs each item through this pipeline, emitting one tag per failure:

1. On excluded-gear whitelist? → skip all checks.
2. Slot enchantable but no enchant? → `[no enchant]`.
3. Enchant present but on blacklist (matching slot/ID)? → `[<enchant name>]`.
4. Open socket? → `[no gem used]`.
5. Gem present but below min quality (non-meta)? → `[<quality> gem used]`.
6. Meta gem present but requirement unmet? → `[meta gem inactive on <boss>]`.
7. Item useless on this encounter (undead/demon/PvP/engi)? → `[<condition>]`.

---

## 6. Recommendations for LCEX

**Adopt:**
- The full taxonomy in §2 and the data-driven config-list architecture (§4). Keep detection logic driven by editable tables, not hardcoded.
- The boss-conditional "useless item" check (undead/demon/PvP-trinket/engi). It's the least obvious check and adds the most value over a naive enchant/gem pass. Needs a small per-encounter flag table (is-undead, is-demon, is-pvp) plus item→condition mappings.
- The excluded-gear whitelist concept — essential to avoid false positives on fishing poles, off-set weapons, and profession gear.

**Deviate (leverage in-game data):**
- Drop the gem-quality heuristic in favor of exact empty-socket detection and true socket-color matching, since LCEX can read this directly.
- Evaluate meta-gem activation once against current gear at loot time; discard CLA's per-boss re-evaluation (a WCL snapshot artifact).
- Consider **inverting the enchant blacklist to a per-slot allowlist** of acceptable (BiS/near-BiS) enchants. CLA's list is 136 rows precisely because blacklisting every bad rank is exhaustive and needs constant maintenance; a short allowlist per slot is lower-maintenance and fails safe (unknown enchant → flag for review).

**Remap:** all WCL 0-based slot indices to `INVSLOT_*` per §3 before consuming the §4 lists.

---

*Source: CLA v1.6.0b, "gear issues" sheet + embedded config lists — the production sheet in active weekly use on Anniversary. The enchant/item IDs are current, working data. Figures/samples drawn from the bundled SSC/TK example report.*
