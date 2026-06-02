-- Continuous entity rendering across portals ("portal ghosts").
--
-- An entity physically straddles a portal's plane for a short window before the
-- teleport fires (props: server ENT:Touch; players: predicted SetupMove). The
-- already-crossed half is otherwise visually cut off: eaten by the portal hole
-- on the entry side, and popping out of nothing (you see its backfaces) on the
-- exit side. We render the straddling entity as TWO clipped halves so it reads
-- as one continuous object spanning the pair:
--
--   * the REAL entity, clipped to keep only the +entry_forward half (the part
--     that has NOT crossed yet) -- via a RenderOverride that pushes an
--     entry-plane clip.
--   * a clientside GHOST at the mirror-transformed exit pose, clipped to keep
--     only the +exit_forward half (the EMERGED part) -- a ClientsideModel the
--     engine auto-draws in every view (main scene AND each portal RT), with its
--     own RenderOverride pushing an exit-plane clip.
--
-- The 180-yaw mirror in wp.TransformPortalPos maps the +entry_forward half to
-- the -exit_forward half and vice versa, so the two kept halves are exact images
-- of each other under the transform: they tile the whole entity with a seam on
-- the portal plane (the same plane the teleport uses, portal:GetPos()).
--
-- This is a pure client-side VISUAL layer, deliberately decoupled from the
-- teleport logic: straddling is detected each frame by a geometry test, not by
-- when the teleport fires.
--
-- Phase 1: physics props (rigid -- a single SetPos/SetAngles poses the ghost).
-- Phase 2: skeletal entities -- ragdolls (physics-driven skeleton) and NPCs
-- (animated, sequence-driven skeleton). Their visible shape is the posed
-- skeleton, not a rigid transform, so a plain ClientsideModel of the model would
-- draw in its reference (T-)pose. We drive the ghost bone-by-bone instead: each
-- frame we read the real entity's world bone matrices and re-emit them through
-- the portal transform onto the ghost (see copyBonesThroughPortal). A held weapon
-- is a separate entity bone-merged onto the hands, so it's mirrored as a second
-- sub-ghost (see updateWeapon / makeWeaponGhostOverride). This covers props,
-- ragdolls, NPCs and players -- including the LOCAL player, whose ghost is their
-- emerged half at the exit, so the body reads as whole during transit. The local
-- player's ghost is suppressed only in the single view looking straight through
-- the portal they're transiting (see localGhostIsCutaway), where the camera sits
-- inside the ghost and it would be an in-your-face cutaway "ghost".

local ENABLE_DEFAULT = "1"
-- Hold the ConVar objects (CreateClientConVar returns them) rather than calling
-- GetConVar inline -- both are read on the per-frame Think path, and GetConVar's
-- string->convar hash lookup each call is the expensive part. :GetBool() on the
-- held object is a cheap live read, so no change-callback cache is needed.
local cvGhosts = CreateClientConVar("worldportals_ghosts", ENABLE_DEFAULT, true, false,
    "World Portals - render continuous clipped ghosts of entities straddling a portal", 0, 1)

-- Opt-out for seeing your OWN body in portals. Covers two things: this file
-- skips the local player as a ghost candidate when off (no completed-half ghost
-- in third-person / recursion), and cl_render.lua's ShouldDrawLocalPlayer gate
-- stops drawing the real local player into portal RTs (no reflection through a
-- portal either). Off => you never see yourself in any portal view. Remote
-- players / NPCs / props stay governed by worldportals_ghosts.
local cvGhostsSelf = CreateClientConVar("worldportals_ghosts_self", "1", true, false,
    "World Portals - show your own body in portals (your reflection through a portal + the ghost half while mid-teleport)", 0, 1)

local GHOST_GRACE   = 0.1   -- seconds to keep a ghost alive after the straddle test drops out (anti-flicker)
local OPENING_SLACK = 8     -- units of slack on the portal opening (width/height) test
local FIND_MARGIN   = 256   -- extra radius around the portal for the candidate FindInSphere
-- The portal's VISIBLE face sits 5 units in front (-forward) of portal:GetPos()
-- -- DrawQuadEasy draws at pos - fwd*5 and SetupBounds puts RenderMax.x at -5.
-- The crossing/teleport plane is at pos itself, 5 units behind the visible face.
-- Clipping the halves at pos cuts each prop 5 units short of the glowing surface
-- (visible as the entity vanishing before it reaches the portal, on both sides),
-- so the seam is placed on the visible face instead.
local FACE_OFFSET   = 5

wp.ghosts = wp.ghosts or {}   -- [entity] = record

