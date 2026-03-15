-- cttLoot_UI.lua
-- Mirrors the HTML viewer layout exactly:
--   Title bar (cttLoot · Player DPS Delta Viewer) + ⚙ cog → right-side drawer
--   Drawer: Import Data / Import DB / Simulate Loot panels
--   Main: filter bar (Boss ▾ · sep · Item ▾ · stats) + card grid scroll area
--   Each card: dark header (item name + boss), ranked rows: [rank][name][bar][dps]
--   Card header click → single-item full view (all players, no row limit)

cttLoot_UI = {}
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
local DD_SEARCH_H = 22       -- dropdown search box height
local DD_MAX_LIST = 160      -- max pixel height of dropdown list before scrolling

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
local syncCogColor  = nil   -- set after cogBtn is built; called by drawer X and window close
local cardScrollF   = nil    -- ScrollFrame for card grid
local filterBar     = nil    -- Filter bar (for relayout after stats update)
local sortFilterBtn    = nil -- Sort-by-delta toggle button
local cardContent   = nil    -- content frame inside scroll
local cardPool      = {}     -- active cards in the current grid
local activeCards   = 0
local emptyLabel    = nil    -- reusable "no data" hint label

-- ── Card recycle pool ─────────────────────────────────────────────────────────
-- Pooled cards live in cardGraveyard (off-screen, hidden) when not displayed.
-- Each has MAX_CARD_ROWS pre-built row slots — show/hide slots as needed.
-- Keeps frame count flat across resizes; no allocations during grid rebuild.
local MAX_CARD_ROWS   = 10        -- matches overview rowLimit cap
local cardGraveyard   = nil       -- hidden frame; pooled cards parent here
local cardRecyclePool = {}        -- { card, ... } available for reuse

-- ── Tab state ─────────────────────────────────────────────────────────────────
local activeTab            = "grid"   -- "grid" | "history"
local tabGridBtn           = nil
local tabHistoryBtn        = nil
local historyScrollF       = nil
local historyContent       = nil
local historyEntryPool     = {}
local historySelectedItem  = nil   -- nil = overview, "itemName" = detail view
local historyDetailEntry   = nil   -- the full entry being zoomed into
local historyFilterBar     = nil   -- the filter bar frame for history tab
-- History filter state
local histFilterBoss       = nil
local histFilterPlayer     = nil
local histFilterItem       = nil


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
-- Uses a plain ScrollFrame (no template) so the EditBox fills the full area.
local function ScrollEB(parent, w, h)
    -- Outer container — gives us a background and border over the full region
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(w, h)
    local ebBg = FlatTex(container, "BACKGROUND", RGB(C.bg3))
    ebBg:SetAllPoints(container)
    PixelBorder(container, C.border)

    -- Plain scroll frame pinned inside the container
    local sf = CreateFrame("ScrollFrame", nil, container)
    sf:SetPoint("TOPLEFT",     container, "TOPLEFT",     4,  -4)
    sf:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -4,  4)

    -- EditBox as the scroll child — width matches SF, height grows with content
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)
    eb:SetFontObject("GameFontNormalSmall")
    eb:SetTextColor(RGB(C.text))
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    sf:SetScrollChild(eb)

    -- Keep EB width in sync and always at least as tall as the visible SF area
    local function SyncEB()
        local sfW = sf:GetWidth()
        local sfH = sf:GetHeight()
        if sfW > 0 then eb:SetWidth(sfW) end
        if sfH > 0 and eb:GetHeight() < sfH then eb:SetHeight(sfH) end
    end
    sf:SetScript("OnSizeChanged", SyncEB)
    container:SetScript("OnSizeChanged", SyncEB)

    -- Clicking anywhere in the container focuses the EditBox
    container:EnableMouse(true)
    container:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then eb:SetFocus() end
    end)

    -- Mouse wheel scrolling
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * 20)))
    end)

    -- Return container as "sf" so callers can anchor it the same way
    return container, eb
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

-- Per-player session award flag: { ["PlayerName"] = true } if they received
-- any loot this RC session.  Cleared automatically when new parse data is
-- imported (cttLoot_RC.ClearAwards fires → onDataApplied → awardsDirty).
local awardedSet = {}

local function BuildAwardedSet()
    awardedSet = cttLoot:GetAwardedPlayers()
end

-- Dirty flags — set true when the underlying data changes, cleared after rebuild.
-- Refresh() checks these instead of rebuilding unconditionally every render.
local classColorsDirty = true   -- rebuild on first Refresh and on GROUP_ROSTER_UPDATE
local awardsDirty      = true   -- rebuild on first Refresh, on new award, on data import

local function RebuildIfDirty()
    if classColorsDirty then
        BuildClassColors()
        classColorsDirty = false
    end
    if awardsDirty then
        BuildAwardedSet()
        awardsDirty = false
    end
end

