//shared definitions
#pragma target fte_5768
#define printf(x, ...) print(sprintf(x, __VA_ARGS__))

// Engine global: texture NAME of the surface hit by the last traceline/tracebox.
// The engine populates it on BOTH client and server (pr_csqc.c:2928 / pr_cmds.c),
// but the auto-generated cl_defs.qc / sv_defs.qc omit it (dumped as "ssqc-only"),
// so declare it here in a shared unit that both builds compile.  Read immediately
// after the trace you care about (a later trace overwrites it).  Used by the
// surface-material system (sh_surfaceprops.qc). Q1 surfaceflags aren't set, so the
// texture name is the key.
string trace_surfacename;

// Gravity Shift (gravity gun): 1 while this player's gravity is redirected.
// Declared here (earliest shared include) so both sh_pmove.qc and the gravgun
// weapon file can see it.  See GravShift_UpdateActivation in sh_pmove.qc.
.float gravshift_active;
// Gravity Shift GLOBAL state (server-authoritative; the WHOLE server shifts to
// gravshift_world_dir, broadcast to clients via the "gravdir" serverinfo key, read
// with serverkey).  Declared shared (inert on the client) so the gravgun prop-tick
// can read the owner.  '0 0 0' world_dir = no shift active.
entity gravshift_owner;          // player currently driving the shift (world = none)
vector gravshift_world_dir;      // global gravity dir while active; '0 0 0' = none
vector gravshift_world_dir_last; // last value pushed to serverinfo (on-change guard)
float  gravshift_owner_assert;   // time the owner last asserted (auto-clear if stale)
.float gravshift_toggle;         // per-player latch: impulse-7 (Weapon Special) flips it on/off,
                                 // the pmove arbiter reads it as the "want shift" state (server-auth).
.float gravshift_hull_cube;      // 1 = the full axis-swapped hull didn't fit where we stood when the
                                 // shift engaged; collide as a ±16 cube (a strict subset of EVERY hull
                                 // variant, so it always fits) until the full hull clears.
.float pm_eye_h;                 // eye height SCALAR (units above origin along gravity-"up").  The duck
                                 // code authors this; PM_ComposeEyeOfs turns it into .view_ofs along the
                                 // active gravity so crouch view dips toward the gravity floor, not world-Z.

// nettest Patch 36 Part B: engine builtin (com_mesh.c Mod_AddHitbox) that registers a
// per-bone hitbox on an alias/IQM player model.  Once a model has any hitbox, MOVE_HITMODEL
// traces the boxes instead of the mesh triangles and reports the struck box's hitgroup via
// trace_surface_id.  Registered from the shared $hbox table (sh_weapons.qc) at precache.
// Returns 1 if the bone exists on that model, else 0.  Name-bound (#0) so it no-ops cleanly
// on an unpatched engine (the function simply isn't found → addmodelhitbox unavailable).
float(float modelindex, string bonename, float hitgroup, vector boxmins, vector boxmaxs) addmodelhitbox = #0:addmodelhitbox;
void(string modelname) Hitbox_RegisterModel;	// defined in sh_weapons.qc (where the $hbox table lives); takes the precache name (precache_model returns a string)

const float FL_DUCKING = 8192;
const float PM_CSQC_PROXY_VERSION = 20;  // v20: movement section adds pm_jump_groundstick_off_until (remaining-secs) right after pm_jump_lag_end, so the post-jump ground-snap suppress window survives reconcile at high ping (codstamina/grapple low jumps).  bump on wire-layout change.  MUST NOT collide with any CSQC_ENT_* id below (CSQC_Ent_Update dispatches by equality before falling through to the pm_proxy parse — v13 collided with CSQC_ENT_CAMERA and silently routed proxy updates into the camera parser).  v14: ammo bitmask + movement byte/short re-encoding.  v15: origin/velocity now WriteFloat (full 32-bit) instead of WriteCoord (1/8 qu) — eliminates snapshot-rounding as a source of reconcile drift.  v16: weapon-state section now also carries pm_weapon_blend_progress + pm_weapon_prev_factor so the speed-factor blend is input-tick-driven instead of wall-clock-driven.  v17: utility proxy includes CS HE/flash/smoke ammo.  v18: primary/secondary ammo is slot-based.  v19: weapon-state section adds 4 floats + 1 byte for the sv_gunkick view-kick state (pitch/yaw offsets + spring velocities + per-burst shot index).
const string PM_CSQC_PROXY_CLASSNAME = "pm_csqc_proxy";

// PM_CSQC_PROXY SendFlags section bits — each section is gated separately
// so ticks where only one section changed don't drag the other ~100 B along.
const float PM_SF_MOVEMENT     = 1;  // origin, velocity, view_ofs, flags, pm_* timers, spread
const float PM_SF_WEAPON_STATE = 2;  // slots, weapon, weaponstate, attack_finished, anim, zoomstage
const float PM_SF_AMMO         = 4;  // slot ammo + utility ammo bytes

// CSQC entity type IDs (first byte sent by SendEntity)
const float CSQC_ENT_PUSH_TRIGGER = 2;
const float CSQC_ENT_SOLID_BRUSH    = 5;
const float CSQC_ENT_DROPPED_WEAPON = 7;
const float CSQC_ENT_PLAYER_VISUAL  = 8;
// MUST NOT collide with PM_CSQC_PROXY_VERSION or any other
// CSQC_ENT_* id — engine dispatches by this byte and same-value collision
// silently routes the wrong parser → wire desync (Host_EndGame).
const float CSQC_ENT_PROJECTILE     = 9;  // server projectiles routed through cl_tosssmooth.qc extrap+smooth
const float CSQC_ENT_C4             = 14; // planted_c4 — fixed-position bomb with beep-pulse dlight
const float CSQC_ENT_ENV_BEAM       = 15; // env_beam — sprite-strip beam between two named entities
const float CSQC_ENT_FUNC_RAIN      = 16; // func_rain — brush volume constraining cl_rain drops
const float CSQC_ENT_ENV_SOUND      = 17; // env_sound — GoldSrc room/reverb trigger points
const float CSQC_ENT_PHYS_PROP      = 18; // ODE filing cabinet — CSQC-networked solid box so the
                                          // CLIENT pmove + bullet traces collide with a matching
                                          // shape (engine-replicated props are invisible to the
                                          // custom QC pmove → fall-through/driftlock without this).
                                          // 18 is permanently safe: PM_CSQC_PROXY_VERSION (19) only
                                          // ever bumps UPWARD, never down onto 18.
const float CSQC_ENT_INFODECAL      = 19; // infodecal — GoldSrc decal projector. Networks the traced
                                          // surface point + normal + { texture so the client places it
                                          // once via the spray-decal draw (cl_infodecal.qc / cl_sprays.qc).
const float CSQC_ENT_PRED_PROP      = 6;  // prop_static/detail with the Predicted-collision flag — a
                                          // PVS-gated CSQC mirror (model + scaled solid) so the LOCAL
                                          // pmove + bullet traces collide client-side (rock-solid, no
                                          // rubber-band). Hero props only; this mirror is the d1_canals
                                          // OOM at thousands — never flag dense clutter.
                                          // Id 6 is the free 5..7 gap, BELOW PM_CSQC_PROXY_VERSION (20);
                                          // the proxy version only bumps UPWARD, so 6 can never collide.
                                          // (Using 20 DID collide with the proxy version → every connect
                                          // desynced and Host_EndGame'd. See line-28 warning.)
const float CSQC_ENT_NAV_DEBUG      = 40; // bot/nav debug overlay proxy (per-client SendEntity).
const float CSQC_ENT_CAR            = 41; // driveable prop_car/func_car mirror (reserved; Stage 2 wheel/cam wire).
                                          // High id: clear of the 2-18 ids AND PM_CSQC_PROXY_VERSION's
                                          // upward growth, so the next proxy bump can't collide.
// nav-debug proxy SendFlags sections (sv_bots.qc NavDbg_SendEntity <-> cl_navdebug.qc NavDebug_EntUpdate)
const float NAVDBG_SF_GRAPH = 1;  // static nav graph chunk (node positions + links)
const float NAVDBG_SF_BOTS  = 2;  // per-bot live state (origin/state/enemy/weapon/mag)
const float NAVDBG_SF_PATHS = 4;  // per-bot A* path: node indices + cursor + roam goal

// phys_files carry phase — the (formerly csolid 0/1) phase byte of phys_files_Send.
// 0/1 keep their old csolid meaning so an in-flight snapshot during a hot-reload still
// decodes solidity right; 2/3 distinguish the carry sub-states for client prediction.
const float PP_PHASE_NONSOLID   = 0;  // carried/flying mid-air, non-solid to players (old csolid 0)
const float PP_PHASE_FREE_SOLID = 1;  // free + re-solidified to players               (old csolid 1)
const float PP_PHASE_GRABBING   = 2;  // server grab pull-in active — client renders the STREAM (no predict)
const float PP_PHASE_STEADY     = 3;  // steady carry — the local carrier may client-predict the hold pose
// The phase itself only needs 2 bits, so the top bit rides along as "the buoyancy debug payload is
// appended at the end of this message" (set when sv_debug_physprops is on).  Carrying the flag inside a
// byte the client already reads is what keeps the writer and the reader in lockstep across a live cvar
// toggle.  ALWAYS mask it off before comparing a phase: `phase & PP_PHASE_MASK`.
const float PP_PHASE_DBG_BIT    = 128;
const float PP_PHASE_MASK       = 3;

// Rest state in the debug payload (bits 0-1), plus bit 2 = in water.
const float PP_DBG_REST_NONE    = 0;
const float PP_DBG_REST_FLOAT   = 1;
const float PP_DBG_REST_CONTACT = 2;
const float PP_DBG_REST_MASK    = 3;
const float PP_DBG_WET_BIT      = 4;
const float PP_DBG_LOADED_BIT   = 8;   // something is stacked on it — it MUST keep being forced

// ---------------------------------------------------------------------------
// PROP RIDER CARRY (PM_CheckPhysPropCarry, sh_pmove.qc)
//
// Velocity of the prop surface the player is standing on.  FORWARD-DECLARED here because
// sh_customdefs.qc compiles first on BOTH sides, while the two definitions live in files that do not:
// on CSQC, cl_progs.src lists sh_pmove.qc at 19 and cl_physprop.qc at 43, so the pmove file cannot see
// anything declared in cl_physprop.qc.  Cross-file forward declaration is the sanctioned way around
// that (same pattern as sv_physprop.qc's W_PhysDropWake).
//
// The two sides deliberately answer DIFFERENTLY, and that is the point:
//   SSQC — the live authoritative .velocity.
//   CSQC — the DERIVATIVE of the same interpolation the hull is posed by, NOT .velocity.  If the hull
//          sits at t-delay but the carry integrates the velocity at t, the player advances at a
//          different rate than the surface under them and slides off the back of the prop over a few
//          hundred ms.  Differentiating the curve the hull is actually posed with makes the player's
//          displacement and the hull's displacement identical by construction.
vector(entity prop) PhysProp_ContactVelocity;

// On the PLAYER: which prop is being ridden, and the contact velocity applied this substep.
.entity prop_carry;
.vector prop_carry_velocity;
.float  prop_carry_active_cltime;   // CSQC only — drives the reconcile filter

// trigger_push spawnflags
const float PUSH_ONCE     = 1;  // remove after first touch
// PUSH_START_OFF moved to bit 2 to match HL spec — many community maps
// set bit 2 expecting "Start Off" semantics, and silently routing that
// to "silent" left the triggers always-active with no use handler
// (buttons targeting them did nothing).  PUSH_SILENT moved to bit 64.
const float PUSH_START_OFF = 2;
const float PUSH_SILENT   = 64; // no wind sound (moved from bit 2)
const float PUSH_ADDITIVE = 4;  // add to velocity rather than replace
const float PUSH_TUNNEL   = 8;  // pull toward trigger centerline while pushing
const float PUSH_SOURCE   = 16; // boost along movedir up to speed, don't overwrite sideways

// Linked list fields for trigger chains
.entity push_next;
.entity tele_next;
.entity ladder_next;
.entity conveyor_next;
.entity rotating_brush_next;
.entity moving_brush_next;

// Platform-carry state.  Set by Mover_PlatformCarry when the player is
// standing on a moving brush (func_train / func_tracktrain).  The same
// helper translates the player by the brush's per-tick delta (locking
// them 1:1 to platform motion) and rotates them around the brush's
// origin by the brush's per-tick yaw delta.  When the carry detection
// fails the next tick (player jumped or stepped off), the helper adds
// platform_carry_velocity to the player's .velocity once — that's the
// "inherit platform velocity on departure" path the user asked for.
//
// Set on PLAYER:
.entity platform_carry;          // brush we're currently locked to (world if none)
.vector platform_carry_velocity; // mirrored from carry.velocity each tick — used for inherit
.float  platform_carry_prev_yaw; // brush.angles_y at the previous carry tick.
// Rotating-brush contact marker.  Set to `time` (SSQC) or `cltime`
// (CSQC) whenever PM_CheckRotatingCarry's Phase 1 (standing on brush)
// or Phase 3 (ground player swept by mesh) applies a slide/carry this
// substep.  Read by CSQC_ReconcilePrediction to zero err during
// rotator contact — the per-substep CSQC slide and the per-func_tick
// server slide integrate to the same per-second rate but don't match
// at every snapshot moment, and the smoother fading those differences
// is what the user perceives as "push then snap back" jitter.  100 ms
// staleness window after the last contact lets the smoother resume
// once the player walks clear of the rotator.
.float  rotcarry_active_cltime;

// Linear-brush geometry push contact marker.  Same shape as
// rotcarry_active_cltime — set by PM_CheckMovingPushers's door push
// branch (sh_pmove.qc:~3216) AND by SSQC Mover_GeometryBlockPush_Player
// each substep / tick the player is being pushed but NOT carried
// (platform_carry is only set when riding on top).  Without this
// marker the drift-lock at cl_player.qc:~1668 holds the camera at
// the pre-reset origin while the player isn't pressing movement
// keys, so the visible position lags the server's authoritative
// push — symptoms: "drift builds up to 24qu, player sinks into the
// door".  The smoother branch's err filter also reads this marker
// to skip fading the per-snapshot integration gap.
.float  mover_push_active_cltime;
                                  // Per-PLAYER (not per-brush) so the CSQC
                                  // preview pmove doesn't leak its writes
                                  // forward into the next real pmove —
                                  // CSQC_BuildPresentationView save/restores
                                  // this field around the preview loop.

