-- ── LootCouncil EX — UI/council/BrowserModule.lua ────────────────────────────
-- Council module: the loot browser, rebuilt for readability. Phase buttons across the top;
-- one reflowing list where raid headers read gold-on-raised bars, bosses indent below them,
-- and items indent further with QUALITY-COLORED names. Marks render inline as dim text; a
-- single editor at the bottom edits the SELECTED item's mark (click a row to select) —
-- replacing the old one-editbox-per-row noise. Mark commits go through SetMark (council-gated,
-- broadcasts pSet).
--
-- Data: Core/Display.lua BuildBrowserDisplay(phase) → {kind=raid/boss/item} rows;
-- names/qualities resolve async through WithItemID. Loads after UI/CouncilWindow.lua.

local LCEX = LootCouncilEX

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local INDENT_BOSS, INDENT_ITEM = 14, 30

-- Collapse state (item 13): absent key = collapsed, so every play session starts folded to the
-- raid headers. In-memory on purpose — a persisted tree would go stale across phase releases.
LCEX.browserExpanded = LCEX.browserExpanded or { raids = {}, bosses = {} }

-- +/− fold indicators as texture escapes (glyph-safe, like CHECK_TEX in the loot window).
local FOLD_OPEN   = "|TInterface\\Buttons\\UI-MinusButton-Up:14:14:0:0|t "
local FOLD_CLOSED = "|TInterface\\Buttons\\UI-PlusButton-Up:14:14:0:0|t "

local function BuildRow(panel)
    local row = CreateFrame("Button", nil, panel)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bg:Hide()

    row.sel = row:CreateTexture(nil, "ARTWORK")
    row.sel:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.sel:SetWidth(2)
    row.sel:SetPoint("TOPLEFT", 0, 0)
    row.sel:SetPoint("BOTTOMLEFT", 0, 0)
    row.sel:SetVertexColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3], 1)
    row.sel:Hide()

    row.icon = LCEX:CreateItemIcon(row, 18)
    row.text = row:CreateFontString(nil, "OVERLAY")
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row.mark = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.mark, "caption", "faint")
    row.mark:SetPoint("RIGHT", -8, 0)
    row.mark:SetJustifyH("RIGHT")
    row.mark:SetWordWrap(false)

    row:SetScript("OnClick", function(r)
        if r.itemID then
            LCEX:BrowserSelectItem(r.panel, r.itemID)
        elseif r.toggleKey then
            LCEX:BrowserToggle(r.panel, r.kind, r.toggleKey) -- raid/boss headers fold (item 13)
        end
    end)
    row.panel = panel
    return row
end

local function FillRow(panel, row, entry)
    row.loadingID = nil
    row.itemID = nil
    row.kind = entry.kind
    row.toggleKey = entry.key
    row.bg:Hide()
    row.sel:Hide()
    row.icon:Hide()
    row.mark:SetText("")
    row.text:ClearAllPoints()

    local fold = (entry.kind == "raid" or entry.kind == "boss")
        and (entry.expanded and FOLD_OPEN or FOLD_CLOSED) or ""
    if entry.kind == "raid" then
        row.bg:Show()
        LCEX:ApplyGradient(row.bg, LCEX.Theme.tone.raised.top, LCEX.Theme.tone.raised.bottom)
        LCEX:ThemeText(row.text, "body", "ink")
        row.text:SetTextColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3])
        row.text:SetPoint("LEFT", 8, 0)
        row.text:SetPoint("RIGHT", -8, 0)
        row.text:SetText(fold .. entry.text:upper())
    elseif entry.kind == "boss" then
        LCEX:ThemeText(row.text, "body", "ink")
        row.text:SetPoint("LEFT", INDENT_BOSS, 0)
        row.text:SetPoint("RIGHT", -8, 0)
        row.text:SetText(fold .. entry.text)
    else -- item
        row.itemID = entry.itemID
        row.icon:Show()
        row.icon:SetPoint("LEFT", INDENT_ITEM, 0)
        local instantIcon = GetItemInfoInstant and select(5, GetItemInfoInstant(entry.itemID))
        row.icon:SetItem(nil, instantIcon)
        LCEX:ThemeText(row.text, "body", "dim")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row.mark, "LEFT", -8, 0)
        row.text:SetText("item:" .. entry.itemID)

        local id = entry.itemID
        row.loadingID = id
        LCEX:WithItemID(id, function(name, link, quality)
            if row.loadingID ~= id then return end -- row reused while loading
            local q = LCEX:QualityColor(quality)
            row.text:SetText(name or ("item:" .. id))
            row.text:SetTextColor(q[1], q[2], q[3])
            row.icon:SetItem(link, instantIcon)
        end)

        row.mark:SetText(LCEX:BrowserMarkText(id))

        if panel.selectedItemID == id then row.sel:Show() end
    end
