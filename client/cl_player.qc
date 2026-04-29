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
float  sv_confirmed_cmdframe;    // last acknowledged command for baseline

// Weapon prediction state (extended proxy)
float  sv_confirmed_slot_primary;
float  sv_confirmed_slot_secondary;
float  sv_confirmed_slot_melee;
float  sv_confirmed_slot_utility;
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
float  sv_confirmed_mag_hlglock;
float  sv_confirmed_ammo_hlglock;
float  sv_confirmed_ammo_hlegon;
float  sv_confirmed_mag_csusp;
float  sv_confirmed_ammo_csusp;
float  sv_confirmed_csusp_silenced;

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

vector csqc_present_origin;
vector csqc_present_view_ofs;
float  csqc_present_valid;
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

	sv_confirmed_slot_primary      = src.slot_primary;
	sv_confirmed_slot_secondary    = src.slot_secondary;
	sv_confirmed_slot_melee        = src.slot_melee;
	sv_confirmed_slot_utility      = src.slot_utility;
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
	sv_confirmed_mag_hlglock      = src.mag_hlglock;
	sv_confirmed_ammo_hlglock     = src.ammo_hlglock;
	sv_confirmed_ammo_hlegon      = src.ammo_hlegon;
	sv_confirmed_mag_csusp        = src.mag_csusp;
	sv_confirmed_ammo_csusp       = src.ammo_csusp;
	sv_confirmed_csusp_silenced   = src.csusp_silenced;
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

	// Sync hull size to match the confirmed duck state.
	// Without this, the predicted player replays commands with the wrong
	// hull size, causing permanent prediction divergence when ducked.
	PM_SyncHull();
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
	float old_mag_csusp;
	float old_ammo_csusp;

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
	old_mag_csusp = self.mag_csusp;
	old_ammo_csusp = self.ammo_csusp;

	CSQC_ResetToConfirmedMoveState();

	self.slot_primary     = sv_confirmed_slot_primary;
	self.slot_secondary   = sv_confirmed_slot_secondary;
	self.slot_melee       = sv_confirmed_slot_melee;
	self.slot_utility     = sv_confirmed_slot_utility;
	self.weapon          = sv_confirmed_weapon;
	self.previous_weapon = sv_confirmed_previous_weapon;
	self.weaponstate     = sv_confirmed_weaponstate;
	self.wep_action_id   = sv_confirmed_wep_action_id;
	self.attack_finished = sv_confirmed_attack_finished;
	self.wep_anim_start  = sv_confirmed_wep_anim_start;
	CSQC_WeaponEquip(self.weapon);
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
	self.zoomstage       = sv_confirmed_zoomstage;
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
	self.mag_hlglock     = sv_confirmed_mag_hlglock;
	self.ammo_hlglock    = sv_confirmed_ammo_hlglock;
	self.ammo_hlegon     = sv_confirmed_ammo_hlegon;
	self.mag_csusp       = sv_confirmed_mag_csusp;
	self.ammo_csusp      = sv_confirmed_ammo_csusp;
	// csusp_silenced is NOT reset from server — client prediction is authoritative
	// for this toggle, same convention as m4a1_silenced.

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
		else if (self.weapon == WEP_AK47)
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
		else if (self.weapon == WEP_CSUSP)
		{
			self.mag_csusp = max(self.mag_csusp, old_mag_csusp);
			self.ammo_csusp = min(self.ammo_csusp, old_ammo_csusp);
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
};

