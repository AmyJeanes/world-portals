
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

    if not IsValid( exitPortal ) and not falseWorld then return false end
    
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


-- Project a portal's visible-face quad to NDC of an arbitrary camera. Returns
-- the screen-space AABB (clamped to the camera's [-1,1] frustum) or nil if the
-- portal sits entirely behind the camera or off-frustum.
local function projectPortalToCameraNDC(portal, camPos, camAng, camFov, aspect)
    local pos = portal:GetPos()
    local fwd = portal:GetForward()
    local right = portal:GetRight()
    local up = portal:GetUp()
    local hw = portal:GetWidth() * 0.5
    local hh = portal:GetHeight() * 0.5
    -- portal's visible face sits at pos - fwd*5 (matches DrawQuadEasy in cl_init.lua)
    local center = pos - fwd * 5
    local corners = {
        center + right * hw + up * hh,
        center - right * hw + up * hh,
        center - right * hw - up * hh,
        center + right * hw - up * hh,
    }

    local f = camAng:Forward()
    local r = camAng:Right()
    local u = camAng:Up()

    local tanHalfH = math.tan(camFov * math.pi / 360)
    local tanHalfV = tanHalfH / aspect

    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local anyForward = false
    for _, c in ipairs(corners) do
        local rel = c - camPos
        local d = rel:Dot(f)
        if d > 0.1 then
            anyForward = true
            local x = rel:Dot(r) / (d * tanHalfH)
            local y = rel:Dot(u) / (d * tanHalfV)
            if x < minX then minX = x end
            if x > maxX then maxX = x end
            if y < minY then minY = y end
            if y > maxY then maxY = y end
        end
    end
    if not anyForward then return nil end

    -- clamp to inner-camera visible NDC
    if minX < -1 then minX = -1 end
    if minY < -1 then minY = -1 end
    if maxX >  1 then maxX =  1 end
    if maxY >  1 then maxY =  1 end
    if minX >= maxX or minY >= maxY then return nil end

    return minX, minY, maxX, maxY
end

-- Map an inner-camera NDC AABB through an outer player-screen AABB. With the
-- outer rect set to full NDC this is the identity transformation, so the same
-- code works at every depth.
local function mapInnerThroughOuter(iMinX, iMinY, iMaxX, iMaxY, oMinX, oMinY, oMaxX, oMaxY)
    local sx = (oMaxX - oMinX) * 0.5
    local sy = (oMaxY - oMinY) * 0.5
    return oMinX + (iMinX + 1) * sx,
           oMinY + (iMinY + 1) * sy,
           oMinX + (iMaxX + 1) * sx,
           oMinY + (iMaxY + 1) * sy
end

function wp.renderportals( plyOrigin, plyAngle, width, height, fov, depth, playerScreenMinX, playerScreenMinY, playerScreenMaxX, playerScreenMaxY )
    if ( wp.drawing ) then return end

    depth = ClampRecurseDepth(depth)
    if depth > recurseDepth then return end

    -- top-level callers pass nil; default to the player's full screen
    if not playerScreenMinX then
        playerScreenMinX, playerScreenMinY, playerScreenMaxX, playerScreenMaxY = -1, -1, 1, 1
    end

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

        local portalScreenMinX, portalScreenMinY, portalScreenMaxX, portalScreenMaxY
        if wp.shouldrender(portal, plyOrigin, plyAngle, fov) and texture then
            -- Layer 2 culling: project this portal onto the inner-camera frustum,
            -- then map through the chain of outer screen rects to see how much of
            -- the player's actual screen this portal would occupy. Cull if none.
            local iMinX, iMinY, iMaxX, iMaxY = projectPortalToCameraNDC(portal, plyOrigin, plyAngle, fov, aspect)
            if iMinX then
                portalScreenMinX, portalScreenMinY, portalScreenMaxX, portalScreenMaxY =
                    mapInnerThroughOuter(iMinX, iMinY, iMaxX, iMaxY,
                        playerScreenMinX, playerScreenMinY, playerScreenMaxX, playerScreenMaxY)
            end
        end

        if portalScreenMinX and texture then
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
                        wp.renderportals(camOrigin, camAngle, width, height, fov, childDepth,
                            portalScreenMinX, portalScreenMinY, portalScreenMaxX, portalScreenMaxY)
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
            elseif falseWorld then
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
