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

    -- (Text severity is no longer a blanket per-rule override. Instead we classify text by
    -- importance below via `textImportance`, so the engine escalates an UNREADABLE truncation
    -- of a decision-relevant or user-authored field to ERROR on its own, while item/player
    -- names stay WARN and the value is only "readable" where LCEX actually exposes it.)

    -- LCEX's top-level windows are independent, user-draggable frames — the player can stack
    -- them however they like (and solo, the ML sees the loot window while their own poll card
    -- is up, so poll+loot ARE co-visible). When two overlap, the engine sees each window's own
    -- draggable ROOT frame as an interactive "control" covering the OTHER window's labels
    -- (OVERLAP/CONTROL_LABEL). That's expected floating-window behavior, not a layout defect.
    -- The pattern matches only a BARE window root as the control (no dotted child path) covering
    -- an LCEX label; the rule already excludes a frame's own descendants, so this exempts ONLY
    -- cross-window overlap and never hides an in-window control-over-label collision.
    expectations = {
        allowedOverlaps = { { a = "^LCEX_%a+$", b = "^LCEX_" } },

        -- Text importance (pilot). Maps LCEX text fields to importance classes so the engine
        -- can enforce readability without knowing anything LCEX-specific. `fallback` asserts
        -- WHERE the full value is reachable — required for user-authored / decision-critical
        -- text, whose readability the engine will NOT infer from a heuristic. Each is honest:
        --   • candidate name + response: the row's nameBtn OnEnter shows the full name and the
        --     full response text (UI/LootWindow.lua — "decision-relevant during a vote").
        --   • responder note: the row stores _noteText "full text for the hover tooltip".
        --   • staged item name: the rail row's OnEnter opens the item tooltip.
        -- Ordered; first debugName match wins. Rail vs pane .name are scoped by container.
        textImportance = {
            { pattern = "%.pane%..-%.name$", class = "player-identity",   fallback = "tooltip" },
            { pattern = "%.resp$",           class = "decision-critical", fallback = "tooltip" },
            { pattern = "%.note$",           class = "user-authored",     fallback = "tooltip" },
            { pattern = "%.rail%..-%.name$", class = "item-identity",     fallback = "tooltip" },
        },
    },

    fixtures = LCEX.__auiaFixtures,
})

LCEX.__auiaFixtures = nil   -- consumed; don't leave it dangling on the addon table
--@end-do-not-package@
