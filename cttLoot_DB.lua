-- cttLoot_DB.lua
-- Item database: populated entirely via in-game Import DB panel.
-- Entries are saved to cttLootDB.customDB (SavedVariables) and loaded on login.

cttLoot.DB = {}



-- ── Derived lookups (built at load time, do not edit) ─────────────────────────
cttLoot.DBByName  = {}  -- lowercase item name → { boss, raid }
cttLoot.DBByBoss  = {}  -- boss name           → { itemName, ... }
cttLoot.RaidOrder = {   -- canonical raid order for the dropdown
  "The Voidspire",
  "Dreamrift",
  "March on Quel'Danas",
}

local function BuildDBLookups()
  for _, entry in pairs(cttLoot.DB) do
    local nameLower = (entry.name or ""):lower()
    if nameLower ~= "" then
      cttLoot.DBByName[nameLower] = { boss = entry.boss, raid = entry.raid }
    end
    if entry.boss then
      if not cttLoot.DBByBoss[entry.boss] then
        cttLoot.DBByBoss[entry.boss] = {}
      end
      table.insert(cttLoot.DBByBoss[entry.boss], entry.name)
    end
  end
end

BuildDBLookups()

-- ── Public helpers ────────────────────────────────────────────────────────────

-- Returns { boss, raid } for a given item name, or nil if not in DB
function cttLoot:GetItemInfo(itemName)
  return self.DBByName[(itemName or ""):lower()]
end

-- Returns a list of all boss names (in raid order)
function cttLoot:GetAllBosses()
  local seen   = {}
  local result = {}
  for _, raid in ipairs(self.RaidOrder) do
    for _, entry in pairs(self.DB) do
      if entry.raid == raid and entry.boss and not seen[entry.boss] then
        seen[entry.boss] = true
        table.insert(result, { boss = entry.boss, raid = raid })
      end
    end
  end
  return result
end

-- Returns item names that drop from a specific boss
function cttLoot:GetItemsForBoss(bossName)
  return self.DBByBoss[bossName] or {}
end

-- ── In-game DB import (SavedVariables: cttLootDB.customDB) ───────────────────
-- Parses tab-separated lines: ID \t Name \t Boss [\t Raid]
-- Skips CATALYST / TOKEN / recipe rows. Merges into cttLoot.DB at login.

function cttLoot:ParseDBRaw(raw)
    local entries = {}
    local defaultRaid = "The Voidspire"
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local cols = {}
            for col in (line .. "\t"):gmatch("([^\t]*)\t") do
                cols[#cols + 1] = col:match("^%s*(.-)%s*$")
            end
            local id   = tonumber(cols[1])
            local name = cols[2] or ""
            local boss = cols[3] or ""
            local raid = (cols[4] and cols[4] ~= "") and cols[4] or defaultRaid
            -- Skip invalid, catalyst, token, recipe rows
            if id and name ~= "" and boss ~= "" then
                local nameLow = name:lower()
                if not (nameLow:find("catalyst") or nameLow:find("token")
                    or nameLow:find("recipe") or nameLow:find("formula")
                    or nameLow:find("pattern") or nameLow:find("schematic")) then
                    entries[id] = { name = name, boss = boss, raid = raid }
                end
            end
        end
    end
    return entries
end

-- Merge cttLootDB.customDB into cttLoot.DB and rebuild lookups
function cttLoot:MergeCustomDB()
    if not cttLootDB or not cttLootDB.customDB then return end
    local count = 0
    for id, entry in pairs(cttLootDB.customDB) do
        cttLoot.DB[id] = entry
        count = count + 1
    end
    if count > 0 then
        -- Rebuild lookups to include custom entries
        wipe(cttLoot.DBByName)
        wipe(cttLoot.DBByBoss)
        for _, entry in pairs(cttLoot.DB) do
            local nameLower = (entry.name or ""):lower()
            if nameLower ~= "" then
                cttLoot.DBByName[nameLower] = { boss = entry.boss, raid = entry.raid }
            end
            if entry.boss then
                if not cttLoot.DBByBoss[entry.boss] then
                    cttLoot.DBByBoss[entry.boss] = {}
                end
                -- avoid duplicates
                local found = false
                for _, n in ipairs(cttLoot.DBByBoss[entry.boss]) do
                    if n == entry.name then found = true; break end
                end
                if not found then
                    table.insert(cttLoot.DBByBoss[entry.boss], entry.name)
                end
            end
        end
        cttLoot:Print(string.format("Loaded %d custom DB entries.", count))
    end
end
