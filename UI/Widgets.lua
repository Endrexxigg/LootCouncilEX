-- ── LootCouncil EX — UI/Widgets.lua ──────────────────────────────────────────
-- Native-frame style layer + factory. NO AceGUI (PROJECT.md §2): every frame in the addon
-- is a CreateFrame built through these helpers, so the look stays consistent and the TBC
-- gotchas live in one place — explicit Show()/Hide() (SetShown is retail-only) and ESC-close
-- via UISpecialFrames.
--
-- Loads before the frame modules (LootFrame/VotingFrame/SessionFrame) that build on it.

local LCEX = LootCouncilEX
local LAY = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua) — anchor from it, not literals

-- Shared metrics (the theme's colors/fonts and the LAYOUT spacing grid live in UI/Theme.lua).
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

-- ── Flat scrollbar ───────────────────────────────────────────────────────────
-- Strip a FauxScrollFrame's stock Blizzard slider down to the addon's flat look (STYLE): hide
-- the beveled up/down arrow buttons and swap the default knob texture (130849) for a solid,
-- quiet theme fill. Shared by every CreateScrollList, so this de-Blizzards every scroll list in
-- the addon (council browser, roster, history, gbank, session config) in one place.
function LCEX:FlatScrollBar(bar)
    -- Arrow buttons: parentKeys on the template, else the named globals, else a Button-child scan
    -- (an unnamed FauxScrollFrame has no $parent name, so the parentKey/scan paths carry it here).
    local name = bar.GetName and bar:GetName()
    local up   = bar.ScrollUpButton   or (name and _G[name .. "ScrollUpButton"])
    local down = bar.ScrollDownButton or (name and _G[name .. "ScrollDownButton"])
    if not (up and down) then
        for _, child in ipairs({ bar:GetChildren() }) do
            if child:IsObjectType("Button") then
                if not up then up = child else down = down or child end
            end
        end
    end
    -- Stash the arrows so the list's Refresh() can re-hide them: FauxScrollFrame_Update toggles
    -- their ENABLED state (not shown), so a one-time Hide() should stick — but re-hiding after
    -- every Update is the belt-and-suspenders that guarantees the flat look.
    bar._flatArrows = { up, down }
    for _, b in ipairs(bar._flatArrows) do
        if b then b:Hide(); b:SetAlpha(0); b:EnableMouse(false) end
    end

    -- Solid thumb in place of the default knob (matches CreateSliderV2's flat thumb pattern).
    -- Full-track-width thumb, same as CreatePixelScrollList's — the two list types must render
    -- identical bars.
    bar:SetWidth(6)
    bar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = bar:GetThumbTexture()
    if thumb then
        local c = self.Theme.text.faint
        thumb:SetVertexColor(c[1], c[2], c[3], 0.9)
        thumb:SetSize(6, 24)
    end
    return bar
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
    -- it INSIDE the list, CENTERED in the LAYOUT.gutter strip the rows leave free (below) — the
    -- same geometry as CreatePixelScrollList, so every list in the addon places its bar
    -- identically. `sf.ScrollBar` is the template's parentKey; the Slider-child scan covers a
    -- client where only the name differs.
    local bar = sf.ScrollBar
    if not bar then
        for _, child in ipairs({ sf:GetChildren() }) do
            if child:IsObjectType("Slider") then bar = child; break end
        end
    end
    if bar then
        bar:ClearAllPoints()
        -- Flat-styled (arrows hidden below), so no ±16 arrow gap — run the thumb the full height.
        local barPad = (LAY.gutter - 6) / 2 -- FlatScrollBar sets the track 6 wide
        bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", -barPad, -2)
        bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -barPad, 2)
        self:FlatScrollBar(bar)
        -- The flat bar hides the stock up/down arrows, so the wheel + thumb-drag are the scroll
        -- affordances. Driving the slider value routes through the template's OnValueChanged →
        -- sf:SetVerticalScroll → our OnVerticalScroll → Refresh, exactly as an arrow click did.
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(_, delta)
            bar:SetValue(bar:GetValue() - delta * rowHeight)
        end)
    end
    list.scrollBar = bar

    local function Refresh()
        FauxScrollFrame_Update(sf, #list.items, list.visibleRows, rowHeight)
        -- Re-hide the stock arrows: FauxScrollFrame_Update may re-show the bar (and, on some
        -- clients, its arrow buttons) whenever the row count crosses the visible window.
        if bar and bar._flatArrows then
            for _, b in ipairs(bar._flatArrows) do if b then b:Hide() end end
        end
        local offset = FauxScrollFrame_GetOffset(sf)
        for i = 1, list.visibleRows do
            local row = list.rows[i]
            if not row then
                row = opts.buildRow(list)
                row:SetHeight(rowHeight)
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -LAY.gutter, -(i - 1) * rowHeight) -- scrollbar gutter
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

