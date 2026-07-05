-- ── LootCouncil EX — Tests/run.lua ───────────────────────────────────────────
-- Headless unit tests for the addon's pure logic (sync merge, digests, council resolution,
-- name normalization, command parsing, award logging, self-report caching). No WoW required.
-- Run from the repo root:   lua Tests/run.lua
-- Exits non-zero on any failure (so CI fails the build).

local H = dofile("Tests/harness.lua")
local L = H.LCEX

local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. tostring(msg)) end
end
local function eq(a, b, msg)
    if a == b then pass = pass + 1
    else fail = fail + 1; print(("  FAIL: %s — expected %s, got %s"):format(tostring(msg), tostring(b), tostring(a))) end
end
local function test(name, fn) H.reset(); print(name); fn() end

-- ── Name normalization ───────────────────────────────────────────────────────
test("NormalizeName", function()
    eq(L:NormalizeName("Bob"), "bob", "bare name")
    eq(L:NormalizeName("Bob-Realm"), "bob", "strips realm")
    eq(L:NormalizeName("Bob (*)"), "bob", "strips cross-realm marker")
    eq(L:NormalizeName("BOB"), "bob", "lowercases")
    eq(L:NormalizeName(""), nil, "empty -> nil")
    eq(L:NormalizeName(nil), nil, "nil -> nil")
end)

-- ── DB schema migration (A0) ─────────────────────────────────────────────────
test("MigrateDB stamps version, never downgrades", function()
    L.db.global.dbVersion = nil          -- a pre-versioning / fresh DB
    L:MigrateDB()
    eq(L.db.global.dbVersion, L.DB_VERSION, "unversioned DB stamped to current")
    L:MigrateDB()
    eq(L.db.global.dbVersion, L.DB_VERSION, "already-current DB unchanged")
    L.db.global.dbVersion = L.DB_VERSION + 1 -- written by a newer build
    L:MigrateDB()
    eq(L.db.global.dbVersion, L.DB_VERSION + 1, "newer DB left as-is (no downgrade)")
end)

-- ── LWW merge (the core sync correctness) ────────────────────────────────────
test("MergeRecord lww", function()
    ok(L:MergeRecord("notes", "k", { text = "a", mod = 5, by = "X" }), "first insert changes")
    eq(L.db.global.notes.k.text, "a", "stored")
    ok(not L:MergeRecord("notes", "k", { text = "b", mod = 4, by = "Y" }), "older mod rejected")
    eq(L.db.global.notes.k.text, "a", "unchanged by older")
    ok(L:MergeRecord("notes", "k", { text = "c", mod = 6, by = "Z" }), "newer mod wins")
    eq(L.db.global.notes.k.text, "c", "updated by newer")
    L.db.global.notes.k = { text = "m", mod = 10, by = "M" }
    ok(L:MergeRecord("notes", "k", { text = "a", mod = 10, by = "A" }), "tie: earlier `by` wins")
    eq(L.db.global.notes.k.by, "A", "tie resolved to A")
    ok(not L:MergeRecord("notes", "k", { text = "z", mod = 10, by = "Z" }), "tie: later `by` loses")
end)

-- ── History LWW merge + correction cascade (§6.15, DL-20) ────────────────────
test("History LWW: award → retract → re-award → replay", function()
    -- First award (mod=100).
    ok(L:LogAward("u1", { winner = "Amy", itemID = 1, itemLink = "[X]", ts = 100, by = "ML" }),
        "first award logs")
    eq(L.db.global.history.u1.player, "Amy", "Amy recorded")
    -- Replaying the SAME award (equal mod + by) is idempotent.
    ok(not L:LogAward("u1", { winner = "Amy", itemID = 1, itemLink = "[X]", ts = 100, by = "ML" }),
        "replayed award is a no-op")
    -- Un-award: a retraction with a fresher mod supersedes (LWW).
    ok(L:LogAward("u1", { winner = "Amy", itemID = 1, itemLink = "[X]", ts = 100, mod = 200,
        by = "ML", retracted = true, retractedBy = "ML" }), "retraction (newer mod) wins")
    eq(L.db.global.history.u1.retracted, true, "record now retracted")
    -- An OLDER-mod write can't resurrect the award.
    ok(not L:LogAward("u1", { winner = "Amy", itemID = 1, itemLink = "[X]", ts = 100, mod = 150,
        by = "ML" }), "stale re-award rejected")
    ok(L.db.global.history.u1.retracted, "still retracted")
    -- Re-award with an even fresher mod supersedes the retraction.
    ok(L:LogAward("u1", { winner = "Bob", itemID = 1, itemLink = "[X]", ts = 300, by = "ML" }),
        "re-award (newest mod) wins")
    eq(L.db.global.history.u1.player, "Bob", "new winner recorded")
    eq(L.db.global.history.u1.retracted, nil, "no longer retracted")
end)

