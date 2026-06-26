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
---@param portal LinkedPortalDoor
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
-- in, so a second d=1 view in the same frame (a security monitor, an RT camera)
-- gets its own decision instead of reusing the eye view's. Separate per-portal
-- key fields so the two caches can't clobber each other.
---@param portal LinkedPortalDoor
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
-- fresh immortal surface every frame of movement - the stereoscopy leak/crash. The per
-- bucket cap trades VRAM for recursion headroom (mono uses one bucket, stereo/VR one
-- per eye size).
local RT_POOL_PER_RES = 32
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
-- cl_screenpoly's GetPortalScreenPolygon reads these cached scalars.
wp.CachePortalScalars = cachePortalScalars

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

-- The small d>1 RT pool is drained depth-first in iteration order, so in raw array order
-- portals late in wp.portals starve. Sort the top level by on-screen prominence so the
-- portal you're looking at claims pool slots first; depth-first then renders its subtree.
local sortBuffer = {} ---@type LinkedPortalDoor[]
local function sortByPriorityDesc(a, b)
    return a.WPSortKey > b.WPSortKey
end
---@return LinkedPortalDoor[] sorted, integer count
local function getSortedPortals(portals, camX, camY, camZ, fwdX, fwdY, fwdZ)
    local buf = sortBuffer -- shared buffer is safe: top-level renders never nest
    local n = #portals
    for i = 1, n do
        local p = portals[i]
        cachePortalScalars(p)
        local dx = p.WPPosX - camX
        local dy = p.WPPosY - camY
        local dz = p.WPPosZ - camZ
        local dot = dx * fwdX + dy * fwdY + dz * fwdZ
        if dot > 0 then
            -- Rank each portal by how much of the view it commands: larger and closer
            -- portals, and ones more directly ahead, score higher - so the one you're
            -- looking at outranks those off to the side or in the distance. The squared
            -- terms keep it a sqrt-free comparison which is cheaper.
            local distSqr = dx * dx + dy * dy + dz * dz + 1
            p.WPSortKey = p:GetWidth() * p:GetHeight() * dot * dot / (distSqr * distSqr)
        else
            p.WPSortKey = 0 -- behind the camera
        end
        buf[i] = p
    end
    for i = n + 1, #buf do buf[i] = nil end
    table.sort(buf, sortByPriorityDesc)
    return buf, n
end

-- Scalarised TransformPortalPos. GMod local frame:
--   local.x = rel·forward, local.y = -(rel·right), local.z = rel·up.
-- The yaw-180 mirror negates local.x/y; LocalToWorld is the symmetric
-- inverse. Allocation-free in the common (no exit-angle-offset) path.
---@param portal LinkedPortalDoor
---@param exit_portal LinkedPortalDoor
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

---@param portal LinkedPortalDoor
---@param exit_portal LinkedPortalDoor
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

-- Pooled scratch tables for the per-view frameRenderedChains swap below - pooled, not one
-- shared table, so a render nested inside another's scene draw stays isolated.
local chainTablePool = {}
local function acquireChainTable()
    local n = #chainTablePool
    if n > 0 then
        local t = chainTablePool[n]
        chainTablePool[n] = nil
        return t
    end
    return {}
