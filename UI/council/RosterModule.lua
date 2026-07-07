-- ── LootCouncil EX — UI/council/RosterModule.lua ────────────────────────────
-- Council module ("Roster"): per-player detail + a raid-wide gear-issue scan. Left inner column
-- = the player picker (everyone we know
-- about: caches, notes, history, guild roster — filterable); right = sub-tabs over the
-- relocated display builders (Core/Display.lua): Gear / History / Professions / BiS / Notes,
-- with the data-freshness line on the self-reported tabs.
--
-- LCEX:OpenPlayerDetail(name) is the public verb (candidate-name clicks, /lcex player) —
-- it opens the council window on this module with the name as ctx.
--
-- Loads after UI/CouncilWindow.lua; self-registers.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local LIST_W = 170
-- The detail column hangs off the picker's right edge like a pane off a rail: lists/bands at
-- divider, text (and bordered controls) at divider + rowPad — one shared content line.
local DETAIL_X = LAY.divider + LAY.rowPad
-- Detail stack, from the panel top: gap · header(16) · gap · sub-tabs · gap.
local DETAIL_TOP = LAY.gap + 16 + LAY.gap + LAY.btnHSlim + LAY.gap
local SUBTABS = {
    { key = "gear",    text = "Gear" },
    { key = "history", text = "History" },
    { key = "profs",   text = "Professions" },
    { key = "bis",     text = "BiS" },
    { key = "notes",   text = "Notes" },
    { key = "gearcheck", text = "Gear Check" }, -- roster-wide overview (Feature G), not per-player
}

-- ── Detail rows (typed display arrays from Core/Display.lua) ─────────────────
local function BuildDetailRow(panel)
    local row = CreateFrame("Frame", nil, panel)
    row.icon = LCEX:CreateItemIcon(row, 18)
    row.icon:SetPoint("LEFT", LAY.rowPad, 0)
    row.text = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.text, "body", "ink")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", LAY.iconGap, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -LAY.rowPad, 0)
    row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
    return row
end

