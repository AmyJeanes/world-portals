
-- Checks if an object's position is behind a plane
function wp.IsBehind( object_pos, plane_pos, plane_forward )

    local vec = object_pos - plane_pos

    if plane_forward:Dot( vec ) < 0 then 
        return true
    end

    return false
end

local function crossDist(vec1, vec2)
    return math.sqrt(vec1:LengthSqr() * vec2:LengthSqr() - vec1:Dot(vec2)^2)
end

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
-- Adapted from SCP 173 https://steamcommunity.com/sharedfiles/filedetails/?id=830210642
function wp.IsLookingAt( portal, portal_pos, view_pos, view_ang, view_fov )
    local radius = math.max(portal:BoundingRadius(), portal:GetThickness())
    local disp = portal_pos - view_pos
    
    local distSqr = disp:LengthSqr()
    if ((distSqr > (radius^2)) and (distSqr > 0)) then
        local aimVec = view_ang:Forward()
        local dir = disp:GetNormalized()
        local viewRadius = arctan2(radius/math.sqrt(distSqr), math.sqrt(1 - radius^2/distSqr)) * 180 / math.pi
        local viewOffset = arctan2(crossDist(dir, aimVec), dir:Dot(aimVec)) * 180 / math.pi
        
        if (viewOffset <= ((view_fov*1.5) / 2 + viewRadius)) then
            return true
        end
    else
        return true
    end
end

-- Returns the distance to a plane
function wp.DistanceToPlane( object_pos, plane_pos, plane_forward )

    plane_forward:Normalize()
    local vec = object_pos - plane_pos

    return plane_forward:Dot( vec )
end

-- Transforms a position from one portal to another
function wp.TransformPortalPos( vec, portal, exit_portal )
    local l_vec = portal:WorldToLocal( vec )
    l_vec:Rotate(Angle(0,180,0))

    local offset =  exit_portal:GetExitPosOffset()

    if IsValid(exit_portal:GetParent()) then
        offset:Rotate(exit_portal:GetParent():GetAngles())
    end

    local w_vec = LocalToWorld(l_vec, portal:GetAngles(), exit_portal:GetPos() + offset, exit_portal:GetAngles() + exit_portal:GetExitAngOffset())

    return w_vec

end

-- Transforms a vector from one portal to another
function wp.TransformPortalVector( vec, portal, exit_portal )

    local rotate_ang = exit_portal:GetAngles() - portal:GetAngles()
    rotate_ang = rotate_ang + Angle( 0, 180, 0 ) + exit_portal:GetExitAngOffset()
    vec:Rotate( rotate_ang )

    return vec

end

--Transforms an angle from one portal to another
function wp.TransformPortalAngle( angle, portal, exit_portal )

    local l_angle = portal:WorldToLocalAngles( angle )
    l_angle:RotateAroundAxis( Vector(0, 0, 1), 180)
    local _, w_angle = LocalToWorld(Vector(), l_angle, Vector(), exit_portal:GetAngles() + exit_portal:GetExitAngOffset())

    return w_angle

end

--Returns the first portal hit starting from a source position and given the direction of the vector
function wp.GetFirstPortalHit(source, direction)
    local portal = {
        Entity = nil,
        Distance = 0,
        HitPos = Vector(0,0,0)
    }
    for _,v in pairs(ents.FindByClass("linked_portal_door")) do
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
