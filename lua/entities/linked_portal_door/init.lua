
AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )

include( "shared.lua" )

AccessorFunc( ENT, "partnername", "PartnerName" )

util.AddNetworkString("WorldPortals_VRMod_SetAngle")
util.AddNetworkString("WorldPortals_Teleport")
util.AddNetworkString("WorldPortals_CrossingGroup")

local cvTpFraction = CreateConVar("worldportals_teleport_fraction", "0.9", FCVAR_ARCHIVE, "Fraction (0-1) of a prop's depth that must pass through a portal before it teleports: 0 = leading edge, 0.5 = centre, 1 = fully through", 0, 1)

---@param key string
---@param value string
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

    elseif ( key == "startcollision" or key == "StartCollision" ) then
        self:SetEnableCollision( tobool(value) )
        self.EnableCollisionSetByMap = true

    elseif ( string.Left( key, 2 ) == "On" ) then
        self:StoreOutput( key, value )
    end
end

local TP_REFIRE_COOLDOWN = 0.2   -- window to suppress a group bouncing straight back out its exit portal

-- Move one body through the portal: transform pos/vel/angle, snapshot and re-apply a
-- ragdoll's physics-object poses around SetPos, disarm the entry, fire outputs/hook,
-- broadcast. Shared by the single-prop and rigid-group paths.
---@param ent Entity
---@param portal linked_portal_door
---@param exit linked_portal_door
local function applyTeleport( ent, portal, exit )
    local new_pos = wp.TransformPortalPos( ent:GetPos(), portal, exit )
    local new_velocity = wp.TransformPortalVector( ent:GetVelocity(), portal, exit )
    local new_angle = wp.TransformPortalAngle( ent:GetAngles(), portal, exit )

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
    -- Adjust hoverball target height to match the new relative position after teleporting so it doesn't snap back
    if ent:GetClass() == "gmod_hoverball" then
        ---@cast ent gmod_hoverball
        ent:SetTargetZ( ent:GetTargetZ() + (new_pos.z - ent:GetPos().z) )
    end
    ent:SetPos( new_pos )
    ent:SetAngles( new_angle )
    ent:SetVelocity( new_velocity )
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocityInstantaneous( new_velocity )
        phys:Wake() -- a sleeping group member won't re-register with the solver/triggers after SetPos
    end

    -- Disarm the entry explicitly - a SetPos teleport can skip its EndTouch, leaving the
    -- prop no-collided against the entry's parent. The exit side arms via its own Touch.
    wp.DisarmNoCollide( ent, portal )
    portal:TriggerOutput("OnEntityTeleportFromMe", ent)
    exit:TriggerOutput("OnEntityTeleportToMe", ent)
    if store then
        for i=0,ent:GetPhysicsObjectCount() do
            local bone=ent:GetPhysicsObjectNum(i)
            if IsValid(bone) and store[i] then
                bone:SetPos(ent:LocalToWorld(store[i][1]))
                bone:SetAngles(ent:LocalToWorldAngles(store[i][2]))
                bone:SetVelocityInstantaneous(new_velocity)
                bone:Wake()
            end
        end
    end

    ent:ForcePlayerDrop()

    hook.Call("wp-teleport", GAMEMODE, portal, ent, new_pos, new_angle)
    net.Start("WorldPortals_Teleport")
        net.WriteEntity(portal)
        net.WriteEntity(ent)
        net.WriteVector(new_pos)
        net.WriteAngle(new_angle)
    net.Broadcast()
end

-- Is a world point within the portal's opening (its y/z face)? The Touch trigger covers
-- a bigger volume than the actual opening on a thick or rotated portal, so we re-check
-- the point is really inside it.
---@param portal linked_portal_door
---@param worldPoint Vector
---@return boolean
local function inFace( portal, worldPoint )
    local lc = portal:WorldToLocal( worldPoint )
    local cmins, cmaxs = portal:GetCollisionBounds()
    return lc.y >= cmins.y and lc.y <= cmaxs.y and lc.z >= cmins.z and lc.z <= cmaxs.z
end

---@class wp.GroupSpan
---@field mass number
---@field momentum Vector
---@field centre Vector
---@field halfDepth number
---@field centreDist number

