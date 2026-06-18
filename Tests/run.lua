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

-- ── LootBrowser display array (Phase 6) ──────────────────────────────────────
test("LootBrowser BuildBrowserDisplay", function()
    local d = L:BuildBrowserDisplay("P2")
    eq(#d, 17, "raid + boss + item entries for P2")
    eq(d[1].kind, "raid", "first entry is a raid header")
    eq(d[1].text, "Serpentshrine Cavern", "raids alpha -> SSC first")
    eq(d[2].kind, "boss", "then a boss header")
    eq(d[2].text, "Hydross the Unstable", "kill order -> Hydross first")
    eq(d[3].kind, "item", "then items")
    eq(d[3].itemID, 28830, "first SSC/Hydross item")
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
    eq(table.concat(L:GetLootPhases(), ","), "P2", "only P2 has data, in PHASES order")
    eq(table.concat(L:GetRaidsForPhase("P2"), "|"), "Serpentshrine Cavern|Tempest Keep",
        "raids alphabetical")
    eq(table.concat(L:GetBossesForRaid("P2", "Serpentshrine Cavern"), "|"),
        "Hydross the Unstable|Leotheras the Blind|Lady Vashj", "bosses in kill order (_order)")
    eq(#L:GetItemsForBoss("P2", "Tempest Keep", "Al'ar"), 1, "Al'ar drops 1")
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
    eq(L:GetTierToken(29753).name, "Helm of the Fallen Champion", "token name")
    eq(L:GetTierPieceForClass(29753, "WARRIOR"), 29021, "warrior piece")
    eq(L:GetTierPieceForClass(29753, "DRUID"), nil, "no druid piece on this token")
    ok(L:FindTokenForItem(29753), "29753 is a token")
    ok(not L:FindTokenForItem(28830), "a normal item is not a token")
end)

-- ── Summary ──────────────────────────────────────────────────────────────────
print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
