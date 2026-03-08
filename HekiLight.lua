-- HekiLight
-- Wraps Blizzard's Single-Button Rotation Assistant (SBA) and displays its
-- current suggestion as a movable, skinnable icon overlay.
--
-- Key APIs used (Midnight 12.0+):
--   C_ActionBar.HasAssistedCombatActionButtons() → bool
--   C_ActionBar.FindAssistedCombatActionButtons() → slotID[]
--   C_ActionBar.IsAssistedCombatAction(slotID)   → bool

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
    scale          = 1.0,
    locked         = false,
    showKeybind    = true,
    showCooldown   = false,   -- SBA cooldown data is taint-protected; enable at your own risk
    showOutOfRange = true,
    pollRate       = 0.05,   -- how often (seconds) to refresh while in combat
    sounds         = false,  -- subtle sound when icon appears in combat
    minimapAngle   = 225,    -- degrees around minimap (0=right, 90=top, 180=left, 270=bottom)
    minimapShow    = true,
    -- Suppression conditions (all on by default)
    hideWhenDead      = true,
    hideWhenMounted   = true,
    hideWhenVehicle   = true,
    hideWhenCinematic = true,
    hideWhenResting   = true,
    hideWhenNoTarget  = true,
}

-- ── State ────────────────────────────────────────────────────────────────────

local db            -- points at HekiLightDB after ADDON_LOADED
local inCombat    = false
local inCinematic = false  -- true while a cut-scene or pre-rendered movie is playing
local elapsed     = 0
local rangeTicker   -- C_Timer ticker for range overlay pulse animation

-- ── Frames ───────────────────────────────────────────────────────────────────

-- Root display frame (BackdropTemplate enables SetBackdrop for border support)
local display = CreateFrame("Frame", "HekiLightDisplay", UIParent, "BackdropTemplate")

-- Child widgets (created in BuildUI)
local iconTexture
local cooldownFrame
local keybindText
local rangeOverlay  -- red tint when out of range

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function InitDB()
    HekiLightDB = HekiLightDB or {}
    db = HekiLightDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
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