-- Measure a rigid group against a portal as one body: total momentum (Sum of mass*velocity,
-- so it points where the centre of mass is heading - used for the direction gate), the
-- combined-bounds centre (for opening alignment), and the group's span along the portal
-- normal (how far through it is). A member far from the opening just shifts these numbers.
---@param group Entity[]
---@param portal linked_portal_door
---@return wp.GroupSpan
local function measureGroup( group, portal )
    local ppos, normal = portal:GetPos(), portal:GetForward()
    local nMin, nMax = math.huge, -math.huge
    local minx, miny, minz = math.huge, math.huge, math.huge
    local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
    local totalMass, momentum = 0, Vector()
    for _, m in ipairs( group ) do
        local mmins, mmaxs = m:OBBMins(), m:OBBMaxs()
        for cx = 0, 1 do for cy = 0, 1 do for cz = 0, 1 do
            local corner = m:LocalToWorld( Vector(
                cx == 0 and mmins.x or mmaxs.x,
                cy == 0 and mmins.y or mmaxs.y,
                cz == 0 and mmins.z or mmaxs.z ) )
            local proj = (corner - ppos):Dot( normal )
            if proj < nMin then nMin = proj end
            if proj > nMax then nMax = proj end
            if corner.x < minx then minx = corner.x end
            if corner.y < miny then miny = corner.y end
            if corner.z < minz then minz = corner.z end
            if corner.x > maxx then maxx = corner.x end
            if corner.y > maxy then maxy = corner.y end
            if corner.z > maxz then maxz = corner.z end
        end end end
        local mp = m:GetPhysicsObject()
        if IsValid( mp ) then
            local mass = mp:GetMass()
            totalMass = totalMass + mass
            momentum:Add( m:GetVelocity() * mass )
        end
    end
    return {
        mass = totalMass,
        momentum = momentum,
        centre = Vector( (minx + maxx) * 0.5, (miny + maxy) * 0.5, (minz + maxz) * 0.5 ),
        halfDepth = 0.5 * (nMax - nMin),
        centreDist = 0.5 * (nMin + nMax),
    }
end

