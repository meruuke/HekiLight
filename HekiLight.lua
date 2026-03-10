-- HekiLight
-- Wraps Blizzard's Single-Button Rotation Assistant (SBA) and displays its
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
    showCooldown   = false,   -- SBA cooldown data is taint-protected; enable at your own risk
    showOutOfRange = true,
    showProcGlow   = true,    -- pulse border gold when the suggested spell has an active proc glow
    pollRate       = 0.05,   -- how often (seconds) to refresh while in combat
    sounds         = false,  -- subtle sound when icon appears in combat
    minimapAngle   = 225,    -- degrees around minimap (0=right, 90=top, 180=left, 270=bottom)
    minimapShow    = true,
    -- Hard stops (always hide regardless of combat state)
    hideWhenDead      = true,
    hideWhenCinematic = true,
    -- Show conditions (positive logic — show when any of these are true)
    showWhenInCombat          = true,
    showWhenAttackableTarget  = true,
}

-- ── State ────────────────────────────────────────────────────────────────────

local db            -- points at HekiLightDB after ADDON_LOADED
local inCombat    = false
-- spellID → GetTime() when cast.  Only spells in this table are checked for
-- cooldowns; spells never cast are trusted to the SBA engine.
-- Stored as a timestamp so we can enforce a post-cast grace period that
-- outlasts the GCD-to-real-CD transition window (engine briefly reports
-- duration=0 at GCD end before the real cooldown value is applied).
local recentlyCastSpells = {}
local MIN_CD_GRACE = 2.0  -- seconds after a cast before we trust duration==0 as "truly off CD"
local inCinematic = false  -- true while a cut-scene or pre-rendered movie is playing
local elapsed     = 0
local rangeTicker   -- C_Timer ticker for range overlay pulse animation
local glowTicker    -- C_Timer ticker for proc-glow border pulse animation
local isGlowActive  = false
local currentSuggestionID = nil  -- spellID currently displayed (used to filter glow events)
local slots    = {}  -- per-slot tables; populated by BuildSlots(); slots[1] is the primary slot
local MAX_SLOTS = 5  -- maximum number of icon slots (always created; extras hidden)

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
    if db.ignoredSpells == nil then db.ignoredSpells = {} end
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
--- from the SBA slot first, and the texture-fallback scan is gone.
local function GetSpellKeybind(spellID)
    local slots = C_ActionBar.FindSpellActionButtons(spellID)
    if slots then
        for _, slot in ipairs(slots) do
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

            -- Keybind label — NumberFontNormal is the same font Blizzard uses on action buttons
            slot.keybindText = slot.frame:CreateFontString(nil, "OVERLAY")
            slot.keybindText:SetFontObject(NumberFontNormal)
            slot.keybindText:SetPoint("BOTTOMRIGHT", slot.frame, "BOTTOMRIGHT", -2, 3)
            slot.keybindText:SetTextColor(1, 1, 1, 1)
        end

        slot.frame:Hide()
        slots[i] = slot
    end

    ApplySlotLayout()
    display:Hide()
    Log("BuildSlots complete, maxSlots=", MAX_SLOTS, "showing=", db.numSuggestions)
end

-- ── Minimap Button ────────────────────────────────────────────────────────────

local minimapBtn
local settingsCategory

local function UpdateMinimapPos()
    local angle = math.rad(db.minimapAngle or 225)
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER",
        80 * math.cos(angle),
        80 * math.sin(angle))
end

