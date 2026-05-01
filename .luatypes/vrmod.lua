---@meta

-- Optional dependency: g3dev's VRMod (Workshop addon).
-- Code paths that touch this are guarded with `if vrmod then` checks.

---@class vrmod
---@field IsPlayerInVR fun(ply?: Player): boolean
---@field GetOriginAng fun(): Angle
---@field SetOriginAng fun(ang: Angle)
vrmod = nil
