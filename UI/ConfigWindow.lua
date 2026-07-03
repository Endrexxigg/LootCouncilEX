-- ── LootCouncil EX — UI/ConfigWindow.lua ─────────────────────────────────────
-- The `config` frame: user-level settings, rendered from a SCHEMA so future options are one
-- table entry (header/checkbox/slider rows stacked vertically, all profile-backed and applied
-- live). Officer/session settings live in the council window's Session Config module instead.
--
-- Appearance plumbing: profile.appearance {scale, opacity} — ApplyAppearance() pushes both to
-- every v2 window (opacity only where the window opted in; the council window did).
--
-- Loads after UI/Theme.lua + UI/Widgets.lua.

local LCEX = LootCouncilEX

local FRAME_NAME = "LCEX_ConfigWindow"

-- Push profile.appearance to every open v2 window (each carries RefreshAppearance).
function LCEX:ApplyAppearance()
    for _, win in ipairs({ self.pollFrame, self.lootWindow, self.councilWindow, self.configWindow }) do
        if win and win.RefreshAppearance then win:RefreshAppearance() end
    end
end

local QUALITY_NAMES = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }

local function BuildSchema(self)
    local p = self.db.profile
    return {
        { type = "header", label = self.L["Appearance"] },
        { type = "slider", label = self.L["Window scale"], min = 0.5, max = 2.0, step = 0.05,
          get = function() return p.appearance.scale end,
          set = function(v) p.appearance.scale = v; self:ApplyAppearance() end },
        { type = "slider", label = self.L["Council window opacity"], min = 0.3, max = 1.0, step = 0.05,
          get = function() return p.appearance.opacity end,
          set = function(v) p.appearance.opacity = v; self:ApplyAppearance() end },

        { type = "header", label = self.L["Minimap"] },
        { type = "checkbox", label = self.L["Show the minimap button"],
          get = function() return not p.minimap.hide end,
          set = function(v)
              p.minimap.hide = not v
              if self.UpdateMinimapButton then self:UpdateMinimapButton() end
          end },

        { type = "header", label = self.L["Loot"] },
        { type = "slider", label = self.L["Loot quality threshold"], min = 2, max = 5, step = 1,
          fmt = function(v) return QUALITY_NAMES[math.floor(v)] or tostring(v) end,
          get = function() return p.minQuality or 4 end,
          set = function(v) p.minQuality = math.floor(v) end },
        { type = "checkbox", label = self.L["Broadcast my gear/professions (self-report)"],
          get = function() return p.selfReport end,
          set = function(v) p.selfReport = v end },
    }
end

function LCEX:EnsureConfigWindow()
    if self.configWindow then return self.configWindow end
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = 360, height = 400,
        title = self.L["Configuration"],
        savedKey = "config",
        defaultPos = { x = -220, y = 60 },
    })

    f.controls = {}
    local y = -44
    for _, entry in ipairs(BuildSchema(self)) do
        local control
        if entry.type == "header" then
            control = f:CreateFontString(nil, "OVERLAY")
            self:ThemeText(control, "caption", "faint")
            control:SetPoint("TOPLEFT", 16, y - 4)
            control:SetText(tostring(entry.label):upper())
            y = y - 24
        elseif entry.type == "checkbox" then
            control = self:CreateCheckbox(f, entry.label, entry.get, entry.set)
            control:SetPoint("TOPLEFT", 18, y)
            y = y - 28
        elseif entry.type == "slider" then
            control = self:CreateSliderV2(f, {
                width = 300, min = entry.min, max = entry.max, step = entry.step,
                label = entry.label, fmt = entry.fmt, get = entry.get, set = entry.set,
            })
            control:SetPoint("TOPLEFT", 18, y)
            y = y - 44
        end
        f.controls[#f.controls + 1] = control
    end

    self.configWindow = f
    return f
end

function LCEX:ToggleConfigWindow()
    local f = self:EnsureConfigWindow()
    if f:IsShown() then
        f:Hide()
    else
        for _, c in ipairs(f.controls) do
            if c.Refresh then c:Refresh() end
        end
        f:Show()
    end
end
