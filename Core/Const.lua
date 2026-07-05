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
    ANNOUNCED  = 90,
    TIMEOUT    = 91,
    NOADDON    = 92,
    DISENCHANT = 93, -- Feature V: a D/E award; renders "D/E" as the award reason (§6.10)
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
L["Commands: ping, version, scan, start, respond, award <n> <name>, end, resume, session, test [n], selftest, note <player> [text], mark <id|link> [text], history [player], report, gear [player], loot, player [name], council [add|remove <name>], config, sync"] =
    "Commands: ping, version, scan, start, respond, award <n> <name>, end, resume, session, test [n], selftest, note <player> [text], mark <id|link> [text], history [player], report, gear [player], loot, player [name], council [add|remove <name>], config, sync"

-- Phase 2 — bags + trade loot engine.
L["Tracking %s for council (from %s)."]     = "Tracking %s for council (from %s)."
L["You are not the master looter."]         = "You are not the master looter."
L["Councilable items in your bags:"]        = "Councilable items in your bags:"
L["  %d. %s (q%d)"]                         = "  %d. %s (q%d)"
L["  %d. %s (q%d) — looted before reload, no trade timer"] =
    "  %d. %s (q%d) — looted before reload, no trade timer"
L["  %d. %s (q%d) — ~%s left to trade"] =
    "  %d. %s (q%d) — ~%s left to trade"
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
-- Phase 7 — session recovery on ML disconnect (DL-6).
L["Unfinished loot session from %s — %d item(s), %d response(s) collected."] =
    "Unfinished loot session from %s — %d item(s), %d response(s) collected."
L["/lcex resume to re-open, /lcex end to discard."] =
    "/lcex resume to re-open, /lcex end to discard."
L["Resume"]                                 = "Resume"
L["Resuming locally — you're not in a group, so this is read-only recovery."] =
    "Resuming locally — you're not in a group, so this is read-only recovery."
L["Resumed session (%s) — %d item(s)."]     = "Resumed session (%s) — %d item(s)."
L["Discarded the unfinished session."]      = "Discarded the unfinished session."
L["No session to resume."]                  = "No session to resume."
L["Session ML %s went quiet — closing the session view."] =
    "Session ML %s went quiet — closing the session view."
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

-- Session UI — the poll (candidate response cards).
L["Loot Drop"]                             = "Loot Drop"
L["Nothing for you this round."]           = "Nothing for you this round."
L["%ds left"]                              = "%ds left"
L["+ %d more"]                             = "+ %d more"
L["Responded %s to %s."]                   = "Responded %s to %s."
L["%s responded %s to %s."]                = "%s responded %s to %s."
L["No active loot session to respond to."] = "No active loot session to respond to."

-- Session UI — the loot window (item rail + candidate table).
L["Loot Session"]                          = "Loot Session"
L["No responses yet."]                     = "No responses yet."
L["Award"]                                 = "Award"
L["Awarded"]                               = "Awarded"
L["Leave session"]                         = "Leave session"
L["Copy %d"]                               = "Copy %d"
L["unawarded"]                             = "unawarded"
L["Every copy of that item is already awarded."] = "Every copy of that item is already awarded."
L["Leave note…"]                           = "Leave note…"
L["Clear note"]                            = "Clear note"
L["Note for %s:"]                          = "Note for %s:"
L["Save"]                                  = "Save"
L["Start session"]                         = "Start session"
L["End session"]                           = "End session"
L["Session active — %d item(s)."]          = "Session active — %d item(s)."
L["%d / %d voted"]                         = "%d / %d voted"
L["Voted:"]                                = "Voted:"
L["No votes yet."]                         = "No votes yet."
L["Anonymous voting"]                      = "Anonymous voting"
L["%s was awarded to %s for %s."]          = "%s was awarded to %s for %s."
L["%s was awarded to %s."]                 = "%s was awarded to %s."
L["D/E"]                                   = "D/E"
L["Correct award"]                         = "Correct award"
L["Un-award %s"]                           = "Un-award %s"
L["Un-award %s and reopen the item for awarding?"] =
    "Un-award %s and reopen the item for awarding?"
L["Correct the record: %s no longer marked as the winner. The item was already traded — this does not reverse the trade."] =
    "Correct the record: %s no longer marked as the winner. The item was already traded — this does not reverse the trade."
L["Award of %s to %s was undone."]         = "Award of %s to %s was undone."
L["(retracted)"]                           = "(retracted)"
L["Correct record"]                        = "Correct record"
L["Retract record…"]                       = "Retract record…"
L["Retract the record of %s → %s? (record only)"] =
    "Retract the record of %s → %s? (record only)"
L["Confirm"]                               = "Confirm"
L["Yes"]                                   = "Yes"
L["No"]                                    = "No"
L["Send %s to %s for disenchant?"]         = "Send %s to %s for disenchant?"
L["No disenchanter available. Send %s for disenchant to:"] =
    "No disenchanter available. Send %s for disenchant to:"
