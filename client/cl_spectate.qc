// ============================================================
//  client/cl_spectate.qc  -  Death camera and spectator system
//
//  Phases:
//    1. Death cam (mp_respawndelay): 3rd person at death spot
//    2. TDM: auto-respawn after delay
//    3. Elimination: spectator mode with player cycling and camera modes
// ============================================================

// Spectator camera modes
float SPEC_MODE_FIRSTPERSON  = 0;
float SPEC_MODE_THIRDPERSON  = 1;
float SPEC_MODE_FREECAM      = 2;

// Camera distance constants
float SPEC_CAM_BACK     = 80;
float SPEC_CAM_UP       = 40;
float SPEC_FREECAM_SPEED = 800;
float SPEC_FREECAM_ACCEL = 10;
float SPEC_FREECAM_FRICTION = 5;
float SPEC_FREECAM_SPRINT = 2.5;
float SPEC_FREECAM_DUCK  = 0.4;
float SPEC_SHADOW        = 1;   // drop shadow offset for spectator HUD text

// State
float spec_mode;
float spec_target;           // entity number (1..maxclients) being watched
float spec_was_dead;         // previous frame dead state for edge detection
float spec_was_in_deathcam;  // previous frame deathcam state
vector spec_death_origin;    // latched death position
vector spec_death_angles;    // latched death view direction
vector spec_freecam_origin;
vector spec_freecam_angles;
vector spec_freecam_velocity;
float spec_freecam_fwd_smooth;
float spec_freecam_side_smooth;
vector spec_follow_origin;   // smoothed target origin for follow modes
vector spec_follow_angles;   // smoothed target angles for follow modes
float spec_hint_time;        // cltime when button hints expire

// spec_freecam_fwd and spec_freecam_side declared in cl_customdefs.qc

// ============================================================
//  Query functions
// ============================================================

float() Spectate_IsActive =
{
    return getstatf(STAT_IS_DEAD) != 0;
};

float() Spectate_InDeathCam =
{
    return getstatf(STAT_DEATH_DELAY_LEFT) > 0;
};

// ============================================================
//  Target finding — cycle through alive players
// ============================================================

float(float dir) Spectate_FindTarget =
{
    float start, n, i;
    string name;

    start = spec_target;
    if (start < 1 || start > maxclients)
        start = 0;

    n = start;
    for (i = 0; i < maxclients; i++)
    {
        n = n + dir;
        if (n > maxclients) n = 1;
        if (n < 1) n = maxclients;

        if (n == player_localentnum)
            continue;

        name = getplayerkeyvalue(n - 1, INFOKEY_P_NAME);
        if (name == "")
            continue;

        // Check entity is active and visible (has a model)
        if (!(float)getentity(n, GE_ACTIVE))
            continue;

        spec_target = n;
        // Seed smooth follow state from new target to avoid lerp pop
        spec_follow_origin = (vector)getentity(n, GE_ORIGIN);
        spec_follow_origin_z += PM_VIEW_OFS_z;
        spec_follow_angles = (vector)getentity(n, GE_ANGLES);
        spec_follow_angles_x = 0 - spec_follow_angles_x;
        return n;
    }

    return spec_target;  // no valid target found, keep current
};

// ============================================================
//  Mode cycling
// ============================================================

float spec_last_cycle_time;

void() Spectate_CycleMode =
{
    // Debounce: ignore rapid key repeats
    if (cltime - spec_last_cycle_time < 0.3)
        return;
    spec_last_cycle_time = cltime;

    spec_mode = spec_mode + 1;
    if (spec_mode > SPEC_MODE_FREECAM)
        spec_mode = SPEC_MODE_FIRSTPERSON;

    // Follow modes need a valid target. Skip to freecam if nobody available.
    if (spec_mode != SPEC_MODE_FREECAM)
    {
        if (spec_target <= 0)
            Spectate_FindTarget(1);
        if (spec_target <= 0)
            spec_mode = SPEC_MODE_FREECAM;
    }

    if (spec_mode == SPEC_MODE_FREECAM)
    {
        spec_freecam_origin = campos;
        spec_freecam_angles = camang;
        spec_freecam_velocity = '0 0 0';
    }
};

// ============================================================
//  State management — called each frame from CSQC_UpdateView
// ============================================================

