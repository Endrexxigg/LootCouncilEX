-- ── LootCouncil EX — UI/council/SessionConfigModule.lua ──────────────────────
-- Council module: officer settings for running sessions. Council roster (guild-rank cutoff +
-- explicit extra members — the UI over profile.council, replacing /lcex council add/remove),
-- the poll response deadline (profile.pollTimeout, rides sStart), and a placeholder for the
-- DL-8 response-set editor. All edits invalidate the cached Plane-B council set.
--
-- Loads after UI/CouncilWindow.lua; self-registers.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

-- Two-column form: the left column sits on the panel's grid line; the right column starts at
-- COL2. Each column follows the same grammar — text/checkboxes on the column line, edit boxes
-- at +editPad, full-bleed lists at -rowPad (so their row text lands back on the column line).
local COL2 = 320

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

-- ── Announcement customization (DL-28) ───────────────────────────────────────
local ANNOUNCE_CHANNELS = { "auto", "RAID", "PARTY", "GUILD", "NONE" }
local function RefreshAnnounce(panel)
    local cfg = LCEX:GetConfig()
    local chan = cfg.announceChannel or "auto"
    panel.announceChan:SetText(string.format(LCEX.L["Announce channel: %s"], chan))
    local off = (chan == "NONE") -- NONE ⇒ no announce, so the message + items controls are moot (Cd3)
    panel.announceItems:SetFlatEnabled(not off)
    panel.announceItems:Refresh()
    if off then
        panel.awardTextLabel:Hide(); panel.awardTextBox:Hide()
    else
        panel.awardTextLabel:Show(); panel.awardTextBox:Show()
        panel.awardTextBox:SetText(cfg.awardText or "")
    end
end

-- ── Custom award reasons (DL-26; quick-pick, right-click the Award button) ───
local function RefreshAwardReasons(panel)
    panel.reasonList:SetData(LCEX:GetConfig().awardReasons or {})
end

local function EditAwardReasons(panel, fn)
    local cur, list = LCEX:GetConfig().awardReasons or {}, {}
    for i, n in ipairs(cur) do list[i] = n end
    fn(list)
    LCEX:SetConfigField("awardReasons", list)
    RefreshAwardReasons(panel)
end

-- ── Response buttons (DL-8, ranked; PASS pinned last) ────────────────────────
-- The editor shows the NORMALIZED set (ResponseSet, so PASS always appears pinned) and writes back
-- the minimal stored form {text, pass}. The CANONICAL stored list is customs-in-order + a single
-- PASS last, so a displayed row index maps 1:1 to a stored index — no separate index bookkeeping.
local function RefreshResponses(panel)
    panel.respList:SetData(LCEX:ResponseSet())
end