// SNAP-JUMP CONSUMPTION (CSQC carry).  The pmove carry math is
// velocity-based per substep (rb.velocity * pm_frametime) which is
// smooth at INPUT rate; using origin-delta would jitter at render rate
// since rb.origin only updates when predraw fires.  The drawback of
// pure velocity-based: CSQC extrapolation uses the LAST snapshot's
// velocity, but the server may have changed velocity mid-snap-interval
// (path_corner turn, speed ramp).  When the new-velocity snapshot
// finally arrives, rb.origin jumps by exactly the amount that V_extrap
// diverged from V_actual — the "cab snaps forward, player stays put"
// lurch.  We capture that discontinuity in brush_snap_origin_cumulative
// at snapshot-receive time (see CSQC_SolidBrush_Update) and let each
// carrying player consume it once via platform_carry_jump_*_consumed.
// In the constant-velocity case the per-snap delta is ~0, so this
// mechanism is invisible.  Only matters at velocity transitions.
.vector platform_carry_jump_origin_consumed;
.float  platform_carry_jump_yaw_consumed;

// --- func_vehicle driver state (SHARED: pmove reads these, the prediction
//     proxy round-trips them owner->client so Phase-2 prediction replays the
//     drive deterministically).  Kept on the PLAYER (driver), not the brush,
//     because the proxy replicates player state and reconcile replays it.
//     The drive model's OUTPUT (velocity + avelocity_z) lives on the brush
//     and is replicated to everyone via brushsync for visual + carry. ---
.entity driving;        // on PLAYER: the func_vehicle we're driving (world if none)
.float  veh_steer;      // on PLAYER: steering-wheel accumulator [-1..1], self-centers when released
.float  veh_throttle;   // on PLAYER: current forward speed scalar (ease-out accel integrator)
.float  veh_in_fwd;     // on PLAYER: WASD forward intent stashed by pmove while driving (walk input is zeroed there so the driver can't stroll off the deck)
.float  veh_in_side;    // on PLAYER: WASD steer intent stashed by pmove while driving
.float  pm_driving;     // on PLAYER: replicated 0/1 "am I driving" flag (prediction proxy, pm_carrying-style) — gates the pmove driver-lock + weapon-fire block on both sides
.vector veh_seat_ofs;   // on PLAYER: rigid seat-bolt — the driver's mount offset in the car's LOCAL (yaw) frame; pm_origin is re-pinned to car+rotate(this) every pmove substep (server + CSQC) so the body tracks the car with no carry drift

// --- prop_car / func_car (Box3D/ODE raycast vehicle — sh_vehicle_phys.qc / sv_prop_vehicle.qc). ---
// SEPARATE from func_vehicle's .driving/.pm_driving so the two vehicle systems never alias.
.entity car_driving;    // on PLAYER: the prop_car/func_car we're driving (world if none)
.entity car_driver;     // on CAR:    the player driving it (world if none)
.float  car_in_fwd;     // on PLAYER: WASD forward intent stashed in the real cmd path while in a car
.float  car_in_side;    // on PLAYER: WASD steer intent stashed while in a car
.float  car_in_brake;   // on PLAYER: handbrake (jump button) intent stashed while in a car — cuts rear grip for drift
.float  pm_incar;       // on PLAYER: replicated 0/1 "am I in a car" flag (prediction proxy, pm_driving-style) — gates the pmove input-zero + weapon-fire block + third-person camera on both sides
.float  veh_seat_ofs_set; // on PLAYER: 1 once veh_seat_ofs is captured for the current drive (cleared on dismount)
// Parked-car sleep (sv_car_sleep).  A driverless, stopped car still ran the FULL raycast
// drive sim every tick — 4 suspension tracelines, ~40 cvar reads, a yaw-damp torque, and a
// physics_enable(TRUE) that re-woke the rigid body every single tick, permanently defeating
// the physics backend's own autodisable.  See the Car_Think sleep gate for why this needs an
// EXPLICIT physics_enable(FALSE) rather than just letting the backend autodisable.
.float  car_rest_since; // on CAR: time it first went still + driverless (0 = moving/driven/awake)
.float  car_asleep;     // on CAR: 1 = body explicitly disabled and Car_PhysStep skipped

// Set on MOVER (func_train / func_tracktrain):
.vector platform_prev_origin;    // brush origin at the previous carry tick
.float  platform_prev_yaw;       // brush yaw at the previous carry tick
.float  platform_prev_seeded;    // 1 once we've snapshotted at least one tick (so the first frame doesn't apply a giant delta)

// Snap-jump cumulative counters on the mover.  Populated only on CSQC
// inside CSQC_SolidBrush_Update each time a brushsync snapshot lands:
//   cumulative += (post-setorigin self.origin) - (pre-setorigin self.origin)
// The pre value is whatever predraw / engine integration last set
// rb.origin to (the CSQC extrap of where the brush "should" be).  The
// post value is the authoritative position the server reported.  Their
// difference is the discontinuous "snap" the cab does at the moment
// of arrival — zero in the constant-velocity case, non-zero whenever
// the server changed velocity mid-snap-interval.  Carrying players
// consume this in PM_CheckMovingPushers so they jump with the cab.
// SSQC leaves these at 0 (no snapshot arrivals on the authoritative
// side — server-side pmove already uses correct velocity each tick).
.vector brush_snap_origin_cumulative;
.float  brush_snap_yaw_cumulative;

// Brush replication fields — declared authoritatively in
// cl_brushsync.qc (CSQC) and sv_brushsync.qc / sv_customdefs.qc
// (SSQC), but the client compile order puts cl_brushsync.qc AFTER
// sh_pmove.qc, so PM_CheckRotatingCarry can't reference them
// without an earlier slot.  Re-declaring at this scope shares
// storage on both sides — QC accepts duplicate `.field` decls of
// matching type.  Vector pos1/pos2 are also declared in
// sv_customdefs.qc; this duplicate is harmless.
.float  brush_type;
.float  mover_state;
.float  brush_is_rotating;
.vector pos1;
.vector pos2;

// Generic movement/entity fields not declared in the engine-generated defs
.float speed;
.float waterlevel;   // synced from pm_waterlevel: 0=dry, 1=feet, 2=waist, 3=eyes

// Skeletal animation fields exposed by the HALFLIFEMODEL_FIELDS engine patch.
// Standard FTE sv_defs.qc only declares .frame/.frame1time/.baseframe for SSQC,
// but our patched engine exposes the full set so MOVE_HITMODEL traces use the
// same skeleton blending as the client renderer.
#ifdef SSQC
.float frame2;
.float frame2time;
.float lerpfrac;
.float baseframe2;
.float baseframe2time;
.float baseframe1time;
.float baselerpfrac;
.float subblend2frac;
.float basesubblend2frac;

// Lag-compensation pose + position stash (see server/sv_lagcomp.qc).
// Saved before a rewound trace so Lagcomp_RestorePlayer can put the
// true pose AND origin/angles back.
.float  lc_stashed;
.float  lc_stash_frame, lc_stash_frame1time, lc_stash_frame2, lc_stash_frame2time, lc_stash_lerpfrac;
.float  lc_stash_baseframe, lc_stash_baseframe1time, lc_stash_baseframe2, lc_stash_baseframe2time, lc_stash_baselerpfrac;
.float  lc_stash_subblendfrac, lc_stash_subblend2frac, lc_stash_basesubblendfrac, lc_stash_basesubblend2frac;
.float  lc_stash_bonecontrol1, lc_stash_bonecontrol2, lc_stash_bonecontrol3, lc_stash_bonecontrol4;
.float  lc_stash_basebone;
.vector lc_stash_origin, lc_stash_angles;

// Forward declarations so shared weapon code (compiled before
// sv_lagcomp.qc) can call them. Definitions live in
// server/sv_lagcomp.qc.
void(vector src, vector end, float moveflags, entity ignore) Lagcomp_TraceLine;
void(entity attacker) Lagcomp_BeginRewind;
void()                Lagcomp_EndRewind;

// Team-select camera system — definitions in server/sv_cameras.qc.
// Forward-declared so sv_player.qc can route team-selecting players
// (and sv_main.qc can drive the per-tick cycle).
float(entity p) Camera_PlacePlayerAtCurrent;   // returns 1 if placed, 0 if no cameras exist
void() Camera_UpdateCyclingSpectators;
void() Camera_EnsureTargetsResolved;
void() Camera_ResetState;                       // call from worldspawn to clear stale state across map loads

// Per-player camera phase (set via `cmd cam_phase <N>` from menu stuffcmd).
// Selects which flagged cameras to cycle when the player is in team-select.
.float cam_phase;
.float cam_last_dbg_time;   // rate-limit for sv_debug_camera bprints

// Latched by RoundRestart before clearing .is_dead — TRUE if the player was
// alive at round end.  PlayerSpawn consumes this flag to decide whether to
// preserve the player's inventory (slot_* + mag_*/ammo_*) or apply the
// default starting loadout from sv_default_* cvars.
.float survived_round;

// Server projectile networking (sv_weapons.qc projectile_SendEntity +
// per-weapon spawn sites). proj_type is one of PROJ_TYPE_* (sh_weapons.qc)
// and tells the CSQC parser which model + gravity factor to apply.
.float proj_type;

// Forward decl — defined in server/sv_player.qc — so sv_cameras.qc can
// push the proxy origin while the player is still in team-select (where
// PlayerPreThink returns early and doesn't call this itself).
void(entity player) PM_SyncPredictionProxy;
#endif

// proj_fuse_end is the absolute time at which the projectile's existing
// one-shot think (explode, expire) should fire.  SSQC's periodic-tick
// wrapper checks against this every sv_toss_tickrate tick to drive CSQC
// SendFlags pulses without losing the original fuse semantics.  Shared
// scope because the CSQC fake-projectile path also needs it: a glancing-
// bbox pass-through window temporarily replaces the expire think, then
// the pass-through restore re-arms nextthink to proj_fuse_end.
.float proj_fuse_end;

// Previous-tick origin for swept-trace tunneling protection.  SSQC
// projectiles (snowball + paintball) snapshot self.origin BEFORE the
// engine integrates the next step; the next think then trace-sweeps
// from this point to the new self.origin to catch any hits the
// engine's per-frame SV_PushEntity sweep might have missed (fast
// players, frame-time jitter, etc.).
//
// Also referenced by the CSQC fake-projectile touch handlers — they
// use it as a fallback probe segment when the engine zeroed velocity
// before the touch callback fired.  Declared at shared scope so both
// progs see the field.
.vector proj_prev_origin;

// Pass-through window state for projectiles that glanced a player
// bbox without intersecting the actual mesh.  During the window the
// projectile is switched to MOVETYPE_NOCLIP and SOLID_NOT so it
// keeps flying past the player rather than vanishing mid-air; the
// owning tick restores MOVETYPE_TOSS / SOLID_BBOX once `time` passes
// proj_passthrough_until.  Zero = not in a pass-through window.
//
// MOVETYPE_NOCLIP specifically (not just SOLID_NOT) — FTE's
// SV_Physics_Toss always runs ClipVelocity after touch returns, even
// for SOLID_NOT entities, which slides the projectile flat against
// the bbox face and clears velocity outright on top-down impacts
// (see sv_phys.c:1467).  Switching the movetype routes physics
// through SV_Physics_Noclip which just does origin += vel*dt.
//
// proj_passthrough_savedvel is the velocity at the moment of the
// glancing touch; restored verbatim on exit so the parabolic arc
// resumes from where it was instead of from whatever value pmove
// integrated during the (brief) NOCLIP segment.
.float  proj_passthrough_until;
.vector proj_passthrough_savedvel;

.float spread_penalty;       // decaying spread penalty from jump/landing (0 = none)
.float fire_spread_penalty;  // decaying spread penalty from sustained fire (0 = none)
.float fire_spread_pending;  // pending penalty to apply AFTER current shot resolves
.float altfire_finished;     // separate cooldown for alt-fire (doesn't block primary)

#ifdef CSQC
// Standard QW player fields not present in cl_defs.qc. Declared here in
// shared (early in cl_progs.src) instead of client/cl_customdefs.qc so
// shared files compiled BEFORE cl_customdefs.qc — like sh_weapons.qc's
// Weapon_SpeedFactor_Smooth — can reference self.weapon. SSQC has these
// from sv_defs.qc; this CSQC-only block matches.
.float weapon;
.float weaponframe;

// Client-local fire latch, cltime-based. Set whenever CSQC prediction
// succeeds at firing/dryfiring, checked at the top of every try-fire.
// Never written from the server and never rolled back by
// CSQC_ResetToConfirmedState — that immunity is the whole point.
// When the server is paused (menu open), attack_finished gets stomped
// back to stale past values every snap; without this field, prediction
// fires one shot per frame until the server catches up.
.float csqc_fire_guard;

// Client-local reload latch, same idea as csqc_fire_guard but scoped
// to reload presses.  Stops buffered impulse 6 (or held R) from
// re-triggering reload every replay tick at high ping: the server's
// weaponstate ack lags, so during the RTT window the local replay sees
// WS_IDLE each reconcile and re-fires SH_StandardTryReload, stacking
// multiple reloads once the ack finally arrives.  cltime-based so it
// survives CSQC_ResetToConfirmedState.
.float csqc_reload_guard;

// Highest wep_action_id whose shooter-local effects have already been
// emitted — a strict high-water mark.  BeginFireActionEffects fires
// iff `wep_action_id > csqc_fire_effect_action_id`, and advances the
// mark to the new action_id on success.
//
// Why high-water (>) rather than equality:
//   • At high render-rate / low cl_maxfps, multiple TryFire successes
//     can occur within a SINGLE input command — cltime advances past
//     attack_finished between render frames while csqc_pred_sequence
//     stays.  Each success advances wep_action_id, so an action_id-
//     keyed gate naturally distinguishes them.
//   • At reconcile a snapshot can REWIND wep_action_id down to the
//     server's last-acked value.  If we then re-pinned this latch on
//     reset, replay would compare a re-pinned (high) value against
//     re-advanced (still lower) action_ids and either:
//       — refuse to re-emit a shot that needs effects, OR
//       — emit a doubled effect when action_id eventually catches
//         the rewound mark.
//     Leaving the high-water mark intact across reconcile means
//     replay re-runs of already-effected shots correctly skip
//     (their action_id ≤ mark), while shots whose action_id climbs
//     PAST the mark (new live tick or freshly-buffered cmd) get
//     emitted exactly once.
//
// Reset paths: ONLY full predicted-entity re-init (fresh spawn / new
// connection) zeroes this field.  Reconcile must NOT touch it.
.float csqc_fire_effect_action_id;