void() Spectate_UpdateState =
{
    float is_dead = getstatf(STAT_IS_DEAD);
    float in_deathcam = Spectate_InDeathCam();

    // Edge detect: just died
    if (is_dead && !spec_was_dead)
    {
        // Latch death position from prediction state
        if (predicted_player)
        {
            if (csqc_present_valid)
                spec_death_origin = csqc_present_origin;
            else
                spec_death_origin = predicted_player.origin;
        }
        else
            spec_death_origin = campos;

        spec_death_angles = view_angles;
        spec_target = 0;
        spec_mode = SPEC_MODE_FIRSTPERSON;
        spec_hint_time = 0;
    }

    // Edge detect: death cam just ended, entering spectator mode
    if (is_dead && !in_deathcam && spec_was_in_deathcam)
    {
        spec_hint_time = cltime + 3;
        Spectate_FindTarget(1);
        spec_mode = SPEC_MODE_FIRSTPERSON;
    }

    // Edge detect: respawned
    if (!is_dead && spec_was_dead)
    {
        spec_target = 0;
        spec_mode = SPEC_MODE_FIRSTPERSON;
        spec_hint_time = 0;
    }

    spec_was_dead = is_dead;
    spec_was_in_deathcam = in_deathcam;
};

// ============================================================
//  Target validity check
// ============================================================

void() Spectate_CheckTargetAlive =
{
    if (spec_mode == SPEC_MODE_FREECAM)
        return;

    if (spec_target <= 0)
    {
        Spectate_FindTarget(1);
        if (spec_target <= 0)
        {
            spec_mode = SPEC_MODE_FREECAM;
            spec_freecam_origin = campos;
            spec_freecam_angles = camang;
            spec_freecam_velocity = '0 0 0';
        }
        return;
    }

    // Check target is still valid
    string name = getplayerkeyvalue(spec_target - 1, INFOKEY_P_NAME);
    if (name == "" || !(float)getentity(spec_target, GE_ACTIVE))
    {
        Spectate_FindTarget(1);
        if (spec_target <= 0)
        {
            spec_mode = SPEC_MODE_FREECAM;
            spec_freecam_origin = campos;
            spec_freecam_angles = camang;
            spec_freecam_velocity = '0 0 0';
        }
    }
};

// ============================================================
//  Camera update
// ============================================================

