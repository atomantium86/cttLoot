-- cttLoot_UI.lua
-- Mirrors the HTML viewer layout exactly:
--   Title bar (cttLoot · Player DPS Delta Viewer) + ⚙ cog → right-side drawer
--   Drawer: Import Data / Import DB / Simulate Loot panels
--   Main: filter bar (Boss ▾ · sep · Item ▾ · stats) + card grid scroll area
--   Each card: dark header (item name + boss), ranked rows: [rank][name][bar][dps]
--   Card header click → single-item full view (all players, no row limit)

cttLoot_UI = {}

-- ── Layout constants ──────────────────────────────────────────────────────────
local WIN_W      = 920
local WIN_H      = 680
local TITLE_H    = 26        -- matches HTML titlebar 34px → ~26 in WoW units
local DRAWER_W   = 340       -- HTML drawer 420px scaled
local PANEL_HDR  = 22        -- section header height in drawer
local PAD        = 8
local CARD_W     = 250       -- HTML .ov-card min-width 220px
local CARD_GAP   = 6
local ROW_H      = 18        -- ov-table row height
local BAR_W      = 72        -- ov-bar-cell width
local BAR_H      = 8         -- ov-bar height
local COL_RANK   = 22        -- rank badge column
local COL_NAME   = 86        -- player name column
local COL_BAR    = BAR_W + 4
local COL_DPS    = 60
local FBAR_H     = 26        -- filter bar height
local DD_ROW_H   = 20        -- dropdown row height

-- ── Colour palette matching HTML :root vars ───────────────────────────────────
local C = {
    bg          = {0.090, 0.090, 0.090},  -- #171717
    bg2         = {0.118, 0.118, 0.118},  -- #1e1e1e
    bg3         = {0.067, 0.067, 0.067},  -- #111
    bg_title    = {0.075, 0.075, 0.075},  -- #131313
    bg_hdr      = {0.102, 0.102, 0.102},  -- #1a1a1a
    border      = {0.200, 0.200, 0.200},  -- #333
    accent      = {0.243, 0.490, 0.753},  -- #3E7DC0
    accent2     = {0.180, 0.369, 0.569},  -- #2e5e91
    text        = {0.898, 0.898, 0.898},  -- #e5e5e5
    text_dim    = {0.533, 0.533, 0.533},  -- #888
    text_hi     = {1.000, 1.000, 1.000},
    green       = {0.329, 0.682, 0.329},  -- #54ae54
    red         = {0.780, 0.251, 0.251},  -- #c74040
    catalyst    = {0.608, 0.349, 0.816},  -- #9b59d0
    rank_gold   = {0.831, 0.659, 0.263},  -- #d4a843
    rank_silver = {0.753, 0.753, 0.753},  -- #c0c0c0
    rank_bronze = {0.722, 0.451, 0.200},  -- #b87333
}

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ── UI state ──────────────────────────────────────────────────────────────────
local window        = nil
local drawer        = nil
local drawerOpen    = false
local cardScrollF   = nil    -- ScrollFrame for card grid
local cardContent   = nil    -- content frame inside scroll
local cardPool      = {}     -- reuse frames: cardPool[i] = frame
local activeCards   = 0

cttLoot_UI.selectedBoss  = nil
cttLoot_UI.selectedItem  = nil
cttLoot_UI.lootFilter    = nil

-- dropdown state
local bossDdOpen  = false
local itemDdOpen  = false
local bossDdFrame = nil
local itemDdFrame = nil
local bossDdRows  = {}
local itemDdRows  = {}

-- label fontstrings (filter bar)
local bossDdLabel  = nil
local itemDdLabel  = nil
local bossClearBtn = nil
local itemClearBtn = nil
local statsLabel   = nil

-- paste edit boxes
local csvEB = nil
local dbEB  = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function RGB(t) return t[1], t[2], t[3] end

local function Hex(t)
    return string.format("%02x%02x%02x",
        math.floor(t[1]*255+0.5), math.floor(t[2]*255+0.5), math.floor(t[3]*255+0.5))
end

local function Clr(t, s)  -- |cffRRGGBBstring|r
    return "|cff"..Hex(t)..s.."|r"
end

local function FlatTex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetTexture(WHITE)
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

local function Bg(parent, col, layer)
    local t = FlatTex(parent, layer or "BACKGROUND", RGB(col))
    t:SetAllPoints(parent)
    return t
end

local function PixelBorder(frame, col, a)
    local r, g, b
    if col then r, g, b = RGB(col) else r, g, b = RGB(C.border) end
    a = a or 1
    local function L(p1, p2, vert)
        local t = frame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(WHITE); t:SetVertexColor(r, g, b, a)
        if vert then t:SetWidth(1) else t:SetHeight(1) end
        local ox1 = p1:find("RIGHT") and 1 or -1
        local oy1 = p1:find("TOP")   and 1 or -1
        local ox2 = p2:find("RIGHT") and 1 or -1
        local oy2 = p2:find("TOP")   and 1 or -1
        t:SetPoint(p1, frame, p1, ox1, oy1)
        t:SetPoint(p2, frame, p2, ox2, oy2)
    end
    L("TOPLEFT",    "TOPRIGHT",    false)
    L("BOTTOMLEFT", "BOTTOMRIGHT", false)
    L("TOPLEFT",    "BOTTOMLEFT",  true)
    L("TOPRIGHT",   "BOTTOMRIGHT", true)
end

local function AccentLeft(parent)
    -- 2px left accent bar (.panel-header::before, .filter-bar::before)
    local t = FlatTex(parent, "OVERLAY", RGB(C.accent))
    t:SetWidth(2)
    t:SetPoint("TOPLEFT",    parent, "TOPLEFT",    0, 0)
    t:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
end

