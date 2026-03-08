-- cttLoot.lua
-- Core: data, TSV parsing, catalyst merging, network broadcast/receive

cttLoot = {}
cttLoot.VERSION    = 1          -- bump to force re-sync on breaking changes
cttLoot.PREFIX     = "cttLoot" -- addon message prefix (max 16 chars)
cttLoot.CHUNK_SIZE = 240        -- safe payload per SendAddonMessage call

-- Parsed data (populated after a paste + load, or received over network)
cttLoot.itemNames   = {}  -- array of base item names (catalyst already merged)
cttLoot.playerNames = {}  -- array of player names
cttLoot.matrix      = {}  -- matrix[playerIdx][itemIdx] = number | nil

-- ── Saved vars default ────────────────────────────────────────────────────────
local defaults = { lastTSV = "", customDB = {} }

-- ── Catalyst helpers ──────────────────────────────────────────────────────────
local function isCatalyst(name)
    return name:lower():find("catalyst") ~= nil
end

local function stripCatalyst(name)
    -- Remove "catalyst" with surrounding spaces/parens
    local result = name:gsub("%s*%(?%f[%a]catalyst%f[%A]%)?%s*", " ")
    result = result:gsub("%s+", " ")
    return result:match("^%s*(.-)%s*$") -- trim
end

