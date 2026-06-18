-- ── LootCouncil EX — session/Candidate.lua ───────────────────────────────────
-- Candidate side of Plane A: receive sStart → open the LootFrame → send cResp to the ML;
-- receive sEnd → close. Session authority is bound to the sStart sender per sid (PROJECT.md
-- DL-11): we record the ML as whoever opened the session and accept the matching sEnd only
-- from that same sender + sid. The trusted guild model (§2) makes this acceptable for v1.
--
-- Loads after UI/LootFrame.lua (opens it) and Comms.lua (whose dispatch table we populate).

local LCEX = LootCouncilEX
LCEX.dispatch = LCEX.dispatch or {}

-- The session we are currently responding to (candidate view), distinct from LCEX.session
-- (the ML-authority state on the ML's own client): { sid, ml, items, responses }.
-- LCEX.activeSession is nil when no session is open for us.

-- GetItemInfoInstant: synchronous, never-nil; on Anniversary it may live under C_Item.
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

-- equipLoc → the inventory slot name(s) an item competes for. Two-slot types (rings,
-- trinkets, one-hand weapons) list both so we can show the candidate's competing gear.
local EQUIP_SLOTS = {
    INVTYPE_HEAD = { "HeadSlot" }, INVTYPE_NECK = { "NeckSlot" },
    INVTYPE_SHOULDER = { "ShoulderSlot" }, INVTYPE_CLOAK = { "BackSlot" },
    INVTYPE_CHEST = { "ChestSlot" }, INVTYPE_ROBE = { "ChestSlot" },
    INVTYPE_WRIST = { "WristSlot" }, INVTYPE_HAND = { "HandsSlot" },
    INVTYPE_WAIST = { "WaistSlot" }, INVTYPE_LEGS = { "LegsSlot" },
    INVTYPE_FEET = { "FeetSlot" },
    INVTYPE_FINGER = { "Finger0Slot", "Finger1Slot" },
    INVTYPE_TRINKET = { "Trinket0Slot", "Trinket1Slot" },
    INVTYPE_WEAPON = { "MainHandSlot", "SecondaryHandSlot" },
    INVTYPE_2HWEAPON = { "MainHandSlot" },
    INVTYPE_WEAPONMAINHAND = { "MainHandSlot" },
    INVTYPE_WEAPONOFFHAND = { "SecondaryHandSlot" },
    INVTYPE_HOLDABLE = { "SecondaryHandSlot" }, INVTYPE_SHIELD = { "SecondaryHandSlot" },
    INVTYPE_RANGED = { "RangedSlot" }, INVTYPE_RANGEDRIGHT = { "RangedSlot" },
    INVTYPE_THROWN = { "RangedSlot" }, INVTYPE_RELIC = { "RangedSlot" },
}

-- The candidate's currently-equipped item(s) competing with `link` — up to two links. Read
-- instantly from GetItemInfoInstant's equipLoc; gives the council a like-for-like compare
-- (GetAverageItemLevel is unreliable in Classic — show the competing slot instead, §6.7).
function LCEX:CompetingGear(link)
    local gear = {}
    local _, _, _, equipLoc = GetItemInfoInstant(link)
    local slots = equipLoc and EQUIP_SLOTS[equipLoc]
    if not slots then return gear end
    for _, slotName in ipairs(slots) do
        local id = GetInventorySlotInfo(slotName)
        local equipped = id and GetInventoryItemLink("player", id)
        if equipped then gear[#gear + 1] = equipped end
    end
    return gear
end

-- A response button was clicked for item #index: send a cResp to the session ML.
function LCEX:OnResponseChosen(index, resp)
    local a = self.activeSession
    if not a then return end
    local item = a.items[index]
    if not item then return end

    local payload = {
        item = index,
        resp = resp.id,
        note = (self.lootFrame and self.lootFrame.noteBox:GetText()) or "",
        gear = self:CompetingGear(item.link),
    }
    if self:IsSelf(a.ml) then
        -- We ARE the ML responding to our own session: aggregate locally — a WHISPER to self
        -- isn't reliably delivered. (The handler reads msg.sid, normally set by BuildEnvelope.)
        payload.sid = a.sid
        self.dispatch.cResp(self, payload, UnitName("player"))
    else
        self:Send("cResp", a.sid, payload, "WHISPER", a.ml)
    end
    self:Msg(string.format(self.L["Responded %s to %s."], resp.text, item.link))
end

-- /lcex respond — reopen the response frame for the active session (e.g. after closing it).
function LCEX:CmdRespond()
    local a = self.activeSession
    if not a then
        self:Msg(self.L["No active loot session to respond to."])
        return
    end
    self:ShowLootFrame(a.items, a.responses)
end

-- Open OUR OWN candidate view for a session we just started as the ML (called from
-- StartSession), so the ML sees the response frame solo or grouped without depending on the
-- comms echo — and can respond to their own session.
function LCEX:OpenOwnCandidateView(sid, items, responses)
    self.activeSession = { sid = sid, ml = UnitName("player"), items = items, responses = responses }
    self:ShowLootFrame(items, responses)
end

-- Close our own candidate view when WE end the session (the solo path has no sEnd echo).
-- Guarded by sid so it won't close some other ML's session frame we might be viewing.
function LCEX:CloseOwnCandidateView(sid)
    local a = self.activeSession
    if a and (not sid or a.sid == sid) then
        self.activeSession = nil
        self:HideLootFrame()
    end
end

-- ── Dispatch handlers ────────────────────────────────────────────────────────
-- The ML opened a session: record it (binding the ML to this sender) and open the frame.
-- A new sStart supersedes any session we were already showing.
LCEX.dispatch.sStart = function(self, msg, sender)
    if type(msg.items) ~= "table" or #msg.items == 0 then return end
    self.activeSession = {
        sid       = msg.sid,
        ml        = sender,
        items     = msg.items,
        responses = msg.responses or self.RESPONSES,
    }
    self:ShowLootFrame(msg.items, self.activeSession.responses)
end

-- The session ended: only the ML that opened THIS sid can close it (DL-11).
LCEX.dispatch.sEnd = function(self, msg, sender)
    local a = self.activeSession
    if a and msg.sid == a.sid and self:NormalizeName(sender) == self:NormalizeName(a.ml) then
        self.activeSession = nil
        self:HideLootFrame()
    end
end