-- ── Button factory ────────────────────────────────────────────────────────────
-- style: "primary" | "danger" | nil (default)
local function Btn(parent, label, w, h, style)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w or 80, h or 20)
    local nr, ng, nb  -- normal bg
    if style == "primary" then
        nr, ng, nb = RGB(C.accent2)
    elseif style == "danger" then
        nr, ng, nb = 0.18, 0.06, 0.06
    else
        nr, ng, nb = RGB(C.bg3)
    end
    local bg = FlatTex(btn, "BACKGROUND", nr, ng, nb)
    bg:SetAllPoints(btn)
    btn._bg = bg
    PixelBorder(btn, C.border)

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints(btn); fs:SetJustifyH("CENTER")
    local tr, tg, tb
    if style == "primary" then tr, tg, tb = RGB(C.text_hi) else tr, tg, tb = RGB(C.text) end
    fs:SetTextColor(tr, tg, tb)
    fs:SetText(label or "")
    btn._label = fs

    btn:SetScript("OnEnter",    function() bg:SetVertexColor(RGB(C.accent2)); fs:SetTextColor(RGB(C.text_hi)) end)
    btn:SetScript("OnLeave",    function() bg:SetVertexColor(nr, ng, nb);     fs:SetTextColor(tr, tg, tb)    end)
    btn:SetScript("OnMouseDown",function() bg:SetVertexColor(RGB(C.accent));  fs:SetTextColor(RGB(C.text_hi)) end)
    btn:SetScript("OnMouseUp",  function() bg:SetVertexColor(nr, ng, nb);     fs:SetTextColor(tr, tg, tb)    end)
    return btn
end

-- Scrollable multi-line EditBox helper
local function ScrollEB(parent, w, h)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetSize(w, h)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)  -- 0 = unlimited (default is 255)
    eb:SetFontObject("GameFontNormalSmall")
    eb:SetTextColor(RGB(C.text))
    eb:SetWidth(w - 20)
    local ebBg = FlatTex(eb, "BACKGROUND", RGB(C.bg3))
    ebBg:SetAllPoints(eb)
    PixelBorder(eb, C.border)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    sf:SetScrollChild(eb)
    return sf, eb
end

-- ── Close all dropdowns ───────────────────────────────────────────────────────
local function CloseDropdowns()
    bossDdOpen = false; itemDdOpen = false
    if bossDdFrame then bossDdFrame:Hide() end
    if itemDdFrame then itemDdFrame:Hide() end
    if bossDdSearch then bossDdSearch:ClearFocus() end
    if itemDdSearch then itemDdSearch:ClearFocus() end
end

-- ── Drawer (settings panel, slides in from right) ─────────────────────────────
local drawerSections = {}  -- { header, body, open }

local function MakeDrawerSection(parent, title, yOff)
    local sec = {}

    local hdr = CreateFrame("Button", nil, parent)
    hdr:SetHeight(PANEL_HDR)
    hdr:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yOff)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOff)
    Bg(hdr, C.bg_hdr)
    AccentLeft(hdr)

    local lbl = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", hdr, "LEFT", 10, 0)
    lbl:SetTextColor(RGB(C.text_hi)); lbl:SetText(title)

    local arrow = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", hdr, "RIGHT", -6, 0)
    arrow:SetTextColor(RGB(C.text_dim)); arrow:SetText("▶")

    -- divider under header
    local div = FlatTex(parent, "BACKGROUND", RGB(C.border))
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  hdr, "BOTTOMLEFT",  0, 0)
    div:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, 0)

    local body = CreateFrame("Frame", nil, parent)
    body:SetPoint("TOPLEFT",  hdr, "BOTTOMLEFT",  0, -1)
    body:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -1)
    Bg(body, C.bg3)
    body:Hide()

    sec.hdr   = hdr
    sec.body  = body
    sec.arrow = arrow
    sec.open  = false

    hdr:SetScript("OnClick", function()
        sec.open = not sec.open
        if sec.open then body:Show(); arrow:SetText("▼")
        else             body:Hide(); arrow:SetText("▶") end
        -- Restack other sections below
        cttLoot_UI:RepositionDrawer()
    end)

    hdr:SetScript("OnEnter", function() hdr._bg:SetVertexColor(0.14, 0.14, 0.14) end)
    hdr:SetScript("OnLeave", function() hdr._bg:SetVertexColor(RGB(C.bg_hdr)) end)
    hdr._bg = Bg(hdr, C.bg_hdr)   -- re-assign so hover works; ok to overwrite

    table.insert(drawerSections, sec)
    return sec
end

-- Reposition all drawer sections after toggling one
function cttLoot_UI:RepositionDrawer()
    local y = -PAD
    for _, sec in ipairs(drawerSections) do
        sec.hdr:ClearAllPoints()
        sec.hdr:SetPoint("TOPLEFT",  drawer, "TOPLEFT",  PAD, y)
        sec.hdr:SetPoint("TOPRIGHT", drawer, "TOPRIGHT", -PAD, y)
        y = y - PANEL_HDR - 1  -- header + divider
        if sec.open then
            sec.body:ClearAllPoints()
            sec.body:SetPoint("TOPLEFT",  drawer, "TOPLEFT",  PAD, y)
            sec.body:SetPoint("TOPRIGHT", drawer, "TOPRIGHT", -PAD, y)
            y = y - sec.body:GetHeight() - PAD
        end
    end
end

