-- Portals

-- Maintained registry of every linked_portal_door, so the hot paths (the
-- predicted SetupMove scan, trace redirection, the render loop) iterate a cached
-- list instead of ents.FindByClass every tick/frame. Portals register from their
-- shared Initialize; EntityRemoved deregisters. Each change rebuilds wp.portals
-- as a fresh array (never mutated in place) so a reference held across iteration
-- stays stable even if a portal is removed mid-loop.
wp.portals = wp.portals or {}

local registered = {}

local function rebuild()
    local list = {}
    for portal in pairs(registered) do
        if IsValid(portal) then list[#list + 1] = portal end
    end
    wp.portals = list
end

function wp.RegisterPortal(portal)
    if registered[portal] then return end
    registered[portal] = true
    rebuild()
end

function wp.UnregisterPortal(portal)
    if not registered[portal] then return end
    registered[portal] = nil
    rebuild()
end

hook.Add("EntityRemoved", "WorldPortals_Portals", function(ent)
    if registered[ent] then wp.UnregisterPortal(ent) end
end)

-- Re-discover live portals when this file hot-reloads: their Initialize already
-- ran, so they'd never re-register and the list would be empty until a respawn.
for _, portal in ipairs(ents.FindByClass("linked_portal_door")) do
    registered[portal] = true
end
rebuild()