void() Spectate_UpdateCamera =
{
    vector target_origin, cam_offset, cam_pos, trace_end;
    vector fwd, rt, up;

    if (Spectate_InDeathCam())
    {
        // 3rd person behind death spot, allow mouselook to orbit
        spec_death_angles = view_angles;
        makevectors(spec_death_angles);

        cam_offset = v_forward * (-SPEC_CAM_BACK) + '0 0 1' * SPEC_CAM_UP;
        cam_pos = spec_death_origin + cam_offset;

        // Wall clip
        traceline(spec_death_origin, cam_pos, TRUE, world);
        if (trace_fraction < 1)
            cam_pos = trace_endpos + trace_plane_normal * 2;

        campos = cam_pos;
        camang = spec_death_angles;
        setproperty(VF_ORIGIN, campos);
        setproperty(VF_ANGLES, camang);
        return;
    }

    if (spec_mode == SPEC_MODE_FREECAM)
    {
        // Momentum-style fly camera with acceleration and friction
        spec_freecam_angles = view_angles;
        makevectors(spec_freecam_angles);
        fwd = v_forward;
        rt = v_right;
        up = '0 0 1';

        // Smooth raw input to avoid stutter between input frames
        float lerp_speed = bound(0, frametime * 20, 1);
        spec_freecam_fwd_smooth += (spec_freecam_fwd - spec_freecam_fwd_smooth) * lerp_speed;
        spec_freecam_side_smooth += (spec_freecam_side - spec_freecam_side_smooth) * lerp_speed;

        // Speed multipliers from held buttons
        float factor = 1.0;
        if (csqc_live_buttons & PM_BTN_SPRINT)
            factor *= SPEC_FREECAM_SPRINT;
        if (csqc_live_buttons & PM_BTN_DUCK)
            factor *= SPEC_FREECAM_DUCK;

        // Build wish velocity from smoothed input + vertical from live buttons
        float vert = 0;
        if (csqc_live_buttons & PM_BTN_JUMP)
            vert += 1;
        if (csqc_live_buttons & PM_BTN_DUCK)
            vert -= 1;

        vector wishvel = (fwd * spec_freecam_fwd_smooth
                        + rt * spec_freecam_side_smooth
                        + up * vert) * SPEC_FREECAM_SPEED * factor;

        float wishspeed = vlen(wishvel);
        vector wishdir = wishvel;
        if (wishspeed > 0)
            wishdir = wishdir * (1.0 / wishspeed);

        float maxspeed = SPEC_FREECAM_SPEED * factor;
        if (wishspeed > maxspeed)
            wishspeed = maxspeed;

        // Accelerate towards wish velocity
        float currentspeed = spec_freecam_velocity * wishdir;
        float addspeed = wishspeed - currentspeed;
        if (addspeed > 0)
        {
            float accelspeed = SPEC_FREECAM_ACCEL * frametime * wishspeed;
            if (accelspeed > addspeed)
                accelspeed = addspeed;
            spec_freecam_velocity = spec_freecam_velocity + wishdir * accelspeed;
        }

        // Friction — bleed off speed
        float speed = vlen(spec_freecam_velocity);
        if (speed < 1)
        {
            spec_freecam_velocity = '0 0 0';
        }
        else
        {
            float control = max(speed, maxspeed * 0.25);
            float drop = control * SPEC_FREECAM_FRICTION * frametime;
            float newspeed = max(speed - drop, 0) / speed;
            spec_freecam_velocity = spec_freecam_velocity * newspeed;
        }

        spec_freecam_origin = spec_freecam_origin + spec_freecam_velocity * frametime;

        campos = spec_freecam_origin;
        camang = spec_freecam_angles;
        setproperty(VF_ORIGIN, campos);
        setproperty(VF_ANGLES, camang);
        return;
    }

    // First-person or third-person following a target
    if (spec_target <= 0)
        return;

    target_origin = (vector)getentity(spec_target, GE_ORIGIN);

    // Add eye offset (standing player view height)
    target_origin_z = target_origin_z + PM_VIEW_OFS_z;

    // Get the target's actual angles.
    // The engine entity's angles_x is 0 (set by SH_PlayerAnim_Update to
    // keep the body upright). The real view pitch is in the visual proxy's
    // vis_pitch field (the player's v_angle_x sent via SendEntity).
    vector target_angles = (vector)getentity(spec_target, GE_ANGLES);
    target_angles_z = 0;

    // Find the visual proxy for this player and read vis_pitch
    entity vis = findfloat(world, vis_owner_entnum, spec_target);
    if (vis)
        target_angles_x = vis.vis_pitch;
    else
    {
        // Fallback: undo QW pitch compression
        target_angles_x = 0 - target_angles_x * 3;
        target_angles_x = bound(-90, target_angles_x, 90);
    }

    // Smooth interpolation toward server-sent position/angles
    float follow_lerp = bound(0, frametime * 30, 1);
    spec_follow_origin += (target_origin - spec_follow_origin) * follow_lerp;
    spec_follow_angles += (target_angles - spec_follow_angles) * follow_lerp;
    spec_follow_angles_z = 0;   // kill roll

    if (spec_mode == SPEC_MODE_FIRSTPERSON)
    {
        campos = spec_follow_origin;
        camang = spec_follow_angles;
        setproperty(VF_ORIGIN, campos);
        setproperty(VF_ANGLES, camang);
        // Hide the spectated player's model so it doesn't block the view
        setproperty(VF_VIEWENTITY, spec_target);
    }
    else if (spec_mode == SPEC_MODE_THIRDPERSON)
    {
        makevectors(spec_follow_angles);
        fwd = v_forward;
        cam_offset = fwd * (-SPEC_CAM_BACK) + '0 0 1' * SPEC_CAM_UP;
        cam_pos = spec_follow_origin + cam_offset;

        traceline(spec_follow_origin, cam_pos, TRUE, world);
        if (trace_fraction < 1)
            cam_pos = trace_endpos + trace_plane_normal * 2;

        campos = cam_pos;
        camang = vectoangles(normalize(spec_follow_origin - cam_pos), '0 0 1');
        camang_x = 0 - camang_x;   // fix Quake inverted pitch
        setproperty(VF_ORIGIN, campos);
        setproperty(VF_ANGLES, camang);
    }
};

