-- ── LootCouncil EX — UI/TradeTimerWindow.lua ─────────────────────────────────
-- Gargul-style loot trade-timer window (Phase 12, §6.17, DL-22) — native rebuild, no LibCandyBar.
-- A compact draggable/resizable window of countdown bars, one per tradeable bag item, sorted
-- soonest-first, colored green/gold/red by remaining time. Winners (owed items) are
-- annotated "-> Name". Minimize collapses to just the soonest bar. The frame is not closeable:
-- when the feature is enabled and loot is tradeable, the information stays on-screen.
--
-- Data comes from Core/TradeTimers.lua (self.tradeTimerEntries); this module only renders + repaints.
-- Loads after UI/Widgets.lua and Core/TradeTimers.lua.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local FRAME_NAME = "LCEX_TradeTimerWindow"
local TIMER_W    = 260
local TIMER_TITLE_H = 14
local ROW_H      = TIMER_TITLE_H
local TIMER_SCALE = 0.9
local TIMER_ALPHA = 1
local ROW_FONT   = "Fonts\\ARIALN.TTF"
local ROW_FONT_SIZE = 9
local TITLE_FONT_SIZE = 8
local TITLE_SLATE = { 0.45, 0.50, 0.57 }
local SHELL_ALPHA  = 0.25
local TEXT_GAP    = 3
local TOP        = TIMER_TITLE_H -- first bar below the title bar
local SIDE       = 0
local TRADE_WINDOW = 7200
local TIMER_TEST_ITEM_ID = 30092
local TIMER_TEST_LINK = "|cffa335ee|Hitem:30092::::::::70:::::|h[Leggings of the Festering Swarm]|h|r"
local TIMER_TEST_DURATION = 74 * 60
local WHITE = "Interface\\Buttons\\WHITE8X8"

local function PaintSurfaceAlpha(tex, tone, alpha)
    tex:Show()
    tex:SetTexture(WHITE)
    tex:SetAlpha(1)
    local ok = false
    if tex.SetGradient and CreateColor then
        ok = pcall(tex.SetGradient, tex, "VERTICAL",
            CreateColor(tone.bottom[1], tone.bottom[2], tone.bottom[3], alpha),
            CreateColor(tone.top[1], tone.top[2], tone.top[3], alpha))
    end
    if not ok and tex.SetGradientAlpha then
        tex:SetGradientAlpha("VERTICAL",
            tone.bottom[1], tone.bottom[2], tone.bottom[3], alpha,
            tone.top[1], tone.top[2], tone.top[3], alpha)
        ok = true
    end
    if not ok then
        tex:SetVertexColor((tone.top[1] + tone.bottom[1]) / 2,
            (tone.top[2] + tone.bottom[2]) / 2,
            (tone.top[3] + tone.bottom[3]) / 2, alpha)
    end
    tex._lcexAlpha = alpha
end

local function SetSurfaceAlpha(frame, toneName, alpha)
    local tone = LCEX.Theme.tone[toneName] or LCEX.Theme.tone.base
    if frame and frame._surface then
        PaintSurfaceAlpha(frame._surface, tone, alpha)
    end
    if frame and frame._topLight then
        frame._topLight:Show()
        frame._topLight:SetAlpha(1)
        frame._topLight:SetVertexColor(1, 1, 1, 0.04 * alpha)
    end
end

local function LinkText(link) return tostring(link):match("(%[.-%])") or ("[" .. tostring(link) .. "]") end

local function ColorText(text, color)
    color = color or { 1, 1, 1 }
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor((color[1] or 1) * 255 + 0.5),
        math.floor((color[2] or 1) * 255 + 0.5),
        math.floor((color[3] or 1) * 255 + 0.5),
        tostring(text or ""))
end

