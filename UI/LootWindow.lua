-- ── LootCouncil EX — UI/LootWindow.lua ───────────────────────────────────────
-- The `loot` frame: everything used during a session, two-pane. Left rail = the item list —
-- an EDITABLE STAGING LIST while no session is open (bag-scan auto-populate, add by
-- shift-click/itemID, per-row remove), frozen into the session at Start (indices lock —
-- uid = sid:index). Right pane = the candidate response/vote table for the selected item,
-- with per-row Award (ML only). Bottom bar = session status + Start/End.
--
-- Data flow: candidates' cResp aggregate on the ML → cUpdate → Core mirrors into
-- LCEX.voteRows[index] → RefreshLootItem(index) repaints here. Votes go out through
-- SendVote; awards through AwardItem. Award progress renders from activeSession.awarded
-- (set ML-side in AwardItem, receiver-side in dispatch.award).
--
-- Loads after UI/Theme.lua + UI/Widgets.lua; before Core/session/Candidate + Council.

local LCEX = LootCouncilEX

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_LootWindow"
local RAIL_W     = 236
local BAR_H      = 34 -- bottom bar

LCEX.stagingItems = LCEX.stagingItems or {}

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

-- Plain [Name] from a link, or the raw string.
local function LinkName(link)
    return tostring(link):match("%[(.-)%]") or tostring(link)
end

-- The item list the rail renders: the live session's wire items, else the staging list.
function LCEX:LootRailItems()
    local a = self.activeSession
    if a and a.items then return a.items, true end
    return self.stagingItems, false
end

-- ── Frame shell ──────────────────────────────────────────────────────────────
function LCEX:EnsureLootWindow()
    if self.lootWindow then return self.lootWindow end
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = 780, height = 470,
        title = self.L["Loot Session"],
        savedKey = "loot",
        defaultPos = { x = 0, y = 40 },
    })

    -- Left rail --------------------------------------------------------------
    local rail = CreateFrame("Frame", nil, f)
    rail:SetPoint("TOPLEFT", 2, -32)
    rail:SetPoint("BOTTOMLEFT", 2, BAR_H + 2)
    rail:SetWidth(RAIL_W)
    self:Surface(rail, "base")
    f.rail = rail

    f.railList = self:CreateScrollList(rail, {
        rowHeight = 30, width = RAIL_W - 4, fillHeight = true,
        buildRow = function(parent) return self:BuildLootRailRow(parent) end,
        fillRow  = function(row, entry, index) self:FillLootRailRow(row, entry, index) end,
    })
    f.railList:SetPoint("TOPLEFT", 2, -30)
    f.railList:SetPoint("BOTTOMRIGHT", -2, 58)

    f.railHeader = rail:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.railHeader, "caption", "faint")
    f.railHeader:SetPoint("TOPLEFT", 12, -10)

    -- Staging controls (hidden while a session is open).
    f.scanBtn = self:CreateFlatButton(rail, self.L["Scan bags"], RAIL_W - 16, 22)
    f.scanBtn:SetPoint("BOTTOMLEFT", 8, 30)
    f.scanBtn:SetScript("OnClick", function() self:LootStageScan() end)

    f.addBox = self:CreateEditBox(rail, {
        width = RAIL_W - 20,
        onCommit = function(text) self:LootStageAdd(text) end,
    })
    f.addBox:SetPoint("BOTTOMLEFT", 12, 6)

    -- Right pane ---------------------------------------------------------------
    local pane = CreateFrame("Frame", nil, f)
    pane:SetPoint("TOPLEFT", rail, "TOPRIGHT", 4, 0)
    pane:SetPoint("BOTTOMRIGHT", -2, BAR_H + 2)
    self:Surface(pane, "page")
    f.pane = pane

    f.itemIcon = self:CreateItemIcon(pane, 30)
    f.itemIcon:SetPoint("TOPLEFT", 12, -8)

    f.itemName = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.itemName, "section", "ink")
    f.itemName:SetPoint("LEFT", f.itemIcon, "RIGHT", 10, 0)
    f.itemName:SetJustifyH("LEFT")
    f.itemName:SetWordWrap(false)

    f.itemCount = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.itemCount, "caption", "faint")
    f.itemCount:SetPoint("TOPRIGHT", -12, -16)
    f.itemName:SetPoint("RIGHT", f.itemCount, "LEFT", -8, 0)

    f.empty = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.empty, "body", "faint")
    f.empty:SetPoint("TOP", 0, -110)
    f.empty:SetText(self.L["No responses yet."])
    f.empty:Hide()

    f.candList = self:CreateScrollList(pane, {
        rowHeight = 26, width = 480, fillHeight = true,
        buildRow = function(parent) return self:BuildLootCandRow(parent) end,
        fillRow  = function(row, entry) self:FillLootCandRow(row, entry) end,
    })
    f.candList:SetPoint("TOPLEFT", 8, -48)
    f.candList:SetPoint("BOTTOMRIGHT", -8, 8)

    -- Bottom bar ---------------------------------------------------------------
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("BOTTOMLEFT", 2, 2)
    bar:SetPoint("BOTTOMRIGHT", -2, 2)
    bar:SetHeight(BAR_H)
    self:Surface(bar, "raised")
    f.bottomBar = bar

    f.status = bar:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.status, "body", "dim")
    f.status:SetPoint("LEFT", 12, 0)

    f.endBtn = self:CreateFlatButton(bar, self.L["End session"], 100, 22, "danger")
    f.endBtn:SetPoint("RIGHT", -8, 0)
    f.endBtn:SetScript("OnClick", function()
        self:EndSession()
        self:RefreshLootWindow()
    end)

    f.startBtn = self:CreateFlatButton(bar, self.L["Start session"], 110, 22, "accent")
    f.startBtn:SetPoint("RIGHT", f.endBtn, "LEFT", -6, 0)
    f.startBtn:SetScript("OnClick", function() self:LootStartStaged() end)

    self.lootWindow = f
    return f
