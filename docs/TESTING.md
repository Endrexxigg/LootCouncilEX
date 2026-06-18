# LootCouncil EX — Test Checklist

> **Most logic is auto-tested — you don't have to.** The pure logic (sync LWW/union merge,
> digests + directional pull, council resolution, name normalization, command parsing, award
> logging, self-report caching) runs headlessly in `Tests/run.lua` — `lua Tests/run.lua` from
> the repo root, and on every push in CI. So this manual checklist is only for what genuinely
> needs the game: **no Lua errors on load, comms delivery, frame rendering, the trade API, and
> live multi-client convergence.** If a logic bug is suspected, add a case to `Tests/run.lua`
> first — it's seconds, not a raid night.

In-game pass for the WoW-dependent behavior. Work through it in one batch; tick items as they
pass; note failures with the exact error text.

## Setup
- [ ] Folder symlinked into `World of Warcraft\_anniversary_\Interface\AddOns\LootCouncilEX`.
- [ ] `/console scriptErrors 1` (or BugSack loaded) so Lua errors surface.
- [ ] `/reload`. **Expected:** chat prints `LootCouncil EX: v0.6.0 loaded.` and **no Lua errors on load**.

## A. Smoke (solo, no group)
- [ ] `/lcex` (bare) opens the **session panel**; `/lcex` again closes it. Drag it, `/reload`, reopen → position remembered.
- [ ] `/lcex ping` → prints `Version check sent…` then `Known addon users:` listing you.
- [ ] `/lcex test 3` → prints a session line, **and** the candidate **Respond** frame + the **Council** frame open with 3 items.
- [ ] In Respond: click a response on a row → it stays highlighted, chat shows `Responded <resp> to <item>` and `<You> responded <resp> to <item>`. The Council frame's row for you shows that response.
- [ ] In Council: `+` on your row → tally shows `1` (green), `+` button highlighted. Click `+` again → back to `0`. `−` → `-1` (red).
- [ ] In Council: click **Award** on your row → chat shows `Recorded: <item> → <you>…`.
- [ ] Council `<` / `>` step between the 3 items (item 2/3 show "No responses yet").
- [ ] `/lcex end` (or the panel's **End session**) closes both frames; panel shows "No active session".
- [ ] Close the Respond frame with Esc, then `/lcex respond` reopens it (while a session is active).

## B. The live loop (2 clients, A = ML, B = candidate)
- [ ] Both in a party/raid. `/lcex ping` on A → B appears in A's `/lcex version`, and vice-versa.
- [ ] A loots (or `/lcex test 2`) and runs **Start session** (panel) or `/lcex start`.
- [ ] **B's Respond frame opens** with the item(s). B clicks responses.
- [ ] A's chat shows `<B> responded <resp> to <item>`, and **A's Council frame fills** with B's row (response + competing-gear icon if applicable + note).
- [ ] If B is on the council (same guild rank ≤ configured, or add B via profile.council.extra): **B's Council frame opens** and shows the table; B votes with `+`/`−`; **A sees the tally update**.
- [ ] A clicks **Award** on B's row → A's chat `Recorded: <item> → B`. B's frames behave (no error).
- [ ] A `End session` → B's frames close.

## C. Trade handoff (2 clients, the BoP flow)
- [ ] After awarding an item to B, A opens a **trade** with B. **Expected:** the awarded item auto-loads into the trade window (or, if it can't, chat says to drag it in manually — never a stuck cursor).
- [ ] Complete the trade. **Expected:** A's pending-trade for that item clears (no false "expired" later). Wrong-winner: if A instead trades the item to someone else, chat warns `Note: <item> was awarded to B but traded to <other>`.
- [ ] Cancel a trade instead of completing → the item stays owed (no false delivery).
- [ ] Loot a fresh epic you've **never seen this session** and confirm it's tracked (`/lcex scan` lists it) — verifies the uncached-item async fix.

## D. Comms / roster hardening
- [ ] Version shows on every interaction (responses/awards from a peer fill `/lcex version` without an explicit ping).
- [ ] Pull a mob (enter combat) while the group roster changes — no `vCheck` spam mid-combat.
- [ ] Same-realm vs cross-realm names don't cause "my vote/award didn't register" (name normalization).

## E. Plane B council sync (Phase 4 proof — 2 council clients, same guild)
Both A and B must be **council**: in the guild at rank ≤ 1 (default `byRank`), or run `/lcex council add <name>` for each other. Verify with `/lcex council` → lists members and shows `you: member`.
- [ ] **Live edit:** both online. A: `/lcex dummy foo hello`. **Expected:** B's chat shows `A updated dummy[foo]`, and B's `/lcex dummy` lists `foo = hello`.
- [ ] **Offline catch-up (the exit criterion):** B logs out. A: `/lcex dummy bar world` (and optionally change foo: `/lcex dummy foo hi2`). B logs back in. Within ~6s **B's chat shows `Synced … dummy record(s) from A`**, and B's `/lcex dummy` now shows both `foo` and `bar` (with `foo = hi2` if changed). No manual step.
- [ ] **Manual trigger:** `/lcex sync` rebroadcasts the digest (use if the 6s login window was missed).
- [ ] **LWW:** A sets `foo=x`, then B sets `foo=y` a moment later → both converge to `y` (the later `mod` wins). Set `foo` on both within the same second → tie breaks by author name alphabetically (deterministic, both agree).
- [ ] **Gating:** a non-council guildie running the addon neither receives nor injects dummy records (their `/lcex dummy` stays empty; `/lcex council` shows `you: not a member`).

## F. Council datasets (Phase 5 — notes / marks / history / self-report)
Both clients council (`/lcex council` → `you: member`), `/lcex debug` on, same guild.

**Solo (one client):**
- [ ] `/lcex note Bob top priority` → `/lcex note Bob` echoes it with `(by <you>)`. `/reload` → still there (SavedVariables).
- [ ] `/lcex mark 30055 give to a mage`, and `/lcex mark <shift-click an item> some text` → `/lcex mark 30055` reads back (link form parses the id even when the item name has spaces).
- [ ] `/lcex test 2` → `/lcex award 1 Bob` → chat shows `Recorded…` **and** debug shows `history += <sid>:1`. `/lcex history` lists it; `/lcex history Bob` filters; re-`/lcex award 1 Bob` → no second history row (union idempotent).
- [ ] `/lcex gear` → dumps your live equipped slots + professions. `/lcex report` → "broadcast" (in guild) or "not sent" (no guild).

**Two clients A+B (grouped, same guild, both council):**
- [ ] **History auto-log:** A `/lcex award 1 <B>` → B's `/lcex history` shows the **same** record (B logged it from the `award` broadcast). Take B offline, A awards another, B back → within ~6s B's `/lcex history` gains the missed row (union sync).
- [ ] **Notes/marks LWW:** A `/lcex note X from A` → B `/lcex note X` shows it. B `/lcex note X from B` a moment later → A's copy updates (greater `mod` wins). Edit while the other is offline → catch-up on login.
- [ ] **pReport group-gate (the key test):** bring in a **non-council** addon user C (in the group). A `/lcex gear <C>` → shows C's cached gear/profs (proves `pReport` is group-gated, not council-gated). Debug on A shows `cached pReport from <C>`.
- [ ] **Negative gating:** C `/lcex note Y blah` → B does **not** pick it up (`/lcex note Y` empty on B) — C's `pSet` is council-gated out. But C's `pReport` **was** accepted (previous step). That asymmetry is the point.
- [ ] **Anti-swap:** C swaps a ring/trinket while in combat → A's cached gear for C still reflects combat-entry gear; an out-of-combat swap on C refreshes it.

## Known rough edges (expected, not bugs)
- `/lcex test` on the *first* `/reload` may show `item:NNNNN` instead of a name for the **pad** items (uncached); real bag items and a second run render correctly.
- The Respond and Council windows both open centered (overlap) until you drag them apart once.
- Council names aren't class-colored yet; "open player detail" is Phase 6.