local function AddVisibleEntries(out, entries, now)
    for _, e in ipairs(entries or {}) do
        if (e.expireAt or 0) > now then out[#out + 1] = e end
    end
end

function LCEX:_TradeTimerTestActive()
    local now = time()
    for _, e in ipairs(self.tradeTimerTestEntries or {}) do
        if (e.expireAt or 0) > now then return true end
    end
    return false
end

-- The entries to show: still running, soonest expiry first. Real bag timers obey the feature
-- toggle; /lcex timertest entries are explicit and display even when the feature is off.
function LCEX:_VisibleTradeEntries()
    local now = time()
    local out = {}
    if self.db and self.db.profile and self.db.profile.tradeTimersAuto then
        AddVisibleEntries(out, self.tradeTimerEntries, now)
    end
    AddVisibleEntries(out, self.tradeTimerTestEntries, now)
    table.sort(out, function(a, b) return (a.expireAt or 0) < (b.expireAt or 0) end)
    return out
end

function LCEX:TradeTimerMaxRows()
    local n = self.db and self.db.profile and tonumber(self.db.profile.tradeTimersMaxRows)
    if not n then return 10 end
    n = math.floor(n)
    if n <= 0 then return nil end
    return n
end

local function BuildTimerRow(f)
    local addon = LCEX
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetPoint("TOPLEFT", ROW_H, 0)
    row.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    row.bar:SetMinMaxValues(0, TRADE_WINDOW)
    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bar.bg:SetAllPoints(row.bar)
    row.bar.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bar.bg:SetVertexColor(0, 0, 0, SHELL_ALPHA)

    row.textLayer = CreateFrame("Frame", nil, row)
    row.textLayer:SetAllPoints(row)
    row.textLayer:SetFrameLevel(row.bar:GetFrameLevel() + 2)

    row.icon = addon:CreateItemIcon(row.textLayer, ROW_H)
    row.icon:SetPoint("LEFT", 0, 0)

    row.label = row.textLayer:CreateFontString(nil, "OVERLAY")
    row.label:SetFont(ROW_FONT, ROW_FONT_SIZE, "OUTLINE")
    row.label:SetTextColor(1, 1, 1)
    row.label:SetShadowColor(0, 0, 0, 1)
    row.label:SetShadowOffset(1, -1)
    row.label:SetPoint("LEFT", row.icon, "RIGHT", TEXT_GAP, 0)
    row.label:SetJustifyH("LEFT"); row.label:SetWordWrap(false)

    row.time = row.textLayer:CreateFontString(nil, "OVERLAY")
    row.time:SetFont(ROW_FONT, ROW_FONT_SIZE, "OUTLINE")
    local ink = addon.Theme.text.ink
    row.time:SetTextColor(ink[1], ink[2], ink[3])
    row.time:SetShadowColor(0, 0, 0, 1)
    row.time:SetShadowOffset(1, -1)
    row.time:SetPoint("RIGHT", -TEXT_GAP, 0)
    row.label:SetPoint("RIGHT", row.time, "LEFT", -TEXT_GAP, 0)

    -- Hover: the item tooltip + who owes it. The bar label can truncate the "-> Name", so the
    -- winner (who the item must be traded to) stays readable here.
    row:SetScript("OnEnter", function(r)
        if r.link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(r.link)
            if r._winner and r._winner ~= "" and r.label:IsTruncated() then
                local tip = addon.Theme.text.ink
                GameTooltip:AddLine("-> " .. r._winner, tip[1], tip[2], tip[3])
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

function LCEX:EnsureTradeTimerWindow()
    if self.tradeTimerWindow then return self.tradeTimerWindow end
    local addon = self
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = TIMER_W, height = TOP + ROW_H + SIDE,
        title = self.L["Loot"],
        titleH = TIMER_TITLE_H,
        titleSizeKey = "caption",
        titleTickH = 7,
        chromeInset = 0,
        savedKey = "tradeTimers",
        defaultPos = { x = 300, y = 0 },
        resizable = true,
        resizeWOnly = true,
        minW = 200, minH = TOP + ROW_H + SIDE,
        noClose = true,
        noEscClose = true, -- a passive HUD shouldn't eat ESC
        scale = TIMER_SCALE,
        alpha = TIMER_ALPHA,
        resizeGripSize = 11,
    })

    if f._surface then
        f._surface:ClearAllPoints()
        f._surface:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TOP)
        f._surface:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    end
    if f._topLight then f._topLight:Hide() end
    SetSurfaceAlpha(f, "page", SHELL_ALPHA)
    SetSurfaceAlpha(f.bar, "raised", SHELL_ALPHA)
    f.title:ClearAllPoints()
    f.title:SetPoint("CENTER", f.bar, "CENTER", 0, 0)
    f.title:SetFont(ROW_FONT, TITLE_FONT_SIZE, "")
    f.title:SetTextColor(TITLE_SLATE[1], TITLE_SLATE[2], TITLE_SLATE[3])
    f.title:SetText(self.L["Loot"])

    -- Minimize: collapse to just the soonest bar (+N).
    local mini = CreateFrame("Button", nil, f.bar)
    mini:SetSize(TIMER_TITLE_H - 3, TIMER_TITLE_H - 3)
    mini:SetPoint("RIGHT", -LAY.gapTight, 0)
    mini.fs = mini:CreateFontString(nil, "OVERLAY")
    mini.fs:SetFont(ROW_FONT, TITLE_FONT_SIZE, "")
    local dim = self.Theme.text.dim
    mini.fs:SetTextColor(dim[1], dim[2], dim[3])
    mini.fs:SetPoint("CENTER", 0, 0)
    mini.fs:SetText("-")
    mini:SetScript("OnClick", function()
        addon._tradeMinimized = not addon._tradeMinimized
        addon:UpdateTradeTimerWindow()
    end)
    f.miniButton = mini
    if f.resizeGrip then
        f.resizeGrip:ClearAllPoints()
        f.resizeGrip:SetPoint("BOTTOMRIGHT", 0, 0)
    end

    f.more = f:CreateFontString(nil, "OVERLAY")
    f.more:SetFont(ROW_FONT, TITLE_FONT_SIZE, "")
    local faint = self.Theme.text.faint
    f.more:SetTextColor(faint[1], faint[2], faint[3])
    f.more:Hide()

    f.rows = {}
    self.tradeTimerWindow = f
    return f
