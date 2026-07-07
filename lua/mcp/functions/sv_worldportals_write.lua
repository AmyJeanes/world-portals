-- MCP world-portals write functions

MCP.wp = MCP.wp or {}
local wp_ = MCP.wp

MCP:AddCapability({
    id = "worldportals_control",
    description = "Allows MCP callers to create, link, modify, and remove world-portals (linked_portal_door entities).",
    default = false,
})

local PORTAL_CLASS = "linked_portal_door"
local MAX_SPECS = 100

-- Measure a custom model's render-bounds centre (for custom_model_center). Un-Spawned prop, so no
-- networking; precache first (server GetModelRenderBounds is nil for an unprecached model).
---@param model string
local function measureRenderCenter(model)
    util.PrecacheModel(model)
    local e = ents.Create("prop_dynamic")
    if not IsValid(e) then return nil end
    e:SetModel(model)
    local mn, mx = e:GetModelRenderBounds()
    e:Remove()
    if not (isvector(mn) and isvector(mx)) then return nil end
    return (mn + mx) * 0.5
end

-- Apply transform + size NetworkVars. `pos_delta` moves relative to the current pos (for bulk moves).
---@param p linked_portal_door
---@param args table schema args, validated per-field below
---@param applied string[]
local function applyTransformSize(p, args, applied)
    if args.pos ~= nil then
        local c, e = wp_.ParseTriple(args.pos, "pos")
        if not c then return e end
        p:SetPos(Vector(c[1], c[2], c[3])); applied[#applied + 1] = "pos"
    end
    if args.pos_delta ~= nil then
        local c, e = wp_.ParseTriple(args.pos_delta, "pos_delta")
        if not c then return e end
        p:SetPos(p:GetPos() + Vector(c[1], c[2], c[3])); applied[#applied + 1] = "pos_delta"
    end
    if args.angles ~= nil then
        local a, e = wp_.ParseTriple(args.angles, "angles")
        if not a then return e end
        p:SetAngles(Angle(a[1], a[2], a[3])); applied[#applied + 1] = "angles"
    end
    if args.width ~= nil then
        if not isnumber(args.width) then return "`width` must be a number" end
        p:SetWidth(math.max(0, math.floor(args.width))); applied[#applied + 1] = "width"
    end
    if args.height ~= nil then
        if not isnumber(args.height) then return "`height` must be a number" end
        p:SetHeight(math.max(0, math.floor(args.height))); applied[#applied + 1] = "height"
    end
    if args.thickness ~= nil then
        if not isnumber(args.thickness) then return "`thickness` must be a number" end
        p:SetThickness(math.max(0, math.floor(args.thickness))); applied[#applied + 1] = "thickness"
    end
    return nil
end

-- Apply flag + render NetworkVars (not the exit link -- that's wp_portal_link's job).
---@param p linked_portal_door
---@param args table schema args, validated per-field below
---@param applied string[]
local function applyRenderFlags(p, args, applied)
    if args.open ~= nil then p:SetOpen(args.open == true); applied[#applied + 1] = "open" end
    if args.enable_teleport ~= nil then p:SetEnableTeleport(args.enable_teleport == true); applied[#applied + 1] = "enable_teleport" end
    if args.inverted ~= nil then p:SetInverted(args.inverted == true); applied[#applied + 1] = "inverted" end
    if args.transparency ~= nil then
        if not isnumber(args.transparency) then return "`transparency` must be a number" end
        p:SetTransparency(math.Clamp(math.floor(args.transparency), 0, 255)); applied[#applied + 1] = "transparency"
    end
    if args.disappear_dist ~= nil then
        if not isnumber(args.disappear_dist) then return "`disappear_dist` must be a number" end
        p:SetDisappearDist(math.max(0, math.floor(args.disappear_dist))); applied[#applied + 1] = "disappear_dist"
    end
    if args.zfar ~= nil then
        if not isnumber(args.zfar) then return "`zfar` must be a number" end
        p:SetZFar(math.max(0, math.floor(args.zfar))); applied[#applied + 1] = "zfar"
    end
    if args.custom_model ~= nil then
        if not isstring(args.custom_model) then return "`custom_model` must be a string" end
        p:SetCustomModel(args.custom_model); applied[#applied + 1] = "custom_model"
    end
    if args.custom_model_pos_offset ~= nil then
        local c, e = wp_.ParseTriple(args.custom_model_pos_offset, "custom_model_pos_offset")
        if not c then return e end
        p:SetCustomModelPosOffset(Vector(c[1], c[2], c[3])); applied[#applied + 1] = "custom_model_pos_offset"
    end
    if args.custom_model_ang_offset ~= nil then
        local a, e = wp_.ParseTriple(args.custom_model_ang_offset, "custom_model_ang_offset")
        if not a then return e end
        p:SetCustomModelAngOffset(Angle(a[1], a[2], a[3])); applied[#applied + 1] = "custom_model_ang_offset"
    end
    if args.exit_pos_offset ~= nil then
        local c, e = wp_.ParseTriple(args.exit_pos_offset, "exit_pos_offset")
        if not c then return e end
        p:SetExitPosOffset(Vector(c[1], c[2], c[3])); applied[#applied + 1] = "exit_pos_offset"
    end
    if args.exit_ang_offset ~= nil then
        local a, e = wp_.ParseTriple(args.exit_ang_offset, "exit_ang_offset")
        if not a then return e end
        p:SetExitAngOffset(Angle(a[1], a[2], a[3])); applied[#applied + 1] = "exit_ang_offset"
    end
    if args.false_world ~= nil then
        if not isstring(args.false_world) then return "`false_world` must be a string" end
        p:SetFalseWorld(args.false_world); applied[#applied + 1] = "false_world"
    end
    -- custom_model_center: measure the (now-current) custom model and centre it via the pos offset.
    -- Runs last so it overrides an explicit custom_model_pos_offset in the same call.
    if args.custom_model_center == true then
        local model = p:GetCustomModel()
        if model ~= "" then
            local center = measureRenderCenter(model)
            if center then
                local axis = isstring(args.auto_center_axis) and args.auto_center_axis or "xyz"
                local off = Vector(0, 0, 0)
                if string.find(axis, "x", 1, true) then off.x = -center.x end
                if string.find(axis, "y", 1, true) then off.y = -center.y end
                if string.find(axis, "z", 1, true) then off.z = -center.z end
                p:SetCustomModelPosOffset(off)
                applied[#applied + 1] = "custom_model_center"
            end
        end
    end
    return nil
end

-- Size/pos/angles/parent must be set BEFORE Spawn: the collision frame is only built in
-- ENT:Initialize when width/height > 0, and post-Spawn SetParent on a trigger portal silently
-- kills its Touch detection. Flags (open/enable_teleport) are applied by the caller AFTER Spawn
-- (Initialize force-sets them true for non-map portals).
---@param pos Vector
---@param ang Angle?
---@param width number
---@param height number
---@param thickness number?
---@param parent Entity?
---@param owner Player?
local function spawnPortal(pos, ang, width, height, thickness, parent, owner)
    local p = ents.Create(PORTAL_CLASS)
    if not IsValid(p) then return nil end
    p:SetPos(pos)
    if ang then p:SetAngles(ang) end
    p:SetWidth(width)
    p:SetHeight(height)
    if thickness then p:SetThickness(thickness) end
    if IsValid(parent) then p:SetParent(parent) end
    p:Spawn()
    p:Activate()
    if IsValid(owner) then p:SetCreator(owner) end
    p.mcp_spawned = true
    return p
end

-- thickness 0 -> a zero-depth (-5..-5) trigger box: players still cross (plane-based SetupMove) but
-- props may not (Touch needs box overlap). Warn (don't block); only on an explicit 0.
---@param t number?
local function thicknessWarning(t)
    if t ~= nil and math.floor(t) == 0 then
        return "thickness 0 makes a zero-depth trigger box: players still teleport (plane-based) but PROPS may not register a crossing (Touch-based) -- pass a small positive thickness for prop teleport"
    end
    return nil
end

---@param v any schema arg, validated below
local function resolveParent(v)
    if v == nil then return nil, nil end
    if not isnumber(v) then return nil, "`parent` must be an entindex" end
    local e = Entity(v)
    if not IsValid(e) then return nil, "no entity at parent entindex " .. v end
    return e, nil
end

-- Property blocks shared across create / set / spec-item so schemas stay in lockstep.
local SIZE_PROPS = {
    width = { type = "number", description = "Opening width in units. Default 100 on create." },
    height = { type = "number", description = "Opening height in units. Default 100 on create." },
    thickness = { type = "number", description = "Portal box thickness in units (0 = zero-depth: players cross, props may not)." },
}
local RENDER_PROPS = {
    open = { type = "boolean", description = "Portal open (renders + teleports). Defaults true on create." },
    enable_teleport = { type = "boolean", description = "Whether crossing teleports. Defaults true on create." },
    inverted = { type = "boolean", description = "Invert (render/link from the back face)." },
    transparency = { type = "number", description = "Surface transparency 0-255." },
    disappear_dist = { type = "number", description = "Fade-out distance; 0 = never fade." },
    zfar = { type = "number", description = "Far clip for the portal view render." },
    custom_model = { type = "string", description = "Model rendered in place of the flat surface (empty clears)." },
    custom_model_center = { type = "boolean", description = "Auto-centre the custom model: measure its render bounds and set custom_model_pos_offset to centre it (overrides an explicit offset)." },
    auto_center_axis = { type = "string", description = "Axes to centre with custom_model_center, e.g. \"z\" or \"xyz\" (default \"xyz\")." },
    custom_model_pos_offset = { type = "array", items = { type = "number" }, description = "Custom model position offset [x,y,z]." },
    custom_model_ang_offset = { type = "array", items = { type = "number" }, description = "Custom model angle offset [p,y,r]." },
    exit_pos_offset = { type = "array", items = { type = "number" }, description = "Offset [x,y,z] applied to where a crosser lands at the exit." },
    exit_ang_offset = { type = "array", items = { type = "number" }, description = "Angle offset [p,y,r] applied to a crosser's facing at the exit." },
    false_world = { type = "string", description = "Registered false-world name to show instead of linking (empty = none)." },
}

local function mergeProps(...)
    local out = {}
    for _, block in ipairs({ ... }) do
        for k, v in pairs(block) do out[k] = v end
    end
    return out
end

-- One portal in a batch `specs`: its own pos + any knob (falls back to the top-level shared value).
local SPEC_ITEM = mergeProps({
    pos = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "This portal's position [x,y,z] (required per spec)." },
    angles = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "This portal's angles [p,y,r]." },
    parent = { type = "integer", description = "Parent this portal to an entindex (applied before Spawn)." },
    link_to = { type = "integer", description = "1-based index of another spec in this batch to bidirectionally link this portal's exit to." },
}, SIZE_PROPS, RENDER_PROPS)

-- Merge a spec item over the shared top-level args (item wins).
---@param spec any spec item, table when present
---@param shared table schema args
local function mergeSpec(spec, shared)
    local m = {}
    for k, v in pairs(shared) do m[k] = v end
    if istable(spec) then for k, v in pairs(spec) do m[k] = v end end
    m.specs = nil -- don't recurse
    return m
end

---@param args table schema args
local function createBatch(args)
    local specs = args.specs
    if #specs == 0 then return { ok = false, error = "`specs` must be a non-empty array" } end
    if #specs > MAX_SPECS then return { ok = false, error = "too many specs (max " .. MAX_SPECS .. ")" } end

    local owner, ownerErr = wp_.ResolvePlayer(args.steamid)
    if args.steamid ~= nil and args.steamid ~= "" and not owner then
        return { ok = false, error = ownerErr }
    end

    local sharedExit
    if args.exit ~= nil then
        local ex, exErr = wp_.ResolvePortal(args.exit)
        if not ex then return { ok = false, error = "bad shared `exit`: " .. exErr } end
        sharedExit = ex
    end

    -- Spawn every portal first (so link_to indices resolve), tracking a warning if any hit thickness 0.
    local created, warning = {}, nil
    for i, spec in ipairs(specs) do
        local m = mergeSpec(spec, args)
        local coords, posErr = wp_.ParseTriple(m.pos, "specs[" .. i .. "].pos")
        if not coords then
            for _, p in ipairs(created) do if IsValid(p) then p:Remove() end end
            return { ok = false, error = posErr }
        end
        local ang
        if m.angles ~= nil then
            local a, e = wp_.ParseTriple(m.angles, "specs[" .. i .. "].angles")
            if not a then
                for _, p in ipairs(created) do if IsValid(p) then p:Remove() end end
                return { ok = false, error = e }
            end
            ang = Angle(a[1], a[2], a[3])
        end
        local parent, pErr = resolveParent(m.parent)
        if pErr then
            for _, p in ipairs(created) do if IsValid(p) then p:Remove() end end
            return { ok = false, error = "specs[" .. i .. "]: " .. pErr }
        end
        local width = m.width ~= nil and math.max(0, math.floor(m.width)) or wp_.DEFAULT_WIDTH
        local height = m.height ~= nil and math.max(0, math.floor(m.height)) or wp_.DEFAULT_HEIGHT
        local thickness = m.thickness ~= nil and math.max(0, math.floor(m.thickness)) or nil
        warning = warning or thicknessWarning(m.thickness)

        local p = spawnPortal(Vector(coords[1], coords[2], coords[3]), ang, width, height, thickness, parent, owner)
        if not IsValid(p) then
            for _, q in ipairs(created) do if IsValid(q) then q:Remove() end end
            return { ok = false, error = "failed to create portal for specs[" .. i .. "]" }
        end
        applyRenderFlags(p, m, {})
        created[i] = p
    end

    -- Resolve links: per-item link_to (bidirectional within the batch), else the shared exit.
    local bidirectional = args.bidirectional ~= false
    for i, spec in ipairs(specs) do
        local p = created[i]
        if istable(spec) and isnumber(spec.link_to) then
            local j = spec.link_to
            if created[j] and j ~= i then
                local target = created[j]
                p:SetExit(target)
                if bidirectional then target:SetExit(p) end
            end
        elseif sharedExit then
            p:SetExit(sharedExit)
            if args.link_back ~= false then sharedExit:SetExit(p) end
        end
    end

    local portals = {}
    for _, p in ipairs(created) do portals[#portals + 1] = wp_.PortalState(p) end
    local result = { ok = true, batch = true, count = #created, portals = portals }
    if warning then result.warning = warning end
    return result
end

MCP:AddFunction({
    id = "wp_portal_create",
    description = "Create world-portal(s) (linked_portal_door). THREE modes: (1) SINGLE -- give `pos` [x,y,z] (+ optional `angles`); (2) PAIR -- also give `exit_pos` (+ `exit_angles`) to spawn a second portal there and bidirectionally cross-link the pair (the common working-teleport case); or link the new portal to an EXISTING one with `exit` (an entindex) + `link_back` (default true); (3) BATCH -- give a `specs` array (each item: its own `pos` + any knob, falling back to the top-level shared value; optional per-item `link_to` = 1-based index of another spec to bidirectionally link to; optional per-item `parent`), plus an optional shared `exit`, to spawn+link a whole fan/ring/row in one call and get every entindex back. Any mode: `parent` (entindex) mounts the portal on a shell/contraption -- applied BEFORE Spawn (post-spawn parenting silently kills the portal's Touch teleport). `custom_model` + `custom_model_center` auto-centres a custom model (measures its render bounds, sets the pos offset). Size (`width`/`height` default 100, `thickness`) and flag/render knobs apply; open/enable_teleport default true. thickness 0 warns (zero-depth box -- players cross, props may not). Portals are tagged mcp_spawned. Returns the new `portal` (+ `exit_portal` for a pair/link), or `portals`[] for a batch.",
    schema = {
        type = "object",
        properties = mergeProps({
            pos = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "First portal position [x,y,z] (single/pair mode)." },
            angles = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "First portal angles [p,y,r]." },
            parent = { type = "integer", description = "Parent the portal to this entindex, applied BEFORE Spawn (mount on a shell/contraption without killing Touch)." },
            exit_pos = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Spawn a second portal here and cross-link the pair. Mutually exclusive with `exit`." },
            exit_angles = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Angles [p,y,r] for the paired exit portal." },
            exit = { type = "integer", description = "Link the new portal(s) to this EXISTING portal entindex instead of a pair. Mutually exclusive with `exit_pos`." },
            link_back = { type = "boolean", description = "With `exit`, also point the existing portal back (bidirectional). Default true." },
            bidirectional = { type = "boolean", description = "For batch `link_to` links, also link the partner back (default true)." },
            specs = { type = "array", items = { type = "object", properties = SPEC_ITEM }, description = "BATCH mode: an array of per-portal specs. Each needs its own `pos`; other knobs fall back to the top-level shared values. Optional per-item `link_to` (1-based batch index) and `parent`." },
            steamid = { type = "string", description = "Owner SteamID/SteamID64 (SetCreator); defaults to the first player." },
        }, SIZE_PROPS, RENDER_PROPS),
        required = {},
    },
    requires = { "worldportals_control" },
    handler = function(args)
        args = args or {}
        ---@cast args table

        if istable(args.specs) then return createBatch(args) end

        local coords, posErr = wp_.ParseTriple(args.pos, "pos")
        if not coords then return { ok = false, error = posErr } end
        local posA = Vector(coords[1], coords[2], coords[3])

        local angA
        if args.angles ~= nil then
            local a, e = wp_.ParseTriple(args.angles, "angles")
            if not a then return { ok = false, error = e } end
            angA = Angle(a[1], a[2], a[3])
        end

        if args.exit_pos ~= nil and args.exit ~= nil then
            return { ok = false, error = "specify `exit_pos` (create a linked pair) OR `exit` (link to an existing portal), not both" }
        end

        local owner, ownerErr = wp_.ResolvePlayer(args.steamid)
        if args.steamid ~= nil and args.steamid ~= "" and not owner then
            return { ok = false, error = ownerErr }
        end

        local parent, pErr = resolveParent(args.parent)
        if pErr then return { ok = false, error = pErr } end

        local width = args.width ~= nil and math.max(0, math.floor(args.width)) or wp_.DEFAULT_WIDTH
        local height = args.height ~= nil and math.max(0, math.floor(args.height)) or wp_.DEFAULT_HEIGHT
        local thickness = args.thickness ~= nil and math.max(0, math.floor(args.thickness)) or nil

        local a = spawnPortal(posA, angA, width, height, thickness, parent, owner)
        if not IsValid(a) then return { ok = false, error = "failed to create linked_portal_door (ents.Create returned nothing)" } end

        local flagErr = applyRenderFlags(a, args, {})
        if flagErr then a:Remove(); return { ok = false, error = flagErr } end

        local result = { ok = true, portal = wp_.PortalState(a) }
        local warning = thicknessWarning(args.thickness)
        if warning then result.warning = warning end

        if args.exit_pos ~= nil then
            local ec, ee = wp_.ParseTriple(args.exit_pos, "exit_pos")
            if not ec then a:Remove(); return { ok = false, error = ee } end
            local posB = Vector(ec[1], ec[2], ec[3])
            local angB
            if args.exit_angles ~= nil then
                local ea, eae = wp_.ParseTriple(args.exit_angles, "exit_angles")
                if not ea then a:Remove(); return { ok = false, error = eae } end
                angB = Angle(ea[1], ea[2], ea[3])
            end
            local b = spawnPortal(posB, angB, width, height, thickness, parent, owner)
            if not IsValid(b) then a:Remove(); return { ok = false, error = "failed to create the exit portal" } end
            applyRenderFlags(b, args, {})
            a:SetExit(b)
            b:SetExit(a)
            result.linked_pair = true
            result.portal = wp_.PortalState(a)
            result.exit_portal = wp_.PortalState(b)
        elseif args.exit ~= nil then
            local ex, exErr = wp_.ResolvePortal(args.exit)
            if not ex then a:Remove(); return { ok = false, error = "bad `exit`: " .. exErr } end
            a:SetExit(ex)
            if args.link_back ~= false then ex:SetExit(a) end
            result.portal = wp_.PortalState(a)
            result.exit_portal = wp_.PortalState(ex)
        end

        return result
    end,
})

MCP:AddFunction({
    id = "wp_portal_set",
    description = "Mutate world-portal NetworkVars, then report. `entindex` is a portal index for a SINGLE portal, or the string \"all\" / \"mcp_spawned\" to bulk-apply the same knobs to every portal / every tool-created portal (repositioning a whole scene in one call). Knobs: transform (`pos` absolute, `pos_delta` [dx,dy,dz] relative -- ideal for a uniform bulk move), `angles`, size (width/height/thickness), flags (open/enable_teleport/inverted), render (transparency/disappear_dist/zfar/custom_model (+ custom_model_center to auto-centre) + pos/ang offsets, exit_pos_offset/exit_ang_offset, false_world). The exit LINK is not set here -- use wp_portal_link. A single-target call returns the full portalState + `applied`; a bulk call returns matched count + applied + a brief per-portal list.",
    schema = {
        type = "object",
        properties = mergeProps({
            entindex = { description = "A portal entindex (number) for one portal, or \"all\" / \"mcp_spawned\" (string) to bulk-apply." },
            pos = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Move to absolute [x,y,z]." },
            pos_delta = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Move by a relative delta [dx,dy,dz] (great for a uniform bulk move / raise-by-dz)." },
            angles = { type = "array", items = { type = "number" }, minItems = 3, maxItems = 3, description = "Reorient to [p,y,r]." },
        }, SIZE_PROPS, RENDER_PROPS),
        required = { "entindex" },
    },
    requires = { "worldportals_control" },
    handler = function(args)
        args = args or {}
        local sel = args.entindex

        local targets = {}
        if isnumber(sel) then
            local p, err = wp_.ResolvePortal(sel)
            if not p then return { ok = false, error = err } end
            targets = { p }
        elseif sel == "all" or sel == "mcp_spawned" then
            for _, p in ipairs(wp_.AllPortals()) do
                if sel == "all" or p.mcp_spawned == true then targets[#targets + 1] = p end
            end
        else
            return { ok = false, error = "`entindex` must be a portal entindex, or \"all\" / \"mcp_spawned\" for bulk" }
        end

        if #targets == 0 then
            return { ok = true, bulk = true, matched = 0, applied = {}, portals = {} }
        end

        local applied
        for _, p in ipairs(targets) do
            local ap = {}
            local e1 = applyTransformSize(p, args, ap)
            if e1 then return { ok = false, error = e1 } end
            local e2 = applyRenderFlags(p, args, ap)
            if e2 then return { ok = false, error = e2 } end
            applied = ap
        end

        if not applied or #applied == 0 then
            return { ok = false, error = "specify at least one knob to set (pos/pos_delta/angles/width/height/thickness/open/enable_teleport/inverted/transparency/disappear_dist/zfar/custom_model[_center]/offsets/false_world)" }
        end

        if isnumber(sel) then
            local st = wp_.PortalState(targets[1])
            st.applied = applied
            local warning = thicknessWarning(args.thickness)
            if warning then st.warning = warning end
            return st
        end

        local brief = {}
        for _, p in ipairs(targets) do brief[#brief + 1] = { index = p:EntIndex(), pos = p:GetPos() } end
        local result = { ok = true, bulk = true, selector = sel, matched = #targets, applied = applied, portals = brief }
        local warning = thicknessWarning(args.thickness)
        if warning then result.warning = warning end
        return result
    end,
})

MCP:AddFunction({
    id = "wp_portal_link",
    description = "Link or unlink a world-portal's exit -- the SetExit pair link, the keystone of a working teleport pair. Pass `a` (a portal entindex) and either `b` (another portal to point `a`'s exit at) or `unlink:true` (clear `a`'s exit). `bidirectional` (default true): on link, also point `b` back at `a` (A<->B); on unlink, also clear the partner's back-link if it pointed at `a`. Portals only teleport when BOTH sides point at each other. Returns the resulting `a` and (when relevant) `b` state so you can confirm `link.mutual`.",
    schema = {
        type = "object",
        properties = {
            a = { type = "integer", description = "The portal whose exit to set (entindex)." },
            b = { type = "integer", description = "The portal to point `a`'s exit at. Omit and set unlink:true to clear." },
            unlink = { type = "boolean", description = "Clear `a`'s exit (and the partner's back-link if bidirectional) instead of linking." },
            bidirectional = { type = "boolean", description = "Also link/unlink the partner's exit back to `a` (default true)." },
        },
        required = { "a" },
    },
    requires = { "worldportals_control" },
    handler = function(args)
        local a, aErr = wp_.ResolvePortal(args.a)
        if not a then return { ok = false, error = aErr } end

        local bidirectional = args.bidirectional ~= false

        if args.unlink == true then
            local prev = a:GetExit()
            a:SetExit(NULL)
            if bidirectional and wp_.IsPortal(prev) and prev:GetExit() == a then prev:SetExit(NULL) end
            local result = { ok = true, action = "unlink", a = wp_.PortalState(a) }
            if wp_.IsPortal(prev) then result.b = wp_.PortalState(prev) end
            return result
        end

        if args.b == nil then
            return { ok = false, error = "specify `b` (a portal to link to) or `unlink:true`" }
        end
        local b, bErr = wp_.ResolvePortal(args.b)
        if not b then return { ok = false, error = bErr } end
        if b == a then return { ok = false, error = "cannot link a portal to itself" } end

        a:SetExit(b)
        if bidirectional then b:SetExit(a) end

        return {
            ok = true,
            action = "link",
            bidirectional = bidirectional,
            a = wp_.PortalState(a),
            b = wp_.PortalState(b),
        }
    end,
})

MCP:AddFunction({
    id = "wp_portal_remove",
    description = "Remove world-portals and confirm they're gone. Select with exactly one of: `entindex` (one portal), `all` (every linked_portal_door), or `mcp_spawned` (only portals this tool created -- the safe cleanup, leaves map-placed portals alone). :Remove is deferred to end-of-frame, so this settles until the targets are actually invalid before reporting `removed` + the removed identities. No match is not an error (removed 0).",
    schema = {
        type = "object",
        properties = {
            entindex = { type = "integer", description = "Remove the single portal at this entindex." },
            all = { type = "boolean", description = "Remove every linked_portal_door in the map." },
            mcp_spawned = { type = "boolean", description = "Remove only portals created by wp_portal_create (tagged mcp_spawned)." },
        },
        required = {},
    },
    requires = { "worldportals_control" },
    handler = function(args, ctx)
        args = args or {}
        local selectors = 0
        if args.entindex ~= nil then selectors = selectors + 1 end
        if args.all == true then selectors = selectors + 1 end
        if args.mcp_spawned == true then selectors = selectors + 1 end
        if selectors ~= 1 then
            return { ok = false, error = "specify exactly one of `entindex`, `all`, or `mcp_spawned`" }
        end

        local targets = {}
        if args.entindex ~= nil then
            local p, err = wp_.ResolvePortal(args.entindex)
            if not p then return { ok = false, error = err } end
            targets[1] = p
        else
            for _, p in ipairs(wp_.AllPortals()) do
                if args.all == true or p.mcp_spawned == true then targets[#targets + 1] = p end
            end
        end

        local removed = {}
        for _, p in ipairs(targets) do
            removed[#removed + 1] = { index = p:EntIndex(), pos = p:GetPos() }
            p:Remove()
        end

        if #targets == 0 then
            return { ok = true, matched = 0, removed = 0, entities = {} }
        end

        MCP:Settle({
            seconds = 2,
            stable_for = 0,
            check = function()
                for _, p in ipairs(targets) do
                    if IsValid(p) then return false end
                end
                return true
            end,
        }, function(s)
            ctx.respond({
                ok = true,
                matched = #targets,
                removed = #targets,
                settled = s.settled,
                entities = removed,
            })
        end)

        return ctx.deferred
    end,
})
