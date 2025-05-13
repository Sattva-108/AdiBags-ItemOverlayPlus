local _, ns = ...

local addon = LibStub('AceAddon-3.0'):GetAddon('AdiBags')
local L = addon.L

LibCompat = LibStub:GetLibrary("LibCompat-1.0")

local mod = addon:NewModule("ItemOverlayPlus", 'AceEvent-3.0')
mod.uiName = L['Item Overlay Plus']
mod.uiDesc = L["Adds a red overlay to items that are unusable for you."]

local tooltipName = "AdibagsItemOverlayPlusScanningTooltip"
local tooltipFrame = _G[tooltipName] or CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")

local unusableItemsCache = {} -- Cache for scanned items
-- place with other locals
local itemUsableCache  = {}                 -- [itemID] = true | false

-- Вверху файла (после локальных объявлений)
local openBagCount = 0   -- сколько сумок AdiBags сейчас отображается?
-- put with other locals
local lastBagUpdate = 0          -- throttle timestamp (sec)

local function ResetUsableCache()
    wipe(itemUsableCache)
    wipe(unusableItemsCache)                -- keep slot-cache in sync
end

function mod:OnInitialize()
    self.db = addon.db:RegisterNamespace(self.moduleName, {
        profile = {
            EnableOverlay = true,
        },
    })

    -- Register the ITEM_UNLOCKED and MERCHANT_UPDATE event handlers
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ITEM_LOCK_UPDATE")
    frame:RegisterEvent("BAG_UPDATE")
    frame:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
    frame:SetScript("OnEvent", function(_, event, bag, slot)
        if openBagCount == 0 then return end          -- сумки скрыты → игнор

        if event == "BAG_UPDATE" then                -- троттлим до 10 кадров
            if GetTime() - lastBagUpdate < 0.10 then return end
            lastBagUpdate = GetTime()
            self:SendMessage('AdiBags_UpdateAllButtons')

        elseif event == "ITEM_LOCK_UPDATE" then      -- предмет заблокировался
            if bag and slot then                     -- чистим ТОЛЬКО этот слот
                unusableItemsCache[bag..","..slot] = nil
            end
            self:SendMessage('AdiBags_UpdateAllButtons')

        elseif event == "CURRENT_SPELL_CAST_CHANGED" then
            -- Меняемся скастованное заклинание: просто перерисовываем,
            --  но НЕ сбрасываем itemUsableCache (иначе возникают лавины таймеров)
            self:SendMessage('AdiBags_UpdateAllButtons')
        end
    end)

    local frame2 = CreateFrame("Frame")
    frame2:RegisterEvent("ITEM_UNLOCKED")
    frame2:RegisterEvent("ITEM_LOCKED")
    frame2:SetScript("OnEvent", function(_, event, bag, slot)
        if event == "ITEM_UNLOCKED" or event == "ITEM_LOCKED" then
            if openBagCount > 0 and bag~=nil and slot~=nil then
                --print(bag, slot)
                unusableItemsCache[bag .. "," .. slot] = nil
                self:SendMessage('AdiBags_UpdateAllButtons')
            end
        end
    end)
end


function mod:GetOptions()
    EnableOverlay = self.db.profile.EnableOverlay
    return {
        EnableOverlay = {
            name = L["Enable Overlay"],
            desc = L["Check this if you want overlay shown"],
            type = "toggle",
            width = "double",
            order = 10,
            get = function() return EnableOverlay end,
            set = function(_, value)
                EnableOverlay = value
                self.db.profile.EnableOverlay = value
                self:SendMessage('AdiBags_UpdateAllButtons')
            end,
        },
    }, addon:GetOptionHandler(self)
end





-- -- Register a message to check if the bag is open whenever the AdiBags_BagOpened or AdiBags_BagClosed messages are received
-- mod:RegisterMessage('AdiBags_BagOpened', emptyfornow)



function mod:OnEnable()

    EnableOverlay = true
    --self:RegisterMessage('AdiBags_UpdateButton', 'UpdateButton')

    self:RegisterMessage('AdiBags_BagSwapPanelClosed', 'ItemPositionChanged')
    self:RegisterMessage('AdiBags_NewItemReset', 'ItemPositionChanged')
    -- self:RegisterMessage('AdiBags_TidyBagsButtonClick', 'ItemPositionChanged')

    self:RegisterMessage('AdiBags_TidyBags', 'TidyBagsUpdateRed')

    -- В OnEnable (или сразу после него)
    self:RegisterMessage('AdiBags_BagOpened',  'OnBagOpened')
    self:RegisterMessage('AdiBags_BagClosed', 'OnBagClosed')

end

function mod:OnBagOpened()
    openBagCount = openBagCount + 1
    if openBagCount == 1 then
        self:RegisterMessage('AdiBags_UpdateButton', 'UpdateButton')
    end

    -- ⚡ Запрашиваем перекраску всех кнопок
    LibCompat.After(0, function()
        self:SendMessage('AdiBags_UpdateAllButtons')
    end)
end


function mod:OnBagClosed()
    if openBagCount > 0 then
        openBagCount = openBagCount - 1
        if openBagCount == 0 then          -- все сумки закрыты
            self:UnregisterMessage('AdiBags_UpdateButton')
            -- на всякий случай сбросим таймеры/кэш
            wipe(unusableItemsCache)
        end
    end
