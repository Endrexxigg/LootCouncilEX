-- ── LootCouncil EX — UI/PlayerDetail.lua ─────────────────────────────────────
-- The per-player detail panel: tabs Gear | History | Professions | BiS | Notes over the
-- council datasets (gearCache / history / profCache / notes) + static BiS data. Opened by
-- clicking a candidate name in the VotingFrame, or /lcex player [name].
--
-- Gear/History/Professions/BiS render through one shared scroll list fed a typed display array
-- (one fillRow switches on entry.kind, like the LootBrowser); Notes is a separate edit panel.
-- The pure list-builders (HistoryForPlayer etc.) live in Core so they're headless-tested.
--
-- This slice ships Gear/History/Professions/Notes; the BiS tab is a placeholder filled next.
--
-- Loads after UI/Widgets.lua and the council/Data files.

local LCEX = LootCouncilEX

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local TABS = {
    { key = "gear",    text = "Gear" },
    { key = "history", text = "History" },
    { key = "profs",   text = "Professions" },
    { key = "bis",     text = "BiS" },
    { key = "notes",   text = "Notes" },
}

-- ── Display builders (per tab) ───────────────────────────────────────────────
function LCEX:BuildGearDisplay(player)
    local key = self:NormalizeName(player)
    local rec = key and self.db.global.gearCache[key]
    local items = rec and rec.items
    if not items and self:IsSelf(player) then items = self:SnapshotGear() end -- live for self
    local out = {}
    if items then
        for slot = 1, 18 do
            if items[slot] then out[#out + 1] = { kind = "gearitem", slot = slot, link = items[slot] } end
        end
    end
    if #out == 0 then out[1] = { kind = "info", text = self.L["(no cached report)"] } end
    return out
end

function LCEX:BuildHistoryDisplay(player)
    local out = {}
    for _, rec in ipairs(self:HistoryForPlayer(self:NormalizeName(player))) do
        out[#out + 1] = { kind = "histitem", rec = rec }
    end
    if #out == 0 then out[1] = { kind = "info", text = self.L["No award history."] } end
    return out
end

function LCEX:BuildProfsDisplay(player)
    local key = self:NormalizeName(player)
    local rec = key and self.db.global.profCache[key]
    local profs = rec and rec.profs
    if not profs and self:IsSelf(player) then profs = self:SnapshotProfs() end
    local out, names = {}, {}
    if profs then for name in pairs(profs) do names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
        out[#out + 1] = { kind = "info", text = name .. ": " .. tostring(profs[name]) }
    end
    if #out == 0 then out[1] = { kind = "info", text = self.L["(no cached report)"] } end
    return out
end

-- Placeholder until slice 6 (BiS class/spec/phase browser).
function LCEX:BuildBiSDisplay()
    return { { kind = "info", text = self.L["BiS — coming next."] } }
end

-- ── Shared list row ──────────────────────────────────────────────────────────
function LCEX:BuildDetailRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.icon = self:CreateItemIcon(row, 18)
    row.icon:SetPoint("LEFT", 2, 0)
    row.text = self:CreateLabel(row, nil, "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
    return row
end

function LCEX:FillDetailRow(row, entry)
    if entry.kind == "gearitem" then
        row.icon:SetItem(entry.link, GetItemInfoInstant and select(5, GetItemInfoInstant(entry.link)))
        row.icon:Show()
        row.text:SetText(string.format(self.L["  slot %d: %s"], entry.slot, entry.link))
    elseif entry.kind == "histitem" then
        local rec = entry.rec
        row.icon:SetItem(rec.itemLink, GetItemInfoInstant and select(5, GetItemInfoInstant(rec.itemLink)))
        row.icon:Show()
        row.text:SetText(string.format("%s  |cff888888%s, %s|r",
            tostring(rec.itemLink), tostring(rec.boss or "?"), date("%m/%d", rec.ts or 0)))
    else -- "info" / "prof" / placeholder: plain text, no icon
        row.icon:Hide()
        row.text:SetText(entry.text or "")
    end
end

-- ── Frame ────────────────────────────────────────────────────────────────────
function LCEX:EnsurePlayerDetail()
    if self.playerDetail then return self.playerDetail end
    local f = self:CreateWindow("LCEX_PlayerDetail", {
        width = 440, height = 400,
        title = self.L["LootCouncil EX — Player"],
        savedKey = "playerDetail",
    })

    f.header = self:CreateLabel(f, nil, "GameFontNormalLarge")
    f.header:SetPoint("TOP", 0, -36)

    f.tabs = self:CreateTabStrip(f, TABS, function(key) self:RenderDetailTab(key) end)
    f.tabs:SetPoint("TOPLEFT", 16, -58)

    f.list = self:CreateScrollList(f, {
        rowHeight = 22, visibleRows = 12, width = 406,
        buildRow = function(parent) return self:BuildDetailRow(parent) end,
        fillRow = function(row, entry) self:FillDetailRow(row, entry) end,
    })
    f.list:SetPoint("TOPLEFT", 16, -88)

    -- Notes editor (shown instead of the list on the Notes tab).
    local notes = CreateFrame("Frame", nil, f)
    notes:SetPoint("TOPLEFT", 16, -88)
    notes:SetPoint("TOPRIGHT", -16, -88)
    notes.label = self:CreateLabel(notes, self.L["Note:"])
    notes.label:SetPoint("TOPLEFT", 0, 0)
    notes.edit = self:CreateEditBox(notes, {
        width = 380,
        onCommit = function(text) if f.player then self:SetNote(f.player, text) end end,
    })
    notes.edit:SetPoint("TOPLEFT", notes.label, "BOTTOMLEFT", 4, -6)
    notes.meta = self:CreateLabel(notes, nil, "GameFontDisableSmall")
    notes.meta:SetPoint("TOPLEFT", notes.edit, "BOTTOMLEFT", -4, -10)
    notes:Hide()
    f.notes = notes

    self.playerDetail = f
    return f
end

function LCEX:RenderDetailTab(key)
    local f = self.playerDetail
    if not f then return end
    self.detailTab = key
    local player = f.player

    if key == "notes" then
        f.list:Hide()
        f.notes:Show()
        local rec = self.db.global.notes[self:NormalizeName(player)]
        f.notes.edit:SetText((rec and rec.text) or "")
        f.notes.meta:SetText(rec and string.format(self.L["by %s, %s"],
            tostring(rec.by), date("%m/%d %H:%M", rec.mod or 0)) or "")
        return
    end

    f.notes:Hide()
    f.list:Show()
    local data
    if key == "gear" then data = self:BuildGearDisplay(player)
    elseif key == "history" then data = self:BuildHistoryDisplay(player)
    elseif key == "profs" then data = self:BuildProfsDisplay(player)
    else data = self:BuildBiSDisplay(player) end
    f.list:SetData(data)
end

-- Open the panel for `name` (self if blank). Re-selects the last-used tab, which renders it.
function LCEX:OpenPlayerDetail(name)
    if not name or name == "" then name = UnitName("player") end
    local f = self:EnsurePlayerDetail()
    f.player = name
    f.header:SetText(name)
    f.tabs:Select(self.detailTab or "gear")
    f:Show()
end

-- /lcex player [name]
function LCEX:CmdPlayerDetail(rest)
    self:OpenPlayerDetail(strtrim(rest or ""))
end
