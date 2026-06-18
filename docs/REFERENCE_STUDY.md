# LootCouncil EX — Reference Study: RCLootCouncil_Classic & Gargul

> Deep-read of the two working reference addons in `../references/` (RCLootCouncil_Classic
> — the addon LCEX replaces — and Gargul) focused on **auto-trading loot** and
> **inter-addon communication**, plus a broader sweep for architectural lessons, mapped
> against [PROJECT.md](../PROJECT.md) and the current `Core/` code.
>
> Method: 12 parallel deep-reader passes over the two codebases grouped into three themes
> (comms / trade-loot / other), each synthesized against the spec, then an executive pass.
> All code references below were re-verified against the actual files. ~1.07M tokens of
> analysis; line/function references are concrete.

---

## Executive summary

The two reference addons — **RCLootCouncil_Classic (RCLC)**, the very addon LCEX
replaces, and **Gargul**, a cleaner native-frame Classic looter — collectively **validate
every core architectural bet LCEX has placed** and supply battle-tested mechanics for the
three hard problems still ahead: trusting inbound comms, handing items off by trade, and
loading item data without showing blank rows. They confirm the **two-plane split** (RCLC's
ML-derived-from-`GetRaidRosterInfo` authority is exactly LCEX's Plane A; its bulk-sync
transport, used as a counter-example, sharpens Plane B), the **trade-from-bags handoff**
(both ship DL-7's exact flow in production), and the **single serialized AceComm envelope**
(both use one prefix + a `cmd`-keyed dispatch table + a version handshake — the precise
skeleton LCEX already has).

The four highest-leverage takeaways:

1. **Derive ML/council authority *locally*** from Blizzard's roster and authorize
   per-handler against the *verified, normalized* sender — never trust comms-asserted
   identity like the name inside `sid`.
2. **Replace the cursor-dance trade fill** with a single `UseContainerItem` guarded by
   `TradeFrame:IsShown()`, and confirm delivery on `UI_INFO_MESSAGE == ERR_TRADE_COMPLETE`,
   never `TRADE_CLOSED`.
3. **Load item data through `Item:CreateFromItemLink():ContinueOnItemLoad`** with a
   synchronous fast-path and a ~0.5s AceTimer safety net, because `GetItemInfo` returns nil
   on first sight and silently drops uncached epics today.
4. **Harden the receive path now** with a one-line `pcall` around dispatch, a
   passively-stamped `ver` on every envelope, and a real semantic version comparator.

Gargul additionally demonstrates the forward-compat answers (correspondenceID RPC,
dual-direction protocol gating) that DL-3/DL-6 will eventually want, while RCLC's
`BackwardsCompat` driver is the migration scaffold LCEX must lay down *before* any
SavedVariables data ships. The review surfaced several concrete bugs in current `Core`
code (below), all in `Award.lua` and the comms receive path, **none structural** — the
foundations are sound, the hardening is mechanical.

---

## Highest-priority findings

| # | Finding | Source | Maps to | Action | Phase |
|---|---|---|---|---|---|
| 1 | Uncached epics silently dropped: `GetItemInfo` returns nil quality on first loot, `CouncilableQuality` returns nil, item never tracked | Gargul `onItemLoadDo`; RCLC | `Award.lua:78-93`, DL-7 | Capture link unconditionally; resolve quality via `ContinueOnItemLoad` + cache fast-path + 0.5s AceTimer | 2 |
| 2 | Trade fill uses fragile `PickupContainerItem`+`ClickTradeButton` cursor dance; `ClickTradeButton` unverified on Anniversary | Gargul `UseContainerItem` | `Award.lua:252-274`, §6.7 | Single `UseContainerItem(bag,slot)` guarded by `TradeFrame:IsShown()`; delete `FirstFreeTradeSlot`; shim `UseContainerItem` | 2 |
| 3 | Delivery inferred from bag absence on `TRADE_CLOSED` (fires on cancel too) → false "delivered", no wrong-winner detection | RCLC `ERR_TRADE_COMPLETE` | `Award.lua:287-298`, §6.7/§6.3 | Register `UI_INFO_MESSAGE`; snapshot links at `TRADE_ACCEPT_UPDATE`; clear only on `ERR_TRADE_COMPLETE`; warn on wrong winner | 2 |
| 4 | `pendingTrades` keyed by winner short-name → 2nd item to same player overwrites 1st; re-award leaves stale auto-fill mapping | RCLC item-keyed store; Gargul | `Award.lua:211`, §6.3 | Key per-award by `uid` (`sid..":"..idx`); make `pendingTrades[partner]` a list; fill all owed on `OnTradeShow` | 2 |
| 5 | Spoofable ML identity: authorizing by the name embedded in `sid` trusts comms-asserted identity | RCLC `IsMasterLooter`/`GetML` trust-anchor | §3, DL-6, future `Session.lua` | When `IsSessionML` lands, resolve ML from `GetRaidRosterInfo`; compare normalized verified sender; `sid` stays identifier only | 3 (design now) |
| 6 | Name comparison false-rejects: bare-vs-`Name-Realm`/casing mismatch silently swallows real ML's `cUpdate`/`vVote` | RCLC `Utils:UnitName`/`UnitIsUnit` | `Roster.lua:24-28`, §6 | Add shared `NormalizeName`/`UnitIsSame` helper; route all sender comparisons through it (prereq for per-handler auth) | 3 (now) |
| 7 | Dispatch not `pcall`-wrapped: one throwing handler kills the receive loop for all later messages | RCLC `FireCmd`; Gargul listener guard | `Comms.lua:74-77` | `local ok,err = pcall(handler, ...)`; log on failure | 1/3 (now) |
| 8 | `pendingTrades` in-memory only → wiped on `/reload`/DC; owed list + timers evaporate | RCLC `ItemStorage` rebuild-on-login | `Award.lua`, `Session.lua:70`, §6.3 | Persist owed record (history row, `received=false`); derive `pendingTrades` on `PLAYER_LOGIN`; closes DL-6 | 4 (flag now) |
| 9 | `versions` reply-only → raiders without addon never appear; §2 violators uncomputable | RCLC `forEachGroupMember` | `Roster.lua:18,74-84`, §2 | `PrintKnownVersions` iterates actual group; show "no addon" after ping window (data now, UI later) | 3 |
| 10 | One-sided protocol gate: drops only higher `v`; an older incompatible peer is silently ignored, council unaware | Gargul dual-direction gate | `Comms.lua:72`, §6 | Stamp `minProtocol`; on older peer surface one-time "outdated" warning | 3 |
| 11 | No `db.version`/migration hook → first post-ship schema change strands user data, cannot retrofit | RCLC `BackwardsCompat`; (Gargul lacks it) | `Init.lua:33-66`, §6.4 | Add `global.dbVersion=1`; lift run-then-stamp driver + `VersionCompare` now, populate migrations from Phase 4 | 3/4 (scaffold now) |
| 12 | Adopt: stamp `ver` on every envelope, record passively before dispatch | Gargul passive version learning | `Comms.lua:32-40`, `Roster.lua:31`, §6 | Add `ver` in `BuildEnvelope`; `RecordVersion(sender,msg.ver)` in `OnCommReceived` | 3 |
| 13 | Adopt: semantic version compare + once-per-`/reload` outdated latch | RCLC `VersionCompare`/`verCheckDisplayed` | `Roster.lua:31-37,74-84` | Port guarded `VersionCompare` (reject `%a+`); add `outdatedWarned` flag | 3 |
| 14 | Adopt: per-handler auth keyed by verified sender (ML-only `sStart`/`cUpdate`/`award`/`sEnd`; council `vVote`; open `cResp`); drop-and-log, no NACK | RCLC `votingFrame.lua` per-handler gates | §3, §6.1, future `Session.lua`/`Council.lua` | Gate inbound handlers by `IsSessionML`/`IsCouncil`; satisfies DL-3 | 3 |
| 15 | Adopt: tooltip-scan real trade timer (`GetContainerItemTradeTimeRemaining`) replacing blind arithmetic + 60s rescan | RCLC + Gargul (both) | `Award.lua:218,314-330`, DL-9 | Hidden tooltip scan of `BIND_TRADE_TIME_REMAINING`; store `seconds+measuredAt`; gate on `C_Item.GetItemGUID` existing | DL-9 refine |
| 16 | Adopt: combat-gate the auto vCheck broadcast | Gargul combat suppression | `Roster.lua:48-55`, `Init.lua:78` | `if UnitAffectingCombat("player") then return end` atop `BroadcastVCheck` | 3 (now) |
| 17 | Adopt: `LibDeflate`+`BULK` pipeline for Plane-B bulk sync (only when payload approaches 255B); skip RCLC's manual push *model* | RCLC Sync transport | §6.2, `Comms.lua:45,70` | Wrap deflate inside envelope serialization, `Encode/Decode` boundary, `pcall` | 4 |
| 18 | Risk: `pHello` `{n,maxMod}` digest + `since=maxMod` delta can miss an old-`mod` edit newer for its key | RCLC re-scans by id (avoids it) | §6.2 sync flow | On count `n` mismatch (not just `maxMod`) request `since=0` full resync | 4 |
| 19 | Adopt: solo WHISPER-to-self fallback in `GroupChannel` for headless testing | Gargul `"GROUP"` pseudo-channel | `Comms.lua:52-61` | Add self-whisper fallback when solo | 2/3 |
| 20 | Adopt: name/realm normalization as shared helper for all Plane-B + roster record keys | RCLC `titleCaseName` | `Roster.lua:31`, §6.2/§6.3 | Normalize every record/roster key identically (`Ambiguate` or append realm) | 4 |

---

## Bugs & risks found in current LCEX code

- **`Award.lua` `OnChatMsgLoot` (78-93) — uncached epics silently dropped.** On the first
  loot of an item this raid, `GetItemInfo(link)` returns nil quality, so `CouncilableQuality`
  returns nil and the epic is never appended to `pendingLoot`. Intermittent, bites precisely
  on fresh kills, defeats DL-7. **Fix:** capture the (already-valid) chat link unconditionally
  and resolve quality via `Item:CreateFromItemLink(link):ContinueOnItemLoad(cb)` with an
  `IsItemDataCached()` fast-path and a ~0.5s AceTimer timeout.
- **`Award.lua` `TryFillTrade` (252-274) — fragile cursor dance.** `PickupContainerItem` +
  `ClickTradeButton` strands the cursor on any mid-sequence failure, races `ITEM_LOCKED`,
  and `ClickTradeButton` is unverified on Anniversary. **Fix:** single
  `UseContainerItem(bag,slot)` guarded by `TradeFrame:IsShown()`; delete `FirstFreeTradeSlot`
  (Blizzard picks the slot); verify by reading `GetTradePlayerItemLink` across slots 1-6.
- **`Award.lua` `OnTradeClosed` (287-298) — false-positive delivery.** Infers handoff from
  bag absence on `TRADE_CLOSED`, which also fires on cancel; banking/mailing/DE'ing the item
  or a coincident bag move falsely marks the award delivered, and a wrong-winner handoff is
  undetectable. **Fix:** register `UI_INFO_MESSAGE`, snapshot `GetTradePlayerItemLink(1..6)`
  at `TRADE_ACCEPT_UPDATE`, clear only on `ERR_TRADE_COMPLETE`, add a wrong-winner warning;
  keep `TRADE_CLOSED` for cleanup only.
- **`Award.lua` `CmdAward` (211) — `pendingTrades` keyed by winner short-name → data loss.**
  A second item owed to one winner overwrites the first; re-awarding an item to a different
  player leaves the original winner's auto-fill mapping live (mis-delivery). **Fix:** key
  per-award by `uid` (§6.3 `sid..":"..idx`), make `pendingTrades[partner]` a list, fill all
  owed items on `OnTradeShow`.
- **`Award.lua` `pendingTrades` (42) / `Session.lua:70` — volatile across `/reload`.** The
  comment claims "pendingTrades outlive the session," but they do not outlive a reload or DC:
  owed list, timers, and auto-fill mappings vanish. **Fix:** persist the owed record to
  SavedVariables at award time and derive `pendingTrades` on `PLAYER_LOGIN`; also closes DL-6.
- **`Award.lua` trade-timer (218, 314-330) — wrong for pre-login items.** `expireAt =
  lootedAt + TRADE_WINDOW` is correct only for items looted while loaded; `CmdScan` already
  admits "no trade timer" for the rest. **Fix (the deferred DL-9):** tooltip-scan
  `GetContainerItemTradeTimeRemaining` with a `measuredAt` anchor; gate on
  `C_Item.GetItemGUID` existing on Anniversary.
- **`Award.lua` `TradePartner` (51) — unsanitized decorated names.** No handling of a
  cross-realm `Name(*)` suffix or secret/empty values, so a decorated partner name fails the
  `pendingTrades` match and auto-fill never fires. **Fix:** strip trailing `(*)`/parens/realm
  before `ShortKey`; ignore secret/empty.
- **`Award.lua` `CmdTest` (349, 364) — test harness lies on first run.** Hardcoded
  `TEST_ITEM_IDS` are the most likely to be uncached on a fresh `/reload`, so the test
  broadcasts wrong qualities/links the first time. **Fix:** pre-warm via
  `Item:CreateFromItemID(id):ContinueOnItemLoad` before building the wire table.
- **`Comms.lua` `OnCommReceived` (74-77) — bare dispatch call.** `handler(self, msg, sender,
  distribution)` is unprotected, so one throwing handler (e.g. a malformed `cUpdate`) kills
  the receive loop for every subsequent message. **Fix:** `local ok, err = pcall(handler,
  ...); if not ok then ...log... end`.
- **`Comms.lua` `OnCommReceived` (72) — one-sided protocol gate (latent).** Drops only a
  higher `v`; an *older* incompatible peer is silently ignored with no user signal. Inert at
  `v=1`, but the day `PROTOCOL_VERSION` bumps to 2, a v1 client just has no handler and
  ignores v2 traffic while the council gets no signal a member can't participate. **Fix:**
  stamp `minProtocol`; warn once when a peer's `v` is below our minimum.
- **`Roster.lua` `IsMe`/comparisons (24-28) — not a general equality predicate (latent).**
  Handles only the same-realm bare case; any future `sender == mlName` or bare `UnitIsUnit`
  will intermittently false-reject the real ML's messages once roster APIs return inconsistent
  realm/casing forms ("my vote/award didn't register"). **Fix:** land the shared
  `NormalizeName` helper before per-handler auth.
- **`Roster.lua` `versions` (18, 74-84) — reply-only roster (gap).** Populated only from
  peers who reply, so a raider without the addon never appears, yet §2 assumes everyone has
  it. **Fix:** iterate the actual group in `PrintKnownVersions` and flag "no addon" after the
  ping window.

---

## Inter-addon communication

LCEX already shares its skeleton with both reference addons: **one AceComm prefix, one
serialized table envelope, a `cmd`-keyed dispatch table, a version handshake.** The deltas
worth acting on are in the *receive* path — sender authorization, version semantics, and
reply fan-out — not the transport.

### What each reference does well, and how

**RCLootCouncil_Classic (RCLC) — authority is derived locally, gated per-handler.** RCLC's
single most important lesson is *where* it puts trust. Every inbound command is authorized
inside its own subscription closure against the **verified sender name**, not in central
middleware (`votingFrame.lua:142-242`): ML-only commands wrap `if
addon:IsMasterLooter(sender) then … else addon.Log:W("Non-ML", sender, …) end`
(`change_response`, `awarded`, `bagged`, `reset_rolls`, `request_votes`, …); the vote
handler gates with `if Council:Contains(Player:Get(sender))` (`votingFrame.lua:144-150`);
candidate-originated commands (`response`, `lootAck`, `roll`) deliberately have **no
guard**. The trust anchor is the key part: `IsMasterLooter(unit)` is purely local —
`self:UnitIsUnit(unit, self.masterLooter)` (`core.lua:2341`), and `self.masterLooter` is
set only by `GetML()`, which loops `GetRaidRosterInfo(i)` for `rank == 2` /
`UnitIsGroupLeader("player")` (`core.lua:2039-2061`). The ML identity comes from
**Blizzard's roster API, never from comms.** A forged `cmd=awarded` from a non-leader
simply fails `IsMasterLooter` and is dropped — silently, with a warning log, no NACK (which
also avoids amplification). Receive ordering is clean and layered: version-major gate →
resolve+normalize sender *once* (`Comms.lua:201`, `addon.Utils:UnitName(sender)`) →
authorize per command. Self-broadcasts are filtered with `UnitIsUnit(sender,"player")`.

RCLC's version subsystem is the model for **quiet scaling**. It uses a *separate* AceComm
prefix `RCLCv` (`Core/Constants.lua:11`) and an "only-newer-peers-reply" handshake: the `v`
receiver runs `CheckOutdatedVersion` and **returns silently if the sender is
same-or-older**, replying `r` only when the sender is *newer* — and then nags itself
(`versionCheck.lua:304-332`). A guild that's fully up to date generates near-zero reply
traffic. `VersionCompare` (`core.lua:2262-2274`) is a real semver compare
(`string.split(".")`, numeric major→minor→patch, nil on non-`x.y.z`), with an anti-tamper
guard rejecting any version containing letters (`strfind(newVersion,"%a+")`). Per-player
version+timestamp persist in SavedVariables, with a one-week purge and a one-day freshness
window. The "you are out of date" line is latched once-per-`/reload`
(`self.verCheckDisplayed`) rather than time-throttled.

**Gargul — request/reply correlation and passive discovery.** Gargul's standout is turning
fire-and-forget comms into addressable RPC. Every message is a `CommMessage` OO instance;
if built with `acceptsResponse=true` it allocates a unique `correspondenceID =
floor(GetTime())..".".."i"` (uniqueness-checked, `CommMessage.lua:74-90`). A recipient
replies via `CommMessage:respond(content)` (a WHISPER carrying the **same**
`correspondenceID`); back on the originator, `processResponse()` appends to
`Box[id].Responses` and fires `onResponse` per reply. One broadcast → N addressed replies,
aggregated by ID. On top sits an application-level ACK: the recipient whispers back the bare
correspondenceID at `"ALERT"` priority (`CommMessage:confirm()`), and the sender arms
`GL:after(3, …)` to fire `onConfirm(false)` if no ACK lands in 3s — a NAK-by-timeout. Gargul
also makes version discovery **passive**: every envelope carries `version` +
`minimumVersion` (short keys `v`/`m`), and `Comm:listen` feeds `Version:addRelease(...)`
for *every* inbound message regardless of action (`Comm.lua:296-299`). It learns the whole
group's version distribution from any traffic at all. Compatibility is gated
**bidirectionally and gracefully** (`Comm.lua:317-351`). Anti-spoof: reject if
`payload.senderFqn` doesn't start with the `playerName` AceComm itself reports
(`Comm.lua:284-294`). A pseudo-channel `"GROUP"` resolves to PARTY/RAID, falling back to
WHISPER-to-self when solo (`CommMessage.lua:47-59`) — free solo testing.

### Where they differ, and which fits LCEX

- **Transport.** Both compress (Gargul: LibSerialize + LibDeflate L5 + EncodeForWoW…; RCLC:
  AceSerializer + LibDeflate L3). LCEX uses **raw AceSerializer, no compression**
  (`Comms.lua:45`). For LCEX's tiny Plane-A envelopes this is correct and one fewer embedded
  lib. Compression only earns its keep once a payload approaches the **255-byte AceComm
  chunk limit** — a full council snapshot or award-history sync on Plane B. *RCLC's choice
  (AceSerializer-compatible, compress only when it pays) fits LCEX better than Gargul's
  wholesale LibSerialize swap,* because §4 fixes AceSerializer and §1 keeps deps minimal.
- **Correlation.** Gargul has full RPC; RCLC does not. LCEX has *session* correlation (`sid`)
  but no per-request correlation — DL-3 accepted "no ACK." For the MVP that stands. Gargul's
  pattern is the concrete answer when DL-3/DL-6 are revisited.
- **Authorization model.** *RCLC's per-handler, locally-derived authority is the exact fit
  for LCEX Plane A* (ML-authoritative, §3). Take RCLC's "derive the ML from
  `GetRaidRosterInfo`, compare the *verified* sender" and Gargul's cheap anti-spoof as
  complementary guards.

### Lessons mapped to LCEX

**Already right — keep:** single prefix + `cmd` dispatch (`Comms.lua:19,74-78`); anti-ping-pong
handshake (`vReply` recorded never answered, `Roster.lua:96-99`); `DebouncedSend`
coalescing (`Comms.lua:86-94`); version-major drop floor (`Comms.lua:72`); silent
drop/no-ACK (DL-3); AceTimer everywhere.

**Adopt now (Phase 3 inbound handlers land here):**

1. **Normalize the sender once**, at the top of `OnCommReceived`. Add a
   `NormalizeName`/`UnitIsSame` helper (~15 lines, no Ace dep; strip spaces,
   `Ambiguate("short")` / append own realm, lowercase-compare) and route **all** sender
   comparisons through it. Replaces the hand-rolled `IsMe` (`Roster.lua:24-28`). **High.**
2. **Per-handler authorization keyed by verified sender, derived locally.** Gate ML-only
   (`sStart`/`cUpdate`/`award`/`sEnd`) with `IsSessionML(sender)`, council-only (`vVote`)
   with `IsCouncil(sender)`, leave `cResp` open. Drop-and-log, no NACK (DL-3). Adopt the
   *design* now even though handlers are Phase 3. **High.**
3. **Stamp `ver` on EVERY envelope; record it passively.** Add `ver = self:GetVersion()` in
   `BuildEnvelope` and call `RecordVersion(sender, msg.ver)` in `OnCommReceived` *before*
   dispatch so even `award`/session traffic feeds the roster (`RecordVersion` is already
   idempotent). **High.**
4. **Combat-gate the automatic broadcast.** `if UnitAffectingCombat("player") then return
   end` atop `BroadcastVCheck` (`Roster.lua:48-55`), since it fires on zone-in and
   `GROUP_ROSTER_UPDATE` (`Init.lua:78`) — a roster-churn burst can hit mid-pull. **High.**
5. **`pcall` the dispatched handler** (`Comms.lua:75`). One throwing handler currently kills
   the receive loop for all subsequent messages. **Medium.**
6. **Semantic version compare + once-per-session out-of-date latch.** Port RCLC's guarded
   `VersionCompare`; add a `self.outdatedWarned` boolean. **High (comparator) / medium (the
   nag UX, needs a surface).**
7. **Solo WHISPER-to-self fallback in `GroupChannel()`** so Phase-2 headless dev round-trips
   without a group. **Medium.**

**Bugs/risks exposed (comms):** spoofable ML identity via `sid` (resolve ML from roster,
not `sid`); name-comparison false-rejects (the `NormalizeName` helper is the prerequisite);
`LCEX.versions` reply-only so "who's missing the addon" is uncomputable (iterate the actual
group).

**Skip / defer:** Skip RCLC `CommsRestrictions.lua` encounter-restriction machinery
(`Enum.AddOnRestrictionType`, `C_RestrictedActions`, `ADDON_RESTRICTION_STATE_CHANGED` —
retail-only, §2 violation). Defer LibSerialize/LibDeflate default codec + short-key envelope
(only if a measured Plane-B sync passes 255B, Phase 4). Defer request/reply correlation +
ACK (DL-3 accepted no-ACK; cheap forward-compat: leave room for an optional `rid` field — it
is the concrete answer to **DL-6**). Defer persistent per-player version history (it's
Plane-B-shaped; fold into Phase-4 GUILD sync's LWW machinery, don't invent a parallel store).
Defer the native group-scan UI (reuse the *patterns* via `UI/Widgets.lua`, not lib-ScrollingTable).
Skip hand-tuned ChatThrottleLib overrides (route through AceComm; pass `BULK`/`ALERT`
priority as a free knob only).

---

## Auto-trade & loot handoff

LCEX's DL-7 flow (ML auto-loots epics to bags, councils later, hands off by trade inside the
BoP 2h window) is structurally identical to what RCLC and Gargul already ship in production.
Both converged on the same answers to the three hard sub-problems — getting an item into an
open trade, knowing the *real* trade-time-remaining, and knowing a trade actually
*completed* — and on every one LCEX's current `Award.lua` takes the weaker path.