end
local function releaseChainTable(t)
    for k in pairs(t) do t[k] = nil end
    chainTablePool[#chainTablePool + 1] = t
end

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

    -- Back-face cull. Use the thick-portal back-plane only at d=1 - at d>1
    -- the inner camera lands inside the exit's thick volume by construction
    -- and would bounce-recurse forever.
    local thickness = portal:GetThickness()
    local planeX, planeY, planeZ = ppx, ppy, ppz
    if thickness > 0 and renderDepth <= 1 then
        planeX = ppx - pfx * thickness
        planeY = ppy - pfy * thickness
        planeZ = ppz - pfz * thickness
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

    -- Each top-level view (stereo/VR eye, or a secondary RT view like a monitor) needs its own
    -- chain set: the d=1 key omits the camera, so sharing lets a later view reuse an earlier
    -- one's RTs. Swap a fresh set in and restore the caller's after RealRenderView, so a
    -- secondary render can't wipe the chains the eye view's post-RenderScene draw relies on.
    local savedChains
    if not nested then
        savedChains = frameRenderedChains
        frameRenderedChains = acquireChainTable()
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

    if not nested then
        releaseChainTable(frameRenderedChains)
        frameRenderedChains = savedChains
    end
end

render.RenderView = WorldPortals_RenderView
hook.Add("InitPostEntity", "WorldPortals_RenderView", function()
    render.RenderView = WorldPortals_RenderView
end)

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

-- 3D skybox reconstruction for an out-of-bounds exit. When a portal exit camera lands in
-- solid, the engine skips the sky pass, so the distant sky_camera scenery (the parallax
-- miniature: far hills, buildings) is missing too. We render that scenery to a render target
-- in a pre-pass, then the void hook composites it as the far-plane backdrop - the 3D extension
-- of the 2D void sky, on whenever the map has a 3D skybox. The flat 2D cube stays the fallback,
-- for maps with no 3D skybox or nested out-of-bounds views where the cheap cube is enough.
-- Only top-level portals pay for the 3D pre-pass; deeper out-of-bounds views use the 2D cube.
local VOIDSKY_3D_DEPTH = 1

-- Dev aid (WorldPortals_VoidSkyDebug below): paints the reconstruction over the normal view
-- anywhere. Declared here so the frame-start pre-pass in RenderScene can read it.
local dbgVoidSky = CreateClientConVar( "worldportals_debug_voidsky", "0", true, false )

local skyRTs = {}
local function getSkyRT( w, h )
    local tag = math.floor( w ) .. "x" .. math.floor( h )
    local rt = skyRTs[tag]
    if not rt then
        -- Its own depth buffer (MATERIAL_RT_DEPTH_SEPARATE): the pre-pass clears depth, and a
        -- buffer shared with the main view would wipe its depth so the far-plane blit then paints
        -- over everything. One surface per resolution - a render target is size-locked, so mono
        -- and the smaller VR eyes each need their own (a shared name across sizes leaks surfaces).
        rt = GetRenderTargetEx( "wp_voidsky3d_" .. tag, w, h, RT_SIZE_NO_CHANGE,
            MATERIAL_RT_DEPTH_SEPARATE, bit.bor( 2, 4, 8, 256 ), 0, IMAGE_FORMAT_RGBA8888 )
        skyRTs[tag] = rt
    end
    return rt
end

-- zfar is the engine's MAX_TRACE_LENGTH so the whole miniature scene fits; viewid 1
-- (VIEW_3DSKY) matches the portal renders and avoids the halo/visibility corruption viewid 0
-- reintroduces.
local skyView = {
    x = 0, y = 0,
    drawviewmodel = false, drawhud = false, drawmonitors = false,
    dopostprocess = false, bloomtone = false,
    znear = 2, zfar = 56756, viewid = 1,
}
-- exitPos/exitForward (the exit portal's plane, world space) clip the skybox to the same side the
-- real exit view shows - omitted by the debug overlay, which has no portal.
local function renderVoidSky3D( camOrigin, camAngle, w, h, fov, aspect, exitPos, exitForward )
    local sky = wp.sky3d
    if not sky then return nil end
    local scale = sky.scale
    local invScale = scale > 0 and ( 1 / scale ) or 1
    -- The skybox camera sits at the scaled-down view position offset by the sky_camera origin.
    local skyOrigin = camOrigin * invScale + sky.origin

    local effAspect = aspect or ( w / h )
    local rt = getSkyRT( w, h )
    skyView.origin = skyOrigin
    skyView.angles = camAngle
    skyView.w, skyView.h = w, h
    skyView.fov = fov
    skyView.aspectratio = effAspect

    -- skyOrigin can land just inside the skybox's own geometry (the miniature buildings/ground sit
    -- right where it falls). The 3D scenery still renders fine from there, but the engine skips the
    -- skybox's 2D sky and leaves it black behind the scenery - flag it so the fill hook paints the
    -- 2D sky back in during the render below. (Don't just bail to the 2D cube; that loses the
    -- skyline for a thin band as an exit camera grazes the skybox surface.)
    wp.renderingSkyInSolid = bit.band( util.PointContents( skyOrigin ), CONTENTS_SOLID ) ~= 0
    wp.renderingSkyOrigin = skyOrigin

    -- A buried exit camera sits inside the wall/foliage the portal is set into, so the skybox would
    -- otherwise render that geometry between the camera and the opening (the "giant leaf" over the
    -- portal). Clip it the same way the exit world view does - at the portal plane - so only what's
    -- in front of the opening (the skyline) survives. The plane is the exit plane scaled into skybox
    -- space: same normal (scale doesn't rotate it), distance through the scaled point on it.
    local clip = exitPos and exitForward
    local oldClip
    if clip then
        local d = exitForward:Dot( exitPos ) * invScale + exitForward:Dot( sky.origin )
        oldClip = render.EnableClipping( true )
        render.PushCustomClipPlane( exitForward, d )
    end

    wp.renderingSky = true
    render.PushRenderTarget( rt )
        render.Clear( 0, 0, 0, 255, true, true )
        render.RealRenderView( skyView )
    render.PopRenderTarget()
    wp.renderingSky = false

    if clip then
        render.PopCustomClipPlane()
        render.EnableClipping( oldClip )
    end
    -- The blit projects with the same fov/aspect the target was rendered with.
    wp.currentSkyFov = fov
    wp.currentSkyAspect = effAspect
    return rt
end

-- A manual world render picks up the main map's fog, not the skybox's. Match the engine's 3D
-- skybox (CSkyboxView::Enable3dSkyboxFog): the sky_camera's own linear fog, start/end scaled by
-- 1/scale. Gated so it only touches the pre-pass, never the eye or exit views.
hook.Add( "SetupWorldFog", "WorldPortals_VoidSky3D", function()
    if not wp.renderingSky then return end
    local sky = wp.sky3d
    if not sky then return end
    local fog = sky.fog
    if not fog then
        render.FogMode( MATERIAL_FOG_NONE )
        return true
    end
    local invScale = sky.scale > 0 and ( 1 / sky.scale ) or 1
    render.FogMode( MATERIAL_FOG_LINEAR )
    render.FogStart( fog.start * invScale )
    render.FogEnd( fog.stop * invScale )
    render.FogColor( fog.color.r, fog.color.g, fog.color.b )
    render.FogMaxDensity( fog.maxdensity )
    return true
end )

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

    -- Priority-order only the top level (see getSortedPortals); nested levels keep raw order.
    local sortedPortals, portalCount
    if depth == 1 then
        local pf = plyAngle:Forward()
        sortedPortals, portalCount = getSortedPortals( portals, plyOrigin.x, plyOrigin.y, plyOrigin.z, pf.x, pf.y, pf.z )
    else
        sortedPortals, portalCount = portals, #portals
    end
    for idx = 1, portalCount do
        local portal = sortedPortals[idx]

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
                    wp.ReleasePoly(poly); poly = nil
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
                        wp.ReleasePoly(poly); poly = nil
                        wp.ReleasePoly(cumulativePoly); cumulativePoly = nil
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

                    -- Out-of-bounds exit: pre-render the 3D skybox now, while the sky isn't
                    -- drawing yet (so the void hook can't fire), for that hook to blit as the
                    -- far-plane backdrop during the exit render below.
                    if depth <= VOIDSKY_3D_DEPTH
                        and bit.band( util.PointContents( camOrigin ), CONTENTS_SOLID ) ~= 0 then
                        wp.currentSkyRT = renderVoidSky3D( camOrigin, camAngle, width, height, fov, aspect, exit_pos, exit_forward )
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
                    wp.currentSkyRT = nil

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
            wp.ReleasePoly(poly)
            if cumulativePoly and cumulativePoly ~= poly then
                wp.ReleasePoly(cumulativePoly)
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
    -- The mono main view is rendered natively by the engine, not through WorldPortals_RenderView,
    -- so these are otherwise unset for mono. Match what renderportals renders the RT with, so
    -- cl_init.lua's opening fill projects through the same camera.
    wp.vieworigin = plyOrigin
    wp.viewangle = plyAngle
    wp.viewfov = fov
    wp.renderportals(plyOrigin, plyAngle, ScrW(), ScrH(), fov)
    -- Debug overlay: render the reconstruction here, at frame start, so its full-scene pre-pass
    -- can't corrupt the main view's depth/state (a mid-frame render did - blanked the viewmodel
    -- and dropped geometry). The WorldPortals_VoidSkyDebug hook then only blits this result.
    if dbgVoidSky:GetBool() and wp.sky3d then
        wp.overlaySkyRT = renderVoidSky3D( plyOrigin, plyAngle, ScrW(), ScrH(), fov, ScrW() / ScrH() )
    else
        wp.overlaySkyRT = nil
    end
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

-- The exit-view clip plane would otherwise slice the 3D skybox (the engine draws it small-scale
-- near the sky_camera), so drop clipping for the skybox draw only. Water reflections of the 3D
-- skybox can be missing at certain positions / angles due to an engine bug:
-- https://github.com/Facepunch/garrysmod-issues/issues/6536
local skyClipSaved
hook.Add( "PreDrawSkyBox", "WorldPortals_SkyClip", function()
    if wp.drawing then skyClipSaved = render.EnableClipping( false ) end
end )
hook.Add( "PostDrawSkyBox", "WorldPortals_SkyClip", function()
    if wp.drawing and skyClipSaved ~= nil then
        render.EnableClipping( skyClipSaved )
        skyClipSaved = nil
    end
end )

-- Draw the 2D skybox ourselves when the exit camera sits in solid: the engine skips its own sky
-- pass and clears to black there, so the sky would otherwise be missing through the portal.
-- Each face: suffix, the direction from the camera to that face, and the quad's CCW rotation.
local SKY_FACE_DEFS = {
    { "bk", Vector(0, 1, 0),  180 }, { "ft", Vector(0, -1, 0), 180 },
    { "lf", Vector(-1, 0, 0), 180 }, { "rt", Vector(1, 0, 0),  180 },
    { "up", Vector(0, 0, 1),    0 }, { "dn", Vector(0, 0, -1),   0 },
}
-- The engine crops ~1 texel off each sky-face edge to hide the seams between faces; match it in UV
-- space (510 of 512, scaled about the centre) so it holds whatever shape the texture is.
local VOIDSKY_INSET = 510 / 512
local skyFaces, skyName, skyCvar
local function buildSkyFaces()
    skyCvar = skyCvar or GetConVar("sv_skyname")
    local name = skyCvar:GetString():lower()
    if name == skyName and skyFaces then return end
    skyName = name
    skyFaces = {}
    for _, d in ipairs(SKY_FACE_DEFS) do
        local path = "skybox/" .. name .. d[1]
        local skyMat = Material(path)
        local dir = d[2] -- the quad faces back at the camera, so its normal is the opposite direction
        if skyMat:GetShader() == "g_sky" then
            -- A procedural GMod sky (gm_construct's "painted") shades a gradient + clouds in its own
            -- shader with no face textures, so draw the engine material straight onto the quad as-is.
            skyFaces[#skyFaces + 1] = { mat = skyMat, dir = dir, normal = -dir, rot = 0 }
        else
            -- Use the texture the engine's sky material resolves to, not the path itself: an HDR sky
            -- points $basetexture at a separate LDR texture, so loading the path raw samples HDR and
            -- washes the colours out.
            local tex = skyMat:GetTexture("$basetexture")
            local w, h = tex and tex:Width() or 1, tex and tex:Height() or 1
            -- A short side texture (e.g. 512x256) is drawn at its real shape, not stretched to fill the
            -- square face: scale it down, sit it against the top, and the texture's clamp smears the last
            -- row down to the floor - exactly what the engine does.
            local tf
            if w ~= h then
                tf = "center 0.5 0 scale " .. VOIDSKY_INSET .. " " .. (w / h * VOIDSKY_INSET) ..
                    " rotate 0 translate 0 " .. (1 - VOIDSKY_INSET)
            else
                tf = "center 0.5 0.5 scale " .. VOIDSKY_INSET .. " " .. VOIDSKY_INSET .. " rotate 0 translate 0 0"
            end
            local mat = CreateMaterial("wp_voidsky_" .. name .. "_" .. d[1], "UnlitGeneric", {
                ["$basetexturetransform"] = tf,
                ["$nofog"] = "1",
                ["$nocull"] = "1",
            })
            if tex then mat:SetTexture("$basetexture", tex) end
            skyFaces[#skyFaces + 1] = { mat = mat, dir = dir, normal = -dir, rot = d[3] }
        end
    end
end

-- Draw the sky cube centred on `origin`, returning the face distance. The sky is six flat quads whose
-- corners reach further out than their faces, so keep the cube inside the far clip plane (half the far
-- distance leaves margin) or the engine slices the corners off; then pin its depth to the far plane so
-- any real geometry, near or far, still draws in front.
local function drawSkyCube( origin )
    buildSkyFaces()
    local vs = render.GetViewSetup()
    local dist = ( vs and vs.zfar or 28000 ) * 0.5
    local size = 2 * dist
    render.OverrideDepthEnable( true, false ) -- depth-test on, write off
    render.DepthRange( 0.99999, 1 )
    render.SuppressEngineLighting( true )
    for _, f in ipairs( skyFaces ) do
        render.SetMaterial( f.mat )
        render.DrawQuadEasy( origin + f.dir * dist, f.normal, size, size, color_white, f.rot )
    end
    render.SuppressEngineLighting( false )
    render.DepthRange( 0, 1 )
    render.OverrideDepthEnable( false, false )
    return dist
end

local skyBlitMat = CreateMaterial( "wp_voidsky3d_blit", "UnlitGeneric", {
    ["$nofog"] = "1",
    ["$nocull"] = "1",
} )
-- Paint the pre-rendered 3D-sky render target across the view as a backdrop. A screen quad
-- ignores depth and would paint over the world, so project the target onto a quad out at the far
-- plane (depth-test on, write off) so real geometry still draws in front. The quad is sized to
-- the view frustum and screen-mapped, matching the fov/aspect the target was rendered with.
local function drawSkyBlit( rt )
    skyBlitMat:SetTexture( "$basetexture", rt )
    local origin = wp.vieworigin or EyePos()
    local ang = wp.viewangle or EyeAngles()
    local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
    local fov = wp.currentSkyFov or wp.viewfov or 90
    local aspect = wp.currentSkyAspect or ( ( wp.viewwidth or ScrW() ) / ( wp.viewheight or ScrH() ) )
    local vs = render.GetViewSetup()
    local d = ( vs and vs.zfar or 28000 ) * 0.5
    local hw = d * math.tan( math.rad( fov ) * 0.5 )
    local hh = hw / aspect
    local c = origin + fwd * d
    local tl, tr = c - right * hw + up * hh, c + right * hw + up * hh
    local br, bl = c + right * hw - up * hh, c - right * hw - up * hh
    -- The exit view's clip plane would slice this far quad when looking oblique; the backdrop
    -- never needs it (the opening composite confines it), so disable clipping around it.
    local oldClip = render.EnableClipping( false )
    render.OverrideDepthEnable( true, false )
    render.DepthRange( 0.99999, 1 )
    render.SetMaterial( skyBlitMat )
    mesh.Begin( MATERIAL_QUADS, 1 )
        mesh.Position( tl ); mesh.TexCoord( 0, 0, 0 ); mesh.AdvanceVertex()
        mesh.Position( tr ); mesh.TexCoord( 0, 1, 0 ); mesh.AdvanceVertex()
        mesh.Position( br ); mesh.TexCoord( 0, 1, 1 ); mesh.AdvanceVertex()
        mesh.Position( bl ); mesh.TexCoord( 0, 0, 1 ); mesh.AdvanceVertex()
    mesh.End()
    render.DepthRange( 0, 1 )
    render.OverrideDepthEnable( false, false )
    render.EnableClipping( oldClip )
end

-- During the 3D pre-pass, if skyOrigin sits inside the skybox geometry the engine skips the
-- skybox's own 2D sky (black behind the scenery) - paint it back in with the 2D cube, depth-tested
-- so the 3D scenery still occludes it. Fires only inside the pre-pass (wp.renderingSky).
hook.Add( "PostDrawOpaqueRenderables", "WorldPortals_VoidSkyFill", function( bDepth, bSky )
    if not wp.renderingSky or not wp.renderingSkyInSolid or bDepth or bSky then return end
    local origin = wp.renderingSkyOrigin
    if not origin then return end
    drawSkyCube( origin )
end )

hook.Add( "PostDrawOpaqueRenderables", "WorldPortals_VoidSky", function( bDepth, bSky )
    if not wp.drawing or bDepth or bSky then return end
    local origin = wp.vieworigin
    if not origin then return end
    if bit.band( util.PointContents( origin ), CONTENTS_SOLID ) == 0 then return end
    -- The 3D pre-pass RT (both skybox scenery and the 2D sky behind it) when we have one;
    -- otherwise the standalone 2D cube.
    if wp.currentSkyRT then
        drawSkyBlit( wp.currentSkyRT )
    else
        drawSkyCube( origin )
    end
end )

-- Dev aid: worldportals_debug_voidsky 1 paints the reconstruction over the normal view anywhere
-- (no portal needed) to compare it against the engine's real sky - the 3D skybox where the map
-- has one (pre-rendered at frame start in RenderScene), else the 2D cube; 2 also outlines the
-- cube faces so the seams between them show.
hook.Add( "PostDrawTranslucentRenderables", "WorldPortals_VoidSkyDebug", function( bDepth, bSky )
    if wp.renderingSky then return end -- don't draw inside the frame-start pre-pass
    local mode = dbgVoidSky:GetInt()
    if mode == 0 or wp.drawing or bDepth or bSky then return end
    if wp.overlaySkyRT then
        drawSkyBlit( wp.overlaySkyRT )
        return
    end
    local origin = wp.vieworigin or EyePos()
    local dist = drawSkyCube( origin )
    if mode >= 2 then -- outline the 12 cube edges so the face seams are visible
        local function C( x, y, z ) return origin + Vector( x * dist, y * dist, z * dist ) end
        local edges = {
            { C(-1,-1,-1), C(1,-1,-1) }, { C(-1,-1,1), C(1,-1,1) }, { C(-1,1,-1), C(1,1,-1) }, { C(-1,1,1), C(1,1,1) },
            { C(-1,-1,-1), C(-1,1,-1) }, { C(-1,-1,1), C(-1,1,1) }, { C(1,-1,-1), C(1,1,-1) }, { C(1,-1,1), C(1,1,1) },
            { C(-1,-1,-1), C(-1,-1,1) }, { C(-1,1,-1), C(-1,1,1) }, { C(1,-1,-1), C(1,-1,1) }, { C(1,1,-1), C(1,1,1) },
        }
        render.SetColorMaterialIgnoreZ()
        for _, e in ipairs( edges ) do render.DrawLine( e[1], e[2], Color( 255, 0, 0 ), false ) end
    end
end )
