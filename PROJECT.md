# LootCouncil EX — Project Source of Truth

> This is the canonical project document. Read it first at the start of every Claude Code session and treat it as authoritative. It supersedes any earlier spec. Intended to live in the repo root as `PROJECT.md` (or `CLAUDE.md`).

---

## 1. Intent

LootCouncil EX is a loot council addon for **World of Warcraft: The Burning Crusade Classic (Anniversary realms)**. It replaces RCLootCouncil, whose Classic build is a patch layer bolted onto the retail core and is buggy and clunky as a result.

**North Star:** a fast, clean, TBC-native loot council tool that does the broadcast → respond → vote → award loop without friction, plus a persistent council toolkit (notes, marks, history, gear/profession lookup) that helps the council make decisions.

**Definition of done (v1):** a guild can run a full raid night on this addon — items get councilled and awarded correctly via master loot — and the council can keep synced notes and persistent gear marks across raid nights.

**Non-goals (do not build):** retail/Era/SoD support; DKP/EPGP/GP point systems; PUG support / non-installed-user fallback (stub only); multiple simultaneous loot sessions; cross-guild council sync; auto-trade handoff polish.

---

## 2. Hard constraints

- **TBC Classic Anniversary API only.** Never use retail-only APIs. When unsure of a signature, verify against the current Classic client, don't assume.
- **Native frames only — no AceGUI.** AceGUI is the source of the "ancient/clunky" feel we're escaping. All UI is `CreateFrame` + a shared style layer.
- **Guild-only model.** Assume every raider has the addon installed; the council is all in one guild. The non-installed whisper fallback is stubbed, not implemented.
- **Data realities the design must respect:**
  - *Gear and professions cannot come from Blizzard inspection* (range/faction/throttle limited). Each player's addon **self-reports** its own gear and professions over comms. Non-addon users and offline/out-of-raid players show last-cached data or nothing.
  - *BiS lists, tier-token mappings, and loot tables are shipped static datasets* that must be compiled and maintained per phase. They are reference data, not code.
  - *Out-of-raid council sync is eventually-consistent.* It reconciles only when two council members are online at the same time (no server). It runs over the **guild channel** and assumes a same-guild council.

---

## 3. Architecture — two data planes

Keep these two subsystems mentally and structurally separate.

### Plane A — Live session (ephemeral, ML-authoritative)
The loot voting itself. The **master looter is the single source of truth.** Candidates and council members whisper to the ML; the ML aggregates and rebroadcasts canonical state to RAID. Exists only while a session is open. No peer-to-peer sync — every change funnels through the ML.

**Loot sourcing & handoff (DL-7):** the ML **auto-loots every drop into their own bags** during the raid and councils them in sessions started later (periodically / end of night) — there is no master-loot-from-corpse. The winner receives the item by **trading** it within the BoP 2-hour window; the addon assists the trade and tracks the timer.

### Plane B — Persistent council (durable, multi-writer, replicated)
Player notes, item/gear marks, shared award history, and cached gear/professions. Authored by any council member, replicated among the council over the **GUILD** channel, persisted in SavedVariables, available in or out of raid. No single authority; conflicts resolve **last-write-wins** on a per-record timestamp. Eventually-consistent.

| | Plane A | Plane B |
|---|---|---|
| Owner | Master looter | Every council member |
| Channel | RAID + WHISPER | GUILD + WHISPER |
| Lifetime | One session | Permanent (SavedVariables) |
| Conflict model | ML is authority | Last-write-wins by `mod` timestamp |
| Available out of raid | No | Yes (when peers online) |

---

## 4. Conventions

