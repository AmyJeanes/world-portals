
include( "shared.lua" )

AccessorFunc( ENT, "texture", "Texture" )

function ENT:DrawPortal(exitPortal)
    if not (self:GetModel() == "models/error.mdl") then
        render.ModelMaterialOverride( wp.matInvis )
        render.Model({model = self:GetModel(), pos = self:LocalToWorld(self:GetModelPos()), angle = self:LocalToWorldAngles(self:GetModelAng())})
        render.ModelMaterialOverride( nil )
    elseif self:GetThickness() == 0 or hook.Call("wp-allowthickportal", GAMEMODE, self, exitPortal)==false then
        render.DrawQuadEasy( self:GetPos() -( self:GetForward() * 5 ), self:GetForward(), self:GetWidth(), self:GetHeight(), color_black, self:GetAngles().roll )
    elseif self:GetInverted() then
        for _,quad in ipairs(self.RenderQuads) do
            render.DrawQuad(self:LocalToWorld(quad[1]), self:LocalToWorld(quad[2]), self:LocalToWorld(quad[3]), self:LocalToWorld(quad[4]), color_black)
        end
    else
        render.DrawBox(self:GetPos(), self:GetAngles(), self.RenderMin, self.RenderMax, color_black)
    end
end

-- Draw world portals
function ENT:Draw()
    if not (wp.IsEnabled and wp.IsEnabled()) then return end
    if not self:GetOpen() then return end
    if wp.drawing and not wp.drawportalsinview then return end

    local shouldrender,drawblack=wp.shouldrender(self, wp.vieworigin, wp.viewangle, wp.viewfov)
    if not (shouldrender or drawblack) then return end

    local exitPortal = self:GetExit()
    local falseWorld = self:GetFalseWorld()
    if not IsValid(exitPortal) and not (falseWorld and falseWorld ~= "") then return end

    -- Skip if our chain was culled this frame; the RT holds stale contents.
    if shouldrender and not wp.IsPortalChainRendered(self) then return end

    hook.Call("wp-predraw", GAMEMODE, self, exitPortal)

    local texture, width, height, depth = wp.GetPortalDrawTexture(self)
    if depth == 1 then
        self:SetTexture( texture )
    end

    if wp.rendermode then
        if shouldrender then
            wp.matView2:SetTexture( "$basetexture", texture )
            render.SetMaterial( wp.matView2 )
        else
            render.SetMaterial( wp.matBlack )
        end
        self:DrawPortal(exitPortal)
    else
        if shouldrender then
            render.ClearStencil()
            render.SetStencilEnable( true )

            render.SetStencilWriteMask( 1 )
            render.SetStencilTestMask( 1 )
            render.SetStencilReferenceValue( 1 )

            render.SetStencilFailOperation( STENCIL_KEEP )
            render.SetStencilZFailOperation( STENCIL_KEEP )
            render.SetStencilPassOperation( STENCIL_REPLACE )
            render.SetStencilCompareFunction( STENCIL_ALWAYS )
        end

        local transparency = self:GetTransparency()
        if transparency > 0 then
            render.SetMaterial( wp.matTrans )
        else
            render.SetMaterial( wp.matBlack )
        end
        render.SetColorModulation( 1, 1, 1 )

        self:DrawPortal(exitPortal)

        if shouldrender then
            render.SetStencilCompareFunction( STENCIL_EQUAL )

            wp.matView:SetTexture( "$basetexture", texture )

            if transparency > 0 then
                cam.Start2D()
                    surface.SetDrawColor(255,255,255,transparency)
                    surface.SetMaterial( wp.matView )
                    surface.DrawTexturedRect( 0, 0, width, height )
                cam.End2D()
            else
                render.SetMaterial( wp.matView )
                render.DrawScreenQuad()
            end

            render.SetStencilEnable( false )
        end
    end

    hook.Call("wp-postdraw", GAMEMODE, self, exitPortal)
