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

-- The effective council-roster config (Feature C, C1/C2, resolves DL-1): the shared, officer-authored
-- `config` record when one is authored for this guild, else the local `profile.council` — the
-- pre-config default and the escape hatch (C4). Returns { byRank, rank, extra }.
function LCEX:CouncilConfig()
    local rec = self:ConfigRecord()
    if rec and (rec.byRank ~= nil or rec.rank ~= nil or rec.extra ~= nil) then
        return { byRank = rec.byRank, rank = rec.rank, extra = rec.extra }
    end
    return self.db.profile.council or {}
end

-- Write a council-roster change to the SHARED config (replicated, LWW). Seeds the full trio from the
-- current effective roster so a first edit doesn't drop the other two fields. `changes` overrides any
-- of byRank/rank/extra. Invalidates the cached Plane-B set. (Who MAY write is gated in Core/Access.)
function LCEX:SetCouncilConfig(changes)
    local c = self:CouncilConfig()
    local extra = {}
    for i, n in ipairs(c.extra or {}) do extra[i] = n end
    local rec = {
        byRank = (c.byRank == nil) and true or c.byRank,
        rank   = c.rank or 1,
        extra  = extra,
    }
    for k, v in pairs(changes) do rec[k] = v end
    self:SetConfigFields(rec)
    self._councilSet = nil
end

-- Resolve the council as a SET of normalized names from the effective council config: explicit
-- `extra`, guild members at/above the configured rank (when byRank), and — when `forceSelf` — the
-- local player. Plane A (the session, GetCouncil) forces self in so the runner can always vote and
-- solo testing has a council of one; Plane B (sync) does NOT (you participate only if actually
-- configured as council). Shared by both planes per DL-1 (one council roster, now config-sourced).
function LCEX:ResolveCouncil(forceSelf)
    local set = {}
    local p = self:CouncilConfig()
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

-- The id of the built-in PASS response (a decline / non-roll), used to classify "rollers" in the
-- loot window's 3-tier sort (V1).
function LCEX:PassResponseId()
    for _, r in ipairs(self.RESPONSES) do
        if r.key == "PASS" then return r.id end
    end
    return 5
end

-- Short display text for a seeded row's `reason` while it has no response yet (V1). Locale-driven.
function LCEX:ReasonText(reason)
    if reason == "pending"    then return self.L["Waiting"] end
    if reason == "cantuse"    then return self.L["Can't use"] end
    if reason == "missedkill" then return self.L["Missed kill"] end
    if reason == "left"       then return self.L["Left"] end
    return ""
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

