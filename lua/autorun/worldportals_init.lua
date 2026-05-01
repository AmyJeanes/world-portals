
--because worldportals is too long
wp = {}

-- Load required files
include( "worldportals/sh_utils.lua" )
include( "worldportals/sh_teleport.lua" )
include( "worldportals/sh_falseworlds.lua" )

if SERVER then

    include( "worldportals/sv_render.lua" )
    include( "worldportals/sv_teleport.lua" )

    AddCSLuaFile( "worldportals/sh_utils.lua" )
    AddCSLuaFile( "worldportals/cl_render.lua" )
    AddCSLuaFile( "worldportals/cl_teleport.lua" )
    AddCSLuaFile( "worldportals/sh_teleport.lua" )
    AddCSLuaFile( "worldportals/sh_falseworlds.lua" )

else

    include( "worldportals/cl_render.lua" )
    include( "worldportals/cl_teleport.lua" )

end