### What each reference does well

**Gargul** splits the job into a mechanical trade-window state machine (`TradeWindow.lua`)
and a policy layer (`AwardedLoot.lua`) communicating via custom events:

- **`UseContainerItem(bag, slot)` to add to a trade** (`TradeWindow.lua:618`). One call: when
  a trade window is open, Blizzard places the bag item into the *first free trade slot
  automatically*. No cursor, no `ClickTradeButton`, no free-slot computation.
- **Async one-item-per-frame drain.** `addItem` only `tinsert`s into `ItemsToAdd`; a
  repeating AceTimer (`processItemsToAdd`, line 575) pops one per tick, re-locates the item
  fresh in bags every tick, and guards `if not TradeFrame:IsShown() then cancel` before each
  `UseContainerItem` — because that call *equips or consumes* the item if no trade is open.
- **`ITEM_UNLOCKED` self-healing retry** (line 404). When the server silently bounces a
  too-fast add, the slot unlocks; Gargul recognizes its own recently-added item GUID (≤0.5s
  window) and re-queues it.
- **Success = `UI_INFO_MESSAGE == ERR_TRADE_COMPLETE`** (line 306), never `TRADE_CLOSED`
  (which fires on cancel too, *before* completion).
- **Per-physical-copy identity via `C_Item.GetItemGUID`** keys all owed-item state.

