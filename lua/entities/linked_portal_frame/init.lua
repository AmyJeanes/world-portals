AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")

include("shared.lua")

-- Per-tick portal move above which we SNAP the hull instead of sweeping it (a
-- single-tick warp can't be swept). Mirrors ComputeShadowControl's teleportdistance.
local SHADOW_TELEPORT_DIST = 128

-- Eight corners of an axis-aligned box in this entity's local space.
---@param x0 number
---@param x1 number
---@param y0 number
---@param y1 number
---@param z0 number
---@param z1 number
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
---@param width number?
---@param height number?
---@param thickness number?
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
    -- Funnels props through the opening, passes players, and blocks bullet/use traces - and passes
    -- PLAYER_MOVEMENT, the collision group NPC pathfinding traces use, so NPC nav routes through.
    self:SetCollisionGroup(COLLISION_GROUP_INTERACTIVE_DEBRIS)

    local phys = self:GetPhysicsObject()
    if not IsValid(phys) then return false end

    -- Build a frozen static body, not a shadow yet: a shadow built overlapping the
    -- parent (the hull sits in its doorway) is force-ejected by the engine's spawn-tick
    -- stuck-push, which ignores the no-collide and flings the parent. Think promotes it
    -- to the swept shadow one tick later, past that push.
    phys:EnableMotion(false)
    phys:SetMass(50000)
    self:SetMoveType(MOVETYPE_NONE)
    self.PendingShadow = true

    -- Re-add the frame<->parent no-collide: a rebuild recreates the physobj and orphans
    -- the old pair, and the pair fires its disable only once.
    if self.ParentNoCollides then
        for _, c in pairs(self.ParentNoCollides) do
            if IsValid(c) then c:Remove() end
        end
        self.ParentNoCollides = nil
    end
    wp.NoCollideFrame(self, self.Portal)
    if self.CollisionEnabled == false then self:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE) end
    return true
end

---@param enabled boolean
function ENT:SetCollisionEnabled(enabled)
    self.CollisionEnabled = enabled
    self:SetCollisionGroup(enabled and COLLISION_GROUP_INTERACTIVE_DEBRIS or COLLISION_GROUP_IN_VEHICLE)
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
    -- Portal unmoved and hull converged: the shadow controller holds a
    -- converged hull at its target on its own, so skip the pose and physics work.
    if self.WPSettled and pos == self.LastShadowTarget
        and ang.p == self.WPLastAngP and ang.y == self.WPLastAngY and ang.r == self.WPLastAngR then
        local now = CurTime()
        if not self.NextParentCheck or now >= self.NextParentCheck then
            self.NextParentCheck = now + 1
            wp.NoCollideFrame(self, portal)
        end
        self:NextThink(now)
        return true
    end
    self.WPSettled = false
    if self:GetPos() ~= pos or self:GetAngles() ~= ang then
        self:SetPos(pos)
        self:SetAngles(ang)
    end
    -- Sweep the shadow hull toward the portal so a moving portal pushes props
    -- along with it; snap instead for a single-tick warp (SHADOW_TELEPORT_DIST).
    -- The drift check sweeps while it catches up, leaves it free once converged.
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        -- Promote the frozen spawn hull to the swept shadow, one tick past the
        -- spawn-tick stuck-push that flings the parent if it builds as a shadow.
        if self.PendingShadow then
            self:MakePhysicsObjectAShadow(false, false)
            phys = self:GetPhysicsObject()
            if IsValid(phys) then phys:SetMass(50000) end
            self.PendingShadow = false
            self.LastShadowTarget = nil
        end
    end
    if IsValid(phys) then
        local last = self.LastShadowTarget
        -- Wrap-aware angle compare: the hull can report an equivalent wrapped
        -- angle (roll 360 vs 0), which exact Angle equality would re-sweep forever.
        local pang = phys:GetAngles()
        local angConverged = math.abs(math.AngleDifference(pang.p, ang.p)) < 0.05
            and math.abs(math.AngleDifference(pang.y, ang.y)) < 0.05
            and math.abs(math.AngleDifference(pang.r, ang.r)) < 0.05
        if (not last) or pos:Distance(last) > SHADOW_TELEPORT_DIST then
            phys:SetPos(pos)
            phys:SetAngles(ang)
        elseif not phys:GetPos():IsEqualTol(pos, 0.05) or not angConverged then
            phys:Wake()
            phys:UpdateShadow(pos, ang, FrameTime())
        else
            self.WPSettled = true
        end
        self.LastShadowTarget = pos
        self.WPLastAngP, self.WPLastAngY, self.WPLastAngR = ang.p, ang.y, ang.r
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