-- Compact, danger-colored suffix summarising a gear item's issues (Feature G): identical tags
-- collapse to "Empty socket ×2". Empty string when the item is clean.
local function IssueTagSuffix(issues)
    if not issues or #issues == 0 then return "" end
    local order, count = {}, {}
    for _, iss in ipairs(issues) do
        if count[iss.text] then count[iss.text] = count[iss.text] + 1
        else count[iss.text] = 1; order[#order + 1] = iss.text end
    end
    local parts = {}
    for _, text in ipairs(order) do
        parts[#parts + 1] = count[text] > 1 and (text .. " ×" .. count[text]) or text
    end
    local d = LCEX.Theme.danger
    return string.format("  |cff%02x%02x%02x%s|r",
        math.floor(d[1] * 255 + 0.5), math.floor(d[2] * 255 + 0.5), math.floor(d[3] * 255 + 0.5),
        table.concat(parts, " · "))
end

local function FillDetailRow(row, entry)
    row.loadingID = nil
    if entry.kind == "gearitem" then
        row.icon:SetItem(entry.link, GetItemInfoInstant and select(5, GetItemInfoInstant(entry.link)))
        row.icon:Show()
        LCEX:ThemeText(row.text, "body", "ink")
        row.text:SetText(string.format(LCEX.L["  slot %d: %s"], entry.slot, entry.link)
            .. (LCEX.db.profile.showGearIssues and IssueTagSuffix(entry.issues) or ""))
    elseif entry.kind == "histitem" then
        local rec = entry.rec
        row.icon:SetItem(rec.itemLink, GetItemInfoInstant and select(5, GetItemInfoInstant(rec.itemLink)))
        row.icon:Show()
        -- Retracted awards (§6.15) dim + carry a "(retracted)" tag; they are kept, not deleted.
        LCEX:ThemeText(row.text, "body", rec.retracted and "faint" or "ink")
        local tag = rec.retracted and ("  " .. LCEX.L["(retracted)"]) or ""
        row.text:SetText(string.format("%s  |cff888888%s, %s|r%s",
            tostring(rec.itemLink), tostring(rec.boss or "?"), date("%m/%d", rec.ts or 0), tag))
    elseif entry.kind == "bisitem" then
        local id = entry.itemID
        row.loadingID = id
        row.icon:SetItem(nil, GetItemInfoInstant and select(5, GetItemInfoInstant(id)))
        row.icon:Show()
        local token = LCEX:FindTokenForItem(id)
        local suffix = token and ("  |cff888888" .. LCEX.L["(token)"] .. "|r") or ""
        LCEX:ThemeText(row.text, "body", "dim")
        row.text:SetText(entry.slot .. ":  item:" .. id .. suffix)
        LCEX:WithItemID(id, function(name, link)
            if row.loadingID ~= id then return end -- row reused while loading
            LCEX:ThemeText(row.text, "body", "ink")
            row.text:SetText(entry.slot .. ":  " .. tostring(link or name or ("item:" .. id)) .. suffix)
            row.icon:SetItem(link, GetItemInfoInstant and select(5, GetItemInfoInstant(id)))
        end)
    elseif entry.kind == "gearcheck" then
        row.icon:Hide()
        local cc = LCEX:ClassColor(LCEX:ClassOf(entry.name) or LCEX:CachedClass(entry.name))
        local flat = {}
        for _, r in ipairs(entry.rows) do
            for _, iss in ipairs(r.issues) do flat[#flat + 1] = iss end
        end
        LCEX:ThemeText(row.text, "body", "ink")
        row.text:SetText(string.format("|cff%02x%02x%02x%s|r%s",
            math.floor(cc[1] * 255 + 0.5), math.floor(cc[2] * 255 + 0.5), math.floor(cc[3] * 255 + 0.5),
            entry.name, IssueTagSuffix(flat)))
    else -- info
        row.icon:Hide()
        LCEX:ThemeText(row.text, "body", "dim")
        row.text:SetText(entry.text or "")
    end
end

-- ── Sub-tab rendering ────────────────────────────────────────────────────────
local function SelectSubTab(panel, key)
    panel.subTab = key
    for _, b in ipairs(panel.subTabs) do
        local fs = b:GetFontString()
        if fs then
            if b.subKey == key then
                fs:SetTextColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3])
            else
                fs:SetTextColor(LCEX.Theme.text.dim[1], LCEX.Theme.text.dim[2], LCEX.Theme.text.dim[3])
            end
        end
    end

    local player = panel.player
    if key == "gear" then
        panel.cacheMeta:SetText(LCEX:CacheMetaText(player, "gearCache")); panel.cacheMeta:Show()
    elseif key == "profs" then
        panel.cacheMeta:SetText(LCEX:CacheMetaText(player, "profCache")); panel.cacheMeta:Show()
    else
        panel.cacheMeta:Hide()
    end

    if key == "notes" then
        panel.detailList:Hide(); panel.bisBar:Hide(); panel.notes:Show()
        local rec = LCEX.db.global.notes[LCEX:NormalizeName(player)]
        panel.notes.edit:SetText((rec and rec.text) or "")
        panel.notes.meta:SetText(rec and string.format(LCEX.L["by %s, %s"],
            tostring(rec.by), date("%m/%d %H:%M", rec.mod or 0)) or "")
        return
    end

    panel.notes:Hide()
    panel.detailList:Show()
    panel.detailList:ClearAllPoints()
    if key == "bis" then
        panel.bisBar:Show()
        panel.detailList:SetPoint("TOPLEFT", panel.picker, "TOPRIGHT",
            LAY.divider, -(DETAIL_TOP + LAY.btnHSlim + LAY.gap)) -- below the BiS cycle bar
    else
        panel.bisBar:Hide()
        panel.detailList:SetPoint("TOPLEFT", panel.picker, "TOPRIGHT", LAY.divider, -DETAIL_TOP)
    end
    panel.detailList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -LAY.bleed, 24)

    local data
    if key == "gear" then data = LCEX:BuildGearDisplay(player)
    elseif key == "history" then data = LCEX:BuildHistoryDisplay(player)
    elseif key == "profs" then data = LCEX:BuildProfsDisplay(player)
    elseif key == "gearcheck" then data = LCEX:BuildGearCheckDisplay() -- roster-wide, ignores `player`
    else
        data = LCEX:BuildBiSDisplay(player)
        panel.bisBar.classBtn:SetText(string.format(LCEX.L["Class: %s"], tostring(LCEX.bisClass or "?")))
        panel.bisBar.specBtn:SetText(string.format(LCEX.L["Spec: %s"], tostring(LCEX.bisSpec or "?")))
        panel.bisBar.phaseBtn:SetText(tostring(LCEX.bisPhase or "?"))
    end
    panel.detailList:SetData(data)