end

-- Repaint one row from an entry (called on render + each 1s tick).
local function FillTimerRow(self, row, entry)
    row.key, row.link = entry.key, entry.link
    local remaining = (entry.expireAt or 0) - time()
    if remaining < 0 then remaining = 0 end
    row.icon:SetItem(entry.link, entry.icon)
    local name = LinkText(entry.link)
    row._winner = entry.winner and (entry.winner:match("^[^%-]+") or entry.winner) or nil -- for the hover tooltip
    local itemText = ColorText(name, self:QualityColor(entry.quality))
    local winnerText = row._winner and ColorText("  -> " .. row._winner, self.Theme.text.dim) or ""
    row.label:SetText(itemText .. winnerText)
    row.time:SetText(self:FormatDuration(remaining))
    row.bar:SetValue(remaining)
    local c = self:TradeBarColor(remaining, TRADE_WINDOW)
    row.bar:SetStatusBarColor(c[1], c[2], c[3], 0.85)
end

-- The single render/refresh verb (called by RescanTradeTimers and the 1s tick). Rebuilds the
-- visible bars, reflows the height, and drives opt-in show / empty hide.
function LCEX:UpdateTradeTimerWindow()
    local enabled = self.db and self.db.profile and self.db.profile.tradeTimersAuto
    local testActive = self:_TradeTimerTestActive()

    if not (enabled or testActive) then
        if self.tradeTimerWindow then self.tradeTimerWindow:Hide() end
        self:_StopTradeTimerTick()
        return
    end

    local visible = self:_VisibleTradeEntries()
    if #visible == 0 then
        if self.tradeTimerWindow then self.tradeTimerWindow:Hide() end
        self:_StopTradeTimerTick()
        return
    end

    local f = self.tradeTimerWindow
    if not f then
        f = self:EnsureTradeTimerWindow()
    end
    if not f:IsShown() then f:Show() end

    local rowLimit = self:TradeTimerMaxRows()
    local shown = self._tradeMinimized and 1 or (rowLimit and math.min(#visible, rowLimit) or #visible)
    for i = 1, shown do
        local row = f.rows[i]
        if not row then
            row = BuildTimerRow(f)
            f.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", SIDE, -(TOP + (i - 1) * ROW_H))
        row:SetPoint("TOPRIGHT", -SIDE, -(TOP + (i - 1) * ROW_H))
        FillTimerRow(self, row, visible[i])
        row:Show()
    end
    for i = shown + 1, #f.rows do f.rows[i]:Hide() end

    local bottom = TOP + shown * ROW_H
    local extra = self._tradeMinimized and (#visible - 1) or (#visible - shown)
    if extra > 0 then
        -- "+N more" on the bars' left edge, in the same compact rhythm as the timer rows.
        f.more:ClearAllPoints()
        f.more:SetPoint("TOPLEFT", SIDE, -(bottom + 2))
        f.more:SetText(string.format(self.L["+ %d more"], extra))
        f.more:Show()
        bottom = bottom + ROW_H
    else
        f.more:Hide()
    end

    -- Grow/shrink downward (pin TOPLEFT — the PollWindow reflow pattern).
    local winTop, winLeft = f:GetTop(), f:GetLeft()
    f:SetHeight(bottom + SIDE)
    if type(winTop) == "number" and type(winLeft) == "number" then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", winLeft, winTop)
    end

    self:_StartTradeTimerTick()
end

-- 1s repaint ticker (only while the window is shown; display math is off the stored expireAt).
function LCEX:_StartTradeTimerTick()
    if not self._tradeTickTimer then
        self._tradeTickTimer = self:ScheduleRepeatingTimer("TickTradeTimerWindow", 1)
    end
end

function LCEX:_StopTradeTimerTick()
    if self._tradeTickTimer then
        self:CancelTimer(self._tradeTickTimer)
        self._tradeTickTimer = nil
    end
end

function LCEX:TickTradeTimerWindow()
    local f = self.tradeTimerWindow
    if not (f and f:IsShown()) then self:_StopTradeTimerTick(); return end
    -- Drop entries whose window lapsed since the last bag scan, then repaint.
    local now = time()
    local kept = {}
    for _, e in ipairs(self.tradeTimerEntries or {}) do
        if (e.expireAt or 0) > now then kept[#kept + 1] = e end
    end
    self.tradeTimerEntries = kept
    kept = {}
    for _, e in ipairs(self.tradeTimerTestEntries or {}) do
        if (e.expireAt or 0) > now then kept[#kept + 1] = e end
    end
    self.tradeTimerTestEntries = (#kept > 0) and kept or nil
    self:UpdateTradeTimerWindow()
end

-- /lcex timertest — toggles a synthetic in-memory row so the frame can be visually checked
-- without a real BoP drop. It deliberately bypasses the feature toggle but never persists.
function LCEX:CmdTimerTest()
    if self:_TradeTimerTestActive() then
        self.tradeTimerTestEntries = nil
        self:UpdateTradeTimerWindow()
        self:Msg(self.L["Trade timer test cleared."])
        return
    end

    local _, link, quality, _, _, _, _, _, _, icon = GetItemInfo(TIMER_TEST_ITEM_ID)
    if not icon and GetItemInfoInstant then icon = select(5, GetItemInfoInstant(TIMER_TEST_ITEM_ID)) end
    self.tradeTimerTestEntries = {
        {
            key      = "test:" .. tostring(time()),
            link     = link or TIMER_TEST_LINK,
            itemID   = TIMER_TEST_ITEM_ID,
            quality  = quality or 4,
            icon     = icon,
            expireAt = time() + TIMER_TEST_DURATION,
            winner   = UnitName("player") or "Test",
        },
    }
    self._tradeMinimized = false
    self:EnsureTradeTimerWindow()
    self:UpdateTradeTimerWindow()
    self:Msg(self.L["Trade timer test item shown. Run /lcex timertest again to clear it."])
end

-- /lcex timers — toggle the trade-timer feature. When enabled, the window is shown whenever
-- tradeable loot exists; when disabled, it is hidden.
function LCEX:ToggleTradeTimerWindow()
    if not (self.db and self.db.profile) then return end
    self.db.profile.tradeTimersAuto = not self.db.profile.tradeTimersAuto
    if not self.db.profile.tradeTimersAuto then
        if self.tradeTimerWindow then self.tradeTimerWindow:Hide() end
        self:_StopTradeTimerTick()
    else
        self:RescanTradeTimers() -- refresh then render
        self:UpdateTradeTimerWindow()
    end
    if self.configWindow and self.configWindow.controls then
        for _, c in ipairs(self.configWindow.controls) do
            if c.Refresh then c:Refresh() end
        end
    end
end
