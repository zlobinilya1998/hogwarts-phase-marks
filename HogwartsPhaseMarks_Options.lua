-- Окно настройки засечек (/hpm): список боссов слева, пороги выбранного босса справа.

local ADDON, ns = ...

local ROW_HEIGHT = 20
local MARK_ROW_HEIGHT = 26
local MAX_MARKS = 8

local window
local bossRows, markRows = {}, {}
local selected

local function button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    return b
end

-- Значение применяется при потере фокуса; Enter просто снимает фокус, Esc возвращает прежнее значение
local function editBox(parent, width, onCommit)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e:SetScript("OnEscapePressed", function(self) ns.updateOptions(); self:ClearFocus() end)
    if onCommit then e:SetScript("OnEditFocusLost", onCommit) end
    return e
end

local function label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text)
    return fs
end

local function changed()
    ns.refresh()
    ns.updateOptions()
end

-- Поле может потерять фокус уже после удаления порога или босса
local function currentMark(i)
    local entry = selected and ns.bossEntry(selected)
    return entry and entry[i]
end

local function sortMarks(entry)
    table.sort(entry, function(a, b) return a.hp > b.hp end)
end

local function bossRow(i)
    if bossRows[i] then return bossRows[i] end
    local b = CreateFrame("Button", nil, window.list)
    b:SetSize(180, ROW_HEIGHT)
    b:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.25)
    b.text = label(b, "", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 4, 0)
    b.text:SetPoint("RIGHT", -4, 0)
    b.text:SetJustifyH("LEFT")
    b:SetScript("OnClick", function(self) selected = self.id; ns.updateOptions() end)
    bossRows[i] = b
    return b
end

local function markRow(parent, i)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(320, MARK_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -52 - (i - 1) * MARK_ROW_HEIGHT)

    row.hp = editBox(row, 40, function(self)
        local v = tonumber((self:GetText():gsub(",", ".")))
        local m = currentMark(i)
        if not m then return end
        if v and v > 0 and v < 100 and math.abs(v / 100 - m.hp) > 1e-6 then
            local entry = ns.editable(selected)
            entry[i].hp = v / 100
            sortMarks(entry)
        end
        changed()
    end)
    row.hp:SetPoint("LEFT", 6, 0)

    local function flag(key, x)
        local c = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        c:SetSize(24, 24)
        c:SetPoint("LEFT", x, 0)
        c:SetScript("OnClick", function(self)
            ns.editable(selected)[i][key] = self:GetChecked() and true or nil
            changed()
        end)
        return c
    end
    row.heroic = flag("heroic", 62)
    row.event = flag("event", 116)

    row.note = editBox(row, 115, function(self)
        local m = currentMark(i)
        if not m then return end
        local text = strtrim(self:GetText())
        if text == "" then text = nil end
        if text ~= m.note then
            ns.editable(selected)[i].note = text
        end
        changed()
    end)
    row.note:SetPoint("LEFT", 170, 0)

    row.del = button(row, "X", 24)
    row.del:SetPoint("LEFT", 292, 0)
    row.del:SetScript("OnClick", function()
        table.remove(ns.editable(selected), i)
        changed()
    end)
    return row
end

-- scale — множитель для показа в окне (доли храним, проценты показываем)
local NUMBER_SETTINGS = {
    { key = "width", text = "Ширина засечки, px", min = 1, max = 10 },
    { key = "nextWidth", text = "Ширина следующей засечки, px", min = 1, max = 10 },
    { key = "outline", text = "Обводка, px (0 — без неё)", min = 0, max = 4 },
    { key = "overhang", text = "Выступ за полосу, px", min = 0, max = 20 },
    { key = "labelOffset", text = "Отступ подписи, px", min = -30, max = 30 },
    { key = "fontSize", text = "Размер шрифта", min = 6, max = 24 },
    { key = "passedAlpha", text = "Прозрачность пройденных, %", min = 0, max = 100, scale = 100 },
    { key = "warnRange", text = "Мигать за, % HP", min = 0, max = 100, scale = 100 },
}

local COLOR_SETTINGS = {
    { key = "phaseColor", text = "Цвет фазы" },
    { key = "eventColor", text = "Цвет события" },
    { key = "outlineColor", text = "Цвет обводки" },
}

