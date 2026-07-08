# LootCouncil EX — Project Source of Truth

> This is the canonical project document. Read it first at the start of every Claude Code session and treat it as authoritative. It supersedes any earlier spec. Intended to live in the repo root as `PROJECT.md` (or `CLAUDE.md`).

---

## 1. Intent

LootCouncil EX is a loot council addon for **World of Warcraft: The Burning Crusade Classic (Anniversary realms)**. It replaces RCLootCouncil, whose Classic build is a patch layer bolted onto the retail core and is buggy and clunky as a result.

**North Star:** a fast, clean, TBC-native loot council tool that does the broadcast → respond → vote → award loop without friction, plus a persistent council toolkit (notes, marks, history, gear/profession lookup) that helps the council make decisions.

**Definition of done (v1):** a guild can run a full raid night on this addon — items get councilled and awarded correctly via master loot — and the council can keep synced notes and persistent gear marks across raid nights.

**Non-goals (do not build):** retail/Era/SoD support; DKP/EPGP/GP point systems; PUG support / non-installed-user (no-addon) whisper fallback (stub only); multiple simultaneous loot sessions; cross-guild council sync; auto-trade handoff polish. **Exception (Phase 13, DL-24):** raiders who run **RCLootCouncil Classic** are supported via a one-way interop bridge — the LCEX ML speaks RCLC's wire dialect so they can respond as candidates (§6.18). This is distinct from the no-addon whisper fallback, which stays out of scope.

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
- **Comms envelope:** every message is one AceSerializer-encoded table `{ v, cmd, sid, ver, ... }`. `v` = `PROTOCOL_VERSION`; drop messages with an unreadable higher major `v`. `cmd` routes through a dispatch table. `sid` identifies the session (nil for Plane B / roster messages). `ver` = the sender's human-facing addon version, stamped on **every** message so peers learn each other's version passively from any traffic (not just the vCheck handshake); the receiver records it **after** dispatch (intentional — so the vCheck handshake's own first-contact announce still fires; `Comms.OnCommReceived`).
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
│   ├── Guild.lua              # guild identity (guildKey via GetGuildInfo) + PresentRoster helper — foundations
│   ├── Access.lua             # Feature C: role + visibility predicates (AmCouncil / CanSee) — headless-tested
│   ├── Minimap.lua            # LDB launcher: left=loot, right=council, ctrl=config
│   ├── Display.lua            # pure display-array builders (headless-tested; UI renders them)
│   ├── Usable.lua             # poll class filter: token lines + TBC proficiency matrix
│   ├── GearIssues.lua         # Feature G: parse gear links → enchant/gem issue tags (pure, headless-tested)
│   ├── TradeTimers.lua        # Phase 12 (DL-22): bag-scan tradeable loot → the trade-timer data layer
│   ├── RCLCWire.lua           # Phase 13 (DL-24): pure RCLC dialect transforms + codec (headless-tested)
│   ├── RCLCBridge.lua         # Phase 13 (DL-24): RCLC interop comms glue (LCEX ML ↔ RCLC-only raiders)
│   ├── SelfTest.lua           # /lcex selftest — in-game validation harness
│   ├── session/               # PLANE A
│   │   ├── Session.lua        # ML state machine (authority); sStart carries the poll deadline
│   │   ├── Candidate.lua      # receive sStart → poll → send cResp (per-card note)
│   │   ├── Council.lua        # receive cUpdate → loot window → send vVote
│   │   ├── Readiness.lua      # Feature V: pure per-item award-readiness status (headless-tested)
│   │   └── Award.lua          # bags/loot detection; award = assist-trade (TRADE_SHOW fill + 2h timer)
│   ├── council/               # PLANE B
│   │   ├── Sync.lua           # GUILD sync engine (manifest, deltas, LWW merge)
│   │   ├── Notes.lua          # player notes dataset
│   │   ├── Marks.lua          # item/gear marks dataset
│   │   ├── History.lua        # award history (witnessed + synced)
│   │   ├── SelfReport.lua     # broadcast own gear/profs; cache others'
│   │   ├── Config.lua         # shared officer config dataset (guildKey-keyed, LWW) — foundations
│   │   └── Gbank.lua          # Feature B: guild-bank scan/cache + append-only ledger (Plane B, guild-scoped)
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
    ├── MiniFrame.lua          # minimized-session pill (Phase 12): surfaces a hidden active session
    ├── TradeTimerWindow.lua   # trade-timer bars window (Phase 12, DL-22; opt-in)
    ├── CouncilWindow.lua      # `council`: resizable dashboard shell + module registry
    ├── council/               # self-registering dashboard modules
    │   ├── BrowserModule.lua  # loot browser (quality colors, hierarchy, mark editor)
    │   ├── RosterModule.lua   # roster picker (renamed from Players) + Gear|History|Profs|BiS|Notes; gear-issue badges + Gear Check overview (Feature G)
    │   ├── HistoryModule.lua  # guild-wide award log
    │   ├── SessionConfigModule.lua # officer: council roster, poll deadline, response-set editor (DL-8)
    │   └── GbankModule.lua    # Feature B: guild bank — hero gold card, tab selector, Contents/Log
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
| `sStart` | ML → raid | RAID | `{ items={[i]={link,quality}}, council={names}, responses, timeout, anon }` |
| `sEnd` | ML → raid | RAID | `{}` |
| `sPing` | ML → raid | RAID | `{}` (liveness heartbeat, ~30s while open; sid on the envelope — DL-6) |
| `cResp` | candidate → ML | WHISPER | `{ item, resp, note, gear={link,link} }` (no `ilvl` — `GetAverageItemLevel` is unreliable in Classic, §6.7, so the ML shows competing-slot gear instead) |
| `cUpdate` | ML → raid | RAID | `{ item, rows={[name]={resp,reason,note,gear,votes,class}}, status={kind,voted} }` |
| `vVote` | council → ML | WHISPER | `{ item, candidate, vote=±1|0 }` |
| `award` | ML → raid | RAID | `{ item, itemID, itemIndex, winner, resp, respText, boss, instance, ts }` (`respText` = the resolved reason text, DL-8 §6.5 — additive; old clients ignore it and fall back to `ResponseText(resp)`) |
| `unaward` | ML → raid | RAID | `{ item, itemID, itemIndex, winner, ts }` (award correction, §6.15) |
| `sReq` | candidate → ML | WHISPER | `{}` (rejoin request after hearing an unknown-sid `sPing`, §6.16) |
| `sJoin` | ML → candidate | WHISPER | `{ items, council, responses, timeout, anon, awarded }` (rejoin reply; followed by per-leader whispered `cUpdate`s) |

Reliability: ML holds the authoritative table; drop inbound `cResp`/`vVote` with a stale `sid` or non-member/non-council sender. Debounce `cUpdate` (~0.2s). Idempotent — re-sends overwrite last value. No ACK in v1. `award` carries enough to build a complete local history record on every present client. `unaward`/`sJoin` are honored only from the bound session ML (DL-11); `sReq` is throttled per sid (60s) and only sent when no session view is active.

Notes: items live in the ML's bags (no loot slot), so `sStart` items carry only `{link,quality}` — the ML resolves the live `{bag,slot}` locally at trade time. Until Phase-3 voting exists, `award.resp` carries the `STATUS.ANNOUNCED` sentinel; a disenchant award carries `award.resp = STATUS.DISENCHANT` (§6.10).

### 6.2 Plane B messages
Channel GUILD; only council members participate.

| cmd | Direction | Channel | Payload |
|---|---|---|---|
| `pReport` | any group member → GUILD | GUILD | `{ gear={slot→link}, profs={name→level}, class, spec, mod }` |
| `pSet` | council → GUILD | GUILD | `{ dataset="notes"|"marks", key, record={text,mod,by} }` |
| `pHello` | council → GUILD | GUILD | `{ digest={ <dataset>={n,maxMod,h}, ... } }` — every dataset digests **uniformly** as `{n, maxMod, h}` (history included: it flipped from union to LWW-by-`mod` in DL-20, so it carries `maxMod` like the rest). `h` = an order-independent content hash (DL-10) that catches same-count/same-maxMod divergence; old clients omit it |
| `pSyncReq` | council → peer | WHISPER | `{ dataset, since=<mod|0> }` |
| `pSyncData` | council → peer | WHISPER | `{ dataset, records={key→record} }` |

Sync flow: on login/load broadcast `pHello`; a peer that's behind sends `pSyncReq(since=myMaxMod)`; peer replies `pSyncData` with the delta. Live edits propagate via `pSet`. Accept `pReport` from any group member (so any raider's gear/profs can be viewed); gate `pSet`/`pHello`/`pSync*` to council senders only.