-- ── Pixel scroll list (real ScrollFrame) ─────────────────────────────────────
-- A REAL ScrollFrame (not FauxScrollFrame): every row is a child of ONE tall scroll child that
-- slides by PIXELS under a clipped viewport, so partial rows show at the top/bottom edges and the
-- thumb (or wheel) scrolls smoothly instead of paging by index. Same builder contract as
-- CreateScrollList — buildRow(parent)->row, fillRow(row,item,index), SetData(items), zebra — so an
-- existing row factory drops in unchanged. `opts = { rowHeight, width, buildRow, fillRow, zebra,
-- gutter }`; `gutter` reserves the flat scrollbar's strip on the right so row content never crashes
-- into it (defaults to the shared LAYOUT.gutter, like CreateScrollList). The compact Loot Session
-- staging list uses this; the Faux helper still serves the rest.
function LCEX:CreatePixelScrollList(parent, opts)
    local addon     = self
    local rowHeight = opts.rowHeight or self.STYLE.rowHeight
    local width     = opts.width or 320
    local gutter    = opts.gutter or LAY.gutter

    local list = CreateFrame("Frame", nil, parent)
    list:SetSize(width, rowHeight * (opts.visibleRows or 6))
    list.rows, list.items = {}, {}

    -- Clipped viewport: the scroll child is cut to these bounds, so a row straddling an edge draws
    -- partially. Leaves `gutter` free on the right for the scrollbar.
    local sf = CreateFrame("ScrollFrame", nil, list)
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -gutter, 0)
    if sf.SetClipsChildren then sf:SetClipsChildren(true) end
    list.scroll = sf

    -- Scroll child: full viewport width, as tall as the data. Holds every row stacked by pixels.
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(width - gutter, 1)
    sf:SetScrollChild(child)
    list.child = child

    -- Flat scrollbar CENTERED in the reserved gutter — a bare Slider (no template), so there are no
    -- stock arrow buttons or knob texture to strip; just a faint track and a solid theme thumb.
    -- Centering (equal pad each side) keeps the gutter from reading as a random extra right margin.
    local barW = math.min(6, math.max(2, gutter - 6))
    local barPad = (gutter - barW) / 2
    local bar = CreateFrame("Slider", nil, list)
    bar:SetOrientation("VERTICAL")
    bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", -barPad, -2)
    bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -barPad, 2)
    bar:SetWidth(barW)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(bar)
    track:SetTexture("Interface\\Buttons\\WHITE8X8")
    track:SetVertexColor(1, 1, 1, 0.03)
    bar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = bar:GetThumbTexture()
    if thumb then
        local c = self.Theme.text.faint
        thumb:SetVertexColor(c[1], c[2], c[3], 0.9)
        thumb:SetSize(barW, 24)
    end
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    list.scrollBar = bar

    -- Apply a known max scroll: clamp the thumb into [0, max], and — the padding half — reserve the
    -- gutter ONLY when a bar is actually needed. With no bar the viewport (and its rows) reclaim the
    -- gutter, so a short list isn't left with a lopsided empty strip down the right edge.
    local function applyRange(max)
        max = math.max(0, max or 0)
        bar:SetMinMaxValues(0, max)
        if bar:GetValue() > max then bar:SetValue(max) end -- clamps the ScrollFrame via OnValueChanged
        local show = max > 0
        if show ~= list._barShown then
            list._barShown = show
            sf:SetPoint("BOTTOMRIGHT", show and -gutter or 0, 0) -- replaces only the BR anchor
            if show then bar:Show() else bar:Hide() end
        end
    end

    -- Best-effort synchronous recompute from the viewport height we can measure now...
    local function updateRange()
        applyRange(#list.items * rowHeight - (list:GetHeight() or 0))
    end
    -- ...backed by the authoritative post-layout signal: the ScrollFrame reports its true vertical
    -- range once WoW has laid the child out, so the clamp lands correctly even when a synchronous
    -- height read was stale (e.g. the list hadn't been sized yet at SetData time).
    sf:SetScript("OnScrollRangeChanged", function(_, _, yrange) applyRange(yrange) end)

    bar:SetScript("OnValueChanged", function(_, value) sf:SetVerticalScroll(value) end)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta)
        bar:SetValue(bar:GetValue() - delta * rowHeight) -- one row per notch; drag for finer/partial
    end)

    -- Rebuild the stacked rows for the current data (pooled: reused across SetData, hidden past the
    -- data length). Every row is a real child of the scroll child; clipping decides which pixels
    -- show, so there's no index windowing to keep in sync.
    local function layout()
        local w = sf:GetWidth() or (width - gutter)
        child:SetWidth(w)
        child:SetHeight(math.max(1, #list.items * rowHeight))
        for i, item in ipairs(list.items) do
            local row = list.rows[i]
            if not row then
                row = opts.buildRow(child)
                row:SetHeight(rowHeight)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * rowHeight)
                if opts.zebra then
                    row._stripe = row:CreateTexture(nil, "BACKGROUND", nil, 1)
                    row._stripe:SetAllPoints(row)
                    row._stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
                    local s = addon.Theme.stripe
                    row._stripe:SetVertexColor(s[1], s[2], s[3], s[4])
                end
                list.rows[i] = row
            end
            opts.fillRow(row, item, i)
            if row._stripe then
                if i % 2 == 0 then row._stripe:Show() else row._stripe:Hide() end
            end
            row:Show()
        end
        for i = #list.items + 1, #list.rows do list.rows[i]:Hide() end
    end
    list.Refresh = layout

    -- A resizable/reflowing parent only changes the scroll RANGE — row Y positions are child-
    -- relative, so they don't move; just match the child width and recompute the range.
    sf:SetScript("OnSizeChanged", function(_, w)
        child:SetWidth(w)
        updateRange()
    end)

    -- Repaint the SAME logical list (selection change, per-row edit, aggregate update) WITHOUT
    -- yanking the view: keep the current pixel offset and clamp it to the new range. A shorter list
    -- (items removed) pulls the offset up only as far as needed; an unchanged/taller list holds it.
    function list.SetData(l, items)
        l.items = items or {}
        layout()
        updateRange() -- clamps bar (and thus the ScrollFrame, via OnValueChanged) into [0, max]
    end

    -- Deliberate reset to the top — for a fresh/empty window or an explicit "scroll to top". Not
    -- called on ordinary repaints, so selection never snaps the view back.
    function list.ScrollToTop(l)
        l.scrollBar:SetValue(0)
        l.scroll:SetVerticalScroll(0)
    end
    return list
end

-- ── Edit box ─────────────────────────────────────────────────────────────────
-- A single-line input (generalizes LootFrame's note box). `opts = { width, onCommit(text) }`.
-- Enter commits (then unfocuses); Escape unfocuses. Commits should route through SetRecord.
function LCEX:CreateEditBox(parent, opts)
    opts = opts or {}
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(opts.width or 200, LAY.editH)
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
-- keys need no DB_DEFAULTS entry). Size is saved only for resizable windows; width-only
-- resize windows let content determine their height.
local function SavePlacement(addon, f, savedKey, resizable, widthOnly)
    if not (savedKey and addon.db) then return end
    local p = addon.db.profile.ui[savedKey]
    if not p then p = {}; addon.db.profile.ui[savedKey] = p end
    local point, _, relPoint, x, y = f:GetPoint()
    p.point, p.relPoint, p.x, p.y = point, relPoint, x, y
    if resizable then
        p.w = f:GetWidth()
        if not widthOnly then p.h = f:GetHeight() end
    end
end

-- ── Window v2 ────────────────────────────────────────────────────────────────
-- Themed, movable, ESC-closable window. `name` is the GLOBAL frame name (UISpecialFrames).
-- opts = { width, height, title, titleH, titleSizeKey, chromeInset, savedKey, defaultPos={x,y},
--          resizable, resizeWOnly, minW, minH, noClose, scale, alpha, useOpacity } — savedKey persists position
-- (and size when resizable); useOpacity
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
    -- Z-order — fixes the loot⇄council "windows drawing through each other" bug. Two co-shown LCEX
    -- windows share the DIALOG strata, and on this (TBC 2.5.x) client frame:Raise() alone does NOT
    -- give them distinct frame LEVELS, so the client interleaves their children by creation order
    -- and one window's rows punch through the other. The fix is the proven RCLootCouncil/Gargul TBC
    -- idiom, two parts:
    --   • A DISTINCT base frame level per window, assigned HERE at creation — BEFORE any child
    --     frame exists, so every child is born into this window's level band (a later SetFrameLevel
    --     is not relied on to cascade to children). The 20-level band leaves room for a window's own
    --     child-frame depth before the next window's band begins, so the two never interleave.
    --   • SetToplevel(true): a click lifts the window AND its whole child stack above other
    --     same-strata windows as one group.
    addon._v2NextLevel = (addon._v2NextLevel or 100) + 20
    f:SetFrameLevel(addon._v2NextLevel)
    f:SetToplevel(true)
    -- Re-raise on show / click so the most recently surfaced window comes to the front; native
    -- Raise() moves the frame together with its children, and the distinct base levels above keep
    -- the raised window strictly above the others' bands rather than colliding at one level.
    f:HookScript("OnShow", function(w) w:Raise() end)
    f:SetScript("OnMouseDown", function(w) w:Raise() end)
    self:Surface(f, "page")
    self:SoftEdge(f)

    -- Title bar: the drag handle. A 3px gold tick + title text; close × on the right unless
    -- noClose is set for passive HUD frames. The tick
    -- sits on the window's absolute content line (LAYOUT.grid): bar at edge + tick at pad = grid.
    local titleH = opts.titleH or LAY.titleH
    local chromeInset = (opts.chromeInset ~= nil) and opts.chromeInset or LAY.edge
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", chromeInset, -chromeInset)
    bar:SetPoint("TOPRIGHT", -chromeInset, -chromeInset)
    bar:SetHeight(titleH)
    self:Surface(bar, "raised")
    f.bar = bar

    local tick = bar:CreateTexture(nil, "ARTWORK")
    tick:SetTexture("Interface\\Buttons\\WHITE8X8")
    tick:SetSize(3, opts.titleTickH or math.min(14, math.max(8, titleH - 6)))
    tick:SetPoint("LEFT", LAY.pad, 0)
    tick:SetVertexColor(self.Theme.accent[1], self.Theme.accent[2], self.Theme.accent[3], 1)

    local title = bar:CreateFontString(nil, "OVERLAY")
    self:ThemeText(title, opts.titleSizeKey or "section", "ink")
    title:SetPoint("LEFT", tick, "RIGHT", LAY.gap, 0)
    title:SetText(opts.title or "")
    f.title = title

    f:SetMovable(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnMouseDown", function() f:Raise() end) -- the bar captures the click, so raise here too
    bar:SetScript("OnDragStart", function() f:Raise(); f:StartMoving() end)
    bar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SavePlacement(addon, f, opts.savedKey, opts.resizable, opts.resizeWOnly)
    end)

    if not opts.noClose then
        local close = CreateFrame("Button", nil, bar)
        local closeSize = math.min(LAY.btnH, math.max(12, titleH - 2))
        close:SetSize(closeSize, closeSize)
        close:SetPoint("RIGHT", -LAY.gapTight, 0)
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
    end

    -- Resizable: bottom-right grip with the stuck-sizing guard (grip mouse-up alone can miss
    -- when the cursor leaves the grip — also stop on the frame's own mouse-up and on hide).
    if opts.resizable then
        local minW, minH = opts.minW or 480, opts.minH or 320
        if not opts.resizeWOnly then
            f:SetResizable(true)
            if f.SetResizeBounds then f:SetResizeBounds(minW, minH)
            elseif f.SetMinResize then f:SetMinResize(minW, minH) end
        end

        local grip = CreateFrame("Button", nil, f)
        local gripSize = opts.resizeGripSize or 16
        grip:SetSize(gripSize, gripSize)
        grip:SetPoint("BOTTOMRIGHT", -3, 3)
        grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        local function stopSizing()
            if f._sizing then
                f._sizing = false
                grip:SetScript("OnUpdate", nil)
                f:StopMovingOrSizing()
                SavePlacement(addon, f, opts.savedKey, true, opts.resizeWOnly)
            end
        end
        grip:SetScript("OnMouseDown", function()
            f._sizing = true
            f:Raise()
            if opts.resizeWOnly then
                local x = GetCursorPosition()
                local scale = UIParent:GetEffectiveScale()
                f._resizeStartX = x / scale
                f._resizeStartW = f:GetWidth()
                grip:SetScript("OnUpdate", function()
                    if not f._sizing then return end
                    local cx = GetCursorPosition()
                    local cs = UIParent:GetEffectiveScale()
                    f:SetWidth(math.max(minW, f._resizeStartW + (cx / cs - f._resizeStartX)))
                end)
            else
                f:StartSizing("BOTTOMRIGHT")
            end
        end)
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
        if opts.resizable and opts.resizeWOnly and p and p.w then
            f:SetWidth(p.w)
        elseif opts.resizable and p and p.w and p.h then
            f:SetSize(p.w, p.h)
        end
    end

    -- Appearance plumbing (Config window writes profile.appearance; nil-safe before then).
    function f.RefreshAppearance(win)
        local a = addon.db and addon.db.profile.appearance
        win:SetScale(((a and a.scale) or 1) * (opts.scale or 1))
        if opts.useOpacity then win:SetAlpha((a and a.opacity) or 1)
        elseif opts.alpha then win:SetAlpha(opts.alpha) end
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
    b:SetSize(width or 90, height or LAY.btnH)
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
        row:SetPoint("TOPLEFT", 0, -(#r.items) * ROW_H - LAY.inlineGap)
        row:SetPoint("TOPRIGHT", 0, -(#r.items) * ROW_H - LAY.inlineGap)
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
        row.fs:SetPoint("LEFT", LAY.pad, 0) -- the rail is an edge-anchored chrome panel: pad line
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
    cb.fs:SetPoint("LEFT", box, "RIGHT", LAY.iconGap, 0)
    cb.fs:SetText(label or "")
    cb:SetWidth(16 + LAY.iconGap + cb.fs:GetStringWidth() + LAY.gap) -- box + gap + label + clearance

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
        local W = 360
        f = self:CreateWindowV2("LCEX_Confirm",
            { width = W, height = 150, title = self.L["Confirm"], strata = "FULLSCREEN_DIALOG" })

        -- Bare window: everything on the LAYOUT.grid line; the edit box compensates its left art.
        f.msg = f:CreateFontString(nil, "OVERLAY")
        self:ThemeText(f.msg, "body", "ink")
        f.msg:SetPoint("TOPLEFT", LAY.grid, -(LAY.contentTop + LAY.gap))
        f.msg:SetPoint("TOPRIGHT", -LAY.grid, -(LAY.contentTop + LAY.gap))
        f.msg:SetJustifyH("LEFT"); f.msg:SetWordWrap(true)

        f.input = self:CreateEditBox(f, {
            width = W - 2 * LAY.grid - LAY.editPad, -- art lands grid-in on both sides
            onCommit = function() f.acceptBtn:Click() end, -- Enter in the box = confirm
        })
        f.input:SetPoint("TOPLEFT", LAY.grid + LAY.editPad, -86)

        f.acceptBtn = self:CreateFlatButton(f, self.L["Yes"], 90, LAY.btnH, "accent")
        f.acceptBtn:SetPoint("BOTTOMRIGHT", -LAY.grid, LAY.grid)
        f.cancelBtn = self:CreateFlatButton(f, self.L["No"], 90, LAY.btnH)
        f.cancelBtn:SetPoint("BOTTOMRIGHT", f.acceptBtn, "BOTTOMLEFT", -LAY.btnGap, 0)
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

        -- Title and row text share one line: title at pad; rows inset edge + fs at rowPad = pad.
        menu.title = menu:CreateFontString(nil, "OVERLAY")
        self:ThemeText(menu.title, "caption", "faint")
        menu.title:SetPoint("TOPLEFT", LAY.pad, -6)

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
            row.fs:SetPoint("LEFT", LAY.rowPad, 0)
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
        local w = row.fs:GetStringWidth() + 2 * (2 + LAY.rowPad) -- mirror the title's +2*pad width
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
