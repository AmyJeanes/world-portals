-- Portal-aware collision for transiting props.
--
-- A portal is usually mounted flush against a solid entity (a TARDIS exterior
-- shell, its door parts, an interior back wall). The teleport only fires once a
-- prop's centre crosses the portal plane (init.lua ENT:Touch), so a decent-sized
-- prop pushed at the portal jams on that wall before it can cross. While a prop
-- is touching an open teleport-enabled portal we no-collide it with the wall
-- entities (via constraint.NoCollide), so it passes through instead of jamming.
-- The portal's collision frame (linked_portal_frame) keeps it funnelled through
-- the opening cross-section while the wall is "removed" for it.
--
-- Arming is driven by the portal's trigger Touch (the portal is a SetTrigger
-- entity), not a per-tick proximity scan: Touch is event-driven and only fires
-- for entities actually overlapping the doorway, which is far cheaper on a base
-- addon everything sits on. Touch (not StartTouch) so a portal that opens around
-- an already-present prop still arms it.
--
-- The clones (cl_clones.lua) make this read continuously; this file is the
-- physics half. There is intentionally NO collidable clone: a clientside entity
-- can't block server props and there's no per-face collision carving, so we make
-- the real prop pass through the wall rather than fake a solid ghost.

if not SERVER then return end

wp.nocollide = wp.nocollide or {}   -- [ent] = { [portal] = { constraints = {} } }

-- Is ent something we should pass through the wall for this portal?
local function eligible(ent, portal)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() then return false end
    if ent.WPIsClone then return false end
    local cls = ent:GetClass()
    if cls == "linked_portal_door" or cls == "linked_portal_frame" then return false end
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

