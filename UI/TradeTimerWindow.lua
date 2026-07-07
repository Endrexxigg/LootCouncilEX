-- ── LootCouncil EX — UI/TradeTimerWindow.lua ─────────────────────────────────
-- Gargul-style loot trade-timer window (Phase 12, §6.17, DL-22) — native rebuild, no LibCandyBar.
-- A compact draggable window of countdown bars, one per tradeable bag item, sorted soonest-first,
-- colored green/gold/red by fraction remaining. Winners (owed items) are annotated "→ Name".
-- Minimize collapses to just the soonest bar; auto-shows when loot is tradeable and auto-hides
-- when the list drains; shift+double-click a bar hides that item for the session.
--
-- Data comes from Core/TradeTimers.lua (self.tradeTimerEntries); this module only renders + repaints.
-- Loads after UI/Widgets.lua and Core/TradeTimers.lua.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local FRAME_NAME = "LCEX_TradeTimerWindow"
local TIMER_W    = 280
local ROW_H      = 22
local TOP        = LAY.contentTop -- first bar below the title bar
local SIDE       = LAY.edge + LAY.bleed -- bars are full-bleed bands on a bare window
local MAX_ROWS   = 12
local TRADE_WINDOW = 7200

local function LinkName(link) return tostring(link):match("%[(.-)%]") or tostring(link) end

-- The entries to show: not user-hidden, still running, soonest expiry first.
function LCEX:_VisibleTradeEntries()
    local hidden = self.tradeTimerHidden or {}
    local now = time()
    local out = {}
    for _, e in ipairs(self.tradeTimerEntries or {}) do
        if not hidden[e.key] and (e.expireAt or 0) > now then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return (a.expireAt or 0) < (b.expireAt or 0) end)
    return out
end

local function BuildTimerRow(f)
    local addon = LCEX
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetAllPoints(row)
    row.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    row.bar:SetMinMaxValues(0, TRADE_WINDOW)
    row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.bar.bg:SetAllPoints(row.bar)
    row.bar.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bar.bg:SetVertexColor(0, 0, 0, 0.4)

    row.icon = addon:CreateItemIcon(row, ROW_H - 4)
    row.icon:SetPoint("LEFT", 2, 0) -- (ROW_H - icon) / 2: vertically-derived, keeps the icon square-centered

    row.label = row:CreateFontString(nil, "OVERLAY")
    addon:ThemeText(row.label, "caption", "ink")
    local lf, lsz = row.label:GetFont()
    if lf then row.label:SetFont(lf, lsz, "OUTLINE") end -- readable over the fill
    row.label:SetPoint("LEFT", row.icon, "RIGHT", LAY.inlineGap, 0)
    row.label:SetJustifyH("LEFT"); row.label:SetWordWrap(false)

    row.time = row:CreateFontString(nil, "OVERLAY")
    addon:ThemeText(row.time, "caption", "ink")
    local tf, tsz = row.time:GetFont()
    if tf then row.time:SetFont(tf, tsz, "OUTLINE") end
    row.time:SetPoint("RIGHT", -LAY.inlineGap, 0)
    row.label:SetPoint("RIGHT", row.time, "LEFT", -LAY.inlineGap, 0)

    -- Hover: the item tooltip + who owes it + the hide hint. The bar label truncates the "→ Name",
    -- so the winner (who the item must be traded to) stays readable here. Shift+double-click hides.
    row:SetScript("OnEnter", function(r)
        if r.link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(r.link)
            if r._winner and r._winner ~= "" and r.label:IsTruncated() then
                local ink = addon.Theme.text.ink
                GameTooltip:AddLine("→ " .. r._winner, ink[1], ink[2], ink[3])
            end
            GameTooltip:AddLine(addon.L["Shift+double-click to hide"], 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnDoubleClick", function(r)
        if IsShiftKeyDown() and r.key then
            addon.tradeTimerHidden = addon.tradeTimerHidden or {}
            addon.tradeTimerHidden[r.key] = true
            addon:UpdateTradeTimerWindow()
        end
    end)
    return row
end

function LCEX:EnsureTradeTimerWindow()
    if self.tradeTimerWindow then return self.tradeTimerWindow end
    local addon = self
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = TIMER_W, height = 120,
        title = self.L["Trade timers"],
        savedKey = "tradeTimers",
        defaultPos = { x = 300, y = 0 },
        noEscClose = true, -- a passive HUD shouldn't eat ESC
    })

    -- A user close (×) suppresses auto-show until the list next drains to empty (Gargul-like).
    f.closeButton:HookScript("OnClick", function() addon._tradeUserClosed = true end)

    -- Minimize: collapse to just the soonest bar (+N). Sits left of the close × (paired glyphs).
    local mini = CreateFrame("Button", nil, f.bar)
    mini:SetSize(LAY.btnH, LAY.btnH)
    mini:SetPoint("RIGHT", f.closeButton, "LEFT", -2, 0)
    mini.fs = mini:CreateFontString(nil, "OVERLAY")
    self:ThemeText(mini.fs, "section", "dim")
    mini.fs:SetPoint("CENTER", 0, 0)
    mini.fs:SetText("_")
    mini:SetScript("OnClick", function()
        addon._tradeMinimized = not addon._tradeMinimized
        addon:UpdateTradeTimerWindow()
    end)
    f.miniButton = mini

    f.more = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.more, "caption", "faint")
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
    local name = LinkName(entry.link)
    row._winner = entry.winner and (entry.winner:match("^[^%-]+") or entry.winner) or nil -- for the hover tooltip
    row.label:SetText(entry.winner and (name .. "  → " .. row._winner) or name)
    row.time:SetText(self:FormatDuration(remaining))
    row.bar:SetValue(remaining)
    local c = self:TradeBarColor(remaining, TRADE_WINDOW)
    row.bar:SetStatusBarColor(c[1], c[2], c[3], 0.85)
