
-- Client side tetleportation prediction
-- This is somewhat specific to rooftops_lost and can be improved a lot

--should really create a custom move type based off of the source engine move type in order
--to have properly predicted teleportation

--[[
local last_tele = 0

hook.Add( "Tick", "WorldPortals_Teleportation", function()

    hook.Remove( "CalcView", "WorldPortals_PredictTeleView" )

    local ply = LocalPlayer()

    for _, portal in pairs( wp.portals ) do

        local distance = ply:GetPos():Distance( portal:GetPos() )

        if distance < 150 then
            print("asdf")

            local mins = portal:GetPos() + Vector( -32, -portal:GetWidth() /2, -portal:GetHeight() /2 ) --would normally be 0
            local maxs = portal:GetPos() + Vector( 32, portal:GetWidth() /2, portal:GetHeight() /2) --would normally be 10

            local ply_pos = LocalPlayer():GetPos() + Vector( 0, 0, 36)

            if ply_pos:WithinAABox( mins, maxs ) then
                --print("asddd1", ent, LocalPlayer() )
                --if ent ~= ply then continue end
                print("asddd")
                
                local vel_norm = ply:GetVelocity():GetNormalized()

                -- Object is moving towards the portal
                if vel_norm:Dot( portal:GetForward() ) < 0 then --and SysTime() - last_tele > 0.5 then

                    print("ddddd")

                    local projected_distance = wp.DistanceToPlane( ply:EyePos() + ply:GetVelocity() *engine.TickInterval(), portal:GetPos(), portal:GetForward() )

                    --if projected_distance < 0 then

                        print("ffffff")

                        hook.Add( "CalcView", "WorldPortals_PredictTeleView", function( ply, pos, angle, fov )

                            local camOrigin = wp.TransformPortalPos( pos, portal, portal:GetExit() )
                            local camAngle = wp.TransformPortalAngle( angle, portal, portal:GetExit() )

                            print("qqqqq")

                            return {
                                origin = camOrigin, ---( angle:Forward()*100 ), --camorigin
                                angles = camAngle,
                                fov = fov
                            }

                        end )
                    --end
                end
            end
        end
    end
end )

net.Receive( "WorldPortals_TeleportAlert", function()
    hook.Remove( "CalcView", "WorldPortals_PredictTeleView" )
end )
]]--

hook.Add("CalcView", "WorldPortals_RotateView", function(ply,pos,ang,fov)
    if wp.rotating then
        if wp.rotating ~= 0 then
            wp.rotating = math.Approach(wp.rotating,0,FrameTime()*((0.5+math.abs(wp.rotating))*3.5))
            local view={
                origin=pos,
                angles=Angle(ang.p,ang.y,wp.rotating),
                fov=fov
            }
            return view
        else
            wp.rotating=nil
        end
    end
end)

net.Receive("WorldPortals_TeleportAlert", function()
    local roll=net.ReadFloat()
    if roll ~= 0 then
        wp.rotating=roll
    end
end)