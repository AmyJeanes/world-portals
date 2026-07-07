-- False worlds

---@type table<string, worldportals_false_world>
wp.falseworlds = wp.falseworlds or {}
-- Client-only cache of long-lived ClientsideModel parts keyed by false-world id.
-- Kept separate from wp.falseworlds so re-registering doesn't have to fight table.Copy.
wp.falseworldscache = wp.falseworldscache or {}

local VECTOR_ORIGIN = Vector()
local VECTOR_UP = Vector( 0, 0, 1 )
local ANGLE_ZERO = Angle()
local ANGLE_YAW_180 = Angle( 0, 180, 0 )

---@api
---@param T worldportals_false_world
function wp.addfalseworld( T )
    if not T.id then
        error( "wp.addfalseworld: missing T.id" )
    end
    if CLIENT then
        local cache = wp.falseworldscache[T.id]
        if cache then
            if IsValid( cache.skybox ) then cache.skybox:Remove() end
            for _, ent in pairs( cache.parts or {} ) do
                if IsValid( ent ) then ent:Remove() end
            end
            wp.falseworldscache[T.id] = nil
        end
    end
    wp.falseworlds[T.id] = table.Copy( T )
end

if SERVER then return end

---@param id string
local function ensureCache( id )
    local cache = wp.falseworldscache[id]
    if cache then return cache end
    cache = { parts = {} }
    wp.falseworldscache[id] = cache
    return cache
end

---@class worldportals_false_world_part
---@field model string
---@field rendergroup integer?
---@field color Vector?
---@field pos Vector?
---@field ang Angle?
---@field scale Vector?

---@class worldportals_false_world
---@field id string
---@field pos Vector?
---@field ang Angle?
---@field baselight Vector?
---@field skybox worldportals_false_world_part?
---@field models table<string, worldportals_false_world_part>
---@field lights table[]?

-- Apply state that's static for the lifetime of the cached entity.
---@param rawpart worldportals_false_world_part
---@param ent CSEnt
local function setupPart( rawpart, ent )
    ent:SetNoDraw( true )
    ent:SetAngles( rawpart.ang or ANGLE_ZERO )
    if rawpart.scale then
        local mat = Matrix()
        mat:Scale( rawpart.scale )
        ent:EnableMatrix( "RenderMultiply", mat )
    end
end

---@param angle Angle
---@param portal linked_portal_door
---@param falseWorldAng Angle
local function TransformFalseWorldAngle( angle, portal, falseWorldAng )
    local l_angle = portal:WorldToLocalAngles( angle )
    l_angle:RotateAroundAxis( VECTOR_UP, 180 )
    local _, w_angle = LocalToWorld( VECTOR_ORIGIN, l_angle, VECTOR_ORIGIN, falseWorldAng )

    return w_angle
end

---@param pos Vector
---@param portal linked_portal_door
---@param falseWorldPos Vector
---@param falseWorldAng Angle
local function TransformFalseWorldPos( pos, portal, falseWorldPos, falseWorldAng )
    local l_pos = portal:WorldToLocal( pos )
    l_pos:Rotate( ANGLE_YAW_180 )
    local w_pos = LocalToWorld( l_pos, ANGLE_ZERO, falseWorldPos, falseWorldAng )

    return w_pos
end

---@param portal linked_portal_door
---@param falseWorldPos Vector
---@param falseWorldAng Angle
local function GetFalseWorldExitPose( portal, falseWorldPos, falseWorldAng )
    local exitPos = falseWorldPos
    local exitAng = falseWorldAng

    local posOffset = portal:GetExitPosOffset()
    if posOffset.x ~= 0 or posOffset.y ~= 0 or posOffset.z ~= 0 then
        local rotatedOffset = Vector( posOffset.x, posOffset.y, posOffset.z )
        rotatedOffset:Rotate( falseWorldAng )
        exitPos = falseWorldPos + rotatedOffset
    end

    local angOffset = portal:GetExitAngOffset()
    if angOffset.p ~= 0 or angOffset.y ~= 0 or angOffset.r ~= 0 then
        exitAng = falseWorldAng + angOffset
    end

    return exitPos, exitAng
end

