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
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local FRAME_NAME = "LCEX_LootWindow"
local RAIL_W     = 280 -- widened from 236 so item names truncate less (handoff item 11)
local PANE_W     = 536 -- the right (candidate) pane
local FULL_W     = 2 * LAY.edge + RAIL_W + LAY.divider + PANE_W
local COMPACT_W  = RAIL_W + 2 * LAY.edge -- rail-only form (item 4): pre-session staging

-- ── Compact staging layout ───────────────────────────────────────────────────
-- One content inset shared by the header, the staged-items list, the Scan/add controls and the
-- footer, all from the LAYOUT contract: the rail is an edge-anchored chrome panel, so its
-- content line is LAYOUT.pad (12px absolute — the title-tick line). The rail list is an INSET
-- list: its stripes start on the pad line and its rows pad content by rowPad inside.
local C_INSET    = LAY.pad        -- left/right content inset inside the rail and the footer
local C_ROW_H    = 30             -- staged-item row height
local C_GAP      = LAY.gap        -- vertical gap between stacked controls
local C_HEADER_H = 16             -- header caption band
-- Staging control band, measured up from the rail bottom: gap · addBox · gap · scanBtn · gap.
local C_BAND_H   = C_GAP + LAY.editH + C_GAP + LAY.btnH + C_GAP
local C_CONTENT_W = RAIL_W - 2 * C_INSET

-- Awarded marker: an inline texture escape (the ready-check tick), NOT a "✓" glyph —
-- FRIZQT__.TTF has no U+2713 and renders it as an error box (handoff item 9).
local CHECK_TEX = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t"

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

-- Rail entries: one per GROUP in a live session (§6.14 — duplicate copies collapse to a single
-- row carrying `count`, `awardedCount`, and per-copy `winners`), else one per staging item (1:1).
-- `leaderIndex` is the selection key (a real item index — always a leader in-session). Returns
-- (entries, inSession).
function LCEX:LootRailEntries()
    local a = self.activeSession
    if a and a.items and a.groups then
        local out = {}
        for _, leader in ipairs(a.groups.leaders) do
            local members = a.groups.members[leader]
            local awardedCount, winners = 0, {}
            for _, m in ipairs(members) do
                local w = a.awarded and a.awarded[m]
                winners[m] = w
                if w then awardedCount = awardedCount + 1 end
            end
            out[#out + 1] = {
                link = a.items[leader].link, quality = a.items[leader].quality,
                leaderIndex = leader, count = #members,
                awardedCount = awardedCount, winners = winners, members = members,
            }
        end
        return out, true
    end
    local out = {}
    for i, it in ipairs(self.stagingItems) do
        out[i] = { link = it.link, quality = it.quality, leaderIndex = i, count = 1 }
    end
    return out, false
end

