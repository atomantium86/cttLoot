-- cttLoot_Minimap.lua
-- Self-contained minimap button (no LibDBIcon dependency).
-- Saves position angle in cttLootDB.minimapAngle.
-- Left-click toggles the main window; right-click opens/closes the settings drawer.

local ICON       = "Interface\\Icons\\INV_Misc_Bag_10"
local BTN_SIZE   = 32
local RADIUS     = 80   -- minimap orbit radius
local DEFAULT_ANGLE = -30  -- degrees, 0 = right, -90 = top

local btn   = nil
local dragging = false
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ── Angle → position on minimap edge ─────────────────────────────────────────
local function AngleToPos(angle)
    local rad = math.rad(angle)
    return RADIUS * math.cos(rad), RADIUS * math.sin(rad)
end

local function PosToAngle(x, y)
    return math.deg(math.atan2(y, x))
end

local function ApplyAngle(angle)
    local x, y = AngleToPos(angle)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- ── Build ─────────────────────────────────────────────────────────────────────
local function Build()
    btn = CreateFrame("Button", "cttLootMinimapBtn", Minimap)
    btn:SetSize(BTN_SIZE, BTN_SIZE)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)

    -- Circular mask (Minimap clip region)
    btn:SetClampedToScreen(false)
    btn:SetMovable(true)

    -- Background circle
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.1, 0.1, 0.1, 1)
    bg:SetAllPoints(btn)

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetAllPoints(btn)
    btn._icon = icon

    -- Border ring (pixel border in accent colour)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(BTN_SIZE + 10, BTN_SIZE + 10)
    border:SetPoint("CENTER", btn, "CENTER", 0, 0)
    border:SetVertexColor(0.24, 0.49, 0.75, 1)  -- accent blue

    -- Highlight
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.12)
    hl:SetAllPoints(btn)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("cttLoot", 0.24, 0.49, 0.75)
        GameTooltip:AddLine("Left-click: Toggle window", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right-click: Check data sync", 0.55, 0.55, 0.55)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Left-click: toggle main window
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and not dragging then
            cttLoot_UI:Toggle()
        elseif button == "RightButton" and not dragging then
            cttLoot:RunCheck()
        end
    end)

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Drag to reposition around minimap
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        dragging = false
        self:SetScript("OnUpdate", function(self_)
            dragging = true
            local cx, cy = Minimap:GetCenter()
            local mx, my = GetCursorPosition()
            local scale  = UIParent:GetEffectiveScale()
            mx, my = mx / scale, my / scale
            local angle  = PosToAngle(mx - cx, my - cy)
            cttLootDB.minimapAngle = angle
            ApplyAngle(angle)
        end)
    end)
    btn:SetScript("OnDragStop", function(self_)
        self_:SetScript("OnUpdate", nil)
        C_Timer.After(0.05, function() dragging = false end)
    end)

    -- Initial position
    local angle = (cttLootDB and cttLootDB.minimapAngle) or DEFAULT_ANGLE
    ApplyAngle(angle)
end

-- ── Init ──────────────────────────────────────────────────────────────────────
local initF = CreateFrame("Frame")
initF:RegisterEvent("PLAYER_LOGIN")
initF:SetScript("OnEvent", function()
    Build()
    -- Try to set the real addon icon if available
    local iconTex = C_AddOns and C_AddOns.GetAddOnMetadata and
        C_AddOns.GetAddOnMetadata("cttLoot", "IconTexture")
    if iconTex and btn._icon then btn._icon:SetTexture(iconTex) end
end)
