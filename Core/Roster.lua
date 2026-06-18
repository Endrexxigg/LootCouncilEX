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

-- True if `sender` is us. AceComm echoes our own RAID/PARTY broadcasts back to us, and
-- it runs Ambiguate(sender, "none") so a same-realm sender arrives bare ("Name"); we
-- compare against the bare player name and also tolerate a "Name-Realm" form.
local function IsMe(sender)
    if not sender then return false end
    local me = UnitName("player")
    return sender == me or sender:match("^([^%-]+)") == me
end

-- Record (or update) a peer's version and announce it once per change.
function LCEX:RecordVersion(name, ver)
    ver = tostring(ver or "?")
    local prev = self.versions[name]
    self.versions[name] = ver
    if prev ~= ver then
        self:Msg(string.format(self.L["%s is running v%s"], name, ver))
    end
end

-- Seed ourselves so /lcex version always lists at least us.
function LCEX:RosterInit()
    self.versions[UnitName("player")] = self:GetVersion()
end

-- Announce our version to the current group. No-op (with feedback) when solo.
function LCEX:BroadcastVCheck()
    local channel = self:GroupChannel()
    if not channel then
        self:Msg(self.L["Not in a group — nothing to broadcast."])
        return
    end
    self:Send("vCheck", nil, { ver = self:GetVersion() }, channel)
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
    if IsMe(sender) then return end
    self:RecordVersion(sender, msg.ver)
    self:Send("vReply", nil, { ver = self:GetVersion() }, "WHISPER", sender)
end

-- A private reply to our vCheck: record only — do not reply, or the two clients would
-- bounce vReplies forever.
LCEX.dispatch.vReply = function(self, msg, sender)
    if IsMe(sender) then return end
    self:RecordVersion(sender, msg.ver)
end
