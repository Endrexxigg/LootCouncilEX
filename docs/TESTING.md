# LootCouncil EX — Test Checklist

> **How this file works.** The **▶ Test next** block at the very top is the *only* thing that
> needs your attention — it lists what changed since the last in-game pass, newest first. When
> you tell me an item passed, I tick it (`[x]`) or move it down into **Passed ✓** (the regression
> reference). Everything under **Passed ✓** is already verified in-game; re-run a section only if
> related code changes.
>
> **Most logic is auto-tested — you don't have to.** Sync merge, digests + directional pull,
> council resolution, name normalization, command parsing, award logging, self-report caching,
> the display builders, and the BiS class/spec resolution all run headlessly in `Tests/run.lua`
> (`lua Tests/run.lua`, and on every push in CI). So this manual list is only for what genuinely
> needs the game: no Lua errors on load, comms delivery, frame rendering, the trade API, and live
> multi-client convergence. If a *logic* bug is suspected, add a case to `Tests/run.lua` first —
> seconds, not a raid night.

---

## ▶ Test next  (newest first)
Changed since the last in-game pass — verify on your next `/reload`, then tell me which passed.

### v0.15.0 — Real P2 loot content (SSC + Tempest Keep)
- [ ] `/lcex loot` → P2 shows **Serpentshrine Cavern** and **Tempest Keep** with their real bosses
  in kill order, each listing real item **names + icons** (not `item:NNNNN`). The five Tier-5
  token drops (Vashj=helm, Leotheras=gloves, Karathress=legs, Void Reaver=shoulder, Kael=chest)
  show a `(token)` annotation.
- [ ] **FauxScrollFrame (now a real long list):** scroll P2 to the bottom, click an empty phase
  tab (P1/P3…), then back to P2 → the list **never renders empty** (offset reset).
- [ ] Spot-check a couple of item names against what you expect (e.g. Lady Vashj drops *Vestments
  of the Sea-Witch*); flag any wrong name so I can fix the CSV.

### v0.14.0 — Real trade-timer (DL-9) — **verify the tooltip parse on Anniversary**
- [ ] Loot a BoP item, `/reload`, then `/lcex scan` → the item now shows **"~Nm left to trade"**
  (a real countdown), not "looted before reload, no trade timer". If it still says no timer, the
  `BIND_TRADE_TIME_REMAINING` tooltip line didn't parse — tell me the exact tooltip wording.
- [ ] Award that pre-reload item → its owed record carries a real expiry (the "N minutes left"
  warning fires on the true window, and an expired one is pruned).

### v0.13.0 — Stale-cache indicator
- [ ] Open a peer's **Gear** (and **Professions**) tab → a grey **"cached Nh ago"** line shows at
  the bottom of the panel. Open **your own** → it reads **"(your live snapshot)"**. The line is
  hidden on the History/BiS/Notes tabs.

### v0.12.0 — BiS auto-resolves spec
- [ ] Open a **grouped** player who has the addon (e.g. a Fury warrior) → **BiS** tab. The **Spec**
  now auto-selects *their* spec (Fury), not just defaulting to the first. Cycling Class away and
  back re-resolves sensibly.
- [ ] Open a council member who's **online but not grouped** with you → their class **and** spec
  still resolve (from their last self-report cached in `gearCache`). `/lcex report` on them first
  if their cache is empty.

### v0.11.0 — Owed-trade persistence (DL-6)
- [ ] Award an item to someone (`/lcex test 1` → `/lcex award 1 <name>`), then **`/reload`**. Open
  a trade with that player → the awarded item **still auto-fills** (the owed list survived the
  reload). A second never-awarded item does not.
- [ ] Owed item still in its 2h window after reload → the "N minutes left" warning still fires; an
  item whose window already lapsed during the reload is silently dropped (no false auto-fill).

### v0.10.0 — DB versioning (invisible)
- [ ] Pure smoke: `/reload` with an existing `LootCouncilEXDB` → no Lua errors, all prior data
  (notes/marks/history) intact. (Migration is a no-op stamp; just confirm nothing breaks.)

---

## Passed ✓  (regression reference)
Verified in-game. Bullets document *what* was checked; re-run a section only if its code changes.

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
- `/lcex test` on the *first* `/reload` may show `item:NNNNN` for the **pad** items (uncached); real bag items and a second run render correctly.
- The Respond and Council windows both open centered (overlap) until dragged apart once.
- Council names aren't class-colored yet.
