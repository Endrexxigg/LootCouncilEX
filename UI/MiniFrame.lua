-- ── LootCouncil EX — UI/MiniFrame.lua ────────────────────────────────────────
-- The mini session pill (Phase 12, §6.13, item 5): a small draggable indicator that a loot
-- session is ACTIVE while the full loot window is hidden — so closing/minimizing the window can
-- never make the ML forget an open session. Clicking it reopens the full window.
--
-- Window visibility ≠ session state (DL-18): the pill only reflects state, it never changes it.
-- Shown iff a session view is active AND the loot window is hidden — at any view level (a
-- spectator benefits too). A single verb, UpdateMiniFrame(), is driven from EnterSession /
-- LeaveSession / RefreshLootItem and the loot window's OnShow/OnHide hooks.
--
-- Loads after UI/LootWindow.lua (calls ShowLootWindow) and UI/Widgets.lua (Surface/SoftEdge).

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local FRAME_NAME = "LCEX_MiniFrame"
local PILL_W, PILL_H = 220, 26   -- PILL_W is the MINIMUM; the pill grows to fit its text (item 4)
local PILL_MAX_W = 360           -- cap; beyond this the hover tooltip carries the overflow

-- Responses collected so far across all groups (full view only — a list-level spectator never
-- stores rows, §6.13/DL-18). Counts rows that carry an actual response, not seeded placeholders.
local function CountResponses(self)
    local n = 0
    if self.voteRows then
        for _, rows in pairs(self.voteRows) do
            for _, d in pairs(rows) do
                if d.resp ~= nil then n = n + 1 end
            end
        end
    end
    return n
end

local function CountAwarded(a)
    local n = 0
    if a and a.awarded then for _ in pairs(a.awarded) do n = n + 1 end end
    return n
end

function LCEX:EnsureMiniFrame()
    if self.miniFrame then return self.miniFrame end
    local addon = self

    local f = CreateFrame("Button", FRAME_NAME, UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(PILL_W, PILL_H)
    f:SetFrameStrata("HIGH") -- above the world, below the DIALOG windows
    f:SetClampedToScreen(true)
    self:Surface(f, "float")
    self:SoftEdge(f)

    -- A gold tick + the status text: the pill reads as a single list row (rowPad insets,
    -- iconGap between tick and text — the title-bar tick grammar at row scale).
    local tick = f:CreateTexture(nil, "ARTWORK")
    tick:SetTexture("Interface\\Buttons\\WHITE8X8")
    tick:SetSize(3, 12)
    tick:SetPoint("LEFT", LAY.rowPad, 0)
    tick:SetVertexColor(self.Theme.accent[1], self.Theme.accent[2], self.Theme.accent[3], 1)

    f.text = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.text, "caption", "ink")
    f.text:SetPoint("LEFT", tick, "RIGHT", LAY.iconGap, 0)
    f.text:SetPoint("RIGHT", -LAY.rowPad, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetWordWrap(false)

    -- Restore saved position (defaults to lower-centre so it doesn't cover the party frames).
    local p = self.db and self.db.profile.ui.mini
    f:ClearAllPoints()
    if p and p.point then
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 180)
    end

    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(b) b:StartMoving() end)
    f:SetScript("OnDragStop", function(b)
        b:StopMovingOrSizing()
        if addon.db then
            local point, _, relPoint, x, y = b:GetPoint()
            addon.db.profile.ui.mini = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end)

    -- Left-click (not a drag) reopens the full window; the OnShow hook then hides the pill.
    f:RegisterForClicks("LeftButtonUp")
    f:SetScript("OnClick", function()
        if addon.recoverableSession and not addon.activeSession and addon.ShowResumePrompt then
            addon:ShowResumePrompt() -- recovery review (§6.16, C20)
        else
            addon:ShowLootWindow()
        end
    end)
    -- The pill text truncates at 220px; when it's clipped, hovering shows the full session-status
    -- string at the cursor. The surface re-tint is unconditional; only the tooltip is gated.
    f:SetScript("OnEnter", function(b)
        addon:Surface(b, "overlay")
        if b.text:IsTruncated() then
            GameTooltip:SetOwner(b, "ANCHOR_CURSOR")
            GameTooltip:AddLine(b.text:GetText(), 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function(b) addon:Surface(b, "float"); GameTooltip:Hide() end)

    f:Hide()
    self.miniFrame = f
    return f
end

-- The single update verb: show the pill iff there is something to surface (an active session, or
-- an unresolved recoverable one — §6.16) AND the full loot window is hidden; else hide it.
function LCEX:UpdateMiniFrame()
    local a = self.activeSession
    local lootShown = self.lootWindow and self.lootWindow:IsShown()
    local recover = self.recoverableSession and not a

    if (not a and not recover) or lootShown then
        if self.miniFrame then self.miniFrame:Hide() end
        return
    end

    local f = self:EnsureMiniFrame()
    if recover then
        f.text:SetText(self.L["Unresolved loot session — click to review"])
    else
        local n = (a.groups and #a.groups.leaders) or (a.items and #a.items) or 0
        if a.viewLevel == "full" then
            f.text:SetText(string.format(self.L["Loot session: %d item(s) · %d response(s)"],
                n, CountResponses(self)))
        else
            f.text:SetText(string.format(self.L["Loot session: %d item(s) · %d awarded"],
                n, CountAwarded(a)))
        end
    end
    -- Size the pill to its text (item 4): the minimized frame isn't user-resizable, so the fixed
    -- 220 clipped the longer status strings. Grow to fit, clamped between PILL_W and PILL_MAX_W —
    -- the OnEnter tooltip still backs the rare string that exceeds the cap. Chrome around the text
    -- = the tick's left inset (rowPad) + tick (3) + the tick→text gap (iconGap) + the right inset
    -- (rowPad), matching the EnsureMiniFrame anchors.
    local chrome = LAY.rowPad + 3 + LAY.iconGap + LAY.rowPad
    f:SetWidth(math.max(PILL_W, math.min(PILL_MAX_W, math.ceil(f.text:GetStringWidth()) + chrome + 2)))
    f:Show()
end