L["Scan bags"]                             = "Scan bags"
L["SESSION ITEMS"]                         = "SESSION ITEMS"
L["STAGED ITEMS"]                          = "STAGED ITEMS"
L["Loot session: %d item(s) · %d response(s)"] = "Loot session: %d item(s) · %d response(s)"
L["Loot session: %d item(s) · %d awarded"] = "Loot session: %d item(s) · %d awarded"
L["Unresolved loot session — click to review"] = "Unresolved loot session — click to review"
L["%d item(s) staged."]                    = "%d item(s) staged."
L["Nothing staged — scan your bags or add items."] =
    "Nothing staged — scan your bags or add items."
L["Couldn't read that item — shift-click a link or type an itemID."] =
    "Couldn't read that item — shift-click a link or type an itemID."

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

-- The council dashboard + its modules.
L["Council"]                                = "Council"
L["Loot Browser"]                           = "Loot Browser"
L["Players"]                                = "Players"
L["Roster"]                                 = "Roster"
L["History"]                                = "History"
L["Session Config"]                         = "Session Config"
L["(token)"]                                = "(token)"
L["Winner:"]                                = "Winner:"
L["Poll response deadline"]                 = "Poll response deadline"
L["Off"]                                    = "Off"
L["Include guild ranks at or above:"]       = "Include guild ranks at or above:"
L["Rank cutoff (0 = GM)"]                   = "Rank cutoff (0 = GM)"
L["Extra members (any guild rank):"]        = "Extra members (any guild rank):"
L["Disenchanters (D/E), ranked:"]           = "Disenchanters (D/E), ranked:"
L["Show the full loot window (responses & votes) to all raiders"] =
    "Show the full loot window (responses & votes) to all raiders"
L["Inherit %s loot-council settings from %s?"] =
    "Inherit %s loot-council settings from %s?"
L["Inherited %s loot-council settings from %s."] =
    "Inherited %s loot-council settings from %s."
L["Response buttons: BiS / Major / Minor / Greed / Pass (editor coming later)."] =
    "Response buttons: BiS / Major / Minor / Greed / Pass (editor coming later)."

-- The guild bank module (Feature B).
L["Guild Bank"]                            = "Guild Bank"
L["not cached"]                            = "not cached"
L["cached just now"]                       = "cached just now"
L["cached %dm ago"]                        = "cached %dm ago"
L["Contents"]                              = "Contents"
L["Log"]                                   = "Log"
L["Tab %d"]                                = "Tab %d"
L["deposited"]                             = "deposited"
L["withdrew"]                              = "withdrew"
L["moved"]                                 = "moved"
L["repaired"]                              = "repaired"
L["No transactions logged yet."]           = "No transactions logged yet."
L["Open the guild bank in-game to scan it."] = "Open the guild bank in-game to scan it."
L["Note for %s's transaction:"]            = "Note for %s's transaction:"
L["Save"]                                  = "Save"
L["+ note"]                                = "+ note"
L["Show the guild-bank log to all raiders"] = "Show the guild-bank log to all raiders"

-- The config window.
L["Configuration"]                          = "Configuration"
L["Appearance"]                             = "Appearance"
L["Window scale"]                           = "Window scale"
L["Council window opacity"]                 = "Council window opacity"
L["Minimap"]                                = "Minimap"
L["Show the minimap button"]                = "Show the minimap button"
L["Loot"]                                   = "Loot"
L["Loot quality threshold"]                 = "Loot quality threshold"
L["Broadcast my gear/professions (self-report)"] =
    "Broadcast my gear/professions (self-report)"
L["No award history."]                      = "No award history."
L["Note:"]                                  = "Note:"
L["by %s, %s"]                              = "by %s, %s"
L["Class %s · Spec %s · %s"]                = "Class %s · Spec %s · %s"
L["No BiS data for this class/spec/phase."] = "No BiS data for this class/spec/phase."
L["Class: %s"]                              = "Class: %s"
L["Spec: %s"]                               = "Spec: %s"

-- Phase 7 — in-game self-test (/lcex selftest).
L["Self-test: running %d checks…"]          = "Self-test: running %d checks…"
L["Self-test already running."]             = "Self-test already running."
L["Self-test: %d passed, %d failed, %d errors, %d skipped (v%s, %.1fs)"] =
    "Self-test: %d passed, %d failed, %d errors, %d skipped (v%s, %.1fs)"
L["Self-test report saved. /reload to write it to disk, then tell Claude to read it."] =
    "Self-test report saved. /reload to write it to disk, then tell Claude to read it."

-- Phase 7 — data-freshness (stale-cache indicators).
L["cached %s"]                              = "cached %s"
L["just now"]                               = "just now"
L["%dm ago"]                                = "%dm ago"
L["%dh ago"]                                = "%dh ago"
L["%dd ago"]                                = "%dd ago"
L["unknown"]                                = "unknown"

-- Phase 8 — gear-issue tags (Feature G).
L["No enchant"]                             = "No enchant"
L["Non-BiS enchant"]                        = "Non-BiS enchant"
L["Empty socket"]                           = "Empty socket"
L["Low-quality gem"]                        = "Low-quality gem"
L["No gear issues found."]                  = "No gear issues found."
L["Show gear issues"]                       = "Show gear issues"

-- Phase 9 — voting readiness (Feature V): seeded-row reasons.
L["Waiting"]                                = "Waiting"
L["Can't use"]                              = "Can't use"
L["Missed kill"]                            = "Missed kill"
L["Left"]                                   = "Left"
