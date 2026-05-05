
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
local WEAPON_COLOR_OFF = Vector(0, 0, 0)
local THICK_PORTAL_POS = Vector()

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

CreateClientConVar("worldportals_enabled", "1", true, false, "Enable World Portals rendering. When 0, portals don't render and entity Draw bails — frees the per-frame engine RenderView allocations the recursion produces.", 0, 1)
CreateClientConVar("worldportals_recurse_depth", "1", true, false, "World Portals - Maximum portal recursion depth", 1, 9)

local enabled = true
local recurseDepth = 1

local function ClampRecurseDepth(value)
    return math.Clamp(math.floor(tonumber(value) or 1), 1, 9)
end

local function UpdateEnabled()
    enabled = GetConVar("worldportals_enabled"):GetInt() ~= 0
end

local function UpdateRecurseDepth()
    recurseDepth = ClampRecurseDepth(GetConVar("worldportals_recurse_depth"):GetString())
end

UpdateEnabled()
UpdateRecurseDepth()

cvars.AddChangeCallback("worldportals_enabled", function() UpdateEnabled() end)

cvars.AddChangeCallback("worldportals_recurse_depth", function(convarName, oldValue, newValue)
    recurseDepth = ClampRecurseDepth(newValue)
end)

function wp.IsEnabled()
    return enabled
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

-- Quantize a world position to a 4-unit grid so cameras that drift by less
-- than that share a chain key (and reuse one RT) instead of churning a fresh
-- RT every frame as the player moves.
local function quantizePos(v)
    return math.floor(v.x / 4 + 0.5), math.floor(v.y / 4 + 0.5), math.floor(v.z / 4 + 0.5)
end

