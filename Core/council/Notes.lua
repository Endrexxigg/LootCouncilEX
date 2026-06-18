-- ── LootCouncil EX — council/Notes.lua ───────────────────────────────────────
-- Plane B: player notes (name → {text, mod, by}), last-write-wins. A council member's own
-- edit goes out via SetRecord (which stamps mod/by and broadcasts pSet); inbound edits merge
-- through the generic sync engine. Keyed by NormalizeName so "Bob"/"Bob-Realm"/casing agree.
--
-- Loads after Sync.lua (RegisterDataset/SetRecord).

local LCEX = LootCouncilEX

LCEX:RegisterDataset("notes", "lww", function() return LCEX.db.global.notes end)

-- /lcex note <player> [text] — set a note (with text) or read it (without).
function LCEX:CmdNote(rest)
    rest = strtrim(rest or "")
    local player, text = rest:match("^(%S+)%s+(.+)$")
    if not player then player = rest end
    if player == "" then
        self:Msg(self.L["Usage: /lcex note <player> [text]"])
        return
    end

    local key = self:NormalizeName(player)
    if text then
        if not self:AmCouncil() then
            self:Msg(self.L["Heads-up: you're not on the council — this won't sync to others."])
        end
        self:SetRecord("notes", key, { text = text })
        self:Msg(string.format(self.L["Note on %s set."], player))
    else
        local rec = key and self.db.global.notes[key]
        if rec then
            self:Msg(string.format(self.L["Note on %s: %s  (by %s)"],
                player, tostring(rec.text), tostring(rec.by)))
        else
            self:Msg(string.format(self.L["No note on %s."], player))
        end
    end
end