end

-- Fold/unfold a raid or boss header (item 13) and rebuild the list. Collapsing a raid hides its
-- bosses AND their items in one step (the display builder skips children of collapsed nodes).
function LCEX:BrowserToggle(panel, kind, key)
    local set = (kind == "raid") and self.browserExpanded.raids or self.browserExpanded.bosses
    set[key] = (not set[key]) and true or nil
    panel.list:SetData(self:BuildBrowserDisplay(self.browserPhase, self.browserExpanded))
end

-- Click-to-select: the bottom editor targets this item's mark.
function LCEX:BrowserSelectItem(panel, itemID)
    panel.selectedItemID = itemID
    local mark = self.db.global.marks[itemID]
    panel.markBox:SetText((mark and mark.text) or "")
    self:WithItemID(itemID, function(name, _, quality)
        if panel.selectedItemID ~= itemID then return end
        local q = self:QualityColor(quality)
        panel.markLabel:SetText(string.format(self.L["Mark — %s:"], name or ("item:" .. itemID)))
        panel.markLabel:SetTextColor(q[1], q[2], q[3])
    end)
    panel.list:Refresh() -- move the selection bar
end

local function ShowPhase(panel, phase)
    LCEX.browserPhase = phase
    for _, b in ipairs(panel.phaseButtons) do
        local fs = b:GetFontString()
        if fs then
            if b.phase == phase then
                fs:SetTextColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3])
            else
                fs:SetTextColor(LCEX.Theme.text.dim[1], LCEX.Theme.text.dim[2], LCEX.Theme.text.dim[3])
            end
        end
    end
    panel.list:SetData(LCEX:BuildBrowserDisplay(phase, LCEX.browserExpanded))
end

LCEX:RegisterCouncilModule({
    key = "browser", title = LCEX.L["Loot Browser"], order = 10,

    build = function(panel)
        -- Phase buttons across the top.
        panel.phaseButtons = {}
        local x = 8
        for _, p in ipairs(LCEX:GetLootPhases()) do
            local b = LCEX:CreateFlatButton(panel, p, 46, 20)
            b:SetPoint("TOPLEFT", x, -8)
            b.phase = p
            b:SetScript("OnClick", function() ShowPhase(panel, p) end)
            panel.phaseButtons[#panel.phaseButtons + 1] = b
            x = x + 50
        end

        -- The browse list fills the space between phase buttons and the mark editor.
        panel.list = LCEX:CreateScrollList(panel, {
            rowHeight = 22, fillHeight = true, zebra = true,
            buildRow = function() return BuildRow(panel) end,
            fillRow  = function(row, entry) FillRow(panel, row, entry) end,
        })
        panel.list:SetPoint("TOPLEFT", 4, -34)
        panel.list:SetPoint("BOTTOMRIGHT", -4, 40)

        -- Mark editor for the selected item.
        panel.markLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.markLabel, "caption", "dim")
        panel.markLabel:SetPoint("BOTTOMLEFT", 10, 22)
        panel.markLabel:SetText(LCEX.L["Mark — click an item:"])

        panel.markBox = LCEX:CreateEditBox(panel, {
            width = 320,
            onCommit = function(text)
                if panel.selectedItemID then
                    LCEX:SetMark(panel.selectedItemID, text)
                    panel.list:Refresh()
                end
            end,
        })
        panel.markBox:SetPoint("BOTTOMLEFT", 14, 2)
    end,

    show = function(panel)
        local phases = LCEX:GetLootPhases()
        ShowPhase(panel, LCEX.browserPhase or phases[1])
    end,
})
