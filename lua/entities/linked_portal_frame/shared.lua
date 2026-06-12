ENT.Type      = "anim"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.PrintName = "Portal Collision Frame"

-- A collision-only perimeter frame for a linked_portal_door opening: a 4-slab
-- multiconvex hull (top/bottom/left/right) leaving the centre hole and the transit
-- axis open, so a prop crossing the portal is funnelled through the opening while
-- no-collided with the parent (sv_collision.lua). Never drawn; ignores players.

-- Slab dimensions, shared so the client debug overlay matches the server hull.
ENT.FrameBorder = 4    -- outward border (lip) beyond each opening edge; the prop is bounded by the slab's inner face
ENT.FrameFront    = 0  -- forward margin beyond the visible face (RenderMax.x)
ENT.FrameMinDepth = 8  -- minimum corridor depth; bounds a fast prop even for a flat portal

-- The 4 perimeter slabs as {x0,x1,y0,y1,z0,z1} boxes in local space (x=transit,
-- y=width, z=height; matches the door SetupBounds opening). nil for a degenerate
-- opening. Feeds both the physics hull (init.lua) and the debug overlay (cl_init.lua).
function ENT:FrameSlabs(width, height, faceX, deepX)
    if not (width and height) or width <= 0 or height <= 0 then return nil end
    local hw, hh = width / 2, height / 2
    local b = self.FrameBorder
    -- The corridor spans the door's render box: front at the visible face (RenderMax.x), back at
    -- the cavity back (RenderMin.x), so the hull is exactly the volume a prop transits. The
    -- FrameMinDepth floor keeps a minimum corridor for a flat portal so a fast prop is bounded.
    local frontX = (faceX or 0) + self.FrameFront
    local backX  = math.min(deepX or 0, frontX - self.FrameMinDepth)
    return {
        { backX, frontX, -hw - b, hw + b,  hh, hh + b },    -- top
        { backX, frontX, -hw - b, hw + b, -hh - b, -hh },   -- bottom
        { backX, frontX, -hw - b, -hw, -hh, hh },           -- left
        { backX, frontX,  hw, hw + b, -hh, hh },            -- right
    }
end
