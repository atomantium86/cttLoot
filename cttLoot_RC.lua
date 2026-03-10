-- cttLoot_RC.lua
-- RCLootCouncil integration:
--   • RCSessionChangedPost  → auto-filter cttLoot grid to the active session item
--   • RCMLAwardSuccess      → stamp winner name onto the awarded item's card header
-- All logic is gated behind RCLootCouncil existing — safe if RC is not installed.

cttLoot_RC = { trackEnabled = true }

-- ── Internal state ────────────────────────────────────────────────────────────
local activeSession   = nil
local awardedItems    = {}
local rcSnapEnabled   = true
local rcTrackEnabled  = true
local rcSessionActive = false  -- true only when RC opened cttLoot via a real session

-- ── Name matching ─────────────────────────────────────────────────────────────
-- Extract plain item name from an RC item link or name string.
-- RC loot table entries have a .name field (plain text) and a .link field.
local function StripLink(link)
    if not link then return nil end
    -- Try to extract from |Hitem:...|h[Name]|h
    local name = link:match("%[(.-)%]")
    if name then return name end
    return link  -- already plain text
end

-- Find the best matching item name in cttLoot's item list.
-- Returns the matched cttLoot item name, or nil if no match.
local function MatchItemName(rcName)
    if not rcName or #cttLoot.itemNames == 0 then return nil end
    local rcLower = rcName:lower()

    -- 1. Exact match (case-insensitive)
    for _, name in ipairs(cttLoot.itemNames) do
        if name:lower() == rcLower then return name end
    end

    -- 2. RC name contains cttLoot name (handles CATALYST suffix etc.)
    for _, name in ipairs(cttLoot.itemNames) do
        if rcLower:find(name:lower(), 1, true) then return name end
    end

    -- 3. cttLoot name contains RC name
    for _, name in ipairs(cttLoot.itemNames) do
        if name:lower():find(rcLower, 1, true) then return name end
    end

    return nil
end

-- ── Apply RC session filter ───────────────────────────────────────────────────
local function ApplyRCSessionFilter(session)
    if not RCLootCouncil then return end

    local lootTable = RCLootCouncil:GetLootTable()
    if not lootTable or not lootTable[session] then return end

    -- Build a filter list of ALL items in the current RC loot table
    -- so that when the user clicks back from a detail view they see
    -- only the items being voted on, not the full grid.
    local sessionItems = {}
    local seen = {}
    for _, entry in ipairs(lootTable) do
        local rcName = entry.name or StripLink(entry.link)
        if rcName then
            local matched = MatchItemName(rcName)
            if matched and not seen[matched] then
                seen[matched] = true
                table.insert(sessionItems, matched)
            end
        end
    end
    if #sessionItems > 0 then
        cttLoot_UI.lootFilter = sessionItems
    end

    -- Also zoom to the specific session item
    local entry   = lootTable[session]
    local rcName  = entry.name or StripLink(entry.link)
    if not rcName then return end

    local matched = MatchItemName(rcName)
    if matched then
        cttLoot_UI.selectedItem = matched
        if itemDdLabel then itemDdLabel:SetText(matched) end
        if itemClearBtn then itemClearBtn:Show() end
        cttLoot_UI:Refresh()
    else
        cttLoot_UI.selectedItem = nil
        cttLoot_UI:Refresh()
        cttLoot:Print(string.format("|cffff4444RC session %d: no sim data for '%s'|r", session, rcName))
    end

    activeSession = session
end

-- ── Winner annotation ─────────────────────────────────────────────────────────
-- Store awarded winner so PopulateGrid can stamp it onto the card.
function cttLoot_RC:GetWinner(itemName)
    if not itemName then return nil end
    return awardedItems[itemName:lower()]
end

local function OnAwardSuccess(_, session, winner, status, link)
    if not winner or not link then return end

    -- Ignore test_mode awards
    if status == "test_mode" then return end

    local rcName  = StripLink(link)
    local matched = MatchItemName(rcName)
    if not matched then return end

    -- Strip realm from winner name
    local shortName = winner:match("^([^%-]+)") or winner
    awardedItems[matched:lower()] = shortName

    cttLoot:Print(string.format("|cffffd700%s|r awarded to |cff00ff00%s|r", matched, shortName))
    cttLoot_UI:Refresh()
end

