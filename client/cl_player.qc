/*
==============================================================================
cl_player.qc  -  Client-side prediction

Prediction now uses an explicit owner-only SSQC->CSQC snapshot proxy:
  1. CSQC_Input_Frame stores each generated input command in a 128-slot ring
     buffer and immediately applies that command to a client-owned
     predicted_player entity.
  2. Before the first proxy snapshot arrives, predicted_player is seeded from
     the engine's local player entity so movement responds instantly.
  3. CSQC_Ent_Update receives the authoritative proxy state, resets
     predicted_player to the server-confirmed state, then replays every
     buffered command after servercommandframe.

This keeps local movement responsive at high ping while still allowing exact
server reconciliation once authoritative state arrives.
==============================================================================
*/

// ---------------------------------------------------------------------------
//  Server-confirmed baseline (populated from the owner-only proxy snapshot)
// ---------------------------------------------------------------------------

vector sv_confirmed_origin;
vector sv_confirmed_velocity;
vector sv_confirmed_view_ofs;
float  sv_confirmed_flags;       // FL_ONGROUND etc.
float  sv_confirmed_movetype;
float  sv_confirmed_jump_held;
float  sv_confirmed_jump_msec;
float  sv_confirmed_waterjumptime;
float  sv_confirmed_in_duck;
float  sv_confirmed_duck_msec;
float  sv_confirmed_oldbuttons;
float  sv_confirmed_timecarry;
float  sv_confirmed_teleport_time;
float  sv_confirmed_ladder_detach_time;
float  sv_confirmed_fuser2;
float  sv_confirmed_spread_penalty;
float  sv_confirmed_fire_spread_penalty;
float  sv_confirmed_step_time;
// Duck-land slide flag + post-landing jump-cooldown end-timestamp.
// These have to be cached + restored across reconcile-replay or CSQC's
// predicted_player loses them after every snapshot — without the
// restore, PM_CheckJump sees pm_jump_lag_end = 0 every tick and
// autohop fires through the gate; PM_Friction sees
// slide_friction_active = 0 and the slide ends.
float  sv_confirmed_slide_friction_active;
float  sv_confirmed_jump_lag_end;
float  sv_confirmed_jump_groundstick_off_until;
// Grappling hook rope-render state — stashed + restored across
// reconcile-replay so the rope doesn't flicker during prediction
// rewinds.
float  sv_confirmed_grapple_rope_active;
float  sv_confirmed_pm_carrying;        // HL2 carry lowered-weapon flag (mirrors grapple)
float  sv_confirmed_pm_driving;         // func_vehicle driving flag (drives the pmove driver-lock)
vector sv_confirmed_grapple_anchor;
// Actively-pulling flag — gates the categorize ground-snap suppress
// so the suppress only fires during the pull phase, not during hook
// flight.  Replicated so CSQC's predicted pmove makes the same
// decision the server does.
float  sv_confirmed_grapple_attached;
// PM_BTN_GRAPPLE held-edge latch — the "was held" reference for the
// CSQC mirror of W_GrappleHeldTick.  See sv_player.qc proxy writer
// for why this needs to be in the rewind baseline.
float  sv_confirmed_grapple_held_last;
// sv_codstamina pool + punish flag + post-fire suppression timestamp
// — replicated through the prediction proxy so CSQC's predicted
// values get corrected to the server-authoritative state each
// snapshot.  Without this CSQC's pmove drains/refills independently
// and the bar visibly drifts (user-reported "skip one or be late").
float  sv_confirmed_codstamina;
float  sv_confirmed_codstamina_punished;
float  sv_confirmed_fire_suppress_until;
float  sv_confirmed_cmdframe;    // last acknowledged command for baseline

// Weapon prediction state (extended proxy)
float  sv_confirmed_slot_primary;
float  sv_confirmed_slot_secondary;
float  sv_confirmed_slot_melee;
float  sv_confirmed_slot_utility;
float  sv_confirmed_slot_primary_mag;
float  sv_confirmed_slot_primary_ammo;
float  sv_confirmed_slot_primary_aux;
float  sv_confirmed_slot_secondary_mag;
float  sv_confirmed_slot_secondary_ammo;
float  sv_confirmed_slot_secondary_aux;
float  sv_confirmed_weapon;
float  sv_confirmed_previous_weapon;
float  sv_confirmed_weaponstate;
float  sv_confirmed_wep_action_id;
float  sv_confirmed_attack_finished;   // absolute cltime
float  sv_confirmed_wep_anim_start;    // absolute cltime when animation began (0 = idle)
float  sv_confirmed_mag_deagle;
float  sv_confirmed_ammo_deagle;
float  sv_confirmed_mag_ak47;
float  sv_confirmed_ammo_ak47;
float  sv_confirmed_mag_m4a1;
float  sv_confirmed_ammo_m4a1;
float  sv_confirmed_m4a1_silenced;
float  sv_confirmed_mag_flakshotgun;
float  sv_confirmed_mag_pistol;
float  sv_confirmed_ammo_pistol;
float  sv_confirmed_mag_scout;
float  sv_confirmed_ammo_scout;
float  sv_confirmed_mag_357;
float  sv_confirmed_ammo_357;
float  sv_confirmed_mag_m249;
float  sv_confirmed_ammo_m249;
float  sv_confirmed_zoomstage;
float  sv_confirmed_mag_awp;
float  sv_confirmed_ammo_awp;
float  sv_confirmed_mag_98k;
float  sv_confirmed_ammo_98k;
float  sv_confirmed_mag_shotgun;
float  sv_confirmed_ammo_shotgun;
float  sv_confirmed_mag_m3;
float  sv_confirmed_ammo_m3;
float  sv_confirmed_mag_mp5;
float  sv_confirmed_ammo_mp5;
float  sv_confirmed_mag_crossbow;
float  sv_confirmed_ammo_crossbow;
float  sv_confirmed_mag_grenadelauncher;
float  sv_confirmed_mag_rebar;
float  sv_confirmed_ammo_gauss;
float  sv_confirmed_mag_glock;
float  sv_confirmed_ammo_glock;
float  sv_confirmed_mag_g3sg1;
float  sv_confirmed_ammo_g3sg1;
float  sv_confirmed_mag_hlsmg;
float  sv_confirmed_ammo_hlsmg;
float  sv_confirmed_ammo_hlsmg_grenades;
float  sv_confirmed_mag_hlrpg;
float  sv_confirmed_ammo_hlrpg;
float  sv_confirmed_ammo_hlgrenade;
float  sv_confirmed_ammo_snowball;
float  sv_confirmed_ammo_cshegrenade;
float  sv_confirmed_ammo_csflashbang;
float  sv_confirmed_ammo_cssmokegrenade;
float  sv_confirmed_ammo_cfc4;
float  sv_confirmed_snowball_has_slingshot;
float  sv_confirmed_snowball_use_slingshot;
float  sv_confirmed_mag_hlglock;
float  sv_confirmed_ammo_hlglock;
float  sv_confirmed_ammo_hlegon;
float  sv_confirmed_mag_paintball;
float  sv_confirmed_ammo_paintball;
float  sv_confirmed_mag_cfaug;
float  sv_confirmed_ammo_cfaug;
float  sv_confirmed_mag_cffamas;
float  sv_confirmed_ammo_cffamas;
float  sv_confirmed_mag_cfmac10;
float  sv_confirmed_ammo_cfmac10;

// csqc_prediction_valid moved to cl_customdefs.qc so cl_cameras.qc can read it.
float  csqc_baseline_valid;      // TRUE once an authoritative proxy snapshot arrived
float  csqc_proxy_seen;          // owner-only proxy seen this map/session
float  csqc_proxy_entnum;
entity csqc_authority_proxy;

// ---------------------------------------------------------------------------
//  Buffered input command history
// ---------------------------------------------------------------------------

// Buffer depth — must be >= server_tickrate × max_supported_ping_seconds.
// 512 covers 300 tick × ~1.7s ping, 200 tick × 2.5s, 100 tick × 5s, etc.
// Memory cost: 8 fields × ~6 bytes avg × 512 = ~24 KB total — trivial.
// Replay CPU cost scales with `actual` ping × tick rate, not buffer size,
// so keeping headroom in the buffer is free; the buffer just needs to be
// deep enough not to truncate replay when the ack-to-current span is large.
const float PRED_CMD_BACKUP = 512;

float  pred_cmd_valid     [PRED_CMD_BACKUP];
float  pred_cmd_sequence  [PRED_CMD_BACKUP];
float  pred_cmd_timestamp [PRED_CMD_BACKUP];
float  pred_cmd_timelength[PRED_CMD_BACKUP];
vector pred_cmd_angles    [PRED_CMD_BACKUP];
vector pred_cmd_movevalues[PRED_CMD_BACKUP];
float  pred_cmd_buttons   [PRED_CMD_BACKUP];
float  pred_cmd_impulse   [PRED_CMD_BACKUP];
float  pred_cmd_count;
float  pred_cmd_latest_sequence;

// --- Remote player interpolation buffer ---
// Ring buffer of the last N server snapshots per remote player. Fed by
// CSQC_SampleRemotePlayersForInterp (called once per render frame; only
// actually records when the server's `time` global advances = new
// snapshot arrived). Used by cl_interp_time to render each remote player
// N seconds behind the latest snapshot, lerping between two known
// positions instead of extrapolating. Trades latency for smoothness —
// useful at low sv_mintic / against players with low cl_netfps.
const float INTERP_HIST_SIZE   = 8;
const float INTERP_MAX_PLAYERS = 32;

vector g_interp_origin  [INTERP_MAX_PLAYERS * INTERP_HIST_SIZE];
float  g_interp_time    [INTERP_MAX_PLAYERS * INTERP_HIST_SIZE];  // cltime-frame timestamp
float  g_interp_head    [INTERP_MAX_PLAYERS];
float  g_interp_count   [INTERP_MAX_PLAYERS];
float  g_interp_last_serverprevtime;   // last value of FTE's serverprevtime — ticks when a new snapshot arrives
float  g_interp_last_snap_cltime;      // cltime at which the most recent snapshot was recorded — basis for extrap dt

// ---------------------------------------------------------------------------
//  Presentation, live input, and diagnostics
// ---------------------------------------------------------------------------

// Drift-trace ring buffer — captures last N live-tick pmove outputs so
// CSQC_PredictSelectWeapon can dump pre-/post-switch context to console
// without flooding the log. Live tick only (skip replay) — replay re-runs
// every render frame and would overwrite the ring 100x/sec at high ping.
const float CL_DRIFT_RING_SIZE = 32;
float  cl_drift_t  [CL_DRIFT_RING_SIZE];
float  cl_drift_seq[CL_DRIFT_RING_SIZE];
float  cl_drift_msec[CL_DRIFT_RING_SIZE];
vector cl_drift_mv [CL_DRIFT_RING_SIZE];
float  cl_drift_btn[CL_DRIFT_RING_SIZE];
float  cl_drift_wep[CL_DRIFT_RING_SIZE];
vector cl_drift_org[CL_DRIFT_RING_SIZE];
vector cl_drift_vel[CL_DRIFT_RING_SIZE];
float  cl_drift_idx;

void(float t_now, float seq, float msec, vector mv, float btn, float wep, vector org, vector vel) CL_Drift_Append =
{
	cl_drift_t  [cl_drift_idx] = t_now;
	cl_drift_seq[cl_drift_idx] = seq;
	cl_drift_msec[cl_drift_idx] = msec;
	cl_drift_mv [cl_drift_idx] = mv;
	cl_drift_btn[cl_drift_idx] = btn;
	cl_drift_wep[cl_drift_idx] = wep;
	cl_drift_org[cl_drift_idx] = org;
	cl_drift_vel[cl_drift_idx] = vel;
	cl_drift_idx = (cl_drift_idx + 1) % CL_DRIFT_RING_SIZE;
};

void() CL_Drift_Dump =
{
	float i;
	dprint(sprintf("--- CL drift ring (oldest first, %g entries) ---\n", CL_DRIFT_RING_SIZE));
	for (i = 0; i < CL_DRIFT_RING_SIZE; i++)
	{
		float ix = (cl_drift_idx + i) % CL_DRIFT_RING_SIZE;
		if (cl_drift_t[ix] <= 0) continue;
		dprint(sprintf("[CL] t=%.4f seq=%g msec=%.2f mv=%v btn=%g wep=%g\n",
			cl_drift_t[ix], cl_drift_seq[ix], cl_drift_msec[ix],
			cl_drift_mv[ix], cl_drift_btn[ix], cl_drift_wep[ix]));
		dprint(sprintf("[CL]   org=%v vel=%v\n", cl_drift_org[ix], cl_drift_vel[ix]));
	}
};

// csqc_present_origin / _view_ofs / _valid are declared in client/cl_customdefs.qc
// (compiled before cl_physprop.qc, which reads them for carried-prop prediction).
// Post-preview FL_DUCKING flag (0/1).  The preview at
// CSQC_BuildPresentationView may complete a duck transition mid-substep —
// origin drops 18qu, FL_DUCKING gets set, then `self.flags = saved_flags`
// restores the pre-preview value.  csqc_present_origin reflects the dropped
// origin, so any consumer sizing a bbox against that origin must use this
// flag, not predicted_player.flags, or the bbox will be standing-tall while
// the origin is ducked-low (feet end up 18qu into the floor).
float  csqc_present_ducking;
float  csqc_live_forward;
float  csqc_live_back;
float  csqc_live_left;
float  csqc_live_right;
float  csqc_live_up;
float  csqc_live_down;
// csqc_live_buttons moved to cl_customdefs.qc so cl_cameras.qc can read it.
float  csqc_dbg_last_key_time;
string csqc_dbg_last_key_cmd;
float  csqc_dbg_last_key_down;
float  csqc_dbg_last_inputframe_time;
float  csqc_dbg_last_snapshot_time;
float  csqc_dbg_last_reconcile_time;
float  csqc_dbg_last_present_time;
float  csqc_dbg_probe_pending;
float  csqc_dbg_probe_start_time;
vector csqc_dbg_probe_start_origin;
float  csqc_dbg_last_preview_response_ms;
float  csqc_dbg_last_predict_response_ms;
float  csqc_dbg_preview_responded;
float  csqc_dbg_predict_responded;
float  csqc_dbg_last_preview_dt;
float  csqc_dbg_last_predict_dt;
float  csqc_dbg_ring_overflowed;
float  csqc_dbg_ack_fell_out;
float  csqc_dbg_last_replay_count;
float  csqc_dbg_last_replay_from;
float  csqc_dbg_seed_source;     // 0 none, 1 engine seed, 2 proxy baseline


// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

void() CSQC_ClampMoveInputs =
{
	input_movevalues_x = bound(-350, input_movevalues_x, 350);
	input_movevalues_y = bound(-350, input_movevalues_y, 350);
	input_movevalues_z = bound(-350, input_movevalues_z, 350);
};

float(float value, float fallback) CSQC_DefaultCvar =
{
	if (!value)
		return fallback;
	return value;
};

entity() CSQC_GetEngineLocalPlayer =
{
	entity engine_player;

	if (player_localentnum <= 0)
	{
		if (player_localnum < 0)
			return world;
		return edict_num(player_localnum + 1);
	}

	engine_player = edict_num(player_localentnum);
	if (!engine_player && player_localnum >= 0)
		return edict_num(player_localnum + 1);

	return engine_player;
};

vector() CSQC_BuildLiveMoveValues =
{
	vector movevalues;
	float forwardspeed;
	float backspeed;
	float sidespeed;
	float upspeed;

	forwardspeed = CSQC_DefaultCvar(cvar("cl_forwardspeed"), 400);
	backspeed = CSQC_DefaultCvar(cvar("cl_backspeed"), forwardspeed);
	sidespeed = CSQC_DefaultCvar(cvar("cl_sidespeed"), 350);
	upspeed = CSQC_DefaultCvar(cvar("cl_upspeed"), 320);

	movevalues_x = csqc_live_forward * forwardspeed - csqc_live_back * backspeed;
	movevalues_y = csqc_live_right * sidespeed - csqc_live_left * sidespeed;
	movevalues_z = csqc_live_up * upspeed - csqc_live_down * upspeed;

	return movevalues;
};

void(float bit, float down) CSQC_SetLiveButton =
{
	if (down)
		csqc_live_buttons = csqc_live_buttons | bit;
	else
		csqc_live_buttons = csqc_live_buttons - (csqc_live_buttons & bit);
};

void(float scan, float down) CSQC_UpdateLiveInputFromBind =
{
	string cmd;

	cmd = getkeybind(scan);
	csqc_dbg_last_key_time = cltime;
	csqc_dbg_last_key_cmd = cmd;
	csqc_dbg_last_key_down = down;
	localplayer = CSQC_GetEngineLocalPlayer();

	if (cmd == "+forward")
		csqc_live_forward = down;
	else if (cmd == "+back")
		csqc_live_back = down;
	else if (cmd == "+moveleft")
		csqc_live_left = down;
	else if (cmd == "+moveright")
		csqc_live_right = down;
	else if (cmd == "+moveup")
		csqc_live_up = down;
	else if (cmd == "+movedown")
		csqc_live_down = down;
	else if (cmd == "+jump")
		CSQC_SetLiveButton(PM_BTN_JUMP, down);
	else if (cmd == "+button6")
		CSQC_SetLiveButton(PM_BTN_DUCK, down);
	else if (cmd == "+button7" || cmd == "+sprint")
		CSQC_SetLiveButton(PM_BTN_SPRINT, down);
	else if (cmd == "+button9" || cmd == "+grapple")
		// Press-and-hold grapple — sets PM_BTN_GRAPPLE in input_buttons
		// while the bind is held.  Edge-detected on both SSQC
		// (W_GrappleHeldTick) and CSQC (PredictGrappleHeldEdge) to
		// engage on rising / release on falling.  Mirrors the +sprint
		// pattern above so users can bind either `+button9` (the raw
		// engine name) or the friendlier `+grapple` alias.
		CSQC_SetLiveButton(PM_BTN_GRAPPLE, down);
	else if (cmd == "+use")
	{
		// Only fire sound + impulse on the initial press, not on OS key-repeat.
		if (down && !(csqc_live_buttons & PM_BTN_USE))
		{
			localsound("sounds/player/use.wav");
			localcmd("impulse 11\n");
		}
		CSQC_SetLiveButton(PM_BTN_USE, down);
	}

	if (down && (cmd == "+forward" || cmd == "+back" || cmd == "+moveleft"
		|| cmd == "+moveright" || cmd == "+jump" || cmd == "+button6"))
	{
		csqc_dbg_probe_pending = TRUE;
		csqc_dbg_probe_start_time = cltime;
		if (predicted_player)
			csqc_dbg_probe_start_origin = predicted_player.origin;
		else if (localplayer)
			csqc_dbg_probe_start_origin = localplayer.origin;
		else
			csqc_dbg_probe_start_origin = '0 0 0';
		csqc_dbg_preview_responded = FALSE;
		csqc_dbg_predict_responded = FALSE;
	}
};

void() CSQC_LatchLiveInputFromCommand =
{
	if (input_movevalues_x > 0)
	{
		csqc_live_forward = TRUE;
		csqc_live_back = FALSE;
	}
	else if (input_movevalues_x < 0)
	{
		csqc_live_forward = FALSE;
		csqc_live_back = TRUE;
	}
	else
	{
		csqc_live_forward = FALSE;
		csqc_live_back = FALSE;
	}

	if (input_movevalues_y > 0)
	{
		csqc_live_right = TRUE;
		csqc_live_left = FALSE;
	}
	else if (input_movevalues_y < 0)
	{
		csqc_live_right = FALSE;
		csqc_live_left = TRUE;
	}
	else
	{
		csqc_live_right = FALSE;
		csqc_live_left = FALSE;
	}

	if (input_movevalues_z > 0)
	{
		csqc_live_up = TRUE;
		csqc_live_down = FALSE;
	}
	else if (input_movevalues_z < 0)
	{
		csqc_live_up = FALSE;
		csqc_live_down = TRUE;
	}
	else
	{
		csqc_live_up = FALSE;
		csqc_live_down = FALSE;
	}

	// Take engine-reported bits as the base, then re-apply any custom bits that
	// CSQC_UpdateLiveInputFromBind set via CSQC_SetLiveButton.  Without this,
	// the engine's overwrite every input frame clears PM_BTN_SPRINT / PM_BTN_USE.
	float custom_bits = PM_BTN_USE;
	csqc_live_buttons = input_buttons | (csqc_live_buttons & custom_bits);
};

float(float seq) CSQC_CommandSequence =
{
	return rint(seq);
};

float(float seq) CSQC_CommandSlot =
{
	seq = CSQC_CommandSequence(seq);
	return seq - floor(seq / PRED_CMD_BACKUP) * PRED_CMD_BACKUP;
};

float() CSQC_FirstBufferedSequence =
{
	if (!pred_cmd_count)
		return 0;

	return pred_cmd_latest_sequence - pred_cmd_count + 1;
};

void() CSQC_ClearPredictionBuffer =
{
	float i;

	for (i = 0; i < PRED_CMD_BACKUP; i++)
		pred_cmd_valid[i] = FALSE;

	pred_cmd_count = 0;
	pred_cmd_latest_sequence = 0;
	csqc_dbg_ring_overflowed = FALSE;
	csqc_dbg_ack_fell_out = FALSE;
	csqc_dbg_last_replay_count = 0;
	csqc_dbg_last_replay_from = 0;
};

float(float seq) CSQC_FindBufferedCommand =
{
	float slot;

	seq = CSQC_CommandSequence(seq);
	slot = CSQC_CommandSlot(seq);

	if (!pred_cmd_valid[slot])
		return -1;
	if (pred_cmd_sequence[slot] != seq)
		return -1;

	return slot;
};

void(float slot) CSQC_LoadBufferedCommand =
{
	input_timelength = pred_cmd_timelength[slot];
	input_angles     = pred_cmd_angles[slot];
	input_movevalues = pred_cmd_movevalues[slot];
	input_buttons    = pred_cmd_buttons[slot];
	input_impulse    = pred_cmd_impulse[slot];
};

void(entity src, entity dst) CSQC_CopyMoveState =
{
	setorigin(dst, src.origin);
	dst.velocity         = src.velocity;
	dst.view_ofs         = src.view_ofs;
	dst.flags            = src.flags;
	dst.pm_movetype      = src.pm_movetype;
	dst.pm_jump_held     = src.pm_jump_held;
	dst.pm_jump_msec     = src.pm_jump_msec;
	dst.pm_waterjumptime = src.pm_waterjumptime;
	dst.pm_in_duck       = src.pm_in_duck;
	dst.pm_duck_msec     = src.pm_duck_msec;
	dst.pm_oldbuttons    = src.pm_oldbuttons;
	dst.pm_timecarry     = src.pm_timecarry;
	dst.pm_fuser2        = src.pm_fuser2;
	dst.spread_penalty   = src.spread_penalty;
	dst.pm_teleport_time      = src.pm_teleport_time;
	dst.pm_ladder_detach_time = src.pm_ladder_detach_time;
	dst.pm_step_time          = src.pm_step_time;
};

void(entity src) CSQC_StoreConfirmedStateFromEntity =
{
	sv_confirmed_origin        = src.origin;
	sv_confirmed_velocity      = src.velocity;
	sv_confirmed_view_ofs      = src.view_ofs;
	sv_confirmed_flags         = src.flags;
	sv_confirmed_movetype      = src.pm_movetype;
	sv_confirmed_jump_held     = src.pm_jump_held;
	sv_confirmed_jump_msec     = src.pm_jump_msec;
	sv_confirmed_waterjumptime = src.pm_waterjumptime;
	sv_confirmed_in_duck       = src.pm_in_duck;
	sv_confirmed_duck_msec     = src.pm_duck_msec;
	sv_confirmed_oldbuttons    = src.pm_oldbuttons;
	sv_confirmed_timecarry     = src.pm_timecarry;
	sv_confirmed_teleport_time        = src.pm_teleport_time;
	sv_confirmed_ladder_detach_time   = src.pm_ladder_detach_time;
	sv_confirmed_fuser2               = src.pm_fuser2;
	sv_confirmed_spread_penalty       = src.spread_penalty;
	sv_confirmed_fire_spread_penalty  = src.fire_spread_penalty;
	sv_confirmed_step_time            = src.pm_step_time;
	sv_confirmed_slide_friction_active = src.slide_friction_active;
	sv_confirmed_jump_lag_end         = src.pm_jump_lag_end;
	sv_confirmed_jump_groundstick_off_until = src.pm_jump_groundstick_off_until;
	sv_confirmed_grapple_rope_active  = src.grapple_rope_active;
	sv_confirmed_pm_carrying          = src.pm_carrying;
	sv_confirmed_pm_driving           = src.pm_driving;
	sv_confirmed_grapple_anchor       = src.grapple_anchor;
	sv_confirmed_grapple_attached     = src.grapple_attached;
	sv_confirmed_grapple_held_last    = src.pm_grapple_held_last;
	sv_confirmed_codstamina           = src.codstamina;
	sv_confirmed_codstamina_punished  = src.codstamina_punished;
	sv_confirmed_fire_suppress_until  = src.pm_fire_suppress_until;

	sv_confirmed_slot_primary      = src.slot_primary;
	sv_confirmed_slot_secondary    = src.slot_secondary;
	sv_confirmed_slot_melee        = src.slot_melee;
	sv_confirmed_slot_utility      = src.slot_utility;
	sv_confirmed_slot_primary_mag  = src.slot_primary_mag;
	sv_confirmed_slot_primary_ammo = src.slot_primary_ammo;
	sv_confirmed_slot_primary_aux  = src.slot_primary_aux;
	sv_confirmed_slot_secondary_mag  = src.slot_secondary_mag;
	sv_confirmed_slot_secondary_ammo = src.slot_secondary_ammo;
	sv_confirmed_slot_secondary_aux  = src.slot_secondary_aux;
	sv_confirmed_weapon           = src.weapon;
	sv_confirmed_previous_weapon  = src.previous_weapon;
	sv_confirmed_weaponstate      = src.weaponstate;
	sv_confirmed_wep_action_id    = src.wep_action_id;
	sv_confirmed_attack_finished  = src.attack_finished;   // already absolute cltime
	sv_confirmed_wep_anim_start   = src.wep_anim_start;   // already absolute cltime
	sv_confirmed_mag_deagle       = src.mag_deagle;
	sv_confirmed_ammo_deagle      = src.ammo_deagle;
	sv_confirmed_mag_ak47         = src.mag_ak47;
	sv_confirmed_ammo_ak47        = src.ammo_ak47;
	sv_confirmed_mag_m4a1         = src.mag_m4a1;
	sv_confirmed_ammo_m4a1        = src.ammo_m4a1;
	sv_confirmed_m4a1_silenced    = src.m4a1_silenced;
	sv_confirmed_mag_flakshotgun  = src.mag_flakshotgun;
	sv_confirmed_mag_pistol       = src.mag_pistol;
	sv_confirmed_ammo_pistol      = src.ammo_pistol;
	sv_confirmed_mag_scout        = src.mag_scout;
	sv_confirmed_ammo_scout       = src.ammo_scout;
	sv_confirmed_mag_357          = src.mag_357;
	sv_confirmed_ammo_357         = src.ammo_357;
	sv_confirmed_mag_m249         = src.mag_m249;
	sv_confirmed_ammo_m249        = src.ammo_m249;
	sv_confirmed_zoomstage        = src.zoomstage;
	sv_confirmed_mag_awp          = src.mag_awp;
	sv_confirmed_ammo_awp         = src.ammo_awp;
	sv_confirmed_mag_98k          = src.mag_98k;
	sv_confirmed_ammo_98k         = src.ammo_98k;
	sv_confirmed_mag_shotgun      = src.mag_shotgun;
	sv_confirmed_ammo_shotgun     = src.ammo_shotgun;
	sv_confirmed_mag_m3           = src.mag_m3;
	sv_confirmed_ammo_m3          = src.ammo_m3;
	sv_confirmed_mag_mp5          = src.mag_mp5;
	sv_confirmed_ammo_mp5         = src.ammo_mp5;
	sv_confirmed_mag_crossbow     = src.mag_crossbow;
	sv_confirmed_ammo_crossbow    = src.ammo_crossbow;
	sv_confirmed_mag_grenadelauncher = src.mag_grenadelauncher;
	sv_confirmed_mag_rebar        = src.mag_rebar;
	sv_confirmed_ammo_gauss       = src.ammo_gauss;
	sv_confirmed_mag_glock        = src.mag_glock;
	sv_confirmed_ammo_glock       = src.ammo_glock;
	sv_confirmed_mag_g3sg1        = src.mag_g3sg1;
	sv_confirmed_ammo_g3sg1       = src.ammo_g3sg1;
	sv_confirmed_mag_hlsmg        = src.mag_hlsmg;
	sv_confirmed_ammo_hlsmg       = src.ammo_hlsmg;
	sv_confirmed_ammo_hlsmg_grenades = src.ammo_hlsmg_grenades;
	sv_confirmed_mag_hlrpg        = src.mag_hlrpg;
	sv_confirmed_ammo_hlrpg       = src.ammo_hlrpg;
	sv_confirmed_ammo_hlgrenade   = src.ammo_hlgrenade;
	sv_confirmed_ammo_snowball    = src.ammo_snowball;
	sv_confirmed_ammo_cshegrenade = src.ammo_cshegrenade;
	sv_confirmed_ammo_csflashbang = src.ammo_csflashbang;
	sv_confirmed_ammo_cssmokegrenade = src.ammo_cssmokegrenade;
	sv_confirmed_ammo_cfc4 = src.ammo_cfc4;
	sv_confirmed_snowball_has_slingshot = src.snowball_has_slingshot;
	sv_confirmed_snowball_use_slingshot = src.snowball_use_slingshot;
	sv_confirmed_mag_hlglock      = src.mag_hlglock;
	sv_confirmed_ammo_hlglock     = src.ammo_hlglock;
	sv_confirmed_ammo_hlegon      = src.ammo_hlegon;
	sv_confirmed_mag_paintball    = src.mag_paintball;
	sv_confirmed_ammo_paintball   = src.ammo_paintball;
	sv_confirmed_mag_cfaug        = src.mag_cfaug;
	sv_confirmed_ammo_cfaug       = src.ammo_cfaug;
	sv_confirmed_mag_cffamas      = src.mag_cffamas;
	sv_confirmed_ammo_cffamas     = src.ammo_cffamas;
	sv_confirmed_mag_cfmac10      = src.mag_cfmac10;
	sv_confirmed_ammo_cfmac10     = src.ammo_cfmac10;
};