-- Is this an entity we render ghosts for? Physics props (rigid) and ragdolls
-- (skeletal -- posed via per-bone matrix copy), never a ghost we made.
--
-- A client-NoDraw'd prop is skipped by DEFAULT (it's hidden for a reason), but a
-- consumer can opt one back in via the wp-shouldghost hook. This covers props
-- that are hidden only in the local realm yet remain real/drawable server-side:
-- notably Doors' cordon SetNoDraw(true)'s every interior prop each frame while
-- the player is OUTSIDE the interior, so they don't render loose in the world.
-- One straddling the interior portal is exactly what we want a ghost for -- the
-- emerged half should poke out of the exterior -- so the cordon returns true
-- here for its managed props. The client can't read the server's authoritative
-- NoDraw (GetNoDraw returns the cordon-modified local flag), so the hider has to
-- declare intent. (False-world models -- the other NoDraw'd things around -- are
-- ClientsideModels, already excluded by the prop_physics class check.)
local function isCandidate(ent)
    if not IsValid(ent) then return false end
    if ent.WPIsGhost then return false end
    -- Per-player opt-out for one's OWN ghost. Short-circuits before the convar
    -- read so it costs nothing for the (common) non-local-player candidates; for
    -- the local player it gates at most once per scan. Off => no self-ghost record
    -- is ever created, and any live one expires via the GHOST_GRACE path.
    if ent == LocalPlayer() and not cvGhostsSelf:GetBool() then
        return false
    end
    -- A dead player isn't transiting a portal (the SetupMove teleport skips the
    -- dead) and its model isn't the body you see -- the death ragdoll is. Yet the
    -- dead player entity lingers at the death spot still running its move anim, so
    -- ghosting it renders a phantom (e.g. a pair of walking legs) over the corpse.
    -- Skip dead players; the death ragdoll itself still ghosts as a normal ragdoll.
    if ent:IsPlayer() and not ent:Alive() then return false end
    -- prop_physics (rigid) or a skeletal entity: a ragdoll (prop_ragdoll, NPC
    -- corpses), a live NPC, or a player -- INCLUDING the local player. The ghost
    -- completes the local player's clipped body into a whole one wherever the body
    -- is drawn (third-person, external cameras, portal views); it's suppressed only
    -- in the plain first-person view by the ghost overrides themselves (where the
    -- real body isn't drawn, so a lone ghost half would float as a "ghost"). These
    -- predicates also cleanly exclude our own ghosts -- a ghost is a plain
    -- ClientsideModel, none of the above, and is flagged WPIsGhost above regardless.
    if ent:GetClass() ~= "prop_physics" and not ent:IsRagdoll()
        and not ent:IsNPC() and not ent:IsPlayer() then return false end
    if ent:GetNoDraw() then
        return hook.Call("wp-shouldghost", GAMEMODE, ent) == true
    end
    return true
end

local function isTranslucent(ent)
    if ent:GetRenderMode() ~= RENDERMODE_NORMAL then return true end
    if ent:GetColor().a < 255 then return true end
    return false
end

local ANGLE_ZERO = Angle()

-- The transform the original is actually RENDERED at -- the single source of
-- truth for gluing the ghost (and the entry clip) to the visible prop. While
-- cl_init.lua's rapid-loop render-follow is active it SetRenderOrigin/Angles's the
-- prop to its networked transform (GetPos is frozen ~cl_interp behind and only
-- jumps on each wrap during a loop), so GetRenderOrigin/Angles returns that;
-- otherwise no override is set and GetRenderOrigin returns nil, so we fall back to
-- GetPos/GetAngles. Reading the render transform (rather than guessing
-- net-vs-GetPos) and applying the pose late (PreDrawOpaqueRenderables, after the
-- follow's Think finalizes) is what stopped a very fast looping prop splitting
-- into a stretched column.
local function renderTransform(ent)
    return ent:GetRenderOrigin() or ent:GetPos(), ent:GetRenderAngles() or ent:GetAngles()
end

local function renderCenter(ent)
    local rpos, rang = renderTransform(ent)
    return LocalToWorld(ent:OBBCenter(), ANGLE_ZERO, rpos, rang)
end

-- Mirror the original's current render transform through the pair onto the ghost.
local function poseGhost(rec)
    local rpos, rang = renderTransform(rec.ent)
    wp.TransformPortalPosInto(rec.posBuf, rpos, rec.portal, rec.exit)
    wp.TransformPortalAngleInto(rec.angBuf, rang, rec.portal, rec.exit)
    rec.ghost:SetPos(rec.posBuf)
    rec.ghost:SetAngles(rec.angBuf)
end

-- The 12 edges of an OBB, as index pairs into the 8 corners enumerated in
-- (sx, sy, sz) order with sz innermost (corner i below). Differ-in-one-bit
-- neighbours: 4 x-edges, 4 y-edges, 4 z-edges.
local OBB_EDGES = {
    {1, 5}, {2, 6}, {3, 7}, {4, 8},  -- x
    {1, 3}, {2, 4}, {5, 7}, {6, 8},  -- y
    {1, 2}, {3, 4}, {5, 6}, {7, 8},  -- z
}
-- Reused scratch (single-threaded): the 8 OBB corners in portal-local space.
-- Seeded with zeros so the analyzer infers number[] (not table<number, nil>).
local sCX = {0, 0, 0, 0, 0, 0, 0, 0}
local sCY = {0, 0, 0, 0, 0, 0, 0, 0}
local sCZ = {0, 0, 0, 0, 0, 0, 0, 0}

-- Does ent's bounds cross portal's plane, within the portal opening? Conservative
-- (over-detects): a near-but-not-crossing prop just produces a fully-clipped
-- (invisible) ghost and a fully-drawn original, i.e. no visible change.
--
-- Two tests. The cheap one (OBB *center* projects inside the opening) catches the
-- common head-on prop. The robust one clips the 12 OBB edges to the portal plane
-- (local x = 0) and checks each crossing point's (y, z) against the opening: this
-- catches LONG / OFF-AXIS props whose center sits far from the opening while a tip
-- still transits the hole -- a ladder pushed in at an angle, say. The server's
-- hull-based Touch accepts those (and arms the no-collide), but a center-only test
-- drew no ghost, so the crossed tip rendered unculled out the back of the wall and
-- nothing showed on the exit side.
local function straddles(ent, portal)
    local pos = portal:GetPos()
    local fwd = portal:GetForward()
    local center = renderCenter(ent)
    local d = fwd.x * (center.x - pos.x) + fwd.y * (center.y - pos.y) + fwd.z * (center.z - pos.z)
    if math.abs(d) >= ent:BoundingRadius() then return false end

    local mins, maxs = portal:GetCollisionBounds()
    local y0, y1 = mins.y - OPENING_SLACK, maxs.y + OPENING_SLACK
    local z0, z1 = mins.z - OPENING_SLACK, maxs.z + OPENING_SLACK

    -- Fast path: the OBB centre projects inside the opening.
    local lc = portal:WorldToLocal(center)
    if lc.y >= y0 and lc.y <= y1 and lc.z >= z0 and lc.z <= z1 then
        return true
    end

    -- Robust path: clip the OBB's edges to the portal plane and test the
    -- crossing points against the opening.
    local rpos, rang = renderTransform(ent)
    local mn, mx = ent:OBBMins(), ent:OBBMaxs()
    local i = 0
    for sx = 0, 1 do
        local lx = sx == 0 and mn.x or mx.x
        for sy = 0, 1 do
            local ly = sy == 0 and mn.y or mx.y
            for sz = 0, 1 do
                local lz = sz == 0 and mn.z or mx.z
                i = i + 1
                local l = portal:WorldToLocal(LocalToWorld(Vector(lx, ly, lz), ANGLE_ZERO, rpos, rang))
                sCX[i], sCY[i], sCZ[i] = l.x, l.y, l.z
            end
        end
    end
    for _, edge in ipairs(OBB_EDGES) do
        local a, b = edge[1], edge[2]
        local ax = sCX[a] --[[@as number]]
        local bx = sCX[b] --[[@as number]]
        if (ax < 0) ~= (bx < 0) then
            local t = ax / (ax - bx)
            local py = sCY[a] + t * (sCY[b] - sCY[a])
            if py >= y0 and py <= y1 then
                local pz = sCZ[a] + t * (sCZ[b] - sCZ[a])
                if pz >= z0 and pz <= z1 then
                    return true
                end
            end
        end
    end
    return false
end

-- Fill rec.entryNrm/entryD (keep the +entry_forward half) and rec.exitNrm/exitD
-- (keep the +exit_forward half), each plane placed on its portal's deepest
-- VISIBLE face so the seam lines up with the glowing surface rather than the
-- crossing plane behind it. The exit side folds in ExitPos/AngOffset.
--
-- Offset = FACE_OFFSET + max(0, thickness). A thin portal's face is FACE_OFFSET
-- (5u) in front (-fwd) of pos (DrawQuadEasy at pos-fwd*5, RenderMax.x=-5). A
-- THICK portal is a doorway tunnel of depth `thickness` extending further back
-- (RenderMin.x = -(5+thickness)); the half straddling it must stay visible
-- through the whole tunnel, so the seam goes on the BACK face (5+thickness) --
-- otherwise it's clipped at the mouth and the door/interior shows through the
-- exposed doorway depth. max(0, ...) guards against the negative thickness some
-- consumers (e.g. TARDIS interior portals report -5/-4) set on thin portals,
-- which would otherwise pull the seam back to the crossing plane.
local function faceOffset(portal)
    return FACE_OFFSET + math.max(0, portal:GetThickness())
end

local function updatePlanes(rec)
    local portal, exit = rec.portal, rec.exit

    local eoff = faceOffset(portal)
    local efwd = portal:GetForward()
    local epos = portal:GetPos()
    rec.entryNrm.x, rec.entryNrm.y, rec.entryNrm.z = efwd.x, efwd.y, efwd.z
    rec.entryD = efwd.x * epos.x + efwd.y * epos.y + efwd.z * epos.z - eoff

    local xoff = faceOffset(exit)
    local xfwd = exit:GetForward()
    local xao = exit:GetExitAngOffset()
    if xao.p ~= 0 or xao.y ~= 0 or xao.r ~= 0 then
        xfwd:Rotate(xao)
    end
    local xpo = exit:GetExitPosOffset()
    local xparent = exit:GetParent()
    if IsValid(xparent) then
        xpo:Rotate(xparent:GetAngles())
    end
    local xpos = exit:GetPos() + xpo
    rec.exitNrm.x, rec.exitNrm.y, rec.exitNrm.z = xfwd.x, xfwd.y, xfwd.z
    rec.exitD = xfwd.x * (xpos.x - xfwd.x * xoff)
              + xfwd.y * (xpos.y - xfwd.y * xoff)
              + xfwd.z * (xpos.z - xfwd.z * xoff)
end

-- Mirror the original's visual customizations onto the ghost. Entity-state
-- fields (model/skin/bodygroups/scale/materials) are diffed against a cached
-- signature and only re-applied on change; colour/alpha is applied at draw time
-- (render.SetColorModulation/SetBlend) where it reliably affects DrawModel.
local function syncAppearance(rec)
    local ent, ghost, sig = rec.ent, rec.ghost, rec.sig

    local model = ent:GetModel()
    if sig.model ~= model then ghost:SetModel(model); sig.model = model end

    local skin = ent:GetSkin()
    if sig.skin ~= skin then ghost:SetSkin(skin); sig.skin = skin end

    for i = 0, ent:GetNumBodyGroups() - 1 do
        local v = ent:GetBodygroup(i)
        if sig["bg" .. i] ~= v then ghost:SetBodygroup(i, v); sig["bg" .. i] = v end
    end

    local scale = ent:GetModelScale()
    if sig.scale ~= scale then ghost:SetModelScale(scale); sig.scale = scale end

    local mat = ent:GetMaterial()
    if sig.mat ~= mat then ghost:SetMaterial(mat); sig.mat = mat end

    local mats = ent:GetMaterials()
    if mats then
        for i = 1, #mats do
            local sub = ent:GetSubMaterial(i - 1)
            if sig["sm" .. i] ~= sub then ghost:SetSubMaterial(i - 1, sub); sig["sm" .. i] = sub end
        end
    end
end

-- The engine calls RenderOverride(self, flags) with the studio render flags
-- (STUDIO_RENDER / STUDIO_*DEPTHTEXTURE) as the second arg. Forward it to both
-- DrawModel and any chained override: a chained override that reads flags (e.g.
-- the sandbox prop-spawn materialize effect, which does bit.band(flags, ...))
-- errors on a nil flags, and the error escapes our PushCustomClipPlane before
-- the matching Pop, leaking the clip plane for the rest of the frame.
local function makeOriginalOverride(rec)
    return function(self, flags)
        local oldEC = render.EnableClipping(true)
        render.PushCustomClipPlane(rec.entryNrm, rec.entryD)
            if rec.savedRenderOverride then
                rec.savedRenderOverride(self, flags)
            else
                self:DrawModel(flags)
            end
        render.PopCustomClipPlane()
        render.EnableClipping(oldEC)
    end
end

-- Drive a skeletal ghost's pose from the real entity's live skeleton, mirrored
-- through the portal. The ghost is a plain ClientsideModel (no physics, no anim),
-- so its bones sit in the reference pose until we override them: each frame we
-- read the source's world bone matrices (SetupBones refreshes them to the current
-- pose -- physics-driven for a ragdoll, animation-driven for an NPC) and re-emit
-- each through the SAME rigid portal transform the teleport uses --
-- TransformPortalPos on the bone origin,
-- TransformPortalAngle on its orientation, scale carried across. Because that
-- transform is a proper rotation+translation, transforming origin and orientation
-- independently is exact, so the ghost's exit-half tiles the original's entry-half
-- seamlessly bone-for-bone. Done inside the RenderOverride (draw time) because
-- SetBoneMatrix overrides are consumed by the next DrawModel and would otherwise
-- be clobbered by the engine's own SetupBones for the ghost.
local function copyBonesThroughPortal(rec, src, ghost)
    src:SetupBones()
    ghost:SetupBones()
    local n = ghost:GetBoneCount()
    if not n or n <= 0 then return end
    for i = 0, n - 1 do
        local m = src:GetBoneMatrix(i)
        if m then
            wp.TransformPortalPosInto(rec.bonePosBuf, m:GetTranslation(), rec.portal, rec.exit)
            wp.TransformPortalAngleInto(rec.boneAngBuf, m:GetAngles(), rec.portal, rec.exit)
            local bm = Matrix()
            bm:SetTranslation(rec.bonePosBuf)
            bm:SetAngles(rec.boneAngBuf)
            bm:SetScale(m:GetScale())
            ghost:SetBoneMatrix(i, bm)
        end
    end
end

-- The ghost is the EXIT half of the local player's body, drawn at the exit. We
-- want it visible everywhere it reads as a real emerged half -- third-person,
-- external cameras, the exit portal seen from afar, recursive portal depths -- so
-- the body looks whole during a transit. The ONE view it MUST be hidden in is the
-- one looking straight through the portal you're transiting: there the render
-- camera sits exactly at the transformed eye, i.e. right inside the ghost, so you'd
-- see the inside of your own model as an in-your-face cutaway "ghost". Detect that
-- precisely -- the current render origin (EyePos, = the portal cam) coincides with
-- where this pair maps your real eye. At any other camera (third-person, external,
-- or a deeper recursion whose camera is multiply-transformed and far from the
-- ghost) the distance is large, so the ghost shows. Never hides for other entities.
local CUTAWAY_DIST_SQR = 64 * 64
local function localGhostIsCutaway(rec)
    if rec.ent ~= LocalPlayer() then return false end
    if not wp.drawing then return false end
    local camAtExit = wp.TransformPortalPos(LocalPlayer():EyePos(), rec.portal, rec.exit)
    return EyePos():DistToSqr(camAtExit) < CUTAWAY_DIST_SQR
end

-- Let a consumer veto drawing this ghost in the CURRENT render pass. The emerged
-- half lands at the exit; when the exit sits in a region the consumer hides from
-- the open world -- e.g. a Doors/TARDIS interior parked thousands of units up in
-- the skybox -- the ghost must draw ONLY in the passes where that region shows
-- (through its portal), not in the main scene where it would float visibly in the
-- empty sky. Consumers answer off wp.drawingent (the portal currently rendering),
-- so this is evaluated per draw, NOT cached: the answer differs between the
-- main-scene pass and each portal RT pass within the very same frame. Returning
-- false skips this one draw. Because a ghost is a ClientsideModel we own (this
-- RenderOverride), the consumer just says "skip" -- no SetNoDraw cordon dance,
-- which consumers reserve for native props whose drawing they can't override.
local function ghostDrawVetoed(rec, ghostEnt)
    return hook.Call("wp-shouldghostdraw", GAMEMODE, rec.ent, ghostEnt, rec.portal, rec.exit) == false
end

local function makeGhostOverride(rec)
    return function(self, flags)
        local ent = rec.ent
        if not IsValid(ent) then return end
        if localGhostIsCutaway(rec) then return end
        if ghostDrawVetoed(rec, self) then return end
        if rec.skeletal then copyBonesThroughPortal(rec, ent, self) end
        local c = ent:GetColor()
        local oldBlend = render.GetBlend()
        local oldEC = render.EnableClipping(true)
        render.PushCustomClipPlane(rec.exitNrm, rec.exitD)
            render.SetColorModulation(c.r / 255, c.g / 255, c.b / 255)
            render.SetBlend(c.a / 255)
            self:DrawModel(flags)
            render.SetColorModulation(1, 1, 1)
            render.SetBlend(oldBlend)
        render.PopCustomClipPlane()
        render.EnableClipping(oldEC)
    end
end

-- An NPC's (or player's) active weapon is a SEPARATE entity bone-merged onto the
-- hands, so it isn't part of the body's skeleton and the body ghost above never
-- draws it. We mirror it as a second sub-ghost, handled symmetrically to the
-- body: the real weapon gets an entry-plane clip (so its muzzle doesn't poke
-- unclipped through the portal on the near side, the same artefact the body clip
-- fixes), and a weapon ClientsideModel at the exit gets the exit-plane clip. The
-- weapon poses by the SAME bone copy -- its 3 merge bones follow the hand, so
-- copyBonesThroughPortal reproduces the held pose exactly (verified: a weapon's
-- GetBoneMatrix(0) == its GetPos, tracking the hand).