### 6.3 Datasets (Plane B — under `global.guilds[guildKey]` per Feature C / §6.11)
- `notes`: name → `{text, mod, by}`
- `marks`: itemID → `{text, mod, by}`
- `history`: uid → `{player, itemID, itemLink, ts, resp, respText, boss, instance}` (**LWW by `mod` per uid** — changed from union by Phase 12 / DL-20 so awards can be corrected). `respText` (DL-8) is the **resolved reason text** captured at award time, so the reason renders correctly even after the guild later changes its response set; readers prefer `respText or ResponseText(resp)`. uid = `sid..":"..itemIndex` (so `award` carries `itemIndex`). Records also carry `by` (the logging ML) + `mod`=ts. A correction *appends in time*: a retraction re-writes the same uid with `retracted=true, retractedBy` and a fresh `mod`; a re-award re-writes it again with the new winner and a newer `mod` — the latest fact wins on merge, and records are never deleted (§6.15). Logged locally on every present client from the `award` broadcast (§6.1); replayed award logs are idempotent (equal `mod`+`by` → merge no-op).
- `gearCache`: name → `{items={slot→link}, class, spec, mod}` (self-reported; `class`/`spec` let the BiS tab auto-resolve a cached player — talent-derived spec, §6.7). The reporter **loopback-writes its own** record locally (not just broadcasts), so a solo addon user's same-guild alts share gear/spec account-wide without a second client (§6.2).
- `profCache`: name → `{profs={name→level}, mod}` (self-reported; same self-loopback)
- gbank sets (Feature B, §6.12): `gbankCache` (LWW), `gbankLog` (immutable, union), `gbankNotes` (LWW)

### 6.4 SavedVariables
```lua
LootCouncilEXDB = {
  profile = {
    council            = { byRank=true, rank=1, extra={} },  -- pre-config LOCAL default only; the live roster moves to shared config (§6.9, DL-16 resolves DL-1)
    syncChannel        = "GUILD",
    minQuality         = 4,
    selfReport         = true,
    tradeTimersAuto    = false,         -- opt-in trade-timer window when tradeable loot exists (§6.17)
    tradeTimersMaxRows = 10,            -- expanded trade-timer rows; 0 = all (§6.17)
    appearance         = { scale=1.0, opacity=1.0, bgOpacity=1.0 },  -- scale=every window; opacity=whole-window (council); bgOpacity=backdrop-only alpha for the loot session + loot drop windows (text/buttons stay crisp)
    ui                 = { loot={pos,w,h}, poll={pos,w}, council={pos,w,h}, config={pos},
                           mini={pos}, tradeTimers={pos,w} },  -- w/h persisted for resizable windows (loot/council=2D, poll/tradeTimers=width-only)
    useWhisperFallback = false,
  },
  global = {
    dbVersion = <int>,                  -- schema version; MigrateDB stamps/upgrades on load (Phase 7)
    -- Plane B, PER GUILD (Feature C / C6 / DL-16). ACTIVE-FLAT + STASH (shipped model): the
    -- CURRENTLY-ACTIVE guild's datasets live in FLAT top-level tables (below) so all ~25 readers
    -- stay unchanged; only NON-active guilds are stashed under guilds[key]. Switching guild swaps
    -- the flat tables with the stash (hide-on-leave). `activeGuild` nil ⇒ a one-time in-place
    -- claim of the existing flat data (no migration, nothing vanishes).
    activeGuild   = <guildKey|nil>,
    config={}, notes={}, marks={}, history={}, gearCache={}, profCache={},   -- ACTIVE guild (flat)
    gbankCache={}, gbankLog={}, gbankNotes={},                               -- ACTIVE guild gbank (Feature B / §6.12)
    guilds = {                          -- NON-active guilds only (stash); same per-guild shape as the flat tables
      [guildKey] = { config={}, notes={}, marks={}, history={}, gearCache={}, profCache={},
                     gbankCache={}, gbankLog={}, gbankNotes={} },
    },
    -- Local (NOT synced) owner-keyed recovery stores so a /reload can't lose ML state (DL-6):
    pendingTrades = { [owner] = { [shortKey] = {owed records} } },  -- owed loot still to be traded out
    session       = { [owner] = {sid, items, council, sessionItems, startedAt,
                                 rows, voters, awarded, anon, savedAt} },  -- the open ML session (Phase 12 / §6.16:
                                 -- rows/voters/awarded are LIVE REFERENCES to the in-memory tables, so every
                                 -- response/vote/award is durable at the next SavedVariables write — DL-21)
  },
}
```

### 6.5 Response enum (configurable — DL-8)
```lua
RESPONSES = {  -- BUILT-IN DEFAULTS (Const.lua); a guild may override via config.responses (DL-8)
  [1]={id=1,key="BIS",  text="BiS",   color={0.96,0.55,0.73}},
  [2]={id=2,key="MAJOR",text="Major", color={0.20,1.00,0.20}},
  [3]={id=3,key="MINOR",text="Minor", color={1.00,0.96,0.41}},
  [4]={id=4,key="GREED",text="Greed", color={0.70,0.70,0.70}},
  [5]={id=5,key="PASS", text="Pass",  color={0.60,0.20,0.20}},  -- built-in: always present + last
}
STATUS = { ANNOUNCED=90, TIMEOUT=91, NOADDON=92, DISENCHANT=93 }
MAX_RESPONSES = 8    -- editor cap; keeps ids well clear of the STATUS floor (90)
```
`PASS` is a built-in response (a candidate must always be able to decline; timeouts resolve to a non-response). The rest are **defaults a guild may reconfigure** (DL-8, Phase 14).

**Configurable set (DL-8).** The live set is `LCEX:ResponseSet()`. When a guild has authored `config.responses` (§6.9), `ResponseSet()` **derives** the runtime set from it through a pure normalizer; otherwise it returns the built-in `RESPONSES` verbatim. The stored shape is minimal — an array of `{ text, pass=true|nil }` — and ids/keys/colors are computed at read time so the invariants hold **by construction**:
- **Contiguous ids `1..N`** (array order = display order); `N ≤ MAX_RESPONSES`.
- **Exactly one `key=="PASS"` entry, pinned LAST** — the normalizer injects it if a stored record lacks it. `RCLC_BuildMLDB`/`numberedResponses`, `RCLC_MapResponse`, and `PassResponseId` all hard-depend on this, and the editor forbids removing/renaming/moving it.
- **Colors auto-assigned** from `RESPONSE_PALETTE` (Const.lua) by index — the editor is add/remove/rename/reorder only in v1 (no per-button color/whisper-key/require-note; those stay out of scope, §1).
- A corrupt/garbage stored record makes the normalizer **fall back to the built-ins** (never nil, never a crash).

The set is carried in `sStart`/`sJoin` and **snapshotted per session** (§6.16), so a mid-session config edit never swaps a live session's buttons; the RCLC MLdb rebuilds from the session's snapshot. History records store the **resolved reason text** (`respText`, §6.1) so an award's reason still renders after the guild later changes its set.

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
- **Guild bank (Feature B — all net-new, verify each):** contents/logs readable **only while the frame is open**. `GetNumGuildBankTabs`, `GetGuildBankTabInfo(tab)`, `QueryGuildBankTab(tab)` (throttled — one per round-trip, answered by `GUILDBANKBAGSLOTS_CHANGED`), `GetGuildBankItemLink(tab,slot)`/`GetGuildBankItemInfo(tab,slot)`, `GetGuildBankMoney`. Logs: `GetNumGuildBankTransactions(tab)`/`GetGuildBankTransaction(tab,i)` (+ money log) report **elapsed** time, not absolute. Events: `GUILDBANKFRAME_OPENED`/`_CLOSED`, `GUILDBANKBAGSLOTS_CHANGED`, `GUILDBANK_UPDATE_MONEY`.

### 6.8 Gear-issue detection (Feature G)
Adopts the CLA "gear issues" model (`docs/CLA_gear_issues_findings.md`) as a **viewer-side** analysis over the gear links already in `gearCache` (§6.3) — **no comms or protocol change** (DL-13). Rules ship as static data (`Data/GearRules.lua`); `Core/GearIssues.lua` is the pure, headless-tested evaluator; results surface in the Roster → Gear sub-tab (per-item tags) and a **Gear Check** overview *within* the Roster tab (the Players module renamed to **Roster** — everyone + issue counts, the pre-raid slacker scan). **Display-only in v1** (no auto-whisper). v1 ships the **core three** checks (enchant / empty-socket / gem-quality); boss-conditional + meta-gem are deferred (see below).

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

**Display.** Per-item tags render in Roster → Gear (danger tone = missing, warning tone = suboptimal). The **Gear Check** view (within the Roster tab) lists every present/cached player with an issue count and badges the roster picker per player; empty = "no issues". Own character evaluates live equipped gear; others evaluate from `gearCache` with the existing "cached Nm ago" freshness. Names come from `enchantLabel` (enchants) / `GetItemInfo` (gems) — arbitrary good-enchant names via tooltip scan are deferred.

### 6.9 Guild identity + shared config (foundations for Features V / C / B)
Features V, C, and B need a **guild-scoped, officer-authored config** shared across the council. Two new primitives:

**Guild identity — `Core/Guild.lua`.** `LCEX:GuildKey()` = the current guild's identity from `GetGuildInfo("player")` (guild **NAME only, NOT realm-qualified** — realm-qualifying would split the key across connected realms and break replication between guildmates on different home realms; **verify the API on the live client, X3**), recomputed on `PLAYER_GUILD_UPDATE`/`GUILD_ROSTER_UPDATE` and cached; nil when guildless (config editing then falls to the C4 escape hatch). An officer in >1 guild defaults to the current character's guild (B2). Same file exposes `LCEX:PresentRoster()` → `{ {name, class}, ... }` for the current raid/party (lifting the `raid1..raidN` + `UnitName`/`UnitClass` loop from `Display.lua:106-111`) — used by Feature V's row seeding and the present-council tally.

