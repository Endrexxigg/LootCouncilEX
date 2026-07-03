-- ── LootCouncil EX — UI/CouncilWindow.lua ────────────────────────────────────
-- The `council` frame: the out-of-raid dashboard. A large, RESIZABLE window (corner grip,
-- profile-persisted size, configurable opacity) with a LEFT nav rail whose entries come from
-- a MODULE REGISTRY — future modules are one RegisterCouncilModule call, no shell changes.
--
-- Module contract:
--   LCEX:RegisterCouncilModule{ key, title, order, build(panel), show(panel, ctx), hide(panel) }
--     • build(panel)  — runs ONCE, lazily, on the module's first display; creates its widgets
--                       inside `panel` (a full-content-area frame).
--     • show(panel, ctx) — runs on every display; ctx is the optional payload from
--                       OpenCouncilModule (e.g. a player name for the Players module).
--     • hide(panel)   — optional; runs when another module takes over.
--
-- Loads after UI/Theme.lua + UI/Widgets.lua; the UI/council/*.lua modules load after this
-- file and self-register.

local LCEX = LootCouncilEX

local FRAME_NAME = "LCEX_CouncilWindow"
local RAIL_W     = 170

LCEX.councilModules = LCEX.councilModules or {}

function LCEX:RegisterCouncilModule(def)
    tinsert(self.councilModules, def)
end

local function ModuleByKey(self, key)
    for _, def in ipairs(self.councilModules) do
        if def.key == key then return def end
    end
    return nil
end

function LCEX:EnsureCouncilWindow()
    if self.councilWindow then return self.councilWindow end
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = 920, height = 560,
        title = self.L["Council"],
        savedKey = "council",
        resizable = true, minW = 760, minH = 440,
        useOpacity = true,
        defaultPos = { x = 0, y = 0 },
    })

    f.rail = self:CreateNavRail(f, {
        width = RAIL_W,
        onSelect = function(key) self:CouncilShowModule(key) end,
    })
    f.rail:SetPoint("TOPLEFT", 2, -32)
    f.rail:SetPoint("BOTTOMLEFT", 2, 2)

    f.content = CreateFrame("Frame", nil, f)
    f.content:SetPoint("TOPLEFT", f.rail, "TOPRIGHT", 4, 0)
    f.content:SetPoint("BOTTOMRIGHT", -2, 2)
    self:Surface(f.content, "page")

    -- One full-size panel per registered module (built lazily on first show).
    f.panels = {}
    table.sort(self.councilModules, function(a, b) return (a.order or 99) < (b.order or 99) end)
    for _, def in ipairs(self.councilModules) do
        f.rail:AddItem(def.key, def.title)
        local panel = CreateFrame("Frame", nil, f.content)
        panel:SetAllPoints(f.content)
        panel:Hide()
        f.panels[def.key] = panel
    end

    self.councilWindow = f
    return f
end

-- Switch the content area to `key` (rail already highlighted by the caller / rail itself).
function LCEX:CouncilShowModule(key)
    local f = self.councilWindow
    local def = ModuleByKey(self, key)
    if not f or not def then return end

    if f.activeModule and f.activeModule ~= key then
        local prev = ModuleByKey(self, f.activeModule)
        local prevPanel = f.panels[f.activeModule]
        if prev and prev.hide and prevPanel then prev.hide(prevPanel) end
        if prevPanel then prevPanel:Hide() end
    end

    local panel = f.panels[key]
    if not panel.built then
        def.build(panel)
        panel.built = true
    end
    f.activeModule = key
    panel:Show()
    def.show(panel, self._councilCtx)
    self._councilCtx = nil
end

-- Open the window on a specific module, with an optional context payload for its show().
function LCEX:OpenCouncilModule(key, ctx)
    local f = self:EnsureCouncilWindow()
    self._councilCtx = ctx
    f:Show()
    f.rail:Select(key) -- drives CouncilShowModule via onSelect
end

function LCEX:ToggleCouncilWindow()
    local f = self:EnsureCouncilWindow()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        f.rail:Select(f.activeModule or (self.councilModules[1] and self.councilModules[1].key))
    end
end
