-- ── LootCouncil EX — session/Award.lua ───────────────────────────────────────
-- Plane A, ML side: the bags + trade loot flow (see memory: the ML auto-loots every
-- drop into their own bags during the raid, councils them later, and hands items off by
-- TRADING the winner within the BoP 2-hour window — NOT master-loot-from-corpse).
--
-- Detection is two-pronged:
--   • Passive: CHAT_MSG_LOOT captures what the ML loots (with the source boss + a
--     looted-at timestamp the 2h trade window needs) into `pendingLoot`.
--   • Bag scan: at session/award time we scan bags 0-4 for councilable items and
--     reconcile them against `pendingLoot` (the only live source of bag/slot location).
--
-- Award = "assist the trade": record the winner, broadcast `award`, and when the ML
-- opens a trade with that winner, auto-load the item into the trade window (best-effort,
-- with a manual-drag fallback). A ticking timer warns before the 2h window lapses.
--
-- Loads after Session.lua (uses LCEX.session / LCEX:Send / LCEX:GroupChannel / Msg).
--
-- Bag/trade APIs are the GLOBAL forms (C_Container is Dragonflight+, absent here).

local LCEX = LootCouncilEX

-- Container/bag APIs moved to the C_Container namespace; on the Anniversary client the
-- old globals are nil. Prefer the namespace, fall back to the global so we work on any
-- client. (We only use these three; their return shapes match between the two forms.)
local Container = C_Container or {}
local GetContainerNumSlots = Container.GetContainerNumSlots or _G.GetContainerNumSlots
local GetContainerItemLink = Container.GetContainerItemLink or _G.GetContainerItemLink
local PickupContainerItem  = Container.PickupContainerItem  or _G.PickupContainerItem

-- Localized "You receive loot: " prefix, derived from the client's own global string so
-- it tracks the locale (falls back to enUS). CHAT_MSG_LOOT for our own item loot.
local SELF_LOOT_PREFIX = (LOOT_ITEM_SELF and LOOT_ITEM_SELF:match("^(.-)%%s")) or "You receive loot: "

local TRADE_WINDOW = 7200 -- BoP trade window, seconds (2 hours)
local WARN_AT = 900       -- warn when <= 15 min left

-- State:
--   LCEX.pendingLoot  = { { link, itemID, quality, boss, instance, lootedAt } }  (raid log)
--   LCEX.sessionItems = index -> { link, itemID, quality, bag, slot, boss, instance, lootedAt }
--   LCEX.pendingTrades = shortKey -> { link, itemID, winner, boss, instance, lootedAt, expireAt, warned }
LCEX.pendingLoot   = LCEX.pendingLoot or {}
LCEX.pendingTrades = LCEX.pendingTrades or {}

-- Short, case-folded character name (drop any realm suffix) for matching trade partners.
local function ShortKey(name)
    if not name or name == "" then return nil end
    return name:match("^[^%-]+"):lower()
end

-- The name of the player we currently have a trade window open with.
local function TradePartner()
    local n = UnitName("npc")
    if n and n ~= "" then return n end
    local frame = _G.TradeFrameRecipientNameText
    return frame and frame:GetText() or nil
end

-- ── Event wiring ─────────────────────────────────────────────────────────────
function LCEX:SetupLootEvents()
    self:RegisterEvent("CHAT_MSG_LOOT", "OnChatMsgLoot")
    self:RegisterEvent("TRADE_SHOW", "OnTradeShow")
    self:RegisterEvent("TRADE_CLOSED", "OnTradeClosed")
end

-- True only when the player themselves is the master looter (PROJECT.md §3 authority).
function LCEX:PlayerIsML()
    local method, mlPartyID, mlRaidID = GetLootMethod()
    if method ~= "master" then
        return false
    end
    if IsInRaid() then
        return mlRaidID ~= nil and UnitIsUnit("player", "raid" .. mlRaidID)
    end
    return mlPartyID == 0 -- party context: 0 == us
end

-- Quality of `link` if it meets the council threshold, else nil.
function LCEX:CouncilableQuality(link)
    if not link then return nil end
    local _, _, quality = GetItemInfo(link)
    if quality and quality >= (self.db.profile.minQuality or 4) then
        return quality
    end
    return nil
end

