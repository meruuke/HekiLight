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
local L = HekiLightLocale  -- populated by Locale.lua (loaded before this file)
local DEBUG = false  -- toggle with /hkl debug

local function Log(...)
    if DEBUG then print("|cff88ccffHekiLight [DBG]:|r", ...) end
end

-- Forward declarations needed by DLog (defined here so DLog can close over them;
-- InitDB() re-points sessionLog at HekiLightDB.sessionLog after ADDON_LOADED).
local sessionLog      = {}
local lastLogSuggID   = nil
local lastSlotSpellID   = {}  -- [slotIndex] = last spellID logged for that slot (change-detect)
local lastSkippedAlertID = nil  -- last currentAlertSpellID logged as SKIPPED (change-detect)
local lastRangeFailSlot  = nil  -- last rslot that failed IsActionInRange pcall (change-detect)
local lastOverrideLogID  = {}   -- [baseSpellID] = effectiveID last logged as OVERRIDE for secondary slots
local lastRawSuggID      = nil  -- last spellID logged as RAW_SUGG (change-detect)

-- Session event recorder — logs significant state changes (not every tick) to
-- HekiLightDB.sessionLog so they survive until the next /reload.
-- Read them with /hkl log [N] or by opening the SavedVariables file directly.
local MAX_LOG = 500
local function DLog(tag, msg)
    if #sessionLog >= MAX_LOG then table.remove(sessionLog, 1) end
    sessionLog[#sessionLog + 1] = string.format("T=%.2f [%s] %s", GetTime(), tag, msg or "")
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
    showProcAlert     = true,           -- show proc-overlay spells not in the main suggestion as an extra icon to the left
    procAlertLocked   = true,           -- true = proc slot follows main display; false = drag independently
    procAlertX        = 0,              -- saved position when free (UIParent CENTER offset X)
    procAlertY        = 0,              -- saved position when free (UIParent CENTER offset Y)
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
local rangeTicker        -- C_Timer ticker for range overlay pulse animation
local glowTicker         -- C_Timer ticker for proc-glow border pulse on primary slot
local isGlowActive       = false
local alertGlowTicker    -- C_Timer ticker for proc-glow border pulse on proc-alert slot
local isAlertGlowActive  = false
local currentSuggestionID = nil  -- spellID currently displayed (used to filter glow events)
local slots    = {}  -- per-slot tables; populated by BuildSlots(); slots[1] is the primary slot
local MAX_SLOTS = 5  -- maximum number of icon slots (always created; extras hidden)
-- Tracks all spells that currently have an active Blizzard proc overlay
-- (populated by SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE events).
local activeOverlaySpells = {}
local procAlertFrame      -- extra icon shown to the LEFT of display for proc spells not in main suggestion
local currentAlertSpellID = nil  -- spellID currently shown in procAlertFrame (nil = hidden)
local editMode            = false  -- true while Edit Mode is active (slots shown as placeholders)
local EditModeRender      -- forward declaration; assigned after StopPollLoop (avoids ordering issue)
-- Placeholder texture shown in edit mode when a slot has no active suggestion.
local PLACEHOLDER_ICON    = "Interface\\Icons\\INV_Misc_QuestionMark"
-- sessionLog and lastLogSuggID are forward-declared above DLog (before line 30).

-- Pre-allocated suggestion queue — reused every poll to avoid per-frame table allocation.
-- GetSuggestionQueue wipes and repopulates these in-place; callers index queue[1..n].
local queueCache = {}
for i = 1, MAX_SLOTS do queueCache[i] = { spellID = nil, realSlotID = nil, onCooldown = false, overrideSpellID = false } end
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
    -- Preserve previous session's log so it survives the /reload used to flush to disk.
    -- lastSessionLog = what was recorded before this reload; sessionLog = current session.
    HekiLightDB.lastSessionLog = HekiLightDB.sessionLog or {}
    HekiLightDB.sessionLog = {}
    sessionLog = HekiLightDB.sessionLog
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
local SLOT_BINDINGS  = {}
-- spellID → last successful keybind string; survives the transient window at
-- the start of combat / target selection when FindSpellActionButtons may not
-- yet return the regular (non-RA) slot.
local keybindCache         = {}
-- C_Timer.NewTimer handle for the post-shapeshift deferred Refresh(); cancelled
-- if combat starts before it fires (poll loop takes over that path).
local keybindRefreshTimer  = nil
-- spellID → last "key:source" string logged; prevents KEYBIND from flooding the
-- ring buffer at the poll rate (20×/s) when the result doesn't change.
local lastKeybindLog       = {}

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
                    keybindCache[spellID] = key  -- remember for transient-miss recovery
                    Log("GetSpellKeybind:", spellID, "→", key, "(slot", slot, ")")
                    local logEntry = key .. ":slot"
                    if lastKeybindLog[spellID] ~= logEntry then
                        lastKeybindLog[spellID] = logEntry
                        DLog("KEYBIND", string.format("spellID=%d key=%s source=slot", spellID, key))
                    end
                    return key
                end
            end
        end
    end
    -- FindSpellActionButtons may transiently return nil or only RA slots at the
    -- start of combat / target selection.  Return the last known good value so
    -- the keybind text is visible immediately instead of after ACTIONBAR_SLOT_CHANGED.
    local cached = keybindCache[spellID]
    if cached then
        Log("GetSpellKeybind:", spellID, "→", "cache:" .. cached)
        local logEntry = cached .. ":cache"
        if lastKeybindLog[spellID] ~= logEntry then
            lastKeybindLog[spellID] = logEntry
            DLog("KEYBIND", string.format("spellID=%d key=%s source=cache", spellID, cached))
        end
    else
        Log("GetSpellKeybind:", spellID, "→ no keybind found")
        if lastKeybindLog[spellID] ~= ":miss" then
            lastKeybindLog[spellID] = ":miss"
            DLog("KEYBIND", string.format("spellID=%d source=miss", spellID))
        end
    end
    return cached or ""
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
local function ApplyProcAlertLayout()
    if not procAlertFrame then return end
    local size = db.iconSize
    local gap  = db.iconSpacing
    procAlertFrame:SetSize(size, size)
    procAlertFrame:ClearAllPoints()
    if db.procAlertLocked then
        -- Locked: anchored relative to main display, moves with it
        procAlertFrame:SetPoint("TOPRIGHT", display, "TOPLEFT", -gap, 0)
    else
        -- Free: independent saved position (UIParent CENTER offset)
        procAlertFrame:SetPoint("CENTER", UIParent, "CENTER", db.procAlertX or 0, db.procAlertY or 0)
    end
    -- Only capture mouse when proc slot is free AND the main display is unlocked
    procAlertFrame:EnableMouse(not db.locked and not db.procAlertLocked)
end

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
    ApplyProcAlertLayout()
end

local function ApplyKeybindStyle()
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if s and s.keybindText then
            s.keybindText:SetFont("Fonts\\ARIALN.TTF", db.keybindFontSize, db.keybindOutline or "OUTLINE")
            s.keybindText:SetTextColor(db.keybindColorR, db.keybindColorG, db.keybindColorB, 1)
        end
    end
    if procAlertFrame and procAlertFrame.keybindText then
        procAlertFrame.keybindText:SetFont("Fonts\\ARIALN.TTF", db.keybindFontSize, db.keybindOutline or "OUTLINE")
        procAlertFrame.keybindText:SetTextColor(db.keybindColorR, db.keybindColorG, db.keybindColorB, 1)
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
    if procAlertFrame and procAlertFrame.keybindText then
        procAlertFrame.keybindText:ClearAllPoints()
        procAlertFrame.keybindText:SetPoint(anchor, procAlertFrame, anchor, off[1], off[2])
    end
end

local function BuildSlots()
    display:SetScale(db.scale)
    display:SetFrameStrata("HIGH")
    display:SetFrameLevel(10)
    display:SetClampedToScreen(true)
    ApplyPosition()

    -- Edit mode banner — shown above the display row while Edit Mode is active
    display.editBanner = display:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    display.editBanner:SetPoint("BOTTOM", display, "TOP", 0, 6)
    display.editBanner:SetText(L["EDIT_BANNER"])
    display.editBanner:Hide()

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

            -- Proc-glow overlay: pulsing additive gold texture on the icon (primary slot only)
            local glowOvl = slot.frame:CreateTexture(nil, "OVERLAY")
            glowOvl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            glowOvl:SetAllPoints(slot.frame)
            glowOvl:SetBlendMode("ADD")
            glowOvl:SetVertexColor(1, 0.85, 0)
            glowOvl:SetAlpha(0)
            slot.glowOverlay = glowOvl
        end

        -- Keybind label — all slots get one; style/anchor applied below via ApplyKeybindStyle()/ApplyKeybindAnchor()
        slot.keybindText = slot.frame:CreateFontString(nil, "OVERLAY")

        -- Edit mode slot number label (centered, shown only while Edit Mode is active)
        slot.editLabel = slot.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        slot.editLabel:SetPoint("CENTER")
        slot.editLabel:SetText(tostring(i))
        slot.editLabel:SetTextColor(1, 1, 0.3, 0.9)
        slot.editLabel:Hide()

        slot.frame:Hide()
        slots[i] = slot
    end

    ApplySlotLayout()
    ApplyKeybindStyle()
    ApplyKeybindAnchor()

    -- Proc-alert icon: parented to UIParent (NOT display) so it can appear even
    -- when the main display is hidden (e.g. no RA suggestion yet, out of combat).
    -- Positioning is still anchored to display via SetPoint in ApplyProcAlertLayout.
    procAlertFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    procAlertFrame:SetFrameStrata("HIGH")
    procAlertFrame:SetFrameLevel(display:GetFrameLevel() + 1)
    procAlertFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    procAlertFrame:SetBackdropColor(0, 0, 0, 0.7)
    procAlertFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
    procAlertFrame.iconTexture = procAlertFrame:CreateTexture(nil, "ARTWORK")
    procAlertFrame.iconTexture:SetAllPoints(procAlertFrame)
    procAlertFrame.iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    procAlertFrame.glowOverlay = procAlertFrame:CreateTexture(nil, "OVERLAY")
    procAlertFrame.glowOverlay:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    procAlertFrame.glowOverlay:SetAllPoints(procAlertFrame)
    procAlertFrame.glowOverlay:SetBlendMode("ADD")
    procAlertFrame.glowOverlay:SetVertexColor(1, 0.85, 0)
    procAlertFrame.glowOverlay:SetAlpha(0)
    procAlertFrame.keybindText = procAlertFrame:CreateFontString(nil, "OVERLAY")

    -- Edit mode labels for the proc-alert slot
    procAlertFrame.editLabel = procAlertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    procAlertFrame.editLabel:SetPoint("CENTER", procAlertFrame, "CENTER", 0, 8)
    procAlertFrame.editLabel:SetText("|cffffcc00PROC|r")
    procAlertFrame.editLabel:Hide()
    procAlertFrame.lockLabel = procAlertFrame:CreateFontString(nil, "OVERLAY")
    procAlertFrame.lockLabel:SetFont("Fonts\\ARIALN.TTF", 9, "OUTLINE")
    procAlertFrame.lockLabel:SetPoint("CENTER", procAlertFrame, "CENTER", 0, -8)
    procAlertFrame.lockLabel:Hide()

    -- Independent drag support for the proc-alert slot.
    -- Only active when procAlertLocked = false AND the main display is unlocked.
    procAlertFrame:SetMovable(true)
    procAlertFrame:RegisterForDrag("LeftButton")
    procAlertFrame:SetScript("OnDragStart", function(self)
        if not db.locked and not db.procAlertLocked then
            self:StartMoving()
        end
    end)
    procAlertFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        db.procAlertX = math.floor(x + 0.5)
        db.procAlertY = math.floor(y + 0.5)
    end)

    procAlertFrame:Hide()
    ApplyProcAlertLayout()
    ApplyKeybindStyle()
    ApplyKeybindAnchor()

    display:Hide()
    Log("BuildSlots complete, maxSlots=", MAX_SLOTS, "showing=", db.numSuggestions)