**Shared config — `Core/council/Config.lua`**, a Plane-B **LWW dataset** (rides the §6.2 `RegisterDataset` / `pHello` / `pSync*` machinery) keyed by `guildKey`, **one officer-authored record per guild**, gated to council senders like `pSet`:
```lua
config[guildKey] = {
  rank          = 1,                 -- officer/council rank cutoff (moved here from profile.council → resolves DL-1)  [C, SHIPPED]
  extra         = {},                -- manual council adds                                                          [C, SHIPPED]
  responses     = { {text,pass}, ... },  -- the guild's response set (DL-8, Phase 14) — STORED minimal;                [C]
                                     --   ResponseSet() derives ids/keys/colors via the normalizer. Absent ⇒ built-ins.
  anonVoting    = false,             -- hide who-voted (V7)                                                          [V]
  disenchanters = { name, ... },     -- ordered; top = highest rank (V5)                                             [V]
  visibility    = { gbankLog=false, gbankNotes=false, lootWindow=false, ... },  -- per-guild view rules (B5, C7)     [C/B]
  mod, by,
}
```
Populated incrementally: **Feature V** writes/reads `anonVoting` + `disenchanters`; **Feature C** moved `rank`/`extra` here (resolving DL-1) and layered the inherit-on-first-load prompt (C1/C5); **Feature B** adds `visibility`; **Phase 14** adds `responses` (DL-8) — the guild's response set, stored minimally and normalized at read (§6.5). A client with no local `config[guildKey]` pulls it via the normal sync flow; C adds the "inherit `<Guild>` config from `<Player>`? Y/N" gate before adopting. Escape hatch (C4): editable when you're GM (rank 0), or no record exists yet, or you're solo/guildless. **Re-keying the *other* datasets (notes/marks/history/caches, and B's gbank) under `guildKey` + hide-on-leave is Feature C's job (C6)** — unreleased, so no migration.

### 6.10 Live-session readiness + roster rows (Feature V)
Reworks the live session so every present raider appears, plus an award-readiness border, a vote tally, anonymous voting, and a disenchant award type. Council-facing only (non-council see just the poll — C7).

**Roster rows (V1).** The row list is the **union (deduped by normalized name) of two sets** (R1): (1) the **kill set** — the raid roster snapshotted at *loot time* onto each captured item (attach in `OnChatMsgLoot`, `Award.lua:177-189`, carried through `BuildCouncilableList` → `sessionItems`/staging beside `boss/instance/lootedAt`; manual-adds fall back to the `StartSession` roster) — the practical proxy for "present at the kill" (no kill event; DL-7 auto-loot); and (2) the **current raid** at vote time (`PresentRoster()`), so latecomers who missed the kill still appear. "More data is better." Per-item **eligible** = in the kill set AND `ClassCanUse(link, class)`. `session.rows[i]` is **pre-seeded** at `StartSession` from the union (no longer starts empty):
```lua
rows[i][name] = { name, class, resp, reason, votes=0, note, gear }
-- reason (non-responders):  "pending"    eligible, no response yet    → MIGHT ROLL
--                           "cantuse"    in kill set, unusable        → Ineligible (can't use)
--                           "missedkill" in current raid, not @ kill  → Ineligible (missed kill)
--                           "left"       was @ kill, no longer present
```
An incoming `cResp` merges into the seeded row via the existing `prev = rows[key]` path (`Session.lua:314`), setting `resp` and clearing `reason` — **the seed's `class`/`reason` must survive the overwrite** (`Session.lua:315-321` preserves only `votes` today). **Accumulate/union over the session (R5):** a row is **never dropped**; on leave/rejoin its `reason` re-marks **subtly**.

**Eligibility is a soft, fail-open gate (R2).** Ineligible rows (`cantuse` / `missedkill`) are flagged and are not a default/auto award target, but **the ML can always override and award anyone** — a bugged or stale snapshot must **never block a legitimate award**. The gate warns; it does not prevent. (A real `ENCOUNTER_END`/`UNIT_DIED` kill hook to tighten the kill set is a possible later refinement — DL-15.)

**Display (V1).** Three tiers — **ROLLED > MIGHT ROLL > NOT ROLLING** (R3): rollers (non-PASS responses) on top, sorted by response/votes; **might-roll** (`pending`) directly below them; then **not-rolling** (passed + `cantuse` + `missedkill` + `left`) at the bottom, dimmed (RCLC). The two ineligible reasons share one dimmed style, labeled distinctly — "Ineligible (missed kill)" / "Ineligible (can't use)". The item rail orders **chronologically, oldest loot first** (`lootedAt`; manual-adds last).

**Readiness border (V3/V4).** The **ML computes a per-item `status` and broadcasts it** (new `cUpdate.status`) so every client draws the same **rail-row** border (header icon unchanged — V4), applied receiver-side like `awarded` (the `award`-flow template) and painted in `FillLootRailRow` (`LootWindow.lua:208-243`). Present-eligible = the eligible rows (in the kill set, can use it, still present — the `pending` + rolled rows; excludes `cantuse`/`missedkill`/`left`, R4); "wants it" = a non-PASS response; "voted" = ≥1 non-zero vote (no abstain — V2):

| status.kind | color | condition |
|---|---|---|
| `awarded` | dark green | `awarded[i]` set |
| `de` | blue | nobody wants it **and** all present-eligible have responded → ready to disenchant |
| `ready` | light green | someone wants it **and** (all present council have voted **or** all responded with exactly one roller) |
| `voting` | gold | someone wants it, all present-eligible responded, not yet `ready` |
| `waiting` | grey | otherwise (responses still outstanding) |

Precedence `awarded > ready > de > voting > waiting` (Vd3); `ready`/`de` are mutually exclusive by construction. `Core/session/Readiness.lua` is the pure, headless-tested calculator. New theme colors: dark-green, light-green, status-blue, neutral-grey (gold = `accent`) in `Theme.lua` (Vd2).

**Vote tally (V6).** `status.voted = { n, of }` — `of` = present-council count, `n` = how many have voted on this item — renders "X / Y voted" in the loot window (existing text tones). Unless anonymous, `status` also carries voter names for a who-voted list. RCLC-like.

**Anonymous voting (V7).** `config.anonVoting` is snapshotted into the session and carried on `sStart` (`anon`) so all clients agree for the session's lifetime; when on, the ML omits voter names from `cUpdate` (the count still shows). Default off (Vd6).

