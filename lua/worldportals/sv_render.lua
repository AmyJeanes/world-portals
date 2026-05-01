
-- Add exit portal visleafs to server's potentially visible set
hook.Add( "SetupPlayerVisibility", "WorldPortals_AddPVS", function( ply, ent )
    for _, portal in ipairs( ents.FindByClass( "linked_portal_door" ) ) do
        if ply:TestPVS( portal:GetPos() ) then
            local exitPortal = portal:GetExit()
            if IsValid(exitPortal) and (not ply:TestPVS( exitPortal:GetPos() )) then
                AddOriginToPVS( exitPortal:GetPos() )
            end
        end
    end
end )


-- Make sure that all portals have found their exit
-- Sometimes the entrance portal will be initialized before the exit
local function PairWithExits()
    for _, portal in ipairs( ents.FindByClass( "linked_portal_door" ) ) do
        if not IsValid( portal:GetExit() ) then
            portal:SetExit( ents.FindByName( portal:GetPartnerName() )[1] )
        end
    end
end
hook.Add( "InitPostEntity", "WorldPortals_PairWithExits", PairWithExits )
hook.Add( "PostCleanupMap", "WorldPortals_PairWithExits", PairWithExits )
