-- HekiLight
-- Wraps Blizzard's Rotation Assistant and displays its
-- current suggestion as a movable, skinnable icon overlay.
--
-- Key APIs used (Midnight 12.0+):
--   C_ActionBar.HasAssistedCombatActionButtons()     → bool
--   C_ActionBar.FindAssistedCombatActionButtons()    → slotID[]
--   C_ActionBar.IsAssistedCombatAction(slotID)       → bool
--   C_AssistedCombat.GetNextCastSpell(false)         → spellID  (primary suggestion)
--   C_AssistedCombat.GetRotationSpells()             → {spellID, ...}  (full queue)
--   C_Spell.GetSpellCooldown(spellID)                → cooldown info (pcall-guarded; secret values)

local ADDON_NAME = "HekiLight"
local DEBUG = false  -- toggle with /hkl debug

local function Log(...)
    if DEBUG then print("|cff88ccffHekiLight [DBG]:|r", ...) end
end

-- ── Defaults ────────────────────────────────────────────────────────────────

local DEFAULTS = {
    x              = 0,
    y              = 0,       -- screen center; use /hkl unlock to reposition
    iconSize       = 64,
    iconSpacing    = 8,       -- pixel gap between icon slots
    numSuggestions = 3,       -- number of spell icon slots to display (1–5)
    scale          = 1.0,
    locked         = false,
    showKeybind    = true,
    showCooldown   = false,   -- Rotation Assistant cooldown data is taint-protected; enable at your own risk
    showOutOfRange = true,
    showProcGlow   = true,    -- pulse border gold when the suggested spell has an active proc glow
    pollRate       = 0.05,   -- how often (seconds) to refresh while in combat
    sounds         = false,  -- subtle sound when icon appears in combat
    minimapAngle   = 225,    -- degrees around minimap (0=right, 90=top, 180=left, 270=bottom)
    minimapShow    = true,
    keybindFontSize = 10,   -- pt size for keybind label
    keybindColorR   = 1.0,  -- red channel (0–1)
    keybindColorG   = 1.0,  -- green channel (0–1)
    keybindColorB   = 1.0,  -- blue channel (0–1); use /hkl kbcolor 1 0.82 0 for WoW yellow
    showMode          = "always", -- "always" | "active" (in combat or attackable target)
    hideWhenDead      = true,
    hideWhenVehicle   = true,
    hideWhenCinematic = true,
    keybindOutline    = "OUTLINE",      -- "OUTLINE" | "THICKOUTLINE" | ""
    keybindAnchor     = "BOTTOMRIGHT",  -- "BOTTOMRIGHT" | "BOTTOMLEFT" | "TOPRIGHT" | "TOPLEFT" | "CENTER"
}

-- Spells auto-added to dbChar.ignoredSpells on first load for the matching
-- class. These are maintenance casts (pet re-summons, revives) that RA may
-- queue when a pet is absent but that clutter the rotation overlay.
-- Applied once via dbChar.classDefaultsApplied flag; user can remove entries.
local CLASS_DEFAULT_IGNORED = {
    WARLOCK = {
        [688]   = true,  -- Summon Imp
        [697]   = true,  -- Summon Voidwalker
        [691]   = true,  -- Summon Felhunter
        [712]   = true,  -- Summon Sayaad
        [30146] = true,  -- Summon Felguard
    },
    HUNTER = {
        [883]   = true,  -- Call Pet 1
        [83242] = true,  -- Call Pet 2
        [83243] = true,  -- Call Pet 3
        [83244] = true,  -- Call Pet 4
        [83245] = true,  -- Call Pet 5
        [982]   = true,  -- Revive Pet
    },
}

-- ── State ────────────────────────────────────────────────────────────────────

local db            -- points at HekiLightDB after ADDON_LOADED
local dbChar        -- points at HekiLightDBChar after ADDON_LOADED (per-character)
local inCombat    = false
local inCinematic = false
local elapsed     = 0
-- Spells with a real cooldown (base CD > 1.5 s) that the player has cast.
-- Used to grey secondary icons while the spell is on its real CD.
-- Populated by UNIT_SPELLCAST_SUCCEEDED; entries cleared by IsSpellOnCooldown
-- once IsSpellAvailable returns true (the secret-number pcall trick ensures
-- this only happens when the spell is truly off cooldown, not just off GCD).
local recentlyCastSpells = {}
local rangeTicker   -- C_Timer ticker for range overlay pulse animation
local glowTicker    -- C_Timer ticker for proc-glow border pulse animation
local isGlowActive  = false
local currentSuggestionID = nil  -- spellID currently displayed (used to filter glow events)
local slots    = {}  -- per-slot tables; populated by BuildSlots(); slots[1] is the primary slot
local MAX_SLOTS = 5  -- maximum number of icon slots (always created; extras hidden)

-- Pre-allocated suggestion queue — reused every poll to avoid per-frame table allocation.
-- GetSuggestionQueue wipes and repopulates these in-place; callers index queue[1..n].
local queueCache = {}
for i = 1, MAX_SLOTS do queueCache[i] = { spellID = nil, realSlotID = nil, onCooldown = false } end
local queueCount = 0  -- number of valid entries populated in the last GetSuggestionQueue call

-- Last non-empty result from C_AssistedCombat.GetRotationSpells().
-- Updated by GetSuggestionQueue whenever RA provides rotation data.
-- Used as a fallback by the Ignored Spells dropdown so it is never empty
-- after a reload even when the settings panel is opened before combat.
local cachedRotSpells = {}

-- ── Frames ───────────────────────────────────────────────────────────────────

-- Root container frame: handles positioning, dragging, and show/hide.
-- Individual slot sub-frames are created inside BuildSlots().
local display = CreateFrame("Frame", "HekiLightDisplay", UIParent)

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function InitDB()
    HekiLightDB = HekiLightDB or {}
    db = HekiLightDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    HekiLightDBChar = HekiLightDBChar or {}
    dbChar = HekiLightDBChar
    if dbChar.ignoredSpells == nil then dbChar.ignoredSpells = {} end
    if dbChar.classDefaultsApplied == nil then dbChar.classDefaultsApplied = false end
end

local function ApplyClassDefaultIgnores(rotSpells)
    if dbChar.classDefaultsApplied then return end
    local _, classID = UnitClass("player")
    local defaults = CLASS_DEFAULT_IGNORED[classID]
    if not defaults then
        dbChar.classDefaultsApplied = true
        return
    end
    for _, sid in ipairs(rotSpells) do
        if defaults[sid] then
            dbChar.ignoredSpells[sid] = true
        end
    end
    dbChar.classDefaultsApplied = true
end

local function ApplyPosition()
    display:ClearAllPoints()
    display:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
end

-- slot ID → binding command, built dynamically from actual button frames.
local SLOT_BINDINGS = {}

-- Called at PLAYER_LOGIN (frames are fully initialised by then).
-- Queries each Blizzard action button frame for its current action slot so
-- we never have to hard-code slot ranges that differ between game versions.
local function RebuildSlotBindings()
    wipe(SLOT_BINDINGS)

    -- Main bar: ActionButton1-12 (current page, slots 1-12 on page 1)
    for i = 1, 12 do
        local btn = _G["ActionButton" .. i]
        local slot = btn and (btn.action or (btn.GetAction and btn:GetAction()))
        SLOT_BINDINGS[slot or i] = "ACTIONBUTTON" .. i
    end

    -- Map all main bar pages (2–8) so spells on any page show their keybind.
    -- Page N slot i uses the same ACTIONBUTTON{i} binding command as page 1.
    for page = 2, 8 do
        for i = 1, 12 do
            local pageSlot = (page - 1) * 12 + i
            if not SLOT_BINDINGS[pageSlot] then
                SLOT_BINDINGS[pageSlot] = "ACTIONBUTTON" .. i
            end
        end
    end

    -- Extra bars: MultiBar* frames have fixed (non-paged) slot IDs
    local multiBarDefs = {
        { frameBase = "MultiBarBottomLeft",  bindBase = "MULTIACTIONBAR1BUTTON" },
        { frameBase = "MultiBarBottomRight", bindBase = "MULTIACTIONBAR2BUTTON" },
        { frameBase = "MultiBarRight",       bindBase = "MULTIACTIONBAR3BUTTON" },
        { frameBase = "MultiBarLeft",        bindBase = "MULTIACTIONBAR4BUTTON" },
    }
    for _, def in ipairs(multiBarDefs) do
        for i = 1, 12 do
            local btn = _G[def.frameBase .. "Button" .. i]
            if btn then
                local slot = btn.action or (btn.GetAction and btn:GetAction())
                if slot and slot > 0 then
                    SLOT_BINDINGS[slot] = def.bindBase .. i
                    Log("SlotMap:", slot, "→", def.bindBase .. i)
                end
            end
        end
    end
end

--- Shorten modifier prefixes for display.
local function FormatKey(key)
    return key:gsub("ALT%-",   "A-")
              :gsub("CTRL%-",  "C-")
              :gsub("SHIFT%-", "S-")
              :gsub("NUMPAD",  "N")
