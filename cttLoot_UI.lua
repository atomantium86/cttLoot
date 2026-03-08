-- cttLoot_UI.lua  (ElvUI-style)
-- Flat dark frames, 1px pixel borders, ElvUI blue accent, tight spacing

cttLoot_UI = {}

-- ── Layout constants ──────────────────────────────────────────────────────────
local WIN_W      = 700
local WIN_H      = 560
local ROW_H      = 20
local TITLE_H    = 20
local SECTION_H  = 150
local FILTER_H   = 26
local HDR_H      = 18
local PAD        = 6
local COL_RANK   = 28
local COL_NAME   = 200
local COL_DPS    = 90
local COL_BAR    = 160

-- ── ElvUI-style colour palette ────────────────────────────────────────────────
local C = {
    bg          = {0.09, 0.09, 0.09},
    bg2         = {0.12, 0.12, 0.12},
    bg3         = {0.06, 0.06, 0.06},
    border      = {0.20, 0.20, 0.20},
    title_bg    = {0.13, 0.13, 0.13},
    hdr_bg      = {0.15, 0.15, 0.15},
    accent      = {0.24, 0.49, 0.75},
    accent2     = {0.18, 0.38, 0.60},
    text        = {0.90, 0.90, 0.90},
    text_dim    = {0.55, 0.55, 0.55},
    text_hi     = {1.00, 1.00, 1.00},
    green       = {0.33, 0.68, 0.33},
    red         = {0.78, 0.25, 0.25},
    rank_gold   = {0.85, 0.73, 0.25},
    rank_silver = {0.75, 0.75, 0.75},
    rank_bronze = {0.72, 0.45, 0.20},
}

local WHITE = "Interface\\Buttons\\WHITE8X8"

local window           = nil
local pasteBox         = nil
local filterBox        = nil
local tableFrame       = nil
local scrollFrame      = nil
local scrollContent    = nil
local rowFrames        = {}
local currentItem      = nil
local filterText       = ""
local pasteSection     = nil
local filterSection    = nil
local pasteSectionOpen = true

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function RGB(t) return t[1], t[2], t[3] end

local function FlatTex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetTexture(WHITE)
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

local function PixelBorder(frame, r, g, b, a)
    r, g, b = r or RGB(C.border)
    a = a or 1
    local function E(p1, p2, w, h)
        local t = frame:CreateTexture(nil, "OVERLAY")
        t:SetTexture(WHITE)
        t:SetVertexColor(r, g, b, a)
        if w then t:SetWidth(w) else t:SetHeight(h) end
        t:SetPoint(p1, frame, p1, p1:find("RIGHT") and 1 or -1, p1:find("TOP") and 1 or -1)
        t:SetPoint(p2, frame, p2, p2:find("RIGHT") and 1 or -1, p2:find("TOP") and 1 or -1)
    end
    -- top
    local top = frame:CreateTexture(nil,"OVERLAY") top:SetTexture(WHITE) top:SetVertexColor(r,g,b,a) top:SetHeight(1) top:SetPoint("TOPLEFT",frame,"TOPLEFT",-1,1) top:SetPoint("TOPRIGHT",frame,"TOPRIGHT",1,1)
    -- bottom
    local bot = frame:CreateTexture(nil,"OVERLAY") bot:SetTexture(WHITE) bot:SetVertexColor(r,g,b,a) bot:SetHeight(1) bot:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",-1,-1) bot:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",1,-1)
    -- left
    local lft = frame:CreateTexture(nil,"OVERLAY") lft:SetTexture(WHITE) lft:SetVertexColor(r,g,b,a) lft:SetWidth(1)  lft:SetPoint("TOPLEFT",frame,"TOPLEFT",-1,1)       lft:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",-1,-1)
    -- right
    local rgt = frame:CreateTexture(nil,"OVERLAY") rgt:SetTexture(WHITE) rgt:SetVertexColor(r,g,b,a) rgt:SetWidth(1)  rgt:SetPoint("TOPRIGHT",frame,"TOPRIGHT",1,1)      rgt:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",1,-1)
end

local function ElvButton(parent, label, w, h)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w or 80, h or 18)
    local bg = FlatTex(btn, "BACKGROUND", RGB(C.bg2))
    bg:SetAllPoints(btn)
    btn.bg = bg
    PixelBorder(btn, RGB(C.border))
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints(btn)
    fs:SetJustifyH("CENTER")
    fs:SetTextColor(RGB(C.text))
    fs:SetText(label or "")
    btn.label = fs
    btn:SetScript("OnEnter",    function() bg:SetVertexColor(RGB(C.accent2)) fs:SetTextColor(RGB(C.text_hi)) end)
    btn:SetScript("OnLeave",    function() bg:SetVertexColor(RGB(C.bg2))     fs:SetTextColor(RGB(C.text))    end)
    btn:SetScript("OnMouseDown",function() bg:SetVertexColor(RGB(C.accent))  fs:SetTextColor(RGB(C.text_hi)) end)
    btn:SetScript("OnMouseUp",  function() bg:SetVertexColor(RGB(C.bg2))     fs:SetTextColor(RGB(C.text))    end)
    return btn