local function BuildMinimapButton()
    minimapBtn = CreateFrame("Button", "HekiLightMinimapButton", Minimap)
    minimapBtn:SetSize(32, 32)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)

    local bg = minimapBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(32, 32)
    bg:SetPoint("CENTER")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")

    local icon = minimapBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\ability_whirlwind")

    local border = minimapBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("CENTER")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

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
            local s = UIParent:GetEffectiveScale()
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
    local panel = CreateFrame("Frame")
    panel.name = "HekiLight"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("HekiLight")

    local version = C_AddOns.GetAddOnMetadata("HekiLight", "Version") or "?"
    local subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Rotation assistant icon overlay  |cff666666v" .. version .. "|r")

    local checkboxRefs = {}
    local sliderRefs   = {}

    -- Two-column layout: left = Appearance/Display/Minimap, right = Hide conditions
    local cols = {
        left  = { x = 16,  y = -70 },
        right = { x = 310, y = -70 },
    }

    local function AddCheckbox(label, tip, getValue, setValue, colName)
        local col = cols[colName or "left"]
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", col.x, col.y)
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
        table.insert(checkboxRefs, { cb = cb, getValue = getValue })
        col.y = col.y - 28
        return cb
    end

    -- Custom slider: no global-name dependency (OptionsSliderTemplate is deprecated in 10.x+)
    local function AddSlider(label, min, max, step, getValue, setValue, colName)
        local col = cols[colName or "left"]

        local labelStr = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        labelStr:SetPoint("TOPLEFT", col.x + 4, col.y)
        labelStr:SetText(label .. ": " .. getValue())

        local slider = CreateFrame("Slider", nil, panel, "BackdropTemplate")
        slider:SetPoint("TOPLEFT", col.x + 4, col.y - 18)
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
            setValue(val)
            labelStr:SetText(label .. ": " .. val)
        end)

        table.insert(sliderRefs, { slider = slider, labelStr = labelStr,
                                   label = label, step = step, getValue = getValue })
        col.y = col.y - 52
        return slider
    end

    local function SectionHeader(text, colName)
        local col = cols[colName or "left"]
        local s = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        s:SetPoint("TOPLEFT", col.x, col.y)
        s:SetText(text)
        col.y = col.y - 22
    end

    -- ── Left Column: Appearance / Display Options / Minimap ───────────────────
    SectionHeader("Appearance")
    AddCheckbox("Lock position",
        "Prevent the icon from being accidentally dragged. Use /hkl unlock or untick this to reposition it.",
        function() return db.locked end,
        function(v)
            db.locked = v
            display:EnableMouse(not v)
            print("|cff88ccffHekiLight:|r Position " .. (v and "locked." or "unlocked — drag to reposition."))
        end)
    AddSlider("Scale", 0.2, 3.0, 0.1,
        function() return db.scale end,
        function(v) db.scale = v; display:SetScale(v) end)
    AddSlider("Icon Size", 16, 256, 8,
        function() return db.iconSize end,
        function(v) db.iconSize = v; ApplySlotLayout(); Refresh() end)
    AddSlider("Suggestions", 1, 5, 1,
        function() return db.numSuggestions end,
        function(v) db.numSuggestions = v; ApplySlotLayout(); Refresh() end)
    AddSlider("Icon Spacing", 0, 32, 2,
        function() return db.iconSpacing end,
        function(v) db.iconSpacing = v; ApplySlotLayout(); Refresh() end)

    SectionHeader("Display Options")
    AddCheckbox("Show keybind text",
        "Show the keybind for the suggested spell in the corner of the icon.",
        function() return db.showKeybind end,
        function(v) db.showKeybind = v; if not v and slots[1] and slots[1].keybindText then slots[1].keybindText:Hide() end end)
    AddCheckbox("Show out-of-range tint",
        "Pulse the icon red when the suggested spell cannot reach your target.",
        function() return db.showOutOfRange end,
        function(v) db.showOutOfRange = v; if not v and slots[1] and slots[1].rangeOverlay then slots[1].rangeOverlay:Hide() end end)
    AddCheckbox("Proc glow border",
        "Pulse the icon border gold when the suggested spell has an active proc glow.",
        function() return db.showProcGlow end,
        function(v) db.showProcGlow = v; if not v then StopGlowPulse() end end)
    AddCheckbox("Show cooldown spiral",
        "Display a cooldown sweep on the icon. May cause UI taint — use with caution.",
        function() return db.showCooldown end,
        function(v) db.showCooldown = v; if not v and slots[1] and slots[1].cooldownFrame then slots[1].cooldownFrame:Hide() end end)
    AddCheckbox("Play sounds",
        "Play a subtle click when the icon appears as you enter combat.",
        function() return db.sounds end,
        function(v) db.sounds = v end)

    SectionHeader("Minimap")
    AddCheckbox("Show minimap button",
        "Show the HekiLight button on the minimap. Drag it to reposition.",
        function() return db.minimapShow ~= false end,
        function(v)
            db.minimapShow = v
            if minimapBtn then minimapBtn:SetShown(v) end
        end)

    -- ── Right Column: Visibility Conditions ──────────────────────────────────
    SectionHeader("Always Hide When...", "right")
    AddCheckbox("Player is dead or a ghost",
        "Hide the icon while you are dead or in spirit form.",
        function() return db.hideWhenDead ~= false end,
        function(v) db.hideWhenDead = v; Refresh() end, "right")
    AddCheckbox("A cinematic is playing",
        "Hide the icon during cut-scenes and pre-rendered movies.",
        function() return db.hideWhenCinematic ~= false end,
        function(v) db.hideWhenCinematic = v; Refresh() end, "right")

    SectionHeader("Show Icon When...", "right")
    AddCheckbox("Player is in combat",
        "Show the icon whenever you enter combat, regardless of your target.",
        function() return db.showWhenInCombat ~= false end,
        function(v) db.showWhenInCombat = v; Refresh() end, "right")
    AddCheckbox("Target is attackable",
        "Show the icon when you have a target you can attack (even outside of combat).",
        function() return db.showWhenAttackableTarget ~= false end,
        function(v) db.showWhenAttackableTarget = v; Refresh() end, "right")

    -- ── Ignored Spells Section (full-width, below both columns) ─────────────────

    local ignoreY = math.min(cols.left.y, cols.right.y) - 20

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 12, ignoreY)
    divider:SetSize(600, 1)
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    ignoreY = ignoreY - 22

    local ignoreHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ignoreHeader:SetPoint("TOPLEFT", 16, ignoreY)
    ignoreHeader:SetText("Ignored Spells")
    ignoreY = ignoreY - 18

    local ignoreDesc = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ignoreDesc:SetPoint("TOPLEFT", 16, ignoreY)
    ignoreDesc:SetText("Spells hidden from the secondary suggestion list. The dropdown shows your current rotation spells.")
    ignoreY = ignoreY - 30

    -- Forward declarations so button-script closures can reference both functions
    local selectedIgnoreSpellID = nil
    local rowPool = {}
    local PopulateRotationDropdown
    local RefreshIgnoreList

    -- UIDropDownMenu has ~18 px of inherent left padding; offset x by -2 to align
    local ignoreDD = CreateFrame("Frame", "HekiLightIgnoreDropdown", panel, "UIDropDownMenuTemplate")
    ignoreDD:SetPoint("TOPLEFT", -2, ignoreY)
    UIDropDownMenu_SetWidth(ignoreDD, 270)
    UIDropDownMenu_SetText(ignoreDD, "Select a rotation spell...")

    local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", ignoreDD, "RIGHT", -4, 2)
    addBtn:SetSize(150, 22)
    addBtn:SetText("Add to ignore list")
    addBtn:SetScript("OnClick", function()
        if not selectedIgnoreSpellID then
            print("|cff88ccffHekiLight:|r Select a spell from the dropdown first.")
            return
        end
        if db.ignoredSpells[selectedIgnoreSpellID] then
            print("|cff88ccffHekiLight:|r That spell is already ignored.")
            return
        end
        db.ignoredSpells[selectedIgnoreSpellID] = true
        local si = C_Spell.GetSpellInfo(selectedIgnoreSpellID)
        local name = si and si.name or tostring(selectedIgnoreSpellID)
        print("|cff88ccffHekiLight:|r " .. name .. " [" .. selectedIgnoreSpellID .. "] will no longer appear in the secondary list.")
        selectedIgnoreSpellID = nil
        UIDropDownMenu_SetText(ignoreDD, "Select a rotation spell...")
        PopulateRotationDropdown()
        RefreshIgnoreList()
    end)

    local listBaseY = ignoreY - 36

    PopulateRotationDropdown = function()
        UIDropDownMenu_Initialize(ignoreDD, function(self, level)
            local ok, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
            if not ok or not rotSpells or #rotSpells == 0 then
                local info    = UIDropDownMenu_CreateInfo()
                info.text     = "|cff888888No rotation spells available|r"
                info.disabled = true
                UIDropDownMenu_AddButton(info, level)
                return
            end
            for _, sid in ipairs(rotSpells) do
                local si = C_Spell.GetSpellInfo(sid)
                if si then
                    local ignored      = db.ignoredSpells[sid]
                    local info         = UIDropDownMenu_CreateInfo()
                    info.text          = (ignored and "|cff888888" or "")
                                        .. si.name
                                        .. "  |cff666666[" .. sid .. "]|r"
                                        .. (ignored and " (hidden)|r" or "")
                    info.icon          = si.iconID
                    info.disabled      = ignored
                    local capturedSid  = sid
                    local capturedName = si.name
                    if not ignored then
                        info.func = function()
                            selectedIgnoreSpellID = capturedSid
                            UIDropDownMenu_SetText(ignoreDD, capturedName .. " [" .. capturedSid .. "]")
                        end
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end)
    end

    RefreshIgnoreList = function()
        for _, row in ipairs(rowPool) do row:Hide() end

        local sorted = {}
        for sid in pairs(db.ignoredSpells) do sorted[#sorted + 1] = sid end
        table.sort(sorted)

        local rowIdx = 0
        for _, sid in ipairs(sorted) do
            rowIdx = rowIdx + 1
            local row = rowPool[rowIdx]
            if not row then
                row = CreateFrame("Frame", nil, panel)
                row:SetSize(580, 24)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(20, 20)
                row.icon:SetPoint("LEFT", 4, 0)
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.label:SetWidth(420)
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
            row.label:SetText((si and si.name or "(unknown)")
                              .. "  |cff888888[" .. sid .. "]|r")
            row.removeBtn:SetScript("OnClick", function()
                db.ignoredSpells[capturedSid] = nil
                PopulateRotationDropdown()
                RefreshIgnoreList()
            end)
            row:SetPoint("TOPLEFT", 16, listBaseY - (rowIdx - 1) * 26)
            row:Show()
        end

        if not panel.ignoreEmptyLabel then
            panel.ignoreEmptyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            panel.ignoreEmptyLabel:SetPoint("TOPLEFT", 16, listBaseY)
            panel.ignoreEmptyLabel:SetText("No spells are currently ignored.")
        end
        panel.ignoreEmptyLabel:SetShown(rowIdx == 0)
    end

    -- Refresh all controls when the panel opens (existing + new ignore widgets)
    panel:SetScript("OnShow", function()
        for _, ref in ipairs(checkboxRefs) do ref.cb:SetChecked(ref.getValue()) end
        for _, ref in ipairs(sliderRefs) do
            ref.slider:SetValue(ref.getValue())
            ref.labelStr:SetText(ref.label .. ": " .. ref.getValue())
        end
        PopulateRotationDropdown()
        RefreshIgnoreList()
    end)

    -- Footer hint (fixed offset below the ignore list area; canvas scrolls in 10.x+)
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, listBaseY - 180)
    hint:SetText("/hkl for quick commands  ·  Drag the icon in-game to reposition  ·  /hkl lock to prevent accidental moves")

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