- **Addon/folder:** `LootCouncilEX`. **Comms prefix:** `LCEX`. **Slash command:** `/lcex`.
- **Libraries:** LibStub + ACE3 (AceAddon, AceEvent, AceComm, AceSerializer, AceConsole, AceDB, AceTimer). **All networking via AceComm — never raw `SendAddonMessage`.**
- **Comms envelope:** every message is one AceSerializer-encoded table `{ v, cmd, sid, ver, ... }`. `v` = `PROTOCOL_VERSION`; drop messages with an unreadable higher major `v`. `cmd` routes through a dispatch table. `sid` identifies the session (nil for Plane B / roster messages). `ver` = the sender's human-facing addon version, stamped on **every** message so peers learn each other's version passively from any traffic (not just the vCheck handshake); the receiver records it silently before dispatch.
- **Plane B record format:** every record carries `mod` (unixtime last modified) and `by` (author char name). **Merge rule:** per key keep the greatest `mod`; ties broken by `by` alphabetically. Immutable datasets (history) merge by union of keys.
- **UI is data-driven:** response buttons, columns, etc. build from the `RESPONSES` table, not hardcoded.
- **Modules are small and single-purpose** per the file layout below.
- **Dev workflow:** symlink the addon folder into the WoW AddOns dir; iterate with `/reload`. This file is the Claude Code context (`PROJECT.md` / `CLAUDE.md`).
- **Frames register for ESC-close** by adding their global name to `UISpecialFrames` (helper in `UI/Widgets.lua`).

---

## 5. File layout

```
LootCouncilEX/
├── LootCouncilEX.toc
├── embeds.xml
├── Libs/                      # LibStub + ACE3 + LibDataBroker/LibDBIcon (minimap)
├── Core/
│   ├── Init.lua               # bootstrap, prefix, DB defaults + profile cleanup, /lcex
│   ├── Const.lua              # PROTOCOL_VERSION, RESPONSES, STATUS, L[]
│   ├── Comms.lua              # envelope, (de)serialize, dispatch, debounce
│   ├── Roster.lua             # raid roster + addon-version handshake
│   ├── Minimap.lua            # LDB launcher: left=loot, right=council, ctrl=config
│   ├── Display.lua            # pure display-array builders (headless-tested; UI renders them)
│   ├── Usable.lua             # poll class filter: token lines + TBC proficiency matrix
│   ├── GearIssues.lua         # Feature G: parse gear links → enchant/gem issue tags (pure, headless-tested)
│   ├── SelfTest.lua           # /lcex selftest — in-game validation harness
│   ├── session/               # PLANE A
│   │   ├── Session.lua        # ML state machine (authority); sStart carries the poll deadline
│   │   ├── Candidate.lua      # receive sStart → poll → send cResp (per-card note)
│   │   ├── Council.lua        # receive cUpdate → loot window → send vVote
│   │   └── Award.lua          # bags/loot detection; award = assist-trade (TRADE_SHOW fill + 2h timer)
│   ├── council/               # PLANE B
│   │   ├── Sync.lua           # GUILD sync engine (manifest, deltas, LWW merge)
│   │   ├── Notes.lua          # player notes dataset
│   │   ├── Marks.lua          # item/gear marks dataset
│   │   ├── History.lua        # award history (witnessed + synced)
│   │   └── SelfReport.lua     # broadcast own gear/profs; cache others'
│   └── Data/                  # SHIPPED STATIC DATA (generated by tools/build_data.lua)
│       ├── Loot.lua           # phase → raid → boss → {itemIDs}
│       ├── BiS.lua            # class → spec → phase → slot → {itemIDs}
│       ├── TierTokens.lua     # tokenItemID → {class → {tierPieceItemIDs}}
│       ├── GearRules.lua      # Feature G: enchant allowlist + gem-min-quality + excluded-gear whitelist (CLA-derived)
│       └── DataAPI.lua        # pure accessors over the shipped tables
└── UI/                        # the four-frame UI (DL-12): flat-dark, gold accent
    ├── Theme.lua              # design language: surface tones, fonts, paint helpers
    ├── Widgets.lua            # themed primitives: window/rail/list/button/checkbox/slider
    ├── PollWindow.lua         # `poll`: raider response cards (filtered, 3 visible, per-card note)
    ├── LootWindow.lua         # `loot`: staging list + item rail + candidate table + award
    ├── CouncilWindow.lua      # `council`: resizable dashboard shell + module registry
    ├── council/               # self-registering dashboard modules
    │   ├── BrowserModule.lua  # loot browser (quality colors, hierarchy, mark editor)
    │   ├── PlayersModule.lua  # player picker + Gear|History|Profs|BiS|Notes
    │   ├── GearCheckModule.lua # Feature G: roster-wide gear-issue overview (everyone + issue counts)
    │   ├── HistoryModule.lua  # guild-wide award log
    │   └── SessionConfigModule.lua # officer: council roster, poll deadline, DL-8 slot
    └── ConfigWindow.lua       # `config`: schema-driven user settings
```

