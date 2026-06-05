float hud_crosshair_cvars_registered;
float hud_crosshair_gap_bonus_smoothed;

// Per-frame crosshair cvar cache. Populated by HUD_RefreshCrosshairCache
// (defined below, after HUD_GetCrosshairColour) once at the top of
// CSQC_UpdateViewAliveHud so HUD_DrawCrosshair doesn't pay 7 cvar
// reads + 1 cvar_string + tokenize() per frame. Values change rarely
// (user opens menu, tweaks a slider). The smoothing/spread math
// inside HUD_DrawCrosshair still runs every frame because it depends
// on per-frame stat values.
string hud_xhair_cache_length_text;
string hud_xhair_cache_thickness_text;
string hud_xhair_cache_gap_text;
float  hud_xhair_cache_length_setting;
float  hud_xhair_cache_thickness_setting;
float  hud_xhair_cache_gap_setting;
vector hud_xhair_cache_colour;

float HUD_CROSSHAIR_DEFAULT_LENGTH = 6;
float HUD_CROSSHAIR_DEFAULT_THICKNESS = 1;
float HUD_CROSSHAIR_DEFAULT_GAP = 3;
float HUD_CROSSHAIR_BASE_SPREAD_TO_GAP_SCALE = 120;
float HUD_CROSSHAIR_MOVE_SPREAD_TO_GAP_SCALE = 360;
float HUD_CROSSHAIR_GAP_LERP_SPEED = 14;

// Crosshair cvars are now registered from the shared table in
// shared/sh_cvar_table.qc CVar_Init(). This stub is kept so the
// existing call site (line ~216) doesn't need an update.
void() HUD_EnsureCrosshairCVars =
{
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

void() HUD_RefreshCrosshairCache =
{
    hud_xhair_cache_length_text     = cvar_string("cl_crosshairlength");
    hud_xhair_cache_thickness_text  = cvar_string("cl_crosshairthickness");
    hud_xhair_cache_gap_text        = cvar_string("cl_crosshairgap");
    hud_xhair_cache_length_setting  = cvar("cl_crosshairlength");
    hud_xhair_cache_thickness_setting = cvar("cl_crosshairthickness");
    hud_xhair_cache_gap_setting     = cvar("cl_crosshairgap");
    hud_xhair_cache_colour          = HUD_GetCrosshairColour();
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

    // cl_crosshairweapongap 0  → strip the per-weapon baseline (skip
    //                             base_spread contribution + force
    //                             gap_scale=1 so the final multiplier
    //                             is weapon-neutral).
    // cl_crosshairdynamic   0  → skip ALL live-accuracy influence:
    //                             movement, jump/landing (sh_spread_flat),
    //                             AND the fire/jump portion of
    //                             spread_scale that previously leaked
    //                             through the weapon baseline.
    // Both off → gap_bonus = 0 (caller uses cl_crosshairgap unchanged).
    float want_weapon_gap = cvar("cl_crosshairweapongap");
    float want_dynamic    = cvar("cl_crosshairdynamic");

    if (!want_weapon_gap)
        gap_scale = 1;

    // When dynamic is off, don't let spread_scale (which includes jump
    // and sustained-fire penalties) inflate the weapon baseline. Pin it
    // to 1 so base_spread stays at its static per-weapon value and
    // sh_spread_flat is ignored below.
    if (!want_dynamic)
    {
        spread_scale = 1;
        sh_spread_flat = 0;
    }

    base_spread = base_spread * spread_scale;
    move_spread = move_spread * spread_scale;

    gap_bonus = 0;
    if (want_weapon_gap)
        gap_bonus = base_spread * HUD_CROSSHAIR_BASE_SPREAD_TO_GAP_SCALE;

    if (want_dynamic)
    {
        if (move_spread > 0 && full_speed > 0)
        {
            move_ratio = move_speed / full_speed;
            move_ratio = bound(0, move_ratio, 1);
            gap_bonus = gap_bonus + (move_spread * move_ratio * HUD_CROSSHAIR_MOVE_SPREAD_TO_GAP_SCALE);
        }

        // Flat spread bonus from jump/landing — convert to gap pixels
        gap_bonus += sh_spread_flat * HUD_CROSSHAIR_BASE_SPREAD_TO_GAP_SCALE;
    }

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

    // cl_crosshair 0 hides the entire crosshair.  sv_crosshair 0 (server
    // gate, default 1) also hides it — legacy/unset servers default to 1
    // so existing clients keep their crosshair.  Keep the smoothed gap
    // reset above active so a previous-tick dynamic-spread state doesn't
    // bleed back in when re-enabled.
    if (!cvar("cl_crosshair") || serverkeyfloat("sv_crosshair", 1) <= 0)
    {
        hud_crosshair_gap_bonus_smoothed = 0;
        return;
    }

    // ADS fade — crosshair fades out as the gun rises to the iron-sights
    // pose (cl_viewfx.qc's ADS envelope rides 0→1 with the same ease as
    // the pose itself).  Snaps back in when ADS releases or sprint
    // cancels it.  Skips the entire draw once fully faded so we don't
    // pay for four no-op drawfills.
    float xhair_alpha = 1.0 - csqc_viewfx_ads_env;
    if (xhair_alpha <= 0)
        return;

    HUD_EnsureCrosshairCVars();

    // Per-frame cvar cache populated once at top of UpdateViewAliveHud.
    length_text       = hud_xhair_cache_length_text;
    thickness_text    = hud_xhair_cache_thickness_text;
    gap_text          = hud_xhair_cache_gap_text;
    length_setting    = hud_xhair_cache_length_setting;
    thickness_setting = hud_xhair_cache_thickness_setting;
    gap_setting       = hud_xhair_cache_gap_setting;
    colour            = hud_xhair_cache_colour;

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
    drawfill(pos, sz, colour, xhair_alpha, 0);

    pos_x = cx - (thickness * 0.5);
    pos_y = cy + gap;
    pos_z = 0;
    sz_x = thickness;
    sz_y = length;
    sz_z = 0;
    drawfill(pos, sz, colour, xhair_alpha, 0);

    pos_x = cx - gap - length;
    pos_y = cy - (thickness * 0.5);
    pos_z = 0;
    sz_x = length;
    sz_y = thickness;
    sz_z = 0;
    drawfill(pos, sz, colour, xhair_alpha, 0);

    pos_x = cx + gap;
    pos_y = cy - (thickness * 0.5);
    pos_z = 0;
    sz_x = length;
    sz_y = thickness;
    sz_z = 0;
    drawfill(pos, sz, colour, xhair_alpha, 0);
};
