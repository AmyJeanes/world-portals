
-- Setup variables
wp.matBlack = Material( "wp/black" )
wp.matTrans = Material( "wp/trans" )
wp.matInvis = Material( "wp/invis" )
wp.matView = CreateMaterial(
    "UnlitGeneric",
    "GMODScreenspace",
    {
        [ "$basetexturetransform" ] = "center .5 .5 scale -1 -1 rotate 0 translate 0 0",
        [ "$texturealpha" ] = "0",
        [ "$vertexalpha" ] = "1",
    }
)
wp.matView2 = CreateMaterial("WorldPortals", "Core_DX90", {["$basetexture"] = wp.matBlack:GetName(), ["$model"] = "1"})

wp.portals = {}
wp.drawing = true --default portals to not draw
wp.rendermode = false

local POLY_SKIP_SENTINEL = {}

-- Reused across all portal RT renders this frame to avoid allocating a fresh
-- view struct per render.RenderView call (33+ calls/frame in dual-pair test
-- maps was producing major GC pauses).
wp._renderView = {
    x = 0,
    y = 0,
    w = 0,
    h = 0,
    fov = 0,
    origin = nil,
    angles = nil,
    dopostprocess = false,
    drawhud = false,
    drawmonitors = false,
    drawviewmodel = false,
    bloomtone = true,
    viewid = 1, -- VIEW_3DSKY
    zfar = nil,
}

CreateClientConVar("worldportals_resolution_percentage", "100", true, false, "World Portals - Render resolution percentage for portals", 1, 100)
CreateClientConVar("worldportals_recurse_depth", "1", true, false, "World Portals - Maximum portal recursion depth", 1, 9)
CreateClientConVar("worldportals_min_render_area", "100", true, false, "World Portals - Minimum cumulative on-screen pixel area for a recursed portal to render. Higher = more aggressive culling of deep / tiny portals.", 0, 100000)

local resolutionScale = 1
local recurseDepth = 1
local minRenderArea = 100

local function ClampPortalResolution(value)
    return math.Clamp((tonumber(value) or 100) / 100, 0.01, 1)
end

local function ClampRecurseDepth(value)
    return math.Clamp(math.floor(tonumber(value) or 1), 1, 9)
end

local function ClampMinRenderArea(value)
    return math.max(0, tonumber(value) or 0)
end

local function UpdatePortalResolution()
    resolutionScale = ClampPortalResolution(GetConVar("worldportals_resolution_percentage"):GetString())
end

local function UpdateRecurseDepth()
    recurseDepth = ClampRecurseDepth(GetConVar("worldportals_recurse_depth"):GetString())
end

local function UpdateMinRenderArea()
    minRenderArea = ClampMinRenderArea(GetConVar("worldportals_min_render_area"):GetString())
end

UpdatePortalResolution()
UpdateRecurseDepth()
UpdateMinRenderArea()

cvars.AddChangeCallback("worldportals_resolution_percentage", function(convarName, oldValue, newValue)
    resolutionScale = ClampPortalResolution(newValue)
end)

cvars.AddChangeCallback("worldportals_recurse_depth", function(convarName, oldValue, newValue)
    recurseDepth = ClampRecurseDepth(newValue)
end)

cvars.AddChangeCallback("worldportals_min_render_area", function(convarName, oldValue, newValue)
    minRenderArea = ClampMinRenderArea(newValue)
end)

function wp.GetMinRenderArea()
    return minRenderArea
end

function wp.GetRecurseDepth()
    return recurseDepth
end

function wp.GetPortalRenderDepth()
    return wp.renderdepth or wp.drawingdepth or 0
end

function wp.IsRenderingPortalView()
    return wp.drawing or (wp.renderdepth or 0) > 1
end

function wp.GetPortalRenderSize(width, height)
    width = width or ScrW()
    height = height or ScrH()

    return math.max(1, math.floor(width * resolutionScale)), math.max(1, math.floor(height * resolutionScale))
end