-- Called by cttLoot_RC after each award so the next Refresh picks it up.
function cttLoot_UI.MarkAwardsDirty()
    awardsDirty = true
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
        if syncCogColor then syncCogColor() end
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
    sec.body:SetHeight(160)

    local sf, eb = ScrollEB(sec.body, DRAWER_W - 24, 90)
    sf:SetPoint("TOPLEFT",  sec.body, "TOPLEFT",  PAD, -PAD)
    sf:SetPoint("BOTTOMRIGHT", sec.body, "BOTTOMRIGHT", -PAD, PAD + 20 + PAD)
    csvEB = eb
    -- Don't try to restore raw CSV into the editbox — data is loaded directly from lastData

    local loadBtn = Btn(sec.body, "Load Data",   76, 20, "primary")
    loadBtn:SetPoint("BOTTOMLEFT", sec.body, "BOTTOMLEFT", 2, PAD)
    loadBtn:SetScript("OnClick", function()
        local raw = eb:GetText()
        if not raw or raw == "" then return end
        local data, err = cttLoot:ParseCSV(raw)
        if not data then cttLoot:Print("Parse error: "..(err or "?")); return end
        cttLoot:ApplyData(data, true)
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
        cttLoot:ApplyData({ itemNames={}, playerNames={}, matrix={} }, true)
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
    sec.body:SetHeight(130)

    local sf, eb = ScrollEB(sec.body, sec.body:GetWidth() - 4, 64)
    sf:SetPoint("TOPLEFT",  sec.body, "TOPLEFT",  PAD, -PAD)
    sf:SetPoint("BOTTOMRIGHT", sec.body, "BOTTOMRIGHT", -PAD, PAD + 20 + PAD)
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


-- ── History drawer section ───────────────────────────────────────────────────
-- ── History filter bar ───────────────────────────────────────────────────────
local histFilterContested = false  -- only show entries where winner wasn't #1

-- Forward declarations — defined later in the file but referenced inside
-- BuildHistoryFilterBar's OnClick closures which are compiled now.
local BuildDdSearchAndList, FillDdList

local function BuildHistoryFilterBar(parent, topAnchor)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(FBAR_H)
    bar:SetPoint("TOPLEFT",  topAnchor, "BOTTOMLEFT",  0, -PAD)
    bar:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -PAD)
    Bg(bar, C.bg2)
    PixelBorder(bar, C.border)
    bar:Hide()

    local hfVisible = true

    -- ── Helpers ──
    local function GetHistoryBosses()
        local seen, out = {}, {}
        for _, e in ipairs(cttLootDB and cttLootDB.history or {}) do
            if e.boss and not seen[e.boss] then seen[e.boss]=true; table.insert(out, e.boss) end
        end
        table.sort(out); return out
    end
    -- Only players who have won something (and only their won items)
    local function GetHistoryWinners()
        local seen, out = {}, {}
        for _, e in ipairs(cttLootDB and cttLootDB.history or {}) do
            if e.winner and not seen[e.winner] then seen[e.winner]=true; table.insert(out, e.winner) end
        end
        table.sort(out); return out
    end
    local function GetHistoryItems()
        local seen, out = {}, {}
        for _, e in ipairs(cttLootDB and cttLootDB.history or {}) do
            -- if a player filter is active, only show items that player won
            local playerMatch = (not histFilterPlayer) or (e.winner == histFilterPlayer)
            if playerMatch and e.itemName and not seen[e.itemName] then
                seen[e.itemName]=true; table.insert(out, e.itemName)
            end
        end
        table.sort(out); return out
    end

    -- Collapse toggle
    local toggleBtn = Btn(bar, "<<", 26, 20)
    toggleBtn:SetPoint("LEFT", bar, "LEFT", 4, 0)

    -- Boss dropdown — parented to window (parent) so frame level is always on top
    local bossDd = CreateFrame("Frame", nil, parent)
    bossDd:SetFrameLevel(500)
    Bg(bossDd, C.bg2); PixelBorder(bossDd, C.accent); bossDd:Hide(); bossDd:EnableMouse(true)

    local bossBtn2 = Btn(bar, "", 130, 20)
    local bossDdLbl = bossBtn2._label; bossDdLbl:SetText("Boss"); bossDdLbl:SetJustifyH("LEFT")
    local bossArrow2 = bar:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    bossArrow2:SetPoint("RIGHT", bossBtn2, "RIGHT", -4, 0)
    bossArrow2:SetTextColor(RGB(C.text_dim)); bossArrow2:SetText("▾")
    local bossClear2 = Btn(bar, "X", 16, 16, "danger"); bossClear2:Hide()
    bossDd:SetPoint("TOPLEFT", bossBtn2, "BOTTOMLEFT", 0, -2)

    -- Player dropdown — parented to window so frame level is always on top
    local playerDd2 = CreateFrame("Frame", nil, parent)
    playerDd2:SetFrameLevel(500)
    Bg(playerDd2, C.bg2); PixelBorder(playerDd2, C.accent); playerDd2:Hide(); playerDd2:EnableMouse(true)

    local playerBtn2 = Btn(bar, "", 110, 20)
    local playerDdLbl = playerBtn2._label; playerDdLbl:SetText("Player"); playerDdLbl:SetJustifyH("LEFT")
    local playerArrow2 = bar:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    playerArrow2:SetPoint("RIGHT", playerBtn2, "RIGHT", -4, 0)
    playerArrow2:SetTextColor(RGB(C.text_dim)); playerArrow2:SetText("▾")
    local playerClear2 = Btn(bar, "X", 16, 16, "danger"); playerClear2:Hide()
    playerDd2:SetPoint("TOPLEFT", playerBtn2, "BOTTOMLEFT", 0, -2)

    -- Item dropdown — parented to window so frame level is always on top
    local itemDd2 = CreateFrame("Frame", nil, parent)
    itemDd2:SetFrameLevel(500)
    Bg(itemDd2, C.bg2); PixelBorder(itemDd2, C.accent); itemDd2:Hide(); itemDd2:EnableMouse(true)

    local itemBtn2 = Btn(bar, "", 160, 20)
    local itemDdLbl = itemBtn2._label; itemDdLbl:SetText("Item"); itemDdLbl:SetJustifyH("LEFT")
    local itemArrow2 = bar:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    itemArrow2:SetPoint("RIGHT", itemBtn2, "RIGHT", -4, 0)
    itemArrow2:SetTextColor(RGB(C.text_dim)); itemArrow2:SetText("▾")
    local itemClear2 = Btn(bar, "X", 16, 16, "danger"); itemClear2:Hide()
    itemDd2:SetPoint("TOPLEFT", itemBtn2, "BOTTOMLEFT", 0, -2)

    -- Contested toggle button — winner wasn't #1 in the sims
    local contestedBtn = Btn(bar, "Contested", 74, 20)
    contestedBtn._label:SetTextColor(RGB(C.text_dim))
    -- Helper: apply the correct label color for current active state
    local function SetContestedColor()
        if histFilterContested then
            contestedBtn._label:SetTextColor(RGB(C.green))
        else
            contestedBtn._label:SetTextColor(RGB(C.text_dim))
        end
    end
    -- Override ALL four Btn scripts so active-state color is always respected
    contestedBtn:SetScript("OnClick", function()
        histFilterContested = not histFilterContested
        SetContestedColor()
        historySelectedItem = nil; historyDetailEntry = nil
        cttLoot_UI:RefreshHistoryTab()
    end)
    contestedBtn:SetScript("OnEnter", function()
        contestedBtn._bg:SetVertexColor(RGB(C.accent2))
        SetContestedColor()   -- keep green/dim, never force white
    end)
    contestedBtn:SetScript("OnLeave", function()
        contestedBtn._bg:SetVertexColor(RGB(C.bg3))
        SetContestedColor()
    end)
    contestedBtn:SetScript("OnMouseDown", function()
        contestedBtn._bg:SetVertexColor(RGB(C.accent))
        SetContestedColor()   -- keep green/dim on press too
    end)
    contestedBtn:SetScript("OnMouseUp", function()
        contestedBtn._bg:SetVertexColor(RGB(C.bg3))
        SetContestedColor()
    end)

    -- ── Per-dropdown search/list state (lazy-built on first open) ──
    local hBossDdSearch, hBossDdListSF, hBossDdListC, hBossDdThumb
    local hPlyrDdSearch, hPlyrDdListSF, hPlyrDdListC, hPlyrDdThumb
    local hItemDdSearch, hItemDdListSF, hItemDdListC, hItemDdThumb
    local hBossDdRows, hPlyrDdRows, hItemDdRows = {}, {}, {}

    -- ── Dropdown close helper ──
    local function CloseHDd()
        bossDd:Hide(); playerDd2:Hide(); itemDd2:Hide()
    end

    -- ── Shared open helper — mirrors PopulateBossDropdown pattern ──
    -- lW seed: use current width if already sized, else 120 minimum so FillDdList
    -- gets a valid positive number before we resize ddFrame to fit content.
    local function OpenHDd(ddFrame, searchEB, listSF, listC, rows, updateThumb)
        searchEB:SetText("")
        local seedW = math.max(ddFrame:GetWidth(), 120)
        local lW = seedW - 18
        local h, maxW = FillDdList(listC, lW, rows, "")
        local listH = math.min(h, DD_MAX_LIST)
        listSF:SetHeight(listH)
        ddFrame:SetWidth(maxW + 4)
        ddFrame:SetHeight(DD_SEARCH_H + 4 + listH + 4)
        C_Timer.After(0, updateThumb)
        searchEB:SetFocus()
        ddFrame:Show()
    end

    -- ── Layout: Boss → Item → Player (left), Contested pinned right ──
    local GAP        = 3
    local CLEAR_W    = 16
    local TOGGLE_W   = 4 + 26 + GAP
    local CONT_RIGHT = 74 + 8
    -- All anchors set once here — HRelayout only calls SetWidth.
    bossBtn2:SetPoint("LEFT", toggleBtn, "RIGHT", GAP, 0)
    bossClear2:SetPoint("LEFT", bossBtn2, "RIGHT", GAP, 0)
    itemBtn2:SetPoint("LEFT", bossClear2, "RIGHT", GAP, 0)
    itemClear2:SetPoint("LEFT", itemBtn2, "RIGHT", GAP, 0)
    playerBtn2:SetPoint("LEFT", itemClear2, "RIGHT", GAP, 0)
    playerClear2:SetPoint("LEFT", playerBtn2, "RIGHT", GAP, 0)
    contestedBtn:SetPoint("RIGHT", bar, "RIGHT", -8, 0)

    local _lastBossW2, _lastItemW2, _lastPlayerW2 = 0, 0, 0
    local function HRelayout()
        local barW = bar:GetWidth(); if barW < 50 then return end
        local fixed = TOGGLE_W + (CLEAR_W + GAP) * 3 + CONT_RIGHT + GAP
        local avail = math.max(barW - fixed, 120)
        local bossW   = math.floor(avail * 0.30)
        local itemW   = math.floor(avail * 0.40)
        local playerW = avail - bossW - itemW
        if bossW   ~= _lastBossW2   then bossBtn2:SetWidth(bossW);     _lastBossW2   = bossW   end
        if itemW   ~= _lastItemW2   then itemBtn2:SetWidth(itemW);     _lastItemW2   = itemW   end
        if playerW ~= _lastPlayerW2 then playerBtn2:SetWidth(playerW); _lastPlayerW2 = playerW end
    end
    bar:SetScript("OnSizeChanged", HRelayout)
    bar.Relayout = HRelayout

    -- ── Boss wiring ──
    bossBtn2:SetScript("OnClick", function()
        if bossDd:IsShown() then CloseHDd(); return end
        CloseHDd()
        if not hBossDdSearch then
            hBossDdSearch, hBossDdListSF, hBossDdListC, hBossDdThumb =
                BuildDdSearchAndList(bossDd, 180)
            hBossDdSearch:SetScript("OnTextChanged", function(s)
                local h2, mW = FillDdList(hBossDdListC, bossDd:GetWidth()-18, hBossDdRows, s:GetText())
                local lH = math.min(h2, DD_MAX_LIST)
                hBossDdListSF:SetHeight(lH)
                bossDd:SetWidth(mW+4); bossDd:SetHeight(DD_SEARCH_H+4+lH+4)
                C_Timer.After(0, hBossDdThumb)
            end)
        end
        hBossDdRows = {}
        table.insert(hBossDdRows, {
            label = "All Bosses", selected = (histFilterBoss == nil),
            onSelect = function()
                histFilterBoss = nil; bossDdLbl:SetText("Boss"); bossClear2:Hide()
                historySelectedItem = nil; historyDetailEntry = nil
                CloseHDd(); cttLoot_UI:RefreshHistoryTab()
            end,
        })
        for _, v in ipairs(GetHistoryBosses()) do
            local cap = v
            table.insert(hBossDdRows, {
                label = v, selected = (histFilterBoss == v),
                onSelect = function()
                    histFilterBoss = cap; bossDdLbl:SetText(cap)
                    if hfVisible then bossClear2:Show() end
                    historySelectedItem = nil; historyDetailEntry = nil
                    CloseHDd(); cttLoot_UI:RefreshHistoryTab()
                end,
            })
        end
        OpenHDd(bossDd, hBossDdSearch, hBossDdListSF, hBossDdListC, hBossDdRows, hBossDdThumb)
    end)
    bossClear2:SetScript("OnClick", function()
        histFilterBoss = nil; bossDdLbl:SetText("Boss"); bossClear2:Hide()
        historySelectedItem = nil; historyDetailEntry = nil
        cttLoot_UI:RefreshHistoryTab()
    end)

    -- ── Player wiring ──
    playerBtn2:SetScript("OnClick", function()
        if playerDd2:IsShown() then CloseHDd(); return end
        CloseHDd()
        if not hPlyrDdSearch then
            hPlyrDdSearch, hPlyrDdListSF, hPlyrDdListC, hPlyrDdThumb =
                BuildDdSearchAndList(playerDd2, 160)
            hPlyrDdSearch:SetScript("OnTextChanged", function(s)
                local h2, mW = FillDdList(hPlyrDdListC, playerDd2:GetWidth()-18, hPlyrDdRows, s:GetText())
                local lH = math.min(h2, DD_MAX_LIST)
                hPlyrDdListSF:SetHeight(lH)
                playerDd2:SetWidth(mW+4); playerDd2:SetHeight(DD_SEARCH_H+4+lH+4)
                C_Timer.After(0, hPlyrDdThumb)
            end)
        end
        hPlyrDdRows = {}
        table.insert(hPlyrDdRows, {
            label = "All Players", selected = (histFilterPlayer == nil),
            onSelect = function()
                histFilterPlayer = nil; playerDdLbl:SetText("Player"); playerClear2:Hide()
                historySelectedItem = nil; historyDetailEntry = nil
                CloseHDd(); cttLoot_UI:RefreshHistoryTab()
            end,
        })
        for _, v in ipairs(GetHistoryWinners()) do
            local cap = v
            table.insert(hPlyrDdRows, {
                label = v, selected = (histFilterPlayer == v),
                onSelect = function()
                    histFilterPlayer = cap; playerDdLbl:SetText(cap)
                    histFilterItem = nil; itemDdLbl:SetText("Item"); itemClear2:Hide()
                    if hfVisible then playerClear2:Show() end
                    historySelectedItem = nil; historyDetailEntry = nil
                    CloseHDd(); cttLoot_UI:RefreshHistoryTab()
                end,
            })
        end
        OpenHDd(playerDd2, hPlyrDdSearch, hPlyrDdListSF, hPlyrDdListC, hPlyrDdRows, hPlyrDdThumb)
    end)
    playerClear2:SetScript("OnClick", function()
        histFilterPlayer = nil; playerDdLbl:SetText("Player"); playerClear2:Hide()
        historySelectedItem = nil; historyDetailEntry = nil
        cttLoot_UI:RefreshHistoryTab()
    end)

    -- ── Item wiring ──
    itemBtn2:SetScript("OnClick", function()
        if itemDd2:IsShown() then CloseHDd(); return end
        CloseHDd()
        if not hItemDdSearch then
            hItemDdSearch, hItemDdListSF, hItemDdListC, hItemDdThumb =
                BuildDdSearchAndList(itemDd2, 210)
            hItemDdSearch:SetScript("OnTextChanged", function(s)
                local h2, mW = FillDdList(hItemDdListC, itemDd2:GetWidth()-18, hItemDdRows, s:GetText())
                local lH = math.min(h2, DD_MAX_LIST)
                hItemDdListSF:SetHeight(lH)
                itemDd2:SetWidth(mW+4); itemDd2:SetHeight(DD_SEARCH_H+4+lH+4)
                C_Timer.After(0, hItemDdThumb)
            end)
        end
        hItemDdRows = {}
        table.insert(hItemDdRows, {
            label = "All Items", selected = (histFilterItem == nil),
            onSelect = function()
                histFilterItem = nil; itemDdLbl:SetText("Item"); itemClear2:Hide()
                historySelectedItem = nil; historyDetailEntry = nil
                CloseHDd(); cttLoot_UI:RefreshHistoryTab()
            end,
        })
        for _, v in ipairs(GetHistoryItems()) do
            local cap = v
            table.insert(hItemDdRows, {
                label = v, selected = (histFilterItem == v),
                onSelect = function()
                    histFilterItem = cap; itemDdLbl:SetText(cap)
                    if hfVisible then itemClear2:Show() end
                    historySelectedItem = nil; historyDetailEntry = nil
                    CloseHDd(); cttLoot_UI:RefreshHistoryTab()
                end,
            })
        end
        OpenHDd(itemDd2, hItemDdSearch, hItemDdListSF, hItemDdListC, hItemDdRows, hItemDdThumb)
    end)
    itemClear2:SetScript("OnClick", function()
        histFilterItem = nil; itemDdLbl:SetText("Item"); itemClear2:Hide()
        historySelectedItem = nil; historyDetailEntry = nil
        cttLoot_UI:RefreshHistoryTab()
    end)

    -- ── Collapse toggle ──
    local hfElements = { bossBtn2, bossArrow2, playerBtn2, playerArrow2,
                         itemBtn2, itemArrow2, contestedBtn }
    local function SetHFVisible(vis)
        hfVisible = vis
        for _, el in ipairs(hfElements) do if vis then el:Show() else el:Hide() end end
        if not vis then
            CloseHDd()
            bossClear2:Hide(); playerClear2:Hide(); itemClear2:Hide()
        else
            if histFilterBoss   then bossClear2:Show()   end
            if histFilterPlayer then playerClear2:Show() end
            if histFilterItem   then itemClear2:Show()   end
        end
        toggleBtn._label:SetText(vis and "<<" or ">>")
    end
    toggleBtn:SetScript("OnClick", function() SetHFVisible(not hfVisible) end)

    C_Timer.After(0, HRelayout)
    historyFilterBar = bar
    return bar
