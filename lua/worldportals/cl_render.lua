-- Render

wp.matBlack = Material( "wp/black" )
wp.matTrans = Material( "wp/trans" )
wp.matInvis = Material( "wp/invis" )
wp.matView2 = CreateMaterial("WorldPortals", "Core_DX90", {["$basetexture"] = wp.matBlack:GetName(), ["$model"] = "1", ["$nocull"] = "1"})

-- Material that paints the exit-view RT into the portal opening (cl_init.lua). DrawScreenQuad
-- fills the active eye's sub-viewport, but its texture coords span the whole render target, so a
-- stereo/VR eye reads only its half - $basetexturetransform (wp.uvRemapMatrix) remaps the eye's
-- slice back to the full view. $translucent lets the per-draw $alpha (cl_init.lua) carry transparency.
wp.matViewUV = CreateMaterial("WorldPortals_ViewUV", "UnlitGeneric", {
    ["$basetexture"] = wp.matBlack:GetName(),
    ["$ignorez"] = "1",
    ["$nocull"] = "1",
    ["$vertexalpha"] = "1",
    ["$translucent"] = "1",
})

-- Reused per-eye texture-coord remap matrix for painting the exit view (see cl_init.lua / matViewUV).
wp.uvRemapMatrix = Matrix()

wp.drawing = true --default portals to not draw
wp.rendermode = false
local WEAPON_COLOR_OFF = Vector(0, 0, 0)
local THICK_PORTAL_POS = Vector()

