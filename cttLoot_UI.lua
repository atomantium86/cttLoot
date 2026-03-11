-- cttLoot_UI.lua
-- Mirrors the HTML viewer layout exactly:
--   Title bar (cttLoot · Player DPS Delta Viewer) + ⚙ cog → right-side drawer
--   Drawer: Import Data / Import DB / Simulate Loot panels
--   Main: filter bar (Boss ▾ · sep · Item ▾ · stats) + card grid scroll area
--   Each card: dark header (item name + boss), ranked rows: [rank][name][bar][dps]
--   Card header click → single-item full view (all players, no row limit)

cttLoot_UI = {}
cttLoot_UI.awardedOnly  = false
cttLoot_UI.sortByDelta  = true   -- default on

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
    bg          = {0.102, 0.102, 0.102},  -- #1a1a1a  main background
    bg2         = {0.122, 0.122, 0.122},  -- #1f1f1f  slightly lighter panels
    bg3         = {0.075, 0.075, 0.075},  -- #131313  darkest inset areas
    bg_title    = {0.082, 0.082, 0.082},  -- #151515  titlebar
    bg_hdr      = {0.114, 0.114, 0.114},  -- #1d1d1d  section headers
    border      = {0.165, 0.165, 0.165},  -- #2a2a2a  thin border everywhere
    accent      = {0.302, 0.498, 0.667},  -- #4d7faa  ElvUI steel blue
    accent2     = {0.220, 0.365, 0.490},  -- #385d7d  darker blue hover
    text        = {0.878, 0.878, 0.878},  -- #e0e0e0  primary text
    text_dim    = {0.431, 0.431, 0.431},  -- #6e6e6e  dimmed text
    text_hi     = {1.000, 1.000, 1.000},  -- #ffffff  highlight text
    green       = {0.337, 0.659, 0.337},  -- #56a856  positive delta
    red         = {0.749, 0.255, 0.255},  -- #bf4141  negative delta
    catalyst    = {0.545, 0.306, 0.737},  -- #8b4ebc  catalyst purple
    rank_gold   = {0.800, 0.647, 0.251},  -- #cca540
    rank_silver = {0.714, 0.714, 0.714},  -- #b6b6b6
    rank_bronze = {0.694, 0.431, 0.192},  -- #b16e31
    card_bg     = {0.102, 0.102, 0.102},  -- same as bg
    card_hdr    = {0.082, 0.082, 0.082},  -- slightly darker card header
}

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ── UI state ──────────────────────────────────────────────────────────────────
local window        = nil
local drawer        = nil
local drawerOpen    = false
local cardScrollF   = nil    -- ScrollFrame for card grid
local filterBar     = nil    -- Filter bar (for relayout after stats update)
local awardedFilterBtn = nil -- Awarded-only toggle button
local sortFilterBtn    = nil -- Sort-by-delta toggle button
local cardContent   = nil    -- content frame inside scroll
local cardPool      = {}     -- reuse frames: cardPool[i] = frame
local activeCards   = 0
local emptyLabel    = nil    -- reusable "no data" hint label

cttLoot_UI.selectedBoss   = nil
cttLoot_UI.selectedItem   = nil
cttLoot_UI.selectedPlayer = nil
cttLoot_UI.lootFilter     = nil

-- dropdown state
local bossDdOpen   = false
local itemDdOpen   = false
local playerDdOpen = false
local bossDdFrame  = nil
local itemDdFrame  = nil
local playerDdFrame = nil
local bossDdRows   = {}
local itemDdRows   = {}
local playerDdRows = {}

-- label fontstrings (filter bar)
local bossDdLabel   = nil
local itemDdLabel   = nil
local playerDdLabel = nil
local bossClearBtn  = nil
local itemClearBtn  = nil
local playerClearBtn = nil
local statsLabel    = nil

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

-- ── Class color cache ─────────────────────────────────────────────────────────
local classColorCache = {}  -- { ["playername"] = {r, g, b} }

local function BuildClassColors()
    classColorCache = {}
    -- Always include the player themselves
    local selfName = UnitName("player")
    if selfName then
        selfName = selfName:match("^([^%-]+)") or selfName
        local _, classToken = UnitClass("player")
        if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
            local c = RAID_CLASS_COLORS[classToken]
            classColorCache[selfName:lower()] = { c.r, c.g, c.b }
        end
    end
    -- Scan group members
    local numMembers = GetNumGroupMembers()
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, numMembers do
        local unit = prefix .. i
        local name = UnitName(unit)
        if name then
            name = name:match("^([^%-]+)") or name
            local _, classToken = UnitClass(unit)
            if classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken] then
                local c = RAID_CLASS_COLORS[classToken]
                classColorCache[name:lower()] = { c.r, c.g, c.b }
            end
        end
    end
end

local function GetClassColor(playerName)
    local key = playerName:lower():match("^([^%-]+)") or playerName:lower()
    return classColorCache[key]
end


local function CloseDropdowns()
    bossDdOpen = false; itemDdOpen = false; playerDdOpen = false
    if bossDdFrame   then bossDdFrame:Hide()   end
    if itemDdFrame   then itemDdFrame:Hide()   end
    if playerDdFrame then playerDdFrame:Hide() end
    if bossDdSearch  then bossDdSearch:ClearFocus()  end
    if itemDdSearch  then itemDdSearch:ClearFocus()  end
    if playerDdSearch then playerDdSearch:ClearFocus() end
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
    arrow:SetTextColor(RGB(C.text_dim)); arrow:SetText("+")

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
        if sec.open then body:Show(); arrow:SetText("-")
        else             body:Hide(); arrow:SetText("+") end
        -- Restack other sections below
        cttLoot_UI:RepositionDrawer()
    end)

    hdr:SetScript("OnEnter", function() hdr._bg:SetVertexColor(0.157, 0.157, 0.157) end)
    hdr:SetScript("OnLeave", function() hdr._bg:SetVertexColor(RGB(C.bg_hdr)) end)
    hdr._bg = Bg(hdr, C.bg_hdr)

    table.insert(drawerSections, sec)
    return sec
end