end

-- ── History tab content area ──────────────────────────────────────────────────
local function BuildHistoryArea(parent, topAnchor, bottomAnchor)
    historyScrollF = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    -- Anchor below the history filter bar (which is itself below topAnchor)
    historyScrollF:SetPoint("TOPLEFT",  historyFilterBar, "BOTTOMLEFT",  0, -PAD)
    if bottomAnchor then
        historyScrollF:SetPoint("BOTTOMRIGHT", bottomAnchor, "TOPRIGHT", -22, PAD)
    else
        historyScrollF:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, PAD + 14)
    end
    Bg(historyScrollF, C.bg3)
    PixelBorder(historyScrollF, C.border)

    historyContent = CreateFrame("Frame", nil, historyScrollF)
    historyContent:SetWidth(historyScrollF:GetWidth())
    historyContent:SetHeight(1)
    historyScrollF:SetScrollChild(historyContent)
    historyScrollF:Hide()
end

local function ClearHistoryArea()
    if not historyContent then return end
    for _, f in ipairs(historyEntryPool) do
        f:Hide()
    end
    historyEntryPool = {}
    historyContent:SetHeight(1)
end

-- Format a unix timestamp as "YYYY-MM-DD HH:MM"
local function FormatTime(ts)
    local d = date("*t", ts)
    return string.format("%02d-%02d-%04d  %02d:%02d", d.month, d.day, d.year, d.hour, d.min)
end

function cttLoot_UI:RefreshHistoryTab()
    if not historyContent then return end
    ClearHistoryArea()

    local rawEntries = cttLoot_History and cttLoot_History:GetAll() or {}
    -- Apply filters
    local allEntries = {}
    for _, e in ipairs(rawEntries) do
        local pass = true
        if histFilterBoss   and e.boss     ~= histFilterBoss   then pass = false end
        if histFilterPlayer and e.winner   ~= histFilterPlayer  then pass = false end
        if histFilterItem   and e.itemName ~= histFilterItem   then pass = false end
        -- Contested: winner was not ranked #1 in the frozen sim snapshot.
        -- We use vals.base (not catalyst) for ranking, matching the main grid sort.
        -- If no sim data exists for this entry we cannot determine rank, so exclude it.
        if pass and histFilterContested then
            local topDps, topPlayer = -math.huge, nil
            for playerName, vals in pairs(e.sims or {}) do
                local base = vals.base
                if base and base > topDps then topDps = base; topPlayer = playerName end
            end
            if not topPlayer then
                -- no sim data — can't confirm contested, exclude
                pass = false
            elseif e.winner == topPlayer then
                -- winner WAS the top sim — not contested
                pass = false
            end
            -- else: winner exists but was not #1 — contested, keep
        end
        if pass then table.insert(allEntries, e) end
    end
    local gridW = historyScrollF:GetWidth() - 4

    if #allEntries == 0 then
        local lbl = historyContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOP", historyContent, "TOP", 0, -50)
        lbl:SetTextColor(RGB(C.text_dim))
        lbl:SetText("No loot decisions recorded yet.")
        table.insert(historyEntryPool, lbl)
        historyContent:SetHeight(120)
        return
    end

    -- ── Detail view ──────────────────────────────────────────────────────────
    if historySelectedItem and historyDetailEntry then
        local entry  = historyDetailEntry
        local cardW  = gridW - PAD * 2

        -- Build sorted sim rows from the frozen snapshot (show all, including negatives)
        local simRows = {}
        for playerName, vals in pairs(entry.sims or {}) do
            if vals.base then table.insert(simRows, { player=playerName, dps=vals.base, isCat=false }) end
            if vals.cat  then table.insert(simRows, { player=playerName, dps=vals.cat,  isCat=true  }) end
        end
        table.sort(simRows, function(a,b) return a.dps > b.dps end)

        local maxAbs = 1
        for _, r in ipairs(simRows) do if math.abs(r.dps) > maxAbs then maxAbs = math.abs(r.dps) end end

        -- Header heights (mirrors MakeCard logic)
        local hasBoss = entry.boss and entry.boss ~= ""
        local hdrH = 20
        if hasBoss then hdrH = 32 end
        if hasBoss and entry.winner then hdrH = 44 end
        local cardH = hdrH + #simRows * ROW_H + 2

        local card = CreateFrame("Frame", nil, historyContent)
        card:SetSize(cardW, cardH)
        card:SetPoint("TOPLEFT", historyContent, "TOPLEFT", PAD, -PAD)
        Bg(card, C.card_bg)
        PixelBorder(card, C.border)
        table.insert(historyEntryPool, card)

        -- Header button — clicking back returns to overview
        local hdr = CreateFrame("Button", nil, card)
        hdr:SetHeight(hdrH)
        hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
        local hdrBg = Bg(hdr, C.card_hdr)

        local titleFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        titleFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -4)
        titleFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -4)
        titleFS:SetHeight(12)
        titleFS:SetTextColor(RGB(C.text_hi))
        titleFS:SetText(entry.itemName or "Unknown")
        titleFS:SetJustifyH("LEFT"); titleFS:SetWordWrap(false); titleFS:SetNonSpaceWrap(false)

        if hasBoss then
            local bossFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            bossFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -17)
            bossFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -17)
            bossFS:SetHeight(12)
            bossFS:SetTextColor(RGB(C.accent))
            bossFS:SetText(entry.boss)
            bossFS:SetJustifyH("LEFT"); bossFS:SetWordWrap(false); bossFS:SetNonSpaceWrap(false)
        end

        if entry.winner then
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
            winnerFS:SetHeight(12); winnerFS:SetWordWrap(false); winnerFS:SetNonSpaceWrap(false)
            winnerFS:SetTextColor(0.2, 1, 0.2, 1)
            -- Date on the right side of the winner line
            local dateStr = FormatTime(entry.timestamp)
            winnerFS:SetText(">> " .. entry.winner .. "  |cff6e6e6e" .. dateStr .. "|r")
        end

        hdr:SetScript("OnEnter", function() hdrBg:SetVertexColor(RGB(C.accent2)) end)
        hdr:SetScript("OnLeave", function() hdrBg:SetVertexColor(RGB(C.card_hdr)) end)
        hdr:SetScript("OnClick", function()
            historySelectedItem = nil
            historyDetailEntry  = nil
            cttLoot_UI:RefreshHistoryTab()
        end)

        -- Rows
        for i, row in ipairs(simRows) do
            local ry = hdrH + (i-1) * ROW_H
            local isWinner = (not row.isCat) and (row.player == entry.winner)

            if isWinner then
                local ar, ag, ab = RGB(C.accent)
                local bestBg = FlatTex(card, "BACKGROUND", ar, ag, ab, 0.15)
                bestBg:SetSize(cardW, ROW_H)
                bestBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
            elseif i % 2 == 0 then
                local rowBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.03)
                rowBg:SetSize(cardW, ROW_H)
                rowBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
            end

            local rankFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rankFS:SetSize(COL_RANK, ROW_H)
            rankFS:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -ry)
            rankFS:SetJustifyH("CENTER"); rankFS:SetJustifyV("MIDDLE")
            if     i == 1 then rankFS:SetTextColor(RGB(C.rank_gold))
            elseif i == 2 then rankFS:SetTextColor(RGB(C.rank_silver))
            elseif i == 3 then rankFS:SetTextColor(RGB(C.rank_bronze))
            else               rankFS:SetTextColor(RGB(C.text_dim)) end
            rankFS:SetText(tostring(i))

            local nameFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nameFS:SetSize(COL_NAME, ROW_H)
            nameFS:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + 2, -ry)
            nameFS:SetJustifyH("LEFT"); nameFS:SetJustifyV("MIDDLE")
            local cc = GetClassColor(row.player)
            if row.isCat then
                nameFS:SetText(Clr(C.catalyst, "*") .. " " .. row.player)
                if cc then nameFS:SetTextColor(cc[1],cc[2],cc[3]) else nameFS:SetTextColor(RGB(C.text)) end
            else
                nameFS:SetText(row.player)
                if cc then nameFS:SetTextColor(cc[1],cc[2],cc[3]) else nameFS:SetTextColor(RGB(C.text)) end
            end

            local dynBarW = cardW - COL_RANK - COL_NAME - COL_DPS - 10
            local barBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.06)
            barBg:SetSize(dynBarW, BAR_H)
            barBg:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + COL_NAME + 2, -ry - (ROW_H - BAR_H) / 2)

            local barPct  = math.max(0.01, math.abs(row.dps) / maxAbs)
            local fillW   = math.max(2, math.floor(barPct * dynBarW))
            local barFill = FlatTex(card, "ARTWORK", 1, 1, 1, 0.85)
            barFill:SetSize(fillW, BAR_H)
            barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 0, 0)
            if row.isCat then barFill:SetVertexColor(RGB(C.catalyst))
            elseif row.dps >= 0 then barFill:SetVertexColor(RGB(C.green))
            else barFill:SetVertexColor(RGB(C.red)) end

            local dpsFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            dpsFS:SetSize(COL_DPS, ROW_H)
            dpsFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -ry)
            dpsFS:SetJustifyH("RIGHT"); dpsFS:SetJustifyV("MIDDLE")
            local sign = row.dps >= 0 and "+" or ""
            dpsFS:SetText(string.format("%s%.0f", sign, row.dps))
            if row.isCat then dpsFS:SetTextColor(RGB(C.catalyst))
            elseif row.dps >= 0 then dpsFS:SetTextColor(RGB(C.green))
            else dpsFS:SetTextColor(RGB(C.red)) end

            if i < #simRows then
                local sep = FlatTex(card, "BACKGROUND", RGB(C.border))
                sep:SetHeight(1)
                sep:SetPoint("BOTTOMLEFT",  card, "TOPLEFT",  0, -(ry + ROW_H - 1))
                sep:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", 0, -(ry + ROW_H - 1))
            end
        end

        historyContent:SetWidth(gridW)
        historyContent:SetHeight(math.max(cardH + PAD * 2, 80))
        return
    end

    -- ── Overview grid ─────────────────────────────────────────────────────────
    -- Build one compact card per history entry (same multi-column layout as main grid)
    local cols    = math.max(1, math.floor((gridW + CARD_GAP) / (CARD_W + CARD_GAP)))
    local col     = 0
    local totalH  = PAD
    local rowMaxH = 0

    for _, entry in ipairs(allEntries) do
        -- Build sorted sim rows, capped at 10 rows like the main overview
        local simRows = {}
        for playerName, vals in pairs(entry.sims or {}) do
            if vals.base and vals.base >= 0 then
                table.insert(simRows, { player=playerName, dps=vals.base, isCat=false })
            end
            if vals.cat and vals.cat >= 0 then
                table.insert(simRows, { player=playerName, dps=vals.cat,  isCat=true })
            end
        end
        table.sort(simRows, function(a,b) return a.dps > b.dps end)
        -- Cap at 10
        while #simRows > 10 do table.remove(simRows) end

        local maxAbs = 1
        for _, r in ipairs(simRows) do if math.abs(r.dps) > maxAbs then maxAbs = math.abs(r.dps) end end

        local hasBoss = entry.boss and entry.boss ~= ""
        local hdrH = 20
        if hasBoss then hdrH = 32 end
        if hasBoss and entry.winner then hdrH = 44 end
        local cardH = hdrH + #simRows * ROW_H + 2

        local ox   = PAD + col * (CARD_W + CARD_GAP)
        local card = CreateFrame("Frame", nil, historyContent)
        card:SetSize(CARD_W, cardH)
        card:SetPoint("TOPLEFT", historyContent, "TOPLEFT", ox, -totalH)
        Bg(card, C.card_bg)
        PixelBorder(card, C.border)
        table.insert(historyEntryPool, card)

        -- Header button
        local hdr = CreateFrame("Button", nil, card)
        hdr:SetHeight(hdrH)
        hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
        local hdrBg = Bg(hdr, C.card_hdr)

        local titleFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        titleFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -4)
        titleFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -4)
        titleFS:SetHeight(12)
        titleFS:SetTextColor(RGB(C.text_hi))
        titleFS:SetText(entry.itemName or "Unknown")
        titleFS:SetJustifyH("LEFT"); titleFS:SetWordWrap(false); titleFS:SetNonSpaceWrap(false)

        if hasBoss then
            local bossFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            bossFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -17)
            bossFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -17)
            bossFS:SetHeight(12)
            bossFS:SetTextColor(RGB(C.accent))
            bossFS:SetText(entry.boss)
            bossFS:SetJustifyH("LEFT"); bossFS:SetWordWrap(false); bossFS:SetNonSpaceWrap(false)
        end

        if entry.winner then
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
            winnerFS:SetHeight(12); winnerFS:SetWordWrap(false); winnerFS:SetNonSpaceWrap(false)
            winnerFS:SetTextColor(0.2, 1, 0.2, 1)
            local dateStr = FormatTime(entry.timestamp)
            winnerFS:SetText(">> " .. entry.winner .. "  |cff6e6e6e" .. dateStr .. "|r")
        end

        hdr:SetScript("OnEnter", function() hdrBg:SetVertexColor(RGB(C.accent2)) end)
        hdr:SetScript("OnLeave", function() hdrBg:SetVertexColor(RGB(C.card_hdr)) end)

        -- Capture entry for click closure
        local capturedEntry = entry
        hdr:SetScript("OnClick", function()
            historySelectedItem = capturedEntry.itemName
            historyDetailEntry  = capturedEntry
            cttLoot_UI:RefreshHistoryTab()
        end)

        -- Rows
        for i, row in ipairs(simRows) do
            local ry       = hdrH + (i-1) * ROW_H
            local isWinner = (not row.isCat) and (row.player == entry.winner)

            if isWinner then
                local ar, ag, ab = RGB(C.accent)
                local bestBg = FlatTex(card, "BACKGROUND", ar, ag, ab, 0.15)
                bestBg:SetSize(CARD_W, ROW_H)
                bestBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
            elseif i % 2 == 0 then
                local rowBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.03)
                rowBg:SetSize(CARD_W, ROW_H)
                rowBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
            end

            local rankFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rankFS:SetSize(COL_RANK, ROW_H)
            rankFS:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -ry)
            rankFS:SetJustifyH("CENTER"); rankFS:SetJustifyV("MIDDLE")
            if     i == 1 then rankFS:SetTextColor(RGB(C.rank_gold))
            elseif i == 2 then rankFS:SetTextColor(RGB(C.rank_silver))
            elseif i == 3 then rankFS:SetTextColor(RGB(C.rank_bronze))
            else               rankFS:SetTextColor(RGB(C.text_dim)) end
            rankFS:SetText(tostring(i))

            local nameFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nameFS:SetSize(COL_NAME, ROW_H)
            nameFS:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + 2, -ry)
            nameFS:SetJustifyH("LEFT"); nameFS:SetJustifyV("MIDDLE")
            local cc = GetClassColor(row.player)
            if row.isCat then
                nameFS:SetText(Clr(C.catalyst, "*") .. " " .. row.player)
            else
                nameFS:SetText(row.player)
            end
            if cc then nameFS:SetTextColor(cc[1],cc[2],cc[3]) else nameFS:SetTextColor(RGB(C.text)) end

            local dynBarW = CARD_W - COL_RANK - COL_NAME - COL_DPS - 10
            local barBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.06)
            barBg:SetSize(dynBarW, BAR_H)
            barBg:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + COL_NAME + 2, -ry - (ROW_H - BAR_H) / 2)

            local barPct  = math.max(0.01, math.abs(row.dps) / maxAbs)
            local fillW   = math.max(2, math.floor(barPct * dynBarW))
            local barFill = FlatTex(card, "ARTWORK", 1, 1, 1, 0.85)
            barFill:SetSize(fillW, BAR_H)
            barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 0, 0)
            if row.isCat then barFill:SetVertexColor(RGB(C.catalyst))
            elseif row.dps >= 0 then barFill:SetVertexColor(RGB(C.green))
            else barFill:SetVertexColor(RGB(C.red)) end

            local dpsFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            dpsFS:SetSize(COL_DPS, ROW_H)
            dpsFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -ry)
            dpsFS:SetJustifyH("RIGHT"); dpsFS:SetJustifyV("MIDDLE")
            local sign = row.dps >= 0 and "+" or ""
            dpsFS:SetText(string.format("%s%.0f", sign, row.dps))
            if row.isCat then dpsFS:SetTextColor(RGB(C.catalyst))
            elseif row.dps >= 0 then dpsFS:SetTextColor(RGB(C.green))
            else dpsFS:SetTextColor(RGB(C.red)) end

            if i < #simRows then
                local sep = FlatTex(card, "BACKGROUND", RGB(C.border))
                sep:SetHeight(1)
                sep:SetPoint("BOTTOMLEFT",  card, "TOPLEFT",  0, -(ry + ROW_H - 1))
                sep:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", 0, -(ry + ROW_H - 1))
            end
        end

        if cardH > rowMaxH then rowMaxH = cardH end
        col = col + 1
        if col >= cols then
            col      = 0
            totalH   = totalH + rowMaxH + CARD_GAP
            rowMaxH  = 0
        end
    end
    if col > 0 then totalH = totalH + rowMaxH + CARD_GAP end

    historyContent:SetWidth(gridW)
    historyContent:SetHeight(math.max(totalH, 80))
