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
2. Manually `include`s every file in `lua/worldportals/`, dispatching by filename prefix:
   - `sh_*.lua` — both realms; `AddCSLuaFile`'d on the server.
   - `sv_*.lua` — server only.
   - `cl_*.lua` — client only; `AddCSLuaFile`'d.

There is no folder-scanning loader. Adding a new file means adding its `include`/`AddCSLuaFile` line to `worldportals_init.lua`. Keep the realm-prefix convention — the static analyzer's realm-mismatch heuristic uses it (and the consumer addon Doors depends on it for its own scanner).

### `wp.*` API surface (all in `sh_utils.lua` unless noted)

Math helpers used by both the entity and downstream consumers:

- `wp.IsBehind(pos, plane_pos, plane_forward) → boolean` — half-space test.
- `wp.IsLookingAt(portal, portal_pos, view_pos, view_ang, view_fov) → boolean` — frustum/cone test, used to skip rendering portals the camera can't see.
- `wp.DistanceToPlane(pos, plane_pos, plane_forward) → number` — signed distance.
- `wp.TransformPortalPos(vec, portal, exit_portal) → Vector` — relative to entry, mirrored 180°, applied to exit (with `GetExitPosOffset`/`GetExitAngOffset` accounted for).
- `wp.TransformPortalVector(vec, portal, exit_portal) → Vector` — direction-only variant.
- `wp.TransformPortalAngle(angle, portal, exit_portal) → Angle` — rotates an angle through a portal pair.
- `wp.GetFirstPortalHit(source, direction) → {Entity, Distance, HitPos}` — ray-vs-portal-plane scan over `ents.FindByClass("linked_portal_door")`.

Plus rendering state and helpers in `cl_render.lua`:

- `wp.matBlack`, `wp.matTrans`, `wp.matInvis`, `wp.matView`, `wp.matView2` — runtime-created materials.
- `wp.portals` — cached list, refreshed each `RenderScene`.
- `wp.drawing` — re-entrancy guard set during `render.RenderView` calls so the entity's `Draw` skips work.
- `wp.rendermode` — true while inside `RealRenderView`, used by `Draw` to pick the simpler material path.
- `wp.shouldrender(portal, camOrigin?, camAngle?, camFOV?)` — runs the full visibility decision and fires the `wp-shouldrender` hook to allow override.
- `wp.renderportals(plyOrigin, plyAngle, w, h, fov)` — renders every portal's exit-view to its texture.

### Entity: `linked_portal_door`

