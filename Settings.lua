-- Settings.lua — BuildSettingsPanel extracted from HekiLight.lua (EPIC-11 Story 11.2)

function BuildSettingsPanel()
    local db                   = HekiLightST.db
    local dbChar               = HekiLightST.dbChar
    local display              = HekiLightST.display
    local slots                = HekiLightST.slots
    local procAlertFrame       = HekiLightST.procAlertFrame
    local cachedRotSpells      = HekiLightST.cachedRotSpells
    local L                    = HekiLightST.L
    local Refresh              = HekiLightST.Refresh
    local ApplySlotLayout      = HekiLightST.ApplySlotLayout
    local ApplyKeybindStyle    = HekiLightST.ApplyKeybindStyle
    local ApplyKeybindAnchor   = HekiLightST.ApplyKeybindAnchor
    local ApplyProcAlertLayout = HekiLightST.ApplyProcAlertLayout
    local ApplyPosition        = HekiLightST.ApplyPosition
    local DEFAULTS             = HekiLightST.DEFAULTS
    local MAX_SLOTS            = HekiLightST.MAX_SLOTS
    local isEditMode           = HekiLightST.isEditMode
    local EditModeRender       = HekiLightST.EditModeRender
    local GetSlotKeybind       = HekiLightST.GetSlotKeybind
    local SetMinimapShown      = HekiLightST.SetMinimapShown
    local StopGlowPulse        = HekiLightST.StopGlowPulse

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
            if isEditMode() then EditModeRender() end  -- update lock indicator in edit mode
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

    local ignoreListBaseY = -72  -- below the dropdown row

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

    local ignoreEmptyLabel = ignoreBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ignoreEmptyLabel:SetPoint("TOPLEFT", 10, ignoreListBaseY)
    ignoreEmptyLabel:SetText(L["No spells are currently ignored."])

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

    -- ── Keybind Overrides section ─────────────────────────────────────────────
    local kbSec, kbBody = MakeSection(L["Keybind Overrides"], false)

    local kbDesc = kbBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    kbDesc:SetPoint("TOPLEFT", 10, -10)
    kbDesc:SetWidth(570)
    kbDesc:SetJustifyH("LEFT")
    kbDesc:SetText(L["Pin the bar slot HekiLight reads for a spell's keybind."])

    local selectedKbSpellID = nil
    local selectedKbSlotID  = nil
    local kbRowPool = {}
    local RefreshKbOverrideList  -- forward declaration

    -- UIDropDownMenu has ~18 px inherent left padding; offset by -2 to align
    local kbSpellDD = CreateFrame("Frame", "HekiLightKbSpellDropdown", kbBody, "UIDropDownMenuTemplate")
    kbSpellDD:SetPoint("TOPLEFT", -2, -26)
    UIDropDownMenu_SetWidth(kbSpellDD, 240)
    UIDropDownMenu_SetText(kbSpellDD, L["Select a rotation spell..."])

    local kbSlotDD = CreateFrame("Frame", "HekiLightKbSlotDropdown", kbBody, "UIDropDownMenuTemplate")
    kbSlotDD:SetPoint("TOPLEFT", -2, -56)
    UIDropDownMenu_SetWidth(kbSlotDD, 240)
    UIDropDownMenu_SetText(kbSlotDD, L["Select a bar slot..."])
    kbSlotDD:Hide()

    local kbPinBtn = CreateFrame("Button", nil, kbBody, "UIPanelButtonTemplate")
    kbPinBtn:SetPoint("LEFT", kbSlotDD, "RIGHT", -4, 2)
    kbPinBtn:SetSize(130, 22)
    kbPinBtn:SetText(L["Pin keybind"])
    kbPinBtn:Hide()

    local kbHintLabel = kbBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    kbHintLabel:SetPoint("TOPLEFT", 8, -60)
    kbHintLabel:SetText(L["Spell not on any action bar — keybind cannot be pinned."])
    kbHintLabel:Hide()

    local kbListBaseY = -90
    local kbEmptyLabel = kbBody:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    kbEmptyLabel:SetPoint("TOPLEFT", 10, kbListBaseY)
    kbEmptyLabel:SetText(L["No keybind overrides set."])

    UIDropDownMenu_Initialize(kbSlotDD, function(self, level)
        if not selectedKbSpellID then return end
        local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, selectedKbSpellID)
        if ok and slots then
            for _, slot in ipairs(slots) do
                if not C_ActionBar.IsAssistedCombatAction(slot) then
                    local info = UIDropDownMenu_CreateInfo()
                    local key  = GetSlotKeybind(slot)
                    local capturedSlot = slot
                    local label = "Slot " .. slot .. " -> " .. (key ~= "" and key or "(unbound)")
                        .. (dbChar.keybindOverrides[selectedKbSpellID] == slot and " [pinned]" or "")
                    info.text  = label
                    info.func  = function()
                        selectedKbSlotID = capturedSlot
                        UIDropDownMenu_SetText(kbSlotDD, label)
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end
    end)

    UIDropDownMenu_Initialize(kbSpellDD, function(self, level)
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
                            .. (entry.ignored and " (ignored)|r" or "")
            info.icon     = entry.iconID
            info.disabled = entry.ignored
            if not entry.ignored then
                local capturedSid  = entry.sid
                local capturedName = entry.name
                info.func = function()
                    selectedKbSpellID = capturedSid
                    selectedKbSlotID  = nil
                    UIDropDownMenu_SetText(kbSpellDD, capturedName .. " [" .. capturedSid .. "]")
                    local ok2, slots2 = pcall(C_ActionBar.FindSpellActionButtons, capturedSid)
                    local nonRACount  = 0
                    if ok2 and slots2 then
                        for _, s in ipairs(slots2) do
                            if not C_ActionBar.IsAssistedCombatAction(s) then
                                nonRACount = nonRACount + 1
                            end
                        end
                    end
                    if nonRACount >= 1 then
                        UIDropDownMenu_SetText(kbSlotDD, L["Select a bar slot..."])
                        kbSlotDD:Show()
                        kbPinBtn:Show()
                        kbHintLabel:Hide()
                    else
                        kbSlotDD:Hide()
                        kbPinBtn:Hide()
                        kbHintLabel:Show()
                    end
                    RefreshKbOverrideList()
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    kbPinBtn:SetScript("OnClick", function()
        if not selectedKbSpellID or not selectedKbSlotID then
            print("|cff88ccffHekiLight:|r " .. L["Select a spell and a slot first."])
            return
        end
        dbChar.keybindOverrides[selectedKbSpellID] = selectedKbSlotID
        local si  = C_Spell.GetSpellInfo(selectedKbSpellID)
        local name = si and si.name or tostring(selectedKbSpellID)
        local key  = GetSlotKeybind(selectedKbSlotID)
        print("|cff88ccffHekiLight:|r Keybind pinned: " .. name .. " [" .. selectedKbSpellID .. "] -> Slot " .. selectedKbSlotID .. " (" .. (key ~= "" and key or "unbound") .. ")")
        selectedKbSpellID = nil
        selectedKbSlotID  = nil
        UIDropDownMenu_SetText(kbSpellDD, L["Select a rotation spell..."])
        kbSlotDD:Hide()
        kbPinBtn:Hide()
        kbHintLabel:Hide()
        RefreshKbOverrideList()
    end)

    RefreshKbOverrideList = function()
        for _, row in ipairs(kbRowPool) do row:Hide() end
        local slotPickerShift = (kbSlotDD and kbSlotDD:IsShown()) and 30 or 0
        local sorted = {}
        for sid in pairs(dbChar.keybindOverrides) do sorted[#sorted + 1] = sid end
        table.sort(sorted)
        local rowIdx = 0
        for _, sid in ipairs(sorted) do
            rowIdx = rowIdx + 1
            local row = kbRowPool[rowIdx]
            if not row then
                row = CreateFrame("Frame", nil, kbBody)
                row:SetSize(570, 24)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(20, 20)
                row.icon:SetPoint("LEFT", 4, 0)
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.label:SetWidth(440)
                row.label:SetJustifyH("LEFT")
                row.clearBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.clearBtn:SetSize(70, 20)
                row.clearBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                row.clearBtn:SetText(L["Clear"])
                kbRowPool[rowIdx] = row
            end
            local capturedSid = sid
            local slotID = dbChar.keybindOverrides[sid]
            local si     = C_Spell.GetSpellInfo(sid)
            local key    = GetSlotKeybind(slotID)
            row.icon:SetTexture(si and si.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.label:SetText(
                (si and si.name or "(unknown)") ..
                "  |cff888888[" .. sid .. "]|r" ..
                "  Slot " .. slotID ..
                " -> " .. (key ~= "" and key or "(unbound)")
            )
            row.clearBtn:SetScript("OnClick", function()
                dbChar.keybindOverrides[capturedSid] = nil
                if selectedKbSpellID == capturedSid then
                    selectedKbSpellID = nil
                    selectedKbSlotID  = nil
                    UIDropDownMenu_SetText(kbSpellDD, L["Select a rotation spell..."])
                    kbSlotDD:Hide()
                    kbPinBtn:Hide()
                    kbHintLabel:Hide()
                end
                RefreshKbOverrideList()
            end)
            row:SetPoint("TOPLEFT", 10, kbListBaseY - (rowIdx - 1) * 30)
            row:Show()
        end
        kbEmptyLabel:ClearAllPoints()
        kbEmptyLabel:SetPoint("TOPLEFT", 10, kbListBaseY)
        kbEmptyLabel:SetShown(rowIdx == 0)
        local overrideCount = 0
        for _ in pairs(dbChar.keybindOverrides) do overrideCount = overrideCount + 1 end
        kbBody:SetHeight(90 + slotPickerShift + math.max(overrideCount, 1) * 30)
        LayoutSections()
    end

    local origKbClick = kbSec.header:GetScript("OnClick")
    kbSec.header:SetScript("OnClick", function(self)
        origKbClick(self)
        if kbSec.isExpanded then
            RefreshKbOverrideList()
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

    local cat = Settings.RegisterCanvasLayoutCategory(panel, "HekiLight")
    HekiLightST.setSettingsCategory(cat)
    Settings.RegisterAddOnCategory(cat)
end