end

local function ElvEditBox(parent, w, h)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetSize(w or 160, h or 18)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontNormalSmall")
    eb:SetTextColor(RGB(C.text))
    local bg = FlatTex(eb, "BACKGROUND", RGB(C.bg3))
    bg:SetAllPoints(eb)
    PixelBorder(eb, RGB(C.border))
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    return eb
end

-- ── Main window ───────────────────────────────────────────────────────────────
local function BuildWindow()
    local f = CreateFrame("Frame", "cttLootFrame", UIParent)
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(420, 300, 1400, 1000)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(100)

    local mainBg = FlatTex(f, "BACKGROUND", RGB(C.bg))
    mainBg:SetAllPoints(f)
    PixelBorder(f, RGB(C.border))

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(TITLE_H)
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",   1, -1)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT",  -1, -1)
    local titleBg = FlatTex(titleBar, "ARTWORK", RGB(C.title_bg))
    titleBg:SetAllPoints(titleBar)

    -- Blue accent line under title
    local accentLine = FlatTex(f, "ARTWORK", RGB(C.accent))
    accentLine:SetHeight(1)
    accentLine:SetPoint("TOPLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    accentLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)

    local titleTxt = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleTxt:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
    titleTxt:SetTextColor(RGB(C.text_hi))
    titleTxt:SetText("cttLoot  |cff3E7DC0·|r  Player DPS Delta Viewer")

    -- Close (red ElvUI style)
    local closeBtn = ElvButton(f, "X", 18, 16)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    closeBtn.bg:SetVertexColor(0.55, 0.18, 0.18)
    closeBtn:SetScript("OnEnter", function() closeBtn.bg:SetVertexColor(0.75, 0.22, 0.22) end)
    closeBtn:SetScript("OnLeave", function() closeBtn.bg:SetVertexColor(0.55, 0.18, 0.18) end)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(12, 12)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() cttLoot_UI:Refresh() end)

    return f
end

