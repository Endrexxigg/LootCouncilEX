-- ── LootCouncil EX — session/Readiness.lua ───────────────────────────────────
-- Feature V award-readiness (PROJECT.md §6.10). Two layers:
--   • ReadinessStatus — a PURE calculator: given one item's rows plus the vote/council/award
--     facts, return { kind, voted }. No frame or session reads, so it is headless-tested.
--   • ComputeItemStatus (+ the two counters) — the ML-side glue that gathers those facts from
--     the live session and calls the calculator. The result rides cUpdate (Session.lua) so every
--     client draws the SAME rail-row border (LootWindow.lua) — the ML is the single source of
--     truth for readiness, exactly like it is for the row aggregate itself.
--
-- Loads after Session.lua (whose BroadcastCUpdate / cResp path calls ComputeItemStatus).

local LCEX = LootCouncilEX

-- Pure award-readiness calculator (§6.10). `input` is a plain table (no self-state read):
--   { rows, passId, awarded(bool), votesCast(n), councilPresent(of) }
-- Returns { kind = <status>, voted = { n = votesCast, of = councilPresent } }.
--
--   kind: "awarded"  dark green  — the item is awarded
--         "de"       blue        — nobody wants it and all present-eligible responded → disenchant
--         "ready"    light green — someone wants it and (all present council voted, OR all
--                                   responded with exactly one roller)
--         "voting"   gold        — someone wants it, all present-eligible responded, not yet ready
--         "waiting"  grey        — responses still outstanding
--
-- Precedence awarded > ready > de > voting > waiting (Vd3); ready/de are mutually exclusive by
-- construction (de needs zero wanters, ready needs ≥1). Present-eligible = rows with reason nil
-- (responded) or "pending" (eligible, unresponded); cantuse/missedkill/left are excluded from the
-- denominator (R4). "Wants it" = a non-PASS response; "voted" = a non-zero vote (no abstain — V2).
function LCEX:ReadinessStatus(input)
    local rows           = input.rows or {}
    local passId         = input.passId
    local votesCast      = input.votesCast or 0
    local councilPresent = input.councilPresent or 0
    local voted          = { n = votesCast, of = councilPresent }

    -- Classify the present-eligible rows (the readiness denominator).
    local eligible, pending, wanters = 0, 0, 0
    for _, r in pairs(rows) do
        local reason = r.reason
        if reason == nil or reason == "pending" then
            eligible = eligible + 1
            if reason == "pending" then
                pending = pending + 1
            elseif r.resp and r.resp ~= passId then
                wanters = wanters + 1
            end
        end
    end
    local allResponded = eligible > 0 and pending == 0

    local kind
    if input.awarded then
        kind = "awarded"
    elseif eligible == 0 then
        kind = "waiting" -- nobody eligible is present → nothing to be ready about yet
    elseif wanters == 0 then
        kind = allResponded and "de" or "waiting" -- all passed → disenchant; else still waiting
    else
        local allCouncilVoted = councilPresent > 0 and votesCast >= councilPresent
        local oneRoller       = allResponded and wanters == 1
        if allCouncilVoted or oneRoller then
            kind = "ready"
        elseif allResponded then
            kind = "voting"
        else
            kind = "waiting"
        end
    end
    return { kind = kind, voted = voted }
end

-- Council members currently present (in the group; self always counts) — the "X / Y voted"
-- denominator (V6) and the "all present council voted" readiness gate. Fail-open: soloed, this is
-- just the runner. `session.council` is the normalized name list resolved at start (GetCouncil).
function LCEX:PresentCouncilCount()
    local s = self.session
    if not s or not s.council then return 0 end
    local n = 0
    for _, name in ipairs(s.council) do
        if self:InGroupWith(name) then n = n + 1 end -- InGroupWith already counts self
    end
    return n
end

-- A voter's display name from its normalized key (capitalized short name, realm dropped). The
-- who-voted list is cosmetic, so this light touch-up beats storing a parallel display map through
-- the whole vote path.
function LCEX:VoterDisplay(key)
    local short = tostring(key):match("^[^%-]+") or tostring(key)
    if short == "" then return short end
    return short:sub(1, 1):upper() .. short:sub(2)
end

-- Distinct council members (display names, sorted) who have cast a non-zero vote on item `index` —
-- the who-voted list (V6) and, by its length, the tally numerator + the "all present council voted"
-- readiness test. voters[index][candKey][voterName] = vote (voterName is the normalized key).
function LCEX:VotersOn(index)
    local s = self.session
    local byCand = s and s.voters and s.voters[index]
    local out = {}
    if not byCand then return out end
    local seen = {}
    for _, voterMap in pairs(byCand) do
        for voterName, v in pairs(voterMap) do
            if v ~= 0 and not seen[voterName] then
                seen[voterName] = true
                out[#out + 1] = self:VoterDisplay(voterName)
            end
        end
    end
    table.sort(out)
    return out
end

function LCEX:VotesCastOn(index)
    return #self:VotersOn(index)
end

-- True once every physical copy in a group is awarded (§6.14). Reads session.groups (ML) +
-- activeSession.awarded. A non-grouped item is "full" once its own index is awarded.
function LCEX:GroupFullyAwarded(leader)
    local a = self.activeSession
    local awarded = a and a.awarded
    local s = self.session
    local members = (s and s.groups and s.groups.members[leader]) or { leader }
    for _, m in ipairs(members) do
        if not (awarded and awarded[m] ~= nil) then return false end
    end
    return true
end

-- ML-side glue: gather the live facts for item `index` and run the calculator. Nil when there is
-- no session / no rows for the item (the caller then sends no status — receivers keep their last).
function LCEX:ComputeItemStatus(index)
    local s = self.session
    if not s then return nil end
    local rows = s.rows[index]
    if not rows then return nil end
    -- Group-aware (§6.14): the border only reads "awarded" once EVERY copy is awarded; a
    -- partially-awarded group keeps computing live status for the copies still up for grabs.
    local awarded = self:GroupFullyAwarded(index)
    local voters = self:VotersOn(index)
    local status = self:ReadinessStatus({
        rows           = rows,
        passId         = self:PassResponseId(),
        awarded        = awarded,
        votesCast      = #voters,
        councilPresent = self:PresentCouncilCount(),
    })
    -- Attach the who-voted list (V6) unless the session is anonymous (V7) — then only the count
    -- survives on the wire, so no client can reconstruct who voted for whom.
    if not s.anon then status.voted.names = voters end
    return status
end