end

-- ── Left rail rows ───────────────────────────────────────────────────────────
function LCEX:BuildLootRailRow(parent)
    local row = CreateFrame("Button", nil, parent)
    self:Surface(row, "base")

    row.sel = row:CreateTexture(nil, "ARTWORK")
    row.sel:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.sel:SetWidth(2)
    row.sel:SetPoint("TOPLEFT", 0, 0)
    row.sel:SetPoint("BOTTOMLEFT", 0, 0)
    row.sel:SetVertexColor(self.Theme.accent[1], self.Theme.accent[2], self.Theme.accent[3], 1)
    row.sel:Hide()

    row.icon = self:CreateItemIcon(row, 22)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.name, "body", "ink")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.badge = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.badge, "caption", "faint")
    row.badge:SetPoint("RIGHT", -24, 0)
    row.name:SetPoint("RIGHT", row.badge, "LEFT", -6, 0)

    -- Staging-only remove ×.
    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(16, 16)
    row.remove:SetPoint("RIGHT", -4, 0)
    row.remove.fs = row.remove:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.remove.fs, "body", "faint")
    row.remove.fs:SetPoint("CENTER", 0, 0)
    row.remove.fs:SetText("×")
    row.remove:SetScript("OnEnter", function(b)
        b.fs:SetTextColor(LCEX.Theme.danger[1], LCEX.Theme.danger[2], LCEX.Theme.danger[3])
    end)
    row.remove:SetScript("OnLeave", function(b) LCEX:ThemeText(b.fs, "body", "faint") end)
    row.remove:SetScript("OnClick", function() LCEX:LootStageRemove(row.index) end)

    row:SetScript("OnClick", function()
        LCEX:LootSelectItem(row.index)
    end)
    return row
end