// Visual proxy death flag, set in CSQC_PlayerVisual_Update from server's
// owner.is_dead byte. Declared here (rather than in cl_player.qc) so
// shared/sh_pmove.qc — which compiles earlier — can reference it from
// PM_IsLivePlayerCollider.
.float vis_is_dead;
// nettest death ragdoll (client-side): KillFeed_Parse flags a body-shot corpse +
// stores the shot direction; the proxy predraw then spawns a separate client ragdoll
// (vis_ragdoll_ent) at the corpse and hides the corpse mesh.  Torn down in CSQC_Ent_Remove.
.float  vis_ragdoll_want;   // 1 = this corpse should ragdoll (set at death)
.vector vis_ragdoll_dir;    // shot direction (attacker->victim) to seed the flop
.entity vis_ragdoll_ent;    // the spawned client ragdoll (world until spawned) — now INERT (server ragdoll instead)
.float  vis_kc_ragdoll;     // 1 on the killcam-owned ragdoll (cl_killcam.qc) — exempts it from the replay-hide
// nettest server ragdoll: networked from the proxy IDENTITY section — 1 = a server-side corpse_ragdoll is
// active for this corpse, so the proxy predraw HIDES the animated mesh (the ragdoll renders in its place),
// except while the killcam re-poses it (PlayerVis_KillcamOwned).
.float  vis_has_server_ragdoll;
// Server-authoritative dead flag — set ONLY from the proxy snapshot (never by
// the client predicted-death), so the proxy's bullet-trace SOLIDITY follows the
// real server state.  vis_is_dead itself gets flipped to 1 by CSQC_TryPredictDeath
// for the death ANIMATION; gating solidity on that made a wrong/early predicted
// death turn the enemy proxy SOLID_NOT *permanently* (the server never re-sends
// IDENTITY while is_dead is unchanged), so the trace passed through it and no
// hitclaim was ever sent again — the "blood splatter then it stops / no damage
// with sv_trust_clienthits 1" bug.  The solidity gate now uses THIS flag.
.float vis_server_is_dead;
// nettest Patch 36 fix: snapshot of the proxy's predraw-computed framestate.  The
// client MOVE_HITMODEL bullet trace runs at PREDICTION/input time, which is BEFORE
// the proxy's predraw poses it that frame, so the live engine .frame/.basebone are a
// frame stale (or degenerate on a recycled entity slot) and the trace misses the
// rendered silhouette.  Predraw stashes the rendered pose into these; W_PlayersExpand-
// Hitboxes restores them onto the proxy just before the trace so trust-1 hits exactly
// what the shooter sees.  Declared here (before sh_weapons.qc) so the restore compiles.
.float vis_trace_frame, vis_trace_frame1time, vis_trace_frame2, vis_trace_lerpfrac;
.float vis_trace_baseframe, vis_trace_baseframe1time, vis_trace_baseframe2, vis_trace_baselerpfrac;
.float vis_trace_basebone, vis_trace_subblendfrac, vis_trace_subblend2frac;
.float vis_trace_pose_valid;
// Server-pushed remote-player health (0..255 byte). Used by CSQC predicted-
// death to decide whether a hit is lethal. Updated in CSQC_PlayerVisual_
// Update each VP_SF_IDENTITY snapshot. Set to 0 by the local predicted
// death so a multi-pellet shotgun spread doesn't re-trigger predictions
// across pellets after the first lethal one.
.float vis_health;
// Bodygroup bitfield mirrored from the visual-proxy IDENTITY section.
// Bit 0 = "backpack" bodypart submodel toggle (red/T-side player
// carrying C4, but not actively holding it, shows bomb on back).
// Translated to a "geomset 2 N" line during setcustomskin in
// CSQC_PlayerVisual_Update. More bits available for future bodypart
// toggles without bumping the wire format.
.float vis_bodygroup;
.float vis_last_applied_bodygroup;   // last bodygroup state we applied via setcustomskin (0 = never applied yet)
// Life generation for trusted hitclaims. The server increments
// player_life_serial on every PlayerSpawn and mirrors it to each
// player_visual_proxy as vis_life_serial. Client hitclaims carry the
// value they hit; the server rejects claims whose serial no longer
// matches the live player slot. This prevents stale dead/corpse
// proxies from damaging a player who has already respawned.
.float vis_life_serial;
// Visual proxy's team — derived from team_model_byte during the IDENTITY
// section parse (cl_player.qc CSQC_PlayerVisual_Update). Used by
// CSQC_TryPredictDeath to skip lethal-hit prediction on teammates when
// mp_friendlyfire is off, so the local "they died" animation doesn't
// fire on hits the server will reject.
.float vis_team;
// Forward-declared here so CSQC_TryPredictDeath (sh_weapon_logic.qc, which
// compiles before cl_player.qc) can write the death animation frames into
// the proxy's anim slots. Authoritative declaration + writer is in
// cl_player.qc — the predraw applies them to .frame and .baseframe.
.float vis_anim_bottom;
.float vis_anim_top;
// Predicted-death latch — set when CSQC_TryPredictDeath fires on this
// proxy. While set, CSQC_PlayerVisual_Update IGNORES incoming VP_SF_ANIM
// section data so the server's late-arriving death animation snapshot
// can't restart / re-trigger the death pose we already played. Cleared
// only AFTER `vis_pred_dead_at_time + ping + headroom` has passed AND
// the snapshot still says alive — so a stale "still alive" snapshot
// arriving before our shot has round-tripped doesn't pop the proxy
// back to the standing pose mid-death-animation.
.float vis_pred_dead_latch;
.float vis_pred_dead_at_time;        // local time when latch was set (0 = never)
// Set in CSQC_TryPredictDeath when the predicted death also clears the
// gib threshold (final damage >= 70).  Lets the CSQC_EVENT_PLAYER_GIBS
// handler suppress the server's late-arriving gib spawn so the same
// gibs/sound/particles don't double-fire.  Same staleness window as
// vis_pred_dead_at_time.
.float vis_pred_gibs_at_time;
// Forward-declared so CSQC_TryPredictDeath can clear the weapon byte
// when it predicts a kill (matching the server's W_DropAllWeaponsOnDeath
// which empties self.weapon and thus the proxy's vis_weapon_id). Real
// declaration + writer is in cl_player.qc (parser populates it from
// the VP_SF_IDENTITY_CL section).
.float vis_weapon_id;
// nettest killcam/spectate: remote weapon-anim state (networked via VP_SF_ANIM)
// + the local-clock stamp of when the current weapon action began (viewmodel anim).
.float vis_weaponstate;
.float vis_wep_action;
.float vis_wep_anim_start;

// Forward decl — defined in client/cl_cameras.qc.
entity(float required_flag) CSQC_GetPreviewCamera;

// Forward decl — defined in client/cl_physprop.qc.  Manual ray-vs-
// cylinder override called after each weapon traceline so phys props
// (which are SOLID_NOT on CSQC to keep pmove unaffected) still register
// as bullet hits for material classification + decal suppression.
void(vector trace_src, vector trace_end) CSQC_PhysProp_OverrideTrace;

// Same cylinder math, applied to the penetration loop's reverse trace
// so exit_pos lands on the prop's back face — lets CSQC penetration
// continue past the barrel/can with reduced damage instead of dead-
// ending on entry.  Defined in client/cl_physprop.qc.
void(vector trace_src, vector trace_end) CSQC_PhysProp_OverrideBackTrace;

// Dropped weapons stay SOLID_NOT on CSQC so player prediction ignores them,
// but bullet prediction still needs to hit their visible pickup bodies.
// Defined in client/cl_weapons.qc.
void(vector trace_src, vector trace_end) CSQC_DroppedWeapon_OverrideTrace;

// CSQC-side dropped-weapon prediction. Server networks dropped weapons
// via CSQC_ENT_DROPPED_WEAPON so the client can predict pickups for
// high-ping players (instant viewmodel swap on touch). State lives on
// the CSQC entity; linked list head makes per-frame touch-check cheap.
entity dropped_weapon_list;
.entity dropped_weapon_next;
.float  dropped_weapon_id;
.float  dropped_weapon_slot;
.float  dropped_weapon_predicted_taken;   // 1 after local predicted pickup
.float  dropped_weapon_mag;               // mag_X value to apply on pickup (option B)
.float  dropped_weapon_ammo;              // ammo_X reserve to apply on pickup
.float  dropped_weapon_silencer;          // silencer toggle (M4A1, USP)
.float  dropped_weapon_physdrop;          // server-authoritative ODE body
.float  dropped_weapon_logged;            // debug: set after confirm/catchup printed,
                                          // cleared on transition back to visible,
                                          // prevents repeated prints from the server's
                                          // per-0.2s SendFlags pulses while hidden.

// Earliest cltime the fake drop is eligible to be predict-picked.
// Mirrors the server's weapon_become_solid gate: drop_ent starts as
// SOLID_NOT and only flips to SOLID_TRIGGER after
// WEAPON_DROP_PICKUP_DELAY, so the dropper can't instantly re-grab their
// own toss. Real networked entities may arrive before the pickup gate, so
// CSQC tracks this separately for local fake pickup prediction.
.float dropped_weapon_pickup_time;

// CSQC fake-drop visuals — tossed-weapon entity rendered locally for the
// dropper until the server-confirmed dropped-weapon entity arrives. Now a
// linked list (previously a single global) so a death-drop burst of up to
// four weapons can coexist. Each ent self-expires via cltime vs
// csqc_fake_drop_expire_time.
entity csqc_fake_drop_list;
.entity csqc_fake_drop_next;
.float  csqc_fake_drop_expire_time;

// Parallel to SSQC's weapon_settle_deadline (declared in sv_weapons.qc).
// Fake drops run a CSQC-side copy of weapon_settle_think so high-ping
// players see the weapon rotate flat on the floor without waiting for
// the server entity to reach them.
.float weapon_settle_deadline;
#endif

// Server-owned life generation for trusted hitclaims. Mirrored to CSQC
// visual proxies as vis_life_serial in the IDENTITY payload.
.float player_life_serial;

// Server-side hysteresis state for the backpedal flip in
// SH_PlayerAnim_Update (sh_player_anims.qc).  Declared shared (not inside
// the CSQC/SSQC blocks above) so both progs see the field — the function
// is in shared/ but only the server actually calls it.  Mirrors
// .vis_backpedaling on the client; both use the same
// cl_player_backpedal_*_angle cvars so hitboxes flip at the same instant
// the visual model does.
.float sv_backpedaling;

// Dropped-weapon "classic Quake spin" opt-in. Server-side each weapon's
// drop / map-spawn function sets this to 1 to get a continuous yaw
// rotation; CSQC replicates the flag and does the rotation locally in
// a predraw (no angle sync required — derived from cltime).
.float dropped_spin;

// Server-side ODE weapon-drop rest state. Declared shared so server-only
// shared weapon helpers can identify sleeping physics drops during traces.
.float weapon_physdrop_sleeping;

// --- Fire spread penalty tuning ---
//
// Behaviour: each fire bumps penalty by PER_SHOT (after the current
// shot's spread is computed — first shot of a fresh burst is accurate),
// penalty decays at `DECAY + DECAY_K * penalty` units/second, capped
// at MAX.
//
// The decay has two components:
//   DECAY    — linear floor.  Keeps a single shot's penalty decaying
//              to 0 in finite time (~1.5s) instead of an exponential
//              tail that lingers forever.
//   DECAY_K  — proportional accelerator.  Scales decay with the
//              current penalty so high values bleed off faster.
//              Sustained fire then reaches a soft equilibrium below
//              MAX rather than ramping linearly to the cap.
//
// AK at 10 shots/sec adds 30 penalty/sec.  Equilibrium where
// accumulation == decay:
//   30 = DECAY + penalty * DECAY_K = 2 + penalty * 4 → penalty = 7.0
// so spread asymptotes around 7/10 of MAX.  Slower-firing weapons
// settle proportionally lower.  Stop firing → high-penalty decay is
// fast (decay_rate at penalty=7 is 2 + 28 = 30/sec), low-penalty
// decay is the linear floor — both single shots and bursts feel
// snappy when you stop firing.
const float FIRE_SPREAD_PENALTY_PER_SHOT = 0.5;
const float FIRE_SPREAD_PENALTY_DECAY    = 7.0;   // linear floor (units/sec)
const float FIRE_SPREAD_PENALTY_DECAY_K  = 10.0;   // proportional rate (1/sec)
const float FIRE_SPREAD_PENALTY_MAX      = 10;    // hard cap (safety net)

// ============================================================
//  sv_gunkick view-kick state — applied per-shot, decays each
//  pmove tick via spring-damper integration. Shared between CSQC
//  and SSQC; also carried in PM_CSQC_PROXY (v19) so client-replay
//  and server pmove never drift more than one snapshot apart.
//
//  pitch / yaw  : current angular OFFSET added to the player's
//                 v_angle when the camera renders + when a bullet
//                 trace fires. Negative pitch = view kicked UP.
//  pitch_vel    : angular velocity used by the spring integrator.
//                 Each shot adds an upward impulse here; the
//                 spring (-K * displacement) integrates it back
//                 to zero with damping (-C * velocity).
//  burst_idx    : Nth shot in the current sustained-fire burst.
//                 Resets to 0 after a couple of pmove ticks of
//                 not-firing so per-burst patterns restart cleanly.
// ============================================================
.float view_kick_pitch;
.float view_kick_yaw;
.float view_kick_pitch_vel;
.float view_kick_yaw_vel;
.float view_kick_burst_idx;
// Counts pmove ticks since the fire button was last released.
// Used by the burst-idx reset gate (≥ 2 release ticks → reset)
// so a single-frame stutter at high tickrate doesn't reset the
// per-burst pattern mid-spray.
.float view_kick_release_ticks;
// sv_gunkick_instant: pending displacement that gets folded into
// view_kick_pitch / view_kick_yaw at the end of the firing tick,
// AFTER the hitscan trace has already read the un-kicked angles.
// Without this defer the instant-displacement impulse would land
// on view_kick_pitch before the trace, biasing the bullet to the
// kicked crosshair instead of the one the player saw at fire time.
// Zero on every tick; ApplyViewKick adds, TickViewKickFrame consumes.
.float view_kick_pending_pitch;
.float view_kick_pending_yaw;

// Linear-spring constants for the gunkick decay integrator.
// Cvar-overridable via sv_gunkick_decay_rate / sv_gunkick_damping;
// these are the fallback values if the cvars are zero. K = Hooke
// pull-back stiffness, C = damping. Critical damping (no overshoot,
// fastest non-oscillating return) is at C = 2*sqrt(K). Defaults
// here are critical at K=25, C=10 → ~0.5 s settle from a single
// shot, snappy without bouncing. The accumulation cap during
// sustained fire is handled separately in SH_ApplyViewKick via a
// diminishing-returns multiplier on the per-shot impulse — so the
// spring itself stays a clean linear system that's easy to tune.
const float GUNKICK_SPRING_K_DEFAULT = 25;
const float GUNKICK_DAMPING_DEFAULT  = 10;
// Displacement (degrees) at which a new shot's impulse contributes
// zero. Linear ramp from full impulse at 0° to zero at this cap.
// CS-style sustained-fire response: the first few shots punch
// hard, subsequent shots soften, reaches a soft equilibrium at
// roughly this many degrees of pitch.
const float GUNKICK_SOFT_CAP_DEG     = 8;

