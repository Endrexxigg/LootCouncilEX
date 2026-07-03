-- ── LootCouncil EX — UI/PollWindow.lua ───────────────────────────────────────
-- The `poll` frame: what a raider sees when a session starts. RCLC-style cards — one per
-- session item the player can actually use (Core/Usable.lua filter), max 3 visible, stacked.
-- Answering a card removes it and the queue shifts UP, so the TOP slot always holds the next
-- item: mash one spot to pass on everything. Each card carries its own note box; the note
-- rides with that item's cResp (notes follow their item when cards shift slots).
--
-- An optional session deadline (sStart `timeout`, set by the ML in Session Config) shows a
-- countdown in the header; at expiry the poll closes silently (no response sent — the ML's
-- table simply shows no response).
--
-- Data flow: Candidate.lua EnterSession → ShowPoll(items, responses, secondsLeft); a button
-- click → OnResponseChosen(itemIndex, resp, note) → cResp to the ML. LeaveSession → HidePoll.
--
-- Loads after UI/Theme.lua + UI/Widgets.lua.

local LCEX = LootCouncilEX
LCEX.pollNotes = LCEX.pollNotes or {}

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME  = "LCEX_PollWindow"
local MAX_CARDS   = 3
local CARD_W      = 380
local CARD_H      = 88
local CARD_GAP    = 6
local HEADER_H    = 34 -- window title bar + countdown line

-- Remove `itemIndex` (a VALUE, not a position) from the queue. Pure — headless-tested.
function LCEX:_PollQueueRemove(queue, itemIndex)
    for i = #queue, 1, -1 do
        if queue[i] == itemIndex then table.remove(queue, i) end
    end
    return queue
end

-- The usable subset of a session's wire items, as item INDICES in session order. Pure given
-- PlayerCanUse — headless-tested.
function LCEX:_BuildPollQueue(items)
    local queue = {}
    for i, it in ipairs(items or {}) do
        if self:PlayerCanUse(it.link) then queue[#queue + 1] = i end
    end
    return queue
end

-- ── Frame ────────────────────────────────────────────────────────────────────
function LCEX:EnsurePoll()
    if self.pollFrame then return self.pollFrame end
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = CARD_W + 24, height = 200,
        title = self.L["Loot Drop"],
        savedKey = "poll",
        defaultPos = { x = 0, y = 220 },
    })

    f.countdown = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.countdown, "caption", "dim")
    f.countdown:SetPoint("RIGHT", f.closeButton, "LEFT", -8, 0)

    f.empty = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.empty, "body", "faint")
    f.empty:SetPoint("TOP", 0, -(HEADER_H + 26))
    f.empty:SetText(self.L["Nothing for you this round."])
    f.empty:Hide()

    f.cards = {}
    self.pollFrame = f
    return f
end

-- One card: icon | name + response buttons + note box. Buttons are (re)built per fill from
-- the session's response set (data-driven, PROJECT.md §6.5).
function LCEX:BuildPollCard(parent, slot)
    local card = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    card:SetSize(CARD_W, CARD_H)
    card:SetPoint("TOP", parent, "TOP", 0, -(HEADER_H + (slot - 1) * (CARD_H + CARD_GAP)))
    self:Surface(card, "raised")
    self:SoftEdge(card, 0.1)

    card.icon = self:CreateItemIcon(card, 34)
    card.icon:SetPoint("TOPLEFT", 12, -12)

    card.name = card:CreateFontString(nil, "OVERLAY")
    self:ThemeText(card.name, "body", "ink")
    card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -2)
    card.name:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)

    card.buttons = {}

    card.note = self:CreateEditBox(card, { width = CARD_W - 70 })
    card.note:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 14, -26)
    card.note:SetScript("OnTextChanged", function(eb)
        -- Notes are keyed by ITEM index so they follow the item when cards shift slots.
        if card.itemIndex then LCEX.pollNotes[card.itemIndex] = eb:GetText() end
    end)
    return card
end

