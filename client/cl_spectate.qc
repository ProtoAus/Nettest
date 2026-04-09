// ============================================================
//  client/cl_spectate.qc  -  Death camera and spectator system
//
//  Phases:
//    1. Death cam (mp_deathdelay): 3rd person at death spot
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
float SPEC_FREECAM_SPEED = 320;
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
        return n;
    }

    return spec_target;  // no valid target found, keep current
};

// ============================================================
//  Mode cycling
// ============================================================

void() Spectate_CycleMode =
{
    spec_mode = spec_mode + 1;
    if (spec_mode > SPEC_MODE_FREECAM)
        spec_mode = SPEC_MODE_FIRSTPERSON;

    if (spec_mode == SPEC_MODE_FREECAM)
    {
        // Seed freecam from current camera position
        spec_freecam_origin = campos;
        spec_freecam_angles = camang;
    }
    else
    {
        // Entering player-follow mode — find a target if we don't have one
        if (spec_target <= 0)
            Spectate_FindTarget(1);
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
        // Noclip-style fly camera using live button state
        spec_freecam_angles = view_angles;
        makevectors(spec_freecam_angles);
        fwd = v_forward;
        rt = v_right;
        up = v_up;

        vector move_dir = '0 0 0';
        // Read live movement from csqc_live_buttons and approximate WASD
        // +forward/+back/+moveleft/+moveright map to input_movevalues in
        // the engine, but those are zeroed for dead players. Use the raw
        // input_movevalues that were captured BEFORE the dead-zero in
        // CSQC_Input_Frame. Since we can't access those, use a simpler
        // approach: build from csqc_live_buttons sprint bit for speed,
        // and just use the standard input_movevalues which for freecam
        // we'll read before zeroing.
        // Actually the simplest: read view_angles for direction, build
        // movement from whatever input_movevalues was before zeroing.
        // We capture pre-zero values in spec globals below.
        move_dir = fwd * spec_freecam_fwd + rt * spec_freecam_side;

        spec_freecam_origin = spec_freecam_origin + move_dir * SPEC_FREECAM_SPEED * frametime;

        campos = spec_freecam_origin;
        camang = spec_freecam_angles;
        setproperty(VF_ORIGIN, campos);
        setproperty(VF_ANGLES, camang);
        return;
    }

    // First-person or third-person following a target
    if (spec_target <= 0)
        return;

    target_origin = getentity(spec_target, GE_ORIGINANDVECTORS);
    fwd = v_forward;
    rt = v_right;
    up = v_up;

    // Add eye offset (approximate standing view offset)
    target_origin_z = target_origin_z + 22;

    if (spec_mode == SPEC_MODE_FIRSTPERSON)
    {
        campos = target_origin;
        camang = vectoangles(fwd, up);
        setproperty(VF_ORIGIN, campos);
        setproperty(VF_ANGLES, camang);
    }
    else if (spec_mode == SPEC_MODE_THIRDPERSON)
    {
        cam_offset = fwd * (-SPEC_CAM_BACK) + '0 0 1' * SPEC_CAM_UP;
        cam_pos = target_origin + cam_offset;

        traceline(target_origin, cam_pos, TRUE, world);
        if (trace_fraction < 1)
            cam_pos = trace_endpos + trace_plane_normal * 2;

        campos = cam_pos;
        camang = vectoangles(normalize(target_origin - cam_pos), '0 0 1');
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
    cy = g_height * 0.4;
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
