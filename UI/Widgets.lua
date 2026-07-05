-- ── LootCouncil EX — UI/Widgets.lua ──────────────────────────────────────────
-- Native-frame style layer + factory. NO AceGUI (PROJECT.md §2): every frame in the addon
-- is a CreateFrame built through these helpers, so the look stays consistent and the TBC
-- gotchas live in one place — explicit Show()/Hide() (SetShown is retail-only) and ESC-close
-- via UISpecialFrames.
--
-- Loads before the frame modules (LootFrame/VotingFrame/SessionFrame) that build on it.

local LCEX = LootCouncilEX

-- Shared metrics (the theme's colors/fonts live in UI/Theme.lua).
LCEX.STYLE = {
    rowHeight = 30,
}

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
    -- Optional stack-count overlay (Feature B "xN"): outlined white, bottom-right. Hidden unless > 1.
    btn.count = btn:CreateFontString(nil, "OVERLAY")
    btn.count:SetFont(self.Theme.font, 10, "OUTLINE")
    btn.count:SetTextColor(1, 1, 1)
    btn.count:SetPoint("BOTTOMRIGHT", -1, 1)
    btn.count:Hide()
    function btn.SetCount(iconBtn, n)
        if n and n > 1 then iconBtn.count:SetText("x" .. n); iconBtn.count:Show()
        else iconBtn.count:Hide() end
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

-- ── Scroll list (FauxScrollFrame) ────────────────────────────────────────────
-- A virtualized list: a fixed pool of `visibleRows` rows re-filled from a windowed slice of the
-- backing data as the user scrolls. `opts = { rowHeight, visibleRows, width, buildRow(list)->row,
-- fillRow(row, item, index), fillHeight }`. The ONLY way to set data is `list:SetData(items)`,
-- which resets the scroll offset first — so a stale offset from a longer previous list can never
-- render the new (shorter) list empty (the classic FauxScrollFrame bug, CLAUDE.md).
-- With `fillHeight = true` the list reflows for a RESIZABLE parent: anchor its top/bottom edges
-- and the visible row count recomputes from the live height (rows are pooled and built lazily).
function LCEX:CreateScrollList(parent, opts)
    local rowHeight = opts.rowHeight or self.STYLE.rowHeight
    local width     = opts.width or 320

    local list = CreateFrame("Frame", nil, parent)
    list.visibleRows = opts.visibleRows or 10
    list:SetSize(width, list.visibleRows * rowHeight)
    list.rows, list.items = {}, {}

    local sf = CreateFrame("ScrollFrame", nil, list, "FauxScrollFrameTemplate")
    sf:SetAllPoints(list)
    list.scroll = sf

    -- The template anchors its scrollbar OUTSIDE the scrollframe's right edge, so a list flush
    -- against a panel border renders its bar across the divider (handoff items 12/18). Re-anchor
    -- it INSIDE the list, in the 24px gutter the rows already leave free. `sf.ScrollBar` is the
    -- template's parentKey; the Slider-child scan covers a client where only the name differs.
    local bar = sf.ScrollBar
    if not bar then
        for _, child in ipairs({ sf:GetChildren() }) do
            if child:IsObjectType("Slider") then bar = child; break end
        end
    end
    if bar then
        bar:ClearAllPoints()
        -- ±16 leaves room for the template's up/down arrows, which hang off the slider's ends.
        bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", -2, -16)
        bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -2, 16)
    end
    list.scrollBar = bar

    local function Refresh()
        FauxScrollFrame_Update(sf, #list.items, list.visibleRows, rowHeight)
        local offset = FauxScrollFrame_GetOffset(sf)
        for i = 1, list.visibleRows do
            local row = list.rows[i]
            if not row then
                row = opts.buildRow(list)
                row:SetHeight(rowHeight)
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -24, -(i - 1) * rowHeight) -- scrollbar gap
                if opts.zebra then
                    -- Shared zebra layer (DL-23): BACKGROUND sublevel 1 sits above a row's
                    -- Surface gradient (sublevel 0) and below ARTWORK selection bars, so the
                    -- select/hover re-tinting the modules already do repaints underneath it.
                    row._stripe = row:CreateTexture(nil, "BACKGROUND", nil, 1)
                    row._stripe:SetAllPoints(row)
                    row._stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
                    local s = self.Theme.stripe
                    row._stripe:SetVertexColor(s[1], s[2], s[3], s[4])
                end
                list.rows[i] = row
            end
            local item = list.items[offset + i]
            if item then
                opts.fillRow(row, item, offset + i)
                -- Stripe by ABSOLUTE index parity so stripes don't swim while scrolling.
                if row._stripe then
                    if (offset + i) % 2 == 0 then row._stripe:Show() else row._stripe:Hide() end
                end
                row:Show()
            else
                row:Hide()
            end
        end
        -- Rows beyond the (possibly shrunken) window stay pooled but hidden.
        for i = list.visibleRows + 1, #list.rows do
            list.rows[i]:Hide()
        end
    end
    list.Refresh = Refresh

    sf:SetScript("OnVerticalScroll", function(self2, delta)
        FauxScrollFrame_OnVerticalScroll(self2, delta, rowHeight, Refresh)
    end)

    if opts.fillHeight then
        list:SetScript("OnSizeChanged", function(l, _, height)
            local rows = math.max(1, math.floor((height or l:GetHeight() or 0) / rowHeight))
            if rows ~= l.visibleRows then
                l.visibleRows = rows
                Refresh()
            end
        end)
    end

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