-- Build the right-side drawer
local function BuildDrawer(parent)
    local d = CreateFrame("Frame", nil, parent)
    d:SetSize(DRAWER_W, WIN_H)
    d:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    d:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    d:SetFrameLevel(parent:GetFrameLevel() + 10)
    Bg(d, C.bg2)
    PixelBorder(d, C.border)

    -- Drawer title bar
    local dtb = CreateFrame("Frame", nil, d)
    dtb:SetHeight(TITLE_H)
    dtb:SetPoint("TOPLEFT"); dtb:SetPoint("TOPRIGHT")
    Bg(dtb, C.bg_title)
    local accentLine = FlatTex(d, "ARTWORK", RGB(C.accent))
    accentLine:SetHeight(1)
    accentLine:SetPoint("TOPLEFT",  dtb, "BOTTOMLEFT",  0, 0)
    accentLine:SetPoint("TOPRIGHT", dtb, "BOTTOMRIGHT", 0, 0)

    local dtitle = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dtitle:SetPoint("LEFT", dtb, "LEFT", 10, 0)
    dtitle:SetTextColor(RGB(C.text_hi))
    dtitle:SetText("Settings")

    local closeX = Btn(d, "X", 22, 18, "danger")
    closeX:SetPoint("RIGHT", dtb, "RIGHT", -4, 0)
    closeX:SetScript("OnClick", function()
        d:Hide(); drawerOpen = false
    end)

    d:Hide()
    return d
end