local function makeWeaponGhostOverride(rec)
    return function(self, flags)
        local w = rec.weapon
        if not IsValid(w) then return end
        if localGhostIsCutaway(rec) then return end
        if ghostDrawVetoed(rec, self) then return end
        copyBonesThroughPortal(rec, w, self)
        local c = w:GetColor()
        local oldBlend = render.GetBlend()
        local oldEC = render.EnableClipping(true)
        render.PushCustomClipPlane(rec.exitNrm, rec.exitD)
            render.SetColorModulation(c.r / 255, c.g / 255, c.b / 255)
            render.SetBlend(c.a / 255)
            self:DrawModel(flags)
            render.SetColorModulation(1, 1, 1)
            render.SetBlend(oldBlend)
        render.PopCustomClipPlane()
        render.EnableClipping(oldEC)
    end
end

local function makeWeaponOriginalOverride(rec)
    return function(self, flags)
        local oldEC = render.EnableClipping(true)
        render.PushCustomClipPlane(rec.entryNrm, rec.entryD)
            if rec.weaponSavedOverride then
                rec.weaponSavedOverride(self, flags)
            else
                self:DrawModel(flags)
            end
        render.PopCustomClipPlane()
        render.EnableClipping(oldEC)
    end
end

-- Tear down weapon tracking: restore the real weapon's RenderOverride and remove
-- the weapon ghost. Safe to call when no weapon is tracked.
local function clearWeapon(rec)
    if IsValid(rec.weaponGhost) then rec.weaponGhost:Remove() end
    rec.weaponGhost = nil
    if IsValid(rec.weapon) and rec.weapon.RenderOverride == rec.weaponOriginalOverride then
        rec.weapon.RenderOverride = rec.weaponSavedOverride
    end
    rec.weapon = nil
    rec.weaponModel = nil
    rec.weaponSavedOverride = nil
