-- ── LootCouncil EX — UI/Theme.lua ────────────────────────────────────────────
-- The design language for the four-frame UI: flat-dark gradient surfaces, gold accent, quiet
-- text tones (patterned on iddqd/Cell, verified TBC-safe against Gargul). One source of truth
-- for every color/font/metric so all windows read as one addon. Widgets.lua builds on this;
-- frame modules never hardcode colors — and anchor from LCEX.LAYOUT, never one-off offsets.
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
    stripe  = { 1, 1, 1, 0.035 },      -- zebra row overlay (DL-23): even list rows lighten subtly
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
    -- Award-readiness rail-row border tones (Feature V, §6.10). "voting" reuses `accent` (gold);
    -- the rest are net-new per Vd2. Kept saturated enough to read as a 2px edge over dark rows.
    status = {
        waiting = { 0.47, 0.49, 0.54 }, -- neutral grey — responses still outstanding
        ready   = { 0.53, 0.87, 0.60 }, -- light green   — ready to be awarded
        de      = { 0.45, 0.64, 0.88 }, -- blue          — nobody wants it → disenchant waiting
        awarded = { 0.28, 0.55, 0.38 }, -- dark green    — awarded
    },
}

-- ── Layout contract ──────────────────────────────────────────────────────────
-- The shared spacing grid every LCEX frame anchors from. The load-bearing idea is ONE content
-- line per container: text, flat buttons and edit-box art all start `grid` (12px) inside their
-- container's edges. Chrome panels that sit at the `edge` (2px) window inset use `pad` (10)
-- internally — 2 + 10 = 12 absolute, the same optical line as the title-bar tick. Full-bleed
-- bands (zebra scroll lists, hero cards) sit at `bleed` (4) and pad row content by `rowPad`
-- (8), so row text lands on the very same line (4 + 8 = 12).
--
-- Identities (asserted in Tests/run.lua — change one number, keep the algebra true):
--   contentTop = edge + titleH + edge      grid = edge + pad      bleed = grid - rowPad
--
-- iconGap must stay ≤ 14: the AddonUIAudit engine treats an icon within 14px of a truncated
-- label as its tooltip host (TEXT/TRUNCATED_NO_TOOLTIP is ERROR for this addon).
LCEX.LAYOUT = {
    -- Window chrome
    edge       = 2,   -- window border → chrome strips (title bar, rails, panes, footer)
    titleH     = 28,  -- title-bar height (CreateWindowV2's f.bar)
    contentTop = 32,  -- first content y below the title bar (= edge + titleH + edge)
    divider    = 4,   -- seam between side-by-side panels (rail | pane)
    footerH    = 34,  -- bottom action-bar height

    -- The content grid
    pad   = 10,       -- content inset inside an edge-anchored chrome panel (→ 12 absolute)
    grid  = 12,       -- content inset inside a bare window or deep panel (= edge + pad)
    bleed = 4,        -- inset for full-bleed bands: zebra lists, hero cards (= grid - rowPad)

    -- Rhythm
    gap      = 8,     -- default gap between stacked/adjacent siblings
    gapTight = 4,     -- compact gap (glyph clusters, tab strips, trailing row buttons)
    section  = 16,    -- gap between unrelated control groups

    -- Rows
    rowPad    = 8,    -- row-internal left/right inset (bleed + rowPad = the grid line)
    iconGap   = 8,    -- icon → text gap (≤ 14, see header note)
    inlineGap = 6,    -- text → text / text → control gap inside a row

    -- Controls
    btnH     = 22,    -- standard flat-button height (footers, toolbars, forms)
    btnHSlim = 20,    -- in-row / tab-strip flat-button height
    btnGap   = 6,     -- gap between grouped action buttons (footer pairs)
    tabGap   = 4,     -- gap between tab-strip buttons
    editH    = 20,    -- InputBoxTemplate's intrinsic height
    editPad  = 4,     -- InputBoxTemplate left-art compensation: frame x = content line + editPad

    -- Lists
    gutter = 14,      -- scrollbar gutter reserved at a list's right edge (both list helpers)
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

-- Repaint an existing Surface with `alpha` baked into the gradient vertex colors — backdrop-only
-- opacity: children (text, buttons, icons) keep full alpha, unlike frame:SetAlpha which cascades.
-- The 1px top-light dims with the surface so a near-invisible shell doesn't keep a bright seam.
-- `toneName` is optional (defaults to the tone recorded by Surface); alpha 1 = the Surface look.
-- Same 3-way client fork as ApplyGradient. Stamps tex._lcexAlpha for the selftest.
function LCEX:SetSurfaceAlpha(frame, toneName, alpha)
    if not (frame and frame._surface) then return end
    local tone = self.Theme.tone[toneName or frame._tone] or self.Theme.tone.base
    local tex = frame._surface
    tex:Show()
    tex:SetTexture(WHITE)
    tex:SetAlpha(1)
    local ok = false
    if tex.SetGradient and CreateColor then
        ok = pcall(tex.SetGradient, tex, "VERTICAL",
            CreateColor(tone.bottom[1], tone.bottom[2], tone.bottom[3], alpha),
            CreateColor(tone.top[1], tone.top[2], tone.top[3], alpha))
    end
    if not ok and tex.SetGradientAlpha then
        tex:SetGradientAlpha("VERTICAL",
            tone.bottom[1], tone.bottom[2], tone.bottom[3], alpha,
            tone.top[1], tone.top[2], tone.top[3], alpha)
        ok = true
    end
    if not ok then
        tex:SetVertexColor((tone.top[1] + tone.bottom[1]) / 2,
            (tone.top[2] + tone.bottom[2]) / 2,
            (tone.top[3] + tone.bottom[3]) / 2, alpha)
    end
    tex._lcexAlpha = alpha
    if frame._topLight then
        frame._topLight:Show()
        frame._topLight:SetAlpha(1)
        frame._topLight:SetVertexColor(1, 1, 1, 0.04 * alpha)
    end
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

-- {r,g,b} for an award-readiness status kind (Feature V, §6.10). "voting" = the gold accent; the
-- others come from the status tones. nil for an unknown/absent kind → the border paints nothing.
function LCEX:StatusColor(kind)
    if kind == "voting" then return self.Theme.accent end
    return kind and self.Theme.status[kind] or nil
end

-- {r,g,b} for a class token via RAID_CLASS_COLORS (nil-safe: unknown → ink).
function LCEX:ClassColor(classToken)
    local cc = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if cc then return { cc.r, cc.g, cc.b } end
    return self.Theme.text.ink
end
