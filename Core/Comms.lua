-- ── LootCouncil EX — Comms.lua ───────────────────────────────────────────────
-- The networking spine. Everything goes through AceComm (never raw SendAddonMessage).
--
-- Wire format (PROJECT.md §4/§6): one AceSerializer-encoded table per message,
--     { v = PROTOCOL_VERSION, cmd = <string>, sid = <session id|nil>, <payload…> }
-- `v`/`cmd`/`sid` are reserved envelope keys; payload fields are flattened in alongside
-- them, so payloads must not reuse those names (none do). `cmd` selects a handler from
-- the dispatch table; feature modules (e.g. Roster) register their handlers into it.
--
-- Loads after Init.lua and before Roster.lua: it creates LCEX.dispatch, which Roster
-- then populates.

local LCEX = LootCouncilEX

local COMM_PREFIX = "LCEX"
local COALESCE = 0.2 -- seconds to coalesce repeated broadcasts of the same key

-- cmd -> function(self, msg, sender, distribution). Created here, filled by features.
LCEX.dispatch = LCEX.dispatch or {}

-- ── Output ───────────────────────────────────────────────────────────────────
-- Single user-facing print path so every line shares the "LootCouncil EX:" brand and
-- matches the acceptance-test wording exactly. (AceConsole :Print would emit a
-- bracketed prefix in the wrong format.) Callers pass text already run through L.
local PREFIX = "|cff66ccffLootCouncil EX:|r "
function LCEX:Msg(text)
    print(PREFIX .. tostring(text))
end

-- ── Send path ──────────────────────────────────────────────────────────────--
-- Build the flat envelope for a command + optional session id + payload table.
function LCEX:BuildEnvelope(cmd, sid, payload)
    -- `ver` (the human-facing addon version) rides on EVERY envelope so peers learn each
    -- other's version from any traffic, not only the explicit vCheck/vReply handshake.
    local msg = { v = self.PROTOCOL_VERSION, cmd = cmd, sid = sid, ver = self:GetVersion() }
    if payload then
        for k, val in pairs(payload) do
            msg[k] = val
        end
    end
    return msg
end

-- Serialize and dispatch one message. `target` is the unit name for WHISPER, nil for
-- the group channels (RAID/PARTY/INSTANCE_CHAT) and GUILD.
function LCEX:Send(cmd, sid, payload, distribution, target)
    local wire = self:Serialize(self:BuildEnvelope(cmd, sid, payload))
    self:SendCommMessage(COMM_PREFIX, wire, distribution, target)
end

-- The correct group channel for a RAID-class broadcast given current group state.
-- Spec lists vCheck as RAID; we generalise so a plain party or a 5-man instance group
-- also round-trips during testing. Returns nil when solo (caller should no-op).
function LCEX:GroupChannel()
    if IsInRaid() then
        return "RAID"
    elseif LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

-- ── Sender identity ──────────────────────────────────────────────────────────
-- Canonical comparison form for a character name: strip a "-Realm" suffix and a trailing
-- cross-realm "(*)" marker, then lowercase. Roster/comms APIs hand back names in mixed
-- forms ("Name", "Name-Realm", occasionally decorated), so comparing raw strings silently
-- false-rejects the same player. Route ALL name-equality checks through this.
function LCEX:NormalizeName(name)
    if type(name) ~= "string" or name == "" then return nil end
    name = name:gsub("%s*%(%*%)$", "")    -- trailing cross-realm "(*)" marker
    name = name:match("^[^%-]+") or name   -- drop "-Realm"
    return name:lower()
end

-- True if `name` is the local player. AceComm echoes our own RAID/PARTY broadcasts back to
-- us (and Ambiguates same-realm senders to a bare name), so handlers use this to skip self.
function LCEX:IsSelf(name)
    local n = self:NormalizeName(name)
    return n ~= nil and n == self:NormalizeName(UnitName("player"))
end

-- ── Receive path ─────────────────────────────────────────────────────────────
-- AceComm default handler. Decodes, applies the protocol-version gate, routes to the
-- registered handler, then backfills the version roster. Silently drops anything malformed
-- or from a future protocol major — Phase 1 has no ACK (PROJECT.md DL-3).
function LCEX:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= COMM_PREFIX then return end

    local ok, msg = self:Deserialize(message)
    if not ok or type(msg) ~= "table" then return end
    if type(msg.v) ~= "number" or msg.v > self.PROTOCOL_VERSION then return end

    local handler = self.dispatch[msg.cmd]
    if handler then
        -- Network input is untrusted: a malformed payload that makes one handler throw must
        -- not take down AceComm's receive path for every later message. Isolate each dispatch.
        local okHandler, err = pcall(handler, self, msg, sender, distribution)
        if not okHandler then
            self:Msg(string.format("comms error in '%s': %s", tostring(msg.cmd), tostring(err)))
        end
    end

    -- Backfill the version roster from ANY envelope (every Send stamps `ver`). Silent: the
    -- explicit vCheck/vReply handshake is what announces; this just learns peers we haven't
    -- pinged. Runs after dispatch so the handshake's announce still fires on first contact.
    if msg.ver and not self:IsSelf(sender) then
        self:RecordVersion(sender, msg.ver, true)
    end
end

-- ── Debounced broadcast ────────────────────────────────────────────────────--
-- Coalesce repeated broadcast requests sharing `key`: each call cancels the pending
-- timer for that key and reschedules ~COALESCE seconds out, so a burst collapses into
-- one send. AceTimer accepts a closure here; we clear the slot before firing so the
-- next request schedules cleanly.
LCEX.pendingTimers = LCEX.pendingTimers or {}
function LCEX:DebouncedSend(key, fn)
    if self.pendingTimers[key] then
        self:CancelTimer(self.pendingTimers[key])
    end
    self.pendingTimers[key] = self:ScheduleTimer(function()
        self.pendingTimers[key] = nil
        fn()
    end, COALESCE)
end
