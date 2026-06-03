-- Teleport

-- Predicted player teleport (SetupMove): server for everyone, client for
-- LocalPlayer, so the local view stays in lockstep without the snapshot.
-- Non-player entities go through ENT:Touch.
local ANGLE_VR_YAW_REF = Angle(0, 0, 0)
-- Slack in front of the plane that still fires this tick — catches a slow
-- creeper whose next, accelerated tick would step over the plane.
local CROSS_SKIN = 2
-- Noclip discards the mirrored exit velocity (FullNoClipMove rederives it from
-- input), so a same-facing pair (TARDIS) re-crosses and ping-pongs. Briefly
-- suppress re-fire so the view rotation can steer them clear.
local NOCLIP_TP_COOLDOWN = 0.25
local function predictPlayerTeleport(ply, mv, cmd)
    if CLIENT and ply ~= LocalPlayer() then return end
    if not ply:Alive() then return end

    local velocity = mv:GetVelocity()
    if velocity:LengthSqr() < 1 then return end

    -- since > 0 is resim-safe: CurTime() in SetupMove is the predicted-tick time,
    -- so it's 0 on the teleport tick's own resims, positive on later ticks.
    if ply:GetMoveType() == MOVETYPE_NOCLIP and ply.wpNoclipTpAt then
        local since = CurTime() - ply.wpNoclipTpAt
        if since > 0 and since < NOCLIP_TP_COOLDOWN then return end
    end

    local origin = mv:GetOrigin()
    local frameTime = FrameTime()

    -- Two crossing points: the EYE (also the anti-cull front guard — it must
    -- stay in front of portal:GetPos() or the stencil culls) and the hull CENTRE
    -- (also drives the face bounds). Fire when EITHER crosses. They differ only
    -- by 28*forward.z, so walls are unchanged and only floor portals gain the
    -- centre trigger (an eye-only test can't fire while you stand on one).
    local eyePos = ply:EyePos()
    local nextEyeX = eyePos.x + velocity.x * frameTime
    local nextEyeY = eyePos.y + velocity.y * frameTime
    local nextEyeZ = eyePos.z + velocity.z * frameTime
    local omins, omaxs = ply:OBBMins(), ply:OBBMaxs()
    local hullCenterX = origin.x + (omins.x + omaxs.x) * 0.5
    local hullCenterY = origin.y + (omins.y + omaxs.y) * 0.5
    local hullCenterZ = origin.z + (omins.z + omaxs.z) * 0.5
    local nextCenterX = hullCenterX + velocity.x * frameTime
    local nextCenterY = hullCenterY + velocity.y * frameTime
    local nextCenterZ = hullCenterZ + velocity.z * frameTime

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
        -- Plane = portal:GetPos(), the same plane cl_render.lua culls on, so the
        -- teleport must fire before the cull hides the volume.
        local distNow  = (eyePos.x - pos.x) * fwd.x + (eyePos.y - pos.y) * fwd.y + (eyePos.z - pos.z) * fwd.z
        -- Re-teleport guard: the eye must be in front of the plane to fire, so
        -- the exit (the pair are each other's exits) doesn't immediately re-fire
        -- and bounce the player. Thick portals allow firing back to the cull
        -- plane so you can re-cross their walkable volume — except in noclip,
        -- where the un-mirrored velocity would just re-fire the bounce.
        local thickness = portal:GetThickness()
        local backLimit = (thickness > 0 and ply:GetMoveType() ~= MOVETYPE_NOCLIP) and -thickness or 0
        if distNow <= backLimit then goto cont end
        local distNext = (nextEyeX - pos.x) * fwd.x + (nextEyeY - pos.y) * fwd.y + (nextEyeZ - pos.z) * fwd.z
        local centerNow  = (hullCenterX - pos.x) * fwd.x + (hullCenterY - pos.y) * fwd.y + (hullCenterZ - pos.z) * fwd.z
        local centerNext = (nextCenterX - pos.x) * fwd.x + (nextCenterY - pos.y) * fwd.y + (nextCenterZ - pos.z) * fwd.z
        -- "Reaches" = crosses next tick, or already within CROSS_SKIN moving
        -- toward the plane (the slow-walk net; fast movers hit the cross first).
        local eyeReaches    = distNext   <= 0 or distNow   <= CROSS_SKIN
        local centerReaches = centerNext <= 0 or centerNow <= CROSS_SKIN
        if not (eyeReaches or centerReaches) then goto cont end

        -- Face bounds on the hull CENTRE, not the eye — fixes the jump-over (the
        -- eye clears the top edge while the body still passes through).
        local localCenter = portal:WorldToLocal(Vector(hullCenterX, hullCenterY, hullCenterZ))
        local mins, maxs = portal:GetCollisionBounds()
        if localCenter.y < mins.y or localCenter.y > maxs.y or localCenter.z < mins.z or localCenter.z > maxs.z then
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
        -- mv:SetAngles is what gamemovement reads for W/S/A/D direction; without
        -- it, walking backward through a portal mangles your motion direction.
        mv:SetAngles(clampedAng)
        cmd:SetViewAngles(clampedAng)
        -- Every pass (resim included): resets the AbsOrigin interp cache and
        -- makes ply:GetPos() report the destination before wp-teleport runs, so
        -- a consumer unstick resolves against it. First-time-only here left the
        -- player stuck at the raw transform for ~RTT at high ping.
        ply:SetPos(newPos)
        -- SetEyeAngles actually rotates the camera (cmd:SetViewAngles alone
        -- no-ops). Client + first-time only: a server write or a resim re-write
        -- both snap back mouse moved during the window. SP runs no client
        -- prediction, so there the server write is the only path.
        if (CLIENT and IsFirstTimePredicted()) or (SERVER and game.SinglePlayer()) then
            ply:SetEyeAngles(clampedAng)
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
            -- Fold a consumer's ply:SetPos relocation back into mv, else
            -- FinishMove reverts it. newPos rides out in the broadcast below.
            local finalPos = ply:GetPos()
            if finalPos ~= newPos then
                mv:SetOrigin(finalPos)
                newPos = finalPos
            end
            -- Remote clients need an immediate update; the crosser predicted it.
            net.Start("WorldPortals_Teleport")
                net.WriteEntity(portal)
                net.WriteEntity(ply)
                net.WriteVector(newPos)
                net.WriteAngle(newAng)
            net.Broadcast()
        else
            -- CLIENT (LocalPlayer), every pass — first-time AND resim. The hook
            -- (and the mv re-sync below folding a consumer relocation back in)
            -- must re-run each resim or the player reverts to the raw transform
            -- for the unacked window. Consumers' wp-teleport handlers must be
            -- idempotent/resim-safe.
            hook.Call("wp-teleport", GAMEMODE, portal, ply, newPos, newAng)
            local finalPos = ply:GetPos()
            if finalPos ~= newPos then
                mv:SetOrigin(finalPos)
                newPos = finalPos
            end
            -- First-time only: arm persistent client-frame state that must NOT
            -- re-fire on resim (re-arming would reset it every frame all window).
            if IsFirstTimePredicted() then
                -- Roll fade + stair strip; shared with the SP net handler.
                if wp.ArmTeleportView then wp.ArmTeleportView(newAng) end
                -- Predict-lerp shift window: CalcView shifts the camera by
                -- (NetworkOrigin - GetPos) while the engine lerps AbsOrigin for
                -- ~RTT after the snap. SysTime, not CurTime (the future tick time).
                wp.predictedPos = newPos
                wp.predictedOldPos = origin
                wp.predictedAt = SysTime()
                wp.predictArmCount = (wp.predictArmCount or 0) + 1
                if wp.RecordTeleportEvent then
                    wp.RecordTeleportEvent(portal, origin, newPos, oldEyeAng, clampedAng, oldVel, newVel)
                end
            end
        end
        -- Arm the noclip re-teleport cooldown (idempotent across resim).
        if ply:GetMoveType() == MOVETYPE_NOCLIP then
            ply.wpNoclipTpAt = CurTime()
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
            -- Keep the original StartPos (not the exit-side start): consumers
            -- expect StartPos == the start they asked for (the camera tool
            -- spawned inside the portal otherwise). HitPos/Entity/Normal stay
            -- exit-side, so see-through traces are unchanged.
            tr.StartPos = trace.StartPos
            return tr
        end
    end
    return trace
end

util.TraceLine = WorldPortals_TraceLine
hook.Add("InitPostEntity", "WorldPortals_TraceLine", function()
    util.TraceLine = WorldPortals_TraceLine
end)