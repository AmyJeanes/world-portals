---@meta
-- Local annotation overrides for gaps in the provisioned GLua annotations.

-- The engine takes a list of lights here, not the single LocalLight the annotation
-- says - the wiki documents "up to 4 tables", so this needs an upstream scraper fix.
---@param lights? LocalLight[]
function render.SetLocalModelLights(lights) end

-- The engine's original TraceLine, saved before wp's detour replaces it.
-- Declared here so every call site sees a clean, non-optional signature.
---@param traceConfig Trace
---@return TraceResult
function util.RealTraceLine(traceConfig) end

-- gmod_hoverball's target height is a per-instance NetworkVar accessor added at spawn, so
-- the annotations don't see it. Declare it so the teleport transform can shift a crossing
-- hoverball's target Z (else it fights back to its pre-teleport height).
---@class gmod_hoverball : Entity
---@field GetTargetZ fun(self: gmod_hoverball): number
---@field SetTargetZ fun(self: gmod_hoverball, z: number)
