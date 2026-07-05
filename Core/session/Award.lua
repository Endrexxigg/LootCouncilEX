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

-- Hidden tooltip used to scan an item's real "tradeable for the next …" line (DL-9). Lazily
-- created. The pattern is built once from the localized BIND_TRADE_TIME_REMAINING global (the
-- RCLC technique): escape its magic chars, then turn its %s placeholder into a capture group.
local scanTip
local function ScanTooltip()
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "LCEX_ScanTooltip", UIParent, "GameTooltipTemplate")
    end
    return scanTip
end

local tradePattern
local function TradeTimePattern()
    if tradePattern == nil then
        local s = BIND_TRADE_TIME_REMAINING
        if not s then
            tradePattern = false -- string absent (e.g. headless / unexpected client) → no scan
        else
            tradePattern = s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", "(.+)")
        end
    end
    return tradePattern or nil
end

-- "Trade complete" signal. UI_INFO_MESSAGE fires (errorType, message); newer clients pass
-- the LE_GAME_ERR_* enum as the first arg, older ones the localized string — match either.
local ERR_TRADE_COMPLETE = _G.ERR_TRADE_COMPLETE
local LE_TRADE_COMPLETE  = _G.LE_GAME_ERR_TRADE_COMPLETE

-- State:
--   LCEX.pendingLoot  = { { link, itemID, quality, boss, instance, lootedAt, roster } }  (raid log)
--   LCEX.sessionItems = index -> { link, itemID, quality, bag, slot, boss, instance, lootedAt, roster }
--     roster = the { {name,class} } present when the item was looted (V1 kill-set proxy, §6.10)
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
    self:RestoreOwedTrades() -- rehydrate owed items left over from before a /reload (DL-6)
    self:RestoreSession()    -- offer to resume a session that was open before the /reload (DL-6)
end

-- Whether we should passively track our own loot into pendingLoot for councilling. Under DL-7
-- the group need NOT use master loot — in fact the Anniversary/Era client removed master loot
-- entirely (GetLootMethod is nil), which is the whole reason this addon councils from bags + trade.
-- So we can't key off the loot method: track whenever grouped (the council source is our own
-- bags; non-ML members simply never /lcex start, and pendingLoot is local + quality-filtered
-- downstream). The master-loot fast-path is kept only for any older client that still exposes it.
function LCEX:PlayerIsML()
    if GetLootMethod then
        local method, mlPartyID, mlRaidID = GetLootMethod()
        if method == "master" then
            if IsInRaid() then
                return mlRaidID ~= nil and UnitIsUnit("player", "raid" .. mlRaidID)
            end
            return mlPartyID == 0 -- party context: 0 == us
        end
    end
    return IsInGroup()
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

