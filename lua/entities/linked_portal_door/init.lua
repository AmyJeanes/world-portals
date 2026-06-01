
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

    elseif ( key == "falseworld" ) then
        self:SetFalseWorld( value )

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

-- Teleportation. Players are handled by the predicted SetupMove path in
-- sh_teleport.lua so the local view stays in lockstep with the server; Touch
-- only handles non-player entities (props, NPCs, ragdolls), which can't be
-- client-predicted anyway.
function ENT:Touch( ent )
    if (not self:GetOpen()) or (not self:GetEnableTeleport()) then return end
    if ent:IsPlayer() then return end
    local exit = self:GetExit()
    if not IsValid(exit) then return end

    -- Self-exclusion / consumer veto: the SAME gate the teleport uses.
    -- ShouldTeleportPortal rejects the consumer's own parts (e.g. ent.TardisPart)
    -- and a closed door, so this single check stops the pass-through no-collide
    -- from ever grabbing the structure the portal is built into, or firing while
    -- the door is shut -- the bugs that let props phase through the shell.
    if hook.Call("wp-shouldtp", GAMEMODE, self, ent) == false then return end

    -- Don't teleport/phase an entity rigidly attached to the contraption this portal
    -- rides on. EXCEPTION: one we've already armed -- our own NoCollide makes it show
    -- up in GetAllConstrainedEntities, but it passed this check cleanly on first arm.
    if IsValid( self:GetParent() ) and not (wp.nocollide[ent] and wp.nocollide[ent][self]) then
        for _,v in pairs( constraint.GetAllConstrainedEntities( self:GetParent() ) ) do
            if v == ent then return end
        end
    end

    -- Pass the prop through the wall while it transits, in ANY direction. This used to
    -- be gated on "moving toward the portal", which made it unreliable for a prop the
    -- player pushes/drags/rotates by hand (a held prop's velocity wanders, so it kept
    -- jamming on the wall). Instead arm whenever the prop is genuinely DYNAMIC -- moving
    -- or physgun-held -- so a static structure prop merely overlapping the trigger
    -- (~zero velocity, not held) is still excluded, with wp-shouldtp above as the real
    -- structure guard. Idempotent; disarmed in EndTouch.
    local entphys = ent:GetPhysicsObject()
    if (IsValid(entphys) and entphys:GetVelocity():LengthSqr() > 25) or ent:IsPlayerHolding() then
        wp.ArmNoCollide(self, ent)
    end

    -- Teleport only when the prop is genuinely crossing TOWARD the exit. Direction
    -- matters here (unlike the no-collide above) so it doesn't bounce back and forth.
    if ent:GetVelocity():GetNormalized():Dot( self:GetForward() ) >= 0 then return end
    local projected_distance = wp.DistanceToPlane( ent:EyePos(), self:GetPos(), self:GetForward() )
    if projected_distance < 0 then

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

            -- Arm the exit side now (the prop just emerged into the exit's wall),
            -- so the handoff is seamless rather than waiting a tick for the exit's
            -- own Touch to fire. The entry side disarms via its EndTouch.
            wp.ArmNoCollide( exit, ent )
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

-- Restore wall collision once the prop leaves the doorway (transited through, or
-- pulled back out). On teleport the prop is moved out of this trigger, so EndTouch
-- fires here and disarms the entry side; the exit side was armed in Touch.
function ENT:EndTouch( ent )
    wp.DisarmNoCollide( ent, self )
end

-- Collision frame: a child linked_portal_frame entity carrying a perimeter-frame
-- physics hull (props only) at the opening, so a prop transiting the portal is
-- funnelled through the hole while sv_collision.lua no-collides it with the wall.
-- Created once here; rebuilt from the Width/Height/Thickness NetworkVarNotifies in
-- shared.lua when the opening resizes.
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
        -- Deliberately NOT parented. A parented frame would sit under this portal's
        -- parent (the TARDIS shell), and the prop<->shell no-collide applied during
        -- transit disables the prop against ALL of the shell's parented descendants
        -- -- so the prop would phase the frame the moment it armed. The frame tracks
        -- the portal via its own Think (reads .Portal) instead. WPPortal networks the
        -- reference for the client debug overlay.
        f.Portal = self
        f:SetNWEntity("WPPortal", self)
        self.CollisionFrame = f
    end
    f:BuildFrame(w, h, self:GetThickness())
    -- No-collide the (unparented) frame with the wall it sits in NOW, before the next
    -- physics tick, so its solid hull doesn't interpenetrate the shell and launch the
    -- TARDIS. The frame's Think re-checks this periodically for late-parented walls.
    wp.NoCollideFrame(f, self)
end

function ENT:OnRemove()
    -- Parented children aren't auto-removed with the parent in GMod.
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