void() CSQC_ResetToConfirmedMoveState =
{
	setorigin(self, sv_confirmed_origin);
	self.velocity         = sv_confirmed_velocity;
	self.view_ofs         = sv_confirmed_view_ofs;
	self.flags            = sv_confirmed_flags;
	self.pm_movetype      = sv_confirmed_movetype;
	self.pm_jump_held     = sv_confirmed_jump_held;
	self.pm_jump_msec     = sv_confirmed_jump_msec;
	self.pm_waterjumptime = sv_confirmed_waterjumptime;
	self.pm_in_duck       = sv_confirmed_in_duck;
	self.pm_duck_msec     = sv_confirmed_duck_msec;
	self.pm_oldbuttons     = sv_confirmed_oldbuttons;
	self.pm_timecarry      = sv_confirmed_timecarry;
	self.pm_teleport_time        = sv_confirmed_teleport_time;
	self.pm_ladder_detach_time   = sv_confirmed_ladder_detach_time;
	self.pm_fuser2               = sv_confirmed_fuser2;
	self.spread_penalty          = sv_confirmed_spread_penalty;
	self.fire_spread_penalty     = sv_confirmed_fire_spread_penalty;
	self.pm_step_time            = sv_confirmed_step_time;
	self.slide_friction_active   = sv_confirmed_slide_friction_active;
	self.pm_jump_lag_end         = sv_confirmed_jump_lag_end;
	self.pm_jump_groundstick_off_until = sv_confirmed_jump_groundstick_off_until;
	self.grapple_rope_active     = sv_confirmed_grapple_rope_active;
	self.pm_carrying             = sv_confirmed_pm_carrying;
	self.pm_driving              = sv_confirmed_pm_driving;
	self.grapple_anchor          = sv_confirmed_grapple_anchor;
	self.grapple_attached        = sv_confirmed_grapple_attached;
	self.pm_grapple_held_last    = sv_confirmed_grapple_held_last;
	self.codstamina              = sv_confirmed_codstamina;
	self.codstamina_punished     = sv_confirmed_codstamina_punished;
	self.pm_fire_suppress_until  = sv_confirmed_fire_suppress_until;

	// Sync hull size to match the confirmed duck state.
	// Without this, the predicted player replays commands with the wrong
	// hull size, causing permanent prediction divergence when ducked.
	PM_SyncHull();

	// Recompute the ladder cache at the rewound position so the first
	// replay tick's fire gate (Weapon_LowerBlocksFire reads pm_on_ladder_cached)
	// agrees with the rewound origin instead of carrying the LAST-LIVE-TICK
	// value through reconcile.  pm_on_ladder_cached is not on the wire
	// (the trigger list IS replicated, so we can reproduce it deterministically
	// here) — PM_CheckLadder writes both pm_on_ladder (the per-step global)
	// AND the latch at done:, but here we call it standalone so we need to
	// copy the result onto the field ourselves.
	PM_CheckLadder();
	self.pm_on_ladder_cached = pm_on_ladder;
};

void() CSQC_ResetToConfirmedState =
{
	float old_weapon;
	float old_weaponstate;
	float old_wep_action_id;
	float old_wep_anim_start;
	float old_attack_finished;
	float old_mag_deagle;
	float old_ammo_deagle;
	float old_mag_ak47;
	float old_ammo_ak47;
	float old_mag_m4a1;
	float old_ammo_m4a1;
	float old_m4a1_silenced;
	float old_mag_flakshotgun;
	float old_mag_pistol;
	float old_ammo_pistol;
	float old_mag_scout;
	float old_ammo_scout;
	float old_mag_357;
	float old_ammo_357;
	float old_mag_m249;
	float old_ammo_m249;
	float old_zoomstage;
	float old_mag_awp;
	float old_ammo_awp;
	float old_mag_98k;
	float old_ammo_98k;
	float old_mag_shotgun;
	float old_ammo_shotgun;
	float old_mag_m3;
	float old_ammo_m3;
	float old_mag_mp5;
	float old_ammo_mp5;
	float old_mag_crossbow;
	float old_ammo_crossbow;
	float old_mag_grenadelauncher;
	float old_mag_rebar;
	float old_ammo_gauss;
	float old_mag_glock;
	float old_ammo_glock;
	float old_mag_g3sg1;
	float old_ammo_g3sg1;
	float old_ammo_snowball;
	float old_ammo_cshegrenade;
	float old_ammo_csflashbang;
	float old_ammo_cssmokegrenade;
	float old_mag_paintball;
	float old_ammo_paintball;

	old_weapon = self.weapon;
	old_weaponstate = self.weaponstate;
	old_wep_action_id = self.wep_action_id;
	old_wep_anim_start = self.wep_anim_start;
	old_attack_finished = self.attack_finished;
	old_mag_deagle = self.mag_deagle;
	old_ammo_deagle = self.ammo_deagle;
	old_mag_ak47 = self.mag_ak47;
	old_ammo_ak47 = self.ammo_ak47;
	old_mag_m4a1 = self.mag_m4a1;
	old_ammo_m4a1 = self.ammo_m4a1;
	old_m4a1_silenced = self.m4a1_silenced;
	old_mag_flakshotgun = self.mag_flakshotgun;
	old_mag_pistol = self.mag_pistol;
	old_ammo_pistol = self.ammo_pistol;
	old_mag_scout = self.mag_scout;
	old_ammo_scout = self.ammo_scout;
	old_mag_357 = self.mag_357;
	old_ammo_357 = self.ammo_357;
	old_mag_m249 = self.mag_m249;
	old_ammo_m249 = self.ammo_m249;
	old_zoomstage = self.zoomstage;
	old_mag_awp = self.mag_awp;
	old_ammo_awp = self.ammo_awp;
	old_mag_98k = self.mag_98k;
	old_ammo_98k = self.ammo_98k;
	old_mag_shotgun = self.mag_shotgun;
	old_ammo_shotgun = self.ammo_shotgun;
	old_mag_m3 = self.mag_m3;
	old_ammo_m3 = self.ammo_m3;
	old_mag_mp5 = self.mag_mp5;
	old_ammo_mp5 = self.ammo_mp5;
	old_mag_crossbow = self.mag_crossbow;
	old_ammo_crossbow = self.ammo_crossbow;
	old_mag_grenadelauncher = self.mag_grenadelauncher;
	old_mag_rebar = self.mag_rebar;
	old_ammo_gauss = self.ammo_gauss;
	old_mag_glock = self.mag_glock;
	old_ammo_glock = self.ammo_glock;
	old_mag_g3sg1 = self.mag_g3sg1;
	old_ammo_g3sg1 = self.ammo_g3sg1;
	old_ammo_snowball = self.ammo_snowball;
	old_ammo_cshegrenade = self.ammo_cshegrenade;
	old_ammo_csflashbang = self.ammo_csflashbang;
	old_ammo_cssmokegrenade = self.ammo_cssmokegrenade;
	old_mag_paintball = self.mag_paintball;
	old_ammo_paintball = self.ammo_paintball;

	CSQC_ResetToConfirmedMoveState();

	self.slot_primary     = sv_confirmed_slot_primary;
	self.slot_secondary   = sv_confirmed_slot_secondary;
	self.slot_melee       = sv_confirmed_slot_melee;
	self.slot_utility     = sv_confirmed_slot_utility;

	// Ammo reconcile is gated on action_id catch-up.  When the local
	// predicted_player has fired (or reloaded) past the server's
	// snapshot view (sv_confirmed_wep_action_id < self.wep_action_id),
	// the server's mag/ammo / slot-ammo values are STALE PRE-FIRE
	// numbers and writing them back would roll the predicted decrement
	// off, which is what previously broke the reload TryReload check
	// ("mag bounces back to full after firing dry, so TryReload sees
	// max-mag and refuses to start the reload anim").
	//
	// When server has caught up (sv_confirmed_wep_action_id >=
	// self.wep_action_id), the snapshot is fresh enough to trust —
	// sync everything, so pickups / round-start loadouts / admin
	// give-cmds propagate.  Steady-state ping has ammo_sync_ok=true
	// most of the time; the gate only closes briefly during the
	// 1× RTT window between predicted fire and server ack.
	float ammo_sync_ok = (sv_confirmed_wep_action_id >= self.wep_action_id);
	// nettest (ammo-HUD fix, bug 1 — M3 reload): the M3 inserts shells one-by-one on the SERVER
	// (W_M3Frame); its custom SH_M3TickState does NOT apply reload ammo client-side, so the client never
	// predicts the per-shell mag climb and the HUD froze for the whole reload (corrected only by a
	// drop+pickup).  Trust the server's ammo while the M3 is reloading so the count climbs live.  This is
	// SCOPED to the M3: standard mag weapons predict their own reload ammo (SH_StandardTickState applies
	// mag+=needed on BOTH sides), so force-syncing a possibly-stale snapshot mid-reload would corrupt their
	// predicted apply math (off-by-one).  You can't fire mid-reload, so there is no predicted fire
	// decrement to protect here.  (Other shell-by-shell loaders that don't predict reload ammo can be
	// added to this condition if they show the same symptom.)
	float trust_server_ammo = ammo_sync_ok || (self.weaponstate == WS_RELOAD && self.weapon == WEP_CSM3);
	if (trust_server_ammo)
	{
		self.slot_primary_mag    = sv_confirmed_slot_primary_mag;
		self.slot_primary_ammo   = sv_confirmed_slot_primary_ammo;
		self.slot_primary_aux    = sv_confirmed_slot_primary_aux;
		self.slot_secondary_mag  = sv_confirmed_slot_secondary_mag;
		self.slot_secondary_ammo = sv_confirmed_slot_secondary_ammo;
		self.slot_secondary_aux  = sv_confirmed_slot_secondary_aux;
	}
	self.weapon          = sv_confirmed_weapon;
	self.previous_weapon = sv_confirmed_previous_weapon;
	// FIRE-DECISION STATE NO LONGER RECONCILED FROM SERVER.
	//
	// Under the client-authoritative fire architecture (see the plan
	// doc, "client-authoritative local-player firing"), predicted_player
	// owns its own weaponstate / wep_action_id / attack_finished /
	// wep_anim_start.  The server still snapshots these fields and they
	// land in sv_confirmed_* / csqc_authority_proxy, but reconcile
	// deliberately does NOT write them back into predicted_player.
	// That avoids the entire class of reconcile-rewind bugs:
	//   - latch trapping at high tick rates (effects skip while ammo
	//     and animation still fire)
	//   - live sv_mintic switches leaving the firing latch stuck
	//   - "ghost shots" after burst → snapshot ack patterns
	// Local cooldown is purely a function of cltime vs the locally
	// advanced attack_finished; the client wins.
	//
	// csqc_fire_guard / csqc_reload_guard were workaround latches for
	// the reconcile-rewind problem; with no reconcile, they have
	// nothing to defend against and the re-sync lines are removed.
	// (The fields themselves will be deleted in Phase 4 of the plan.)
	//
	// zoomstage / snowball_use_slingshot likewise become local — they
	// were riding the snapshot purely because they happened to live
	// next to wep_action_id in the wire format.
	//
	// snowball_has_slingshot STAYS server-authoritative — it's a
	// pickup-item flag, not a fire-decision field, so it goes with
	// the loadout-sync block.
	self.snowball_has_slingshot = sv_confirmed_snowball_has_slingshot;
	CSQC_WeaponEquip(self.weapon);

	// Snapshot-driven weapon change (respawn / team change / server
	// force-equip) — mirror what CSQC_PredictSelectWeapon does for
	// input-initiated switches so the draw animation actually plays
	// locally.  Without this, the server multicasts the deploy sound
	// but predicted_player.weaponstate is left at its pre-equip value
	// (commonly WS_IDLE or WS_DEAD), so the viewmodel anim driver
	// never enters the WS_DRAW branch — sound plays, no animation.
	//
	// Two trigger paths:
	//   (a) weapon CHANGED since last reconcile (server force-equip,
	//       weapon pickup, etc.)
	//   (b) wep_action_id was just reset to 0 by the action-id-
	//       rewind detector in CSQC_Ent_Update (respawn, team change
	//       with the SAME primary weapon — common case for CS-style
	//       loadouts where T+CT both spawn with AK or M4 etc.).
	//       Without case (b), team-changing into the same primary
	//       weapon you had before leaves the player with no draw
	//       animation since case (a) doesn't fire.
	if (self.weapon != WEP_NONE
	    && (self.weapon != old_weapon || self.wep_action_id == 0))
	{
		self.weaponstate    = WS_DRAW;
		self.wep_action_id += 1;
		self.wep_anim_start = cltime;
		self.attack_finished   = 0;
		self.altfire_finished  = 0;
		self.csqc_fire_guard   = 0;
		self.csqc_reload_guard = 0;

		// nettest (ammo-HUD fix, bug 2 — buy / server-equip): force the new weapon's slot ammo from the
		// snapshot even if the fire-prediction gate is closed.  A buy is `cmd buy` -> server (NOT
		// client-predicted), so the new weapon's ammo is purely server-authoritative; without this the HUD
		// kept showing the PREVIOUS weapon's ammo ("copied over") until a drop+pickup re-synced it.
		// GATE on csqc_weapon_pending_ack_sequence <= 0: that is true only when the client has NO predicted
		// weapon action in flight, i.e. this weapon change came from the SERVER (buy/pickup/force-equip),
		// not from a local predicted switch the server hasn't acked yet — for which force-syncing the
		// server's (lagging) ammo would briefly show the wrong gun's count.  W_SlotAmmo_LoadCurrent below
		// then seeds the active weapon's working register from this slot.
		if (csqc_weapon_pending_ack_sequence <= 0)
		{
			self.slot_primary_mag    = sv_confirmed_slot_primary_mag;
			self.slot_primary_ammo   = sv_confirmed_slot_primary_ammo;
			self.slot_primary_aux    = sv_confirmed_slot_primary_aux;
			self.slot_secondary_mag  = sv_confirmed_slot_secondary_mag;
			self.slot_secondary_ammo = sv_confirmed_slot_secondary_ammo;
			self.slot_secondary_aux  = sv_confirmed_slot_secondary_aux;
		}
	}

	// Per-weapon mag/ammo sync — gated on ammo_sync_ok for the same
	// reason as the slot-ammo block above.  When local has predicted
	// fires the server hasn't acknowledged yet, the snapshot's values
	// are stale and writing them back would erase the predicted
	// decrement (= "ammo bounces back to full, reload TryReload then
	// refuses to start because mag looks full").  When server has
	// caught up, sync — which is also how pickup / round-start
	// loadout values reach the client.
	if (trust_server_ammo)
	{
		self.mag_deagle      = sv_confirmed_mag_deagle;
		self.ammo_deagle     = sv_confirmed_ammo_deagle;
		self.mag_ak47        = sv_confirmed_mag_ak47;
		self.ammo_ak47       = sv_confirmed_ammo_ak47;
		self.mag_m4a1        = sv_confirmed_mag_m4a1;
		self.ammo_m4a1       = sv_confirmed_ammo_m4a1;
		// m4a1_silenced is NOT reset from server — client prediction is authoritative
		// for this toggle. Resetting it causes sound desyncs at high ping.
		self.mag_flakshotgun = sv_confirmed_mag_flakshotgun;
		self.mag_pistol      = sv_confirmed_mag_pistol;
		self.ammo_pistol     = sv_confirmed_ammo_pistol;
		self.mag_scout       = sv_confirmed_mag_scout;
		self.ammo_scout      = sv_confirmed_ammo_scout;
		self.mag_357         = sv_confirmed_mag_357;
		self.ammo_357        = sv_confirmed_ammo_357;
		self.mag_m249        = sv_confirmed_mag_m249;
		self.ammo_m249       = sv_confirmed_ammo_m249;
		// zoomstage stays local — see fire-state-decouple comment above.
		self.mag_awp         = sv_confirmed_mag_awp;
		self.ammo_awp        = sv_confirmed_ammo_awp;
		self.mag_98k         = sv_confirmed_mag_98k;
		self.ammo_98k        = sv_confirmed_ammo_98k;
		self.mag_shotgun     = sv_confirmed_mag_shotgun;
		self.ammo_shotgun    = sv_confirmed_ammo_shotgun;
		self.mag_m3          = sv_confirmed_mag_m3;
		self.ammo_m3         = sv_confirmed_ammo_m3;
		self.mag_mp5         = sv_confirmed_mag_mp5;
		self.ammo_mp5        = sv_confirmed_ammo_mp5;
		self.mag_crossbow    = sv_confirmed_mag_crossbow;
		self.ammo_crossbow   = sv_confirmed_ammo_crossbow;
		self.mag_grenadelauncher = sv_confirmed_mag_grenadelauncher;
		self.mag_rebar       = sv_confirmed_mag_rebar;
		self.ammo_gauss      = sv_confirmed_ammo_gauss;
		self.mag_glock       = sv_confirmed_mag_glock;
		self.ammo_glock      = sv_confirmed_ammo_glock;
		self.mag_g3sg1       = sv_confirmed_mag_g3sg1;
		self.ammo_g3sg1      = sv_confirmed_ammo_g3sg1;
		self.mag_hlsmg       = sv_confirmed_mag_hlsmg;
		self.ammo_hlsmg      = sv_confirmed_ammo_hlsmg;
		self.ammo_hlsmg_grenades = sv_confirmed_ammo_hlsmg_grenades;
		self.mag_hlrpg       = sv_confirmed_mag_hlrpg;
		self.ammo_hlrpg      = sv_confirmed_ammo_hlrpg;
		self.ammo_hlgrenade  = sv_confirmed_ammo_hlgrenade;
		self.ammo_snowball   = sv_confirmed_ammo_snowball;
		self.ammo_cshegrenade = sv_confirmed_ammo_cshegrenade;
		self.ammo_csflashbang = sv_confirmed_ammo_csflashbang;
		self.ammo_cssmokegrenade = sv_confirmed_ammo_cssmokegrenade;
		self.mag_hlglock     = sv_confirmed_mag_hlglock;
		self.ammo_hlglock    = sv_confirmed_ammo_hlglock;
		self.ammo_hlegon     = sv_confirmed_ammo_hlegon;
		self.mag_paintball   = sv_confirmed_mag_paintball;
		self.ammo_paintball  = sv_confirmed_ammo_paintball;
		self.mag_cfaug       = sv_confirmed_mag_cfaug;
		self.ammo_cfaug      = sv_confirmed_ammo_cfaug;
		self.mag_cffamas     = sv_confirmed_mag_cffamas;
		self.ammo_cffamas    = sv_confirmed_ammo_cffamas;
		self.mag_cfmac10     = sv_confirmed_mag_cfmac10;
		self.ammo_cfmac10    = sv_confirmed_ammo_cfmac10;
		// for this toggle, same convention as m4a1_silenced.
	}

	// C4 carry flag (ammo_cfc4) is server-authoritative and NEVER client-predicted
	// — the only ammo_cfc4=1 grant is server-side — so reconcile it UNCONDITIONALLY,
	// outside the trust_server_ammo gate.  That gate protects predicted mag/ammo
	// decrements during the 1xRTT ack window; ammo_cfc4 has no predicted decrement,
	// and gating it could strand the HUD C4 slot + plant animation at 0 whenever a
	// predicted weapon action was in flight just after a (re)spawn.
	self.ammo_cfc4 = sv_confirmed_ammo_cfc4;

	W_SlotAmmo_LoadCurrent(self);

	// Keep a single weapon action monotonic. Once local prediction is already
	// further through that same action, don't let a delayed server snapshot pull
	// it backwards and replay the tail of the animation.
	if (self.weapon == old_weapon
		&& self.wep_action_id == old_wep_action_id)
	{
		if (old_attack_finished > 0)
			self.attack_finished = min(self.attack_finished, old_attack_finished);

		// Only guard ammo for the active weapon — other weapons'
		// ammo must take server values (pickups change them).
		if (self.weapon == WEP_DEAGLE)
		{
			self.mag_deagle = max(self.mag_deagle, old_mag_deagle);
			self.ammo_deagle = min(self.ammo_deagle, old_ammo_deagle);
		}
		else if (self.weapon == WEP_AK47 || self.weapon == WEP_HDAK47)
		{
			self.mag_ak47 = max(self.mag_ak47, old_mag_ak47);
			self.ammo_ak47 = min(self.ammo_ak47, old_ammo_ak47);
		}
		else if (self.weapon == WEP_M4A1)
		{
			self.mag_m4a1 = max(self.mag_m4a1, old_mag_m4a1);
			self.ammo_m4a1 = min(self.ammo_m4a1, old_ammo_m4a1);
		}
		else if (self.weapon == WEP_FLAKSHOTGUN)
		{
			self.mag_flakshotgun = max(self.mag_flakshotgun, old_mag_flakshotgun);
		}
		else if (self.weapon == WEP_PISTOL)
		{
			self.mag_pistol = max(self.mag_pistol, old_mag_pistol);
			self.ammo_pistol = min(self.ammo_pistol, old_ammo_pistol);
		}
		else if (self.weapon == WEP_SCOUT)
		{
			self.mag_scout = max(self.mag_scout, old_mag_scout);
			self.ammo_scout = min(self.ammo_scout, old_ammo_scout);
		}
		else if (self.weapon == WEP_357)
		{
			self.mag_357 = max(self.mag_357, old_mag_357);
			self.ammo_357 = min(self.ammo_357, old_ammo_357);
		}
		else if (self.weapon == WEP_M249)
		{
			self.mag_m249 = max(self.mag_m249, old_mag_m249);
			self.ammo_m249 = min(self.ammo_m249, old_ammo_m249);
		}
		else if (self.weapon == WEP_CSAWP)
		{
			self.mag_awp = max(self.mag_awp, old_mag_awp);
			self.ammo_awp = min(self.ammo_awp, old_ammo_awp);
		}
		else if (self.weapon == WEP_DOD98K)
		{
			self.mag_98k = max(self.mag_98k, old_mag_98k);
			self.ammo_98k = min(self.ammo_98k, old_ammo_98k);
		}
		else if (self.weapon == WEP_HLSHOTGUN)
		{
			self.mag_shotgun = max(self.mag_shotgun, old_mag_shotgun);
			self.ammo_shotgun = min(self.ammo_shotgun, old_ammo_shotgun);
		}
		else if (self.weapon == WEP_CSM3)
		{
			self.mag_m3 = max(self.mag_m3, old_mag_m3);
			self.ammo_m3 = min(self.ammo_m3, old_ammo_m3);
		}
		else if (self.weapon == WEP_CSMP5)
		{
			self.mag_mp5 = max(self.mag_mp5, old_mag_mp5);
			self.ammo_mp5 = min(self.ammo_mp5, old_ammo_mp5);
		}
		else if (self.weapon == WEP_CROSSBOW)
		{
			self.mag_crossbow = max(self.mag_crossbow, old_mag_crossbow);
			self.ammo_crossbow = min(self.ammo_crossbow, old_ammo_crossbow);
		}
		else if (self.weapon == WEP_GRENADELAUNCHER)
		{
			self.mag_grenadelauncher = max(self.mag_grenadelauncher, old_mag_grenadelauncher);
		}
		else if (self.weapon == WEP_REBAR)
		{
			self.mag_rebar = max(self.mag_rebar, old_mag_rebar);
		}
		else if (self.weapon == WEP_GAUSS)
		{
			self.ammo_gauss = min(self.ammo_gauss, old_ammo_gauss);
		}
		else if (self.weapon == WEP_GLOCK)
		{
			self.mag_glock = max(self.mag_glock, old_mag_glock);
			self.ammo_glock = min(self.ammo_glock, old_ammo_glock);
		}
		else if (self.weapon == WEP_G3SG1)
		{
			self.mag_g3sg1 = max(self.mag_g3sg1, old_mag_g3sg1);
			self.ammo_g3sg1 = min(self.ammo_g3sg1, old_ammo_g3sg1);
		}
		else if (self.weapon == WEP_SNOWBALL)
		{
			self.ammo_snowball = min(self.ammo_snowball, old_ammo_snowball);
		}
		else if (self.weapon == WEP_CSHEGRENADE)
		{
			self.ammo_cshegrenade = min(self.ammo_cshegrenade, old_ammo_cshegrenade);
		}
		else if (self.weapon == WEP_CSFLASHBANG)
		{
			self.ammo_csflashbang = min(self.ammo_csflashbang, old_ammo_csflashbang);
		}
		else if (self.weapon == WEP_CSSMOKEGRENADE)
		{
			self.ammo_cssmokegrenade = min(self.ammo_cssmokegrenade, old_ammo_cssmokegrenade);
		}
		else if (self.weapon == WEP_PAINTBALL)
		{
			self.mag_paintball = max(self.mag_paintball, old_mag_paintball);
			self.ammo_paintball = min(self.ammo_paintball, old_ammo_paintball);
		}

		if (old_weaponstate == WS_IDLE && self.weaponstate != WS_IDLE)
		{
			self.weaponstate = WS_IDLE;
			self.wep_anim_start = 0;
		}
		else if (self.weaponstate != WS_IDLE
			&& self.weaponstate == old_weaponstate
			&& old_wep_anim_start > 0
			&& (self.wep_anim_start <= 0 || old_wep_anim_start < self.wep_anim_start))
		{
			self.wep_anim_start = old_wep_anim_start;
		}
	}
	W_SlotAmmo_SaveCurrent(self);
};

