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
        ui                 = {
            lootFrame    = {},
            votingFrame  = {},
            sessionFrame = {},
            playerDetail = {},
            lootBrowser  = {},
        },
        useWhisperFallback = false,
    },
    global = {
        notes     = {},
        marks     = {},
        history   = {},
        gearCache = {},
        profCache = {},
        dummy     = {}, -- Phase-4 sync-proof dataset (council/Sync.lua); retire with Phase 5.
    },
}

-- The addon's displayed version (the `## Version` line), e.g. "0.1". Distinct from the
-- comms PROTOCOL_VERSION in Const.lua. Anniversary clients moved GetAddOnMetadata under
-- C_AddOns; fall back to the global for older builds.
function LCEX:GetVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMeta and getMeta(ADDON_NAME, "Version")) or "dev"
end

function LCEX:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("LootCouncilEXDB", DB_DEFAULTS, true)

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
        self:ToggleSessionFrame()
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
    elseif cmd == "council" then
        self:CmdCouncil(rest)
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
    elseif cmd == "session" then
        self:CmdSession()
    elseif cmd == "test" then
        self:CmdTest(rest)
    else
        self:Msg(self.L["Commands: ping, version, scan, start, respond, award <n> <name>, end, session, test [n], note <player> [text], mark <id|link> [text], history [player], report, gear [player], council [add|remove <name>], sync"])
    end
end
