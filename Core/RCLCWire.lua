-- ── LootCouncil EX — Core/RCLCWire.lua ───────────────────────────────────────
-- Pure translation + codec for the RCLC compatibility bridge (PROJECT.md §6.18, DL-24). This
-- file has NO comms and NO session state: it only turns LCEX data into RCLootCouncil-shaped
-- tables (and back) and wraps RCLC's serialization pipeline. Core/RCLCBridge.lua is the stateful
-- glue that calls these; splitting them keeps the shape logic headless-testable.
--
-- Dialect (RCLootCouncil_Classic v1.4.x, verified against the vendored reference): AceComm prefix
-- "RCLC"; a message is `AceSerializer:Serialize(command, {args})` → `LibDeflate:CompressDeflate`
-- (level 3) → `EncodeForWoWAddonChannel`. Decode reverses it back to `(command, argsArray)`.
--
-- Loads after Comms.lua (uses the AceSerializer mixin `Serialize`/`Deserialize`). LibDeflate is
-- resolved lazily via LibStub so this file loads fine where the lib is absent (the headless
-- harness): the pure transforms never touch it; only the codec does, and it nil-guards.

local LCEX = LootCouncilEX

-- LibDeflate is embedded (embeds.xml) and registers with LibStub in-game. Resolve once, lazily,
-- and cache. `false` = "looked, not present" (headless) so the codec no-ops instead of erroring.
local LibDeflate
local function deflate()
    if LibDeflate == nil then
        LibDeflate = (LibStub and LibStub("LibDeflate")) or false
    end
    return LibDeflate or nil
end

-- True once LibDeflate is available (in-game). The bridge gates its whole outbound path on this,
-- so the headless harness (no LibDeflate) and any build missing the lib stay completely inert.
function LCEX:RCLCReady()
    return deflate() ~= nil
end

-- The item string from a hyperlink, minus the "item:" prefix (what RCLC puts on the wire, e.g.
-- "40395:0:0:0:0:0:0:::::"). The candidate rebuilds "item:"..string and GetItemInfo's it.
local function itemString(link)
    if type(link) ~= "string" then return nil end
    return link:match("|?H?item:([%-%d:]+)")
end

-- The numbered response buttons RCLC should show = the LCEX response set MINUS the built-in PASS
-- (RCLC's loot frame always renders its own Pass, which comes back as the "PASS" code). Kept as
-- the single source both the mldb builder and the inbound mapper read, so button index N always
-- means the same LCEX response on both sides.
local function numberedResponses(responses)
    local out = {}
    for _, r in ipairs(responses or {}) do
        if r.key ~= "PASS" then out[#out + 1] = r end
    end
    return out
end

-- ── Pure transforms (headless-tested) ────────────────────────────────────────

-- Build RCLC's `mldb` (master-looter DB) from a live LCEX response set, so RCLC raiders see
-- LCEX's own buttons/colors. Plain key names are legal on the wire — RCLC's RestoreFromTransmit
-- only swaps its magic keys and passes the rest through. `numButtons` is sent both at the top
-- level (legacy) and inside buttons.default (where RCLC actually reads it). Colors gain alpha=1.
-- `timeoutSecs` is the poll deadline; RCLC frames always count down, so 0/nil ⇒ a long default
-- (a timed-out RCLC raider then just reads as a native non-responder).
function LCEX:RCLC_BuildMLDB(responses, timeoutSecs)
    responses = responses or self.RESPONSES
    local buttons = numberedResponses(responses)
    local bdef = { numButtons = #buttons }
    local rdef = {}
    for i, r in ipairs(buttons) do
        bdef[i] = { text = r.text, requireNotes = false }
        local c = r.color or { 1, 1, 1 }
        rdef[i] = { text = r.text, color = { c[1], c[2], c[3], 1 }, sort = i }
    end
    local timeout = (type(timeoutSecs) == "number" and timeoutSecs > 0) and timeoutSecs or 300
    return {
        numButtons      = #buttons,
        timeout         = timeout,
        anonymousVoting = false,
        hideVotes       = false,
        buttons         = { default = bdef },
        responses       = { default = rdef },
    }
end

-- Build RCLC's `lootTable` from the session's wire items. Array index == `session` == the LCEX
-- item index, so an inbound RCLC response (which echoes `session`) maps straight back to our row.
-- `owner` is the ML (loot sits in ML bags per DL-7, so the ML is the item's holder/trader).
-- `sessionItems` (optional, the ML-side full records) supplies `boss` when present.
function LCEX:RCLC_BuildLootTable(items, mlName, sessionItems)
    local out = {}
    for i, it in ipairs(items or {}) do
        local s = itemString(it.link)
        if s then
            out[i] = {
                string  = s,
                session = i,
                owner   = mlName,
                boss    = sessionItems and sessionItems[i] and sessionItems[i].boss or nil,
            }
        end
    end
    return out
end

-- Map an RCLC response code to an LCEX response id (nil = no row change). A numeric code is a
-- 1-based index into the numbered (non-PASS) buttons; "PASS" and a `true` autopass map to the
-- set's PASS id; every other code (TIMEOUT/DISABLED/NOTINRAID/…) leaves the row as-is.
function LCEX:RCLC_MapResponse(rclcResp, responses)
    responses = responses or self.RESPONSES
    if type(rclcResp) == "number" then
        local r = numberedResponses(responses)[rclcResp]
        return r and r.id or nil
    end
    if rclcResp == "PASS" or rclcResp == true then
        for _, r in ipairs(responses) do
            if r.key == "PASS" then return r.id end
        end
    end
    return nil
end

-- RCLC gear1/gear2 are cleaned item strings (no "item:"); rebuild them into links for the LCEX
-- candidate row's competing-gear icons. Returns a 0-, 1-, or 2-element array (nils dropped).
function LCEX:RCLC_GearLinks(gear1, gear2)
    local out = {}
    if type(gear1) == "string" and gear1 ~= "" then out[#out + 1] = "item:" .. gear1 end
    if type(gear2) == "string" and gear2 ~= "" then out[#out + 1] = "item:" .. gear2 end
    return out
end

-- ── Codec (real AceSerializer + LibDeflate; selftest-verified in-game) ────────
-- The harness identity-mocks Serialize/Deserialize and has no LibDeflate, so these no-op there;
-- the round-trip is exercised by /lcex selftest and by a raw-LibDeflate headless test.

-- Encode one RCLC message: command string + its varargs (packed into an array, RCLC's shape).
-- Returns the channel-safe string, or nil if LibDeflate is unavailable.
function LCEX:RCLCEncode(command, ...)
    local lib = deflate()
    if not lib then return nil end
    local serialized = self:Serialize(command, { ... })
    local compressed = lib:CompressDeflate(serialized, { level = 3 })
    return lib:EncodeForWoWAddonChannel(compressed)
end

-- Decode an RCLC message back to `(command, argsArray)`, or nil on any failure (untrusted input).
function LCEX:RCLCDecode(encoded)
    local lib = deflate()
    if not lib or type(encoded) ~= "string" then return nil end
    local decoded = lib:DecodeForWoWAddonChannel(encoded)
    if not decoded then return nil end
    local decompressed = lib:DecompressDeflate(decoded)
    if not decompressed then return nil end
    local ok, command, args = self:Deserialize(decompressed)
    if not ok or type(command) ~= "string" then return nil end
    return command, args
end
