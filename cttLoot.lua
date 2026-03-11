-- cttLoot.lua
-- Core: data, CSV parsing, network broadcast/receive
--
-- Midnight Secret Value compliance:
--   • GetLootSlotLink returns a Secret in instances — we pass it opaquely to
--     C_Item.GetItemIDFromItemLink (which accepts Secrets) and never inspect
--     the link string itself.
--   • ENCOUNTER_END: encounterName is Secret in instances. We store only
--     encounterId (numeric, non-secret) and resolve boss names from our own DB.
--   • All UI manipulation originating from combat events is deferred to
--     PLAYER_REGEN_ENABLED when InCombatLockdown() is true.
--   • C_ChatInfo.SendAddonMessage is blocked in instances; guarded with
--     C_ChatInfo.InChatMessagingLockdown().
--   • Addon message payloads are Secret in instances; we discard them when
--     InChatMessagingLockdown() is active rather than attempt to read Secrets.

cttLoot = {}
cttLoot.VERSION    = 1
cttLoot.loopback   = false
cttLoot.PREFIX     = "cttLoot"
cttLoot.CHUNK_SIZE = 240

cttLoot.itemNames   = {}
cttLoot.playerNames = {}
cttLoot.matrix      = {}
cttLoot.itemIndex   = {}
cttLoot.playerIndex = {}

-- ── Saved vars default ────────────────────────────────────────────────────────
local defaults = { customDB = {}, lastData = nil, windowX = nil, windowY = nil, windowW = nil, windowH = nil, windowPoint = nil, windowRelPoint = nil }
-- lastData = { itemNames={}, playerNames={}, matrix={} } stored directly

-- ── Deferred action queue ─────────────────────────────────────────────────────
-- Any action that touches the UI and originates from a combat event is pushed
-- here and executed on PLAYER_REGEN_ENABLED (combat end).
local pendingActions = {}

