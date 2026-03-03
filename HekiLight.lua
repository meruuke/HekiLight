-- HekiLight
-- Wraps Blizzard's Single-Button Rotation Assistant (SBA) and displays its
-- current suggestion as a movable, skinnable icon overlay.
--
-- Key APIs used (Midnight 12.0+):
--   C_ActionBar.HasAssistedCombatActionButtons() → bool
--   C_ActionBar.FindAssistedCombatActionButtons() → slotID[]
--   C_ActionBar.IsAssistedCombatAction(slotID)   → bool

local ADDON_NAME = "HekiLight"

-- ── Defaults ────────────────────────────────────────────────────────────────

local DEFAULTS = {
    x           = 0,
    y           = -220,
    iconSize    = 64,
    scale       = 1.0,
    locked      = false,
    showKeybind = true,
    showCooldown = true,
    showOutOfRange = true,
    -- How often (seconds) to refresh while in combat
    pollRate    = 0.05,
}

-- ── State ────────────────────────────────────────────────────────────────────

local db            -- points at HekiLightDB after ADDON_LOADED
local inCombat = false
local elapsed  = 0

-- ── Frames ───────────────────────────────────────────────────────────────────

-- Root display frame
local display = CreateFrame("Frame", "HekiLightDisplay", UIParent)

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

--- Return a short keybind string for an action slot, e.g. "C-1" or "F".
local function GetSlotKeybind(slotID)
    local key = GetBindingKey("ACTION " .. slotID)
    if not key then return "" end
    key = key:gsub("ALT%-",   "A-")
              :gsub("CTRL%-",  "C-")
              :gsub("SHIFT%-", "S-")
    return key
end

--- True when the spell in slotID is out of range for the current target.
local function IsOutOfRange(slotID)
    return C_ActionBar.IsActionInRange and
           C_ActionBar.IsActionInRange(slotID) == false
end

-- ── UI Construction ───────────────────────────────────────────────────────────

local function BuildUI()
    local size = db.iconSize

    display:SetSize(size, size)
    display:SetScale(db.scale)
    display:SetFrameStrata("MEDIUM")
    display:SetClampedToScreen(true)
    ApplyPosition()

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

    -- Spell icon
    iconTexture = display:CreateTexture(nil, "BACKGROUND")
    iconTexture:SetAllPoints(display)
    iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- trim default icon border

    -- Cooldown spiral
    cooldownFrame = CreateFrame("Cooldown", "HekiLightCooldown", display, "CooldownFrameTemplate")
    cooldownFrame:SetAllPoints(display)
    cooldownFrame:SetDrawEdge(true)
    cooldownFrame:SetHideCountdownNumbers(false)

    -- Out-of-range red tint
    rangeOverlay = display:CreateTexture(nil, "OVERLAY")
    rangeOverlay:SetAllPoints(display)
    rangeOverlay:SetColorTexture(1, 0, 0, 0.35)
    rangeOverlay:Hide()

    -- Keybind label (bottom-right corner, like default action bars)
    keybindText = display:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    keybindText:SetPoint("BOTTOMRIGHT", display, "BOTTOMRIGHT", -2, 2)
    keybindText:SetTextColor(1, 1, 1, 1)
    keybindText:SetShadowOffset(1, -1)
    keybindText:SetShadowColor(0, 0, 0, 1)

    -- Thin black border
    local border = CreateFrame("Frame", nil, display, "BackdropTemplate")
    border:SetAllPoints(display)
    border:SetFrameLevel(display:GetFrameLevel() + 2)
    border:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
    })
    border:SetBackdropBorderColor(0, 0, 0, 1)

    display:Hide()
end

-- ── Core Update Logic ─────────────────────────────────────────────────────────

local function Refresh()
    -- SBA not active: hide and bail
    if not C_ActionBar.HasAssistedCombatActionButtons() then
        display:Hide()
        return
    end

    local slots = C_ActionBar.FindAssistedCombatActionButtons()
    if not slots or #slots == 0 then
        display:Hide()
        return
    end

    local slotID  = slots[1]
    local texture = C_ActionBar.GetActionTexture(slotID)

    if not texture then
        display:Hide()
        return
    end

    -- Icon
    iconTexture:SetTexture(texture)

    -- Cooldown
    if db.showCooldown then
        local start, duration = C_ActionBar.GetActionCooldown(slotID)
        if start and start > 0 then
            cooldownFrame:SetCooldown(start, duration)
            cooldownFrame:Show()
        else
            cooldownFrame:Hide()
        end
    else
        cooldownFrame:Hide()
    end

    -- Range indicator
    if db.showOutOfRange and IsOutOfRange(slotID) then
        rangeOverlay:Show()
    else
        rangeOverlay:Hide()
    end

    -- Keybind
    if db.showKeybind then
        keybindText:SetText(GetSlotKeybind(slotID))
        keybindText:Show()
    else
        keybindText:Hide()
    end

    display:Show()
end

-- ── Combat Polling ────────────────────────────────────────────────────────────

-- Poll during combat so the display reacts to every GCD without relying solely
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

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildUI()

    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Refresh()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        elapsed  = db.pollRate  -- fire immediately on next frame
        display:SetScript("OnUpdate", OnUpdate)

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        display:SetScript("OnUpdate", nil)
        display:Hide()

    elseif event == "UPDATE_BINDINGS" then
        Refresh()

    elseif event == "ACTIONBAR_SLOT_CHANGED" then
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

    else
        PrintHelp()
    end
end