end


-- ── Options section ───────────────────────────────────────────────────────────
local rcHookBtn = nil
local function BuildOptionsSection()
    local sec = MakeDrawerSection(drawer, "Options", 0)
    sec.body:SetHeight(172)

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
            -- Only snap immediately if a session is currently active
            if cttLoot_RC:IsSessionActive() then
                cttLoot_UI:SnapToRC()
            end
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

    -- ── Divider — centred in the gap between Disable RC and History label ──
    local div = FlatTex(sec.body, "BACKGROUND", RGB(C.border))
    div:SetHeight(1)
    div:SetPoint("TOPLEFT",  sec.body, "TOPLEFT",  2, -60)
    div:SetPoint("TOPRIGHT", sec.body, "TOPRIGHT", -2, -60)

    -- History sub-label
    local histLabel = sec.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    histLabel:SetPoint("TOPLEFT", sec.body, "TOPLEFT", 4, -65)
    histLabel:SetTextColor(RGB(C.text_dim))

    local function RefreshCount()
        local n = cttLoot_History and cttLoot_History:Count() or 0
        histLabel:SetText(n == 1 and "History: 1 decision" or "History: "..n.." decisions")
    end
    RefreshCount()

    -- "Delete older than N days" row
    local pruneLabel = sec.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pruneLabel:SetPoint("TOPLEFT", sec.body, "TOPLEFT", 4, -83)
    pruneLabel:SetTextColor(RGB(C.text))
    pruneLabel:SetText("Delete entries older than")

    local daysEB = CreateFrame("EditBox", nil, sec.body)
    daysEB:SetSize(36, 18)
    daysEB:SetPoint("LEFT", pruneLabel, "RIGHT", 6, 0)
    daysEB:SetAutoFocus(false)
    daysEB:SetMaxLetters(3)
    daysEB:SetNumeric(true)
    daysEB:SetFontObject("GameFontNormalSmall")
    daysEB:SetTextColor(RGB(C.text))
    daysEB:SetTextInsets(4, 4, 0, 0)
    daysEB:SetText("30")
    local daysEBbg = FlatTex(daysEB, "BACKGROUND", RGB(C.bg3))
    daysEBbg:SetAllPoints(daysEB)
    PixelBorder(daysEB, C.border)
    daysEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    daysEB:SetScript("OnEnterPressed",  function(s) s:ClearFocus() end)

    local daysLabel2 = sec.body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    daysLabel2:SetPoint("LEFT", daysEB, "RIGHT", 4, 0)
    daysLabel2:SetTextColor(RGB(C.text))
    daysLabel2:SetText("days")

    local pruneBtn = Btn(sec.body, "Prune", 52, 20, "danger")
    pruneBtn:SetPoint("LEFT", daysLabel2, "RIGHT", 6, 0)
    pruneBtn:SetScript("OnClick", function()
        local days = tonumber(daysEB:GetText()) or 30
        if days < 1 then days = 1 end
        local n = cttLoot_History and cttLoot_History:PruneOlderThan(days) or 0
        cttLoot:Print(string.format("Pruned %d history entries older than %d days.", n, days))
        RefreshCount()
        if activeTab == "history" then cttLoot_UI:RefreshHistoryTab() end
    end)

    -- Clear all button
    local clearAllBtn = Btn(sec.body, "Clear All", 68, 20, "danger")
    clearAllBtn:SetPoint("TOPLEFT", pruneLabel, "BOTTOMLEFT", 0, -PAD)
    clearAllBtn:SetScript("OnClick", function()
        if cttLoot_History then cttLoot_History:ClearAll() end
        cttLoot:Print("Loot history cleared.")
        RefreshCount()
        if activeTab == "history" then cttLoot_UI:RefreshHistoryTab() end
    end)

    -- Refresh count whenever the section is opened
    sec.hdr:HookScript("OnClick", function()
        if sec.open then RefreshCount() end
    end)

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

    local filtersVisible = true

    -- Collapse toggle (leftmost, fixed width)
    local toggleBtn = Btn(bar, "<<", 26, 20)
    toggleBtn:SetPoint("LEFT", bar, "LEFT", 4, 0)

    -- Stats label (anchored RIGHT, fixed)
    statsLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsLabel:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    statsLabel:SetTextColor(RGB(C.text_dim))
    cttLoot_UI.statsLabel = statsLabel

    -- Boss dropdown button — anchored once; Relayout only calls SetWidth
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

    -- Item dropdown button — anchored once; Relayout only calls SetWidth
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

    -- Player dropdown button — anchored once; Relayout only calls SetWidth
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

    -- Reserve a fixed pixel budget for the stats label so button widths
    -- never shift when the label text changes (e.g. boss name appears).
    local STATS_RESERVE = 160
    -- Anchors set once here; Relayout only calls SetWidth (no ClearAllPoints/SetPoint).
    -- This makes OnSizeChanged safe to fire every pixel with no anchor-graph churn.
    bossBtn:SetPoint("LEFT", toggleBtn, "RIGHT", GAP, 0)
    itemBtn:SetPoint("LEFT", bossClearBtn, "RIGHT", GAP, 0)
    playerBtn:SetPoint("LEFT", itemClearBtn, "RIGHT", GAP, 0)

    local _lastBossW, _lastItemW, _lastPlayerW = 0, 0, 0
    local function Relayout()
        local barW = bar:GetWidth()
        if barW < 50 then return end
        local fixed  = TOGGLE_W + (CLEAR_W + GAP) * 3 + (CLEAR_W + GAP) + STATS_RESERVE
        local avail  = math.max(barW - fixed, 120)
        local bossW   = math.floor(avail * 0.30)
        local itemW   = math.floor(avail * 0.40)
        local playerW = avail - bossW - itemW
        -- Only call SetWidth when the value actually changed — avoids even that cost per pixel
        if bossW   ~= _lastBossW   then bossBtn:SetWidth(bossW);     _lastBossW   = bossW   end
        if itemW   ~= _lastItemW   then itemBtn:SetWidth(itemW);     _lastItemW   = itemW   end
        if playerW ~= _lastPlayerW then playerBtn:SetWidth(playerW); _lastPlayerW = playerW end
        if not bossDdFrame:IsShown()   then bossDdFrame:SetWidth(math.max(bossW, 160))     end
        if not itemDdFrame:IsShown()   then itemDdFrame:SetWidth(math.max(itemW, 200))     end
        if not playerDdFrame:IsShown() then playerDdFrame:SetWidth(math.max(playerW, 140)) end
    end
    bar:SetScript("OnSizeChanged", Relayout)
    bar.Relayout = Relayout
    C_Timer.After(0, Relayout)

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
    bar.IsFiltersVisible = function() return filtersVisible end

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
local function BuildCardArea(parent, topAnchor, bottomAnchor)
    cardScrollF = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    cardScrollF:SetPoint("TOPLEFT",  topAnchor, "BOTTOMLEFT",  0, -PAD)
    if bottomAnchor then
        cardScrollF:SetPoint("BOTTOMRIGHT", bottomAnchor, "TOPRIGHT", -22, PAD)
    else
        cardScrollF:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -22, PAD + 14)
    end

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

