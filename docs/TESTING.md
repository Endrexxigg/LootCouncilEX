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

### v0.9.8 — BiS tab class fix
- [ ] Open your **own** character (`/lcex player`, or click your name in the voting frame) → **BiS** tab.
  **Class auto-resolves to your real class** (no longer always "Mage").
- [ ] The **Class** button cycles through **all 9 classes**; **Spec** cycles that class's 3 talent
  trees; **Phase** cycles P1–P5. A class/spec/phase with no data shows
  *"No BiS data for this class/spec/phase."* (only Mage/Fire/P2 has stub data for now).
- [ ] Open a **grouped** non-Mage player → BiS class still auto-resolves to *their* class.

### v0.9.7 — Session frame overflow
- [ ] With **10+** councilable items in your bags, `/lcex` (bare) → the bag preview **scrolls
  inside the frame** (mouse-wheel / scrollbar); **nothing spills past the bottom edge or the
  Start/End buttons**. Switch between a long and short bag list → the list never renders empty
  (FauxScrollFrame offset reset).

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
- [x] BiS tab class auto-resolve — **superseded by the v0.9.8 retest above** (see ▶ Test next).

---

## Known rough edges (expected, not bugs)
- `/lcex test` on the *first* `/reload` may show `item:NNNNN` for the **pad** items (uncached); real bag items and a second run render correctly.
- The Respond and Council windows both open centered (overlap) until dragged apart once.
- Council names aren't class-colored yet.
