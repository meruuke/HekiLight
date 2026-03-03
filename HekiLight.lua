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
    x           = 0,
    y           = 0,       -- screen center; use /hkl unlock to reposition
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

-- ── UI Construction ───────────────────────────────────────────────────────────

local function BuildUI()
    local size = db.iconSize

    display:SetSize(size, size)
    display:SetScale(db.scale)
    display:SetFrameStrata("HIGH")   -- sit above action bars (MEDIUM)
    display:SetFrameLevel(100)
    display:SetClampedToScreen(true)
    ApplyPosition()

    -- Dark background so the frame is visible even before a texture loads
    local bg = display:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints(display)
    bg:SetColorTexture(0, 0, 0, 0.6)

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

    -- Spell icon (sub-layer 0, above the bg at -1)
    iconTexture = display:CreateTexture(nil, "BACKGROUND", nil, 0)
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

    display:Hide()
    Log("BuildUI complete, size=", size, "strata=HIGH level=100")
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

    -- Cooldown
    if db.showCooldown then
        -- Midnight 12.0: GetActionCooldown returns a table
        -- { startTime, duration, isEnabled, modRate }
        local cd = C_ActionBar.GetActionCooldown(slotID)
        if cd and cd.startTime and cd.startTime > 0 then
            cooldownFrame:SetCooldown(cd.startTime, cd.duration)
            cooldownFrame:Show()
        else
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

    -- Keybind
    if db.showKeybind then
        keybindText:SetText(GetSlotKeybind(slotID))
        keybindText:Show()
    else
        keybindText:Hide()
    end

    display:Show()
    Log("display:Show() called — IsShown:", display:IsShown(),
        "W:", display:GetWidth(), "H:", display:GetHeight(),
        "x:", db.x, "y:", db.y)

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
events:RegisterEvent("ACTIONBAR_UPDATE_STATE")  -- fires when SBA changes highlight

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        BuildUI()

    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
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

    elseif event == "ACTIONBAR_UPDATE_STATE" or
           event == "ACTIONBAR_SLOT_CHANGED" or
           event == "UPDATE_BINDINGS" then
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

    elseif msg == "debug" then
        DEBUG = not DEBUG
        print("|cff88ccffHekiLight:|r Debug output " .. (DEBUG and "ON" or "OFF") .. ".")

    elseif msg == "status" then
        local hasAPI = C_ActionBar.HasAssistedCombatActionButtons ~= nil
        local hasActive = hasAPI and C_ActionBar.HasAssistedCombatActionButtons()
        local slots = hasActive and C_ActionBar.FindAssistedCombatActionButtons() or {}
        print("|cff88ccffHekiLight status:|r")
        print("  API available:", tostring(hasAPI))
        print("  HasAssistedCombatActionButtons:", tostring(hasActive))
        print("  FindAssistedCombatActionButtons slots:", #slots > 0 and table.concat(slots, ", ") or "(none)")
        print("  In combat:", tostring(inCombat))
        print("  Display visible:", tostring(display:IsShown()))
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
