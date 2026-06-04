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
ENT.FrameFront    = 0  -- forward margin beyond the front face (x = -5); 0 keeps the frame flush with the doorway
ENT.FrameMinDepth = 8  -- minimum corridor depth, so a thin (near-zero-thickness) portal still bounds a prop

-- The 4 perimeter slabs as {x0,x1,y0,y1,z0,z1} boxes in local space (x=transit,
-- y=width, z=height; matches the door SetupBounds opening). nil for a degenerate
-- opening. Feeds both the physics hull (init.lua) and the debug overlay (cl_init.lua).
function ENT:FrameSlabs(width, height, thickness)
    if not (width and height) or width <= 0 or height <= 0 then return nil end
    local hw, hh = width / 2, height / 2
    local b = self.FrameBorder
    -- The opening spans x between -5 and -(5+thickness). thickness can be NEGATIVE
    -- (thin portals report ~-5/-4), so derive both edges and order them rather than
    -- clamping (clamping parked the frame visibly behind a thin opening).
    local e1, e2 = -5, -(5 + (thickness or 0))
    local frontX = math.max(e1, e2) + self.FrameFront                       -- near edge (toward approach)
    local backX  = math.min(math.min(e1, e2), frontX - self.FrameMinDepth)  -- far edge, clamped to min depth
    return {
        { backX, frontX, -hw - b, hw + b,  hh, hh + b },    -- top
        { backX, frontX, -hw - b, hw + b, -hh - b, -hh },   -- bottom
        { backX, frontX, -hw - b, -hw, -hh, hh },           -- left
        { backX, frontX,  hw, hw + b, -hh, hh },            -- right
    }
end
