//shared definitions
#pragma target fte_5768
#define printf(x, ...) print(sprintf(x, __VA_ARGS__))

const float FL_DUCKING = 8192;
const float PM_CSQC_PROXY_VERSION = 12;  // bump on wire-layout change
const string PM_CSQC_PROXY_CLASSNAME = "pm_csqc_proxy";

// PM_CSQC_PROXY SendFlags section bits — each section is gated separately
// so ticks where only one section changed don't drag the other ~100 B along.
const float PM_SF_MOVEMENT     = 1;  // origin, velocity, view_ofs, flags, pm_* timers, spread
const float PM_SF_WEAPON_STATE = 2;  // slots, weapon, weaponstate, attack_finished, anim, zoomstage
const float PM_SF_AMMO         = 4;  // all mag_*/ammo_*/silencer bytes

// CSQC entity type IDs (first byte sent by SendEntity)
const float CSQC_ENT_PUSH_TRIGGER = 2;
const float CSQC_ENT_SOLID_BRUSH    = 5;
const float CSQC_ENT_DROPPED_WEAPON = 7;
const float CSQC_ENT_PLAYER_VISUAL  = 8;

// trigger_push spawnflags
const float PUSH_ONCE     = 1;  // remove after first touch
const float PUSH_SILENT   = 2;  // no wind sound
const float PUSH_ADDITIVE = 4;  // add to velocity rather than replace
const float PUSH_TUNNEL   = 8;  // pull toward trigger centerline while pushing
const float PUSH_SOURCE   = 16; // boost along movedir up to speed, don't overwrite sideways

// Linked list fields for trigger chains
.entity push_next;
.entity tele_next;
.entity ladder_next;

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

// Lag-compensation pose stash (see server/sv_lagcomp.qc). Saved before a
// rewound trace so Lagcomp_RestorePlayer can put the true pose back.
.float  lc_stashed;
.float  lc_stash_frame, lc_stash_frame1time, lc_stash_frame2, lc_stash_frame2time, lc_stash_lerpfrac;
.float  lc_stash_baseframe, lc_stash_baseframe1time, lc_stash_baseframe2, lc_stash_baseframe2time, lc_stash_baselerpfrac;
.float  lc_stash_subblendfrac, lc_stash_subblend2frac, lc_stash_basesubblendfrac, lc_stash_basesubblend2frac;
.float  lc_stash_bonecontrol1, lc_stash_bonecontrol2, lc_stash_bonecontrol3, lc_stash_bonecontrol4;
.float  lc_stash_basebone;

// Forward declaration so shared weapon code (compiled before sv_lagcomp.qc)
// can call it. Definition lives in server/sv_lagcomp.qc.
void(vector src, vector end, float moveflags, entity ignore) Lagcomp_TraceLine;

// Team-select camera system — definitions in server/sv_cameras.qc.
// Forward-declared so sv_player.qc can route team-selecting players
// (and sv_main.qc can drive the per-tick cycle).
float(entity p) Camera_PlacePlayerAtCurrent;   // returns 1 if placed, 0 if no cameras exist
void() Camera_UpdateCyclingSpectators;
void() Camera_EnsureTargetsResolved;

// Per-player camera phase (set via `cmd cam_phase <N>` from menu stuffcmd).
// Selects which flagged cameras to cycle when the player is in team-select.
.float cam_phase;
.float cam_last_dbg_time;   // rate-limit for sv_debug_camera bprints

// Latched by RoundRestart before clearing .is_dead — TRUE if the player was
// alive at round end.  PlayerSpawn consumes this flag to decide whether to
// preserve the player's inventory (slot_* + mag_*/ammo_*) or apply the
// default starting loadout from sv_default_* cvars.
.float survived_round;

// Forward decl — defined in server/sv_player.qc — so sv_cameras.qc can
// push the proxy origin while the player is still in team-select (where
// PlayerPreThink returns early and doesn't call this itself).
void(entity player) PM_SyncPredictionProxy;
#endif
.float spread_penalty;       // decaying spread penalty from jump/landing (0 = none)
.float fire_spread_penalty;  // decaying spread penalty from sustained fire (0 = none)
.float fire_spread_pending;  // pending penalty to apply AFTER current shot resolves
.float altfire_finished;     // separate cooldown for alt-fire (doesn't block primary)

#ifdef CSQC
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

