-- cttLoot.lua  (rewritten for clean layer separation)
-- Core module: data model, CSV parsing, serialisation, network, checksums.
--
-- UI CONTRACT
-- This file communicates with cttLoot_UI ONLY through these public methods:
--   cttLoot_UI:Toggle()                  cttLoot_UI:Open()
--   cttLoot_UI:Close()                   cttLoot_UI:IsWindowShown()
--   cttLoot_UI:SetBossFilter(boss)       cttLoot_UI:SetLootFilter(items)
--   cttLoot_UI:Refresh()                 cttLoot_UI:PopulateBossDropdown()
--   cttLoot_UI:GetWindow()               cttLoot_UI:GetVisibleItemsForBoss(boss)
-- It never touches cttLoot_UI locals or internals.
--
-- Midnight Secret Value compliance:
--   * GetLootSlotLink -> C_Item.GetItemIDFromItemLink only (never inspected).
--   * ENCOUNTER_END: only numeric encounterId stored; name resolved from DB.
--   * UI calls from combat events deferred to PLAYER_REGEN_ENABLED.
--   * C_ChatInfo.SendAddonMessage guarded by InChatMessagingLockdown().

cttLoot = {}
cttLoot.VERSION    = 1
cttLoot.loopback   = false
cttLoot.PREFIX     = "cttLoot"
cttLoot.CHUNK_SIZE = 240

-- Data model
cttLoot.itemNames   = {}
cttLoot.playerNames = {}
cttLoot.matrix      = {}
cttLoot.itemIndex   = {}   -- name -> index  (O(1))
cttLoot.playerIndex = {}   -- name -> index  (O(1))

-- ── Saved vars defaults ───────────────────────────────────────────────────────
local defaults = {
    customDB={}; lastData=nil; history={};
    windowX=nil; windowY=nil; windowW=nil; windowH=nil;
    windowPoint=nil; windowRelPoint=nil;
}