-- chainKey identifies which RT a given (depth, camera, portal) maps to.
-- At depth 1 every portal has only one chain (the player's view) so we omit
-- the camera and the d=1 RT stays stable across frames. At deeper levels we
-- fold the level camera in: chains that converge on identical cameras share
-- one RT (dedup), chains with different cameras get distinct RTs (no
-- last-write-wins overwrite between sibling chains).
local function getChainKey(depth, camPos, portal)
    if depth <= 1 or not camPos then
        local key = portal.WPDepth1ChainKey
        if key then return key end
        key = depth .. ":" .. portal:EntIndex()
        portal.WPDepth1ChainKey = key
        return key
    end

    local qx, qy, qz = quantizePos(camPos)
    if portal.WPLastChainKeyDepth == depth
        and portal.WPLastChainKeyQX == qx
        and portal.WPLastChainKeyQY == qy
        and portal.WPLastChainKeyQZ == qz
    then
        return portal.WPLastChainKey
    end

    local key = depth .. ":" .. qx .. "_" .. qy .. "_" .. qz .. ":" .. portal:EntIndex()
    portal.WPLastChainKeyDepth = depth
    portal.WPLastChainKeyQX = qx
    portal.WPLastChainKeyQY = qy
    portal.WPLastChainKeyQZ = qz
    portal.WPLastChainKey = key
    return key
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
local rtPoolCount = 0
local rtPoolNextSlot = 0
local rtPoolMaxSize = 32
local frameCounter = 0

hook.Add("PreRender", "WorldPortals_AdvanceFrame", function()
    frameCounter = frameCounter + 1
end)

-- Per-entity per-frame scalar cache. Each portal's pos/forward/right/up are
-- the same for every render call this frame, but the engine getters
-- (portal:GetPos, portal:GetForward, ...) each allocate a fresh Vector. In
-- heavy-recurse scenes these were churning hundreds of Vectors per frame.
-- Caching as plain numbers on the entity table eliminates the alloc — the
-- next call this frame just reads scalar fields. Mutated entity poses are
-- still picked up: WPCacheFrame is reset implicitly when frameCounter
-- advances. Networked offsets (ExitPosOffset, ExitAngOffset) are cached
-- here too because they're accessed per render and otherwise allocate.
local function cachePortalScalars(p)
    if p.WPCacheFrame == frameCounter then return end
    local pos = p:GetPos()
    p.WPPosX, p.WPPosY, p.WPPosZ = pos.x, pos.y, pos.z
    local fwd = p:GetForward()
    p.WPFwdX, p.WPFwdY, p.WPFwdZ = fwd.x, fwd.y, fwd.z
    local rt = p:GetRight()
    p.WPRtX, p.WPRtY, p.WPRtZ = rt.x, rt.y, rt.z
    local up = p:GetUp()
    p.WPUpX, p.WPUpY, p.WPUpZ = up.x, up.y, up.z
    local ang = p:GetAngles()
    p.WPAngP, p.WPAngY, p.WPAngR = ang.p, ang.y, ang.r
    -- Networked offsets. ExitPosOffset is rotated by the parent's angles if
    -- the portal is parented (Hammer-style relative offsets follow the
    -- parent). Cache the *post-rotation* scalars so callers don't redo it.
    local epo = p:GetExitPosOffset()
    local parent = p:GetParent()
    if IsValid(parent) then
        epo:Rotate(parent:GetAngles())
    end
    p.WPEPOffX, p.WPEPOffY, p.WPEPOffZ = epo.x, epo.y, epo.z
    local eao = p:GetExitAngOffset()
    p.WPEAOffP, p.WPEAOffY, p.WPEAOffR = eao.p, eao.y, eao.r
    p.WPCacheFrame = frameCounter
end
wp.CachePortalScalars = cachePortalScalars

-- Static scratch buffers for the renderportals hot path. These get mutated
-- per render but never escape Lua (no engine call retains them after it
-- returns), so reusing them eliminates the per-render alloc churn.
local EXIT_ANG_BUF = Angle()
local EXIT_ANG_OFF_BUF = Angle()
local VECTOR_ORIGIN = Vector()
local VECTOR_UP = Vector(0, 0, 1)

-- Per-recursion-depth pool of reusable Vectors/Angles. Each depth's iteration
-- uses its own slot for camOrigin/camAngle/exitPos/exitFwd, so the recursive
-- call into depth+1 cannot overwrite the parent depth's values mid-render.
-- These are passed:
--   (a) to the recursive renderportals call as plyOrigin/plyAngle and
--       parentExitPos/parentExitFwd
--   (b) to render.RenderView via rv.origin/rv.angles after the recursion
--       returns, plus to PushCustomClipPlane for the exit-plane.
local depthSlots = {}
local function getDepthSlots(depth)
    local s = depthSlots[depth]
    if not s then
        s = {
            camOrigin = Vector(),
            camAngle = Angle(),
            exitPos = Vector(),
            exitFwd = Vector(),
        }
        depthSlots[depth] = s
    end
    return s
end

-- Allocation-light variants of TransformPortalPos / TransformPortalAngle:
-- write the result into a caller-provided Vector/Angle and reuse static
-- buffers for the intermediate exit-side pose. Original sh_utils versions
-- allocated ~9-10 Vectors/Angles per call; these allocate ~3 (the unavoidable
-- WorldToLocal[Angles] result + the LocalToWorld result pair).
-- Fully scalar TransformPortalPos. GMod convention (verified by probing
-- WorldToLocal at runtime): local.x = rel·forward, local.y = -(rel·right),
-- local.z = rel·up. The yaw-180 mirror negates local.x and local.y. The
-- inverse mapping for LocalToWorld is symmetric: world = portal_pos +
-- l.x*fwd - l.y*right + l.z*up. With the per-frame entity scalar cache
-- (cachePortalScalars), the no-exit-angle-offset path is allocation-free
-- — the engine getter calls (WorldToLocal/LocalToWorld) that originally
-- allocated 3 Vector/Angle pairs are eliminated.
local function transformPortalPosInto(out, vec, portal, exit_portal)
    cachePortalScalars(portal)
    cachePortalScalars(exit_portal)

    local rx = vec.x - portal.WPPosX
    local ry = vec.y - portal.WPPosY
    local rz = vec.z - portal.WPPosZ
    -- WorldToLocal projection into portal frame.
    local lx = rx * portal.WPFwdX + ry * portal.WPFwdY + rz * portal.WPFwdZ
    local ly = -(rx * portal.WPRtX + ry * portal.WPRtY + rz * portal.WPRtZ)
    local lz = rx * portal.WPUpX + ry * portal.WPUpY + rz * portal.WPUpZ
    -- Yaw-180 mirror.
    lx = -lx
    ly = -ly

    -- Exit basis. The common case is no exit-angle-offset, so the cached
    -- exit basis is the right one — zero allocs. Otherwise build the
    -- combined Angle in a static buffer and ask the engine for its basis
    -- (3 unavoidable allocs in this rarer branch).
    local efx, efy, efz, erx, ery, erz, eux, euy, euz
    if exit_portal.WPEAOffP == 0 and exit_portal.WPEAOffY == 0 and exit_portal.WPEAOffR == 0 then
        efx, efy, efz = exit_portal.WPFwdX, exit_portal.WPFwdY, exit_portal.WPFwdZ
        erx, ery, erz = exit_portal.WPRtX, exit_portal.WPRtY, exit_portal.WPRtZ
        eux, euy, euz = exit_portal.WPUpX, exit_portal.WPUpY, exit_portal.WPUpZ
    else
        EXIT_ANG_BUF.p = exit_portal.WPAngP + exit_portal.WPEAOffP
        EXIT_ANG_BUF.y = exit_portal.WPAngY + exit_portal.WPEAOffY
        EXIT_ANG_BUF.r = exit_portal.WPAngR + exit_portal.WPEAOffR
        local f = EXIT_ANG_BUF:Forward()
        local r = EXIT_ANG_BUF:Right()
        local u = EXIT_ANG_BUF:Up()
        efx, efy, efz = f.x, f.y, f.z
        erx, ery, erz = r.x, r.y, r.z
        eux, euy, euz = u.x, u.y, u.z
    end

    local epx = exit_portal.WPPosX + exit_portal.WPEPOffX
    local epy = exit_portal.WPPosY + exit_portal.WPEPOffY
    local epz = exit_portal.WPPosZ + exit_portal.WPEPOffZ

    out.x = epx + lx * efx - ly * erx + lz * eux
    out.y = epy + lx * efy - ly * ery + lz * euy
    out.z = epz + lx * efz - ly * erz + lz * euz
    return out
end
wp.TransformPortalPosInto = transformPortalPosInto

local function transformPortalAngleInto(out, angle, portal, exit_portal)
    local l_angle = portal:WorldToLocalAngles(angle)
    l_angle:RotateAroundAxis(VECTOR_UP, 180)
    cachePortalScalars(exit_portal)
    EXIT_ANG_BUF.p = exit_portal.WPAngP + exit_portal.WPEAOffP
    EXIT_ANG_BUF.y = exit_portal.WPAngY + exit_portal.WPEAOffY
    EXIT_ANG_BUF.r = exit_portal.WPAngR + exit_portal.WPEAOffR
    local _, w_angle = LocalToWorld(VECTOR_ORIGIN, l_angle, VECTOR_ORIGIN, EXIT_ANG_BUF)
    out.p = w_angle.p
    out.y = w_angle.y
    out.r = w_angle.r
    return out
end
wp.TransformPortalAngleInto = transformPortalAngleInto

local function getPooledRT(chainKey, width, height)
    local entry = rtPool[chainKey]
    if entry and entry.width == width and entry.height == height then
        entry.lastFrame = frameCounter
        return entry.rt
    end
    -- Resolution changed for this slot — drop it and reallocate below.
    if entry then
        rtPool[chainKey] = nil
        rtPoolCount = rtPoolCount - 1
    end

    if rtPoolCount < rtPoolMaxSize then
        local rt = GetRenderTarget("wp_chain_pool_" .. rtPoolNextSlot, width, height)
        rtPoolNextSlot = rtPoolNextSlot + 1
        rtPool[chainKey] = { rt = rt, lastFrame = frameCounter, width = width, height = height }
        rtPoolCount = rtPoolCount + 1
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
        rtPoolCount = rtPoolCount - 1
        return nil
    end
    rtPool[chainKey] = { rt = victim.rt, lastFrame = frameCounter, width = width, height = height }
    return victim.rt
end

function wp.GetPortalPoolStats()
    return rtPoolCount, rtPoolMaxSize
end

---@return ITexture?
---@return number width
---@return number height
function wp.GetPortalTexture(portal, width, height, depth, chainKey)
    depth = ClampRecurseDepth(depth)
    width = width or ScrW()
    height = height or ScrH()

    -- d=1 stays per-portal stable: only one chain (the player view), and
    -- portal:SetTexture is consumed by downstream addons that expect a
    -- consistent texture handle frame-to-frame.
    if depth <= 1 then
        local texture = portal.WPTexture1
        if texture and portal.WPTexture1Width == width and portal.WPTexture1Height == height then
            return texture, width, height
        end
        texture = GetRenderTarget("portal:" .. portal:EntIndex() .. ":d1:" .. width .. ":" .. height, width, height)
        portal.WPTexture1 = texture
        portal.WPTexture1Width = width
        portal.WPTexture1Height = height
        if texture then return texture, width, height end
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
    local chainKey = portal.WPLastDrawChainDepth == depth and portal.WPLastDrawChainCam == camPos and portal.WPLastDrawChainKey or getChainKey(depth, camPos, portal)
    if portal.WPLastRenderedChainKey == chainKey
        and portal.WPLastRenderedDepth == depth
        and portal.WPLastRenderedWidth
        and portal.WPLastRenderedHeight
        and portal.WPLastRenderedTexture
    then
        return portal.WPLastRenderedTexture, portal.WPLastRenderedWidth, portal.WPLastRenderedHeight, depth
    end
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
local frameShouldRenderCache = {}

function wp.IsPortalChainRendered(portal, depth, camPos)
    depth = depth or wp.drawtexturedepth or 1
    camPos = camPos or wp.vieworigin or EyePos()
    local chainKey = getChainKey(depth, camPos, portal)
    portal.WPLastDrawChainDepth = depth
    portal.WPLastDrawChainCam = camPos
    portal.WPLastDrawChainKey = chainKey
    return frameRenderedChains[chainKey] == true
end

-- Start drawing the portals
-- This prevents the game from crashing when loaded for the first time
hook.Add( "PostRender", "WorldPortals_StartRender", function()
    wp.drawing = false
    hook.Remove( "PostRender", "WorldPortals_StartRender" )
end )

-- Per-frame shouldrender cache: keyed by chainKey (depth + quantized camera +
-- portal). The same portal/camera pair is consulted by both renderportals
-- (at recursion entry) and entity Draw (inside the RT render). Without this,
-- shouldrender ran ~290 times/frame in heavy recurse scenes — each call
-- allocated ~3 Vectors (portal:GetPos, GetForward, view_ang:Forward inside
-- IsLookingAt), driving ~30 KB/frame of GC pressure. With the cache, calls
-- collapse to ~one per unique (depth, cam, portal) triple.
--
-- Cache values: 0 = !render+!black, 1 = render, 2 = !render+black, 3 = render+black.
-- Encoded as a number to avoid any per-call table allocation. nil means miss.
function wp.shouldrender( portal, camOrigin, camAngle, camFOV )
    if not camOrigin then camOrigin = EyePos() end
    if not camAngle then camAngle = EyeAngles() end
    if not camFOV then camFOV = LocalPlayer():GetFOV() end

    local cacheDepth = wp.drawtexturedepth or wp.renderdepth or 1
    local cacheKey = getChainKey(cacheDepth, camOrigin, portal)
    local cached = frameShouldRenderCache[cacheKey]
    if cached ~= nil then
        return (cached % 2) == 1, cached >= 2
    end

    local exitPortal = portal:GetExit()

    if not IsValid( exitPortal ) then
        local falseWorld = portal:GetFalseWorld()
        if not (falseWorld and falseWorld ~= "") then
            frameShouldRenderCache[cacheKey] = 0
            return false
        end
    end

    local renderDepth = wp.GetPortalRenderDepth()
    local override, drawblack = hook.Call( "wp-shouldrender", GAMEMODE, portal, exitPortal, camOrigin, camAngle, camFOV, renderDepth )
    if override ~= nil then
        frameShouldRenderCache[cacheKey] = (override and 1 or 0) + (drawblack and 2 or 0)
        return override, drawblack
    end

    if not portal:GetOpen() then
        frameShouldRenderCache[cacheKey] = 0
        return false
    end

    if portal:IsDormant() then
        frameShouldRenderCache[cacheKey] = 0
        return false
    end

    local disappearDist = portal:GetDisappearDist()
    if disappearDist > 0 then
        local portalPos = portal:GetPos()
        local dx = camOrigin.x - portalPos.x
        local dy = camOrigin.y - portalPos.y
        local dz = camOrigin.z - portalPos.z
        if dx * dx + dy * dy + dz * dz > disappearDist * disappearDist then
            frameShouldRenderCache[cacheKey] = 0
            return false
        end
    end


    --don't render if the view is behind the portal
    -- Use the thick-portal back-face plane only at the top level (player view)
    -- so a player walking through a thick portal still sees its render during
    -- the brief client-side window before the teleport net message arrives.
    -- At depth>1 the inner camera lands inside the exit portal's thick volume
    -- by construction (paired-portal mirror), and rendering it would create
    -- an infinite recursion bouncing between the pair.
    local portalPos = portal:GetPos()
    local forward = portal:GetForward()
    local thickness = portal:GetThickness()
    if thickness > 0 and renderDepth <= 1 then
        THICK_PORTAL_POS.x = portalPos.x - forward.x * thickness
        THICK_PORTAL_POS.y = portalPos.y - forward.y * thickness
        THICK_PORTAL_POS.z = portalPos.z - forward.z * thickness
        portalPos = THICK_PORTAL_POS
    end
    local behind = wp.IsBehind( camOrigin, portalPos, forward )
    if behind then
        frameShouldRenderCache[cacheKey] = 0
        return false
    end
    local lookingAt = wp.IsLookingAt( portal, portalPos, camOrigin, camAngle, camFOV )
    if not lookingAt then
        frameShouldRenderCache[cacheKey] = 0
        return false
    end

    frameShouldRenderCache[cacheKey] = 1
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


local NEAR_EPS = 1

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

-- Polygon representation: flat float array {x1, y1, x2, y2, ...}.
-- Vertex count is #poly / 2; "is empty" is #poly == 0; "has triangle"
-- is #poly >= 6. Flat layout halves the per-vertex allocation burden
-- vs the {x=, y=} table-of-tables representation.
--
-- Frame-scoped pool: clipping/intersection produce many intermediate
-- polygons that all become garbage at end of frame. Hand them back to
-- the pool instead of letting them churn the GC.
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

function wp.ReleasePoly(p)
    releasePoly(p)
end

-- Project a portal's visible-face quad through an arbitrary camera into
-- player-screen pixel space, applying near-plane clipping. Returns a
-- flat polygon {x1, y1, x2, y2, ...} (0, 6, 8, or 10 entries).
--
-- camFov is the *rendered* horizontal FOV (i.e. the value RenderScene
-- and CalcView pass around — already aspect-adjusted by the engine, NOT
-- the 4:3-reference hfov from Player:GetFOV()). tanHalfV is derived as
-- tanHalfH / aspect, which is the actual rendered vertical FOV. Don't
-- apply the 0.75 Hor+ factor here; that conversion is only valid going
-- from 4:3-reference hfov to vfov.
-- Single-slot cache for the camera basis: renderportals iterates ~7 portals
-- per recursion level all sharing the same plyAngle, so the second through
-- last calls in a level skip the three engine getter allocs and reuse the
-- last-computed basis. Cache key is the (p, y, r) triple — comparing
-- numbers avoids the Angle __eq's componentwise userdata path.
local lastCamP, lastCamY, lastCamR
local lastCamFwdX, lastCamFwdY, lastCamFwdZ = 0, 0, 0
local lastCamRtX, lastCamRtY, lastCamRtZ = 0, 0, 0
local lastCamUpX, lastCamUpY, lastCamUpZ = 0, 0, 0

function wp.GetPortalScreenPolygon(portal, camPos, camAng, camFov, aspect)
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

    local sw, sh = ScrW(), ScrH()
    local out = acquirePoly()

    cachePortalScalars(portal)
    local hw = portal:GetWidth() * 0.5
    local hh = portal:GetHeight() * 0.5
    -- visible face sits at pos - fwd*5 (matches DrawQuadEasy in entity cl_init.lua)
    local cx = portal.WPPosX - portal.WPFwdX * 5
    local cy = portal.WPPosY - portal.WPFwdY * 5
    local cz = portal.WPPosZ - portal.WPFwdZ * 5
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

local framePortalRenderCount = 0
local framePortalRenderByDepth = {}

-- Per-frame log of every portal render that actually happened, in render
-- order. Each entry stores the portal entity, the depth, and the camera
-- pose used to render it (so the debug overlay can re-project the portal
-- quad to screen without re-walking the recursion). Entries are reused
-- across frames — the list grows to high-water and stays there.
--
-- Population is gated on `recordRenders` so the overlay-off case pays
-- nothing per render. cl_debug toggles this flag from its convar
-- callback; defaults off so consumers without the overlay never pay.
local frameRenderedList = {}
local frameRenderedCount = 0
-- Parallel list of portals at depth>1 that were culled because their
-- screen-projected quad has no overlap with the cumulative ancestor
-- footprint (i.e. would not be visible through the stencil chain). The
-- overlay paints these yellow.
local frameCulledList = {}
local frameCulledCount = 0
local recordRenders = false

function wp.SetRecordRenders(on)
    recordRenders = on and true or false
end

function wp.GetFramePortalRenderCount()
    return framePortalRenderCount
end

function wp.GetFramePortalRenderByDepth()
    return framePortalRenderByDepth
end

-- Returns (list, count). Read-only — do not mutate. count is the number of
-- valid entries; list[i] beyond count holds stale data from earlier frames.
function wp.GetFrameRenderedList()
    return frameRenderedList, frameRenderedCount
end

-- Returns (list, count) for portals culled by the ancestor-overlap test
-- (i.e. they'd render geometrically but their on-screen quad is entirely
-- hidden by the cumulative ancestor stencil chain). Same shape as the
-- rendered list. Only populated when recordRenders is true.
function wp.GetFrameCulledList()
    return frameCulledList, frameCulledCount
end

hook.Add("PreRender", "WorldPortals_ResetRenderCount", function()
    framePortalRenderCount = 0
    for d in pairs(framePortalRenderByDepth) do
        framePortalRenderByDepth[d] = 0
    end
    for k in pairs(frameRenderedChains) do
        frameRenderedChains[k] = nil
    end
    for k in pairs(frameShouldRenderCache) do
        frameShouldRenderCache[k] = nil
    end
    frameRenderedCount = 0
    frameCulledCount = 0
end)

function wp.renderportals( plyOrigin, plyAngle, width, height, fov, depth, parentPoly, parentExitPos, parentExitFwd )
    if ( wp.drawing ) then return end
    if not enabled then return end

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

    local aspect = width / height

    -- Disable phys gun glow and beam
    local ply = LocalPlayer()
    local oldWepColor
    if depth == 1 then
        oldWepColor = ply:GetWeaponColor()
        ply:SetWeaponColor( WEAPON_COLOR_OFF )
    end

    for _, portal in ipairs( portals ) do

        -- Only d=1 needs an unconditional texture (for portal:SetTexture, used
        -- by downstream consumers). For d > 1 we defer pool allocation until
        -- we've actually passed all culls — otherwise the pool fills up with
        -- slots earmarked for portals that won't render this frame, starving
        -- the chains that will.
        local texture
        if depth == 1 then
            texture = wp.GetPortalTexture(portal, width, height, depth)
            portal:SetTexture( texture )
        end

        -- Eligible to render? Four culls:
        -- 1. Chain dedup: sibling chain already rendered this (depth, cam,
        --    portal) into the same RT.
        -- 2. shouldrender: hooks + FOV cone + back-face + open/dormant.
        -- 3. Exit clip-plane: portals entirely behind the parent's exit clip
        --    plane would render to clipped-out content.
        -- 4. Ancestor stencil overlap (depth>1): the on-screen quad of this
        --    portal must overlap the cumulative ancestor footprint, otherwise
        --    nothing of its render would be visible to the player anyway.
        local shouldRender = false
        local poly, cumulativePoly
        local chainKey = getChainKey(depth, plyOrigin, portal)
        -- shouldrender owns the per-frame cache now (keyed by chainKey),
        -- so we just call it — repeat callers within the frame hit the cache.
        local renderable = wp.shouldrender(portal, plyOrigin, plyAngle, fov) and true or false

        if renderable and not frameRenderedChains[chainKey] then
            local clipped = false
            if depth > 1 and parentExitPos and parentExitFwd then
                local portalPos = portal:GetPos()
                local signedDist = (portalPos.x - parentExitPos.x) * parentExitFwd.x
                    + (portalPos.y - parentExitPos.y) * parentExitFwd.y
                    + (portalPos.z - parentExitPos.z) * parentExitFwd.z
                if signedDist + portal:BoundingRadius() < -0.5 then
                    clipped = true
                end
            end

            if not clipped then
                if depth == 1 then
                    -- Top-level: no ancestor footprint to clip against.
                    -- Compute polygon once so children can intersect with it.
                    poly = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngle, fov, aspect)
                    if #poly < 6 then
                        releasePoly(poly); poly = nil
                    else
                        cumulativePoly = poly
                        shouldRender = true
                    end
                else
                    poly = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngle, fov, aspect)
                    if #poly < 6 then
                        releasePoly(poly); poly = nil
                    elseif parentPoly then
                        cumulativePoly = wp.IntersectConvexPolygons(poly, parentPoly)
                        if #cumulativePoly < 6 then
                            -- Hidden behind ancestor stencil chain — record
                            -- as culled (yellow in overlay) and skip render.
                            if recordRenders then
                                local slot = frameCulledList[frameCulledCount + 1]
                                if not slot then
                                    slot = {camOrigin = Vector(), camAngle = Angle()}
                                    frameCulledList[frameCulledCount + 1] = slot
                                end
                                slot.portal = portal
                                slot.depth = depth
                                slot.fov = fov
                                slot.camOrigin:Set(plyOrigin)
                                slot.camAngle:Set(plyAngle)
                                frameCulledCount = frameCulledCount + 1
                            end
                            releasePoly(poly); poly = nil
                            releasePoly(cumulativePoly); cumulativePoly = nil
                        else
                            shouldRender = true
                        end
                    else
                        cumulativePoly = poly
                        shouldRender = true
                    end
                end
            end
        end

        -- Late texture allocation for d > 1: only consume a pool slot once we
        -- know the chain will actually render.
        if shouldRender and not texture then
            texture = wp.GetPortalTexture(portal, width, height, depth, chainKey)
        end

        if shouldRender and texture then
            framePortalRenderCount = framePortalRenderCount + 1
            framePortalRenderByDepth[depth] = (framePortalRenderByDepth[depth] or 0) + 1
            frameRenderedChains[chainKey] = true
            portal.WPLastRenderedChainKey = chainKey
            portal.WPLastRenderedDepth = depth
            portal.WPLastRenderedWidth = width
            portal.WPLastRenderedHeight = height
            portal.WPLastRenderedTexture = texture

            -- Record the render for the debug overlay (only when enabled —
            -- the overlay-off case must not pay per-render cost). Reuses
            -- the slot table and its inner Vector/Angle/poly across frames
            -- so we don't churn the GC at 30+ renders/frame. Copying the
            -- camera and the cumulative polygon into our own buffers
            -- insulates the cache from pool reuse and caller mutation.
            if recordRenders then
                local slot = frameRenderedList[frameRenderedCount + 1]
                if not slot then
                    slot = {camOrigin = Vector(), camAngle = Angle(), cumPoly = {}}
                    frameRenderedList[frameRenderedCount + 1] = slot
                end
                slot.portal = portal
                slot.depth = depth
                slot.fov = fov
                slot.camOrigin:Set(plyOrigin)
                slot.camAngle:Set(plyAngle)
                local cp = slot.cumPoly
                for i = #cp, 1, -1 do cp[i] = nil end
                if cumulativePoly then
                    for i = 1, #cumulativePoly do cp[i] = cumulativePoly[i] end
                end
                frameRenderedCount = frameRenderedCount + 1
            end

            local exitPortal = portal:GetExit()
            if IsValid(exitPortal) then
                hook.Call( "wp-prerender", GAMEMODE, portal, exitPortal, plyOrigin )
                render.PushRenderTarget( texture )
                    render.Clear( 0, 0, 0, 255, true, true )

                    local oldClip = render.EnableClipping( true )

                    -- Cache exit-side scalars once per frame; subsequent reads
                    -- here are plain table lookups instead of allocating
                    -- Vector/Angle from the engine each call.
                    cachePortalScalars(exitPortal)
                    cachePortalScalars(portal)

                    -- Per-depth scratch buffers so the recursion at line below
                    -- can read parentExitPos/parentExitFwd from this depth's
                    -- slot without the child overwriting them.
                    local slots = getDepthSlots(depth)
                    local exit_forward = slots.exitFwd
                    local exit_pos = slots.exitPos

                    exit_forward.x = exitPortal.WPFwdX
                    exit_forward.y = exitPortal.WPFwdY
                    exit_forward.z = exitPortal.WPFwdZ
                    -- Apply the entity's exit-angle offset (rare; usually all
                    -- zero) by rotating the cached forward via a static Angle
                    -- buffer — no alloc.
                    if exitPortal.WPEAOffP ~= 0 or exitPortal.WPEAOffY ~= 0 or exitPortal.WPEAOffR ~= 0 then
                        EXIT_ANG_OFF_BUF.p = exitPortal.WPEAOffP
                        EXIT_ANG_OFF_BUF.y = exitPortal.WPEAOffY
                        EXIT_ANG_OFF_BUF.r = exitPortal.WPEAOffR
                        exit_forward:Rotate(EXIT_ANG_OFF_BUF)
                    end

                    -- exit_pos = exitPortal:GetPos() + (parent-rotated offset);
                    -- both are cached as scalars by cachePortalScalars.
                    exit_pos.x = exitPortal.WPPosX + exitPortal.WPEPOffX
                    exit_pos.y = exitPortal.WPPosY + exitPortal.WPEPOffY
                    exit_pos.z = exitPortal.WPPosZ + exitPortal.WPEPOffZ

                    local camOrigin = slots.camOrigin
                    local camAngle = slots.camAngle
                    transformPortalPosInto(camOrigin, plyOrigin, portal, exitPortal)
                    transformPortalAngleInto(camAngle, plyAngle, portal, exitPortal)

                    local zfar = portal:GetZFar()
                    if zfar > 0 then
                        local pdx = exitPortal.WPPosX - portal.WPPosX
                        local pdy = exitPortal.WPPosY - portal.WPPosY
                        local pdz = exitPortal.WPPosZ - portal.WPPosZ
                        local portal_to_exit_dist = math.sqrt(pdx*pdx + pdy*pdy + pdz*pdz)
                        local adjusted_zfar = portal_to_exit_dist
                            + (plyOrigin.x - portal.WPPosX) * portal.WPFwdX
                            + (plyOrigin.y - portal.WPPosY) * portal.WPFwdY
                            + (plyOrigin.z - portal.WPPosZ) * portal.WPFwdZ
                        zfar = math.max(adjusted_zfar, zfar)
                    else
                        zfar = nil
                    end

                    local childDepth = depth + 1
                    local drawPortalsInView = childDepth <= recurseDepth
                    if drawPortalsInView then
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
                    rv.w = width
                    rv.h = height
                    rv.fov = fov
                    rv.origin = camOrigin
                    rv.angles = camAngle
                    rv.zfar = zfar
                    -- Scalarised dot: avoids the two Vectors that
                    -- `exit_pos - exit_forward * 0.5` would allocate.
                    local efx, efy, efz = exit_forward.x, exit_forward.y, exit_forward.z
                    local clipD = efx * (exit_pos.x - efx * 0.5)
                                + efy * (exit_pos.y - efy * 0.5)
                                + efz * (exit_pos.z - efz * 0.5)
                    render.PushCustomClipPlane( exit_forward, clipD )
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
            else
                local falseWorld = portal:GetFalseWorld()
                if falseWorld and falseWorld ~= "" then
                    wp.renderfalseworld(texture, portal, plyOrigin, plyAngle, width, height, fov )
                end
            end
        end

        -- Recursion has returned; the parent-poly the child borrowed is
        -- no longer referenced. Release back to the per-frame pool.
        if poly then
            releasePoly(poly)
            if cumulativePoly and cumulativePoly ~= poly then
                releasePoly(cumulativePoly)
            end
        end
    end
    if depth == 1 and oldWepColor then
        ply:SetWeaponColor( oldWepColor )
    end
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
