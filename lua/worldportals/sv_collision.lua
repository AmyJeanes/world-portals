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

-- What a transiting prop may phase through: the portal's parent +
-- constraint network + whatever wp-nocollide returns, but only those that opt in
-- with `ent.PortalNoCollide == true`. Opt-in (default-solid) is deliberate - a
-- missed flag just jams the prop (recoverable), never drops it into the void.
-- Never the portal/frame/prop, and only entities with a physics object.
local function gatherParentSolids(portal, ent)
    local solids, seen = {}, {}
    local function consider(e)
        if not IsValid(e) or seen[e] then return end
        if e == ent or e.WPIsGhost then return end
        local cls = e:GetClass()
        if cls == "linked_portal_door" or cls == "linked_portal_frame" then return end
        seen[e] = true
        if e.PortalNoCollide == true and IsValid(e:GetPhysicsObject()) then
            solids[#solids + 1] = e
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
    return solids
end

-- The frame's solid hull overlaps the parent (both occupy the doorway), so without a
-- no-collide between them the physics solver shoves the parent away. Maintain that
-- frame<->parent no-collide. Idempotent, so safe to re-run - BuildFrame recreates the
-- physobj and orphans the old one, and the parent can appear late.
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

-- Arm the pass-through for `ent`: no-collide it with the portal's parent solids so
-- it phases through instead of jamming on the parent. Idempotent - a no-op if the
-- pair is already armed, so it's safe to call every Touch tick.
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
    for _, s in ipairs(gatherParentSolids(portal, ent)) do
        local c = constraint.NoCollide(ent, s, 0, 0, true)
        if IsValid(c) then
            cons[#cons + 1] = c
        end
    end
    recs[portal] = { constraints = cons }
end

-- Restore collision by removing each pair.
local function releaseConstraints(rec)
    for _, c in ipairs(rec.constraints) do
        if IsValid(c) then c:Remove() end
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
-- removed) so the parent goes solid again for those props.
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
