-- Render follow

-- Bypass entity interpolation for a prop in a rapid teleport loop. GMod renders
-- entities cl_interp in the past and resets the interp history on every teleport,
-- so a prop looping faster than ~0.1s freezes into an ~8 Hz stutter. While
-- looping we render it at its live GetNetworkOrigin/Angles instead: snap on enter
-- (it's a real teleport), ease back to interpolation on exit. Only RAPID loops
-- engage (a lone teleport interpolates fine). Accepted limit: a prop leaving the
-- loop still moving gets a brief freeze.
wp.renderFollow = wp.renderFollow or {}
local RAPID_WINDOW       = 0.2   -- two teleports within this => a loop interp can't track
local RENDER_FOLLOW_TIME = 0.3   -- keep following for this long after the last teleport
local RENDER_BLEND_TIME  = 0.15  -- ease back to interpolation over this long on exit

-- Record each entity teleport and engage the follow on a rapid pair. Reacts to
-- wp-teleport (fired client-side from the portal's WorldPortals_Teleport net
-- receive); players are excluded - SetRenderOrigin no-ops the local player and
-- remote players don't loop.
hook.Add("wp-teleport", "WorldPortals_RenderFollow", function(_, ent)
    if not IsValid(ent) or ent:IsPlayer() then return end
    local now = SysTime()
    local rec = wp.renderFollow[ent]
    if rec then
        if now - rec.lastTP < RAPID_WINDOW then
            rec.expiry = now + RENDER_FOLLOW_TIME
            rec.blendStart = nil
        end
        rec.lastTP = now
    else
        wp.renderFollow[ent] = { lastTP = now }
    end
end)

hook.Add("Think", "WorldPortals_RenderFollow", function()
    if not next(wp.renderFollow) then return end
    local now = SysTime()
    for ent, rec in pairs(wp.renderFollow) do
        if not IsValid(ent) then
            wp.renderFollow[ent] = nil
        elseif not rec.expiry then
            -- One teleport seen but no rapid pair yet: drop the record once it
            -- can no longer pair within RAPID_WINDOW (it was an isolated tp).
            if now - rec.lastTP > RAPID_WINDOW then wp.renderFollow[ent] = nil end
        elseif now <= rec.expiry then
            -- Looping: track the live networked transform (snaps on each
            -- teleport, no interp lag between them).
            rec.blendStart = nil
            ent:SetRenderOrigin( ent:GetNetworkOrigin() )
            ent:SetRenderAngles( ent:GetNetworkAngles() )
        else
            -- Stopped looping: ease from where we were (the networked transform,
            -- captured once) back to the engine's interpolated transform, then
            -- release rendering to normal interpolation.
            if not rec.blendStart then
                rec.blendStart   = now
                rec.blendFromPos = ent:GetNetworkOrigin()
                rec.blendFromAng = ent:GetNetworkAngles()
            end
            local frac = (now - rec.blendStart) / RENDER_BLEND_TIME
            if frac >= 1 then
                ent:SetRenderOrigin()
                ent:SetRenderAngles()
                wp.renderFollow[ent] = nil
            else
                ent:SetRenderOrigin( LerpVector( frac, rec.blendFromPos, ent:GetPos() ) )
                ent:SetRenderAngles( LerpAngle( frac, rec.blendFromAng, ent:GetAngles() ) )
            end
        end
    end
end)
