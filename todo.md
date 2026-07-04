# todo.md — feature backlog & decisions

Dev-only planning doc. `.pkgmeta`-ignored — never ships in the CurseForge zip.
Status flow per feature: `awaiting answers` → `answers locked` → `specced` (PROJECT.md
written) → `in progress` → `shipped vX.Y.Z`.

Answers were locked **2026-07-03**. Question numbers are preserved so decisions map back to
the original probe. Where an answer superseded a grounding assumption, the change is called
out inline. `X1 = spec-first`, so the next deliverable is PROJECT.md spec sections (§ per
feature) **before** any implementation.

**Proposed build order** (X2 delegated ordering to the agent, by dependency + risk):
**G → V → C → B**, with a small shared-foundations step (guild identity/`guildKey` [X4] +
shared-config channel [X5]) built at the front of **C** and reused by **B**. Rationale:
G is independent + low-risk; V's session-model change (V1) is foundational session polish;
C introduces the guild-scoping + shared-config that **B depends on**; B is largest/highest-risk.

---

## Feature G — Enchant/gem gear issues in the self-report

**Status:** **specced** — PROJECT.md §6.8 + Phase 8 + DL-13 (detection model =
`docs/CLA_gear_issues_findings.md`); v1 = core checks, boss-conditional + meta-gem → v1.1. Ready
to build.