-- ── Duplicate-item grouping (§6.14, DL-19) ───────────────────────────────────
-- Group session items by identical link so duplicate drops share one poll card / one candidate
-- table (RCLC-style), while each award still consumes a DISTINCT physical index. Pure and
-- deterministic: the ML and every client derive the same groups from the same broadcast `items`
-- list, so nothing new rides the wire. leader = the lowest index of each link.
--   { leaderOf = {[i]=leader}, members = {[leader]={i,...}}, leaders = {leadersAsc} }
function LCEX:BuildItemGroups(items)
    local leaderOf, members, leaders, firstByLink = {}, {}, {}, {}
    for i, it in ipairs(items or {}) do
        local link = it.link
        local leader = firstByLink[link]
        if not leader then
            firstByLink[link] = i
            leader = i
            members[i] = {}
            leaders[#leaders + 1] = i
        end
        leaderOf[i] = leader
        members[leader][#members[leader] + 1] = i
    end
    return { leaderOf = leaderOf, members = members, leaders = leaders }
end

-- Union of several {name,class} rosters, deduped by normalized name (first seen wins). A group's
-- kill set is the union of every member copy's captured roster — "more data is better" (R1). Pure.
function LCEX:_UnionRosters(rosters)
    local seen, out = {}, {}
    for _, roster in ipairs(rosters or {}) do
        for _, m in ipairs(roster or {}) do
            local k = self:NormalizeName(m.name)
            if k and not seen[k] then seen[k] = true; out[#out + 1] = m end
        end
    end
    return out
end

-- The physical member indices of a leader's group, CLIENT-SAFE (reads activeSession.groups, which
-- every client derives). Falls back to { leader } when there is no grouping. Used by the UI.
function LCEX:GroupMembers(leader)
    local a = self.activeSession
    local m = a and a.groups and a.groups.members[leader]
    return m or { leader }
end

-- The deduped kill roster for a group leader: union the captured roster of every member copy.
function LCEX:GroupKillRoster(leader)
    local s = self.session
    local members = (s and s.groups and s.groups.members[leader]) or { leader }
    local rosters = {}
    for _, m in ipairs(members) do
        local r = self.sessionItems and self.sessionItems[m] and self.sessionItems[m].roster
        if r then rosters[#rosters + 1] = r end
    end
    return self:_UnionRosters(rosters)
end

-- Build the pre-seeded candidate rows for one session item (V1, PROJECT.md §6.10). The row list is
-- the union (deduped by normalized name) of the KILL roster — who was present when the item dropped
-- — and the CURRENT raid, so both latecomers and leavers show. Each row carries a `reason` until
-- the candidate responds (cResp then sets `resp` and clears `reason`):
--   pending    — eligible (in the kill set, class can use it, still present): "might roll"
--   cantuse    — in the kill set but their class can't use it (an auto-pass, ineligible)
--   missedkill — in the raid now but NOT present at the kill (ineligible for this item)
--   left       — was present at the kill but has since left the raid
-- Pure: depends only on ClassCanUse + NormalizeName. `killRoster`/`nowRoster` are { {name,class} }.
function LCEX:SeedRows(killRoster, nowRoster, itemLink)
    local nowByKey = {}
    for _, m in ipairs(nowRoster or {}) do
        local k = self:NormalizeName(m.name)
        if k then nowByKey[k] = m end
    end
    local rows = {}
    local function put(m, inKill)
        local k = self:NormalizeName(m.name)
        if not k or rows[k] then return end
        local now = nowByKey[k]
        local class = (now and now.class) or m.class
        local reason
        if not now then reason = "left"
        elseif not inKill then reason = "missedkill"
        elseif self:ClassCanUse(itemLink, class) then reason = "pending"
        else reason = "cantuse" end
        rows[k] = { name = m.name, class = class, reason = reason, votes = 0 }
    end
    for _, m in ipairs(killRoster or {}) do put(m, true) end
    for _, m in ipairs(nowRoster or {}) do put(m, false) end -- add current-raid latecomers
    return rows
end

-- Seed every open-session item's rows from its captured loot roster ∪ the current raid (V1), then
-- push each to the ML's own view and out to the council (cUpdate) so the full roster shows
-- immediately. Called from StartSession/ResumeSession AFTER EnterSession (needs the local view).
function LCEX:SeedSessionRows()
    local s = self.session
    if not s then return end
    local nowRoster = self:PresentRoster()
    -- Seed LEADERS only (§6.14): duplicate copies share the leader's rows. The kill set is the
    -- union of every member copy's captured roster.
    for _, leader in ipairs(s.groups.leaders) do
        local killRoster = self:GroupKillRoster(leader)
        s.rows[leader] = self:SeedRows(killRoster, nowRoster, s.items[leader].link)
        self:ApplyCUpdate(s.sid, leader, s.rows[leader], self:ComputeItemStatus(leader)) -- ML's own frame
        self:BroadcastCUpdate(leader)                                                    -- + council (no-op solo)
    end
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
    -- Anonymous voting (V7) is snapshotted from the shared config at start and rides sStart, so it
    -- is fixed for the session's lifetime (mid-session config edits don't retroactively de-anon it).
    local anon = self:GetConfig().anonVoting and true or false
    self.session = {
        sid = sid, items = items, council = council, councilSet = councilSet,
        rows = {}, voters = {}, startedAt = time(), anon = anon,
        groups = self:BuildItemGroups(items), -- duplicate grouping (§6.14)
    }

    -- Optional response deadline (Session Config): rides sStart as a DURATION so receivers
    -- compute a local expiry (no clock-skew risk). Old clients simply ignore the field.
    local timeout = tonumber(self.db.profile.pollTimeout) or 0
    if timeout <= 0 then timeout = nil end

    local channel = self:GroupChannel()
    if channel then
        self:Send("sStart", sid, {
            items = items, council = council, responses = self:ResponseSet(),
            timeout = timeout, anon = anon,
        }, channel)
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) broadcast."], sid, #items))
    else
        self:Msg(string.format(self.L["Session started (%s) — %d item(s) [local only, not in a group]."],
            sid, #items))
    end

    -- Enter our own view of the session (solo or grouped) so the ML can respond/vote and can
    -- preview the frames without a second client. The sStart echo is ignored (see Candidate).
    self:EnterSession(sid, UnitName("player"), items, self:ResponseSet(), council, timeout, anon)
    self:SeedSessionRows() -- pre-seed each item's rows from its roster (V1) and push to the council

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
    local a = self.activeSession
    -- rows/voters/awarded are stored BY REFERENCE (the sessionItems trick, §6.16 / DL-21): every
    -- later mutation is already durable at the next SavedVariables write, so responses, votes, and
    -- awards survive a /reload with no extra save plumbing.
    self.db.global.session[owner] = {
        sid = s.sid, items = s.items, council = s.council,
        sessionItems = self.sessionItems, startedAt = s.startedAt,
        rows = s.rows, voters = s.voters, anon = s.anon,
        awarded = a and a.awarded, savedAt = time(),
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
    -- A themed resume dialog (§6.16) after a short delay so the UI + roster settle post-login;
    -- also surface the recovery pill immediately.
    self:ScheduleTimer("ShowResumePrompt", 3)
    self:UpdateMiniFrame()
end

-- Responses collected in a saved session's aggregate (rows carrying an actual resp), for the
-- resume dialog. Pure/testable.
function LCEX:CountSavedResponses(saved)
    local n = 0
    if saved and saved.rows then
        for _, rows in pairs(saved.rows) do
            for _, d in pairs(rows) do
                if type(d) == "table" and d.resp ~= nil then n = n + 1 end
            end
        end
    end
    return n
end

-- The resume dialog (§6.16): age + item/response counts, Resume to re-open. Declining keeps the
-- session recoverable (the /lcex resume · /lcex end · /lcex abort commands still work). Falls back
-- to chat if the confirm frame is already busy (e.g. Feature C's inherit prompt).
function LCEX:ShowResumePrompt()
    local saved = self.recoverableSession
    if not saved then return end
    local msg = string.format(
        self.L["Unfinished loot session from %s — %d item(s), %d response(s) collected."],
        self:RelTime(saved.savedAt or saved.startedAt), #saved.items, self:CountSavedResponses(saved))
    if self._confirmFrame and self._confirmFrame:IsShown() then
        self:Msg(msg .. " " .. self.L["/lcex resume to re-open, /lcex end to discard."])
        return
    end
    self:ShowConfirm({
        text = msg,
        accept = self.L["Resume"],
        onAccept = function() self:ResumeSession() end,
    })
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
    -- anon is restored from the SAVE (it was snapshotted onto the session at start, §6.16) — not
    -- re-read from config, so the session's anonymity can't silently change across a reload.
    local anon = saved.anon and true or false
    self.session = {
        sid = saved.sid, items = saved.items, council = saved.council, councilSet = councilSet,
        rows = {}, voters = saved.voters or {}, startedAt = saved.startedAt or time(), anon = anon,
        groups = self:BuildItemGroups(saved.items), -- duplicate grouping (§6.14)
    }
    self.sessionItems = saved.sessionItems

    local timeout = tonumber(self.db.profile.pollTimeout) or 0
    if timeout <= 0 then timeout = nil end
    local channel = self:GroupChannel()
    if channel then
        self:Send("sStart", saved.sid, {
            items = saved.items, council = saved.council, responses = self:ResponseSet(),
            timeout = timeout, anon = anon,
        }, channel)
    else
        self:Msg(self.L["Resuming locally — you're not in a group, so this is read-only recovery."])
    end
    self:EnterSession(saved.sid, UnitName("player"), saved.items, self:ResponseSet(), saved.council, timeout, anon)
    -- Restore the awarded mirror BEFORE seeding so ComputeItemStatus sees it (border/tally correct).
    if self.activeSession then self.activeSession.awarded = saved.awarded or {} end
    self:SeedSessionRows() -- fresh seed (late joiners appear) …
    -- … then overlay the saved aggregate so collected responses/votes survive (§6.16), and re-push.
    for _, leader in ipairs(self.session.groups.leaders) do
        self.session.rows[leader] = self:_OverlaySavedRows(self.session.rows[leader],
            saved.rows and saved.rows[leader])
        self:ApplyCUpdate(self.session.sid, leader, self.session.rows[leader],
            self:ComputeItemStatus(leader))
        self:BroadcastCUpdate(leader)
    end
    self:SaveSession()    -- re-mirror with the new live references
    self:StartHeartbeat() -- no-op out of a group; re-arms on the next roster update with a channel
    self:UpdateMiniFrame()
    self:Msg(string.format(self.L["Resumed session (%s) — %d item(s)."], saved.sid, #saved.items))
    return true
end

-- Overlay a saved per-item aggregate onto freshly-seeded rows (§6.16): a saved responder's
-- resp/note/gear/votes win (their reason clears); a seeded non-responder keeps its class/reason; a
-- saved responder no longer in the seed roster re-enters marked "left" (accumulate, never drop —
-- R5). Pure given the two row maps.
function LCEX:_OverlaySavedRows(seeded, saved)
    local out = {}
    for k, r in pairs(seeded or {}) do out[k] = r end
    for k, sr in pairs(saved or {}) do
        local base = out[k]
        if base then
            if sr.resp ~= nil then
                base.resp, base.reason, base.note, base.gear = sr.resp, nil, sr.note, sr.gear
            end
            base.votes = sr.votes or base.votes or 0
        else
            local copy = {}
            for kk, vv in pairs(sr) do copy[kk] = vv end
            if copy.resp == nil then copy.reason = "left" end
            out[k] = copy
        end
    end
    return out
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
            self:UpdateMiniFrame() -- clear the recovery pill (§6.16)
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
        -- Status computed at SEND time (inside the debounce) so it reflects the final state after a
        -- burst of responses/votes coalesces (V3 — every client renders the same border, §6.10).
        self:Send("cUpdate", s.sid,
            { item = index, rows = s.rows[index], status = self:ComputeItemStatus(index) }, channel)
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
    -- Aggregate under the group LEADER (§6.14): duplicate copies share one candidate table.
    -- Identity mapping when no duplicates exist, so a non-grouped session is byte-unchanged.
    index = (s.groups and s.groups.leaderOf[index]) or index

    local rows = s.rows[index] or {}
    s.rows[index] = rows
    local key = self:NormalizeName(sender)
    local prev = rows[key]
    rows[key] = {
        name   = sender,
        class  = prev and prev.class,        -- preserve the seeded class (V1)
        resp   = msg.resp,
        reason = nil,                        -- responded → no longer a pending/ineligible seed
        note   = msg.note,
        gear   = msg.gear,
        votes  = (prev and prev.votes) or 0, -- preserve any tally across a re-response
    }

    self:Msg(string.format(self.L["%s responded %s to %s."],
        sender, self:ResponseText(msg.resp), s.items[index].link))
    self:ApplyCUpdate(s.sid, index, s.rows[index], self:ComputeItemStatus(index)) -- ML's own frame now
    self:BroadcastCUpdate(index)
end

-- ── ML inbound: a rejoin request (§6.16) ─────────────────────────────────────
-- A reloaded / mid-session-joining candidate heard our sPing and asked to (re)join. Whisper back
-- a session snapshot (sJoin) plus the current per-leader cUpdate, so they re-enter without a
-- full raid re-broadcast. Gated to a real group member for our open session.
LCEX.dispatch.sReq = function(self, msg, sender)
    local s = self.session
    if not s or msg.sid ~= s.sid then return end
    if not self:InGroupWith(sender) then return end
    local a = self.activeSession
    -- Remaining deadline as a fresh DURATION (no clock-skew), like sStart.
    local timeout
    if a and a.deadlineAt then
        local left = a.deadlineAt - GetTime()
        if left and left > 0 then timeout = left end
    end
    self:Send("sJoin", s.sid, {
        items = s.items, council = s.council, responses = self:ResponseSet(),
        timeout = timeout, anon = s.anon, awarded = (a and a.awarded) or {},
    }, "WHISPER", sender)
    -- Then the live aggregate per group leader (AceComm keeps per-target order, so sJoin lands first).
    for _, leader in ipairs(s.groups.leaders) do
        if s.rows[leader] then
            self:Send("cUpdate", s.sid,
                { item = leader, rows = s.rows[leader], status = self:ComputeItemStatus(leader) },
                "WHISPER", sender)
        end
    end
end