end

--- Return a short keybind string for an action slot, e.g. "C-1" or "F".
local function GetSlotKeybind(slotID)
    local bindCmd = SLOT_BINDINGS[slotID]
    local key = bindCmd and GetBindingKey(bindCmd)
    if not key or key == "" then return "" end
    return FormatKey(key)
end

--- Return a short keybind string for a spell, by finding the spell's real
--- action bar slot(s) and looking up the binding. Since we now always have
--- the spellID from GetActiveSuggestion(), we no longer need to extract it
--- from the Rotation Assistant slot first, and the texture-fallback scan is gone.
local function GetSpellKeybind(spellID)
    local actionSlots = C_ActionBar.FindSpellActionButtons(spellID)
    if actionSlots then
        for _, slot in ipairs(actionSlots) do
            if not C_ActionBar.IsAssistedCombatAction(slot) then
                local key = GetSlotKeybind(slot)
                if key ~= "" then
                    Log("GetSpellKeybind:", spellID, "→", key, "(slot", slot, ")")
                    return key
                end
            end
        end
    end
    Log("GetSpellKeybind:", spellID, "→ no keybind found")
    return ""
end

-- ── Visibility Gate ───────────────────────────────────────────────────────────

local function ShouldShow()
    -- Hard stops (always suppress regardless of mode)
    if db.hideWhenDead and UnitIsDeadOrGhost("player") then
        return false, "dead"
    end
    if db.hideWhenVehicle and (UnitInVehicle("player") or UnitHasVehicleUI("player")
            or HasVehicleActionBar() or HasOverrideActionBar()) then
        return false, "vehicle"
    end
    if db.hideWhenCinematic and inCinematic then
        return false, "cinematic"
    end
    -- Show mode
    local mode = db.showMode or "always"
    if mode == "always" then
        return true
    elseif mode == "active" then
        if inCombat then return true end
        if UnitCanAttack("player", "target") then return true end
        return false, "not in combat and no attackable target"
    end
    return true
end

local Refresh  -- forward declaration

-- ── UI Construction ───────────────────────────────────────────────────────────

-- Resize the container and reposition every slot sub-frame.
-- Call whenever iconSize, iconSpacing, or numSuggestions changes.
local function ApplySlotLayout()
    local n    = db.numSuggestions
    local size = db.iconSize
    local gap  = db.iconSpacing
    display:SetSize(n * size + (n - 1) * gap, size)
    for i = 1, MAX_SLOTS do
        if slots[i] then
            slots[i].frame:SetSize(size, size)
            slots[i].frame:SetPoint("TOPLEFT", display, "TOPLEFT", (i - 1) * (size + gap), 0)
        end
    end
end

local function ApplyKeybindStyle()
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if s and s.keybindText then
            s.keybindText:SetFont("Fonts\\ARIALN.TTF", db.keybindFontSize, db.keybindOutline or "OUTLINE")
            s.keybindText:SetTextColor(db.keybindColorR, db.keybindColorG, db.keybindColorB, 1)
        end
    end
end

local function ApplyKeybindAnchor()
    local anchor = db.keybindAnchor or "BOTTOMRIGHT"
    local offsets = {
        BOTTOMRIGHT = { -2,  3 },
        BOTTOMLEFT  = {  2,  3 },
        TOPRIGHT    = { -2, -3 },
        TOPLEFT     = {  2, -3 },
        CENTER      = {  0,  0 },
    }
    local off = offsets[anchor] or offsets["BOTTOMRIGHT"]
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if s and s.keybindText then
            s.keybindText:ClearAllPoints()
            s.keybindText:SetPoint(anchor, s.frame, anchor, off[1], off[2])
        end
    end
end

local function BuildSlots()
    display:SetScale(db.scale)
    display:SetFrameStrata("HIGH")
    display:SetFrameLevel(10)
    display:SetClampedToScreen(true)
    ApplyPosition()

    -- Play a subtle sound when the container first appears in combat
    display:SetScript("OnShow", function()
        if db and db.sounds then
            PlaySoundFile("Interface\\Buttons\\UI-CheckBox-Up.wav", "SFX")
        end
    end)

    -- Drag support on the container
    display:SetMovable(true)
    display:EnableMouse(not db.locked)
    display:RegisterForDrag("LeftButton")
    display:SetScript("OnDragStart", function(self)
        if not db.locked then self:StartMoving() end
    end)
    display:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        db.x = math.floor(x + 0.5)
        db.y = math.floor(y + 0.5)
    end)

    -- Create MAX_SLOTS slot sub-frames upfront; only numSuggestions are shown.
    wipe(slots)
    for i = 1, MAX_SLOTS do
        local slot = {}

        slot.frame = CreateFrame("Frame", nil, display, "BackdropTemplate")
        slot.frame:SetFrameLevel(display:GetFrameLevel() + 1)
        slot.frame:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile     = true,
            tileSize = 16,
            edgeSize = 16,
            insets   = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        slot.frame:SetBackdropColor(0, 0, 0, 0.7)
        slot.frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)

        -- Spell icon (ARTWORK so the backdrop border in BORDER layer renders above it)
        slot.iconTexture = slot.frame:CreateTexture(nil, "ARTWORK")
        slot.iconTexture:SetAllPoints(slot.frame)
        slot.iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        if i == 1 then
            -- Cooldown spiral (primary slot only)
            slot.cooldownFrame = CreateFrame("Cooldown", "HekiLightCooldown", slot.frame, "CooldownFrameTemplate")
            slot.cooldownFrame:SetAllPoints(slot.frame)
            slot.cooldownFrame:SetDrawEdge(true)
            slot.cooldownFrame:SetHideCountdownNumbers(false)

            -- Out-of-range red tint (primary slot only) — pulses so it's impossible to miss
            local rangeOvl = slot.frame:CreateTexture(nil, "OVERLAY")
            rangeOvl:SetAllPoints(slot.frame)
            rangeOvl:SetColorTexture(1, 0, 0, 0.35)
            rangeOvl:Hide()
            rangeOvl:SetScript("OnShow", function()
                local alpha, dir = 0.15, 1
                rangeTicker = C_Timer.NewTicker(0.05, function()
                    alpha = alpha + dir * 0.04
                    if alpha >= 0.5 then dir = -1 elseif alpha <= 0.1 then dir = 1 end
                    rangeOvl:SetAlpha(alpha)
                end)
            end)
            rangeOvl:SetScript("OnHide", function()
                if rangeTicker then rangeTicker:Cancel(); rangeTicker = nil end
            end)
            slot.rangeOverlay = rangeOvl
        end

        -- Keybind label — all slots get one; style/anchor applied below via ApplyKeybindStyle()/ApplyKeybindAnchor()
        slot.keybindText = slot.frame:CreateFontString(nil, "OVERLAY")

        slot.frame:Hide()
        slots[i] = slot
    end

    ApplySlotLayout()
    ApplyKeybindStyle()
    ApplyKeybindAnchor()
    display:Hide()
    Log("BuildSlots complete, maxSlots=", MAX_SLOTS, "showing=", db.numSuggestions)
end

-- ── Minimap Button ────────────────────────────────────────────────────────────

local minimapBtn
local settingsCategory

local function UpdateMinimapPos()
    local angle = math.rad(db.minimapAngle or 225)
    local r = (Minimap:GetWidth() / 2) + 5  -- dynamic: sits 5px outside the minimap edge
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER",
        r * math.cos(angle),
        r * math.sin(angle))
end

local function BuildMinimapButton()
    minimapBtn = CreateFrame("Button", "HekiLightMinimapButton", Minimap)
    minimapBtn:SetSize(32, 32)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)

    -- Background disc — same texture/size as LibDBIcon (24 px circular disc)
    local bg = minimapBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")
    bg:SetTexture(136467)  -- Interface\Minimap\UI-Minimap-Background

    local icon = minimapBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\ability_whirlwind")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)  -- 5% crop on each side (LibDBIcon standard)

    -- Overlay ring anchored at TOPLEFT — the circular ring masks the icon's square corners
    local border = minimapBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT")
    border:SetTexture(136430)  -- Interface\Minimap\MiniMap-TrackingBorder

    local hl = minimapBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetSize(32, 32)
    hl:SetPoint("CENTER")
    hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    hl:SetBlendMode("ADD")

    -- Drag to reposition around minimap edge
    minimapBtn:RegisterForDrag("LeftButton")
    minimapBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()  -- must match Minimap scale, not UIParent
            db.minimapAngle = math.deg(math.atan2((py / s) - my, (px / s) - mx))
            UpdateMinimapPos()
        end)
    end)
    minimapBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff88ccffHekiLight|r")
        GameTooltip:AddLine("Click to open settings", 1, 1, 1)
        GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapBtn:SetScript("OnClick", function()
        if settingsCategory then
            Settings.OpenToCategory(settingsCategory:GetID())
        end
    end)

    UpdateMinimapPos()
    if not db.minimapShow then minimapBtn:Hide() end