-- The current set as the canonical stored form (derived from the normalized set, so it always has
-- exactly one PASS, last). Seeds from config, else from the built-in defaults.
local function CurrentResponsesStored()
    local list = {}
    for _, r in ipairs(LCEX:ResponseSet()) do
        list[#list + 1] = { text = r.text, pass = (r.key == "PASS") or nil }
    end
    return list
end

-- Copy the canonical stored list, let `fn` mutate it, then replicate via SetConfigField (LWW).
local function EditResponses(panel, fn)
    local list = CurrentResponsesStored()
    fn(list)
    LCEX:SetConfigField("responses", list)
    RefreshResponses(panel)
end

-- Reorder a custom response; never moves PASS (always last) and never lets a custom step onto it.
local function MoveResponse(panel, index, delta)
    EditResponses(panel, function(l)
        local passAt = #l -- canonical: PASS is last
        local j = index + delta
        if index == passAt or j == passAt then return end
        if j >= 1 and j < passAt then l[index], l[j] = l[j], l[index] end
    end)
end

LCEX:RegisterCouncilModule({
    key = "sessioncfg", title = LCEX.L["Session Config"], order = 40,
    -- Officer-only (C3): hidden from non-council, with the C4 escape hatch (solo / GM / no config yet).
    visible = function() return LCEX:CanSeeSessionConfig() end,

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
        panel.timeout:SetPoint("TOPLEFT", LAY.grid, -16)

        -- Anonymous voting (V7) — a SHARED-config field (replicated), so the whole council agrees
        -- for a session's lifetime. Right of the deadline slider, clear of the roster column below.
        panel.anon = LCEX:CreateCheckbox(panel, LCEX.L["Anonymous voting"],
            function() return LCEX:GetConfig().anonVoting end,
            function(v) LCEX:SetConfigField("anonVoting", v) end)
        panel.anon:SetPoint("TOPLEFT", COL2, -16) -- column tops align with the deadline slider

        -- Announcement customization (DL-28): channel cycler + items toggle + a custom message
        -- template. The message box + items toggle grey/hide when the channel is NONE (Cd3).
        panel.announceChan = LCEX:CreateFlatButton(panel, "", 150, LAY.btnH)
        panel.announceChan:SetPoint("TOPLEFT", COL2, -42)
        panel.announceChan:SetScript("OnClick", function()
            local cur = LCEX:GetConfig().announceChannel or "auto"
            local idx = 1
            for i, c in ipairs(ANNOUNCE_CHANNELS) do if c == cur then idx = i; break end end
            LCEX:SetConfigField("announceChannel", ANNOUNCE_CHANNELS[(idx % #ANNOUNCE_CHANNELS) + 1])
            RefreshAnnounce(panel)
        end)

        panel.announceItems = LCEX:CreateCheckbox(panel, LCEX.L["Announce items at session start"],
            function() return LCEX:GetConfig().announceItems end,
            function(v) LCEX:SetConfigField("announceItems", v) end)
        panel.announceItems:SetPoint("TOPLEFT", COL2, -70)

        panel.awardTextLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.awardTextLabel, "caption", "dim")
        panel.awardTextLabel:SetPoint("TOPLEFT", COL2, -94)
        panel.awardTextLabel:SetText(LCEX.L["Custom award message (&p &i &r):"])
        panel.awardTextBox = LCEX:CreateEditBox(panel, {
            width = 200,
            onCommit = function(text) LCEX:SetConfigField("awardText", strtrim(text or "")) end,
        })
        panel.awardTextBox:SetPoint("TOPLEFT", COL2 + LAY.editPad, -112)

        -- Preferred disenchanters (V5) — a ranked SHARED-config list (top = highest priority; the
        -- highest present is auto-picked for a D/E award). Add by name; ▲/▼ reorder; × removes.
        panel.deLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.deLabel, "caption", "dim")
        panel.deLabel:SetPoint("TOPLEFT", COL2, -140)
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
        panel.deAddBox:SetPoint("TOPLEFT", COL2 + LAY.editPad, -158)

        panel.deList = LCEX:CreateScrollList(panel, {
            rowHeight = 20, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.fs = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.fs, "body", "ink")
                row.fs:SetPoint("LEFT", LAY.rowPad, 0)
                row.remove = GlyphButton(row, "×")
                row.remove:SetPoint("RIGHT", -LAY.gapTight, 0)
                row.down = GlyphButton(row, "▼")
                row.down:SetPoint("RIGHT", row.remove, "LEFT", -2, 0) -- paired glyphs: half a gapTight
                row.up = GlyphButton(row, "▲")
                row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
                row.fs:SetPoint("RIGHT", row.up, "LEFT", -LAY.inlineGap, 0)
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
        panel.deList:SetPoint("TOPLEFT", COL2 - LAY.rowPad, -184) -- bleed: row text back on COL2
        panel.deList:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -LAY.bleed, -276) -- fixed ~92px

        -- Council roster (Feature C: the officer-authored SHARED config, replicated — CouncilConfig
        -- reads it, SetCouncilConfig writes+broadcasts it; profile.council is the pre-config default).
        panel.byRank = LCEX:CreateCheckbox(panel, LCEX.L["Include guild ranks at or above:"],
            function() return LCEX:CouncilConfig().byRank end,
            function(v)
                LCEX:SetCouncilConfig({ byRank = v })
                RefreshRoster(panel)
            end)
        panel.byRank:SetPoint("TOPLEFT", LAY.grid, -66)

        panel.rank = LCEX:CreateSliderV2(panel, {
            width = 200, min = 0, max = 9, step = 1,
            label = LCEX.L["Rank cutoff (0 = GM)"],
            fmt = function(v) return tostring(math.floor(v)) end,
            get = function() return LCEX:CouncilConfig().rank or 1 end,
            set = function(v)
                LCEX:SetCouncilConfig({ rank = math.floor(v) })
                RefreshRoster(panel)
            end,
        })
        panel.rank:SetPoint("TOPLEFT", LAY.grid + 16 + LAY.iconGap, -96) -- flush with the byRank checkbox LABEL text

        panel.addLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.addLabel, "caption", "dim")
        panel.addLabel:SetPoint("TOPLEFT", LAY.grid, -146)
        panel.addLabel:SetText(LCEX.L["Extra members (any guild rank):"])

        panel.addBox = LCEX:CreateEditBox(panel, {
            width = 160,
            onCommit = function(text)
                text = strtrim(text or "")
                if text == "" then return end
                local extra = {}
                for _, n in ipairs(LCEX:CouncilConfig().extra or {}) do extra[#extra + 1] = n end
                extra[#extra + 1] = text
                LCEX:SetCouncilConfig({ extra = extra })
                panel.addBox:SetText("")
                RefreshRoster(panel)
            end,
        })
        panel.addBox:SetPoint("TOPLEFT", LAY.grid + LAY.editPad, -164)

        panel.rosterCount = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.rosterCount, "caption", "faint")
        panel.rosterCount:SetPoint("TOPLEFT", LAY.grid, -192)

        -- The resolved council (rank members + extras); extras carry a remove ×.
        panel.rosterList = LCEX:CreateScrollList(panel, {
            rowHeight = 20, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.fs = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.fs, "body", "ink")
                row.fs:SetPoint("LEFT", LAY.rowPad, 0)
                -- Pin the × to the row's RIGHT edge first, then right-bind the name to it so a long
                -- extra-member name truncates instead of shoving the × off the row (mirrors the
                -- disenchanter row above; the v0.52.3 layout follow-up).
                row.remove = CreateFrame("Button", nil, row)
                row.remove:SetSize(16, 16)
                row.remove:SetPoint("RIGHT", -LAY.gapTight, 0)
                row.remove.fs = row.remove:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.remove.fs, "body", "faint")
                row.remove.fs:SetPoint("CENTER", 0, 0)
                row.remove.fs:SetText("×")
                row.remove:SetScript("OnClick", function()
                    LCEX:CmdCouncil("remove " .. (row.playerKey or ""))
                    RefreshRoster(panel)
                end)
                row.fs:SetPoint("RIGHT", row.remove, "LEFT", -LAY.inlineGap, 0)
                row.fs:SetJustifyH("LEFT"); row.fs:SetWordWrap(false)
                return row
            end,
            fillRow = function(row, name)
                row.playerKey = name
                row.fs:SetText(name)
                -- Only explicit extras are removable here; rank members come from the guild.
                local isExtra = false
                for _, n in ipairs(LCEX:CouncilConfig().extra or {}) do
                    if LCEX:NormalizeName(n) == name then isExtra = true; break end
                end
                if isExtra then row.remove:Show() else row.remove:Hide() end
            end,
        })
        panel.rosterList:SetPoint("TOPLEFT", LAY.bleed, -212) -- a full gap under the extra-add box
        -- Left column, FIXED height (the award-reasons editor sits below it). Right edge before COL2.
        panel.rosterList:SetPoint("BOTTOMRIGHT", panel, "TOPLEFT", COL2 - LAY.gap, -360)

        -- Custom award reasons (DL-26) — quick-pick labels for the right-click "Award for…" menu.
        -- Left column, below the roster; add by name, × removes (no ranking — order is cosmetic).
        panel.reasonLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.reasonLabel, "caption", "dim")
        panel.reasonLabel:SetPoint("TOPLEFT", LAY.grid, -368)
        panel.reasonLabel:SetText(LCEX.L["Award reasons (right-click Award):"])

        panel.reasonAddBox = LCEX:CreateEditBox(panel, {
            width = 150,
            onCommit = function(text)
                text = strtrim(text or "")
                if text == "" then return end
                EditAwardReasons(panel, function(l)
                    for _, n in ipairs(l) do if n:lower() == text:lower() then return end end -- dedupe
                    l[#l + 1] = text
                end)
                panel.reasonAddBox:SetText("")
            end,
        })
        panel.reasonAddBox:SetPoint("TOPLEFT", LAY.grid + LAY.editPad, -386)

        panel.reasonList = LCEX:CreateScrollList(panel, {
            rowHeight = 20, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.fs = row:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.fs, "body", "ink")
                row.fs:SetPoint("LEFT", LAY.rowPad, 0)
                row.remove = GlyphButton(row, "×")
                row.remove:SetPoint("RIGHT", -LAY.gapTight, 0)
                row.fs:SetPoint("RIGHT", row.remove, "LEFT", -LAY.inlineGap, 0)
                row.fs:SetJustifyH("LEFT"); row.fs:SetWordWrap(false)
                return row
            end,
            fillRow = function(row, reason, index)
                row.fs:SetText(reason)
                row.remove:SetScript("OnClick", function()
                    EditAwardReasons(panel, function(l) table.remove(l, index) end)
                end)
            end,
        })
        panel.reasonList:SetPoint("TOPLEFT", LAY.bleed, -408)
        panel.reasonList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", COL2 - LAY.gap, 46)

        -- Loot-window visibility — a SHARED-config toggle, repurposed by Phase 12 (DL-18). Off:
        -- raiders get the rail-only list view (items/award state/winners). On: raiders get the
        -- FULL read-only view, responses and votes included.
        panel.vis = LCEX:CreateCheckbox(panel, LCEX.L["Show the full loot window (responses & votes) to all raiders"],
            function() local v = LCEX:GetConfig().visibility; return v and v.lootWindow end,
            function(v)
                local cur = LCEX:GetConfig().visibility or {}
                local nv = {}
                for k, val in pairs(cur) do nv[k] = val end
                nv.lootWindow = v
                LCEX:SetConfigField("visibility", nv)
            end)
        panel.vis:SetPoint("BOTTOMLEFT", LAY.grid, 40)

        -- Guild-bank log visibility (B5) — a SHARED-config toggle. Off by default (raiders see the
        -- bank's contents + gold, but not the log or annotations); on opens the log to the whole guild.
        panel.visGbank = LCEX:CreateCheckbox(panel, LCEX.L["Show the guild-bank log to all raiders"],
            function() local v = LCEX:GetConfig().visibility; return v and v.gbankLog end,
            function(v)
                local cur = LCEX:GetConfig().visibility or {}
                local nv = {}
                for k, val in pairs(cur) do nv[k] = val end
                nv.gbankLog = v
                LCEX:SetConfigField("visibility", nv)
            end)
        panel.visGbank:SetPoint("LEFT", panel.vis, "RIGHT", LAY.section, 0)

        -- Response buttons (DL-8) — the guild's response set, in the lower RIGHT column under the
        -- disenchanter list. Add by name; ▲/▼ reorder customs; × removes; click a name to rename.
        -- PASS is a pinned built-in (faint, no controls). Edits apply to the NEXT session (a live
        -- session keeps its snapshot, §6.5), which the label states.
        panel.respLabel = panel:CreateFontString(nil, "OVERLAY")
        LCEX:ThemeText(panel.respLabel, "caption", "dim")
        panel.respLabel:SetPoint("TOPLEFT", COL2, -288)
        panel.respLabel:SetText(LCEX.L["Response buttons — apply to the next session:"])

        panel.respAddBox = LCEX:CreateEditBox(panel, {
            width = 150,
            onCommit = function(text)
                text = strtrim(text or "")
                if text == "" then return end
                EditResponses(panel, function(l)
                    if #l >= (LCEX.MAX_RESPONSES or 8) then
                        LCEX:Msg(string.format(LCEX.L["Response limit is %d."], LCEX.MAX_RESPONSES or 8))
                        return
                    end
                    for _, e in ipairs(l) do
                        if e.text:lower() == text:lower() then return end -- dedupe (case-insensitive)
                    end
                    table.insert(l, #l, { text = text }) -- insert just before the pinned PASS
                end)
                panel.respAddBox:SetText("")
            end,
        })
        panel.respAddBox:SetPoint("TOPLEFT", COL2 + LAY.editPad, -306)

        panel.respList = LCEX:CreateScrollList(panel, {
            rowHeight = 20, fillHeight = true, zebra = true,
            buildRow = function(parent)
                local row = CreateFrame("Frame", nil, parent)
                row.swatch = row:CreateTexture(nil, "ARTWORK")
                row.swatch:SetTexture("Interface\\Buttons\\WHITE8X8")
                row.swatch:SetSize(10, 10)
                row.swatch:SetPoint("LEFT", LAY.rowPad, 0)
                row.remove = GlyphButton(row, "×")
                row.remove:SetPoint("RIGHT", -LAY.gapTight, 0)
                row.down = GlyphButton(row, "▼")
                row.down:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
                row.up = GlyphButton(row, "▲")
                row.up:SetPoint("RIGHT", row.down, "LEFT", -2, 0)
                -- Clickable name region (rename), bounded between the swatch and the glyph cluster.
                row.name = CreateFrame("Button", nil, row)
                row.name:SetHeight(18)
                row.name:SetPoint("LEFT", row.swatch, "RIGHT", LAY.iconGap, 0)
                row.name:SetPoint("RIGHT", row.up, "LEFT", -LAY.inlineGap, 0)
                row.name.fs = row.name:CreateFontString(nil, "OVERLAY")
                LCEX:ThemeText(row.name.fs, "body", "ink")
                row.name.fs:SetPoint("LEFT", 0, 0); row.name.fs:SetPoint("RIGHT", 0, 0)
                row.name.fs:SetJustifyH("LEFT"); row.name.fs:SetWordWrap(false)
                return row
            end,
            fillRow = function(row, r, index)
                local isPass = (r.key == "PASS")
                row.name.fs:SetText(r.text)
                local c = r.color or { 0.7, 0.7, 0.7 }
                row.swatch:SetVertexColor(c[1], c[2], c[3])
                if isPass then
                    LCEX:ThemeText(row.name.fs, "caption", "faint")
                    row.name.fs:SetText(string.format(LCEX.L["%s (built-in)"], r.text))
                    row.name:EnableMouse(false); row.name:SetScript("OnClick", nil)
                    row.up:Hide(); row.down:Hide(); row.remove:Hide()
                    return
                end
                LCEX:ThemeText(row.name.fs, "body", "ink")
                row.up:Show(); row.down:Show(); row.remove:Show()
                row.name:EnableMouse(true)
                row.name:SetScript("OnClick", function()
                    LCEX:ShowConfirm({
                        text  = string.format(LCEX.L["Rename response \"%s\" to:"], r.text),
                        input = r.text,
                        onAccept = function(newText)
                            newText = strtrim(newText or "")
                            if newText == "" then return end
                            EditResponses(panel, function(l) if l[index] then l[index].text = newText end end)
                        end,
                    })
                end)
                row.up:SetScript("OnClick", function() MoveResponse(panel, index, -1) end)
                row.down:SetScript("OnClick", function() MoveResponse(panel, index, 1) end)
                row.remove:SetScript("OnClick", function()
                    -- Keep at least one custom + PASS (never remove PASS, never empty the set).
                    EditResponses(panel, function(l)
                        if index ~= #l and #l > 2 then table.remove(l, index) end
                    end)
                end)
            end,
        })
        panel.respList:SetPoint("TOPLEFT", COL2 - LAY.rowPad, -332)
        panel.respList:SetPoint("BOTTOMRIGHT", -LAY.bleed, 64)
    end,

    show = function(panel)
        panel.timeout:Refresh()
        panel.anon:Refresh()
        panel.byRank:Refresh()
        panel.rank:Refresh()
        panel.vis:Refresh()
        panel.visGbank:Refresh()
        RefreshRoster(panel)
        RefreshDisenchanters(panel)
        RefreshResponses(panel)
        RefreshAwardReasons(panel)
        RefreshAnnounce(panel)
    end,
})
