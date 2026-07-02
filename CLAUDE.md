# CLAUDE.md

Guidance for Claude Code (and any AI assistant) working in the **LootCouncil EX**
repository. The authoritative **design / spec is [PROJECT.md](PROJECT.md)** — read it
first every session and treat it as the source of truth for *what* to build. This
file covers *how* to work: target client, API rules, conventions, the git workflow,
testing, and the TBC gotchas that have bitten these addons before.

## What this is

LootCouncil EX is a loot council addon for **World of Warcraft: The Burning Crusade
Classic (Anniversary realms)** — a TBC-native replacement for RCLootCouncil. Pure
Lua 5.1 + embedded Ace3, **no build step**: the repo folder *is* the addon. Symlink
it into `World of Warcraft\_anniversary_\Interface\AddOns\LootCouncilEX` and `/reload`
in-game to test.

- **Addon / folder:** `LootCouncilEX`  ·  **Comms prefix:** `LCEX`  ·  **Slash:** `/lcex`
- **Architecture is two separate data planes** (live ML-authoritative session vs.
  persistent replicated council data). Do not blur them — see PROJECT.md §3.

## Target client

**TBC Classic Anniversary only.** NOT retail, NOT Era, NOT Wrath/Cata Classic.

- Interface version: copy the `## Interface:` number from a known-good installed TBC
  addon's `.toc` (e.g. ArenaSmartStats uses `20505` for patch 2.5.x) rather than
  guessing.
- The client lives under `_anniversary_` (Anniversary runs on the Classic Era client, but
  installs into its own `_anniversary_` folder — not `_classic_era_`).

## API source of truth

- **https://warcraft.wiki.gg/** (successor to wowpedia). Check API version tags;
  prefer pages tagged **"BCC API"** / **"Classic API"**.
- **Never use retail-only APIs.** Common traps: `C_Container.GetContainerItemInfo`
  (use `GetContainerItemInfo`), `C_Spell.*`, `C_Item.*`, `SetShown` (see gotchas).
- **If you're not sure an API exists in TBC, ask — don't guess at signatures or invent
  function names.** Verify against the current Classic client; don't assume it matches
  retail.

## Libraries

LibStub + **Ace3**, embedded under `Libs/` and loaded via `embeds.xml`: AceAddon,
AceEvent, AceComm, AceSerializer, AceConsole, AceDB, AceTimer.

- **Native frames only — no AceGUI.** AceGUI is exactly the "ancient/clunky" feel this
  addon exists to escape. All UI is `CreateFrame` + the shared style layer in
  `UI/Widgets.lua`.
- **All networking goes through AceComm** (`SendCommMessage` / `RegisterComm`) — never
  raw `SendAddonMessage`. Every message is one AceSerializer table envelope
  (PROJECT.md §6).
- **Embedded libs load in dependency order.** In `embeds.xml` / the `.toc`, a lib must
  appear *after* everything it needs: `LibStub` → `CallbackHandler-1.0` → `AceAddon-3.0`
  → the rest. Out-of-order entries leave a lib `nil` at load with no obvious error.
  (Same trap as LibDBIcon → LibDataBroker → CallbackHandler if a minimap button is ever
  added.)

## Conventions

- **Every file opens with a header comment** stating its responsibility and, where
  useful, the data flow / "why". It's how the codebase documents itself — preserve it
  and match the surrounding comment density and section separators.
- **No global pollution.** Everything hangs off the addon table from
  `local addonName, LCEX = ...` (or `local LCEX = LootCouncilEX`); the only intended
  globals are `LootCouncilEX`, `LootCouncilEXDB`, frame names, and slash entries.
- **Name global frames** so they can register for ESC-close via
  `tinsert(UISpecialFrames, "LCEX_FrameName")` (helper in `UI/Widgets.lua`).
- **UI is data-driven**: build response buttons / columns from the `RESPONSES` table,
  never hardcoded (PROJECT.md §6.5).
- **User-facing strings** go through a locale table (`L["..."]`), even if enUS-only for
  now.
- **Stay in phase.** PROJECT.md §7 is a strict phased build map — don't build ahead into
  a later phase's scope.

## Git / version control

**Claude owns version control here.** Handle git yourself, narrate what you did in plain
English, and don't assume the user will run git by hand.

- **`main` is the only long-lived branch.** Solo, private, no releases yet — small
  commits, merged fast, pushed often. No long-lived feature branches.
- **Session start:** `git status` + `git fetch` before touching code. If the tree is
  dirty with changes you didn't make, or local `main` is behind `origin/main`, say so
  and reconcile before building. Never build on a dirty or stale tree.