**RCLC** is the closer shape match (same DL-7 trade-from-bags flow):

- **A first-class persisted owed-items store** (`Utils/ItemStorage.lua`, saved in
  `db.profile.itemStorage`), not an ad-hoc table. The TradeUI list is a pure projection
  (`GetAllItemsOfType("to_trade")`). On login `InitItemStorage` rebuilds the live store from
  a bag re-scan — owed trades survive `/reload` and relog.
- **Tooltip-scan of the real trade timer** (`GetContainerItemTradeTimeRemaining`,
  `core.lua:1443`): `SetBagItem` on a hidden tooltip, walk `NumLines()`/`TextLeftN:GetText()`,
  match the localized global `BIND_TRADE_TIME_REMAINING`, reconstruct seconds from
  `INT_SPELL_DURATION_HOURS/_MIN/_SEC`. Stored as `time_remaining + time_updated`,
  re-derived on read. Items looted before load or after relog still show a correct countdown.
- **Reconciliation on `UI_INFO_MESSAGE == ERR_TRADE_COMPLETE`** after snapshotting given
  links at `TRADE_ACCEPT_UPDATE`, plus a **wrong-winner check** (`trade_WrongWinner`).
- **Skip-list when locating the next item** so two copies of one link fill distinct slots.

**Which fits LCEX:** for *getting an item into the trade*, Gargul's `UseContainerItem` is
strictly simpler than RCLC's `PickupContainerItem` + `ClickTradeButton` (what LCEX currently
copies) — adopt Gargul's. For *owed-item modeling and reconciliation*, RCLC's typed
persisted store and explicit `ERR_TRADE_COMPLETE`/wrong-winner handling fit LCEX's
data-plane design better — adopt RCLC's. They agree exactly on the tooltip-scan timer and on
never trusting `TRADE_CLOSED`; both apply.

