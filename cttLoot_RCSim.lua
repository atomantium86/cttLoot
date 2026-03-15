-- cttLoot_RCSim.lua
-- Simulates an RCLootCouncil voting session using real Midnight Season 1 raid items.
-- Usage: /cttloot rcsim [boss]
--   No argument  -> picks a random boss across all three Season 1 raids
--   boss name    -> runs a specific boss (substring match)
--
-- ALL item IDs verified from Wowhead live/beta database search results (patch 12.0.1).
-- Source NPC names match Wowhead item pages exactly.

cttLoot_RCSim = {}

-- ── Verified Midnight Season 1 item data ──────────────────────────────────────
-- Format: { id=<wowhead item id>, name="Item Name" }

local RAIDS = {
    -- ── The Voidspire ─────────────────────────────────────────────────────────

    {
        raid = "The Voidspire",
        boss = "Imperator Averzian",
        items = {
            { id=249344, name="Light Company Guidon" },                  -- Trinket
            { id=249335, name="Imperator's Banner" },                    -- Back (Cloak)
            { id=249275, name="Bulwark of Noble Resolve" },              -- Shield
            { id=249279, name="Sunstrike Rifle" },                       -- Gun
            { id=249293, name="Weight of Command" },                     -- 1H Mace
            { id=249306, name="Devouring Night's Visage" },              -- Head (Leather)
            { id=249310, name="Robes of the Voidbound" },                -- Chest (Mail)
            { id=249313, name="Light-Judged Spaulders" },                -- Shoulders (Plate)
            { id=249319, name="Endless March Waistwrap" },               -- Waist (Cloth)
            { id=249320, name="Sabatons of Obscurement" },               -- Feet (Mail)
            { id=249323, name="Leggings of the Devouring Advance" },     -- Legs (Cloth)
            { id=249326, name="Light's March Bracers" },                 -- Wrists (Plate)
            { id=249334, name="Void-Claimed Shinkickers" },              -- Feet (Leather)
        },
    },
    {
        raid = "The Voidspire",
        boss = "Vorasius",
        items = {
            { id=249342, name="Heart of Ancient Hunger" },               -- Trinket
            { id=249276, name="Grimoire of the Eternal Light" },         -- Off-Hand
            { id=249925, name="Hungering Victory" },                     -- Dagger
            { id=249302, name="Inescapable Reach" },                     -- Polearm
            { id=249336, name="Signet of the Starved Beast" },           -- Ring
            { id=249315, name="Voracious Wristwraps" },                  -- Wrists (Cloth)
            { id=249317, name="Frenzy's Rebuke" },                       -- Head (Mail)
            { id=249327, name="Void-Skinned Bracers" },                  -- Wrists (Leather)
            { id=249332, name="Parasite Stompers" },                     -- Feet (Plate)
            { id=249351, name="Voidwoven Hungering Nullcore" },          -- Tier Token
            { id=249352, name="Voidcured Hungering Nullcore" },          -- Tier Token
            { id=249353, name="Voidcast Hungering Nullcore" },           -- Tier Token
            { id=249354, name="Voidforged Hungering Nullcore" },         -- Tier Token
        },
    },
    {
        raid = "The Voidspire",
        boss = "Fallen-King Salhadaar",
        items = {
            { id=249341, name="Volatile Void Suffuser" },                -- Trinket
            { id=249340, name="Wraps of Cosmic Madness" },               -- Trinket
            { id=249281, name="Blade of the Final Twilight" },           -- 1H Sword
            { id=249298, name="Tormentor's Bladed Fists" },              -- Fist Weapon
            { id=249337, name="Ribbon of Coiled Malice" },               -- Neck
            { id=249304, name="Fallen King's Cuffs" },                   -- Wrists (Mail)
            { id=249314, name="Twisted Twilight Sash" },                 -- Waist (Leather)
            { id=249316, name="Crown of the Fractured Tyrant" },         -- Head (Plate)
            { id=249308, name="Despotic Raiment" },                      -- Chest (Cloth)
            { id=249363, name="Voidwoven Unraveled Nullcore" },          -- Tier Token
            { id=249364, name="Voidcured Unraveled Nullcore" },          -- Tier Token
            { id=249365, name="Voidcast Unraveled Nullcore" },           -- Tier Token
            { id=249366, name="Voidforged Unraveled Nullcore" },         -- Tier Token
        },
    },
    {
        raid = "The Voidspire",
        boss = "Vaelgor & Ezzorak",
        items = {
            { id=249339, name="Gloom-Spattered Dreadscale" },            -- Trinket (Tank)
            { id=249346, name="Vaelgor's Final Stare" },                 -- Trinket (Int)
            { id=249280, name="Emblazoned Sunglaive" },                  -- Warglaive
            { id=249287, name="Clutchmates' Caress" },                   -- 1H Mace
            { id=249370, name="Draconic Nullcape" },                     -- Back (Cloak)
            { id=249305, name="Slippers of the Midnight Flame" },        -- Feet (Cloth)
            { id=249318, name="Nullwalker's Dread Epaulettes" },         -- Shoulders (Mail)
            { id=249321, name="Vaelgor's Fearsome Grasp" },              -- Hands (Leather)
            { id=249331, name="Ezzorak's Gloombind" },                   -- Waist (Plate)
            { id=249359, name="Voidwoven Corrupted Nullcore" },          -- Tier Token
            { id=249360, name="Voidcured Corrupted Nullcore" },          -- Tier Token
            { id=249361, name="Voidcast Corrupted Nullcore" },           -- Tier Token
            { id=249362, name="Voidforged Corrupted Nullcore" },         -- Tier Token
        },
    },
    {
        -- Lightblinded Vanguard is a council: War Chaplain Senn, Commander Venel Lightblood, General Amias Bellamy
        -- Loot is attributed per sub-boss on Wowhead but all drops on the same kill
        raid = "The Voidspire",
        boss = "Lightblinded Vanguard",
        items = {
            { id=249808, name="Litany of Lightblind Wrath" },            -- Trinket
            { id=249277, name="Bellamy's Final Judgement" },             -- 2H Mace
            { id=249294, name="Blade of the Blind Verdict" },            -- 1H Sword
            { id=249369, name="Bond of Light" },                         -- Ring
            { id=249303, name="Waistcord of the Judged" },               -- Waist (Mail)
            { id=249311, name="Lightblood Greaves" },                    -- Legs (Plate)
            { id=249330, name="War Chaplain's Grips" },                  -- Hands (Cloth)
            { id=249333, name="Blooming Barklight Spaulders" },          -- Shoulders (Leather)
            { id=249355, name="Voidwoven Fanatical Nullcore" },          -- Tier Token
            { id=249356, name="Voidcured Fanatical Nullcore" },          -- Tier Token
            { id=249357, name="Voidcast Fanatical Nullcore" },           -- Tier Token
            { id=249358, name="Voidforged Fanatical Nullcore" },         -- Tier Token
        },
    },
    {
        -- Crown of the Cosmos - boss is Alleria Windrunner
        raid = "The Voidspire",
        boss = "Crown of the Cosmos",
        items = {
            { id=249809, name="Locus-Walker's Ribbon" },                 -- Trinket (DPS Int)
            { id=249345, name="Ranger-Captain's Iridescent Insignia" },  -- Trinket (Agi)
            { id=260423, name="Arator's Swift Remembrance" },            -- 1H Sword
            { id=249295, name="Turalyon's False Echo" },                 -- 1H Mace
            { id=249288, name="Ranger-Captain's Lethal Recurve" },       -- Bow
            { id=249368, name="Eternal Voidsong Chain" },                -- Neck
            { id=249380, name="Hate-Tied Waistchain" },                  -- Waist (Plate)
            { id=249329, name="Gaze of the Unrestrained" },              -- Head (Cloth)
            { id=249312, name="Nightblade's Pantaloons" },               -- Legs (Leather)
            { id=249309, name="Sunbound Breastplate" },                  -- Chest (Plate)
            { id=249382, name="Canopy Walker's Footwraps" },             -- Feet (Leather)
            { id=249325, name="Untethered Berserker's Grips" },          -- Hands (Mail)
        },
    },

    -- ── The Dreamrift ─────────────────────────────────────────────────────────
    {
        raid = "The Dreamrift",
        boss = "Chimaerus, the Undreamt God",
        items = {
            { id=249343, name="Gaze of the Alnseer" },                   -- Trinket
            { id=249805, name="Undreamt God's Oozing Vestige" },         -- Trinket
            { id=249278, name="Alnscorned Spire" },                      -- Staff
            { id=249922, name="Tome of Alnscorned Regret" },             -- Off-Hand
            { id=249381, name="Greaves of the Unformed" },               -- Feet (Plate)
            { id=249373, name="Dream-Scorched Striders" },               -- Feet (Cloth)
            { id=249374, name="Scorn-Scarred Shul'ka's Belt" },          -- Waist (Leather)
            { id=249371, name="Scornbane Waistguard" },                  -- Waist (Mail)
            { id=249347, name="Alnwoven Riftbloom" },                    -- Tier Token
            { id=249348, name="Alncured Riftbloom" },                    -- Tier Token
            { id=249349, name="Alncast Riftbloom" },                     -- Tier Token
            { id=249350, name="Alnforged Riftbloom" },                   -- Tier Token
        },
    },

    -- ── March on Quel'Danas ───────────────────────────────────────────────────
    {
        raid = "March on Quel'Danas",
        boss = "Belo'ren, Child of Al'ar",
        items = {
            { id=249806, name="Radiant Plume" },                         -- Trinket (Agi/Str)
            { id=260235, name="Umbral Plume" },                          -- Trinket (Agi/Str)
            { id=249807, name="The Eternal Egg" },                       -- Trinket (Tank)
            { id=249283, name="Belo'melorn the Shattered Talon" },       -- 2H Sword
            { id=249284, name="Belo'ren's Swift Talon" },                -- 1H Sword
            { id=249919, name="Sin'dorei Band of Hope" },                -- Ring
            { id=249921, name="Thalassian Dawnguard" },                  -- Neck
            { id=249322, name="Radiant Clutchtender's Jerkin" },         -- Chest (Leather)
            { id=249328, name="Echoing Void Mantle" },                   -- Shoulders (Cloth)
            { id=249307, name="Emberborn Grasps" },                      -- Hands (Plate)
            { id=249324, name="Eternal Flame Scaleguards" },             -- Legs (Mail)
            { id=249376, name="Whisper-Inscribed Sash" },                -- Waist (Cloth)
            { id=249377, name="Darkstrider Treads" },                    -- Feet (Mail)
        },
    },
    {
        -- "Midnight Falls" boss is named L'ura on Wowhead
        raid = "March on Quel'Danas",
        boss = "Midnight Falls",
        items = {
            { id=249810, name="Shadow of the Empyrean Requiem" },        -- Trinket (Int)
            { id=249811, name="Light of the Cosmic Crescendo" },         -- Trinket (Healer)
            { id=249286, name="Brazier of the Dissonant Dirge" },        -- Staff
            { id=260408, name="Lightless Lament" },                      -- Warglaive
            { id=249920, name="Eye of Midnight" },                       -- Ring
            { id=250247, name="Amulet of the Abyssal Hymn" },            -- Neck
            { id=249912, name="Robes of Endless Oblivion" },             -- Chest (Cloth)
            { id=249296, name="Alah'endal the Dawnsong" },               -- 1H Sword
            { id=249915, name="Extinction Guards" },                     -- Legs (Plate)
            { id=249913, name="Mask of Darkest Intent" },                -- Head (Leather)
            { id=249914, name="Oblivion Guise" },                        -- Head (Mail)
            { id=249367, name="Chiming Void Curio" },                    -- Tier Token
        },
    },
}

