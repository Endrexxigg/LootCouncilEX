-- ── LootCouncil EX — Core/Usable.lua ─────────────────────────────────────────
-- Class-usability filter for the poll window: raiders only see cards for items their class
-- can actually use. Two checks, in order:
--   1. Tier tokens: TierTokens[id].pieces[CLASS] — a token that redeems into nothing for the
--      player's class is hidden.
--   2. Armor/weapon proficiency: GetItemInfoInstant's classID/subClassID against the static
--      TBC proficiency tables below (fixed game facts as of 2.4.3 — e.g. rogues get axes only
--      in Cataclysm, druids get polearms only in Wrath).
-- PHILOSOPHY: never hide something usable — anything unknown (recipes, quest items, misc,
-- absent APIs) defaults to SHOW. Filtering is display-only on the receiving client; sessions
-- always broadcast the full item list.
--
-- Loads after Core/Data (FindTokenForItem). Headless-tested in Tests/run.lua.

local LCEX = LootCouncilEX

-- GetItemInfoInstant: synchronous, never-nil for a valid item; on Anniversary it may live
-- under C_Item (same shim as the UI files).
local GetItemInfoInstant = _G.GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)

-- Armor subclasses (classID 4): 1=Cloth 2=Leather 3=Mail 4=Plate 6=Shield 7=Libram 8=Idol
-- 9=Totem. Subclass 0 (Misc: rings/necks/trinkets/held-in-off-hand) is universal, handled in
-- code, as are cloaks (subclass Cloth but INVTYPE_CLOAK — every class wears them).
local ARMOR = {
    WARRIOR = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true },
    PALADIN = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [7] = true },
    HUNTER  = { [1] = true, [2] = true, [3] = true },
    ROGUE   = { [1] = true, [2] = true },
    PRIEST  = { [1] = true },
    SHAMAN  = { [1] = true, [2] = true, [3] = true, [6] = true, [9] = true },
    MAGE    = { [1] = true },
    WARLOCK = { [1] = true },
    DRUID   = { [1] = true, [2] = true, [8] = true },
}

-- Weapon subclasses (classID 2): 0=1H Axe 1=2H Axe 2=Bow 3=Gun 4=1H Mace 5=2H Mace 6=Polearm
-- 7=1H Sword 8=2H Sword 10=Staff 13=Fist 15=Dagger 16=Thrown 18=Crossbow 19=Wand.
local WEAPON = {
    WARRIOR = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
                [6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true,
                [16] = true, [18] = true },
    PALADIN = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true,
                [8] = true },
    HUNTER  = { [0] = true, [1] = true, [2] = true, [3] = true, [6] = true, [7] = true,
                [8] = true, [10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
    ROGUE   = { [2] = true, [3] = true, [4] = true, [7] = true, [13] = true, [15] = true,
                [16] = true, [18] = true },
    PRIEST  = { [4] = true, [10] = true, [15] = true, [19] = true },
    SHAMAN  = { [0] = true, [1] = true, [4] = true, [5] = true, [10] = true, [13] = true,
                [15] = true },
    MAGE    = { [7] = true, [10] = true, [15] = true, [19] = true },
    WARLOCK = { [7] = true, [10] = true, [15] = true, [19] = true },
    DRUID   = { [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
}

-- Can `classToken` use this item? `item` is an itemID or an item link; `classToken` defaults
-- to the player's own class. Exposed with an explicit class arg so the proficiency matrix is
-- headless-testable for all nine classes.
function LCEX:ClassCanUse(item, classToken)
    if not item then return true end
    local id = tonumber(item) or tonumber(tostring(item):match("item:(%d+)"))

    -- Tier tokens: the token line either includes this class or it doesn't.
    local token = id and self:FindTokenForItem(id)
    if token then
        return token.pieces ~= nil and token.pieces[classToken] ~= nil
    end

    if not GetItemInfoInstant then return true end
    local _, _, _, equipLoc, _, classID, subClassID = GetItemInfoInstant(id or item)
    if classID == 4 then -- armor
        if equipLoc == "INVTYPE_CLOAK" then return true end -- 'cloth' but universal
        if subClassID == 0 then return true end             -- rings/necks/trinkets/held items
        local usable = ARMOR[classToken]
        if not usable then return true end
        return usable[subClassID] == true
    elseif classID == 2 then -- weapon
        local usable = WEAPON[classToken]
        if not usable then return true end
        return usable[subClassID] == true
    end
    return true -- anything else: never hide
end

-- The poll's question: can *I* use it?
function LCEX:PlayerCanUse(item)
    return self:ClassCanUse(item, select(2, UnitClass("player")))
end
