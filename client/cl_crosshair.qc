float hud_crosshair_cvars_registered;
float hud_crosshair_gap_bonus_smoothed;

float HUD_CROSSHAIR_DEFAULT_LENGTH = 6;
float HUD_CROSSHAIR_DEFAULT_THICKNESS = 1;
float HUD_CROSSHAIR_DEFAULT_GAP = 3;
float HUD_CROSSHAIR_BASE_SPREAD_TO_GAP_SCALE = 120;
float HUD_CROSSHAIR_MOVE_SPREAD_TO_GAP_SCALE = 360;
float HUD_CROSSHAIR_GAP_LERP_SPEED = 14;

void() HUD_EnsureCrosshairCVars =
{
    if (hud_crosshair_cvars_registered)
        return;

    registercvar("cl_crosshairlength", "6");
    registercvar("cl_crosshairthickness", "1");
    registercvar("cl_crosshairgap", "3");
    registercvar("cl_crosshaircolour", "0 1 0");
    hud_crosshair_cvars_registered = TRUE;
};

vector() HUD_GetCrosshairColour =
{
    vector colour;
    string colour_text;
    float token_count;
    float max_component;

    colour = '0 1 0';
    colour_text = cvar_string("cl_crosshaircolour");
    token_count = tokenize(colour_text);

    if (token_count >= 3)
    {
        colour_x = stof(argv(0));
        colour_y = stof(argv(1));
        colour_z = stof(argv(2));
    }
    else if (token_count == 1)
    {
        colour_x = stof(argv(0));
        colour_y = colour_x;
        colour_z = colour_x;
    }

    max_component = max(colour_x, max(colour_y, colour_z));
    if (max_component > 1)
    {
        colour_x = colour_x / 255;
        colour_y = colour_y / 255;
        colour_z = colour_z / 255;
    }

    colour_x = bound(0, colour_x, 1);
    colour_y = bound(0, colour_y, 1);
    colour_z = bound(0, colour_z, 1);
    return colour;
};

// Returns the predicted player's horizontal speed this render frame.
// Uses predicted_player.velocity directly so the crosshair responds to
// movement instantly, regardless of server round-trip time.
float() CSQC_GetPredictedCrosshairMoveSpeed =
{
    vector flat_vel;

    if (!predicted_player || !csqc_prediction_valid)
        return 0;

    flat_vel   = predicted_player.velocity;
    flat_vel_z = 0;
    return vlen(flat_vel);
};

// Returns a multiplier on all spread values based on player stance.
// Matches SH_GetSpreadScale() so the crosshair reflects actual accuracy.
float() CSQC_GetPredictedCrosshairSpreadScale =
{
    entity old_self;
    float s;

    if (!predicted_player)
        return 1;

    // Fixed-spread weapons (shotguns) have move_spread = 0 — no stance modifiers
    if (getstatf(STAT_CROSSHAIR_MOVESPREAD) == 0)
    {
        sh_spread_flat = 0;
        return 1;
    }

    old_self = self;
    self = predicted_player;
    s = SH_GetSpreadScale();
    self = old_self;
    return s;
};

float() HUD_GetCrosshairGapBonus =
{
    float base_spread;
    float move_spread;
    float full_speed;
    float gap_scale;
    float spread_scale;
    float move_speed;
    float move_ratio;
    float gap_bonus;

    base_spread = getstatf(STAT_CROSSHAIR_BASESPREAD);
    move_spread = getstatf(STAT_CROSSHAIR_MOVESPREAD);
    full_speed = getstatf(STAT_CROSSHAIR_FULLSPEED);
    gap_scale = getstatf(STAT_CROSSHAIR_GAPSCALE);
    move_speed = CSQC_GetPredictedCrosshairMoveSpeed();
    spread_scale = CSQC_GetPredictedCrosshairSpreadScale();

    if (gap_scale <= 0)
        return 0;

    if (spread_scale <= 0)
        spread_scale = 1;

    base_spread = base_spread * spread_scale;
    move_spread = move_spread * spread_scale;

    gap_bonus = base_spread * HUD_CROSSHAIR_BASE_SPREAD_TO_GAP_SCALE;

    if (move_spread > 0 && full_speed > 0)
    {
        move_ratio = move_speed / full_speed;
        move_ratio = bound(0, move_ratio, 1);
        gap_bonus = gap_bonus + (move_spread * move_ratio * HUD_CROSSHAIR_MOVE_SPREAD_TO_GAP_SCALE);
    }

    // Flat spread bonus from jump/landing — convert to gap pixels
    gap_bonus += sh_spread_flat * HUD_CROSSHAIR_BASE_SPREAD_TO_GAP_SCALE;

    return gap_bonus * gap_scale;
};

