-- cttLoot_RC.lua
-- RCLootCouncil integration.
--
-- LAYER CONTRACT
-- This module communicates with cttLoot_UI ONLY through its public methods:
--   cttLoot_UI:SetSelectedItem(name)   cttLoot_UI:SetLootFilter(names)
--   cttLoot_UI:SetBossFilter(name)     cttLoot_UI:Open()
--   cttLoot_UI:Close()                 cttLoot_UI:Refresh()
--   cttLoot_UI:SnapToRC()              cttLoot_UI:ReleaseSnap()
--   cttLoot_UI:ResetAwardFilter()
--
-- Award state lives entirely inside this module.
-- cttLoot_UI reads winner data through cttLoot:GetWinnerForItem() — NOT directly from RC.
-- cttLoot_UI NEVER accesses cttLoot_RC fields or locals.

cttLoot_RC = { trackEnabled = true }

-- ── Internal state ────────────────────────────────────────────────────────────
local activeSession   = nil
local awardedItems    = {}   -- { [itemName:lower()] = { winner1, winner2, ... } }
local rcSnapEnabled   = true
local rcTrackEnabled  = true
local rcSessionActive = false

-- ── Name matching ─────────────────────────────────────────────────────────────
local function StripLink(link)
    if not link then return nil end
    local name = link:match("%[(.-)%]")
    if name then return name end
    return link
end

local function MatchItemName(rcName)
    if not rcName or #cttLoot.itemNames == 0 then return nil end
    local rcLower = rcName:lower()

    -- 1. O(1) exact match via cached lowercase lookup
    local exact = cttLoot.itemIndexLower[rcLower]
    if exact then return exact end

    -- 2. RC name contains cttLoot name (uses pre-lowered array)
    local namesLower = cttLoot.itemNamesLower
    for i, nameLower in ipairs(namesLower) do
        if rcLower:find(nameLower, 1, true) then return cttLoot.itemNames[i] end
    end
    -- 3. cttLoot name contains RC name
    for i, nameLower in ipairs(namesLower) do
        if nameLower:find(rcLower, 1, true) then return cttLoot.itemNames[i] end
    end
    return nil
end

-- ── Apply RC session filter via public UI API only ────────────────────────────
local function ApplyRCSessionFilter(session)
    if not RCLootCouncil then return end
    if #cttLoot.itemNames == 0 then return end

    local lootTable = RCLootCouncil:GetLootTable()
    if not lootTable or not lootTable[session] then return end

    -- Build loot filter for all items in this RC loot table
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

    -- SetLootFilter also clears selectedItem internally — use public API
    if #sessionItems > 0 then
        cttLoot_UI:SetLootFilter(sessionItems)
    end

    -- Zoom to the specific session item
    local entry  = lootTable[session]
    local rcName = entry.name or StripLink(entry.link)
    if not rcName then
        cttLoot_UI:Refresh()
        return
    end

    local matched = MatchItemName(rcName)
    if matched then
        cttLoot_UI:SetSelectedItem(matched)
        cttLoot_UI:Refresh()
    else
        cttLoot_UI:SetSelectedItem(nil)
        cttLoot_UI:Refresh()
        cttLoot:Print(string.format("|cffff4444RC session %d: no sim data for '%s'|r", session, rcName))
    end

    activeSession = session
end

-- ── Winner data ───────────────────────────────────────────────────────────────
local function AddWinner(itemKey, name)
    if not awardedItems[itemKey] then awardedItems[itemKey] = {} end
    for _, v in ipairs(awardedItems[itemKey]) do
        if v == name then return end
    end
    table.insert(awardedItems[itemKey], name)
    -- Persist so the muted-color state survives /reload
    if cttLootDB then cttLootDB.awardedItems = awardedItems end
    -- Signal UI to rebuild awardedSet on next Refresh
    if cttLoot_UI and cttLoot_UI.MarkAwardsDirty then cttLoot_UI.MarkAwardsDirty() end
end

-- Returns a set { ["PlayerName"] = true } of every player who received an
-- award this session, regardless of which item.  Called via cttLoot facade.
function cttLoot_RC.GetAwardedPlayers()
    local set = {}
    for _, winners in pairs(awardedItems) do
        for _, name in ipairs(winners) do
            set[name] = true
        end
    end
    return set
end

-- Read-only accessor called by cttLoot:GetWinnerForItem() facade.
-- cttLoot_UI never calls this directly.
function cttLoot_RC.GetWinnerForItem(itemName)
    if not itemName then return nil end
    local list = awardedItems[itemName:lower()]
    if not list or #list == 0 then return nil end
    return table.concat(list, ", ")
end

-- ── Award handling ────────────────────────────────────────────────────────────
local function OnAwardSuccess(_, session, winner, status, link)
    if not winner or not link then return end
    if status == "test_mode" then return end

    local rcName  = StripLink(link)
    local matched = MatchItemName(rcName)
    if not matched then return end

    local shortName = winner:match("^([^%-]+)") or winner
    AddWinner(matched:lower(), shortName)

    -- Record to history with frozen sim snapshot
    if cttLoot_History then cttLoot_History:RecordAward(matched, shortName) end

    cttLoot:Print(string.format("|cffffd700%s|r awarded to |cff00ff00%s|r", matched, shortName))
    cttLoot_UI:Refresh()

    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        C_ChatInfo.SendAddonMessage(cttLoot.PREFIX, "AWARD:" .. matched .. "\t" .. shortName, channel)
    end
end

local function OnAwardReceived(itemName, winner)
    if not itemName or not winner then return end
    local matched = MatchItemName(itemName)
    if not matched then return end
    -- Only record if not already in history (ML already recorded via OnAwardSuccess)
    -- Non-ML members record here since they don't fire RCMLAwardSuccess
    if cttLoot_History and not cttLoot_RC._isMasterLooter then
        cttLoot_History:RecordAward(matched, winner)
    end
    AddWinner(matched:lower(), winner)
    cttLoot_UI:Refresh()