-- ── Clear awarded items when a new loot session starts ────────────────────────
local function OnLootTableReceived()
    awardedItems = {}
    activeSession = nil
    rcSessionActive = false
    cttLoot_UI.lootFilter   = nil
    cttLoot_UI.selectedItem = nil
end

-- ── Initialise ────────────────────────────────────────────────────────────────
function cttLoot_RC:Init()
    if not RCLootCouncil then return end  -- RC not installed, do nothing

    local RC = RCLootCouncil

    local pendingSession = nil
    local sessionTimer = nil
    RC:RegisterMessage("RCSessionChangedPost", function(_, session)
        if not rcTrackEnabled then return end
        if sessionTimer then
            sessionTimer:Cancel()
            sessionTimer = nil
        end
        pendingSession = session
        sessionTimer = C_Timer.NewTimer(0.15, function()
            sessionTimer = nil
            ApplyRCSessionFilter(pendingSession)
            pendingSession = nil
        end)
    end)

    RC:RegisterMessage("RCMLAwardSuccess", function(_, session, winner, status, link, responseText)
        if not rcTrackEnabled then return end
        OnAwardSuccess(_, session, winner, status, link)
    end)

    RC:RegisterMessage("RCLootTableAdditionsReceived", function()
        if not rcTrackEnabled then return end
        OnLootTableReceived()
    end)

    RC:RegisterMessage("RCLootTableHidden", function()
        if not rcTrackEnabled then return end
        if not rcSessionActive then return end
        rcSessionActive = false
        cttLoot_UI.lootFilter   = nil
        cttLoot_UI.selectedItem = nil
        cttLoot_UI:Close()
    end)

    local vf = RC:GetActiveModule("votingframe")
    if vf then
        local pendingOpen = false
        hooksecurefunc(vf, "ReceiveLootTable", function()
            if not rcTrackEnabled then return end
            if pendingOpen then return end
            pendingOpen = true
            C_Timer.After(0.1, function()
                pendingOpen = false
                rcSessionActive = true
                ApplyRCSessionFilter(1)
                cttLoot_UI:Open()
                if rcSnapEnabled then cttLoot_UI:SnapToRC() end
            end)
        end)
        hooksecurefunc(vf, "Show", function()
            if not rcSnapEnabled then return end
            C_Timer.After(0.05, function()
                cttLoot_UI:SnapToRC()
            end)
        end)
        hooksecurefunc(vf, "Hide", function()
            if not rcTrackEnabled then return end
            if not rcSessionActive then return end
            rcSessionActive = false
            activeSession = nil
            cttLoot_UI.lootFilter   = nil
            cttLoot_UI.selectedItem = nil
            cttLoot_UI:Close()
        end)
    end
end

-- ── Enable/disable RC snap via flag ──────────────────────────────────────────
function cttLoot_RC:SetSnapEnabled(val)
    rcSnapEnabled = val
end

function cttLoot_RC:IsEnabled()
    return rcSnapEnabled
end

function cttLoot_RC:SetEnabled(val)
    rcTrackEnabled = val
    self.trackEnabled = val
    if not val then
        awardedItems = {}
        activeSession = nil
        cttLoot_UI.lootFilter   = nil
        cttLoot_UI.selectedItem = nil
        cttLoot_UI:Refresh()
    end
end

function cttLoot_RC:Unhook()
    self:SetEnabled(false)
end
-- Usage: /cttloot rctest Augury of the Primal Flame
function cttLoot_RC:Test(itemName)
    if not itemName or itemName == "" then
        cttLoot:Print("Usage: /cttloot rctest <item name>")
        return
    end
    local matched = MatchItemName(itemName)
    if matched then
        cttLoot_UI.selectedItem = matched
        cttLoot_UI.lootFilter   = nil
        if itemDdLabel then itemDdLabel:SetText(matched) end
        if itemClearBtn then itemClearBtn:Show() end
        cttLoot_UI:Refresh()
        cttLoot:Print(string.format("RC test → |cffffd700%s|r", matched))
    else
        cttLoot:Print(string.format("RC test: no match for '%s'", itemName))
    end
end

-- ── Winner stamp accessor (called from MakeCard in cttLoot_UI.lua) ────────────
-- Returns the winner name string for a given item, or nil.
function cttLoot_RC.GetWinnerForItem(itemName)
    if not itemName then return nil end
    return awardedItems[itemName:lower()]
end
