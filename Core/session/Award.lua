-- ── LootCouncil EX — session/Award.lua ───────────────────────────────────────
-- Plane A, ML side: scan an open loot window for councilable items, resolve a winning
-- candidate, and assign the item via GiveMasterLoot — then broadcast the `award` so
-- (in a later phase) every present client can log history. Phase 2 is headless: the
-- flow is driven by /lcex test commands and chat output.
--
-- Loads after Session.lua (uses LCEX.session / LCEX:Send / LCEX:GroupChannel).
--
-- API notes (verified against warcraft.wiki.gg for the Classic/BCC client):
--   • Quality is read from GetItemInfo(link) (3rd return, stable across versions) rather
--     than GetLootSlotInfo, whose quality position shifted when currencyID was added.
--   • Loot slots do not renumber while a window stays open, but an awarded slot empties;
--     so award is content-addressed — we re-check the stored link before giving.
--   • Master-loot candidate indices are not stable across roster changes — we always
--     re-enumerate at award time.

local LCEX = LootCouncilEX

-- LCEX.lootScan is nil when no window is open (or we are not ML), else
-- { items = { { link, slot, quality, itemID } }, boss, instance }. itemID is kept here
-- (not in the trimmed sStart wire form) for the award payload.

-- Register the loot events. Called from Init's OnEnable so the DB (minQuality) is ready.
function LCEX:SetupLootEvents()
    self:RegisterEvent("LOOT_OPENED", "OnLootOpened")
    self:RegisterEvent("LOOT_CLOSED", "OnLootClosed")
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

-- On loot open, if we are the ML, scan for items at or above the configured quality
-- threshold and cache them. Only announces when something councilable dropped, to avoid
-- chat spam on trash.
function LCEX:OnLootOpened()
    if not self:PlayerIsML() then
        return
    end

    local minQ = self.db.profile.minQuality or 4
    local items = {}
    for slot = 1, GetNumLootItems() do
        if LootSlotHasItem(slot) then
            local link = GetLootSlotLink(slot)
            if link then
                local _, _, quality = GetItemInfo(link)
                if quality and quality >= minQ then
                    items[#items + 1] = {
                        link = link,
                        slot = slot,
                        quality = quality,
                        itemID = tonumber(link:match("item:(%d+)")),
                    }
                end
            end
        end
    end

    self.lootScan = { items = items, boss = UnitName("target"), instance = GetInstanceInfo() }
    if #items > 0 then
        self:ReportScan()
    end
end

function LCEX:OnLootClosed()
    self.lootScan = nil
end

-- Print the cached scan (shared by the auto-announce and /lcex scan).
function LCEX:ReportScan()
    local items = self.lootScan.items
    self:Msg(string.format(self.L["Detected %d councilable item(s):"], #items))
    for i, it in ipairs(items) do
        self:Msg(string.format(self.L["  %d. %s (slot %d, q%d)"], i, it.link, it.slot, it.quality))
    end
end

-- /lcex scan — show what is currently councilable on the open corpse.
function LCEX:CmdScan()
    if not self.lootScan then
        self:Msg(self.L["No loot window open (or you are not the master looter)."])
        return
    end
    if #self.lootScan.items == 0 then
        self:Msg(self.L["No councilable items on this corpse."])
        return
    end
    self:ReportScan()
end

-- /lcex start — open a session from the current scan. Sends the trimmed wire form
-- ({link,slot,quality}); the full scan (with itemID) is retained for award lookups.
function LCEX:CmdStartFromScan()
    if not self.lootScan or #self.lootScan.items == 0 then
        self:Msg(self.L["Nothing scanned — open a corpse as master looter first."])
        return
    end
    local wire = {}
    for i, it in ipairs(self.lootScan.items) do
        wire[i] = { link = it.link, slot = it.slot, quality = it.quality }
    end
    self:StartSession(wire)
end

-- Find the master-loot candidate index for `name` on a given slot. Returns the index and
-- the canonical name, or nil. Re-enumerates live (indices are not stable).
function LCEX:ResolveCandidate(slot, name)
    name = strtrim(name or ""):lower()
    if name == "" then
        return nil
    end
    for i = 1, 40 do
        local cand = GetMasterLootCandidate(slot, i)
        if not cand then
            break
        end
        if cand:match("^[^-]+"):lower() == name then
            return i, cand
        end
    end
    return nil
end

-- /lcex award <itemIndex> <name> — assign a scanned item to a candidate and broadcast it.
function LCEX:CmdAward(rest)
    local indexStr, name = strtrim(rest or ""):match("^(%S+)%s+(.+)$")
    local itemIndex = tonumber(indexStr)
    if not itemIndex or not name then
        self:Msg(self.L["Usage: /lcex award <itemIndex> <name>"])
        return
    end
    if not self.lootScan then
        self:Msg(self.L["No loot window open (or you are not the master looter)."])
        return
    end
    local entry = self.lootScan.items[itemIndex]
    if not entry then
        self:Msg(string.format(self.L["No item #%d in the scan."], itemIndex))
        return
    end
    if GetNumLootItems() == 0 then
        self:Msg(self.L["Loot window is closed."])
        return
    end

    -- Content-addressed re-validation: confirm the slot still holds the scanned item.
    local liveLink = LootSlotHasItem(entry.slot) and GetLootSlotLink(entry.slot) or nil
    if liveLink ~= entry.link then
        self:Msg(string.format(self.L["Item #%d is no longer in slot %d."], itemIndex, entry.slot))
        return
    end

    local idx, canon = self:ResolveCandidate(entry.slot, name)
    if not idx then
        self:Msg(string.format(self.L["%s is not an eligible candidate for that item."], name))
        return
    end

    GiveMasterLoot(entry.slot, idx)

    local channel = self:GroupChannel()
    if self.session and channel then
        self:Send("award", self.session.sid, {
            item     = entry.link,
            itemID   = entry.itemID,
            winner   = canon,
            resp     = self.STATUS.ANNOUNCED, -- no vote in Phase 2: "announced" sentinel
            boss     = self.lootScan.boss,
            instance = self.lootScan.instance,
            ts       = time(),
        }, channel)
    end
    self:Msg(string.format(self.L["Awarded %s to %s."], entry.link, canon))
end
