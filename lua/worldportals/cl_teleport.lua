
-- Predict-lerp window: while armed (sh_teleport.lua sets wp.predictedPos /
-- wp.predictedAt / wp.predictedOldPos on a successful local prediction), the
-- engine's snapshot interp can pull ply:GetPos() through wild intermediate
-- values for a few frames after a teleport (observed: snap to newPos →
-- drift back partway → drift forward again → settle). The user sees this
-- as 1-2 frames of "wrong place" rendering — sky, blank, or weird angle.
--
-- The shift uses `delta = NetworkOrigin - GetPos`. NetworkOrigin tracks the
-- *server's authoritative position* of the player, which on listen-server
-- (and in steady state on real clients) is at the post-teleport pos plus
-- accumulated movement — exactly where we want the camera. While the engine
-- drifts GetPos around, NetOrigin stays put at the right spot, so adding
-- (NetOrigin - GetPos) to the view origin parks the camera at NetOrigin.
--
-- Sanity guard: if NetOrigin is *closer to oldPos than to predictedPos*,
-- the post-teleport snapshot hasn't arrived yet and applying the shift
-- would yank the camera *backward* to oldPos. In that case we skip the
-- shift and let the camera render from GetPos (which, having just been
-- snapped by ply:SetPos, is at newPos — correct without our help).
--
-- Disarm: pure timeout. Convergence-detection was tried and failed —
-- engine drift is non-monotonic, so |delta|<threshold fires too early
-- and the shift vanishes before the next drift wave. The shift is
-- naturally a no-op once GetPos catches up to NetOrigin (delta → 0),
-- so a generous timeout is harmless.
--
-- We use SysTime() rather than CurTime() for the timestamp because CurTime()
-- inside SetupMove is the predicted-tick time (advanced into the future);
-- comparing against a real-time CurTime() in CalcView yields negative ages.
local PREDICT_TIMEOUT = 0.5

-- Stats so we can verify the arm/disarm branch fires at all from the HUD.
wp.predictArmCount = wp.predictArmCount or 0
wp.predictDisarmReasons = wp.predictDisarmReasons or {timeout=0, sanityFail=0}

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
    -- Sanity: NetOrigin should be near predictedPos. If it's still at the
    -- pre-teleport pos (snapshot hasn't caught up), don't shift — would
    -- pull camera backward.
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

-- View roll fade after a portal that introduced roll. wp.rotating is set
-- locally from the predicted teleport in sh_teleport.lua (no net round-trip).
hook.Add("CalcView", "WorldPortals_View", function(ply, pos, ang, fov)
    local delta = getPredictDelta(ply)
    local newOrigin = delta and (pos + delta) or nil
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

-- Same delta for the viewmodel so the physgun/hands ride with the camera —
-- without this the previous CalcView-only attempt detached them from the
-- camera ("out of body" physgun) because viewmodel pos is computed from
-- ply:EyePos() which still tracks the lerping AbsOrigin.
hook.Add("CalcViewModelView", "WorldPortals_ViewModel", function(weapon, vm, oldPos, oldAng, pos, ang)
    local delta = getPredictDelta(LocalPlayer())
    if not delta then return end
    return pos + delta, ang
end)

-- Predicted teleport debug HUD. Toggle with `worldportals_debug_predict 1`.
-- Buffers the last few SetupMove-driven teleports + per-frame ply state so a
-- paused frame still shows what the prediction did at that frame.
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

-- Track LocalPlayer.doori changes so the HUD can show whether the predicted
-- entry-state (ply.doori set) actually flipped on the same frame as the
-- predicted teleport, or lagged behind the server snapshot.
local doriHistory = {}
local lastDori
hook.Add("Think", "WorldPortals_DebugDoriTrack", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local cur = ply.doori
    if cur ~= lastDori then
        table.insert(doriHistory, 1, {
            time = CurTime(),
            frame = FrameNumber(),
            from = lastDori,
            to = cur,
        })
        while #doriHistory > 5 do table.remove(doriHistory) end
        lastDori = cur
    end
end)

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
    for _, portal in ipairs(ents.FindByClass("linked_portal_door")) do
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

    y = y + lh / 2
    line(string.format("ply.doori: %s", IsValid(ply.doori) and tostring(ply.doori) or "nil"), Color(140, 220, 255))
    if IsValid(ply.doori) then
        ---@type Entity
        local d = ply.doori
        ---@diagnostic disable: undefined-field
        line(string.format("  _init=%s  mesh=%s  material=%s",
            tostring(d._init),
            d.mesh and "set" or "nil",
            tostring(d.material)), Color(140, 220, 255))
        ---@diagnostic enable: undefined-field
        local origin = d:GetPos()
        local rmins, rmaxs = d:GetRenderBounds()
        line(string.format("  pos: %.1f,%.1f,%.1f", origin.x, origin.y, origin.z), Color(140, 220, 255))
        line(string.format("  renderbounds: %.0f,%.0f,%.0f -> %.0f,%.0f,%.0f", rmins.x, rmins.y, rmins.z, rmaxs.x, rmaxs.y, rmaxs.z), Color(140, 220, 255))
        local eyeInBounds = (eye.x >= origin.x + rmins.x and eye.x <= origin.x + rmaxs.x
            and eye.y >= origin.y + rmins.y and eye.y <= origin.y + rmaxs.y
            and eye.z >= origin.z + rmins.z and eye.z <= origin.z + rmaxs.z)
        line(string.format("  eye-in-renderbounds: %s  NoDraw=%s  IsDormant=%s",
            tostring(eyeInBounds), tostring(d:GetNoDraw()), tostring(d:IsDormant())), Color(140, 220, 255))
        -- Local-space eye position vs bounds, so we can see the overshoot
        -- direction/magnitude when the eye is outside.
        local localEye = d:WorldToLocal(eye)
        line(string.format("  eye-local: %.1f,%.1f,%.1f", localEye.x, localEye.y, localEye.z), Color(140, 220, 255))
        local function delta(v, lo, hi)
            if v < lo then return v - lo end
            if v > hi then return v - hi end
            return 0
        end
        line(string.format("  bounds-overshoot: x=%+.1f y=%+.1f z=%+.1f", delta(localEye.x, rmins.x, rmaxs.x), delta(localEye.y, rmins.y, rmaxs.y), delta(localEye.z, rmins.z, rmaxs.z)), Color(140, 220, 255))
    end
    if doriHistory[1] then
        line("doori history (newest first):", Color(140, 220, 255))
        for i, e in ipairs(doriHistory) do
            line(string.format("  [%d] %.3fs ago  frame=%d  %s -> %s", i, CurTime() - e.time, e.frame,
                IsValid(e.from) and tostring(e.from) or "nil",
                IsValid(e.to)   and tostring(e.to)   or "nil"))
        end
    end
end)
