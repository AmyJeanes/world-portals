# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Garry's Mod (Lua) addon shipping the `linked_portal_door` entity and a small `wp.*` runtime library. The portal renders one location through another (stencil mask + render-target texture) and optionally teleports anything crossing it. Lives in-place at `garrysmod/addons/world-portals`; no build step — GMod loads the `lua/` tree at server start.

This is the **base layer** other addons build on. The main consumer is `AmyJeanes/Doors` (TARDIS-style doors): it builds exterior↔interior teleporting on `linked_portal_door` and uses `wp.TransformPortal*` for view/velocity transforms. Doors' CI combines both repos into one Workshop upload, so paths here can collide with Doors at upload time (consumer wins) — hence no `addon.json`. `.github/workflows/ci.yml` runs `glua_check` on push/PR to `dev`.

## Architecture

### Module layout

`lua/autorun/worldportals_init.lua` is the only entry point: creates the `wp` namespace (one global table), then `wp.LoadFolder("worldportals")` — a folder scanner dispatching each `*.lua` by filename prefix: `sh_` (both realms, AddCSLuaFile'd), `sv_` (server), `cl_` (client, AddCSLuaFile'd). No recognised prefix → silently skipped, so the prefix is **mandatory**. Also `wp.LoadFolder("worldportals/falseworlds", true)` — the `noprefix` form that include+AddCSLuaFile's everything regardless of name (false-worlds extension point; ships only `example.lua`).

**Adding a file under `lua/worldportals/` needs no init edit** — give it a realm prefix and it's picked up. Keep the prefix convention: the loader, the analyzer's realm heuristic, and Doors' own scanner all depend on it. Entities under `lua/entities/` (`linked_portal_door`, `linked_portal_frame`) auto-load via GMod.

### `wp.*` API (in `sh_utils.lua` unless noted)

- `wp.IsBehind(pos, plane_pos, plane_fwd)` — half-space test.
- `wp.IsLookingAt(portal, portal_pos, view_pos, view_ang, view_fov)` — frustum/cone test to skip off-screen portals.
- `wp.DistanceToPlane(pos, plane_pos, plane_fwd)` — signed distance.
- `wp.TransformPortalPos/Angle(x, portal, exit)` — through-portal transform (WorldToLocal → 180° yaw mirror → LocalToWorld, with `GetExitPosOffset`/`GetExitAngOffset`).
- `wp.TransformPortalVector(vec, portal, exit)` — direction-only (velocity), same pipeline so a real rotation at any pitch/yaw/roll. **The old `exit:GetAngles() - portal:GetAngles()` Euler-subtraction form flipped velocity on floor/ceiling/rolled pairs (the infinite-fall bounce) — don't go back to it.**
- `wp.GetFirstPortalHit(source, dir)` — ray-vs-portal-plane scan over `wp.portals`.

Allocation-free variants in `cl_render.lua` read per-portal cached basis scalars instead of calling engine `WorldToLocal`: `wp.TransformPortalPosInto(out, ...)` / `wp.TransformPortalAngleInto(out, ...)` write into a caller-owned Vector/Angle for hot paths.

`cl_render.lua` state: materials `wp.matBlack/matTrans/matInvis/matView/matView2`; `wp.drawing` (re-entrancy guard set during `render.RenderView`); `wp.rendermode` (true inside `RealRenderView`); `wp.renderparent` (scan-phase: the portal whose exit-view is being filled, nil at top level - the counterpart to draw-phase `wp.drawingent`, which is nil during the scan, so a `wp-shouldrender` veto reads `wp.renderparent` for render direction); `wp.shouldrender(portal, ...)` (visibility decision + `wp-shouldrender` hook); `wp.renderportals(...)`.

`wp.portals` (in `sh_portals.lua`) is a maintained array of live portals — registered from each portal's shared `Initialize`, deregistered via `EntityRemoved`, rebuilt fresh on change (never mutated in place, so a held reference survives mid-iteration), re-discovered on hot-reload. Hot paths iterate it instead of `ents.FindByClass` per tick/frame.

