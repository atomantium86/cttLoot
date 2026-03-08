-- cttLoot_DB.lua
-- Item database: populated entirely via in-game Import DB panel.
-- Entries are saved to cttLootDB.customDB (SavedVariables) and loaded on login.

cttLoot.DB = {}

-- ── Derived lookups (built at load time, do not edit) ─────────────────────────
cttLoot.DBByName   = {}  -- lowercase item name → { boss }
cttLoot.DBByBoss   = {}  -- boss name           → { itemName, ... }
cttLoot.DBByItemId = {}  -- numeric item id     → { name, boss }
                         -- ALL ids stored since same id can map to different items

local function BuildDBLookups()
  for key, entry in pairs(cttLoot.DB) do
    local nameLower = (entry.name or ""):lower()
    if nameLower ~= "" then
      cttLoot.DBByName[nameLower] = { boss = entry.boss }
    end
    if entry.boss then
      if not cttLoot.DBByBoss[entry.boss] then
        cttLoot.DBByBoss[entry.boss] = {}
      end
      table.insert(cttLoot.DBByBoss[entry.boss], entry.name)
    end
    -- Extract numeric ID from compound key "id_name" — store every id
    local numId = tonumber(key:match("^(%d+)_"))
    if numId then
      -- Store all mappings; if same id maps to multiple names, keep a list
      if not cttLoot.DBByItemId[numId] then
        cttLoot.DBByItemId[numId] = {}
      end
      table.insert(cttLoot.DBByItemId[numId], { name = entry.name, boss = entry.boss })
    end
  end
end

BuildDBLookups()

-- ── Public helpers ────────────────────────────────────────────────────────────

-- Returns { boss } for a given item name, or nil if not in DB
function cttLoot:GetItemInfo(itemName)
  return self.DBByName[(itemName or ""):lower()]
end

-- Returns a sorted list of all boss names that have DB entries
function cttLoot:GetAllBosses()
  local seen   = {}
  local result = {}
  for _, entry in pairs(self.DB) do
    if entry.boss and not seen[entry.boss] then
      seen[entry.boss] = true
      table.insert(result, entry.boss)
    end
  end
  table.sort(result)
  return result
end

-- Returns item names that drop from a specific boss
function cttLoot:GetItemsForBoss(bossName)
  return self.DBByBoss[bossName] or {}
end

-- ── In-game DB import (SavedVariables: cttLootDB.customDB) ───────────────────
-- Parses tab-separated lines: ID \t Name \t Boss
-- Merges into cttLoot.DB at login.

function cttLoot:ParseDBRaw(raw)
    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    local entries = {}
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local delim = line:find("\t") and "\t" or ","
            local cols = {}
            local pattern = "([^" .. delim .. "]*)" .. delim
            for col in (line .. delim):gmatch(pattern) do
                cols[#cols + 1] = col:match("^%s*(.-)%s*$"):gsub('^"(.*)"$', '%1')
            end
            local id          = tonumber(cols[1])
            local name        = cols[2] or ""
            local boss        = cols[3] or ""
            local encounterId = tonumber(cols[4])
            if id and name ~= "" and boss ~= "" then
                -- Use id+name as key to avoid ID reuse across bosses
                local key = tostring(id) .. "_" .. name
                entries[key] = { name = name, boss = boss, encounterId = encounterId }
            end
        end
    end
    return entries
end

-- Merge cttLootDB.customDB into cttLoot.DB and rebuild lookups
function cttLoot:MergeCustomDB()
    if not cttLootDB or not cttLootDB.customDB then return end
    local count = 0
    for key, entry in pairs(cttLootDB.customDB) do
        cttLoot.DB[key] = entry
        count = count + 1
    end
    if count > 0 then
        wipe(cttLoot.DBByName)
        wipe(cttLoot.DBByBoss)
        wipe(cttLoot.DBByItemId)
        for key, entry in pairs(cttLoot.DB) do
            local nameLower = (entry.name or ""):lower()
            if nameLower ~= "" then
                cttLoot.DBByName[nameLower] = { boss = entry.boss }
            end
            if entry.boss then
                if not cttLoot.DBByBoss[entry.boss] then
                    cttLoot.DBByBoss[entry.boss] = {}
                end
                local found = false
                for _, n in ipairs(cttLoot.DBByBoss[entry.boss]) do
                    if n == entry.name then found = true; break end
                end
                if not found then
                    table.insert(cttLoot.DBByBoss[entry.boss], entry.name)
                end
            end
            local numId = tonumber(key:match("^(%d+)_"))
            if numId then
                if not cttLoot.DBByItemId[numId] then
                    cttLoot.DBByItemId[numId] = {}
                end
                table.insert(cttLoot.DBByItemId[numId], { name = entry.name, boss = entry.boss })
            end
        end
        cttLoot:Print(string.format("Loaded %d custom DB entries.", count))
    end
end
