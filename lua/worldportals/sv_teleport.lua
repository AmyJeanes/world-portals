
-- Add message name to pool
util.AddNetworkString( "WorldPortals_TeleportAlert" )

-- Let player know that server has acknowledged and completed the teleport
function wp.AlertPlayerOnTeleport( ply, roll )
    net.Start( "WorldPortals_TeleportAlert" )
        net.WriteFloat(roll)
    net.Send( ply )
end