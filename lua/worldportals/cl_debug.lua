
CreateClientConVar("worldportals_debug", "0", true, false, "World Portals - Show portal render-decision debug overlay", 0, 1)

local NEAR_EPS = 1

local function getPortalCorners(portal)
    local pos = portal:GetPos()
    local fwd = portal:GetForward()
    local right = portal:GetRight()
    local up = portal:GetUp()
    local hw = portal:GetWidth() * 0.5
    local hh = portal:GetHeight() * 0.5
    -- visible face sits at pos - fwd*5 (matches DrawQuadEasy in entity cl_init.lua)
    local center = pos - fwd * 5
    return
        center + right * hw + up * hh,
        center - right * hw + up * hh,
        center - right * hw - up * hh,
        center + right * hw - up * hh
end

-- Sutherland-Hodgman clip of a quad against the half-space in front of the
-- camera (signed distance along camFwd > NEAR_EPS). Returns 0..5 world-space
-- points.
local function clipQuadToCamera(c1, c2, c3, c4, camPos, camFwd)
    local pts = {}

    local function clipEdge(a, b)
        local da = (a - camPos):Dot(camFwd) - NEAR_EPS
        local db = (b - camPos):Dot(camFwd) - NEAR_EPS
        if da > 0 then
            pts[#pts + 1] = a
            if db <= 0 then
                pts[#pts + 1] = a + (b - a) * (da / (da - db))
            end
        elseif db > 0 then
            pts[#pts + 1] = a + (b - a) * (da / (da - db))
        end
    end

    clipEdge(c1, c2)
    clipEdge(c2, c3)
    clipEdge(c3, c4)
    clipEdge(c4, c1)
    return pts
end

local COLOR_RENDERED = Color(0, 255, 0, 220)
local COLOR_CULLED = Color(255, 60, 60, 220)
local COLOR_CHILD = Color(255, 220, 0, 220)

-- Draw the clipped portal quad on the player screen using a custom camera's
-- NDC. The inner camera renders to a screen-aligned RT, so a feature at
-- inner-NDC (u, v) appears at player-screen NDC (u, v) within the parent's
-- stencil region.
local function drawClippedQuadNDC(child, camPos, camFwd, camRight, camUp, tanHalfH, tanHalfV)
    local c1, c2, c3, c4 = getPortalCorners(child)
    local pts = clipQuadToCamera(c1, c2, c3, c4, camPos, camFwd)
    if #pts < 2 then return end

    local sw, sh = ScrW(), ScrH()
    local first, prev
    for _, v in ipairs(pts) do
        local rel = v - camPos
        local d = rel:Dot(camFwd)
        local ndcX = rel:Dot(camRight) / (d * tanHalfH)
        local ndcY = rel:Dot(camUp)    / (d * tanHalfV)
        local s = {
            x = (ndcX + 1) * 0.5 * sw,
            y = (1 - ndcY) * 0.5 * sh,
        }
        if prev then
            surface.DrawLine(prev.x, prev.y, s.x, s.y)
        else
            first = s
        end
        prev = s
    end
    if first and prev and prev ~= first then
        surface.DrawLine(prev.x, prev.y, first.x, first.y)
    end
end

local function drawChildOverlays(parent, plyOrigin, plyAngles, plyFov, aspect, portals)
    local exit = parent:GetExit()
    if not IsValid(exit) then return end

    local innerOrigin = wp.TransformPortalPos(plyOrigin, parent, exit)
    local innerAngles = wp.TransformPortalAngle(plyAngles, parent, exit)
    local innerFwd = innerAngles:Forward()
    local innerRight = innerAngles:Right()
    local innerUp = innerAngles:Up()
    -- Source uses Hor+ scaling: GetFOV() is the horizontal FOV at 4:3
    -- reference; the actual rendering keeps the derived vertical FOV
    -- constant and widens hfov for wider aspects.
    local tanHalfV = math.tan(plyFov * math.pi / 360) * 0.75
    local tanHalfH = tanHalfV * aspect

    surface.SetDrawColor(COLOR_CHILD)
    for _, child in pairs(portals) do
        if IsValid(child)
           and wp.shouldrender(child, innerOrigin, innerAngles, plyFov) then
            drawClippedQuadNDC(child, innerOrigin, innerFwd, innerRight, innerUp, tanHalfH, tanHalfV)
        end
    end
end

local function drawClippedQuad(portal, camPos, camFwd)
    local c1, c2, c3, c4 = getPortalCorners(portal)
    local pts = clipQuadToCamera(c1, c2, c3, c4, camPos, camFwd)
    if #pts < 2 then return end

    local first, prev
    for _, v in ipairs(pts) do
        local s = v:ToScreen()
        if prev then
            surface.DrawLine(prev.x, prev.y, s.x, s.y)
        else
            first = s
        end
        prev = s
    end
    if first and prev and prev ~= first then
        surface.DrawLine(prev.x, prev.y, first.x, first.y)
    end
end

hook.Add("HUDPaint", "WorldPortals_Debug", function()
    if not GetConVar("worldportals_debug"):GetBool() then return end

    local camPos = EyePos()
    local camAng = EyeAngles()
    local camFwd = camAng:Forward()
    local camFov = LocalPlayer():GetFOV()
    local aspect = ScrW() / ScrH()
    local portals = ents.FindByClass("linked_portal_door")

    for _, portal in ipairs(portals) do
        if IsValid(portal) then
            local rendered = wp.shouldrender(portal)
            surface.SetDrawColor(rendered and COLOR_RENDERED or COLOR_CULLED)
            drawClippedQuad(portal, camPos, camFwd)

            if rendered then
                drawChildOverlays(portal, camPos, camAng, camFov, aspect, portals)
            end
        end
    end
end)
