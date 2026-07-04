-- ── LootCouncil EX — UI/PollWindow.lua ───────────────────────────────────────
-- The `poll` frame: what a raider sees when a session starts. RCLC-style cards — one per
-- session item the player can actually use (Core/Usable.lua filter), max 3 visible, stacked.
-- Answering a card removes it and the queue shifts UP, so the TOP slot always holds the next
-- item: mash one spot to pass on everything. Each card carries its own note box; the note
-- rides with that item's cResp (notes follow their item when cards shift slots).
--
-- An optional session deadline (sStart `timeout`, set by the ML in Session Config) drives a
-- prominent depleting bar below the title (green → gold → red) with the seconds remaining; at
-- expiry the poll closes silently (no response sent — the ML's table simply shows no response).
-- When the usable queue is longer than the visible cards, a "+N more" footer shows the overflow.
--
-- Layout uses one uniform PAD everywhere (window edge ↔ content, and the gap between cards).
--
-- Data flow: Candidate.lua EnterSession → ShowPoll(items, responses, secondsLeft); a button
-- click → OnResponseChosen(itemIndex, resp, note) → cResp to the ML. LeaveSession → HidePoll.
--
-- Loads after UI/Theme.lua + UI/Widgets.lua.

local LCEX = LootCouncilEX
LCEX.pollNotes = LCEX.pollNotes or {}

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_PollWindow"
local MAX_CARDS  = 3
local PAD        = 10   -- the ONE margin: window edge ↔ content, and the gap between cards
local CARD_W     = 380
local CARD_H     = 78
local TITLE_H    = 30   -- CreateWindowV2's title bar (28px) + its 2px top inset — content below
local TIMER_H    = 12   -- deadline depleting bar (present only when a deadline is armed)
local MORE_H     = 16   -- "+N more" footer (present only when the queue exceeds MAX_CARDS)

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
        width = CARD_W + 2 * PAD, height = 200,
        title = self.L["Loot Drop"],
        savedKey = "poll",
        defaultPos = { x = 0, y = 220 },
    })

    -- Deadline bar: a depleting fill + centered "Ns left". Sits in the content area (below the
    -- title bar), so — unlike a title-bar overlay — it actually renders. Shown only when armed.
    local bar = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    bar:SetHeight(TIMER_H)
    self:Surface(bar, "base")
    self:SoftEdge(bar, 0.12)
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar.fill:SetPoint("TOPLEFT", 1, -1)
    bar.fill:SetPoint("BOTTOMLEFT", 1, 1)
    bar.text = bar:CreateFontString(nil, "OVERLAY")
    self:ThemeText(bar.text, "caption", "ink")
    local tf, tsz = bar.text:GetFont()
    if tf then bar.text:SetFont(tf, tsz, "OUTLINE") end -- thin outline: readable over the fill
    bar.text:SetPoint("CENTER", 0, 0)
    bar:Hide()
    f.timerBar = bar

    f.empty = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.empty, "body", "faint")
    f.empty:SetPoint("TOP", 0, -(TITLE_H + 20))
    f.empty:SetText(self.L["Nothing for you this round."])
    f.empty:Hide()

    -- Overflow footer: how many queued items are hidden below the visible cards.
    f.more = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.more, "caption", "faint")
    f.more:Hide()

    f.cards = {}
    self.pollFrame = f
    return f
end

-- One card: icon | name over a response-button row, with a full-width note box beneath. The
-- card's OUTER position + width are set each render (RenderPollCards); this only builds it.
function LCEX:BuildPollCard(parent)
    local card = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    card:SetHeight(CARD_H)
    self:Surface(card, "raised")
    self:SoftEdge(card, 0.1)

    card.icon = self:CreateItemIcon(card, 32)
    card.icon:SetPoint("TOPLEFT", PAD, -PAD)

    card.name = card:CreateFontString(nil, "OVERLAY")
    self:ThemeText(card.name, "body", "ink")
    card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -1)
    card.name:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)

    card.buttons = {}

    -- Full-width note under the icon/buttons: TOPLEFT + RIGHT anchors override CreateEditBox's
    -- default width so it fills the card.
    card.note = self:CreateEditBox(card, {})
    card.note:SetPoint("TOPLEFT", card, "TOPLEFT", PAD + 4, -54)
    card.note:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
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
        b:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10 + x, -20)
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

