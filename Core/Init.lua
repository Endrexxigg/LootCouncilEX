-- ── LootCouncil EX — Init.lua ────────────────────────────────────────────────
-- Bootstrap and entry point. Creates the single AceAddon object that IS the addon
-- namespace, loads the SavedVariables DB with the PROJECT.md §6.4 defaults, registers
-- the "LCEX" comm prefix and the /lcex slash command, and wires the events that drive
-- the version handshake.
--
-- This file MUST load first (see the .toc): its body publishes the `LootCouncilEX`
-- global that every other Core file binds to via `local LCEX = LootCouncilEX`. The
-- AceAddon lifecycle (OnInitialize → OnEnable) fires only after every file body has
-- run, so methods defined in Const/Comms/Roster are all present by the time the
-- handlers below execute.

local ADDON_NAME = "LootCouncilEX"

-- The addon object embeds the Ace3 mixins this addon leans on; they become methods
-- directly on LCEX (RegisterComm/SendCommMessage, ScheduleTimer/CancelTimer,
-- RegisterChatCommand, RegisterEvent, Serialize/Deserialize). AceDB is NOT a mixin —
-- it is created on demand via LibStub("AceDB-3.0"):New(...) in OnInitialize.
local LCEX = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0",
    "AceComm-3.0",
    "AceConsole-3.0",
    "AceSerializer-3.0",
    "AceTimer-3.0"
)
LootCouncilEX = LCEX

-- SavedVariables shape — PROJECT.md §6.4, verbatim. Phase 1 only reads/writes nothing
-- here yet, but the full schema is created up front (it is inert data, not behaviour)
-- so later phases inherit a stable layout. AceDB deep-copies these defaults, so the
-- nested empty tables survive into LootCouncilEXDB.
local DB_DEFAULTS = {
    profile = {
        council            = { byRank = true, rank = 1, extra = {} },
        syncChannel        = "GUILD",
        minQuality         = 4,
        selfReport         = true,
        showGearIssues     = false, -- Feature G: show the gear-issue callouts on the Roster tab

        ui                 = {
            poll    = {},
            loot    = {},
            council = {},
            config  = {},
        },
        -- Poll response deadline in seconds (0 = none). Set by the ML in Session Config;
        -- rides sStart so every candidate's poll counts down.
        pollTimeout        = 0,
        -- Window appearance (Config window): scale for every LCEX window, opacity for the
        -- windows that opt in (council).
        appearance         = { scale = 1.0, opacity = 1.0 },
        -- LibDBIcon's saved state (position angle + hide flag) — owned by the lib.
        minimap            = { hide = false },
        useWhisperFallback = false,
    },
    global = {
        notes     = {},
        marks     = {},
        history   = {},
        gearCache = {},
        profCache = {},
        config    = {}, -- shared officer config, keyed by guildKey (Feature V/C, §6.9)
        dummy     = {}, -- Phase-4 sync-proof dataset (council/Sync.lua); retire with Phase 5.
        -- Owed loot the ML still has to trade out, mirrored here so it survives /reload (DL-6).
        -- Account-wide, keyed by OWNER character name → the in-memory pendingTrades shape. Local
        -- only (NOT a sync dataset). See Award.lua SaveOwedTrades/RestoreOwedTrades.
        pendingTrades = {},
        -- An open ML session, mirrored so it survives /reload (DL-6): owner → session descriptor.
        -- On login the ML is offered /lcex resume. See Session.lua SaveSession/RestoreSession.
        session = {},
        -- NOTE: `dbVersion` is deliberately NOT defaulted here. An AceDB default would mask the
        -- difference between a fresh DB and a pre-versioning one (both would read the default),
        -- breaking migration detection — so MigrateDB reads it raw (nil ⇒ unversioned) and stamps
        -- a real stored value. See LCEX.DB_VERSION / LCEX:MigrateDB below.
    },
}

-- Current `global` schema version. Bump by one whenever a migration step is added below; the
-- step upgrades a DB written by the previous version in place. v1 is the schema that shipped
-- through Phase 6 (notes/marks/history/gear+prof caches), so nil/0 → 1 is a no-op stamp.
LCEX.DB_VERSION = 1

-- The addon's displayed version (the `## Version` line), e.g. "0.1". Distinct from the
-- comms PROTOCOL_VERSION in Const.lua. Anniversary clients moved GetAddOnMetadata under
-- C_AddOns; fall back to the global for older builds.
function LCEX:GetVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMeta and getMeta(ADDON_NAME, "Version")) or "dev"
end

-- One-shot schema migration, run in OnInitialize BEFORE anything reads db.global (datasets
-- register/read in OnEnable, later). Walks the migration chain from the stored version up to
-- LCEX.DB_VERSION, then stamps the current version as a real value. A DB written by a NEWER
-- build (version ahead of ours) is left untouched — never downgrade or discard a peer's data.
function LCEX:MigrateDB()
    local g = self.db.global
    local from = g.dbVersion or 0
    if from == self.DB_VERSION then return end
    if from > self.DB_VERSION then
        self:Debug("DB is newer (v%s > v%s) — leaving as-is", tostring(from), tostring(self.DB_VERSION))
        return
    end
    -- Migration chain: each `if from < N` block upgrades a (N-1)-era DB to N. None yet — the
    -- current schema is what shipped through Phase 6, so an unversioned DB is already v1-shaped.
    -- if from < 2 then ...transform g...; from = 2 end
    g.dbVersion = self.DB_VERSION
