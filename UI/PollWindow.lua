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
-- Layout uses one uniform PAD everywhere (window edge ↔ content, and the gap between cards):
-- LAYOUT.grid, the bare-window content line. Card INTERIORS pad by LAYOUT.pad (cards are panels).
--
-- Data flow: Candidate.lua EnterSession → ShowPoll(items, responses, secondsLeft); a button
-- click → OnResponseChosen(itemIndex, resp, note) → cResp to the ML. LeaveSession → HidePoll.
--
-- Loads after UI/Theme.lua + UI/Widgets.lua.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)
LCEX.pollNotes = LCEX.pollNotes or {}

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_PollWindow"
local MAX_CARDS  = 3
local PAD        = LAY.grid -- the ONE margin: window edge ↔ content, and the gap between cards
local CARD_W     = 380
local CARD_H     = 78
local ICON_SZ    = 40 -- item icon; its 40px height spans the name row + the response-button row,
                      -- so the icon bottom meets the button-row bottom (aligned, item 3)
local HEADER_H   = 20 -- slim header strip: the poll shell is BARE (chromeless), so the header is
                      -- deliberately small — just a drag handle with the title + close
local TITLE_H    = LAY.edge + HEADER_H -- the header's bottom edge — content stacks below
local TIMER_H    = 12   -- deadline depleting bar (present only when a deadline is armed)
local MORE_H     = 16   -- "+N more" line under the last card (only when the queue overflows)

-- Remove `itemIndex` (a VALUE, not a position) from the queue. Pure — headless-tested.
function LCEX:_PollQueueRemove(queue, itemIndex)
    for i = #queue, 1, -1 do
        if queue[i] == itemIndex then table.remove(queue, i) end
    end
    return queue
end

