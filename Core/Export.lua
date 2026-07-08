-- ── LootCouncil EX — Core/Export.lua ─────────────────────────────────────────
-- Phase 15a (§6.19, DL-25): pure loot-history exporters (CSV / JSON / Discord) and the RCLC CSV
-- import parser. NO comms, NO frames — the History module's Export/Import buttons call these and
-- feed the text through the reused ShowExportFrame. Builds over BuildHistoryLog(filter) so an
-- export always matches the module's current winner filter, newest-first.
--
-- Loads after Display.lua (BuildHistoryLog) + History.lua (HistoryReasonText/BuildHistoryRecord).
-- The import path also uses Sync.lua (MergeRecord/HashString) + Const (STATUS) at runtime, all of
-- which load later in the .toc but resolve fine (import runs on a button click, long after load).

local LCEX = LootCouncilEX

-- Item NAME from a link's [bracketed] text; "" when not resolvable (headless-safe — no GetItemInfo).
local function itemName(link)
    if type(link) ~= "string" then return "" end
    return link:match("%[(.-)%]") or ""
end

-- The flat export rows (newest-first, honoring the winner filter): one table per history record,
-- with the DL-8 resolved reason. Shared by all three formatters so they never diverge.
function LCEX:ExportRows(filter)
    local out = {}
    for _, e in ipairs(self:BuildHistoryLog(filter)) do
        local r = e.rec
        out[#out + 1] = {
            winner    = r.player or "",
            ts        = r.ts or 0,
            itemID    = r.itemID or "",
            itemName  = itemName(r.itemLink),
            reason    = self:HistoryReasonText(r) or "",
            boss      = r.boss or "",
            instance  = r.instance or "",
            by        = r.by or "",
            retracted = r.retracted and true or false,
        }
    end
    return out
end

-- ── CSV (RFC-4180) ───────────────────────────────────────────────────────────
local function csvCell(v)
    v = tostring(v == nil and "" or v)
    if v:find('[,"\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

function LCEX:ExportCSV(filter)
    local lines = { "winner,date,time,itemID,itemName,response,boss,instance,by,retracted" }
    for _, r in ipairs(self:ExportRows(filter)) do
        lines[#lines + 1] = table.concat({
            csvCell(r.winner), csvCell(date("%Y-%m-%d", r.ts)), csvCell(date("%H:%M", r.ts)),
            csvCell(r.itemID), csvCell(r.itemName), csvCell(r.reason),
            csvCell(r.boss), csvCell(r.instance), csvCell(r.by),
            csvCell(r.retracted and "yes" or ""),
        }, ",")
    end
    return table.concat(lines, "\n")
end

-- ── JSON (hand-rolled for this flat shape; Lua 5.1-safe — no %z) ──────────────
local function jsonStr(s)
    s = tostring(s == nil and "" or s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

function LCEX:ExportJSON(filter)
    local parts = {}
    for _, r in ipairs(self:ExportRows(filter)) do
        parts[#parts + 1] = table.concat({
            "{",
            '"winner":', jsonStr(r.winner), ",",
            '"date":', jsonStr(date("%Y-%m-%d", r.ts)), ",",
            '"time":', jsonStr(date("%H:%M", r.ts)), ",",
            '"itemID":', tostring(tonumber(r.itemID) or 0), ",",
            '"itemName":', jsonStr(r.itemName), ",",
            '"response":', jsonStr(r.reason), ",",
            '"boss":', jsonStr(r.boss), ",",
            '"instance":', jsonStr(r.instance), ",",
            '"by":', jsonStr(r.by), ",",
            '"retracted":', r.retracted and "true" or "false",
            "}",
        })
    end
    return "[" .. table.concat(parts, ",\n") .. "]"
end

-- ── Discord markdown ─────────────────────────────────────────────────────────
-- `**[Item]** → Winner (*reason*) — Boss, MM/DD`; retracted lines struck through.
function LCEX:ExportDiscord(filter)
    local lines = {}
    for _, r in ipairs(self:ExportRows(filter)) do
        local name = (r.itemName ~= "" and r.itemName) or ("item:" .. tostring(r.itemID))
        local reason = r.reason ~= "" and (" (*" .. r.reason .. "*)") or ""
        local tail = r.boss ~= "" and (" — " .. r.boss .. ", " .. date("%m/%d", r.ts))
            or (" — " .. date("%m/%d", r.ts))
        local line = "**[" .. name .. "]** → " .. r.winner .. reason .. tail
        if r.retracted then line = "~~" .. line .. "~~" end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