### Entity: `linked_portal_door`

- `shared.lua` — `Initialize` (registers in `wp.portals`, forces `Inverted` on), `SetupBounds` (render/collision bounds + the 5 quads of the inverted cavity). Every portal renders as an inverted cavity at least 5u deep, so the near-Z clip can't slice the stencil mask to nothing as the eye approaches (the flat-portal gap). `SetDepth(d)` is the modern API — a cavity `d` deep (clamped to a 5u floor; `Depth == 0` is the unset sentinel) behind an opening at `SetFaceOffset(o)` (render-only, `0` = flush with `GetPos`, negative = recessed; it **never moves `GetPos`, the wormhole/teleport plane**, so a legacy `Thickness` portal migrates to `depth + faceoffset` with its exit unshifted). Legacy `Thickness` / the `thickness` keyvalue is a back-compat shim: `SetupBounds` keeps the exact authored face (`RenderMax.x = max(-(5+thk), -5)`) and only adds depth *behind* it (`RenderMin.x = face - max(5, |thk|)`), never moving the face — so the ~271 community interiors render unshifted (a thickness-omitting portal stays at the legacy `-5` recess, only gap-fixed). It also stores `SeamOffset` (legacy `5+thk`, modern `d - faceoffset`) and `LogicDepth` (legacy `max(0,thk)`, modern `d`) so the ghost seam (`cl_ghosts`), teleport `backLimit` (`sh_teleport`), and back-cull (`cl_render`) read each portal's legacy plane, not the deepened cavity. `SetupDataTables` (networked fields: `Exit`, `Width/Height`, `Thickness` (legacy), `Depth` (modern), `FaceOffset` (modern, render-only opening offset), `Transparency`, `ZFar`, `Open`, `EnableTeleport`, `Inverted` (always-on; `SetInverted` is a no-op, forced true in `Initialize` via the captured raw setter so `GetInverted` read-back stays honest), `CustomLink`, `ExitPosOffset/ExitAngOffset`, `ModelPos/ModelAng`). Width/Height/Thickness/Depth/FaceOffset notifies rebuild bounds + (server) the collision-frame hull (passing the door's `LogicDepth` as the corridor depth); `Open`/`EnableTeleport` notifies call `wp.DisarmPortal` when the portal goes closed/non-teleporting so a mid-pass-through prop isn't left no-collided through a now-solid parent.
- `init.lua` (server) — `KeyValue` (Hammer I/O), `Touch` teleports **non-player entities only** (players use the predicted SetupMove path): entry-side `DistanceToPlane` check, `wp-shouldtp` veto, transform pos/vel/angle, ragdoll physics-object pose snapshot/re-apply around `SetPos`, broadcast `WorldPortals_Teleport`. `Touch` also arms the pass-through no-collide for a dynamic/held prop and pre-arms the exit on teleport; `EndTouch` disarms. `RebuildCollisionFrame` (from `Initialize`) creates the `linked_portal_frame` child; `OnRemove` tears it down (unparented, so not auto-removed).
- `cl_init.lua` — `Draw` is the stencil dance. No model (error.mdl marker) → the inverted-cavity quads (one render path; the old flat-quad / solid-box branches are gone now that every portal is an inverted cavity); model assigned → `render.Model`. Under `wp.rendermode` (inside another portal's RenderView) it uses the simpler `matView2` path instead of stenciling. Net receives: `WorldPortals_VRMod_SetAngle` (VR yaw), `WorldPortals_Teleport` (mirrors server `SetPos`/`SetAngles` for remote clients; skipped for `LocalPlayer` who predicted it — instead records via `wp.RecordNetTeleport` for the debug HUD).

### Stencil rendering pipeline (`cl_render.lua`) — most fragile piece

Per frame: `render.RenderView` is monkey-patched to first render every portal's exit-view to its RT (recursively; `wp.drawing` guards prevent infinite recursion), then pass through to `RealRenderView`. `wp.renderportals` iterates portals `wp.shouldrender` accepts: push RT → push a clip plane at the exit back-face → compute camera by `TransformPortal*`-ing the view → set `zfar` from portal/exit distance → recursive `RenderView` with `viewid = 1` (`VIEW_3DSKY`, the trick that avoids HUD/postprocess). Phys-gun glow is zeroed during the loop. `RenderScene` calls `renderportals` for the eye view; `PreDrawHalos` returns false while `wp.drawing`. The order and the `wp.drawing`/`wp.rendermode` guards are why nearly every callback checks them first.

### Predicted player teleport (`sh_teleport.lua`)

Players teleport in a `SetupMove` hook running in the prediction loop on both realms (LocalPlayer only client-side), so the local view stays in lockstep without waiting for a snapshot. Non-player entities can't be client-predicted (server-authoritative VPhysics) — they stay on `ENT:Touch`.

Per-tick: skip dead/near-zero-velocity; per portal skip closed/no-teleport/no-exit/not-approaching (`velocity:Dot(fwd) >= 0`); fire on a **swept crossing of the `portal:GetPos()` plane** by the eye OR the hull centre (eye is the anti-cull guard — same plane `wp.shouldrender` culls on, so firing here beats the cull; centre catches jump-over and floor-portal cases); in-face bounds check (eye OR centre); `wp-shouldtp` veto.

Then apply, with these hard-won rules — **don't "simplify" them away**:
- `mv:SetOrigin/SetVelocity/SetAngles` + `cmd:SetViewAngles` every pass. `mv:SetAngles` is what gamemovement reads for WASD direction (without it, direction-changing portals skid); safe to re-apply on resim.
- `ply:SetPos(newPos)` **every pass** (server + client first-time AND resim): resets the AbsOrigin interp cache `mv:SetOrigin` doesn't touch, and makes `ply:GetPos()` report the destination before `wp-teleport` runs so a consumer unstick resolves against it. (First-time-only left the origin at the raw transform on resim → high-ping stuck-after-teleport.)
- `ply:SetEyeAngles(clampedAng)` **client-only, first-time-only** (or server-only in singleplayer, which runs no client prediction). It's what actually rotates the camera (`cmd:SetViewAngles` alone no-ops it); the rotated angle rides out in subsequent cmds so the server converges on its own. *First-time only* because it writes a persistent field — re-writing on resim clobbers mouse moved since. *Not server* because a server write makes it authoritative and the snapshot pushes it back ~RTT later, overriding in-flight mouse (confirmed snap-back; a server write was tried and reverted).
- Server branch: VR yaw, `ForcePlayerDrop`, outputs, `wp-teleport`, mv re-sync (re-read `ply:GetPos()` so a consumer relocation survives FinishMove), broadcast.
- Client branch, **every pass**: `wp-teleport` + the same mv re-sync — a consumer unstick (Doors) relocates via `ply:SetPos` inside `wp-teleport` and must re-apply each resim or FinishMove reverts to the raw (often embedded) pos for the ~RTT the crossing command stays unacked. The unstick is a deterministic idempotent resolver, so re-running is safe. **Consumers' `wp-teleport`/`PostTeleportPortal` handlers must be idempotent and resim-safe.**
- Client branch, **first-time only**: arm roll fade (`wp.rotating`), predict-lerp window (`wp.predictedPos/At`), debug record — persistent client-frame state that must NOT re-fire on resim (every resim is the same frame).

**Accepted limits — documented so they're not re-attempted:**
- *High-ping angle contamination.* A predicted teleport at high ping can double-rotate or rotate-and-roll-back the player: client `SetEyeAngles` feeds forward into the next cmds, and prediction tolerance lets the server cross on a *different* command than the client, so the "late" realm reads an already-rotated viewangle. Not cleanly fixable in Lua (predicted DT vars flow server→client only, no clean-angle channel back). Don't retry: the inference fix (reject `view ≈ TransformPortalAngle(stored)`) false-positives on the genuine exit approach and latches a stale angle; the clean fix (carry rotation as a render+movement offset, never rotate `m_angEyeAngles`) needs a global `EyeAngles` override that breaks every consumer's aim.
- *Predict-lerp shift.* `ply:SetPos` doesn't override the engine's snapshot origin lerp: at high ping a pre-teleport snapshot makes `ply:GetPos()` lerp from the old pos for ~RTT (blank-sky frames, wrong frustum origin). Lua can't disable this lerp. Mitigation: `cl_viewcorrections.lua`'s `CalcView`/`CalcViewModelView` shift the camera/viewmodel by `GetNetworkOrigin() - GetPos()` while `wp.predictedPos` is armed, parking the camera at the server-known pos. Use `NetworkOrigin`, not the static `predictedPos` (which freezes the view as the player walks on). Sanity guard: if `NetworkOrigin` is still nearer `predictedOldPos` than `predictedPos` the snapshot hasn't arrived — skip the shift (else it yanks the camera back to oldPos). Disarm is a pure 0.5s `SysTime` timeout — convergence detection failed (engine drift is non-monotonic, so `|delta|` dips below threshold and re-exceeds, firing the disarm early). Use `SysTime`, not `CurTime` (`CurTime` in SetupMove is the future predicted-tick time). `SetRenderOrigin` is a no-op on the local playermodel (works on props), so the local model still lerps — invisible first-person, briefly visible in mirrors.
- *Residual NetworkOrigin stutter.* `NetworkOrigin` isn't interpolated for the local player, so during fast post-teleport motion the camera steps along server ticks (~7u at 500 u/s, converges, no lasting desync). A threshold-gated blend-out would fix it but touches this fragile logic and a naive convergence-disarm already regressed once → left as-is.
- *Noclip re-teleport cooldown.* `FullNoClipMove` discards `mv:SetVelocity`, so the mirrored exit velocity never takes and a same-facing pair (TARDIS) ping-pongs forever. A 0.25s `NOCLIP_TP_COOLDOWN` (resim-safe via `since > 0`) suppresses the immediate re-fire. The thick-volume `backLimit` allowance is also dropped in noclip (no collision to trap a noclipper, so it just reopens the bounce).
- *Deferred — zero-velocity static net.* A player standing dead-still on a floor portal never crosses (the velocity gate + swept test only fire on motion). A static-rest path was scoped but not built; known gap, not a regression.

### Portal ghosts (`cl_ghosts.lua`) — continuous entity rendering

Client-only visual layer so an entity straddling a portal reads as one body instead of being cut off at the opening. Renders **two clipped halves**: the real entity (`RenderOverride` clipping to `+entry_forward`) and a clientside **ghost** (`ClientsideModel`, flagged `WPIsGhost`) at the mirror-transformed exit pose clipping to `+exit_forward`. The seam sits on each portal's stored `SeamOffset` plane (`SetupBounds`: legacy `5 + thickness`, modern the `SetDepth` depth), measured back from `GetPos` along forward, so it tracks the authored geometry rather than the deepened render cavity. Decoupled from the teleport — straddling is a per-frame geometry test (`straddles`: cheap OBB-centre-in-opening, plus a 12-edge OBB-vs-plane clip for long/off-axis props).

- **Discovery** on a throttled `Think` (~25 Hz): `ents.FindInSphere` per open teleport-enabled portal, gated by `isCandidate` (prop_physics/ragdoll/NPC/player incl. local; skips dead players, our ghosts, and NoDraw'd props - a NoDraw'd prop would ghost as a bodiless emerged half) and `wouldTeleport` (the same `wp-shouldtp` veto — position-independent, the right "portal off" signal; NOT `wp-shouldrender`, which is view-dependent and would vanish the ghost inside an interior).
- **Pose** re-applied every frame in `PreDrawOpaqueRenderables` (after `cl_renderfollow`'s render-follow finalises the original's transform), reading the original's *render* transform. Rigid props: one `SetPos`/`SetAngles`. Skeletal (ragdoll/NPC/player): per-bone via `copyBonesThroughPortal`, which composes the portal transform once as a `VMatrix` (`exitFrame * yaw180 * entryFrame:GetInverseTR()`) and applies `M * GetBoneMatrix(i)` per bone — done inside the `RenderOverride` because `SetBoneMatrix` is consumed by the next `DrawModel`. A held weapon is mirrored as a second sub-ghost.
- **Records** (`wp.ghosts[ent]`) carry a 0.1s anti-flicker grace, are re-pointed to the new pair the instant the entity teleports (the `wp-teleport` hook updates `rec.portal/exit` before render, killing a one-frame flicker), and tear down on expiry/`EntityRemoved` (restoring the saved `RenderOverride`). `wp.IsGhosting(ent)` reports whether a record exists - a consumer that also drives the entity's `RenderOverride` (Doors' cordon) yields the slot while it's true.
- **Local player:** ghost is the emerged half, shown in third-person/external/RT/recursion, suppressed only in the view looking straight through the transited portal (`localGhostIsCutaway`). Player colour via overriding `GetPlayerColor` on the ghost (`SetPlayerColor` errors on a `ClientsideModel`).
- Convars `worldportals_ghosts` (master) / `worldportals_show_self` (own body; created in `cl_render.lua`, also gates `ShouldDrawLocalPlayer` so off = no self-reflection in RTs). Consumer hook `wp-shouldghostdraw` under Conventions.

### Rapid-loop interp bypass (`cl_renderfollow.lua`)

A non-player prop teleporting twice within `RAPID_WINDOW` (a tight floor↔ceiling loop) renders at its live `GetNetworkOrigin/Angles` instead of the engine's `cl_interp` history (which resets each teleport and freezes the prop into an ~8 Hz stutter) — snapping on entry, easing back on exit. Armed off `wp-teleport` (client, players excluded); applied in a `Think` over `wp.renderFollow`; `cl_ghosts` pose reads the `SetRenderOrigin` it sets. Accepted limit: a prop leaving the loop still moving gets a brief freeze.

### Trace redirection (`sh_teleport.lua`)

1. **`EntityFireBullets`** — bullets toward a portal get `data.Src`/`Dir` rewritten exit-side, `data.IgnoreEntity` set from `wp-tracefilter`; return `true` so the engine uses the modified data.
2. **`util.TraceLine` monkey-patch** — `util.RealTraceLine` captures the original; `WorldPortals_TraceLine` re-traces from the exit if a portal sits between start and hit. Re-installed in `InitPostEntity` to win the race against addons that also replace `util.TraceLine`.

The monkey-patch is **global** — every consumer's traces go through it. Be deliberate; silent regressions hit every addon.

### Server: PVS & pairing (`sv_render.lua`)

- `SetupPlayerVisibility` adds the exit origin to PVS for anyone who can see the entry — the only way GMod allows the out-of-PVS exit scene to render (else the RT draws empty).
- `PairWithExits` (at `InitPostEntity` + `PostCleanupMap`) sets each portal's exit by partner name if invalid — Hammer load order isn't guaranteed.

### Server: portal-aware collision (`sv_collision.lua`, `linked_portal_frame`)

A portal is usually parented to a solid structure (e.g. a shell), and the teleport only fires once a prop's centre crosses — so a big prop jams on that parent first. Two server pieces fix it (no collidable ghost exists — a clientside entity can't block server props); with the visual ghosts, a prop reads as passing through.

