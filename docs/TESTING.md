# LootCouncil EX — Test Checklist

> **How this file works.** The **▶ Test next** block at the very top is the *only* thing that
> needs your attention — it lists what changed since the last in-game pass, newest first. When
> you tell me an item passed, I tick it (`[x]`) or move it down into **Passed ✓** (the regression
> reference). Everything under **Passed ✓** is already verified in-game; re-run a section only if
> related code changes.
>
> **Three layers of testing — two of them are automatic:**
>
> 1. **Headless (`lua Tests/run.lua`, and on every push in CI).** Pure logic: sync merge,
>    digests + directional pull, council resolution, name normalization, command parsing, award
>    logging, self-report caching, the display builders, BiS resolution. If a *logic* bug is
>    suspected, add a case here first — seconds, not a raid night.
> 2. **In-game automated (`/lcex selftest`, Core/SelfTest.lua).** Everything that needs the real
>    client but no second player: WoW API existence/signatures on the Anniversary client (the
>    `GetTalentTabInfo`/`C_Container` class of bug), frame rendering + the FauxScrollFrame offset
>    regression, the real AceComm receive path (+ a live GUILD echo when guilded), snapshots, and
>    the full solo session pipeline (start → respond → vote → award → end). **Run it solo**, wait
>    for the chat summary, then `/reload` — that writes the full report to SavedVariables, where
>    Claude reads it directly (`WTF\Account\*\SavedVariables\LootCouncilEX.lua`) and updates this
>    file. You never need to transcribe results.
> 3. **Manual (this list).** Only what neither harness can reach: two-client convergence, real
>    trades/loot events, `/reload`-persistence flows, and how things *look*.
>
> **When a new feature lands, its in-game checks are added to `Core/SelfTest.lua` in the same
> commit** — so the manual list only ever grows by genuinely-manual items.

---

## ▶ Test next  (newest first)
Changed since the last in-game pass — verify on your next `/reload`, then tell me which passed.

### v0.52.5 — Notes fully readable on hover
The audit's leftover INFO was a real gap: a note wider than its column truncated with no way to
read the rest. Every truncatable note now shows its FULL text in a hover tooltip. Selftest-covered
(the candidate row carries a note-hover target + the full note text).