-- Reposition all drawer sections after toggling one
function cttLoot_UI:RepositionDrawer()
    local y = -(TITLE_H + PAD + 2)
    for _, sec in ipairs(drawerSections) do
        sec.hdr:ClearAllPoints()
        sec.hdr:SetPoint("TOPLEFT",  drawer, "TOPLEFT",  PAD, y)
        sec.hdr:SetPoint("TOPRIGHT", drawer, "TOPRIGHT", -PAD, y)
        y = y - PANEL_HDR - 1
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
    d:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(TITLE_H + 2))
    d:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    d:SetWidth(DRAWER_W)
    d:SetFrameLevel(parent:GetFrameLevel() + 10)
    d:EnableMouse(true)
    Bg(d, C.bg2)
    PixelBorder(d, C.border)

    -- Drawer title bar
    local dtb = CreateFrame("Frame", nil, d)
    dtb:SetHeight(TITLE_H)
    dtb:SetPoint("TOPLEFT"); dtb:SetPoint("TOPRIGHT")
    Bg(dtb, C.bg_title)
    local accentLine = FlatTex(dtb, "ARTWORK", RGB(C.accent))
    accentLine:SetHeight(1)
    accentLine:SetPoint("TOPLEFT",  dtb, "BOTTOMLEFT",  0, 0)
    accentLine:SetPoint("TOPRIGHT", dtb, "BOTTOMRIGHT", 0, 0)

    local dtitle = dtb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dtitle:SetPoint("LEFT", dtb, "LEFT", 10, 0)
    dtitle:SetTextColor(RGB(C.text_hi))
    dtitle:SetText("Settings")

    local closeX = Btn(dtb, "X", 22, 18, "danger")
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
    local sec = MakeDrawerSection(drawer, "Import Parse Data", -(TITLE_H + PAD + 2))
    sec.open = true
    sec.arrow:SetText("-")
    sec.body:Show()
    sec.body:SetHeight(138)

    local sf, eb = ScrollEB(sec.body, DRAWER_W - 24, 90)
    sf:SetPoint("TOPLEFT",  sec.body, "TOPLEFT",  2, -PAD)
    sf:SetPoint("TOPRIGHT", sec.body, "TOPRIGHT", -20, -PAD)
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
        cttLootDB.lastData = { itemNames=data.itemNames, playerNames=data.playerNames, matrix=data.matrix }
        cttLoot:Print(string.format("Loaded %d items x %d players.", #data.itemNames, #data.playerNames))
        cttLoot_UI:Refresh()
        -- Auto-broadcast to group (or if loopback enabled for testing)
        if IsInRaid() or IsInGroup() or cttLoot.loopback then
            cttLoot:Broadcast()
        end
    end)

    local sendBtn = Btn(sec.body, "Resend to Raid", 106, 20)
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
    sf:SetPoint("TOPRIGHT", sec.body, "TOPRIGHT", -20, -PAD)
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


-- ── Options section ───────────────────────────────────────────────────────────
local rcHookBtn = nil
local function BuildOptionsSection()
    local sec = MakeDrawerSection(drawer, "Options", 0)
    sec.body:SetHeight(80)

    -- RC snap toggle button
    rcHookBtn = Btn(sec.body, "Unsnap RC", 90, 20, "danger")
    rcHookBtn:SetPoint("TOPLEFT", sec.body, "TOPLEFT", 2, -PAD)
    rcHookBtn:SetScript("OnClick", function()
        if cttLoot_RC:IsEnabled() then
            cttLoot_RC:SetSnapEnabled(false)
            rcHookBtn._label:SetText("Snap to RC")
            cttLoot_UI:ReleaseSnap()
            cttLoot:Print("RC snap disabled.")
        else
            cttLoot_RC:SetSnapEnabled(true)
            rcHookBtn._label:SetText("Unsnap RC")
            cttLoot_UI:SnapToRC()
            cttLoot:Print("RC snap enabled.")
        end
    end)

    local rcLabel = sec.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rcLabel:SetPoint("LEFT", rcHookBtn, "RIGHT", 6, 0)
    rcLabel:SetTextColor(0.6, 0.6, 0.6)
    rcLabel:SetText("Snap cttLoot to RC voting frame")

    -- RC integration toggle button
    local rcIntBtn = Btn(sec.body, "Disable RC", 90, 20, "danger")
    rcIntBtn:SetPoint("TOPLEFT", rcHookBtn, "BOTTOMLEFT", 0, -PAD)
    rcIntBtn:SetScript("OnClick", function()
        if cttLoot_RC.trackEnabled then
            cttLoot_RC:SetEnabled(false)
            rcIntBtn._label:SetText("Enable RC")
            cttLoot:Print("RC integration disabled.")
        else
            cttLoot_RC:SetEnabled(true)
            rcIntBtn._label:SetText("Disable RC")
            cttLoot:Print("RC integration enabled.")
        end
    end)

    local rcIntLabel = sec.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rcIntLabel:SetPoint("LEFT", rcIntBtn, "RIGHT", 6, 0)
    rcIntLabel:SetTextColor(0.6, 0.6, 0.6)
    rcIntLabel:SetText("RCLootCouncil session tracking")

    return sec
end
-- Returns the filter bar frame; sets module-level label/button refs.
local function BuildFilterBar(parent, topAnchor)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(FBAR_H)
    bar:SetPoint("TOPLEFT",  topAnchor, "BOTTOMLEFT",  0, -PAD)
    bar:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -PAD)
    Bg(bar, C.bg2)
    PixelBorder(bar, C.border)
    AccentLeft(bar)

    local filtersVisible = true

    -- Collapse toggle (leftmost, fixed width)
    local toggleBtn = Btn(bar, "<<", 26, 20)
    toggleBtn:SetPoint("LEFT", bar, "LEFT", 4, 0)

    -- Stats label (anchored RIGHT, fixed)
    statsLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsLabel:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    statsLabel:SetTextColor(RGB(C.text_dim))
    cttLoot_UI.statsLabel = statsLabel

    -- Boss dropdown button (LEFT anchor set in relayout)
    local bossBtn = Btn(bar, "", 150, 20)
    bossDdLabel = bossBtn._label
    bossDdLabel:SetText("Boss")
    bossDdLabel:SetJustifyH("LEFT")
    local bossArrow = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossArrow:SetPoint("RIGHT", bossBtn, "RIGHT", -4, 0)
    bossArrow:SetTextColor(RGB(C.text_dim)); bossArrow:SetText("▾")

    bossClearBtn = Btn(bar, "X", 16, 16, "danger")
    bossClearBtn:SetPoint("LEFT", bossBtn, "RIGHT", 2, 0)
    bossClearBtn:Hide()
    bossClearBtn:SetScript("OnClick", function() cttLoot_UI:SetBossFilter(nil) end)
    cttLoot_UI.bossClearBtn = bossClearBtn

    -- Item dropdown button
    local itemBtn = Btn(bar, "", 180, 20)
    itemDdLabel = itemBtn._label
    itemDdLabel:SetText("Item")
    itemDdLabel:SetJustifyH("LEFT")
    local itemArrow = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemArrow:SetPoint("RIGHT", itemBtn, "RIGHT", -4, 0)
    itemArrow:SetTextColor(RGB(C.text_dim)); itemArrow:SetText("▾")

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

    -- Player dropdown button
    local playerBtn = Btn(bar, "", 120, 20)
    playerDdLabel = playerBtn._label
    playerDdLabel:SetText("Player")
    playerDdLabel:SetJustifyH("LEFT")
    local playerArrow = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    playerArrow:SetPoint("RIGHT", playerBtn, "RIGHT", -4, 0)
    playerArrow:SetTextColor(RGB(C.text_dim)); playerArrow:SetText("▾")

    playerClearBtn = Btn(bar, "X", 16, 16, "danger")
    playerClearBtn:SetPoint("LEFT", playerBtn, "RIGHT", 2, 0)
    playerClearBtn:Hide()
    playerClearBtn:SetScript("OnClick", function()
        cttLoot_UI.selectedPlayer = nil
        playerDdLabel:SetText("Player")
        playerClearBtn:Hide()
        cttLoot_UI:Refresh()
    end)
    cttLoot_UI.playerClearBtn = playerClearBtn

    -- ── Dropdown panels ──
    bossDdFrame = CreateFrame("Frame", nil, bar)
    bossDdFrame:SetPoint("TOPLEFT", bossBtn, "BOTTOMLEFT", 0, -2)
    bossDdFrame:SetFrameLevel(bar:GetFrameLevel() + 20)
    bossDdFrame:EnableMouse(true)
    Bg(bossDdFrame, C.bg2); PixelBorder(bossDdFrame, C.accent)
    bossDdFrame:Hide()

    itemDdFrame = CreateFrame("Frame", nil, bar)
    itemDdFrame:SetPoint("TOPLEFT", itemBtn, "BOTTOMLEFT", 0, -2)
    itemDdFrame:SetFrameLevel(bar:GetFrameLevel() + 20)
    itemDdFrame:EnableMouse(true)
    Bg(itemDdFrame, C.bg2); PixelBorder(itemDdFrame, C.accent)
    itemDdFrame:Hide()

    playerDdFrame = CreateFrame("Frame", nil, bar)
    playerDdFrame:SetPoint("TOPLEFT", playerBtn, "BOTTOMLEFT", 0, -2)
    playerDdFrame:SetFrameLevel(bar:GetFrameLevel() + 20)
    playerDdFrame:EnableMouse(true)
    Bg(playerDdFrame, C.bg2); PixelBorder(playerDdFrame, C.accent)
    playerDdFrame:Hide()

    -- ── Relayout: anchor chain with tight gaps, no seps ──
    local GAP        = 3   -- gap between elements
    local CLEAR_W    = 16  -- clear btn width
    local TOGGLE_W   = 4 + 26 + GAP
    local RIGHT_PAD  = 10

    local function Relayout()
        local barW = bar:GetWidth()
        if barW < 50 then return end
        local statsW = statsLabel:GetStringWidth() + RIGHT_PAD
        -- fixed: toggle + 3*(clearBtn+gap) + statsW
        local fixed  = TOGGLE_W + (CLEAR_W + GAP) * 3 + statsW
        local avail  = math.max(barW - fixed, 120)
        local bossW   = math.floor(avail * 0.30)
        local itemW   = math.floor(avail * 0.40)
        local playerW = avail - bossW - itemW

        bossBtn:ClearAllPoints()
        bossBtn:SetWidth(bossW)
        bossBtn:SetPoint("LEFT", toggleBtn, "RIGHT", GAP, 0)

        itemBtn:ClearAllPoints()
        itemBtn:SetWidth(itemW)
        itemBtn:SetPoint("LEFT", bossClearBtn, "RIGHT", GAP, 0)

        playerBtn:ClearAllPoints()
        playerBtn:SetWidth(playerW)
        playerBtn:SetPoint("LEFT", itemClearBtn, "RIGHT", GAP, 0)

        -- Dropdown panels auto-fit to content; set a minimum matching the button
        if not bossDdFrame:IsShown()   then bossDdFrame:SetWidth(math.max(bossW, 160))     end
        if not itemDdFrame:IsShown()   then itemDdFrame:SetWidth(math.max(itemW, 200))     end
        if not playerDdFrame:IsShown() then playerDdFrame:SetWidth(math.max(playerW, 140)) end
    end
    bar:SetScript("OnSizeChanged", Relayout)
    bar.Relayout = Relayout

    -- ── Toggle filter visibility ──
    local filterElements = { bossBtn, bossArrow, itemBtn, itemArrow, playerBtn, playerArrow }
    local function SetFiltersVisible(visible)
        filtersVisible = visible
        for _, el in ipairs(filterElements) do
            if visible then el:Show() else el:Hide() end
        end
        if not visible then
            CloseDropdowns()
            bossClearBtn:Hide(); itemClearBtn:Hide(); playerClearBtn:Hide()
        end
        toggleBtn._label:SetText(visible and "<<" or ">>")
    end
    toggleBtn:SetScript("OnClick", function() SetFiltersVisible(not filtersVisible) end)

    -- ── Dropdown clicks ──
    bossBtn:SetScript("OnClick", function()
        if bossDdOpen then CloseDropdowns(); return end
        CloseDropdowns(); bossDdOpen = true
        cttLoot_UI:PopulateBossDropdown(); bossDdFrame:Show()
    end)
    itemBtn:SetScript("OnClick", function()
        if itemDdOpen then CloseDropdowns(); return end
        CloseDropdowns(); itemDdOpen = true
        cttLoot_UI:PopulateItemDropdown(); itemDdFrame:Show()
    end)
    playerBtn:SetScript("OnClick", function()
        if playerDdOpen then CloseDropdowns(); return end
        CloseDropdowns(); playerDdOpen = true
        cttLoot_UI:PopulatePlayerDropdown(); playerDdFrame:Show()
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
    cardScrollF:SetPoint("BOTTOMRIGHT", parent,    "BOTTOMRIGHT", -22, PAD + 14)

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
    return cttLoot.itemIndex[name .. " CATALYST"]
end

local function GetItemPool()
    local pool = {}
    local source
    if cttLoot_UI.selectedItem then
        return { cttLoot_UI.selectedItem }
    elseif cttLoot_UI.lootFilter then
        source = cttLoot_UI.lootFilter
    elseif cttLoot_UI.selectedBoss then
        source = cttLoot_UI:GetVisibleItemsForBoss(cttLoot_UI.selectedBoss)
    else
        source = cttLoot.itemNames
    end

    local selectedPlayer = cttLoot_UI.selectedPlayer
    local playerRow = selectedPlayer and cttLoot.matrix[cttLoot.playerIndex[selectedPlayer]]
    for _, n in ipairs(source) do
        if not IsCatalyst(n) then
            local passesAward = not cttLoot_UI.awardedOnly
                or (cttLoot_RC and cttLoot_RC.GetWinnerForItem(n))
            if passesAward then
                if selectedPlayer then
                    local ci = cttLoot.itemIndex[n]
                    if ci and playerRow and playerRow[ci] then
                        table.insert(pool, n)
                    end
                else
                    table.insert(pool, n)
                end
            end
        end
    end
    return pool
end

-- Helper: get the best delta for an item across all players, or for a specific player
local function GetItemDelta(itemName, forPlayer)
    local ci = cttLoot.itemIndex[itemName]
    if not ci then return 0 end
    local best = 0
    if forPlayer then
        local pi = cttLoot.playerIndex[forPlayer]
        local v = pi and cttLoot.matrix[pi] and cttLoot.matrix[pi][ci]
        return v or 0
    end
    for r = 1, #cttLoot.playerNames do
        local v = cttLoot.matrix[r] and cttLoot.matrix[r][ci]
        if v and v > best then best = v end
    end
    return best
end

local function GetItemPoolSorted()
    local pool = GetItemPool()
    if cttLoot_UI.selectedItem then return pool end
    if not cttLoot_UI.sortByDelta then
        table.sort(pool)
        return pool
    end
    -- Pre-cache delta for each item to avoid O(N*players) work per sort comparison
    local forPlayer = cttLoot_UI.selectedPlayer
    local deltaCache = {}
    for _, name in ipairs(pool) do
        deltaCache[name] = GetItemDelta(name, forPlayer)
    end
    table.sort(pool, function(a, b)
        return deltaCache[a] > deltaCache[b]
    end)
    return pool
end

-- Per-player best item lookup (populated before each grid render)
local playerBestItem = {}

-- Build one card frame for `itemName` at position (ox, oy) relative to cardContent
-- Returns the card frame (or nil) and its total height.
local function MakeCard(itemName, ox, oy, limit, cardW)
    cardW = cardW or CARD_W
    local ci = cttLoot.itemIndex[itemName]
    if not ci then return nil, 0 end

    local catCi = CatColFor(itemName)

    -- Gather entries
    local entries = {}
    local filterPlayer = cttLoot_UI.selectedPlayer
    for r, player in ipairs(cttLoot.playerNames) do
        if not filterPlayer or player == filterPlayer then
            local row = cttLoot.matrix[r]
            local base = row and row[ci]
            local cat  = catCi and row and row[catCi]
            -- In overview (no item zoom), hide negative deltas
            local showNeg = cttLoot_UI.selectedItem ~= nil
            if base and (showNeg or base >= 0) then table.insert(entries, { player=player, dps=base, isCat=false }) end
            if cat  and (showNeg or cat  >= 0) then table.insert(entries, { player=player, dps=cat,  isCat=true  }) end
        end
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
    local winner   = cttLoot_RC and cttLoot_RC.GetWinnerForItem(itemName)
    -- hdrH: 1 line (item only) = 20, 2 lines (item+boss) = 32, 3 lines (item+boss+winner) = 44
    local hdrH = 20
    if hasBoss  then hdrH = 32 end
    if hasBoss and winner then hdrH = 44 end
    local cardH    = hdrH + #entries * ROW_H + 2

    local card = CreateFrame("Frame", nil, cardContent)
    card:SetSize(cardW, cardH)
    card:SetPoint("TOPLEFT", cardContent, "TOPLEFT", ox, -oy)

    Bg(card, C.card_bg)
    PixelBorder(card, C.border)

    -- Header button (clicking zooms to single-item view)
    local hdr = CreateFrame("Button", nil, card)
    hdr:SetHeight(hdrH)
    hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
    local hdrBg = Bg(hdr, C.card_hdr)

    -- Item name (.ov-title)
    local titleFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -4)
    titleFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -4)
    titleFS:SetHeight(12)
    titleFS:SetTextColor(RGB(C.text_hi))
    titleFS:SetText(itemName)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(false)
    titleFS:SetNonSpaceWrap(false)

    -- Boss sub-label
    if hasBoss then
        local bossFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bossFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -17)
        bossFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -17)
        bossFS:SetHeight(12)
        bossFS:SetTextColor(RGB(C.accent))
        bossFS:SetText(info.boss)
        bossFS:SetJustifyH("LEFT")
        bossFS:SetWordWrap(false)
        bossFS:SetNonSpaceWrap(false)
    end

    -- Winner stamp — shown when RC has awarded this item
    if winner then
        local winnerFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if hasBoss then
            winnerFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -29)
            winnerFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -29)
            winnerFS:SetJustifyH("LEFT")
        else
            winnerFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -4)
            winnerFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -4)
            winnerFS:SetJustifyH("RIGHT")
        end
        winnerFS:SetHeight(12)
        winnerFS:SetWordWrap(false)
        winnerFS:SetNonSpaceWrap(false)
        winnerFS:SetTextColor(0.2, 1, 0.2, 1)
        winnerFS:SetText(">> " .. winner)

        -- Dim the entire card only in overview grid (not when zoomed into single-item view)
        if not cttLoot_UI.selectedItem then
            local dimTex = card:CreateTexture(nil, "OVERLAY")
            dimTex:SetAllPoints(card)
            dimTex:SetColorTexture(0, 0, 0, 0.5)
        end
    end

    hdr:SetScript("OnEnter", function() hdrBg:SetVertexColor(RGB(C.accent2)) end)
    hdr:SetScript("OnLeave", function() hdrBg:SetVertexColor(RGB(C.card_hdr)) end)    hdr:SetScript("OnClick", function()
        CloseDropdowns()
        if cttLoot_UI.selectedItem == itemName then
            -- clicking same item header → go back to previous view
            cttLoot_UI.selectedItem = nil
            -- only reset item dropdown if we're not in loot filter mode
            if not cttLoot_UI.lootFilter then
                if itemDdLabel then itemDdLabel:SetText("Item") end
                if itemClearBtn then itemClearBtn:Hide() end
            end
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

        -- Gold highlight if this is the player's best item
        local isBest = not e.isCat and (playerBestItem[e.player] == itemName)
        if isBest then
            local ar, ag, ab = RGB(C.accent)
            local bestBg = FlatTex(card, "BACKGROUND", ar, ag, ab, 0.15)
            bestBg:SetSize(cardW, ROW_H)
            bestBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
        elseif i % 2 == 0 then
            local rowBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.03)
            rowBg:SetSize(cardW, ROW_H)
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
        local classColor = GetClassColor(e.player)
        if e.isCat then
            nameFS:SetText(e.player .. " " .. Clr(C.catalyst, "(cat)"))
            if classColor then nameFS:SetTextColor(classColor[1], classColor[2], classColor[3])
            else nameFS:SetTextColor(RGB(C.text)) end
        else
            if classColor then nameFS:SetTextColor(classColor[1], classColor[2], classColor[3])
            else nameFS:SetTextColor(RGB(C.text)) end
            nameFS:SetText(e.player)
        end

        local dynBarW = cardW - COL_RANK - COL_NAME - COL_DPS - 10
        local barBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.06)
        barBg:SetSize(dynBarW, BAR_H)
        barBg:SetPoint("TOPLEFT", card, "TOPLEFT",
            COL_RANK + COL_NAME + 2, -ry - (ROW_H - BAR_H) / 2)

        -- Bar fill — flat colors, ElvUI style
        local barPct = math.max(0.01, math.abs(e.dps) / maxAbs)
        local fillW  = math.max(2, math.floor(barPct * dynBarW))
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

        -- DPS value
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

        -- Row separator line — thin gold
        if i < #entries then
            local sep = FlatTex(card, "BACKGROUND", RGB(C.border))
            sep:SetHeight(1)
            sep:SetPoint("BOTTOMLEFT",  card, "TOPLEFT",  0, -(ry + ROW_H - 1))
            sep:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", 0, -(ry + ROW_H - 1))
        end
    end

    return card, cardH
