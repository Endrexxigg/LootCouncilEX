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

-- ── v1.1 gem-colour helpers (Phase 17) ───────────────────────────────────────
-- The SOCKET colours a gem of colour c satisfies (hybrids satisfy both parents), and its PRIMARY
-- contribution to a meta requirement. R/Y/B primaries; O=R+Y, G=Y+B, P=R+B hybrids; M = meta.
local GEM_MATCH = {
    R = { R = true }, Y = { Y = true }, B = { B = true },
    O = { R = true, Y = true }, G = { Y = true, B = true }, P = { R = true, B = true },
}
local GEM_PRIMARY = {
    R = { red = 1 }, Y = { yellow = 1 }, B = { blue = 1 },
    O = { red = 1, yellow = 1 }, G = { yellow = 1, blue = 1 }, P = { red = 1, blue = 1 },
}

-- Can each socket colour be assigned a distinct gem that satisfies it? Sockets ≤ 3, so a plain
-- backtracking search is ample. `sockets` = { "R", "Y", … }; `gemSets` = { {R=true,Y=true}, … }.
local function assignable(sockets, gemSets)
    local used = {}
    local function try(si)
        if si > #sockets then return true end
        local color = sockets[si]
        for gi = 1, #gemSets do
            if not used[gi] and gemSets[gi][color] then
                used[gi] = true
                if try(si + 1) then return true end
                used[gi] = false
            end
        end
        return false
    end
    return try(1)
end

-- Per-colour inherent socket counts (RED/YELLOW/BLUE/META + total) from GetItemStats, or nil when
-- the API gives nothing. Distinct from ItemSocketCount (the sum) — this drives colour matching.
function LCEX:ItemSocketColors(link)
    if not GetItemStats or not link then return nil end
    local stats = GetItemStats(link)
    if type(stats) ~= "table" then return nil end
    local MAP = { EMPTY_SOCKET_RED = "RED", EMPTY_SOCKET_YELLOW = "YELLOW",
                  EMPTY_SOCKET_BLUE = "BLUE", EMPTY_SOCKET_META = "META" }
    local counts, any = { RED = 0, YELLOW = 0, BLUE = 0, META = 0, total = 0 }, false
    for k, v in pairs(stats) do
        local color = MAP[k]
        if color and type(v) == "number" and v > 0 then
            counts[color] = counts[color] + v
            counts.total = counts.total + v
            any = true
        end
    end
    return any and counts or nil
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

    -- Boss-conditional / profession FYI (v1.1): a labeled `useless` tag (e.g. [PvP trinket]). Data
    -- ships minimal; empty itemCondition ⇒ never fires.
    local cond = R.itemCondition and R.itemCondition[itemID]
    if cond then
        out[#out + 1] = { kind = "useless", text = (R.conditionLabel and R.conditionLabel[cond]) or cond }
    end

    -- Enchant: missing on an enchantable slot, or present-but-suboptimal.
    if enchant == 0 then
        if R.enchantable[slot] then
            out[#out + 1] = { kind = "noenchant", text = self.L["No enchant"] }
        end
    else
        local allow = R.enchantAllow[slot]
        local label
        if allow then -- allowlist mode: anything unlisted is suspect (fail-safe)
            if not allow[enchant] then
                label = R.enchantLabel[enchant] or R.enchantBad[enchant] or self.L["Non-BiS enchant"]
            end
        else -- blacklist fallback: enchantBad maps a listed ID → its display label (nil = not listed)
            label = R.enchantBad[enchant]
        end
        if label then
            out[#out + 1] = { kind = "badenchant", text = label }
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

    -- Socket-COLOUR matching (v1.1): flag [socket bonus unmet] ONLY when every coloured (non-meta)
    -- socket is filled, every gem's colour is known, and no assignment satisfies the socket colours.
    -- Fail-open everywhere else (unknown gem, an empty socket — the nogem check owns that, no data).
    local colors = self:ItemSocketColors(link)
    if colors then
        local socketList = {}
        for _ = 1, colors.RED do socketList[#socketList + 1] = "R" end
        for _ = 1, colors.YELLOW do socketList[#socketList + 1] = "Y" end
        for _ = 1, colors.BLUE do socketList[#socketList + 1] = "B" end
        if #socketList > 0 and R.gemColors then
            local gemSets, known = {}, true
            for _, g in ipairs(gems) do
                if g ~= 0 then
                    local c = R.gemColors[g]
                    if c and c ~= "M" and GEM_MATCH[c] then
                        gemSets[#gemSets + 1] = GEM_MATCH[c] -- a coloured socket gem
                    elseif c ~= "M" then
                        known = false; break -- unknown colour (a meta gem is ignored, not "unknown")
                    end
                end
            end
            -- Judge only with a gem for every coloured socket AND all colours known (else fail-open).
            if known and #gemSets >= #socketList and not assignable(socketList, gemSets) then
                out[#out + 1] = { kind = "socketcolor", text = self.L["Socket bonus unmet"] }
            end
        end
    end

    return out
end

-- Whole-set meta-gem activation (v1.1): the equipped META gem's colour requirement checked against
-- the total primary-colour counts across ALL equipped gems (hybrids count for both parents). One
-- tag or nil. Fail-open TWICE: skip if the meta has no known requirement, or ANY equipped gem
-- colour is unknown (we can't be sure the meta is inactive). `items` = slot → link.
function LCEX:GearMetaIssue(items)
    if type(items) ~= "table" then return nil end
    local R = self.GearRules
    if not (R.gemColors and R.metaRequirements) then return nil end
    local meta, counts, unknown = nil, { red = 0, yellow = 0, blue = 0 }, false
    for slot = 1, 18 do
        local _, _, gems = self:ItemEnchantGems(items[slot])
        if gems then
            for _, g in ipairs(gems) do
                if g ~= 0 then
                    local c = R.gemColors[g]
                    if c == "M" then meta = meta or g
                    elseif c and GEM_PRIMARY[c] then
                        for k, num in pairs(GEM_PRIMARY[c]) do counts[k] = counts[k] + num end
                    else unknown = true end
                end
            end
        end
    end
    if not meta then return nil end
    local req = R.metaRequirements[meta]
    if not req or unknown then return nil end -- unknown meta or an unknown gem colour → fail-open
    for color, need in pairs(req) do
        if (counts[color] or 0) < need then
            return { kind = "metagem", text = self.L["Meta gem inactive"] }
        end
    end
    return nil
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
    -- Whole-set meta-gem activation (v1.1) is a per-PLAYER check; it attaches to the head slot
    -- (metas are head-only), computed once here and folded into slot 1's issues below.
    local metaIssue = self:GearMetaIssue(items)
    for slot = 1, 18 do
        local link = items[slot]
        if link then
            local issues = self:GearIssuesForItem(link, slot)
            if slot == 1 and metaIssue then issues[#issues + 1] = metaIssue; metaIssue = nil end
            if #issues > 0 then
                rows[#rows + 1] = { slot = slot, link = link, issues = issues }
                total = total + #issues
            end
        end
    end
    if metaIssue then -- head slot had no item (unusual) — surface the meta issue anyway
        rows[#rows + 1] = { slot = 1, link = items[1], issues = { metaIssue } }
        total = total + 1
    end
    return rows, total
end