end

-- ── Minimap Button ────────────────────────────────────────────────────────────

local minimapBtn
local settingsCategory
local libDBIconRef  -- set when LibDBIcon registration succeeds; nil means manual button is active

local function UpdateMinimapPos()
    local angle = math.rad(db.minimapAngle or 225)
    local r = (Minimap:GetWidth() / 2) + 5  -- dynamic: sits 5px outside the minimap edge
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER",
        r * math.cos(angle),
        r * math.sin(angle))
end

local function SetMinimapShown(shown)
    db.minimapShow = shown
    if libDBIconRef then
        if shown then libDBIconRef:Show("HekiLight") else libDBIconRef:Hide("HekiLight") end
        if db.minimapDB then db.minimapDB.hide = not shown end
    elseif minimapBtn then
        minimapBtn:SetShown(shown)
    end
end

local function BuildMinimapButton()
    -- Prefer LibDBIcon when available (loaded by Details, LeatrixPlus, etc.).
    -- This makes LeatrixPlus treat us as a first-class button: grouped in the
    -- bag with no "use LibDBIcon" warning tooltip.
    local ldb     = LibStub and LibStub("LibDataBroker-1.1", true)
    local libIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if ldb and libIcon then
        local ok, dataObj = pcall(function()
            return ldb:NewDataObject("HekiLight", {
                type  = "launcher",
                icon  = "Interface\\AddOns\\HekiLight\\assets\\icon",
                OnClick = function(_, btn)
                    if btn == "LeftButton" and settingsCategory then
                        Settings.OpenToCategory(settingsCategory:GetID())
                    end
                end,
                OnTooltipShow = function(tip)
                    tip:AddLine("|cff88ccffHekiLight|r")
                    tip:AddLine(L["Click to open settings"], 1, 1, 1)
                    tip:AddLine(L["Drag to reposition"], 0.7, 0.7, 0.7)
                end,
            })
        end)
        if ok and dataObj then
            -- db.minimapDB persists LibDBIcon's angle + hide state across sessions.
            -- Seed minimapPos from db.minimapAngle on first use.
            db.minimapDB = db.minimapDB or {minimapPos = db.minimapAngle or 225, hide = false}
            db.minimapDB.hide = not (db.minimapShow ~= false)
            pcall(libIcon.Register, libIcon, "HekiLight", dataObj, db.minimapDB)
            libDBIconRef = libIcon
            return  -- LibDBIcon manages its own frame; no manual button needed
        end
    end

    -- Fallback: manual button (used when no LibDBIcon-embedding addon is loaded).
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
    icon:SetTexture("Interface\\AddOns\\HekiLight\\assets\\icon")
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
        GameTooltip:AddLine(L["Click to open settings"], 1, 1, 1)
        GameTooltip:AddLine(L["Drag to reposition"], 0.7, 0.7, 0.7)
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
    subtitle:SetText(L["Rotation assistant icon overlay"] .. "  |cff666666v" .. version .. "|r")

    -- ScrollFrame: sits below the title, leaves 36 px at the bottom for the Reset button.
    local scrollFrame = CreateFrame("ScrollFrame", "HekiLightScrollFrame", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -52)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 36)

    -- Content frame: scroll child. Width fixed; height computed by LayoutSections().
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(592)   -- 620 - 28 (scrollbar)
    scrollFrame:SetScrollChild(content)

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
        if startExpanded == nil then startExpanded = false end
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
    local _, appBody = MakeSection(L["Appearance"])
    local cur = { y = -8 }
    SL(appBody, cur, L["Overall Scale"], 0.2, 3.0, 0.1,
        function() return db.scale end,
        function(v) db.scale = v; display:SetScale(v) end,
        L["Scales the entire HekiLight overlay — icons, spacing, and keybind text."])
    SL(appBody, cur, L["Icon Size"], 16, 256, 8,
        function() return db.iconSize end,
        function(v) db.iconSize = v; ApplySlotLayout(); Refresh() end,
        L["Sets the raw pixel size of the spell icon texture."])
    SL(appBody, cur, L["Spell Icon Slots"], 1, 5, 1,
        function() return db.numSuggestions end,
        function(v) db.numSuggestions = v; ApplySlotLayout(); Refresh() end,
        L["Number of spell icons to display (1 = primary only, up to 5)."])
    SL(appBody, cur, L["Icon Spacing"], 0, 32, 2,
        function() return db.iconSpacing end,
        function(v) db.iconSpacing = v; ApplySlotLayout(); Refresh() end)
    SL(appBody, cur, L["Refresh Rate (s)"], 0.02, 0.5, 0.01,
        function() return db.pollRate end,
        function(v) db.pollRate = v end,
        L["How often (seconds) the suggestion bar refreshes."])
    CB(appBody, cur, L["Lock position"],
        L["Prevent the icon from being accidentally dragged. Use /hkl unlock to reposition it."],
        function() return db.locked end,
        function(v)
            db.locked = v
            display:EnableMouse(not v)
            print("|cff88ccffHekiLight:|r " .. (v and L["Position locked."] or L["Position unlocked — drag to reposition."]))
        end)
    appBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Display ─────────────────────────────────────────────────────
    local _, dispBody = MakeSection(L["Display"])
    cur = { y = -8 }
    CB(dispBody, cur, L["Show keybind text"],
        L["Show the keybind for the suggested spell in the corner of the icon."],
        function() return db.showKeybind end,
        function(v) db.showKeybind = v; if not v then for i = 1, MAX_SLOTS do if slots[i] and slots[i].keybindText then slots[i].keybindText:Hide() end end end end)
    CB(dispBody, cur, L["Show out-of-range tint"],
        L["Pulse the icon red when the suggested spell cannot reach your target."],
        function() return db.showOutOfRange end,
        function(v) db.showOutOfRange = v; if not v and slots[1] and slots[1].rangeOverlay then slots[1].rangeOverlay:Hide() end end)
    CB(dispBody, cur, L["Spell Proc Glow"],
        L["Pulse the icon border gold when the suggested spell has an active proc glow."],
        function() return db.showProcGlow end,
        function(v) db.showProcGlow = v; if not v then StopGlowPulse() end end)
    CB(dispBody, cur, L["Show proc-alert icon"],
        L["Show an extra icon to the left when a proc spell is active but not the main suggestion."],
        function() return db.showProcAlert end,
        function(v) db.showProcAlert = v; Refresh() end)
    CB(dispBody, cur, L["Lock proc-alert to main display"],
        L["When checked, the proc icon moves with the main suggestion row. Uncheck to drag it independently."],
        function() return db.procAlertLocked end,
        function(v)
            if not v and procAlertFrame then
                -- Capture the current on-screen position before releasing the anchor,
                -- so the frame stays exactly where it is — no jump to defaults.
                local sx, sy = procAlertFrame:GetCenter()
                local ux, uy = UIParent:GetCenter()
                db.procAlertX = math.floor((sx - ux) + 0.5)
                db.procAlertY = math.floor((sy - uy) + 0.5)
            end
            db.procAlertLocked = v
            ApplyProcAlertLayout()
            if editMode then EditModeRender() end  -- update lock indicator in edit mode
        end)
    CB(dispBody, cur, L["Show cooldown spiral"],
        L["Display a cooldown sweep on the icon."],
        function() return db.showCooldown end,
        function(v) db.showCooldown = v; if not v and slots[1] and slots[1].cooldownFrame then slots[1].cooldownFrame:Hide() end end)
    CB(dispBody, cur, L["Play sounds"],
        L["Play a subtle click when the icon appears as you enter combat."],
        function() return db.sounds end,
        function(v) db.sounds = v end)
    CB(dispBody, cur, L["Show minimap button"],
        L["Show the HekiLight button on the minimap. Drag it to reposition."],
        function() return db.minimapShow ~= false end,
        function(v) SetMinimapShown(v) end)
    dispBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Keybind Style ───────────────────────────────────────────────
    local _, kbBody = MakeSection(L["Keybind Style"])
    cur = { y = -8 }
    SL(kbBody, cur, L["Font Size"], 8, 24, 1,
        function() return db.keybindFontSize end,
        function(v) db.keybindFontSize = v; ApplyKeybindStyle(); Refresh() end)

    -- Color label + swatch (not a standard widget, built inline)
    local colorLblStr = kbBody:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorLblStr:SetPoint("TOPLEFT", 14, cur.y)
    colorLblStr:SetText(L["Color"])
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
        GameTooltip:AddLine(L["Keybind Color"])
        GameTooltip:AddLine(L["Click to open the color picker."], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    colorSwatch:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cur.y = cur.y - 28

    SubHdr(kbBody, cur, L["Outline Style"])
    RG(kbBody, cur, {
        { label = L["Outline"],       value = "OUTLINE",      tip = L["Thin border around each character."] },
        { label = L["Thick Outline"], value = "THICKOUTLINE", tip = L["Bold border — readable at small sizes."] },
        { label = L["None"],          value = "",             tip = L["No outline — flat text."] },
    }, function() return db.keybindOutline or "OUTLINE" end,
       function(v) db.keybindOutline = v; ApplyKeybindStyle() end)

    SubHdr(kbBody, cur, L["Corner Position"])
    RG(kbBody, cur, {
        { label = L["Bottom Right"], value = "BOTTOMRIGHT" },
        { label = L["Bottom Left"],  value = "BOTTOMLEFT"  },
        { label = L["Top Right"],    value = "TOPRIGHT"    },
        { label = L["Top Left"],     value = "TOPLEFT"     },
        { label = L["Center"],       value = "CENTER"      },
    }, function() return db.keybindAnchor or "BOTTOMRIGHT" end,
       function(v) db.keybindAnchor = v; ApplyKeybindAnchor() end)
    kbBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Visibility ──────────────────────────────────────────────────
    local _, visBody = MakeSection(L["Visibility"])
    cur = { y = -8 }
    SubHdr(visBody, cur, L["Show Overlay"])
    RG(visBody, cur, {
        { label = L["Always"],
          value = "always",
          tip   = L["Show the overlay whenever Rotation Assistant has a suggestion."] },
        { label = L["In Combat or Attackable Target"],
          value = "active",
          tip   = L["Only show when in combat, or when you have an attackable target selected."] },
    }, function() return db.showMode or "always" end,
       function(v) db.showMode = v end)
    SubHdr(visBody, cur, L["Always Hide When"])
    CB(visBody, cur, L["Dead or Ghost"],
        L["Hide the overlay while you are dead or a ghost."],
        function() return db.hideWhenDead end,
        function(v) db.hideWhenDead = v; Refresh() end)
    CB(visBody, cur, L["In a cinematic"],
        L["Hide the overlay during in-game cinematics and movies."],
        function() return db.hideWhenCinematic end,
        function(v) db.hideWhenCinematic = v; Refresh() end)
    CB(visBody, cur, L["In a vehicle"],
        L["Hide the overlay while riding a vehicle with its own action bar."],
        function() return db.hideWhenVehicle end,
        function(v) db.hideWhenVehicle = v; Refresh() end)
    visBody:SetHeight(math.abs(cur.y) + 8)

    -- ── Section: Ignored Spells (collapsed by default) ───────────────────────
    local ignoreSec, ignoreBody = MakeSection(L["Ignored Spells"], false)

    local ignoreDesc = ignoreBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ignoreDesc:SetPoint("TOPLEFT", 10, -8)
    ignoreDesc:SetWidth(570)
    ignoreDesc:SetJustifyH("LEFT")
    ignoreDesc:SetText(L["Spells hidden from the secondary suggestion list. Select a spell and click Add.\n|cffaaaaaa Requires Rotation Assistant to be active.|r"])

    local selectedIgnoreSpellID = nil
    local rowPool = {}
    local ignoreEmptyLabel = nil
    local RefreshIgnoreList      -- forward declaration

    -- UIDropDownMenu has ~18 px inherent left padding; offset by -2 to align
    local ignoreDD = CreateFrame("Frame", "HekiLightIgnoreDropdown", ignoreBody, "UIDropDownMenuTemplate")
    ignoreDD:SetPoint("TOPLEFT", -2, -46)
    UIDropDownMenu_SetWidth(ignoreDD, 240)
    UIDropDownMenu_SetText(ignoreDD, L["Select a rotation spell..."])

    local addBtn = CreateFrame("Button", nil, ignoreBody, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", ignoreDD, "RIGHT", -4, 2)
    addBtn:SetSize(130, 22)
    addBtn:SetText(L["Add to ignore list"])
    addBtn:SetScript("OnClick", function()
        if not selectedIgnoreSpellID then
            print("|cff88ccffHekiLight:|r " .. L["Select a spell from the dropdown first."])
            return
        end
        if dbChar.ignoredSpells[selectedIgnoreSpellID] then
            print("|cff88ccffHekiLight:|r " .. L["That spell is already ignored."])
            return
        end
        dbChar.ignoredSpells[selectedIgnoreSpellID] = true
        local si = C_Spell.GetSpellInfo(selectedIgnoreSpellID)
        local name = si and si.name or tostring(selectedIgnoreSpellID)
        print("|cff88ccffHekiLight:|r " .. name .. " [" .. selectedIgnoreSpellID .. "]" .. L[" will no longer appear in the secondary list."])
        selectedIgnoreSpellID = nil
        UIDropDownMenu_SetText(ignoreDD, L["Select a rotation spell..."])
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
            info.text     = "|cff888888" .. L["No rotation spells available"] .. "|r"
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
                row.removeBtn:SetText(L["Remove"])
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
            ignoreEmptyLabel:SetText(L["No spells are currently ignored."])
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
            UIDropDownMenu_SetText(ignoreDD, n == 1 and L["HINT_SPELL_SINGULAR"] or string.format(L["HINT_SPELL_PLURAL"], n))
        else
            UIDropDownMenu_SetText(ignoreDD, L["Select a rotation spell..."])
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
    resetBtn:SetText(L["Reset to Defaults"])
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
        print("|cff88ccffHekiLight:|r " .. L["All settings reset to defaults."])
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

-- Forward declaration: GetRealSlot is defined after GetActiveSuggestion in this
-- section but is needed by the out-of-combat fallback inside GetActiveSuggestion.
local GetRealSlot

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
        if spellID and spellID ~= lastRawSuggID then
            local si = C_Spell.GetSpellInfo(spellID)
            DLog("RAW_SUGG", string.format("GetNextCastSpell=%d name=%s iconID=%s",
                spellID, si and si.name or "?", tostring(si and si.iconID)))
            lastRawSuggID = spellID
        end
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
            if spellID and spellID ~= lastRawSuggID then
                local si = C_Spell.GetSpellInfo(spellID)
                DLog("RAW_SUGG", string.format("Fallback slot=%d spellID=%d name=%s iconID=%s",
                    sbaSlot, spellID, si and si.name or "?", tostring(si and si.iconID)))
                lastRawSuggID = spellID
            end
        end
    end

    if not spellID then
        -- Out-of-combat fallback for secondary-form spells (e.g. Cat Form for Resto Druid).
        -- GetNextCastSpell returns nil for these before combat starts. Find the first usable
        -- rotation spell so suggestions appear on target acquisition without entering combat.
        if not inCombat and UnitCanAttack("player", "target") and C_AssistedCombat.GetRotationSpells then
            local okF, rotF = pcall(C_AssistedCombat.GetRotationSpells)
            if okF and rotF then
                for _, sid in ipairs(rotF) do
                    local rslot = GetRealSlot(sid)
                    if rslot and IsUsableAction(rslot) then
                        spellID = sid
                        break
                    end
                end
            end
        end
        if not spellID then
            Log("No active suggestion found")
            return nil, nil
        end
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

    -- RA returns the base spellID even when a talent replaces it (e.g. Death and Decay → Defile).
    -- GetActionInfo on the real bar slot returns the overriding spell, giving us the correct icon.
    if realSlotID then
        local ok, overrideID = pcall(function()
            local t, id = GetActionInfo(realSlotID)
            return (t == "spell") and id or nil
        end)
        if ok and overrideID and overrideID ~= spellID then
            DLog("OVERRIDE", string.format("spellID %d → %d via slot %d", spellID, overrideID, realSlotID))
            spellID = overrideID
        end
    end

    Log("Active suggestion: spellID=", spellID, "realSlot=", tostring(realSlotID))
    return spellID, realSlotID
end

-- Returns the first regular action bar slot for a spellID.
-- Used for range checks and keybind lookups on secondary rotation spells.
GetRealSlot = function(spellID)
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

-- Returns realSlotID and effectiveSpellID for a secondary rotation spell.
-- GetRotationSpells() returns base IDs; this mirrors the override resolution in
-- GetActiveSuggestion so dedup and icon display are correct for talent replacements
-- (e.g. Defile shows Defile icon and deduplicates against primaryID correctly).
local function resolveSecondary(sid)
    local rslot = GetRealSlot(sid)
    local effectiveID = sid
    if rslot then
        local ok, oid = pcall(function()
            local t, id = GetActionInfo(rslot)
            return (t == "spell") and id or nil
        end)
        if ok and oid and oid ~= sid then
            effectiveID = oid
        end
    end
    return rslot, effectiveID
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
        queueCache[i].spellID        = nil
        queueCache[i].realSlotID     = nil
        queueCache[i].onCooldown     = false
        queueCache[i].overrideSpellID = false
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
                if not dbChar.ignoredSpells[sid] and IsPlayerSpell(sid) then
                    local rslot, effectiveID = resolveSecondary(sid)
                    -- Dedup against primaryID using the effective (cast) ID, not the base ID.
                    -- GetRotationSpells returns base IDs; primaryID is an override ID.
                    if effectiveID ~= primaryID and not IsSpellOnCooldown(sid) and rslot and IsUsableAction(rslot) then
                        if effectiveID ~= sid and lastOverrideLogID[sid] ~= effectiveID then
                            DLog("OVERRIDE", string.format("secondary spellID %d → %d via slot %d", sid, effectiveID, rslot))
                            lastOverrideLogID[sid] = effectiveID
                        end
                        queueCount = queueCount + 1
                        queueCache[queueCount].spellID        = sid
                        queueCache[queueCount].realSlotID     = rslot
                        queueCache[queueCount].overrideSpellID = effectiveID ~= sid and effectiveID or false
                        queueCache[queueCount].onCooldown     = false
                    end
                end
            end
            -- Pass 2: on-cooldown spells fill any remaining slots (low priority, greyed out)
            if queueCount < n then
                for _, sid in ipairs(rotSpells) do
                    if queueCount >= n then break end
                    if not dbChar.ignoredSpells[sid] and IsPlayerSpell(sid) then
                        local rslot, effectiveID = resolveSecondary(sid)
                        if effectiveID ~= primaryID and IsSpellOnCooldown(sid) and rslot and IsUsableAction(rslot) then
                            queueCount = queueCount + 1
                            queueCache[queueCount].spellID        = sid
                            queueCache[queueCount].realSlotID     = rslot
                            queueCache[queueCount].overrideSpellID = effectiveID ~= sid and effectiveID or false
                            queueCache[queueCount].onCooldown     = true
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
    if slots[1] and slots[1].glowOverlay then
        slots[1].glowOverlay:SetAlpha(0)
    end
end

local function StartGlowPulse()
    if isGlowActive then return end
    isGlowActive = true
    local t, dir = 0, 1
    glowTicker = C_Timer.NewTicker(0.05, function()
        t = t + dir * 0.06
        if t >= 1 then t = 1; dir = -1
        elseif t <= 0 then t = 0; dir = 1 end
        if slots[1] and slots[1].glowOverlay then
            slots[1].glowOverlay:SetAlpha(t * 0.7)
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

local function StopAlertGlowPulse()
    if not isAlertGlowActive then return end  -- nothing to stop; skip log noise
    DLog("ALERT_GLOW", "stopped")
    if alertGlowTicker then alertGlowTicker:Cancel(); alertGlowTicker = nil end
    isAlertGlowActive = false
    if not procAlertFrame then return end
    -- Stop ActionBarButtonSpellActivationAlert overlay if it was created
    if procAlertFrame.spellOverlay then
        local ov = procAlertFrame.spellOverlay
        if ov.animIn and ov.animIn:IsPlaying() then pcall(ov.animIn.Stop, ov.animIn) end
        if ov.animOut then pcall(ov.animOut.Play, ov.animOut) end
    end
    -- Reset fallback texture and border
    if procAlertFrame.glowOverlay then procAlertFrame.glowOverlay:SetAlpha(0) end
    procAlertFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
end

local function StartAlertGlowPulse()
    if isAlertGlowActive then return end
    isAlertGlowActive = true
    if not procAlertFrame then return end

    -- Attempt 1: ActionBarButtonSpellActivationAlert frame template (same XML the action bar uses).
    -- ActionButton_ShowOverlayGlow was removed in Midnight 12.0 but the template may still exist.
    if not procAlertFrame.spellOverlay then
        local ok, overlay = pcall(CreateFrame, "Frame", nil, procAlertFrame, "ActionBarButtonSpellActivationAlert")
        if ok and overlay then
            local sz = procAlertFrame:GetWidth() * 1.4
            overlay:SetSize(sz, sz)
            overlay:SetPoint("CENTER")
            procAlertFrame.spellOverlay = overlay
        end
    end
    if procAlertFrame.spellOverlay then
        local ov = procAlertFrame.spellOverlay
        if ov.animOut and ov.animOut:IsPlaying() then pcall(ov.animOut.Stop, ov.animOut) end
        if ov.animIn then
            local ok = pcall(ov.animIn.Play, ov.animIn)
            if ok then
                DLog("ALERT_GLOW", "started: ActionBarButtonSpellActivationAlert template")
                return
            end
        end
    end

    -- Fallback: aggressive ButtonHilight pulse + backdrop border color flash.
    -- Much more visible than the previous subtle ticker: full alpha, fast cycle, gold border.
    DLog("ALERT_GLOW", "started: fallback ticker (template unavailable)")
    local t, dir = 0, 1
    alertGlowTicker = C_Timer.NewTicker(0.033, function()  -- ~30fps
        t = t + dir * 0.15
        if t >= 1 then t = 1; dir = -1
        elseif t <= 0 then t = 0; dir = 1 end
        if procAlertFrame then
            if procAlertFrame.glowOverlay then
                procAlertFrame.glowOverlay:SetAlpha(t)  -- full 1.0 alpha
            end
            -- Border flashes gold → bright white and back
            procAlertFrame:SetBackdropBorderColor(1, 0.82 + t * 0.18, t, 1)
        end
    end)
end

-- Show or hide the proc-alert icon (the extra frame to the LEFT of display).
-- Sets currentAlertSpellID so Refresh()'s slot loop can exclude duplicates.
-- Must be called BEFORE the secondary slot render loop in Refresh().
--
-- Candidate sources (combined):
--   1. activeOverlaySpells — event-tracked; reliable when GLOW_SHOW fired this session.
--   2. cachedRotSpells / GetRotationSpells() — catches procs that were already active
--      before the addon loaded (after a /reload with proc up, GLOW_SHOW never re-fires).
-- For each candidate, C_SpellActivationOverlay.IsSpellOverlayed() is queried directly
-- (same pattern as UpdateGlowState does for the primary slot).
local function UpdateProcAlert(primarySpellID)
    currentAlertSpellID = nil
    if not procAlertFrame or not db.showProcAlert then
        if procAlertFrame then procAlertFrame:Hide() end
        return
    end

    -- Build candidate set from all known sources
    local candidates = {}
    for sid in pairs(activeOverlaySpells) do candidates[sid] = true end
    -- Use the cached rotation list; if not yet populated, ask the engine directly
    local rotList = (#cachedRotSpells > 0) and cachedRotSpells or nil
    if not rotList then
        local ok, live = pcall(C_AssistedCombat.GetRotationSpells)
        rotList = (ok and type(live) == "table") and live or nil
    end
    if rotList then
        for _, sid in ipairs(rotList) do candidates[sid] = true end
    end

    -- Pick the first candidate that is currently overlayed and is not the primary suggestion
    local alertSpellID
    for spellID in pairs(candidates) do
        if spellID ~= primarySpellID and C_SpellActivationOverlay.IsSpellOverlayed(spellID) then
            alertSpellID = spellID
            break
        end
    end

    if alertSpellID then
        local si = C_Spell.GetSpellInfo(alertSpellID)
        if si and si.iconID then
            procAlertFrame.iconTexture:SetTexture(si.iconID)
            if db.showKeybind and procAlertFrame.keybindText then
                procAlertFrame.keybindText:SetText(GetSpellKeybind(alertSpellID))
                procAlertFrame.keybindText:Show()
            elseif procAlertFrame.keybindText then
                procAlertFrame.keybindText:Hide()
            end
            currentAlertSpellID = alertSpellID
            if not procAlertFrame:IsShown() then
                DLog("ALERT_SHOW", string.format("spellID=%d (%s)", alertSpellID, si.name or "?"))
            end
            procAlertFrame:Show()
            StartAlertGlowPulse()  -- proc alert always glows (it only shows for proc spells)
            return
        end
    end
    if procAlertFrame:IsShown() then
        DLog("ALERT_HIDE", "no overlayed candidate found")
        lastSkippedAlertID = nil
    end
    if procAlertFrame.keybindText then procAlertFrame.keybindText:Hide() end
    StopAlertGlowPulse()
    procAlertFrame:Hide()
end


Refresh = function()
    if #slots == 0 then return end  -- BuildSlots not yet called
    if editMode then EditModeRender(); return end  -- edit mode: placeholder rendering, skip normal RA logic

    local showOk, reason = ShouldShow()
    if not showOk then
        -- Hard stop (dead / vehicle / cinematic) — suppress proc alert too
        if currentSuggestionID ~= nil then
            DLog("SUPPRESS", "ShouldShow=false reason=" .. tostring(reason))
        end
        currentSuggestionID = nil
        lastLogSuggID = nil
        lastRawSuggID = nil
        lastSkippedAlertID = nil
        wipe(lastOverrideLogID)
        StopGlowPulse()
        StopAlertGlowPulse()
        currentAlertSpellID = nil
        if procAlertFrame then procAlertFrame:Hide() end
        display:Hide()
        Log("display suppressed — reason:", reason)
        return
    end

    local queue   = GetSuggestionQueue(db.numSuggestions)
    local primary = queue[1]

    if not primary or not primary.spellID then
        -- RA has no suggestion yet (pre-combat / RA idle) but a proc may still
        -- be active — update the proc alert independently of the main display.
        Log("No active suggestion — hiding display")
        currentSuggestionID = nil
        StopGlowPulse()
        UpdateProcAlert(nil)
        display:Hide()
        return
    end

    local primaryInfo = C_Spell.GetSpellInfo(primary.spellID)
    if not primaryInfo or not primaryInfo.iconID then
        Log("No spell info for", primary.spellID, "— hiding display")
        currentSuggestionID = nil
        StopGlowPulse()
        UpdateProcAlert(nil)
        display:Hide()
        return
    end

    -- Resolve proc-alert BEFORE the slot loop so currentAlertSpellID is set and
    -- secondary slots can skip any spell already claimed by the proc-alert slot.
    UpdateProcAlert(primary.spellID)

    -- Update each slot's icon texture.
    -- Priority: 1) main suggestion (slot 1), 2) proc-alert slot (left of display),
    -- 3) secondary slots — filled sequentially from the queue, skipping any spell
    --    already claimed by the proc-alert so there are never visual gaps.
    local nextQueueIdx = 2  -- queue read pointer for secondary slots (slots 2+)
    for i = 1, db.numSuggestions do
        local slot  = slots[i]
        local entry
        if i == 1 then
            entry = queue[1]
        else
            -- Advance past any entry already shown in the proc-alert slot
            while nextQueueIdx <= queueCount and
                  queue[nextQueueIdx].spellID == currentAlertSpellID do
                if lastSkippedAlertID ~= currentAlertSpellID then
                    local si2 = C_Spell.GetSpellInfo(queue[nextQueueIdx].spellID)
                    DLog("SLOT", string.format("queue[%d] SKIPPED (alert has it) spellID=%d (%s)",
                        nextQueueIdx, queue[nextQueueIdx].spellID, si2 and si2.name or "?"))
                    lastSkippedAlertID = currentAlertSpellID
                end
                nextQueueIdx = nextQueueIdx + 1
            end
            entry = (nextQueueIdx <= queueCount) and queue[nextQueueIdx] or nil
            nextQueueIdx = nextQueueIdx + 1
        end

        if entry and entry.spellID then
            local iconID = (i == 1) and entry.spellID or (entry.overrideSpellID or entry.spellID)
            local si = (i == 1) and primaryInfo or C_Spell.GetSpellInfo(iconID)
            if si and si.iconID then
                if i > 1 and lastSlotSpellID[i] ~= entry.spellID then
                    DLog("SLOT", string.format("slot=%d spellID=%d (%s)", i, entry.spellID, si.name or "?"))
                    lastSlotSpellID[i] = entry.spellID
                end
                slot.iconTexture:SetTexture(si.iconID)
                slot.iconTexture:SetDesaturated(i > 1 and entry.onCooldown)
                slot.frame:Show()
                if db.showKeybind and slot.keybindText then
                    -- Two-stage lookup: prefer realSlotID direct binding, fall back to
                    -- GetSpellKeybind (which has keybindCache). The naive `realSlotID and
                    -- GetSlotKeybind(...) or GetSpellKeybind(...)` form silently skips the
                    -- fallback when GetSlotKeybind returns "" because "" is truthy in Lua.
                    local kb = ""
                    if entry.realSlotID then
                        kb = GetSlotKeybind(entry.realSlotID)
                        if kb ~= "" then
                            keybindCache[entry.spellID] = kb  -- keep cache warm for post-shapeshift transient
                            local logEntry = kb .. ":realslot"
                            if lastKeybindLog[entry.spellID] ~= logEntry then
                                lastKeybindLog[entry.spellID] = logEntry
                                DLog("KEYBIND", string.format("spellID=%d key=%s source=realslot slot=%d", entry.spellID, kb, entry.realSlotID))
                            end
                        end
                    end
                    if kb == "" then
                        kb = GetSpellKeybind(entry.overrideSpellID or entry.spellID)
                    end
                    slot.keybindText:SetText(kb)
                    slot.keybindText:Show()
                elseif slot.keybindText then
                    slot.keybindText:Hide()
                end
            else
                if i > 1 and lastSlotSpellID[i] ~= nil then
                    DLog("SLOT", string.format("slot=%d hidden (no spellinfo)", i))
                    lastSlotSpellID[i] = nil
                end
                slot.iconTexture:SetDesaturated(false)
                slot.frame:Hide()
                if slot.keybindText then slot.keybindText:Hide() end
            end
        else
            if i > 1 and lastSlotSpellID[i] ~= nil then
                DLog("SLOT", string.format("slot=%d hidden (no entry)", i))
                lastSlotSpellID[i] = nil
            end
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
    if sid ~= lastLogSuggID then
        DLog("SUGGEST", string.format("spellID=%d name=%s iconID=%s",
            sid, primaryInfo.name or "?", tostring(primaryInfo.iconID)))
        lastLogSuggID = sid
    end
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
        local okR, inRange = pcall(C_ActionBar.IsActionInRange, rslot)
        if not okR then
            if rslot ~= lastRangeFailSlot then
                DLog("SLOT", string.format("IsActionInRange pcall failed for slot %d", rslot))
                lastRangeFailSlot = rslot
            end
            inRange = nil
        end
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

-- ── Edit Mode ─────────────────────────────────────────────────────────────────

-- Renders all slot frames as visible placeholders. Called by Refresh() whenever
-- editMode is true, bypassing the normal RA suggestion pipeline entirely.
EditModeRender = function()
    display:Show()

    for i = 1, db.numSuggestions do
        local s = slots[i]
        if s then
            s.frame:Show()
            -- Use placeholder only if no real spell icon is currently loaded
            if not s.iconTexture:GetTexture() then
                s.iconTexture:SetTexture(PLACEHOLDER_ICON)
            end
            s.iconTexture:SetDesaturated(false)
            if s.editLabel   then s.editLabel:Show() end
            if s.keybindText then s.keybindText:Hide() end
            if s.rangeOverlay then s.rangeOverlay:Hide() end
        end
    end
    -- Hide slots beyond numSuggestions
    for i = db.numSuggestions + 1, MAX_SLOTS do
        if slots[i] then slots[i].frame:Hide() end
    end

    if procAlertFrame then
        procAlertFrame:Show()
        if not procAlertFrame.iconTexture:GetTexture() then
            procAlertFrame.iconTexture:SetTexture(PLACEHOLDER_ICON)
        end
        -- In edit mode drag is allowed regardless of db.locked; locked state
        -- only controls whether proc moves independently or with the display.
        procAlertFrame:EnableMouse(not db.procAlertLocked)
        if procAlertFrame.editLabel then procAlertFrame.editLabel:Show() end
        if procAlertFrame.lockLabel then
            if db.procAlertLocked then
                procAlertFrame.lockLabel:SetText(L["PROC_LOCK_LABEL"])
            else
                procAlertFrame.lockLabel:SetText(L["PROC_FREE_LABEL"])
            end
            procAlertFrame.lockLabel:Show()
        end
        if procAlertFrame.keybindText then procAlertFrame.keybindText:Hide() end
    end

    if display.editBanner then display.editBanner:Show() end
end

local function EnterEditMode()
    editMode = true
    StopPollLoop()
    display:EnableMouse(true)  -- always draggable in edit mode, regardless of db.locked
    EditModeRender()
    local lockStatus = db.procAlertLocked and L["PROC_LOCKED_STATUS"] or L["PROC_FREE_STATUS"]
    print("|cff88ccffHekiLight:|r " .. L["EDIT_MODE_ON"])
    print("  " .. L["Drag the main row or the proc slot to reposition them."])
    print("  " .. L["Proc slot: "] .. lockStatus .. "  (/hkl procalert lock|unlock)")
    print("  " .. L["/hkl edit to exit and save."])
end

local function ExitEditMode()
    editMode = false
    -- Restore normal drag/mouse state
    display:EnableMouse(not db.locked)
    if procAlertFrame then
        procAlertFrame:EnableMouse(not db.locked and not db.procAlertLocked)
    end
    -- Hide all edit UI elements
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if s and s.editLabel then s.editLabel:Hide() end
    end
    if procAlertFrame then
        if procAlertFrame.editLabel then procAlertFrame.editLabel:Hide() end
        if procAlertFrame.lockLabel then procAlertFrame.lockLabel:Hide() end
    end
    if display.editBanner then display.editBanner:Hide() end
    -- Resume normal rendering; restart poll loop if we were in combat
    Refresh()
    if inCombat then StartPollLoop() end
    print("|cff88ccffHekiLight:|r " .. L["EDIT_MODE_OFF"])
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
        if keybindRefreshTimer then keybindRefreshTimer:Cancel(); keybindRefreshTimer = nil end
        RebuildSlotBindings()  -- ensure SLOT_BINDINGS is current before first poll
        wipe(keybindCache); wipe(lastKeybindLog)  -- clear stale cache; fresh fight, fresh lookup
        -- Poll only when rotation assistance is active (Rotation Assistant button or Assisted Highlight).
        -- ACTIONBAR_SLOT_CHANGED will start the loop if the feature is enabled mid-combat.
        if IsAssistActive() then StartPollLoop() end
        Log("Entered combat")

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        lastRawSuggID = nil
        StopPollLoop()
        wipe(recentlyCastSpells)
        Refresh()
        Log("Left combat")

    elseif event == "ACTIONBAR_UPDATE_STATE" then
        -- State changes (button highlights) don't affect slot assignments; just re-render.
        Refresh()

    elseif event == "ACTIONBAR_SLOT_CHANGED" or
           event == "UPDATE_BINDINGS" then
        -- Slot content or keybinding actually changed — rebuild the map then re-render.
        RebuildSlotBindings()
        wipe(lastKeybindLog)  -- reset DLog change-detect; keep keybindCache as transient-miss fallback
        Refresh()
        -- If assist feature was just enabled mid-combat, start polling now.
        if inCombat and IsAssistActive() then StartPollLoop() end
        -- Out of combat, FindSpellActionButtons has a transient nil window immediately
        -- after a slot change (e.g., shapeshifting out of Travel Form). The Refresh()
        -- above likely misses it. Schedule a deferred repopulation after the window closes.
        if not inCombat then
            if keybindRefreshTimer then keybindRefreshTimer:Cancel() end
            keybindRefreshTimer = C_Timer.NewTimer(0.3, function()
                keybindRefreshTimer = nil
                if not inCombat then Refresh() end
            end)
        end

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        -- Track all active proc overlays; update proc-alert icon and border pulse
        activeOverlaySpells[arg1] = true
        local si_ev = C_Spell.GetSpellInfo(arg1)
        DLog("PROC_SHOW", string.format("spellID=%d (%s) isPrimary=%s",
            arg1, si_ev and si_ev.name or "?", tostring(arg1 == currentSuggestionID)))
        if arg1 == currentSuggestionID and db.showProcGlow then
            StartGlowPulse()
        end
        UpdateProcAlert(currentSuggestionID)

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        -- Proc overlay faded; remove from tracking and refresh proc-alert icon
        activeOverlaySpells[arg1] = nil
        local si_ev2 = C_Spell.GetSpellInfo(arg1)
        DLog("PROC_HIDE", string.format("spellID=%d (%s)", arg1, si_ev2 and si_ev2.name or "?"))
        if arg1 == currentSuggestionID then
            StopGlowPulse()
        end
        UpdateProcAlert(currentSuggestionID)

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
        -- These fire every damage/heal tick — only re-render when visibility would change
        -- (dead state, vehicle state). Full Refresh on every tick is a perf hazard.
        if arg1 == "player" then
            local canShow = ShouldShow()
            if canShow ~= display:IsShown() then Refresh() end
        end

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
    dead      = { key = "hideWhenDead",      label = L["Always hide when dead"] },
    vehicle   = { key = "hideWhenVehicle",   label = L["Always hide in a vehicle"] },
    cinematic = { key = "hideWhenCinematic", label = L["Always hide during cinematics"] },
}

-- Data-driven condition maps for slash commands.
local function PrintHelp()
    print("|cff88ccffHekiLight|r commands:")
    print("  /hkl edit                  toggle Edit Mode (show placeholders, drag to reposition)")
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
    print("  /hkl procalert lock        lock proc slot to main display (moves together)")
    print("  /hkl procalert unlock      free proc slot — drag independently")
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

    if msg == "edit" then
        if editMode then ExitEditMode() else EnterEditMode() end

    elseif msg == "lock" then
        db.locked = true
        display:EnableMouse(false)
        print("|cff88ccffHekiLight:|r " .. L["Display locked."])

    elseif msg == "unlock" then
        db.locked = false
        display:EnableMouse(true)
        print("|cff88ccffHekiLight:|r " .. L["Display unlocked — drag to reposition."])

    elseif msg == "reset" then
        wipe(db)
        for k, v in pairs(DEFAULTS) do db[k] = v end
        ApplyPosition()
        display:SetScale(db.scale)
        ApplySlotLayout()
        ApplyKeybindStyle()
        Refresh()
        print("|cff88ccffHekiLight:|r " .. L["All settings reset to defaults."])

    elseif msg:find("^scale%s") then
        local v = tonumber(msg:match("^scale%s+(.+)$"))
        if v and v >= 0.2 and v <= 3.0 then
            db.scale = v
            display:SetScale(v)
            print("|cff88ccffHekiLight:|r " .. string.format(L["SCALE_FMT"], v))
        else
            print("|cff88ccffHekiLight:|r " .. L["Scale must be between 0.2 and 3.0."])
        end

    elseif msg:find("^size%s") then
        local v = tonumber(msg:match("^size%s+(.+)$"))
        if v and v >= 16 and v <= 256 then
            db.iconSize = v
            ApplySlotLayout()
            Refresh()
            print("|cff88ccffHekiLight:|r " .. string.format(L["ICON_SIZE_FMT"], v))
        else
            print("|cff88ccffHekiLight:|r " .. L["Size must be between 16 and 256."])
        end

    elseif msg:find("^suggestions%s") then
        local v = tonumber(msg:match("^suggestions%s+(.+)$"))
        if v and v >= 1 and v <= 5 then
            db.numSuggestions = math.floor(v)
            ApplySlotLayout()
            Refresh()
            print("|cff88ccffHekiLight:|r " .. string.format(L["SUGGESTIONS_FMT"], db.numSuggestions))
        else
            print("|cff88ccffHekiLight:|r " .. L["Suggestions must be between 1 and 5."])
        end

    elseif msg:find("^spacing%s") then
        local v = tonumber(msg:match("^spacing%s+(.+)$"))
        if v and v >= 0 and v <= 32 then
            db.iconSpacing = math.floor(v)
            ApplySlotLayout()
            Refresh()
            print("|cff88ccffHekiLight:|r " .. string.format(L["SPACING_FMT"], db.iconSpacing))
        else
            print("|cff88ccffHekiLight:|r " .. L["Spacing must be between 0 and 32."])
        end

    elseif msg:find("^poll%s") then
        local v = tonumber(msg:match("^poll%s+(.+)$"))
        if v and v >= 0.016 and v <= 1.0 then
            db.pollRate = v
            print("|cff88ccffHekiLight:|r " .. string.format(L["POLL_FMT"], v))
        else
            print("|cff88ccffHekiLight:|r " .. L["Poll rate must be between 0.016 and 1.0."])
        end

    elseif msg == "keybind on" then
        db.showKeybind = true
        Refresh()
        print("|cff88ccffHekiLight:|r " .. L["Keybind text enabled."])

    elseif msg == "keybind off" then
        db.showKeybind = false
        if slots[1] and slots[1].keybindText then slots[1].keybindText:Hide() end
        print("|cff88ccffHekiLight:|r " .. L["Keybind text disabled."])

    elseif msg == "range on" then
        db.showOutOfRange = true
        Refresh()
        print("|cff88ccffHekiLight:|r " .. L["Out-of-range tint enabled."])

    elseif msg == "range off" then
        db.showOutOfRange = false
        if slots[1] and slots[1].rangeOverlay then slots[1].rangeOverlay:Hide() end
        print("|cff88ccffHekiLight:|r " .. L["Out-of-range tint disabled."])

    elseif msg == "procglow on" then
        db.showProcGlow = true
        Refresh()
        print("|cff88ccffHekiLight:|r " .. L["Proc glow border enabled."])

    elseif msg == "procglow off" then
        db.showProcGlow = false
        StopGlowPulse()
        print("|cff88ccffHekiLight:|r " .. L["Proc glow border disabled."])

    elseif msg == "sounds on" then
        db.sounds = true
        print("|cff88ccffHekiLight:|r " .. L["Sounds enabled."])

    elseif msg == "sounds off" then
        db.sounds = false
        print("|cff88ccffHekiLight:|r " .. L["Sounds disabled."])

    elseif msg:find("^kbsize%s") then
        local v = tonumber(msg:match("^kbsize%s+(.+)$"))
        if v and v >= 8 and v <= 24 then
            db.keybindFontSize = v
            ApplyKeybindStyle(); Refresh()
            print("|cff88ccffHekiLight:|r " .. string.format(L["KBSIZE_FMT"], v))
        else
            print("|cff88ccffHekiLight:|r " .. L["kbsize must be between 8 and 24."])
        end

    elseif msg:find("^kbcolor%s") then
        local r, g, b = msg:match("^kbcolor%s+([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            db.keybindColorR = math.max(0, math.min(1, r))
            db.keybindColorG = math.max(0, math.min(1, g))
            db.keybindColorB = math.max(0, math.min(1, b))
            ApplyKeybindStyle(); Refresh()
            print("|cff88ccffHekiLight:|r " .. L["Keybind color set."])
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl kbcolor <r> <g> <b>  (values 0–1, e.g. 1 0.82 0 for yellow)"])
        end

    elseif msg:find("^kboutline%s") then
        local arg = strtrim(msg:match("^kboutline%s+(.+)$") or "")
        local val = KB_OUTLINES[arg]
        if val ~= nil then
            db.keybindOutline = val
            ApplyKeybindStyle()
            print("|cff88ccffHekiLight:|r " .. string.format(L["KBOUTLINE_FMT"], (arg == "none" and "none" or arg)))
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl kboutline outline|thick|none"])
        end

    elseif msg:find("^kbanchor%s") then
        local arg = strtrim(msg:match("^kbanchor%s+(.+)$") or "")
        local val = KB_ANCHORS[arg]
        if val then
            db.keybindAnchor = val
            ApplyKeybindAnchor()
            print("|cff88ccffHekiLight:|r " .. string.format(L["KBANCHOR_FMT"], val))
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl kbanchor bottomright|bottomleft|topright|topleft|center"])
        end

    elseif msg:find("^show%s") then
        local arg = strtrim(msg:match("^show%s+(.+)$") or "")
        if SHOW_MODES[arg] then
            db.showMode = arg
            Refresh()
            print("|cff88ccffHekiLight:|r " .. string.format(L["SHOWMODE_FMT"], arg))
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl show always|active"])
        end

    elseif msg:find("^hide%s") then
        local flag, toggle = msg:match("^hide%s+(%a+)%s+(on|off)$")
        local entry = flag and ALWAYS_HIDE_FLAGS[flag]
        if entry and toggle then
            db[entry.key] = (toggle == "on")
            Refresh()
            print("|cff88ccffHekiLight:|r " .. entry.label .. " → " .. toggle)
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl hide dead|vehicle|cinematic on|off"])
        end

    elseif msg == "minimap on" then
        SetMinimapShown(true)
        print("|cff88ccffHekiLight:|r " .. L["Minimap button shown."])

    elseif msg == "minimap off" then
        SetMinimapShown(false)
        print("|cff88ccffHekiLight:|r " .. L["Minimap button hidden."])

    elseif msg == "procalert lock" then
        db.procAlertLocked = true
        ApplyProcAlertLayout()
        if editMode then EditModeRender() end  -- update lock indicator immediately
        print("|cff88ccffHekiLight:|r " .. L["Proc slot locked to main display."])

    elseif msg == "procalert unlock" then
        -- Snapshot the current on-screen position BEFORE releasing the anchor so
        -- the frame stays exactly where it is visually — no jump to any default.
        if procAlertFrame then
            local sx, sy = procAlertFrame:GetCenter()
            local ux, uy = UIParent:GetCenter()
            db.procAlertX = math.floor((sx - ux) + 0.5)
            db.procAlertY = math.floor((sy - uy) + 0.5)
        end
        db.procAlertLocked = false
        ApplyProcAlertLayout()
        if editMode then EditModeRender() end  -- update lock indicator immediately
        print("|cff88ccffHekiLight:|r " .. L["Proc slot is free — drag it independently."])

    elseif msg:find("^ignore%s") then
        local arg = strtrim(msg:match("^ignore%s+(.+)$") or "")
        local sid = tonumber(arg)
        if sid then
            dbChar.ignoredSpells[sid] = true
            local si = C_Spell.GetSpellInfo(sid)
            local name = si and si.name or tostring(sid)
            print("|cff88ccffHekiLight:|r " .. name .. " [" .. sid .. "]" .. L[" will no longer appear in the secondary list."])
            Refresh()
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl ignore <spellID>"])
        end

    elseif msg:find("^unignore%s") then
        local arg = strtrim(msg:match("^unignore%s+(.+)$") or "")
        local sid = tonumber(arg)
        if sid then
            dbChar.ignoredSpells[sid] = nil
            local si = C_Spell.GetSpellInfo(sid)
            local name = si and si.name or tostring(sid)
            print("|cff88ccffHekiLight:|r " .. name .. " [" .. sid .. "]" .. L[" restored to the secondary list."])
            Refresh()
        else
            print("|cff88ccffHekiLight:|r " .. L["Usage: /hkl unignore <spellID>"])
        end

    elseif msg == "ignorelist" then
        local sorted = {}
        for sid in pairs(dbChar.ignoredSpells) do sorted[#sorted + 1] = sid end
        table.sort(sorted)
        if #sorted == 0 then
            print("|cff88ccffHekiLight:|r " .. L["No spells are hidden from the secondary list."])
        else
            print("|cff88ccffHekiLight:|r " .. L["Spells hidden from the secondary list:"])
            for _, sid in ipairs(sorted) do
                local si = C_Spell.GetSpellInfo(sid)
                local name = si and si.name or "(unknown)"
                print("  " .. name .. " [" .. sid .. "]  — /hkl unignore " .. sid .. " " .. L["to restore"])
            end
        end

    elseif msg == "debug" then
        DEBUG = not DEBUG
        print("|cff88ccffHekiLight:|r " .. (DEBUG and L["DEBUG_ON_FMT"] or L["DEBUG_OFF_FMT"]))

    elseif msg == "log" or msg:find("^log%s") then
        local n = tonumber(msg:match("^log%s+(%d+)$")) or 30
        -- Prefer current session; fall back to last session if current is empty
        local src = (#sessionLog > 0) and sessionLog or (HekiLightDB.lastSessionLog or {})
        local label = (#sessionLog > 0) and L["current session"] or L["previous session (current is empty)"]
        local total = #src
        n = math.min(n, total)
        if n == 0 then
            print("|cff88ccffHekiLight:|r " .. L["No log data. Play a fight then /reload, or use /hkl log after combat."])
        else
            print("|cff88ccffHekiLight:|r " .. string.format(L["HINT_LOG_FMT"], n, total, label))
            local start = total - n + 1
            for i = start, total do
                print("  " .. src[i])
            end
        end

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
