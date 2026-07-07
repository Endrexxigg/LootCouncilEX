-- ── LootCouncil EX — UI/council/GbankModule.lua ─────────────────────────────
-- Council module ("Guild Bank", Feature B §6.12). Renders the replicated cache/ledger built by
-- Core/council/Gbank.lua — no scanning here (that's event-driven, ML/officer side). Layout (B8):
-- a gold HERO CARD on top, a TAB selector for the bank tabs, and Contents / Log sub-tabs. Contents
-- is a 14×7 item grid (with "xN" stack overlays); Log is the grouped, newest-first transaction feed.
-- Everything reads from the cache, so it works out of range / offline (Bd5 "not cached" when empty).
--
-- Loads after UI/CouncilWindow.lua; self-registers (order 50).

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

-- The Anniversary guild-bank tab is 14 columns × 7 rows (98 slots), numbered COLUMN-MAJOR:
-- slots 1-7 = column 1 (top→bottom), 8-14 = column 2, … So slot i sits at
-- column ⌊(i-1)/7⌋, row (i-1) mod 7 — matching the in-game layout exactly.
local GRID_COLS = 14
local GRID_ROWS = 7
local ICON      = 30
local MAX_TABS  = 8 -- pooled tab buttons (BCC guild banks cap at 8 tabs)

local SUBTABS = { { key = "contents", text = LCEX.L["Contents"] }, { key = "log", text = LCEX.L["Log"] } }

-- Coin string with the client's coin-icon textures, falling back to plain g/s/c.
local function CoinText(copper)
    copper = copper or 0
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return string.format("%dg %ds %dc",
        math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100)
end

local function iconOf(link)
    return link and GetItemInfoInstant and select(5, GetItemInfoInstant(link)) or nil
end

-- "cached Nm ago" freshness for the last scan (Bd2/Bd3).
local function Freshness(mod)
    if not mod or mod == 0 then return LCEX.L["not cached"] end
    local mins = math.floor((time() - mod) / 60)
    if mins < 1 then return LCEX.L["cached just now"] end
    return string.format(LCEX.L["cached %dm ago"], mins)
end

local ACTION = { deposit = LCEX.L["deposited"], withdraw = LCEX.L["withdrew"],
                 move = LCEX.L["moved"], repair = LCEX.L["repaired"] }

-- ── Rendering ────────────────────────────────────────────────────────────────
local function RefreshHero(panel)
    local gold, mod = LCEX:GbankGold()
    panel.hero.gold:SetText(CoinText(gold or 0))
    panel.hero.fresh:SetText(Freshness(mod))
end

-- Populate the 14×7 grid from the selected tab's slots; hide the trailing empties.
local function FillContents(panel)
    local tabs = LCEX:GbankTabs()
    local tab
    for _, t in ipairs(tabs) do if t.index == panel.selTab then tab = t end end
    local slots = (tab and tab.slots) or {}
    for i, ic in ipairs(panel.gridIcons) do
        local s = slots[i]
        if s and s.link then
            ic:SetItem(s.link, iconOf(s.link))
            ic:SetCount(s.count)
            ic:Show()
        else
            ic:Hide()
        end
    end
end

-- One tab button per cached tab (from the pool); the current one highlights. Hidden tabs are the
-- ones this player can't view (Bd5) — they simply don't appear.
local function RefreshTabBar(panel)
    local tabs = LCEX:GbankTabs()
    if panel.selTab == nil and tabs[1] then panel.selTab = tabs[1].index end
    for i, btn in ipairs(panel.tabBtns) do
        local t = tabs[i]
        if t then
            btn:SetText(t.name and t.name ~= "" and t.name or string.format(LCEX.L["Tab %d"], t.index))
            btn.tabIndex = t.index
            btn:Show()
            local fs = btn:GetFontString()
            if fs then
                local on = (t.index == panel.selTab)
                fs:SetTextColor(on and LCEX.Theme.accent[1] or LCEX.Theme.text.dim[1],
                                on and LCEX.Theme.accent[2] or LCEX.Theme.text.dim[2],
                                on and LCEX.Theme.accent[3] or LCEX.Theme.text.dim[3])
            end
        else
            btn:Hide()
        end
    end
end

local function SelectSubTab(panel, key)
    panel.subTab = key
    for _, b in ipairs(panel.subTabs) do
        local fs = b:GetFontString()
        if fs then
            local on = (b.subKey == key)
            fs:SetTextColor(on and LCEX.Theme.accent[1] or LCEX.Theme.text.dim[1],
                            on and LCEX.Theme.accent[2] or LCEX.Theme.text.dim[2],
                            on and LCEX.Theme.accent[3] or LCEX.Theme.text.dim[3])
        end
    end
    if key == "log" then
        panel.grid:Hide()
        panel.logList:Show()
        panel.logList:SetData(LCEX:BuildGbankGroups(LCEX:GbankLogEntries()))
    else
        panel.logList:Hide()
        panel.grid:Show()
        FillContents(panel)
    end
    panel.empty:SetText(key == "log" and LCEX.L["No transactions logged yet."]
        or LCEX.L["Open the guild bank in-game to scan it."])
    local emptyView = (key == "log" and #LCEX:GbankLogEntries() == 0)
        or (key == "contents" and #LCEX:GbankTabs() == 0)
    if emptyView then panel.empty:Show() else panel.empty:Hide() end
end

-- ── Log rows (grouped transactions) ──────────────────────────────────────────
local LOG_ICONS = 6
-- Council click-to-annotate a group (B5): reuses ShowConfirm's input field. Non-council rows are
-- inert. The note attaches to the group's LEAD uid (stable across scans).
local function EditNote(panel, uid, player)
    if not LCEX:AmCouncil() then return end
    LCEX:ShowConfirm({
        text = string.format(LCEX.L["Note for %s's transaction:"], tostring(player)),
        input = (LCEX:GbankNote(uid)) or "",
        accept = LCEX.L["Save"],
        onAccept = function(t) LCEX:SetGbankNote(uid, t); SelectSubTab(panel, "log") end,
    })
end

local function BuildLogRow(panel, listFrame)
    -- Parent the row to the SCROLL-LIST frame (not the panel) so hiding the list on the Contents
    -- tab actually hides its rows — otherwise the log stayed drawn over the item grid.
    local row = CreateFrame("Button", nil, listFrame or panel)
    row.time = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.time, "caption", "faint")
    row.time:SetPoint("LEFT", LAY.rowPad, 0); row.time:SetWidth(74); row.time:SetJustifyH("LEFT")
    row.who = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.who, "body", "ink")
    row.who:SetPoint("LEFT", row.time, "RIGHT", LAY.inlineGap, 0); row.who:SetWidth(180)
    row.who:SetJustifyH("LEFT"); row.who:SetWordWrap(false)
    row.icons = {}
    local anchor = row.who
    for i = 1, LOG_ICONS do
        local ic = LCEX:CreateItemIcon(row, 20)
        ic:SetPoint("LEFT", anchor, "RIGHT", i == 1 and LAY.inlineGap or 2, 0) -- paired icons: 2
        row.icons[i] = ic; anchor = ic
    end
    row.gold = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.gold, "body", "dim")
    row.gold:SetPoint("RIGHT", -LAY.rowPad, 0); row.gold:SetJustifyH("RIGHT")
    -- Annotation: shown after the icons, up to the gold. Council rows offer a "+ note" affordance.
    -- Offset = the icon strip's true span (first gap + icons + inner gaps) + an inlineGap.
    local iconSpan = LAY.inlineGap + LOG_ICONS * 20 + (LOG_ICONS - 1) * 2
    row.note = row:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(row.note, "caption", "faint")
    row.note:SetPoint("LEFT", row.who, "RIGHT", iconSpan + LAY.inlineGap, 0)
    row.note:SetPoint("RIGHT", row.gold, "LEFT", -LAY.rowPad, 0)
    row.note:SetJustifyH("LEFT"); row.note:SetWordWrap(false)
    row:SetScript("OnClick", function() EditNote(panel, row.groupUid, row.player) end)
    return row
