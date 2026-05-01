
AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )

include( "shared.lua" )

AccessorFunc( ENT, "partnername", "PartnerName" )
AccessorFunc( ENT, "enableteleport", "EnableTeleport", FORCE_BOOL )

util.AddNetworkString("WorldPortals_VRMod_SetAngle")
util.AddNetworkString("WorldPortals_Teleport")

-- Collect properties
function ENT:KeyValue( key, value )
    if ( key == "partnername" ) then
        self:SetPartnerName( value )
        self:SetExit( ents.FindByName( value )[1] )

    elseif ( key == "width" ) then
        self:SetWidth( (tonumber(value) or 0) *2 )

    elseif ( key == "height" ) then
        self:SetHeight( (tonumber(value) or 0) *2 )

    elseif ( key == "thickness" ) then
        self:SetThickness( tonumber(value) )

    elseif ( key == "DisappearDist" or key == "fademaxdist" ) then
        self:SetDisappearDist( tonumber(value) )

    elseif ( key == "angles" ) then
        local args = value:Split( " " )

        for k, arg in pairs( args ) do
            args[k] = tonumber(arg)
        end

        self:SetAngles( Angle( unpack(args) ) )

    elseif ( key == "EnableTeleport" ) then
        self:SetEnableTeleport( tobool(value) )
        self.EnableTeleportSetByMap = true

    elseif ( key == "Open" ) then
        self:SetOpen( tobool(value) )
        self.OpenSetByMap = true

    elseif ( key == "startactive" or key == "StartActive" ) then
        self:SetOpen( tobool(value) )
        self.OpenSetByMap = true

    elseif ( string.Left( key, 2 ) == "On" ) then
        self:StoreOutput( key, value )
    end
end

-- Teleportation
function ENT:Touch( ent )
    if (not self:GetOpen()) or (not self:GetEnableTeleport()) then return end
    local exit = self:GetExit()
    if not IsValid(exit) then return end
    
    if IsValid( self:GetParent() ) then
        local ents = constraint.GetAllConstrainedEntities( self:GetParent() ) -- don't mess up this contraption we're on
        for _,v in pairs( ents ) do
            if v == ent then
                return
            end
        end
    end
    local vel_norm = ent:GetVelocity():GetNormalized()

    -- Object is moving towards the portal
    if vel_norm:Dot( self:GetForward() ) < 0 then

        local projected_distance = wp.DistanceToPlane( ent:EyePos(), self:GetPos(), self:GetForward() )

        if projected_distance < 0 and hook.Call("wp-shouldtp",GAMEMODE,self,ent)~=false then

            local new_pos = wp.TransformPortalPos( ent:GetPos(), self, exit )
            local new_velocity = wp.TransformPortalVector( ent:GetVelocity(), self, exit )
            local new_angle = wp.TransformPortalAngle( ent:GetAngles(), self, exit )
            if ent:IsPlayer() then
                local height = ent:OBBMaxs().z
                local temppos = Vector(0,0,height)
                temppos:Rotate(Angle(0,0,new_angle.r))
                new_pos = new_pos + Vector(0,0,(temppos.z - height) / 2) 
            end
        
            
            ---@type table<integer, {[1]: Vector, [2]: Angle}>?
            local store
            if ent:IsRagdoll() then
                store={}
                for i=0,ent:GetPhysicsObjectCount() do
                    local bone=ent:GetPhysicsObjectNum(i)
                    if IsValid(bone) then
                        store[i]={ent:WorldToLocal(bone:GetPos()),ent:WorldToLocalAngles(bone:GetAngles())}
                    end
                end
            end
            ent:SetPos( new_pos )
            if ent:IsPlayer() then
                if vrmod and vrmod.IsPlayerInVR(ent) then
                    net.Start("WorldPortals_VRMod_SetAngle")
                        net.WriteDouble(wp.TransformPortalAngle(Angle(0,0,0), self, exit).y)
                    net.Send(ent)
                end
                ent:SetEyeAngles( Angle(new_angle.p, new_angle.y, 0) )
                ent:SetLocalVelocity( new_velocity )
                wp.AlertPlayerOnTeleport( ent, new_angle.r )
                self:TriggerOutput("OnPlayerTeleportFromMe", ent)
                exit:TriggerOutput("OnPlayerTeleportToMe", ent)
            else
                ent:SetAngles( new_angle )

                ent:SetVelocity( new_velocity )
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) then phys:SetVelocityInstantaneous( new_velocity ) end
                self:TriggerOutput("OnEntityTeleportFromMe", ent)
                exit:TriggerOutput("OnEntityTeleportToMe", ent)
            end
            if store then
                for i=0,ent:GetPhysicsObjectCount() do
                    local bone=ent:GetPhysicsObjectNum(i)
                    if IsValid(bone) and store[i] then
                        bone:SetPos(ent:LocalToWorld(store[i][1]))
                        bone:SetAngles(ent:LocalToWorldAngles(store[i][2]))
                        bone:SetVelocityInstantaneous(new_velocity)
                    end
                end
            end
            
            ent:ForcePlayerDrop()
            
            hook.Call("wp-teleport", GAMEMODE, self, ent, new_pos, new_angle)
            net.Start("WorldPortals_Teleport")
                net.WriteEntity(self)
                net.WriteEntity(ent)
                net.WriteVector(new_pos)
                net.WriteAngle(new_angle)
            net.Broadcast()
        end
    end
end

function ENT:AcceptInput( inputName, activator, caller, data )
    if ( inputName == "SetPartner" ) then
        self:SetPartnerName( data )
        self:SetExit( ents.FindByName( data )[1] )
    elseif ( inputName == "EnableTeleport" ) then
        self:SetEnableTeleport( tobool(data) )
    elseif ( inputName == "Open" ) then
        self:SetOpen( true )
    elseif ( inputName == "Close" ) then
        self:SetOpen( false )
    end
end
