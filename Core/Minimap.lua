-- ── LootCouncil EX — Core/Minimap.lua ────────────────────────────────────────
-- The minimap button: a LibDataBroker launcher rendered by LibDBIcon (position + hide flag
-- live in profile.minimap, owned by the lib). Click routing: left → loot window, right →
-- council dashboard, ctrl+click → config. Both libs are silent-optional so a stripped
-- install (or the headless harness) degrades to no button rather than an error.
--
-- Loads after Init/Comms (wired from OnEnable via SetupMinimapButton).

local LCEX = LootCouncilEX

local BUTTON_NAME = "LootCouncilEX"

function LCEX:SetupMinimapButton()
    local ldb = LibStub("LibDataBroker-1.1", true)
    local dbi = LibStub("LibDBIcon-1.0", true)
    if not (ldb and dbi) then return end

    local obj = ldb:NewDataObject(BUTTON_NAME, {
        type = "launcher",
        icon = "Interface\\Icons\\INV_Misc_Coin_02",
        OnClick = function(_, button)
            if IsControlKeyDown() then
                LCEX:ToggleConfigWindow()
            elseif button == "RightButton" then
                LCEX:ToggleCouncilWindow()
            else
                LCEX:ToggleLootWindow()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("LootCouncil EX")
            tt:AddLine(LCEX.L["|cff9aa0adClick|r loot  ·  |cff9aa0adRight-click|r council  ·  |cff9aa0adCtrl-click|r config"])
        end,
    })
    dbi:Register(BUTTON_NAME, obj, self.db.profile.minimap)
    self:UpdateMinimapButton()
end

-- Config-window toggle target: apply the current hide flag.
function LCEX:UpdateMinimapButton()
    local dbi = LibStub("LibDBIcon-1.0", true)
    if not dbi then return end
    if self.db.profile.minimap.hide then
        dbi:Hide(BUTTON_NAME)
    else
        dbi:Show(BUTTON_NAME)
    end
end