// Spectate_CaptureFreecamInput inlined in cl_player.qc CSQC_Input_Frame

// ============================================================
//  Input handling — spectator mode only (not death cam)
// ============================================================

float(float evtype, float scanx, float chary, float devid) Spectate_HandleInput =
{
    string cmd;

    if (evtype != IE_KEYDOWN)
        return FALSE;

    // Mouse1: next player
    if (scanx == K_MOUSE1)
    {
        Spectate_FindTarget(1);
        return TRUE;
    }

    // Mouse2: previous player
    if (scanx == K_MOUSE2)
    {
        Spectate_FindTarget(-1);
        return TRUE;
    }

    // +jump: cycle camera mode
    cmd = getkeybind(scanx);
    if (cmd == "+jump")
    {
        Spectate_CycleMode();
        return TRUE;
    }

    return FALSE;
};

// ============================================================
//  HUD drawing
// ============================================================

void() Spectate_DrawHUD =
{
    float cx, cy;
    string text = "";
    string sub_text = "";
    vector text_size, sub_size;
    float text_w, sub_w;
    float gamemode;

    cx = g_width * 0.5;
    cy = g_height * 0.4 + 42;
    text_size = [24, 24];
    sub_size = [12, 12];

    gamemode = getstatf(STAT_GAMEMODE);

    if (Spectate_InDeathCam())
    {
        float delay_left = getstatf(STAT_DEATH_DELAY_LEFT);

        if (gamemode == GAMEMODE_TDM)
            text = sprintf("Respawning in %.0f...", ceil(delay_left));
        else
            text = "You are dead";

        text_w = stringwidth(text, 1, text_size);
        drawstring([cx - text_w * 0.5 + SPEC_SHADOW, cy + SPEC_SHADOW], text, text_size, '0 0 0', 0.5, 0);
        drawstring([cx - text_w * 0.5, cy], text, text_size, '1 1 1', 0.9, 0);
        return;
    }

    // Spectator mode HUD
    // Target player name
    if (spec_target > 0 && spec_mode != SPEC_MODE_FREECAM)
    {
        string target_name = getplayerkeyvalue(spec_target - 1, INFOKEY_P_NAME);
        if (target_name != "")
        {
            text = sprintf("Spectating: %s", target_name);
            text_w = stringwidth(text, 1, sub_size);
            float name_y = g_height - 80;
            drawstring([cx - text_w * 0.5 + SPEC_SHADOW, name_y + SPEC_SHADOW], text, sub_size, '0 0 0', 0.4, 0);
            drawstring([cx - text_w * 0.5, name_y], text, sub_size, '0.8 0.8 0.8', 0.85, 0);
        }
    }

    // Camera mode label
    if (spec_mode == SPEC_MODE_FIRSTPERSON)
        text = "First Person";
    else if (spec_mode == SPEC_MODE_THIRDPERSON)
        text = "Third Person";
    else
        text = "Free Cam";

    text_w = stringwidth(text, 1, sub_size);
    float mode_y = g_height - 66;
    drawstring([cx - text_w * 0.5 + SPEC_SHADOW, mode_y + SPEC_SHADOW], text, sub_size, '0 0 0', 0.4, 0);
    drawstring([cx - text_w * 0.5, mode_y], text, sub_size, '0.7 0.7 0.7', 0.8, 0);

    // Button hints (shown for 3 seconds after entering spectator)
    if (cltime < spec_hint_time)
    {
        sub_text = "[Mouse1/Mouse2] Cycle Players   [Jump] Change View";
        sub_w = stringwidth(sub_text, 1, sub_size);
        float hint_y = g_height - 52;
        float hint_alpha = min(1.0, (spec_hint_time - cltime));  // fade out in last second
        drawstring([cx - sub_w * 0.5 + SPEC_SHADOW, hint_y + SPEC_SHADOW], sub_text, sub_size, '0 0 0', 0.3 * hint_alpha, 0);
        drawstring([cx - sub_w * 0.5, hint_y], sub_text, sub_size, '0.6 0.6 0.6', 0.7 * hint_alpha, 0);
    }
};
