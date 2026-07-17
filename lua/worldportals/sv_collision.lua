-- Collision

-- Portal-aware collision for transiting props. A portal is parented to a solid
-- structure (e.g. a shell) and you cross through an opening in it. The non-player
-- teleport only fires once a prop's centre crosses the portal plane, so a decent-
-- sized prop jams on the parent before its centre can get there. While a dynamic
-- prop touches an open teleport-enabled portal we no-collide it with the parent's
-- solids (constraint.NoCollide) so it passes through; the collision frame
-- (linked_portal_frame) keeps it funnelled through the opening. Armed from the
-- portal's trigger Touch (event-driven, cheap).

if not SERVER then return end

wp.nocollide = wp.nocollide or {}   -- [ent] = { [portal] = { constraints = {}, lastPos = Vector } }

-- Is ent something we should pass through the parent for this portal?
---@param ent Entity
---@param portal linked_portal_door
local function eligible(ent, portal)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() then return false end
    if ent.WPIsGhost then return false end
    if wp.IsPortalEntity( ent ) then return false end
    if not IsValid(ent:GetPhysicsObject()) then return false end

    -- Contraption guard: don't disturb a prop that rides the portal's parent
    -- (mirrors the same check in ENT:Touch).
    local parent = portal:GetParent()
    if IsValid(parent) then
        for _, v in pairs(constraint.GetAllConstrainedEntities(parent) or {}) do
            if v == ent then return false end
        end
    end
    return true
end

---@class wp.ConstraintEnt
---@field Entity Entity
---@field World boolean

---@class wp.Constraint
---@field Type string
---@field Entity wp.ConstraintEnt[]

-- Cache each walk - a welded contraption straddling a portal holds steady as it crosses, so
-- re-walking it (a constraint.GetTable + wp-shouldtp per member) every tick and scan is waste.
-- Cleared when a constraint (phys_*) is added or removed - the only thing that shifts membership.
---@type table<linked_portal_door, table<Entity, Entity[]|false>>
local groupCache = {}   -- [portal][member] = the member's group, or false for a cached veto
hook.Add("OnEntityCreated", "WorldPortals_GroupCache", function(ent)
    if ent:GetClass():sub(1, 5) == "phys_" then groupCache = {} end
end)
hook.Add("EntityRemoved", "WorldPortals_GroupCache", function(ent)
    if ent:GetClass():sub(1, 5) == "phys_" then groupCache = {} end
end)

