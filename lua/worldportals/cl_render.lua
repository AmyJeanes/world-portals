
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
    
    local override, drawblack = hook.Call( "wp-shouldrender", GAMEMODE, portal, exitPortal, camOrigin )
    if override ~= nil then return override, drawblack end
    
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
    if not wp.drawing then
        local v=view or EMPTY
        wp.renderportals(v.origin or EyePos(), v.angles or EyeAngles(), v.width or ScrW(), v.height or ScrH(), v.fov or LocalPlayer():GetFOV())
    end
    wp.rendermode = true
    render.RealRenderView(view)
    wp.rendermode = false
end

render.RenderView = WorldPortals_RenderView
hook.Add("InitPostEntity", "WorldPortals_RenderView", function()
    render.RenderView = WorldPortals_RenderView
end)


function wp.renderportals( plyOrigin, plyAngle, width, height, fov )
    if ( wp.drawing ) then return end
    wp.portals = ents.FindByClass( "linked_portal_door" )
    if ( not wp.portals ) then return end

    -- Disable phys gun glow and beam
    local oldWepColor = LocalPlayer():GetWeaponColor()
    LocalPlayer():SetWeaponColor( Vector( 0, 0, 0 ) )

    for _, portal in pairs( wp.portals ) do
        local exitPortal = portal:GetExit()
        local falseWorld = portal:GetFalseWorld()
        local texture = portal:GetTexture()
        if wp.shouldrender(portal, plyOrigin, plyAngle, fov) and texture then
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

                    render.PushCustomClipPlane( exit_forward, exit_forward:Dot( exit_pos - exit_forward * 0.5 ) )

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

                    wp.drawing = true
                    wp.drawingent = portal
                        render.RenderView( {
                            x = 0,
                            y = 0,
                            w = width,
                            h = height,
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
                    wp.drawing = false
                    wp.drawingent = nil

                    render.PopCustomClipPlane()
                    render.EnableClipping( oldClip )
                render.PopRenderTarget()

                hook.Call( "wp-postrender", GAMEMODE, portal, exitPortal, plyOrigin )
            elseif falseWorld then
                wp.renderfalseworld(texture, portal, plyOrigin, plyAngle, width, height, fov )
            end
        end
    end
    LocalPlayer():SetWeaponColor( oldWepColor )
end

hook.Add( "RenderScene", "WorldPortals_Render", function( plyOrigin, plyAngle, fov )
    wp.renderportals(plyOrigin, plyAngle, ScrW(), ScrH(), fov)
end )

--[[ causes player to see themselves in first person sometimes (particularly in multiplayer)
hook.Add( "ShouldDrawLocalPlayer", "WorldPortals_Render", function()
    if wp.drawing then
        return true
    end
end )
]]--

hook.Add( "PreDrawHalos", "WorldPortals_Render", function()
    if wp.drawing then return false end
end )
