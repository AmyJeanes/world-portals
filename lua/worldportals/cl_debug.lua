
CreateClientConVar("worldportals_debug", "0", true, false, "World Portals - Debug overlay (0=off, 1=clipped to visible, 2=rendered only, 3=all incl. culled)", 0, 3)

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
                                 parentPoly, depth, maxDepth, mode)
    if depth > maxDepth then return end

    -- Per-mode visibility flags. Mode 1 also clips visible orange overlays
    -- to the cumulative ancestor footprint so each one shows just the
    -- portion the player can actually see through the stencil chain.
    local showCulled
    if depth == 1 then
        showCulled = (mode == 1 or mode == 3)
    else
        showCulled = (mode == 3)
    end
    local clipOrange = (mode == 1)

    for _, portal in pairs(portals) do
        if IsValid(portal) then
            local rendered = wp.shouldrender(portal, plyOrigin, plyAngles, plyFov)
            -- Top-level always considers culled portals (red); deeper levels
            -- skip portals the current camera doesn't see (inner-cam cull).
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

                if visible or showCulled then
                    surface.SetDrawColor(color)
                    local drawPts = pts
                    if visible and depth > 1 and clipOrange and parentPoly then
                        drawPts = wp.IntersectConvexPolygons(pts, parentPoly)
                    end
                    drawScreenPolygon(drawPts)
                end

                if visible and depth + 1 <= maxDepth then
                    local exit = portal:GetExit()
                    if IsValid(exit) then
                        local innerOrigin = wp.TransformPortalPos(plyOrigin, portal, exit)
                        local innerAngles = wp.TransformPortalAngle(plyAngles, portal, exit)
                        -- Cumulative ancestor footprint: clip this portal's
                        -- polygon against the existing parent so deeper
                        -- levels test against every ancestor's stencil.
                        local childParent = pts
                        if depth > 1 and parentPoly then
                            childParent = wp.IntersectConvexPolygons(pts, parentPoly)
                        end
                        drawPortalOverlay(innerOrigin, innerAngles, plyFov, aspect, portals,
                            childParent, depth + 1, maxDepth, mode)
                    end
                end
            end
        end
    end
end

hook.Add("HUDPaint", "WorldPortals_Debug", function()
    local mode = GetConVar("worldportals_debug"):GetInt()
    if mode <= 0 then return end

    local camPos = EyePos()
    local camAng = EyeAngles()
    local camFov = LocalPlayer():GetFOV()
    local aspect = ScrW() / ScrH()
    local portals = ents.FindByClass("linked_portal_door")
    local maxDepth = wp.GetRecurseDepth()

    drawPortalOverlay(camPos, camAng, camFov, aspect, portals, nil, 1, maxDepth, mode)

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
