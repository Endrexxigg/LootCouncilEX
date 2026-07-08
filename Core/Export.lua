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
