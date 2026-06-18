-- ── LootCouncil EX — council/SelfReport.lua ──────────────────────────────────
-- Plane B: each player self-reports their own gear + professions over comms — Blizzard
-- inspection is range/faction/throttle-limited and useless here (§2 / DL-4). We broadcast a
-- `pReport` (gear + profs) on login and on equipment change; everyone in the group caches it
-- into gearCache/profCache, which then reconcile among council via the sync engine so an
-- out-of-raid council member still gets the last-cached gear.
--
-- CRITICAL gating asymmetry (§6.2): `pReport` is accepted from ANY GROUP MEMBER (so the
-- council can view any candidate), NOT council-only — so its inbound handler uses InGroupWith,
-- NOT syncGateBad. The gearCache/profCache DATASETS still sync council-only via the engine.
--
-- Anti-swap (§6.7): freeze the gear snapshot at combat start so a pre-pull stat-swap can't
-- change what the council sees; ignore mid-combat equipment changes.
--
-- Loads after Sync.lua (RegisterDataset/MergeRecord) and Session.lua (InGroupWith).

local LCEX = LootCouncilEX
LCEX.dispatch = LCEX.dispatch or {}

-- The caches sync among council like any lww dataset.
LCEX:RegisterDataset("gearCache", "lww", function() return LCEX.db.global.gearCache end)
LCEX:RegisterDataset("profCache", "lww", function() return LCEX.db.global.profCache end)

-- Primary + secondary professions (enUS). The skill-line scan returns weapon/class/language
-- skills too, so we filter to these by name. (enUS-only for now, consistent with the addon's
-- locale stance; localize alongside L[] later.)
local PROFESSIONS = {
    Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true,
    Herbalism = true, Jewelcrafting = true, Leatherworking = true, Mining = true,
    Skinning = true, Tailoring = true, Cooking = true, ["First Aid"] = true, Fishing = true,
}

-- ── Snapshots ────────────────────────────────────────────────────────────────
-- Equipped items by inventory slot (1..18: head…ranged; skips ammo/shirt-cosmetic tabard).
function LCEX:SnapshotGear()
    local gear = {}
    for slot = 1, 18 do
        local link = GetInventoryItemLink("player", slot)
        if link then gear[slot] = link end
    end
    return gear
end

-- Professions → rank. Scans the skill lines (§6.7); a profession under a COLLAPSED skill
-- header won't enumerate — acceptable for v1 (re-sent on equip change / login), refine later.
function LCEX:SnapshotProfs()
    local profs = {}
    for i = 1, (GetNumSkillLines() or 0) do
        local name, isHeader, _, rank = GetSkillLineInfo(i)
        if name and not isHeader and PROFESSIONS[name] and rank and rank > 0 then
            profs[name] = rank
        end
    end
    return profs
end

-- ── Broadcast ────────────────────────────────────────────────────────────────
-- Send our gear (the frozen anti-swap snapshot) + professions. Honors the selfReport opt-out
-- and the GUILD-requires-guild guard. Returns true if actually sent.
function LCEX:SendSelfReport()
    if not self.db.profile.selfReport then return false end
    local channel = self.db.profile.syncChannel or "GUILD"
    if channel == "GUILD" and not IsInGuild() then
        self:Debug("pReport NOT sent: syncChannel is GUILD but you're not in a guild")
        return false
    end
    self:Send("pReport", nil, {
        gear  = self.lastGearSnapshot or self:SnapshotGear(),
        profs = self:SnapshotProfs(),
        mod   = time(),
    }, channel)
    self:Debug("sent pReport via %s", channel)
    return true
end

-- ── Event wiring ─────────────────────────────────────────────────────────────
function LCEX:SetupSelfReport()
    self.lastGearSnapshot = self:SnapshotGear()
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStartSnapshot")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "OnEquipmentChanged")
    self:ScheduleTimer("SendSelfReport", 6) -- announce once roster/equipment settle after login
end

-- Combat start: freeze the gear we entered combat with (defeats a pre-pull swap, §6.7).
function LCEX:OnCombatStartSnapshot()
    self.lastGearSnapshot = self:SnapshotGear()
end

-- Out-of-combat gear change: refresh the snapshot and (debounced) re-report. Mid-combat swaps
-- are ignored so they can't change the council's view.
function LCEX:OnEquipmentChanged()
    if UnitAffectingCombat("player") then return end
    self.lastGearSnapshot = self:SnapshotGear()
    self:DebouncedSend("pReport", function() self:SendSelfReport() end)
end

-- ── Inbound: cache a peer's report (ANY group member, NOT council — §6.2) ────
LCEX.dispatch.pReport = function(self, msg, sender)
    if self:IsSelf(sender) then return end
    if not self:InGroupWith(sender) then return end -- the deliberate non-council gate
    local key = self:NormalizeName(sender)
    if not key then return end
    local mod = tonumber(msg.mod) or time()
    if type(msg.gear) == "table" then
        self:MergeRecord("gearCache", key, { items = msg.gear, mod = mod, by = sender })
    end
    if type(msg.profs) == "table" then
        self:MergeRecord("profCache", key, { profs = msg.profs, mod = mod, by = sender })
    end
    self:Debug("cached pReport from %s", sender)
end

-- /lcex report — refresh + rebroadcast our own gear/professions now.
function LCEX:CmdReport()
    self.lastGearSnapshot = self:SnapshotGear()
    if self:SendSelfReport() then
        self:Msg(self.L["Self-report broadcast."])
    else
        self:Msg(self.L["Self-report not sent (disabled, or not in a guild)."])
    end
end

-- /lcex gear [player] — dump a CACHED gear/profession report for a player (a live snapshot of
-- our own if no name). Headless inspector for the caches; Phase 6 builds the real PlayerDetail.
function LCEX:CmdGear(rest)
    rest = strtrim(rest or "")
    local who, gear, profs, note
    if rest == "" then
        who, gear, profs, note = UnitName("player"), self:SnapshotGear(), self:SnapshotProfs(),
            self.L["(your live snapshot)"]
    else
        who = rest
        local key = self:NormalizeName(rest)
        local g = key and self.db.global.gearCache[key]
        local p = key and self.db.global.profCache[key]
        gear, profs = (g and g.items) or {}, (p and p.profs) or {}
        note = (g or p) and "" or self.L["(no cached report)"]
    end

    self:Msg(string.format(self.L["Gear/profs — %s %s"], who, note))
    local slots = {}
    for slot in pairs(gear) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        self:Msg(string.format(self.L["  slot %d: %s"], slot, tostring(gear[slot])))
    end
    local names = {}
    for name in pairs(profs) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        self:Msg(string.format(self.L["  %s: %d"], name, profs[name]))
    end
end