-- ── SetRecord stamps + broadcasts ────────────────────────────────────────────
test("SetRecord stamps mod/by and broadcasts pSet", function()
    H.now = 1234
    L:SetRecord("notes", "bob", { text = "hi" })
    eq(L.db.global.notes.bob.text, "hi", "stored")
    eq(L.db.global.notes.bob.mod, 1234, "mod stamped")
    eq(L.db.global.notes.bob.by, "Tester", "by stamped to self")
    eq(#H.sent, 1, "one broadcast")
    eq(H.sent[1].msg.cmd, "pSet", "is pSet")
    eq(H.sent[1].dist, "GUILD", "over GUILD")
end)

-- ── Council resolution ───────────────────────────────────────────────────────
test("ResolveCouncil (extra + byRank + forceSelf)", function()
    L.db.profile.council = { byRank = true, rank = 1, extra = { "Alice" } }
    H.guild = { { name = "Tester", rankIndex = 0 }, { name = "Carol", rankIndex = 1 },
                { name = "Dave", rankIndex = 5 } }
    local set = L:ResolveCouncil(false)
    ok(set["alice"], "extra included")
    ok(set["tester"], "guild GM (rank 0)")
    ok(set["carol"], "guild rank 1")
    ok(not set["dave"], "guild rank 5 excluded")
    ok(not set["tester2"], "stranger absent")

    L.db.profile.council = { byRank = false, extra = {} }
    L._councilSet = nil
    H.guild = {}
    ok(not L:ResolveCouncil(false)["tester"], "no forceSelf -> self not council")
    ok(L:ResolveCouncil(true)["tester"], "forceSelf -> self council")
end)

-- ── Marks command parsing (raw id + shift-clicked link with spaces) ──────────
test("CmdMark parse", function()
    L.db.profile.council = { byRank = false, extra = { "Tester" } } -- be council (no warning)
    L._councilSet = nil
    L:CmdMark("30055 give to a mage")
    eq(L.db.global.marks[30055] and L.db.global.marks[30055].text, "give to a mage", "raw id")
    L:CmdMark("|cffa335ee|Hitem:28830:0:0:0|h[Ring of a Thousand Marks]|r save for the tank")
    eq(L.db.global.marks[28830] and L.db.global.marks[28830].text, "save for the tank",
        "link with spaces in name")
end)

-- ── Browser mark column (Phase 12, item 16) ──────────────────────────────────
test("BrowserMarkText: user mark only, never (token) metadata", function()
    local tokenID = next(L.TierTokens) -- any shipped token
    ok(tokenID ~= nil, "TierTokens data present")
    eq(L:BrowserMarkText(tokenID), "", "token without a mark shows nothing")
    L.db.global.marks[tokenID] = { text = "save for tanks", mod = 1, by = "X" }
    eq(L:BrowserMarkText(tokenID), "save for tanks", "marked token shows the mark text only")
    L.db.global.marks[tokenID] = nil
    eq(L:BrowserMarkText(12345), "", "unmarked item shows nothing")
    -- HasUserMark (item 14): the note indicator fires only on a REAL non-empty mark.
    eq(L:HasUserMark(12345), false, "no mark -> no indicator")
    L.db.global.marks[12345] = { text = "", mod = 1, by = "X" }
    eq(L:HasUserMark(12345), false, "empty mark text -> no indicator")
    L.db.global.marks[12345] = { text = "note", mod = 2, by = "X" }
    eq(L:HasUserMark(12345), true, "real mark -> indicator")
    L.db.global.marks[12345] = nil
end)

-- ── Notes command write + read ───────────────────────────────────────────────
test("CmdNote write + read", function()
    L.db.profile.council = { byRank = false, extra = { "Tester" } }
    L._councilSet = nil
    L:CmdNote("Bob top priority")
    eq(L.db.global.notes["bob"] and L.db.global.notes["bob"].text, "top priority", "written, key normalized")
    H.msgs = {}
    L:CmdNote("Bob")
    ok(H.msgs[1] and H.msgs[1]:find("top priority"), "read echoes the note")
end)

-- ── Award logging (uid + idempotent union) ───────────────────────────────────
test("LogAward -> history", function()
    H.now = 5000
    L:LogAward("Tester-100-1:3", { winner = "Bob", itemID = 30055, itemLink = "[X]",
        ts = 5000, resp = 1, boss = "Gruul" })
    local rec = L.db.global.history["Tester-100-1:3"]
    ok(rec, "history record created")
    eq(rec.player, "Bob", "winner -> player")
    eq(rec.itemID, 30055, "itemID")
    eq(rec.boss, "Gruul", "boss")
    ok(not L:LogAward("Tester-100-1:3", { winner = "Bob", itemID = 30055 }), "re-log idempotent")
end)

-- ── Owed-trade persistence across /reload (A1, DL-6) ──────────────────────────
test("Owed-trade save/restore round-trips and prunes expired", function()
    H.now = 10000
    L.pendingTrades = {
        bob = { { uid = "S:1", link = "[Axe]", itemID = 1, winner = "Bob",
                  expireAt = 10000 + 3600, warned = false, filled = true } },
        amy = { { uid = "S:2", link = "[Bow]", itemID = 2, winner = "Amy",
                  expireAt = 10000 - 1, warned = false } }, -- already lapsed
    }
    L:SaveOwedTrades()
    ok(L.db.global.pendingTrades["tester"], "persisted under the owner key")
    ok(L.db.global.pendingTrades["tester"].bob[1].filled == nil, "transient `filled` not persisted")

    L.pendingTrades = {} -- simulate a /reload wiping the in-memory copy
    L:RestoreOwedTrades()
    ok(L.pendingTrades.bob and #L.pendingTrades.bob == 1, "live debt rebuilt from the DB")
    eq(L.pendingTrades.bob[1].winner, "Bob", "owed record restored")
    ok(not L.pendingTrades.amy, "an already-expired window is pruned on restore")

    L:ForgetAward("S:1")
    ok(not L.pendingTrades.bob, "ForgetAward clears the live copy")
    ok(not L.db.global.pendingTrades["tester"], "and the persisted copy (owner pruned to nil)")
end)

-- ── Real trade-timer (DL-9 / A2) ─────────────────────────────────────────────
test("ParseTradeDuration + TradeExpiry + missing-API fallback", function()
    eq(L:ParseTradeDuration("1 hr 59 min"), 3600 + 59 * 60, "hours + minutes")
    eq(L:ParseTradeDuration("45 min"), 45 * 60, "minutes only")
    eq(L:ParseTradeDuration("30 sec"), 30, "seconds only")
    eq(L:ParseTradeDuration("2 hours"), 2 * 3600, "long unit word")
    eq(L:ParseTradeDuration("soulbound"), nil, "no number -> nil")

    eq(L:TradeExpiry(1000, nil, 9999), 1000 + 7200, "lootedAt anchor wins")
    eq(L:TradeExpiry(nil, 600, 1000), 1600, "measured remaining -> now + remaining")
    eq(L:TradeExpiry(nil, 0, 1000), nil, "zero remaining -> no timer")
    eq(L:TradeExpiry(nil, math.huge, 1000), nil, "unbound (huge) -> no timer")
    eq(L:TradeExpiry(nil, nil, 1000), nil, "nothing -> no timer")

    eq(L:FormatDuration(3900), "1h 5m", "h+m render")
    eq(L:FormatDuration(720), "12m", "minutes render")

    -- BIND_TRADE_TIME_REMAINING absent in the headless env → the scan declines gracefully.
    eq(L:ItemTradeTimeRemaining(0, 1), nil, "no API/string -> nil (fallback)")
end)

-- ── Trade timers (§6.17, DL-22 — pure helpers) ───────────────────────────────
test("TradeBarColor: green ≥60%, gold ≥30%, red below", function()
    eq(L:TradeBarColor(7200, 7200), L.Theme.success, "full window -> green")
    eq(L:TradeBarColor(4400, 7200), L.Theme.success, "≥60% -> green")
    eq(L:TradeBarColor(3000, 7200), L.Theme.accent, "≥30% -> gold")
    eq(L:TradeBarColor(600, 7200), L.Theme.danger, "<30% -> red")
    eq(L:TradeBarColor(nil, 7200), L.Theme.danger, "nil remaining -> red")
end)

test("_TradeKeyFor: GUID exact, else bucketed expiry + ordinal", function()
    eq(L:_TradeKeyFor(100, 5000, "abc", 0), "g:abc", "GUID wins when present")
    -- 4920 and 5000 both fall in the [4920, 5040) 120s bucket.
    eq(L:_TradeKeyFor(100, 4920, nil, 0), L:_TradeKeyFor(100, 5000, nil, 0),
        "same 120s bucket -> same fallback key")
    ok(L:_TradeKeyFor(100, 4920, nil, 0) ~= L:_TradeKeyFor(100, 5040, nil, 0),
        "next bucket -> different key")
    ok(L:_TradeKeyFor(100, 5000, nil, 0) ~= L:_TradeKeyFor(100, 5000, nil, 1),
        "ordinal disambiguates a same-bucket collision")
end)

test("_ReconcileTradeEntries: inherit stable keys across drift", function()
    local prev = { { key = "k1", itemID = 100, expireAt = 5000, guid = "g1" },
                   { key = "k2", itemID = 100, expireAt = 5000 } }
    -- GUID match despite a big expiry drift; itemID+near-expiry match for the GUID-less one.
    local scanned = { { key = "new1", itemID = 100, expireAt = 4000, guid = "g1" },
                      { key = "new2", itemID = 100, expireAt = 5090 } }
    L:_ReconcileTradeEntries(prev, scanned)
    eq(scanned[1].key, "k1", "GUID match inherits the prior key")
    eq(scanned[2].key, "k2", "itemID + |Δexpire|≤180 inherits the prior key")
    -- A far-off expiry with no GUID is a NEW item (keeps its own key).
    local scanned2 = { { key = "fresh", itemID = 100, expireAt = 9999 } }
    L:_ReconcileTradeEntries(prev, scanned2)
    eq(scanned2[1].key, "fresh", "expiry beyond the window -> not matched")
end)

test("_AnnotateTradeWinners: greedy expiry pairing per link", function()
    local entries = { { link = "[Tok]", itemID = 1, expireAt = 200 },
                      { link = "[Tok]", itemID = 1, expireAt = 100 },
                      { link = "[Solo]", itemID = 2, expireAt = 300 } }
    local owed = { amy = { { link = "[Tok]", winner = "Amy", expireAt = 90 } },
                   bob = { { link = "[Tok]", winner = "Bob", expireAt = 250 } } }
    L:_AnnotateTradeWinners(entries, owed)
    -- Both sides sort by expiry: earliest [Tok] (100) ↔ Amy (90); later [Tok] (200) ↔ Bob (250).
    local byExpire = {}
    for _, e in ipairs(entries) do byExpire[e.expireAt] = e.winner end
    eq(byExpire[100], "Amy", "earliest copy owed to the earliest winner")
    eq(byExpire[200], "Bob", "later copy owed to the later winner")
    eq(byExpire[300], nil, "un-owed loot stays blank")
end)

-- ── ML-disconnect session recovery (A3, DL-6; persistence v2 §6.16) ──────────
test("Session persist → restore → resume → end (rows/votes/awards survive)", function()
    L.sessionItems = { { link = "[Axe]", itemID = 1, quality = 4 } }
    L:StartSession({ { link = "[Axe]", quality = 4 } })
    local sid = L.session.sid
    ok(L.db.global.session.tester, "open session mirrored to the DB under the owner")
    eq(L.db.global.session.tester.sid, sid, "stored sid matches")

    -- Collect a response + votes + an award — all held BY REFERENCE in the DB mirror (§6.16).
    L.session.rows[1] = L.session.rows[1] or {}
    L.session.rows[1]["bob"] = { name = "Bob", class = "WARRIOR", resp = 1, votes = 2 }
    L.session.voters[1] = { bob = { tester = 1, amy = 1 } }
    L.activeSession.awarded = { [1] = "Bob" }
    L:SaveSession()
    eq(L.db.global.session.tester.rows[1]["bob"].resp, 1, "response mirrored by reference")
    eq(L:CountSavedResponses(L.db.global.session.tester), 1, "resume dialog counts one response")

    -- Simulate a /reload: in-memory session gone, DB record remains.
    L.session, L.sessionItems, L.activeSession = nil, nil, nil
    L:RestoreSession()
    ok(L.recoverableSession, "restore finds the persisted session and offers resume")

    ok(L:ResumeSession(), "resume succeeds")
    eq(L.session.sid, sid, "resumed with the SAME sid (history uids stay stable)")
    ok(L.sessionItems and L.sessionItems[1].link == "[Axe]", "ML award records restored")
    -- The collected aggregate survived the reload (seed → overlay).
    eq(L.session.rows[1]["bob"].resp, 1, "saved response survived resume")
    eq(L.session.rows[1]["bob"].votes, 2, "saved votes survived resume")
    ok(L.session.voters[1] and L.session.voters[1].bob, "per-voter map restored")
    eq(L.activeSession.awarded[1], "Bob", "saved award survived resume")
    ok(not L.recoverableSession, "recoverable cleared after resume")

    L:EndSession()
    ok(not L.db.global.session.tester, "end clears the persisted session")
end)

-- Overlay merge (§6.16): saved responses win; a seeded non-responder keeps its reason; a saved
-- responder missing from the seed re-enters "left".
test("_OverlaySavedRows: saved wins, non-responder kept, missing → left", function()
    local seeded = {
        amy = { name = "Amy", class = "MAGE", reason = "pending", votes = 0 },
        cid = { name = "Cid", class = "ROGUE", reason = "pending", votes = 0 },
    }
    local saved = {
        amy = { name = "Amy", resp = 1, note = "n", votes = 3 }, -- responded before the reload
        bob = { name = "Bob", resp = 2, votes = 1 },             -- responded then LEFT the raid
    }
    local out = L:_OverlaySavedRows(seeded, saved)
    eq(out.amy.resp, 1, "saved response overlays the seed")
    eq(out.amy.reason, nil, "responder's reason cleared")
    eq(out.amy.votes, 3, "saved votes win")
    eq(out.cid.reason, "pending", "seeded non-responder keeps its reason")
    ok(out.bob ~= nil and out.bob.resp == 2, "saved responder missing from the seed re-enters")
end)

test("Recoverable session can be discarded with /lcex end", function()
    L.db.global.session.tester = { sid = "S", items = { { link = "[X]", quality = 4 } }, council = {} }
    L:RestoreSession()
    ok(L.recoverableSession, "offered for recovery")
    L:EndSession() -- no live session → discards the recoverable one
    ok(not L.recoverableSession and not L.db.global.session.tester, "discarded from memory + DB")
end)

test("Candidate watchdog closes a dropped ML's session", function()
    L:EnterSession("S1", "OtherML", { { link = "[X]", quality = 4 } }, L.RESPONSES, {})
    ok(L.activeSession, "entered a remote session")
    ok(L.sessionTimeout, "watchdog armed for a remote ML")
    L:OnSessionTimeout()
    ok(not L.activeSession, "timeout closes the stale session view")

    -- The ML's OWN client never watchdogs itself.
    L:EnterSession("S2", "Tester", { { link = "[X]", quality = 4 } }, L.RESPONSES, {})
    ok(not L.sessionTimeout, "no watchdog when we are the session ML")
    L:LeaveSession("S2")
end)

-- ── Candidate rejoin (§6.16 sReq/sJoin) ──────────────────────────────────────
test("sReq: unknown-sid sPing triggers one throttled rejoin request", function()
    L.activeSession, L._sReqAt = nil, nil
    L.dispatch.sPing(L, { sid = "S9" }, "BossML")
    eq(#H.sent, 1, "one sReq whispered on an unknown-sid ping")
    eq(H.sent[1].msg.cmd, "sReq", "the request is sReq")
    eq(H.sent[1].dist, "WHISPER", "sent by whisper")
    eq(H.sent[1].target, "BossML", "whispered to the pinging ML")
    L.dispatch.sPing(L, { sid = "S9" }, "BossML")
    eq(#H.sent, 1, "a repeat ping within the throttle window sends nothing")
    L.activeSession = { sid = "OTHER", ml = "X" }
    L.dispatch.sPing(L, { sid = "S9" }, "BossML")
    eq(#H.sent, 1, "viewing another session -> no request")
    L.activeSession = nil
end)

test("sJoin: enter, merge same-sid awarded, never supersede a different session", function()
    L.activeSession = nil
    L.dispatch.sJoin(L, { sid = "S9", items = { { link = "[X]", quality = 4 } },
        responses = L.RESPONSES, council = {}, awarded = { [1] = "Amy" } }, "BossML")
    ok(L.activeSession and L.activeSession.sid == "S9", "entered the session from sJoin")
    eq(L.activeSession.ml, "BossML", "ML bound to the sJoin sender (DL-11)")
    eq(L.activeSession.awarded[1], "Amy", "awarded snapshot applied")
    L.dispatch.sJoin(L, { sid = "S9", items = { { link = "[X]", quality = 4 } },
        responses = L.RESPONSES, council = {}, awarded = { [2] = "Bob" } }, "BossML")
    eq(L.activeSession.awarded[2], "Bob", "same-sid sJoin merges more awards")
    L.dispatch.sJoin(L, { sid = "OTHER", items = { { link = "[Y]", quality = 4 } },
        responses = L.RESPONSES, council = {} }, "OtherML")
    eq(L.activeSession.sid, "S9", "a different live session is never superseded")
    L:LeaveSession("S9")
end)

test("dispatch.sReq: ML whispers back sJoin + per-leader cUpdate", function()
    H.inRaid, H.group = true, { "Amy", "Tester" }
    L.sessionItems = { { link = "[X]", itemID = 1, quality = 4 } }
    L:StartSession({ { link = "[X]", quality = 4 } })
    H.sent = {} -- ignore the sStart from StartSession
    L.dispatch.sReq(L, { sid = L.session.sid }, "Amy")
    ok(#H.sent >= 1, "ML replied to sReq")
    eq(H.sent[1].msg.cmd, "sJoin", "first reply is the sJoin snapshot")
    eq(H.sent[1].dist, "WHISPER", "sJoin whispered")
    eq(H.sent[1].target, "Amy", "sJoin to the requester")
    ok(H.sent[1].msg.items and #H.sent[1].msg.items == 1, "sJoin carries the item list")
    local sawUpdate = false
    for _, e in ipairs(H.sent) do
        if e.msg.cmd == "cUpdate" and e.target == "Amy" then sawUpdate = true end
    end
    ok(sawUpdate, "ML followed with a whispered cUpdate")
    H.sent = {}
    L.dispatch.sReq(L, { sid = "nope" }, "Amy")
    eq(#H.sent, 0, "foreign sid -> no reply")
    L:EndSession()
end)

test("PlayerIsML tracks loot when grouped (Anniversary has no master-loot API)", function()
    -- GetLootMethod is removed on the Era/Anniversary client (nil here too) — PlayerIsML must
    -- nil-guard it and fall back to IsInGroup, not crash.
    H.group = {}
    ok(not L:PlayerIsML(), "solo / ungrouped -> don't track")
    H.group = { "Ally", "Mate" }
    ok(L:PlayerIsML(), "grouped -> track our own loot")
end)

-- ── pReport caching: group-gated, NOT council-gated (§6.2) ────────────────────
test("pReport caches gear from a group member (group-gated)", function()
    H.group = { "Carol" }
    L.dispatch.pReport(L, { gear = { [1] = "headlink" }, profs = { Tailoring = 300 }, mod = 2000 }, "Carol")
    ok(L.db.global.gearCache["carol"], "cached gear")
    eq(L.db.global.gearCache["carol"].items[1], "headlink", "gear items")
    eq(L.db.global.gearCache["carol"].by, "Carol", "by = sender (not me)")
    eq(L.db.global.profCache["carol"].profs.Tailoring, 300, "profs cached")

    H.group = {} -- not grouped with this sender
    L.dispatch.pReport(L, { gear = { [1] = "x" } }, "Stranger")
    ok(not L.db.global.gearCache["stranger"], "non-group sender dropped")
end)

-- ── pHello directional pull (regression guard for the merge-direction bug) ───
test("pHello: pull when peer ahead, hello-back when we're ahead", function()
    L.db.profile.council = { byRank = false, extra = { "Tester", "Peer" } }
    L._councilSet = nil

    -- Peer ahead: we hold 1 dummy record (mod 5); peer advertises n=2, maxMod=10.
    L.db.global.dummy["a"] = { mod = 5 }
    L.dispatch.pHello(L, { digest = { dummy = { n = 2, maxMod = 10 } } }, "Peer")
    eq(#H.sent, 1, "exactly one message")
    eq(H.sent[1].msg.cmd, "pSyncReq", "peer ahead -> request a delta")
    eq(H.sent[1].msg.since, 5, "request since our maxMod")

    -- We ahead: 2 records (maxMod 10); peer advertises n=1, maxMod=5. Must NOT pull; hello back.
    H.sent = {}
    L.db.global.dummy["b"] = { mod = 10 }
    L.dispatch.pHello(L, { digest = { dummy = { n = 1, maxMod = 5 } } }, "Peer")
    local sawReq, sawHello = false, false
    for _, s in ipairs(H.sent) do
        if s.msg.cmd == "pSyncReq" then sawReq = true end
        if s.msg.cmd == "pHello" and s.msg.reply then sawHello = true end
    end
    ok(not sawReq, "we're ahead -> NO backwards pull")
    ok(sawHello, "we're ahead -> hello back so they pull")
end)

-- ── PlayerDetail builders (Phase 6) ──────────────────────────────────────────
test("HistoryForPlayer filter + sort", function()
    L.db.global.history["s:1"] = { player = "Bob",   ts = 100 }
    L.db.global.history["s:2"] = { player = "Bob",   ts = 300 }
    L.db.global.history["s:3"] = { player = "Carol", ts = 200 }
    local bob = L:HistoryForPlayer(L:NormalizeName("Bob"))
    eq(#bob, 2, "two records for Bob")
    eq(bob[1].ts, 300, "newest first")
    eq(bob[2].ts, 100, "then older")
    eq(#L:HistoryForPlayer(nil), 3, "nil key -> all records")
    eq(#L:HistoryForPlayer(L:NormalizeName("Nobody")), 0, "unknown player -> none")
end)

test("PlayerDetail display builders", function()
    L.db.global.gearCache["bob"] = { items = { [1] = "headlink", [5] = "chestlink" }, mod = 1 }
    local g = L:BuildGearDisplay("Bob")
    eq(#g, 2, "two equipped slots")
    eq(g[1].kind, "gearitem", "gear rows")
    eq(g[1].slot, 1, "slot 1 first")
    eq(L:BuildGearDisplay("Ghost")[1].kind, "info", "no cache -> info row")

    L.db.global.profCache["bob"] = { profs = { Tailoring = 375, Enchanting = 300 }, mod = 1 }
    local p = L:BuildProfsDisplay("Bob")
    eq(#p, 2, "two professions")
    ok(p[1].text:find("Enchanting"), "professions sorted (Enchanting before Tailoring)")
end)

test("BiS: _CycleNext + BuildBiSDisplay", function()
    eq(L:_CycleNext({ "a", "b", "c" }, "a"), "b", "cycle forward")
    eq(L:_CycleNext({ "a", "b", "c" }, "c"), "a", "wraps to first")
    eq(L:_CycleNext({ "a", "b", "c" }, "zzz"), "a", "unknown -> first")
    eq(L:_CycleNext({}, "a"), nil, "empty -> nil")

    -- self is a MAGE (UnitClass mock); class resolves live, spec defaults to first.
    local d = L:BuildBiSDisplay("Tester")
    eq(L.bisClass, "MAGE", "class resolves to the live class")
    eq(L.bisSpec, "Fire", "spec defaults to first (Fire)")
    eq(d[1].kind, "info", "header row first")

    L.bisPhase = "P2" -- where MAGE/Fire has stub data
    local d2 = L:BuildBiSDisplay("Tester")
    eq(#d2, 4, "header + 3 Fire/P2 BiS slots")
    eq(d2[2].kind, "bisitem", "then BiS item rows")
    eq(d2[2].slot, "head", "slot order -> head first")
end)

-- Regression: a player whose class has NO stub BiS data must still resolve to THEIR class
-- (not fall back to whichever class has data), and the class cycler walks all 9 classes.
test("BiS: own class without data resolves; class cycler walks all classes", function()
    H.class = "WARRIOR" -- live UnitClass for self; WARRIOR has no BiS stub data
    local d = L:BuildBiSDisplay("Tester")
    eq(L.bisClass, "WARRIOR", "resolves to the live class even with no data")
    eq(L.bisSpec, "Arms", "spec defaults to the class's first talent tree")
    eq(d[#d].text, L.L["No BiS data for this class/spec/phase."], "and shows the no-data line")

    eq(#L.CLASSES, 9, "all 9 TBC classes are browsable")
    eq(L:_CycleNext(L.CLASSES, "WARRIOR"), "PALADIN", "class cycler advances past a data-less class")
    eq(table.concat(L:SpecsForClass("WARRIOR"), ","), "Arms,Fury,Protection", "static specs for the cycler")
    ok(L:IsKnownClass("DRUID") and not L:IsKnownClass("NOPE"), "IsKnownClass validates tokens")
end)

-- ── Stale-cache indicators (A5) ──────────────────────────────────────────────
test("RelTime buckets + CacheMetaText", function()
    eq(L:RelTime(1000, 1000), L.L["just now"], "0s -> just now")
    eq(L:RelTime(1000, 1000 + 59), L.L["just now"], "<1m -> just now")
    eq(L:RelTime(1000, 1000 + 120), "2m ago", "minutes")
    eq(L:RelTime(1000, 1000 + 3 * 3600), "3h ago", "hours")
    eq(L:RelTime(1000, 1000 + 2 * 86400), "2d ago", "days")
    eq(L:RelTime(nil, 1000), L.L["unknown"], "nil mod -> unknown")

    H.now = 10000
    eq(L:CacheMetaText("Tester", "gearCache"), L.L["(your live snapshot)"], "self -> live snapshot")
    eq(L:CacheMetaText("Ghost", "gearCache"), "", "no cache -> blank (list says so)")
    L.db.global.gearCache.bob = { items = {}, mod = 10000 - 7200 }
    eq(L:CacheMetaText("Bob", "gearCache"), "cached 2h ago", "peer -> cached <ago>")
end)

-- ── Spec capture → BiS auto-resolve (A4) ─────────────────────────────────────
test("SnapshotSpec maps the top talent tab to a spec name", function()
    H.class = "MAGE"
    H.talentPoints = { 41, 0, 0 }; local c, s = L:SnapshotSpec()
    eq(c, "MAGE", "class from UnitClass"); eq(s, "Arcane", "tab 1 -> Arcane")
    H.talentPoints = { 0, 41, 0 };  eq(select(2, L:SnapshotSpec()), "Fire",  "tab 2 -> Fire")
    H.talentPoints = { 0, 8, 41 };  eq(select(2, L:SnapshotSpec()), "Frost", "tab 3 -> Frost")
    H.class = "WARRIOR"
    H.talentPoints = { 0, 0, 41 };  eq(select(2, L:SnapshotSpec()), "Protection", "warrior tab 3 -> Protection")
    H.talentPoints = { 0, 0, 0 };   eq(select(2, L:SnapshotSpec()), nil, "untalented -> nil spec")
end)

test("ResolveBiSContext honors a cached (out-of-group) class + spec", function()
    -- Amy isn't grouped (ClassOf returns nil), but a prior pReport cached her class+spec.
    L.db.global.gearCache.amy = { items = {}, class = "WARRIOR", spec = "Fury", mod = 1 }
    L.bisClass, L.bisSpec = nil, nil
    L:BuildBiSDisplay("Amy")
    eq(L.bisClass, "WARRIOR", "class resolved from the cached report")
    eq(L.bisSpec, "Fury", "spec resolved from the cached report")
    -- Cycling class away makes the cached Mage-less spec invalid → falls back, not stuck on Fury.
    L.bisClass, L.bisSpec = "MAGE", nil
    L:BuildBiSDisplay("Amy")
    eq(L.bisClass, "MAGE", "manual class pick kept")
    ok(L.bisSpec ~= "Fury", "cached spec ignored when it doesn't fit the picked class")
end)

-- ── LootBrowser display array (Phase 6) ──────────────────────────────────────
test("LootBrowser BuildBrowserDisplay", function()
    local d = L:BuildBrowserDisplay("P2")
    -- 2 raid headers + 10 boss headers + 128 items (real SSC + TK P2 dataset).
    eq(#d, 140, "raid + boss + item entries for P2")
    eq(d[1].kind, "raid", "first entry is a raid header")
    eq(d[1].text, "Serpentshrine Cavern", "raids alpha -> SSC first")
    eq(d[2].kind, "boss", "then a boss header")
    eq(d[2].text, "Hydross the Unstable", "kill order -> Hydross first")
    eq(d[3].kind, "item", "then items")
    eq(d[3].itemID, 30056, "first SSC/Hydross item (Robe of Hateful Echoes)")
    eq(#L:BuildBrowserDisplay("P9"), 0, "empty phase -> empty array")
end)

-- Collapse state (Phase 12, item 13): absent key = collapsed; children of a collapsed node are
-- skipped entirely; nil `expanded` keeps the legacy always-expanded behavior (asserted above).
test("LootBrowser collapse/expand matrix", function()
    local exp = { raids = {}, bosses = {} }
    local d = L:BuildBrowserDisplay("P2", exp)
    eq(#d, 2, "fresh state -> raid headers only")
    eq(d[1].kind, "raid", "raid header first")
    ok(d[1].key ~= nil, "raid row carries its toggle key")
    eq(d[1].expanded, false, "raid starts collapsed")

    exp.raids[d[1].key] = true -- expand SSC
    d = L:BuildBrowserDisplay("P2", exp)
    eq(#d, 8, "expanded raid shows its 6 bosses, still folded (2 raids + 6 bosses)")
    eq(d[2].kind, "boss", "boss header under the expanded raid")
    eq(d[2].expanded, false, "bosses start collapsed")

    exp.bosses[d[2].key] = true -- expand Hydross
    d = L:BuildBrowserDisplay("P2", exp)
    ok(#d > 8, "expanded boss shows its items")
    eq(d[3].kind, "item", "items directly under the expanded boss")
    eq(d[3].itemID, 30056, "Hydross's first item")

    exp.raids[d[1].key] = nil -- collapse the raid again
    d = L:BuildBrowserDisplay("P2", exp)
    eq(#d, 2, "collapsing the raid hides bosses AND their items")
end)

-- ── Widgets: tab-strip state (Phase 6) ───────────────────────────────────────
test("Widgets _TabSelect", function()
    local st = { active = "a", valid = { a = true, b = true, c = true } }
    eq(L:_TabSelect(st, "b"), "b", "select a valid key")
    eq(L:_TabSelect(st, "b"), "b", "re-select is idempotent")
    eq(L:_TabSelect(st, "zzz"), "b", "unknown key is a no-op (keeps current)")
    eq(L:_TabSelect(st, "c"), "c", "switch to another valid key")
end)

-- ── WithItemID async loader (Phase 6) ────────────────────────────────────────
test("WithItemID", function()
    local got
    L:WithItemID(123, function(name) got = name end)
    eq(got, "Test Item", "cached -> cb with the item name (sync fast-path)")

    local n = "sentinel"
    L:WithItemID(nil, function(v) n = v end)
    eq(n, nil, "nil itemID -> cb(nil)")

    H.itemEmpty = true
    local e = "sentinel"
    L:WithItemID(999, function(v) e = v end)
    eq(e, nil, "empty/invalid item -> cb(nil)")
    H.itemEmpty = false

    H.itemCached = false
    local u
    L:WithItemID(456, function(name) u = name end)
    eq(u, "Test Item", "uncached -> resolves via ContinueOnItemLoad")
end)

-- ── Static data accessors (Phase 6) ──────────────────────────────────────────
test("DataAPI: loot accessors", function()
    eq(table.concat(L:GetLootPhases(), ","), "P1,P2", "P1 + P2 have data, in PHASES order")
    eq(table.concat(L:GetRaidsForPhase("P1"), "|"),
        "Gruul's Lair|Karazhan|Magtheridon's Lair|World Bosses", "P1 raids alphabetical")
    eq(L:GetBossesForRaid("P1", "Karazhan")[1], "Attumen the Huntsman", "Kara kill order starts at Attumen")
    eq(#L:GetBossesForRaid("P1", "Karazhan"), 17, "Kara bosses incl. rares/opera variants/trash")
    ok(#L:GetItemsForBoss("P1", "Gruul's Lair", "Gruul the Dragonkiller") == 17, "Gruul drops")
    eq(table.concat(L:GetRaidsForPhase("P2"), "|"), "Serpentshrine Cavern|Tempest Keep",
        "raids alphabetical")
    eq(table.concat(L:GetBossesForRaid("P2", "Serpentshrine Cavern"), "|"),
        "Hydross the Unstable|The Lurker Below|Leotheras the Blind|Fathom-Lord Karathress|Morogrim Tidewalker|Lady Vashj",
        "bosses in kill order (_order)")
    ok(#L:GetItemsForBoss("P2", "Tempest Keep", "Al'ar") > 1, "Al'ar drops several items")
    eq(#L:GetItemsForBoss("P2", "Tempest Keep", "Nobody"), 0, "missing boss -> empty")
    eq(#L:GetRaidsForPhase("P9"), 0, "missing phase -> empty")
end)

test("DataAPI: BiS accessors", function()
    eq(table.concat(L:GetBiSSpecs("MAGE"), ","), "Fire,Frost", "specs alphabetical")
    eq(#L:GetBiSSpecs("ROGUE"), 0, "class without data -> empty")
    local rows = L:GetBiSForSpecPhase("MAGE", "Fire", "P2")
    eq(#rows, 3, "Fire P2 has 3 slots with data")
    eq(rows[1].slot, "head", "slot order respects BIS_SLOT_ORDER (head)")
    eq(rows[2].slot, "neck", "...(neck)")
    eq(rows[3].slot, "hands", "...(hands after neck)")
    eq(#L:GetBiSForSpecPhase("MAGE", "Fire", "P9"), 0, "missing phase -> empty")
end)

test("DataAPI: tier tokens", function()
    -- Real T5 data: Helm of the Vanquished Defender (30243) → Druid/Priest/Warrior. A class with
    -- spec-variant tier sets redeems into several pieces (warrior: Destroyer Armor + Battlegear).
    eq(L:GetTierToken(30243).name, "Helm of the Vanquished Defender", "token name")
    eq(table.concat(L:GetTierPieceForClass(30243, "WARRIOR"), ","), "30115,30120",
        "warrior helm pieces (both Destroyer sets)")
    eq(#L:GetTierPieceForClass(30244, "MAGE"), 1, "single-set class -> one piece (mage Tirisfal helm)")
    eq(L:GetTierPieceForClass(30243, "MAGE"), nil, "mage is NOT on the Defender line")
    ok(L:FindTokenForItem(30243), "30243 is a token")
    ok(L:FindTokenForItem(30242) and L:FindTokenForItem(30250), "champion + hero tokens too")
    ok(not L:FindTokenForItem(30056), "a normal gear item is not a token")

    -- T4 (P1 content): 15 tokens, same trio structure. Warrior has both Warbringer sets.
    eq(L:GetTierToken(29759).name, "Helm of the Fallen Hero", "T4 helm token name")
    eq(table.concat(L:GetTierPieceForClass(29767, "WARRIOR"), ","), "29016,29023",
        "warrior legs pieces (both Warbringer sets)")
    eq(#L:GetTierPieceForClass(29765, "MAGE"), 1, "single-set class -> one T4 piece")
    eq(L:GetTierPieceForClass(29765, "WARRIOR"), nil, "warrior is NOT on the Hero line")
    ok(L:FindTokenForItem(29753) and L:FindTokenForItem(29758), "T4 chest + gloves tokens resolve")
end)

-- ── Class-usability filter (Core/Usable.lua) ─────────────────────────────────
test("ClassCanUse: tier-token class lines (no item APIs needed)", function()
    -- 29767 = Leggings of the Fallen Defender (Druid/Priest/Warrior); 29765 = Hero (Hun/Mage/Wlk).
    ok(L:ClassCanUse(29767, "WARRIOR"), "warrior on the Defender line")
    ok(not L:ClassCanUse(29767, "MAGE"), "mage NOT on the Defender line")
    ok(L:ClassCanUse(29765, "MAGE"), "mage on the Hero line")
    ok(not L:ClassCanUse(29765, "ROGUE"), "rogue NOT on the Hero line")
    ok(L:ClassCanUse("|cffa335ee|Hitem:29767::::::::70|h[Leggings]|h|r", "PRIEST"),
        "token check works from a link too")
end)

test("ClassCanUse: armor/weapon proficiency matrix", function()
    local function instant(classID, subClassID, equipLoc)
        H.instant = { 12345, "t", "st", equipLoc or "INVTYPE_CHEST", 135, classID, subClassID }
    end
    instant(4, 4) -- plate chest
    ok(L:ClassCanUse(12345, "WARRIOR"), "warrior wears plate")
    ok(not L:ClassCanUse(12345, "PRIEST"), "priest does not wear plate")
    instant(4, 3) -- mail
    ok(L:ClassCanUse(12345, "SHAMAN"), "shaman wears mail")
    ok(not L:ClassCanUse(12345, "ROGUE"), "rogue does not wear mail")
    instant(4, 1, "INVTYPE_CLOAK") -- cloak: 'cloth' but universal
    ok(L:ClassCanUse(12345, "WARRIOR"), "cloaks are universal")
    instant(4, 0) -- misc armor: rings/trinkets/necks
    ok(L:ClassCanUse(12345, "MAGE"), "misc armor is universal")
    instant(4, 6) -- shield
    ok(L:ClassCanUse(12345, "PALADIN"), "paladin uses shields")
    ok(not L:ClassCanUse(12345, "DRUID"), "druid does not use shields")
    instant(2, 1) -- 2H axe
    ok(L:ClassCanUse(12345, "SHAMAN"), "shaman swings 2H axes")
    ok(not L:ClassCanUse(12345, "ROGUE"), "rogue cannot use axes in TBC")
    instant(2, 19) -- wand
    ok(L:ClassCanUse(12345, "PRIEST"), "priest uses wands")
    ok(not L:ClassCanUse(12345, "WARRIOR"), "warrior cannot use wands")
    instant(9, 0) -- recipe: unknown class of item -> never hide
    ok(L:ClassCanUse(12345, "ROGUE"), "non-equipment defaults to SHOW")
    H.instant = nil
    ok(L:ClassCanUse(12345, "ROGUE"), "no item info -> default SHOW")
end)

-- ── Gear issues (Core/GearIssues.lua) ────────────────────────────────────────
local function countKind(issues, kind)
    local n = 0
    for _, i in ipairs(issues) do if i.kind == kind then n = n + 1 end end
    return n
end

test("ItemEnchantGems parses enchant + gem fields", function()
    local id, ench, gems = L:ItemEnchantGems("|cffa335ee|Hitem:30055:2647:32409:0:0:0:0:0:70|h[x]|h|r")
    eq(id, 30055, "itemID")
    eq(ench, 2647, "enchantID")
    eq(gems[1], 32409, "gem1 filled")
    eq(gems[2], 0, "gem2 empty")
    eq(L:ItemEnchantGems("item:15138"), 15138, "short link: itemID only, no enchant/gem fields")
    eq((L:ItemEnchantGems("not a link")), nil, "non-item string -> nil")
end)

test("GearIssuesForItem: missing enchant on enchantable slots only", function()
    eq(countKind(L:GearIssuesForItem("item:30055:0:0:0:0:0", 5), "noenchant"), 1, "bare chest flagged")
    eq(countKind(L:GearIssuesForItem("item:30055:0:0:0:0:0", 2), "noenchant"), 0, "neck is not enchantable")
    eq(countKind(L:GearIssuesForItem("item:30055:2647:0:0:0:0", 5), "noenchant"), 0, "enchanted chest clean")
end)

test("GearIssuesForItem: empty sockets from GetItemStats (inherent - filled)", function()
    H.itemStats = { EMPTY_SOCKET_RED = 1, EMPTY_SOCKET_YELLOW = 1 } -- 2 inherent sockets
    eq(countKind(L:GearIssuesForItem("item:30055:2647:32409:0:0:0", 5), "nogem"), 1, "one gem in, one empty")
    eq(countKind(L:GearIssuesForItem("item:30055:2647:32409:32410:0:0", 5), "nogem"), 0, "both sockets filled")
    H.itemStats = nil
    eq(countKind(L:GearIssuesForItem("item:30055:2647:0:0:0:0", 5), "nogem"), 0, "no stats -> no socket flag")
end)

test("GearIssuesForItem: low-quality gem below minGemQuality", function()
    H.itemStats = { EMPTY_SOCKET_RED = 1 } -- 1 socket, filled below so no empty-socket flag
    H.itemQuality = 2 -- uncommon
    eq(countKind(L:GearIssuesForItem("item:30055:2647:32409:0:0:0", 5), "badgem"), 1, "uncommon gem flagged")
    H.itemQuality = 3 -- rare
    eq(countKind(L:GearIssuesForItem("item:30055:2647:32409:0:0:0", 5), "badgem"), 0, "rare gem clean")
end)

test("GearIssuesForItem: blacklisted enchant flagged with its CLA label", function()
    -- 908 = "50 HP" chest enchant (low-rank, on the CLA §4b blacklist).
    local issues = L:GearIssuesForItem("item:30055:908:0:0:0:0", 5)
    eq(countKind(issues, "badenchant"), 1, "blacklisted enchant flagged")
    local label
    for _, i in ipairs(issues) do if i.kind == "badenchant" then label = i.text end end
    eq(label, "50 HP", "flag carries the CLA label")
    eq(countKind(L:GearIssuesForItem("item:30055:2647:0:0:0:0", 5), "badenchant"), 0, "unlisted enchant is clean")
end)

test("GearIssuesForItem: excluded item is never flagged", function()
    -- 15138 = Onyxia Scale Cloak (whitelisted); back(15) is enchantable and the enchant is 0.
    eq(#L:GearIssuesForItem("item:15138:0:0:0:0:0", 15), 0, "excluded item skips all checks")
end)

test("GearIssuesForPlayer aggregates a cached report", function()
    L.db.global.gearCache["bob"] = { items = {
        [5] = "item:30055:0:0:0:0:0", -- chest, no enchant -> 1 issue
        [2] = "item:30056:0:0:0:0:0", -- neck, not enchantable -> clean
    } }
    local rows, total = L:GearIssuesForPlayer("Bob")
    eq(total, 1, "one issue total")
    eq(#rows, 1, "one row carries issues")
    eq(rows[1].slot, 5, "it's the chest row")
end)

test("BuildGearDisplay attaches gear issues to each item", function()
    L.db.global.gearCache["bob"] = { items = { [5] = "item:30055:0:0:0:0:0" } }
    local disp = L:BuildGearDisplay("Bob")
    eq(disp[1].kind, "gearitem", "first row is a gear item")
    ok(disp[1].issues and #disp[1].issues >= 1, "issues attached to the entry")
    eq(disp[1].issues[1].kind, "noenchant", "no-enchant detected on the bare chest")
end)

test("BuildGearCheckDisplay lists offenders worst-first, omits clean players", function()
    L.db.global.gearCache["bob"] = { items = { [5] = "item:30055:0:0:0:0:0" } }                 -- 1 issue
    L.db.global.gearCache["amy"] = { items = { [5] = "item:30055:0:0:0:0:0",
                                               [3] = "item:30056:0:0:0:0:0" } }                  -- 2 issues
    L.db.global.gearCache["cid"] = { items = { [5] = "item:30055:2647:0:0:0:0" } }               -- clean
    local disp = L:BuildGearCheckDisplay()
    eq(disp[1].kind, "gearcheck", "row kind")
    eq(disp[1].name, "amy", "worst offender first")
    eq(disp[1].total, 2, "amy has two issues")
    eq(disp[2].name, "bob", "bob second")
    local cid = false
    for _, e in ipairs(disp) do if e.name == "cid" then cid = true end end
    ok(not cid, "clean player omitted")
end)

-- ── Guild identity + present roster (Core/Guild.lua) ─────────────────────────
test("GuildKey + PresentRoster", function()
    H.inGuild, H.guildName = true, "Wipe Enthusiasts"
    eq(L:GuildKey(), "Wipe Enthusiasts", "guild name is the key")
    H.inGuild = false
    eq(L:GuildKey(), nil, "guildless -> nil")

    H.inRaid, H.group = false, {}
    local solo = L:PresentRoster()
    eq(#solo, 1, "solo roster is just self")
    eq(solo[1].name, "Tester", "self present")

    H.inRaid, H.group = true, { "Amy", "Bob", "Tester" }
    eq(#L:PresentRoster(), 3, "self + amy + bob, self deduped")
end)

-- ── Shared config dataset (Core/council/Config.lua) ─────────────────────────
test("GetConfig defaults + SetConfigField replicates via pSet", function()
    H.inGuild, H.guildName = true, "Guildy"
    local cfg = L:GetConfig()
    eq(cfg.anonVoting, false, "default anonVoting is off")
    eq(type(cfg.disenchanters), "table", "default disenchanters is a list")

    H.now = 500
    L:SetConfigField("anonVoting", true)
    eq(L:GetConfig().anonVoting, true, "anonVoting now on")
    eq(L.db.global.config["Guildy"].by, "Tester", "record stamped by self")
    eq(#H.sent, 1, "one broadcast")
    eq(H.sent[1].msg.cmd, "pSet", "broadcast was a pSet")

    L:SetConfigField("disenchanters", { "Zap" })
    local c2 = L:GetConfig()
    eq(c2.anonVoting, true, "earlier field preserved across a second set")
    eq(c2.disenchanters[1], "Zap", "new field stored")
end)

test("Council roster sourced from shared config once authored (DL-1 / Feature C)", function()
    H.inGuild, H.guildName = true, "Guildy"
    -- No config record yet -> the pre-config default is profile.council (the C4 escape hatch).
    L.db.profile.council = { byRank = false, rank = 1, extra = { "Alice" } }
    ok(L:ResolveCouncil(false)["alice"], "pre-config: profile.council.extra resolves")
    ok(not L:ConfigRecord(), "no config record authored yet")

    -- Authoring the roster writes+replicates config; from then on profile.council is ignored.
    L:SetCouncilConfig({ extra = { "Bob" } })
    ok(L:ConfigRecord() ~= nil, "config record now authored")
    local set = L:ResolveCouncil(false)
    ok(set["bob"], "post-config: config.extra resolves")
    ok(not set["alice"], "profile.council no longer consulted once config is authored")
    -- byRank/rank were seeded atomically from the prior effective roster (not dropped).
    eq(L:CouncilConfig().byRank, false, "byRank seeded from the effective roster on first write")
    L.db.global.config = {}
end)

test("Access predicates: edit/see gating with the C4 escape hatch (Feature C)", function()
    -- Solo / guildless -> always editable + visible (the testing escape hatch).
    H.inGuild = false
    ok(L:CanEditConfig(), "guildless: config editable")
    ok(L:CanSeeSessionConfig(), "guildless: session config visible")

    -- In a guild, nothing authored yet -> bootstrap: anyone can author.
    H.inGuild, H.guildName = true, "Guildy"
    H.myRank = 5 -- a plain raider
    L.db.profile.council = { byRank = false, rank = 1, extra = {} } -- Tester not council
    ok(not L:AmCouncil(), "raider is not council")
    ok(L:CanEditConfig(), "no config authored -> bootstrap editable")

    -- Authoring a config (as some officer) then locks the raider out.
    L:SetCouncilConfig({ extra = { "Officer" } })
    ok(L:ConfigRecord() ~= nil, "config authored")
    ok(not L:CanEditConfig(), "authored + raider (not council) -> read-only")
    ok(not L:CanSeeSessionConfig(), "authored + raider -> session config hidden")

    -- GM (rank 0) keeps the escape hatch even after authoring.
    H.myRank = 0
    ok(L:CanEditConfig(), "GM can always edit")

    -- Council membership grants edit regardless of guild rank.
    H.myRank = 3
    L:SetCouncilConfig({ extra = { "Tester" } })
    ok(L:AmCouncil(), "Tester now council")
    ok(L:CanEditConfig(), "council member can edit")

    -- Loot-window VIEW level (Phase 12, DL-18 — supersedes the C7 open gate): council -> full,
    -- raider -> list by default, opt-in upgrades the raider to full.
    ok(L:LootViewLevel() == "full", "council -> full view")
    L:SetCouncilConfig({ extra = {} }) -- Tester off council again
    H.myRank = 5
    eq(L:LootViewLevel(), "list", "raider, opt-in off -> list view")
    L:SetConfigField("visibility", { lootWindow = true })
    eq(L:LootViewLevel(), "full", "raider, opt-in on -> full view")
    L.db.global.config = {}
end)

-- ── ApplyCUpdate view-level stripping (Phase 12, item 1 / DL-18) ─────────────
test("ApplyCUpdate: list-level spectators never store rows/tally", function()
    L.activeSession = { sid = "S1", ml = "Boss", viewLevel = "list", amCouncil = false }
    L.voteRows, L.voteStatus = nil, nil
    L:ApplyCUpdate("S1", 1, { bob = { resp = 1, votes = 2, note = "secret" } },
        { kind = "voting", voted = { n = 1, of = 3, names = { "Amy" } } })
    ok(L.voteRows == nil or L.voteRows[1] == nil, "list level must not store rows")
    ok(L.voteStatus and L.voteStatus[1] and L.voteStatus[1].kind == "voting",
        "list level keeps the readiness kind")
    ok(L.voteStatus[1].voted == nil, "list level strips the vote tally + who-voted names")

    L.activeSession.viewLevel = "full"
    L:ApplyCUpdate("S1", 1, { bob = { resp = 1 } }, { kind = "ready", voted = { n = 1, of = 1 } })
    ok(L.voteRows and L.voteRows[1] and L.voteRows[1].bob ~= nil, "full level stores rows")
    ok(L.voteStatus[1].voted ~= nil, "full level keeps the tally")

    L:ApplyCUpdate("OTHER", 1, {}, nil)
    ok(L.voteRows[1].bob ~= nil, "foreign sid ignored")
    L.activeSession, L.voteRows, L.voteStatus = nil, nil, nil
end)

test("SyncGuildScope: claim-in-place, stash on switch, restore on rejoin (Feature C, C6)", function()
    H.inGuild, H.guildName = true, "Alpha"
    L.db.global.history["u1"] = { player = "Amy", ts = 1 }
    L.db.global.notes["amy"] = { text = "hi" }
    L:SetConfigField("anonVoting", true) -- authors config for Alpha

    -- First scope claims the existing flat tables in place for Alpha (no data moves).
    L:SyncGuildScope()
    eq(L.db.global.activeGuild, "Alpha", "flat tables claimed for Alpha")
    ok(L.db.global.history["u1"], "existing data still present after the in-place claim")

    -- Switch to Beta: Alpha's data stashes; the flat tables go empty (hide-on-leave).
    H.guildName = "Beta"
    L:SyncGuildScope()
    eq(L.db.global.activeGuild, "Beta", "now scoped to Beta")
    ok(not L.db.global.history["u1"], "Alpha history hidden under Beta")
    ok(not next(L.db.global.notes), "Alpha notes hidden under Beta")
    eq(L:GetConfig().anonVoting, false, "Alpha config hidden -> Beta sees defaults")
    ok(L.db.global.guilds["Alpha"], "Alpha data stashed under its namespace")

    -- Author Beta data, switch back to Alpha: Beta stashes, Alpha restores intact.
    L.db.global.history["u2"] = { player = "Bob", ts = 2 }
    H.guildName = "Alpha"
    L:SyncGuildScope()
    ok(L.db.global.history["u1"], "Alpha history restored on rejoin")
    ok(not L.db.global.history["u2"], "Beta history not visible under Alpha")
    eq(L:GetConfig().anonVoting, true, "Alpha config restored on rejoin")
end)

test("SyncGuildScope defers while guilded but the roster has not loaded", function()
    H.inGuild, H.guildName = true, nil -- IsInGuild true, GetGuildInfo returns nothing yet
    L.db.global.history["u1"] = { player = "Amy", ts = 1 }
    L:SyncGuildScope()
    eq(L.db.global.activeGuild, nil, "no claim while the guild name is unknown")
    ok(L.db.global.history["u1"], "flat data left in place (still visible) meanwhile")
end)

test("Inherit gate: hold + prompt a peer config on first load; accept applies it (Feature C)", function()
    H.inGuild, H.guildName, H.myRank = true, "Menu", 3 -- guilded officer, not GM
    local incoming = { anonVoting = true, mod = 500, by = "Officer" }
    local gated = L:GateConfigInherit(L:ConfigKey(), incoming, "Officer")
    ok(gated, "peer config held (not auto-merged) on first load")
    ok(not L:ConfigRecord(), "config not applied while pending")
    ok(H.confirm and H.confirm.text:find("Menu"), "inherit prompt shown, naming the guild")
    L:AcceptInherit()
    ok(L:ConfigRecord() ~= nil, "config applied on accept")
    eq(L:GetConfig().anonVoting, true, "inherited settings active")
    L.db.global.config = {}
end)

test("Inherit gate: decline keeps defaults + stops asking; GM/solo skip the gate (Feature C)", function()
    H.inGuild, H.guildName, H.myRank = true, "Menu", 3
    local incoming = { anonVoting = true, mod = 500, by = "Officer" }
    ok(L:GateConfigInherit(L:ConfigKey(), incoming, "Officer"), "held for the prompt")
    L:DeclineInherit()
    ok(not L:ConfigRecord(), "decline keeps local defaults (no config authored)")
    ok(not L:GateConfigInherit(L:ConfigKey(), incoming, "Officer"), "stops asking this session after decline")

    -- Escape hatches skip the gate entirely (auto-adopt / nothing to inherit).
    L._inheritDecided = nil
    H.myRank = 0
    ok(not L:GateConfigInherit(L:ConfigKey(), incoming, "Officer"), "GM auto-adopts (no gate)")
    H.inGuild = false
    ok(not L:GateConfigInherit("_local", incoming, "Officer"), "solo: nothing to inherit")
end)

-- ── Guild bank ledger (Core/council/Gbank.lua, Feature B) ────────────────────
local HR = 3600
test("Gbank uid + normalize: content-hash dedups; withdrawal folds to withdraw", function()
    eq(L:GbankNormalizeKind("withdrawal"), "withdraw", "money withdrawal folds to withdraw")
    eq(L:GbankNormalizeKind("deposit"), "deposit", "deposit passes through")
    local u1 = L:GbankTxnUid("withdraw", "Amy", "item:1", 2, "1>", 100)
    eq(u1, L:GbankTxnUid("withdrawal", "Amy", "item:1", 2, "1>", 100), "withdraw/withdrawal same uid")
    ok(u1 ~= L:GbankTxnUid("withdraw", "Amy", "item:1", 3, "1>", 100), "count change -> new uid")
end)

test("GbankTxnHour: capture floored to the hour minus elapsed", function()
    local capturedAt = 100 * HR + 1800 -- 100.5 hours; floors to hour 100
    eq(L:GbankTxnHour(capturedAt, 0, 0, 0, 2), 98, "2h ago -> capturedHour - 2")
    eq(L:GbankTxnHour(capturedAt, 0, 0, 1, 0), 100 - 24, "1 day ago -> -24h")
end)

test("IngestTxnList: dedups identical transactions across scans (union ledger)", function()
    local txns = {
        { kind = "withdraw", player = "Amy", itemLink = "item:1", count = 2, tabs = "1>",
          years = 0, months = 0, days = 0, hours = 1 },
        { kind = "deposit", player = "Bob", gold = 5000, tabs = "",
          years = 0, months = 0, days = 0, hours = 1 },
    }
    eq(L:IngestTxnList(txns, 1000 * HR), 2, "two new entries ingested")
    eq(L:IngestTxnList(txns, 1000 * HR), 0, "same scan re-ingested -> all dedup")
    eq(L:IngestTxnList(txns, 1000 * HR + 600), 0, "another officer, same hour -> deduped")
    eq(#L:GbankLogEntries(), 2, "ledger holds the two unique transactions")
end)

test("BuildGbankGroups: groups same player+action; xN items; gold sums; splits on change", function()
    local H0 = 1000 * HR
    local entries = {
        { uid = "a1", kind = "deposit", player = "Amy", itemLink = "item:1", count = 2, ts = H0 },
        { uid = "a2", kind = "deposit", player = "Amy", itemLink = "item:1", count = 3, ts = H0 },
        { uid = "a3", kind = "deposit", player = "Amy", gold = 500, ts = H0 },
        { uid = "b1", kind = "withdraw", player = "Bob", itemLink = "item:9", count = 1, ts = H0 },
    }
    local g = L:BuildGbankGroups(entries)
    eq(#g, 2, "Amy's deposits group; Bob's withdraw is separate")
    eq(g[1].player, "Amy", "first group is Amy")
    eq(#g[1].items, 1, "identical items collapse to one line")
    eq(g[1].items[1].count, 5, "counts sum to xN (2+3)")
    eq(g[1].gold, 500, "gold in the group sums")
    eq(g[1].uid, "a1", "group uid is the lead entry's (stable for annotations)")
    eq(g[2].player, "Bob", "second group is Bob")
end)

test("Gbank accessors: gold + tabs from the cache", function()
    L.db.global.gbankCache["money"] = { gold = 12345, mod = 1 }
    L.db.global.gbankCache[1] = { index = 1, name = "Tab1", slots = {} }
    eq((L:GbankGold()), 12345, "gold read from cache")
    local tabs = L:GbankTabs()
    eq(#tabs, 1, "one cached tab (money key excluded)")
    eq(tabs[1].name, "Tab1", "tab name")
end)

test("Gbank annotations + log visibility (Feature B, B5)", function()
    -- Annotation round-trip keyed by a group's lead uid.
    L:SetGbankNote("grp1", "restock for MC")
    eq((L:GbankNote("grp1")), "restock for MC", "note stored + read back")
    L:SetGbankNote("grp1", "")
    eq((L:GbankNote("grp1")), "", "note cleared")

    -- Log visibility: council always; a raider only under the per-guild opt-in.
    H.inGuild, H.guildName, H.myRank = true, "Menu", 5
    L.db.profile.council = { byRank = false, rank = 1, extra = {} } -- Tester not council
    L.db.global.config, L._councilSet = {}, nil
    ok(not L:AmCouncil(), "raider is not council")
    ok(not L:CanSeeGbankLog(), "raider, opt-in off -> log hidden")
    L:SetConfigField("visibility", { gbankLog = true })
    ok(L:CanSeeGbankLog(), "raider, opt-in on -> log visible")
    L.db.global.config = {}
end)

-- ── Session row seeding (Core/session/Session.lua, Feature V) ────────────────
test("SeedRows: pending / cantuse / missedkill / left", function()
    -- A plate chest (classID 4, subClass 4): WARRIOR can use, PRIEST cannot.
    H.instant = { 100, "t", "st", "INVTYPE_CHEST", 135, 4, 4 }
    local kill = { { name = "War", class = "WARRIOR" }, { name = "Pri", class = "PRIEST" },
                   { name = "Gone", class = "WARRIOR" } }
    local now  = { { name = "War", class = "WARRIOR" }, { name = "Pri", class = "PRIEST" },
                   { name = "Late", class = "WARRIOR" } }
    local rows = L:SeedRows(kill, now, "item:100")
    eq(rows["war"].reason,  "pending",    "at kill + can use -> pending")
    eq(rows["pri"].reason,  "cantuse",    "at kill + cannot use -> cantuse")
    eq(rows["gone"].reason, "left",       "at kill but gone -> left")
    eq(rows["late"].reason, "missedkill", "in raid now but missed the kill -> missedkill")
    eq(rows["war"].class,   "WARRIOR",    "class captured on the row")
    eq(rows["war"].resp,    nil,          "no response yet")
end)

test("StartSession pre-seeds rows from the item roster (V1)", function()
    H.inRaid, H.group = true, { "Amy", "Tester" }
    H.instant = { 100, "t", "st", "INVTYPE_CHEST", 135, 4, 1 } -- cloth chest: MAGE can use
    L.sessionItems = { { link = "item:100",
        roster = { { name = "Amy", class = "MAGE" }, { name = "Gone", class = "MAGE" } } } }
    L:StartSession({ { link = "item:100", quality = 4 } })
    local rows = L.session.rows[1]
    ok(rows, "item 1 rows seeded")
    eq(rows["amy"].reason,  "pending",    "Amy at kill + can use -> pending")
    eq(rows["gone"].reason, "left",       "Gone in kill roster but not present -> left")
    eq(rows["tester"].reason, "missedkill", "self present but not in this item's kill roster -> missedkill")

    -- A response clears the reason and keeps the seeded class.
    L.dispatch.cResp(L, { sid = L.session.sid, item = 1, resp = 2, note = "" }, "Amy")
    eq(L.session.rows[1]["amy"].resp, 2, "cResp recorded")
    eq(L.session.rows[1]["amy"].reason, nil, "reason cleared on response")
    eq(L.session.rows[1]["amy"].class, "MAGE", "seeded class preserved")
end)

-- ── Award-readiness cascade (Core/session/Readiness.lua, Feature V) ──────────
-- The PURE calculator over a plain rows table. PASS = 5; a non-PASS response = a "roller".
local function readiness(rows, opts)
    opts = opts or {}
    return L:ReadinessStatus({
        rows = rows, passId = 5,
        awarded = opts.awarded, votesCast = opts.votesCast, councilPresent = opts.councilPresent,
    })
end

test("Readiness: waiting while a present-eligible row has not responded", function()
    eq(readiness({ a = { reason = "pending" } }, { councilPresent = 1 }).kind, "waiting",
        "one eligible, unresponded -> waiting")
    -- A roller plus a still-pending eligible: not everyone responded -> still waiting.
    eq(readiness({ a = { resp = 1 }, b = { reason = "pending" } }, { councilPresent = 2 }).kind,
        "waiting", "a wanter but responses outstanding -> waiting")
end)

test("Readiness: de when all present-eligible responded and nobody wants it", function()
    eq(readiness({ a = { resp = 5 }, b = { resp = 5 } }).kind, "de",
        "all passed -> disenchant (blue)")
    -- Not-yet-all-responded with nobody (so far) wanting it stays grey, not blue.
    eq(readiness({ a = { resp = 5 }, b = { reason = "pending" } }).kind, "waiting",
        "a passer but someone still pending -> waiting")
end)

test("Readiness: ready via the single-roller shortcut", function()
    eq(readiness({ a = { resp = 1 }, b = { resp = 5 } }, { councilPresent = 3 }).kind, "ready",
        "all responded, exactly one roller -> ready without votes")
end)

test("Readiness: voting then ready as council votes come in", function()
    local rows = { a = { resp = 1 }, b = { resp = 1 } } -- two rollers, all responded
    eq(readiness(rows, { councilPresent = 2, votesCast = 0 }).kind, "voting",
        "all responded, multiple rollers, no votes -> voting (gold)")
    eq(readiness(rows, { councilPresent = 2, votesCast = 2 }).kind, "ready",
        "all present council voted -> ready (light green)")
end)

test("Readiness: awarded overrides every other state", function()
    eq(readiness({ a = { reason = "pending" } }, { awarded = true }).kind, "awarded",
        "awarded wins even with responses still outstanding")
end)

test("Readiness: ineligible rows are excluded from the denominator (R4)", function()
    -- cantuse/missedkill/left don't count; only the lone roller does -> ready, not waiting.
    local rows = { a = { reason = "cantuse" }, b = { reason = "missedkill" },
                   c = { reason = "left" }, d = { resp = 1 } }
    eq(readiness(rows, { councilPresent = 1 }).kind, "ready", "only the eligible roller counts")
    -- No eligible rows at all -> nothing to be ready about.
    eq(readiness({ a = { reason = "cantuse" }, b = { reason = "left" } }).kind, "waiting",
        "zero present-eligible -> waiting")
end)

test("Readiness: voted tally echoes the vote/council counts", function()
    local st = readiness({ a = { resp = 1 } }, { votesCast = 1, councilPresent = 3 })
    eq(st.voted.n, 1, "voted numerator = votes cast")
    eq(st.voted.of, 3, "voted denominator = present council")
end)

test("VotesCastOn / VotersOn: distinct council voters with a non-zero vote", function()
    L.session = { voters = { [1] = {
        cand1 = { v1 = 1, v2 = 0 },  -- v2 abstained (0) -> not counted
        cand2 = { v1 = 1, v3 = -1 }, -- v1 already counted; v3 downvoted
    } } }
    eq(L:VotesCastOn(1), 2, "v1 and v3 voted; v2's zero does not count")
    eq(L:VotesCastOn(2), 0, "no voters on an untouched item")
    local names = L:VotersOn(1)
    eq(table.concat(names, ","), "V1,V3", "voter display names, deduped + sorted + capitalized")
    L.session = nil
end)

test("ComputeItemStatus: anon gate hides voter names, keeps the count", function()
    L.session = {
        rows    = { [1] = { a = { resp = 1 } } },    -- one roller (BiS)
        voters  = { [1] = { a = { tester = 1 } } },   -- the runner voted for them
        council = { "tester" }, anon = false,
    }
    L.activeSession = nil
    local st = L:ComputeItemStatus(1)
    eq(st.voted.n, 1, "one voter counted")
    ok(st.voted.names and #st.voted.names == 1, "names present when not anonymous")
    eq(st.voted.names[1], "Tester", "voter display name")
    L.session.anon = true
    local sta = L:ComputeItemStatus(1)
    eq(sta.voted.n, 1, "count still shows under anonymous voting")
    eq(sta.voted.names, nil, "names hidden under anonymous voting")
    L.session = nil
end)

-- ── Award messaging (Core/session/Award.lua, Feature V D/E) ──────────────────
test("AwardReasonText: D/E, response text, or nil for announced", function()
    eq(L:AwardReasonText(L.STATUS.DISENCHANT), "D/E", "disenchant -> D/E")
    eq(L:AwardReasonText(1), "BiS", "response id -> its text")
    eq(L:AwardReasonText(L.STATUS.ANNOUNCED), nil, "announced -> no reason clause")
end)

test("AnnounceAward: raid chat when configured + grouped, else local", function()
    H.inRaid, H.group = true, { "Amy", "Tester" }
    L.db.global.config = {} -- announceAwards defaults on
    L:AnnounceAward("item:100", "Amy", 1)
    eq(#H.chat, 1, "announced to chat when grouped + on")
    eq(H.chat[1].chan, "RAID", "announce channel is RAID")
    ok(H.chat[1].text:find("for BiS"), "reason rides the message")
    -- Toggle off -> the message stays in the ML's own chat frame, not raid chat.
    H.chat = {}
    L:SetConfigField("announceAwards", false)
    L:AnnounceAward("item:100", "Amy", L.STATUS.DISENCHANT)
    eq(#H.chat, 0, "no raid chat when the toggle is off")
    L.db.global.config = {}
end)

test("ResolveDisenchanter: highest-ranked present wins; nil when none present", function()
    L.db.global.config = {}
    L:SetConfigField("disenchanters", { "Bob", "Amy" }) -- Bob ranked highest
    H.inRaid, H.group = true, { "Amy", "Tester" }        -- Bob absent, Amy present
    eq(L:ResolveDisenchanter(), "Amy", "top-ranked Bob absent -> next present (Amy)")
    H.group = { "Bob", "Amy", "Tester" }
    eq(L:ResolveDisenchanter(), "Bob", "top-ranked Bob present -> Bob")
    H.group = { "Tester" }
    eq(L:ResolveDisenchanter(), nil, "none present -> nil (manual fallback)")
    L.db.global.config = {}
end)

test("AwardItem forcedResp tags a D/E award (reason renders D/E)", function()
    H.inRaid, H.group = true, { "Amy", "Tester" }
    H.instant = { 100, "t", "st", "INVTYPE_CHEST", 135, 4, 1 } -- cloth chest
    L.sessionItems = { { link = "item:100", itemID = 100, quality = 4,
        roster = { { name = "Amy", class = "MAGE" } } } }
    L:StartSession({ { link = "item:100", quality = 4 } })
    ok(L:AwardItem(1, "Amy", L.STATUS.DISENCHANT), "D/E award recorded")
    local uid = L.session.sid .. ":1"
    eq(L.db.global.history[uid].resp, L.STATUS.DISENCHANT, "history carries the D/E reason code")
    eq(L:AwardReasonText(L.db.global.history[uid].resp), "D/E", "renders as D/E")
    L:EndSession()
end)

-- ── Duplicate grouping (§6.14, DL-19) ────────────────────────────────────────
test("Duplicate grouping: shared responses + per-copy awards", function()
    H.inRaid, H.group = true, { "Amy", "Bob", "Tester" }
    H.instant = { 100, "t", "st", "INVTYPE_CHEST", 135, 4, 1 } -- cloth chest: usable by the mock
    local items = { { link = "item:100", quality = 4 }, { link = "item:100", quality = 4 },
                    { link = "item:200", quality = 4 } }

    -- BuildItemGroups: copies 1&2 group under leader 1; item 3 is its own group.
    local g = L:BuildItemGroups(items)
    eq(g.leaderOf[2], 1, "copy 2 groups under leader 1")
    eq(g.leaderOf[3], 3, "distinct item is its own leader")
    eq(#g.leaders, 2, "two groups")
    eq(#g.members[1], 2, "leader 1 has two members")

    -- One poll card per group (leaders only), order preserved.
    eq(table.concat(L:_BuildPollQueue(items), ","), "1,3", "one poll card per group")

    -- _UnionRosters dedups by normalized name.
    local u = L:_UnionRosters({ { { name = "Amy", class = "MAGE" } },
                                { { name = "Amy" }, { name = "Bob", class = "WARRIOR" } } })
    eq(#u, 2, "union dedups Amy across copies")

    L.sessionItems = {
        { link = "item:100", itemID = 100, quality = 4, roster = { { name = "Amy", class = "MAGE" } } },
        { link = "item:100", itemID = 100, quality = 4, roster = { { name = "Bob", class = "WARRIOR" } } },
        { link = "item:200", itemID = 200, quality = 4, roster = { { name = "Amy", class = "MAGE" } } },
    }
    L:StartSession(items)
    local s = L.session
    ok(s.rows[1] ~= nil and s.rows[3] ~= nil, "leaders seeded")
    ok(s.rows[2] == nil, "member copy not separately seeded")
    ok(s.rows[1]["amy"] and s.rows[1]["bob"], "group 1 kill set unions both copies' rosters")

    -- cResp on a MEMBER index (2) aggregates under the leader (1).
    L.dispatch.cResp(L, { sid = s.sid, item = 2, resp = 1 }, "Amy")
    eq(s.rows[1]["amy"].resp, 1, "cResp on a member index lands under the leader")
    ok(s.rows[2] == nil, "no rows created under the member index")

    -- vVote on a member index also remaps to the leader.
    L.dispatch.vVote(L, { sid = s.sid, item = 2, candidate = "amy", vote = 1 }, "Tester")
    eq(s.rows[1]["amy"].votes, 1, "vVote on a member index tallies under the leader")

    -- Per-copy awards: leader first, then the next member; distinct uids; group-full gating.
    eq(L:NextAwardableIndex(1), 1, "first award -> leader copy")
    ok(L:AwardGroup(1, "Amy"), "award copy 1 to Amy")
    eq(L.activeSession.awarded[1], "Amy", "copy 1 -> Amy")
    ok(not L:GroupFullyAwarded(1), "group not full after one of two")
    eq(L:NextAwardableIndex(1), 2, "next award -> the second copy")
    ok(L:AwardGroup(1, "Bob"), "award copy 2 to Bob")
    eq(L.activeSession.awarded[2], "Bob", "copy 2 -> Bob")
    ok(L:GroupFullyAwarded(1), "group full once both copies are awarded")
    ok(not L:AwardGroup(1, "Amy"), "no copies left -> AwardGroup refuses")
    ok(L.db.global.history[s.sid .. ":1"] and L.db.global.history[s.sid .. ":2"],
        "two distinct physical history uids")
    L:EndSession()
    H.instant = nil
end)

-- ── Poll queue (UI/PollWindow.lua pure helpers) ──────────────────────────────
test("Poll queue: filtered build + value-remove advance", function()
    local function instant(classID, subClassID)
        H.instant = { 1, "t", "st", "INVTYPE_CHEST", 135, classID, subClassID }
    end
    instant(4, 1) -- everything reads as a cloth chest: usable by the mock MAGE
    local items = { { link = "item:1", quality = 4 }, { link = "item:2", quality = 4 },
                    { link = "item:3", quality = 4 } }
    local q = L:_BuildPollQueue(items)
    eq(#q, 3, "all usable -> all queued")
    eq(q[1], 1, "queue preserves session order")
    L:_PollQueueRemove(q, 2) -- answer the MIDDLE card
    eq(table.concat(q, ","), "1,3", "value-remove keeps the others' indices intact")
    L:_PollQueueRemove(q, 1)
    L:_PollQueueRemove(q, 3)
    eq(#q, 0, "queue drains")
    instant(4, 4) -- plate: the mock MAGE can't use any of them
    eq(#L:_BuildPollQueue(items), 0, "fully-filtered queue is empty")
    H.instant = nil
end)

test("Starting over a live session never clobbers its award records", function()
    L:StartSession({ { link = "[Axe]", quality = 4 } })
    L.sessionItems = { { link = "[Axe]", itemID = 1, quality = 4 } }
    local marker = L.sessionItems
    -- A second start via the staging path must refuse BEFORE touching sessionItems.
    L.stagingItems = { { link = "[Bow]", itemID = 2, quality = 4 } }
    L:LootStartStaged()
    ok(L.sessionItems == marker, "staged start over a live session left sessionItems alone")
    eq(#L.stagingItems, 1, "staging list not consumed by the refused start")
    L:EndSession()
    L.stagingItems = {}
end)

test("Entering own session clears a stale remote-ML watchdog", function()
    L:EnterSession("S-remote", "OtherML", { { link = "[X]", quality = 4 } }, L.RESPONSES, {})
    ok(L.sessionTimeout ~= nil, "watchdog armed for the remote ML")
    -- The remote ML vanishes; we start our OWN session — the stale timer must be cleared,
    -- or OnSessionTimeout closes our fresh session within 95s.
    L:StartSession({ { link = "[Y]", quality = 4 } })
    ok(L.sessionTimeout == nil, "stale watchdog cleared on entering own session")
    L:EndSession()
end)

test("OnResponseChosen carries the per-card note into the aggregated row", function()
    L:StartSession({ { link = "[Axe]", quality = 4 } })
    L:OnResponseChosen(1, L.RESPONSES[1], "per-card note")
    local row = L.session.rows[1] and L.session.rows[1]["tester"]
    ok(row ~= nil, "own response aggregated")
    eq(row and row.note, "per-card note", "note parameter rode the cResp")
    eq(row and row.resp, 1, "response id recorded")
    L:EndSession()
end)

-- ── Council-module builders (Core/Display.lua) ───────────────────────────────
test("BuildPlayerIndex unions sources + filters", function()
    L.db.global.gearCache.bob = { items = {}, by = "Bob", mod = 1 }
    L.db.global.notes.carol = { text = "x", mod = 1, by = "T" }
    L.db.global.history["s:1"] = { player = "Dave", ts = 1 }
    H.guild = { { name = "Erin", rankIndex = 1 } }
    local idx = L:BuildPlayerIndex()
    local keys = {}
    for _, e in ipairs(idx) do keys[#keys + 1] = e.key end
    eq(table.concat(keys, ","), "bob,carol,dave,erin,tester", "sorted union incl. self")
    eq(idx[2].name, "Carol", "normalized keys re-capitalized for display")
    eq(#L:BuildPlayerIndex("bo"), 1, "filter narrows to bob")
    eq(L:BuildPlayerIndex("bo")[1].key, "bob", "filtered hit")
end)

test("BuildHistoryLog: newest-first + winner filter + {uid,rec}", function()
    L.db.global.history["s:1"] = { player = "Bob", ts = 100 }
    L.db.global.history["s:2"] = { player = "Amy", ts = 300 }
    L.db.global.history["s:3"] = { player = "Bobby", ts = 200 }
    local all = L:BuildHistoryLog("")
    eq(#all, 3, "all records")
    eq(all[1].rec.ts, 300, "newest first (unwrapped rec)")
    eq(all[1].uid, "s:2", "entry carries its uid for retract")
    eq(#L:BuildHistoryLog("bob"), 2, "substring filter matches Bob + Bobby")
    eq(#L:BuildHistoryLog("zzz"), 0, "unmatched filter -> empty")
end)

-- dispatch.unaward: a bound-ML retraction clears the local awarded mirror + writes the retracted
-- record; a non-ML / foreign-sid sender is ignored (§6.15, DL-11).
test("dispatch.unaward: bound ML clears award + writes retraction", function()
    L.activeSession = { sid = "S1", ml = "Boss", viewLevel = "full", awarded = { [2] = "Amy" } }
    -- Wrong sender: ignored.
    L.dispatch.unaward(L, { sid = "S1", itemIndex = 2, winner = "Amy", item = "[X]", ts = 500 }, "Rando")
    eq(L.activeSession.awarded[2], "Amy", "non-ML unaward ignored")
    -- Bound ML: applies.
    L.dispatch.unaward(L, { sid = "S1", itemIndex = 2, winner = "Amy", item = "[X]", itemID = 9, ts = 500 }, "Boss")
    eq(L.activeSession.awarded[2], nil, "awarded mirror cleared")
    eq(L.db.global.history["S1:2"].retracted, true, "retracted history record written")
    eq(L.db.global.history["S1:2"].mod, 500, "record mod = broadcast ts (all clients converge)")
    L.activeSession = nil
end)

-- ── Self-test runner (Core/SelfTest.lua) ─────────────────────────────────────
-- The in-game checks themselves need the real client; headless we verify the RUNNER: status
-- classification, the always-runs cleanup contract, sync-completing async tests, the timeout
-- path, and the persisted report shape.
test("SelfTest runner: statuses, cleanup contract, report", function()
    local realTests = L.selfTests
    L.selfTests = {}
    local cleaned, failCleaned = false, false
    L:RegisterSelfTest("g", "passes", function(_, t) t:Ok(true, "fine") end)
    L:RegisterSelfTest("g", "fails", function(_, t) t:Eq(1, 2, "one is two") end,
        { cleanup = function() failCleaned = true end })
    L:RegisterSelfTest("g", "errors", function() error("boom") end)
    L:RegisterSelfTest("g", "skips", function(_, t) t:Skip("not here") end)
    L:RegisterSelfTest("g", "async done synchronously", function(_, t) t:Ok(true, "y"); t:Done() end,
        { async = true, cleanup = function() cleaned = true end })
    L:CmdSelfTest()

    local rep = L.db.global.selfTest
    ok(rep ~= nil, "report written to db.global.selfTest")
    eq(rep.pass, 2, "pass count")
    eq(rep.fail, 1, "fail count")
    eq(rep.error, 1, "error count")
    eq(rep.skip, 1, "skip count")
    eq(#rep.results, 5, "one result per test")
    eq(rep.results[2].status, "FAIL", "fail status recorded")
    ok(rep.results[2].msg:find("one is two"), "failure message recorded")
    eq(rep.results[3].status, "ERROR", "error status recorded")
    ok(rep.results[3].msg:find("boom"), "error message recorded")
    eq(rep.results[4].msg, "not here", "skip reason recorded")
    ok(cleaned and failCleaned, "cleanup ran for async AND failed tests")
    ok(L.selfTestRun == nil, "run state cleared after finish")
    eq(rep.ver, L:GetVersion(), "report stamps the addon version")
    L.selfTests = realTests
end)

test("SelfTest runner: async timeout fails the test, the suite continues", function()
    local realTests = L.selfTests
    L.selfTests = {}
    local timeoutFn
    local origSchedule = L.ScheduleTimer
    L.ScheduleTimer = function(_, fn) timeoutFn = fn; return {} end
    local hungCleaned = false
    L:RegisterSelfTest("g", "hangs", function() end,
        { async = true, timeout = 2, cleanup = function() hungCleaned = true end })
    L:RegisterSelfTest("g", "after the hang", function(_, t) t:Ok(true, "z") end)
    L:CmdSelfTest()
    ok(L.selfTestRun ~= nil, "runner parked waiting on the async test")
    ok(type(timeoutFn) == "function", "timeout timer armed")
    timeoutFn() -- the timeout fires
    L.ScheduleTimer = origSchedule

    local rep = L.db.global.selfTest
    ok(L.selfTestRun == nil, "run finished after the timeout resumed it")
    eq(rep.fail, 1, "hung test failed by timeout")
    ok(rep.results[1].msg:find("timed out after 2s"), "timeout message recorded")
    eq(rep.pass, 1, "the test after the hang still ran")
    ok(hungCleaned, "cleanup ran for the timed-out test")
    L.selfTests = realTests
end)

test("SelfTest runner: late Done() after a timeout is ignored", function()
    local realTests = L.selfTests
    L.selfTests = {}
    local lateT
    local origSchedule = L.ScheduleTimer
    local timeoutFn
    L.ScheduleTimer = function(_, fn) timeoutFn = fn; return {} end
    L:RegisterSelfTest("g", "hangs then answers late", function(_, t) lateT = t end,
        { async = true, timeout = 1 })
    L:CmdSelfTest()
    timeoutFn()
    L.ScheduleTimer = origSchedule
    local rep = L.db.global.selfTest
    eq(rep.fail, 1, "timed out")
    lateT:Done() -- a late item-load/echo callback fires afterwards
    eq(L.db.global.selfTest, rep, "late Done neither re-finalizes nor restarts anything")
    ok(L.selfTestRun == nil, "no phantom run resumed")
    L.selfTests = realTests
end)

test("SelfTest suite: real registrations loaded and solo session E2E skips safely when grouped", function()
    ok(#L.selfTests >= 20, "the real in-game suite registered (got " .. #L.selfTests .. ")")
    ok(type(L.dispatch.tEcho) == "function", "tEcho loopback handler registered")
end)

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
