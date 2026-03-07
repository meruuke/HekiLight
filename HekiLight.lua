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

--- Find the keybind of the actual spell the SBA is suggesting,
--- by looking up the spell on the player's real action bar slots.
local function GetSuggestedSpellKeybind(sbaSlotID)
    -- Get the spell ID from the SBA slot (pcall guards against taint)
    local spellID
    local actionType
    local callOk = pcall(function()
        local id
        actionType, id = GetActionInfo(sbaSlotID)
        if actionType == "spell" then spellID = id end
    end)
    Log("keybind lookup: pcall ok=", callOk,
        "actionType=", tostring(actionType), "spellID=", tostring(spellID))

    if spellID then
        -- Find all real bar slots that have this spell
        local slots = C_ActionBar.FindSpellActionButtons(spellID)
        Log("FindSpellActionButtons:", slots and #slots or 0, "slots")
        if slots then
            for _, slot in ipairs(slots) do
                local isAssist = C_ActionBar.IsAssistedCombatAction(slot)
                local key = GetSlotKeybind(slot)
                Log("  slot", slot, "isAssist=", isAssist, "key=", key)
                if not isAssist and key ~= "" then return key end
            end
        end
    end

    -- Fallback: scan by matching icon texture
    local texture = C_ActionBar.GetActionTexture(sbaSlotID)
    Log("texture fallback, sba texture=", tostring(texture))
    if texture then
        for slot = 1, 120 do
            if not C_ActionBar.IsAssistedCombatAction(slot)
            and C_ActionBar.GetActionTexture(slot) == texture then
                local key = GetSlotKeybind(slot)
                Log("  texture match at slot", slot, "key=", key)
                if key ~= "" then return key end
            end
        end
    end

    Log("keybind lookup: no direct keybind, falling back to SBA slot keybind")
    return GetSlotKeybind(sbaSlotID)
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

    -- Backdrop: dark background + thin tooltip-style border
    display:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 8,
        edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
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
        rangeOverlay:SetAlpha(1)
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
    icon:SetTexture("Interface\\Icons\\ability_monk_chiwave")

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
    local y = -70
    local sliderIdx = 0

    local function AddCheckbox(label, tip, getValue, setValue)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 16, y)
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
        y = y - 28
        return cb
    end

    local function AddSlider(label, min, max, step, getValue, setValue)
        sliderIdx = sliderIdx + 1
        local name   = "HekiLightSettingsSlider" .. sliderIdx
        local slider = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", 20, y - 10)
        slider:SetWidth(220)
        slider:SetMinMaxValues(min, max)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)
        slider:SetValue(getValue())
        _G[name .. "Low"]:SetText(tostring(min))
        _G[name .. "High"]:SetText(tostring(max))
        _G[name .. "Text"]:SetText(label .. ": " .. getValue())
        slider:SetScript("OnValueChanged", function(self, val)
            val = math.floor(val / step + 0.5) * step
            setValue(val)
            _G[name .. "Text"]:SetText(label .. ": " .. val)
        end)
        table.insert(sliderRefs, { slider = slider, name = name, label = label,
                                   step = step, getValue = getValue })
        y = y - 52
        return slider
    end

    local function SectionHeader(text)
        local s = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        s:SetPoint("TOPLEFT", 16, y)
        s:SetText(text)
        y = y - 22
    end

    -- Appearance
    SectionHeader("Appearance")
    AddSlider("Scale", 0.2, 3.0, 0.1,
        function() return db and db.scale or DEFAULTS.scale end,
        function(v) if db then db.scale = v; display:SetScale(v) end end)
    AddSlider("Icon Size", 16, 256, 8,
        function() return db and db.iconSize or DEFAULTS.iconSize end,
        function(v) if db then db.iconSize = v; display:SetSize(v, v) end end)

    -- Display Options
    SectionHeader("Display Options")
    AddCheckbox("Show keybind text",
        "Show the keybind for the suggested spell in the corner of the icon.",
        function() return db and db.showKeybind or false end,
        function(v) if db then db.showKeybind = v; if not v then keybindText:Hide() end end end)
    AddCheckbox("Show out-of-range tint",
        "Pulse the icon red when the suggested spell cannot reach your target.",
        function() return db and db.showOutOfRange or false end,
        function(v) if db then db.showOutOfRange = v; if not v then rangeOverlay:Hide() end end end)
    AddCheckbox("Show cooldown spiral",
        "Display a cooldown sweep on the icon. May cause UI taint — use with caution.",
        function() return db and db.showCooldown or false end,
        function(v) if db then db.showCooldown = v; if not v then cooldownFrame:Hide() end end end)
    AddCheckbox("Play sounds",
        "Play a subtle click when the icon appears as you enter combat.",
        function() return db and db.sounds or false end,
        function(v) if db then db.sounds = v end end)

    -- Minimap
    SectionHeader("Minimap")
    AddCheckbox("Show minimap button",
        "Show the HekiLight button on the minimap. Drag it to reposition.",
        function() return db and db.minimapShow ~= false end,
        function(v)
            if db then
                db.minimapShow = v
                if minimapBtn then if v then minimapBtn:Show() else minimapBtn:Hide() end end
            end
        end)

    -- Suppression Rules
    SectionHeader("Hide Icon When...")
    AddCheckbox("Player is dead or a ghost",
        "Hide the icon while you are dead or in spirit form.",
        function() return db and db.hideWhenDead ~= false end,
        function(v) if db then db.hideWhenDead = v; Refresh() end end)
    AddCheckbox("Player is mounted",
        "Hide the icon while riding any mount.",
        function() return db and db.hideWhenMounted ~= false end,
        function(v) if db then db.hideWhenMounted = v; Refresh() end end)
    AddCheckbox("Player is in a vehicle",
        "Hide the icon when controlling a vehicle with its own action bar.",
        function() return db and db.hideWhenVehicle ~= false end,
        function(v) if db then db.hideWhenVehicle = v; Refresh() end end)
    AddCheckbox("A cinematic is playing",
        "Hide the icon during cut-scenes and pre-rendered movies.",
        function() return db and db.hideWhenCinematic ~= false end,
        function(v) if db then db.hideWhenCinematic = v; Refresh() end end)
    AddCheckbox("Player is in a resting area",
        "Hide the icon while in a city or inn.",
        function() return db and db.hideWhenResting ~= false end,
        function(v) if db then db.hideWhenResting = v; Refresh() end end)
    AddCheckbox("No hostile target",
        "Hide the icon when you have no target or your target is not attackable.",
        function() return db and db.hideWhenNoTarget ~= false end,
        function(v) if db then db.hideWhenNoTarget = v; Refresh() end end)

    -- Refresh all controls to current db values when the panel is shown
    panel:SetScript("OnShow", function()
        for _, ref in ipairs(checkboxRefs) do ref.cb:SetChecked(ref.getValue()) end
        for _, ref in ipairs(sliderRefs) do
            ref.slider:SetValue(ref.getValue())
            _G[ref.name .. "Text"]:SetText(ref.label .. ": " .. ref.getValue())
        end
    end)

    -- Footer hint
    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 16, y - 12)
    hint:SetText("/hkl for quick commands  ·  Drag the icon in-game to reposition  ·  /hkl lock to prevent accidental moves")

    settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "HekiLight")
    Settings.RegisterAddOnCategory(settingsCategory)
