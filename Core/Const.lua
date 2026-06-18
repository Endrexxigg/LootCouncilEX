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
--
-- These are DEFAULTS. Making the set user-configurable (add/remove/rename) is Phase 3,
-- once there is a settings UI and the responses actually drive candidate/voting frames.
-- `PASS` is a built-in: it must always exist so a candidate can decline and so timeouts
-- resolve to a non-response.
LCEX.RESPONSES = {
    [1] = { id = 1, key = "BIS",   text = "BiS",   color = { 0.96, 0.55, 0.73 } },
    [2] = { id = 2, key = "MAJOR", text = "Major", color = { 0.20, 1.00, 0.20 } },
    [3] = { id = 3, key = "MINOR", text = "Minor", color = { 1.00, 0.96, 0.41 } },
    [4] = { id = 4, key = "GREED", text = "Greed", color = { 0.70, 0.70, 0.70 } },
    [5] = { id = 5, key = "PASS",  text = "Pass",  color = { 0.60, 0.20, 0.20 } },
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
L["Version check sent (v%s) — watch for replies."] =
    "Version check sent (v%s) — watch for replies."
L["Commands: ping, version, scan, start, respond, award <n> <name>, end, session, test [n], note <player> [text], mark <id|link> [text], history [player], report, gear [player], loot, council [add|remove <name>], sync"] =
    "Commands: ping, version, scan, start, respond, award <n> <name>, end, session, test [n], note <player> [text], mark <id|link> [text], history [player], report, gear [player], loot, council [add|remove <name>], sync"

-- Phase 2 — bags + trade loot engine.
L["Tracking %s for council (from %s)."]     = "Tracking %s for council (from %s)."
L["You are not the master looter."]         = "You are not the master looter."
L["Councilable items in your bags:"]        = "Councilable items in your bags:"
L["  %d. %s (q%d)"]                         = "  %d. %s (q%d)"
L["  %d. %s (q%d) — looted before reload, no trade timer"] =
    "  %d. %s (q%d) — looted before reload, no trade timer"
L["Nothing councilable in your bags."]      = "Nothing councilable in your bags."
L["A session is already active. /lcex end first."] =
    "A session is already active. /lcex end first."
L["Nothing to council."]                    = "Nothing to council."
L["Session started (%s) — %d item(s) broadcast."] =
    "Session started (%s) — %d item(s) broadcast."
L["Session started (%s) — %d item(s) [local only, not in a group]."] =
    "Session started (%s) — %d item(s) [local only, not in a group]."
L["Session %s — %d item(s):"]               = "Session %s — %d item(s):"
L["Session ended."]                         = "Session ended."
L["No active session."]                     = "No active session."
L["Usage: /lcex award <itemIndex> <name>"]  = "Usage: /lcex award <itemIndex> <name>"
L["No item #%d in the session."]            = "No item #%d in the session."
L["Recorded: %s → %s. Trade it to them within the window to hand it off."] =
    "Recorded: %s → %s. Trade it to them within the window to hand it off."
L["Auto-filled %s into the trade with %s."] = "Auto-filled %s into the trade with %s."
L["Could not auto-fill %s — drag it into the trade window yourself."] =
    "Could not auto-fill %s — drag it into the trade window yourself."
L["Note: %s was awarded to %s but traded to %s."] =
    "Note: %s was awarded to %s but traded to %s."
L["You have %d minute(s) left to trade %s to %s."] =
    "You have %d minute(s) left to trade %s to %s."
L["Trade window for %s (%s) has expired."]  = "Trade window for %s (%s) has expired."
L["Test session: broadcasting %d sample item(s)."] =
    "Test session: broadcasting %d sample item(s)."

-- Phase 3 — session UI (candidate response loop).
L["LootCouncil EX — Respond"]              = "LootCouncil EX — Respond"
L["Note (sent with your response):"]       = "Note (sent with your response):"
L["Responded %s to %s."]                   = "Responded %s to %s."
L["%s responded %s to %s."]                = "%s responded %s to %s."
L["No active loot session to respond to."] = "No active loot session to respond to."
L["LootCouncil EX — Council"]              = "LootCouncil EX — Council"
L["No responses yet."]                     = "No responses yet."
L["Award"]                                 = "Award"
L["LootCouncil EX"]                        = "LootCouncil EX"
L["Refresh"]                               = "Refresh"
L["Start session"]                         = "Start session"
L["End session"]                           = "End session"
L["Session active — %d item(s)."]          = "Session active — %d item(s)."
L["%d councilable item(s) in your bags."]  = "%d councilable item(s) in your bags."

-- Phase 4 — council sync (Plane B) + proof commands.
L["Synced %d %s record(s) from %s."]       = "Synced %d %s record(s) from %s."
L["%s updated %s[%s]."]                     = "%s updated %s[%s]."
L["Sync digest broadcast."]                 = "Sync digest broadcast."
L["dummy[%s] = %s"]                         = "dummy[%s] = %s"
L["dummy dataset — %d record(s):"]          = "dummy dataset — %d record(s):"
L["  %s = %s  (mod %s, by %s)"]             = "  %s = %s  (mod %s, by %s)"
L["Added %s to the council."]               = "Added %s to the council."
L["Removed %s from the council."]           = "Removed %s from the council."
L["Council — %d member(s) (you: %s):"]      = "Council — %d member(s) (you: %s):"
L["member"]                                 = "member"
L["not a member"]                           = "not a member"
L["  %s"]                                    = "  %s"

-- Phase 5 — council datasets (notes / marks / history / self-report).
L["Heads-up: you're not on the council — this won't sync to others."] =
    "Heads-up: you're not on the council — this won't sync to others."
L["Usage: /lcex note <player> [text]"]      = "Usage: /lcex note <player> [text]"
L["Note on %s set."]                        = "Note on %s set."
L["Note on %s: %s  (by %s)"]                = "Note on %s: %s  (by %s)"
L["No note on %s."]                         = "No note on %s."
L["Usage: /lcex mark <itemID|link> [text]"] = "Usage: /lcex mark <itemID|link> [text]"
L["Mark on item %d set."]                   = "Mark on item %d set."
L["Mark on item %d: %s  (by %s)"]           = "Mark on item %d: %s  (by %s)"
L["No mark on item %d."]                    = "No mark on item %d."
L["Award history — %d record(s):"]          = "Award history — %d record(s):"
L["  %s → %s  (%s, %s)"]                     = "  %s → %s  (%s, %s)"
L["  …and %d more."]                         = "  …and %d more."
L["Self-report broadcast."]                 = "Self-report broadcast."
L["Self-report not sent (disabled, or not in a guild)."] =
    "Self-report not sent (disabled, or not in a guild)."
L["(your live snapshot)"]                   = "(your live snapshot)"
L["(no cached report)"]                     = "(no cached report)"
L["Gear/profs — %s %s"]                     = "Gear/profs — %s %s"
L["  slot %d: %s"]                          = "  slot %d: %s"
L["  %s: %d"]                               = "  %s: %d"

-- Phase 6 — viewer UIs.
L["LootCouncil EX — Loot Browser"]          = "LootCouncil EX — Loot Browser"
L["LootCouncil EX — Player"]                = "LootCouncil EX — Player"