end

-- Destroy all current card frames
local function ClearCards()
    if not cardContent then return end
    for _, c in ipairs(cardPool) do
        c:Hide()
        c:SetParent(nil)
    end
    cardPool = {}
    activeCards = 0
    cardContent:SetHeight(1)
end

-- Per-player best item: { ["playername"] = "itemName" }
local function BuildPlayerBestItems()
    playerBestItem = {}
    for r, player in ipairs(cttLoot.playerNames) do
        local row = cttLoot.matrix[r]
        if row then
            local bestVal, bestItem = nil, nil
            for i, itemName in ipairs(cttLoot.itemNames) do
                if not IsCatalyst(itemName) then
                    local v = row[i]
                    if v and (bestVal == nil or v > bestVal) then
                        bestVal = v
                        bestItem = itemName
                    end
                end
            end
            if bestItem then
                playerBestItem[player] = bestItem
            end
        end
    end
end

-- Re-lay out the card grid
local function PopulateGrid()
    if not cardContent then return end
    ClearCards()

    local pool = GetItemPoolSorted()

    if #pool == 0 then
        if not emptyLabel then
            emptyLabel = cardContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            emptyLabel:SetPoint("TOP", cardContent, "TOP", 0, -50)
            emptyLabel:SetTextColor(RGB(C.text_dim))
        end
        if #cttLoot.playerNames == 0 then
            emptyLabel:SetText("Open Settings > Import Parse Data, paste CSV, then click Load Data")
        else
            emptyLabel:SetText("No items match current filter")
        end
        emptyLabel:Show()
        cardContent:SetHeight(120)

        if statsLabel then statsLabel:SetText("") end
        return
    end

    -- Cards are being shown — hide the empty label if it exists
    if emptyLabel then emptyLabel:Hide() end

    -- In single-item view show all rows; otherwise cap at 10 (matching HTML limit 10)
    local rowLimit = cttLoot_UI.selectedItem and 0 or 10

    local gridW    = cardScrollF:GetWidth() - 4
    local cardW    = cttLoot_UI.selectedItem and (gridW - PAD * 2) or CARD_W
    local cols     = cttLoot_UI.selectedItem and 1 or math.max(1, math.floor((gridW + CARD_GAP) / (CARD_W + CARD_GAP)))
    local col, totalH, rowMaxH = 0, PAD, 0

    for _, name in ipairs(pool) do
        local ox = PAD + col * (cardW + CARD_GAP)
        local oy = totalH
        local card, cardH = MakeCard(name, ox, oy, rowLimit, cardW)
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
        if filterBar then filterBar.Relayout() end
    end