-- ── Frame shell ──────────────────────────────────────────────────────────────
function LCEX:EnsureLootWindow()
    if self.lootWindow then return self.lootWindow end
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = FULL_W, height = 470,
        title = self.L["Loot Session"],
        savedKey = "loot",
        defaultPos = { x = 0, y = 40 },
    })

    -- Left rail --------------------------------------------------------------
    local rail = CreateFrame("Frame", nil, f)
    rail:SetPoint("TOPLEFT", LAY.edge, -LAY.contentTop)
    rail:SetPoint("BOTTOMLEFT", LAY.edge, LAY.footerH + LAY.edge)
    rail:SetWidth(RAIL_W)
    self:Surface(rail, "base")
    f.rail = rail

    f.railHeader = rail:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.railHeader, "caption", "faint")
    f.railHeader:SetPoint("TOPLEFT", C_INSET, -C_GAP)

    -- Real pixel-scrolling staged-items list: top-anchored below the header, bottom set per state
    -- in RefreshLootWindow (above the staging band out-of-session, snug in-session). The shared
    -- LAYOUT.gutter reserve keeps the flat scrollbar clear of the row content on the right.
    f.railList = self:CreatePixelScrollList(rail, {
        rowHeight = C_ROW_H, width = C_CONTENT_W, zebra = true,
        buildRow = function(parent) return self:BuildLootRailRow(parent) end,
        fillRow  = function(row, entry, index) self:FillLootRailRow(row, entry, index) end,
    })
    f.railList:SetPoint("TOPLEFT", C_INSET, -C_GAP) -- staging default; re-topped for the in-session header
    f.railList:SetPoint("BOTTOMRIGHT", -C_INSET, C_BAND_H) -- staging default; retightened in-session

    -- Empty-state helper in the BODY (replaces the old header band): shown only when nothing is
    -- staged, so the footer can stay a short, stable count. Centered — vertically in the list area
    -- and center-justified — with a balanced two-line break (see the locale value) so it never reads
    -- as one long line over a stub.
    f.railEmpty = rail:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.railEmpty, "body", "faint")
    f.railEmpty:SetPoint("CENTER", f.railList, "CENTER", 0, 0)
    f.railEmpty:SetWidth(C_CONTENT_W)
    f.railEmpty:SetJustifyH("CENTER")
    f.railEmpty:SetText(self.L["Scan bags or paste item links to stage loot."])
    f.railEmpty:Hide()

    -- Staging controls (hidden while a session is open), sharing the content inset with the list.
    f.scanBtn = self:CreateFlatButton(rail, self.L["Scan bags"], C_CONTENT_W, LAY.btnH)
    f.scanBtn:SetPoint("BOTTOMLEFT", C_INSET, C_GAP + LAY.editH + C_GAP) -- sits above the add box
    f.scanBtn:SetScript("OnClick", function() self:LootStageScan() end)

    -- editPad shifts the frame so the box ART lands on the same line as the Scan button above.
    f.addBox = self:CreateEditBox(rail, {
        width = C_CONTENT_W - LAY.editPad,
        onCommit = function(text) self:LootStageAdd(text) end,
    })
    f.addBox:SetPoint("BOTTOMLEFT", C_INSET + LAY.editPad, C_GAP)

    -- Right pane ---------------------------------------------------------------
    -- A deep panel: its content line is LAYOUT.grid; the candidate list is a full-bleed band
    -- (bleed inset, rowPad-inside rows), so list text lands on the same grid line as the header.
    local pane = CreateFrame("Frame", nil, f)
    pane:SetPoint("TOPLEFT", rail, "TOPRIGHT", LAY.divider, 0)
    pane:SetPoint("BOTTOMRIGHT", -LAY.edge, LAY.footerH + LAY.edge)
    self:Surface(pane, "page")
    f.pane = pane

    f.itemIcon = self:CreateItemIcon(pane, 30)
    f.itemIcon:SetPoint("TOPLEFT", LAY.grid, -LAY.gap)

    f.itemName = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.itemName, "section", "ink")
    f.itemName:SetPoint("LEFT", f.itemIcon, "RIGHT", LAY.iconGap, 0)
    f.itemName:SetJustifyH("LEFT")
    f.itemName:SetWordWrap(false)

    f.itemCount = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.itemCount, "caption", "faint")
    f.itemCount:SetPoint("TOPRIGHT", -LAY.grid, -16)
    f.itemName:SetPoint("RIGHT", f.itemCount, "LEFT", -LAY.gap, 0)

    -- Tooltip on the selected item's NAME, not just its icon (item 15) — an overlay button in
    -- the row.nameBtn pattern, reading the selection live at hover time.
    f.itemNameBtn = CreateFrame("Button", nil, pane)
    f.itemNameBtn:SetAllPoints(f.itemName)
    f.itemNameBtn:SetScript("OnEnter", function(b)
        local items = self:LootRailItems()
        local entry = f.selectedIndex and items[f.selectedIndex]
        if entry and entry.link then
            GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(entry.link)
            GameTooltip:Show()
        end
    end)
    f.itemNameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Vote tally for the selected item (V6): "X / Y voted", below the item count. Session-only,
    -- and the count shows even under anonymous voting (only voter NAMES hide — V7).
    f.voteTally = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.voteTally, "caption", "dim")
    f.voteTally:SetPoint("TOPRIGHT", -LAY.grid, -30)
    f.voteTally:Hide()

    -- Hover target over the tally → the who-voted list (V6), suppressed to "Anonymous voting" when
    -- the session is anon (V7). Reads the selected item's status live at hover time.
    f.voteTallyBtn = CreateFrame("Button", nil, pane)
    f.voteTallyBtn:SetAllPoints(f.voteTally)
    f.voteTallyBtn:Hide()
    f.voteTallyBtn:SetScript("OnEnter", function(b)
        local idx = f.selectedIndex
        local st = idx and self.voteStatus and self.voteStatus[idx]
        local voted = st and st.voted
        GameTooltip:SetOwner(b, "ANCHOR_LEFT")
        if self.activeSession and self.activeSession.anon then
            GameTooltip:AddLine(self.L["Anonymous voting"])
        elseif voted and voted.names and #voted.names > 0 then
            GameTooltip:AddLine(self.L["Voted:"])
            for _, n in ipairs(voted.names) do GameTooltip:AddLine(n, 1, 1, 1) end
        else
            GameTooltip:AddLine(self.L["No votes yet."])
        end
        GameTooltip:Show()
    end)
    f.voteTallyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.candList = self:CreateScrollList(pane, {
        rowHeight = 26, fillHeight = true, zebra = true,
        buildRow = function(parent) return self:BuildLootCandRow(parent) end,
        fillRow  = function(row, entry) self:FillLootCandRow(row, entry) end,
    })
    -- Full-bleed band below the header row (gap · 30px icon · gap), width from the anchors.
    f.candList:SetPoint("TOPLEFT", LAY.bleed, -(LAY.gap + 30 + LAY.gap))
    f.candList:SetPoint("BOTTOMRIGHT", -LAY.bleed, LAY.bleed)

    -- Empty-state centered on the list area (the railEmpty pattern), not a fixed window offset.
    f.empty = pane:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.empty, "body", "faint")
    f.empty:SetPoint("CENTER", f.candList, "CENTER", 0, 0)
    f.empty:SetText(self.L["No responses yet."])
    f.empty:Hide()

    -- Bottom bar ---------------------------------------------------------------
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("BOTTOMLEFT", LAY.edge, LAY.edge)
    bar:SetPoint("BOTTOMRIGHT", -LAY.edge, LAY.edge)
    bar:SetHeight(LAY.footerH)
    self:Surface(bar, "raised")
    f.bottomBar = bar

    f.status = bar:CreateFontString(nil, "OVERLAY")
    self:ThemeText(f.status, "body", "dim")
    f.status:SetPoint("LEFT", C_INSET, 0)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(false) -- single-line: a right bound (set per-state in RefreshLootWindow) truncates, never wraps

    f.endBtn = self:CreateFlatButton(bar, self.L["End session"], 100, LAY.btnH, "danger")
    f.endBtn:SetPoint("RIGHT", -C_INSET, 0) -- footer buttons end on the same line the status starts on
    f.endBtn:SetScript("OnClick", function()
        -- Contextual: the ML ends the session for everyone; anyone else just closes their own
        -- view (a candidate can't end the ML's session, and EndSession's no-session path would
        -- discard an unrelated RESUMABLE session — that stays slash-only via /lcex end).
        if self.session then
            self:EndSession()
        elseif self.activeSession then
            self:LeaveSession(self.activeSession.sid)
        end
        self:RefreshLootWindow()
    end)

    f.startBtn = self:CreateFlatButton(bar, self.L["Start session"], 110, LAY.btnH, "accent")
    f.startBtn:SetPoint("RIGHT", f.endBtn, "LEFT", -LAY.btnGap, 0)
    f.startBtn:SetScript("OnClick", function() self:LootStartStaged() end)

    -- Disenchant the selected item (Feature V, ML-only + session-only). Shares startBtn's slot —
    -- startBtn is hidden in-session and deBtn out-of-session, so they are never both shown.
    f.deBtn = self:CreateFlatButton(bar, self.L["D/E"], 60, LAY.btnH)
    f.deBtn:SetPoint("RIGHT", f.endBtn, "LEFT", -LAY.btnGap, 0)
    f.deBtn:SetScript("OnClick", function() self:LootDisenchantSelected() end)
    f.deBtn:Hide()

    -- The mini pill and the window are mutually exclusive: hide the pill when the window opens,
    -- surface it when the window closes on a live session (§6.13 — closing never ends the session).
    f:HookScript("OnShow", function() LCEX:UpdateMiniFrame() end)
    f:HookScript("OnHide", function() LCEX:UpdateMiniFrame() end)

    self.lootWindow = f
    return f
