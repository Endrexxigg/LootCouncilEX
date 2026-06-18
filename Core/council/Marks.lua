-- ── LootCouncil EX — council/Marks.lua ───────────────────────────────────────
-- Plane B: persistent item marks (itemID → {text, mod, by}), last-write-wins — the council's
-- standing note on an item ("give next to X"). Own edits broadcast via SetRecord; inbound
-- merge through the sync engine. Keyed by numeric itemID.
--
-- Loads after Sync.lua (RegisterDataset/SetRecord).

local LCEX = LootCouncilEX

LCEX:RegisterDataset("marks", "lww", function() return LCEX.db.global.marks end)

-- Set an item's mark and sync it (council-gated warning, then SetRecord broadcasts pSet).
-- Shared by /lcex mark and the LootBrowser's inline editor.
function LCEX:SetMark(itemID, text)
    if not self:AmCouncil() then
        self:Msg(self.L["Heads-up: you're not on the council — this won't sync to others."])
    end
    self:SetRecord("marks", itemID, { text = text })
end

-- /lcex mark <itemID|link> [text] — set or read a mark. Accepts a raw itemID or a
-- shift-clicked item link (whose [Name] may contain spaces, so we extract the id from the
-- hyperlink and take the text after the link's closing |r).
function LCEX:CmdMark(rest)
    rest = strtrim(rest or "")
    local itemID, text
    local linkID = rest:match("|Hitem:(%d+)")
    if linkID then
        itemID = tonumber(linkID)
        text = strtrim(rest:match("|r%s*(.*)$") or "")
    else
        local first, remainder = rest:match("^(%S+)%s+(.+)$")
        itemID = tonumber(first or rest)
        text = remainder
    end

    if not itemID then
        self:Msg(self.L["Usage: /lcex mark <itemID|link> [text]"])
        return
    end

    if text and text ~= "" then
        self:SetMark(itemID, text)
        self:Msg(string.format(self.L["Mark on item %d set."], itemID))
    else
        local rec = self.db.global.marks[itemID]
        if rec then
            self:Msg(string.format(self.L["Mark on item %d: %s  (by %s)"],
                itemID, tostring(rec.text), tostring(rec.by)))
        else
            self:Msg(string.format(self.L["No mark on item %d."], itemID))
        end
    end
end