### Where LCEX already does the right thing

Manual accept only / no auto-`InitiateTrade` (`OnTradeShow` only fills); slots 1-6 only
(`FirstFreeTradeSlot` excludes 7); re-locate by link at trade time, not a cached `{bag,slot}`
(`FindItemInBags` re-scans); AceTimer for the ticker; `ShortKey` strips realm + lowercases;
locale-derived loot prefix (`SELF_LOOT_PREFIX`).

### BUGS / RISKS in current `Award.lua` (priority order)

1. **`TryFillTrade` (252-274) fragile cursor dance.** `PickupContainerItem` +
   `ClickTradeButton` strands the cursor, races `ITEM_LOCKED`, and `ClickTradeButton` is
   unverified on Anniversary. **Fix:** single `UseContainerItem(bag, slot)` guarded by
   `TradeFrame:IsShown()`; add `UseContainerItem` to the `C_Container`-or-global shim block
   (25-28); **delete `FirstFreeTradeSlot`**; verify via `GetTradePlayerItemLink` across 1-6.
2. **`OnTradeClosed` (287-298) infers delivery from bags, wrong event.** `TRADE_CLOSED` fires
   on cancel; "item gone from bags" is ambiguous (banked/sold/DE'd/mailed). **Fix:** register
   `UI_INFO_MESSAGE`; snapshot links at `TRADE_ACCEPT_UPDATE`; clear only on
   `ERR_TRADE_COMPLETE`; add a wrong-winner warning; keep `TRADE_CLOSED` for cleanup only.
3. **`pendingTrades` keyed by winner short-name (211) → silent data loss.** Can't hold two
   items for one winner; re-awarding leaves the old winner's auto-fill live (mis-delivery).
   **Fix:** key per-award by `uid` (§6.3 `sid..":"..idx`); make `pendingTrades[partner]` a
   list; on `OnTradeShow` queue every owed item for that partner.
4. **`pendingTrades` in-memory only → wiped on `/reload`/DC.** `Session.lua:70` comment is
   wrong. **Fix:** write the owed record into SavedVariables (a `global.history` row per §6.3
   with `received=false`) at award time, derive `pendingTrades` on `PLAYER_LOGIN`; unifies
   volatile table + persistent history and answers DL-6.
5. **DL-9 timer is arithmetic, wrong for pre-login items (218, 314-330).** **Fix:** port
   `GetContainerItemTradeTimeRemaining` tooltip scan; store `secondsRemaining +
   measuredAt=GetServerTime()`; let the ticker recompute. Gate on `C_Item.GetItemGUID`
   existing on Anniversary.
6. **`TradePartner` (51) doesn't sanitize decorated names.** Strip trailing `(*)`/parens/realm
   before `ShortKey`; ignore secret/empty.
7. **Nil-quality silent skip on first-seen items (80).** Parse quality from the `|cffXXXXXX`
   color in the link, or defer via `GET_ITEM_INFO_RECEIVED`, rather than dropping. (When loot-
   window detection is added later, prefer `GetLootSlotInfo`'s 5th return, valid even uncached.)
8. **`PlayerIsML` assumes global `GetLootMethod` exists (66-75).** Gargul shims it to
   `C_PartyInfo.GetLootMethod`. **Verify** on Anniversary; shim if absent.

### Prioritized recommendations

**Adopt now (Phase 2 — hardens the heart of `Award.lua`):** #1 single `UseContainerItem` +
delete `FirstFreeTradeSlot`; #2 `ERR_TRADE_COMPLETE` delivery + link snapshot + wrong-winner
warning; #3 re-key owed items per-award, list-per-partner; a lightweight Gargul-style
`ITEM_UNLOCKED` single-item retry; #6 `TradePartner` sanitize; #7 nil-quality fix.

**Adopt now / early Phase 4:** #4 persist owed items, derive `pendingTrades` on login (closes
DL-6). Flag now so the in-memory table isn't cemented.

**Defer to the planned DL-9 refinement:** #5 tooltip-scan timer + `measuredAt` anchor +
`BAG_UPDATE_DELAYED`-driven re-scan (debounced via one reused AceTimer, fire only on change),
keeping `lootedAt` as fallback; re-key per-item state by `C_Item.GetItemGUID`.

**Defer to Phase 3+ (UI):** RCLC's **typed store + UI-as-projection** model (`type` =
`to_trade`/`award_later`/`temp`) is the data shape for the eventual Trade UI / LootBrowser —
build it with `CreateFrame` + `UI/Widgets.lua`, **NOT** AceGUI ScrollingTable (§2). Keep
`pendingTrades` shaped to graduate into it. Multi-item add staggering + skip-list — needed
only once the voting UI can award 2+ items to one person.

