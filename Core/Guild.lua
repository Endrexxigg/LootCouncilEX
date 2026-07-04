-- ── LootCouncil EX — Core/Guild.lua ──────────────────────────────────────────
-- Guild identity + present-roster helpers (foundations for Features V / C / B, PROJECT.md §6.9).
--   GuildKey()      — a stable per-guild key from GetGuildInfo, used to scope the shared config
--                     (and, in Feature C, the replicated datasets). The guild NAME only: every
--                     member must derive the SAME key for config to replicate, and a guild name is
--                     unique on its realm — realm-qualifying would instead break replication across
--                     connected realms (members read different GetRealmName). nil when guildless,
--                     so config editing falls to the solo escape hatch (C4).
--   PresentRoster() — { {name, class}, … } for the player plus every present raid/party member;
--                     used by Feature V's row seeding and the present-council vote tally. Always
--                     includes self, deduped by normalized name.
--
-- Loads after Core/Roster.lua. Headless-tested in Tests/run.lua.

local LCEX = LootCouncilEX

-- GetGuildInfo("player") → guildName, rankName, rankIndex on TBC (verify on the live client — the
-- addon never called this before; see PROJECT.md X3).
local GetGuildInfo = _G.GetGuildInfo

function LCEX:GuildKey()
    if not IsInGuild() or not GetGuildInfo then return nil end
    local name = GetGuildInfo("player")
    if not name or name == "" then return nil end
    return name
end

function LCEX:PresentRoster()
    local out, seen = {}, {}
    local function add(name, class)
        local key = self:NormalizeName(name)
        if key and not seen[key] then
            seen[key] = true
            out[#out + 1] = { name = name, class = class }
        end
    end
    add(UnitName("player"), select(2, UnitClass("player")))
    local inRaid = IsInRaid()
    for i = 1, (GetNumGroupMembers() or 0) do
        local unit = inRaid and ("raid" .. i) or ("party" .. i)
        local n = UnitName(unit)
        if n then add(n, select(2, UnitClass(unit))) end
    end
    return out
end
