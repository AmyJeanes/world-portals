-- Continuous entity rendering across portals ("portal clones").
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
--   * a clientside CLONE at the mirror-transformed exit pose, clipped to keep
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
-- Phase 1 (this file): physics props. Players are a later phase.

local ENABLE_DEFAULT = "1"
CreateClientConVar("worldportals_clones", ENABLE_DEFAULT, true, false,
    "World Portals - render continuous clipped clones of entities straddling a portal", 0, 1)

local CLONE_GRACE   = 0.1   -- seconds to keep a clone alive after the straddle test drops out (anti-flicker)
local OPENING_SLACK = 8     -- units of slack on the portal opening (width/height) test
local FIND_MARGIN   = 256   -- extra radius around the portal for the candidate FindInSphere
-- The portal's VISIBLE face sits 5 units in front (-forward) of portal:GetPos()
-- -- DrawQuadEasy draws at pos - fwd*5 and SetupBounds puts RenderMax.x at -5.
-- The crossing/teleport plane is at pos itself, 5 units behind the visible face.
-- Clipping the halves at pos cuts each prop 5 units short of the glowing surface
-- (visible as the entity vanishing before it reaches the portal, on both sides),
-- so the seam is placed on the visible face instead.
local FACE_OFFSET   = 5

wp.clones = wp.clones or {}   -- [entity] = record

-- Is this an entity we render clones for? Phase 1: physics props only, never a
-- clone we made.
local function isCandidate(ent)
    if not IsValid(ent) then return false end
    if ent.WPIsClone then return false end
    if ent:GetClass() ~= "prop_physics" then return false end
    if ent:GetNoDraw() then return false end
    return true
end

local function isTranslucent(ent)
    if ent:GetRenderMode() ~= RENDERMODE_NORMAL then return true end
    if ent:GetColor().a < 255 then return true end
    return false
end

local ANGLE_ZERO = Angle()

-- The transform the original is actually RENDERED at -- the single source of
-- truth for gluing the clone (and the entry clip) to the visible prop. While
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

-- Mirror the original's current render transform through the pair onto the clone.
local function poseClone(rec)
    local rpos, rang = renderTransform(rec.ent)
    wp.TransformPortalPosInto(rec.posBuf, rpos, rec.portal, rec.exit)
    wp.TransformPortalAngleInto(rec.angBuf, rang, rec.portal, rec.exit)
    rec.clone:SetPos(rec.posBuf)
    rec.clone:SetAngles(rec.angBuf)
end

-- Does ent's bounds cross portal's plane, within the portal opening? Conservative
-- (over-detects): a near-but-not-crossing prop just produces a fully-clipped
-- (invisible) clone and a fully-drawn original, i.e. no visible change.
local function straddles(ent, portal)
    local pos = portal:GetPos()
    local fwd = portal:GetForward()
    local center = renderCenter(ent)
    local d = fwd.x * (center.x - pos.x) + fwd.y * (center.y - pos.y) + fwd.z * (center.z - pos.z)
    if math.abs(d) >= ent:BoundingRadius() then return false end

    local lc = portal:WorldToLocal(center)
    local mins, maxs = portal:GetCollisionBounds()
    if lc.y < mins.y - OPENING_SLACK or lc.y > maxs.y + OPENING_SLACK
        or lc.z < mins.z - OPENING_SLACK or lc.z > maxs.z + OPENING_SLACK then
        return false
    end
    return true
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

-- Mirror the original's visual customizations onto the clone. Entity-state
-- fields (model/skin/bodygroups/scale/materials) are diffed against a cached
-- signature and only re-applied on change; colour/alpha is applied at draw time
-- (render.SetColorModulation/SetBlend) where it reliably affects DrawModel.
local function syncAppearance(rec)
    local ent, clone, sig = rec.ent, rec.clone, rec.sig

    local model = ent:GetModel()
    if sig.model ~= model then clone:SetModel(model); sig.model = model end

    local skin = ent:GetSkin()
    if sig.skin ~= skin then clone:SetSkin(skin); sig.skin = skin end

    for i = 0, ent:GetNumBodyGroups() - 1 do
        local v = ent:GetBodygroup(i)
        if sig["bg" .. i] ~= v then clone:SetBodygroup(i, v); sig["bg" .. i] = v end
    end

    local scale = ent:GetModelScale()
    if sig.scale ~= scale then clone:SetModelScale(scale); sig.scale = scale end

    local mat = ent:GetMaterial()
    if sig.mat ~= mat then clone:SetMaterial(mat); sig.mat = mat end

    local mats = ent:GetMaterials()
    if mats then
        for i = 1, #mats do
            local sub = ent:GetSubMaterial(i - 1)
            if sig["sm" .. i] ~= sub then clone:SetSubMaterial(i - 1, sub); sig["sm" .. i] = sub end
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