---

## 6. Canonical reference

### 6.1 Plane A messages
Envelope `{ v, cmd, sid, ver, ... }`; `sid` = `"<MLname>-<unixtime>-<counter>"`; `ver` is stamped on every message (see §4).

| cmd | Direction | Channel | Payload |
|---|---|---|---|
| `vCheck` | any → raid | RAID | `{}` (ver rides on the envelope) |
| `vReply` | client → asker | WHISPER | `{}` (ver rides on the envelope) |
| `sStart` | ML → raid | RAID | `{ items={[i]={link,quality}}, council={names} }` |
| `sEnd` | ML → raid | RAID | `{}` |
| `sPing` | ML → raid | RAID | `{}` (liveness heartbeat, ~30s while open; sid on the envelope — DL-6) |
| `cResp` | candidate → ML | WHISPER | `{ item, resp, note, ilvl, gear={link,link} }` |
| `cUpdate` | ML → raid | RAID | `{ item, rows={[name]={resp,note,ilvl,gear,votes}} }` |
| `vVote` | council → ML | WHISPER | `{ item, candidate, vote=±1|0 }` |
| `award` | ML → raid | RAID | `{ item, itemID, itemIndex, winner, resp, boss, instance, ts }` |

Reliability: ML holds the authoritative table; drop inbound `cResp`/`vVote` with a stale `sid` or non-member/non-council sender. Debounce `cUpdate` (~0.2s). Idempotent — re-sends overwrite last value. No ACK in v1. `award` carries enough to build a complete local history record on every present client.

Notes: items live in the ML's bags (no loot slot), so `sStart` items carry only `{link,quality}` — the ML resolves the live `{bag,slot}` locally at trade time. Until Phase-3 voting exists, `award.resp` carries the `STATUS.ANNOUNCED` sentinel.

### 6.2 Plane B messages
Channel GUILD; only council members participate.

| cmd | Direction | Channel | Payload |
|---|---|---|---|
| `pReport` | any group member → GUILD | GUILD | `{ gear={slot→link}, profs={name→level}, class, spec, mod }` |
| `pSet` | council → GUILD | GUILD | `{ dataset="notes"|"marks", key, record={text,mod,by} }` |
| `pHello` | council → GUILD | GUILD | `{ digest={ notes={n,maxMod}, marks={n,maxMod}, history={n}, gearCache={n,maxMod}, profCache={n,maxMod} } }` |
| `pSyncReq` | council → peer | WHISPER | `{ dataset, since=<mod|0> }` |
| `pSyncData` | council → peer | WHISPER | `{ dataset, records={key→record} }` |

Sync flow: on login/load broadcast `pHello`; a peer that's behind sends `pSyncReq(since=myMaxMod)`; peer replies `pSyncData` with the delta. Live edits propagate via `pSet`. Accept `pReport` from any group member (so any raider's gear/profs can be viewed); gate `pSet`/`pHello`/`pSync*` to council senders only.

