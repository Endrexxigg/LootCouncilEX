-- ── LootCouncil EX — Const.lua ───────────────────────────────────────────────
-- Static constants and the locale table. No behaviour lives here — just the values
-- the rest of the addon reads: the comms protocol version, the canonical RESPONSES /
-- STATUS enums (PROJECT.md §6.5, the single source UI and comms are data-driven from),
-- and the L[] string table all user-facing text flows through.
--
-- Loads after Init.lua, so the LootCouncilEX global already exists to hang these off.

local LCEX = LootCouncilEX

-- Comms wire-format version (the `v` field of every envelope; PROJECT.md §6). An
-- integer treated as the protocol "major": a receiver drops any message whose `v` is
-- higher than this. Bump it only on an incompatible envelope/payload change. This is
-- NOT the addon's `## Version` ("0.1") — that is a separate, human-facing string.
LCEX.PROTOCOL_VERSION = 1

-- Candidate response options. UI columns/buttons and comms responses are built from
-- this table, never hardcoded (PROJECT.md §6.5). Index order = display order.
LCEX.RESPONSES = {
    [1] = { id = 1, key = "BIS",   text = "BiS",       color = { 0.96, 0.55, 0.73 } },
    [2] = { id = 2, key = "MS",    text = "Mainspec",  color = { 0.20, 1.00, 0.20 } },
    [3] = { id = 3, key = "OS",    text = "Offspec",   color = { 1.00, 1.00, 0.40 } },
    [4] = { id = 4, key = "MINOR", text = "Minor Upg", color = { 0.70, 0.70, 0.70 } },
    [5] = { id = 5, key = "PASS",  text = "Pass",      color = { 0.60, 0.20, 0.20 } },
}

-- Non-response status codes (PROJECT.md §6.5). Kept numerically clear of RESPONSES ids.
LCEX.STATUS = {
    ANNOUNCED = 90,
    TIMEOUT   = 91,
    NOADDON   = 92,
}

-- Locale. AceLocale is intentionally not embedded; this is a plain table whose
-- metatable returns the key itself for any unset string, so a missing translation
-- degrades to readable English rather than nil. enUS for now; add other locales by
-- assigning into L under a locale guard later.
local L = setmetatable({}, { __index = function(_, k) return k end })
LCEX.L = L

L["v%s loaded."]                      = "v%s loaded."
L["%s is running v%s"]                = "%s is running v%s"
L["Known addon users:"]               = "Known addon users:"
L["  %s — v%s"]                       = "  %s — v%s"
L["Not in a group — nothing to broadcast."] = "Not in a group — nothing to broadcast."
L["Commands: ping, version, scan, start, award <n> <name>, end, session"] =
    "Commands: ping, version, scan, start, award <n> <name>, end, session"

-- Phase 2 — loot engine (session + award).
L["Detected %d councilable item(s):"]      = "Detected %d councilable item(s):"
L["  %d. %s (slot %d, q%d)"]                = "  %d. %s (slot %d, q%d)"
L["No councilable items on this corpse."]   = "No councilable items on this corpse."
L["No loot window open (or you are not the master looter)."] =
    "No loot window open (or you are not the master looter)."
L["Nothing scanned — open a corpse as master looter first."] =
    "Nothing scanned — open a corpse as master looter first."
L["A session is already active. /lcex end first."] =
    "A session is already active. /lcex end first."
L["Session started (%s) — %d item(s) broadcast."] =
    "Session started (%s) — %d item(s) broadcast."
L["Session %s — %d item(s):"]               = "Session %s — %d item(s):"
L["Session ended."]                         = "Session ended."
L["No active session."]                     = "No active session."
L["Usage: /lcex award <itemIndex> <name>"]  = "Usage: /lcex award <itemIndex> <name>"
L["No item #%d in the scan."]               = "No item #%d in the scan."
L["Loot window is closed."]                 = "Loot window is closed."
L["Item #%d is no longer in slot %d."]      = "Item #%d is no longer in slot %d."
L["%s is not an eligible candidate for that item."] =
    "%s is not an eligible candidate for that item."
L["Awarded %s to %s."]                      = "Awarded %s to %s."
