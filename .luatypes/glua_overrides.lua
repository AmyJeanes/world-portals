---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("glua_overrides.lua contains type annotations only and must never be executed")

-- Local annotation overrides for gaps in the provisioned GLua annotations.

-- glua_ls upstream: the wiki page path leaks into the generated type, so the annotated
-- `Structures/LocalLight[]` resolves to a bogus class `Structures` -- https://github.com/Pollux12/annotations-gmod-glua-ls/issues/16
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

-- The map's 3D skybox camera: a stock engine entity with no annotation entry, so
-- FindByClass on it would otherwise auto-create the class and warn.
---@class sky_camera : Entity