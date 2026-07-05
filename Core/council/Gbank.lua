-- ── LootCouncil EX — council/Gbank.lua ───────────────────────────────────────
-- Feature B guild bank (PROJECT.md §6.12). A Plane-B scanner + cache + append-only ledger, all
-- guild-scoped (Feature C §6.11) and replicated over the sync engine. Three datasets:
--   • gbankCache (lww)   — per-tab {name,icon,slots} + a "money" record {gold}; latest scan wins.
--   • gbankLog (union)   — one immutable record per transaction, keyed by a content-hash uid so the
--                          same transaction seen by two officers dedups. Elapsed→absolute is
--                          hour-granular (an API limitation, §6.12) — the uid buckets by hour.
--   • gbankNotes (lww)   — council annotations attached to a transaction GROUP (Phase-11 commit 3).
--
-- The pure logic (uid synthesis, elapsed→absolute, dedup ingest, 5-min grouping) is headless-tested;
-- the live scanner reads the net-new guild-bank APIs, verified BCC-tagged on warcraft.wiki.gg + by
-- the /lcex selftest API contract (X3). GetGuildBankMoneyTransaction CRASHES on an out-of-range
-- index, so its loop is strictly bounded by GetNumGuildBankMoneyTransactions().
--
-- Loads after Sync.lua (RegisterDataset/MergeRecord/SetRecord/SyncHello).

local LCEX = LootCouncilEX

LCEX:RegisterDataset("gbankCache", "lww",   function() return LCEX.db.global.gbankCache end)
LCEX:RegisterDataset("gbankLog",   "union", function() return LCEX.db.global.gbankLog end)
LCEX:RegisterDataset("gbankNotes", "lww",   function() return LCEX.db.global.gbankNotes end)

local HOUR         = 3600
local GROUP_WINDOW = 300  -- consecutive same-player+action entries within 5 min group for display
local MONEY_KEY    = "money"
local UID_SEP      = "\30" -- record-separator: safe inside item links (which contain |, :, etc.)

-- ── Pure ledger logic (headless-tested) ──────────────────────────────────────

-- Normalize the API's transaction-type strings for grouping/dedup: money logs report "withdrawal",
-- item logs "withdraw" — collapse to "withdraw" so a player's item + gold withdrawal in the same
-- window group together. Result set: deposit / withdraw / move / repair.
function LCEX:GbankNormalizeKind(kind)
    if kind == "withdrawal" then return "withdraw" end
    return kind or "?"
end

-- An absolute HOUR INDEX (unix hours) for a transaction: the capture time (floored to the hour, so
-- two officers scanning within the same clock hour derive the SAME index) minus the API's elapsed
-- years/months/days/hours. This is the basis of the content-hash uid, so dedup is hour-granular.
function LCEX:GbankTxnHour(capturedAt, years, months, days, hours)
    local capturedHour = math.floor((capturedAt or 0) / HOUR)
    local elapsed = (years or 0) * 365 * 24 + (months or 0) * 30 * 24 + (days or 0) * 24 + (hours or 0)
    return capturedHour - elapsed
end

-- Content-hash uid: identical (action, player, item, count, tabs, hour) transactions collapse to one
-- key, so the union gbankLog dedups them across officers' scans (§6.12's accepted hour-granularity).
function LCEX:GbankTxnUid(kind, player, itemKey, count, tabs, hourIndex)
    return table.concat({ self:GbankNormalizeKind(kind), player or "?", itemKey or "-",
        count or 0, tabs or "-", hourIndex or 0 }, UID_SEP)
end

