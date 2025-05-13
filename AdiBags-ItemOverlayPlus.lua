local _, ns = ...

local addon = LibStub('AceAddon-3.0'):GetAddon('AdiBags')
local L = addon.L

local openBagCount = 0

-- Plan Item 1: Correct LibCompat Timer Usage
local LibCompat = LibStub:GetLibrary("LibCompat-1.0", true)
if not LibCompat then
    print("AdiBags_ItemOverlayPlus: LibCompat-1.0 not found!")
    return
end
local CompatTimer = LibCompat -- Correctly get the Timer sub-module

local mod = addon:NewModule("ItemOverlayPlus", 'AceEvent-3.0')
mod.uiName = L['Item Overlay Plus']
mod.uiDesc = L["Adds a red overlay to items that are unusable for you."]

local tooltipName = "AdibagsItemOverlayPlusScanningTooltip"
local tooltipFrame = _G[tooltipName] or CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")

local unusableItemsCache = {}
local scanQueue = {}
local scanTimerHandle = nil -- Stores the handle from CompatTimer.After
local SCAN_DELAY_SECONDS = 0.005

-- Plan Item 3: Debounce AdiBags_UpdateAllButtons
local updateAllButtonsTimerHandle = nil
local UPDATE_ALL_BUTTONS_DEBOUNCE_TIME = 0.25 -- Debounce time in seconds