end

-- Keep the weapon sub-ghost in step with the NPC/player's current active weapon.
-- Lazily (re)builds the weapon ghost when the held model changes, installs the
-- entry clip on the real weapon, and parks the ghost root at the transformed
-- weapon pose for culling (its bones are placed in world space by the override).
local function updateWeapon(rec)
    local ent = rec.ent
    if not (ent:IsNPC() or ent:IsPlayer()) then return end

    local w = ent:GetActiveWeapon()
    local model = IsValid(w) and w:GetModel() or nil
    if not model or model == "" then
        clearWeapon(rec)
        return
    end

    if rec.weaponModel ~= model then
        clearWeapon(rec)
        local wc = ClientsideModel(model, RENDERGROUP_OPAQUE)
        if not IsValid(wc) then return end
        wc.WPIsGhost = true
        wc:SetNoDraw(false)
        wc:DrawShadow(false)
        wc.RenderOverride = makeWeaponGhostOverride(rec)
        rec.weaponGhost = wc
        rec.weaponModel = model
        rec.weaponOriginalOverride = rec.weaponOriginalOverride or makeWeaponOriginalOverride(rec)
    end
    rec.weapon = w

    if w.RenderOverride ~= rec.weaponOriginalOverride then
        rec.weaponSavedOverride = w.RenderOverride
        w.RenderOverride = rec.weaponOriginalOverride
    end

    if IsValid(rec.weaponGhost) then
        wp.TransformPortalPosInto(rec.posBuf, w:GetPos(), rec.portal, rec.exit)
        wp.TransformPortalAngleInto(rec.angBuf, w:GetAngles(), rec.portal, rec.exit)
        rec.weaponGhost:SetPos(rec.posBuf)
        rec.weaponGhost:SetAngles(rec.angBuf)
        rec.weaponGhost:SetSkin(w:GetSkin())
    end