-- Quantize a world position to a 4-unit grid so cameras that drift by less
-- than that share a chain key (and reuse one RT) instead of churning a fresh
-- RT every frame as the player moves.
local function quantizePos(v)
    return math.floor(v.x / 4 + 0.5) .. "_" .. math.floor(v.y / 4 + 0.5) .. "_" .. math.floor(v.z / 4 + 0.5)
end

-- chainKey identifies which RT a given (depth, camera, portal) maps to.
-- At depth 1 every portal has only one chain (the player's view) so we omit
-- the camera and the d=1 RT stays stable across frames. At deeper levels we
-- fold the level camera in: chains that converge on identical cameras share
-- one RT (dedup), chains with different cameras get distinct RTs (no
-- last-write-wins overwrite between sibling chains).
local function getChainKey(depth, camPos, portal)
    if depth <= 1 or not camPos then
        return depth .. ":" .. portal:EntIndex()
    end
    return depth .. ":" .. quantizePos(camPos) .. ":" .. portal:EntIndex()
end

-- Pool of RTs shared across all portals for d > 1 renders. The chain-key
-- design at d > 1 produces many unique keys (one per quantized camera per
-- portal per depth), so per-portal caching grew unbounded as the player
-- moved — every fresh GetRenderTarget name allocates a new GPU surface and
-- the engine registry never frees them, which thrashes memory and tanks
-- frametime. The pool reuses a fixed set of RT names with LRU eviction to
-- bound that allocation. d=1 RTs stay per-portal-stable so portal:SetTexture
-- (consumed downstream) keeps working across frames.
local rtPool = {}
local rtPoolNextSlot = 0
local rtPoolMaxSize = 32
local frameCounter = 0

hook.Add("PreRender", "WorldPortals_AdvanceFrame", function()
    frameCounter = frameCounter + 1
end)

local function getPooledRT(chainKey, width, height)
    local entry = rtPool[chainKey]
    if entry and entry.width == width and entry.height == height then
        entry.lastFrame = frameCounter
        return entry.rt
    end
    -- Resolution changed for this slot — drop it and reallocate below.
    if entry then rtPool[chainKey] = nil end

    local count = 0
    for _ in pairs(rtPool) do count = count + 1 end

    if count < rtPoolMaxSize then
        local rt = GetRenderTarget("wp_chain_pool_" .. rtPoolNextSlot, width, height)
        rtPoolNextSlot = rtPoolNextSlot + 1
        rtPool[chainKey] = { rt = rt, lastFrame = frameCounter, width = width, height = height }
        return rt
    end

    -- Evict LRU, but never an entry already used this frame (still needed
    -- for the in-flight render). If everything is current-frame we've
    -- exceeded the pool — return nil and let the caller skip the render.
    local lruKey, lruFrame
    for k, e in pairs(rtPool) do
        if e.lastFrame < frameCounter and (not lruKey or e.lastFrame < lruFrame) then
            lruKey, lruFrame = k, e.lastFrame
        end
    end
    if not lruKey then return nil end

    local victim = rtPool[lruKey]
    if not victim then return nil end
    rtPool[lruKey] = nil
    if victim.width ~= width or victim.height ~= height then
        -- Old slot was a different size; we'd have to allocate a new RT
        -- anyway, which defeats pooling. Fall back to skip.
        return nil
    end
    rtPool[chainKey] = { rt = victim.rt, lastFrame = frameCounter, width = width, height = height }
    return victim.rt
end

function wp.GetPortalPoolStats()
    local count = 0
    for _ in pairs(rtPool) do count = count + 1 end
    return count, rtPoolMaxSize
end

---@return ITexture?
---@return number width
---@return number height
function wp.GetPortalTexture(portal, width, height, depth, chainKey)
    depth = ClampRecurseDepth(depth)
    width, height = wp.GetPortalRenderSize(width, height)

    -- d=1 stays per-portal stable: only one chain (the player view), and
    -- portal:SetTexture is consumed by downstream addons that expect a
    -- consistent texture handle frame-to-frame.
    if depth <= 1 then
        portal.WPTextures = portal.WPTextures or {}
        local key = "1:" .. width .. ":" .. height
        local texture = portal.WPTextures[key]
        if texture then return texture, width, height end
        texture = GetRenderTarget("portal:" .. portal:EntIndex() .. ":d1:" .. width .. ":" .. height, width, height)
        portal.WPTextures[key] = texture
        return texture, width, height
    end

    chainKey = chainKey or (depth .. ":" .. portal:EntIndex())
    return getPooledRT(chainKey, width, height), width, height
end

---@return ITexture
---@return number width
---@return number height
---@return number depth
function wp.GetPortalDrawTexture(portal)
    local depth = wp.drawtexturedepth or 1
    local camPos = wp.vieworigin or EyePos()
    local chainKey = getChainKey(depth, camPos, portal)
    local texture, width, height = wp.GetPortalTexture(portal, wp.viewwidth or ScrW(), wp.viewheight or ScrH(), depth, chainKey)
    return texture, width, height, depth
end

-- Per-frame set of chain keys whose RT has actually been rendered this
-- frame. Used both by renderportals (to skip duplicate work when two
-- chains converge to the same camera/portal) and by entity Draw (to skip
-- drawing portals whose RT wasn't filled, e.g. because their chain was
-- area-culled at a parent level — without this the Draw would sample
-- stale or undefined RT content and smear it across the screen).
local frameRenderedChains = {}

function wp.IsPortalChainRendered(portal, depth, camPos)
    depth = depth or wp.drawtexturedepth or 1
    camPos = camPos or wp.vieworigin or EyePos()
    return frameRenderedChains[getChainKey(depth, camPos, portal)] == true
end

-- Start drawing the portals
-- This prevents the game from crashing when loaded for the first time
hook.Add( "PostRender", "WorldPortals_StartRender", function()
    wp.drawing = false
    hook.Remove( "PostRender", "WorldPortals_StartRender" )
end )

function wp.shouldrender( portal, camOrigin, camAngle, camFOV )
    if not camOrigin then camOrigin = EyePos() end
    if not camAngle then camAngle = EyeAngles() end
    if not camFOV then camFOV = LocalPlayer():GetFOV() end
    local exitPortal = portal:GetExit()
    local falseWorld = portal:GetFalseWorld()
    local distance = camOrigin:Distance( portal:GetPos() )
    local disappearDist = portal:GetDisappearDist()

    if not IsValid( exitPortal ) and not (falseWorld and falseWorld ~= "") then return false end
    
    local override, drawblack = hook.Call( "wp-shouldrender", GAMEMODE, portal, exitPortal, camOrigin, camAngle, camFOV, wp.GetPortalRenderDepth() )
    if override ~= nil then return override, drawblack end

    if not portal:GetOpen() then return false end

    if portal:IsDormant() then return false end
    
    if not (disappearDist <= 0) and distance > disappearDist then return false end
    
    --don't render if the view is behind the portal
    -- Use the thick-portal back-face plane only at the top level (player view)
    -- so a player walking through a thick portal still sees its render during
    -- the brief client-side window before the teleport net message arrives.
    -- At depth>1 the inner camera lands inside the exit portal's thick volume
    -- by construction (paired-portal mirror), and rendering it would create
    -- an infinite recursion bouncing between the pair.
    local portalPos
    local thickness = portal:GetThickness()
    if thickness > 0 and wp.GetPortalRenderDepth() <= 1 then
        portalPos = portal:LocalToWorld(Vector(-thickness,0,0))
    else
        portalPos = portal:GetPos()
    end
    local behind = wp.IsBehind( camOrigin, portalPos, portal:GetForward() )
    if behind then return false end
    local lookingAt = wp.IsLookingAt( portal, portalPos, camOrigin, camAngle, camFOV )
    if not lookingAt then return false end

    return true
end


if not render.RealRenderView then
    render.RealRenderView = render.RenderView
end

local EMPTY={}
function WorldPortals_RenderView(view)
    local v=view or EMPTY
    local origin = v.origin or EyePos()
    local angles = v.angles or EyeAngles()
    local width = v.width or v.w or ScrW()
    local height = v.height or v.h or ScrH()
    local fov = v.fov or LocalPlayer():GetFOV()

    if not wp.drawing then
        wp.renderportals(origin, angles, width, height, fov, 1)
    end

    local oldRenderMode = wp.rendermode
    local oldViewOrigin = wp.vieworigin
    local oldViewAngle = wp.viewangle
    local oldViewFOV = wp.viewfov
    local oldViewWidth = wp.viewwidth
    local oldViewHeight = wp.viewheight

    wp.rendermode = true
    wp.vieworigin = origin
    wp.viewangle = angles
    wp.viewfov = fov
    wp.viewwidth = width
    wp.viewheight = height
    render.RealRenderView(view)
    wp.rendermode = oldRenderMode
    wp.vieworigin = oldViewOrigin
    wp.viewangle = oldViewAngle
    wp.viewfov = oldViewFOV
    wp.viewwidth = oldViewWidth
    wp.viewheight = oldViewHeight
end

render.RenderView = WorldPortals_RenderView
hook.Add("InitPostEntity", "WorldPortals_RenderView", function()
    render.RenderView = WorldPortals_RenderView
end)


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

local NEAR_EPS = 1

-- Sutherland-Hodgman clip of a world-space quad against the half-space in
-- front of the camera (signed distance along camFwd > NEAR_EPS). Returns
-- 0..5 world-space points.
local function clipQuadNearPlane(c1, c2, c3, c4, camPos, camFwd)
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

-- Polygon representation: flat float array {x1, y1, x2, y2, ...}.
-- Vertex count is #poly / 2 (or "is empty" via #poly == 0, "has triangle"
-- via #poly >= 6). Flat layout halves the per-vertex allocation burden
-- — previously each vertex was its own {x=, y=} table — which dominates
-- per-frame GC pressure on the debug overlay's recursive walk.

-- Frame-scoped polygon pool: clipping/intersection both produce many
-- intermediate polygons that all become garbage at end of frame. Hand them
-- back to the pool instead of letting them churn the GC.
local polyPool = {}
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
local function releasePoly(p)
    if p then polyPool[#polyPool + 1] = p end
end

-- Project a portal's visible-face quad through an arbitrary camera into
-- player-screen pixel space, applying near-plane clipping and Hor+ FOV
-- scaling. Inner cameras render to screen-aligned RTs sampled at screen
-- UV, so a feature at inner-NDC (u, v) lands at player-screen NDC (u, v)
-- — the same conversion works at top level (player camera) and at every
-- recursion depth. Returns a flat polygon (0, 6, 8, or 10 entries).
function wp.GetPortalScreenPolygon(portal, camPos, camAng, camFov, aspect)
    local fwd = camAng:Forward()
    local right = camAng:Right()
    local up = camAng:Up()
    -- Hor+ scaling: GetFOV() is the horizontal FOV at 4:3 reference; the
    -- engine derives vfov from that and widens hfov for wider aspects.
    local tanHalfV = math.tan(camFov * math.pi / 360) * 0.75
    local tanHalfH = tanHalfV * aspect

    local c1, c2, c3, c4 = getPortalCorners(portal)
    local clipped = clipQuadNearPlane(c1, c2, c3, c4, camPos, fwd)

    local sw, sh = ScrW(), ScrH()
    local out = acquirePoly()
    for i = 1, #clipped do
        local v = clipped[i] --[[@as Vector]]
        local rel = v - camPos
        local d = rel:Dot(fwd)
        local ndcX = rel:Dot(right) / (d * tanHalfH)
        local ndcY = rel:Dot(up)    / (d * tanHalfV)
        out[#out + 1] = (ndcX + 1) * 0.5 * sw
        out[#out + 1] = (1 - ndcY) * 0.5 * sh
    end
    return out
end

local function projectPolyOntoAxis(pts, ax, ay)
    local mn, mx = math.huge, -math.huge
    for i = 1, #pts, 2 do
        local d = pts[i] * ax + pts[i+1] * ay
        if d < mn then mn = d end
        if d > mx then mx = d end
    end
    return mn, mx
end

-- Test each edge of polygon `axes` as a candidate separating axis: project
-- both polygons onto the edge's normal and report disjoint ranges.
local function hasSeparatingEdge(axes, other)
    local n = #axes
    if n < 6 then return false end
    local p1x, p1y = axes[n-1], axes[n]
    for i = 1, n, 2 do
        local p2x, p2y = axes[i], axes[i+1]
        local ax = -(p2y - p1y)
        local ay = p2x - p1x
        local aMin, aMax = projectPolyOntoAxis(axes, ax, ay)
        local bMin, bMax = projectPolyOntoAxis(other, ax, ay)
        if aMax < bMin or bMax < aMin then return true end
        p1x, p1y = p2x, p2y
    end
    return false
end

-- Convex-polygon intersection via Separating Axis Theorem. Both inputs are
-- assumed convex (which our near-plane-clipped quads always are).
function wp.PolygonsIntersectSAT(a, b)
    if #a < 6 or #b < 6 then return false end
    if hasSeparatingEdge(a, b) then return false end
    if hasSeparatingEdge(b, a) then return false end
    return true
end

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

function wp.PolygonArea(poly)
    return math.abs(polygonSignedArea(poly))
end

local function reversePolygonInto(src, dst)
    for i = #dst, 1, -1 do dst[i] = nil end
    for i = #src - 1, 1, -2 do
        dst[#dst + 1] = src[i]
        dst[#dst + 1] = src[i + 1]
    end
    return dst
end

-- Sutherland-Hodgman: clip `subject` against directed edge (e1 → e2),
-- keeping vertices on the half-plane the right normal points into.
-- Caller is responsible for ensuring the clip edge winding gives a
-- right-normal-inward orientation. Result written into `out` (cleared
-- first), so callers can swap two reusable polygon buffers across edges.
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

-- Convex-polygon intersection via iterated Sutherland-Hodgman: clip the
-- subject polygon against every edge of the convex clip polygon. Returns
-- the (possibly empty) intersection polygon — a freshly-acquired pool
-- buffer, so callers should `releasePoly` it when done. Polygons projected
-- through portal-recursed cameras can come out with either winding
-- (paired-portal basis flips), so canonicalize the clip to the
-- right-normal-inward orientation that clipPolygonAgainstEdge expects.
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

    -- Two reusable buffers ping-ponged across edges so the per-edge clip
    -- doesn't allocate a fresh polygon table per iteration.
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

    -- Copy the final result so the two scratch buffers can be returned to
    -- the pool independently of the result's lifetime.
    for i = 1, #current do result[i] = current[i] end
    releasePoly(bufA)
    releasePoly(bufB)
    if clipBuf then releasePoly(clipBuf) end
    return result
end

-- Hand a polygon back to the per-frame pool.
function wp.ReleasePoly(p)
    releasePoly(p)
end

local framePortalRenderCount = 0
local framePortalRenderByDepth = {}

function wp.GetFramePortalRenderCount()
    return framePortalRenderCount
end

function wp.GetFramePortalRenderByDepth()
    return framePortalRenderByDepth
end

hook.Add("PreRender", "WorldPortals_ResetRenderCount", function()
    framePortalRenderCount = 0
    for d in pairs(framePortalRenderByDepth) do
        framePortalRenderByDepth[d] = 0
    end
    for k in pairs(frameRenderedChains) do
        frameRenderedChains[k] = nil
    end
end)

function wp.renderportals( plyOrigin, plyAngle, width, height, fov, depth, parentPoly, parentExitPos, parentExitFwd )
    if ( wp.drawing ) then return end

    depth = ClampRecurseDepth(depth)
    if depth > recurseDepth then return end

    local oldRenderDepth = wp.renderdepth
    wp.renderdepth = depth

    if depth == 1 or not wp.portals then
        wp.portals = ents.FindByClass( "linked_portal_door" )
    end

    local portals = wp.portals
    if ( not portals ) then
        wp.renderdepth = oldRenderDepth
        return
    end

    local renderWidth, renderHeight = wp.GetPortalRenderSize(width, height)
    local aspect = width / height

    -- Disable phys gun glow and beam
    local oldWepColor = LocalPlayer():GetWeaponColor()
    LocalPlayer():SetWeaponColor( Vector( 0, 0, 0 ) )

    for _, portal in pairs( portals ) do
        local exitPortal = portal:GetExit()
        local falseWorld = portal:GetFalseWorld()
        local chainKey = getChainKey(depth, plyOrigin, portal)

        -- Only d=1 needs an unconditional texture (for portal:SetTexture, used
        -- by downstream consumers). For d > 1 we defer pool allocation until
        -- we've actually passed all culls — otherwise the pool fills up with
        -- slots earmarked for portals that won't render this frame, starving
        -- the chains that will.
        local texture
        if depth == 1 then
            texture = wp.GetPortalTexture(portal, width, height, depth, chainKey)
            portal:SetTexture( texture )
        end

        local poly
        local cumulativePoly
        -- Dedup: if a sibling chain already rendered this exact (depth,
        -- camera, portal), the RT is already populated. Skip the work
        -- entirely; no recursion either, since the d+1 RTs along this
        -- branch are deterministic from (cam, portal) and were filled by
        -- the first chain.
        if not frameRenderedChains[chainKey] and wp.shouldrender(portal, plyOrigin, plyAngle, fov) then
            -- Exit clip-plane cull: the parent's render pushes a
            -- PushCustomClipPlane at its exit (normal = exit forward) that
            -- discards scene fragments behind it. A portal entirely behind
            -- that plane would render to clipped-out content, so skip it.
            local clipped = false
            if depth > 1 and parentExitPos and parentExitFwd then
                local signedDist = (portal:GetPos() - parentExitPos):Dot(parentExitFwd)
                if signedDist + portal:BoundingRadius() < -0.5 then
                    clipped = true
                end
            end

            if not clipped then
                if minRenderArea > 0 then
                    -- Compute screen polygon for visible-area culling. The
                    -- polygon also threads as parentPoly to children so deeper
                    -- portals can be culled against the cumulative footprint.
                    poly = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngle, fov, aspect)
                    if #poly < 6 then
                        wp.ReleasePoly(poly)
                        poly = nil
                    elseif depth > 1 and parentPoly then
                        cumulativePoly = wp.IntersectConvexPolygons(poly, parentPoly)
                        if #cumulativePoly < 6 or wp.PolygonArea(cumulativePoly) < minRenderArea then
                            wp.ReleasePoly(poly)
                            wp.ReleasePoly(cumulativePoly)
                            poly = nil
                            cumulativePoly = nil
                        end
                    else
                        cumulativePoly = poly
                    end
                else
                    -- Area cull disabled: skip the polygon machinery entirely.
                    -- It's the dominant per-frame computation source, so when
                    -- the user has dialled the threshold to 0 we save a
                    -- meaningful chunk of CPU. Use a static sentinel so the
                    -- "would render" check downstream still passes; children
                    -- in this branch will also see minRenderArea==0 and never
                    -- inspect the polygon's contents.
                    poly = POLY_SKIP_SENTINEL
                end
            end
        end

        -- Late texture allocation for d > 1: only consume a pool slot once we
        -- know the chain will actually render.
        if poly and not texture then
            texture = wp.GetPortalTexture(portal, width, height, depth, chainKey)
        end

        if poly and texture then
            framePortalRenderCount = framePortalRenderCount + 1
            framePortalRenderByDepth[depth] = (framePortalRenderByDepth[depth] or 0) + 1
            frameRenderedChains[chainKey] = true
            if IsValid(exitPortal) then
                hook.Call( "wp-prerender", GAMEMODE, portal, exitPortal, plyOrigin )
                render.PushRenderTarget( texture )
                    render.Clear( 0, 0, 0, 255, true, true )

                    local oldClip = render.EnableClipping( true )

                    local exit_forward = exitPortal:GetForward()
                    local exit_ang_offset = exitPortal:GetExitAngOffset()
                    if exit_ang_offset then
                        exit_forward:Rotate(exit_ang_offset)
                    end

                    local offset = exitPortal:GetExitPosOffset()

                    if IsValid(exitPortal:GetParent()) then
                        offset:Rotate(exitPortal:GetParent():GetAngles())
                    end

                    local exit_pos = exitPortal:GetPos() + offset

                    local camOrigin = wp.TransformPortalPos( plyOrigin, portal, exitPortal )
                    local camAngle = wp.TransformPortalAngle( plyAngle, portal, exitPortal )

                    local zfar = portal:GetZFar()
                    if zfar > 0 then
                        local relative_pos = plyOrigin - portal:GetPos()
                        local portal_to_exit_dist = exitPortal:GetPos():Distance(portal:GetPos())
                        local adjusted_zfar = portal_to_exit_dist + relative_pos:Dot(portal:GetForward())
                        zfar = math.max(adjusted_zfar, zfar)
                    else
                        zfar = nil
                    end

                    local childDepth = depth + 1
                    local drawPortalsInView = childDepth <= recurseDepth
                    if drawPortalsInView then
                        -- Cumulative ancestor footprint already computed in
                        -- the per-portal cull above; deeper portals are
                        -- culled against every ancestor's stencil chain.
                        wp.renderportals(camOrigin, camAngle, width, height, fov, childDepth, cumulativePoly, exit_pos, exit_forward)
                    end

                    local oldDrawing = wp.drawing
                    local oldDrawingEnt = wp.drawingent
                    local oldDrawingDepth = wp.drawingdepth
                    local oldDrawTextureDepth = wp.drawtexturedepth
                    local oldDrawPortalsInView = wp.drawportalsinview

                    wp.drawing = true
                    wp.drawingent = portal
                    wp.drawingdepth = depth
                    wp.drawtexturedepth = childDepth
                    wp.drawportalsinview = drawPortalsInView
                    -- Reuse a single view struct so the 30+ portal-render
                    -- calls per frame don't each allocate a fresh Lua table
                    -- (the resulting GC churn was producing 25–30ms hitches
                    -- ~3 times per second).
                    local rv = wp._renderView
                    rv.w = renderWidth
                    rv.h = renderHeight
                    rv.fov = fov
                    rv.origin = camOrigin
                    rv.angles = camAngle
                    rv.zfar = zfar
                    render.PushCustomClipPlane( exit_forward, exit_forward:Dot( exit_pos - exit_forward * 0.5 ) )
                        render.RenderView( rv )
                    wp.drawing = oldDrawing
                    wp.drawingent = oldDrawingEnt
                    wp.drawingdepth = oldDrawingDepth
                    wp.drawtexturedepth = oldDrawTextureDepth
                    wp.drawportalsinview = oldDrawPortalsInView

                    render.PopCustomClipPlane()
                    render.EnableClipping( oldClip )
                render.PopRenderTarget()

                hook.Call( "wp-postrender", GAMEMODE, portal, exitPortal, plyOrigin )
            elseif falseWorld and falseWorld ~= "" then
                wp.renderfalseworld(texture, portal, plyOrigin, plyAngle, renderWidth, renderHeight, fov )
            end
        end

        -- Recursive renderportals call has returned; the parent-poly we
        -- handed it is no longer referenced. Return our owned pool buffers,
        -- but never the static POLY_SKIP_SENTINEL (it's reused every frame).
        if poly and poly ~= POLY_SKIP_SENTINEL then
            wp.ReleasePoly(poly)
            if cumulativePoly and cumulativePoly ~= poly then
                wp.ReleasePoly(cumulativePoly)
            end
        end
    end
    LocalPlayer():SetWeaponColor( oldWepColor )
    wp.renderdepth = oldRenderDepth
end

hook.Add( "RenderScene", "WorldPortals_Render", function( plyOrigin, plyAngle, fov )
    wp.renderportals(plyOrigin, plyAngle, ScrW(), ScrH(), fov)
end )

hook.Add( "ShouldDrawLocalPlayer", "WorldPortals_Render", function()
    if wp.drawing then
        return true
    end
end )

hook.Add( "PreDrawHalos", "WorldPortals_Render", function()
    if wp.drawing then return false end
end )