-- The usable subset of a session's wire items, as GROUP-LEADER indices in session order (§6.14):
-- duplicate copies share one card, so a raider responds once per distinct item. Pure given
-- PlayerCanUse + BuildItemGroups — headless-tested.
function LCEX:_BuildPollQueue(items)
    local groups = self:BuildItemGroups(items)
    local queue = {}
    for _, leader in ipairs(groups.leaders) do
        if self:PlayerCanUse(items[leader].link) then queue[#queue + 1] = leader end
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
        -- Bare shell: no window backdrop/border and no mouse on the margins — mid-fight the poll
        -- reads as floating item cards + a slim header, not a big panel over the raid UI.
        bare = true, titleH = HEADER_H, titleSizeKey = "caption",
        useBgOpacity = true, -- profile.appearance.bgOpacity: header/timer/cards translucent, content crisp
        -- Width-only resize (height stays content-computed, like the trade-timer window): the
        -- cards/name/note gain room so a wide item name reads without truncation; buttons keep
        -- their left cluster. minW = the tight width that still fits the 5-button response row.
        resizable = true, resizeWOnly = true, minW = CARD_W + 2 * PAD,
    })
    f._bgSurfaces = {} -- deadline bar + lazily-built cards register here (useBgOpacity)

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
    f._bgSurfaces[#f._bgSurfaces + 1] = bar
    f:RefreshAppearance() -- apply a saved bgOpacity to the shell + bar from the first paint

    -- Re-anchored each render to the middle of the reserved card band (so it can never sit
    -- under an armed deadline bar); built here, positioned in RenderPollCards. The shell is
    -- bare, so this floats over the world — outlined for readability.
    f.empty = f:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.empty, "body", "dim")
    self:SetThemedFont(f.empty, self.Theme.fontSize.body, "OUTLINE")
    f.empty:SetPoint("TOP", 0, -(TITLE_H + PAD))
    f.empty:SetText(self.L["Nothing for you this round."])
    f.empty:Hide()

    -- Overflow line under the last card: how many queued items are still hidden. Floats on the
    -- bare shell with no background — success-green + outline so it stands out over the world.
    f.more = f:CreateFontString(nil, "OVERLAY")
    self:SetThemedFont(f.more, self.Theme.fontSize.body, "OUTLINE")
    f.more:SetTextColor(self.Theme.success[1], self.Theme.success[2], self.Theme.success[3])
    f.more:Hide()

    f.cards = {}

    -- Width-only grip: re-layout the cards to the new width on drag. Guard on width so the
    -- SetHeight inside RenderPollCards (which fires OnSizeChanged too) can't recurse.
    f:SetScript("OnSizeChanged", function(win)
        local w = win:GetWidth()
        if win._lastRenderW and math.abs(w - win._lastRenderW) < 0.5 then return end
        LCEX:RenderPollCards()
    end)

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
    -- Cards are lazy-built: register for the backdrop-only opacity sweep (useBgOpacity) and
    -- paint the current setting immediately so a mid-session card matches its siblings.
    parent._bgSurfaces[#parent._bgSurfaces + 1] = card
    local a = self.db and self.db.profile.appearance
    self:SetSurfaceAlpha(card, nil, (a and a.bgOpacity) or 1)

    -- Card interior: a panel surface, so content pads by LAYOUT.pad from the card's own edges.
    card.icon = self:CreateItemIcon(card, ICON_SZ)
    card.icon:SetPoint("TOPLEFT", LAY.pad, -LAY.pad)

    card.name = card:CreateFontString(nil, "OVERLAY")
    self:ThemeText(card.name, "body", "ink")
    card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", LAY.iconGap, 0) -- top-aligned with the icon
    card.name:SetPoint("RIGHT", card, "RIGHT", -LAY.pad, 0)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)

    card.buttons = {}

    -- Full-width note under the icon/buttons: TOPLEFT + RIGHT anchors override CreateEditBox's
    -- default width so it fills the card; editPad lands the box ART on the card's pad line.
    -- Its top rides the interior stack: pad(10) + icon/button-row 40 + gapTight(4) = 54.
    card.note = self:CreateEditBox(card, {})
    card.note:SetPoint("TOPLEFT", card, "TOPLEFT", LAY.pad + LAY.editPad, -54)
    card.note:SetPoint("RIGHT", card, "RIGHT", -LAY.pad, 0)
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
    -- "xN" when this card stands in for a duplicate stack (§6.14); hidden at 1.
    local a = self.activeSession
    local members = a and a.groups and a.groups.members[itemIndex]
    card.icon:SetCount(members and #members or 1)

    local q = self:QualityColor(item.quality)
    card.name:SetText(tostring(item.link):match("%[(.-)%]") or item.link)
    card.name:SetTextColor(q[1], q[2], q[3])

    for _, b in ipairs(card.buttons) do b:Hide() end
    local x = 0
    for ri, resp in ipairs(responses) do
        local b = card.buttons[ri]
        if not b then
            b = self:CreateFlatButton(card, "", 58, LAY.btnHSlim)
            card.buttons[ri] = b
        end
        b:SetText(resp.text)
        local c = resp.color
        local fs = b:GetFontString()
        if c and fs then fs:SetTextColor(c[1], c[2], c[3]) end
        b:ClearAllPoints()
        -- y = -20: the 20px button row spans card-y -30..-50 = the 40px icon's bottom, so the
        -- response group bottom-aligns to the icon; the top-anchored name row sits above it (item 3).
        b:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", LAY.iconGap + x, -20)
        b:SetScript("OnClick", function()
            self:OnResponseChosen(card.itemIndex, resp, self.pollNotes[card.itemIndex] or "")
            self:PollCardAnswered(card.itemIndex)
        end)
        b:Show()
        x = x + 58 + LAY.tabGap -- button width + the tab-strip gap
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

    -- Width is user-resizable (grip); cards/bar fill it. Stamp the width we render at so the
    -- OnSizeChanged guard treats the SetHeight below (which also fires OnSizeChanged) as a no-op.
    local cardW = f:GetWidth() - 2 * PAD
    f._lastRenderW = f:GetWidth()

    -- Deadline bar below the title bar (when armed); it shifts everything below it down.
    local top = TITLE_H + PAD
    if f.deadline then
        f.timerBar:ClearAllPoints()
        f.timerBar:SetPoint("TOPLEFT", PAD, -top)
        f.timerBar:SetWidth(cardW)
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
            card:SetWidth(cardW)
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
        -- Left-justified on the card edge line, vertically centered in a MORE_H band a PAD below
        -- the last card ("LEFT" puts the text's vertical centre on the y, so it reads centered).
        f.more:ClearAllPoints()
        f.more:SetPoint("LEFT", f, "TOPLEFT", PAD, -(bottom + PAD + MORE_H / 2))
        f.more:SetText(string.format(self.L["+ %d more"], extra))
        f.more:Show()
        bottom = bottom + PAD + MORE_H
    else
        f.more:Hide()
    end

    -- Empty state: centered in the CARD_H band reserved above (never under the timer bar).
    if shown == 0 then
        f.empty:ClearAllPoints()
        f.empty:SetPoint("TOP", 0, -(top + CARD_H / 2 - 6)) -- half a body line above true centre
        f.empty:Show()
    else
        f.empty:Hide()
    end
    -- Grow/shrink DOWNWARD: pin the current top-left, then resize. The window default is a CENTER
    -- anchor, which resizes around the middle — so shrinking as you answer would slide the cards
    -- (and their buttons) up, out from under the cursor. Re-anchoring TOPLEFT keeps the top fixed.
    local winTop, winLeft = f:GetTop(), f:GetLeft()
    f:SetHeight(bottom + PAD)
    if type(winTop) == "number" and type(winLeft) == "number" then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", winLeft, winTop)
    end
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
