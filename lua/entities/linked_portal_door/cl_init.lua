
include( "shared.lua" )

AccessorFunc( ENT, "texture", "Texture" )

function ENT:DrawPortal(exitPortal)
    if not (self:GetModel() == "models/error.mdl") then
        render.ModelMaterialOverride( wp.matInvis )
        render.Model({model = self:GetModel(), pos = self:LocalToWorld(self:GetModelPos()), angle = self:LocalToWorldAngles(self:GetModelAng())})
        render.ModelMaterialOverride( nil )
    elseif self:GetThickness() == 0 or hook.Call("wp-allowthickportal", GAMEMODE, self, exitPortal)==false then
        -- Draw the face at the front of the render geometry (recessed for an inverted
        -- portal), matching the cull poly and the box/inverted stencils.
        local fo = (self.RenderMin and self.RenderMax) and math.max(self.RenderMin.x, self.RenderMax.x) or 0
        render.DrawQuadEasy( self:GetPos() + self:GetForward() * fo, self:GetForward(), self:GetWidth(), self:GetHeight(), color_black, self:GetAngles().roll )
    elseif self:GetInverted() then
        for _,quad in ipairs(self.RenderQuads) do
            render.DrawQuad(self:LocalToWorld(quad[1]), self:LocalToWorld(quad[2]), self:LocalToWorld(quad[3]), self:LocalToWorld(quad[4]), color_black)
        end
    else
        render.DrawBox(self:GetPos(), self:GetAngles(), self.RenderMin, self.RenderMax, color_black)
    end
end

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

    local texture, _, _, depth = wp.GetPortalDrawTexture(self)
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

            -- Composite the exit-view RT into the stencilled opening. render.DrawScreenQuad
            -- (the 3D context, not cam.Start2D - the 2D context skews the fill off-centre so
            -- the interior slides as you look across the portal obliquely) fills the active
            -- eye sub-viewport exactly. Its UV spans the whole render target though, so a
            -- stereoscopy/VR eye would read only its half - remap the eye's UV slice back to
            -- [0..1] (identity in mono). SetBlend carries portal transparency; the RT's own
            -- alpha is flattened to 255 upstream.
            local vx, vy = wp.viewportX or 0, wp.viewportY or 0
            local vw, vh = wp.viewportW or ScrW(), wp.viewportH or ScrH()
            local rtw, rth = wp.viewportRTW or vw, wp.viewportRTH or vh
            local m = wp.blitMatrix
            m:Identity()
            m:SetField( 1, 1, rtw / vw )
            m:SetField( 2, 2, rth / vh )
            m:SetField( 1, 4, -vx / vw )
            m:SetField( 2, 4, -vy / vh )
            wp.matViewUV:SetMatrix( "$basetexturetransform", m )
            wp.matViewUV:SetTexture( "$basetexture", texture )
            render.SetMaterial( wp.matViewUV )
            render.SetColorModulation( 1, 1, 1 )
            render.SetBlend( transparency > 0 and ( transparency / 255 ) or 1 )
            -- DrawScreenQuad paints the whole framebuffer, gated only by the stencil. In
            -- stereoscopy/VR both eyes share one buffer and the stencil isn't cleared between
            -- them, so without this the second eye's blit bleeds parallax-shifted content into
            -- the first eye's still-stencilled opening. Confine it to this eye's rect (the full
            -- screen in mono, so a no-op there).
            render.SetScissorRect( vx, vy, vx + vw, vy + vh, true )
            render.DrawScreenQuad()
            render.SetScissorRect( 0, 0, 0, 0, false )
            render.SetBlend( 1 )

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
            -- SP runs no client prediction, so the prediction branch never armed
            -- our roll/stair window or fired the client-realm wp-teleport (which
            -- re-points our own ghost pair). Drive both from the broadcast here.
            -- Gate on SinglePlayer: on a listen server the prediction branch
            -- already did this ~RTT ago.
            if game.SinglePlayer() then
                if wp.ArmTeleportView then wp.ArmTeleportView(new_angle) end
                hook.Call("wp-teleport", GAMEMODE, portal, ent, new_pos, new_angle)
            end
            return
        end
        ent:SetPos( new_pos )
        if not ent:IsPlayer() then
            ent:SetAngles( new_angle )
        end
        hook.Call("wp-teleport", GAMEMODE, portal, ent, new_pos, new_angle)
    end
end)