void(float zoomstage) HUD_DrawCrosshair =
{
    float scoped_weapon;
    float cx;
    float cy;
    float length;
    float thickness;
    float gap;
    float length_setting;
    float thickness_setting;
    float gap_setting;
    float target_gap_bonus;
    float gap_blend;
    string length_text;
    string thickness_text;
    string gap_text;
    vector pos;
    vector sz;
    vector colour;

    // Drive visibility off the predicted weapon rather than the networked
    // STAT_CROSSHAIR_DISABLED stat — weapon switches are client-predicted,
    // so this flips instantly on a switch regardless of ping.  The stat
    // still arrives from the server but we intentionally ignore it here.
    float wep = predicted_player ? predicted_player.weapon : WEP_NONE;
    scoped_weapon = !Weapon_HasCrosshair(wep);

    if (zoomstage > 0 || scoped_weapon)
    {
        hud_crosshair_gap_bonus_smoothed = 0;
        return;
    }

    HUD_EnsureCrosshairCVars();

    length_text = cvar_string("cl_crosshairlength");
    thickness_text = cvar_string("cl_crosshairthickness");
    gap_text = cvar_string("cl_crosshairgap");
    length_setting = cvar("cl_crosshairlength");
    thickness_setting = cvar("cl_crosshairthickness");
    gap_setting = cvar("cl_crosshairgap");
    colour = HUD_GetCrosshairColour();

    if (length_text == "" || length_setting <= 0)
        length = HUD_CROSSHAIR_DEFAULT_LENGTH;
    else
        length = length_setting;

    if (thickness_text == "" || thickness_setting <= 0)
        thickness_setting = HUD_CROSSHAIR_DEFAULT_THICKNESS;

    if (gap_text == "")
        gap = HUD_CROSSHAIR_DEFAULT_GAP;
    else if (gap_setting < 0)
        gap = 0;
    else
        gap = gap_setting;

    target_gap_bonus = HUD_GetCrosshairGapBonus();
    gap_blend = frametime * HUD_CROSSHAIR_GAP_LERP_SPEED;
    gap_blend = bound(0, gap_blend, 1);
    hud_crosshair_gap_bonus_smoothed = hud_crosshair_gap_bonus_smoothed + ((target_gap_bonus - hud_crosshair_gap_bonus_smoothed) * gap_blend);

    length = bound(1, length, 64);
    thickness = bound(0.5, thickness_setting * 0.5, 8);
    gap = bound(0, gap + hud_crosshair_gap_bonus_smoothed, 64);

    cx = g_width * 0.5;
    cy = g_height * 0.5;

    pos_x = cx - (thickness * 0.5);
    pos_y = cy - gap - length;
    pos_z = 0;
    sz_x = thickness;
    sz_y = length;
    sz_z = 0;
    drawfill(pos, sz, colour, 1, 0);

    pos_x = cx - (thickness * 0.5);
    pos_y = cy + gap;
    pos_z = 0;
    sz_x = thickness;
    sz_y = length;
    sz_z = 0;
    drawfill(pos, sz, colour, 1, 0);

    pos_x = cx - gap - length;
    pos_y = cy - (thickness * 0.5);
    pos_z = 0;
    sz_x = length;
    sz_y = thickness;
    sz_z = 0;
    drawfill(pos, sz, colour, 1, 0);

    pos_x = cx + gap;
    pos_y = cy - (thickness * 0.5);
    pos_z = 0;
    sz_x = length;
    sz_y = thickness;
    sz_z = 0;
    drawfill(pos, sz, colour, 1, 0);
};
