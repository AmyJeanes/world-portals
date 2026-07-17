-- Ghosts

-- Continuous entity rendering across portals ("portal ghosts"). An entity
-- straddling a portal would be cut off at the opening, so we spawn a clientside
-- ghost at the mirror-transformed exit pose and clip both halves to the portal
-- plane - the real entity keeps the entry side, the ghost the exit side - so
-- they read as one body. Pure client-side, decoupled from the teleport. Rigid
-- props pose via SetPos/SetAngles; skeletal entities (ragdolls/NPCs/players)
-- pose bone-by-bone.

local cvGhosts = CreateClientConVar("worldportals_ghosts", "1", true, false,
    "Render props through portals as they are passing through them", 0, 1)

-- worldportals_show_self convar (created in cl_render.lua), resolved lazily.
local cvShowSelf

local GHOST_GRACE   = 0.1   -- seconds to keep a ghost alive after the straddle test drops out (anti-flicker)
local OPENING_SLACK = 8     -- units of slack on the portal opening (width/height) test
-- The visible face sits 5u in front of portal:GetPos() (DrawQuadEasy at pos-fwd*5),
-- so clip the halves there, not at the crossing plane, to seam on the glowing face.
local FACE_OFFSET   = 5

---@type table<Entity, wp.GhostRecord>
wp.ghosts = wp.ghosts or {}   -- [entity] = record

local GROUP_CROSS_GRACE = 0.3   -- seconds a crossing mark survives without a net refresh

-- Rigid-group members the server flagged as past the portal face but not yet teleported. The
-- per-prop straddle test misses them, so they'd render solid behind the portal; ghost them
-- instead. Constraint networks are server-only, so the set arrives by net.
---@type table<Entity, wp.GroupCross>
wp.groupCrossing = wp.groupCrossing or {}
setmetatable(wp.groupCrossing, { __mode = "k" })   -- weak keys: drop marks for entities that vanish

-- Lets a consumer that also drives ent's RenderOverride yield to us while we ghost it.
---@api
---@param ent Entity
function wp.IsGhosting(ent)
    return wp.ghosts[ent] ~= nil
end

-- A crossable body with a model to clone (a brush "*N" model can't be ClientsideModel'd).
---@param ent Entity
local function isGhostableBody(ent)
    if not wp.IsPhysicalMover(ent) then return false end
    local mdl = ent:GetModel()
    return mdl ~= nil and mdl ~= "" and mdl:sub(1, 1) ~= "*"
end

---@param ent Entity
local function isCandidate(ent)
    if not IsValid(ent) then return false end
    if ent.WPIsGhost then return false end
    if ent == LocalPlayer() then
        cvShowSelf = cvShowSelf or GetConVar("worldportals_show_self")
        if cvShowSelf and not cvShowSelf:GetBool() then return false end
    end
    -- A dead player's entity lingers running its move anim (the visible body is
    -- the ragdoll), so ghosting it draws a phantom over the corpse. The ragdoll
    -- itself still ghosts normally.
    if ent:IsPlayer() and not ent:Alive() then return false end
    if not isGhostableBody(ent) then return false end
    if ent:GetNoDraw() then return false end
    return true
end

---@param ent Entity
local function isTranslucent(ent)
    if ent:GetRenderMode() ~= RENDERMODE_NORMAL then return true end
    if ent:GetColor().a < 255 then return true end
    return false
end

local ANGLE_ZERO = Angle()

---@param ent Entity
local function renderTransform(ent)
    return ent:GetRenderOrigin() or ent:GetPos(), ent:GetRenderAngles() or ent:GetAngles()
end

---@param ent Entity
local function renderCenter(ent)
    local rpos, rang = renderTransform(ent)
    return LocalToWorld(ent:OBBCenter(), ANGLE_ZERO, rpos, rang)
end

---@param rec wp.GhostRecord
local function poseGhost(rec)
    local rpos, rang = renderTransform(rec.ent)
    wp.TransformPortalPosInto(rec.posBuf, rpos, rec.portal, rec.exit)
    wp.TransformPortalAngleInto(rec.angBuf, rang, rec.portal, rec.exit)
    rec.ghost:SetPos(rec.posBuf)
    rec.ghost:SetAngles(rec.angBuf)
end

