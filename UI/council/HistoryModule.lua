-- ── LootCouncil EX — UI/council/HistoryModule.lua ────────────────────────────
-- Council module: the guild-wide award log, newest first, filterable by winner name. Rows
-- render the item (quality color via the link), the winner (class-colored where resolvable),
-- source boss and date, and the winner's response at award time.
--
-- Data: Core/Display.lua BuildHistoryLog(filter) over db.global.history (union sync dataset).
-- Loads after UI/CouncilWindow.lua; self-registers.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

LCEX:RegisterCouncilModule({
    key = "history", title = LCEX.L["History"], order = 30,

    build = function(panel)
        -- Filter row on the grid line; the label sits low enough that the taller edit box
        -- centered on it still clears the panel top by the standard gap.
        panel.filterLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.filterLabel, "caption", "dim")
        panel.filterLabel:SetPoint("TOPLEFT", LAY.grid, -12)
        panel.filterLabel:SetText(LCEX.L["Winner:"])

        panel.filterBox = LCEX:CreateEditBox(panel, { width = 160 })
        panel.filterBox:SetPoint("LEFT", panel.filterLabel, "RIGHT", LAY.gap + LAY.editPad, 0)
        panel.filterBox:SetScript("OnTextChanged", function(eb)
            panel.list:SetData(LCEX:BuildHistoryLog(eb:GetText()))
        end)

        -- Export (§6.19): the current view (honoring the winner filter) as CSV / JSON / Discord,
        -- into the reused copy/paste frame.
        panel.exportBtn = LCEX:CreateFlatButton(panel, LCEX.L["Export"], 80, LAY.btnH)
        panel.exportBtn:SetPoint("LEFT", panel.filterBox, "RIGHT", LAY.gap, 0)
        panel.exportBtn:SetScript("OnClick", function()
            local filter = panel.filterBox:GetText()
            LCEX:ShowContextMenu({ anchor = panel.exportBtn, title = LCEX.L["Export as…"], items = {
                { text = LCEX.L["CSV"], onClick = function()
                    LCEX:ShowExportFrame(LCEX.L["Export (CSV)"], LCEX:ExportCSV(filter)) end },
                { text = LCEX.L["JSON"], onClick = function()
                    LCEX:ShowExportFrame(LCEX.L["Export (JSON)"], LCEX:ExportJSON(filter)) end },
                { text = LCEX.L["Discord"], onClick = function()
                    LCEX:ShowExportFrame(LCEX.L["Export (Discord)"], LCEX:ExportDiscord(filter)) end },
            } })
        end)

        panel.list = LCEX:CreateScrollList(panel, {
            rowHeight = 24, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Button", nil, parent)
                row:RegisterForClicks("RightButtonUp")
                row:SetScript("OnClick", function(r) LCEX:HistoryRecordMenu(r._uid, r._rec) end)
                -- When the winner (100px) / response (50px) / boss·date columns clip, hovering the
                -- row shows the full record at the cursor (the item itself is covered by the icon's
                -- own tooltip). Silent when everything already fits.
                row:SetScript("OnEnter", function(r)
                    local rec = r._rec
                    if not rec then return end
                    if not (r.winner:IsTruncated() or r.resp:IsTruncated() or r.meta:IsTruncated()) then return end
                    GameTooltip:SetOwner(r, "ANCHOR_CURSOR")
                    local d = LCEX.Theme.text.dim
                    GameTooltip:AddDoubleLine(LCEX.L["Winner:"], tostring(rec.player or "?"),
                        d[1], d[2], d[3], 1, 1, 1)
                    local respTxt = rec.retracted and LCEX.L["(retracted)"] or LCEX:HistoryReasonText(rec)
                    if respTxt and respTxt ~= "" then
                        GameTooltip:AddLine(tostring(respTxt), d[1], d[2], d[3])
                    end
                    GameTooltip:AddLine(string.format("%s · %s", tostring(rec.boss or "?"),
                        date("%m/%d %H:%M", rec.ts or 0)), d[1], d[2], d[3])
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.icon = LCEX:CreateItemIcon(row, 18)
                row.icon:SetPoint("LEFT", LAY.rowPad, 0)
                row.item = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.item, "body", "ink")
                row.item:SetPoint("LEFT", row.icon, "RIGHT", LAY.iconGap, 0)
                row.item:SetWidth(220); row.item:SetJustifyH("LEFT"); row.item:SetWordWrap(false)
                row.winner = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.winner, "body", "ink")
                row.winner:SetPoint("LEFT", row.item, "RIGHT", LAY.gap, 0)
                row.winner:SetWidth(100); row.winner:SetJustifyH("LEFT"); row.winner:SetWordWrap(false)
                row.resp = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.resp, "caption", "dim")
                row.resp:SetPoint("LEFT", row.winner, "RIGHT", LAY.gap, 0)
                row.resp:SetWidth(50); row.resp:SetJustifyH("LEFT"); row.resp:SetWordWrap(false)
                row.meta = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.meta, "caption", "faint")
                row.meta:SetPoint("LEFT", row.resp, "RIGHT", LAY.gap, 0)
                row.meta:SetPoint("RIGHT", row, "RIGHT", -LAY.rowPad, 0)
                row.meta:SetJustifyH("LEFT"); row.meta:SetWordWrap(false)
                return row
            end,
            fillRow = function(row, entry)
                local rec = entry.rec
                row._uid, row._rec = entry.uid, rec
                local icon = GetItemInfoInstant and rec.itemLink
                    and select(5, GetItemInfoInstant(rec.itemLink))
                row.icon:SetItem(rec.itemLink, icon)
                row.item:SetText(rec.itemLink or ("item:" .. tostring(rec.itemID)))
                row.winner:SetText(tostring(rec.player or "?"))
                -- Retracted records (§6.15) render dimmed with a "(retracted)" suffix — kept, not deleted.
                if rec.retracted then
                    LCEX:ThemeText(row.item, "body", "faint")
                    LCEX:ThemeText(row.winner, "body", "faint")
                    row.resp:SetText(LCEX.L["(retracted)"])
                else
                    LCEX:ThemeText(row.item, "body", "ink")
                    local cc = LCEX:ClassColor(LCEX:ClassOf(rec.player) or LCEX:CachedClass(rec.player))
                    row.winner:SetTextColor(cc[1], cc[2], cc[3])
                    row.resp:SetText(LCEX:HistoryReasonText(rec))
                end
                row.meta:SetText(string.format("%s · %s",
                    tostring(rec.boss or "?"), date("%m/%d %H:%M", rec.ts or 0)))
            end,
        })
        panel.list:SetPoint("TOPLEFT", LAY.bleed, -(LAY.gap + LAY.editH + LAY.gap))
        panel.list:SetPoint("BOTTOMRIGHT", -LAY.bleed, LAY.bleed)
    end,

    show = function(panel)
        panel.list:SetData(LCEX:BuildHistoryLog(panel.filterBox:GetText()))
    end,
})

