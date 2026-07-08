-- ── LootCouncil EX — council/Sync.lua ────────────────────────────────────────
-- Plane B: the persistent-council sync engine (PROJECT.md §3 / §6.2). Replicates per-dataset
-- records among the council over the GUILD channel, eventually-consistent, last-write-wins by
-- per-record `mod` timestamp (ties broken by `by` alphabetically); immutable datasets merge by
-- union of keys. No single authority — any council member may write.
--
-- Datasets are pluggable: each registers a store accessor + a merge mode. Phase 4 ships only a
-- "dummy" dataset to PROVE the transport; the real datasets (notes/marks/history/caches)
-- register in Phase 5 and ride this unchanged.
--
-- Flow (§6.2): on login broadcast pHello (our per-dataset digest). A peer that's behind sends
-- pSyncReq(since); we answer pSyncData with the delta. If we're AHEAD of a peer's hello, we
-- hello back (WHISPER) so a freshly-logged-in peer hears from those already online. Live edits
-- propagate immediately via pSet. All sync traffic is gated to council senders, both ways.
--
-- Loads after Session.lua (ResolveCouncil) and Comms.lua (dispatch table).

local LCEX = LootCouncilEX
LCEX.dispatch  = LCEX.dispatch  or {}
LCEX.datasets  = LCEX.datasets  or {}

-- Guild-roster refresh nudge — GuildRoster is removed on Anniversary; C_GuildInfo has it
-- (same shim as Session.lua).
local RequestGuildRoster = GuildRoster or (C_GuildInfo and C_GuildInfo.GuildRoster)

-- ── Council membership (Plane B) ─────────────────────────────────────────────
-- Plane-B council set, cached and rebuilt lazily (invalidated on guild-roster change / council
-- edit). Unlike the Plane-A session council it does NOT force-add self: you sync only if you
-- are actually configured as council.
function LCEX:CouncilSet()
    if not self._councilSet then
        self._councilSet = self:ResolveCouncil(false)
    end
    return self._councilSet
end

function LCEX:AmCouncil()
    return self:CouncilSet()[self:NormalizeName(UnitName("player"))] == true
end

function LCEX:SyncSenderOk(sender)
    local n = self:NormalizeName(sender)
    return n ~= nil and self:CouncilSet()[n] == true
end

function LCEX:OnGuildRosterUpdate()
    self._councilSet = nil    -- roster changed; recompute on next use
    self:SyncGuildScope()     -- the guild name may now be known (or have changed) — re-scope datasets
end

