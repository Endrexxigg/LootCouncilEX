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
- **Comms envelope:** every message is one AceSerializer-encoded table `{ v, cmd, sid, ... }`. `v` = `PROTOCOL_VERSION`; drop messages with an unreadable higher major `v`. `cmd` routes through a dispatch table. `sid` identifies the session (nil for Plane B / roster messages).
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
├── Libs/                      # LibStub + ACE3
├── Core/
│   ├── Init.lua               # bootstrap, prefix, DB defaults, /lcex
│   ├── Const.lua              # PROTOCOL_VERSION, RESPONSES, STATUS
│   ├── Comms.lua              # envelope, (de)serialize, dispatch, debounce
│   ├── Roster.lua             # raid roster + addon-version handshake
│   ├── session/               # PLANE A
│   │   ├── Session.lua        # ML state machine (authority)
│   │   ├── Candidate.lua      # receive sStart → loot frame → send cResp
│   │   ├── Council.lua        # receive cUpdate → voting frame → send vVote
│   │   └── Award.lua          # GiveMasterLoot wrapper, eligibility, manual-trade path
│   ├── council/               # PLANE B
│   │   ├── Sync.lua           # GUILD sync engine (manifest, deltas, LWW merge)
│   │   ├── Notes.lua          # player notes dataset
│   │   ├── Marks.lua          # item/gear marks dataset
│   │   ├── History.lua        # award history (witnessed + synced)
│   │   └── SelfReport.lua     # broadcast own gear/profs; cache others'
│   └── Data/                  # SHIPPED STATIC DATA (populate + maintain)
│       ├── Loot.lua           # phase → raid → boss → {itemIDs}
│       ├── BiS.lua            # class → spec → phase → slot → {itemIDs}
│       └── TierTokens.lua     # tokenItemID → {class → tierPieceItemID}
└── UI/
    ├── Widgets.lua            # frame factory, style tokens, UISpecialFrames helper
    ├── SessionFrame.lua       # ML: detected items + Start/Cancel
    ├── LootFrame.lua          # candidate: response buttons + note box
    ├── VotingFrame.lua        # council: candidate table + vote + open-detail
    ├── PlayerDetail.lua       # tabs: Gear | History | Professions | BiS | Notes
    └── LootBrowser.lua        # phase tabs → boss-sorted items → editable marks
```

---

## 6. Canonical reference

### 6.1 Plane A messages
Envelope `{ v, cmd, sid, ... }`; `sid` = `"<MLname>-<unixtime>-<counter>"`.

| cmd | Direction | Channel | Payload |
|---|---|---|---|
| `vCheck` | any → raid | RAID | `{ ver }` |
| `vReply` | client → asker | WHISPER | `{ ver }` |
| `sStart` | ML → raid | RAID | `{ items={[i]={link,slot,quality}}, council={names} }` |
| `sEnd` | ML → raid | RAID | `{}` |
| `cResp` | candidate → ML | WHISPER | `{ item, resp, note, ilvl, gear={link,link} }` |
| `cUpdate` | ML → raid | RAID | `{ item, rows={[name]={resp,note,ilvl,gear,votes}} }` |
| `vVote` | council → ML | WHISPER | `{ item, candidate, vote=±1|0 }` |
| `award` | ML → raid | RAID | `{ item, itemID, winner, resp, boss, instance, ts }` |

Reliability: ML holds the authoritative table; drop inbound `cResp`/`vVote` with a stale `sid` or non-member/non-council sender. Debounce `cUpdate` (~0.2s). Idempotent — re-sends overwrite last value. No ACK in v1. `award` carries enough to build a complete local history record on every present client.

### 6.2 Plane B messages
Channel GUILD; only council members participate.

| cmd | Direction | Channel | Payload |
|---|---|---|---|
| `pReport` | any group member → GUILD | GUILD | `{ gear={slot→link}, profs={name→level}, mod }` |
| `pSet` | council → GUILD | GUILD | `{ dataset="notes"|"marks", key, record={text,mod,by} }` |
| `pHello` | council → GUILD | GUILD | `{ digest={ notes={n,maxMod}, marks={n,maxMod}, history={n}, gearCache={n,maxMod}, profCache={n,maxMod} } }` |
| `pSyncReq` | council → peer | WHISPER | `{ dataset, since=<mod|0> }` |
| `pSyncData` | council → peer | WHISPER | `{ dataset, records={key→record} }` |

Sync flow: on login/load broadcast `pHello`; a peer that's behind sends `pSyncReq(since=myMaxMod)`; peer replies `pSyncData` with the delta. Live edits propagate via `pSet`. Accept `pReport` from any group member (so any raider's gear/profs can be viewed); gate `pSet`/`pHello`/`pSync*` to council senders only.

### 6.3 Datasets (Plane B, in SavedVariables `global`)
- `notes`: name → `{text, mod, by}`
- `marks`: itemID → `{text, mod, by}`
- `history`: uid → `{player, itemID, itemLink, ts, resp, boss, instance}` (immutable; union merge). uid = `sid..":"..itemIndex`
- `gearCache`: name → `{items={slot→link}, mod}` (self-reported)
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
  global = { notes={}, marks={}, history={}, gearCache={}, profCache={} },
}
```

