-- ── LootCouncil EX — UI/Theme.lua ────────────────────────────────────────────
-- The design language for the four-frame UI: flat-dark gradient surfaces, gold accent, quiet
-- text tones (patterned on iddqd/Cell, verified TBC-safe against Gargul). One source of truth
-- for every color/font/metric so all windows read as one addon. Widgets.lua builds on this;
-- frame modules never hardcode colors.
--
-- Classic-safety notes baked in here:
--   • Gradients: newer clients take Texture:SetGradient(orient, ColorMixin, ColorMixin); the
--     2.5.x era client takes SetGradientAlpha(orient, r,g,b,a, r,g,b,a). ApplyGradient tries
--     both (pcall-guarded), degrading to a flat fill — a frame never fails to paint.
--   • All fills use Interface\Buttons\WHITE8X8 (present on every client).
--
-- Loads before UI/Widgets.lua.

local LCEX = LootCouncilEX

local WHITE = "Interface\\Buttons\\WHITE8X8"

LCEX.Theme = {
    -- Elevation tones: vertical gradients, darker at the bottom. Deeper in the stack = darker.
    tone = {
        page    = { top = { 0.047, 0.047, 0.053 }, bottom = { 0.031, 0.031, 0.037 } },
        base    = { top = { 0.090, 0.094, 0.110 }, bottom = { 0.063, 0.067, 0.082 } },
        raised  = { top = { 0.106, 0.110, 0.127 }, bottom = { 0.082, 0.086, 0.102 } },
        overlay = { top = { 0.129, 0.133, 0.153 }, bottom = { 0.102, 0.106, 0.124 } },
        float   = { top = { 0.165, 0.169, 0.188 }, bottom = { 0.137, 0.141, 0.157 } },
    },
    accent  = { 0.792, 0.651, 0.353 }, -- gold #caa65a — selection, focus, the addon's voice
    success = { 0.373, 0.749, 0.541 }, -- #5fbf8a
    danger  = { 0.831, 0.459, 0.420 }, -- #d4756b
    text = {
        ink   = { 0.914, 0.918, 0.933 }, -- #e9eaee — primary
        dim   = { 0.604, 0.627, 0.678 }, -- #9aa0ad — secondary
        faint = { 0.392, 0.416, 0.463 }, -- #646a76 — tertiary/disabled
    },
    font = "Fonts\\FRIZQT__.TTF",
    fontSize = { title = 22, section = 16, body = 13, caption = 11 },
    -- Blizzard item-quality RGB (poor..legendary), used wherever items render as text.
    quality = {
        [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 },       [2] = { 0.12, 1, 0 },
        [3] = { 0, 0.44, 0.87 },    [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 },
    },
}

-- ── Paint helpers ────────────────────────────────────────────────────────────
-- Vertical gradient on a texture, working on every client generation (see header). `top` and
-- `bottom` are {r,g,b}; alpha rides on the texture itself.
function LCEX:ApplyGradient(tex, top, bottom)
    tex:SetTexture(WHITE)
    if tex.SetGradient and CreateColor then
        local ok = pcall(tex.SetGradient, tex, "VERTICAL",
            CreateColor(bottom[1], bottom[2], bottom[3], 1),
            CreateColor(top[1], top[2], top[3], 1))
        if ok then return end
    end
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha("VERTICAL",
            bottom[1], bottom[2], bottom[3], 1, top[1], top[2], top[3], 1)
        return
    end
    -- No gradient API at all: flat fill at the midpoint.
    tex:SetVertexColor((top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2,
        (top[3] + bottom[3]) / 2, 1)
end

-- Paint `frame` as an elevation surface: gradient fill + a 1px top-light line. Idempotent —
-- repainting with another tone reuses the same textures (rows re-tone on select/hover).
function LCEX:Surface(frame, toneName)
    local tone = self.Theme.tone[toneName] or self.Theme.tone.base
    if not frame._surface then
        frame._surface = frame:CreateTexture(nil, "BACKGROUND")
        frame._surface:SetAllPoints(frame)
        frame._topLight = frame:CreateTexture(nil, "BORDER")
        frame._topLight:SetTexture(WHITE)
        frame._topLight:SetPoint("TOPLEFT", 0, 0)
        frame._topLight:SetPoint("TOPRIGHT", 0, 0)
        frame._topLight:SetHeight(1)
        frame._topLight:SetVertexColor(1, 1, 1, 0.04)
    end
    self:ApplyGradient(frame._surface, tone.top, tone.bottom)
    frame._tone = toneName
    return frame
end

-- Soft outer edge (the quiet border every themed window/card carries).
function LCEX:SoftEdge(frame, alpha)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 9,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        frame:SetBackdropBorderColor(1, 1, 1, alpha or 0.065)
    end
    return frame
end

-- Themed FontString: size from the ramp, color from the text tones. `sizeKey` defaults to
-- body, `toneKey` to ink. SetFont always precedes SetText (callers set text after).
function LCEX:ThemeText(fs, sizeKey, toneKey)
    local size = self.Theme.fontSize[sizeKey or "body"] or self.Theme.fontSize.body
    fs:SetFont(self.Theme.font, size, "")
    local c = self.Theme.text[toneKey or "ink"] or self.Theme.text.ink
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- {r,g,b} for an item quality (nil-safe: unknown → common white).
function LCEX:QualityColor(quality)
    return self.Theme.quality[quality] or self.Theme.quality[1]
end

-- {r,g,b} for a class token via RAID_CLASS_COLORS (nil-safe: unknown → ink).
function LCEX:ClassColor(classToken)
    local cc = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if cc then return { cc.r, cc.g, cc.b } end
    return self.Theme.text.ink
end
