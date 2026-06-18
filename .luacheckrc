-- ── LootCouncil EX — luacheck config ─────────────────────────────────────────
-- Lean baseline. Vendored libs and reference addons are excluded. The globals list
-- covers the WoW + Ace3 surface this addon uses (see PROJECT.md §6.7); add to it as
-- new APIs are introduced. ArenaSmartStats ships a full generated WoW API dump if
-- exhaustive coverage is ever wanted.

std = "lua51"
max_line_length = false
codes = true

exclude_files = {
    "Libs/",
    "References/",
}

-- Addon globals we define and read across files.
globals = {
    "LootCouncilEX",
    "LootCouncilEXDB",
    "SlashCmdList",
}

read_globals = {
    -- Core / libs
    "LibStub", "UISpecialFrames",
    -- Frames / UI
    "CreateFrame", "UIParent", "GameTooltip", "DEFAULT_CHAT_FRAME", "RAID_CLASS_COLORS",
    "FauxScrollFrame_GetOffset", "FauxScrollFrame_Update",
    "FauxScrollFrame_OnVerticalScroll", "FauxScrollFrame_SetOffset",
    -- Addon metadata
    "GetAddOnMetadata",
    -- Units / roster
    "UnitName", "UnitClass", "UnitExists", "UnitGUID", "UnitFullName", "UnitInRaid",
    "GetNumGroupMembers", "GetNumRaidMembers", "GetRaidRosterInfo", "IsInRaid", "IsInGroup",
    -- Loot / master loot
    "GetMasterLootCandidate", "GiveMasterLoot", "GetNumLootItems",
    "GetLootSlotLink", "GetLootSlotInfo", "LootSlotHasItem",
    -- Items / gear / professions
    "GetInventoryItemLink", "GetInventorySlotInfo", "GetItemInfo", "GetAverageItemLevel",
    "GetNumSkillLines", "GetSkillLineInfo",
    -- Misc WoW
    "GetTime", "GetServerTime", "GetRealmName",
    -- Lua 5.1 + WoW string/table extras
    "wipe", "strtrim", "strsplit", "strfind", "strmatch", "format",
    "tinsert", "tremove", "tContains", "time", "date",
}