**Pass-through no-collide.** While a dynamic/held prop touches an open teleport-enabled portal (armed from `ENT:Touch`, event-driven), it's `constraint.NoCollide`d with the solids `wp-nocollide` returns, disarmed on `EndTouch`/close/disable/removal. State: `wp.nocollide[ent][portal]`; API `wp.ArmNoCollide`/`DisarmNoCollide`/`DisarmAllNoCollide`/`DisarmPortal`. Phase solids = exactly what `wp-nocollide` returns — the consumer owns the decision (its structure may not be engine-parented to the portal); omitting an entity keeps it solid (default-solid), so a missed one jams the prop rather than voiding it. Two sharp edges: (1) the already-armed check runs **before** `eligible()`, because the NoCollide makes the prop appear in the parent's constraint network and would fail the contraption guard on re-arm; (2) the `NoCollide` is created with `disableOnRemove = true` (5th arg) so a bare `:Remove()` re-enables the pair — without it, `:Remove()` leaves the VPhysics pair disabled forever (silent permanent ghosting). A sleeping prop isn't re-tested by triggers, so a portal moving out from under one never fires its `EndTouch`; a `Tick` handler wakes armed props whose portal moved so the trigger re-evaluates and disarms them.

**Collision frame (`linked_portal_frame`).** Invisible server-built perimeter hull (`FrameSlabs` → 4 box slabs via `PhysicsInitMultiConvex`) funnelling a transiting prop through the opening while the parent is "removed" for it. `COLLISION_GROUP_WEAPON` (hits props, not players — players keep their predicted path), no `EnableCustomCollisions` (physics-vs-physics suffices; ECC would block bullet/use traces). Created/resized by `RebuildCollisionFrame`/`BuildFrame`. Two verified choices:
- **Unparented** — a parented frame would be a descendant of the parent, so the prop↔parent no-collide would phase the frame the instant a prop armed. Unparented, it follows via its own `Think`; `wp.NoCollideFrame` re-adds the frame↔parent no-collide it loses (else the solid hull interpenetrates the parent and the solver shoves it), **parent-only** so it doesn't grab an armed transiting prop. `BuildFrame` recreates the physobj, which orphans that no-collide (a `logic_collision_pair` fires its disable once and never reapplies, and stays valid so `NoCollideFrame`'s IsValid check won't replace it) — so `BuildFrame` drops + re-adds it. (Tested: the orphaned state doesn't shove a *settled* parent, but it leaves collision silently wrong and would push the parent if the orphaned frame then moves.)
- **Physics shadow, not a static body** — `MakePhysicsObjectAShadow(false,false)` + per-tick `UpdateShadow`, so a moving portal **pushes** props in the doorway; a static `SetPos`'d hull flung them. A single-tick jump past `SHADOW_TELEPORT_DIST` can't be swept, so it snaps.