end

-- ── Shared: build search box + scrollable list inside a dd frame ─────────────
-- Returns: searchEB, listFrame, listContent
-- The caller populates listContent and sets its height.
local DD_SEARCH_H = 22
local DD_MAX_LIST = 220  -- max height of the scrollable list area

local function BuildDdSearchAndList(ddFrame, ddW)
    -- Search box
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
    searchEB:SetScript("OnTextChanged",    function(s) placeholder:SetShown(s:GetText() == "") end)
    searchEB:SetScript("OnEditFocusGained", function()  placeholder:Hide() end)
    searchEB:SetScript("OnEditFocusLost",  function(s) placeholder:SetShown(s:GetText() == "") end)

    -- ── Custom scroll frame (no template — scrollbar stays inside) ──
    local SBAR_W = 8   -- thin scrollbar

    local listSF = CreateFrame("ScrollFrame", nil, ddFrame)
    listSF:SetPoint("TOPLEFT",  ddFrame, "TOPLEFT",  0, -(DD_SEARCH_H + 4))
    listSF:SetPoint("TOPRIGHT", ddFrame, "TOPRIGHT",  0, -(DD_SEARCH_H + 4))

    local listContent = CreateFrame("Frame", nil, listSF)
    listContent:SetWidth(ddW - SBAR_W - 2)
    listContent:SetHeight(1)
    listSF:SetScrollChild(listContent)

    -- Mouse wheel scrolling
    listSF:EnableMouseWheel(true)
    listSF:SetScript("OnMouseWheel", function(self, delta)
        local cur  = self:GetVerticalScroll()
        local max  = self:GetVerticalScrollRange()
        local step = 20
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * step)))
        -- update thumb
        if max > 0 then
            local pct = self:GetVerticalScroll() / max
            local sfH = self:GetHeight()
            local thumbH = math.max(16, sfH * (sfH / (sfH + max)))
            local travel = sfH - thumbH
            thumb:SetPoint("TOP", scrollTrack, "TOP", 0, -pct * travel)
        end
    end)

    -- Thin scrollbar track (right edge, inside)
    local scrollTrack = CreateFrame("Frame", nil, ddFrame)
    scrollTrack:SetWidth(SBAR_W)
    scrollTrack:SetPoint("TOPRIGHT",    ddFrame, "TOPRIGHT",    -1, -(DD_SEARCH_H + 5))
    scrollTrack:SetPoint("BOTTOMRIGHT", ddFrame, "BOTTOMRIGHT", -1,  1)
    local trackBg = FlatTex(scrollTrack, "BACKGROUND", RGB({0.12, 0.12, 0.12}))
    trackBg:SetAllPoints(scrollTrack)

    local thumb = CreateFrame("Frame", nil, scrollTrack)
    thumb:SetWidth(SBAR_W)
    thumb:SetHeight(20)
    thumb:SetPoint("TOP", scrollTrack, "TOP", 0, 0)
    local thumbTex = FlatTex(thumb, "ARTWORK", RGB({0.35, 0.35, 0.40}))
    thumbTex:SetAllPoints(thumb)
    thumb:Hide()

    -- Update thumb on scroll
    local function UpdateThumb()
        local max = listSF:GetVerticalScrollRange()
        if max <= 0 then thumb:Hide(); return end
        thumb:Show()
        local sfH    = listSF:GetHeight()
        local contH  = listContent:GetHeight()
        local thumbH = math.max(16, sfH * sfH / contH)
        local travel = sfH - thumbH
        local pct    = listSF:GetVerticalScroll() / max
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", scrollTrack, "TOP", 0, -pct * travel)
    end
    listSF:SetScript("OnVerticalScroll", function(self, offset)
        self:SetVerticalScroll(offset)
        UpdateThumb()
    end)
    listSF:SetScript("OnSizeChanged", UpdateThumb)
    listContent:SetScript("OnSizeChanged", UpdateThumb)

    -- Thumb drag
    thumb:EnableMouse(true)
    thumb:SetScript("OnMouseDown", function(self, btn)
        if btn ~= "LeftButton" then return end
        local _, thumbY  = thumb:GetCenter()
        local _, trackY  = scrollTrack:GetTop() and 0 or 0
        local startY     = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local startScroll = listSF:GetVerticalScroll()
        local max        = listSF:GetVerticalScrollRange()
        local sfH        = listSF:GetHeight()
        local thumbH     = thumb:GetHeight()
        local travel     = sfH - thumbH
        thumb:SetScript("OnUpdate", function()
            local curY = select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
            local delta = startY - curY
            if travel > 0 then
                local newScroll = math.max(0, math.min(max, startScroll + delta * max / travel))
                listSF:SetVerticalScroll(newScroll)
                UpdateThumb()
            end
        end)
    end)
    thumb:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    return searchEB, listSF, listContent, UpdateThumb
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

    local q      = query and query:lower() or ""
    local y      = 0
    local any    = false
    local maxW   = listW  -- track widest label
    for _, row in ipairs(rows) do
        local label = row.label
        if q == "" or label:lower():find(q, 1, true) then
            -- Measure text width + padding
            local tmp = listContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            tmp:SetText(label)
            local tw = tmp:GetStringWidth() + 24  -- 24px for padding + arrow
            tmp:Hide()
            if tw > maxW then maxW = tw end
            local btn = Btn(listContent, label, maxW, DD_ROW_H)
            btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
            if row.selected then btn._bg:SetVertexColor(RGB(C.accent2)) end
            local cb = row.onSelect
            btn:SetScript("OnClick", cb)
            y   = y + DD_ROW_H + 1
            any = true
        end
    end
    -- Resize all buttons to the max width
    for _, child in ipairs({ listContent:GetChildren() }) do
        child:SetWidth(maxW)
    end
    if not any then
        local empty = listContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", listContent, "TOPLEFT", 8, -6)
        empty:SetTextColor(RGB(C.text_dim))
        empty:SetText(q ~= "" and "No match" or "—")
        y = y + 20
    end
    listContent:SetHeight(math.max(y, 1))
    return y, maxW
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
        local updateThumb
        bossDdSearch, bossDdListSF, bossDdListC, updateThumb =
            BuildDdSearchAndList(bossDdFrame, 196)
        bossDdSearch:SetScript("OnTextChanged", function(s)
            local txt = s:GetText()
            local lW = bossDdFrame:GetWidth() - 18
            local h, mW = FillDdList(bossDdListC, lW, bossDdAllRows, txt)
            local listH = math.min(h, DD_MAX_LIST)
            bossDdListSF:SetHeight(listH)
            bossDdFrame:SetWidth(mW + 4)
            bossDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
            C_Timer.After(0, updateThumb)
        end)
        bossDdListSF.updateThumb = updateThumb
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
    local h, maxW = FillDdList(bossDdListC, listW, bossDdAllRows, "")
    local listH = math.min(h, DD_MAX_LIST)
    bossDdListSF:SetHeight(listH)
    bossDdFrame:SetWidth(maxW + 4)
    bossDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
    C_Timer.After(0, bossDdListSF.updateThumb)
    bossDdSearch:SetFocus()