void() CSQC_ResetPresentationView =
{
	csqc_present_valid = FALSE;
	csqc_present_origin = '0 0 0';
	csqc_present_view_ofs = '0 0 0';
	csqc_present_ducking = 0;
};

void() CSQC_EnsurePredictedPlayer =
{
	if (predicted_player)
		return;

	predicted_player = spawn();
	predicted_player.hitcontentsmaski = CONTENTBITS_BOXSOLID;
	predicted_player.pm_movetype = PM_MOVETYPE_NORMAL;
	predicted_player.view_ofs = PM_VIEW_OFS;
	predicted_player.pm_jump_held = FALSE;
	predicted_player.pm_jump_msec = 0;
	predicted_player.pm_waterjumptime = 0;
	predicted_player.pm_in_duck = FALSE;
	predicted_player.pm_duck_msec = 0;
	predicted_player.pm_oldbuttons = 0;
	predicted_player.pm_timecarry = 0;
	predicted_player.pm_teleport_time = 0;
	predicted_player.pm_ladder_detach_time = 0;
	predicted_player.pm_fuser2 = 0;
	predicted_player.spread_penalty = 0;
	predicted_player.fire_spread_penalty = 0;
	predicted_player.pm_step_time = 0;

	predicted_player.slot_primary     = WEP_NONE;
	predicted_player.slot_secondary   = WEP_NONE;
	predicted_player.slot_melee       = WEP_NONE;
	predicted_player.slot_utility     = WEP_NONE;
	W_SlotAmmo_ClearSlots(predicted_player);
	predicted_player.previous_weapon  = WEP_NONE;
	predicted_player.weapon          = WEP_NONE;
	predicted_player.weaponstate     = WS_IDLE;
	predicted_player.wep_action_id   = 0;
	predicted_player.wep_anim_start  = 0;
	predicted_player.attack_finished = 0;
	// Fresh-entity init only — see comment on csqc_fire_effect_action_id
	// in sh_customdefs.qc.  Reconcile must NOT zero this; only the
	// rewind-detected respawn (cl_player.qc CSQC_Ent_Update where
	// wep_action_id goes backward) does.
	predicted_player.csqc_fire_effect_action_id = 0;
	predicted_player.mag_deagle      = 0;
	predicted_player.ammo_deagle     = 0;
	predicted_player.mag_ak47        = 0;
	predicted_player.ammo_ak47       = 0;
	predicted_player.mag_m4a1        = 0;
	predicted_player.ammo_m4a1       = 0;
	predicted_player.m4a1_silenced   = sv_confirmed_m4a1_silenced;
	predicted_player.mag_flakshotgun = 0;
	predicted_player.mag_pistol      = 0;
	predicted_player.ammo_pistol     = 0;
	predicted_player.mag_scout       = 0;
	predicted_player.ammo_scout      = 0;
	predicted_player.mag_357         = 0;
	predicted_player.ammo_357        = 0;
	predicted_player.mag_m249        = 0;
	predicted_player.ammo_m249       = 0;
	predicted_player.zoomstage       = 0;
	predicted_player.codstamina      = 1;
	predicted_player.codstamina_punished = 0;
	predicted_player.pm_fire_suppress_until = 0;
	predicted_player.pm_last_onground_time  = 0;
	predicted_player.ammo_snowball   = 0;
	predicted_player.ammo_cshegrenade = 0;
	predicted_player.ammo_csflashbang = 0;
	predicted_player.ammo_cssmokegrenade = 0;
	predicted_player.snowball_has_slingshot = FALSE;
	predicted_player.snowball_use_slingshot = FALSE;
	predicted_player.mag_awp         = 0;
	predicted_player.ammo_awp        = 0;
	predicted_player.mag_98k         = 0;
	predicted_player.ammo_98k        = 0;
	predicted_player.mag_shotgun     = 0;
	predicted_player.ammo_shotgun    = 0;
	predicted_player.mag_m3          = 0;
	predicted_player.ammo_m3         = 0;
	predicted_player.mag_mp5         = 0;
	predicted_player.ammo_mp5        = 0;
	predicted_player.mag_crossbow    = 0;
	predicted_player.ammo_crossbow   = 0;
	predicted_player.mag_grenadelauncher = 0;
	predicted_player.mag_rebar       = 0;
	predicted_player.ammo_gauss      = 0;
	predicted_player.mag_glock       = 0;
	predicted_player.ammo_glock      = 0;
	predicted_player.mag_g3sg1       = 0;
	predicted_player.ammo_g3sg1      = 0;
	predicted_player.mag_paintball   = 0;
	predicted_player.ammo_paintball  = 0;

	// Per-weapon predicted-throw bookkeeping. CS grenades guard the
	// fake-grenade local spawn against re-firing the same wep_action_id
	// (csgren_fake_spawned_serial). On respawn, wep_action_id resets to
	// 0 and increments from there, so a stale serial from before death
	// can collide with the new value and silently drop the spawn — the
	// throw animation plays but no fake grenade ever appears. Wiping the
	// pair here closes that hole.
	predicted_player.csgren_throw_pending       = 0;
	predicted_player.csgren_fake_spawned_serial = 0;
	predicted_player.csgren_spawn_time          = 0;
	predicted_player.csgren_throw_type          = 0;
	// Same fix for paintball-projectile fakes (sv_paintball_projectile 1).
	predicted_player.paintball_fake_spawned_serial = 0;
};

string() CSQC_DebugSeedSource =
{
	if (csqc_dbg_seed_source == 1)
		return "engine";
	if (csqc_dbg_seed_source == 2)
		return "proxy";
	return "none";
};

float() CSQC_SeedPredictedPlayerFromEngine =
{
	entity engine_player;

	engine_player = CSQC_GetEngineLocalPlayer();
	localplayer = engine_player;
	if (!engine_player)
		return FALSE;

	CSQC_EnsurePredictedPlayer();

	setorigin(predicted_player, engine_player.origin);
	predicted_player.velocity = engine_player.velocity;
	predicted_player.view_ofs = engine_player.view_ofs;
	predicted_player.flags = engine_player.flags;
	predicted_player.pm_movetype = PM_MOVETYPE_NORMAL;
	predicted_player.pm_jump_held = FALSE;
	predicted_player.pm_jump_msec = 0;
	predicted_player.pm_waterjumptime = 0;
	predicted_player.pm_in_duck = FALSE;
	predicted_player.pm_duck_msec = 0;
	predicted_player.pm_oldbuttons = input_buttons;
	predicted_player.pm_timecarry = 0;
	predicted_player.pm_teleport_time = 0;
	predicted_player.pm_ladder_detach_time = 0;
	predicted_player.pm_fuser2 = 0;
	predicted_player.spread_penalty = 0;
	predicted_player.fire_spread_penalty = 0;
	predicted_player.pm_step_time = 0;
	if (!predicted_player.view_ofs_x && !predicted_player.view_ofs_y && !predicted_player.view_ofs_z)
		predicted_player.view_ofs = PM_VIEW_OFS;

	// Set initial hull size
	{
		entity save = self;
		self = predicted_player;
		PM_SyncHull();
		self = save;
	}

	predicted_player.slot_primary     = WEP_NONE;
	predicted_player.slot_secondary   = WEP_NONE;
	predicted_player.slot_melee       = WEP_NONE;
	predicted_player.slot_utility     = WEP_NONE;
	predicted_player.previous_weapon  = WEP_NONE;
	predicted_player.weapon          = engine_player.weapon;
	predicted_player.weaponstate     = WS_IDLE;
	predicted_player.wep_action_id   = 0;
	predicted_player.wep_anim_start  = 0;
	predicted_player.attack_finished = 0;
	predicted_player.csqc_fire_effect_action_id = 0;
	// CS-grenade fake-spawn bookkeeping. Same fix as CSQC_EnsurePredictedPlayer
	// (see comment there): without this, post-respawn throws can silently
	// drop the local fake-grenade spawn when the new wep_action_id collides
	// with the stale csgren_fake_spawned_serial from before death.
	predicted_player.csgren_throw_pending       = 0;
	predicted_player.csgren_fake_spawned_serial = 0;
	predicted_player.csgren_spawn_time          = 0;
	predicted_player.csgren_throw_type          = 0;
	predicted_player.paintball_fake_spawned_serial = 0;
	{
		entity old_self = self;
		self = predicted_player;
		CSQC_WeaponEquip(self.weapon);
		self = old_self;
	}
	predicted_player.mag_deagle      = 0;
	predicted_player.ammo_deagle     = 0;

	csqc_prediction_valid = TRUE;
	csqc_dbg_seed_source = 1;
	return TRUE;
};

void() CSQC_ResetPredictionState =
{
	if (predicted_player)
	{
		remove(predicted_player);
		predicted_player = world;
	}

	localplayer = world;
	csqc_authority_proxy = world;
	csqc_prediction_valid = FALSE;
	csqc_baseline_valid = FALSE;
	csqc_proxy_seen = FALSE;
	csqc_proxy_entnum = 0;
	csqc_present_valid = FALSE;
	csqc_present_origin = '0 0 0';
	csqc_present_view_ofs = '0 0 0';
	csqc_present_ducking = 0;
	csqc_live_forward = FALSE;
	csqc_live_back = FALSE;
	csqc_live_left = FALSE;
	csqc_live_right = FALSE;
	csqc_live_up = FALSE;
	csqc_live_down = FALSE;
	csqc_live_buttons = 0;
	csqc_dbg_last_key_time = cltime;
	csqc_dbg_last_inputframe_time = cltime;
	csqc_dbg_last_snapshot_time = cltime;
	csqc_dbg_last_reconcile_time = cltime;
	csqc_dbg_last_present_time = cltime;
	csqc_dbg_last_preview_response_ms = 0;
	csqc_dbg_last_predict_response_ms = 0;
	csqc_dbg_last_preview_dt = 0;
	csqc_dbg_last_predict_dt = 0;
	csqc_dbg_probe_pending = FALSE;
	csqc_dbg_preview_responded = FALSE;
	csqc_dbg_predict_responded = FALSE;
	csqc_dbg_seed_source = 0;
	csqc_last_predicted_weapon_sound_time = 0;
	csqc_last_predicted_auto_sound_time = 0;
	csqc_pred_sequence = 0;
	csqc_weapon_pending_ack_sequence = 0;
	CSQC_ClearPredictionBuffer();
	CSQC_ResetPresentationView();

	// Wipe in-flight CS grenade state — fake projectiles, residual
	// flashbang blindness, and the ringing sound entity — so a flash
	// that detonated just before death doesn't bleed past respawn.
	CSQC_ResetCSGrenadeState();
};

void() CSQC_CheckDebugPredictResponse =
{
	float dist2d;
	vector delta;

	if (!csqc_dbg_probe_pending || !predicted_player || csqc_dbg_predict_responded)
		return;

	delta = predicted_player.origin - csqc_dbg_probe_start_origin;
	dist2d = vlen([delta_x, delta_y, 0]);

	if (dist2d > 0.05 || fabs(predicted_player.velocity_z) > 1)
	{
		csqc_dbg_predict_responded = TRUE;
		csqc_dbg_last_predict_response_ms = (cltime - csqc_dbg_probe_start_time) * 1000;
		if (csqc_dbg_preview_responded)
			csqc_dbg_probe_pending = FALSE;
	}
};

void() CSQC_CheckDebugPreviewResponse =
{
	float dist2d;
	vector delta;

	if (!csqc_dbg_probe_pending || !csqc_present_valid || csqc_dbg_preview_responded)
		return;

	delta = csqc_present_origin - csqc_dbg_probe_start_origin;
	dist2d = vlen([delta_x, delta_y, 0]);

	if (dist2d > 0.05 || (csqc_present_origin_z - csqc_dbg_probe_start_origin_z) > 0.05)
	{
		csqc_dbg_preview_responded = TRUE;
		csqc_dbg_last_preview_response_ms = (cltime - csqc_dbg_probe_start_time) * 1000;
		if (csqc_dbg_predict_responded)
			csqc_dbg_probe_pending = FALSE;
	}
};

// ---------------------------------------------------------------------------
//  Command buffer storage and replay
// ---------------------------------------------------------------------------

void(float seq) CSQC_BufferInputCommand =
{
	float slot;
	float was_same_sequence;

	seq = CSQC_CommandSequence(seq);

	// Sequence numbers should be monotonic; if they jump backwards we are in a
	// new session/map and the old ring contents are no longer usable.
	if (pred_cmd_count && seq < pred_cmd_latest_sequence)
		CSQC_ClearPredictionBuffer();

	slot = CSQC_CommandSlot(seq);

	was_same_sequence = pred_cmd_valid[slot] && pred_cmd_sequence[slot] == seq;
	if (!was_same_sequence)
	{
		if (pred_cmd_count >= PRED_CMD_BACKUP)
			csqc_dbg_ring_overflowed = TRUE;
		pred_cmd_count = min(pred_cmd_count + 1, PRED_CMD_BACKUP);
	}

	pred_cmd_valid[slot]      = TRUE;
	pred_cmd_sequence[slot]   = seq;
	pred_cmd_timestamp[slot]  = cltime;
	pred_cmd_timelength[slot] = input_timelength;
	pred_cmd_angles[slot]     = input_angles;
	pred_cmd_movevalues[slot] = input_movevalues;
	pred_cmd_buttons[slot]    = input_buttons;
	pred_cmd_impulse[slot]    = input_impulse;

	pred_cmd_latest_sequence = seq;
};

float(float first_sequence, float replay_weapons) CSQC_ReplayBufferedCommands =
{
	float replay_count;
	float seq;
	float slot;

	replay_count = 0;

	if (!pred_cmd_count)
		return 0;

	first_sequence = CSQC_CommandSequence(first_sequence);
	first_sequence = max(first_sequence, CSQC_FirstBufferedSequence());

	for (seq = first_sequence; seq <= pred_cmd_latest_sequence; seq++)
	{
		slot = CSQC_FindBufferedCommand(seq);
		if (slot < 0)
			break;

		CSQC_LoadBufferedCommand(slot);
		CSQC_ClampMoveInputs();
		csqc_pred_sequence = pred_cmd_sequence[slot];
		csqc_pred_time = pred_cmd_timestamp[slot];
		// Weapon impulse first, then pmove — mirrors server order
		// (PlayerPreThink runs CheckImpulses BEFORE PM_Move). See live-tick
		// note in CSQC_PredictCurrentCommand for the full rationale.
		if (replay_weapons)
			CSQC_PredictWeaponCommand();
		PM_PlayerMove();
		// sv_gunkick: tick the spring decay once per replay step
		// (post-fire, post-pmove). Mirrors live-tick path so replay
		// and live integrate the spring identically.
		if (replay_weapons)
			SH_TickViewKickFrame();
		// Replay tick — DO NOT append to drift ring. Replay re-runs every
		// render frame (potentially 100+ Hz) and would overwrite the ring
		// instantly. Live tick capture is what we compare against the
		// server, so the replay's per-tick details aren't needed in the
		// trace. The final post-replay state IS already the next live tick's
		// starting state.
		replay_count += 1;
	}

	return replay_count;
};

void() CSQC_ReconcilePrediction =
{
	float ack_sequence;
	float ack_slot;
	float first_buffered;
	float replay_from;
	float saved_buttons;
	float saved_impulse;
	float saved_timelength;
	float weapon_ack_ok;
	vector saved_angles;
	vector saved_movevalues;

	if (!csqc_baseline_valid)
		return;

	CSQC_EnsurePredictedPlayer();

	// Smoothing diagnostics — reconcile fires once per authoritative
	// snapshot, so the time between calls is the snapshot inter-arrival
	// interval.  Skip the first (no prior timestamp) and push ms.
	if (smooth_last_snap_cltime > 0)
		Smooth_Push(SMOOTH_M_SNAP, (cltime - smooth_last_snap_cltime) * 1000);
	smooth_last_snap_cltime = cltime;

	entity saved = self;
	self = predicted_player;

	// Capture predicted origin BEFORE reset-to-confirmed + replay so the
	// final post-replay origin can be diffed: that delta is the visible
	// "reconcile correction" that yanks the view if prediction drifted.
	smooth_pre_reset_origin = self.origin;

	// Duck-completion in PM_CheckDuck snaps origin Z by 18qu (PM_MINS_z -
	// PM_DUCK_MINS_z) when FL_DUCKING toggles.  If the original prediction
	// crossed the duck-completion threshold at one sub-step and the replay
	// crosses it at a different sub-step, pre vs post differ by ~18qu in Z
	// — that is a deterministic state transition, NOT prediction drift the
	// smoother should fade out.  Capture the pre-reset duck flag so the
	// err computation below can exclude the Z component when this happens.
	// Symptom otherwise: at 300 tick the camera/body dips 18qu into the
	// ground for a render frame after each duck-press, until smooth offset
	// decays.
	float pre_reset_ducking = (self.flags & FL_DUCKING) != 0;

	saved_timelength = input_timelength;
	saved_angles = input_angles;
	saved_movevalues = input_movevalues;
	saved_buttons = input_buttons;
	saved_impulse = input_impulse;

	ack_sequence = CSQC_CommandSequence(sv_confirmed_cmdframe);
	ack_slot = CSQC_FindBufferedCommand(ack_sequence);
	replay_from = ack_sequence + 1;
	first_buffered = CSQC_FirstBufferedSequence();

	csqc_dbg_ack_fell_out = FALSE;
	if (pred_cmd_count && ack_slot < 0)
	{
		if (ack_sequence < first_buffered - 1)
			csqc_dbg_ack_fell_out = TRUE;
		else if (ack_sequence >= first_buffered && ack_sequence <= pred_cmd_latest_sequence)
			csqc_dbg_ack_fell_out = TRUE;
	}

	// The proxy reconstructed attack_finished and wep_anim_start relative
	// to cltime at receive-time, but replayed commands use their original
	// buffered timestamps (pred_cmd_timestamp[]).  At high ping, cltime is
	// far ahead of the ack'd command's timestamp, so replayed elapsed
	// values come out negative and weapon-state transitions never fire.
	// Shift both timestamps back to the ack'd command's time domain so
	// replay produces correct positive elapsed values.
	if (ack_slot >= 0)
	{
		float time_offset = cltime - pred_cmd_timestamp[ack_slot];
		sv_confirmed_attack_finished -= time_offset;
		if (sv_confirmed_wep_anim_start > 0)
			sv_confirmed_wep_anim_start -= time_offset;
	}

	weapon_ack_ok = (csqc_weapon_pending_ack_sequence <= 0
		|| ack_sequence >= csqc_weapon_pending_ack_sequence);

	if (weapon_ack_ok)
	{
		CSQC_ResetToConfirmedState();
		csqc_weapon_pending_ack_sequence = 0;
	}
	else
	{
		CSQC_ResetToConfirmedMoveState();
	}

	if (ack_slot < 0)
		replay_from = max(replay_from, first_buffered);

	csqc_dbg_last_replay_from = replay_from;
	pm_suppress_sounds = TRUE;
	csqc_dbg_last_replay_count = CSQC_ReplayBufferedCommands(replay_from, weapon_ack_ok);
	pm_suppress_sounds = FALSE;

	// The replay uses buffered command timestamps, so attack_finished may
	// end up in the past relative to cltime.  Clamp it forward so the live
	// prediction in CSQC_PredictCurrentCommand doesn't re-fire on stale
	// timing and produce a double sound.
	if (weapon_ack_ok && self.attack_finished < cltime)
		self.attack_finished = cltime;

	csqc_dbg_last_reconcile_time = cltime;
	csqc_dbg_seed_source = 2;

	// Smoothing — reconcile correction magnitude.  Replay should
	// reproduce the same end origin as the extrapolation chain if
	// prediction matched server; any delta is the visible yank.
	Smooth_Push(SMOOTH_M_RECONC, vlen(self.origin - smooth_pre_reset_origin));

	// Capture the post-replay error and stash it on predicted_player so
	// CSQC_BuildPresentationView can fade it out of the rendered camera
	// origin over cl_extrap_smooth_time.  Without this, every reconcile
	// snaps the view by however much the replay drifted from live
	// prediction — at high ping this lands as a steady push in the
	// movement direction.  Same shape as the remote-proxy path
	// (cl_player.qc:2614-2622).
	{
		vector err  = smooth_pre_reset_origin - self.origin;   // pre - post (cumulative)

		// Duck-transition Z-step filter: see comment at pre_reset_ducking
		// capture.  If the duck flag flipped during reconcile, zero err.z
		// so the 18qu state-transition step does not enter the smoother.
		float post_reset_ducking = (self.flags & FL_DUCKING) != 0;
		if (pre_reset_ducking != post_reset_ducking)
			err_z = 0;

		// Moving-platform Z-step filter.  CSQC pmove already predicts
		// platform carry locally (sh_pmove.qc:3024-3048 for doors,
		// sh_pmove.qc:2741+ for trains) and sets self.platform_carry =
		// rb on each substep the player is riding a moving brush.  But
		// the server runs Mover_PlatformCarry at sv_func_tickrate (40 Hz
		// default) while CSQC integrates velocity * pm_frametime per
		// substep — the two paths integrate to *almost* the same total
		// over the same interval, but timing drift around door
		// pause/reverse events leaves a small per-reconcile Z delta.
		// That delta drives the smoother's fade-to-server-position,
		// which is visually fine when standing still (lock branch
		// keeps the camera at pre-reset) but visually awful when
		// strafing — the smoother branch fades the Z error each cycle
		// and the player view drifts into the floor (descending plat)
		// or sky (rising plat) until the brush stops.  Zero err.z when
		// carried so only XY drift enters the smoother; the per-tick
		// Z snap is small (~1.5 qu) and the next pmove cycle already
		// matches server within prediction tolerance.
		if (self.platform_carry != world)
			err_z = 0;

		// Rotating-brush contact filter.  PM_CheckRotatingCarry sets
		// self.rotcarry_active_cltime = cltime whenever Phase 1 (on
		// brush) or Phase 3 (ground player swept by mesh) runs.  Like
		// the platform_carry filter above, but rotators move players
		// in arbitrary directions (XY for yaw axis, YZ for pitch, XZ
		// for roll), so zero the FULL err vector — not just Z — to
		// stop the smoother from fading the per-substep / per-tick
		// rate-mismatch into visible "push then snap back" jitter.
		// 100 ms staleness window: by then the player has left
		// rotator contact and the normal smoother resumes.
		if (self.rotcarry_active_cltime > 0
		    && cltime - self.rotcarry_active_cltime < 0.1)
			err = '0 0 0';

		// Linear-mover push contact filter.  Same shape as the
		// rotating filter above: PM_CheckMovingPushers door branch
		// sets self.mover_push_active_cltime whenever the geometry
		// push fires (player being shoved sideways by a door, but
		// not standing ON it — so platform_carry isn't set).  Zero
		// err so the smoother doesn't fade the small per-substep /
		// per-tick rate-mismatch, which otherwise compounds across
		// reconciles into the user-reported "drift up to 24qu" /
		// "player sinks into the door" visual.
		if (self.mover_push_active_cltime > 0
		    && cltime - self.mover_push_active_cltime < 0.1)
			err = '0 0 0';

		float  elen = vlen(err);

		// Per-reconcile authoritative-position delta.  This is how much
		// the server's view of the player advanced THIS snapshot, which
		// cleanly separates "server is gradually catching up to a stopped
		// player" (small steady delta) from "user got shoved" (one big
		// delta in a single snapshot).  The lock gates on this rather
		// than on `elen` (cumulative) so a long walk-stop catch-up
		// window can't accumulate divergence past a fixed cap and
		// trigger the smoother fallback as a visible bump.
		//
		// '0 0 0' init means we have no previous reference — first
		// reconcile sees per_recon_len = 0 and the lock can apply if
		// otherwise eligible.
		float per_recon_len;
		if (smooth_prev_post_origin == '0 0 0')
			per_recon_len = 0;
		else
			per_recon_len = vlen(self.origin - smooth_prev_post_origin);

		// Capture the post-replay origin BEFORE any restore — we want
		// `smooth_prev_post_origin` to track where the server thinks
		// the player is, not where we locked the camera to.
		smooth_prev_post_origin = self.origin;

		// Read directly from CSQC's keyboard-event-driven live latches.
		// These are updated by CSQC_UpdateLiveInputFromBind on actual
		// key press/release ONLY — they're never clobbered by the
		// engine's replay path the way input_movevalues / saved_*
		// can be.  At >300 ms ping the engine fires several replay
		// passes between input frames and saved_movevalues snapshots
		// the LAST replayed buffered command's value, which made the
		// smoother briefly read "released" while the user was holding
		// a key (lock toggled off → fade fired → oscillation).
		float live_wants_motion = (csqc_live_forward
		                        || csqc_live_back
		                        || csqc_live_left
		                        || csqc_live_right
		                        || csqc_live_up
		                        || csqc_live_down
		                        || (csqc_live_buttons & PM_BTN_JUMP) != 0);

		// Lock state: hold camera at live trajectory unless the user is
		// actively walking on the ground.  In the air (FL_ONGROUND clear)
		// the lock STAYS engaged regardless of input — keeps the parabolic
		// jump/fall trajectory stable through reconciles instead of
		// letting the smoother fade re-trigger every snapshot.  Only when
		// grounded AND pressing a movement key do we let the fade take
		// over; that's the case where the camera should track the
		// bleeding-edge predicted position responsively.
		float on_ground          = (self.flags & FL_ONGROUND) != 0;
		float walking_on_ground  = on_ground && live_wants_motion;

		if (cvar("cl_debug_driftlock"))
			dprint(sprintf("[smooth_local] reconcile elen=%.3f dpost=%.3f wants_motion=%g grounded=%g pre=%v post=%v\n",
				elen, per_recon_len, live_wants_motion, on_ground,
				smooth_pre_reset_origin, self.origin));

		// Expose live values to cl_debug_drift overlay.  lock_active
		// will be set to 1 below if the lock branch fires; default 0.
		smooth_local_dbg_elen           = elen;
		smooth_local_dbg_dpost          = per_recon_len;
		smooth_local_dbg_wants_motion   = live_wants_motion;
		smooth_local_dbg_lock_active    = 0;
		smooth_local_dbg_last_reconcile = cltime;

		const float LOCAL_SMOOTH_MIN     = 0.05;
		const float LOCAL_SMOOTH_MAXJUMP = 32.0;

		// Mover contact override: the lock branch below holds the
		// camera at the pre-reset origin (effectively reverting the
		// replay-applied carry / slide) whenever the user isn't
		// pressing movement keys.  That suppresses the visible motion
		// when a moving brush carries / pushes / sweeps into a
		// stationary player — symptoms include "door opens through
		// me then snap" (rotating Phase 3), "player floats above the
		// floor after func_door arrival snap" (linear platform_carry),
		// and "drift builds up to 24qu, player sinks into the door"
		// (linear geometry push).  Skip the lock whenever any mover
		// is acting on the player:
		//   - rotcarry_active_cltime: written by PM_CheckRotatingCarry
		//     on each substep of Phase 1 or Phase 3 contact.
		//   - platform_carry: set by PM_CheckMovingPushers (or
		//     server-side Mover_PlatformCarry) while the player is
		//     riding a linear func_door / func_train / func_tracktrain.
		//   - mover_push_active_cltime: written by PM_CheckMovingPushers's
		//     door geometry-push branch when the player is being shoved
		//     by a brush they're NOT standing on.
		// 100 ms staleness windows match the err-zero filters above so
		// they engage / disengage together.
		float rotcarry_active = (self.rotcarry_active_cltime > 0
		                         && cltime - self.rotcarry_active_cltime < 0.1);
		float push_active     = (self.mover_push_active_cltime > 0
		                         && cltime - self.mover_push_active_cltime < 0.1);
		float carry_active    = (self.platform_carry != world);

		if (!walking_on_ground && elen <= LOCAL_SMOOTH_MAXJUMP
		    && cvar("cl_driftlock")
		    && !rotcarry_active && !carry_active && !push_active)
		{
			smooth_local_dbg_lock_active = 1;
			// User has released keys.  Hold camera at live trajectory
			// regardless of dpost magnitude or cumulative elen — both
			// the steady catch-up tail (small dpost) and the subframe-
			// quantization bursts within it (occasional dpost spikes)
			// are server-side artifacts of physics that live prediction
			// already played out locally.  None of them is information
			// the user wants to see act on the camera while standing
			// still.
			//
			// Trade-off: small external pushes (< 32 qu cumulative)
			// from teammates walking into the player won't be visible
			// until the user next presses a movement key — at which
			// point the smoother branch below picks up the accumulated
			// offset and fades it over a long smooth_time so the
			// release isn't perceived as a bump.  Real teleports /
			// respawns (> 32 qu) bypass this branch into the snap path.
			// Rotating-door / fan pushes bypass via rotcarry_active.
			setorigin(self, smooth_pre_reset_origin);
			self.extrap_error_offset      = '0 0 0';
			self.extrap_error_cltime      = 0;
			self.extrap_error_smooth_time = 0;
		}
		else if (elen > LOCAL_SMOOTH_MIN && elen <= LOCAL_SMOOTH_MAXJUMP)
		{
			// Smoother — used during active motion AND when the lock
			// releases (user just started moving after a stop with
			// accumulated server-vs-live drift).
			//
			// Pick smooth_time based on err magnitude AND player
			// velocity:
			//
			//   small err (< 1 qu) — steady-state structural lag in
			//       active motion.  Use cvar default (~31 ms) so the
			//       camera tracks the bleeding-edge prediction
			//       responsively.
			//
			//   large err (>= 1 qu) — almost certainly a lock release
			//       carrying accumulated catch-up drift.  The fade
			//       pull rate visible on the camera is err / fade_time,
			//       which previously landed at e.g. 50 qu/s for a
			//       10 qu err over 0.2 s.  At slow walk speeds (60
			//       qu/s), that's a noticeable yank.  Scale fade_time
			//       so the visible pull rate is ~20 % of the player's
			//       current speed (so the correction is subordinate to
			//       the user's own motion).  Floored at 30 qu/s pull
			//       rate so fades complete reasonably even at rest.
			float smooth_time;
			if (elen >= 1.0)
			{
				float vel_mag   = vlen(self.velocity);
				float pull_rate = max(30, vel_mag * 0.2);
				smooth_time = elen / pull_rate;
				smooth_time = bound(0.15, smooth_time, 1.5);
			}
			else
			{
				smooth_time = cvar("cl_extrap_smooth_time");
				if (smooth_time <= 0) smooth_time = 0.1;
			}

			// Continuity preservation against any in-flight previous
			// offset (active-motion overlapping reconciles).  Use the
			// PREVIOUS capture's stored smooth_time for the visible-
			// tail calculation so the decay math matches what the
			// helper has been applying.
			if (self.extrap_error_cltime > 0
			    && self.extrap_error_smooth_time > 0)
			{
				float age = cltime - self.extrap_error_cltime;
				if (age >= 0 && age < self.extrap_error_smooth_time)
				{
					float decay = 1.0 - (age / self.extrap_error_smooth_time);
					err = err + self.extrap_error_offset * decay;
				}
			}
			self.extrap_error_offset      = err;
			self.extrap_error_cltime      = cltime;
			self.extrap_error_smooth_time = smooth_time;
		}
		else if (elen > LOCAL_SMOOTH_MAXJUMP)
		{
			// Teleport / respawn — clear so the camera follows the
			// real warp instead of fading 32+ qu over smooth_time.
			self.extrap_error_offset      = '0 0 0';
			self.extrap_error_cltime      = 0;
			self.extrap_error_smooth_time = 0;
			smooth_local_dbg_last_snap = cltime;
		}
		// elen <= LOCAL_SMOOTH_MIN: noise floor, no action.
	}

	input_timelength = saved_timelength;
	input_angles     = saved_angles;
	input_movevalues = saved_movevalues;
	input_buttons    = saved_buttons;
	input_impulse    = saved_impulse;

	self = saved;
};

