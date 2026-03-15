-- cttLoot_Minimap.lua
-- Minimap button built exactly like LibDBIcon-1.0.
-- Uses GetMinimapShape() to handle both round (default WoW) and
-- square (ElvUI) minimaps — the same algorithm all major addons use.

local DEFAULT_POS = 220  -- degrees 0-360

local btn = nil
local ICON = "Interface\\Icons\\INV_Misc_Bag_10"

-- ── Shape table (copied verbatim from LibDBIcon-1.0) ─────────────────────────
-- Each entry is {q1, q2, q3, q4} — true = use circular radius for that quadrant
-- false = use clamped diagonal (snaps to square edge)
-- SQUARE has all false → every quadrant snaps to edge, works perfectly with ElvUI
local minimapShapes = {
    ["ROUND"]                = {true,  true,  true,  true},
    ["SQUARE"]               = {false, false, false, false},
    ["CORNER-TOPLEFT"]       = {false, false, false, true},
    ["CORNER-TOPRIGHT"]      = {false, false, true,  false},
    ["CORNER-BOTTOMLEFT"]    = {false, true,  false, false},
    ["CORNER-BOTTOMRIGHT"]   = {true,  false, false, false},
    ["SIDE-LEFT"]            = {false, true,  false, true},
    ["SIDE-RIGHT"]           = {true,  false, true,  false},
    ["SIDE-TOP"]             = {false, false, true,  true},
    ["SIDE-BOTTOM"]          = {true,  true,  false, false},
    ["TRICORNER-TOPLEFT"]    = {false, true,  true,  true},
    ["TRICORNER-TOPRIGHT"]   = {true,  false, true,  true},
    ["TRICORNER-BOTTOMLEFT"] = {true,  true,  false, true},
    ["TRICORNER-BOTTOMRIGHT"]= {true,  true,  true,  false},
}

-- ── Position ──────────────────────────────────────────────────────────────────
local function UpdatePosition()
    local angle = math.rad((cttLootDB and cttLootDB.minimapAngle) or DEFAULT_POS)
    local x, y  = math.cos(angle), math.sin(angle)

    -- Determine which quadrant (1-4) for shape lookup
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end

    local shape   = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTbl = minimapShapes[shape] or minimapShapes["ROUND"]

    -- Use actual minimap dimensions so the button always sits just outside
    -- the edge regardless of minimap size (default WoW ~160px, ElvUI ~200px+)
    local w = (Minimap:GetWidth()  / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5

    if quadTbl[q] then
        -- Circular quadrant: scale by half-extents
        x, y = x * w, y * h
    else
        -- Square edge: diagonal radius clamped to the half-extents
        local diagW = math.sqrt(2 * w * w) - 10
        local diagH = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * diagW, w))
        y = math.max(-h, math.min(y * diagH, h))
    end

    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- ── Drag OnUpdate ─────────────────────────────────────────────────────────────
local function OnUpdate(self)
    local mx, my = Minimap:GetCenter()
    local scale  = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    if cttLootDB then
        cttLootDB.minimapAngle = math.deg(math.atan2(py - my, px - mx)) % 360
    end
    UpdatePosition()
end

-- ── Build ─────────────────────────────────────────────────────────────────────
local function Build()
    -- Exact LibDBIcon-1.0 button structure
    btn = CreateFrame("Button", "LibDBIcon10_cttLoot", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetWidth(31); btn:SetHeight(31)
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("anyUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Overlay ring: 53x53 at TOPLEFT (provides circular clipping visually)
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53); overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    -- Background circle fill
    local background = btn:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5)

    -- Icon: 17x17 inside the ring
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(17); icon:SetHeight(17)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5)
    btn.icon = icon

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("cttLoot", 0.24, 0.49, 0.75)
        GameTooltip:AddLine("Left-click: Toggle window",    0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right-click: Check data sync", 0.55, 0.55, 0.55)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Icon texcoord feedback on mouse down/up (LibDBIcon pattern)
    btn:SetScript("OnMouseDown", function(self) self.icon:SetTexCoord(0, 1, 0, 1) end)
    btn:SetScript("OnMouseUp",   function(self) self.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95) end)

    -- Click
    local isMoving = false
    btn:SetScript("OnClick", function(self, b)
        if isMoving then return end
        if b == "LeftButton"  then cttLoot_UI:Toggle()  end
        if b == "RightButton" then cttLoot:RunCheck()   end
    end)

    -- Drag
    local function ResetMoving() isMoving = false end
    btn:SetScript("OnDragStart", function(self)
        isMoving = true
        self:LockHighlight()
        self:SetScript("OnUpdate", OnUpdate)
        GameTooltip:Hide()
    end)
    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
        C_Timer.After(0, ResetMoving)
    end)

    UpdatePosition()
end

-- ── Init ──────────────────────────────────────────────────────────────────────
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name)
    if name ~= "cttLoot" then return end
    f:UnregisterEvent("ADDON_LOADED")
    Build()
end)
