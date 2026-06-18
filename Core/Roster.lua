-- ── LootCouncil EX — Roster.lua ──────────────────────────────────────────────
-- Tracks which group members run the addon and at what version, via the vCheck/vReply
-- handshake (PROJECT.md §6.1). These are roster messages, not session messages, so
-- they carry sid = nil.
--
-- Flow:
--   • We announce ourselves with vCheck → RAID/PARTY/INSTANCE_CHAT (on /lcex ping or
--     zoning in; debounced in Comms).
--   • A peer receiving vCheck records our version and answers vReply → WHISPER to us.
--   • Receiving vReply records the peer's version. vReply is NOT answered, so the
--     handshake terminates instead of ping-ponging.
--
-- Loads after Comms.lua, whose LCEX.dispatch table we populate here.

local LCEX = LootCouncilEX

-- name -> version string of every addon user we have heard from (incl. ourselves).
LCEX.versions = LCEX.versions or {}
LCEX.dispatch = LCEX.dispatch or {}

-- Record (or update) a peer's version. Announces once per change unless `silent` — the
-- passive backfill from ordinary traffic (Comms.OnCommReceived) stays quiet; only the
-- explicit vCheck/vReply handshake announces. (Self-skip lives in the callers via IsSelf.)
function LCEX:RecordVersion(name, ver, silent)
    ver = tostring(ver or "?")
    local prev = self.versions[name]
    self.versions[name] = ver
    if prev ~= ver and not silent then
        self:Msg(string.format(self.L["%s is running v%s"], name, ver))
    end
end

-- Seed ourselves so /lcex version always lists at least us.
function LCEX:RosterInit()
    self.versions[UnitName("player")] = self:GetVersion()
end

-- Announce our version to the current group (the envelope carries `ver`). Silent (returns
-- true/false) so the automatic zone-in / roster-change broadcasts don't spam chat; the
-- manual /lcex ping (CmdPing) prints its own feedback.
function LCEX:BroadcastVCheck()
    local channel = self:GroupChannel()
    if not channel then
        return false
    end
    self:Send("vCheck", nil, nil, channel)
    return true
end

-- Automatic (event-driven) re-announce, suppressed in combat so a roster-churn burst can't
-- fire mid-pull. The manual /lcex ping path (CmdPing → BroadcastVCheck) is unaffected.
function LCEX:AutoBroadcastVCheck()
    if UnitAffectingCombat("player") then return end
    self:BroadcastVCheck()
end

-- /lcex ping — manual version check. Prints confirmation now, then the resulting roster
-- a beat later (replies arrive by whisper). RecordVersion only announces NEW/changed
-- versions to avoid spamming the automatic broadcasts, so this delayed summary is what
-- gives a manual ping visible feedback even when nothing changed.
function LCEX:CmdPing()
    if not self:BroadcastVCheck() then
        self:Msg(self.L["Not in a group — nothing to broadcast."])
        return
    end
    self:Msg(string.format(self.L["Version check sent (v%s) — watch for replies."], self:GetVersion()))
    if self.pingSummaryTimer then
        self:CancelTimer(self.pingSummaryTimer)
    end
    self.pingSummaryTimer = self:ScheduleTimer("PrintKnownVersions", 1.5)
end

-- /lcex version — list every known addon user, sorted, with their version.
function LCEX:PrintKnownVersions()
    self:Msg(self.L["Known addon users:"])
    local names = {}
    for name in pairs(self.versions) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        self:Msg(string.format(self.L["  %s — v%s"], name, self.versions[name]))
    end
end

-- ── Dispatch handlers (registered into Comms' table) ─────────────────────────
-- Someone announced themselves: record them and reply privately with our version.
LCEX.dispatch.vCheck = function(self, msg, sender)
    if self:IsSelf(sender) then return end
    self:RecordVersion(sender, msg.ver)
    self:Send("vReply", nil, nil, "WHISPER", sender)
end

-- A private reply to our vCheck: record only — do not reply, or the two clients would
-- bounce vReplies forever.
LCEX.dispatch.vReply = function(self, msg, sender)
    if self:IsSelf(sender) then return end
    self:RecordVersion(sender, msg.ver)
end