### 6.3 Datasets (Plane B, in SavedVariables `global`)
- `notes`: name → `{text, mod, by}`
- `marks`: itemID → `{text, mod, by}`
- `history`: uid → `{player, itemID, itemLink, ts, resp, boss, instance}` (immutable; union merge). uid = `sid..":"..itemIndex` (so `award` carries `itemIndex`). Records also carry `by` (the logging ML) + `mod`=ts for display; union ignores both for merge. Logged locally on every present client from the `award` broadcast (§6.1).
- `gearCache`: name → `{items={slot→link}, class, spec, mod}` (self-reported; `class`/`spec` let the BiS tab auto-resolve a cached player — talent-derived spec, §6.7)
- `profCache`: name → `{profs={name→level}, mod}` (self-reported)

### 6.4 SavedVariables
```lua
LootCouncilEXDB = {
  profile = {
    council            = { byRank=true, rank=1, extra={} },  -- see DL-1: vote roster + sync roster currently shared
    syncChannel        = "GUILD",
    minQuality         = 4,
    selfReport         = true,
    ui                 = { lootFrame={pos}, votingFrame={pos}, sessionFrame={pos}, playerDetail={pos}, lootBrowser={pos} },
    useWhisperFallback = false,
  },
  global = {
    dbVersion = <int>,                  -- schema version; MigrateDB stamps/upgrades on load (Phase 7)
    notes={}, marks={}, history={}, gearCache={}, profCache={},
    -- Local (NOT synced) owner-keyed recovery stores so a /reload can't lose ML state (DL-6):
    pendingTrades = { [owner] = { [shortKey] = {owed records} } },  -- owed loot still to be traded out
    session       = { [owner] = {sid, items, council, sessionItems, startedAt} },  -- the open ML session
  },
}
```

### 6.5 Response enum
```lua
RESPONSES = {  -- DEFAULTS; user-configurable (add/remove/rename) is Phase 3
  [1]={id=1,key="BIS",  text="BiS",   color={0.96,0.55,0.73}},
  [2]={id=2,key="MAJOR",text="Major", color={0.20,1.00,0.20}},
  [3]={id=3,key="MINOR",text="Minor", color={1.00,0.96,0.41}},
  [4]={id=4,key="GREED",text="Greed", color={0.70,0.70,0.70}},
  [5]={id=5,key="PASS", text="Pass",  color={0.60,0.20,0.20}},  -- built-in: always present
}
STATUS = { ANNOUNCED=90, TIMEOUT=91, NOADDON=92 }
```
`PASS` is a built-in response (a candidate must always be able to decline; timeouts resolve to a non-response). The rest are defaults the council may reconfigure once the settings UI lands (DL-8).

### 6.6 Static data shapes
```lua
Loot       = { ["P2"]={ raids={ ["Serpentshrine Cavern"]={ ["Hydross the Unstable"]={itemID,...}, ... }, ["Tempest Keep"]={...} } } }
BiS        = { ["MAGE"]={ ["Fire"]={ ["P2"]={ ["head"]={itemID}, ["neck"]={itemID,altID}, ... } } } }
TierTokens = { [30243]={ name="Helm of the Vanquished Defender", pieces={ ["WARRIOR"]={itemID,...}, ["PRIEST"]={...}, ["DRUID"]={...} } } }  -- pieces[CLASS] is a LIST (spec-variant sets → several pieces)
```

