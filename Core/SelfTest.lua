-- ── LootCouncil EX — Core/SelfTest.lua ───────────────────────────────────────
-- /lcex selftest — the in-game validation harness. Runs every registered check inside the
-- live client, prints a summary, and persists the full report to db.global.selfTest so a
-- /reload flushes it to SavedVariables where Claude can read it off disk. This automates the
-- half of testing that Tests/run.lua (headless) can't reach: real WoW API existence and
-- signatures on the Anniversary client, real frame rendering, the real AceComm wire, and the
-- solo end-to-end session pipeline.
--
-- HOW TO EXTEND (do this in the same commit as any feature needing in-game validation):
--   LCEX:RegisterSelfTest(group, name, function(self, t) ... end, opts)
--     t:Ok(cond, label) / t:Eq(got, want, label)  — accumulate assertions (never throw)
--     t:Skip(reason)                              — mark skipped (return afterwards)
--     t:Done()                                    — finish an async test (opts.async = true,
--                                                   opts.timeout seconds, default 3)
--     t.info = "..."                              — informational note kept on a PASS
--   opts.cleanup = function(self) ... end         — ALWAYS runs (even after FAIL/ERROR);
--                                                   must remove every DB key / frame / timer
--                                                   the test created. Tests must leave zero
--                                                   residue in LootCouncilEXDB.
--
-- Ground rules (from the module gotchas — see docs/TESTING.md):
--   • Never SetRecord/SetNote/SetMark here (they broadcast pSet to the guild); use MergeRecord.
--   • The session E2E hard-skips when grouped — solo, GroupChannel() is nil so nothing sends.
--   • History is a union sync dataset: delete any test award record in the SAME synchronous
--     step (cleanup), before yielding to timers, or it propagates to guild peers forever.
--
-- Loads LAST in the .toc (it exercises every other module).

local LCEX = LootCouncilEX

-- Real TBC item for item-API checks (30056 Robe of Hateful Echoes, SSC — cloth INVTYPE_ROBE,
-- usable by every class). NB: 30055 is Shoulderpads of the Stranger — LEATHER, NOT universal.
local TEST_ITEM_ID = 30056
-- Session E2E items: MUST be usable by every class so the poll filter never hides them on
-- any test character — a trinket (28830 Dragonspine Trophy) and a cloth robe (30056).
local TEST_LINK_IDS = { 28830, 30056 }
-- Award target that can never collide with a real trade partner (ShortKey → "lcextestdummy").
local AWARD_DUMMY = "LCEXTestDummy"

local ALL_DATASETS = { "dummy", "notes", "marks", "history", "gearCache", "profCache", "config" }

-- ── Registry ─────────────────────────────────────────────────────────────────
LCEX.selfTests = LCEX.selfTests or {}

function LCEX:RegisterSelfTest(group, name, fn, opts)
    opts = opts or {}
    tinsert(self.selfTests, {
        group   = group,
        name    = name,
        fn      = fn,
        async   = opts.async or false,
        timeout = opts.timeout or 3,
        cleanup = opts.cleanup,
    })
end

-- ── Test context ─────────────────────────────────────────────────────────────
-- Assertions accumulate into t.fails instead of throwing, so one bad check doesn't hide the
-- rest of a test's findings; a real Lua error still aborts the test and reports ERROR.
local ContextMT = {}
ContextMT.__index = ContextMT