**Consciously skip (§1 non-goals):** programmatic gold-in-trade / money-poll / gold overlays
(Gargul's `setCopper` is stubbed by Blizzard anyway; LCEX has no DKP/GDKP — confirms
`Award.lua` is right to be item-only); `GiveMasterLoot`/`GetMasterLootCandidate` and
PackMule's full rule grammar (DL-7 is trade-from-bags; the disenchanter path implies a points
model); RCLC positional-args + LibDeflate comms and Gargul's `SendChatMessage` "items I owe"
broadcast (LCEX is AceComm-only, one versioned envelope — carry `award`/`trade-complete`/
`wrong-winner` as `cmd` values instead). One constraint to carry forward: the
**255-char / ~5-item-links-per-message** chat limit, for any future multi-item chat summary.

---

## Other architectural lessons

Cross-cutting machinery both addons rely on everywhere: async item loading, comms transport,
DB versioning/migrations, event wiring, protocol-version gating.

### 1. Async item loading — highest-value lesson, and a live bug

`GetItemInfo(link)` returns `nil` for every attribute the **first** time the client sees an
item this session. It's not an error — code that reads `quality` and compares `>= 4` simply
treats the item as non-councilable. The TBC-Anniversary fix is the Blizzard Item mixin:
`Item:CreateFromItemLink(link)` → `ItemMixin:ContinueOnItemLoad(callback)`, which fires
immediately if cached, otherwise when server data lands. Both exist and work on Anniversary.

