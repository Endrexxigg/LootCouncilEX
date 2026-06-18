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

-- Cycle to the next element after `current` (wraps; unknown/empty -> first/nil). Pure/testable.
function LCEX:_CycleNext(list, current)
    if #list == 0 then return nil end
    for i, v in ipairs(list) do
        if v == current then return list[(i % #list) + 1] end
    end
    return list[1]
end

-- Live class token (UnitClass) for the local player or a grouped member; nil otherwise.
function LCEX:ClassOf(name)
    if self:IsSelf(name) then return select(2, UnitClass("player")) end
    local n = self:NormalizeName(name)
    if not n then return nil end
    local inRaid = IsInRaid()
    for i = 1, GetNumGroupMembers() do
        local unit = inRaid and ("raid" .. i) or ("party" .. i)
        local u = UnitName(unit)
        if u and self:NormalizeName(u) == n then return select(2, UnitClass(unit)) end
    end
    return nil
end

-- Classes that have BiS data (sorted) — the browse set for the class cycler.
function LCEX:BiSClassesWithData()
    local out = {}
    for class in pairs(self.BiS) do out[#out + 1] = class end
    table.sort(out)
    return out
end

-- Resolve the current BiS class/spec/phase. Class defaults to the player's LIVE class on first
-- view (when unset/invalid), else the first class with data; spec/phase default to the first
-- available. Manual cycling sticks until a different player is opened (OpenPlayerDetail resets).
function LCEX:ResolveBiSContext(player)
    if not self.bisClass or not self.BiS[self.bisClass] then
        local live = self:ClassOf(player)
        self.bisClass = (live and self.BiS[live] and live) or self:BiSClassesWithData()[1]
    end
    local c = self.bisClass and self.BiS[self.bisClass]
    if not self.bisSpec or not (c and c[self.bisSpec]) then
        self.bisSpec = (self.bisClass and self:GetBiSSpecs(self.bisClass)[1]) or nil
    end
    if not self.bisPhase then self.bisPhase = self.PHASES[1] end
end

-- BiS rows for the resolved class/spec/phase, with a header line. UI-only: class is the
-- player's live class by default; spec/phase are user-cycled (full capture is Phase 7).
function LCEX:BuildBiSDisplay(player)
    self:ResolveBiSContext(player)
    local out = { { kind = "info", text = string.format(self.L["Class %s · Spec %s · %s"],
        tostring(self.bisClass or "?"), tostring(self.bisSpec or "?"), tostring(self.bisPhase or "?")) } }
    if self.bisClass and self.bisSpec and self.bisPhase then
        for _, r in ipairs(self:GetBiSForSpecPhase(self.bisClass, self.bisSpec, self.bisPhase)) do
            for _, itemID in ipairs(r.items) do
                out[#out + 1] = { kind = "bisitem", slot = r.slot, itemID = itemID }
            end
        end
    end
    if #out == 1 then out[#out + 1] = { kind = "info", text = self.L["No BiS data for this class/spec/phase."] } end
    return out
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
    row.loadingID = nil -- invalidate any pending async fill from a previous use of this pooled row
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
    elseif entry.kind == "bisitem" then
        local id = entry.itemID
        row.loadingID = id
        row.icon:SetItem(nil, GetItemInfoInstant and select(5, GetItemInfoInstant(id)))
        row.icon:Show()
        local token = self:FindTokenForItem(id)
        local suffix = token and "  |cff888888(token)|r" or ""
        row.text:SetText(entry.slot .. ":  item:" .. id .. suffix)
        self:WithItemID(id, function(name, link)
            if row.loadingID ~= id then return end -- row reused while loading
            row.text:SetText(entry.slot .. ":  " .. tostring(link or name or ("item:" .. id)) .. suffix)
            row.icon:SetItem(link, GetItemInfoInstant and select(5, GetItemInfoInstant(id)))
        end)
    else -- "info" / "prof": plain text, no icon
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
        rowHeight = 22, visibleRows = 11, width = 406,
        buildRow = function(parent) return self:BuildDetailRow(parent) end,
        fillRow = function(row, entry) self:FillDetailRow(row, entry) end,
    })
    f.list:SetPoint("TOPLEFT", 16, -88)

    -- BiS sub-bar: class / spec / phase cycle buttons (shown only on the BiS tab; the list drops
    -- below it on that tab). Each cycles its value and re-renders.
    local bisBar = CreateFrame("Frame", nil, f)
    bisBar:SetPoint("TOPLEFT", 16, -86)
    bisBar:SetSize(400, 22)
    bisBar.classBtn = self:CreateButton(bisBar, "", 120, 20)
    bisBar.classBtn:SetPoint("LEFT", 0, 0)
    bisBar.classBtn:SetScript("OnClick", function()
        self.bisClass = self:_CycleNext(self:BiSClassesWithData(), self.bisClass)
        self.bisSpec = nil
        self:RenderDetailTab("bis")
    end)
    bisBar.specBtn = self:CreateButton(bisBar, "", 100, 20)
    bisBar.specBtn:SetPoint("LEFT", bisBar.classBtn, "RIGHT", 4, 0)
    bisBar.specBtn:SetScript("OnClick", function()
        self.bisSpec = self:_CycleNext(self:GetBiSSpecs(self.bisClass), self.bisSpec)
        self:RenderDetailTab("bis")
    end)
    bisBar.phaseBtn = self:CreateButton(bisBar, "", 56, 20)
    bisBar.phaseBtn:SetPoint("LEFT", bisBar.specBtn, "RIGHT", 4, 0)
    bisBar.phaseBtn:SetScript("OnClick", function()
        self.bisPhase = self:_CycleNext(self.PHASES, self.bisPhase)
        self:RenderDetailTab("bis")
    end)
    bisBar:Hide()
    f.bisBar = bisBar

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
        f.list:Hide(); f.bisBar:Hide(); f.notes:Show()
        local rec = self.db.global.notes[self:NormalizeName(player)]
        f.notes.edit:SetText((rec and rec.text) or "")
        f.notes.meta:SetText(rec and string.format(self.L["by %s, %s"],
            tostring(rec.by), date("%m/%d %H:%M", rec.mod or 0)) or "")
        return
    end

    f.notes:Hide()
    f.list:Show()
    f.list:ClearAllPoints()
    if key == "bis" then
        f.bisBar:Show()
        f.list:SetPoint("TOPLEFT", 16, -114) -- below the BiS cycle bar
    else
        f.bisBar:Hide()
        f.list:SetPoint("TOPLEFT", 16, -88)
    end

    local data
    if key == "gear" then data = self:BuildGearDisplay(player)
    elseif key == "history" then data = self:BuildHistoryDisplay(player)
    elseif key == "profs" then data = self:BuildProfsDisplay(player)
    else
        data = self:BuildBiSDisplay(player)
        f.bisBar.classBtn:SetText(string.format(self.L["Class: %s"], tostring(self.bisClass or "?")))
        f.bisBar.specBtn:SetText(string.format(self.L["Spec: %s"], tostring(self.bisSpec or "?")))
        f.bisBar.phaseBtn:SetText(tostring(self.bisPhase or "?"))
    end
    f.list:SetData(data)
end

-- Open the panel for `name` (self if blank). Re-selects the last-used tab, which renders it.
function LCEX:OpenPlayerDetail(name)
    if not name or name == "" then name = UnitName("player") end
    local f = self:EnsurePlayerDetail()
    if self:NormalizeName(name) ~= self:NormalizeName(f.player or "") then
        self.bisClass, self.bisSpec = nil, nil -- a new player re-resolves BiS to THEIR class
    end
    f.player = name
    f.header:SetText(name)
    f.tabs:Select(self.detailTab or "gear")
    f:Show()
end

-- /lcex player [name]
function LCEX:CmdPlayerDetail(rest)
    self:OpenPlayerDetail(strtrim(rest or ""))
end
