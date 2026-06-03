# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Garry's Mod (Lua) addon that ships the `linked_portal_door` entity and a small `wp.*` runtime library. The portal entity renders one location through another using a stencil mask and a render-target texture, and (optionally) teleports anything that crosses it. The repository lives in-place inside `garrysmod/addons/world-portals`; there is no compile/build step.

This is the **base layer** other addons sit on. The most prominent consumer is `AmyJeanes/Doors` (TARDIS-style doors), which builds its exterior↔interior teleporting on top of `linked_portal_door` and uses `wp.TransformPortal*` for player view/velocity transforms. The Doors CI combines this repo with that one into a single Workshop upload — paths here may collide with paths there at upload time, with the consumer winning.

There is no `addon.json` (this repo is combined into Doors's Workshop upload at build time), but `.github/workflows/ci.yml` runs `glua_check` against the codebase on push and pull request to `dev`. GMod loads the `lua/` tree at server start.

## Architecture

### Module layout

`lua/autorun/worldportals_init.lua` is the only entry point. It:
1. Creates the `wp` namespace (one global table — chosen because "worldportals" is too long for prefixing every helper).
2. Calls `wp.LoadFolder("worldportals")` — a folder-scanning loader that `file.Find`s every `*.lua` in `lua/worldportals/` and dispatches each by filename prefix:
   - `sh_*.lua` — both realms; `AddCSLuaFile`'d on the server.
   - `sv_*.lua` — server only.
   - `cl_*.lua` — client only; `AddCSLuaFile`'d.
   A file whose name has no recognised prefix is silently skipped, so the prefix is mandatory.
3. Calls `wp.LoadFolder("worldportals/falseworlds", true)` — the `noprefix` form, which `include`s + `AddCSLuaFile`s every file in that subtree shared regardless of name (the false-worlds extension point; ships only `example.lua` here).

The loader scans the folder, so **adding a new file under `lua/worldportals/` needs no edit to `worldportals_init.lua`** — give it the right realm prefix and it's picked up automatically (this is how `sh_teleport.lua`, `cl_ghosts.lua`, `cl_options.lua`, `sv_collision.lua` all load). Keep the realm-prefix convention — the loader dispatches on it, the static analyzer's realm-mismatch heuristic uses it, and the consumer addon Doors depends on it for its own scanner. (Entities under `lua/entities/` — `linked_portal_door`, `linked_portal_frame` — are auto-loaded by GMod's own entity system and likewise need no registration.)

### `wp.*` API surface (all in `sh_utils.lua` unless noted)

Math helpers used by both the entity and downstream consumers:

- `wp.IsBehind(pos, plane_pos, plane_forward) → boolean` — half-space test.
- `wp.IsLookingAt(portal, portal_pos, view_pos, view_ang, view_fov) → boolean` — frustum/cone test, used to skip rendering portals the camera can't see.
- `wp.DistanceToPlane(pos, plane_pos, plane_forward) → number` — signed distance.
- `wp.TransformPortalPos(vec, portal, exit_portal) → Vector` — relative to entry, mirrored 180°, applied to exit (with `GetExitPosOffset`/`GetExitAngOffset` accounted for).
- `wp.TransformPortalVector(vec, portal, exit_portal) → Vector` — direction-only variant (used for velocity). Same `WorldToLocal → 180° mirror → LocalToWorld` pipeline as the position/angle transforms, so it's a real rotation at any pitch/yaw/roll. The old `exit:GetAngles() - portal:GetAngles()` Euler-subtraction form was only correct for yaw-only (wall) pairs and silently *flipped* velocity on floor/ceiling/rolled pairs — the confirmed infinite-fall bounce.
- `wp.TransformPortalAngle(angle, portal, exit_portal) → Angle` — rotates an angle through a portal pair.
- `wp.GetFirstPortalHit(source, direction) → {Entity, Distance, HitPos}` — ray-vs-portal-plane scan over `ents.FindByClass("linked_portal_door")`.

In-place / allocation-free transform variants live in `cl_render.lua` (they read per-portal cached basis scalars rather than calling the engine `WorldToLocal` each time):

- `wp.TransformPortalPosInto(out, vec, portal, exit_portal)` / `wp.TransformPortalAngleInto(out, ang, portal, exit_portal)` — write the transformed result into a caller-owned `out` `Vector`/`Angle` and return it, so a per-frame hot path allocates no garbage. `cl_ghosts.lua` calls these per bone per frame to pose skeletal ghosts.

Plus rendering state and helpers in `cl_render.lua`:

- `wp.matBlack`, `wp.matTrans`, `wp.matInvis`, `wp.matView`, `wp.matView2` — runtime-created materials.
- `wp.portals` — cached list, refreshed each `RenderScene`.
- `wp.drawing` — re-entrancy guard set during `render.RenderView` calls so the entity's `Draw` skips work.
- `wp.rendermode` — true while inside `RealRenderView`, used by `Draw` to pick the simpler material path.
- `wp.shouldrender(portal, camOrigin?, camAngle?, camFOV?)` — runs the full visibility decision and fires the `wp-shouldrender` hook to allow override.
- `wp.renderportals(plyOrigin, plyAngle, w, h, fov)` — renders every portal's exit-view to its texture.

### Entity: `linked_portal_door`

Three files:
- `shared.lua` — type/render group, `Initialize`, `SetupBounds` (recomputes render/collision bounds + the 5 quads used for inverted/thick rendering), and the `SetupDataTables` block that creates every networked field (`Exit`, `Width`, `Height`, `Thickness`, `Transparency`, `ZFar`, `Open`, `EnableTeleport`, `Inverted`, `CustomLink`, `ExitPosOffset`/`ExitAngOffset`, `ModelPos`/`ModelAng`). The Width/Height/Thickness `NetworkVarNotify`s rebuild bounds **and** (server) the collision frame's hull; the `Open`/`EnableTeleport` notifies call `wp.DisarmPortal` when the portal goes closed/non-teleporting so a prop mid-pass-through doesn't end up clipping a wall that just went solid again.
- `init.lua` (server) — `KeyValue` handles Hammer entity I/O (`partnername`, `width` ×2, `height` ×2, `thickness`, `DisappearDist`, `angles`, `EnableTeleport`, `Open`, output `On*` are forwarded to `StoreOutput`); `Touch` teleports **non-player entities only** (props, NPCs, ragdolls — players go through the predicted SetupMove path in `sh_teleport.lua`): entry-side check via `DistanceToPlane`, fires the `wp-shouldtp` hook for veto, transforms pos/velocity/angle, special-cases ragdolls by snapshotting all physics objects' local pose then re-applying after `SetPos`, broadcasts `WorldPortals_Teleport` so clients update the entity's position immediately rather than waiting for the snapshot. `Touch` also arms the pass-through no-collide for a *dynamic or physgun-held* prop straddling the doorway (`wp.ArmNoCollide`, see the collision section), and pre-arms the exit side on teleport; `EndTouch` disarms it. `AcceptInput` handles the Hammer inputs. `RebuildCollisionFrame` (called from `Initialize`) creates the portal's `linked_portal_frame` child and no-collides it with the wall; the Width/Height/Thickness notifies resize its hull via `BuildFrame`, and `OnRemove` tears it down (GMod doesn't auto-remove the unparented frame).
- `cl_init.lua` — `Draw` is the stencil-and-stencil dance. With the model error.mdl marker (no model assigned) it draws a black box (or thick portal quads when `Thickness > 0`); with a model assigned it draws via `render.Model`. When `wp.rendermode` is true (we're inside `RenderView` for another portal) it uses the simpler `matView2`-textured path instead of stenciling. The non-`rendermode` path writes a stencil mask, draws the portal black/transparent, then rerenders the contents through `matView` only where the stencil matches — alpha blended via `cam.Start2D` if `Transparency > 0`. Receives `WorldPortals_VRMod_SetAngle` (rotates VR origin) and `WorldPortals_Teleport` (mirrors the server-side `SetPos`/`SetAngles` so non-server-authoritative clients don't see lag — for `LocalPlayer` this is skipped since they predicted it themselves; instead `wp.RecordNetTeleport` records the broadcast pos so the debug HUD can flag predict/snapshot disagreement).

### Stencil rendering pipeline (`cl_render.lua`)

This is the most fragile / load-bearing piece. The flow in a single frame:

1. `render.RenderView` is monkey-patched (`render.RenderView = WorldPortals_RenderView`). On every call: render every portal's exit-view to its render-target texture (recursively — `wp.drawing` guards prevent infinite recursion), then pass through to `RealRenderView` for the actual scene draw.
2. `wp.renderportals` iterates `linked_portal_door` entities. For each portal that `wp.shouldrender` accepts:
   - Push its render target.
   - Push a custom clip plane at the **exit** so geometry behind the exit's back face doesn't bleed.
   - Compute the camera origin/angle by `TransformPortal*`-ing the player's view through the pair.
   - Compute `zfar` based on portal-to-exit distance + the player's forward distance (so faraway exits aren't culled prematurely).
   - Recursively `RenderView` with `viewid = 1` (`VIEW_3DSKY`) — this is the trick that makes the engine treat it as "skybox view" and avoids HUD/postprocess.