**Gargul does this best** (`Utils/Items.lua`). `GL:onItemLoadDo(Items, callback)` is a
join-barrier loader: `GetItemInfoInstant` first (the **synchronous, never-nil** API) to read
static fields (itemID, equipLoc, classID, icon); `IsItemDataCached()` fast-path resolves
synchronously when cached (the common case mid-raid, no timer); slow path increments a counter
and a `callbackCalled` guard fires the callback exactly once. **The critical TBC lesson — a
0.5s AceTimer safety net** (Items.lua:725-736): `ContinueOnItemLoad` is *not guaranteed to
fire* for an item whose server data never arrives, so a timeout force-completes the entry.
Without it, one bad item deadlocks the whole barrier forever. `normalizeItem` returns `false`,
not a partial record, when the link is still nil — never write a half-populated item.

**RCLC uses cruder strategies** (whole-table re-poll next frame until cached; bounded
20-attempt/50ms retry in `AddItem`). These busy-poll patterns are part of why the Classic
build *feels* janky. Its one good discipline: standardize on `GetItemInfoInstant` for static
fields, reserve `GetItemInfo` for quality/ilvl/bindType. **Which fits LCEX:** Gargul's
`ContinueOnItemLoad` + fast-path + timeout, decisively. Skip RCLC's poll/retry.

- **BUG — `CouncilableQuality` drops uncached epics** (`Award.lua:78`, used in
  `OnChatMsgLoot` 88-93). The first time the ML loots an epic this raid it's uncached,
  `GetItemInfo` returns nil quality, the item is silently dropped — defeating DL-7. The single
  highest-value fix. **Adopt now:** the chat link is already valid — capture it
  unconditionally, resolve quality via `ContinueOnItemLoad` (fast-path + 0.5s timeout), append
  inside the callback.
- **RISK in `ScanBags`** (108-147): synchronous `CouncilableQuality` per slot. Bag items are
  usually cached, but an item picked up seconds before `/lcex start` can read nil and be
  excluded. **Adopt now, cheaply:** collect links first, join on a counter barrier; or schedule
  one retry when a slot *has* a link but quality is nil.
- **Convention:** read equipLoc/classID/icon via `GetItemInfoInstant` (never blocks); only
  `ContinueOnItemLoad`-gate quality/ilvl. Pays off in Phase-6 `PlayerDetail` competing-slot
  comparison (§6.7).
- **`/lcex test` lies on first run** (`CmdTest` 339, 364): hardcoded pad items are the most
  likely uncached on a fresh `/reload`. **Adopt now:** pre-warm via `CreateFromItemID` before
  building the wire table.
- **Defer to Phase 3:** a shared `LCEX:LoadItemsThen(links, cb)` helper. Council members are
  *far* more likely than the ML to have uncached items, so `VotingFrame` MUST async-load the
  `sStart`/`cUpdate` item list before rendering or it shows blank rows — exactly the bug class
  that makes RCLC feel broken. Guard the mixin with `IsItemEmpty()`/`GetItemInfoInstant` or
  `pcall` (`ContinueOnItemLoad` *throws* on an invalid item — RCLC wraps it in `pcall`).

### 2. Bulk-sync transport — adopt the pipeline, reject the model

**RCLC's "Sync"** is mostly a *counter-example*. The **model** is manual, one-peer,
one-direction, popup-gated push of a whole dataset (operator opens a window, picks target +
dataset, clicks Sync; receiver gets a `LibDialog` confirm). Its merge is *not* LWW — history
is union-by-id add-only with no timestamp (author-flagged O(n²)), settings is a blind
key-by-key clobber. This is the opposite of LCEX Plane B (automatic, all-council,
bidirectional, digest+delta, LWW by `mod`; §3/§6.2). **Consciously skip the model wholesale**
— reconciliation must be automatic on login, never a button; this is the RCLootCouncil
clunkiness §1 exists to escape.