-- ── Card pool: init / acquire / release / configure ──────────────────────────
-- All pool functions must be declared BEFORE MakeCard which calls them.

local function InitCardPool()
    if cardGraveyard then return end
    cardGraveyard = CreateFrame("Frame", nil, UIParent)
    cardGraveyard:Hide()
    cardGraveyard:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -9999, 9999)
    cardGraveyard:SetSize(1, 1)
end

-- Move a pooled card out of the scene into the graveyard.
-- Re-parenting removes it from cardContent's child list so WoW stops
-- processing it in layout passes — the key fix for progressive slowdown.
local function ReleaseCard(card)
    card:SetParent(cardGraveyard)
    card:ClearAllPoints()
    card:Hide()
    cardRecyclePool[#cardRecyclePool + 1] = card
end

-- Per-player best item lookup (populated before each grid render)
local playerBestItem = {}

-- Build one card with every possible element pre-created and hidden.
-- MAX_CARD_ROWS row slots let any overview item be displayed without
-- allocating new frames.  Parented to cardGraveyard until acquired.

local function CreatePooledCard()
    local card = CreateFrame("Frame", nil, cardGraveyard)
    card:SetSize(CARD_W, 80)
    Bg(card, C.card_bg)
    PixelBorder(card, C.border)

    local hdr = CreateFrame("Button", nil, card)
    hdr:SetHeight(20)
    hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
    local hdrBg = Bg(hdr, C.card_hdr)

    local titleFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -4)
    titleFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -4)
    titleFS:SetHeight(12); titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(false); titleFS:SetNonSpaceWrap(false)

    local bossFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossFS:SetHeight(12); bossFS:SetJustifyH("LEFT")
    bossFS:SetWordWrap(false); bossFS:SetNonSpaceWrap(false)
    bossFS:SetTextColor(RGB(C.accent)); bossFS:Hide()

    local winnerFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    winnerFS:SetHeight(12); winnerFS:SetWordWrap(false); winnerFS:SetNonSpaceWrap(false)
    winnerFS:SetTextColor(0.2, 1, 0.2, 1); winnerFS:Hide()

    local dimTex = card:CreateTexture(nil, "OVERLAY")
    dimTex:SetAllPoints(card); dimTex:SetColorTexture(0, 0, 0, 0.5); dimTex:Hide()

    local rows = {}
    for i = 1, MAX_CARD_ROWS do
        local ar, ag, ab = RGB(C.accent)
        local bestBg  = FlatTex(card, "BACKGROUND", ar, ag, ab, 0.15); bestBg:Hide()
        local rowBg   = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.03);    rowBg:Hide()
        local rankFS  = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rankFS:SetSize(COL_RANK, ROW_H)
        rankFS:SetJustifyH("CENTER"); rankFS:SetJustifyV("MIDDLE"); rankFS:Hide()
        local nameFS  = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFS:SetSize(COL_NAME, ROW_H)
        nameFS:SetJustifyH("LEFT"); nameFS:SetJustifyV("MIDDLE"); nameFS:Hide()
        local barBg   = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.06); barBg:Hide()
        local barFill = FlatTex(card, "ARTWORK",     1, 1, 1, 0.85); barFill:Hide()
        local dpsFS   = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dpsFS:SetSize(COL_DPS, ROW_H)
        dpsFS:SetJustifyH("RIGHT"); dpsFS:SetJustifyV("MIDDLE"); dpsFS:Hide()
        local sep = FlatTex(card, "BACKGROUND", RGB(C.border))
        sep:SetHeight(1); sep:Hide()
        rows[i] = { bestBg=bestBg, rowBg=rowBg, rankFS=rankFS, nameFS=nameFS,
                    barBg=barBg, barFill=barFill, dpsFS=dpsFS, sep=sep }
    end

    -- Scripts are set once here and reference card._itemName so no re-wiring
    -- is needed on reconfigure — only card._itemName is updated each time.
    hdr:SetScript("OnEnter", function() hdrBg:SetVertexColor(RGB(C.accent2)) end)
    hdr:SetScript("OnLeave", function() hdrBg:SetVertexColor(RGB(C.card_hdr)) end)
    hdr:SetScript("OnClick", function()
        CloseDropdowns()
        if cttLoot_UI.selectedItem == card._itemName then
            cttLoot_UI:SetSelectedItem(nil)
        else
            cttLoot_UI:SetSelectedItem(card._itemName)
        end
        cttLoot_UI:Refresh()
    end)

    card._p = { hdr=hdr, hdrBg=hdrBg, titleFS=titleFS, bossFS=bossFS,
                winnerFS=winnerFS, dimTex=dimTex, rows=rows }
    return card
end

