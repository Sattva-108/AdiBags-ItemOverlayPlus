local _, ns = ...

local addon = LibStub('AceAddon-3.0'):GetAddon('AdiBags')
local L = addon.L

local openBagCount = 0

-- User-corrected LibCompat Timer usage
local LibCompat = LibStub:GetLibrary("LibCompat-1.0", true)
if not LibCompat then
    print("AdiBags_ItemOverlayPlus: LibCompat-1.0 not found!")
    return
end
-- Assuming CompatTimer.After returns a handle and CompatTimer.Cancel takes that handle
local CompatTimer = LibCompat


local mod = addon:NewModule("ItemOverlayPlus", 'AceEvent-3.0')
mod.uiName = L['Item Overlay Plus']
mod.uiDesc = L["Adds a red overlay to items that are unusable for you."]

local tooltipName = "AdibagsItemOverlayPlusScanningTooltip"
local tooltipFrame = _G[tooltipName] or CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")

local unusableItemsCache = {}
local scanQueue = {}
local scanTimerHandle = nil
local SCAN_DELAY_SECONDS = 0.005

local updateAllButtonsTimerHandle = nil
local UPDATE_ALL_BUTTONS_DEBOUNCE_TIME = 0.25

local function requestUpdateAllButtons(self)
    if updateAllButtonsTimerHandle then
        CompatTimer.CancelTimer(updateAllButtonsTimerHandle) -- User's timer CancelTimer method
        updateAllButtonsTimerHandle = nil
    end
    updateAllButtonsTimerHandle = CompatTimer.After(UPDATE_ALL_BUTTONS_DEBOUNCE_TIME, function() -- User's timer schedule method
        if self.db.profile.EnableOverlay and openBagCount > 0 then
            self:SendMessage('AdiBags_UpdateAllButtons')
        end
        updateAllButtonsTimerHandle = nil
    end)
end

function mod:OnInitialize()
    self.db = addon.db:RegisterNamespace(self.moduleName, {
        profile = {
            EnableOverlay = true,
        },
    })

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ITEM_LOCK_UPDATE")
    frame:RegisterEvent("BAG_UPDATE")
    frame:RegisterEvent("CURRENT_SPELL_CAST_CHANGED")
    frame:SetScript("OnEvent", function(_, event, ...)
        if not self.db.profile.EnableOverlay or openBagCount == 0 then
            if updateAllButtonsTimerHandle then
                CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
                updateAllButtonsTimerHandle = nil
            end
            return
        end
        requestUpdateAllButtons(self)
    end)

    local frame2 = CreateFrame("Frame")
    frame2:RegisterEvent("ITEM_UNLOCKED")
    frame2:RegisterEvent("ITEM_LOCKED")
    frame2:SetScript("OnEvent", function(_, event, bag, slot)
        if not self.db.profile.EnableOverlay or openBagCount == 0 or bag == nil or slot == nil then
            return
        end

        if _G["AdiBagsContainer1"] then
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                unusableItemsCache[bag .. "," .. slot] = nil
                requestUpdateAllButtons(self)
            end
        end
    end)
end

function mod:GetOptions()
    return {
        EnableOverlay = {
            name = L["Enable Overlay"],
            desc = L["Check this if you want overlay shown"],
            type = "toggle",
            width = "double",
            order = 10,
            get = function() return self.db.profile.EnableOverlay end,
            set = function(_, value)
                self.db.profile.EnableOverlay = value
                if not value then
                    self:CancelAndClearScanQueue()
                    if updateAllButtonsTimerHandle then
                        CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
                        updateAllButtonsTimerHandle = nil
                    end
                    for _, bagWindow in ipairs(addon:GetBagWindows()) do
                        if bagWindow:IsVisible() then
                            for _, button in bagWindow:IterateButtons() do
                                if button:IsVisible() and button.IconTexture then
                                    button.IconTexture:SetVertexColor(1, 1, 1)
                                end
                            end
                        end
                    end
                else
                    if openBagCount > 0 then
                        requestUpdateAllButtons(self)
                    end
                end
            end,
        },
    }, addon:GetOptionHandler(self)
end

function mod:OnEnable()
    self:RegisterMessage('AdiBags_UpdateButton', 'QueueButtonScan')
    self:RegisterMessage('AdiBags_BagSwapPanelClosed', 'ItemPositionChanged')
    self:RegisterMessage('AdiBags_NewItemReset', 'ItemPositionChanged')
    self:RegisterMessage('AdiBags_TidyBags', 'TidyBagsUpdateRed')
    self:RegisterMessage('AdiBags_BagOpened', 'OnBagOpened')
    self:RegisterMessage('AdiBags_BagClosed', 'OnBagClosed')
end