-- Ingest a list of raw transactions into the union ledger (dedup by uid; no broadcast — replication
-- rides the digest sync). Each txn: { kind, player, itemLink|gold, count, tabs, years,months,days,
-- hours }. `capturedAt` anchors the elapsed→absolute conversion. Returns how many were new.
function LCEX:IngestTxnList(txns, capturedAt)
    local added = 0
    for _, tx in ipairs(txns or {}) do
        if tx.kind and tx.player then
            local hour = self:GbankTxnHour(capturedAt, tx.years, tx.months, tx.days, tx.hours)
            local isMoney = tx.gold ~= nil
            local itemKey = isMoney and MONEY_KEY or (tx.itemLink or "-")
            local amount  = isMoney and tx.gold or tx.count
            local uid = self:GbankTxnUid(tx.kind, tx.player, itemKey, amount, tx.tabs, hour)
            local rec = { kind = self:GbankNormalizeKind(tx.kind), player = tx.player,
                          tabs = tx.tabs, ts = hour * HOUR, by = tx.by or UnitName("player") }
            if isMoney then rec.gold = tx.gold else rec.itemLink = tx.itemLink; rec.count = tx.count end
            if self:MergeRecord("gbankLog", uid, rec) then added = added + 1 end
        end
    end
    return added
end

