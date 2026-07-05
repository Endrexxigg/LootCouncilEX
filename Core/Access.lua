-- ── LootCouncil EX — Core/Access.lua ─────────────────────────────────────────
-- Feature C access control (§6.11). Pure predicates deciding who may EDIT the shared guild config,
-- SEE the officer Session Config module, and OPEN the loot/voting window. Read by CouncilWindow
-- (the module rail filter), LootWindow (the open gate), and Candidate/Council (the session-open
-- gate). Built on AmCouncil() + the local guild rank + config.visibility — no frames, no writes,
-- so they are headless-tested.
--
-- Loads after Sync.lua (AmCouncil / CouncilSet) and Config.lua (GetConfig / ConfigRecord).

local LCEX = LootCouncilEX

-- The local player's guild rank index (0 = GM), or nil when not in a guild.
function LCEX:MyGuildRank()
    if not IsInGuild() then return nil end
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex
end

-- May the local player EDIT the shared guild config? Council members author it (C2), with the C4
-- escape hatch so a guild can always bootstrap: solo/guildless (testing), when nothing is authored
-- yet, or as the GM (rank 0). A non-council raider in an established guild is read-only.
function LCEX:CanEditConfig()
    if not IsInGuild() then return true end         -- solo / guildless (testing)
    if not self:ConfigRecord() then return true end -- nobody has authored it yet (bootstrap)
    if self:MyGuildRank() == 0 then return true end -- GM
    return self:AmCouncil()                         -- officer rank / manual council (C2)
end

-- Is the officer Session Config module available to the local player? Council-only (C3); the same
-- escape hatch keeps it reachable for a solo / GM / bootstrap user so the config can be set up in the
-- first place. A non-council raider in an established guild never sees it.
function LCEX:CanSeeSessionConfig()
    return self:CanEditConfig()
end

-- Has the guild opted into showing the FULL loot/voting window to all raiders? Off by default.
-- Phase 12 repurposed this (DL-18): it now upgrades non-council from the list view to the full
-- view — it no longer gates whether the window opens at all.
function LCEX:LootWindowOptIn()
    local vis = self:GetConfig().visibility
    return (vis and vis.lootWindow) == true
end

-- The loot window's VIEW level for the local player (Phase 12, DL-18 — supersedes the C7 open
-- gate): everyone may OPEN the window; council and opted-in raiders get the full two-pane view
-- ("full"), everyone else the rail-only spectator view ("list" — items, quantities, award state,
-- winners; never responses/votes/notes). During a live session the level is snapshotted per
-- session (activeSession.viewLevel, EnterSession); this predicate seeds that snapshot and covers
-- the out-of-session case.
function LCEX:LootViewLevel()
    return (self:AmCouncil() or self:LootWindowOptIn()) and "full" or "list"
end

-- May the local player see the guild-bank LOG + annotations (Feature B, B5)? Council always; other
-- raiders only when the guild opted in (config.visibility.gbankLog). Contents + gold are public.
function LCEX:CanSeeGbankLog()
    if self:AmCouncil() then return true end
    local vis = self:GetConfig().visibility
    return (vis and vis.gbankLog) == true
end