-- ── Passive detection: track what the ML loots ───────────────────────────────
function LCEX:OnChatMsgLoot(_, text)
    if not self:PlayerIsML() then return end
    if not text or text:sub(1, #SELF_LOOT_PREFIX) ~= SELF_LOOT_PREFIX then return end
    local link = text:match("(|c%x+|Hitem:.-|h|r)")
    local quality = self:CouncilableQuality(link)
    if not quality then return end
    local boss = UnitName("target")
    self.pendingLoot[#self.pendingLoot + 1] = {
        link     = link,
        itemID   = tonumber(link:match("item:(%d+)")),
        quality  = quality,
        boss     = boss,
        instance = GetInstanceInfo(),
        lootedAt = time(),
    }
    self:Msg(string.format(self.L["Tracking %s for council (from %s)."], link, boss or "?"))
end

-- ── Bag scan + reconcile ──────────────────────────────────────────────────────
-- Every councilable item currently in bags 0-4, with its live { bag, slot }.
function LCEX:ScanBags()
    local found = {}
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            local quality = self:CouncilableQuality(link)
            if quality then
                found[#found + 1] = {
                    link    = link,
                    itemID  = tonumber(link:match("item:(%d+)")),
                    quality = quality,
                    bag     = bag,
                    slot    = slot,
                }
            end
        end
    end
    return found
end

-- The councilable list = bag items, enriched with boss/looted-at from the passive log
-- where we have it. Items looted before the addon loaded carry no trade-timer context.
function LCEX:BuildCouncilableList()
    local byLink = {}
    for _, p in ipairs(self.pendingLoot) do
        byLink[p.link] = byLink[p.link] or {}
        table.insert(byLink[p.link], p)
    end
    local list = self:ScanBags()
    for _, item in ipairs(list) do
        local matches = byLink[item.link]
        local p = matches and table.remove(matches)
        if p then
            item.boss     = p.boss
            item.instance = p.instance
            item.lootedAt = p.lootedAt
        end
    end
    return list
end

-- Find an item's current { bag, slot } by link (slots move as bags change).
function LCEX:FindItemInBags(link)
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if GetContainerItemLink(bag, slot) == link then
                return bag, slot
            end
        end
    end
    return nil
end

-- /lcex scan — list what is councilable in the ML's bags right now.
function LCEX:CmdScan()
    local list = self:BuildCouncilableList()
    if #list == 0 then
        self:Msg(self.L["Nothing councilable in your bags."])
        return
    end
    self:Msg(self.L["Councilable items in your bags:"])
    for i, it in ipairs(list) do
        if it.lootedAt then
            self:Msg(string.format(self.L["  %d. %s (q%d)"], i, it.link, it.quality))
        else
            self:Msg(string.format(self.L["  %d. %s (q%d) — looted before reload, no trade timer"],
                i, it.link, it.quality))
        end
    end
end

-- /lcex start — open a session over the councilable bag items.
function LCEX:CmdStartFromBags()
    local list = self:BuildCouncilableList()
    if #list == 0 then
        self:Msg(self.L["Nothing councilable in your bags."])
        return
    end
    self.sessionItems = list
    local wire = {}
    for i, it in ipairs(list) do
        wire[i] = { link = it.link, quality = it.quality }
    end
    self:StartSession(wire)
end

-- ── Award + assist-trade ──────────────────────────────────────────────────────
-- /lcex award <itemIndex> <name> — record the winner, broadcast `award`, and set up the
-- pending trade so opening a trade with them auto-loads the item.
function LCEX:CmdAward(rest)
    local indexStr, name = strtrim(rest or ""):match("^(%S+)%s+(.+)$")
    local itemIndex = tonumber(indexStr)
    if not itemIndex or not name then
        self:Msg(self.L["Usage: /lcex award <itemIndex> <name>"])
        return
    end
    name = strtrim(name)
    local entry = self.sessionItems and self.sessionItems[itemIndex]
    if not entry then
        self:Msg(string.format(self.L["No item #%d in the session."], itemIndex))
        return
    end

    self.pendingTrades[ShortKey(name)] = {
        link     = entry.link,
        itemID   = entry.itemID,
        winner   = name,
        boss     = entry.boss,
        instance = entry.instance,
        lootedAt = entry.lootedAt,
        expireAt = entry.lootedAt and (entry.lootedAt + TRADE_WINDOW) or nil,
        warned   = false,
    }
    self:EnsureTradeTicker()

    local channel = self:GroupChannel()
    if channel then
        self:Send("award", self.session and self.session.sid or nil, {
            item     = entry.link,
            itemID   = entry.itemID,
            winner   = name,
            resp     = self.STATUS.ANNOUNCED, -- no vote yet (Phase 3); "announced" sentinel
            boss     = entry.boss,
            instance = entry.instance,
            ts       = time(),
        }, channel)
    end
    self:Msg(string.format(
        self.L["Recorded: %s → %s. Trade it to them within the window to hand it off."],
        entry.link, name))
end

-- First empty player trade slot (1-6); slot 7 is the will-not-be-traded slot.
function LCEX:FirstFreeTradeSlot()
    for i = 1, 6 do
        if not GetTradePlayerItemLink(i) then
            return i
        end
    end
    return nil
end

-- Best-effort: place the won item into the open trade window. Any failure degrades to a
-- "drag it yourself" prompt and never strands the cursor.
function LCEX:TryFillTrade(entry)
    local function bail()
        if CursorHasItem() then ClearCursor() end
        self:Msg(string.format(
            self.L["Could not auto-fill %s — drag it into the trade window yourself."], entry.link))
    end

    if CursorHasItem() then return bail() end
    local bag, slot = self:FindItemInBags(entry.link)
    if not bag then return bail() end
    -- Re-validate the slot still holds the exact item before picking it up.
    if GetContainerItemLink(bag, slot) ~= entry.link then return bail() end
    local freeSlot = self:FirstFreeTradeSlot()
    if not freeSlot then return bail() end

    PickupContainerItem(bag, slot)
    ClickTradeButton(freeSlot)
    if GetTradePlayerItemLink(freeSlot) then
        self:Msg(string.format(self.L["Auto-filled %s into the trade with %s."], entry.link, entry.winner))
    else
        bail()
    end
end

function LCEX:OnTradeShow()
    local partner = TradePartner()
    self.tradePartnerKey = ShortKey(partner)
    local entry = self.tradePartnerKey and self.pendingTrades[self.tradePartnerKey]
    if entry then
        self:TryFillTrade(entry)
    end
end

-- A completed trade removes the item from bags; clear that pending award. Re-check after
-- a short delay so bag state has settled (a cancelled trade keeps the entry).
function LCEX:OnTradeClosed()
    local key = self.tradePartnerKey
    self.tradePartnerKey = nil
    if not key then return end
    self:ScheduleTimer(function()
        local entry = self.pendingTrades[key]
        if entry and not self:FindItemInBags(entry.link) then
            self.pendingTrades[key] = nil
            self:StopTradeTickerIfIdle()
        end
    end, 1)
end

-- ── 2-hour trade-window timer ─────────────────────────────────────────────────
function LCEX:EnsureTradeTicker()
    if not self.tradeTicker then
        self.tradeTicker = self:ScheduleRepeatingTimer("CheckTradeTimers", 60)
    end
end

function LCEX:StopTradeTickerIfIdle()
    if not next(self.pendingTrades) and self.tradeTicker then
        self:CancelTimer(self.tradeTicker)
        self.tradeTicker = nil
    end
end

function LCEX:CheckTradeTimers()
    local now = time()
    for key, e in pairs(self.pendingTrades) do
        if e.expireAt then
            local left = e.expireAt - now
            if left <= 0 then
                self:Msg(string.format(self.L["Trade window for %s (%s) has expired."], e.winner, e.link))
                self.pendingTrades[key] = nil
            elseif left <= WARN_AT and not e.warned then
                e.warned = true
                self:Msg(string.format(self.L["You have %d minute(s) left to trade %s to %s."],
                    math.ceil(left / 60), e.link, e.winner))
            end
        end
    end
    self:StopTradeTickerIfIdle()
end

-- ── Test mode ─────────────────────────────────────────────────────────────────
-- Real TBC item links for padding when the player's bags lack enough councilable items.
local TEST_ITEM_IDS = { 32837, 30055, 28830, 29918, 29381, 28040 }

-- /lcex test [n] — start a session from sample items (default 3) so the whole
-- broadcast → award → trade-assist → timer path can be exercised without a live drop.
-- Prefers real bag items (so trade auto-fill works); pads with sample item IDs.
function LCEX:CmdTest(rest)
    local n = math.max(1, math.min(6, tonumber(strtrim(rest or "")) or 3))
    local instance = GetInstanceInfo()
    local list = {}

    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if #list >= n then break end
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, q = GetItemInfo(link)
                list[#list + 1] = {
                    link = link, itemID = tonumber(link:match("item:(%d+)")),
                    quality = q or 1, bag = bag, slot = slot,
                    boss = "Test Boss", instance = instance, lootedAt = time(),
                }
            end
        end
        if #list >= n then break end
    end

    local idx = 1
    while #list < n and idx <= #TEST_ITEM_IDS do
        local id = TEST_ITEM_IDS[idx]
        idx = idx + 1
        local _, link, q = GetItemInfo(id)
        list[#list + 1] = {
            link = link or ("item:" .. id), itemID = id, quality = q or 4,
            boss = "Test Boss", instance = instance, lootedAt = time(),
        }
    end

    self.sessionItems = list
    local wire = {}
    for i, it in ipairs(list) do
        wire[i] = { link = it.link, quality = it.quality }
    end
    self:Msg(string.format(self.L["Test session: broadcasting %d sample item(s)."], #wire))
    self:StartSession(wire)
end
