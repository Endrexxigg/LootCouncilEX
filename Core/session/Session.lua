-- ── LootCouncil EX — session/Session.lua ─────────────────────────────────────
-- Plane A: the live loot session state machine. The master looter is the single
-- source of truth (PROJECT.md §3); a session exists only while open and every change
-- would funnel through the ML. Phase 2 is headless and SEND-ONLY: we open a session,
-- broadcast sStart to the group, and close it with sEnd. Receiving candidate responses
-- / votes and rebroadcasting cUpdate is Phase 3 — no inbound handlers live here yet.
--
-- Loads after Comms.lua (uses LCEX:Send / LCEX:GroupChannel / LCEX:Msg).

local LCEX = LootCouncilEX

-- Per-session monotonic counter, combined with the ML name + unixtime into the sid
-- (PROJECT.md §6.1: "<MLname>-<unixtime>-<counter>").
local counter = 0

-- LCEX.session is nil when idle, else { sid, items, council, startedAt }. `items` holds
-- the wire form { [i] = { link, slot, quality } } that was broadcast in sStart.

-- The voting council for a session. Phase-2 stand-in: empty. The sStart schema carries
-- a `council` key, but no Phase-2 consumer reads it; real (rank-based) resolution lands
-- with the council toolkit in a later phase.
function LCEX:GetCouncil()
    return {}
end

function LCEX:NewSessionID()
    counter = counter + 1
    return UnitName("player") .. "-" .. time() .. "-" .. counter
end

-- Open a session over the given trimmed item list and broadcast sStart. Refuses if a
-- session is already open, we are not in a group, or there is nothing to council.
function LCEX:StartSession(items)
    if self.session then
        self:Msg(self.L["A session is already active. /lcex end first."])
        return
    end
    local channel = self:GroupChannel()
    if not channel then
        self:Msg(self.L["Not in a group — nothing to broadcast."])
        return
    end
    if not items or #items == 0 then
        self:Msg(self.L["Nothing scanned — open a corpse as master looter first."])
        return
    end

    local sid = self:NewSessionID()
    self.session = { sid = sid, items = items, council = self:GetCouncil(), startedAt = time() }
    self:Send("sStart", sid, { items = items, council = self.session.council }, channel)
    self:Msg(string.format(self.L["Session started (%s) — %d item(s) broadcast."], sid, #items))
end

-- Close the active session and broadcast sEnd.
function LCEX:EndSession()
    if not self.session then
        self:Msg(self.L["No active session."])
        return
    end
    local channel = self:GroupChannel()
    if channel then
        self:Send("sEnd", self.session.sid, {}, channel)
    end
    self.session = nil
    self:Msg(self.L["Session ended."])
end

-- /lcex session — dump the current session state for headless verification.
function LCEX:CmdSession()
    if not self.session then
        self:Msg(self.L["No active session."])
        return
    end
    local s = self.session
    self:Msg(string.format(self.L["Session %s — %d item(s):"], s.sid, #s.items))
    for i, it in ipairs(s.items) do
        self:Msg(string.format(self.L["  %d. %s (slot %d, q%d)"], i, it.link, it.slot, it.quality))
    end
end