end

-- ── Award-readiness icon border (Feature V, §6.10) ───────────────────────────
-- A thin colored outline hugging a rail row's item icon (V4/Vd1: the icon, not the whole row nor
-- the header). Four WHITE8X8 edges in OVERLAY so they sit above the icon art; recolored + toggled
-- per the ML-broadcast status. Corners double-draw at the same color — reads as one clean box.
local ICON_BORDER = 2
local function BuildIconBorder(row)
    local icon, edges = row.icon, {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = row:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        t:Hide()
        edges[side] = t
    end
    edges.TOP:SetPoint("TOPLEFT", icon, "TOPLEFT", -ICON_BORDER, ICON_BORDER)
    edges.TOP:SetPoint("TOPRIGHT", icon, "TOPRIGHT", ICON_BORDER, ICON_BORDER)
    edges.TOP:SetHeight(ICON_BORDER)
    edges.BOTTOM:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", -ICON_BORDER, -ICON_BORDER)
    edges.BOTTOM:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", ICON_BORDER, -ICON_BORDER)
    edges.BOTTOM:SetHeight(ICON_BORDER)
    edges.LEFT:SetPoint("TOPLEFT", icon, "TOPLEFT", -ICON_BORDER, ICON_BORDER)
    edges.LEFT:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", -ICON_BORDER, -ICON_BORDER)
    edges.LEFT:SetWidth(ICON_BORDER)
    edges.RIGHT:SetPoint("TOPRIGHT", icon, "TOPRIGHT", ICON_BORDER, ICON_BORDER)
    edges.RIGHT:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", ICON_BORDER, -ICON_BORDER)
    edges.RIGHT:SetWidth(ICON_BORDER)
    return edges
end

local function SetIconBorder(edges, color)
    if color then
        for _, t in pairs(edges) do
            t:SetVertexColor(color[1], color[2], color[3], 1)
            t:Show()
        end
    else
        for _, t in pairs(edges) do t:Hide() end
    end
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
    row.icon:SetPoint("LEFT", LAY.rowPad, 0)
    row.statusBorder = BuildIconBorder(row) -- award-readiness edge (Feature V)

    row.name = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.name, "body", "ink")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", LAY.iconGap, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Badge default clears the staging remove-× zone: gapTight · 16px button · gapTight.
    row.badge = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.badge, "caption", "faint")
    row.badge:SetPoint("RIGHT", -(LAY.gapTight + 16 + LAY.gapTight), 0)
    row.name:SetPoint("RIGHT", row.badge, "LEFT", -LAY.inlineGap, 0)

    -- Staging-only remove ×.
    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(16, 16)
    row.remove:SetPoint("RIGHT", -LAY.gapTight, 0)
    row.remove.fs = row.remove:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.remove.fs, "body", "faint")
    row.remove.fs:SetPoint("CENTER", 0, 0)
    row.remove.fs:SetText("×")
    row.remove:SetScript("OnEnter", function(b)
        b.fs:SetTextColor(LCEX.Theme.danger[1], LCEX.Theme.danger[2], LCEX.Theme.danger[3])
    end)
    row.remove:SetScript("OnLeave", function(b) LCEX:ThemeText(b.fs, "body", "faint") end)
    row.remove:SetScript("OnClick", function() LCEX:LootStageRemove(row.index) end)

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(r, button)
        if button == "RightButton" then
            LCEX:LootUnawardMenu(r.index) -- ML-only per-copy correction (§6.15)
        else
            LCEX:LootSelectItem(r.index)
        end
    end)
    -- Hover a grouped row → the per-copy winner breakdown, so a diverged x2 (one awarded, one
    -- still up) is never hidden behind the count (§6.14). Single/unawarded rows show nothing.
    row:SetScript("OnEnter", function(r)
        local e = r.entry
        if not (e and e.count and e.count > 1 and (e.awardedCount or 0) > 0) then return end
        GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
        GameTooltip:AddLine(LinkName(e.link))
        for i, m in ipairs(e.members or {}) do
            local w = e.winners and e.winners[m]
            if w then
                GameTooltip:AddDoubleLine(string.format(LCEX.L["Copy %d"], i),
                    DisplayName(nil, w), 0.8, 0.8, 0.8,
                    LCEX.Theme.success[1], LCEX.Theme.success[2], LCEX.Theme.success[3])
            else
                GameTooltip:AddDoubleLine(string.format(LCEX.L["Copy %d"], i),
                    LCEX.L["unawarded"], 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

function LCEX:FillLootRailRow(row, entry)
    row.index = entry.leaderIndex -- selection key (a leader index in-session; staging position otherwise)
    row.entry = entry
    local icon = GetItemInfoInstant and select(5, GetItemInfoInstant(entry.link))
    row.icon:SetItem(entry.link, icon)
    row.icon:SetCount(entry.count or 1) -- "xN" for duplicate stacks; hidden at 1 (§6.14, item 10)
    local q = self:QualityColor(entry.quality)
    row.name:SetText(LinkName(entry.link))
    row.name:SetTextColor(q[1], q[2], q[3])

    local f = self.lootWindow
    local a = self.activeSession
    -- The badge's right inset is dynamic: staging clears the remove-× zone; in-session the
    -- × is hidden, so the badge (and the name chained to it) reclaim that width (item 11).
    row.badge:ClearAllPoints()
    row.badge:SetPoint("RIGHT", a and -LAY.rowPad or -(LAY.gapTight + 16 + LAY.gapTight), 0)
    if a then
        row.remove:Hide()
        local statusKind
        local awardedCount, count = entry.awardedCount or 0, entry.count or 1
        if awardedCount > 0 then
            -- Winner badge: a single item shows its winner; a partially/fully awarded stack shows
            -- "a/N" (the per-copy tooltip breaks out who won which). Fully-awarded forces the
            -- "awarded" border directly; a partial group keeps the live status.
            if count == 1 then
                local only = entry.winners and entry.winners[entry.leaderIndex]
                row.badge:SetText(CHECK_TEX .. " " .. DisplayName(nil, only))
            else
                row.badge:SetText(CHECK_TEX .. " " .. awardedCount .. "/" .. count)
            end
            row.badge:SetTextColor(self.Theme.success[1], self.Theme.success[2], self.Theme.success[3])
            if awardedCount >= count then
                statusKind = "awarded"
            else
                local st = self.voteStatus and self.voteStatus[entry.leaderIndex]
                statusKind = st and st.kind
            end
        else
            -- Response count is full-view only (DL-18): a list-level spectator's rail shows
            -- item + award state + winner, never how many (or who) responded.
            if a.viewLevel == "full" then
                local n = 0
                local rows = self.voteRows and self.voteRows[entry.leaderIndex]
                if rows then for _ in pairs(rows) do n = n + 1 end end
                row.badge:SetText(tostring(n))
                self:ThemeText(row.badge, "caption", "faint")
            else
                row.badge:SetText("")
            end
            local st = self.voteStatus and self.voteStatus[entry.leaderIndex]
            statusKind = st and st.kind
        end
        SetIconBorder(row.statusBorder, self:StatusColor(statusKind))
    else
        row.remove:Show()
        row.badge:SetText("")
        SetIconBorder(row.statusBorder, nil)
    end

    if f and f.selectedIndex == entry.leaderIndex then
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
    row.name:SetPoint("LEFT", LAY.rowPad, 0)
    row.name:SetWidth(110); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)

    row.nameBtn = CreateFrame("Button", nil, row)
    row.nameBtn:SetPoint("LEFT", LAY.rowPad, 0)
    row.nameBtn:SetSize(110, 24)
    row.nameBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.nameBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Right-click a winner → correct that candidate's copy (§6.15), ML-only.
            local a = LCEX.activeSession
            if a and LCEX:IsSelf(a.ml) and row._wonIndex then
                LCEX:ConfirmUnaward(row._wonIndex, a.awarded and a.awarded[row._wonIndex])
            end
        elseif row._cleanName and row._cleanName ~= "" then
            LCEX:OpenPlayerDetail(row._cleanName) -- the clean name (no ✓ texture prefix)
        end
    end)

    row.resp = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.resp, "body", "dim")
    row.resp:SetPoint("LEFT", row.name, "RIGHT", LAY.inlineGap, 0)
    row.resp:SetWidth(52); row.resp:SetJustifyH("LEFT"); row.resp:SetWordWrap(false)

    row.gear = { self:CreateItemIcon(row, 18), self:CreateItemIcon(row, 18) }
    row.gear[1]:SetPoint("LEFT", row.resp, "RIGHT", LAY.gapTight, 0)
    row.gear[2]:SetPoint("LEFT", row.gear[1], "RIGHT", 2, 0) -- paired icons: half a gapTight

    row.note = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.note, "caption", "faint")
    row.note:SetPoint("LEFT", row.gear[2], "RIGHT", LAY.inlineGap, 0)
    row.note:SetJustifyH("LEFT"); row.note:SetWordWrap(false)

    row.award = self:CreateFlatButton(row, self.L["Award"], 56, LAY.btnHSlim, "accent")
    row.award:SetPoint("RIGHT", -LAY.gapTight, 0)
    -- Vote cluster reads [−][n][+] left→right (handoff item 2): downvote left, upvote right.
    -- Cluster-internal gaps are gapTight; the cluster stands a full gap off the Award button.
    row.plus = self:CreateFlatButton(row, "+", 22, LAY.btnHSlim)
    row.plus:SetPoint("RIGHT", row.award, "LEFT", -LAY.gap, 0)
    row.votes = row:CreateFontString(nil, "OVERLAY")
    self:ThemeText(row.votes, "body", "ink")
    row.votes:SetPoint("RIGHT", row.plus, "LEFT", -LAY.gapTight, 0)
    row.votes:SetWidth(22); row.votes:SetJustifyH("CENTER")
    row.minus = self:CreateFlatButton(row, "−", 22, LAY.btnHSlim)
    row.minus:SetPoint("RIGHT", row.votes, "LEFT", -LAY.gapTight, 0)
    row.note:SetPoint("RIGHT", row.minus, "LEFT", -LAY.inlineGap, 0)

    return row
