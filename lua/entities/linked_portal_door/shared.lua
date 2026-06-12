
ENT.Type                = "anim"
ENT.RenderGroup         = RENDERGROUP_BOTH -- fixes translucent stuff rendering behind the portal
ENT.Spawnable           = false
ENT.AdminOnly           = false
ENT.Editable            = false

function ENT:SetupBounds(w, h, t, d, o)
    local width = w or self:GetWidth()
    local height = h or self:GetHeight()

    -- Canonical render box: a visible face and a cavity at least 5u deep behind it. The
    -- stencil mask needs that depth so the near-Z clip can't slice it to nothing as the eye
    -- approaches (the flat-portal gap). SetDepth is the modern API: a cavity d deep behind an
    -- opening at FaceOffset. Legacy Thickness (and the Hammer keyvalue) is a compatibility shim
    -- that keeps the exact face the content authored and only adds depth behind it, never moving it.
    local face, back, seam, logic
    local depth = d or self:GetDepth()
    if depth > 0 then
        -- FaceOffset shifts only the rendered opening, never GetPos (the wormhole/teleport plane),
        -- so legacy thickness migrates to depth + faceoffset with its exit unchanged. 0 = flush.
        local faceoffset = o or self:GetFaceOffset()
        face, back, seam, logic = faceoffset, faceoffset - depth, depth - faceoffset, depth
    else
        local thickness = t or self:GetThickness()
        face  = math.max(-(5 + thickness), -5)
        back  = face - math.max(5, math.abs(thickness))
        seam  = 5 + thickness            -- legacy ghost-seam plane (cl_ghosts)
        logic = math.max(0, thickness)   -- legacy teleport/cull depth (sh_teleport, cl_render)
    end

    self.RenderMin = Vector(back, -width / 2, -height / 2)
    self.RenderMax = Vector(face,  width / 2,  height / 2)
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

    self.SeamOffset = seam
    self.LogicDepth = logic

    self:SetCollisionBounds( self.RenderMin, self.RenderMax )

    if CLIENT then
        self:SetRenderBounds( self.RenderMin, self.RenderMax )
    end
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
        self:SetInvertedReal(true)
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

    self:NetworkVar( "Float", "Width" )
    self:NetworkVar( "Float", "Height" )
    self:NetworkVar( "Int", "DisappearDist" )
    self:NetworkVar( "Int", "Thickness" )
    self:NetworkVar( "Int", "Transparency" )
    self:NetworkVar( "Int", "ZFar" )

    -- Depth is the modern API: opening flush at GetPos, cavity Depth deep behind it. 0 = unset
    -- (SetDepth never called or SetDepth(0)), which SetupBounds reads as the legacy Thickness
    -- shim. A positive call stores max(5, d) - so the minimum flush cavity is 5; 0 stays the
    -- unset sentinel so callers (and the debug tool) can switch a portal back to thickness.
    self:NetworkVar( "Float", "Depth" )
    local rawSetDepth = self.SetDepth
    self.SetDepth = function(s, v) rawSetDepth(s, (v and v > 0) and math.max(5, v) or 0) end

    -- FaceOffset places the rendered opening relative to GetPos (0 = flush, negative = recessed).
    -- It is render-only: it never moves GetPos, the wormhole/teleport plane, so a legacy thickness
    -- portal migrates to depth + faceoffset with no exit shift. Only read while Depth > 0.
    self:NetworkVar( "Float", "FaceOffset" )

    self:NetworkVar( "String", "CustomLink" )
    self:NetworkVar( "String", "FalseWorld" )

    self:NetworkVar( "Bool", "Inverted" )
    -- Every portal is an inverted cavity now, so Inverted is permanently on. SetInverted shipped
    -- for years and downstream addons still call it with assorted values; swallow them so they
    -- neither error nor un-invert. Keep the real setter to force it on in Initialize, so the
    -- TARDIS debug overlay's GetInverted read-back stays honest.
    self.SetInvertedReal = self.SetInverted
    self.SetInverted = function() end
    self:NetworkVar( "Bool", "Open" )
    self:NetworkVar( "Bool", "EnableTeleport" )

    self:NetworkVar( "Vector", "ExitPosOffset" )
    self:NetworkVar( "Angle", "ExitAngOffset" )

    self:NetworkVar( "Vector", "ModelPos" )
    self:NetworkVar( "Angle", "ModelAng" )

    -- Rebuild the server-only collision frame on resize. Pass the new value
    -- explicitly (the accessor may still read stale here) and only touch an
    -- already-created frame (initial creation is in Initialize).
    self:NetworkVarNotify("Width", function(ent, name, old, new)
        ent:SetupBounds(new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(new, ent:GetHeight(), ent.RenderMax.x, ent.RenderMin.x)
        end
    end)
    self:NetworkVarNotify("Height", function(ent, name, old, new)
        ent:SetupBounds(nil, new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(ent:GetWidth(), new, ent.RenderMax.x, ent.RenderMin.x)
        end
    end)
    self:NetworkVarNotify("Thickness", function(ent, name, old, new)
        ent:SetupBounds(nil, nil, new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(ent:GetWidth(), ent:GetHeight(), ent.RenderMax.x, ent.RenderMin.x)
        end
    end)
    self:NetworkVarNotify("Depth", function(ent, name, old, new)
        ent:SetupBounds(nil, nil, nil, new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(ent:GetWidth(), ent:GetHeight(), ent.RenderMax.x, ent.RenderMin.x)
        end
    end)
    self:NetworkVarNotify("FaceOffset", function(ent, name, old, new)
        ent:SetupBounds(nil, nil, nil, nil, new)
        if SERVER and IsValid(ent.CollisionFrame) then
            ent.CollisionFrame:BuildFrame(ent:GetWidth(), ent:GetHeight(), ent.RenderMax.x, ent.RenderMin.x)
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
end