-- The wall entities a transiting prop should pass through: candidates are the
-- portal's parent + that parent's children/constraint network, unioned with
-- whatever the wp-nocollide consumer hook returns -- but a candidate is only
-- actually no-collided if it OPTS IN with `ent.PortalNoCollide == true`.
--
-- Opt-in (default solid) is deliberate: a portal's parent can be a large interior
-- model, and no-colliding it by default would let a transiting prop fall through
-- the whole interior into the void. So the consumer explicitly flags exactly what
-- should be phased -- the shell the portal is mounted on, the entry wall -- and
-- everything else (floor, decor, the interior model itself) stays solid. A missed
-- flag just jams the prop (recoverable); it can never drop it into the world.
-- Never the portal or its frame (the frame must keep bounding the prop) nor the
-- prop itself, and only entities with a physics object (NoCollide needs one).
local function gatherWalls(portal, ent)
    local walls, seen = {}, {}
    local function consider(e)
        if not IsValid(e) or seen[e] then return end
        if e == ent or e.WPIsClone then return end
        local cls = e:GetClass()
        if cls == "linked_portal_door" or cls == "linked_portal_frame" then return end
        seen[e] = true
        if e.PortalNoCollide == true and IsValid(e:GetPhysicsObject()) then
            walls[#walls + 1] = e
        end
        -- recurse children regardless: a child may opt in even if the parent didn't
        for _, c in ipairs(e:GetChildren()) do
            consider(c)
        end
    end

    local parent = portal:GetParent()
    if IsValid(parent) then
        consider(parent)
        for _, v in pairs(constraint.GetAllConstrainedEntities(parent) or {}) do
            consider(v)
        end
    end

    local extra = hook.Call("wp-nocollide", GAMEMODE, portal, ent)
    if istable(extra) then
        for _, e in ipairs(extra) do
            consider(e)
        end
    end
    return walls
end

-- Permanently no-collide a collision FRAME with the wall it sits flush against (the
-- portal's parent + that parent's network). The frame is intentionally UNPARENTED
-- (so the transit no-collide can't propagate into it), which means it no longer gets
-- the free parent<->child no-collision it had when parented -- so its solid hull
-- interpenetrates the TARDIS shell and the physics solver launches the whole TARDIS.
-- This restores that no-collision explicitly. It does NOT affect prop<->frame: the
-- pair is frame<->wall, and neither the prop nor the frame is a parented descendant
-- of the other, so transiting props still collide with the frame.
--
-- Re-runnable and idempotent per wall: only creates a pair for a wall not already
-- handled, so it's cheap to call periodically (the wall set can change late -- the
-- portal is parented to the shell after frame creation, parts are added, demat/remat).
-- DeleteOnRemove ties each pair's lifetime to the frame; permanent otherwise.
function wp.NoCollideFrame(frame, portal)
    if not (IsValid(frame) and IsValid(portal)) then return end
    -- ONLY the portal's parent (the wall/shell the frame sits in). Source propagates a
    -- NoCollide down the parent's entire parented subtree, so this one pair also covers
    -- every part parented under the shell -- equivalent to the free parent<->child
    -- no-collision the frame had when it was itself parented. We must NOT walk the
    -- constraint network (gatherWalls) here: constraint.GetAllConstrainedEntities
    -- includes logic_collision_pair links, so an ARMED transiting prop (no-collided
    -- with the shell) shows up there, and the frame would then wrongly no-collide the
    -- prop -- so the frame stops bounding it AND that no-collide outlives the prop's
    -- shell-arm. Parent-only sidesteps the whole feedback loop.
    local wall = portal:GetParent()
    if not IsValid(wall) then return end   -- free-standing portal: no wall to phase
    frame.WallNoCollides = frame.WallNoCollides or {}
    if not IsValid(frame.WallNoCollides[wall]) then
        local c = constraint.NoCollide(frame, wall, 0, 0)
        if IsValid(c) then
            frame.WallNoCollides[wall] = c
            frame:DeleteOnRemove(c)
        end
    end
end

-- Pass `ent` through the wall entities of `portal`. Idempotent: a no-op if the
-- pair is already armed, so it's safe to call every Touch tick.
function wp.ArmNoCollide(portal, ent)
    if not (IsValid(portal) and IsValid(ent)) then return end

    -- Already-armed check BEFORE eligible(): once we no-collide the prop with the
    -- wall, the prop shows up in the wall's constraint network (NoCollide registers
    -- there), which would make eligible()'s contraption check falsely reject the
    -- re-arm. Checking armed first means eligible() only runs on the clean network
    -- at the first arm, so its contraption guard stays correct.
    local recs = wp.nocollide[ent]
    if recs and recs[portal] then return end
    if not eligible(ent, portal) then return end
    if not recs then
        recs = {}
        wp.nocollide[ent] = recs
    end

    local cons = {}
    for _, w in ipairs(gatherWalls(portal, ent)) do
        local c = constraint.NoCollide(ent, w, 0, 0)
        if IsValid(c) then
            cons[#cons + 1] = c
        end
    end
    recs[portal] = { constraints = cons }
end

-- Restore collision for the pairs a rec disabled. CRITICAL: removing a
-- logic_collision_pair does NOT re-enable collision -- the VPhysics pair-disable
-- persists, so a bare :Remove() silently leaves the entities ghosting forever.
-- Firing EnableCollisions restores it, and the enable sticks once the pair is
-- removed; we remove it the next frame (removing it the same frame drops the
-- still-queued input before it processes).
local function releaseConstraints(rec)
    for _, c in ipairs(rec.constraints) do
        if IsValid(c) then
            c:Fire("EnableCollisions", "", 0)
            timer.Simple(0, function() if IsValid(c) then c:Remove() end end)
        end
    end
end

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

function wp.DisarmAllNoCollide(ent)
    local recs = wp.nocollide[ent]
    if not recs then return end
    for _, rec in pairs(recs) do
        releaseConstraints(rec)
    end
    wp.nocollide[ent] = nil
end

-- Disarm everything armed against a portal (it closed, disabled teleport, or was
-- removed) so the wall goes solid again for those props.
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
    -- ...or it was a portal something was armed against (harmless otherwise).
    wp.DisarmPortal(ent)
end)

hook.Add("PostCleanupMap", "WorldPortals_Collision", function()
    -- Entities (and their constraints) are gone; just drop our bookkeeping.
    wp.nocollide = {}
end)

-- Safety net: disarm anything that has gone invalid or drifted well away from its
-- portal, in case an EndTouch was ever missed. Low frequency, and only iterates the
-- (few) currently-armed entries -- NOT a world scan. This is what would have caught
-- the runaway accumulation before it ghosted the whole structure.
timer.Create("WorldPortals_CollisionSweep", 2, 0, function()
    local stale
    for ent, recs in pairs(wp.nocollide) do
        for portal in pairs(recs) do
            local drop = not IsValid(ent) or not IsValid(portal)
            if not drop then
                local center = ent:LocalToWorld(ent:OBBCenter())
                if center:Distance(portal:GetPos()) > portal:BoundingRadius() + 256 then
                    drop = true
                end
            end
            if drop then
                stale = stale or {}
                stale[#stale + 1] = { ent, portal }
            end
        end
    end
    if stale then
        for _, s in ipairs(stale) do
            wp.DisarmNoCollide(s[1], s[2])
        end
    end
end)
