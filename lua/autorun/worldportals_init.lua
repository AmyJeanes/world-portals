
--because worldportals is too long
wp = wp or {}

function wp.LoadFolder( folder, noprefix )
    local files = file.Find( folder .. "/*.lua", "LUA" )
    for _, name in ipairs( files ) do
        local path = folder .. "/" .. name
        if noprefix then
            if SERVER then
                AddCSLuaFile( path )
            end
            include( path )
        else
            local sep = string.find( name, "_" )
            local prefix = sep and string.sub( name, 1, sep - 1 ) or ""
            if SERVER then
                if prefix == "sv" or prefix == "sh" then
                    include( path )
                end
                if prefix == "sh" or prefix == "cl" then
                    AddCSLuaFile( path )
                end
            else
                if prefix == "sh" or prefix == "cl" then
                    include( path )
                end
            end
        end
    end
end

wp.LoadFolder( "worldportals" )
wp.LoadFolder( "worldportals/falseworlds", true )
