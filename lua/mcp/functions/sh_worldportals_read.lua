-- MCP world-portals read functions

MCP.wp = MCP.wp or {}
local wp_ = MCP.wp

MCP:AddFunction({
    id = "wp_portal_find",
    description = "List world-portals (linked_portal_door) with a lean state row each -- the survey read, drill into one with wp_portal_state. Each row: index, pos, open, enable_teleport, width, height, linked (has a valid exit portal), exit_index, mutual (a working pair), has_custom_model, has_false_world, and distance from the sort centre. By default lists every portal, sorted nearest-first to the host player. Filter with `point` [x,y,z] or `around` (an entindex) as the centre plus `radius` (units); `linked` (true = only paired, false = only unlinked); `false_world` (true/false = has/hasn't a false-world, or a string = that false-world name); `parent` (only portals parented to that entindex) or `parent_class` (only those whose parent is that class, e.g. \"gmod_tardis\"). `fields` is an opt-in array to enrich each row (angles, forward, exit_pos_offset, exit_ang_offset, transparency, disappear_dist, custom_model, false_world, parent) -- a multi-portal facing/attach audit in one call instead of N wp_portal_state calls. `limit` caps the list (default 50, max 200). The _cl mirror sees the same networked portals.",
    schema = {
        type = "object",
        properties = {
            point = { type = "array", items = { type = "number" }, description = "Sort/filter centre [x,y,z]. Defaults to the host player's position." },
            around = { type = "integer", description = "Use this entity's position as the centre instead of `point`." },
            radius = { type = "number", description = "Only include portals within this many units of the centre." },
            linked = { type = "boolean", description = "Filter by link state: true = only portals with a valid exit, false = only unlinked." },
            false_world = { description = "Filter by false-world: true = only portals with one, false = only without, or a string = only that false-world name." },
            parent = { type = "integer", description = "Only portals parented to this entindex." },
            parent_class = { type = "string", description = "Only portals whose parent is this class (e.g. \"gmod_tardis\")." },
            fields = { type = "array", items = { type = "string" }, description = "Extra per-row fields: angles, forward, exit_pos_offset, exit_ang_offset, transparency, disappear_dist, custom_model, false_world, parent." },
            limit = { type = "integer", minimum = 1, maximum = 200, description = "Max rows (default 50)." },
        },
        required = {},
    },
    handler = function(args)
        args = args or {}

        local center, centerSource
        if args.point ~= nil then
            local c, e = wp_.ParseTriple(args.point, "point")
            if not c then return { ok = false, error = e } end
            center, centerSource = Vector(c[1], c[2], c[3]), "point"
        elseif args.around ~= nil then
            if not isnumber(args.around) then return { ok = false, error = "`around` must be an entindex" } end
            local e = Entity(args.around)
            if not IsValid(e) then return { ok = false, error = "no entity at entindex " .. args.around } end
            center, centerSource = e:GetPos(), "entity " .. args.around
        else
            local ply = wp_.FirstPlayer()
            if IsValid(ply) then center, centerSource = ply:GetPos(), "host" end
        end

        local radius = isnumber(args.radius) and args.radius or nil
        local linkedFilter = args.linked
        local fwFilter = args.false_world
        local parentFilter = isnumber(args.parent) and args.parent or nil
        local parentClass = isstring(args.parent_class) and args.parent_class or nil
        local fields = istable(args.fields) and args.fields or nil

        local rows = {}
        for _, p in ipairs(wp_.AllPortals()) do
            local include = true
            if linkedFilter ~= nil and (wp_.IsPortal(p:GetExit()) ~= (linkedFilter == true)) then include = false end
            if include and fwFilter ~= nil then
                -- A typeless schema arg can arrive as a string ("true"/"false") or a real bool, so
                -- normalise the has/hasn't cases and treat any other string as a false-world name.
                local fw = p:GetFalseWorld()
                local has = fw ~= ""
                if fwFilter == true or fwFilter == "true" then
                    if not has then include = false end
                elseif fwFilter == false or fwFilter == "false" then
                    if has then include = false end
                elseif isstring(fwFilter) then
                    if fw ~= fwFilter then include = false end
                end
            end
            if include and (parentFilter or parentClass) then
                local par = p:GetParent()
                if not IsValid(par) then include = false
                elseif parentFilter and par:EntIndex() ~= parentFilter then include = false
                elseif parentClass and par:GetClass() ~= parentClass then include = false end
            end
            if include and radius and center and p:GetPos():Distance(center) > radius then include = false end
            if include then rows[#rows + 1] = wp_.PortalRow(p, center, fields) end
        end

        if center then
            table.sort(rows, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
        end

        local total = #rows
        local limit = math.Clamp(math.floor(tonumber(args.limit) or 50), 1, 200)
        local truncated = total > limit
        if truncated then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = rows[i] end
            rows = trimmed
        end

        return {
            ok = true,
            realm = MCP.util.RealmName(),
            portals = rows,
            total = total,
            returned = #rows,
            truncated = truncated,
            center = center,
            center_source = centerSource,
        }
    end,
})

MCP:AddFunction({
    id = "wp_portal_state",
    description = "Full structured snapshot of one world-portal (linked_portal_door) by `entindex`. Returns identity (entindex, creation_id, owner), pos/angles, a `size` block {width, height, thickness}, a `flags` block {open, enable_teleport, inverted}, a `render` block {transparency, disappear_dist, zfar, custom_model + its pos/ang offsets, false_world, opening_bounds (the portal's own opening slab min/max) + opening_quad_count}, a `link` block {linked, exit (index/pos/open/enable_teleport), mutual (a working pair), exit_pos_offset, exit_ang_offset, partner_name}, a `parent` block when the portal is parented (attach index+class, the parent's velocity/angular_velocity, and the portal's local_pos/local_angles within it -- e.g. a portal mounted on a gmod_tardis), and (server realm only) a `frame` block describing the invisible linked_portal_frame collision companion {index, pos_drift from the portal, phys_pos_drift (shadow hull vs entity), movetype, collision_group, obb bounds, pending_shadow, frame_border/min_depth, and parent_nocollides -- the frame<->parent no-collide validity, which a SetThickness resize can orphan}. Pass `approach_standoff` (units) to also get an `approach` block {point, yaw, angles} -- the walk-up pose to feed player_walk to cross the portal. The _cl mirror omits the server-only frame block.",
    schema = {
        type = "object",
        properties = {
            entindex = { type = "integer", description = "The linked_portal_door entindex." },
            approach_standoff = { type = "number", description = "If set (units, e.g. 80), include an `approach` block: where to stand in front of the portal and the facing to walk through it (for player_walk)." },
        },
        required = { "entindex" },
    },
    handler = function(args)
        local p, err = wp_.ResolvePortal(args.entindex)
        if not p then return { ok = false, error = err } end
        local out = wp_.PortalState(p, { approach_standoff = tonumber(args.approach_standoff) })
        out.realm = MCP.util.RealmName()
        return out
    end,
})