-- ── Import Parse Data section ─────────────────────────────────────────────────
local function BuildImportSection(drawer_)
    drawerSections = {}  -- reset on build
    local sec = MakeDrawerSection(drawer_, "Import Parse Data", -(TITLE_H + PAD + 2))
    sec.open = true
    sec.arrow:SetText("▼")
    sec.body:Show()
    sec.body:SetHeight(138)

    local sf, eb = ScrollEB(sec.body, sec.body:GetWidth() - 4, 90)
    sf:SetPoint("TOPLEFT",  sec.body, "TOPLEFT",  2, -PAD)
    sf:SetPoint("TOPRIGHT", sec.body, "TOPRIGHT", -2, -PAD)
    csvEB = eb
    -- Don't try to restore raw CSV into the editbox — data is loaded directly from lastData

    local loadBtn = Btn(sec.body, "Load Data",   76, 20, "primary")
    loadBtn:SetPoint("BOTTOMLEFT", sec.body, "BOTTOMLEFT", 2, PAD)
    loadBtn:SetScript("OnClick", function()
        local raw = eb:GetText()
        if not raw or raw == "" then return end
        local data, err = cttLoot:ParseCSV(raw)
        if not data then cttLoot:Print("Parse error: "..(err or "?")); return end
        cttLoot:ApplyData(data)
        -- Save parsed data directly — bypasses editbox size limits entirely
        cttLootDB.lastData = { itemNames=data.itemNames, playerNames=data.playerNames, matrix=data.matrix }
        cttLoot:Print(string.format("Loaded %d items x %d players.", #data.itemNames, #data.playerNames))
        cttLoot_UI:Refresh()
    end)

    local sendBtn = Btn(sec.body, "Send to Raid", 88, 20)
    sendBtn:SetPoint("LEFT", loadBtn, "RIGHT", 4, 0)
    sendBtn:SetScript("OnClick", function()
        if #cttLoot.itemNames == 0 then cttLoot:Print("Load data first."); return end
        cttLoot:Broadcast()
    end)

    local clearBtn = Btn(sec.body, "Clear", 54, 20, "danger")
    clearBtn:SetPoint("LEFT", sendBtn, "RIGHT", 4, 0)
    clearBtn:SetScript("OnClick", function()
        eb:SetText("")
        cttLootDB.lastData = nil
        cttLoot:ApplyData({ itemNames={}, playerNames={}, matrix={} })
        cttLoot_UI.selectedBoss = nil
        cttLoot_UI.selectedItem = nil
        cttLoot_UI.lootFilter   = nil
        cttLoot_UI:Refresh()
        cttLoot:Print("Cleared.")
    end)

    return sec
end

-- ── Import DB section ─────────────────────────────────────────────────────────
local function BuildDBSection()
    local sec = MakeDrawerSection(drawer, "Import Item Database", 0)
    sec.body:SetHeight(110)

    local sf, eb = ScrollEB(sec.body, sec.body:GetWidth() - 4, 64)
    sf:SetPoint("TOPLEFT",  sec.body, "TOPLEFT",  2, -PAD)
    sf:SetPoint("TOPRIGHT", sec.body, "TOPRIGHT", -2, -PAD)
    dbEB = eb

    local impBtn = Btn(sec.body, "Import", 64, 20, "primary")
    impBtn:SetPoint("BOTTOMLEFT", sec.body, "BOTTOMLEFT", 2, PAD)
    impBtn:SetScript("OnClick", function()
        local raw = eb:GetText()
        if not raw or raw == "" then return end
        local entries = cttLoot:ParseDBRaw(raw)
        local n = 0
        for id, e in pairs(entries) do cttLoot.DB[id]=e; cttLootDB.customDB[id]=e; n=n+1 end
        cttLoot:MergeCustomDB()
        cttLoot:Print(string.format("Imported %d DB entries.", n))
        cttLoot_UI:Refresh()
    end)

    local appBtn = Btn(sec.body, "Append", 64, 20)
    appBtn:SetPoint("LEFT", impBtn, "RIGHT", 4, 0)
    appBtn:SetScript("OnClick", function()
        local raw = eb:GetText()
        if not raw or raw == "" then return end
        local entries = cttLoot:ParseDBRaw(raw)
        local n = 0
        for id, e in pairs(entries) do
            if not cttLoot.DB[id] then cttLoot.DB[id]=e; cttLootDB.customDB[id]=e; n=n+1 end
        end
        cttLoot:MergeCustomDB()
        cttLoot:Print(string.format("Appended %d new DB entries.", n))
        cttLoot_UI:Refresh()
    end)

    local sendBtn = Btn(sec.body, "Send to Raid", 88, 20)
    sendBtn:SetPoint("LEFT", appBtn, "RIGHT", 4, 0)
    sendBtn:SetScript("OnClick", function() cttLoot:BroadcastDB() end)

    local clrBtn = Btn(sec.body, "Clear DB", 68, 20, "danger")
    clrBtn:SetPoint("LEFT", sendBtn, "RIGHT", 4, 0)
    clrBtn:SetScript("OnClick", function()
        cttLootDB.customDB = {}
        wipe(cttLoot.DB); wipe(cttLoot.DBByName); wipe(cttLoot.DBByBoss)
        cttLoot:Print("Item DB cleared.")
        cttLoot_UI:Refresh()
    end)

    return sec
end


-- ── Filter bar ────────────────────────────────────────────────────────────────
-- Returns the filter bar frame; sets module-level label/button refs.
local function BuildFilterBar(parent, topAnchor)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(FBAR_H)
    bar:SetPoint("TOPLEFT",  topAnchor, "BOTTOMLEFT",  0, -PAD)
    bar:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -PAD)
    Bg(bar, C.bg2)
    PixelBorder(bar, C.border)
    AccentLeft(bar)

    local x = 10

    -- "Boss" label
    local bossLbl = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossLbl:SetPoint("LEFT", bar, "LEFT", x, 0)
    bossLbl:SetTextColor(RGB(C.text_dim)); bossLbl:SetText("Boss")
    x = x + bossLbl:GetStringWidth() + 6

    -- Boss dropdown button
    local bossBtn = Btn(bar, "", 150, 20)
    bossBtn:SetPoint("LEFT", bar, "LEFT", x, 0)
    bossDdLabel = bossBtn._label
    bossDdLabel:SetText("Boss")
    bossDdLabel:SetJustifyH("LEFT")

    -- Arrow on right of boss button
    local bossArrow = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossArrow:SetPoint("RIGHT", bossBtn, "RIGHT", -4, 0)
    bossArrow:SetTextColor(RGB(C.text_dim)); bossArrow:SetText("▾")

    -- Boss clear (✕) button
    bossClearBtn = Btn(bar, "X", 16, 16, "danger")
    bossClearBtn:SetPoint("LEFT", bossBtn, "RIGHT", 2, 0)
    bossClearBtn:Hide()
    bossClearBtn:SetScript("OnClick", function()
        cttLoot_UI:SetBossFilter(nil)
    end)
    cttLoot_UI.bossClearBtn = bossClearBtn

    x = x + 150 + 18 + 4

    -- Separator
    local sep1 = FlatTex(bar, "ARTWORK", RGB(C.border))
    sep1:SetSize(1, 16)
    sep1:SetPoint("LEFT", bar, "LEFT", x, 0)
    x = x + 8

    -- "Item" label
    local itemLbl = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemLbl:SetPoint("LEFT", bar, "LEFT", x, 0)
    itemLbl:SetTextColor(RGB(C.text_dim)); itemLbl:SetText("Item")
    x = x + itemLbl:GetStringWidth() + 6

    -- Item dropdown button
    local itemBtn = Btn(bar, "", 180, 20)
    itemBtn:SetPoint("LEFT", bar, "LEFT", x, 0)
    itemDdLabel = itemBtn._label
    itemDdLabel:SetText("Item")
    itemDdLabel:SetJustifyH("LEFT")

    local itemArrow = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemArrow:SetPoint("RIGHT", itemBtn, "RIGHT", -4, 0)
    itemArrow:SetTextColor(RGB(C.text_dim)); itemArrow:SetText("▾")

    -- Item clear button
    itemClearBtn = Btn(bar, "X", 16, 16, "danger")
    itemClearBtn:SetPoint("LEFT", itemBtn, "RIGHT", 2, 0)
    itemClearBtn:Hide()
    itemClearBtn:SetScript("OnClick", function()
        cttLoot_UI.selectedItem = nil
        itemDdLabel:SetText("Item")
        itemClearBtn:Hide()
        cttLoot_UI:Refresh()
    end)
    cttLoot_UI.itemClearBtn = itemClearBtn

    -- Stats label (right side, matching .stats-badge)
    statsLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsLabel:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    statsLabel:SetTextColor(RGB(C.text_dim))
    cttLoot_UI.statsLabel = statsLabel

    -- ── Boss dropdown panel ──
    bossDdFrame = CreateFrame("Frame", nil, bar)
    bossDdFrame:SetWidth(218)
    bossDdFrame:SetPoint("TOPLEFT", bossBtn, "BOTTOMLEFT", 0, -2)
    bossDdFrame:SetFrameLevel(bar:GetFrameLevel() + 20)
    Bg(bossDdFrame, C.bg2)
    PixelBorder(bossDdFrame, C.accent)
    bossDdFrame:Hide()

    -- ── Item dropdown panel ──
    itemDdFrame = CreateFrame("Frame", nil, bar)
    itemDdFrame:SetWidth(238)
    itemDdFrame:SetPoint("TOPLEFT", itemBtn, "BOTTOMLEFT", 0, -2)
    itemDdFrame:SetFrameLevel(bar:GetFrameLevel() + 20)
    Bg(itemDdFrame, C.bg2)
    PixelBorder(itemDdFrame, C.accent)
    itemDdFrame:Hide()

    -- Wire up boss button click
    bossBtn:SetScript("OnClick", function()
        if bossDdOpen then CloseDropdowns(); return end
        CloseDropdowns()
        bossDdOpen = true
        cttLoot_UI:PopulateBossDropdown()
        bossDdFrame:Show()
    end)

    -- Wire up item button click
    itemBtn:SetScript("OnClick", function()
        if itemDdOpen then CloseDropdowns(); return end
        CloseDropdowns()
        itemDdOpen = true
        cttLoot_UI:PopulateItemDropdown()
        itemDdFrame:Show()
    end)

    -- Close dropdowns when clicking elsewhere on main window
    parent:SetScript("OnMouseDown", function(_, btn_)
        if btn_ == "LeftButton" then CloseDropdowns() end
    end)

    return bar
end

-- ── Card grid (ScrollFrame) ───────────────────────────────────────────────────
local function BuildCardArea(parent, topAnchor)
    cardScrollF = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    cardScrollF:SetPoint("TOPLEFT",     topAnchor, "BOTTOMLEFT",  0, -PAD)
    cardScrollF:SetPoint("BOTTOMRIGHT", parent,    "BOTTOMRIGHT", -18, PAD)

    Bg(cardScrollF, C.bg3)
    PixelBorder(cardScrollF, C.border)

    cardContent = CreateFrame("Frame", nil, cardScrollF)
    cardContent:SetWidth(cardScrollF:GetWidth())
    cardContent:SetHeight(1)
    cardScrollF:SetScrollChild(cardContent)
end

-- ── Card rendering ────────────────────────────────────────────────────────────
local function IsCatalyst(name)
    return name:upper():sub(-9) == " CATALYST"
end

local function CatColFor(name)
    local cat = name .. " CATALYST"
    for i, n in ipairs(cttLoot.itemNames) do
        if n == cat then return i end
    end
    return nil
end

local function GetItemPool()
    local pool = {}
    local source
    if cttLoot_UI.lootFilter then
        source = cttLoot_UI.lootFilter
    elseif cttLoot_UI.selectedItem then
        -- single-item view: only one item
        return { cttLoot_UI.selectedItem }
    elseif cttLoot_UI.selectedBoss then
        source = cttLoot_UI:GetVisibleItemsForBoss(cttLoot_UI.selectedBoss)
    else
        source = cttLoot.itemNames
    end
    for _, n in ipairs(source) do
        if not IsCatalyst(n) then table.insert(pool, n) end
    end
    return pool
end

-- Build one card frame for `itemName` at position (ox, oy) relative to cardContent
-- Returns the card frame (or nil) and its total height.
local function MakeCard(itemName, ox, oy, limit)
    -- Find column index
    local ci = nil
    for i, n in ipairs(cttLoot.itemNames) do
        if n == itemName then ci = i; break end
    end
    if not ci then return nil, 0 end

    local catCi = CatColFor(itemName)

    -- Gather entries
    local entries = {}
    for r, player in ipairs(cttLoot.playerNames) do
        local row = cttLoot.matrix[r]
        local base = row and row[ci]
        local cat  = catCi and row and row[catCi]
        if base then table.insert(entries, { player=player, dps=base, isCat=false }) end
        if cat  then table.insert(entries, { player=player, dps=cat,  isCat=true  }) end
    end
    table.sort(entries, function(a,b) return a.dps > b.dps end)

    if limit and limit > 0 then
        while #entries > limit do table.remove(entries) end
    end

    local maxAbs = 1
    for _, e in ipairs(entries) do
        if math.abs(e.dps) > maxAbs then maxAbs = math.abs(e.dps) end
    end

    -- Card layout
    local info     = cttLoot:GetItemInfo(itemName)
    local hasBoss  = info and info.boss
    local hdrH     = hasBoss and 32 or 20  -- two-line header if boss known
    local cardH    = hdrH + #entries * ROW_H + 2

    local card = CreateFrame("Frame", nil, cardContent)
    card:SetSize(CARD_W, cardH)
    card:SetPoint("TOPLEFT", cardContent, "TOPLEFT", ox, -oy)

    Bg(card, C.bg2)
    PixelBorder(card, C.border)

    -- Header button (clicking zooms to single-item view)
    local hdr = CreateFrame("Button", nil, card)
    hdr:SetHeight(hdrH)
    hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
    local hdrBg = Bg(hdr, C.bg3)

    -- Item name (.ov-title)
    local titleFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT", hdr, "TOPLEFT", 6, -5)
    titleFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -5)
    titleFS:SetTextColor(RGB(C.text_hi))
    titleFS:SetText(itemName)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(false)

    -- Boss sub-label (.ov-boss — accent blue, smaller)
    if hasBoss then
        local bossFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bossFS:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 6, 4)
        bossFS:SetTextColor(RGB(C.accent))
        bossFS:SetText(info.boss)
        bossFS:SetJustifyH("LEFT")
    end

    hdr:SetScript("OnEnter", function() hdrBg:SetVertexColor(RGB(C.accent2)) end)
    hdr:SetScript("OnLeave", function() hdrBg:SetVertexColor(RGB(C.bg3))    end)
    hdr:SetScript("OnClick", function()
        CloseDropdowns()
        if cttLoot_UI.selectedItem == itemName then
            -- clicking same item header → go back to overview
            cttLoot_UI.selectedItem = nil
            if itemDdLabel then itemDdLabel:SetText("Item") end
            if itemClearBtn then itemClearBtn:Hide() end
        else
            cttLoot_UI.selectedItem = itemName
            if itemDdLabel then itemDdLabel:SetText(itemName) end
            if itemClearBtn then itemClearBtn:Show() end
        end
        cttLoot_UI:Refresh()
    end)

    -- Rows
    for i, e in ipairs(entries) do
        local ry = hdrH + (i-1) * ROW_H

        -- Alternating row tint (matching tbody tr:nth-child(even))
        if i % 2 == 0 then
            local rowBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.025)
            rowBg:SetSize(CARD_W, ROW_H)
            rowBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
        end

        -- Rank badge (.ov-rank)
        local rankFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rankFS:SetSize(COL_RANK, ROW_H)
        rankFS:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -ry)
        rankFS:SetJustifyH("CENTER"); rankFS:SetJustifyV("MIDDLE")
        if     i == 1 then rankFS:SetTextColor(RGB(C.rank_gold))
        elseif i == 2 then rankFS:SetTextColor(RGB(C.rank_silver))
        elseif i == 3 then rankFS:SetTextColor(RGB(C.rank_bronze))
        else               rankFS:SetTextColor(RGB(C.text_dim)) end
        rankFS:SetText(tostring(i))

        -- Player name (.ov-name) + optional (cat)
        local nameFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFS:SetSize(COL_NAME, ROW_H)
        nameFS:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + 2, -ry)
        nameFS:SetJustifyH("LEFT"); nameFS:SetJustifyV("MIDDLE")
        if e.isCat then
            nameFS:SetText(e.player .. " " .. Clr(C.catalyst, "(cat)"))
            nameFS:SetTextColor(RGB(C.text))
        else
            nameFS:SetTextColor(RGB(C.text))
            nameFS:SetText(e.player)
        end

        -- Bar background (.ov-bar-wrap)
        local barBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.06)
        barBg:SetSize(BAR_W, BAR_H)
        barBg:SetPoint("TOPLEFT", card, "TOPLEFT",
            COL_RANK + COL_NAME + 2, -ry - (ROW_H - BAR_H) / 2)

        -- Bar fill (.ov-bar)
        local barPct = math.max(0.01, math.abs(e.dps) / maxAbs)
        local fillW  = math.max(2, math.floor(barPct * BAR_W))
        local barFill = FlatTex(card, "ARTWORK", 1, 1, 1, 0.85)
        barFill:SetSize(fillW, BAR_H)
        barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 0, 0)
        if e.isCat then
            barFill:SetVertexColor(RGB(C.catalyst))
        elseif e.dps >= 0 then
            barFill:SetVertexColor(RGB(C.green))
        else
            barFill:SetVertexColor(RGB(C.red))
        end

        -- DPS value (.ov-dps)
        local dpsFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dpsFS:SetSize(COL_DPS, ROW_H)
        dpsFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -ry)
        dpsFS:SetJustifyH("RIGHT"); dpsFS:SetJustifyV("MIDDLE")
        local sign = e.dps >= 0 and "+" or ""
        dpsFS:SetText(string.format("%s%.0f", sign, e.dps))
        if e.isCat then
            dpsFS:SetTextColor(RGB(C.catalyst))
        elseif e.dps >= 0 then
            dpsFS:SetTextColor(RGB(C.green))
        else
            dpsFS:SetTextColor(RGB(C.red))
        end

        -- Row separator line
        if i < #entries then
            local sep = FlatTex(card, "BACKGROUND", RGB(C.bg_hdr))
            sep:SetHeight(1)
            sep:SetPoint("BOTTOMLEFT",  card, "TOPLEFT",  0, -(ry + ROW_H - 1))
            sep:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", 0, -(ry + ROW_H - 1))
        end
    end

    return card, cardH