void() CSQC_PredictCurrentCommand =
{
	if (!csqc_prediction_valid)
	{
		if (!CSQC_SeedPredictedPlayerFromEngine())
			return;
	}

	CSQC_EnsurePredictedPlayer();

	entity saved = self;
	self = predicted_player;

	csqc_pred_sequence = clientcommandframe;
	csqc_pred_time = cltime;

	// Weapon impulse runs BEFORE pmove to mirror the server. SSQC processes
	// CheckImpulses inside PlayerPreThink (sv_player.qc:584) which fires
	// before the engine's PM_Move, so the switch-tick on the server already
	// uses the new weapon's speed factor in pmove. If we ran pmove first
	// here, the switch-tick would use the OLD speed factor on the client and
	// the new one on the server — that 1-tick divergence becomes a position
	// jump after every reconcile at high ping (heavier weapon → snap back,
	// lighter weapon → snap forward).
	CSQC_PredictWeaponCommand();
	PM_PlayerMove();
	// sv_gunkick: decay tick runs AFTER fire so the bullet trace
	// (inside CSQC_PredictWeaponCommand) used pre-decay pitch.
	// SSQC's PlayerPostThink does the same, ensuring both sides
	// advance the spring once per frame at the same logical point.
	SH_TickViewKickFrame();
	if (cvar("sv_debug_wepswap"))
	{
		vector dbg_mv = '0 0 0';
		dbg_mv_x = input_movevalues_x; dbg_mv_y = input_movevalues_y;
		CL_Drift_Append(cltime, csqc_pred_sequence, input_timelength * 1000,
			dbg_mv, input_buttons, self.weapon, self.origin, self.velocity);
	}
	CSQC_CheckPickupTouches();   // MVP weapon-pickup prediction — self is predicted_player
	csqc_dbg_last_predict_dt = (cltime - csqc_dbg_last_key_time) * 1000;
	CSQC_CheckDebugPredictResponse();

	self = saved;
};

// Add the still-decaying reconcile-error offset to `base` so the rendered
// camera position lands smoothly at the post-replay predicted position
// instead of jumping the full reconcile delta in one frame.  Returns the
// adjusted origin.  Mirrors the remote-proxy decay in CSQC_SmoothSetOrigin
// (cl_player.qc:1584-1611).  Gated by cl_driftlock — set 0 to A/B
// against the old snap behaviour.
vector(vector base) CSQC_ApplyLocalSmoothOffset =
{
	if (cvar_string("cl_driftlock") != "" && !cvar("cl_driftlock"))
		return base;
	if (!predicted_player || predicted_player.extrap_error_cltime <= 0)
		return base;

	// Read the smooth_time that was chosen at offset-capture time.
	// CSQC_ReconcilePrediction velocity-scales it for large errs so slow
	// walks see slower fades — recomputing here would diverge if the
	// player's velocity changed mid-fade.  Fall back to cvar default if
	// no stored value (e.g. legacy state before this field existed).
	float smooth_time = predicted_player.extrap_error_smooth_time;
	if (smooth_time <= 0)
	{
		smooth_time = cvar("cl_extrap_smooth_time");
		if (smooth_time <= 0) smooth_time = 0.1;
	}

	float age = cltime - predicted_player.extrap_error_cltime;
	if (age >= 0 && age < smooth_time)
	{
		float decay = 1.0 - (age / smooth_time);
		return base + predicted_player.extrap_error_offset * decay;
	}

	// Decay finished — clear so the next reconcile starts a fresh
	// timer, instead of inheriting a zero-but-nonzero-cltime entry.
	predicted_player.extrap_error_offset      = '0 0 0';
	predicted_player.extrap_error_cltime      = 0;
	predicted_player.extrap_error_smooth_time = 0;
	return base;
};

// func_vehicle camera seat-lock state (local driver only).
vector veh_seat_local;     // driver's offset from the car, in the car's local frame (captured at mount)
float  veh_seat_captured;  // 1 once veh_seat_local is valid for the current drive
entity veh_seat_car;       // the vehicle we're locked to (held through flaky carry frames so the camera never falls back to the stale predicted position)

void() CSQC_BuildPresentationView =
{
	float elapsed;
	float preview_time;
	float slot;
	float saved_buttons;
	float saved_timelength;
	float saved_flags;
	float saved_jump_held;
	float saved_jump_msec;
	float saved_movetype;
	float saved_waterjumptime;
	float saved_in_duck;
	float saved_duck_msec;
	float saved_oldbuttons;
	float saved_timecarry;
	float saved_teleport_time;
	float saved_ladder_detach_time;
	float saved_fuser2;
	float saved_spread_penalty;
	float saved_fire_spread_penalty;
	float saved_step_time;
	float saved_slide_friction_active;
	float saved_jump_groundstick;
	float saved_pm_on_ladder_cached;
	float saved_impulse;
	vector saved_origin;
	vector saved_velocity;
	vector saved_view_ofs;
	vector saved_angles;
	vector saved_movevalues;
	// Platform-carry tracking state — saved so the preview pmove's
	// writes to platform_carry_prev_yaw / platform_carry latches don't
	// leak forward into the next real pmove (preview can advance
	// brush yaw / velocity past the next real-command timestamp,
	// which would make the real pmove see only the residual delta and
	// drop the rest — visible as drift/jitter while riding a train).
	entity saved_platform_carry;
	vector saved_platform_carry_velocity;
	float  saved_platform_carry_prev_yaw;
	vector saved_platform_carry_jump_origin_consumed;
	float  saved_platform_carry_jump_yaw_consumed;

	CSQC_ResetPresentationView();

	if (!predicted_player || !csqc_prediction_valid)
		return;

	csqc_present_valid = TRUE;
	csqc_present_origin = CSQC_ApplyLocalSmoothOffset(predicted_player.origin);
	csqc_present_view_ofs = predicted_player.view_ofs;
	csqc_present_ducking = (predicted_player.flags & FL_DUCKING) != 0;

	// func_vehicle: PIN the driver's presentation origin to the car on EVERY
	// frame — BEFORE the preview early-returns below.  The previous override sat
	// AFTER those returns, so any frame that early-returned (no buffered cmd /
	// tiny preview_time) left csqc_present_origin at the stale predicted body
	// (the "+use mount" spot) while full frames snapped it to the car → the
	// camera flickered between the two.  Computing it here, once, from the car's
	// render extrapolation kills the flicker: the fragile pmove down-trace no
	// longer affects rendering, and veh_seat_car is held across momentary carry
	// drops so the lock never falls back.  (cl_vehicle_seatlock 0 disables.)
	if (predicted_player.pm_driving && cvar("cl_vehicle_seatlock"))
	{
		entity dcar = predicted_player.platform_carry;
		if (dcar == world || dcar.brush_type != BRUSH_TYPE_VEHICLE)
			dcar = veh_seat_car;
		if (dcar != world)
		{
			veh_seat_car = dcar;
			// Match the car's predraw origin extrapolation (cl_brushsync.qc)
			// EXACTLY so the camera sits where the car is RENDERED this frame.
			float dla = cvar("cl_brushsync_lookahead"); if (dla < 0) dla = 0;
			float delp = cltime - dcar.csqc_snap_time;
			if (delp < 0)   delp = 0;
			if (delp > dla) delp = dla;
			vector dorg = dcar.csqc_snap_origin + dcar.velocity * delp;
			if (!veh_seat_captured)
			{
				veh_seat_local_z = predicted_player.origin_z - dorg_z;   // eye height above the car
				veh_seat_captured = 1;
			}
			csqc_present_origin_x = dorg_x;
			csqc_present_origin_y = dorg_y;
			csqc_present_origin_z = dorg_z + veh_seat_local_z;
			csqc_present_view_ofs = predicted_player.view_ofs;
			return;   // car-locked every frame; skip the preview pmove entirely
		}
	}
	else
	{
		veh_seat_car = world;
		veh_seat_captured = 0;
	}

	if (!pred_cmd_count)
		return;

	slot = CSQC_FindBufferedCommand(pred_cmd_latest_sequence);
	if (slot < 0)
		return;

	elapsed = max(cltime - pred_cmd_timestamp[slot], 0);
	preview_time = predicted_player.pm_timecarry + elapsed;
	preview_time = min(preview_time, 0.05);

	if (preview_time <= PM_FIXEDSTEP_EPSILON)
		return;

	entity saved = self;
	self = predicted_player;

	saved_origin = self.origin;
	saved_velocity = self.velocity;
	saved_view_ofs = self.view_ofs;
	saved_flags = self.flags;
	saved_movetype = self.pm_movetype;
	saved_jump_held = self.pm_jump_held;
	saved_jump_msec = self.pm_jump_msec;
	saved_waterjumptime = self.pm_waterjumptime;
	saved_in_duck = self.pm_in_duck;
	saved_duck_msec = self.pm_duck_msec;
	saved_oldbuttons = self.pm_oldbuttons;
	saved_timecarry = self.pm_timecarry;
	saved_teleport_time = self.pm_teleport_time;
	saved_ladder_detach_time = self.pm_ladder_detach_time;
	saved_fuser2 = self.pm_fuser2;
	saved_spread_penalty = self.spread_penalty;
	saved_fire_spread_penalty = self.fire_spread_penalty;
	saved_step_time = self.pm_step_time;
	saved_slide_friction_active = self.slide_friction_active;
	saved_jump_groundstick = self.pm_jump_groundstick_off_until;
	saved_pm_on_ladder_cached = self.pm_on_ladder_cached;
	saved_platform_carry                      = self.platform_carry;
	saved_platform_carry_velocity             = self.platform_carry_velocity;
	saved_platform_carry_prev_yaw             = self.platform_carry_prev_yaw;
	saved_platform_carry_jump_origin_consumed = self.platform_carry_jump_origin_consumed;
	saved_platform_carry_jump_yaw_consumed    = self.platform_carry_jump_yaw_consumed;

	saved_timelength = input_timelength;
	saved_angles = input_angles;
	saved_movevalues = input_movevalues;
	saved_buttons = input_buttons;
	saved_impulse = input_impulse;

	input_angles = view_angles;
	input_movevalues = CSQC_BuildLiveMoveValues();
	input_buttons = csqc_live_buttons;
	input_impulse = 0;
	CSQC_ClampMoveInputs();

	// Freeze time: the buffered command was zeroed by CSQC_Input_Frame, but
	// this render-rate preview sim reads live WASD directly.  Without this
	// mirror, a single preview step produces ~1 frame of visible motion
	// before the next tick's reconcile snaps it back — looks like a server
	// correction but is a local bypass.
	if (getstatf(STAT_ROUND_PHASE) == ROUND_PHASE_FREEZE)
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
		input_buttons = input_buttons & ~1;
	}
	// C4 plant freeze — predicted side mirror.  Freeze through BOTH the
	// prefire hold (WS_FIRE) and the fire commit (WS_SPECIAL) so the planter
	// can't walk during the commit anim — they're locked until fully planted.
	// Without this the preview sim would visibly slide for one frame before the
	// server-side freeze pulled it back.
	else if (predicted_player
	         && predicted_player.weapon == WEP_CFC4
	         && (predicted_player.weaponstate == WS_FIRE
	             || predicted_player.weaponstate == WS_SPECIAL))
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
		input_movevalues_z = 0;
		input_buttons = input_buttons & ~PM_BTN_JUMP;
	}

	// func_vehicle: mirror the predicted driver-lock in the render preview so the
	// driver doesn't visibly walk between ticks (WASD steers the car, not feet).
	if (predicted_player && predicted_player.pm_driving)
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
	}

	float fixedstep = PM_ReadMovevar("sv_mintic", 0.01);
	if (fixedstep < 0.001) fixedstep = 0.01;

	// mp_noblock: this render-rate preview calls PM_PlayerMoveStep() directly,
	// bypassing PM_PlayerMove() where the noblock stash lives. Without the same
	// stash here the preview (hence the camera, via csqc_present_origin below)
	// collides with remote players' SOLID_BBOX proxies while the REAL prediction
	// passes through them — snapping the view to the proxy's bbox edge entering
	// and stalling it inside (the boundary hitch + through-stutter). Mirror
	// PM_PlayerMove: desolidify other players for the preview substeps, restore
	// right after. Set the flag explicitly (not the value carried from the last
	// real tick) so the first preview frame after a cvar toggle is correct.
	pm_noblock_active = stof(serverkey("mp_noblock")) > 0;
	if (pm_noblock_active)
		PM_NoblockStash();

	pm_suppress_sounds = TRUE;   // preview steps are speculative — no sounds
	while (preview_time > PM_FIXEDSTEP_EPSILON)
	{
		input_timelength = min(preview_time, fixedstep);
		PM_PlayerMoveStep();
		preview_time -= input_timelength;
	}
	pm_suppress_sounds = FALSE;

	if (pm_noblock_active)
		PM_NoblockRestore();

	csqc_present_origin = CSQC_ApplyLocalSmoothOffset(self.origin);
	csqc_present_view_ofs = self.view_ofs;

	// (func_vehicle driver seat-lock moved ABOVE the early-returns — the driver
	// returns before reaching here, so this path is the normal walking case.)

	// Post-preview duck flag.  See declaration comment — the saved_flags
	// restore below this block reverts self.flags to its pre-preview value,
	// so consumers that pair csqc_present_origin with a bbox size MUST read
	// this snapshot rather than predicted_player.flags.
	csqc_present_ducking = (self.flags & FL_DUCKING) != 0;
	csqc_dbg_last_present_time = cltime;
	csqc_dbg_last_preview_dt = (cltime - csqc_dbg_last_key_time) * 1000;
	CSQC_CheckDebugPreviewResponse();

	// Smoothing diagnostics — per-frame visual-step samples.  Use
	// saved_velocity (stable, captured before the preview physics
	// sub-steps) rather than self.velocity which swings transiently
	// inside the TOSS loop.  Gate tightly: real locomotion only, sane
	// frametime, step within a plausible frame-budget (filter out
	// teleports / respawn jumps / initial (0,0,0) seed), and ratio
	// within a physically meaningful range (≤ 4x expected — anything
	// larger implies a preview-vs-predict out-of-phase sample which
	// isn't a rendering artefact the user perceives as jitter).
	{
		vector step_vec = csqc_present_origin - smooth_last_present_origin;
		float  step_len = vlen(step_vec);

		vector vel_horiz = saved_velocity;
		vel_horiz_z = 0;
		float speed_h = vlen(vel_horiz);

		float expected  = speed_h * frametime;
		float plausible = expected * 2.0 + 1.0;

		if (speed_h > 50 && frametime > 0.001
		    && expected > 0.05
		    && step_len < plausible)
		{
			float ratio = step_len / expected;
			if (ratio >= 0 && ratio <= 4)
			{
				Smooth_Push(SMOOTH_M_STEP, step_len);
				Smooth_Push(SMOOTH_M_REGULAR, ratio);

				vector vdir = vel_horiz * (1.0 / speed_h);
				vector step_horiz = step_vec;
				step_horiz_z = 0;
				float fwd_step = step_horiz * vdir;
				Smooth_Push(SMOOTH_M_FWDSTEP, fwd_step);
			}
		}
		smooth_last_present_origin = csqc_present_origin;
	}

	setorigin(self, saved_origin);
	self.velocity = saved_velocity;
	self.view_ofs = saved_view_ofs;
	self.flags = saved_flags;
	self.pm_movetype = saved_movetype;
	self.pm_jump_held = saved_jump_held;
	self.pm_jump_msec = saved_jump_msec;
	self.pm_waterjumptime = saved_waterjumptime;
	self.pm_in_duck = saved_in_duck;
	self.pm_duck_msec = saved_duck_msec;
	self.pm_oldbuttons = saved_oldbuttons;
	self.pm_timecarry = saved_timecarry;
	self.pm_teleport_time = saved_teleport_time;
	self.pm_ladder_detach_time = saved_ladder_detach_time;
	self.pm_fuser2 = saved_fuser2;
	self.spread_penalty = saved_spread_penalty;
	self.fire_spread_penalty = saved_fire_spread_penalty;
	// Preview MUST NOT leak pm_step_time mutations back into the real
	// prediction — the preview runs at render rate on live WASD, but the
	// fresh prediction (CSQC_PredictCurrentCommand) runs at input rate on
	// the buffered command. If preview ticks the step timer forward, the
	// next real prediction inherits a corrupted timer and fires extra
	// steps. Restore it alongside the other move fields.
	self.pm_step_time = saved_step_time;
	// Same leak-prevention as pm_step_time: the suppressed preview pmove can
	// engage a slide (slide_friction_active 0->1) a render-frame BEFORE the
	// real prediction does. Without this restore that 1 leaks onto
	// predicted_player, the live PM_TryEngageSlide short-circuits on its
	// idempotency guard, and the edge-latch slide sound (CSQC_Input_Frame)
	// never sees a clean 0->1 edge.
	self.slide_friction_active = saved_slide_friction_active;
	// Same: a preview-tick jump stamps pm_jump_groundstick_off_until; restore it
	// so the suppress window doesn't leak forward by a frame (momentary float).
	self.pm_jump_groundstick_off_until = saved_jump_groundstick;
	// Same leak-prevention rationale as pm_step_time above: the
	// preview's pmove writes pm_on_ladder_cached unconditionally at
	// the done: block (sh_pmove.qc), so without this restore the
	// preview's speculative ladder-overlap state would persist on
	// predicted_player and the next CSQC_Input_Frame's view-fx /
	// fire-gate would read it instead of the real buffered command's
	// value.  Visible as the gun briefly dropping (lower envelope
	// ramps up to a stale TRUE) at the base of a ladder if the player
	// pushes forward into it at high render fps, even before they
	// touch it.
	self.pm_on_ladder_cached = saved_pm_on_ladder_cached;
	self.platform_carry                      = saved_platform_carry;
	self.platform_carry_velocity             = saved_platform_carry_velocity;
	self.platform_carry_prev_yaw             = saved_platform_carry_prev_yaw;
	self.platform_carry_jump_origin_consumed = saved_platform_carry_jump_origin_consumed;
	self.platform_carry_jump_yaw_consumed    = saved_platform_carry_jump_yaw_consumed;

	input_timelength = saved_timelength;
	input_angles = saved_angles;
	input_movevalues = saved_movevalues;
	input_buttons = saved_buttons;
	input_impulse = saved_impulse;

	self = saved;
};

// ---------------------------------------------------------------------------
//  Remote player dead-reckoning
//
//  The engine already lerps other players between the two most recently
//  received server frames.  After the lerp reaches the latest snapshot,
//  however, the entity sits frozen until the next packet arrives.  This
//  function extrapolates each remote player's position forward by
//  (cltime - time) — the elapsed time since the last server snapshot —
//  using their velocity and gravity, so they travel smoothly in the air
//  between network updates.
//
//  Called in CSQC_UpdateView before addentities(MASK_ENGINE).  Writing to
//  ent.origin here affects this frame's render position only; the engine
//  overwrites it with fresh lerp data at the start of the next frame.
//
//  Tuning cvars (all live, no restart needed):
//    cl_extrap             1   master toggle; 0 = pure engine lerp only
//    cl_extrap_grounded    1   also extrapolate grounded players (required
//                              for smooth running-target motion; smoothing
//                              hides any direction-change snap-back)
//    cl_debug_extrap       0   1 = print per-player extrap delta each
//                              frame to console (spammy, use briefly)
//
// The extrap window cap is hard-coded at 10 × sv_mintic (~156 ms at
// 64 Hz) — enough to ride out several ticks of packet loss without
// runaway extrapolation. Retired from cvar list as no users benefit
// from tuning.
// ---------------------------------------------------------------------------

// Record a remote player snapshot into the interp ring buffer.
//
// This mod networks remote-player visuals via CSQC_Ent_Update as
// player_visual_proxy entities, NOT via the engine's default
// player-slot broadcast. So the correct per-player "snapshot arrived"
// signal is CSQC_PlayerVisual_Update (called in cl_player.qc when a
// VP_SF_POSE_CL section lands), not a scan over 1..maxclients slots
// (those report GE_ACTIVE=0 on this mod).
//
// Takes the fresh origin as a parameter rather than reading proxy.origin,
// because CSQC_PlayerVisual_Update only commits the snapshot via
// setorigin() at the END of the function — reading proxy.origin from
// an earlier hook site captured one-snapshot-stale data and caused
// cl_interp_time to lock the model in place.
//
// Key: vis_owner_entnum (the player's slot, 1..maxclients — stable).
// Tag: cltime, so all downstream math is in a single clock frame.
// Setorigin with entity-smoothing error offset applied. Target is the
// "where we want to render this proxy this frame" position (either the
// interp-behind lerp result or the extrap-forward projection). If an
// error was stashed in CSQC_PlayerVisual_Update on the last snapshot
// arrival and it hasn't fully decayed, we shift target by err*decay so
// the rendered position interpolates smoothly from "where we were"
// to "where the server says we are" over cl_extrap_smooth_time.
//
// decay = 1 at the moment of the snapshot (render = old predicted position,
//         matches last frame exactly, no jump)
// decay = 0 after smooth_time elapsed (render = authoritative target)
void(entity proxy, vector target) CSQC_SmoothSetOrigin =
{
	if (proxy.extrap_error_cltime > 0)
	{
		// smooth_time <= 0 means "no smoothing" (instant correction).
		// Earlier version silently substituted 0.1 when the cvar was 0
		// or negative, which made `cl_extrap_smooth_time 0` behave
		// identical to the default — wrong. Fall back to default ONLY
		// when the cvar is completely unset.
		float smooth_time;
		if (cvar_string("cl_extrap_smooth_time") == "")
			smooth_time = 0.1;
		else
			smooth_time = cvar("cl_extrap_smooth_time");

		if (smooth_time > 0)
		{
			float age = cltime - proxy.extrap_error_cltime;
			if (age >= 0 && age < smooth_time)
			{
				float decay = 1.0 - (age / smooth_time);
				target = target + proxy.extrap_error_offset * decay;
			}
		}
		// else: smoothing disabled by value — snap to target.
	}
	setorigin(proxy, target);
};

void(entity proxy, vector snap_origin) CSQC_RecordProxySnapshot =
{
	if (proxy.vis_owner_entnum <= 0 || proxy.vis_owner_entnum > INTERP_MAX_PLAYERS)
		return;
	if (proxy.vis_owner_entnum == player_localentnum)
		return;   // don't buffer our own proxy — local player uses prediction
	if (proxy.vis_is_dead)
		return;   // don't pollute the slot's ring buffer with frozen corpse origins
		          // — the slot is shared with the (respawning) live proxy.

	float slot = proxy.vis_owner_entnum - 1;
	float base = slot * INTERP_HIST_SIZE;
	float idx  = g_interp_head[slot];

	g_interp_origin[base + idx] = snap_origin;
	g_interp_time  [base + idx] = cltime;

	g_interp_head[slot] = (idx + 1) % INTERP_HIST_SIZE;
	if (g_interp_count[slot] < INTERP_HIST_SIZE)
		g_interp_count[slot] = g_interp_count[slot] + 1;

	g_interp_last_snap_cltime = cltime;
};