-- The 12 edges of an OBB as index pairs into the 8 corners (enumerated sx,sy,sz
-- with sz innermost): 4 x-edges, 4 y-edges, 4 z-edges.
local OBB_EDGES = {
    {1, 5}, {2, 6}, {3, 7}, {4, 8},  -- x
    {1, 3}, {2, 4}, {5, 7}, {6, 8},  -- y
    {1, 2}, {3, 4}, {5, 6}, {7, 8},  -- z
}
-- Reused scratch: the 8 OBB corners in portal-local space.
local sCX = {0, 0, 0, 0, 0, 0, 0, 0}
local sCY = {0, 0, 0, 0, 0, 0, 0, 0}
local sCZ = {0, 0, 0, 0, 0, 0, 0, 0}

-- Does ent's bounds cross the portal plane within the opening? Conservative - a
-- near-miss just makes a fully-clipped, invisible ghost.
---@param ent Entity
---@param portal linked_portal_door
local function straddles(ent, portal)
    local pos = portal:GetPos()
    local fwd = portal:GetForward()
    local center = renderCenter(ent)
    -- Cheap reject: bounds too far from the plane to reach it.
    local d = fwd.x * (center.x - pos.x) + fwd.y * (center.y - pos.y) + fwd.z * (center.z - pos.z)
    if math.abs(d) >= ent:BoundingRadius() then return false end

    local mins, maxs = portal:GetCollisionBounds()
    local y0, y1 = mins.y - OPENING_SLACK, maxs.y + OPENING_SLACK
    local z0, z1 = mins.z - OPENING_SLACK, maxs.z + OPENING_SLACK

    -- Cheap path: the OBB centre projects inside the opening.
    local lc = portal:WorldToLocal(center)
    if lc.y >= y0 and lc.y <= y1 and lc.z >= z0 and lc.z <= z1 then
        return true
    end

    -- Robust path (long/off-axis props whose centre missed): build the 8 OBB
    -- corners in portal-local space, then clip each edge to the plane below.
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
    -- An edge with endpoints on opposite sides of the plane (x sign flip) crosses
    -- it; test where that crossing lands against the opening.
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

-- Seam offset = FACE_OFFSET + thickness: a thick portal is a tunnel of depth
-- `thickness`, so the seam sits on its back face, else the doorway depth shows
-- through.
---@param portal linked_portal_door
local function faceOffset(portal)
    return FACE_OFFSET + portal:GetThickness()
end

-- The exit clip plane (n . p = D) the ghost half is sliced on, at the exit's visible
-- face, folding in its pos/ang offsets so an offset or relinked pair still seams.
---@param rec wp.GhostRecord
local function updateExitPlane(rec)
    local exit = rec.exit
    local xoff = faceOffset(exit)
    local xfwd = exit:GetForward()
    local xao = exit:GetExitAngOffset()
    if xao.p ~= 0 or xao.y ~= 0 or xao.r ~= 0 then
        xfwd:Rotate(xao)
    end
    -- ExitPosOffset is defined in the parent's local space - rotate it to world.
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

-- The entry clip plane the real entity's half is sliced on, at the portal's visible face.
---@param rec wp.GhostRecord
local function updateEntryPlane(rec)
    local portal = rec.portal
    local eoff = faceOffset(portal)
    local efwd = portal:GetForward()
    local epos = portal:GetPos()
    rec.entryNrm.x, rec.entryNrm.y, rec.entryNrm.z = efwd.x, efwd.y, efwd.z
    rec.entryD = efwd.x * epos.x + efwd.y * epos.y + efwd.z * epos.z - eoff
end

-- Mirror the original's appearance onto the ghost: model/skin/bodygroups/scale/
-- materials diffed against a cached signature; colour/alpha applied at draw time.
---@param rec wp.GhostRecord
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

-- Clip via the entity's own persistent clip plane, NOT render.PushCustomClipPlane: the
-- latter is only active within the main-view Push/Pop, so the engine's separate shadow-
-- depth pass never sees it and the shadow spills across the portal uncut. SetRenderClipPlane
-- rides on the entity, so the engine applies it in every pass - model and cast shadow alike -
-- slicing the shadow to the same half as the visible body. Disabled again on teardown.
---@param ent Entity
---@param nrm Vector
---@param d number
local function clipToHalf(ent, nrm, d)
    ent:SetRenderClipPlane(nrm, d)
    ent:SetRenderClipPlaneEnabled(true)
end