function LCEX:FillLootRailRow(row, entry, index)
    row.index = index
    local icon = GetItemInfoInstant and select(5, GetItemInfoInstant(entry.link))
    row.icon:SetItem(entry.link, icon)
    local q = self:QualityColor(entry.quality)
    row.name:SetText(LinkName(entry.link))
    row.name:SetTextColor(q[1], q[2], q[3])

    local f = self.lootWindow
    local a = self.activeSession
    if a then
        row.remove:Hide()
        local awardedTo = a.awarded and a.awarded[index]
        if awardedTo then
            row.badge:SetText("✓ " .. DisplayName(nil, awardedTo))
            row.badge:SetTextColor(self.Theme.success[1], self.Theme.success[2], self.Theme.success[3])
        else
            local n = 0
            local rows = self.voteRows and self.voteRows[index]
            if rows then for _ in pairs(rows) do n = n + 1 end end
            row.badge:SetText(tostring(n))
            self:ThemeText(row.badge, "caption", "faint")
        end
    else
        row.remove:Show()
        row.badge:SetText("")
    end

    if f and f.selectedIndex == index then
        self:Surface(row, "overlay")
        row.sel:Show()
    else
        self:Surface(row, "base")
        row.sel:Hide()
    end
end

-- ── Right pane: candidate rows ───────────────────────────────────────────────
function LCEX:BuildLootCandRow(parent)
    local row = CreateFrame("Frame", nil, parent)

    row.name = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.name, "body", "ink")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetWidth(110); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)

    row.nameBtn = CreateFrame("Button", nil, row)
    row.nameBtn:SetPoint("LEFT", 4, 0)
    row.nameBtn:SetSize(110, 24)
    row.nameBtn:SetScript("OnClick", function()
        local n = row.name:GetText()
        if n and n ~= "" then LCEX:OpenPlayerDetail(n) end
    end)

    row.resp = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.resp, "body", "dim")
    row.resp:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    row.resp:SetWidth(52); row.resp:SetJustifyH("LEFT"); row.resp:SetWordWrap(false)

    row.gear = { self:CreateItemIcon(row, 18), self:CreateItemIcon(row, 18) }
    row.gear[1]:SetPoint("LEFT", row.resp, "RIGHT", 4, 0)
    row.gear[2]:SetPoint("LEFT", row.gear[1], "RIGHT", 2, 0)

    row.note = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.note, "caption", "faint")
    row.note:SetPoint("LEFT", row.gear[2], "RIGHT", 6, 0)
    row.note:SetJustifyH("LEFT"); row.note:SetWordWrap(false)

    row.award = self:CreateFlatButton(row, self.L["Award"], 56, 20, "accent")
    row.award:SetPoint("RIGHT", -2, 0)
    row.minus = self:CreateFlatButton(row, "−", 22, 20)
    row.minus:SetPoint("RIGHT", row.award, "LEFT", -8, 0)
    row.votes = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.votes, "body", "ink")
    row.votes:SetPoint("RIGHT", row.minus, "LEFT", -6, 0)
    row.votes:SetWidth(22); row.votes:SetJustifyH("CENTER")
    row.plus = self:CreateFlatButton(row, "+", 22, 20)
    row.plus:SetPoint("RIGHT", row.votes, "LEFT", -4, 0)
    row.note:SetPoint("RIGHT", row.plus, "LEFT", -6, 0)

    return row
end