-- Net the members already past the portal face - the ones that would otherwise render solid
-- behind it - so the client ghosts them at the exit.
---@param portal linked_portal_door
---@param group Entity[]
---@param normal Vector
local function broadcastCrossingGroup( portal, group, normal )
    local ppos = portal:GetPos()
    local past = {}
    for _, m in ipairs( group ) do
        if wp.DistanceToPlane( m:WorldSpaceCenter(), ppos, normal ) <= 0 then
            past[#past + 1] = m
        end
    end
    if #past == 0 then return end

    net.Start("WorldPortals_CrossingGroup")
        net.WriteEntity( portal )
        net.WriteUInt( #past, 16 )
        for _, m in ipairs( past ) do net.WriteEntity( m ) end
    net.Broadcast()
end

-- Is this rigid group mid-crossing - its combined body straddling the opening, part past the
-- face and part in front? A lone prop, or a group fully in or out, is not.
---@param group Entity[]
---@param portal linked_portal_door
---@return boolean
local function groupStraddles( group, portal )
    if #group <= 1 then return false end
    local span = measureGroup( group, portal )
    return math.abs( span.centreDist ) < span.halfDepth and inFace( portal, span.centre )
end

-- Find any mid-crossing group near one portal and broadcast its past members. Only walk from a
-- mover whose centre is at or past the face - the ones that can need a crossing ghost - so a
-- contraption still approaching, or props parked in front, is never walked.
---@param portal linked_portal_door
local function scanPortalForCrossings( portal )
    local ppos, normal = portal:GetPos(), portal:GetForward()
    local r = portal:OBBCenter():Length() + portal:BoundingRadius() + 512
    local gathered = {}   -- walk each group once; its members all recur in FindInSphere
    for _, ent in ipairs( ents.FindInSphere( ppos, r ) ) do
        if wp.IsPhysicalMover( ent ) and not gathered[ent]
            and wp.DistanceToPlane( ent:WorldSpaceCenter(), ppos, normal ) <= 0 then
            local group = wp.GatherRigidGroup( ent, portal )
            if group then
                for _, m in ipairs( group ) do gathered[m] = true end
                if groupStraddles( group, portal ) then
                    broadcastCrossingGroup( portal, group, normal )
                end
            end
        end
    end
end

-- Find contraption members that have cleared a portal's opening but not teleported, so
-- cl_ghosts can ghost them. Geometric rather than off ENT:Touch: a frozen contraption's members
-- are asleep so Touch never fires, and off Touch the ghost flaps as they wake and sleep.
-- FindInSphere per portal is the cost here; 10Hz stays well inside the client's 0.3s mark grace.
local GROUP_SCAN_INTERVAL = 0.1
local nextGroupScan = 0
hook.Add("Think", "WorldPortals_CrossingScan", function()
    local rt = RealTime()
    if rt < nextGroupScan then return end
    nextGroupScan = rt + GROUP_SCAN_INTERVAL

    for _, portal in ipairs( wp.portals ) do
        if IsValid( portal ) and portal:GetOpen() and portal:GetEnableTeleport() and IsValid( portal:GetExit() ) then
            scanPortalForCrossings( portal )
        end
    end
end)

-- Teleport non-player entities (props/NPCs/ragdolls); players use the predicted
-- SetupMove path. A welded/roped contraption crosses as one rigid body
-- (wp.GatherRigidGroup) so its constraints survive.
---@param ent Entity
function ENT:Touch( ent )
    if (not self:GetOpen()) or (not self:GetEnableTeleport()) then return end
    if ent:IsPlayer() then return end
    -- Only a free physical body, not scripted/static geometry (a prop_dynamic the portal sits in).
    if not wp.IsPhysicalMover( ent ) then return end
    local exit = self:GetExit()
    if not IsValid(exit) then return end

    -- Stop a group member bouncing straight back into the portal it just came out of.
    if ent.wpGroupTpAt and ent.wpGroupTpExit == self
        and CurTime() - ent.wpGroupTpAt < TP_REFIRE_COOLDOWN then return end

    if hook.Call("wp-shouldtp", GAMEMODE, self, ent) == false then return end

    -- Don't teleport the portal's mount (parent chain) or a prop welded into its contraption. The
    -- weld check skips an already-armed prop, whose pass-through NoCollide would itself falsely match.
    if wp.RidesPortal( ent, self ) then return end
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

    -- Touch fires per member; evaluate the whole rigid group only once per tick per portal.
    local tick = engine.TickCount()
    if ent.wpGroupTick == tick and ent.wpGroupPortal == self then return end
    local group = wp.GatherRigidGroup( ent, self )
    if not group then return end   -- anchored to the world / the portal's mount, or a member vetoed
    for _, m in ipairs( group ) do
        m.wpGroupTick = tick
        m.wpGroupPortal = self
    end

    if #group <= 1 then
        -- Single body: teleport once the configured fraction of the prop's depth (measured
        -- along the portal normal) has passed the plane. 0.5 = its centre; higher waits
        -- until more of it has emerged.
        local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
        local half_depth = 0.5 * ( math.abs((maxs.x - mins.x) * ent:GetForward():Dot(normal))
                                 + math.abs((maxs.y - mins.y) * ent:GetRight():Dot(normal))
                                 + math.abs((maxs.z - mins.z) * ent:GetUp():Dot(normal)) )
        local center = ent:LocalToWorld( ent:OBBCenter() )
        local center_dist = wp.DistanceToPlane( center, self:GetPos(), normal )
        if inFace( self, center ) and center_dist <= half_depth * (1 - 2 * cvTpFraction:GetFloat()) then
            applyTeleport( ent, self, exit )
        end
        return
    end

    -- The whole rigid group teleports in one tick; these gates only decide WHEN, all measured
    -- on the group as one body - so a member far from the opening just shifts them and still
    -- comes along. In order: heading into the portal, centre within the opening, far enough through.
    local span = measureGroup( group, self )
    if span.mass <= 0 then return end
    if span.momentum:Dot( normal ) >= 0 then return end
    if not inFace( self, span.centre ) then return end
    if span.centreDist > span.halfDepth * (1 - 2 * cvTpFraction:GetFloat()) then return end

    for _, m in ipairs( group ) do
        applyTeleport( m, self, exit )
        m.wpGroupTpAt = CurTime()
        m.wpGroupTpExit = exit
    end
end

-- Restore parent collision when the prop leaves the doorway without teleporting
-- (a teleport already disarms the entry in Touch). Idempotent if both fire.
---@param ent Entity
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
    f:SetCollisionEnabled(self:GetEnableCollision())
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

---@param inputName string
---@param activator Entity
---@param caller Entity
---@param data string
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
    elseif ( inputName == "EnableCollision" ) then
        self:SetEnableCollision( true )
    elseif ( inputName == "DisableCollision" ) then
        self:SetEnableCollision( false )
    end
end