- **Commit as you go, unprompted** — one logical change per commit, after `luacheck .`
  passes. Don't let work pile up uncommitted.
- **Bump the version in `LootCouncilEX.toc` (`## Version:` line) in the same commit** so
  the in-game version tracks the commit history:
  - New feature → bump **MINOR**, reset PATCH to 0.
  - Everything else (fixes, refactors, docs, chores) → bump **PATCH** by one.
  - **MAJOR** is reserved for breaking releases, bumped by hand.
- **Task done / session end: push.** Work on one machine only is not backed up.
- **Never:** force-push, amend or rebase already-pushed commits, or resolve a conflict by
  silently discarding work. On conflicts, stop and explain the options.
- **Never commit:** WoW `WTF/` / SavedVariables, secrets, packaged `.zip` archives, or
  large binary art.

## Testing

- **In-game (automated): `/lcex selftest`** (`Core/SelfTest.lua`) runs the full in-game
  validation suite solo — API-contract checks against the live client, frame rendering, comm
  loopback, and the solo session pipeline — then persists the report to
  `LootCouncilEXDB.global.selfTest`. After the user `/reload`s, read the report yourself from
  `C:\Program Files (x86)\World of Warcraft\_anniversary_\WTF\Account\*\SavedVariables\LootCouncilEX.lua`
  (pick the newest) and update `docs/TESTING.md`. **When a feature needs in-game validation,
  register its checks in `Core/SelfTest.lua` in the same commit** — tests must clean up every
  DB/frame/timer side effect (ground rules in that file's header).
- **In-game (manual):** only what the self-test can't reach — two-client convergence, real
  trades/loot, `/reload` persistence, visuals. Tracked in `docs/TESTING.md`. After a change,
  the user `/reload`s; Lua errors surface via **BugSack** or `/console scriptErrors 1`.
- When the user pastes an error, **fix the root cause — don't paper over it with defensive
  `nil` checks** to silence the symptom.
- **Lint:** `luacheck .` (config in `.luacheckrc`, Lua 5.1 std, `Libs/` and `References/`
  excluded). WoW ships **Lua 5.1** — avoid 5.1-incompatible idioms in shipped code even if
  your local Lua is newer.
- **Headless:** `lua Tests/run.lua` (mock harness in `Tests/harness.lua`) — pure logic plus
  the self-test *runner* mechanics. Runs in CI on every push.

## TBC Classic API gotchas

These are real bugs that have cost hours in sibling addons. Internalize them.

### `SetShown` does not exist in TBC Classic

`frame:SetShown(bool)` is retail-only. Use explicit `frame:Show()` / `frame:Hide()`
everywhere. `SetShown` doesn't raise a Lua error — it silently does nothing, which makes
it miserable to diagnose.

### Reset FauxScrollFrame offset on every filter/content change

`FauxScrollFrame_GetOffset` reads `frame.offset`, written only by
`FauxScrollFrame_OnVerticalScroll`. `frame:SetVerticalScroll(0)` moves the thumb but does
**not** reset `.offset`. If a stale offset exceeds the new row count, every
`display[offset + i]` is nil and the list renders empty. Reset both:

```lua
scrollFrame.offset = 0
scrollFrame:SetVerticalScroll(0)
-- then repopulate the list
```

(Relevant to VotingFrame and LootBrowser, which are scroll lists.)

### `C_Timer.After` is not reliably backported

Don't use `C_Timer.After` for delays — use **AceTimer-3.0** (`:ScheduleTimer`). Several
zone/name APIs are also locale-sensitive (EN-only today).

### Gear / professions are self-reported only

Blizzard inspection is range/faction/throttle-limited, so gear and professions are
**self-reported over comms** (PROJECT.md §2). `GetAverageItemLevel` is unreliable in
Classic — show the competing-slot item from a snapshot instead. Snapshot own gear on
`PLAYER_REGEN_DISABLED` to defeat pre-pull swaps.

## References

`References/` holds vendored reference addons kept for API examples only.
**NovaInstanceTracker** is the gold-standard addon to consult when unsure how best to
implement something idiomatically in TBC.

## Do not touch

- **`Libs/`** — vendored Ace3 and friends. Bundled; excluded from luacheck. Don't edit or
  lint.
- **`References/`** — vendored reference addons. **Never edit, lint, or search** them as
  project code; they pollute results (duplicate Ace3 trees, etc.).

## When uncertain

**Ask.** Don't guess at API signatures, don't invent function names, and don't build ahead
of the current phase. A quick question beats a silent wrong assumption.