-- Кнопки-переключатели: щелчок выбирает следующее значение по кругу
local CYCLE_SETTINGS = {
    { key = "labelPos", text = "Подпись", values = { "BOTTOM", "TOP", "INSIDE", "NONE" },
      names = { BOTTOM = "Под полосой", TOP = "Над полосой", INSIDE = "Внутри полосы", NONE = "Скрыта" } },
    { key = "labelsMode", text = "Подписывать", values = { "ALL", "NEXT" },
      names = { ALL = "Все пороги", NEXT = "Только следующий" } },
}

local KINDS = { "elvui", "blizzard", "nameplate" }
local KIND_NAMES = { elvui = "ElvUI", blizzard = "Blizzard", nameplate = "Неймплейты" }

local styleKind = "elvui"
local styleControls = {}

local function nextValue(values, current)
    for i, v in ipairs(values) do
        if v == current then return values[i % #values + 1] end
    end
    return values[1]
end

local function pickColor(key)
    local kind = styleKind
    local r, g, b = unpack(ns.style(key, kind))
    local function set(nr, ng, nb)
        ns.setStyle(kind, key, { nr, ng, nb })
        ns.updateOptions()
    end
    local info = {
        r = r, g = g, b = b, hasOpacity = false,
        swatchFunc = function() set(ColorPickerFrame:GetColorRGB()) end,
        cancelFunc = function() set(r, g, b) end,
    }
    -- Новый API палитры есть не во всех сборках клиента
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow(info)
    else
        ColorPickerFrame.func = info.swatchFunc
        ColorPickerFrame.cancelFunc = info.cancelFunc
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = { r, g, b }
        ColorPickerFrame:SetColorRGB(r, g, b)
        ShowUIPanel(ColorPickerFrame)
    end
end

local function createStylePage(f)
    local page = CreateFrame("Frame", nil, f)
    page:SetPoint("TOPLEFT", 0, -26)
    page:SetPoint("BOTTOMRIGHT")

    label(page, "Настройки для рамок"):SetPoint("TOPLEFT", 20, -44)
    local kindButton = button(page, "", 110)
    kindButton:SetPoint("TOPLEFT", 160, -38)
    kindButton:SetScript("OnClick", function()
        styleKind = nextValue(KINDS, styleKind)
        ns.updateOptions()
    end)
    styleControls.kind = kindButton

    local enabledButton = button(page, "", 110)
    enabledButton:SetPoint("LEFT", kindButton, "RIGHT", 8, 0)
    enabledButton:SetScript("OnClick", function()
        ns.setStyle(styleKind, "enabled", not ns.style("enabled", styleKind))
        ns.updateOptions()
    end)
    styleControls.enabled = enabledButton

    local top = -76
    for i, s in ipairs(NUMBER_SETTINGS) do
        local y = top - (i - 1) * 28
        label(page, s.text, "GameFontHighlightSmall"):SetPoint("TOPLEFT", 20, y - 4)
        local box = editBox(page, 50, function(self)
            local v = tonumber((self:GetText():gsub(",", ".")))
            if v then
                v = math.max(s.min, math.min(s.max, v)) / (s.scale or 1)
                if v ~= ns.style(s.key, styleKind) then ns.setStyle(styleKind, s.key, v) end
            end
            ns.updateOptions()
        end)
        box:SetPoint("TOPLEFT", 220, y)
        styleControls[s.key] = box
    end

    for i, s in ipairs(COLOR_SETTINGS) do
        local y = top - (i - 1) * 28
        label(page, s.text, "GameFontHighlightSmall"):SetPoint("TOPLEFT", 310, y - 4)
        local swatch = CreateFrame("Button", nil, page)
        swatch:SetSize(40, 18)
        swatch:SetPoint("TOPLEFT", 450, y)
        local border = swatch:CreateTexture(nil, "BACKGROUND")
        border:SetAllPoints()
        border:SetColorTexture(0.6, 0.6, 0.6)
        swatch.color = swatch:CreateTexture(nil, "ARTWORK")
        swatch.color:SetPoint("TOPLEFT", 1, -1)
        swatch.color:SetPoint("BOTTOMRIGHT", -1, 1)
        swatch:SetScript("OnClick", function() pickColor(s.key) end)
        styleControls[s.key] = swatch
    end

    for i, s in ipairs(CYCLE_SETTINGS) do
        local y = top - (#COLOR_SETTINGS + i - 1) * 28
        label(page, s.text, "GameFontHighlightSmall"):SetPoint("TOPLEFT", 310, y - 4)
        local b = button(page, "", 120)
        b:SetPoint("TOPLEFT", 400, y + 2)
        b:SetScript("OnClick", function()
            ns.setStyle(styleKind, s.key, nextValue(s.values, ns.style(s.key, styleKind)))
            ns.updateOptions()
        end)
        styleControls[s.key] = b
    end

    local reset = button(page, "Сбросить вид", 120)
    reset:SetPoint("BOTTOMRIGHT", -12, 12)
    reset:SetScript("OnClick", function() ns.resetStyle(styleKind); ns.updateOptions() end)
    return page
end

local function updateStylePage()
    styleControls.kind:SetText(KIND_NAMES[styleKind])
    styleControls.enabled:SetText(ns.style("enabled", styleKind) and "|cff40ff40Включены|r" or "|cffff4040Выключены|r")
    for _, s in ipairs(NUMBER_SETTINGS) do
        styleControls[s.key]:SetText(format("%g", ns.style(s.key, styleKind) * (s.scale or 1)))
    end
    for _, s in ipairs(COLOR_SETTINGS) do
        styleControls[s.key].color:SetColorTexture(unpack(ns.style(s.key, styleKind)))
    end
    for _, s in ipairs(CYCLE_SETTINGS) do
        styleControls[s.key]:SetText(s.names[ns.style(s.key, styleKind)])
    end
end

local function createWindow()
    local f = CreateFrame("Frame", "HogwartsPhaseMarksOptions", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(570, 430)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText("Hogwarts Phase Marks") end
    tinsert(UISpecialFrames, f:GetName())
    window = f

    local page = CreateFrame("Frame", nil, f)
    page:SetPoint("TOPLEFT", 0, -26)
    page:SetPoint("BOTTOMRIGHT")
    f.bossPage = page
    f.stylePage = createStylePage(f)

    local tabBoss = button(f, "Боссы", 90)
    tabBoss:SetPoint("TOPLEFT", 14, -28)
    local tabStyle = button(f, "Вид", 90)
    tabStyle:SetPoint("LEFT", tabBoss, "RIGHT", 4, 0)
    -- Текущая вкладка — неактивная кнопка
    local function showPage(stylePage)
        f.bossPage:SetShown(not stylePage)
        f.stylePage:SetShown(stylePage)
        tabBoss:SetEnabled(stylePage)
        tabStyle:SetEnabled(not stylePage)
    end
    tabBoss:SetScript("OnClick", function() showPage(false) end)
    tabStyle:SetScript("OnClick", function() showPage(true) end)
    showPage(false)

    -- Список боссов
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetSize(180, 310)
    f.list = CreateFrame("Frame", nil, scroll)
    f.list:SetSize(180, 1)
    scroll:SetScrollChild(f.list)

    local idBox = editBox(page, 60)
    idBox:SetNumeric(true)
    idBox:SetPoint("BOTTOMLEFT", 20, 14)
    local function addById()
        local id = tonumber(idBox:GetText())
        if not id then return end
        idBox:SetText("")
        idBox:ClearFocus()
        ns.addBoss(id)
        selected = id
        ns.updateOptions()
    end
    idBox:SetScript("OnEnterPressed", addById)
    local addId = button(page, "По ID", 60)
    addId:SetPoint("LEFT", idBox, "RIGHT", 4, 0)
    addId:SetScript("OnClick", addById)
    local addTarget = button(page, "Цель", 60)
    addTarget:SetPoint("LEFT", addId, "RIGHT", 2, 0)
    addTarget:SetScript("OnClick", function()
        local id = ns.npcId("target")
        if not id then
            print("|cffd9b45aHogwarts Phase Marks|r: возьми в цель NPC, чтобы добавить его")
            return
        end
        ns.addBoss(id, UnitName("target"))
        selected = id
        ns.updateOptions()
    end)

    -- Пороги выбранного босса
    local d = CreateFrame("Frame", nil, page)
    d:SetPoint("TOPLEFT", 230, -32)
    d:SetPoint("BOTTOMRIGHT", -12, 12)
    f.detail = d

    local nameLabel = label(d, "Имя")
    nameLabel:SetPoint("TOPLEFT", 0, -6)
    f.nameBox = editBox(d, 170, function(self)
        local entry = selected and ns.bossEntry(selected)
        if not entry then return end
        local text = strtrim(self:GetText())
        if text ~= "" and text ~= entry.name then
            ns.editable(selected).name = text
        end
        changed()
    end)
    f.nameBox:SetPoint("TOPLEFT", 36, -2)
    f.idText = label(d, "", "GameFontDisableSmall")
    f.idText:SetPoint("LEFT", f.nameBox, "RIGHT", 8, 0)

    for text, x in pairs({ ["HP %"] = 4, ["Героик"] = 58, ["Событие"] = 108, ["Подпись"] = 172 }) do
        label(d, text):SetPoint("TOPLEFT", x, -36)
    end
    for i = 1, MAX_MARKS do markRows[i] = markRow(d, i) end

    f.addMark = button(d, "+ Порог", 90)
    f.addMark:SetPoint("BOTTOMLEFT", 0, 0)
    f.addMark:SetScript("OnClick", function()
        local entry = ns.editable(selected)
        table.insert(entry, { hp = 0.5 })
        sortMarks(entry)
        changed()
    end)
    f.reset = button(d, "Сбросить", 90)
    f.reset:SetPoint("LEFT", f.addMark, "RIGHT", 4, 0)
    f.reset:SetScript("OnClick", function() ns.resetBoss(selected); ns.updateOptions() end)
    local delete = button(d, "Удалить босса", 120)
    delete:SetPoint("BOTTOMRIGHT", 0, 0)
    delete:SetScript("OnClick", function()
        ns.deleteBoss(selected)
        selected = nil
        ns.updateOptions()
    end)
end

function ns.updateOptions()
    if not window or not window:IsShown() then return end
    updateStylePage()

    local ids = ns.allBossIds()
    table.sort(ids, function(a, b)
        local na, nb = ns.bossEntry(a).name or "", ns.bossEntry(b).name or ""
        if na == nb then return a < b end
        return na < nb
    end)
    if selected and not ns.bossEntry(selected) then selected = nil end
    for i, id in ipairs(ids) do
        local row = bossRow(i)
        row.id = id
        row.text:SetText((ns.bossEntry(id).name or "?") .. (ns.isCustom(id) and " |cff888888(изм.)|r" or ""))
        row.sel:SetShown(id == selected)
        row:Show()
    end
    for i = #ids + 1, #bossRows do bossRows[i]:Hide() end
    window.list:SetHeight(math.max(1, #ids * ROW_HEIGHT))

    local entry = selected and ns.bossEntry(selected)
    window.detail:SetShown(entry ~= nil)
    if not entry then return end
    window.nameBox:SetText(entry.name or "")
    window.idText:SetText("npc id " .. selected)
    for i, row in ipairs(markRows) do
        local m = entry[i]
        if m then
            row.hp:SetText(ns.formatPct(m.hp))
            row.heroic:SetChecked(m.heroic == true)
            row.event:SetChecked(m.event == true)
            row.note:SetText(m.note or "")
            row:Show()
        else
            row:Hide()
        end
    end
    window.addMark:SetEnabled(#entry < MAX_MARKS)
    window.reset:SetEnabled(ns.DEFAULTS[selected] ~= nil and ns.isCustom(selected))
end

function ns.toggleOptions()
    if not window then
        createWindow()
        window:Hide()
    end
    window:SetShown(not window:IsShown())
    if window:IsShown() then
        if not selected then selected = ns.npcId("target") end
        ns.updateOptions()
    end
end

-- Страница в «Настройки → AddOns»: у аддона своё окно, здесь только описание и кнопка, которая его открывает
local panel = CreateFrame("Frame")
panel.name = "|cff9b1c1cHogwarts|r Phase Marks"

local title = label(panel, panel.name, "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
local hint = label(panel, "Засечки порогов смены фаз на полосах здоровья боссов: рамки цели, фокуса и боссов (Blizzard и ElvUI) и неймплейты.\n\n/hpm — окно настройки\n/hpm test — показать засечки на любой цели", "GameFontHighlight")
hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
hint:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
hint:SetJustifyH("LEFT")

local open = button(panel, "Открыть настройки", 180)
open:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -16)
open:SetScript("OnClick", function()
    if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
    if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
    if not (window and window:IsShown()) then ns.toggleOptions() end
end)

if Settings and Settings.RegisterCanvasLayoutCategory then
    Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, panel.name))
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
end