-- ── Dataset registry + merge primitives ──────────────────────────────────────
-- store() returns the dataset's SavedVariables table (key -> record). mode is "lww" (records
-- carry mod/by; greatest mod wins) or "union" (immutable; keep any key we don't have).
function LCEX:RegisterDataset(name, mode, store)
    self.datasets[name] = { name = name, mode = mode or "lww", store = store }
end

-- Order-independent content hash of a (key, mod) pair — pure Lua 5.1, no bit ops. A rolling
-- polynomial over the key's bytes folded with the record's mod, mod 2^31-1. Intermediates stay
-- < 2^38 (p < 2^31, *131 < 2^38), safe in a double. Summed commutatively across the dataset so
-- `pairs` order is irrelevant and two peers derive the SAME digest hash from the SAME records.
local HASH_M = 2147483647 -- 2^31 - 1
local function pairHash(key, mod)
    local p = 0
    for i = 1, #key do p = (p * 131 + key:byte(i)) % HASH_M end
    return (p * 31 + (mod % HASH_M)) % HASH_M
end

-- {n, maxMod, h}. `h` is the content hash (DL-10): it distinguishes two stores with the same count
-- and same newest-mod but DIFFERENT records (disjoint keys, or a stale LWW loss in the middle) —
-- which n+maxMod alone cannot. Old peers omit `h`; the compare nil-guards it.
local function digestOf(ds)
    local n, maxMod, h = 0, 0, 0
    for k, rec in pairs(ds.store()) do
        n = n + 1
        local m = rec.mod or 0
        if m > maxMod then maxMod = m end
        h = (h + pairHash(tostring(k), m)) % HASH_M
    end
    return { n = n, maxMod = maxMod, h = h }
end

-- Records strictly newer than `since` (lww), or all records (union — `since` is meaningless for
-- an immutable set, the receiver unions by key).
local function deltaSince(ds, since)
    local out = {}
    for k, rec in pairs(ds.store()) do
        if ds.mode == "union" or (rec.mod or 0) > since then
            out[k] = rec
        end
    end
    return out
end

-- Merge incoming records into the store; returns how many keys actually changed AND a
-- {key→record} map of just those that landed (nil if none) — the second value drives the gbank
-- sync-notification prints. Existing callers read only the count (`> 0`), so it's additive.
local function mergeRecords(ds, records)
    local store = ds.store()
    local changed, changedRecs = 0, nil
    for k, inc in pairs(records) do
        local cur = store[k]
        local take
        if ds.mode == "union" then
            take = (cur == nil)
        else
            local im, cm = inc.mod or 0, (cur and cur.mod) or 0
            take = (not cur) or im > cm or (im == cm and tostring(inc.by) < tostring(cur and cur.by))
        end
        if take then
            store[k] = inc
            changed = changed + 1
            changedRecs = changedRecs or {}
            changedRecs[k] = inc
        end
    end
    return changed, changedRecs
end

-- Copper → a coin string (client coin icons in-game, plain g/s/c under the headless harness).
local function coinText(copper)
    copper = copper or 0
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return string.format("%dg %ds %dc",
        math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100)
end

-- Chat-surface the officer-relevant events a gbank sync just delivered (B1, §6.12): GOLD
-- withdrawals from gbankLog and new annotations from gbankNotes. Item withdrawals (raiders pulling
-- mats) and deposits/moves/repairs stay silent — only gold moves and notes warrant a line. Capped
-- so a big first-sync can't spam the frame. `changedRecs` is mergeRecords' second return.
local GBANK_PRINT_CAP = 3
local function announceGbankSync(self, dataset, changedRecs, sender)
    if not changedRecs then return end
    local lines = {}
    if dataset == "gbankLog" then
        for _, rec in pairs(changedRecs) do
            if rec.kind == "withdraw" and rec.gold and rec.gold > 0 then
                lines[#lines + 1] = string.format(self.L["Gbank: %s withdrew %s (synced from %s)."],
                    rec.player or "?", coinText(rec.gold), sender)
            end
        end
    elseif dataset == "gbankNotes" then
        for _, rec in pairs(changedRecs) do
            lines[#lines + 1] = string.format(self.L["Gbank: %s annotated a transaction."],
                rec.by or sender)
        end
    end
    for i = 1, math.min(#lines, GBANK_PRINT_CAP) do self:Msg(lines[i]) end
    if #lines > GBANK_PRINT_CAP then
        self:Msg(string.format(self.L["  …and %d more."], #lines - GBANK_PRINT_CAP))
    end
end

-- ── Local write API ──────────────────────────────────────────────────────────
-- Set a record locally (stamping mod=now, by=us, so LWW makes our write win) and broadcast it
-- to the council as pSet. The transport for Plane B is the sync channel (GUILD by default).
function LCEX:SetRecord(dataset, key, payload)
    local ds = self.datasets[dataset]
    if not ds then return end
    local rec = {}
    for k, v in pairs(payload or {}) do rec[k] = v end
    rec.mod = time()
    rec.by = UnitName("player")
    ds.store()[key] = rec

    local channel = self.db.profile.syncChannel or "GUILD"
    if channel ~= "GUILD" or IsInGuild() then
        self:Debug("send pSet %s[%s] via %s", dataset, tostring(key), channel)
        self:Send("pSet", nil, { dataset = dataset, key = key, record = rec }, channel)
    else
        self:Debug("pSet NOT sent: syncChannel is GUILD but you're not in a guild")
    end
end

-- Merge ONE record into a dataset locally, WITHOUT broadcasting and WITHOUT re-stamping
-- mod/by — for records that arrived another way: an `award` everyone present already heard, or
-- a peer's `pReport` gear we cache verbatim. The CALLER supplies the right mod/by. Reuses the
-- mode-aware merge (union: keep-if-absent; lww: greater mod, tie by `by`). Returns true if the
-- store changed.
function LCEX:MergeRecord(dataset, key, record)
    local ds = self.datasets[dataset]
    if not ds or key == nil or type(record) ~= "table" then return false end
    return mergeRecords(ds, { [key] = record }) > 0
end

-- ── Hello (digest broadcast) ─────────────────────────────────────────────────
function LCEX:BuildDigest()
    self:SyncGuildScope() -- ensure the flat datasets reflect the current guild before we sync (C6)
    local digest = {}
    for name, ds in pairs(self.datasets) do
        digest[name] = digestOf(ds)
    end
    return digest
end

-- Broadcast our per-dataset digest so behind peers pull from us. Council-only; GUILD requires a
-- guild. (§6.2: "on login/load broadcast pHello".)
function LCEX:SyncHello()
    if not self:AmCouncil() then return end
    local channel = self.db.profile.syncChannel or "GUILD"
    if channel == "GUILD" and not IsInGuild() then return end
    self:Send("pHello", nil, { digest = self:BuildDigest() }, channel)
end

function LCEX:SetupSync()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    if RequestGuildRoster then RequestGuildRoster() end
    self:ScheduleTimer("SyncHello", 6) -- announce once the guild roster has settled after login
end

-- ── Dispatch handlers (all gated: ignore self-echo + non-council either direction) ──────────
local function syncGateBad(self, sender)
    if self:IsSelf(sender) then return true end -- our own echo (silent)
    if not self:AmCouncil() then
        self:Debug("sync drop: I am not council (check /lcex council)")
        return true
    end
    if not self:SyncSenderOk(sender) then
        self:Debug("sync drop: %s is not in MY council list", tostring(sender))
        return true
    end
    return false
end

-- A peer advertised its digest. For each dataset, pull a delta if they have more; and if WE
-- have more than them, hello back so they pull (covers the just-logged-in peer). `reply` marks
-- a hello-back so it can't recurse.
LCEX.dispatch.pHello = function(self, msg, sender)
    if syncGateBad(self, sender) or type(msg.digest) ~= "table" then return end
    local iAmAhead = false
    for name, ds in pairs(self.datasets) do
        local theirs = msg.digest[name]
        local mine = digestOf(ds)
        if theirs then
            -- Pull from the sender only when THEY have more: a newer record (greater maxMod), or
            -- a higher record count (they hold keys we lack → request the full set, since=0). This
            -- is directional, so being ahead never triggers a wasteful backwards pull. (Works for
            -- both modes: union records carry no mod, so maxMod is 0 both sides and `n` drives it.)
            -- Same count AND same newest-mod but a different content hash ⇒ the two stores hold
            -- DISJOINT keys (each wrote a record while apart). Neither is "ahead", so both must pull
            -- the full set (since=0) AND hello back, so each side gets the other's keys and LWW
            -- converges. Only fires when both peers speak the hash (nil-guarded for old clients).
            local hashDiverged = theirs.h ~= nil and mine.h ~= nil
                and (theirs.n or 0) == (mine.n or 0)
                and (theirs.maxMod or 0) == (mine.maxMod or 0)
                and theirs.h ~= mine.h
            local needDelta, since = false, (mine.maxMod or 0)
            if (theirs.maxMod or 0) > (mine.maxMod or 0) then
                needDelta = true
            elseif (theirs.n or 0) > (mine.n or 0) then
                needDelta, since = true, 0 -- count mismatch in their favor (DL-10)
            elseif hashDiverged then
                needDelta, since = true, 0 -- disjoint keys at equal n+maxMod (DL-10)
            end
            if needDelta then
                self:Send("pSyncReq", nil, { dataset = name, since = since }, "WHISPER", sender)
            end
            -- We're ahead if we hold a newer record or a higher count — hello back so they pull. A
            -- pure hash divergence has no ahead side, so both peers hello back (see above).
            if (mine.maxMod or 0) > (theirs.maxMod or 0) or (mine.n or 0) > (theirs.n or 0)
                or hashDiverged then
                iAmAhead = true
            end
        elseif (mine.n or 0) > 0 then
            iAmAhead = true
        end
    end
    if iAmAhead and not msg.reply then
        self:Send("pHello", nil, { digest = self:BuildDigest(), reply = true }, "WHISPER", sender)
    end
end

-- A peer asked for a delta of one dataset.
LCEX.dispatch.pSyncReq = function(self, msg, sender)
    if syncGateBad(self, sender) then return end
    local ds = self.datasets[msg.dataset]
    if not ds then return end
    local records = deltaSince(ds, msg.since or 0)
    if next(records) then
        self:Send("pSyncData", nil, { dataset = msg.dataset, records = records }, "WHISPER", sender)
    end
end

-- A peer sent us a delta — merge it. On first load a `config` record is HELD for the inherit prompt
-- (Feature C) rather than auto-merged; the gate drops it from the batch and asks instead.
LCEX.dispatch.pSyncData = function(self, msg, sender)
    if syncGateBad(self, sender) then return end
    local ds = self.datasets[msg.dataset]
    if not ds or type(msg.records) ~= "table" then return end
    local records = msg.records
    if msg.dataset == "config" then
        records = {}
        for k, rec in pairs(msg.records) do
            if not self:GateConfigInherit(k, rec, sender) then records[k] = rec end
        end
    end
    local changed, changedRecs = mergeRecords(ds, records)
    if changed > 0 then
        self:Msg(string.format(self.L["Synced %d %s record(s) from %s."], changed, msg.dataset, sender))
        announceGbankSync(self, msg.dataset, changedRecs, sender)
    end
end

-- A live edit from a council member — merge it (LWW protects against a stale overwrite). A first-load
-- `config` record is held for the inherit prompt instead of auto-merging (Feature C).
LCEX.dispatch.pSet = function(self, msg, sender)
    if syncGateBad(self, sender) then return end
    local ds = self.datasets[msg.dataset]
    if not ds or msg.key == nil or type(msg.record) ~= "table" then return end
    if msg.dataset == "config" and self:GateConfigInherit(msg.key, msg.record, sender) then return end
    local n, changedRecs = mergeRecords(ds, { [msg.key] = msg.record })
    if n > 0 then
        self:Msg(string.format(self.L["%s updated %s[%s]."], sender, msg.dataset, tostring(msg.key)))
        announceGbankSync(self, msg.dataset, changedRecs, sender)
    end
end

-- ── Phase-4 proof dataset + test commands ────────────────────────────────────
-- A throwaway LWW dataset used only to prove the transport (see /lcex dummy, /lcex sync). The
-- real datasets register in Phase 5; the engine above doesn't change.
LCEX:RegisterDataset("dummy", "lww", function() return LCEX.db.global.dummy end)

-- /lcex sync — manually rebroadcast our digest.
function LCEX:CmdSync()
    self:SyncHello()
    self:Msg(self.L["Sync digest broadcast."])
end

-- /lcex dummy [<key> <text>] — set a dummy record (and sync it), or dump the dataset.
function LCEX:CmdDummy(rest)
    rest = strtrim(rest or "")
    local key, text = rest:match("^(%S+)%s+(.+)$")
    if key and text then
        self:SetRecord("dummy", key, { text = text })
        self:Msg(string.format(self.L["dummy[%s] = %s"], key, text))
        return
    end
    local store = self.db.global.dummy or {}
    local keys = {}
    for k in pairs(store) do keys[#keys + 1] = k end
    table.sort(keys)
    self:Msg(string.format(self.L["dummy dataset — %d record(s):"], #keys))
    for _, k in ipairs(keys) do
        local r = store[k]
        self:Msg(string.format(self.L["  %s = %s  (mod %s, by %s)"],
            k, tostring(r.text), tostring(r.mod), tostring(r.by)))
    end
end

-- /lcex council [add|remove <name>] — show or edit the council's `extra` list. Writes go to the
-- SHARED, replicated config (Feature C) via SetCouncilConfig, reading the current effective list.
function LCEX:CmdCouncil(rest)
    rest = strtrim(rest or "")
    local action, name = rest:match("^(%S+)%s+(.+)$")
    if action == "add" and name then
        name = strtrim(name)
        local extra = {}
        for _, n in ipairs(self:CouncilConfig().extra or {}) do extra[#extra + 1] = n end
        extra[#extra + 1] = name
        self:SetCouncilConfig({ extra = extra })
        self:Msg(string.format(self.L["Added %s to the council."], name))
    elseif action == "remove" and name then
        local target = self:NormalizeName(strtrim(name))
        local extra = {}
        for _, n in ipairs(self:CouncilConfig().extra or {}) do
            if self:NormalizeName(n) ~= target then extra[#extra + 1] = n end
        end
        self:SetCouncilConfig({ extra = extra })
        self:Msg(string.format(self.L["Removed %s from the council."], strtrim(name)))
    else
        local names = {}
        for n in pairs(self:ResolveCouncil(false)) do names[#names + 1] = n end
        table.sort(names)
        self:Msg(string.format(self.L["Council — %d member(s) (you: %s):"],
            #names, self:AmCouncil() and self.L["member"] or self.L["not a member"]))
        for _, n in ipairs(names) do
            self:Msg(string.format(self.L["  %s"], n))
        end
    end
end
