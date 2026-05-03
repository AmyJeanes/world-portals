
-- Setup variables
wp.matBlack = Material( "wp/black" )
wp.matTrans = Material( "wp/trans" )
wp.matInvis = Material( "wp/invis" )
wp.matView = CreateMaterial(
    "UnlitGeneric",
    "GMODScreenspace",
    {
        [ "$basetexturetransform" ] = "center .5 .5 scale -1 -1 rotate 0 translate 0 0",
        [ "$texturealpha" ] = "0",
        [ "$vertexalpha" ] = "1",
    }
)
wp.matView2 = CreateMaterial("WorldPortals", "Core_DX90", {["$basetexture"] = wp.matBlack:GetName(), ["$model"] = "1"})

wp.portals = {}
wp.drawing = true --default portals to not draw
wp.rendermode = false

CreateClientConVar("worldportals_resolution_percentage", "100", true, false, "World Portals - Render resolution percentage for portals", 1, 100)
CreateClientConVar("worldportals_recurse_depth", "1", true, false, "World Portals - Maximum portal recursion depth", 1, 9)

local resolutionScale = 1
local recurseDepth = 1

local function ClampPortalResolution(value)
    return math.Clamp((tonumber(value) or 100) / 100, 0.01, 1)
end

local function ClampRecurseDepth(value)
    return math.Clamp(math.floor(tonumber(value) or 1), 1, 9)
end

local function UpdatePortalResolution()
    resolutionScale = ClampPortalResolution(GetConVar("worldportals_resolution_percentage"):GetString())
end

local function UpdateRecurseDepth()
    recurseDepth = ClampRecurseDepth(GetConVar("worldportals_recurse_depth"):GetString())
end

UpdatePortalResolution()
UpdateRecurseDepth()

cvars.AddChangeCallback("worldportals_resolution_percentage", function(convarName, oldValue, newValue)
    resolutionScale = ClampPortalResolution(newValue)
end)

cvars.AddChangeCallback("worldportals_recurse_depth", function(convarName, oldValue, newValue)
    recurseDepth = ClampRecurseDepth(newValue)
end)

function wp.GetRecurseDepth()
    return recurseDepth
end

function wp.GetPortalRenderDepth()
    return wp.renderdepth or wp.drawingdepth or 0
end

function wp.IsRenderingPortalView()
    return wp.drawing or (wp.renderdepth or 0) > 1
end

function wp.GetPortalRenderSize(width, height)
    width = width or ScrW()
    height = height or ScrH()

    return math.max(1, math.floor(width * resolutionScale)), math.max(1, math.floor(height * resolutionScale))
end

function wp.GetPortalTexture(portal, width, height, depth)
    depth = ClampRecurseDepth(depth)
    width, height = wp.GetPortalRenderSize(width, height)

    portal.WPTextures = portal.WPTextures or {}

    local textureKey = depth .. ":" .. width .. ":" .. height
    local texture = portal.WPTextures[textureKey]
    if texture then return texture, width, height end

    texture = GetRenderTarget("portal:" .. portal:EntIndex() .. ":" .. width .. ":" .. height .. ":d" .. depth, width, height)
    portal.WPTextures[textureKey] = texture

    return texture, width, height
end

function wp.GetPortalDrawTexture(portal)
    local depth = wp.drawtexturedepth or 1
    local texture, width, height = wp.GetPortalTexture(portal, wp.viewwidth or ScrW(), wp.viewheight or ScrH(), depth)
    return texture, width, height, depth
end

-- Start drawing the portals
-- This prevents the game from crashing when loaded for the first time
hook.Add( "PostRender", "WorldPortals_StartRender", function()
    wp.drawing = false
    hook.Remove( "PostRender", "WorldPortals_StartRender" )
end )