- [ ] **Loot candidate note**: in a live session, give a candidate a long response note (via the
  poll's note box) — hovering that note in the right-pane row shows the whole note in a tooltip.
- [ ] **Guild-bank log note**: an annotated transaction shows its full note when you hover the row.
- [ ] **Loot-browser note**: an item with a "Leave note…" mark shows the full note appended under
  its item tooltip on hover.

### v0.52.4 — Window z-order (fixes windows drawing through each other)
The `/auiaudit` run on v0.52.3 surfaced a **real bug** (screenshot: the Council loot-browser rows
punching through the Loot Session window). Two co-shown LCEX windows shared the DIALOG strata and
the same frame *level*, so the client interleaved their children by creation order. Fixed with the
RCLootCouncil/Gargul TBC idiom in `CreateWindowV2`: a **distinct base frame level per window**
(assigned at creation, before any child exists, 20 levels of band apart) plus **`SetToplevel(true)`**
(a click lifts the whole window+children group above other same-strata windows). Selftest-covered
(distinct-frame-level guard); the audit's cross-window OVERLAP cascade is separately declared
`allowedOverlaps` in the dev adapter (independent windows may legitimately float over each other).

- [ ] **No draw-through** *(the reported bug)*: open the Council window and the Loot Session
  window overlapping — neither window's rows/text bleed through the other. Click either to bring
  it fully to the front; the whole window (rows included) comes forward as one.
- [ ] **`/auiaudit run LootCouncilEX`** — `STRATA/AMBIGUOUS_ZORDER` should be **gone** (windows now
  hold distinct frame levels) and the cross-window `OVERLAP/CONTROL_LABEL` cascade should be
  **exempted**. Net: **no new ERROR/WARN**.
- [ ] **Nothing else shifted**: poll/loot/council/config/trade-timer still open, drag, ESC-close,
  and (council) resize as before; the confirm popup and context menu still sit above their window.

### v0.52.3 — Global layout/alignment pass (LCEX.LAYOUT contract)
Every frame now anchors from the shared spacing grid in `UI/Theme.lua` (one 12px content line
per container; unified 14px scrollbar gutter in BOTH list helpers; one edit-box art compensation).
Headless asserts the contract identities; geometry was verified arithmetically — what's left is
how it *looks* on the real client.

- [ ] **`/auiaudit run LootCouncilEX`** — must report **no new ERROR/WARN** vs the baseline
  (fingerprints are geometry-independent, so pure offset changes should not churn them).
- [ ] **Edit-box art alignment (`editPad = 4`)**: the staging add-box art lines up with the Scan
  button above it; the roster filter box, history Winner box, session-config add boxes, and the
  confirm popup's input all sit flush with their labels/columns. If the art reads ~1px off
  everywhere, `LAYOUT.editPad` in `UI/Theme.lua` is the single knob.
- [ ] **Faux-list gutters**: candidate list / roster / browser / history / gbank-log scrollbars
  now sit centered in a 14px gutter (rows got ~10px wider) — bar clear of row content, no
  overlap with badges/glyph clusters at the row's right edge.
- [ ] **Loot footer**: End/Start/D-E buttons end on the same line in both states (staging ↔
  session toggle no longer shifts the right edge by 2px); status text truncates before buttons.
- [ ] **Poll window**: margin grew 10→12 (window 404 wide); "+N more" aligns with the card edge;
  with a deadline armed and nothing usable, the empty text sits *below* the timer bar.
- [ ] **Council modules**: browser phase buttons / roster sub-tabs / gbank tabs+grid+log all
  share their panel's left line with headers and list text; session-config left column at one
  x, right column (Anonymous voting / D/E) at one x; gbank log note column starts right after
  the icon strip (was 14px adrift).
- [ ] **Config window**: controls symmetric (sliders now span the window evenly), uniform
  vertical rhythm.

*Known/intentional*: nav-rail text moved 14→10 (aligns with the title tick's 12px absolute
line); trade-timer icon inset 2 is vertical centering, not a margin; session-config roster-row
remove-× still trails a long name unbounded (pre-existing, follow-up); the browser boss/item
indents (14/30) derive from the 14px fold glyph.

### v0.39.2–v0.51 — PHASE 12 (jul4 fix/change batch, 18 items)
The 18-item handoff (`docs/lcex_fix_change_handoff_jul4.md`). **Heavily selftest-covered** — the
scrollbar/zebra/flat-button/context-menu widgets, compact↔full loot layout, awarded feedback, x2
grouping (one card / two distinct-uid awards), un-award round-trip, mini-pill show/hide, save→wipe→
resume, the trade-timer scanner shape + GUID probe, and the timer-window render/minimize/hide all
run under `/lcex selftest`; headless covers grouping/poll-dedup/leader-remap, history LWW +
`dispatch.unaward`, resume overlay + `CountSavedResponses`, `sReq`/`sJoin`, and the trade-timer
pure helpers. **Run `/lcex selftest` first** — then the genuinely-manual items below.

**Solo / visual (one client):**
- [ ] **Scrollbars (items 12/18)**: the loot rail, roster picker, and browser scrollbars sit
  *inside* their panel, not across the divider.
- [ ] **Zebra striping (item 8)**: alternating row shading on the loot cand list, rail, roster,
  browser, history, and gbank log — subtle, still legible on hover/selection.
- [ ] **Vote order (item 2)**: candidate rows read `[−] [n] [+]  [Award]`; the own-vote gold tint
  follows the correct button.
- [ ] **Glyph (item 9)**: an awarded rail row shows a ready-check tick + winner, no tofu box.
- [ ] **Rail width / names (item 11)**: common item names fit the widened (280) rail; the
  selected-item header and browser names show a tooltip on *name* hover (not the rail).
- [ ] **Compact pre-session (item 4)**: `/lcex loot` opens rail-only; **Start** expands to two
  panes; **End** collapses back on reopen.
- [ ] **Browser (items 13/14/16/17)**: raids default **collapsed**, +/− toggles raids/bosses; a
  note icon shows only on truly-marked items; no `(Token)` in the mark column; right-click an item
  → **Leave note…** / **Clear note** (the bottom mark box is gone).
- [ ] **Trade timers (item 7)** *(needs a real BoP drop — like the v0.14 DL-9 item)*: the window
  auto-opens on tradeable loot, bars recolor green→gold→red over time, minimize shows the soonest
  bar, **shift+double-click** hides a bar, it auto-closes when the last window lapses. `/lcex timers`
  toggles it. *(The selftest confirms rendering with injected entries; only the live scan is manual.)*

**2-client:**
- [ ] **Spectator view (item 1)**: a non-council raider can `/lcex loot` into a **rail-only** view
  (items, quantities, award state, winners) — **no** responses/votes/notes anywhere — and still
  answers the **poll** normally. Flip "Show the full loot window…" (Session Config) → that raider
  gets the full read-only view.
- [ ] **Duplicates (item 10)**: put **two identical items** up → raiders see **one** poll card
  (x2), the ML sees **one** candidate table; award to two different winners → rail badge reads
  `✓ 1/2` then done, the per-copy hover tooltip names each, and **two separate** trade timers track.
- [ ] **Un-award (item 3)**: right-click an awarded row → **Un-award <winner>** → the item reopens
  on both clients and history shows it retracted; **re-award** supersedes. A **post-trade**
  retraction (from the History module) is record-only and says so.
- [ ] **ML reload (item 6)**: collect responses/votes + an award, then `/reload` → the **resume
  dialog** shows age + item/response counts; **Resume** restores the votes **and** the award state.
- [ ] **Candidate reload (item 6)**: a raider `/reload`s mid-session → they **auto-rejoin** within
  ~30s of the next heartbeat (poll reopens, awarded state correct) — no ML action needed.
- [ ] **Mini pill (item 5)**: close the loot window mid-session → the pill appears (session stays
  open); its counts update as responses arrive; click restores the window.

### v0.37–v0.39 — FEATURE B COMPLETE (guild bank) — **needs a live scan**
Headless-tested: the pure ledger (uid dedup, elapsed→absolute, 5-min/xN grouping), accessors, log
visibility, and annotation round-trip; a selftest API contract (all guild-bank APIs exist) + a module
render check. **The scanner + real replication need a live bank** — the selftest can't open one:

- [ ] **Scan on open**: open your guild bank in-game → the `Guild Bank` council module fills the gold
  **hero card**, per-tab **Contents** grid, and the **Log** (grouped newest-first, "xN" stacks). Watch
  BugSack — the money-transaction loop is bounded to avoid the documented out-of-range **crash**.
- [ ] **Replication (B1)**: a second officer sees your scanned contents / gold / log after a sync
  (bounded by when your client re-advertises — `SyncHello` fires after a scan ingests new entries).
- [ ] **Annotations (B5)**: click a Log group → add a note → it shows inline and replicates to another
  officer. Non-council can't edit.
- [ ] **Visibility (B5)**: as a raider, the module shows **Contents + gold** but **no Log** tab; flip
  "Show the guild-bank log to all raiders" (Session Config) → the Log tab appears for raiders too.
- [ ] **Hour-granular dedup caveat**: two officers scanning in different clock hours may double-log a
  transaction (accepted API limitation) — sanity-check the log isn't wildly duplicated.

### v0.33–v0.36 — FEATURE C COMPLETE (access control + guild scoping + inherit)
Selftest **green through v0.35.0 (43 pass / 0 fail)**; `guild scoping active` passed and `activeGuild
= "Menu"` with existing history intact — the guild-scope **claim-in-place did not lose data**. v0.36.0
(inherit prompt) adds headless coverage + a safe no-op selftest. Automated coverage: access predicates,
config-sourced council, guild-scope claim/stash/restore, and the inherit gate/accept/decline. Manual /
2-client items the selftest can't reach:

- [ ] **Non-council hiding (C3/C7)**: as a raider (guild rank **above** the cutoff, not an extra), the
  council window shows **no Session Config** module and `/lcex loot` says "council-only"; you still get
  the **poll** on a drop. As an officer/GM you see both.
- [ ] **Config replicates (C1)**: two officers — one edits the roster / anon / disenchanters / the
  "show loot window to all raiders" toggle; the other sees it converge (shared `config`, LWW).
- [ ] **Loot-window opt-in (C7)**: flip "show loot window to all raiders" on → a raider now sees a
  **read-only** loot window on a session (no vote ±); off → back to poll-only.
- [ ] **Inherit prompt (C1/C5)**: a fresh/no-config officer joining sees "Inherit `<Guild>` settings
  from `<Player>`? Y/N" a few seconds after login; **Yes** adopts the guild config, **No** keeps local
  defaults and doesn't re-ask that session. (GM / solo skip the prompt.)
- [ ] **Hide-on-leave (C6)**: switching guilds hides the old guild's notes/marks/history/config; the
  new guild starts empty; rejoining restores the first guild's data. (Hard to test without two guilds.)

### v0.27–v0.32 — FEATURE V COMPLETE (readiness border · tally · anon · D/E)
Selftest run **2026-07-04, v0.32.0 → 41 pass / 0 fail / 0 error / 0 skip — all green** (Bankrex-
Dreamscythe, solo). Automated coverage that passed: the pure readiness cascade + status→color map,
the anon gate on voter names, award-reason mapping, disenchanter ordering, the confirm popup + D/E
control, the disenchanter-list render, and the solo E2E (now asserting a lone roller borders **ready**
+ the who-voted list). Manual/visual items the selftest can't reach:

- [ ] **Readiness border** (open a real 2+ player session): rail-row icon border shifts **grey →
  gold → light-green** as responses/votes arrive; an all-passed item borders **blue**; an awarded
  item borders **dark-green**. Header icon stays un-bordered (V4).
- [ ] **Vote tally + who-voted**: "X / Y voted" shows under the item count; hovering it lists who
  voted. Toggle **Anonymous voting** (Session Config) on → the hover reads "Anonymous voting" and
  names never appear, but the count still moves.
- [ ] **D/E award**: with a disenchanter configured + present, the **D/E** button (bottom bar, ML)
  → confirm "Send `<item>` to `<name>` for disenchant?" → Yes trades it + posts "…for D/E" to raid
  chat. With none present, the confirm offers a manual name field.
- [ ] **Disenchanter editor** (Session Config, right column): add names, ▲/▼ reorders priority, ×
  removes; replicates to a second officer.
- [ ] **Award announcements**: normal awards now post "`<item>` was awarded to `<player>` for
  `<reason>`" to raid/party chat (reason = the poll response). *(Announce channel is code-default on;
  its user-facing toggle lands with Feature C's visibility settings.)*

### v0.25–v0.26 — FEATURE G (gear issues) + FEATURE V (voting readiness, in progress)
Selftest run **2026-07-04, v0.26.9 → 38 pass / 0 fail / 0 skip — all green.** (The earlier v0.26.7
run's 2 poll-fixture fails + 1 session-E2E skip are both resolved below.)

- [x] **`GetItemStats` present** on the live client — Feature G's "no comms change" premise holds
  (X3 resolved; item #30056 reported 0 sockets, so the inherent-vs-unfilled socket semantics still
  want a socketed item to confirm, but the API exists and returns a table).
- [x] **Roster module + Gear Check sub-tab render** (renamed from Players); the `config` dataset is
  registered over its live store and covered by the sync digest.
- [x] **2 poll-filter failures — FIXED (bad test fixture, NOT a code bug), v0.26.9.** 30055 is
  *Shoulderpads of the Stranger* (**leather**), not the cloth robe the test assumed — a cloth class
  correctly can't wear it, so the filter was right all along. Fixed the fixture to **30056** (*Robe
  of Hateful Echoes*, the actual universal cloth item) and made the leather case an explicit-class
  assertion. **✓ confirmed green in the v0.26.9 run.** *(Also: the `marks[30055]="give to a mage"` in your DB is a
  stale/wrong note from old testing — clear it with `/lcex mark 30055` if you like; harmless.)*
- [x] **Session E2E ran + PASSED** (v0.26.9, after `/lcex end` cleared the stale session) — the solo
  start→respond→vote→award→end pipeline, which now pre-seeds `session.rows` via `SeedSessionRows`
  (Feature V, V1), works on the live client.
- [ ] **Feature G visual pass**: Roster picker shows a red issue-count badge per player; the Gear
  sub-tab shows per-item tags (No enchant / Empty socket / 50 HP …) in red; the Gear Check sub-tab
  lists offenders worst-first.
- [ ] **Feature V visual pass** (after clearing the stale session + opening a real session): every
  present raider gets a row; rollers on top, "might roll" below, pass/can't-use/missed-kill/left
  dimmed at the bottom showing their reason.

### v0.19–0.24 — THE FOUR-FRAME UI (full rearchitecture) — **selftest + a visual pass**
The five old frames are gone; poll/loot/council/config replace them, plus a minimap button.
Mechanics are covered by `/lcex selftest` (now ~40 checks); the visual/feel items below need
eyes. **Old window positions were reset once** (new layout keys).

- [ ] **Selftest first**: solo, `/lcex selftest`, `/reload`, tell me — I read the report.
- [ ] **Minimap button** (gold coin icon): left-click opens **loot**, right-click **council**,
  ctrl+click **config**; it drags around the minimap; the config checkbox hides/shows it.
- [ ] **Loot window** (`/lcex` or minimap): flat dark look, gold accents. Staging: [Scan bags]
  fills the rail; type an itemID (or shift-click a bag link into the box) + Enter adds it;
  × removes. [Start session] → poll opens, rail badges count responses, click an item → its
  candidate table fills; +/− votes; Award (gold button) records; ✓ badge appears. [End] closes.
- [ ] **Poll** (as any raider): cards stack (max 3), item names quality-colored, response
  buttons per card, note box per card; clicking a response advances the queue INTO the top
  slot (mash one spot to pass all). Items your class can't use never show (check with an
  off-class token in a test session). With a deadline set (council → Session Config), the
  countdown shows and the poll closes at zero.