local function AcquireCard()
    if #cardRecyclePool > 0 then
        local c = cardRecyclePool[#cardRecyclePool]
        cardRecyclePool[#cardRecyclePool] = nil
        return c
    end
    return CreatePooledCard()
end

-- Reconfigure a pooled card in-place for a new item.
-- Updates position, size, header, and all row slots without creating any frames.
local function ConfigureCard(card, itemName, entries, maxAbs, ox, oy, cardW, hdrH, cardH, info, winner)
    local p = card._p
    card._itemName = itemName
    card._cardH    = cardH

    card:SetParent(cardContent)
    card:SetSize(cardW, cardH)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", cardContent, "TOPLEFT", ox, -oy)
    card:Show()

    p.hdr:SetHeight(hdrH)
    p.titleFS:SetTextColor(RGB(C.text_hi))
    p.titleFS:SetText(itemName)

    if info and info.boss then
        p.bossFS:ClearAllPoints()
        p.bossFS:SetPoint("TOPLEFT",  p.hdr, "TOPLEFT",  6, -17)
        p.bossFS:SetPoint("TOPRIGHT", p.hdr, "TOPRIGHT", -4, -17)
        p.bossFS:SetText(info.boss); p.bossFS:Show()
    else
        p.bossFS:Hide()
    end

    if winner then
        p.winnerFS:ClearAllPoints()
        if info and info.boss then
            p.winnerFS:SetPoint("TOPLEFT",  p.hdr, "TOPLEFT",  6, -29)
            p.winnerFS:SetPoint("TOPRIGHT", p.hdr, "TOPRIGHT", -4, -29)
            p.winnerFS:SetJustifyH("LEFT")
        else
            p.winnerFS:SetPoint("TOPLEFT",  p.hdr, "TOPLEFT",  6, -4)
            p.winnerFS:SetPoint("TOPRIGHT", p.hdr, "TOPRIGHT", -4, -4)
            p.winnerFS:SetJustifyH("RIGHT")
        end
        p.winnerFS:SetText(">> " .. winner); p.winnerFS:Show()
        if not cttLoot_UI.selectedItem then p.dimTex:Show() else p.dimTex:Hide() end
    else
        p.winnerFS:Hide(); p.dimTex:Hide()
    end

    local dynBarW = cardW - COL_RANK - COL_NAME - COL_DPS - 10
    for i = 1, MAX_CARD_ROWS do
        local slot = p.rows[i]
        local e    = entries[i]
        if e then
            local ry      = hdrH + (i - 1) * ROW_H
            local isBest  = not e.isCat and (playerBestItem[e.player] == itemName)
            local wasAwarded = awardedSet[e.player]

            if isBest then
                slot.bestBg:SetSize(cardW, ROW_H)
                slot.bestBg:ClearAllPoints()
                slot.bestBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
                slot.bestBg:Show(); slot.rowBg:Hide()
            elseif i % 2 == 0 then
                slot.rowBg:SetSize(cardW, ROW_H)
                slot.rowBg:ClearAllPoints()
                slot.rowBg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -ry)
                slot.rowBg:Show(); slot.bestBg:Hide()
            else
                slot.bestBg:Hide(); slot.rowBg:Hide()
            end

            slot.rankFS:ClearAllPoints()
            slot.rankFS:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -ry)
            if     i == 1 then slot.rankFS:SetTextColor(RGB(C.rank_gold))
            elseif i == 2 then slot.rankFS:SetTextColor(RGB(C.rank_silver))
            elseif i == 3 then slot.rankFS:SetTextColor(RGB(C.rank_bronze))
            else               slot.rankFS:SetTextColor(RGB(C.text_dim)) end
            slot.rankFS:SetText(tostring(i)); slot.rankFS:Show()

            slot.nameFS:ClearAllPoints()
            slot.nameFS:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + 2, -ry)
            local cc = GetClassColor(e.player)
            if e.isCat then
                slot.nameFS:SetText(Clr(C.catalyst, "*") .. " " .. e.player)
            else
                slot.nameFS:SetText(e.player)
            end
            if cc then
                if wasAwarded then slot.nameFS:SetTextColor(cc[1]*0.5, cc[2]*0.5, cc[3]*0.5)
                else               slot.nameFS:SetTextColor(cc[1], cc[2], cc[3]) end
            else
                if wasAwarded then slot.nameFS:SetTextColor(RGB(C.text_dim))
                else               slot.nameFS:SetTextColor(RGB(C.text)) end
            end
            slot.nameFS:Show()

            slot.barBg:SetSize(dynBarW, BAR_H)
            slot.barBg:ClearAllPoints()
            slot.barBg:SetPoint("TOPLEFT", card, "TOPLEFT",
                COL_RANK + COL_NAME + 2, -ry - (ROW_H - BAR_H) / 2)
            slot.barBg:Show()

            local barPct  = math.max(0.01, math.abs(e.dps) / maxAbs)
            local fillW   = math.max(2, math.floor(barPct * dynBarW))
            slot.barFill:SetSize(fillW, BAR_H)
            slot.barFill:ClearAllPoints()
            slot.barFill:SetPoint("TOPLEFT", slot.barBg, "TOPLEFT", 0, 0)
            if e.isCat then
                if wasAwarded then slot.barFill:SetVertexColor(0.273, 0.153, 0.369)   -- muted purple
                else               slot.barFill:SetVertexColor(RGB(C.catalyst)) end
            elseif e.dps >= 0 then
                if wasAwarded then slot.barFill:SetVertexColor(0.169, 0.330, 0.169)   -- muted green
                else               slot.barFill:SetVertexColor(RGB(C.green)) end
            else
                if wasAwarded then slot.barFill:SetVertexColor(0.375, 0.128, 0.128)   -- muted red
                else               slot.barFill:SetVertexColor(RGB(C.red)) end
            end
            slot.barFill:Show()

            slot.dpsFS:ClearAllPoints()
            slot.dpsFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -ry)
            local sign = e.dps >= 0 and "+" or ""
            slot.dpsFS:SetText(string.format("%s%.0f", sign, e.dps))
            if e.isCat then
                if wasAwarded then slot.dpsFS:SetTextColor(0.273, 0.153, 0.369)
                else               slot.dpsFS:SetTextColor(RGB(C.catalyst)) end
            elseif e.dps >= 0 then
                if wasAwarded then slot.dpsFS:SetTextColor(0.169, 0.330, 0.169)
                else               slot.dpsFS:SetTextColor(RGB(C.green)) end
            else
                if wasAwarded then slot.dpsFS:SetTextColor(0.375, 0.128, 0.128)
                else               slot.dpsFS:SetTextColor(RGB(C.red)) end
            end
            slot.dpsFS:Show()

            if i < #entries then
                slot.sep:ClearAllPoints()
                slot.sep:SetPoint("BOTTOMLEFT",  card, "TOPLEFT",  0, -(ry + ROW_H - 1))
                slot.sep:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", 0, -(ry + ROW_H - 1))
                slot.sep:Show()
            else
                slot.sep:Hide()
            end
        else
            slot.bestBg:Hide(); slot.rowBg:Hide()
            slot.rankFS:Hide(); slot.nameFS:Hide()
            slot.barBg:Hide();  slot.barFill:Hide()
            slot.dpsFS:Hide();  slot.sep:Hide()
        end
    end
end

-- Build or reconfigure a card for `itemName` at (ox, oy) in cardContent.
-- Overview (limit > 0): acquires a pooled card and configures it in-place —
--   zero frame allocations after the pool is warm.
-- Detail view (limit == 0): builds a fresh card with unlimited rows — this
--   path is only reached once per item selection (never on resize).
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

    local info    = cttLoot:GetItemInfo(itemName)
    local hasBoss = info and info.boss
    local winner  = cttLoot:GetWinnerForItem(itemName)
    local hdrH = 20
    if hasBoss        then hdrH = 32 end
    if hasBoss and winner then hdrH = 44 end
    local cardH = hdrH + #entries * ROW_H + 2

    -- ── Overview: zero-allocation pooled card ─────────────────────────────────
    if limit and limit > 0 then
        local card = AcquireCard()
        ConfigureCard(card, itemName, entries, maxAbs, ox, oy, cardW, hdrH, cardH, info, winner)
        return card, cardH
    end

    -- ── Detail view (unlimited rows): build fresh ─────────────────────────────
    -- Only one card exists in detail view and it is rebuilt only on item-selection
    -- changes (user clicks), never during resize.  Fresh cards are parked in
    -- cardGraveyard on ClearCards — removed from cardContent's child list.
    local card = CreateFrame("Frame", nil, cardContent)
    card:SetSize(cardW, cardH)
    card:SetPoint("TOPLEFT", cardContent, "TOPLEFT", ox, -oy)

    Bg(card, C.card_bg)
    PixelBorder(card, C.border)

    local hdr = CreateFrame("Button", nil, card)
    hdr:SetHeight(hdrH)
    hdr:SetPoint("TOPLEFT"); hdr:SetPoint("TOPRIGHT")
    local hdrBg = Bg(hdr, C.card_hdr)

    local titleFS = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT",  hdr, "TOPLEFT",  6, -4)
    titleFS:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -4, -4)
    titleFS:SetHeight(12)
    titleFS:SetTextColor(RGB(C.text_hi))
    titleFS:SetText(itemName)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(false)
    titleFS:SetNonSpaceWrap(false)

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
        -- Detail view: selectedItem is always set here so never dim
    end

    hdr:SetScript("OnEnter", function() hdrBg:SetVertexColor(RGB(C.accent2)) end)
    hdr:SetScript("OnLeave", function() hdrBg:SetVertexColor(RGB(C.card_hdr)) end)
    hdr:SetScript("OnClick", function()
        CloseDropdowns()
        if cttLoot_UI.selectedItem == itemName then
            cttLoot_UI:SetSelectedItem(nil)
        else
            cttLoot_UI:SetSelectedItem(itemName)
        end
        cttLoot_UI:Refresh()
    end)

    for i, e in ipairs(entries) do
        local ry = hdrH + (i-1) * ROW_H

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

        local rankFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rankFS:SetSize(COL_RANK, ROW_H)
        rankFS:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -ry)
        rankFS:SetJustifyH("CENTER"); rankFS:SetJustifyV("MIDDLE")
        if     i == 1 then rankFS:SetTextColor(RGB(C.rank_gold))
        elseif i == 2 then rankFS:SetTextColor(RGB(C.rank_silver))
        elseif i == 3 then rankFS:SetTextColor(RGB(C.rank_bronze))
        else               rankFS:SetTextColor(RGB(C.text_dim)) end
        rankFS:SetText(tostring(i))

        local nameFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameFS:SetSize(COL_NAME, ROW_H)
        nameFS:SetPoint("TOPLEFT", card, "TOPLEFT", COL_RANK + 2, -ry)
        nameFS:SetJustifyH("LEFT"); nameFS:SetJustifyV("MIDDLE")
        local classColor = GetClassColor(e.player)
        local wasAwarded = awardedSet[e.player]
        if e.isCat then
            nameFS:SetText(Clr(C.catalyst, "*") .. " " .. e.player)
            if classColor then
                if wasAwarded then nameFS:SetTextColor(classColor[1]*0.5, classColor[2]*0.5, classColor[3]*0.5)
                else               nameFS:SetTextColor(classColor[1], classColor[2], classColor[3]) end
            else
                if wasAwarded then nameFS:SetTextColor(RGB(C.text_dim))
                else               nameFS:SetTextColor(RGB(C.text)) end
            end
        else
            if classColor then
                if wasAwarded then nameFS:SetTextColor(classColor[1]*0.5, classColor[2]*0.5, classColor[3]*0.5)
                else               nameFS:SetTextColor(classColor[1], classColor[2], classColor[3]) end
            else
                if wasAwarded then nameFS:SetTextColor(RGB(C.text_dim))
                else               nameFS:SetTextColor(RGB(C.text)) end
            end
            nameFS:SetText(e.player)
        end

        local dynBarW = cardW - COL_RANK - COL_NAME - COL_DPS - 10
        local barBg = FlatTex(card, "BACKGROUND", 1, 1, 1, 0.06)
        barBg:SetSize(dynBarW, BAR_H)
        barBg:SetPoint("TOPLEFT", card, "TOPLEFT",
            COL_RANK + COL_NAME + 2, -ry - (ROW_H - BAR_H) / 2)

        local barPct = math.max(0.01, math.abs(e.dps) / maxAbs)
        local fillW  = math.max(2, math.floor(barPct * dynBarW))
        local barFill = FlatTex(card, "ARTWORK", 1, 1, 1, 0.85)
        barFill:SetSize(fillW, BAR_H)
        barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 0, 0)
        local wasAwarded = awardedSet[e.player]
        if e.isCat then
            if wasAwarded then barFill:SetVertexColor(0.273, 0.153, 0.369)
            else               barFill:SetVertexColor(RGB(C.catalyst)) end
        elseif e.dps >= 0 then
            if wasAwarded then barFill:SetVertexColor(0.169, 0.330, 0.169)
            else               barFill:SetVertexColor(RGB(C.green)) end
        else
            if wasAwarded then barFill:SetVertexColor(0.375, 0.128, 0.128)
            else               barFill:SetVertexColor(RGB(C.red)) end
        end

        local dpsFS = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dpsFS:SetSize(COL_DPS, ROW_H)
        dpsFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -ry)
        dpsFS:SetJustifyH("RIGHT"); dpsFS:SetJustifyV("MIDDLE")
        local sign = e.dps >= 0 and "+" or ""
        dpsFS:SetText(string.format("%s%.0f", sign, e.dps))
        if e.isCat then
            if wasAwarded then dpsFS:SetTextColor(0.273, 0.153, 0.369)
            else               dpsFS:SetTextColor(RGB(C.catalyst)) end
        elseif e.dps >= 0 then
            if wasAwarded then dpsFS:SetTextColor(0.169, 0.330, 0.169)
            else               dpsFS:SetTextColor(RGB(C.green)) end
        else
            if wasAwarded then dpsFS:SetTextColor(0.375, 0.128, 0.128)
            else               dpsFS:SetTextColor(RGB(C.red)) end
        end

        if i < #entries then
            local sep = FlatTex(card, "BACKGROUND", RGB(C.border))
            sep:SetHeight(1)
            sep:SetPoint("BOTTOMLEFT",  card, "TOPLEFT",  0, -(ry + ROW_H - 1))
            sep:SetPoint("BOTTOMRIGHT", card, "TOPRIGHT", 0, -(ry + ROW_H - 1))
        end
    end

    card._cardH = cardH
    return card, cardH