-- ── Paste section ─────────────────────────────────────────────────────────────
local function BuildPasteSection(parent)
    local sec = CreateFrame("Frame", nil, parent)
    sec:SetPoint("TOPLEFT",  parent, "TOPLEFT",  PAD, -(TITLE_H + PAD + 2))
    sec:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, -(TITLE_H + PAD + 2))
    sec:SetHeight(SECTION_H)

    local secBg = FlatTex(sec, "BACKGROUND", RGB(C.bg2))
    secBg:SetAllPoints(sec)
    PixelBorder(sec, RGB(C.border))

    -- Header / toggle bar
    local toggleBtn = CreateFrame("Button", nil, sec)
    toggleBtn:SetPoint("TOPLEFT")
    toggleBtn:SetPoint("TOPRIGHT")
    toggleBtn:SetHeight(18)
    local togBg = FlatTex(toggleBtn, "BACKGROUND", RGB(C.hdr_bg))
    togBg:SetAllPoints(toggleBtn)
    local togAccent = FlatTex(toggleBtn, "ARTWORK", RGB(C.accent))
    togAccent:SetWidth(2)
    togAccent:SetPoint("TOPLEFT")
    togAccent:SetPoint("BOTTOMLEFT")

    local togLabel = toggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    togLabel:SetPoint("LEFT", 8, 0)
    togLabel:SetTextColor(RGB(C.text_hi))
    togLabel:SetText("Paste TSV Data")

    local togHint = toggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    togHint:SetPoint("RIGHT", -6, 0)
    togHint:SetTextColor(RGB(C.text_dim))
    togHint:SetText("▼  collapse")

    -- Body
    local body = CreateFrame("Frame", nil, sec)
    body:SetPoint("TOPLEFT",     sec, "TOPLEFT",     0, -18)
    body:SetPoint("BOTTOMRIGHT", sec, "BOTTOMRIGHT", 0,   0)

    -- Scrollable editbox
    local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     body, "TOPLEFT",     4,  -4)
    scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -22, 26)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("GameFontNormalSmall")
    editBox:SetTextColor(RGB(C.text))
    editBox:SetWidth(scroll:GetWidth())
    editBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    editBox:SetText(cttLootDB and cttLootDB.lastTSV or "")
    scroll:SetScrollChild(editBox)
    pasteBox = editBox

    local editBg = FlatTex(body, "BACKGROUND", RGB(C.bg3))
    editBg:SetPoint("TOPLEFT",     body,   "TOPLEFT",     3, -3)
    editBg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 1,  0)

    local hint = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 4, 8)
    hint:SetTextColor(RGB(C.text_dim))
    hint:SetText("Col A = players  ·  Row 1 = item names  ·  Values = DPS delta")

    -- Load Data button (blue)
    local loadBtn = ElvButton(body, "Load Data", 88, 18)
    loadBtn:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 4)
    loadBtn.bg:SetVertexColor(RGB(C.accent2))
    loadBtn:SetScript("OnEnter",    function() loadBtn.bg:SetVertexColor(RGB(C.accent))  end)
    loadBtn:SetScript("OnLeave",    function() loadBtn.bg:SetVertexColor(RGB(C.accent2)) end)
    loadBtn:SetScript("OnMouseDown",function() loadBtn.bg:SetVertexColor(RGB(C.accent))  end)
    loadBtn:SetScript("OnMouseUp",  function() loadBtn.bg:SetVertexColor(RGB(C.accent2)) end)
    loadBtn:SetScript("OnClick", function()
        local raw = pasteBox:GetText()
        if not raw or raw == "" then cttLoot:Print("No data pasted.") return end
        local data, err = cttLoot:ParseTSV(raw)
        if not data then cttLoot:Print("Parse error: " .. (err or "?")) return end
        cttLoot:ApplyData(data)
        if cttLootDB then cttLootDB.lastTSV = raw end
        body:Hide()
        togLabel:SetText("Paste TSV Data")
        togHint:SetText("▶  expand")
        pasteSectionOpen = false
        sec:SetHeight(18)
        cttLoot_UI:RepositionTable()
        cttLoot_UI:Refresh()
    end)

    -- Send to Raid button
    local sendBtn = ElvButton(body, "Send to Raid", 96, 18)
    sendBtn:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)
    sendBtn:SetScript("OnClick", function()
        if #cttLoot.itemNames == 0 then cttLoot:Print("Load data first.") return end
        cttLoot:Broadcast()
    end)

    -- Toggle expand/collapse
    toggleBtn:SetScript("OnClick", function()
        pasteSectionOpen = not pasteSectionOpen
        if pasteSectionOpen then
            body:Show()
            togLabel:SetText("Paste TSV Data")
            togHint:SetText("▼  collapse")
            sec:SetHeight(SECTION_H)
        else
            body:Hide()
            togLabel:SetText("Paste TSV Data")
            togHint:SetText("▶  expand")
            sec:SetHeight(18)
        end
        cttLoot_UI:RepositionTable()
    end)

    pasteSection = sec
    return sec
end

-- ── DB Import section ─────────────────────────────────────────────────────────
local dbSection       = nil
local dbBox           = nil
local dbSectionOpen   = false
local dbStatusText    = nil

