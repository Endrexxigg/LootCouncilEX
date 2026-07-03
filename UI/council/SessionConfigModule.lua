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
        panel.byRank:Refresh()
        panel.rank:Refresh()
        RefreshRoster(panel)
    end,
})
