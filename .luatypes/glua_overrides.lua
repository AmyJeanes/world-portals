---@meta

-- glua-api-snippets declares enum aliases as string-literal unions for autocomplete,
-- but the corresponding constants are plain integers at runtime. Re-declare the aliases
-- as `integer` so passing the constants to APIs that take the enum type-checks.

---@alias COLLISION_GROUP integer
---@alias EF integer
---@alias FCVAR integer
---@alias FORCE integer
---@alias MATERIAL_FOG integer
---@alias STENCILOPERATION integer
---@alias STENCILCOMPARISONFUNCTION integer
---@alias RT_SIZE integer
---@alias MATERIAL_RT_DEPTH integer
---@alias TEXTUREFLAGS integer
---@alias CREATERENDERTARGETFLAGS integer

---@type FCVAR
FCVAR_ARCHIVE = 128
---@type COLLISION_GROUP
COLLISION_GROUP_WORLD = 20
---@type COLLISION_GROUP
COLLISION_GROUP_WEAPON = 11
---@type COLLISION_GROUP
COLLISION_GROUP_IN_VEHICLE = 10
---@type EF
EF_BONEMERGE = 1
---@type STENCILOPERATION
STENCIL_KEEP = 1
---@type STENCILOPERATION
STENCIL_REPLACE = 3
---@type STENCILCOMPARISONFUNCTION
STENCIL_EQUAL = 3
---@type STENCILCOMPARISONFUNCTION
STENCIL_ALWAYS = 8
---@type RT_SIZE
RT_SIZE_NO_CHANGE = 0
---@type MATERIAL_RT_DEPTH
MATERIAL_RT_DEPTH_SEPARATE = 1
---@type MATERIAL_FOG
MATERIAL_FOG_NONE = 0
---@type MATERIAL_FOG
MATERIAL_FOG_LINEAR = 1

-- The stub declares only the 3-arg `table.insert(tbl, position, value)` form, so calls
-- like `table.insert(t, x)` against a narrowly-typed `t` mis-resolve and treat `x` as
-- the position. Add the 2-arg append-only overload.
---@diagnostic disable-next-line: duplicate-set-field
---@overload fun(tbl: table, value: any): integer
---@param tbl table
---@param position integer
---@param value any
---@return integer
function table.insert(tbl, position, value) end

-- glua-api initialises always-populated TraceResult fields to `nil` (e.g.
-- `TraceResult.HitPos = nil`) despite their `---@type Vector`, and the flow-nil
-- analysis reads that literal over the annotation - re-declaring the field in a
-- meta file does not win (class defs merge). A real trace always fills these, so
-- a populated trace is `---@cast trace WPTraceResult` at the call site instead.
---@class WPTraceResult : TraceResult
---@field HitPos Vector
---@field HitNormal Vector
---@field Normal Vector
---@field StartPos Vector

-- util.GetModelInfo returns the model's render-bound corners in HullMin/HullMax (identical to
-- Entity:GetModelRenderBounds), but the stub omits them. Add them so reading a model's bounds
-- from a path - without setting it on an entity - type-checks.
---@class ModelInfo
---@field HullMin Vector
---@field HullMax Vector

-- glua-api's ViewData omits `aspectratio`, the deprecated-but-still-honored alias of `aspect`.
-- Add it so a view carrying the legacy field type-checks (wp reads both, and emits `aspect`).
---@class ViewData
---@field aspectratio number?

-- gmod_hoverball's target height is a per-instance NetworkVar accessor added at spawn, so
-- glua-api doesn't see it. Declare it so the teleport transform can shift a crossing
-- hoverball's target Z (else it fights back to its pre-teleport height).
---@class gmod_hoverball : Entity
---@field GetTargetZ fun(self: gmod_hoverball): number
---@field SetTargetZ fun(self: gmod_hoverball, z: number)