// Retained but now a no-op; the per-proxy hook in CSQC_PlayerVisual_Update
// does the actual sampling. Keeping the call sites intact avoids churn.
void() CSQC_SampleRemotePlayersForInterp =
{
};

// Lookup an interpolated origin for `slot` at `render_time` (seconds on the
// server clock). Returns '0 0 0' and sets interp_lookup_ok=0 if the buffer
// can't bracket render_time (too new = extrap needed; too old = no data).
float interp_lookup_ok;

vector(float slot, float render_time) CSQC_LookupInterpedOrigin =
{
	interp_lookup_ok = 0;
	if (slot >= INTERP_MAX_PLAYERS)
		return '0 0 0';
	if (g_interp_count[slot] < 2)
		return '0 0 0';

	float base  = slot * INTERP_HIST_SIZE;
	float count = g_interp_count[slot];
	float head  = g_interp_head[slot];

	// Walk from newest backward to find the first sample at or before render_time.
	float i;
	float older_idx = -1;
	float newer_idx = -1;
	for (i = 0; i < count; i++)
	{
		float idx = (head - 1 - i + INTERP_HIST_SIZE) % INTERP_HIST_SIZE;
		if (g_interp_time[base + idx] <= render_time)
		{
			older_idx = idx;
			break;
		}
		newer_idx = idx;
	}

	if (older_idx < 0) return '0 0 0';  // render_time older than all samples
	if (newer_idx < 0) return '0 0 0';  // render_time newer than all samples (need extrap)

	float t_old = g_interp_time[base + older_idx];
	float t_new = g_interp_time[base + newer_idx];
	if (t_new <= t_old)
		return '0 0 0';

	float frac = (render_time - t_old) / (t_new - t_old);
	interp_lookup_ok = 1;
	return g_interp_origin[base + older_idx] * (1 - frac)
	     + g_interp_origin[base + newer_idx] * frac;
};

// Push cl_interp_time as userinfo so the server can read it in
// Lagcomp_GetRewindSeconds and add it to the rewind window. Without
// this, shooters running cl_interp_time > 0 see the hit-compensation
// falling short by exactly their interp amount (phantom misses).
// The dedup guard makes the per-frame call essentially free.
float cl_interp_pushed_init;
float cl_interp_last_pushed;

void() CSQC_PushInterpUserInfo =
{
	float v = cvar("cl_interp_time");
	if (cl_interp_pushed_init && v == cl_interp_last_pushed)
		return;
	cl_interp_pushed_init = 1;
	cl_interp_last_pushed = v;
	localcmd(sprintf("setinfo cl_interp_time %f\n", v));
};

// Push cl_predict_hits as userinfo so the server knows whether to expect
// a hitclaim from this shooter. When sv_trust_clienthits >= 1, the server
// suppresses its own player-damage path for shooters that *will* claim,
// avoiding the dedup race that silently dropped the visually-accurate
// claim in favor of a slightly-off lag-comped server hit. Shooters with
// cl_predict_hits 0 keep the legacy server-auth damage path.
float cl_predict_hits_pushed_init;
float cl_predict_hits_last_pushed;

void() CSQC_PushPredictHitsUserInfo =
{
	float v = cvar("cl_predict_hits");
	if (cl_predict_hits_pushed_init && v == cl_predict_hits_last_pushed)
		return;
	cl_predict_hits_pushed_init = 1;
	cl_predict_hits_last_pushed = v;
	localcmd(sprintf("setinfo cl_predict_hits %f\n", v));
};

// NOTE: cl_extrap_* cvars only have a visible effect when at least one
// other player is connected.  In a single-player session the per-player
// loop body never executes, so every cvar combination produces identical
// (zero) behavior — set cl_debug_extrap 1 to confirm via the
// "no remote players" notice.  cl_debug_extrap uses print() (not dprint)
// so output is visible without enabling `developer 1`.
//
// When cl_interp_time > 0, remote players are rendered N seconds behind
// the latest snapshot, blending between two known positions from the
// ring buffer. Adds visual latency = cl_interp_time, but produces
// maximum smoothness regardless of snapshot rate or any remote player's
// cl_netfps. Falls back to extrap when the buffer can't bracket the
// requested time (startup, packet loss). Pass-through when 0.
void() CSQC_ExtrapolateRemotePlayers =
{
	float n;
	float dt;
	float gravity;
	vector base_origin;
	vector extrap_origin;
	entity ent;
	float seen_remote = 0;

	float extrap_debug = cvar("cl_debug_extrap");

	// Master toggle: unset cvar = on (preserves default behavior),
	// explicit 0 = off.
	float master;
	if (cvar_string("cl_extrap") == "")
		master = 1;
	else
		master = cvar("cl_extrap");

	float extrap_grounded = cvar("cl_extrap_grounded");

	// Hard-coded: max extrap window = 10 × sv_mintic (≈156 ms at 64 Hz).
	// Previously cl_extrap_max cvar; users set it to 99 effectively
	// disabling the cap. 10 ticks is enough slack for normal packet
	// jitter without runaway extrapolation under catastrophic loss.
	const float max_mult = 10;

	// cl_interp_time: render N seconds behind the latest snapshot using
	// the ring buffer (overrides extrap per-player when data available).
	float interp_time = cvar("cl_interp_time");
	if (interp_time < 0) interp_time = 0;

	gravity = cvar("sv_gravity");
	if (!gravity) gravity = 800;

	float ticrate = cvar("sv_mintic");
	if (ticrate <= 0) ticrate = 0.015;

	// dt = how much real time has passed since the most recent snapshot
	// was recorded. Measured entirely in cltime-frame so it can't invert
	// on a remote-hosted server (where `time` is offset from cltime by
	// the server's pre-connect run time).
	dt = cltime - g_interp_last_snap_cltime;

	if (extrap_debug)
	{
		print(sprintf("[extrap] enter cltime=%.3f last_snap_cltime=%.3f dt=%.3f\n",
			cltime, g_interp_last_snap_cltime, dt));
		print(sprintf("[extrap]   master=%g grounded=%g maxmult=%g interp=%.3f\n",
			master, extrap_grounded, max_mult, interp_time));
		print(sprintf("[extrap]   maxclients=%g player_localentnum=%g\n",
			maxclients, player_localentnum));
	}

	// If both systems are off, nothing to do.
	if (!master && interp_time <= 0)
	{
		if (extrap_debug) print("[extrap] both off (cl_extrap=0 and cl_interp_time=0) — skipping\n");
		return;
	}

	// Before any snapshot has been recorded, g_interp_last_snap_cltime == 0
	// — the ring buffer is empty, so neither interp nor extrap can do
	// anything useful yet.
	if (g_interp_last_snap_cltime <= 0)
	{
		if (extrap_debug)
			print("[extrap] skip — no snapshot recorded yet (waiting for first serverprevtime change)\n");
		return;
	}

	// Per-proxy gating: the dt clamp below only gates EXTRAP, not interp.
	// Interp can always run if cl_interp_time > 0 and the buffer brackets
	// the requested (cltime - interp_time) — it doesn't care about how
	// much time has passed since the latest snapshot.
	float extrap_ok = master && (dt >= 0) && (dt <= ticrate * max_mult);
	if (master && !extrap_ok && extrap_debug)
		print(sprintf("[extrap] extrap-disabled this frame — dt=%.3f outside (0, %.3f]  (interp still runs if on)\n",
			dt, ticrate * max_mult));

	// Iterate player_visual_proxy entities (this mod's custom remote-player
	// networking, not engine-default player slots). findchain returns a
	// linked list via .chain.
	entity proxy = findchain(classname, "player_visual_proxy");
	while (proxy)
	{
		float owner = proxy.vis_owner_entnum;
		if (owner <= 0 || owner == player_localentnum)
		{
			proxy = proxy.chain;
			continue;
		}

		// Corpses (vis_is_dead) don't move — and they share
		// vis_owner_entnum with the respawning live proxy, so the
		// shared interp ring buffer's latest entry is the LIVE
		// player's origin. Without this skip the corpse would
		// extrap to whatever the new live proxy's just-received
		// origin is and visibly follow that player around.
		if (proxy.vis_is_dead)
		{
			proxy = proxy.chain;
			continue;
		}

		seen_remote = 1;

		if (extrap_debug)
			print(sprintf("[extrap]   proxy owner=%g origin=(%.1f %.1f %.1f) flags=%g\n",
				owner, proxy.origin_x, proxy.origin_y, proxy.origin_z, proxy.flags));

		// Lerp-behind path: independent of cl_extrap. If cl_interp_time
		// is set and the ring buffer can bracket (cltime - interp_time),
		// use a blended origin from two known snapshots. This path can
		// run with cl_extrap 0 for pure lerp-between-snapshots behavior.
		if (interp_time > 0)
		{
			vector lerped = CSQC_LookupInterpedOrigin(owner - 1, cltime - interp_time);
			if (interp_lookup_ok)
			{
				// setorigin (not direct .origin = ...) so the engine's
				// spatial index and gettaginfo see the updated position.
				// A direct field write leaves hitbox bones anchored to the
				// last setorigin, which produces the "hitboxes lag behind
				// the model and snap back" symptom. Smoothed variant
				// applies any pending error offset so snapshot snaps
				// blend over cl_extrap_smooth_time instead of popping.
				CSQC_SmoothSetOrigin(proxy, lerped);
				if (extrap_debug)
					print(sprintf("[extrap] proxy owner=%g  interp-behind=%.3fs\n",
						owner, interp_time));
				proxy = proxy.chain;
				continue;
			}
			if (extrap_debug)
				print(sprintf("[extrap] proxy owner=%g  interp buffer miss\n", owner));
		}

		// ---- Extrap path (only runs if cl_extrap is enabled) ----
		// When cl_extrap is off AND interp missed (or isn't configured),
		// we simply leave the proxy at its last-setorigin (the snapshot
		// position) — that's the "pure lerp, nothing else" mode.
		if (!extrap_ok)
		{
			if (extrap_debug)
				print(sprintf("[extrap] proxy owner=%g  extrap off — holding snapshot pos\n", owner));
			proxy = proxy.chain;
			continue;
		}

		// Grounded players: by default trust pure engine interpolation.
		// Walking direction changes too often for velocity-based
		// extrapolation to be a win — it causes snap-back when the next
		// packet contradicts the guess. Opt-in via cl_extrap_grounded.
		if (proxy.flags & FL_ONGROUND)
		{
			if (!extrap_grounded)
			{
				if (extrap_debug)
					print(sprintf("[extrap] proxy owner=%g skipped (grounded, cl_extrap_grounded=0)\n", owner));
				proxy = proxy.chain;
				continue;
			}

		}

		// Extrap from the LATEST SNAPSHOT origin (newest ring-buffer entry),
		// not from proxy.origin. The previous frame overwrote proxy.origin
		// with an extrapped value; extrapping that again compounds velocity
		// each frame and produces severe overshoot — the "player traveling
		// way too quickly" symptom. player_visual_proxy is a CSQC entity
		// without engine-side snapshot reset, so we have to pin the basis
		// ourselves.
		float slot = owner - 1;
		if (slot < 0 || slot >= INTERP_MAX_PLAYERS || g_interp_count[slot] < 1)
		{
			base_origin = proxy.origin;   // fallback: no buffer yet
		}
		else
		{
			float base = slot * INTERP_HIST_SIZE;
			float newest_idx = (g_interp_head[slot] - 1 + INTERP_HIST_SIZE) % INTERP_HIST_SIZE;
			base_origin = g_interp_origin[base + newest_idx];
		}

		extrap_origin = base_origin + proxy.velocity * dt;

		if (!(proxy.flags & FL_ONGROUND))
			extrap_origin_z -= 0.5 * gravity * dt * dt;

		// Smoothed setorigin — applies any pending error-offset decay so
		// snapshot snap-backs bleed out over cl_extrap_smooth_time
		// instead of popping in a single frame.
		CSQC_SmoothSetOrigin(proxy, extrap_origin);

		if (extrap_debug)
		{
			vector delta = extrap_origin - base_origin;
			print(sprintf("[extrap] proxy owner=%g  dt=%.3f  delta=(%.2f %.2f %.2f) len=%.2f%s\n",
				owner, dt,
				delta_x, delta_y, delta_z, vlen(delta),
				(proxy.flags & FL_ONGROUND) ? " [grounded]" : ""));
		}

		proxy = proxy.chain;
	}

	if (extrap_debug && !seen_remote)
		print("[extrap] no remote players in this session — cvar settings will have no visible effect\n");
};

// ---------------------------------------------------------------------------
// CSQC_SetupRemotePlayerSolids was removed.  It tried to set engine
// player slots SOLID_SLIDEBOX every input frame via edict_num(n) for
// n=1..maxclients — but in this CSQC config edict_num(n) doesn't
// return engine player slots, it returns whatever CSQC entity happens
// to be at edict slot n (predicted_player, preview models, etc.).
// Live diagnostic confirmed every iteration was skipped by the model-
// prefix check; the function ran 32 outer iterations doing nothing.
//
// Player-vs-player collision on CSQC is handled by the visual proxy
// alone (set SOLID_BBOX in CSQC_PlayerVisual_Update and stashed by
// PM_NoblockStash when mp_noblock is on).  PM_ReadMovevars (which
// SetupRemotePlayerSolids also called) is invoked per-pmove inside
// PM_PlayerMove and on every CSQC_PlayerVisual_Update for proxy
// bbox sizing, so its globals stay populated without this caller.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//  CSQC_Input_Frame  -  called each input frame, inputs already set
// ---------------------------------------------------------------------------

// Single-frame jump-pulse buffer.  Mouse wheel +jump binds fire a press
// + release inside a single render frame; depending on phase against the
// pmove tick the engine will sometimes never sample the press, dropping
// the jump entirely.  We watch the rising edge of PM_BTN_JUMP and, on
// the very next frame where the raw button has gone back off, force it
// on for one extra input frame.  That guarantees at least one full
// pmove tick sees the press, which is enough for PM_CheckJump to fire.
// Multi-tick presses are unaffected (the falling edge just lands one
// frame later than it otherwise would — invisible to the player).
float csqc_jump_buffer_armed;
float csqc_jump_was_down;
float csqc_carry_fire_last;   // +attack rising-edge latch for the carry throw
float csqc_carry_throw_lockout; // keep fire suppressed after a throw until +attack released

// Edge-latch state: last frame's live-predicted slide_friction_active, so the
// predicted slide sound (above, after CSQC_PredictCurrentCommand) fires exactly
// once on the 0->1 engage edge and re-arms when the slide ends.
float csqc_slide_snd_prev;
void() CSQC_Input_Frame =
{
	localplayer = CSQC_GetEngineLocalPlayer();

	// Advance remote player proxies to their interped/extrapped positions
	// BEFORE any fire trace runs. Without this, client's hit traces use
	// proxy positions from the previous render frame's UpdateView pass,
	// which is 1 render frame behind what the user will visually see
	// when the trace draws its impact. Small (~3 ms of target motion at
	// 300 fps) but user-visible as "aim hit the player model, trace
	// missed." Idempotent with the UpdateView call that follows.
	CSQC_ExtrapolateRemotePlayers();
	CSQC_ClampMoveInputs();
	csqc_dbg_last_inputframe_time = cltime;
	CSQC_LatchLiveInputFromCommand();
	input_buttons = csqc_live_buttons;   // write custom bits before buffer captures them

	// HL2 carry: while holding a prop, +attack THROWS it instead of firing.
	// Suppress the fire button HERE — before the command is buffered + predicted
	// and before it's sent to the server — so NO weapon (server or client,
	// standard or custom-fire) shoots or emits a `cs` client-shot, and send the
	// throw on the rising edge. pm_carrying is the server-confirmed carry flag.
	if (predicted_player && predicted_player.pm_carrying)
	{
		if ((input_buttons & PM_BTN_FIRE) && !csqc_carry_fire_last)
		{
			localcmd("cmd throwprop\n");
			csqc_carry_throw_lockout = 1;   // hold fire-suppress through the throw
			// Gravity gun: predict the throw "fire2" animation client-side (the
			// fire bit is suppressed below, so the gravgun predict command can't
			// see it).  weaponstate is client-authoritative — drive it here.
			if (predicted_player.weapon == WEP_GRAVITYGUN)
			{
				predicted_player.weaponstate     = WS_FIRE;
				predicted_player.wep_anim_start  = cltime;
				predicted_player.attack_finished = cltime + GRAVGUN_GRAB_COOLDOWN;
				csqc_gravgun_fire_seq            = GRAVGUN_SEQ_FIRE2;
			}
		}
		csqc_carry_fire_last = (input_buttons & PM_BTN_FIRE) ? 1 : 0;
		input_buttons = input_buttons & ~PM_BTN_FIRE;
	}
	else
	{
		// Track the raw fire state even when not carrying so that grabbing while
		// +attack is held doesn't read as a fresh press (instant throw on grab).
		csqc_carry_fire_last = (input_buttons & PM_BTN_FIRE) ? 1 : 0;
		// After a throw, keep fire suppressed until +attack is RELEASED, so the
		// still-held button doesn't immediately shoot once carrying ends (the
		// "you still shoot after throwing" report). pm_carrying drops ~1 RTT
		// after the throw; this bridges that window and the held button.
		if (csqc_carry_throw_lockout)
		{
			if (input_buttons & PM_BTN_FIRE)
				input_buttons = input_buttons & ~PM_BTN_FIRE;
			else
				csqc_carry_throw_lockout = 0;
		}
	}

	// Advance view-feel state (bob phase, landing spring, sway lag) on
	// the input-frame cadence so the phase is identical across render-
	// rate fluctuation.  Read-only with respect to prediction state.
	CSQC_ViewFX_UpdateState();
	// CoD scope state machine — driven from the ADS envelope updated
	// above, so MUST come after ViewFX_UpdateState in the same tick.
	CSQC_CodScope_UpdateState();
	// Per-frame scope fog sync for the CS-style scope path (no-op
	// while the CoD machine is engaged — it owns the fog hookup in
	// CoD mode).
	CSQC_CodScope_FogCSStyle();

	// Apply any yaw delta posted by func_door_rotating's per-frame carry
	// pass (CSQC_EVENT_DOOR_VIEWROT).  Folded in *after* the engine has
	// stamped its mouse-tracked angles so we add to whatever the player
	// is currently looking at — pitch/roll are left untouched.
	//
	// Update VF_CL_VIEWANGLES too so next frame's mouse delta is added
	// onto the rotated yaw, not snapped back to the pre-rotation value.
	//
	// HISTORICAL: the accumulated offset previously came exclusively
	// from per-tick CSQC_EVENT_DOOR_VIEWROT events fired from the
	// server's Brush_RotateCarry.  Those arrived at netrate cadence
	// with ping latency, and the events buffered between rotation-end
	// and final ack manifested as a 0.5–1 s view-yaw catch-up tail.
	// The server fire is now disabled — see sv_doors_rotating.qc;
	// the offset is filled in below by the local-prediction block.
	if (csqc_door_yaw_offset != 0)
	{
		// Only the setproperty(VF_CL_VIEWANGLES_Y) write persists: it
		// advances cl.playerview.viewangles, which the engine re-seeds
		// into the NEXT frame's outgoing cmd->angles (cl_input.c:1304).
		// A separate input_angles_y bump here re-applied the same delta
		// to THIS frame's cmd->angles, double-counting the rotation
		// (the "view yaw spins ~2x too fast" report). Drop it.
		float new_yaw = (float)getproperty(VF_CL_VIEWANGLES_Y) + csqc_door_yaw_offset;
		setproperty(VF_CL_VIEWANGLES_Y, new_yaw);
		csqc_door_yaw_offset = 0;
	}

	// Local-prediction view yaw rotation when standing on a rotating
	// brush (yaw axis only — pitch/roll rotators don't drag view yaw).
	// Mirrors PM_CheckRotatingCarry's position prediction: each input
	// frame we add avelocity_y * input_timelength to the view yaw,
	// keeping the camera facing the same brush-relative direction
	// throughout the rotation.
	//
	// Uses `input_timelength` (this input command's duration) NOT
	// `frametime` (engine render frame time).  CSQC_Input_Frame fires
	// once per input frame, but at high render fps a single input
	// frame spans many render frames — `frametime` underestimated the
	// gap by render_fps/input_fps, so the view rotated at only that
	// fraction of the brush's actual rate (the user's "much less"
	// report).  `input_timelength` is the correct per-input-frame
	// duration; total per second equals avelocity exactly.
	if (predicted_player && rotating_brush_list != world && input_timelength > 0)
	{
		entity rb;
		float iter = 0;
		entity saved_self = self;
		self = predicted_player;
		for (rb = rotating_brush_list; rb; rb = rb.rotating_brush_next)
		{
			iter = iter + 1;
			if (iter > 256) break;
			if (rb.avelocity == '0 0 0') continue;
			// Yaw-dominant only — rotators on X/Z don't translate to
			// view yaw under the existing carry semantics.
			if (fabs(rb.avelocity_y) < fabs(rb.avelocity_x)) continue;
			if (fabs(rb.avelocity_y) < fabs(rb.avelocity_z)) continue;

			// Strict "standing on this brush" check — same trace as
			// PM_CheckRotatingCarry uses.  Bbox overlap alone would
			// keep rotating the view during jumps; user expectation
			// is the natural one: jump off → no view carry.
			tracebox(predicted_player.origin,
			         PM_CurrentMins(), PM_CurrentMaxs(),
			         predicted_player.origin - '0 0 4',
			         MOVE_NORMAL, predicted_player);
			if (trace_fraction >= 1) continue;
			if (trace_ent != rb) continue;

			// Only the setproperty(VF_CL_VIEWANGLES_Y) write persists:
			// it advances cl.playerview.viewangles, which the engine
			// re-seeds into the NEXT frame's outgoing cmd->angles
			// (cl_input.c:1304). A separate input_angles_y bump here
			// re-applied the same delta to THIS frame's cmd->angles,
			// double-counting the rotation (the "view yaw spins ~2x too
			// fast while position carry stays 1x" report). Drop it; the
			// rotation still reaches the server via the viewangles
			// re-seed, lagged a uniform one input frame (<16ms).
			float yaw_delta = rb.avelocity_y * input_timelength;
			float predicted_yaw = (float)getproperty(VF_CL_VIEWANGLES_Y) + yaw_delta;
			setproperty(VF_CL_VIEWANGLES_Y, predicted_yaw);
			break;   // first matching brush wins; no double-rotation
		}
		self = saved_self;
	}

	// Jump pulse extension — see comment above the file-scope statics.
	float jump_now = (input_buttons & PM_BTN_JUMP) != 0;
	if (jump_now && !csqc_jump_was_down)
	{
		csqc_jump_buffer_armed = 1;
	}
	else if (!jump_now && csqc_jump_buffer_armed)
	{
		input_buttons = input_buttons | PM_BTN_JUMP;
		jump_now = 1;
		csqc_jump_buffer_armed = 0;
	}
	csqc_jump_was_down = jump_now;

	// Freeze time: block WASD movement and primary attack
	if (getstatf(STAT_ROUND_PHASE) == ROUND_PHASE_FREEZE)
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
		input_buttons = input_buttons & ~1;
	}
	// C4 plant freeze — buffered-command mirror of the SSQC freeze.  Covers
	// BOTH the prefire hold (WS_FIRE) and the fire commit (WS_SPECIAL) so the
	// outgoing command carries no movement until the bomb is fully planted.
	// Keep button0 alive (the hold detection runs server-side via
	// W_CFC4Frame) but zero WASD/jump so the predicted move matches.
	else if (predicted_player
	         && predicted_player.weapon == WEP_CFC4
	         && (predicted_player.weaponstate == WS_FIRE
	             || predicted_player.weaponstate == WS_SPECIAL))
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
		input_movevalues_z = 0;
		input_buttons = input_buttons & ~PM_BTN_JUMP;
	}

	// Dead: build freecam input from live directional state, then block server-bound movement
	if (getstatf(STAT_IS_DEAD))
	{
		// Use csqc_live_* booleans (latched above from input_movevalues before zeroing)
		spec_freecam_fwd = 0;
		spec_freecam_side = 0;
		if (csqc_live_forward) spec_freecam_fwd += 1;
		if (csqc_live_back)    spec_freecam_fwd -= 1;
		if (csqc_live_right)   spec_freecam_side += 1;
		if (csqc_live_left)    spec_freecam_side -= 1;
		input_movevalues = '0 0 0';
		input_buttons = 0;
	}

	// func_vehicle driver lock (predicted, freeze-grade).  Zero the walk for the
	// BUFFERED command + the prediction below so predicted_player (and every
	// reconcile replay off the buffer) stays put — then RESTORE the live WASD at
	// the end so the engine's outgoing usercmd still carries the throttle to the
	// server (the car is driven from it).  Without the restore the server would
	// receive 0 and the car wouldn't move; without the zero the driver visibly
	// walks and rubber-bands.  The render preview is locked separately in
	// CSQC_BuildPresentationView (it reads live WASD, not this buffer).
	vector veh_lock_saved_mv = input_movevalues;
	float  veh_lock_active = FALSE;
	if (predicted_player && predicted_player.pm_driving)
		veh_lock_active = TRUE;
	if (veh_lock_active)
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
	}

	CSQC_BufferInputCommand(clientcommandframe);
	CSQC_PredictCurrentCommand();

	// Predicted slide sound — play once on the live 0->1 engage edge, HERE
	// (after the live predict pass) rather than inside PM_TryEngageSlide, which
	// the suppressed render-preview pass reaches first and short-circuits. The
	// preview no longer leaks slide_friction_active (restored in the preview),
	// so this reads a clean live-predicted value → instant at any ping, once
	// per slide; the latch self-clears when the slide ends.
	if (predicted_player)
	{
		float slide_now = predicted_player.slide_friction_active;
		if (slide_now && !csqc_slide_snd_prev)
		{
			slide_local_variant = (slide_local_variant % 5) + 1;
			// Channel 5, NOT CHAN_BODY (4): footsteps also play on CHAN_BODY and
			// auto-replace the prior voice, so a footstep mid-slide was cutting
			// the ~1.25s slide sample short. Its own dedicated channel lets the
			// slide ring out; a fresh slide still cuts the previous one.
			localsound(sprintf("sounds/player/slide%g.wav", slide_local_variant), 5, 1);
		}
		csqc_slide_snd_prev = slide_now;
	}

	if (veh_lock_active)
		input_movevalues = veh_lock_saved_mv;   // restore real WASD for the engine's sent usercmd → car drives
};


// ---------------------------------------------------------------------------
//  CSQC player visual proxy — predraw + receiver
//
//  CSQC entity with predraw for full animation control. Uses ONLY
//  engine built-in fields from cl_defs.qc — NO redeclarations.
//  bonecontrol1-4 and subblendfrac only work on CSQC entities.
// ---------------------------------------------------------------------------

const string PLAYER_VISUAL_MODEL = "models/player/leet/leet.iqm";

// Custom fields only (no engine equivalents to shadow).
// vis_owner_entnum is forward-declared in client/cl_customdefs.qc so
// CSQC_SendHitclaim (in sh_weapon_logic.qc, compiled earlier) can read it.