function LCEX:FillPollCard(card, itemIndex, item, responses)
    card.itemIndex = itemIndex

    local icon = GetItemInfoInstant and select(5, GetItemInfoInstant(item.link))
    card.icon:SetItem(item.link, icon)

    local q = self:QualityColor(item.quality)
    card.name:SetText(tostring(item.link):match("%[(.-)%]") or item.link)
    card.name:SetTextColor(q[1], q[2], q[3])

    for _, b in ipairs(card.buttons) do b:Hide() end
    local x = 0
    for ri, resp in ipairs(responses) do
        local b = card.buttons[ri]
        if not b then
            b = self:CreateFlatButton(card, "", 58, 20)
            card.buttons[ri] = b
        end
        b:SetText(resp.text)
        local c = resp.color
        local fs = b:GetFontString()
        if c and fs then fs:SetTextColor(c[1], c[2], c[3]) end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10 + x, -22)
        b:SetScript("OnClick", function()
            self:OnResponseChosen(card.itemIndex, resp, self.pollNotes[card.itemIndex] or "")
            self:PollCardAnswered(card.itemIndex)
        end)
        b:Show()
        x = x + 62
    end

    card.note:SetText(self.pollNotes[itemIndex] or "")
    card:Show()
end

-- Re-render the visible slots from the head of the queue and shrink the window to fit.
-- Renders from the poll's OWN stored items/responses (set by ShowPoll), so it doesn't depend
-- on a live activeSession.
function LCEX:RenderPollCards()
    local f = self.pollFrame
    if not f then return end
    local queue = self.pollQueue or {}
    local items = self._pollItems or {}
    local responses = self._pollResponses or self.RESPONSES

    local shown = 0
    for slot = 1, MAX_CARDS do
        local card = f.cards[slot]
        local itemIndex = queue[slot]
        local item = itemIndex and items[itemIndex]
        if item then
            if not card then
                card = self:BuildPollCard(f, slot)
                f.cards[slot] = card
            end
            self:FillPollCard(card, itemIndex, item, responses)
            shown = shown + 1
        elseif card then
            card.itemIndex = nil
            card:Hide()
        end
    end

    if shown == 0 then f.empty:Show() else f.empty:Hide() end
    f:SetHeight(HEADER_H + math.max(1, shown) * (CARD_H + CARD_GAP) + 10)
end

-- A card was answered: drop that item from the queue; if that was the last one, close.
function LCEX:PollCardAnswered(itemIndex)
    self:_PollQueueRemove(self.pollQueue or {}, itemIndex)
    self.pollNotes[itemIndex] = nil
    if #(self.pollQueue or {}) == 0 then
        self:HidePoll()
    else
        self:RenderPollCards()
    end
end

-- ── Deadline countdown ───────────────────────────────────────────────────────
function LCEX:UpdatePollCountdown()
    local f = self.pollFrame
    if not f or not f.deadline then return end
    local left = math.floor(f.deadline - GetTime() + 0.5)
    if left <= 0 then
        self:HidePoll() -- expiry: close silently; no response is sent
    else
        f.countdown:SetText(string.format(self.L["%ds left"], left))
    end
end

-- ── Entry points (Core contract) ─────────────────────────────────────────────
-- Open the poll over the session's wire items. `secondsLeft` (optional) arms the deadline.
function LCEX:ShowPoll(items, responses, secondsLeft)
    local f = self:EnsurePoll()
    self.pollQueue = self:_BuildPollQueue(items)
    self.pollNotes = {}
    self._pollItems = items
    self._pollResponses = responses

    if self.pollTicker then self:CancelTimer(self.pollTicker); self.pollTicker = nil end
    if secondsLeft and secondsLeft > 0 then
        f.deadline = GetTime() + secondsLeft
        self.pollTicker = self:ScheduleRepeatingTimer("UpdatePollCountdown", 1)
        self:UpdatePollCountdown()
    else
        f.deadline = nil
        f.countdown:SetText("")
    end

    self:RenderPollCards()
    f:Show()
end

function LCEX:HidePoll()
    if self.pollTicker then self:CancelTimer(self.pollTicker); self.pollTicker = nil end
    if self.pollFrame then
        self.pollFrame.deadline = nil
        self.pollFrame:Hide()
    end
    self.pollQueue, self.pollNotes = nil, {}
end
