-- ── LootCouncil EX — UI/council/HistoryModule.lua ────────────────────────────
-- Council module: the guild-wide award log, newest first, filterable by winner name. Rows
-- render the item (quality color via the link), the winner (class-colored where resolvable),
-- source boss and date, and the winner's response at award time.
--
-- Data: Core/Display.lua BuildHistoryLog(filter) over db.global.history (union sync dataset).
-- Loads after UI/CouncilWindow.lua; self-registers.

local LCEX = LootCouncilEX

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

LCEX:RegisterCouncilModule({
    key = "history", title = LCEX.L["History"], order = 30,

    build = function(panel)
        panel.filterLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.filterLabel, "caption", "dim")
        panel.filterLabel:SetPoint("TOPLEFT", 10, -12)
        panel.filterLabel:SetText(LCEX.L["Winner:"])

        panel.filterBox = LCEX:CreateEditBox(panel, { width = 160 })
        panel.filterBox:SetPoint("LEFT", panel.filterLabel, "RIGHT", 10, 0)
        panel.filterBox:SetScript("OnTextChanged", function(eb)
            panel.list:SetData(LCEX:BuildHistoryLog(eb:GetText()))
        end)

        panel.list = LCEX:CreateScrollList(panel, {
            rowHeight = 24, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.icon = LCEX:CreateItemIcon(row, 18)
                row.icon:SetPoint("LEFT", 6, 0)
                row.item = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.item, "body", "ink")
                row.item:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.item:SetWidth(220); row.item:SetJustifyH("LEFT"); row.item:SetWordWrap(false)
                row.winner = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.winner, "body", "ink")
                row.winner:SetPoint("LEFT", row.item, "RIGHT", 8, 0)
                row.winner:SetWidth(100); row.winner:SetJustifyH("LEFT"); row.winner:SetWordWrap(false)
                row.resp = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.resp, "caption", "dim")
                row.resp:SetPoint("LEFT", row.winner, "RIGHT", 8, 0)
                row.resp:SetWidth(50); row.resp:SetJustifyH("LEFT"); row.resp:SetWordWrap(false)
                row.meta = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.meta, "caption", "faint")
                row.meta:SetPoint("LEFT", row.resp, "RIGHT", 8, 0)
                row.meta:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.meta:SetJustifyH("LEFT"); row.meta:SetWordWrap(false)
                return row
            end,
            fillRow = function(row, rec)
                local icon = GetItemInfoInstant and rec.itemLink
                    and select(5, GetItemInfoInstant(rec.itemLink))
                row.icon:SetItem(rec.itemLink, icon)
                row.item:SetText(rec.itemLink or ("item:" .. tostring(rec.itemID)))
                row.winner:SetText(tostring(rec.player or "?"))
                local cc = LCEX:ClassColor(LCEX:ClassOf(rec.player) or LCEX:CachedClass(rec.player))
                row.winner:SetTextColor(cc[1], cc[2], cc[3])
                row.resp:SetText(LCEX:ResponseText(rec.resp))
                row.meta:SetText(string.format("%s · %s",
                    tostring(rec.boss or "?"), date("%m/%d %H:%M", rec.ts or 0)))
            end,
        })
        panel.list:SetPoint("TOPLEFT", 4, -36)
        panel.list:SetPoint("BOTTOMRIGHT", -4, 4)
    end,

    show = function(panel)
        panel.list:SetData(LCEX:BuildHistoryLog(panel.filterBox:GetText()))
    end,
})