// Jump/landing spread penalty — applied to spread_penalty in PM_Jump and
// on airborne→grounded transition. Landing is deliberately smaller than
// jumping so touching down mid-route doesn't blow your aim as much as a
// full jump. Both sites live in shared pmove so server + CSQC always
// apply identical values to the same synced field.
const float SPREAD_PENALTY_JUMP = 4.0;
const float SPREAD_PENALTY_LAND = 1.5;

// Trigger linked list heads (populated on server by spawn, on client by CSQC_Ent_Update)
entity push_trigger_list;
entity teleport_trigger_list;
entity ladder_trigger_list;
entity conveyor_list;
// Rotating-brush carry list — populated by Mover_RotateStart server-side
// and by CSQC_SolidBrush_Update on the client whenever avelocity != 0.
// Pmove iterates this list to predict the carry math identically on
// both sides so reconcile error stays at 0 during rotation.
entity rotating_brush_list;
// Linear-motion brush list — populated by Mover_Start server-side and
// by CSQC_SolidBrush_Update on the client whenever a non-conveyor
// brush has non-zero velocity (sliding func_door / func_button while
// in transit).  Conveyors get their own list (continuous static
// motion); this is for transient door-style motion.  Client-side
// PM_CheckMovingPushers iterates and pushes players whose bbox
// intersects the brush BSP geometry (dimension-bit probe) to
// predict the server-side Mover_GeometryBlockPush pass.
entity moving_brush_list;

const float CSQC_ENT_LADDER_TRIGGER = 4;
const float CSQC_ENT_CAMERA         = 13;  // team-select preview cameras (Team_Blue/Red_Player flagged)

// Resolved look-target world origin for a "camera" entity whose .target
// points at an info_notnull.  Shared across sv_cameras.qc (sets it on
// resolve) and cl_cameras.qc + m_teamselect.qc (reads it for preview
// model placement).
.vector cam_target_origin;

// ---- trigger_push spawnflags already declared above ----

// trigger_teleport / info_teleport_destination
const float CSQC_ENT_TELEPORT_TRIGGER = 3;
const float TELEPORT_KEEPVEL          = 4;  // spawnflag: keep velocity through teleporter
const float TELEPORT_KEEPANGLE        = 8;  // spawnflag: keep current view angle (ignore dest angles)

// Per-teleport-trigger entity fields (cached destination, set at spawn time)
.vector tele_dest_origin;  // world-space destination position
.vector tele_dest_angles;  // destination view angles (zero = no snap)
.float  tele_resolved;     // TRUE once Teleport_FindDestination succeeded

// Per-player entity fields for teleport state
.float  pm_teleport_time;       // countdown guard: seconds remaining before player can re-teleport
.float  pm_ladder_detach_time;  // countdown guard: seconds remaining before player can re-grab a ladder
.float  codstamina;             // sv_codstamina: 0..1 stamina pool, depletes during sprint (1/4.5 per sec) and during hold-breath while scoped (1/8 per sec); refills otherwise (1/3 per sec).  Both sides run the same drain/refill so prediction stays in sync.
.float  codstamina_punished;    // sv_codstamina: 1 = depleted-and-still-recovering punish state (sprint locked out, hold-breath locked out + heavy-breathing punish, bar drawn red).  Clears when codstamina refills to >= STAMINA_PUNISH_RECOVER_AT.
.float  pm_last_onground_time;  // sv_codstamina: absolute world-time of the most recent on-ground tick — drives the sv_codstamina_ground_grace hysteresis in the sprint drain so single-frame FL_ONGROUND drops on clip-brush stairs don't pause the drain.  Uses `time` (pmove clock) so CSQC and SSQC agree across reconcile-replay.
.float  pm_fire_suppress_until; // sv_codstamina + cl_codscope: absolute `time` at which the post-fire scope-suppression window ends.  Set by SH_StandardTryFire on a successful shot; while time < this value, (a) the pmove stamina drain treats st_scope as 0 even with +attack2 held (fixes "drain continues after auto-unscope"), (b) cl_viewfx ADS target is forced to 0 (gun drops out of ADS), (c) the CoD scope state machine's OFF→RAISING re-entry is blocked.  When the window expires with +attack2 still held, the scope auto-re-engages (the user-requested "return to ADS scoping in after the shot is complete" behaviour).
.float  pm_on_ladder_cached;    // pm_on_ladder latched at end of PM_PlayerMoveStep so CSQC view-fx (cl_viewfx.qc) and the Weapon_LowerBlocksFire helper can read it without re-running PM_CheckLadder.  Recomputed every pmove tick; NOT replicated through the prediction proxy (the trigger list and BSP contents are already replicated, so PM_CheckLadder reproduces the value deterministically on reconcile-replay).
.float  pm_carrying;            // 1 while the player is carrying a phys_files prop (HL2 carry — sv_physprop.qc Carry_*).  Drives the lowered/deactivated viewmodel + fire-block exactly like grapple_rope_active: SSQC sets it authoritatively, REPLICATED through the prediction proxy (sv_player.qc writer ↔ cl_player.qc reader) so CSQC's Weapon_LowerBlocksFire / lower envelope agree and firing doesn't mispredict.
.float  pm_fuser2;              // CS 1.6 stamina: msec of landing fatigue remaining (0 = none)
.float  pm_step_time;           // seconds until next footstep sound fires
.float  sv_last_step_time;      // SSQC-only: time of last PM_EmitStepSound fire, used by sv_debug_footsteps to print cadence delta between server step events
.vector pm_anim_prev_origin;    // previous-frame origin for distance-based leg cycle timing
.entity pm_ground_ent;          // entity the player is standing on (captured after the ground trace in PM_CategorizePosition); used to play metal footsteps when it's the phys_files cabinet


// Custom player stats — sent from server to client via clientstat()
const float STAT_CROSSHAIR_BASESPREAD = 32;
const float STAT_CROSSHAIR_MOVESPREAD = 33;
const float STAT_CROSSHAIR_FULLSPEED  = 34;
const float STAT_CROSSHAIR_GAPSCALE   = 35;
const float STAT_CROSSHAIR_DISABLED   = 36;

// Zoom/scope stats
const float STAT_ZOOMSTAGE            = 42;
const float ZOOM_FOV_STAGE1           = 24;
const float ZOOM_FOV_STAGE2           = 12;

// Per-player model choice (shared so animation lookups can branch on it)
.float player_model_index;  // 0-3 = team models, 5 = sini, 6 = chickenman, 7 = numberK, 8 = kilmer
.entity player_visual_proxy;

// Hitgroup constants (GoldSrc standard)
const float HITGROUP_GENERIC  = 0;
const float HITGROUP_HEAD     = 1;
const float HITGROUP_CHEST    = 2;
const float HITGROUP_STOMACH  = 3;
const float HITGROUP_LEFTARM  = 4;
const float HITGROUP_RIGHTARM = 5;
const float HITGROUP_LEFTLEG  = 6;
const float HITGROUP_RIGHTLEG = 7;

// Team constants
const float TEAM_NONE = 0;
const float TEAM_BLUE = 1;
const float TEAM_RED  = 2;
const float TEAM_SPEC = 3;

// Camera entity spawnflags (map-authored) — tag each "camera" point entity
// with which team-select phase it should cycle in.  No flags = neutral
// camera, used on the initial team-pick screen (or as fallback).
const float CAM_FLAG_TEAM_BLUE         = 1;
const float CAM_FLAG_TEAM_RED          = 2;
const float CAM_FLAG_TEAM_BLUE_PLAYER  = 4;
const float CAM_FLAG_TEAM_RED_PLAYER   = 8;

// Team-select camera phases — the menu tells the server which one the
// client is in via `cmd cam_phase <N>`, and the server picks cameras
// whose spawnflag matches.  Phase 0 selects unflagged cameras.
const float CAM_PHASE_NEUTRAL        = 0;
const float CAM_PHASE_TEAM_BLUE      = 1;
const float CAM_PHASE_TEAM_RED       = 2;
const float CAM_PHASE_BLUE_PLAYER    = 3;
const float CAM_PHASE_RED_PLAYER     = 4;

// Player model choices per team (indices 0-3)
// All player models migrated from HL studio .mdl to IQM so the
// FTE Alias_BlendBoneData renderer can blend between sequences
// (.frame2 + .lerpfrac).  Each .iqm + its BMP textures sit in
// models/player/<name>/.  Generated by
// C:/Users/Lex/Desktop/playermodels/generate_iqm.py.
string team_blue_models[] = {
    "models/player/urban/urban.iqm",
    "models/player/gign/gign.iqm",
    "models/player/gsg9/gsg9.iqm",
    "models/player/sas/sas.iqm"
};
string team_blue_names[] = { "Urban", "GIGN", "GSG9", "SAS" };

string team_red_models[] = {
    "models/player/guerilla/guerilla.iqm",
    "models/player/leet/leet.iqm",
    "models/player/terror/terror.iqm",
    "models/player/arctic/arctic.iqm"
};
string team_red_names[] = { "Guerilla", "Leet", "Terror", "Arctic" };

const float TEAM_MODEL_COUNT = 4;

// Resolve a networked team_model_byte back to a model path.  Decoder half of the encoder in
// sv_player.qc (PlayerVisual writer): 252-255 = team-independent sentinels, else (team-1)*4 + model.
// Used client-side by the visual proxy (cl_player.qc) AND the seated car-driver render (cl_physprop.qc)
// so both pick the SAME model the server encoded.  Lives here (shared) next to the model arrays.
string(float tmbyte) SH_ModelPathForTeamByte =
{
    if (tmbyte == 255) return "models/player/sini.mdl";
    if (tmbyte == 254) return "models/player/chickenman/chickenman.iqm";
    if (tmbyte == 253) return "models/player/numberk/numberK.iqm";
    if (tmbyte == 252) return "models/player/kilmer/kilmer.iqm";
    float vteam  = floor(tmbyte / 4);        // 0 = blue, 1 = red (matches (team-1) in the encoder)
    float vmodel = tmbyte - vteam * 4;       // 0..3 model index within the team
    if (vteam == 0) return team_blue_models[vmodel];
    return team_red_models[vmodel];
};

// Team stats — sent from server to client via clientstat()
const float STAT_PLAYERTEAM       = 39;
const float STAT_TEAMMENU_REQUEST = 40;

// Round timer stat — seconds remaining in the current round
const float STAT_ROUNDTIMER       = 41;
const float STAT_MAPTIMELEFT      = 43;
const float STAT_ROUNDNUM         = 44;
const float STAT_MAXROUNDS        = 45;
const float STAT_ROUND_PHASE      = 46;
const float STAT_FREEZE_TIMELEFT  = 47;
const float STAT_GAMEMODE         = 48;
const float STAT_WINNING_TEAM     = 49;
const float STAT_DEATH_DELAY_LEFT = 50;
const float STAT_IS_DEAD          = 51;
const float STAT_BLUE_SCORE       = 52;
const float STAT_RED_SCORE        = 53;
// Per-player defuse progress (0..CFC4_DEFUSE_TIME).  Set by
// C4_TickDefuseInteraction in sh_wpn_cfc4.qc on the active defuser
// only; everyone else reads 0.  HUD bar visibility gates on > 0.
const float STAT_DEFUSE_PROGRESS  = 54;

// sv_func_tickrate mirror.  The cvar is registered with CVAR_SIDE_SV
// (sh_cvar_table.qc:996) so cvar() on CSQC returns 0 and prediction
// hits the hardcoded fallback in PM_CheckRotatingCarry — which causes
// a per-second slide-rate mismatch with the server when the admin
// changes sv_func_tickrate from its default.  Publishing the value
// per-snapshot via this stat closes the loop: CSQC reads getstatf()
// and matches the server's authoritative rate within one tick.
const float STAT_FUNC_TICKRATE    = 55;

// CS-style economy.  STAT_MONEY = the owning player's current cash (drives
// the HUD money line + buy-menu greyout).  STAT_CSARMOR = current Kevlar value
// (0..100).  NOTE: named CSARMOR, not ARMOR — the engine ALREADY defines a
// built-in `const float STAT_ARMOR = 4` (cl_defs.qc / fteextensions.qc).  A
// duplicate const keeps the FIRST (engine) definition, so a mod STAT_ARMOR=57
// silently resolved to 4, and getstatf(STAT_ARMOR) read the engine's unused
// armor stat (always 0) — armor never showed on the HUD.  Both published
// per-snapshot via clientstat in sv_main.qc.
const float STAT_MONEY            = 56;
const float STAT_CSARMOR          = 57;
// 1 when the owning player may currently buy (inside an allowed func_buyzone,
// or mp_buyanywhere, or the map has no buy zones).  Drives the HUD money
// colour (yellow = can buy).
const float STAT_IN_BUYZONE       = 58;
// 1 when the owning C4 carrier may plant at their current spot (mp_plantanywhere,
// or the map has no func_bomb_target, or standing inside one).  The client reads
// this to gate the plant PREFIRE animation — mp_plantanywhere / the bomb-target
// volumes are server-only, so without it the client predicts the plant anim where
// the server would deny it (anim plays, no bomb).  Set by C4_CanPlantHere.
const float STAT_CAN_PLANT        = 59;
// 1 while a planted_c4 is live in Defuse mode (between plant and explode/
// defuse/round-restart).  Suspends the round clock (the bomb fuse owns the
// round now) and hides the round timer from the HUD until the next round.
// Set server-side from find(world,"planted_c4"); 0 in every other gamemode.
const float STAT_BOMB_PLANTED     = 60;

// nettest progression spine (Part 1) — persistent XP / level, networked to the
// owning client.  STAT_XP is XP banked into the current level (0..STAT_XP_NEXT).
const float STAT_XP               = 61;
const float STAT_LEVEL            = 62;
const float STAT_XP_NEXT          = 63;
const float STAT_PROG_SESSIONXP   = 64;   // XP earned this session (match-end summary)

// Shared marker: 1 on a server-side AI bot (spawnclient).  Declared shared so
// W_ShouldDeferToClaim (sh_weapon_standard.qc) can apply a bot's hitscan damage
// server-side instead of deferring to a client hitclaim that never comes.
// Always 0 on the client (not networked).
.float is_bot;

// Gamemode constants
const float GAMEMODE_TDM         = 0;
const float GAMEMODE_ELIMINATION = 1;
const float GAMEMODE_BHOP        = 2;
const float GAMEMODE_FFA         = 3;
// Paintgun: elimination-style round flow + paintball-only loadout +
// any tag (paintball or snowball hit) is lethal with a fixed DEATH2
// animation so getting "tagged" reads visually clean.
const float GAMEMODE_PAINTGUN    = 4;
// Defuse: red team auto-receives one C4 charge per round (random pick at
// RoundStart, fallback to first-red-spawn).  Round ends on bomb explode
// (red wins) or full defuse (blue wins).  Standard team elimination
// still applies as a fallback win condition.
const float GAMEMODE_DEFUSE      = 5;
// Prop Hunt: RED = SEEKERS, BLUE = HIDERS.  Teams force-shuffled every round
// (~mp_ph_ratio hiders per seeker).  The freeze phase is the HIDE phase —
// hiders run free while seekers are locked + blindfolded (SH_RoundFreezeLocksPlayer).
// Hiders +use a prop to become a copy of it (HP scaled by prop size), +reload
// toggles rotation lock.  Seekers hurt themselves shooting real props and heal
// on hider kills.  Timer expiry = hiders win; a team wiped = other team wins.
const float GAMEMODE_PROPHUNT    = 6;

