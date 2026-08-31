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

// Half-Life bodygroup selector.  A real entvar as of Patch 131 — the engine
// registers it (server/progdefs.h:368), ships it under PEXT2_BODYGROUP
// (sv_ents.c:3660 -> cl_ents.c:5406) and gl_hlmdl.c:1889 divides it back out per
// bodypart.  sv_cycler.qc has declared it since the cycler landed, but that file
// compiles long after the weapons; declaring it here (line 3 of BOTH .src files)
// is what lets a weapon use it.  The duplicate is harmless — QC accepts repeated
// .float declarations of matching type, as the note in sv_cycler.qc says.
//
// Needed by the tripmine, which draws v_tripmine.mdl at body 3 to hide the
// viewmodel's hands, exactly as tripmine.cpp:104 does.
.float body;

// Gravity Shift (gravity gun): 1 while this player's gravity is redirected.
// Declared here (earliest shared include) so both sh_pmove.qc and the gravgun
// weapon file can see it.  See GravShift_UpdateActivation in sh_pmove.qc.
.float gravshift_active;
// Half-Life's long jump module.  SHARED, not server-only, because the jump it
// modifies is computed in shared/sh_pmove.qc and therefore has to be PREDICTED —
// an unpredicted 560 u/s launch rubber-bands on every jump.  This is exactly
// HL's "slj" physinfo key (dlls/player.cpp:3195-3202), which exists for the same
// reason: it is the one bit pm_shared needs and cannot derive for itself.
.float pm_longjump;
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
const float PM_CSQC_PROXY_VERSION = 29;  // v29 carries TWO additions.  (a) ammo section adds ammo_dodbinocs, written immediately after ammo_dodstick and diffed as pm_ammo_mb2 bit 16 (so both baseline re-arms are now 31, not 15).  The SIXTH weapon caught by the utility-ammo hole and the first caught by a DIFFERENT route: the binoculars have no rounds, so ownership was written as `slot_utility == WEP_DODBINOCS` on the reasoning that there was no count to ship — and that test is CIRCULAR, because slot_utility is the selection cursor and W_UtilityRefreshSlotBinding rebuilds the cursor by asking exactly this question of every weapon in the ring.  The first refresh after they were given moved the cursor and disowned them for good: "binoculars despawn immediately and I can't switch to them?  zero ammo?".  They now carry 1 while held, with all four edits (byte, mask bit, both baseline re-arms, sv_confirmed_* store and unconditional reconcile).  Safe to grant in sv_default_utility where the medkit and SOFLAM are not, because the binoculars have no world pickup for the duplicate-utility reject to block.  (b) weapon-state section adds TWO bytes immediately after satchel_state: wep_deployed then famas_burst_mode.  famas_burst_mode is the FAMAS fire selector (0 auto, 1 three-round burst): +attack2 used to FIRE a burst while +attack stayed automatic, which is two triggers on a gun that has one trigger and a selector switch.  It now moves the switch and +attack fires whichever mode is set, so the byte decides which of two very different things the trigger does — the same argument satchel_state's byte is here for.  wep_deployed:  FIVE Day of Defeat weapons are now EMPLACED — the mortar, the MG34, the MG42, the .30 cal and the BAR.  +attack2 plants each one (up_to_down / uptodown), which LOCKS MOVEMENT to zero via the shared SH_DeploySpeedFactor in sh_weapons.qc, and the reward is a much tighter cone (or, for the mortar, the ability to load and fire at all).  ONE flag and ONE byte for all five, armed per weapon by .weapon_deployable exactly as .weapon_ads_eligible arms the ADS profile.  Beside satchel_state because it is the same kind of value: a per-weapon mode both sides predict off a button, where a drifted copy predicts the wrong one of two very different actions.  Reconciled UNCONDITIONALLY, outside trust_server_ammo and beside ammo_cfc4, for a stronger reason than that group's: a stance has no predicted decrement to erase, and one that could latch would strand the player unable to move with no way to lift it.  v28: ammo section adds ammo_dodmills and ammo_dodstick, written immediately after ammo_penguin and diffed as pm_ammo_mb2 bits 4 and 8.  The two Day of Defeat grenades — Mills bomb and stick grenade — and the FIRST SLOT_UTILITY weapons in this tree to arrive with the whole thing in one change: byte, mask bit, proxy copy, BOTH baseline re-arms (which is why pm_ammo_mb2 is now 15, not 3), sv_confirmed_* store and unconditional reconcile.  Read the v22/v23/v27 notes below before adding a sixth: every one of those shipped with some subset of that list and the symptom was identical each time — HUD stuck on 0 while the SHARED try-fire gate had the client refuse a throw the server would have allowed.  v27: ammo section adds ammo_penguin, written immediately after ammo_soflam and diffed as pm_ammo_mb2 bit 2.  The fourth weapon caught by the SAME hole as v22's tripmine/snark and v23's medkit/soflam: W_SlotAmmo_UsesSlot is FALSE for SLOT_UTILITY, so the slot bridge skips them and this section is their only channel.  Shipped after v23 and so never got the treatment — no byte, no mask bit, no proxy copy.  AND the v23 pair were only HALF fixed: their bytes were written and read, but never copied into an sv_confirmed_* global, and predicted_player is a separate entity from the parsed proxy — so the medkit and SOFLAM counts still never reached the entity the HUD and the SHARED try-fire gates read, and both sat at 0 for the whole map while the server fired anyway.  All three are now stored and reconciled UNCONDITIONALLY (beside ammo_cfc4), because none of the three has a client-side decrement to protect.  v26: movement section adds the four item_inventory holder-effect bytes (pm_inv_speed_pct, pm_inv_gravity_pct, pm_inv_friction_pct, pm_inv_blockfire), written immediately after pm_longjump and BEFORE the conditional car block — the same fixed-before-conditional rule v24 spells out.  Sven's item_inventory can halve the holder's speed (th_escape's car battery does exactly that) and block their weapons; PM_LoadMovevars and Weapon_LowerBlocksFire read all four on both sides, so an unreplicated value rubber-bands every step while carrying and mispredicts every trigger-pull.  Percent-encoded in one byte each (100 = unchanged, and 0 is ALSO treated as unchanged so a player who has never held an item costs nothing); pm_inv_blockfire is a plain 0/1 beside pm_carrying, which it ORs into.  v25: weapon-state section adds the two 4-byte carry lists (carry_primary, carry_secondary) that back mp_maxprimary / mp_maxsecondary.  Fixed 8 bytes, packed and 0-terminated, written immediately after the four slot bytes and BEFORE self.weapon - length-prefixing was rejected because a variable-length run inside a fixed section is exactly the hazard the v24 note describes.  The four slot bytes keep their names but change meaning: they are now the SELECTED weapon per slot (a cursor), not the only one held.  NO ammo bytes were added and the pm_ammo_mb* mask is untouched - a carried but holstered weapon keeps its magazine in its own legacy .mag_x/.ammo_x fields, so the canonical slot_primary_mag/_ammo/_aux registers still belong to whatever the cursor names.  v24: movement section adds pm_longjump, one byte written immediately after ph_yaw_locked and BEFORE the conditional car block.  Half-Life's long jump module: PM_CheckJump needs it on both sides or the 560 u/s launch is server-only and rubber-bands every jump.  Wire order is the load-bearing part — a fixed-size byte must never sit after a conditional section.  v23: ammo section adds ammo_medkit and ammo_soflam, the last two SLOT_UTILITY counts that were never networked.  Identical failure to v22's tripmine/snark, and they were missed because they ARE copied onto the proxy entity (a server-side field write that SendEntity never serialises) and so the plumbing read as complete.  Symptom: HUD stuck on 0 while the SHARED try-fire gate had the client refuse and the server, holding the real count, fire anyway.  v22: ammo section adds ammo_tripmine and ammo_snark.  They were the only SLOT_UTILITY counts never networked at all — W_SlotAmmo_UsesSlot is FALSE for utility weapons so the slot bridge correctly skips them, and this section was their only possible channel.  The client's copy therefore sat at 0 forever, so SH_TripmineTryPlace / SH_SnarkTryThrow failed their own ammo gate, never entered WS_FIRE, and never played a placement/throw animation; the HUD printed 0 and W_UtilityPlayerHasWeapon denied the weapon client-side while the server still had it in your hands.  The note below about deployables "self-correcting" on auto-switch was wrong: a count that starts at 0 and is never raised has nothing to correct from.  v21: weapon-state section adds satchel_state and the ammo section adds ammo_satchel — the satchel's +attack now picks throw-vs-detonate off those two, so a client predicting stale values predicts the wrong action outright.  v20: movement section adds pm_jump_groundstick_off_until (remaining-secs) right after pm_jump_lag_end, so the post-jump ground-snap suppress window survives reconcile at high ping (codstamina/grapple low jumps).  bump on wire-layout change.  MUST NOT collide with any CSQC_ENT_* id below (CSQC_Ent_Update dispatches by equality before falling through to the pm_proxy parse — v13 collided with CSQC_ENT_CAMERA and silently routed proxy updates into the camera parser).  v14: ammo bitmask + movement byte/short re-encoding.  v15: origin/velocity now WriteFloat (full 32-bit) instead of WriteCoord (1/8 qu) — eliminates snapshot-rounding as a source of reconcile drift.  v16: weapon-state section now also carries pm_weapon_blend_progress + pm_weapon_prev_factor so the speed-factor blend is input-tick-driven instead of wall-clock-driven.  v17: utility proxy includes CS HE/flash/smoke ammo.  v18: primary/secondary ammo is slot-based.  v19: weapon-state section adds 4 floats + 1 byte for the sv_gunkick view-kick state (pitch/yaw offsets + spring velocities + per-burst shot index).
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
const float CSQC_ENT_TRIGGER_CAMERA = 42; // Sven Co-op trigger_camera cutscene pose.  Sent with
                                          // pvsflags = PVSF_IGNOREPVS because a cutscene camera is
                                          // routinely nowhere near the player it is filming for.
                                          // Distinct from CSQC_ENT_CAMERA (13), which is this mod's
                                          // own team-select preview camera with unrelated spawnflags.
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

// ---------------------------------------------------------------------------
//  trigger_push flags — TWO SEPARATE VOCABULARIES
//
//  The bits a MAP sets are Sven's (sven-coop.fgd:6553-6560).  The bits this
//  code tests are the mod's own, and they are NOT the same allocation.  They
//  used to be read as if they were, which is a real and widespread bug:
//  measured across the Sven + They Hunger + local corpus, 436 of 745
//  trigger_push entities (59%) set a bit beyond 1|2 and were being misread.
//
//  The worst case is in the very map this was reported from — th_ep1_03's
//  `toenail_push` carries spawnflags 6, which is Sven's "Start Off" plus a
//  stray undefined bit 4.  Read as PUSH_ADDITIVE, that applied an uncapped
//  +1800 qu/s on EVERY pmove tick for the ~2 s the multi_manager held it open.
//  Nothing catches it: players are MOVETYPE_NONE (sv_player.qc) so FTE's
//  engine-side sv_maxvelocity clamp never runs on them.
//
//  `trigger_push` (sv_push.qc) now TRANSLATES map bits into mod bits at spawn,
//  so nothing downstream ever sees a raw map bit.
// ---------------------------------------------------------------------------

// What a MAP writes.  Bits 4 and 32 are undefined in Sven and in GoldSrc, which
// is exactly how 66 entities came to have bit 4 set without meaning anything.
const float PUSHMAP_ONCE       = 1;
const float PUSHMAP_START_OFF  = 2;
const float PUSHMAP_NOCLIENTS  = 8;   // "No Clients"
const float PUSHMAP_NOMONSTERS = 16;  // "No Monsters"
const float PUSHMAP_FORCE      = 64;  // "Force push (deprecated, see pushmode)"