local function IsAssistActive()
    return C_ActionBar.HasAssistedCombatActionButtons()
        or GetCVarBool("assistedCombatHighlight")
end

-- Returns the suggested spellID from the rotation engine, plus the first
-- real (non-SBA) action bar slot that contains it for range/keybind checks.
--
-- Detection order:
--   1. C_AssistedCombat.GetNextCastSpell(false) — direct engine query; works
--      with either SBA button or Action Bar Highlight (or both).
--   2. Fallback: derive spellID from the SBA slot via GetActionInfo.
--      Keeps the old behaviour for any edge case where GetNextCastSpell is nil.
local function GetActiveSuggestion()
    local spellID

    -- Primary path: ask the rotation engine directly (Midnight 12.0+).
    -- checkForVisibleButton=false means "give me the suggestion even if the
    -- SBA floating button is hidden / not on the bar."
    if C_AssistedCombat.GetNextCastSpell then
        local ok
        ok, spellID = pcall(C_AssistedCombat.GetNextCastSpell, false)
        if not ok then spellID = nil end
        Log("GetNextCastSpell →", tostring(spellID))
    end

    -- Fallback: SBA slot → GetActionInfo → spellID (old path; safety net).
    if not spellID then
        -- Find the SBA slot the old way.
        local sbaSlot
        if C_ActionBar.HasAssistedCombatActionButtons() then
            local slots = C_ActionBar.FindAssistedCombatActionButtons()
            if slots and #slots > 0 then
                sbaSlot = slots[1]
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
            Log("Fallback SBA slot", tostring(sbaSlot), "→ spellID", tostring(spellID))
        end
    end

    if not spellID then
        Log("No active suggestion found")
        return nil, nil
    end

    -- Find a real (non-SBA) action bar slot for this spell so we can do
    -- range checks and keybind lookups against the player's actual bars.
    local realSlotID
    local slots = C_ActionBar.FindSpellActionButtons(spellID)
    if slots then
        for _, slot in ipairs(slots) do
            if not C_ActionBar.IsAssistedCombatAction(slot) then
                realSlotID = slot
                break
            end
        end
    end
    Log("Active suggestion: spellID=", spellID, "realSlot=", tostring(realSlotID))
    return spellID, realSlotID