end

-- ── Item dropdown population ──────────────────────────────────────────────────
function cttLoot_UI:PopulateItemDropdown()
    if not itemDdFrame then return end

    if not itemDdSearch then
        local updateThumb
        itemDdSearch, itemDdListSF, itemDdListC, updateThumb =
            BuildDdSearchAndList(itemDdFrame, 216)
        itemDdSearch:SetScript("OnTextChanged", function(s)
            local txt = s:GetText()
            local lW = itemDdFrame:GetWidth() - 18
            local h, mW = FillDdList(itemDdListC, lW, itemDdAllRows, txt)
            local listH = math.min(h, DD_MAX_LIST)
            itemDdListSF:SetHeight(listH)
            itemDdFrame:SetWidth(mW + 4)
            itemDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
            C_Timer.After(0, updateThumb)
        end)
        itemDdListSF.updateThumb = updateThumb
    end

    -- Always show the full item list in the dropdown (ignoring selectedItem filter)
    local source
    if self.lootFilter then
        source = self.lootFilter
    elseif self.selectedBoss then
        source = self:GetVisibleItemsForBoss(self.selectedBoss)
    else
        source = cttLoot.itemNames
    end
    local pool = {}
    for _, n in ipairs(source) do
        if not IsCatalyst(n) then pool[#pool+1] = n end
    end
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
    local h, maxW = FillDdList(itemDdListC, listW, itemDdAllRows, "")
    local listH = math.min(h, DD_MAX_LIST)
    itemDdListSF:SetHeight(listH)
    itemDdFrame:SetWidth(maxW + 4)
    itemDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
    C_Timer.After(0, itemDdListSF.updateThumb)
    itemDdSearch:SetFocus()
end

-- ── Player dropdown population ────────────────────────────────────────────────
local playerDdSearch, playerDdListSF, playerDdListC
local playerDdAllRows = {}

function cttLoot_UI:PopulatePlayerDropdown()
    if not playerDdFrame then return end

    if not playerDdSearch then
        local updateThumb
        playerDdSearch, playerDdListSF, playerDdListC, updateThumb =
            BuildDdSearchAndList(playerDdFrame, 138)
        playerDdSearch:SetScript("OnTextChanged", function(s)
            local txt = s:GetText()
            local lW = playerDdFrame:GetWidth() - 18
            local h, mW = FillDdList(playerDdListC, lW, playerDdAllRows, txt)
            local listH = math.min(h, DD_MAX_LIST)
            playerDdListSF:SetHeight(listH)
            playerDdFrame:SetWidth(mW + 4)
            playerDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
            C_Timer.After(0, updateThumb)
        end)
        playerDdListSF.updateThumb = updateThumb
    end

    playerDdAllRows = {}
    -- "All Players" option
    table.insert(playerDdAllRows, {
        label    = "All Players",
        selected = (self.selectedPlayer == nil),
        onSelect = function()
            self.selectedPlayer = nil
            playerDdLabel:SetText("Player")
            playerClearBtn:Hide()
            CloseDropdowns()
            self:Refresh()
        end,
    })
    for _, playerName in ipairs(cttLoot.playerNames) do
        local pName = playerName
        table.insert(playerDdAllRows, {
            label    = playerName,
            selected = (self.selectedPlayer == playerName),
            onSelect = function()
                self.selectedPlayer = pName
                playerDdLabel:SetText(pName)
                playerClearBtn:Show()
                CloseDropdowns()
                self:Refresh()
            end,
        })
    end

    playerDdSearch:SetText("")
    local listW = playerDdFrame:GetWidth() - 18
    local h, maxW = FillDdList(playerDdListC, listW, playerDdAllRows, "")
    local listH = math.min(h, DD_MAX_LIST)
    playerDdListSF:SetHeight(listH)
    playerDdFrame:SetWidth(maxW + 4)
    playerDdFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
    C_Timer.After(0, playerDdListSF.updateThumb)
    playerDdSearch:SetFocus()
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
    BuildClassColors()
    PopulateGrid()
end

function cttLoot_UI:ToggleDrawer()
    if not drawer then return end
    drawerOpen = not drawerOpen
    if drawerOpen then drawer:Show() else drawer:Hide() end
end

function cttLoot_UI:Toggle()
    if not window then
        self:Build()
    end
    if window:IsShown() then
        window:Hide(); CloseDropdowns()
    else
        window:Show(); self:Refresh()
    end
end

-- Open the window (build if needed). Does nothing if already visible.
function cttLoot_UI:GetWindow() return window end

function cttLoot_UI:Open()
    if not window then self:Build() end
    if not window:IsShown() then
        window:Show(); self:Refresh()
    end
end

function cttLoot_UI:Close()
    if window and window:IsShown() then
        window:Hide()
    end
end

-- Snap the cttLoot window to the right of the RC voting frame
function cttLoot_UI:SnapToRC()
    if not window then self:Build() end
    if not RCLootCouncil then return end
    local vf = RCLootCouncil:GetActiveModule("votingframe")
    if not vf then return end
    local rcFrame = vf.frame or vf.mainFrame or _G["RCVotingFrame"]
    if not rcFrame or not rcFrame:IsShown() then return end
    window:ClearAllPoints()
    window:SetPoint("TOPLEFT", rcFrame, "TOPRIGHT", 2, -3)
    window:SetMovable(false)
end

function cttLoot_UI:ReleaseSnap()
    if not window then return end
    local left = window:GetLeft()
    local top  = window:GetTop()
    window:ClearAllPoints()
    window:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top - UIParent:GetHeight())
    window:SetMovable(true)
    -- Persist released position so it survives a reload
    if cttLootDB then
        cttLootDB.windowPoint    = "TOPLEFT"
        cttLootDB.windowRelPoint = "TOPLEFT"
        cttLootDB.windowX = left
        cttLootDB.windowY = top - UIParent:GetHeight()
    end
