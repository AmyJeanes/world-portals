-- Predict debug

-- Predicted-teleport debug HUD (worldportals_debug_predict). Buffers the last few
-- predicted teleports + the last self-broadcast pos and dumps per-frame ply state,
-- so a paused frame shows what the prediction did. Records run at teleport rate
-- (RecordTeleportEvent from sh_teleport.lua, RecordNetTeleport from the entity net
-- receive); the render is gated on the cvar. Reads the predict-lerp state set in
-- cl_viewcorrections.lua / sh_teleport.lua.
CreateClientConVar("worldportals_debug_predict", "0", true, false, "Show predicted player teleport debug HUD", 0, 1)

local recentTeleports = {}
local MAX_HISTORY = 5
local lastNetTeleport = nil

function wp.RecordTeleportEvent(portal, oldPos, newPos, oldAng, newAng, oldVel, newVel)
    table.insert(recentTeleports, 1, {
        time = CurTime(),
        frame = FrameNumber(),
        portal = IsValid(portal) and portal:EntIndex() or -1,
        oldPos = Vector(oldPos.x, oldPos.y, oldPos.z),
        newPos = Vector(newPos.x, newPos.y, newPos.z),
        oldAng = Angle(oldAng.p, oldAng.y, oldAng.r),
        newAng = Angle(newAng.p, newAng.y, newAng.r),
        oldVel = Vector(oldVel.x, oldVel.y, oldVel.z),
        newVel = Vector(newVel.x, newVel.y, newVel.z),
    })
    while #recentTeleports > MAX_HISTORY do
        table.remove(recentTeleports)
    end
end

function wp.RecordNetTeleport(pos)
    lastNetTeleport = { time = CurTime(), pos = Vector(pos.x, pos.y, pos.z) }
end

hook.Add("HUDPaint", "WorldPortals_DebugPredictHUD", function()
    if not GetConVar("worldportals_debug_predict"):GetBool() then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local x, y = 20, 100
    local lh = 16
    local function line(text, col)
        draw.SimpleText(text, "DermaDefault", x, y, col or color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        y = y + lh
    end

    line(string.format("Frame: %d  CurTime: %.3f", FrameNumber(), CurTime()))
    local pos = ply:GetPos()
    local eye = ply:EyePos()
    local ang = ply:EyeAngles()
    local vel = ply:GetVelocity()
    local netPos = ply:GetNetworkOrigin()
    line(string.format("Pos:       %8.2f, %8.2f, %8.2f", pos.x, pos.y, pos.z))
    line(string.format("NetOrigin: %8.2f, %8.2f, %8.2f  (Pos-Net=%6.1f)", netPos.x, netPos.y, netPos.z, (pos - netPos):Length()))
    line(string.format("EyePos:    %8.2f, %8.2f, %8.2f", eye.x, eye.y, eye.z))
    line(string.format("EyeAng:    p=%6.1f y=%6.1f r=%6.1f", ang.p, ang.y, ang.r))
    line(string.format("Vel:       %7.1f, %7.1f, %7.1f  (len=%6.1f)", vel.x, vel.y, vel.z, vel:Length()))

    line(string.format("Predict stats: arms=%d disarms{timeout=%d}",
        wp.predictArmCount or 0,
        (wp.predictDisarmReasons or {}).timeout or 0),
        Color(180, 180, 255))

    if wp.predictedPos then
        local age = SysTime() - (wp.predictedAt or 0)
        local dNet = netPos - pos
        local dPred = wp.predictedPos - pos
        local sanityState = wp.predictSanityFailed and "SANITY-FAIL (NetOrigin stale)" or "OK"
        line(string.format("Predict-lerp: ARMED  tgt=%.1f,%.1f,%.1f  age=%.4fs",
            wp.predictedPos.x, wp.predictedPos.y, wp.predictedPos.z, age),
            Color(120, 255, 180))
        line(string.format("  shift = NetOrigin - Pos = %.1f,%.1f,%.1f  (|=%.1f)",
            dNet.x, dNet.y, dNet.z, dNet:Length()),
            Color(120, 255, 180))
        line(string.format("  predictedPos - Pos = %.1f,%.1f,%.1f  (|=%.1f)  sanity=%s",
            dPred.x, dPred.y, dPred.z, dPred:Length(), sanityState),
            Color(120, 255, 180))
    else
        line("Predict-lerp: NOT ARMED (wp.predictedPos = nil)", Color(200, 140, 140))
    end

    -- Nearest portal being approached.
    local nearestPortal, nearestDist
    for _, portal in ipairs(wp.portals) do
        if IsValid(portal) and portal.GetOpen and portal:GetOpen() and portal:GetEnableTeleport() then
            local fwd = portal:GetForward()
            if vel:Dot(fwd) < 0 then
                local d = (eye.x - portal:GetPos().x) * fwd.x + (eye.y - portal:GetPos().y) * fwd.y + (eye.z - portal:GetPos().z) * fwd.z
                if not nearestDist or math.abs(d) < math.abs(nearestDist) then
                    nearestPortal = portal
                    nearestDist = d
                end
            end
        end
    end
    if nearestPortal then
        local fwd = nearestPortal:GetForward()
        local nextEye = eye + vel * FrameTime()
        local pp = nearestPortal:GetPos()
        local distNext = (nextEye.x - pp.x) * fwd.x + (nextEye.y - pp.y) * fwd.y + (nextEye.z - pp.z) * fwd.z
        line(string.format("Approaching portal #%d:", nearestPortal:EntIndex()))
        line(string.format("  distNow:  %7.2f   distNext: %7.2f   ft=%.4f", nearestDist, distNext, FrameTime()))
        line(string.format("  fwd:      %.2f, %.2f, %.2f", fwd.x, fwd.y, fwd.z))
    end

    if recentTeleports[1] then
        y = y + lh / 2
        line("---- Predicted teleports (newest first) ----", Color(255, 220, 120))
        for i, e in ipairs(recentTeleports) do
            local ago = CurTime() - e.time
            line(string.format("[%d] portal=%d  %.3fs ago  frame=%d", i, e.portal, ago, e.frame))
            line(string.format("    pos:  %.1f,%.1f,%.1f -> %.1f,%.1f,%.1f", e.oldPos.x, e.oldPos.y, e.oldPos.z, e.newPos.x, e.newPos.y, e.newPos.z))
            line(string.format("    ang:  p%.1f y%.1f r%.1f -> p%.1f y%.1f r%.1f", e.oldAng.p, e.oldAng.y, e.oldAng.r, e.newAng.p, e.newAng.y, e.newAng.r))
            line(string.format("    vel:  len %.1f -> %.1f", e.oldVel:Length(), e.newVel:Length()))
        end
    end

    if lastNetTeleport then
        y = y + lh / 2
        line(string.format("Last net broadcast for self: %.3fs ago at pos %.1f,%.1f,%.1f", CurTime() - lastNetTeleport.time, lastNetTeleport.pos.x, lastNetTeleport.pos.y, lastNetTeleport.pos.z), Color(255, 120, 120))
    end
end)
