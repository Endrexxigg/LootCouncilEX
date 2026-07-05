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

-- ── Guild scoping (Feature C, C6) ────────────────────────────────────────────
-- Every replicated dataset is guild-scoped so leaving a guild hides its data (§6.11). Rather than
-- re-home ~25 call sites, the ACTIVE guild's data always lives in the flat `db.global.<name>` tables
-- (every existing reader is unchanged); OTHER guilds' data is stashed under `db.global.guilds[key]`.
-- Switching guild (or leaving → key change) stashes the outgoing guild's data and loads the incoming
-- guild's — so an old guild's records are simply not present in the flat tables (hidden, not deleted;
-- rejoining restores them). Local recovery stores (pendingTrades/session) are NOT scoped — they are
-- live ML state, not council data (§6.11).
local SCOPED = { "notes", "marks", "history", "gearCache", "profCache", "config", "dummy",
                 "gbankCache", "gbankLog", "gbankNotes" }

function LCEX:SyncGuildScope()
    local g = self.db and self.db.global
    if not g then return end
    -- NEVER re-scope unless the guild is positively known. IsInGuild() reads FALSE transiently at
    -- login/reload before guild data loads — scoping then would stash the active guild's flat tables
    -- and blank them (no gear/gbank/notes visible) until GUILD_ROSTER_UPDATE recovered. So: not in a
    -- guild at all → don't touch the flat tables (a guildless user just uses them as-is); guilded but
    -- the name hasn't loaded → wait. Either way GUILD_ROSTER_UPDATE re-runs this once it settles.
    if not IsInGuild() then return end
    local key = self:GuildKey()
    if not key then return end
    if g.activeGuild == key then return end
    g.guilds = g.guilds or {}
    if g.activeGuild == nil then
        -- First run under guild scoping: the pre-existing flat tables ARE this guild's data. Claim
        -- them in place (moving them would blank existing notes/marks/history/caches/config).
        g.activeGuild = key
        return
    end
    -- Guild changed: stash the outgoing guild's flat tables, load the incoming guild's (empty if new).
    local out = g.activeGuild
    g.guilds[out] = g.guilds[out] or {}
    local incoming = g.guilds[key] or {}
    for _, name in ipairs(SCOPED) do
        g.guilds[out][name] = g[name]
        g[name] = incoming[name] or {}
    end
    g.guilds[key] = nil -- its data is live in the flat tables now; re-stashed on the next swap
    g.activeGuild = key
    self._inheritDecided, self._pendingInherit = nil, nil -- a new guild gets a fresh inherit decision
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
