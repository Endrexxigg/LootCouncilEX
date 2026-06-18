# LootCouncil EX — Test Checklist

Consolidated in-game test pass for everything built up to **v0.6.0** (Phase 2 trade/loot
hardening, comms/roster hardening, Phase 3 MVP: respond → vote → award → trade). Work through
it in one batch. Tick items as they pass; note failures with the exact error text.

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

## Known rough edges (expected, not bugs)
- `/lcex test` on the *first* `/reload` may show `item:NNNNN` instead of a name for the **pad** items (uncached); real bag items and a second run render correctly.
- The Respond and Council windows both open centered (overlap) until you drag them apart once.
- Council names aren't class-colored yet; "open player detail" is Phase 6.