3. Disable phys gun glow/beam during the loop by zeroing the local player's weapon color and restoring after.
4. `RenderScene` hook calls `renderportals` for the actual eye view (in addition to the monkey-patched `RenderView` recursion), so even if `RenderView` was never called externally the portals still get textured for `Draw`.
5. `PreDrawHalos` returns false while `wp.drawing` so halo renders inside portal views don't break the stencil.

The order matters and the `wp.drawing` / `wp.rendermode` guards are why almost every callback in this addon checks them first.

### Predicted player teleport (`sh_teleport.lua`)

Players go through a `SetupMove` hook that runs in the prediction loop on both server and client (LocalPlayer only on the client side), so the local view stays in lockstep with the server without waiting for a snapshot.

Per-tick flow inside the hook:

1. Skip dead/zero-velocity players.
2. Iterate `linked_portal_door`s. Skip portals that are closed, not teleport-enabled, have no exit, or that the player isn't moving toward (`velocity:Dot(fwd) >= 0`).
3. Swept eye-pos test: this tick's eye and next-tick eye (`eye + vel * FrameTime()`) on opposite sides of the portal's `GetPos()` plane. The reference plane is `portal:GetPos()` rather than the visible face (5 units in front), because that's the same plane `cl_render.lua`'s `wp.shouldrender` uses for back-face culling — once the eye crosses it, the stencil stops rendering and the player would see "through" the portal volume. Firing on this plane guarantees the teleport always beats the cull.
4. Local-space Y/Z bbox check at the projected crossing point (matches `wp.GetFirstPortalHit`).
5. `wp-shouldtp` hook for veto — registered shared in Doors so client and server can both consult it. Inner `ShouldTeleportPortal` handlers stay server-only; on the client `CallHook` returns nil (no veto), so the client optimistically allows and the server has the final say.
6. Apply per-tick state: `mv:SetOrigin(newPos)`, `mv:SetVelocity(newVel)`, `mv:SetAngles(clampedAng)`, `cmd:SetViewAngles(clampedAng)`. These all mutate per-tick prediction state and are safe to re-apply during resimulation. `mv:SetOrigin/SetVelocity` drive the move; `mv:SetAngles` is what gamemovement reads to interpret W/S/A/D direction (without it the engine still uses the pre-teleport view, causing a "skid" on direction-changing portals); `cmd:SetViewAngles` keeps the next move's input direction consistent.
7. Call `ply:SetPos(newPos)` on **every** prediction pass (server, and client first-time AND resim). `ply:SetPos` is the canonical entity-snap path (same one the broadcast hits for remote clients), resets the AbsOrigin interp cache that `mv:SetOrigin` doesn't touch, and — critically — makes `ply:GetPos()` report the post-teleport pos before the `wp-teleport` hook (step 10) runs, so a consumer unstick that reads `ply:GetPos()` resolves against the destination on every pass. It re-snaps to the same deterministic value each resim, which is harmless. (Was first-time-only; that left the predicted origin at the raw transform on resim — see the high-ping stuck-after-teleport note below.)
8. Call `ply:SetEyeAngles(clampedAng)` on the **client only**, and only when `IsFirstTimePredicted()`. `ply:SetEyeAngles` writes the persistent `m_angEyeAngles` field. *Why client:* it's what actually rotates the camera (`cmd:SetViewAngles` alone leaves the camera on its last-input value — directional portals no-op without it). The rotated angle then rides out in the player's subsequent cmds (mouse is sampled relative to it), so the server picks it up via `cmd:GetViewAngles` and converges on its own — no explicit server write needed. *Why first-time only:* `SetEyeAngles` writes a persistent field that survives resim, so calling it during resim clobbers mouse delta accumulated since (camera "snaps back" mid-look). *Why NOT the server:* a server write makes `m_angEyeAngles` authoritative, and the snapshot pushes it back to the owning client ~RTT later, **overriding any mouse the user moved during that window** — a confirmed, reproducible snap-back of in-flight look input. (A server-side write was tried this session to kill a suspected angle-rollback; the rollback didn't reproduce in clean testing and the snap-back was strictly worse — reverted.)
9. Server branch: VR yaw offset (`WorldPortals_VRMod_SetAngle`), `ForcePlayerDrop`, entity outputs, `wp-teleport` hook, `mv` re-sync (re-read `ply:GetPos()` to fold any consumer relocation back into `mv:SetOrigin` — FinishMove would otherwise revert it), broadcast `WorldPortals_Teleport` with the final pos.
10. Client branch — split into two parts by resim-safety:
    - **Every pass (first-time AND resim):** the `wp-teleport` hook, then the same `mv` re-sync as the server. This is the fix for the **high-ping stuck-after-teleport** bug: a consumer unstick (Doors) relocates the player via `ply:SetPos` *inside* `wp-teleport`, and that relocation must be reproduced on every resim or FinishMove reverts the predicted origin to the raw transform. The crossing command stays unacked — and so resimulated — for ~RTT at high ping, so a first-time-only hook left the player sitting at the raw (often geometry-embedded) pos until the server snapshot corrected them ~RTT later. The unstick is a pure, deterministic, idempotent resolver (matching the server's), so re-running it every pass yields the identical landing. **Consumers' `wp-teleport`/`PostTeleportPortal` handlers must be idempotent and resim-safe** — like all prediction-path code.
    - **First-time-predicted only:** roll fade trigger (`wp.rotating = newAng.r` for `cl_teleport.lua`'s `CalcView` to interpolate down), predict-lerp arm (`wp.predictedPos = newPos`, `wp.predictedAt = SysTime()` — see below), debug-HUD record. These arm persistent client-frame state and must NOT re-fire on resim — every resim runs within the same frame, so re-arming would reset the fade/window/record each frame for the whole unacked window.

Non-player entities still go through `ENT:Touch` in `init.lua` — they can't be client-predicted (server-authoritative VPhysics).

**Accepted limit — high-ping angle contamination.** At high ping (~`net_fakelag 100`) a predicted teleport can occasionally leave the player rotated by the portal delta: either double-rotated in place, or rotated-and-kicked-back-out. Root cause: the step-8 client `SetEyeAngles` feeds forward into the *next* commands' viewangles, and Source's prediction-error tolerance lets the server's authoritative crossing land on a *different* command than the client's. The realm that crosses "late" reads an already-rotated viewangle — transforming it again (double-rotation), or, while still outside facing the rotated view, walking the player *sideways across the portal face* so the crossing never fires (rotated-and-rolled-back). This is **not cleanly fixable in Lua and should be left alone**: the server only ever sees the contaminated command and there's no upstream channel to hand it the clean angle (predicted DT vars flow server→client only). The one clean fix — never rotate `m_angEyeAngles`, carry the rotation as a render+movement offset — requires globally overriding `EyeAngles` (breaks every consumer's aim while rotated) and is the kind of global change flagged elsewhere in this file. An inference-based fix (transform the last clean approach angle, reject updates matching `view ≈ TransformPortalAngle(stored)`) was tried and reverted: it has a structural false-positive on the **exit** direction (the genuine exit-approach view *is* ≈ the transform of a plausible stored angle), latching a stale angle and rotating the player on every exit.

**Predict-lerp shift window.** `ply:SetPos(newPos)` resets the entity AbsOrigin interp cache but doesn't override the engine's snapshot-driven origin lerp. At high ping (~`net_fakelag 100` = 200ms RTT) a snapshot captured *before* the server ran SetupMove for the predicting command arrives at the client showing the pre-teleport pos, and `ply:GetPos()` lerps from there to the predicted pos for ~RTT. While that lerp is in flight the eye is at the wrong location — `eye-in-renderbounds` against a destination interior fails (blank-sky / black frame), and frustum culling against world geometry uses the wrong origin. Lua can't disable this engine lerp (`cl_smooth`/`cl_interp 0`/`EF_NOINTERP` all do nothing).

Mitigation: arm a shift window from the SetupMove path (`wp.predictedPos`, `wp.predictedOldPos`, `wp.predictedAt`). `cl_teleport.lua`'s `CalcView` and `CalcViewModelView` each compute `delta = ply:GetNetworkOrigin() - ply:GetPos()` per frame and add it to the view origin / viewmodel origin respectively, parking the camera at `NetworkOrigin` (the server-known current position) while the engine drifts `GetPos` through wild intermediate values. The world (and bounds checks against it) renders from the right place, and the viewmodel rides with the camera.

Why `NetworkOrigin` and not `predictedPos`: `predictedPos` is a static target captured at teleport time. As the player keeps walking forward, `GetPos` overshoots it and `predictedPos - GetPos` grows again — using a static target locks the camera at the exact teleport point and "freezes" the view for the disarm window. Convergence detection (disarm when `|delta|<threshold`) was also tried and failed: engine drift is **non-monotonic** (snap → drift back partway → drift forward → settle), so `|delta|` dips below threshold and re-exceeds it, and the convergence-disarm fires on the dip, leaving the next drift wave unmasked. `NetworkOrigin` tracks the live "where the player should be" so the shift naturally goes to zero on real convergence, no dance required.

Sanity guard: at the very first frames after arm, the post-teleport snapshot may not have arrived yet on the client, leaving `NetworkOrigin` at the pre-teleport pos. Applying `NetworkOrigin - GetPos` there would yank the camera *backward* to oldPos. We capture `wp.predictedOldPos = origin` at arm and check `(NetOrigin - predictedPos):LengthSqr() < (NetOrigin - oldPos):LengthSqr()` — if NetOrigin is closer to oldPos than to predictedPos, skip the shift and let `GetPos` (just snapped to newPos by `ply:SetPos`) render through. Surfaced as `sanity=SANITY-FAIL` in the debug HUD.

Disarm: pure `SysTime`-based timeout (0.5s). No convergence detection. Once `GetPos` catches up the shift is a no-op anyway, so leaving the window armed through the timeout is harmless. The earlier convergence-disarm fired too eagerly during the non-monotonic drift; pure timeout is simpler and reliable.

Time bookkeeping uses `SysTime()`, not `CurTime()`: inside `SetupMove` the engine advances `CurTime()` to the predicted-tick time, so `CurTime()` recorded there is "in the future" relative to `CurTime()` in `CalcView` — comparing the two yields negative ages and incorrect timeouts.

Caveat: `SetRenderOrigin` is a no-op for the local playermodel (verified empirically — works on props, ignored on `LocalPlayer`). So the local model itself still lerps; we don't try to drag it. This is invisible in first-person and only briefly visible in mirrors/portal-exit reflections looking back. Both `CalcView` and `CalcViewModelView` reuse a `getPredictDelta(ply)` helper that performs the timeout/convergence check and clears `wp.predictedPos`/`wp.predictedAt` once the window ends. `wp.predictedPos` value itself is unused by the shift logic — it's only kept as the arm flag (and surfaced in the debug HUD).

**Accepted residual — the camera follows `NetworkOrigin`'s snapshot steps during fast post-teleport motion.** While the window is armed (a fixed 0.5s), the camera is parked at `NetworkOrigin`, which is *not* interpolated for the local player — it advances one server-tick at a time. So if the player is moving fast right after the teleport (e.g. a TARDIS exit at ~500 u/s, especially one followed by a large consumer relocation like Doors' ~48u fallback unstick), the camera stutters along those steps — a small (~7u at 500 u/s, shrinking with speed) shift in the direction of motion that the player reads as "the server nudging me." It fully converges (`|GetPos − NetworkOrigin| → 0`) and leaves no lasting desync; measured frame-by-frame at `net_fakelag 100`, `GetPos` stabilises in ~30ms but the window holds the mask for the full 0.5s, so the steps stay visible until it disarms. A threshold-gated *blend-out* (full mask while `|GetPos − NetworkOrigin|` is huge — the genuine wild-drift frames — then ramp the shift to zero once it's small, reverting the camera to the smooth predicted `GetPos`) would remove it, but it touches this same fragile logic and a naive convergence-disarm already regressed once (fired on a dip between wild-drift waves → reintroduced blank sky), so it was left as an accepted limit.

**Noclip re-teleport cooldown.** Noclip rederives velocity from input each tick (`FullNoClipMove` discards `mv:SetVelocity`), so the mirrored exit velocity never takes and a same-facing pair (a TARDIS) ping-pongs the player in/out forever. A 0.25s `NOCLIP_TP_COOLDOWN` (noclip-gated, and resim-safe via the `since > 0` check — `CurTime()` in `SetupMove` is the predicted-tick time, identical across a tick's resims) suppresses the immediate re-fire so the one surviving view rotation can steer them clear. Also why the thick-volume `backLimit` allowance is dropped in noclip — there's no collision to trap a noclipper in the shell, so it just reopens the bounce.

**Deferred — zero-velocity static net.** The velocity gate (step 1) means a player standing *dead still* on an upward-facing (floor) portal — feet resting on whatever's under the opening — never crosses and never teleports. The swept eye/centre test only fires on motion. A separate static-rest path was scoped but **not built**; it's a known gap, not a regression (it never worked for the dead-still case).

### Portal ghosts — continuous entity rendering (`cl_ghosts.lua`)

A client-only visual layer that makes an entity *straddling* a portal read as one continuous body instead of being cut off at the opening. While an entity overlaps the portal plane (before its teleport fires) its already-crossed half is otherwise eaten by the portal hole on the entry side and shows its backfaces out of nothing on the exit side. The fix renders it as **two clipped halves**: the real entity with a `RenderOverride` that clips to the `+entry_forward` half, and a clientside **ghost** (a `ClientsideModel`, flagged `WPIsGhost`) at the mirror-transformed exit pose clipping to the `+exit_forward` half. The 180° mirror maps each half to the other, so the two tile the whole body with the seam on the portal's *visible* face (`FACE_OFFSET`, plus `thickness` for a thick tunnel) rather than the crossing plane 5u behind it.

Deliberately decoupled from the teleport: straddling is detected by a per-frame geometry test (`straddles` — a cheap OBB-centre-in-opening test, plus a robust 12-edge OBB-vs-plane clip for long/off-axis props), not by when the teleport fires.

- **Discovery** runs on a throttled `Think` (`SCAN_INTERVAL` ~25 Hz): an `ents.FindInSphere` broad-phase per open teleport-enabled portal, gated by `isCandidate` (prop_physics / ragdoll / NPC / player including the local player; skips dead players and our own ghosts) and `wouldTeleport` (the **same `wp-shouldtp` veto** the teleport uses — position-independent, so it's the right "portal off" signal; deliberately *not* `wp-shouldrender`, which is view-dependent and would vanish a ghost the moment you step inside a far-off interior).
- **Pose** is re-applied every frame in `PreDrawOpaqueRenderables` (after `cl_init.lua`'s render-follow finalises the original's transform), reading the original's *render* transform (`GetRenderOrigin`/`Angles`, falling back to `GetPos`/`Angles`). Rigid props pose with one `SetPos`/`SetAngles`; **skeletal** entities (ragdolls/NPCs/players) drive the ghost bone-by-bone (`copyBonesThroughPortal`: read each world bone matrix, re-emit through the portal transform), and a held weapon is mirrored as a second sub-ghost.
- **Records** (`wp.ghosts[ent]`) carry a `GHOST_GRACE` (0.1s) anti-flicker grace, are handed to the new pair the instant the entity teleports (the `wp-teleport` hook re-points `rec.portal`/`exit` before render, killing a one-frame half-body flicker), and are torn down on expiry / `EntityRemoved` (restoring the original's saved `RenderOverride`).
- **Local player:** the ghost is the player's emerged half, shown in third-person / external cameras / portal-RT / recursion so the body reads as whole during transit, and suppressed only in the single view looking straight through the portal being transited (`localGhostIsCutaway` — the render camera sits inside the ghost). Player colour is carried by overriding `GetPlayerColor` on the ghost (`SetPlayerColor` errors on a `ClientsideModel`).
- Convars: `worldportals_ghosts` (master) and `worldportals_ghosts_self` (your own body — the latter also gates `cl_render.lua`'s `ShouldDrawLocalPlayer` so turning it off also stops your reflection drawing into portal RTs). The consumer hooks `wp-shouldghost` / `wp-shouldghostdraw` are described under Conventions.

### Client: rapid-loop interp bypass (`cl_renderfollow.lua`)

A non-player prop that teleports twice within `RAPID_WINDOW` (a tight floor↔ceiling loop) renders at its live `GetNetworkOrigin`/`GetNetworkAngles` instead of the engine's `cl_interp` history — which resets on every teleport and otherwise freezes the prop into an ~8 Hz stutter — snapping on entry and easing back to interpolation on exit. Records are armed off the `wp-teleport` hook (fired client-side from `linked_portal_door`'s `WorldPortals_Teleport` net receive; players excluded) and applied in a `Think` hook over `wp.renderFollow`; `cl_ghosts.lua`'s pose reads the `SetRenderOrigin` it sets. Accepted limit: a prop that leaves the loop still moving gets a brief freeze.

### Trace redirection (`sh_teleport.lua`)

Two things:

1. **`EntityFireBullets` hook** — bullets fired toward a portal get their `data.Src` and `data.Dir` rewritten to the exit-side, and `data.IgnoreEntity` is overwritten with whatever `wp-tracefilter` returns. Returning `true` from the hook tells the engine "use my modified data".
2. **`util.TraceLine` monkey-patch** — `util.RealTraceLine` captures the original; `util.TraceLine` becomes `WorldPortals_TraceLine` which, if a portal sits between start and hit, re-traces from the exit-side instead. Re-installed in `InitPostEntity` because some addons replace `util.TraceLine` themselves and we need to win the race.

The monkey-patch is global: every consumer's traces go through it whether they know about portals or not. Be deliberate when changing this — silent regressions affect every addon.

### Server: PVS and portal pairing (`sv_render.lua`)

- `SetupPlayerVisibility` adds the exit portal's origin to PVS for any player who can see the entry. Without this, the exit-side render target draws empty. This is the only way GMod allows out-of-PVS scenes to be visible.
- `PairWithExits` runs at `InitPostEntity` and `PostCleanupMap`: walks every `linked_portal_door` and `:SetExit(ents.FindByName(:GetPartnerName())[1])` if its exit is invalid. Required because Hammer load order isn't guaranteed and a portal may initialize before its partner exists.

### Server: portal-aware collision + collision frame (`sv_collision.lua`, `linked_portal_frame`)

A portal is usually mounted flush against a solid (a TARDIS shell, a back wall), and the teleport only fires once a prop's *centre* crosses the plane — so a decent-sized prop jams on that wall before it can cross. Two server-only pieces fix that; together with the ghosts (the visual half) a prop reads as passing cleanly through. There is intentionally **no collidable ghost** — a clientside entity can't block server props, and there's no per-face collision carving — so we make the real prop pass through the wall instead of faking a solid.

**Pass-through no-collide (`sv_collision.lua`).** While a *dynamic or physgun-held* prop touches an open teleport-enabled portal (armed from `ENT:Touch`, event-driven — no per-tick scan), it's `constraint.NoCollide`d with the wall entities so it passes through instead of jamming, then disarmed on `EndTouch` / portal close / disable / removal. State lives in `wp.nocollide[ent][portal]`; the API is `wp.ArmNoCollide` / `wp.DisarmNoCollide` / `wp.DisarmAllNoCollide` / `wp.DisarmPortal`. Walls are the portal's parent + its constraint network, unioned with whatever the `wp-nocollide` hook returns — but each candidate is only no-collided if it opts in with `ent.PortalNoCollide == true` (default-solid; see Conventions). Two sharp edges encoded here: (1) the already-armed check runs *before* `eligible()`, because the NoCollide makes the prop show up in the wall's constraint network and would fail the contraption guard on re-arm; (2) restoring collision must `Fire("EnableCollisions")` and then remove the `logic_collision_pair` *next frame* — a bare `:Remove()` leaves the VPhysics pair disabled forever (silent, permanent ghosting). A 2s safety timer disarms anything gone invalid or drifted away in case an `EndTouch` was ever missed.

**Collision frame (`linked_portal_frame`).** An invisible, server-built perimeter hull (`ENT:FrameSlabs` → 4 box slabs via `PhysicsInitMultiConvex`) that keeps a transiting prop funnelled through the opening cross-section while the wall is "removed" for it. Put in `COLLISION_GROUP_WEAPON` so it collides with props but **not players** (players keep their predicted-teleport path untouched), and built without `EnableCustomCollisions` (physics-vs-physics is all that's needed, and ECC would also block bullet/use traces against this invisible hull). Created/resized by the portal's `RebuildCollisionFrame`. Two non-obvious choices, both verified in-engine:
  - **Unparented.** A parented frame would sit under the portal's parent, and the prop↔shell no-collide disables the prop against *all* of the shell's parented descendants — so the prop would phase the frame the instant it armed ("loses collision with the frame as soon as it enters"). Keeping it unparented takes it out of that hierarchy; it follows the portal via its own `Think`, and `wp.NoCollideFrame` explicitly re-adds the **frame↔wall** no-collision it lost by unparenting (else its solid hull interpenetrates the shell and the solver launches the whole TARDIS). `NoCollideFrame` is deliberately *parent-only*, not the full constraint network, to avoid re-grabbing an armed transiting prop.
  - **Physics shadow, not a frozen static body.** `MakePhysicsObjectAShadow(false, false)` + `UpdateShadow` each tick, so a *moving* portal **pushes** props in the doorway along with it; a static `SetPos`'d hull teleported past props and flung them. A single-tick jump past `SHADOW_TELEPORT_DIST` (a demat/remat warp) can't be swept, so the hull snaps for that (mirroring the engine's own shadow teleport distance).

The client half of the frame (`cl_init.lua`) is debug-only: `worldportals_debug_collision` draws the slabs (rebuilt client-side from the portal's networked dimensions so they match the server hull). Together with `worldportals_debug_predict` (the teleport HUD) these are the two debug cvars.

### Client: view roll on teleport (`cl_teleport.lua`)

A combined `CalcView` hook handles three things: (a) view roll fade — reads `wp.rotating` (armed by the predicted SetupMove path / `wp.ArmTeleportView` when the new view has nonzero roll) and `math.Approach`es the roll back to 0 over a few frames so the world doesn't snap-rotate on landing; (b) predict-lerp shift — adds `(NetworkOrigin - ply:GetPos())` to the view origin while `wp.predictedPos` is armed (see "Predicted player teleport" above for why); (c) stair-smoothing strip — subtracts the engine's `SmoothViewOnStairs` eye-Z easing (measured as `pos.z - EyePos().z`, stashed in `wp.stairLeak`) for a brief window (`wp.stairStripAt`) after a grounded portal exit, so a portal landing's huge grounded Z change isn't read as one enormous stair step. All three deltas are mirrored onto the viewmodel via `CalcViewModelView` so the physgun/hands ride with the camera, and both hooks bail when `GetViewEntity() ~= ply` so a camera/monitor view is left untouched. The roll fade and stair strip arm in **both** realms (the singleplayer net handler in `cl_init.lua` calls `wp.ArmTeleportView`); the predict-lerp shift is prediction/ping-only (always nil in singleplayer). Pulling out the roll fade alone is fine; pulling out the predict-lerp shift reintroduces the blank-sky frame at high ping.

### Client: predicted-teleport debug HUD (`cl_predictdebug.lua`)

A developer HUD gated behind the `worldportals_debug_predict` cvar (default off). It buffers the last 5 predicted teleports (`wp.RecordTeleportEvent`, called from `sh_teleport.lua`) and the last server-broadcast position for the local player (`wp.RecordNetTeleport`, from `linked_portal_door`'s net receive), and renders per-frame ply state, the predict-lerp panel (shift / sanity / arm-disarm counts), and nearest-portal swept-test inputs. Useful for inspecting paused frames during a teleport — the live `EyeAng`/`Pos` vs the recorded `oldAng → newAng` / `oldPos → newPos` make it obvious whether prediction set what you expect, and the "last net broadcast" line fires if the server snapshot disagrees. The record calls are guarded (`if wp.RecordTeleportEvent then`), so the whole file is a clean delete once the instrumentation has outlived its use. (The arm/disarm counters it reads — `wp.predictArmCount` / `wp.predictDisarmReasons` — are maintained in `cl_teleport.lua`/`sh_teleport.lua` so removing this file can't break the predict path.)

### Optional integrations

- **`vrmod`** — only touched behind `if vrmod then` guards. The stub at `.luatypes/vrmod.lua` declares the three functions used (`IsPlayerInVR`, `GetOriginAng`, `SetOriginAng`). VR users get a yaw-offset rotation on teleport so their head doesn't whip around.
- **No CPPI, no WireLib.** This repo doesn't depend on either.

## Conventions when adding code

- **Pure Lua syntax only — no GMod-Lua extensions.** No `//` comments, no `continue`, no `!=`, no `&&`/`||`. Use `--`, `goto continue`, `~=`, `and`/`or`. Earlier code had `!=` in `sh_utils.lua` which the analyzer (and pure Lua parsers) reject; keep it that way.
- **Realm-prefix filenames.** `sh_`, `sv_`, `cl_` as prefixes. Suffix conventions break the analyzer's realm-awareness heuristic.
- **Comments: concise, why-not-what.** Keep comments to a couple of lines; reserve length for genuinely non-obvious rationale. Don't restate what the code plainly does. Keep the essential *why* inline and self-contained — don't send a code reader to an external doc (`memory/`, this file) they may not have; a code comment has to stand on its own. The hard-won why that isn't visible in the code is worth keeping; the wall of prose around it usually isn't.
- **For `pairs`/`ipairs` loops, drop the variable you don't use rather than naming it.** `for _, v in pairs(t)` discards the key, `for k in pairs(t)` discards the value, `for _ = 1, n do` for plain N-iteration. The `unused` lint is on so future dead `local x = expensive_call()` survivors get flagged — keep the noise floor at zero by using these forms.
- When monkey-patching engine globals (`util.TraceLine`, `render.RenderView`), capture the original under a `Real*` alias **once** before reassigning, and reinstall the patch in `InitPostEntity` so addons that load after us don't clobber it.
- Hooks fired for downstream consumers (`wp-shouldrender`, `wp-trace`, `wp-tracefilter`, `wp-shouldtp`, `wp-teleport`, `wp-allowthickportal`, `wp-shouldghost`, `wp-shouldghostdraw`, `wp-nocollide`, `wp-predraw`/`postdraw`, `wp-prerender`/`postrender`) all use `hook.Call(name, GAMEMODE, ...)`. Don't change the calling convention without updating consumers (Doors hooks all of these).
- `wp-shouldghost(ent)` (client, `cl_ghosts.lua`) gates whether a **NoDraw'd** prop still gets a continuous ghost. Default: NoDraw'd props are NOT ghosted (hidden for a reason). A consumer that hides a real, server-drawable prop only in the local realm returns `true` to opt it back in — Doors' cordon does this for the interior props it `SetNoDraw`s while the player is outside, so a prop straddling the interior portal still shows its emerged half out the exterior. Only fires for props that are currently `GetNoDraw()` (drawable props ghost unconditionally).
- `wp-shouldghostdraw(sourceEnt, ghostEnt, portal, exit)` (client, `cl_ghosts.lua`) is fired **inside the ghost's `RenderOverride`, once per render pass** — return `false` to skip drawing the ghost in that pass. It exists because a ghost's emerged half lands at `exit`, which may sit in a region a consumer hides from the open world (a Doors/TARDIS interior parked up in the skybox): there the ghost must draw only in the passes that reveal that region (its portal's RT), not the main scene where it would float visibly in empty sky. Consumers decide off `wp.drawingent` (the portal currently rendering), so this is evaluated per-draw and **must not be cached** — the answer differs between the main-scene pass and each portal RT pass within the same frame. Doors routes it (via `exit:GetParent()`) to a `ShouldDrawGhost` ENT hook on the interior, which mirrors the interior's own `ShouldDraw`. This is the clean lever for ghosts (ClientsideModels we draw via `RenderOverride`); it deliberately does **not** touch the `SetNoDraw` cordon, which consumers reserve for engine-native props whose drawing they can't override.
- `wp-shouldtp` and `wp-teleport` fire on **both client and server** for predicted player teleports, from inside `SetupMove`. `wp-shouldtp` fires once per crossing decision; `wp-teleport` fires on the client on **every prediction pass — first-time AND resim** (the server fires it once per command during its own gamemovement step). The client must re-fire it on resim so a consumer's position adjustment (e.g. Doors' unstick) re-applies each resim instead of reverting to the raw transform for the unacked window — so **`wp-teleport` consumers must be idempotent and resim-safe** (no sounds/effects/counters; pure deterministic position resolvers are fine). Consumers must register the hooks shared (Doors moved its `wp-shouldtp` registration out of an `if SERVER` block for this). Inner `CallHook` chains can stay server-only and return nil on the client; the client optimistically allows and the server is authoritative.
- `wp-nocollide(portal, ent)` (server, `sv_collision.lua`) lets a consumer return a **list of extra wall entities** a transiting prop should pass through, on top of the portal's parent + its constraint network. An entity is only actually no-collided if it also opts in with `ent.PortalNoCollide == true` — default-solid is deliberate, so a missed flag merely *jams* a prop (recoverable) instead of dropping it through an interior into the void. Two field contracts go with this: `ent.PortalNoCollide == true` marks a wall the pass-through may phase; `ent.WPIsGhost == true` marks a clientside ghost model (`cl_ghosts.lua`) so both the collision and ghost passes skip it. Don't repurpose either field.
- `wp-prerender` and `wp-postrender` fire as `(portal, exitPortal, plyOrigin, depth)` — the recursion depth (1 = top-level player view, 2+ = nested through-portal renders). Consumers that mutate engine state across the pre/post pair (e.g. cordon's `SetNoDraw` save/restore) MUST guard on `depth > 1` to skip nested renders, or the parent's saved state gets clobbered by a nested pre-render before the parent's post-render restores it.

## Tooling

`.luarc.json` configures `glua_ls` / `glua_check` (both on EmmyLua-Analyzer-Rust) with `./.tools/glua-api` (GLua type stubs) and `./.luatypes` (local override aliases and the `vrmod` stub). The recommended VS Code extension is `Pollux.gmod-glua-ls`.

### Type annotations

Patterns that matter for this codebase:

- **Trace redirection in `sh_teleport.lua`.** `util.RealTraceLine` returns a `TraceResult`, not the input `Trace`. Be careful with variable naming — calling it `trace` and then reading `trace.mask`/`trace.filter` looks fine but accesses fields that don't exist on `TraceResult` (this is a long-standing latent bug in `WorldPortals_TraceLine`; see the warning still surfaced by `glua_check`).
- **Field-access narrowing doesn't propagate.** `if not (data.Src and data.Dir and data.Distance) then return end` does NOT narrow `data.Src`/`Dir`/`Distance` on the lines below. To narrow, copy each into a local first, then null-check the locals, separated by lines (`if not src then return end` then `if not dir then return end` rather than a combined `and`-chain). Then use the locals downstream and reassign to `data.X` only when you genuinely want to mutate the input.
- **Trace struct casts.** Inline-built tables passed to `util.TraceLine`/`RealTraceLine` may not match the `Trace` struct because field-type narrowing is partial. When the surrounding logic is correct, an inline `--[[@as Trace]]` cast on the closing brace is cleaner than restructuring.
- **`.luatypes/`** — local LuaLS workspace stubs, picked up by `.luarc.json` `workspace.library`.
  - `glua_overrides.lua` aliases the integer enums (`COLLISION_GROUP`, `FORCE`, `STENCILOPERATION`, `STENCILCOMPARISONFUNCTION`) — glua-api-snippets ships them as string-literal unions, which breaks calls like `self:SetCollisionGroup(COLLISION_GROUP_WORLD)`. Also adds the missing 2-arg `table.insert(tbl, value)` overload (the upstream stub only declares the 3-arg form, so `table.insert(narrowly_typed_array, x)` mis-resolves and treats `x` as the position).
  - `vrmod.lua` declares the optional VR addon's three globals used here. All call sites guard with `if vrmod then`.

There is intentionally **no `diagnostics.disable` block in `.luarc.json`** — every rule earns its keep. Prefer code-level fixes or targeted annotations over global suppression.

### Claude Code LSP integration (`glua-lsp` plugin)

Diagnostics, hover, and jump-to-definition are provided via the [`glua-lsp` plugin](https://github.com/AmyJeanes/gmod-claude-plugins) (marketplace: `AmyJeanes/gmod-claude-plugins`). The plugin wraps the [`glua_ls`](https://github.com/Pollux12/gmod-glua-ls) language server — same EmmyLua-Analyzer-Rust engine as `glua_check`, just running long-lived. Diagnostics arrive automatically after every edit; no hook involvement.

`.claude/settings.json` declares `extraKnownMarketplaces` so contributors get prompted to install the plugin on first open. The plugin itself ships only configuration — two per-machine pieces are still needed and are not in source control.

#### First-time setup (do this before doing other work)

`scripts/install-tools.ps1` is the single source of truth for `glua_check`, `glua_ls`, and the GLua API stubs. Versions are pinned at the top of the script and shared with CI, so local and CI run the exact same engine.

In a fresh clone, run it once before touching `.lua` files:

```bash
pwsh -File scripts/install-tools.ps1
```

It is idempotent — re-running is a no-op when the pinned versions are already present, so it's also the recovery path when LSP diagnostics look wrong. The `glua-lsp` Claude Code plugin auto-resolves `glua_ls` from this project's `.tools/bin/` at LSP launch (no PATH plumbing needed); after a fresh install just `/reload-plugins`.

To bump a version: edit the `$GluaLsVersion` / `$GluaApiVersion` constants in `scripts/install-tools.ps1`, commit, and CI + every fresh clone picks it up. Renovate (`renovate.json` customManagers) also raises bump PRs automatically, gated by the GLua Check CI job.

The `glua-lsp:install-glua-ls` skill covers the same recovery flow if symptoms appear later. Treat reported diagnostics as actionable only if the edit caused them — pre-existing noise on unrelated lines is not in scope for the current change.

#### Workspace-wide scans with `glua_check`

`glua_ls` only analyzes files as they are opened/edited. To audit the whole repo at once, use `scripts/glua-check.ps1` — it installs the pinned tooling on demand (no-op when present) and runs `glua_check --warnings-as-errors` against the repo. CI calls the same script.

```bash
pwsh -File scripts/glua-check.ps1
```

`glua_check` only accepts a workspace root, not file/path filters, so the script always scans the whole repo.

Useful when a fix has rippled across the codebase or when picking up the project to find latent issues the LSP hasn't surfaced yet.