function ContextMT:Ok(cond, label)
    if not cond then self.fails[#self.fails + 1] = tostring(label) end
    return cond and true or false
end

function ContextMT:Eq(got, want, label)
    if got ~= want then
        self.fails[#self.fails + 1] = string.format("%s — expected %s, got %s",
            tostring(label), tostring(want), tostring(got))
        return false
    end
    return true
end

function ContextMT:Skip(reason)
    self.skipReason = tostring(reason or "skipped")
end

-- Finish an async test. Safe to call more than once (late item-load / echo callbacks after a
-- timeout are ignored). When the runner is already parked waiting on us, resume it.
function ContextMT:Done()
    if self.finished then return end
    self.finished = true
    if self.timer then
        LCEX:CancelTimer(self.timer)
        self.timer = nil
    end
    if self.waiting then
        LCEX:_SelfTestFinalize(self)
        LCEX:_SelfTestAdvance()
    end
end

local function NewContext(test)
    return setmetatable({
        test = test, fails = {}, finished = false, waiting = false,
        startedAt = GetTime(),
    }, ContextMT)
end

-- ── Runner ───────────────────────────────────────────────────────────────────
-- Sequential (state isolation beats speed here): each test runs under pcall, async tests park
-- the runner until t:Done() or the timeout, and the test's cleanup ALWAYS runs before the next
-- test starts.
function LCEX:CmdSelfTest()
    if self.selfTestRun then
        self:Msg(self.L["Self-test already running."])
        return
    end
    self.selfTestRun = {
        i = 0, results = {}, pass = 0, fail = 0, err = 0, skip = 0,
        startedAt = GetTime(),
    }
    self:Msg(string.format(self.L["Self-test: running %d checks…"], #self.selfTests))
    self:_SelfTestAdvance()
end

function LCEX:_SelfTestAdvance()
    local run = self.selfTestRun
    if not run then return end
    while true do
        run.i = run.i + 1
        local test = self.selfTests[run.i]
        if not test then
            return self:_SelfTestFinish()
        end
        local t = NewContext(test)
        local ok, err = pcall(test.fn, self, t)
        if not ok then
            t.errored = err
            self:_SelfTestFinalize(t)
        elseif test.async and not t.finished then
            t.waiting = true
            t.timer = self:ScheduleTimer(function() self:_SelfTestTimeout(t) end, test.timeout)
            return -- parked; t:Done() or the timeout resumes the loop
        else
            self:_SelfTestFinalize(t)
        end
    end
end

function LCEX:_SelfTestTimeout(t)
    if t.finished then return end
    t.timer = nil
    t.finished = true
    t.fails[#t.fails + 1] = string.format("timed out after %ds", t.test.timeout)
    self:_SelfTestFinalize(t)
    self:_SelfTestAdvance()
end

function LCEX:_SelfTestFinalize(t)
    if t.finalized then return end
    t.finalized = true
    local run = self.selfTestRun
    if not run then return end

    local status, msg
    if t.errored then
        status, msg = "ERROR", tostring(t.errored)
    elseif t.skipReason then
        status, msg = "SKIP", t.skipReason
    elseif #t.fails > 0 then
        status, msg = "FAIL", table.concat(t.fails, "; ")
    else
        status, msg = "PASS", t.info
    end

    -- The cleanup contract: runs no matter how the test ended; a cleanup error means residue,
    -- which downgrades even a PASS.
    if t.test.cleanup then
        local ok, cerr = pcall(t.test.cleanup, self)
        if not ok then
            if status == "PASS" then status = "FAIL" end
            msg = (msg and (msg .. "; ") or "") .. "cleanup error: " .. tostring(cerr)
        end
    end

    if status == "PASS" then run.pass = run.pass + 1
    elseif status == "FAIL" then run.fail = run.fail + 1
    elseif status == "ERROR" then run.err = run.err + 1
    else run.skip = run.skip + 1 end

    run.results[#run.results + 1] = {
        group  = t.test.group,
        name   = t.test.name,
        status = status,
        msg    = msg,
        ms     = math.floor((GetTime() - t.startedAt) * 1000),
    }
end

function LCEX:_SelfTestFinish()
    local run = self.selfTestRun
    self.selfTestRun = nil
    if not run then return end

    local duration = GetTime() - run.startedAt
    -- The persisted report — what Claude reads out of SavedVariables after the /reload.
    self.db.global.selfTest = {
        ver     = self:GetVersion(),
        when    = date("%Y-%m-%d %H:%M:%S"),
        ts      = time(),
        player  = UnitName("player"),
        realm   = GetRealmName(),
        build   = string.format("%s (%s, toc %s)",
            tostring((GetBuildInfo())), tostring(select(2, GetBuildInfo())),
            tostring(select(4, GetBuildInfo()))),
        locale  = GetLocale(),
        grouped = IsInGroup() and true or false,
        guilded = IsInGuild() and true or false,
        pass    = run.pass,
        fail    = run.fail,
        error   = run.err,
        skip    = run.skip,
        durationMs = math.floor(duration * 1000),
        results = run.results,
    }

    self:Msg(string.format(self.L["Self-test: %d passed, %d failed, %d errors, %d skipped (v%s, %.1fs)"],
        run.pass, run.fail, run.err, run.skip, self:GetVersion(), duration))
    for _, r in ipairs(run.results) do
        if r.status ~= "PASS" then
            local color = (r.status == "SKIP") and "999999" or "ff5555"
            self:Msg(string.format("  |cff%s%s|r %s/%s — %s",
                color, r.status, r.group, r.name, tostring(r.msg)))
        end
    end
    self:Msg(self.L["Self-test report saved. /reload to write it to disk, then tell Claude to read it."])
end

-- ── Shared helpers for the checks below ──────────────────────────────────────
-- A wire item for the fake session; prefers a real cached link so icons render, falls back to
-- the bare "item:<id>" string exactly like CmdTest's pad path.
local function FakeWireItem(i)
    local id = TEST_LINK_IDS[i] or TEST_LINK_IDS[1]
    local _, link, q = GetItemInfo(id)
    return { link = link or ("item:" .. id), itemID = id, quality = q or 4 }
end

local function ContainerAPI(name)
    return (C_Container and C_Container[name]) or _G[name]
end

-- First occupied bag slot, or nil — several API checks need a real item to poke at.
local function FirstOccupiedSlot()
    local numSlots, itemLink = ContainerAPI("GetContainerNumSlots"), ContainerAPI("GetContainerItemLink")
    for bag = 0, 4 do
        for slot = 1, (numSlots(bag) or 0) do
            if itemLink(bag, slot) then return bag, slot end
        end
    end
    return nil
end

-- ═════════════════════════════════════════════════════════════════════════════
-- The checks. Grouped: env → load → api → data → council → ui → comm → session.
-- ═════════════════════════════════════════════════════════════════════════════

-- ── env: informational facts about the live client (always PASS) ─────────────
LCEX:RegisterSelfTest("env", "client environment facts", function(self, t)
    local gii = _G.GetItemInfoInstant and "global" or (C_Item and C_Item.GetItemInfoInstant and "C_Item")
    t.info = table.concat({
        "toc=" .. tostring(select(4, GetBuildInfo())),
        "locale=" .. tostring(GetLocale()),
        "GetLootMethod=" .. (GetLootMethod and "present" or "nil"),
        "C_Container=" .. (C_Container and "present" or "nil"),
        "GetItemInfoInstant=" .. tostring(gii or "MISSING"),
        "CreateColor=" .. (CreateColor and "present" or "nil"),
        "BackdropTemplateMixin=" .. (BackdropTemplateMixin and "present" or "nil"),
        "GuildRoster=" .. (GuildRoster and "global"
            or (C_GuildInfo and C_GuildInfo.GuildRoster) and "C_GuildInfo" or "MISSING"),
    }, ", ")
end)

-- ── load: everything the .toc promised actually exists ───────────────────────
LCEX:RegisterSelfTest("load", "core functions present", function(self, t)
    local fns = {
        -- Comms / roster
        "NormalizeName", "IsSelf", "Send", "BuildEnvelope", "OnCommReceived", "DebouncedSend",
        "GroupChannel", "RecordVersion", "BroadcastVCheck", "PrintKnownVersions",
        -- Session plane
        "ResolveCouncil", "GetCouncil", "IsCouncil", "InGroupWith", "StartSession", "EndSession",
        "EnterSession", "LeaveSession", "ResumeSession", "RestoreSession", "SaveSession",
        "ShowResumePrompt", "CountSavedResponses", "_OverlaySavedRows", "MaybeRequestSession",
        "OnResponseChosen", "CompetingGear", "SendVote", "ApplyCUpdate",
        "PlayerCanUse", "ClassCanUse",
        "AwardItem", "AwardGroup", "NextAwardableIndex", "BuildItemGroups", "GroupMembers",
        "GroupFullyAwarded", "UnawardItem", "HasOwedTrade", "LogAward", "ForgetAward",
        "ScanBags", "BuildCouncilableList",
        "WithItemQuality", "WithItemID", "ItemTradeTimeRemaining", "ParseTradeDuration",
        "FormatDuration", "TradeExpiry", "SaveOwedTrades", "RestoreOwedTrades",
        "EnsureTradeTicker", "StopTradeTickerIfIdle",
        -- Council plane
        "RegisterDataset", "SetRecord", "MergeRecord", "BuildDigest", "SyncHello",
        "SetNote", "SetMark", "HistoryForPlayer", "BuildHistoryRecord",
        "SnapshotGear", "SnapshotSpec", "SnapshotProfs", "SendSelfReport",
        -- Data + display builders
        "MigrateDB", "GetVersion", "RelTime", "CacheMetaText", "ResolveBiSContext",
        "BuildGearDisplay", "BuildProfsDisplay", "BuildBiSDisplay", "BuildHistoryDisplay",
        "BuildBrowserDisplay", "GetLootPhases", "GetRaidsForPhase", "GetBossesForRaid",
        "GetItemsForBoss", "GetBiSSpecs", "GetBiSForSpecPhase", "GetTierToken",
        "GetTierPieceForClass", "FindTokenForItem", "SpecsForClass", "IsKnownClass",
        -- UI
        "CreateItemIcon", "CreateScrollList", "CreatePixelScrollList", "CreateEditBox",
        -- UI v2 (Theme + themed primitives)
        "ApplyGradient", "Surface", "SoftEdge", "ThemeText", "QualityColor", "ClassColor",
        "CreateWindowV2", "CreateFlatButton", "CreateNavRail", "CreateCheckbox", "CreateSliderV2",
        "ShowPoll", "HidePoll", "EnsurePoll", "RenderPollCards", "PollCardAnswered",
        "_PollQueueRemove", "_BuildPollQueue",
        "ShowLootWindow", "HideLootWindow", "ToggleLootWindow", "EnsureLootWindow",
        "RefreshLootWindow", "RefreshLootItem", "LootRailItems", "LootSelectItem",
        "LootStageScan", "LootStageAdd", "LootStageRemove", "LootStartStaged",
        "RegisterCouncilModule", "EnsureCouncilWindow", "ToggleCouncilWindow",
        "OpenCouncilModule", "CouncilShowModule", "BrowserSelectItem",
        "OpenPlayerDetail", "BuildPlayerIndex", "BuildHistoryLog",
        "EnsureConfigWindow", "ToggleConfigWindow", "ApplyAppearance",
        "SetupMinimapButton", "UpdateMinimapButton",
    }
    for _, name in ipairs(fns) do
        t:Ok(type(self[name]) == "function", "missing function: " .. name)
    end
end)

LCEX:RegisterSelfTest("load", "comm dispatch handlers registered", function(self, t)
    local cmds = { "vCheck", "vReply", "sStart", "sEnd", "sPing", "cResp", "cUpdate", "vVote",
                   "award", "unaward", "sReq", "sJoin", "pHello", "pSyncReq", "pSyncData",
                   "pSet", "pReport", "tEcho" }
    for _, cmd in ipairs(cmds) do
        t:Ok(type(self.dispatch[cmd]) == "function", "missing dispatch handler: " .. cmd)
    end
end)

LCEX:RegisterSelfTest("load", "datasets registered over the live stores", function(self, t)
    for _, name in ipairs(ALL_DATASETS) do
        local ds = self.datasets[name]
        if t:Ok(ds ~= nil, "dataset not registered: " .. name) then
            t:Ok(ds.store() == self.db.global[name],
                "dataset store detached from db.global: " .. name)
        end
    end
end)

LCEX:RegisterSelfTest("load", "RESPONSES table well-formed (UI is data-driven from it)", function(self, t)
    t:Ok(#self.RESPONSES >= 2, "need at least two responses")
    local sawPass = false
    for i, r in ipairs(self.RESPONSES) do
        t:Eq(r.id, i, "RESPONSES[" .. i .. "].id")
        t:Ok(type(r.key) == "string" and type(r.text) == "string", "RESPONSES[" .. i .. "] key/text")
        t:Ok(type(r.color) == "table" and #r.color == 3, "RESPONSES[" .. i .. "].color")
        if r.key == "PASS" then sawPass = true end
    end
    t:Ok(sawPass, "built-in PASS response missing")
    for name, s in pairs(self.STATUS) do
        t:Ok(s > #self.RESPONSES, "STATUS." .. name .. " overlaps response ids")
    end
end)

LCEX:RegisterSelfTest("load", "db schema + migration stamp", function(self, t)
    for _, key in ipairs({ "notes", "marks", "history", "gearCache", "profCache",
                           "pendingTrades", "session", "dummy" }) do
        t:Ok(type(self.db.global[key]) == "table", "db.global." .. key .. " missing")
    end
    t:Eq(self.db.global.dbVersion, self.DB_VERSION, "dbVersion stamp")
    t:Ok(type(self.db.profile.council) == "table", "profile.council missing")
    for _, key in ipairs({ "poll", "loot", "council", "config" }) do
        t:Ok(type(self.db.profile.ui[key]) == "table", "profile.ui." .. key .. " missing")
    end
    for _, key in ipairs({ "lootFrame", "votingFrame", "sessionFrame", "playerDetail", "lootBrowser" }) do
        t:Ok(self.db.profile.ui[key] == nil, "orphaned profile.ui." .. key .. " not cleaned up")
    end
end)

LCEX:RegisterSelfTest("load", "locale table degrades missing keys to English", function(self, t)
    t:Eq(self.L["__lcex_selftest_missing__"], "__lcex_selftest_missing__", "L metatable echo")
end)

LCEX:RegisterSelfTest("load", "embedded Ace3 libraries present", function(self, t)
    for _, lib in ipairs({ "AceAddon-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0",
                           "AceConsole-3.0", "AceDB-3.0", "AceTimer-3.0", "CallbackHandler-1.0" }) do
        t:Ok(LibStub(lib, true) ~= nil, "LibStub missing: " .. lib)
    end
end)

LCEX:RegisterSelfTest("load", "addon metadata readable (## Version)", function(self, t)
    t:Ok(self:GetVersion() ~= "dev", "GetAddOnMetadata returned nothing — version reads as 'dev'")
end)

LCEX:RegisterSelfTest("load", "minimap libs embedded + button registered", function(self, t)
    local ldb = LibStub("LibDataBroker-1.1", true)
    local dbi = LibStub("LibDBIcon-1.0", true)
    t:Ok(ldb ~= nil, "LibDataBroker-1.1 missing (embeds.xml order?)")
    t:Ok(dbi ~= nil, "LibDBIcon-1.0 missing (embeds.xml order?)")
    if ldb then
        t:Ok(ldb:GetDataObjectByName("LootCouncilEX") ~= nil, "launcher data object not registered")
    end
    if dbi then
        t:Ok(dbi:GetMinimapButton("LootCouncilEX") ~= nil, "minimap button not created")
    end
end)

-- ── api: the WoW client contract the code depends on ─────────────────────────
LCEX:RegisterSelfTest("api", "container API resolvable + callable", function(self, t)
    for _, name in ipairs({ "GetContainerNumSlots", "GetContainerItemLink",
                            "GetContainerItemInfo", "UseContainerItem" }) do
        t:Ok(ContainerAPI(name) ~= nil, name .. " missing from both C_Container and _G")
    end
    if #t.fails > 0 then return end
    t:Ok(type(ContainerAPI("GetContainerNumSlots")(0)) == "number",
        "GetContainerNumSlots(0) did not return a number")
end)

LCEX:RegisterSelfTest("api", "container item info shape (SlotInfo contract)", function(self, t)
    local bag, slot = FirstOccupiedSlot()
    if not bag then return t:Skip("bags are empty — nothing to scan") end
    local link = ContainerAPI("GetContainerItemLink")(bag, slot)
    t:Ok(type(link) == "string" and link:find("|Hitem:", 1, true) ~= nil,
        "container link is not an item link")
    local info = ContainerAPI("GetContainerItemInfo")(bag, slot)
    if type(info) == "table" then -- C_Container form (Anniversary)
        t:Ok(info.hyperlink ~= nil, "C_Container info table lacks .hyperlink")
        t:Ok(type(info.quality) == "number", "C_Container info table lacks numeric .quality")
    else -- legacy flat multi-return: 4th = quality, 7th = link
        local q = select(4, ContainerAPI("GetContainerItemInfo")(bag, slot))
        t:Ok(type(q) == "number", "flat GetContainerItemInfo 4th return (quality) not a number")
    end
end)

LCEX:RegisterSelfTest("api", "talent API signature (SnapshotSpec contract)", function(self, t)
    t:Ok(type(GetNumTalentTabs) == "function", "GetNumTalentTabs missing")
    t:Ok(type(GetTalentTabInfo) == "function", "GetTalentTabInfo missing")
    if #t.fails > 0 then return end
    local tabs = GetNumTalentTabs()
    t:Ok(type(tabs) == "number" and tabs >= 1, "GetNumTalentTabs not a positive number")
    local class = select(2, UnitClass("player"))
    local specs = self.CLASS_SPECS[class] or {}
    for tab = 1, math.min(tonumber(tabs) or 0, 3) do
        local _, name, _, _, pointsSpent = GetTalentTabInfo(tab)
        t:Ok(type(name) == "string" and name ~= "",
            "tab " .. tab .. ": 2nd return (name) not a string — signature drift")
        t:Ok(tonumber(pointsSpent) ~= nil,
            "tab " .. tab .. ": 5th return (pointsSpent) not numeric — signature drift")
        local known = false
        for _, s in ipairs(specs) do if s == name then known = true end end
        t:Ok(known, "tab " .. tab .. " name '" .. tostring(name) .. "' not a CLASS_SPECS."
            .. tostring(class) .. " tree — BiS auto-resolve would break")
    end
end)

LCEX:RegisterSelfTest("api", "unit / instance / realm basics", function(self, t)
    local n = UnitName("player")
    t:Ok(type(n) == "string" and n ~= "", "UnitName('player') empty")
    t:Ok(self:IsKnownClass(select(2, UnitClass("player"))), "UnitClass 2nd return not a known class token")
    t:Ok(type(GetInstanceInfo()) == "string", "GetInstanceInfo 1st return not a string")
    t:Ok(type(GetRealmName()) == "string", "GetRealmName not a string")
end)

LCEX:RegisterSelfTest("api", "Item mixin present (async item loads)", function(self, t)
    if not t:Ok(type(Item) == "table", "Item mixin missing") then return end
    t:Ok(type(Item.CreateFromItemID) == "function", "Item.CreateFromItemID missing")
    t:Ok(type(Item.CreateFromItemLink) == "function", "Item.CreateFromItemLink missing")
    local obj = Item:CreateFromItemID(TEST_ITEM_ID)
    if t:Ok(type(obj) == "table", "CreateFromItemID did not return an object") then
        for _, m in ipairs({ "IsItemEmpty", "IsItemDataCached", "ContinueOnItemLoad" }) do
            t:Ok(type(obj[m]) == "function", "item object missing :" .. m)
        end
    end
end)

LCEX:RegisterSelfTest("api", "GetItemInfoInstant shape (icon + equipLoc)", function(self, t)
    local gii = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
    if not t:Ok(gii ~= nil, "GetItemInfoInstant missing from both _G and C_Item") then return end
    local id, _, _, equipLoc, icon = gii(TEST_ITEM_ID)
    t:Eq(id, TEST_ITEM_ID, "1st return (itemID)")
    t:Ok(type(equipLoc) == "string" and equipLoc:find("^INVTYPE_") ~= nil,
        "4th return (equipLoc) not an INVTYPE_ token — CompetingGear would break")
    t:Ok(icon ~= nil, "5th return (icon) nil")
end)

LCEX:RegisterSelfTest("api", "GetItemStats sockets + gear-issue engine (Feature G)", function(self, t)
    -- Engine smoke: a synthetic un-enchanted chest link must flag [no enchant] and never error.
    local issues = self:GearIssuesForItem("item:" .. TEST_ITEM_ID .. ":0:0:0:0:0", 5)
    if t:Ok(type(issues) == "table", "GearIssuesForItem returned a " .. type(issues)) then
        local noEnchant = false
        for _, i in ipairs(issues) do if i.kind == "noenchant" then noEnchant = true end end
        t:Ok(noEnchant, "un-enchanted enchantable slot did not flag [no enchant]")
    end
    -- GetItemStats existence + shape drives empty-socket detection (PROJECT.md X3, DL-13). The
    -- info line reports the raw EMPTY_SOCKET_* keys so the inherent-vs-unfilled semantics can be
    -- confirmed against the live client.
    if not GetItemStats then
        t.info = "GetItemStats ABSENT — socket check no-ops (fail-safe); enchant/gem checks unaffected"
        return
    end
    local stats = GetItemStats("item:" .. TEST_ITEM_ID)
    t:Ok(stats == nil or type(stats) == "table", "GetItemStats returned a " .. type(stats))
    local socketKeys = {}
    if type(stats) == "table" then
        for k, v in pairs(stats) do
            if type(k) == "string" and k:find("EMPTY_SOCKET_", 1, true) then
                socketKeys[#socketKeys + 1] = k .. "=" .. tostring(v)
            end
        end
    end
    t.info = "GetItemStats present; sockets on #" .. TEST_ITEM_ID .. ": "
        .. (#socketKeys > 0 and table.concat(socketKeys, ", ") or "none")
end)

LCEX:RegisterSelfTest("api", "item data loads (WithItemID round-trip)", function(self, t)
    self:WithItemID(TEST_ITEM_ID, function(name)
        t:Ok(type(name) == "string" and name ~= "",
            "WithItemID resolved no name (item load / 0.5s fallback both failed)")
        t:Done()
    end)
end, { async = true, timeout = 4 })

LCEX:RegisterSelfTest("api", "trade + loot global strings, tooltip scan", function(self, t)
    t:Ok(type(BIND_TRADE_TIME_REMAINING) == "string" and BIND_TRADE_TIME_REMAINING:find("%%s") ~= nil,
        "BIND_TRADE_TIME_REMAINING missing/odd — trade-timer scan dead")
    t:Ok(type(_G.ERR_TRADE_COMPLETE) == "string",
        "ERR_TRADE_COMPLETE missing — trade completion undetectable")
    t:Ok(type(LOOT_ITEM_SELF) == "string" and LOOT_ITEM_SELF:find("%%s") ~= nil,
        "LOOT_ITEM_SELF missing/odd — passive loot tracking dead")
    local bag, slot = FirstOccupiedSlot()
    if bag then
        local rem = self:ItemTradeTimeRemaining(bag, slot)
        t:Ok(rem == nil or type(rem) == "number",
            "ItemTradeTimeRemaining returned a " .. type(rem))
    end
end)

LCEX:RegisterSelfTest("api", "session-start sound (SOUNDKIT.READY_CHECK)", function(self, t)
    t:Ok(type(PlaySound) == "function", "PlaySound missing — no session-start cue possible")
    local id = _G.SOUNDKIT and _G.SOUNDKIT.READY_CHECK
    -- Soft: absence just means the cue is silent (guarded), so report rather than fail — if nil,
    -- switch EnterSession to a numeric sound ID.
    t.info = "SOUNDKIT.READY_CHECK = " .. tostring(id)
end)

LCEX:RegisterSelfTest("api", "FauxScrollFrame + frame plumbing globals", function(self, t)
    t:Ok(type(FauxScrollFrame_Update) == "function", "FauxScrollFrame_Update missing")
    t:Ok(type(FauxScrollFrame_GetOffset) == "function", "FauxScrollFrame_GetOffset missing")
    t:Ok(type(FauxScrollFrame_OnVerticalScroll) == "function", "FauxScrollFrame_OnVerticalScroll missing")
    t:Ok(type(CreateFrame) == "function", "CreateFrame missing")
    t:Ok(type(UISpecialFrames) == "table", "UISpecialFrames missing")
    t:Ok(GameTooltip ~= nil, "GameTooltip missing")
end)

LCEX:RegisterSelfTest("api", "guild roster APIs (byRank council contract)", function(self, t)
    t:Ok((GuildRoster or (C_GuildInfo and C_GuildInfo.GuildRoster)) ~= nil,
        "no guild-roster refresh API (global or C_GuildInfo) — byRank council may go stale")
    t:Ok(type(GetNumGuildMembers) == "function", "GetNumGuildMembers missing")
    t:Ok(type(GetGuildRosterInfo) == "function", "GetGuildRosterInfo missing")
    if IsInGuild() and (GetNumGuildMembers() or 0) > 0 then
        local gname, _, rankIndex = GetGuildRosterInfo(1)
        t:Ok(type(gname) == "string", "GetGuildRosterInfo 1st return (name) not a string")
        t:Ok(type(rankIndex) == "number", "GetGuildRosterInfo 3rd return (rankIndex) not a number")
    end
end)

LCEX:RegisterSelfTest("api", "inventory + skill-line APIs", function(self, t)
    local headSlot = GetInventorySlotInfo("HeadSlot")
    t:Ok(type(headSlot) == "number", "GetInventorySlotInfo('HeadSlot') not a number")
    local link = GetInventoryItemLink("player", headSlot or 1)
    t:Ok(link == nil or type(link) == "string", "GetInventoryItemLink returned a " .. type(link))
    local n = GetNumSkillLines()
    t:Ok(type(n) == "number", "GetNumSkillLines not a number")
    if type(n) == "number" and n > 0 then
        t:Ok(type((GetSkillLineInfo(1))) == "string", "GetSkillLineInfo 1st return not a string")
    end
end)

-- ── data: static content intact on the live client ───────────────────────────
LCEX:RegisterSelfTest("data", "loot phases + tier tokens resolve", function(self, t)
    local phases = self:GetLootPhases()
    t:Ok(#phases >= 1, "no loot phases carry data")
    for _, phase in ipairs(phases) do
        local d = self:BuildBrowserDisplay(phase)
        t:Ok(#d > 0, "empty browser display for " .. phase)
        t:Eq(d[1] and d[1].kind, "raid", phase .. " display should start with a raid header")
    end
    t:Ok(self:GetTierToken(30243) ~= nil, "T5 token 30243 missing")
    local pieces = self:GetTierPieceForClass(30243, "WARRIOR")
    t:Ok(type(pieces) == "table" and #pieces > 0, "no warrior pieces for token 30243")
    t:Ok(self:GetTierToken(29759) ~= nil, "T4 token 29759 missing")
    local t4 = self:GetTierPieceForClass(29767, "WARRIOR")
    t:Ok(type(t4) == "table" and #t4 == 2, "warrior T4 legs should map to both Warbringer sets")
end)

-- ── council: Plane B against the real client (no broadcasts) ─────────────────
LCEX:RegisterSelfTest("council", "own snapshots (gear / spec / professions)", function(self, t)
    local gear = self:SnapshotGear()
    t:Ok(type(gear) == "table", "SnapshotGear not a table")
    for slot, link in pairs(gear) do
        t:Ok(type(slot) == "number" and slot >= 1 and slot <= 18, "gear slot key out of range")
        t:Ok(type(link) == "string" and link:find("|Hitem:", 1, true) ~= nil,
            "gear slot " .. tostring(slot) .. " value not an item link")
    end
    local class, spec = self:SnapshotSpec()
    t:Ok(self:IsKnownClass(class), "SnapshotSpec class not a known token")
    if spec ~= nil then
        local known = false
        for _, s in ipairs(self:SpecsForClass(class)) do if s == spec then known = true end end
        t:Ok(known, "SnapshotSpec spec '" .. tostring(spec) .. "' not a " .. tostring(class) .. " tree")
    end
    local profs = self:SnapshotProfs()
    t:Ok(type(profs) == "table", "SnapshotProfs not a table")
    for pname, rank in pairs(profs) do
        t:Ok(type(pname) == "string" and type(rank) == "number", "profession entry shape")
    end
end)

local MERGE_KEY = "__lcex_selftest__"
LCEX:RegisterSelfTest("council", "dataset merge hits the live store (no broadcast)", function(self, t)
    -- MergeRecord (not SetRecord!) — SetRecord would broadcast pSet to the guild.
    local store = self.db.global.dummy
    store[MERGE_KEY] = nil
    t:Ok(self:MergeRecord("dummy", MERGE_KEY, { text = "a", mod = 10, by = "SelfTest" }), "first merge inserts")
    t:Ok(not self:MergeRecord("dummy", MERGE_KEY, { text = "b", mod = 9, by = "SelfTest" }), "older mod rejected")
    t:Ok(self:MergeRecord("dummy", MERGE_KEY, { text = "c", mod = 11, by = "SelfTest" }), "newer mod wins")
    t:Eq(store[MERGE_KEY] and store[MERGE_KEY].text, "c", "stored text after LWW")
end, { cleanup = function(self) self.db.global.dummy[MERGE_KEY] = nil end })

-- Loopback (own-alt visibility): the sender must cache its OWN pReport — dispatch.pReport drops
-- the self-echo, so without the loopback a solo user's alts never see this character's gear.
local prevOwnGear, prevOwnProf
LCEX:RegisterSelfTest("council", "self-report loopback caches own gear (own-alt visibility)", function(self, t)
    if not self.db.profile.selfReport then return t:Skip("selfReport is disabled") end
    local key = self:NormalizeName(UnitName("player"))
    if not key then return t:Skip("player name unavailable") end
    local gearStore, profStore = self.db.global.gearCache, self.db.global.profCache
    prevOwnGear, prevOwnProf = gearStore[key], profStore[key]
    gearStore[key], profStore[key] = nil, nil
    -- End-to-end on purpose: also emits a routine pReport broadcast, same as /lcex report
    -- (idempotent — peers just re-cache the same data).
    self:SendSelfReport()
    local rec = gearStore[key]
    if t:Ok(rec ~= nil, "own gearCache record missing after SendSelfReport") then
        t:Ok(type(rec.items) == "table", "own record carries an items table")
        t:Eq(rec.by, UnitName("player"), "own record stamped by us")
    end
    t:Ok(profStore[key] ~= nil, "own profCache record missing after SendSelfReport")
end, { cleanup = function(self)
    local key = self:NormalizeName(UnitName("player"))
    if key then
        self.db.global.gearCache[key] = prevOwnGear
        self.db.global.profCache[key] = prevOwnProf
    end
    prevOwnGear, prevOwnProf = nil, nil
end })

LCEX:RegisterSelfTest("council", "digest covers every dataset", function(self, t)
    local digest = self:BuildDigest()
    for _, name in ipairs(ALL_DATASETS) do
        local d = digest[name]
        if t:Ok(type(d) == "table", "digest missing dataset: " .. name) then
            t:Ok(type(d.n) == "number" and type(d.maxMod) == "number", "digest shape for " .. name)
        end
    end
end)

-- ── ui: real frame rendering ──────────────────────────────────────────────────
LCEX:RegisterSelfTest("ui", "poll renders usable-item cards + queue advance", function(self, t)
    if self.activeSession then return t:Skip("a session is open — not stomping the live poll") end
    local items = { FakeWireItem(1), FakeWireItem(2) } -- trinket + cloth robe: universal
    self:ShowPoll(items, self.RESPONSES, 0)
    local f = self.pollFrame
    if not t:Ok(f and f:IsShown(), "poll not shown") then return end
    t:Eq(#(self.pollQueue or {}), 2, "both universal items pass the class filter")
    for slot = 1, 2 do
        local card = f.cards[slot]
        if t:Ok(card and card:IsShown(), "card " .. slot .. " not shown") then
            t:Ok(card.icon.tex:GetTexture() ~= nil, "card " .. slot .. " icon texture not set")
            -- Flat themed note box (not InputBoxTemplate): carries its own surface paint.
            t:Ok(card.note and card.note._surface ~= nil, "card " .. slot .. " note box missing the flat skin")
            for ri, resp in ipairs(self.RESPONSES) do
                local b = card.buttons[ri]
                if t:Ok(b and b:IsShown(), "card " .. slot .. " missing response button " .. ri) then
                    t:Eq(b:GetText(), resp.text, "card " .. slot .. " button " .. ri .. " text")
                end
            end
        end
    end
    t:Ok(not (f.cards[3] and f.cards[3]:IsShown()), "phantom third card")
    -- Queue advance: answer the TOP card — the next item must shift into slot 1.
    self:PollCardAnswered(self.pollQueue[1])
    t:Eq(self.pollQueue and self.pollQueue[1], 2, "queue advanced to the next item")
    t:Ok(f.cards[1] and f.cards[1]:IsShown() and f.cards[1].itemIndex == 2,
        "top slot re-filled after answering")
    t:Ok(not (f.cards[2] and f.cards[2]:IsShown()), "second slot emptied")
    self:PollCardAnswered(2)
    t:Ok(not f:IsShown(), "poll auto-closes when the queue drains")
end, { cleanup = function(self) self:HidePoll() end })

-- Backdrop-only opacity (profile.appearance.bgOpacity): the loot/poll shells + region surfaces
-- repaint with baked-in alpha (SetSurfaceAlpha stamps _lcexAlpha) while the window's own alpha —
-- what the content inherits — stays 1. Restores the prior setting afterwards.
local prevBgOpacity
LCEX:RegisterSelfTest("ui", "bgOpacity paints loot/poll backdrops only", function(self, t)
    local a = self.db.profile.appearance
    prevBgOpacity = a.bgOpacity
    local loot, poll = self:EnsureLootWindow(), self:EnsurePoll()
    a.bgOpacity = 0.5
    self:ApplyAppearance()
    t:Eq(loot._surface and loot._surface._lcexAlpha, 0.5, "loot shell surface alpha")
    t:Eq(loot.rail._surface and loot.rail._surface._lcexAlpha, 0.5, "loot rail surface alpha")
    t:Eq(loot.pane._surface and loot.pane._surface._lcexAlpha, 0.5, "loot pane surface alpha")
    -- The poll shell is BARE (chromeless + mouse-transparent): it must paint no surface of its
    -- own; bgOpacity instead lands on its header bar and registered sub-surfaces (timer bar).
    t:Ok(poll._surface == nil, "poll shell must stay bare (no backdrop surface)")
    t:Ok(not poll:IsMouseEnabled(), "poll shell margins must not eat mouse events")
    t:Eq(poll.bar._surface and poll.bar._surface._lcexAlpha, 0.5, "poll header surface alpha")
    t:Eq(poll.timerBar._surface and poll.timerBar._surface._lcexAlpha, 0.5, "poll timer-bar surface alpha")
    t:Ok(math.abs(loot:GetAlpha() - 1) < 0.001, "loot window alpha (content) must stay 1")
    t:Ok(math.abs(poll:GetAlpha() - 1) < 0.001, "poll window alpha (content) must stay 1")
end, { cleanup = function(self)
    self.db.profile.appearance.bgOpacity = prevBgOpacity
    self:ApplyAppearance()
    prevBgOpacity = nil
end })

-- Focus hygiene (flat edit boxes): a focused input must release the keyboard when combat starts
-- (the click-away path needs a live mouse, so only the combat event is driven here).
LCEX:RegisterSelfTest("ui", "edit box drops focus when combat starts", function(self, t)
    local lw = self:EnsureLootWindow()
    local eb = lw.addBox
    if not t:Ok(eb ~= nil, "no edit box available") then return end
    eb:SetFocus()
    t:Ok(self._focusedEdit == eb, "focus gained did not arm the watcher")
    t:Ok(eb._focusRoot == lw, "focus root should be the owning window")
    local w = self._editFocusWatcher
    if t:Ok(w ~= nil, "focus watcher frame missing") then
        w:GetScript("OnEvent")(w, "PLAYER_REGEN_DISABLED")
    end
    t:Ok(not (eb.HasFocus and eb:HasFocus()), "combat start must clear edit focus")
    t:Ok(self._focusedEdit == nil, "watcher not disarmed after focus loss")
end, { cleanup = function(self)
    if self._focusedEdit then self._focusedEdit:ClearFocus() end
end })

LCEX:RegisterSelfTest("ui", "loot + poll windows carry a user resize grip", function(self, t)
    local loot, poll = self:EnsureLootWindow(), self:EnsurePoll()
    t:Ok(loot.resizeGrip ~= nil, "loot window has a resize grip")
    t:Ok(poll.resizeGrip ~= nil, "poll window has a resize grip")
    -- Width-only poll: its height tracks content, so a stored height is never persisted.
    t:Ok(not (self.db.profile.ui.poll and self.db.profile.ui.poll.h), "poll never persists a height")
end)

LCEX:RegisterSelfTest("ui", "poll class filter (token lines + universals)", function(self, t)
    local class = select(2, UnitClass("player"))
    local onToken, offToken
    for id, tok in pairs(self.TierTokens) do
        if tok.pieces then
            if tok.pieces[class] and not onToken then onToken = id end
            if not tok.pieces[class] and not offToken then offToken = id end
        end
    end
    if t:Ok(onToken ~= nil, "no own-class token in TierTokens data") then
        t:Ok(self:PlayerCanUse(onToken), "own-class token was filtered out")
    end
    if t:Ok(offToken ~= nil, "no off-class token in TierTokens data") then
        t:Ok(not self:PlayerCanUse(offToken), "off-class token was NOT filtered")
    end
    t:Ok(self:PlayerCanUse(28830), "trinket must be universal")
    -- Cloth armor (30056 Robe of Hateful Echoes) is wearable by every class → never filtered.
    t:Ok(self:PlayerCanUse(30056), "cloth armor is wearable by every class")
    -- Negative case, char-agnostic via explicit classes: 30055 (Shoulderpads of the Stranger) is
    -- LEATHER — a cloth class can't wear it, a leather-wearer can (verifies the real armor subclass).
    t:Ok(not self:ClassCanUse(30055, "MAGE"), "mage cannot use leather (30055)")
    t:Ok(self:ClassCanUse(30055, "ROGUE"), "rogue can use leather (30055)")
end)

LCEX:RegisterSelfTest("ui", "loot window: staging list edits + live bag scan", function(self, t)
    if self.activeSession then return t:Skip("a session is open") end
    if #self.stagingItems > 0 then return t:Skip("staging list in use — not stomping it") end
    self:ShowLootWindow()
    local f = self.lootWindow
    if not t:Ok(f and f:IsShown(), "loot window not shown") then return end
    t:Ok(f.startBtn:IsShown() and not f.endBtn:IsShown(), "staging controls not in staging mode")
    -- Compact pre-session form (Phase 12, item 4): rail-only width, right pane hidden.
    t:Ok(math.abs(f:GetWidth() - (f.rail:GetWidth() + 4)) < 0.5,
        "pre-session window not rail-only (width " .. math.floor(f:GetWidth() or 0) .. ")")
    t:Ok(not f.pane:IsShown(), "right pane visible before a session")
    -- Empty state: short stable footer count, the body helper visible, and Start disabled (nothing
    -- to start). The long "what to do" copy lives in the body, not the footer.
    t:Eq(f.status:GetText(), string.format(self.L["%d item(s) staged."], 0), "empty-staging footer count")
    t:Ok(f.railEmpty:IsShown(), "empty-state body helper not shown with nothing staged")
    t:Ok(not f.startBtn:IsEnabled(), "Start must be disabled with zero staged items")
    t:Ok(f.railList.scroll:GetVerticalScroll() == 0, "fresh staging window starts scrolled to top")

    -- Real bag scan populates the staging list (exercises the container APIs end-to-end).
    self:LootStageScan()
    t:Ok(type(self.stagingItems) == "table", "scan did not build a staging list")

    -- Deterministic edits on a known list.
    self.stagingItems = { FakeWireItem(1), FakeWireItem(2) }
    self:RefreshLootWindow()
    t:Eq(#f.railList.items, 2, "staged items in the rail")
    t:Ok(f.railList.rows[1] and f.railList.rows[1]:IsShown(), "rail row not rendered")
    t:Ok(f.railList.rows[1].remove:IsShown(), "staging rows must carry the remove ×")
    t:Ok(not f.railEmpty:IsShown(), "empty-state helper must hide once items are staged")
    t:Ok(f.startBtn:IsEnabled(), "Start must enable once items are staged")
    self:LootStageRemove(1)
    t:Eq(#self.stagingItems, 1, "remove did not edit the staging list")
    t:Eq(#f.railList.items, 1, "rail did not follow the edit")
    t:Eq(f.status:GetText(), string.format(self.L["%d item(s) staged."], 1), "staged-count status")
end, { cleanup = function(self)
    self.stagingItems = {}
    if self.lootWindow then self.lootWindow:Hide() end
end })

LCEX:RegisterSelfTest("ui", "council window: browser module + resize + offset regression", function(self, t)
    local prevPhase = self.browserPhase
    self:OpenCouncilModule("browser")
    local f = self.councilWindow
    if not t:Ok(f and f:IsShown(), "council window not shown") then return end
    t:Ok(f:IsResizable(), "council window not resizable")
    t:Ok((f.SetResizeBounds or f.SetMinResize) ~= nil, "no resize-bounds API on this client")
    t:Eq(f.activeModule, "browser", "browser module not active")
    local panel = f.panels and f.panels.browser
    if not t:Ok(panel and panel:IsShown(), "browser panel not shown") then return end
    local phase = self.browserPhase
    if not t:Ok(phase ~= nil, "no phase selected") then return end
    t:Eq(#panel.list.items, #self:BuildBrowserDisplay(phase, self.browserExpanded),
        "browser row count for " .. tostring(phase))
    t:Ok(panel.list.rows[1] and panel.list.rows[1]:IsShown(), "first browser row not rendered")
    -- Collapse state (Phase 12, item 13): toggling a raid header adds its boss rows and folds
    -- them back away; the round-trip restores the starting count.
    local before = #panel.list.items
    local head = panel.list.items[1]
    if t:Ok(head and head.kind == "raid" and head.key ~= nil, "first row is a toggleable raid header") then
        self._selfTestFoldKey = self.browserExpanded.raids[head.key] == nil and head.key or nil
        self:BrowserToggle(panel, "raid", head.key)
        t:Ok(#panel.list.items ~= before, "toggling a raid did not change the row count")
        self:BrowserToggle(panel, "raid", head.key)
        t:Eq(#panel.list.items, before, "toggle round-trip did not restore the count")
        self._selfTestFoldKey = nil
    end
    -- The CLAUDE.md FauxScrollFrame gotcha, exercised for real: poison the offset, repopulate —
    -- the list must render from the top, never empty.
    panel.list.scroll.offset = 500
    panel.list:SetData(self:BuildBrowserDisplay(phase, self.browserExpanded))
    t:Eq(panel.list.scroll.offset, 0, "SetData did not reset the poisoned scroll offset")
    t:Ok(panel.list.rows[1] and panel.list.rows[1]:IsShown(), "list rendered empty after offset poison")
    self.browserPhase = prevPhase or self.browserPhase
end, { cleanup = function(self)
    if self._selfTestFoldKey then -- a failed toggle round-trip may leak an expanded raid
        self.browserExpanded.raids[self._selfTestFoldKey] = nil
        self._selfTestFoldKey = nil
    end
    if self.councilWindow then self.councilWindow:Hide() end
end })

LCEX:RegisterSelfTest("ui", "roster module renders for self (gear/BiS/history/gear-check sub-tabs)", function(self, t)
    local me = UnitName("player")
    -- Force a fresh BiS resolve: it only resets when the viewed player CHANGES, so a manually
    -- cycled class from an earlier look at ourselves would false-fail the assert.
    self.bisClass, self.bisSpec = nil, nil
    self:OpenPlayerDetail(me)
    local f = self.councilWindow
    if not t:Ok(f and f:IsShown(), "council window not shown") then return end
    t:Eq(f.activeModule, "roster", "roster module not active")
    local panel = f.panels and f.panels.roster
    if not t:Ok(panel and panel:IsShown(), "players panel not shown") then return end
    t:Eq(self:NormalizeName(panel.player or ""), self:NormalizeName(me), "own player not selected")
    t:Ok(#panel.playerList.items >= 1, "player picker empty")

    local function subtab(key)
        for _, b in ipairs(panel.subTabs) do
            if b.subKey == key then b:Click(); return true end
        end
        return false
    end
    t:Ok(subtab("gear"), "no gear sub-tab")
    t:Ok(#panel.detailList.items >= 1, "gear display empty (needs at least the info row)")
    t:Eq(panel.cacheMeta:GetText(), self.L["(your live snapshot)"], "self gear meta line")
    t:Ok(panel.cacheMeta:IsShown(), "cacheMeta hidden on the gear sub-tab")
    t:Ok(subtab("bis"), "no BiS sub-tab")
    t:Ok(panel.bisBar:IsShown(), "BiS cycle bar hidden on the BiS sub-tab")
    t:Eq(self.bisClass, select(2, UnitClass("player")), "BiS class auto-resolved to own class")
    t:Ok(subtab("history"), "no history sub-tab")
    t:Ok(not panel.cacheMeta:IsShown(), "cacheMeta should hide on the history sub-tab")
    t:Ok(#panel.detailList.items >= 1, "history display empty (needs at least the info row)")
    t:Ok(subtab("gearcheck"), "no Gear Check sub-tab")
    t:Ok(#panel.detailList.items >= 1, "Gear Check overview empty (needs at least the info row)")
end, { cleanup = function(self)
    self.bisClass, self.bisSpec = nil, nil
    if self.councilWindow then self.councilWindow:Hide() end
end })

LCEX:RegisterSelfTest("ui", "history + session-config modules render", function(self, t)
    self:OpenCouncilModule("history")
    local f = self.councilWindow
    local hp = f and f.panels and f.panels.history
    if t:Ok(hp and hp:IsShown(), "history panel not shown") then
        t:Eq(#hp.list.items, #self:BuildHistoryLog(""), "history rows mismatch the log builder")
    end
    -- Session Config is officer-only now (Feature C, C3). Assert it renders when this player may see
    -- it, and is correctly absent from the rail otherwise — either way exercises the gate.
    if self:CanSeeSessionConfig() then
        self:OpenCouncilModule("sessioncfg")
        local sp = f and f.panels and f.panels.sessioncfg
        if t:Ok(sp and sp:IsShown(), "session-config panel not shown") then
            t:Ok(sp.timeout ~= nil and sp.rosterList ~= nil and sp.byRank ~= nil,
                "session-config controls missing")
            t:Ok(type(sp.rosterList.items) == "table", "council roster failed to resolve")
            -- Feature V controls: the anon toggle + the ranked disenchanter editor (render-only — no
            -- SetConfigField here, which would broadcast a config change to the guild).
            t:Ok(sp.anon ~= nil and sp.deList ~= nil and sp.deAddBox ~= nil, "Feature V session controls missing")
            t:Ok(type(sp.deList.items) == "table", "disenchanter list failed to render")
            t:Ok(sp.vis ~= nil, "loot-window visibility toggle missing (C7)")
        end
    else
        t:Ok(f.panels.sessioncfg == nil, "non-council: Session Config correctly hidden from the rail")
    end
end, { cleanup = function(self)
    if self.councilWindow then self.councilWindow:Hide() end
end })

-- Cd3 (§6.11): the checkbox/slider disabled state, exercised on a throwaway host frame (no DB
-- residue — nothing here writes SavedVariables; cleanup hides the host).
LCEX:RegisterSelfTest("widgets", "checkbox + slider disabled state (Cd3)", function(self, t)
    local host = self._cd3Host or CreateFrame("Frame", nil, UIParent)
    self._cd3Host = host
    host:SetSize(220, 80)
    host:Show()

    local checked = true
    local cb = self:CreateCheckbox(host, "cd3 test", function() return checked end,
        function(v) checked = v end)
    cb:SetPoint("TOPLEFT", 0, 0)
    local sval = 3
    local sl = self:CreateSliderV2(host, { width = 180, min = 0, max = 9, step = 1, label = "cd3",
        get = function() return sval end, set = function(v) sval = v end })
    sl:SetPoint("TOPLEFT", 0, -30)

    if not t:Ok(cb.SetFlatEnabled ~= nil and sl.SetFlatEnabled ~= nil,
        "both widgets expose SetFlatEnabled") then return end

    -- IsEnabled/IsMouseEnabled return 1/nil on the Classic client, so test truthiness, not ==false.
    cb:SetFlatEnabled(false)
    sl:SetFlatEnabled(false)
    t:Ok(not cb:IsEnabled(), "disabled checkbox is not enabled")
    t:Ok(cb._flatDisabled == true, "checkbox flagged disabled")
    t:Ok(not sl.slider:IsMouseEnabled(), "disabled slider ignores the mouse")
    t:Ok(sl._flatDisabled == true, "slider flagged disabled")

    cb:SetFlatEnabled(true)
    sl:SetFlatEnabled(true)
    t:Ok(cb:IsEnabled() and true or false, "re-enabled checkbox is enabled")
    t:Ok(cb._flatDisabled == nil, "checkbox disabled flag cleared")
    t:Ok(sl.slider:IsMouseEnabled() and true or false, "re-enabled slider takes the mouse")
    t:Ok(sl._flatDisabled == nil, "slider disabled flag cleared")
end, { cleanup = function(self)
    if self._cd3Host then self._cd3Host:Hide() end
end })

LCEX:RegisterSelfTest("api", "guild bank API contract (Feature B)", function(self, t)
    -- The net-new BCC guild-bank APIs the scanner relies on exist on the live client (X3). Existence
    -- only — the query/read functions need an open bank, and GetGuildBankMoneyTransaction crashes on
    -- a bad index, so the scanner (not the selftest) calls them.
    for _, name in ipairs({ "GetNumGuildBankTabs", "GetGuildBankTabInfo", "QueryGuildBankTab",
                            "GetGuildBankItemLink", "GetGuildBankItemInfo", "GetGuildBankMoney",
                            "QueryGuildBankLog", "GetNumGuildBankTransactions", "GetGuildBankTransaction",
                            "GetNumGuildBankMoneyTransactions", "GetGuildBankMoneyTransaction" }) do
        t:Ok(type(_G[name]) == "function", "missing guild-bank API: " .. name)
    end
end)

LCEX:RegisterSelfTest("data", "guild bank ledger: uid dedup + grouping (pure, Feature B)", function(self, t)
    t:Eq(self:GbankNormalizeKind("withdrawal"), "withdraw", "withdrawal folds to withdraw")
    t:Eq(self:GbankTxnUid("withdraw", "A", "i:1", 2, "1>", 5),
         self:GbankTxnUid("withdrawal", "A", "i:1", 2, "1>", 5), "normalized kinds share a uid")
    local groups = self:BuildGbankGroups({
        { uid = "g1", kind = "deposit", player = "A", itemLink = "i:1", count = 2, ts = 3600000 },
        { uid = "g2", kind = "deposit", player = "A", itemLink = "i:1", count = 1, ts = 3600000 },
        { uid = "g3", kind = "withdraw", player = "B", itemLink = "i:9", count = 1, ts = 3600000 },
    })
    t:Eq(#groups, 2, "A's deposits group; B's withdraw is separate")
    t:Eq(groups[1].items[1].count, 3, "identical items collapse to xN")
end)

LCEX:RegisterSelfTest("load", "guild scoping active (Feature C, C6)", function(self, t)
    t:Ok(type(self.SyncGuildScope) == "function", "SyncGuildScope missing")
    t:Ok(type(self.db.global.guilds) == "table", "guilds namespace present")
    -- Safe to run for real: for the CURRENT guild this is a claim-in-place / no-op — it never moves
    -- data. Afterward the flat datasets are scoped to this guild (or _local when solo).
    self:SyncGuildScope()
    local key = self:GuildKey() or "_local"
    t:Eq(self.db.global.activeGuild, key, "flat datasets scoped to the current guild")
end)

LCEX:RegisterSelfTest("load", "inherit-on-first-load flow present (Feature C)", function(self, t)
    for _, fn in ipairs({ "GateConfigInherit", "PromptInherit", "AcceptInherit", "DeclineInherit" }) do
        t:Ok(type(self[fn]) == "function", "missing inherit function: " .. fn)
    end
    -- Safe no-op path: a record for a key other than ours is never gated — returns false before any
    -- prompt or pending state, so this can't pop a dialog or mutate the real inherit decision.
    t:Ok(self:GateConfigInherit("__lcex_bogus_key__", { mod = 1 }, "Nobody") == false,
        "a foreign-key config record is not gated")
    t:Ok(self._pendingInherit == nil, "no pending inherit left after the no-op check")
end)

LCEX:RegisterSelfTest("load", "access predicates resolve (Feature C / DL-18)", function(self, t)
    for _, fn in ipairs({ "CanEditConfig", "CanSeeSessionConfig", "LootViewLevel",
                          "LootWindowOptIn", "MyGuildRank" }) do
        t:Ok(type(self[fn]) == "function", "missing access predicate: " .. fn)
    end
    t:Ok(type(self:CanSeeSessionConfig()) == "boolean", "CanSeeSessionConfig returns a boolean")
    local lvl = self:LootViewLevel()
    t:Ok(lvl == "full" or lvl == "list", "LootViewLevel must be full|list (got " .. tostring(lvl) .. ")")
    -- Council always gets the full view (the opt-in only matters for non-council raiders).
    if self:AmCouncil() then t:Eq(lvl, "full", "council must resolve the full view") end
end)

LCEX:RegisterSelfTest("ui", "guild bank module renders (Feature B)", function(self, t)
    self:OpenCouncilModule("gbank")
    local f = self.councilWindow
    local gp = f and f.panels and f.panels.gbank
    if t:Ok(gp and gp:IsShown(), "gbank panel not shown") then
        t:Ok(gp.hero ~= nil and gp.grid ~= nil and gp.logList ~= nil, "gbank controls missing")
        t:Eq(#gp.gridIcons, 98, "contents grid has 14x7 slots")
        t:Ok(gp.hero.gold:GetText() ~= nil, "hero gold rendered from the cache")
        t:Ok(type(self.GbankNote) == "function" and type(self.SetGbankNote) == "function",
            "annotation accessors present")
        -- The Log sub-tab is officer-only by default (B5); only exercise it when this player may see it.
        if self:CanSeeGbankLog() then
            for _, b in ipairs(gp.subTabs) do if b.subKey == "log" then b:Click() end end
            t:Ok(gp.logList:IsShown(), "log sub-tab shows the grouped list")
            for _, b in ipairs(gp.subTabs) do if b.subKey == "contents" then b:Click() end end
        end
    end
end, { cleanup = function(self)
    if self.councilWindow then self.councilWindow:Hide() end
end })

LCEX:RegisterSelfTest("ui", "confirm popup + loot-window D/E control (Feature V)", function(self, t)
    -- The reusable confirm (D/E send; later Feature C's inherit prompt): accept fires onAccept with
    -- the input text when a manual-target field is shown, and dismisses. No DB writes here.
    local got
    self:ShowConfirm({ text = "test?", input = "Sharder", onAccept = function(v) got = v end })
    local cf = self._confirmFrame
    if t:Ok(cf and cf:IsShown(), "confirm popup did not open") then
        t:Ok(cf.input:IsShown(), "input field should show for a manual-target confirm")
        cf.acceptBtn:Click()
        t:Eq(got, "Sharder", "onAccept did not receive the input text")
        t:Ok(not cf:IsShown(), "confirm popup did not dismiss on accept")
    end
    -- Plain Yes/No (no input): onAccept gets nil, the input field hides.
    local ran = false
    self:ShowConfirm({ text = "ok?", onAccept = function(v) ran = (v == nil) end })
    t:Ok(cf and not cf.input:IsShown(), "input should hide for a plain confirm")
    if cf then cf.acceptBtn:Click() end
    t:Ok(ran, "plain confirm accept did not fire with nil input")

    -- The loot window exposes the ML-only D/E control.
    self:EnsureLootWindow()
    t:Ok(self.lootWindow and self.lootWindow.deBtn ~= nil, "loot window missing the D/E button")
end, { cleanup = function(self)
    if self._confirmFrame then self._confirmFrame:Hide() end
end })

LCEX:RegisterSelfTest("ui", "config window renders its schema + appearance plumbing", function(self, t)
    self:ToggleConfigWindow()
    local f = self.configWindow
    if not t:Ok(f and f:IsShown(), "config window not shown") then return end
    t:Ok(#f.controls >= 8, "schema controls missing (got " .. tostring(f and #f.controls) .. ")")
    -- Appearance round-trip: opacity reaches the council window (the opted-in one).
    local a = self.db.profile.appearance
    local prevOpacity = a.opacity
    a.opacity = 0.7
    self:EnsureCouncilWindow()
    self:ApplyAppearance()
    local alpha = self.councilWindow:GetAlpha()
    t:Ok(math.abs(alpha - 0.7) < 0.02, "council opacity not applied (alpha " .. string.format("%.2f", alpha) .. ")")
    a.opacity = prevOpacity
    self:ApplyAppearance()
end, { cleanup = function(self)
    if self.configWindow then self.configWindow:Hide() end
    if self.councilWindow then self.councilWindow:Hide() end
end })

LCEX:RegisterSelfTest("ui", "all windows registered for ESC-close", function(self, t)
    self:EnsurePoll(); self:EnsureLootWindow(); self:EnsureCouncilWindow(); self:EnsureConfigWindow()
    for _, name in ipairs({ "LCEX_PollWindow", "LCEX_LootWindow", "LCEX_CouncilWindow",
                            "LCEX_ConfigWindow" }) do
        t:Ok(_G[name] ~= nil, "global frame missing: " .. name)
        local found = false
        for _, n in ipairs(UISpecialFrames) do
            if n == name then found = true end
        end
        t:Ok(found, name .. " not in UISpecialFrames")
    end
end)

-- Phase 12 (DL-23): CreateScrollList must resolve the Faux template's scrollbar and re-anchor it
-- INSIDE the list frame (items 12/18) — otherwise it renders across the owning panel's divider.
LCEX:RegisterSelfTest("ui", "scroll list: scrollbar re-anchored inside the list", function(self, t)
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(200, 120)
    host:Hide()
    self._selfTestScrollHost = host
    local list = self:CreateScrollList(host, {
        rowHeight = 20, visibleRows = 4, width = 200,
        buildRow = function(parent) return CreateFrame("Button", nil, parent) end,
        fillRow  = function() end,
    })
    list:SetPoint("TOPLEFT", 0, 0)
    if not t:Ok(list.scrollBar ~= nil, "scrollbar not resolved (template parentKey + child scan both failed)") then
        return
    end
    t:Ok(list.scrollBar:IsObjectType("Slider"), "resolved scrollbar is not a Slider")
    local inside = 0
    for i = 1, list.scrollBar:GetNumPoints() do
        local _, rel = list.scrollBar:GetPoint(i)
        if rel == list then inside = inside + 1 end
    end
    t:Eq(inside, 2, "scrollbar anchor points referencing the list frame")
end, { cleanup = function(self)
    if self._selfTestScrollHost then
        self._selfTestScrollHost:Hide()
        self._selfTestScrollHost:SetParent(nil)
        self._selfTestScrollHost = nil
    end
end })

-- Window z-order: two co-shown v2 windows must occupy DISTINCT frame levels. On the TBC client
-- frame:Raise() alone leaves co-shown DIALOG windows at the same level, so the client interleaves
-- their children by creation order and one window's rows draw THROUGH the other (the loot⇄council
-- overlap). CreateWindowV2 fixes this by giving each window a distinct base level at creation plus
-- SetToplevel(true); this guards the observable property (distinct levels) against regression.
LCEX:RegisterSelfTest("ui", "v2 windows: co-shown windows get distinct frame levels (no draw-through)", function(self, t)
    local loot    = self:EnsureLootWindow()
    local council = self:EnsureCouncilWindow()
    local la, lc = loot:GetFrameLevel(), council:GetFrameLevel()
    t:Ok(la ~= lc, string.format(
        "loot & council share frame level %d — their child rows will interleave on overlap", la))
    -- The bands must be far enough apart that the lower window's deepest child still sits below the
    -- higher window's base (CreateWindowV2 reserves 20 levels per window).
    t:Ok(math.abs(la - lc) >= 2, string.format(
        "window level bands only %d apart — too close to separate child stacks", math.abs(la - lc)))
end)

-- Compact staging list uses a REAL ScrollFrame (pixel scrolling): rows are children of one scroll
-- child sliding under a clipped viewport, the flat scrollbar is a bare Slider (no stock arrows).
-- SetData PRESERVES the pixel offset (clamped into the new range) so selection never snaps the view;
-- only ScrollToTop resets. The bar (and its gutter) only appear when content overflows.
-- The host is SHOWN offscreen with EXPLICIT sizes so the frame chain actually lays out — a hidden,
-- anchor-derived host reports a 0 viewport height, which breaks every scroll-math assertion.
LCEX:RegisterSelfTest("ui", "pixel scroll list: preserve/clamp offset, flat bar, gutter, ScrollToTop", function(self, t)
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", 0, 0) -- fully offscreen, but a resolved anchor
    host:SetSize(200, 120)
    self._selfTestPixelHost = host
    local list = self:CreatePixelScrollList(host, {
        rowHeight = 30, width = 200, gutter = 14, zebra = true,
        buildRow = function(parent) return CreateFrame("Button", nil, parent) end,
        fillRow  = function() end,
    })
    list:SetPoint("TOPLEFT", 0, 0)
    list:SetSize(200, 120) -- explicit viewport: 6×30=180 content overflows, 2×30=60 fits
    t:Ok(list.scroll and list.scroll:IsObjectType("ScrollFrame"), "viewport is a real ScrollFrame")
    t:Ok(list.child and list.scroll:GetScrollChild() == list.child, "scroll child wired to the viewport")
    t:Ok(list.scrollBar and list.scrollBar:IsObjectType("Slider"), "flat scrollbar is a Slider")
    -- A bare Slider carries no stock arrow-button children (the STYLE/SCROLLBAR_DEFAULT trap).
    t:Ok(list.scrollBar.ScrollUpButton == nil and list.scrollBar.ScrollDownButton == nil,
        "flat scrollbar must not carry stock arrow buttons")

    -- Overflow → the bar (and its gutter) appear.
    list:SetData({ 1, 2, 3, 4, 5, 6 })
    t:Ok(list.scrollBar:IsShown(), "scrollbar must show when content overflows")
    t:Ok(list.rows[1] and list.rows[1]:GetParent() == list.child, "rows parent to the scroll child")
    -- Scroll down, then repaint the SAME list → offset holds (selection must not snap to top).
    list.scrollBar:SetValue(40)
    list:SetData({ 1, 2, 3, 4, 5, 6 })
    t:Eq(list.scroll:GetVerticalScroll(), 40, "SetData preserves the pixel scroll offset")
    -- Shrink below the viewport: offset clamps to 0 AND the bar/gutter go away so rows fill the width.
    list:SetData({ 1, 2 })
    t:Eq(list.scroll:GetVerticalScroll(), 0, "SetData clamps offset to the shrunken range")
    t:Ok(not list.scrollBar:IsShown(), "scrollbar (and its gutter) must hide when content fits")
    -- Explicit reset is the only path back to the top.
    list:SetData({ 1, 2, 3, 4, 5, 6 })
    list.scrollBar:SetValue(40)
    list:ScrollToTop()
    t:Eq(list.scroll:GetVerticalScroll(), 0, "ScrollToTop resets to the top")
end, { cleanup = function(self)
    if self._selfTestPixelHost then
        self._selfTestPixelHost:Hide()
        self._selfTestPixelHost:SetParent(nil)
        self._selfTestPixelHost = nil
    end
end })

-- Phase 12 (DL-23): the shared zebra layer stripes by ABSOLUTE index parity (even rows lighten).
LCEX:RegisterSelfTest("ui", "scroll list: zebra stripes alternate by absolute index", function(self, t)
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(200, 120)
    host:Hide()
    self._selfTestZebraHost = host
    local list = self:CreateScrollList(host, {
        rowHeight = 20, visibleRows = 4, width = 200, zebra = true,
        buildRow = function(parent) return CreateFrame("Button", nil, parent) end,
        fillRow  = function() end,
    })
    list:SetPoint("TOPLEFT", 0, 0)
    list:SetData({ "a", "b", "c" })
    for i = 1, 3 do
        local row = list.rows[i]
        if t:Ok(row and row._stripe ~= nil, "row " .. i .. " missing the stripe texture") then
            t:Eq(row._stripe:IsShown() and true or false, i % 2 == 0, "row " .. i .. " stripe parity")
        end
    end
end, { cleanup = function(self)
    if self._selfTestZebraHost then
        self._selfTestZebraHost:Hide()
        self._selfTestZebraHost:SetParent(nil)
        self._selfTestZebraHost = nil
    end
end })

-- Phase 12 (DL-23): flat buttons carry a disabled state (award-button grey-out rides on it).
LCEX:RegisterSelfTest("ui", "flat button: SetFlatEnabled disable/enable round-trip", function(self, t)
    local host = CreateFrame("Frame", nil, UIParent)
    host:Hide()
    self._selfTestBtnHost = host
    local b = self:CreateFlatButton(host, "Probe", 60, 20, "accent")
    t:Ok(b.SetFlatEnabled ~= nil, "SetFlatEnabled missing")
    b:SetFlatEnabled(false)
    t:Ok(not b:IsEnabled(), "button still enabled after SetFlatEnabled(false)")
    t:Ok(b._flatDisabled == true, "hover guard flag not set")
    b:SetFlatEnabled(true)
    t:Ok(b:IsEnabled() and true or false, "button not re-enabled")
    t:Ok(b._flatDisabled == nil, "hover guard flag not cleared")
end, { cleanup = function(self)
    if self._selfTestBtnHost then
        self._selfTestBtnHost:Hide()
        self._selfTestBtnHost:SetParent(nil)
        self._selfTestBtnHost = nil
    end
end })

-- Phase 12 (DL-23): the shared context menu — build, disabled rows, click-through, dismissal.
LCEX:RegisterSelfTest("ui", "context menu: rows render, disabled row inert, click closes", function(self, t)
    local clicked = false
    local menu = self:ShowContextMenu({
        title = "Probe",
        items = {
            { text = "Run",      onClick = function() clicked = true end },
            { text = "Dimmed",   disabled = true },
            { text = "Danger",   danger = true, onClick = function() end },
        },
    })
    if not t:Ok(menu and menu:IsShown(), "menu not shown") then return end
    t:Ok(menu.catcher:IsShown() and true or false, "click-catcher not shown")
    for i = 1, 3 do
        t:Ok(menu.rows[i] and menu.rows[i]:IsShown(), "row " .. i .. " not shown")
    end
    t:Ok(menu.rows[2]._off == true, "disabled row not marked inert")
    menu.rows[2]:Click()
    t:Ok(menu:IsShown() and true or false, "disabled row click must not close the menu")
    menu.rows[1]:Click()
    t:Ok(clicked, "item onClick did not run")
    t:Ok(not menu:IsShown(), "menu still shown after an item click")
    t:Ok(not menu.catcher:IsShown(), "catcher still shown after dismiss")
    local found = false
    for _, n in ipairs(UISpecialFrames) do
        if n == "LCEX_ContextMenu" then found = true end
    end
    t:Ok(found, "context menu not registered for ESC-close")
end, { cleanup = function(self) self:HideContextMenu() end })

-- Phase 12 (item 17): the right-click note flow replaces the bottom mark box. The mark is
-- planted directly in the dataset (NOT via SetMark — that would broadcast pSet) and restored
-- synchronously in cleanup.
LCEX:RegisterSelfTest("ui", "browser: right-click note menu (leave/clear)", function(self, t)
    self:OpenCouncilModule("browser")
    local panel = self.councilWindow and self.councilWindow.panels and self.councilWindow.panels.browser
    if not t:Ok(panel ~= nil, "browser panel missing") then return end
    t:Ok(panel.markBox == nil, "the always-visible mark box must be gone")

    self:BrowserItemMenu(panel, TEST_ITEM_ID, nil)
    local menu = self._contextMenu
    if not t:Ok(menu and menu:IsShown(), "note menu did not open") then return end
    t:Eq(menu.rows[1].fs:GetText(), self.L["Leave note…"], "first entry is Leave note")
    t:Ok(not (menu.rows[2] and menu.rows[2]:IsShown()), "Clear entry must not show without a mark")
    self:HideContextMenu()

    self._selfTestMarkStash = self.db.global.marks[TEST_ITEM_ID]
    self.db.global.marks[TEST_ITEM_ID] = { text = "selftest", mod = time(), by = "SelfTest" }
    self:BrowserItemMenu(panel, TEST_ITEM_ID, nil)
    t:Ok(menu.rows[2] and menu.rows[2]:IsShown()
        and menu.rows[2].fs:GetText() == self.L["Clear note"], "Clear note entry with a mark")
end, { cleanup = function(self)
    self.db.global.marks[TEST_ITEM_ID] = self._selfTestMarkStash
    self._selfTestMarkStash = nil
    self:HideContextMenu()
    if self.councilWindow then self.councilWindow:Hide() end
end })

-- ── comm: the real receive path + the real wire ───────────────────────────────
-- tEcho: the self-test's loopback cmd. Deliberately has NO IsSelf-drop (unlike every production
-- handler) — it only ever acts when a self-test armed _selfTestEcho with a matching nonce, so
-- another player's tEcho (or one arriving outside a run) is ignored without side effects.
LCEX.dispatch.tEcho = function(self, msg, sender)
    local pending = self._selfTestEcho
    if not pending or not self:IsSelf(sender) or msg.nonce ~= pending.nonce then return end
    self._selfTestEcho = nil
    pending.cb(msg)
end

LCEX:RegisterSelfTest("comm", "receive path + serializer fidelity (in-process)", function(self, t)
    local got
    self._selfTestEcho = { nonce = "inproc", cb = function(msg) got = msg end }
    local wire = self:Serialize(self:BuildEnvelope("tEcho", "sid-selftest", {
        nonce = "inproc", probe = { 1, "two", { three = true } },
    }))
    t:Ok(type(wire) == "string", "Serialize did not return a string")
    local ok = pcall(self.OnCommReceived, self, "LCEX", wire, "WHISPER", UnitName("player"))
    t:Ok(ok, "OnCommReceived errored on a valid envelope")
    if t:Ok(got ~= nil, "valid envelope was not dispatched") then
        t:Eq(got.sid, "sid-selftest", "sid survived the round-trip")
        t:Ok(type(got.probe) == "table" and got.probe[1] == 1 and got.probe[2] == "two"
            and type(got.probe[3]) == "table" and got.probe[3].three == true,
            "nested payload corrupted through Serialize/Deserialize")
    end
end, { cleanup = function(self) self._selfTestEcho = nil end })

LCEX:RegisterSelfTest("comm", "malformed + future-version envelopes dropped", function(self, t)
    self._selfTestEcho = { nonce = "drop", cb = function() end }
    t:Ok(pcall(self.OnCommReceived, self, "LCEX", "not a serialized table", "GUILD", UnitName("player")),
        "garbage payload errored the receive path")
    t:Ok(self._selfTestEcho ~= nil, "garbage payload was dispatched")
    local msg = self:BuildEnvelope("tEcho", nil, { nonce = "drop" })
    msg.v = self.PROTOCOL_VERSION + 1
    t:Ok(pcall(self.OnCommReceived, self, "LCEX", self:Serialize(msg), "GUILD", UnitName("player")),
        "future-version envelope errored the receive path")
    t:Ok(self._selfTestEcho ~= nil, "future-version envelope must be dropped, not dispatched")
end, { cleanup = function(self) self._selfTestEcho = nil end })

-- RCLC bridge codec (§6.18): the real AceSerializer + LibDeflate pipeline the headless harness
-- can't run (it identity-mocks Serialize and has no LibDeflate). Proves the vendored lib is wired
-- and both single-table and multi-arg RCLC payloads survive encode→decode; garbage decodes to nil.
LCEX:RegisterSelfTest("comm", "RCLC codec round-trips (AceSerializer + LibDeflate)", function(self, t)
    if not self:RCLCReady() then return t:Skip("LibDeflate not loaded — RCLC bridge inert") end
    local mldb = self:RCLC_BuildMLDB(self.RESPONSES, 45)
    local enc = self:RCLCEncode("mldb", mldb)
    if not t:Ok(type(enc) == "string" and #enc > 0, "encode produced a channel-safe string") then return end
    local cmd, args = self:RCLCDecode(enc)
    t:Eq(cmd, "mldb", "command survived the round-trip")
    t:Ok(args and args[1] and args[1].numButtons == mldb.numButtons, "mldb numButtons survived")
    t:Eq(args and args[1] and args[1].buttons.default[1].text, "BiS", "nested button text survived")
    local cmd2, a2 = self:RCLCDecode(self:RCLCEncode("awarded", 3, "Winner", "Mlchar"))
    t:Eq(cmd2, "awarded", "multi-arg command survived")
    t:Ok(a2 and a2[1] == 3 and a2[2] == "Winner" and a2[3] == "Mlchar", "multi-arg values survived")
    t:Ok((self:RCLCDecode("!!!not-a-valid-blob!!!")) == nil, "garbage decodes to nil, not an error")
end)

-- The RCLC receive path end-to-end (real decode + dispatch routing + per-handler pcall isolation).
-- No open session, so the response handler gates itself out — we're proving the wiring never
-- errors on valid, garbage, self-echo, or wrong-prefix input (untrusted network).
LCEX:RegisterSelfTest("comm", "RCLC receive path is robust", function(self, t)
    if not self:RCLCReady() then return t:Skip("LibDeflate not loaded — RCLC bridge inert") end
    local wire = self:RCLCEncode("response", 1, { response = 1, note = "" })
    t:Ok(pcall(self.OnRCLCReceived, self, "RCLC", wire, "RAID", "Rclcprobe"), "valid message errored the receive path")
    t:Ok(pcall(self.OnRCLCReceived, self, "RCLC", "not-a-real-blob", "RAID", "Rclcprobe"), "garbage errored the receive path")
    t:Ok(pcall(self.OnRCLCReceived, self, "RCLC", wire, "RAID", UnitName("player")), "self-echo errored the receive path")
    t:Ok(pcall(self.OnRCLCReceived, self, "LCEX", wire, "RAID", "Rclcprobe"), "wrong prefix errored the receive path")
end)

LCEX:RegisterSelfTest("comm", "live wire loopback (GUILD echo)", function(self, t)
    if not IsInGuild() then return t:Skip("not in a guild — no addon channel to echo over") end
    local nonce = UnitName("player") .. ":" .. tostring(GetTime())
    self._selfTestEcho = {
        nonce = nonce,
        cb = function(msg)
            t:Eq(msg.v, self.PROTOCOL_VERSION, "protocol version on the wire")
            t:Eq(msg.ver, self:GetVersion(), "addon version stamp on the wire")
            t:Ok(type(msg.probe) == "table" and msg.probe.deep and msg.probe.deep[2] == "two",
                "payload corrupted over the real wire")
            t:Done()
        end,
    }
    self:Send("tEcho", nil, { nonce = nonce, probe = { deep = { 1, "two" } } }, "GUILD")
end, { async = true, timeout = 8, cleanup = function(self) self._selfTestEcho = nil end })

-- ── session: the solo end-to-end pipeline ─────────────────────────────────────
-- Automates TESTING.md section A: start → respond → vote (incl. the toggle) → award → end,
-- through the SAME entry points the buttons use. Solo only: with a group, sStart/award would
-- broadcast to real players (and every present client would log the fake award to history).
-- Pure award-readiness cascade (Feature V, §6.10) — no session/frame/DB side effects, so it needs
-- no cleanup. Mirrors the headless Tests/run.lua coverage, run against the LIVE client's Lua, and
-- confirms every status kind resolves to a theme color (the rail-row border, LootWindow.lua).
LCEX:RegisterSelfTest("session", "award-readiness cascade + status colors (pure)", function(self, t)
    local PASS = self:PassResponseId()
    local function kind(rows, opts)
        opts = opts or {}
        return self:ReadinessStatus({ rows = rows, passId = PASS, awarded = opts.awarded,
            votesCast = opts.votesCast, councilPresent = opts.councilPresent }).kind
    end
    t:Eq(kind({ a = { reason = "pending" } }), "waiting", "unresponded eligible -> waiting")
    t:Eq(kind({ a = { resp = PASS }, b = { resp = PASS } }), "de", "all passed -> disenchant")
    t:Eq(kind({ a = { resp = 1 }, b = { resp = PASS } }), "ready", "lone roller -> ready")
    t:Eq(kind({ a = { resp = 1 }, b = { resp = 1 } }, { councilPresent = 2, votesCast = 0 }),
        "voting", "multiple rollers, no votes -> voting")
    t:Eq(kind({ a = { resp = 1 }, b = { resp = 1 } }, { councilPresent = 2, votesCast = 2 }),
        "ready", "all present council voted -> ready")
    t:Eq(kind({ a = { reason = "pending" } }, { awarded = true }), "awarded", "awarded overrides")
    t:Eq(kind({ a = { reason = "cantuse" }, b = { reason = "left" } }), "waiting",
        "zero present-eligible -> waiting")
    for _, k in ipairs({ "waiting", "ready", "de", "awarded", "voting" }) do
        t:Ok(type(self:StatusColor(k)) == "table", "no theme color for status: " .. k)
    end
    t:Ok(self:StatusColor(nil) == nil, "nil kind should map to no color")
    -- Award-reason text (V5): D/E for a disenchant, the response text for a real response, and no
    -- reason clause for an ML-assigned (ANNOUNCED) award.
    t:Eq(self:AwardReasonText(self.STATUS.DISENCHANT), self.L["D/E"], "disenchant reason -> D/E")
    t:Ok(self:AwardReasonText(self.RESPONSES[1].id) ~= nil, "a real response id yields reason text")
    t:Eq(self:AwardReasonText(self.STATUS.ANNOUNCED), nil, "announced -> no reason clause")
end)

LCEX:RegisterSelfTest("session", "solo end-to-end: start → respond → vote → award → end", function(self, t)
    if self.session or self.activeSession then return t:Skip("a session is already open") end
    if self.recoverableSession then return t:Skip("an unfinished session is pending /lcex resume") end
    if self:GroupChannel() then return t:Skip("grouped — run the self-test solo so nothing broadcasts") end

    local meName = UnitName("player")
    local me = self:NormalizeName(meName)
    local items = { FakeWireItem(1), FakeWireItem(2) }
    -- StartSession alone doesn't set sessionItems (CmdTest/CmdStartFromBags do) — AwardItem
    -- reads it, so build the ML-side records the same way CmdTest does.
    self.sessionItems = {}
    for i, it in ipairs(items) do
        self.sessionItems[i] = { link = it.link, itemID = it.itemID, quality = it.quality,
                                 boss = "Self-Test", lootedAt = time() }
    end
    self:StartSession({ { link = items[1].link, quality = items[1].quality },
                        { link = items[2].link, quality = items[2].quality } })
    local s = self.session
    if not t:Ok(s ~= nil, "StartSession did not open a session") then return end
    self._selfTestSid = s.sid -- cleanup key: the uids to purge even if we error below

    t:Eq(#s.items, 2, "session item count")
    t:Ok(self.activeSession and self.activeSession.sid == s.sid, "ML did not enter its own session")
    t:Ok(self.activeSession and self.activeSession.amCouncil, "runner not on the session council (council-of-one)")
    t:Ok(self.pollFrame and self.pollFrame:IsShown(), "poll did not open")
    t:Eq(#(self.pollQueue or {}), 2, "poll queue should hold both universal items")
    t:Ok(self.lootWindow and self.lootWindow:IsShown(), "loot window did not open")
    t:Ok(self.lootWindow and self.lootWindow.endBtn:IsShown()
        and not self.lootWindow.startBtn:IsShown(), "loot window not in session mode")
    -- Full layout in-session (Phase 12, item 4): pane shown, window expanded past the rail.
    t:Ok(self.lootWindow.pane:IsShown(), "right pane hidden during a live session")
    t:Ok(self.lootWindow:GetWidth() > self.lootWindow.rail:GetWidth() + 100,
        "window did not expand to the two-pane form")
    t:Ok(self.db.global.session[me] ~= nil, "session not mirrored to the DB (resume support)")

    -- Respond to both items through the button path (ML fast-path dispatches cResp in-process),
    -- carrying a per-card note like the poll buttons do.
    self:OnResponseChosen(1, self.RESPONSES[1], "selftest note")
    self:OnResponseChosen(2, self.RESPONSES[2], "")
    local row = s.rows[1] and s.rows[1][me]
    if t:Ok(row ~= nil, "own response did not aggregate into session.rows") then
        t:Eq(row.resp, self.RESPONSES[1].id, "aggregated response id")
        t:Eq(row.note, "selftest note", "per-card note did not ride the response")
    end
    t:Ok(self.voteRows and self.voteRows[1] and self.voteRows[1][me] ~= nil,
        "voting view did not mirror the response")
    -- Readiness status rode the same cUpdate path into the voting view (Feature V): a lone present-
    -- eligible roller lands "ready", and the tally denominator counts the runner (council-of-one).
    local st1 = self.voteStatus and self.voteStatus[1]
    if t:Ok(st1 ~= nil, "readiness status did not mirror into voteStatus") then
        t:Eq(st1.kind, "ready", "solo single-roller item should border ready")
        t:Ok(st1.voted and st1.voted.of >= 1, "vote tally denominator should count present council")
    end
    -- Mini pill (Phase 12, §6.13): hidden while the full window is open; hiding the window
    -- surfaces it (closing must NOT end the session), showing the item count.
    t:Ok(not (self.miniFrame and self.miniFrame:IsShown()), "pill visible while the loot window is open")
    self:HideLootWindow()
    t:Ok(self.miniFrame and self.miniFrame:IsShown(), "pill not shown after hiding the loot window")
    t:Ok(self.session ~= nil, "hiding the loot window must not end the session")
    t:Ok((self.miniFrame.text:GetText() or ""):find("item", 1, true) ~= nil, "pill text missing item count")
    -- Item 4: a minimized (non-resizable) pill must GROW to fit its status string, not clip it.
    t:Ok(not self.miniFrame.text:IsTruncated(), "pill text truncated — the pill did not size to fit (item 4)")
    t:Ok(self.miniFrame:GetWidth() >= 220, "pill narrower than its minimum")
    self:ShowLootWindow()
    t:Ok(not self.miniFrame:IsShown(), "pill not hidden after reopening the loot window")

    local candRow = self.lootWindow and self.lootWindow.candList.rows[1]
    t:Ok(candRow ~= nil and candRow:IsShown(), "candidate row did not render for the response")
    -- Truncatable decision text must stay fully readable (readable-truncation invariant): the row
    -- carries a note-hover target + the full note, and captures the full response text for the
    -- name-hover tooltip (item 1's response carried "selftest note"; item 1 is the default select).
    t:Ok(candRow ~= nil and candRow.noteBtn ~= nil, "candidate row missing the note-hover target")
    t:Eq(candRow and candRow._noteText, "selftest note", "full note not captured for the hover tooltip")
    t:Ok(candRow ~= nil and candRow._respText ~= nil and candRow._respText ~= "",
        "full response text not captured for the name-hover tooltip")
    -- Own row must be class-colored (live ClassOf path; solo, we are always resolvable).
    local myClass = select(2, UnitClass("player"))
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[myClass]
    if cc and candRow then
        local r, g, b = candRow.name:GetTextColor()
        t:Ok(math.abs(r - cc.r) < 0.02 and math.abs(g - cc.g) < 0.02 and math.abs(b - cc.b) < 0.02,
            "candidate row name not class-colored (got " .. string.format("%.2f/%.2f/%.2f", r, g, b) .. ")")
    end

    -- Gates: a non-group candidate and a non-council voter must both be dropped, silently.
    self.dispatch.cResp(self, { sid = s.sid, item = 1, resp = 5 }, "Lcexfakecand")
    t:Ok(s.rows[1]["lcexfakecand"] == nil, "cResp from a non-group sender was accepted")
    self.dispatch.vVote(self, { sid = s.sid, item = 1, candidate = me, vote = 1 }, "Lcexfakecand")
    t:Eq(row and row.votes, 0, "vVote from a non-council sender was tallied")

    -- Vote through the button path: +1, re-cast toggles off, +1 again sticks.
    self:SendVote(1, me, 1)
    t:Eq(row and row.votes, 1, "vote tally after +1")
    self:SendVote(1, me, 1)
    t:Eq(row and row.votes, 0, "re-casting the same vote should toggle it off")
    self:SendVote(1, me, 1)
    t:Eq(row and row.votes, 1, "vote tally after re-vote")
    -- The "X / Y voted" header (V6) reflects the recomputed tally for the selected item.
    if self.lootWindow and self.lootWindow.voteTally then
        t:Ok(self.lootWindow.voteTally:IsShown(), "vote tally hidden during a live session")
        t:Eq(self.lootWindow.voteTally:GetText(), "1 / 1 voted", "vote tally text")
    end
    -- Who-voted list (V6) + the anon gate (V7): names ride the status unless the session is anon.
    -- Guarded on activeSession.anon so it holds whether or not anonymous voting is configured on.
    local st1v = self.voteStatus and self.voteStatus[1]
    if t:Ok(st1v and st1v.voted ~= nil, "readiness status missing after vote") then
        if self.activeSession and self.activeSession.anon then
            t:Eq(st1v.voted.names, nil, "anonymous session must not carry voter names")
        else
            t:Ok(st1v.voted.names and #st1v.voted.names >= 1, "who-voted list should name the voter")
        end
    end

    -- Award item 1 to a dummy who never responded (→ STATUS.ANNOUNCED), item 2 to ourselves
    -- (→ carries our own response id). Solo: no channel, so no award broadcast.
    local uid1, uid2 = s.sid .. ":1", s.sid .. ":2"
    t:Ok(self:AwardItem(1, AWARD_DUMMY), "AwardItem(1) failed")
    t:Ok(self:AwardItem(2, meName), "AwardItem(2) failed")
    local h1, h2 = self.db.global.history[uid1], self.db.global.history[uid2]
    if t:Ok(h1 ~= nil, "award 1 did not log to history") then
        t:Eq(h1.player, AWARD_DUMMY, "history winner")
        t:Eq(h1.resp, self.STATUS.ANNOUNCED, "non-responder award should carry ANNOUNCED")
    end
    if t:Ok(h2 ~= nil, "award 2 did not log to history") then
        t:Eq(h2.resp, self.RESPONSES[2].id, "history should carry the winner's response")
    end
    local owed = self.pendingTrades[AWARD_DUMMY:lower()]
    t:Ok(owed and owed[1] and owed[1].uid == uid1, "owed-trade record missing for the award")
    t:Ok(owed and owed[1] and owed[1].expireAt ~= nil, "owed trade lacks its 2h expiry anchor")
    t:Ok(self.db.global.pendingTrades[me] ~= nil, "owed trades not persisted to the DB")

    -- Awarded feedback (Phase 12, item 3): the award button greys out, the winner's row is
    -- check-marked, and the rail badge carries the texture escape (item 9) — never a glyph.
    self:LootSelectItem(2) -- item 2's winner (us) has a rendered candidate row
    local awardRow
    for _, r in ipairs(self.lootWindow.candList.rows) do
        if r:IsShown() and r.award:IsShown() then awardRow = r; break end
    end
    if t:Ok(awardRow ~= nil, "no candidate row with an award button after award") then
        t:Ok(not awardRow.award:IsEnabled(), "award button still enabled on an awarded item")
        t:Eq(awardRow.award:GetText(), self.L["Awarded"], "award button label after award")
        t:Ok((awardRow.name:GetText() or ""):find("|T", 1, true) ~= nil,
            "winner's candidate row not check-marked")
    end
    local railRow = self.lootWindow.railList.rows[2]
    t:Ok(railRow and (railRow.badge:GetText() or ""):find("|T", 1, true) ~= nil,
        "awarded rail badge missing the texture escape")

    -- Un-award correction (Phase 12, §6.15): item 1 (→ dummy) reopens — awarded mirror cleared,
    -- owed trade dropped, and the history record marked retracted (LWW supersedes the award).
    t:Ok(self:UnawardItem(1), "UnawardItem(1) failed")
    t:Ok(self.activeSession.awarded[1] == nil, "awarded mirror not cleared on un-award")
    t:Ok(self.pendingTrades[AWARD_DUMMY:lower()] == nil, "owed trade not dropped on un-award")
    t:Ok(self.db.global.history[uid1] and self.db.global.history[uid1].retracted == true,
        "history record not marked retracted")
    self:LootSelectItem(1)
    local reRow
    for _, r in ipairs(self.lootWindow.candList.rows) do
        if r:IsShown() and r.award:IsShown() then reRow = r; break end
    end
    if reRow then t:Ok(reRow.award:IsEnabled(), "award button not re-enabled after un-award") end
    -- Re-award to a real responder: a fresh record supersedes the retraction (newest mod wins).
    t:Ok(self:AwardItem(1, meName), "re-award after un-award failed")
    t:Ok(self.db.global.history[uid1] and not self.db.global.history[uid1].retracted,
        "re-award did not supersede the retraction")

    -- End: both frames close, all session state (incl. the DB mirror) clears.
    self:EndSession()
    t:Ok(self.session == nil and self.activeSession == nil, "session state not cleared")
    t:Ok(not (self.pollFrame and self.pollFrame:IsShown()), "poll still open after end")
    t:Ok(not (self.lootWindow and self.lootWindow:IsShown()), "loot window still open after end")
    t:Ok(self.db.global.session[me] == nil, "persisted session not cleared")
end, { cleanup = function(self)
    -- Unwind every side effect no matter where the test stopped: live/persisted session, both
    -- fake awards (owed trades + the history records — history is a union SYNC dataset, so a
    -- leftover fake record would propagate to guild peers), and the 60s trade ticker.
    local sid = self._selfTestSid
    self._selfTestSid = nil
    if self.session and sid and self.session.sid == sid then self:EndSession() end
    if sid then
        for i = 1, 2 do
            local uid = sid .. ":" .. i
            self:ForgetAward(uid)
            self.db.global.history[uid] = nil
        end
    end
    -- No live session ⇒ sessionItems must be nil (EndSession's invariant). Covers the edge
    -- where StartSession threw after the fake records were staged but before a sid existed.
    if not self.session then self.sessionItems = nil end
    self:StopTradeTickerIfIdle()
end })

-- Duplicate grouping (Phase 12, §6.14): two identical items run as ONE poll card / ONE candidate
-- table (RCLC-style), but each award consumes a DISTINCT physical index (uid = sid:index). Solo,
-- so nothing broadcasts. Mirrors the headless coverage against the live client.
LCEX:RegisterSelfTest("session", "duplicate grouping: one card, two physical awards", function(self, t)
    if self.session or self.activeSession then return t:Skip("a session is already open") end
    if self.recoverableSession then return t:Skip("an unfinished session is pending /lcex resume") end
    if self:GroupChannel() then return t:Skip("grouped — run the self-test solo so nothing broadcasts") end

    -- Two copies of the SAME universal item (30056 cloth robe) + one distinct item.
    local dup = FakeWireItem(2)
    local items = { { link = dup.link, quality = dup.quality },
                    { link = dup.link, quality = dup.quality },
                    FakeWireItem(1) }
    self.sessionItems = {}
    for i, it in ipairs(items) do
        self.sessionItems[i] = { link = it.link, itemID = it.itemID or dup.itemID, quality = it.quality,
                                 boss = "Self-Test", lootedAt = time() }
    end
    self:StartSession({ { link = items[1].link, quality = items[1].quality },
                        { link = items[2].link, quality = items[2].quality },
                        { link = items[3].link, quality = items[3].quality } })
    local s = self.session
    if not t:Ok(s ~= nil, "StartSession did not open") then return end
    self._selfTestSid = s.sid

    -- Grouping: copies 1&2 collapse to leader 1; the distinct item is its own group.
    t:Eq(s.groups.leaderOf[2], 1, "copy 2 groups under leader 1")
    t:Ok(s.rows[2] == nil, "member copy has no separate rows")
    -- Poll: one card per group → 2 cards for 3 items (the dup collapses).
    t:Eq(#(self.pollQueue or {}), 2, "one poll card per group (dup collapsed)")
    -- Rail: the grouped row carries the x2 count overlay.
    local entries = self:LootRailEntries()
    t:Eq(#entries, 2, "rail shows one row per group")
    t:Eq(entries[1].count, 2, "grouped rail row count = 2")
    t:Ok(self.lootWindow.railList.rows[1].icon.count:IsShown(), "x2 overlay shown for the dup")

    -- Two AwardGroup calls consume distinct physical copies with distinct uids.
    t:Ok(self:AwardGroup(1, AWARD_DUMMY), "award copy 1")
    t:Ok(not self:GroupFullyAwarded(1), "group not full after one copy")
    t:Ok(self:AwardGroup(1, AWARD_DUMMY), "award copy 2")
    t:Ok(self:GroupFullyAwarded(1), "group full after both copies")
    t:Ok(self.db.global.history[s.sid .. ":1"] and self.db.global.history[s.sid .. ":2"],
        "two distinct physical history uids")
    self:EndSession()
end, { cleanup = function(self)
    local sid = self._selfTestSid
    self._selfTestSid = nil
    if self.session and sid and self.session.sid == sid then self:EndSession() end
    if sid then
        for i = 1, 2 do
            self:ForgetAward(sid .. ":" .. i)
            self.db.global.history[sid .. ":" .. i] = nil
        end
    end
    if not self.session then self.sessionItems = nil end
    self:StopTradeTickerIfIdle()
end })

-- Persistence v2 (Phase 12, §6.16): a collected response + an award survive a simulated /reload
-- (drop the live refs, RestoreSession, ResumeSession) via the by-reference DB mirror + seed→overlay.
LCEX:RegisterSelfTest("session", "persistence: save → wipe → resume restores responses/awards", function(self, t)
    if self.session or self.activeSession or self.recoverableSession then
        return t:Skip("session state busy")
    end
    if self:GroupChannel() then return t:Skip("grouped — run the self-test solo") end
    local it = FakeWireItem(1)
    self.sessionItems = { { link = it.link, itemID = it.itemID, quality = it.quality,
                            boss = "Self-Test", lootedAt = time() } }
    self:StartSession({ { link = it.link, quality = it.quality } })
    local s = self.session
    if not t:Ok(s ~= nil, "StartSession failed") then return end
    self._selfTestSid = s.sid

    -- Collect a response + an award (held by reference in the DB mirror).
    s.rows[1] = s.rows[1] or {}
    s.rows[1]["bob"] = { name = "Bob", resp = self.RESPONSES[1].id, votes = 1 }
    self.activeSession.awarded = { [1] = "Bob" }
    self:SaveSession()
    t:Ok(self:CountSavedResponses(self.db.global.session[self:OwnerKey()]) >= 1,
        "resume dialog would count the response")

    -- Simulate a /reload: drop the live refs (NOT EndSession — that clears the DB), then recover.
    local savedSid = s.sid
    self.session, self.sessionItems, self.activeSession = nil, nil, nil
    self:RestoreSession()
    if not t:Ok(self.recoverableSession ~= nil, "no recoverable session after wipe") then return end
    t:Ok(self:ResumeSession(), "resume failed")
    t:Eq(self.session.sid, savedSid, "resumed with the same sid")
    t:Ok(self.session.rows[1] and self.session.rows[1]["bob"]
        and self.session.rows[1]["bob"].resp ~= nil, "collected response not restored")
    t:Eq(self.activeSession.awarded[1], "Bob", "award state not restored")
    self:EndSession()
end, { cleanup = function(self)
    local sid = self._selfTestSid
    self._selfTestSid = nil
    if self.session and sid and self.session.sid == sid then self:EndSession() end
    self:ClearSavedSession()
    self.recoverableSession = nil
    if not self.session then self.sessionItems = nil end
    self:StopTradeTickerIfIdle()
end })

-- Trade-timer scanner (Phase 12, §6.17): the bag scan returns well-formed entries, and the
-- item-GUID keying is PROBED on the live Anniversary client (the X-item — with a fallback either
-- way). Read-only: ScanTradeTimers touches no state and arms no timer.
LCEX:RegisterSelfTest("api", "trade timers: scanner shape + item-GUID probe", function(self, t)
    local entries = self:ScanTradeTimers()
    if not t:Ok(type(entries) == "table", "ScanTradeTimers did not return a table") then return end
    for _, e in ipairs(entries) do
        t:Ok(e.key and e.link and e.expireAt, "malformed entry (needs key/link/expireAt)")
    end
    t:Ok(self:TradeBarColor(3600, 7200) ~= nil, "TradeBarColor returned nil")
    -- X-item: is C_Item.GetItemGUID usable on Anniversary? Record it (informational, not a fail).
    local guidOk = (C_Item and C_Item.GetItemGUID and _G.ItemLocation) and true or false
    t.info = "GetItemGUID available: " .. tostring(guidOk)
        .. "; tradeable bag items scanned: " .. #entries
end)

-- Trade-timer window (Phase 12, §6.17): injected entries respect the opt-in toggle, render as
-- bars, sort soonest-first, have no close button, color the item name, and minimize to one bar.
LCEX:RegisterSelfTest("ui", "trade-timer window: render / sort / minimize / no-close", function(self, t)
    local now = time()
    self._selfTestTradeSaved = self.tradeTimerEntries
    self._selfTestTradeTestSaved = self.tradeTimerTestEntries
    local prevAuto = self.db.profile.tradeTimersAuto
    self._selfTestTradeMaxRows = self.db.profile.tradeTimersMaxRows
    self._tradeMinimized = false
    self.db.profile.tradeTimersMaxRows = 10
    self.tradeTimerEntries = {
        { key = "e1", link = select(2, GetItemInfo(30056)) or "item:30056", itemID = 30056,
          quality = 4, expireAt = now + 3600 },
        { key = "e2", link = select(2, GetItemInfo(28830)) or "item:28830", itemID = 28830,
          quality = 4, expireAt = now + 600 },
    }

    self.db.profile.tradeTimersAuto = false
    self:UpdateTradeTimerWindow()
    t:Ok(not (self.tradeTimerWindow and self.tradeTimerWindow:IsShown()),
        "trade-timer window showed while disabled")

    self:CmdTimerTest()
    t:Ok(self:_TradeTimerTestActive(), "timertest did not create an active synthetic row")
    t:Ok(self.tradeTimerWindow and self.tradeTimerWindow:IsShown(),
        "timertest did not show the trade-timer window while disabled")
    self:CmdTimerTest()
    t:Ok(not self:_TradeTimerTestActive(), "timertest did not clear its synthetic row")

    self.db.profile.tradeTimersAuto = true
    self:UpdateTradeTimerWindow()
    local f = self.tradeTimerWindow
    if not t:Ok(f and f:IsShown(), "trade-timer window did not open when enabled") then return end
    t:Ok(not f.closeButton, "trade-timer window must not have a close button")
    t:Ok(f.resizeGrip and f.resizeGrip:IsShown(), "trade-timer window missing resize grip")
    t:Eq(f.title and f.title:GetText(), self.L["Loot"], "trade-timer title should be the compact Loot label")
    if f._surface and f.bar and f.bar._surface then
        t:Ok(f._surface:IsShown(), "trade-timer content surface should be visible at low alpha")
        t:Ok(f.bar._surface:IsShown(), "trade-timer header surface should be visible at low alpha")
        t:Eq(math.floor(((f._surface._lcexAlpha or 0) * 100) + 0.5), 25,
            "trade-timer content surface alpha")
        t:Eq(math.floor(((f.bar._surface._lcexAlpha or 0) * 100) + 0.5), 25,
            "trade-timer header surface alpha")
    end
    t:Eq(math.floor((f.bar:GetHeight() or 0) + 0.5), 14, "trade-timer header height")
    t:Eq(math.floor((f.resizeGrip:GetWidth() or 0) + 0.5), 11, "trade-timer resize grip width")
    t:Ok(f.rows[1] and f.rows[1]:IsShown() and f.rows[2] and f.rows[2]:IsShown(), "two bars not rendered")
    t:Eq(math.floor((f.rows[1]:GetHeight() or 0) + 0.5), 14, "trade-timer row height should match header")
    t:Eq(f.rows[1].key, "e2", "bars not sorted soonest-first (600s item on top)")
    t:Ok((f.rows[1].label:GetText() or ""):find("|cff") and true or false,
        "item label is not colorized")
    t:Ok((f.rows[1].label:GetText() or ""):find("%[") and true or false,
        "item label should display bracketed item-link text")

    self.db.profile.tradeTimersMaxRows = 1
    self:UpdateTradeTimerWindow()
    t:Ok(f.rows[1]:IsShown() and not (f.rows[2] and f.rows[2]:IsShown()),
        "expanded row cap did not limit visible timers")
    t:Ok(f.more:IsShown(), "expanded row cap missing the +N indicator")
    self.db.profile.tradeTimersMaxRows = 0
    self:UpdateTradeTimerWindow()
    t:Ok(f.rows[2] and f.rows[2]:IsShown(), "All row setting did not show every timer")

    self._tradeMinimized = true
    self:UpdateTradeTimerWindow()
    t:Ok(f.rows[1]:IsShown() and not (f.rows[2] and f.rows[2]:IsShown()), "minimize did not collapse to one bar")
    t:Ok(f.more:IsShown(), "minimize missing the +N indicator")
    self._tradeMinimized = false

    self.db.profile.tradeTimersAuto = false
    self:UpdateTradeTimerWindow()
    t:Ok(not f:IsShown(), "disabled trade timers should hide the window")
    self.db.profile.tradeTimersAuto = prevAuto
    self.db.profile.tradeTimersMaxRows = self._selfTestTradeMaxRows
    self._selfTestTradeMaxRows = nil
end, { cleanup = function(self)
    self.tradeTimerEntries = self._selfTestTradeSaved or {}
    self._selfTestTradeSaved = nil
    self.tradeTimerTestEntries = self._selfTestTradeTestSaved
    self._selfTestTradeTestSaved = nil
    if self._selfTestTradeMaxRows ~= nil then
        self.db.profile.tradeTimersMaxRows = self._selfTestTradeMaxRows
        self._selfTestTradeMaxRows = nil
    end
    self._tradeMinimized = false
    self:_StopTradeTimerTick()
    if self.tradeTimerWindow then self.tradeTimerWindow:Hide() end
end })