void() CSQC_ResetPresentationView =
{
	csqc_present_valid = FALSE;
	csqc_present_origin = '0 0 0';
	csqc_present_view_ofs = '0 0 0';
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
	predicted_player.previous_weapon  = WEP_NONE;
	predicted_player.weapon          = WEP_NONE;
	predicted_player.weaponstate     = WS_IDLE;
	predicted_player.wep_action_id   = 0;
	predicted_player.wep_anim_start  = 0;
	predicted_player.attack_finished = 0;
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
	predicted_player.mag_csusp       = 0;
	predicted_player.ammo_csusp      = 0;
	predicted_player.csusp_silenced  = sv_confirmed_csusp_silenced;
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

		if (!walking_on_ground && elen <= LOCAL_SMOOTH_MAXJUMP
		    && cvar("cl_driftlock"))
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
	float saved_impulse;
	vector saved_origin;
	vector saved_velocity;
	vector saved_view_ofs;
	vector saved_angles;
	vector saved_movevalues;

	CSQC_ResetPresentationView();

	if (!predicted_player || !csqc_prediction_valid)
		return;

	csqc_present_valid = TRUE;
	csqc_present_origin = CSQC_ApplyLocalSmoothOffset(predicted_player.origin);
	csqc_present_view_ofs = predicted_player.view_ofs;

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

	float fixedstep = PM_ReadMovevar("sv_mintic", 0.01);
	if (fixedstep < 0.001) fixedstep = 0.01;

	pm_suppress_sounds = TRUE;   // preview steps are speculative — no sounds
	while (preview_time > PM_FIXEDSTEP_EPSILON)
	{
		input_timelength = min(preview_time, fixedstep);
		PM_PlayerMoveStep();
		preview_time -= input_timelength;
	}
	pm_suppress_sounds = FALSE;

	csqc_present_origin = CSQC_ApplyLocalSmoothOffset(self.origin);
	csqc_present_view_ofs = self.view_ofs;
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

	// Freeze time: block WASD movement and primary attack
	if (getstatf(STAT_ROUND_PHASE) == ROUND_PHASE_FREEZE)
	{
		input_movevalues_x = 0;
		input_movevalues_y = 0;
		input_buttons = input_buttons & ~1;
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

	CSQC_BufferInputCommand(clientcommandframe);
	CSQC_PredictCurrentCommand();
};


// ---------------------------------------------------------------------------
//  CSQC player visual proxy — predraw + receiver
//
//  CSQC entity with predraw for full animation control. Uses ONLY
//  engine built-in fields from cl_defs.qc — NO redeclarations.
//  bonecontrol1-4 and subblendfrac only work on CSQC entities.
// ---------------------------------------------------------------------------

const string PLAYER_VISUAL_MODEL = "models/player/leet/leet.mdl";

// Custom fields only (no engine equivalents to shadow).
// vis_owner_entnum is forward-declared in client/cl_customdefs.qc so
// CSQC_SendHitclaim (in sh_weapon_logic.qc, compiled earlier) can read it.
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
// extrap_error_* fields live in client/cl_customdefs.qc so
// CSQC_SmoothSetOrigin (defined earlier in this file) can see them.

// Weapon attachment entity + state
.entity vis_weapon_ent;
.string vis_weapon_model;

float spec_target;
float spec_mode;
const float SPEC_MODE_FIRSTPERSON_FWD = 0;  // must match cl_spectate.qc

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

float() CSQC_PlayerVisual_Predraw =
{
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
		return PREDRAW_NEXT;

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
		self.vis_anim_bottom_time = 0;
		self.vis_last_anim_bottom = self.vis_anim_bottom;
	}
	if (self.vis_anim_top != self.vis_last_anim_top
	    || self.vis_anim_top_gen != self.vis_last_anim_top_gen)
	{
		self.vis_anim_top_time = 0;
		self.vis_last_anim_top = self.vis_anim_top;
		self.vis_last_anim_top_gen = self.vis_anim_top_gen;
	}
	self.vis_anim_top_time += dt;

	// --- Strafe body twist + backpedal detection ---
	// Compute BEFORE animation timer so we know if we're backpedaling.
	self.angles_y = self.vis_aim_yaw;  // reset to original aim each frame

	vector vel2d = self.velocity; vel2d_z = 0;
	float speed2d = vlen(vel2d);
	float leg_twist = 0;
	float backpedaling = FALSE;
	if (speed2d > 10)
	{
		float vel_yaw = vectoyaw(vel2d);
		float yaw_diff = vel_yaw - self.vis_aim_yaw;
		// Normalize to -180..180
		yaw_diff -= floor((yaw_diff + 180) / 360) * 360;

		// Beyond ±89° = backpedaling. Mirror the angle so legs face
		// the opposite direction (e.g. moving back-right → legs face forward-left).
		if (fabs(yaw_diff) > 95)
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
	self.frame          = self.vis_anim_bottom;       // legs
	self.frame1time     = self.vis_anim_bottom_time;
	self.baseframe      = self.vis_anim_top;          // torso
	self.baseframe1time = self.vis_anim_top_time;

	float bb = cvar("sv_player_basebone");
	if (bb <= 0) bb = gettagindex(self, "Bip01 L Thigh");
	self.basebone = bb;

	// Torso aim blending via subblend fracs (.frame side).
	// subblend2frac = Y axis (pitch / up-down aiming)
	float sb = self.vis_pitch / 90;
	self.subblend2frac = sb;

	// Progressive spine twist via bonecontrol
	makevectors([0, self.angles_y, 0]);
	float fCorrect = dotproduct(self.velocity, v_right) * 0.25;
	self.bonecontrol1 = fCorrect;
	self.bonecontrol2 = fCorrect * 0.5;
	self.bonecontrol3 = fCorrect * 0.25;
	self.bonecontrol4 = fCorrect * 0.125;

	// (Tried locking bone 1's translation here via skel_build +
	// skel_set_bone — froze the whole model because skel_build replaces
	// the engine's frame+baseframe blend with a single-track build,
	// losing the basebone split. The proper fix lives outside the
	// runtime — strip the root translation from the breathing animation
	// in the .smd source, or accept the feet drift. See repo notes.)

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

				// Mirror player bones → weapon bones (valve pattern)
				float i, pbone, wbone;
				vector bpos;
				for (i = 0; i < g_pbones.length; i++)
				{
					pbone = gettagindex(self, g_pbones[i]);
					wbone = gettagindex(wep, g_pbones[i]);
					if (wbone > 0 && pbone > 0)
					{
						bpos = gettaginfo(self, pbone);
						skel_set_bone_world(wep, wbone, bpos, v_forward, v_right, v_up);
					}
				}

				// Bones are set in world space via skel_set_bone_world,
				// so the entity origin must be 0 — otherwise the origin
				// gets added on top and the weapon double-offsets + lags.
				setorigin(wep, '0 0 0');
				wep.angles = '0 0 0';
				addentity(wep);
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

	if (identity_changed)
	{
		self.vis_weapon_id = readbyte();
		self.skin          = readbyte();
		self.colormap      = readbyte();
		float team_model_byte = readbyte();
		// Death byte — server sets when owner.is_dead. Drops proxy
		// solidity so the corpse stops shoving live players around.
		self.vis_is_dead = readbyte();
		// Health byte (0..255) — used by CSQC_TryPredictDeath to
		// decide whether a predicted hit is lethal. Server clamps to
		// the byte range in Player_VisualProxy_Sync.
		self.vis_health  = readbyte();

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
			mdl_path = "models/player/sini.mdl";
		else
		{
			float vis_team  = floor(team_model_byte / 4) + 1;
			float vis_model = team_model_byte % 4;
			if (vis_team == TEAM_BLUE)
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
		setcustomskin(self, "", "geomset 0 2\n");
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
	float prox_ducking = (self.flags & FL_DUCKING) != 0;

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
	if (self.vis_owner_entnum == player_localentnum || self.vis_is_dead)
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
noref void(float isnew) CSQC_Ent_Update =
{
	float ent_type;

	ent_type = readbyte();

	// One-log-per-transition for every CSQC entity.  Tracks server-entnum →
	// CSQC-ent-type changes to diagnose "brush attached to player" slot-reuse
	// bugs.  Prints on first receive AND on any type change, gated behind
	// sv_debug_ent_types since the map-join spam isn't useful in normal play.
	if ((isnew || self.dbg_last_ent_type != ent_type) && cvar("sv_debug_ent_types"))
	{
		print(sprintf("[ent %g] type %g%s%s origin=%v model='%s'\n",
		              self.entnum, ent_type,
		              isnew ? " (new)" : "",
		              (self.dbg_last_ent_type && self.dbg_last_ent_type != ent_type)
		                ? sprintf(" (was %g!)", self.dbg_last_ent_type) : "",
		              self.origin, self.model));
	}
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
		self.wep_action_id   = readlong();   // 32-bit — matches server's WriteLong in PM_PredictionProxy_SendEntity
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
		// Speed-factor blend state — paired with WriteFloat in
		// PM_PredictionProxy_SendEntity.  Preserves in-flight transition
		// across reconcile so client replay and server pmove stay
		// synchronized through ping-window weapon switches.
		self.pm_weapon_blend_progress = readfloat();
		self.pm_weapon_prev_factor    = readfloat();
	}

	if (changedflags & PM_SF_AMMO)
	{
		// 6-byte bitmask + per-bit conditional readbyte.  Matches the
		// server write order in PM_PredictionProxy_SendEntity exactly.
		// Fields whose bit is clear keep their cached value (server
		// skipped writing them because they didn't change this send).
		float m0 = readbyte();
		float m1 = readbyte();
		float m2 = readbyte();
		float m3 = readbyte();
		float m4 = readbyte();
		float m5 = readbyte();

		// byte 0
		if (m0 &   1) self.mag_deagle          = readbyte();
		if (m0 &   2) self.ammo_deagle         = readbyte();
		if (m0 &   4) self.mag_ak47            = readbyte();
		if (m0 &   8) self.ammo_ak47           = readbyte();
		if (m0 &  16) self.mag_m4a1            = readbyte();
		if (m0 &  32) self.ammo_m4a1           = readbyte();
		if (m0 &  64) self.m4a1_silenced       = readbyte();
		if (m0 & 128) self.mag_flakshotgun     = readbyte();

		// byte 1
		if (m1 &   1) self.mag_pistol          = readbyte();
		if (m1 &   2) self.ammo_pistol         = readbyte();
		if (m1 &   4) self.mag_scout           = readbyte();
		if (m1 &   8) self.ammo_scout          = readbyte();
		if (m1 &  16) self.mag_357             = readbyte();
		if (m1 &  32) self.ammo_357            = readbyte();
		if (m1 &  64) self.mag_m249            = readbyte();
		if (m1 & 128) self.ammo_m249           = readbyte();

		// byte 2
		if (m2 &   1) self.mag_awp             = readbyte();
		if (m2 &   2) self.ammo_awp            = readbyte();
		if (m2 &   4) self.mag_98k             = readbyte();
		if (m2 &   8) self.ammo_98k            = readbyte();
		if (m2 &  16) self.mag_shotgun         = readbyte();
		if (m2 &  32) self.ammo_shotgun        = readbyte();
		if (m2 &  64) self.mag_m3              = readbyte();
		if (m2 & 128) self.ammo_m3             = readbyte();

		// byte 3
		if (m3 &   1) self.mag_mp5             = readbyte();
		if (m3 &   2) self.ammo_mp5            = readbyte();
		if (m3 &   4) self.mag_crossbow        = readbyte();
		if (m3 &   8) self.ammo_crossbow       = readbyte();
		if (m3 &  16) self.mag_grenadelauncher = readbyte();
		if (m3 &  32) self.mag_rebar           = readbyte();
		if (m3 &  64) self.ammo_gauss          = readbyte();
		if (m3 & 128) self.mag_glock           = readbyte();

		// byte 4
		if (m4 &   1) self.ammo_glock          = readbyte();
		if (m4 &   2) self.mag_g3sg1           = readbyte();
		if (m4 &   4) self.ammo_g3sg1          = readbyte();
		if (m4 &   8) self.mag_hlsmg           = readbyte();
		if (m4 &  16) self.ammo_hlsmg          = readbyte();
		if (m4 &  32) self.ammo_hlsmg_grenades = readbyte();
		if (m4 &  64) self.mag_hlrpg           = readbyte();
		if (m4 & 128) self.ammo_hlrpg          = readbyte();

		// byte 5 (bit 7 unused — 47 fields total)
		if (m5 &   1) self.ammo_hlgrenade      = readbyte();
		if (m5 &   2) self.mag_hlglock         = readbyte();
		if (m5 &   4) self.ammo_hlglock        = readbyte();
		if (m5 &   8) self.ammo_hlegon         = readbyte();
		if (m5 &  16) self.mag_csusp           = readbyte();
		if (m5 &  32) self.ammo_csusp          = readbyte();
		if (m5 &  64) self.csusp_silenced      = readbyte();
	}

	CSQC_StoreConfirmedStateFromEntity(self);
	sv_confirmed_cmdframe        = servercommandframe;
	csqc_dbg_last_snapshot_time  = cltime;
	csqc_baseline_valid          = TRUE;
	csqc_prediction_valid        = TRUE;
	csqc_dbg_seed_source         = 2;
	CSQC_ReconcilePrediction();
};