Three files:
- `shared.lua` — type/render group, `Initialize`, `SetupBounds` (recomputes render/collision bounds + the 5 quads used for inverted/thick rendering), and the `SetupDataTables` block that creates every networked field (`Exit`, `Width`, `Height`, `Thickness`, `Transparency`, `ZFar`, `Open`, `EnableTeleport`, `Inverted`, `CustomLink`, `ExitPosOffset`/`ExitAngOffset`, `ModelPos`/`ModelAng`). `NetworkVarNotify`s rebuild bounds when width/height/thickness change.
- `init.lua` (server) — `KeyValue` handles Hammer entity I/O (`partnername`, `width` ×2, `height` ×2, `thickness`, `DisappearDist`, `angles`, `EnableTeleport`, `Open`, output `On*` are forwarded to `StoreOutput`); `Touch` teleports **non-player entities only** (props, NPCs, ragdolls — players go through the predicted SetupMove path in `sh_teleport.lua`): entry-side check via `DistanceToPlane`, fires the `wp-shouldtp` hook for veto, transforms pos/velocity/angle, special-cases ragdolls by snapshotting all physics objects' local pose then re-applying after `SetPos`, broadcasts `WorldPortals_Teleport` so clients update the entity's position immediately rather than waiting for the snapshot. `AcceptInput` handles the Hammer inputs.
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
6. Apply: `mv:SetOrigin(newPos)`, `mv:SetVelocity(newVel)`, `mv:SetAngles(clampedAng)`, `ply:SetEyeAngles(clampedAng)`, `cmd:SetViewAngles(clampedAng)`. **All four mutations matter**: `mv:SetOrigin/SetVelocity` drive the move; `mv:SetAngles` is what gamemovement reads to interpret W/S/A/D direction (without it the engine still uses the pre-teleport view, causing a "skid" on direction-changing portals); `ply:SetEyeAngles` is what actually rotates the camera (`cmd:SetViewAngles` alone only mutates the input cmd struct); `cmd:SetViewAngles` keeps the next move's input direction consistent.
7. On first-time-predicted client OR on server: also call `ply:SetPos(newPos)`. `mv:SetOrigin` updates the move buffer but **doesn't reset the entity's AbsOrigin interpolation cache**, so without this `ply:GetPos()` lerps from old to new over a few frames (visible as a position slide). `ply:SetPos` is the canonical snap path — same one the broadcast hits for remote clients. Skipped during resimulation.
8. Server branch: VR yaw offset (`WorldPortals_VRMod_SetAngle`), `ForcePlayerDrop`, entity outputs, `wp-teleport` hook, broadcast `WorldPortals_Teleport`.
9. First-time-predicted client branch: roll fade trigger (`wp.rotating = newAng.r` for `cl_teleport.lua`'s `CalcView` to interpolate down), predict-lerp arm (`wp.predictedPos = newPos`, `wp.predictedAt = CurTime()` — see below), `wp-teleport` hook, debug-HUD record.

Non-player entities still go through `ENT:Touch` in `init.lua` — they can't be client-predicted (server-authoritative VPhysics).

**Predict-lerp shift window.** `ply:SetPos(newPos)` resets the entity AbsOrigin interp cache but doesn't override the engine's snapshot-driven origin lerp. At high ping (~`net_fakelag 100` = 200ms RTT) a snapshot captured *before* the server ran SetupMove for the predicting command arrives at the client showing the pre-teleport pos, and `ply:GetPos()` lerps from there to the predicted pos for ~RTT. While that lerp is in flight the eye is at the wrong location — `eye-in-renderbounds` against a destination interior fails (blank-sky / black frame), and frustum culling against world geometry uses the wrong origin. Lua can't disable this engine lerp (`cl_smooth`/`cl_interp 0`/`EF_NOINTERP` all do nothing — see `memory/reference_predict_engine_limits.md`).

Mitigation: arm a shift window from the SetupMove path (`wp.predictedPos`, `wp.predictedOldPos`, `wp.predictedAt`). `cl_teleport.lua`'s `CalcView` and `CalcViewModelView` each compute `delta = ply:GetNetworkOrigin() - ply:GetPos()` per frame and add it to the view origin / viewmodel origin respectively, parking the camera at `NetworkOrigin` (the server-known current position) while the engine drifts `GetPos` through wild intermediate values. The world (and bounds checks against it) renders from the right place, and the viewmodel rides with the camera.

Why `NetworkOrigin` and not `predictedPos`: `predictedPos` is a static target captured at teleport time. As the player keeps walking forward, `GetPos` overshoots it and `predictedPos - GetPos` grows again — using a static target locks the camera at the exact teleport point and "freezes" the view for the disarm window. Convergence detection (disarm when `|delta|<threshold`) was also tried and failed: engine drift is **non-monotonic** (snap → drift back partway → drift forward → settle), so `|delta|` dips below threshold and re-exceeds it, and the convergence-disarm fires on the dip, leaving the next drift wave unmasked. `NetworkOrigin` tracks the live "where the player should be" so the shift naturally goes to zero on real convergence, no dance required.

Sanity guard: at the very first frames after arm, the post-teleport snapshot may not have arrived yet on the client, leaving `NetworkOrigin` at the pre-teleport pos. Applying `NetworkOrigin - GetPos` there would yank the camera *backward* to oldPos. We capture `wp.predictedOldPos = origin` at arm and check `(NetOrigin - predictedPos):LengthSqr() < (NetOrigin - oldPos):LengthSqr()` — if NetOrigin is closer to oldPos than to predictedPos, skip the shift and let `GetPos` (just snapped to newPos by `ply:SetPos`) render through. Surfaced as `sanity=SANITY-FAIL` in the debug HUD.

Disarm: pure `SysTime`-based timeout (0.5s). No convergence detection. Once `GetPos` catches up the shift is a no-op anyway, so leaving the window armed through the timeout is harmless. The earlier convergence-disarm fired too eagerly during the non-monotonic drift; pure timeout is simpler and reliable.

Time bookkeeping uses `SysTime()`, not `CurTime()`: inside `SetupMove` the engine advances `CurTime()` to the predicted-tick time, so `CurTime()` recorded there is "in the future" relative to `CurTime()` in `CalcView` — comparing the two yields negative ages and incorrect timeouts.

Time bookkeeping uses `SysTime()`, not `CurTime()`: inside `SetupMove` the engine advances `CurTime()` to the predicted-tick time, so `CurTime()` recorded there is "in the future" relative to `CurTime()` in `CalcView` — comparing the two yields negative ages and incorrect timeouts.

Caveat: `SetRenderOrigin` is a no-op for the local playermodel (verified empirically — works on props, ignored on `LocalPlayer`). So the local model itself still lerps; we don't try to drag it. This is invisible in first-person and only briefly visible in mirrors/portal-exit reflections looking back. Both `CalcView` and `CalcViewModelView` reuse a `getPredictDelta(ply)` helper that performs the timeout/convergence check and clears `wp.predictedPos`/`wp.predictedAt` once the window ends. `wp.predictedPos` value itself is unused by the shift logic — it's only kept as the arm flag (and surfaced in the debug HUD).

### Trace redirection (`sh_teleport.lua`)

Two things:

1. **`EntityFireBullets` hook** — bullets fired toward a portal get their `data.Src` and `data.Dir` rewritten to the exit-side, and `data.IgnoreEntity` is overwritten with whatever `wp-tracefilter` returns. Returning `true` from the hook tells the engine "use my modified data".
2. **`util.TraceLine` monkey-patch** — `util.RealTraceLine` captures the original; `util.TraceLine` becomes `WorldPortals_TraceLine` which, if a portal sits between start and hit, re-traces from the exit-side instead. Re-installed in `InitPostEntity` because some addons replace `util.TraceLine` themselves and we need to win the race.

The monkey-patch is global: every consumer's traces go through it whether they know about portals or not. Be deliberate when changing this — silent regressions affect every addon.

### Server: PVS and portal pairing (`sv_render.lua`)

- `SetupPlayerVisibility` adds the exit portal's origin to PVS for any player who can see the entry. Without this, the exit-side render target draws empty. This is the only way GMod allows out-of-PVS scenes to be visible.
- `PairWithExits` runs at `InitPostEntity` and `PostCleanupMap`: walks every `linked_portal_door` and `:SetExit(ents.FindByName(:GetPartnerName())[1])` if its exit is invalid. Required because Hammer load order isn't guaranteed and a portal may initialize before its partner exists.

### Client: view roll on teleport + debug HUD (`cl_teleport.lua`)

A combined `CalcView` hook handles two things: (a) view roll fade — reads `wp.rotating` (set by the predicted SetupMove path when the new view has nonzero roll) and `math.Approach`es the roll back to 0 over a few frames so the world doesn't snap-rotate on landing; (b) predict-lerp shift — adds `(predictedPos - ply:GetPos())` to view origin while `wp.predictedPos` is armed (see "Predicted player teleport" above for why). The same delta is applied to the viewmodel via `CalcViewModelView` so the physgun/hands ride with the camera. Pulling out the roll fade alone is fine; pulling out the predict-lerp shift will reintroduce the blank-sky frame at high ping.

The same file owns the predicted-teleport debug HUD, gated behind the `worldportals_debug_predict` cvar. It buffers the last 5 SetupMove-driven teleports (`wp.RecordTeleportEvent`) and the last server broadcast position for the local player (`wp.RecordNetTeleport`), and renders per-frame ply state + nearest-portal swept-test inputs. Useful for inspecting paused frames during a teleport — the live `EyeAng`/`Pos` lines vs the recorded `oldAng → newAng` / `oldPos → newPos` make it obvious whether prediction set what you expect, and the "last net broadcast" line will fire if server snapshot disagrees.

### Optional integrations

- **`vrmod`** — only touched behind `if vrmod then` guards. The stub at `.luatypes/vrmod.lua` declares the three functions used (`IsPlayerInVR`, `GetOriginAng`, `SetOriginAng`). VR users get a yaw-offset rotation on teleport so their head doesn't whip around.
- **No CPPI, no WireLib.** This repo doesn't depend on either.

## Conventions when adding code

- **Pure Lua syntax only — no GMod-Lua extensions.** No `//` comments, no `continue`, no `!=`, no `&&`/`||`. Use `--`, `goto continue`, `~=`, `and`/`or`. Earlier code had `!=` in `sh_utils.lua` which the analyzer (and pure Lua parsers) reject; keep it that way.
- **Realm-prefix filenames.** `sh_`, `sv_`, `cl_` as prefixes. Suffix conventions break the analyzer's realm-awareness heuristic.
- **For `pairs`/`ipairs` loops, drop the variable you don't use rather than naming it.** `for _, v in pairs(t)` discards the key, `for k in pairs(t)` discards the value, `for _ = 1, n do` for plain N-iteration. The `unused` lint is on so future dead `local x = expensive_call()` survivors get flagged — keep the noise floor at zero by using these forms.
- When monkey-patching engine globals (`util.TraceLine`, `render.RenderView`), capture the original under a `Real*` alias **once** before reassigning, and reinstall the patch in `InitPostEntity` so addons that load after us don't clobber it.
- Hooks fired for downstream consumers (`wp-shouldrender`, `wp-trace`, `wp-tracefilter`, `wp-shouldtp`, `wp-teleport`, `wp-allowthickportal`, `wp-predraw`/`postdraw`, `wp-prerender`/`postrender`) all use `hook.Call(name, GAMEMODE, ...)`. Don't change the calling convention without updating consumers (Doors hooks all of these).
- `wp-shouldtp` and `wp-teleport` fire on **both client and server** for predicted player teleports — the client fires gated on `IsFirstTimePredicted()` from inside `SetupMove`, the server fires from the same path during its own gamemovement step. Consumers must register the hooks shared (Doors moved its `wp-shouldtp` registration out of an `if SERVER` block for this). Inner `CallHook` chains can stay server-only and return nil on the client; the client optimistically allows and the server is authoritative.
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
