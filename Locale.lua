-- ── Locale ───────────────────────────────────────────────────────────────────
-- Exposes HekiLightLocale; accessed in HekiLight.lua as: local L = HekiLightLocale
-- Add new locale blocks following the ptBR pattern.

local L = {}
HekiLightLocale = L

-- Non-identity defaults: format strings and keys whose value differs from the key.
L["HINT_SPELL_SINGULAR"]  = "1 spell available — click to select"
L["HINT_SPELL_PLURAL"]    = "%d spells available — click to select"
L["HINT_LOG_FMT"]         = "Last %d of %d events (%s):"
L["SCALE_FMT"]            = "Scale → %s"
L["ICON_SIZE_FMT"]        = "Icon size → %spx"
L["SUGGESTIONS_FMT"]      = "Suggestions → %d"
L["SPACING_FMT"]          = "Icon spacing → %spx"
L["POLL_FMT"]             = "Poll rate → %ss"
L["KBSIZE_FMT"]           = "Keybind font size → %d"
L["KBOUTLINE_FMT"]        = "Keybind outline → %s"
L["KBANCHOR_FMT"]         = "Keybind anchor → %s"
L["SHOWMODE_FMT"]         = "Show mode → %s"
L["PROC_LOCKED_STATUS"]   = "|cff88ccffLOCKED|r — moves with main row"
L["PROC_FREE_STATUS"]     = "|cffff9900FREE|r — drag independently"
L["PROC_LOCK_LABEL"]      = "|cff88ccff[locked]|r"
L["PROC_FREE_LABEL"]      = "|cffff9900[free]|r"
L["EDIT_BANNER"]          = "|cffffcc00✦ Edit Mode|r  ·  drag to reposition  ·  /hkl edit to exit"
L["EDIT_MODE_ON"]         = "|cffffcc00✦ Edit Mode|r ON"
L["EDIT_MODE_OFF"]        = "|cffffcc00✦ Edit Mode|r OFF — positions saved."
L["DEBUG_ON_FMT"]         = "Debug output ON."
L["DEBUG_OFF_FMT"]        = "Debug output OFF."

-- ── ptBR ─────────────────────────────────────────────────────────────────────

