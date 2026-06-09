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
local FIND_MARGIN   = 256   -- extra radius around the portal for the candidate FindInSphere
-- The visible face sits 5u in front of portal:GetPos() (DrawQuadEasy at pos-fwd*5),
-- so clip the halves there, not at the crossing plane, to seam on the glowing face.
local FACE_OFFSET   = 5

wp.ghosts = wp.ghosts or {}   -- [entity] = record

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
    if ent:GetClass() ~= "prop_physics" and not ent:IsRagdoll()
        and not ent:IsNPC() and not ent:IsPlayer() then return false end
    -- A NoDraw'd prop is skipped by default (hidden for a reason) but a consumer can
    -- opt it back in via wp-shouldghost (e.g. a prop the consumer hides only in the
    -- local realm but still wants ghosted).
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

local function renderTransform(ent)
    return ent:GetRenderOrigin() or ent:GetPos(), ent:GetRenderAngles() or ent:GetAngles()
end

local function renderCenter(ent)
    local rpos, rang = renderTransform(ent)
    return LocalToWorld(ent:OBBCenter(), ANGLE_ZERO, rpos, rang)
end

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
local function faceOffset(portal)
    return FACE_OFFSET + portal:GetThickness()
end

-- Recompute the entry/exit clip planes (n . p = D) the halves are sliced on, each
-- at its portal's visible face; the exit folds in its pos/ang offsets so an offset
-- or relinked pair still seams cleanly.
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

-- Mirror the original's appearance onto the ghost: model/skin/bodygroups/scale/
-- materials diffed against a cached signature; colour/alpha applied at draw time.
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

-- Forward the studio render flags to DrawModel and any chained override (e.g. the
-- prop-spawn materialize effect reads them).
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

local YAW180 = Matrix()
YAW180:SetAngles(Angle(0, 180, 0))

-- Pose a skeletal ghost from the source's live skeleton: re-emit each world bone
-- matrix through the portal. Done inside the RenderOverride because SetBoneMatrix
-- is consumed by the next DrawModel (the engine's own SetupBones would clobber it).
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

-- An active weapon is a separate bone-merged entity the body ghost never draws,
-- so mirror it as a second sub-ghost handled symmetrically: real weapon gets the
-- entry clip, a weapon ClientsideModel at the exit gets the exit clip. Poses by
-- the same bone copy (its merge bones follow the hand).

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

-- Safe to call when no weapon is tracked.
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

-- Keep the weapon sub-ghost in step with the NPC/player's active weapon. The
-- ghost root is parked at the transformed weapon pose only for culling - its
-- bones are placed in world space by the override.
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
-- RenderOverride (a consumer's) so it still runs - just clipped.
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

local function updateStraddle(rec, now)
    rec.lastSeen = now

    -- Re-read the exit each frame: a relinked portal can change it.
    local exit = rec.portal:GetExit()
    if not IsValid(exit) then return false end
    rec.exit = exit

    -- A change in translucency flips which render pass the ghost belongs to,
    -- which is baked in at ClientsideModel creation - rebuild on change.
    if isTranslucent(rec.ent) ~= rec.translucent then return false end

    updatePlanes(rec)
    poseGhost(rec)
    syncAppearance(rec)
    ensureOriginalOverride(rec)
    updateWeapon(rec)
    return true
end

local seen = {}

-- Discovery (FindInSphere + straddle tests) is the bulk of the cost and needn't
-- run every frame: the pose is re-applied per-frame in PreDrawOpaqueRenderables
-- and GHOST_GRACE outlives the gap. Throttle to ~25 Hz.
local SCAN_INTERVAL = 0.04   -- seconds between discovery scans (~25 Hz)
local nextScan = 0

-- Only ghost where the prop would actually teleport. wp-shouldtp is the right
-- "portal off" signal because it's position-independent (networked state), unlike
-- wp-shouldrender which is view-dependent and would vanish the ghost when you step
-- into a far-off interior. nil = no veto = ghost; a missed server-only veto just
-- shows a ghost that stays fully clipped (harmless).
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

    for _, portal in ipairs(wp.portals) do
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

-- Authoritative ghost pose, after every Think (so cl_renderfollow.lua's render-follow
-- has finalized the original's transform) and right before the scene draws - keeps
-- the ghost glued even at extreme loop speeds.
hook.Add("PreDrawOpaqueRenderables", "WorldPortals_GhostPose", function(_, skybox)
    if skybox then return end
    if not next(wp.ghosts) then return end
    for ent, rec in pairs(wp.ghosts) do
        if IsValid(ent) and IsValid(rec.ghost) and IsValid(rec.exit) then
            poseGhost(rec)
        end
    end
end)