-- ── TSV Parser ────────────────────────────────────────────────────────────────
-- Expected format:
--   Row 0 col 0: blank | Row 0 col 1+: item names
--   Row 1+ col 0: player name | col 1+: DPS delta values
function cttLoot:ParseTSV(raw)
    local lines = {}
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then
            lines[#lines + 1] = line
        end
    end

    if #lines < 2 then
        return nil, "Need at least a header row and one player row."
    end

    -- Parse header row → raw item names
    local headerCells = {}
    for cell in (lines[1] .. "\t"):gmatch("([^\t]*)\t") do
        headerCells[#headerCells + 1] = cell:match("^%s*(.-)%s*$")
    end
    local rawItemNames = {}
    for i = 2, #headerCells do
        if headerCells[i] ~= "" then
            rawItemNames[#rawItemNames + 1] = headerCells[i]
        end
    end

    -- Parse player rows
    local rawPlayerNames = {}
    local rawMatrix      = {}
    for r = 2, #lines do
        local cells = {}
        for cell in (lines[r] .. "\t"):gmatch("([^\t]*)\t") do
            cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
        end
        local player = cells[1] or ""
        if player ~= "" then
            rawPlayerNames[#rawPlayerNames + 1] = player
            local row = {}
            for i = 1, #rawItemNames do
                local val = cells[i + 1] or ""
                val = val:gsub(",", "")
                local n = tonumber(val)
                row[i] = n  -- nil if not a number
            end
            rawMatrix[#rawMatrix + 1] = row
        end
    end

    -- Merge catalyst columns into base name, keeping max per player
    local mergedOrder = {}
    local mergedMap   = {}  -- baseName -> { rawColIdx, ... }
    for i, name in ipairs(rawItemNames) do
        local base = isCatalyst(name) and stripCatalyst(name) or name
        if not mergedMap[base] then
            mergedMap[base] = {}
            mergedOrder[#mergedOrder + 1] = base
        end
        mergedMap[base][#mergedMap[base] + 1] = i
    end

    local finalMatrix = {}
    for r, row in ipairs(rawMatrix) do
        local merged = {}
        for _, base in ipairs(mergedOrder) do
            local best = nil
            for _, ci in ipairs(mergedMap[base]) do
                local v = row[ci]
                if v ~= nil then
                    if best == nil or v > best then best = v end
                end
            end
            merged[#merged + 1] = best
        end
        finalMatrix[r] = merged
    end

    return {
        itemNames   = mergedOrder,
        playerNames = rawPlayerNames,
        matrix      = finalMatrix,
    }
end

-- Apply parsed data to the live cttLoot tables
function cttLoot:ApplyData(data)
    self.itemNames   = data.itemNames
    self.playerNames = data.playerNames
    self.matrix      = data.matrix
end

-- ── Serialisation ─────────────────────────────────────────────────────────────
-- Wire format (single string):
--   VER|<version>
--   ITEMS|item1^item2^...
--   PLAYER|name|val1^val2^...   (one line per player; empty cell = "N")
--
-- We split this into numbered chunks and reassemble on the receiver.

local function Serialize(data)
    local parts = {}
    parts[#parts + 1] = "VER|" .. cttLoot.VERSION
    parts[#parts + 1] = "ITEMS|" .. table.concat(data.itemNames, "^")
    for r, player in ipairs(data.playerNames) do
        local vals = {}
        for _, v in ipairs(data.matrix[r]) do
            vals[#vals + 1] = v ~= nil and tostring(v) or "N"
        end
        parts[#parts + 1] = "PLAYER|" .. player .. "|" .. table.concat(vals, "^")
    end
    return table.concat(parts, "\n")
end

local function Deserialize(raw)
    local data = { itemNames = {}, playerNames = {}, matrix = {} }
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(1, 4) == "VER|" then
            -- version check (ignore for now, forward-compatible)
        elseif line:sub(1, 6) == "ITEMS|" then
            local items = line:sub(7)
            for item in (items .. "^"):gmatch("([^^]*)%^") do
                data.itemNames[#data.itemNames + 1] = item
            end
        elseif line:sub(1, 7) == "PLAYER|" then
            local rest  = line:sub(8)
            local sep   = rest:find("|")
            if sep then
                local player = rest:sub(1, sep - 1)
                local valStr = rest:sub(sep + 1)
                data.playerNames[#data.playerNames + 1] = player
                local row = {}
                for v in (valStr .. "^"):gmatch("([^^]*)%^") do
                    row[#row + 1] = v == "N" and nil or tonumber(v)
                end
                data.matrix[#data.matrix + 1] = row
            end
        end
    end
    return data
end

-- ── Network: send ─────────────────────────────────────────────────────────────
-- We chunk the serialised string and prefix each piece with "<idx>/<total>:"
function cttLoot:Broadcast(channel)
    channel = channel or (IsInRaid() and "RAID" or "PARTY")
    local payload = Serialize({ itemNames = self.itemNames, playerNames = self.playerNames, matrix = self.matrix })

    -- Split into chunks
    local chunks = {}
    local pos    = 1
    while pos <= #payload do
        chunks[#chunks + 1] = payload:sub(pos, pos + self.CHUNK_SIZE - 1)
        pos = pos + self.CHUNK_SIZE
    end

    local total = #chunks
    for i, chunk in ipairs(chunks) do
        local msg = i .. "/" .. total .. ":" .. chunk
        C_ChatInfo.SendAddonMessage(self.PREFIX, msg, channel)
    end

    self:Print(string.format("Broadcast %d items × %d players to %s in %d chunk(s).",
        #self.itemNames, #self.playerNames, channel, total))
end

-- Serialize the item DB into a string for broadcast
local function SerializeDB()
    local lines = { "DBVER|1" }
    for id, entry in pairs(cttLoot.DB) do
        if entry.name and entry.boss then
            lines[#lines + 1] = "DBENTRY|" .. id .. "|" .. entry.name .. "|" .. entry.boss .. "|" .. (entry.raid or "The Voidspire")
        end
    end
    return table.concat(lines, "\n")
end

local function DeserializeDB(raw)
    local entries = {}
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(1, 8) == "DBENTRY|" then
            local rest = line:sub(9)
            local id, name, boss, raid = rest:match("^(%d+)|([^|]+)|([^|]+)|(.+)$")
            id = tonumber(id)
            if id and name and boss then
                entries[id] = { name = name, boss = boss, raid = raid or "The Voidspire" }
            end
        end
    end
    return entries
end

function cttLoot:BroadcastDB(channel)
    channel = channel or (IsInRaid() and "RAID" or "PARTY")
    local count = 0
    for _ in pairs(self.DB) do count = count + 1 end
    if count == 0 then self:Print("Item DB is empty — nothing to send."); return end

    local payload = SerializeDB()
    local chunks  = {}
    local pos     = 1
    while pos <= #payload do
        chunks[#chunks + 1] = payload:sub(pos, pos + self.CHUNK_SIZE - 1)
        pos = pos + self.CHUNK_SIZE
    end

    local total = #chunks
    for i, chunk in ipairs(chunks) do
        local msg = "DB:" .. i .. "/" .. total .. ":" .. chunk
        C_ChatInfo.SendAddonMessage(self.PREFIX, msg, channel)
    end

    self:Print(string.format("Sent item DB (%d entries) to %s in %d chunk(s).", count, channel, total))
end

-- ── Network: receive ──────────────────────────────────────────────────────────
local inboundBuffers   = {}  -- [sender] = { total=N, received=0, chunks={} }
local inboundDBBuffers = {}  -- [sender] = { total=N, received=0, chunks={} }

local function OnAddonMessage(_, prefix, message, _, sender)
    if prefix ~= cttLoot.PREFIX then return end
    if sender == UnitName("player") then return end

    -- DB broadcast: "DB:idx/total:data"
    if message:sub(1, 3) == "DB:" then
        local idx, total, data = message:match("^DB:(%d+)/(%d+):(.*)$")
        idx   = tonumber(idx)
        total = tonumber(total)
        if not idx or not total then return end

        if not inboundDBBuffers[sender] or inboundDBBuffers[sender].total ~= total then
            inboundDBBuffers[sender] = { total = total, received = 0, chunks = {} }
        end
        local buf = inboundDBBuffers[sender]
        buf.chunks[idx] = data
        buf.received    = buf.received + 1

        if buf.received == total then
            local fullPayload = table.concat(buf.chunks)
            inboundDBBuffers[sender] = nil
            local entries = DeserializeDB(fullPayload)
            local count = 0
            for id, entry in pairs(entries) do
                cttLoot.DB[id] = entry
                cttLootDB.customDB[id] = entry
                count = count + 1
            end
            cttLoot:MergeCustomDB()
            cttLoot_UI:PopulateBossDropdown()
            cttLoot:Print(string.format("Received item DB from %s: %d entries added.", sender, count))
        end
        return
    end

    -- TSV broadcast: "idx/total:data"
    local idx, total, data = message:match("^(%d+)/(%d+):(.*)$")
    idx   = tonumber(idx)
    total = tonumber(total)
    if not idx or not total then return end

    if not inboundBuffers[sender] or inboundBuffers[sender].total ~= total then
        inboundBuffers[sender] = { total = total, received = 0, chunks = {} }
    end
    local buf = inboundBuffers[sender]
    buf.chunks[idx] = data
    buf.received    = buf.received + 1

    if buf.received == total then
        local assembled = {}
        for i = 1, total do assembled[i] = buf.chunks[i] or "" end
        local fullPayload = table.concat(assembled)
        inboundBuffers[sender] = nil

        local parsed = Deserialize(fullPayload)
        cttLoot:ApplyData(parsed)
        cttLoot:Print(string.format("Received data from %s: %d items × %d players.",
            sender, #parsed.itemNames, #parsed.playerNames))
        cttLoot_UI:Refresh()
    end
end

-- ── Slash commands ────────────────────────────────────────────────────────────
local function SlashHandler(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")
    if msg == "" or msg == "show" then
        cttLoot_UI:Toggle()
    elseif msg == "send" then
        if #cttLoot.itemNames == 0 then
            cttLoot:Print("No data loaded. Paste TSV first.")
        else
            cttLoot:Broadcast()
        end
    elseif msg == "help" then
        cttLoot:Print("/il show  — open/close window")
        cttLoot:Print("/il send  — broadcast data to raid/party")
    end
end

SLASH_ITEMLENS1 = "/itemlens"
SLASH_ITEMLENS2 = "/il"
SlashCmdList["ITEMLENS"] = SlashHandler

-- ── Print helper ─────────────────────────────────────────────────────────────
function cttLoot:Print(msg)
    print("|cffC8A84B[cttLoot]|r " .. tostring(msg))
end

-- ── Encounter & loot tracking ────────────────────────────────────────────────
-- lastKilledBoss is set on ENCOUNTER_END (success only).
-- When LOOT_OPENED fires, if we have a matching boss in the DB and TSV data is
-- loaded, we auto-set the boss filter and open the cttLoot window.

cttLoot.lastKilledBoss    = nil  -- boss name string from ENCOUNTER_END
cttLoot.lastKilledEncounterId = nil

local function OnEncounterEnd(encounterId, encounterName, _, _, success)
    if success ~= 1 then return end  -- wipe, ignore
    cttLoot.lastKilledBoss        = encounterName
    cttLoot.lastKilledEncounterId = encounterId
    cttLoot:Print(string.format("Boss killed: %s (id %d)", encounterName, encounterId))
end

local function OnLootOpened()
    -- Only act if TSV data is loaded
    if #cttLoot.playerNames == 0 then return end
    if not cttLoot.lastKilledBoss then return end

    -- Find a matching boss name in the DB (case-insensitive partial match)
    local killedLower = cttLoot.lastKilledBoss:lower()
    local matchedBoss = nil

    for _, entry in pairs(cttLoot.DB) do
        if entry.boss and entry.boss:lower() == killedLower then
            matchedBoss = entry.boss; break
        end
    end
    if not matchedBoss then
        for _, entry in pairs(cttLoot.DB) do
            if entry.boss then
                local bossLower = entry.boss:lower()
                if bossLower:find(killedLower, 1, true) or killedLower:find(bossLower, 1, true) then
                    matchedBoss = entry.boss; break
                end
            end
        end
    end
    if not matchedBoss then return end

    -- Scan the loot window for actual item IDs that dropped
    local lootedNames = {}
    local numSlots = GetNumLootItems and GetNumLootItems() or 0
    for i = 1, numSlots do
        local itemLink = GetLootSlotLink and GetLootSlotLink(i)
        if itemLink then
            local itemId = tonumber(itemLink:match("item:(%d+)"))
            if itemId and cttLoot.DB[itemId] then
                local name = cttLoot.DB[itemId].name
                -- Only include if this item is in the loaded TSV
                for _, tsvName in ipairs(cttLoot.itemNames) do
                    if tsvName:lower() == name:lower() then
                        lootedNames[name] = true
                        break
                    end
                end
            end
        end
    end

    -- Build ordered list of looted item names that exist in TSV
    local filtered = {}
    for _, name in ipairs(cttLoot.itemNames) do
        if lootedNames[name] then
            filtered[#filtered + 1] = name
        end
    end

    if #filtered == 0 then
        -- Fall back to showing all boss items if nothing matched by ID
        local bossItemsInTSV = cttLoot_UI:GetVisibleItemsForBoss(matchedBoss)
        if #bossItemsInTSV == 0 then
            cttLoot:Print(string.format("%s loot detected but no matching items in TSV.", matchedBoss))
            return
        end
        cttLoot:Print(string.format("Auto-showing all %d items for %s.", #bossItemsInTSV, matchedBoss))
        cttLoot_UI:SetBossFilter(matchedBoss)
        cttLoot_UI:SetLootFilter(nil)
    else
        cttLoot:Print(string.format("Showing %d looted item(s) from %s.", #filtered, matchedBoss))
        cttLoot_UI:SetBossFilter(matchedBoss)
        cttLoot_UI:SetLootFilter(filtered)
    end

    if not cttLoot_UI:IsWindowShown() then
        cttLoot_UI:Toggle()
    else
        cttLoot_UI:Refresh()
    end
end

-- ── Addon lifecycle ───────────────────────────────────────────────────────────
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("LOOT_OPENED")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "cttLoot" then
            -- Init saved vars
            cttLootDB = cttLootDB or CopyTable(defaults)
            if cttLootDB.customDB == nil then cttLootDB.customDB = {} end
            -- Merge any previously imported DB entries
            cttLoot:MergeCustomDB()
            -- Register addon message prefix
            C_ChatInfo.RegisterAddonMessagePrefix(cttLoot.PREFIX)
            cttLoot:Print("Loaded. Type /il for commands.")
        end
    elseif event == "PLAYER_LOGIN" then
        -- Auto-load saved TSV so data is ready without clicking Load Data
        if cttLootDB and cttLootDB.lastTSV and cttLootDB.lastTSV ~= "" then
            local data, err = cttLoot:ParseTSV(cttLootDB.lastTSV)
            if data then
                cttLoot:ApplyData(data)
                cttLoot:Print("TSV data restored from last session.")
            else
                cttLoot:Print("Could not restore TSV: " .. (err or "unknown error"))
            end
        end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(_, ...)
    elseif event == "ENCOUNTER_END" then
        OnEncounterEnd(...)
    elseif event == "LOOT_OPENED" then
        OnLootOpened()
    end
end)