local function makeCloneOverride(rec)
    return function(self, flags)
        local ent = rec.ent
        if not IsValid(ent) then return end
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
    if IsValid(rec.clone) then rec.clone:Remove() end
    if IsValid(rec.ent) and rec.ent.RenderOverride == rec.originalOverride then
        rec.ent.RenderOverride = rec.savedRenderOverride
    end
    wp.clones[rec.ent] = nil
end

local function startStraddle(ent, portal)
    local exit = portal:GetExit()
    if not IsValid(exit) then return nil end

    local clone = ClientsideModel(ent:GetModel(),
        isTranslucent(ent) and RENDERGROUP_TRANSLUCENT or RENDERGROUP_OPAQUE)
    if not IsValid(clone) then return nil end

    clone.WPIsClone = true
    clone:SetNoDraw(false)
    clone:DrawShadow(false)

    local rec = {
        ent = ent,
        portal = portal,
        exit = exit,
        clone = clone,
        translucent = isTranslucent(ent),
        lastSeen = SysTime(),
        posBuf = Vector(),
        angBuf = Angle(),
        entryNrm = Vector(),
        exitNrm = Vector(),
        entryD = 0,
        exitD = 0,
        sig = {},
    }
    rec.originalOverride = makeOriginalOverride(rec)
    clone.RenderOverride = makeCloneOverride(rec)
    wp.clones[ent] = rec
    return rec
end

local function updateStraddle(rec, now)
    rec.lastSeen = now

    -- Re-read the exit each frame: a relinked portal can change it.
    local exit = rec.portal:GetExit()
    if not IsValid(exit) then return false end
    rec.exit = exit

    -- A change in translucency flips which render pass the clone belongs to,
    -- which is baked in at ClientsideModel creation -- rebuild on change.
    if isTranslucent(rec.ent) ~= rec.translucent then return false end

    updatePlanes(rec)
    poseClone(rec)
    syncAppearance(rec)
    ensureOriginalOverride(rec)
    return true
end

local seen = {}

hook.Add("Think", "WorldPortals_Clones", function()
    if wp.drawing then return end
    if not GetConVar("worldportals_clones"):GetBool() then
        if next(wp.clones) then
            for _, rec in pairs(wp.clones) do endStraddle(rec) end
        end
        return
    end

    local now = SysTime()

    for k in pairs(seen) do seen[k] = nil end

    local portals = wp.portals
    if not portals then portals = ents.FindByClass("linked_portal_door") end

    for _, portal in ipairs(portals) do
        if IsValid(portal) and portal.GetOpen and portal:GetOpen()
            and portal:GetEnableTeleport() and IsValid(portal:GetExit()) then
            local ppos = portal:GetPos()
            local r = portal:BoundingRadius() + FIND_MARGIN
            for _, ent in ipairs(ents.FindInSphere(ppos, r)) do
                if isCandidate(ent) and straddles(ent, portal) then
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
        local rec = wp.clones[ent]
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
    for ent, rec in pairs(wp.clones) do
        if not IsValid(ent) or not IsValid(rec.portal) or not IsValid(rec.clone) then
            expired = expired or {}
            expired[#expired + 1] = rec
        elseif not seen[ent] and (now - rec.lastSeen) > CLONE_GRACE then
            expired = expired or {}
            expired[#expired + 1] = rec
        end
    end
    if expired then
        for _, rec in ipairs(expired) do endStraddle(rec) end
    end
end)

hook.Add("EntityRemoved", "WorldPortals_Clones", function(ent)
    local direct = wp.clones[ent]
    if direct then endStraddle(direct) end

    -- A removed portal/exit/clone invalidates any record referencing it.
    local victims
    for e, rec in pairs(wp.clones) do
        if e ~= ent and (rec.portal == ent or rec.exit == ent or rec.clone == ent) then
            victims = victims or {}
            victims[#victims + 1] = rec
        end
    end
    if victims then
        for _, rec in ipairs(victims) do endStraddle(rec) end
    end
end)

-- Authoritative clone pose, applied after every Think (so cl_init.lua's rapid-loop
-- render-follow has finalized the original's SetRenderOrigin) and right before the
-- scene draws. Re-posing here from the original's live render transform keeps the
-- clone glued to the visible prop even at extreme loop speeds, where a Think-time
-- pose lagged the follow by a sub-frame and split the prop into two offset halves.
hook.Add("PreDrawOpaqueRenderables", "WorldPortals_ClonePose", function(_, skybox)
    if skybox then return end
    if not next(wp.clones) then return end
    for ent, rec in pairs(wp.clones) do
        if IsValid(ent) and IsValid(rec.clone) and IsValid(rec.exit) then
            poseClone(rec)
        end
    end
end)