end

local function SelectPlayer(panel, name)
    if LCEX:NormalizeName(name) ~= LCEX:NormalizeName(panel.player or "") then
        LCEX.bisClass, LCEX.bisSpec = nil, nil -- a new player re-resolves BiS to THEIR class
    end
    panel.player = name
    panel.header:SetText(name)
    panel.playerList:Refresh() -- move the selection bar
    SelectSubTab(panel, panel.subTab or "gear")
end

LCEX:RegisterCouncilModule({
    key = "roster", title = LCEX.L["Roster"], order = 20,

    build = function(panel)
        -- Player picker column.
        local picker = CreateFrame("Frame", nil, panel)
        picker:SetPoint("TOPLEFT", 0, 0)
        picker:SetPoint("BOTTOMLEFT", 0, 0)
        picker:SetWidth(LIST_W)
        LCEX:Surface(picker, "base")
        panel.picker = picker

        -- Filter box art on the picker's grid line, symmetric right margin.
        panel.filterBox = LCEX:CreateEditBox(picker, {
            width = LIST_W - 2 * LAY.grid - LAY.editPad,
            onCommit = function() panel.playerList:SetData(LCEX:BuildPlayerIndex(panel.filterBox:GetText())) end,
        })
        panel.filterBox:SetPoint("TOPLEFT", LAY.grid + LAY.editPad, -LAY.gap)
        panel.filterBox:SetScript("OnTextChanged", function()
            panel.playerList:SetData(LCEX:BuildPlayerIndex(panel.filterBox:GetText()))
        end)

        panel.playerList = LCEX:CreateScrollList(picker, {
            rowHeight = 22, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Button", nil, parent)
                LCEX:Surface(row, "base")
                row.sel = row:CreateTexture(nil, "ARTWORK")
                row.sel:SetTexture("Interface\\Buttons\\WHITE8X8")
                row.sel:SetWidth(2)
                row.sel:SetPoint("TOPLEFT", 0, 0)
                row.sel:SetPoint("BOTTOMLEFT", 0, 0)
                row.sel:SetVertexColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3], 1)
                row.fs = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.fs, "body", "dim")
                row.fs:SetPoint("LEFT", LAY.rowPad, 0)
                -- Right bound clears the badge's ~14px slot at the rowPad inset.
                row.fs:SetPoint("RIGHT", -(LAY.rowPad + 14), 0); row.fs:SetJustifyH("LEFT"); row.fs:SetWordWrap(false)
                row.badge = row:CreateFontString(nil, "OVERLAY") -- Feature G: gear-issue count
                LCEX:ThemeText(row.badge, "caption", "dim")
                row.badge:SetPoint("RIGHT", -LAY.rowPad, 0)
                row:SetScript("OnClick", function(r) SelectPlayer(panel, r.playerName) end)
                return row
            end,
            fillRow = function(row, entry)
                row.playerName = entry.name
                row.fs:SetText(entry.name)
                local cc = LCEX:ClassColor(LCEX:ClassOf(entry.name) or LCEX:CachedClass(entry.name))
                row.fs:SetTextColor(cc[1], cc[2], cc[3])
                local issueTotal = 0
                if LCEX.db.profile.showGearIssues then
                    local _, total = LCEX:GearIssuesForPlayer(entry.name)
                    issueTotal = total
                end
                if issueTotal > 0 then
                    row.badge:SetText(tostring(issueTotal))
                    local d = LCEX.Theme.danger
                    row.badge:SetTextColor(d[1], d[2], d[3])
                    row.badge:Show()
                else
                    row.badge:Hide()
                end
                if LCEX:NormalizeName(panel.player or "") == entry.key then
                    LCEX:Surface(row, "overlay"); row.sel:Show()
                else
                    LCEX:Surface(row, "base"); row.sel:Hide()
                end
            end,
        })
        panel.playerList:SetPoint("TOPLEFT", LAY.bleed, -(LAY.gap + LAY.editH + LAY.gap))
        panel.playerList:SetPoint("BOTTOMRIGHT", -LAY.bleed, LAY.bleed)

        -- Detail area: header row, then the sub-tab row, then list/notes below — all on the
        -- DETAIL_X content line off the picker's edge.
        panel.header = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.header, "section", "ink")
        panel.header:SetPoint("TOPLEFT", picker, "TOPRIGHT", DETAIL_X, -LAY.gap)

        -- Feature G: toggle the gear-issue callouts (per-item tags + picker badges). Off by default;
        -- the Gear Check sub-tab is unaffected — it stays as the explicit "show me problems" view.
        panel.gearToggle = LCEX:CreateCheckbox(panel, LCEX.L["Show gear issues"],
            function() return LCEX.db.profile.showGearIssues end,
            function(v)
                LCEX.db.profile.showGearIssues = v
                panel.playerList:SetData(LCEX:BuildPlayerIndex(panel.filterBox:GetText())) -- badges
                SelectSubTab(panel, panel.subTab or "gear")                                -- tags
            end)
        panel.gearToggle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -LAY.grid, -LAY.gap)

        panel.subTabs = {}
        local x = 0
        for _, tabDef in ipairs(SUBTABS) do
            local w = math.max(52, #tabDef.text * 8)
            local b = LCEX:CreateFlatButton(panel, tabDef.text, w, LAY.btnHSlim)
            b:SetPoint("TOPLEFT", picker, "TOPRIGHT", DETAIL_X + x, -(LAY.gap + 16 + LAY.gap))
            b.subKey = tabDef.key
            b:SetScript("OnClick", function() SelectSubTab(panel, tabDef.key) end)
            panel.subTabs[#panel.subTabs + 1] = b
            x = x + w + LAY.tabGap
        end

        -- Full-bleed band off the picker seam: rows pad by rowPad, landing text on DETAIL_X.
        -- The 24px bottom inset hosts the cacheMeta caption line.
        panel.detailList = LCEX:CreateScrollList(panel, {
            rowHeight = 22, fillHeight = true, zebra = true,
            buildRow = function() return BuildDetailRow(panel) end,
            fillRow = function(row, entry) FillDetailRow(row, entry) end,
        })
        panel.detailList:SetPoint("TOPLEFT", picker, "TOPRIGHT", LAY.divider, -DETAIL_TOP)
        panel.detailList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -LAY.bleed, 24)

        -- BiS cycle bar (shown only on the BiS sub-tab): three buttons on the content line.
        local bisBar = CreateFrame("Frame", nil, panel)
        bisBar:SetPoint("TOPLEFT", picker, "TOPRIGHT", DETAIL_X, -DETAIL_TOP)
        bisBar:SetSize(120 + LAY.tabGap + 150 + LAY.tabGap + 50, LAY.btnHSlim)
        bisBar.classBtn = LCEX:CreateFlatButton(bisBar, "", 120, LAY.btnHSlim)
        bisBar.classBtn:SetPoint("LEFT", 0, 0)
        bisBar.classBtn:SetScript("OnClick", function()
            LCEX.bisClass = LCEX:_CycleNext(LCEX.CLASSES, LCEX.bisClass)
            LCEX.bisSpec = nil -- re-resolve to the new class's first spec
            SelectSubTab(panel, "bis")
        end)
        bisBar.specBtn = LCEX:CreateFlatButton(bisBar, "", 150, LAY.btnHSlim)
        bisBar.specBtn:SetPoint("LEFT", bisBar.classBtn, "RIGHT", LAY.tabGap, 0)
        bisBar.specBtn:SetScript("OnClick", function()
            LCEX.bisSpec = LCEX:_CycleNext(LCEX:SpecsForClass(LCEX.bisClass), LCEX.bisSpec)
            SelectSubTab(panel, "bis")
        end)
        bisBar.phaseBtn = LCEX:CreateFlatButton(bisBar, "", 50, LAY.btnHSlim)
        bisBar.phaseBtn:SetPoint("LEFT", bisBar.specBtn, "RIGHT", LAY.tabGap, 0)
        bisBar.phaseBtn:SetScript("OnClick", function()
            LCEX.bisPhase = LCEX:_CycleNext(LCEX.PHASES, LCEX.bisPhase)
            SelectSubTab(panel, "bis")
        end)
        bisBar:Hide()
        panel.bisBar = bisBar

        -- Notes editor (replaces the list on the Notes sub-tab), on the shared content line;
        -- the box art indents by editPad under its label and stretches to the notes frame.
        local notes = CreateFrame("Frame", nil, panel)
        notes:SetPoint("TOPLEFT", picker, "TOPRIGHT", DETAIL_X, -DETAIL_TOP)
        notes:SetPoint("TOPRIGHT", -LAY.grid, -DETAIL_TOP)
        notes:SetHeight(80)
        notes.label = notes:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(notes.label, "caption", "dim")
        notes.label:SetPoint("TOPLEFT", 0, 0)
        notes.label:SetText(LCEX.L["Note:"])
        notes.edit = LCEX:CreateEditBox(notes, {
            onCommit = function(text)
                if panel.player then
                    LCEX:SetNote(panel.player, text)
                    SelectSubTab(panel, "notes")
                end
            end,
        })
        notes.edit:SetPoint("TOPLEFT", notes.label, "BOTTOMLEFT", LAY.editPad, -LAY.inlineGap)
        notes.edit:SetPoint("RIGHT", notes, "RIGHT", 0, 0)
        notes.meta = notes:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(notes.meta, "caption", "faint")
        notes.meta:SetPoint("TOPLEFT", notes.edit, "BOTTOMLEFT", -LAY.editPad, -LAY.gap)
        notes:Hide()
        panel.notes = notes

        -- Data-freshness line (gear/profs sub-tabs only), under the detail list's 24px reserve.
        panel.cacheMeta = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.cacheMeta, "caption", "faint")
        panel.cacheMeta:SetPoint("BOTTOMLEFT", picker, "BOTTOMRIGHT", DETAIL_X, LAY.gap)
    end,

    show = function(panel, ctx)
        panel.playerList:SetData(LCEX:BuildPlayerIndex(panel.filterBox:GetText()))
        SelectPlayer(panel, (ctx and ctx ~= "" and ctx) or panel.player or UnitName("player"))
    end,
})

-- The public verb: open the dashboard on this module for `name` (self when blank). Kept as
-- the stable entry point for candidate-name clicks and /lcex player.
function LCEX:OpenPlayerDetail(name)
    if not name or name == "" then name = UnitName("player") end
    self:OpenCouncilModule("roster", name)
end

function LCEX:CmdPlayerDetail(rest)
    self:OpenPlayerDetail(strtrim(rest or ""))
end
