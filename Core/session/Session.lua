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

-- Guild-roster refresh nudge. The GuildRoster global is REMOVED on Anniversary (selftest env
-- fact: GuildRoster=nil); it lives under C_GuildInfo there. Either form, or nil — callers guard.
local RequestGuildRoster = GuildRoster or (C_GuildInfo and C_GuildInfo.GuildRoster)

-- Per-session monotonic counter, combined with the ML name + unixtime into the sid
-- (PROJECT.md §6.1: "<MLname>-<unixtime>-<counter>").
local counter = 0

-- While a session is open the ML pings the raid every SPING_INTERVAL so candidates know it's
-- still alive (DL-6); a candidate that hears nothing for STALE_AFTER (Candidate.lua) gives up.
local SPING_INTERVAL = 30

-- LCEX.session is nil when idle, else { sid, items, council, rows, startedAt }. `items` holds
-- the wire form { [i] = { link, quality } } that was broadcast in sStart. (Items live in
-- the ML's bags, not a loot window, so there is no loot slot — the ML resolves the live
-- bag/slot at trade time in Award.lua.) `rows` is the per-item response aggregate (see below).

-- Resolve the council as a SET of normalized names from profile.council: explicit `extra`,
-- guild members at/above the configured rank (when byRank), and — when `forceSelf` — the local
-- player. Plane A (the session, GetCouncil) forces self in so the runner can always vote and
-- solo testing has a council of one; Plane B (sync) does NOT (you participate only if actually
-- configured as council). Shared by both planes per DL-1 (one council roster for v1).
function LCEX:ResolveCouncil(forceSelf)
    local set = {}
    local p = self.db.profile.council or {}
    for _, name in ipairs(p.extra or {}) do
        local n = self:NormalizeName(name)
        if n then set[n] = true end
    end
    if forceSelf then set[self:NormalizeName(UnitName("player"))] = true end
    if p.byRank and IsInGuild() then
        if RequestGuildRoster then RequestGuildRoster() end -- nudge a roster refresh (may be stale this frame)
        for i = 1, (GetNumGuildMembers() or 0) do
            local gname, _, rankIndex = GetGuildRosterInfo(i)
            if gname and rankIndex and rankIndex <= (p.rank or 1) then
                local n = self:NormalizeName(gname)
                if n then set[n] = true end
            end
        end
    end
    return set
end

-- The Plane-A session council as a list of normalized names (runner always included), carried
-- in sStart.
function LCEX:GetCouncil()
    local list = {}
    for n in pairs(self:ResolveCouncil(true)) do list[#list + 1] = n end
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

    -- Optional response deadline (Session Config): rides sStart as a DURATION so receivers
    -- compute a local expiry (no clock-skew risk). Old clients simply ignore the field.
    local timeout = tonumber(self.db.profile.pollTimeout) or 0
    if timeout <= 0 then timeout = nil end

    local channel = self:GroupChannel()
    if channel then
        self:Send("sStart", sid, {
            items = items, council = council, responses = self:ResponseSet(),
            timeout = timeout,
        }, channel)
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) broadcast."], sid, #items))
    else
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) [local only, not in a group]."],
            sid, #items))
    end

    -- Enter our own view of the session (solo or grouped) so the ML can respond/vote and can
    -- preview the frames without a second client. The sStart echo is ignored (see Candidate).
    self:EnterSession(sid, UnitName("player"), items, self:ResponseSet(), council, timeout)

    self:SaveSession()    -- mirror to the DB so a /reload can resume it (DL-6)
    self:StartHeartbeat() -- tell candidates we're alive
end

-- ── ML heartbeat (DL-6) ──────────────────────────────────────────────────────
function LCEX:StartHeartbeat()
    self:StopHeartbeat()
    if self:GroupChannel() then
        self.sPingTimer = self:ScheduleRepeatingTimer("SendSessionPing", SPING_INTERVAL)
    end
end

function LCEX:StopHeartbeat()
    if self.sPingTimer then
        self:CancelTimer(self.sPingTimer)
        self.sPingTimer = nil
    end
end

function LCEX:SendSessionPing()
    local s = self.session
    local channel = s and self:GroupChannel()
    if channel then self:Send("sPing", s.sid, {}, channel) end
end

-- ── ML session persistence + resume (DL-6) ───────────────────────────────────
-- Mirror / restore the open ML session under the owner key (like owed trades, Award.lua). On
-- /reload the in-memory session is gone; RestoreSession offers the ML `/lcex resume`, which
-- re-broadcasts sStart (with the SAME sid, so history uids stay stable) and rebuilds ML state.
function LCEX:SaveSession()
    local owner = self:OwnerKey()
    local s = self.session
    if not owner or not s then return end
    self.db.global.session[owner] = {
        sid = s.sid, items = s.items, council = s.council,
        sessionItems = self.sessionItems, startedAt = s.startedAt,
    }
end

function LCEX:ClearSavedSession()
    local owner = self:OwnerKey()
    if owner then self.db.global.session[owner] = nil end
    self.recoverableSession = nil
end

function LCEX:RestoreSession()
    local owner = self:OwnerKey()
    local saved = owner and self.db and self.db.global.session[owner]
    if not saved or type(saved.items) ~= "table" or #saved.items == 0 then return end
    self.recoverableSession = saved
    self:Msg(string.format(
        self.L["Unfinished session from before reload (%d item(s)). /lcex resume to re-open, /lcex end to discard."],
        #saved.items))
end

function LCEX:ResumeSession()
    local saved = self.recoverableSession
    if not saved then return false end
    if self.session then
        self:Msg(self.L["A session is already active. /lcex end first."])
        return false
    end
    self.recoverableSession = nil

    local councilSet = {}
    for _, n in ipairs(saved.council or {}) do councilSet[n] = true end
    self.session = {
        sid = saved.sid, items = saved.items, council = saved.council, councilSet = councilSet,
        rows = {}, voters = {}, startedAt = saved.startedAt or time(),
    }
    self.sessionItems = saved.sessionItems

    local timeout = tonumber(self.db.profile.pollTimeout) or 0
    if timeout <= 0 then timeout = nil end
    local channel = self:GroupChannel()
    if channel then
        self:Send("sStart", saved.sid, {
            items = saved.items, council = saved.council, responses = self:ResponseSet(),
            timeout = timeout,
        }, channel)
    end
    self:EnterSession(saved.sid, UnitName("player"), saved.items, self:ResponseSet(), saved.council, timeout)
    self:SaveSession()
    self:StartHeartbeat()
    self:Msg(string.format(self.L["Resumed session (%s) — %d item(s)."], saved.sid, #saved.items))
    return true
end

-- /lcex resume — re-open the session that was open before a /reload.
function LCEX:CmdResume()
    if self.recoverableSession then
        self:ResumeSession()
    else
        self:Msg(self.L["No session to resume."])
    end
end

-- Close the active session and broadcast sEnd. With no live session but a recoverable one (a
-- /reload left one persisted), /lcex end discards it instead (DL-6).
function LCEX:EndSession()
    if not self.session then
        if self.recoverableSession then
            self:ClearSavedSession()
            self:Msg(self.L["Discarded the unfinished session."])
        else
            self:Msg(self.L["No active session."])
        end
        return
    end
    local sid = self.session.sid
    local channel = self:GroupChannel()
    if channel then
        self:Send("sEnd", sid, {}, channel)
    end
    self:StopHeartbeat()
    self.session = nil
    self.sessionItems = nil -- the ML-side full records (Award.lua); pendingTrades outlive the session
    self:ClearSavedSession()
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
