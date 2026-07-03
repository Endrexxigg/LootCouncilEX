# todo.md — feature backlog & open questions

Dev-only planning doc. `.pkgmeta`-ignored — never ships in the CurseForge zip.
Status flow per feature: `awaiting answers` → `specced` → `in progress` → `shipped vX.Y.Z`.
Question numbers here match the numbers asked in chat, so answers can be recorded
without re-deriving anything. A skipped **Decision** question is not consent — it gets
re-asked before that part is built. Silence on a **Default** = consent (that tier only).

---

## Feature G — Enchant/gem data in the gear self-report

**Status:** awaiting answers

**The ask (user's words):** "make the self report also include enchant and gem data.
I'd like to see each raid member's gear (and gear issues like bad gems/missing enchants)
so officers can identify issues before raid time and send reminders to slackers."

**Grounding (what the code says today):**
- Gear is snapshotted by `LCEX:SnapshotGear()` — `Core/council/SelfReport.lua:35-42` —
  as **full item links keyed by inventory slot 1..18** (`gear[slot] = GetInventoryItemLink`).
  No itemID/ilvl/slot fields; the slot is the table key.
- **Item links already embed enchant + gem IDs** (`item:itemID:enchantID:gem1:gem2:gem3:gem4:…`).
  Nothing in the codebase parses past the itemID today — every parser does
  `match("item:(%d+)")` and discards the rest (`Core/Usable.lua:61`, `Core/council/Marks.lua:27`,
  `Core/session/Award.lua:184`, etc.). So the enchant/gem data an officer needs is **already
  sitting in the replicated `gearCache` links** — potentially a pure-rendering change.
- The one thing links do NOT carry: an **empty socket**. Only *filled* gems appear in the
  link. Detecting "item has a socket but no gem" needs the item's base socket count —
  from `GetItemStats` (EMPTY_SOCKET_* keys) or a tooltip scan. `GetItemStats` runs locally
  on any cached link (not range-limited), so a *viewer* could compute this too — pending
  live-client verification.
- Transmission: `pReport` message (`SelfReport.lua:83-100`) over GUILD (`syncChannel`),
  payload `{gear, profs, class, spec, mod}`; received at `dispatch.pReport`
  (`SelfReport.lua:124-140`), stored in `global.gearCache[name] = {items, class, spec, mod, by}`,
  replicated council-only via the Plane-B sync engine (LWW by `mod`). Adding fields is
  additive/backward-compatible — no forced `PROTOCOL_VERSION` (Const.lua:15, =1) or
  `DB_VERSION` (Init.lua:79, =1) bump.
- Display today: Players council module → Gear sub-tab
  (`UI/council/PlayersModule.lua`, `FillDetailRow` 38-44) renders one row per occupied slot:
  item icon + `"  slot N: <link>"`. **No enchant or gem info shown anywhere.** Shows one
  selected player at a time — there is no roster-wide overview.
- Existing tooltip-scan idiom exists to copy if needed: `LCEX_ScanTooltip` in
  `Core/session/Award.lua:41-59` (used for the BoP trade timer; the established pattern for
  reading tooltip lines).
- No enchant-name / gem-stat reference tables exist. No notion of "enchantable slots."

**Open questions — Decisions:**
- **G1.** Data source / where issues are computed. Because links already carry enchant+gem
  IDs and `GetItemStats` gives socket counts locally, issue-detection can likely be a
  **pure viewer-side rendering change (zero comms/protocol change)**. The alternative is
  **enriching the `pReport` payload** (reporter sends socket counts / resolved names).
  Which? (Recommend: rendering-only if `GetItemStats` socket data proves reliable on the
  live Anniversary client; I must verify that before committing. Fall back to payload
  enrichment only if it doesn't.)
- **G2.** What counts as an "issue"? Which of these does v1 flag: (a) **missing enchant**
  (enchantable slot, enchantID==0); (b) **empty socket** (socket present, no gem);
  (c) **low-quality gem** (uncommon/green quality); (d) **wrong-color gem** (gem color ≠
  socket color)? (Recommend a+b+c; (d) is fiddly and low-value in TBC — propose out of scope.)
- **G3.** Enchant judgment depth: v1 = binary **enchant present vs absent** on a hardcoded
  TBC enchantable-slots list, OR a quality judgment ("is this a *good* enchant")?
  (Recommend binary presence — a curated "acceptable enchant per slot" table is a large,
  maintenance-heavy dataset better left to a later pass.)
- **G4.** Viewing surface. Today the Gear sub-tab shows ONE selected player. Do we
  (a) only annotate that per-player view with enchant/gem lines + issue badges, or
  (b) also add a **roster-wide "Gear Check" overview** listing every member with an
  issue count (the "who are my slackers" at-a-glance scan), or both? (Recommend both —
  "identify slackers before raid" implies a scan-everyone view; (b) is the larger piece.)
- **G5.** Is any **automated reminder/messaging** in scope for v1 (e.g. a button to
  whisper/guild-message offenders their gaps), or is this display-only and the officer
  messages people by hand? (Recommend display-only for v1; a "copy/whisper summary"
  button is a clean follow-up.)

**Open questions — Defaults (veto if wrong):**
- **Gd1.** Per-slot render: under each gear row, a small enchant line (green ✓ "Enchant:
  <name>" / red ✗ "No enchant") and gem dots colored per socketed gem, with a grey empty-
  socket marker. Clean slots render as today.
- **Gd2.** Issue coloring reuses the existing `Theme` danger (red-brown) for problems and
  success (green) for OK — no new colors.
- **Gd3.** Empty gear slots (no item) stay skipped as today, not flagged as an issue.
- **Gd4.** Enchant/gem display names resolve via the item link + `GetItemInfo`, async via
  the existing `WithItemID` pattern for uncached items; still-loading shows a graceful
  placeholder, never a blank/error.
- **Gd5.** Freshness reuses the existing "cached Nm ago" line — no separate enchant-data
  timestamp.
- **Gd6.** Your own character shows live-computed issues from currently-equipped items
  (matching the existing self live-snapshot path), not a stale cached report.
- **Gd7.** Pre-feature `gearCache` records need no migration — enchant/gem derive from the
  links they already store.

---

## Feature B — Guild Bank module

**Status:** awaiting answers

**The ask (user's words):** "include a module for guild bank. this tab will cache the
guild bank items/tabs/gold/logs. log entries can be annotated, like 'Endrexx withdrew 187g -
bought some primal nethers for cloaks' or 'Endrexx withdrew 7 items - mongoose for Zzaj's
fang'. when multiple log items occur in a short timespan (like withdrawing 5 stacks of
enchanting mats), display them grouped with item icons and 'x2' to show quantity
withdrawn/deposited. add a setting to toggle a prompt to add a note upon closing the gbank
if you withdrew/deposited anything while it was open. add a nice looking hero card on this
view to showcase total gold in the gbank."

**Grounding (what the code says today):**
- **Entirely net-new.** "guild bank" appears **nowhere** in PROJECT.md, and **no
  guild-bank API is used anywhere** in the tree (searched `GetGuildBankItemInfo`,
  `QueryGuildBankTab`, `GUILDBANKFRAME_OPENED`, `GetGuildBankTransaction`, etc. — zero hits).
  Every API/event would be introduced fresh and **must be verified against the live TBC
  Anniversary client** (PROJECT.md:21 hard constraint).
- Module contract is clean to extend: `LCEX:RegisterCouncilModule{key,title,order,build,show,hide}`
  (`UI/CouncilWindow.lua:6-12,22-26`); modules self-register and are listed in the `.toc`.
  Existing orders: browser=10, players=20, history=30, sessioncfg=40. `HistoryModule.lua`
  is the simplest template; `PlayersModule.lua` shows the sub-tab pattern.
- **No hero-card / stat-callout widget exists.** Nearest precedent is the inline poll
  response card — `UI/PollWindow.lua:74-100` (`Surface(card,"raised")` + `SoftEdge`). A gold
  hero card would be built inline in that style (Theme: accent gold #caa65a, elevation tones).
- **No item-icon count/"xN" overlay exists.** `CreateItemIcon` (`UI/Widgets.lua:17-36`) is a
  single texture, no count FontString. Quantity is only ever shown as a *sibling* FontString
  (`LootWindow` badges). An "xN" overlay is net-new.
- Scroll lists: `LCEX:CreateScrollList` (`UI/Widgets.lua:55-116`) — the FauxScrollFrame
  factory; repopulate via `list:SetData(...)` which does the load-bearing offset reset.
- DB: only **account-wide `global`** and a single forced-default `profile` — **no `char`,
  `realm`, or `factionrealm` namespace** (`Core/Init.lua:108`). Persistent council data lives
  in `global` (`notes/marks/history/gearCache/profCache`), replicated Plane-B via
  `LCEX:RegisterDataset(name, mode, store)` — `"lww"` (LWW by `mod`) or `"union"` (immutable,
  like `history`). Owner-keyed maps already exist as precedent (`pendingTrades`, `session`).
- Settings: schema-driven config window — append `{type="checkbox",label,get,set}` to
  `BuildSchema` (`UI/ConfigWindow.lua:28-56`) + a default in `DB_DEFAULTS.profile`
  (`Core/Init.lua:33-54`).
- **TBC guild-bank API reality (shapes several questions):** contents/logs are only readable
  while the bank frame is **open**; `QueryGuildBankTab` is throttled (one tab per server
  round-trip, answered by `GUILDBANKBAGSLOTS_CHANGED`); transaction logs are **indexed,
  shallow (last N per tab + money log), have no stable unique ID**, and report time as
  *elapsed* ("years/months/days/hours ago"), not absolute — so absolute times must be
  computed at read time.

**Open questions — Decisions:**
- **B1.** Replication: does the guild-bank cache (items/tabs/gold/logs/annotations)
  **replicate to the whole council over Plane B** (so officers *without* bank access can
  view/annotate it), or stay **local to whoever opened the bank**? (Recommend replicate —
  the stated review/annotate/remind workflow implies a shared view. Note: 7 tabs × 98 slots
  is sizable to sync.)
- **B2.** DB scope / keying. `global` is account-wide with no realm/guild scope, but
  guild-bank data is inherently guild+realm-specific. Key everything under a synthesized
  `guildKey = realm.."|"..guildName` (owner-keyed precedent), or assume a single guild and
  keep it flat? Does multi-guild/multi-realm on one account matter at all? (Recommend
  guild-keyed to avoid mixing.)
- **B3.** Log identity & annotation target (the hard one). TBC logs are ephemeral, indexed,
  and ID-less. To attach durable annotations we need our own **append-only local ledger**:
  on each bank open, read the logs, convert elapsed→absolute time, assign our own monotonic
  IDs, dedup against already-captured entries, and annotate *our* ledger entries. Confirm
  this ledger approach — and whether an annotation attaches to a **single entry, a grouped
  transaction, or both** (the user's examples read as group-level: "withdrew 7 items —
  mongoose…"). (Recommend append-only ledger; annotations attach at group level, with a
  single-entry group being the degenerate case.)
- **B4.** Grouping rule. Group consecutive entries by the **same player + same action
  (withdraw/deposit)** within a time window into one row: identical items collapse to one
  icon + "xN"; distinct items show multiple icons + a header summary ("7 items / 187g").
  What window — a fixed span (e.g. 5 min) or "same bank-open capture"? (Recommend: same
  player+action within 5 minutes; distinct items shown side by side, matching both user
  examples.)
- **B5.** Annotation authorship & replication. Who may annotate — any council member, or
  only officers with bank access? Are annotations replicated LWW like `notes` so everyone
  sees them? (Recommend: any council member; replicated LWW like `notes`.)
- **B6.** Capture on open: auto-query **all** viewable tabs sequentially on
  `GUILDBANKFRAME_OPENED` (a few seconds of throttled queries) to cache everything, or only
  cache the tab the user actually clicks? (Recommend auto-scan all viewable tabs, spaced via
  AceTimer.)
- **B7.** Close-prompt setting. On bank close, if *you* moved anything while it was open, pop
  a themed note dialog pre-filled with a summary ("You withdrew 7 items, 187g"); your typed
  note saves as the annotation on that group. Confirm: trigger on **your own** transactions
  only; themed popup (not a chat prompt); and default **off** or **on**?
- **B8.** Pane layout. Proposed: gold **hero card** across the top; a **tab selector** for
  the guild-bank tabs; and sub-tabs **Contents** (item grid) vs **Log** (annotatable list),
  in the `PlayersModule` sub-tab style. Confirm this shape or adjust.

**Open questions — Defaults (veto if wrong):**
- **Bd1.** Registered as council module `key="gbank"`, title "Guild Bank", **order 50**
  (end of the rail, so existing tabs don't shift).
- **Bd2.** Hero card = a `Surface("raised")` card showing **total gold** via Blizzard coin
  icons (g/s/c), built inline in the poll-card style; no new widget framework.
- **Bd3.** Gold in the hero card is **whatever was last cached** on the most recent bank open
  (with a "cached Nm ago" freshness line), since live gold is only readable while open.
- **Bd4.** Item counts/stacks render as an **"xN" text overlay** on the bottom-right of the
  icon (new small addition to the icon widget), matching the WoW bag convention.
- **Bd5.** Contents view shows only tabs the viewer's cache actually has; tabs never scanned
  show an empty/"not cached" state rather than erroring.
- **Bd6.** Money-log and item-log entries share one unified Log list, newest first.

---

## Cross-cutting

**Open questions — Decisions:**
- **X1.** Spec-first vs build-first. Both features are absent from PROJECT.md and the Phase 7
  map. PROJECT.md is the repo's source of truth. Do we **update PROJECT.md first** (data-plane
  placement, new datasets/message types, §5 file layout, a phase/section for each) before
  implementing, or build then document? (Recommend spec-first per repo convention.)
- **X2.** Build order. Feature G is a small bolt-on to an existing subsystem (Phase-5
  self-report); Feature B is a large net-new module. Ship **G first, then B** as its own
  mini-phase? (Recommend yes.)
- **X3.** Live-client API verification. I can't run the game; guild-bank APIs and
  `GetItemStats` socket behavior must be verified on the live Anniversary client. Plan:
  build against warcraft.wiki.gg **BCC-tagged** signatures **plus** `/lcex selftest`
  API-contract checks you run in-game, then I read the report from SavedVariables. Confirm.

**Defaults (veto if wrong):**
- **Xd1.** Both features register `/lcex selftest` checks in `Core/SelfTest.lua` in the same
  commit as the feature (repo rule) — gear issue-detection logic is headless-testable; the
  guild-bank API contract + cache round-trip get in-game checks.