### 6.5 Response enum
```lua
RESPONSES = {
  [1]={id=1,key="BIS",  text="BiS",      color={0.96,0.55,0.73}},
  [2]={id=2,key="MS",   text="Mainspec", color={0.20,1.00,0.20}},
  [3]={id=3,key="OS",   text="Offspec",  color={1.00,1.00,0.40}},
  [4]={id=4,key="MINOR",text="Minor Upg",color={0.70,0.70,0.70}},
  [5]={id=5,key="PASS", text="Pass",     color={0.60,0.20,0.20}},
}
STATUS = { ANNOUNCED=90, TIMEOUT=91, NOADDON=92 }
```

### 6.6 Static data shapes
```lua
Loot       = { ["P2"]={ raids={ ["Serpentshrine Cavern"]={ ["Hydross the Unstable"]={itemID,...}, ... }, ["Tempest Keep"]={...} } } }
BiS        = { ["MAGE"]={ ["Fire"]={ ["P2"]={ ["head"]={itemID}, ["neck"]={itemID,altID}, ... } } } }
TierTokens = { [30243]={ name="Helm of the Fallen Hero", pieces={ ["WARRIOR"]=itemID, ["HUNTER"]=itemID, ["SHAMAN"]=itemID } } }
```

### 6.7 Key TBC APIs (verify signatures)
- **ESC close:** `tinsert(UISpecialFrames, "LCEX_FrameName")`.
- **Loot detect:** `LOOT_OPENED` → `GetNumLootItems()`, per slot `GetLootSlotLink`/`GetLootSlotInfo`(quality)/`LootSlotHasItem`.
- **Master loot:** `GetMasterLootCandidate(lootSlot, index)`, `GiveMasterLoot(lootSlot, candidateIndex)`. Item in bags: BoP 2-hour trade window.
- **Own gear:** `GetInventoryItemLink("player", slotID)`; snapshot on `PLAYER_REGEN_DISABLED` (anti-swap).
- **Own professions:** scan `GetNumSkillLines()`/`GetSkillLineInfo(i)` for the two professions + level. (No reliable cross-player profession inspect — self-report only.)
- **Equipped ilvl:** `GetAverageItemLevel` unreliable in Classic; show the competing-slot item from the snapshot instead.
- **Comms:** `RegisterComm("LCEX", handler)`; `SendCommMessage("LCEX", msg, "RAID"|"GUILD"|"WHISPER", target)`. GUILD reaches all online guildies (the out-of-raid path).

---

## 7. Build map

Each phase has a hard scope and an exit criterion. Do not build ahead into a later phase. Phases 1–3 produce a working voting addon (the MVP); 4–7 add the council toolkit.

**Phase 1 — Skeleton + comms proof.** `Const`, `Init`, `Comms`, `Roster` + libs.
*Exit:* two clients in a raid, `/lcex` works, `vCheck` round-trips and each prints the other's name + version. No UI. No Lua errors on load.

**Phase 2 — Loot engine (headless).** `session/Session.lua` (state machine), `session/Award.lua` (LOOT_OPENED scan, candidate resolution, `GiveMasterLoot`).
*Exit:* ML opens a corpse, addon detects epics, can broadcast `sStart` and award an item via `GiveMasterLoot` — all driven/verified through chat output and test commands, still no real UI.

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

## 8. Decision log / open questions

- **DL-1 (open, needs owner decision):** `profile.council` currently defines both the live-vote roster *and* the Plane-B sync roster. If notes/sync membership should differ from vote membership, split into two settings before Phase 4.
- **DL-2 (out of scope v1):** cross-guild council sync via custom channel — fragile; deferred.
- **DL-3 (accepted v1):** no ACK on Plane A; last-write-wins + re-click. Revisit only if delivery gaps appear in practice.
- **DL-4 (accepted, no alternative):** gear/professions are self-reported; out-of-raid / non-addon users show cached or none.
- **DL-5 (open, content task):** static datasets must be maintained each phase; consider a build-time import from a community dataset instead of hand-editing.
- **DL-6 (open, Phase 7):** ML disconnect mid-session recovery behavior is undefined.

---

## 9. Glossary
- **ML** — master looter; the loot authority for a session (Plane A).
- **Candidate** — a raid member eligible for / responding to an item.
- **Council** — members who vote (Plane A) and own the shared notes/marks (Plane B).
- **Session** — one open loot-voting cycle, identified by `sid`.
- **Mark** — a persistent council note attached to an item ("give next to X").
- **Plane A / B** — live ML-authoritative voting / persistent replicated council data.