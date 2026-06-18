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

local LCEX = LootCouncilEX

-- Container/bag/trade APIs moved to the C_Container namespace; on the Anniversary client
-- the old globals are nil. Prefer the namespace, fall back to the global so we work on any
-- client. GetContainerItemInfo's return SHAPE differs (a table under C_Container, a flat
-- multi-return as the old global) — SlotInfo below normalises that.
local Container = C_Container or {}
local GetContainerNumSlots = Container.GetContainerNumSlots or _G.GetContainerNumSlots
local GetContainerItemLink = Container.GetContainerItemLink or _G.GetContainerItemLink
local GetContainerItemInfo = Container.GetContainerItemInfo or _G.GetContainerItemInfo
local UseContainerItem     = Container.UseContainerItem     or _G.UseContainerItem

-- Localized "You receive loot: " prefix, derived from the client's own global string so
-- it tracks the locale (falls back to enUS). CHAT_MSG_LOOT for our own item loot.
local SELF_LOOT_PREFIX = (LOOT_ITEM_SELF and LOOT_ITEM_SELF:match("^(.-)%%s")) or "You receive loot: "

local TRADE_WINDOW = 7200 -- BoP trade window, seconds (2 hours)
local WARN_AT = 900       -- warn when <= 15 min left

-- "Trade complete" signal. UI_INFO_MESSAGE fires (errorType, message); newer clients pass
-- the LE_GAME_ERR_* enum as the first arg, older ones the localized string — match either.
local ERR_TRADE_COMPLETE = _G.ERR_TRADE_COMPLETE
local LE_TRADE_COMPLETE  = _G.LE_GAME_ERR_TRADE_COMPLETE

-- State:
--   LCEX.pendingLoot  = { { link, itemID, quality, boss, instance, lootedAt } }  (raid log)
--   LCEX.sessionItems = index -> { link, itemID, quality, bag, slot, boss, instance, lootedAt }
--   LCEX.pendingTrades = shortKey -> { {uid, link, itemID, winner, boss, instance, lootedAt,
--                        expireAt, warned}, ... }  (owed items — a LIST, so one winner can be
--                        owed several items at once)
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
    self:RegisterEvent("TRADE_ACCEPT_UPDATE", "OnTradeAcceptUpdate")
    self:RegisterEvent("UI_INFO_MESSAGE", "OnUiInfoMessage")
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

-- True if an item of this quality meets the council threshold.
function LCEX:IsCouncilable(quality)
    return quality ~= nil and quality >= (self.db.profile.minQuality or 4)
end

-- Resolve `link`'s quality, loading it from the server when the client hasn't cached the
-- item yet — GetItemInfo returns nil on the FIRST sight of an item (e.g. a fresh boss drop),
-- which previously made such items silently un-councilable. cb(quality|nil) runs exactly
-- once: synchronously if cached, on load otherwise, or cb(nil) after a short timeout so an
-- item whose data never arrives can't wedge the caller. (Pattern: Gargul Utils/Items.lua
-- onItemLoadDo; ContinueOnItemLoad is NOT guaranteed to fire.)
function LCEX:WithItemQuality(link, cb)
    if not link then return cb(nil) end
    local item = Item:CreateFromItemLink(link)
    if item:IsItemEmpty() then return cb(nil) end
    if item:IsItemDataCached() then
        return cb(select(3, GetItemInfo(link)))
    end
    local fired = false
    local function finish()
        if fired then return end
        fired = true
        cb(select(3, GetItemInfo(link)))
    end
    item:ContinueOnItemLoad(finish)
    self:ScheduleTimer(finish, 0.5)
end

-- ── Passive detection: track what the ML loots ───────────────────────────────
function LCEX:OnChatMsgLoot(_, text)
    if not self:PlayerIsML() then return end
    if not text or text:sub(1, #SELF_LOOT_PREFIX) ~= SELF_LOOT_PREFIX then return end
    local link = text:match("(|c%x+|Hitem:.-|h|r)")
    if not link then return end
    -- Capture the source context NOW — target/zone/time are only correct at loot time. The
    -- item may be uncached on a fresh kill, so resolve quality asynchronously and only track
    -- it once we know it clears the threshold.
    local boss     = UnitName("target")
    local instance = GetInstanceInfo()
    local lootedAt = time()
    self:WithItemQuality(link, function(quality)
        if not self:IsCouncilable(quality) then return end
        self.pendingLoot[#self.pendingLoot + 1] = {
            link     = link,
            itemID   = tonumber(link:match("item:(%d+)")),
            quality  = quality,
            boss     = boss,
            instance = instance,
            lootedAt = lootedAt,
        }
        self:Msg(string.format(self.L["Tracking %s for council (from %s)."], link, boss or "?"))
    end)
end

-- ── Bag scan + reconcile ──────────────────────────────────────────────────────
-- Quality + link for a bag slot, read from the container API — which knows an item's
-- quality even when GetItemInfo hasn't cached it yet (so a just-looted item isn't dropped
-- from a scan). Normalises both return shapes: a table under C_Container (Anniversary), a
-- flat multi-return as the old global.
local function SlotInfo(bag, slot)
    local info = GetContainerItemInfo(bag, slot)
    if type(info) == "table" then
        return info.quality, info.hyperlink
    end
    local _, _, _, quality, _, _, link = GetContainerItemInfo(bag, slot)
    return quality, link
