
-- Predicted player teleport. Runs in the prediction loop on both server (every
-- player) and client (LocalPlayer only), so the local player's position stays
-- in lockstep without waiting for the server snapshot. Non-player entities
-- still go through ENT:Touch — they can't be client-predicted.
local ANGLE_VR_YAW_REF = Angle(0, 0, 0)
-- How far in front of the portal plane the eye may already be and still fire
-- this tick (see the crossing test). Small enough to be imperceptible vs the
-- exact-plane timing, large enough to catch a slow creeper whose accelerated
-- tick would otherwise step over the plane between two SetupMove evaluations.
local CROSS_SKIN = 2
local function predictPlayerTeleport(ply, mv, cmd)
    if CLIENT and ply ~= LocalPlayer() then return end
    if not ply:Alive() then return end

    local velocity = mv:GetVelocity()
    if velocity:LengthSqr() < 1 then return end

    local origin = mv:GetOrigin()
    local frameTime = FrameTime()

    -- Two reference points feed the crossing/bounds tests below:
    --   * the EYE is the camera. It must still be IN FRONT of the portal plane
    --     when we teleport or the back-face cull (cl_render.lua, on
    --     portal:GetPos()) stops the stencil and the world shows through before
    --     the teleport lands. So the eye is the anti-cull / anti-bounce front
    --     guard (the distNow <= backLimit gate below), and one of the two points
    --     whose plane-crossing can fire the teleport.
    --   * the hull CENTRE drives the face bounds, and is the SECOND crossing
    --     point. We fire when EITHER the eye or the centre reaches the plane.
    --
    -- Why both, not the eye alone: the eye sits a fixed ~28u straight ABOVE the
    -- centre (purely vertical — measured), so along a portal's normal the two
    -- differ by 28 * forward.z, i.e. only the portal's PITCH matters, never yaw:
    --   * upright/vertical portal (forward.z ~= 0): eye and centre are at the
    --     same depth, so "either crosses" is bit-for-bit the old eye-only test —
    --     no change to the common wall portal at any yaw.
    --   * ceiling / downward-pitched (forward.z < 0): the eye LEADS (going up
    --     into the plane the highest point crosses first), so it still fires
    --     first and the centre term never triggers earlier — also unchanged.
    --   * floor / upward-pitched (forward.z > 0): the centre LEADS. The eye is
    --     the highest point, so against an up-facing portal it crosses LAST — and
    --     when you rest on whatever's under the opening (e.g. a TARDIS shell) your
    --     feet stop before the eye ever reaches the plane, so an eye-only test
    --     can't fire while standing and only fires deep/late on a fall. Firing on
    --     the centre catches the body crossing mid-fall, retaining entry velocity.
    --     This is the only case the change affects. (A dead-still rest is still
    --     skipped by the velocity gate above; that case needs a separate path.)
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
        -- Crossing test against the portal plane (= portal:GetPos(), the same
        -- plane cl_render.lua's wp.shouldrender culls the back face on — once
        -- the eye crosses it the stencil stops rendering and the world behind
        -- shows through, so the teleport must fire before then).
        local distNow  = (eyePos.x - pos.x) * fwd.x + (eyePos.y - pos.y) * fwd.y + (eyePos.z - pos.z) * fwd.z
        -- Re-teleport guard. The eye must be IN FRONT of the plane to fire,
        -- EXCEPT inside a thick portal's own depth. A teleport lands the player
        -- ON / just behind the EXIT face (the mirror transform puts the eye a
        -- unit or two past it), and the pair are each other's exits, so a plain
        -- "must be in front" rule (distNow <= 0) is what stops the exit
        -- immediately re-firing and bouncing the player back — a confirmed
        -- double-teleport.
        --
        -- But a thick (inverse-3D) portal renders its exit view through the
        -- whole volume between its face (pos) and its back-cull plane
        -- (pos - fwd*thickness): that volume is walkable and shows the exit,
        -- e.g. the exterior box shell you stand inside while seeing the
        -- interior. The mirror lands the emerging eye INSIDE that volume, so a
        -- flat distNow <= 0 guard traps the player there and lets them walk the
        -- full depth into the shell (the reported bug). Allow firing down to
        -- the back-cull plane instead: walking back into the volume then
        -- re-crosses and teleports cleanly. This still can't bounce on
        -- emergence — the player leaves the volume moving OUT
        -- (velocity:Dot(fwd) >= 0, already skipped above); only deliberate
        -- backward motion reaches here. Thin portals (thickness <= 0) keep the
        -- exact distNow <= 0 guard, so their behaviour is unchanged.
        --
        -- NOCLIP EXCEPTION: the "can't bounce on emergence" reasoning relies on
        -- the mirrored exit velocity carrying the player back OUT of the volume.
        -- The engine's FullNoClipMove rederives velocity from the held input +
        -- view every tick and discards mv:SetVelocity, so a noclipping player
        -- keeps their pre-teleport WORLD velocity instead. When entry and exit
        -- face the same world direction (e.g. a TARDIS interior/exterior pair
        -- both facing +X), that un-mirrored velocity points straight into the
        -- exit's front face: the eye emerges a few units inside the shell
        -- (measured ~7u into a 42u shell) still moving inward, so the backLimit
        -- window re-fires it — an infinite interior<->exterior bounce. The
        -- backLimit only ever guarded against a *walking* player getting trapped
        -- in the shell, which can't happen in noclip (no collision — they fly
        -- straight through the volume), so fall back to the flat distNow <= 0
        -- guard there. (Restores pre-thick-volume-allowance noclip behaviour.)
        local thickness = portal:GetThickness()
        local backLimit = (thickness > 0 and ply:GetMoveType() ~= MOVETYPE_NOCLIP) and -thickness or 0
        if distNow <= backLimit then goto cont end
        local distNext = (nextEyeX - pos.x) * fwd.x + (nextEyeY - pos.y) * fwd.y + (nextEyeZ - pos.z) * fwd.z
        -- The hull centre, swept the same way (this tick / next tick along the
        -- portal normal). It is the SECOND crossing point — see the reference-
        -- point note at the top of this function for why firing on either the
        -- eye or the centre is identical to the old eye-only test on upright and
        -- downward portals and only changes upward-facing ones.
        local centerNow  = (hullCenterX - pos.x) * fwd.x + (hullCenterY - pos.y) * fwd.y + (hullCenterZ - pos.z) * fwd.z
        local centerNext = (nextCenterX - pos.x) * fwd.x + (nextCenterY - pos.y) * fwd.y + (nextCenterZ - pos.z) * fwd.z
        -- A point "reaches" the plane when it crosses this tick (...Next <= 0) OR
        -- it is already within CROSS_SKIN of the plane while moving toward it
        -- (guaranteed by the velocity:Dot(fwd) < 0 gate above). The skin is the
        -- slow-walk safety net: a player who creeps to a near-stop just short of
        -- the plane and then accelerates moves further in the *next* (accelerated)
        -- tick than ...Next — computed here from this tick's slow velocity —
        -- predicts, so the crossing slab is stepped over and the distNow <= 0
        -- guard then blocks it for the rest of the walk-through. A near-stop
        -- creeper dwells several ticks within the skin and the first accelerated
        -- tick from rest moves well under a unit, so a small skin reliably catches
        -- it; fast movers hit ...Next <= 0 first, so their (correct, at-the-plane)
        -- timing is unchanged. Fire when EITHER point reaches; skip only if both
        -- are still short of it.
        local eyeReaches    = distNext   <= 0 or distNow   <= CROSS_SKIN
        local centerReaches = centerNext <= 0 or centerNow <= CROSS_SKIN
        if not (eyeReaches or centerReaches) then goto cont end

        -- Face bounds: the hull CENTRE must lie within the portal opening.
        -- Testing the centre (not the eye) is what fixes the jump-over — when
        -- you jump through a doorway the eye rises above the top edge but the
        -- body's mid-point still passes through the opening, so an eye-Z test
        -- spuriously fails while a centre-Z test passes. WorldToLocal folds in
        -- the portal's pitch/yaw/roll, so this holds at any orientation.
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
        -- mv:SetAngles is what gamemovement reads to decide which world
        -- direction W/S/A/D push toward; without it the engine still uses the
        -- pre-teleport view angles for input, which manifests as "walking
        -- backward through a portal mangles your motion direction" because
        -- backward input * old view ≠ backward input * new view.
        mv:SetAngles(clampedAng)
        cmd:SetViewAngles(clampedAng)
        -- ply:SetPos resets the AbsOrigin interp cache that mv:SetOrigin
        -- doesn't touch, and makes ply:GetPos() report the post-teleport
        -- position before the wp-teleport hook fires below. A consumer unstick
        -- (Doors) reads ply:GetPos() to decide where to relocate the player, so
        -- this has to hold on EVERY prediction pass, resim included. The
        -- teleport mv:SetOrigin above re-runs each resim; if ply:SetPos (and the
        -- unstick that depends on it) only ran first-time-predicted, every resim
        -- would leave the predicted origin at the raw transform. At high ping
        -- the crossing command stays unacked — and therefore resimulated — for
        -- ~RTT, so that raw pos (often embedded in the exit geometry) is what the
        -- player sits at until the server snapshot finally corrects them: the
        -- "stuck after teleport, un-stuck once the lag catches up" bug. Re-snaps
        -- to the same deterministic value every resim, which is harmless.
        ply:SetPos(newPos)
        -- ply:SetEyeAngles — client-only, first-time-predicted only.
        --
        -- Why client: cmd:SetViewAngles alone leaves the persistent
        -- m_angEyeAngles on its last-input value, so directional portals
        -- visibly no-op locally without this — SetEyeAngles is what actually
        -- rotates the camera. The rotated angle then rides out in the player's
        -- subsequent cmds (mouse is sampled relative to it), so the server
        -- picks it up via cmd:GetViewAngles and converges to it on its own —
        -- no explicit server write needed.
        --
        -- Why first-time only: SetEyeAngles writes a persistent field that
        -- survives resim, so calling it during resim clobbers mouse delta the
        -- user has accumulated since (camera "snaps back" mid-look).
        --
        -- Why NOT on the server (in multiplayer): a server write makes
        -- m_angEyeAngles authoritative, and the snapshot pushes it back to the
        -- owning client ~RTT later, overriding any mouse the user moved during
        -- that window — a confirmed, reproducible snap-back of in-flight look
        -- input. We tried a server-side write to kill a suspected angle-
        -- rollback; the rollback did not reproduce in clean testing (the client
        -- rotation propagates via cmds as above), and the write's snap-back was
        -- strictly worse. See memory/reference_predict_angle_contamination.md.
        --
        -- SINGLEPLAYER EXCEPTION: in singleplayer the engine runs no client-
        -- side prediction — SetupMove/Move/FinishMove fire on the SERVER realm
        -- only, so this whole function never executes on the client and the
        -- CLIENT-gated SetEyeAngles never lands, leaving the view un-rotated on
        -- entry (the position teleport still works because that's server-side).
        -- The snap-back reason above doesn't apply in SP: there's no
        -- prediction, no RTT, no snapshot-override window — server and client
        -- are synchronous, so the server write IS the correct (and only) way to
        -- rotate the view. game.SinglePlayer() is false on a listen server, so
        -- the multiplayer path is untouched.
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
            -- A wp-teleport consumer (e.g. Doors' unstick) may have repositioned
            -- the player via ply:SetPos. That ran inside SetupMove, so without
            -- folding it back into mv the move's FinishMove overwrites the entity
            -- origin with the pre-adjust mv value and the relocation is lost.
            -- Re-read and re-commit so it survives; the reassigned newPos then
            -- rides out in the broadcast below so remote snaps match the landing.
            local finalPos = ply:GetPos()
            if finalPos ~= newPos then
                mv:SetOrigin(finalPos)
                newPos = finalPos
            end
            -- Remote clients still need an immediate position update; the
            -- player who crossed predicts it themselves and skips the apply.
            net.Start("WorldPortals_Teleport")
                net.WriteEntity(portal)
                net.WriteEntity(ply)
                net.WriteVector(newPos)
                net.WriteAngle(newAng)
            net.Broadcast()
        else
            -- CLIENT (LocalPlayer). The wp-teleport hook and the mv re-sync
            -- below run on EVERY prediction pass — first-time AND resim. A
            -- consumer unstick (Doors) repositions the player via ply:SetPos
            -- from inside the hook; that relocation has to be reproduced on each
            -- resim or FinishMove reverts the predicted origin to the raw
            -- transform. Because the crossing command is resimulated for the
            -- whole ~RTT it stays unacked at high ping, skipping resim here is
            -- exactly what left the player stuck at the raw pos until the server
            -- snapshot corrected them. The unstick is a pure, deterministic
            -- position resolver (matching the server's), so re-running it every
            -- pass yields the identical landing — which is what prediction
            -- requires. (Consumers' wp-teleport handlers must therefore be
            -- idempotent and resim-safe, like all prediction-path code.)
            hook.Call("wp-teleport", GAMEMODE, portal, ply, newPos, newAng)
            -- Fold any consumer relocation (ply:SetPos in the hook) back into mv
            -- so the move keeps the adjusted origin; FinishMove would otherwise
            -- revert it. The reassigned newPos rides out to the predict-window
            -- arming below so it matches the server's broadcast pos.
            local finalPos = ply:GetPos()
            if finalPos ~= newPos then
                mv:SetOrigin(finalPos)
                newPos = finalPos
            end
            -- One-time client side effects: first-time-predicted ONLY. These arm
            -- persistent client-frame state that must NOT re-fire on resim (every
            -- resim runs within the same frame, so re-arming would reset the roll
            -- fade / predict-lerp window / debug record every frame for the whole
            -- unacked window). They read the post-unstick newPos set just above:
            -- cl_teleport.lua's getPredictDelta sanity guard compares
            -- NetworkOrigin against predictedPos and the server broadcasts this
            -- same final pos, so predictedPos must equal it.
            if IsFirstTimePredicted() then
                -- Roll fade-in + stair-smoothing strip window. Shared with the
                -- singleplayer path (cl_init.lua's WorldPortals_Teleport net
                -- handler) via this helper so both realms arm identical client-
                -- frame corrections. The predict-lerp window below is armed
                -- separately because it's prediction/ping-only (unneeded in SP).
                if wp.ArmTeleportView then wp.ArmTeleportView(newAng) end
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
                if wp.RecordTeleportEvent then
                    wp.RecordTeleportEvent(portal, origin, newPos, oldEyeAng, clampedAng, oldVel, newVel)
                end
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
            -- Keep StartPos as the ORIGINAL requested start, not the exit-side
            -- re-trace start. Every non-portal trace reports StartPos == the
            -- start you asked for, and consumers rely on it: the sandbox camera
            -- tool places the camera at trace.StartPos expecting the player's
            -- eye, so a redirected StartPos spawned the camera inside the portal.
            -- HitPos/Entity/Normal stay the exit-side results, so see-through
            -- traces (line-of-sight, +use, tool HitPos placement) are unchanged
            -- -- only StartPos is restored. (StartPos and HitPos then sit on
            -- opposite sides of the portal, so anything deriving a ray from
            -- HitPos - StartPos sees a portal-crossing vector; the bullet path
            -- doesn't use this -- it rewrites Src/Dir in EntityFireBullets.)
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