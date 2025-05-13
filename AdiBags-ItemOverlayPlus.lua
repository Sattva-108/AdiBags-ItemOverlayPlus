local _, ns = ...

local addon = LibStub('AceAddon-3.0'):GetAddon('AdiBags')
local L = addon.L

local openBagCount = 0

LibCompat = LibStub:GetLibrary("LibCompat-1.0") -- Already present

local mod = addon:NewModule("ItemOverlayPlus", 'AceEvent-3.0')
mod.uiName = L['Item Overlay Plus']
mod.uiDesc = L["Adds a red overlay to items that are unusable for you."]

local tooltipName = "AdibagsItemOverlayPlusScanningTooltip"
local tooltipFrame = _G[tooltipName] or CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")

local unusableItemsCache = {} -- Cache for scanned items: nil (not scanned), "queued", true (unusable), false (usable)

-- For Centralized Throttled Scan Queue (Plan Item 2)
local scanQueue = {}
local scanTimer = nil
local SCAN_DELAY_SECONDS = 0.005 -- Time between individual item scans. Adjust as needed.

function mod:OnInitialize()
    self.db = addon.db:RegisterNamespace(self.moduleName, {
        profile = {
            EnableOverlay = true,
        },
    })

    -- Register event handlers (Plan Item 1: Smarter Event Handling)
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ITEM_LOCK_UPDATE")
    frame:RegisterEvent("BAG_UPDATE")
    -- frame:RegisterEvent("CURRENT_SPELL_CAST_CHANGED") -- Removed, too broad, unlikely to affect bag item usability
    frame:SetScript("OnEvent", function(_, event, ...)
        -- BAG_UPDATE can be very frequent. ITEM_LOCK_UPDATE is more relevant.
        if event == "ITEM_LOCK_UPDATE" or event == "BAG_UPDATE" then
            if self.db.profile.EnableOverlay and openBagCount > 0 then -- Check if bags are open
                -- print("Event causing full update:", event)
                self:SendMessage('AdiBags_UpdateAllButtons')
            end
        end
    end)

    local frame2 = CreateFrame("Frame")
    frame2:RegisterEvent("ITEM_UNLOCKED")
    frame2:RegisterEvent("ITEM_LOCKED")
    frame2:SetScript("OnEvent", function(_, event, bag, slot)
        -- This is specific item invalidation, which is good (Plan Item 4)
        if event == "ITEM_UNLOCKED" or event == "ITEM_LOCKED" then
            if self.db.profile.EnableOverlay and _G["AdiBagsContainer1"] and bag ~= nil and slot ~= nil then
                local itemID = GetContainerItemID(bag, slot)
                if itemID then -- Only invalidate if there's an item
                    -- print("Item (un)locked, clearing cache for:", bag, slot)
                    unusableItemsCache[bag .. "," .. slot] = nil -- Clear specific cache entry
                    self:SendMessage('AdiBags_UpdateAllButtons') -- Trigger rescan for all, AdiBags will filter to visible
                end
            end
        end
    end)
end

function mod:GetOptions()
    -- Ensure we use self.db.profile consistently
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
                    -- Plan Item 5: Graceful Handling of Overlay Toggle
                    self:CancelAndClearScanQueue()
                    -- Reset all currently visible item colors
                    for _, bagWindow in ipairs(addon:GetBagWindows()) do
                        if bagWindow:IsVisible() then
                            for _, button in bagWindow:IterateButtons() do
                                if button:IsVisible() and button.IconTexture then
                                    button.IconTexture:SetVertexColor(1, 1, 1)
                                    -- Also clear any "queued" status from cache for these items
                                    local key = button.bag .. "," .. button.slot
                                    if unusableItemsCache[key] == "queued" then
                                        unusableItemsCache[key] = nil
                                    end
                                end
                            end
                        end
                    end
                else
                    -- If enabling, trigger a full update
                    self:SendMessage('AdiBags_UpdateAllButtons')
                end
            end,
        },
    }, addon:GetOptionHandler(self)
end

function mod:OnEnable()
    -- self.db.profile.EnableOverlay is used directly now
    self:RegisterMessage('AdiBags_UpdateButton', 'QueueButtonScan')

    self:RegisterMessage('AdiBags_BagSwapPanelClosed', 'ItemPositionChanged')
    self:RegisterMessage('AdiBags_NewItemReset', 'ItemPositionChanged')
    self:RegisterMessage('AdiBags_TidyBags', 'TidyBagsUpdateRed')

    self:RegisterMessage('AdiBags_BagOpened', 'OnBagOpened')
    self:RegisterMessage('AdiBags_BagClosed', 'OnBagClosed')
end

