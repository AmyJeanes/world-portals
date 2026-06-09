AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")

include("shared.lua")

-- Per-tick portal move above which we SNAP the hull instead of sweeping it (a
-- single-tick warp can't be swept). Mirrors ComputeShadowControl's teleportdistance.
local SHADOW_TELEPORT_DIST = 128

-- Eight corners of an axis-aligned box in this entity's local space.
local function boxVerts(x0, x1, y0, y1, z0, z1)
    return {
        Vector(x0, y0, z0), Vector(x1, y0, z0), Vector(x0, y1, z0), Vector(x1, y1, z0),
        Vector(x0, y0, z1), Vector(x1, y0, z1), Vector(x0, y1, z1), Vector(x1, y1, z1),
    }
end

function ENT:Initialize()
    self:SetMoveType(MOVETYPE_NONE)
    self:DrawShadow(false)
    self:SetNoDraw(true)
end

-- (Re)build the collision hull from the portal opening dimensions. Calling again
-- replaces the previous physics object.
function ENT:BuildFrame(width, height, thickness)
    local slabs = self:FrameSlabs(width, height, thickness)
    if not slabs then
        self:PhysicsDestroy()
        return false
    end

    local meshes = {}
    for _, s in ipairs(slabs) do
        meshes[#meshes + 1] = boxVerts(s[1], s[2], s[3], s[4], s[5], s[6])
    end

    self:SetSolid(SOLID_VPHYSICS)
    self:PhysicsInitMultiConvex(meshes)
    -- COLLISION_GROUP_WEAPON hits world+props but not players, so the frame funnels
    -- props without changing player movement.
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)

    if not IsValid(self:GetPhysicsObject()) then return false end
    -- Drive the hull as an immovable physics SHADOW (both flags false): external
    -- forces never displace it, yet a swept UpdateShadow each tick pushes props
    -- along instead of teleporting past them.
    self:MakePhysicsObjectAShadow(false, false)
    local phys = self:GetPhysicsObject()
    if not IsValid(phys) then return false end
    phys:SetMass(50000)
    self:SetMoveType(MOVETYPE_NONE)

    -- The new physobj defaults to colliding - constraint.NoCollide fires its
    -- disable once and never reapplies - so re-add the frame<->parent no-collide
    -- or the immovable shadow shoves the parent.
    if self.ParentNoCollides then
        for _, c in pairs(self.ParentNoCollides) do
            if IsValid(c) then c:Remove() end
        end
        self.ParentNoCollides = nil
    end
    wp.NoCollideFrame(self, self.Portal)
    return true
end

-- Follow the portal WITHOUT being parented, driving both the entity transform and
-- the physics hull from here each tick. Not parented because the prop<->parent
-- no-collide would disable the prop against the parent's whole parented subtree, so
-- a parented frame would be phased the instant a prop armed (sv_collision.lua).
function ENT:Think()
    local portal = self.Portal
    if not IsValid(portal) then
        self:Remove()
        return
    end
    local pos, ang = portal:GetPos(), portal:GetAngles()
    if self:GetPos() ~= pos or self:GetAngles() ~= ang then
        self:SetPos(pos)
        self:SetAngles(ang)
    end
    -- Sweep the shadow hull toward the portal so a moving portal pushes props
    -- along with it; snap instead for a single-tick warp (SHADOW_TELEPORT_DIST).
    -- The drift check sweeps while it catches up, leaves it free once converged.
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        local last = self.LastShadowTarget
        if (not last) or pos:Distance(last) > SHADOW_TELEPORT_DIST then
            phys:SetPos(pos)
            phys:SetAngles(ang)
        elseif not phys:GetPos():IsEqualTol(pos, 0.05) or phys:GetAngles() ~= ang then
            phys:Wake()
            phys:UpdateShadow(pos, ang, FrameTime())
        end
        self.LastShadowTarget = pos
    end
    -- Keep the (unparented) hull no-collided with its parent, so it doesn't
    -- interpenetrate the parent and shove it away. Low-frequency re-check picks up
    -- the parent once the portal is parented to it and any parts added later.
    local now = CurTime()
    if not self.NextParentCheck or now >= self.NextParentCheck then
        self.NextParentCheck = now + 1
        wp.NoCollideFrame(self, portal)
    end
    self:NextThink(CurTime())
    return true
end