function LCEX:FillLootCandRow(row, entry)
    local itemIndex, candKey, data = entry.itemIndex, entry.candKey, entry.data
    row.name:SetText(DisplayName(data, candKey))
    local cc = self:ClassColor(self:ClassOf(data.name or candKey) or self:CachedClass(data.name or candKey))
    row.name:SetTextColor(cc[1], cc[2], cc[3])

    local resp = ResponseEntry(self, data.resp)
    if resp then
        row.resp:SetText(resp.text)
        local c = resp.color
        if c then row.resp:SetTextColor(c[1], c[2], c[3]) end
    else
        row.resp:SetText("?")
        self:ThemeText(row.resp, "body", "faint")
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
    if v > 0 then row.votes:SetTextColor(self.Theme.success[1], self.Theme.success[2], self.Theme.success[3])
    elseif v < 0 then row.votes:SetTextColor(self.Theme.danger[1], self.Theme.danger[2], self.Theme.danger[3])
    else self:ThemeText(row.votes, "body", "dim") end

    -- Own pending vote → gold-tint the matching button's label.
    local a = self.activeSession
    local mine = a and a.myVotes and a.myVotes[itemIndex] and a.myVotes[itemIndex][candKey]
    local plusFs, minusFs = row.plus:GetFontString(), row.minus:GetFontString()
    if plusFs then
        if mine == 1 then plusFs:SetTextColor(self.Theme.accent[1], self.Theme.accent[2], self.Theme.accent[3])
        else plusFs:SetTextColor(self.Theme.text.ink[1], self.Theme.text.ink[2], self.Theme.text.ink[3]) end
    end
    if minusFs then
        if mine == -1 then minusFs:SetTextColor(self.Theme.accent[1], self.Theme.accent[2], self.Theme.accent[3])
        else minusFs:SetTextColor(self.Theme.text.ink[1], self.Theme.text.ink[2], self.Theme.text.ink[3]) end
    end

    row.plus:SetScript("OnClick", function() self:SendVote(itemIndex, candKey, 1) end)
    row.minus:SetScript("OnClick", function() self:SendVote(itemIndex, candKey, -1) end)

    -- Award is the ML's action only — only the ML's award is authoritative.
    if a and self:IsSelf(a.ml) then
        row.award:Show()
        row.award:SetScript("OnClick", function()
            if self:AwardItem(itemIndex, data.name or candKey) then
                self:RefreshLootWindow()
            end
        end)
    else
        row.award:Hide()
    end
end

-- ── Rendering ────────────────────────────────────────────────────────────────
function LCEX:LootSelectItem(index)
    local f = self.lootWindow
    if not f then return end
    f.selectedIndex = index
    self:RefreshLootWindow()
end

