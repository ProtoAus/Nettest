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
float  sv_confirmed_cmdframe;    // last acknowledged command for baseline

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

	csqc_live_buttons = input_buttons;
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
};

void() CSQC_ResetToConfirmedState =
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
	self.pm_oldbuttons    = sv_confirmed_oldbuttons;
	self.pm_timecarry     = sv_confirmed_timecarry;
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
	predicted_player.pm_movetype = PM_MOVETYPE_NORMAL;
	predicted_player.view_ofs = PM_VIEW_OFS;
	predicted_player.pm_jump_held = FALSE;
	predicted_player.pm_jump_msec = 0;
	predicted_player.pm_waterjumptime = 0;
	predicted_player.pm_in_duck = FALSE;
	predicted_player.pm_duck_msec = 0;
	predicted_player.pm_oldbuttons = 0;
	predicted_player.pm_timecarry = 0;
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

	if (!predicted_player.view_ofs_x && !predicted_player.view_ofs_y && !predicted_player.view_ofs_z)
		predicted_player.view_ofs = PM_VIEW_OFS;

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

	pred_cmd_latest_sequence = seq;
};

float(float first_sequence) CSQC_ReplayBufferedCommands =
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
		PM_PlayerMove();
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
	float saved_timelength;
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

	CSQC_ResetToConfirmedState();

	if (ack_slot < 0)
		replay_from = max(replay_from, first_buffered);

	csqc_dbg_last_replay_from = replay_from;
	csqc_dbg_last_replay_count = CSQC_ReplayBufferedCommands(replay_from);
	csqc_dbg_last_reconcile_time = cltime;
	csqc_dbg_seed_source = 2;

	input_timelength = saved_timelength;
	input_angles     = saved_angles;
	input_movevalues = saved_movevalues;
	input_buttons    = saved_buttons;

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

	PM_PlayerMove();
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

	saved_timelength = input_timelength;
	saved_angles = input_angles;
	saved_movevalues = input_movevalues;
	saved_buttons = input_buttons;

	input_angles = view_angles;
	input_movevalues = CSQC_BuildLiveMoveValues();
	input_buttons = csqc_live_buttons;
	CSQC_ClampMoveInputs();

	while (preview_time > PM_FIXEDSTEP_EPSILON)
	{
		input_timelength = min(preview_time, PM_FIXEDSTEP);
		PM_PlayerMoveStep();
		preview_time -= input_timelength;
	}

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

	input_timelength = saved_timelength;
	input_angles = saved_angles;
	input_movevalues = saved_movevalues;
	input_buttons = saved_buttons;

	self = saved;
};


// ---------------------------------------------------------------------------
//  CSQC_Input_Frame  -  called each input frame, inputs already set
// ---------------------------------------------------------------------------

void() CSQC_Input_Frame =
{
	localplayer = CSQC_GetEngineLocalPlayer();
	CSQC_ClampMoveInputs();
	csqc_dbg_last_inputframe_time = cltime;
	CSQC_LatchLiveInputFromCommand();
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
	self.pm_movetype = PM_MOVETYPE_NORMAL;
	self.view_ofs = PM_VIEW_OFS;
	self.pm_timecarry = 0;
};

noref void(float isnew) CSQC_Ent_Update =
{
	float version;

	localplayer = CSQC_GetEngineLocalPlayer();
	csqc_authority_proxy = self;
	csqc_proxy_seen = TRUE;
	csqc_proxy_entnum = self.entnum;

	if (isnew)
	{
		self.pm_movetype = PM_MOVETYPE_NORMAL;
		self.view_ofs = PM_VIEW_OFS;
		self.pm_timecarry = 0;
	}

	version = readbyte();
	if (version != PM_CSQC_PROXY_VERSION)
		print(sprintf("prediction proxy version mismatch: got %g expected %g\n",
			version, PM_CSQC_PROXY_VERSION));

	setorigin(self, readvector());
	self.velocity = readvector();
	self.view_ofs = readvector();
	self.flags = readfloat();
	self.pm_movetype = readfloat();
	self.pm_jump_held = readfloat();
	self.pm_jump_msec = readfloat();
	self.pm_waterjumptime = readfloat();
	self.pm_in_duck = readfloat();
	self.pm_duck_msec = readfloat();
	self.pm_oldbuttons = readfloat();
	self.pm_timecarry = readfloat();

	CSQC_StoreConfirmedStateFromEntity(self);
	sv_confirmed_cmdframe = servercommandframe;
	csqc_dbg_last_snapshot_time = cltime;
	csqc_baseline_valid = TRUE;
	csqc_prediction_valid = TRUE;
	csqc_dbg_seed_source = 2;
	CSQC_ReconcilePrediction();
};