end

-- Install our entry-plane clip on the original, chaining any pre-existing
-- RenderOverride (a consumer's) so it still runs -- just clipped.
local function ensureOriginalOverride(rec)
    local ent = rec.ent
    if ent.RenderOverride ~= rec.originalOverride then
        rec.savedRenderOverride = ent.RenderOverride
        ent.RenderOverride = rec.originalOverride
    end
end

local function endStraddle(rec)
    if IsValid(rec.ghost) then rec.ghost:Remove() end
    if IsValid(rec.ent) and rec.ent.RenderOverride == rec.originalOverride then
        rec.ent.RenderOverride = rec.savedRenderOverride
    end
    clearWeapon(rec)
    wp.ghosts[rec.ent] = nil
end

local function startStraddle(ent, portal)
    local exit = portal:GetExit()
    if not IsValid(exit) then return nil end

    local ghost = ClientsideModel(ent:GetModel(),
        isTranslucent(ent) and RENDERGROUP_TRANSLUCENT or RENDERGROUP_OPAQUE)
    if not IsValid(ghost) then return nil end

    ghost.WPIsGhost = true
    ghost:SetNoDraw(false)
    ghost:DrawShadow(false)

    -- A player model's PlayerColor material proxy reads ent:GetPlayerColor(), which
    -- a plain ClientsideModel can't carry -- SetPlayerColor ERRORS on one. Override
    -- the method on the ghost instead, so the proxy returns the source player's live
    -- colour and tints exactly the clothing materials the real body does (verified:
    -- the proxy invokes this Lua method; whole-model SetColorModulation would wrongly
    -- tint skin too). Players only -- props/ragdolls/NPCs have no player colour, and
    -- a held physgun's world model already carries its weapon colour on its own.
    if ent:IsPlayer() then
        ghost.GetPlayerColor = function() return ent:GetPlayerColor() end
    end

    local rec = {
        ent = ent,
        portal = portal,
        exit = exit,
        ghost = ghost,
        -- A ragdoll, NPC or player is skeletal: the ghost's pose comes from per-bone
        -- matrix copy (copyBonesThroughPortal) rather than the rigid SetPos/SetAngles.
        skeletal = ent:IsRagdoll() or ent:IsNPC() or ent:IsPlayer(),
        translucent = isTranslucent(ent),
        lastSeen = SysTime(),
        posBuf = Vector(),
        angBuf = Angle(),
        -- Separate scratch for the per-bone transform so it never races the root
        -- pose's posBuf/angBuf (different callbacks, same frame).
        bonePosBuf = Vector(),
        boneAngBuf = Angle(),
        entryNrm = Vector(),
        exitNrm = Vector(),
        entryD = 0,
        exitD = 0,
        sig = {},
    }
    rec.originalOverride = makeOriginalOverride(rec)
    ghost.RenderOverride = makeGhostOverride(rec)
    wp.ghosts[ent] = rec
    return rec
end

local function updateStraddle(rec, now)
    rec.lastSeen = now

    -- Re-read the exit each frame: a relinked portal can change it.
    local exit = rec.portal:GetExit()
    if not IsValid(exit) then return false end
    rec.exit = exit

    -- A change in translucency flips which render pass the ghost belongs to,
    -- which is baked in at ClientsideModel creation -- rebuild on change.
    if isTranslucent(rec.ent) ~= rec.translucent then return false end

    updatePlanes(rec)
    poseGhost(rec)
    syncAppearance(rec)
    ensureOriginalOverride(rec)
    updateWeapon(rec)
    return true
end

local seen = {}

-- Discovery (the ents.FindInSphere broad-phase + per-candidate straddle tests) is
-- the bulk of this hook's cost and scales with open-portals x nearby entities. It
-- doesn't need to run every frame: the ghost POSE is re-applied per-frame in
-- PreDrawOpaqueRenderables (so ghosts stay glued regardless), and GHOST_GRACE
-- (0.1s) comfortably outlives the gap, so a record seen on one scan survives until
-- the next. Running it at ~SCAN_HZ instead of the frame rate cuts the cost without
-- a visible change -- a ghost appearing up to SCAN_INTERVAL late as a prop first
-- crosses is imperceptible at any realistic push speed.
local SCAN_INTERVAL = 0.04   -- seconds between discovery scans (~25 Hz)
local nextScan = 0

-- A ghost depicts a prop mid-transit, so only show one where the prop would
-- actually teleport through this portal. Consult wp-shouldtp -- the SAME
-- per-entity veto the teleport itself uses -- and skip on an explicit false.
--
-- This is the right "portal off" signal because it is POSITION-INDEPENDENT: it
-- reads networked state (DoorOpen, vortex/redecorate flags, GetTracking,
-- custom-link part on/off) identically from any viewpoint. We deliberately do NOT
-- gate on wp-shouldrender: the exterior portal's ShouldRenderPortal returns false
-- once the camera is far from the exterior box (a TARDIS interior is thousands of
-- units away), so a render-gated ghost vanished the moment you stepped INSIDE --
-- even though the emerged half should still show through the interior portal. The
-- ghost is a world-space model at the exit; whether the entry portal's SURFACE
-- draws from the current eye is irrelevant to whether the ghost should exist.
--
-- Covers: closed door, TARDIS in the vortex (in flight), interior redecorating,
-- the prop being the TARDIS's towed/tracked entity, a custom-linked sub-door
-- switched off, and TardisParts. The downstream ShouldTeleportPortal handlers are
-- registered shared for the predicted player teleport and read networked state, so
-- this resolves on the client. nil = no veto = ghost. (A purely server-side veto --
-- e.g. tracking's constraint-set check -- can't be seen here, but erring toward
-- showing a ghost the server won't teleport is harmless: the prop never crosses
-- the plane, so its ghost stays fully clipped and invisible.)
local function wouldTeleport(portal, ent)
    return hook.Call("wp-shouldtp", GAMEMODE, portal, ent) ~= false
end

hook.Add("Think", "WorldPortals_Ghosts", function()
    if wp.drawing then return end
    if not cvGhosts:GetBool() then
        if next(wp.ghosts) then
            for _, rec in pairs(wp.ghosts) do endStraddle(rec) end
        end
        return
    end

    local now = SysTime()
    if now < nextScan then return end
    nextScan = now + SCAN_INTERVAL

    for k in pairs(seen) do seen[k] = nil end

    local portals = wp.portals
    if not portals then portals = ents.FindByClass("linked_portal_door") end

    for _, portal in ipairs(portals) do
        if IsValid(portal) and portal.GetOpen and portal:GetOpen()
            and portal:GetEnableTeleport() and IsValid(portal:GetExit()) then
            local ppos = portal:GetPos()
            local r = portal:BoundingRadius() + FIND_MARGIN
            for _, ent in ipairs(ents.FindInSphere(ppos, r)) do
                if isCandidate(ent) and straddles(ent, portal) and wouldTeleport(portal, ent) then
                    -- If straddling more than one portal, keep the nearest.
                    local prev = seen[ent]
                    if not prev then
                        seen[ent] = portal
                    else
                        local pc = renderCenter(ent)
                        local prevPos = prev:GetPos()
                        local dn = (pc - ppos):LengthSqr()
                        local dp = (pc - prevPos):LengthSqr()
                        if dn < dp then seen[ent] = portal end
                    end
                end
            end
        end
    end

    for ent, portal in pairs(seen) do
        local rec = wp.ghosts[ent]
        if rec and rec.portal ~= portal then
            endStraddle(rec)
            rec = nil
        end
        if not rec then rec = startStraddle(ent, portal) end
        if rec and not updateStraddle(rec, now) then
            endStraddle(rec)
        end
    end

    -- Expire records not seen this frame once the grace window passes; also
    -- tear down anything that went invalid.
    local expired
    for ent, rec in pairs(wp.ghosts) do
        if not IsValid(ent) or not IsValid(rec.portal) or not IsValid(rec.ghost) then
            expired = expired or {}
            expired[#expired + 1] = rec
        elseif not seen[ent] and (now - rec.lastSeen) > GHOST_GRACE then
            expired = expired or {}
            expired[#expired + 1] = rec
        end
    end
    if expired then
        for _, rec in ipairs(expired) do endStraddle(rec) end
    end
end)

-- Hand the ghost off to the new portal pair the INSTANT the entity teleports.
-- Measured frame-by-frame: the discovery scan runs BEFORE SetupMove in the frame,
-- so it can't see the just-teleported position until the next frame. For that one
-- frame the ghost stays bound to the stale entry pair, so poseGhost transforms the
-- NEW position through the OLD pair and flings the ghost to the wrong place -- it's
-- drawn there in the portal view as a half-body flicker right at the crossing.
--
-- After crossing A->B the entity straddles B from the far side, so its new entry is
-- B (the portal it emerged from = portal:GetExit()) and its new exit is B's exit.
-- Re-point the record and recompute the clip planes here, before render -- poseGhost
-- (PreDrawOpaqueRenderables) then re-poses through the correct pair the same frame.
-- The next scan confirms/maintains it. wp-teleport fires on every resim pass for the
-- local player; this is idempotent (same pair each time), so it's resim-safe.
hook.Add("wp-teleport", "WorldPortals_GhostsTeleport", function(portal, ent)
    local rec = ent and wp.ghosts[ent]
    if rec and IsValid(portal) then
        local newEntry = portal:GetExit()
        if IsValid(newEntry) and IsValid(newEntry:GetExit()) then
            rec.portal = newEntry
            rec.exit = newEntry:GetExit()
            updatePlanes(rec)
        end
    end
    nextScan = 0
end)

hook.Add("EntityRemoved", "WorldPortals_Ghosts", function(ent)
    local direct = wp.ghosts[ent]
    if direct then endStraddle(direct) end

    -- A removed portal/exit/ghost invalidates any record referencing it.
    local victims
    for e, rec in pairs(wp.ghosts) do
        if e ~= ent and (rec.portal == ent or rec.exit == ent or rec.ghost == ent) then
            victims = victims or {}
            victims[#victims + 1] = rec
        end
    end
    if victims then
        for _, rec in ipairs(victims) do endStraddle(rec) end
    end
end)

-- Authoritative ghost pose, applied after every Think (so cl_init.lua's rapid-loop
-- render-follow has finalized the original's SetRenderOrigin) and right before the
-- scene draws. Re-posing here from the original's live render transform keeps the
-- ghost glued to the visible prop even at extreme loop speeds, where a Think-time
-- pose lagged the follow by a sub-frame and split the prop into two offset halves.
hook.Add("PreDrawOpaqueRenderables", "WorldPortals_GhostPose", function(_, skybox)
    if skybox then return end
    if not next(wp.ghosts) then return end
    for ent, rec in pairs(wp.ghosts) do
        if IsValid(ent) and IsValid(rec.ghost) and IsValid(rec.exit) then
            poseGhost(rec)
        end
    end
end)