// What THIS code tests, after translation.  1 and 2 mean the same in both
// vocabularies and pass straight through; every other bit is derived.
const float PUSH_ONCE     = 1;  // remove after first touch
// PUSH_START_OFF moved to bit 2 to match HL spec — many community maps
// set bit 2 expecting "Start Off" semantics, and silently routing that
// to "silent" left the triggers always-active with no use handler
// (buttons targeting them did nothing).  PUSH_SILENT moved to bit 64.
const float PUSH_START_OFF = 2;
const float PUSH_SILENT   = 64; // no wind sound (moved from bit 2)
const float PUSH_ADDITIVE = 4;  // add to velocity rather than replace
const float PUSH_TUNNEL   = 8;  // pull toward trigger centerline while pushing
// Uncapped per-tick add along movedir — NOT the "up to speed" clamp the name
// implies.  That clamp was deliberately removed (see PM_ApplyTriggerPush);
// PUSH_FLOOR is the flag that actually floors velocity.
const float PUSH_SOURCE   = 16;
// Sven's `pushmode` key (sven-coop.fgd:6562-6567), which nothing parsed until
// now.  pushmode 1, "Forced (minimum velocity)", IS the velocity floor that
// used to be applied unconditionally to every vertical push — it is opt-in in
// Sven, and it is opt-in here now.  pushmode 2 is "Forced (exact velocity)".
const float PUSH_FLOOR     = 32;
const float PUSH_NOCLIENTS = 128;   // from PUSHMAP_NOCLIENTS
const float PUSH_EXACT     = 256;
// From PUSHMAP_NOMONSTERS.  Used to be discarded on the (then true) grounds that
// only players were ever pushed; trigger_push_touch pushes NPCs now, so the map's
// "No Monsters" bit has to survive the translation or it silently stops meaning
// anything the moment the feature it filters starts working.
const float PUSH_NOMONSTERS = 512;

// Speed the player was travelling at the START of this frame's pmove, before
// any of it was clipped away.  Latched once per PM_PlayerMove.
//
// This exists because func_breakable's SF_BREAK_TOUCH gate cannot use
// .velocity.  Half-Life's BreakTouch runs from inside the engine's move, at the
// instant of impact, so `pevToucher->velocity.Length()` there is the APPROACH
// speed.  Here the touch is dispatched by SV_CheckTouchTriggers AFTER the whole
// move has run, and PM_SlideMove has already reflected pm_velocity off the very
// brush being touched (PM_ClipVelocity) — so a player sprinting head-on into a
// pane arrives with his into-the-plane component gone and reads ~0.  That is
// exactly backwards: the harder you run at plate glass, the more completely the
// speed that should have broken it is removed before anything measures it.
//
// Declared here, at compile position 10, because sv_breakable.qc reads it at 44
// and sh_pmove.qc writes it at 465 — fields do not forward-declare.
.float pm_impact_speed;

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
// func_tracktrain driving, the same shape one row up but for a train rather than
// a car.  Read by server/sv_func_traincontrols.qc and stashed each tick by
// sv_player.qc; server-side only, so unlike pm_incar these are not on the
// prediction proxy — a driven train moves the player by carrying the brush, and
// the carry is already replicated.
.entity tt_driving;     // on PLAYER: the func_tracktrain being driven, or world
.float  pm_ontrain;     // on PLAYER: standing on a driveable train (eviction test)
.float  tt_in_fwd;      // on PLAYER: forward input stashed while driving
.float  tt_in_side;     // on PLAYER: steer input stashed while driving
.float  tt_prev_fwd;    // on PLAYER: previous tick's tt_in_fwd, for edge detection
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
void(vector src, vector mn, vector mx, vector end,
     float moveflags, entity ignore) Lagcomp_TraceBox;
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

// HL's CCrowbar m_flNextPrimaryAttack, as the charge test at crowbar.cpp:240
// sees it.  Stamped with the RESULTING attack_finished at the end of every
// crowbar swing; the next swing compares (this + 1 s) against its own `now` to
// decide full damage vs half.
//
// A field rather than a file-scope global because SSQC runs this for every
// player at once.  Kept SEPARATE from attack_finished because
// W_StandardEquipSetup does not clear attack_finished, so a slow weapon held
// just before the crowbar would otherwise poison the charge clock.
//
// Named generically: the same idiom fits the knife and wrench later.
.float melee_charge_ref;

#ifdef CSQC
// Standard QW player fields not present in cl_defs.qc. Declared here in
// shared (early in cl_progs.src) instead of client/cl_customdefs.qc so
// shared files compiled BEFORE cl_customdefs.qc — like sh_weapons.qc's
// Weapon_SpeedFactor_Smooth — can reference self.weapon. SSQC has these
// from sv_defs.qc; this CSQC-only block matches.
.float weapon;
.float weaponframe;

// GoldSrc SF_BREAK_CROWBAR / BREAKABLE_INSTANT_CROWBAR on a func_breakable,
// replicated in bit 1 of the brush flag byte (sv_brushsync.qc / cl_brushsync.qc).
//
// Declared HERE, at cl_progs.src position 7, rather than in cl_brushsync.qc at
// position 75, because the melee path in sh_weapon_logic.qc (position 25) is
// what has to read it — and it has to, because the client's breakclaim is what
// actually spends a breakable's HP under the default sv_trust_clientbreak 1.
.float brush_instant_melee;
// Replicated current HP of a breakable.  Also declared in cl_bulletimpact.qc and
// cl_brushsync.qc — both of which compile after sh_weapon_logic.qc, which is why
// it needs a copy here.  Identical redeclaration, the same pattern
// .brush_max_health already uses across those two files.
.float brush_health;

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

// Monsters are ENGINE entities, so they are not in the CSQC world at all and a
// CSQC traceline goes straight through them - which is why the shooter's own
// bullets used to land on the wall behind an NPC, as concrete, with a hole.
// Same override technique as the two above, reading the engine entity list
// through getentity().  Defined in client/cl_monstertrace.qc.
void(vector trace_src, vector trace_end) CSQC_Monster_OverrideTrace;

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
const float TELEPORT_NOCLIENTS        = 16; // spawnflag: do not teleport players at all
// Sven's "Relative Teleport" (its bit 128), translated into this vocabulary at
// spawn like the three above.  Moves the player BY (destination - trigger origin)
// instead of TO the destination, keeping their offset inside the volume, their
// facing and their velocity — the seamless kind, used for looping lift shafts.
// Implies keep-velocity and keep-angle by construction; see the block in
// PM_CheckTeleportTriggers.
const float TELEPORT_RELATIVE         = 64;
// SWITCHED OFF RIGHT NOW.  Not a map spawnflag - a runtime state, carried in
// .spawnflags precisely because that field is already on the trigger_teleport wire
// and already read by the shared pmove on both sides.  A toggled teleporter is
// therefore predicted correctly with no protocol change at all, which a separate
// field would not have been.
const float TELEPORT_INACTIVE         = 32;
//
// These three are the MOD's vocabulary and are what everything downstream —
// including the CSQC prediction path — reads.  GoldSrc maps use a completely
// different bit layout and are translated into this one at spawn by
// Teleport_NormaliseFlags (sv_teleport.qc):
//
//     bit   nettest.fgd (ours)   sven-coop.fgd (Trigger base + own)
//       1   -                    Monsters
//       2   -                    No Clients          -> our 16
//       4   Keep Velocity        Pushables
//       8   Keep Angle           Everything else
//      16   (No Clients)         Fire On Enter
//      32   -                    Fire On Exit
//      64   -                    Random Destination
//     128   -                    Relative Teleport   (NOT IMPLEMENTED)
//     256   -                    Keep Angles         -> our 8
//     512   -                    Keep velocity       -> our 4
//    1024   -                    Rotate (Dest Angles) (NOT IMPLEMENTED)
//
// Measured: -sp_campaign_portal's 8 teleports carry 896 / 909 / 1920, so they
// genuinely use 256 and 512 — and 909 additionally trips our raw 4 and 8 by
// accident.  pizza_ya_san1's single teleport is 6 (Pushables | No Clients),
// which under Sven must NOT move a player; before this it did.

// Per-teleport-trigger entity fields (cached destination, set at spawn time)
.vector tele_dest_origin;  // world-space destination position
.vector tele_dest_angles;  // destination view angles (zero = no snap)
.float  tele_resolved;     // TRUE once Teleport_FindDestination succeeded

// Per-player entity fields for teleport state
.float  pm_teleport_time;       // countdown guard: seconds remaining before player can re-teleport
// WHERE THE LAST TELEPORT PUT US.  A time guard alone cannot make a two-way
// portal work, and hl_c05_a2's silo pair is the proof: each of its two
// trigger_teleports sits exactly on the OTHER one's destination, so arriving
// through one lands you inside the other and any purely time-based cooldown just
// sets the interval at which you bounce.  The map ships teleport_cooldown 0.001 on
// both triggers and 0.0001 on both destinations - the author disabled every timer
// Sven has - which is only survivable if the real rule is positional: a trigger
// may not fire on a player who has not LEFT it since arriving.  This is that rule.
// Predicted identically on both sides because it is derived from position alone.
.vector pm_teleport_org;
.float  pm_ladder_detach_time;  // countdown guard: seconds remaining before player can re-grab a ladder
.float  codstamina;             // sv_codstamina: 0..1 stamina pool, depletes during sprint (1/4.5 per sec) and during hold-breath while scoped (1/8 per sec); refills otherwise (1/3 per sec).  Both sides run the same drain/refill so prediction stays in sync.
.float  codstamina_punished;    // sv_codstamina: 1 = depleted-and-still-recovering punish state (sprint locked out, hold-breath locked out + heavy-breathing punish, bar drawn red).  Clears when codstamina refills to >= STAMINA_PUNISH_RECOVER_AT.
.float  pm_last_onground_time;  // sv_codstamina: absolute world-time of the most recent on-ground tick — drives the sv_codstamina_ground_grace hysteresis in the sprint drain so single-frame FL_ONGROUND drops on clip-brush stairs don't pause the drain.  Uses `time` (pmove clock) so CSQC and SSQC agree across reconcile-replay.
.float  pm_fire_suppress_until; // sv_codstamina + cl_codscope: absolute `time` at which the post-fire scope-suppression window ends.  Set by SH_StandardTryFire on a successful shot; while time < this value, (a) the pmove stamina drain treats st_scope as 0 even with +attack2 held (fixes "drain continues after auto-unscope"), (b) cl_viewfx ADS target is forced to 0 (gun drops out of ADS), (c) the CoD scope state machine's OFF→RAISING re-entry is blocked.  When the window expires with +attack2 still held, the scope auto-re-engages (the user-requested "return to ADS scoping in after the shot is complete" behaviour).
.float  pm_on_ladder_cached;    // pm_on_ladder latched at end of PM_PlayerMoveStep so CSQC view-fx (cl_viewfx.qc) and the Weapon_LowerBlocksFire helper can read it without re-running PM_CheckLadder.  Recomputed every pmove tick; NOT replicated through the prediction proxy (the trigger list and BSP contents are already replicated, so PM_CheckLadder reproduces the value deterministically on reconcile-replay).
.float  pm_carrying;            // 1 while the player is carrying a phys_files prop (HL2 carry — sv_physprop.qc Carry_*).  Drives the lowered/deactivated viewmodel + fire-block exactly like grapple_rope_active: SSQC sets it authoritatively, REPLICATED through the prediction proxy (sv_player.qc writer ↔ cl_player.qc reader) so CSQC's Weapon_LowerBlocksFire / lower envelope agree and firing doesn't mispredict.
// Sven Co-op item_inventory holder effects, folded to four scalars by
// Inv_RecalcEffects (server/sv_item_inventory.qc) and REPLICATED through the
// prediction proxy for the same reason pm_carrying above is: PM_LoadMovevars
// and Weapon_LowerBlocksFire read them on BOTH sides, and a server that halves
// maxspeed while CSQC still predicts the full value rubber-bands every step.
// Percentages rather than multipliers because that is what the wire carries —
// one byte each, 100 = unchanged, matching Sven's own units for effect_speed /
// effect_gravity / effect_friction.  ZERO also means unchanged: a player who
// has never touched an item_inventory has these at 0, and PM_LoadMovevars
// treats 0 and 100 identically so the untouched case costs nothing.
.float  pm_inv_speed_pct;       // effect_speed aggregate, percent
.float  pm_inv_gravity_pct;     // effect_gravity aggregate, percent
.float  pm_inv_friction_pct;    // effect_friction aggregate, percent
.float  pm_inv_blockfire;       // effect_block_weapons: both hands full, gun lowered

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
// THE TEAM-INDEPENDENT MODELS, in ONE table.
//
// player_model_index 0-3 are the per-team models above and are encoded as
// (team-1)*4 + index.  Everything from 5 up is team-independent and rides a
// SENTINEL byte counting down from 255.  Bytes 8..246 are unused — the encoder
// has only ever emitted 0-7 and the sentinels — so adding models costs no wire
// format change at all, only entries here.
//
// THESE TWO FUNCTIONS EXIST BECAUSE THE RULE HAD THREE HAND-WRITTEN COPIES:
// server/sv_player.qc's PlayerApplyModel (index -> path), the visual-proxy
// writer in the same file (index -> byte), and a third in server/sv_physprop.qc
// for the seated car driver.  Adding a model meant editing all three plus the
// decoder, and nothing linked them; the seated-driver copy is exactly the kind
// that gets missed.  One table, four callers.
const float PLAYERMODEL_DOD_FIRST  = 9;
const float PLAYERMODEL_DOD_LAST   = 13;
const float PLAYERMODEL_MAX_INDEX  = 13;

