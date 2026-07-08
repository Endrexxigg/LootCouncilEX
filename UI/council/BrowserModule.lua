-- ── LootCouncil EX — UI/council/BrowserModule.lua ────────────────────────────
-- Council module: the loot browser. Phase buttons across the top; one reflowing list where
-- raid headers read gold-on-raised bars, bosses indent below them, and items indent further
-- with QUALITY-COLORED names. Raid/boss headers fold (item 13, default collapsed, in-memory
-- state). Marks render inline as dim text with a note-icon indicator (item 14); they're edited
-- via the right-click "Leave note…" flow (item 17 — the shared confirm-with-input), never an
-- always-visible box. Mark commits go through SetMark (council-gated, broadcasts pSet).
--
-- Data: Core/Display.lua BuildBrowserDisplay(phase, expanded) → {kind=raid/boss/item} rows;
-- names/qualities resolve async through WithItemID. Loads after UI/CouncilWindow.lua.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

-- Tree indents: raid text sits at rowPad; bosses step in by inlineGap (their 14px fold glyph
-- then lands the label at ~28); items indent to 30 so their icons align under the boss LABELS.
local INDENT_BOSS, INDENT_ITEM = LAY.rowPad + LAY.inlineGap, 30

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
    row.mark:SetPoint("RIGHT", -LAY.rowPad, 0)
    row.mark:SetJustifyH("RIGHT")
    row.mark:SetWordWrap(false)

    -- Note indicator (item 14): a small note-glyph icon, shown only when a REAL user mark
    -- exists — icon-based so it can't be confused with item-quality name colors.
    row.noteIcon = row:CreateTexture(nil, "OVERLAY")
    row.noteIcon:SetSize(12, 12)
    row.noteIcon:SetTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
    row.noteIcon:SetPoint("RIGHT", row.mark, "LEFT", -LAY.gapTight, 0)
    row.noteIcon:Hide()

    -- Loot-priority indicator (§6.23): a small accent glyph when the item has a prio entry; the
    -- full chains ride the hover tooltip (below). Left of the note icon.
    row.prioGlyph = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.prioGlyph, "caption", "dim")
    row.prioGlyph:SetTextColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3])
    row.prioGlyph:SetText("◆")
    row.prioGlyph:SetPoint("RIGHT", row.noteIcon, "LEFT", -LAY.gapTight, 0)
    row.prioGlyph:Hide()

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(r, button)
        if r.itemID then
            if button == "RightButton" then
                LCEX:BrowserItemMenu(r.panel, r.itemID, r.itemLink) -- note flow (item 17)
            else
                LCEX:BrowserSelectItem(r.panel, r.itemID)
            end
        elseif r.toggleKey then
            LCEX:BrowserToggle(r.panel, r.kind, r.toggleKey) -- raid/boss headers fold (item 13)
        end
    end)
    -- Item tooltip on NAME hover, not just the icon (item 15). Header rows show nothing. The
    -- mark column truncates a long note, so the FULL note rides along under the item tooltip.
    row:SetScript("OnEnter", function(r)
        if r.kind ~= "item" or not r.itemID then return end
        GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(r.itemLink or ("item:" .. r.itemID))
        if LCEX:HasUserMark(r.itemID) and r.mark:IsTruncated() then
            local mark = LCEX:BrowserMarkText(r.itemID)
            if mark and mark ~= "" then
                GameTooltip:AddLine(" ")
                local d = LCEX.Theme.text.dim
                GameTooltip:AddLine(LCEX.L["Note:"], d[1], d[2], d[3])
                GameTooltip:AddLine(mark, 1, 1, 1, true) -- wrap the full text
            end
        end
        -- Loot priority (§6.23): one "Prio (label): A = B > C" pair per labeled chain.
        local prio = LCEX:GetPrioForItem(r.itemID)
        if prio then
            local d = LCEX.Theme.text.dim
            GameTooltip:AddLine(" ")
            for _, e in ipairs(prio) do
                GameTooltip:AddLine(string.format(LCEX.L["Prio (%s):"], tostring(e.label)), d[1], d[2], d[3])
                GameTooltip:AddLine(LCEX:PrioLine(e.chain), 1, 1, 1, true)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.panel = panel
    return row
end

local function FillRow(panel, row, entry)
    row.loadingID = nil
    row.itemID = nil
    row.itemLink = nil
    row.kind = entry.kind
    row.toggleKey = entry.key
    row.bg:Hide()
    row.sel:Hide()
    row.icon:Hide()
    row.noteIcon:Hide()
    row.prioGlyph:Hide()
    row.mark:SetText("")
    row.text:ClearAllPoints()

    local fold = (entry.kind == "raid" or entry.kind == "boss")
        and (entry.expanded and FOLD_OPEN or FOLD_CLOSED) or ""
    if entry.kind == "raid" then
        row.bg:Show()
        LCEX:ApplyGradient(row.bg, LCEX.Theme.tone.raised.top, LCEX.Theme.tone.raised.bottom)
        LCEX:ThemeText(row.text, "body", "ink")
        row.text:SetTextColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3])
        row.text:SetPoint("LEFT", LAY.rowPad, 0)
        row.text:SetPoint("RIGHT", -LAY.rowPad, 0)
        row.text:SetText(fold .. entry.text:upper())
    elseif entry.kind == "boss" then
        LCEX:ThemeText(row.text, "body", "ink")
        row.text:SetPoint("LEFT", INDENT_BOSS, 0)
        row.text:SetPoint("RIGHT", -LAY.rowPad, 0)
        row.text:SetText(fold .. entry.text)
    else -- item
        row.itemID = entry.itemID
        row.icon:Show()
        row.icon:SetPoint("LEFT", INDENT_ITEM, 0)
        local instantIcon = GetItemInfoInstant and select(5, GetItemInfoInstant(entry.itemID))
        row.icon:SetItem(nil, instantIcon)
        LCEX:ThemeText(row.text, "body", "dim")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", LAY.iconGap, 0)
        row.text:SetPoint("RIGHT", row.noteIcon, "LEFT", -LAY.inlineGap, 0)
        row.text:SetText("item:" .. entry.itemID)
        if LCEX:HasUserMark(entry.itemID) then row.noteIcon:Show() end
        if LCEX:GetPrioForItem(entry.itemID) then row.prioGlyph:Show() end

        local id = entry.itemID
        row.loadingID = id
        LCEX:WithItemID(id, function(name, link, quality)
            if row.loadingID ~= id then return end -- row reused while loading
            local q = LCEX:QualityColor(quality)
            row.text:SetText(name or ("item:" .. id))
            row.text:SetTextColor(q[1], q[2], q[3])
            row.icon:SetItem(link, instantIcon)
            row.itemLink = link -- the row-hover tooltip prefers the resolved link
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

-- Click-to-select: moves the selection bar (the note editor is the right-click flow below).
function LCEX:BrowserSelectItem(panel, itemID)
    panel.selectedItemID = itemID
    panel.list:Refresh() -- move the selection bar
end

-- Right-click note flow (item 17) — replaces the old always-visible bottom mark box. "Leave
-- note…" opens the shared confirm-with-input as a compact editor pre-filled with the current
-- mark; "Clear note" appears only when one exists. Commits still route through SetMark
-- (council-gated, broadcasts pSet); clearing writes text="" so the clear replicates (LWW).
function LCEX:BrowserItemMenu(panel, itemID, link)
    self:BrowserSelectItem(panel, itemID)
    local label = (link and link:match("%[(.-)%]")) or ("item:" .. itemID)
    local items = {
        { text = self.L["Leave note…"], onClick = function()
            self:ShowConfirm({
                text = string.format(self.L["Note for %s:"], label),
                input = self:BrowserMarkText(itemID),
                accept = self.L["Save"],
                onAccept = function(text)
                    self:SetMark(itemID, strtrim(text or ""))
                    panel.list:Refresh()
                end,
            })
        end },
    }
    if self:HasUserMark(itemID) then
        items[#items + 1] = { text = self.L["Clear note"], danger = true, onClick = function()
            self:SetMark(itemID, "")
            panel.list:Refresh()
        end }
    end
    self:ShowContextMenu({ title = label, items = items })
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
        -- Phase buttons across the top, on the panel's grid line.
        panel.phaseButtons = {}
        local x = LAY.grid
        for _, p in ipairs(LCEX:GetLootPhases()) do
            local b = LCEX:CreateFlatButton(panel, p, 46, LAY.btnHSlim)
            b:SetPoint("TOPLEFT", x, -LAY.gap)
            b.phase = p
            b:SetScript("OnClick", function() ShowPhase(panel, p) end)
            panel.phaseButtons[#panel.phaseButtons + 1] = b
            x = x + 46 + LAY.tabGap
        end

        -- The browse list fills everything below the phase buttons — the old always-visible
        -- mark editor is gone; notes are edited via the right-click menu (item 17). Full-bleed
        -- band: bleed insets, rowPad-inside rows, so row text lands back on the grid line.
        panel.list = LCEX:CreateScrollList(panel, {
            rowHeight = 22, fillHeight = true, zebra = true,
            buildRow = function() return BuildRow(panel) end,
            fillRow  = function(row, entry) FillRow(panel, row, entry) end,
        })
        panel.list:SetPoint("TOPLEFT", LAY.bleed, -(LAY.gap + LAY.btnHSlim + LAY.gap))
        panel.list:SetPoint("BOTTOMRIGHT", -LAY.bleed, LAY.bleed)
    end,

    show = function(panel)
        local phases = LCEX:GetLootPhases()
        ShowPhase(panel, LCEX.browserPhase or phases[1])
    end,
})
