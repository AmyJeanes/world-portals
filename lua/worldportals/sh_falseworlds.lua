wp.falseworlds = wp.falseworlds or {}

function wp.addfalseworld( T )
    if not T.ID then
        error( "wp.addfalseworld: missing T.ID" )
    end
    wp.falseworlds[T.ID] = table.Copy( T )
end

if SERVER then return end

function wp.createfalseworld( portal, plyOrigin, plyAngle, width, height, fov )
    local fwname = portal:GetFalseWorld()
    local falseworld = wp.falseworlds[fwname]

    if not falseworld then
        ErrorNoHalt( "wp.createfalseworld: no registered false world '" .. tostring( fwname ) .. "'\n" )
        return
    end

    local fw_origin = falseworld.origin --[[@as Vector?]]
    local origin = Vector()
    if fw_origin then
        origin = -fw_origin
    end
    local baselight = falseworld.baselight or Vector()

    cam.Start3D( plyOrigin + origin, plyAngle, fov, 0, 0, width, height )
        local exit_forward = portal:GetForward() * -1

        local oldEC = render.EnableClipping( true )

        local function DrawPart( rawpart )
            local skybox = rawpart.skybox
            local model = rawpart.model
            local scale = rawpart.scale
            local color = rawpart.color or Vector( 1, 1, 1 )
            local pos = rawpart.pos or Vector()
            local angle = rawpart.angle or Angle()
            local rendergroup = rawpart.rendergroup
            local part = ClientsideModel( model, rendergroup )
            if not IsValid( part ) then return end
            part:SetNoDraw( true )
            if skybox then
                part:SetPos( plyOrigin + origin )
            else
                part:SetPos( pos )
            end
            part:SetAngles( angle )
            render.SetColorModulation( color.x, color.y, color.z )
            if not skybox then
                render.ResetModelLighting( baselight.x, baselight.y, baselight.z )
                render.SetLocalModelLights( falseworld.lights )
            end
            if scale then
                local mat = Matrix()
                mat:Scale( scale )
                part:EnableMatrix( "RenderMultiply", mat )
            end
            if skybox then
                render.OverrideDepthEnable( true, false )
                part:DrawModel()
                render.OverrideDepthEnable( false, false )
            else
                part:DrawModel()
            end
            -- clientside entity MUST be removed after drawing or they stack up every frame
            part:Remove()
        end

        if falseworld.skybox then
            local skybox = falseworld.skybox
            skybox.skybox = true
            DrawPart( skybox )
        end

        render.PushCustomClipPlane( exit_forward, exit_forward:Dot( origin - exit_forward * 0.5 ) )
            for _, v in pairs( falseworld.models ) do
                DrawPart( v )
            end
        render.PopCustomClipPlane()

        render.EnableClipping( oldEC )
    cam.End3D()
end

function wp.renderfalseworld( texture, portal, plyOrigin, plyAngle, width, height, fov )
    hook.Call( "wp-prerender", GAMEMODE, portal, nil, plyOrigin )
    render.PushRenderTarget( texture )
        local oldW, oldH = ScrW(), ScrH()
        render.Clear( 0, 0, 0, 0, true, true )
        render.SetViewPort( 0, 0, ScrW(), ScrH() )

        local oldFog = render.GetFogMode()
        render.SuppressEngineLighting( true )
        render.FogMode( MATERIAL_FOG_NONE )

        local plyOriginLocal = plyOrigin - portal:GetPos()
        wp.createfalseworld( portal, plyOriginLocal, plyAngle, width, height, fov )

        render.OverrideDepthEnable( false, false )
        render.FogMode( oldFog )
        render.SuppressEngineLighting( false )

        render.SetViewPort( 0, 0, oldW, oldH )
    render.PopRenderTarget()
    hook.Call( "wp-postrender", GAMEMODE, portal, nil, plyOrigin )
end