end

-- ── SBA Slot Detection ────────────────────────────────────────────────────────

-- Try the fast direct API first; fall back to scanning all slots with
-- IsAssistedCombatAction in case FindAssistedCombatActionButtons returns empty
-- (can happen depending on which SBA mode Blizzard is using).
local function FindSBASlot()
    if C_ActionBar.HasAssistedCombatActionButtons() then
        local slots = C_ActionBar.FindAssistedCombatActionButtons()
        if slots and #slots > 0 then
            Log("FindAssistedCombatActionButtons → slot", slots[1])
            return slots[1]
        end
        Log("HasAssisted=true but FindAssisted returned empty, scanning slots...")
    else
        Log("HasAssistedCombatActionButtons = false")
    end

    -- Fallback: scan action bar slots 1-120
    for slot = 1, 120 do
        if C_ActionBar.IsAssistedCombatAction(slot) then
            Log("Fallback scan found SBA slot:", slot)
            return slot
        end
    end
    return nil
end

-- ── Core Update Logic ─────────────────────────────────────────────────────────

--- Returns false (with a reason string) when the icon should be suppressed
--- regardless of SBA state, or true when it is safe to show.
local function ShouldShow()
    if db.hideWhenDead and UnitIsDeadOrGhost("player") then
        return false, "dead"
    end
    if db.hideWhenMounted and IsMounted() then
        return false, "mounted"
    end
    if db.hideWhenVehicle and (UnitInVehicle("player") or UnitHasVehicleUI("player")) then
        return false, "vehicle"
    end
    if db.hideWhenCinematic and inCinematic then
        return false, "cinematic"
    end
    if db.hideWhenResting and IsResting() then
        return false, "resting"
    end
    if db.hideWhenNoTarget and not UnitCanAttack("player", "target") then
        return false, "no hostile target"
    end
    return true