-- Group consecutive newest-first entries by the same player + normalized action within GROUP_WINDOW
-- (B4): identical items sum to xN; money adds to the group's gold. The group's uid = its lead
-- entry's uid (stable for annotations). `entries` come from GbankLogEntries (sorted newest-first).
function LCEX:BuildGbankGroups(entries)
    local groups, cur = {}, nil
    for _, e in ipairs(entries or {}) do
        local kind = self:GbankNormalizeKind(e.kind)
        local same = cur and cur.player == e.player and cur.kind == kind
            and math.abs((cur.anchorTs or 0) - (e.ts or 0)) <= GROUP_WINDOW
        if not same then
            cur = { player = e.player, kind = kind, ts = e.ts, anchorTs = e.ts, uid = e.uid,
                    items = {}, gold = 0, _byLink = {} }
            groups[#groups + 1] = cur
        end
        if e.gold and e.gold > 0 then
            cur.gold = cur.gold + e.gold
        elseif e.itemLink then
            local slot = cur._byLink[e.itemLink]
            if slot then
                slot.count = slot.count + (e.count or 1)
            else
                slot = { link = e.itemLink, count = e.count or 1 }
                cur._byLink[e.itemLink] = slot
                cur.items[#cur.items + 1] = slot
            end
        end
    end
    for _, g in ipairs(groups) do g._byLink = nil end
    return groups
end

-- ── Accessors for the UI (read the cache/ledger; nil-safe) ───────────────────
function LCEX:GbankGold()
    local m = self.db.global.gbankCache and self.db.global.gbankCache[MONEY_KEY]
    return m and m.gold, m and m.mod
end

-- Cached tabs sorted by index: { {index, name, icon, slots={slot→{link,count}}, mod, by}, … }.
function LCEX:GbankTabs()
    local out = {}
    for k, rec in pairs(self.db.global.gbankCache or {}) do
        if k ~= MONEY_KEY and type(rec) == "table" then out[#out + 1] = rec end
    end
    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out
end

-- Ledger entries (a shallow copy each carrying its uid) sorted newest-first.
function LCEX:GbankLogEntries()
    local out = {}
    for uid, rec in pairs(self.db.global.gbankLog or {}) do
        local e = {}
        for k, v in pairs(rec) do e[k] = v end
        e.uid = uid
        out[#out + 1] = e
    end
    table.sort(out, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return out
end

-- ── Live scanner (B6) ────────────────────────────────────────────────────────
local SLOTS_PER_TAB = _G.MAX_GUILDBANK_SLOTS_PER_TAB or 98

-- Cancel-and-reschedule debounce for the bursty *_CHANGED / *_UPDATE events (they can fire many
-- times as the server streams data — coalesce into one cache/ingest pass).
local function gbankDebounce(self, key, delay, fn)
    self._gbankTimers = self._gbankTimers or {}
    if self._gbankTimers[key] then self:CancelTimer(self._gbankTimers[key]) end
    self._gbankTimers[key] = self:ScheduleTimer(fn, delay)
end

function LCEX:SetupGbank()
    self:RegisterEvent("GUILDBANKFRAME_OPENED", "OnGuildBankOpened")
    self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", "OnGuildBankSlots")
    self:RegisterEvent("GUILDBANKLOG_UPDATE", "OnGuildBankLog")
end

-- The guild bank opened (B6): snapshot the moment for elapsed→absolute, cache gold, and request each
-- viewable tab's items + logs — throttled one query per tick, answered asynchronously by the
-- *_CHANGED / *_UPDATE events. The money log lives at tab MAX_GUILDBANK_TABS+1.
function LCEX:OnGuildBankOpened()
    if not GetNumGuildBankTabs then return end
    self._gbankCapturedAt = time()
    if GetGuildBankMoney then
        self:SetRecord("gbankCache", MONEY_KEY, { gold = GetGuildBankMoney() or 0 })
    end
    local tabs = GetNumGuildBankTabs() or 0
    local moneyTab = (_G.MAX_GUILDBANK_TABS or 8) + 1
    local tick = 0
    for tab = 1, tabs do
        tick = tick + 1
        self:ScheduleTimer(function()
            if QueryGuildBankTab then QueryGuildBankTab(tab) end
            if QueryGuildBankLog then QueryGuildBankLog(tab) end
        end, 0.35 * tick)
    end
    self:ScheduleTimer(function()
        if QueryGuildBankLog then QueryGuildBankLog(moneyTab) end
    end, 0.35 * (tick + 1))
end

-- Tab slot data arrived (the event doesn't say which tab). Re-cache ALL viewable tabs — reads are by
-- explicit (tab, slot) so the server's cached data is addressable without switching the shown tab.
function LCEX:CacheAllTabs()
    -- All-or-nothing existence guard: after it, call the APIs DIRECTLY. A `fn and fn(x)` guard would
    -- truncate their multi-return to one value (the classic `and` trap — isViewable/count → nil).
    if not (GetNumGuildBankTabs and GetGuildBankTabInfo and GetGuildBankItemLink
            and GetGuildBankItemInfo) then return end
    for tab = 1, (GetNumGuildBankTabs() or 0) do
        local name, icon, isViewable = GetGuildBankTabInfo(tab)
        if isViewable then
            local slots = {}
            for slot = 1, SLOTS_PER_TAB do
                local link = GetGuildBankItemLink(tab, slot)
                if link then
                    local _, count = GetGuildBankItemInfo(tab, slot)
                    slots[slot] = { link = link, count = count or 1 }
                end
            end
            self:SetRecord("gbankCache", tab, { index = tab, name = name, icon = icon, slots = slots })
        end
    end
end

function LCEX:OnGuildBankSlots()
    gbankDebounce(self, "cache", 0.4, function() self:CacheAllTabs() end)
end

-- Read every tab's item log + the money log into a raw txn list and ingest it (dedup by uid). Money
-- transactions are bounded strictly by GetNumGuildBankMoneyTransactions() — the API crashes the
-- client on an out-of-range index. On new entries, re-advertise our digest so behind council pull.
function LCEX:IngestAllLogs()
    if not (GetNumGuildBankTabs and GetNumGuildBankTransactions and GetGuildBankTransaction) then return end
    local txns = {}
    for tab = 1, (GetNumGuildBankTabs and GetNumGuildBankTabs() or 0) do
        for i = 1, (GetNumGuildBankTransactions(tab) or 0) do
            local kind, player, itemLink, count, tab1, tab2, y, mo, d, h = GetGuildBankTransaction(tab, i)
            if kind and player then
                txns[#txns + 1] = { kind = kind, player = player, itemLink = itemLink, count = count,
                    tabs = tostring(tab1 or "") .. ">" .. tostring(tab2 or ""),
                    years = y, months = mo, days = d, hours = h }
            end
        end
    end
    if GetNumGuildBankMoneyTransactions and GetGuildBankMoneyTransaction then
        for i = 1, (GetNumGuildBankMoneyTransactions() or 0) do -- strict bound: out-of-range CRASHES
            local kind, player, amount, y, mo, d, h = GetGuildBankMoneyTransaction(i)
            if kind and player then
                txns[#txns + 1] = { kind = kind, player = player, gold = amount, tabs = "",
                    years = y, months = mo, days = d, hours = h }
            end
        end
    end
    if self:IngestTxnList(txns, self._gbankCapturedAt or time()) > 0 then
        self:SyncHello() -- advertise the new digest so behind council pull the delta (B1)
    end
end

function LCEX:OnGuildBankLog()
    gbankDebounce(self, "log", 0.5, function() self:IngestAllLogs() end)
end
