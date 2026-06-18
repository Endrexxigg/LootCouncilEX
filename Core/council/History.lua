-- ── LootCouncil EX — council/History.lua ─────────────────────────────────────
-- Plane B: the award-history dataset. Immutable (union merge by uid) — awards are facts, not
-- edits. Every client PRESENT for an award logs it locally from the `award` broadcast (§6.1),
-- so the record needs no central authority; the union sync (Sync.lua) then carries it to
-- council members who were absent. uid = "<sid>:<itemIndex>" (§6.3).
--
-- Two write paths, one record builder:
--   • The ML logs directly in AwardItem via LCEX:LogAward (doesn't rely on its own echo).
--   • Everyone else logs in the inbound `award` handler below.
-- Both go through MergeRecord (no re-broadcast; union is idempotent on a repeated uid).
--
-- Loads after Sync.lua (RegisterDataset/MergeRecord) and Comms.lua (dispatch table).

local LCEX = LootCouncilEX
LCEX.dispatch = LCEX.dispatch or {}

-- Register at load (store closure is invoked lazily, after the DB exists — same as `dummy`).
LCEX:RegisterDataset("history", "union", function() return LCEX.db.global.history end)

-- The §6.3 history record. `by`/`mod` are extensions kept for display/self-description; union
-- merges purely by key presence, so they never affect the merge.
function LCEX:BuildHistoryRecord(f)
    return {
        player   = f.winner,
        itemID   = f.itemID,
        itemLink = f.itemLink,
        ts       = f.ts or time(),
        resp     = f.resp,
        boss     = f.boss,
        instance = f.instance,
        by       = f.by,
        mod      = f.ts or time(),
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
        ts = msg.ts, resp = msg.resp, boss = msg.boss, instance = msg.instance, by = sender,
    })
end

-- /lcex history [player] — dump award history (optionally filtered to one winner), newest
-- first. The headless verifier; Phase 6 builds the real PlayerDetail/History UI.
function LCEX:CmdHistory(rest)
    rest = strtrim(rest or "")
    local filter = rest ~= "" and self:NormalizeName(rest) or nil

    local rows = {}
    for _, rec in pairs(self.db.global.history) do
        if not filter or self:NormalizeName(rec.player) == filter then
            rows[#rows + 1] = rec
        end
    end
    table.sort(rows, function(a, b) return (a.ts or 0) > (b.ts or 0) end)

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
