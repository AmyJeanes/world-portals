-- MCP world-portals helpers

MCP.wp = MCP.wp or {}
local wp_ = MCP.wp

local PORTAL_CLASS = "linked_portal_door"
wp_.PORTAL_CLASS = PORTAL_CLASS
wp_.DEFAULT_WIDTH = 100
wp_.DEFAULT_HEIGHT = 100

function wp_.IsPortal(ent)
    return IsValid(ent) and ent:GetClass() == PORTAL_CLASS
end

function wp_.ResolvePortal(entindex)
    if type(entindex) ~= "number" then
        return nil, "`entindex` must be a number"
    end
    local ent = Entity(entindex)
    if not wp_.IsPortal(ent) then
        return nil, "no linked_portal_door at entindex " .. entindex
    end
    return ent
end

function wp_.FirstPlayer()
    return player.GetAll()[1]
end

function wp_.ResolvePlayer(steamid)
    if steamid ~= nil and steamid ~= "" then
        if type(steamid) ~= "string" then return nil, "`steamid` must be a string" end
        for _, p in ipairs(player.GetAll()) do
            if p:SteamID() == steamid or p:SteamID64() == steamid then return p end
        end
        return nil, "no connected player matches steamid " .. steamid
    end
    return wp_.FirstPlayer()
end

---@return number[]? values, string? err
function wp_.ParseTriple(t, label)
    if type(t) ~= "table" or #t ~= 3 then
        return nil, "`" .. label .. "` must be a 3-element array"
    end
    for i = 1, 3 do
        if type(t[i]) ~= "number" then
            return nil, "`" .. label .. "[" .. i .. "]` must be a number"
        end
    end
    return { t[1], t[2], t[3] }
end

function wp_.OwnerInfo(ent)
    local creator = ent:GetCreator()
    if not IsValid(creator) then return nil end
    return { name = creator:Nick(), steamid = creator:SteamID() }
end

-- The exit an entity's portal points at, with the facts that decide whether the link is usable.
function wp_.ExitRef(exit)
    if wp_.IsPortal(exit) then
        return {
            index = exit:EntIndex(),
            valid = true,
            pos = exit:GetPos(),
            open = exit:GetOpen(),
            enable_teleport = exit:GetEnableTeleport(),
        }
    end
    if IsValid(exit) then
        return { index = exit:EntIndex(), valid = true, class = exit:GetClass() }
    end
    return nil
end

local function decode(prefix, value)
    local name = MCP.util.DecodeEnum and MCP.util.DecodeEnum(prefix, value)
    return name or value
end

-- Parent attach block: distinguishes an exterior portal (parented to a gmod_tardis / shell) from a
-- free-standing one, and carries the parent's motion + the portal's local-space offset -- so callers
-- stop hand-walking GetParent()/GetClass()/GetVelocity(). nil when the portal is unparented.
function wp_.ParentInfo(p)
    local par = p:GetParent()
    if not IsValid(par) then return nil end
    local out = {
        index = par:EntIndex(),
        class = par:GetClass(),
        velocity = par:GetVelocity(),
        speed = par:GetVelocity():Length(),
        local_pos = p:GetLocalPos(),
        local_angles = p:GetLocalAngles(),
    }
    local phys = par:GetPhysicsObject()
    if IsValid(phys) then out.angular_velocity = phys:GetAngleVelocity() end
    return out
end

-- The linked_portal_frame collision companion (SERVER only -- the Lua reference lives on the portal
-- server-side). This invisible 4-slab hull is what actually blocks/funnels transiting PROPS, and its
-- frame<->parent no-collide is what a SetThickness resize can orphan (a rebuilt physobj drops the old
-- pair). nil when there's no frame (a 0-size portal never builds one) or on the client.
function wp_.FrameInfo(p)
    if not SERVER then return nil end
    local f = p.CollisionFrame
    if not IsValid(f) then return nil end
    local phys = f:GetPhysicsObject()
    local nocollides = {}
    if istable(f.ParentNoCollides) then
        for parent, c in pairs(f.ParentNoCollides) do
            nocollides[#nocollides + 1] = {
                parent = IsValid(parent) and { index = parent:EntIndex(), class = parent:GetClass() } or nil,
                valid = IsValid(c),
            }
        end
    end
    local out = {
        index = f:EntIndex(),
        valid = true,
        pos = f:GetPos(),
        pos_drift = math.Round(f:GetPos():Distance(p:GetPos()), 3), -- frame follows the portal each tick (~0)
        movetype = decode("MOVETYPE_", f:GetMoveType()),
        collision_group = decode("COLLISION_GROUP_", f:GetCollisionGroup()),
        has_physics = IsValid(phys),
        pending_shadow = f.PendingShadow == true, -- still the frozen spawn hull, not yet the swept shadow
        obb_mins = f:OBBMins(),
        obb_maxs = f:OBBMaxs(),
        frame_border = f.FrameBorder,
        frame_min_depth = f.FrameMinDepth,
        parent_nocollides = nocollides, -- resize orphans one -> it shows valid=false / drops out
    }
    if IsValid(phys) then
        out.phys_pos_drift = math.Round(phys:GetPos():Distance(f:GetPos()), 3) -- shadow hull vs entity transform
        out.phys_asleep = phys:IsAsleep()
    end
    return out