### 6.7 Key TBC APIs (verify signatures)
- **ESC close:** `tinsert(UISpecialFrames, "LCEX_FrameName")`.
- **Loot detect (bags flow):** passively track the ML's own loot via `CHAT_MSG_LOOT` ("You receive loot:" — derive the prefix from `LOOT_ITEM_SELF` for locale) to capture the source boss (`UnitName("target")`) + a looted-at `time()` stamp; plus a bag scan over bags 0-4 via **`C_Container`** (`GetContainerNumSlots` / `GetContainerItemLink` / `GetContainerItemInfo`), falling back to the same-named globals when absent (the globals are nil on Anniversary). Read quality from `GetContainerItemInfo` (cache-independent) for bag items; for a freshly-looted item `GetItemInfo` returns nil on first sight, so resolve quality async via `Item:CreateFromItemLink(link):ContinueOnItemLoad` with an `IsItemDataCached` fast-path and a ~0.5s `AceTimer` timeout. itemID via `link:match("item:(%d+)")`.
- **Award handoff (trade):** the ML trades the item to the winner within the BoP 2-hour window. Do NOT auto-open (`InitiateTrade` is hardware-gated); on `TRADE_SHOW` auto-fill via a single **`UseContainerItem(bag,slot)`** guarded by `TradeFrame:IsShown()` (it drops the item into the first free trade slot; slots 1-6 are tradeable, slot 7 = will-not-be-traded), with a manual-drag fallback and a short bag-locked retry. Confirm delivery on `UI_INFO_MESSAGE == ERR_TRADE_COMPLETE` (snapshot the given items at `TRADE_ACCEPT_UPDATE`, warn on a wrong-winner hand-off) — NOT `TRADE_CLOSED`, which also fires on cancel. Track the 2h window from the looted-at `time()` and warn before it lapses. (`GetMasterLootCandidate`/`GiveMasterLoot` are **not used** — the guild auto-loots to bags, see §3 / DL-7.)
- **Own gear:** `GetInventoryItemLink("player", slotID)`; snapshot on `PLAYER_REGEN_DISABLED` (anti-swap).
- **Own professions:** scan `GetNumSkillLines()`/`GetSkillLineInfo(i)` for the two professions + level. (No reliable cross-player profession inspect — self-report only.)
- **Own spec:** on Anniversary `GetTalentTabInfo(tab)` returns `(id, name, description, icon, pointsSpent, fileName)` — take the tab with the most `pointsSpent` (the **5th** return; the 3rd is the description `""`) and use its `name` (2nd) as the spec. Self-reported in `pReport` like gear/profs. (Verified against BigWigs/Cell/Details/NovaInstanceTracker. The single-arg form reads the active tabs; `GetActiveTalentGroup` is not needed.)
- **Equipped ilvl:** `GetAverageItemLevel` unreliable in Classic; show the competing-slot item from the snapshot instead.
- **Comms:** `RegisterComm("LCEX", handler)`; `SendCommMessage("LCEX", msg, "RAID"|"GUILD"|"WHISPER", target)`. GUILD reaches all online guildies (the out-of-raid path).

### 6.8 Gear-issue detection (Feature G)
Adopts the CLA "gear issues" model (`docs/CLA_gear_issues_findings.md`) as a **viewer-side** analysis over the gear links already in `gearCache` (§6.3) — **no comms or protocol change** (DL-13). Rules ship as static data (`Data/GearRules.lua`); `Core/GearIssues.lua` is the pure, headless-tested evaluator; results surface in the Players → Gear sub-tab (per-item tags) and a new roster-wide **Gear Check** council module (everyone + issue counts — the pre-raid slacker scan). **Display-only in v1** (no auto-whisper). v1 ships the **core three** checks (enchant / empty-socket / gem-quality); boss-conditional + meta-gem are deferred (see below).

**Item-string parse.** Split the itemString on `:` — the field after `itemID` = enchantID (0 = none); the next four fields = socketed gem itemIDs (0 = empty). This is a new full-string splitter (existing parsers grab only the itemID).