end

local function FillLogRow(row, g)
    row.groupUid, row.player = g.uid, g.player
    row.time:SetText(date("%m/%d %Hh", g.ts or 0))
    local cc = LCEX:ClassColor(LCEX:ClassOf(g.player) or LCEX:CachedClass(g.player))
    row.who:SetText(string.format("|cff%02x%02x%02x%s|r %s",
        math.floor(cc[1] * 255 + 0.5), math.floor(cc[2] * 255 + 0.5), math.floor(cc[3] * 255 + 0.5),
        tostring(g.player), tostring(ACTION[g.kind] or g.kind)))
    for i, ic in ipairs(row.icons) do
        local it = g.items[i]
        if it then
            ic:SetItem(it.link, iconOf(it.link)); ic:SetCount(it.count); ic:Show()
        else
            ic:Hide()
        end
    end
    row.gold:SetText((g.gold and g.gold > 0) and CoinText(g.gold) or "")
    local note = LCEX:GbankNote(g.uid)
    if note and note ~= "" then
        row.note:SetText("\226\128\156" .. note .. "\226\128\157") -- “curly quotes”
        LCEX:ThemeText(row.note, "caption", "dim")
    else
        row.note:SetText(LCEX:AmCouncil() and LCEX.L["+ note"] or "")
        LCEX:ThemeText(row.note, "caption", "faint")
    end
end

