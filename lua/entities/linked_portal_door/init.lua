
AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )

include( "shared.lua" )

AccessorFunc( ENT, "partnername", "PartnerName" )

util.AddNetworkString("WorldPortals_VRMod_SetAngle")
util.AddNetworkString("WorldPortals_Teleport")

local cvTpFraction = CreateConVar("worldportals_teleport_fraction", "0.9", FCVAR_ARCHIVE, "Fraction (0-1) of a prop's depth that must pass through a portal before it teleports: 0 = leading edge, 0.5 = centre, 1 = fully through", 0, 1)

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

    elseif ( key == "falseworld" ) then
        self:SetFalseWorld( value )

    elseif ( key == "custommodel" ) then
        self:SetCustomModel( value )

    elseif ( key == "custommodelpos" ) then
        local args = value:Split( " " )
        for k, arg in pairs( args ) do
            args[k] = tonumber(arg)
        end
        self:SetCustomModelPosOffset( Vector( unpack(args) ) )

    elseif ( key == "custommodelang" ) then
        local args = value:Split( " " )
        for k, arg in pairs( args ) do
            args[k] = tonumber(arg)
        end
        self:SetCustomModelAngOffset( Angle( unpack(args) ) )

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

-- Teleportation for non-player entities (props/NPCs/ragdolls) only - players go
-- through the predicted SetupMove path in sh_teleport.lua.
function ENT:Touch( ent )
    if (not self:GetOpen()) or (not self:GetEnableTeleport()) then return end
    if ent:IsPlayer() then return end
    local exit = self:GetExit()
    if not IsValid(exit) then return end
    if hook.Call("wp-shouldtp", GAMEMODE, self, ent) == false then return end

    -- Don't teleport or phase a prop that's part of the contraption this portal rides
    -- on. Skip the check for an already-armed prop: its pass-through NoCollide is
    -- itself a constraint, so the prop self-registers in the parent's network and
    -- would wrongly match here - yet it armed only after passing this check clean.
    if IsValid( self:GetParent() ) and not (wp.nocollide[ent] and wp.nocollide[ent][self]) then
        for _,v in pairs( constraint.GetAllConstrainedEntities( self:GetParent() ) ) do
            if v == ent then return end
        end
    end

    -- Arm the parent pass-through for any dynamic or physgun-held prop, in any
    -- direction (a held prop's velocity wanders). Static props excluded; wp-shouldtp
    -- guards the structure.
    local entphys = ent:GetPhysicsObject()
    if (IsValid(entphys) and entphys:GetVelocity():LengthSqr() > 25) or ent:IsPlayerHolding() then
        wp.ArmNoCollide(self, ent)
    end

    -- Teleport only when the prop is crossing toward the exit, else it ping-pongs.
    local normal = self:GetForward()
    if ent:GetVelocity():GetNormalized():Dot( normal ) >= 0 then return end

    -- Teleport once the configured fraction of the prop's depth (measured along the
    -- portal normal) has passed the plane. 0.5 = its centre; higher waits until more
    -- of it has emerged.
    local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
    local half_depth = 0.5 * ( math.abs((maxs.x - mins.x) * ent:GetForward():Dot(normal))
                             + math.abs((maxs.y - mins.y) * ent:GetRight():Dot(normal))
                             + math.abs((maxs.z - mins.z) * ent:GetUp():Dot(normal)) )
    local center_dist = wp.DistanceToPlane( ent:LocalToWorld( ent:OBBCenter() ), self:GetPos(), normal )
    if center_dist <= half_depth * (1 - 2 * cvTpFraction:GetFloat()) then

            local new_pos = wp.TransformPortalPos( ent:GetPos(), self, exit )
            local new_velocity = wp.TransformPortalVector( ent:GetVelocity(), self, exit )
            local new_angle = wp.TransformPortalAngle( ent:GetAngles(), self, exit )

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
            ent:SetAngles( new_angle )
            ent:SetVelocity( new_velocity )
            local phys = ent:GetPhysicsObject()
            if IsValid(phys) then phys:SetVelocityInstantaneous( new_velocity ) end

            -- Disarm the entry explicitly - a SetPos teleport can skip its EndTouch,
            -- leaving the prop no-collided against the entry's parent. The exit side
            -- arms via its own Touch as the prop emerges through it.
            wp.DisarmNoCollide( ent, self )
            self:TriggerOutput("OnEntityTeleportFromMe", ent)
            exit:TriggerOutput("OnEntityTeleportToMe", ent)
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

-- Restore parent collision when the prop leaves the doorway without teleporting
-- (a teleport already disarms the entry in Touch). Idempotent if both fire.
function ENT:EndTouch( ent )
    wp.DisarmNoCollide( ent, self )
end

-- Create/destroy the portal's linked_portal_frame child (a perimeter physics hull
-- that funnels transiting props through the opening).
function ENT:RebuildCollisionFrame()
    local w, h = self:GetWidth(), self:GetHeight()
    if w <= 0 or h <= 0 then
        if IsValid(self.CollisionFrame) then
            self.CollisionFrame:Remove()
            self.CollisionFrame = nil
        end
        return
    end

    local f = self.CollisionFrame
    if not IsValid(f) then
        f = ents.Create("linked_portal_frame")
        if not IsValid(f) then return end
        f:SetPos(self:GetPos())
        f:SetAngles(self:GetAngles())
        f:Spawn()
        -- Deliberately NOT parented: the prop<->parent no-collide would disable the
        -- prop against the parent's whole parented subtree, so a parented frame
        -- would be phased too. It tracks the portal via its own Think (.Portal);
        -- WPPortal networks the reference for the client debug overlay.
        f.Portal = self
        f:SetNWEntity("WPPortal", self)
        self.CollisionFrame = f
    end
    f:BuildFrame(w, h, self:GetThickness())
    -- No-collide the (unparented) frame with the parent it sits in NOW, before the
    -- next physics tick: an overlapping solid hull would interpenetrate that parent
    -- and the physics solver would violently shove it away. The frame's Think
    -- re-checks this periodically in case the parent is parented late.
    wp.NoCollideFrame(f, self)
end

function ENT:OnRemove()
    if IsValid(self.CollisionFrame) then
        self.CollisionFrame:Remove()
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