-- Like WithItemQuality but keyed by itemID — for static Loot/BiS lists a council member may not
-- have cached. cb receives GetItemInfo's returns (name, link, quality, ..., icon) once resolved,
-- or cb(nil) for a missing/invalid item. Synchronous when cached, else ContinueOnItemLoad with a
-- 0.5s AceTimer safety net (the same proven shape as WithItemQuality). UI callers paint the icon
-- instantly from GetItemInfoInstant and use this to fill the name + tooltip on resolve.
function LCEX:WithItemID(itemID, cb)
    if not itemID then return cb(nil) end
    local item = Item:CreateFromItemID(itemID)
    if item:IsItemEmpty() then return cb(nil) end
    local function finish() cb(GetItemInfo(itemID)) end
    if item:IsItemDataCached() then return finish() end
    local fired = false
    local function once()
        if fired then return end
        fired = true
        finish()
    end
    item:ContinueOnItemLoad(once)
    self:ScheduleTimer(once, 0.5)
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
    local roster   = self:PresentRoster() -- who's present at loot time (V1 kill-set proxy, §6.10)
    self:WithItemQuality(link, function(quality)
        if not self:IsCouncilable(quality) then return end
        self.pendingLoot[#self.pendingLoot + 1] = {
            link     = link,
            itemID   = tonumber(link:match("item:(%d+)")),
            quality  = quality,
            boss     = boss,
            instance = instance,
            lootedAt = lootedAt,
            roster   = roster,
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
            item.roster   = p.roster
        end
    end
    return list
end

-- Find an item's current { bag, slot } by link (slots move as bags change). With `skipLocked`,
-- skip a slot mid-move (its item is being placed elsewhere); with `avoid` = { ["bag:slot"]=true },
-- skip slots already claimed this pass — so two identical copies resolve to two distinct stacks
-- instead of both grabbing the first (§6.14 duplicate hand-off).
function LCEX:FindItemInBags(link, skipLocked, avoid)
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            if GetContainerItemLink(bag, slot) == link then
                local key = bag .. ":" .. slot
                local locked = false
                if skipLocked then
                    local info = GetContainerItemInfo(bag, slot)
                    if type(info) == "table" then locked = info.isLocked and true or false
                    else locked = select(3, GetContainerItemInfo(bag, slot)) and true or false end
                end
                if not locked and not (avoid and avoid[key]) then
                    return bag, slot
                end
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
            -- No looted-at anchor (in bags before we logged it): read the real window off the
            -- tooltip (DL-9) so a pre-login item shows an actual countdown, not "no timer".
            local rem = it.bag and self:ItemTradeTimeRemaining(it.bag, it.slot)
            if rem and rem > 0 then
                self:Msg(string.format(self.L["  %d. %s (q%d) — ~%s left to trade"],
                    i, it.link, it.quality, self:FormatDuration(rem)))
            else
                self:Msg(string.format(self.L["  %d. %s (q%d) — looted before reload, no trade timer"],
                    i, it.link, it.quality))
            end
        end
    end
end

-- /lcex start — open a session over the councilable bag items.
function LCEX:CmdStartFromBags()
    -- Guard BEFORE touching sessionItems: StartSession would refuse anyway, but by then the
    -- live session's award records would already be clobbered (uid = sid:index reads them).
    if self.session then
        self:Msg(self.L["A session is already active. /lcex end first."])
        return
    end
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
function LCEX:AwardItem(itemIndex, name, forcedResp)
    name = strtrim(name or "")
    local entry = self.sessionItems and self.sessionItems[itemIndex]
    if not entry then
        self:Msg(string.format(self.L["No item #%d in the session."], itemIndex))
        return false
    end
    if name == "" then return false end

    -- The award's reason: an explicit override (a D/E award forces STATUS.DISENCHANT — §6.10),
    -- else the winner's own poll response if they made one, else ANNOUNCED (assigned outside the poll).
    local resp = forcedResp
    if not resp then
        resp = self.STATUS.ANNOUNCED
        if self.session and self.session.rows[itemIndex] then
            local r = self.session.rows[itemIndex][self:NormalizeName(name)]
            if r and r.resp then resp = r.resp end
        end
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
        -- looted-at anchor when we have it; else the real remaining window off the tooltip (DL-9).
        expireAt = entry.lootedAt and (entry.lootedAt + TRADE_WINDOW)
                   or self:MeasuredExpiryForLink(entry.link),
        warned   = false,
    }
    self:EnsureTradeTicker()
    self:SaveOwedTrades() -- persist the new debt immediately (DL-6)

    -- Strictly-increasing per-uid ts so a re-award after a same-second retraction still wins (§6.15).
    local ts = self:NextHistoryTs(uid)
    local channel = self:GroupChannel()
    if channel then
        self:Send("award", self.session and self.session.sid or nil, {
            item      = entry.link,
            itemID    = entry.itemID,
            itemIndex = itemIndex, -- so receivers can build the history uid (sid:itemIndex)
            winner    = name,
            resp      = resp,
            boss      = entry.boss,
            instance  = entry.instance,
            ts        = ts,
        }, channel)
    end
    -- Log to persistent history locally. Every present client logs from the `award` broadcast;
    -- the ML logs here directly (same ts) so it doesn't depend on its own group echo — the
    -- union history dataset then propagates to council who were absent (council/History.lua).
    self:LogAward(uid, {
        winner = name, itemID = entry.itemID, itemLink = entry.link, ts = ts,
        resp = resp, boss = entry.boss, instance = entry.instance, by = UnitName("player"),
    })
    self:Msg(string.format(
        self.L["Recorded: %s → %s. Trade it to them within the window to hand it off."],
        entry.link, name))
    self:AnnounceAward(entry.link, name, resp) -- RCLC-like "<item> awarded to <player> for <reason>"

    -- Track award progress on the live view (the loot window's rail badges). Receivers learn
    -- the same fact from the `award` broadcast (council/History.lua).
    local a = self.activeSession
    if a and self.session and a.sid == self.session.sid then
        a.awarded = a.awarded or {}
        a.awarded[itemIndex] = name
        -- Recompute + rebroadcast the GROUP's readiness (§6.14): the border flips to "awarded"
        -- only when the last copy lands, and partial-award progress reaches every client.
        local leader = (self.session.groups and self.session.groups.leaderOf[itemIndex]) or itemIndex
        self:ApplyCUpdate(self.session.sid, leader, self.session.rows[leader], self:ComputeItemStatus(leader))
        self:BroadcastCUpdate(leader)
        self:RefreshLootItem(itemIndex)
    end
    return true
end

-- The next unawarded physical copy of a group (§6.14): its leader first, then members in order;
-- nil when every copy is awarded. Reads activeSession.awarded (client-safe) with GroupMembers.
function LCEX:NextAwardableIndex(leader)
    local a = self.activeSession
    for _, m in ipairs(self:GroupMembers(leader)) do
        if not (a and a.awarded and a.awarded[m] ~= nil) then return m end
    end
    return nil
end

-- Award `name` the next available copy of a group (§6.14). The UI awards through this so a
-- duplicate stack hands out distinct physical indices (uid = sid:physIdx) across copies.
function LCEX:AwardGroup(leader, name, forcedResp)
    local idx = self:NextAwardableIndex(leader)
    if not idx then
        self:Msg(self.L["Every copy of that item is already awarded."])
        return false
    end
    return self:AwardItem(idx, name, forcedResp)
end

-- A history timestamp for `uid` strictly greater than any record already stored under it, so a
-- same-second correction (award → un-award → re-award) still supersedes under LWW (§6.15 — the
-- DL-20 second-granularity guard). The ML computes the authoritative ts and BROADCASTS it, so
-- every client converges on the same value; a first award (no prior record) just gets `time()`.
function LCEX:NextHistoryTs(uid)
    local cur = self.db and self.db.global.history and self.db.global.history[uid]
    local now = time()
    if cur and (cur.mod or 0) >= now then return (cur.mod or 0) + 1 end
    return now
end

-- Is there still an owed (untraded) record for this uid? Drives the un-award confirm wording:
-- present → pre-trade ("return to the session"); absent → already delivered (record-only fix).
function LCEX:HasOwedTrade(uid)
    for _, list in pairs(self.pendingTrades) do
        for _, r in ipairs(list) do
            if r.uid == uid then return true end
        end
    end
    return false
end

-- Un-award a physical copy (§6.15, ML-only): drop the owed trade (no-op if already delivered),
-- clear the awarded mirror, append a RETRACTED history record (fresh mod so LWW supersedes the
-- award), broadcast `unaward`, and recompute the group's readiness. Post-trade this only corrects
-- the record — the in-game item is NOT reversed (the caller's confirm says so). Returns true.
function LCEX:UnawardItem(physIdx)
    local s, a = self.session, self.activeSession
    if not (s and a and a.awarded and a.awarded[physIdx]) then return false end
    local winner = a.awarded[physIdx]
    local entry = self.sessionItems and self.sessionItems[physIdx]
    local uid = s.sid .. ":" .. physIdx

    self:ForgetAward(uid)      -- drop the owed trade if it's still pending
    a.awarded[physIdx] = nil
    self:StopTradeTickerIfIdle()

    -- Strictly-increasing per-uid ts so the retraction supersedes the award even in the same second.
    local ts = self:NextHistoryTs(uid)
    self:LogAward(uid, {
        winner = winner, itemID = entry and entry.itemID, itemLink = entry and entry.link,
        ts = ts, mod = ts, by = UnitName("player"),
        retracted = true, retractedBy = UnitName("player"),
    })
    local channel = self:GroupChannel()
    if channel then
        self:Send("unaward", s.sid, {
            item = entry and entry.link, itemID = entry and entry.itemID,
            itemIndex = physIdx, winner = winner, ts = ts,
        }, channel)
    end

    -- The group's border may leave "awarded" — recompute + rebroadcast (§6.14).
    local leader = (s.groups and s.groups.leaderOf[physIdx]) or physIdx
    self:ApplyCUpdate(s.sid, leader, s.rows[leader], self:ComputeItemStatus(leader))
    self:BroadcastCUpdate(leader)

    local text = string.format(self.L["Award of %s to %s was undone."],
        (entry and entry.link) or "?", winner)
    local ch = self:GroupChannel()
    if self:GetConfig().announceAwards and ch then SendChatMessage(text, ch) else self:Msg(text) end
    self:RefreshLootItem(physIdx)
    return true
end

-- Human-readable award reason for a resp code (§6.10): D/E for a disenchant, the poll response text
-- for a real response, or nil when the ML assigned it outside the poll (ANNOUNCED) — then the
-- announcement drops the "for <reason>" clause.
function LCEX:AwardReasonText(resp)
    if resp == self.STATUS.DISENCHANT then return self.L["D/E"] end
    for _, r in ipairs(self.RESPONSES) do
        if r.id == resp then return r.text end
    end
    return nil
end

-- Announce an award RCLC-style. To group chat when `config.announceAwards` is on and we are in a
-- group (default on — the whole raid sees who won what and why); otherwise just to our own chat
-- frame. ML-only path: receivers learn the award from the `award` comm, so only the ML announces.
function LCEX:AnnounceAward(link, name, resp)
    local reason = self:AwardReasonText(resp)
    local text = reason
        and string.format(self.L["%s was awarded to %s for %s."], link, name, reason)
        or  string.format(self.L["%s was awarded to %s."], link, name)
    local channel = self:GroupChannel()
    if self:GetConfig().announceAwards and channel then
        SendChatMessage(text, channel)
    else
        self:Msg(text)
    end
end

-- The highest-ranked configured disenchanter currently present in the raid (V5/Vd7).
-- config.disenchanters is ranked top = highest priority, so the first present entry wins. nil when
-- none is set or present — the D/E flow then falls back to a manual target pick. "Eligible to
-- receive" for a shard is simply being present (class usability is irrelevant — it's being sharded).
function LCEX:ResolveDisenchanter()
    for _, name in ipairs(self:GetConfig().disenchanters or {}) do
        if self:InGroupWith(name) then return name end
    end
    return nil
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

-- How many of `link` are currently sitting in the player's six trade slots. (Slot 7 is the
-- will-not-be-traded slot and is never used for hand-offs.) Counts duplicates, so owing a winner
-- two identical copies fills two slots, not one (§6.14).
function LCEX:TradeItemCount(link)
    local n = 0
    for i = 1, 6 do
        if GetTradePlayerItemLink(i) == link then n = n + 1 end
    end
    return n
end

-- Load every item owed to the current trade partner into the window. Owed records are grouped by
-- link and placed COUNTED — for k copies of one link already showing `present` copies, place the
-- k − present remaining, each from a distinct bag slot (§6.14: two identical items no longer
-- collapse onto one trade slot). UseContainerItem can silently no-op while a just-looted item is
-- still bag-locked, so anything that doesn't take retries a beat later, then falls back to a
-- manual-drag prompt. Stops if the trade window closes.
function LCEX:FillOwedTrades(attempt)
    local list = self.tradePartnerKey and self.pendingTrades[self.tradePartnerKey]
    if not list or #list == 0 then return end
    if not (TradeFrame and TradeFrame:IsShown()) then return end

    local byLink = {}
    for _, rec in ipairs(list) do
        byLink[rec.link] = byLink[rec.link] or {}
        table.insert(byLink[rec.link], rec)
    end

    local stuck, used = {}, {}
    for link, recs in pairs(byLink) do
        local present = self:TradeItemCount(link)
        for i, rec in ipairs(recs) do
            if i <= present then
                -- Already in a trade slot (from a prior pass or a manual drag) — just announce once.
                if not rec.filled then
                    rec.filled = true
                    self:Msg(string.format(self.L["Auto-filled %s into the trade with %s."],
                        rec.link, rec.winner))
                end
            else
                if CursorHasItem() then ClearCursor() end
                local bag, slot = self:FindItemInBags(link, true, used)
                local before = self:TradeItemCount(link)
                if bag then
                    UseContainerItem(bag, slot)
                    if CursorHasItem() then ClearCursor() end -- never strand the cursor
                end
                if bag and self:TradeItemCount(link) > before then
                    used[bag .. ":" .. slot] = true
                    present = self:TradeItemCount(link)
                    rec.filled = true
                    self:Msg(string.format(self.L["Auto-filled %s into the trade with %s."],
                        rec.link, rec.winner))
                else
                    stuck[#stuck + 1] = rec
                end
            end
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
                self:SaveOwedTrades() -- a delivered/re-awarded item clears from the DB too
                return
            end
        end
    end
end

-- ── Real trade-timer (tooltip scan; DL-9) ────────────────────────────────────
-- Parse a localized trade-time string ("1 hr 59 min", "45 min", "30 sec") to seconds. enUS-
-- leaning: sums every <number><unit> pair by the unit's first letter (h/m/s). Pure/testable.
function LCEX:ParseTradeDuration(text)
    if not text then return nil end
    local total, found = 0, false
    for num, unit in text:gmatch("(%d+)%s*(%a+)") do
        local u = unit:sub(1, 1):lower()
        if u == "h" then total, found = total + tonumber(num) * 3600, true
        elseif u == "m" then total, found = total + tonumber(num) * 60, true
        elseif u == "s" then total, found = total + tonumber(num), true end
    end
    return found and total or nil
end

-- Compact "1h 5m" / "12m" rendering of a seconds duration (for the scan list). Pure/testable.
function LCEX:FormatDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

-- Seconds left in a bag item's BoP trade window by scanning its tooltip for the
-- BIND_TRADE_TIME_REMAINING line. Returns a number, or nil when the API/string is unavailable,
-- the item shows no such line (already untradeable / never BoP), or the scan fails — callers
-- treat nil as "no timer" (the prior behavior), so this only ever ADDS a countdown.
function LCEX:ItemTradeTimeRemaining(bag, slot)
    local pattern = TradeTimePattern()
    if not pattern then return nil end
    local tip = ScanTooltip()
    tip:SetOwner(UIParent, "ANCHOR_NONE")
    tip:SetBagItem(bag, slot)
    local n = tip:NumLines()
    if type(n) ~= "number" or n == 0 then tip:Hide(); return nil end
    for i = 1, n do
        local fs = _G[tip:GetName() .. "TextLeft" .. i]
        local text = fs and fs.GetText and fs:GetText()
        local cap = text and text:match(pattern)
        if cap then
            tip:Hide()
            return self:ParseTradeDuration(cap)
        end
    end
    tip:Hide()
    return nil
end

-- Resolve an owed item's absolute expiry: the looted-at anchor (lootedAt + 2h) when we have it,
-- else a measured remaining window (now + remaining), else nil (no timer). Pure/testable.
function LCEX:TradeExpiry(lootedAt, remaining, now)
    if lootedAt then return lootedAt + TRADE_WINDOW end
    if remaining and remaining > 0 and remaining ~= math.huge then return (now or time()) + remaining end
    return nil
end

-- Best expiry for an owed link not anchored by lootedAt: locate it in bags and scan its tooltip.
-- Container-API-guarded so it's a no-op (nil) on a client/headless run without the bag API.
function LCEX:MeasuredExpiryForLink(link)
    if not GetContainerNumSlots then return nil end
    local bag, slot = self:FindItemInBags(link)
    if not bag then return nil end
    return self:TradeExpiry(nil, self:ItemTradeTimeRemaining(bag, slot), time())
end

-- ── Owed-trade persistence (survive /reload; DL-6 part 1) ─────────────────────
-- self.pendingTrades is the live working copy; it also mirrors into the account-wide DB under
-- the OWNER character's key so a /reload or crash never loses the "who do I still owe" ledger.
-- Keyed by owner so an account's alts keep separate ledgers. The transient `filled` flag
-- (per-trade-window UI state) is intentionally NOT persisted.
local OWED_FIELDS = { "uid", "link", "itemID", "winner", "boss", "instance",
                      "lootedAt", "expireAt", "warned" }

function LCEX:OwnerKey()
    return self:NormalizeName(UnitName("player"))
end

-- Mirror the live pendingTrades into db.global.pendingTrades[owner] (durable fields only).
function LCEX:SaveOwedTrades()
    local owner = self:OwnerKey()
    if not owner or not self.db then return end
    local out = {}
    for shortKey, list in pairs(self.pendingTrades) do
        local copy = {}
        for _, rec in ipairs(list) do
            local r = {}
            for _, f in ipairs(OWED_FIELDS) do r[f] = rec[f] end
            copy[#copy + 1] = r
        end
        if #copy > 0 then out[shortKey] = copy end
    end
    self.db.global.pendingTrades[owner] = next(out) and out or nil
end

-- Rebuild pendingTrades from the DB on login. Drops records whose 2h window already lapsed
-- (no point auto-filling a now-untradeable item); keeps no-timer debts. Resumes the ticker if
-- anything survives, and writes the pruned set back.
function LCEX:RestoreOwedTrades()
    local owner = self:OwnerKey()
    local saved = owner and self.db and self.db.global.pendingTrades[owner]
    if not saved then return end
    local now = time()
    local restored = {}
    for shortKey, list in pairs(saved) do
        local keep = {}
        for _, rec in ipairs(list) do
            if not (rec.expireAt and rec.expireAt <= now) then
                -- A debt with no anchor (awarded from a pre-login bag item) can get a real
                -- countdown now that the item is in bags again (DL-9).
                if not rec.expireAt then rec.expireAt = self:MeasuredExpiryForLink(rec.link) end
                keep[#keep + 1] = rec
            end
        end
        if #keep > 0 then restored[shortKey] = keep end
    end
    self.pendingTrades = restored
    if next(self.pendingTrades) then self:EnsureTradeTicker() end
    self:SaveOwedTrades()
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
    self:SaveOwedTrades() -- persist expirations/warn-flag updates
    self:StopTradeTickerIfIdle()
end

-- ── Test mode ─────────────────────────────────────────────────────────────────
-- Real TBC item links for padding when the player's bags lack enough councilable items.
local TEST_ITEM_IDS = { 32837, 30055, 28830, 29918, 29381, 28040 }

-- /lcex test [n] — start a session from sample items (default 3) so the whole
-- broadcast → award → trade-assist → timer path can be exercised without a live drop.
-- Prefers real bag items (so trade auto-fill works); pads with sample item IDs.
function LCEX:CmdTest(rest)
    -- Same guard as CmdStartFromBags: never clobber a live session's award records.
    if self.session then
        self:Msg(self.L["A session is already active. /lcex end first."])
        return
    end
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