-- ═════════════════════════════════════════════════════════════════════════════
-- Widgets v2 — the themed primitives for the four-frame UI (UI/Theme.lua). The v1 factories
-- above remain until the last legacy frame is replaced, then they retire.
-- ═════════════════════════════════════════════════════════════════════════════

-- Persist a v2 window's placement into db.profile.ui[savedKey] (creates the subtable — new
-- keys need no DB_DEFAULTS entry). Size is saved only for resizable windows.
local function SavePlacement(addon, f, savedKey, resizable)
    if not (savedKey and addon.db) then return end
    local p = addon.db.profile.ui[savedKey]
    if not p then p = {}; addon.db.profile.ui[savedKey] = p end
    local point, _, relPoint, x, y = f:GetPoint()
    p.point, p.relPoint, p.x, p.y = point, relPoint, x, y
    if resizable then p.w, p.h = f:GetWidth(), f:GetHeight() end
end

-- ── Window v2 ────────────────────────────────────────────────────────────────
-- Themed, movable, ESC-closable window. `name` is the GLOBAL frame name (UISpecialFrames).
-- opts = { width, height, title, savedKey, defaultPos={x,y}, resizable, minW, minH,
--          useOpacity } — savedKey persists position (and size when resizable); useOpacity
-- windows honor profile.appearance.opacity. Returns the frame; content anchors below f.bar.
function LCEX:CreateWindowV2(name, opts)
    opts = opts or {}
    local addon = self

    local f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(opts.width or 420, opts.height or 320)
    local def = opts.defaultPos
    f:SetPoint("CENTER", UIParent, "CENTER", (def and def.x) or 0, (def and def.y) or 0)
    f:SetFrameStrata(opts.strata or "DIALOG")
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    -- Bring a window to the front of its strata whenever it's shown or clicked, so overlapping
    -- LCEX windows (all DIALOG) stop hiding under each other. Modal popups pass a higher strata.
    f:HookScript("OnShow", function(w) w:Raise() end)
    f:SetScript("OnMouseDown", function(w) w:Raise() end)
    self:Surface(f, "page")
    self:SoftEdge(f)

    -- Title bar: the drag handle. A 3px gold tick + title text; close × on the right.
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", 2, -2)
    bar:SetPoint("TOPRIGHT", -2, -2)
    bar:SetHeight(28)
    self:Surface(bar, "raised")
    f.bar = bar

    local tick = bar:CreateTexture(nil, "ARTWORK")
    tick:SetTexture("Interface\\Buttons\\WHITE8X8")
    tick:SetSize(3, 14)
    tick:SetPoint("LEFT", 10, 0)
    tick:SetVertexColor(self.Theme.accent[1], self.Theme.accent[2], self.Theme.accent[3], 1)

    local title = bar:CreateFontString(nil, "OVERLAY")
    self:ThemeText(title, "section", "ink")
    title:SetPoint("LEFT", tick, "RIGHT", 8, 0)
    title:SetText(opts.title or "")
    f.title = title

    f:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnMouseDown", function() f:Raise() end) -- the bar captures the click, so raise here too
    bar:SetScript("OnDragStart", function() f:Raise(); f:StartMoving() end)
    bar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SavePlacement(addon, f, opts.savedKey, opts.resizable)
    end)

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(22, 22)
    close:SetPoint("RIGHT", -4, 0)
    close.fs = close:CreateFontString(nil, "OVERLAY")
    addon:ThemeText(close.fs, "section", "dim")
    close.fs:SetPoint("CENTER", 0, 0)
    close.fs:SetText("×")
    close:SetScript("OnEnter", function(b)
        b.fs:SetTextColor(addon.Theme.danger[1], addon.Theme.danger[2], addon.Theme.danger[3])
    end)
    close:SetScript("OnLeave", function(b) addon:ThemeText(b.fs, "section", "dim") end)
    close:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = close

    -- Resizable: bottom-right grip with the stuck-sizing guard (grip mouse-up alone can miss
    -- when the cursor leaves the grip — also stop on the frame's own mouse-up and on hide).
    if opts.resizable then
        f:SetResizable(true)
        local minW, minH = opts.minW or 480, opts.minH or 320
        if f.SetResizeBounds then f:SetResizeBounds(minW, minH)
        elseif f.SetMinResize then f:SetMinResize(minW, minH) end

        local grip = CreateFrame("Button", nil, f)
        grip:SetSize(16, 16)
        grip:SetPoint("BOTTOMRIGHT", -3, 3)
        grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        local function stopSizing()
            if f._sizing then
                f._sizing = false
                f:StopMovingOrSizing()
                SavePlacement(addon, f, opts.savedKey, true)
            end
        end
        grip:SetScript("OnMouseDown", function() f._sizing = true; f:StartSizing("BOTTOMRIGHT") end)
        grip:SetScript("OnMouseUp", stopSizing)
        f:HookScript("OnMouseUp", stopSizing)
        f:HookScript("OnHide", stopSizing)
        f.resizeGrip = grip
    end

    -- Restore saved placement (position always; size only when resizable).
    if opts.savedKey and self.db then
        local p = self.db.profile.ui[opts.savedKey]
        if p and p.point then
            f:ClearAllPoints()
            f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
        end
        if opts.resizable and p and p.w and p.h then
            f:SetSize(p.w, p.h)
        end
    end

    -- Appearance plumbing (Config window writes profile.appearance; nil-safe before then).
    function f.RefreshAppearance(win)
        local a = addon.db and addon.db.profile.appearance
        win:SetScale((a and a.scale) or 1)
        if opts.useOpacity then win:SetAlpha((a and a.opacity) or 1) end
    end
    f:RefreshAppearance()

    if not opts.noEscClose then
        tinsert(UISpecialFrames, name) -- ESC closes it (opt out for passive windows, e.g. trade timers)
    end
    f:Hide()
    return f
end

-- ── Flat button ──────────────────────────────────────────────────────────────
-- Themed push button. `variant` = nil (neutral) | "accent" | "danger" — tints border + text.
-- Native SetText/GetText work (the font string is attached via SetFontString).
function LCEX:CreateFlatButton(parent, text, width, height, variant)
    local addon = self
    local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    b:SetSize(width or 90, height or 22)
    self:Surface(b, "overlay")
    if b.SetBackdrop then
        b:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    end

    local edge = { 0, 0, 0, 0.9 }
    local textTone = "ink"
    if variant == "accent" then
        edge = { addon.Theme.accent[1], addon.Theme.accent[2], addon.Theme.accent[3], 0.7 }
    elseif variant == "danger" then
        edge = { addon.Theme.danger[1], addon.Theme.danger[2], addon.Theme.danger[3], 0.7 }
        textTone = "dim"
    end
    if b.SetBackdropBorderColor then b:SetBackdropBorderColor(edge[1], edge[2], edge[3], edge[4]) end

    local fs = b:CreateFontString(nil, "OVERLAY")
    self:ThemeText(fs, "body", textTone)
    fs:SetPoint("CENTER", 0, 0)
    b:SetFontString(fs)
    b:SetText(text or "")
    b:SetPushedTextOffset(0, -1)

    b:SetScript("OnEnter", function(btn)
        if not btn._flatDisabled then addon:Surface(btn, "float") end
    end)
    b:SetScript("OnLeave", function(btn)
        if not btn._flatDisabled then addon:Surface(btn, "overlay") end
    end)

    -- Disabled state (Phase 12, DL-23): dim the text/border and stop hover re-tinting. Named
    -- SetFlatEnabled so the native Button:SetEnabled stays untouched. Re-enabling restores the
    -- variant's own edge color and text tone.
    b._edge, b._textTone = edge, textTone
    function b.SetFlatEnabled(btn, on)
        if on then
            btn._flatDisabled = nil
            btn:Enable()
            addon:ThemeText(fs, "body", btn._textTone)
            if btn.SetBackdropBorderColor then
                btn:SetBackdropBorderColor(btn._edge[1], btn._edge[2], btn._edge[3], btn._edge[4])
            end
            addon:Surface(btn, "overlay")
        else
            btn._flatDisabled = true
            btn:Disable()
            addon:ThemeText(fs, "body", "faint")
            if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0, 0, 0, 0.4) end
            addon:Surface(btn, "base")
        end
    end
    return b