end

-- The single render/refresh verb (called by RescanTradeTimers and the 1s tick). Rebuilds the
-- visible bars, reflows the height, and drives auto-show / auto-hide.
function LCEX:UpdateTradeTimerWindow()
    local visible = self:_VisibleTradeEntries()

    -- Auto-hide + reset the user-closed latch when the list drains (next batch auto-shows again).
    if #visible == 0 then
        self._tradeUserClosed = false
        if self.tradeTimerWindow then self.tradeTimerWindow:Hide() end
        self:_StopTradeTimerTick()
        return
    end
    -- Auto-show only when enabled and not dismissed this batch; an already-open window stays open.
    local f = self.tradeTimerWindow
    local wantShow = self.db.profile.tradeTimersAuto and not self._tradeUserClosed
    if not f then
        if not wantShow then return end -- nothing to show and not asked to
        f = self:EnsureTradeTimerWindow()
    end
    if not f:IsShown() then
        if not wantShow then return end
        f:Show()
    end

    local shown = self._tradeMinimized and 1 or math.min(#visible, MAX_ROWS)
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
        -- "+N more" on the bars' left edge, in a 16px band 2px under the last bar.
        f.more:ClearAllPoints()
        f.more:SetPoint("TOPLEFT", SIDE, -(bottom + 2))
        f.more:SetText(string.format(self.L["+ %d more"], extra))
        f.more:Show()
        bottom = bottom + 16
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
    self:UpdateTradeTimerWindow()
end

-- /lcex timers — toggle the window manually (clears the auto-show suppression when opening).
function LCEX:ToggleTradeTimerWindow()
    local f = self.tradeTimerWindow
    if f and f:IsShown() then
        self._tradeUserClosed = true
        f:Hide()
    else
        self._tradeUserClosed = false
        self:RescanTradeTimers() -- refresh then render
        self:EnsureTradeTimerWindow():Show()
        self:UpdateTradeTimerWindow()
    end
end
