
CreateClientConVar("worldportals_debug", "0", true, false, "World Portals - Show portal render-decision debug overlay", 0, 1)

local COLOR_RENDERED = Color(0, 255, 0, 220)
local COLOR_CULLED = Color(255, 60, 60, 220)
local COLOR_CHILD = Color(255, 220, 0, 220)
local COLOR_CHILD_VISIBLE = Color(255, 140, 0, 220)

local function drawScreenPolygon(pts)
    if #pts < 2 then return end
    local first, prev
    for _, p in ipairs(pts) do
        if prev then
            surface.DrawLine(prev.x, prev.y, p.x, p.y)
        else
            first = p
        end
        prev = p
    end
    if first and prev and prev ~= first then
        surface.DrawLine(prev.x, prev.y, first.x, first.y)
    end
end

-- Recursively walk the portal tree, mirroring wp.renderportals' logic. At
-- depth 1 we draw every portal in the player's view (green if it would
-- render, red if not). At depth >= 2 we only draw portals the current
-- camera can see (skipping those wp.shouldrender rejects), colouring
-- orange when SAT-intersecting the immediate parent's polygon and
-- yellow otherwise. We descend into a portal's exit only when it
-- would actually render, since that mirrors what the renderer does.
local function drawPortalOverlay(plyOrigin, plyAngles, plyFov, aspect, portals,
                                 parentPoly, depth, maxDepth)
    if depth > maxDepth then return end

    for _, portal in pairs(portals) do
        if IsValid(portal) then
            local rendered = wp.shouldrender(portal, plyOrigin, plyAngles, plyFov)
            -- Top-level draws even when culled (red); deeper levels skip culled.
            if depth == 1 or rendered then
                local pts = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngles, plyFov, aspect)

                local visible, color
                if depth == 1 then
                    visible = rendered
                    color = rendered and COLOR_RENDERED or COLOR_CULLED
                else
                    visible = parentPoly and wp.PolygonsIntersectSAT(parentPoly, pts) or false
                    color = visible and COLOR_CHILD_VISIBLE or COLOR_CHILD
                end

                surface.SetDrawColor(color)
                drawScreenPolygon(pts)

                if visible and depth + 1 <= maxDepth then
                    local exit = portal:GetExit()
                    if IsValid(exit) then
                        local innerOrigin = wp.TransformPortalPos(plyOrigin, portal, exit)
                        local innerAngles = wp.TransformPortalAngle(plyAngles, portal, exit)
                        drawPortalOverlay(innerOrigin, innerAngles, plyFov, aspect, portals,
                            pts, depth + 1, maxDepth)
                    end
                end
            end
        end
    end
end

hook.Add("HUDPaint", "WorldPortals_Debug", function()
    if not GetConVar("worldportals_debug"):GetBool() then return end

    local camPos = EyePos()
    local camAng = EyeAngles()
    local camFov = LocalPlayer():GetFOV()
    local aspect = ScrW() / ScrH()
    local portals = ents.FindByClass("linked_portal_door")
    local maxDepth = wp.GetRecurseDepth()

    drawPortalOverlay(camPos, camAng, camFov, aspect, portals, nil, 1, maxDepth)

    local SHADOW = Color(0, 0, 0, 220)
    local x = 16
    local lineH = 22
    local total = wp.GetFramePortalRenderCount()
    local byDepth = wp.GetFramePortalRenderByDepth()

    -- Center the block vertically around screen midline.
    local visibleDepths = 0
    for d = 1, maxDepth do
        if (byDepth[d] or 0) > 0 then visibleDepths = visibleDepths + 1 end
    end
    local totalLines = 1 + visibleDepths
    local y = math.floor(ScrH() * 0.5 - ((totalLines - 1) * lineH) * 0.5)

    draw.SimpleTextOutlined("Portal renders: " .. total, "Trebuchet18", x, y,
        color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, SHADOW)
    y = y + lineH
    for d = 1, maxDepth do
        local c = byDepth[d] or 0
        if c > 0 then
            draw.SimpleTextOutlined(("  D%d: %d"):format(d, c), "Trebuchet18", x, y,
                color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, SHADOW)
            y = y + lineH
        end
    end
end)
