
ENT.Type                = "anim"
ENT.RenderGroup         = RENDERGROUP_BOTH -- fixes translucent stuff rendering behind the portal
ENT.Spawnable           = false
ENT.AdminOnly           = false
ENT.Editable            = false

function ENT:SetupBounds(w, h, t)
    local width = w or self:GetWidth()
    local height = h or self:GetHeight()
    local thickness = t or self:GetThickness()

    self.RenderMin = Vector(-(5 + thickness), -width / 2, -height / 2)
    self.RenderMax = Vector(- 5             ,  width / 2,  height / 2)
    self.RenderQuads = {
        -- bottom
        { Vector(self.RenderMin.x, self.RenderMin.y, self.RenderMin.z), Vector(self.RenderMax.x, self.RenderMin.y, self.RenderMin.z), Vector(self.RenderMax.x, self.RenderMax.y, self.RenderMin.z), Vector(self.RenderMin.x, self.RenderMax.y, self.RenderMin.z) },

        -- top
        { Vector(self.RenderMin.x, self.RenderMin.y, self.RenderMax.z), Vector(self.RenderMax.x, self.RenderMin.y, self.RenderMax.z), Vector(self.RenderMax.x, self.RenderMax.y, self.RenderMax.z), Vector(self.RenderMin.x, self.RenderMax.y, self.RenderMax.z) },

        -- back
        { Vector(self.RenderMin.x, self.RenderMin.y, self.RenderMin.z), Vector(self.RenderMin.x, self.RenderMin.y, self.RenderMax.z), Vector(self.RenderMin.x, self.RenderMax.y, self.RenderMax.z), Vector(self.RenderMin.x, self.RenderMax.y, self.RenderMin.z) },

        -- left
        { Vector(self.RenderMin.x, self.RenderMin.y, self.RenderMin.z), Vector(self.RenderMin.x, self.RenderMin.y, self.RenderMax.z), Vector(self.RenderMax.x, self.RenderMin.y, self.RenderMax.z), Vector(self.RenderMax.x, self.RenderMin.y, self.RenderMin.z) },
        
        -- right
        { Vector(self.RenderMin.x, self.RenderMax.y, self.RenderMin.z), Vector(self.RenderMin.x, self.RenderMax.y, self.RenderMax.z), Vector(self.RenderMax.x, self.RenderMax.y, self.RenderMax.z), Vector(self.RenderMax.x, self.RenderMax.y, self.RenderMin.z) },
    }

    self:SetCollisionBounds( self.RenderMin, self.RenderMax )

    if CLIENT then
        self:UpdateRenderBounds()
    end
end

-- Render bounds = the portal box unioned with the assigned model's bounds, so a custom model bigger
-- than its opening doesn't get frustum-culled when the opening is off-screen but the model is still
-- on-screen. Collision bounds stay the opening (set above).
function ENT:UpdateRenderBounds()
    if not (self.RenderMin and self.RenderMax) then return end
    local mins, maxs = Vector(self.RenderMin), Vector(self.RenderMax)
    local model = self:GetCustomModel()
    if model ~= "" then
        -- Read the model's bounds straight from its file rather than via GetModelRenderBounds, so
        -- we don't have to SetModel on the entity (which also resets the trigger collision bounds).
        local info = util.GetModelInfo(model)
        local lmn, lmx = info and info.HullMin, info and info.HullMax
        if lmn and lmx then
            local off, ang = self:GetCustomModelPosOffset(), self:GetCustomModelAngOffset()
            local corners = {
                Vector(lmn.x, lmn.y, lmn.z), Vector(lmx.x, lmn.y, lmn.z),
                Vector(lmn.x, lmx.y, lmn.z), Vector(lmx.x, lmx.y, lmn.z),
                Vector(lmn.x, lmn.y, lmx.z), Vector(lmx.x, lmn.y, lmx.z),
                Vector(lmn.x, lmx.y, lmx.z), Vector(lmx.x, lmx.y, lmx.z),
            }
            for _, corner in ipairs(corners) do
                local c = LocalToWorld(corner, angle_zero, off, ang)
                mins.x = math.min(mins.x, c.x); mins.y = math.min(mins.y, c.y); mins.z = math.min(mins.z, c.z)
                maxs.x = math.max(maxs.x, c.x); maxs.y = math.max(maxs.y, c.y); maxs.z = math.max(maxs.z, c.z)
            end
        end
    end
    self:SetRenderBounds(mins, maxs)