// Duration of the inter-sequence anim blend on the proxy.
//
// CAVEAT — for HL/GoldSrc studio MDLs (which all this mod's player
// models are), FTE's renderer does NOT honor the .frame2/.lerpfrac
// mechanism: gl_hlmdl.c:HLMDL_GetBoneData_Internal only passes
// frame[0]/frametime[0] to HL_SetupBones, so the OLD anim and the
// blend weight are silently ignored.  The transition snaps.
//
// The fields are still being written below because:
//   1. The infrastructure is correct for Quake-MDL / IQM models if
//      a future change swaps the player format, no rewrite needed.
//   2. Server-side hitbox traces (MOVE_HITMODEL) do read these
//      fields for some FTE paths.  Harmless either way.
//
// The "proper" fix for HL studio sequence lerping is skel_build_ptr,
// but that would replace the engine's automatic frame+baseframe
// split (basebone) with a manual rebuild — a much larger refactor.
float() PlayerVis_LerpDuration =
{
    float d = cvar("cl_player_anim_lerp_time");
    if (d <= 0) return 0;
    return d;
};

.float vis_anim_top;
.float vis_anim_bottom;
.float vis_anim_top_time;
.float vis_anim_bottom_time;
.float vis_weapon_id;
.float vis_pitch;
.float vis_prev_cltime;
.vector vis_prev_origin;
.float vis_last_anim_top;
.float vis_last_anim_bottom;
.float vis_aim_yaw;          // server-sent aim direction (never modified by predraw)
.float vis_anim_top_gen;     // fire/reload generation counter — detects re-fires
.float vis_last_anim_top_gen;

// --- Inter-sequence anim blending (lerpfrac transitions) ---
//
// When the proxy's selected anim changes (e.g. RUN → IDLE_STATIC on
// the legs, or AIM → SHOOT on the torso), the legs / hands snap to
// the new pose in one frame.  Setting `.frame2` (OLD anim) and
// `.lerpfrac` (blend factor) on top of `.frame` (NEW anim) tells
// the engine to interpolate between the two during the transition.
//
// Per FTE convention (cl_defs.qc L308): lerpfrac=0 → render
// `.frame` only; lerpfrac=1 → render `.frame2` only.  So we start
// each transition at lerpfrac=1 (still showing OLD) and animate
// toward 0 (fully NEW) over PLAYER_ANIM_LERP_DURATION.
//
// Per-body-section tracking — bottom (legs) and top (torso) blend
// independently since they switch on different events (locomotion
// vs. weapon state).
.float vis_lerp_bot_start;       // cltime when bottom transition began (0 = no lerp)
.float vis_lerp_bot_prev_anim;   // OLD sequence — written to .frame2
.float vis_lerp_bot_prev_time;   // .frame1time of OLD at moment of transition
.float vis_lerp_top_start;
.float vis_lerp_top_prev_anim;
.float vis_lerp_top_prev_time;

// --- Spine deformer skeleton (IQM-only) ---
//
// HL studiomdl used `.bonecontrol1..4` to fan a yaw delta across
// the four spine bones, giving the "lower body twists with movement
// while the torso stays facing aim" look.  IQM has no bonecontrol;
// we replicate the effect with a per-proxy skeletonindex that we
// build from the current anim state each frame, then post-modify
// the spine bones via skel_set_bone.  The same skeleton object
// hosts the spine PITCH (aim up/down) deformation in place of HL's
// subblend2frac.
//
// `vis_skel` is the FTE skelobject handle (skel_create return).
// Created lazily on first predraw, recycled across frames.  Reset
// to 0 if the model swaps (skel_create binds a model).
.float vis_skel;
.float vis_skel_modelindex;     // tracks which modelindex vis_skel was created against
.float vis_spine_debug_next;
.float vis_backpedaling;

// --- Flinch override (torso) ---
//
// vis_flinch_until / vis_flinch_hitgroup are FORWARD-DECLARED in
// client/cl_customdefs.qc so shared/sh_weapon_logic.qc (compiled
// earlier) can predict the flinch in CSQC_SendHitclaim.  While
// `vis_flinch_until > cltime`, the predraw below overrides anim_top
// with CSANIM_GUT_FLINCH / CSANIM_HEAD_FLINCH per
// vis_flinch_hitgroup.  The lerp machinery above handles the blend
// in and out of the flinch automatically — anim_top changes are
// detected as normal transitions.
// extrap_error_* fields live in client/cl_customdefs.qc so
// CSQC_SmoothSetOrigin (defined earlier in this file) can see them.

// Weapon attachment entity + state
.entity vis_weapon_ent;
.string vis_weapon_model;

float spec_target;
float spec_mode;
const float SPEC_MODE_FIRSTPERSON_FWD = 0;  // must match cl_spectate.qc

float(entity e) PlayerVis_ModelIsIQM =
{
	float len = strlen(e.model);
	if (len < 4)
		return FALSE;
	return (substring(strtolower(e.model), len - 4, 4) == ".iqm");
};

float(float skel, string name) PlayerVis_FindBone =
{
	if (!skel)
		return 0;
	return skel_find_bone(skel, name);
};

// Bone name array for skeleton mirroring (from cstrike/src/shared/skeleton.h).
// Used to copy bone positions from the player to the weapon attachment.
// These names match what FTE uses internally for HLMDL bone lookup.
string g_pbones[] =
{
	"Bip01",
	"Bip01 Footsteps",
	"Bip01 Pelvis",
	"Bip01 L Leg",
	"Bip01 L Leg1",
	"Bip01 L Foot",
	"Bip01 L Toe0",
	"Bip01 L Toe01",
	"Bip01 L Toe02",
	"Dummy16",
	"Bip01 R Leg",
	"Bip01 R Leg1",
	"Bip01 R Foot",
	"Bip01 R Toe0",
	"Bip01 R Toe01",
	"Bip01 R Toe02",
	"Dummy11",
	"Bip01 Spine",
	"Bip01 Spine1",
	"Bip01 Spine2",
	"Bip01 Spine3",
	"Bip01 Neck",
	"Bip01 Head",
	"Dummy21",
	"Dummy08",
	"Bone02",
	"Bone03",
	"Bone04",
	"Dummy05",
	"Bone09",
	"Bone10",
	"Dummy04",
	"Bone05",
	"Bone06",
	"Dummy03",
	"Bone07",
	"Bone08",
	"Dummy09",
	"Bone11",
	"Bone12",
	"Dummy10",
	"Bone13",
	"Bone14",
	"Bone15",
	"Bip01 L Arm",
	"Bip01 L Arm1",
	"Bip01 L Arm2",
	"Bip01 L Hand",
	"Bip01 L Finger0",
	"Bip01 L Finger01",
	"Bip01 L Finger02",
	"Dummy06",
	"Bip01 L Finger1",
	"Bip01 L Finger11",
	"Bip01 L Finger12",
	"Dummy07",
	"Bip01 R Arm",
	"Bip01 R Arm1",
	"Bip01 R Arm2",
	"Bip01 R Hand",
	"Bip01 R Finger0",
	"Bip01 R Finger01",
	"Bip01 R Finger02",
	"Dummy01",
	"Bip01 R Finger1",
	"Bip01 R Finger11",
	"Bip01 R Finger12",
	"Dummy02",
	"Box02",
	"Bone08",
	"Bone15"
};

// ============================================================
//  Spine deformer — replaces HL bonecontrol on IQM models
// ============================================================
//
// `PlayerVis_TwistBone` and `PlayerVis_PitchBone` apply an
// in-place rotation to a single bone in the proxy's skeletonobject.
// The rotation axis is the bone's OWN local axis.  On the converted
// CS IQMs, local +X (v_forward) runs up the spine, so rotating around
// it yaws the upper body.  Local +Z (v_up) is the lateral bend axis;
// rotating around it pitches the torso up/down.  Local +Y behaves
// like a roll axis on these files, which is why the first pass leaned
// left/right when aiming vertically.
//
// The bone's origin and the axis NOT being rotated stay untouched,
// so chained bones (Spine → Spine1 → Spine2 → Spine3 → Neck) can
// each take a fraction of the total deformation and the result
// distributes smoothly across the spine.
//
// If the bone-axis convention in the user's IQMs is different
// (e.g. +X is forward instead of up-the-spine), the rotations will
// bend the model the wrong way.  Easy to spot in-game; in that
// case swap the cos/sin formula to rotate the other plane.

const float PI_RAD = 3.14159265358979;

float(float f) PlayerVis_FloatGood =
{
	return (fabs(f) < 100000);
};

float(vector v) PlayerVis_VectorGood =
{
	return (PlayerVis_FloatGood(v_x)
	     && PlayerVis_FloatGood(v_y)
	     && PlayerVis_FloatGood(v_z));
};

float() PlayerVis_TagBasisGood =
{
	if (!PlayerVis_VectorGood(v_forward)
	    || !PlayerVis_VectorGood(v_right)
	    || !PlayerVis_VectorGood(v_up)
	    || vlen(v_forward) < 0.001
	    || vlen(v_right) < 0.001
	    || vlen(v_up) < 0.001)
		return FALSE;
	return TRUE;
};

float(float skel, float bone_idx) PlayerVis_LoadBoneBasis =
{
	if (bone_idx <= 0 || skel == 0)
		return FALSE;

	skel_get_bonerel(skel, bone_idx);

	if (!PlayerVis_VectorGood(v_forward)
	    || !PlayerVis_VectorGood(v_right)
	    || !PlayerVis_VectorGood(v_up)
	    || vlen(v_forward) < 0.001
	    || vlen(v_right) < 0.001
	    || vlen(v_up) < 0.001)
		return FALSE;

	// IQM frame blending can leave basis vectors slightly scaled.  Normalize
	// and orthogonalize before applying extra rotations so addentity/gettaginfo
	// never see an increasingly squashed bone matrix.
	vector old_f = v_forward;
	vector old_r = v_right;
	vector old_u = v_up;
	vector lf = normalize(old_f);
	vector lu = old_u - lf * (old_u * lf);
	if (vlen(lu) < 0.001)
		lu = crossproduct(old_r, lf);
	if (vlen(lu) < 0.001)
		return FALSE;
	lu = normalize(lu);
	vector lr = crossproduct(lf, lu);
	if (vlen(lr) < 0.001)
		return FALSE;
	lr = normalize(lr);
	if (lr * old_r < 0)
	{
		lr = -lr;
		lu = -lu;
	}

	v_forward = lf;
	v_right   = lr;
	v_up      = lu;
	return TRUE;
};

void(float skel) PlayerVis_OrthonormalizeSkeleton =
{
	float n = skel_get_numbones(skel);
	float i;
	for (i = 1; i <= n; i++)
	{
		vector bone_org = skel_get_bonerel(skel, i);
		if (!PlayerVis_VectorGood(bone_org))
			bone_org = '0 0 0';
		if (PlayerVis_LoadBoneBasis(skel, i))
			skel_set_bone(skel, i, bone_org, v_forward, v_right, v_up);
		else
			skel_set_bone(skel, i, bone_org, '1 0 0', '0 1 0', '0 0 1');
	}
};

// Orthonormalize a SINGLE bone.  perf: the spine deform only rotates 5 bones, so
// only those need the IQM-blend scaling cleanup — not all ~50 (see the predraw).
void(float skel, float bone_idx) PlayerVis_OrthonormalizeBone =
{
	if (bone_idx <= 0)
		return;
	vector bone_org = skel_get_bonerel(skel, bone_idx);
	if (!PlayerVis_VectorGood(bone_org))
		bone_org = '0 0 0';
	if (PlayerVis_LoadBoneBasis(skel, bone_idx))
		skel_set_bone(skel, bone_idx, bone_org, v_forward, v_right, v_up);
	else
		skel_set_bone(skel, bone_idx, bone_org, '1 0 0', '0 1 0', '0 0 1');
};

void(float skel) PlayerVis_BuildPoseSkeleton =
{
	float splitbone = self.basebone;

	// Build torso/base and legs/regular as separate skel_build calls.
	// A single call spanning both framestate groups can make FTE's
	// alias skeleton blender reuse the wrong group's pose data, which
	// freezes locomotion bones once an explicit skeleton is attached.
	if (splitbone > 1)
	{
		skel_build(skel, self, self.modelindex, 0, 1, splitbone);
		skel_build(skel, self, self.modelindex, 0, splitbone, 0);
	}
	else
	{
		skel_build(skel, self, self.modelindex, 0, 0, 0);
	}
};

// Twist a bone around its own local +X (v_forward).  HL biped
// convention: +X runs up the spine, so this rotates yaw around the
// spine — the per-bone body-twist contribution.
void(float skel, float bone_idx, float deg) PlayerVis_TwistBone =
{
    vector bone_org = skel_get_bonerel(skel, bone_idx);
    if (!PlayerVis_LoadBoneBasis(skel, bone_idx))
        return;
    vector lf = v_forward, lr = v_right, lu = v_up;
    float c = cos(deg * PI_RAD / 180);
    float s = sin(deg * PI_RAD / 180);
    // Rotate (right, up) plane around forward.
    vector new_right = lr * c + lu * s;
    vector new_up    = -lr * s + lu * c;
    skel_set_bone(skel, bone_idx, bone_org, lf, new_right, new_up);
};

// Pitch a bone around its own local +Z (v_up).  On these converted
// CS IQMs, local +Y is roll; +Z gives the forward/back torso bend.
void(float skel, float bone_idx, float deg) PlayerVis_PitchBone =
{
    vector bone_org = skel_get_bonerel(skel, bone_idx);
    if (!PlayerVis_LoadBoneBasis(skel, bone_idx))
        return;
    vector lf = v_forward, lr = v_right, lu = v_up;
    float c = cos(deg * PI_RAD / 180);
    float s = sin(deg * PI_RAD / 180);
    // Rotate (forward, right) plane around up.
    vector new_fwd   = lf * c - lr * s;
    vector new_right = lf * s + lr * c;
    skel_set_bone(skel, bone_idx, bone_org, new_fwd, new_right, lu);
};

// nettest perf: corpse skeleton freeze.  A settled corpse holds a static death
// pose, so it does NOT need its ~50-bone IQM skeleton rebuilt + orthonormalized
// every frame (the dominant client cost when many dead bodies are on screen).
// The death/fall animation plays for VIS_CORPSE_FREEZE_DELAY seconds, then the
// per-frame skeleton rebuild is skipped and the persisted skeleton holds the
// final pose.  Live players are unaffected (they keep rebuilding).
const float VIS_CORPSE_FREEZE_DELAY = 4.0;   // fallback freeze delay when frameduration can't read the death-anim length
.float vis_death_cltime;    // cltime when this proxy became a corpse (0 = alive/never)
.float vis_skel_was_dead;   // edge-detects the alive->dead transition for the stamp

// nettest perf: PlayerVis_ModelIsIQM does strlen+strtolower+substring on .model
// every frame, but the model type is constant for a given modelindex (it only
// changes on an identity model swap).  Cache the bool keyed on modelindex; the
// modelindex-match doubles as the validity check (no literal initializer, per the
// fteqcc const-global-initializer trap).
.float vis_is_iqm;          // cached PlayerVis_ModelIsIQM result
.float vis_is_iqm_mdl;      // modelindex the cache was computed for (0 = stale)

// nettest perf: the spine-deform cvars are identical for every proxy in a frame
// but were re-read via cvar() per proxy; cache them once per frame.  The spine
// bone indices are model-constant but were re-found via skel_find_bone (a string
// walk) per proxy every frame; cache them per proxy keyed on modelindex.
float g_spine_cv_time;
float g_spine_deform, g_spine_twist_scale, g_spine_twist_max, g_spine_twist_waist;
float g_spine_twist_upper, g_spine_pitch_scale, g_spine_pitch_upper, g_spine_pitch_max;
float g_spine_idle_rate;    // cl_player_skel_idle_rate: rebuild Hz for STILL players (0 = every frame)
.float vis_spine_sb0, vis_spine_sb1, vis_spine_sb2, vis_spine_sb3, vis_spine_sbn;
.float vis_spine_bones_mdl;
.float vis_skel_next_rebuild;   // next cltime an idle proxy may rebuild its skeleton

// nettest perf: corpse render cull (the only QC lever on the engine scene floor —
// not submitting an off-screen corpse removes its edict-copy + skin from the
// 2.46s CSQC_UpdateViewAliveScene cost).  Scoped to SETTLED corpses only.  Cvars
// (r_corpses_pvscull default 1, r_corpses_maxdist default 0) are identical for
// every proxy in a frame, so cache them + the view origin once per frame.
float  g_corpse_cull_time;
float  g_corpse_pvscull;
float  g_corpse_maxdist_sq;
vector g_corpse_vieworg;

void() PlayerVis_RefreshCorpseCull =
{
    if (cltime == g_corpse_cull_time)
        return;
    g_corpse_cull_time  = cltime;
    g_corpse_pvscull    = cvar("r_corpses_pvscull");
    float md            = cvar("r_corpses_maxdist");
    g_corpse_maxdist_sq = (md > 0) ? md * md : 0;
    g_corpse_vieworg    = (vector)getproperty(VF_ORIGIN);
};

void() PlayerVis_RefreshSpineCvars =
{
	if (cltime == g_spine_cv_time)
		return;
	g_spine_cv_time      = cltime;
	g_spine_deform       = cvar("cl_player_spine_deform");
	g_spine_twist_scale  = cvar("cl_player_spine_twist_scale");
	g_spine_twist_max    = cvar("cl_player_spine_twist_max");
	if (g_spine_twist_max <= 0) g_spine_twist_max = 50;
	g_spine_twist_waist  = bound(0, cvar("cl_player_spine_twist_waist_scale"), 2);
	g_spine_twist_upper  = bound(0, cvar("cl_player_spine_twist_upper_scale"), 2);
	g_spine_pitch_scale  = cvar("cl_player_spine_pitch_scale");
	g_spine_pitch_upper  = bound(0, cvar("cl_player_spine_pitch_upper_scale"), 2);
	g_spine_pitch_max    = cvar("cl_player_spine_pitch_max");
	if (g_spine_pitch_max <= 0) g_spine_pitch_max = 35;
	g_spine_idle_rate    = cvar("cl_player_skel_idle_rate");
};