end

function cttLoot_RC.HandleMessage(message)
    if message:sub(1, 6) == "AWARD:" then
        local payload = message:sub(7)
        local itemName, winner = payload:match("^(.+)\t(.+)$")
        OnAwardReceived(itemName, winner)
        return true
    end
    return false
end

-- ── Session lifecycle ─────────────────────────────────────────────────────────
local function OnLootTableReceived()
    activeSession   = nil
    rcSessionActive = false
    cttLoot_UI:SetLootFilter(nil)
    cttLoot_UI:SetSelectedItem(nil)
end

local function OnSessionEnd()
    if not rcSessionActive then return end
    rcSessionActive = false
    activeSession   = nil
    cttLoot_UI:SetLootFilter(nil)
    cttLoot_UI:SetSelectedItem(nil)
    cttLoot_UI:ReleaseSnap()
    cttLoot_UI:Close()
end

function cttLoot_RC.ClearAwards()
    awardedItems = {}
    if cttLootDB then cttLootDB.awardedItems = nil end
    if cttLoot_UI and cttLoot_UI.MarkAwardsDirty then cttLoot_UI.MarkAwardsDirty() end
    if cttLoot_UI and cttLoot_UI.ResetAwardFilter then cttLoot_UI:ResetAwardFilter() end
    if cttLoot_UI and cttLoot_UI.Refresh          then cttLoot_UI:Refresh() end
end

-- ── Initialise ────────────────────────────────────────────────────────────────
function cttLoot_RC:Init()
    if not RCLootCouncil then return end

    -- Restore persisted award state so muted colors survive /reload.
    -- ClearAwards (fired on new import) wipes cttLootDB.awardedItems,
    -- so this never outlasts a fresh paste.
    if cttLootDB and cttLootDB.awardedItems then
        awardedItems = cttLootDB.awardedItems
        -- BuildAwardedSet already ran at login before this 1-second delay,
        -- so we need a fresh Refresh to pick up the restored state.
        if cttLoot_UI and cttLoot_UI.Refresh then cttLoot_UI:Refresh() end
    end

    local RC            = RCLootCouncil
    local pendingSession = nil
    local sessionTimer  = nil

    RC:RegisterMessage("RCSessionChangedPost", function(_, session)
        if not rcTrackEnabled then return end
        if sessionTimer then sessionTimer:Cancel(); sessionTimer = nil end
        pendingSession = session
        sessionTimer = C_Timer.NewTimer(0.15, function()
            sessionTimer = nil
            ApplyRCSessionFilter(pendingSession)
            pendingSession = nil
        end)
    end)

    RC:RegisterMessage("RCMLAwardSuccess", function(_, session, winner, status, link)
        if not rcTrackEnabled then return end
        OnAwardSuccess(_, session, winner, status, link)
    end)

    RC:RegisterMessage("RCLootTableAdditionsReceived", function()
        if not rcTrackEnabled then return end
        OnLootTableReceived()
    end)

    RC:RegisterMessage("RCLootTableHidden", function()
        if not rcTrackEnabled then return end
        OnSessionEnd()
    end)

    local vf = RC:GetActiveModule("votingframe")
    if vf then
        local pendingOpen = false
        hooksecurefunc(vf, "ReceiveLootTable", function()
            if not rcTrackEnabled then return end
            if pendingOpen then return end
            pendingOpen = true
            C_Timer.After(0.1, function()
                pendingOpen     = false
                rcSessionActive = true
                ApplyRCSessionFilter(1)
                cttLoot_UI:Open()
                if rcSnapEnabled then cttLoot_UI:SnapToRC() end
            end)
        end)
        hooksecurefunc(vf, "Show", function()
            if not rcSnapEnabled then return end
            C_Timer.After(0.05, function() cttLoot_UI:SnapToRC() end)
        end)
        hooksecurefunc(vf, "Hide", function()
            if not rcTrackEnabled then return end
            OnSessionEnd()
        end)
    end
end

-- ── Enable / disable ──────────────────────────────────────────────────────────
function cttLoot_RC:SetSnapEnabled(val) rcSnapEnabled = val end
function cttLoot_RC:IsEnabled()         return rcSnapEnabled end
function cttLoot_RC:IsSessionActive()   return rcSessionActive end

function cttLoot_RC:SetEnabled(val)
    rcTrackEnabled    = val
    self.trackEnabled = val
    if not val then
        awardedItems  = {}
        activeSession = nil
        if cttLootDB then cttLootDB.awardedItems = nil end
        if cttLoot_UI and cttLoot_UI.MarkAwardsDirty then cttLoot_UI.MarkAwardsDirty() end
        cttLoot_UI:SetLootFilter(nil)
        cttLoot_UI:SetSelectedItem(nil)
        cttLoot_UI:Refresh()
    end
end

function cttLoot_RC:Unhook() self:SetEnabled(false) end

-- ── Debug / test ──────────────────────────────────────────────────────────────
function cttLoot_RC:Test(itemName)
    if not itemName or itemName == "" then
        cttLoot:Print("Usage: /cttloot rctest <item name>"); return
    end
    local matched = MatchItemName(itemName)
    if matched then
        cttLoot_UI:SetLootFilter(nil)
        cttLoot_UI:SetSelectedItem(matched)
        cttLoot_UI:Refresh()
        cttLoot:Print(string.format("RC test → |cffffd700%s|r", matched))
    else
        cttLoot:Print(string.format("RC test: no match for '%s'", itemName))
    end
end
