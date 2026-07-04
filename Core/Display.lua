-- ── LootCouncil EX — Core/Display.lua ────────────────────────────────────────
-- Pure display-array builders and resolvers shared by the UI: data in, typed row arrays out
-- (NO frames, NO comms). Relocated out of the frame modules so the UI layer can be replaced
-- without touching them; everything here is headless-tested in Tests/run.lua. The UI renders
-- these arrays through generic scroll lists, switching on each entry's `kind`.
--
-- Loads after the Data files and council datasets it reads (all resolved at call time).

local LCEX = LootCouncilEX

-- ── Loot browser display ─────────────────────────────────────────────────────
-- Flat display array for a phase: { {kind="raid",text}, {kind="boss",text}, {kind="item",itemID}, ... }
-- in raid (alpha) → boss (kill order) → item order.
function LCEX:BuildBrowserDisplay(phase)
    local out = {}
    for _, raid in ipairs(self:GetRaidsForPhase(phase)) do
        out[#out + 1] = { kind = "raid", text = raid }
        for _, boss in ipairs(self:GetBossesForRaid(phase, raid)) do
            out[#out + 1] = { kind = "boss", text = boss }
            for _, itemID in ipairs(self:GetItemsForBoss(phase, raid, boss)) do
                out[#out + 1] = { kind = "item", itemID = itemID }
            end
        end
    end
    return out
end

-- ── Player detail displays (gear / history / professions) ────────────────────
function LCEX:BuildGearDisplay(player)
    local key = self:NormalizeName(player)
    local rec = key and self.db.global.gearCache[key]
    local items = rec and rec.items
    if not items and self:IsSelf(player) then items = self:SnapshotGear() end -- live for self
    local out = {}
    if items then
        for slot = 1, 18 do
            if items[slot] then
                out[#out + 1] = { kind = "gearitem", slot = slot, link = items[slot],
                    issues = self:GearIssuesForItem(items[slot], slot) } -- Feature G tags
            end
        end
    end
    if #out == 0 then out[1] = { kind = "info", text = self.L["(no cached report)"] } end
    return out
end

function LCEX:BuildHistoryDisplay(player)
    local out = {}
    for _, rec in ipairs(self:HistoryForPlayer(self:NormalizeName(player))) do
        out[#out + 1] = { kind = "histitem", rec = rec }
    end
    if #out == 0 then out[1] = { kind = "info", text = self.L["No award history."] } end
    return out
end

function LCEX:BuildProfsDisplay(player)
    local key = self:NormalizeName(player)
    local rec = key and self.db.global.profCache[key]
    local profs = rec and rec.profs
    if not profs and self:IsSelf(player) then profs = self:SnapshotProfs() end
    local out, names = {}, {}
    if profs then for name in pairs(profs) do names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
        out[#out + 1] = { kind = "info", text = name .. ": " .. tostring(profs[name]) }
    end
    if #out == 0 then out[1] = { kind = "info", text = self.L["(no cached report)"] } end
    return out
end

-- ── Data-freshness text ──────────────────────────────────────────────────────
-- Coarse "how long ago" for a unixtime, bucketed just-now / Nm / Nh / Nd. Pure/testable.
function LCEX:RelTime(mod, now)
    if not mod then return self.L["unknown"] end
    local d = (now or time()) - mod
    if d < 0 then d = 0 end
    if d < 60 then return self.L["just now"] end
    if d < 3600 then return string.format(self.L["%dm ago"], math.floor(d / 60)) end
    if d < 86400 then return string.format(self.L["%dh ago"], math.floor(d / 3600)) end
    return string.format(self.L["%dd ago"], math.floor(d / 86400))
end

-- Staleness line for the gear/profs views: a live snapshot for self, "cached <ago>" for a
-- peer's last self-report, or "" when there's nothing cached (the list already says so).
-- dataset = "gearCache" | "profCache". Pure/testable.
function LCEX:CacheMetaText(player, dataset)
    if self:IsSelf(player) then return self.L["(your live snapshot)"] end
    local key = self:NormalizeName(player)
    local rec = key and self.db.global[dataset][key]
    if not rec then return "" end
    return string.format(self.L["cached %s"], self:RelTime(rec.mod))
end

-- ── Class / spec resolvers ───────────────────────────────────────────────────
-- Cycle to the next element after `current` (wraps; unknown/empty -> first/nil). Pure/testable.
function LCEX:_CycleNext(list, current)
    if #list == 0 then return nil end
    for i, v in ipairs(list) do
        if v == current then return list[(i % #list) + 1] end
    end
    return list[1]
end

-- Live class token (UnitClass) for the local player or a grouped member; nil otherwise.
function LCEX:ClassOf(name)
    if self:IsSelf(name) then return select(2, UnitClass("player")) end
    local n = self:NormalizeName(name)
    if not n then return nil end
    local inRaid = IsInRaid()
    for i = 1, GetNumGroupMembers() do
        local unit = inRaid and ("raid" .. i) or ("party" .. i)
        local u = UnitName(unit)
        if u and self:NormalizeName(u) == n then return select(2, UnitClass(unit)) end
    end
    return nil
end

-- Self-reported class/spec for a player, from their gearCache record (SelfReport.lua), or nil.
-- Lets the BiS view resolve class+spec for a cached player who isn't currently grouped.
function LCEX:CachedClass(name)
    local key = self:NormalizeName(name)
    local rec = key and self.db.global.gearCache[key]
    return rec and rec.class
end

function LCEX:CachedSpec(name)
    local key = self:NormalizeName(name)
    local rec = key and self.db.global.gearCache[key]
    return rec and rec.spec
end

-- ── Player index (the Players module's picker) ───────────────────────────────
-- Everyone we know about: self, gear/prof caches, notes keys, history winners, the guild
-- roster. Returns { {key=<normalized>, name=<display>}, ... } sorted by key, optionally
-- prefix/substring-filtered. Pure/testable.
function LCEX:BuildPlayerIndex(filter)
    local seen, all = {}, {}
    local function add(name)
        if type(name) ~= "string" or name == "" then return end
        local key = self:NormalizeName(name)
        if not key or seen[key] then return end
        seen[key] = true
        local display = name:match("^[^%-]+")
        -- Dataset keys arrive pre-normalized (lowercase) — re-capitalize for display.
        if display == key then display = key:gsub("^%l", string.upper) end
        all[#all + 1] = { key = key, name = display }
    end
    add(UnitName("player"))
    for key, rec in pairs(self.db.global.gearCache) do add(rec.by or key) end
    for key, rec in pairs(self.db.global.profCache) do add(rec.by or key) end
    for key in pairs(self.db.global.notes) do add(key) end
    for _, rec in pairs(self.db.global.history) do add(rec.player) end
    for i = 1, (GetNumGuildMembers() or 0) do add((GetGuildRosterInfo(i))) end

    filter = (filter and filter ~= "" and filter:lower()) or nil
    local out = {}
    for _, e in ipairs(all) do
        if not filter or e.key:find(filter, 1, true) then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ── History log (the History module) ─────────────────────────────────────────
-- All award records newest-first, optionally filtered by a winner-name substring.
-- Pure/testable.
function LCEX:BuildHistoryLog(filter)
    filter = (filter and filter ~= "" and filter:lower()) or nil
    local rows = {}
    for _, rec in pairs(self.db.global.history) do
        local key = self:NormalizeName(rec.player) or ""
        if not filter or key:find(filter, 1, true) then rows[#rows + 1] = rec end
    end
    table.sort(rows, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return rows
end

-- ── BiS display ──────────────────────────────────────────────────────────────
-- Resolve the current BiS class/spec/phase. Class defaults to the player's class on first view
-- (when unset/invalid) — their LIVE class if grouped, else their last self-reported class, else
-- the first class. Spec defaults to their reported spec when it fits the resolved class, else the
-- first spec with data (so items show immediately), else the class's first talent tree; phase to
-- the first. Manual cycling sticks until a different player is opened.
function LCEX:ResolveBiSContext(player)
    if not self.bisClass or not self:IsKnownClass(self.bisClass) then
        local live = self:ClassOf(player) or self:CachedClass(player)
        self.bisClass = (live and self:IsKnownClass(live) and live) or self.CLASSES[1]
    end
    local specs = self:SpecsForClass(self.bisClass)
    local valid = false
    for _, s in ipairs(specs) do if s == self.bisSpec then valid = true; break end end
    if not valid then
        local cached = self:CachedSpec(player)
        local cachedFits = false
        if cached then for _, s in ipairs(specs) do if s == cached then cachedFits = true; break end end end
        self.bisSpec = (cachedFits and cached) or self:GetBiSSpecs(self.bisClass)[1] or specs[1]
    end
    if not self.bisPhase then self.bisPhase = self.PHASES[1] end
end

-- BiS rows for the resolved class/spec/phase, with a header line.
function LCEX:BuildBiSDisplay(player)
    self:ResolveBiSContext(player)
    local out = { { kind = "info", text = string.format(self.L["Class %s · Spec %s · %s"],
        tostring(self.bisClass or "?"), tostring(self.bisSpec or "?"), tostring(self.bisPhase or "?")) } }
    if self.bisClass and self.bisSpec and self.bisPhase then
        for _, r in ipairs(self:GetBiSForSpecPhase(self.bisClass, self.bisSpec, self.bisPhase)) do
            for _, itemID in ipairs(r.items) do
                out[#out + 1] = { kind = "bisitem", slot = r.slot, itemID = itemID }
            end
        end
    end
    if #out == 1 then out[#out + 1] = { kind = "info", text = self.L["No BiS data for this class/spec/phase."] } end
    return out
end
