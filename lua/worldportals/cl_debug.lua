
CreateClientConVar("worldportals_debug", "0", true, false, "World Portals - Debug overlay (0=off, 1=clipped to visible, 2=rendered only, 3=all incl. culled)", 0, 3)

local COLOR_RENDERED = Color(0, 255, 0, 220)
local COLOR_CULLED = Color(255, 60, 60, 220)
local COLOR_CHILD = Color(255, 220, 0, 220)
local COLOR_CHILD_VISIBLE = Color(255, 140, 0, 220)

-- Polygon is a flat array {x1, y1, x2, y2, ...}.
local function drawScreenPolygon(pts)
    local n = #pts
    if n < 4 then return end
    local prevX, prevY = pts[n-1], pts[n]
    for i = 1, n, 2 do
        local x, y = pts[i], pts[i+1]
        surface.DrawLine(prevX, prevY, x, y)
        prevX, prevY = x, y
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
                                 parentPoly, depth, maxDepth, mode,
                                 parentExitPos, parentExitFwd)
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

    local minArea = wp.GetMinRenderArea()

    for _, portal in pairs(portals) do
        if IsValid(portal) then
            local rendered = wp.shouldrender(portal, plyOrigin, plyAngles, plyFov)
            -- Mirror renderportals' exit clip-plane cull so the overlay
            -- agrees with what actually gets rendered.
            if rendered and depth > 1 and parentExitPos and parentExitFwd then
                local signedDist = (portal:GetPos() - parentExitPos):Dot(parentExitFwd)
                if signedDist + portal:BoundingRadius() < -0.5 then
                    rendered = false
                end
            end
            -- Top-level always considers culled portals (red); deeper levels
            -- skip portals the current camera doesn't see (inner-cam cull).
            if depth == 1 or rendered then
                local pts = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngles, plyFov, aspect)

                local visible, color, cumPts, ownsCum
                if depth == 1 then
                    visible = rendered
                    cumPts = pts
                    color = rendered and COLOR_RENDERED or COLOR_CULLED
                else
                    if parentPoly and #pts >= 6 then
                        cumPts = wp.IntersectConvexPolygons(pts, parentPoly)
                        ownsCum = true
                        -- Geometric overlap with the cumulative ancestor
                        -- footprint is the visibility test even at minArea==0
                        -- — a portal that doesn't overlap the ancestor stencil
                        -- chain isn't visible through it regardless of how
                        -- big its on-screen quad is.
                        visible = #cumPts >= 6 and wp.PolygonArea(cumPts) >= minArea
                    else
                        visible = false
                    end
                    color = visible and COLOR_CHILD_VISIBLE or COLOR_CHILD
                end

                if visible or showCulled then
                    surface.SetDrawColor(color)
                    local drawPts = pts
                    if visible and depth > 1 and clipOrange and cumPts then
                        drawPts = cumPts
                    end
                    drawScreenPolygon(drawPts)
                end

                if visible and depth + 1 <= maxDepth then
                    local exit = portal:GetExit()
                    if IsValid(exit) then
                        local innerOrigin = wp.TransformPortalPos(plyOrigin, portal, exit)
                        local innerAngles = wp.TransformPortalAngle(plyAngles, portal, exit)

                        local exitFwd = exit:GetForward()
                        local exitAngOffset = exit:GetExitAngOffset()
                        if exitAngOffset then
                            exitFwd:Rotate(exitAngOffset)
                        end
                        local exitOffset = exit:GetExitPosOffset()
                        if IsValid(exit:GetParent()) then
                            exitOffset:Rotate(exit:GetParent():GetAngles())
                        end
                        local exitPos = exit:GetPos() + exitOffset

                        drawPortalOverlay(innerOrigin, innerAngles, plyFov, aspect, portals,
                            cumPts, depth + 1, maxDepth, mode, exitPos, exitFwd)
                    end
                end

                if ownsCum and cumPts ~= pts then wp.ReleasePoly(cumPts) end
                wp.ReleasePoly(pts)
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
