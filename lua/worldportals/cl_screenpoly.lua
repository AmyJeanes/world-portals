-- Screen polygons

-- Project a portal's visible face through a camera into screen-space pixels, and intersect two such
-- convex polygons. The render cull (cl_render) uses this to skip a portal hidden behind its parent's
-- opening; the debug overlay draws them. Pure 2D math. Flat arrays {x1, y1, x2, y2, ...}.

local NEAR_EPS = 1

---@param out number[]
---@param x number
---@param y number
---@param z number
---@param cpx number
---@param cpy number
---@param cpz number
---@param fwdX number
---@param fwdY number
---@param fwdZ number
---@param rightX number
---@param rightY number
---@param rightZ number
---@param upX number
---@param upY number
---@param upZ number
---@param tanHalfH number
---@param tanHalfV number
---@param sw number
---@param sh number
local function addProjectedPoint(out, x, y, z, cpx, cpy, cpz, fwdX, fwdY, fwdZ, rightX, rightY, rightZ, upX, upY, upZ, tanHalfH, tanHalfV, sw, sh)
    local relX = x - cpx
    local relY = y - cpy
    local relZ = z - cpz
    local d = relX * fwdX + relY * fwdY + relZ * fwdZ
    local ndcX = (relX * rightX + relY * rightY + relZ * rightZ) / (d * tanHalfH)
    local ndcY = (relX * upX + relY * upY + relZ * upZ) / (d * tanHalfV)
    out[#out + 1] = (ndcX + 1) * 0.5 * sw
    out[#out + 1] = (1 - ndcY) * 0.5 * sh
end

---@param out number[]
---@param ax number
---@param ay number
---@param az number
---@param bx number
---@param by number
---@param bz number
---@param cpx number
---@param cpy number
---@param cpz number
---@param fwdX number
---@param fwdY number
---@param fwdZ number
---@param rightX number
---@param rightY number
---@param rightZ number
---@param upX number
---@param upY number
---@param upZ number
---@param tanHalfH number
---@param tanHalfV number
---@param sw number
---@param sh number
local function clipAndProjectEdge(out, ax, ay, az, bx, by, bz, cpx, cpy, cpz, fwdX, fwdY, fwdZ, rightX, rightY, rightZ, upX, upY, upZ, tanHalfH, tanHalfV, sw, sh)
    local aRelX = ax - cpx
    local aRelY = ay - cpy
    local aRelZ = az - cpz
    local bRelX = bx - cpx
    local bRelY = by - cpy
    local bRelZ = bz - cpz
    local da = aRelX * fwdX + aRelY * fwdY + aRelZ * fwdZ - NEAR_EPS
    local db = bRelX * fwdX + bRelY * fwdY + bRelZ * fwdZ - NEAR_EPS

    if da > 0 then
        addProjectedPoint(out, ax, ay, az, cpx, cpy, cpz, fwdX, fwdY, fwdZ, rightX, rightY, rightZ, upX, upY, upZ, tanHalfH, tanHalfV, sw, sh)
        if db <= 0 then
            local t = da / (da - db)
            addProjectedPoint(out, ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, cpx, cpy, cpz, fwdX, fwdY, fwdZ, rightX, rightY, rightZ, upX, upY, upZ, tanHalfH, tanHalfV, sw, sh)
        end
    elseif db > 0 then
        local t = da / (da - db)
        addProjectedPoint(out, ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, cpx, cpy, cpz, fwdX, fwdY, fwdZ, rightX, rightY, rightZ, upX, upY, upZ, tanHalfH, tanHalfV, sw, sh)
    end
end

-- Pool reuses buffers across the many intermediate polys produced by
-- clipping/intersection per frame.
local polyPool = {}
---@return number[]
local function acquirePoly()
    local n = #polyPool
    if n > 0 then
        local p = polyPool[n] --[[@as number[] ]]
        polyPool[n] = nil
        for i = #p, 1, -1 do p[i] = nil end
        return p
    end
    return {}
end
---@param p number[]?
local function releasePoly(p)
    if p then polyPool[#polyPool + 1] = p end
end

---@param p number[]?
function wp.ReleasePoly(p)
    releasePoly(p)
end

-- Project a portal's visible-face quad through a camera into screen pixel
-- space, near-plane-clipped. Returns a flat polygon (0, 6, 8, or 10 entries).
-- camFov is the rendered horizontal FOV (already aspect-adjusted by the
-- engine - don't re-apply Hor+ here).
--
-- Single-slot cache for the camera basis: renderportals iterates many
-- portals per level sharing one plyAngle, so subsequent calls skip the
-- three engine getter allocs.
local lastCamP, lastCamY, lastCamR
local lastCamFwdX, lastCamFwdY, lastCamFwdZ = 0, 0, 0
local lastCamRtX, lastCamRtY, lastCamRtZ = 0, 0, 0
local lastCamUpX, lastCamUpY, lastCamUpZ = 0, 0, 0

-- sw/sh are the projection space the polygon is measured in. They MUST be stable
-- across one recursion (the cull intersects a parent and child poly), so renderportals
-- passes its view width/height - NOT ScrW()/ScrH(), which silently changes the moment a
-- portal render target is pushed (a stereoscopy/VR eye RT is smaller than the screen, so
-- ancestor polys built pre-push and child polys built post-push would be in different
-- spaces and never intersect). Defaults to the screen for the debug overlay.
---@param portal linked_portal_door
---@param camPos Vector
---@param camAng Angle
---@param camFov number
---@param aspect number
---@param sw number?
---@param sh number?
function wp.GetPortalScreenPolygon(portal, camPos, camAng, camFov, aspect, sw, sh)
    local cap, cay, car = camAng.p, camAng.y, camAng.r
    if cap ~= lastCamP or cay ~= lastCamY or car ~= lastCamR then
        local f = camAng:Forward()
        local r = camAng:Right()
        local u = camAng:Up()
        lastCamFwdX, lastCamFwdY, lastCamFwdZ = f.x, f.y, f.z
        lastCamRtX, lastCamRtY, lastCamRtZ = r.x, r.y, r.z
        lastCamUpX, lastCamUpY, lastCamUpZ = u.x, u.y, u.z
        lastCamP, lastCamY, lastCamR = cap, cay, car
    end
    local fwd_x, fwd_y, fwd_z = lastCamFwdX, lastCamFwdY, lastCamFwdZ
    local right_x, right_y, right_z = lastCamRtX, lastCamRtY, lastCamRtZ
    local up_x, up_y, up_z = lastCamUpX, lastCamUpY, lastCamUpZ
    local tanHalfH = math.tan(camFov * math.pi / 360)
    local tanHalfV = tanHalfH / aspect

    sw = sw or ScrW()
    sh = sh or ScrH()
    local out = acquirePoly()

    wp.CachePortalScalars(portal)
    local hw = portal:GetWidth() * 0.5
    local hh = portal:GetHeight() * 0.5
    -- Project the portal's front face - the furthest extent along forward, read from the
    -- render geometry (RenderMin/Max). A flat or box front sits on the plane; an inverted
    -- portal's front is recessed, so a fixed offset can't match every shape's stencil.
    local rmin, rmax = portal.RenderMin, portal.RenderMax
    local frontOff = (rmin and rmax) and math.max(rmin.x, rmax.x) or 0
    local cx = portal.WPPosX + portal.WPFwdX * frontOff
    local cy = portal.WPPosY + portal.WPFwdY * frontOff
    local cz = portal.WPPosZ + portal.WPFwdZ * frontOff
    local rx = portal.WPRtX * hw
    local ry = portal.WPRtY * hw
    local rz = portal.WPRtZ * hw
    local ux = portal.WPUpX * hh
    local uy = portal.WPUpY * hh
    local uz = portal.WPUpZ * hh

    local x1, y1, z1 = cx + rx + ux, cy + ry + uy, cz + rz + uz
    local x2, y2, z2 = cx - rx + ux, cy - ry + uy, cz - rz + uz
    local x3, y3, z3 = cx - rx - ux, cy - ry - uy, cz - rz - uz
    local x4, y4, z4 = cx + rx - ux, cy + ry - uy, cz + rz - uz

    local cpx, cpy, cpz = camPos.x, camPos.y, camPos.z
    clipAndProjectEdge(out, x1, y1, z1, x2, y2, z2, cpx, cpy, cpz, fwd_x, fwd_y, fwd_z, right_x, right_y, right_z, up_x, up_y, up_z, tanHalfH, tanHalfV, sw, sh)
    clipAndProjectEdge(out, x2, y2, z2, x3, y3, z3, cpx, cpy, cpz, fwd_x, fwd_y, fwd_z, right_x, right_y, right_z, up_x, up_y, up_z, tanHalfH, tanHalfV, sw, sh)
    clipAndProjectEdge(out, x3, y3, z3, x4, y4, z4, cpx, cpy, cpz, fwd_x, fwd_y, fwd_z, right_x, right_y, right_z, up_x, up_y, up_z, tanHalfH, tanHalfV, sw, sh)
    clipAndProjectEdge(out, x4, y4, z4, x1, y1, z1, cpx, cpy, cpz, fwd_x, fwd_y, fwd_z, right_x, right_y, right_z, up_x, up_y, up_z, tanHalfH, tanHalfV, sw, sh)

    return out
end

---@param poly number[]
local function polygonSignedArea(poly)
    local n = #poly
    if n < 6 then return 0 end
    local sum = 0
    local prevX, prevY = poly[n-1], poly[n]
    for i = 1, n, 2 do
        local x, y = poly[i], poly[i+1]
        sum = sum + (prevX * y - x * prevY)
        prevX, prevY = x, y
    end
    return sum * 0.5
end

---@param src number[]
---@param dst number[]
local function reversePolygonInto(src, dst)
    for i = #dst, 1, -1 do dst[i] = nil end
    for i = #src - 1, 1, -2 do
        dst[#dst + 1] = src[i]
        dst[#dst + 1] = src[i + 1]
    end
    return dst
end

-- Sutherland-Hodgman: clip `subject` against edge (e1 -> e2), keeping the
-- right-normal-inward half. Result written to `out` (cleared first) so
-- callers can ping-pong two buffers across edges.
---@param subject number[]
---@param e1x number
---@param e1y number
---@param e2x number
---@param e2y number
---@param out number[]
local function clipPolygonAgainstEdge(subject, e1x, e1y, e2x, e2y, out)
    for i = #out, 1, -1 do out[i] = nil end
    local n = #subject
    if n == 0 then return out end

    local nx = e2y - e1y
    local ny = -(e2x - e1x)

    local prevX, prevY = subject[n-1], subject[n]
    local prevD = (prevX - e1x) * nx + (prevY - e1y) * ny
    for i = 1, n, 2 do
        local currX, currY = subject[i], subject[i+1]
        local currD = (currX - e1x) * nx + (currY - e1y) * ny
        if currD >= 0 then
            if prevD < 0 then
                local t = prevD / (prevD - currD)
                out[#out + 1] = prevX + (currX - prevX) * t
                out[#out + 1] = prevY + (currY - prevY) * t
            end
            out[#out + 1] = currX
            out[#out + 1] = currY
        elseif prevD >= 0 then
            local t = prevD / (prevD - currD)
            out[#out + 1] = prevX + (currX - prevX) * t
            out[#out + 1] = prevY + (currY - prevY) * t
        end
        prevX, prevY, prevD = currX, currY, currD
    end
    return out
end

-- Iterated Sutherland-Hodgman convex/convex intersection. Caller owns the
-- returned pool buffer (call wp.ReleasePoly when done). Portal-recursed cameras
-- can produce either winding so we canonicalize the clip first.
---@param subject number[]
---@param clip number[]
function wp.IntersectConvexPolygons(subject, clip)
    local result = acquirePoly()
    if #subject == 0 or #clip < 6 then return result end

    local area = polygonSignedArea(clip)
    if area == 0 then return result end
    local clipBuf
    if area > 0 then
        clipBuf = acquirePoly()
        clip = reversePolygonInto(clip, clipBuf)
    end

    -- Ping-pong two buffers so per-edge clipping doesn't alloc per iteration.
    local bufA = acquirePoly()
    for i = 1, #subject do bufA[i] = subject[i] end
    local bufB = acquirePoly()

    local n = #clip
    local prevX, prevY = clip[n-1], clip[n]
    local current = bufA
    local other = bufB
    for i = 1, n, 2 do
        local cx, cy = clip[i], clip[i+1]
        clipPolygonAgainstEdge(current, prevX, prevY, cx, cy, other)
        local tmp = current
        current = other
        other = tmp
        if #current == 0 then break end
        prevX, prevY = cx, cy
    end

    -- Copy out so the scratch buffers can return to the pool now.
    for i = 1, #current do result[i] = current[i] end
    releasePoly(bufA)
    releasePoly(bufB)
    if clipBuf then releasePoly(clipBuf) end
    return result
end
