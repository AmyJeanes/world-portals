-- Example world for testing and helping people learn how to make them.
local T = {
    ID = "example",
    origin = Vector( -230, 0, 0 ), -- origin point all positioning will be based on
    baselight = Vector( 0.2, 0.2, 0.2 ), -- base light level
    skybox = { -- use a model as a skybox, useful for space ceilings, though not required
        model = "models/hunter/misc/shell2x2.mdl",
        pos = Vector( 0, 0, 0 ),
        angle = Angle( 0, 0, 0 ),
    },
    models = {
        vending = {
            model = "models/props_interiors/VendingMachineSoda01a.mdl",
            pos = Vector( -180, 70, -3 ),
            angle = Angle( 0, 0, 0 ),
            color = Vector( 0, 1, 0 ),
        },
        tube = {
            model = "models/props_phx/construct/windows/window_curve360x2.mdl",
            pos = Vector( -180, -70, -50 ),
            angle = Angle( 0, 0, 0 ),
            scale = Vector( 0.5, 0.5, 1.7 ),
        },
        tower = {
            model = "models/props_phx/huge/tower.mdl",
            pos = Vector( 0, 0, -2015 ),
            angle = Angle( 0, 0, 0 ),
        },
    },
    lights = { -- These lights are fed in directly using the LocalLight structure
        { color = Vector( 1, 0, 0 ), pos = Vector( 0, 0, 20 ) },
        { color = Vector( 0, 0, 1 ), pos = Vector( 0, 200, 20 ) },
        { color = Vector( 0, 1, 0 ), pos = Vector( 0, -200, 20 ) },
    },
}

wp.addfalseworld( T )
