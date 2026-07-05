-- ── LootCouncil EX — Core/TradeTimers.lua ────────────────────────────────────
-- Gargul-style loot trade timers (Phase 12, §6.17, DL-22) — the DATA layer. Scans the player's
-- bags for items with a running BoP trade window and keeps a live entry list the timer window
-- (UI/TradeTimerWindow.lua) renders. Rebuilt native from Gargul's UX; no LibCandyBar, no copied
-- code. The remaining-time source is the DL-9 tooltip scanner (Award.lua ItemTradeTimeRemaining).
--
-- Shows ALL tradeable loot (not just owed trades) — the winner name is annotated onto entries
-- that ARE owed, from the pendingTrades ledger. The pure helpers (_TradeKeyFor / _Reconcile /
-- _AnnotateTradeWinners / TradeBarColor) are headless-tested; the bag scan + events aren't.
--
-- Loads after Core/session/Award.lua (ItemTradeTimeRemaining + pendingTrades live there).

local LCEX = LootCouncilEX

-- Container APIs under C_Container on Anniversary, with the old-global fallback (as in Award.lua).
local Container = C_Container or {}
local GetContainerNumSlots = Container.GetContainerNumSlots or _G.GetContainerNumSlots
local GetContainerItemLink = Container.GetContainerItemLink or _G.GetContainerItemLink

local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

local TRADE_WINDOW = 7200 -- the 2h BoP window (mirrors Award.lua)

-- ── Pure helpers (headless-tested) ───────────────────────────────────────────
-- Bar color by fraction remaining (§6.17): green ≥60%, gold ≥30%, red below — Gargul's buckets.
function LCEX:TradeBarColor(remaining, total)
    total = (total and total > 0) and total or TRADE_WINDOW
    local frac = remaining and (remaining / total) or 0
    if frac >= 0.6 then return self.Theme.success end
    if frac >= 0.3 then return self.Theme.accent end
    return self.Theme.danger
end

-- A stable-ish key for a tradeable bag item: the item GUID when available (exact), else a
-- bucketed-expiry key + a collision ordinal (the tooltip's remaining time is minute-granular, so
-- bucket to 120s). Pure.
function LCEX:_TradeKeyFor(itemID, expireAt, guid, ordinal)
    if guid and guid ~= "" then return "g:" .. tostring(guid) end
    local bucket = math.floor((expireAt or 0) / 120)
    return string.format("i:%s:%d:%d", tostring(itemID), bucket, ordinal or 0)
end

-- Reconcile a fresh scan against the previous entry list so keys stay stable across rescans
-- despite the tooltip's minute-granular expiry drift: a scanned item matches a prior entry by GUID
-- (exact) else by itemID + |Δexpire| ≤ 180s, and inherits that entry's key (so the UI's row
-- identity + hidden-set survive). Pure; returns the scanned list with reconciled keys.
function LCEX:_ReconcileTradeEntries(prev, scanned)
    local used = {}
    for _, sc in ipairs(scanned or {}) do
        local match
        for pi, pe in ipairs(prev or {}) do
            if not used[pi] then
                local byGuid = sc.guid and pe.guid and sc.guid == pe.guid
                local byItem = (not (sc.guid and pe.guid)) and sc.itemID == pe.itemID
                    and math.abs((sc.expireAt or 0) - (pe.expireAt or 0)) <= 180
                if byGuid or byItem then match = pi; break end
            end
        end
        if match then
            used[match] = true
            sc.key = prev[match].key
        end
    end
    return scanned
end