local function DeferAction(fn)
    pendingActions[#pendingActions + 1] = fn
end

local function FlushPendingActions()
    for _, fn in ipairs(pendingActions) do
        pcall(fn)
    end
    pendingActions = {}
end

-- ── CSV row splitter (handles quoted fields with embedded commas) ─────────────
local function splitRow(line, delim)
    if delim == "\t" then
        -- TSV: no quoting, just split on tabs
        local cells = {}
        for cell in (line .. "\t"):gmatch("([^\t]*)\t") do
            cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
        end
        return cells
    end
    -- CSV: proper quoted-field parser
    local cells = {}
    local i = 1
    local len = #line
    while i <= len + 1 do
        if i > len then
            cells[#cells + 1] = ""
            break
        end
        if line:sub(i, i) == '"' then
            -- Quoted field
            local val = ""
            i = i + 1
            while i <= len do
                local c = line:sub(i, i)
                if c == '"' then
                    if line:sub(i + 1, i + 1) == '"' then
                        val = val .. '"'; i = i + 2
                    else
                        i = i + 1; break
                    end
                else
                    val = val .. c; i = i + 1
                end
            end
            cells[#cells + 1] = val
            if line:sub(i, i) == "," then i = i + 1 end
        else
            -- Unquoted field
            local j = line:find(",", i, true)
            if j then
                cells[#cells + 1] = line:sub(i, j - 1):match("^%s*(.-)%s*$")
                i = j + 1
            else
                cells[#cells + 1] = line:sub(i):match("^%s*(.-)%s*$")
                i = len + 2
            end
        end
    end
    return cells
end

-- ── CSV Parser ────────────────────────────────────────────────────────────
function cttLoot:ParseCSV(raw)
    -- Normalise line endings (Windows \r\n, old Mac \r)
    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")

    local lines = {}
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then lines[#lines + 1] = line end
    end

    if #lines < 2 then
        return nil, "Need at least a header row and one data row."
    end

    local delim = lines[1]:find("\t") and "\t" or ","

    -- Layout: row 1 col A = empty, cols B+ = player names
    --         rows 2+  col A = item name, cols B+ = delta values
    local headerCells = splitRow(lines[1], delim)
    local rawPlayerNames, rawPlayerIdxs = {}, {}
    for i = 2, #headerCells do
        if headerCells[i] ~= "" then
            local name = headerCells[i]
            name = name:sub(1,1):upper() .. name:sub(2)
            rawPlayerNames[#rawPlayerNames + 1] = name
            rawPlayerIdxs[#rawPlayerIdxs + 1] = i
        end
    end

    local rawItemNames = {}
    local rawMatrix = {}
    for p = 1, #rawPlayerNames do rawMatrix[p] = {} end

    for r = 2, #lines do
        local cells = splitRow(lines[r], delim)
        local itemName = cells[1] or ""
        if itemName ~= "" then
            local itemIdx = #rawItemNames + 1
            rawItemNames[itemIdx] = itemName
            for p, origCol in ipairs(rawPlayerIdxs) do
                local val = (cells[origCol] or ""):gsub(",", ""):gsub("^%+", "")
                rawMatrix[p][itemIdx] = tonumber(val)
            end
        end
    end

    return { itemNames = rawItemNames, playerNames = rawPlayerNames, matrix = rawMatrix }
end

function cttLoot:ApplyData(data)
    self.itemNames   = data.itemNames
    -- Ensure all player names have first letter capitalized regardless of source
    for i, name in ipairs(data.playerNames) do
        data.playerNames[i] = name:sub(1,1):upper() .. name:sub(2)
    end
    self.playerNames = data.playerNames
    self.matrix      = data.matrix
    -- Build reverse lookup tables for O(1) name->index access
    self.itemIndex   = {}
    self.playerIndex = {}
    for i, v in ipairs(self.itemNames)   do self.itemIndex[v]   = i end
    for i, v in ipairs(self.playerNames) do self.playerIndex[v] = i end
    -- Notify listeners that data has changed
    if self.onDataApplied then self.onDataApplied() end
    -- Clear awarded stamps — they belong to the previous parse session
    if cttLoot_RC and cttLoot_RC.ClearAwards then
        cttLoot_RC.ClearAwards()
    end
end

-- ── Serialisation ─────────────────────────────────────────────────────────────
local SEP = "\031"  -- ASCII unit separator — safe in addon messages, never in item/player names

local function Serialize(data)
    local parts = {}
    parts[#parts + 1] = "VER|" .. cttLoot.VERSION
    parts[#parts + 1] = "ITEMS|" .. table.concat(data.itemNames, "^")
    local numItems = #data.itemNames
    for r, player in ipairs(data.playerNames) do
        local vals = {}
        local row = data.matrix[r] or {}
        for i = 1, numItems do
            vals[i] = row[i] ~= nil and tostring(row[i]) or "N"
        end
        parts[#parts + 1] = "PLAYER|" .. player .. "|" .. table.concat(vals, "^")
    end
    return table.concat(parts, SEP)
end

local function Deserialize(raw)
    local data = { itemNames = {}, playerNames = {}, matrix = {} }
    for line in (raw .. SEP):gmatch("([^" .. SEP .. "]*)" .. SEP) do
        if line:sub(1, 6) == "ITEMS|" then
            for item in (line:sub(7) .. "^"):gmatch("([^^]*)%^") do
                data.itemNames[#data.itemNames + 1] = item
            end
        elseif line:sub(1, 7) == "PLAYER|" then
            local rest = line:sub(8)
            local sep  = rest:find("|")
            if sep then
                local player = rest:sub(1, sep - 1)
                player = player:sub(1,1):upper() .. player:sub(2)
                local valStr = rest:sub(sep + 1)
                data.playerNames[#data.playerNames + 1] = player
                local row = {}
                local col = 0
                for v in (valStr .. "^"):gmatch("([^^]*)%^") do
                    col = col + 1
                    if v ~= "N" then row[col] = tonumber(v) end
                end
                data.matrix[#data.matrix + 1] = row
            end
        end
    end
    return data
end

-- ── Network: send ─────────────────────────────────────────────────────────────
-- Midnight: C_ChatInfo.SendAddonMessage is blocked while in an instance.
-- Guard every send with InChatMessagingLockdown().
local function SafeSendAddonMessage(prefix, msg, channel, target)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        cttLoot:Print("Cannot send: addon messaging is restricted while in an instance.")
        return false
    end
    C_ChatInfo.SendAddonMessage(prefix, msg, channel, target)
    return true
end

function cttLoot:Broadcast(channel)
    if not channel then
        if IsInRaid() then channel = "RAID"
        elseif IsInGroup() then channel = "PARTY"
        else channel = "WHISPER" end
    end
    local target = channel == "WHISPER" and UnitName("player") or nil
    local payload = Serialize({ itemNames = self.itemNames, playerNames = self.playerNames, matrix = self.matrix })
    cttLoot:Print(string.format("Serialized payload: %d bytes, %d chunks", #payload, math.ceil(#payload / self.CHUNK_SIZE)))

    local chunks, pos = {}, 1
    while pos <= #payload do
        chunks[#chunks + 1] = payload:sub(pos, pos + self.CHUNK_SIZE - 1)
        pos = pos + self.CHUNK_SIZE
    end

    local total = #chunks
    local i = 1
    local ticker
    ticker = C_Timer.NewTicker(0.1, function()
        if i > total then
            ticker:Cancel()
            cttLoot:Print(string.format("Broadcast %d items × %d players to %s in %d chunk(s).",
                cttLoot.itemNames and #cttLoot.itemNames or 0, cttLoot.playerNames and #cttLoot.playerNames or 0, channel, total))
            return
        end
        SafeSendAddonMessage(cttLoot.PREFIX, i .. "/" .. total .. ":" .. chunks[i], channel, target)
        i = i + 1
    end)
end

local function SerializeDB()
    local lines = { "DBVER|1" }
    for id, entry in pairs(cttLoot.DB) do
        if entry.name and entry.boss then
            lines[#lines + 1] = "DBENTRY|" .. id .. "|" .. entry.name .. "|" .. entry.boss
        end
    end
    return table.concat(lines, SEP)
end

local function DeserializeDB(raw)
    local entries = {}
    for line in (raw .. SEP):gmatch("([^" .. SEP .. "]*)" .. SEP) do
        if line:sub(1, 8) == "DBENTRY|" then
            local rest = line:sub(9)
            local id, name, boss = rest:match("^(%d+)|([^|]+)|(.+)$")
            id = tonumber(id)
            if id and name and boss then
                entries[id] = { name = name, boss = boss }
            end
        end
    end
    return entries
end

function cttLoot:BroadcastDB(channel)
    if not channel then
        if IsInRaid() then channel = "RAID"
        elseif IsInGroup() then channel = "PARTY"
        else channel = "WHISPER" end
    end
    local target = channel == "WHISPER" and UnitName("player") or nil
    local count = 0
    for _ in pairs(self.DB) do count = count + 1 end
    if count == 0 then self:Print("Item DB is empty — nothing to send."); return end

    local payload  = SerializeDB()
    local chunks, pos = {}, 1
    while pos <= #payload do
        chunks[#chunks + 1] = payload:sub(pos, pos + self.CHUNK_SIZE - 1)
        pos = pos + self.CHUNK_SIZE
    end

    local total = #chunks
    local i = 1
    local ticker
    ticker = C_Timer.NewTicker(0.1, function()
        if i > total then
            ticker:Cancel()
            cttLoot:Print(string.format("Sent item DB (%d entries) to %s in %d chunk(s).", count, channel, total))
            return
        end
        SafeSendAddonMessage(cttLoot.PREFIX, "DB:" .. i .. "/" .. total .. ":" .. chunks[i], channel, target)
        i = i + 1
    end)
end

-- ── Checksum ──────────────────────────────────────────────────────────────────
local checkResults   = {}  -- { [name] = { parse, db } }
local checkTimer     = nil

-- FNV-1a 32-bit hash over a string (Lua 5.1 compatible — no bitwise operators)
local function FNV1a(str)
    local hash = 2166136261
    for i = 1, #str do
        local b = str:byte(i)
        -- XOR via: a ~ b = (a + b) - 2*(a & b), but simpler: use the bit library if available,
        -- otherwise approximate with addition-based mixing that still distributes well
        if bit then
            hash = bit.bxor(hash, b)
        else
            -- Manual XOR for environments without bit lib
            local xor, mask, h, bv = 0, 1, hash, b
            while h > 0 or bv > 0 do
                local hb, bb = h % 2, bv % 2
                if hb ~= bb then xor = xor + mask end
                mask, h, bv = mask * 2, math.floor(h / 2), math.floor(bv / 2)
            end
            hash = xor
        end
        hash = (hash * 16777619) % 4294967296
    end
    return hash
end

local function Checksum()
    if #cttLoot.itemNames == 0 then return "empty" end
    -- Sorted copies for deterministic iteration
    local items   = {}; for _, v in ipairs(cttLoot.itemNames)   do items[#items+1]   = v end
    local players = {}; for _, v in ipairs(cttLoot.playerNames) do players[#players+1] = v end
    table.sort(items)
    table.sort(players)
    -- Serialize all values in deterministic order using persistent index tables
    local parts = {}
    for _, pname in ipairs(players) do
        local pi = cttLoot.playerIndex[pname]
        for _, iname in ipairs(items) do
            local ii = cttLoot.itemIndex[iname]
            local v = cttLoot.matrix[pi] and cttLoot.matrix[pi][ii]
            if v then
                parts[#parts+1] = iname .. "\t" .. pname .. "\t" .. string.format("%.4f", v)
            end
        end
    end
    local payload = table.concat(parts, "\n")
    return string.format("%d|%d|%08x", #cttLoot.itemNames, #cttLoot.playerNames, FNV1a(payload))
end

local function DBChecksum()
    local keys = {}
    for key in pairs(cttLoot.DB) do keys[#keys+1] = tostring(key) end
    table.sort(keys)
    local payload = table.concat(keys, ",")
    return string.format("%d|%08x", #keys, FNV1a(payload))
end

-- ── Network: receive ──────────────────────────────────────────────────────────
-- Midnight: addon message payloads are Secret in instances.
-- We guard with InChatMessagingLockdown() and discard rather than read Secrets.
local inboundBuffers        = {}
local inboundDBBuffers      = {}

local function OnAddonMessage(_, prefix, message, channel, sender)
    if prefix ~= cttLoot.PREFIX then return end

    -- Do not attempt to read Secret message contents in instances.
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end

    -- UnitName("player") is non-secret; safe to compare.
    local senderShort = sender:match("^([^%-]+)") or sender
    if not cttLoot.loopback and senderShort == UnitName("player") then return end

    -- Checksum ping — someone is asking for our checksums
    if message == "CHECK:" then
        local reply = Checksum() .. "|DB:" .. DBChecksum()
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
        local target  = channel == "WHISPER" and sender or nil
        SafeSendAddonMessage(cttLoot.PREFIX, "CHECKR:" .. reply, channel, target)
        return
    end

    -- RC award broadcast from ML — stamp winner on card for all clients
    if message:sub(1, 6) == "AWARD:" then
        if cttLoot_RC and cttLoot_RC.HandleMessage then
            cttLoot_RC.HandleMessage(message)
        end
        return
    end

    -- Checksum response — someone replied to our check
    if message:sub(1, 7) == "CHECKR:" then
        local payload     = message:sub(8)
        local myCheck     = Checksum()
        local myDBCheck   = DBChecksum()
        -- Format: "parseCheck|DB:dbCheck"
        local theirParse, theirDB = payload:match("^(.+)|DB:(.+)$")
        if not theirParse then
            -- Legacy client — no DB checksum
            theirParse = payload
            theirDB    = nil
        end
        if checkResults then
            checkResults[sender] = {
                parse = (theirParse == myCheck),
                db    = theirDB and (theirDB == myDBCheck) or nil,
            }
        end
        return
    end

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
            local cnt = 0
            -- Full replace — sender's DB becomes ours
            cttLoot.DB = {}
            cttLootDB.customDB = {}
            for id, entry in pairs(entries) do
                cttLoot.DB[id] = entry
                cttLootDB.customDB[id] = entry
                cnt = cnt + 1
            end
            cttLoot:MergeCustomDB()
            cttLoot_UI:PopulateBossDropdown()
            cttLoot:Print(string.format("Received item DB from %s: replaced with %d entries.", sender, cnt))
        end
        return
    end

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
        inboundBuffers[sender] = nil

        local fullPayload = table.concat(assembled)
        local parsed = Deserialize(fullPayload)
        -- Debug: count non-nil values
        local nonNil = 0
        for r = 1, #parsed.matrix do
            for i = 1, #parsed.itemNames do
                if parsed.matrix[r][i] ~= nil then nonNil = nonNil + 1 end
            end
        end
        cttLoot:Print(string.format("Received data from %s: %d items × %d players, %d values, payload=%d bytes",
            sender, #parsed.itemNames, #parsed.playerNames, nonNil, #fullPayload))
        cttLoot:ApplyData(parsed)
        cttLoot_UI.selectedBoss = nil
        cttLoot_UI.selectedItem = nil
        cttLoot_UI.lootFilter   = nil
        cttLoot_UI:Refresh()
    end
end

-- ── Test mode ────────────────────────────────────────────────────────────────
-- Cycles through DB bosses on PLAYER_REGEN_ENABLED, simulates loot window
cttLoot.testMode        = false
cttLoot.testBossIndex   = 1
cttLoot.wasInCombat     = false  -- tracks combat state to detect transitions

local function RunTestLoot()
    -- Build sorted list of bosses currently in the DB
    local bosses = cttLoot:GetAllBosses()
    if #bosses == 0 then
        cttLoot:Print("Test mode: no bosses in DB. Import a DB first.")
        return
    end

    -- Cycle to next boss
    if cttLoot.testBossIndex > #bosses then
        cttLoot.testBossIndex = 1
    end
    local bossName = bosses[cttLoot.testBossIndex]
    cttLoot.testBossIndex = cttLoot.testBossIndex + 1

    -- Get all items for this boss that exist in the loaded CSV
    local csvNameSet = {}
    for _, csvName in ipairs(cttLoot.itemNames) do
        csvNameSet[csvName:lower()] = csvName
    end

    local pool = {}
    for _, itemName in ipairs(cttLoot:GetItemsForBoss(bossName)) do
        -- Exclude catalyst variants from the drop pool (those come from tokens)
        local nameLower = itemName:lower()
        if not nameLower:find(" catalyst$") then
            local match = csvNameSet[nameLower]
            if match then pool[#pool + 1] = match end
        end
    end

    if #pool == 0 then
        cttLoot:Print(string.format("Test mode: no CSV matches for %s, skipping.", bossName))
        return
    end

    -- Shuffle pool and pick 4-6 items
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local count = math.min(math.random(4, 6), #pool)
    local loot = {}
    for i = 1, count do loot[i] = pool[i] end

    cttLoot:Print(string.format("[TEST] %s — %d items", bossName, count))
    cttLoot_UI:SetBossFilter(bossName)
    cttLoot_UI:SetLootFilter(loot)
    if not cttLoot_UI:IsWindowShown() then
        cttLoot_UI:Toggle()
    else
        cttLoot_UI:Refresh()
    end
end

-- ── Encounter & loot tracking ─────────────────────────────────────────────────
-- Midnight compliance notes:
--
--   ENCOUNTER_END: the encounterName argument is SecretWhenInInstance.
--   We intentionally ignore it entirely and store only the numeric encounterId,
--   which is always a plain number. Boss name resolution happens via our own
--   DB (cttLoot.DB entries may optionally carry an encounterId field).
--
--   LOOT_OPENED: GetLootSlotLink returns a Secret string in instances.
--   We pass the Secret link directly to C_Item.GetItemIDFromItemLink, which
--   is documented to accept Secrets and returns a plain number. We never
--   pattern-match, concatenate, or otherwise inspect the raw link string.
--
--   UI calls (Toggle, SetBossFilter, SetLootFilter, Refresh): these may
--   involve frame manipulation. All such calls originating from event handlers
--   are deferred via DeferAction when InCombatLockdown() is true, and
--   executed on PLAYER_REGEN_ENABLED.

cttLoot.lastKilledEncounterId = nil
cttLoot.lastKilledName        = nil  -- only stored when not Secret (out of instance)

local function OnEncounterEnd(encounterId, encounterName, _, _, success)
    if success ~= 1 then return end
    cttLoot.lastKilledEncounterId = encounterId  -- plain number, always safe

    -- encounterName is SecretWhenInInstance. issecretvalue() tells us whether it
    -- is currently a Secret so we never attempt to read or store a Secret string.
    if issecretvalue and issecretvalue(encounterName) then
        cttLoot.lastKilledName = nil
    else
        cttLoot.lastKilledName = encounterName
    end
end

-- Resolve a boss name using two strategies:
--   1. encounterId match against DB entries that carry one (works in instances)
--   2. Boss name fuzzy match against lastKilledName (works outside instances)
local function ResolveBoss()
    local encounterId = cttLoot.lastKilledEncounterId
    local killedName  = cttLoot.lastKilledName

    -- Strategy 1: numeric encounterId match
    if encounterId then
        for _, entry in pairs(cttLoot.DB) do
            if entry.encounterId == encounterId then
                return entry.boss
            end
        end
    end

    -- Strategy 2: name match (only available when encounterName was not Secret)
    if killedName then
        local killedLower = killedName:lower()
        -- Exact match first
        for _, entry in pairs(cttLoot.DB) do
            if entry.boss and entry.boss:lower() == killedLower then
                return entry.boss
            end
        end
        -- Partial match fallback
        for _, entry in pairs(cttLoot.DB) do
            if entry.boss then
                local bossLower = entry.boss:lower()
                if bossLower:find(killedLower, 1, true) or killedLower:find(bossLower, 1, true) then
                    return entry.boss
                end
            end
        end
    end

    return nil
end

-- Build and apply the loot filter. Called only when the loot window is open
-- and we are NOT in combat lockdown.
-- Note: loot is only Secret *during* an active encounter. By the time this
-- runs (LOOT_OPENED after ENCOUNTER_END), the item names are readable.
local function OpenLootUI(matchedBoss)
    -- Build a lowercase set of CSV item names for fast lookup
    local csvNameSet = {}
    for _, csvName in ipairs(cttLoot.itemNames) do
        csvNameSet[csvName:lower()] = csvName
    end

    local lootedNames = {}
    local numSlots = GetNumLootItems and GetNumLootItems() or 0
    for i = 1, numSlots do
        -- GetLootSlotInfo returns the item name directly — safe post-encounter
        local name = GetLootSlotInfo and select(2, GetLootSlotInfo(i))
        if name and name ~= "" then
            local match = csvNameSet[name:lower()]
            if match then lootedNames[match] = true end
        else
            -- Fallback: try via item link → ID → DB
            local itemLink = GetLootSlotLink and GetLootSlotLink(i)
            if itemLink then
                local itemId = C_Item.GetItemIDFromItemLink and C_Item.GetItemIDFromItemLink(itemLink)
                if itemId then
                    local entries = cttLoot.DBByItemId[itemId]
                    if entries then
                        for _, entry in ipairs(entries) do
                            local m = csvNameSet[entry.name:lower()]
                            if m then lootedNames[m] = true end
                        end
                    end
                end
            end
        end
    end

    local filtered = {}
    for _, name in ipairs(cttLoot.itemNames) do
        if lootedNames[name] then filtered[#filtered + 1] = name end
    end

    if #filtered == 0 then
        local bossItemsInCSV = cttLoot_UI:GetVisibleItemsForBoss(matchedBoss)
        if #bossItemsInCSV == 0 then
            cttLoot:Print(string.format("%s loot detected but no matching items in CSV.", matchedBoss))
            return
        end
        cttLoot:Print(string.format("Auto-showing all %d items for %s.", #bossItemsInCSV, matchedBoss))
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

local function OnLootOpened()
    if #cttLoot.playerNames == 0 then return end
    if not cttLoot.lastKilledEncounterId and not cttLoot.lastKilledName then return end

    local matchedBoss = ResolveBoss()
    if not matchedBoss then return end

    if InCombatLockdown() then
        -- Loot window may close before combat ends so we cannot defer the
        -- GetLootSlotLink scan. Fall back to boss-level filter only, deferred.
        local bossSnap = matchedBoss
        DeferAction(function()
            cttLoot_UI:SetBossFilter(bossSnap)
            cttLoot_UI:SetLootFilter(nil)
            if not cttLoot_UI:IsWindowShown() then
                cttLoot_UI:Toggle()
            else
                cttLoot_UI:Refresh()
            end
        end)
    else
        OpenLootUI(matchedBoss)
    end
end

function cttLoot:RunCheck()
        if #cttLoot.itemNames == 0 then
            cttLoot:Print("No data loaded — nothing to check.")
        else
            local myCheck   = Checksum()
            local myDBCheck = DBChecksum()
            cttLoot:Print(string.format("Parse: %s  DB: %s — pinging group...", myCheck, myDBCheck))
            checkResults = {}
            if checkTimer then checkTimer:Cancel(); checkTimer = nil end
            local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
            local target  = channel == "WHISPER" and UnitName("player") or nil
            SafeSendAddonMessage(cttLoot.PREFIX, "CHECK:", channel, target)
            checkTimer = C_Timer.NewTimer(3, function()
                checkTimer = nil
                if not next(checkResults) then
                    cttLoot:Print("No responses — no other cttLoot users found.")
                    return
                end
                for name, result in pairs(checkResults) do
                    local parseOK = result.parse
                    local dbOK    = result.db
                    local parseStr = parseOK and "|cff44ff44parse OK|r" or "|cffff4444parse mismatch|r"
                    local dbStr
                    if dbOK == nil then
                        dbStr = "|cffaaaaaaDB unknown (old client)|r"
                    elseif dbOK then
                        dbStr = "|cff44ff44DB OK|r"
                    else
                        dbStr = "|cffff4444DB mismatch|r"
                    end
                    cttLoot:Print(string.format("  %s — %s  %s", name, parseStr, dbStr))
                end
            end)
        end
end



-- /cttloot ejtest [N]
--   Reads boss loot directly from the Encounter Journal for Liberation of
--   Undermine (instance 1296), picks a random boss (or boss #N), then adds
--   a random selection of 3-6 items to RCLootCouncil exactly as /rc add does.
--
--   Works entirely from live game data — no hardcoded item IDs, always current.
--   Item links that aren't cached yet are retried once after 2 seconds.

local EJ_INSTANCE_LOU    = 1296   -- Liberation of Undermine instance ID
local ejTestBossIndex    = 1      -- cycles if no arg given

function cttLoot:EJTest(bossArg)
    if not RCLootCouncil then
        self:Print("EJTest: RCLootCouncil not loaded.")
        return
    end
    local ML = RCLootCouncil:GetActiveModule("masterlooter")
    if not ML then
        self:Print("EJTest: You are not the Master Looter (or ML module not active).")
        return
    end

    -- Select the LoU instance in the EJ
    EJ_SelectInstance(EJ_INSTANCE_LOU)

    -- Build boss list from the EJ
    local bosses = {}
    local idx = 1
    while true do
        local encID, name = EJ_GetEncounterInfoByIndex(idx)
        if not encID then break end
        bosses[#bosses + 1] = { id = encID, name = name }
        idx = idx + 1
    end

    if #bosses == 0 then
        self:Print("EJTest: No bosses found for Liberation of Undermine in EJ.")
        return
    end

    -- Pick boss
    local bossNum
    if bossArg and bossArg >= 1 and bossArg <= #bosses then
        bossNum = bossArg
    else
        bossNum = ejTestBossIndex
        ejTestBossIndex = (ejTestBossIndex % #bosses) + 1
    end
    local boss = bosses[bossNum]
    EJ_SelectEncounter(boss.id)

    -- Gather loot for this boss (loot mode 1 = normal+)
    local lootPool = {}
    local lootIdx = 1
    while true do
        local itemID = EJ_GetLootInfoByIndex(lootIdx)
        if not itemID then break end
        lootPool[#lootPool + 1] = itemID
        lootIdx = lootIdx + 1
    end

    if #lootPool == 0 then
        self:Print(string.format("EJTest: No loot found for %s in EJ.", boss.name))
        return
    end

    -- Shuffle and pick 3-6 items
    for i = #lootPool, 2, -1 do
        local j = math.random(i)
        lootPool[i], lootPool[j] = lootPool[j], lootPool[i]
    end
    local count = math.min(math.random(3, 6), #lootPool)
    local picked = {}
    for i = 1, count do picked[i] = lootPool[i] end

    self:Print(string.format("[EJTest] Boss %d/%d: |cffffd700%s|r — adding %d items to RC...",
        bossNum, #bosses, boss.name, count))

    -- Add items to RC. C_Item.GetItemInfo may return nil for uncached items,
    -- so we collect any that fail and retry once after 2 seconds.
    local function AddToRC(itemID)
        local _, link = C_Item.GetItemInfo(itemID)
        if link then
            ML:AddItem(link, true, nil, nil, nil, boss.name)
            return true
        end
        return false
    end

    local retry = {}
    for _, itemID in ipairs(picked) do
        if not AddToRC(itemID) then
            C_Item.RequestLoadItemDataByID(itemID)
            retry[#retry + 1] = itemID
        end
    end

    if #retry > 0 then
        self:Print(string.format("EJTest: %d item(s) not cached, retrying in 2s...", #retry))
        C_Timer.After(2, function()
            for _, itemID in ipairs(retry) do
                if not AddToRC(itemID) then
                    self:Print(string.format("EJTest: item %d still not cached, skipping.", itemID))
                end
            end
        end)
    end
end

local function SlashHandler(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")
    if msg == "" or msg == "show" then
        cttLoot_UI:Toggle()
    elseif msg == "help" then
        cttLoot:Print("Commands:")
        cttLoot:Print("  |cffffd700/cttloot show|r — toggle window")
        cttLoot:Print("  |cffffd700/cttloot send|r — broadcast parse data to group")
        cttLoot:Print("  |cffffd700/cttloot check|r — verify group has same data")
        cttLoot:Print("  |cffffd700/cttloot rcsim [boss]|r — simulate RC loot session")
        cttLoot:Print("  |cffffd700/cttloot rctest <item>|r — test RC item match")
        cttLoot:Print("  |cffffd700/cttloot loopback|r — toggle receiving own broadcasts")
        cttLoot:Print("  |cffffd700/cttloot sendcheck|r — test serialize/deserialize")
        cttLoot:Print("  |cffffd700/cttloot test|r — toggle test mode")
        cttLoot:Print("  |cffffd700/cttloot ejtest [N]|r — RC test via Encounter Journal")
        cttLoot:Print("  |cffffd700/cttloot lootdebug|r — print loot slot debug info")
        cttLoot:Print("  |cffffd700/cttloot unknown|r — list unmatched CSV items")
        cttLoot:Print("  |cffffd700/cttloot reset|r — reset window position/size")
        cttLoot:Print("  |cffffd700/cttloot awardtest <item> [>> winner]|r — simulate award broadcast")
    elseif msg == "check" then
        cttLoot:RunCheck()
    elseif msg:sub(1, 6) == "rctest" then
        cttLoot_RC:Test(msg:sub(8))
    elseif msg:sub(1, 5) == "rcsim" then
        cttLoot_RCSim:Run(msg:sub(7))
    elseif msg == "rcdebug" then
        cttLoot_RCSim:DebugRC()
    elseif msg == "reset" then
        cttLootDB.windowX = nil; cttLootDB.windowY = nil
        cttLootDB.windowW = nil; cttLootDB.windowH = nil
        cttLootDB.windowPoint = nil; cttLootDB.windowRelPoint = nil
        cttLoot:Print("Window position and size reset. Reload to apply (/reload).")
    elseif msg == "send" then
        if #cttLoot.itemNames == 0 then
            cttLoot:Print("No data loaded. Paste CSV first.")
        else
            cttLoot:Broadcast()
        end
    elseif msg == "loopback" then
        cttLoot.loopback = not cttLoot.loopback
        if cttLoot.loopback then
            cttLoot:Print("Loopback ON — you will receive your own broadcasts.")
        else
            cttLoot:Print("Loopback OFF.")
        end
    elseif msg == "sendcheck" then
        local before = { items = #cttLoot.itemNames, players = #cttLoot.playerNames }
        local nonNilBefore = 0
        for r = 1, #cttLoot.matrix do
            for i = 1, #cttLoot.itemNames do
                if cttLoot.matrix[r][i] ~= nil then nonNilBefore = nonNilBefore + 1 end
            end
        end
        local payload = Serialize({ itemNames = cttLoot.itemNames, playerNames = cttLoot.playerNames, matrix = cttLoot.matrix })
        local parsed  = Deserialize(payload)
        local nonNilAfter = 0
        for r = 1, #parsed.matrix do
            for i = 1, #parsed.itemNames do
                if parsed.matrix[r][i] ~= nil then nonNilAfter = nonNilAfter + 1 end
            end
        end
        cttLoot:Print(string.format("Before: %d items, %d players, %d values", before.items, before.players, nonNilBefore))
        cttLoot:Print(string.format("After:  %d items, %d players, %d values", #parsed.itemNames, #parsed.playerNames, nonNilAfter))
        if nonNilBefore == nonNilAfter then
            cttLoot:Print("Serialize/Deserialize OK — no data loss.")
        else
            cttLoot:Print(string.format("DATA LOSS: lost %d values!", nonNilBefore - nonNilAfter))
        end
    elseif msg:sub(1, 9) == "awardtest" then
        -- Usage: /cttloot awardtest <item name> [winner]
        -- Simulates receiving an award broadcast without needing RC or a group
        local arg = msg:sub(11):match("^%s*(.-)%s*$")
        local itemPart, winnerPart = arg:match("^(.+)%s+>>%s+(.+)$")
        if not itemPart then
            itemPart   = arg
            winnerPart = UnitName("player") or "TestPlayer"
        end
        if itemPart == "" then
            cttLoot:Print("Usage: /cttloot awardtest <item> [>> winner]")
        elseif cttLoot_RC and cttLoot_RC.HandleMessage then
            local fakeMsg = "AWARD:" .. itemPart .. "\t" .. winnerPart
            local handled = cttLoot_RC.HandleMessage(fakeMsg)
            if handled then
                cttLoot:Print(string.format("Award test: |cffffd700%s|r → |cff00ff00%s|r", itemPart, winnerPart))
            else
                cttLoot:Print(string.format("Award test: no match for '%s'", itemPart))
            end
        end
        cttLoot.testMode = not cttLoot.testMode
        cttLoot.testBossIndex = 1
        if cttLoot.testMode then
            cttLoot:Print("Test mode ON — leave combat to cycle through bosses.")
        else
            cttLoot:Print("Test mode OFF.")
        end
    elseif msg:sub(1, 6) == "ejtest" then
        local arg = msg:sub(8):match("^%s*(.-)%s*$")
        cttLoot:EJTest(arg ~= "" and tonumber(arg) or nil)
    elseif msg == "lootdebug" then
        local numSlots = GetNumLootItems and GetNumLootItems() or 0
        cttLoot:Print(string.format("Loot slots: %d", numSlots))
        for i = 1, numSlots do
            local name = GetLootSlotInfo and select(2, GetLootSlotInfo(i))
            local itemLink = GetLootSlotLink and GetLootSlotLink(i)
            local itemId = itemLink and C_Item.GetItemIDFromItemLink and C_Item.GetItemIDFromItemLink(itemLink)
            cttLoot:Print(string.format("  slot %d: name=%s id=%s", i, tostring(name), tostring(itemId)))
        end
        cttLoot:Print(string.format("lastKilledEncounterId=%s lastKilledName=%s",
            tostring(cttLoot.lastKilledEncounterId), tostring(cttLoot.lastKilledName)))

        cttLoot:Print(string.format("In memory: %d items, %d players",
            #cttLoot.itemNames, #cttLoot.playerNames))
        if cttLootDB and cttLootDB.lastData then
            local d = cttLootDB.lastData
            cttLoot:Print(string.format("SavedVars lastData: %d items, %d players",
                d.itemNames and #d.itemNames or 0,
                d.playerNames and #d.playerNames or 0))
        else
            cttLoot:Print("SavedVars: no lastData saved")
        end
        -- Print first 5 item names in memory
        for i = 1, math.min(5, #cttLoot.itemNames) do
            cttLoot:Print("  item["..i.."]: "..cttLoot.itemNames[i])
        end
        -- Print first 5 player names
        for i = 1, math.min(5, #cttLoot.playerNames) do
            local row = cttLoot.matrix[i] or {}
            local nonnil = 0
            for _, v in ipairs(row) do if v then nonnil = nonnil + 1 end end
            cttLoot:Print(string.format("  player[%d]: %s (%d non-nil values)",
                i, cttLoot.playerNames[i], nonnil))
        end
    elseif msg == "unknown" then
        if #cttLoot.itemNames == 0 then
            cttLoot:Print("No CSV data loaded."); return
        end
        local unknown = {}
        for _, name in ipairs(cttLoot.itemNames) do
            local isCat = name:upper():sub(-9) == " CATALYST"
            if not isCat and not cttLoot:GetItemInfo(name) then
                table.insert(unknown, name)
            end
        end
        if #unknown == 0 then
            cttLoot:Print("All items matched in DB.")
        else
            cttLoot:Print(string.format("%d unmatched items:", #unknown))
            for _, name in ipairs(unknown) do
                cttLoot:Print("  " .. name)
            end
        end
        cttLoot:Print("/cttloot show     — open/close window")
        cttLoot:Print("/cttloot send     — broadcast data to raid/party")
        cttLoot:Print("/cttloot check    — verify everyone has the same data")
        cttLoot:Print("/cttloot test     — toggle test mode (fake loot on combat end)")
        cttLoot:Print("/cttloot ejtest [N] — RC test: add N random LoU boss items to RC session (N=1-8)")
        cttLoot:Print("/cttloot loopback — toggle receiving your own broadcasts")
        cttLoot:Print("/cttloot unknown  — list CSV items not found in item DB")
        cttLoot:Print("/cttloot debug    — print loaded data info")
    end
end

SLASH_CTTLOOT1 = "/cttloot"

SlashCmdList["CTTLOOT"] = SlashHandler

-- ── Print helper ──────────────────────────────────────────────────────────────
function cttLoot:Print(msg)
    print("|cffC8A84B[cttLoot]|r " .. tostring(msg))
end

-- ── Addon lifecycle ───────────────────────────────────────────────────────────
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "cttLoot" then
            cttLootDB = cttLootDB or CopyTable(defaults)
            if cttLootDB.customDB == nil then cttLootDB.customDB = {} end
            -- Restore parsed data directly (no CSV re-parse, no editbox size limit)
            if cttLootDB.lastData and cttLootDB.lastData.itemNames then
                cttLoot:ApplyData(cttLootDB.lastData)
                cttLoot:Print(string.format("Restored %d items x %d players.",
                    #cttLoot.itemNames, #cttLoot.playerNames))
            end
            cttLoot:MergeCustomDB()
            C_ChatInfo.RegisterAddonMessagePrefix(cttLoot.PREFIX)
            cttLoot:Print("Loaded. Type /cttloot for commands.")
        end
    elseif event == "PLAYER_LOGIN" then
        -- Delay RC init slightly to ensure RCLootCouncil has fully loaded
        C_Timer.After(1, function() cttLoot_RC:Init() end)
    elseif event == "PLAYER_LOGOUT" then
        -- Flush current window position to DB before saving
        if cttLoot_UI and cttLootDB then
            local w = cttLoot_UI:GetWindow()
            if w and w:IsShown() then
                local point, _, relPoint, x, y = w:GetPoint(1)
                if point then
                    cttLootDB.windowPoint    = point
                    cttLootDB.windowRelPoint = relPoint
                    cttLootDB.windowX = x
                    cttLootDB.windowY = y
                end
            end
        end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(_, ...)
    elseif event == "ENCOUNTER_END" then
        if not (RCLootCouncil and cttLoot_RC.trackEnabled) then
            OnEncounterEnd(...)
        end
    elseif event == "LOOT_OPENED" then
        if not (RCLootCouncil and cttLoot_RC.trackEnabled) then
            OnLootOpened()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended — execute any UI actions that were deferred
        FlushPendingActions()
        -- Test mode: only fire if we actually transitioned from in-combat
        if cttLoot.testMode and cttLoot.wasInCombat then
            if #cttLoot.playerNames > 0 then
                RunTestLoot()
            else
                cttLoot:Print("Test mode: no CSV loaded. Import parse data first.")
            end
        end
        cttLoot.wasInCombat = false
    elseif event == "PLAYER_REGEN_DISABLED" then
        cttLoot.wasInCombat = true
    end
end)