local function BuildUI()
    local size = db.iconSize

    display:SetSize(size, size)
    display:SetScale(db.scale)
    display:SetFrameStrata("HIGH")   -- sit above action bars (MEDIUM)
    display:SetFrameLevel(10)        -- reasonable level; 100 was unnecessarily high
    display:SetClampedToScreen(true)
    ApplyPosition()

    -- Backdrop: dark background + tooltip-style border (edgeSize 16 matches UI-Tooltip-Border tile size)
    display:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    display:SetBackdropColor(0, 0, 0, 0.7)
    display:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)

    -- Play a subtle sound when the icon first appears in combat
    display:SetScript("OnShow", function()
        if db and db.sounds then
            PlaySoundFile("Interface\\Buttons\\UI-CheckBox-Up.wav", "SFX")
        end
    end)

    -- Drag support
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

    -- Spell icon (ARTWORK so the backdrop border in BORDER layer renders above it)
    iconTexture = display:CreateTexture(nil, "ARTWORK")
    iconTexture:SetAllPoints(display)
    iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- trim default icon border

    -- Cooldown spiral
    cooldownFrame = CreateFrame("Cooldown", "HekiLightCooldown", display, "CooldownFrameTemplate")
    cooldownFrame:SetAllPoints(display)
    cooldownFrame:SetDrawEdge(true)
    cooldownFrame:SetHideCountdownNumbers(false)

    -- Out-of-range red tint — pulses so it's impossible to miss
    rangeOverlay = display:CreateTexture(nil, "OVERLAY")
    rangeOverlay:SetAllPoints(display)
    rangeOverlay:SetColorTexture(1, 0, 0, 0.35)
    rangeOverlay:Hide()
    rangeOverlay:SetScript("OnShow", function()
        local alpha, dir = 0.15, 1
        rangeTicker = C_Timer.NewTicker(0.05, function()
            alpha = alpha + dir * 0.04
            if alpha >= 0.5 then dir = -1 elseif alpha <= 0.1 then dir = 1 end
            rangeOverlay:SetAlpha(alpha)
        end)
    end)
    rangeOverlay:SetScript("OnHide", function()
        if rangeTicker then rangeTicker:Cancel(); rangeTicker = nil end
        -- alpha resets automatically when frame is shown again via OnShow
    end)

    -- Keybind label — NumberFontNormal is the same font Blizzard uses on action buttons
    keybindText = display:CreateFontString(nil, "OVERLAY")
    keybindText:SetFontObject(NumberFontNormal)
    keybindText:SetPoint("BOTTOMRIGHT", display, "BOTTOMRIGHT", -2, 3)
    keybindText:SetTextColor(1, 1, 1, 1)

    display:Hide()
    Log("BuildUI complete, size=", size, "strata=HIGH level=10")
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
        function(v) db.iconSize = v; display:SetSize(v, v) end)

    SectionHeader("Display Options")
    AddCheckbox("Show keybind text",
        "Show the keybind for the suggested spell in the corner of the icon.",
        function() return db.showKeybind end,
        function(v) db.showKeybind = v; if not v then keybindText:Hide() end end)
    AddCheckbox("Show out-of-range tint",
        "Pulse the icon red when the suggested spell cannot reach your target.",
        function() return db.showOutOfRange end,
        function(v) db.showOutOfRange = v; if not v then rangeOverlay:Hide() end end)
    AddCheckbox("Show cooldown spiral",
        "Display a cooldown sweep on the icon. May cause UI taint — use with caution.",
        function() return db.showCooldown end,
        function(v) db.showCooldown = v; if not v then cooldownFrame:Hide() end end)
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

    -- ── Right Column: Hide Conditions ─────────────────────────────────────────
    SectionHeader("Hide Icon When...", "right")
    AddCheckbox("Player is dead or a ghost",
        "Hide the icon while you are dead or in spirit form.",
        function() return db.hideWhenDead ~= false end,
        function(v) db.hideWhenDead = v; Refresh() end, "right")
    AddCheckbox("Player is mounted",
        "Hide the icon while riding any mount.",
        function() return db.hideWhenMounted ~= false end,
        function(v) db.hideWhenMounted = v; Refresh() end, "right")
    AddCheckbox("Player is in a vehicle",
        "Hide the icon when controlling a vehicle with its own action bar.",
        function() return db.hideWhenVehicle ~= false end,
        function(v) db.hideWhenVehicle = v; Refresh() end, "right")
    AddCheckbox("A cinematic is playing",
        "Hide the icon during cut-scenes and pre-rendered movies.",
        function() return db.hideWhenCinematic ~= false end,
        function(v) db.hideWhenCinematic = v; Refresh() end, "right")
    AddCheckbox("Player is in a resting area",
        "Hide the icon while in a city or inn.",
        function() return db.hideWhenResting ~= false end,
        function(v) db.hideWhenResting = v; Refresh() end, "right")
    AddCheckbox("No hostile target",
        "Hide the icon when you have no target or your target is not attackable.",
        function() return db.hideWhenNoTarget ~= false end,
        function(v) db.hideWhenNoTarget = v; Refresh() end, "right")

    -- Refresh all controls to current db values when the panel is shown
    panel:SetScript("OnShow", function()
        for _, ref in ipairs(checkboxRefs) do ref.cb:SetChecked(ref.getValue()) end
        for _, ref in ipairs(sliderRefs) do
            ref.slider:SetValue(ref.getValue())
            ref.labelStr:SetText(ref.label .. ": " .. ref.getValue())
        end
    end)

    -- Footer hint below the deepest column
    local footerY = math.min(cols.left.y, cols.right.y) - 12
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, footerY)
    hint:SetText("/hkl for quick commands  ·  Drag the icon in-game to reposition  ·  /hkl lock to prevent accidental moves")

    settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "HekiLight")
    Settings.RegisterAddOnCategory(settingsCategory)
end

-- ── Spell Suggestion Detection ───────────────────────────────────────────────

-- Returns true when the rotation assistance system is active in any mode.
-- Used to decide whether to start the combat poll loop.
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

-- ── Core Update Logic ─────────────────────────────────────────────────────────

--- Returns false (with a reason string) when the icon should be suppressed
--- regardless of SBA state, or true when it is safe to show.
local function ShouldShow()
    -- Hard stops — always suppress, even with an attackable target.
    if db.hideWhenDead and UnitIsDeadOrGhost("player") then
        return false, "dead"
    end
    if db.hideWhenCinematic and inCinematic then
        return false, "cinematic"
    end

    -- An attackable target overrides all remaining soft conditions.
    -- Handles quest fights in cities, resting areas, while technically mounted, etc.
    if UnitCanAttack("player", "target") then
        return true
    end

    -- No attackable target — soft suppression conditions apply.
    if db.hideWhenMounted and IsMounted() then
        return false, "mounted"
    end
    if db.hideWhenVehicle and (UnitInVehicle("player") or UnitHasVehicleUI("player")) then
        return false, "vehicle"
    end
    if db.hideWhenResting and IsResting() then
        return false, "resting"
    end
    if db.hideWhenNoTarget then
        return false, "no hostile target"
    end
    return true
end