end

function cttLoot_UI:ResetAwardFilter()
    self.awardedOnly = false
    if awardedFilterBtn then
        awardedFilterBtn._label:SetTextColor(RGB(C.text_dim))
    end
end

function cttLoot_UI:Build()
    -- ── Main window ──
    window = CreateFrame("Frame", "cttLootFrame", UIParent)

    -- Restore saved size or use defaults
    local savedW = cttLootDB and cttLootDB.windowW or WIN_W
    local savedH = cttLootDB and cttLootDB.windowH or WIN_H
    window:SetSize(savedW, savedH)

    -- Restore saved position or center, clamping to screen bounds
    local function RestorePosition()
        if not (cttLootDB and cttLootDB.windowX and cttLootDB.windowY and cttLootDB.windowPoint) then
            window:SetPoint("CENTER")
            return
        end
        window:SetPoint(cttLootDB.windowPoint, UIParent, cttLootDB.windowRelPoint or cttLootDB.windowPoint, cttLootDB.windowX, cttLootDB.windowY)
        -- Clamp: if the window's top-left is off-screen, reset to center
        local screenW = UIParent:GetWidth()
        local screenH = UIParent:GetHeight()
        local left  = window:GetLeft()
        local top   = window:GetTop()
        local right = window:GetRight()
        local bot   = window:GetBottom()
        if not left or not top
            or right  < 50 or left > screenW - 50
            or top    < 50 or bot  > screenH - 50 then
            window:ClearAllPoints()
            window:SetPoint("CENTER")
            cttLootDB.windowX = nil
            cttLootDB.windowY = nil
            cttLootDB.windowPoint = nil
        end
    end
    RestorePosition()

    window:SetMovable(true); window:SetResizable(true)
    window:SetResizeBounds(500, 380, 1600, 1100)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function()
        if window:IsMovable() then window:StartMoving() end
    end)
    window:SetScript("OnDragStop", function()
        window:StopMovingOrSizing()
        local point, _, relPoint, x, y = window:GetPoint(1)
        cttLootDB.windowPoint  = point
        cttLootDB.windowRelPoint = relPoint
        cttLootDB.windowX = x
        cttLootDB.windowY = y
    end)
    window:SetFrameStrata("HIGH"); window:SetFrameLevel(100)
    Bg(window, C.bg)
    PixelBorder(window, C.border)

    -- Title bar — flat dark ElvUI style
    local titleBar = CreateFrame("Frame", nil, window)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetPoint("TOPLEFT",  window, "TOPLEFT",  1, -1)
    titleBar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
    Bg(titleBar, C.bg_title)

    -- Thin accent underline under titlebar
    local accentLine = FlatTex(window, "ARTWORK", RGB(C.accent))
    accentLine:SetHeight(1)
    accentLine:SetPoint("TOPLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    accentLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)

    -- Title text
    local titleFS = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFS:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    titleFS:SetTextColor(RGB(C.text_hi))
    titleFS:SetText("cttLoot  "..Clr(C.accent, "·").."  Loot Parser")

    -- Close button (plain X)
    local closeBtn = Btn(window, "X", 22, 18, "danger")
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
    closeBtn:SetScript("OnClick", function()
        window:Hide(); CloseDropdowns()
        if drawer then drawer:Hide(); drawerOpen = false end
    end)

    -- Settings button (same height as X, left of close button)
    local cogBtn = Btn(window, "Settings", 60, 18)
    cogBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    cogBtn:SetScript("OnClick", function()
        drawerOpen = not drawerOpen
        if drawerOpen then drawer:Show() else drawer:Hide() end
    end)

    -- Check button (left of Settings)
    local checkBtn = Btn(window, "Check", 50, 18)
    checkBtn:SetPoint("RIGHT", cogBtn, "LEFT", -2, 0)
    checkBtn:SetScript("OnClick", function()
        cttLoot:RunCheck()
    end)

    -- Awarded filter button (left of Check)
    awardedFilterBtn = Btn(window, "Awarded", 60, 18)
    awardedFilterBtn:SetPoint("RIGHT", checkBtn, "LEFT", -2, 0)
    awardedFilterBtn._label:SetTextColor(RGB(C.text_dim))
    awardedFilterBtn:SetScript("OnClick", function()
        cttLoot_UI.awardedOnly = not cttLoot_UI.awardedOnly
        if cttLoot_UI.awardedOnly then
            awardedFilterBtn._label:SetTextColor(RGB(C.green))
        else
            awardedFilterBtn._label:SetTextColor(RGB(C.text_dim))
        end
        cttLoot_UI:Refresh()
    end)
    -- Override OnLeave/OnMouseUp to restore active-aware color instead of default
    awardedFilterBtn:SetScript("OnLeave", function()
        awardedFilterBtn._bg:SetVertexColor(RGB(C.bg3))
        if cttLoot_UI.awardedOnly then
            awardedFilterBtn._label:SetTextColor(RGB(C.green))
        else
            awardedFilterBtn._label:SetTextColor(RGB(C.text_dim))
        end
    end)
    awardedFilterBtn:SetScript("OnMouseUp", function()
        awardedFilterBtn._bg:SetVertexColor(RGB(C.bg3))
        if cttLoot_UI.awardedOnly then
            awardedFilterBtn._label:SetTextColor(RGB(C.green))
        else
            awardedFilterBtn._label:SetTextColor(RGB(C.text_dim))
        end
    end)
    cttLoot_UI.awardedFilterBtn = awardedFilterBtn

    -- Sort button (left of Awarded) — on by default (delta), off = alphabetical
    sortFilterBtn = Btn(window, "Delta", 45, 18)
    sortFilterBtn:SetPoint("RIGHT", awardedFilterBtn, "LEFT", -2, 0)
    sortFilterBtn._label:SetTextColor(RGB(C.green))  -- on by default
    sortFilterBtn:SetScript("OnClick", function()
        cttLoot_UI.sortByDelta = not cttLoot_UI.sortByDelta
        if cttLoot_UI.sortByDelta then
            sortFilterBtn._label:SetTextColor(RGB(C.green))
        else
            sortFilterBtn._label:SetTextColor(RGB(C.text_dim))
        end
        cttLoot_UI:Refresh()
    end)
    sortFilterBtn:SetScript("OnLeave", function()
        sortFilterBtn._bg:SetVertexColor(RGB(C.bg3))
        if cttLoot_UI.sortByDelta then
            sortFilterBtn._label:SetTextColor(RGB(C.green))
        else
            sortFilterBtn._label:SetTextColor(RGB(C.text_dim))
        end
    end)
    sortFilterBtn:SetScript("OnMouseUp", function()
        sortFilterBtn._bg:SetVertexColor(RGB(C.bg3))
        if cttLoot_UI.sortByDelta then
            sortFilterBtn._label:SetTextColor(RGB(C.green))
        else
            sortFilterBtn._label:SetTextColor(RGB(C.text_dim))
        end
    end)

    -- Resize grip
    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -2, 2)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function()
        window:SetMovable(true)  -- temporarily allow sizing even if snapped
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        -- Restore snap lock if RC integration is active
        if cttLoot_RC:IsEnabled() then
            window:SetMovable(false)
            cttLoot_UI:SnapToRC()
        else
            window:SetMovable(true)
            local point, _, relPoint, x, y = window:GetPoint(1)
            if point then
                cttLootDB.windowPoint    = point
                cttLootDB.windowRelPoint = relPoint
                cttLootDB.windowX = x
                cttLootDB.windowY = y
            end
        end
    end)

    -- Reflow scroll frame and save size whenever window size changes
    local resizeTimer = nil
    window:SetScript("OnSizeChanged", function()
        if not cardScrollF or not cardContent then return end
        cardScrollF:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -22, PAD + 14)
        cardContent:SetWidth(cardScrollF:GetWidth())
        cttLootDB.windowW = math.floor(window:GetWidth())
        cttLootDB.windowH = math.floor(window:GetHeight())
        -- Debounce the expensive Refresh call
        if resizeTimer then resizeTimer:Cancel() end
        resizeTimer = C_Timer.NewTimer(0.15, function()
            resizeTimer = nil
            cttLoot_UI:Refresh()
        end)
    end)

    -- ── Drawer (right-side settings panel) ──
    drawer = BuildDrawer(window)

    -- ── Drawer sections ──
    local importSec = BuildImportSection(drawer)
    BuildDBSection()
    BuildOptionsSection()
    self:RepositionDrawer()

    -- ── Filter bar (anchored below title bar) ──
    filterBar = BuildFilterBar(window, titleBar)

    -- ── Card grid (fills remaining space below filter bar) ──
    BuildCardArea(window, filterBar)

    window:Hide()
end

-- Init on login
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    local ok, err = pcall(function() cttLoot_UI:Build() end)
    if not ok then
        cttLoot:Print("|cffff4444cttLoot UI build error: " .. tostring(err) .. "|r")
        if _G["cttLootFrame"] then _G["cttLootFrame"]:Hide() end
        return
    end
    -- Rebuild playerBestItem whenever parse data changes, not on every grid render
    cttLoot.onDataApplied = function()
        BuildPlayerBestItems()
    end
    BuildPlayerBestItems()
    cttLoot_UI:Refresh()
end)