end

function LCEX:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("LootCouncilEXDB", DB_DEFAULTS, true)
    self:MigrateDB() -- normalize the schema before any reader touches db.global

    -- One-shot profile cleanup: the pre-v0.22 five-frame position keys. Profile data is NOT
    -- covered by MigrateDB (global-only), and AceDB keeps non-default keys forever — so the
    -- orphans are dropped here (idempotent; nil-ing an absent key is a no-op).
    local ui = self.db.profile.ui
    ui.lootFrame, ui.votingFrame, ui.sessionFrame = nil, nil, nil
    ui.playerDetail, ui.lootBrowser = nil, nil

    -- Inbound comms route to LCEX:OnCommReceived (Comms.lua), the default handler name.
    self:RegisterComm("LCEX")

    -- /lcex … dispatches to LCEX:HandleSlash below.
    self:RegisterChatCommand("lcex", "HandleSlash")
end

function LCEX:OnEnable()
    -- "Zoning in" and roster churn both re-announce our version (debounced in Comms).
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnterWorld")
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnRosterUpdate")

    -- Seed ourselves into the known-versions table (Roster.lua).
    self:RosterInit()

    -- Loot detection / master-loot events (Award.lua). Registered here, after the DB
    -- exists, so the handler can read db.profile.minQuality.
    self:SetupLootEvents()

    -- Plane B — council sync (council/Sync.lua): roster-change invalidation + a login digest.
    self:SetupSync()

    -- Plane B — gear/profession self-report (council/SelfReport.lua): snapshot + login report.
    self:SetupSelfReport()

    -- The minimap launcher (Core/Minimap.lua): left=loot, right=council, ctrl=config.
    self:SetupMinimapButton()

    self:Msg(string.format(self.L["v%s loaded."], self:GetVersion()))
end

-- Both triggers coalesce through the same debounce key so a burst of events
-- (e.g. several loading screens) results in a single vCheck broadcast.
function LCEX:OnEnterWorld()
    self:DebouncedSend("vCheck", function() self:AutoBroadcastVCheck() end)
end

function LCEX:OnRosterUpdate()
    self:DebouncedSend("vCheck", function() self:AutoBroadcastVCheck() end)
    -- Group membership changed: re-broadcast our gear/professions so members we weren't grouped
    -- with at our last report (e.g. our login report) now receive it. pReport is only cached by
    -- current group members, so a login-time report is dropped by people who join us later.
    self:DebouncedSend("pReport", function() self:SendSelfReport() end)
end

-- /lcex <subcommand> [args]. The first token is the command (lowercased); the
-- remainder is preserved as-is (player names are case-sensitive). A manual `ping` sends
-- immediately (no debounce) so the acceptance test is deterministic; event-driven
-- broadcasts go through the debounce.
function LCEX:HandleSlash(input)
    input = strtrim(input or "")
    local cmd = (input:match("^(%S*)") or ""):lower()
    local rest = strtrim(input:match("^%S*%s*(.*)$") or "")
    if cmd == "" or cmd == "show" then
        self:ToggleLootWindow()
    elseif cmd == "ping" then
        self:CmdPing()
    elseif cmd == "version" or cmd == "ver" then
        self:PrintKnownVersions()
    elseif cmd == "scan" then
        self:CmdScan()
    elseif cmd == "start" then
        self:CmdStartFromBags()
    elseif cmd == "respond" then
        self:CmdRespond()
    elseif cmd == "note" then
        self:CmdNote(rest)
    elseif cmd == "mark" then
        self:CmdMark(rest)
    elseif cmd == "history" then
        self:CmdHistory(rest)
    elseif cmd == "report" then
        self:CmdReport()
    elseif cmd == "gear" then
        self:CmdGear(rest)
    elseif cmd == "loot" or cmd == "browser" then
        self:OpenCouncilModule("browser")
    elseif cmd == "council" then
        -- Bare = the council window; with args = the roster editor (add|remove|list).
        if rest == "" then
            self:ToggleCouncilWindow()
        else
            self:CmdCouncil(rest)
        end
    elseif cmd == "player" or cmd == "detail" then
        self:CmdPlayerDetail(rest)
    elseif cmd == "sync" then
        self:CmdSync()
    elseif cmd == "dummy" then
        self:CmdDummy(rest)
    elseif cmd == "debug" then
        self.debug = not self.debug
        self:Msg("Debug tracing " .. (self.debug and "ON" or "OFF"))
    elseif cmd == "award" then
        self:CmdAward(rest)
    elseif cmd == "end" then
        self:EndSession()
    elseif cmd == "resume" then
        self:CmdResume()
    elseif cmd == "session" then
        self:CmdSession()
    elseif cmd == "config" or cmd == "options" then
        self:ToggleConfigWindow()
    elseif cmd == "test" then
        self:CmdTest(rest)
    elseif cmd == "selftest" then
        self:CmdSelfTest()
    else
        self:Msg(self.L["Commands: ping, version, scan, start, respond, award <n> <name>, end, resume, session, test [n], selftest, note <player> [text], mark <id|link> [text], history [player], report, gear [player], loot, player [name], council [add|remove <name>], config, sync"])
    end
end