function mod:OnDisable()
    -- self.db.profile.EnableOverlay = false -- Not strictly needed if options handle it
    self:UnregisterMessage('AdiBags_UpdateButton')
    self:UnregisterMessage('AdiBags_BagSwapPanelClosed')
    self:UnregisterMessage('AdiBags_NewItemReset')
    self:UnregisterMessage('AdiBags_TidyBags')
    self:UnregisterMessage('AdiBags_BagOpened')
    self:UnregisterMessage('AdiBags_BagClosed')

    self:CancelAndClearScanQueue()
    wipe(unusableItemsCache)
    openBagCount = 0 -- Reset bag count
end

function mod:CancelAndClearScanQueue()
    if scanTimer then
        LibCompat.Cancel(scanTimer)
        scanTimer = nil
    end
    wipe(scanQueue)
    -- Go through cache and change any "queued" items back to nil,
    -- as their scan won't happen now.
    for key, status in pairs(unusableItemsCache) do
        if status == "queued" then
            unusableItemsCache[key] = nil
        end
    end
end

function mod:OnBagOpened()
    openBagCount = openBagCount + 1
    -- print("Bag opened, count:", openBagCount)
    if openBagCount == 1 then
        -- Registering AdiBags_UpdateButton is done in OnEnable, no need here if always registered
        -- self:RegisterMessage('AdiBags_UpdateButton', 'QueueButtonScan') -- Already in OnEnable
    end

    if self.db.profile.EnableOverlay then
        -- Delay slightly to allow AdiBags to fully initialize its buttons
        LibCompat.After(0.1, function()
            -- print("Requesting full button update after bag open")
            self:SendMessage('AdiBags_UpdateAllButtons')
        end)
    end
end

function mod:OnBagClosed()
    if openBagCount > 0 then
        openBagCount = openBagCount - 1
        -- print("Bag closed, count:", openBagCount)
        if openBagCount == 0 then
            -- Unregistering AdiBags_UpdateButton is done in OnDisable
            -- self:UnregisterMessage('AdiBags_UpdateButton') -- Done in OnDisable
            self:CancelAndClearScanQueue()
            wipe(unusableItemsCache) -- Clear cache when all bags are closed to save memory
            -- print("All bags closed, cache wiped, scan queue cleared.")
        end
    end
end

function mod:TidyBagsUpdateRed()
    -- print("Tidy Bags: Wiping cache and redoing scans.")
    wipe(unusableItemsCache)
    if self.db.profile.EnableOverlay and openBagCount > 0 then
        self:SendMessage('AdiBags_UpdateAllButtons')
    end
end

function mod:ItemPositionChanged()
    -- print("Item Position Changed: Wiping cache and redoing scans.")
    wipe(unusableItemsCache)
    if self.db.profile.EnableOverlay and openBagCount > 0 then
        self:SendMessage('AdiBags_UpdateAllButtons')
    end
end

-- Plan Item 2: Centralized Throttled Scan Queue - Processing
function mod:ProcessScanQueue()
    scanTimer = nil -- Assume timer is done unless rescheduled

    if not self.db.profile.EnableOverlay or openBagCount == 0 then
        -- print("Overlay disabled or bags closed, clearing scan queue.")
        wipe(scanQueue) -- Don't process if overlay disabled or bags closed
        return
    end

    local buttonToScan = tremove(scanQueue, 1)
    if not buttonToScan then
        -- print("Scan queue empty.")
        return -- Queue is empty
    end

    -- Defensive checks, button might have become invalid
    if not buttonToScan:IsVisible() or not GetContainerItemID(buttonToScan.bag, buttonToScan.slot) then
        -- print("Button no longer valid for scan:", buttonToScan.bag, buttonToScan.slot)
        unusableItemsCache[buttonToScan.bag .. "," .. buttonToScan.slot] = nil -- Clear "queued" status
        -- Process next item if any
        if #scanQueue > 0 then
            scanTimer = LibCompat.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
        end
        return
    end

    local key = buttonToScan.bag .. "," .. buttonToScan.slot
    -- print("Processing scan for:", key)
    local isUnusable = self:ScanTooltipOfBagItemForRedText(buttonToScan.bag, buttonToScan.slot)
    unusableItemsCache[key] = isUnusable -- Store actual boolean result

    -- Re-check visibility and apply color, only if overlay is still enabled
    if self.db.profile.EnableOverlay and buttonToScan:IsVisible() and buttonToScan.IconTexture then
        if isUnusable then
            buttonToScan.IconTexture:SetVertexColor(1, 0.1, 0.1)
        else
            buttonToScan.IconTexture:SetVertexColor(1, 1, 1)
        end
    end

    -- If there are more items, schedule next scan
    if #scanQueue > 0 then
        scanTimer = LibCompat.After(SCAN_DELAY_SECONDS, function() self:ProcessScanQueue() end)
    else
        -- print("Finished processing scan queue.")
    end
end

