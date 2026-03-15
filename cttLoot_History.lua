-- cttLoot_History.lua
-- Persistent loot decision history.
--
-- Each award records a snapshot of ALL sim values at the moment of the decision,
-- so the record remains accurate even after the CSV is replaced next week.
--
-- SavedVar layout  (cttLootDB.history):
--   { [n] = {
--       itemName  = "string",
--       winner    = "string",
--       boss      = "string" or nil,
--       timestamp = <Unix seconds>,
--       sims      = { [playerName] = { base=<num or nil>, cat=<num or nil> } }
--   } }

cttLoot_History = {}

-- Cached reversed view — invalidated on any mutation
local getAllCache = nil

-- ── Public: record one award ──────────────────────────────────────────────────
-- Called by cttLoot_RC immediately after an award is confirmed.
-- Snapshots the current matrix so values are frozen at decision time.
function cttLoot_History:RecordAward(itemName, winner)
    getAllCache = nil
    if not cttLootDB then return end
    if not cttLootDB.history then cttLootDB.history = {} end

    -- Snapshot sim values for this item right now
    local ci    = cttLoot.itemIndex[itemName]
    local catCi = cttLoot.itemIndex[itemName .. " CATALYST"]
    local sims  = {}

    for r, playerName in ipairs(cttLoot.playerNames) do
        local row  = cttLoot.matrix[r]
        local base = ci    and row and row[ci]    or nil
        local cat  = catCi and row and row[catCi] or nil
        if base or cat then
            sims[playerName] = { base = base, cat = cat }
        end
    end

    -- Resolve boss from item DB
    local info = cttLoot:GetItemInfo(itemName)
    local boss = info and info.boss or nil

    local entry = {
        itemName  = itemName,
        winner    = winner,
        boss      = boss,
        timestamp = time(),
        sims      = sims,
    }
    table.insert(cttLootDB.history, entry)
end

-- ── Public: prune entries older than N days ───────────────────────────────────
function cttLoot_History:PruneOlderThan(days)
    getAllCache = nil
    if not cttLootDB or not cttLootDB.history then return 0 end
    local cutoff = time() - (days * 86400)
    local kept   = {}
    local pruned = 0
    for _, entry in ipairs(cttLootDB.history) do
        if entry.timestamp >= cutoff then
            table.insert(kept, entry)
        else
            pruned = pruned + 1
        end
    end
    cttLootDB.history = kept
    return pruned
end

-- ── Public: get all entries (newest first) ────────────────────────────────────
function cttLoot_History:GetAll()
    if getAllCache then return getAllCache end
    if not cttLootDB or not cttLootDB.history then return {} end
    -- Return a reversed copy so newest is first
    local result = {}
    for i = #cttLootDB.history, 1, -1 do
        table.insert(result, cttLootDB.history[i])
    end
    getAllCache = result
    return result
end

-- ── Public: total count ───────────────────────────────────────────────────────
function cttLoot_History:Count()
    if not cttLootDB or not cttLootDB.history then return 0 end
    return #cttLootDB.history
end

-- ── Public: clear all ────────────────────────────────────────────────────────
function cttLoot_History:ClearAll()
    getAllCache = nil
    if cttLootDB then cttLootDB.history = {} end
end

-- ── Initialise SavedVar on addon load ────────────────────────────────────────
-- Called from cttLoot.lua ADDON_LOADED after cttLootDB is set up
function cttLoot_History:Init()
    if not cttLootDB.history then cttLootDB.history = {} end
end