end

-- The walk-up approach pose for player_walk: stand `standoff` units in front of the portal (on its
-- normal side) facing back into it, so walking forward crosses the plane against the normal and
-- triggers the teleport. Replaces the hand-rolled LocalToWorld+Forward*N / yaw+180 dance.
function wp_.ApproachInfo(p, standoff)
    local fwd = p:GetForward()
    local ang = (-fwd):Angle()
    return {
        standoff = standoff,
        point = p:GetPos() + fwd * standoff,
        yaw = ang.yaw,
        angles = Angle(0, ang.yaw, 0),
    }
end

-- Full structured snapshot. opts.approach_standoff (>0) adds the approach block.
function wp_.PortalState(p, opts)
    opts = opts or {}
    local exit = p:GetExit()
    local pname = p.GetPartnerName and p:GetPartnerName() or nil
    local render = {
        transparency = p:GetTransparency(),
        disappear_dist = p:GetDisappearDist(),
        zfar = p:GetZFar(),
        custom_model = p:GetCustomModel() ~= "" and p:GetCustomModel() or nil,
        custom_model_pos_offset = p:GetCustomModelPosOffset(),
        custom_model_ang_offset = p:GetCustomModelAngOffset(),
        false_world = p:GetFalseWorld() ~= "" and p:GetFalseWorld() or nil,
    }
    -- Opening box (the portal's own render/trigger slab, set in ENT:SetupBounds on both realms).
    if isvector(p.RenderMin) and isvector(p.RenderMax) then
        render.opening_bounds = { min = p.RenderMin, max = p.RenderMax }
        if istable(p.RenderQuads) then render.opening_quad_count = #p.RenderQuads end
    end

    local out = {
        ok = true,
        entindex = p:EntIndex(),
        valid = true,
        class = p:GetClass(),
        creation_id = p:GetCreationID(),
        owner = wp_.OwnerInfo(p),
        pos = p:GetPos(),
        angles = p:GetAngles(),
        size = {
            width = p:GetWidth(),
            height = p:GetHeight(),
            thickness = p:GetThickness(),
        },
        flags = {
            open = p:GetOpen(),
            enable_teleport = p:GetEnableTeleport(),
            inverted = p:GetInverted(),
        },
        render = render,
        link = {
            linked = wp_.IsPortal(exit),
            exit = wp_.ExitRef(exit),
            mutual = wp_.IsPortal(exit) and exit:GetExit() == p or false,
            exit_pos_offset = p:GetExitPosOffset(),
            exit_ang_offset = p:GetExitAngOffset(),
            partner_name = (pname ~= nil and pname ~= "") and pname or nil,
        },
        parent = wp_.ParentInfo(p),
        frame = wp_.FrameInfo(p),
    }
    if isnumber(opts.approach_standoff) and opts.approach_standoff > 0 then
        out.approach = wp_.ApproachInfo(p, opts.approach_standoff)
    end
    return out
end

-- Lean survey row + optional `fields` enrichment (angles/forward/exit_pos_offset/parent/
-- transparency/disappear_dist/custom_model/false_world).
function wp_.PortalRow(p, center, fields)
    local exit = p:GetExit()
    local row = {
        index = p:EntIndex(),
        pos = p:GetPos(),
        open = p:GetOpen(),
        enable_teleport = p:GetEnableTeleport(),
        width = p:GetWidth(),
        height = p:GetHeight(),
        linked = wp_.IsPortal(exit),
        exit_index = IsValid(exit) and exit:EntIndex() or nil,
        mutual = wp_.IsPortal(exit) and exit:GetExit() == p or false,
        has_custom_model = p:GetCustomModel() ~= "",
        has_false_world = p:GetFalseWorld() ~= "",
    }
    if center then row.distance = p:GetPos():Distance(center) end
    if istable(fields) then
        for _, f in ipairs(fields) do
            if f == "angles" then row.angles = p:GetAngles()
            elseif f == "forward" then row.forward = p:GetForward()
            elseif f == "exit_pos_offset" then row.exit_pos_offset = p:GetExitPosOffset()
            elseif f == "exit_ang_offset" then row.exit_ang_offset = p:GetExitAngOffset()
            elseif f == "transparency" then row.transparency = p:GetTransparency()
            elseif f == "disappear_dist" then row.disappear_dist = p:GetDisappearDist()
            elseif f == "custom_model" then row.custom_model = p:GetCustomModel() ~= "" and p:GetCustomModel() or nil
            elseif f == "false_world" then row.false_world = p:GetFalseWorld() ~= "" and p:GetFalseWorld() or nil
            elseif f == "parent" then
                local par = p:GetParent()
                if IsValid(par) then row.parent_index, row.parent_class = par:EntIndex(), par:GetClass() end
            end
        end
    end
    return row
end

function wp_.AllPortals()
    local list = {}
    if istable(wp) and istable(wp.portals) then
        for _, p in ipairs(wp.portals) do
            if wp_.IsPortal(p) then list[#list + 1] = p end
        end
    end
    if #list == 0 then
        list = ents.FindByClass(PORTAL_CLASS)
    end
    return list
end