end

-- ── Settings Panel ────────────────────────────────────────────────────────────

local function BuildSettingsPanel()
    -- Outer panel: FIXED height — registered with canvas, never overflows.
    -- All scrollable content lives inside the UIPanelScrollFrameTemplate below.
    local panel = CreateFrame("Frame")
    panel.name = "HekiLight"
    panel:SetSize(620, 560)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("HekiLight")

    local version = C_AddOns.GetAddOnMetadata("HekiLight", "Version") or "?"
    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Rotation assistant icon overlay  |cff666666v" .. version .. "|r")

    -- ScrollFrame: sits below the title, leaves 36 px at the bottom for the Reset button.
    local scrollFrame = CreateFrame("ScrollFrame", "HekiLightScrollFrame", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -52)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 36)

    -- Content frame: scroll child. Width fixed; height computed by LayoutSections().
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(592)   -- 620 - 28 (scrollbar)
    scrollFrame:SetScrollChild(content)

    -- Hide the scrollbar when all content fits; show it when content overflows.
    -- OnScrollRangeChanged fires every time the scroll extent is recalculated.
    local scrollBar = _G["HekiLightScrollFrameScrollBar"]
    if scrollBar then
        scrollFrame:SetScript("OnScrollRangeChanged", function(self, _, yRange)
            scrollBar:SetShown(yRange and yRange > 0)
        end)
    end

    -- ── Collapsible section system ────────────────────────────────────────────
    local sectionList = {}

    local function LayoutSections()
        local y = -8
        for _, sec in ipairs(sectionList) do
            sec.header:ClearAllPoints()
            sec.header:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, y)
            sec.header:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
            y = y - 26
            if sec.isExpanded then
                sec.body:ClearAllPoints()
                sec.body:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
                sec.body:SetWidth(592)
                sec.body:Show()
                y = y - sec.body:GetHeight() - 4
            else
                sec.body:Hide()
            end
        end
        content:SetHeight(math.abs(y) + 20)
    end

    local function MakeSection(label, startExpanded)
        if startExpanded == nil then startExpanded = true end
        local hdr = CreateFrame("Button", nil, content, "BackdropTemplate")
        hdr:SetHeight(26)
        hdr:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        hdr:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
        hdr:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        local lbl = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", 10, 0)
        lbl:SetText("|cffffcc00" .. label .. "|r")
        local toggle = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        toggle:SetPoint("RIGHT", -10, 0)
        toggle:SetText(startExpanded and "-" or "+")
        local body = CreateFrame("Frame", nil, content)
        body:SetWidth(592)
        body:SetHeight(10)
        body:SetShown(startExpanded)
        local sec = { header = hdr, body = body, isExpanded = startExpanded }
        hdr:SetScript("OnClick", function()
            sec.isExpanded = not sec.isExpanded
            toggle:SetText(sec.isExpanded and "-" or "+")
            LayoutSections()
        end)
        sectionList[#sectionList + 1] = sec
        return sec, body
    end

    -- ── Widget helpers: (parent, cur, ...) where cur = {y = -8} ─────────────
    local checkboxRefs  = {}
    local sliderRefs    = {}
    local radioRefs     = {}
    local panelUpdating = false

    local function CB(parent, cur, label, tip, getValue, setValue)
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 10, cur.y)
        cb.text:SetText(label)
        cb:SetChecked(getValue())
        cb:SetScript("OnClick", function(self) setValue(self:GetChecked()) end)
        if tip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(label)
                GameTooltip:AddLine(tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        checkboxRefs[#checkboxRefs + 1] = { cb = cb, getValue = getValue }
        cur.y = cur.y - 28
    end

    local function SL(parent, cur, label, min, max, step, getValue, setValue, tip)
        local labelStr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        labelStr:SetPoint("TOPLEFT", 14, cur.y)
        labelStr:SetText(label .. ": " .. getValue())
        local slider = CreateFrame("Slider", nil, parent, "BackdropTemplate")
        slider:SetPoint("TOPLEFT", 14, cur.y - 20)
        slider:SetSize(240, 17)
        slider:SetOrientation("HORIZONTAL")
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        slider:SetBackdrop({
            bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
        slider:SetMinMaxValues(min, max)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)
        slider:SetValue(getValue())
        slider:SetScript("OnValueChanged", function(self, val)
            if not panelUpdating then setValue(val) end
            labelStr:SetText(label .. ": " .. val)
        end)
        if tip then
            slider:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(label)
                GameTooltip:AddLine(tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            slider:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        sliderRefs[#sliderRefs + 1] = { slider = slider, labelStr = labelStr,
                                        label = label, step = step, getValue = getValue }
        cur.y = cur.y - 52
    end

    local function RG(parent, cur, options, getValue, setValue)
        local refs = {}
        for _, opt in ipairs(options) do
            local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
            cb:SetPoint("TOPLEFT", 10, cur.y)
            cb.text:SetText(opt.label)
            cb:SetChecked(getValue() == opt.value)
            local capturedValue = opt.value
            cb:SetScript("OnClick", function()
                setValue(capturedValue)
                for _, r in ipairs(refs) do r.cb:SetChecked(r.value == capturedValue) end
                Refresh()
            end)
            if opt.tip then
                cb:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(opt.label)
                    GameTooltip:AddLine(opt.tip, 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            refs[#refs + 1] = { cb = cb, value = opt.value }
            cur.y = cur.y - 28
        end
        radioRefs[#radioRefs + 1] = { refs = refs, getValue = getValue }
        return refs
    end

    local function SubHdr(parent, cur, label)
        local s = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        s:SetPoint("TOPLEFT", 10, cur.y)
        s:SetText("|cffaaaaaa" .. label .. "|r")
        cur.y = cur.y - 20
    end

    -- ── Section: Appearance ──────────────────────────────────────────────────
    local _, appBody = MakeSection("Appearance")
    local cur = { y = -8 }
    SL(appBody, cur, "Overall Scale", 0.2, 3.0, 0.1,
        function() return db.scale end,
        function(v) db.scale = v; display:SetScale(v) end,
        "Scales the entire HekiLight overlay — icons, spacing, and keybind text.")
    SL(appBody, cur, "Icon Size", 16, 256, 8,
        function() return db.iconSize end,
        function(v) db.iconSize = v; ApplySlotLayout(); Refresh() end,
        "Sets the raw pixel size of the spell icon texture.")
    SL(appBody, cur, "Spell Icon Slots", 1, 5, 1,
        function() return db.numSuggestions end,
        function(v) db.numSuggestions = v; ApplySlotLayout(); Refresh() end,
        "Number of spell icons to display (1 = primary only, up to 5).")
    SL(appBody, cur, "Icon Spacing", 0, 32, 2,
        function() return db.iconSpacing end,
        function(v) db.iconSpacing = v; ApplySlotLayout(); Refresh() end)
    SL(appBody, cur, "Refresh Rate (s)", 0.02, 0.5, 0.01,
        function() return db.pollRate end,
        function(v) db.pollRate = v end,
        "How often (seconds) the suggestion bar refreshes.")
    CB(appBody, cur, "Lock position",
        "Prevent the icon from being accidentally dragged. Use /hkl unlock to reposition it.",
        function() return db.locked end,
        function(v)
            db.locked = v
            display:EnableMouse(not v)
            print("|cff88ccffHekiLight:|r Position " .. (v and "locked." or "unlocked — drag to reposition."))
        end)
    appBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Display ─────────────────────────────────────────────────────
    local _, dispBody = MakeSection("Display")
    cur = { y = -8 }
    CB(dispBody, cur, "Show keybind text",
        "Show the keybind for the suggested spell in the corner of the icon.",
        function() return db.showKeybind end,
        function(v) db.showKeybind = v; if not v then for i = 1, MAX_SLOTS do if slots[i] and slots[i].keybindText then slots[i].keybindText:Hide() end end end end)
    CB(dispBody, cur, "Show out-of-range tint",
        "Pulse the icon red when the suggested spell cannot reach your target.",
        function() return db.showOutOfRange end,
        function(v) db.showOutOfRange = v; if not v and slots[1] and slots[1].rangeOverlay then slots[1].rangeOverlay:Hide() end end)
    CB(dispBody, cur, "Spell Proc Glow",
        "Pulse the icon border gold when the suggested spell has an active proc glow.",
        function() return db.showProcGlow end,
        function(v) db.showProcGlow = v; if not v then StopGlowPulse() end end)
    CB(dispBody, cur, "Show cooldown spiral",
        "Display a cooldown sweep on the icon.",
        function() return db.showCooldown end,
        function(v) db.showCooldown = v; if not v and slots[1] and slots[1].cooldownFrame then slots[1].cooldownFrame:Hide() end end)
    CB(dispBody, cur, "Play sounds",
        "Play a subtle click when the icon appears as you enter combat.",
        function() return db.sounds end,
        function(v) db.sounds = v end)
    CB(dispBody, cur, "Show minimap button",
        "Show the HekiLight button on the minimap. Drag it to reposition.",
        function() return db.minimapShow ~= false end,
        function(v) db.minimapShow = v; if minimapBtn then minimapBtn:SetShown(v) end end)
    dispBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Keybind Style ───────────────────────────────────────────────
    local _, kbBody = MakeSection("Keybind Style")
    cur = { y = -8 }
    SL(kbBody, cur, "Font Size", 8, 24, 1,
        function() return db.keybindFontSize end,
        function(v) db.keybindFontSize = v; ApplyKeybindStyle(); Refresh() end)

    -- Color label + swatch (not a standard widget, built inline)
    local colorLblStr = kbBody:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLblStr:SetPoint("TOPLEFT", 14, cur.y)
    colorLblStr:SetText("Color")
    cur.y = cur.y - 22
    local colorSwatch = CreateFrame("Button", nil, kbBody, "BackdropTemplate")
    colorSwatch:SetSize(80, 20)
    colorSwatch:SetPoint("TOPLEFT", 14, cur.y)
    colorSwatch:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    colorSwatch:SetBackdropColor(db.keybindColorR, db.keybindColorG, db.keybindColorB, 1)
    colorSwatch:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    colorSwatch:SetScript("OnClick", function()
        ColorPickerFrame:SetupColorPickerAndShow({
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                db.keybindColorR, db.keybindColorG, db.keybindColorB = r, g, b
                colorSwatch:SetBackdropColor(r, g, b, 1)
                ApplyKeybindStyle()
            end,
            cancelFunc = function(prev)
                db.keybindColorR, db.keybindColorG, db.keybindColorB = prev.r, prev.g, prev.b
                colorSwatch:SetBackdropColor(prev.r, prev.g, prev.b, 1)
                ApplyKeybindStyle()
            end,
            hasOpacity = false,
            r = db.keybindColorR, g = db.keybindColorG, b = db.keybindColorB,
        })
    end)
    colorSwatch:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Keybind Color")
        GameTooltip:AddLine("Click to open the color picker.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    colorSwatch:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cur.y = cur.y - 28

    SubHdr(kbBody, cur, "Outline Style")
    RG(kbBody, cur, {
        { label = "Outline",       value = "OUTLINE",      tip = "Thin border around each character." },
        { label = "Thick Outline", value = "THICKOUTLINE", tip = "Bold border — readable at small sizes." },
        { label = "None",          value = "",             tip = "No outline — flat text." },
    }, function() return db.keybindOutline or "OUTLINE" end,
       function(v) db.keybindOutline = v; ApplyKeybindStyle() end)

    SubHdr(kbBody, cur, "Corner Position")
    RG(kbBody, cur, {
        { label = "Bottom Right", value = "BOTTOMRIGHT" },
        { label = "Bottom Left",  value = "BOTTOMLEFT"  },
        { label = "Top Right",    value = "TOPRIGHT"    },
        { label = "Top Left",     value = "TOPLEFT"     },
        { label = "Center",       value = "CENTER"      },
    }, function() return db.keybindAnchor or "BOTTOMRIGHT" end,
       function(v) db.keybindAnchor = v; ApplyKeybindAnchor() end)
    kbBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Visibility ──────────────────────────────────────────────────
    local _, visBody = MakeSection("Visibility")
    cur = { y = -8 }
    SubHdr(visBody, cur, "Show Overlay")
    RG(visBody, cur, {
        { label = "Always",
          value = "always",
          tip   = "Show the overlay whenever Rotation Assistant has a suggestion." },
        { label = "In Combat or Attackable Target",
          value = "active",
          tip   = "Only show when in combat, or when you have an attackable target selected." },
    }, function() return db.showMode or "always" end,
       function(v) db.showMode = v end)
    SubHdr(visBody, cur, "Always Hide When")
    CB(visBody, cur, "Dead or Ghost",
        "Hide the overlay while you are dead or a ghost.",
        function() return db.hideWhenDead end,
        function(v) db.hideWhenDead = v; Refresh() end)
    CB(visBody, cur, "In a cinematic",
        "Hide the overlay during in-game cinematics and movies.",
        function() return db.hideWhenCinematic end,
        function(v) db.hideWhenCinematic = v; Refresh() end)
    CB(visBody, cur, "In a vehicle",
        "Hide the overlay while riding a vehicle with its own action bar.",
        function() return db.hideWhenVehicle end,
        function(v) db.hideWhenVehicle = v; Refresh() end)
    visBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Ignored Spells (collapsed by default) ───────────────────────
    local ignoreSec, ignoreBody = MakeSection("Ignored Spells", false)

    local ignoreDesc = ignoreBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ignoreDesc:SetPoint("TOPLEFT", 10, -8)
    ignoreDesc:SetWidth(570)
    ignoreDesc:SetJustifyH("LEFT")
    ignoreDesc:SetText("Spells hidden from the secondary suggestion list. Select a spell and click Add.\n|cffaaaaaa Requires Rotation Assistant to be active.|r")

    local selectedIgnoreSpellID = nil
    local rowPool = {}
    local ignoreEmptyLabel = nil
    local RefreshIgnoreList      -- forward declaration

    -- UIDropDownMenu has ~18 px inherent left padding; offset by -2 to align
    local ignoreDD = CreateFrame("Frame", "HekiLightIgnoreDropdown", ignoreBody, "UIDropDownMenuTemplate")
    ignoreDD:SetPoint("TOPLEFT", -2, -46)
    UIDropDownMenu_SetWidth(ignoreDD, 240)
    UIDropDownMenu_SetText(ignoreDD, "Select a rotation spell...")

    local addBtn = CreateFrame("Button", nil, ignoreBody, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", ignoreDD, "RIGHT", -4, 2)
    addBtn:SetSize(130, 22)
    addBtn:SetText("Add to ignore list")
    addBtn:SetScript("OnClick", function()
        if not selectedIgnoreSpellID then
            print("|cff88ccffHekiLight:|r Select a spell from the dropdown first.")
            return
        end
        if dbChar.ignoredSpells[selectedIgnoreSpellID] then
            print("|cff88ccffHekiLight:|r That spell is already ignored.")
            return
        end
        dbChar.ignoredSpells[selectedIgnoreSpellID] = true
        local si = C_Spell.GetSpellInfo(selectedIgnoreSpellID)
        local name = si and si.name or tostring(selectedIgnoreSpellID)
        print("|cff88ccffHekiLight:|r " .. name .. " [" .. selectedIgnoreSpellID .. "] will no longer appear in the secondary list.")
        selectedIgnoreSpellID = nil
        UIDropDownMenu_SetText(ignoreDD, "Select a rotation spell...")
        RefreshIgnoreList()
    end)

    local ignoreListBaseY = -82  -- below the dropdown row

    -- Dropdown initializer: data fetched live on every open (never stale)
    UIDropDownMenu_Initialize(ignoreDD, function(self, level)
        local entries = {}
        local ok, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
        if not (ok and type(rotSpells) == "table" and #rotSpells > 0) then
            rotSpells = cachedRotSpells
        end
        for _, sid in ipairs(rotSpells) do
            if IsPlayerSpell(sid) then
                local si = C_Spell.GetSpellInfo(sid)
                if si then
                    entries[#entries + 1] = {
                        sid     = sid,
                        name    = si.name,
                        iconID  = si.iconID,
                        ignored = dbChar.ignoredSpells[sid],
                    }
                end
            end
        end
        if #entries == 0 then
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = "|cff888888No rotation spells available|r"
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
            return
        end
        for _, entry in ipairs(entries) do
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = (entry.ignored and "|cff888888" or "")
                            .. entry.name
                            .. "  |cff666666[" .. entry.sid .. "]|r"
                            .. (entry.ignored and " (hidden)|r" or "")
            info.icon     = entry.iconID
            info.disabled = entry.ignored
            if not entry.ignored then
                local capturedSid  = entry.sid
                local capturedName = entry.name
                info.func = function()
                    selectedIgnoreSpellID = capturedSid
                    UIDropDownMenu_SetText(ignoreDD, capturedName .. " [" .. capturedSid .. "]")
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    RefreshIgnoreList = function()
        for _, row in ipairs(rowPool) do row:Hide() end
        local sorted = {}
        for sid in pairs(dbChar.ignoredSpells) do sorted[#sorted + 1] = sid end
        table.sort(sorted)
        local rowIdx = 0
        for _, sid in ipairs(sorted) do
            rowIdx = rowIdx + 1
            local row = rowPool[rowIdx]
            if not row then
                row = CreateFrame("Frame", nil, ignoreBody)
                row:SetSize(570, 24)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(20, 20)
                row.icon:SetPoint("LEFT", 4, 0)
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.label:SetWidth(460)
                row.label:SetJustifyH("LEFT")
                row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.removeBtn:SetSize(70, 20)
                row.removeBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                row.removeBtn:SetText("Remove")
                rowPool[rowIdx] = row
            end
            local capturedSid = sid
            local si = C_Spell.GetSpellInfo(sid)
            row.icon:SetTexture(si and si.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.label:SetText((si and si.name or "(unknown)") .. "  |cff888888[" .. sid .. "]|r")
            row.removeBtn:SetScript("OnClick", function()
                dbChar.ignoredSpells[capturedSid] = nil
                RefreshIgnoreList()
            end)
            row:SetPoint("TOPLEFT", 10, ignoreListBaseY - (rowIdx - 1) * 30)
            row:Show()
        end
        if not ignoreEmptyLabel then
            ignoreEmptyLabel = ignoreBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            ignoreEmptyLabel:SetPoint("TOPLEFT", 10, ignoreListBaseY)
            ignoreEmptyLabel:SetText("No spells are currently ignored.")
        end
        ignoreEmptyLabel:SetShown(rowIdx == 0)
        ignoreBody:SetHeight(math.abs(ignoreListBaseY) + math.max(rowIdx * 30, 20) + 16)
        LayoutSections()
    end

    local function CountRotationSpells()
        local ok, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
        if ok and type(rotSpells) == "table" and #rotSpells > 0 then
            wipe(cachedRotSpells)
            for i, sid in ipairs(rotSpells) do cachedRotSpells[i] = sid end
        else
            rotSpells = cachedRotSpells
        end
        local n = 0
        for _, sid in ipairs(rotSpells) do if IsPlayerSpell(sid) then n = n + 1 end end
        return n
    end

    local function UpdateDropdownHint()
        if selectedIgnoreSpellID then return end
        local n = CountRotationSpells()
        if n > 0 then
            UIDropDownMenu_SetText(ignoreDD, n .. " spell" .. (n == 1 and "" or "s") .. " available — click to select")
        else
            UIDropDownMenu_SetText(ignoreDD, "Select a rotation spell...")
        end
    end

    -- Wrap the section toggle to start/stop the hint ticker
    local origIgnoreClick = ignoreSec.header:GetScript("OnClick")
    ignoreSec.header:SetScript("OnClick", function(self)
        origIgnoreClick(self)
        if ignoreSec.isExpanded then
            RefreshIgnoreList()
            UpdateDropdownHint()
            if not ignoreSec.ticker then
                ignoreSec.ticker = C_Timer.NewTicker(0.5, UpdateDropdownHint)
            end
        else
            if ignoreSec.ticker then ignoreSec.ticker:Cancel(); ignoreSec.ticker = nil end
        end
    end)

    -- ── Reset button (anchored to panel, always visible outside the scroll) ──
    local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(140, 22)
    resetBtn:SetPoint("BOTTOMLEFT", 16, 8)
    resetBtn:SetText("Reset to Defaults")
    resetBtn:SetScript("OnClick", function()
        wipe(db)
        for k, v in pairs(DEFAULTS) do db[k] = v end
        ApplyPosition()
        display:SetScale(db.scale)
        ApplySlotLayout()
        ApplyKeybindStyle()
        ApplyKeybindAnchor()
        Refresh()
        for _, ref in ipairs(checkboxRefs) do ref.cb:SetChecked(ref.getValue()) end
        for _, entry in ipairs(radioRefs) do
            local val = entry.getValue()
            for _, r in ipairs(entry.refs) do r.cb:SetChecked(r.value == val) end
        end
        panelUpdating = true
        for _, ref in ipairs(sliderRefs) do
            local v = ref.getValue()
            ref.slider:SetValue(v)
            ref.labelStr:SetText(ref.label .. ": " .. v)
        end
        panelUpdating = false
        colorSwatch:SetBackdropColor(db.keybindColorR, db.keybindColorG, db.keybindColorB, 1)
        print("|cff88ccffHekiLight:|r All settings reset to defaults.")
    end)

    -- ── OnShow / OnHide sync ─────────────────────────────────────────────────
    panel:SetScript("OnShow", function()
        for _, ref in ipairs(checkboxRefs) do ref.cb:SetChecked(ref.getValue()) end
        for _, entry in ipairs(radioRefs) do
            local val = entry.getValue()
            for _, r in ipairs(entry.refs) do r.cb:SetChecked(r.value == val) end
        end
        panelUpdating = true
        for _, ref in ipairs(sliderRefs) do
            local v = ref.getValue()
            ref.slider:SetValue(v)
            ref.labelStr:SetText(ref.label .. ": " .. v)
        end
        panelUpdating = false
        colorSwatch:SetBackdropColor(db.keybindColorR, db.keybindColorG, db.keybindColorB, 1)
        if ignoreSec.isExpanded then
            RefreshIgnoreList()
            UpdateDropdownHint()
            if not ignoreSec.ticker then
                ignoreSec.ticker = C_Timer.NewTicker(0.5, UpdateDropdownHint)
            end
        end
    end)

    panel:SetScript("OnHide", function()
        if ignoreSec.ticker then ignoreSec.ticker:Cancel(); ignoreSec.ticker = nil end
    end)

    LayoutSections()

    settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "HekiLight")
    Settings.RegisterAddOnCategory(settingsCategory)
end

-- ── Spell Suggestion Detection ───────────────────────────────────────────────

-- Returns true if spellID can be cast right now (off cooldown / has a charge).
-- Uses the secret-number pcall trick on C_Spell.GetSpellCooldown:
--   • duration == 0 (off CD / has a charge) → plain 0 → comparison succeeds → true
--   • duration > 0 (on CD / no charges left) → secret value → comparison throws
--     → pcall catches the error → returns false
local function IsSpellAvailable(spellID)
    local available = false
    pcall(function()
        local cd = C_Spell.GetSpellCooldown(spellID)
        if cd and cd.duration == 0 then
            available = true
        end
    end)
    return available
end

-- Returns true when spellID has been cast and is still on its real cooldown.
-- Only spells with GetSpellBaseCooldown > 1500 ms are ever tracked (filters
-- out GCD-only spells). IsSpellAvailable uses the secret-number pcall trick —
-- it returns true only when duration is plain 0, which means truly off CD
-- (not just off GCD), so no grace period is needed.
local function IsSpellOnCooldown(sid)
    if not recentlyCastSpells[sid] then return false end
    if IsSpellAvailable(sid) then
        recentlyCastSpells[sid] = nil
        return false
    end
    return true
end


local function IsAssistActive()
    return C_ActionBar.HasAssistedCombatActionButtons()
        or GetCVarBool("assistedCombatHighlight")
end

-- Returns the suggested spellID from the rotation engine, plus the first
-- regular action bar slot that contains it for range/keybind checks.
--
-- Detection order:
--   1. C_AssistedCombat.GetNextCastSpell(false) — direct engine query; works
--      with either Rotation Assistant button or Assisted Highlight (or both).
--   2. Fallback: derive spellID from the Rotation Assistant slot via GetActionInfo.
--      Keeps the old behaviour for any edge case where GetNextCastSpell is nil.
local function GetActiveSuggestion()
    local spellID

    -- Primary path: ask the rotation engine directly (Midnight 12.0+).
    -- checkForVisibleButton=false means "give me the suggestion even if the
    -- Rotation Assistant button is hidden / not on the bar."
    if C_AssistedCombat.GetNextCastSpell then
        local ok
        ok, spellID = pcall(C_AssistedCombat.GetNextCastSpell, false)
        if not ok then spellID = nil end
        Log("GetNextCastSpell →", tostring(spellID))
    end

    -- Fallback: Rotation Assistant slot → GetActionInfo → spellID (old path; safety net).
    if not spellID then
        -- Find the Rotation Assistant slot the old way.
        local sbaSlot
        if C_ActionBar.HasAssistedCombatActionButtons() then
            local sbaSlots = C_ActionBar.FindAssistedCombatActionButtons()
            if sbaSlots and #sbaSlots > 0 then
                sbaSlot = sbaSlots[1]
            else
                for slot = 1, 120 do
                    if C_ActionBar.IsAssistedCombatAction(slot) then
                        sbaSlot = slot; break
                    end
                end
            end
        end
        if sbaSlot then
            local ok
            ok, spellID = pcall(function()
                local t, id = GetActionInfo(sbaSlot)
                return (t == "spell") and id or nil
            end)
            if not ok then spellID = nil end
            Log("Fallback Rotation Assistant slot", tostring(sbaSlot), "→ spellID", tostring(spellID))
        end
    end

    if not spellID then
        Log("No active suggestion found")
        return nil, nil
    end

    -- Find a regular action bar slot for this spell so we can do
    -- range checks and keybind lookups against the player's actual bars.
    local realSlotID
    local actionSlots = C_ActionBar.FindSpellActionButtons(spellID)
    if actionSlots then
        for _, slot in ipairs(actionSlots) do
            if not C_ActionBar.IsAssistedCombatAction(slot) then
                realSlotID = slot
                break
            end
        end
    end
    Log("Active suggestion: spellID=", spellID, "realSlot=", tostring(realSlotID))
    return spellID, realSlotID
end

-- Returns the first regular action bar slot for a spellID.
-- Used for range checks and keybind lookups on secondary rotation spells.
local function GetRealSlot(spellID)
    local slotList = C_ActionBar.FindSpellActionButtons(spellID)
    if slotList then
        for _, slot in ipairs(slotList) do
            if not C_ActionBar.IsAssistedCombatAction(slot) then
                return slot
            end
        end
    end
    return nil
end

-- Returns up to n { spellID, realSlotID } entries representing the current
-- rotation queue.  Slot 1 is always the active Rotation Assistant suggestion (GetNextCastSpell).
-- Slots 2..n come from C_AssistedCombat.GetRotationSpells() (Midnight 12.0+).
--
-- Two-pass fill: pass 1 adds spells with no real cooldown (duration ≤1.5s),
-- pass 2 fills remaining slots with on-CD spells (shown greyed out).
local function GetSuggestionQueue(n)
    -- Wipe entries from the previous call so stale spellIDs are never read.
    for i = 1, queueCount do
        queueCache[i].spellID    = nil
        queueCache[i].realSlotID = nil
        queueCache[i].onCooldown = false
    end
    queueCount = 0

    local primaryID, primarySlot = GetActiveSuggestion()
    queueCount = 1
    queueCache[1].spellID   = primaryID
    queueCache[1].realSlotID = primarySlot

    if n > 1 and C_AssistedCombat.GetRotationSpells then
        local ok, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
        if ok and rotSpells then
            -- Keep a session-level copy so the Ignored Spells dropdown can
            -- fall back to this if RA hasn't been queried yet when the panel opens.
            if #rotSpells > 0 then
                wipe(cachedRotSpells)
                for i, sid in ipairs(rotSpells) do cachedRotSpells[i] = sid end
                ApplyClassDefaultIgnores(rotSpells)
            end
            -- Pass 1: off-cooldown spells fill slots first (high priority)
            for _, sid in ipairs(rotSpells) do
                if queueCount >= n then break end
                if sid ~= primaryID and not dbChar.ignoredSpells[sid] and IsPlayerSpell(sid) then
                    if not IsSpellOnCooldown(sid) then
                        queueCount = queueCount + 1
                        queueCache[queueCount].spellID    = sid
                        queueCache[queueCount].realSlotID = GetRealSlot(sid)
                        queueCache[queueCount].onCooldown = false
                    end
                end
            end
            -- Pass 2: on-cooldown spells fill any remaining slots (low priority, greyed out)
            if queueCount < n then
                for _, sid in ipairs(rotSpells) do
                    if queueCount >= n then break end
                    if sid ~= primaryID and not dbChar.ignoredSpells[sid] and IsPlayerSpell(sid) then
                        if IsSpellOnCooldown(sid) then
                            queueCount = queueCount + 1
                            queueCache[queueCount].spellID    = sid
                            queueCache[queueCount].realSlotID = GetRealSlot(sid)
                            queueCache[queueCount].onCooldown = true
                        end
                    end
                end
            end
        end
    end

    return queueCache
end

-- ── Core Update Logic ─────────────────────────────────────────────────────────

-- ── Proc-Glow Border Pulse ────────────────────────────────────────────────────

local function StopGlowPulse()
    if glowTicker then glowTicker:Cancel(); glowTicker = nil end
    isGlowActive = false
    -- Restore normal border color on the primary slot
    if slots[1] and slots[1].frame then
        slots[1].frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
    end
end

local function StartGlowPulse()
    if isGlowActive then return end  -- already running
    isGlowActive = true
    local t, dir = 0, 1
    glowTicker = C_Timer.NewTicker(0.05, function()
        t = t + dir * 0.06
        if t >= 1 then t = 1; dir = -1
        elseif t <= 0 then t = 0; dir = 1 end
        -- Lerp border from gray (0.5,0.5,0.5) → gold (1,0.85,0) on the primary slot
        if slots[1] and slots[1].frame then
            slots[1].frame:SetBackdropBorderColor(
                0.5 + 0.5  * t,
                0.5 + 0.35 * t,
                0.5 - 0.5  * t,
                0.9)
        end
    end)
end

local function UpdateGlowState(spellID)
    if db.showProcGlow and C_SpellActivationOverlay.IsSpellOverlayed(spellID) then
        StartGlowPulse()
    else
        StopGlowPulse()
    end
end


Refresh = function()
    if #slots == 0 then return end  -- BuildSlots not yet called

    local showOk, reason = ShouldShow()
    if not showOk then
        currentSuggestionID = nil
        StopGlowPulse()
        display:Hide()
        Log("display suppressed — reason:", reason)
        return
    end

    local queue   = GetSuggestionQueue(db.numSuggestions)
    local primary = queue[1]

    if not primary or not primary.spellID then
        Log("No active suggestion — hiding display")
        currentSuggestionID = nil
        StopGlowPulse()
        display:Hide()
        return
    end

    local primaryInfo = C_Spell.GetSpellInfo(primary.spellID)
    if not primaryInfo or not primaryInfo.iconID then
        Log("No spell info for", primary.spellID, "— hiding display")
        currentSuggestionID = nil
        StopGlowPulse()
        display:Hide()
        return
    end

    -- Update each slot's icon texture
    for i = 1, db.numSuggestions do
        local slot  = slots[i]
        local entry = queue[i]
        if entry and entry.spellID then
            local si = (i == 1) and primaryInfo or C_Spell.GetSpellInfo(entry.spellID)
            if si and si.iconID then
                slot.iconTexture:SetTexture(si.iconID)
                slot.iconTexture:SetDesaturated(i > 1 and entry.onCooldown)
                slot.frame:Show()
                if db.showKeybind and slot.keybindText then
                    slot.keybindText:SetText(GetSpellKeybind(entry.spellID))
                    slot.keybindText:Show()
                elseif slot.keybindText then
                    slot.keybindText:Hide()
                end
            else
                slot.iconTexture:SetDesaturated(false)
                slot.frame:Hide()
                if slot.keybindText then slot.keybindText:Hide() end
            end
        else
            slot.iconTexture:SetDesaturated(false)
            slot.frame:Hide()
            if slot.keybindText then slot.keybindText:Hide() end
        end
    end

    -- Hide slots beyond numSuggestions (guards against numSuggestions being reduced)
    for i = db.numSuggestions + 1, MAX_SLOTS do
        if slots[i] then slots[i].frame:Hide() end
    end

    -- Primary-slot decorations (slot 1 only)
    local s1    = slots[1]
    local sid   = primary.spellID
    local rslot = primary.realSlotID
    Log("Showing spellID", sid, "iconID", primaryInfo.iconID, "realSlot", tostring(rslot))

    currentSuggestionID = sid
    UpdateGlowState(sid)

    -- Cooldown — use C_Spell API (no slot needed; taint guard still applies)
    if db.showCooldown and s1.cooldownFrame then
        local ok = pcall(function()
            local cd = C_Spell.GetSpellCooldown(sid)
            local startTime = cd and cd.startTime or 0
            if startTime > 0 then
                s1.cooldownFrame:SetCooldown(startTime, cd.duration or 0)
                s1.cooldownFrame:Show()
            else
                s1.cooldownFrame:Hide()
            end
        end)
        if not ok then s1.cooldownFrame:Hide() end
    elseif s1.cooldownFrame then
        s1.cooldownFrame:Hide()
    end

    -- Range indicator — requires a real action bar slot; hide if none found
    if db.showOutOfRange and rslot and s1.rangeOverlay then
        local inRange = C_ActionBar.IsActionInRange(rslot)
        -- inRange: true = in range, false = out of range, nil = no range requirement
        s1.rangeOverlay:SetShown(inRange == false)
    elseif s1.rangeOverlay then
        s1.rangeOverlay:Hide()
    end

    display:Show()
    Log("display:Show() — numSuggestions:", db.numSuggestions,
        "x:", db.x, "y:", db.y)
end

-- ── Combat Polling ────────────────────────────────────────────────────────────
-- OnUpdate fires at the configured poll rate and calls Refresh() to track
-- the Rotation Assistant suggestion. Only runs when Rotation Assistant is active AND the player is in combat.
local function OnUpdate(_, dt)
    elapsed = elapsed + dt
    if elapsed >= db.pollRate then
        elapsed = 0
        Refresh()
    end
end

-- Start the poll loop only when Rotation Assistant is actually configured and we're in combat.
-- Called from combat-start and from action bar change events so the loop can
-- activate mid-combat if the player adds the Rotation Assistant button during a fight.
local function StartPollLoop()
    elapsed = db.pollRate  -- fire on the very next frame
    display:SetScript("OnUpdate", OnUpdate)
    Log("Poll loop started")
end

local function StopPollLoop()
    display:SetScript("OnUpdate", nil)
    currentSuggestionID = nil
    StopGlowPulse()
    Log("Poll loop stopped")
end

-- ── Event Handling ────────────────────────────────────────────────────────────

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_DISABLED")   -- combat start
events:RegisterEvent("PLAYER_REGEN_ENABLED")    -- combat end
events:RegisterEvent("UPDATE_BINDINGS")
events:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
events:RegisterEvent("ACTIONBAR_UPDATE_STATE")  -- fires when Rotation Assistant changes highlight
events:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")  -- proc glow appears
events:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")  -- proc glow fades
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")             -- track real-CD casts for grey filter
events:RegisterEvent("UNIT_FLAGS")
events:RegisterEvent("UNIT_HEALTH")
events:RegisterEvent("UNIT_ENTERED_VEHICLE")
events:RegisterEvent("UNIT_EXITED_VEHICLE")
events:RegisterEvent("CINEMATIC_START")
events:RegisterEvent("CINEMATIC_STOP")
events:RegisterEvent("PLAY_MOVIE")
events:RegisterEvent("STOP_MOVIE")
events:RegisterEvent("PLAYER_TARGET_CHANGED")

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildSlots()
        BuildMinimapButton()
        BuildSettingsPanel()

    elseif event == "PLAYER_ENTERING_WORLD" then
        RebuildSlotBindings()
        if UnitAffectingCombat("player") then
            inCombat = true
        end
        if IsAssistActive() then StartPollLoop() end
        Refresh()
        -- RA may not have fully initialized yet at this point.
        -- Retry after 1 s to pre-warm cachedRotSpells before the player
        -- opens the Ignored Spells panel for the first time.
        C_Timer.After(1, function()
            if #cachedRotSpells == 0 then
                local ok, spells = pcall(C_AssistedCombat.GetRotationSpells)
                if ok and type(spells) == "table" and #spells > 0 then
                    wipe(cachedRotSpells)
                    for i, sid in ipairs(spells) do cachedRotSpells[i] = sid end
                    ApplyClassDefaultIgnores(spells)
                end
            else
                ApplyClassDefaultIgnores(cachedRotSpells)
            end
        end)

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        -- Poll only when rotation assistance is active (Rotation Assistant button or Assisted Highlight).
        -- ACTIONBAR_SLOT_CHANGED will start the loop if the feature is enabled mid-combat.
        if IsAssistActive() then StartPollLoop() end
        Log("Entered combat")

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        Refresh()
        Log("Left combat")

    elseif event == "ACTIONBAR_UPDATE_STATE" then
        -- State changes (button highlights) don't affect slot assignments; just re-render.
        Refresh()

    elseif event == "ACTIONBAR_SLOT_CHANGED" or
           event == "UPDATE_BINDINGS" then
        -- Slot content or keybinding actually changed — rebuild the map then re-render.
        RebuildSlotBindings()
        Refresh()
        -- If assist feature was just enabled mid-combat, start polling now.
        if inCombat and IsAssistActive() then StartPollLoop() end

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        -- A proc glow appeared — if it's our current suggestion, start pulsing
        if arg1 == currentSuggestionID and db.showProcGlow then
            StartGlowPulse()
        end

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        -- A proc glow faded — if it was our current suggestion, stop pulsing
        if arg1 == currentSuggestionID then
            StopGlowPulse()
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1 = unit, arg2 = castGUID, arg3 = spellID
        -- Track spells with a real cooldown (base CD > 1.5 s) so secondary
        -- icons can be greyed while they are on cooldown.
        -- GetSpellBaseCooldown returns base CD in ms as a plain Lua number.
        if arg1 == "player" and arg3 then
            local baseCDms = GetSpellBaseCooldown(arg3) or 0
            if baseCDms > 1500 then
                recentlyCastSpells[arg3] = true
            end
        end

    elseif event == "CINEMATIC_START" or event == "PLAY_MOVIE" then
        inCinematic = true; display:Hide()

    elseif event == "CINEMATIC_STOP" or event == "STOP_MOVIE" then
        inCinematic = false; Refresh()

    elseif event == "UNIT_FLAGS" or event == "UNIT_HEALTH" then
        if arg1 == "player" then Refresh() end

    elseif event == "UNIT_ENTERED_VEHICLE" then
        if arg1 == "player" then Refresh() end

    elseif event == "UNIT_EXITED_VEHICLE" then
        if arg1 == "player" then Refresh() end

    elseif event == "PLAYER_TARGET_CHANGED" then
        Refresh()
    end
end)

-- ── Slash Commands ────────────────────────────────────────────────────────────

local SHOW_MODES  = { always = true, active = true }
local KB_OUTLINES = { outline = "OUTLINE", thick = "THICKOUTLINE", none = "" }
local KB_ANCHORS  = {
    bottomright = "BOTTOMRIGHT", bottomleft = "BOTTOMLEFT",
    topright    = "TOPRIGHT",    topleft    = "TOPLEFT",
    center      = "CENTER",
}

local ALWAYS_HIDE_FLAGS = {
    dead      = { key = "hideWhenDead",      label = "Always hide when dead" },
    vehicle   = { key = "hideWhenVehicle",   label = "Always hide in a vehicle" },
    cinematic = { key = "hideWhenCinematic", label = "Always hide during cinematics" },
}

-- Data-driven condition maps for slash commands.
local function PrintHelp()
    print("|cff88ccffHekiLight|r commands:")
    print("  /hkl lock                  lock display position")
    print("  /hkl unlock                unlock display position")
    print("  /hkl reset                 reset all settings to defaults")
    print("  /hkl scale <0.2–3.0>       set display scale")
    print("  /hkl size  <16–256>        set icon size in pixels")
    print("  /hkl suggestions <1–5>     set number of icon slots (default 3)")
    print("  /hkl spacing <0–32>        set pixel gap between icons")
    print("  /hkl poll  <seconds>       set poll rate (default 0.05)")
    print("  /hkl keybind on|off        toggle keybind text")
    print("  /hkl range on|off          toggle out-of-range tint")
    print("  /hkl procglow on|off       toggle proc glow border pulse")
    print("  /hkl sounds on|off         toggle combat sounds")
    print("  /hkl kbsize <8–24>         set keybind text font size")
    print("  /hkl kbcolor <r> <g> <b>   set keybind text color (0–1 each; e.g. 1 0.82 0 = yellow)")
    print("  /hkl kboutline outline|thick|none  set keybind text outline style")
    print("  /hkl kbanchor br|bl|tr|tl|center   set keybind text corner position")
    print("  /hkl show always|active    set show mode (active = in combat or attackable target)")
    print("  /hkl hide dead on|off      toggle hide when dead")
    print("  /hkl hide vehicle on|off   toggle hide in vehicle")
    print("  /hkl hide cinematic on|off toggle hide during cinematics")
    print("  /hkl minimap on|off        toggle minimap button")
    print("  /hkl ignore <spellID>      hide a spell from the secondary list")
    print("  /hkl unignore <spellID>    re-show a spell in the secondary list")
    print("  /hkl ignorelist            list ignored spells")
    print("  /hkl debug                 toggle debug output")
    print("  /hkl status                print current Rotation Assistant state")
end

SLASH_HEKILIGHT1 = "/hekilight"
SLASH_HEKILIGHT2 = "/hkl"
SlashCmdList["HEKILIGHT"] = function(msg)
    msg = strtrim(msg:lower())

    if msg == "lock" then
        db.locked = true
        display:EnableMouse(false)
        print("|cff88ccffHekiLight:|r Display locked.")

    elseif msg == "unlock" then
        db.locked = false
        display:EnableMouse(true)
        print("|cff88ccffHekiLight:|r Display unlocked — drag to reposition.")

    elseif msg == "reset" then
        wipe(db)
        for k, v in pairs(DEFAULTS) do db[k] = v end
        ApplyPosition()
        display:SetScale(db.scale)
        ApplySlotLayout()
        ApplyKeybindStyle()
        Refresh()
        print("|cff88ccffHekiLight:|r All settings reset to defaults.")

    elseif msg:find("^scale%s") then
        local v = tonumber(msg:match("^scale%s+(.+)$"))
        if v and v >= 0.2 and v <= 3.0 then
            db.scale = v
            display:SetScale(v)
            print("|cff88ccffHekiLight:|r Scale → " .. v)
        else
            print("|cff88ccffHekiLight:|r Scale must be between 0.2 and 3.0.")
        end

    elseif msg:find("^size%s") then
        local v = tonumber(msg:match("^size%s+(.+)$"))
        if v and v >= 16 and v <= 256 then
            db.iconSize = v
            ApplySlotLayout()
            Refresh()
            print("|cff88ccffHekiLight:|r Icon size → " .. v .. "px")
        else
            print("|cff88ccffHekiLight:|r Size must be between 16 and 256.")
        end

    elseif msg:find("^suggestions%s") then
        local v = tonumber(msg:match("^suggestions%s+(.+)$"))
        if v and v >= 1 and v <= 5 then
            db.numSuggestions = math.floor(v)
            ApplySlotLayout()
            Refresh()
            print("|cff88ccffHekiLight:|r Suggestions → " .. db.numSuggestions)
        else
            print("|cff88ccffHekiLight:|r Suggestions must be between 1 and 5.")
        end

    elseif msg:find("^spacing%s") then
        local v = tonumber(msg:match("^spacing%s+(.+)$"))
        if v and v >= 0 and v <= 32 then
            db.iconSpacing = math.floor(v)
            ApplySlotLayout()
            Refresh()
            print("|cff88ccffHekiLight:|r Icon spacing → " .. db.iconSpacing .. "px")
        else
            print("|cff88ccffHekiLight:|r Spacing must be between 0 and 32.")
        end

    elseif msg:find("^poll%s") then
        local v = tonumber(msg:match("^poll%s+(.+)$"))
        if v and v >= 0.016 and v <= 1.0 then
            db.pollRate = v
            print("|cff88ccffHekiLight:|r Poll rate → " .. v .. "s")
        else
            print("|cff88ccffHekiLight:|r Poll rate must be between 0.016 and 1.0.")
        end

    elseif msg == "keybind on" then
        db.showKeybind = true
        Refresh()
        print("|cff88ccffHekiLight:|r Keybind text enabled.")

    elseif msg == "keybind off" then
        db.showKeybind = false
        if slots[1] and slots[1].keybindText then slots[1].keybindText:Hide() end
        print("|cff88ccffHekiLight:|r Keybind text disabled.")

    elseif msg == "range on" then
        db.showOutOfRange = true
        Refresh()
        print("|cff88ccffHekiLight:|r Out-of-range tint enabled.")

    elseif msg == "range off" then
        db.showOutOfRange = false
        if slots[1] and slots[1].rangeOverlay then slots[1].rangeOverlay:Hide() end
        print("|cff88ccffHekiLight:|r Out-of-range tint disabled.")

    elseif msg == "procglow on" then
        db.showProcGlow = true
        Refresh()
        print("|cff88ccffHekiLight:|r Proc glow border enabled.")

    elseif msg == "procglow off" then
        db.showProcGlow = false
        StopGlowPulse()
        print("|cff88ccffHekiLight:|r Proc glow border disabled.")

    elseif msg == "sounds on" then
        db.sounds = true
        print("|cff88ccffHekiLight:|r Sounds enabled.")

    elseif msg == "sounds off" then
        db.sounds = false
        print("|cff88ccffHekiLight:|r Sounds disabled.")

    elseif msg:find("^kbsize%s") then
        local v = tonumber(msg:match("^kbsize%s+(.+)$"))
        if v and v >= 8 and v <= 24 then
            db.keybindFontSize = v
            ApplyKeybindStyle(); Refresh()
            print("|cff88ccffHekiLight:|r Keybind font size → " .. v)
        else
            print("|cff88ccffHekiLight:|r kbsize must be between 8 and 24.")
        end

    elseif msg:find("^kbcolor%s") then
        local r, g, b = msg:match("^kbcolor%s+([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            db.keybindColorR = math.max(0, math.min(1, r))
            db.keybindColorG = math.max(0, math.min(1, g))
            db.keybindColorB = math.max(0, math.min(1, b))
            ApplyKeybindStyle(); Refresh()
            print("|cff88ccffHekiLight:|r Keybind color set.")
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl kbcolor <r> <g> <b>  (values 0–1, e.g. 1 0.82 0 for yellow)")
        end

    elseif msg:find("^kboutline%s") then
        local arg = strtrim(msg:match("^kboutline%s+(.+)$") or "")
        local val = KB_OUTLINES[arg]
        if val ~= nil then
            db.keybindOutline = val
            ApplyKeybindStyle()
            print("|cff88ccffHekiLight:|r Keybind outline → " .. (arg == "none" and "none" or arg))
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl kboutline outline|thick|none")
        end

    elseif msg:find("^kbanchor%s") then
        local arg = strtrim(msg:match("^kbanchor%s+(.+)$") or "")
        local val = KB_ANCHORS[arg]
        if val then
            db.keybindAnchor = val
            ApplyKeybindAnchor()
            print("|cff88ccffHekiLight:|r Keybind anchor → " .. val)
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl kbanchor bottomright|bottomleft|topright|topleft|center")
        end

    elseif msg:find("^show%s") then
        local arg = strtrim(msg:match("^show%s+(.+)$") or "")
        if SHOW_MODES[arg] then
            db.showMode = arg
            Refresh()
            print("|cff88ccffHekiLight:|r Show mode → " .. arg)
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl show always|active")
        end

    elseif msg:find("^hide%s") then
        local flag, toggle = msg:match("^hide%s+(%a+)%s+(on|off)$")
        local entry = flag and ALWAYS_HIDE_FLAGS[flag]
        if entry and toggle then
            db[entry.key] = (toggle == "on")
            Refresh()
            print("|cff88ccffHekiLight:|r " .. entry.label .. " → " .. toggle)
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl hide dead|vehicle|cinematic on|off")
        end

    elseif msg == "minimap on" then
        db.minimapShow = true
        if minimapBtn then minimapBtn:Show() end
        print("|cff88ccffHekiLight:|r Minimap button shown.")

    elseif msg == "minimap off" then
        db.minimapShow = false
        if minimapBtn then minimapBtn:Hide() end
        print("|cff88ccffHekiLight:|r Minimap button hidden.")

    elseif msg:find("^ignore%s") then
        local arg = strtrim(msg:match("^ignore%s+(.+)$") or "")
        local sid = tonumber(arg)
        if sid then
            dbChar.ignoredSpells[sid] = true
            local si = C_Spell.GetSpellInfo(sid)
            local name = si and si.name or tostring(sid)
            print("|cff88ccffHekiLight:|r " .. name .. " [" .. sid .. "] will no longer appear in the secondary list.")
            Refresh()
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl ignore <spellID>")
        end

    elseif msg:find("^unignore%s") then
        local arg = strtrim(msg:match("^unignore%s+(.+)$") or "")
        local sid = tonumber(arg)
        if sid then
            dbChar.ignoredSpells[sid] = nil
            local si = C_Spell.GetSpellInfo(sid)
            local name = si and si.name or tostring(sid)
            print("|cff88ccffHekiLight:|r " .. name .. " [" .. sid .. "] restored to the secondary list.")
            Refresh()
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl unignore <spellID>")
        end

    elseif msg == "ignorelist" then
        local sorted = {}
        for sid in pairs(dbChar.ignoredSpells) do sorted[#sorted + 1] = sid end
        table.sort(sorted)
        if #sorted == 0 then
            print("|cff88ccffHekiLight:|r No spells are hidden from the secondary list.")
        else
            print("|cff88ccffHekiLight:|r Spells hidden from the secondary list:")
            for _, sid in ipairs(sorted) do
                local si = C_Spell.GetSpellInfo(sid)
                local name = si and si.name or "(unknown)"
                print("  " .. name .. " [" .. sid .. "]  — /hkl unignore " .. sid .. " to restore")
            end
        end

    elseif msg == "debug" then
        DEBUG = not DEBUG
        print("|cff88ccffHekiLight:|r Debug output " .. (DEBUG and "ON" or "OFF") .. ".")

    elseif msg == "status" then
        local hasRA       = C_ActionBar.HasAssistedCombatActionButtons()
        local hasHighlight = GetCVarBool("assistedCombatHighlight")
        local hasEngine   = C_AssistedCombat.GetNextCastSpell ~= nil

        -- Detection mode summary
        local mode
        if hasRA and hasHighlight then
            mode = "|cff00ff00Rotation Assistant + Assisted Highlight|r"
        elseif hasRA then
            mode = "|cffffff00Rotation Assistant only|r"
        elseif hasHighlight then
            mode = "|cffffff00Assisted Highlight only|r"
        else
            mode = "|cffff4444none — rotation assistance is off|r"
        end

        -- Current suggestion from engine
        local currentSpellID
        if hasEngine then
            pcall(function() currentSpellID = C_AssistedCombat.GetNextCastSpell(false) end)
        end
        local spellDesc = "(none)"
        if currentSpellID then
            local si = C_Spell.GetSpellInfo(currentSpellID)
            spellDesc = si and (si.name .. " [" .. currentSpellID .. "]") or tostring(currentSpellID)
        end

        local canShow, suppressReason = ShouldShow()
        print("|cff88ccffHekiLight status:|r")
        print("  Detection mode:", mode)
        print("  GetNextCastSpell API:", tostring(hasEngine))
        print("  Current suggestion:", spellDesc)
        print("  In combat:", tostring(inCombat))
        print("  Display visible:", tostring(display:IsShown()))
        if canShow then
            print("  Suppression: |cff00ff00none|r — icon allowed to show")
        else
            print("  Suppression: |cffff4444" .. suppressReason .. "|r — icon hidden")
        end

    else
        PrintHelp()
    end
end
