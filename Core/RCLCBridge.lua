-- ── LootCouncil EX — Core/RCLCBridge.lua ─────────────────────────────────────
-- The stateful glue of the RCLC compatibility bridge (PROJECT.md §6.18, DL-24). It carries the
-- LCEX ML's live session out to RCLootCouncil-only raiders over RCLC's own AceComm prefix, and
-- funnels their responses back into the native session table. Pure shape/codec work lives in
-- Core/RCLCWire.lua; this file is comms + session hooks only.
--
-- Direction is ONE-WAY (candidates only): LCEX is always the ML here and never acts as an RCLC
-- candidate. Every path is inert unless `profile.rclcBridge` is on, LibDeflate is present, and we
-- are actually in a group — so the headless harness (no LibDeflate) and solo play never emit RCLC
-- traffic or warnings.
--
-- Loads after Session/Award/Candidate/Council + RCLCWire — it references their functions at
-- runtime (session start/award/end hooks, the native cResp injection point in commit 4).

local LCEX = LootCouncilEX

local RCLC_PREFIX = "RCLC"

-- The bridge is live only when: the toggle is on, LibDeflate loaded (RCLCReady), and we have a
-- group channel to reach RCLC raiders on. Headless (no LibDeflate) and solo both fail this, so
-- every hook below no-ops there without a separate guard.
function LCEX:RCLCActive()
    if not (self.db and self.db.profile.rclcBridge) then return false end
    if not self:RCLCReady() then return false end
    return self:GroupChannel() ~= nil
end

-- ── Send helpers (encode on the RCLC prefix) ─────────────────────────────────
-- Both no-op if the toggle is off or LibDeflate is missing (RCLCEncode returns nil). Broadcast
-- goes to the group; whisper answers a single requester (reconnect/MLdb_request/council_request).
local function rclcSend(self, channel, target, command, ...)
    if not (self.db and self.db.profile.rclcBridge) or not channel then return end
    local encoded = self:RCLCEncode(command, ...)
    if encoded then self:SendCommMessage(RCLC_PREFIX, encoded, channel, target) end
end

function LCEX:RCLCBroadcast(command, ...)
    rclcSend(self, self:GroupChannel(), nil, command, ...)
end

function LCEX:RCLCWhisper(target, command, ...)
    rclcSend(self, "WHISPER", target, command, ...)
end

-- RCLC council set = { [guidNoPrefix] = true }. Candidates-only: we advertise just the ML's own
-- GUID so RCLC treats us as the loot authority; RCLC raiders stay plain candidates (no voting).
function LCEX:RCLCCouncilSet()
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) ~= "string" then return {} end
    return { [(guid:gsub("^Player%-", ""))] = true }
end

-- The RCLC mldb for the live session's response set + poll deadline. One builder, reused by the
-- session-start broadcast and the on-demand request answers, so RCLC raiders always see the same
-- (LCEX) buttons — and inherit DL-8 user-configurable responses automatically once those land.
function LCEX:RCLCMLDB()
    return self:RCLC_BuildMLDB(self:ResponseSet(), self.db and self.db.profile.pollTimeout)
end

-- ── Outbound session hooks (called from Session.lua / Award.lua) ─────────────
-- Session opened/resumed: warn if we can't be RCLC's ML, then send the start set IN ORDER —
-- StartHandleLoot, mldb (must precede lootTable or candidates defer the frame), council, then
-- lootTable. Owner on each item = the ML (loot sits in ML bags, DL-7).
function LCEX:BridgeSessionStart()
    if not self:RCLCActive() or not self.session then return end
    self:RCLCLeaderWarn()
    self:RCLCBroadcast("StartHandleLoot")
    self:RCLCBroadcast("mldb", self:RCLCMLDB())
    self:RCLCBroadcast("council", self:RCLCCouncilSet())
    self:RCLCBroadcast("lootTable",
        self:RCLC_BuildLootTable(self.session.items, UnitName("player"), self.sessionItems))
end

-- An item was awarded: tell RCLC clients so their frames advance / TradeUI arms. session == the
-- LCEX item index (== the lootTable session), owner == the ML (the item's holder/trader).
function LCEX:BridgeAward(itemIndex, winner)
    if not self:RCLCActive() then return end
    self:RCLCBroadcast("awarded", itemIndex, winner, UnitName("player"))
end

-- Session ended: close any still-open RCLC loot frames.
function LCEX:BridgeSessionEnd()
    if not self:RCLCActive() then return end
    self:RCLCBroadcast("session_end")
end

-- RCLC only accepts our ML traffic if we are the sender its GetML() computes: the Blizzard ML
-- under master loot, else the raid/group leader. Anniversary has no master-loot API, so unless we
-- hold lead (or master loot is somehow set) RCLC raiders silently ignore the session. Warn once
-- at start so the ML can pass lead to themselves.
function LCEX:RCLCLeaderWarn()
    local method = GetLootMethod and GetLootMethod()
    if method == "master" then return end
    if UnitIsGroupLeader and UnitIsGroupLeader("player") then return end
    self:Msg(self.L["RCLC compatibility: you're not the raid leader, so RCLootCouncil raiders can't see this session. Pass lead to yourself if any raiders use RCLC."])
end

-- ── Receive path (own prefix, own dispatch) ──────────────────────────────────
-- A SECOND AceComm registration routes RCLC-prefixed traffic here (Init.lua). It never shares
-- OnCommReceived: RCLC uses LibDeflate + a different envelope, so it needs its own decode. Inbound
-- is untrusted — gate on the toggle, drop our own echo, and pcall each handler.
LCEX.rclcDispatch = LCEX.rclcDispatch or {}

function LCEX:OnRCLCReceived(prefix, message, distribution, sender)
    if prefix ~= RCLC_PREFIX then return end
    if not (self.db and self.db.profile.rclcBridge) then return end
    if self:IsSelf(sender) then return end
    local command, args = self:RCLCDecode(message)
    if not command then return end
    local handler = self.rclcDispatch[command]
    if handler then
        local ok, err = pcall(handler, self, args or {}, sender, distribution)
        if not ok then self:Debug("RCLC handler '%s' error: %s", tostring(command), tostring(err)) end
    end
end

-- On-demand resends. RCLC candidates ask for mldb/council when they're missing, and re-request
-- the whole set after a /reload via `reconnect`. Answer only while a session is open, whispered to
-- the asker (idempotent — a group re-broadcast would also work, but a whisper is lighter).
LCEX.rclcDispatch.MLdb_request = function(self, _, sender)
    if not self.session then return end
    self:RCLCWhisper(sender, "mldb", self:RCLCMLDB())
end

LCEX.rclcDispatch.council_request = function(self, _, sender)
    if not self.session then return end
    self:RCLCWhisper(sender, "council", self:RCLCCouncilSet())
end

LCEX.rclcDispatch.reconnect = function(self, _, sender)
    if not self.session then return end
    self:RCLCWhisper(sender, "StartHandleLoot")
    self:RCLCWhisper(sender, "mldb", self:RCLCMLDB())
    self:RCLCWhisper(sender, "council", self:RCLCCouncilSet())
    self:RCLCWhisper(sender, "lootTable",
        self:RCLC_BuildLootTable(self.session.items, UnitName("player"), self.sessionItems))
end
