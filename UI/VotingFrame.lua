-- ── LootCouncil EX — UI/VotingFrame.lua ──────────────────────────────────────
-- Council side (Plane A): the table a council member uses to see candidates' responses and
-- cast votes. Driven by session/Council.lua — opened on session entry (if we're council),
-- fed by cUpdate via LCEX:ApplyCUpdate → RefreshVotingItem, and votes go back out as vVote.
--
-- One item at a time (Prev/Next), with a row per responding candidate: name, response,
-- competing gear, note, the running vote tally, and +/− vote buttons. Renders from
-- self.voteRows[index] (the client-side mirror of the ML's authoritative rows) and the
-- candidate's own pending vote from activeSession.myVotes.
--
-- Loads after UI/Widgets.lua (uses the window/button/icon factory).

local LCEX = LootCouncilEX

-- GetItemInfoInstant: synchronous, never-nil; on Anniversary it may live under C_Item.
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_VotingFrame"

-- The RESPONSES entry for a response id, from this session's set (falls back to defaults).
local function ResponseEntry(self, id)
    local set = (self.activeSession and self.activeSession.responses) or self.RESPONSES
    for _, r in ipairs(set) do
        if r.id == id then return r end
    end
    return nil
end

-- Bare display name (strip a realm suffix, keep case) for a stored row / key.
local function DisplayName(row, key)
    return ((row and row.name) or key or "?"):match("^[^%-]+")
end

function LCEX:EnsureVotingFrame()
    if self.votingFrame then return self.votingFrame end
    local f = self:CreateWindow(FRAME_NAME, {
        width = 520, height = 320,
        title = self.L["LootCouncil EX — Council"],
        savedKey = "votingFrame",
    })
    f.candRows = {}

    -- Item navigator: < [item] (i/N) >
    f.prev = self:CreateButton(f, "<", 24, 22)
    f.prev:SetPoint("TOPLEFT", 16, -40)
    f.prev:SetScript("OnClick", function() self:VotingStep(-1) end)

    f.next = self:CreateButton(f, ">", 24, 22)
    f.next:SetPoint("TOPRIGHT", -16, -40)
    f.next:SetScript("OnClick", function() self:VotingStep(1) end)

    f.itemLabel = self:CreateLabel(f, nil, "GameFontNormal")
    f.itemLabel:SetPoint("LEFT", f.prev, "RIGHT", 8, 0)
    f.itemLabel:SetPoint("RIGHT", f.next, "LEFT", -8, 0)
    f.itemLabel:SetJustifyH("CENTER")
    f.itemLabel:SetWordWrap(false)

    f.empty = self:CreateLabel(f, self.L["No responses yet."], "GameFontDisable")
    f.empty:SetPoint("TOP", 0, -80)

    self.votingFrame = f
    return f
end

-- One candidate row: name | response | gear icons | note | votes | + | −.
function LCEX:BuildCandRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(24)

    row.name = self:CreateLabel(row, nil, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 2, 0)
    row.name:SetWidth(96); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)

    -- Clicking the name opens the player detail panel (§7). A transparent button over JUST the
    -- name region, so it never steals clicks from the +/-/Award buttons (separate children).
    row.nameBtn = CreateFrame("Button", nil, row)
    row.nameBtn:SetPoint("LEFT", 2, 0)
    row.nameBtn:SetSize(96, 22)
    row.nameBtn:SetScript("OnClick", function()
        local n = row.name:GetText()
        if n and n ~= "" then self:OpenPlayerDetail(n) end
    end)

    row.resp = self:CreateLabel(row, nil, "GameFontNormalSmall")
    row.resp:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
    row.resp:SetWidth(52); row.resp:SetJustifyH("LEFT"); row.resp:SetWordWrap(false)

    row.gear = { self:CreateItemIcon(row, 18), self:CreateItemIcon(row, 18) }
    row.gear[1]:SetPoint("LEFT", row.resp, "RIGHT", 2, 0)
    row.gear[2]:SetPoint("LEFT", row.gear[1], "RIGHT", 2, 0)

    row.note = self:CreateLabel(row, nil, "GameFontDisableSmall")
    row.note:SetPoint("LEFT", row.gear[2], "RIGHT", 4, 0)
    row.note:SetWidth(110); row.note:SetJustifyH("LEFT"); row.note:SetWordWrap(false)

    row.award = self:CreateButton(row, self.L["Award"], 56, 20)
    row.award:SetPoint("RIGHT", -2, 0)
    row.minus = self:CreateButton(row, "−", 22, 20)
    row.minus:SetPoint("RIGHT", row.award, "LEFT", -6, 0)
    row.votes = self:CreateLabel(row, nil, "GameFontHighlight")
    row.votes:SetPoint("RIGHT", row.minus, "LEFT", -4, 0)
    row.votes:SetWidth(24); row.votes:SetJustifyH("CENTER")
    row.plus = self:CreateButton(row, "+", 22, 20)
    row.plus:SetPoint("RIGHT", row.votes, "LEFT", -2, 0)

    return row
end

-- Fill a candidate row for `candKey` from its stored `data`, wiring the vote buttons.
function LCEX:FillCandRow(row, itemIndex, candKey, data)
    row.candKey = candKey
    row.name:SetText(DisplayName(data, candKey))

    -- Class-color the name: live class while grouped, else the class from their last cached
    -- self-report (PlayerDetail's resolvers). Rows are pooled — reset to the default highlight
    -- white when no class resolves, or a reused row keeps the previous candidate's color.
    local class = self:ClassOf(data.name or candKey) or self:CachedClass(data.name or candKey)
    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if cc then
        row.name:SetTextColor(cc.r, cc.g, cc.b)
    else
        row.name:SetTextColor(1, 1, 1)
    end

    local resp = ResponseEntry(self, data.resp)
    if resp then
        row.resp:SetText(resp.text)
        local c = resp.color
        if c then row.resp:SetTextColor(c[1], c[2], c[3]) end
    else
        row.resp:SetText("?"); row.resp:SetTextColor(0.7, 0.7, 0.7)
    end

    local gear = data.gear or {}
    for i = 1, 2 do
        local ic = row.gear[i]
        local link = gear[i]
        if link then
            local icon = GetItemInfoInstant and select(5, GetItemInfoInstant(link))
            ic:SetItem(link, icon)
            ic:Show()
        else
            ic:Hide()
        end
    end

    row.note:SetText((data.note and data.note ~= "" and data.note) or "")

    local v = data.votes or 0
    row.votes:SetText(tostring(v))
    if v > 0 then row.votes:SetTextColor(0.2, 1, 0.2)
    elseif v < 0 then row.votes:SetTextColor(1, 0.3, 0.3)
    else row.votes:SetTextColor(0.8, 0.8, 0.8) end

    -- Own pending vote → highlight the matching button.
    local a = self.activeSession
    local mine = a and a.myVotes and a.myVotes[itemIndex] and a.myVotes[itemIndex][candKey]
    row.plus:UnlockHighlight(); row.minus:UnlockHighlight()
    if mine == 1 then row.plus:LockHighlight() elseif mine == -1 then row.minus:LockHighlight() end

    row.plus:SetScript("OnClick", function() self:SendVote(itemIndex, candKey, 1) end)
    row.minus:SetScript("OnClick", function() self:SendVote(itemIndex, candKey, -1) end)

    -- Award is the ML's action only — only the ML's award is authoritative.
    if a and self:IsSelf(a.ml) then
        row.award:Show()
        row.award:SetScript("OnClick", function() self:AwardItem(itemIndex, data.name or candKey) end)
    else
        row.award:Hide()
    end
end

-- Render the candidate rows for the currently-selected item.
function LCEX:RenderVotingRows()
    local f = self.votingFrame
    if not f then return end
    local a = self.activeSession
    local index = f.currentIndex or 1
    local items = a and a.items

    for _, row in ipairs(f.candRows) do row:Hide() end

    if items and items[index] then
        f.itemLabel:SetText(string.format("%s  (%d/%d)", items[index].link, index, #items))
    else
        f.itemLabel:SetText("")
    end

    local rows = self.voteRows and self.voteRows[index]
    local keys = {}
    if rows then for k in pairs(rows) do keys[#keys + 1] = k end end
    table.sort(keys, function(x, y)
        return (rows[x].votes or 0) > (rows[y].votes or 0)
    end)

    if #keys == 0 then f.empty:Show() else f.empty:Hide() end

    local y = -70
    for n, candKey in ipairs(keys) do
        local row = f.candRows[n] or self:BuildCandRow(f)
        f.candRows[n] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
        row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, y)
        self:FillCandRow(row, index, candKey, rows[candKey])
        row:Show()
        y = y - 26
    end

    f:SetHeight(math.max(180, 80 + math.max(1, #keys) * 26 + 24))
end

-- Step the selected item by `delta`, clamped.
function LCEX:VotingStep(delta)
    local f = self.votingFrame
    local a = self.activeSession
    if not f or not a or not a.items then return end
    local n = #a.items
    f.currentIndex = math.min(n, math.max(1, (f.currentIndex or 1) + delta))
    self:RenderVotingRows()
end

-- Open the council frame over the session items (council members only).
function LCEX:ShowVotingFrame(items)
    local f = self:EnsureVotingFrame()
    f.currentIndex = 1
    f.itemCount = items and #items or 0
    self:RenderVotingRows()
    f:Show()
end

-- Refresh the table if it is showing the item that just changed.
function LCEX:RefreshVotingItem(index)
    local f = self.votingFrame
    if f and f:IsShown() and (f.currentIndex or 1) == index then
        self:RenderVotingRows()
    end
end

function LCEX:HideVotingFrame()
    if self.votingFrame then self.votingFrame:Hide() end
end
