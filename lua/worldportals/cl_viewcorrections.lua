-- View corrections

-- Predict-lerp window: after a local teleport the engine's snapshot interp
-- pulls ply:GetPos() through wild values for a few frames (blank/sky frames).
-- While armed, CalcView shifts the camera by (NetworkOrigin - GetPos) to park
-- it at the server's authoritative pos until GetPos catches up. Disarm is a pure
-- timeout, not convergence detection (which fires early on the non-monotonic drift).
-- SysTime, not CurTime (CurTime in SetupMove is the future tick time).
local PREDICT_TIMEOUT = 0.5

-- Window for stripping the engine's post-teleport stair smoothing.
local STAIR_STRIP_TIMEOUT = 0.5

-- Predict-lerp diagnostic counters, read by the debug HUD (cl_predictdebug.lua).
wp.predictArmCount = wp.predictArmCount or 0
wp.predictDisarmReasons = wp.predictDisarmReasons or {timeout=0}

-- Arm the roll fade (wp.rotating) + stair-strip window (wp.stairStripAt) for a
-- local teleport, from the listen-server predict path and the SP net handler.
-- NOT the predict-lerp shift - that's prediction/ping-only.
function wp.ArmTeleportView(newAng)
    if newAng.r ~= 0 then
        wp.rotating = newAng.r
    end
    wp.stairStripAt = SysTime()
end

local function getPredictDelta(ply)
    if not wp.predictedPos then return end
    if SysTime() - (wp.predictedAt or 0) > PREDICT_TIMEOUT then
        wp.predictedPos = nil
        wp.predictedAt = nil
        wp.predictedOldPos = nil
        wp.predictDisarmReasons.timeout = wp.predictDisarmReasons.timeout + 1
        return
    end
    local netPos = ply:GetNetworkOrigin()
    -- Sanity: if NetOrigin is still nearer oldPos than predictedPos the snapshot
    -- hasn't caught up - shifting would pull the camera backward, so skip.
    if wp.predictedOldPos then
        local distToNew = (netPos - wp.predictedPos):LengthSqr()
        local distToOld = (netPos - wp.predictedOldPos):LengthSqr()
        if distToOld < distToNew then
            wp.predictSanityFailed = true
            return  -- skip shift this frame, NetOrigin stale
        end
    end
    wp.predictSanityFailed = nil
    return netPos - ply:GetPos()
end

-- Combines three post-teleport view corrections: the predict-lerp shift, the
-- stair-strip, and the roll fade. wp.rotating (the roll) is set locally from the
-- predicted teleport in sh_teleport.lua, no net round-trip.
hook.Add("CalcView", "WorldPortals_View", function(ply, pos, ang, fov)
    -- These corrections derive from the player's own eye/body, so only apply to
    -- the player's first-person view. Bail when rendering from another entity
    -- (camera/monitor/spectate).
    if GetViewEntity() ~= ply then
        wp.stairLeak = nil
        return
    end
    local delta = getPredictDelta(ply)
    local newOrigin = delta and (pos + delta) or nil
    -- The engine eases the eye's Z when you step up stairs or off a ledge
    -- (SmoothViewOnStairs) so the camera doesn't jolt - but a grounded portal
    -- exit's big Z change trips it as one huge step on landing, so we strip it,
    -- same idea as the predict-lerp shift above. (pos.z - EyePos().z) is exactly
    -- the leaked offset (EyePos isn't stair-smoothed), so it self-measures;
    -- stashed in wp.stairLeak for CalcViewModelView. Its own window gates it (both
    -- realms, unlike the predict shift) so normal stairs keep their smoothing.
    if wp.stairStripAt and SysTime() - wp.stairStripAt < STAIR_STRIP_TIMEOUT then
        local base = newOrigin or pos
        wp.stairLeak = pos.z - ply:EyePos().z
        newOrigin = Vector(base.x, base.y, base.z - wp.stairLeak)
    else
        wp.stairLeak = nil
    end
    local newAngles
    if wp.rotating then
        if wp.rotating ~= 0 then
            wp.rotating = math.Approach(wp.rotating, 0, FrameTime() * ((0.5 + math.abs(wp.rotating)) * 3.5))
            newAngles = Angle(ang.p, ang.y, wp.rotating)
        else
            wp.rotating = nil
        end
    end
    if newOrigin or newAngles then
        return {
            origin = newOrigin or pos,
            angles = newAngles or ang,
            fov = fov,
        }
    end
end)

-- Same delta for the viewmodel so the physgun/hands ride with the camera.
hook.Add("CalcViewModelView", "WorldPortals_ViewModel", function(weapon, vm, oldPos, oldAng, pos, ang)
    local ply = LocalPlayer()
    -- Same own-view restriction as CalcView.
    if GetViewEntity() ~= ply then return end
    local delta = getPredictDelta(ply)
    -- Check both: a delta-only bail drops the stair strip in SP (nil delta there).
    if not delta and not wp.stairLeak then return end
    local origin = delta and (pos + delta) or pos
    if wp.stairLeak then
        origin = Vector(origin.x, origin.y, origin.z - wp.stairLeak)
    end
    return origin, ang
end)