-- Full repaint: rail, right pane (for the selected item), bottom bar.
function LCEX:RefreshLootWindow()
    local f = self.lootWindow
    if not f or not f:IsShown() then return end
    local items, inSession = self:LootRailItems()

    -- Clamp/derive selection.
    if not f.selectedIndex or not items[f.selectedIndex] then
        f.selectedIndex = items[1] and 1 or nil
    end

    f.railHeader:SetText(inSession and self.L["SESSION ITEMS"] or self.L["STAGED ITEMS"])
    f.railList:SetData(items)

    if inSession then
        f.scanBtn:Hide(); f.addBox:Hide()
        f.startBtn:Hide(); f.endBtn:Show()
        f.status:SetText(string.format(self.L["Session active — %d item(s)."], #items))
    else
        f.scanBtn:Show(); f.addBox:Show()
        f.startBtn:Show(); f.endBtn:Hide()
        if #items == 0 then
            f.status:SetText(self.L["Nothing staged — scan your bags or add items."])
        else
            f.status:SetText(string.format(self.L["%d item(s) staged."], #items))
        end
    end

    -- Right pane: selected item header + candidate table.
    local entry = f.selectedIndex and items[f.selectedIndex]
    if entry then
        local icon = GetItemInfoInstant and select(5, GetItemInfoInstant(entry.link))
        f.itemIcon:SetItem(entry.link, icon)
        f.itemIcon:Show()
        local q = self:QualityColor(entry.quality)
        f.itemName:SetText(LinkName(entry.link))
        f.itemName:SetTextColor(q[1], q[2], q[3])
        f.itemCount:SetText(string.format("%d / %d", f.selectedIndex, #items))
    else
        f.itemIcon:Hide()
        f.itemName:SetText("")
        f.itemCount:SetText("")
    end

    local display = {}
    if inSession and f.selectedIndex then
        local rows = self.voteRows and self.voteRows[f.selectedIndex]
        if rows then
            local keys = {}
            for k in pairs(rows) do keys[#keys + 1] = k end
            table.sort(keys, function(x, y) return (rows[x].votes or 0) > (rows[y].votes or 0) end)
            for _, k in ipairs(keys) do
                display[#display + 1] = { itemIndex = f.selectedIndex, candKey = k, data = rows[k] }
            end
        end
    end
    f.candList:SetData(display)
    if inSession and #display == 0 then f.empty:Show() else f.empty:Hide() end
end

-- Core contract: a single item's aggregate changed (cUpdate / own vote / award). Rail badges
-- always move and the pane may be showing the item — a full repaint covers both cheaply at
-- this scale (a handful of pooled rows), so the index goes unused.
function LCEX:RefreshLootItem()
    self:RefreshLootWindow()
end

-- ── Staging actions ──────────────────────────────────────────────────────────
function LCEX:LootStageScan()
    self.stagingItems = self:BuildCouncilableList()
    self:RefreshLootWindow()
end

-- Add a shift-clicked link or a raw itemID to the staging list (resolves async if uncached).
function LCEX:LootStageAdd(text)
    text = strtrim(text or "")
    if text == "" then return end
    local link = text:match("(|c%x+|Hitem:.-|h|r)")
    local itemID = link and tonumber(link:match("item:(%d+)")) or tonumber(text)
    if not itemID then
        self:Msg(self.L["Couldn't read that item — shift-click a link or type an itemID."])
        return
    end
    self:WithItemID(itemID, function(name, resolvedLink, quality)
        if not name then
            self:Msg(self.L["Couldn't read that item — shift-click a link or type an itemID."])
            return
        end
        self.stagingItems[#self.stagingItems + 1] = {
            link = resolvedLink or link or ("item:" .. itemID),
            itemID = itemID, quality = quality or 4,
        }
        local f = self.lootWindow
        if f then f.addBox:SetText("") end
        self:RefreshLootWindow()
    end)
end

function LCEX:LootStageRemove(index)
    if self.activeSession then return end -- session lists are frozen (uid = sid:index)
    table.remove(self.stagingItems, index)
    self:RefreshLootWindow()
end

-- Start the session over the staged list: the staging records become sessionItems (full,
-- ML-side) and the wire list in the SAME order — the index invariant holds by construction.
function LCEX:LootStartStaged()
    if #self.stagingItems == 0 then
        self:Msg(self.L["Nothing staged — scan your bags or add items."])
        return
    end
    self.sessionItems = self.stagingItems
    local wire = {}
    for i, it in ipairs(self.stagingItems) do
        wire[i] = { link = it.link, quality = it.quality }
    end
    self:StartSession(wire)
    if self.session then self.stagingItems = {} end -- consumed (StartSession may refuse)
    self:RefreshLootWindow()
end

-- ── Entry points (Core contract) ─────────────────────────────────────────────
function LCEX:ShowLootWindow()
    local f = self:EnsureLootWindow()
    f.selectedIndex = nil -- re-derive from the current item list
    f:Show()
    self:RefreshLootWindow()
end

function LCEX:HideLootWindow()
    if self.lootWindow then self.lootWindow:Hide() end
end

function LCEX:ToggleLootWindow()
    local f = self:EnsureLootWindow()
    if f:IsShown() then
        f:Hide()
    else
        self:ShowLootWindow()
    end
end

-- Shift-clicking an item while our add box has focus inserts the link there (the chat edit
-- box owns that behavior natively; addon boxes must opt in).
if hooksecurefunc and ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        local f = LCEX.lootWindow
        if f and f.addBox and f.addBox:HasFocus() and link then
            f.addBox:SetText(link)
        end
    end)
end
