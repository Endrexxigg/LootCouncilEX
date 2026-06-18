-- ── LootCouncil EX — UI/LootFrame.lua ────────────────────────────────────────
-- Candidate side (Plane A): the frame a raider uses to respond to a loot session. Opened by
-- session/Candidate.lua on sStart with the session's items + response set. One row per item:
-- the item + a row of response buttons built from the session's RESPONSES (data-driven, never
-- hardcoded — PROJECT.md §6.5). Clicking a button sends a cResp to the ML (Candidate.lua).
--
-- Item name/colour come straight from the link string (self-contained, no GetItemInfo wait),
-- and the icon from GetItemInfoInstant — so rows never render blank on uncached items.
--
-- Loads after UI/Widgets.lua (uses LCEX:CreateWindow / CreateButton / CreateLabel / icon).

local LCEX = LootCouncilEX

-- GetItemInfoInstant is the synchronous, never-nil item lookup; on Anniversary it may live
-- under C_Item rather than the global (Gargul shims it the same way).
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_LootFrame"
local RESP_BTN_W = 58

-- Build the frame shell once; rows are created on demand and reused.
function LCEX:EnsureLootFrame()
    if self.lootFrame then return self.lootFrame end
    local f = self:CreateWindow(FRAME_NAME, {
        width = 560, height = 320,
        title = self.L["LootCouncil EX — Respond"],
        savedKey = "lootFrame",
    })
    f.rows = {}

    local noteLabel = self:CreateLabel(f, self.L["Note (sent with your response):"])
    noteLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 38)

    local note = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    note:SetSize(500, 20)
    note:SetPoint("TOPLEFT", noteLabel, "BOTTOMLEFT", 6, -4)
    note:SetAutoFocus(false)
    note:SetScript("OnEscapePressed", note.ClearFocus)
    note:SetScript("OnEnterPressed", note.ClearFocus)
    f.noteBox = note

    self.lootFrame = f
    return f
end

-- One item row: icon + colored item link + the response buttons.
function LCEX:BuildLootRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(self.STYLE.rowHeight)

    row.icon = self:CreateItemIcon(row, 24)
    row.icon:SetPoint("LEFT", 0, 0)

    row.name = self:CreateLabel(row, nil, "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(170)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.buttons = {}
    return row
end

-- Fill a row for item #index, wiring each response button to send a cResp on click and
-- LockHighlight the chosen one so the candidate sees their selection.
function LCEX:FillLootRow(row, index, item, responses)
    local _, _, _, _, icon = GetItemInfoInstant(item.link)
    row.icon:SetItem(item.link, icon)
    row.name:SetText(item.link) -- the link renders as the colored [Name]

    for _, b in ipairs(row.buttons) do b:Hide() end

    local x = 0
    for ri, resp in ipairs(responses) do
        local b = row.buttons[ri]
        if not b then
            b = self:CreateButton(row, "", RESP_BTN_W, 22)
            row.buttons[ri] = b
        end
        b:SetText(resp.text)
        local c = resp.color
        local fs = b:GetFontString()
        if c and fs then fs:SetTextColor(c[1], c[2], c[3]) end
        b:ClearAllPoints()
        b:SetPoint("LEFT", row.name, "RIGHT", 8 + x, 0)
        b:SetScript("OnClick", function()
            for _, sib in ipairs(row.buttons) do sib:UnlockHighlight() end
            b:LockHighlight()
            self:OnResponseChosen(index, resp)
        end)
        b:UnlockHighlight()
        b:Show()
        x = x + RESP_BTN_W + 2
    end
end

-- Open the frame over `items` (each { link, quality }) using `responses` for the buttons.
function LCEX:ShowLootFrame(items, responses)
    local f = self:EnsureLootFrame()
    responses = responses or self.RESPONSES

    for _, row in ipairs(f.rows) do row:Hide() end

    local y = -40
    for i, it in ipairs(items) do
        local row = f.rows[i] or self:BuildLootRow(f)
        f.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
        row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, y)
        self:FillLootRow(row, i, it, responses)
        row:Show()
        y = y - (self.STYLE.rowHeight + 2)
    end

    f:SetHeight(math.max(160, 50 + #items * (self.STYLE.rowHeight + 2) + 64))
    f.noteBox:SetText("")
    f:Show()
end

function LCEX:HideLootFrame()
    if self.lootFrame then self.lootFrame:Hide() end
end
