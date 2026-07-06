--@do-not-package@
-- ── LootCouncil EX — DevAudit/Adapter.lua ────────────────────────────────────
-- DEV-ONLY. Registers LootCouncilEX with the AddonUIAudit engine. Stripped from any
-- packaged build and inert without the engine (the first line bails). This is the ONLY
-- place LCEX-specific audit knowledge lives; the engine stays fully generic.
--
-- Loads LAST in the .toc, after every LCEX module and after DevAudit/Fixtures.lua, so
-- LCEX.__auiaFixtures and all the window functions exist. AddonUIAudit is declared in
-- OptionalDeps, so when installed it finishes loading before LCEX and the global exists.

local AUA = AddonUIAudit
if not AUA then return end          -- engine not installed: no-op
local LCEX = LootCouncilEX
if not LCEX then return end

local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata

AUA:RegisterAddon("LootCouncilEX", {
    engineApi = 1,
    version   = (getMeta and getMeta("LootCouncilEX", "Version")) or "dev",

    -- SavedVariables the engine deep-snapshots before each fixture and dirty-checks after.
    savedVariables = { "LootCouncilEXDB" },

    -- LCEX's AceComm prefix — the sandbox flags only OUR addon messages, so unrelated
    -- third-party traffic during the fixture window isn't reported as a violation.
    commPrefixes = { "LCEX" },

    -- Silence all outbound comms for the duration of every fixture (setup → teardown),
    -- including LCEX's background guild sync that may fire on a timer mid-run. We swap
    -- LCEX's OWN comm methods (taint-safe — addon-local), so nothing reaches the wire.
    -- The engine's hooksecurefunc detection remains the net for anything that slips past.
    stubComms = function(on)
        if on then
            LCEX.__auiaComm = { scm = LCEX.SendCommMessage, send = LCEX.Send }
            if LCEX.SendCommMessage then LCEX.SendCommMessage = function() end end
            if LCEX.Send then LCEX.Send = function() end end
        else
            local o = LCEX.__auiaComm
            if o then
                if o.scm then LCEX.SendCommMessage = o.scm end
                if o.send then LCEX.Send = o.send end
                LCEX.__auiaComm = nil
            end
        end
    end,

    -- Adapter-level roots (lazy closures): used when a fixture declares none, and as the
    -- audit surface for a future live-state pass. Fixtures below declare their own roots.
    roots = {
        function() return LCEX.lootWindow end,
        function() return LCEX.pollFrame end,
        function() return LCEX.councilWindow end,
        function() return LCEX.configWindow end,
    },

    -- Tune engine rules for this addon. A truncated item/response label with no way to
    -- read the full text is a real bug here, so raise it to ERROR. (The engine now detects
    -- row-mate tooltip hosts — the adjacent item icon — generically, so no per-window
    -- tooltipProviders declaration is needed.)
    rules = {
        severity = { ["TEXT/TRUNCATED_NO_TOOLTIP"] = "ERROR" },
    },

    fixtures = LCEX.__auiaFixtures,
})

LCEX.__auiaFixtures = nil   -- consumed; don't leave it dangling on the addon table
--@end-do-not-package@
