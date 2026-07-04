-- ── LootCouncil EX — council/Config.lua ──────────────────────────────────────
-- Plane B: the guild's SHARED loot-council config (foundations, PROJECT.md §6.9). One officer-
-- authored record per guild, keyed by GuildKey (Core/Guild.lua) and replicated LWW over the sync
-- engine exactly like notes/marks — so BuildDigest/pHello reconcile it for free. It is the single
-- home for settings every member must agree on:
--   • Feature V fills anonVoting + disenchanters (the DEFAULTS below).
--   • Feature C moves the council rank/extra roster + the response set here (resolving DL-1/DL-8)
--     and adds per-guild visibility rules.
-- GetConfig() always returns a defaults-merged snapshot (never nil); writes go through
-- SetConfigField, which stamps mod/by and broadcasts pSet (officer-gated at the UI layer in
-- Feature C). The "_local" key is the guildless/solo fallback so config stays editable while
-- testing (the C4 escape hatch).
--
-- Loads after Sync.lua (RegisterDataset/SetRecord) and Guild.lua (GuildKey).

local LCEX = LootCouncilEX

LCEX:RegisterDataset("config", "lww", function() return LCEX.db.global.config end)

-- Feature-V config fields + their defaults. Feature C extends this (rank/extra/responses/
-- visibility). The `disenchanters` default is a SHARED empty list when no record exists — callers
-- read it, they must not mutate it.
local DEFAULTS = { anonVoting = false, disenchanters = {}, announceAwards = true }

-- Record key for the current guild's config, or a local sentinel when guildless (solo testing).
function LCEX:ConfigKey()
    return self:GuildKey() or "_local"
end

-- The RAW stored config record for this guild, or nil if none is authored yet — distinct from
-- GetConfig, which always returns a defaults-merged view. Callers use this to tell "authored" from
-- "default" (Feature C: the council roster + escape hatch decide off whether a record exists).
function LCEX:ConfigRecord()
    return self.db.global.config[self:ConfigKey()]
end

-- The current guild's shared config with defaults merged in (never nil). A fresh table each call,
-- so callers can't accidentally mutate the stored record (mod/by are stripped from the view).
function LCEX:GetConfig()
    local out = {}
    for k, v in pairs(DEFAULTS) do out[k] = v end
    local rec = self.db.global.config[self:ConfigKey()]
    if rec then
        for k, v in pairs(rec) do
            if k ~= "mod" and k ~= "by" then out[k] = v end
        end
    end
    return out
end

-- Set several shared-config fields at once and replicate them (LWW) in ONE write. Preserves the
-- record's other fields; seeds from DEFAULTS when no record exists yet. The atomic form matters for
-- the council roster (byRank/rank/extra move together, C1) so a first edit can't drop the others.
function LCEX:SetConfigFields(fields)
    local key = self:ConfigKey()
    local cur = self.db.global.config[key]
    local rec = {}
    if cur then
        for k, v in pairs(cur) do if k ~= "mod" and k ~= "by" then rec[k] = v end end
    else
        for k, v in pairs(DEFAULTS) do rec[k] = v end
    end
    for k, v in pairs(fields) do rec[k] = v end
    self:SetRecord("config", key, rec)
end

-- Set one shared-config field and replicate it (LWW). Preserves the record's other fields.
function LCEX:SetConfigField(field, value)
    self:SetConfigFields({ [field] = value })
end
