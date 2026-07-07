-- The map's 3D skybox (sky_camera) parameters, bridged from server to client.
-- sky_camera is a server-only point entity, and the engine exposes its data to the
-- client only in C++ (no Lua getter), so the server reads it and sends it across.
-- The void-sky reconstruction renders this skybox scene when a portal exit camera
-- lands out of bounds.

if SERVER then
    util.AddNetworkString( "WorldPortals_Sky3D" )
    util.AddNetworkString( "WorldPortals_RequestSky3D" )

    -- colorPrimary comes back as a "r g b a" string.
    ---@param s any GetInternalVariable's return is untyped
    local function parseColor( s )
        local p = string.Explode( " ", tostring( s ) )
        return tonumber( p[1] ) or 255, tonumber( p[2] ) or 255, tonumber( p[3] ) or 255
    end

    ---@param target Player?
    local function send( target )
        local cam = ents.FindByClass( "sky_camera" )[1]
        local valid = IsValid( cam )
        net.Start( "WorldPortals_Sky3D" )
            net.WriteBool( valid )
            if valid then
                net.WriteVector( cam:GetPos() )
                net.WriteFloat( cam:GetInternalVariable( "m_skyboxData.scale" ) or 16 )
                local fogEnable = cam:GetInternalVariable( "m_skyboxData.fog.enable" ) == true
                net.WriteBool( fogEnable )
                if fogEnable then
                    net.WriteFloat( tonumber( cam:GetInternalVariable( "m_skyboxData.fog.start" ) ) or 0 )
                    net.WriteFloat( tonumber( cam:GetInternalVariable( "m_skyboxData.fog.end" ) ) or 0 )
                    net.WriteFloat( tonumber( cam:GetInternalVariable( "m_skyboxData.fog.maxdensity" ) ) or 1 )
                    local r, g, b = parseColor( cam:GetInternalVariable( "m_skyboxData.fog.colorPrimary" ) )
                    net.WriteUInt( r, 8 ); net.WriteUInt( g, 8 ); net.WriteUInt( b, 8 )
                end
            end
        if target then net.Send( target ) else net.Broadcast() end
    end

    -- A client asks once it is ready to receive (covers the initial load and late joiners).
    net.Receive( "WorldPortals_RequestSky3D", function( _, ply ) send( ply ) end )
    hook.Add( "PostCleanupMap", "WorldPortals_Sky3D", function() send() end )
else
    net.Receive( "WorldPortals_Sky3D", function()
        if not net.ReadBool() then
            wp.sky3d = nil
            return
        end
        local sky = {
            origin = net.ReadVector(),
            scale = net.ReadFloat(),
        }
        if net.ReadBool() then
            sky.fog = {
                start = net.ReadFloat(),
                stop = net.ReadFloat(),
                maxdensity = net.ReadFloat(),
                color = Color( net.ReadUInt( 8 ), net.ReadUInt( 8 ), net.ReadUInt( 8 ) ),
            }
        end
        wp.sky3d = sky
    end )

    hook.Add( "InitPostEntity", "WorldPortals_Sky3D", function()
        net.Start( "WorldPortals_RequestSky3D" )
        net.SendToServer()
    end )
end
