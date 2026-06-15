-- Debug

CreateClientConVar("worldportals_debug", "0", true, false, "World Portals - Debug overlay (0=off, 1=clipped to visible, 2=rendered only, 3=all incl. culled)", 0, 3)

-- Toggle the renderer's per-render logging from the cvar (off => it skips that
-- work, so non-overlay users pay nothing). cl_render loads after us alphabetically,
-- so guard SetRecordRenders and let the callback sync once loaded.
local function syncRecord()
    if wp.SetRecordRenders then
        wp.SetRecordRenders(GetConVar("worldportals_debug"):GetInt() > 0)
    end
end
syncRecord()
cvars.AddChangeCallback("worldportals_debug", syncRecord, "WorldPortals_Debug_Sync")
-- Sync once after all files load so a persisted non-zero cvar takes effect at boot.
hook.Add("InitPostEntity", "WorldPortals_Debug_InitSync", function()
    syncRecord()
    hook.Remove("InitPostEntity", "WorldPortals_Debug_InitSync")
end)

local COLOR_RENDERED = Color(0, 255, 0, 220)
local COLOR_CULLED = Color(255, 60, 60, 220)
local COLOR_CHILD_VISIBLE = Color(255, 140, 0, 220)
local COLOR_CHILD_HIDDEN = Color(255, 220, 0, 220)

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

-- Reused across frames so the "show culled at d=1" mode doesn't allocate
-- a fresh set table every HUDPaint.
local renderedAtD1 = {}