-- Annotate entries with the winner they're owed to (§6.17): group owed records (pendingTrades) by
-- link, sort both sides by expiry, and greedily pair — each tradeable copy shows "→ Winner" where
-- one is owed, unowed loot stays blank. Pure given the ledger; sets/clears entry.winner.
function LCEX:_AnnotateTradeWinners(entries, pendingTrades)
    local owedByLink = {}
    for _, list in pairs(pendingTrades or {}) do
        for _, rec in ipairs(list) do
            owedByLink[rec.link] = owedByLink[rec.link] or {}
            table.insert(owedByLink[rec.link], rec)
        end
    end
    for _, recs in pairs(owedByLink) do
        table.sort(recs, function(a, b) return (a.expireAt or 0) < (b.expireAt or 0) end)
    end
    local byLink = {}
    for _, e in ipairs(entries or {}) do
        e.winner = nil
        byLink[e.link] = byLink[e.link] or {}
        table.insert(byLink[e.link], e)
    end
    for link, es in pairs(byLink) do
        table.sort(es, function(a, b) return (a.expireAt or 0) < (b.expireAt or 0) end)
        local owed = owedByLink[link]
        if owed then
            for i, e in ipairs(es) do
                if owed[i] then e.winner = owed[i].winner end
            end
        end
    end
    return entries
end

-- ── Bag scan (event side) ────────────────────────────────────────────────────
-- The item GUID for a bag slot, pcall-guarded (§6.17 X-item: availability on Anniversary is
-- probed by the selftest). nil when the API/location is unavailable → the bucketed-key fallback.
function LCEX:_TradeItemGUID(bag, slot)
    if not (C_Item and C_Item.GetItemGUID and _G.ItemLocation) then return nil end
    local ok, guid = pcall(function()
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if not loc then return nil end
        if C_Item.DoesItemExist and not C_Item.DoesItemExist(loc) then return nil end
        return C_Item.GetItemGUID(loc)
    end)
    return (ok and guid) or nil
end

-- Every bag item with a running BoP trade window, as fresh entries (keys provisional — reconciled
-- against the prior list by RescanTradeTimers).
function LCEX:ScanTradeTimers()
    local entries, ordinals = {}, {}
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots and GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
            local remaining = link and self:ItemTradeTimeRemaining(bag, slot)
            if link and remaining and remaining > 0 then
                local itemID = tonumber(link:match("item:(%d+)"))
                local expireAt = time() + remaining
                local guid = self:_TradeItemGUID(bag, slot)
                local okey = tostring(itemID) .. ":" .. math.floor(expireAt / 120)
                local ord = ordinals[okey] or 0
                ordinals[okey] = ord + 1
                entries[#entries + 1] = {
                    key      = self:_TradeKeyFor(itemID, expireAt, guid, ord),
                    link     = link,
                    itemID   = itemID,
                    icon     = GetItemInfoInstant and select(5, GetItemInfoInstant(link)) or nil,
                    bag      = bag, slot = slot,
                    expireAt = expireAt,
                    guid     = guid,
                }
            end
        end
    end
    return entries
end

-- The event-driven verb: rescan, reconcile keys against the live list, annotate winners, and push
-- to the window (guarded until UI/TradeTimerWindow.lua lands). Also keeps a 60s safety rescan
-- alive while any tradeable item exists (an item can cross a threshold with no bag event).
function LCEX:RescanTradeTimers()
    local scanned = self:ScanTradeTimers()
    self.tradeTimerEntries = self:_ReconcileTradeEntries(self.tradeTimerEntries or {}, scanned)
    self:_AnnotateTradeWinners(self.tradeTimerEntries, self.pendingTrades)

    if #self.tradeTimerEntries > 0 then
        if not self._tradeSafetyTimer then
            self._tradeSafetyTimer = self:ScheduleRepeatingTimer("RescanTradeTimers", 60)
        end
    elseif self._tradeSafetyTimer then
        self:CancelTimer(self._tradeSafetyTimer)
        self._tradeSafetyTimer = nil
    end

    if self.UpdateTradeTimerWindow then self:UpdateTradeTimerWindow() end
end

-- ── Events ────────────────────────────────────────────────────────────────────
function LCEX:SetupTradeTimers()
    self.tradeTimerEntries = self.tradeTimerEntries or {}
    self:RegisterEvent("BAG_UPDATE_DELAYED", "OnBagUpdateTradeTimers")
end

-- Bag churn → a 1s-debounced rescan (coalesce a burst of updates into one scan).
function LCEX:OnBagUpdateTradeTimers()
    if self._tradeRescanTimer then self:CancelTimer(self._tradeRescanTimer) end
    self._tradeRescanTimer = self:ScheduleTimer("RescanTradeTimers", 1)
end
