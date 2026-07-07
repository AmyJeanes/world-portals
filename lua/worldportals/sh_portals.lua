-- Portals

---@type linked_portal_door[]
wp.portals = wp.portals or {}

local registered = {}

local function rebuild()
    local list = {}
    for portal in pairs(registered) do
        if IsValid(portal) then list[#list + 1] = portal end
    end
    wp.portals = list
end

---@api
---@param portal linked_portal_door
function wp.RegisterPortal(portal)
    if registered[portal] then return end
    registered[portal] = true
    rebuild()
end

---@api
---@param portal Entity
function wp.UnregisterPortal(portal)
    if not registered[portal] then return end
    registered[portal] = nil
    rebuild()
end

hook.Add("EntityRemoved", "WorldPortals_Portals", function(ent)
    if registered[ent] then wp.UnregisterPortal(ent) end
end)

for _, portal in ipairs(ents.FindByClass("linked_portal_door")) do
    registered[portal] = true
end
rebuild()