function wp.shouldrender( portal, camOrigin, camAngle, camFOV )
    if not camOrigin then camOrigin = EyePos() end
    if not camAngle then camAngle = EyeAngles() end
    if not camFOV then camFOV = LocalPlayer():GetFOV() end
    local exitPortal = portal:GetExit()
    local falseWorld = portal:GetFalseWorld()
    local distance = camOrigin:Distance( portal:GetPos() )
    local disappearDist = portal:GetDisappearDist()

    if not IsValid( exitPortal ) and not (falseWorld and falseWorld ~= "") then return false end
    
    local override, drawblack = hook.Call( "wp-shouldrender", GAMEMODE, portal, exitPortal, camOrigin, camAngle, camFOV, wp.GetPortalRenderDepth() )
    if override ~= nil then return override, drawblack end

    if not portal:GetOpen() then return false end

    if portal:IsDormant() then return false end
    
    if not (disappearDist <= 0) and distance > disappearDist then return false end
    
    --don't render if the view is behind the portal
    local portalPos
    local thickness = portal:GetThickness()
    if thickness > 0 then
        portalPos = portal:LocalToWorld(Vector(-thickness,0,0))
    else
        portalPos = portal:GetPos()
    end
    local behind = wp.IsBehind( camOrigin, portalPos, portal:GetForward() )
    if behind then return false end
    local lookingAt = wp.IsLookingAt( portal, portalPos, camOrigin, camAngle, camFOV )
    if not lookingAt then return false end

    return true
end


if not render.RealRenderView then
    render.RealRenderView = render.RenderView
end

local EMPTY={}
function WorldPortals_RenderView(view)
    local v=view or EMPTY
    local origin = v.origin or EyePos()
    local angles = v.angles or EyeAngles()
    local width = v.width or v.w or ScrW()
    local height = v.height or v.h or ScrH()
    local fov = v.fov or LocalPlayer():GetFOV()

    if not wp.drawing then
        wp.renderportals(origin, angles, width, height, fov, 1)
    end

    local oldRenderMode = wp.rendermode
    local oldViewOrigin = wp.vieworigin
    local oldViewAngle = wp.viewangle
    local oldViewFOV = wp.viewfov
    local oldViewWidth = wp.viewwidth
    local oldViewHeight = wp.viewheight

    wp.rendermode = true
    wp.vieworigin = origin
    wp.viewangle = angles
    wp.viewfov = fov
    wp.viewwidth = width
    wp.viewheight = height
    render.RealRenderView(view)
    wp.rendermode = oldRenderMode
    wp.vieworigin = oldViewOrigin
    wp.viewangle = oldViewAngle
    wp.viewfov = oldViewFOV
    wp.viewwidth = oldViewWidth
    wp.viewheight = oldViewHeight
end

render.RenderView = WorldPortals_RenderView
hook.Add("InitPostEntity", "WorldPortals_RenderView", function()
    render.RenderView = WorldPortals_RenderView
end)


local function getPortalCorners(portal)
    local pos = portal:GetPos()
    local fwd = portal:GetForward()
    local right = portal:GetRight()
    local up = portal:GetUp()
    local hw = portal:GetWidth() * 0.5
    local hh = portal:GetHeight() * 0.5
    -- visible face sits at pos - fwd*5 (matches DrawQuadEasy in entity cl_init.lua)
    local center = pos - fwd * 5
    return
        center + right * hw + up * hh,
        center - right * hw + up * hh,
        center - right * hw - up * hh,
        center + right * hw - up * hh
end

local NEAR_EPS = 1