if GetLocale() == "ptBR" then

    -- Settings panel: section headers
    L["Rotation assistant icon overlay"] = "Sobreposição do Assistente de Rotação"
    L["Appearance"]     = "Aparência"
    L["Display"]        = "Exibição"
    L["Keybind Style"]  = "Estilo de Atalho"
    L["Visibility"]     = "Visibilidade"
    L["Ignored Spells"] = "Magias Ignoradas"

    -- Appearance: sliders
    L["Overall Scale"] = "Escala Geral"
    L["Scales the entire HekiLight overlay — icons, spacing, and keybind text."]
        = "Ajusta a escala de toda a sobreposição do HekiLight — ícones, espaçamento e texto de atalho."
    L["Icon Size"] = "Tamanho do Ícone"
    L["Sets the raw pixel size of the spell icon texture."]
        = "Define o tamanho em pixels do ícone da magia."
    L["Spell Icon Slots"] = "Slots de Ícone"
    L["Number of spell icons to display (1 = primary only, up to 5)."]
        = "Número de ícones de magia a exibir (1 = somente primário, até 5)."
    L["Icon Spacing"] = "Espaçamento de Ícone"
    L["Refresh Rate (s)"] = "Taxa de Atualização (s)"
    L["How often (seconds) the suggestion bar refreshes."]
        = "Frequência (segundos) de atualização da barra de sugestão."

    -- Appearance: lock checkbox
    L["Lock position"] = "Travar posição"
    L["Prevent the icon from being accidentally dragged. Use /hkl unlock to reposition it."]
        = "Impede que o ícone seja movido acidentalmente. Use /hkl unlock para reposicioná-lo."
    L["Position locked."] = "Posição travada."
    L["Position unlocked — drag to reposition."] = "Posição destravada — arraste para reposicionar."

    -- Display: checkboxes
    L["Show keybind text"] = "Exibir texto de atalho"
    L["Show the keybind for the suggested spell in the corner of the icon."]
        = "Exibe o atalho da magia sugerida no canto do ícone."
    L["Show out-of-range tint"] = "Exibir tinta fora de alcance"
    L["Pulse the icon red when the suggested spell cannot reach your target."]
        = "Pulsa o ícone em vermelho quando a magia sugerida não alcança o alvo."
    L["Spell Proc Glow"] = "Brilho de Proc"
    L["Pulse the icon border gold when the suggested spell has an active proc glow."]
        = "Pulsa a borda do ícone em dourado quando a magia sugerida tem um proc ativo."
    L["Show proc-alert icon"] = "Exibir ícone de alerta de proc"
    L["Show an extra icon to the left when a proc spell is active but not the main suggestion."]
        = "Exibe um ícone extra à esquerda quando uma magia com proc está ativa mas não é a sugestão principal."
    L["Lock proc-alert to main display"] = "Travar proc ao painel principal"
    L["When checked, the proc icon moves with the main suggestion row. Uncheck to drag it independently."]
        = "Quando marcado, o ícone de proc se move com a fila principal. Desmarque para arrastá-lo independentemente."
    L["Show cooldown spiral"] = "Exibir espiral de recarga"
    L["Display a cooldown sweep on the icon."] = "Exibe o tempo de recarga no ícone."
    L["Play sounds"] = "Reproduzir sons"
    L["Play a subtle click when the icon appears as you enter combat."]
        = "Toca um clique sutil quando o ícone aparece ao entrar em combate."
    L["Show minimap button"] = "Exibir botão do minimapa"
    L["Show the HekiLight button on the minimap. Drag it to reposition."]
        = "Exibe o botão do HekiLight no minimapa. Arraste para reposicioná-lo."

    -- Keybind Style
    L["Font Size"]    = "Tamanho da Fonte"
    L["Color"]        = "Cor"
    L["Keybind Color"] = "Cor do Atalho"
    L["Click to open the color picker."] = "Clique para abrir o seletor de cor."
    L["Outline Style"] = "Estilo de Contorno"
    L["Outline"]      = "Contorno"
    L["Thin border around each character."] = "Borda fina ao redor de cada caractere."
    L["Thick Outline"] = "Contorno Grosso"
    L["Bold border — readable at small sizes."] = "Borda grossa — legível em tamanhos pequenos."
    L["None"]         = "Nenhum"
    L["No outline — flat text."] = "Sem contorno — texto simples."
    L["Corner Position"] = "Posição do Canto"
    L["Bottom Right"] = "Inferior Direito"
    L["Bottom Left"]  = "Inferior Esquerdo"
    L["Top Right"]    = "Superior Direito"
    L["Top Left"]     = "Superior Esquerdo"
    L["Center"]       = "Centro"

    -- Visibility
    L["Show Overlay"] = "Exibir Sobreposição"
    L["Always"]       = "Sempre"
    L["Show the overlay whenever Rotation Assistant has a suggestion."]
        = "Exibe a sobreposição sempre que o Assistente de Rotação tiver uma sugestão."
    L["In Combat or Attackable Target"] = "Em Combate ou Alvo Atacável"
    L["Only show when in combat, or when you have an attackable target selected."]
        = "Exibe somente em combate ou com um alvo atacável selecionado."
    L["Always Hide When"] = "Sempre Ocultar Quando"
    L["Dead or Ghost"] = "Morto ou Fantasma"
    L["Hide the overlay while you are dead or a ghost."]
        = "Oculta a sobreposição enquanto você está morto ou fantasma."
    L["In a cinematic"] = "Em uma cinemática"
    L["Hide the overlay during in-game cinematics and movies."]
        = "Oculta a sobreposição durante cinemáticas e filmes do jogo."
    L["In a vehicle"] = "Em um veículo"
    L["Hide the overlay while riding a vehicle with its own action bar."]
        = "Oculta a sobreposição ao usar um veículo com sua própria barra de ação."

    -- Ignored Spells
    L["Spells hidden from the secondary suggestion list. Select a spell and click Add.\n|cffaaaaaa Requires Rotation Assistant to be active.|r"]
        = "Magias ocultas da lista secundária. Selecione uma magia e clique em Adicionar.\n|cffaaaaaa Requer o Assistente de Rotação ativo.|r"
    L["Select a rotation spell..."]    = "Selecione uma magia de rotação..."
    L["Add to ignore list"]            = "Adicionar à lista"
    L["Remove"]                        = "Remover"
    L["No rotation spells available"]  = "Nenhuma magia de rotação disponível"
    L["No spells are currently ignored."] = "Nenhuma magia está sendo ignorada no momento."
    L["Select a spell from the dropdown first."] = "Selecione uma magia no menu primeiro."
    L["That spell is already ignored."] = "Esta magia já está ignorada."
    L[" will no longer appear in the secondary list."] = " não aparecerá mais na lista secundária."
    L[" restored to the secondary list."] = " restaurado à lista secundária."
    -- Keybind override panel (Story 10.2)
    L["Select a bar slot..."]          = "Selecione um slot de barra..."
    L["Pin keybind"]                   = "Fixar atalho"
    L["Only one bar slot found — no override needed."] = "Apenas um slot encontrado — substituição desnecessária."
    L["Select a spell and a slot first."] = "Selecione uma magia e um slot primeiro."
    L["Keybind Overrides"]             = "Substituições de Atalho"
    L["No keybind overrides set."]     = "Nenhuma substituição de atalho definida."
    L["Clear"]                         = "Limpar"
    L["Reset to Defaults"]             = "Redefinir para Padrão"
    L["All settings reset to defaults."] = "Todas as configurações foram redefinidas."

    -- Minimap tooltip
    L["Click to open settings"] = "Clique para abrir as configurações"
    L["Drag to reposition"]     = "Arraste para reposicionar"

    -- Edit mode (non-identity keys)
    L["EDIT_BANNER"]  = "|cffffcc00✦ Modo de Edição|r  ·  arraste para reposicionar  ·  /hkl edit para sair"
    L["EDIT_MODE_ON"] = "|cffffcc00✦ Modo de Edição|r ATIVADO"
    L["EDIT_MODE_OFF"] = "|cffffcc00✦ Modo de Edição|r DESATIVADO — posições salvas."
    L["Drag the main row or the proc slot to reposition them."]
        = "Arraste a fila principal ou o slot de proc para reposicioná-los."
    L["Proc slot: "]          = "Slot de proc: "
    L["/hkl edit to exit and save."] = "/hkl edit para sair e salvar."
    L["PROC_LOCKED_STATUS"]   = "|cff88ccffTRAVADO|r — se move com a fila principal"
    L["PROC_FREE_STATUS"]     = "|cffff9900LIVRE|r — arraste independentemente"
    L["PROC_LOCK_LABEL"]      = "|cff88ccff[travado]|r"
    L["PROC_FREE_LABEL"]      = "|cffff9900[livre]|r"

    -- ALWAYS_HIDE_FLAGS labels
    L["Always hide when dead"]          = "Sempre ocultar quando morto"
    L["Always hide in a vehicle"]       = "Sempre ocultar em um veículo"
    L["Always hide during cinematics"]  = "Sempre ocultar durante cinemáticas"

    -- Slash command feedback
    L["Display locked."]                = "Exibição travada."
    L["Display unlocked — drag to reposition."] = "Exibição destravada — arraste para reposicionar."
    L["Scale must be between 0.2 and 3.0."] = "A escala deve estar entre 0,2 e 3,0."
    L["Size must be between 16 and 256."]   = "O tamanho deve estar entre 16 e 256."
    L["Suggestions must be between 1 and 5."] = "As sugestões devem estar entre 1 e 5."
    L["Spacing must be between 0 and 32."]  = "O espaçamento deve estar entre 0 e 32."
    L["Poll rate must be between 0.016 and 1.0."] = "A taxa de atualização deve estar entre 0,016 e 1,0."
    L["Keybind text enabled."]          = "Texto de atalho ativado."
    L["Keybind text disabled."]         = "Texto de atalho desativado."
    L["Out-of-range tint enabled."]     = "Tinta fora de alcance ativada."
    L["Out-of-range tint disabled."]    = "Tinta fora de alcance desativada."
    L["Proc glow border enabled."]      = "Borda de proc ativada."
    L["Proc glow border disabled."]     = "Borda de proc desativada."
    L["Sounds enabled."]                = "Sons ativados."
    L["Sounds disabled."]              = "Sons desativados."
    L["kbsize must be between 8 and 24."] = "kbsize deve estar entre 8 e 24."
    L["Keybind color set."]             = "Cor do atalho definida."
    L["Usage: /hkl kbcolor <r> <g> <b>  (values 0–1, e.g. 1 0.82 0 for yellow)"]
        = "Uso: /hkl kbcolor <r> <g> <b>  (valores 0–1, ex: 1 0.82 0 = amarelo)"
    L["Usage: /hkl kboutline outline|thick|none"] = "Uso: /hkl kboutline outline|thick|none"
    L["Usage: /hkl kbanchor bottomright|bottomleft|topright|topleft|center"]
        = "Uso: /hkl kbanchor bottomright|bottomleft|topright|topleft|center"
    L["Usage: /hkl show always|active"] = "Uso: /hkl show always|active"
    L["Usage: /hkl hide dead|vehicle|cinematic on|off"]
        = "Uso: /hkl hide dead|vehicle|cinematic on|off"
    L["Minimap button shown."]          = "Botão do minimapa exibido."
    L["Minimap button hidden."]         = "Botão do minimapa oculto."
    L["Proc slot locked to main display."] = "Slot de proc travado ao painel principal."
    L["Proc slot is free — drag it independently."] = "Slot de proc livre — arraste independentemente."
    L["Usage: /hkl ignore <spellID>"]  = "Uso: /hkl ignore <spellID>"
    L["Usage: /hkl unignore <spellID>"] = "Uso: /hkl unignore <spellID>"
    L["No spells are hidden from the secondary list."]
        = "Nenhuma magia está oculta da lista secundária."
    L["Spells hidden from the secondary list:"] = "Magias ocultas da lista secundária:"
    L["to restore"]                     = "para restaurar"
    L["DEBUG_ON_FMT"]                   = "Saída de depuração ATIVADA."
    L["DEBUG_OFF_FMT"]                  = "Saída de depuração DESATIVADA."
    L["No log data. Play a fight then /reload, or use /hkl log after combat."]
        = "Sem dados de log. Jogue uma batalha e faça /reload, ou use /hkl log após o combate."
    L["current session"]                = "sessão atual"
    L["previous session (current is empty)"] = "sessão anterior (atual vazia)"
    L["HINT_LOG_FMT"]                   = "Últimos %d de %d eventos (%s):"
    L["HINT_SPELL_SINGULAR"]            = "1 magia disponível — clique para selecionar"
    L["HINT_SPELL_PLURAL"]              = "%d magias disponíveis — clique para selecionar"
    L["SCALE_FMT"]                      = "Escala → %s"
    L["ICON_SIZE_FMT"]                  = "Tamanho do ícone → %spx"
    L["SUGGESTIONS_FMT"]                = "Sugestões → %d"
    L["SPACING_FMT"]                    = "Espaçamento → %spx"
    L["POLL_FMT"]                       = "Taxa de atualização → %ss"
    L["KBSIZE_FMT"]                     = "Tamanho da fonte → %d"
    L["KBOUTLINE_FMT"]                  = "Contorno do atalho → %s"
    L["KBANCHOR_FMT"]                   = "Posição do atalho → %s"
    L["SHOWMODE_FMT"]                   = "Modo de exibição → %s"
end

-- Identity fallback: any key not explicitly set returns itself (English default).
setmetatable(L, { __index = function(_, k) return k end })