**Socket count** comes from `GetItemStats(link)` keys `EMPTY_SOCKET_RED|YELLOW|BLUE|META|PRISMATIC` (the item's *inherent* sockets). Empty sockets = inherent sockets − filled gem fields. **Verify on the live Anniversary client (X3):** if `GetItemStats` sockets prove unreliable, fall back to a tooltip scan (localized "Socket" lines) or a reporter-side socket count added to `pReport`/`gearCache` — the *only* variant that would touch comms.

**Rule tables — `Data/GearRules.lua`** (CLA §4, WCL slot indices remapped to `INVSLOT_*` per CLA §3):
```lua
GearRules = {
  minGemQuality = 3,                                   -- rare; filled gem below this = flagged (meta exempt)
  enchantable   = { [INVSLOT_HEAD]=true, ... },        -- slots that SHOULD carry an enchant
  enchantAllow  = { [INVSLOT_HEAD]={ [enchID]=true }, ... },  -- per-slot acceptable enchants (allowlist; CLA §6 inversion — fails safe)
  enchantLabel  = { [enchID]="+10 Critical Strike", ... },    -- names for flagged enchants (GetItemInfo can't resolve enchant names)
  excludeItems  = { [15138]=true, ... },               -- never flag (fishing poles, off-set, un-enchantable BiS) — CLA §4c
}
```

**Evaluation pipeline** — per equipped item, emit one tag per failure (CLA §5):
1. In `excludeItems`? → skip all checks.
2. Slot in `enchantable` and enchantID == 0 → `[no enchant]`.
3. enchantID present and **not** in `enchantAllow[slot]` → `[bad enchant]` (label from `enchantLabel`, else "non-BiS enchant"). Unknown enchant → flagged for review (fail-safe).
4. Empty socket (inherent > filled) → `[no gem used]` (×N).
5. Filled non-meta gem below `minGemQuality` (quality via `GetItemInfo` on the gem itemID) → `[bad gem]`.

**Deferred to a fast-follow (DL-13):** the boss-conditional "useless item" family (undead / demon / PvP-trinket / engineering — needs per-encounter flag tables + item→condition maps), meta-gem activation, and true socket-**color** matching. v1 does enchant presence/allowlist + empty-socket + gem-quality only.

**Display.** Per-item tags render in Players → Gear (danger tone = missing, warning tone = suboptimal). The **Gear Check** module lists every present/cached player with an issue count; empty = "no issues". Own character evaluates live equipped gear; others evaluate from `gearCache` with the existing "cached Nm ago" freshness. Names come from `enchantLabel` (enchants) / `GetItemInfo` (gems) — arbitrary good-enchant names via tooltip scan are deferred.

---

## 7. Build map

Each phase has a hard scope and an exit criterion. Do not build ahead into a later phase. Phases 1–3 produce a working voting addon (the MVP); 4–7 add the council toolkit.

**Phase 1 — Skeleton + comms proof.** `Const`, `Init`, `Comms`, `Roster` + libs.
*Exit:* two clients in a raid, `/lcex` works, `vCheck` round-trips and each prints the other's name + version. No UI. No Lua errors on load.

**Phase 2 — Loot engine (headless).** `session/Session.lua` (state machine), `session/Award.lua` (bags/loot detection, session start, award = assist-trade). Items are sourced from the ML's bags (auto-looted during the raid), not a corpse.
*Exit:* the ML's looted epics are tracked → `/lcex start` broadcasts `sStart` → `/lcex award <n> <name>` records the winner + broadcasts `award` → opening a trade with the winner auto-fills the item (or prompts a manual drag) → the 2h trade timer warns before it lapses. Driven/verified through chat output, `/lcex test`, and a willing trade partner — no live boss required, still no real UI.

**Phase 3 — Session UI → MVP.** `UI/Widgets.lua`, `SessionFrame`, `LootFrame`, `VotingFrame`, wired via `session/Candidate.lua` + `session/Council.lua`.
*Exit:* full live loop between 2+ clients — item drops → candidates respond in a frame → council sees the table and votes → ML awards → item assigned. **This is a usable loot council addon.**

**Phase 4 — Sync engine proof.** `council/Sync.lua` (GUILD transport, `pHello` digest, `pSyncReq`/`pSyncData` deltas, LWW merge) + dataset scaffolding.
*Exit:* two council clients reconcile a *dummy* dataset across offline/online — write on A while B is offline, B catches up on login. Proven before any feature rides on it.

**Phase 5 — Council datasets.** `council/Notes.lua`, `Marks.lua`, `History.lua`, `SelfReport.lua`.
*Exit:* notes, marks, award history, and gear/profession self-reports all sync between council members; awards log automatically from `award`.

**Phase 6 — Viewers + data scaffolding.** `Data/*` (stub samples), `UI/PlayerDetail.lua` (tabbed), `UI/LootBrowser.lua` (phase tabs, boss-sorted, editable marks), tier-token reference.
*Exit:* clicking a player opens the detail panel (gear/history/professions/BiS/notes); loot browser renders by phase/boss with editable persistent marks.

**Phase 7 — Content + polish.** Populate real `Data/*` tables; edge cases (ML disconnect mid-session, stale-cache indicators, roster changes); deferred niceties.
*Exit:* production-ready for a full raid night across multiple weeks.

---

### Post-v1 feature suite (phases 8–11)
Phases 8–11 extend **past** the original v1 definition of done — the four features scoped in `todo.md` (probe-for-detail): gear issues, voting-readiness, council access control, guild bank. Speced incrementally; build order **8 → 9 → 10 → 11** (G → V → C → B) by dependency + risk. A small **shared-foundations** step (guild identity/`guildKey`, X4; shared-config channel, X5) leads Phase 10 and is reused by Phase 11. *(Phases 9–11 are specced as each is reached; see `todo.md` for their locked decisions.)*

**Phase 8 — Gear issues (Feature G).** `Core/GearIssues.lua` (pure detection over `gearCache` links + `GetItemStats` sockets), `Data/GearRules.lua` (CLA-derived rule tables), per-item tags in Players → Gear + `UI/council/GearCheckModule.lua` (roster overview). Core three checks only (enchant allowlist + empty socket + gem quality); viewer-side, no comms change (DL-13).
*Exit:* the Gear Check module lists every raider's enchant/gem problems pre-raid; a test character wearing a missing-enchant + empty-socket + green-gem item surfaces exactly `[no enchant]` `[no gem used]` `[bad gem]`; `/lcex selftest` covers the detection logic (headless, fixed links → expected tags) + the `GetItemStats` socket contract (in-game). Boss-conditional + meta-gem checks are explicitly out of this phase.

---

## 8. Decision log / open questions

- **DL-1 (open, needs owner decision):** `profile.council` currently defines both the live-vote roster *and* the Plane-B sync roster. If notes/sync membership should differ from vote membership, split into two settings before Phase 4.
- **DL-2 (out of scope v1):** cross-guild council sync via custom channel — fragile; deferred.
- **DL-3 (accepted v1):** no ACK on Plane A; last-write-wins + re-click. Revisit only if delivery gaps appear in practice.
- **DL-4 (accepted, no alternative):** gear/professions are self-reported; out-of-raid / non-addon users show cached or none.
- **DL-5 (open, content task):** static datasets must be maintained each phase; consider a build-time import from a community dataset instead of hand-editing.
- **DL-6 (closed, Phase 7):** ML disconnect mid-session recovery is defined. The ML heartbeats `sPing` (~30s) while a session is open; a candidate that hears nothing for 95s closes the stale view (no one is stuck). The open ML session and any owed trades are mirrored to `global.session`/`global.pendingTrades` (owner-keyed, local) and restored on login — the ML is offered `/lcex resume` (re-broadcasts `sStart` with the same sid) or `/lcex end` to discard.
- **DL-7 (accepted v1):** loot flow is auto-loot-to-ML-bags + later sessions + handoff by **trade** within the BoP 2h window. This supersedes the original master-loot-from-corpse assumption; `GetMasterLootCandidate`/`GiveMasterLoot` are not used.
- **DL-8 (open, Phase 3):** response buttons are user-configurable (add/remove/rename); only the DEFAULT set (BiS/Major/Minor/Greed + built-in Pass) exists until the settings UI lands. The set used in a session will need to be consistent across participants (likely carried in `sStart` or a synced config).
- **DL-9 (done, Phase 7):** the 2h trade window prefers the looted-at `time()` anchor; for items already in bags before login it now reads the *real* remaining time by scanning the item tooltip for the localized `BIND_TRADE_TIME_REMAINING` line (RCLC's technique — `GetContainerItemTradeTimeRemaining` is RCLC's own method, not a Blizzard global) and sets `expireAt = now + remaining`. The scan is guarded: if the string/line is absent it falls back to the prior "no timer" behavior, so it only ever adds a countdown.
- **DL-10 (Phase 4, partially mitigated):** the §6.2 `{n, maxMod}` digest + delta can miss records. *Implemented* (`council/Sync.lua`): pull is **directional** — request only when the peer's `maxMod` or `n` exceeds ours (a higher count → full pull, `since=0`); a peer that's *ahead* **hellos back** (WHISPER) so a freshly-logged-in client is reached by those already online. *Remaining gap:* two peers with the **same count and same `maxMod` but disjoint keys** (e.g. each wrote one record in the same second while apart) can't be told apart by this digest. Acceptable for v1 (rare, second-granularity); closing it needs a content-hash digest or a periodic `since=0` resync.
- **DL-12 (accepted, 2026-07-03 — the four-frame UI):** the UI is four holistic windows —
  **poll** (raider response cards: class-usability filtered via token lines + a TBC proficiency
  matrix, max 3 visible, queue advances into the top slot, per-card notes, optional response
  deadline carried in `sStart` as a duration), **loot** (two-pane in-raid interface: staging-only
  editable item list that freezes at Start — the `uid = sid:index` invariant holds by
  construction; candidate table + votes + award per item), **council** (resizable left-rail
  dashboard over a module registry: Browser / Players / History / Session Config, expandable),
  and **config** (schema-driven user settings). Style: flat-dark gradient surfaces, gold accent
  (patterned on iddqd/Cell, TBC-safe per Gargul). Minimap: LDB + LibDBIcon, left=loot,
  right=council, ctrl=config. **Mid-session item mutation was explicitly rejected** (staging
  only): every wire/index contract predating the redesign is unchanged. Reopening the poll
  (`/lcex respond`) intentionally shows ALL items again — re-clicking is the DL-3 re-respond
  mechanism.
- **DL-11 (accepted, Phase 3):** Plane-A session authority is bound to the **`sStart` sender**, per `sid` — candidates/council record the ML as whoever opened the session and accept subsequent `cUpdate`/`sEnd`/`award` only from that same sender carrying that `sid`. The WoW master-looter API is **not** the authority source: under DL-7 the group need not be using master loot during a council session, so `GetRaidRosterInfo`-derived ML (RCLC's model) doesn't apply here. The trusted guild model (§2) makes initial trust of the `sStart` sender acceptable for v1; `sid` stays an identifier, not a credential. On the ML's own client the session ML is simply whoever runs `/lcex start` (it broadcasts `sStart`); `PlayerIsML` governs only passive loot-tracking, a separate concern.
- **DL-13 (accepted, 2026-07-04 — Feature G gear issues):** enchant/gem issue detection is **viewer-side** over the links already in `gearCache` + `GetItemStats` sockets — **no comms/protocol change**. The one exception: if `GetItemStats` sockets prove unreliable on Anniversary (verify via selftest, X3), a reporter-side socket count is added to `pReport`/`gearCache`. Rules ship as **static `Data/GearRules.lua`** (CLA-derived: per-slot enchant **allowlist** that fails safe on unknown enchants, gem-min-quality = rare, excluded-gear whitelist), **not** guild-editable in v1. The boss-conditional "useless item" (undead/demon/PvP/engi) + meta-gem-activation checks, and true socket-color matching, are **deferred to a fast-follow**. Model: `docs/CLA_gear_issues_findings.md`; canonical spec §6.8.

---

## 9. Glossary
- **ML** — master looter; the loot authority for a session (Plane A).
- **Candidate** — a raid member eligible for / responding to an item.
- **Council** — members who vote (Plane A) and own the shared notes/marks (Plane B).
- **Session** — one open loot-voting cycle, identified by `sid`.
- **Mark** — a persistent council note attached to an item ("give next to X").
- **Plane A / B** — live ML-authoritative voting / persistent replicated council data.