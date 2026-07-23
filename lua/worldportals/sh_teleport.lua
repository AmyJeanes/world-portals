-- Teleport

-- Predicted player teleport (SetupMove): server for everyone, client for
-- LocalPlayer. Both realms run the teleport on the same move command in the same
-- tick, so the local view moves the instant you cross instead of waiting ~RTT for
-- the server's snapshot to confirm it (client-side prediction).
-- Non-player entities go through ENT:Touch.
local ANGLE_VR_YAW_REF = Angle(0, 0, 0)
-- Slack in front of the plane that still fires this tick - catches a slow
-- creeper whose next, accelerated tick would step over the plane.
local CROSS_SKIN = 2
-- Re-fire suppression window after a teleport (the bounce guard).
local TP_REFIRE_COOLDOWN = 0.25
---@param ply Player
---@param mv CMoveData
---@param cmd CUserCmd
local function predictPlayerTeleport(ply, mv, cmd)
    if CLIENT and ply ~= LocalPlayer() then return end
    if not ply:Alive() then return end

    local velocity = mv:GetVelocity()
    if velocity:LengthSqr() < 1 then return end

    -- sinceTp > 0 excludes the teleport tick's own resims (CurTime is the tick time).
    local sinceTp = ply.wpTpAt and (CurTime() - ply.wpTpAt) or nil
    local recentTp = sinceTp ~= nil and sinceTp > 0 and sinceTp < TP_REFIRE_COOLDOWN
    -- Noclip loses the mirrored exit velocity, so a same-facing pair ping-pongs.
    if recentTp and ply:GetMoveType() == MOVETYPE_NOCLIP then return end

    local origin = mv:GetOrigin()
    local frameTime = FrameTime()

    -- Two crossing points: the player's eye (the normal case) and the hull
    -- centre, so a portal angled away from the eyeline (e.g. on the floor) can be
    -- entered without putting your eye right up to it; fire when EITHER crosses.
    -- They differ only by 28*forward.z, so walls are unchanged, only floors gain it.
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

    for _, portal in ipairs(wp.portals) do
        -- A portal can be in the registry before its NetworkVar accessors are
        -- wired up (registered late in Initialize, but a stale entry could
        -- survive a frame). Skip until it's fully alive.
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
        -- Thick portals allow firing back to the cull plane (their walkable volume),
        -- except in noclip where the un-mirrored velocity would just re-fire the bounce.
        local thickness = portal:GetThickness()
        local backLimit = (thickness > 0 and ply:GetMoveType() ~= MOVETYPE_NOCLIP) and -thickness or 0
        -- Behind the plane: block within the re-fire window (bounce); past it pick up a
        -- slow-crosser, but only within the visible face so far-behind steps don't yank you in.
        local limit = recentTp and backLimit or math.min(backLimit, wp.PortalFaceOffset(portal))
        if distNow <= limit then goto cont end
        local distNext = (nextEyeX - pos.x) * fwd.x + (nextEyeY - pos.y) * fwd.y + (nextEyeZ - pos.z) * fwd.z
        local centerNow  = (hullCenterX - pos.x) * fwd.x + (hullCenterY - pos.y) * fwd.y + (hullCenterZ - pos.z) * fwd.z
        local centerNext = (nextCenterX - pos.x) * fwd.x + (nextCenterY - pos.y) * fwd.y + (nextCenterZ - pos.z) * fwd.z
        -- "Reaches" = crosses next tick, or already within CROSS_SKIN moving
        -- toward the plane (the slow-walk net; fast movers hit the cross first).
        local eyeReaches    = distNext   <= 0 or distNow   <= CROSS_SKIN
        local centerReaches = centerNext <= 0 or centerNow <= CROSS_SKIN
        if not (eyeReaches or centerReaches) then goto cont end

        -- Face bounds: fire if EITHER the hull centre or the eye projects inside
        -- the opening, matching the eye-OR-centre crossing above. Centre covers
        -- the jump-over (eye clears the top edge while the body passes through);
        -- eye covers a portal smaller than the player mounted off-centre, where
        -- the eye enters the hole but the centre misses the face.
        local mins, maxs = portal:GetCollisionBounds()
        local lc = portal:WorldToLocal(Vector(hullCenterX, hullCenterY, hullCenterZ))
        local le = portal:WorldToLocal(eyePos)
        local centerInFace = lc.y >= mins.y and lc.y <= maxs.y and lc.z >= mins.z and lc.z <= maxs.z
        local eyeInFace    = le.y >= mins.y and le.y <= maxs.y and le.z >= mins.z and le.z <= maxs.z
        if not (centerInFace or eyeInFace) then goto cont end

        if hook.Call("wp-shouldtp", GAMEMODE, portal, ply) == false then goto cont end

        -- Capture pre-teleport state for the debug HUD before any mutation.
        local oldEyeAng = cmd:GetViewAngles()
        local oldVel = Vector(velocity.x, velocity.y, velocity.z)

        local newPos = wp.TransformPortalPos(origin, portal, exit)
        local newVel = wp.TransformPortalVector(velocity, portal, exit)
        local newAng = wp.TransformPortalAngle(oldEyeAng, portal, exit)

        -- Keep eyeline level when teleporting through a roll.
        local height = ply:OBBMaxs().z
        local upRot = Vector(0, 0, height)
        upRot:Rotate(Angle(0, 0, newAng.r))
        newPos = newPos + Vector(0, 0, (upRot.z - height) / 2)

        local clampedAng = Angle(newAng.p, newAng.y, 0)
        mv:SetOrigin(newPos)
        mv:SetVelocity(newVel)
        -- Some movement code reads the entity velocity, not the move's, so mirror
        -- there too. SetLocalVelocity: SetAbsVelocity no-ops for a predicted player.
        ply:SetLocalVelocity(newVel)
        mv:SetAngles(clampedAng)
        -- Game movement builds the WASD wish-dir from the move angles, not the view;
        -- without SetMoveAngles the tick after teleport steers along the old heading.
        mv:SetMoveAngles(clampedAng)
        cmd:SetViewAngles(clampedAng)
        -- Every pass (resim included): resets the AbsOrigin interp cache and makes
        -- ply:GetPos() report the destination before wp-teleport runs, so a consumer
        -- unstick resolves against it. First-time-only would leave the player stuck
        -- at the raw transform for ~RTT at high ping.
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
            -- CLIENT (LocalPlayer), every pass - first-time AND resim. The hook
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
        -- Arm the re-fire window (idempotent across resim).
        ply.wpTpAt = CurTime()
        -- One teleport per tick: this returns from the whole scan. `goto cont`
        -- above is the loop's "continue" (Lua has no continue keyword); `do return
        -- end` wraps the return so the `::cont::` label can follow it (a bare
        -- return must be the last statement in its block).
        do return end
        ::cont::
    end
end
hook.Add("SetupMove", "WorldPortals_PredictTeleport", predictPlayerTeleport)

-- True when `trace` reaches `portal` -- the portal is nearer than the first real obstruction. A door
-- filling the portal's own opening (solid serverside only) is not one: wp-tracefilter names a portal's
-- far-side door, so this portal's near door is its exit's, and hitting only that still reaches it.
---@param portal {Entity: linked_portal_door, Distance: number, HitPos: Vector}
---@param trace TraceResult
---@return boolean
local function portalReached(portal, trace)
    if portal.Distance < trace.HitPos:Distance(trace.StartPos) then return true end
    local exit = portal.Entity:GetExit()
    return IsValid(exit) and trace.Entity == hook.Call("wp-tracefilter", GAMEMODE, exit)
end

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
    })

    local portal = wp.GetFirstPortalHit(src, dir)

    if IsValid(portal.Entity) and portalReached(portal, trace) then
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
    -- A typed local keeps the detour below from leaking back into RealTraceLine's type.
    ---@type fun(traceConfig: Trace): TraceResult
    local engineTraceLine = util.TraceLine
    util.RealTraceLine = engineTraceLine
end

---@param data Trace
---@return TraceResult
function WorldPortals_TraceLine(data)
    local trace = util.RealTraceLine(data)
    local portal = wp.GetFirstPortalHit(trace.StartPos, trace.Normal)

    if IsValid(portal.Entity) and portalReached(portal, trace) then
        local localHitPos = portal.Entity:WorldToLocal(portal.HitPos)
        local mins, maxs = portal.Entity:GetCollisionBounds()

        if localHitPos.y > mins.y and localHitPos.y < maxs.y
        and localHitPos.z > mins.z and localHitPos.z < maxs.z
        and hook.Call("wp-trace", GAMEMODE, portal.Entity)~=false then
            local dir = wp.TransformPortalAngle( trace.Normal:Angle(), portal.Entity, portal.Entity:GetExit() ):Forward()
            local startPos = wp.TransformPortalPos( portal.HitPos, portal.Entity, portal.Entity:GetExit() )

            local dataStart, dataEnd = data.start, data.endpos
            if not dataStart or not dataEnd then return trace end
            local length = dataStart:Distance(dataEnd)
            local usedLength = portal.Distance

            local endPos = dir
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
            -- Report the StartPos the caller asked for, not the exit-side start
            -- (else e.g. the camera tool spawns inside the portal). HitPos/Normal
            -- stay exit-side, so see-through traces are unchanged.
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