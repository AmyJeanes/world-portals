-- Void sky

-- When a portal exit camera lands in solid (out of bounds), the engine clears black and skips the
-- sky pass - so the sky is missing through the portal. We redraw it: a 2D skybox cube (six flat
-- quads of the map's sky textures) for any out-of-bounds view, plus, on maps with a 3D skybox, the
-- sky_camera's parallax scenery rendered to an RT by wp.RenderVoidSky3D and drawn as the far-plane
-- backdrop. cl_render's renderportals triggers the 3D pre-pass; the composite hooks here paint it.

-- Dev aid (WorldPortals_VoidSkyDebug below): paints the reconstruction over the normal view anywhere.
local dbgVoidSky = CreateClientConVar( "worldportals_debug_voidsky", "0", true, false )

-- GMod doesn't expose the TEXTUREFLAGS enum to Lua, so name the few we use here.
local TEXTUREFLAGS_TRILINEAR = 2
local TEXTUREFLAGS_CLAMPS = 4
local TEXTUREFLAGS_CLAMPT = 8
local TEXTUREFLAGS_NOMIP = 256

local skyRTs = {}
local function getSkyRT( w, h )
    local tag = math.floor( w ) .. "x" .. math.floor( h )
    local rt = skyRTs[tag]
    if not rt then
        -- An off-screen canvas to render the sky into, with its own depth buffer. Rendering the sky
        -- wipes depth first (a fresh scene); if it shared the main view's buffer that wipe would blank
        -- the real scene's depth too, and the far-away backdrop would then paint over everything. One
        -- cached RT per screen size - they can't be resized, and reusing a name across sizes leaks.
        rt = GetRenderTargetEx( "wp_voidsky3d_" .. tag, w, h, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_SEPARATE,
            bit.bor( TEXTUREFLAGS_TRILINEAR, TEXTUREFLAGS_CLAMPS, TEXTUREFLAGS_CLAMPT, TEXTUREFLAGS_NOMIP ),
            0, IMAGE_FORMAT_RGBA8888 )
        skyRTs[tag] = rt
    end
    return rt
end

-- zfar is the engine's longest view distance (MAX_TRACE_LENGTH) so the whole miniature scene fits.
-- viewid 1 (VIEW_3DSKY) matches the portal renders and dodges a halo/visibility glitch viewid 0 brings back.
local skyView = {
    x = 0, y = 0,
    drawviewmodel = false, drawhud = false, drawmonitors = false,
    dopostprocess = false, bloomtone = false,
    znear = 2, zfar = 56756, viewid = 1,
}

function wp.RenderVoidSky3D( camOrigin, camAngle, w, h, fov, aspect, exitPos, exitForward )
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

    -- skyOrigin is our camera inside the miniature skybox, and it can land buried in that world's own
    -- ground or buildings. The scenery still draws, but the engine won't render the sky from inside
    -- solid, so the backdrop goes black behind it - flag that so the fill hook repaints the 2D sky.
    -- (Falling back to the flat 2D cube instead would drop the parallax skyline for the thin band
    -- where skyOrigin only grazes the surface.)
    wp.renderingSkyInSolid = bit.band( util.PointContents( skyOrigin ), CONTENTS_SOLID ) ~= 0
    wp.renderingSkyOrigin = skyOrigin

    -- Clip off any geometry between the camera and the portal opening, just like a normal portal's exit
    -- view does: the exit camera can sit buried inside whatever the portal is set into, and we only want
    -- the skyline in front of the opening. The plane is the exit plane (exitPos/exitForward, world space)
    -- shrunk into skybox space - same facing direction (scaling doesn't rotate it), positioned at the
    -- scaled-down opening. The debug overlay has no portal, so it passes neither and skips this.
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
    -- The backdrop is drawn with the same fov/aspect the target was rendered with.
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

-- Debug overlay (worldportals_debug_voidsky): render the reconstruction here, before the main view
-- draws, because rendering a whole scene mid-frame corrupts that view. The VoidSkyDebug hook below
-- just paints the result. Its own RenderScene hook; the in-portal pre-pass is driven from renderportals.
hook.Add( "RenderScene", "WorldPortals_VoidSkyOverlay", function( plyOrigin, plyAngle, fov )
    -- In VR vrmod renders the eyes itself, so this full-screen pass shows nothing - skip it.
    if vrmod and vrmod.IsPlayerInVR() then return end
    if dbgVoidSky:GetBool() and wp.sky3d then
        wp.overlaySkyRT = wp.RenderVoidSky3D( plyOrigin, plyAngle, ScrW(), ScrH(), fov, ScrW() / ScrH() )
    else
        wp.overlaySkyRT = nil
    end
end )

-- The six faces of the 2D skybox cube - the map's main sky. Each face: texture suffix, the direction
-- from the camera to it, and the quad's rotation in degrees.
local SKY_FACE_DEFS = {
    { "bk", Vector(0, 1, 0),  180 }, { "ft", Vector(0, -1, 0), 180 },
    { "lf", Vector(-1, 0, 0), 180 }, { "rt", Vector(1, 0, 0),  180 },
    { "up", Vector(0, 0, 1),    0 }, { "dn", Vector(0, 0, -1),   0 },
}
-- The engine crops ~1 texel off each sky-face edge to hide the seams between faces; we match that on
-- the texture itself (510 of 512, scaled about its centre) so it works whatever shape the texture is.
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

local skyBackdropMat = CreateMaterial( "wp_voidsky3d_backdrop", "UnlitGeneric", {
    ["$nofog"] = "1",
    ["$nocull"] = "1",
} )
-- Paint the pre-rendered 3D-sky target across the view as a backdrop. A full-screen quad ignores
-- depth and would paint over the world, so we put it on a quad way out at the far plane (depth-test
-- on, write off) so real geometry still draws in front. The quad's sized to fill the view and mapped
-- to the screen, matching the fov/aspect the target was rendered with.
local function drawSkyBackdrop( rt )
    skyBackdropMat:SetTexture( "$basetexture", rt )
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
    render.SetMaterial( skyBackdropMat )
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
        drawSkyBackdrop( wp.currentSkyRT )
    else
        drawSkyCube( origin )
    end
end )

-- Dev aid: worldportals_debug_voidsky 1 paints the reconstruction over the normal view anywhere
-- (no portal needed) to compare it against the engine's real sky - the 3D skybox where the map
-- has one (pre-rendered at frame start in the overlay hook above), else the 2D cube; 2 also
-- outlines the cube faces so the seams between them show.
hook.Add( "PostDrawTranslucentRenderables", "WorldPortals_VoidSkyDebug", function( bDepth, bSky )
    if wp.renderingSky then return end -- don't draw inside the frame-start pre-pass
    local mode = dbgVoidSky:GetInt()
    if mode == 0 or wp.drawing or bDepth or bSky then return end
    if wp.overlaySkyRT then
        drawSkyBackdrop( wp.overlaySkyRT )
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