LCEX:RegisterCouncilModule({
    key = "gbank", title = LCEX.L["Guild Bank"], order = 50,

    build = function(panel)
        -- Hero gold card (Bd1-3): a full-bleed band; its interior pads like a card (LAYOUT.pad),
        -- so hero text sits on the same absolute line as the tab buttons below (bleed + pad).
        local hero = CreateFrame("Frame", nil, panel)
        hero:SetPoint("TOPLEFT", LAY.bleed, -LAY.bleed)
        hero:SetPoint("TOPRIGHT", -LAY.bleed, -LAY.bleed)
        hero:SetHeight(52)
        LCEX:Surface(hero, "raised")
        hero.label = hero:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(hero.label, "caption", "dim")
        hero.label:SetPoint("TOPLEFT", LAY.pad, -LAY.gap); hero.label:SetText(LCEX.L["Guild Bank"])
        hero.gold = hero:CreateFontString(nil, "OVERLAY")
        hero.gold:SetFont(LCEX.Theme.font, 22, "")
        hero.gold:SetTextColor(LCEX.Theme.text.ink[1], LCEX.Theme.text.ink[2], LCEX.Theme.text.ink[3])
        hero.gold:SetPoint("LEFT", LAY.pad, -4)
        hero.fresh = hero:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(hero.fresh, "caption", "faint")
        hero.fresh:SetPoint("BOTTOMRIGHT", -LAY.pad, LAY.gap)
        panel.hero = hero

        -- Band stack below the hero: tab bar · sub-tabs · grid/log, a gap apart. Buttons and
        -- grid icons start on the panel's grid line (hero at bleed + pad inside = the same line).
        local bandX = LAY.grid - LAY.bleed -- hero-relative x for the panel's grid line
        local tabTop, subTop = LAY.gap, LAY.gap + LAY.btnHSlim + LAY.gap
        local contentTop = subTop + LAY.btnHSlim + LAY.gap

        -- Tab selector (pooled buttons).
        panel.tabBtns = {}
        local x = bandX
        for i = 1, MAX_TABS do
            local b = LCEX:CreateFlatButton(panel, "", 84, LAY.btnHSlim)
            b:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", x, -tabTop)
            b:SetScript("OnClick", function()
                if b.tabIndex then panel.selTab = b.tabIndex; RefreshTabBar(panel); SelectSubTab(panel, "contents") end
            end)
            b:Hide()
            panel.tabBtns[i] = b
            x = x + 84 + LAY.tabGap
        end

        -- Contents / Log sub-tabs.
        panel.subTabs = {}
        local sx = bandX
        for _, def in ipairs(SUBTABS) do
            local b = LCEX:CreateFlatButton(panel, def.text, 74, LAY.btnHSlim)
            b:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", sx, -subTop)
            b.subKey = def.key
            b:SetScript("OnClick", function() SelectSubTab(panel, def.key) end)
            panel.subTabs[#panel.subTabs + 1] = b
            sx = sx + 74 + LAY.tabGap
        end

        -- Contents grid (14×7 pooled icons).
        local grid = CreateFrame("Frame", nil, panel)
        grid:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", bandX, -contentTop)
        grid:SetSize(GRID_COLS * (ICON + 2), GRID_ROWS * (ICON + 2))
        panel.grid = grid
        panel.gridIcons = {}
        for i = 1, GRID_COLS * GRID_ROWS do
            -- Column-major over 7 rows: column = ⌊(i-1)/7⌋, row = (i-1) mod 7 (GRID_ROWS = 7).
            local col, r = math.floor((i - 1) / GRID_ROWS), (i - 1) % GRID_ROWS
            local ic = LCEX:CreateItemIcon(grid, ICON)
            ic:SetPoint("TOPLEFT", col * (ICON + 2), -r * (ICON + 2))
            ic:Hide()
            panel.gridIcons[i] = ic
        end

        -- Log list (grouped transactions).
        panel.logList = LCEX:CreateScrollList(panel, {
            rowHeight = 24, fillHeight = true, zebra = true,
            buildRow = function(list) return BuildLogRow(panel, list) end,
            fillRow = function(row, g) FillLogRow(row, g) end,
        })
        -- Full-bleed band (rows pad by rowPad, landing text on the grid line with the icons).
        panel.logList:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, -contentTop)
        panel.logList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -LAY.bleed, LAY.bleed)
        panel.logList:Hide()

        -- Centered in the content region below the hero band (bleed + hero + tab bands ≈ 64px:
        -- shift down by half so it reads centered in the space the grid/log actually occupy).
        panel.empty = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.empty, "body", "faint")
        panel.empty:SetPoint("CENTER", 0, -32)
        panel.empty:Hide()
    end,

    show = function(panel)
        LCEX._gbankPanel = panel -- so Core can live-refresh the hero on GUILDBANK_UPDATE_MONEY
        RefreshHero(panel)
        RefreshTabBar(panel)
        -- Log + annotations are officer-only by default (B5); hide the sub-tab for non-council unless
        -- the guild opted in. Contents + gold stay visible to everyone.
        local canLog = LCEX:CanSeeGbankLog()
        for _, b in ipairs(panel.subTabs) do
            if b.subKey == "log" then if canLog then b:Show() else b:Hide() end end
        end
        local sub = panel.subTab or "contents"
        if sub == "log" and not canLog then sub = "contents" end
        SelectSubTab(panel, sub)
    end,
})

-- Live-refresh the hero gold card when the module is open (called from the money event in Core).
function LCEX:RefreshGbankHero()
    local panel = self._gbankPanel
    if panel and panel:IsShown() then RefreshHero(panel) end
end