-- Right-click a history record → the post-session correction path (§6.15, record-only): "Retract
-- record…" is offered only to the ML who LOGGED it (IsSelf(rec.by)) and only when not already
-- retracted. SetRecord stamps a fresh mod/by and propagates over pSet/pSync (LWW).
function LCEX:HistoryRecordMenu(uid, rec)
    if not (uid and rec) or rec.retracted then return end
    if not self:IsSelf(rec.by) then return end
    self:ShowContextMenu({ title = self.L["Correct record"], items = { {
        text = self.L["Retract record…"], danger = true,
        onClick = function()
            self:ShowConfirm({
                text = string.format(self.L["Retract the record of %s → %s? (record only)"],
                    tostring(rec.itemLink or "?"), tostring(rec.player or "?")),
                onAccept = function()
                    local copy = {}
                    for k, v in pairs(rec) do copy[k] = v end
                    copy.retracted, copy.retractedBy = true, UnitName("player")
                    self:SetRecord("history", uid, copy) -- stamps mod/by, broadcasts pSet
                    if self.councilWindow and self.councilWindow.panels
                        and self.councilWindow.panels.history then
                        local p = self.councilWindow.panels.history
                        p.list:SetData(self:BuildHistoryLog(p.filterBox:GetText()))
                    end
                end,
            })
        end,
    } } })
end
