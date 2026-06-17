-- Debug

CreateClientConVar("worldportals_debug", "0", true, false, "World Portals - Debug overlay (0=off, 1=clipped to visible, 2=rendered only, 3=all incl. culled)", 0, 3)

-- Toggle the renderer's per-render logging from the cvar (off => it skips that
-- work, so non-overlay users pay nothing). cl_render loads after us alphabetically,
-- so guard SetRecordRenders and let the callback sync once loaded.
local function syncRecord()
    if not wp.SetRecordRenders then return end
    local on = GetConVar("worldportals_debug"):GetInt() > 0
    local cv3d = GetConVar("worldportals_debug_3d")
    wp.SetRecordRenders(on or (cv3d ~= nil and cv3d:GetInt() > 0))
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

-- Per-eye render-decision overlay. The screen-polygon overlay above runs in HUDPaint - one
-- mono pass that doesn't line up with the stereoscopy/VR eye sub-viewports. This draws in the
-- world pass instead (PostDrawTranslucentRenderables fires once per eye) and entirely in 3D -
-- no ToScreen, which measures against the eye RT and drifts. So it lands correctly in each eye
-- and in mono. Each portal is boxed in its render-decision colour, with the recursion depth it
-- reached shown as a stack of ticks above it.
CreateClientConVar("worldportals_debug_3d", "0", true, false, "World Portals - Per-eye 3D render-decision overlay", 0, 1)
cvars.AddChangeCallback("worldportals_debug_3d", syncRecord, "WorldPortals_Debug3D_Sync")

local C3_DIRECT = Color(0, 255, 0)     -- rendered at depth 1 (direct player view)
local C3_CHILD  = Color(255, 140, 0)   -- rendered only through another portal (depth > 1)
local C3_CULLED = Color(255, 220, 0)   -- overlap-culled behind an ancestor stencil chain
local C3_NOREND = Color(255, 40, 40)   -- shouldrender failed - not rendered this frame
local C3_REF    = Color(120, 120, 120) -- GetPos anchor + normal, neutral reference

-- Per-portal status for the current frame, rebuilt from the renderer's rendered/culled lists.
-- Tables reused across frames to avoid per-frame allocation.
local stMaxDepth, stAtD1, stCulled = {}, {}, {}
local function buildStatus()
    for k in pairs(stMaxDepth) do stMaxDepth[k] = nil end
    for k in pairs(stAtD1) do stAtD1[k] = nil end
    for k in pairs(stCulled) do stCulled[k] = nil end
    local rl, rc = wp.GetFrameRenderedList()
    for i = 1, rc do
        local e = rl[i]
        if e and IsValid(e.portal) then
            local p = e.portal
            if not stMaxDepth[p] or e.depth > stMaxDepth[p] then stMaxDepth[p] = e.depth end
            if e.depth == 1 then stAtD1[p] = true end
        end
    end
    local cl, cc = wp.GetFrameCulledList()
    for i = 1, cc do
        local e = cl[i]
        if e and IsValid(e.portal) then stCulled[e.portal] = true end
    end
end

local function statusColor(p)
    if stAtD1[p] then return C3_DIRECT end
    if (stMaxDepth[p] or 0) > 1 then return C3_CHILD end
    if stCulled[p] then return C3_CULLED end
    return C3_NOREND
end

hook.Add("PostDrawTranslucentRenderables", "WorldPortals_Debug3D", function(_, bSkybox)
    -- Skip the skybox sub-pass and the portal RT renders (wp.drawing) so the overlay draws
    -- once per real eye, on top of the world.
    if bSkybox or wp.drawing then return end
    if GetConVar("worldportals_debug_3d"):GetInt() <= 0 then return end

    buildStatus()

    cam.IgnoreZ(true)
    for _, portal in ipairs(wp.portals) do
        local mn, mx = portal.RenderMin, portal.RenderMax
        if IsValid(portal) and mn and mx then
            local col = statusColor(portal)
            render.DrawWireframeBox(portal:GetPos(), portal:GetAngles(), mn, mx, col, true)

            local pos = portal:GetPos()
            local rt, up, fwd = portal:GetRight(), portal:GetUp(), portal:GetForward()
            render.DrawLine(pos - rt * 6, pos + rt * 6, C3_REF, true)
            render.DrawLine(pos - up * 6, pos + up * 6, C3_REF, true)
            render.DrawLine(pos, pos + fwd * 24, C3_REF, true)

            -- One tick per recursion level this portal's chain reached.
            local depth = stMaxDepth[portal] or 0
            local top = pos + up * (portal:GetHeight() * 0.5 + 6)
            for i = 1, depth do
                local base = top + up * (i * 5)
                render.DrawLine(base - rt * 10, base + rt * 10, col, true)
            end
        end
    end
    cam.IgnoreZ(false)
end)