-- Clip the real entity to its entry half, recomputing the entry plane here at the draw
-- so it tracks a fast-moving portal (mirror of the ghost's exit plane). Forwards the
-- studio render flags to DrawModel and any chained override (e.g. the prop-spawn
-- materialize effect reads them).
---@param rec wp.GhostRecord
local function makeOriginalOverride(rec)
    return function(self, flags)
        if IsValid(rec.portal) then
            updateEntryPlane(rec)
            clipToHalf(self, rec.entryNrm, rec.entryD)
        end
        if rec.savedRenderOverride then
            rec.savedRenderOverride(self, flags)
        else
            self:DrawModel(flags)
        end
    end
end

local YAW180 = Matrix()
YAW180:SetAngles(Angle(0, 180, 0))

-- Pose a skeletal ghost from the source's live skeleton: re-emit each world bone
-- matrix through the portal. Done inside the RenderOverride because SetBoneMatrix
-- is consumed by the next DrawModel (the engine's own SetupBones would clobber it).
---@param rec wp.GhostRecord
---@param src Entity
---@param ghost Entity
local function copyBonesThroughPortal(rec, src, ghost)
    src:SetupBones()
    ghost:SetupBones()
    local n = ghost:GetBoneCount()
    if not n or n <= 0 then return end

    -- The through-portal transform is the same for every bone, so compose it once
    -- as exit-frame * yaw180 * entry-frame^-1 (the WorldToLocal -> mirror ->
    -- LocalToWorld pipeline of TransformPortalPos) and reduce each bone to one
    -- multiply - no per-bone transform math or translation/angle/scale allocs.
    local exit = rec.exit
    local offset = exit:GetExitPosOffset()
    local xparent = exit:GetParent()
    if IsValid(xparent) then offset:Rotate(xparent:GetAngles()) end
    local entry, ex = rec.entryFrame, rec.exitFrame
    entry:SetAngles(rec.portal:GetAngles())
    entry:SetTranslation(rec.portal:GetPos())
    ex:SetAngles(exit:GetAngles() + exit:GetExitAngOffset())
    ex:SetTranslation(exit:GetPos() + offset)
    local M = ex * YAW180 * entry:GetInverseTR()

    for i = 0, n - 1 do
        local m = src:GetBoneMatrix(i)
        if m then ghost:SetBoneMatrix(i, M * m) end
    end
end

-- Hide the local player's ghost only in the view looking straight through the
-- portal being transited: there the render camera sits at the transformed eye,
-- inside the ghost (an in-your-face cutaway). Detect it as the render origin
-- coinciding with where the pair maps the real eye; any other camera is far.
local CUTAWAY_DIST_SQR = 64 * 64
---@param rec wp.GhostRecord
local function localGhostIsCutaway(rec)
    if rec.ent ~= LocalPlayer() then return false end
    if not wp.drawing then return false end
    local camAtExit = wp.TransformPortalPos(LocalPlayer():EyePos(), rec.portal, rec.exit)
    return EyePos():DistToSqr(camAtExit) < CUTAWAY_DIST_SQR
end

-- Let a consumer veto drawing this ghost in the current pass - for an exit in a
-- region hidden from the open world (e.g. an interior tucked in the skybox), it must
-- draw only in that region's portal RT, not the main scene. Per-draw, NOT cached
-- (the answer differs between passes within one frame).
---@param sourceEnt Entity
---@param ghostEnt Entity
---@param portal linked_portal_door
---@param exit linked_portal_door
local function ghostDrawVetoed(sourceEnt, ghostEnt, portal, exit)
    return hook.Call("wp-shouldghostdraw", GAMEMODE, sourceEnt, ghostEnt, portal, exit) == false
end

---@param rec wp.GhostRecord
local function makeGhostOverride(rec)
    return function(self, flags)
        local ent = rec.ent
        if not IsValid(ent) then return end
        if not (IsValid(rec.portal) and IsValid(rec.exit)) then return end
        -- The local player never sees their own shadow, so keep their ghost shadowless:
        -- the shadow-depth pass calls this override, and skipping it suppresses the cast
        -- (DrawShadow(false) alone can't - it doesn't gate a manual DrawModel). Everyone
        -- else's ghost casts a shadow, clipped to the exit half by clipToHalf below.
        if rec.isLocalPlayer and bit.band(flags, STUDIO_SHADOWDEPTHTEXTURE) ~= 0 then return end
        if localGhostIsCutaway(rec) then return end
        if ghostDrawVetoed(ent, self, rec.portal, rec.exit) then return end
        -- A skeletal ghost whose source stops being force-drawn reads bind-pose bones and draws
        -- a T-pose, so gate it out. Rigid props pose live every draw and don't, so gating them
        -- just blinks them off on a frame hitch that stretches the scan past the grace.
        if rec.skeletal and SysTime() - rec.lastSeen > GHOST_GRACE then return end
        -- Pose + exit clip plane are recomputed here, at the draw: the ghost only renders
        -- in the portal RT passes (world-portals draws portals under VIEW_3DSKY), so
        -- computing them at the draw keeps it glued to a fast-moving exit between the 25Hz
        -- discovery scans. Skeletal ghosts place their bones; rigid props set the body.
        if rec.skeletal then
            copyBonesThroughPortal(rec, ent, self)
        else
            poseGhost(rec)
            -- DrawModel renders from the bone matrices the engine built (off the
            -- pre-override transform) before this override ran, so SetPos alone wouldn't
            -- move the draw; SetupBones rebuilds them from the pose we just set.
            self:SetupBones()
        end
        updateExitPlane(rec)
        clipToHalf(self, rec.exitNrm, rec.exitD)
        local c = ent:GetColor()
        local oldBlend = render.GetBlend()
        render.SetColorModulation(c.r / 255, c.g / 255, c.b / 255)
        render.SetBlend(c.a / 255)
        self:DrawModel(flags)
        render.SetColorModulation(1, 1, 1)
        render.SetBlend(oldBlend)

        -- Flag that the ghost has actually rendered; the scan creates its sun shadow once it has
        -- (CreateShadow no-ops on a never-drawn model and must run in the game loop, not mid-render).
        rec.hasDrawn = true
    end
end

-- An active weapon is a separate bone-merged entity the body ghost never draws,
-- so mirror it as a second sub-ghost handled symmetrically: real weapon gets the
-- entry clip, a weapon ClientsideModel at the exit gets the exit clip. Poses by
-- the same bone copy (its merge bones follow the hand).

---@param rec wp.GhostRecord
local function makeWeaponGhostOverride(rec)
    return function(self, flags)
        local w = rec.weapon
        if not IsValid(w) then return end
        if not (IsValid(rec.portal) and IsValid(rec.exit)) then return end
        if rec.isLocalPlayer and bit.band(flags, STUDIO_SHADOWDEPTHTEXTURE) ~= 0 then return end  -- local player's own ghost stays shadowless (see makeGhostOverride)
        if localGhostIsCutaway(rec) then return end
        if ghostDrawVetoed(rec.ent, self, rec.portal, rec.exit) then return end
        if SysTime() - rec.lastSeen > GHOST_GRACE then return end  -- stop at grace, no bind-pose flash (see makeGhostOverride)
        copyBonesThroughPortal(rec, IsValid(rec.weaponPose) and rec.weaponPose or w, self)
        updateExitPlane(rec)
        clipToHalf(self, rec.exitNrm, rec.exitD)
        local c = w:GetColor()
        local oldBlend = render.GetBlend()
        render.SetColorModulation(c.r / 255, c.g / 255, c.b / 255)
        render.SetBlend(c.a / 255)
        self:DrawModel(flags)
        render.SetColorModulation(1, 1, 1)
        render.SetBlend(oldBlend)
        rec.weaponHasDrawn = true   -- the scan creates its shadow once drawn (see makeGhostOverride)
    end
end

---@param rec wp.GhostRecord
local function makeWeaponOriginalOverride(rec)
    return function(self, flags)
        if IsValid(rec.portal) then
            updateEntryPlane(rec)
            clipToHalf(self, rec.entryNrm, rec.entryD)
        end
        if rec.weaponSavedOverride then
            rec.weaponSavedOverride(self, flags)
        else
            self:DrawModel(flags)
        end
    end
end

-- Safe to call when no weapon is tracked.
---@param rec wp.GhostRecord
local function clearWeapon(rec)
    if IsValid(rec.weaponGhost) then rec.weaponGhost:Remove() end
    rec.weaponGhost = nil
    if IsValid(rec.weaponPose) then rec.weaponPose:Remove() end
    rec.weaponPose = nil
    if IsValid(rec.weapon) and rec.weapon.RenderOverride == rec.weaponOriginalOverride then
        rec.weapon.RenderOverride = rec.weaponSavedOverride
        rec.weapon:SetRenderClipPlaneEnabled(false)
    end
    rec.weapon = nil
    rec.weaponModel = nil
    rec.weaponSkin = nil
    rec.weaponSavedOverride = nil
    rec.weaponHasDrawn = nil      -- a new weapon ghost re-establishes its shadow
    rec.weaponShadowReady = nil
end

-- The world model a weapon actually draws can differ from GetModel: some carry a
-- placeholder model and swap to the real one inside DrawWorldModel. Dry-run that
-- draw with SetModel/SetSkin/DrawModel intercepted (scoped to this weapon, nothing
-- rendered) to capture the model it would set; fall back to GetModel if it sets none.
local entMeta = assert(FindMetaTable("Entity"))
---@param w Entity
local function resolveWeaponWorldModel(w)
    if not isfunction(w.DrawWorldModel) then
        return w:GetModel(), w:GetSkin()
    end
    local model, skin
    local oSet, oSkin, oDraw = entMeta.SetModel, entMeta.SetSkin, entMeta.DrawModel
    ---@param s Entity
    ---@param m string
    entMeta.SetModel = function(s, m) if s == w then model = m return end return oSet(s, m) end
    ---@param s Entity
    ---@param k number
    entMeta.SetSkin = function(s, k) if s == w then skin = k return end return oSkin(s, k) end
    ---@param s Entity
    entMeta.DrawModel = function(s, ...) if s == w then return end return oDraw(s, ...) end
    pcall(w.DrawWorldModel, w)
    entMeta.SetModel, entMeta.SetSkin, entMeta.DrawModel = oSet, oSkin, oDraw
    return model or w:GetModel(), skin or w:GetSkin()
end

-- Keep the weapon sub-ghost in step with the NPC/player's active weapon. The
-- ghost root is parked at the transformed weapon pose only for culling - its
-- bones are placed in world space by the override.
---@param rec wp.GhostRecord
local function updateWeapon(rec)
    local ent = rec.ent
    if not (ent:IsNPC() or ent:IsPlayer()) then return end

    local w = ent:GetActiveWeapon()
    if not IsValid(w) then
        clearWeapon(rec)
        return
    end
    local model, skin = resolveWeaponWorldModel(w)
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
        -- Some weapons use material proxies that rely on the owner being set (e.g. the physgun core colour)
        wc:SetOwner(ent)
        wc:DrawShadow(not rec.isLocalPlayer)   -- CreateShadow below once it has drawn (see startStraddle)
        wc.RenderOverride = makeWeaponGhostOverride(rec)
        rec.weaponGhost = wc

        -- Bone source for the ghost. A weapon that swaps to its real world model inside
        -- DrawWorldModel leaves the live weapon posing the placeholder skeleton, so copying
        -- its bones onto the resolved-model ghost would mismatch. Bonemerge a hidden clone of
        -- the resolved model to the holder instead: it shares the ghost's skeleton and its
        -- bones follow the hand.
        local pose = ClientsideModel(model, RENDERGROUP_OPAQUE)
        if IsValid(pose) then
            pose:Spawn()
            pose.WPIsGhost = true
            pose:SetNoDraw(true)
            pose:SetParent(ent)
            pose:AddEffects(EF_BONEMERGE)
            rec.weaponPose = pose
        end

        rec.weaponModel = model
        rec.weaponOriginalOverride = rec.weaponOriginalOverride or makeWeaponOriginalOverride(rec)
    end
    rec.weapon = w
    rec.weaponSkin = skin

    if w.RenderOverride ~= rec.weaponOriginalOverride then
        rec.weaponSavedOverride = w.RenderOverride
        w.RenderOverride = rec.weaponOriginalOverride
    end

    if IsValid(rec.weaponGhost) then
        wp.TransformPortalPosInto(rec.posBuf, w:GetPos(), rec.portal, rec.exit)
        wp.TransformPortalAngleInto(rec.angBuf, w:GetAngles(), rec.portal, rec.exit)
        rec.weaponGhost:SetPos(rec.posBuf)
        rec.weaponGhost:SetAngles(rec.angBuf)
        rec.weaponGhost:SetSkin(skin or 0)

        -- Sun/RTT shadow once the weapon ghost has drawn, same as the body ghost (see updateStraddle):
        -- the Think re-renders it each frame via MarkShadowAsDirty so it tracks the hand.
        if rec.weaponHasDrawn and not rec.weaponShadowReady and not rec.isLocalPlayer then
            rec.weaponShadowReady = true
            rec.weaponGhost:CreateShadow()
        end
    end
end

-- Install our entry-plane clip on the original, chaining any pre-existing
-- RenderOverride (a consumer's) so it still runs - just clipped.
---@param rec wp.GhostRecord
local function ensureOriginalOverride(rec)
    local ent = rec.ent
    if ent.RenderOverride ~= rec.originalOverride then
        rec.savedRenderOverride = ent.RenderOverride
        ent.RenderOverride = rec.originalOverride
    end
end

---@param rec wp.GhostRecord
local function endStraddle(rec)
    if IsValid(rec.ghost) then rec.ghost:Remove() end
    if IsValid(rec.ent) and rec.ent.RenderOverride == rec.originalOverride then
        rec.ent.RenderOverride = rec.savedRenderOverride
    end
    -- The entry clip rides on the entity, so it must be turned off or the prop stays
    -- half-clipped (body and shadow) once it leaves the portal.
    if IsValid(rec.ent) then rec.ent:SetRenderClipPlaneEnabled(false) end
    clearWeapon(rec)
    wp.ghosts[rec.ent] = nil
end

---@class wp.GroupCross
---@field portal linked_portal_door
---@field deadline number

---@class wp.GhostRecord
---@field ent Entity
---@field portal linked_portal_door
---@field exit linked_portal_door
---@field ghost Entity
---@field isLocalPlayer boolean
---@field skeletal boolean
---@field translucent boolean
---@field lastSeen number
---@field posBuf Vector
---@field angBuf Angle
---@field entryFrame VMatrix
---@field exitFrame VMatrix
---@field entryNrm Vector
---@field exitNrm Vector
---@field entryD number
---@field exitD number
---@field sig table
---@field originalOverride function
---@field hasDrawn boolean?
---@field savedRenderOverride function?
---@field shadowReady boolean?
---@field weapon Entity?
---@field weaponGhost Entity?
---@field weaponPose Entity?
---@field weaponHasDrawn boolean?
---@field weaponModel string?
---@field weaponSkin number?
---@field weaponOriginalOverride function?
---@field weaponSavedOverride function?
---@field weaponShadowReady boolean?

---@param ent Entity
---@param portal linked_portal_door
---@return wp.GhostRecord?
local function startStraddle(ent, portal)
    local exit = portal:GetExit()
    if not IsValid(exit) then return nil end

    local ghost = ClientsideModel(ent:GetModel(),
        isTranslucent(ent) and RENDERGROUP_TRANSLUCENT or RENDERGROUP_OPAQUE)
    if not IsValid(ghost) then return nil end

    local isLocalPlayer = ent == LocalPlayer()
    ghost.WPIsGhost = true
    ghost:SetNoDraw(false)
    -- Never draw shadows for the local player as you cannot normally see your own shadow
    ghost:DrawShadow(not isLocalPlayer)

    -- The PlayerColor material proxy reads ent:GetPlayerColor(); SetPlayerColor
    -- ERRORS on a ClientsideModel, so override the getter instead (the proxy calls
    -- this Lua method). Players only.
    if ent:IsPlayer() then
        ghost.GetPlayerColor = function() return ent:GetPlayerColor() end
    end

    local rec = {
        ent = ent,
        portal = portal,
        exit = exit,
        ghost = ghost,
        isLocalPlayer = isLocalPlayer,
        skeletal = ent:IsRagdoll() or ent:IsNPC() or ent:IsPlayer(),
        translucent = isTranslucent(ent),
        lastSeen = SysTime(),
        posBuf = Vector(),
        angBuf = Angle(),
        -- Reused scratch for the per-pose through-portal bone matrix.
        entryFrame = Matrix(),
        exitFrame = Matrix(),
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

---@param rec wp.GhostRecord
---@param now number
local function updateStraddle(rec, now)
    rec.lastSeen = now

    -- Re-read the exit each frame: a relinked portal can change it.
    local exit = rec.portal:GetExit()
    if not IsValid(exit) then return false end
    rec.exit = exit

    -- A change in translucency flips which render pass the ghost belongs to,
    -- which is baked in at ClientsideModel creation - rebuild on change.
    if isTranslucent(rec.ent) ~= rec.translucent then return false end

    -- Pose here only refreshes the ghost's cull bounds between draws; the overrides
    -- pose + plane for the actual draw.
    poseGhost(rec)

    -- Give the ghost its sun/RTT shadow once it has actually rendered: CreateShadow no-ops mid-render
    -- and on a never-drawn ClientsideModel, so do it here in the game loop after the override flagged
    -- hasDrawn. The per-frame MarkShadowAsDirty (in the Think) re-renders it so it tracks the prop and
    -- grows as it emerges; SetRenderClipPlane trims it to the exit half. Once only - CreateShadow per
    -- frame is severe lag. Skipped for the local player's own ghost (it stays shadowless).
    if rec.hasDrawn and not rec.shadowReady and not rec.isLocalPlayer then
        rec.shadowReady = true
        rec.ghost:CreateShadow()
    end

    syncAppearance(rec)
    ensureOriginalOverride(rec)
    updateWeapon(rec)
    return true
end

local seen = {}

-- Discovery (FindInSphere + straddle tests) is the bulk of the cost and needn't
-- run every frame: the ghost overrides re-pose/re-plane per draw and GHOST_GRACE
-- outlives the gap. Throttle to ~25 Hz.
local SCAN_INTERVAL = 0.04   -- seconds between discovery scans (~25 Hz)
local nextScan = 0

-- Max distance from an entity's origin to its farthest bound. FindInSphere culls on
-- origins, and an origin can sit far from the geometry that matters on BOTH sides of the
-- search: a prop's origin (e.g. a ladder's might be at one end) and a portal's (its box sits
-- behind the face, offset by 5 + thickness/2, and grows with width/height). Used for both.
---@param ent Entity
local function reachOf(ent)
    return ent:OBBCenter():Length() + ent:BoundingRadius()
end

-- The search radius is padded by the largest candidate's reach so a prop whose origin
-- sits far from its straddling geometry is still discovered; the straddle test then keys
-- off its OBB centre. Reach is ~static (model/scale), so cache it per entity on spawn;
-- the max only recomputes when an entity at the max leaves, scanning the cached values.
local seeded = false
-- Mode k (weak keys) auto removes entries when the key (entity) no longer exists via GC.
local reachByEnt = setmetatable({}, { __mode = "k" })
local maxReach = 0
-- Set a minimum so a straddling player/NPC/ragdoll is found even when no large props exist
local REACH_FLOOR = 256  

---@param ent Entity
local function trackReach(ent)
    if not IsValid(ent) then return end
    if isGhostableBody(ent) then
        local reach = reachOf(ent)
        reachByEnt[ent] = reach
        if reach > maxReach then maxReach = reach end
    end
end

local function refreshMaxReach()
    local m = 0
    for ent, reach in pairs(reachByEnt) do
        if IsValid(ent) and reach > m then m = reach end
    end
    maxReach = m
end

-- Bounds aren't populated on the creation frame, so measure a tick later.
hook.Add("OnEntityCreated", "WorldPortals_GhostReach", function(ent)
    timer.Simple(0, function() trackReach(ent) end)
end)

-- Drop the cached reach on removal; only losing an entity at the current max shrinks it
-- Weak keys on reachByEnt are a backstop should a removal ever be missed.
hook.Add("EntityRemoved", "WorldPortals_GhostReach", function(ent)
    local reach = reachByEnt[ent]
    if not reach then return end
    reachByEnt[ent] = nil
    if reach >= maxReach then refreshMaxReach() end
end)

-- Only ghost where the prop would actually teleport. wp-shouldtp is the right
-- "portal off" signal because it's position-independent (networked state), unlike
-- wp-shouldrender which is view-dependent and would vanish the ghost when you step
-- into a far-off interior. nil = no veto = ghost; a missed server-only veto just
-- shows a ghost that stays fully clipped (harmless).
---@param portal linked_portal_door
---@param ent Entity
local function wouldTeleport(portal, ent)
    return hook.Call("wp-shouldtp", GAMEMODE, portal, ent) ~= false
end

-- Ghost-only consumer veto (companion to wp-shouldtp).
---@param portal linked_portal_door
---@param ent Entity
local function wouldGhost(portal, ent)
    return hook.Call("wp-shouldghost", GAMEMODE, portal, ent) ~= false
end

-- Add ent to this frame's ghost set, keeping the nearest portal when more than one wants it
-- (straddling two portals, or a crossing mark plus a straddle).
---@param ent Entity
---@param portal linked_portal_door
local function keepNearest(ent, portal)
    local prev = seen[ent]
    if not prev then
        seen[ent] = portal
    else
        local pc = renderCenter(ent)
        local dn = (pc - portal:GetPos()):LengthSqr()
        local dp = (pc - prev:GetPos()):LengthSqr()
        if dn < dp then seen[ent] = portal end
    end
end

hook.Add("Think", "WorldPortals_Ghosts", function()
    if wp.drawing then return end
    if not cvGhosts:GetBool() then
        if next(wp.ghosts) then
            for _, rec in pairs(wp.ghosts) do endStraddle(rec) end
        end
        return
    end

    -- Keep each ghost's sun/RTT shadow re-rendering every frame. A ClientsideModel posed via
    -- SetPos/SetBoneMatrix only re-renders its shadow when its angle changes - pure translation
    -- leaves it frozen at its last extent, so the shadow wouldn't grow as the prop slides through.
    -- MarkShadowAsDirty forces the re-render; it's light (re-render, not recreate - CreateShadow per
    -- frame is severe lag). Gated on shadowReady (the shadow exists); the local player's own ghost is
    -- skipped (it has no shadow).
    for _, rec in pairs(wp.ghosts) do
        if not rec.isLocalPlayer then
            if rec.shadowReady and IsValid(rec.ghost) then rec.ghost:MarkShadowAsDirty() end
            if rec.weaponShadowReady and IsValid(rec.weaponGhost) then rec.weaponGhost:MarkShadowAsDirty() end
        end
    end

    local now = SysTime()
    if now < nextScan then return end
    nextScan = now + SCAN_INTERVAL

    -- Seed once for entities that predate our OnEntityCreated hook (already present at
    -- load, or after a Lua autorefresh).
    if not seeded then
        seeded = true
        for _, e in ipairs(ents.GetAll()) do trackReach(e) end
    end

    for k in pairs(seen) do seen[k] = nil end

    for _, portal in ipairs(wp.portals) do
        if IsValid(portal) and portal.GetOpen and portal:GetOpen()
            and portal:GetEnableTeleport() and IsValid(portal:GetExit()) then
            local ppos = portal:GetPos()
            local r = reachOf(portal) + math.max(maxReach, REACH_FLOOR)
            for _, ent in ipairs(ents.FindInSphere(ppos, r)) do
                if isCandidate(ent) and not wp.RidesPortal(ent, portal) and straddles(ent, portal)
                    and wouldTeleport(portal, ent) and wouldGhost(portal, ent) then
                    keepNearest(ent, portal)
                end
            end
        end
    end

    -- Fold in the server's crossing marks. Their ghost clip planes hide the real body and draw
    -- the emerged half, so a fully-past member needs no special casing beyond joining the set.
    for ent, cross in pairs(wp.groupCrossing) do
        local portal = cross.portal
        if now >= cross.deadline then
            wp.groupCrossing[ent] = nil
        elseif IsValid(ent) and IsValid(portal) and portal:GetOpen()
            and portal:GetEnableTeleport() and IsValid(portal:GetExit())
            and isCandidate(ent) and not wp.RidesPortal(ent, portal)
            and wouldTeleport(portal, ent) and wouldGhost(portal, ent) then
            keepNearest(ent, portal)
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

-- Re-point the ghost to the new pair the instant the entity teleports: the
-- discovery scan can't see the new position until next frame, so without this the
-- ghost flings through the stale pair for one frame (a half-body flicker). After
-- A->B the new entry is B (= portal:GetExit()). Idempotent, so resim-safe.
hook.Add("wp-teleport", "WorldPortals_GhostsTeleport", function(portal, ent)
    -- Teleported: drop the crossing mark. The member now emerges from the far side, which the
    -- re-point below and the normal straddle own.
    if ent then wp.groupCrossing[ent] = nil end

    local rec = ent and wp.ghosts[ent]
    if rec and IsValid(portal) then
        local newEntry = portal:GetExit()
        if IsValid(newEntry) and IsValid(newEntry:GetExit()) then
            rec.portal = newEntry
            rec.exit = newEntry:GetExit()
        end
    end
    nextScan = 0
end)

-- Refresh each flagged member's crossing mark. The scan ghosts them; a mark lapses on the
-- grace timeout or clears when the member teleports.
net.Receive("WorldPortals_CrossingGroup", function()
    local portal = net.ReadEntity()
    local n = net.ReadUInt(16)
    local deadline = SysTime() + GROUP_CROSS_GRACE
    for _ = 1, n do
        local ent = net.ReadEntity()
        if IsValid(ent) and IsValid(portal) then
            local rec = wp.groupCrossing[ent]
            if rec then
                rec.portal = portal
                rec.deadline = deadline
            else
                wp.groupCrossing[ent] = { portal = portal, deadline = deadline }
            end
        end
    end
    nextScan = 0   -- ghost the new members now, not on the next scan tick
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
