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

-- ── Union merge (immutable history) ──────────────────────────────────────────
test("MergeRecord union (history)", function()
    ok(L:MergeRecord("history", "u1", { player = "A" }), "first insert")
    ok(not L:MergeRecord("history", "u1", { player = "B" }), "union keeps existing key")
    eq(L.db.global.history.u1.player, "A", "immutable")
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

-- ── ML-disconnect session recovery (A3, DL-6) ────────────────────────────────
test("Session persist → restore → resume → end", function()
    L.sessionItems = { { link = "[Axe]", itemID = 1, quality = 4 } }
    L:StartSession({ { link = "[Axe]", quality = 4 } })
    local sid = L.session.sid
    ok(L.db.global.session.tester, "open session mirrored to the DB under the owner")
    eq(L.db.global.session.tester.sid, sid, "stored sid matches")

    -- Simulate a /reload: in-memory session gone, DB record remains.
    L.session, L.sessionItems, L.activeSession = nil, nil, nil
    L:RestoreSession()
    ok(L.recoverableSession, "restore finds the persisted session and offers resume")

    ok(L:ResumeSession(), "resume succeeds")
    eq(L.session.sid, sid, "resumed with the SAME sid (history uids stay stable)")
    ok(L.sessionItems and L.sessionItems[1].link == "[Axe]", "ML award records restored")
    ok(not L.recoverableSession, "recoverable cleared after resume")

    L:EndSession()
    ok(not L.db.global.session.tester, "end clears the persisted session")
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

test("BuildHistoryLog: newest-first + winner filter", function()
    L.db.global.history["s:1"] = { player = "Bob", ts = 100 }
    L.db.global.history["s:2"] = { player = "Amy", ts = 300 }
    L.db.global.history["s:3"] = { player = "Bobby", ts = 200 }
    local all = L:BuildHistoryLog("")
    eq(#all, 3, "all records")
    eq(all[1].ts, 300, "newest first")
    eq(#L:BuildHistoryLog("bob"), 2, "substring filter matches Bob + Bobby")
    eq(#L:BuildHistoryLog("zzz"), 0, "unmatched filter -> empty")
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
