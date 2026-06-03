-- Collision

-- Portal-aware collision for transiting props. A portal is usually mounted flush
-- against a solid (a TARDIS shell), so a decent-sized prop jams on that wall
-- before its centre can cross the plane. While a dynamic prop touches an open
-- teleport-enabled portal we no-collide it with the wall (constraint.NoCollide)
-- so it passes through; the collision frame (linked_portal_frame) keeps it
-- funnelled through the opening. Armed from the portal's trigger Touch (event-
-- driven, cheap). No collidable ghost — clientside can't block server props.

if not SERVER then return end

wp.nocollide = wp.nocollide or {}   -- [ent] = { [portal] = { constraints = {} } }

-- Is ent something we should pass through the wall for this portal?
local function eligible(ent, portal)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() then return false end
    if ent.WPIsGhost then return false end
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

-- Wall entities a transiting prop passes through: the portal's parent +
-- constraint network + whatever wp-nocollide returns, but only those that opt in
-- with `ent.PortalNoCollide == true`. Opt-in (default-solid) is deliberate — a
-- missed flag just jams the prop (recoverable), never drops it into the void.
-- Never the portal/frame/prop, and only entities with a physics object.
local function gatherWalls(portal, ent)
    local walls, seen = {}, {}
    local function consider(e)
        if not IsValid(e) or seen[e] then return end
        if e == ent or e.WPIsGhost then return end
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

-- Restore the frame<->wall no-collision the unparented frame lost (else its solid
-- hull interpenetrates the shell and the solver launches the TARDIS). Doesn't
-- touch prop<->frame, so transiting props still collide with the frame.
-- Idempotent per wall, so cheap to re-run as the wall set changes late.
function wp.NoCollideFrame(frame, portal)
    if not (IsValid(frame) and IsValid(portal)) then return end
    -- ONLY the portal's parent: Source propagates the NoCollide down its whole
    -- parented subtree, covering every part. Walking the constraint network would
    -- pull in an armed transiting prop (it shows up via logic_collision_pair) and
    -- make the frame wrongly stop bounding it — parent-only avoids that loop.
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

    -- Already-armed check BEFORE eligible(): the NoCollide registers the prop in
    -- the wall's constraint network, which would fail eligible()'s contraption
    -- guard on re-arm. Checking armed first keeps that guard on the clean network.
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

-- Restore collision. CRITICAL: removing a logic_collision_pair does NOT re-enable
-- collision (a bare :Remove() ghosts the pair forever) — fire EnableCollisions,
-- then remove next frame (same-frame removal drops the queued input).
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

-- Safety net: disarm anything gone invalid or drifted from its portal, in case an
-- EndTouch was missed. Only iterates the few armed entries, not a world scan.
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
