-- ── LootCouncil EX — Tests/harness.lua ───────────────────────────────────────
-- Loads the addon's Core Lua in a plain Lua interpreter (no WoW), behind a small mock of the
-- WoW + Ace3 API, so the pure logic (sync merge, digests, name normalization, council
-- resolution, command parsing) can be unit-tested headlessly. Run from the repo root:
--     lua Tests/run.lua
--
-- The mock is intentionally minimal: enough to LOAD the Core files and exercise their logic.
-- UI files are skipped (frame rendering isn't unit-testable here). Outgoing comms are captured
-- in H.sent; chat output in H.msgs. H.now drives time() deterministically.

local H = { sent = {}, msgs = {}, now = 1000, inGuild = true, inRaid = false,
            guild = {}, group = {}, playerName = "Tester" }

-- ── Lua-version + WoW string/table helpers ───────────────────────────────────
unpack = unpack or table.unpack
local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

_G.strtrim   = trim
_G.format    = string.format
_G.tinsert   = table.insert
_G.tremove   = table.remove
_G.strsplit  = function(sep, s) return string.split and string.split(sep, s) or s end
_G.wipe      = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.time      = function() return H.now end
_G.date      = os.date
_G.GetTime   = os.clock
_G.GetServerTime = function() return H.now end

-- ── WoW unit/guild/group API ─────────────────────────────────────────────────
_G.UnitName = function(unit)
    if unit == "player" then return H.playerName end
    local kind, idx = tostring(unit):match("^(%a+)(%d+)$")
    if (kind == "party" or kind == "raid") and H.group[tonumber(idx)] then
        return H.group[tonumber(idx)]
    end
    if unit == "npc" then return H.tradePartner end
    return nil
end
_G.UnitIsUnit = function(a, b) return a == b end
_G.UnitClass = function() return "Mage", H.class or "MAGE" end -- localizedName, classToken
-- Talent tabs (SnapshotSpec). H.talentPoints = {tab1, tab2, tab3} points-spent. Mirrors the real
-- Anniversary signature (id, name, description, icon, pointsSpent, fileName) — tab name (2nd) is
-- the class's spec for that tab, points is the 5th. Default: Fire mage (tab 2 highest).
_G.GetNumTalentTabs = function() return 3 end
_G.GetTalentTabInfo = function(tab)
    local specs = _G.LootCouncilEX and _G.LootCouncilEX.CLASS_SPECS
        and _G.LootCouncilEX.CLASS_SPECS[H.class or "MAGE"]
    local name = (specs and specs[tab]) or ("Tab" .. tostring(tab))
    return 100 + tab, name, "", nil, (H.talentPoints and H.talentPoints[tab]) or 0, "file"
end
_G.UnitAffectingCombat = function() return false end
_G.IsInGuild = function() return H.inGuild end
_G.GuildRoster = function() end
_G.GetNumGuildMembers = function() return #H.guild end
_G.GetGuildRosterInfo = function(i)
    local m = H.guild[i]
    if not m then return nil end
    return m.name, m.rank or "Member", m.rankIndex or 0
end
_G.GetGuildInfo = function(unit) -- guildName, rankName, rankIndex (GuildKey reads the 1st)
    if unit == "player" and H.inGuild then return H.guildName or "TestGuild", "Member", H.myRank or 0 end
    return nil
end
_G.IsInRaid = function() return H.inRaid end
_G.IsInGroup = function() return #H.group > 0 end
_G.GetNumGroupMembers = function() return #H.group end
_G.GetNumRaidMembers = function() return H.inRaid and #H.group or 0 end
_G.GetRaidRosterInfo = function(i) local m = H.group[i]; return m end
_G.GetInstanceInfo = function() return "Test Zone" end
_G.SendChatMessage = function(text, chan) H.chat[#H.chat + 1] = { text = text, chan = chan } end
_G.LE_PARTY_CATEGORY_INSTANCE = 2
_G.GetRealmName = function() return "TestRealm" end
_G.GetBuildInfo = function() return "2.5.5", "99999", "Jan 1 2026", 20505 end
_G.GetLocale = function() return "enUS" end

-- ── WoW item/loot/skill API (enough to load; returns benign values) ──────────
_G.GetInventoryItemLink = function() return nil end
_G.GetNumSkillLines = function() return 0 end
_G.GetSkillLineInfo = function() return nil end
_G.GetItemInfo = function() -- name, link, quality, ilvl, req, class, sub, stack, equip, icon
    if H.itemEmpty then return nil end
    return "Test Item", "[Test Item]", H.itemQuality or 4, 60, 60, "", "", 1, "", 135
end
_G.GetInventorySlotInfo = function() return nil end
-- GetItemStats(link) → stats table; H.itemStats drives the EMPTY_SOCKET_* keys the gear-issue
-- detector (Core/GearIssues.lua) sums for sockets. nil → the socket check no-ops (fail-safe path).
_G.GetItemStats = function() return H.itemStats end
-- Blizzard Item mixin (ItemMixin) used by WithItemQuality/WithItemID. H.itemCached/itemEmpty
-- drive the cached/empty branches; ContinueOnItemLoad fires synchronously here.
_G.Item = {
    CreateFromItemID = function(_, _id)
        return {
            IsItemEmpty        = function() return H.itemEmpty == true end,
            IsItemDataCached   = function() return H.itemCached ~= false end,
            ContinueOnItemLoad = function(_, cb) cb() end,
        }
    end,
    CreateFromItemLink = function(_, _link)
        return {
            IsItemEmpty        = function() return H.itemEmpty == true end,
            IsItemDataCached   = function() return H.itemCached ~= false end,
            ContinueOnItemLoad = function(_, cb) cb() end,
        }
    end,
}
_G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
_G.LOOT_ITEM_SELF = "You receive loot: %s."

-- ── WoW frame API (magic stubs) ──────────────────────────────────────────────
-- Enough to LOAD the UI files and exercise their PURE helpers (tab state, display builders) —
-- not to render. Every frame method returns the frame (chainable). We don't assert on frames.
local function newFrame()
    local f = {}
    setmetatable(f, { __index = function() return function() return f end end })
    return f
end
_G.CreateFrame = function() return newFrame() end
_G.UIParent = newFrame()
_G.GameTooltip = newFrame()
_G.UISpecialFrames = {}
_G.BackdropTemplateMixin = nil
_G.FauxScrollFrame_Update = function() end
_G.FauxScrollFrame_GetOffset = function() return 0 end
_G.FauxScrollFrame_OnVerticalScroll = function() end
_G.FauxScrollFrame_SetOffset = function() end
-- Driveable at call time: tests set H.instant = {id, type, subType, equipLoc, icon, classID,
-- subClassID} to exercise the Core/Usable.lua proficiency matrix (file-locals capture this
-- FUNCTION at load; it reads H per call).
_G.GetItemInfoInstant = function()
    local i = H.instant
    if not i then return nil end
    return i[1], i[2], i[3], i[4], i[5], i[6], i[7]
end

-- ── LibStub + the Ace3 mixins the addon embeds ───────────────────────────────
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepcopy(v) end
    return r
end

-- Stub the Ace mixin methods onto the addon object. Comms/events/timers are no-ops or capture.
local function applyMixins(obj)
    function obj:RegisterEvent(_, _) end
    function obj:UnregisterEvent(_) end
    function obj:RegisterComm(_, _) end
    function obj:RegisterChatCommand(_, _) end
    function obj:ScheduleTimer(_, _) return {} end
    function obj:ScheduleRepeatingTimer(_, _) return {} end
    function obj:CancelTimer(_) end
    function obj:Print(...) end
    function obj:SendCommMessage(prefix, text, dist, target)
        H.sent[#H.sent + 1] = { prefix = prefix, msg = text, dist = dist, target = target }
    end
    -- In-process "serialization": pass the table through unchanged (no string encoding needed).
    function obj:Serialize(t) return t end
    function obj:Deserialize(s) return true, s end
    return obj
end

local libs = {
    ["AceAddon-3.0"] = {
        NewAddon = function(_, _name, ...) return applyMixins({}) end,
    },
    ["AceDB-3.0"] = {
        New = function(_, _name, defaults)
            return { profile = deepcopy(defaults.profile), global = deepcopy(defaults.global) }
        end,
    },
}
_G.LibStub = function(name) return libs[name] end

-- ── Load the Core files (toc order, Core only — UI is not unit-tested here) ──
local FILES = {
    "Core/Init.lua", "Core/Const.lua", "Core/Comms.lua", "Core/Roster.lua", "Core/Guild.lua", "Core/Minimap.lua",
    "Core/Data/Loot.lua", "Core/Data/BiS.lua", "Core/Data/TierTokens.lua", "Core/Data/DataAPI.lua",
    "Core/Data/GearRules.lua",
    "Core/Display.lua",
    "Core/session/Session.lua", "Core/session/Readiness.lua", "Core/session/Award.lua",
    "Core/session/Candidate.lua", "Core/session/Council.lua",
    "Core/council/Sync.lua", "Core/council/Notes.lua", "Core/council/Marks.lua",
    "Core/council/History.lua", "Core/council/SelfReport.lua", "Core/council/Config.lua",
    "Core/Access.lua",
    "Core/Usable.lua", "Core/GearIssues.lua",
    "UI/Theme.lua", "UI/Widgets.lua", "UI/PollWindow.lua", "UI/LootWindow.lua",
    "UI/CouncilWindow.lua", "UI/council/BrowserModule.lua", "UI/council/RosterModule.lua",
    "UI/council/HistoryModule.lua", "UI/council/SessionConfigModule.lua", "UI/ConfigWindow.lua",
    "Core/SelfTest.lua", -- last, like the .toc; only its RUNNER is exercised headlessly
}
for _, f in ipairs(FILES) do
    local chunk, err = loadfile(f)
    if not chunk then error("failed to load " .. f .. ": " .. tostring(err)) end
    chunk()
end

local LCEX = _G.LootCouncilEX
LCEX:OnInitialize() -- creates LCEX.db (mock AceDB)

-- Capture chat output instead of printing it.
function LCEX:Msg(text) H.msgs[#H.msgs + 1] = tostring(text) end

-- The session Show/Hide frame plumbing is pure UI; stub it so the session lifecycle (start /
-- enter / leave / resume) can be exercised headlessly without rendering.
function LCEX:ShowPoll() end
function LCEX:HidePoll() end
function LCEX:ShowLootWindow() end
function LCEX:HideLootWindow() end
function LCEX:RefreshLootItem() end

-- Reset mutable state between tests.
function H.reset()
    H.sent, H.msgs, H.chat = {}, {}, {}
    H.now, H.inGuild, H.inRaid = 1000, true, false
    H.guild, H.group = {}, {}
    H.playerName, H.tradePartner = "Tester", nil
    H.itemCached, H.itemEmpty = true, false
    H.itemStats, H.itemQuality = nil, nil
    H.instant = nil
    H.class = "MAGE"
    H.guildName = nil
    H.myRank = 0 -- local player's guild rank index (0 = GM); Access tests override
    H.talentPoints = { 0, 41, 20 } -- Fire mage by default (tab 2 wins)
    LCEX._councilSet = nil
    LCEX.bisClass, LCEX.bisSpec, LCEX.bisPhase = nil, nil, nil
    LCEX.pendingTrades = {}
    LCEX.pendingLoot = {}
    LCEX.session, LCEX.sessionItems, LCEX.activeSession = nil, nil, nil
    LCEX.recoverableSession, LCEX.sessionTimeout, LCEX.sPingTimer = nil, nil, nil
    if LCEX.db.global.pendingTrades then wipe(LCEX.db.global.pendingTrades) end
    if LCEX.db.global.session then wipe(LCEX.db.global.session) end
    LCEX.db.profile.council = { byRank = true, rank = 1, extra = {} }
    LCEX.db.profile.syncChannel = "GUILD"
    LCEX.db.profile.selfReport = true
    for _, ds in pairs(LCEX.datasets) do
        local store = ds.store()
        if store then for k in pairs(store) do store[k] = nil end end
    end
end

H.LCEX = LCEX
return H