- [ ] **Council window** (right-click minimap / `/lcex council`): resizes by the corner grip
  (min size respected, no stuck-sizing), remembers size+position; opacity slider (config)
  works. Rail: Loot Browser / Players / History / Session Config, gold bar on the active one.
- [ ] **Browser module**: gold raid bars, indented bosses, quality-colored item names; click
  an item → bottom mark editor targets it; committing a mark shows inline + syncs.
- [ ] **Players module**: picker filters as you type, names class-colored; sub-tabs render
  gear ("(your live snapshot)" for self) / history / profs / BiS (auto-resolves your class) /
  notes (edit + meta line).
- [ ] **History module**: award log newest-first; winner filter box narrows it.
- [ ] **Session Config**: poll-deadline slider ("Off" at 0); council roster — byRank +
  rank cutoff rebuild the list, extras add via box / remove via ×.
- [ ] **Config window** (ctrl+click minimap / `/lcex config`): scale slider rescales the
  windows live; council opacity slider works; loot threshold + self-report toggles persist
  across `/reload`.

### v0.16.0 — ML-disconnect session recovery (DL-6) — **2 clients**
- [ ] A (ML) starts a session → B's frames open. A **`/reload`s**. Within ~95s B prints
  *"Session ML A went quiet — closing the session view"* and the frames close (B isn't stuck).
- [ ] On reload, A prints *"Unfinished session … /lcex resume to re-open, /lcex end to discard"*.
  `/lcex resume` → B's frames re-open (B re-responds); `/lcex end` instead → discarded, nothing re-opens.
- [ ] **Heartbeat:** with A's session left open and untouched, B does **not** time out past 95s
  (the 30s `sPing` keeps it alive). End normally → B closes.

### v0.15.0 — Real P2 loot content — *rendering now auto-tested; one manual spot-check left*
- [ ] Spot-check a couple of P2 item names in `/lcex loot` against what you expect (e.g. Lady
  Vashj drops *Vestments of the Sea-Witch*); flag any wrong name so I can fix the CSV.

### v0.14.0 — Real trade-timer (DL-9) — *needs a real BoP drop; selftest only proves the plumbing*
- [ ] Loot a BoP item, `/reload`, then `/lcex scan` → the item now shows **"~Nm left to trade"**
  (a real countdown), not "looted before reload, no trade timer". If it still says no timer, the
  `BIND_TRADE_TIME_REMAINING` tooltip line didn't parse — tell me the exact tooltip wording.
- [ ] Award that pre-reload item → its owed record carries a real expiry (the "N minutes left"
  warning fires on the true window, and an expired one is pruned).

### v0.13.0 — Stale-cache indicator — *own-snapshot half now auto-tested*
- [ ] Open a **peer's** Gear (and Professions) tab → a grey **"cached Nh ago"** line shows at the
  bottom of the panel (needs a cached `pReport` from a second client).

### v0.12.0 — BiS auto-resolves spec — *own-class half now auto-tested; 2-client half left*
- [ ] Open a **grouped** player who has the addon (e.g. a Fury warrior) → **BiS** tab. The **Spec**
  auto-selects *their* spec (Fury). Cycling Class away and back re-resolves sensibly.
- [ ] Open a council member who's **online but not grouped** with you → their class **and** spec
  still resolve (from their last self-report cached in `gearCache`). `/lcex report` on them first
  if their cache is empty.

### v0.11.0 — Owed-trade persistence (DL-6) — *needs a real `/reload` mid-flow*
- [ ] Award an item to someone (`/lcex test 1` → `/lcex award 1 <name>`), then **`/reload`**. Open
  a trade with that player → the awarded item **still auto-fills** (the owed list survived the
  reload). A second never-awarded item does not.
- [ ] Owed item still in its 2h window after reload → the "N minutes left" warning still fires; an
  item whose window already lapsed during the reload is silently dropped (no false auto-fill).

---

## Passed ✓  (regression reference)
Verified in-game. Bullets document *what* was checked; re-run a section only if its code changes.

### v0.18.x — P1 content + polish batch
- [x] Selftest run 2026-07-02 on v0.18.2: **34/34 PASS** (adds the guild-roster contract check;
  the session E2E now also proves the class-colored council row).
- [x] `/lcex loot` P1 tab: correct items under each boss (user-verified). *Readability flagged —
  see Known rough edges.*

### v0.17.0 — In-game self-test (`/lcex selftest`)
- [x] First run 2026-07-02 (Bankrex-Dreamscythe, build 2.5.5/68101): **33/33 PASS**, 0 fail /
  0 error / 0 skip; live GUILD echo 334ms; solo session E2E clean; zero DB residue. Env facts:
  `GetLootMethod=nil`, `GuildRoster=nil` (→ shim fix), `C_Container` present,
  `GetItemInfoInstant` global, `BackdropTemplateMixin` present. Re-run after any change —
  report is read from SavedVariables automatically.

### Setup
- [x] Folder symlinked into `World of Warcraft\_anniversary_\Interface\AddOns\LootCouncilEX`.
- [x] `/console scriptErrors 1` (or BugSack) on; `/reload` prints `LootCouncil EX: v… loaded.` and **no Lua errors on load**.

### A. Smoke (solo, no group)
- [x] `/lcex` opens/closes the session panel; drag + `/reload` remembers position.
- [x] `/lcex ping` → `Version check sent…` then `Known addon users:` listing you.
- [x] `/lcex test 3` → session line + the candidate **Respond** and **Council** frames open with 3 items.
- [x] Respond: click a response → stays highlighted, chat echoes it, Council row reflects it.
- [x] Council: `+`/`−` adjust the tally (green/red); re-click returns to 0.
- [x] Council: **Award** → `Recorded: <item> → <you>…`. `<`/`>` step between items.
- [x] `/lcex end` (or **End session**) closes both frames; panel shows "No active session".
- [x] Esc-close Respond, then `/lcex respond` reopens it during an active session.

### B. The live loop (2 clients, A = ML, B = candidate)
- [x] Both grouped; `/lcex ping` cross-populates `/lcex version` both ways.
- [x] A `/lcex start` (or **Start session**) → **B's Respond frame opens**; B responds.
- [x] A's chat shows B's response; **A's Council frame fills** (response + competing-gear icon + note).
- [x] Council member B votes `+`/`−`; **A sees the tally update**.
- [x] A **Award** on B's row → `Recorded: <item> → B`; no errors on B. A **End** → B's frames close.

### C. Trade handoff (2 clients, the BoP flow)
- [x] After awarding to B, A opens a trade with B → item **auto-loads** (or clear "drag it in" message; never a stuck cursor).
- [x] Complete → A's pending-trade clears (no false "expired"). Wrong-winner warns `… awarded to B but traded to <other>`.
- [x] Cancel a trade → item stays owed (no false delivery).
- [x] Loot a never-seen-this-session epic → it's tracked (`/lcex scan`) — the uncached-item async fix.

### D. Comms / roster hardening
- [x] Version shows on every interaction (responses/awards fill `/lcex version` without a ping).
- [x] Enter combat while the roster changes → no `vCheck` spam mid-combat.
- [x] Same-realm vs cross-realm names don't break vote/award (name normalization).

### E. Plane B council sync (2 council clients, same guild)
- [x] **Live edit:** A `/lcex dummy foo hello` → B's chat `A updated dummy[foo]`; B's `/lcex dummy` lists it.
- [x] **Offline catch-up:** B logs out, A edits, B logs in → within ~6s `Synced … dummy record(s) from A`; both keys present.
- [x] **Manual trigger:** `/lcex sync` rebroadcasts the digest.
- [x] **LWW:** later `mod` wins; same-second tie breaks by author name (both converge).
- [x] **Gating:** a non-council guildie neither receives nor injects dummy records (`you: not a member`).

### F. Council datasets (notes / marks / history / self-report)
- [x] `/lcex note <p> …` round-trips with `(by <you>)` and survives `/reload`.
- [x] `/lcex mark <id|shift-click> …` round-trips (link form parses the id through spaces).
- [x] `/lcex award` logs history (debug `history += …`); `/lcex history [player]` lists/filters; re-award is idempotent (union).
- [x] `/lcex gear` dumps live slots + professions; `/lcex report` → "broadcast"/"not sent".
- [x] **History auto-log** to B from the `award` broadcast; missed rows catch up on login (union sync).
- [x] **Notes/marks LWW** converge across A/B incl. offline edits.
- [x] **pReport group-gate:** A `/lcex gear <C>` shows a non-council group member C's gear (group-gated, not council-gated).
- [x] **Negative gating:** C's `pSet` (note) is council-gated out on B, but C's `pReport` was accepted — the asymmetry is the point.
- [x] **Anti-swap:** combat-entry gear snapshot defeats a pre-pull swap; out-of-combat swap refreshes it.

### G. Viewer UIs (Phase 6)
- [x] `/reload` → loads with no Lua errors.
- [x] **Loot browser** (`/lcex loot`): phase tab shows raid/boss headers + item rows (icons + names, `(token)` note); edit a mark + Enter persists (`/lcex mark <id>`) and broadcasts; Esc closes.
- [x] **Scroll/offset:** long → short phase never renders empty (FauxScrollFrame reset).
- [x] **Player detail:** candidate-name click (does **not** trigger a vote) / `/lcex player <name>` opens the panel; tabs render from cached data; switching tabs resets the scroll.
- [x] **Notes tab:** edit + Enter persists + (2-client) syncs; "by …, date" updates on reopen.
- [x] **BiS tab:** class auto-resolves to the viewed player's real class; Class button cycles all 9 classes, Spec cycles the class's 3 trees, data-less combos show "No BiS data" (v0.9.8 fix verified).

---

## Known rough edges (expected, not bugs)
- **Loot browser readability** (flagged 2026-07-02): data is accurate but the presentation is
  hard to scan — one flat uncolored list, no hierarchy indent, an inline mark box on every row.
  Redesign pending (quality-colored names, indented raid/boss headers, decluttered marks).
- `/lcex test` on the *first* `/reload` may show `item:NNNNN` for the **pad** items (uncached); real bag items and a second run render correctly.
- ~~The Respond and Council windows both open centered (overlap) until dragged apart once.~~ Fixed v0.18.2 (first-run offsets; saved positions unaffected).
- ~~Council names aren't class-colored yet.~~ Fixed v0.18.1.