-- ── RCLC CSV import (§6.19, DL-25) ───────────────────────────────────────────
-- Split one CSV line into fields, honoring RFC-4180 double-quote quoting ("" = a literal quote).
local function splitCSVLine(line)
    local fields, i, n = {}, 1, #line
    while true do
        if line:sub(i, i) == '"' then
            local field = ""
            i = i + 1
            while i <= n do
                local c = line:sub(i, i)
                if c == '"' then
                    if line:sub(i + 1, i + 1) == '"' then field = field .. '"'; i = i + 2
                    else i = i + 1; break end
                else field = field .. c; i = i + 1 end
            end
            fields[#fields + 1] = field
            if line:sub(i, i) == "," then i = i + 1 else break end
        else
            local comma = line:find(",", i, true)
            if comma then fields[#fields + 1] = line:sub(i, comma - 1); i = comma + 1
            else fields[#fields + 1] = line:sub(i); break end
        end
    end
    return fields
end

-- RCLC date is DD/MM/YY, time HH:MM:SS. Build a real unix epoch via time({...}) when parseable
-- (the in-game path); otherwise fall back to now. Never throws (pcall-guarded).
function LCEX:_RCLCEpoch(dateStr, timeStr)
    local d, m, y = tostring(dateStr or ""):match("(%d+)/(%d+)/(%d+)")
    if d and m and y then
        local hh, mm, ss = tostring(timeStr or ""):match("(%d+):(%d+):(%d+)")
        local yy = tonumber(y)
        local ok, epoch = pcall(time, {
            year = yy + (yy < 70 and 2000 or 1900), month = tonumber(m), day = tonumber(d),
            hour = tonumber(hh) or 12, min = tonumber(mm) or 0, sec = tonumber(ss) or 0,
        })
        if ok and type(epoch) == "number" and epoch > 0 then return epoch end
    end
    return time()
end

-- Parse an RCLootCouncil history CSV into native-shaped records (winner/itemID/itemLink/respText/
-- boss/instance/ts). Columns are mapped BY HEADER NAME so RCLC column drift doesn't break it.
-- Returns (records, skipped). Malformed rows (no player / no numeric itemID) are counted, not fatal.
function LCEX:ParseRCLCHistoryCSV(text)
    local records, skipped = {}, 0
    local lines = {}
    for ln in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        if ln:match("%S") then lines[#lines + 1] = ln end
    end
    if #lines < 2 then return records, skipped end
    local col, header = {}, splitCSVLine(lines[1])
    for idx, name in ipairs(header) do col[name:lower()] = idx end
    if not (col.player and col.itemid) then return records, skipped end -- not an RCLC CSV
    local function cell(f, name) return col[name] and f[col[name]] end
    for i = 2, #lines do
        local f = splitCSVLine(lines[i])
        local player = cell(f, "player")
        local itemID = tonumber(cell(f, "itemid"))
        if player and player ~= "" and itemID then
            local link = cell(f, "item")
            records[#records + 1] = {
                winner   = self:NormalizeName(player) or player,
                itemID   = itemID,
                itemLink = (link and link ~= "" and link) or ("item:" .. itemID),
                respText = cell(f, "response") or "",
                boss     = cell(f, "boss"),
                instance = cell(f, "instance"),
                ts       = self:_RCLCEpoch(cell(f, "date"), cell(f, "time")),
            }
        else
            skipped = skipped + 1
        end
    end
    return records, skipped
end

-- Import an RCLC history CSV into the native history dataset. Each row → an `imp:<hash>` record
-- (stable, so re-import is idempotent) with mod = the award's own epoch (never out-ranks a real
-- recent award; imp: uids can't collide with sid:index) and resp = STATUS.CUSTOM + verbatim
-- respText (DL-8 makes id-mapping unnecessary). Re-advertises the digest so imports replicate.
function LCEX:ImportRCLCHistory(text)
    local records, skipped = self:ParseRCLCHistoryCSV(text)
    local added = 0
    for _, r in ipairs(records) do
        local uid = "imp:" .. self:HashString(table.concat(
            { r.winner, r.itemID, r.ts, r.boss or "", r.respText or "" }, "\30"))
        local rec = self:BuildHistoryRecord({
            winner = r.winner, itemID = r.itemID, itemLink = r.itemLink, ts = r.ts, mod = r.ts,
            resp = self.STATUS.CUSTOM, respText = r.respText, boss = r.boss, instance = r.instance,
            by = "import",
        })
        if self:MergeRecord("history", uid, rec) then added = added + 1 end
    end
    if added > 0 and self.SyncHello then self:SyncHello() end -- re-advertise so imports replicate
    self:Msg(string.format(self.L["Imported %d record(s) (%d skipped)."], added, skipped))
    return added, skipped
end
