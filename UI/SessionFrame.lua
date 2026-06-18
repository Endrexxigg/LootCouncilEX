-- ── LootCouncil EX — UI/SessionFrame.lua ─────────────────────────────────────
-- The ML's control panel: a preview of the councilable items in your bags plus Start / End
-- buttons — the windowed equivalent of /lcex scan + /lcex start + /lcex end. Opened with a
-- bare /lcex (or /lcex show). Anyone may open it and start a session (whoever runs Start is
-- that session's ML, DL-11); awarding happens from the council VotingFrame.
--
-- Loads after UI/Widgets.lua and reads BuildCouncilableList / StartSession / EndSession.

local LCEX = LootCouncilEX

-- GetItemInfoInstant: synchronous, never-nil; on Anniversary it may live under C_Item.
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_SessionFrame"

function LCEX:EnsureSessionFrame()
    if self.sessionFrame then return self.sessionFrame end
    local f = self:CreateWindow(FRAME_NAME, {
        width = 380, height = 320,
        title = self.L["LootCouncil EX"],
        savedKey = "sessionFrame",
    })
    f.rows = {}

    f.status = self:CreateLabel(f, nil, "GameFontNormal")
    f.status:SetPoint("TOP", 0, -38)

    f.refresh = self:CreateButton(f, self.L["Refresh"], 80, 22)
    f.refresh:SetPoint("BOTTOMLEFT", 16, 14)
    f.refresh:SetScript("OnClick", function() self:RefreshSessionFrame() end)

    f.startBtn = self:CreateButton(f, self.L["Start session"], 110, 22)
    f.startBtn:SetPoint("BOTTOM", -28, 14)
    f.startBtn:SetScript("OnClick", function()
        self:CmdStartFromBags()
        self:RefreshSessionFrame()
    end)

    f.endBtn = self:CreateButton(f, self.L["End session"], 96, 22)
    f.endBtn:SetPoint("BOTTOMRIGHT", -16, 14)
    f.endBtn:SetScript("OnClick", function()
        self:EndSession()
        self:RefreshSessionFrame()
    end)

    self.sessionFrame = f
    return f
end

-- One councilable-item preview row: icon + colored link.
function LCEX:BuildSessionRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(22)
    row.icon = self:CreateItemIcon(row, 18)
    row.icon:SetPoint("LEFT", 0, 0)
    row.name = self:CreateLabel(row, nil, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(300); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
    return row
end

-- Re-read state + the bag preview and repaint.
function LCEX:RefreshSessionFrame()
    local f = self.sessionFrame
    if not f then return end

    if self.session then
        f.status:SetText(string.format(self.L["Session active — %d item(s)."], #self.session.items))
    end

    for _, row in ipairs(f.rows) do row:Hide() end
    local list = self:BuildCouncilableList()

    if not self.session then
        if #list == 0 then
            f.status:SetText(self.L["Nothing councilable in your bags."])
        else
            f.status:SetText(string.format(self.L["%d councilable item(s) in your bags."], #list))
        end
    end

    local y = -62
    for i, it in ipairs(list) do
        local row = f.rows[i] or self:BuildSessionRow(f)
        f.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
        row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, y)
        local icon = GetItemInfoInstant and select(5, GetItemInfoInstant(it.link))
        row.icon:SetItem(it.link, icon)
        row.name:SetText(it.link)
        row:Show()
        y = y - 24
    end

    -- Start only makes sense with items and no open session; End only with one.
    if self.session then f.startBtn:Disable() else f.startBtn:Enable() end
    if self.session then f.endBtn:Enable() else f.endBtn:Disable() end
end

-- /lcex (bare) / /lcex show — toggle the ML panel.
function LCEX:ToggleSessionFrame()
    local f = self:EnsureSessionFrame()
    if f:IsShown() then
        f:Hide()
    else
        self:RefreshSessionFrame()
        f:Show()
    end
end
