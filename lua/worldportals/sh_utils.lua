-- Utils

---@param y number
---@param x number
---@return number
local function arctan2(y, x)
    if ((x ~= 0) or (y ~= 0)) then
        if (math.abs(x) >= math.abs(y)) then
            if (x >= 0) then
                return math.atan(y / x)
            elseif (y >= 0) then
                return math.atan(y / x) + math.pi
            else
                return math.atan(y / x) - math.pi
            end
        elseif (y >= 0) then
            return math.pi / 2 - math.atan(x / y)
        else
            return -math.pi / 2 - math.atan(x / y)
        end
    else
        return 0.0
    end
end

-- Checks if a given position and view angle is looking at another position
---@param portal linked_portal_door
---@param portal_pos Vector
---@param view_pos Vector
---@param view_ang Angle
---@param view_fov number
function wp.IsLookingAt( portal, portal_pos, view_pos, view_ang, view_fov )
    local radius = math.max(portal:BoundingRadius(), portal:GetThickness())
    local dx = portal_pos.x - view_pos.x
    local dy = portal_pos.y - view_pos.y
    local dz = portal_pos.z - view_pos.z
    
    local distSqr = dx * dx + dy * dy + dz * dz
    local aimVec = view_ang:Forward()
    if ((distSqr > (radius^2)) and (distSqr > 0)) then
        local dist = math.sqrt(distSqr)
        local dirDotAim = (dx * aimVec.x + dy * aimVec.y + dz * aimVec.z) / dist
        local aimLenSqr = aimVec:LengthSqr()
        local crossLen = math.sqrt(math.max(aimLenSqr - dirDotAim * dirDotAim, 0))
        local viewRadius = arctan2(radius / dist, math.sqrt(1 - radius^2 / distSqr)) * 180 / math.pi
        local viewOffset = arctan2(crossLen, dirDotAim) * 180 / math.pi

        if (viewOffset <= ((view_fov*1.5) / 2 + viewRadius)) then
            return true
        end
    else
        -- Inside the bounding sphere the cone test breaks down, so render
        -- unless the portal is fully behind the view (using its oriented
        -- extent, not the sphere radius which overstates thin portals).
        local extent = (math.abs(portal:GetWidth()     * portal:GetRight():Dot(aimVec))
                      + math.abs(portal:GetHeight()    * portal:GetUp():Dot(aimVec))
                      + math.abs(portal:GetThickness() * portal:GetForward():Dot(aimVec))) / 2
        if dx * aimVec.x + dy * aimVec.y + dz * aimVec.z + extent > 0 then
            return true
        end
    end
end

-- Returns the distance to a plane
---@param object_pos Vector
---@param plane_pos Vector
---@param plane_forward Vector
function wp.DistanceToPlane( object_pos, plane_pos, plane_forward )

    plane_forward:Normalize()

    return plane_forward.x * (object_pos.x - plane_pos.x)
        + plane_forward.y * (object_pos.y - plane_pos.y)
        + plane_forward.z * (object_pos.z - plane_pos.z)
end

-- Classes never treated as a body crossing a portal.
local PORTAL_EXCLUDED_CLASSES = {
    linked_portal_door = true,
    linked_portal_frame = true,
}

-- One of our own portal entities (the door or its collision frame), not a crossing body.
---@param ent Entity
---@return boolean
function wp.IsPortalEntity( ent )
    return PORTAL_EXCLUDED_CLASSES[ent:GetClass()] ~= nil
end

---@param ent Entity
---@return boolean
function wp.IsPhysicalMover( ent )
    if wp.IsPortalEntity( ent ) then return false end
    return ent:GetMoveType() == MOVETYPE_VPHYSICS
        or ent:IsRagdoll() or ent:IsNPC() or ent:IsPlayer()
end