function mod:OnDisable()
    -- print("ItemOverlayPlus: OnDisable called")
    self:UnregisterMessage('AdiBags_UpdateButton')
    self:UnregisterMessage('AdiBags_BagSwapPanelClosed')
    self:UnregisterMessage('AdiBags_NewItemReset')
    self:UnregisterMessage('AdiBags_TidyBags')
    self:UnregisterMessage('AdiBags_BagOpened')
    self:UnregisterMessage('AdiBags_BagClosed')

    self:CancelAndClearScanQueue()
    wipe(unusableItemsCache)
    openBagCount = 0

    if updateAllButtonsTimerHandle then
        CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
        updateAllButtonsTimerHandle = nil
    end
    -- print("ItemOverlayPlus: OnDisable complete. Cache size:", self:_CountTable(unusableItemsCache), "Queue size:", #scanQueue)
end

function mod:CancelAndClearScanQueue()
    if scanTimerHandle then
        CompatTimer.CancelTimer(scanTimerHandle)
        scanTimerHandle = nil
    end
    wipe(scanQueue)
    for key, status in pairs(unusableItemsCache) do
        if status == "queued" then
            unusableItemsCache[key] = nil
        end
    end
end

function mod:OnBagOpened()
    openBagCount = openBagCount + 1
    if self.db.profile.EnableOverlay then
        -- Using LibCompat main object's After for simple one-shot delays if it exists
        -- If LibCompat.Timer is needed, it would be LibCompat.Timer:After
        -- Assuming LibCompat.After is the non-cancellable delay for LibCompat-1.0 based on context
        LibCompat.After(0.15, function()
            if openBagCount > 0 and self.db.profile.EnableOverlay then
                requestUpdateAllButtons(self)
            end
        end)
    end
end

function mod:OnBagClosed()
    if openBagCount > 0 then
        openBagCount = openBagCount - 1
        if openBagCount == 0 then
            -- print("ItemOverlayPlus: All bags closed. Wiping cache and queue.")
            self:CancelAndClearScanQueue()
            wipe(unusableItemsCache)
            if updateAllButtonsTimerHandle then
                CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
                updateAllButtonsTimerHandle = nil
            end
            -- print("ItemOverlayPlus: Cache and queue wiped. Cache size:", self:_CountTable(unusableItemsCache), "Queue size:", #scanQueue)
        end
    end
end

function mod:TidyBagsUpdateRed()
    if openBagCount > 0 and self.db.profile.EnableOverlay then
        wipe(unusableItemsCache)
        requestUpdateAllButtons(self)
    end
end

function mod:ItemPositionChanged()
    if openBagCount > 0 and self.db.profile.EnableOverlay then
        wipe(unusableItemsCache)
        requestUpdateAllButtons(self)
    end
end

function mod:ProcessScanQueue()
    scanTimerHandle = nil

    if not self.db.profile.EnableOverlay or openBagCount == 0 or #scanQueue == 0 then
        wipe(scanQueue)
        return
    end

    local buttonToScan = tremove(scanQueue, 1)
    if not buttonToScan then return end

    local key = buttonToScan.bag .. "," .. buttonToScan.slot
    local isButtonValidAndVisible = buttonToScan:IsVisible() and GetContainerItemID(buttonToScan.bag, buttonToScan.slot)

    if isButtonValidAndVisible then
        local parent = buttonToScan:GetParent()
        local adiBagsWindowVisible = false
        while parent do
            if parent == UIParent then break end
            if (parent.bagID or string.match(parent:GetName() or "", "AdiBagsContainer")) and parent:IsVisible() then
                adiBagsWindowVisible = true
                break
            end
            parent = parent:GetParent()
        end
        if not adiBagsWindowVisible then
            isButtonValidAndVisible = false
        end
    end

    if not isButtonValidAndVisible then
        unusableItemsCache[key] = nil
        if #scanQueue > 0 then
            scanTimerHandle = CompatTimer.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
        end
        return
    end

    local isUnusable = self:ScanTooltipOfBagItemForRedText(buttonToScan.bag, buttonToScan.slot)
    unusableItemsCache[key] = isUnusable

    if self.db.profile.EnableOverlay and buttonToScan:IsVisible() and buttonToScan.IconTexture then
        if isUnusable then
            buttonToScan.IconTexture:SetVertexColor(1, 0.1, 0.1)
        else
            buttonToScan.IconTexture:SetVertexColor(1, 1, 1)
        end
    end

    if #scanQueue > 0 then
        scanTimerHandle = CompatTimer.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
    else
        -- print("ItemOverlayPlus: Scan queue finished processing. Cache size:", self:_CountTable(unusableItemsCache))
    end
end

function mod:QueueButtonScan(event, button)
    local key = button.bag .. "," .. button.slot -- Define key early

    if not self.db.profile.EnableOverlay then
        if button.IconTexture then
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        if unusableItemsCache[key] == "queued" then unusableItemsCache[key] = nil end
        return
    end

    -- *** THE CRUCIAL FIX IS HERE ***
    local itemID = GetContainerItemID(button.bag, button.slot)
    if not itemID then
        -- If the slot is now empty, or item is otherwise invalid, clear its cache entry
        if unusableItemsCache[key] ~= nil then
            -- print("ItemOverlayPlus: Clearing cache for now empty/invalid slot:", key)
            unusableItemsCache[key] = nil
        end
        -- Also ensure the button's icon is reset if it was previously colored by us
        if button.IconTexture then
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        return -- Don't queue or process this button further
    end
    -- *** END OF CRUCIAL FIX ***

    if not button:IsVisible() then return end

    local cachedStatus = unusableItemsCache[key]

    if type(cachedStatus) == "boolean" then
        if cachedStatus then
            button.IconTexture:SetVertexColor(1, 0.1, 0.1)
        else
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        return
    elseif cachedStatus == "queued" then
        return
    end

    unusableItemsCache[key] = "queued"
    table.insert(scanQueue, button)

    if not scanTimerHandle and #scanQueue > 0 then
        scanTimerHandle = CompatTimer.After(0, function() self:ProcessScanQueue() end)
    end
end

local function isTextColorRed(textTable)
    if not textTable then return false end
    local text = textTable:GetText()
    if not text or text == "" or string.find(text, "0 / %d+") then return false end
    local r, g, b = textTable:GetTextColor()
    return r > 0.98 and g < 0.15 and b < 0.15
end

function mod:ScanTooltipOfBagItemForRedText(bag, slot)
    tooltipFrame:ClearLines()
    tooltipFrame:SetBagItem(bag, slot)
    for i = 1, tooltipFrame:NumLines() do
        if isTextColorRed(_G[tooltipName .. "TextLeft" .. i]) or isTextColorRed(_G[tooltipName .. "TextRight" .. i]) then
            return true
        end
    end
    return false
end

function mod:_CountTable(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end