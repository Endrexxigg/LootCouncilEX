-- ── LootCouncil EX — UI/Widgets.lua ──────────────────────────────────────────
-- Native-frame style layer + factory. NO AceGUI (PROJECT.md §2): every frame in the addon
-- is a CreateFrame built through these helpers, so the look stays consistent and the TBC
-- gotchas live in one place — explicit Show()/Hide() (SetShown is retail-only) and ESC-close
-- via UISpecialFrames.
--
-- Loads before the frame modules (LootFrame/VotingFrame/SessionFrame) that build on it.

local LCEX = LootCouncilEX

-- Shared style tokens — one source of truth for metrics/colors so frames match.
LCEX.STYLE = {
    backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    },
    pad       = 14,
    rowHeight = 30,
}

-- Create a movable, ESC-closable titled window. `name` is the GLOBAL frame name (required
-- for UISpecialFrames). `opts` = { width, height, title, savedKey, defaultPos }. savedKey,
-- if given, persists the window position into db.profile.ui[savedKey]. defaultPos = {x, y}
-- offsets the first-run CENTER anchor so paired windows (Respond/Council) don't spawn
-- stacked; a saved position always wins over it.
function LCEX:CreateWindow(name, opts)
    opts = opts or {}
    local addon = self

    -- Guarded template (Gargul's pattern): if BackdropTemplate is ever absent, pass nil and
    -- skip the backdrop rather than erroring out of CreateFrame.
    local f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(opts.width or 360, opts.height or 280)
    local def = opts.defaultPos
    f:SetPoint("CENTER", UIParent, "CENTER", (def and def.x) or 0, (def and def.y) or 0)
    f:SetFrameStrata("DIALOG")
    if f.SetBackdrop then f:SetBackdrop(self.STYLE.backdrop) end
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self2)
        self2:StopMovingOrSizing()
        if opts.savedKey and addon.db then
            local p = addon.db.profile.ui[opts.savedKey]
            if p then
                local point, _, relPoint, x, y = self2:GetPoint()
                p.point, p.relPoint, p.x, p.y = point, relPoint, x, y
            end
        end
    end)

    -- Restore a saved position.
    if opts.savedKey and self.db then
        local p = self.db.profile.ui[opts.savedKey]
        if p and p.point then
            f:ClearAllPoints()
            f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
        end
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText(opts.title or "")
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    f.closeButton = close

    tinsert(UISpecialFrames, name) -- ESC closes it
    f:Hide()
    return f
end

-- A standard push button.
function LCEX:CreateButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 80, height or 22)
    b:SetText(text or "")
    return b
end

-- A FontString label on `parent`.
function LCEX:CreateLabel(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    if text then fs:SetText(text) end
    return fs
end

-- A small item-icon button that shows the item tooltip on hover. :SetItem(link, icon).
function LCEX:CreateItemIcon(parent, size)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size or 24, size or 24)
    btn.tex = btn:CreateTexture(nil, "ARTWORK")
    btn.tex:SetAllPoints()
    btn.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn:SetScript("OnEnter", function(self2)
        if self2.itemLink then
            GameTooltip:SetOwner(self2, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self2.itemLink)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function btn.SetItem(iconBtn, link, icon)
        iconBtn.itemLink = link
        iconBtn.tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
    return btn
end

-- ── Tab strip ────────────────────────────────────────────────────────────────
-- Pure tab-state transition, factored out so the active-key logic is headless-testable.
-- `state` = { active, valid={key=true} }. Selecting a valid key makes it active; an unknown
-- key is a no-op (keeps the current active). Returns the active key.
function LCEX:_TabSelect(state, key)
    if state.valid[key] then state.active = key end
    return state.active
end

-- A row of toggle buttons. `tabs` = { {key, text}, ... }. `onSelect(key)` fires on every
-- Select (incl. programmatic). `strip:Select(key)` highlights the active and calls onSelect.
-- Reused for PlayerDetail's content tabs and LootBrowser's phase tabs.
function LCEX:CreateTabStrip(parent, tabs, onSelect)
    local addon = self
    local strip = CreateFrame("Frame", nil, parent)
    strip.buttons = {}
    strip.state = { active = nil, valid = {} }

    local x = 0
    for _, t in ipairs(tabs) do
        strip.state.valid[t.key] = true
        local b = self:CreateButton(strip, t.text, math.max(56, #t.text * 8 + 16), 22)
        b:SetPoint("LEFT", x, 0)
        b.tabKey = t.key
        b:SetScript("OnClick", function() strip:Select(t.key) end)
        strip.buttons[#strip.buttons + 1] = b
        x = x + b:GetWidth() + 2
    end
    strip:SetSize(math.max(1, x), 24)

    function strip.Select(s, key)
        local active = addon:_TabSelect(s.state, key)
        for _, b in ipairs(s.buttons) do
            if b.tabKey == active then b:LockHighlight() else b:UnlockHighlight() end
        end
        if onSelect then onSelect(active) end
        return active
    end
    return strip
end

-- ── Scroll list (FauxScrollFrame) ────────────────────────────────────────────
-- A virtualized list: a fixed pool of `visibleRows` rows re-filled from a windowed slice of the
-- backing data as the user scrolls. `opts = { rowHeight, visibleRows, width, buildRow(list)->row,
-- fillRow(row, item, index) }`. The ONLY way to set data is `list:SetData(items)`, which resets
-- the scroll offset first — so a stale offset from a longer previous list can never render the
-- new (shorter) list empty (the classic FauxScrollFrame bug, CLAUDE.md).
function LCEX:CreateScrollList(parent, opts)
    local rowHeight   = opts.rowHeight or self.STYLE.rowHeight
    local visibleRows = opts.visibleRows or 10
    local width       = opts.width or 320

    local list = CreateFrame("Frame", nil, parent)
    list:SetSize(width, visibleRows * rowHeight)
    list.rows, list.items = {}, {}

    local sf = CreateFrame("ScrollFrame", nil, list, "FauxScrollFrameTemplate")
    sf:SetAllPoints(list)
    list.scroll = sf

    local function Refresh()
        FauxScrollFrame_Update(sf, #list.items, visibleRows, rowHeight)
        local offset = FauxScrollFrame_GetOffset(sf)
        for i = 1, visibleRows do
            local row = list.rows[i]
            if not row then
                row = opts.buildRow(list)
                row:SetHeight(rowHeight)
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -24, -(i - 1) * rowHeight) -- scrollbar gap
                list.rows[i] = row
            end
            local item = list.items[offset + i]
            if item then
                opts.fillRow(row, item, offset + i)
                row:Show()
            else
                row:Hide()
            end
        end
    end
    list.Refresh = Refresh

    sf:SetScript("OnVerticalScroll", function(self2, delta)
        FauxScrollFrame_OnVerticalScroll(self2, delta, rowHeight, Refresh)
    end)

    function list.SetData(l, items)
        l.items = items or {}
        l.scroll.offset = 0              -- the load-bearing reset
        l.scroll:SetVerticalScroll(0)
        Refresh()
    end
    return list
end

-- ── Edit box ─────────────────────────────────────────────────────────────────
-- A single-line input (generalizes LootFrame's note box). `opts = { width, onCommit(text) }`.
-- Enter commits (then unfocuses); Escape unfocuses. Commits should route through SetRecord.
function LCEX:CreateEditBox(parent, opts)
    opts = opts or {}
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(opts.width or 200, 20)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self2) self2:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self2)
        if opts.onCommit then opts.onCommit(self2:GetText()) end
        self2:ClearFocus()
    end)
    return eb
end
