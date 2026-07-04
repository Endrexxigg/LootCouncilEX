-- ── LootCouncil EX — UI/council/SessionConfigModule.lua ──────────────────────
-- Council module: officer settings for running sessions. Council roster (guild-rank cutoff +
-- explicit extra members — the UI over profile.council, replacing /lcex council add/remove),
-- the poll response deadline (profile.pollTimeout, rides sStart), and a placeholder for the
-- DL-8 response-set editor. All edits invalidate the cached Plane-B council set.
--
-- Loads after UI/CouncilWindow.lua; self-registers.

local LCEX = LootCouncilEX

local function RefreshRoster(panel)
    local names = {}
    for n in pairs(LCEX:ResolveCouncil(false)) do names[#names + 1] = n end
    table.sort(names)
    panel.rosterList:SetData(names)
    panel.rosterCount:SetText(string.format(LCEX.L["Council — %d member(s) (you: %s):"],
        #names, LCEX:AmCouncil() and LCEX.L["member"] or LCEX.L["not a member"]))
end

-- ── Preferred disenchanters (Feature V, ranked) ──────────────────────────────
local function RefreshDisenchanters(panel)
    panel.deList:SetData(LCEX:GetConfig().disenchanters or {})
end

-- Read the shared list, copy it (the stored/defaults list must not be mutated in place), let `fn`
-- edit the copy, then replicate it via SetConfigField (LWW). Order is the ranking (top = highest).
local function EditDisenchanters(panel, fn)
    local cur, list = LCEX:GetConfig().disenchanters or {}, {}
    for i, n in ipairs(cur) do list[i] = n end
    fn(list)
    LCEX:SetConfigField("disenchanters", list)
    RefreshDisenchanters(panel)
end

local function MoveDisenchanter(panel, index, delta)
    EditDisenchanters(panel, function(l)
        local j = index + delta
        if j >= 1 and j <= #l then l[index], l[j] = l[j], l[index] end
    end)
end

-- A small square glyph button (▲ / ▼ / ×) with an accent-on-hover label.
local function GlyphButton(parent, glyph)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(16, 16)
    b.fs = b:CreateFontString(nil, "OVERLAY")
    LCEX:ThemeText(b.fs, "body", "faint")
    b.fs:SetPoint("CENTER", 0, 0)
    b.fs:SetText(glyph)
    b:SetScript("OnEnter", function()
        b.fs:SetTextColor(LCEX.Theme.accent[1], LCEX.Theme.accent[2], LCEX.Theme.accent[3])
    end)
    b:SetScript("OnLeave", function() LCEX:ThemeText(b.fs, "body", "faint") end)
    return b
end

LCEX:RegisterCouncilModule({
    key = "sessioncfg", title = LCEX.L["Session Config"], order = 40,

    build = function(panel)
        local p = LCEX.db.profile

        -- Poll deadline -----------------------------------------------------------
        panel.timeout = LCEX:CreateSliderV2(panel, {
            width = 260, min = 0, max = 300, step = 15,
            label = LCEX.L["Poll response deadline"],
            fmt = function(v)
                if v <= 0 then return LCEX.L["Off"] end
                return string.format("%ds", v)
            end,
            get = function() return tonumber(p.pollTimeout) or 0 end,
            set = function(v) p.pollTimeout = v end,
        })
        panel.timeout:SetPoint("TOPLEFT", 14, -16)

        -- Anonymous voting (V7) — a SHARED-config field (replicated), so the whole council agrees
        -- for a session's lifetime. Right of the deadline slider, clear of the roster column below.
        panel.anon = LCEX:CreateCheckbox(panel, LCEX.L["Anonymous voting"],
            function() return LCEX:GetConfig().anonVoting end,
            function(v) LCEX:SetConfigField("anonVoting", v) end)
        panel.anon:SetPoint("TOPLEFT", 320, -24)

        -- Preferred disenchanters (V5) — a ranked SHARED-config list (top = highest priority; the
        -- highest present is auto-picked for a D/E award). Add by name; ▲/▼ reorder; × removes.
        panel.deLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.deLabel, "caption", "dim")
        panel.deLabel:SetPoint("TOPLEFT", 320, -56)
        panel.deLabel:SetText(LCEX.L["Disenchanters (D/E), ranked:"])

        panel.deAddBox = LCEX:CreateEditBox(panel, {
            width = 150,
            onCommit = function(text)
                text = strtrim(text or "")
                if text == "" then return end
                EditDisenchanters(panel, function(l)
                    for _, n in ipairs(l) do
                        if LCEX:NormalizeName(n) == LCEX:NormalizeName(text) then return end -- dedupe
                    end
                    table.insert(l, text)
                end)
                panel.deAddBox:SetText("")
            end,
        })
        panel.deAddBox:SetPoint("TOPLEFT", 324, -74)

        panel.deList = LCEX:CreateScrollList(panel, {
            rowHeight = 20, fillHeight = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.fs = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.fs, "body", "ink")
                row.fs:SetPoint("LEFT", 10, 0)
                row.remove = GlyphButton(row, "×")
                row.remove:SetPoint("RIGHT", -4, 0)
                row.down = GlyphButton(row, "▼")
                row.down:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
                row.up = GlyphButton(row, "▲")
                row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
                row.fs:SetPoint("RIGHT", row.up, "LEFT", -6, 0)
                row.fs:SetJustifyH("LEFT"); row.fs:SetWordWrap(false)
                return row
            end,
            fillRow = function(row, name, index)
                row.fs:SetText(string.format("%d. %s", index, name)) -- rank number + name
                row.up:SetScript("OnClick", function() MoveDisenchanter(panel, index, -1) end)
                row.down:SetScript("OnClick", function() MoveDisenchanter(panel, index, 1) end)
                row.remove:SetScript("OnClick", function()
                    EditDisenchanters(panel, function(l) table.remove(l, index) end)
                end)
            end,
        })
        panel.deList:SetPoint("TOPLEFT", 316, -100)
        panel.deList:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -8, -204)

        -- Council roster ----------------------------------------------------------
        panel.byRank = LCEX:CreateCheckbox(panel, LCEX.L["Include guild ranks at or above:"],
            function() return p.council.byRank end,
            function(v)
                p.council.byRank = v
                LCEX._councilSet = nil
                RefreshRoster(panel)
            end)
        panel.byRank:SetPoint("TOPLEFT", 14, -66)

        panel.rank = LCEX:CreateSliderV2(panel, {
            width = 200, min = 0, max = 9, step = 1,
            label = LCEX.L["Rank cutoff (0 = GM)"],
            fmt = function(v) return tostring(math.floor(v)) end,
            get = function() return p.council.rank or 1 end,
            set = function(v)
                p.council.rank = math.floor(v)
                LCEX._councilSet = nil
                RefreshRoster(panel)
            end,
        })
        panel.rank:SetPoint("TOPLEFT", 34, -96)

        panel.addLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.addLabel, "caption", "dim")
        panel.addLabel:SetPoint("TOPLEFT", 14, -146)
        panel.addLabel:SetText(LCEX.L["Extra members (any guild rank):"])

        panel.addBox = LCEX:CreateEditBox(panel, {
            width = 160,
            onCommit = function(text)
                text = strtrim(text or "")
                if text == "" then return end
                table.insert(p.council.extra, text)
                LCEX._councilSet = nil
                panel.addBox:SetText("")
                RefreshRoster(panel)
            end,
        })
        panel.addBox:SetPoint("TOPLEFT", 18, -164)

        panel.rosterCount = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.rosterCount, "caption", "faint")
        panel.rosterCount:SetPoint("TOPLEFT", 14, -192)

        -- The resolved council (rank members + extras); extras carry a remove ×.
        panel.rosterList = LCEX:CreateScrollList(panel, {
            rowHeight = 20, fillHeight = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.fs = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.fs, "body", "ink")
                row.fs:SetPoint("LEFT", 10, 0)
                row.remove = CreateFrame("Button", nil, row)
                row.remove:SetSize(16, 16)
                row.remove:SetPoint("LEFT", row.fs, "RIGHT", 8, 0)
                row.remove.fs = row.remove:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.remove.fs, "body", "faint")
                row.remove.fs:SetPoint("CENTER", 0, 0)
                row.remove.fs:SetText("×")
                row.remove:SetScript("OnClick", function()
                    LCEX:CmdCouncil("remove " .. (row.playerKey or ""))
                    RefreshRoster(panel)
                end)
                return row
            end,
            fillRow = function(row, name)
                row.playerKey = name
                row.fs:SetText(name)
                -- Only explicit extras are removable here; rank members come from the guild.
                local isExtra = false
                for _, n in ipairs(p.council.extra or {}) do
                    if LCEX:NormalizeName(n) == name then isExtra = true; break end
                end
                if isExtra then row.remove:Show() else row.remove:Hide() end
            end,
        })
        panel.rosterList:SetPoint("TOPLEFT", 4, -210)
        panel.rosterList:SetPoint("BOTTOMRIGHT", -4, 40)

        -- DL-8 placeholder ----------------------------------------------------------
        panel.dl8 = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.dl8, "caption", "faint")
        panel.dl8:SetPoint("BOTTOMLEFT", 14, 14)
        panel.dl8:SetText(LCEX.L["Response buttons: BiS / Major / Minor / Greed / Pass (editor coming later)."])
    end,

    show = function(panel)
        panel.timeout:Refresh()
        panel.anon:Refresh()
        panel.byRank:Refresh()
        panel.rank:Refresh()
        RefreshRoster(panel)
        RefreshDisenchanters(panel)
    end,
})