// --- Prop Hunt disguise state (shared: SSQC player, CSQC proxies) -----------
// Server-authoritative.  The collision hull is QUANTIZED to 3 bytes at
// possession (sv_prophunt.qc) and the server itself uses only the dequantized
// values; the same bytes ship on the visual proxy (broadcast) AND the
// prediction proxy (owner), so the predicted hull is bit-identical to the
// server's — any drift here means rubber-banding while disguised.
// Hull is PROP-PIVOT-RELATIVE: the player origin becomes the prop pivot, so
// the rendered prop, the traced mesh and the hull all coincide.
// `.ph_disguise_modelindex != 0` is THE "is disguised" predicate everywhere.
// On CSQC the same fieldnames live on the visual proxy (hitgroup normalize +
// render) and on predicted_player (hull/eye for prediction).
.float ph_disguise_modelindex;	// server modelindex of the copied prop (0 = undisguised)
.float ph_hull_halfxy;			// dequantized COLLISION hull half-width (1..16, never wider than the player hull)
.float ph_hull_minz;			// hull bottom relative to origin (-64..63)
.float ph_hull_height;			// hull height (4..72)
.float ph_yaw_locked;			// rotation COMMITTED flag: 0 = loose (yaw follows view), 1 = world-absolute pose held
// Free 3-axis prop orientation, stored as a forward/up BASIS in the carry frame
// (yaw0 = v_angle_y + 180), exactly like a carried prop's carry_rel_fwd/up.  Shared
// so CSQC can predict the local player's pose zero-ping while holding the rotate key.
// Composed to .angles via CarryRot_FromFrame + CarryRot_Angles (sh_carryrot.qc).
// Seeded upright ('-1 0 0' fwd / '0 0 1' up) on PropHunt_Possess — the '-1' faces the
// pose to angles_y = v_angle_y (matches the old flat facing; see PropHunt_Possess).
.vector ph_rel_fwd;
.vector ph_rel_up;

// The prop's TRUE square half-footprint, unclamped by the player hull.
//
// This is deliberately NOT ph_hull_halfxy.  Those two numbers answer different questions
// and briefly got conflated:
//   ph_hull_halfxy — what the PLAYER COLLIDES WITH.  Capped at the standing player hull,
//                    because becoming a big prop must not stop you tucking into a corner.
//                    Widening this made bulky disguises nearly unhideable, which is the
//                    whole point of the mode.
//   ph_mesh_halfxy — where the prop's GEOMETRY actually is.  Used only to build the
//                    trace-time enclosure (PH_ExpandTraceBbox) and to ground the drawn
//                    prop; never for movement, never for the possess room test.
//
// So a wide crate collides like a player and shoots like a crate.  Rides the visual-proxy
// IDENTITY wire (one byte, sent only when the disguise changes), so it costs nothing per
// snapshot.  0 = not set: PH_Mesh* falls back to the collision hull.
.float ph_mesh_halfxy;

// Same split on the vertical: the prop's TRUE height, where ph_hull_height is capped at
// the standing player height so becoming a tall prop never makes you taller than you
// already were (you keep fitting under the same lips and vents).  Without this the cap
// would also shrink the trace enclosure and leave the top of every tall prop unshootable.
//
// Shares ph_hull_minz as its base — both boxes are anchored at the prop's bottom and only
// differ in reach — so this costs one byte, not two.
.float ph_mesh_height;

// Trace-only hit volume bookkeeping — see PH_ExpandTraceBbox (shared/sh_weapons.qc),
// which swaps in an AABB that encloses the rotated prop for the duration of a weapon
// trace and restores it inside the same QC frame.  Absolute saves rather than delta
// math so the restore is exact no matter what the expand computed.
.vector ph_trace_mins_save;
.vector ph_trace_maxs_save;
.float  ph_trace_inflated;

vector(entity e) PH_HullMins =
{
	vector m;
	m_x = -e.ph_hull_halfxy;
	m_y = -e.ph_hull_halfxy;
	m_z = e.ph_hull_minz;
	return m;
};
vector(entity e) PH_HullMaxs =
{
	vector m;
	m_x = e.ph_hull_halfxy;
	m_y = e.ph_hull_halfxy;
	m_z = e.ph_hull_minz + e.ph_hull_height;
	return m;
};

// The prop's GEOMETRY box — its true footprint and true height, neither of them clamped to
// the player hull.  Use for anything that must match where the prop's mesh actually is: the
// trace enclosure and the render's floor-grounding.  NEVER for movement, the possess room
// test, or PM_CurrentMins/Maxs — those are collision, and collision stays player-sized on
// purpose so a bulky disguise can still hide in a corner and duck under the same geometry.
//
// Shares ph_hull_minz: both boxes are anchored at the prop's bottom and differ only in how
// far out and up they reach.
//
// Each axis falls back to the collision hull when its mesh field is unset (an undisguised
// player, or a proxy whose IDENTITY section has not landed yet), so the box is never larger
// than something we actually know about.
//
// KNOWN LIMIT, pre-existing and unchanged: ph_hull_minz is quantized to [-64, 63], so a prop
// whose base sits further than that below its own origin has the BOTTOM of its mesh box
// clipped.  Nothing in the current prop set comes close.
float(entity e) PH_MeshHalfXY =
{
	return (e.ph_mesh_halfxy > e.ph_hull_halfxy) ? e.ph_mesh_halfxy : e.ph_hull_halfxy;
};
float(entity e) PH_MeshHeight =
{
	return (e.ph_mesh_height > e.ph_hull_height) ? e.ph_mesh_height : e.ph_hull_height;
};
vector(entity e) PH_MeshMins =
{
	vector m;
	m_x = -PH_MeshHalfXY(e);
	m_y = m_x;
	m_z = e.ph_hull_minz;
	return m;
};
vector(entity e) PH_MeshMaxs =
{
	vector m;
	m_x = PH_MeshHalfXY(e);
	m_y = m_x;
	m_z = e.ph_hull_minz + PH_MeshHeight(e);
	return m;
};

// Returns TRUE for gamemodes that present every player as one big team:
// no Phase 0 team-pick (one unified character-select panel), single
// scoreboard column, merged spawn pool (both blue + red spawn entities),
// friendly-fire bypassed. Currently FFA + Bhop. Add new modes here as
// they're created — every site that needs the "unified" treatment routes
// through this single check, so the codebase stays symmetric.
//
// Reads sv_gamemode on SSQC and STAT_GAMEMODE on CSQC; same value either
// way (sv_main.qc pushes the gamemode to the clientstat each tick).
float() Gamemode_HasUnifiedTeams =
{
#ifdef CSQC
    float gm = getstatf(STAT_GAMEMODE);
#else
    float gm = cvar("sv_gamemode");
#endif
    return gm == GAMEMODE_FFA || gm == GAMEMODE_BHOP;
};

// Round phase constants
const float ROUND_PHASE_NONE      = 0;
const float ROUND_PHASE_FREEZE    = 1;
const float ROUND_PHASE_ACTIVE    = 2;
const float ROUND_PHASE_ROUND_END = 3;
const float ROUND_PHASE_MAP_END   = 4;

// Forward decls — precache_everything() below calls into units that compile LATER.
// This file is line 3 in both .src files; sh_matsounds.qc is line 10 and sh_pmove.qc
// is line 20 (cl) / 150 (sv).  Missing these is a hard fteqcc error, not a silent bug.
void() MatSnd_PrecacheAll;   // shared/sh_matsounds.qc — scripts/materialsounds.txt sound sets
void() FS_PrecacheAll;       // shared/sh_pmove.qc     — the FS_SOUND_* footstep catalogue

#ifdef SSQC
void(entity owner) phys_barrel_spawn_infront;
void(entity owner) phys_can_spawn_infront;
void(entity owner) phys_files_spawn_infront;
void() phys_barrel_precache;

// Per-frame cvar cache — refreshed once per StartFrame (sv_main.qc) so
// hot-path readers (Player_VisualProxy_Sync, SH_PlayerAnim_Update) can
// read these constants without paying for cvar() every call.  Declared
// here because sh_player_anims.qc references them and compiles before
// sv_main.qc in sv_progs.src.
float sv_cached_anim_resend_interval;
float sv_cached_anim_qu_per_sec;
float sv_cached_anim_qu_per_sec_crouch;

// Phys-prop per-frame cvar cache — same deal, but for the PROP tick path, which is
// the hottest cvar consumer on a prop-dense map: PhysObj_Think runs at 64 Hz for
// EVERY free prop, and each pass through PhysObj_DetectContactFX used to hash-look-up
// sv_physprop_impact_min_speed + sv_physprop_slide_min_speed (~1600 lookups/tick with
// a few hundred props).  Refreshed once per StartFrame; read as plain globals below.
float pp_cached_impact_min_speed;
float pp_cached_impact_hard_speed;
float pp_cached_impact_cooldown;
float pp_cached_slide_min_speed;
float pp_cached_slide_interval;
float pp_cached_scrape_track;
float pp_cached_stream_hz;        // sv_physprop_stream_hz — moving-mirror send throttle
float pp_cached_sleep_enable;     // sv_physprop_sleep — 1 = resting props drop to the slow tick
float pp_cached_sleep_hz;         // sv_physprop_sleep_hz — slow-tick rate for a settled prop
float pp_cached_debug;            // sv_debug_physprops
// Buoyancy per-frame cache.  force_iter and meshpitch/roll are cvar reads that would otherwise be
// made per-prop-per-tick; Phys_ForceIter in particular does a cvar_string + string compare.
float pp_cached_buoyancy;         // sv_prop_buoyancy — master toggle
float pp_cached_buoy_density;     // sv_prop_buoyancy_density — density of water in the pm_density scale
float pp_cached_buoy_damping;     // sv_prop_buoyancy_damping — target heave damping RATIO (zeta)
float pp_cached_gravity;          // sv_gravity — Buoy_Tick needs it per prop per tick
float pp_cached_force_iter;       // Phys_ForceIter() — backend force scale (ODE substep compensation)
float pp_cached_meshpitch;        // r_meshpitch — the backend applies this when building the body quat
float pp_cached_meshroll;         // r_meshroll

// Car per-frame cvar cache.  Only the reads that a PARKED (asleep) car still makes every
// tick live here — Car_TickInterval + the live box re-tune + the sleep gate itself.  The
// ~40 sv_car_* tuning reads inside Car_PhysStep are deliberately NOT cached: the sleep gate
// skips PhysStep entirely for parked cars (the common case), so those only run for a car
// someone is actually driving — 1-2 cars, i.e. noise (Car_Cvar profiled at 0.006s/5s).
float car_cached_mintic;          // sv_mintic
float car_cached_wheel_sink;      // sv_car_wheel_sink
float car_cached_box_yaw;         // sv_car_box_yaw
float car_cached_sleep_enable;    // sv_car_sleep
#endif