local function BuildDBSection(parent)
    local sec = CreateFrame("Frame", nil, parent)
    sec:SetPoint("TOPLEFT",  pasteSection, "BOTTOMLEFT",  0, -PAD)
    sec:SetPoint("TOPRIGHT", pasteSection, "BOTTOMRIGHT", 0, -PAD)
    sec:SetHeight(18) -- collapsed by default

    local secBg = FlatTex(sec, "BACKGROUND", RGB(C.bg2))
    secBg:SetAllPoints(sec)
    PixelBorder(sec, RGB(C.border))

    -- Header toggle
    local toggleBtn = CreateFrame("Button", nil, sec)
    toggleBtn:SetPoint("TOPLEFT")
    toggleBtn:SetPoint("TOPRIGHT")
    toggleBtn:SetHeight(18)
    local togBg = FlatTex(toggleBtn, "BACKGROUND", RGB(C.hdr_bg))
    togBg:SetAllPoints(toggleBtn)
    local togAccent = FlatTex(toggleBtn, "ARTWORK", RGB(C.accent))
    togAccent:SetWidth(2)
    togAccent:SetPoint("TOPLEFT")
    togAccent:SetPoint("BOTTOMLEFT")

    local togLabel = toggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    togLabel:SetPoint("LEFT", 8, 0)
    togLabel:SetTextColor(RGB(C.text_hi))
    togLabel:SetText("Import Item Database")

    local togHint = toggleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    togHint:SetPoint("RIGHT", -6, 0)
    togHint:SetTextColor(RGB(C.text_dim))
    togHint:SetText("▶  expand")

    -- Body
    local body = CreateFrame("Frame", nil, sec)
    body:SetPoint("TOPLEFT",     sec, "TOPLEFT",     0, -18)
    body:SetPoint("BOTTOMRIGHT", sec, "BOTTOMRIGHT", 0,  0)
    body:Hide()

    -- Scrollable editbox for raw paste
    local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     body, "TOPLEFT",     4,  -4)
    scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -22, 30)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("GameFontNormalSmall")
    editBox:SetTextColor(RGB(C.text))
    editBox:SetWidth(scroll:GetWidth())
    editBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    scroll:SetScrollChild(editBox)
    dbBox = editBox

    local editBg = FlatTex(body, "BACKGROUND", RGB(C.bg3))
    editBg:SetPoint("TOPLEFT",     body,   "TOPLEFT",     3, -3)
    editBg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 1,  0)

    -- Status line
    local status = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 4, 8)
    status:SetTextColor(RGB(C.text_dim))
    status:SetText("Format: ItemID \\t Name \\t Boss [\\t Raid]")
    dbStatusText = status

    -- Append button (blue)
    local appendBtn = ElvButton(body, "Append", 72, 18)
    appendBtn:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 4)
    appendBtn.bg:SetVertexColor(RGB(C.accent2))
    appendBtn:SetScript("OnEnter",    function() appendBtn.bg:SetVertexColor(RGB(C.accent))  end)
    appendBtn:SetScript("OnLeave",    function() appendBtn.bg:SetVertexColor(RGB(C.accent2)) end)
    appendBtn:SetScript("OnClick", function()
        local raw = dbBox:GetText()
        if not raw or raw == "" then
            dbStatusText:SetText("|cffff4444No data pasted.|r")
            return
        end
        local entries = cttLoot:ParseDBRaw(raw)
        local count = 0
        for _ in pairs(entries) do count = count + 1 end
        if count == 0 then
            dbStatusText:SetText("|cffff4444No valid entries found.|r")
            return
        end
        -- Merge into live DB
        for id, entry in pairs(entries) do cttLoot.DB[id] = entry end
        -- Save to SavedVariables
        for id, entry in pairs(entries) do cttLootDB.customDB[id] = entry end
        -- Rebuild lookups
        cttLoot:MergeCustomDB()
        cttLoot_UI:PopulateBossDropdown()
        local total = 0
        for _ in pairs(cttLootDB.customDB) do total = total + 1 end
        dbStatusText:SetText(string.format("|cff55cc55✓ Appended %d items. Custom DB: %d total.|r", count, total))
    end)

    -- Send to Raid button
    local dbSendBtn = ElvButton(body, "Send to Raid", 96, 18)
    dbSendBtn:SetPoint("RIGHT", clearBtn, "LEFT", -4, 0)
    dbSendBtn:SetScript("OnClick", function()
        cttLoot:BroadcastDB()
    end)

    -- Clear button (red)
    local clearBtn = ElvButton(body, "Clear DB", 72, 18)
    clearBtn:SetPoint("RIGHT", appendBtn, "LEFT", -4, 0)
    clearBtn.bg:SetVertexColor(0.45, 0.15, 0.15)
    clearBtn:SetScript("OnEnter", function() clearBtn.bg:SetVertexColor(0.65, 0.20, 0.20) end)
    clearBtn:SetScript("OnLeave", function() clearBtn.bg:SetVertexColor(0.45, 0.15, 0.15) end)
    clearBtn:SetScript("OnClick", function()
        cttLootDB.customDB = {}
        -- Reset DB to hardcoded only — rebuild from scratch
        wipe(cttLoot.DBByName)
        wipe(cttLoot.DBByBoss)
        -- Re-run the static BuildDBLookups equivalent
        for _, entry in pairs(cttLoot.DB) do
            local nameLower = (entry.name or ""):lower()
            if nameLower ~= "" then
                cttLoot.DBByName[nameLower] = { boss = entry.boss, raid = entry.raid }
            end
            if entry.boss then
                if not cttLoot.DBByBoss[entry.boss] then cttLoot.DBByBoss[entry.boss] = {} end
                table.insert(cttLoot.DBByBoss[entry.boss], entry.name)
            end
        end
        cttLoot_UI:PopulateBossDropdown()
        dbStatusText:SetText("|cffaaaaaaCustom DB cleared. Hardcoded DB retained.|r")
    end)

    -- Toggle
    toggleBtn:SetScript("OnClick", function()
        dbSectionOpen = not dbSectionOpen
        if dbSectionOpen then
            body:Show()
            togHint:SetText("▼  collapse")
            sec:SetHeight(SECTION_H)
        else
            body:Hide()
            togHint:SetText("▶  expand")
            sec:SetHeight(18)
        end
        cttLoot_UI:RepositionFilterBar()
    end)

    dbSection = sec
    return sec