local function requestUpdateAllButtons(self)
    if updateAllButtonsTimerHandle then
        CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
        updateAllButtonsTimerHandle = nil
    end
    updateAllButtonsTimerHandle = CompatTimer.After(UPDATE_ALL_BUTTONS_DEBOUNCE_TIME, function()
        -- print("Debounced: Sending AdiBags_UpdateAllButtons")
        if self.db.profile.EnableOverlay and openBagCount > 0 then -- Re-check conditions before sending
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
        -- print("Event triggering requestUpdateAllButtons:", event)
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
                -- print("Item (un)locked, clearing cache for:", bag, slot)
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
                    self:CancelAndClearScanQueue() -- Clears scan queue and resets "queued" items
                    if updateAllButtonsTimerHandle then
                        CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
                        updateAllButtonsTimerHandle = nil
                    end
                    -- Reset all currently visible item colors
                    for _, bagWindow in ipairs(addon:GetBagWindows()) do
                        if bagWindow:IsVisible() then
                            for _, button in bagWindow:IterateButtons() do
                                if button:IsVisible() and button.IconTexture then
                                    button.IconTexture:SetVertexColor(1, 1, 1)
                                    -- No need to touch unusableItemsCache here if it's not "queued"
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

    self:CancelAndClearScanQueue() -- Plan Item 2: Clears scan queue, resets "queued", cancels timer
    wipe(unusableItemsCache)       -- Plan Item 2: Full cache wipe
    openBagCount = 0

    if updateAllButtonsTimerHandle then
        CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
        updateAllButtonsTimerHandle = nil
    end
    -- print("ItemOverlayPlus: OnDisable complete. Cache size:", self:_CountTable(unusableItemsCache), "Queue size:", #scanQueue)
end

-- Plan Item 2: Aggressive Cache & Queue Cleanup
function mod:CancelAndClearScanQueue()
    -- print("ItemOverlayPlus: CancelAndClearScanQueue called")
    if scanTimerHandle then
        CompatTimer.CancelTimer(scanTimerHandle)
        scanTimerHandle = nil
    end
    wipe(scanQueue) -- Wipe the queue itself
    -- Reset any items in cache that were marked as "queued"
    for key, status in pairs(unusableItemsCache) do
        if status == "queued" then
            unusableItemsCache[key] = nil
        end
    end
    -- print("ItemOverlayPlus: Scan queue cleared. Queue size:", #scanQueue)
end

function mod:OnBagOpened()
    openBagCount = openBagCount + 1
    -- print("ItemOverlayPlus: OnBagOpened. Count:", openBagCount)
    if self.db.profile.EnableOverlay then
        -- Delay slightly to allow AdiBags to fully initialize its buttons
        LibCompat.After(0.15, function() -- Use main LibCompat.After for simple one-shot delays
            if openBagCount > 0 and self.db.profile.EnableOverlay then -- Re-check state
                requestUpdateAllButtons(self)
            end
        end)
    end
end

function mod:OnBagClosed()
    if openBagCount > 0 then
        openBagCount = openBagCount - 1
        -- print("ItemOverlayPlus: OnBagClosed. Count:", openBagCount)
        if openBagCount == 0 then
            -- print("ItemOverlayPlus: All bags closed. Wiping cache and queue.")
            self:CancelAndClearScanQueue() -- Plan Item 2
            wipe(unusableItemsCache)       -- Plan Item 2
            if updateAllButtonsTimerHandle then
                CompatTimer.CancelTimer(updateAllButtonsTimerHandle)
                updateAllButtonsTimerHandle = nil
            end
            -- print("ItemOverlayPlus: Cache and queue wiped. Cache size:", self:_CountTable(unusableItemsCache), "Queue size:", #scanQueue)
        end
    end
end

function mod:TidyBagsUpdateRed()
    -- print("ItemOverlayPlus: TidyBagsUpdateRed called.")
    if openBagCount > 0 and self.db.profile.EnableOverlay then -- Only if active
        wipe(unusableItemsCache)
        requestUpdateAllButtons(self)
    end
end

function mod:ItemPositionChanged()
    -- print("ItemOverlayPlus: ItemPositionChanged called.")
    if openBagCount > 0 and self.db.profile.EnableOverlay then -- Only if active
        wipe(unusableItemsCache)
        requestUpdateAllButtons(self)
    end
end

function mod:ProcessScanQueue()
    scanTimerHandle = nil -- Timer has fired or been cancelled if we are here

    if not self.db.profile.EnableOverlay or openBagCount == 0 or #scanQueue == 0 then
        wipe(scanQueue) -- Ensure queue is empty if we bail early
        return
    end

    local buttonToScan = tremove(scanQueue, 1)
    if not buttonToScan then return end -- Should be caught by #scanQueue check

    local key = buttonToScan.bag .. "," .. buttonToScan.slot

    -- Plan Item 5: Review `ProcessScanQueue` Button Validity
    -- Check if button is still valid and visible in an AdiBags context
    local isButtonValidAndVisible = buttonToScan:IsVisible() and GetContainerItemID(buttonToScan.bag, buttonToScan.slot)
    if isButtonValidAndVisible then
        local parent = buttonToScan:GetParent()
        local adiBagsWindowVisible = false
        while parent do
            if parent == UIParent then break end -- Reached top without finding AdiBags window
            -- A simple check, AdiBags container frames usually have a bagID or are named like AdiBagsContainerX
            if (parent.bagID or string.match(parent:GetName() or "", "AdiBagsContainer")) and parent:IsVisible() then
                adiBagsWindowVisible = true
                break
            end
            parent = parent:GetParent()
        end
        if not adiBagsWindowVisible then
            isButtonValidAndVisible = false -- Mark as invalid if its AdiBags window isn't visible
        end
    end

    if not isButtonValidAndVisible then
        unusableItemsCache[key] = nil -- Reset cache status if button became invalid/invisible
        if #scanQueue > 0 then
            scanTimerHandle = CompatTimer.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
        end
        return
    end

    -- print("Processing scan for:", key)
    local isUnusable = self:ScanTooltipOfBagItemForRedText(buttonToScan.bag, buttonToScan.slot)
    unusableItemsCache[key] = isUnusable -- Store actual boolean result

    -- Re-check visibility and apply color, only if overlay is still enabled and button still visible
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
        -- print("ItemOverlayPlus: Scan queue finished processing.")
    end
end

function mod:QueueButtonScan(event, button)
    if not self.db.profile.EnableOverlay then
        if button.IconTexture then
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        local key = button.bag .. "," .. button.slot
        if unusableItemsCache[key] == "queued" then unusableItemsCache[key] = nil end
        return
    end

    if not GetContainerItemID(button.bag, button.slot) then return end
    if not button:IsVisible() then return end -- Important: only queue visible buttons

    local key = button.bag .. "," .. button.slot
    local cachedStatus = unusableItemsCache[key]

    if type(cachedStatus) == "boolean" then
        if cachedStatus then
            button.IconTexture:SetVertexColor(1, 0.1, 0.1)
        else
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        return
    elseif cachedStatus == "queued" then
        return -- Already in queue or being processed
    end

    unusableItemsCache[key] = "queued"
    table.insert(scanQueue, button)
    -- print("Queued for scan:", key, "#scanQueue:", #scanQueue)

    if not scanTimerHandle and #scanQueue > 0 then
        -- print("Starting scan timer.")
        scanTimerHandle = CompatTimer.After(0, function() self:ProcessScanQueue() end) -- Start ASAP
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

-- Helper for debugging cache size (Plan Item 4 - if needed)
function mod:_CountTable(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end