Client half of the frame is debug-only: `worldportals_debug_collision` draws the slabs (rebuilt client-side from networked dimensions).

### Client: view roll, predict-shift, stair-strip (`cl_viewcorrections.lua`)

A combined `CalcView` hook does three things, all mirrored onto the viewmodel via `CalcViewModelView` (so the physgun/hands ride with the camera), both bailing when `GetViewEntity() ~= ply` (leave camera/monitor views alone):
(a) **roll fade** — `math.Approach`es `wp.rotating` (armed by the SetupMove path / `wp.ArmTeleportView`) to 0 so the world doesn't snap-rotate on landing;
(b) **predict-lerp shift** — see Predicted player teleport above;
(c) **stair-strip** — subtracts the engine's `SmoothViewOnStairs` eye-Z easing (measured as `pos.z - EyePos().z`, stashed in `wp.stairLeak`) for a brief window after a grounded portal exit, so the landing's big Z change isn't read as one huge stair step.
Roll fade + stair strip arm in **both** realms (the singleplayer net handler calls `wp.ArmTeleportView`); the predict-shift is prediction/ping-only (nil in singleplayer). Removing the roll fade alone is fine; removing the predict-shift reintroduces the blank-sky frame at high ping.

### Client: predicted-teleport debug HUD (`cl_predictdebug.lua`)

