//Various globals that are used in this FTEQW example are defined here, they are not used by the engine itself

//#pragma warning disable Q302
#pragma target fte_5768

.vector view_ofs;    /* eye position relative to entity origin */
.vector movedir;     /* push direction for trigger_push */
.float  spawnflags;  /* trigger/entity spawn flags (not in CSQC defs) */

// .weapon / .weaponframe moved to shared/sh_customdefs.qc so shared
// files compiled before this one (sh_weapons.qc) can reference them.
// attack_finished moved to shared/sh_weapons.qc

// nettest death ragdoll: the corpse proxy predraw (cl_player.qc) spawns the ragdoll, but the
// implementation lives in cl_ragdoll.qc which compiles AFTER cl_player.qc — forward-declare it here.
entity(entity corpse, vector shotdir) CSQC_SpawnCorpseRagdoll;

vector cursor_pos; /* Current mouse cursor position, updated in csqc_inputevent */
float g_width, g_height; /* Globals for screen width and height */

// Set by CSQC_PredictPickupWeapon when it plays the pickup sound
// locally.  The server's pickup-sound event handler reads this latch
// and only plays when WE are the excluded picker AND predict didn't
// already fire — robust against event/update processing order within
// a single snapshot.  Previous design (latch in event, gate in
// entity update) silently dropped the sound whenever the event
// happened to arrive AFTER the entity update in the same packet.
float cl_local_predict_sound_time;

//Menu stuff
float in_menu; //what menu are we in
float time_in_menu;

// for keybinding
float active_bind_index;
float menu_click_held;

const float MENU_NONE = 0;
const float MENU_MAIN = 1;
const float MENU_JOIN = 2;
const float MENU_SETTINGS = 4;
const float MENU_BUY = 8;
const float MENU_HOST = 16;
const float MENU_PREGAME = 32;
const float MENU_POSTGAME = 64;

float in_input_box;
float input_cursor;

vector campos;
vector camang;

float hud_font;
float hud_font_regular;
float hud_font_mono;     // monospace for scrolling numeric strips (debug graphs)

// Dynamic-light re-issue gate — sampled once per render frame in
// CSQC_DlightGate_Tick (cl_main.qc) from cl_dlight_update_hz.
// Per-frame-mutable dlight callsites (muzzle flash, bullet impact,
// explosion) read this and skip their dynamiclight_add when 0 so the
// engine's lightmap-hack path doesn't pay MarkLights / rebuild cost
// for that dlight on the skipped frame.  Defaults to 1 so behaviour
// is unchanged before the first tick fires.
var float csqc_dlight_update_this_frame = 1;

// Forward decl — defined in cl_main.qc but called from spawn-side
// helpers earlier in the compile order (CSQC_MuzzleFlash,
// CSQC_AddImpactLight, CSQC_AddExplosionLight).  Forces the current
// render frame's gate to "yes" and rebases the cap interval to now
// so the peak (frac == 1.0) frame of a freshly-spawned dlight is
// always drawn even when cl_dlight_update_hz would otherwise have
// skipped this frame.
void() CSQC_DlightGate_ForceUpdate;

// Spectator freecam input (captured in cl_player.qc, used in cl_spectate.qc)
float spec_freecam_fwd;
float spec_freecam_side;

entity localplayer;
entity predicted_player;

// Declared here so any file compiled after cl_customdefs.qc can read
// them (cl_cameras.qc's sniper sway needs them, and they're still
// *written* from cl_player.qc).
float csqc_prediction_valid;    // TRUE once predicted_player can drive view
float csqc_live_buttons;        // live button bits captured by +cmd aliases

// Freshest local presentation eye, computed in CSQC_BuildPresentationView
// (cl_player.qc) and consumed by the render camera (cl_main.qc).  Declared
// here so cl_physprop.qc (compiled before cl_player.qc) can read them to
// predict the carried prop's hold point from the local view.
vector csqc_present_origin;
vector csqc_present_view_ofs;
float  csqc_present_valid;