-- Re-render from the head of the queue: position the deadline bar (if armed), the visible cards,
-- and the "+N more" footer, then shrink the window to exactly fit. Renders from the poll's OWN
-- stored items/responses (set by ShowPoll), so it doesn't depend on a live activeSession.
function LCEX:RenderPollCards()
    local f = self.pollFrame
    if not f then return end
    local queue = self.pollQueue or {}
    local items = self._pollItems or {}
    local responses = self._pollResponses or self.RESPONSES

    -- Deadline bar below the title bar (when armed); it shifts everything below it down.
    local top = TITLE_H + PAD
    if f.deadline then
        f.timerBar:ClearAllPoints()
        f.timerBar:SetPoint("TOPLEFT", PAD, -top)
        f.timerBar:SetWidth(CARD_W)
        f.timerBar:Show()
        self:UpdatePollCountdown()
        top = top + TIMER_H + PAD
    else
        f.timerBar:Hide()
    end

    local shown = 0
    for slot = 1, MAX_CARDS do
        local card = f.cards[slot]
        local itemIndex = queue[slot]
        local item = itemIndex and items[itemIndex]
        if item then
            if not card then card = self:BuildPollCard(f); f.cards[slot] = card end
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", PAD, -(top + (slot - 1) * (CARD_H + PAD)))
            card:SetWidth(CARD_W)
            self:FillPollCard(card, itemIndex, item, responses)
            shown = shown + 1
        elseif card then
            card.itemIndex = nil
            card:Hide()
        end
    end

    local bottom = top + math.max(1, shown) * CARD_H + math.max(0, shown - 1) * PAD

    local extra = #queue - shown
    if extra > 0 then
        -- Left-justified, vertically centered in a MORE_H band a PAD below the last card. The
        -- "LEFT" anchor point puts the text's vertical centre on the y, so it reads as centered.
        f.more:ClearAllPoints()
        f.more:SetPoint("LEFT", f, "TOPLEFT", PAD + 4, -(bottom + PAD + MORE_H / 2))
        f.more:SetText(string.format(self.L["+ %d more"], extra))
        f.more:Show()
        bottom = bottom + PAD + MORE_H
    else
        f.more:Hide()
    end

    if shown == 0 then f.empty:Show() else f.empty:Hide() end
    f:SetHeight(bottom + PAD)
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
    if not f or not f.deadline or not f.deadlineTotal then return end
    local left = f.deadline - GetTime()
    if left <= 0 then
        self:HidePoll() -- expiry: close silently; no response is sent
        return
    end
    local frac = math.max(0, math.min(1, left / f.deadlineTotal))
    local col = self.Theme.success
    if frac <= 0.25 then col = self.Theme.danger
    elseif frac <= 0.5 then col = self.Theme.accent end
    f.timerBar.fill:SetWidth(math.max(1, (f.timerBar:GetWidth() - 2) * frac))
    f.timerBar.fill:SetVertexColor(col[1], col[2], col[3], 0.85)
    f.timerBar.text:SetText(string.format(self.L["%ds left"], math.ceil(left)))
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
        f.deadlineTotal = secondsLeft
        self.pollTicker = self:ScheduleRepeatingTimer("UpdatePollCountdown", 0.5)
    else
        f.deadline, f.deadlineTotal = nil, nil
    end

    self:RenderPollCards() -- lays out the (armed) timer bar + cards, then sizes the window
    f:Show()
end

function LCEX:HidePoll()
    if self.pollTicker then self:CancelTimer(self.pollTicker); self.pollTicker = nil end
    if self.pollFrame then
        self.pollFrame.deadline, self.pollFrame.deadlineTotal = nil, nil
        self.pollFrame:Hide()
    end
    self.pollQueue, self.pollNotes = nil, {}
end
