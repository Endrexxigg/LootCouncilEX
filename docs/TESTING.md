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