hook.Add("HUDPaint", "WorldPortals_Debug", function()
    local mode = GetConVar("worldportals_debug"):GetInt()
    if mode <= 0 then return end

    local aspect = ScrW() / ScrH()
    local list, count = wp.GetFrameRenderedList()

    -- Pass 1: draw every rendered chain by projecting through the camera the
    -- renderer used (it already did the recursion/culls - we just visualise).
    -- Mode 1 = "clipped to visible": orange polygons drawn as the
    --          cumulative-ancestor-clipped shape (cumPoly) so they don't
    --          escape the green parent. Faithful "what the player sees
    --          through the stencil chain".
    -- Mode 2 = "rendered only": orange polygons drawn as the portal's
    --          full screen quad - escapes the green, shows where the
    --          render actually occupies in NDC. No yellow/red.
    -- Mode 3 = "all incl. culled": same as mode 2 plus yellow (overlap-
    --          culled at depth>1) and red (top-level shouldrender failed).
    local clipOrange = (mode == 1)

    surface.SetDrawColor(COLOR_RENDERED)
    local lastColor = COLOR_RENDERED
    for i = 1, count do
        local e = list[i]
        if e then
            local color = e.depth == 1 and COLOR_RENDERED or COLOR_CHILD_VISIBLE
            if color ~= lastColor then
                surface.SetDrawColor(color)
                lastColor = color
            end
            if clipOrange and e.depth > 1 and e.cumPoly and #e.cumPoly >= 6 then
                drawScreenPolygon(e.cumPoly)
            else
                local pts = wp.GetPortalScreenPolygon(e.portal, e.camOrigin, e.camAngle, e.fov, aspect)
                drawScreenPolygon(pts)
                wp.ReleasePoly(pts)
            end
        end
    end

    -- Yellow outlines for overlap-culled chains (mode 3 only) - would
    -- render geometrically but ancestor stencil hides them entirely.
    if mode == 3 then
        local culledList, culledCount = wp.GetFrameCulledList()
        if culledCount > 0 then
            surface.SetDrawColor(COLOR_CHILD_HIDDEN)
            for i = 1, culledCount do
                local e = culledList[i]
                if e then
                    local pts = wp.GetPortalScreenPolygon(e.portal, e.camOrigin, e.camAngle, e.fov, aspect)
                    drawScreenPolygon(pts)
                    wp.ReleasePoly(pts)
                end
            end
        end
    end

    -- Red outlines for top-level portals the renderer skipped (i.e.
    -- shouldrender returned false from the player view). Shown in all
    -- modes since these are useful at any debug level. Builds a set of
    -- rendered-at-d=1 portals and draws the complement; shouldrender
    -- for d=1 is implicit in "did the renderer log it?".
    for k in pairs(renderedAtD1) do renderedAtD1[k] = nil end
    for i = 1, count do
        local e = list[i]
        if e and e.depth == 1 then renderedAtD1[e.portal] = true end
    end
    surface.SetDrawColor(COLOR_CULLED)
    local camPos = EyePos()
    local camAng = EyeAngles()
    -- GetPortalScreenPolygon expects the *rendered* horizontal FOV (post
    -- aspect adjustment). Player:GetFOV() returns the 4:3 reference
    -- hfov, so widen via Hor+:
    --   vfov          = 2*atan(tan(hfov4_3/2) * 0.75)
    --   rendered_hfov = 2*atan(tan(vfov/2) * aspect)
    local hfov4_3 = LocalPlayer():GetFOV()
    local camFov = math.deg(2 * math.atan(math.tan(math.rad(hfov4_3) * 0.5) * 0.75 * aspect))
    for _, portal in ipairs(wp.portals) do
        if IsValid(portal) and not renderedAtD1[portal] then
            local pts = wp.GetPortalScreenPolygon(portal, camPos, camAng, camFov, aspect)
            drawScreenPolygon(pts)
            wp.ReleasePoly(pts)
        end
    end

    -- Render-count breakdown.
    local SHADOW = Color(0, 0, 0, 220)
    local x = 16
    local lineH = 22
    local total = wp.GetFramePortalRenderCount()
    local byDepth = wp.GetFramePortalRenderByDepth()
    local maxDepth = wp.GetRecurseDepth()

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

-- 3D structure overlay. The screen-polygon overlay above is flat; this draws each
-- portal's actual render geometry projected to screen so the recessed thick cavity is
-- legible - the 5 stencil faces (each a distinct colour, matching the RenderQuads
-- order), the open front rim, the GetPos wormhole anchor and the normal.
CreateClientConVar("worldportals_debug_3d", "0", true, false, "World Portals - Draw portal 3D render structure", 0, 1)

-- RenderQuads order (shared.lua): bottom, top, back, left, right (no front - it's open).
local FACE_COLORS = {
    Color(80, 120, 255),  -- bottom
    Color(0, 255, 255),   -- top
    Color(255, 120, 0),   -- back (recessed)
    Color(255, 0, 255),   -- left
    Color(255, 255, 0),   -- right
}
local C_BOUNDS = Color(0, 255, 0)
local C_FRONT = Color(255, 255, 255)
local C_ANCHOR = Color(255, 0, 0)
local C_OPENING = Color(0, 255, 0) -- GetPos wormhole/opening plane (x=0)

-- Project to screen and draw in HUDPaint so the overlay is always on top (like the
-- screen-polygon debug above), not depth-occluded by the shell. Skip a segment if
-- either end is behind the camera (ToScreen coords are meaningless there).
local function line3D(a, b, col)
    local sa, sb = a:ToScreen(), b:ToScreen()
    if not (sa.visible and sb.visible) then return end
    surface.SetDrawColor(col)
    surface.DrawLine(sa.x, sa.y, sb.x, sb.y)
end

local function quadEdges(a, b, c, d, col)
    line3D(a, b, col)
    line3D(b, c, col)
    line3D(c, d, col)
    line3D(d, a, col)
end

hook.Add("HUDPaint", "WorldPortals_Debug3D", function()
    if GetConVar("worldportals_debug_3d"):GetInt() <= 0 then return end

    for _, portal in ipairs(wp.portals) do
        local mn, mx = portal.RenderMin, portal.RenderMax
        if IsValid(portal) and mn and mx then
            local pos = portal:GetPos()
            local fwd, rt, up = portal:GetForward(), portal:GetRight(), portal:GetUp()

            -- The actual stencil faces, per-face colour, so the bar's face is identifiable.
            local quads = portal.RenderQuads
            if quads then
                for i, q in ipairs(quads) do
                    quadEdges(portal:LocalToWorld(q[1]), portal:LocalToWorld(q[2]),
                        portal:LocalToWorld(q[3]), portal:LocalToWorld(q[4]),
                        FACE_COLORS[i] or C_BOUNDS)
                end
            end

            -- Open front rim (at RenderMax.x) - the opening, no stencil face here.
            quadEdges(
                portal:LocalToWorld(Vector(mx.x, mn.y, mn.z)),
                portal:LocalToWorld(Vector(mx.x, mx.y, mn.z)),
                portal:LocalToWorld(Vector(mx.x, mx.y, mx.z)),
                portal:LocalToWorld(Vector(mx.x, mn.y, mx.z)),
                C_FRONT)

            -- GetPos opening plane (local x=0) - where the interior view is anchored,
            -- 5u IN FRONT of the recessed cavity front. The interior registers to THIS.
            quadEdges(
                portal:LocalToWorld(Vector(0, mn.y, mn.z)),
                portal:LocalToWorld(Vector(0, mx.y, mn.z)),
                portal:LocalToWorld(Vector(0, mx.y, mx.z)),
                portal:LocalToWorld(Vector(0, mn.y, mx.z)),
                C_OPENING)

            -- GetPos anchor cross + forward normal.
            line3D(pos - rt * 6, pos + rt * 6, C_ANCHOR)
            line3D(pos - up * 6, pos + up * 6, C_ANCHOR)
            line3D(pos, pos + fwd * 24, C_FRONT)
        end
    end
end)
