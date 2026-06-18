-- ── LootCouncil EX — Data/DataAPI.lua ────────────────────────────────────────
-- Pure accessors over the static Loot / BiS / TierTokens tables. NO frames, NO comms — just
-- read helpers, so they are fully headless-unit-testable (Tests/run.lua). The UI (LootBrowser,
-- PlayerDetail BiS tab) reads exclusively through these, never the raw tables, so a Phase-7
-- content swap can't break the UI.
--
-- Loads after Loot/BiS/TierTokens (it reads them at call time, not at load).

local LCEX = LootCouncilEX

-- Display order of content phases, and the canonical equipment-slot order for BiS rows.
LCEX.PHASES = { "P1", "P2", "P3", "P4", "P5" }
LCEX.BIS_SLOT_ORDER = {
    "head", "neck", "shoulder", "back", "chest", "wrist", "hands",
    "waist", "legs", "feet", "finger", "trinket", "mainhand", "offhand", "ranged",
}

-- ── Loot ─────────────────────────────────────────────────────────────────────
-- Phase keys that actually have loot data, in PHASES order.
function LCEX:GetLootPhases()
    local out = {}
    for _, p in ipairs(self.PHASES) do
        if self.Loot[p] then out[#out + 1] = p end
    end
    return out
end

-- Raids in a phase (alphabetical, stable for display).
function LCEX:GetRaidsForPhase(phase)
    local out = {}
    local raids = self.Loot[phase] and self.Loot[phase].raids
    if raids then for name in pairs(raids) do out[#out + 1] = name end end
    table.sort(out)
    return out
end

-- Bosses in a raid, in kill order (`_order`) where given, else alphabetical.
function LCEX:GetBossesForRaid(phase, raid)
    local r = self.Loot[phase] and self.Loot[phase].raids and self.Loot[phase].raids[raid]
    if not r then return {} end
    local out = {}
    if r._order then
        for _, boss in ipairs(r._order) do
            if r[boss] then out[#out + 1] = boss end
        end
        return out
    end
    for boss in pairs(r) do
        if boss ~= "_order" then out[#out + 1] = boss end
    end
    table.sort(out)
    return out
end

function LCEX:GetItemsForBoss(phase, raid, boss)
    local r = self.Loot[phase] and self.Loot[phase].raids and self.Loot[phase].raids[raid]
    return (r and r[boss]) or {}
end

-- ── BiS ──────────────────────────────────────────────────────────────────────
function LCEX:GetBiSSpecs(class)
    local out = {}
    local c = class and self.BiS[class]
    if c then for spec in pairs(c) do out[#out + 1] = spec end end
    table.sort(out)
    return out
end

function LCEX:GetBiSItems(class, spec, phase, slot)
    local c = self.BiS[class]
    local s = c and c[spec]
    local p = s and s[phase]
    return (p and p[slot]) or {}
end

-- Slot-ordered list { {slot=, items={...}}, ... } for a spec+phase (only slots that have data).
function LCEX:GetBiSForSpecPhase(class, spec, phase)
    local out = {}
    for _, slot in ipairs(self.BIS_SLOT_ORDER) do
        local items = self:GetBiSItems(class, spec, phase, slot)
        if #items > 0 then
            out[#out + 1] = { slot = slot, items = items }
        end
    end
    return out
end

-- ── Tier tokens ──────────────────────────────────────────────────────────────
function LCEX:GetTierToken(tokenID) return self.TierTokens[tokenID] end

function LCEX:GetTierPieceForClass(tokenID, class)
    local t = self.TierTokens[tokenID]
    return t and t.pieces and t.pieces[class]
end

-- Cross-ref: if `itemID` is itself a tier token, return its record (name + pieces) so the
-- browser can annotate "token → <class> gets <piece>". nil for a normal item.
function LCEX:FindTokenForItem(itemID)
    return self.TierTokens[itemID]
end