**Disenchant award type (V5).** New `STATUS.DISENCHANT = 93` (§6.5). A **D/E button** per item (ML) picks the highest-ranked `config.disenchanters` entry who is **present and eligible to receive**, confirms "Send to `<name>` for d/e?" → on Yes, `AwardItem(i, name)` with `resp = STATUS.DISENCHANT`. Award messaging becomes "`<item>` was awarded to `<player>` for `<reason>`" (reason = the winner's response text, or **D/E**). Falls back to a manual target pick if no disenchanter is set/present (Vd7).

### 6.11 Council access control + guild scoping (Feature C)
Builds on the shared config (§6.9). Three parts:

**Council sourced from shared config (C1/C2 — resolves DL-1).** `ResolveCouncil` (`Session.lua:35-54`) reads `config.rank`/`config.extra` (the per-guild shared record) instead of `profile.council` — the roster is now **officer-authored and replicated**, so every client resolves the same council. "Officer rank" = that `rank` cutoff; `AmCouncil()`/`IsCouncil()` stay the same predicates over the resolved set (C2). `profile.council` is kept only as the pre-config local default (escape hatch).

**Gating — `Core/Access.lua`** (role + visibility predicates, headless-tested; reads `AmCouncil()` + `config.visibility`):
- **Officer settings (C3):** the Session Config module is added to the council rail only when `AmCouncil()` (the `CouncilWindow.lua` module loop) — hidden from non-council. Personal settings (`ConfigWindow`) stay visible to everyone (Cd2).
- **Loot/voting window (C7 — superseded by Phase 12 / DL-18, §6.13):** every raider may now OPEN the loot window; what they see is tiered. Non-council (non-opted-in) get the **list view** — the left item rail only (items, quantities, award state, winners), never responses/votes/notes. `config.visibility.lootWindow` is repurposed: the opt-in now grants non-council the **full** (read-only) view rather than any view at all. Council always full; award/end/D-E controls stay ML-only.
- **Greyed controls (Cd3) — SHIPPED v0.57.1:** a `SetFlatEnabled(false)` disabled state on `CreateCheckbox` (Disable + faint label + grey tick + click guard) and `CreateSliderV2` (`EnableMouse(false)` + faint label/value + grey thumb), mirroring the flat-button helper. Value still Refreshes while disabled; selftest group `widgets` covers the state round-trip.

**Guild scoping + hide-on-leave (C6).** Every replicated dataset (`config` from Phase 9, plus `notes`/`marks`/`history`/`gearCache`/`profCache`/`dummy`, and Feature B's gbank sets) is guild-scoped so leaving a guild hides its data. Rather than re-home the ~25 readers, an **active-flat + stash** model is used (`Core/Guild.lua` `SyncGuildScope`): the **active guild's data always lives in the flat `db.global.<name>` tables** (every existing reader is unchanged), while **other guilds' data is stashed under `db.global.guilds[guildKey][name]`**. Switching guild (or leaving → key change) stashes the outgoing guild's flat tables and loads the incoming guild's (empty if new), so **an old guild's records are simply not present in the flat tables** — hidden without deletion; rejoining restores them. `db.global.activeGuild` tracks which guild the flat tables hold; **nil ⇒ never scoped**, which triggers a one-time *in-place claim* (existing pre-scoping data becomes the current guild's — nothing is moved or lost, so **no migration is needed**). `SyncGuildScope` runs at `OnEnable`, on `GUILD_ROSTER_UPDATE`, and defensively in `BuildDigest`, and **defers while guilded-but-roster-not-loaded** (`IsInGuild()` true, `GuildKey()` nil) so data is never stranded under `_local`. The sync/council gate is already per-`guildKey` (a peer in another guild fails `SyncSenderOk`). Local owner-keyed recovery stores (`pendingTrades`/`session`) stay account-global (live ML state, not council data).

**Inherit on first load (C1/C5, escape hatch C4).** On login with no authored local `config` for the current `guildKey`, an incoming peer config (over `pSet`/`pSyncData`) is **not auto-merged** — `GateConfigInherit` (Config.lua) holds it as `_pendingInherit` and a themed `ShowConfirm` asks **"Inherit `<Guild>` loot-council settings from `<Player>`? Y/N"** (`<Player>` = the sending officer). **Yes** (`AcceptInherit`) applies the held record verbatim (keeping its `mod`/`by` so LWW stays consistent); **No / dismiss** (`DeclineInherit`) keeps local defaults and **stops asking this session** (a fresh guild resets the decision, cleared in `SyncGuildScope`). The gate short-circuits (auto-merge, no prompt) under the **escape hatch (C4)** — **GM (rank 0)**, **solo/guildless**, or a config already authored — and only prospective council members reach it at all (`syncGateBad` drops sync for non-council).

### 6.12 Guild Bank (Feature B)
A new council module (`UI/council/GbankModule.lua`, key `gbank`, order 50) over a Plane-B scanner/cache (`Core/council/Gbank.lua`). All data is **guild-scoped** (`db.global.guilds[guildKey]`, §6.11) and replicated. **Every guild-bank API is net-new — verify on the live client (X3, §6.7).**

**Scan on open (B6).** On `GUILDBANKFRAME_OPENED`, auto-query **every viewable tab** in sequence (`QueryGuildBankTab` is throttled — one per round-trip, answered by `GUILDBANKBAGSLOTS_CHANGED`; space with AceTimer). Cache per tab: name/icon (`GetGuildBankTabInfo`) + each slot's `{link, count}` (`GetGuildBankItemLink`/`GetGuildBankItemInfo`); cache gold (`GetGuildBankMoney`) and tab count. Un-scanned tabs render "not cached" (Bd5). Everything outside an open frame renders from cache.

**Append-only ledger (B3).** Transaction logs are ephemeral, indexed, ID-less, and report **elapsed** time (`GetGuildBankTransaction` → type/name/itemLink/count/tabs + years/months/days/hours-ago; money via `GetGuildBankMoneyTransaction`). On each open: read the logs, convert **elapsed → absolute** (`capturedAt − elapsed`), synthesize a **content-hash uid** (`type+name+itemLink+count+tabs+absoluteHour`), and **append new uids to a union ledger**, deduping against stored entries. *Limitation:* elapsed time is hour-granular, so two identical transactions by the same player in the same hour collapse to one uid — an API constraint, accepted.

**Grouping (B4).** For display, consecutive ledger entries by the **same player + same action** within **5 minutes** collapse into one group: identical items show one icon + **"xN"** (a new count overlay on `CreateItemIcon`, Bd4), distinct items sit side by side under a header summary ("7 items / 187g"). A group's ID = its earliest entry's uid (stable for annotations).

**Annotations (B5/B7).** Council/officers attach a note to a **group** — a new **LWW dataset** keyed by the group's lead uid (`{text, mod, by}`), like `notes`/`marks`. v1 ships the annotation feature itself; the **auto close-prompt + chat reminder are deferred** (B7), as is the whole **withdrawal-request flow** (B5).

**Datasets (Plane B, guild-scoped):**
- `gbankCache`: `tab → {name, icon, slots={slot→{link,count}}, mod, by}` + a `"money"` key `{gold, mod, by}` (LWW — latest scan wins).
- `gbankLog`: `uid → {kind, player, itemLink, count, tabs, ts}` (immutable; **union** merge, like `history`).
- `gbankNotes`: `groupUid → {text, mod, by}` (LWW).

**Replication (B1).** All three ride the existing sync engine, guild-scoped. An officer's withdrawal enters their `gbankLog` on their next scan and propagates via `pSet`/`pSync` — "real-time" bounded by when the capturing officer's client syncs. **A chat print fires when a sync delivers a GOLD withdrawal (`gbankLog`) or a new annotation (`gbankNotes`)** — item withdrawals and deposits/moves/repairs stay silent, capped at 3 lines per sync (`Sync.lua announceGbankSync`).

**Visibility (B5).** `config.visibility` (§6.9) gates the sensitive views: **contents + gold visible to all guild members by default**; **logs / annotations hidden from non-council by default**, each toggle per guild.

**UI (B8 / Bd1-3 / Bd6).** A **hero gold card** on top (a `Surface("raised")` card with the cached total in coin icons, built inline in the poll-card style, with "cached Nm ago" freshness — Bd2/Bd3), a **tab selector** for the bank tabs, and **Contents** (item grid) / **Log** (grouped, annotatable, money+item unified, newest-first — Bd6) sub-tabs.

### 6.13 Loot-window visibility tiers, compact layout, mini pill (Phase 12, DL-18)
The loot window is decoupled from council membership: **anyone may open it; the view is tiered.**

**View levels.** `LCEX:LootViewLevel()` → `"full" | "list"`. In-session the level is snapshotted
onto the view at `EnterSession` (`viewLevel`, replacing `canSeeLoot`): **full** = council ∪
`config.visibility.lootWindow` opt-in; **list** = everyone else. Out of session the window is the
compact staging rail for everyone (each client sees only its own local staging list — harmless).
- **full** — both panes; votes still council-only, award/D-E/End still ML-only (unchanged gates).
- **list** ("spectator") — the left rail only, at compact width: item icons/names/quality,
  quantity (`xN`), readiness-border *kind*, award state + winner. The response-count badge is
  suppressed. Spectator clients **never store** responses/votes/notes: `ApplyCUpdate` at list
  level keeps only `status.kind` and never populates `voteRows` — privacy is enforced at the
  state layer, not just the paint layer (the wire itself stays raid-wide per DL-18).
- The bottom-bar button is contextual: ML = "End session", everyone else = "Leave session".
- Auto-open on `sStart` remains full-level-only; spectators open on demand (minimap / mini pill /
  `/lcex`). The poll flow is untouched at every level.

**Compact/full layout (item 4).** `ApplyLootLayout(f, mode)`: `COMPACT_W = 284` (rail + insets),
`FULL_W = 824`. Pre-session (and in-session spectators) the window is rail-only at compact width;
a session at full level expands to a **user-resizable** two-pane form (pane shown). Mode changes
pin TOPLEFT (the PollWindow reflow pattern) so the rail never jumps; the staging-control band
(scan/add, 58px) is reclaimed by the list in-session.

**Resizable + backdrop opacity (pre-raid pass).** Full mode is 2D-resizable (`minW 700, minH
360`): the rail keeps its width, the pane and both scroll lists reflow off their anchors, and the
size persists in `profile.ui.loot.w/h`. Full mode restores the saved width (else `FULL_W`) and
shows the grip; compact hides the grip and forces the narrow width — an `f._suppressSizeSave` flag
(honored by `SavePlacement`) stops a compact-mode move from clobbering the saved session size. Both
the loot window and the loot-drop poll opt into `useBgOpacity`: `profile.appearance.bgOpacity`
drives a backdrop-only alpha (`LCEX:SetSurfaceAlpha`, Theme.lua) on the shell + region/card
surfaces so the panels can sit over the raid UI while text/buttons/icons stay crisp. The poll is
**width-only** resizable (height stays content-computed) so long item names get more room, and its
shell is **bare** (`CreateWindowV2 { bare }`): the window paints no surface/border and takes no
mouse — mid-fight it reads as a slim header strip + timer bar + floating item cards, clicks in the
margins fall through to the raid UI, and the "+N more" overflow line floats success-green with an
outline instead of sitting on a panel. The stack is tight: header/timer/cards sit flush with the
window rect (no side margins — INSET 0 + chromeInset 0) on a 4px vertical rhythm (8px between
cards), and the header tick, card icons, note boxes and "+N more" all sit on one column line.

**Mini session pill (item 5).** `UI/MiniFrame.lua`: a small draggable pill (min 220×26, **grows to
fit its text** up to 360 so the status never clips — a minimized frame isn't user-resizable; HIGH
strata, position → `profile.ui.mini`, NOT in `UISpecialFrames`) shown **iff a session view is
active and the loot window is hidden** — any view level. Text: full = "Loot session: N item(s) · R
response(s)"; list = "Loot session: N item(s) · A awarded". Click → `ShowLootWindow()`. With no
live session but a recoverable one (§6.16) it reads "Unresolved loot session — click to review" →
resume prompt. One verb `UpdateMiniFrame()` is called from Enter/LeaveSession, `RefreshLootItem`,
and the loot window's OnShow/OnHide. Window visibility never touches session state (DL-18).

### 6.14 Duplicate-item grouping (Phase 12, DL-19)
Duplicate drops (same item link) form a **group** with **shared responses** (RCLC-style):
raiders see ONE poll card per group and respond once; the council sees ONE candidate table; each
award still consumes a distinct **physical** item index, so `uid = sid:index`, per-copy trade
tracking, and history all keep their existing shape.

**Derivation (zero wire change).** `LCEX:BuildItemGroups(items)` — pure and deterministic over
the broadcast `sStart` items list (same `link` ⇒ same group; leader = lowest index) → returns
`{ leaderOf = {[i]=leader}, members = {[leader]={i,...}}, leaders = {asc} }`. Computed
independently on the ML (`StartSession`/`ResumeSession` → `session.groups`) and every client
(`EnterSession` → `activeSession.groups`); all agree because the input list is identical.

**Aggregation.** `session.rows`/`voters` (and `voteRows`/`voteStatus`/`cUpdate`) exist **only
under leader indices**. Inbound `cResp`/`vVote` map `msg.item` through `leaderOf` before
validation (identity mapping for non-duplicate sessions — behavior is unchanged when no dups
exist). `SeedSessionRows` seeds leaders only; a group's kill set = deduped union of every member
copy's captured roster. `ComputeItemStatus(leader)`: `awarded` only when **all** members are
awarded — a partially-awarded group keeps computing live status for the remaining copies.

**Award.** UI verbs call `AwardGroup(leader, name, forcedResp)` =
`AwardItem(NextAwardableIndex(leader), ...)` — leader first, then next unawarded member; nil ⇒
all copies awarded. The `award` broadcast and `/lcex award <n>` keep raw physical indices.
Un-award (§6.15) targets a specific physical copy, re-opening a mid-group hole that
`NextAwardableIndex` naturally re-offers.

**Display.** The rail shows one row per group: `xN` count overlay (hidden when N=1 — item 10),
badge `✓ Name` (fully awarded single) or `✓ a/N` (partial), and a hover tooltip enumerating
per-copy winners so diverged state is never hidden behind the `xN`. Selection and the right pane
operate on leader indices. Poll cards carry the `xN` overlay too.

**Trade-fill hardening.** Two same-link copies owed to one partner must both fill:
`FillOwedTrades` counts placed-vs-needed per link (not a boolean has-item), and `FindItemInBags`
skips locked slots so the second copy resolves to the second physical stack.

### 6.15 Award correction — un-award + retractable history (Phase 12, DL-20)
The ML can **un-award** a copy (right-click the awarded rail/candidate row → per-copy
"Un-award <winner>" → confirm). `UnawardItem(physIdx)`: `ForgetAward(uid)` (drops the owed trade
if still pending), clears `awarded[physIdx]` locally, writes a **retracted history record**
(same uid, `retracted=true, retractedBy`, fresh `mod`), broadcasts `unaward` (§6.1), and
rebroadcasts the group's `cUpdate`. Receivers (bound-ML-gated, DL-11) clear their `awarded`
mirror and write the byte-identical record (`mod = msg.ts`) so every client converges; absent
council members converge via the normal Plane-B delta pull (the uid's `mod` grew).

The confirm wording is stateful: **pre-trade** = "return the item to the session"; **post-trade**
(no owed record found) = "correct the record only" — LCEX never implies an in-game trade was
reversed. Post-session record fixes: HistoryModule row right-click → "Retract record…", enabled
only when `IsSelf(rec.by)` (the ML who logged it), which `SetRecord`s a retracted copy over
pSet/pSync. Retracted records render faint + "(retracted)" wherever history renders and are
never deleted. History's merge is LWW-by-`mod` per uid (§6.3) — the enabling change.

### 6.16 Session persistence v2 + rejoin (Phase 12, DL-21)
**Persist-by-reference.** `SaveSession` mirrors the ML's live `rows`, `voters`, and the view's
`awarded` tables (plus `anon`, the session's `responses` snapshot, `savedAt`) into
`db.global.session[owner]` **as references** (the `sessionItems` trick), so every subsequent
mutation is durable at the next SavedVariables write — no debounced re-save plumbing.
`EnterSession` pre-creates `awarded = {}` for this. The `responses` snapshot (DL-8) means a resume
re-broadcasts the SAME response set the session started with, even if the guild config changed
during the reload.

**Resume.** On login with a saved session, a delayed (~3s) `ShowConfirm` reports age
(`RelTime(startedAt)`), item count, and responses collected; Accept = `ResumeSession` (the
explicit ML action that re-broadcasts `sStart` with the SAME sid); dismiss = chat hint
(`/lcex resume` / `/lcex end` / `/lcex abort` remain). If the confirm frame is busy (Feature C
inherit prompt), fall back to the chat prompt. `ResumeSession` restores `anon` from the save,
seeds rows fresh (late joiners appear), then **overlays** saved rows (saved
responses/notes/gear/votes win; seeded class/reason survive for non-responders; saved rows
missing from the seed re-enter as `left`), restores `voters` + `awarded`, and pushes one
debounced `cUpdate` per leader. **Out of group:** resume proceeds LOCALLY (no broadcast — safe
read-only recovery); the heartbeat self-arms on the next roster update that finds a channel.
Sessions are destroyed **only** by the explicit `EndSession` (`/lcex end`, `/lcex abort`, the
End button) — never by reload/DC/group-drop/window-close.

**Candidate rejoin (sReq/sJoin, §6.1).** A client with NO active session hearing `sPing` for an
unknown sid whispers `sReq` to the pinger (throttled 60s per sid). The ML validates (open
session, sid match, `InGroupWith`) and whispers back `sJoin` (items/council/responses/remaining
timeout/anon/awarded) followed by one whispered `cUpdate` per leader (AceComm preserves
per-target order). The candidate enters via the normal `EnterSession` (ML bound to sender,
DL-11); a same-sid duplicate `sJoin` merges `awarded` only; a client already viewing a
*different* live session ignores it. The reopened poll shows all items — the DL-3 re-respond
mechanism (the reloaded client's old responses live on in the ML's aggregate).

### 6.17 Trade timers (Phase 12, DL-22)
Gargul-pattern loot trade timers, rebuilt native (no LibCandyBar, no copied code).

**Scanner (`Core/TradeTimers.lua`).** `BAG_UPDATE_DELAYED` → 1s-debounced rescan; login/zone →
5s-delayed rescan (piggybacks the existing `OnEnterWorld`); a 60s safety tick while entries
exist. A rescan walks bags 0-4 and calls the DL-9 tooltip scanner (`ItemTradeTimeRemaining`) per
occupied slot; items with a running BoP trade window become entries `{key, link, itemID, quality, icon,
bag, slot, expireAt}` — **all tradeable loot**, not just owed trades. Keying: prefer
`C_Item.GetItemGUID` (pcall-guarded; availability on Anniversary is probed by selftest — X-item);
fallback = `itemID:bucket(expireAt,120s)` + collision ordinal, with `_ReconcileTradeEntries`
matching new scans to prior entries (by GUID, else itemID + |Δexpire| ≤ 180s) so keys stay stable
across rescans despite the tooltip's minute-granular drift. `_AnnotateTradeWinners` zips
`pendingTrades` owed records onto entries per link (both sides expiry-sorted) → "→ Winner".

**Window (`UI/TradeTimerWindow.lua`).** A compact 260-wide `CreateWindowV2` (savedKey
`tradeTimers`, scaled slightly smaller, semi-transparent, **width-resizable only**, **not**
ESC-closable, and **not closeable**) with a 25%-opacity shell/header/empty-track,
a subtle centered "Loot" title, 14px header/rows, and a smaller resize grip. Pooled native
`StatusBar` rows use a full-height icon,
rarity-colored bracketed item name (`[Item]`), optional "-> Winner", right-aligned countdown,
fill 0..7200 beginning at the icon's right edge and colored by absolute warning bucket —
`success` ≥60m remaining, `accent` ≥30m, `danger` below. Rows sort ascending by remaining;
height reflows from content only (TOPLEFT-pin). Expanded row count is configurable
(`profile.tradeTimersMaxRows`, default 10, 0 = all) with "+N more" when capped. Compact
title-bar **minimize** → exactly the soonest bar + "(+N)". `profile.tradeTimersAuto` is the
opt-in feature toggle (default off; ConfigWindow checkbox). When enabled and entries exist the
frame stays on-screen; when disabled or empty it hides. `/lcex timers` toggles the feature. 1s
repaint ticker while shown (display math off stored `expireAt` — no tooltip work). `/lcex
timertest` toggles one synthetic, in-memory Leggings of the Festering Swarm row so the frame can
be visually checked without a live BoP drop.

### 6.18 RCLC compatibility bridge (Phase 13, DL-24)

One-way interop so raiders who run **only RCLootCouncil Classic** (v1.4.x, the modern
LibDeflate dialect) can participate as **candidates** in an LCEX-run session. LCEX is always the
ML here; it never acts as an RCLC candidate. Scope: candidates only — RCLC council voting is out
of scope; RCLC users appear to LCEX as ordinary responders. Toggle `profile.rclcBridge`
(default **on**; ConfigWindow checkbox). Files: `Core/RCLCWire.lua` (pure transforms + codec),
`Core/RCLCBridge.lua` (comms glue). Vendored `Libs/LibDeflate`.

**Dialect (verified against the RCLootCouncil_Classic v1.4.1 reference).** AceComm prefix
`"RCLC"`; encode = `AceSerializer:Serialize(command, {args})` → `LibDeflate:CompressDeflate(_,
{level=3})` → `EncodeForWoWAddonChannel`; decode is the reverse → `(command, dataArray)`. LCEX
**never** touches the `"RCLCv"` version prefix (silence there = zero version popups on RCLC
clients).

**The authority constraint (vs DL-11).** RCLC candidates accept `lootTable`/`mldb`/`council`/
`session_end`/`awarded` only from the sender their `GetML()` computes — under master loot the
Blizzard ML, **else the raid/group leader**. Anniversary has no master-loot API, so **the LCEX
ML must be the raid leader** or RCLC clients silently drop everything. The bridge prints one
warning at session start when the toggle is on and the ML is not leader. (LCEX's own Plane A is
still `sStart`-sender-authoritative per DL-11; this constraint is RCLC's, imposed only on the
RCLC-facing traffic.)

**Outbound (ML → RCLC), group channel, in order at session start:** `StartHandleLoot {}` →
`mldb {tbl}` → `council {{[ourGuid]=true}}` → `lootTable {entries}`. Per award: `awarded
{session, winner, owner=ML}` (loot sits in ML bags per DL-7, so the ML is the item owner/trader).
At end: `session_end {}`. On demand: answer `MLdb_request`→mldb, `council_request`→council,
`reconnect`→ resend the whole start set. `mldb` **must precede** `lootTable` (candidates defer
the frame and spam `MLdb_request` otherwise). `mldb.buttons.default`/`responses.default` are
built by `ipairs` over the **live session response set** (`ResponseSet()`), so RCLC raiders see
LCEX's buttons and the mapping is 1:1 — when responses become user-configurable (DL-8) the bridge
inherits it for free. `mldb.timeout` = `pollTimeout` if set, else a large default (RCLC frames
always count down; a timed-out RCLC raider reads as a native non-responder). `lootTable` entries
= `{ string = <link minus "item:">, session = <LCEX item index>, boss, owner = ML }`.

**Inbound (RCLC → ML):** `response {session, {response=<btnIndex>|"PASS"|code, note, gear1,
gear2, ilvl, specID, roll}}` and `lootAck {specID, ilvl, sessionData}` (gear/presence/autopass).
Every inbound is gated on the toggle **and** an open local session **and** `InGroupWith(sender)`.
A translated response is injected through the **existing** `dispatch.cResp(self, {sid, item,
resp, note, gear}, senderName)` path — the exact entry point the ML already uses for its own poll
answer — so rows, cUpdate fan-out, readiness and awards behave natively. Button index →
`responses[idx].id`; `"PASS"`/autopass → the set's PASS id; other codes (`TIMEOUT`/`DISABLED`/…)
→ no row change. Competing-gear links come from the candidate's prior `lootAck` (cached per
session+player), attached to the injected `gear` field for the row's gear icons.

**Not bridged (v1):** un-award (RCLC has no message for it), mid-session item adds (LCEX freezes
the item list at start — no `lt_add`). Both-addon raiders get both popups; answers converge on
the same row key (last write wins). No ACK on our sends — RCLC's own `reconnect`/`MLdb_request`
retries heal a missed broadcast. No `PROTOCOL_VERSION` bump: the LCEX wire is unchanged; the RCLC
dialect rides a separate prefix.

---

## 7. Build map

Each phase has a hard scope and an exit criterion. Do not build ahead into a later phase. Phases 1–3 produce a working voting addon (the MVP); 4–7 add the council toolkit.

**Phase 1 — Skeleton + comms proof.** `Const`, `Init`, `Comms`, `Roster` + libs.
*Exit:* two clients in a raid, `/lcex` works, `vCheck` round-trips and each prints the other's name + version. No UI. No Lua errors on load.

**Phase 2 — Loot engine (headless).** `session/Session.lua` (state machine), `session/Award.lua` (bags/loot detection, session start, award = assist-trade). Items are sourced from the ML's bags (auto-looted during the raid), not a corpse.
*Exit:* the ML's looted epics are tracked → `/lcex start` broadcasts `sStart` → `/lcex award <n> <name>` records the winner + broadcasts `award` → opening a trade with the winner auto-fills the item (or prompts a manual drag) → the 2h trade timer warns before it lapses. Driven/verified through chat output, `/lcex test`, and a willing trade partner — no live boss required, still no real UI.

**Phase 3 — Session UI → MVP.** `UI/Widgets.lua` + the session frames (originally named `SessionFrame`/`LootFrame`/`VotingFrame` — **superseded by the DL-12 four-frame redesign**, which ships this functionality as `UI/PollWindow.lua` + `UI/LootWindow.lua`), wired via `session/Candidate.lua` + `session/Council.lua`.
*Exit:* full live loop between 2+ clients — item drops → candidates respond in a frame → council sees the table and votes → ML awards → item assigned. **This is a usable loot council addon.**

**Phase 4 — Sync engine proof.** `council/Sync.lua` (GUILD transport, `pHello` digest, `pSyncReq`/`pSyncData` deltas, LWW merge) + dataset scaffolding.
*Exit:* two council clients reconcile a *dummy* dataset across offline/online — write on A while B is offline, B catches up on login. Proven before any feature rides on it.

**Phase 5 — Council datasets.** `council/Notes.lua`, `Marks.lua`, `History.lua`, `SelfReport.lua`.
*Exit:* notes, marks, award history, and gear/profession self-reports all sync between council members; awards log automatically from `award`.

**Phase 6 — Viewers + data scaffolding.** `Data/*` (stub samples), a tabbed player-detail viewer and a phase/boss loot browser (originally `UI/PlayerDetail.lua` / `UI/LootBrowser.lua` — **superseded by the DL-12 redesign**, which ships them as the `UI/council/RosterModule.lua` and `UI/council/BrowserModule.lua` dashboard modules), tier-token reference.
*Exit:* clicking a player opens the detail panel (gear/history/professions/BiS/notes); loot browser renders by phase/boss with editable persistent marks.

**Phase 7 — Content + polish.** Populate real `Data/*` tables; edge cases (ML disconnect mid-session, stale-cache indicators, roster changes); deferred niceties.
*Exit:* production-ready for a full raid night across multiple weeks.

---

### Post-v1 feature suite (phases 8–11)
Phases 8–11 extend **past** the original v1 definition of done — the four features scoped in `todo.md` (probe-for-detail): gear issues, voting-readiness, council access control, guild bank. Specced incrementally; build order **8 → 9 → 10 → 11** (G → V → C → B) by dependency + risk. A small **shared-foundations** step (guild identity/`guildKey`, X4; shared-config, X5) leads **Phase 9** (Feature V is the first consumer of shared config) and is reused by Phases 10–11. *(Phases 9–11 are specced as each is reached; see `todo.md` for their locked decisions.)*

**Phase 8 — Gear issues (Feature G).** `Core/GearIssues.lua` (pure detection over `gearCache` links + `GetItemStats` sockets), `Data/GearRules.lua` (CLA-derived rule tables); **rename the Players module → Roster**, add per-item tags in Roster → Gear, gear-issue badges on the roster picker, and a **Gear Check** overview view within it. Core three checks only (enchant allowlist + empty socket + gem quality); viewer-side, no comms change (DL-13).
*Exit:* the Gear Check view lists every raider's enchant/gem problems pre-raid; a test character wearing a missing-enchant + empty-socket + green-gem item surfaces exactly `[no enchant]` `[no gem used]` `[bad gem]`; `/lcex selftest` covers the detection logic (headless, fixed links → expected tags) + the `GetItemStats` socket contract (in-game). Boss-conditional + meta-gem checks are explicitly out of this phase.

**Phase 9 — Foundations + voting readiness (Feature V).** *Foundations first:* `Core/Guild.lua` (`GuildKey` + `PresentRoster`), `Core/council/Config.lua` (shared officer-config LWW dataset, §6.9). *Then Feature V:* pre-seed `session.rows` from the present-at-loot roster with per-item eligibility; `Core/session/Readiness.lua` (pure status calc); rail-row readiness borders via a broadcast `cUpdate.status`; the "X/Y voted" tally; anonymous voting (snapshotted onto `sStart.anon`); the D/E award type (`STATUS.DISENCHANT`, target from `config.disenchanters`). New theme colors (Vd2).
*Exit:* in a 2+ client session every present raider shows a row (rollers on top; pass/can't-use/left dimmed at the bottom); the rail is oldest-loot-first; an item nobody wants borders **blue** and the D/E button trades it to the configured disenchanter ("awarded … for D/E"); an item where all present council voted borders **light-green**; the tally reads "X/Y voted"; toggling anonymous hides voter names but not the count; `config` replicates between two officers. `/lcex selftest` covers the readiness cascade (headless) + `GuildKey`/`PresentRoster`/`config` round-trip.

**Phase 10 — Council access control + guild scoping (Feature C).** `Core/Access.lua` (role/visibility predicates); source council from `config` (`ResolveCouncil`); hide the Session Config module + the loot window from non-council (`CouncilWindow`/`LootWindow`, greyed-control helper in `Widgets`); move all Plane-B datasets under `db.global.guilds[guildKey]` (`Sync.lua`/`Init.lua`); the inherit-on-first-load prompt + escape hatch.
*Exit:* a non-council raider sees the poll + award chat but neither the Session Config module nor the loot window (unless the guild opts in); two officers editing the roster/rank converge via shared config; a fresh install in an established guild is offered "inherit `<Guild>` config from `<Player>`? Y/N" and adopts on Yes; leaving the guild hides that guild's notes/marks/history/caches. `/lcex selftest` covers the access predicates (headless) + a guild-scoped dataset round-trip.

**Phase 11 — Guild Bank (Feature B).** `Core/council/Gbank.lua` (scan-on-open, append-only ledger, guild-scoped `gbankCache`/`gbankLog`/`gbankNotes`) + `UI/council/GbankModule.lua` (hero gold card, tab selector, Contents/Log sub-tabs, "xN" icon overlay). Council-only annotations; configurable visibility. Withdrawal-request flow + auto note-prompt deferred.
*Exit:* opening the guild bank caches all tabs + gold + logs; the module shows the hero gold total, per-tab contents, and a grouped newest-first log; an officer annotates a withdrawal group and a second officer sees both the note and the withdrawal replicate; non-council see contents+gold but not logs/annotations (unless the guild opts in). `/lcex selftest` covers the ledger dedup/grouping (headless) + the guild-bank API contract (in-game).

**Phase 12 — Fix/change batch (handoff jul4).** The 18-item UX/fix batch specced in
`docs/lcex_fix_change_handoff_jul4.md` (§6.13–6.17, DL-18..23): spectator list view + compact
layout + mini pill; vote-button order, awarded feedback, un-award + retractable history (LWW);
duplicate grouping with shared responses; session persistence v2 (rows/votes/awarded survive
`/reload`) + resume dialog + sReq/sJoin rejoin; Gargul-style trade-timer window; shared widget
fixes (scrollbar-inside-list, zebra striping, flat-button disable, context menu); browser
collapse/note-indicator/name-tooltips/right-click notes/(token) cleanup; rail widen + glyph fix.
*Exit:* the consolidated Phase 12 checklist in `docs/TESTING.md` passes a 2-client run — a
non-council raider sees the rail-only view while responding via the poll; two identical drops
run as one card / two awards; an un-award converges on both clients and in history; an ML
`/reload` mid-session resumes with responses/votes/awarded intact and a reloaded candidate
auto-rejoins on the next heartbeat; trade timers track a real BoP drop end-to-end.

**Phase 13 — RCLC compatibility bridge (§6.18, DL-24).** One-way interop: the LCEX ML speaks
RCLootCouncil Classic's wire dialect so RCLC-only raiders respond as candidates. Vendored
`Libs/LibDeflate`; `Core/RCLCWire.lua` (pure transforms + codec) + `Core/RCLCBridge.lua` (comms
glue); `profile.rclcBridge` toggle. *Scope:* candidates only, LCEX-ML direction only, RCLC
raiders see LCEX's buttons via MLdb. *Exit:* a 2-client run (`docs/TESTING.md`) with LCEX ML **as
raid leader** and a stock RCLootCouncil Classic v1.4.x client — the RCLC loot frame pops with
LCEX button texts, a response lands as a row in the LCEX table with gear icons, an award and
`/lcex end` close the RCLC frames, and a mid-session RCLC `/reload` recovers via `reconnect`.

### Post-v1 continued (phases 14+)

**Phase 14 — Configurable response buttons (DL-8).** `config.responses` in the shared config
(§6.9), a pure `NormalizeResponseSet` + a config-reading `ResponseSet()` (§6.5), the resolved
`respText` on `award`/history (§6.1/§6.3), the per-session snapshot (§6.16), and the
add/remove/rename/reorder editor in `SessionConfigModule` (replaces the DL-8 placeholder).
*Exit:* an officer edits the guild's response set, it replicates to a second officer, poll cards
and the loot window render the custom buttons, an RCLC raider gets them via MLdb, a session
already in flight keeps its original buttons, and a history record's reason still renders after
the set changes. Headless covers the normalizer invariants + snapshot; selftest validates the
live configured set is well-formed.

---

## 8. Decision log / open questions

- **DL-1 (RESOLVED, Phase 10 — Feature C):** the council roster is **one** list, now sourced from the officer-authored, replicated shared `config` (`byRank`/`rank`/`extra`), so every client resolves the same council (`CouncilConfig`/`SetCouncilConfig`; `ResolveCouncil` reads it). `profile.council` remains only as the pre-config local default + escape hatch (C4). No split between vote/sync membership — one roster for v1 as originally intended, just no longer per-client-local.
- **DL-2 (out of scope v1):** cross-guild council sync via custom channel — fragile; deferred.
- **DL-3 (accepted v1):** no ACK on Plane A; last-write-wins + re-click. Revisit only if delivery gaps appear in practice.
- **DL-4 (accepted, no alternative):** gear/professions are self-reported; out-of-raid / non-addon users show cached or none.
- **DL-5 (open, content task):** static datasets must be maintained each phase; consider a build-time import from a community dataset instead of hand-editing.
- **DL-6 (closed, Phase 7):** ML disconnect mid-session recovery is defined. The ML heartbeats `sPing` (~30s) while a session is open; a candidate that hears nothing for 95s closes the stale view (no one is stuck). The open ML session and any owed trades are mirrored to `global.session`/`global.pendingTrades` (owner-keyed, local) and restored on login — the ML is offered `/lcex resume` (re-broadcasts `sStart` with the same sid) or `/lcex end` to discard.
- **DL-7 (accepted v1):** loot flow is auto-loot-to-ML-bags + later sessions + handoff by **trade** within the BoP 2h window. This supersedes the original master-loot-from-corpse assumption; `GetMasterLootCandidate`/`GiveMasterLoot` are not used.
- **DL-8 (RESOLVED, Phase 14 — v0.59.x):** response buttons are user-configurable (add/remove/rename/reorder). The set lives in the replicated shared config as `config.responses` (§6.9), stored minimally as `{ {text, pass}, ... }` and **normalized at read** by `ResponseSet()` — ids contiguous `1..N`, exactly one `key=="PASS"` pinned last, colors auto-assigned from `RESPONSE_PALETTE`, capped at `MAX_RESPONSES` (8); a garbage record falls back to the built-in defaults (§6.5). **Consistency across participants:** the set is carried in `sStart`/`sJoin` and **snapshotted onto the session** at start (§6.16), so every candidate renders the ML's set and a mid-session config edit can't swap a live session's buttons; the RCLC MLdb rebuilds from that snapshot. **History longevity:** each award stores the resolved reason text (`respText`, §6.1/§6.3), so a record's reason renders correctly after the guild later changes its set. Editor v1 = add/remove/rename/reorder only (colors auto, PASS pinned/non-editable); per-button colors, whisper keys, and require-note are out of scope (§1).
- **DL-9 (done, Phase 7):** the 2h trade window prefers the looted-at `time()` anchor; for items already in bags before login it now reads the *real* remaining time by scanning the item tooltip for the localized `BIND_TRADE_TIME_REMAINING` line (RCLC's technique — `GetContainerItemTradeTimeRemaining` is RCLC's own method, not a Blizzard global) and sets `expireAt = now + remaining`. The scan is guarded: if the string/line is absent it falls back to the prior "no timer" behavior, so it only ever adds a countdown.
- **DL-10 (Phase 4, mitigated; RESOLVED v0.58.0):** the §6.2 digest + delta can miss records. *Directional pull* (`council/Sync.lua`): request only when the peer's `maxMod` or `n` exceeds ours (a higher count → full pull, `since=0`); a peer that's *ahead* **hellos back** (WHISPER) so a freshly-logged-in client is reached by those already online. **The disjoint-keys gap is now closed** (v0.58.0): the digest carries a third field `h`, an order-independent content hash (a commutative sum of per-record `pairHash(key, mod)` mod 2^31−1 — pure Lua 5.1, no bit ops). When two peers report the **same `n` and same `maxMod` but different `h`** (disjoint keys, e.g. each wrote a record while apart, or a stale LWW loss), **both** pull `since=0` and hello back, so each gets the other's keys and LWW converges. Old clients omit `h`; the compare nil-guards it, so a mixed fleet degrades to the prior behavior. No periodic resync needed — the hash fires on every login hello + `/lcex sync`.
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
- **DL-14 (accepted, 2026-07-04 — foundations: guild identity + shared config):** `Core/Guild.lua` derives a `guildKey` from `GetGuildInfo` (guild NAME only, not realm-qualified — see §6.9 for the connected-realm rationale; verify live, X3) plus a `PresentRoster` helper. `Core/council/Config.lua` is a Plane-B **LWW dataset keyed by `guildKey`** (one officer-authored record per guild) riding the existing sync engine — the home for the response set (resolves **DL-8**) and the council rank/extra roster (resolves **DL-1** once Feature C moves them in), plus anon/disenchanters/visibility. Re-keying the other datasets under `guildKey` + hide-on-leave is Feature C (C6); unreleased ⇒ no migration. §6.9.
- **DL-15 (accepted, 2026-07-04 — Feature V voting readiness):** `session.rows` is pre-seeded one row per present raider (`PresentRoster` + `ClassCanUse`); non-rollers dim to the bottom (RCLC); the rail sorts oldest-loot-first. The ML computes a per-item **status** (awarded/de/ready/voting/waiting) and broadcasts it on `cUpdate` so all clients draw the same **rail-row** border (header unchanged). Adds a vote tally (`status.voted={n,of}`), anonymous voting (snapshotted onto `sStart.anon`, default off), and a **D/E award type** (`STATUS.DISENCHANT=93`; target = highest-ranked present+eligible `config.disenchanters`; reason renders "D/E"). **Row-set (resolved 2026-07-04, R1–R5):** the list is the union (deduped) of the **kill set** (raid snapshotted at loot time — the proxy for the kill; manual-adds → `StartSession` roster) and the **current raid** (latecomers → `missedkill`); per-item eligible = in-kill-set ∧ `ClassCanUse`. Three display tiers **ROLLED > MIGHT ROLL (`pending`) > NOT ROLLING** (dimmed). Eligibility is a **soft, fail-open gate** — it flags/warns but the ML can always award anyone; a bad snapshot must never block a legitimate award. Accumulate/union over the session (never drop a row; re-mark leave/rejoin subtly). §6.10.
- **DL-16 (accepted, 2026-07-04 — Feature C access control + guild scoping):** the council roster moves from local `profile.council` into the shared `config` record (§6.9), officer-authored and replicated — **resolves DL-1** (one roster, now consistent guild-wide). `Core/Access.lua` gates the Session Config module and the loot window behind `AmCouncil()` + `config.visibility` (raiders see only the poll + award chat by default; per-guild opt-in). All Plane-B datasets are namespaced under `db.global.guilds[guildKey]`, so leaving a guild hides its data with no deletion (hide-on-leave, C6); local recovery stores stay account-global. First-load inherit prompt ("inherit `<Guild>` from `<Player>`? Y/N") with a GM / no-config / solo escape hatch (C4). Unreleased ⇒ no migration. §6.11.
- **DL-17 (accepted, 2026-07-04 — Feature B guild bank):** a new `gbank` council module over a Plane-B scanner (`Core/council/Gbank.lua`). Scan all viewable tabs on `GUILDBANKFRAME_OPENED` (throttled queries); cache contents+gold (LWW `gbankCache`) and an **append-only union ledger** (`gbankLog`) built by converting the logs' **elapsed** time to absolute + a content-hash uid (dedup is hour-granular — an API limitation, accepted). Rapid same-player+action entries **group** (5-min window, "xN" icon overlay); **council-only annotations** attach to a group (LWW `gbankNotes`). All guild-scoped (§6.11) + replicated (real-time bounded by the capturing officer's sync). `config.visibility` hides logs/annotations from non-council by default (contents+gold public). **Deferred:** withdrawal-request flow, auto close-prompt/chat reminder. *(Sync-notification chat prints for gold withdrawals + annotations — B1 — shipped v0.57.0.)* Guild-bank APIs verify on the live client (X3). §6.12.
- **DL-18 (accepted, 2026-07-04 — Phase 12 loot visibility tiers):** the loot window opens for
  everyone; the VIEW is tiered — non-council default = the left-rail **list view** (items,
  quantities, award state, winners; responses/votes/notes neither rendered **nor stored** —
  `ApplyCUpdate` strips at list level); council ∪ `config.visibility.lootWindow` opt-in = full
  view (opt-in REPURPOSED from "may open at all" — supersedes the C7 gate in DL-16); ML keeps the
  only award/end controls. The wire stays raid-wide (trusted guild, §2) — privacy is state/UI-side
  by explicit decision. Window visibility ≠ session state: close/ESC/minimize never end a session;
  a mini pill surfaces hidden active sessions. Spectators are never auto-opened into the window.
  §6.13.
- **DL-19 (accepted, 2026-07-04 — Phase 12 duplicate grouping):** duplicate drops group by item
  link with **shared responses** (one poll card, one candidate table per group) — RCLC-style.
  Grouping is derived client-side from the `sStart` items list (leader = lowest index): **zero
  wire change**, deterministic everywhere. Aggregation re-keys onto leader indices; awards stay
  per-PHYSICAL-index (`uid = sid:index` inviolate; per-copy trades/history unchanged);
  `AwardGroup` consumes the next unawarded copy. Partial groups stay visually distinguishable
  (`✓ a/N` + per-copy tooltip). §6.14.
- **DL-20 (accepted, 2026-07-04 — Phase 12 award correction):** history flips **union →
  LWW-by-`mod` per uid** (records already carry `mod`/`by`; zero data migration) so awards can be
  corrected. Correction = append-in-time: un-award writes a `retracted=true` record with fresh
  `mod`; a re-award overwrites with a newer one; nothing is ever deleted. Live path = ML-only
  right-click → `unaward` broadcast (DL-11-gated receivers); post-trade path = record-only
  retraction from HistoryModule (gated `IsSelf(rec.by)`), wording never implies the trade
  reversed. Caveat: a not-yet-upgraded client keeps union semantics and ignores retractions until
  updated — accepted (same-version fleet). §6.15.
- **DL-21 (accepted, 2026-07-04 — Phase 12 session persistence v2):** the saved ML session
  mirrors the live `rows`/`voters`/`awarded` tables **by reference** (the `sessionItems` trick) —
  responses/votes/awards survive `/reload` with no extra save plumbing. Resume is an explicit ML
  action (dialog with age/counts, or `/lcex resume`); it seeds fresh then overlays the saved
  aggregate; out-of-group resume is local-only (no broadcast). Candidate rejoin = `sReq`/`sJoin`
  whisper pair triggered by an unknown-sid `sPing` — minimal, idempotent, throttled, DL-11 trust
  unchanged. Sessions die only by explicit end/abort. §6.16.
- **DL-22 (accepted, 2026-07-04 — Phase 12 trade timers):** Gargul's trade-timer UX rebuilt
  native (no LibCandyBar, no copied code): bag-scan on `BAG_UPDATE_DELAYED` (debounced) through
  the DL-9 tooltip scanner; **all** tradeable loot shows, winners annotated from `pendingTrades`;
  ascending countdown bars, green/gold/red at ≥60m/≥30m/below; minimize = the
  soonest bar; opt-in default off, no close button, rarity-colored bracketed item text,
  semi-transparent compact frame with width-only resize grip and configurable expanded row cap.
  Keying prefers `C_Item.GetItemGUID` (probe on Anniversary — X-item) with an
  `itemID:expiry-bucket` reconcile fallback. `/lcex timertest` shows a synthetic test row for
  visual QA without raid loot. §6.17.
- **DL-23 (accepted, 2026-07-04 — Phase 12 shared widget layer):** the batch's cross-cutting UI
  mechanics land ONCE in `UI/Widgets.lua`/`UI/Theme.lua`, never per-module: FauxScrollFrame
  scrollbar repositioned inside the list (fixes every list at once), an index-parity zebra stripe
  layer under `CreateScrollList` (`opts.zebra`), a `SetFlatEnabled` disabled state on flat
  buttons, and one reused native context-menu widget (`ShowContextMenu`) shared by the browser
  note flow, award correction, and future consumers. Per the handoff's "do not duplicate
  row-striping logic" rule. Extended (pre-raid pass): `CreateEditBox` dropped `InputBoxTemplate`
  for a flat themed input (base fill, hairline border, accent focus ring) — every text input
  addon-wide reskins at once — and `LAYOUT.editPad` collapsed to 0 (the flat frame edge IS the
  content line; call sites keep their `+ editPad` algebra). Focus hygiene rides the same widget:
  a raw-event watcher in Widgets.lua clears edit focus when combat starts or a mouse press lands
  outside the focused box's own window, so a note box can never silently eat movement keys.
- **DL-24 (accepted — Phase 13, RCLC compatibility bridge, §6.18):** support raiders on
  **RCLootCouncil Classic** with a **one-way** bridge — the LCEX ML speaks RCLC's wire dialect so
  they respond as **candidates** (RCLC council voting out of scope; LCEX never acts as an RCLC
  candidate). Amends the §1 non-goal (RCLC-installed raiders are now in scope; the no-addon
  whisper fallback stays out). Dialect pinned to **RCLC Classic v1.4.x** (AceSerializer +
  LibDeflate L3 + `EncodeForWoWAddonChannel`, prefix `"RCLC"`); the ancient 2.x LibCompress
  dialect is unsupported. Key constraints: (a) RCLC derives the ML from `GetLootMethod`/roster, so
  on Anniversary (no master-loot API) **the LCEX ML must be raid leader** — the bridge warns
  otherwise; this is RCLC's authority model, orthogonal to LCEX's own `sStart`-sender authority
  (DL-11). (b) RCLC raiders see **LCEX's** buttons via MLdb built from the live `ResponseSet()`,
  so DL-8 (user-configurable responses) flows through unchanged. (c) The `"RCLCv"` version prefix
  is never sent (zero version popups). (d) Inbound RCLC responses reuse the native
  `dispatch.cResp` injection point, so no session-logic fork. (e) No `PROTOCOL_VERSION` bump — the
  LCEX wire is untouched; the RCLC dialect is a separate prefix. Deferred: un-award + mid-session
  adds to RCLC clients (no RCLC message for either); no send-ACK (RCLC's own reconnect retry
  heals drops).

---

## 9. Glossary
- **ML** — master looter; the loot authority for a session (Plane A).
- **Candidate** — a raid member eligible for / responding to an item.
- **Council** — members who vote (Plane A) and own the shared notes/marks (Plane B).
- **Session** — one open loot-voting cycle, identified by `sid`.
- **Mark** — a persistent council note attached to an item ("give next to X").
- **Plane A / B** — live ML-authoritative voting / persistent replicated council data.
