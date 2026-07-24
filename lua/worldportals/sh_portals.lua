-- Portals

---@class wp
---@field portals linked_portal_door[] live portals, rebuilt fresh on change

wp.portals = wp.portals or {}

---@type table<linked_portal_door, boolean>
local registered = {}

local function rebuild()
    -- glua_ls 1.1.1: infers `{ T }` from the appends, then fails to unify it with `T[]`.
    ---@diagnostic disable-next-line: assign-type-mismatch
    ---@type linked_portal_door[]
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

-- Clientside ENTITY:Initialize only fires on a portal's first create; during the connect burst the client re-creates it, so re-register here.
hook.Add("NetworkEntityCreated", "WorldPortals_Portals", function(ent)
    if IsValid(ent) and ent:GetClass() == "linked_portal_door" then
        wp.RegisterPortal(ent)
    end
end)

for _, portal in ipairs(ents.FindByClass("linked_portal_door")) do
    registered[portal] = true
end
rebuild()
