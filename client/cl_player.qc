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

float  csqc_prediction_valid;    // TRUE once predicted_player can drive view
float  csqc_baseline_valid;      // TRUE once an authoritative proxy snapshot arrived
float  csqc_proxy_seen;          // owner-only proxy seen this map/session
float  csqc_proxy_entnum;
entity csqc_authority_proxy;

// ---------------------------------------------------------------------------
//  Buffered input command history
// ---------------------------------------------------------------------------

const float PRED_CMD_BACKUP = 128;

float  pred_cmd_valid[128];
float  pred_cmd_sequence[128];
float  pred_cmd_timestamp[128];
float  pred_cmd_timelength[128];
vector pred_cmd_angles[128];
vector pred_cmd_movevalues[128];
float  pred_cmd_buttons[128];
float  pred_cmd_impulse[128];
float  pred_cmd_count;
float  pred_cmd_latest_sequence;

// ---------------------------------------------------------------------------
//  Presentation, live input, and diagnostics
// ---------------------------------------------------------------------------

vector csqc_present_origin;
vector csqc_present_view_ofs;
float  csqc_present_valid;
float  csqc_live_forward;
float  csqc_live_back;
float  csqc_live_left;
float  csqc_live_right;
float  csqc_live_up;
float  csqc_live_down;
float  csqc_live_buttons;
float  csqc_pred_debug;
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
	else if (cmd == "+speed" || cmd == "+button9")
		CSQC_SetLiveButton(PM_BTN_WALK, down);
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
	float custom_bits = PM_BTN_USE | PM_BTN_WALK;
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

	CSQC_ResetToConfirmedMoveState();

	self.slot_primary     = sv_confirmed_slot_primary;
	self.slot_secondary   = sv_confirmed_slot_secondary;
	self.slot_melee       = sv_confirmed_slot_melee;
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

	predicted_player.slot_primary     = WEP_NONE;
	predicted_player.slot_secondary   = WEP_NONE;
	predicted_player.slot_melee       = WEP_NONE;
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