end
local function BuildFilterBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(FILTER_H)
    bar:SetPoint("TOPLEFT",  dbSection, "BOTTOMLEFT",  0, -PAD)
    bar:SetPoint("TOPRIGHT", dbSection, "BOTTOMRIGHT", 0, -PAD)

    local barBg = FlatTex(bar, "BACKGROUND", RGB(C.bg2))
    barBg:SetAllPoints(bar)
    PixelBorder(bar, RGB(C.border))

    local accent = FlatTex(bar, "ARTWORK", RGB(C.accent))
    accent:SetWidth(2)
    accent:SetPoint("TOPLEFT")
    accent:SetPoint("BOTTOMLEFT")

    local label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", 8, 0)
    label:SetTextColor(RGB(C.text_dim))
    label:SetText("Filter:")

    local eb = ElvEditBox(bar, 220, 16)
    eb:SetPoint("LEFT", label, "RIGHT", 6, 0)
    eb:SetScript("OnTextChanged", function(self)
        filterText = self:GetText():lower()
        cttLoot_UI:ApplyFilter()
    end)
    filterBox = eb

    local clearBtn = ElvButton(bar, "X", 18, 16)
    clearBtn:SetPoint("LEFT", eb, "RIGHT", 4, 0)
    clearBtn.bg:SetVertexColor(0.45, 0.15, 0.15)
    clearBtn:SetScript("OnEnter", function() clearBtn.bg:SetVertexColor(0.65, 0.20, 0.20) end)
    clearBtn:SetScript("OnLeave", function() clearBtn.bg:SetVertexColor(0.45, 0.15, 0.15) end)
    clearBtn:SetScript("OnClick", function()
        eb:SetText("")
        currentItem = nil
        filterText  = ""
        cttLoot_UI:Refresh()
    end)

    -- Separator
    local sep = FlatTex(bar, "ARTWORK", RGB(C.border))
    sep:SetWidth(1)
    sep:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0)
    sep:SetHeight(14)

    -- Boss label
    local bossLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossLabel:SetPoint("LEFT", sep, "RIGHT", 8, 0)
    bossLabel:SetTextColor(RGB(C.text_dim))
    bossLabel:SetText("Boss:")

    -- Boss dropdown button (ElvUI-style flat button that opens a list)
    local bossBtn = ElvButton(bar, "All Bosses", 160, 16)
    bossBtn:SetPoint("LEFT", bossLabel, "RIGHT", 6, 0)
    bossBtn.bg:SetVertexColor(RGB(C.bg3))
    cttLoot_UI.bossBtn = bossBtn

    -- Boss clear button
    local bossClearBtn = ElvButton(bar, "X", 16, 16)
    bossClearBtn:SetPoint("LEFT", bossBtn, "RIGHT", 4, 0)
    bossClearBtn.bg:SetVertexColor(0.45, 0.15, 0.15)
    bossClearBtn:SetScript("OnEnter", function() bossClearBtn.bg:SetVertexColor(0.65, 0.20, 0.20) end)
    bossClearBtn:SetScript("OnLeave", function() bossClearBtn.bg:SetVertexColor(0.45, 0.15, 0.15) end)
    bossClearBtn:SetScript("OnClick", function()
        cttLoot_UI:SetBossFilter(nil)
    end)
    cttLoot_UI.bossClearBtn = bossClearBtn
    bossClearBtn:Hide()

    -- Boss dropdown frame
    local dropdown = CreateFrame("Frame", "cttLootBossDropdown", UIParent, "BackdropTemplate")
    dropdown:SetWidth(200)
    dropdown:SetFrameStrata("TOOLTIP")
    dropdown:SetFrameLevel(200)
    local ddBg = FlatTex(dropdown, "BACKGROUND", RGB(C.bg2))
    ddBg:SetAllPoints(dropdown)
    PixelBorder(dropdown, RGB(C.accent))
    dropdown:Hide()
    cttLoot_UI.bossDropdown = dropdown
    cttLoot_UI.bossDropdownRows = {}

    -- Open/close dropdown on click
    bossBtn:SetScript("OnClick", function()
        if dropdown:IsShown() then
            dropdown:Hide()
        else
            cttLoot_UI:PopulateBossDropdown()
            dropdown:ClearAllPoints()
            dropdown:SetPoint("TOPLEFT", bossBtn, "BOTTOMLEFT", 0, -2)
            dropdown:Show()
        end
    end)

    -- Close dropdown when clicking elsewhere
    local ddClose = CreateFrame("Frame", nil, UIParent)
    ddClose:SetAllPoints(UIParent)
    ddClose:SetFrameStrata("DIALOG")
    ddClose:EnableMouse(true)
    ddClose:Hide()
    ddClose:SetScript("OnMouseDown", function()
        dropdown:Hide()
        ddClose:Hide()
    end)
    dropdown:SetScript("OnShow", function() ddClose:Show() end)
    dropdown:SetScript("OnHide", function() ddClose:Hide() end)

    local stats = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stats:SetPoint("RIGHT", bar, "RIGHT", -8, 0)
    stats:SetTextColor(RGB(C.text_dim))
    cttLoot_UI.statsLabel = stats

    filterSection = bar
    return bar