Developer HUD behind `worldportals_debug_predict` (default off). Buffers the last few predicted teleports (`wp.RecordTeleportEvent` from `sh_teleport.lua`) + the last self-broadcast pos (`wp.RecordNetTeleport`) and renders per-frame ply state, predict-lerp panel, and nearest-portal swept-test inputs — useful on paused frames. Record calls are guarded (`if wp.RecordTeleportEvent then`) so the file is a clean delete; the counters it reads live in `cl_viewcorrections.lua`/`sh_teleport.lua` so removing it can't break the predict path.

### Optional integrations

- **`vrmod`** — only behind `if vrmod then`; stub at `.luatypes/vrmod.lua` (`IsPlayerInVR`, `GetOriginAng`, `SetOriginAng`). VR users get a yaw-offset on teleport.
- **No CPPI, no WireLib.**

## Conventions when adding code

- **Pure Lua only — no GMod-Lua extensions.** No `//`, `continue`, `!=`, `&&`/`||`. Use `--`, `goto continue`, `~=`, `and`/`or`.
- **Realm-prefix filenames** (`sh_`/`sv_`/`cl_`). Suffixes break the analyzer's realm heuristic.
- **Comments: concise, why-not-what.** A couple of lines; reserve length for genuinely non-obvious rationale, and bias toward cutting — match the surrounding density, don't pad to essay length. Don't restate the code. Keep the *why* inline and self-contained — don't point a reader at an external doc (`memory/`, this file) or lean on a fragile cross-file pointer. Don't explain code by what it replaced (no "this replaces the old X that did Y") — state the live *why*, or the *why-not* for an obvious-but-wrong alternative. The hard-won why is worth keeping; the wall of prose around it isn't. Keep comments ASCII: use `->`, not `→`. For a dash use a single spaced hyphen; never a double `--` (reads as a second comment marker) or an em-dash (em-dashes are fine in this file's prose, nowhere else).
- **Drop unused loop variables** rather than naming them: `for _, v in pairs(t)`, `for k in pairs(t)`, `for _ = 1, n do`. The `unused` lint is on — keep the noise floor at zero.
- **Monkey-patching engine globals** (`util.TraceLine`, `render.RenderView`): capture the original under a `Real*` alias once, and reinstall in `InitPostEntity` so later-loading addons don't clobber it.
- **Consumer hooks** all use `hook.Call(name, GAMEMODE, ...)`: `wp-shouldrender`, `wp-trace`, `wp-tracefilter`, `wp-shouldtp`, `wp-teleport`, `wp-allowthickportal`, `wp-shouldghostdraw`, `wp-nocollide`, `wp-predraw`/`postdraw`, `wp-prerender`/`postrender`. Don't change the calling convention without updating Doors (it hooks all of these). `wp-allowthickportal` is retained for API compatibility only — it no longer affects rendering (every portal is an inverted cavity; its result is never read), so its registrations are harmless no-ops.