end

-- Every councilable item currently in bags 0-4, with its live { bag, slot }.
function LCEX:ScanBags()
    local found = {}
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local quality, link = SlotInfo(bag, slot)
            if link and self:IsCouncilable(quality) then
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
-- Record `name` as the winner of session item #itemIndex: set up the pending trade (so
-- opening a trade with them auto-loads the item), broadcast `award`, and arm the 2h ticker.
-- Shared by the /lcex award command and the VotingFrame's Award button. Returns true on
-- success. The award carries the winner's own response where we have it (else ANNOUNCED).
function LCEX:AwardItem(itemIndex, name)
    name = strtrim(name or "")
    local entry = self.sessionItems and self.sessionItems[itemIndex]
    if not entry then
        self:Msg(string.format(self.L["No item #%d in the session."], itemIndex))
        return false
    end
    if name == "" then return false end

    -- Carry the winner's response into the award/history record if they responded.
    local resp = self.STATUS.ANNOUNCED
    if self.session and self.session.rows[itemIndex] then
        local r = self.session.rows[itemIndex][self:NormalizeName(name)]
        if r and r.resp then resp = r.resp end
    end

    -- Owed items are keyed per-partner as a LIST (a winner can be owed several), each tagged
    -- with a uid (§6.3 history uid). Re-awarding this same item first drops any prior record
    -- of it — even from a different winner — so it never auto-fills to the wrong person.
    local uid = (self.session and self.session.sid or "nosession") .. ":" .. itemIndex
    self:ForgetAward(uid)
    local key  = ShortKey(name)
    local list = self.pendingTrades[key]
    if not list then
        list = {}
        self.pendingTrades[key] = list
    end
    list[#list + 1] = {
        uid      = uid,
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
            resp     = resp,
            boss     = entry.boss,
            instance = entry.instance,
            ts       = time(),
        }, channel)
    end
    self:Msg(string.format(
        self.L["Recorded: %s → %s. Trade it to them within the window to hand it off."],
        entry.link, name))
    return true
end

-- /lcex award <itemIndex> <name> — parse the args and hand off to AwardItem.
function LCEX:CmdAward(rest)
    local indexStr, name = strtrim(rest or ""):match("^(%S+)%s+(.+)$")
    local itemIndex = tonumber(indexStr)
    if not itemIndex or not name then
        self:Msg(self.L["Usage: /lcex award <itemIndex> <name>"])
        return
    end
    self:AwardItem(itemIndex, name)
end

-- Is `link` already sitting in one of the player's six trade slots? (Slot 7 is the
-- will-not-be-traded slot and is never used for hand-offs.)
function LCEX:TradeHasItem(link)
    for i = 1, 6 do
        if GetTradePlayerItemLink(i) == link then
            return true
        end
    end
    return false
end

-- Try ONCE to drop a single owed item into the open trade window. UseContainerItem places a
-- bag item into the first free trade slot — but ONLY while a trade is open; with no trade it
-- would equip/consume the item, hence the IsShown guard. Returns true once the item shows in
-- a trade slot. No user message: FillOwedTrades decides when to report success/failure.
function LCEX:PlaceItemInTrade(rec)
    if self:TradeHasItem(rec.link) then return true end
    if not (TradeFrame and TradeFrame:IsShown()) then return false end
    if CursorHasItem() then ClearCursor() end
    local bag, slot = self:FindItemInBags(rec.link)
    if not bag then return false end
    UseContainerItem(bag, slot)
    if CursorHasItem() then ClearCursor() end -- never strand the cursor on a failed add
    return self:TradeHasItem(rec.link)
end