end

-- Returns the first real (non-SBA) action bar slot for a spellID.
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
-- rotation queue.  Slot 1 is always the active SBA suggestion (GetNextCastSpell).
-- Slots 2..n come from C_AssistedCombat.GetRotationSpells() (Midnight 12.0+).
--
-- Cooldown filter: only spells the player has actually cast (tracked in
-- recentlyCastSpells) are checked via IsSpellAvailable.  Spells never cast are
-- shown as-is — the SBA engine is trusted to include them appropriately.
-- Once a tracked spell is detected as available again, it is removed from the
-- set so it flows freely on future polls.
local function GetSuggestionQueue(n)
    local queue = {}
    local primaryID, primarySlot = GetActiveSuggestion()
    queue[1] = { spellID = primaryID, realSlotID = primarySlot }

    if n > 1 and C_AssistedCombat.GetRotationSpells then
        local ok, rotSpells = pcall(C_AssistedCombat.GetRotationSpells)
        if ok and rotSpells then
            for _, sid in ipairs(rotSpells) do
                if sid ~= primaryID and not db.ignoredSpells[sid] then
                    local onCooldown = false
                    if recentlyCastSpells[sid] then
                        local pastGrace = (GetTime() - recentlyCastSpells[sid]) > MIN_CD_GRACE
                        if pastGrace and IsSpellAvailable(sid) then
                            recentlyCastSpells[sid] = nil  -- truly off CD, stop tracking
                        else
                            onCooldown = true              -- in grace period or still on CD
                        end
                    end
                    if not onCooldown then
                        local realSlot = GetRealSlot(sid)
                        queue[#queue + 1] = { spellID = sid, realSlotID = realSlot }
                        if #queue >= n then break end
                    end
                end
            end
        end
    end

    return queue
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

--- Returns true when the icon should be shown, false (+ reason) when it should not.
--- Logic: hard stops always suppress; then show if ANY positive condition is met.
local function ShouldShow()
    -- Hard stops — always hide regardless of combat state.
    if db.hideWhenDead and UnitIsDeadOrGhost("player") then
        return false, "dead"
    end
    if db.hideWhenCinematic and inCinematic then
        return false, "cinematic"
    end

    -- Positive show conditions — show if any enabled condition is met.
    if db.showWhenInCombat and inCombat then
        return true
    end
    if db.showWhenAttackableTarget and UnitCanAttack("player", "target") then
        return true
    end

    return false, "no show condition met"
end

local function Refresh()
    if #slots == 0 then return end  -- BuildSlots not yet called

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

    -- Check suppression before doing any rendering work
    local showOk, reason = ShouldShow()
    if not showOk then
        currentSuggestionID = nil
        StopGlowPulse()
        display:Hide()
        Log("display suppressed — reason:", reason)
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
                slot.frame:Show()
            else
                slot.frame:Hide()
            end
        else
            slot.frame:Hide()
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

    -- Keybind
    if db.showKeybind and s1.keybindText then
        s1.keybindText:SetText(GetSpellKeybind(sid))
        s1.keybindText:Show()
    elseif s1.keybindText then
        s1.keybindText:Hide()
    end

    display:Show()
    Log("display:Show() — numSuggestions:", db.numSuggestions,
        "x:", db.x, "y:", db.y)
end

-- ── Combat Polling ────────────────────────────────────────────────────────────
-- OnUpdate fires at the configured poll rate and calls Refresh() to track
-- the SBA suggestion. Only runs when SBA is active AND the player is in combat.
local function OnUpdate(_, dt)
    elapsed = elapsed + dt
    if elapsed >= db.pollRate then
        elapsed = 0
        Refresh()
    end
end

-- Start the poll loop only when SBA is actually configured and we're in combat.
-- Called from combat-start and from action bar change events so the loop can
-- activate mid-combat if the player adds the SBA button during a fight.
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
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_DISABLED")   -- combat start
events:RegisterEvent("PLAYER_REGEN_ENABLED")    -- combat end
events:RegisterEvent("UPDATE_BINDINGS")
events:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
events:RegisterEvent("ACTIONBAR_UPDATE_STATE")  -- fires when SBA changes highlight
events:RegisterEvent("UNIT_FLAGS")              -- catches death / vehicle state changes
events:RegisterEvent("UNIT_HEALTH")             -- instant hide on death (no poll lag)
events:RegisterEvent("CINEMATIC_START")         -- in-engine cut-scene begins
events:RegisterEvent("CINEMATIC_STOP")          -- in-engine cut-scene ends
events:RegisterEvent("PLAY_MOVIE")              -- pre-rendered movie begins
events:RegisterEvent("STOP_MOVIE")              -- pre-rendered movie ends
events:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")  -- mount / dismount
events:RegisterEvent("PLAYER_TARGET_CHANGED")         -- target swapped or cleared
events:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")  -- proc glow appears
events:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")  -- proc glow fades
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")             -- track casts for CD filter

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildSlots()
        BuildMinimapButton()
        BuildSettingsPanel()

    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        RebuildSlotBindings()
        -- Handle logging in while already in combat
        if UnitAffectingCombat("player") then
            inCombat = true
            if IsAssistActive() then StartPollLoop() end
        end
        Refresh()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        -- Poll only when rotation assistance is active (SBA button or Highlight).
        -- ACTIONBAR_SLOT_CHANGED will start the loop if the feature is enabled mid-combat.
        if IsAssistActive() then StartPollLoop() end
        Log("Entered combat")

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        StopPollLoop()
        display:Hide()
        Log("Left combat")

    elseif event == "CINEMATIC_START" or event == "PLAY_MOVIE" then
        inCinematic = true
        display:Hide()
        Log("Cinematic started — display hidden")

    elseif event == "CINEMATIC_STOP" or event == "STOP_MOVIE" then
        inCinematic = false
        Refresh()
        Log("Cinematic ended — refreshed")

    elseif event == "UNIT_FLAGS" or event == "UNIT_HEALTH" then
        -- Only care about the player unit; re-run Refresh so ShouldShow() acts immediately
        if arg1 == "player" then Refresh() end

    elseif event == "PLAYER_MOUNT_DISPLAY_CHANGED" or
           event == "PLAYER_TARGET_CHANGED" then
        Refresh()

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
        -- Record every player cast so the cooldown filter knows which spells
        -- to check.  Spells never cast are always shown (trusted to the engine).
        if arg1 == "player" and arg3 then
            recentlyCastSpells[arg3] = GetTime()
        end
    end
end)