-- Walk `startEnt`'s constraint network over rigid edges (skipping NoCollide) and return every
-- member with a physics object, so a contraption teleports as one rigid body. Returns nil to veto
-- the whole move if the group is anchored to the world or map machinery, rides the portal,
-- or a member fails wp-shouldtp - a partial move would snap it.
---@param startEnt Entity
---@param portal linked_portal_door
---@return Entity[]?
local function walkRigidGroup(startEnt, portal)
    local group, seen = {}, {}
    local stack = { startEnt }
    seen[startEnt] = true
    while #stack > 0 do
        local e = stack[#stack]
        stack[#stack] = nil

        if wp.RidesPortal(e, portal) then return nil end
        if hook.Call("wp-shouldtp", GAMEMODE, portal, e) == false then return nil end

        if not wp.IsPortalEntity( e ) then
            -- A physics shadow makes a brush/scripted mover (func_door) look constrainable,
            -- but it's map machinery - same bucket as a world anchor: veto, don't derail it.
            if not wp.IsPhysicalMover(e) then return nil end
            if IsValid(e:GetPhysicsObject()) then
                group[#group + 1] = e
            end
            for _, con in ipairs(constraint.GetTable(e)) do
                ---@cast con wp.Constraint
                -- Skip NoCollide edges: they bind no relative motion, and our own pass-through
                -- no-collides would otherwise bridge the mount into the set.
                if con.Type ~= "NoCollide" then
                    for _, info in pairs(con.Entity) do
                        -- A constraint end pinned to the map (GetAllConstrainedEntities hides
                        -- these) - can't move the world, so veto.
                        if info.World then return nil end
                        local n = info.Entity
                        -- Never walk into a player (they teleport only via the predicted
                        -- SetupMove path), so a player-roped prop keeps its per-body crossing.
                        if IsValid(n) and not seen[n] and not n:IsPlayer() then
                            seen[n] = true
                            stack[#stack + 1] = n
                        end
                    end
                end
            end
        end
    end
    return group
end

-- Serve `startEnt`'s group from the cache when its membership hasn't changed, else walk it and
-- cache the result under every member, so a later call from any of them hits without re-walking.
---@param startEnt Entity
---@param portal linked_portal_door
---@return Entity[]?
function wp.GatherRigidGroup(startEnt, portal)
    local pc = groupCache[portal]
    if not pc then pc = {}; groupCache[portal] = pc end

    local cached = pc[startEnt]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local group = walkRigidGroup(startEnt, portal)
    if group then
        for _, m in ipairs(group) do pc[m] = group end
    else
        pc[startEnt] = false
    end
    return group
end

-- The solids a transiting prop may phase, from the wp-nocollide hook - a consumer's
-- structure isn't always engine-parented to the portal, so we can't discover it.
---@param portal linked_portal_door
---@param ent Entity
local function gatherPhaseSolids(portal, ent)
    local extra = hook.Call("wp-nocollide", GAMEMODE, portal, ent)
    if not istable(extra) then return {} end
    local solids, seen = {}, {}
    for _, e in ipairs(extra) do
        if IsValid(e) and not seen[e] and e ~= ent and not e.WPIsGhost then
            if not wp.IsPortalEntity( e ) and IsValid(e:GetPhysicsObject()) then
                seen[e] = true
                solids[#solids + 1] = e
            end
        end
    end
    return solids
end

-- The frame's solid hull overlaps the parent (both occupy the doorway), so without a
-- no-collide between them the physics solver shoves the parent away. Maintain that
-- frame<->parent no-collide. Idempotent, so safe to re-run - BuildFrame recreates the
-- physobj and orphans the old one, and the parent can appear late.
---@param frame Entity
---@param portal linked_portal_door
function wp.NoCollideFrame(frame, portal)
    if not (IsValid(frame) and IsValid(portal)) then return end
    -- ONLY the portal's parent: Source propagates the NoCollide down its whole
    -- parented subtree, covering every part. Walking the constraint network would
    -- pull in an armed transiting prop (it shows up via logic_collision_pair) and
    -- make the frame wrongly stop bounding it - parent-only avoids that loop.
    local parent = portal:GetParent()
    if not IsValid(parent) then return end   -- free-standing portal: nothing to phase
    frame.ParentNoCollides = frame.ParentNoCollides or {}
    if not IsValid(frame.ParentNoCollides[parent]) then
        local c = constraint.NoCollide(frame, parent, 0, 0)
        if IsValid(c) then
            frame.ParentNoCollides[parent] = c
            frame:DeleteOnRemove(c)
        end
    end
end

-- Arm the pass-through for `ent`: no-collide it with the solids wp-nocollide names so
-- it phases through instead of jamming on the structure. Idempotent - a no-op if the
-- pair is already armed, so it's safe to call every Touch tick.
---@param portal linked_portal_door
---@param ent Entity
function wp.ArmNoCollide(portal, ent)
    if not (IsValid(portal) and IsValid(ent)) then return end

    -- Check already-armed before eligible(): a no-collide counts as a constraint, so
    -- an armed prop would fail eligible() on re-arm.
    local recs = wp.nocollide[ent]
    if recs and recs[portal] then return end
    if not eligible(ent, portal) then return end
    if not recs then
        recs = {}
        wp.nocollide[ent] = recs
    end

    local cons = {}
    for _, s in ipairs(gatherPhaseSolids(portal, ent)) do
        local c = constraint.NoCollide(ent, s, 0, 0, true)
        if IsValid(c) then
            cons[#cons + 1] = c
        end
    end
    recs[portal] = { constraints = cons }
end

-- Restore collision by removing each pair.
---@param rec {constraints: Entity[], lastPos: Vector?}
local function releaseConstraints(rec)
    for _, c in ipairs(rec.constraints) do
        if IsValid(c) then c:Remove() end
    end
end

---@param ent Entity
---@param portal linked_portal_door
function wp.DisarmNoCollide(ent, portal)
    local recs = wp.nocollide[ent]
    if not recs then return end
    local rec = recs[portal]
    if rec then
        releaseConstraints(rec)
        recs[portal] = nil
    end
    if not next(recs) then
        wp.nocollide[ent] = nil
    end
end

---@param ent Entity
function wp.DisarmAllNoCollide(ent)
    local recs = wp.nocollide[ent]
    if not recs then return end
    for _, rec in pairs(recs) do
        releaseConstraints(rec)
    end
    wp.nocollide[ent] = nil
end

-- Disarm everything armed against a portal (it closed, disabled teleport, or was
-- removed) so the parent goes solid again for those props.
---@param portal Entity
function wp.DisarmPortal(portal)
    local victims
    for ent, recs in pairs(wp.nocollide) do
        if recs[portal] then
            victims = victims or {}
            victims[#victims + 1] = ent
        end
    end
    if victims then
        for _, ent in ipairs(victims) do
            wp.DisarmNoCollide(ent, portal)
        end
    end
end

hook.Add("EntityRemoved", "WorldPortals_Collision", function(ent)
    -- The removed entity itself was being passed through something.
    if wp.nocollide[ent] then wp.DisarmAllNoCollide(ent) end
    -- The removed entity was a portal - disarm everything passing through it.
    if ent:GetClass() == "linked_portal_door" then wp.DisarmPortal(ent) end
end)

hook.Add("PostCleanupMap", "WorldPortals_Collision", function()
    wp.nocollide = {}
end)

-- A sleeping prop isn't re-tested by triggers, so a portal moving out from under one
-- never fires its EndTouch and the no-collide would linger. Wake an armed prop when
-- its portal moves; the trigger then re-evaluates and EndTouch disarms it once clear.
hook.Add("Tick", "WorldPortals_CollisionWake", function()
    if not next(wp.nocollide) then return end
    for ent, recs in pairs(wp.nocollide) do
        local phys = IsValid(ent) and ent:GetPhysicsObject()
        for portal, rec in pairs(recs) do
            if IsValid(portal) then
                local pos = portal:GetPos()
                if rec.lastPos and rec.lastPos ~= pos and IsValid(phys) and phys:IsAsleep() then
                    phys:Wake()
                end
                rec.lastPos = pos
            end
        end
    end
end)
