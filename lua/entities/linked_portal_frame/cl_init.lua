include("shared.lua")

-- Debug: draw the (otherwise invisible) collision frames so the perimeter hull a
-- transiting prop is funnelled through can be inspected. Off by default.
CreateClientConVar("worldportals_debug_collision", "0", true, false,
    "World Portals - draw portal collision frames (debug)", 0, 1)

-- Collision-only; the server owns the physics hull. Never drawn normally.
function ENT:Initialize()
    self:SetNoDraw(true)
end

function ENT:Draw()
end

local FILL = Color(0, 180, 255, 50)
local WIRE = Color(0, 230, 255, 255)

-- One overlay pass for every frame, gated on the cvar. Each frame reads its
-- portal's networked dimensions and rebuilds the same slabs the server hull uses
-- (ENT:FrameSlabs), so the drawn boxes are exactly the collision shape.
hook.Add("PostDrawTranslucentRenderables", "WorldPortals_DebugCollision", function(_, skybox)
    if skybox then return end
    if not GetConVar("worldportals_debug_collision"):GetBool() then return end

    render.SetColorMaterial()
    -- Draw through walls/props (debug: the collision shape is often behind geometry).
    cam.IgnoreZ(true)
    for _, fr in ipairs(ents.FindByClass("linked_portal_frame")) do
        local portal = fr:GetNWEntity("WPPortal")
        if IsValid(fr) and IsValid(portal) then
            local slabs = fr:FrameSlabs(portal:GetWidth(), portal:GetHeight(), portal:GetThickness())
            if slabs then
                local pos, ang = fr:GetPos(), fr:GetAngles()
                for _, s in ipairs(slabs) do
                    local mn = Vector(s[1], s[3], s[5])
                    local mx = Vector(s[2], s[4], s[6])
                    render.DrawBox(pos, ang, mn, mx, FILL)
                    render.DrawWireframeBox(pos, ang, mn, mx, WIRE, true)
                end
            end
        end
    end
    cam.IgnoreZ(false)
end)