end

net.Receive("WorldPortals_VRMod_SetAngle", function()
    local yawOffset = net.ReadDouble()
    if vrmod and vrmod.IsPlayerInVR() then
        local ang = vrmod.GetOriginAng()
        ang.y = ang.y + yawOffset
        vrmod.SetOriginAng(ang)
    end
end)

-- Bypass entity interpolation for props caught in a rapid teleport loop.
--
-- GMod renders networked entities cl_interp (default 0.1s) in the past and
-- resets the interpolation history on every teleport. A prop in a tight portal
-- loop -- e.g. an infinite fall between a floor and ceiling portal -- teleports
-- many times per second, faster than the ~0.1s interpolation can recover
-- between resets, so the rendered position freezes at each post-teleport point
-- and only jumps on the next wrap: an ~8 Hz stutter no matter the framerate.
-- While such a prop is looping we render it at its live GetNetworkOrigin/
-- GetNetworkAngles instead, which tracks the real motion at the snapshot rate.
--
-- Only RAPID loops engage this. A single or occasional teleport interpolates
-- fine on its own (and engaging the override there would just trade the stutter
-- for the boundary seam below), so we wait for a SECOND teleport within
-- RAPID_WINDOW before taking over; a lone teleport leaves a record the Think
-- hook prunes. SetRenderOrigin is a no-op on the local player and only
-- non-player entities are armed, so the predicted local-player path is left
-- alone.
--
-- Switching rendering source has a latency seam (override is ~now, normal
-- interpolation is ~now-cl_interp), handled differently at each boundary:
--   * ENTER: snap to the live transform. Engaging coincides with a real
--     teleport, and the interpolated position is then one teleport behind the
--     networked one -- easing between them would slide the prop bodily across
--     the portal gap. A snap reads as the teleport it is.
--   * EXIT: once teleports stop the interpolation is clean again, so ease
--     (lerp) from the networked transform back to the interpolated one over
--     RENDER_BLEND_TIME, then release. ACCEPTED LIMIT: a prop that leaves the
--     loop still MOVING (e.g. physgunned out) has ~cl_interp of motion handed
--     back to interpolation, which reads as a brief freeze; a prop that exits
--     by coming to rest has no give-back and no freeze. Eliminating it would
--     need the override to run at matched cl_interp latency (a teleport-aware
--     interpolation buffer) -- deliberately not done. See
--     memory/reference_prop_teleport_interp.md.
wp.renderFollow = wp.renderFollow or {}
local RAPID_WINDOW       = 0.2   -- two teleports within this => a loop interp can't track
local RENDER_FOLLOW_TIME = 0.3   -- keep following for this long after the last teleport
local RENDER_BLEND_TIME  = 0.15  -- ease back to interpolation over this long on exit

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

net.Receive("WorldPortals_Teleport", function()
    local portal = net.ReadEntity()
    local ent = net.ReadEntity()
    local new_pos = net.ReadVector()
    local new_angle = net.ReadAngle()
    if IsValid(portal) and IsValid(ent) then
        -- LocalPlayer predicts their own teleport in SetupMove and fires
        -- wp-teleport client-side from there; skip the snapshot apply so we
        -- don't double-fire the hook or yank the predicted position.
        if ent == LocalPlayer() then
            if wp.RecordNetTeleport then wp.RecordNetTeleport(new_pos) end
            return
        end
        ent:SetPos( new_pos )
        if not ent:IsPlayer() then
            ent:SetAngles( new_angle )
            -- Engage render-follow only for RAPID loops: record this teleport,
            -- and take over (or refresh the window) only when another teleport
            -- already landed within RAPID_WINDOW. A lone teleport just leaves a
            -- record the Think hook prunes. Refreshing cancels any exit blend.
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
        end
        hook.Call("wp-teleport", GAMEMODE, portal, ent, new_pos, new_angle)
    end
end)
