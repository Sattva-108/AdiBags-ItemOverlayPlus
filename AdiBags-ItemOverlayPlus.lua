local _, ns = ...

local addon = LibStub('AceAddon-3.0'):GetAddon('AdiBags')
local L = addon.L

local openBagCount = 0

-- Ensure LibCompat is loaded
if not LibStub:GetLibrary("LibCompat-1.0", true) then
    -- Handle missing LibCompat if necessary, though it's usually present with AceAddon-3.0
    print("AdiBags_ItemOverlayPlus: LibCompat-1.0 not found!")
    return
end
local CompatTimer = LibStub("LibCompat-1.0")

local mod = addon:NewModule("ItemOverlayPlus", 'AceEvent-3.0')
mod.uiName = L['Item Overlay Plus']
mod.uiDesc = L["Adds a red overlay to items that are unusable for you."]

local tooltipName = "AdibagsItemOverlayPlusScanningTooltip"
local tooltipFrame = _G[tooltipName] or CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")

local unusableItemsCache = {} -- Cache for scanned items: nil (not scanned), "queued", true (unusable), false (usable)

local scanQueue = {}
local scanTimer = nil
local SCAN_DELAY_SECONDS = 0.005 -- Time between individual item scans.

function mod:OnInitialize()
    self.db = addon.db:RegisterNamespace(self.moduleName, {
        profile = {
            EnableOverlay = true,
        },
    })

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ITEM_LOCK_UPDATE")
    frame:RegisterEvent("BAG_UPDATE")
    frame:RegisterEvent("CURRENT_SPELL_CAST_CHANGED") -- Re-added event
    frame:SetScript("OnEvent", function(_, event, ...)
        if not self.db.profile.EnableOverlay or openBagCount == 0 then
            return
        end

        if event == "ITEM_LOCK_UPDATE" or event == "BAG_UPDATE" or event == "CURRENT_SPELL_CAST_CHANGED" then
            -- For these events, tell AdiBags to update all buttons.
            -- Our QueueButtonScan will efficiently re-apply colors for cached items
            -- or queue new/changed items for scanning.
            -- print("Event causing full update:", event)
            self:SendMessage('AdiBags_UpdateAllButtons')
        end
    end)

    local frame2 = CreateFrame("Frame")
    frame2:RegisterEvent("ITEM_UNLOCKED")
    frame2:RegisterEvent("ITEM_LOCKED")
    frame2:SetScript("OnEvent", function(_, event, bag, slot)
        if not self.db.profile.EnableOverlay or openBagCount == 0 or bag == nil or slot == nil then
            return
        end

        if event == "ITEM_UNLOCKED" or event == "ITEM_LOCKED" then
            if _G["AdiBagsContainer1"] then -- Check if AdiBags UI is likely present
                local itemID = GetContainerItemID(bag, slot)
                if itemID then
                    -- print("Item (un)locked, clearing cache for:", bag, slot)
                    unusableItemsCache[bag .. "," .. slot] = nil
                    self:SendMessage('AdiBags_UpdateAllButtons')
                end
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
                    -- Reset all currently visible item colors
                    for _, bagWindow in ipairs(addon:GetBagWindows()) do
                        if bagWindow:IsVisible() then
                            for _, button in bagWindow:IterateButtons() do
                                if button:IsVisible() and button.IconTexture then
                                    button.IconTexture:SetVertexColor(1, 1, 1)
                                    local key = button.bag .. "," .. button.slot
                                    if unusableItemsCache[key] == "queued" then
                                        unusableItemsCache[key] = nil
                                    end
                                end
                            end
                        end
                    end
                else
                    if openBagCount > 0 then -- Only update if bags are already open
                        self:SendMessage('AdiBags_UpdateAllButtons')
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
    self:UnregisterMessage('AdiBags_UpdateButton')
    self:UnregisterMessage('AdiBags_BagSwapPanelClosed')
    self:UnregisterMessage('AdiBags_NewItemReset')
    self:UnregisterMessage('AdiBags_TidyBags')
    self:UnregisterMessage('AdiBags_BagOpened')
    self:UnregisterMessage('AdiBags_BagClosed')

    self:CancelAndClearScanQueue()
    wipe(unusableItemsCache)
    openBagCount = 0
end

function mod:CancelAndClearScanQueue()
    if scanTimer then
        CompatTimer.Cancel(scanTimer)
        scanTimer = nil
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
        -- Delay slightly to allow AdiBags to fully initialize its buttons
        -- Using LibCompat.After directly here for a one-shot delay.
        LibStub("LibCompat-1.0").After(0.1, function()
            if openBagCount > 0 and self.db.profile.EnableOverlay then -- Re-check state
                self:SendMessage('AdiBags_UpdateAllButtons')
            end
        end)
    end
end

function mod:OnBagClosed()
    if openBagCount > 0 then
        openBagCount = openBagCount - 1
        if openBagCount == 0 then
            self:CancelAndClearScanQueue()
            wipe(unusableItemsCache)
        end
    end
end

function mod:TidyBagsUpdateRed()
    wipe(unusableItemsCache)
    if self.db.profile.EnableOverlay and openBagCount > 0 then
        self:SendMessage('AdiBags_UpdateAllButtons')
    end
end

function mod:ItemPositionChanged()
    wipe(unusableItemsCache)
    if self.db.profile.EnableOverlay and openBagCount > 0 then
        self:SendMessage('AdiBags_UpdateAllButtons')
    end
end

function mod:ProcessScanQueue()
    scanTimer = nil

    if not self.db.profile.EnableOverlay or openBagCount == 0 or #scanQueue == 0 then
        wipe(scanQueue)
        return
    end

    local buttonToScan = tremove(scanQueue, 1)
    if not buttonToScan then return end -- Should be caught by #scanQueue check, but defensive

    if not buttonToScan:IsVisible() or not GetContainerItemID(buttonToScan.bag, buttonToScan.slot) then
        unusableItemsCache[buttonToScan.bag .. "," .. buttonToScan.slot] = nil
        if #scanQueue > 0 then
            scanTimer = CompatTimer.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
        end
        return
    end

    local key = buttonToScan.bag .. "," .. buttonToScan.slot
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
        scanTimer = CompatTimer.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
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
    if not button:IsVisible() then return end

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
        return
    end

    unusableItemsCache[key] = "queued"
    table.insert(scanQueue, button)

    if not scanTimer and #scanQueue > 0 then
        scanTimer = CompatTimer.After(0, function() self:ProcessScanQueue() end)
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
    -- No specific handling for bag < 0 for SetInventoryItem as AdiBags should provide
    -- bag/slot that SetBagItem can understand (e.g. bag = -1 for main bank).

    for i = 1, tooltipFrame:NumLines() do
        if isTextColorRed(_G[tooltipName .. "TextLeft" .. i]) or isTextColorRed(_G[tooltipName .. "TextRight" .. i]) then
            return true
        end
    end
    return false
end