void() precache_everything =
{
	precache_sound("sounds/null.wav");

#ifdef SSQC
	phys_barrel_precache();
#endif


    // Player Models
    // nettest Patch 36 Part B: register the per-bone hitbox table (sh_weapons.qc) on each
    // player model right after precache, in BOTH progs, so MOVE_HITMODEL traces the boxes
    // (native per-bone hit detection) and returns the struck box's hitgroup.  Hitbox_Register-
    // Model no-ops on the sini .mdl (HL native hitboxes) and on any unpatched engine.
    Hitbox_RegisterModel(precache_model("models/player/arctic/arctic.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/gign/gign.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/gsg9/gsg9.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/sas/sas.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/guerilla/guerilla.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/leet/leet.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/terror/terror.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/urban/urban.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/sini.mdl"));
    Hitbox_RegisterModel(precache_model("models/player/chickenman/chickenman.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/numberk/numberK.iqm"));
    Hitbox_RegisterModel(precache_model("models/player/kilmer/kilmer.iqm"));

	// Player Models / Sounds
	precache_sound("sounds/player/use.wav");
	precache_sound("sounds/player/spray.wav");
	precache_sound("sounds/player/weapondrop.wav");
	// Footsteps: the WHOLE FS_SOUND_* catalogue, derived from FS_SoundName() so the enum
	// in sh_pmove.qc stays the ONLY place a footstep path is written.  Covers the generic
	// step / waterstep / ladder sets AND all 8 material sets.  Both VMs (SSQC multicasts
	// the byte and puts the names in the soundlist; CSQC plays them by name via
	// localsound/pointsound).  Replaces the step1-4 / metal_box_footstep1-4 / ladder1-4 /
	// waterstep1-10 literals that used to be listed here by hand.
	FS_PrecacheAll();
	// Per-material contact sounds (scripts/materialsounds.txt): server = every kind,
	// client = bullet rics only.  Replaces the metal_solid_impact_bullet1-4 literals here
	// and the 18-call hand-list that used to live in sv_physprop.qc.
	MatSnd_PrecacheAll();
	precache_sound("sounds/player/fallpain1.wav");
	precache_sound("sounds/player/fallpain2.wav");
	// sv_sliding random one-shot pool — PM_TryEngageSlide picks one of
	// these uniformly at every engage.
	precache_sound("sounds/player/slide1.wav");
	precache_sound("sounds/player/slide2.wav");
	precache_sound("sounds/player/slide3.wav");
	precache_sound("sounds/player/slide4.wav");
	precache_sound("sounds/player/slide5.wav");
	// sv_snipersway + cl_codscope hold-breath cues — played on
	// +button4 press / release while the player is scoped.
	precache_sound("sounds/player/breathin.wav");
	precache_sound("sounds/player/breathout.wav");
	// Heartbeat — 1 Hz pulse during hold-breath (cl_codscope.qc).
	// outofbreath — fires once when codstamina_punished latches.
	precache_sound("sounds/player/heartbeat.wav");
	precache_sound("sounds/player/outofbreath.wav");
	// sv_grappling — fire, hook-impact, pull-loop.
	precache_sound("sounds/player/grappling.wav");
	precache_sound("sounds/player/hook.wav");
	precache_sound("sounds/player/grapplingpull.wav");
	precache_sound("sounds/player/grappledisconnect.wav");
	// Grapple hook anchor entity — bubble sprite as a known-present
	// placeholder so the engine assigns a real modelindex and broadcasts
	// the entity to clients.  EF_NODRAW on the entity keeps it
	// invisible; CSQC walks entities by this modelindex to find the
	// rope's far endpoint.  progs/s_null.spr was the cleaner choice but
	// isn't shipped with the gamedir.
	precache_model("progs/s_bubble.spr");
	precache_sound("sounds/player/bullethit1.wav");
	precache_sound("sounds/player/bullethit2.wav");
	precache_sound("sounds/weapons/hitmarker.wav");

	// All guns
	precache_model("models/weapons/9mmcasing.mdl");
	precache_model("models/weapons/redcasing.mdl");
	precache_model("models/weapons/riflecasing.mdl");
	precache_model("models/weapons/riflecasingbig.mdl");
	precache_model("models/weapons/shotgunshell1.mdl");
	precache_model("models/weapons/shotgunshell2.mdl");
	precache_model("models/weapons/pistolmag.mdl");
	precache_model("models/weapons/pistolmaghl.mdl");
	precache_model("models/weapons/riflemag.mdl");
    precache_model("models/weapons/crossbowclip.mdl");
	precache_sound("sounds/weapons/casing1.wav");
	precache_sound("sounds/weapons/casing2.wav");
	precache_sound("sounds/weapons/casing3.wav");
	precache_sound("sounds/weapons/draw.wav");
	precache_sound("sounds/weapons/dryfire1.wav");
	precache_sound("sounds/weapons/pickup1.wav");
    precache_sound("sounds/weapons/explode1.wav");
    precache_sound("sounds/weapons/explode2.wav");
    precache_sound("sounds/weapons/explode3.wav");
	precache_sound("sounds/weapons/ric1.wav");
	precache_sound("sounds/weapons/ric2.wav");
	precache_sound("sounds/weapons/ric3.wav");
	precache_sound("sounds/weapons/ric4.wav");
	precache_sound("sounds/weapons/ric5.wav");
	precache_sound("sounds/weapons/hitmarker.wav");

    // Gibs Models
    precache_model("models/gibs/debris1.mdl");
    precache_model("models/gibs/debris2.mdl");
    precache_model("models/gibs/debris3.mdl");
    precache_model("models/gibs/woodgib1.mdl");
    precache_model("models/gibs/woodgib2.mdl");
    precache_model("models/gibs/woodgib3.mdl");
    precache_model("models/gibs/glassgibs.mdl");

    // Gibs Sounds
    precache_sound("sounds/debris/break_concretehl1.wav");
    precache_sound("sounds/debris/break_concretehl2.wav");

    precache_sound("sounds/debris/break_eletronichl1.wav");
    precache_sound("sounds/debris/break_eletronichl2.wav");
    precache_sound("sounds/debris/break_eletronichl3.wav");
    precache_sound("sounds/debris/break_eletronichl4.wav");
    precache_sound("sounds/debris/break_eletronichl5.wav");
    precache_sound("sounds/debris/break_eletronichl6.wav");
    precache_sound("sounds/debris/break_eletronichl7.wav");
    precache_sound("sounds/debris/break_eletronichl8.wav");

    precache_sound("sounds/debris/break_fleshhl1.wav");
    precache_sound("sounds/debris/break_fleshhl2.wav");

    precache_sound("sounds/debris/break_glasshl1.wav");
    precache_sound("sounds/debris/break_glasshl2.wav");
    precache_sound("sounds/debris/break_glasshl3.wav");

    precache_sound("sounds/debris/break_metalhl1.wav");
    precache_sound("sounds/debris/break_metalhl2.wav");

    precache_sound("sounds/debris/break_woodhl1.wav");
    precache_sound("sounds/debris/break_woodhl2.wav");
    precache_sound("sounds/debris/break_woodhl3.wav");

    precache_sound("sounds/debris/impact_concretehl1.wav");
    precache_sound("sounds/debris/impact_concretehl2.wav");
    precache_sound("sounds/debris/impact_concretehl3.wav");

    precache_sound("sounds/debris/impact_fleshhl1.wav");
    precache_sound("sounds/debris/impact_fleshhl2.wav");
    precache_sound("sounds/debris/impact_fleshhl3.wav");
    precache_sound("sounds/debris/impact_fleshhl4.wav");
    precache_sound("sounds/debris/impact_fleshhl5.wav");
    precache_sound("sounds/debris/impact_fleshhl6.wav");

    precache_sound("sounds/debris/impact_glasshl1.wav");
    precache_sound("sounds/debris/impact_glasshl2.wav");
    precache_sound("sounds/debris/impact_glasshl3.wav");
    precache_sound("sounds/debris/impact_glasshl4.wav");

    precache_sound("sounds/debris/impact_metalhl1.wav");
    precache_sound("sounds/debris/impact_metalhl2.wav");
    precache_sound("sounds/debris/impact_metalhl3.wav");
    precache_sound("sounds/debris/impact_metalhl4.wav");
    precache_sound("sounds/debris/impact_metalhl5.wav");
    precache_sound("sounds/debris/impact_metalhl6.wav");

    precache_sound("sounds/debris/impact_woodhl1.wav");
    precache_sound("sounds/debris/impact_woodhl2.wav");
    precache_sound("sounds/debris/impact_woodhl3.wav");
    precache_sound("sounds/debris/impact_woodhl4.wav");

    //Old Gib Sounds
    precache_sound("sounds/debris/break_glass.wav");
    precache_sound("sounds/debris/break_rock.wav");
    precache_sound("sounds/debris/break_wood.wav");
    precache_sound("sounds/debris/break_metal.wav");
    precache_sound("sounds/debris/impact_glass.wav");
    precache_sound("sounds/debris/impact_conc.wav");
    precache_sound("sounds/debris/impact_metal.wav");

	// CS 1.6 USP with actually GoldSrc MDL

    // Third-person weapon models (p_models)
    precache_model("models/weapons/wpn_csak47/p_ak47.mdl");
    precache_model("models/weapons/wpn_hdak47/p_ak47.mdl");
    precache_model("models/weapons/wpn_csawp/p_awp.mdl");
    precache_model("models/weapons/wpn_csdeagle/p_deagle.mdl");
    precache_model("models/weapons/wpn_csg3sg1/p_g3sg1.mdl");
    precache_model("models/weapons/wpn_csglock/p_glock.mdl");
    precache_model("models/weapons/wpn_csknife/p_knife.mdl");
    precache_model("models/weapons/wpn_butteryfly/p_knife.mdl");
    precache_model("models/weapons/wpn_cfaug/p_aug.mdl");
    precache_model("models/weapons/wpn_cffamas/p_famas.mdl");
    precache_model("models/weapons/wpn_cfmac10/p_mac10.mdl");
    precache_model("models/weapons/wpn_cfc4/p_c4.mdl");
    precache_model("models/weapons/wpn_csm3/p_m3.mdl");
    precache_model("models/weapons/wpn_csm4a1/p_m4a1.mdl");
    precache_model("models/weapons/wpn_csm249/p_m249.mdl");
    precache_model("models/weapons/wpn_csmp5/p_mp5.mdl");
    precache_model("models/weapons/wpn_csscout/p_scout.mdl");
    precache_model("models/weapons/wpn_dod98k/p_k98.mdl");

	// HL SMG
	precache_model("models/weapons/wpn_hlsmg/w_smg.mdl");
	precache_model("models/weapons/wpn_hlsmg/v_smg.mdl");
    precache_model("models/weapons/wpn_hlsmg/grenade.mdl");
    precache_sound("sounds/weapons/wpn_hlsmg/fire1.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/fire2.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/fire3.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/glauncher1.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/glauncher2.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/reload2.wav");

	// HL RPG
	precache_model("models/weapons/wpn_hlrpg/rpgrocket.mdl");
	precache_model("models/weapons/wpn_hlrpg/w_rpg.mdl");
	precache_model("models/weapons/wpn_hlrpg/v_rpg.mdl");
    precache_sound("sounds/weapons/wpn_hlrpg/fire.wav");
    precache_sound("sounds/weapons/wpn_hlrpg/fly.wav");

	// HL Grenade
    precache_model("models/weapons/wpn_hlgrenade/w_grenade.mdl");
    precache_model("models/weapons/wpn_hlgrenade/v_grenade.mdl");
    precache_sound("sounds/weapons/wpn_hlgrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/explode3.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/hit1.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/hit2.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/hit3.wav");

	// CS throwable utilities
    precache_model("models/weapons/wpn_cshegrenade/v_hegrenade.mdl");
    precache_model("models/weapons/wpn_cshegrenade/w_hegrenade.mdl");
    precache_model("models/weapons/wpn_cshegrenade/p_hegrenade.mdl");
    precache_sound("sounds/weapons/wpn_cshegrenade/pinpull.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/bounce.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode3.wav");
    precache_model("models/weapons/wpn_csflashbang/v_flashbang.mdl");
    precache_model("models/weapons/wpn_csflashbang/w_flashbang.mdl");
    precache_model("models/weapons/wpn_csflashbang/p_flashbang.mdl");
    precache_sound("sounds/weapons/wpn_csflashbang/pinpull.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/bounce1.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/bounce2.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/explode1.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/explode2.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/ringing.wav");
    precache_model("models/weapons/wpn_cssmokegrenade/v_smokegrenade.mdl");
    precache_model("models/weapons/wpn_cssmokegrenade/w_smokegrenade.mdl");
    precache_model("models/weapons/wpn_cssmokegrenade/p_smokegrenade.mdl");
    precache_sound("sounds/weapons/wpn_cssmokegrenade/pinpull.wav");
    precache_sound("sounds/weapons/wpn_cssmokegrenade/bounce1.wav");
    precache_sound("sounds/weapons/wpn_cssmokegrenade/bounce2.wav");
    precache_sound("sounds/weapons/wpn_cssmokegrenade/explode.wav");
    // CS HE-grenade explosion sprite (single new asset; replaces
    // the old hl_explode 3-variant set).
    precache_model("gfx/eexplo.spr");

	// Snowball / slingshot
    precache_model("models/weapons/wpn_snowball/v_snowball.mdl");
    precache_model("models/weapons/wpn_snowball/w_snowball.mdl");
    precache_model("models/weapons/wpn_snowball/p_snowball.mdl");
    precache_model("models/weapons/wpn_snowball/v_slingshot.mdl");
    precache_model("models/weapons/wpn_snowball/w_slingshot.mdl");
    precache_model("models/weapons/wpn_snowball/p_slingshot.mdl");
    precache_sound("sounds/weapons/wpn_snowball/hit.wav");
    precache_sound("sounds/weapons/wpn_snowball/throw.wav");
    precache_sound("sounds/weapons/wpn_snowball/stretch.wav");
    precache_sound("sounds/weapons/wpn_snowball/snap.wav");

	// Paintball
    precache_model("models/weapons/wpn_paintball/v_excal.mdl");
    precache_model("models/weapons/wpn_paintball/w_excal.mdl");
    precache_model("models/weapons/wpn_paintball/p_excal.mdl");
    precache_sound("sounds/weapons/wpn_paintball/fire.wav");
    precache_sound("sounds/weapons/wpn_paintball/lidopen.wav");
    precache_sound("sounds/weapons/wpn_paintball/lidclose.wav");
    precache_sound("sounds/weapons/wpn_paintball/reload.wav");

	// HL Glock
    precache_model("models/weapons/wpn_hlglock/w_glock.mdl");
    precache_model("models/weapons/wpn_hlglock/v_glock.mdl");
    precache_sound("sounds/weapons/wpn_hlglock/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlglock/fire.wav");
    precache_sound("sounds/weapons/wpn_hlglock/reload2.wav");

	// HL Egon
    precache_model("models/weapons/wpn_hlegon/w_egon.mdl");
    precache_model("models/weapons/wpn_hlegon/v_egon.mdl");
    precache_sound("sounds/weapons/wpn_hlegon/windup.wav");
    precache_sound("sounds/weapons/wpn_hlegon/off.wav");
    precache_sound("sounds/weapons/wpn_hlegon/run.wav");

	// CS Glock
    precache_model("models/weapons/wpn_csglock/w_glock.mdl");
    precache_model("models/weapons/wpn_csglock/v_glock.mdl");
    precache_sound("sounds/weapons/wpn_csglock/reload.wav");
    precache_sound("sounds/weapons/wpn_csglock/fire.wav");
    precache_sound("sounds/weapons/wpn_csglock/fireburst.wav");
    precache_sound("sounds/weapons/wpn_csglock/sliderelease.wav");
    precache_sound("sounds/weapons/wpn_csglock/slideback.wav");

	// CS g3sg1
    precache_model("models/weapons/wpn_csg3sg1/w_g3sg1.mdl");
    precache_model("models/weapons/wpn_csg3sg1/v_g3sg1.mdl");
    precache_sound("sounds/weapons/wpn_csg3sg1/clipin.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/clipout.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/fire.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/slide.wav");

	// HL Gauss
    precache_model("models/weapons/wpn_hlgauss/w_gauss.mdl");
    precache_model("models/weapons/wpn_hlgauss/v_gauss.mdl");
    precache_sound("sounds/weapons/wpn_hlgauss/charge.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/electro1.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/electro2.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/electro3.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/fire.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce1.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce2.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce3.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce4.wav");
    precache_sound("sounds/weapons/wpn_hlgauss/bounce5.wav");

	// HL Crossbow
    precache_model("models/weapons/wpn_hlcrossbow/w_crossbow.mdl");
    precache_model("models/weapons/wpn_hlcrossbow/v_crossbow.mdl");
    precache_model("models/weapons/wpn_hlcrossbow/bolt.mdl");
    precache_model("models/weapons/crossbowclip.mdl");
    precache_sound("sounds/weapons/wpn_hlcrossbow/fire.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/fly.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hit1.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hit2.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hitbody1.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hitbody2.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/reload.wav");

	// HL 357
	precache_model("models/weapons/wpn_hl357/w_357.mdl");
    precache_model("models/weapons/wpn_hl357/v_357.mdl");
    precache_sound("sounds/weapons/wpn_hl357/cock.wav");
    precache_sound("sounds/weapons/wpn_hl357/reload.wav");
    precache_sound("sounds/weapons/wpn_hl357/fire1.wav");
    precache_sound("sounds/weapons/wpn_hl357/fire2.wav");

	// DOD 98k
    precache_model("models/weapons/wpn_dod98k/w_98k.mdl");
    precache_model("models/weapons/wpn_dod98k/v_98k.mdl");
    precache_sound("sounds/weapons/wpn_dod98k/fire.wav");
    precache_sound("sounds/weapons/wpn_dod98k/boltback.wav");
    precache_sound("sounds/weapons/wpn_dod98k/boltforward.wav");
    precache_sound("sounds/weapons/wpn_dod98k/reload.wav");
    precache_sound("sounds/weapons/wpn_dod98k/stab.wav");

	// CS Scout
    precache_model("models/weapons/wpn_csscout/w_scout.mdl");
    precache_model("models/weapons/wpn_csscout/v_scout.mdl");
    precache_sound("sounds/weapons/wpn_csscout/bolt.wav");
    precache_sound("sounds/weapons/wpn_csscout/clipin.wav");
    precache_sound("sounds/weapons/wpn_csscout/clipout.wav");
    precache_sound("sounds/weapons/wpn_csscout/fire.wav");

	// Grenade Launcher
    precache_model("models/weapons/wpn_grenadelauncher/w_grenlauncher.mdl");
    precache_model("models/weapons/wpn_grenadelauncher/v_grenlauncher.mdl");
    precache_model("models/weapons/wpn_grenadelauncher/grenade.mdl");
    precache_sound("sounds/weapons/wpn_grenadelauncher/fire1.wav");
    precache_sound("sounds/weapons/wpn_grenadelauncher/fire2.wav");
    precache_sound("sounds/weapons/wpn_grenadelauncher/fire3.wav");
    precache_sound("sounds/weapons/wpn_grenadelauncher/reload.wav");

	// CS M249
    precache_model("models/weapons/wpn_csm249/w_m249.mdl");
    precache_model("models/weapons/wpn_csm249/v_m249.mdl");
    precache_sound("sounds/weapons/wpn_csm249/boxin.wav");
    precache_sound("sounds/weapons/wpn_csm249/boxout.wav");
    precache_sound("sounds/weapons/wpn_csm249/chain.wav");
    precache_sound("sounds/weapons/wpn_csm249/coverdown.wav");
    precache_sound("sounds/weapons/wpn_csm249/coverup.wav");
    precache_sound("sounds/weapons/wpn_csm249/fire1.wav");
    precache_sound("sounds/weapons/wpn_csm249/fire2.wav");

	// HL Crowbar
    precache_model("models/weapons/wpn_hlcrowbar/w_crowbar.mdl");
    precache_model("models/weapons/wpn_hlcrowbar/v_crowbar.mdl");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitwall1.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitwall2.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/miss.wav");

	// HL Shotgun
    precache_model("models/weapons/wpn_hlshotgun/w_shotgun.mdl");
    precache_model("models/weapons/wpn_hlshotgun/v_shotgun.mdl");
    precache_sound("sounds/weapons/wpn_hlshotgun/fire1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/fire2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/cock.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload3.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell3.wav");

	// CS M3
    precache_model("models/weapons/wpn_csm3/w_m3.mdl");
    precache_model("models/weapons/wpn_csm3/v_m3.mdl");
    precache_sound("sounds/weapons/wpn_csm3/fire.wav");
    precache_sound("sounds/weapons/wpn_csm3/insertshell.wav");
    precache_sound("sounds/weapons/wpn_csm3/pump.wav");

	// CS MP5
    precache_model("models/weapons/wpn_csmp5/w_mp5.mdl");
    precache_model("models/weapons/wpn_csmp5/v_mp5.mdl");
    precache_sound("sounds/weapons/wpn_csmp5/clipin.wav");
    precache_sound("sounds/weapons/wpn_csmp5/clipout.wav");
    precache_sound("sounds/weapons/wpn_csmp5/slideback.wav");
    precache_sound("sounds/weapons/wpn_csmp5/fire1.wav");
    precache_sound("sounds/weapons/wpn_csmp5/fire2.wav");

	// Rebar
    precache_model("models/weapons/wpn_rebar/w_rebar.mdl");
    precache_model("models/weapons/wpn_rebar/v_rebar.mdl");
    precache_model("models/weapons/wpn_rebar/rebar.mdl");
    precache_sound("sounds/weapons/wpn_rebar/fire.wav");
    precache_sound("sounds/weapons/wpn_rebar/stick.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload1.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload2.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload3.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowreload4.wav");
	precache_sound("sounds/weapons/wpn_rebar/bowclank.wav");

	// CS AWP
	precache_model("models/weapons/wpn_csawp/w_awp.mdl");
    precache_model("models/weapons/wpn_csawp/v_awp.mdl");
    precache_sound("sounds/weapons/wpn_csawp/clipin.wav");
    precache_sound("sounds/weapons/wpn_csawp/clipout.wav");
    precache_sound("sounds/weapons/wpn_csawp/deploy.wav");
    precache_sound("sounds/weapons/wpn_csawp/fire.wav");
    precache_sound("sounds/weapons/wpn_csawp/zoom.wav");
    precache_sound("sounds/weapons/wpn_csawp/boltup.wav");
    precache_sound("sounds/weapons/wpn_csawp/boltdown.wav");
    precache_sound("sounds/weapons/wpn_csawp/boltpull.wav");

	// Wrench
	precache_model("models/weapons/wpn_wrench/v_wrench.mdl");
	precache_model("models/weapons/wpn_wrench/g_wrench.mdl");
    precache_sound("sounds/weapons/wpn_wrench/wrenchswing.wav");
    precache_sound("sounds/weapons/wpn_wrench/wrenchclank1.wav");
    precache_sound("sounds/weapons/wpn_wrench/wrenchclank2.wav");

	// CS Deagle
	precache_model("models/weapons/wpn_csdeagle/v_deagle.mdl");
	precache_model("models/weapons/wpn_csdeagle/w_deagle.mdl");
	precache_sound("sounds/weapons/wpn_csdeagle/deploy.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/fire1.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/fire2.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/clipin.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/clipout.wav");

	// CS Knife
	precache_model("models/weapons/wpn_csknife/v_knife.mdl");
	precache_model("models/weapons/wpn_csknife/w_knife.mdl");
	precache_sound("sounds/weapons/wpn_csknife/deploy.wav");
	precache_sound("sounds/weapons/wpn_csknife/hit1.wav");
	precache_sound("sounds/weapons/wpn_csknife/hit2.wav");
	precache_sound("sounds/weapons/wpn_csknife/hitwall.wav");
	precache_sound("sounds/weapons/wpn_csknife/slash.wav");
	precache_sound("sounds/weapons/wpn_csknife/stab.wav");

	// Butterfly Knife (Balisong) — model folder spelled "wpn_butteryfly",
	// sound folder spelled "wpn_butterfly" (intentional, matches assets).
	precache_model("models/weapons/wpn_butteryfly/v_knife.mdl");
	precache_model("models/weapons/wpn_butteryfly/w_knife.mdl");
	precache_sound("sounds/weapons/wpn_butterfly/select.wav");
	precache_sound("sounds/weapons/wpn_butterfly/attack1.wav");
	precache_sound("sounds/weapons/wpn_butterfly/attack2.wav");
	precache_sound("sounds/weapons/wpn_butterfly/combo1.wav");
	precache_sound("sounds/weapons/wpn_butterfly/combo2.wav");
	precache_sound("sounds/weapons/wpn_butterfly/bigshot.wav");
	precache_sound("sounds/weapons/wpn_butterfly/bigshot_r.wav");
	precache_sound("sounds/weapons/wpn_butterfly/bigshot_spin.wav");
	precache_sound("sounds/weapons/wpn_butterfly/bigshot_r_spin.wav");
	precache_sound("sounds/weapons/wpn_butterfly/observe.wav");
	precache_sound("sounds/weapons/wpn_butterfly/observe2.wav");
	precache_sound("sounds/weapons/wpn_butterfly/hit1.wav");
	precache_sound("sounds/weapons/wpn_butterfly/hit2.wav");
	precache_sound("sounds/weapons/wpn_butterfly/hit3.wav");
	precache_sound("sounds/weapons/wpn_butterfly/hit4.wav");
	precache_sound("sounds/weapons/wpn_butterfly/hitwall1.wav");

	// Fists (wpn_melee) — view-model only, no p_/w_ models.
	// Sound set: miss1 / punchhit1 / kickhit1 / block1.
	precache_model("models/weapons/wpn_melee/v_melee.mdl");
	precache_sound("sounds/weapons/wpn_melee/miss1.wav");
	precache_sound("sounds/weapons/wpn_melee/punchhit1.wav");
	precache_sound("sounds/weapons/wpn_melee/kickhit1.wav");
	precache_sound("sounds/weapons/wpn_melee/block1.wav");

	// Katana — full p/w/v model set, droppable melee.
	precache_model("models/weapons/wpn_katana/v_katana.mdl");
	precache_model("models/weapons/wpn_katana/w_katana.mdl");
	precache_model("models/weapons/wpn_katana/p_katana.mdl");
	precache_sound("sounds/weapons/wpn_katana/hitbody1.wav");
	precache_sound("sounds/weapons/wpn_katana/hitwall1.wav");
	precache_sound("sounds/weapons/wpn_katana/hitwall2.wav");
	precache_sound("sounds/weapons/wpn_katana/miss1.wav");
	precache_sound("sounds/weapons/wpn_katana/miss2.wav");

	// CF AUG
	precache_model("models/weapons/wpn_cfaug/v_aug.mdl");
	precache_model("models/weapons/wpn_cfaug/w_aug.mdl");
	precache_sound("sounds/weapons/wpn_cfaug/fire1.wav");
	precache_sound("sounds/weapons/wpn_cfaug/reload.wav");
	precache_sound("sounds/weapons/wpn_cfaug/clipin.wav");
	precache_sound("sounds/weapons/wpn_cfaug/clipout.wav");
	precache_sound("sounds/weapons/wpn_cfaug/bcy.wav");
	precache_sound("sounds/weapons/wpn_cfaug/cy.wav");

	// CF FAMAS
	precache_model("models/weapons/wpn_cffamas/v_famas.mdl");
	precache_model("models/weapons/wpn_cffamas/w_famas.mdl");
	precache_sound("sounds/weapons/wpn_cffamas/fire1.wav");
	precache_sound("sounds/weapons/wpn_cffamas/fire2.wav");
	precache_sound("sounds/weapons/wpn_cffamas/reload.wav");
	precache_sound("sounds/weapons/wpn_cffamas/clipin.wav");
	precache_sound("sounds/weapons/wpn_cffamas/clipout.wav");
	precache_sound("sounds/weapons/wpn_cffamas/blockback.wav");

	// CF MAC10
	precache_model("models/weapons/wpn_cfmac10/v_mac10.mdl");
	precache_model("models/weapons/wpn_cfmac10/w_mac10.mdl");
	precache_sound("sounds/weapons/wpn_cfmac10/fire.wav");
	precache_sound("sounds/weapons/wpn_cfmac10/draw.wav");
	precache_sound("sounds/weapons/wpn_cfmac10/reload.wav");
	precache_sound("sounds/weapons/wpn_cfmac10/clipin.wav");
	precache_sound("sounds/weapons/wpn_cfmac10/clipout.wav");

	// CF Beretta M9 (cfm9 QC) — models + sounds both under wpn_cfm9.
	precache_model("models/weapons/wpn_cfm9/v_m9.mdl");
	precache_model("models/weapons/wpn_cfm9/w_m9.mdl");
	precache_model("models/weapons/wpn_cfm9/p_m9.mdl");
	precache_sound("sounds/weapons/wpn_cfm9/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfm9/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfm9/bback.WAV");
	precache_sound("sounds/weapons/wpn_cfm9/bcback.WAV");
	precache_sound("sounds/weapons/wpn_cfm9/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfm9/clipout.WAV");

	// CF Colt Anaconda (cfrevolver)
	precache_model("models/weapons/wpn_cfrevolver/v_revolver.mdl");
	precache_model("models/weapons/wpn_cfrevolver/w_revolver.mdl");
	precache_model("models/weapons/wpn_cfrevolver/p_revolver.mdl");
	precache_sound("sounds/weapons/wpn_cfrevolver/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfrevolver/reload1.WAV");
	precache_sound("sounds/weapons/wpn_cfrevolver/reload2.WAV");
	precache_sound("sounds/weapons/wpn_cfrevolver/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfrevolver/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfrevolver/bcback.WAV");

	// CF Barrett M82 (cfbarrett)
	precache_model("models/weapons/wpn_cfbarrett/v_barrett.mdl");
	precache_model("models/weapons/wpn_cfbarrett/w_barrett.mdl");
	precache_model("models/weapons/wpn_cfbarrett/p_barrett.mdl");
	precache_sound("sounds/weapons/wpn_cfbarrett/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfbarrett/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfbarrett/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfbarrett/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfbarrett/draw.WAV");

	// CF PSG1 (cfpsg1)
	precache_model("models/weapons/wpn_cfpsg1/v_psg1.mdl");
	precache_model("models/weapons/wpn_cfpsg1/w_psg1.mdl");
	precache_model("models/weapons/wpn_cfpsg1/p_psg1.mdl");
	precache_sound("sounds/weapons/wpn_cfpsg1/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfpsg1/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfpsg1/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfpsg1/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfpsg1/cy.WAV");
	precache_sound("sounds/weapons/wpn_cfpsg1/bcy.WAV");

	// CF Dual Desert Deagle (cfddeagle)
	precache_model("models/weapons/wpn_cfddeagle/v_ddeagle.mdl");
	precache_model("models/weapons/wpn_cfddeagle/w_ddeagle.mdl");
	precache_model("models/weapons/wpn_cfddeagle/p_ddeagle.mdl");
	precache_sound("sounds/weapons/wpn_cfddeagle/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfddeagle/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfddeagle/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfddeagle/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfddeagle/select.WAV");

	// CF SPAS-12 (cfspas12) — sounds available: clipin/clipout/draw/fire/reload (all .WAV).
	// In the QC: bulletin event → clipin.WAV (shell insert), bback event → clipout.WAV (pump back).
	precache_model("models/weapons/wpn_cfspas12/v_spas12.mdl");
	precache_model("models/weapons/wpn_cfspas12/w_spas12.mdl");
	precache_model("models/weapons/wpn_cfspas12/p_spas12.mdl");
	precache_sound("sounds/weapons/wpn_cfspas12/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfspas12/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfspas12/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfspas12/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfspas12/draw.WAV");

	// CF Remington M700 (cfm700 QC) — assets under wpn_cfm700 (v_m700 etc.).
	precache_model("models/weapons/wpn_cfm700/v_m700.mdl");
	precache_model("models/weapons/wpn_cfm700/w_m700.mdl");
	precache_model("models/weapons/wpn_cfm700/p_m700.mdl");
	precache_sound("sounds/weapons/wpn_cfm700/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfm700/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfm700/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfm700/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfm700/draw.WAV");

	// CF Winchester (cfm3) — disk has v_m3/w_m3/p_m3 (NOT v_winchester)
	// and bulletin.WAV/draw.WAV (no clipin/clipout for this gun).
	precache_model("models/weapons/wpn_cfm3/v_m3.mdl");
	precache_model("models/weapons/wpn_cfm3/w_m3.mdl");
	precache_model("models/weapons/wpn_cfm3/p_m3.mdl");
	precache_sound("sounds/weapons/wpn_cfm3/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfm3/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfm3/bulletin.WAV");
	precache_sound("sounds/weapons/wpn_cfm3/draw.WAV");

	// CF FN SCAR (cfscar QC) — assets under wpn_cfscar (v_scar etc.).
	// No bback.wav on disk — draw clack uses reload.WAV instead.
	precache_model("models/weapons/wpn_cfscar/v_scar.mdl");
	precache_model("models/weapons/wpn_cfscar/w_scar.mdl");
	precache_model("models/weapons/wpn_cfscar/p_scar.mdl");
	precache_sound("sounds/weapons/wpn_cfscar/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfscar/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfscar/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfscar/clipout.WAV");

	// CF C96 Mauser (cfmauser QC) — assets under wpn_cfmauser (v_mauser etc.).
	// draw.WAV used for deploy; no reload.WAV on disk for this weapon.
	precache_model("models/weapons/wpn_cfmauser/v_mauser.mdl");
	precache_model("models/weapons/wpn_cfmauser/w_mauser.mdl");
	precache_model("models/weapons/wpn_cfmauser/p_mauser.mdl");
	precache_sound("sounds/weapons/wpn_cfmauser/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfmauser/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfmauser/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfmauser/draw.WAV");

	// CF SVD Dragunov (cfsvd QC) — assets under wpn_cfsvd (v_svd etc.).
	precache_model("models/weapons/wpn_cfsvd/v_svd.mdl");
	precache_model("models/weapons/wpn_cfsvd/w_svd.mdl");
	precache_model("models/weapons/wpn_cfsvd/p_svd.mdl");
	precache_sound("sounds/weapons/wpn_cfsvd/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfsvd/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfsvd/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfsvd/clipout.WAV");

	// CF MP5 (cfmp5) — sounds clipin/clipout/fire/reload (.WAV); NO draw,
	// deploy reuses reload.WAV.  Bone-attached muzzle (Bone01).
	precache_model("models/weapons/wpn_cfmp5/v_mp5.mdl");
	precache_model("models/weapons/wpn_cfmp5/w_mp5.mdl");
	precache_model("models/weapons/wpn_cfmp5/p_mp5.mdl");
	precache_sound("sounds/weapons/wpn_cfmp5/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfmp5/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfmp5/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfmp5/clipout.WAV");

	// CF Vector (cfvector) — sounds clipin/clipout/draw/fire/reload (.WAV).
	precache_model("models/weapons/wpn_cfvector/v_vector.mdl");
	precache_model("models/weapons/wpn_cfvector/w_vector.mdl");
	precache_model("models/weapons/wpn_cfvector/p_vector.mdl");
	precache_sound("sounds/weapons/wpn_cfvector/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfvector/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfvector/draw.WAV");
	precache_sound("sounds/weapons/wpn_cfvector/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfvector/clipout.WAV");

	// CF Type 89 (cftype89) — sounds clipin/clipout/draw/fire/reload (.WAV).
	precache_model("models/weapons/wpn_cftype89/v_type89.mdl");
	precache_model("models/weapons/wpn_cftype89/w_type89.mdl");
	precache_model("models/weapons/wpn_cftype89/p_type89.mdl");
	precache_sound("sounds/weapons/wpn_cftype89/fire.WAV");
	precache_sound("sounds/weapons/wpn_cftype89/reload.WAV");
	precache_sound("sounds/weapons/wpn_cftype89/draw.WAV");
	precache_sound("sounds/weapons/wpn_cftype89/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cftype89/clipout.WAV");

	// CF UMP45 (cfump45) — sounds clipin/clipout/draw/fire/reload (.WAV).
	precache_model("models/weapons/wpn_cfump45/v_ump45.mdl");
	precache_model("models/weapons/wpn_cfump45/w_ump45.mdl");
	precache_model("models/weapons/wpn_cfump45/p_ump45.mdl");
	precache_sound("sounds/weapons/wpn_cfump45/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfump45/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfump45/draw.WAV");
	precache_sound("sounds/weapons/wpn_cfump45/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfump45/clipout.WAV");

	// CF M249 (cfm249) — sounds clipin/clipout/draw/fire/reload (.WAV).
	precache_model("models/weapons/wpn_cfm249/v_m249.mdl");
	precache_model("models/weapons/wpn_cfm249/w_m249.mdl");
	precache_model("models/weapons/wpn_cfm249/p_m249.mdl");
	precache_sound("sounds/weapons/wpn_cfm249/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfm249/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfm249/draw.WAV");
	precache_sound("sounds/weapons/wpn_cfm249/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfm249/clipout.WAV");

	// CF AWM (cfawm) — sounds clipin/clipout/fire/reload (.WAV); NO draw,
	// deploy + bolt cycle reuse reload.WAV.  Bolt-action sniper.
	precache_model("models/weapons/wpn_cfawm/v_awm.mdl");
	precache_model("models/weapons/wpn_cfawm/w_awm.mdl");
	precache_model("models/weapons/wpn_cfawm/p_awm.mdl");
	precache_sound("sounds/weapons/wpn_cfawm/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfawm/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfawm/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfawm/clipout.WAV");

	// CF KS-23 (cfks23) — pump shotgun, shell-by-shell (clipin = shell insert,
	// reload = pump, blowback = post-fire blow).  Has draw.WAV.
	precache_model("models/weapons/wpn_cfks23/v_ks23.mdl");
	precache_model("models/weapons/wpn_cfks23/w_ks23.mdl");
	precache_model("models/weapons/wpn_cfks23/p_ks23.mdl");
	precache_sound("sounds/weapons/wpn_cfks23/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfks23/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfks23/draw.WAV");
	precache_sound("sounds/weapons/wpn_cfks23/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfks23/blowback.WAV");

	// CF M4 Super 90 (cfm4) — auto shotgun, shell-by-shell (shellin = shell insert,
	// reload = pump + deploy).  NO draw.WAV; deploy reuses reload.WAV.
	precache_model("models/weapons/wpn_cfm4/v_m4.mdl");
	precache_model("models/weapons/wpn_cfm4/w_m4.mdl");
	precache_model("models/weapons/wpn_cfm4/p_m4.mdl");
	precache_sound("sounds/weapons/wpn_cfm4/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfm4/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfm4/shellin.WAV");

	// CF MK23 SOCOM (cfmk23) — semi-auto .45 pistol, silencer toggle (+attack2).
	// draw = deploy + toggle click; 4-event reload.
	precache_model("models/weapons/wpn_cfmk23/v_mk23.mdl");
	precache_model("models/weapons/wpn_cfmk23/w_mk23.mdl");
	precache_model("models/weapons/wpn_cfmk23/p_mk23.mdl");
	precache_sound("sounds/weapons/wpn_cfmk23/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfmk23/fire-silenced.WAV");
	precache_sound("sounds/weapons/wpn_cfmk23/draw.WAV");
	precache_sound("sounds/weapons/wpn_cfmk23/blowback.WAV");
	precache_sound("sounds/weapons/wpn_cfmk23/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfmk23/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfmk23/delblowback.WAV");

	// CS USP-45 (csusp) — semi-auto .45 pistol, silencer toggle (+attack2).
	// Camera-local muzzle; lowercase .wav assets.  sfire = silenced fire,
	// silenceron/off = toggle, slideback/sliderelease = slide rack.
	precache_model("models/weapons/wpn_csusp/v_usp.mdl");
	precache_model("models/weapons/wpn_csusp/w_usp.mdl");
	precache_model("models/weapons/wpn_csusp/p_usp.mdl");
	precache_sound("sounds/weapons/wpn_csusp/fire.wav");
	precache_sound("sounds/weapons/wpn_csusp/sfire.wav");
	precache_sound("sounds/weapons/wpn_csusp/clipin.wav");
	precache_sound("sounds/weapons/wpn_csusp/clipout.wav");
	precache_sound("sounds/weapons/wpn_csusp/silenceron.wav");
	precache_sound("sounds/weapons/wpn_csusp/silenceroff.wav");
	precache_sound("sounds/weapons/wpn_csusp/slideback.wav");
	precache_sound("sounds/weapons/wpn_csusp/sliderelease.wav");

	// CF Galil (cfgalil) — full-auto rifle.  Bone-attached muzzle (Bone01).
	precache_model("models/weapons/wpn_cfgalil/v_galil.mdl");
	precache_model("models/weapons/wpn_cfgalil/w_galil.mdl");
	precache_model("models/weapons/wpn_cfgalil/p_galil.mdl");
	precache_sound("sounds/weapons/wpn_cfgalil/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfgalil/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfgalil/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfgalil/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfgalil/draw.WAV");

	// CF Glock 18 (cfglock) — full-auto pistol.
	precache_model("models/weapons/wpn_cfglock/v_glock18.mdl");
	precache_model("models/weapons/wpn_cfglock/w_glock18.mdl");
	precache_model("models/weapons/wpn_cfglock/p_glock18.mdl");
	precache_sound("sounds/weapons/wpn_cfglock/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfglock/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfglock/bback.WAV");
	precache_sound("sounds/weapons/wpn_cfglock/bcback.WAV");
	precache_sound("sounds/weapons/wpn_cfglock/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfglock/clipout.WAV");

	// CF Scout Elite (cfelite) — semi-auto scout sniper (CoD-scope).  Uses v_scout models.
	precache_model("models/weapons/wpn_cfelite/v_scout.mdl");
	precache_model("models/weapons/wpn_cfelite/w_scout.mdl");
	precache_model("models/weapons/wpn_cfelite/p_scout.mdl");
	precache_sound("sounds/weapons/wpn_cfelite/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfelite/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfelite/blowback.WAV");
	precache_sound("sounds/weapons/wpn_cfelite/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfelite/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfelite/draw.WAV");

	// CF P228 (cfp228) — semi-auto pistol.
	precache_model("models/weapons/wpn_cfp228/v_p228.mdl");
	precache_model("models/weapons/wpn_cfp228/w_p228.mdl");
	precache_model("models/weapons/wpn_cfp228/p_p228.mdl");
	precache_sound("sounds/weapons/wpn_cfp228/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfp228/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfp228/bback.WAV");
	precache_sound("sounds/weapons/wpn_cfp228/bcback.WAV");
	precache_sound("sounds/weapons/wpn_cfp228/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfp228/clipout.WAV");

	// CF MSG90 (cfmsg90) — semi-auto sniper (CoD-scope).
	precache_model("models/weapons/wpn_cfmsg90/v_msg90.mdl");
	precache_model("models/weapons/wpn_cfmsg90/w_msg90.mdl");
	precache_model("models/weapons/wpn_cfmsg90/p_msg90.mdl");
	precache_sound("sounds/weapons/wpn_cfmsg90/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfmsg90/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfmsg90/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfmsg90/clipout.WAV");
	precache_sound("sounds/weapons/wpn_cfmsg90/draw.WAV");

	// CF SG552 (cfsg552) — full-auto scoped assault rifle.  Deploy reuses reload.WAV.
	precache_model("models/weapons/wpn_cfsg552/v_sg552.mdl");
	precache_model("models/weapons/wpn_cfsg552/w_sg552.mdl");
	precache_model("models/weapons/wpn_cfsg552/p_sg552.mdl");
	precache_sound("sounds/weapons/wpn_cfsg552/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfsg552/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfsg552/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfsg552/clipout.WAV");

	// CF SL8 (cfsl8) — semi-auto marksman rifle.  Deploy reuses reload.WAV.
	precache_model("models/weapons/wpn_cfsl8/v_sl8.mdl");
	precache_model("models/weapons/wpn_cfsl8/w_sl8.mdl");
	precache_model("models/weapons/wpn_cfsl8/p_sl8.mdl");
	precache_sound("sounds/weapons/wpn_cfsl8/fire.WAV");
	precache_sound("sounds/weapons/wpn_cfsl8/reload.WAV");
	precache_sound("sounds/weapons/wpn_cfsl8/clipin.WAV");
	precache_sound("sounds/weapons/wpn_cfsl8/clipout.WAV");

	// Gravity Gun — viewmodel + world model only (no p-model, no sounds yet).
	precache_model("models/weapons/wpn_gravitygun/v_gravitygun.mdl");
	precache_model("models/weapons/wpn_gravitygun/w_gravitygun.mdl");

	// CF C4
	precache_model("models/weapons/wpn_cfc4/v_c4.mdl");
	precache_model("models/weapons/wpn_cfc4/w_c4.mdl");
	precache_sound("sounds/weapons/wpn_cfc4/pullout.wav");
	precache_sound("sounds/weapons/wpn_cfc4/plant.wav");
	precache_sound("sounds/weapons/wpn_cfc4/beep.wav");
	precache_sound("sounds/weapons/wpn_cfc4/disarm.wav");
	precache_sound("sounds/weapons/wpn_cfc4/explode.wav");

	// CS AK47
	precache_model("models/weapons/wpn_csak47/v_ak47.mdl");
	precache_model("models/weapons/wpn_csak47/w_ak47.mdl");
	precache_sound("sounds/weapons/wpn_csak47/fire1.wav");
	precache_sound("sounds/weapons/wpn_csak47/fire2.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipin.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipout.wav");
	precache_sound("sounds/weapons/wpn_csak47/boltpull.wav");
	// HD AK47 — shares wpn_csak47 sounds, only new model files.
	precache_model("models/weapons/wpn_hdak47/v_ak47.mdl");
	precache_model("models/weapons/wpn_hdak47/w_ak47.mdl");

	// CS M4a1
	precache_model("models/weapons/wpn_csm4a1/v_m4a1.mdl");
	precache_model("models/weapons/wpn_csm4a1/v_m4a1_unsil.mdl");
	precache_model("models/weapons/wpn_csm4a1/w_m4a1.mdl");
	precache_sound("sounds/weapons/wpn_csm4a1/fire1.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/fire2.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/sfire1.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/clipin.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/clipout.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/deploy.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/boltpull.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/silenceroff.wav");
	precache_sound("sounds/weapons/wpn_csm4a1/silenceron.wav");

	// FlakShotgun
	precache_model("models/weapons/wpn_flakshotgun/v_flakshotgun.mdl");
	precache_model("models/weapons/wpn_flakshotgun/w_flakshotgun.mdl");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire1.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire2.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire3.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/fire4.wav");
	precache_sound("sounds/weapons/wpn_flakshotgun/reload.wav");

	// Pistol
	precache_model("models/weapons/wpn_pistol/v_pistol.mdl");
	precache_model("models/weapons/wpn_pistol/w_pistol.mdl");
	precache_sound("sounds/weapons/wpn_pistol/deadlockreload.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire1.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire2.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire3.wav");
	precache_sound("sounds/weapons/wpn_pistol/fire4.wav");
	precache_sound("sounds/weapons/wpn_pistol/reload.wav");
	precache_sound("sounds/weapons/wpn_pistol/magdrop.wav");
};


float sv_cached_pose_keepalive_interval;  // re-added after CSUSP-removal pass
