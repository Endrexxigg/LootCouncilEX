-- ── LootCouncil EX — Core/GearIssues.lua ─────────────────────────────────────
-- The gear-issue detector (Feature G, PROJECT.md §6.8). Pure analysis over the item links
-- already stored in gearCache (self-reported, §6.2) — no comms or protocol change. Officers use
-- it to spot missing enchants / bad or missing gems across the raid before pull.
--
-- WoW item links embed the enchant + gem IDs (item:itemID:enchant:gem1:gem2:gem3:gem4:…); nothing
-- else in the codebase reads past the itemID. Sockets are NOT in the link (only filled gems are),
-- so empty-socket detection reads the item's inherent socket count from GetItemStats — which is
-- the one live-client unknown (verified by /lcex selftest, PROJECT.md X3). If GetItemStats is
-- absent or returns nothing, the socket check simply no-ops: we never false-flag.
--
-- Rules are data-driven from Core/Data/GearRules.lua. The per-item evaluator is headless-tested
-- in Tests/run.lua; the GetItemStats contract has an in-game self-test check.
--
-- Loads after Core/Data/GearRules.lua (rules) and near Core/Usable.lua (a sibling pure analyser).

local LCEX = LootCouncilEX

-- GetItemStats(link) → a stats table; the EMPTY_SOCKET_* keys give the item's inherent sockets.
-- GetItemInfo(gemID) → 3rd return is itemQuality. Both may be nil on first sight of an uncached
-- item; the detector treats a nil result as "no signal" (skip that check) rather than a failure.
local GetItemStats = _G.GetItemStats
local GetItemInfo  = _G.GetItemInfo

-- Split the enchant + gem fields out of an item link or item string.
-- Returns itemID, enchantID (0 = none), gems = { g1, g2, g3, g4 } (0 = empty), or nil for a
-- non-item string. Fields absent from a short link read as 0.
function LCEX:ItemEnchantGems(link)
    if not link then return nil end
    local body = tostring(link):match("item:([%-%d:]+)")
    if not body then return nil end
    local f, n = {}, 0
    for tok in (body .. ":"):gmatch("([%-%d]*):") do
        n = n + 1
        f[n] = tonumber(tok) or 0
        if n >= 6 then break end
    end
    local itemID = f[1]
    if not itemID or itemID == 0 then return nil end
    return itemID, f[2] or 0, { f[3] or 0, f[4] or 0, f[5] or 0, f[6] or 0 }
end

-- The item's inherent socket count (sum of EMPTY_SOCKET_* from GetItemStats). Returns count, ok.
-- ok = false when the API is unavailable / returns nothing → callers skip the empty-socket check
-- rather than guess. NOTE: this counts the item's TOTAL sockets; empty ones = count − filled gems
-- (the caller subtracts). If the live client turns out to report only UNFILLED sockets, flip the
-- caller — the selftest surfaces the raw shape.
function LCEX:ItemSocketCount(link)
    if not GetItemStats or not link then return 0, false end
    local stats = GetItemStats(link)
    if type(stats) ~= "table" then return 0, false end
    local n = 0
    for k, v in pairs(stats) do
        if type(k) == "string" and type(v) == "number" and k:find("EMPTY_SOCKET_", 1, true) then
            n = n + v
        end
    end
    return n, true
end

-- Evaluate one equipped item (its link, in inventory slot `slot`) against GearRules. Returns a
-- list of issue tags { kind, text }; an empty list means "no issues". kinds: "noenchant",
-- "badenchant", "nogem", "badgem".
function LCEX:GearIssuesForItem(link, slot)
    local out = {}
    local itemID, enchant, gems = self:ItemEnchantGems(link)
    if not itemID then return out end
    local R = self.GearRules
    if R.excludeItems[itemID] then return out end -- whitelisted: never flag

    -- Enchant: missing on an enchantable slot, or present-but-suboptimal.
    if enchant == 0 then
        if R.enchantable[slot] then
            out[#out + 1] = { kind = "noenchant", text = self.L["No enchant"] }
        end
    else
        local allow = R.enchantAllow[slot]
        local flag
        if allow then
            flag = not allow[enchant] -- allowlist mode: anything unlisted is suspect (fail-safe)
        else
            flag = R.enchantBad[enchant] == true -- blacklist fallback
        end
        if flag then
            out[#out + 1] = { kind = "badenchant", text = R.enchantLabel[enchant] or self.L["Non-BiS enchant"] }
        end
    end

    -- Sockets: an inherent socket with no gem in it.
    local sockets, ok = self:ItemSocketCount(link)
    if ok and sockets > 0 then
        local filled = 0
        for _, g in ipairs(gems) do if g ~= 0 then filled = filled + 1 end end
        for _ = 1, sockets - filled do
            out[#out + 1] = { kind = "nogem", text = self.L["Empty socket"] }
        end
    end

    -- Gems: a socketed gem below the minimum quality (meta gems are epic, so never caught here).
    if GetItemInfo then
        for _, g in ipairs(gems) do
            if g ~= 0 then
                local q = select(3, GetItemInfo(g))
                if q and q < R.minGemQuality then
                    out[#out + 1] = { kind = "badgem", text = self.L["Low-quality gem"] }
                end
            end
        end
    end

    return out
end

-- All gear issues for a player: their own live-equipped gear (self) or their cached self-report
-- (others). Returns rows = { { slot, link, issues={…} }, … } for slots WITH issues, and the total
-- issue count. Empty gear slots are skipped (an empty slot is not an issue).
function LCEX:GearIssuesForPlayer(name)
    local rows, total = {}, 0
    local items
    if self:IsSelf(name) then
        items = self:SnapshotGear()
    else
        local key = self:NormalizeName(name)
        local cache = self.db and self.db.global and self.db.global.gearCache
        local rec = key and cache and cache[key]
        items = rec and rec.items
    end
    if type(items) ~= "table" then return rows, total end
    for slot = 1, 18 do
        local link = items[slot]
        if link then
            local issues = self:GearIssuesForItem(link, slot)
            if #issues > 0 then
                rows[#rows + 1] = { slot = slot, link = link, issues = issues }
                total = total + #issues
            end
        end
    end
    return rows, total
end
