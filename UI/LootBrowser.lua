-- ── LootCouncil EX — UI/LootBrowser.lua ──────────────────────────────────────
-- The loot browser: phase tabs → a boss-sorted list of items, each with its persistent mark
-- editable inline. Reads the static Loot data through DataAPI accessors and the marks dataset;
-- mark edits go out via LCEX:SetMark (council-gated, broadcasts pSet).
--
-- The body is ONE flat virtualized scroll list over a mixed display array (raid header / boss
-- header / item rows) so FauxScrollFrame windowing stays uniform — `BuildBrowserDisplay(phase)`
-- builds that array (pure, headless-tested) and `FillBrowserRow` switches on entry.kind.
--
-- Loads after UI/Widgets.lua (tab strip / scroll list / edit box) and the Data files.

local LCEX = LootCouncilEX

-- GetItemInfoInstant: synchronous, never-nil; on Anniversary it may live under C_Item.
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

-- (BuildBrowserDisplay lives in Core/Display.lua.)

-- One reusable row: icon + text (item name / header) + an inline mark edit box (items only).
function LCEX:BuildBrowserRow(parent)
    local addon = self
    local row = CreateFrame("Frame", nil, parent)

    row.icon = self:CreateItemIcon(row, 20)
    row.icon:SetPoint("LEFT", 4, 0)

    row.text = self:CreateLabel(row, nil, "GameFontHighlight")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetWidth(190); row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)

    row.mark = self:CreateEditBox(row, {
        width = 190,
        onCommit = function(text)
            if row.itemID then addon:SetMark(row.itemID, text) end
        end,
    })
    row.mark:SetPoint("LEFT", row.text, "RIGHT", 8, 0)
    return row
end

function LCEX:FillBrowserRow(row, entry)
    if entry.kind == "item" then
        row.itemID = entry.itemID
        local instantIcon = GetItemInfoInstant and select(5, GetItemInfoInstant(entry.itemID))
        row.icon:SetItem(nil, instantIcon)
        row.icon:Show()
        -- Tier-token cross-ref annotation, if this item is a token.
        local token = self:FindTokenForItem(entry.itemID)
        local suffix = token and ("  |cff888888(" .. tostring(token.name) .. ")|r") or ""
        row.text:SetText("item:" .. entry.itemID .. suffix)
        self:WithItemID(entry.itemID, function(name, link)
            if row.itemID ~= entry.itemID then return end -- row reused while loading
            row.text:SetText((name or ("item:" .. entry.itemID)) .. suffix)
            row.icon:SetItem(link, instantIcon)
        end)
        local mark = self.db.global.marks[entry.itemID]
        row.mark:SetText((mark and mark.text) or "")
        row.mark:Show()
    else
        row.itemID = nil
        row.icon:Hide()
        row.mark:Hide()
        row.text:SetText(entry.text)
        row.text:SetFontObject(entry.kind == "raid" and "GameFontNormalLarge" or "GameFontNormal")
        if entry.kind == "item" then row.text:SetFontObject("GameFontHighlight") end
    end
end

function LCEX:EnsureLootBrowser()
    if self.lootBrowser then return self.lootBrowser end
    local f = self:CreateWindow("LCEX_LootBrowser", {
        width = 480, height = 430,
        title = self.L["LootCouncil EX — Loot Browser"],
        savedKey = "lootBrowser",
    })

    local tabs = {}
    for _, p in ipairs(self:GetLootPhases()) do tabs[#tabs + 1] = { key = p, text = p } end
    f.tabs = self:CreateTabStrip(f, tabs, function(phase) self:ShowLootPhase(phase) end)
    f.tabs:SetPoint("TOPLEFT", 16, -38)

    f.list = self:CreateScrollList(f, {
        rowHeight = 24, visibleRows = 13, width = 446,
        buildRow = function(parent) return self:BuildBrowserRow(parent) end,
        fillRow = function(row, entry) self:FillBrowserRow(row, entry) end,
    })
    f.list:SetPoint("TOPLEFT", 16, -68)

    self.lootBrowser = f
    return f
end

function LCEX:ShowLootPhase(phase)
    self.browserPhase = phase
    if self.lootBrowser then
        self.lootBrowser.list:SetData(self:BuildBrowserDisplay(phase))
    end
end

-- /lcex loot — toggle the browser. Selecting a phase tab renders it (and resets scroll).
function LCEX:ToggleLootBrowser()
    local f = self:EnsureLootBrowser()
    if f:IsShown() then
        f:Hide()
    else
        local phases = self:GetLootPhases()
        f.tabs:Select(self.browserPhase or phases[1])
        f:Show()
    end
end