**The ask (user's words):** "make the self report also include enchant and gem data. I'd like
to see each raid member's gear (and gear issues like bad gems/missing enchants) so officers can
identify issues before raid time and send reminders to slackers."

**Grounding (unchanged):** gear is stored as full item links per slot in `gearCache`
(`Core/council/SelfReport.lua:35-42`); links already embed enchant + gem IDs but nothing parses
past the itemID. Empty sockets aren't in the link (only filled gems are) — need `GetItemStats`
EMPTY_SOCKET_* or a tooltip scan. Display today = Players → Gear sub-tab, one selected player,
"slot N: link", no enchant/gem info, no roster overview.

**Decisions (locked):**
- **G1.** Rendering-only / viewer-side (parse links already in `gearCache` + `GetItemStats` for
  sockets) — **no comms/protocol change** — *provided the needed data actually comes through*. If
  `GetItemStats` socket data proves unreliable on the live Anniversary client, fall back to
  reporter-side `pReport` enrichment. (Verify via selftest — X3.)
- **G2.** Adopt the **CLA issue taxonomy** wholesale (`CLA_gear_issues_findings.md` §2), driven by
  **editable data tables** (§4), not hardcoded: `[no enchant]`, `[no gem used]` = empty socket,
  `[bad gem]` = below-rare quality (meta gems exempt), `[bad enchant]`, `[meta gem inactive]`,
  `[useless item]` (boss-conditional). Use in-game exact data, not CLA's WCL heuristics (§1, §6).
- **G3.** Enchant judgment = **per-slot allowlist** of acceptable enchants (doc §6 inversion —
  short, low-maintenance, **fails safe**: unknown/not-listed enchant → flag for review), with WCL
  slot indices remapped to `INVSLOT_*` per §3. **Not** binary present/absent.
- **G4.** **Both** surfaces: enrich the per-player Gear sub-tab with issue tags **and** add a
  roster-wide "Gear Check" overview (every member + issue count — the pre-raid slacker scan).
- **G5.** **Display-only for v1** — no automated reminder/whisper messaging.

**Defaults — CLA sanity-check applied (revisions called out):**
- **Gd1 — REVISED.** Per-item render must show the **CLA issue tags** (one cell per failure,
  `Item name [reason]` style), not just a binary "Enchant ✓/✗" line. Clean items render ✓/plain.
- **Gd4 — REVISED.** Enchant ID→**name** is **not** resolvable via `GetItemInfo`. Use our own
  table labels (the allowlist/blacklist carry enchant names) for named enchants; **gems are items**
  so gem itemID→name/quality resolves via `GetItemInfo`. Arbitrary good-enchant name display via
  tooltip-scan is **deferred**.
- **Gd2** stands, with a note: gem-quality display may use the existing `quality[*]` colors; a
  distinct "suboptimal" (amber/warning) tone vs hard "missing" (danger) is a possible refinement.
- **Gd3, Gd5, Gd6, Gd7** stand. (Gd7 is moot anyway — no legacy data, addon unreleased; see C6.)

**Decision — G-scope (locked):**
- **G-scope.** v1 = the **core three** (enchant allowlist + empty socket + gem quality). The
  **boss-conditional "useless item"** check (undead/demon/PvP-trinket/engi — needs per-encounter
  is-undead/is-demon/is-PvP flag tables + item→condition maps) and **meta-gem activation** are
  **deferred to a v1.1 fast-follow** (largest data lift, independently shippable). Added to the
  Deferred list.

---

## Feature V — Voting-frame award-readiness border (+ session-roster rows, tally, anon, disenchanter)

**Status:** answers locked — **V1 expands the session/candidate model** (rows for all eligible
players); border is **rail-row only**.

**The ask (user's words):** "on the voting frame, add a highlighted border to the item icon if
it's ready to be awarded. … grey = still waiting for responses, blue = d/e waiting, dark green =
awarded, gold = everyone has responded / voting in progress, light green = ready to be awarded."
(+ embedded asks: preferred disenchanter, vote tally / who-voted, anonymous voting.)

**Grounding (unchanged):** rail + header icons are `CreateItemIcon` (no border layer — new
geometry; template = flat-button WHITE8X8 edge). `accent` gold exists; dark/light green + status
blue don't. Responses (`cResp`) vs council votes (`vVote`) are cleanly separated. No readiness
field, no vote tally / who-voted, no anon setting, no disenchant concept — all net-new.

**Decisions (locked):**
- **V1 — CHANGED (expands the session model).** Non-respondents **must have rows**. A session should
  consist of the **full raid group** (TBC 10 or 25). On boss loot, **record who was present at the
  kill and eligible for loot**; when an item enters a session, **add a row for every eligible
  player**. Rows for players who didn't respond are **clearly marked with the reason** (left the
  group, auto-passed on loot they can't use, still-pending, …). *This replaces the deadline-based
  "denominator" approach from V1's original framing — the eligible set is now explicit, so
  "everyone responded" is well-defined.* (Eligibility computable ML-side from `UnitClass` of present
  group members + item type — verify at spec time.)
  **Row set (locked):** the list shows **all present raiders** — everyone at the kill gets a line.
  **All non-roll responses** (pass, ineligible, left group, auto-passed) **sort to the bottom and
  are dimmed**; active rollers sort on top. RCLC behavior throughout.
- **V2.** **No abstain.** Items are typically awarded **without** full votes — the border exists to
  flag "this one's ready, knock it out while others collect votes." "All present council voted" is
  **one** possible ready-reason, **not** a requirement. Awarding is usually sequential by session
  order but not always. **NEW:** keep loot sequencing **chronological — oldest loot first.**
- **V3.** ML computes readiness and **broadcasts a per-item status** (in `cUpdate`) so every client
  renders identical borders.
- **V4.** **Rail-row icons only** — **not** the header/current item (a border on the item you've
  already selected is pointless). *(Overrides the earlier "both/header" default.)*
- **V5.** Preferred disenchanter(s) set in **council settings**; allow **multiple, ranked by sort
  order** (first/top entry = highest). The **highest-ranked disenchanter present in the raid and
  eligible to receive** the item is auto-suggested. **D/E is a special award type with its own
  button** in the loot/voting panel: click → confirm popup "Send to `<disenchanter>` for d/e?" →
  Yes sends, No / click-elsewhere dismisses. RCLC-like award messaging: **"`<item>` was awarded to
  `<player>` for `<reason>`"** where reason = a poll response (BiS/OS/…) **or** a special (D/E).
- **V6.** Add a clean vote tally / who-voted indicator, **RCLC-like** in behavior.
- **V7.** Add an **anonymous-voting** setting; default **OFF**.

**Defaults — veto applied:**
- **Vd1** (WHITE8X8 edge on the icon, colored per state), **Vd2** (new dark-green/light-green/blue/
  grey theme colors; gold = `accent`), **Vd5** (tally uses existing text tones, hidden outside a
  session), **Vd6** (anon default OFF), **Vd7** (disenchanter stored in council/shared config; falls
  back to manual pick if unset/offline) all stand.
- **Vd3** (precedence awarded > ready > d/e > voting > waiting) stands, **applied to rail-row
  borders only** (per V4).
- **Vd4** (no border while staging) stands.

---

## Feature C — Council/officer access control + guild config inheritance

**Status:** answers locked — synced shared config; **loot window also hidden from non-council by
default** (new, C7); no legacy-data migration (addon unreleased).

**The ask (user's words):** "separate council members from other guild members to prevent showing
council-only settings to anyone in the raid. … inherit [an existing guild config] from another
guild member, polling guild on first load. pop up: inherit <Guild> loot council settings from
<Player>? Y/N. … settings will contain officer rank … if user is below officer rank, or not
manually added to the loot council, grey out those settings. … if someone quits the guild, they
should no longer be able to see data for an old guild."

**Grounding (unchanged):** council = single local `profile.council {byRank,rank,extra}`, computed
per-client, never replicated. `GetGuildInfo` never called (no guild name). No role-gated settings;
`SessionConfigModule` editable by anyone. No disabled/greyed control state. All data account-wide
`global`, never guild-scoped; no purge-on-leave. No config-over-comms path exists.

**Decisions (locked):**
- **C1.** **Synced, officer-authored shared guild config** (replicated, LWW) — not a one-time copy —
  with the "inherit … from `<Player>`? Y/N" prompt as first-run onboarding on top of it. (Uses the
  unified shared-config mechanism, X5; resolves DL-1/DL-8.)
- **C2.** **Reuse the existing `AmCouncil()` predicate** — "officer rank" = the `council.rank`
  cutoff, manual adds = `extra`. No parallel "officer" tier.
- **C3.** **Hide** the officer settings module (deadline + roster + rank editor) from non-council;
  personal settings stay visible to all.
- **C4.** Escape hatch: config always editable when you're **guild rank 0 / GM**, OR **no shared
  config exists yet**, OR **solo / not in a guild** (testing) — else nobody could ever set it up.
- **C5.** Inherit from the **highest-ranked / officer** responder to the first-load guild poll,
  named in the prompt. (Accept only from officer-rank senders; prefer highest rank.)
- **C6.** **(a) Guild-scope all council data by `guildKey` and hide non-matching data.** **No legacy
  concerns** — the addon is unreleased, so scope everything by `guildKey` from the start; no
  migration/adoption of old records needed. (Unified `guildKey`, X4.)
- **C7 — NEW (from the C-defaults callout).** The **loot/voting window is NOT visible to non-council
  by default.** Raiders see only the **poll** + **chat messages** when items are awarded, etc. This
  is **configurable** (per-guild shared config) to opt in to making the voting process / loot window
  visible to the whole raid, for guilds that want more transparency.

**Defaults:** all stand (Cd1–Cd6). Note Cd3's greyed-control helper is still needed for personal
settings that depend on state, and for the configurable-visibility toggles.

---

## Feature B — Guild Bank module

**Status:** answers locked — v1 = cache + council/officer annotations + configurable visibility;
withdrawal-request flow and auto-note-prompt **deferred**.

**The ask (user's words):** "include a module for guild bank … cache the guild bank
items/tabs/gold/logs. log entries can be annotated … when multiple log items occur in a short
timespan … display them grouped with item icons and 'x2' … add a setting to toggle a prompt to add
a note upon closing the gbank … add a nice looking hero card … to showcase total gold."

**Grounding (unchanged):** entirely net-new; no guild-bank API used anywhere; module contract
(`RegisterCouncilModule`) + Plane-B `RegisterDataset` are clean insertion points; no hero-card or
icon-count-overlay widget exists; TBC logs are ephemeral/indexed/ID-less and report elapsed time.

**Decisions (locked):**
- **B1.** **Replicate** (Plane B), real-time: officer A withdraws → officer B sees the change.
  *(DEFERRED: a chat print when a gbank sync arrives carrying a gold withdrawal or a new annotation
  — see Deferred list.)*
- **B2.** **Single guild / single server** covers the vast majority — build for that first. Multi-
  guild edge case (a player who's an officer in >1 guild) → allow **switching** between guilds,
  **defaulting to the guild associated with the current character**. (Unified `guildKey`, X4.)
- **B3.** Append-only local **ledger** (capture on open, elapsed→absolute, own IDs, dedup);
  annotations attach at **group** level. (as rec'd)
- **B4.** Group consecutive **same-player + same-action** entries within **5 min**; identical items
  collapse to "xN", distinct items shown side-by-side with a header summary. (as rec'd)
- **B5.** Annotations are **council/officer-only**. Non-council guild members **can** open the gbank
  module, but **default visibility = contents + gold only** (contents are useful for future
  withdrawal requests; gold isn't sensitive). **Logs, notes, annotations, and other sensitive data
  are hidden from non-council by default.** These **visibility rules are configurable** (per-guild
  shared config, X5) since guilds differ. **Withdrawal requests are DEFERRED** — do **not** build the
  request/ping/offline-notification flow in v1.
- **B6.** Auto-scan all viewable tabs on `GUILDBANKFRAME_OPENED`, AceTimer-spaced. (as rec'd)
- **B7.** **DEFER** the automatic close-prompt note flow and any chat reminder. **v1 = the
  transaction-note feature itself** (council/officers annotate transactions). Do **not** build the
  `/lcex gb <note>` prompt-targeting flow in v1 unless separately specced.
- **B8.** Layout = gold **hero card** on top + **tab selector** + **Contents / Log** sub-tabs. (as rec'd)

**Defaults:** stand (Bd1–Bd6), **except** anything implying the automatic transaction-note
prompt/chat reminder → **deferred per B7**. (Bd3 hero-card "cached Nm ago" freshness, Bd4 "xN"
overlay, etc. remain.)

---

## Cross-cutting — Decisions (locked)

- **X1.** **Spec-first** — update PROJECT.md (data-plane placement, new datasets/message types, §5
  file layout, a section per feature) before implementing.
- **X2.** Build order **delegated to the agent** by dependency + risk → **G → V → C → B** with a
  shared-foundations step (`guildKey` X4 + shared-config X5) at the front of C (see top of file).
- **X3.** Live-client API verification via warcraft.wiki.gg **BCC-tagged** signatures + `/lcex
  selftest` API-contract checks the user runs in-game, then the report is read from SavedVariables.
  Applies to: `GetItemStats` sockets (G), all guild-bank APIs (B), `GetGuildInfo` (C).
- **X4.** **One unified `guildKey`** guild-scoping mechanism (from `GetGuildInfo`) shared by C and B.
- **X5.** **One unified shared-config** mechanism carrying council config (C1) + visibility rules
  (B5, C7) + anon flag (V7) + preferred disenchanters (V5) + the deferred response set (DL-8).
- **X6.** New wire messages warrant a `PROTOCOL_VERSION` bump + spec-first §6 updates (ties to X1).
- **Xd1.** Every feature registers `/lcex selftest` checks in `Core/SelfTest.lua` in the same commit.

---

## Deferred / future probes (need more speccing before build)

- **Guild-bank withdrawal requests.** Non-council users request withdrawals from cached contents.
  Full flow needs probing: right-click request UX, request notes, officer pings, minimap
  notification badge, offline-officer notification on next login.
- **Enchant-material request helper.** Integrate mat lists for common enchants: a guildie hits
  "request withdrawal" on enchanting mats → LCEX asks which enchant → autocomplete suggestions →
  the generated request asks for all required mats.
- **Guild-bank sync notification prints (B1).** Print to chat when a gbank sync arrives carrying a
  gold withdrawal or a newly-added annotation.
- **Automatic transaction-note prompt (B7).** The close-prompt-on-gbank-close + chat-reminder flow.
  v1 scope is transaction notes themselves, not the automatic prompt.
- **Enchant-name display via tooltip scan (Gd4).** Showing arbitrary (non-tabled) enchant names.
- **G v1.1: boss-conditional + meta-gem checks.** The CLA "useless item" family (undead/demon/
  PvP-trinket/engi) + meta-gem activation — needs per-encounter flag tables + item→condition maps.
