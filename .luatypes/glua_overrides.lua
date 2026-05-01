---@meta

-- glua-api-snippets declares enum aliases as string-literal unions for autocomplete,
-- but the corresponding constants are plain integers at runtime. Re-declare the aliases
-- as `integer` so passing the constants to APIs that take the enum type-checks.

---@alias COLLISION_GROUP integer
---@alias FORCE integer
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
