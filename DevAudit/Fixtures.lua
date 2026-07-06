--@do-not-package@
-- ── LootCouncil EX — DevAudit/Fixtures.lua ───────────────────────────────────
-- DEV-ONLY. Deterministic UI fixtures for the AddonUIAudit engine. This file is
-- stripped from any packaged build (the --@do-not-package@ wrappers + the .pkgmeta
-- ignore of DevAudit/) and is inert without the engine installed. It contains the
-- LCEX-specific knowledge the generic engine must not: which functions open which
-- windows, and how to drive them into realistic states with fake data.
--
-- Side-effect discipline (mirrors Core/SelfTest.lua):
--   • Solo only for the session fixture — GroupChannel() is nil, so nothing broadcasts;
--     the fixture also stubs LCEX.Send as belt-and-braces.
--   • Every fixture cleans up in teardown (EndSession / HidePoll / Hide + reset state),
--     so no residue reaches SavedVariables. The engine's sandbox flags any it misses.
--
-- Loaded before DevAudit/Adapter.lua, which reads LCEX.__auiaFixtures.

local AUA = AddonUIAudit
if not AUA then return end          -- engine not installed: do nothing, define nothing
local LCEX = LootCouncilEX
if not LCEX then return end

-- A real wire item (link/quality from the client cache; falls back to a bare item string).
local function wireItem(id)
    local _, link, q = GetItemInfo(id)
    return { link = link or ("item:" .. id), itemID = id, quality = q or 4 }
end

-- A synthetic item that DISPLAYS a long name but carries a real, universally-usable
-- item id (28830 Dragonspine Trophy — a trinket every class can use), so it survives
-- the poll's class-usability filter while forcing name-column truncation. FillPollCard
-- and the loot rail both take the display name from the link's [bracket].
local function longItem(name, id)
    id = id or 28830
    return {
        link    = "|cffa335ee|Hitem:" .. id .. "::::::::70:::::|h[" .. name .. "]|h|r",
        itemID  = id,
        quality = 4,
    }
end

-- Realistic MAX-LENGTH TBC epic names (not absurd stress strings): these fit the poll
-- card / session pane widths but overflow the NARROW loot-rail name column — so the audit
-- reflects what a real long item does in the live UI, not a synthetic worst case.
local LONG_A = "Thunderfury, Blessed Blade of the Windseeker"
local LONG_B = "Girdle of the Exalted Deathdealer of Shadow"
-- Distinct universal item ids so the two long items never collapse into one group:
-- 28830 Dragonspine Trophy (trinket, all classes) and 30056 Robe of Hateful Echoes
-- (cloth, wearable by all classes). Both survive the poll's PlayerCanUse filter.
local ID_A, ID_B = 28830, 30056