void() CSQC_DrawPredictionDebug =
{
	float box_height;
	float oldest;
	float server_error;
	string line;
	string seed_source;
	vector live_move;
	vector server_delta;
	float y;

	if (!csqc_pred_debug)
		return;

	box_height = 214;
	if (csqc_pred_debug > 1)
		box_height = 238;

	drawfill([8, 8], [620, box_height], [0, 0, 0], 0.65, 0);

	localplayer = CSQC_GetEngineLocalPlayer();
	oldest = CSQC_FirstBufferedSequence();
	seed_source = CSQC_DebugSeedSource();
	server_error = 0;
	if (predicted_player && csqc_baseline_valid)
	{
		server_delta = predicted_player.origin - sv_confirmed_origin;
		server_error = vlen(server_delta);
	}

	y = 12;
	line = sprintf("pred_debug  cltime %.3f  frametime %.4f", cltime, frametime);
	drawstring([12, y], line, [8, 8], [1, 1, 1], 1, 0);
	y += 12;

	line = sprintf("proxy %.0f ent %.0f  baseline %.0f  seed %s",
		csqc_proxy_seen, csqc_proxy_entnum, csqc_baseline_valid, seed_source);
	drawstring([12, y], line, [8, 8], [1, 1, 1], 1, 0);
	y += 12;

	line = sprintf("frames ccmd %.0f  scmd %.0f  oldest %.0f  latest %.0f  count %.0f",
		clientcommandframe, servercommandframe, oldest,
		pred_cmd_latest_sequence, pred_cmd_count);
	drawstring([12, y], line, [8, 8], [1, 1, 1], 1, 0);
	y += 12;

	line = sprintf("ages key %.1fms  input %.1fms  snap %.1fms  recon %.1fms  present %.1fms",
		(cltime - csqc_dbg_last_key_time) * 1000,
		(cltime - csqc_dbg_last_inputframe_time) * 1000,
		(cltime - csqc_dbg_last_snapshot_time) * 1000,
		(cltime - csqc_dbg_last_reconcile_time) * 1000,
		(cltime - csqc_dbg_last_present_time) * 1000);
	drawstring([12, y], line, [8, 8], [1, 1, 1], 1, 0);
	y += 12;

	line = sprintf("last key %s %s", csqc_dbg_last_key_cmd, csqc_dbg_last_key_down ? "down" : "up");
	drawstring([12, y], line, [8, 8], [1, 1, 0.5], 1, 0);
	y += 12;

	live_move = CSQC_BuildLiveMoveValues();
	line = sprintf("live mv %.0f %.0f %.0f  btn %.0f", live_move_x,
		live_move_y, live_move_z, csqc_live_buttons);
	drawstring([12, y], line, [8, 8], [0.8, 1, 0.8], 1, 0);
	y += 12;

	if (predicted_player)
	{
		line = sprintf("pred org %.2f %.2f %.2f  vel %.2f %.2f %.2f  carry %.4f",
			predicted_player.origin_x, predicted_player.origin_y, predicted_player.origin_z,
			predicted_player.velocity_x, predicted_player.velocity_y, predicted_player.velocity_z,
			predicted_player.pm_timecarry);
		drawstring([12, y], line, [8, 8], [0.7, 0.9, 1], 1, 0);
		y += 12;
	}

	if (csqc_baseline_valid)
	{
		line = sprintf("auth org %.2f %.2f %.2f  vel %.2f %.2f %.2f",
			sv_confirmed_origin_x, sv_confirmed_origin_y, sv_confirmed_origin_z,
			sv_confirmed_velocity_x, sv_confirmed_velocity_y, sv_confirmed_velocity_z);
		drawstring([12, y], line, [8, 8], [1, 0.8, 0.7], 1, 0);
		y += 12;
	}

	line = sprintf("pred-auth err %.3f  replay from %.0f  count %.0f",
		server_error, csqc_dbg_last_replay_from, csqc_dbg_last_replay_count);
	drawstring([12, y], line, [8, 8], [1, 0.7, 0.7], 1, 0);
	y += 12;

	line = sprintf("ackdrop %.0f  overflow %.0f  probe preview %.1fms  predict %.1fms  pending %.0f",
		csqc_dbg_ack_fell_out, csqc_dbg_ring_overflowed,
		csqc_dbg_last_preview_response_ms, csqc_dbg_last_predict_response_ms, csqc_dbg_probe_pending);
	drawstring([12, y], line, [8, 8], [1, 1, 0.6], 1, 0);
	y += 12;

	line = sprintf("preview dt %.1fms  predict dt %.1fms",
		csqc_dbg_last_preview_dt, csqc_dbg_last_predict_dt);
	drawstring([12, y], line, [8, 8], [1, 1, 0.6], 1, 0);
	y += 12;

	if (csqc_pred_debug > 1 && localplayer)
	{
		line = sprintf("engine org %.2f %.2f %.2f  vel %.2f %.2f %.2f",
			localplayer.origin_x, localplayer.origin_y, localplayer.origin_z,
			localplayer.velocity_x, localplayer.velocity_y, localplayer.velocity_z);
		drawstring([12, y], line, [8, 8], [0.7, 1, 0.7], 1, 0);
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
		PM_PlayerMove();
		if (replay_weapons)
			CSQC_PredictWeaponCommand();
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

	entity saved = self;
	self = predicted_player;

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
	PM_PlayerMove();
	CSQC_PredictWeaponCommand();
	csqc_dbg_last_predict_dt = (cltime - csqc_dbg_last_key_time) * 1000;
	CSQC_CheckDebugPredictResponse();

	self = saved;
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
	csqc_present_origin = predicted_player.origin;
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

	float fixedstep = cvar("sv_mintic");
	if (fixedstep < 0.001) fixedstep = 0.01;

	pm_suppress_sounds = TRUE;   // preview steps are speculative — no sounds
	while (preview_time > PM_FIXEDSTEP_EPSILON)
	{
		input_timelength = min(preview_time, fixedstep);
		PM_PlayerMoveStep();
		preview_time -= input_timelength;
	}
	pm_suppress_sounds = FALSE;

	csqc_present_origin = self.origin;
	csqc_present_view_ofs = self.view_ofs;
	csqc_dbg_last_present_time = cltime;
	csqc_dbg_last_preview_dt = (cltime - csqc_dbg_last_key_time) * 1000;
	CSQC_CheckDebugPreviewResponse();

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
// ---------------------------------------------------------------------------

void() CSQC_ExtrapolateRemotePlayers =
{
	float n;
	float dt;
	float gravity;
	vector base_origin;
	vector extrap_origin;
	entity ent;

	gravity = cvar("sv_gravity");
	if (!gravity) gravity = 800;

	// cltime = local wall clock  |  time = server game time at last packet
	dt = cltime - time;
	dt = bound(0, dt, 0.1);
	if (dt <= 0)
		return;

	for (n = 1; n <= maxclients; n++)
	{
		if (n == player_localentnum)
			continue;

		if (!(float)getentity(n, GE_ACTIVE))
			continue;

		// engine's interpolated position for this slot
		base_origin = getentity(n, GE_ORIGIN);

		ent = edict_num(n);

		// velocity-based extrapolation
		extrap_origin = base_origin + ent.velocity * dt;

		// gravity correction when airborne
		if (!(ent.flags & FL_ONGROUND))
			extrap_origin_z -= 0.5 * gravity * dt * dt;

		ent.origin = extrap_origin;
	}
};

// ---------------------------------------------------------------------------
//  CSQC_SetupRemotePlayerSolids
//  Called before each prediction tick so that other players are solid
//  obstacles in PM_TraceHull (MOVE_NORMAL).  Uses the engine-interpolated
//  position for each active remote player slot, with the correct standing or
//  ducking hull.  Must run before PM_PlayerMoveStep, not just at render time.
// ---------------------------------------------------------------------------

void() CSQC_SetupRemotePlayerSolids =
{
	float  n;
	entity ent;
	vector emins, emaxs;

	PM_ReadMovevars();

	for (n = 1; n <= maxclients; n++)
	{
		if (n == player_localentnum)
			continue;

		if (!(float)getentity(n, GE_ACTIVE))
			continue;

		ent = edict_num(n);
		if (!ent || ent == world)
			continue;

		// Use duck hull if the remote player is crouching
		if (ent.flags & FL_DUCKING)
		{
			emins = PM_DUCK_MINS;
			emaxs = PM_DUCK_MAXS;
		}
		else
		{
			emins = PM_MINS;
			emaxs = PM_MAXS;
		}

		setorigin(ent, getentity(n, GE_ORIGIN));
		setsize(ent, emins, emaxs);
		ent.solid = SOLID_SLIDEBOX;
	}
};

// ---------------------------------------------------------------------------
//  CSQC_Input_Frame  -  called each input frame, inputs already set
// ---------------------------------------------------------------------------

void() CSQC_Input_Frame =
{
	localplayer = CSQC_GetEngineLocalPlayer();
	CSQC_SetupRemotePlayerSolids();
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

	// Dead: capture freecam input before zeroing, then block
	if (getstatf(STAT_IS_DEAD))
	{
		spec_freecam_fwd = input_movevalues_x / 350;
		spec_freecam_side = input_movevalues_y / 350;
		input_movevalues = '0 0 0';
		input_buttons = 0;
	}

	CSQC_BufferInputCommand(clientcommandframe);
	CSQC_PredictCurrentCommand();
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

noref void(float isnew) CSQC_Ent_Update =
{
	float ent_type;

	ent_type = readbyte();

	if (ent_type == CSQC_ENT_PUSH_TRIGGER)
	{
		CSQC_PushTrigger_Update();
		return;
	}

	if (ent_type == CSQC_ENT_TELEPORT_TRIGGER)
	{
		CSQC_TeleportTrigger_Update();
		return;
	}

	if (ent_type == CSQC_ENT_LADDER_TRIGGER)
	{
		CSQC_LadderTrigger_Update();
		return;
	}

	if (ent_type == CSQC_ENT_SOLID_BRUSH)
	{
		CSQC_SolidBrush_Update();
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

	setorigin(self, readvector());
	self.velocity      = readvector();
	self.view_ofs      = readvector();
	self.flags         = readfloat();
	self.pm_movetype   = readfloat();
	self.pm_jump_held  = readfloat();
	self.pm_jump_msec  = readfloat();
	self.pm_waterjumptime = readfloat();
	self.pm_in_duck    = readfloat();
	self.pm_duck_msec  = readfloat();
	self.pm_oldbuttons    = readfloat();
	self.pm_timecarry     = readfloat();
	self.pm_teleport_time        = readfloat();
	self.pm_ladder_detach_time   = readfloat();
	self.pm_fuser2               = readfloat();
	self.spread_penalty          = readfloat();
	self.fire_spread_penalty     = readfloat();
	self.pm_step_time            = readfloat();

	// Weapon prediction state
	self.slot_primary      = readfloat();
	self.slot_secondary    = readfloat();
	self.slot_melee        = readfloat();
	self.weapon          = readfloat();
	self.previous_weapon = readfloat();
	self.weaponstate     = readfloat();
	self.wep_action_id   = readfloat();
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
	self.mag_deagle      = readfloat();
	self.ammo_deagle     = readfloat();
	self.mag_ak47        = readfloat();
	self.ammo_ak47       = readfloat();
	self.mag_m4a1        = readfloat();
	self.ammo_m4a1       = readfloat();
	self.m4a1_silenced   = readfloat();
	self.mag_flakshotgun = readfloat();
	self.mag_pistol      = readfloat();
	self.ammo_pistol     = readfloat();
	self.mag_scout       = readfloat();
	self.ammo_scout      = readfloat();
	self.mag_357         = readfloat();
	self.ammo_357        = readfloat();
	self.mag_m249        = readfloat();
	self.ammo_m249       = readfloat();
	self.zoomstage       = readfloat();
	self.mag_awp         = readfloat();
	self.ammo_awp        = readfloat();
	self.mag_98k         = readfloat();
	self.ammo_98k        = readfloat();
	self.mag_shotgun     = readfloat();
	self.ammo_shotgun    = readfloat();
	self.mag_m3          = readfloat();
	self.ammo_m3         = readfloat();
	self.mag_mp5         = readfloat();
	self.ammo_mp5        = readfloat();
	self.mag_crossbow    = readfloat();
	self.ammo_crossbow   = readfloat();
	self.mag_grenadelauncher = readfloat();
	self.mag_rebar       = readfloat();
	self.ammo_gauss      = readfloat();
	self.mag_glock       = readfloat();
	self.ammo_glock      = readfloat();
	self.mag_g3sg1       = readfloat();
	self.ammo_g3sg1      = readfloat();

	CSQC_StoreConfirmedStateFromEntity(self);
	sv_confirmed_cmdframe        = servercommandframe;
	csqc_dbg_last_snapshot_time  = cltime;
	csqc_baseline_valid          = TRUE;
	csqc_prediction_valid        = TRUE;
	csqc_dbg_seed_source         = 2;
	CSQC_ReconcilePrediction();
};
