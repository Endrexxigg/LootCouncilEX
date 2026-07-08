-- ── LootCouncil EX — tools/atlas_import.lua ──────────────────────────────────
-- DEV-TIME importer (NOT shipped, NOT run by CI). Sandbox-loads the installed AtlasLoot TBC data
-- and emits loot.csv rows for whitelisted raids, so a new content phase is a review-and-append
-- instead of hand-transcribing itemIDs. It reverse-engineers only the SHAPE it needs and stubs
-- everything else, so AtlasLoot's own internals can't break it.
--
--   lua tools/atlas_import.lua [atlasRoot]        # print P3 loot.csv rows + a summary to stdout
--
-- atlasRoot defaults to the standard Anniversary AddOns dir. Review the printed rows, then append
-- them under a `# ── P3` section in tools/sources/loot.csv and run `lua tools/build_data.lua`
-- (P1/P2 bytes stay untouched, so there is no drift). Runs under the same standalone Lua as the
-- harness (uses load(...,env), not the 5.1-only setfenv).

local atlasRoot = arg[1]
    or "C:/Program Files (x86)/World of Warcraft/_anniversary_/Interface/AddOns"
local DATA_TBC = atlasRoot .. "/AtlasLootClassic_DungeonsAndRaids/data-tbc.lua"

-- AtlasLoot instance key → (phase, our display raid name). Only these are imported; everything
-- else AtlasLoot defines is ignored, which is what makes the walk robust to its other content.
local RAID_WHITELIST = {
    HyjalSummit = { phase = "P3", display = "Hyjal Summit" },
    BlackTemple = { phase = "P3", display = "Black Temple" },
}

-- ── Sandbox ──────────────────────────────────────────────────────────────────
-- A permissive auto-vivifying stub: callable and indexable, so ANY unknown AtlasLoot API chain the
-- data file touches (colors, module registration, …) is inert instead of erroring.
local function makeStub()
    return setmetatable({}, {
        __index = function() return makeStub() end,
        __call  = function() return makeStub() end,
        __newindex = function() end,
    })
end

local NORMAL_SENTINEL      -- the sentinel AtlasLoot's data:AddDifficulty("NORMAL") returns; each
                           -- boss stores its drop list under [NORMAL_DIFF] = this exact table.

-- The `data` object returned by AtlasLoot.ItemDB:Add. It doubles as the container the file writes
-- `data["RaidName"] = {...}` into AND the object it calls difficulty/type/content methods on.
local function makeDataTable()
    local d = {}
    function d.AddDifficulty(_, name)
        local sentinel = { __diff = name }
        if name == "NORMAL" and not NORMAL_SENTINEL then NORMAL_SENTINEL = sentinel end
        return sentinel
    end
    function d.AddItemTableType(_) return { __itt = true } end
    function d.AddExtraItemTableType(_) return { __xitt = true } end
    function d.AddContentType(_) return { __ct = true } end
    return d
end