// Visual proxy death flag, set in CSQC_PlayerVisual_Update from server's
// owner.is_dead byte. Declared here (rather than in cl_player.qc) so
// shared/sh_pmove.qc — which compiles earlier — can reference it from
// PM_IsLivePlayerCollider.
.float vis_is_dead;

// Forward decl — defined in client/cl_cameras.qc.
entity(float required_flag) CSQC_GetPreviewCamera;

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
.float  dropped_weapon_logged;            // debug: set after confirm/catchup printed,
                                          // cleared on transition back to visible,
                                          // prevents repeated prints from the server's
                                          // per-0.2s SendFlags pulses while hidden.

// Earliest cltime the fake drop is eligible to be predict-picked.
// Mirrors the server's weapon_become_solid gate: drop_ent starts as
// SOLID_NOT and only flips to SOLID_TRIGGER after 0.7s, so the
// dropper can't instantly re-grab their own toss.  Real networked
// entities arrive past this gate (SendEntity is wired inside
// weapon_become_solid itself), so they leave this field at 0.
.float dropped_weapon_pickup_time;

// CSQC fake-drop visuals — tossed-weapon entity rendered locally for the
// dropper during the 0.7s window before weapon_become_solid wires the
// networked SendEntity.  Now a linked list (previously a single global)
// so a death-drop burst of up to four weapons can coexist.  Each ent
// self-expires via cltime vs csqc_fake_drop_expire_time.
entity csqc_fake_drop_list;
.entity csqc_fake_drop_next;
.float  csqc_fake_drop_expire_time;

// Parallel to SSQC's weapon_settle_deadline (declared in sv_weapons.qc).
// Fake drops run a CSQC-side copy of weapon_settle_think so high-ping
// players see the weapon rotate flat on the floor without waiting for
// the server entity to reach them.
.float weapon_settle_deadline;
#endif

// Dropped-weapon "classic Quake spin" opt-in. Server-side each weapon's
// drop / map-spawn function sets this to 1 to get a continuous yaw
// rotation; CSQC replicates the flag and does the rotation locally in
// a predraw (no angle sync required — derived from cltime).
.float dropped_spin;

// --- Fire spread penalty tuning ---
const float FIRE_SPREAD_PENALTY_PER_SHOT = 3.0;  // penalty added per bullet fired
const float FIRE_SPREAD_PENALTY_DECAY    = 30.0;   // decay rate per second
const float FIRE_SPREAD_PENALTY_MAX      = 10;   // maximum penalty cap

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
.float  pm_fuser2;              // CS 1.6 stamina: msec of landing fatigue remaining (0 = none)
.float  pm_step_time;           // seconds until next footstep sound fires
.float  sv_last_step_time;      // SSQC-only: time of last PM_EmitStepSound fire, used by sv_debug_footsteps to print cadence delta between server step events
.vector pm_anim_prev_origin;    // previous-frame origin for distance-based leg cycle timing


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
.float player_model_index;  // 0-3 = team models, 5 = sini
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
string team_blue_models[] = {
    "models/player/urban/urban.mdl",
    "models/player/gign/gign.mdl",
    "models/player/gsg9/gsg9.mdl",
    "models/player/sas/sas.mdl"
};
string team_blue_names[] = { "Urban", "GIGN", "GSG9", "SAS" };

string team_red_models[] = {
    "models/player/guerilla/guerilla.mdl",
    "models/player/leet/leet.mdl",
    "models/player/terror/terror.mdl",
    "models/player/arctic/arctic.mdl"
};
string team_red_names[] = { "Guerilla", "Leet", "Terror", "Arctic" };

const float TEAM_MODEL_COUNT = 4;

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

// Gamemode constants
const float GAMEMODE_TDM         = 0;
const float GAMEMODE_ELIMINATION = 1;
const float GAMEMODE_BHOP        = 2;

// Round phase constants
const float ROUND_PHASE_NONE      = 0;
const float ROUND_PHASE_FREEZE    = 1;
const float ROUND_PHASE_ACTIVE    = 2;
const float ROUND_PHASE_ROUND_END = 3;
const float ROUND_PHASE_MAP_END   = 4;

#ifdef SSQC
void(entity owner) phys_barrel_spawn_infront;
void(entity owner) phys_can_spawn_infront;
void() phys_barrel_precache;
void(entity plr) PhysProp_DepenetratePlayer;
#endif