-- ── RC API inspector (debug) ──────────────────────────────────────────────────
function cttLoot_RCSim:DebugRC()
    if not RCLootCouncil then
        cttLoot:Print("RC not loaded.")
        return
    end
    local ML = RCLootCouncil:GetActiveModule("masterlooter")
    if not ML then
        cttLoot:Print("No masterlooter module (not ML).")
        return
    end
    cttLoot:Print("ML methods:")
    for k, v in pairs(ML) do
        if type(v) == "function" then
            cttLoot:Print("  fn: " .. tostring(k))
        end
    end
    -- Also check metatable
    local mt = getmetatable(ML)
    if mt and mt.__index then
        cttLoot:Print("ML metatable methods:")
        for k, v in pairs(mt.__index) do
            if type(v) == "function" then
                cttLoot:Print("  fn: " .. tostring(k))
            end
        end
    end
end
local function MakeLink(id, name)
    return string.format("|cffff8000|Hitem:%d:0:0:0:0:0:0:0:0|h[%s]|h|r", id, name)
end

-- ── Fake loot table ───────────────────────────────────────────────────────────
local function BuildFakeLootTable(bossData, count)
    local pool = {}
    for _, item in ipairs(bossData.items) do
        pool[#pool+1] = item
    end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local lt = {}
    for i = 1, math.min(count, #pool) do
        lt[i] = {
            name    = pool[i].name,
            link    = MakeLink(pool[i].id, pool[i].name),
            ilvl    = 249,
            quality = 4,
        }
    end
    return lt
end

-- ── Inject items into RC, starting a session if needed ───────────────────────
local function InjectIntoRC(bossData, picked)
    local ML = RCLootCouncil:GetActiveModule("masterlooter")
    if not ML then
        cttLoot:Print("rcsim: RC loaded but you are not Master Looter - skipping RC inject.")
        return
    end

    local links = {}
    local retry = {}
    for _, item in ipairs(picked) do
        local _, link = C_Item.GetItemInfo(item.id)
        if link then
            links[#links+1] = { link = link, item = item }
        else
            C_Item.RequestLoadItemDataByID(item.id)
            retry[#retry+1] = item
        end
    end

    local function DoStart(itemLinks)
        if #itemLinks == 0 then
            cttLoot:Print("rcsim: no item links resolved, cannot start RC session.")
            return
        end
        local ML2 = RCLootCouncil:GetActiveModule("masterlooter")
        if not ML2 then return end
        for _, entry in ipairs(itemLinks) do
            ML2:AddItem(entry.link, true, nil, nil, nil, bossData.boss)
        end
        ML2:StartSession()
        cttLoot:Print(string.format("rcsim: RC session started with %d items.", #itemLinks))
    end

    if #retry > 0 then
        cttLoot:Print(string.format("rcsim: %d item(s) not cached, retrying in 2s...", #retry))
        C_Timer.After(2, function()
            for _, item in ipairs(retry) do
                local _, link = C_Item.GetItemInfo(item.id)
                if link then
                    links[#links+1] = { link = link, item = item }
                else
                    cttLoot:Print(string.format("rcsim: %s still not cached, skipping.", item.name))
                end
            end
            DoStart(links)
        end)
    else
        DoStart(links)
    end
end

-- ── Public: run simulation ────────────────────────────────────────────────────
function cttLoot_RCSim:Run(bossFilter)
    local candidates = {}
    if bossFilter and bossFilter ~= "" then
        local f = bossFilter:lower()
        for _, b in ipairs(RAIDS) do
            if b.boss:lower():find(f, 1, true) or b.raid:lower():find(f, 1, true) then
                candidates[#candidates+1] = b
            end
        end
        if #candidates == 0 then
            cttLoot:Print(string.format("rcsim: no boss matching '%s'", bossFilter))
            cttLoot:Print("Valid: Averzian, Vorasius, Salhadaar, Vaelgor, Vanguard, Crown, Chimaerus, Belo'ren, Midnight")
            return
        end
    else
        candidates = RAIDS
    end

    local bossData  = candidates[math.random(#candidates)]
    local count     = math.random(4, math.min(6, #bossData.items))
    local fakeTable = BuildFakeLootTable(bossData, count)

    cttLoot:Print(string.format(
        "rcsim -> |cff69CCF0%s|r / |cffffd700%s|r  (%d items)",
        bossData.raid, bossData.boss, #fakeTable))

    -- Inject into live RC session if RC is available
    if RCLootCouncil then
        local idMap = {}
        for _, item in ipairs(bossData.items) do idMap[item.name] = item end
        local picked = {}
        for _, entry in ipairs(fakeTable) do
            if idMap[entry.name] then picked[#picked+1] = idMap[entry.name] end
        end
        InjectIntoRC(bossData, picked)
    end

    local fakeRC = {
        _lootTable   = fakeTable,
        GetLootTable = function(self) return self._lootTable end,
    }

    local realRC  = RCLootCouncil
    if not RCLootCouncil then RCLootCouncil = fakeRC end

    cttLoot_UI:Open()

    local sessionItems = {}
    local seen = {}
    for _, entry in ipairs(fakeTable) do
        local name    = entry.name
        local matched = nil
        if #cttLoot.itemNames > 0 then
            local nl = name:lower()
            for _, n in ipairs(cttLoot.itemNames) do
                if n:lower() == nl then matched = n; break end
            end
            if not matched then
                for _, n in ipairs(cttLoot.itemNames) do
                    if nl:find(n:lower(), 1, true) then matched = n; break end
                end
            end
        end
        local display = matched or name
        if not seen[display] then
            seen[display] = true
            sessionItems[#sessionItems+1] = display
        end
    end

    if #sessionItems > 0 then
        cttLoot_UI.lootFilter   = sessionItems
        cttLoot_UI.selectedItem = sessionItems[1]
        cttLoot_UI:Refresh()
    else
        cttLoot:Print("rcsim: none of the simulated items are in your loaded parse data.")
        cttLoot:Print("Load a sim parse first, then run rcsim again.")
    end

    if not realRC then RCLootCouncil = nil end
end
