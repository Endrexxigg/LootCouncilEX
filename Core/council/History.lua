-- ── LootCouncil EX — council/History.lua ─────────────────────────────────────
-- Plane B: the award-history dataset. LWW by `mod` per uid (§6.3, DL-20) — awards are the norm,
-- but the ML can CORRECT one: an un-award appends a `retracted=true` record with a fresher `mod`,
-- a re-award appends the new winner with a fresher one still. Nothing is ever deleted; the latest
-- fact wins. Every client PRESENT for an award/un-award writes the same record locally from the
-- broadcast (§6.1); the LWW sync (Sync.lua) carries it to absent council. uid = "<sid>:<itemIndex>".
--
-- Write paths, one record builder:
--   • The ML logs directly in AwardItem / UnawardItem via LCEX:LogAward (doesn't rely on its echo).
--   • Everyone else logs in the inbound `award` / `unaward` handlers below.
-- All go through MergeRecord; a replayed award (equal mod + by) is idempotent.
--
-- Loads after Sync.lua (RegisterDataset/MergeRecord) and Comms.lua (dispatch table).

local LCEX = LootCouncilEX
LCEX.dispatch = LCEX.dispatch or {}

-- Register at load (store closure is invoked lazily, after the DB exists — same as `dummy`).
LCEX:RegisterDataset("history", "lww", function() return LCEX.db.global.history end)

-- The §6.3 history record. `mod` drives LWW (defaults to `ts`, the award time — a correction
-- passes a fresh `mod` so it supersedes without disturbing the displayed award time). `retracted`
-- marks an un-awarded record (kept, not deleted).
function LCEX:BuildHistoryRecord(f)
    return {
        player      = f.winner,
        itemID      = f.itemID,
        itemLink    = f.itemLink,
        ts          = f.ts or time(),
        resp        = f.resp,
        respText    = f.respText, -- DL-8: resolved reason text so it renders after a set change
        boss        = f.boss,
        instance    = f.instance,
        by          = f.by,
        mod         = f.mod or f.ts or time(),
        retracted   = f.retracted or nil,
        retractedBy = f.retractedBy or nil,
    }
end

-- Log one award into the persistent history locally (no broadcast). Idempotent per uid.
function LCEX:LogAward(uid, fields)
    local changed = self:MergeRecord("history", uid, self:BuildHistoryRecord(fields))
    if changed then
        self:Debug("history += %s (%s -> %s)", tostring(uid),
            tostring(fields.itemLink), tostring(fields.winner))
    end
    return changed
end

-- ── Inbound: log awards we witness from other MLs ───────────────────────────
-- Group-gated (NOT council-gated): §6.1 says every present client builds a complete local
-- record. A non-council witness can log but cannot push it out (pHello/pSync are council-only);
-- union only ever grows by key, so the same award merges idempotently.
LCEX.dispatch.award = function(self, msg, sender)
    if self:IsSelf(sender) then return end          -- the ML logged this via LogAward already
    if not self:InGroupWith(sender) then return end
    if msg.itemIndex == nil then return end          -- need it for the uid
    local uid = (msg.sid or "nosession") .. ":" .. tostring(msg.itemIndex)
    self:LogAward(uid, {
        winner = msg.winner, itemID = msg.itemID, itemLink = msg.item,
        ts = msg.ts, resp = msg.resp, respText = msg.respText,
        boss = msg.boss, instance = msg.instance, by = sender,
    })
    -- Mirror award progress into the live session view (loot-window rail badges).
    local a = self.activeSession
    if a and msg.sid == a.sid and type(msg.itemIndex) == "number" then
        a.awarded = a.awarded or {}
        a.awarded[msg.itemIndex] = msg.winner
        self:RefreshLootItem(msg.itemIndex)
    end
end

-- ── Inbound: an award was CORRECTED (un-awarded) by the ML (§6.15, DL-20) ────
-- Only the bound session ML may retract (DL-11). Write the byte-identical retracted record
-- (mod = msg.ts) so every client converges, and clear the local awarded mirror.
LCEX.dispatch.unaward = function(self, msg, sender)
    if self:IsSelf(sender) then return end -- the ML wrote its own retraction in UnawardItem
    local a = self.activeSession
    if not a or msg.sid ~= a.sid then return end
    if self:NormalizeName(sender) ~= self:NormalizeName(a.ml) then return end
    if type(msg.itemIndex) ~= "number" then return end
    local uid = (msg.sid or "nosession") .. ":" .. tostring(msg.itemIndex)
    self:LogAward(uid, {
        winner = msg.winner, itemID = msg.itemID, itemLink = msg.item,
        ts = msg.ts, mod = msg.ts, by = sender, retracted = true, retractedBy = sender,
    })
    if a.awarded then a.awarded[msg.itemIndex] = nil end
    self:RefreshLootItem(msg.itemIndex)
end

-- The display reason for a history record (DL-8): the stored resolved text when present, else the
-- current set's text for the id (which may render as a raw id for one no longer configured).
function LCEX:HistoryReasonText(rec)
    return rec.respText or self:ResponseText(rec.resp)
end

-- Award-history records for a player (normalized key), or ALL when key is nil — newest first.
-- Shared by /lcex history and the PlayerDetail History tab.
function LCEX:HistoryForPlayer(key)
    local rows = {}
    for _, rec in pairs(self.db.global.history) do
        if not key or self:NormalizeName(rec.player) == key then
            rows[#rows + 1] = rec
        end
    end
    table.sort(rows, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return rows
end

-- /lcex history [player] — dump award history (optionally filtered to one winner), newest first.
function LCEX:CmdHistory(rest)
    rest = strtrim(rest or "")
    local rows = self:HistoryForPlayer(rest ~= "" and self:NormalizeName(rest) or nil)

    self:Msg(string.format(self.L["Award history — %d record(s):"], #rows))
    for i = 1, math.min(#rows, 30) do
        local rec = rows[i]
        self:Msg(string.format(self.L["  %s → %s  (%s, %s)"],
            tostring(rec.itemLink), tostring(rec.player),
            tostring(rec.boss or "?"), date("%m/%d %H:%M", rec.ts or 0)))
    end
    if #rows > 30 then
        self:Msg(string.format(self.L["  …and %d more."], #rows - 30))
    end
end