**The transport, however, is gold-standard and portable.** Send pipeline:
`AceSerializer:Serialize` → `LibDeflate:CompressDeflate({level=3})` →
`LibDeflate:EncodeForWoWAddonChannel` → `SendCommMessage(prefix, encoded, channel, target,
"BULK", callback)`. AceComm handles 255-byte chunking/reassembly; `BULK` priority routes the
blob *below* live traffic via ChatThrottleLib so it doesn't disconnect the sender; the
`(bytesSent, bytesTotal)` callback drives a progress bar for free. Handshakes go at `NORMAL`.
`EncodeForWoWAddonChannel` is **mandatory** after deflate — deflated bytes (NUL etc.) are
illegal on the addon channel. The two-phase handshake with typed decline reasons (`syncR` →
`syncAck`|`syncNack(reason)`) and the **pluggable `syncHandlers` registry** `{text, send(),
receive(data)}` are both directly applicable — the latter is exactly LCEX's per-dataset
(notes/marks/history/gearCache/profCache) merge shape.

**LCEX today** sends raw AceSerializer text — correct and chunk-safe *now* (no large payload).
LibDeflate is **not** in the embedded lib set.

- **Defer to Phase 4, decide deliberately.** For `pSyncData` (§6.2), either vendor LibDeflate
  (add to `Libs/` + `embeds.xml` in dependency order: `LibStub → CallbackHandler → … →
  LibDeflate`) and send at `BULK` with `CompressDeflate → EncodeForWoWAddonChannel`, or accept
  raw serialized `BULK` for small datasets. Send tiny `pHello`/`pSyncReq` at `NORMAL`. Keep
  the `{v, cmd, sid, …}` envelope — wrap deflate *inside* the payload, after envelope
  serialization. The moment deflate is added, the `Encode`/`Decode` wrap and a `Decode →
  Decompress` receive path become non-optional.
- **Adopt the `syncHandlers` registry pattern in Phase 4**, but write LWW yourself: there is
  **no reusable merge code to lift** from RCLC. notes/marks = greatest-`mod`-wins, ties by
  `by` alphabetically (§6.2); history = union-by-uid (§6.3).
- **Skip** RCLC's `ADDON_RESTRICTION_STATE_CHANGED` / `Enum.AddOnRestrictionType` /
  `C_RestrictedActions` / `C_Secrets` combat-gating — recent-client APIs likely absent/no-op
  on 2.5.x; AceComm `BULK` already protects the link.

- **Design RISK to flag now (Phase 4):** a pure `pHello` digest of `{n, maxMod}` plus a
  `since=maxMod` delta can **silently miss** an edit whose `mod` is older than my `maxMod` but
  newer for *its key*. RCLC sidesteps this only because its history merge re-scans every record
  by id. **Mitigation:** the digest **count `n` mismatch (not just `maxMod`) must also trigger
  a request**, and on a count mismatch request `since=0` (full dataset). The deflate+`BULK`
  transport is cheap, so a full resync on mismatch is affordable. This is an unflagged
  correctness gap in the §6.2 sync flow as written.

- **Smaller transport lessons (adopt now where cheap):** name/realm normalization as a shared
  helper for *every* Plane-B record key and roster key, or LWW merge will fork records across
  `Name` and `Name-Realm`; a 5-second send cooldown / jitter on the login `pHello` (reuse
  `DebouncedSend`) so N council members logging in together don't stampede `pSyncData`; gate
  Plane-B handlers by *membership, not window* — register always-on (LCEX must work headless on
  login) but drop `pSet`/`pHello`/`pSync*` from non-council senders, accept `pReport` from any
  group member (§6.2).

### 3. DB versioning & migrations — scaffold now, before SavedVariables ships data

The sharpest contrast and most load-bearing lesson for Phases 4-5.

**Gargul has essentially no migration system** — a flat `Tables` list aliased live onto
`GL.DB.*`, ad-hoc per-feature nudges, **no `db.version` driving structural upgrades.** Don't
copy this.

**RCLC has the pattern to copy** (`Utils/BackwardsCompat.lua`). `Compat.list` is an *ordered*
array of `{name, version, func}`. `Compat:Run(version)` iterates in order; for each entry
whose `version` is `"always"` or newer than the stored `db.global.version`, and not yet run
this session (`executed` flag), it runs `pcall(v.func, …)`. **`pcall` isolation means a broken
migration logs and continues instead of bricking login.** The driver in `OnEnable` is the
canonical **run-then-stamp** sequence: (a) `if self.db.global.version then Compat:Run(version)`
— runs *before* updating the stored version and **not on first install** (no stored version →
skip, so a clean install never runs migrations); (b) record `oldVersion`; (c) stamp
`db.global.version = version`. `VersionCompare` is a 13-line `string.split` major→minor→patch
numeric comparator — liftable verbatim.

**LCEX today** (`Init.lua:33-66`) declares the full §6.4 schema up front via `AceDB:New(...,
true)` — correct — but there is **no `db.version`, no `oldVersion`, and no migration hook.**

- **Adopt the scaffold NOW (~25 lines), populate migrations from Phase 4.** Add
  `global.dbVersion` to `DB_DEFAULTS` and, in `OnInitialize` right after `AceDB:New`
  (`Init.lua:66`), lift RCLC's three-step driver and `VersionCompare`. **Why before you need
  it:** once notes/marks/history/gear ship to real users' SavedVariables in Phases 4-5, the
  *first* schema change with no migration path silently corrupts or strands their data, and you
  **cannot retrofit a version stamp onto already-shipped DBs that never had one.** Establishing
  `dbVersion = 1` now means every future build migrates cleanly.

### 4. Protocol-version gating — current gate is one-sided (latent risk)

**Gargul stamps every envelope with both `version` and `minimumVersion`** and runs a
**dual-direction gate** on receive: if a sender's `version` < our minimum, warn locally once
per sender that *they* are outdated; if a sender's `minimumVersion` > our version, *we* are too
old — notice and drop. **RCLC keeps version traffic on a separate prefix** (`RCLCv`) so version
checks and sync never contend.