end
-- Release all current cards.  Pooled cards return to cardRecyclePool;
-- fresh detail-view cards are parked in cardGraveyard (not reused, but
-- removed from cardContent's child list so WoW stops processing them).
local function ClearCards()
    if not cardContent then return end
    for _, c in ipairs(cardPool) do
        if c._p then
            ReleaseCard(c)          -- pooled: return for reuse
        else
            c:SetParent(cardGraveyard)  -- fresh detail card: park, don't reuse
            c:ClearAllPoints()
            c:Hide()
        end
    end
    cardPool    = {}
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
    cardContent._lastCols = cols   -- used by ReflowCards to detect column count change

    -- Update stats badge
    if statsLabel then
        local bossStr = cttLoot_UI.selectedBoss
            and (Clr(C.accent, "·") .. " " .. cttLoot_UI.selectedBoss .. "  ") or ""
        statsLabel:SetText(string.format("%s%d items  " .. Clr(C.accent, "·") .. "  %d players",
            bossStr, #pool, #cttLoot.playerNames))
        if filterBar then filterBar.Relayout() end
    end
end

-- Reposition existing visible cards to fit a new grid width.
-- Called after window resize — does NOT create or destroy any frames.
-- Card content (player rows, deltas) is unchanged; only position/width changes
-- when cols change. If cols actually changed we fall back to full Refresh.
local function ReflowCards()
    if not cardScrollF or not cardContent then return end
    if #cardPool == 0 then return end  -- no cards yet; nothing to reflow

    local gridW = cardScrollF:GetWidth() - 4
    if gridW < 10 then return end  -- scroll frame not yet settled; bail

    -- Detail view: cardW = gridW - PAD*2, so all internal bar sizes (barBg,
    -- barFill, dpsFS) must recalculate from the new cardW.  Only one card
    -- exists here so a full Refresh is cheap.
    if cttLoot_UI.selectedItem then
        cttLoot_UI:Refresh()
        return
    end

    local cardW = CARD_W
    local cols  = math.max(1, math.floor((gridW + CARD_GAP) / (CARD_W + CARD_GAP)))

    -- If column count changed the layout is structurally different — need full rebuild.
    -- This is rare (only when window width crosses a column boundary).
    local prevCols = cardContent._lastCols or cols
    if cols ~= prevCols then
        cttLoot_UI:Refresh()
        return
    end

    -- Same column count: just reposition each card to its new (ox, oy).
    local col, totalH, rowMaxH = 0, PAD, 0
    local rowStart = 1
    for idx, card in ipairs(cardPool) do
        local cardH = card._cardH or 80
        local ox    = PAD + col * (cardW + CARD_GAP)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", cardContent, "TOPLEFT", ox, -totalH)
        card:SetWidth(cardW)
        if cardH > rowMaxH then rowMaxH = cardH end
        col = col + 1
        if col >= cols then
            col      = 0
            totalH   = totalH + rowMaxH + CARD_GAP
            rowMaxH  = 0
        end
    end
    if col > 0 then totalH = totalH + rowMaxH + CARD_GAP end

    cardContent:SetWidth(gridW)
    cardContent:SetHeight(math.max(totalH, 80))
    cardContent._lastCols = cols
end

-- ── Shared: build search box + scrollable list inside a dd frame ─────────────
-- Returns: searchEB, listFrame, listContent
-- The caller populates listContent and sets its height.
local DD_MAX_LIST = 220  -- max height of the scrollable list area

BuildDdSearchAndList = function(ddFrame, ddW)
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
    local SBAR_W = 4   -- thin scrollbar

    local listSF = CreateFrame("ScrollFrame", nil, ddFrame)
    listSF:SetPoint("TOPLEFT",  ddFrame, "TOPLEFT",  0, -(DD_SEARCH_H + 4))
    listSF:SetPoint("TOPRIGHT", ddFrame, "TOPRIGHT",  0, -(DD_SEARCH_H + 4))

    local listContent = CreateFrame("Frame", nil, listSF)
    listContent:SetWidth(ddW - SBAR_W - 2)
    listContent:SetHeight(1)
    listSF:SetScrollChild(listContent)

    -- Thin scrollbar track (right edge, inside) — declared before OnMouseWheel so thumb is in scope
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
-- Reuses existing child buttons rather than creating new ones every call,
-- preventing unbounded frame accumulation across repeated dropdown opens.
FillDdList = function(listContent, listW, rows, query)
    -- Collect existing reusable buttons (hide them all first)
    local recycled = {}
    for _, child in ipairs({ listContent:GetChildren() }) do
        child:Hide()
        table.insert(recycled, child)
    end
    for _, region in ipairs({ listContent:GetRegions() }) do
        region:Hide()
    end

    local q      = query and query:lower() or ""
    local y      = 0
    local any    = false
    local maxW   = listW
    local active = {}   -- buttons shown this pass

    -- First pass: measure max width needed.
    -- Reuse a single measurer FontString stored on the frame — created once,
    -- never accumulates across repeated dropdown opens or keystrokes.
    if not listContent._measurer then
        listContent._measurer = listContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        listContent._measurer:Hide()
    end
    local measurer = listContent._measurer
    for _, row in ipairs(rows) do
        if q == "" or row.label:lower():find(q, 1, true) then
            measurer:SetText(row.label)
            local tw = measurer:GetStringWidth() + 24
            if tw > maxW then maxW = tw end
        end
    end
    measurer:SetText("")

    -- Second pass: reuse or create buttons
    local recycleIdx = 1
    for _, row in ipairs(rows) do
        local label = row.label
        if q == "" or label:lower():find(q, 1, true) then
            local btn = recycled[recycleIdx]
            if btn then
                recycleIdx = recycleIdx + 1
                -- Reconfigure existing button
                btn._label:SetText(label)
                btn:SetWidth(maxW)
                btn:SetHeight(DD_ROW_H)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
                if row.selected then
                    btn._bg:SetVertexColor(RGB(C.accent2))
                else
                    btn._bg:SetVertexColor(RGB(C.bg3))
                end
                btn:SetScript("OnClick", row.onSelect)
                btn:Show()
            else
                -- Create new button only when pool exhausted
                btn = Btn(listContent, label, maxW, DD_ROW_H)
                btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -y)
                if row.selected then btn._bg:SetVertexColor(RGB(C.accent2)) end
                btn:SetScript("OnClick", row.onSelect)
            end
            table.insert(active, btn)
            y   = y + DD_ROW_H + 1
            any = true
        end
    end

    if not any then
        -- Show "no match" text in a recycled button or new fontstring
        local btn = recycled[recycleIdx]
        if btn then
            btn._label:SetText(q ~= "" and "No match" or "—")
            btn._label:SetTextColor(RGB(C.text_dim))
            btn:SetWidth(maxW); btn:SetHeight(DD_ROW_H)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 8, -6)
            btn._bg:SetVertexColor(RGB(C.bg3))
            btn:SetScript("OnClick", function() end)
            btn:Show()
        else
            local empty = listContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            empty:SetPoint("TOPLEFT", listContent, "TOPLEFT", 8, -6)
            empty:SetTextColor(RGB(C.text_dim))
            empty:SetText(q ~= "" and "No match" or "—")
        end
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
    -- "All Bosses" always first
    table.insert(bossDdAllRows, {
        label    = "All Bosses",
        selected = (self.selectedBoss == nil),
        onSelect = function() self:SetBossFilter(nil); CloseDropdowns() end,
    })
    local allBosses = cttLoot:GetAllBosses()
    if #allBosses == 0 then
        table.insert(bossDdAllRows, {
            label    = "Database empty — import items first",
            selected = false,
            onSelect = function() end,
        })
    else
        for _, bossName in ipairs(allBosses) do
            local bName = bossName
            table.insert(bossDdAllRows, {
                label    = bossName,
                selected = (self.selectedBoss == bossName),
                onSelect = function() self:SetBossFilter(bName); CloseDropdowns() end,
            })
        end
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
    -- "All Items" always first
    table.insert(itemDdAllRows, {
        label    = "All Items",
        selected = (self.selectedItem == nil),
        onSelect = function()
            self.selectedItem = nil
            if itemDdLabel  then itemDdLabel:SetText("Item") end
            if itemClearBtn then itemClearBtn:Hide() end
            CloseDropdowns(); self:Refresh()
        end,
    })
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
                    if itemClearBtn and (not filterBar or filterBar.IsFiltersVisible()) then itemClearBtn:Show() end
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
                if filterBar and filterBar.IsFiltersVisible() then playerClearBtn:Show() end
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
        if bossName and filterBar and filterBar.IsFiltersVisible() then bossClearBtn:Show() else bossClearBtn:Hide() end
    end
    if itemClearBtn then itemClearBtn:Hide() end
    self:Refresh()
end

function cttLoot_UI:SetLootFilter(names)
    self.lootFilter = names
    -- Updating the loot filter implicitly clears the selected item
    self.selectedItem = nil
    if itemDdLabel  then itemDdLabel:SetText("Item") end
    if itemClearBtn then itemClearBtn:Hide() end
end

-- Set (or clear) the zoomed item view.  Pass nil to return to the grid.
-- Handles all label/button sync so callers never touch those locals.
function cttLoot_UI:SetSelectedItem(name)
    self.selectedItem = name
    if name then
        if itemDdLabel  then itemDdLabel:SetText(name) end
        if itemClearBtn and filterBar and filterBar.IsFiltersVisible() then itemClearBtn:Show() end
    else
        if itemDdLabel  then itemDdLabel:SetText("Item") end
        if itemClearBtn then itemClearBtn:Hide() end
    end
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
    RebuildIfDirty()
    if activeTab == "history" then
        self:RefreshHistoryTab()
    else
        PopulateGrid()
    end
end

-- Reposition cards after a window resize without rebuilding them.
function cttLoot_UI:ReflowCards()
    if not window then return end
    if activeTab == "history" then
        -- History tab: just update content width, no card reposition needed
        if historyScrollF and historyContent then
            historyContent:SetWidth(historyScrollF:GetWidth() - 4)
        end
    else
        ReflowCards()
    end
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
end

function cttLoot_UI:Build()
    InitCardPool()   -- idempotent; creates cardGraveyard if not already done

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
        if syncCogColor then syncCogColor() end
    end)

    -- Settings button — white when closed, green when open
    local cogBtn = Btn(window, "Settings", 60, 18)
    cogBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    cogBtn._label:SetTextColor(RGB(C.text_hi))  -- starts white (drawer closed)
    local function SetCogColor()
        if drawerOpen then
            cogBtn._label:SetTextColor(RGB(C.green))
        else
            cogBtn._label:SetTextColor(RGB(C.text_hi))
        end
    end
    syncCogColor = SetCogColor  -- expose to drawer X and window close
    cogBtn:SetScript("OnClick", function()
        drawerOpen = not drawerOpen
        if drawerOpen then drawer:Show() else drawer:Hide() end
        SetCogColor()
    end)
    cogBtn:SetScript("OnEnter", function()
        cogBtn._bg:SetVertexColor(RGB(C.accent2))
        SetCogColor()
    end)
    cogBtn:SetScript("OnLeave", function()
        cogBtn._bg:SetVertexColor(RGB(C.bg3))
        SetCogColor()
    end)
    cogBtn:SetScript("OnMouseDown", function()
        cogBtn._bg:SetVertexColor(RGB(C.accent))
        SetCogColor()
    end)
    cogBtn:SetScript("OnMouseUp", function()
        cogBtn._bg:SetVertexColor(RGB(C.bg3))
        SetCogColor()
    end)

    -- Check button — white normally, green for 3s while check is live
    local checkBtn = Btn(window, "Check", 50, 18)
    checkBtn:SetPoint("RIGHT", cogBtn, "LEFT", -2, 0)
    checkBtn._label:SetTextColor(RGB(C.text_hi))
    local checkActive = false
    local checkPulseTimer = nil
    local function SetCheckColor()
        if checkActive then
            checkBtn._label:SetTextColor(RGB(C.green))
        else
            checkBtn._label:SetTextColor(RGB(C.text_hi))
        end
    end
    checkBtn:SetScript("OnClick", function()
        if #cttLoot.itemNames == 0 then return end  -- RunCheck will print the error
        checkActive = true
        SetCheckColor()
        if checkPulseTimer then checkPulseTimer:Cancel() end
        checkPulseTimer = C_Timer.NewTimer(3, function()
            checkPulseTimer = nil
            checkActive = false
            SetCheckColor()
        end)
        cttLoot:RunCheck()
    end)
    checkBtn:SetScript("OnEnter", function()
        checkBtn._bg:SetVertexColor(RGB(C.accent2))
        SetCheckColor()
    end)
    checkBtn:SetScript("OnLeave", function()
        checkBtn._bg:SetVertexColor(RGB(C.bg3))
        SetCheckColor()
    end)
    checkBtn:SetScript("OnMouseDown", function()
        checkBtn._bg:SetVertexColor(RGB(C.accent))
        SetCheckColor()
    end)
    checkBtn:SetScript("OnMouseUp", function()
        checkBtn._bg:SetVertexColor(RGB(C.bg3))
        SetCheckColor()
    end)

    -- Sort button (left of Check) — on by default (delta), off = alphabetical
    sortFilterBtn = Btn(window, "Delta", 45, 18)
    sortFilterBtn:SetPoint("RIGHT", checkBtn, "LEFT", -2, 0)
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

    -- Resize grip — sits at bottom-right corner, on top of footer bar
    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(window:GetFrameLevel() + 20)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    -- Freeze/restore helpers: during resize the scroll frames must NOT be
    -- two-anchor elastic frames — that causes WoW to recalculate the entire
    -- descendant hierarchy every pixel, which is what causes the lag.
    grip:SetScript("OnMouseDown", function()
        window:SetMovable(true)
        window:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        -- Restore snap lock if RC integration is active
        if cttLoot_RC:IsEnabled() and cttLoot_RC:IsSessionActive() then
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

    -- After resize: reflow layout only — never rebuild cards from scratch.
    -- Cards are expensive to create (20+ sub-frames each). Rebuilding them on
    -- every resize causes unbounded frame accumulation in cardContent.
    -- Instead we just reposition existing cards to fit the new width.
    -- ── Resize debounce (OnUpdate, zero allocations) ──────────────────────────
    -- The old approach called C_Timer.NewTimer on every pixel of resize (~60/s).
    -- Each NewTimer allocates a Lua object and registers with WoW's timer list,
    -- which is iterated every frame.  After ~20 seconds of dragging the list
    -- accumulates ~1,200+ objects and causes the progressive frame-rate drop.
    --
    -- This OnUpdate frame costs nothing while hidden.  OnSizeChanged resets the
    -- elapsed counter and shows the frame; OnUpdate hides itself once the delay
    -- elapses and fires the reflow — zero timer objects ever created.
    local resizeElapsed = 0
    local RESIZE_DELAY  = 0.15
    local resizeDF = CreateFrame("Frame")
    resizeDF:Hide()
    resizeDF:SetScript("OnUpdate", function(_, dt)
        resizeElapsed = resizeElapsed + dt
        if resizeElapsed >= RESIZE_DELAY then
            resizeDF:Hide()
            resizeElapsed = 0
            if not cardScrollF or not cardContent then return end
            local csW = cardScrollF:GetWidth()
            if csW > 10 then cardContent:SetWidth(csW) end
            if historyScrollF and historyContent then
                local hsW = historyScrollF:GetWidth()
                if hsW > 10 then historyContent:SetWidth(hsW - 4) end
            end
            if filterBar        and filterBar.Relayout        then filterBar.Relayout()        end
            if historyFilterBar and historyFilterBar.Relayout then historyFilterBar.Relayout() end
            if cttLootDB then
                cttLootDB.windowW = math.floor(window:GetWidth())
                cttLootDB.windowH = math.floor(window:GetHeight())
            end
            cttLoot_UI:ReflowCards()
        end
    end)
    window:SetScript("OnSizeChanged", function()
        resizeElapsed = 0
        if not resizeDF:IsShown() then resizeDF:Show() end
    end)

    -- ── Drawer (right-side settings panel) ──
    drawer = BuildDrawer(window)

    -- ── Drawer sections ──
    local importSec = BuildImportSection(drawer)
    BuildDBSection()
    BuildOptionsSection()
    self:RepositionDrawer()

    -- ── Filter bar (anchored below title bar, as before) ──
    filterBar = BuildFilterBar(window, titleBar)

    -- ── Footer tab bar (pinned to window bottom, above resize grip) ──
    local FOOTER_H = 22
    local footerBar = CreateFrame("Frame", nil, window)
    footerBar:SetHeight(FOOTER_H)
    footerBar:SetPoint("BOTTOMLEFT",  window, "BOTTOMLEFT",  1, 1)
    footerBar:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -1, 1)
    Bg(footerBar, C.bg_title)

    -- Accent line on TOP of footer (separates content from footer)
    local footerAccent = FlatTex(window, "ARTWORK", RGB(C.accent))
    footerAccent:SetHeight(1)
    footerAccent:SetPoint("BOTTOMLEFT",  footerBar, "TOPLEFT",  0, 0)
    footerAccent:SetPoint("BOTTOMRIGHT", footerBar, "TOPRIGHT", 0, 0)

    -- Per-tab active underline (TOP edge of button = top of footer bar)
    local gridUnderline    = FlatTex(footerBar, "OVERLAY", RGB(C.accent))
    local historyUnderline = FlatTex(footerBar, "OVERLAY", RGB(C.accent))
    gridUnderline:SetHeight(2)
    historyUnderline:SetHeight(2)

    local function SetTabActive(btn, underline, active)
        if active then
            btn._bg:SetVertexColor(RGB(C.bg2))
            btn._label:SetTextColor(RGB(C.text_hi))
            underline:Show()
        else
            btn._bg:SetVertexColor(RGB(C.bg_title))
            btn._label:SetTextColor(RGB(C.text_dim))
            underline:Hide()
        end
        if not active then
            btn:SetScript("OnEnter",     function() btn._label:SetTextColor(RGB(C.text)) end)
            btn:SetScript("OnLeave",     function() btn._label:SetTextColor(RGB(C.text_dim)) end)
            btn:SetScript("OnMouseDown", function() end)
            btn:SetScript("OnMouseUp",   function() end)
        else
            btn:SetScript("OnEnter",     function() end)
            btn:SetScript("OnLeave",     function() end)
            btn:SetScript("OnMouseDown", function() end)
            btn:SetScript("OnMouseUp",   function() end)
        end
    end

    tabGridBtn    = Btn(footerBar, "Main",    56, FOOTER_H - 2)
    tabHistoryBtn = Btn(footerBar, "History", 64, FOOTER_H - 2)
    tabGridBtn:SetPoint("LEFT",    footerBar, "LEFT", 6, 0)
    tabHistoryBtn:SetPoint("LEFT", tabGridBtn, "RIGHT", 2, 0)

    -- Underlines sit on the TOP edge of each button (visible above content area)
    gridUnderline:SetPoint("TOPLEFT",  tabGridBtn,    "TOPLEFT",  0, 0)
    gridUnderline:SetPoint("TOPRIGHT", tabGridBtn,    "TOPRIGHT", 0, 0)
    historyUnderline:SetPoint("TOPLEFT",  tabHistoryBtn, "TOPLEFT",  0, 0)
    historyUnderline:SetPoint("TOPRIGHT", tabHistoryBtn, "TOPRIGHT", 0, 0)

    SetTabActive(tabGridBtn,    gridUnderline,    true)
    SetTabActive(tabHistoryBtn, historyUnderline, false)

    tabGridBtn:SetScript("OnClick", function()
        if activeTab == "grid" then return end
        activeTab = "grid"
        historySelectedItem = nil
        historyDetailEntry  = nil
        SetTabActive(tabGridBtn,    gridUnderline,    true)
        SetTabActive(tabHistoryBtn, historyUnderline, false)
        filterBar:Show()
        if cardScrollF      then cardScrollF:Show()      end
        if historyFilterBar then historyFilterBar:Hide() end
        if historyScrollF   then historyScrollF:Hide()   end
        cttLoot_UI:Refresh()
    end)
    tabHistoryBtn:SetScript("OnClick", function()
        if activeTab == "history" then return end
        activeTab = "history"
        SetTabActive(tabGridBtn,    gridUnderline,    false)
        SetTabActive(tabHistoryBtn, historyUnderline, true)
        filterBar:Hide()
        if cardScrollF    then cardScrollF:Hide()    end
        if historyFilterBar then historyFilterBar:Show() end
        if historyScrollF then historyScrollF:Show() end
        cttLoot_UI:RefreshHistoryTab()
    end)

    -- ── Card grid (fills space between filter bar and footer) ──
    BuildCardArea(window, filterBar, footerBar)

    -- ── History filter bar (hidden until history tab active) ──
    BuildHistoryFilterBar(window, titleBar)

    -- ── History area (anchored below history filter bar) ──
    BuildHistoryArea(window, titleBar, footerBar)

    window:Hide()
end

-- Init on login
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
initFrame:SetScript("OnEvent", function(_, event)
    if event == "GROUP_ROSTER_UPDATE" then
        classColorsDirty = true
        -- Refresh only if the window is open so we don't waste work
        if window and window:IsShown() then cttLoot_UI:Refresh() end
        return
    end
    -- PLAYER_LOGIN
    local ok, err = pcall(function() cttLoot_UI:Build() end)
    if not ok then
        cttLoot:Print("|cffff4444cttLoot UI build error: " .. tostring(err) .. "|r")
        if _G["cttLootFrame"] then _G["cttLootFrame"]:Hide() end
        return
    end
    -- Mark dirty on data change so Refresh rebuilds only when needed
    cttLoot.onDataApplied = function()
        BuildPlayerBestItems()
        awardsDirty = true
    end
    BuildPlayerBestItems()
    -- classColorsDirty and awardsDirty are already true from declaration;
    -- RebuildIfDirty() inside Refresh() below will handle the first build.
    cttLoot_UI:Refresh()
end)