end

local function Refresh()
    local slotID = FindSBASlot()

    if not slotID then
        Log("No SBA slot found — hiding display")
        display:Hide()
        return
    end

    local texture = C_ActionBar.GetActionTexture(slotID)
    if not texture then
        Log("Slot", slotID, "has no texture — hiding display")
        display:Hide()
        return
    end

    Log("Showing spell from slot", slotID, "texture:", texture)

    -- Icon
    iconTexture:SetTexture(texture)

    -- Cooldown — SBA slot cooldown data is marked secret by Blizzard's taint
    -- system; wrap in pcall so a taint error doesn't spam the log.
    if db.showCooldown then
        local ok = pcall(function()
            local cd = C_ActionBar.GetActionCooldown(slotID)
            local startTime = cd and cd.startTime or 0
            if startTime > 0 then
                cooldownFrame:SetCooldown(startTime, cd.duration or 0)
                cooldownFrame:Show()
            else
                cooldownFrame:Hide()
            end
        end)
        if not ok then
            cooldownFrame:Hide()
        end
    else
        cooldownFrame:Hide()
    end

    -- Range indicator
    if db.showOutOfRange then
        local inRange = C_ActionBar.IsActionInRange(slotID)
        -- inRange: true = in range, false = out of range, nil = no range requirement
        if inRange == false then
            rangeOverlay:Show()
        else
            rangeOverlay:Hide()
        end
    else
        rangeOverlay:Hide()
    end

    -- Keybind — show the real spell's keybind, not the SBA button's keybind
    if db.showKeybind then
        keybindText:SetText(GetSuggestedSpellKeybind(slotID))
        keybindText:Show()
    else
        keybindText:Hide()
    end

    -- All content is ready — only show if suppression conditions allow it
    local ok, reason = ShouldShow()
    if ok then
        display:Show()
        Log("display:Show() called — IsShown:", display:IsShown(),
            "W:", display:GetWidth(), "H:", display:GetHeight(),
            "x:", db.x, "y:", db.y)
    else
        display:Hide()
        Log("display suppressed — reason:", reason)
    end
end

-- ── Combat Polling ────────────────────────────────────────────────────────────
-- on events (some SBA changes don't fire explicit events).
local function OnUpdate(_, dt)
    elapsed = elapsed + dt
    if elapsed >= db.pollRate then
        elapsed = 0
        Refresh()
    end
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
            elapsed  = db.pollRate
            display:SetScript("OnUpdate", OnUpdate)
        end
        Refresh()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        elapsed  = db.pollRate  -- fire immediately on next frame
        display:SetScript("OnUpdate", OnUpdate)
        Log("Entered combat — poll loop started")

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        display:SetScript("OnUpdate", nil)
        display:Hide()
        Log("Left combat — poll loop stopped")

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

    elseif event == "ACTIONBAR_UPDATE_STATE" or
           event == "ACTIONBAR_SLOT_CHANGED" or
           event == "UPDATE_BINDINGS" then
        RebuildSlotBindings()
        Refresh()
    end
end)