end

-- Destroy all current card frames
local function ClearCards()
    for _, c in ipairs(cardPool) do
        c:Hide()
        c:SetParent(nil)
    end
    cardPool = {}
    activeCards = 0
    -- Also remove orphaned font strings / textures via SetHeight(1) reset
    cardContent:SetHeight(1)
end

-- Re-lay out the card grid
local function PopulateGrid()
    ClearCards()

    local pool = GetItemPool()

    if #pool == 0 then
        local empty = cardContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        empty:SetPoint("TOP", cardContent, "TOP", 0, -50)
        empty:SetTextColor(RGB(C.text_dim))
        if #cttLoot.playerNames == 0 then
            empty:SetText("Open Settings > Import Parse Data, paste CSV, then click Load Data")
        else
            empty:SetText("No items match current filter")
        end
        cardContent:SetHeight(120)

        if statsLabel then statsLabel:SetText("") end
        return
    end

    -- In single-item view show all rows; otherwise cap at 10 (matching HTML limit 10)
    local rowLimit = cttLoot_UI.selectedItem and 0 or 10

    local gridW = cardScrollF:GetWidth() - 4
    local cols  = math.max(1, math.floor((gridW + CARD_GAP) / (CARD_W + CARD_GAP)))
    local col, totalH, rowMaxH = 0, PAD, 0

    for _, name in ipairs(pool) do
        local ox = PAD + col * (CARD_W + CARD_GAP)
        local oy = totalH
        local card, cardH = MakeCard(name, ox, oy, rowLimit)
        if card then
            table.insert(cardPool, card)
            activeCards = activeCards + 1
            if cardH > rowMaxH then rowMaxH = cardH end
        end
        col = col + 1
        if col >= cols then
            col = 0
            totalH = totalH + rowMaxH + CARD_GAP
            rowMaxH = 0
        end
    end
    if col > 0 then totalH = totalH + rowMaxH + CARD_GAP end

    cardContent:SetWidth(gridW)
    cardContent:SetHeight(math.max(totalH, 80))

    -- Update stats badge
    if statsLabel then
        local bossStr = cttLoot_UI.selectedBoss
            and (Clr(C.accent, "·") .. " " .. cttLoot_UI.selectedBoss .. "  ") or ""
        statsLabel:SetText(string.format("%s%d items  " .. Clr(C.accent, "·") .. "  %d players",
            bossStr, #pool, #cttLoot.playerNames))
    end
end

-- ── Shared: build search box + scrollable list inside a dd frame ─────────────
-- Returns: searchEB, listFrame, listContent
-- The caller populates listContent and sets its height.
local DD_SEARCH_H = 22
local DD_MAX_LIST = 220  -- max height of the scrollable list area

local function BuildDdSearchAndList(ddFrame, ddW)
    -- Search box (matching HTML .dd-search)
    local searchEB = CreateFrame("EditBox", nil, ddFrame)
    searchEB:SetHeight(DD_SEARCH_H)
    searchEB:SetPoint("TOPLEFT",  ddFrame, "TOPLEFT",  2,  -2)
    searchEB:SetPoint("TOPRIGHT", ddFrame, "TOPRIGHT", -2, -2)
    searchEB:SetAutoFocus(false)
    searchEB:SetFontObject("GameFontNormalSmall")
    searchEB:SetTextColor(RGB(C.text))
    searchEB:SetTextInsets(6, 6, 0, 0)
    searchEB:SetScript("OnEscapePressed", function(s)
        s:SetText(""); s:ClearFocus()
    end)
    local searchBg = FlatTex(searchEB, "BACKGROUND", RGB(C.bg3))
    searchBg:SetAllPoints(searchEB)
    -- bottom border line (matches .dd-search border-bottom)
    local searchDiv = FlatTex(ddFrame, "OVERLAY", RGB(C.border))
    searchDiv:SetHeight(1)
    searchDiv:SetPoint("TOPLEFT",  searchEB, "BOTTOMLEFT",  0, 0)
    searchDiv:SetPoint("TOPRIGHT", searchEB, "BOTTOMRIGHT", 0, 0)

    local placeholder = searchEB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    placeholder:SetAllPoints(searchEB)
    placeholder:SetTextColor(0.27, 0.27, 0.27)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetText("Search…")
    placeholder:SetPoint("LEFT", searchEB, "LEFT", 6, 0)

    searchEB:SetScript("OnTextChanged", function(s)
        placeholder:SetShown(s:GetText() == "")
    end)

    -- Scroll frame for the list
    local listSF = CreateFrame("ScrollFrame", nil, ddFrame, "UIPanelScrollFrameTemplate")
    listSF:SetPoint("TOPLEFT",  ddFrame, "TOPLEFT",  0, -(DD_SEARCH_H + 4))
    listSF:SetPoint("TOPRIGHT", ddFrame, "TOPRIGHT", -16, -(DD_SEARCH_H + 4))

    local listContent = CreateFrame("Frame", nil, listSF)
    -- Width = ddFrame width minus scrollbar (16px) minus 2px padding each side
    listContent:SetWidth(ddW - 16)
    listContent:SetHeight(1)
    listSF:SetScrollChild(listContent)

    return searchEB, listSF, listContent
end

-- Populate a list content frame with rows, filtered by query string.
-- rows is array of { label, onSelect, selected }
-- listW is the explicit pixel width for row buttons.
-- Returns total height used.
local function FillDdList(listContent, listW, rows, query)
    -- Clear old children (frames + buttons)
    for _, child in ipairs({ listContent:GetChildren() }) do
        child:Hide(); child:SetParent(nil)
    end
    -- Also clear any regions (fontstrings / textures) created directly
    for _, region in ipairs({ listContent:GetRegions() }) do
        region:Hide()
    end

    local q   = query and query:lower() or ""
    local y   = 0
    local any = false
    for _, row in ipairs(rows) do
        local label = row.label
        if q == "" or label:lower():find(q, 1, true) then
            local btn = Btn(listContent, label, listW, DD_ROW_H)
            btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
            if row.selected then btn._bg:SetVertexColor(RGB(C.accent2)) end
            local cb = row.onSelect
            btn:SetScript("OnClick", cb)
            y   = y + DD_ROW_H + 1
            any = true
        end
    end
    if not any then
        local empty = listContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", listContent, "TOPLEFT", 8, -6)
        empty:SetTextColor(RGB(C.text_dim))
        empty:SetText(q ~= "" and "No match" or "—")
        y = y + 20
    end
    listContent:SetHeight(math.max(y, 1))
    return y
end

-- Boss search state
local bossDdSearch   = nil
local bossDdListSF   = nil
local bossDdListC    = nil
local bossDdAllRows  = {}  -- cached full row descriptors

-- Item search state
local itemDdSearch   = nil
local itemDdListSF   = nil
local itemDdListC    = nil
local itemDdAllRows  = {}

-- ── Boss dropdown population ──────────────────────────────────────────────────
function cttLoot_UI:PopulateBossDropdown()
    if not bossDdFrame then return end

    -- Build search + list on first call
    if not bossDdSearch then
        bossDdSearch, bossDdListSF, bossDdListC =
            BuildDdSearchAndList(bossDdFrame, 196)
        bossDdSearch:SetScript("OnTextChanged", function(s)
            local txt = s:GetText()
            local lW = bossDdFrame:GetWidth() - 18
            local h = FillDdList(bossDdListC, lW, bossDdAllRows, txt)
            local listH = math.min(h, DD_MAX_LIST)
            bossDdListSF:SetHeight(listH)
            bossDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
        end)
    end

    -- Build row descriptors
    bossDdAllRows = {}
    for _, bossName in ipairs(cttLoot:GetAllBosses()) do
        local bName = bossName
        table.insert(bossDdAllRows, {
            label    = bossName,
            selected = (self.selectedBoss == bossName),
            onSelect = function() self:SetBossFilter(bName); CloseDropdowns() end,
        })
    end
    if #bossDdAllRows == 1 then
        -- only "All Bosses" — add empty notice
        table.insert(bossDdAllRows, {
            label    = "Database empty — import items first",
            selected = false,
            onSelect = function() end,
        })
    end

    bossDdSearch:SetText("")
    local listW = bossDdFrame:GetWidth() - 18
    local h = FillDdList(bossDdListC, listW, bossDdAllRows, "")
    local listH = math.min(h, DD_MAX_LIST)
    bossDdListSF:SetHeight(listH)
    bossDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
    bossDdSearch:SetFocus()
end

-- ── Item dropdown population ──────────────────────────────────────────────────
function cttLoot_UI:PopulateItemDropdown()
    if not itemDdFrame then return end

    if not itemDdSearch then
        itemDdSearch, itemDdListSF, itemDdListC =
            BuildDdSearchAndList(itemDdFrame, 216)
        itemDdSearch:SetScript("OnTextChanged", function(s)
            local txt = s:GetText()
            local lW = itemDdFrame:GetWidth() - 18
            local h = FillDdList(itemDdListC, lW, itemDdAllRows, txt)
            local listH = math.min(h, DD_MAX_LIST)
            itemDdListSF:SetHeight(listH)
            itemDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
        end)
    end

    local pool = GetItemPool()
    itemDdAllRows = {}
    if #pool == 0 then
        table.insert(itemDdAllRows, {
            label    = "No items loaded",
            selected = false,
            onSelect = function() end,
        })
    else
        for _, name in ipairs(pool) do
            local iName = name
            table.insert(itemDdAllRows, {
                label    = name,
                selected = (self.selectedItem == name),
                onSelect = function()
                    self.selectedItem = iName
                    if itemDdLabel  then itemDdLabel:SetText(iName) end
                    if itemClearBtn then itemClearBtn:Show() end
                    CloseDropdowns(); self:Refresh()
                end,
            })
        end
    end

    itemDdSearch:SetText("")
    local listW = itemDdFrame:GetWidth() - 18
    local h = FillDdList(itemDdListC, listW, itemDdAllRows, "")
    local listH = math.min(h, DD_MAX_LIST)
    itemDdListSF:SetHeight(listH)
    itemDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
    itemDdSearch:SetFocus()
end

-- ── Public API ────────────────────────────────────────────────────────────────

function cttLoot_UI:SetBossFilter(bossName)
    self.selectedBoss = bossName
    self.lootFilter   = nil
    self.selectedItem = nil
    if bossDdLabel then bossDdLabel:SetText(bossName or "Boss") end
    if itemDdLabel then itemDdLabel:SetText("Item") end
    if bossClearBtn then
        if bossName then bossClearBtn:Show() else bossClearBtn:Hide() end
    end
    if itemClearBtn then itemClearBtn:Hide() end
    self:Refresh()
end

function cttLoot_UI:SetLootFilter(names)
    self.lootFilter = names
end

function cttLoot_UI:GetVisibleItemsForBoss(bossName)
    local dbItems = cttLoot:GetItemsForBoss(bossName)
    if #dbItems == 0 then
        -- Boss not in DB at all — show everything
        return cttLoot.itemNames
    end
    local bossSet = {}
    for _, item in ipairs(dbItems) do
        bossSet[item:lower()] = true
    end
    local result = {}
    for _, n in ipairs(cttLoot.itemNames) do
        local info = cttLoot:GetItemInfo(n)
        -- Include if: matches this boss in DB, OR not in DB at all
        if bossSet[n:lower()] or not info then
            table.insert(result, n)
        end
    end
    return result
end

function cttLoot_UI:IsWindowShown()
    return window and window:IsShown()
end

function cttLoot_UI:Refresh()
    if not window then return end
    PopulateGrid()
end

function cttLoot_UI:ToggleDrawer()
    if not drawer then return end
    drawerOpen = not drawerOpen
    if drawerOpen then drawer:Show() else drawer:Hide() end
end

function cttLoot_UI:Toggle()
    if not window then self:Build() end
    if window:IsShown() then
        window:Hide(); CloseDropdowns()
    else
        window:Show(); self:Refresh()
    end
end

function cttLoot_UI:Build()
    -- ── Main window ──
    window = CreateFrame("Frame", "cttLootFrame", UIParent)
    window:SetSize(WIN_W, WIN_H)
    window:SetPoint("CENTER")
    window:SetMovable(true); window:SetResizable(true)
    window:SetResizeBounds(500, 380, 1600, 1100)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop",  window.StopMovingOrSizing)
    window:SetFrameStrata("HIGH"); window:SetFrameLevel(100)
    Bg(window, C.bg)
    PixelBorder(window, C.border)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, window)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetPoint("TOPLEFT",  window, "TOPLEFT",  1, -1)
    titleBar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
    Bg(titleBar, C.bg_title)

    -- Blue accent underline under titlebar (matching HTML titlebar border-bottom)
    local accentLine = FlatTex(window, "ARTWORK", RGB(C.accent))
    accentLine:SetHeight(1)
    accentLine:SetPoint("TOPLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    accentLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)

    -- Title text: "cttLoot · Player DPS Delta Viewer"
    local titleFS = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    titleFS:SetTextColor(RGB(C.text_hi))
    titleFS:SetText("cttLoot  "..Clr(C.accent, "·").."  Player DPS Delta Viewer")

    -- ⚙ Cog button (right side of title bar, opens drawer)
    local cogBtn = Btn(window, "Settings", 60, 20)
    cogBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
    cogBtn:SetScript("OnClick", function()
        drawerOpen = not drawerOpen
        if drawerOpen then drawer:Show() else drawer:Hide() end
    end)

    -- Close button (plain X — ✕ renders as a box in WoW fonts)
    local closeBtn = Btn(window, "X", 22, 18, "danger")
    closeBtn:SetPoint("RIGHT", cogBtn, "LEFT", -2, 0)
    closeBtn:SetScript("OnClick", function()
        window:Hide(); CloseDropdowns()
        if drawer then drawer:Hide(); drawerOpen = false end
    end)

    -- Resize grip
    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -2, 2)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function() window:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp",   function()
        window:StopMovingOrSizing()
        if cardScrollF then
            -- resize scroll area to fit new window dimensions
            cardScrollF:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -18, PAD)
            if cardContent then cardContent:SetWidth(cardScrollF:GetWidth()) end
        end
        cttLoot_UI:Refresh()
    end)

    -- ── Drawer (right-side settings panel) ──
    drawer = BuildDrawer(window)

    -- ── Drawer sections ──
    local importSec = BuildImportSection(drawer)
    BuildDBSection()
    self:RepositionDrawer()

    -- ── Filter bar (anchored below title bar) ──
    local filterBar = BuildFilterBar(window, titleBar)

    -- ── Card grid (fills remaining space below filter bar) ──
    BuildCardArea(window, filterBar)

    window:Hide()
end

-- Init on login
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    cttLoot_UI:Build()
    -- cttLoot.lua's PLAYER_LOGIN handler (registered first) has already
    -- restored parse data into cttLoot.itemNames/playerNames/matrix.
    -- Refresh so the card grid reflects that data immediately.
    cttLoot_UI:Refresh()
end)