float() CSQC_PlayerVisual_Predraw =
{
	float spine_debug = cvar("cl_player_spine_debug");

	// Hide the visual proxy when we shouldn't see it:
	// 1. Own body in first person (not chase cam, not spectating, not death cam)
	// 2. Spectated player's body in first-person spectate mode
	// Death cam is a 3rd-person orbit around spec_death_origin — the corpse
	// should be visible there, so keep our own proxy drawn while it's active.
	//
	// Corpses (vis_is_dead) are NEVER hidden by the first-person rule —
	// we want to see our own body on the ground after respawning.
	// Per-frame Sync no longer touches the corpse, so vis_is_dead stays
	// at the moment-of-death value (=1) for the life of the corpse.
	if (self.vis_owner_entnum == player_localentnum
	    && !self.vis_is_dead
	    && spec_target == 0 && !cvar("chase_active")
	    && !Spectate_InDeathCam())
	{
		if (spine_debug && cltime >= self.vis_spine_debug_next)
		{
			print(sprintf("[spine] local proxy hidden: owner=%g model='%s' chase_active=%g\n",
			              self.vis_owner_entnum, self.model, cvar("chase_active")));
			self.vis_spine_debug_next = cltime + 0.5;
		}
		return PREDRAW_NEXT;
	}

	// Hide the spectated player's proxy so it doesn't block the first-
	// person view. NOT during death-cam: that's a 3rd-person orbit
	// around our corpse, and spec_target gets pre-populated with the
	// killer's entnum — without this guard the killer's proxy would
	// vanish from view the instant we die. Mirrors the VF_VIEWENTITY
	// gate in cl_main.qc CSQC_UpdateView (also Spectate_InDeathCam-
	// excluded).
	if (spec_target > 0 && spec_mode == SPEC_MODE_FIRSTPERSON_FWD
	    && self.vis_owner_entnum == spec_target
	    && !Spectate_InDeathCam())
		return PREDRAW_NEXT;

	// Snap local player's proxy to predicted position so it doesn't
	// flicker between server snapshots when in chase_active.
	//
	// Corpses must NOT be snapped — they share vis_owner_entnum with the
	// (now-respawning) live proxy, so without this guard the corpse
	// would teleport to the live player's predicted position every
	// frame and visibly follow them around.
	if (self.vis_owner_entnum == player_localentnum
	    && !self.vis_is_dead
	    && predicted_player
	    && csqc_prediction_valid)
		setorigin(self, csqc_present_origin);

	float dt;
	if (self.vis_prev_cltime > 0)
		dt = cltime - self.vis_prev_cltime;
	else
		dt = 0;
	self.vis_prev_cltime = cltime;
	dt = bound(0, dt, 0.1);

	if (self.vis_anim_bottom != self.vis_last_anim_bottom)
	{
		// Capture OLD anim + its current playback time as frame2
		// source for the upcoming lerp.  vis_last_anim_bottom == 0
		// happens on the very first frame after proxy spawn — skip
		// the lerp there (no prior pose to blend from) so the
		// initial appearance is a clean snap to the first anim.
		if (self.vis_last_anim_bottom != 0)
		{
			self.vis_lerp_bot_prev_anim = self.vis_last_anim_bottom;
			self.vis_lerp_bot_prev_time = self.vis_anim_bottom_time;
			self.vis_lerp_bot_start     = cltime;
		}
		self.vis_anim_bottom_time = 0;
		self.vis_last_anim_bottom = self.vis_anim_bottom;
	}

	// --- Effective torso anim (with flinch override) ---
	// While vis_flinch_until > cltime, the torso shows the gut /
	// head flinch sequence instead of the server-sent anim_top.
	// Compare against the EFFECTIVE value (not vis_anim_top) so the
	// lerp machinery treats flinch entry/exit as normal transitions
	// and blends them in / out smoothly.
	float effective_anim_top = self.vis_anim_top;
	float effective_anim_top_gen = self.vis_anim_top_gen;
	if (self.vis_flinch_until > cltime)
	{
		effective_anim_top = (self.vis_flinch_hitgroup == HITGROUP_HEAD)
		                     ? CSANIM_HEAD_FLINCH : CSANIM_GUT_FLINCH;
		// Hold a constant fake gen while flinching so a server
		// snapshot bumping the underlying gen doesn't retrigger
		// change-detection mid-flinch.
		effective_anim_top_gen = -1;
	}

	if (effective_anim_top != self.vis_last_anim_top
	    || effective_anim_top_gen != self.vis_last_anim_top_gen)
	{
		if (self.vis_last_anim_top != 0)
		{
			self.vis_lerp_top_prev_anim = self.vis_last_anim_top;
			self.vis_lerp_top_prev_time = self.vis_anim_top_time;
			self.vis_lerp_top_start     = cltime;
		}
		self.vis_anim_top_time = 0;
		self.vis_last_anim_top = effective_anim_top;
		self.vis_last_anim_top_gen = effective_anim_top_gen;
	}
	self.vis_anim_top_time += dt;

	// --- Strafe body twist + backpedal detection ---
	// Compute BEFORE animation timer so we know if we're backpedaling.
	self.angles_y = self.vis_aim_yaw;  // reset to original aim each frame

	vector vel2d = self.velocity; vel2d_z = 0;
	float speed2d = vlen(vel2d);
	float leg_twist = 0;
	float backpedaling = FALSE;
	float backpedal_enter = cvar("cl_player_backpedal_enter_angle");
	float backpedal_exit = cvar("cl_player_backpedal_exit_angle");
	if (backpedal_enter <= 0) backpedal_enter = 150;
	if (backpedal_exit <= 0) backpedal_exit = 100;
	backpedal_enter = bound(91, backpedal_enter, 179);
	backpedal_exit = bound(1, backpedal_exit, backpedal_enter - 1);

	if (speed2d > 10)
	{
		float vel_yaw = vectoyaw(vel2d);
		float yaw_diff = vel_yaw - self.vis_aim_yaw;
		// Normalize to -180..180
		yaw_diff -= floor((yaw_diff + 180) / 360) * 360;

		// Hysteresis keeps pure strafing stable while the player makes
		// small aim corrections near 90 degrees. Enter backpedal late,
		// leave it earlier, then mirror the leg angle.
		float abs_yaw_diff = fabs(yaw_diff);
		if (self.vis_backpedaling)
		{
			if (abs_yaw_diff < backpedal_exit)
				self.vis_backpedaling = FALSE;
		}
		else if (abs_yaw_diff > backpedal_enter)
			self.vis_backpedaling = TRUE;

		if (self.vis_backpedaling)
		{
			backpedaling = TRUE;
			// Flip: 135° becomes -45°, -135° becomes 45°, 180° becomes 0°
			if (yaw_diff > 0)
				yaw_diff = yaw_diff - 180;
			else
				yaw_diff = yaw_diff + 180;
		}

		float speed_frac = bound(0, speed2d / 250, 1);
		leg_twist = yaw_diff * speed_frac;
	}
	else
		self.vis_backpedaling = FALSE;

	// Rotate whole model toward movement (legs face walk direction)
	self.angles_y += leg_twist;

	// Counter-rotate upper body back to aim direction via subblendfrac.
	self.subblendfrac = bound(-1, leg_twist / 90, 1);

	// Animation timer: for locomotion (RUN/CROUCH_RUN), advance by distance
	// traveled so feet sync to the ground. For idle/jump, use regular time.
	// The dev's formula: frame1time += dot(delta, v_forward) / qu_per_sec
	float is_locomotion = (self.vis_anim_bottom == CSANIM_RUN
	                    || self.vis_anim_bottom == CSANIM_RUN_CROUCH);

	if (is_locomotion && speed2d > 1)
	{
		// How many QU the walk cycle covers per second of animation time.
		// Higher = faster foot cycle. Crouch run uses its own value
		// (sv_anim_qu_per_sec_crouch, default 100) since crouch movement
		// is slower — sharing one value made the legs cycle look right
		// standing but glacial when crouching.
		float qu_per_sec;
		if (self.vis_anim_bottom == CSANIM_RUN_CROUCH)
		{
			qu_per_sec = cvar("sv_anim_qu_per_sec_crouch");
			if (qu_per_sec <= 0) qu_per_sec = 100;
		}
		else
		{
			qu_per_sec = cvar("sv_anim_qu_per_sec");
			if (qu_per_sec <= 0) qu_per_sec = 240;
		}

		vector delta = self.origin - self.vis_prev_origin;
		delta_z = 0;  // horizontal distance only
		makevectors([0, self.angles_y, 0]);

		float dist_fwd = delta * v_forward;
		if (backpedaling)
			dist_fwd = -fabs(dist_fwd);  // ensure negative for reverse

		self.vis_anim_bottom_time += dist_fwd / qu_per_sec;
	}
	else
	{
		// Idle/jump: regular time-based advancement
		if (backpedaling)
			self.vis_anim_bottom_time -= dt;
		else
			self.vis_anim_bottom_time += dt;
	}
	self.vis_prev_origin = self.origin;

	// Wrap negative time so engine doesn't choke (valve hack)
	if (self.vis_anim_bottom_time < 0)
		self.vis_anim_bottom_time = 10.0;

	// FTE basebone: bones < basebone → .baseframe, bones >= basebone → .frame
	//
	// Our model: torso at LOW indices, legs at HIGH indices (L Thigh=43+).
	// Split at first leg bone so:
	//   .baseframe = aim (torso)       → bones < basebone
	//   .frame     = locomotion (legs) → bones >= basebone
	self.frame          = self.vis_anim_bottom;       // legs (NEW)
	self.frame1time     = self.vis_anim_bottom_time;
	self.baseframe      = effective_anim_top;         // torso (NEW, flinch-overridden)
	self.baseframe1time = self.vis_anim_top_time;

	// Inter-sequence blend — write the OLD anim + a 1→0 lerpfrac
	// across `cl_player_anim_lerp_time` so legs/torso transitions
	// (e.g. run → idle) interpolate instead of snapping.  See the
	// vis_lerp_* field declarations above for the convention.
	// frame2time advances during the window so the OLD anim keeps
	// playing through the blend — limbs continue their motion
	// while the new pose blends in over the top.
	float lerp_dur = PlayerVis_LerpDuration();
	float bot_elapsed = cltime - self.vis_lerp_bot_start;
	if (lerp_dur > 0 && self.vis_lerp_bot_start > 0 && bot_elapsed < lerp_dur)
	{
		self.frame2     = self.vis_lerp_bot_prev_anim;
		self.frame2time = self.vis_lerp_bot_prev_time + bot_elapsed;
		self.lerpfrac   = 1 - (bot_elapsed / lerp_dur);
	}
	else
	{
		// Past the lerp window — fully on the new anim.
		self.lerpfrac = 0;
	}

	float top_elapsed = cltime - self.vis_lerp_top_start;
	if (lerp_dur > 0 && self.vis_lerp_top_start > 0 && top_elapsed < lerp_dur)
	{
		self.baseframe2     = self.vis_lerp_top_prev_anim;
		self.baseframe2time = self.vis_lerp_top_prev_time + top_elapsed;
		self.baselerpfrac   = 1 - (top_elapsed / lerp_dur);
	}
	else
	{
		self.baselerpfrac = 0;
	}

	float bb = cvar("sv_player_basebone");
	if (bb <= 0) bb = gettagindex(self, "Bip01 L Thigh");
	self.basebone = bb;

	// Torso aim blending via subblend fracs (.frame side).
	// subblend2frac = Y axis (pitch / up-down aiming)
	float sb = self.vis_pitch / 90;
	self.subblend2frac = sb;

	// Progressive spine twist via bonecontrol (HL studio only — IQM
	// models ignore .bonecontrolN; the skel-based deformer below
	// replaces it for IQM).  Left as-is so the old MDLs we may load
	// (sini, chickenman, numberK, Kilmer) still get the spine twist.
	makevectors([0, self.angles_y, 0]);
	float fCorrect = dotproduct(self.velocity, v_right) * 0.25;
	self.bonecontrol1 = fCorrect;
	self.bonecontrol2 = fCorrect * 0.5;
	self.bonecontrol3 = fCorrect * 0.25;
	self.bonecontrol4 = fCorrect * 0.125;

	// IQM spine deformer — applies body twist (strafe yaw of the
	// lower spine) and pitch-aim (torso looking up/down for view
	// pitch) directly to spine bone matrices via skel_set_bone.
	// HL bone-controllers and HL aim-pitch subblend do nothing on
	// mod_alias models; this reproduces both effects in QC.
	//
	// Flow per frame:
	//   1. skel_build populates the skeleton from the current
	//      frame+frame2+lerpfrac state (engine handles inter-
	//      sequence blending automatically for IQM via
	//      Alias_BlendBoneData).
	//   2. We modify 4 spine bones (Spine, Spine1, Spine2, Spine3)
	//      with fractional yaw + pitch — fractions distribute the
	//      twist across the spine like the old HL controllers did
	//      (bigger fraction on the upper bones for pitch so the
	//      head ends up looking where you aim).
	//   3. Engine renders using the skeleton (skeletonindex != 0).
	//      Weapon attachment further down also sees these modified
	//      bones via gettaginfo, so the gun follows the twist/pitch.
	//
	// Gated on cl_player_spine_deform so users can disable for A/B
	// testing.  Also skipped on HL studio models (sini etc.) since
	// they already have working bone-controllers + subblend.
	// Cached per proxy keyed on modelindex (recompute only on a model swap).
	if (self.vis_is_iqm_mdl != self.modelindex)
	{
		self.vis_is_iqm     = PlayerVis_ModelIsIQM(self);
		self.vis_is_iqm_mdl = self.modelindex;
	}
	float is_iqm_player = self.vis_is_iqm;
	if (!is_iqm_player && self.skeletonindex)
	{
		skel_delete(self.skeletonindex);
		self.skeletonindex = 0;
		self.vis_skel_modelindex = 0;
	}

	// nettest perf: edge-detect the alive->dead transition so the corpse skeleton
	// freeze (below) knows when this body died.  Runs for every visible proxy;
	// corpses are NOT hidden by the first-person guard above, so they reach here.
	if (self.vis_is_dead != self.vis_skel_was_dead)
	{
		if (self.vis_is_dead)
			self.vis_death_cltime = cltime;
		self.vis_skel_was_dead = self.vis_is_dead;
	}

	// perf: corpse render cull — the only QC lever on the engine scene floor
	// (skip the addentity entirely for a body you can't see).  GATED on the body
	// being a SETTLED corpse: keyed off the SAME frameduration freeze the skeleton
	// uses, so we never cull a corpse mid-fall (the death anim keeps rebuilding
	// while unculled, so by settle time the skeleton already holds the final pose;
	// culling earlier could freeze a half-fall on PVS re-entry).  Placed AFTER the
	// vis_death_cltime stamp so a body that dies off-screen still latches its death
	// time + freeze.  checkpvs is fail-safe (returns visible when PVS data is
	// missing, e.g. CoD), so it never hides a corpse in your line of sight.
	// r_corpses_pvscull 1 (default), r_corpses_maxdist 0 = distance off (default).
	if (self.vis_is_dead && self.vis_death_cltime > 0)
	{
		float cull_age  = cltime - self.vis_death_cltime;
		float cull_ddur = frameduration(self.modelindex, self.vis_anim_bottom);
		if (cull_ddur <= 0)
			cull_ddur = VIS_CORPSE_FREEZE_DELAY;
		if ((cull_age > cull_ddur + 0.4) || (cull_age > 8.0))
		{
			PlayerVis_RefreshCorpseCull();
			if (g_corpse_maxdist_sq > 0)
			{
				vector cull_dv = self.origin - g_corpse_vieworg;
				if ((cull_dv * cull_dv) > g_corpse_maxdist_sq)
					return PREDRAW_NEXT;
			}
			if (g_corpse_pvscull && !checkpvs(g_corpse_vieworg, self))
				return PREDRAW_NEXT;
		}
	}

	PlayerVis_RefreshSpineCvars();           // perf: read the 8 spine cvars once/frame
	float twist_scale       = g_spine_twist_scale;
	float twist_max         = g_spine_twist_max;
	float twist_waist_scale = g_spine_twist_waist;
	float twist_upper_scale = g_spine_twist_upper;
	float pitch_scale       = g_spine_pitch_scale;
	float pitch_upper_scale = g_spine_pitch_upper;
	float spine_has_work = (twist_scale != 0 || pitch_scale != 0);

	if (spine_debug
	    && cltime >= self.vis_spine_debug_next
	    && (!g_spine_deform || !is_iqm_player || !self.modelindex || !spine_has_work))
	{
		print(sprintf("[spine] inactive: ent=%g model='%s' modelindex=%g iqm=%g deform=%g scales=%.2f/%.2f\n",
		              self.vis_owner_entnum, self.model, self.modelindex,
		              is_iqm_player, g_spine_deform,
		              twist_scale, pitch_scale));
		self.vis_spine_debug_next = cltime + 0.5;
	}

	// nettest Patch 36 (revised): the CLIENT visual proxy keeps its QC skel_build skeleton
	// + skel_set_bone spine deform — that is what renders the proxy AND what the client's
	// MOVE_HITMODEL bullet trace poses against (via the skeleton's bonestate), so render and
	// trust-1 hit detection stay in lock-step.  The engine-native spine bend (r_skel_spinebend)
	// is for entities WITHOUT a QC skeleton — i.e. the SERVER player (its skeleton is cleared
	// each tick) — so trust-0 server hit detection leans correctly.  The engine bend explicitly
	// SKIPS any entity that has a skeletal object (Alias_SpineBendActive in com_mesh.c), so the
	// client proxy is never double-bent.  Applying the engine bend directly to the proxy (the
	// earlier Part A approach) warped the pose/gun — hence this split.
	if ((!g_spine_deform || !spine_has_work) && self.skeletonindex)
	{
		skel_delete(self.skeletonindex);
		self.skeletonindex = 0;
		self.vis_skel_modelindex = 0;
	}

	if (g_spine_deform && spine_has_work && is_iqm_player && self.modelindex)
	{
		// One-time skeleton allocation per proxy.  Reused across
		// frames; the proxy entity's remove path tears it down.
		float fresh_skel = FALSE;
		if (self.skeletonindex && self.vis_skel_modelindex != self.modelindex)
		{
			skel_delete(self.skeletonindex);
			self.skeletonindex = 0;
			self.vis_skel_modelindex = 0;
		}
		if (!self.skeletonindex)
		{
			self.skeletonindex = skel_create(self.modelindex);
			self.vis_skel_modelindex = self.modelindex;
			fresh_skel = TRUE;
		}

		// nettest perf: a settled corpse holds a static death pose — skip the
		// per-frame ~50-bone rebuild + orthonormalize + spine deform (the dominant
		// cost with many dead bodies on screen).  The persisted skeletonindex keeps
		// the last-built (settled) pose, which addentity still renders.  A freshly
		// (re)created skeleton always builds once so it's never left in bind pose.
		//
		// Freeze only AFTER the death animation has fully PLAYED.  A flat delay
		// froze long falls mid-animation ("stuck half falling"), so key off the
		// death seq's own frameduration (+ a settle margin) rather than a constant.
		// Fall back to VIS_CORPSE_FREEZE_DELAY if frameduration whiffs, and a hard
		// 8s cap guarantees the corpse always freezes eventually.
		float corpse_frozen = FALSE;
		if (self.vis_is_dead && self.vis_death_cltime > 0)
		{
			float corpse_age = cltime - self.vis_death_cltime;
			float death_dur  = frameduration(self.modelindex, self.vis_anim_bottom);
			if (death_dur <= 0)
				death_dur = VIS_CORPSE_FREEZE_DELAY;
			corpse_frozen = (corpse_age > death_dur + 0.4) || (corpse_age > 8.0);
		}

		// perf (b): rate-limit STILL live players' rebuild.  A standing crowd's
		// breathing pose barely changes, yet re-solving the skeleton every frame
		// is the top idle-server cost.  Fresh skeletons AND moving players rebuild
		// every frame (smooth animation); corpses use the freeze above.  The trace
		// poses against this same cached skeleton (Patch 36), so render + trust-1
		// hit detection stay consistent at the lower rate.  cl_player_skel_idle_rate
		// 0 = always rebuild.
		float do_rebuild = TRUE;
		if (corpse_frozen && !fresh_skel)
			do_rebuild = FALSE;
		else if (!fresh_skel && !self.vis_is_dead && g_spine_idle_rate > 0
		         && vlen(self.velocity) <= 8)
		{
			do_rebuild = (cltime >= self.vis_skel_next_rebuild);
			if (do_rebuild)
				self.vis_skel_next_rebuild = cltime + 1.0 / g_spine_idle_rate;
		}

		if (self.skeletonindex && do_rebuild)
		{
			// Rebuild the skeleton from the current animated pose.  Split
			// the baseframe/regular-frame bone ranges so locomotion bones
			// keep animating while the torso gets its own aim/fire pose.
			PlayerVis_BuildPoseSkeleton(self.skeletonindex);

			// perf: spine bone indices are model-constant — cache per proxy and
			// re-find (skel_find_bone string walk) only when the model changes.
			float sb0, sb1, sb2, sb3, sbn;
			if (self.vis_spine_bones_mdl == self.modelindex)
			{
				sb0 = self.vis_spine_sb0; sb1 = self.vis_spine_sb1;
				sb2 = self.vis_spine_sb2; sb3 = self.vis_spine_sb3;
				sbn = self.vis_spine_sbn;
			}
			else
			{
				sb0 = PlayerVis_FindBone(self.skeletonindex, "Bip01 Spine");
				sb1 = PlayerVis_FindBone(self.skeletonindex, "Bip01 Spine1");
				sb2 = PlayerVis_FindBone(self.skeletonindex, "Bip01 Spine2");
				sb3 = PlayerVis_FindBone(self.skeletonindex, "Bip01 Spine3");
				sbn = PlayerVis_FindBone(self.skeletonindex, "Bip01 Neck");
				self.vis_spine_sb0 = sb0; self.vis_spine_sb1 = sb1;
				self.vis_spine_sb2 = sb2; self.vis_spine_sb3 = sb3;
				self.vis_spine_sbn = sbn;
				self.vis_spine_bones_mdl = self.modelindex;
			}

			// perf (a): orthonormalize ONLY the 5 spine bones the deform rotates
			// (was all ~50 every frame — the dominant idle-server cost).  The
			// IQM-blend scaling cleanup is only needed on bones we then rotate; the
			// rest keep skel_build's fresh per-frame pose.
			PlayerVis_OrthonormalizeBone(self.skeletonindex, sb0);
			PlayerVis_OrthonormalizeBone(self.skeletonindex, sb1);
			PlayerVis_OrthonormalizeBone(self.skeletonindex, sb2);
			PlayerVis_OrthonormalizeBone(self.skeletonindex, sb3);
			PlayerVis_OrthonormalizeBone(self.skeletonindex, sbn);

			// Body-twist fractions match the old HL controllers (1.0/0.5/0.25/0.125
			// — bigger near the waist).  Use leg_twist, not fCorrect (which the
			// self.angles_y movement-turn can zero on a pure strafe); leg_twist is
			// the lower-body yaw delta to counter across the spine.
			float iqm_twist = bound(-twist_max, -leg_twist * twist_scale, twist_max);

			if (iqm_twist != 0)
			{
				// Upper-spine fractions scale by twist_upper_scale so the
				// head/shoulders rotate less than the waist when strafing.
				PlayerVis_TwistBone(self.skeletonindex, sb0, iqm_twist * twist_waist_scale);
				PlayerVis_TwistBone(self.skeletonindex, sb1, iqm_twist * 0.5);
				PlayerVis_TwistBone(self.skeletonindex, sb2, iqm_twist * 0.25 * twist_upper_scale);
				PlayerVis_TwistBone(self.skeletonindex, sb3, iqm_twist * 0.125 * twist_upper_scale);
			}

			// Pitch-aim — distribute the view pitch across the
			// spine with bigger fractions toward the head.  Map the
			// full -90..90 view range into -pitch_max..pitch_max; do
			// not clamp raw view pitch early, or the max pose is hit
			// halfway through the player's actual aim range.
			float pitch_max = g_spine_pitch_max;   // perf: cached once/frame
			float pitch_frac = bound(-1, self.vis_pitch / 90, 1);
			float iqm_pitch = bound(-pitch_max, pitch_frac * pitch_max * pitch_scale, pitch_max);
			if (iqm_pitch != 0)
			{
				PlayerVis_PitchBone(self.skeletonindex, sb0, iqm_pitch * 0.05);
				PlayerVis_PitchBone(self.skeletonindex, sb1, iqm_pitch * 0.15);
				PlayerVis_PitchBone(self.skeletonindex, sb2, iqm_pitch * 0.30);
				PlayerVis_PitchBone(self.skeletonindex, sb3, iqm_pitch * 0.35 * pitch_upper_scale);
				PlayerVis_PitchBone(self.skeletonindex, sbn, iqm_pitch * 0.15 * pitch_upper_scale);
			}

			if (spine_debug && cltime >= self.vis_spine_debug_next)
			{
				print(sprintf("[spine] ent=%g model='%s' skel=%g\n",
				              self.vis_owner_entnum, self.model, self.skeletonindex));
				print(sprintf("        bones=%g/%g/%g/%g/%g\n",
				              sb0, sb1, sb2, sb3, sbn));
				print(sprintf("        leg=%.1f twist=%.1f pitch=%.1f scales=%.2f/%.2f max=%.1f\n",
				              leg_twist, iqm_twist, iqm_pitch,
				              twist_scale, pitch_scale, pitch_max));
				print(sprintf("        waist=%.2f bp=%g\n",
				              twist_waist_scale, backpedaling));
				self.vis_spine_debug_next = cltime + 0.5;
			}
		}
	}

	// nettest Patch 36 fix: stash the framestate we just computed (the pose this
	// frame renders) so the prediction-time MOVE_HITMODEL bullet trace — which runs
	// BEFORE this predraw each frame, in CSQC_Input_Frame — can pose the proxy
	// IDENTICALLY to how it renders (restored in W_PlayersExpandHitboxes).  Without
	// this the trace reads last-frame / degenerate .frame+.basebone and the precise
	// per-bone hitboxes (Patch 36 Part B) miss the live silhouette under trust 1.
	self.vis_trace_frame         = self.frame;
	self.vis_trace_frame1time    = self.frame1time;
	self.vis_trace_frame2        = self.frame2;
	self.vis_trace_lerpfrac      = self.lerpfrac;
	self.vis_trace_baseframe     = self.baseframe;
	self.vis_trace_baseframe1time= self.baseframe1time;
	self.vis_trace_baseframe2    = self.baseframe2;
	self.vis_trace_baselerpfrac  = self.baselerpfrac;
	self.vis_trace_basebone      = self.basebone;
	self.vis_trace_subblendfrac  = self.subblendfrac;
	self.vis_trace_subblend2frac = self.subblend2frac;
	self.vis_trace_pose_valid    = 1;

	// Gravity Shift: orient the WHOLE model so its up-axis aligns with the global
	// gravity's "up" (gup = -gravdir), preserving the model's facing yaw — so remote
	// players visibly stand on the wall/ceiling with you (and the per-bone hitboxes,
	// which read .angles, rotate with the model).  Inert when no shift is active.
	vector gs_dir = stov(serverkey("gravdir"));
	if (gs_dir != '0 0 0')
	{
		vector gs_up = '0 0 0' - gs_dir;
		makevectors([0, self.angles_y, 0]);                       // facing from yaw only
		vector gs_fwd = v_forward - gs_up * (v_forward * gs_up);  // project onto the wall plane
		if (vlen(gs_fwd) < 0.01)                                  // facing ~parallel to gup -> fallback
		{
			makevectors([0, self.angles_y + 90, 0]);
			gs_fwd = v_forward - gs_up * (v_forward * gs_up);
		}
		gs_fwd = normalize(gs_fwd);
		self.angles = vectoangles(gs_fwd, gs_up);
	}

	addentity(self);

	// --- Weapon attachment (p_model) ---
	string pmdl = W_GetPModelPath(self.vis_weapon_id);
	if (pmdl != "")
	{
		entity wep = self.vis_weapon_ent;
		if (!wep)
		{
			wep = spawn();
			wep.classname = "player_weapon_attach";
			wep.solid = SOLID_NOT;
			self.vis_weapon_ent = wep;
		}

		// Update model if weapon changed
		if (self.vis_weapon_model != pmdl)
		{
			setattachment(wep, world, "");
			setmodel(wep, pmdl);
			self.vis_weapon_model = pmdl;
			if (wep.skeletonindex)
				skel_delete(wep.skeletonindex);
			wep.skeletonindex = 0;
		}

		if (wep.modelindex)
		{
			if (!wep.skeletonindex)
				wep.skeletonindex = skel_create(wep.modelindex);

			if (wep.skeletonindex)
			{
				// Build the weapon skeleton from its own default pose
				skel_build(wep.skeletonindex, wep, wep.modelindex, 0, 0, -1);

				// Park the weapon entity at the player's origin BEFORE
				// the bone-mirror loop runs.  FTE samples the lightmap
				// at entity.origin — a zeroed origin samples world
				// (0,0,0), almost always inside a wall or void, so the
				// gun rendered solid black against whatever room the
				// player walked into.  Co-locating with the player
				// origin makes the lightmap sample land on the same
				// floor / surface lighting the player picks up.
				//
				// Safe vs. the bone math: skel_set_bone_world stores
				// each bone as inv(entity_matrix * parent_matrix) *
				// world_target (engine/client/pr_skelobj.c:2381-2444),
				// so the entity origin / angles cancel out at render
				// time AS LONG AS they match what they were at
				// skel_set_bone_world call time.  Setting origin here
				// (before the loop) and leaving it unchanged through
				// addentity preserves that invariant.  Angles stay
				// '0 0 0' — including non-zero player angles would
				// pre-rotate the bone basis and the gun would spin
				// with the player's yaw on top of the bone pose.
				setattachment(wep, world, "");
				setorigin(wep, self.origin);
				wep.angles = '0 0 0';

				// Mirror player bones → weapon bones (valve pattern)
				float i, pbone, wbone;
				vector bpos;
				float matched = 0;
				for (i = 0; i < g_pbones.length; i++)
				{
					pbone = gettagindex(self, g_pbones[i]);
					wbone = gettagindex(wep, g_pbones[i]);
					if (wbone > 0 && pbone > 0)
					{
						bpos = gettaginfo(self, pbone);
						if (!PlayerVis_VectorGood(bpos) || !PlayerVis_TagBasisGood())
							continue;
						skel_set_bone_world(wep, wbone, bpos, v_forward, v_right, v_up);
						matched = matched + 1;
					}
				}

				if (matched > 0)
				{
					addentity(wep);
				}
				else
				{
					// Fallback for pmodels whose mdl skeleton uses bone
					// names that don't match the Bip01 set (or has no
					// frame data so the engine doesn't expose tags).
					// setattachment hangs the weapon entity off the
					// player's right-hand tag — engine handles the
					// per-frame follow.  Pose won't track individual
					// finger bones, but the weapon at least sits in the
					// hand instead of teleporting to world origin.
					float hand = gettagindex(self, "Bip01 R Hand");
					if (hand > 0)
					{
						setattachment(wep, self, "Bip01 R Hand");
						wep.angles = '0 0 0';
						addentity(wep);
					}
				}
			}
		}
	}
	else if (self.vis_weapon_ent)
	{
		// No weapon — hide attachment
		if (self.vis_weapon_ent.skeletonindex)
		{
			skel_delete(self.vis_weapon_ent.skeletonindex);
			self.vis_weapon_ent.skeletonindex = 0;
		}
		setattachment(self.vis_weapon_ent, world, "");
		remove(self.vis_weapon_ent);
		self.vis_weapon_ent = world;
		self.vis_weapon_model = "";
	}

	return PREDRAW_NEXT;
};

// Mirror of server's VP_SF_* — sectioned sends to skip unchanged fields.
const float VP_SF_POSE_CL     = 1;
const float VP_SF_ANIM_CL     = 2;
const float VP_SF_IDENTITY_CL = 4;

// Console command: dump every bone of the first visible player_visual_proxy
// to the console (name + index). Use the result to pick the right value
// for sv_player_basebone — it should split between the last torso/arm
// bone and the first leg bone (typically the bone whose translation is
// driven by the breathing/idle animation should fall on the TORSO side
// of the split, while the root bone — if it has no animation translation
// — can stay on either side). Registered in cl_main.qc.
void() CSQC_DumpPlayerBones =
{
	entity vis = findchain(classname, "player_visual_proxy");
	if (!vis || !vis.modelindex)
	{
		print("[bones] no active player_visual_proxy with a model — try chase_active 1 or watch a remote player\n");
		return;
	}

	if (!vis.skeletonindex)
		vis.skeletonindex = skel_create(vis.modelindex);
	if (!vis.skeletonindex)
	{
		print("[bones] skel_create failed — model may not have a skeleton\n");
		return;
	}

	float n = skel_get_numbones(vis.skeletonindex);
	print(sprintf("[bones] proxy owner=%g model='%s' bones=%g\n",
		vis.vis_owner_entnum, vis.model, n));
	float i;
	for (i = 1; i <= n; i++)
	{
		float parent = skel_get_boneparent(vis.skeletonindex, i);
		print(sprintf("[bones]  %3d  parent=%-3d  %s\n",
			i, parent, skel_get_bonename(vis.skeletonindex, i)));
	}
	print(sprintf("[bones] current sv_player_basebone = %g\n",
		cvar("sv_player_basebone")));
};