**LCEX's gate is one-sided** — `OnCommReceived` (`Comms.lua:72`) drops only a *higher* protocol
major (`msg.v > PROTOCOL_VERSION`); it does nothing about an *older*, incompatible peer and
never warns the user. Today everything is `v=1` so it's inert. But when `PROTOCOL_VERSION` bumps
to 2, a v1 client's check is false, so it doesn't even drop-with-reason — it just has no handler
and silently ignores v2 session messages, while the v2 council gets no signal a v1 member can't
participate. A member could sit casting votes that never register.

- **Adopt the receive-side warning in Phase 3.** Stamp a `minProtocol` on the envelope; on
  receive, if a peer's `v` < our minimum, surface a one-time "X has an outdated LootCouncil EX"
  warning, bolted onto the Roster `versions` table.
- **Adopt now — `pcall` the dispatch call (one line, high value).** `OnCommReceived`
  (`Comms.lua:74-77`) calls the handler with no `pcall`; a single malformed inbound message
  throws straight out of AceComm's receive path. Most dangerous in Plane A: an exception
  processing one vote must not abort the rest of a `cUpdate`/`cResp` batch.
- **Skip** the numeric-action-enum optimization (Gargul's `Actions=1..32`); string `cmd` is
  more readable and the wire-size difference is negligible. *Note:* if a clean break is ever
  needed that the in-band gate can't handle, bumping `COMM_PREFIX` (`"LCEX"` → `"LCEX2"`) is the
  nuclear hard-fork.

### 5. Event wiring — keep AceEvent; borrow only RCLC's declarative table

**Gargul replaces AceEvent entirely** with a custom multiplexer (one shared frame, refcounted
register/unregister, per-listener `pcall`, a namespaced in-process bus). **RCLC takes the
lighter path:** a declarative `coreEvents = {[EVENT]=MethodName}` table registered in one loop,
plus `RegisterBucketEvent` to coalesce the chatty `GROUP_ROSTER_UPDATE`.

**LCEX today** uses per-module AceEvent directly (`Init.lua:77-78`, `Award.lua:60-62`).

- **Skip Gargul's full multiplexer** — AceEvent already gives refcounting, namespacing-by-
  method, and (once you add the §4 `pcall`) per-listener guarding for free. A custom event
  frame is the over-engineering §1 non-goals push against.
- **Defer to Phase 3, then prefer RCLC's lighter pattern:** a declarative `coreEvents` table +
  single registration loop, so a session *start* registers the batch and a session *end* tears
  the **exact same batch** down — matters for `Candidate.lua`/`Council.lua`/`VotingFrame` wiring.
- **Already correct:** LCEX already debounces `GROUP_ROSTER_UPDATE → vCheck`
  (`Init.lua:96-98`), equivalent to RCLC's `RegisterBucketEvent`; and the loot prefix is
  derived from the localized global `LOOT_ITEM_SELF` (`Award.lua:32`), matching Gargul's locale
  discipline.

---

## What to deliberately skip

- **RCLC `CommsRestrictions.lua` encounter-restriction machinery** — retail/recent-client only,
  likely absent/no-op on 2.5.x Anniversary (RCLC even ships a TBC shim). Violates §2; AceComm
  `BULK` already protects the link. **Skip entirely.**
- **`GiveMasterLoot`/`GetMasterLootCandidate` and PackMule's rule grammar** (SELF/DE/RR/RANDOM,
  disenchanter, round-robin) — DL-7 is trade-from-bags, and the disenchanter path implies a
  points model. Forbidden by DL-7 and the §1 no-points non-goal. **Skip.**
- **Programmatic gold-in-trade / money-poll / GDKP overlays** (Gargul's `setCopper`, stubbed by
  Blizzard anyway) — §1 excludes DKP/EPGP/GP/GDKP. **Skip** (confirms `Award.lua` is right to be
  item-only).
- **RCLC's manual one-peer push *model* of Sync** (operator opens a window, picks target/dataset,
  clicks Sync; union-by-id, no LWW timestamp) — the literal opposite of §3 Plane B. **Skip the
  model wholesale**; borrow only its `BULK`/deflate *transport* and `syncHandlers` *registry*.
- **AceGUI / lib-ScrollingTable list widgets** — forbidden by §2 (native frames only). Reuse the
  *patterns* (store-as-projection, timeout-as-absence, data-driven status color), render via
  `CreateFrame` + `UI/Widgets.lua` with `Show()`/`Hide()` (not `SetShown`) and
  `scrollFrame.offset = 0` resets. **Skip the widgets.**
- **Gargul's full custom event multiplexer** (`Classes/Events.lua`) — AceEvent already provides
  refcounting and per-method namespacing. **Skip** (borrow only RCLC's lightweight declarative
  `coreEvents` table for session-lifecycle wiring).
- **`SendChatMessage` "items I still owe" human-readable broadcast** (Gargul) — LCEX networking
  is AceComm-only, one versioned envelope (§4/§6). Any "still owed" reminder belongs in the award
  flow over AceComm. **Skip.**
- **Numeric action-enum wire optimization** (Gargul's `Actions=1..32`) — string `cmd` is more
  readable and the byte difference is negligible for a guild-sized network. **Skip.**
- **Gargul's `correspondenceID` RPC + ACK-by-timeout** — DL-3 accepted no-ACK for v1; this is the
  concrete future answer to DL-3/DL-6, not a current requirement. **Defer** (cheaply leave room
  for an optional `rid` envelope field), don't build now.

---

## Appendix — method

Generated by a 16-agent fan-out workflow: 12 parallel deep-reader passes (Gargul `Comm`/
`CommMessage`/`Version`/`GroupVersionCheck`/`TradeWindow`/`TradeTime`/`AwardedLoot`/
`DroppedLoot`/`DroppedLootLedger`/`PackMule`/`ItemDataManager`/`bootstrap`/`Events`/`DB`;
RCLC `Services/Comms`/`CommsRestrictions`/`versionCheck`/`TradeUI`/`Sync`/`Utils/Item`/
`Core/Constants`/`core`/`ml_core`), three theme synthesizers mapping against PROJECT.md and the
current `Core/` code, one executive assembler. All cited line/function references were verified
against the actual source.