Hook contracts that bite if misused:
- **`wp-shouldghostdraw(sourceEnt, ghostEnt, portal, exit)`** (client) — fired **inside the ghost's `RenderOverride`, once per render pass**; return `false` to skip drawing in that pass. For an exit in a region hidden from the open world (a TARDIS interior in the skybox), the ghost must draw only in that region's RT pass, not the main scene. **Must not be cached** — the answer differs between the main-scene pass and each RT pass in one frame. Doors routes it (via `exit:GetParent()`) to a `ShouldDrawGhost` interior hook. Deliberately does NOT touch the `SetNoDraw` cordon (reserved for engine-native props).
- **`wp-shouldtp` + `wp-teleport` fire on both realms** for predicted player teleports (from `SetupMove`). `wp-shouldtp` once per crossing; `wp-teleport` on the client **every prediction pass (first-time AND resim)** (server fires it once per command). The client re-fires so a consumer's position fix re-applies each resim — so **handlers must be idempotent and resim-safe** (no sounds/effects/counters; pure deterministic resolvers only). Register the hooks **shared** (Doors moved `wp-shouldtp` out of `if SERVER`). Inner `CallHook` chains can stay server-only and return nil client-side; the client optimistically allows, server is authoritative.
- **`wp-nocollide(portal, ent)`** (server) — return the complete list of solids the transiting prop may phase through; world-portals no-collides exactly that, skipping the prop itself / ghosts / portals / frames and anything without a physics object. The consumer owns the decision — omitting an entity keeps it solid, so a missed one merely *jams* a prop (recoverable) instead of dropping it into the void. Field contract: `ent.WPIsGhost == true` = a clientside ghost (collision + ghost passes skip it); don't repurpose it.
- **`wp-prerender`/`wp-postrender`** fire as `(portal, exitPortal, plyOrigin, depth)` (1 = top-level, 2+ = nested). A consumer that saves/restores global render state across the pair MUST guard on `depth > 1` to skip nested renders, or a nested pre-render clobbers the parent's saved state before its post-render restores.

