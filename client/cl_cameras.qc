// ============================================================
//  client/cl_cameras.qc  -  CSQC-side team-select preview cameras
//
//  Receives server "camera" entities that carry the
//  CAM_FLAG_TEAM_BLUE_PLAYER / CAM_FLAG_TEAM_RED_PLAYER spawnflags.
//  Exposes CSQC_GetPreviewCamera(required_flag) so the team-select
//  menu's DrawCharacterPreview viewport can render from a map-authored
//  camera position instead of the old hardcoded VF_ORIGIN=[300,0,-10].
//
//  Also owns the team-select main-view sway (CSQC_TeamSelectSwayAngles).
//  That used to live in server/sv_cameras.qc but was moved here so the
//  motion runs at render rate — immune to ping / server tick jitter.
// ============================================================

// Subtle sway applied to the team-select view each render frame.  Sine
// pair with incommensurate periods so the loop doesn't read as periodic.
// Amplitudes in degrees, rates in Hz.
const float TEAMSEL_SWAY_YAW_AMP    = 0.8;
const float TEAMSEL_SWAY_YAW_RATE   = 0.37;
const float TEAMSEL_SWAY_PITCH_AMP  = 0.45;
const float TEAMSEL_SWAY_PITCH_RATE = 0.23;

// Applies the sway offset to `base` (the server-provided team-select
// angles) using local cltime, and returns the result.  Caller is
// responsible for only invoking this while in team-select state.
vector(vector base) CSQC_TeamSelectSwayAngles =
{
    vector out = base;
    out_y += sin(cltime * TEAMSEL_SWAY_YAW_RATE   * 2 * 3.14159265) * TEAMSEL_SWAY_YAW_AMP;
    out_x += sin(cltime * TEAMSEL_SWAY_PITCH_RATE * 2 * 3.14159265) * TEAMSEL_SWAY_PITCH_AMP;
    return out;
};

// ============================================================
//  Sniper breathing sway (sv_snipersway)
//
//  Pure VF_ANGLES render modification — input_angles is untouched,
//  so the shot always fires from the player's real aim direction
//  (server-authoritative).  Sway scales with movement speed and
//  collapses near zero while the player holds +button4 (hold-breath).
//
//  All the CSQC_ApplySniperSway gates check client-local state, so
//  high ping doesn't phase-shift the sway off the weapon swap — the
//  moment predicted_player.weapon flips away from a sniper (instantly,
//  via prediction) the helper early-outs with the unmodified base.
// ============================================================

const float SNIPERSWAY_YAW_AMP    = 1.2;    // degrees, peak
const float SNIPERSWAY_YAW_RATE   = 0.4;    // Hz
const float SNIPERSWAY_PITCH_AMP  = 0.7;
const float SNIPERSWAY_PITCH_RATE = 0.28;

vector(vector base) CSQC_ApplySniperSway =
{
    // The classic + breathing sway is composed once per input frame
    // in cl_codscope.qc UpdateState and cached in csqc_codscope_sway_*.
    // That ensures the camera (this function) and the predicted /
    // authoritative trace (CSQC_PredictWeaponCommand + the SSQC cs
    // handler) all use the SAME bias values, so the bullet lands
    // exactly where the scoped crosshair appears.  This function is
    // now a thin wrapper that just adds the cached values to the
    // camera angles.  sv_snipersway / scope-eligibility / velocity
    // intensity / hold-breath scaling are all baked into the cached
    // values.
    vector out = base;
    out_x += csqc_codscope_sway_pitch;
    out_y += csqc_codscope_sway_yaw;
    return out;
};

// ============================================================
//  sv_gunkick view bias
//
//  Pure VF_ANGLES render modification — input_angles is untouched
//  so the player's mouse direction (the angle the engine sends to
//  the server with each input command) is unaffected. Only the
//  CAMERA tilts. The hitscan helper biases the trace direction by
//  the same kick state, so bullets land where the kicked crosshair
//  is pointing — not where the input angle is.
//
//  When the spring decays back to zero, the camera glides back to
//  the player's underlying input angle. That's the "fall back to
//  origin" behaviour from the user's design ask.
// ============================================================
vector(vector base) CSQC_ApplyViewKick =
{
    if (serverkeyfloat("sv_gunkick", 1) <= 0)
        return base;
    if (!predicted_player || !csqc_prediction_valid)
        return base;

    vector out = base;
    out_x += predicted_player.view_kick_pitch;
    out_y += predicted_player.view_kick_yaw;
    return out;
};

float csqc_damagekick_pitch;
float csqc_damagekick_roll;
float csqc_damagekick_last_time;

float(float value, float step) CSQC_ApproachZero =
{
    if (value > step)
        return value - step;
    if (value < 0 - step)
        return value + step;
    return 0;
};

