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

## Feature C — Council/officer access control + guild config inheritance

**Status:** awaiting answers

**The ask (user's words):** "add logic to separate council members from other guild members
to prevent showing council-only settings to anyone in the raid. if there's an existing guild
config set up, inherit it from another guild member, polling guild on first load. pop up a
prompt like: inherit <Guild> loot council settings from <Player> ? Y/N. these settings will
contain settings like officer rank, which is different for different guilds. if user is below
officer rank, or not manually added to the loot council, grey out those settings in the addon.
also make sure if someone quits the guild, they should no longer be able to see data for an old
guild... however that needs to happen."

**Grounding (what the code says today):**
- Council roster is a **single local `profile.council = {byRank, rank, extra}`** (`Core/Init.lua:35`)
  that double-duties for BOTH vote-gating (Plane A) and sync-gating (Plane B) — flagged unresolved
  as **DL-1** (PROJECT.md:237). `ResolveCouncil` (`Core/session/Session.lua:35-54`): union of
  `extra` (manual, any rank) + self (Plane A only) + guild members with `rankIndex <= rank`
  (0 = GM; lower index = higher rank; `rank` is a "this rank or better" cutoff).
- Predicates: `AmCouncil()` / `IsCouncil(name)` / `SyncSenderOk(sender)` (`Sync.lua:37-44`,
  `Session.lua:66-70`). Today council membership **only gates sync + votes — never which settings
  a user sees or edits.** There is **no council-vs-ordinary-guild-member distinction for settings.**
- Guild rank is read **only** via `GetGuildRosterInfo(i)` 3rd return (`rankIndex`) inside
  `ResolveCouncil`. **`GetGuildInfo` is never called** — the addon does not read the player's OWN
  rank directly, and **never reads the guild NAME.** `GuildControlGetRankName` never called (no
  rank-name strings). `GUILD_ROSTER_UPDATE` is hooked (`Sync.lua:148`) but only invalidates the
  cached council set; **`PLAYER_GUILD_UPDATE` is never registered.**
- Two settings UIs, **neither role-gated:** `UI/ConfigWindow.lua` (personal: scale, opacity,
  minimap, `minQuality`, self-report) and `UI/council/SessionConfigModule.lua` (officer-ish:
  poll deadline, **council roster editor + rank cutoff**). The latter is reachable by anyone —
  `CouncilWindow.lua:60-67` registers every module unconditionally, no role check.
- **No disabled/greyed control state exists** in Widgets — only a `faint` "disabled" text *color*
  (`Theme.lua:34`); greying would need manual `EnableMouse(false)`/`SetAlpha` (net-new helper).
- **All data is account-wide `global`, keyed by player name — never guild-scoped.** No `char`/
  `realm`/`factionrealm`/guild namespace. **No purge/hide-on-leave mechanism anywhere.** Owner-keyed
  maps (`pendingTrades`, `session`) are the only keying precedent, keyed by CHARACTER not guild.
- **No config broadcast/inherit exists.** Config is 100% local per-install; nothing on the wire
  carries `profile.council`, `rank`, `minQuality`, `pollTimeout`, or the response set. `sStart`
  carries the resolved council LIST + response set for one session only — not config replication.
  DL-8 (PROJECT.md:244) notes a shared response set "will need to be carried in sStart or a synced
  config" — i.e. **no synced config yet.**

**Open questions — Decisions:**
- **C1.** Config-sharing model — the crux. Is the inherited guild config a **one-time bootstrap
  copy** on first load (then local, re-inheritable), or a **continuously-synced shared config**
  (officer-authored, LWW, replicated like a dataset)? The "inherit from <Player>? Y/N" wording
  reads as a bootstrap copy, but that lets officer-rank/roster drift out of sync across the guild.
  (Recommend a synced officer-authored guild-config record — keeps everyone consistent, resolves
  DL-1/DL-8 — with the Y/N prompt as the first-run onboarding on top of it. Bigger build. Fork is real.)
- **C2.** What "officer rank" means vs the existing model. Is the settings-gate simply the existing
  **`AmCouncil()`** predicate (byRank cutoff OR `extra`), or a NEW separate "officer" tier distinct
  from the voting council (e.g. officers *configure*, a broader council *votes*)? (Recommend reuse
  `AmCouncil()` — "officer rank" = the `council.rank` cutoff, manual adds = `extra` — to avoid a
  parallel concept. Confirm, or define officers ≠ council.)
- **C3.** Gate mechanics: which settings, and **hide vs grey**. Personal settings (ConfigWindow)
  stay visible to everyone; the officer settings (SessionConfigModule: deadline, roster, rank)
  get gated. The ask says both "prevent showing" AND "grey out" — do we **hide the officer module
  from the rail** for non-council, or **show-but-disable (greyed)** so they see it exists?
  (Recommend hide the officer module; keep personal settings visible.)
- **C4.** Bootstrapping / escape hatch. If editing council config is itself gated, who sets it up
  first? (Recommend: always editable when you're guild rank 0 / GM, OR no shared config exists yet,
  OR solo/not-in-guild for testing — else the config is uneditable by everyone.)
- **C5.** Inheritance source & trust. On first load with no local config, we broadcast a config
  request to GUILD — whom do we adopt from? (Recommend: prefer the highest-ranked responder / an
  officer, name them in "inherit <Guild> config from <Player>? Y/N". Confirm: auto-pick highest
  rank vs user chooses among responders vs only accept from officer-rank senders.)
- **C6.** Guild-leave data handling (the explicit "however that needs to happen"). Options:
  (a) **guild-scope all council data by `guildKey` and HIDE** data not belonging to the current
  guild; (b) **delete** on leave; (c) keep but **read-only**. And legacy records created before
  guild-tagging — adopt into the current guild, or leave visible as untagged? (Recommend (a): tag
  new records with `guildKey` going forward, hide non-matching; adopt pre-existing untagged records
  into the first guild seen. This is a big data-model change that **overlaps Guild Bank B2** — see X4.)

**Open questions — Defaults (veto if wrong):**
- **Cd1.** The settings gate reuses the existing `AmCouncil()` predicate — no new membership
  concept — unless C2 says otherwise.
- **Cd2.** Personal settings (scale/opacity/minimap/self-report/`minQuality`) stay fully visible &
  editable for everyone; only officer/session settings are gated.
- **Cd3.** Where we grey rather than hide, it's the `faint` text tone + `EnableMouse(false)`/`SetAlpha`
  (net-new minimal disabled helper, since Widgets has none).
- **Cd4.** The inherit prompt is a themed Y/N popup, shown once on first load when no local config
  exists and a guild peer offers one; "No" keeps defaults and stops asking this session.
- **Cd5.** `guildKey` = normalized guild name from `GetGuildInfo` (realm-qualified), following the
  owner-keyed precedent. (Requires calling `GetGuildInfo` — verify on live client, see X3.)
- **Cd6.** Non-council players keep FULL loot-session participation (poll responses, loot window,
  their own votes if on the session council) — gating is only about council SETTINGS/data, never
  the raider flow.

---

## Feature V — Voting-frame award-readiness border (+ tally, anon voting, disenchanter)

**Status:** awaiting answers

**The ask (user's words):** "on the voting frame, add a highlighted border to the item icon if
it's ready to be awarded. an item is ready when: nobody rolls on it and it's ready to be sent for
d/e (do we have an intuitive way to set your preferred disenchanter so you don't have to choose
who you're sending it to every time? if not we need that too.) OR when all council members present
in the session have voted (do we have a way to indicate cleanly how many votes have been cast and
by whom? do we have a setting for anonymous voting?) OR when only one person rolled on an item and
everyone else passed. grey border = still waiting for responses, blue = d/e waiting (nobody rolled
on it and all votes are in), dark green = awarded, gold = everyone has responded, voting in
progress, light green = ready to be awarded."

**Grounding (what the code says today):**
- Header item icon: `CreateItemIcon(pane, 30)` (`UI/LootWindow.lua:99-100`), repainted in
  `RefreshLootWindow` (`:394-407`). The icon widget (`Widgets.lua:17-36`) has **no border layer** —
  an outline is new geometry. Best template: `CreateFlatButton`'s `SetBackdrop{edgeFile=WHITE8X8,
  edgeSize=1}` + `SetBackdropBorderColor` colored by variant (`Widgets.lua:274-285`). Rail-row icons
  are also `CreateItemIcon` (`LootWindow.lua:174`) so a border helper applies to both.
- Theme colors (`Theme.lua:28-42`): **gold = `accent` exists.** grey/blue only approximable
  (`text.faint`, `quality[3]` rare-blue) — not named status colors. **dark-green & light-green do
  NOT exist** (only one `success` green). New named status colors needed.
- Award state today: `activeSession.awarded[index]` → rail badge "✓ name" in `success` green
  (`LootWindow.lua:220-224`). No per-item "status/readiness" field anywhere.
- Responses vs votes are **separate & clean**: `RESPONSES` = BiS/Major/Minor/Greed/Pass
  (`Const.lua:24-30`; "wants" = not PASS; **no "roll?" and no "Disenchant" response**). `cResp`
  (candidate response, not council-gated) vs `vVote` (council vote — council-gated, a signed
  ±1/0 toggle cast ON a responder). State: `session.rows[i][name]={resp,votes(net sum),…}`,
  `session.voters[i][candKey][voter]=±1`, `councilSet`.
- **Definitional trap:** the poll pre-filters to players who *can use* the item, and a
  non-responder simply has **no row** — so "everyone passed" and "nobody responded / not eligible"
  are indistinguishable, and the ML has no clean "expected responder" denominator. There IS a
  `pollTimeout` deadline (`profile.pollTimeout`, 0 = off).
- **All three "ready" conditions are computable but none is precomputed.** (a)/(c) from
  `rows[i]` + the PASS id; (b) "all present council voted" needs the MOST new work — there's **no
  "present council roster" and no per-item "who voted" set** (only per-candidate signed sums). Must
  intersect `councilSet` with current group presence, then union voter keys across `voters[i]`.
- **Vote tally / who-voted: does not exist.** `row.votes` is a net signed sum (can be 0 with votes
  cast); the rail badge counts *responders*, not votes. No "3/5 council voted", no voter list.
  Non-ML clients only receive aggregated net sums, never per-voter ballots (ML-only knowledge).
- **Anonymous voting: does not exist** (no setting/flag anywhere).
- **Disenchant / preferred disenchanter: do not exist.** No DE response, no DE award path, no
  default-target setting; the "disenchanter path" is explicitly listed as consciously skipped
  (docs/REFERENCE_STUDY.md — "implies a points model"). Award target is **always** named explicitly
  by the ML (`AwardItem(index, name)`, `Award.lua:315`; UI Award button passes the row's candidate).

**Open questions — Decisions:**
- **V1.** State-machine / the denominator problem. Given the poll pre-filter + no-row-for-non-
  responders, how is "everyone has responded" (gold) defined? (Recommend driving state off the
  **deadline**: before deadline = grey collecting → gold once responses stop coming / deadline
  approaches; after deadline evaluate the three ready conditions. If `pollTimeout` is Off, there's
  no deadline — then what triggers "responses are in"? Needs an answer.)
- **V2.** Condition (b) definitions: "**present** council" = intersect frozen `councilSet` with the
  CURRENT group (vs the set frozen at session start)? "**has voted**" = a council member cast ≥1
  non-zero vote on this item, OR require an explicit "done/abstain" click (else a deliberate
  abstainer blocks "all voted" forever)? (Recommend present = frozen∩currentgroup; voted = any
  non-zero in `voters[i]`; add an explicit **Abstain** so abstainers count as "voted".)
- **V3.** Where readiness is computed/shown. Per-voter ballots live ONLY on the ML, so non-ML
  clients can't fully compute (b). Do we **broadcast a per-item status from the ML in `cUpdate`**
  (every client shows the same border), or compute locally per client (non-ML shows a reduced
  border)? (Recommend ML computes + broadcasts status — consistent borders, sidesteps ML-only data.)
- **V4.** Border scope: header icon only (current item), or **also each rail-row icon** for
  at-a-glance readiness across all items? (Recommend both — rail borders are the real value to an
  ML working a list; rows are the same widget.)
- **V5.** Preferred disenchanter. How is it set — (a) a config setting naming a character,
  (b) right-click a roster/candidate → "set as disenchanter", (c) auto-suggest guild Enchanters from
  `profCache`? And is "send for d/e" just **awarding to that target via the existing `AwardItem`
  path** (logged with a DE flag), with **NO points model** (per the out-of-scope note)? (Recommend
  a+c: a stored preferred-disenchanter name suggested from Enchanters; DE = AwardItem flagged DE.)
- **V6.** Vote tally / who-voted indicator (needed for (b) regardless). Add an "**X / Y council
  voted**" readout (Y = present council count) plus a who-voted list. Where — the loot-window header
  area? (Recommend header readout + a hover/expand voter list, subject to V7.)
- **V7.** Anonymous voting setting. Add an officer/session toggle; when ON, hide "by whom" / per-
  voter detail and show only aggregate counts. Scope: hide voter identities from **the ML too**, or
  only from non-ML (who already get only aggregates)? (Recommend a session-level flag carried in
  `sStart` so all clients agree; hides "by whom" everywhere incl. ML display; counts still shown.)

**Open questions — Defaults (veto if wrong):**
- **Vd1.** Border = a WHITE8X8 backdrop edge on the icon button colored per state (reusing the
  `CreateFlatButton` border template), added as a reusable method on `CreateItemIcon`.
- **Vd2.** New named theme colors added for the missing states: dark-green (awarded), light-green
  (ready), a status blue (d/e), a neutral grey (waiting); gold reuses `accent`.
- **Vd3.** State precedence: awarded (dark green) beats all; among the rest ready(light green) >
  d/e(blue) > voting(gold) > waiting(grey).
- **Vd4.** No border while staging (no active session).
- **Vd5.** The tally readout uses existing Theme text tones; hidden entirely outside a session.
- **Vd6.** Anonymous voting defaults **OFF**.
- **Vd7.** Preferred disenchanter is stored per-profile; DE falls back to manual target selection
  if it's unset or that character is offline / not in the raid.

---

## Cross-cutting

**Open questions — Decisions:**
- **X1.** Spec-first vs build-first. All four features are absent from PROJECT.md and the Phase 7
  map. PROJECT.md is the repo's source of truth. Do we **update PROJECT.md first** (data-plane
  placement, new datasets/message types, §5 file layout, a phase/section for each) before
  implementing, or build then document? (Recommend spec-first per repo convention.)
- **X2.** Build order across all four. G is a small bolt-on; V is self-contained session polish;
  C introduces config replication + guild-scoping (foundational); B (guild bank) **depends on the
  guild-scoping C introduces**. (Recommend **G → V → C → B**.)
- **X3.** Live-client API verification. I can't run the game. New/unverified APIs across these
  features: `GetItemStats` socket data (G), all guild-bank APIs (B), and **`GetGuildInfo`** for
  guild name/`guildKey` (C). Plan: build against warcraft.wiki.gg **BCC-tagged** signatures **plus**
  `/lcex selftest` API-contract checks you run in-game, then I read the report from SavedVariables.
- **X4.** **Unify guild-scoping.** Both Guild Bank (B2) and Council-access (C6) need to key/scope
  data by guild. Design ONE `guildKey` scoping mechanism (from `GetGuildInfo`) used by both, rather
  than two schemes. (Recommend yes.)
- **X5.** **Unify shared config.** Config inheritance (C1), anon-voting-in-`sStart` (V7), and the
  deferred shared response set (DL-8) all point to a "synced/shared guild config" that doesn't exist.
  Build ONE shared-config mechanism carrying council config + response set + anon flag, or bolt each
  on separately? (Recommend one mechanism — also resolves DL-1/DL-8.)
- **X6.** New message types / protocol. These add wire messages (config request/broadcast, gbank
  sync, per-item readiness in `cUpdate`, DE-flagged award). Confirm whether they warrant a
  `PROTOCOL_VERSION` bump and spec-first PROJECT.md §6 updates (ties to X1).

**Defaults (veto if wrong):**
- **Xd1.** Every feature registers `/lcex selftest` checks in `Core/SelfTest.lua` in the same commit
  as the feature (repo rule) — headless-testable logic (gear issues, readiness computation) gets
  runner checks; API contracts (gbank, `GetItemStats`, `GetGuildInfo`) + cache round-trips get
  in-game checks.