LCEX.__auiaFixtures = {

    -- 1) Compact loot staging window with staged items. Targets the staging footer /
    --    Start-button overlap and long item names in the narrow rail.
    {
        name        = "loot-staging",
        description = "Compact staging window with staged items",
        expectations = { tooltipProviders = { "%.icon$" } },  -- item icons carry the tooltip
        guard = function()
            if LCEX.activeSession or LCEX.session then return false, "a session is open" end
            return true
        end,
        setup = function(fctx)
            LCEX:ShowLootWindow()
            LCEX.stagingItems = { longItem(LONG_A, ID_A), longItem(LONG_B, ID_B), wireItem(19019) }
            LCEX:RefreshLootWindow()
            fctx:DeclareRoot(LCEX.lootWindow, "loot-staging")
        end,
        settle = { frames = 3, ready = function() return LCEX.lootWindow and LCEX.lootWindow:IsShown() end },
        teardown = function()
            LCEX.stagingItems = {}
            if LCEX.lootWindow and LCEX.lootWindow:IsShown() then
                pcall(function() LCEX:RefreshLootWindow() end)
            end
            if LCEX.lootWindow then LCEX.lootWindow:Hide() end
        end,
    },

    -- 2) Poll window with long item names → the bounded, non-wrapping card.name
    --    truncates with no tooltip fallback of its own.
    {
        name        = "poll-long-choices",
        description = "Poll cards with very long item names",
        expectations = {},   -- card.name has no OnEnter → NO_TOOLTIP should fire
        guard = function()
            if LCEX.activeSession or LCEX.session then return false, "a session is open" end
            return true
        end,
        setup = function(fctx)
            local items = { longItem(LONG_A, ID_A), longItem(LONG_B, ID_B) }
            LCEX:ShowPoll(items, LCEX.RESPONSES, 0)
            fctx:DeclareRoot(LCEX.pollFrame, "poll")
        end,
        settle = { frames = 3, ready = function() return LCEX.pollFrame and LCEX.pollFrame:IsShown() end },
        teardown = function()
            if LCEX.HidePoll then pcall(function() LCEX:HidePoll() end) end
        end,
    },

    -- 3) Active loot session (solo, no broadcast) with long response notes. Targets
    --    the candidate rows / award buttons vs labels, and gives STRATA a co-visible
    --    poll+loot pair to compare.
    {
        name        = "loot-session-long",
        description = "Active session, long response notes/status",
        expectations = {},
        guard = function()
            if LCEX.session or LCEX.activeSession then return false, "a session is already open" end
            if LCEX.recoverableSession then return false, "unfinished session pending /lcex resume" end
            if LCEX:GroupChannel() then return false, "grouped — run solo so nothing broadcasts" end
            return true
        end,
        setup = function(fctx)
            -- Comms are stubbed engine-side via the adapter's stubComms hook for the whole
            -- fixture, so StartSession's broadcasts and any background sync are silenced.
            local it1, it2 = longItem(LONG_A, ID_A), longItem(LONG_B, ID_B)
            LCEX.sessionItems = {
                { link = it1.link, itemID = it1.itemID, quality = it1.quality, boss = "AUIAudit", lootedAt = time() },
                { link = it2.link, itemID = it2.itemID, quality = it2.quality, boss = "AUIAudit", lootedAt = time() },
            }
            LCEX:StartSession({
                { link = it1.link, quality = it1.quality },
                { link = it2.link, quality = it2.quality },
            })
            fctx.scratch.sid = LCEX.session and LCEX.session.sid
            fctx:DeclareRoot(LCEX.lootWindow, "loot-session")
            if LCEX.pollFrame then fctx:DeclareRoot(LCEX.pollFrame, "poll") end
        end,
        settle = { frames = 3, ready = function() return LCEX.lootWindow and LCEX.lootWindow:IsShown() end },
        states = {
            {
                name = "responded",
                enter = function(fctx)
                    -- Plausible raider notes that mildly exceed the narrow note column (they
                    -- surface real truncation, not a synthetic 120-char worst case).
                    LCEX:OnResponseChosen(1, LCEX.RESPONSES[1], "Off-spec set, low priority please")
                    LCEX:OnResponseChosen(2, LCEX.RESPONSES[2], "BiS for my main tanking set")
                    if LCEX.LootSelectItem then pcall(function() LCEX:LootSelectItem(1) end) end
                end,
            },
        },
        teardown = function(fctx)
            local sid = fctx.scratch.sid
            if LCEX.session and sid and LCEX.session.sid == sid then
                pcall(function() LCEX:EndSession() end)
            end
            LCEX.sessionItems = nil
            if LCEX.StopTradeTickerIfIdle then pcall(function() LCEX:StopTradeTickerIfIdle() end) end
        end,
    },

    -- 4) Scroll-heavy council surface (the loot browser) — declares a flat scroll
    --    style so the stock FauxScrollFrame scrollbar is flagged.
    {
        name        = "council-scroll",
        description = "Loot browser (scroll-heavy) with a flat scroll-style expectation",
        expectations = { scrollStyle = "flat" },
        setup = function(fctx)
            LCEX:OpenCouncilModule("browser")   -- synchronously populates panel.list (SetData)
            local cw = LCEX.councilWindow
            if cw then cw:SetHeight(320) end     -- fewer visible rows → easier to overflow
            fctx.scratch.raids, fctx.scratch.bosses = {}, {}
            local panel = cw and cw.panels and cw.panels.browser
            if panel and panel.list and panel.list.items and LCEX.BrowserToggle
               and LCEX.browserExpanded and LCEX.browserExpanded.raids and LCEX.browserExpanded.bosses then
                -- The browser starts fully collapsed and a phase may have only 1-3 raid headers,
                -- which fit without scrolling. Expand every raid AND every boss so the item rows
                -- far exceed the visible-row count and the stock FauxScrollFrame bar must show.
                -- Collect keys before toggling (each toggle rebuilds panel.list.items).
                local raidKeys = {}
                for _, e in ipairs(panel.list.items) do
                    if e.kind == "raid" and e.key ~= nil and LCEX.browserExpanded.raids[e.key] == nil then
                        raidKeys[#raidKeys + 1] = e.key
                    end
                end
                for _, k in ipairs(raidKeys) do
                    fctx.scratch.raids[#fctx.scratch.raids + 1] = k
                    pcall(function() LCEX:BrowserToggle(panel, "raid", k) end)
                end
                local bossKeys = {}
                for _, e in ipairs(panel.list.items) do
                    if e.kind == "boss" and e.key ~= nil and LCEX.browserExpanded.bosses[e.key] == nil then
                        bossKeys[#bossKeys + 1] = e.key
                    end
                end
                for _, k in ipairs(bossKeys) do
                    fctx.scratch.bosses[#fctx.scratch.bosses + 1] = k
                    pcall(function() LCEX:BrowserToggle(panel, "boss", k) end)
                end
            end
            fctx:DeclareRoot(cw, "council")
        end,
        settle = { frames = 4, ready = function() return LCEX.councilWindow and LCEX.councilWindow:IsShown() end },
        teardown = function(fctx)
            -- Restore the collapse state we changed (absent key == collapsed == the default).
            if LCEX.browserExpanded then
                for _, k in ipairs(fctx.scratch.raids or {}) do LCEX.browserExpanded.raids[k] = nil end
                for _, k in ipairs(fctx.scratch.bosses or {}) do LCEX.browserExpanded.bosses[k] = nil end
            end
            if LCEX.councilWindow then LCEX.councilWindow:Hide() end
        end,
    },
}
--@end-do-not-package@