end

function LCEX:FillLootCandRow(row, entry)
    local itemIndex, candKey, data = entry.itemIndex, entry.candKey, entry.data
    -- Group-aware award state (§6.14): a candidate is a winner if they took ANY copy; the group is
    -- "full" once every copy is awarded. itemIndex is the group leader (the shared candidate table).
    local a = self.activeSession
    local awarded = a and a.awarded
    local members = self:GroupMembers(itemIndex)
    local awardedCount, isWinner, wonIndex = 0, false, nil
    for _, m in ipairs(members) do
        local w = awarded and awarded[m]
        if w then
            awardedCount = awardedCount + 1
            if self:NormalizeName(w) == candKey then isWinner = true; wonIndex = m end
        end
    end
    local groupFull = awardedCount >= #members
    row._cleanName = DisplayName(data, candKey) -- for OpenPlayerDetail (no ✓ prefix)
    row._wonIndex = wonIndex                    -- the physical copy this candidate won (right-click un-award)
    -- The winner's row is explicitly marked (item 3): check + success-tinted response below.
    row.name:SetText((isWinner and (CHECK_TEX .. " ") or "") .. row._cleanName)
    local cc = self:ClassColor(self:ClassOf(data.name or candKey) or self:CachedClass(data.name or candKey))
    row.name:SetTextColor(cc[1], cc[2], cc[3])
    -- Dim the "not rolling" tier — declined, ineligible (can't use / missed kill), or left (V1, R3).
    if data.resp == self:PassResponseId() or (data.reason and data.reason ~= "pending") then
        self:ThemeText(row.name, "body", "faint")
    end

    local resp = ResponseEntry(self, data.resp)
    if resp then
        row.resp:SetText(resp.text)
        local c = resp.color
        if c then row.resp:SetTextColor(c[1], c[2], c[3]) end
    else
        -- No response yet: show the seeded reason (Waiting / Can't use / Missed kill / Left), dimmed.
        row.resp:SetText(self:ReasonText(data.reason))
        self:ThemeText(row.resp, "body", "faint")
    end
    if isWinner then
        row.resp:SetTextColor(self.Theme.success[1], self.Theme.success[2], self.Theme.success[3])
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
    -- Voting is council-only (C7): a transparency viewer (opted-in raider) sees the tally read-only.
    if a and a.amCouncil then row.plus:Show(); row.minus:Show()
    else row.plus:Hide(); row.minus:Hide() end

    -- Award is the ML's action only — only the ML's award is authoritative.
    if a and self:IsSelf(a.ml) then
        row.award:Show()
        if groupFull then
            -- Every copy awarded: grey out so it can't be casually re-clicked (item 3). The
            -- deliberate correction path is the right-click un-award, not this button.
            row.award:SetText(self.L["Awarded"])
            row.award:SetFlatEnabled(false)
            row.award:SetScript("OnClick", nil)
        else
            row.award:SetText(self.L["Award"])
            row.award:SetFlatEnabled(true)
            -- AwardGroup hands out the next unawarded physical copy (§6.14).
            row.award:SetScript("OnClick", function()
                if self:AwardGroup(itemIndex, data.name or candKey) then
                    self:RefreshLootWindow()
                end
            end)
        end
    else
        row.award:Hide()
    end
end

-- Compact/full layout (item 4): with nothing to show on the right, the window is just the
-- staging rail; a live session expands to the two-pane form. Resizing pins TOPLEFT (the
-- PollWindow reflow pattern) so the rail never moves — the pane grows rightward. Hiding
-- `f.pane` covers every right-side widget (all are pane children). Height never changes.
function LCEX:ApplyLootLayout(f, mode)
    if f._layoutMode == mode then return end
    f._layoutMode = mode
    local winTop, winLeft = f:GetTop(), f:GetLeft()
    f:SetWidth(mode == "full" and FULL_W or COMPACT_W)
    if mode == "full" then f.pane:Show() else f.pane:Hide() end
    if type(winTop) == "number" and type(winLeft) == "number" then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", winLeft, winTop)
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
    local railEntries = self:LootRailEntries()

    -- Full layout only for a live session at the full view level (DL-18): spectators keep the
    -- rail-only form, as does the pre-session staging list for everyone.
    local fullView = inSession and self.activeSession and self.activeSession.viewLevel == "full"
    self:ApplyLootLayout(f, fullView and "full" or "rail")

    -- Selection is a group LEADER (rows/header live under leaders, §6.14). Snap a stale member
    -- selection up to its leader, then clamp to the first rail entry.
    local a = self.activeSession
    if inSession and a and a.groups and f.selectedIndex then
        f.selectedIndex = a.groups.leaderOf[f.selectedIndex] or f.selectedIndex
    end
    if not f.selectedIndex or not items[f.selectedIndex] then
        f.selectedIndex = railEntries[1] and railEntries[1].leaderIndex or nil
    end

    -- Header only in-session (the list starts below it). Staging drops the header entirely so the
    -- list starts near the top of the body; the empty-state helper takes the header's old job.
    if inSession then
        f.railHeader:SetText(self.L["SESSION ITEMS"])
        f.railHeader:Show()
        f.railList:SetPoint("TOPLEFT", C_INSET, -(C_GAP + C_HEADER_H + C_GAP))
    else
        f.railHeader:Hide()
        f.railList:SetPoint("TOPLEFT", C_INSET, -C_GAP)
    end
    -- Empty-state helper (staging only, when nothing is staged). Lives in the body so the footer
    -- stays a short count; hidden the moment a row exists so the list owns the space.
    if not inSession and #items == 0 then f.railEmpty:Show() else f.railEmpty:Hide() end
    -- In-session the staging-control band (scan/add) is reclaimed by the list; out-of-session the
    -- list stops above it. Both use the shared content inset so the list right edge never moves.
    f.railList:SetPoint("BOTTOMRIGHT", -C_INSET, inSession and C_GAP or C_BAND_H)
    f.railList:SetData(railEntries)

    if inSession then
        f.scanBtn:Hide(); f.addBox:Hide()
        f.startBtn:Hide(); f.endBtn:Show()
        -- End is shown here, so restore startBtn to its shared slot left of End (it's hidden in
        -- this state, but keep the anchor coherent for the next staging→session toggle).
        f.startBtn:ClearAllPoints()
        f.startBtn:SetPoint("RIGHT", f.endBtn, "LEFT", -LAY.btnGap, 0)
        -- Contextual label (DL-18): only the ML ends the session for everyone; anyone else
        -- (council or spectator) merely leaves their own view of it.
        f.endBtn:SetText(self.session and self.L["End session"] or self.L["Leave session"])
        -- D/E is the ML's action only (it awards on the ML-authoritative session).
        if self.activeSession and self:IsSelf(self.activeSession.ml) then f.deBtn:Show() else f.deBtn:Hide() end
        f.status:SetText(string.format(self.L["Session active — %d item(s)."], #items))
        -- Right-bound the status to the leftmost VISIBLE right-side button so it truncates instead
        -- of sliding under the buttons. deBtn (when shown) sits left of endBtn; never anchor to a
        -- hidden frame (LAYOUT/DANGLING_ANCHOR), so re-pick the target with the visibility swaps.
        f.status:SetPoint("RIGHT", f.deBtn:IsShown() and f.deBtn or f.endBtn, "LEFT", -C_GAP, 0)
    else
        f.scanBtn:Show(); f.addBox:Show()
        f.startBtn:Show(); f.endBtn:Hide()
        f.deBtn:Hide()
        -- Footer: Start right-aligned at the content inset (End/deBtn hidden, so it can't ride the
        -- hidden End button's slot — that squeezed the status to ~36px and truncated the label).
        f.startBtn:ClearAllPoints()
        f.startBtn:SetPoint("RIGHT", f.bottomBar, "RIGHT", -C_INSET, 0)
        -- Start needs at least one staged item; disable it in the empty state (the long "what to do"
        -- copy lives in the body helper, not here). LootStartStaged still guards defensively.
        f.startBtn:SetFlatEnabled(#items > 0)
        -- Short, stable footer count — "0 item(s) staged." when empty (no truncating sentence).
        f.status:SetText(string.format(self.L["%d item(s) staged."], #items))
        -- Status left-aligned at the inset, right-bounded to Start so it truncates before overlap.
        f.status:SetPoint("RIGHT", f.startBtn, "LEFT", -C_GAP, 0)
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
        -- Position among the RAIL entries (groups), not physical items, so "2 / 3" matches the list.
        local pos = 1
        for i, e in ipairs(railEntries) do if e.leaderIndex == f.selectedIndex then pos = i; break end end
        f.itemCount:SetText(string.format("%d / %d", pos, #railEntries))
    else
        f.itemIcon:Hide()
        f.itemName:SetText("")
        f.itemCount:SetText("")
    end

    -- Vote tally for the selected item (V6). Hidden outside a session, or when no council is
    -- present to vote (of == 0). The numerator/denominator ride the ML's broadcast status.
    local st = inSession and entry and self.voteStatus and self.voteStatus[f.selectedIndex]
    local voted = st and st.voted
    if voted and (voted.of or 0) > 0 then
        f.voteTally:SetText(string.format(self.L["%d / %d voted"], voted.n or 0, voted.of))
        f.voteTally:Show()
        f.voteTallyBtn:Show()
    else
        f.voteTally:Hide()
        f.voteTallyBtn:Hide()
    end

    local display = {}
    if inSession and f.selectedIndex then
        local rows = self.voteRows and self.voteRows[f.selectedIndex]
        if rows then
            local PASS = self:PassResponseId()
            local function tier(d) -- ROLLED (1) > MIGHT ROLL (2) > NOT ROLLING (3) — V1, R3
                if d.resp and d.resp ~= PASS then return 1 end
                if d.reason == "pending" then return 2 end
                return 3
            end
            local keys = {}
            for k in pairs(rows) do keys[#keys + 1] = k end
            table.sort(keys, function(x, y)
                local rx, ry = rows[x], rows[y]
                local tx, ty = tier(rx), tier(ry)
                if tx ~= ty then return tx < ty end
                if (rx.votes or 0) ~= (ry.votes or 0) then return (rx.votes or 0) > (ry.votes or 0) end
                return tostring(rx.name or x) < tostring(ry.name or y)
            end)
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
    self:UpdateMiniFrame() -- keep the pill's response/award counts current (§6.13)
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
    -- Guard BEFORE touching sessionItems: overwriting it under a live session corrupts that
    -- session's award records (AwardItem reads sessionItems by index).
    if self.session then
        self:Msg(self.L["A session is already active. /lcex end first."])
        return
    end
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
    if self.session then self.stagingItems = {} end -- consumed (StartSession may still refuse on empty)
    self:RefreshLootWindow()
end

-- Disenchant the selected item (Feature V, §6.10). ML-only. Auto-picks the highest-ranked present
-- disenchanter (ResolveDisenchanter) and confirms; if none is set/present, falls back to a manual
-- name entry (Vd7). On confirm, awards with the D/E reason so the announcement reads "… for D/E".
function LCEX:LootDisenchantSelected()
    local f = self.lootWindow
    local a = self.activeSession
    if not (f and a and self:IsSelf(a.ml)) then return end
    local index = f.selectedIndex
    local items = self:LootRailItems()
    local entry = index and items[index]
    if not entry then return end

    local function award(name)
        name = strtrim(name or "")
        -- AwardGroup so a D/E on a duplicate stack consumes the next physical copy (§6.14).
        if name ~= "" and self:AwardGroup(index, name, self.STATUS.DISENCHANT) then
            self:RefreshLootWindow()
        end
    end

    local target = self:ResolveDisenchanter()
    if target then
        self:ShowConfirm({
            text = string.format(self.L["Send %s to %s for disenchant?"], entry.link, target),
            onAccept = function() award(target) end,
        })
    else
        self:ShowConfirm({
            text = string.format(self.L["No disenchanter available. Send %s for disenchant to:"], entry.link),
            input = "",
            onAccept = award,
        })
    end
end

-- ── Award correction (§6.15, ML-only) ────────────────────────────────────────
-- Right-clicking an awarded rail row opens a per-copy correction menu: one "Un-award <winner>"
-- entry per awarded physical copy in the group, so the ML picks exactly which to retract.
function LCEX:LootUnawardMenu(leader)
    local a = self.activeSession
    if not (a and self.session and self:IsSelf(a.ml)) then return end
    local menu = {}
    for _, m in ipairs(self:GroupMembers(leader)) do
        local w = a.awarded and a.awarded[m]
        if w then
            menu[#menu + 1] = {
                text = string.format(self.L["Un-award %s"], DisplayName(nil, w)),
                danger = true,
                onClick = function() self:ConfirmUnaward(m, w) end,
            }
        end
    end
    if #menu == 0 then return end -- nothing awarded in this group yet
    self:ShowContextMenu({ title = self.L["Correct award"], items = menu })
end

-- Confirm dialog before an un-award. Wording is stateful: with an owed (untraded) record it offers
-- to return the item to the session; once traded it's a record-only correction (never implies the
-- item came back).
function LCEX:ConfirmUnaward(physIdx, winner)
    if not (self.session and winner) then return end
    local uid = self.session.sid .. ":" .. physIdx
    local text
    if self:HasOwedTrade(uid) then
        text = string.format(self.L["Un-award %s and reopen the item for awarding?"], DisplayName(nil, winner))
    else
        text = string.format(
            self.L["Correct the record: %s no longer marked as the winner. The item was already traded — this does not reverse the trade."],
            DisplayName(nil, winner))
    end
    self:ShowConfirm({
        text = text,
        onAccept = function()
            if self:UnawardItem(physIdx) then self:RefreshLootWindow() end
        end,
    })
end

-- ── Entry points (Core contract) ─────────────────────────────────────────────
function LCEX:ShowLootWindow()
    -- Everyone may open the window (Phase 12, DL-18): what renders is decided by the VIEW level
    -- — rail-only list view for non-council raiders, the full two-pane for council/opted-in.
    local f = self:EnsureLootWindow()
    f.selectedIndex = nil -- re-derive from the current item list
    f:Show()
    self:RefreshLootWindow()
    f.railList:ScrollToTop() -- opening the window is a deliberate fresh view → start at the top
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