-- Sutherland-Hodgman clip of a world-space quad against the half-space in
-- front of the camera (signed distance along camFwd > NEAR_EPS). Returns
-- 0..5 world-space points.
local function clipQuadNearPlane(c1, c2, c3, c4, camPos, camFwd)
    local pts = {}
    local function clipEdge(a, b)
        local da = (a - camPos):Dot(camFwd) - NEAR_EPS
        local db = (b - camPos):Dot(camFwd) - NEAR_EPS
        if da > 0 then
            pts[#pts + 1] = a
            if db <= 0 then
                pts[#pts + 1] = a + (b - a) * (da / (da - db))
            end
        elseif db > 0 then
            pts[#pts + 1] = a + (b - a) * (da / (da - db))
        end
    end
    clipEdge(c1, c2)
    clipEdge(c2, c3)
    clipEdge(c3, c4)
    clipEdge(c4, c1)
    return pts
end

-- Project a portal's visible-face quad through an arbitrary camera into
-- player-screen pixel space, applying near-plane clipping and Hor+ FOV
-- scaling. Inner cameras render to screen-aligned RTs sampled at screen
-- UV, so a feature at inner-NDC (u, v) lands at player-screen NDC (u, v)
-- — the same conversion works at top level (player camera) and at every
-- recursion depth. Returns a list of 0..5 {x, y} screen-pixel points.
function wp.GetPortalScreenPolygon(portal, camPos, camAng, camFov, aspect)
    local fwd = camAng:Forward()
    local right = camAng:Right()
    local up = camAng:Up()
    -- Hor+ scaling: GetFOV() is the horizontal FOV at 4:3 reference; the
    -- engine derives vfov from that and widens hfov for wider aspects.
    local tanHalfV = math.tan(camFov * math.pi / 360) * 0.75
    local tanHalfH = tanHalfV * aspect

    local c1, c2, c3, c4 = getPortalCorners(portal)
    local clipped = clipQuadNearPlane(c1, c2, c3, c4, camPos, fwd)

    local sw, sh = ScrW(), ScrH()
    local out = {}
    for _, v in ipairs(clipped) do
        local rel = v - camPos
        local d = rel:Dot(fwd)
        local ndcX = rel:Dot(right) / (d * tanHalfH)
        local ndcY = rel:Dot(up)    / (d * tanHalfV)
        out[#out + 1] = {
            x = (ndcX + 1) * 0.5 * sw,
            y = (1 - ndcY) * 0.5 * sh,
        }
    end
    return out
end

local function projectPolyOntoAxis(pts, ax, ay)
    local mn, mx = math.huge, -math.huge
    for _, p in ipairs(pts) do
        local d = p.x * ax + p.y * ay
        if d < mn then mn = d end
        if d > mx then mx = d end
    end
    return mn, mx
end

-- Test each edge of polygon `axes` as a candidate separating axis: project
-- both polygons onto the edge's normal and report disjoint ranges.
local function hasSeparatingEdge(axes, other)
    local function testEdge(p1, p2)
        local ax = -(p2.y - p1.y)
        local ay = p2.x - p1.x
        local aMin, aMax = projectPolyOntoAxis(axes, ax, ay)
        local bMin, bMax = projectPolyOntoAxis(other, ax, ay)
        return aMax < bMin or bMax < aMin
    end

    local first, prev
    for _, p in ipairs(axes) do
        if prev then
            if testEdge(prev, p) then return true end
        else
            first = p
        end
        prev = p
    end
    if first and prev and prev ~= first then
        if testEdge(prev, first) then return true end
    end
    return false
end

-- Convex-polygon intersection via Separating Axis Theorem. Both inputs are
-- assumed convex (which our near-plane-clipped quads always are).
function wp.PolygonsIntersectSAT(a, b)
    if #a < 3 or #b < 3 then return false end
    if hasSeparatingEdge(a, b) then return false end
    if hasSeparatingEdge(b, a) then return false end
    return true
end

local function polygonSignedArea(poly)
    if #poly < 3 then return 0 end
    local sum = 0
    local first, prev
    for _, p in ipairs(poly) do
        if prev then
            sum = sum + (prev.x * p.y - p.x * prev.y)
        else
            first = p
        end
        prev = p
    end
    if first and prev and prev ~= first then
        sum = sum + (prev.x * first.y - first.x * prev.y)
    end
    return (sum or 0) * 0.5
end

local function reversePolygon(poly)
    local rev = {}
    for i = #poly, 1, -1 do
        rev[#rev + 1] = poly[i]
    end
    return rev
end

-- Sutherland-Hodgman: clip `subject` against directed edge (e1 → e2),
-- keeping vertices on the half-plane the right normal points into.
-- Caller is responsible for ensuring the clip edge winding gives a
-- right-normal-inward orientation.
local function clipPolygonAgainstEdge(subject, e1, e2)
    if #subject == 0 then return {} end

    local nx = e2.y - e1.y
    local ny = -(e2.x - e1.x)

    local function dist(p)
        return (p.x - e1.x) * nx + (p.y - e1.y) * ny
    end

    local function intersect(s, sd, e, ed)
        local t = sd / (sd - ed)
        return { x = s.x + (e.x - s.x) * t, y = s.y + (e.y - s.y) * t }
    end

    local function processEdge(out, s, sd, e, ed)
        if ed >= 0 then
            if sd < 0 then
                out[#out + 1] = intersect(s, sd, e, ed)
            end
            out[#out + 1] = e
        elseif sd >= 0 then
            out[#out + 1] = intersect(s, sd, e, ed)
        end
    end

    local out = {}
    local first, firstD, prev, prevD
    for _, curr in ipairs(subject) do
        local currD = dist(curr)
        if prev then
            processEdge(out, prev, prevD, curr, currD)
        else
            first = curr
            firstD = currD
        end
        prev = curr
        prevD = currD
    end
    if first and prev and prev ~= first then
        processEdge(out, prev, prevD, first, firstD)
    end
    return out
end

-- Convex-polygon intersection via iterated Sutherland-Hodgman: clip the
-- subject polygon against every edge of the convex clip polygon. Returns
-- the (possibly empty) intersection polygon. Polygons projected through
-- portal-recursed cameras can come out with either winding (paired-portal
-- basis flips), so canonicalize the clip to the right-normal-inward
-- orientation that clipPolygonAgainstEdge expects.
function wp.IntersectConvexPolygons(subject, clip)
    if #subject == 0 or #clip < 3 then return {} end

    local area = polygonSignedArea(clip)
    if area == 0 then return {} end
    if area > 0 then clip = reversePolygon(clip) end

    local result = subject
    local first, prev
    for _, e in ipairs(clip) do
        if prev then
            result = clipPolygonAgainstEdge(result, prev, e)
            if #result == 0 then return result end
        else
            first = e
        end
        prev = e
    end
    if first and prev and prev ~= first then
        result = clipPolygonAgainstEdge(result, prev, first)
    end
    return result
end

local framePortalRenderCount = 0
local framePortalRenderByDepth = {}

function wp.GetFramePortalRenderCount()
    return framePortalRenderCount
end

function wp.GetFramePortalRenderByDepth()
    return framePortalRenderByDepth
end

hook.Add("PreRender", "WorldPortals_ResetRenderCount", function()
    framePortalRenderCount = 0
    for d in pairs(framePortalRenderByDepth) do
        framePortalRenderByDepth[d] = 0
    end
end)

function wp.renderportals( plyOrigin, plyAngle, width, height, fov, depth, parentPoly )
    if ( wp.drawing ) then return end

    depth = ClampRecurseDepth(depth)
    if depth > recurseDepth then return end

    local oldRenderDepth = wp.renderdepth
    wp.renderdepth = depth

    if depth == 1 or not wp.portals then
        wp.portals = ents.FindByClass( "linked_portal_door" )
    end

    local portals = wp.portals
    if ( not portals ) then
        wp.renderdepth = oldRenderDepth
        return
    end

    local renderWidth, renderHeight = wp.GetPortalRenderSize(width, height)
    local aspect = width / height

    -- Disable phys gun glow and beam
    local oldWepColor = LocalPlayer():GetWeaponColor()
    LocalPlayer():SetWeaponColor( Vector( 0, 0, 0 ) )

    for _, portal in pairs( portals ) do
        local exitPortal = portal:GetExit()
        local falseWorld = portal:GetFalseWorld()
        local texture = wp.GetPortalTexture(portal, width, height, depth)
        if depth == 1 then
            portal:SetTexture( texture )
        end

        local poly
        if wp.shouldrender(portal, plyOrigin, plyAngle, fov) and texture then
            poly = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngle, fov, aspect)
            -- Stencil cull: at depth > 1 the portal must intersect its
            -- immediate parent's screen polygon, otherwise the parent's
            -- stencil masks it out entirely.
            if depth > 1 and parentPoly and not wp.PolygonsIntersectSAT(parentPoly, poly) then
                poly = nil
            elseif #poly < 3 then
                poly = nil
            end
        end

        if poly and texture then
            framePortalRenderCount = framePortalRenderCount + 1
            framePortalRenderByDepth[depth] = (framePortalRenderByDepth[depth] or 0) + 1
            if IsValid(exitPortal) then
                hook.Call( "wp-prerender", GAMEMODE, portal, exitPortal, plyOrigin )
                render.PushRenderTarget( texture )
                    render.Clear( 0, 0, 0, 255, true, true )

                    local oldClip = render.EnableClipping( true )

                    local exit_forward = exitPortal:GetForward()
                    local exit_ang_offset = exitPortal:GetExitAngOffset()
                    if exit_ang_offset then
                        exit_forward:Rotate(exit_ang_offset)
                    end

                    local offset = exitPortal:GetExitPosOffset()

                    if IsValid(exitPortal:GetParent()) then
                        offset:Rotate(exitPortal:GetParent():GetAngles())
                    end

                    local exit_pos = exitPortal:GetPos() + offset

                    local camOrigin = wp.TransformPortalPos( plyOrigin, portal, exitPortal )
                    local camAngle = wp.TransformPortalAngle( plyAngle, portal, exitPortal )

                    local zfar = portal:GetZFar()
                    if zfar > 0 then
                        local relative_pos = plyOrigin - portal:GetPos()
                        local portal_to_exit_dist = exitPortal:GetPos():Distance(portal:GetPos())
                        local adjusted_zfar = portal_to_exit_dist + relative_pos:Dot(portal:GetForward())
                        zfar = math.max(adjusted_zfar, zfar)
                    else
                        zfar = nil
                    end

                    local childDepth = depth + 1
                    local drawPortalsInView = childDepth <= recurseDepth
                    if drawPortalsInView then
                        -- Pass the cumulative ancestor footprint so deeper
                        -- portals are culled against every ancestor's stencil,
                        -- not just the immediate parent's.
                        local childParent = poly
                        if depth > 1 and parentPoly then
                            childParent = wp.IntersectConvexPolygons(poly, parentPoly)
                        end
                        wp.renderportals(camOrigin, camAngle, width, height, fov, childDepth, childParent)
                    end

                    local oldDrawing = wp.drawing
                    local oldDrawingEnt = wp.drawingent
                    local oldDrawingDepth = wp.drawingdepth
                    local oldDrawTextureDepth = wp.drawtexturedepth
                    local oldDrawPortalsInView = wp.drawportalsinview

                    wp.drawing = true
                    wp.drawingent = portal
                    wp.drawingdepth = depth
                    wp.drawtexturedepth = childDepth
                    wp.drawportalsinview = drawPortalsInView
                    render.PushCustomClipPlane( exit_forward, exit_forward:Dot( exit_pos - exit_forward * 0.5 ) )
                        render.RenderView( {
                            x = 0,
                            y = 0,
                            w = renderWidth,
                            h = renderHeight,
                            fov = fov,
                            origin = camOrigin,
                            angles = camAngle,
                            dopostprocess = false,
                            drawhud = false,
                            drawmonitors = false,
                            drawviewmodel = false,
                            bloomtone = true,
                            viewid = 1, -- VIEW_3DSKY
                            zfar = zfar
                        } )
                    wp.drawing = oldDrawing
                    wp.drawingent = oldDrawingEnt
                    wp.drawingdepth = oldDrawingDepth
                    wp.drawtexturedepth = oldDrawTextureDepth
                    wp.drawportalsinview = oldDrawPortalsInView

                    render.PopCustomClipPlane()
                    render.EnableClipping( oldClip )
                render.PopRenderTarget()

                hook.Call( "wp-postrender", GAMEMODE, portal, exitPortal, plyOrigin )
            elseif falseWorld and falseWorld ~= "" then
                wp.renderfalseworld(texture, portal, plyOrigin, plyAngle, renderWidth, renderHeight, fov )
            end
        end
    end
    LocalPlayer():SetWeaponColor( oldWepColor )
    wp.renderdepth = oldRenderDepth
end

hook.Add( "RenderScene", "WorldPortals_Render", function( plyOrigin, plyAngle, fov )
    wp.renderportals(plyOrigin, plyAngle, ScrW(), ScrH(), fov)
end )

hook.Add( "ShouldDrawLocalPlayer", "WorldPortals_Render", function()
    if wp.drawing then
        return true
    end
end )

hook.Add( "PreDrawHalos", "WorldPortals_Render", function()
    if wp.drawing then return false end
end )
