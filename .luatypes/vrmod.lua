---@meta

-- Type annotations only - never executed. The declarations below define real
-- globals and library functions with empty bodies, so loading this file at
-- runtime would replace working functions with stubs rather than declare them.
-- It lives outside lua/ so the game cannot reach it; this is the backstop.
error("vrmod.lua contains type annotations only and must never be executed")

-- Optional dependency: g3dev's VRMod (Workshop addon).
-- Code paths that touch this are guarded with `if vrmod then` checks.

---@class vrmod
---@field IsPlayerInVR fun(ply?: Player): boolean
---@field GetOriginAng fun(): Angle
---@field SetOriginAng fun(ang: Angle)
vrmod = nil