end


function mod:TidyBagsUpdateRed()
    wipe(unusableItemsCache)
    self:SendMessage('AdiBags_UpdateAllButtons')
    -- print('Tidy Bags: Redoing button scanning due to filters changed')
end


function mod:ItemPositionChanged()
    wipe(unusableItemsCache)
    self:SendMessage('AdiBags_UpdateAllButtons')
    -- print('Button Position: Redoing button scanning due to filters changed')
end



function mod:OnDisable()
    EnableOverlay = false
end

------------------------------------------------------------------------
-- 🆕  Step 4 — красим кнопку Только когда цвет реально меняется
------------------------------------------------------------------------

-- helper рядом с другими локальными функциями
local function ApplyOverlay(button, unusable)
    -- 0 = белый, 1 = красный  (храним для логики, но не доверяем UI)
    button.__overlayState = unusable and 1 or 0

    if unusable then
        button.IconTexture:SetVertexColor(1, 0.1, 0.1)
    else
        button.IconTexture:SetVertexColor(1, 1,   1)
    end
end


------------------------------------------------------------------------
-- 🆕  Step 2 — единая очередь таймеров
------------------------------------------------------------------------

-- locals (рядом с остальными счётчиками)
local pendingButtons, processingQueue = {}, false
local pendingItem = {}   -- pendingItem[id] = true
local BATCH_SIZE = 12          -- кнопок за кадр; подберите по вкусу

-- обработка очереди
local function ProcessQueue()
    local processed = 0
    while processed < BATCH_SIZE and #pendingButtons > 0 do
        local entry = tremove(pendingButtons, 1)

        local unusable = mod:ScanTooltipOfBagItemForRedText(entry.bag, entry.slot)
        itemUsableCache[entry.id] = unusable
        -- в ProcessQueue после itemUsableCache[itemID] = unusable
        pendingItem[entry.id] = nil                         -- сняли блокировку


        if entry.btn and entry.btn.IconTexture then
            ApplyOverlay(entry.btn, unusable)
        end
        processed = processed + 1
    end

    if #pendingButtons > 0 then            -- ещё работа → следующий кадр
        LibCompat.After(0, ProcessQueue)
    else
        processingQueue = false            -- очередь пуста
    end
end

-- helper: кладём кнопку в очередь

-- EnqueueButton
local function EnqueueButton(bag, slot, itemID, button)
    if pendingItem[itemID] then return end          -- уже ждёт скана
    pendingItem[itemID] = true                      -- помечаем

    pendingButtons[#pendingButtons+1] =
    { bag = bag, slot = slot, id = itemID, btn = button }

    if not processingQueue then
        processingQueue = true
        LibCompat.After(0, ProcessQueue)
    end
end




-- put this near the top of the file, before you first touch the counters
local createdTimers, firedTimers = 0, 0      -- both start at 0


-- replace the body of UpdateButton
------------------------------------------------------------------------
--  FULL UpdateButton with debug
------------------------------------------------------------------------
function mod:UpdateButton(_, button)
    if not EnableOverlay then return end

    local itemID = GetContainerItemID(button.bag, button.slot)

    -- ► слот опустел — всегда сбрасываем красный
    if not itemID then
        ApplyOverlay(button, false)
        --print("[IOP] empty", button.bag, button.slot)
        return
    end

    -- ► быстрый путь: уже знаем пригодность этого itemID
    local cached = itemUsableCache[itemID]
    if cached ~= nil then
        ApplyOverlay(button, cached)                   -- ← ставим цвет!
--        print("[IOP] fast", itemID, cached and "red" or "white")
        return
    end

    -- ► медленный путь: кладём кнопку в общую очередь
    EnqueueButton(button.bag, button.slot, itemID, button)
--    print("[IOP] queued", itemID, "slot", button.slot)
end




local function roundRGB(r, g, b)
    return floor(r * 100 + 0.5) / 100, floor(g * 100 + 0.5) / 100, floor(b * 100 + 0.5) / 100
end

local function isTextColorRed(textTable)
    if not textTable then
        return false
    end

    local text = textTable:GetText()
    if not text or text == "" or string.find(text, "0 / %d+") then
        return false
    end

    -- local r, g, b = roundRGB(textTable:GetTextColor())
    local r, g, b = textTable:GetTextColor()
    -- return r > 1 and g == 0.13 and b == 0.13
    return r > 0.98 and g < 0.15 and b < 0.15
end

function mod:ScanTooltipOfBagItemForRedText(bag, slot)
    --local tooltip = _G[tooltipName]
    tooltipFrame:ClearLines()
    tooltipFrame:SetBagItem(bag, slot)
    if bag < 0 then
        tooltipFrame:SetInventoryItem('player', slot+39)
    end
    for i=1, tooltipFrame:NumLines() do
        if isTextColorRed(_G[tooltipName .. "TextLeft" .. i]) or isTextColorRed(_G[tooltipName .. "TextRight" .. i]) then
            -- print("Red text found on line:", i, "in bag:", bag, "slot:", slot)
            return true
        end
    end

    return false
end
