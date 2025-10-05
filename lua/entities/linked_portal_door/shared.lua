
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
        self:SetRenderBounds( self.RenderMin, self.RenderMax )
    end
end

function ENT:Initialize()
    if SERVER then
        self:SetTrigger( true )
    end

    self:SetMoveType( MOVETYPE_NONE )
    self:SetSolid( SOLID_OBB )
    self:SetNotSolid( true )
    self:SetCollisionGroup( COLLISION_GROUP_WORLD )

    self:DrawShadow( false )

    self:SetupBounds()
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

    self:NetworkVar( "Bool", "Inverted" )

    self:NetworkVar( "Vector", "ExitPosOffset" )
    self:NetworkVar( "Angle", "ExitAngOffset" )

    self:NetworkVar( "Vector", "ModelPos" )
    self:NetworkVar( "Angle", "ModelAng" )

    self:NetworkVarNotify("Width", function(ent, name, old, new) ent:SetupBounds(new) end)
    self:NetworkVarNotify("Height", function(ent, name, old, new) ent:SetupBounds(nil, new) end)
    self:NetworkVarNotify("Thickness", function(ent, name, old, new) ent:SetupBounds(nil, nil, new) end)
end