---@param portal linked_portal_door
---@param plyOrigin Vector
---@param plyAngle Angle
---@param width number
---@param height number
---@param fov number
function wp.createfalseworld( portal, plyOrigin, plyAngle, width, height, fov )
    local fwname = portal:GetFalseWorld()
    local falseworld = wp.falseworlds[fwname]

    if not falseworld then
        ErrorNoHalt( "wp.createfalseworld: no registered false world '" .. tostring( fwname ) .. "'\n" )
        return
    end

    local cache = ensureCache( fwname )

    local falseWorldPos = falseworld.pos or VECTOR_ORIGIN
    local falseWorldAng = falseworld.ang or ANGLE_ZERO
    local baselight = falseworld.baselight or VECTOR_ORIGIN
    local exitPos, exitAng = GetFalseWorldExitPose( portal, falseWorldPos, falseWorldAng )
    local camOrigin = TransformFalseWorldPos( plyOrigin, portal, exitPos, exitAng )
    local camAngle = TransformFalseWorldAngle( plyAngle, portal, exitAng )

    cam.Start3D( camOrigin, camAngle, fov, 0, 0, width, height )
        local exit_forward = exitAng:Forward()

        local oldEC = render.EnableClipping( true )

        if falseworld.skybox then
            local rawpart = falseworld.skybox
            local part = cache.skybox
            if not IsValid( part ) then
                part = ClientsideModel( rawpart.model, rawpart.rendergroup )
                if IsValid( part ) then
                    setupPart( rawpart, part )
                    cache.skybox = part
                end
            end
            if IsValid( part ) then
                part:SetPos( camOrigin )
                local color = rawpart.color
                if color then
                    render.SetColorModulation( color.x, color.y, color.z )
                else
                    render.SetColorModulation( 1, 1, 1 )
                end
                render.OverrideDepthEnable( true, false )
                part:DrawModel()
                render.OverrideDepthEnable( false, false )
            end
        end

        render.PushCustomClipPlane( exit_forward, exit_forward:Dot( exitPos - exit_forward * 0.5 ) )
            for key, rawpart in pairs( falseworld.models ) do
                local part = cache.parts[key]
                if not IsValid( part ) then
                    part = ClientsideModel( rawpart.model, rawpart.rendergroup )
                    if IsValid( part ) then
                        setupPart( rawpart, part )
                        part:SetPos( rawpart.pos or VECTOR_ORIGIN )
                        cache.parts[key] = part
                    end
                end
                if IsValid( part ) then
                    ---@cast rawpart worldportals_false_world_part
                    local color = rawpart.color
                    if color then
                        render.SetColorModulation( color.x, color.y, color.z )
                    else
                        render.SetColorModulation( 1, 1, 1 )
                    end
                    render.ResetModelLighting( baselight.x, baselight.y, baselight.z )
                    render.SetLocalModelLights( falseworld.lights )
                    part:DrawModel()
                end
            end
        render.PopCustomClipPlane()

        render.EnableClipping( oldEC )
    cam.End3D()
end

---@param texture ITexture
---@param portal linked_portal_door
---@param plyOrigin Vector
---@param plyAngle Angle
---@param width number
---@param height number
---@param fov number
---@param depth number
function wp.renderfalseworld( texture, portal, plyOrigin, plyAngle, width, height, fov, depth )
    hook.Call( "wp-prerender", GAMEMODE, portal, nil, plyOrigin, depth )
    render.PushRenderTarget( texture )
        local oldW, oldH = ScrW(), ScrH()
        render.Clear( 0, 0, 0, 0, true, true )
        render.SetViewPort( 0, 0, ScrW(), ScrH() )

        local oldFog = render.GetFogMode() --[[@as MATERIAL_FOG]]
        render.SuppressEngineLighting( true )
        render.FogMode( MATERIAL_FOG_NONE )

        wp.createfalseworld( portal, plyOrigin, plyAngle, width, height, fov )

        render.OverrideDepthEnable( false, false )
        render.FogMode( oldFog )
        render.SuppressEngineLighting( false )

        render.SetViewPort( 0, 0, oldW, oldH )
    render.PopRenderTarget()
    hook.Call( "wp-postrender", GAMEMODE, portal, nil, plyOrigin, depth )
end
