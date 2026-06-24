
include( "shared.lua" )

AccessorFunc( ENT, "texture", "Texture" )

-- True when the active render origin is submerged (eyes underwater). Tests the actual view origin
-- rather than the player's WaterLevel, so it's correct for a VR eye (the HMD can be underwater while
-- the player entity isn't) and for camera/monitor views above water.
local function eyeInWater()
    local vo = wp.vieworigin
    return vo and bit.band( util.PointContents( vo ), CONTENTS_WATER ) ~= 0 or false
end

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
    -- Bail unless this portal has something to show this frame.
    if not (wp.IsEnabled and wp.IsEnabled()) then return end
    if not self:GetOpen() then return end
    -- Inside another portal's RT pass that isn't drawing nested portals.
    if wp.drawing and not wp.drawportalsinview then return end

    -- shouldrender = show the through-view; drawblack = draw a solid black face instead.
    local shouldrender,drawblack=wp.shouldrender(self, wp.vieworigin, wp.viewangle, wp.viewfov)
    if not (shouldrender or drawblack) then return end

    -- Need a destination: a linked exit portal, or a false-world.
    local exitPortal = self:GetExit()
    local falseWorld = self:GetFalseWorld()
    if not IsValid(exitPortal) and not (falseWorld and falseWorld ~= "") then return end

    -- Our exit-view RT got culled this frame, so it holds stale pixels - skip.
    if shouldrender and not wp.IsPortalChainRendered(self) then return end

    hook.Call("wp-predraw", GAMEMODE, self, exitPortal)

    -- The RT holding our exit view. At depth 1, expose it as the entity's texture so
    -- consumers can read portal:GetTexture().
    local texture, depth = wp.GetPortalDrawTexture(self)
    if depth == 1 then
        self:SetTexture( texture )
    end

    if wp.rendermode then
        -- Being drawn inside another portal's view. Stencils don't nest cleanly, so skip
        -- the dance and put the exit-view texture flat on the face (black if it won't render).
        if shouldrender then
            wp.matView2:SetTexture( "$basetexture", texture )
            render.SetMaterial( wp.matView2 )
        else
            render.SetMaterial( wp.matBlack )
        end
        self:DrawPortal(exitPortal)
    else
        -- Top-level eye view: the stencil dance. Stamp the opening shape into the stencil,
        -- then paint the exit view into just that shape.
        if shouldrender then
            -- Stamp: make every pixel the face covers get stencil = 1.
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

        -- Draw the visible face - see-through if the portal has transparency, else solid
        -- black. This same pass writes the stamp above.
        local transparency = self:GetTransparency()
        if transparency > 0 then
            render.SetMaterial( wp.matTrans )
        else
            render.SetMaterial( wp.matBlack )
        end
        render.SetColorModulation( 1, 1, 1 )

        self:DrawPortal(exitPortal)

        if shouldrender then
            -- Now fill the stencilled opening (where stencil == 1) with the exit view.
            render.SetStencilCompareFunction( STENCIL_EQUAL )

            -- Source renders water in extra passes that clip geometry at the surface, which breaks
            -- the default screen-space fill below the water line. Branch on the bound render target
            -- so each pass (and the eyes-underwater main view) gets a fill that survives the clip.
            local rt = render.GetRenderTarget()
            local rtName = rt and rt:GetName() or ""

            if rtName == "_rt_waterreflection" then
                -- Reflection uses a mirrored camera, so the eye-rendered exit view can't be fitted
                -- here. Skip it; the stamped black face reflects like a door.
            else
                -- Below the water line Source clips geometry at the surface (the refraction pass, and
                -- the main view once the eyes submerge), which would discard the screen-space fill (a
                -- quad up at the camera, above water). Lift that clip so the one screen-space fill
                -- works there too, instead of a separate tessellated-geometry path.
                local isRefraction = rtName == "_rt_waterrefraction"
                local belowWater = isRefraction or eyeInWater()
                local prevClip
                if belowWater then prevClip = render.EnableClipping( false ) end

                local vx, vy = wp.viewportX or 0, wp.viewportY or 0
                local vw, vh = wp.viewportW or ScrW(), wp.viewportH or ScrH()
                local m = wp.uvRemapMatrix
                m:Identity()

                -- The water refraction pass draws into just this eye's viewport with viewport-local
                -- UVs and its own per-eye stencil, so an identity remap samples the whole exit view
                -- and no scissor is needed. The main buffer is the opposite: DrawScreenQuad spans the
                -- whole (both-eyes in stereo/VR) buffer with target-relative UVs, so rescale the lookup
                -- to this eye's slice and scissor so the other eye's matching stencil region isn't
                -- filled too. Both are a no-op in mono (one full-screen eye).
                local useScissor = not isRefraction
                if useScissor then
                    local rtw, rth = wp.viewportRTW or vw, wp.viewportRTH or vh
                    m:SetField( 1, 1, rtw / vw )   -- rescale horizontally (1.0 in mono)
                    m:SetField( 2, 2, rth / vh )   -- rescale vertically
                    m:SetField( 1, 4, -vx / vw )   -- shift onto this eye's left edge (0 in mono)
                    m:SetField( 2, 4, -vy / vh )   -- shift onto this eye's top edge
                end
                wp.matViewUV:SetMatrix( "$basetexturetransform", m )
                wp.matViewUV:SetTexture( "$basetexture", texture )
                render.SetMaterial( wp.matViewUV )
                render.SetColorModulation( 1, 1, 1 )
                -- Transparency goes through $alpha, not render.SetBlend: $vertexalpha makes
                -- DrawScreenQuad's own (opaque) vertex alpha override SetBlend, so it never took.
                wp.matViewUV:SetFloat( "$alpha", transparency > 0 and ( transparency / 255 ) or 1 )
                if useScissor then render.SetScissorRect( vx, vy, vx + vw, vy + vh, true ) end
                -- 3D context: cam.Start2D would skew the fill, so the interior slides as you
                -- look across the portal at an angle.
                render.DrawScreenQuad()
                if useScissor then render.SetScissorRect( 0, 0, 0, 0, false ) end
                wp.matViewUV:SetFloat( "$alpha", 1 )

                if belowWater then render.EnableClipping( prevClip ) end
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