// "" when the index is a per-team model (0-3) — the caller resolves those from
// team_blue_models / team_red_models, which need the team.
string(float idx) SH_TeamlessModelPath =
{
    if (idx == 5)  return "models/player/sini.mdl";
    if (idx == 6)  return "models/player/chickenman/chickenman.iqm";
    if (idx == 7)  return "models/player/numberk/numberK.iqm";
    if (idx == 8)  return "models/player/kilmer/kilmer.iqm";
    // Day of Defeat.  Mounted from the dod gamedir (fs_addons.txt), 345
    // sequences each, and animated by NAME through shared/sh_player_dod.qc
    // rather than by the CSANIM_* indices — see SH_ModelIsDoD.
    if (idx == 9)  return "models/player/us-inf/us-inf.mdl";
    if (idx == 10) return "models/player/axis-inf/axis-inf.mdl";
    if (idx == 11) return "models/player/brit-inf/brit-inf.mdl";
    if (idx == 12) return "models/player/us-para/us-para.mdl";
    if (idx == 13) return "models/player/axis-para/axis-para.mdl";
    return "";
};

// 0 when the index is a per-team model — same split as above.
float(float idx) SH_TeamlessModelByte =
{
    if (idx == 5)  return 255;
    if (idx == 6)  return 254;
    if (idx == 7)  return 253;
    if (idx == 8)  return 252;
    if (idx == 9)  return 251;
    if (idx == 10) return 250;
    if (idx == 11) return 249;
    if (idx == 12) return 248;
    if (idx == 13) return 247;
    return 0;
};