// Pending yaw delta sent privately by func_door_rotating while it carries
// us.  CSQC_Input_Frame folds it into input_angles_y once and zeroes it,
// so the local view follows the door without disturbing pitch/roll.
float csqc_door_yaw_offset;

// Shared CSQC weapon-prediction bookkeeping.
float csqc_pred_sequence;
float csqc_weapon_pending_ack_sequence;

// Persistent CSQC viewmodel entity — driven by predicted_player
entity csqc_viewmodel_ent;

// Sequence-driven viewmodels normally use time since weapon-state start.
// Multi-part reloads can override this per draw so a later sequence begins
// at local sequence time 0 instead of inheriting the full reload elapsed.
float csqc_viewmodel_sequence_time_override;
float csqc_viewmodel_sequence_time;

// Current "logical time" for weapon prediction.
// Set to cltime for live prediction, pred_cmd_timestamp[slot] for replay.
float csqc_pred_time;

// Time the last predicted local weapon sound was played, used to suppress
// the delayed server-side echo in CSQC_Event_Sound.
float csqc_last_predicted_weapon_sound_time;
float csqc_last_predicted_auto_sound_time;

// FTE CSQC time globals not present in the stock cl_defs.qc. serverprevtime
// ticks forward only when a new server snapshot is received, making it the
// canonical snapshot-arrival trigger (independent of the cltime-vs-time
// epoch offset that breaks naive `cltime - time` dt calculations).
// clframetime is real-time frame delta (for fps measurement in the net_graph).
float serverprevtime;
float clframetime;

// Forward-declared here so shared/sh_weapon_logic.qc (which compiles
// before client/cl_player.qc) can read it in CSQC_SendHitclaim. The
// actual use site is CSQC_PlayerVisual_Update; see cl_player.qc for the
// full set of vis_* fields.
.float vis_owner_entnum;
// Player body paint (client/cl_paint.qc, compiled AFTER cl_player.qc):
// returns the 'replace "surf" "shader"' lines for a proxy's setcustomskin
// call — cl_player.qc's PlayerVis_ApplySkin appends them to its geomset
// lines.  Prototypes here so earlier files can call the later one.
string(entity proxy) Paint_SkinLines;
void() Paint_RendererRestarted;   // re-upload paint textures after vid_restart (cl_infodecal.qc hook)
// Networked aim yaw + pitch (never modified by the predraw — unlike .angles_y, which
// the predraw rotates by leg_twist).  Declared early so the remote-tracer event parse
// (cl_bulletimpact.qc, compiled before cl_player.qc) can read them for the per-weapon
// muzzle basis; cl_player.qc re-declares them harmlessly (same pattern as vis_owner_entnum).
.float vis_aim_yaw;
.float vis_pitch;

// --- Full OBB hitbox detection ---
// The bullet ray is traced against the SAME 20 per-bone oriented boxes that
// cl_debug_hitboxes / sv_debug_hitboxes draw, so what you shoot matches what you
// see and the hitgroup is the box you hit (not a Z-height guess).  The table +
// CSQC_TraceHitboxes implementation live in cl_debuginfo.qc (after the table);
// these forward decls + result globals let CSQC_PredictedImpact / W_HitgroupClassify
// in sh_weapon_logic.qc (compiled earlier) drive it.  Results from the last trace:
float  csqc_obb_hit;     // TRUE if a box was hit
entity csqc_obb_ent;     // the proxy whose box was hit
vector csqc_obb_pos;     // world hit point
float  csqc_obb_frac;    // parametric [0..1] distance of the hit along src..end
float  csqc_obb_group;   // HITGROUP_* of the box that was hit
void(vector src, vector end, float limit_frac) CSQC_TraceHitboxes;
void() CSQC_PlayersUnsolid;
void() CSQC_PlayersResolid;

// Forward-declared for the same reason — CSQC_SendHitclaim writes
// these to predict the flinch reaction on the target proxy.  Real
// declarations and the predraw application live in cl_player.qc.
.float vis_flinch_until;
.float vis_flinch_hitgroup;

