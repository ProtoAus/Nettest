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
    // Server-side master toggle — read once per frame.  Default 0
    // (off); enable per-server with `sv_snipersway 1` while testing.
    if (serverkeyfloat("sv_snipersway", 0) <= 0)
        return base;
    if (!predicted_player || !csqc_prediction_valid)
        return base;
    if (predicted_player.zoomstage <= 0)
        return base;
    if (!Weapon_HasScope(predicted_player.weapon))
        return base;

    // Movement intensity: at rest ~0.5, walking ~1.3, running ~2.0.
    vector v = predicted_player.velocity;
    v_z = 0;
    float speed = vlen(v);
    float intensity = 0.5 + bound(0, speed / 300, 1.5);

    // Hold-breath on +button4 — drops sway to 15% of current.
    if (csqc_live_buttons & PM_BTN_SPRINT)
        intensity *= 0.15;

    vector out = base;
    out_y += sin(cltime * SNIPERSWAY_YAW_RATE   * 2 * 3.14159265) * SNIPERSWAY_YAW_AMP   * intensity;
    out_x += sin(cltime * SNIPERSWAY_PITCH_RATE * 2 * 3.14159265) * SNIPERSWAY_PITCH_AMP * intensity;
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