-- The structure the portal is mounted on (its parent chain) - client-safe, unlike constraints.
---@param ent Entity
---@param portal linked_portal_door
---@return boolean
function wp.RidesPortal( ent, portal )
    local p = portal:GetParent()
    while IsValid(p) do
        if p == ent then return true end
        p = p:GetParent()
    end
    return false
end

---@param portal linked_portal_door
function wp.PortalFaceOffset( portal )
    local rmin, rmax = portal.RenderMin, portal.RenderMax
    return (rmin and rmax) and math.max( rmin.x, rmax.x ) or 0
end

local ANGLE_YAW_180 = Angle(0, 180, 0)
local ANGLE_ZERO = Angle(0, 0, 0)
local VECTOR_ORIGIN = Vector()
local VECTOR_UP = Vector(0, 0, 1)

-- Transforms a position from one portal to another
---@api
---@param vec Vector
---@param portal linked_portal_door
---@param exit_portal linked_portal_door
function wp.TransformPortalPos( vec, portal, exit_portal )
    local l_vec = portal:WorldToLocal( vec )
    l_vec:Rotate(ANGLE_YAW_180)

    local offset =  exit_portal:GetExitPosOffset()

    if IsValid(exit_portal:GetParent()) then
        offset:Rotate(exit_portal:GetParent():GetAngles())
    end

    local w_vec = LocalToWorld(l_vec, portal:GetAngles(), exit_portal:GetPos() + offset, exit_portal:GetAngles() + exit_portal:GetExitAngOffset())

    return w_vec

end

-- Transforms a vector (direction) through a portal pair: same WorldToLocal ->
-- 180-yaw mirror -> LocalToWorld pipeline as the position/angle transforms, so
-- it's a real rotation at any pitch/roll (Euler-angle subtraction would flip
-- velocity on pitched/rolled pairs).
---@api
---@param vec Vector
---@param portal linked_portal_door
---@param exit_portal linked_portal_door
function wp.TransformPortalVector( vec, portal, exit_portal )

    -- Direction-only: zero origin so only the rotation applies. WorldToLocal
    -- returns a fresh vector, so the caller's input is untouched.
    local l_vec = WorldToLocal( vec, ANGLE_ZERO, VECTOR_ORIGIN, portal:GetAngles() )
    l_vec:Rotate( ANGLE_YAW_180 )
    local w_vec = LocalToWorld( l_vec, ANGLE_ZERO, VECTOR_ORIGIN, exit_portal:GetAngles() + exit_portal:GetExitAngOffset() )

    return w_vec

end

--Transforms an angle from one portal to another
---@api
---@param angle Angle
---@param portal linked_portal_door
---@param exit_portal linked_portal_door
function wp.TransformPortalAngle( angle, portal, exit_portal )

    local l_angle = portal:WorldToLocalAngles( angle )
    l_angle:RotateAroundAxis( VECTOR_UP, 180)
    local _, w_angle = LocalToWorld(VECTOR_ORIGIN, l_angle, VECTOR_ORIGIN, exit_portal:GetAngles() + exit_portal:GetExitAngOffset())

    return w_angle

end

--Returns the first portal hit starting from a source position and given the direction of the vector
---@api
---@param source Vector
---@param direction Vector
function wp.GetFirstPortalHit(source, direction)
    local portal = {
        Entity = nil,
        Distance = 0,
        HitPos = Vector(0,0,0)
    }
    for _, v in ipairs(wp.portals) do
        if v.GetExit and IsValid(v:GetExit()) then
            local hitPos = util.IntersectRayWithPlane(source, direction, v:GetPos(), v:GetForward())

            if isvector(hitPos) and direction:Dot( v:GetForward() ) < 0 then
                local dist = source:Distance(v:GetPos())

                if portal.Distance == 0 then
                    portal.Distance = dist
                end

                if dist <= portal.Distance then
                    portal.Entity = v
                    portal.Distance = dist
                    portal.HitPos = hitPos
                end
            end
        end
    end

    return portal
end
