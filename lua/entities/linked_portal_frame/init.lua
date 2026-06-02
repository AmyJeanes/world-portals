AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")

include("shared.lua")

-- Per-tick portal displacement above which we SNAP the hull to the portal instead
-- of sweeping it as a shadow. A continuous flight moves the portal a handful of
-- units per tick (well under this), so it sweeps and pushes props; a TARDIS
-- demat/remat warp relocates it thousands of units in a single tick, which no
-- shadow can sweep across -- there's no "push" possible through an instant jump --
-- so we teleport the hull, mirroring ComputeShadowControl's teleportdistance.
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

-- (Re)build the perimeter-frame collision hull from the portal opening
-- dimensions. Verts are in this entity's local space; parented at the portal
-- with no offset, that equals the portal's local space: +x forward/transit,
-- y the width axis, z the height axis (matching shared.lua SetupBounds, where
-- the opening box is x in [-(5+thickness), -5], y in +-width/2, z in +-height/2).
-- Calling again replaces the previous physics object.
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
    -- No EnableCustomCollisions: we only need physics-vs-physics collision (a prop
    -- bumping a slab), which VPHYSICS handles natively -- verified a prop rests on
    -- the hull without it. ECC forces FSOLID_CUSTOM*TEST (every ray/box test routed
    -- through custom paths, expensive) and would also make this invisible frame
    -- block bullets/use traces, which we don't want.
    -- COLLISION_GROUP_WEAPON collides with world and props but not players, so the
    -- frame funnels props without altering player movement.
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)

    if not IsValid(self:GetPhysicsObject()) then return false end
    -- Drive the hull as an immovable physics SHADOW rather than a frozen static body.
    -- Both flags false => external forces never displace it (a prop bumping the doorway
    -- can't shove the TARDIS's frame around), yet UpdateShadow (ENT:Think) can still
    -- sweep it toward the portal each tick -- and a SWEPT shadow PUSHES props in its
    -- path instead of teleporting through them. So when the portal moves (a flying
    -- TARDIS), the doorway carries props out of the way. A static EnableMotion(false)
    -- hull SetPos'd each tick instead teleported past props and flung them (verified
    -- A/B: shadow sweep pushed a crate cleanly; SetPos ejected it backwards).
    self:MakePhysicsObjectAShadow(false, false)
    local phys = self:GetPhysicsObject()
    if not IsValid(phys) then return false end
    phys:SetMass(50000)
    self:SetMoveType(MOVETYPE_NONE)
    return true
end

-- Follow the portal WITHOUT being parented to it, and keep the physics hull pinned
-- to that transform.
--
-- Why not parent: while a prop transits we no-collide it with the wall the portal
-- is mounted on (the TARDIS shell etc., sv_collision.lua). A logic_collision_pair
-- that disables prop<->shell collision ALSO disables the prop against every entity
-- parented under that shell. If the frame were parented to the portal (itself
-- parented to the shell) the prop would phase the frame the instant it armed --
-- exactly the "loses collision with the frame as soon as it enters" bug. Keeping
-- the frame unparented takes it out of that hierarchy so the no-collide can't reach
-- it (verified: an unparented frame still blocks a prop no-collided with the shell).
--
-- The cost of not parenting: nothing moves the frame for us. A shadow hull doesn't
-- track anything on its own anyway, so we drive BOTH the entity transform (so the
-- networked position + client debug overlay follow) and the hull (via UpdateShadow,
-- which sweeps + pushes) from the portal here each tick. The drift guard keeps it
-- free when the portal is stationary. (This also subsumes the moving-parent
-- stranded-hull case.)
function ENT:Think()
    local portal = self.Portal
    if not IsValid(portal) then
        -- Portal gone independently of our OnRemove path; nothing to bound.
        self:Remove()
        return
    end
    local pos, ang = portal:GetPos(), portal:GetAngles()
    if self:GetPos() ~= pos or self:GetAngles() ~= ang then
        self:SetPos(pos)
        self:SetAngles(ang)
    end
    -- Sweep the physics hull toward the portal as a shadow (BuildFrame made it one),
    -- so a MOVING portal PUSHES props in the doorway along with it instead of the
    -- old SetPos snap teleporting the hull past them. UpdateShadow drives the hull
    -- while leaving collision intact. A large single-tick jump (a demat/remat warp)
    -- can't be swept, so snap the hull for that -- see SHADOW_TELEPORT_DIST. The
    -- drift check (hull not yet at the portal) keeps sweeping while it catches up and
    -- leaves it free once converged at a stationary portal.
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
    -- Keep the (unparented) hull no-collided with the wall it sits in, so it doesn't
    -- interpenetrate the TARDIS shell and launch it. Low-frequency re-check picks up
    -- the shell once the portal is parented to it and any parts added later.
    local now = CurTime()
    if not self.NextWallCheck or now >= self.NextWallCheck then
        self.NextWallCheck = now + 1
        wp.NoCollideFrame(self, portal)
    end
    self:NextThink(CurTime())
    return true
end