-- Reused across every render.RenderView call this frame to avoid allocating
-- a fresh view struct per portal render (was driving GC hitches).
wp._renderView = {
    x = 0,
    y = 0,
    w = 0,
    h = 0,
    fov = 0,
    aspectratio = nil,
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

CreateClientConVar("worldportals_enabled", "1", true, false, "Enable World Portals rendering. When 0, portals don't render and entity Draw bails - frees the per-frame engine RenderView allocations the recursion produces.", 0, 1)
CreateClientConVar("worldportals_recurse_depth", "2", true, false, "World Portals - Maximum portal recursion depth", 1, 9)

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

-- Snap to a 4-unit grid so small camera drift reuses the same chain key / RT.
local function quantizePos(v)
    return math.floor(v.x / 4 + 0.5), math.floor(v.y / 4 + 0.5), math.floor(v.z / 4 + 0.5)
end

-- Identifies which RT a (depth, camera, portal) triple maps to. At d=1 the
-- camera is omitted (only one chain - the player view - so the RT stays
-- stable across frames). At d>1 the camera is folded in so sibling chains
-- with different cameras get distinct RTs and identical ones dedup.
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

-- Key for the render-decision cache. Unlike getChainKey, always folds the camera
-- in, so a second d=1 view in the same frame (a TARDIS scanner, a security
-- monitor) gets its own decision instead of reusing the eye view's. Separate
-- per-portal key fields so the two caches can't clobber each other.
local function getDecisionKey(depth, camPos, portal)
    if not camPos then return getChainKey(depth, nil, portal) end
    local qx, qy, qz = quantizePos(camPos)
    if portal.WPDecKeyDepth == depth
        and portal.WPDecKeyQX == qx
        and portal.WPDecKeyQY == qy
        and portal.WPDecKeyQZ == qz
    then
        return portal.WPDecKey
    end
    local key = "dec:" .. depth .. ":" .. qx .. "_" .. qy .. "_" .. qz .. ":" .. portal:EntIndex()
    portal.WPDecKeyDepth = depth
    portal.WPDecKeyQX = qx
    portal.WPDecKeyQY = qy
    portal.WPDecKeyQZ = qz
    portal.WPDecKey = key
    return key
end

-- Pool of d>1 exit-view RTs, bucketed by resolution. GetRenderTarget surfaces are
-- immortal (never freed), so each bucket caps at RT_POOL_PER_RES and LRU-recycles its
-- own. The resolution split isn't tidiness: a named surface is size-locked, so without
-- it a mono chain and a smaller stereo/VR eye chain collide on one key and remint a
-- fresh immortal surface every frame of movement - the stereoscopy leak/crash. 16
-- covers depth-9 stereo (8 levels x 2 eyes).
local RT_POOL_PER_RES = 16
local resPools = {}        -- resTag -> { count, nextSlot, entries = { chainKey -> {rt, lastGen} } }
local frameCounter = 0
-- Bumped per top-level view (mono eye, or each stereo/VR eye). LRU eviction recycles
-- only a prior view's surface (lastGen < viewGen), so the current view's in-flight
-- RTs aren't stolen.
local viewGen = 0

hook.Add("PreRender", "WorldPortals_AdvanceFrame", function()
    frameCounter = frameCounter + 1
end)

-- Per-frame scalar cache for portal pose. Engine getters
-- (GetPos/GetForward/...) each allocate a Vector; caching as plain numbers
-- on the entity table eliminates that for every call after the first.
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
    -- ExitPosOffset is rotated by the parent's angles if parented; cache
    -- the post-rotation scalars so callers don't redo it.
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

-- Static scratch buffers - mutated per call but never retained by engine.
local EXIT_ANG_BUF = Angle()
local EXIT_ANG_OFF_BUF = Angle()
local VECTOR_ORIGIN = Vector()
local VECTOR_UP = Vector(0, 0, 1)

-- One slot per recursion depth so the child call can't overwrite the
-- parent's camOrigin/camAngle/exitPos/exitFwd while they're still in use
-- across the recursion + post-recursion RenderView call.
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

-- Scalarised TransformPortalPos. GMod local frame:
--   local.x = rel·forward, local.y = -(rel·right), local.z = rel·up.
-- The yaw-180 mirror negates local.x/y; LocalToWorld is the symmetric
-- inverse. Allocation-free in the common (no exit-angle-offset) path.
local function transformPortalPosInto(out, vec, portal, exit_portal)
    cachePortalScalars(portal)
    cachePortalScalars(exit_portal)

    local rx = vec.x - portal.WPPosX
    local ry = vec.y - portal.WPPosY
    local rz = vec.z - portal.WPPosZ
    local lx = rx * portal.WPFwdX + ry * portal.WPFwdY + rz * portal.WPFwdZ
    local ly = -(rx * portal.WPRtX + ry * portal.WPRtY + rz * portal.WPRtZ)
    local lz = rx * portal.WPUpX + ry * portal.WPUpY + rz * portal.WPUpZ
    lx = -lx
    ly = -ly

    -- Exit basis: cached scalars in the common case; engine basis only when
    -- there's an exit-angle-offset (rare).
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
    local tag = math.floor(width) .. "x" .. math.floor(height)
    local bucket = resPools[tag]
    if not bucket then
        bucket = { count = 0, nextSlot = 0, entries = {} }
        resPools[tag] = bucket
    end

    local entry = bucket.entries[chainKey]
    if entry then
        entry.lastGen = viewGen
        return entry.rt
    end

    if bucket.count < RT_POOL_PER_RES then
        local rt = GetRenderTarget("wp_chain_pool_" .. tag .. "_" .. bucket.nextSlot, width, height)
        bucket.nextSlot = bucket.nextSlot + 1
        bucket.entries[chainKey] = { rt = rt, lastGen = viewGen }
        bucket.count = bucket.count + 1
        return rt
    end

    -- At capacity: recycle the least-recently-used surface from a PRIOR view (a
    -- current-view entry is still in flight this pass). Same bucket = same size, so
    -- the recycled surface is always usable.
    local lruKey, lruGen
    for k, e in pairs(bucket.entries) do
        if e.lastGen < viewGen and (not lruKey or e.lastGen < lruGen) then
            lruKey, lruGen = k, e.lastGen
        end
    end
    if not lruKey then return nil end

    local victim = bucket.entries[lruKey]
    if not victim then return nil end
    bucket.entries[lruKey] = nil
    bucket.entries[chainKey] = { rt = victim.rt, lastGen = viewGen }
    return victim.rt
end

---@return ITexture?
function wp.GetPortalTexture(portal, width, height, depth, chainKey)
    depth = ClampRecurseDepth(depth)
    width = width or ScrW()
    height = height or ScrH()

    -- d=1 stays per-portal stable so portal:SetTexture is frame-to-frame
    -- consistent for downstream consumers.
    if depth <= 1 then
        local texture = portal.WPTexture1
        if texture and portal.WPTexture1Width == width and portal.WPTexture1Height == height then
            return texture
        end
        texture = GetRenderTarget("portal:" .. portal:EntIndex() .. ":d1:" .. width .. ":" .. height, width, height)
        portal.WPTexture1 = texture
        portal.WPTexture1Width = width
        portal.WPTexture1Height = height
        return texture
    end

    chainKey = chainKey or (depth .. ":" .. portal:EntIndex())
    return getPooledRT(chainKey, width, height)
end

---@return ITexture
---@return number depth
function wp.GetPortalDrawTexture(portal)
    local depth = wp.drawtexturedepth or 1
    local camPos = wp.vieworigin or EyePos()
    local chainKey = portal.WPLastDrawChainDepth == depth and portal.WPLastDrawChainCam == camPos and portal.WPLastDrawChainKey or getChainKey(depth, camPos, portal)
    if portal.WPLastRenderedChainKey == chainKey
        and portal.WPLastRenderedDepth == depth
        and portal.WPLastRenderedTexture
    then
        return portal.WPLastRenderedTexture, depth
    end
    local texture = wp.GetPortalTexture(portal, wp.viewwidth or ScrW(), wp.viewheight or ScrH(), depth, chainKey)
    return texture, depth
end

-- Chain keys whose RT was filled this frame. renderportals uses it to dedup
-- converging chains; entity Draw uses it to skip portals whose RT is stale.
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

-- Defer first render until after PostRender (avoids first-load crash).
hook.Add( "PostRender", "WorldPortals_StartRender", function()
    wp.drawing = false
    hook.Remove( "PostRender", "WorldPortals_StartRender" )
end )

-- Per-frame cache keyed by chainKey. Result is encoded as a number so the
-- cache doesn't allocate a table per entry:
--   0 = !render+!black, 1 = render, 2 = !render+black, 3 = render+black.
function wp.shouldrender( portal, camOrigin, camAngle, camFOV )
    if not camOrigin then camOrigin = EyePos() end
    if not camAngle then camAngle = EyeAngles() end
    if not camFOV then camFOV = LocalPlayer():GetFOV() end

    local cacheDepth = wp.drawtexturedepth or wp.renderdepth or 1
    local cacheKey = getDecisionKey(cacheDepth, camOrigin, portal)
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

    cachePortalScalars(portal)
    local ppx, ppy, ppz = portal.WPPosX, portal.WPPosY, portal.WPPosZ
    local pfx, pfy, pfz = portal.WPFwdX, portal.WPFwdY, portal.WPFwdZ

    local disappearDist = portal:GetDisappearDist()
    if disappearDist > 0 then
        local dx = camOrigin.x - ppx
        local dy = camOrigin.y - ppy
        local dz = camOrigin.z - ppz
        if dx * dx + dy * dy + dz * dz > disappearDist * disappearDist then
            frameShouldRenderCache[cacheKey] = 0
            return false
        end
    end

    -- Back-face cull. A portal is an inverted cavity LogicDepth deep behind GetPos. Cull on the
    -- BACK plane only at d=1, so the eye can stand inside the cavity and still see through. At
    -- d>1 the mirror-transformed inner camera lands inside the exit's own cavity by construction,
    -- so culling on the origin plane there stops infinite recursion. A flat legacy portal has
    -- LogicDepth 0 (no cavity to stand in), so it culls on the origin plane as it always did.
    local depth = portal.LogicDepth or 0
    local planeX, planeY, planeZ = ppx, ppy, ppz
    if depth > 0 and renderDepth <= 1 then
        planeX = ppx - pfx * depth
        planeY = ppy - pfy * depth
        planeZ = ppz - pfz * depth
    end
    local behind = pfx * (camOrigin.x - planeX) + pfy * (camOrigin.y - planeY) + pfz * (camOrigin.z - planeZ) < 0
    if behind then
        frameShouldRenderCache[cacheKey] = 0
        return false
    end
    -- IsLookingAt expects a Vector; reuse a static buffer.
    THICK_PORTAL_POS.x = planeX
    THICK_PORTAL_POS.y = planeY
    THICK_PORTAL_POS.z = planeZ
    local lookingAt = wp.IsLookingAt( portal, THICK_PORTAL_POS, camOrigin, camAngle, camFOV )
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
    local aspect = v.aspectratio or (width / height)
    local fov = v.fov
    if not fov then
        -- A view with no fov (a stereo/VR eye) must match the engine's actual rendered fov:
        -- the aspect-corrected Hor+ value, not raw GetFOV() (the 4:3 reference), or the
        -- through-portal view zooms relative to the eye scene.
        fov = math.deg(2 * math.atan(math.tan(math.rad(LocalPlayer():GetFOV() * 0.5)) * aspect / (4 / 3)))
    end

    -- wp.drawing is true only inside a portal rendering its own exit RT (renderportals
    -- sets it before recursing); a top-level eye - each stereo/VR eye included, as those
    -- also route through render.RenderView - has it false and needs the stencil path.
    local nested = wp.drawing

    if not nested then
        -- Each top-level view (each stereo/VR eye is its own render.RenderView) needs its
        -- own RTs. frameRenderedChains dedups within one view's recursion, but its d=1 key
        -- omits the camera - so without clearing, a later eye reuses the first eye's RTs.
        for k in pairs(frameRenderedChains) do frameRenderedChains[k] = nil end
        wp.renderportals(origin, angles, width, height, fov, 1, nil, nil, nil, nil, aspect)
    end

    local oldRenderMode = wp.rendermode
    local oldViewOrigin = wp.vieworigin
    local oldViewAngle = wp.viewangle
    local oldViewFOV = wp.viewfov
    local oldViewWidth = wp.viewwidth
    local oldViewHeight = wp.viewheight
    local oldViewportX = wp.viewportX
    local oldViewportY = wp.viewportY
    local oldViewportW = wp.viewportW
    local oldViewportH = wp.viewportH
    local oldViewportRTW = wp.viewportRTW
    local oldViewportRTH = wp.viewportRTH

    wp.rendermode = nested
    wp.vieworigin = origin
    wp.viewangle = angles
    wp.viewfov = fov
    wp.viewwidth = width
    wp.viewheight = height
    -- This eye's pixel rect on the active render target, where cl_init.lua paints the
    -- portal RT: a sub-rect of vrmod's shared two-eye buffer in VR, of the back buffer
    -- in stereoscopy, or the whole screen in mono.
    wp.viewportX = v.x or 0
    wp.viewportY = v.y or 0
    wp.viewportW = width
    wp.viewportH = height
    -- Size of that full target: ScrW/ScrH here is the whole pushed buffer (both eyes in
    -- VR), which the per-eye texture-coord remap needs.
    wp.viewportRTW = ScrW()
    wp.viewportRTH = ScrH()
    render.RealRenderView(view)
    wp.rendermode = oldRenderMode
    wp.vieworigin = oldViewOrigin
    wp.viewangle = oldViewAngle
    wp.viewfov = oldViewFOV
    wp.viewwidth = oldViewWidth
    wp.viewheight = oldViewHeight
    wp.viewportX = oldViewportX
    wp.viewportY = oldViewportY
    wp.viewportW = oldViewportW
    wp.viewportH = oldViewportH
    wp.viewportRTW = oldViewportRTW
    wp.viewportRTH = oldViewportRTH
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

-- Polygons are flat arrays {x1, y1, x2, y2, ...}; vertex count is #poly/2.
-- Pool reuses buffers across the many intermediate polys produced by
-- clipping/intersection per frame.
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

    cachePortalScalars(portal)
    local hw = portal:GetWidth() * 0.5
    local hh = portal:GetHeight() * 0.5
    -- The cull poly is the visible face quad. RenderMax.x is that face (RenderMin.x is the
    -- deeper cavity back), so offset the poly centre out to it along forward.
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

local function reversePolygonInto(src, dst)
    for i = #dst, 1, -1 do dst[i] = nil end
    for i = #src - 1, 1, -2 do
        dst[#dst + 1] = src[i]
        dst[#dst + 1] = src[i + 1]
    end
    return dst
end

-- Sutherland-Hodgman: clip `subject` against edge (e1 → e2), keeping the
-- right-normal-inward half. Result written to `out` (cleared first) so
-- callers can ping-pong two buffers across edges.
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
-- returned pool buffer (call releasePoly when done). Portal-recursed cameras
-- can produce either winding so we canonicalize the clip first.
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

local framePortalRenderCount = 0
local framePortalRenderByDepth = {}

-- Debug-overlay log of every render this frame, in order. Slots reused
-- across frames; gated on `recordRenders` so overlay-off pays nothing.
local frameRenderedList = {}
local frameRenderedCount = 0
-- Same shape, for portals culled by ancestor-overlap (yellow in overlay).
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

-- Returns (list, count). Read-only; entries beyond count are stale.
function wp.GetFrameRenderedList()
    return frameRenderedList, frameRenderedCount
end

-- Same shape, for ancestor-overlap-culled portals. Only populated when
-- recordRenders is on.
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

-- The scene render leaves specular/HDR data in the RT's alpha channel; the translucent
-- exit-view draw (cl_init.lua) would read that as opacity and show the nearest surfaces as
-- fake translucency. Flatten alpha to 255 (RGB untouched) so the draw's opacity is clean -
-- solid where opaque, the portal's transparency where not.
local function flattenRTAlpha(width, height)
    render.OverrideColorWriteEnable(true, false)
    render.OverrideAlphaWriteEnable(true, true)
    cam.Start2D()
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawRect(0, 0, width, height)
    cam.End2D()
    render.OverrideAlphaWriteEnable(false, false)
    render.OverrideColorWriteEnable(false, false)
end

function wp.renderportals( plyOrigin, plyAngle, width, height, fov, depth, parentPoly, parentExitPos, parentExitFwd, parentPortal, aspect )
    if ( wp.drawing ) then return end
    if not enabled then return end

    depth = ClampRecurseDepth(depth)
    -- A new top-level view starts here (the mono eye, or each stereoscopy/VR eye).
    -- Advance the pool generation so this view can reclaim the previous view's
    -- already-consumed RTs instead of starving behind them (see viewGen).
    if depth <= 1 then viewGen = viewGen + 1 end
    if depth > recurseDepth then return end

    local oldRenderDepth = wp.renderdepth
    wp.renderdepth = depth

    -- The portal whose view we're rendering right now (nil for the player's own
    -- view). A consumer reads it to tell which portal the current render is for -
    -- e.g. an interior hiding its own portals while we render the view through its door.
    local oldRenderParent = wp.renderparent
    wp.renderparent = parentPortal

    local portals = wp.portals
    if ( not portals ) then
        wp.renderdepth = oldRenderDepth
        wp.renderparent = oldRenderParent
        return
    end

    -- The eye's true aspectratio (VR sets one that differs from w/h); the RT must
    -- render at it so the through-portal view lines up vertically with the eye scene.
    aspect = aspect or (width / height)

    -- Suppress phys gun glow/beam during the portal renders.
    local ply = LocalPlayer()
    local oldWepColor
    if depth == 1 then
        oldWepColor = ply:GetWeaponColor()
        ply:SetWeaponColor( WEAPON_COLOR_OFF )
    end

    for _, portal in ipairs( portals ) do

        -- d=1 needs a texture unconditionally for portal:SetTexture; d>1
        -- defers pool allocation until past all culls so doomed chains don't
        -- starve real ones for pool slots.
        local texture
        if depth == 1 then
            texture = wp.GetPortalTexture(portal, width, height, depth)
            portal:SetTexture( texture )
        end

        -- Four culls: chain dedup, shouldrender, parent exit-clip plane,
        -- ancestor screen-overlap.
        local shouldRender = false
        local poly, cumulativePoly
        local chainKey = getChainKey(depth, plyOrigin, portal)
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
                poly = wp.GetPortalScreenPolygon(portal, plyOrigin, plyAngle, fov, aspect, width, height)
                if #poly < 6 then
                    releasePoly(poly); poly = nil
                elseif parentPoly then
                    cumulativePoly = wp.IntersectConvexPolygons(poly, parentPoly)
                    if #cumulativePoly < 6 then
                        -- Hidden behind ancestor stencil chain.
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
                    -- No ancestor (depth 1): this poly seeds the children's clip.
                    cumulativePoly = poly
                    shouldRender = true
                end
            end
        end

        -- d>1: only consume a pool slot now that all culls have passed.
        if shouldRender and not texture then
            texture = wp.GetPortalTexture(portal, width, height, depth, chainKey)
        end

        if shouldRender and texture then
            framePortalRenderCount = framePortalRenderCount + 1
            framePortalRenderByDepth[depth] = (framePortalRenderByDepth[depth] or 0) + 1
            frameRenderedChains[chainKey] = true
            portal.WPLastRenderedChainKey = chainKey
            portal.WPLastRenderedDepth = depth
            portal.WPLastRenderedTexture = texture

            -- Record for the debug overlay; reuses slots across frames.
            -- Copy the camera and poly so pool reuse can't mutate them.
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
                hook.Call( "wp-prerender", GAMEMODE, portal, exitPortal, plyOrigin, depth )
                render.PushRenderTarget( texture )
                    render.Clear( 0, 0, 0, 255, true, true )

                    local oldClip = render.EnableClipping( true )

                    cachePortalScalars(exitPortal)
                    cachePortalScalars(portal)

                    -- Per-depth slots so the child recursion can't overwrite
                    -- this depth's parentExitPos/Fwd while still in use.
                    local slots = getDepthSlots(depth)
                    local exit_forward = slots.exitFwd
                    local exit_pos = slots.exitPos

                    exit_forward.x = exitPortal.WPFwdX
                    exit_forward.y = exitPortal.WPFwdY
                    exit_forward.z = exitPortal.WPFwdZ
                    -- Apply the (rare) exit-angle offset via a static buffer.
                    if exitPortal.WPEAOffP ~= 0 or exitPortal.WPEAOffY ~= 0 or exitPortal.WPEAOffR ~= 0 then
                        EXIT_ANG_OFF_BUF.p = exitPortal.WPEAOffP
                        EXIT_ANG_OFF_BUF.y = exitPortal.WPEAOffY
                        EXIT_ANG_OFF_BUF.r = exitPortal.WPEAOffR
                        exit_forward:Rotate(EXIT_ANG_OFF_BUF)
                    end

                    -- exit_pos = exitPortal:GetPos() + parent-rotated offset.
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
                        wp.renderportals(camOrigin, camAngle, width, height, fov, childDepth, cumulativePoly, exit_pos, exit_forward, portal, aspect)
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
                    -- Reuse one view struct across every render this frame.
                    local rv = wp._renderView
                    rv.w = width
                    rv.h = height
                    rv.fov = fov
                    rv.aspectratio = aspect
                    rv.origin = camOrigin
                    rv.angles = camAngle
                    rv.zfar = zfar
                    -- Scalar form of `exit_forward · (exit_pos - exit_forward*0.5)`.
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
                    flattenRTAlpha( width, height )
                render.PopRenderTarget()

                hook.Call( "wp-postrender", GAMEMODE, portal, exitPortal, plyOrigin, depth )
            else
                local falseWorld = portal:GetFalseWorld()
                if falseWorld and falseWorld ~= "" then
                    wp.renderfalseworld(texture, portal, plyOrigin, plyAngle, width, height, fov, depth )
                end
            end
        end

        -- Recursion done; release this iteration's polys back to the pool.
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
    wp.renderparent = oldRenderParent
end

hook.Add( "RenderScene", "WorldPortals_Render", function( plyOrigin, plyAngle, fov )
    -- In VR, vrmod renders the eyes itself and shows one on the desktop, so this normal
    -- full-screen pass just fills RTs nothing displays - skip the wasted work.
    if vrmod and vrmod.IsPlayerInVR() then return end
    -- Mono fills the whole screen; each stereo/VR eye overrides these per-eye in
    -- WorldPortals_RenderView.
    wp.viewportX, wp.viewportY = 0, 0
    wp.viewportW, wp.viewportH = ScrW(), ScrH()
    wp.viewportRTW, wp.viewportRTH = ScrW(), ScrH()
    wp.renderportals(plyOrigin, plyAngle, ScrW(), ScrH(), fov)
end )

-- While a portal's exit-view renders into its RT (wp.drawing), draw the local
-- player's model so your body shows up in portals (e.g. a portal whose pair points
-- back at you, or recursive views). Outside that - the normal eye view - this
-- returns nil, so the engine keeps first-person bodiless as usual.
local cvShowSelf = CreateClientConVar("worldportals_show_self", "1", true, false, "Show your own body inside portals", 0, 1)
hook.Add( "ShouldDrawLocalPlayer", "WorldPortals_Render", function()
    if wp.drawing then
        -- Toggle off => keep yourself out of portal RTs. (The mid-teleport ghost
        -- half is gated by this same convar, separately, in cl_ghosts.lua.)
        if not cvShowSelf:GetBool() then return false end
        return true
    end
end )

hook.Add( "PreDrawHalos", "WorldPortals_Render", function()
    if wp.drawing then return false end
end )
