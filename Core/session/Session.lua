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

-- The voting council for a session, as a list of normalized names carried in sStart. Resolved
-- from profile.council: explicit `extra` names, the session runner (always), and — when
-- byRank — guild members at or above the configured rank. Degrades to just the runner solo /
-- outside a guild (so solo testing still has a council of one).
function LCEX:GetCouncil()
    local set = {}
    local p = self.db.profile.council or {}
    for _, name in ipairs(p.extra or {}) do
        local n = self:NormalizeName(name)
        if n then set[n] = true end
    end
    set[self:NormalizeName(UnitName("player"))] = true
    if p.byRank and IsInGuild() then
        if GuildRoster then GuildRoster() end -- nudge a roster refresh (may be stale this frame)
        for i = 1, (GetNumGuildMembers() or 0) do
            local gname, _, rankIndex = GetGuildRosterInfo(i)
            if gname and rankIndex and rankIndex <= (p.rank or 1) then
                local n = self:NormalizeName(gname)
                if n then set[n] = true end
            end
        end
    end
    local list = {}
    for n in pairs(set) do list[#list + 1] = n end
    return list
end

-- True if `name` is on the current session's council (the set resolved at start). The ML uses
-- this to gate inbound vVote.
function LCEX:IsCouncil(name)
    local n = self:NormalizeName(name)
    if not n or not self.session then return false end
    return self.session.councilSet ~= nil and self.session.councilSet[n] == true
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
    local council = self:GetCouncil()
    local councilSet = {}
    for _, n in ipairs(council) do councilSet[n] = true end
    -- `rows` accumulates candidate responses per item index (the ML-authority aggregate that
    -- gets rebroadcast as cUpdate): rows[itemIndex][normName] = { name, resp, note, gear, votes }.
    -- `voters` tracks each council member's vote per candidate so the tally recomputes on change.
    self.session = {
        sid = sid, items = items, council = council, councilSet = councilSet,
        rows = {}, voters = {}, startedAt = time(),
    }

    local channel = self:GroupChannel()
    if channel then
        self:Send("sStart", sid, {
            items = items, council = council, responses = self:ResponseSet(),
        }, channel)
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) broadcast."], sid, #items))
    else
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) [local only, not in a group]."],
            sid, #items))
    end

    -- Enter our own view of the session (solo or grouped) so the ML can respond/vote and can
    -- preview the frames without a second client. The sStart echo is ignored (see Candidate).
    self:EnterSession(sid, UnitName("player"), items, self:ResponseSet(), council)
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
    self:LeaveSession(sid)
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
    self:ApplyCUpdate(s.sid, index, s.rows[index]) -- refresh the ML's own voting frame now
    self:BroadcastCUpdate(index)
end
