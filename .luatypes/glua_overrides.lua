---@meta

-- glua-api-snippets declares enum aliases as string-literal unions for autocomplete,
-- but the corresponding constants are plain integers at runtime. Re-declare the aliases
-- as `integer` so passing the constants to APIs that take the enum type-checks.

---@alias COLLISION_GROUP integer
---@alias FORCE integer
---@alias MATERIAL_FOG integer
---@alias STENCILOPERATION integer
---@alias STENCILCOMPARISONFUNCTION integer

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
---@field Normal Vector
---@field StartPos Vector

-- util.GetModelInfo returns the model's render-bound corners in HullMin/HullMax (identical to
-- Entity:GetModelRenderBounds), but the stub omits them. Add them so reading a model's bounds
-- from a path - without setting it on an entity - type-checks.
---@class ModelInfo
---@field HullMin Vector
---@field HullMax Vector