-- ── Slash Commands ────────────────────────────────────────────────────────────

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

    elseif msg:match("^scale%s+(.+)$") then
        local v = tonumber(msg:match("^scale%s+(.+)$"))
        if v and v >= 0.2 and v <= 3.0 then
            db.scale = v
            display:SetScale(v)
            print("|cff88ccffHekiLight:|r Scale → " .. v)
        else
            print("|cff88ccffHekiLight:|r Scale must be between 0.2 and 3.0.")
        end

    elseif msg:match("^size%s+(.+)$") then
        local v = tonumber(msg:match("^size%s+(.+)$"))
        if v and v >= 16 and v <= 256 then
            db.iconSize = v
            display:SetSize(v, v)
            print("|cff88ccffHekiLight:|r Icon size → " .. v .. "px")
        else
            print("|cff88ccffHekiLight:|r Size must be between 16 and 256.")
        end

    elseif msg:match("^poll%s+(.+)$") then
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

    -- Hide condition toggles
    elseif msg == "hide dead on"      then db.hideWhenDead      = true;  Refresh(); print("|cff88ccffHekiLight:|r Hide when dead: ON")
    elseif msg == "hide dead off"     then db.hideWhenDead      = false; Refresh(); print("|cff88ccffHekiLight:|r Hide when dead: OFF")
    elseif msg == "hide mounted on"   then db.hideWhenMounted   = true;  Refresh(); print("|cff88ccffHekiLight:|r Hide when mounted: ON")
    elseif msg == "hide mounted off"  then db.hideWhenMounted   = false; Refresh(); print("|cff88ccffHekiLight:|r Hide when mounted: OFF")
    elseif msg == "hide vehicle on"   then db.hideWhenVehicle   = true;  Refresh(); print("|cff88ccffHekiLight:|r Hide in vehicle: ON")
    elseif msg == "hide vehicle off"  then db.hideWhenVehicle   = false; Refresh(); print("|cff88ccffHekiLight:|r Hide in vehicle: OFF")
    elseif msg == "hide cinematic on"  then db.hideWhenCinematic = true;  Refresh(); print("|cff88ccffHekiLight:|r Hide during cinematic: ON")
    elseif msg == "hide cinematic off" then db.hideWhenCinematic = false; Refresh(); print("|cff88ccffHekiLight:|r Hide during cinematic: OFF")
    elseif msg == "hide resting on"   then db.hideWhenResting   = true;  Refresh(); print("|cff88ccffHekiLight:|r Hide while resting: ON")
    elseif msg == "hide resting off"  then db.hideWhenResting   = false; Refresh(); print("|cff88ccffHekiLight:|r Hide while resting: OFF")
    elseif msg == "hide target on"    then db.hideWhenNoTarget  = true;  Refresh(); print("|cff88ccffHekiLight:|r Hide with no hostile target: ON")
    elseif msg == "hide target off"   then db.hideWhenNoTarget  = false; Refresh(); print("|cff88ccffHekiLight:|r Hide with no hostile target: OFF")

    elseif msg == "debug" then
        DEBUG = not DEBUG
        print("|cff88ccffHekiLight:|r Debug output " .. (DEBUG and "ON" or "OFF") .. ".")

    elseif msg == "status" then
        local hasAPI = C_ActionBar.HasAssistedCombatActionButtons ~= nil
        local hasActive = hasAPI and C_ActionBar.HasAssistedCombatActionButtons()
        local slots = hasActive and C_ActionBar.FindAssistedCombatActionButtons() or {}
        local canShow, suppressReason = ShouldShow()
        print("|cff88ccffHekiLight status:|r")
        print("  API available:", tostring(hasAPI))
        print("  HasAssistedCombatActionButtons:", tostring(hasActive))
        print("  FindAssistedCombatActionButtons slots:", #slots > 0 and table.concat(slots, ", ") or "(none)")
        print("  In combat:", tostring(inCombat))
        print("  Display visible:", tostring(display:IsShown()))
        if canShow then
            print("  Suppression: |cff00ff00none|r — icon allowed to show")
        else
            print("  Suppression: |cffff4444" .. suppressReason .. "|r — icon hidden")
        end
        -- Scan for IsAssistedCombatAction hits
        local found = {}
        for slot = 1, 120 do
            if C_ActionBar.IsAssistedCombatAction(slot) then
                tinsert(found, slot)
            end
        end
        print("  IsAssistedCombatAction hits:", #found > 0 and table.concat(found, ", ") or "(none)")

    else
        PrintHelp()
    end
end