end

-- ── Table area ────────────────────────────────────────────────────────────────
local function BuildTableHeader(parent)
    local hdr = CreateFrame("Frame", nil, parent)
    hdr:SetHeight(HDR_H)
    hdr:SetPoint("TOPLEFT")
    hdr:SetPoint("TOPRIGHT")

    local hdrBg = FlatTex(hdr, "BACKGROUND", RGB(C.hdr_bg))
    hdrBg:SetAllPoints(hdr)

    local hdrLine = FlatTex(hdr, "ARTWORK", RGB(C.accent))
    hdrLine:SetHeight(1)
    hdrLine:SetPoint("BOTTOMLEFT")
    hdrLine:SetPoint("BOTTOMRIGHT")

    local function HdrLabel(text, xLeft, w)
        local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetWidth(w)
        fs:SetPoint("LEFT", xLeft, 0)
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(RGB(C.text_dim))
        fs:SetText(text:upper())
    end
    HdrLabel("#",         4,                       COL_RANK)
    HdrLabel("Player",    COL_RANK + 4,            COL_NAME)
    HdrLabel("DPS Delta", COL_RANK + COL_NAME + 4, COL_DPS)
    return hdr
end

local function BuildTableArea(parent)
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("TOPLEFT",     filterSection, "BOTTOMLEFT",  0,    -PAD)
    container:SetPoint("BOTTOMRIGHT", parent,        "BOTTOMRIGHT", -PAD,  PAD)

    local contBg = FlatTex(container, "BACKGROUND", RGB(C.bg))
    contBg:SetAllPoints(container)
    PixelBorder(container, RGB(C.border))

    local hdr = BuildTableHeader(container)

    local sf = CreateFrame("ScrollFrame", "cttLootScroll", container, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     hdr,       "BOTTOMLEFT",   0,  -1)
    sf:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -18,  1)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(sf:GetWidth())
    content:SetHeight(1)
    sf:SetScrollChild(content)

    scrollFrame   = sf
    scrollContent = content
    tableFrame    = container
    return container
end

-- ── Row pool ──────────────────────────────────────────────────────────────────
local function GetOrCreateRow(idx)
    if rowFrames[idx] then return rowFrames[idx] end

    local row = CreateFrame("Frame", nil, scrollContent)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT",  scrollContent, "TOPLEFT",  0, -(idx - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", scrollContent, "TOPRIGHT", 0, -(idx - 1) * ROW_H)

    local bg = FlatTex(row, "BACKGROUND", 1, 1, 1, idx % 2 == 0 and 0.04 or 0.00)
    bg:SetAllPoints(row)
    row.bg = bg

    local sep = FlatTex(row, "ARTWORK", RGB(C.border))
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT")
    sep:SetPoint("BOTTOMRIGHT")

    local rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rank:SetWidth(COL_RANK)
    rank:SetPoint("LEFT", 4, 0)
    rank:SetJustifyH("CENTER")
    row.rank = rank

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetWidth(COL_NAME)
    name:SetPoint("LEFT", COL_RANK + 4, 0)
    name:SetJustifyH("LEFT")
    row.name = name

    local dps = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dps:SetWidth(COL_DPS)
    dps:SetPoint("LEFT", COL_RANK + COL_NAME + 4, 0)
    dps:SetJustifyH("RIGHT")
    row.dps = dps

    local barBg = FlatTex(row, "ARTWORK", 1, 1, 1, 0.06)
    barBg:SetHeight(4)
    barBg:SetPoint("LEFT", COL_RANK + COL_NAME + COL_DPS + 10, 0)
    barBg:SetWidth(COL_BAR)
    row.barBg = barBg

    local barFill = FlatTex(row, "ARTWORK", RGB(C.green))
    barFill:SetHeight(4)
    barFill:SetPoint("LEFT", barBg, "LEFT", 0, 0)
    barFill:SetWidth(1)
    row.barFill = barFill

    row:Show()
    rowFrames[idx] = row
    return row
end

local function ClearRows(from)
    for i = from, #rowFrames do
        if rowFrames[i] then rowFrames[i]:Hide() end
    end
end