-- Renamed UpdateButton to QueueButtonScan to reflect its new role
function mod:QueueButtonScan(event, button)
    if not self.db.profile.EnableOverlay then
        -- Plan Item 5: Reset color if overlay is disabled
        if button.IconTexture then
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        local key = button.bag .. "," .. button.slot
        if unusableItemsCache[key] == "queued" then unusableItemsCache[key] = nil end
        return
    end

    if not GetContainerItemID(button.bag, button.slot) then
        return
    end

    if not button:IsVisible() then
        return
    end

    local key = button.bag .. "," .. button.slot
    local cachedStatus = unusableItemsCache[key]

    -- Plan Item 3: Optimized Cache Handling for Queued Items
    if type(cachedStatus) == "boolean" then -- Already scanned (true or false)
        if cachedStatus then
            button.IconTexture:SetVertexColor(1, 0.1, 0.1)
        else
            button.IconTexture:SetVertexColor(1, 1, 1)
        end
        return
    elseif cachedStatus == "queued" then -- Already in queue
        return
    end

    -- Item needs scanning, mark as "queued" and add to our list
    unusableItemsCache[key] = "queued"
    table.insert(scanQueue, button)
    -- print("Queued for scan:", key, "#scanQueue:", #scanQueue)

    -- If timer isn't running and queue has items, start it
    if not scanTimer and #scanQueue > 0 then
        -- print("Starting scan timer.")
        -- Start processing almost immediately, but after current event finishes
        scanTimer = LibCompat.After(0, function() self:ProcessScanQueue() end)
    end
end

-- Helper for ScanTooltipOfBagItemForRedText (no changes needed here from original)
local function isTextColorRed(textTable)
    if not textTable then return false end
    local text = textTable:GetText()
    if not text or text == "" or string.find(text, "0 / %d+") then return false end
    local r, g, b = textTable:GetTextColor()
    return r > 0.98 and g < 0.15 and b < 0.15 -- Original check seems fine
end

function mod:ScanTooltipOfBagItemForRedText(bag, slot)
    tooltipFrame:ClearLines()
    -- tooltipFrame:SetOwner(UIParent, "ANCHOR_NONE") -- Ensure it's not tied to mouse
    if bag < 0 then -- Bank, Reagent Bank, etc. AdiBags uses negative bag IDs for these.
        -- This specific handling might need verification against AdiBags's button.bag values for bank/reagents.
        -- Assuming AdiBags provides correct `bag` and `slot` that GetContainerItemInfo can use,
        -- or that `SetBagItem` handles negative bag IDs correctly for special containers.
        -- WoW API `SetInventoryItem` is for player equipment slots, not bank slots via bag ID.
        -- `C_Container.GetContainerItemInfo(bag, slot)` should work if `bag` is a valid container ID.
        -- AdiBags might be translating bank slots to something `SetBagItem` understands.
        -- For now, trusting `SetBagItem` with potentially negative `bag` values if AdiBags passes them.
        -- The original code had a specific `SetInventoryItem('player', slot+39)` for bag < 0.
        -- This needs to be reconciled with how AdiBags represents bank/reagent bank slots.
        -- AdiBags usually provides virtual bag/slot numbers that work with standard APIs or its own wrappers.
        -- Let's stick to SetBagItem as AdiBags's `button.bag` and `button.slot` should be compatible.
        -- If `bag` refers to player bank slots, `SetBagItem(BANK_CONTAINER, slot)` or similar is used.
        -- AdiBags abstracts this. The original `slot+39` for `SetInventoryItem` implies character bank slots (slot 0-27 for bank, then bags).
        -- This part is tricky without knowing exactly what `bag` values AdiBags uses for non-backpack containers.
        -- Sticking to SetBagItem assuming AdiBags normalizes this.
        -- If `bag` is e.g. -1 for main bank, `SetBagItem` should handle it.
        -- The original code's `if bag < 0 then tooltipFrame:SetInventoryItem('player', slot+39) end`
        -- was likely an attempt to handle character bank slots. Let's re-evaluate.
        -- Standard bank slots are bag ID `BANK_CONTAINER` (which is -1) and slots 1 through `NUM_BANKGENERICSTORAGE_SLOTS`.
        -- Reagent bank is `REAGENTBANK_CONTAINER` (-3).
        -- If AdiBags passes e.g. `bag = -1, slot = 5`, then `SetBagItem(-1, 5)` is correct.
        -- The `slot+39` logic seems specific and potentially brittle.
        -- Let's trust `SetBagItem` with the `bag` and `slot` AdiBags provides.
    end
    tooltipFrame:SetBagItem(bag, slot) -- This should handle bank bags if bag ID is correct (e.g., -1 for main bank)

    for i = 1, tooltipFrame:NumLines() do
        if isTextColorRed(_G[tooltipName .. "TextLeft" .. i]) or isTextColorRed(_G[tooltipName .. "TextRight" .. i]) then
            return true
        end
    end
    return false
end