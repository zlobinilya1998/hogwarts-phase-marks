-- Hogwarts Phase Marks: засечки порогов смены фаз на полосе здоровья боссов рейдов Cataclysm.
-- Рамки: цель, фокус и боссы — стандартные Blizzard и ElvUI.
-- Босс определяется по npc id из GUID (не по имени — не зависит от языка клиента).
-- /hpm — окно настройки, /hpm test — показать засечки Al'Akir на любой цели (проверка вне рейда).

local ADDON, ns = ...

-- Стандартный список. Правки из окна хранятся в HogwartsPhaseMarksDB.bosses и целиком заменяют запись босса.
-- hp — доля здоровья; heroic — только на героике; event — не смена фазы, а событие (золотая засечка);
-- note — подпись у засечки
local DEFAULTS = {
    -- Blackwing Descent
    [41570] = { name = "Magmaw", { hp = 0.30, heroic = true, note = "Нефариан" } },
    [48270] = { name = "Exposed Head of Magmaw", { hp = 0.30, heroic = true, note = "Нефариан" } }, -- общее HP с Magmaw
    [43296] = { name = "Chimaeron", { hp = 0.20, note = "Mortality" } },
    [41378] = { name = "Maloriak", { hp = 0.25 } },
    -- The Bastion of Twilight
    [44600] = { name = "Halfus Wyrmbreaker", { hp = 0.50, event = true, note = "Furious Roar" } },
    [43687] = { name = "Feludius", { hp = 0.25, note = "фаза 2" } },
    [43686] = { name = "Ignacious", { hp = 0.25, note = "фаза 2" } },
    [43688] = { name = "Arion", { hp = 0.25, note = "фаза 3" } },
    [43689] = { name = "Terrastra", { hp = 0.25, note = "фаза 3" } },
    [43324] = { name = "Cho'gall", { hp = 0.25 } },
    [45213] = { name = "Sinestra", { hp = 0.30 } },
    -- Throne of the Four Winds
    [46753] = { name = "Al'Akir", { hp = 0.80 }, { hp = 0.25 } },
    -- Baradin Hold
    [47120] = { name = "Argaloth", { hp = 0.66, event = true, note = "Fel Firestorm" }, { hp = 0.33, event = true, note = "Fel Firestorm" } },
    -- Firelands
    [53691] = { name = "Shannox", { hp = 0.30, event = true, note = "Frenzied Devotion" } },
    [52558] = { name = "Lord Rhyolith", { hp = 0.25 } },
    [52409] = { name = "Ragnaros", { hp = 0.70 }, { hp = 0.40 }, { hp = 0.10, heroic = true } },
    -- Dragon Soul
    [55265] = { name = "Morchok", { hp = 0.90, heroic = true, event = true, note = "Kohcrom" }, { hp = 0.20, event = true, note = "Furious" } },
    [57773] = { name = "Kohcrom", { hp = 0.20, event = true, note = "Furious" } }, -- общее HP с Morchok
    [56173] = { name = "Madness of Deathwing", { hp = 0.20 } },
}

local TEST_MARKS = DEFAULTS[46753]

-- Внешний вид; правки из вкладки «Вид» хранятся в HogwartsPhaseMarksDB.style
local STYLE_DEFAULTS = {
    enabled = true,
    width = 2,
    nextWidth = 3,
    outline = 1,
    overhang = 3,            -- насколько засечка выступает за полосу сверху и снизу
    phaseColor = { 1, 1, 1 },
    eventColor = { 1, 0.82, 0.2 },
    outlineColor = { 0, 0, 0 },
    labelPos = "BOTTOM",     -- BOTTOM | TOP | INSIDE | NONE
    labelOffset = 0,
    labelsMode = "ALL",      -- ALL | NEXT (подпись только у следующего порога)
    fontSize = 10,
    passedAlpha = 0.3,
    warnRange = 0.10,        -- ближе этого к следующему порогу засечка мигает
}

-- Полоса Blizzard маленькая и зажата между именем и маной — по умолчанию компактнее,
-- а подпись уходит под полосу маны
local KIND_DEFAULTS = {
    elvui = {},
    blizzard = { width = 1, nextWidth = 2, overhang = 0, fontSize = 8, labelsMode = "NEXT", labelOffset = 13 },
    nameplate = { width = 1, nextWidth = 2, overhang = 2, fontSize = 8, labelsMode = "NEXT" },
}