-- Load every item owed to the current trade partner into the window. UseContainerItem can
-- silently no-op while a just-looted item is still bag-locked, so retry a few times a beat
-- apart before falling back to a manual-drag prompt. Stops if the trade window closes.
function LCEX:FillOwedTrades(attempt)
    local list = self.tradePartnerKey and self.pendingTrades[self.tradePartnerKey]
    if not list or #list == 0 then return end
    if not (TradeFrame and TradeFrame:IsShown()) then return end

    local stuck = {}
    for _, rec in ipairs(list) do
        if self:PlaceItemInTrade(rec) then
            if not rec.filled then
                rec.filled = true
                self:Msg(string.format(self.L["Auto-filled %s into the trade with %s."],
                    rec.link, rec.winner))
            end
        else
            stuck[#stuck + 1] = rec
        end
    end

    if #stuck > 0 then
        if attempt < 3 then
            self:ScheduleTimer(function() self:FillOwedTrades(attempt + 1) end, 0.5)
        else
            for _, rec in ipairs(stuck) do
                self:Msg(string.format(
                    self.L["Could not auto-fill %s — drag it into the trade window yourself."],
                    rec.link))
            end
        end
    end
end

function LCEX:OnTradeShow()
    self.tradePartnerKey = ShortKey(TradePartner())
    -- Fresh window: clear stale "announced" flags so a re-opened trade re-announces fills.
    local list = self.tradePartnerKey and self.pendingTrades[self.tradePartnerKey]
    if list then
        for _, rec in ipairs(list) do rec.filled = nil end
    end
    self:FillOwedTrades(0)
end

-- Snapshot what WE are offering whenever the trade contents settle, so completion can tell
-- exactly which owed items left our bags. (A bag diff can't distinguish a hand-off from
-- banking/mailing the item, and TRADE_CLOSED can't distinguish completion from cancel.)
function LCEX:OnTradeAcceptUpdate()
    local given = {}
    for i = 1, 6 do
        local link = GetTradePlayerItemLink(i)
        if link then
            given[#given + 1] = link
        end
    end
    self.tradeGiven = given
end

function LCEX:OnUiInfoMessage(_, arg1, arg2)
    local complete = (LE_TRADE_COMPLETE and arg1 == LE_TRADE_COMPLETE)
        or arg1 == ERR_TRADE_COMPLETE or arg2 == ERR_TRADE_COMPLETE
    if complete then
        self:OnTradeCompleted()
    end
end

-- An owed record matching `link`, preferring one owed to `preferKey`. Returns rec, ownerKey.
function LCEX:FindOwedByLink(link, preferKey)
    local rec, ownerKey
    for key, list in pairs(self.pendingTrades) do
        for _, r in ipairs(list) do
            if r.link == link then
                if key == preferKey then return r, key end
                rec, ownerKey = rec or r, ownerKey or key
            end
        end
    end
    return rec, ownerKey
end

-- A trade actually completed: clear the owed records for the items we handed over (from the
-- accept-time snapshot), and warn if one went to someone other than its recorded winner. We
-- match against the partner key captured at TRADE_SHOW (reliable) — UnitName("npc") can read
-- nil mid-completion, which would otherwise spuriously trip the wrong-winner warning.
function LCEX:OnTradeCompleted()
    local key = self.tradePartnerKey
    for _, link in ipairs(self.tradeGiven or {}) do
        local rec, owner = self:FindOwedByLink(link, key)
        if rec then
            if owner ~= key then
                self:Msg(string.format(self.L["Note: %s was awarded to %s but traded to %s."],
                    rec.link, rec.winner, TradePartner() or key or "?"))
            end
            self:ForgetAward(rec.uid)
        end
    end
    self.tradeGiven = nil
    self:StopTradeTickerIfIdle()
end

-- TRADE_CLOSED only clears transient state — delivery is reconciled on ERR_TRADE_COMPLETE
-- (a cancelled trade must keep the owed records intact for the next attempt).
function LCEX:OnTradeClosed()
    self.tradePartnerKey = nil
    self.tradeGiven = nil
end

-- Drop the owed record with this uid from wherever it lives (re-award or delivery). Prunes
-- the partner's list to nil when it empties, so StopTradeTickerIfIdle/next() see no owner.
function LCEX:ForgetAward(uid)
    for key, list in pairs(self.pendingTrades) do
        for i = #list, 1, -1 do
            if list[i].uid == uid then
                table.remove(list, i)
                if #list == 0 then self.pendingTrades[key] = nil end
                return
            end
        end
    end
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
    for key, list in pairs(self.pendingTrades) do
        for i = #list, 1, -1 do
            local e = list[i]
            if e.expireAt then
                local left = e.expireAt - now
                if left <= 0 then
                    self:Msg(string.format(self.L["Trade window for %s (%s) has expired."], e.winner, e.link))
                    table.remove(list, i)
                elseif left <= WARN_AT and not e.warned then
                    e.warned = true
                    self:Msg(string.format(self.L["You have %d minute(s) left to trade %s to %s."],
                        math.ceil(left / 60), e.link, e.winner))
                end
            end
        end
        if #list == 0 then self.pendingTrades[key] = nil end
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