-- ── Slash Commands ────────────────────────────────────────────────────────────

-- Data-driven condition maps for slash commands.
local ALWAYS_HIDE_FLAGS = {
    dead      = { key = "hideWhenDead",      label = "Always hide when dead" },
    cinematic = { key = "hideWhenCinematic", label = "Always hide during cinematic" },
}
local SHOW_FLAGS = {
    combat = { key = "showWhenInCombat",         label = "Show when in combat" },
    target = { key = "showWhenAttackableTarget", label = "Show when target is attackable" },
}

local function PrintHelp()
    print("|cff88ccffHekiLight|r commands:")
    print("  /hkl lock                  lock display position")
    print("  /hkl unlock                unlock display position")
    print("  /hkl reset                 reset position to default")
    print("  /hkl scale <0.2–3.0>       set display scale")
    print("  /hkl size  <16–256>        set icon size in pixels")
    print("  /hkl suggestions <1–5>     set number of icon slots (default 3)")
    print("  /hkl spacing <0–32>        set pixel gap between icons")
    print("  /hkl poll  <seconds>       set poll rate (default 0.05)")
    print("  /hkl keybind on|off        toggle keybind text")
    print("  /hkl range on|off          toggle out-of-range tint")
    print("  /hkl procglow on|off       toggle proc glow border pulse")
    print("  /hkl sounds on|off         toggle combat sounds")
    print("  /hkl minimap on|off        toggle minimap button")
    print("  /hkl hide dead on|off      toggle always-hide when dead")
    print("  /hkl hide cinematic on|off toggle always-hide during cinematics")
    print("  /hkl show combat on|off    toggle show when in combat")
    print("  /hkl show target on|off    toggle show when target is attackable")
    print("  /hkl ignore <spellID>      hide a spell from the secondary list")
    print("  /hkl unignore <spellID>    re-show a spell in the secondary list")
    print("  /hkl ignorelist            list ignored spells")
    print("  /hkl debug                 toggle debug output")
    print("  /hkl status                print current SBA state")
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
        db.x, db.y = DEFAULTS.x, DEFAULTS.y
        ApplyPosition()
        print("|cff88ccffHekiLight:|r Position reset.")

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

    elseif msg == "minimap on" then
        db.minimapShow = true
        if minimapBtn then minimapBtn:Show() end
        print("|cff88ccffHekiLight:|r Minimap button shown.")

    elseif msg == "minimap off" then
        db.minimapShow = false
        if minimapBtn then minimapBtn:Hide() end
        print("|cff88ccffHekiLight:|r Minimap button hidden.")

    -- Hide/show condition toggles — data-driven via ALWAYS_HIDE_FLAGS / SHOW_FLAGS.
    elseif msg:find("^hide%s") then
        local flag, state = msg:match("^hide%s+(%a+)%s+(on|off)$")
        local def = flag and ALWAYS_HIDE_FLAGS[flag]
        if def then
            db[def.key] = (state == "on")
            Refresh()
            print("|cff88ccffHekiLight:|r " .. def.label .. ": " .. state:upper())
        else
            print("|cff88ccffHekiLight:|r Unknown flag. Valid: dead, cinematic")
        end

    elseif msg:find("^show%s") then
        local flag, state = msg:match("^show%s+(%a+)%s+(on|off)$")
        local def = flag and SHOW_FLAGS[flag]
        if def then
            db[def.key] = (state == "on")
            Refresh()
            print("|cff88ccffHekiLight:|r " .. def.label .. ": " .. state:upper())
        else
            print("|cff88ccffHekiLight:|r Unknown flag. Valid: combat, target")
        end

    elseif msg:find("^ignore%s") then
        local arg = strtrim(msg:match("^ignore%s+(.+)$") or "")
        local sid = tonumber(arg)
        if sid then
            db.ignoredSpells[sid] = true
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
            db.ignoredSpells[sid] = nil
            local si = C_Spell.GetSpellInfo(sid)
            local name = si and si.name or tostring(sid)
            print("|cff88ccffHekiLight:|r " .. name .. " [" .. sid .. "] restored to the secondary list.")
            Refresh()
        else
            print("|cff88ccffHekiLight:|r Usage: /hkl unignore <spellID>")
        end

    elseif msg == "ignorelist" then
        local sorted = {}
        for sid in pairs(db.ignoredSpells) do sorted[#sorted + 1] = sid end
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
        local hasSBA      = C_ActionBar.HasAssistedCombatActionButtons()
        local hasHighlight = GetCVarBool("assistedCombatHighlight")
        local hasEngine   = C_AssistedCombat.GetNextCastSpell ~= nil

        -- Detection mode summary
        local mode
        if hasSBA and hasHighlight then
            mode = "|cff00ff00SBA button + Action Bar Highlight|r"
        elseif hasSBA then
            mode = "|cffffff00SBA button only|r"
        elseif hasHighlight then
            mode = "|cffffff00Action Bar Highlight only|r"
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