## Tooling

`.luarc.json` configures `glua_ls`/`glua_check` (both EmmyLua-Analyzer-Rust) with `./.tools/glua-api` (GLua stubs) and `./.luatypes` (local overrides + the `vrmod` stub). VS Code extension: `Pollux.gmod-glua-ls`.

**Setup (fresh clone, before touching `.lua`):** `pwsh -File scripts/install-tools.ps1` — the single source of truth for `glua_check`/`glua_ls`/stubs, versions pinned at the top and shared with CI. Idempotent (no-op when present), so also the recovery path when diagnostics look wrong; the `glua-lsp:install-glua-ls` skill covers the same. The `glua-lsp` plugin auto-resolves `glua_ls` from `.tools/bin/` at launch; after a fresh install, `/reload-plugins`. Bump versions via the constants in that script (Renovate raises bump PRs, gated by the GLua Check CI job).

**Whole-repo scan:** `pwsh -File scripts/glua-check.ps1` (installs tooling on demand, runs `glua_check --warnings-as-errors`; CI calls the same). `glua_ls` only analyzes open/edited files, so use this to audit everything. Treat diagnostics as actionable only if your edit caused them — pre-existing noise on unrelated lines isn't in scope.

LSP diagnostics/hover/jump are via the [`glua-lsp` plugin](https://github.com/AmyJeanes/gmod-claude-plugins) (wraps `glua_ls`, same engine as `glua_check`); `.claude/settings.json` declares the marketplace so contributors get prompted. Diagnostics arrive automatically after edits.

### Type annotations

- **Trace redirection (`sh_teleport.lua`).** `util.RealTraceLine` returns a `TraceResult`, not the input `Trace`. The result is named `trace`, but `mask`/`filter` come off the input `data` — keep that straight; `trace.mask`/`trace.filter` would read fields a `TraceResult` lacks.
- **Field-access narrowing doesn't propagate.** `if not (data.Src and data.Dir) then return end` does NOT narrow `data.Src`/`Dir` below. Copy each into a local, null-check the locals on separate lines, then use the locals.
- **Trace struct casts.** Inline tables passed to `util.TraceLine`/`RealTraceLine` may not match the `Trace` struct (partial narrowing); an inline `--[[@as Trace]]` cast is cleaner than restructuring when the logic is correct.
- **`.luatypes/`** — local LuaLS stubs. `glua_overrides.lua` aliases the integer enums (`COLLISION_GROUP`, `FORCE`, `STENCILOPERATION`, `STENCILCOMPARISONFUNCTION`; glua-api ships them as string-literal unions that break `SetCollisionGroup(COLLISION_GROUP_WORLD)`) and adds the 2-arg `table.insert(tbl, value)` overload. `vrmod.lua` declares the VR globals.

**No `diagnostics.disable` in `.luarc.json`** — every rule earns its keep; prefer code fixes or targeted annotations over global suppression.
