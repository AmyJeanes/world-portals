
include( "shared.lua" )

AccessorFunc( ENT, "texture", "Texture" )

function ENT:DrawPortal(exitPortal)
    if not (self:GetModel() == "models/error.mdl") then
        render.ModelMaterialOverride( wp.matInvis )
        render.Model({model = self:GetModel(), pos = self:LocalToWorld(self:GetModelPos()), angle = self:LocalToWorldAngles(self:GetModelAng())})
        render.ModelMaterialOverride( false )
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
    if wp.drawing then return end
    local shouldrender,drawblack=wp.shouldrender(self)
    if not (shouldrender or drawblack) then return end

    local exitPortal = self:GetExit()
    if not IsValid(exitPortal) then return end
    hook.Call("wp-predraw", GAMEMODE, self, exitPortal)

    local width, height = ScrW(), ScrH()
    local texture = GetRenderTarget("portal:" .. self:EntIndex() .. ":" .. width .. ":" .. height, width, height)
    self:SetTexture( texture )

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

net.Receive("WorldPortals_Teleport", function()
    local portal = net.ReadEntity()
    local ent = net.ReadEntity()
    local new_pos = net.ReadVector()
    local new_angle = net.ReadAngle()
    if IsValid(portal) and IsValid(ent) then
        ent:SetPos( new_pos )
        if not ent:IsPlayer() then
            ent:SetAngles( new_angle )
        end
        hook.Call("wp-teleport", GAMEMODE, portal, ent, new_pos, new_angle)
    end
end)
