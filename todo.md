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

## Feature R — RCLC compatibility bridge (Phase 13)

**Status:** **in progress** — specced (PROJECT.md §6.18, DL-24, Phase 13). Amends the §1 non-goal:
RCLootCouncil-installed raiders are now in scope (the no-addon whisper fallback stays out).

**The ask (user's words):** "have LCEX interface with RCLC directly, in the event that a raider
(or an entire raid) has rclc installed but the master looter has LCEX, everyone can still
participate in the session."

**Answers locked (2026-07-07):**
- **R1 — depth: candidates only.** RCLC raiders get their native loot popup + responses land in
  the LCEX table; RCLC council voting is out of scope (they appear as ordinary responders).
- **R2 — direction: LCEX-ML only.** LCEX never acts as an RCLC candidate against an RCLC ML.
- **R3 — buttons: LCEX's own, via RCLC MLdb, built from the live `ResponseSet()`.** Prefer this
  as shipped; **plan for user-configurable buttons (DL-8) coming soon** — the MLdb is built by
  `ipairs` over the session's response set, so custom buttons flow through with no bridge change.

**Build (5 commits, v0.56.x):** (1) spec + vendor `Libs/LibDeflate` + embeds.xml; (2)
`Core/RCLCWire.lua` pure transforms (BuildMLDB/BuildLootTable/MapResponse/GearLinks) + codec +
headless tests; (3) `Core/RCLCBridge.lua` outbound (start/award/end sends, request/reconnect
answers, leader warning) + `profile.rclcBridge` toggle + selftest; (4) inbound
`OnRCLCReceived`→`rclcDispatch`→native `cResp` injection + tests; (5) `docs/TESTING.md` 2-client
section. Wire change ⇒ but **no `PROTOCOL_VERSION` bump** (X6): the LCEX wire is untouched; the
RCLC dialect rides a separate `"RCLC"` prefix.

**Deferred (v1):** un-award + mid-session item adds to RCLC clients (no RCLC message for either);
send-ACK (RCLC's own reconnect/MLdb_request retries heal drops); the reverse direction (R2).

---

## Feature G — Enchant/gem gear issues in the self-report

**Status:** **shipped v0.25.6** (Phase 8) — detection layer (all four checks + CLA blacklist) **and**
the full Roster UI: Players→Roster rename, per-item issue tags in the Gear sub-tab, issue-count picker
badges, and the Gear Check overview sub-tab (offenders worst-first). 275 headless tests; selftest
extended (roster render + `GetItemStats` X3 contract). **Pending in-game validation** (user defers):
`/lcex selftest` + `/reload` to confirm clean load, the `GetItemStats` socket contract, and a visual
pass. Follow-ups in the Deferred list (bad-enchant allowlist, boss-conditional + meta-gem checks).

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
  roster-wide "Gear Check" overview (every member + issue count — the pre-raid slacker scan). **Gear Check is a view inside the Roster tab (the Players module renamed → Roster), not a standalone module.** `GetItemStats` socket reliability is unknown until in-game testing — kept as the primary path with the reporter-side fallback (DL-13).
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

**Status:** **✅ SHIPPED (Phase 9, v0.27.0–v0.32.0)** — all four sub-features complete (border · tally ·
anon + who-voted · D/E). Pending in-game validation (`/lcex selftest` + `/reload` + a 2-client pass).
V1 (through aac6494, v0.26.6): Guild/Config foundations; roster snapshotted at loot time; `session.rows`
pre-seeded per present raider (`SeedRows`, kill-set ∪ current raid) + broadcast; `cResp` preserves
class / clears reason; loot window sorts 3-tier ROLLED > MIGHT ROLL > NOT ROLLING with reason text +
dimming. **Readiness border (v0.27.0, 315 tests):** `Core/session/Readiness.lua` — pure `ReadinessStatus`
cascade (awarded/de/ready/voting/waiting per §6.10) + ML glue (`ComputeItemStatus`, `VotesCastOn`,
`PresentCouncilCount`); status rides `cUpdate.status`, mirrored into `voteStatus`, painted as a per-status
icon border on the rail rows (`StatusColor` + new `Theme.status` colors + `BuildIconBorder`); awarded lights
instantly off the existing award flow. Headless cascade tests + in-game selftest (pure cascade + StatusColor
+ E2E readiness assertion). **Vote tally (v0.28.0):** "X / Y voted" header on the selected item in the loot window
(`status.voted={n,of}` off the broadcast status; hidden outside a session / when no council present;
count shows even under anon). **Anon voting + who-voted list (v0.29.0):** `config.anonVoting`
snapshotted at start → `sStart.anon` → `session/activeSession.anon` (fixed for the session's life);
ML attaches `status.voted.names` (sorted display names via `VotersOn`/`VoterDisplay`) unless anon;
loot-window tally shows a who-voted hover tooltip (or "Anonymous voting"); a shared-config checkbox in
Session Config. **D/E award type (4) — building in 3 commits:** **(A) award-for-reason messaging — DONE (v0.30.0):**
`STATUS.DISENCHANT=93`; `AwardItem(i,name,forcedResp)` carries a forced reason; `AwardReasonText`
(D/E / response text / nil); `AnnounceAward` posts "`<item>` was awarded to `<player>` for `<reason>`"
to group chat when `config.announceAwards` (new shared field, default on) + grouped, else ML-local.
**(B) ranked disenchanter config — DONE (v0.31.0):** Session Config right-column editor (add box +
per-row `n. name` with ▲/▼ reorder + × remove), writing the ranked `config.disenchanters` shared list;
`ResolveDisenchanter` returns the highest-ranked present entry (nil → manual fallback). **(C) D/E button
+ confirm — DONE (v0.32.0):** ML-only **D/E** button (loot-window bottom bar, shares the hidden
start-btn slot) → `LootDisenchantSelected` resolves the disenchanter → new reusable themed
`LCEX:ShowConfirm` popup ("Send `<item>` to `<name>` for disenchant?", or a manual name entry when
none present) → `AwardItem(i, name, STATUS.DISENCHANT)`. **`ShowConfirm` is reused by Feature C's
inherit prompt.** Spec: §6.10, DL-15.

### ✅ Feature V COMPLETE (v0.27.0 → v0.32.0)
All four sub-features shipped: readiness border · vote tally · anonymous voting + who-voted list ·
D/E award type (messaging + ranked disenchanters + button/confirm). Next in the build order: **Feature C**
(Phase 10 — council access control + guild scoping; already specced §6.11 / DL-16). `ShowConfirm` (V)
and the shared `config` dataset (V) are foundations C builds on.

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

### V1 row-set — LOCKED (sub-probe resolved 2026-07-04)

**Direction locked (user):** the voting list should **always include at least everyone present at the
kill**, **plus anyone currently in the raid** (a latecomer's row just reads **ineligible**). "More
data is better." Keep capture simple — the `ENCOUNTER_END` kill-hook was rejected as over-complex.

**Grounding:** no boss-kill event (DL-7 auto-loot; `boss` = `UnitName("target")` at the loot line);
`PresentRoster()` enumerates the current raid → `{name,class}`; `ClassCanUse(link,class)` gives
per-class usability; `session.rows` seeds at `StartSession`, `cResp` merges via `prev=rows[key]`.

**Answers (locked 2026-07-04):**
- **R1** as rec'd — loot-time snapshot = kill set, unioned at vote time with the current raid;
  latecomers → `missedkill`.
- **R2** as rec'd, **fail-open**: flags ineligible + non-default award target, but the ML can always
  override; a bugged/stale snapshot must **never block a legitimate award** (err toward allowing —
  the bigger risk is wrongly blocking an eligible player, not wrongly allowing a rare pug).
- **R3** — three tiers **ROLLED > MIGHT ROLL > NOT ROLLING**; `pending` (might-roll) sits
  **directly below the rollers**, not at the bottom.
- **R4** as rec'd — readiness denominator = eligible + usable + present rows only.
- **R5** as rec'd — accumulate/union, never drop; re-mark leave/rejoin **subtly**.
- **Rd4 (revised):** the two ineligible reasons share one color/style, labeled **"Ineligible (missed
  kill)"** / **"Ineligible (can't use)"**. Rd1 / Rd2 / Rd3 / Rd5 stand.

**Questions as asked (for traceability) — Decisions:**
- **R1.** How the "present at the kill" set is captured, and its granularity. Per-item **loot-time
  snapshot** (who's in the raid when THIS item is looted — per-kill-accurate, auto-loot is seconds
  after the kill) vs a **raid-wide union** (everyone who's been in the raid this session — simpler,
  but not per-kill: someone there for boss 1 but not boss 3 would still show on boss 3's loot).
  *(Recommend: loot-time snapshot = the kill set, unioned at vote time with the current raid →
  latecomers appear as ineligible. Confirm, or say what "present at the kill" should mean.)*
- **R2.** Is "present at the kill" a real **eligibility gate** (missed-the-kill ⇒ cannot be awarded
  that item, shown only for transparency) or just a **display label** (still awardable)? Can the ML
  override? *(Recommend: real gate + ML override.)*
- **R3.** Full row status taxonomy + sort order. Proposed: **rolled** (BiS/Major/Minor/Greed — top,
  by response/votes) · **pending** (eligible, no response yet) · **passed** · **can't use** (at
  kill, item unusable for class) · **ineligible** (in raid now, not at the kill) · **left** (was at
  kill, no longer present). Non-rollers dim to the bottom (RCLC). *(Confirm the set + where
  **pending** sits — with rollers, or at the bottom.)*
- **R4.** Readiness-border denominator: which rows count toward "everyone responded" (gold/blue/
  ready)? *(Recommend: only eligible + usable + still-present rows; ineligible / can't-use / left are
  excluded — they're auto-resolved, not "waiting.")*
- **R5.** Roster churn during a session: **accumulate/union** (never drop a row; re-mark on
  leave/rejoin) vs **live-recompute** each refresh? *(Recommend accumulate + re-mark, per "more data
  is better.")*

**Open — Defaults (veto if wrong):**
- **Rd1.** Rows keyed by normalized name; the kill-set ∪ current-raid union dedupes (one row per person).
- **Rd2.** Pets / guardians / non-player raid entries excluded.
- **Rd3.** The ML gets a row like anyone else (eligible if they can use the item).
- **Rd4.** "Ineligible (missed kill)" and "can't use" are visually distinct labels even though both dim.
- **Rd5.** Realm-suffix normalization (the existing helper) so cross-realm raiders dedupe correctly.

---

## Feature C — Council/officer access control + guild config inheritance

**Status:** **✅ SHIPPED (Phase 10, v0.33.0–v0.36.0)** — all four parts complete; pending a 2-client
in-game pass (non-council hiding, config replication, inherit prompt, guild-switch hide-on-leave).
**(1) Council from shared config — DONE (v0.33.0, resolves DL-1):** `CouncilConfig` (effective read: shared `config` record if authored,
else `profile.council` escape hatch) + `SetCouncilConfig` (atomic byRank/rank/extra write via new
`SetConfigFields`); `ResolveCouncil`, the Session Config roster editor, and `/lcex council add/remove`
all now read/write the replicated config. **(2) Access control — DONE (v0.34.0):** `Core/Access.lua`
(`CanEditConfig` / `CanSeeSessionConfig` / `CanSeeLootWindow` / `LootWindowOptIn` / `MyGuildRank`, C4
escape hatch = solo / GM / no-config-yet); Session Config module hidden from non-council via a
`visible()` predicate on the module contract; loot window gated (session-aware `canSeeLoot` = council
+ opt-in; raiders get the poll only, opted-in raiders get a read-only loot window with no vote +/-);
`config.visibility.lootWindow` toggle in Session Config. *(Greyed-control helper Cd3 deferred — moot
while see==edit for council; add when Feature B's visibility toggles need it.)* **(3) Guild scoping — DONE (v0.35.0):** active-flat + stash model
(`Core/Guild.lua` `SyncGuildScope`) — the active guild's replicated datasets stay in the flat
`db.global.<name>` tables (all ~25 readers unchanged); other guilds stash under
`db.global.guilds[key]`; switching guild swaps them (hide-on-leave). `activeGuild` nil ⇒ one-time
in-place claim of existing data (**no migration, nothing vanishes**); defers while guilded-but-
roster-not-loaded. Runs at OnEnable / GUILD_ROSTER_UPDATE / BuildDigest. **(4) Inherit-on-first-load — DONE (v0.36.0):**
`GateConfigInherit` (Config.lua) holds a first-load peer config as `_pendingInherit` instead of
auto-merging (gate-until-Yes); `ShowConfirm` (now with `onCancel`) asks "Inherit `<Guild>` from
`<Player>`? Y/N"; Yes → `AcceptInherit` (apply verbatim, keep mod/by), No/dismiss → `DeclineInherit`
(keep defaults, stop asking this session; a new guild resets it). Escape hatch: GM / solo / already-
authored auto-merge. Spec: §6.11, DL-16.

### ✅ Feature C COMPLETE (v0.33.0 → v0.36.0)
All four parts shipped: council-from-shared-config (resolves DL-1) · access control (hide Session
Config + loot window from non-council) · guild-scoped datasets with hide-on-leave (active-flat + stash,
no migration) · inherit-on-first-load (gated merge). Next in the build order: **Feature B** (Phase 11 —
Guild Bank; specced §6.12 / DL-17). Reuses `guilds[guildKey]` scoping (C) + `config.visibility` (C7).

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

**Status:** **✅ SHIPPED (Phase 11, v0.37.0–v0.39.0)** — pending a 2-client in-game pass (scan on
open, replication between officers, annotations, non-council log hiding). **(1) Data layer — DONE (v0.37.0):**
`Core/council/Gbank.lua` — three guild-scoped datasets (`gbankCache` lww / `gbankLog` union /
`gbankNotes` lww); pure ledger logic (`GbankNormalizeKind`, `GbankTxnHour` elapsed→absolute hour,
`GbankTxnUid` content-hash, `IngestTxnList` dedup, `BuildGbankGroups` 5-min/xN grouping); accessors
(`GbankGold`/`GbankTabs`/`GbankLogEntries`); live scanner on `GUILDBANKFRAME_OPENED` (throttled
`QueryGuildBankTab`/`QueryGuildBankLog`, debounced `CacheAllTabs`/`IngestAllLogs`, crash-safe money-txn
bound). **All guild-bank APIs verified BCC-tagged on warcraft.wiki.gg (X3)** + a selftest API contract.
Headless tests for the pure logic. **(2) Module UI — DONE (v0.38.0):** `UI/council/GbankModule.lua`
(order 50) — gold **hero card** (`GetCoinTextureString` + "cached Nm ago"), pooled **tab selector**,
**Contents** 14×7 item grid + **Log** grouped-newest-first sub-tabs; added an **"xN" stack overlay** to
`CreateItemIcon` (`SetCount`). Reads only the cache/ledger (works offline; "not cached" empty state).
Selftest render check. **(3) Annotations + visibility — DONE (v0.39.0):** council click-to-annotate a
log group (`gbankNotes` LWW, keyed by lead uid; reuses `ShowConfirm`); `CanSeeGbankLog` gates the Log
sub-tab (council + `config.visibility.gbankLog` opt-in; contents+gold stay public); a "Show the
guild-bank log to all raiders" toggle in Session Config. Withdrawal-request + auto-note-prompt
**deferred** (see Deferred list). §6.12, DL-17.

### ✅ Feature B COMPLETE (v0.37.0 → v0.39.0) — and with it, the WHOLE probe backlog
All four probed features are now shipped: **G** (gear issues, v0.25.x) · **V** (voting readiness,
v0.27–v0.32) · **C** (access control + guild scoping, v0.33–v0.36) · **B** (guild bank, v0.37–v0.39).
Cross-cutting X1–X6 all satisfied. Remaining: 2-client in-game validation passes (per feature, in
TESTING.md) + the Deferred/future-probes list below (withdrawal requests, enchant-mat helper, sync
notification prints, auto note-prompt, enchant-name tooltip, G v1.1 boss-conditional/meta-gem).

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
  **Specced §6.9 (DL-14)** — the `config[guildKey]` LWW dataset; Feature V populates anon +
  disenchanters, C moves in rank/extra/responses, B adds visibility. `guildKey` primitive (X4) also
  specced in §6.9; C does the dataset re-keying (C6).
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
