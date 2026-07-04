-- ── LootCouncil EX — session/Council.lua ─────────────────────────────────────
-- Council side of Plane A: consume the ML's cUpdate into the local voting view, let council
-- members cast votes (vVote), and — on the ML — tally those votes into the authoritative
-- session state. Pairs with UI/VotingFrame.lua (the table) the way Candidate.lua pairs with
-- LootFrame.lua.
--
-- Data flow:
--   ML aggregates cResp into session.rows (Session.lua) → cUpdate → here: ApplyCUpdate mirrors
--   it into self.voteRows and refreshes the frame. A vote → vVote → the ML tallies it into
--   session.voters / row.votes and re-broadcasts cUpdate.
--
-- Loads after UI/VotingFrame.lua (refreshes it) and Comms.lua (dispatch table).

local LCEX = LootCouncilEX
LCEX.dispatch = LCEX.dispatch or {}

-- Mirror the ML's broadcast of one item's rows (+ readiness status) into our local voting view and
-- refresh the frame. Council-only and gated to the active session's sid (a stale/foreign sid is
-- ignored). On the ML this is fed directly from session.rows + ComputeItemStatus; on council from
-- the received cUpdate. `status` (Feature V, §6.10) may be nil — the rail-row border then clears.
function LCEX:ApplyCUpdate(sid, index, rows, status)
    local a = self.activeSession
    -- Populate the local voting view for council AND any opted-in raider watching (C7) — otherwise a
    -- transparency viewer's loot window would render empty. Non-council can view but not vote.
    if not a or sid ~= a.sid or not (a.amCouncil or a.canSeeLoot) then return end
    self.voteRows = self.voteRows or {}
    self.voteRows[index] = rows
    self.voteStatus = self.voteStatus or {}
    self.voteStatus[index] = status
    self:RefreshLootItem(index)
end

-- Cast (or toggle off) our vote for a candidate on an item. Sends vVote to the ML; if WE are
-- the ML, tally locally (a WHISPER to self isn't reliably delivered).
function LCEX:SendVote(index, candKey, vote)
    local a = self.activeSession
    if not a or not a.amCouncil then return end
    a.myVotes = a.myVotes or {}
    a.myVotes[index] = a.myVotes[index] or {}
    if a.myVotes[index][candKey] == vote then vote = 0 end -- clicking the same vote clears it
    a.myVotes[index][candKey] = vote

    local payload = { item = index, candidate = candKey, vote = vote }
    if self:IsSelf(a.ml) then
        payload.sid = a.sid
        self.dispatch.vVote(self, payload, UnitName("player"))
    else
        self:Send("vVote", a.sid, payload, "WHISPER", a.ml)
    end
    self:RefreshLootItem(index) -- update our own-vote highlight immediately
end

-- ── Dispatch handlers ────────────────────────────────────────────────────────
-- The ML rebroadcast an item's aggregated rows. Only the bound ML for our session may move
-- our view (DL-11).
LCEX.dispatch.cUpdate = function(self, msg, sender)
    if self:IsSelf(sender) then return end -- our own echo; the ML already applied it locally
    local a = self.activeSession
    if not a or msg.sid ~= a.sid then return end
    if self:NormalizeName(sender) ~= self:NormalizeName(a.ml) then return end
    if type(msg.item) ~= "number" or type(msg.rows) ~= "table" then return end
    self:ResetSessionTimeout() -- a real update from our ML counts as a heartbeat (DL-6)
    self:ApplyCUpdate(msg.sid, msg.item, msg.rows, msg.status)
end

-- A council member voted (WHISPER → ML). ML-only authority: validate the open session + a
-- real council sender, record the per-voter vote, recompute the candidate's tally, and
-- rebroadcast. (vVote is council-gated, unlike candidate-originated cResp.)
LCEX.dispatch.vVote = function(self, msg, sender)
    local s = self.session
    if not s or msg.sid ~= s.sid then return end
    if not self:IsCouncil(sender) then return end
    local index, candKey = msg.item, msg.candidate
    if type(index) ~= "number" or not s.items[index] then return end
    local row = s.rows[index] and s.rows[index][candKey]
    if not row then return end -- can't vote for someone who hasn't responded

    local vote = msg.vote
    if vote ~= 1 and vote ~= -1 then vote = 0 end

    s.voters[index] = s.voters[index] or {}
    s.voters[index][candKey] = s.voters[index][candKey] or {}
    s.voters[index][candKey][self:NormalizeName(sender)] = vote

    local sum = 0
    for _, v in pairs(s.voters[index][candKey]) do sum = sum + v end
    row.votes = sum

    self:ApplyCUpdate(s.sid, index, s.rows[index], self:ComputeItemStatus(index)) -- ML's own frame
    self:BroadcastCUpdate(index)
end
