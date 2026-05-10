
-- Predicted player teleport. Runs in the prediction loop on both server (every
-- player) and client (LocalPlayer only), so the local player's position stays
-- in lockstep without waiting for the server snapshot. Non-player entities
-- still go through ENT:Touch — they can't be client-predicted.
local ANGLE_VR_YAW_REF = Angle(0, 0, 0)
local function predictPlayerTeleport(ply, mv, cmd)
    if CLIENT and ply ~= LocalPlayer() then return end
    if not ply:Alive() then return end

    local velocity = mv:GetVelocity()
    if velocity:LengthSqr() < 1 then return end

    local origin = mv:GetOrigin()
    local eyePos = ply:EyePos()
    local frameTime = FrameTime()
    local nextEyeX = eyePos.x + velocity.x * frameTime
    local nextEyeY = eyePos.y + velocity.y * frameTime
    local nextEyeZ = eyePos.z + velocity.z * frameTime

    for _, portal in ipairs(ents.FindByClass("linked_portal_door")) do
        -- Freshly-spawned portals can appear in FindByClass before their
        -- NetworkVar accessors are wired up (Initialize / SetupDataTables
        -- hasn't run on this realm yet). Skip until they're fully alive.
        if not IsValid(portal) or not portal.GetOpen then goto cont end
        if not (portal:GetOpen() and portal:GetEnableTeleport()) then goto cont end

        local exit = portal:GetExit()
        if not IsValid(exit) then goto cont end

        local fwd = portal:GetForward()
        if velocity:Dot(fwd) >= 0 then goto cont end

        local pos = portal:GetPos()
        -- Test against the back-face cull plane in cl_render.lua's
        -- wp.shouldrender (= portal:GetPos() for thin portals). Once the eye
        -- crosses this plane the stencil stops rendering, exposing the world
        -- behind the portal — so the teleport must fire before then.
        local distNow  = (eyePos.x - pos.x) * fwd.x + (eyePos.y - pos.y) * fwd.y + (eyePos.z - pos.z) * fwd.z
        if distNow <= 0 then goto cont end
        local distNext = (nextEyeX - pos.x) * fwd.x + (nextEyeY - pos.y) * fwd.y + (nextEyeZ - pos.z) * fwd.z
        if distNext > 0 then goto cont end

        -- Quad bounds check at the projected crossing point. X is portal-local
        -- forward (already covered by the plane test); Y/Z are the face.
        local localEye = portal:WorldToLocal(Vector(nextEyeX, nextEyeY, nextEyeZ))
        local mins, maxs = portal:GetCollisionBounds()
        if localEye.y < mins.y or localEye.y > maxs.y or localEye.z < mins.z or localEye.z > maxs.z then
            goto cont
        end

        if hook.Call("wp-shouldtp", GAMEMODE, portal, ply) == false then goto cont end

        -- Capture pre-teleport state for the debug HUD before any mutation.
        local oldEyeAng = cmd:GetViewAngles()
        local oldVel = Vector(velocity.x, velocity.y, velocity.z)

        local newPos = wp.TransformPortalPos(origin, portal, exit)
        local newVel = wp.TransformPortalVector(velocity, portal, exit)
        local newAng = wp.TransformPortalAngle(oldEyeAng, portal, exit)

        -- Keep eyeline level when teleporting through a roll (matches the
        -- prior server-side Touch math).
        local height = ply:OBBMaxs().z
        local upRot = Vector(0, 0, height)
        upRot:Rotate(Angle(0, 0, newAng.r))
        newPos = newPos + Vector(0, 0, (upRot.z - height) / 2)

        local clampedAng = Angle(newAng.p, newAng.y, 0)
        mv:SetOrigin(newPos)
        mv:SetVelocity(newVel)
        -- mv:SetAngles is what gamemovement reads to decide which world
        -- direction W/S/A/D push toward; without it the engine still uses the
        -- pre-teleport view angles for input, which manifests as "walking
        -- backward through a portal mangles your motion direction" because
        -- backward input * old view ≠ backward input * new view.
        mv:SetAngles(clampedAng)
        -- ply:SetEyeAngles is what actually rotates the camera; cmd:SetViewAngles
        -- alone only mutates the input cmd struct, leaving the eye angles on
        -- their last-input value (so directional portals appeared to no-op).
        ply:SetEyeAngles(clampedAng)
        cmd:SetViewAngles(clampedAng)
        -- mv:SetOrigin updates the move buffer but not the entity's AbsOrigin
        -- interpolation pipeline, so for a few frames after teleport
        -- ply:GetPos() lerps from old to new (visible as a position slide).
        -- ply:SetPos snaps the entity (same path the broadcast SetPos hits
        -- for remote clients) and resets the interp cache. Skipped during
        -- resimulation so we don't repeatedly snap to the same value.
        if SERVER or IsFirstTimePredicted() then
            ply:SetPos(newPos)
        end

        if SERVER then
            if vrmod and vrmod.IsPlayerInVR(ply) then
                net.Start("WorldPortals_VRMod_SetAngle")
                    net.WriteDouble(wp.TransformPortalAngle(ANGLE_VR_YAW_REF, portal, exit).y)
                net.Send(ply)
            end
            ply:ForcePlayerDrop()
            portal:TriggerOutput("OnPlayerTeleportFromMe", ply)
            exit:TriggerOutput("OnPlayerTeleportToMe", ply)
            hook.Call("wp-teleport", GAMEMODE, portal, ply, newPos, newAng)
            -- Remote clients still need an immediate position update; the
            -- player who crossed predicts it themselves and skips the apply.
            net.Start("WorldPortals_Teleport")
                net.WriteEntity(portal)
                net.WriteEntity(ply)
                net.WriteVector(newPos)
                net.WriteAngle(newAng)
            net.Broadcast()
        elseif IsFirstTimePredicted() then
            if newAng.r ~= 0 then
                wp.rotating = newAng.r
            end
            -- Arm the predict-lerp shift window. ply:SetPos snaps the entity
            -- but the engine still lerps AbsOrigin from the pre-teleport
            -- snapshot for ~RTT until a snapshot captured after the server
            -- ran SetupMove arrives. CalcView/CalcViewModelView in
            -- cl_teleport.lua shift the camera + viewmodel by
            -- (NetworkOrigin - GetPos) each frame during this window so the
            -- scene renders from where the server thinks the player is
            -- (eye-in-renderbounds works, no blank-sky frame). Disarms on
            -- convergence or timeout. Local playermodel is left to lerp —
            -- SetRenderOrigin is a no-op for the local player and the model
            -- isn't visible to ourselves in first-person anyway.
            -- SysTime, not CurTime: CurTime inside SetupMove is the
            -- predicted-tick time (advanced into the future), so comparing
            -- against CurTime in CalcView yields negative ages.
            wp.predictedPos = newPos
            wp.predictedOldPos = origin  -- pre-teleport pos, used by getPredictDelta sanity check
            wp.predictedAt = SysTime()
            wp.predictArmCount = (wp.predictArmCount or 0) + 1
            hook.Call("wp-teleport", GAMEMODE, portal, ply, newPos, newAng)
            if wp.RecordTeleportEvent then
                wp.RecordTeleportEvent(portal, origin, newPos, oldEyeAng, clampedAng, oldVel, newVel)
            end
        end
        do return end
        ::cont::
    end
end
hook.Add("SetupMove", "WorldPortals_PredictTeleport", predictPlayerTeleport)

hook.Add("EntityFireBullets", "WorldPortals_Bullets", function(ent,data)
    local src, dir, distance = data.Src, data.Dir, data.Distance
    if not src then return end
    if not dir then return end
    if not distance then return end
    local bulletFilter = {ent}
    if data.IgnoreEntity then table.insert(bulletFilter, data.IgnoreEntity) end
    local trace = util.RealTraceLine({
        start = src,
        endpos = src + dir * distance,
        filter = bulletFilter,
    } --[[@as Trace]])

    local portal = wp.GetFirstPortalHit(src, dir)

    if IsValid(portal.Entity) and portal.Distance < trace.HitPos:Distance(src) then
        local localHitPos = portal.Entity:WorldToLocal(portal.HitPos)
        local mins, maxs = portal.Entity:GetCollisionBounds()
        if localHitPos.y > mins.y and localHitPos.y < maxs.y
        and localHitPos.z > mins.z and localHitPos.z < maxs.z
        and hook.Call("wp-trace", GAMEMODE, portal.Entity)~=false then
            data.Src=wp.TransformPortalPos( portal.HitPos, portal.Entity, portal.Entity:GetExit() )
            data.Dir=wp.TransformPortalAngle( dir:Angle(), portal.Entity, portal.Entity:GetExit() ):Forward()

            local traceFilter = hook.Call("wp-tracefilter", GAMEMODE, portal.Entity)
            if IsValid(traceFilter) then
                data.IgnoreEntity = traceFilter
            end

            return true
        end
    end
end)

if not util.RealTraceLine then
    util.RealTraceLine = util.TraceLine
end

function WorldPortals_TraceLine(data)
    local trace = util.RealTraceLine(data)
    local portal = wp.GetFirstPortalHit(trace.StartPos, trace.Normal)

    if IsValid(portal.Entity) and portal.Distance < trace.HitPos:Distance(trace.StartPos) then
        local localHitPos = portal.Entity:WorldToLocal(portal.HitPos)
        local mins, maxs = portal.Entity:GetCollisionBounds()

        if localHitPos.y > mins.y and localHitPos.y < maxs.y
        and localHitPos.z > mins.z and localHitPos.z < maxs.z
        and hook.Call("wp-trace", GAMEMODE, portal.Entity)~=false then
            local angle = wp.TransformPortalAngle( trace.Normal:Angle(), portal.Entity, portal.Entity:GetExit() ):Forward()
            local startPos = wp.TransformPortalPos( portal.HitPos, portal.Entity, portal.Entity:GetExit() )

            local length = data.start:Distance(data.endpos)
            local usedLength = portal.Distance

            local endPos = angle
            endPos:Mul(length + 32 - usedLength)
            endPos:Add(startPos)
            
            local hookFilter = hook.Call("wp-tracefilter", GAMEMODE, portal.Entity)
            local newFilter = data.filter
            if IsValid(hookFilter) then
                if newFilter == nil then
                    newFilter = hookFilter
                elseif type(newFilter) == "table" then
                    newFilter = {unpack(newFilter)}
                    table.insert(newFilter, hookFilter)
                elseif type(newFilter) ~= "function" then
                    newFilter = {newFilter, hookFilter}
                end
            end

            local tr = util.RealTraceLine({
                start = startPos,
                endpos = endPos,
                mask = data.mask,
                filter = newFilter,
            })
            return tr
        end
    end
    return trace
end

util.TraceLine = WorldPortals_TraceLine
hook.Add("InitPostEntity", "WorldPortals_TraceLine", function()
    util.TraceLine = WorldPortals_TraceLine
end)