void() precache_everything =
{
	precache_sound("sounds/null.wav");

#ifdef SSQC
	phys_barrel_precache();
#endif


    // Player Models
    precache_model("models/testplayer.iqm");
    precache_model("models/player/arctic/arctic.mdl");
    precache_model("models/player/gign/gign.mdl");
    precache_model("models/player/gsg9/gsg9.mdl");
    precache_model("models/player/sas/sas.mdl");
    precache_model("models/player/guerilla/guerilla.mdl");
    precache_model("models/player/leet/leet.mdl");
    precache_model("models/player/terror/terror.mdl");
    precache_model("models/player/urban/urban.mdl");
    precache_model("models/player/sini.mdl");

	// Player Models / Sounds
	precache_sound("sounds/player/use.wav");
	precache_sound("sounds/player/step1.wav");
	precache_sound("sounds/player/step2.wav");
	precache_sound("sounds/player/step3.wav");
	precache_sound("sounds/player/step4.wav");
	precache_sound("sounds/player/ladder1.wav");
	precache_sound("sounds/player/ladder2.wav");
	precache_sound("sounds/player/ladder3.wav");
	precache_sound("sounds/player/ladder4.wav");
	precache_sound("sounds/player/waterstep1.wav");
	precache_sound("sounds/player/waterstep2.wav");
	precache_sound("sounds/player/waterstep3.wav");
	precache_sound("sounds/player/waterstep4.wav");
	precache_sound("sounds/player/waterstep5.wav");
	precache_sound("sounds/player/waterstep6.wav");
	precache_sound("sounds/player/waterstep7.wav");
	precache_sound("sounds/player/waterstep8.wav");
	precache_sound("sounds/player/waterstep9.wav");
	precache_sound("sounds/player/waterstep10.wav");
	precache_sound("sounds/player/fallpain1.wav");
	precache_sound("sounds/player/fallpain2.wav");
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
	precache_model("models/weapons/wpn_csusp/w_usp.mdl");
	precache_model("models/weapons/wpn_csusp/v_usp.mdl");
    precache_model("models/weapons/wpn_csusp/p_usp.mdl");

    // Third-person weapon models (p_models)
    precache_model("models/weapons/wpn_csak47/p_ak47.mdl");
    precache_model("models/weapons/wpn_csawp/p_awp.mdl");
    precache_model("models/weapons/wpn_csdeagle/p_deagle.mdl");
    precache_model("models/weapons/wpn_csg3sg1/p_g3sg1.mdl");
    precache_model("models/weapons/wpn_csglock/p_glock.mdl");
    precache_model("models/weapons/wpn_csknife/p_knife.mdl");
    precache_model("models/weapons/wpn_csm3/p_m3.mdl");
    precache_model("models/weapons/wpn_csm4a1/p_m4a1.mdl");
    precache_model("models/weapons/wpn_csm249/p_m249.mdl");
    precache_model("models/weapons/wpn_csmp5/p_mp5.mdl");
    precache_model("models/weapons/wpn_csscout/p_scout.mdl");
    precache_model("models/weapons/wpn_dod98k/p_k98.mdl");
    precache_sound("sounds/weapons/wpn_csusp/clipin.wav");
    precache_sound("sounds/weapons/wpn_csusp/clipout.wav");
    precache_sound("sounds/weapons/wpn_csusp/silenceroff.wav");
    precache_sound("sounds/weapons/wpn_csusp/silenceron.wav");
    precache_sound("sounds/weapons/wpn_csusp/slideback.wav");
    precache_sound("sounds/weapons/wpn_csusp/sliderelease.wav");
    precache_sound("sounds/weapons/wpn_csusp/fire.wav");
    precache_sound("sounds/weapons/wpn_csusp/sfire.wav");

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

	// CS AK47
	precache_model("models/weapons/wpn_csak47/v_ak47.mdl");
	precache_model("models/weapons/wpn_csak47/w_ak47.mdl");
	precache_sound("sounds/weapons/wpn_csak47/fire1.wav");
	precache_sound("sounds/weapons/wpn_csak47/fire2.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipin.wav");
	precache_sound("sounds/weapons/wpn_csak47/clipout.wav");
	precache_sound("sounds/weapons/wpn_csak47/boltpull.wav");

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
