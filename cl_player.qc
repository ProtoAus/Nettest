
/*
==============================================================================
cl_player.qc  –  Client-side prediction

PM_PlayerMove (from sh_pmove.qc) is called here on every input frame so the
local player feels immediately responsive regardless of ping.

Prediction flow:
  1.  Server sends a confirmed position/velocity via CSQC_Ent_Update.
      We store it in sv_confirmed_* globals and mark the baseline as valid.
  2.  CSQC_Input_Frame is called each render frame with the current input_*
      globals already set.  We reset localplayer to the server baseline and
      run PM_PlayerMove once to get the predicted position one frame ahead.
  3.  CSQC_UpdateView reads localplayer.origin and sets the camera there.

TODO: for full reconciliation at high ping, replace the single-frame prediction
with a circular input-command buffer and replay all unacknowledged commands
against the server baseline each frame.
==============================================================================
*/

// ---------------------------------------------------------------------------
//  Server-confirmed baseline (populated in CSQC_Ent_Update)
// ---------------------------------------------------------------------------

vector sv_confirmed_origin;
vector sv_confirmed_velocity;
float  sv_confirmed_flags;       // FL_ONGROUND etc.
float  sv_confirmed_jump_held;
float  sv_confirmed_jump_msec;
float  sv_confirmed_waterjumptime;

float  csqc_prediction_valid;    // TRUE once we have a server baseline

// The local player entity number (1-based): player index 0 → ent 1, etc.
float  localplayer_entnum;


// ---------------------------------------------------------------------------
//  CSQC_PredictPlayer  –  called from CSQC_Input_Frame
// ---------------------------------------------------------------------------

void() CSQC_PredictPlayer =
{
	if (!localplayer || !csqc_prediction_valid)
		return;

	entity saved = self;
	self = localplayer;

	// reset to server-confirmed baseline
	setorigin(self, sv_confirmed_origin);
	self.velocity         = sv_confirmed_velocity;
	self.flags            = sv_confirmed_flags;
	self.pm_jump_held     = sv_confirmed_jump_held;
	self.pm_jump_msec     = sv_confirmed_jump_msec;
	self.pm_waterjumptime = sv_confirmed_waterjumptime;

	// run one step of movement with the current frame's inputs
	PM_PlayerMove();

	self = saved;
};


// ---------------------------------------------------------------------------
//  CSQC_Input_Frame  –  called each render frame, inputs already set
// ---------------------------------------------------------------------------

void() CSQC_Input_Frame =
{
	// clamp movement inputs to engine-safe range
	input_movevalues_x = bound(-350, input_movevalues_x, 350);
	input_movevalues_y = bound(-350, input_movevalues_y, 350);
	input_movevalues_z = bound(-350, input_movevalues_z, 350);

	CSQC_PredictPlayer();
};


// ---------------------------------------------------------------------------
//  CSQC_Ent_Update  –  receive entity state from server
//
//  When the server sends an update for the local player entity, we snapshot
//  it as the new reconciliation baseline and keep localplayer pointing at it.
// ---------------------------------------------------------------------------

noref void(float isnew) CSQC_Ent_Update =
{
	if (isnew)
	{
		// First time we see this entity: initialise the movetype so our
		// prediction code knows what kind of movement to apply.
		self.pm_movetype = PM_MOVETYPE_NORMAL;
		self.view_ofs    = '0 0 48';
	}

	// Check whether this entity is the local player.
	// In FTE, player N (0-based) occupies entity slot N+1.
	if (num_for_edict(self) == player_localnum + 1)
	{
		localplayer = self;

		// snapshot the authoritative server state
		sv_confirmed_origin       = self.origin;
		sv_confirmed_velocity     = self.velocity;
		sv_confirmed_flags        = self.flags;
		sv_confirmed_jump_held    = self.pm_jump_held;
		sv_confirmed_jump_msec    = self.pm_jump_msec;
		sv_confirmed_waterjumptime = self.pm_waterjumptime;

		csqc_prediction_valid = TRUE;
	}
};