// Forward-declared so cl_player.qc's CSQC_PlayerVisual_Predraw can gate
// own-body visibility on the death-cam window. Defined in cl_spectate.qc,
// which is compiled after cl_player.qc.
float() Spectate_InDeathCam;

// Entity smoothing / error compensation (CSQC_SmoothSetOrigin in
// cl_player.qc). Declared here so the helper — which appears earlier
// in cl_player.qc than the other vis_* field block — can see them.
.vector extrap_error_offset;
.float  extrap_error_cltime;
// Fade duration chosen at offset-capture time.  Held with the offset so
// the helper applying the decaying offset reads the SAME value the
// reconcile site computed — without storing it, the two sites would
// have to recompute from velocity each frame and drift.  Used only by
// cl_driftlock's reconcile-error fade; the remote-proxy and
// toss-smooth helpers fall back to cl_extrap_smooth_time directly.
.float  extrap_error_smooth_time;

// Toss-smoothing fields (cl_tosssmooth.qc). Stash the latest server
// {origin, velocity, sample-time} and per-entity gravity factor so the
// per-frame predraw can extrapolate forward and apply the decaying
// extrap_error_offset on top. Used by dropped weapons + server
// projectiles. General entity fields, intentionally not gated.
.vector toss_last_origin;
.vector toss_last_velocity;
.float  toss_last_cltime;
.float  toss_gravity;          // 0 = no gravity (rocket); 0.5 = grenade; 1 = full
.float  toss_moving;           // cached velocity state for predraw smoothing

// Per-entity brightness-cap cache for CSQC_MaxlightScale_Cached
// (cl_teamtint.qc), used by the dropped-weapon predraw. A settled drop
// never moves, so its getlight() lightmap sample is identical every
// frame — store the resulting scalar and re-sample only when the origin
// moves (>1qu) or the cap/knee cvars change. Removes the per-frame
// getlight() on 200+ sleeping drops (the CSQC_MaxlightScale cost seen in
// the profiler). General entity fields; only drops currently use them.
.float  maxlight_cache_scale;
.vector maxlight_cache_origin;
.float  maxlight_cache_cap;
.float  maxlight_cache_knee;
// Settle latch: once a still drop's colormod has been written for the current
// (origin, cap, knee) it persists on the edict, so re-writing it every frame is
// redundant.  Set after the colormod write; the latch elides both the
// CSQC_MaxlightScale_Cached call and the colormod store while the keys match.
.float  maxlight_cache_committed;

// Forward — defined in cl_player.qc, dispatched from cl_main.qc's
// CSQC_ConsoleCommand. Both files compile after cl_customdefs.qc.
void() CSQC_DumpPlayerBones;

// Drift-trace ring buffer (cl_player.qc). Used by cl_weapons.qc which
// compiles earlier than cl_player.qc.
void() CL_Drift_Dump;

// Nav/bot debug overlay CSQC entity handler — defined in cl_navdebug.qc (compiles
// after cl_player.qc), dispatched from CSQC_Ent_Update in cl_player.qc.
void() NavDebug_EntUpdate;

vector() readvector =
{
	vector r = '0 0 0';
	r_x = readcoord();
	r_y = readcoord();
	r_z = readcoord();
	return r;
};

// Forward decls for CoD scope (cl_codscope.qc) — referenced from
// cl_cameras.qc's sniper-sway helper which compiles BEFORE
// cl_codscope.qc in cl_progs.src.
float() CSQC_CodScope_IsScoped;
float() CSQC_CodScope_IsActive;
vector() CSQC_CodScope_BreathingSway;
vector() CSQC_CodScope_GetTraceBias;
float csqc_codscope_holdbreath_env;
float csqc_codscope_fire_blocks_ads;
float csqc_codscope_sway_pitch;
float csqc_codscope_sway_yaw;
float() CSQC_CodScope_HidesViewmodel;