end

-- NetworkVarNotify fires before the value is applied, so defer the render-bounds recompute one frame
-- to read the settled value; coalesces multiple same-tick changes into one update.
function ENT:QueueRenderBoundsUpdate()
    if not CLIENT or self.WPBoundsQueued then return end
    self.WPBoundsQueued = true
    timer.Simple(0, function()
        if IsValid(self) then
            self.WPBoundsQueued = nil
            self:UpdateRenderBounds()
        end
    end)
end

function ENT:Initialize()

    if SERVER then
        self:SetTrigger(true)
        -- Map-set properties apply before Initialize, so we skip here to avoid overwriting them
        if not self.OpenSetByMap then
            self:SetOpen(true)
        end
        if not self.EnableTeleportSetByMap then
            self:SetEnableTeleport(true)
        end
    end

    self:SetMoveType( MOVETYPE_NONE )
    self:SetSolid( SOLID_OBB )
    self:SetNotSolid( true )
    self:SetCollisionGroup( COLLISION_GROUP_WORLD )

    self:DrawShadow( false )

    self:SetupBounds()

    if SERVER then
        self:RebuildCollisionFrame()
    end

    wp.RegisterPortal(self)
end

function ENT:SetupDataTables()
    self:NetworkVar( "Entity", "Exit" )

    self:NetworkVar( "Int", "Width" )
    self:NetworkVar( "Int", "Height" )
    self:NetworkVar( "Int", "DisappearDist" )
    self:NetworkVar( "Int", "Thickness" )
    self:NetworkVar( "Int", "Transparency" )
    self:NetworkVar( "Int", "ZFar" )

    self:NetworkVar( "String", "CustomLink" )
    self:NetworkVar( "String", "FalseWorld" )

    self:NetworkVar( "Bool", "Inverted" )
    self:NetworkVar( "Bool", "Open" )
    self:NetworkVar( "Bool", "EnableTeleport" )

    self:NetworkVar( "Vector", "ExitPosOffset" )
    self:NetworkVar( "Angle", "ExitAngOffset" )

    self:NetworkVar( "Vector", "CustomModelPosOffset" )
    self:NetworkVar( "Angle", "CustomModelAngOffset" )
    self:NetworkVar( "String", "CustomModel" )

    -- Rebuild the server-only collision frame on resize. Pass the new value
    -- explicitly (the accessor may still read stale here) and only touch an
    -- already-created frame (initial creation is in Initialize).
    self:NetworkVarNotify("Width", function(ent, name, old, new)
        ent:SetupBounds(new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(new, ent:GetHeight(), ent:GetThickness())
        end
    end)
    self:NetworkVarNotify("Height", function(ent, name, old, new)
        ent:SetupBounds(nil, new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(ent:GetWidth(), new, ent:GetThickness())
        end
    end)
    self:NetworkVarNotify("Thickness", function(ent, name, old, new)
        ent:SetupBounds(nil, nil, new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(ent:GetWidth(), ent:GetHeight(), new)
        end
    end)

    -- Restore parent collision if the portal closes/stops teleporting under a still-
    -- touching prop (EndTouch only covers the prop leaving).
    self:NetworkVarNotify("Open", function(ent, name, old, new)
        if SERVER and not new then wp.DisarmPortal(ent) end
    end)
    self:NetworkVarNotify("EnableTeleport", function(ent, name, old, new)
        if SERVER and not new then wp.DisarmPortal(ent) end
    end)

    -- Re-extend the render bounds when the model or its offset/angle change. The model itself is
    -- read by path (render.Model, util.GetModelInfo) and never set on the entity, so there's nothing
    -- to apply here. Deferred a frame (QueueRenderBoundsUpdate) since the notify fires pre-apply.
    self:NetworkVarNotify("CustomModel", function(ent)
        ent:QueueRenderBoundsUpdate()
    end)
    self:NetworkVarNotify("CustomModelPosOffset", function(ent)
        ent:QueueRenderBoundsUpdate()
    end)
    self:NetworkVarNotify("CustomModelAngOffset", function(ent)
        ent:QueueRenderBoundsUpdate()
    end)
end
