ENT.Type      = "anim"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.PrintName = "Portal Collision Frame"

-- A collision-only perimeter frame for a linked_portal_door opening. The server
-- builds a 4-slab multiconvex hull (top/bottom/left/right) that leaves the
-- centre hole open AND leaves the transit (forward) axis uncapped, so a prop
-- crossing the portal is funnelled through the opening cross-section while it is
-- no-collided with the wall the portal is mounted on (see sv_collision.lua).
--
-- It is parented to its portal, never drawn, and put in a collision group that
-- ignores players (props only), so it doesn't change how players move through
-- the doorway -- they keep going through the predicted teleport path untouched.

-- Slab dimensions, shared so the client debug overlay matches the server hull.
ENT.FrameBorder = 4    -- outward border beyond each opening edge: a thin solid lip is
                       -- all that's needed. A prop within the opening is bounded by the
                       -- slab's INNER face at the edge; the outward extent is never
                       -- touched in the normal case (oversized props can't fit anyway).
ENT.FrameFront    = 0  -- forward margin beyond the opening's FRONT FACE (x = -5). 0 keeps
                       -- the frame flush with the doorway so it doesn't poke out in front.
ENT.FrameMinDepth = 8  -- minimum corridor depth. A thick portal's frame lines the opening
                       -- exactly (front face to back face); a thin / near-zero-thickness
                       -- portal's opening has almost no depth, so clamp to at least this so
                       -- the frame stays a real volume that can bound a transiting prop.

-- The 4 perimeter slabs of the opening as {x0,x1,y0,y1,z0,z1} boxes in local
-- space (x = forward/transit, y = width, z = height; matches the linked_portal_door
-- SetupBounds opening: x in [-(5+thickness), -5], y +-width/2, z +-height/2).
-- Returns nil for a degenerate opening. One definition feeds both the physics
-- hull (init.lua BuildFrame) and the debug overlay (cl_init.lua).
function ENT:FrameSlabs(width, height, thickness)
    if not (width and height) or width <= 0 or height <= 0 then return nil end
    local hw, hh = width / 2, height / 2
    local b = self.FrameBorder
    -- The opening (matching linked_portal_door SetupBounds) spans x between the near
    -- face -5 and -(5+thickness). thickness can be NEGATIVE -- thin TARDIS portals
    -- report ~-5/-4, which puts -(5+thickness) IN FRONT of -5 -- so derive both edges
    -- and order them rather than clamping thickness to 0. (Clamping parked the frame
    -- behind a thin opening, leaving it visibly offset from the portal.)
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