string(float tmbyte) SH_ModelPathForTeamByte =
{
    // Sentinels first, decoded straight back through the same table the encoder
    // used, so the two cannot drift.  The floor()/stride arithmetic below is only
    // reachable for a real 0-7 team byte.
    if (tmbyte >= 247)
    {
        // 255 -> 5, 254 -> 6, ... 247 -> 13
        string p = SH_TeamlessModelPath(260 - tmbyte);
        if (p != "")
            return p;
    }
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

// Sven Co-op trigger_camera binding.  0 = this player is not in a cutscene.
// Otherwise the low bits carry the bound camera's entnum (so CSQC can find the
// CSQC_ENT_TRIGGER_CAMERA entity holding the pose) and the high bits carry the
// per-player presentation flags below.  One stat rather than two because the
// binding and its presentation always change together, and a split would let
// them arrive on different frames and flicker.
const float STAT_CUTSCENE         = 65;
// 16 bits of entnum, not 12: pizza_ya_san1 alone spawns 897 map entities and a
// busy server adds players, projectiles and temp entities on top, so a 4095
// ceiling is closer than it looks — and an aliased entnum would bind the view
// to the wrong entity rather than fail visibly.
const float CUTSCENE_ENT_MASK     = 0x0FFFF;  // bound camera entnum (0 = none)
const float CUTSCENE_SF_FREEZE    = 0x10000;  // player is frozen for the duration
const float CUTSCENE_SF_CURSOR    = 0x20000;  // mouse cursor + trigger_cameratarget picking
const float CUTSCENE_SF_NOHEALTH  = 0x40000;  // hud_health -1   — hide health/battery
const float CUTSCENE_SF_NOFLASH   = 0x80000;  // hud_flashlight -1
const float CUTSCENE_SF_NOWEAPONS = 0x100000; // hud_weapons -1  — hide belt + ammo

// Counter-Strike tactical shield.  ONE stat rather than two booleans: carrying
// and deploying always change together from the client's point of view (the
// viewmodel, the player-animation family and the movement speed all key off the
// pair), and splitting them would let the two arrive on different frames and
// flicker between the shielded and unshielded pose.
const float STAT_SHIELD           = 66;
const float SHIELD_CARRIED        = 1;   // the player has weapon_shield
const float SHIELD_DEPLOYED       = 2;   // ...and is holding it up (+attack2)

// Medkit carrier only: is there anything in front of them worth spending a
// charge on?  Exactly the STAT_CAN_PLANT pattern and for exactly the same
// reason — the predicate is server-only, and without it the client predicts the
// heal/revive animation where the server refuses (anim plays, nobody healed).
// That was the reported "don't do weapon_medkit animations if no healing is
// going to take place".
//
// ONE stat, two bits, because the two fire modes are asked on the same frame and
// splitting them would cost a second stat slot for nothing.
//
// The predicate CANNOT be shared the way the tripmine's surface test can:
// W_WeaponTraceLine is server machinery (lag-comp rewind, corpse masking,
// monster cull-box inflation), and CSQC cannot see monsters at all
// (client/cl_monstertrace.qc:11) — friendly NPCs are half the medkit's valid
// targets, so a client-side traceline would silently refuse every ally heal.
//
// Treat it as a PERMISSIVE HINT, not authority: it is computed from the
// server's last tick, and a medkit target is a moving player under a swinging
// crosshair, so it is a snapshot stale and will occasionally refuse a heal the
// server would have allowed.  The authoritative refusal stays in W_MedkitUse /
// W_MedkitRevive where it already is.
const float STAT_CAN_MEDKIT       = 67;
const float MEDKIT_CAN_HEAL       = 1;   // a woundable target is in reach
const float MEDKIT_CAN_REVIVE     = 2;   // a revivable corpse is in reach

// SOFLAM carrier only: is the designator actually looking at something it can
// call a strike on?  Same pattern, same reason as STAT_CAN_MEDKIT above —
// W_SoflamFindTarget is server-only, so without this the client played the full
// designate take and the server answered with an hgrunt saying "negative".
const float STAT_CAN_SOFLAM       = 68;

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
// TRUE when the running map is a GoldSrc/Half-Life BSP (version 30).
//
// Shared twin of the server-only Map_IsGoldSrc() in sv_customdefs.qc.  The
// engine advertises the worldmodel's BSP version in serverinfo, and serverinfo
// is replicated, so both VMs can answer the same question — the server reads it
// with infokey(world, ...) and the client with serverkey(...).
float() Map_IsGoldSrcShared =
{
#ifdef CSQC
    return stof(serverkey("*bspversion")) == 30;
#else
    return stof(infokey(world, "*bspversion")) == 30;
#endif
};

float() Gamemode_HasUnifiedTeams =
{
#ifdef CSQC
    float gm = getstatf(STAT_GAMEMODE);
#else
    float gm = cvar("sv_gamemode");
#endif
    if (gm == GAMEMODE_FFA || gm == GAMEMODE_BHOP)
        return TRUE;

    // GoldSrc / Sven Co-op maps are single-team co-op: they ship ONE spawn
    // pool (info_player_deathmatch) and no team spawns at all, and their whole
    // progression assumes everybody is on the same side.  Routing them through
    // the unified path collapses the Phase-0 team pick, merges the scoreboard
    // column and bypasses friendly fire — which is what "don't worry about
    // teams, there is only one spawn" needs.  Resolved from serverinfo rather
    // than a new gamemode value so it costs no network stat and no menu work.
    if (Map_IsGoldSrcShared())
        return TRUE;

    return FALSE;
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
void() Hornet_PrecacheTrails;   // shared/weapons/sh_wpn_hlhornetgun.qc

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
float pp_dbg_cvars_reported;      // one-shot: dump the contact-FX tuning values under sv_debug_physprops
// sv_physprop_weapon_trace_bbox_{x,y,z}, cached as one vector.  These were read
// with three cvar() string-hashes EVERY TIME a server hitscan traced, and
// W_PenetratingHitscanShoot traces up to five times per shot through a wrapper
// that expands and restores — so an MG42 at 20 rounds/second was paying 300
// cvar hashes a second for three numbers that never change.
vector pp_cached_wep_trace_bbox;
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
	// Server-side particle handles.  particleeffectnum() on the server is
	// SV_ParticlePrecache_Add, and the precache list is handed to a client when
	// it CONNECTS -- an entry added later (at first shot) leaves an already-
	// connected client with an index it has no name for, so the effect draws
	// nothing.  Anything the server puts in .traileffectnum must be registered
	// here, before anyone joins.
	Hornet_PrecacheTrails();
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

    // --- Day of Defeat player models ---
    //
    // NOT SELECTABLE YET.  Precached so the animation probe below can measure
    // them: getmodelindex returns 0 for an unprecached path, and every shape
    // test in sh_player_anims.qc opens with `if (mdlidx <= 0) return FALSE;`
    // (SH_ModelIsSven:320, SH_ModelIsDoD beside it) — so an unloaded model
    // reports "not DoD-shaped" for the wrong reason and the measurement lies in
    // the direction that looks like success.
    //
    // These come from the MOUNTED dod gamedir (fs_addons.txt:50
    // steam:Half-Life/dod), not from the mod, so they cost nothing on the CDN —
    // the same arrangement every DoD weapon model in this tree already relies on.
    //
    // Hitbox_RegisterModel is a deliberate no-op here: it bails on the model type
    // before it looks at a bone name (com_mesh.c, Mod_AddHitbox), and these carry
    // their own 21 native studio hitboxes with groups 1-7 — verified, no group is
    // outside HL's range, unlike the HL monsters (see [[hitgroups-above-7-are-real]]).
    // It is called anyway so the line reads like its eleven neighbours.
    Hitbox_RegisterModel(precache_model("models/player/us-inf/us-inf.mdl"));
    Hitbox_RegisterModel(precache_model("models/player/axis-inf/axis-inf.mdl"));
    Hitbox_RegisterModel(precache_model("models/player/brit-inf/brit-inf.mdl"));
    Hitbox_RegisterModel(precache_model("models/player/us-para/us-para.mdl"));
    Hitbox_RegisterModel(precache_model("models/player/axis-para/axis-para.mdl"));

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
	// Surfacing gasps for Player_WaterMove (sv_player.qc) — player.cpp:1238/1240.
	// These are the MOUNTED Half-Life/Sven originals, not files under sounds/,
	// so no local copy exists to fall back on.  They belong in this
	// unconditional worldspawn block and NOT beside the pl_slosh* set in
	// sv_func_pushable.qc: that one sits inside func_pushable's spawn function
	// and so only runs on maps that happen to contain a pushable.
	precache_sound("player/pl_wade1.wav");
	precache_sound("player/pl_wade2.wav");
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

    // Third-person weapon models (p_models).
    //
    // The twelve CS ones come from the cstrike MOUNT as of 2026-08-30.  Every
    // mod-local copy was verified BYTE-IDENTICAL to the mount original first
    // (md5, all twelve) — they were pure duplicates, unlike the v_/w_ pairs in
    // the same directories, which were lossy Quake-MDL conversions.
    precache_model("models/p_ak47.mdl");
    precache_model("models/weapons/wpn_hdak47/p_ak47.mdl");
    precache_model("models/p_awp.mdl");
    precache_model("models/p_deagle.mdl");
    precache_model("models/p_g3sg1.mdl");
    precache_model("models/p_glock18.mdl");
    precache_model("models/p_knife.mdl");
    precache_model("models/weapons/wpn_butteryfly/p_knife.mdl");
    precache_model("models/weapons/wpn_cfaug/p_aug.mdl");
    precache_model("models/weapons/wpn_cffamas/p_famas.mdl");
    precache_model("models/weapons/wpn_cfmac10/p_mac10.mdl");
    precache_model("models/weapons/wpn_cfc4/p_c4.mdl");
    precache_model("models/p_m3.mdl");
    precache_model("models/p_m4a1.mdl");
    precache_model("models/p_m249.mdl");
    precache_model("models/p_mp5.mdl");
    precache_model("models/p_scout.mdl");
    precache_model("models/p_k98.mdl");   // DoD mount — see the 98k block below

	// HL SMG — models now precached in the HL GUNS block below.
	// models/weapons/wpn_hlsmg/grenade.mdl went with them, and it was ALREADY
	// dead: nothing ever setmodel()s it.  Both the server projectile
	// (sh_wpn_hlsmg.qc:322) and the CSQC fake use
	// models/weapons/wpn_grenadelauncher/grenade.mdl, precached in the grenade
	// launcher's own block — so on a map that placed the SMG but not the GL,
	// the alt-fire projectile was precache-missing.  It no longer is: the
	// launcher block is unconditional too.
	//
	// The contact grenade has since moved to Half-Life's OWN models/grenade.mdl
	// (ggrenade.cpp:351) under its own PROJ_TYPE_SMG_GRENADE, so that it can
	// carry HL's flight shape without dragging the grenade launcher and the
	// SOFLAM mortar — which share PROJ_TYPE_GRENADE — onto the same numbers.
	precache_model("models/grenade.mdl");
    precache_sound("sounds/weapons/wpn_hlsmg/fire1.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/fire2.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/fire3.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/glauncher1.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/glauncher2.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlsmg/reload2.wav");

	// HL RPG — models now precached in the HL GUNS block below, rocket included.
    precache_sound("sounds/weapons/wpn_hlrpg/fire.wav");
    precache_sound("sounds/weapons/wpn_hlrpg/fly.wav");

	// HL GUNS — the mounted Half-Life originals, replacing the local IDPO
	// conversions under models/weapons/wpn_hl*/.  These come out of the
	// `steam:Half-Life/valve` mount listed in quakers/fs_addons.txt; a tester
	// without Half-Life installed gets missing models here, which is the
	// accepted trade for using the real guns.
	precache_model("models/v_9mmhandgun.mdl");   // HL Glock
	precache_model("models/w_9mmhandgun.mdl");
	precache_model("models/p_9mmhandgun.mdl");
	precache_model("models/v_9mmar.mdl");        // HL SMG (MP5 / 9mmAR)
	precache_model("models/w_9mmar.mdl");
	precache_model("models/p_9mmar.mdl");
	precache_model("models/v_shotgun.mdl");
	precache_model("models/w_shotgun.mdl");
	precache_model("models/p_shotgun.mdl");
	precache_model("models/v_357.mdl");
	precache_model("models/w_357.mdl");
	precache_model("models/p_357.mdl");
	precache_model("models/v_crowbar.mdl");
	precache_model("models/w_crowbar.mdl");
	precache_model("models/p_crowbar.mdl");
	precache_model("models/v_egon.mdl");
	precache_model("models/w_egon.mdl");
	precache_model("models/p_egon.mdl");
	precache_model("models/v_gauss.mdl");
	precache_model("models/w_gauss.mdl");
	precache_model("models/p_gauss.mdl");
	precache_model("models/v_crossbow.mdl");
	precache_model("models/w_crossbow.mdl");
	precache_model("models/p_crossbow.mdl");
	precache_model("models/v_rpg.mdl");
	precache_model("models/w_rpg.mdl");
	precache_model("models/p_rpg.mdl");
	precache_model("models/v_grenade.mdl");
	precache_model("models/w_grenade.mdl");      // also the thrown projectile
	precache_model("models/p_grenade.mdl");
	precache_model("models/rpgrocket.mdl");      // the RPG's projectile

	// THEY HUNGER GUNS — the eight promoted out of the pickup-alias block in
	// server/sv_goldsrc_pickups.qc.  These come out of the
	// `steam:Sven Co-op/svencoop` mount listed in quakers/fs_addons.txt, the
	// same accepted trade as the Half-Life block above: a tester without Sven
	// Co-op installed gets missing models here.
	//
	// Precached UNCONDITIONALLY, like the equipment block below, and for the
	// same reason: these eight are reachable from the buy menu and the F5
	// spawn panel on any map, not just the They Hunger campaign, so waiting
	// for a map to place one would make every other route a late precache —
	// which is a client desync, not a missing model.
	//
	// The sounds live in the mount too (svencoop/sound/hunger/weapons/) and
	// keep their on-disk capitalisation: TOZ_*, M3_*, M1921_* are really
	// spelled that way, and FTE's VFS is case-sensitive against real files on
	// Linux.  The tesla's are .ogg, not .wav.
	precache_model("models/hunger/weapons/colt/v_1911.mdl");
	precache_model("models/hunger/weapons/colt/w_1911.mdl");
	precache_model("models/hunger/weapons/colt/p_1911.mdl");
	precache_model("models/hunger/weapons/tommygun/v_tommygun.mdl");
	precache_model("models/hunger/weapons/tommygun/w_tommygun.mdl");
	precache_model("models/hunger/weapons/tommygun/p_tommygun.mdl");
	precache_model("models/hunger/weapons/greasegun/v_greasegun.mdl");
	precache_model("models/hunger/weapons/greasegun/w_greasegun.mdl");
	precache_model("models/hunger/weapons/greasegun/p_greasegun.mdl");
	precache_model("models/hunger/weapons/m14/v_m14.mdl");
	precache_model("models/hunger/weapons/m14/w_m14.mdl");
	precache_model("models/hunger/weapons/m14/p_m14.mdl");
	precache_model("models/hunger/weapons/m16a1/v_m16.mdl");
	precache_model("models/hunger/weapons/m16a1/w_m16.mdl");
	precache_model("models/hunger/weapons/m16a1/p_m16.mdl");
	precache_model("models/hunger/weapons/dbarrel/v_dbarrel.mdl");
	precache_model("models/hunger/weapons/dbarrel/w_dbarrel.mdl");
	precache_model("models/hunger/weapons/dbarrel/p_dbarrel.mdl");
	precache_model("models/hunger/weapons/spanner/v_spanner.mdl");
	precache_model("models/hunger/weapons/spanner/w_spanner.mdl");
	precache_model("models/hunger/weapons/spanner/p_spanner.mdl");
	precache_model("models/hunger/weapons/tesla/v_tesla.mdl");
	precache_model("models/hunger/weapons/tesla/w_tesla.mdl");
	precache_model("models/hunger/weapons/tesla/p_tesla.mdl");

	// SVEN CO-OP / OPPOSING FORCE GUNS — the nine promoted out of the
	// pickup-alias block in server/sv_goldsrc_pickups.qc and
	// sv_goldsrc_compat.qc.  Precached unconditionally for the same reason the
	// They Hunger block above is: all nine are reachable from the buy menu and
	// the F5 spawn panel on ANY map, so a lazy precache would be a client
	// desync rather than a saving.
	//
	// Sourced from the `steam:Sven Co-op/svencoop` mount in quakers/fs_addons.txt.
	// A tester without Sven Co-op installed gets missing models here — the same
	// accepted trade the HL GUNS block above makes for the Half-Life originals.
	//
	// TWO NAMES THAT ARE NOT WHAT THEY LOOK LIKE, and both were checked against
	// the mount rather than guessed from the classname:
	//   w_pmedkit.mdl  is the carried WEAPON.  w_medkit.mdl is item_healthkit.
	//   v_m16a2.mdl    is the M16's viewmodel.  There is no v_m16.mdl.
	// The akimbo UZI has no viewmodel of its own at all: it is sequences 8-16
	// of v_uzi.mdl, which is why only its w_/p_ pair appears below.
	precache_model("models/v_medkit.mdl");         // Sven medkit (healing tool)
	precache_model("models/w_pmedkit.mdl");
	precache_model("models/p_medkit.mdl");
	precache_model("models/v_uzi.mdl");            // Sven UZI — also the akimbo's
	precache_model("models/w_uzi.mdl");
	precache_model("models/p_uzi.mdl");
	precache_model("models/w_2uzis.mdl");          // Sven akimbo UZIs
	precache_model("models/p_2uzis.mdl");
	precache_model("models/v_minigun.mdl");        // Sven minigun
	precache_model("models/w_minigun.mdl");
	precache_model("models/p_minigunidle.mdl");
	precache_model("models/v_m16a2.mdl");          // Sven M16
	precache_model("models/w_m16.mdl");
	precache_model("models/p_m16.mdl");
	precache_model("models/v_pipe_wrench.mdl");    // OpFor pipe wrench
	precache_model("models/w_pipe_wrench.mdl");
	precache_model("models/p_pipe_wrench.mdl");
	precache_model("models/v_m40a1.mdl");          // OpFor sniper rifle
	precache_model("models/w_m40a1.mdl");
	precache_model("models/p_m40a1.mdl");
	precache_model("models/v_spore_launcher.mdl"); // OpFor spore launcher
	precache_model("models/w_spore_launcher.mdl");
	precache_model("models/p_spore_launcher.mdl");
	precache_model("models/spore.mdl");            // ...and its projectile
	precache_model("models/v_desert_eagle.mdl");   // OpFor Desert Eagle
	precache_model("models/w_desert_eagle.mdl");
	precache_model("models/p_desert_eagle.mdl");
	precache_model("models/v_knife.mdl");          // OpFor combat knife
	precache_model("models/w_knife.mdl");
	precache_model("models/p_knife.mdl");
	precache_model("models/v_saw.mdl");            // OpFor M249 SAW
	precache_model("models/w_saw.mdl");
	precache_model("models/p_saw.mdl");
	precache_model("models/v_penguin.mdl");        // OpFor penguin
	precache_model("models/w_penguinnest.mdl");    // ...the ground pickup is the NEST
	precache_model("models/w_penguin.mdl");        // ...and this is the thrown creature
	precache_model("models/p_penguin.mdl");
	// The snark's own nest, which sh_wpn_hlsnark.qc recorded as missing from the
	// mount and is not: valve/models/w_sqknest.mdl sits beside w_squeak.mdl.  Its
	// pickup is the nest now, like Half-Life's.
	precache_model("models/w_sqknest.mdl");

	// pizza_ya_san1's two AngelScript weapons.  These come from
	// svencoop_downloads rather than svencoop, and unlike the nine above they
	// are map-local content — but the same argument applies: both are in the
	// weapon manifest, so both are spawnable anywhere.
	precache_model("models/pizza_ya_san/v_shotgun_shorty.mdl");
	precache_model("models/pizza_ya_san/w_shotgun_shorty.mdl");
	precache_model("models/pizza_ya_san/p_shotgun_shorty.mdl");
	precache_model("models/pizza_ya_san/v_soflam.mdl");
	precache_model("models/pizza_ya_san/w_soflam.mdl");
	precache_model("models/pizza_ya_san/p_soflam.mdl");

	// ...and their sounds.  The medkit's live under items/ rather than weapons/
	// because there is no medkit audio in sound/weapons/ at all.
	precache_sound("items/medshot4.wav");
	precache_sound("items/medshot5.wav");
	precache_sound("items/medshotno1.wav");
	precache_sound("weapons/uzi/shoot1.wav");
	precache_sound("weapons/uzi/shoot2.wav");
	precache_sound("weapons/uzi/shoot3.wav");
	precache_sound("weapons/uzi/deploy.wav");
	precache_sound("weapons/uzi/reload1.wav");
	precache_sound("weapons/uzi/reload2.wav");
	precache_sound("weapons/uzi/reload3.wav");
	precache_sound("weapons/uzi/akimbo_deploy.wav");
	precache_sound("weapons/uzi/fire_both1.wav");
	precache_sound("weapons/uzi/fire_both2.wav");
	precache_sound("weapons/uzi/reload_left1.wav");
	precache_sound("weapons/uzi/reload_right1.wav");
	// The SAW's set.  Borrowed by the MINIGUN only — the mount really does ship
	// no minigun audio.  It used to be borrowed by the M16 as well, on the stated
	// grounds that there were "no M16-specific samples"; that was false and is
	// corrected below.  saw_fire1/boxin/boxout/bolt stay precached because the
	// minigun's reload and dry paths still use them.
	precache_sound("weapons/saw_fire1.wav");
	precache_sound("weapons/saw_fire2.wav");
	precache_sound("weapons/saw_deploy.wav");
	precache_sound("weapons/saw_boxin.wav");
	precache_sound("weapons/saw_boxout.wav");
	precache_sound("weapons/saw_bolt.wav");
	// Sven's own M16 set — svencoop/sound/weapons.  m16_3round.wav is a
	// three-shot one-shot sample, which is the mount's own evidence that
	// weapon_m16 is a burst gun and not the full-auto it was implemented as.
	precache_sound("weapons/m16_3round.wav");
	precache_sound("weapons/m16_single.wav");
	precache_sound("weapons/m16_magout_metallic.wav");
	precache_sound("weapons/m16_magin_metallic.wav");
	precache_sound("weapons/m16_charge.wav");
	precache_sound("weapons/pwrench_hit1.wav");
	precache_sound("weapons/pwrench_hit2.wav");
	precache_sound("weapons/pwrench_hitbod1.wav");
	precache_sound("weapons/pwrench_hitbod2.wav");
	precache_sound("weapons/pwrench_hitbod3.wav");
	precache_sound("weapons/pwrench_miss1.wav");
	precache_sound("weapons/pwrench_miss2.wav");
	precache_sound("weapons/pwrench_big_hit1.wav");
	precache_sound("weapons/pwrench_big_hit2.wav");
	precache_sound("weapons/pwrench_big_hitbod1.wav");
	precache_sound("weapons/pwrench_big_hitbod2.wav");
	precache_sound("weapons/pwrench_big_miss.wav");
	// OpFor combat knife.  knife1/2/3 are the swing whooshes and are fired by the
	// model's own studio events on the miss takes as well as from QC.
	precache_sound("weapons/knife1.wav");
	precache_sound("weapons/knife2.wav");
	precache_sound("weapons/knife3.wav");
	precache_sound("weapons/knife_hit_flesh1.wav");
	precache_sound("weapons/knife_hit_flesh2.wav");
	precache_sound("weapons/knife_hit_wall1.wav");
	precache_sound("weapons/knife_hit_wall2.wav");
	// OpFor M249 SAW.  saw_reload / saw_reload2 are gearbox's two reload drills;
	// the seven below are the studio events on svencoop's v_saw.mdl, which is the
	// model that actually wins the mount — see SH_SawReloadSndName.  All nine
	// resolve (svencoop ships every one), and precaching a name the drill never
	// asks for costs one soundindex slot.
	precache_sound("weapons/saw_fire1.wav");
	precache_sound("weapons/saw_fire2.wav");
	precache_sound("weapons/saw_fire3.wav");
	precache_sound("weapons/saw_reload.wav");
	precache_sound("weapons/saw_reload2.wav");
	precache_sound("weapons/saw_bolt.wav");
	precache_sound("weapons/saw_coveropen.wav");
	precache_sound("weapons/saw_beltout.wav");
	precache_sound("weapons/saw_boxout.wav");
	precache_sound("weapons/saw_boxin.wav");
	precache_sound("weapons/saw_beltin.wav");
	precache_sound("weapons/saw_coverdown.wav");
	precache_sound("weapons/sniper_fire.wav");
	precache_sound("weapons/sniper_fire_last_round.wav");
	precache_sound("weapons/sniper_bolt1.wav");
	precache_sound("weapons/sniper_reload_first_seq.wav");
	precache_sound("weapons/sniper_reload_second_seq.wav");
	precache_sound("weapons/spore_ammo.wav");
	precache_sound("weapons/spore_hit1.wav");
	precache_sound("weapons/spore_hit2.wav");
	precache_sound("weapons/spore_hit3.wav");
	// The spore launcher's REAL audio, from the gearbox (Opposing Force) mount
	// rather than Sven's — Sven ships only the ammo and hit samples, so firing
	// used to play spore_ammo.wav, an ammo-handling sound, as the muzzle report.
	precache_sound("weapons/splauncher_fire.wav");
	precache_sound("weapons/splauncher_reload.wav");
	precache_sound("weapons/splauncher_impact.wav");   // spore detonation, sh_wpn_opsporelauncher.qc:230
	precache_sound("weapons/desert_eagle_fire.wav");
	precache_sound("weapons/desert_eagle_reload.wav");
	precache_sound("weapons/desert_eagle_sight.wav");
	// The SOFLAM's radio chatter is the hgrunt voice set, which is what the
	// map's own script uses — the strike is called in over a radio.
	precache_sound("hgrunt/roger.wav");
	precache_sound("hgrunt/yessir.wav");
	precache_sound("hgrunt/affirmative.wav");
	precache_sound("hgrunt/negative.wav");
	// The shorty's audio is entirely stock Half-Life, per its own script — one
	// sbarrel1 per shell, not HL's double-barrel dbarrel.  sbarrel1 and
	// 357_cock1 are already precached with the HL guns above; these two are not.
	precache_sound("weapons/reload1.wav");
	precache_sound("weapons/scock1.wav");

	precache_sound("hunger/weapons/colt/colt_fire1.wav");
	precache_sound("hunger/weapons/colt/colt_fire2.wav");
	precache_sound("hunger/weapons/colt/colt_empty.wav");
	precache_sound("hunger/weapons/colt/1911_magin.wav");
	precache_sound("hunger/weapons/colt/1911_magout.wav");
	precache_sound("hunger/weapons/colt/1911_slideforward.wav");
	precache_sound("hunger/weapons/tommygun/fire.wav");
	precache_sound("hunger/weapons/tommygun/M1921_magin.wav");
	precache_sound("hunger/weapons/tommygun/M1921_magout.wav");
	precache_sound("hunger/weapons/tommygun/M1921_boltback.wav");
	precache_sound("hunger/weapons/greasegun/M3_shoot1.wav");
	precache_sound("hunger/weapons/greasegun/M3_magin.wav");
	precache_sound("hunger/weapons/greasegun/M3_magout.wav");
	precache_sound("hunger/weapons/greasegun/M3_boltpull.wav");
	precache_sound("hunger/weapons/m14/m14_shot1.wav");
	precache_sound("hunger/weapons/m14/m14_shot2.wav");
	precache_sound("hunger/weapons/m14/m14_magin.wav");
	precache_sound("hunger/weapons/m14/m14_magout.wav");
	precache_sound("hunger/weapons/m14/m14_boltrelease.wav");
	precache_sound("hunger/weapons/m14/m14_zoom.wav");
	precache_sound("hunger/weapons/m16a1/m16_fire1.wav");
	precache_sound("hunger/weapons/m16a1/m16_fire2.wav");
	precache_sound("hunger/weapons/m16a1/m16_fire3.wav");
	precache_sound("hunger/weapons/m16a1/m16_burst.wav");
	precache_sound("hunger/weapons/m16a1/m16_magin.wav");
	precache_sound("hunger/weapons/m16a1/m16_magout.wav");
	precache_sound("hunger/weapons/m16a1/m16_boltcatch.wav");
	precache_sound("hunger/weapons/dbarrel/fire.wav");
	precache_sound("hunger/weapons/dbarrel/doublefire.wav");
	precache_sound("hunger/weapons/dbarrel/TOZ_open.wav");
	precache_sound("hunger/weapons/dbarrel/TOZ_close.wav");
	precache_sound("hunger/weapons/dbarrel/TOZ_shell1.wav");
	precache_sound("hunger/weapons/dbarrel/TOZ_shell_out.wav");
	precache_sound("hunger/weapons/tesla/tesla_fire.ogg");
	precache_sound("hunger/weapons/tesla/tesla_spinup.ogg");
	precache_sound("hunger/weapons/tesla/tesla_chargehold.ogg");
	precache_sound("hunger/weapons/tesla/tesla_bigrelease.ogg");
	precache_sound("hunger/weapons/tesla/tesla_draw.ogg");
	// The spanner borrows Opposing Force's pipe-wrench wavs, which is what
	// weapon_spanner.as itself does (:170-176, :225-254).  They live in the
	// gearbox mount, and Sven ships a copy too.
	precache_sound("weapons/pwrench_hit1.wav");
	precache_sound("weapons/pwrench_hit2.wav");
	precache_sound("weapons/pwrench_miss1.wav");
	precache_sound("weapons/pwrench_miss2.wav");

	// HL equipment — satchel / tripmine / snark / hivehand.
	// These are the valve mount's own GoldSrc models rather than converted
	// IDPO copies, which is why the paths have no wpn_* directory.  Every one
	// of them is precached unconditionally: a map that places weapon_satchel
	// but no weapon_tripmine still has to be able to receive a dropped mine
	// from another player, and a late precache is a client desync.
	precache_model("models/v_satchel.mdl");
	precache_model("models/v_satchel_radio.mdl");
	precache_model("models/w_satchel.mdl");
	precache_model("models/p_satchel.mdl");
	precache_model("models/v_tripmine.mdl");
	precache_model("models/p_tripmine.mdl");
	// GROUND PICKUP model, out of the mounted svencoop tree.  The pickup used to
	// draw p_tripmine.mdl, which is the hand-attachment mesh — a mine plus a
	// pair of arms, offset from the origin by the grip pose.  See the note in
	// sh_wpn_hltripmine.qc.
	precache_model("models/w_tripmine.mdl");
	precache_model("models/v_squeak.mdl");
	precache_model("models/w_squeak.mdl");
	precache_model("models/p_squeak.mdl");
	precache_model("models/v_hgun.mdl");
	precache_model("models/w_hgun.mdl");
	precache_model("models/p_hgun.mdl");
	precache_model("models/hornet.mdl");
	precache_model("sprites/laserbeam.spr");    // the tripmine's laser
	// Beam/impact sprites for the gauss and egon, now that both draw through the
	// real GoldSrc beam renderer instead of a particle streak.  Names are the
	// ON-DISK spelling, which is lowercase for all four — the SDK writes
	// "sprites/XSpark1.spr" but the shipped file is xspark1.spr, and FTE's VFS
	// is case-sensitive against real files on Linux.
	precache_model("sprites/laserdot.spr");     // RPG guide spot   (rpg.cpp CLaserSpot::Spawn)
	precache_model("sprites/smoke.spr");        // gauss beam       (ev_hldm.cpp EV_FireGauss)
	precache_model("sprites/hotglow.spr");      // gauss impact glow + ricochet balls
	precache_model("sprites/xbeam1.spr");       // egon beam        (EGON_BEAM_SPRITE)
	precache_model("sprites/xspark1.spr");      // egon endpoint flare (EGON_FLARE_SPRITE)
	precache_sound("weapons/g_bounce1.wav");
	precache_sound("weapons/g_bounce2.wav");
	precache_sound("weapons/g_bounce3.wav");
	precache_sound("weapons/mine_deploy.wav");
	precache_sound("weapons/mine_activate.wav");
	precache_sound("weapons/mine_charge.wav");
	precache_sound("squeek/sqk_blast1.wav");
	precache_sound("squeek/sqk_die1.wav");
	precache_sound("squeek/sqk_deploy1.wav");
	precache_sound("squeek/sqk_hunt1.wav");
	precache_sound("squeek/sqk_hunt2.wav");
	precache_sound("squeek/sqk_hunt3.wav");
	precache_sound("agrunt/ag_fire1.wav");
	precache_sound("agrunt/ag_fire2.wav");
	precache_sound("agrunt/ag_fire3.wav");
	// The in-flight buzz, re-emitted every TrackTarget tick (hornet.cpp:295).
	precache_sound("hornet/ag_buzz1.wav");
	precache_sound("hornet/ag_buzz2.wav");
	precache_sound("hornet/ag_buzz3.wav");
	precache_sound("hornet/ag_hornethit1.wav");
	precache_sound("hornet/ag_hornethit2.wav");
	precache_sound("hornet/ag_hornethit3.wav");

	// HL Grenade — models now precached in the HL GUNS block above.
    precache_sound("sounds/weapons/wpn_hlgrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/explode3.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/hit1.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/hit2.wav");
    precache_sound("sounds/weapons/wpn_hlgrenade/hit3.wav");

	// CS throwable utilities
    // Models come from the cstrike mount now — see the block comment on
    // CSHE_VIEWMODEL in shared/weapons/sh_wpn_csgrenades.qc.  The SOUNDS are
    // still the mod's own and stay where they are.
    precache_model("models/v_hegrenade.mdl");
    precache_model("models/w_hegrenade.mdl");
    precache_model("models/p_hegrenade.mdl");
    precache_sound("sounds/weapons/wpn_cshegrenade/pinpull.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/bounce.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode1.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode2.wav");
    precache_sound("sounds/weapons/wpn_cshegrenade/explode3.wav");
    precache_model("models/v_flashbang.mdl");
    precache_model("models/w_flashbang.mdl");
    precache_model("models/p_flashbang.mdl");
    precache_sound("sounds/weapons/wpn_csflashbang/pinpull.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/bounce1.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/bounce2.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/explode1.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/explode2.wav");
    precache_sound("sounds/weapons/wpn_csflashbang/ringing.wav");
    precache_model("models/v_smokegrenade.mdl");
    precache_model("models/w_smokegrenade.mdl");
    precache_model("models/p_smokegrenade.mdl");
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

	// HL Glock — models now precached in the HL GUNS block above.
    precache_sound("sounds/weapons/wpn_hlglock/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlglock/fire.wav");
    precache_sound("sounds/weapons/wpn_hlglock/reload2.wav");

	// HL Egon — models now precached in the HL GUNS block above.
    precache_sound("sounds/weapons/wpn_hlegon/windup.wav");
    precache_sound("sounds/weapons/wpn_hlegon/off.wav");
    precache_sound("sounds/weapons/wpn_hlegon/run.wav");

	// CS Glock
    precache_model("models/w_glock18.mdl");
    // Viewmodel comes from the mounted cstrike gamedir (fs_addons.txt:16), not
    // from wpn_csglock/ — that copy is a flat IDPO frame bake with no sequence
    // names.  Same reason the crowbar uses models/v_crowbar.mdl from valve.
    precache_model("models/v_glock18.mdl");
    precache_sound("sounds/weapons/wpn_csglock/reload.wav");
    precache_sound("sounds/weapons/wpn_csglock/fire.wav");
    precache_sound("sounds/weapons/wpn_csglock/fireburst.wav");
    precache_sound("sounds/weapons/wpn_csglock/sliderelease.wav");
    precache_sound("sounds/weapons/wpn_csglock/slideback.wav");

	// CS g3sg1
    precache_model("models/w_g3sg1.mdl");
    // Viewmodel from the mounted cstrike gamedir — see the CS Glock note above.
    precache_model("models/v_g3sg1.mdl");
    precache_sound("sounds/weapons/wpn_csg3sg1/clipin.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/clipout.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/fire.wav");
    precache_sound("sounds/weapons/wpn_csg3sg1/slide.wav");

	// ---- The thirteen Counter-Strike 1.6 guns ------------------------------
	//
	// NOTHING HERE IS A MOD ASSET.  All three models and every sound resolve on
	// the mounted cstrike gamedir (fs_addons.txt:16), the same way the CS Glock
	// and G3SG1 above take their viewmodels from it.  They are precached HERE
	// rather than only inside each weapon_*() map-spawn function because a weapon
	// handed out by the give / buy / loadout path never runs its spawn function -
	// see the Opposing Force note further down for the invisible-weapon bug that
	// caused.
	// p228
	precache_model("models/v_p228.mdl");
	precache_model("models/w_p228.mdl");
	precache_model("models/p_p228.mdl");
	precache_sound("weapons/de_deploy.wav");
	precache_sound("weapons/p228-1.wav");
	precache_sound("weapons/p228_clipin.wav");
	precache_sound("weapons/p228_clipout.wav");
	precache_sound("weapons/p228_slidepull.wav");
	precache_sound("weapons/p228_sliderelease.wav");
	// fiveseven
	precache_model("models/v_fiveseven.mdl");
	precache_model("models/w_fiveseven.mdl");
	precache_model("models/p_fiveseven.mdl");
	precache_sound("weapons/fiveseven-1.wav");
	precache_sound("weapons/fiveseven_clipin.wav");
	precache_sound("weapons/fiveseven_clipout.wav");
	precache_sound("weapons/fiveseven_slidepull.wav");
	precache_sound("weapons/fiveseven_sliderelease.wav");
	// elite
	precache_model("models/v_elite.mdl");
	precache_model("models/w_elite.mdl");
	precache_model("models/p_elite.mdl");
	precache_sound("weapons/elite_clipout.wav");
	precache_sound("weapons/elite_deploy.wav");
	precache_sound("weapons/elite_fire.wav");
	precache_sound("weapons/elite_leftclipin.wav");
	precache_sound("weapons/elite_reloadstart.wav");
	precache_sound("weapons/elite_rightclipin.wav");
	precache_sound("weapons/elite_sliderelease.wav");
	// tmp
	precache_model("models/v_tmp.mdl");
	precache_model("models/w_tmp.mdl");
	precache_model("models/p_tmp.mdl");
	precache_sound("items/cliprelease1.wav");
	precache_sound("weapons/clipin1.wav");
	precache_sound("weapons/clipout1.wav");
	precache_sound("weapons/tmp-1.wav");
	// mac10
	precache_model("models/v_mac10.mdl");
	precache_model("models/w_mac10.mdl");
	precache_model("models/p_mac10.mdl");
	precache_sound("weapons/mac10-1.wav");
	precache_sound("weapons/mac10_boltpull.wav");
	precache_sound("weapons/mac10_clipin.wav");
	precache_sound("weapons/mac10_clipout.wav");
	// ump45
	precache_model("models/v_ump45.mdl");
	precache_model("models/w_ump45.mdl");
	precache_model("models/p_ump45.mdl");
	precache_sound("weapons/ump45-1.wav");
	precache_sound("weapons/ump45_boltslap.wav");
	precache_sound("weapons/ump45_clipin.wav");
	precache_sound("weapons/ump45_clipout.wav");
	// p90
	precache_model("models/v_p90.mdl");
	precache_model("models/w_p90.mdl");
	precache_model("models/p_p90.mdl");
	precache_sound("weapons/p90-1.wav");
	precache_sound("weapons/p90_boltpull.wav");
	precache_sound("weapons/p90_clipin.wav");
	precache_sound("weapons/p90_clipout.wav");
	precache_sound("weapons/p90_cliprelease.wav");
	// galil
	precache_model("models/v_galil.mdl");
	precache_model("models/w_galil.mdl");
	precache_model("models/p_galil.mdl");
	precache_sound("weapons/galil-1.wav");
	precache_sound("weapons/galil_boltpull.wav");
	precache_sound("weapons/galil_clipin.wav");
	precache_sound("weapons/galil_clipout.wav");
	// famas
	precache_model("models/v_famas.mdl");
	precache_model("models/w_famas.mdl");
	precache_model("models/p_famas.mdl");
	precache_sound("weapons/famas-1.wav");
	precache_sound("weapons/famas-burst.wav");
	precache_sound("weapons/famas_clipin.wav");
	precache_sound("weapons/famas_clipout.wav");
	precache_sound("weapons/famas_forearm.wav");
	// aug
	precache_model("models/v_aug.mdl");
	precache_model("models/w_aug.mdl");
	precache_model("models/p_aug.mdl");
	precache_sound("weapons/aug-1.wav");
	precache_sound("weapons/aug_boltpull.wav");
	precache_sound("weapons/aug_boltslap.wav");
	precache_sound("weapons/aug_clipin.wav");
	precache_sound("weapons/aug_clipout.wav");
	precache_sound("weapons/aug_forearm.wav");
	// sg552
	precache_model("models/v_sg552.mdl");
	precache_model("models/w_sg552.mdl");
	precache_model("models/p_sg552.mdl");
	precache_sound("weapons/sg552-1.wav");
	precache_sound("weapons/sg552_boltpull.wav");
	precache_sound("weapons/sg552_clipin.wav");
	precache_sound("weapons/sg552_clipout.wav");
	// sg550
	precache_model("models/v_sg550.mdl");
	precache_model("models/w_sg550.mdl");
	precache_model("models/p_sg550.mdl");
	precache_sound("weapons/sg550-1.wav");
	precache_sound("weapons/sg550_boltpull.wav");
	precache_sound("weapons/sg550_clipin.wav");
	precache_sound("weapons/sg550_clipout.wav");
	// xm1014
	precache_model("models/v_xm1014.mdl");
	precache_model("models/w_xm1014.mdl");
	precache_model("models/p_xm1014.mdl");
	precache_sound("weapons/m3_insertshell.wav");
	precache_sound("weapons/xm1014-1.wav");

	// ---- The twelve Day of Defeat weapons -----------------------------------
	//
	// NOTHING HERE IS A MOD ASSET either.  All three models and every sound
	// resolve on the mounted dod gamedir, and for the same reason as the CS
	// block above they are precached HERE rather than only inside each
	// weapon_*() spawn function: a weapon handed out by give / buy / loadout
	// never runs its spawn function, and an unprecached model is invisible.
	//
	// The six shared magazine and select sounds are listed ONCE, at the top,
	// rather than repeated per weapon -- eleven of the twelve draw from that set
	// and precache_sound is not free.
	precache_sound("weapons/rifleselect.wav");
	precache_sound("weapons/tommy_reload_clipin.wav");
	precache_sound("weapons/tommy_reload_clipout.wav");
	precache_sound("weapons/tommy_draw_slideback.wav");
	precache_sound("weapons/colt_reload_clipin.wav");
	precache_sound("weapons/colt_reload_clipout.wav");
	precache_sound("weapons/colt_draw_pullslide.wav");
	precache_sound("weapons/butt_hit.wav");
	// colt
	precache_model("models/v_colt.mdl");
	precache_model("models/w_colt.mdl");
	precache_model("models/p_colt.mdl");
	precache_sound("weapons/colt_shoot.wav");
	// luger
	precache_model("models/v_luger.mdl");
	precache_model("models/w_luger.mdl");
	precache_model("models/p_luger.mdl");
	precache_sound("weapons/luger_shoot.wav");
	// webley
	precache_model("models/v_webley.mdl");
	precache_model("models/w_webley.mdl");
	precache_model("models/p_webley.mdl");
	precache_sound("weapons/webley_shoot.wav");
	// garand
	precache_model("models/v_garand.mdl");
	precache_model("models/w_garand.mdl");
	precache_model("models/p_garand.mdl");
	precache_sound("weapons/garand_shoot.wav");
	precache_sound("weapons/garand_reload_clipin.wav");
	precache_sound("weapons/garand_reload_clipding.wav");
	// m1 carbine
	precache_model("models/v_m1carbine.mdl");
	precache_model("models/w_m1carb.mdl");
	precache_model("models/p_m1carb.mdl");
	precache_sound("weapons/carbine_shoot.wav");
	// gewehr 43
	precache_model("models/v_k43.mdl");
	precache_model("models/w_k43.mdl");
	precache_model("models/p_k43.mdl");
	precache_sound("weapons/k43_shoot.wav");
	// thompson
	precache_model("models/v_tommy.mdl");
	precache_model("models/w_tommy.mdl");
	precache_model("models/p_tommy.mdl");
	precache_sound("weapons/thompson_shoot.wav");
	// mp40
	precache_model("models/v_mp40.mdl");
	precache_model("models/w_mp40.mdl");
	precache_model("models/p_mp40.mdl");
	precache_sound("weapons/mp40_shoot.wav");
	// sten
	precache_model("models/v_sten.mdl");
	precache_model("models/w_sten.mdl");
	precache_model("models/p_sten.mdl");
	precache_sound("weapons/sten_shoot.wav");
	// m3 grease gun
	precache_model("models/v_greasegun.mdl");
	precache_model("models/w_greasegun.mdl");
	precache_model("models/p_grease.mdl");
	precache_sound("weapons/greasegun_shoot.wav");
	// stg44
	precache_model("models/v_mp44.mdl");
	precache_model("models/w_mp44.mdl");
	precache_model("models/p_stg44.mdl");
	precache_sound("weapons/mp44_shoot.wav");
	// bar
	precache_model("models/v_bar.mdl");
	precache_model("models/w_bar.mdl");
	precache_model("models/p_barbu.mdl");
	precache_sound("weapons/bar_shoot.wav");

	// ---- Day of Defeat, third batch ----------------------------------------
	// Every reload sound these need (rifleselect, the tommy_reload_* trio, the
	// bolt pair) is already precached above or in the second-batch block.
	// bren
	precache_model("models/v_bren.mdl");
	precache_model("models/w_bren.mdl");
	precache_model("models/p_bren.mdl");
	precache_sound("weapons/bren_shoot.wav");
	// fg42 and its scoped twin.  NOTE there is no w_scopedfg42.mdl in the mount
	// — the scoped rifle drops as a plain FG42 — but p_fg42s.mdl does exist.
	precache_model("models/v_fg42.mdl");
	precache_model("models/v_scopedfg42.mdl");
	precache_model("models/w_fg42.mdl");
	precache_model("models/p_fg42.mdl");
	precache_model("models/p_fg42s.mdl");
	precache_sound("weapons/fg42_shoot.wav");
	// m1a1 folding carbine
	precache_model("models/v_fcarb.mdl");
	precache_model("models/w_fcarb.mdl");
	precache_model("models/p_fcarb.mdl");
	precache_sound("weapons/carbine_shoot.wav");
	// lee-enfield no.4
	precache_model("models/v_enfield.mdl");
	precache_model("models/w_enfield.mdl");
	precache_model("models/p_enfield.mdl");
	precache_sound("weapons/enfield_shoot.wav");
	// mortar.  NOT "weapons/mortar.wav" — that name resolves to Half-Life's
	// 25 KB sample through the higher mounts and is already precached for
	// func_mortar_field.  DoD's own shot is mortar_shoot.wav.
	precache_model("models/v_mortar.mdl");
	precache_model("models/w_mortar.mdl");
	precache_model("models/p_mortar.mdl");
	precache_sound("weapons/mortar_shoot.wav");
	precache_sound("weapons/mortar_load.wav");
	// binoculars — VIEW MODEL ONLY.  dod ships no w_ or p_ for these; see the
	// header of sh_wpn_dodbinocs.qc for why that decides the whole weapon.
	precache_model("models/v_binoculars.mdl");

	// ---- Day of Defeat, second batch ---------------------------------------
	// Shared samples first, once each: the bolt pair the three snipers use, the
	// machine-gun belt set, and the three-part AT reload.  rifleselect.wav and
	// the tommy_reload_* pair are already precached with the first DoD batch.
	precache_sound("weapons/boltback.wav");
	precache_sound("weapons/boltforward.wav");
	precache_sound("weapons/chainpull.wav");
	precache_sound("weapons/clampdown.wav");
	precache_sound("weapons/bulletchain.wav");
	precache_sound("weapons/mgbolt.wav");
	precache_sound("weapons/bazookareloadgetrocket.wav");
	precache_sound("weapons/bazookareloadrocketin.wav");
	precache_sound("weapons/bazookareloadshovehome.wav");
	// The melee set — four weapons, one shared sample pool, which is DoD's own
	// arrangement and not an approximation (there are no per-weapon variants).
	precache_sound("weapons/knife_slash1.wav");
	precache_sound("weapons/knife_slash2.wav");
	precache_sound("weapons/knife_hit1.wav");
	precache_sound("weapons/knife_hit2.wav");
	precache_sound("weapons/knife_hit3.wav");
	precache_sound("weapons/knife_hit4.wav");
	precache_sound("weapons/knife_hitwall1.wav");
	// scoped k98 — NOTE the fire sample is the mod's own: dod ships no k98 shot.
	precache_model("models/v_scoped98k.mdl");
	precache_model("models/w_scoped98k.mdl");
	precache_model("models/p_k98s.mdl");
	// springfield
	precache_model("models/v_spring.mdl");
	precache_model("models/w_spring.mdl");
	precache_model("models/p_spring.mdl");
	precache_sound("weapons/spring_shoot.wav");
	// scoped enfield
	precache_model("models/v_enfield_scoped.mdl");
	precache_model("models/w_enfield_scoped.mdl");
	precache_model("models/p_enfields.mdl");
	precache_sound("weapons/enfieldsniper_shoot.wav");
	// .30 cal
	precache_model("models/v_30cal.mdl");
	precache_model("models/w_30cal.mdl");
	precache_model("models/p_30cal.mdl");
	precache_sound("weapons/30cal_shoot.wav");
	// mg34
	precache_model("models/v_mg34.mdl");
	precache_model("models/w_mg34.mdl");
	precache_model("models/p_mg34bu.mdl");
	precache_sound("weapons/mg34_shoot.wav");
	// mg42
	precache_model("models/v_mg42.mdl");
	precache_model("models/w_mg42.mdl");
	precache_model("models/p_mg42bu.mdl");
	precache_sound("weapons/mg42_shoot.wav");
	// bazooka — the rocket mesh too, or the projectile setmodel finds nothing
	precache_model("models/v_bazooka.mdl");
	precache_model("models/w_bazooka.mdl");
	precache_model("models/p_bazooka.mdl");
	precache_model("models/w_bazooka_rocket.mdl");
	// NOT "weapons/rocket1.wav" — that name resolves to Half-Life's looping RPG
	// flight sample through the higher mounts.  See SH_DodATFireSound.
	precache_sound("sounds/weapons/wpn_dodat/bazooka_fire.wav");
	// panzerschreck — world model is w_pschreck, NOT w_panzerschreck
	precache_model("models/v_panzerschreck.mdl");
	precache_model("models/w_pschreck.mdl");
	precache_model("models/p_pschreck.mdl");
	precache_model("models/w_pschreck_rocket.mdl");
	precache_sound("weapons/rocket2.wav");
	// piat
	precache_model("models/v_piat.mdl");
	precache_model("models/w_piat.mdl");
	precache_model("models/p_piat.mdl");
	precache_model("models/w_piat_rocket.mdl");
	precache_sound("weapons/piat_shoot.wav");
	// melee — w_fairbairn.mdl DOES NOT EXIST in dod/models, so the commando
	// knife borrows the US knife's world model (see sh_wpn_dodmelee.qc).
	precache_model("models/v_amerk.mdl");
	precache_model("models/w_amerk.mdl");
	precache_model("models/p_amerk.mdl");
	precache_model("models/v_fairbairn.mdl");
	precache_model("models/p_fairbairn.mdl");
	precache_model("models/v_paraknife.mdl");
	precache_model("models/w_paraknife.mdl");
	precache_model("models/p_paraknife.mdl");
	precache_model("models/v_spade.mdl");
	precache_model("models/w_spade.mdl");
	precache_model("models/p_spade.mdl");
	// grenades — the w_ meshes double as the thrown projectile, so a missing
	// precache here shows up as an invisible grenade rather than a missing icon
	precache_model("models/v_mills.mdl");
	precache_model("models/w_mills.mdl");
	precache_model("models/p_mills.mdl");
	precache_model("models/v_stick.mdl");
	precache_model("models/w_stick.mdl");
	precache_model("models/p_stick.mdl");
	precache_sound("weapons/explode3.wav");
	precache_sound("weapons/explode4.wav");
	precache_sound("weapons/explode5.wav");
	precache_sound("weapons/grenade_hit1.wav");
	precache_sound("weapons/grenade_hit2.wav");
	precache_sound("weapons/grenade_hit3.wav");

	// ---- Opposing Force weapons: MODELS ------------------------------------
	//
	// The same reasoning that put the sounds here applies to the models, and it
	// was missed when these four weapons were added.  Their precache_model calls
	// lived ONLY inside their weapon_*() map-spawn functions, so a weapon handed
	// out by the give / buy / loadout path was never precached at all:
	//
	//     gave Displacer
	//     WARNING: SV_ModelIndex: model models/w_displacer.mdl not precached
	//
	// An unprecached setmodel() yields modelindex 0, and the engine drops any
	// entity with a null model before it reaches the scene (pr_csqc.c
	// CopyCSQCEdictToEntity) -- so this is an invisible-weapon bug, not just a
	// log warning.  sprites/exit1.spr is the displacer's own projectile, which
	// is exactly why its orb could never be seen.
	//
	// All of these resolve through the mounted gearbox searchpath.
    precache_model("models/v_shock.mdl");
    precache_model("models/w_shock.mdl");
    precache_model("models/p_shock.mdl");
    precache_model("sprites/muzzle_shock.spr");  // the bolt it fires
    precache_model("models/v_displacer.mdl");
    precache_model("models/w_displacer.mdl");
    precache_model("models/p_displacer.mdl");
    precache_model("sprites/exit1.spr");
    precache_model("models/v_bgrap.mdl");
    precache_model("models/w_bgrap.mdl");
    precache_model("models/p_bgrap.mdl");
    // The tongue's own texture, drawn as a ribbon by cl_rope.qc.  Must be
    // precached even though nothing setmodel()s it: the client resolves it with
    // getmodelindex + spriteframe, which only find a model the engine already
    // loaded.  Without this the grapple silently falls back to the generic rope,
    // which is the state it shipped in.
    precache_model("sprites/tongue.spr");
	// The pizza_ya_san2 jetpack.  A previous note here said these "are not
	// present in ANY mounted searchpath here, so listing them would only add
	// three load warnings to every map" and left them to weapon_jetpack()'s own
	// spawn function.  THAT WAS WRONG, and the logs said so: all three sit in
	// svencoop_downloads/models/pizza_ya_san/ beside the shorty and SOFLAM models
	// this same file already precaches a few lines up, and the deferral produced
	// a recurring `SV_ModelIndex: model models/pizza_ya_san/w_glock18jet.mdl not
	// precached` — because the jetpack is buyable and F5-givable on ANY map,
	// not only the one that ships it.
	precache_model("models/pizza_ya_san/v_glock18jet.mdl");
	precache_model("models/pizza_ya_san/w_glock18jet.mdl");
	precache_model("models/pizza_ya_san/p_glock18jet.mdl");

	// Opposing Force shock rifle.  The FIRE sound has to be here rather than in
	// the weapon's own spawn function: the client predicts its own shot and
	// plays it locally, and a CSQC-side sound() on something only the server
	// precached is a load warning and a silent trigger.
    precache_sound("weapons/shock_fire.wav");
    precache_sound("weapons/shock_draw.wav");
    precache_sound("weapons/shock_recharge.wav");

	// Opposing Force displacer.
    precache_sound("weapons/displacer_fire.wav");
    precache_sound("weapons/displacer_impact.wav");
    precache_sound("weapons/displacer_spin.wav");
    precache_sound("weapons/displacer_spin2.wav");
    precache_sound("weapons/displacer_start.wav");
    precache_sound("weapons/displacer_teleport.wav");
    precache_sound("weapons/displacer_teleport_player.wav");

	// pizza_ya_san2's jetpack.
    precache_sound("weapons/hks1.wav");
    precache_sound("items/clipinsert1.wav");
    precache_sound("weapons/357_cock1.wav");
    precache_sound("ambience/steamburst1.wav");

	// Opposing Force barnacle grapple.
    precache_sound("weapons/bgrapple_fire.wav");
    precache_sound("weapons/bgrapple_release.wav");
    precache_sound("weapons/bgrapple_cough.wav");
    precache_sound("weapons/bgrapple_impact.wav");

	// HL Gauss — models now precached in the HL GUNS block above.
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

	// HL Crossbow — v_/w_ now precached in the HL GUNS block above.  The BOLT
	// stays local on purpose (sh_wpn_hlcrossbow.qc:23): valve ships
	// crossbow_bolt.mdl, but swapping it needs the SSQC spawn, the CSQC
	// replicated projectile and Projectile_ModelForType to move together plus a
	// size check in-game, so it was left consistent rather than half-moved.
    precache_model("models/weapons/wpn_hlcrossbow/bolt.mdl");
    precache_model("models/weapons/crossbowclip.mdl");
    precache_sound("sounds/weapons/wpn_hlcrossbow/fire.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/fly.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hit1.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hit2.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hitbody1.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/hitbody2.wav");
    precache_sound("sounds/weapons/wpn_hlcrossbow/reload.wav");

	// HL 357 — models now precached in the HL GUNS block above.
    precache_sound("sounds/weapons/wpn_hl357/cock.wav");
    precache_sound("sounds/weapons/wpn_hl357/reload.wav");
    precache_sound("sounds/weapons/wpn_hl357/fire1.wav");
    precache_sound("sounds/weapons/wpn_hl357/fire2.wav");

	// DOD 98k — mount assets since 2026-08-30 (it was the last DoD weapon
	// shipping mod-local copies; see the header of sh_wpn_dod98k.qc).  The
	// bolt / clipin / rifleselect / knife_* samples are precached with the
	// rest of the DoD set elsewhere in this file; kar_shoot is this rifle's
	// own and both K98 variants use it.
    precache_model("models/w_98k.mdl");
    precache_model("models/v_98k.mdl");
    precache_sound("weapons/kar_shoot.wav");

	// CS Scout
    precache_model("models/w_scout.mdl");
    // Mounted cstrike viewmodel — the bundled wpn_csscout/ IDPO re-bake is gone.
    precache_model("models/v_scout.mdl");
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
    precache_model("models/w_m249.mdl");
    // Mounted cstrike viewmodel — the bundled wpn_csm249/ IDPO re-bake is gone.
    precache_model("models/v_m249.mdl");
    precache_sound("sounds/weapons/wpn_csm249/boxin.wav");
    precache_sound("sounds/weapons/wpn_csm249/boxout.wav");
    precache_sound("sounds/weapons/wpn_csm249/chain.wav");
    precache_sound("sounds/weapons/wpn_csm249/coverdown.wav");
    precache_sound("sounds/weapons/wpn_csm249/coverup.wav");
    precache_sound("sounds/weapons/wpn_csm249/fire1.wav");
    precache_sound("sounds/weapons/wpn_csm249/fire2.wav");

	// HL Crowbar — models now precached in the HL GUNS block above.
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitwall1.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitwall2.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/miss.wav");
    // The flesh set.  All three have shipped in quakers/sounds since the crowbar
    // was added and nothing played them: every hit, on a wall or on a zombie,
    // used hitwall1/2.  Half-Life splits the two on Classify() - see
    // W_MeleeHitIsBody in sv_weapons.qc.
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitbody1.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitbody2.wav");
    precache_sound("sounds/weapons/wpn_hlcrowbar/hitbody3.wav");

	// HL Shotgun — models now precached in the HL GUNS block above.
    precache_sound("sounds/weapons/wpn_hlshotgun/fire1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/fire2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/cock.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/reload3.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell1.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell2.wav");
    precache_sound("sounds/weapons/wpn_hlshotgun/shell3.wav");

	// CS tactical shield.  All eleven files come out of the cstrike mount; the
	// nine combined {v,p}_shield_<x> pairs are the complete list Counter-Strike
	// ships, and they are what defines which weapons the shield can be carried
	// with (SH_ShieldSuffix in shared/weapons/sh_wpn_csshield.qc).
	precache_model("models/w_shield.mdl");
	precache_model("models/p_shield.mdl");
	precache_model("models/v_shield_r.mdl");
	precache_model("models/shield/v_shield_usp.mdl");
	precache_model("models/shield/p_shield_usp.mdl");
	precache_model("models/shield/v_shield_glock18.mdl");
	precache_model("models/shield/p_shield_glock18.mdl");
	precache_model("models/shield/v_shield_deagle.mdl");
	precache_model("models/shield/p_shield_deagle.mdl");
	precache_model("models/shield/v_shield_p228.mdl");
	precache_model("models/shield/p_shield_p228.mdl");
	precache_model("models/shield/v_shield_fiveseven.mdl");
	precache_model("models/shield/p_shield_fiveseven.mdl");
	precache_model("models/shield/v_shield_knife.mdl");
	precache_model("models/shield/p_shield_knife.mdl");
	precache_model("models/shield/v_shield_hegrenade.mdl");
	precache_model("models/shield/p_shield_hegrenade.mdl");
	precache_model("models/shield/v_shield_flashbang.mdl");
	precache_model("models/shield/p_shield_flashbang.mdl");
	precache_model("models/shield/v_shield_smokegrenade.mdl");
	precache_model("models/shield/p_shield_smokegrenade.mdl");
	precache_sound("weapons/ric2.wav");

	// CS body armour — armoury_entity item 16 (kevlar) and 17 (assaultsuit).
	// These were the only two of the nineteen armoury indices with no entry
	// here.  item_kevlar / item_assaultsuit (server/sv_cs_entities.qc:89-99)
	// reach GoldSrc_SpawnPickup, which does precache at spawn time
	// (sv_goldsrc_pickups.qc), so this is belt-and-braces rather than a fix for
	// a live failure — but every other armoury model is precached up front and
	// a spawn-time precache is a thinner safety net than it looks on a map that
	// spawns one late.
    precache_model("models/w_kevlar.mdl");
    precache_model("models/w_assault.mdl");

	// CS M3
    // World model now comes from the cstrike mount — see M3_WORLDMODEL in
    // shared/weapons/sh_wpn_csm3.qc.  The view model stays mod-local.
    precache_model("models/w_m3.mdl");
    // Mounted cstrike viewmodel — the bundled wpn_csm3/ IDPO re-bake is gone.
    precache_model("models/v_m3.mdl");
    precache_sound("sounds/weapons/wpn_csm3/fire.wav");
    precache_sound("sounds/weapons/wpn_csm3/insertshell.wav");
    precache_sound("sounds/weapons/wpn_csm3/pump.wav");

	// CS MP5
    precache_model("models/w_mp5.mdl");
    // Mounted cstrike viewmodel — the bundled wpn_csmp5/ IDPO re-bake is gone.
    precache_model("models/v_mp5.mdl");
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
	precache_model("models/w_awp.mdl");
    // Mounted cstrike viewmodel — the bundled wpn_csawp/ IDPO re-bake is gone.
    precache_model("models/v_awp.mdl");
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
	// Moved to the MOUNTED cstrike viewmodel (see sh_wpn_csdeagle.qc's header) —
	// the bundled IDPO re-bake under models/weapons/wpn_csdeagle/ is no longer
	// loaded.  The sounds below still ship with the mod and are still ours.
	precache_model("models/v_deagle.mdl");
	precache_model("models/w_deagle.mdl");
	precache_sound("sounds/weapons/wpn_csdeagle/deploy.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/fire1.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/fire2.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/clipin.wav");
	precache_sound("sounds/weapons/wpn_csdeagle/clipout.wav");

	// CS Knife
	precache_model("models/weapons/wpn_csknife/v_knife.mdl");
	precache_model("models/w_knife.mdl");
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
	precache_model("models/v_usp.mdl");
	precache_model("models/w_usp.mdl");
	precache_model("models/p_usp.mdl");
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

	// CS AK47.  v_/w_/p_ all come from the mounted cstrike gamedir now — the
	// bundled models/weapons/wpn_csak47/v_ak47.mdl was an IDPO re-bake that made
	// the AK read as the HD pack rather than stock CS.  Sounds stay on the mod's
	// own (identical) copies, so only the model line moved.
	precache_model("models/v_ak47.mdl");
	precache_model("models/w_ak47.mdl");
	precache_sound("sounds/weapons/wpn_csak47/fire1.wav");
	precache_sound("sounds/weapons/wpn_csak47/fire2.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipin.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipout.wav");
	precache_sound("sounds/weapons/wpn_csak47/boltpull.wav");
	// HD AK47 — shares wpn_csak47 sounds, only new model files.
	precache_model("models/weapons/wpn_hdak47/v_ak47.mdl");
	precache_model("models/weapons/wpn_hdak47/w_ak47.mdl");

	// CS M4a1
	// Mounted cstrike viewmodel.  ONE file now, not two: the stock model carries
	// the silenced set at sequences 0-6 and the unsilenced set at 7-13, so the
	// silencer toggle swaps sequence rather than model.
	precache_model("models/v_m4a1.mdl");
	precache_model("models/w_m4a1.mdl");
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

// ============================================================================
//  PM_ContentsAt — point contents that can SEE BRUSH-ENTITY WATER
// ============================================================================
//
//  pointcontents() consults the WORLDMODEL ONLY.  GoldSrc maps routinely put
//  their pools in func_water brush entities rather than in baked world water
//  (both of de_rats' pools are func_water, and Sven maps do the same), and
//  those are completely invisible to it.  That single blind spot is why a
//  player could stand on the bottom of de_rats' sink without ever swimming,
//  and why a func_pushable dropped into that sink sank instead of floating.
//
//  pointcontentsmask(pos, 0) does the same query but ALSO walks linked brush
//  entities and honours FTE's negative-.skin contents override — which is
//  exactly what func_water sets (skin -3 water / -4 slime / -5 lava).  The
//  result is a CONTENTBIT_* mask, so it is folded back into the Q1 CONTENT_*
//  the movement code speaks, in the SAME priority order the engine's own
//  PF_pointcontents uses (solid > sky > lava > slime > water > ladder).  That
//  makes this a strict superset of pointcontents(): every answer it used to
//  give is unchanged, and brush volumes now answer too.
//
//  Requires the brush to be SOLID_BSP — World_ContentsOfLinks skips SOLID_NOT
//  outright (engine world.c), and an unlinked entity is not reachable at all.
//  See server/sv_water.qc for why that costs func_water nothing: a trace's
//  contents mask never includes water, so a skin<0 brush still cannot block
//  anyone.
__uint(vector pos, optional float worldonly) pointcontentsmask = #0:pointcontentsmask;

float(vector pos) PM_ContentsAt =
{
	int m = pointcontentsmask(pos, 0);
	if (m & CONTENTBIT_SOLID)  return CONTENT_SOLID;
	if (m & CONTENTBIT_SKY)    return CONTENT_SKY;
	if (m & CONTENTBIT_LAVA)   return CONTENT_LAVA;
	if (m & CONTENTBIT_SLIME)  return CONTENT_SLIME;
	if (m & CONTENTBIT_WATER)  return CONTENT_WATER;
	// FTELADDER is the engine's own spelling of the bit CONTENT_LADDER maps to
	// (FTECONTENTS_LADDER 0x4000, bspfile.h:526).
	if (m & CONTENTBIT_FTELADDER) return CONTENT_LADDER;
	return CONTENT_EMPTY;
};