local capturedData
local function makeAtlasLoot()
    local locale = setmetatable({}, { __index = function(_, k) return k end }) -- AL["X"] → "X"
    -- Version gates: we are AT the current (TBC) version, so LT any version = false and GE any past
    -- version = true. Any OTHER unknown AtlasLoot method falls back to an inert stub (over-including
    -- content is harmless — we only read whitelisted raids' item lists).
    local al = {
        BC_VERSION_NUM = 20500,
        WOTLK_VERSION_NUM = 30300, VANILLA_VERSION_NUM = 11500,
        GameVersion_LT = function() return false end,
        GameVersion_GE = function() return true end,
        GameVersion_GT = function() return false end,
        GameVersion_LE = function() return true end,
        Locales        = locale,
        IngameLocales  = locale,
        ItemDB = { Add = function() capturedData = makeDataTable(); return capturedData end },
    }
    return setmetatable(al, { __index = function() return makeStub() end })
end

local function loadAtlas(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path .. " — is AtlasLoot installed?")
    local src = f:read("*a"); f:close()

    local env = {}
    env._G = env
    env.string, env.table, env.math = string, table, math
    env.tonumber, env.tostring, env.type = tonumber, tostring, type
    env.pairs, env.ipairs, env.select, env.next = pairs, ipairs, select, next
    env.setmetatable, env.getmetatable = setmetatable, getmetatable
    env.rawset, env.rawget, env.rawequal = rawset, rawget, rawequal
    env.unpack, env.print, env.error, env.assert, env.pcall = (unpack or table.unpack), print, error, assert, pcall
    env.format = string.format
    env.getfenv = function() return env end -- data file opens with `local _G = getfenv(0)`
    env.setfenv = function() end
    env.AtlasLoot = makeAtlasLoot()
    setmetatable(env, { __index = function() return makeStub() end }) -- unknown globals → inert stub

    local chunk = assert(load(src, "@" .. path, "t", env))
    chunk("AtlasLootClassic_DungeonsAndRaids") -- the file reads its addon name from `...`
    return capturedData
end

-- ── Extract ──────────────────────────────────────────────────────────────────
local data = loadAtlas(DATA_TBC)
assert(data, "AtlasLoot data never registered (ItemDB:Add not called) — format changed?")
assert(NORMAL_SENTINEL, "NORMAL difficulty sentinel not captured — format changed?")

local rows, summary = {}, {}
for key, wl in pairs(RAID_WHITELIST) do
    local raid = data[key]
    assert(type(raid) == "table" and type(raid.items) == "table",
        "raid not found or shapeless: " .. key)
    local bosses, items = 0, 0
    for i, boss in ipairs(raid.items) do
        local name = boss.name
        local order = tonumber(boss.AtlasMapBossID) or i
        local drops = boss[NORMAL_SENTINEL]
        -- Only real encounters (an npcID — a number, or a table for multi-NPC councils like the
        -- Illidari Council). This drops AtlasLoot's aggregate entries (Trash / Patterns / "Tier 6
        -- Sets"), which aren't boss drops the council cares about.
        if type(name) == "string" and type(drops) == "table" and boss.npcID ~= nil then
            bosses = bosses + 1
            for _, row in ipairs(drops) do
                local itemID = tonumber(row[2])
                if itemID and itemID > 0 then
                    items = items + 1
                    rows[#rows + 1] = { phase = wl.phase, raid = wl.display, order = order,
                                        boss = name, itemID = itemID }
                end
            end
        end
    end
    summary[#summary + 1] = string.format("%-14s → %-14s: %d bosses, %d items",
        key, wl.display, bosses, items)
    -- Sanity gates (loose, just to catch a broken parse). Hyjal = 5 bosses, BT = 9.
    local expect = (key == "HyjalSummit" and 5) or (key == "BlackTemple" and 9) or nil
    if expect and bosses ~= expect then
        io.stderr:write(string.format("WARNING: %s parsed %d bosses, expected %d\n", key, bosses, expect))
    end
end

-- Stable order: raid, then boss kill order, then itemID.
table.sort(rows, function(a, b)
    if a.raid ~= b.raid then return a.raid < b.raid end
    if a.order ~= b.order then return a.order < b.order end
    return a.itemID < b.itemID
end)

-- ── Emit ──────────────────────────────────────────────────────────────────────
print("# ── P3 (generated by tools/atlas_import.lua — review before appending to loot.csv) ──")
local curRaid
for _, r in ipairs(rows) do
    if r.raid ~= curRaid then
        curRaid = r.raid
        print("# ── " .. curRaid .. " ──")
    end
    print(string.format("%s,%s,%d,%s,%d", r.phase, r.raid, r.order, r.boss, r.itemID))
end
io.stderr:write("\n== summary ==\n")
for _, s in ipairs(summary) do io.stderr:write(s .. "\n") end
io.stderr:write(string.format("total: %d rows\n", #rows))