local function style(key, kind)
    local s = HogwartsPhaseMarksDB and HogwartsPhaseMarksDB.style[kind]
    if s and s[key] ~= nil then return s[key] end
    local k = KIND_DEFAULTS[kind][key]
    if k ~= nil then return k end
    return STYLE_DEFAULTS[key]
end

local testMode = false

local function npcId(unit)
    local guid = UnitGUID(unit)
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

local function isHeroic()
    local _, instanceType, difficultyId = GetInstanceInfo()
    return instanceType == "raid" and (difficultyId == 5 or difficultyId == 6)
end

local function bossEntry(id)
    local db = HogwartsPhaseMarksDB
    if db and db.bosses[id] then return db.bosses[id] end
    if db and db.deleted[id] then return nil end
    return DEFAULTS[id]
end

local function formatPct(hp)
    return format("%g", math.floor(hp * 1000 + 0.5) / 10)
end

local function marksFor(unit)
    if not UnitExists(unit) then return nil end
    if testMode then return TEST_MARKS end
    local list = bossEntry(npcId(unit))
    if not list then return nil end
    local heroic = isHeroic()
    local out = {}
    for _, m in ipairs(list) do
        if heroic or not m.heroic then out[#out + 1] = m end
    end
    return #out > 0 and out or nil
end

-- Полосы здоровья: { unit, функция, возвращающая StatusBar }. Рамки ElvUI создаются позже входа в игру,
-- поэтому ищем их каждый раз заново, а не один раз при загрузке.
local BARS = {
    { unit = "target", kind = "blizzard", get = function() return TargetFrame and TargetFrame.healthbar end },
    { unit = "focus", kind = "blizzard", get = function() return FocusFrame and FocusFrame.healthbar end },
    { unit = "target", kind = "elvui", get = function() return ElvUF_Target and ElvUF_Target.Health end },
    { unit = "focus", kind = "elvui", get = function() return ElvUF_Focus and ElvUF_Focus.Health end },
}
for i = 1, 8 do
    local unit = "boss" .. i
    BARS[#BARS + 1] = { unit = unit, kind = "blizzard", get = function() local f = _G["Boss" .. i .. "TargetFrame"]; return f and f.healthbar end }
    BARS[#BARS + 1] = { unit = unit, kind = "elvui", get = function() local f = _G["ElvUF_Boss" .. i]; return f and f.Health end }
end
-- Неймплейты: у ElvUI свой фрейм в plate.unitFrame, стандартный plate.UnitFrame при этом скрыт
for i = 1, 40 do
    local unit = "nameplate" .. i
    BARS[#BARS + 1] = { unit = unit, kind = "nameplate", get = function()
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if not plate then return nil end
        return (plate.unitFrame and plate.unitFrame.Health) or (plate.UnitFrame and plate.UnitFrame.healthBar)
    end }
end

local BARS_BY_UNIT = {}
for _, b in ipairs(BARS) do
    BARS_BY_UNIT[b.unit] = BARS_BY_UNIT[b.unit] or {}
    table.insert(BARS_BY_UNIT[b.unit], b)
end

-- Слой засечек на полосе: отдельный фрейм поверх заливки, текстуры переиспользуются
local overlays = {}

local function healthPct(unit)
    local max = UnitHealthMax(unit)
    if not max or max == 0 then return 1 end
    return UnitHealth(unit) / max
end

local function placeVertical(tex, bar, x, overhang)
    tex:ClearAllPoints()
    tex:SetPoint("TOP", bar, "TOPLEFT", x, overhang)
    tex:SetPoint("BOTTOM", bar, "BOTTOMLEFT", x, -overhang)
end

local function layout(bar)
    local o = overlays[bar]
    if not o or not o.marks then return end
    local width = bar:GetWidth()
    local reverse = bar.GetReverseFill and bar:GetReverseFill()
    local pct = healthPct(o.unit)
    local nextMark
    for _, m in ipairs(o.marks) do
        if m.hp < pct and (not nextMark or m.hp > nextMark.hp) then nextMark = m end
    end
    local kind = o.kind
    local outline, overhang = style("outline", kind), style("overhang", kind)
    local labelPos, labelOffset = style("labelPos", kind), style("labelOffset", kind)
    local allLabels = style("labelsMode", kind) == "ALL"
    local outlineR, outlineG, outlineB = unpack(style("outlineColor", kind))
    o.pulse = nil
    for i, m in ipairs(o.marks) do
        local n = o.notches[i]
        local x = width * (reverse and (1 - m.hp) or m.hp)
        local isNext = m == nextMark
        local w = isNext and style("nextWidth", kind) or style("width", kind)
        local r, g, b = unpack(style(m.event and "eventColor" or "phaseColor", kind))

        placeVertical(n.outline, bar, x, overhang + outline)
        n.outline:SetWidth(w + 2 * outline)
        n.outline:SetColorTexture(outlineR, outlineG, outlineB, 0.9)
        n.outline:SetShown(outline > 0)
        placeVertical(n.line, bar, x, overhang)
        n.line:SetWidth(w)
        n.line:SetColorTexture(r, g, b)

        local text = formatPct(m.hp) .. "%"
        if m.note then text = text .. " " .. m.note end
        if isNext then text = text .. format(" · ещё %.1f%%", (pct - m.hp) * 100) end
        n.label:SetFont(STANDARD_TEXT_FONT, style("fontSize", kind), "OUTLINE")
        n.label:ClearAllPoints()
        if labelPos == "TOP" then
            n.label:SetPoint("BOTTOM", bar, "TOPLEFT", x, overhang + outline + labelOffset)
        elseif labelPos == "INSIDE" then
            n.label:SetPoint("LEFT", bar, "LEFT", x + w / 2 + outline + 2, labelOffset)
        else
            n.label:SetPoint("TOP", bar, "BOTTOMLEFT", x, -overhang - outline - labelOffset)
        end
        n.label:SetTextColor(r, g, b)
        n.label:SetText(text)
        n.label:SetShown(labelPos ~= "NONE" and (allLabels or isNext))

        n.frame:SetAlpha(m.hp >= pct and style("passedAlpha", kind) or 1)
        if isNext and pct - m.hp <= style("warnRange", kind) then o.pulse = n.frame end
        n.frame:Show()
    end
    for i = #o.marks + 1, #o.notches do o.notches[i].frame:Hide() end
end

local function pulse(frame)
    local o = overlays[frame:GetParent()]
    if o and o.pulse then o.pulse:SetAlpha(0.35 + 0.65 * math.abs(math.sin(GetTime() * 6))) end
end

local function overlayFor(bar)
    local o = overlays[bar]
    if o then return o end
    local frame = CreateFrame("Frame", nil, bar)
    frame:SetAllPoints(bar)
    frame:SetFrameLevel(bar:GetFrameLevel() + 5)
    frame:SetScript("OnUpdate", pulse)
    o = { frame = frame, notches = {} }
    overlays[bar] = o
    bar:HookScript("OnSizeChanged", function() layout(bar) end)
    return o
end

local function newNotch(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    local outline = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    local line = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    local label = frame:CreateFontString(nil, "OVERLAY")
    label:SetFont(STANDARD_TEXT_FONT, STYLE_DEFAULTS.fontSize, "OUTLINE")
    return { frame = frame, outline = outline, line = line, label = label }
end

local function apply(bar, marks, unit, kind)
    if not marks then
        local o = overlays[bar]
        if o then o.marks = nil; o.frame:Hide() end
        return
    end
    if bar.GetOrientation and bar:GetOrientation() == "VERTICAL" then return end
    local o = overlayFor(bar)
    o.marks = marks
    o.unit = unit
    o.kind = kind
    for i = #o.notches + 1, #marks do
        o.notches[i] = newNotch(o.frame)
    end
    o.frame:Show()
    layout(bar)
end

local function refresh(unit)
    local list = BARS
    if unit then list = BARS_BY_UNIT[unit] or {} end
    for _, b in ipairs(list) do
        local bar = b.get()
        if bar then apply(bar, style("enabled", b.kind) and marksFor(b.unit) or nil, b.unit, b.kind) end
    end
end

-- Смена HP не меняет набор засечек — только их состояние (пройдена/следующая) и подписи
local function relayout(unit)
    for _, b in ipairs(BARS_BY_UNIT[unit] or {}) do
        local bar = b.get()
        if bar and overlays[bar] then layout(bar) end
    end
end

local function hideFor(unit)
    for _, b in ipairs(BARS_BY_UNIT[unit] or {}) do
        local bar = b.get()
        if bar then apply(bar, nil) end
    end
end

-- API для окна настройки (HogwartsPhaseMarks_Options.lua)
ns.DEFAULTS = DEFAULTS
ns.bossEntry = bossEntry
ns.formatPct = formatPct
ns.npcId = npcId
ns.refresh = refresh
ns.style = style

function ns.setStyle(kind, key, value)
    HogwartsPhaseMarksDB.style[kind][key] = value
    refresh()
end

function ns.resetStyle(kind)
    wipe(HogwartsPhaseMarksDB.style[kind])
    refresh()
end

function ns.isCustom(id)
    return HogwartsPhaseMarksDB.bosses[id] ~= nil
end

function ns.allBossIds()
    local db, ids = HogwartsPhaseMarksDB, {}
    for id in pairs(DEFAULTS) do
        if not db.deleted[id] then ids[#ids + 1] = id end
    end
    for id in pairs(db.bosses) do
        if not DEFAULTS[id] then ids[#ids + 1] = id end
    end
    return ids
end

-- Запись босса для правки: при первой правке стандартная запись копируется в HogwartsPhaseMarksDB
function ns.editable(id)
    local db = HogwartsPhaseMarksDB
    if not db.bosses[id] then
        db.bosses[id] = CopyTable(DEFAULTS[id] or { name = "NPC " .. id })
        db.deleted[id] = nil
    end
    return db.bosses[id]
end

function ns.addBoss(id, name)
    local db = HogwartsPhaseMarksDB
    db.deleted[id] = nil
    if not bossEntry(id) then db.bosses[id] = { name = name or ("NPC " .. id) } end
    refresh()
end

function ns.deleteBoss(id)
    local db = HogwartsPhaseMarksDB
    db.bosses[id] = nil
    if DEFAULTS[id] then db.deleted[id] = true end
    refresh()
end

function ns.resetBoss(id)
    local db = HogwartsPhaseMarksDB
    db.bosses[id] = nil
    db.deleted[id] = nil
    refresh()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("PLAYER_FOCUS_CHANGED")
events:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
events:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
events:RegisterEvent("UNIT_HEALTH")
events:RegisterEvent("UNIT_MAXHEALTH")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            HogwartsPhaseMarksDB = HogwartsPhaseMarksDB or {}
            HogwartsPhaseMarksDB.bosses = HogwartsPhaseMarksDB.bosses or {}
            HogwartsPhaseMarksDB.deleted = HogwartsPhaseMarksDB.deleted or {}
            local s = HogwartsPhaseMarksDB.style or {}
            -- До 1.4 вид был общим для всех рамок; он настраивался под ElvUI — переносим туда
            if not s.elvui then
                local old = s
                s = { elvui = {} }
                for k, v in pairs(old) do s.elvui[k] = v end
            end
            s.blizzard = s.blizzard or {}
            s.nameplate = s.nameplate or {}
            HogwartsPhaseMarksDB.style = s
        end
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        relayout(arg1)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- ElvUI создаёт свой фрейм неймплейта на этом же событии — ждём кадр, чтобы он успел появиться
        C_Timer.After(0, function() refresh(arg1) end)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        hideFor(arg1)
    elseif event == "PLAYER_TARGET_CHANGED" then
        refresh("target")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        refresh("focus")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- ElvUI достраивает рамки после входа — повторяем чуть позже
        refresh()
        C_Timer.After(2, function() refresh() end)
    else
        refresh()
    end
end)

SLASH_HOGWARTSPHASEMARKS1 = "/hpm"
SLASH_HOGWARTSPHASEMARKS2 = "/bpm"
SlashCmdList.HOGWARTSPHASEMARKS = function(msg)
    msg = strlower(strtrim(msg or ""))
    if msg == "test" then
        testMode = not testMode
        refresh()
        print("|cffd9b45aHogwarts Phase Marks|r: тестовый режим " .. (testMode and "включён — засечки Al'Akir (80%, 25%) на любой цели" or "выключен"))
    elseif msg == "" then
        ns.toggleOptions()
    else
        print("|cffd9b45aHogwarts Phase Marks|r: /hpm — окно настройки, /hpm test — показать засечки на любой цели (проверка вне рейда)")
    end
end