void() CSQC_PlayerVisual_Update =
{
	self.vis_owner_entnum = readbyte();
	float section_bits    = readbyte();

	vector new_origin = self.origin;
	float  had_pose   = (section_bits & VP_SF_POSE_CL);

	if (section_bits & VP_SF_POSE_CL)
	{
		new_origin_x  = readcoord();
		new_origin_y  = readcoord();
		new_origin_z  = readcoord();
		self.angles_x = readfloat();
		self.angles_y = readfloat();
		self.angles_z = readfloat();
		self.vis_aim_yaw = self.angles_y;  // preserve original aim before predraw modifies it
		self.velocity_x = readcoord();
		self.velocity_y = readcoord();
		self.velocity_z = readcoord();
	}

	if (section_bits & VP_SF_ANIM_CL)
	{
		// Wire order: byte1 = .frame (legs), byte2 = .baseframe (torso)
		// Always READ from the wire (else later sections desync), but
		// only APPLY when the proxy isn't predicted-dead — otherwise
		// the server's late death-anim snapshot would re-trigger the
		// pose CSQC_TryPredictDeath already played out, causing a
		// visible "the body restarts the death animation" jitter.
		float new_anim_bottom  = readbyte();
		float new_anim_top     = readbyte();
		float new_pitch        = readfloat();
		float new_flags        = readfloat();
		float new_anim_top_gen = readbyte();

		if (!self.vis_pred_dead_latch)
		{
			self.vis_anim_bottom  = new_anim_bottom;
			self.vis_anim_top     = new_anim_top;
			self.vis_pitch        = new_pitch;
			self.flags            = new_flags;
			self.vis_anim_top_gen = new_anim_top_gen;
		}
	}

	float identity_changed = (section_bits & VP_SF_IDENTITY_CL);
	string mdl_path = self.model;   // default: keep current model when identity didn't change

	float prev_is_dead = self.vis_is_dead;
	if (identity_changed)
	{
		self.vis_weapon_id = readbyte();
		self.skin          = readbyte();
		self.colormap      = readbyte();
		float team_model_byte = readbyte();
		// Death byte — server sets when owner.is_dead. Drops proxy
		// solidity so the corpse stops shoving live players around.
		self.vis_is_dead = readbyte();
		// Authoritative copy that the predicted-death code never touches —
		// drives the bullet-trace solidity below (see vis_server_is_dead decl).
		self.vis_server_is_dead = self.vis_is_dead;

		// Client-side death-anim fallback.  With cl_predict_death 0
		// and the server's VP_SF_ANIM section dropped or arriving in
		// a later snapshot than VP_SF_IDENTITY, the proxy can flip to
		// dead state (vis_is_dead = 1) while vis_anim_bottom still
		// holds the alive locomotion frame — visible as "the body
		// stays alive after it dies".  Snap the anim slots to a
		// generic death pose on the dead transition; the server's
		// authoritative anim will overwrite when it arrives.  The
		// CSANIM_DEATH* / CSANIM_DIE_* range starts at CSANIM_DEATH1
		// (sh_player_anims.qc), so anything below is treated as a
		// non-death frame that needs the snap.
		if (!prev_is_dead && self.vis_is_dead
		    && (self.vis_anim_bottom < CSANIM_DEATH1
		     || self.vis_anim_bottom > CSANIM_DIE_FORWARD))
		{
			self.vis_anim_bottom      = CSANIM_DEATH1;
			self.vis_anim_top         = CSANIM_DEATH1;
			self.vis_anim_bottom_time = 0;
			self.vis_anim_top_time    = 0;
		}
		// Health byte (0..255) — used by CSQC_TryPredictDeath to
		// decide whether a predicted hit is lethal. Server clamps to
		// the byte range in Player_VisualProxy_Sync.
		self.vis_health  = readbyte();
		// Bodygroup bitfield — bit 0 = backpack-visible (C4 carried,
		// but not actively held). Stored on the proxy and translated
		// to a "geomset 2 N" line on setcustomskin.
		self.vis_bodygroup = readbyte();
		// Life generation mirrored from the server's player slot.
		// Hitclaims include this so a stale corpse/old-life proxy
		// cannot damage the newly respawned player in the same slot.
		self.vis_life_serial = readbyte();

		// Rollback clear: if the server snapshot says alive, our
		// predicted-death was wrong (target had armor / regen / FF /
		// bad hitclaim) — clear the latch so future anim updates
		// resume applying. Stays set while server confirms dead so
		// subsequent dead-state snapshots can't re-restart the anim.
		//
		// Time-gate: only believe an "alive" snapshot once enough time
		// has elapsed for our shot to have round-tripped (ping +
		// headroom). Within that window, an "alive" snapshot is just
		// the pre-kill state the server hadn't processed our hit at —
		// keep the latch and the predicted death pose. Without this
		// gate, body-shot prediction visibly snapped back to standing
		// for one frame before the kill confirmation came through.
		if (!self.vis_is_dead && self.vis_pred_dead_latch)
		{
			float ping_s = getplayerkeyfloat(player_localnum, INFOKEY_P_PING, 0) * 0.001;
			float confirm_window = bound(0.05, ping_s + 0.10, 2.5);
			if (self.vis_pred_dead_at_time == 0
			    || time - self.vis_pred_dead_at_time > confirm_window)
			{
				self.vis_pred_dead_latch   = 0;
				self.vis_pred_dead_at_time = 0;
				self.vis_pred_gibs_at_time = 0;
			}
		}

		if (team_model_byte == 255)
		{
			mdl_path = "models/player/sini.mdl";
			// "Sini" override doesn't carry team info — leave vis_team
			// at whatever it was (server should still also send this in
			// the next non-override IDENTITY tick if team changed).
		}
		else if (team_model_byte == 254)
		{
			mdl_path = "models/player/chickenman/chickenman.iqm";
			// Same team-independent sentinel pattern as sini.
		}
		else if (team_model_byte == 253)
		{
			mdl_path = "models/player/numberk/numberK.iqm";
			// Same team-independent sentinel pattern as sini / chickenman.
		}
		else if (team_model_byte == 252)
		{
			mdl_path = "models/player/kilmer/kilmer.iqm";
			// Same team-independent sentinel pattern as sini / chickenman / numberK.
		}
		else
		{
			float new_team   = floor(team_model_byte / 4) + 1;
			float vis_model  = team_model_byte % 4;
			self.vis_team    = new_team;   // expose for CSQC_TryPredictDeath FF gate
			if (new_team == TEAM_BLUE)
				mdl_path = team_blue_models[vis_model];
			else
				mdl_path = team_red_models[vis_model];
		}
	}

	if (self.classname != "player_visual_proxy")
	{
		self.classname = "player_visual_proxy";
		self.drawmask = MASK_ENGINE;
		self.predraw = CSQC_PlayerVisual_Predraw;
	}

	// Feed the interp ring buffer when a real pose arrived. Pass
	// new_origin directly — self.origin isn't committed via setorigin
	// until line ~2311 below, so reading it here would capture stale
	// data (the previous snapshot's origin).
	if (section_bits & VP_SF_POSE_CL)
		CSQC_RecordProxySnapshot(self, new_origin);

	// Model change can only happen when IDENTITY section arrived — skip
	// setmodel/setcustomskin/setsize entirely otherwise (frequent case
	// for idle pose-only updates).
	float model_changed = identity_changed && (self.model != mdl_path);
	if (model_changed)
	{
		string prev_model = self.model;
		float  prev_mi    = self.modelindex;
		if (self.skeletonindex)
		{
			skel_delete(self.skeletonindex);
			self.skeletonindex = 0;
			self.vis_skel_modelindex = 0;
		}
		// Explicitly detach any prior model binding before the re-bind.  If
		// this CSQC entity slot was previously a func_breakable / func_wall,
		// its BSP-submodel binding otherwise survives the setmodel-over and
		// renders as a ghost brush at our new (player) origin.
		setmodel(self, "");
		setmodel(self, mdl_path);
		if (cvar("sv_debug_ent_types"))
		{
			print(sprintf("  [vis %g] want='%s' prev_model='%s' prev_mi=%g → model='%s' mi=%g\n",
			              self.entnum, mdl_path, prev_model, prev_mi,
			              self.model, self.modelindex));
		}
		// Force re-apply on next bodygroup pass — setmodel resets the
		// custom-skin state, so the cached "last applied" must be cleared
		// or the bodygroup branch below would skip the re-apply when the
		// new bodygroup byte happens to match the pre-model-swap value.
		self.vis_last_applied_bodygroup = -1;
	}

	// Bodygroup re-apply: pushes both the static "geomset 0 2" body-variant
	// select AND the dynamic "geomset 2 N" backpack toggle (1 = blank,
	// 2 = bomb) every time either the model OR the bodygroup byte changes.
	//
	// Bodypart 2 = backpack on the standard CT/T player models — these
	// have three bodyparts in HL .mdl order: $body studio "head&legs" (0),
	// $body studio "body" (1), $bodygroup backpack (2).  Submodels inside
	// the backpack bodygroup are 1-indexed: 1 = blank, 2 = bomb.
	//
	// Skipped when bodygroup is identical to last applied AND model didn't
	// change — setcustomskin parses the string each call, no point churning.
	if (model_changed || (identity_changed && self.vis_bodygroup != self.vis_last_applied_bodygroup))
	{
		float backpack_submodel = (self.vis_bodygroup & 1) ? 2 : 1;
		setcustomskin(self, "", sprintf("geomset 0 2\ngeomset 2 %g\n", backpack_submodel));
		self.vis_last_applied_bodygroup = self.vis_bodygroup;
	}

	// Bbox sync — every snapshot, not just on model change.
	//
	// The proxy is the sole client-side pmove collider for remote
	// players in this CSQC mode (no engine-slot collider exists; the
	// removed CSQC_SetupRemotePlayerSolids tried to populate one but
	// the edict_num(n) it queried didn't actually map to engine player
	// slots).  Sizing matches PM_MINS / PM_MAXS — origin-at-body-
	// center hulls (Z range -36..+36) — so pmove traces against the
	// proxy match the server's authoritative hull and PM_Disentangle-
	// FromPlayer resolves against the right shape.
	//
	// PM_ReadMovevars() populates PM_MINS / PM_MAXS / PM_DUCK_*.
	// They're also filled on every PM_PlayerMove tick, but a fresh
	// proxy snapshot can land before pmove runs on a new connect, so
	// we call defensively here.
	PM_ReadMovevars();

	// Duck state: read directly from the proxy's own .flags, which the
	// VP_SF_ANIM_CL section just deserialised at line ~2526 from the
	// player_visual_proxy SendEntity payload (server writes self.flags
	// at sv_player.qc:978).  Earlier version looked up
	// edict_num(self.vis_owner_entnum).flags — wrong: in this CSQC
	// edict_num(N) for N=1..maxclients does NOT return engine player
	// slots, it returns whatever entity happens to live at edict N
	// (predicted_player, preview models, etc.).  The first remote-
	// player proxy was reading predicted_player.flags — i.e. the LOCAL
	// player's duck state — so the wrong proxy resized.
	//
	// For the LOCAL player in chase_active, origin comes from
	// csqc_present_origin (predicted + render-rate preview, line ~3035),
	// which has already applied the 18qu duck-completion drop.  The
	// preview saves/restores predicted_player.flags around its sim, so
	// predicted_player.flags reflects the PRE-preview state while the
	// origin reflects the POST-preview state.  csqc_present_ducking is
	// captured INSIDE the preview at the same moment as the origin —
	// use it here so the bbox sizing stays consistent.  Reading
	// predicted_player.flags or self.flags here can leave the bbox
	// standing-tall against a ducked-low origin (feet sink 18qu).
	float prox_ducking;
	if (self.vis_owner_entnum == player_localentnum
	    && !self.vis_is_dead
	    && predicted_player
	    && csqc_prediction_valid
	    && csqc_present_valid)
		prox_ducking = csqc_present_ducking;
	else
		prox_ducking = (self.flags & FL_DUCKING) != 0;

	if (prox_ducking)
		setsize(self, PM_DUCK_MINS, PM_DUCK_MAXS);
	else
		setsize(self, PM_MINS, PM_MAXS);
	if (had_pose)
	{
		// Stash the "error" between where we extrapolated the proxy to
		// last frame and where the server says it actually is. The
		// extrap function bleeds this offset out over
		// cl_extrap_smooth_time so the snap-back isn't visible as a
		// single-frame pop.
		if (self.vis_owner_entnum > 0 && self.vis_owner_entnum != player_localentnum)
		{
			float smooth_enabled = 1;
			if (cvar_string("cl_extrap_smooth") != "" && !cvar("cl_extrap_smooth"))
				smooth_enabled = 0;

			if (smooth_enabled)
			{
				// Hard-coded 32 units = teleport threshold (one player
				// bbox width). Smaller deltas are prediction error and
				// get smoothed; larger = teleport/respawn, snap instantly.
				// Previously cl_extrap_smooth_maxjump cvar; no user ever
				// benefits from tuning this.
				const float SMOOTH_MAXJUMP = 32;

				vector err = self.origin - new_origin;
				float elen = vlen(err);
				// Ignore tiny sub-pixel noise (floor rounding, 0.5-unit
				// snaps) and ignore huge jumps (teleport, respawn) — the
				// first would spam pointless smoothing, the second would
				// render the player visibly lagging behind a teleport.
				if (elen > 0.5 && elen <= SMOOTH_MAXJUMP)
				{
					self.extrap_error_offset = err;
					self.extrap_error_cltime  = cltime;
				}
				else
				{
					self.extrap_error_offset  = '0 0 0';
					self.extrap_error_cltime  = 0;
				}
			}
		}

		setorigin(self, new_origin);
	}

	// Solidity policy — set LAST so setmodel/setsize re-link calls can't
	// silently default solid back to SOLID_BBOX.
	//   • OWN proxy → SOLID_NOT (otherwise predicted_player's pmove
	//     traceboxes hit it on every frame — instant stutter, since
	//     pmove ignores `self` only, not arbitrary other entities).
	//   • DEAD other player → SOLID_NOT (corpse must not block the living).
	//   • Live other players → SOLID_BBOX so the local CSQC bullet trace
	//     (with MOVE_HITMODEL) can broad-phase against the bbox and
	//     refine to model hitboxes.
	// Gate on vis_SERVER_is_dead (authoritative), NOT vis_is_dead — the latter is
	// flipped by client predicted-death and, since the server won't re-send
	// IDENTITY while is_dead is unchanged, a wrong/early predict would otherwise
	// leave the live enemy SOLID_NOT forever and un-hittable in trust mode.
	if (self.vis_owner_entnum == player_localentnum || self.vis_server_is_dead)
		self.solid = SOLID_NOT;
	else
		self.solid = SOLID_BBOX;
};

// ---------------------------------------------------------------------------
//  CSQC_Ent_Spawn / CSQC_Ent_Update  -  explicit owner-only proxy snapshots
// ---------------------------------------------------------------------------

noref void(float netentnum) CSQC_Ent_Spawn =
{
	self = spawn();
	self.entnum = netentnum;
};

// ---------------------------------------------------------------------------
//  CSQC_Ent_Update  –  dispatches on entity type byte
//  (trigger handlers live in cl_push.qc and cl_teleport.qc)
// ---------------------------------------------------------------------------

// Diagnostic — when sv_debug_ent_types is nonzero, report every time a CSQC
// entity slot receives a different type byte than the previous update.  That
// exposes server-side entnum recycling between e.g. func_breakable (type 5)
// and player_visual_proxy (type 8), which would leak model/origin state.
.float dbg_last_ent_type;

void(float old_type, float new_type) CSQC_Ent_CleanupTypeChange =
{
	// FTE can recycle a CSQC entity slot for a different SendEntity type
	// without first calling CSQC_Ent_Remove on the old type. Clear the
	// pieces that are dangerous if they leak across types: explicit IQM
	// skeletons, player weapon attachments, linked-list membership, and
	// stale model bindings. This is especially visible when a moving ODE
	// dropped weapon inherits a player_visual_proxy skeleton for one
	// frame: unrelated player models can briefly render stretched.
	if (self.vis_weapon_ent)
	{
		entity wep = self.vis_weapon_ent;
		if (wep.skeletonindex)
		{
			skel_delete(wep.skeletonindex);
			wep.skeletonindex = 0;
		}
		setattachment(wep, world, "");
		remove(wep);
		self.vis_weapon_ent = world;
		self.vis_weapon_model = "";
	}

	if (self.skeletonindex)
	{
		skel_delete(self.skeletonindex);
		self.skeletonindex = 0;
		self.vis_skel_modelindex = 0;
	}

	dropped_weapon_list_remove_csqc(self);
	push_list_remove_csqc(self);
	tele_list_remove_csqc(self);
	ladder_list_remove_csqc(self);
	Conveyor_RemoveFromList(self);
	RotatingBrush_RemoveFromList(self);
	MovingBrush_RemoveFromList(self);

	setattachment(self, world, "");
	setmodel(self, "");
	self.predraw = __NULL__;
	self.think = __NULL__;
	self.nextthink = 0;
	self.movetype = MOVETYPE_NONE;
	self.solid = SOLID_NOT;
	self.drawmask = 0;

	self.vis_is_dead = 0;
	self.vis_server_is_dead = 0;
	self.vis_pred_dead_latch = 0;
	self.vis_pred_dead_at_time = 0;
	self.vis_pred_gibs_at_time = 0;
	self.vis_last_applied_bodygroup = -1;
	self.dropped_weapon_next = world;
	self.csqc_fake_drop_next = world;
	self.extrap_error_offset = '0 0 0';
	self.extrap_error_cltime = 0;
};

noref void(float isnew) CSQC_Ent_Update =
{
	float ent_type;

	ent_type = readbyte();

	// One-log-per-transition for every CSQC entity.  Tracks server-entnum →
	// CSQC-ent-type changes to diagnose "brush attached to player" slot-reuse
	// bugs.  Prints on first receive AND on any type change, gated behind
	// sv_debug_ent_types since the map-join spam isn't useful in normal play.
	float type_changed = (!isnew && self.dbg_last_ent_type && self.dbg_last_ent_type != ent_type);
	if ((isnew || type_changed) && cvar("sv_debug_ent_types"))
	{
		print(sprintf("[ent %g] type %g%s%s origin=%v model='%s'\n",
		              self.entnum, ent_type,
		              isnew ? " (new)" : "",
		              type_changed
		                ? sprintf(" (was %g!)", self.dbg_last_ent_type) : "",
		              self.origin, self.model));
	}
	if (type_changed)
		CSQC_Ent_CleanupTypeChange(self.dbg_last_ent_type, ent_type);
	self.dbg_last_ent_type = ent_type;

	if (ent_type == CSQC_ENT_PUSH_TRIGGER)
	{
		CSQC_PushTrigger_Update();
		CSQC_NetStat_RecordTrigger(NET_SZ_PUSH_TRIG);
		return;
	}

	if (ent_type == CSQC_ENT_TELEPORT_TRIGGER)
	{
		CSQC_TeleportTrigger_Update();
		CSQC_NetStat_RecordTrigger(NET_SZ_TELE_TRIG);
		return;
	}

	if (ent_type == CSQC_ENT_LADDER_TRIGGER)
	{
		CSQC_LadderTrigger_Update();
		CSQC_NetStat_RecordTrigger(NET_SZ_LADDER_TRIG);
		return;
	}

	if (ent_type == CSQC_ENT_CAMERA)
	{
		CSQC_Camera_Update();
		return;
	}

	if (ent_type == CSQC_ENT_SOLID_BRUSH)
	{
		CSQC_SolidBrush_Update();
		CSQC_NetStat_RecordBrush();
		return;
	}

	if (ent_type == CSQC_ENT_PLAYER_VISUAL)
	{
		CSQC_PlayerVisual_Update();
		CSQC_NetStat_RecordVisual(self.vis_owner_entnum);
		return;
	}

	if (ent_type == CSQC_ENT_DROPPED_WEAPON)
	{
		CSQC_DroppedWeapon_Update(isnew);
		return;
	}

	if (ent_type == CSQC_ENT_PROJECTILE)
	{
		CSQC_Projectile_Update(isnew);
		return;
	}

	if (ent_type == CSQC_ENT_C4)
	{
		CSQC_C4_Update(isnew);
		return;
	}

	if (ent_type == CSQC_ENT_ENV_BEAM)
	{
		CSQC_EnvBeam_Update();
		return;
	}

	if (ent_type == CSQC_ENT_FUNC_RAIN)
	{
		CSQC_FuncRain_Update(isnew);
		return;
	}

	if (ent_type == CSQC_ENT_ENV_SOUND)
	{
		CSQC_EnvSound_Update(isnew);
		return;
	}

	if (ent_type == CSQC_ENT_PHYS_PROP)
	{
		CSQC_PhysProp_Update(isnew);
		return;
	}

	// --- prediction proxy ---

	if (ent_type != PM_CSQC_PROXY_VERSION)
		print(sprintf("CSQC_Ent_Update: unknown type %g\n", ent_type));

	localplayer = CSQC_GetEngineLocalPlayer();
	csqc_authority_proxy = self;
	csqc_proxy_seen = TRUE;
	csqc_proxy_entnum = self.entnum;

	if (isnew)
	{
		self.pm_movetype = PM_MOVETYPE_NORMAL;
		self.view_ofs    = PM_VIEW_OFS;
		self.pm_timecarry = 0;
	}

	float changedflags = readbyte();
	CSQC_NetStat_RecordProxy(changedflags);

	if (changedflags & PM_SF_MOVEMENT)
	{
		// Full 32-bit float for origin / velocity (paired with the
		// matching WriteFloat in PM_PredictionProxy_SendEntity).  Avoids
		// 1/8 qu coord quantization that was the dominant source of
		// reconcile-vs-live drift — pmove on both sides is deterministic,
		// but coord rounding on snapshot turned that determinism into
		// per-reconcile noise.  view_ofs stays at coord precision (rarely
		// changes; 1/8 qu noise is well below visible).
		vector pred_origin;
		pred_origin_x = readfloat();
		pred_origin_y = readfloat();
		pred_origin_z = readfloat();
		setorigin(self, pred_origin);
		self.velocity_x    = readfloat();
		self.velocity_y    = readfloat();
		self.velocity_z    = readfloat();
		self.view_ofs      = readvector();
		self.flags         = readfloat();
		// Matches server's re-encoding in PM_PredictionProxy_SendEntity:
		// small integer / bitfield fields are byte or short, not float.
		self.pm_movetype   = readbyte();
		self.pm_jump_held  = readbyte();
		self.pm_jump_msec  = readshort();
		self.pm_waterjumptime = readfloat();
		self.pm_in_duck    = readbyte();
		self.pm_duck_msec  = readshort();
		self.pm_oldbuttons    = readbyte();
		self.pm_timecarry     = readfloat();
		self.pm_teleport_time        = readfloat();
		self.pm_ladder_detach_time   = readfloat();
		self.pm_fuser2               = readfloat();
		self.spread_penalty          = readfloat();
		self.fire_spread_penalty     = readfloat();
		self.pm_step_time            = readfloat();
		// Duck-land slide friction flag.  Mirrors the SSQC write at the
		// tail of the PM_SF_MOVEMENT section so CSQC's predicted pmove
		// applies the friction reduction on the same ticks.
		self.slide_friction_active   = readbyte();
		// sv_jumplag — server sent remaining seconds; reconstruct the
		// absolute end-timestamp against the client's local `time` so
		// PM_CheckJump's `time < pm_jump_lag_end` gate releases in
		// lockstep with the server.
		self.pm_jump_lag_end         = time + readfloat();
		// Ground-snap suppress window — remaining-secs, SAME wire position as
		// the SSQC writer (right after pm_jump_lag_end, before grapple) so the
		// movement-section decode stays byte-aligned.
		self.pm_jump_groundstick_off_until = time + readfloat();
		// Grappling-hook rope render: 1 byte + 3 coords matching the
		// SSQC writer.  Reads onto the proxy entity → flows through
		// CSQC_StoreConfirmedStateFromEntity into predicted_player so
		// cl_rope.qc can draw it.
		self.grapple_rope_active     = readbyte();
		vector grap_anchor;
		grap_anchor_x = readcoord();
		grap_anchor_y = readcoord();
		grap_anchor_z = readcoord();
		self.grapple_anchor          = grap_anchor;
		// Actively-pulling flag (gates ground-snap suppress in pmove).
		self.grapple_attached        = readbyte();
		// PM_BTN_GRAPPLE edge-latch baseline (see sv_player.qc writer).
		self.pm_grapple_held_last    = readbyte();
		// sv_codstamina state: float pool + byte punish-latch + float
		// remaining-seconds for pm_fire_suppress_until.  Reconstruct
		// the absolute-time stamp against the client's local `time`
		// (mirrors the pm_jump_lag_end wire format above).
		self.codstamina              = readfloat();
		self.codstamina_punished     = readbyte();
		self.pm_fire_suppress_until  = time + readfloat();
		// HL2 carry lowered-weapon flag — matches the SSQC writer tail
		// (sv_player.qc).  Drives Weapon_LowerBlocksFire + the lower envelope.
		self.pm_carrying             = readbyte();
		// func_vehicle driving flag — matches the SSQC writer tail.
		self.pm_driving              = readbyte();
	}

	if (changedflags & PM_SF_WEAPON_STATE)
	{
		self.slot_primary      = readbyte();
		self.slot_secondary    = readbyte();
		self.slot_melee        = readbyte();
		self.slot_utility      = readbyte();
		self.weapon          = readbyte();
		self.previous_weapon = readbyte();
		self.weaponstate     = readbyte();
		// Respawn / team-change detection: server resets wep_action_id to
		// 0 when a player respawns, so a strictly-monotonic counter going
		// BACKWARDS is the unambiguous signal. CSQC_ResetPredictionState
		// only fires on map change / disconnect, NOT on respawn — the
		// predicted_player ent persists across respawns and CSQC_Ensure-
		// PredictedPlayer's csgren reset block never re-runs. Without
		// this hook the stale csgren_fake_spawned_serial from a pre-death
		// throw collides with the post-respawn action_id (both end up at
		// 2 after pin-pull + throw), which silently no-ops the fake-
		// grenade spawn — throw animation plays, ammo decrements, but
		// no smoke cloud appears for the shooter.
		float _prev_action_id = self.wep_action_id;
		self.wep_action_id   = readlong();   // 32-bit — matches server's WriteLong in PM_PredictionProxy_SendEntity
		if (self.wep_action_id < _prev_action_id)
		{
			self.csgren_throw_pending       = 0;
			self.csgren_fake_spawned_serial = 0;
			self.csgren_spawn_time          = 0;
			self.csgren_throw_type          = 0;
			self.paintball_fake_spawned_serial = 0;
			// Respawn / team-change / live sv_mintic re-seed —
			// detected by the server's action_id going backward.
			// Under the trust=1 fire-state-decouple (Phase 1+2), the
			// auth-proxy's wep_action_id is no longer reconciled into
			// predicted_player, so when the server resets to 0 the
			// predicted_player can be left with a stale-high value
			// (e.g. 50 from the previous life).  That stale value
			// permanently closes the ammo-sync gate
			// `sv_confirmed_wep_action_id >= self.wep_action_id`
			// (the new ammo-decouple gate in CSQC_ResetToConfirmedState),
			// so the post-respawn loadout's mag/ammo never reaches the
			// client and the player spawns with empty guns.  The
			// equivalent problem hits weaponstate / attack_finished /
			// wep_anim_start: they get stuck in pre-death values and
			// the draw animation never plays for the freshly equipped
			// weapon (sound plays from the server multicast, no anim
			// because predicted_player.weaponstate != WS_DRAW).
			//
			// Fix: when the rewind is detected, also zero the predicted-
			// player's fire-state fields so they're a clean slate ready
			// for the snapshot to seed.  The actual seeding (weapon ID,
			// equipped slot, ammo) flows through CSQC_ResetToConfirmedState
			// on the next reconcile pass; this branch just makes sure
			// the gates are open.
			if (predicted_player)
			{
				predicted_player.csqc_fire_effect_action_id = 0;
				predicted_player.wep_action_id   = 0;
				predicted_player.attack_finished = 0;
				predicted_player.wep_anim_start  = 0;
				predicted_player.weaponstate     = WS_IDLE;
				predicted_player.csqc_fire_guard   = 0;
				predicted_player.csqc_reload_guard = 0;
			}
			CSQC_ResetCSGrenadeState();
		}
		self.attack_finished = cltime + readfloat();   // server sends remaining time
		{
			float _elapsed = readfloat();   // server sends time since animation began
			if (_elapsed > 0)
				self.wep_anim_start = cltime - _elapsed;
			else if (self.weaponstate != WS_IDLE)
				self.wep_anim_start = cltime;   // animation just started this server frame
			else
				self.wep_anim_start = 0;
		}
		self.zoomstage       = readbyte();
		self.snowball_has_slingshot = readbyte();
		self.snowball_use_slingshot = readbyte();
		// Speed-factor blend state — paired with WriteFloat in
		// PM_PredictionProxy_SendEntity.  Preserves in-flight transition
		// across reconcile so client replay and server pmove stay
		// synchronized through ping-window weapon switches.
		self.pm_weapon_blend_progress = readfloat();
		self.pm_weapon_prev_factor    = readfloat();
		// sv_gunkick state — proxy v19. Mirrors PM_PredictionProxy_
		// SendEntity in sv_player.qc. Authoritative server values
		// overwrite the locally-integrated kick state on every
		// snapshot; pmove keeps integrating between snapshots so
		// the camera stays smooth at the per-tick rate.
		self.view_kick_pitch     = readfloat();
		self.view_kick_yaw       = readfloat();
		self.view_kick_pitch_vel = readfloat();
		self.view_kick_yaw_vel   = readfloat();
		self.view_kick_burst_idx = readbyte();
	}

	if (changedflags & PM_SF_AMMO)
	{
		// Compact slot-ammo bitmask + utility counts. Matches the server
		// write order in PM_PredictionProxy_SendEntity exactly.
		// Fields whose bit is clear keep their cached value (server
		// skipped writing them because they didn't change this send).
		float m0 = readbyte();
		float m1 = readbyte();

		if (m0 &   1) self.slot_primary_mag    = readbyte();
		if (m0 &   2) self.slot_primary_ammo   = readbyte();
		if (m0 &   4) self.slot_primary_aux    = readbyte();
		if (m0 &   8) self.slot_secondary_mag  = readbyte();
		if (m0 &  16) self.slot_secondary_ammo = readbyte();
		if (m0 &  32) self.slot_secondary_aux  = readbyte();
		if (m0 &  64) self.ammo_hlgrenade      = readbyte();
		if (m0 & 128) self.ammo_snowball       = readbyte();

		if (m1 &   1) self.ammo_cshegrenade    = readbyte();
		if (m1 &   2) self.ammo_csflashbang    = readbyte();
		if (m1 &   4) self.ammo_cssmokegrenade = readbyte();
		if (m1 &   8) self.ammo_cfc4           = readbyte();

		W_SlotAmmo_LoadCurrent(self);
	}

	CSQC_StoreConfirmedStateFromEntity(self);
	sv_confirmed_cmdframe        = servercommandframe;
	csqc_dbg_last_snapshot_time  = cltime;
	csqc_baseline_valid          = TRUE;
	csqc_prediction_valid        = TRUE;
	csqc_dbg_seed_source         = 2;
	CSQC_ReconcilePrediction();
};