-- ── Populate ──────────────────────────────────────────────────────────────────
local function PopulateTable(_, itemName)
    local colIdx = nil
    if itemName then
        for i, n in ipairs(cttLoot.itemNames) do
            if n == itemName then colIdx = i; break end
        end
    end

    -- Use visible items (respects boss filter) when showing overview
    local visibleNames = cttLoot_UI:GetVisibleItems()

    local rows = {}
    for r, player in ipairs(cttLoot.playerNames) do
        if colIdx then
            rows[#rows + 1] = { player = player, dps = cttLoot.matrix[r] and cttLoot.matrix[r][colIdx] }
        else
            local total = nil
            if cttLoot.matrix[r] then
                for _, visName in ipairs(visibleNames) do
                    -- find column index for this visible item
                    for ci, n in ipairs(cttLoot.itemNames) do
                        if n == visName then
                            local v = cttLoot.matrix[r][ci]
                            if v then total = (total or 0) + v end
                            break
                        end
                    end
                end
            end
            rows[#rows + 1] = { player = player, dps = total }
        end
    end

    table.sort(rows, function(a, b)
        if a.dps == nil and b.dps == nil then return false end
        if a.dps == nil then return false end
        if b.dps == nil then return true  end
        return a.dps > b.dps
    end)

    local maxAbs = 1
    for _, row in ipairs(rows) do
        if row.dps and math.abs(row.dps) > maxAbs then maxAbs = math.abs(row.dps) end
    end

    local count = 0
    for i, row in ipairs(rows) do
        local fr = GetOrCreateRow(i)
        fr:Show()
        count = i

        if i == 1 then
            fr.rank:SetText(string.format("|cff%02x%02x%02x1|r",
                C.rank_gold[1]*255, C.rank_gold[2]*255, C.rank_gold[3]*255))
        elseif i == 2 then
            fr.rank:SetText(string.format("|cff%02x%02x%02x2|r",
                C.rank_silver[1]*255, C.rank_silver[2]*255, C.rank_silver[3]*255))
        elseif i == 3 then
            fr.rank:SetText(string.format("|cff%02x%02x%02x3|r",
                C.rank_bronze[1]*255, C.rank_bronze[2]*255, C.rank_bronze[3]*255))
        else
            fr.rank:SetTextColor(RGB(C.text_dim))
            fr.rank:SetText(tostring(i))
        end

        fr.name:SetText(row.player)
        fr.name:SetTextColor(RGB(C.text))

        if row.dps == nil then
            fr.dps:SetText("|cff555555—|r")
            fr.barFill:SetWidth(1)
        else
            local isPos = row.dps >= 0
            local sign  = isPos and "+" or ""
            local cr, cg, cb = isPos and RGB(C.green) or RGB(C.red)
            fr.dps:SetText(string.format("|cff%02x%02x%02x%s%.1f|r",
                cr * 255, cg * 255, cb * 255, sign, row.dps))
            local barW = math.max(2, math.floor(math.abs(row.dps) / maxAbs * COL_BAR))
            fr.barFill:SetWidth(barW)
            fr.barFill:SetVertexColor(cr, cg, cb, 0.85)
        end
    end

    ClearRows(count + 1)
    scrollContent:SetHeight(math.max(count * ROW_H, 1))

    if cttLoot_UI.statsLabel then
        if itemName then
            local info = cttLoot:GetItemInfo(itemName)
            local bossStr = info and ("|cff3E7DC0·|r " .. info.boss) or ""
            cttLoot_UI.statsLabel:SetText(string.format(
                "%s  %s  |cff3E7DC0·|r  %d players", itemName, bossStr, count))
        else
            local bossStr = cttLoot_UI.selectedBoss
                and ("|cff3E7DC0·|r " .. cttLoot_UI.selectedBoss .. "  ") or ""
            cttLoot_UI.statsLabel:SetText(string.format(
                "%s%d items  |cff3E7DC0·|r  %d players",
                bossStr, #visibleNames, #cttLoot.playerNames))
        end
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Boss filter state
cttLoot_UI.selectedBoss = nil

function cttLoot_UI:SetBossFilter(bossName)
    self.selectedBoss = bossName
    self.lootFilter   = nil  -- clear loot filter when boss is manually changed
    if self.bossBtn then
        self.bossBtn.label:SetText(bossName or "All Bosses")
    end
    if self.bossClearBtn then
        if bossName then self.bossClearBtn:Show() else self.bossClearBtn:Hide() end
    end
    if self.bossDropdown then self.bossDropdown:Hide() end
    self:Refresh()
end

function cttLoot_UI:PopulateBossDropdown()
    local dd   = self.bossDropdown
    local rows = self.bossDropdownRows
    -- Clear old rows
    for _, r in ipairs(rows) do r:Hide() end
    wipe(rows)

    local bosses = cttLoot:GetAllBosses()
    local ROW_H  = 18
    local y      = 0
    local lastRaid = nil

    -- "All Bosses" row
    local allRow = ElvButton(dd, "All Bosses", 198, ROW_H)
    allRow:SetPoint("TOPLEFT", 1, -y - 1)
    allRow:SetScript("OnClick", function() self:SetBossFilter(nil) end)
    table.insert(rows, allRow)
    y = y + ROW_H

    if #bosses == 0 then
        -- Empty DB notice
        local notice = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        notice:SetPoint("TOPLEFT", 6, -y - 4)
        notice:SetText("|cff555555No database entries yet|r")
        notice:SetWidth(186)
        y = y + 22
        table.insert(rows, notice)
    else
        for _, entry in ipairs(bosses) do
            -- Raid header
            if entry.raid ~= lastRaid then
                lastRaid = entry.raid
                local hdr = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hdr:SetPoint("TOPLEFT", 6, -y - 3)
                hdr:SetText("|cff3E7DC0" .. entry.raid .. "|r")
                hdr:SetWidth(186)
                y = y + 18
                table.insert(rows, hdr)
                -- accent line under raid header
                local line = FlatTex(dd, "ARTWORK", RGB(C.accent))
                line:SetHeight(1)
                line:SetPoint("TOPLEFT",  dd, "TOPLEFT",  1, -y)
                line:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -1, -y)
                y = y + 1
                table.insert(rows, line)
            end
            -- Boss row
            local bossRow = ElvButton(dd, entry.boss, 198, ROW_H)
            bossRow:SetPoint("TOPLEFT", 1, -y - 1)
            local bName = entry.boss
            bossRow:SetScript("OnClick", function() self:SetBossFilter(bName) end)
            -- Highlight if selected
            if self.selectedBoss == bName then
                bossRow.bg:SetVertexColor(RGB(C.accent2))
            end
            table.insert(rows, bossRow)
            y = y + ROW_H
        end
    end

    dd:SetHeight(y + 4)
    self.bossDropdownRows = rows
end

cttLoot_UI.lootFilter = nil

function cttLoot_UI:SetLootFilter(names)
    self.lootFilter = names
end

function cttLoot_UI:GetVisibleItems()
    if self.lootFilter then return self.lootFilter end
    if not self.selectedBoss then return cttLoot.itemNames end
    return self:GetVisibleItemsForBoss(self.selectedBoss)
end

-- Returns items from a specific boss that are present in the loaded TSV
function cttLoot_UI:GetVisibleItemsForBoss(bossName)
    local result  = {}
    local bossSet = {}
    for _, name in ipairs(cttLoot:GetItemsForBoss(bossName)) do
        bossSet[name:lower()] = true
    end
    for _, name in ipairs(cttLoot.itemNames) do
        if bossSet[name:lower()] then
            table.insert(result, name)
        end
    end
    return result
end

function cttLoot_UI:IsWindowShown()
    return window and window:IsShown()
end

function cttLoot_UI:Refresh()
    if not window then return end
    PopulateTable(nil, currentItem)
end

function cttLoot_UI:ApplyFilter()
    if filterText == "" then currentItem = nil; self:Refresh(); return end
    for _, name in ipairs(cttLoot.itemNames) do
        if name:lower() == filterText then currentItem = name; self:Refresh(); return end
    end
    for _, name in ipairs(cttLoot.itemNames) do
        if name:lower():find(filterText, 1, true) then currentItem = name; self:Refresh(); return end
    end
    currentItem = nil; self:Refresh()
end

function cttLoot_UI:RepositionFilterBar()
    if not filterSection then return end
    filterSection:ClearAllPoints()
    filterSection:SetPoint("TOPLEFT",  dbSection, "BOTTOMLEFT",  0, -PAD)
    filterSection:SetPoint("TOPRIGHT", dbSection, "BOTTOMRIGHT", 0, -PAD)
    self:RepositionTable()
end

function cttLoot_UI:RepositionTable()
    if not tableFrame then return end
    tableFrame:ClearAllPoints()
    tableFrame:SetPoint("TOPLEFT",     filterSection, "BOTTOMLEFT",  0,    -PAD)
    tableFrame:SetPoint("BOTTOMRIGHT", window,        "BOTTOMRIGHT", -PAD,  PAD)
end

function cttLoot_UI:Toggle()
    if not window then self:Build() end
    if window:IsShown() then window:Hide()
    else window:Show(); self:Refresh() end
end

function cttLoot_UI:Build()
    window = BuildWindow()
    BuildPasteSection(window)
    BuildDBSection(window)
    BuildFilterBar(window)
    BuildTableArea(window)
    window:Hide()
end

-- Init on login
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function() cttLoot_UI:Build() end)
