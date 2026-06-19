-- ── LootCouncil EX — luacheck config ─────────────────────────────────────────
-- Lean baseline. Vendored libs and reference addons are excluded. The globals list
-- covers the WoW + Ace3 surface this addon uses (see PROJECT.md §6.7); add to it as
-- new APIs are introduced. ArenaSmartStats ships a full generated WoW API dump if
-- exhaustive coverage is ever wanted.

std = "lua51"
max_line_length = false
codes = true

-- Methods declared with `:` always receive `self`; don't warn when a method doesn't
-- read it (common for Ace3-style methods). Other unused args still flag real mistakes.
ignore = { "212/self" }

exclude_files = {
    "Libs/",
    "References/",
    "Tests/", -- headless test harness: mocks WoW + sets globals, lints under its own rules
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
    "CreateFrame", "UIParent", "GameTooltip", "DEFAULT_CHAT_FRAME", "RAID_CLASS_COLORS", "TradeFrame",
    "BackdropTemplateMixin",
    "FauxScrollFrame_GetOffset", "FauxScrollFrame_Update",
    "FauxScrollFrame_OnVerticalScroll", "FauxScrollFrame_SetOffset",
    -- Addon metadata
    "GetAddOnMetadata", "C_AddOns",
    -- Units / roster
    "UnitName", "UnitClass", "UnitExists", "UnitGUID", "UnitFullName", "UnitInRaid", "UnitIsUnit",
    "UnitAffectingCombat",
    "GetNumGroupMembers", "GetNumRaidMembers", "GetRaidRosterInfo", "IsInRaid", "IsInGroup",
    "LE_PARTY_CATEGORY_INSTANCE", "GetInstanceInfo",
    "IsInGuild", "GuildRoster", "GetNumGuildMembers", "GetGuildRosterInfo",
    -- Loot / master loot
    "GetMasterLootCandidate", "GiveMasterLoot", "GetNumLootItems", "GetLootMethod",
    "GetLootSlotLink", "GetLootSlotInfo", "LootSlotHasItem", "LOOT_ITEM_SELF",
    -- Bags / trade
    "C_Container",
    "GetContainerNumSlots", "GetContainerItemLink", "GetContainerItemInfo",
    "PickupContainerItem", "ClickTradeButton", "GetTradePlayerItemLink",
    "CursorHasItem", "ClearCursor", "BIND_TRADE_TIME_REMAINING",
    -- Items / gear / professions
    "Item", "C_Item", "GetItemInfoInstant",
    "GetInventoryItemLink", "GetInventorySlotInfo", "GetItemInfo", "GetAverageItemLevel",
    "GetNumSkillLines", "GetSkillLineInfo",
    -- Talents (self-reported spec)
    "GetNumTalentTabs", "GetTalentTabInfo",
    -- Misc WoW
    "GetTime", "GetServerTime", "GetRealmName",
    -- Lua 5.1 + WoW string/table extras
    "wipe", "strtrim", "strsplit", "strfind", "strmatch", "format",
    "tinsert", "tremove", "tContains", "time", "date",
}
