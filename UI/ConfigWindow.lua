-- ── LootCouncil EX — UI/ConfigWindow.lua ─────────────────────────────────────
-- The `config` frame: user-level settings, rendered from a SCHEMA so future options are one
-- table entry (header/checkbox/slider rows stacked vertically, all profile-backed and applied
-- live). Officer/session settings live in the council window's Session Config module instead.
--
-- Appearance plumbing: profile.appearance {scale, opacity, bgOpacity} — ApplyAppearance()
-- pushes all three to every v2 window via RefreshAppearance (opacity only where the window
-- opted in — council; bgOpacity is the backdrop-only alpha the loot/poll windows layer on).
--
-- Loads after UI/Theme.lua + UI/Widgets.lua.

local LCEX = LootCouncilEX
local LAY  = LCEX.LAYOUT -- the shared layout contract (UI/Theme.lua)

local FRAME_NAME = "LCEX_ConfigWindow"
local WIN_W      = 360

-- Push profile.appearance to every created v2 window (each carries RefreshAppearance).
-- Iterate by FIELD NAME: an array literal of window references gets nil holes for windows
-- that don't exist yet, and ipairs stops at the first hole.
local WINDOW_FIELDS = { "pollFrame", "lootWindow", "councilWindow", "configWindow", "tradeTimerWindow" }
function LCEX:ApplyAppearance()
    for _, field in ipairs(WINDOW_FIELDS) do
        local win = self[field]
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
        -- Backdrop-only (SetSurfaceAlpha): the loot session + loot drop panels go translucent,
        -- text/buttons/icons stay crisp — so they can sit over the raid UI without blocking it.
        { type = "slider", label = self.L["Loot window background opacity"], min = 0.3, max = 1.0, step = 0.05,
          get = function() return p.appearance.bgOpacity or 1.0 end,
          set = function(v) p.appearance.bgOpacity = v; self:ApplyAppearance() end },

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
        { type = "checkbox", label = self.L["Show trade timers"],
          get = function() return p.tradeTimersAuto end,
          set = function(v)
              p.tradeTimersAuto = v
              if self.UpdateTradeTimerWindow then self:UpdateTradeTimerWindow() end
          end },
        { type = "slider", label = self.L["Trade timer rows"], min = 0, max = 20, step = 1,
          fmt = function(v)
              v = math.floor(v)
              if v <= 0 then return self.L["All"] end
              return tostring(v)
          end,
          get = function() return p.tradeTimersMaxRows or 10 end,
          set = function(v)
              p.tradeTimersMaxRows = math.floor(v)
              if self.UpdateTradeTimerWindow then self:UpdateTradeTimerWindow() end
          end },
    }
end

function LCEX:EnsureConfigWindow()
    if self.configWindow then return self.configWindow end
    local f = self:CreateWindowV2(FRAME_NAME, {
        width = WIN_W, height = 440,
        title = self.L["Configuration"],
        savedKey = "config",
        defaultPos = { x = -220, y = 60 },
    })

    -- Bare window: every control sits on the LAYOUT.grid line, symmetric left/right. Rows
    -- advance by control height + gap; headers keep a small extra breath (gapTight) above.
    f.controls = {}
    local y = -(LAY.contentTop + LAY.grid)
    for _, entry in ipairs(BuildSchema(self)) do
        local control
        if entry.type == "header" then
            control = f:CreateFontString(nil, "OVERLAY")
            self:ThemeText(control, "caption", "faint")
            control:SetPoint("TOPLEFT", LAY.grid, y - LAY.gapTight)
            control:SetText(tostring(entry.label):upper())
            y = y - 24
        elseif entry.type == "checkbox" then
            control = self:CreateCheckbox(f, entry.label, entry.get, entry.set)
            control:SetPoint("TOPLEFT", LAY.grid, y)
            y = y - (LAY.btnHSlim + LAY.gap)
        elseif entry.type == "slider" then
            control = self:CreateSliderV2(f, {
                width = WIN_W - 2 * LAY.grid, min = entry.min, max = entry.max, step = entry.step,
                label = entry.label, fmt = entry.fmt, get = entry.get, set = entry.set,
            })
            control:SetPoint("TOPLEFT", LAY.grid, y)
            y = y - (34 + LAY.gap) -- CreateSliderV2's wrap is 34 tall
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