local function Refresh()
    local spellID, realSlotID = GetActiveSuggestion()

    if not spellID then
        Log("No active suggestion — hiding display")
        display:Hide()
        return
    end

    -- Texture from spell info (iconID is a numeric file ID accepted by SetTexture)
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if not spellInfo or not spellInfo.iconID then
        Log("No spell info for", spellID, "— hiding display")
        display:Hide()
        return
    end
    Log("Showing spellID", spellID, "iconID", spellInfo.iconID, "realSlot", tostring(realSlotID))

    -- Icon
    iconTexture:SetTexture(spellInfo.iconID)

    -- Cooldown — use C_Spell API (no slot needed; taint guard still applies)
    if db.showCooldown then
        local ok = pcall(function()
            local cd = C_Spell.GetSpellCooldown(spellID)
            local startTime = cd and cd.startTime or 0
            if startTime > 0 then
                cooldownFrame:SetCooldown(startTime, cd.duration or 0)
                cooldownFrame:Show()
            else
                cooldownFrame:Hide()
            end
        end)
        if not ok then cooldownFrame:Hide() end
    else
        cooldownFrame:Hide()
    end

    -- Range indicator — requires a real action bar slot; hide if none found
    if db.showOutOfRange and realSlotID then
        local inRange = C_ActionBar.IsActionInRange(realSlotID)
        -- inRange: true = in range, false = out of range, nil = no range requirement
        rangeOverlay:SetShown(inRange == false)
    else
        rangeOverlay:Hide()
    end

    -- Keybind
    if db.showKeybind then
        keybindText:SetText(GetSpellKeybind(spellID))
        keybindText:Show()
    else
        keybindText:Hide()
    end

    -- All content ready — only show if suppression conditions allow it
    local ok, reason = ShouldShow()
    if ok then
        display:Show()
        Log("display:Show() — IsShown:", display:IsShown(),
            "x:", db.x, "y:", db.y)
    else
        display:Hide()
        Log("display suppressed — reason:", reason)
    end
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

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildUI()
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
    end
end)

-- ── Slash Commands ────────────────────────────────────────────────────────────

-- Data-driven hide-condition map. Adding a new condition only requires a new
-- entry here and a matching key in DEFAULTS — no ladder of elseif needed.
local HIDE_FLAGS = {
    dead      = { key = "hideWhenDead",      label = "Hide when dead" },
    mounted   = { key = "hideWhenMounted",   label = "Hide when mounted" },
    vehicle   = { key = "hideWhenVehicle",   label = "Hide in vehicle" },
    cinematic = { key = "hideWhenCinematic", label = "Hide during cinematic" },
    resting   = { key = "hideWhenResting",   label = "Hide while resting" },
    target    = { key = "hideWhenNoTarget",  label = "Hide with no hostile target" },
}

local function PrintHelp()
    print("|cff88ccffHekiLight|r commands:")
    print("  /hkl lock              lock display position")
    print("  /hkl unlock            unlock display position")
    print("  /hkl reset             reset position to default")
    print("  /hkl scale <0.2–3.0>   set display scale")
    print("  /hkl size  <16–256>    set icon size in pixels")
    print("  /hkl poll  <seconds>   set poll rate (default 0.05)")
    print("  /hkl keybind on|off    toggle keybind text")
    print("  /hkl range on|off      toggle out-of-range tint")
    print("  /hkl sounds on|off     toggle combat sounds")
    print("  /hkl minimap on|off    toggle minimap button")
    print("  /hkl hide dead on|off      toggle hide when dead")
    print("  /hkl hide mounted on|off   toggle hide when mounted")
    print("  /hkl hide vehicle on|off   toggle hide in vehicle")
    print("  /hkl hide cinematic on|off toggle hide during cinematics")
    print("  /hkl hide resting on|off   toggle hide while resting")
    print("  /hkl hide target on|off    toggle hide with no hostile target")
    print("  /hkl debug             toggle debug output")
    print("  /hkl status            print current SBA state")
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
            display:SetSize(v, v)
            print("|cff88ccffHekiLight:|r Icon size → " .. v .. "px")
        else
            print("|cff88ccffHekiLight:|r Size must be between 16 and 256.")
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
        keybindText:Hide()
        print("|cff88ccffHekiLight:|r Keybind text disabled.")

    elseif msg == "range on" then
        db.showOutOfRange = true
        print("|cff88ccffHekiLight:|r Out-of-range tint enabled.")

    elseif msg == "range off" then
        db.showOutOfRange = false
        rangeOverlay:Hide()
        print("|cff88ccffHekiLight:|r Out-of-range tint disabled.")

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

    -- Hide condition toggles — data-driven via HIDE_FLAGS; no per-condition branches needed.
    elseif msg:find("^hide%s") then
        local flag, state = msg:match("^hide%s+(%a+)%s+(on|off)$")
        local def = flag and HIDE_FLAGS[flag]
        if def then
            db[def.key] = (state == "on")
            Refresh()
            print("|cff88ccffHekiLight:|r " .. def.label .. ": " .. state:upper())
        else
            print("|cff88ccffHekiLight:|r Unknown condition. Valid: dead, mounted, vehicle, cinematic, resting, target")
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
