-- ── LootCouncil EX — UI/Widgets.lua ──────────────────────────────────────────
-- Native-frame style layer + factory. NO AceGUI (PROJECT.md §2): every frame in the addon
-- is a CreateFrame built through these helpers, so the look stays consistent and the TBC
-- gotchas live in one place — explicit Show()/Hide() (SetShown is retail-only) and ESC-close
-- via UISpecialFrames.
--
-- Loads before the frame modules (LootFrame/VotingFrame/SessionFrame) that build on it.

local LCEX = LootCouncilEX

-- Shared style tokens — one source of truth for metrics/colors so frames match.
LCEX.STYLE = {
    backdrop = {
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    },
    pad       = 14,
    rowHeight = 30,
}

-- Create a movable, ESC-closable titled window. `name` is the GLOBAL frame name (required
-- for UISpecialFrames). `opts` = { width, height, title, savedKey }. savedKey, if given,
-- persists the window position into db.profile.ui[savedKey].
function LCEX:CreateWindow(name, opts)
    opts = opts or {}
    local addon = self

    -- Guarded template (Gargul's pattern): if BackdropTemplate is ever absent, pass nil and
    -- skip the backdrop rather than erroring out of CreateFrame.
    local f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(opts.width or 360, opts.height or 280)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    if f.SetBackdrop then f:SetBackdrop(self.STYLE.backdrop) end
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self2)
        self2:StopMovingOrSizing()
        if opts.savedKey and addon.db then
            local p = addon.db.profile.ui[opts.savedKey]
            if p then
                local point, _, relPoint, x, y = self2:GetPoint()
                p.point, p.relPoint, p.x, p.y = point, relPoint, x, y
            end
        end
    end)

    -- Restore a saved position.
    if opts.savedKey and self.db then
        local p = self.db.profile.ui[opts.savedKey]
        if p and p.point then
            f:ClearAllPoints()
            f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
        end
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText(opts.title or "")
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    f.closeButton = close

    tinsert(UISpecialFrames, name) -- ESC closes it
    f:Hide()
    return f
end

-- A standard push button.
function LCEX:CreateButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 80, height or 22)
    b:SetText(text or "")
    return b
end

-- A FontString label on `parent`.
function LCEX:CreateLabel(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    if text then fs:SetText(text) end
    return fs
end

-- A small item-icon button that shows the item tooltip on hover. :SetItem(link, icon).
function LCEX:CreateItemIcon(parent, size)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size or 24, size or 24)
    btn.tex = btn:CreateTexture(nil, "ARTWORK")
    btn.tex:SetAllPoints()
    btn.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn:SetScript("OnEnter", function(self2)
        if self2.itemLink then
            GameTooltip:SetOwner(self2, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self2.itemLink)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function btn.SetItem(iconBtn, link, icon)
        iconBtn.itemLink = link
        iconBtn.tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
    return btn
end
