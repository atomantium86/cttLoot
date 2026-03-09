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
        return nil, "Need at least a header row and one player row."
    end

    local delim = lines[1]:find("\t") and "\t" or ","

    local headerCells = splitRow(lines[1], delim)
    local rawItemNames, rawItemIdxs = {}, {}
    for i = 2, #headerCells do
        if headerCells[i] ~= "" then
            rawItemNames[#rawItemNames + 1] = headerCells[i]
            rawItemIdxs[#rawItemIdxs + 1] = i
        end
    end
    local totalCols = #headerCells - 1

    local rawPlayerNames, rawMatrix = {}, {}
    for r = 2, #lines do
        local cells = splitRow(lines[r], delim)
        while #cells <= totalCols do cells[#cells + 1] = "" end
        local player = cells[1] or ""
        if player ~= "" then
            rawPlayerNames[#rawPlayerNames + 1] = player
            local row = {}
            for j, origIdx in ipairs(rawItemIdxs) do
                local val = (cells[origIdx] or ""):gsub(",", ""):gsub("^%+", "")
                row[j] = tonumber(val)
            end
            rawMatrix[#rawMatrix + 1] = row
        end
    end

    return { itemNames = rawItemNames, playerNames = rawPlayerNames, matrix = rawMatrix }
end

function cttLoot:ApplyData(data)
    self.itemNames   = data.itemNames
    self.playerNames = data.playerNames
    self.matrix      = data.matrix
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
local checkResults = {}  -- { [name] = "match" | "mismatch" }
local checkTimer   = nil

local function Checksum()
    if #cttLoot.itemNames == 0 then return "empty" end
    local sum = 0
    for r = 1, #cttLoot.matrix do
        for i = 1, #cttLoot.itemNames do
            local v = cttLoot.matrix[r][i]
            if v then sum = sum + v * (r * 100 + i) end
        end
    end
    return string.format("%d|%d|%d", #cttLoot.itemNames, #cttLoot.playerNames, sum % 1000000)
end

-- ── Network: receive ──────────────────────────────────────────────────────────
-- Midnight: addon message payloads are Secret in instances.
-- We guard with InChatMessagingLockdown() and discard rather than read Secrets.
local inboundBuffers   = {}
local inboundDBBuffers = {}

local function OnAddonMessage(_, prefix, message, _, sender)
    if prefix ~= cttLoot.PREFIX then return end

    -- Do not attempt to read Secret message contents in instances.
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end

    -- UnitName("player") is non-secret; safe to compare.
    local senderShort = sender:match("^([^%-]+)") or sender
    if not cttLoot.loopback and senderShort == UnitName("player") then return end

    -- Checksum ping — someone is asking for our checksum
    if message == "CHECK:" then
        local myCheck = Checksum()
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
        local target  = channel == "WHISPER" and sender or nil
        SafeSendAddonMessage(cttLoot.PREFIX, "CHECKR:" .. myCheck, channel, target)
        return
    end

    -- Checksum response — someone replied to our check
    if message:sub(1, 7) == "CHECKR:" then
        local theirCheck = message:sub(8)
        local myCheck    = Checksum()
        if checkResults then
            checkResults[sender] = (theirCheck == myCheck) and "match" or "mismatch"
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
            for id, entry in pairs(entries) do
                cttLoot.DB[id] = entry
                cttLootDB.customDB[id] = entry
                cnt = cnt + 1
            end
            cttLoot:MergeCustomDB()
            cttLoot_UI:PopulateBossDropdown()
            cttLoot:Print(string.format("Received item DB from %s: %d entries added.", sender, cnt))
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
            local myCheck = Checksum()
            cttLoot:Print(string.format("My checksum: %s — pinging group...", myCheck))
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
                    if result == "match" then
                        cttLoot:Print(string.format("  %s |cff44ff44[OK]|r match", name))
                    else
                        cttLoot:Print(string.format("  %s |cffff4444[!!]|r mismatch", name))
                    end
                end
            end)
        end
end

local function SlashHandler(msg)
    msg = msg:lower():match("^%s*(.-)%s*$")
    if msg == "" or msg == "show" then
        cttLoot_UI:Toggle()
    elseif msg == "check" then
        cttLoot:RunCheck()
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
    elseif msg == "test" then
        cttLoot.testMode = not cttLoot.testMode
        cttLoot.testBossIndex = 1
        if cttLoot.testMode then
            cttLoot:Print("Test mode ON — leave combat to cycle through bosses.")
        else
            cttLoot:Print("Test mode OFF.")
        end
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
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(_, ...)
    elseif event == "ENCOUNTER_END" then
        OnEncounterEnd(...)
    elseif event == "LOOT_OPENED" then
        OnLootOpened()
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