-- ── Combat-deferred action queue ──────────────────────────────────────────────
local pendingActions = {}
local function DeferAction(fn) pendingActions[#pendingActions+1] = fn end
local function FlushPendingActions()
    for _, fn in ipairs(pendingActions) do pcall(fn) end
    pendingActions = {}
end

-- ── CSV row splitter ──────────────────────────────────────────────────────────
local function splitRow(line, delim)
    if delim == "\t" then
        local cells = {}
        for cell in (line.."\t"):gmatch("([^\t]*)\t") do
            cells[#cells+1] = cell:match("^%s*(.-)%s*$")
        end
        return cells
    end
    local cells, i, len = {}, 1, #line
    while i <= len+1 do
        if i > len then cells[#cells+1]=""; break end
        if line:sub(i,i) == '"' then
            local val=""; i=i+1
            while i<=len do
                local c=line:sub(i,i)
                if c=='"' then
                    if line:sub(i+1,i+1)=='"' then val=val..'"'; i=i+2
                    else i=i+1; break end
                else val=val..c; i=i+1 end
            end
            cells[#cells+1]=val
            if line:sub(i,i)=="," then i=i+1 end
        else
            local j=line:find(",",i,true)
            if j then cells[#cells+1]=line:sub(i,j-1):match("^%s*(.-)%s*$"); i=j+1
            else       cells[#cells+1]=line:sub(i):match("^%s*(.-)%s*$"); i=len+2 end
        end
    end
    return cells
end

-- ── CSV Parser ────────────────────────────────────────────────────────────────
function cttLoot:ParseCSV(raw)
    raw = raw:gsub("\r\n","\n"):gsub("\r","\n")
    local lines = {}
    for line in (raw.."\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then lines[#lines+1]=line end
    end
    if #lines < 2 then return nil, "Need at least a header row and one data row." end

    local delim = lines[1]:find("\t") and "\t" or ","
    local headerCells = splitRow(lines[1], delim)
    local rawPlayerNames, rawPlayerIdxs = {}, {}
    for i=2,#headerCells do
        if headerCells[i] ~= "" then
            local name = headerCells[i]
            name = name:sub(1,1):upper()..name:sub(2)
            rawPlayerNames[#rawPlayerNames+1] = name
            rawPlayerIdxs[#rawPlayerIdxs+1]   = i
        end
    end

    local rawItemNames, rawMatrix = {}, {}
    for p=1,#rawPlayerNames do rawMatrix[p]={} end
    for r=2,#lines do
        local cells    = splitRow(lines[r], delim)
        local itemName = cells[1] or ""
        if itemName ~= "" then
            local idx = #rawItemNames+1
            rawItemNames[idx] = itemName
            for p, origCol in ipairs(rawPlayerIdxs) do
                local val = (cells[origCol] or ""):gsub(",",""):gsub("^%+","")
                rawMatrix[p][idx] = tonumber(val)
            end
        end
    end
    return { itemNames=rawItemNames, playerNames=rawPlayerNames, matrix=rawMatrix }
end

-- ── Apply parsed data ─────────────────────────────────────────────────────────
function cttLoot:ApplyData(data)
    self.itemNames = data.itemNames
    for i, name in ipairs(data.playerNames) do
        data.playerNames[i] = name:sub(1,1):upper()..name:sub(2)
    end
    self.playerNames = data.playerNames
    self.matrix      = data.matrix
    self.itemIndex   = {}
    self.playerIndex = {}
    for i, v in ipairs(self.itemNames)   do self.itemIndex[v]   = i end
    for i, v in ipairs(self.playerNames) do self.playerIndex[v] = i end
    if self.onDataApplied then self.onDataApplied() end
    if cttLoot_RC and cttLoot_RC.ClearAwards then cttLoot_RC.ClearAwards() end
end

-- ── Serialisation ─────────────────────────────────────────────────────────────
local SEP = "\031"

local function Serialize(data)
    local parts = { "VER|"..cttLoot.VERSION, "ITEMS|"..table.concat(data.itemNames,"^") }
    local numItems = #data.itemNames
    for r, player in ipairs(data.playerNames) do
        local vals, row = {}, data.matrix[r] or {}
        for i=1,numItems do vals[i] = row[i]~=nil and tostring(row[i]) or "N" end
        parts[#parts+1] = "PLAYER|"..player.."|"..table.concat(vals,"^")
    end
    return table.concat(parts, SEP)
end

local function Deserialize(raw)
    local data = { itemNames={}, playerNames={}, matrix={} }
    for line in (raw..SEP):gmatch("([^"..SEP.."]*)("..SEP..")") do
        if line:sub(1,6)=="ITEMS|" then
            for item in (line:sub(7).."^"):gmatch("([^^]*)%^") do
                data.itemNames[#data.itemNames+1]=item
            end
        elseif line:sub(1,7)=="PLAYER|" then
            local rest=line:sub(8); local sep=rest:find("|")
            if sep then
                local player=rest:sub(1,sep-1)
                player=player:sub(1,1):upper()..player:sub(2)
                local valStr=rest:sub(sep+1)
                data.playerNames[#data.playerNames+1]=player
                local row, col={}, 0
                for v in (valStr.."^"):gmatch("([^^]*)%^") do
                    col=col+1; if v~="N" then row[col]=tonumber(v) end
                end
                data.matrix[#data.matrix+1]=row
            end
        end
    end
    return data
end

-- ── Network send helpers ──────────────────────────────────────────────────────
local function SafeSend(prefix, msg, channel, target)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        cttLoot:Print("Cannot send: addon messaging restricted in instances.")
        return false
    end
    C_ChatInfo.SendAddonMessage(prefix, msg, channel, target)
    return true
end

local function BroadcastChunked(payload, msgPrefix, channel, target, onDone)
    local chunks, pos = {}, 1
    while pos<=#payload do
        chunks[#chunks+1]=payload:sub(pos, pos+cttLoot.CHUNK_SIZE-1)
        pos=pos+cttLoot.CHUNK_SIZE
    end
    local total, i, ticker = #chunks, 1
    ticker = C_Timer.NewTicker(0.1, function()
        if i>total then ticker:Cancel(); if onDone then onDone(total) end; return end
        SafeSend(cttLoot.PREFIX, msgPrefix..i.."/"..total..":"..chunks[i], channel, target)
        i=i+1
    end)
end

function cttLoot:Broadcast(channel)
    if not channel then
        channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
    end
    local target  = channel=="WHISPER" and UnitName("player") or nil
    local payload = Serialize({itemNames=self.itemNames,playerNames=self.playerNames,matrix=self.matrix})
    cttLoot:Print(string.format("Serialized payload: %d bytes, %d chunks",
        #payload, math.ceil(#payload/self.CHUNK_SIZE)))
    BroadcastChunked(payload, "", channel, target, function(total)
        cttLoot:Print(string.format("Broadcast %d items x %d players to %s in %d chunk(s).",
            #cttLoot.itemNames, #cttLoot.playerNames, channel, total))
    end)
end

-- ── DB serialisation ──────────────────────────────────────────────────────────
local function SerializeDB()
    local lines = {"DBVER|1"}
    for id, entry in pairs(cttLoot.DB) do
        if entry.name and entry.boss then
            lines[#lines+1]="DBENTRY|"..id.."|"..entry.name.."|"..entry.boss
        end
    end
    return table.concat(lines, SEP)
end

local function DeserializeDB(raw)
    local entries={}
    for line in (raw..SEP):gmatch("([^"..SEP.."]*)("..SEP..")") do
        if line:sub(1,8)=="DBENTRY|" then
            local rest=line:sub(9)
            local id,name,boss=rest:match("^(%d+)|([^|]+)|(.+)$")
            id=tonumber(id)
            if id and name and boss then entries[id]={name=name,boss=boss} end
        end
    end
    return entries
end

function cttLoot:BroadcastDB(channel)
    if not channel then
        channel=IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
    end
    local target=channel=="WHISPER" and UnitName("player") or nil
    local count=0; for _ in pairs(self.DB) do count=count+1 end
    if count==0 then self:Print("Item DB is empty."); return end
    local payload=SerializeDB()
    BroadcastChunked(payload, "DB:", channel, target, function(total)
        cttLoot:Print(string.format("Sent item DB (%d entries) to %s in %d chunk(s).",count,channel,total))
    end)
end

-- ── Checksums (FNV-1a, Lua 5.1 compatible) ───────────────────────────────────
local function FNV1a(str)
    local hash=2166136261
    for i=1,#str do
        local b=str:byte(i)
        if bit then hash=bit.bxor(hash,b)
        else
            local xor,mask,h,bv=0,1,hash,b
            while h>0 or bv>0 do
                local hb,bb=h%2,bv%2
                if hb~=bb then xor=xor+mask end
                mask,h,bv=mask*2,math.floor(h/2),math.floor(bv/2)
            end
            hash=xor
        end
        hash=(hash*16777619)%4294967296
    end
    return hash
end

local function Checksum()
    if #cttLoot.itemNames==0 then return "empty" end
    local items,players={},{}
    for _,v in ipairs(cttLoot.itemNames)   do items[#items+1]=v end
    for _,v in ipairs(cttLoot.playerNames) do players[#players+1]=v end
    table.sort(items); table.sort(players)
    local parts={}
    for _,pname in ipairs(players) do
        local pi=cttLoot.playerIndex[pname]
        for _,iname in ipairs(items) do
            local ii=cttLoot.itemIndex[iname]
            local v=cttLoot.matrix[pi] and cttLoot.matrix[pi][ii]
            if v then parts[#parts+1]=iname.."\t"..pname.."\t"..string.format("%.4f",v) end
        end
    end
    return string.format("%d|%d|%08x",#cttLoot.itemNames,#cttLoot.playerNames,FNV1a(table.concat(parts,"\n")))
end

local function DBChecksum()
    local keys={}
    for key in pairs(cttLoot.DB) do keys[#keys+1]=tostring(key) end
    table.sort(keys)
    return string.format("%d|%08x",#keys,FNV1a(table.concat(keys,",")))
end

-- ── Network receive ───────────────────────────────────────────────────────────
local checkResults     = {}
local checkTimer       = nil
local inboundBuffers   = {}
local inboundDBBuffers = {}

local function OnAddonMessage(_, prefix, message, channel, sender)
    if prefix~=cttLoot.PREFIX then return end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end
    local senderShort = sender:match("^([^%-]+)") or sender
    if not cttLoot.loopback and senderShort==UnitName("player") then return end

    -- CHECK ping
    if message=="CHECK:" then
        local reply=Checksum().."|DB:"..DBChecksum()
        local ch=IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
        local tgt=ch=="WHISPER" and sender or nil
        SafeSend(cttLoot.PREFIX,"CHECKR:"..reply,ch,tgt)
        return
    end

    -- Award broadcast
    if message:sub(1,6)=="AWARD:" then
        if cttLoot_RC and cttLoot_RC.HandleMessage then cttLoot_RC.HandleMessage(message) end
        return
    end

    -- CHECK response
    if message:sub(1,7)=="CHECKR:" then
        local payload=message:sub(8)
        local myCheck,myDBCheck=Checksum(),DBChecksum()
        local theirParse,theirDB=payload:match("^(.+)|DB:(.+)$")
        if not theirParse then theirParse=payload; theirDB=nil end
        checkResults[sender]={
            parse=(theirParse==myCheck),
            db=theirDB and (theirDB==myDBCheck) or nil,
        }
        return
    end

    -- DB chunks
    if message:sub(1,3)=="DB:" then
        local idx,total,data=message:match("^DB:(%d+)/(%d+):(.*)$")
        idx=tonumber(idx); total=tonumber(total)
        if not idx or not total then return end
        if not inboundDBBuffers[sender] or inboundDBBuffers[sender].total~=total then
            inboundDBBuffers[sender]={total=total,received=0,chunks={}}
        end
        local buf=inboundDBBuffers[sender]
        buf.chunks[idx]=data; buf.received=buf.received+1
        if buf.received==total then
            local entries=DeserializeDB(table.concat(buf.chunks))
            inboundDBBuffers[sender]=nil
            local cnt=0
            cttLoot.DB={}; cttLootDB.customDB={}
            for id,entry in pairs(entries) do
                cttLoot.DB[id]=entry; cttLootDB.customDB[id]=entry; cnt=cnt+1
            end
            cttLoot:MergeCustomDB()
            if cttLoot_UI and cttLoot_UI.PopulateBossDropdown then
                cttLoot_UI:PopulateBossDropdown()
            end
            cttLoot:Print(string.format("Received item DB from %s: replaced with %d entries.",sender,cnt))
        end
        return
    end

    -- Parse data chunks
    local idx,total,data=message:match("^(%d+)/(%d+):(.*)$")
    idx=tonumber(idx); total=tonumber(total)
    if not idx or not total then return end
    if not inboundBuffers[sender] or inboundBuffers[sender].total~=total then
        inboundBuffers[sender]={total=total,received=0,chunks={}}
    end
    local buf=inboundBuffers[sender]
    buf.chunks[idx]=data; buf.received=buf.received+1
    if buf.received==total then
        local assembled={}
        for i=1,total do assembled[i]=buf.chunks[i] or "" end
        inboundBuffers[sender]=nil
        local fullPayload=table.concat(assembled)
        local parsed=Deserialize(fullPayload)
        local nonNil=0
        for r=1,#parsed.matrix do
            for i=1,#parsed.itemNames do
                if parsed.matrix[r][i]~=nil then nonNil=nonNil+1 end
            end
        end
        cttLoot:Print(string.format("Received data from %s: %d items x %d players, %d values, payload=%d bytes",
            sender,#parsed.itemNames,#parsed.playerNames,nonNil,#fullPayload))
        cttLoot:ApplyData(parsed)
        -- Reset view state via public API only
        if cttLoot_UI then
            cttLoot_UI:SetBossFilter(nil)
            cttLoot_UI:SetLootFilter(nil)
            cttLoot_UI:Refresh()
        end
    end
end

-- ── Test mode ─────────────────────────────────────────────────────────────────
cttLoot.testMode      = false
cttLoot.testBossIndex = 1
cttLoot.wasInCombat   = false

local function RunTestLoot()
    local bosses=cttLoot:GetAllBosses()
    if #bosses==0 then cttLoot:Print("Test mode: no bosses in DB."); return end
    if cttLoot.testBossIndex>#bosses then cttLoot.testBossIndex=1 end
    local bossName=bosses[cttLoot.testBossIndex]
    cttLoot.testBossIndex=cttLoot.testBossIndex+1

    local csvNameSet={}
    for _,csvName in ipairs(cttLoot.itemNames) do csvNameSet[csvName:lower()]=csvName end
    local pool={}
    for _,itemName in ipairs(cttLoot:GetItemsForBoss(bossName)) do
        local nameLower=itemName:lower()
        if not nameLower:find(" catalyst$") then
            local match=csvNameSet[nameLower]
            if match then pool[#pool+1]=match end
        end
    end
    if #pool==0 then cttLoot:Print(string.format("Test mode: no CSV matches for %s.",bossName)); return end
    for i=#pool,2,-1 do local j=math.random(i); pool[i],pool[j]=pool[j],pool[i] end
    local count=math.min(math.random(4,6),#pool)
    local loot={}; for i=1,count do loot[i]=pool[i] end
    cttLoot:Print(string.format("[TEST] %s — %d items",bossName,count))
    if cttLoot_UI then
        cttLoot_UI:SetBossFilter(bossName)
        cttLoot_UI:SetLootFilter(loot)
        if not cttLoot_UI:IsWindowShown() then cttLoot_UI:Toggle()
        else cttLoot_UI:Refresh() end
    end
end

-- ── Encounter & loot tracking ─────────────────────────────────────────────────
cttLoot.lastKilledEncounterId = nil
cttLoot.lastKilledName        = nil

local function OnEncounterEnd(encounterId, encounterName, _, _, success)
    if success~=1 then return end
    cttLoot.lastKilledEncounterId=encounterId
    if issecretvalue and issecretvalue(encounterName) then cttLoot.lastKilledName=nil
    else cttLoot.lastKilledName=encounterName end
end

local function ResolveBoss()
    local encounterId=cttLoot.lastKilledEncounterId
    local killedName=cttLoot.lastKilledName
    if encounterId then
        for _,entry in pairs(cttLoot.DB) do
            if entry.encounterId==encounterId then return entry.boss end
        end
    end
    if killedName then
        local killedLower=killedName:lower()
        for _,entry in pairs(cttLoot.DB) do
            if entry.boss and entry.boss:lower()==killedLower then return entry.boss end
        end
        for _,entry in pairs(cttLoot.DB) do
            if entry.boss then
                local bossLower=entry.boss:lower()
                if bossLower:find(killedLower,1,true) or killedLower:find(bossLower,1,true) then
                    return entry.boss
                end
            end
        end
    end
    return nil
end

local function OpenLootUI(matchedBoss)
    if not cttLoot_UI then return end
    local csvNameSet={}
    for _,csvName in ipairs(cttLoot.itemNames) do csvNameSet[csvName:lower()]=csvName end
    local lootedNames={}
    local numSlots=GetNumLootItems and GetNumLootItems() or 0
    for i=1,numSlots do
        local name=GetLootSlotInfo and select(2,GetLootSlotInfo(i))
        if name and name~="" then
            local match=csvNameSet[name:lower()]
            if match then lootedNames[match]=true end
        else
            local itemLink=GetLootSlotLink and GetLootSlotLink(i)
            if itemLink then
                local itemId=C_Item.GetItemIDFromItemLink and C_Item.GetItemIDFromItemLink(itemLink)
                if itemId then
                    local entries=cttLoot.DBByItemId[itemId]
                    if entries then
                        for _,entry in ipairs(entries) do
                            local m=csvNameSet[entry.name:lower()]
                            if m then lootedNames[m]=true end
                        end
                    end
                end
            end
        end
    end
    local filtered={}
    for _,name in ipairs(cttLoot.itemNames) do
        if lootedNames[name] then filtered[#filtered+1]=name end
    end
    if #filtered==0 then
        local bossItemsInCSV=cttLoot_UI:GetVisibleItemsForBoss(matchedBoss)
        if #bossItemsInCSV==0 then
            cttLoot:Print(string.format("%s loot detected but no matching items in CSV.",matchedBoss))
            return
        end
        cttLoot:Print(string.format("Auto-showing all %d items for %s.",#bossItemsInCSV,matchedBoss))
        cttLoot_UI:SetBossFilter(matchedBoss)
        cttLoot_UI:SetLootFilter(nil)
    else
        cttLoot:Print(string.format("Showing %d looted item(s) from %s.",#filtered,matchedBoss))
        cttLoot_UI:SetBossFilter(matchedBoss)
        cttLoot_UI:SetLootFilter(filtered)
    end
    if not cttLoot_UI:IsWindowShown() then cttLoot_UI:Toggle()
    else cttLoot_UI:Refresh() end
end

local function OnLootOpened()
    if #cttLoot.playerNames==0 then return end
    if not cttLoot.lastKilledEncounterId and not cttLoot.lastKilledName then return end
    local matchedBoss=ResolveBoss()
    if not matchedBoss then return end
    if InCombatLockdown() then
        local bossSnap=matchedBoss
        DeferAction(function()
            if not cttLoot_UI then return end
            cttLoot_UI:SetBossFilter(bossSnap)
            cttLoot_UI:SetLootFilter(nil)
            if not cttLoot_UI:IsWindowShown() then cttLoot_UI:Toggle()
            else cttLoot_UI:Refresh() end
        end)
    else
        OpenLootUI(matchedBoss)
    end
end

-- ── Run check ─────────────────────────────────────────────────────────────────
function cttLoot:RunCheck()
    if #cttLoot.itemNames==0 then cttLoot:Print("No data loaded."); return end
    local myCheck,myDBCheck=Checksum(),DBChecksum()
    cttLoot:Print(string.format("Parse: %s  DB: %s — pinging group...",myCheck,myDBCheck))
    checkResults={}
    if checkTimer then checkTimer:Cancel(); checkTimer=nil end
    local ch=IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
    local tgt=ch=="WHISPER" and UnitName("player") or nil
    SafeSend(cttLoot.PREFIX,"CHECK:",ch,tgt)
    checkTimer=C_Timer.NewTimer(3,function()
        checkTimer=nil
        if not next(checkResults) then cttLoot:Print("No responses."); return end
        for name,result in pairs(checkResults) do
            local parseStr=result.parse and "|cff44ff44parse OK|r" or "|cffff4444parse mismatch|r"
            local dbStr
            if result.db==nil then dbStr="|cffaaaaaaDB unknown (old client)|r"
            elseif result.db  then dbStr="|cff44ff44DB OK|r"
            else                   dbStr="|cffff4444DB mismatch|r" end
            cttLoot:Print(string.format("  %s — %s  %s",name,parseStr,dbStr))
        end
    end)
end

-- ── EJ test ───────────────────────────────────────────────────────────────────
local EJ_INSTANCE_LOU=1296
local ejTestBossIndex=1

function cttLoot:EJTest(bossArg)
    if not RCLootCouncil then self:Print("EJTest: RCLootCouncil not loaded."); return end
    local ML=RCLootCouncil:GetActiveModule("masterlooter")
    if not ML then self:Print("EJTest: Not the Master Looter."); return end
    EJ_SelectInstance(EJ_INSTANCE_LOU)
    local bosses,idx={},1
    while true do
        local encID,name=EJ_GetEncounterInfoByIndex(idx)
        if not encID then break end
        bosses[#bosses+1]={id=encID,name=name}; idx=idx+1
    end
    if #bosses==0 then self:Print("EJTest: No bosses found."); return end
    local bossNum
    if bossArg and bossArg>=1 and bossArg<=#bosses then bossNum=bossArg
    else bossNum=ejTestBossIndex; ejTestBossIndex=(ejTestBossIndex%#bosses)+1 end
    local boss=bosses[bossNum]
    EJ_SelectEncounter(boss.id)
    local lootPool,lootIdx={},1
    while true do
        local itemID=EJ_GetLootInfoByIndex(lootIdx)
        if not itemID then break end
        lootPool[#lootPool+1]=itemID; lootIdx=lootIdx+1
    end
    if #lootPool==0 then self:Print(string.format("EJTest: No loot for %s.",boss.name)); return end
    for i=#lootPool,2,-1 do local j=math.random(i); lootPool[i],lootPool[j]=lootPool[j],lootPool[i] end
    local count=math.min(math.random(3,6),#lootPool)
    local picked={}; for i=1,count do picked[i]=lootPool[i] end
    self:Print(string.format("[EJTest] Boss %d/%d: |cffffd700%s|r — adding %d items to RC...",
        bossNum,#bosses,boss.name,count))
    local function AddToRC(itemID)
        local _,link=C_Item.GetItemInfo(itemID)
        if link then ML:AddItem(link,true,nil,nil,nil,boss.name); return true end
        return false
    end
    local retry={}
    for _,itemID in ipairs(picked) do
        if not AddToRC(itemID) then C_Item.RequestLoadItemDataByID(itemID); retry[#retry+1]=itemID end
    end
    if #retry>0 then
        self:Print(string.format("EJTest: %d item(s) not cached, retrying in 2s...",#retry))
        C_Timer.After(2,function()
            for _,itemID in ipairs(retry) do
                if not AddToRC(itemID) then self:Print(string.format("EJTest: item %d still not cached.",itemID)) end
            end
        end)
    end
end

-- ── Winner facade ─────────────────────────────────────────────────────────────
-- cttLoot_UI calls this to get the winner string for an item.
-- It delegates to cttLoot_RC so the UI layer never imports RC directly.
function cttLoot:GetWinnerForItem(itemName)
    if cttLoot_RC and cttLoot_RC.GetWinnerForItem then
        return cttLoot_RC.GetWinnerForItem(itemName)
    end
    return nil
end

-- ── Print helper ──────────────────────────────────────────────────────────────
function cttLoot:Print(msg)
    print("|cffC8A84B[cttLoot]|r "..tostring(msg))
end

-- ── Slash handler ─────────────────────────────────────────────────────────────
local function SlashHandler(msg)
    msg=msg:lower():match("^%s*(.-)%s*$")
    if msg=="" or msg=="show" then
        if cttLoot_UI then cttLoot_UI:Toggle() end
    elseif msg=="help" then
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
        cttLoot:Print("  |cffffd700/cttloot awardtest <item> [>> winner]|r — simulate award")
    elseif msg=="check" then
        cttLoot:RunCheck()
    elseif msg:sub(1,6)=="rctest" then
        cttLoot_RC:Test(msg:sub(8))
    elseif msg:sub(1,5)=="rcsim" then
        cttLoot_RCSim:Run(msg:sub(7))
    elseif msg=="rcdebug" then
        cttLoot_RCSim:DebugRC()
    elseif msg=="reset" then
        cttLootDB.windowX=nil; cttLootDB.windowY=nil
        cttLootDB.windowW=nil; cttLootDB.windowH=nil
        cttLootDB.windowPoint=nil; cttLootDB.windowRelPoint=nil
        cttLoot:Print("Window reset. Reload to apply (/reload).")
    elseif msg=="send" then
        if #cttLoot.itemNames==0 then cttLoot:Print("No data loaded.")
        else cttLoot:Broadcast() end
    elseif msg=="loopback" then
        cttLoot.loopback=not cttLoot.loopback
        cttLoot:Print(cttLoot.loopback and "Loopback ON." or "Loopback OFF.")
    elseif msg=="sendcheck" then
        local before={items=#cttLoot.itemNames,players=#cttLoot.playerNames}
        local nonNilBefore=0
        for r=1,#cttLoot.matrix do
            for i=1,#cttLoot.itemNames do
                if cttLoot.matrix[r][i]~=nil then nonNilBefore=nonNilBefore+1 end
            end
        end
        local payload=Serialize({itemNames=cttLoot.itemNames,playerNames=cttLoot.playerNames,matrix=cttLoot.matrix})
        local parsed=Deserialize(payload)
        local nonNilAfter=0
        for r=1,#parsed.matrix do
            for i=1,#parsed.itemNames do
                if parsed.matrix[r][i]~=nil then nonNilAfter=nonNilAfter+1 end
            end
        end
        cttLoot:Print(string.format("Before: %d items, %d players, %d values",before.items,before.players,nonNilBefore))
        cttLoot:Print(string.format("After:  %d items, %d players, %d values",#parsed.itemNames,#parsed.playerNames,nonNilAfter))
        cttLoot:Print(nonNilBefore==nonNilAfter and "Serialize/Deserialize OK." or
            string.format("DATA LOSS: lost %d values!",nonNilBefore-nonNilAfter))
    elseif msg:sub(1,9)=="awardtest" then
        local arg=msg:sub(11):match("^%s*(.-)%s*$")
        local itemPart,winnerPart=arg:match("^(.+)%s+>>%s+(.+)$")
        if not itemPart then itemPart=arg; winnerPart=UnitName("player") or "TestPlayer" end
        if itemPart=="" then cttLoot:Print("Usage: /cttloot awardtest <item> [>> winner]")
        elseif cttLoot_RC and cttLoot_RC.HandleMessage then
            local handled=cttLoot_RC.HandleMessage("AWARD:"..itemPart.."\t"..winnerPart)
            if handled then cttLoot:Print(string.format("Award test: |cffffd700%s|r -> |cff00ff00%s|r",itemPart,winnerPart))
            else cttLoot:Print(string.format("Award test: no match for '%s'",itemPart)) end
        end
    elseif msg=="test" then
        cttLoot.testMode=not cttLoot.testMode
        cttLoot.testBossIndex=1
        cttLoot:Print(cttLoot.testMode and "Test mode ON — leave combat to cycle bosses." or "Test mode OFF.")
    elseif msg:sub(1,6)=="ejtest" then
        local arg=msg:sub(8):match("^%s*(.-)%s*$")
        cttLoot:EJTest(arg~="" and tonumber(arg) or nil)
    elseif msg=="lootdebug" then
        local numSlots=GetNumLootItems and GetNumLootItems() or 0
        cttLoot:Print(string.format("Loot slots: %d",numSlots))
        for i=1,numSlots do
            local name=GetLootSlotInfo and select(2,GetLootSlotInfo(i))
            local itemLink=GetLootSlotLink and GetLootSlotLink(i)
            local itemId=itemLink and C_Item.GetItemIDFromItemLink and C_Item.GetItemIDFromItemLink(itemLink)
            cttLoot:Print(string.format("  slot %d: name=%s id=%s",i,tostring(name),tostring(itemId)))
        end
        cttLoot:Print(string.format("lastKilledEncounterId=%s lastKilledName=%s",
            tostring(cttLoot.lastKilledEncounterId),tostring(cttLoot.lastKilledName)))
        cttLoot:Print(string.format("In memory: %d items, %d players",#cttLoot.itemNames,#cttLoot.playerNames))
        if cttLootDB and cttLootDB.lastData then
            local d=cttLootDB.lastData
            cttLoot:Print(string.format("SavedVars lastData: %d items, %d players",
                d.itemNames and #d.itemNames or 0,d.playerNames and #d.playerNames or 0))
        else cttLoot:Print("SavedVars: no lastData saved") end
        for i=1,math.min(5,#cttLoot.itemNames) do cttLoot:Print("  item["..i.."]: "..cttLoot.itemNames[i]) end
        for i=1,math.min(5,#cttLoot.playerNames) do
            local row=cttLoot.matrix[i] or {}
            local nonnil=0; for _,v in ipairs(row) do if v then nonnil=nonnil+1 end end
            cttLoot:Print(string.format("  player[%d]: %s (%d non-nil)",i,cttLoot.playerNames[i],nonnil))
        end
    elseif msg=="unknown" then
        if #cttLoot.itemNames==0 then cttLoot:Print("No CSV data loaded."); return end
        local unknown={}
        for _,name in ipairs(cttLoot.itemNames) do
            local isCat=name:upper():sub(-9)==" CATALYST"
            if not isCat and not cttLoot:GetItemInfo(name) then unknown[#unknown+1]=name end
        end
        if #unknown==0 then cttLoot:Print("All items matched in DB.")
        else
            cttLoot:Print(string.format("%d unmatched items:",#unknown))
            for _,name in ipairs(unknown) do cttLoot:Print("  "..name) end
        end
    else
        cttLoot:Print("/cttloot help — list commands")
    end
end

SLASH_CTTLOOT1="/cttloot"
SlashCmdList["CTTLOOT"]=SlashHandler

-- ── Addon lifecycle ───────────────────────────────────────────────────────────
local frame=CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")

frame:SetScript("OnEvent", function(_, event, ...)
    if event=="ADDON_LOADED" then
        local name=...
        if name=="cttLoot" then
            cttLootDB=cttLootDB or CopyTable(defaults)
            if cttLootDB.customDB==nil then cttLootDB.customDB={} end
            if cttLootDB.lastData and cttLootDB.lastData.itemNames then
                cttLoot:ApplyData(cttLootDB.lastData)
                cttLoot:Print(string.format("Restored %d items x %d players.",
                    #cttLoot.itemNames,#cttLoot.playerNames))
            end
            cttLoot:MergeCustomDB()
            if cttLoot_History then cttLoot_History:Init() end
            C_ChatInfo.RegisterAddonMessagePrefix(cttLoot.PREFIX)
            cttLoot:Print("Loaded. Type /cttloot for commands.")
        end
    elseif event=="PLAYER_LOGIN" then
        C_Timer.After(1,function() cttLoot_RC:Init() end)
    elseif event=="PLAYER_LOGOUT" then
        if cttLoot_UI and cttLootDB then
            local w=cttLoot_UI:GetWindow()
            if w then
                local point,_,relPoint,x,y=w:GetPoint(1)
                if point then
                    cttLootDB.windowPoint=point; cttLootDB.windowRelPoint=relPoint
                    cttLootDB.windowX=x; cttLootDB.windowY=y
                end
            end
        end
    elseif event=="CHAT_MSG_ADDON" then
        OnAddonMessage(_,...)
    elseif event=="ENCOUNTER_END" then
        if not (RCLootCouncil and cttLoot_RC.trackEnabled) then OnEncounterEnd(...) end
    elseif event=="LOOT_OPENED" then
        if not (RCLootCouncil and cttLoot_RC.trackEnabled) then OnLootOpened() end
    elseif event=="PLAYER_REGEN_ENABLED" then
        FlushPendingActions()
        if cttLoot.testMode and cttLoot.wasInCombat then
            if #cttLoot.playerNames>0 then RunTestLoot()
            else cttLoot:Print("Test mode: no CSV loaded.") end
        end
        cttLoot.wasInCombat=false
    elseif event=="PLAYER_REGEN_DISABLED" then
        cttLoot.wasInCombat=true
    end
end)
