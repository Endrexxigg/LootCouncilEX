-- ── LootCouncil EX — session/Session.lua ─────────────────────────────────────
-- Plane A: the live loot session state machine. The master looter is the single source of
-- truth (PROJECT.md §3); a session exists only while open and every change funnels through
-- the ML. The ML opens a session (sStart), aggregates candidate responses (cResp) into the
-- authoritative per-item `rows`, and rebroadcasts that as cUpdate; it closes with sEnd. The
-- vote tally (vVote) joins this in the Council slice.
--
-- Loads after Comms.lua (uses LCEX:Send / LCEX:GroupChannel / LCEX:Msg / the dispatch table).

local LCEX = LootCouncilEX
LCEX.dispatch = LCEX.dispatch or {}

-- Per-session monotonic counter, combined with the ML name + unixtime into the sid
-- (PROJECT.md §6.1: "<MLname>-<unixtime>-<counter>").
local counter = 0

-- LCEX.session is nil when idle, else { sid, items, council, rows, startedAt }. `items` holds
-- the wire form { [i] = { link, quality } } that was broadcast in sStart. (Items live in
-- the ML's bags, not a loot window, so there is no loot slot — the ML resolves the live
-- bag/slot at trade time in Award.lua.) `rows` is the per-item response aggregate (see below).

-- The voting council for a session. Phase-3 stand-in: empty (voting lands in slice 2 with
-- Council.lua/VotingFrame). The sStart schema carries a `council` key; real rank-based
-- resolution lands with the council toolkit.
function LCEX:GetCouncil()
    return {}
end

-- The response set carried in sStart so every candidate renders the same buttons (DL-8).
-- Defaults to the built-in RESPONSES until the settings UI makes it configurable (Phase 3).
function LCEX:ResponseSet()
    return self.RESPONSES
end

-- Display text for a response id. Falls back to the raw id (e.g. a STATUS sentinel).
function LCEX:ResponseText(id)
    for _, r in ipairs(self.RESPONSES) do
        if r.id == id then return r.text end
    end
    return tostring(id)
end

-- True if `name` is in our current group (raid/party). The ML drops cResp/vVote from
-- non-members. Self always passes (the ML can respond to its own session).
function LCEX:InGroupWith(name)
    if self:IsSelf(name) then return true end
    local n = self:NormalizeName(name)
    if not n then return false end
    local inRaid = IsInRaid()
    for i = 1, GetNumGroupMembers() do
        local unit = inRaid and ("raid" .. i) or ("party" .. i)
        local u = UnitName(unit)
        if u and self:NormalizeName(u) == n then return true end
    end
    return false
end

function LCEX:NewSessionID()
    counter = counter + 1
    return UnitName("player") .. "-" .. time() .. "-" .. counter
end

-- Open a session over the given trimmed item list and broadcast sStart. Refuses if a
-- session is already open or there is nothing to council. With no group we still open the
-- session locally (no broadcast) so the flow can be exercised/tested solo.
function LCEX:StartSession(items)
    if self.session then
        self:Msg(self.L["A session is already active. /lcex end first."])
        return
    end
    if not items or #items == 0 then
        self:Msg(self.L["Nothing to council."])
        return
    end

    local sid = self:NewSessionID()
    -- `rows` accumulates candidate responses per item index (the ML-authority aggregate that
    -- gets rebroadcast as cUpdate): rows[itemIndex][normName] = { name, resp, note, gear, votes }.
    self.session = {
        sid = sid, items = items, council = self:GetCouncil(),
        rows = {}, startedAt = time(),
    }

    local channel = self:GroupChannel()
    if channel then
        self:Send("sStart", sid, {
            items = items, council = self.session.council, responses = self:ResponseSet(),
        }, channel)
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) broadcast."], sid, #items))
    else
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) [local only, not in a group]."],
            sid, #items))
    end

    -- Show our own candidate view too (solo or grouped) so the ML can respond and can preview
    -- the frame without a second client.
    self:OpenOwnCandidateView(sid, items, self:ResponseSet())
end

-- Close the active session and broadcast sEnd.
function LCEX:EndSession()
    if not self.session then
        self:Msg(self.L["No active session."])
        return
    end
    local sid = self.session.sid
    local channel = self:GroupChannel()
    if channel then
        self:Send("sEnd", sid, {}, channel)
    end
    self.session = nil
    self.sessionItems = nil -- the ML-side full records (Award.lua); pendingTrades outlive the session
    self:CloseOwnCandidateView(sid)
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
        self:Msg(string.format(self.L["  %d. %s (q%d)"], i, it.link, it.quality))
    end
end

-- ── ML inbound: candidate responses ──────────────────────────────────────────
-- Rebroadcast the aggregated state for one item to the raid as cUpdate, debounced (~0.2s per
-- §6.1) so a burst of responses collapses into one send. Keyed per item so distinct items
-- don't coalesce into each other.
function LCEX:BroadcastCUpdate(index)
    local channel = self:GroupChannel()
    if not channel then return end
    self:DebouncedSend("cUpdate:" .. index, function()
        local s = self.session
        if not s or not s.rows[index] then return end
        self:Send("cUpdate", s.sid, { item = index, rows = s.rows[index] }, channel)
    end)
end

-- A candidate responded (WHISPER → ML). Accept only for the open session (matching sid) from
-- a real group member, store the row keyed by normalized name, and rebroadcast cUpdate. (cResp
-- is candidate-originated, so it is NOT ML-gated — any group member may respond.)
LCEX.dispatch.cResp = function(self, msg, sender)
    local s = self.session
    if not s or msg.sid ~= s.sid then return end
    if not self:InGroupWith(sender) then return end
    local index = msg.item
    if type(index) ~= "number" or not s.items[index] then return end

    local rows = s.rows[index] or {}
    s.rows[index] = rows
    local key = self:NormalizeName(sender)
    local prev = rows[key]
    rows[key] = {
        name  = sender,
        resp  = msg.resp,
        note  = msg.note,
        gear  = msg.gear,
        votes = (prev and prev.votes) or 0, -- preserve any tally across a re-response
    }

    self:Msg(string.format(self.L["%s responded %s to %s."],
        sender, self:ResponseText(msg.resp), s.items[index].link))
    self:BroadcastCUpdate(index)
end