void(float pitch, float roll) CSQC_DamageViewKick_Add =
{
    csqc_damagekick_pitch += pitch;
    csqc_damagekick_roll  += roll;

    csqc_damagekick_pitch = bound(-16, csqc_damagekick_pitch, 16);
    csqc_damagekick_roll  = bound(-24, csqc_damagekick_roll, 24);
};

vector(vector base) CSQC_ApplyDamageViewKick =
{
    if (serverkeyfloat("sv_headkick", 1) <= 0)
    {
        csqc_damagekick_pitch = 0;
        csqc_damagekick_roll = 0;
        csqc_damagekick_last_time = cltime;
        return base;
    }

    float dt = cltime - csqc_damagekick_last_time;
    csqc_damagekick_last_time = cltime;

    if (dt > 0)
    {
        float rate = serverkeyfloat("sv_headkick_return_rate", 24);
        if (rate <= 0)
            rate = 24;
        float step = rate * bound(0, dt, 0.1);
        csqc_damagekick_pitch = CSQC_ApproachZero(csqc_damagekick_pitch, step);
        csqc_damagekick_roll  = CSQC_ApproachZero(csqc_damagekick_roll, step);
    }

    vector out = base;
    out_x += csqc_damagekick_pitch;
    out_z += csqc_damagekick_roll;
    return out;
};

.entity         cam_list_next;
.float          cam_in_list;   // one-shot guard to prevent re-add on refresh

entity cam_list_head;

// Receive handler — called from CSQC_Ent_Update dispatcher.  Runs once on
// first arrival and again every time the server re-sends (e.g. after
// deferred target resolution).  Field writes are fine; re-adding to the
// linked list is NOT — it creates a circular list that CSQC_GetPreviewCamera
// loops forever on.
void() CSQC_Camera_Update =
{
    setorigin(self, readvector());       // .origin
    self.angles            = readvector();
    self.cam_target_origin = readvector();
    self.spawnflags        = readbyte();

    if (!self.cam_in_list)
    {
        self.cam_in_list   = 1;
        self.cam_list_next = cam_list_head;
        cam_list_head      = self;
    }
};

// Per-flag random-cycle state for the preview viewport.  Matches the
// server-side scheme in sv_cameras.qc — picks a fresh random camera on
// each cycle boundary and avoids back-to-back repeats when count > 1.
//
// FTEQCC treats `float x = -1;` at file scope as const, so the -1
// sentinel (needed so the first call actually picks at cycle 0) is
// assigned lazily on first use via preview_cycle_initialized.
float preview_cycle_initialized;
float preview_cycle_num_blue; float preview_cycle_idx_blue;
float preview_cycle_num_red;  float preview_cycle_idx_red;

float(float required_flag, float count) CSQC_PreviewRandomIdx =
{
    if (!preview_cycle_initialized)
    {
        preview_cycle_initialized = 1;
        preview_cycle_num_blue = -1;
        preview_cycle_num_red  = -1;
    }

    float cycle_num = floor(cltime / 7);
    float last_num, last_idx;

    if (required_flag & CAM_FLAG_TEAM_RED_PLAYER)
    {
        last_num = preview_cycle_num_red;
        last_idx = preview_cycle_idx_red;
    }
    else
    {
        last_num = preview_cycle_num_blue;
        last_idx = preview_cycle_idx_blue;
    }

    if (cycle_num != last_num)
    {
        float new_idx = floor(random() * count);
        if (new_idx < 0)      new_idx = 0;
        if (new_idx >= count) new_idx = count - 1;
        if (count > 1 && new_idx == last_idx)
            new_idx = (new_idx + 1) - floor((new_idx + 1) / count) * count;

        last_idx = new_idx;
        last_num = cycle_num;

        if (required_flag & CAM_FLAG_TEAM_RED_PLAYER)
        {
            preview_cycle_num_red = last_num;
            preview_cycle_idx_red = last_idx;
        }
        else
        {
            preview_cycle_num_blue = last_num;
            preview_cycle_idx_blue = last_idx;
        }
    }

    return last_idx;
};

// Look up a camera matching the requested flag.  Cycles by cltime so the
// preview animates across multiple matching cameras the mapper placed.
// Returns world if no camera matches.
entity(float required_flag) CSQC_GetPreviewCamera =
{
    entity c;
    float count = 0;
    for (c = cam_list_head; c; c = c.cam_list_next)
    {
        if (c.spawnflags & required_flag)
            count = count + 1;
    }
    if (count <= 0) return world;

    float idx = (count <= 1) ? 0 : CSQC_PreviewRandomIdx(required_flag, count);
    float i = 0;
    for (c = cam_list_head; c; c = c.cam_list_next)
    {
        if (c.spawnflags & required_flag)
        {
            if (i == idx) return c;
            i = i + 1;
        }
    }
    return world;
};