end

-- ── Left nav rail ────────────────────────────────────────────────────────────
-- Vertical module tabs for the council window. opts = { width, onSelect(key) }. Items are
-- added with rail:AddItem(key, text) (order of addition = display order); rail:Select(key)
-- drives the gold selection bar + onSelect. Reuses _TabSelect for the active-key logic.
function LCEX:CreateNavRail(parent, opts)
    opts = opts or {}
    local addon = self
    local rail = CreateFrame("Frame", nil, parent)
    rail:SetWidth(opts.width or 170)
    self:Surface(rail, "base")
    rail.items = {}
    rail.state = { active = nil, valid = {} }

    local ROW_H = 26
    function rail.AddItem(r, key, text)
        r.state.valid[key] = true
        local row = CreateFrame("Button", nil, r)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 0, -(#r.items) * ROW_H - 6)
        row:SetPoint("TOPRIGHT", 0, -(#r.items) * ROW_H - 6)
        addon:Surface(row, "base")

        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.bar:SetWidth(2)
        row.bar:SetPoint("TOPLEFT", 0, 0)
        row.bar:SetPoint("BOTTOMLEFT", 0, 0)
        row.bar:SetVertexColor(addon.Theme.accent[1], addon.Theme.accent[2], addon.Theme.accent[3], 1)
        row.bar:Hide()

        row.fs = row:CreateFontString(nil, "OVERLAY")
        addon:ThemeText(row.fs, "body", "dim")
        row.fs:SetPoint("LEFT", 14, 0)
        row.fs:SetText(text)

        row.key = key
        row:SetScript("OnClick", function() r:Select(key) end)
        row:SetScript("OnEnter", function(rw)
            if r.state.active ~= rw.key then addon:Surface(rw, "raised") end
        end)
        row:SetScript("OnLeave", function(rw)
            if r.state.active ~= rw.key then addon:Surface(rw, "base") end
        end)
        r.items[#r.items + 1] = row
        return row
    end

    function rail.Select(r, key)
        local active = addon:_TabSelect(r.state, key)
        for _, row in ipairs(r.items) do
            if row.key == active then
                addon:Surface(row, "overlay")
                row.bar:Show()
                addon:ThemeText(row.fs, "body", "ink")
            else
                addon:Surface(row, "base")
                row.bar:Hide()
                addon:ThemeText(row.fs, "body", "dim")
            end
        end
        if opts.onSelect then opts.onSelect(active) end
        return active
    end
    return rail
end

-- ── Checkbox ─────────────────────────────────────────────────────────────────
-- Flat checkbox bound to get/set closures. cb:Refresh() re-reads the value.
function LCEX:CreateCheckbox(parent, label, get, set)
    local addon = self
    local cb = CreateFrame("Button", nil, parent)
    cb:SetHeight(20)

    local box = CreateFrame("Frame", nil, cb, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    self:Surface(box, "overlay")
    if box.SetBackdrop then
        box:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        box:SetBackdropBorderColor(0, 0, 0, 0.9)
    end
    cb.tick = box:CreateTexture(nil, "OVERLAY")
    cb.tick:SetTexture("Interface\\Buttons\\WHITE8X8")
    cb.tick:SetSize(8, 8)
    cb.tick:SetPoint("CENTER", 0, 0)
    cb.tick:SetVertexColor(addon.Theme.accent[1], addon.Theme.accent[2], addon.Theme.accent[3], 1)

    cb.fs = cb:CreateFontString(nil, "OVERLAY")
    self:ThemeText(cb.fs, "body", "ink")
    cb.fs:SetPoint("LEFT", box, "RIGHT", 8, 0)
    cb.fs:SetText(label or "")
    cb:SetWidth(24 + cb.fs:GetStringWidth() + 8)

    function cb.Refresh(c)
        if get() then c.tick:Show() else c.tick:Hide() end
    end
    cb:SetScript("OnClick", function(c)
        set(not get())
        c:Refresh()
    end)
    cb:Refresh()
    return cb
end

-- ── Slider v2 ────────────────────────────────────────────────────────────────
-- Flat labeled slider bound to get/set. opts = { width, min, max, step, label, fmt(v)->str }.
-- Values quantize to `step` in OnValueChanged (SetObeyStepOnDrag is not classic-safe).
function LCEX:CreateSliderV2(parent, opts)
    local addon = self
    local wrap = CreateFrame("Frame", nil, parent)
    wrap:SetSize(opts.width or 200, 34)

    wrap.label = wrap:CreateFontString(nil, "OVERLAY")
    self:ThemeText(wrap.label, "caption", "dim")
    wrap.label:SetPoint("TOPLEFT", 0, 0)
    wrap.label:SetText(opts.label or "")

    wrap.value = wrap:CreateFontString(nil, "OVERLAY")
    self:ThemeText(wrap.value, "caption", "ink")
    wrap.value:SetPoint("TOPRIGHT", 0, 0)

    local s = CreateFrame("Slider", nil, wrap, BackdropTemplateMixin and "BackdropTemplate" or nil)
    s:SetOrientation("HORIZONTAL")
    s:SetPoint("BOTTOMLEFT", 0, 0)
    s:SetPoint("BOTTOMRIGHT", 0, 0)
    s:SetHeight(14)
    self:Surface(s, "overlay")
    if s.SetBackdrop then
        s:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        s:SetBackdropBorderColor(0, 0, 0, 0.9)
    end
    s:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = s:GetThumbTexture()
    thumb:SetSize(10, 14)
    thumb:SetVertexColor(addon.Theme.accent[1], addon.Theme.accent[2], addon.Theme.accent[3], 1)
    s:SetMinMaxValues(opts.min or 0, opts.max or 1)
    s:EnableMouse(true)
    wrap.slider = s

    local step = opts.step or 0.05
    local function fmt(v) return opts.fmt and opts.fmt(v) or string.format("%.2f", v) end
    local settingUp = false

    local function apply(v)
        v = math.floor(v / step + 0.5) * step
        wrap.value:SetText(fmt(v))
        return v
    end
    s:SetScript("OnValueChanged", function(_, v)
        if settingUp then return end
        opts.set(apply(v))
    end)

    function wrap.Refresh(w)
        settingUp = true
        local v = opts.get()
        w.slider:SetValue(v)
        w.value:SetText(fmt(v))
        settingUp = false
    end
    wrap:Refresh()
    return wrap
end

-- ── Confirm popup ────────────────────────────────────────────────────────────
-- A small centered modal-ish confirm (Feature V's D/E send; reused by Feature C's inherit prompt).
-- One reused frame on the DIALOG strata, ESC / × / cancel all dismiss. `opts`:
--   text      — the prompt line(s)
--   input     — if a string, show an edit box pre-filled with it; onAccept receives its text
--                (the manual-target path); omit for a plain Yes/No
--   accept    — accept button label (default "Yes"); cancel is always "No"
--   onAccept  — function(inputText|nil) called when the user confirms
--   onCancel  — function() called when the user declines (No / × / ESC — any non-accept dismiss)
function LCEX:ShowConfirm(opts)
    opts = opts or {}
    local f = self._confirmFrame
    if not f then
        -- FULLSCREEN_DIALOG so the modal-ish confirm (e.g. the browser Leave-note editor) always
        -- sits ABOVE the DIALOG-strata windows it's launched from, instead of clipping under them.
        f = self:CreateWindowV2("LCEX_Confirm",
            { width = 360, height = 150, title = self.L["Confirm"], strata = "FULLSCREEN_DIALOG" })

        f.msg = f:CreateFontString(nil, "OVERLAY")
        self:ThemeText(f.msg, "body", "ink")
        f.msg:SetPoint("TOPLEFT", 16, -40)
        f.msg:SetPoint("TOPRIGHT", -16, -40)
        f.msg:SetJustifyH("LEFT"); f.msg:SetWordWrap(true)

        f.input = self:CreateEditBox(f, {
            width = 320,
            onCommit = function() f.acceptBtn:Click() end, -- Enter in the box = confirm
        })
        f.input:SetPoint("TOPLEFT", 18, -86)

        f.acceptBtn = self:CreateFlatButton(f, self.L["Yes"], 90, 24, "accent")
        f.acceptBtn:SetPoint("BOTTOMRIGHT", -14, 12)
        f.cancelBtn = self:CreateFlatButton(f, self.L["No"], 90, 24)
        f.cancelBtn:SetPoint("BOTTOMRIGHT", f.acceptBtn, "BOTTOMLEFT", -8, 0)
        f.cancelBtn:SetScript("OnClick", function() f:Hide() end)
        -- Any dismiss that isn't the accept button (No / × / ESC) counts as cancel — onHide fires the
        -- cancel callback unless accept already ran. Guarded so accept's own Hide() doesn't double-fire.
        f:SetScript("OnHide", function()
            if not f._accepted and f._onCancel then f._onCancel() end
            f._accepted = false
        end)

        self._confirmFrame = f
    end

    f.msg:SetText(opts.text or "")
    f.acceptBtn:GetFontString():SetText(opts.accept or self.L["Yes"])
    f._onCancel = opts.onCancel
    f._accepted = false
    local hasInput = type(opts.input) == "string"
    if hasInput then
        f.input:SetText(opts.input)
        f.input:Show()
    else
        f.input:Hide()
    end

    local onAccept = opts.onAccept
    f.acceptBtn:SetScript("OnClick", function()
        local val = hasInput and f.input:GetText() or nil
        f._accepted = true
        f:Hide()
        if onAccept then onAccept(val) end
    end)

    f:Show()
    if hasInput then f.input:SetFocus() end
    return f
end

-- ── Context menu ─────────────────────────────────────────────────────────────
-- A small themed right-click menu (Phase 12, DL-23) — native frames, no UIDropDownMenu. One
-- reused frame plus a fullscreen click-catcher one level beneath it, so any click-away closes;
-- ESC closes via UISpecialFrames. Rows rebuild on every show, so dynamic item lists (per-copy
-- un-award entries, note flows) are first-class. `opts`:
--   anchor — "cursor" (default) or a frame to hang TOPLEFT-under
--   title  — optional non-interactive caption row
--   items  — { { text, disabled=bool, danger=bool, onClick=function() end }, ... }
-- Consumers: browser leave-note flow, award correction, trade-timer rows.
local MENU_ROW_H = 20
function LCEX:ShowContextMenu(opts)
    opts = opts or {}
    local addon = self
    local menu = self._contextMenu
    if not menu then
        -- Click-catcher: swallows the click that lands anywhere off the menu and closes it.
        local catcher = CreateFrame("Frame", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("FULLSCREEN_DIALOG")
        catcher:EnableMouse(true)
        catcher:SetScript("OnMouseDown", function() addon:HideContextMenu() end)
        catcher:Hide()

        menu = CreateFrame("Frame", "LCEX_ContextMenu", UIParent,
            BackdropTemplateMixin and "BackdropTemplate" or nil)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameLevel(catcher:GetFrameLevel() + 10)
        menu:SetClampedToScreen(true)
        self:Surface(menu, "float")
        self:SoftEdge(menu)
        menu.catcher = catcher
        menu.rows = {}

        menu.title = menu:CreateFontString(nil, "OVERLAY")
        self:ThemeText(menu.title, "caption", "faint")
        menu.title:SetPoint("TOPLEFT", 10, -6)

        menu:SetScript("OnHide", function() catcher:Hide() end)
        tinsert(UISpecialFrames, "LCEX_ContextMenu")
        self._contextMenu = menu
    end

    local items = opts.items or {}
    local top = 4
    if opts.title and opts.title ~= "" then
        menu.title:SetText(opts.title)
        menu.title:Show()
        top = 22
    else
        menu.title:Hide()
    end

    local width = menu.title:IsShown() and (menu.title:GetStringWidth() + 20) or 0
    for i, it in ipairs(items) do
        local row = menu.rows[i]
        if not row then
            row = CreateFrame("Button", nil, menu)
            row:SetHeight(MENU_ROW_H)
            row.hl = row:CreateTexture(nil, "ARTWORK")
            row.hl:SetAllPoints(row)
            row.hl:SetTexture("Interface\\Buttons\\WHITE8X8")
            row.hl:SetVertexColor(1, 1, 1, 0.06)
            row.hl:Hide()
            row.fs = row:CreateFontString(nil, "OVERLAY")
            addon:ThemeText(row.fs, "body", "ink") -- set a font at BUILD time: SetText below errors otherwise
            row.fs:SetPoint("LEFT", 10, 0)
            row.fs:SetJustifyH("LEFT")
            row:SetScript("OnEnter", function(r) if not r._off then r.hl:Show() end end)
            row:SetScript("OnLeave", function(r) r.hl:Hide() end)
            row:SetScript("OnClick", function(r)
                if r._off then return end
                addon:HideContextMenu()
                if r._onClick then r._onClick() end
            end)
            menu.rows[i] = row
        end
        row:SetPoint("TOPLEFT", 2, -(top + (i - 1) * MENU_ROW_H))
        row:SetPoint("TOPRIGHT", -2, -(top + (i - 1) * MENU_ROW_H))
        row.fs:SetText(it.text or "")
        if it.disabled then
            self:ThemeText(row.fs, "body", "faint")
        elseif it.danger then
            self:ThemeText(row.fs, "body", "ink")
            row.fs:SetTextColor(self.Theme.danger[1], self.Theme.danger[2], self.Theme.danger[3])
        else
            self:ThemeText(row.fs, "body", "ink")
        end
        row._off = it.disabled and true or nil
        row._onClick = it.onClick
        row:Show()
        local w = row.fs:GetStringWidth() + 24
        if w > width then width = w end
    end
    for i = #items + 1, #menu.rows do menu.rows[i]:Hide() end

    menu:SetSize(math.max(120, width), top + #items * MENU_ROW_H + 6)

    menu:ClearAllPoints()
    if opts.anchor and opts.anchor ~= "cursor" then
        menu:SetPoint("TOPLEFT", opts.anchor, "BOTTOMLEFT", 0, -2)
    else
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 2, y / scale + 2)
    end

    menu.catcher:Show()
    menu:Show()
    return menu
end

function LCEX:HideContextMenu()
    if self._contextMenu then self._contextMenu:Hide() end
end
