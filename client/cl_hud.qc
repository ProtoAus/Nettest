// ============================================================
//  client/cl_hud.qc  -  Heads-up display
// ============================================================

void() HUD_DrawScope =
{
    float cx, cy, radius, diameter;
    vector pos, sz;

    cx = g_width * 0.5;
    cy = g_height * 0.5;
    radius = g_height * 0.45;
    diameter = radius * 2;

    // Black bars: left
    pos = '0 0 0';
    sz_x = cx - radius; sz_y = g_height; sz_z = 0;
    drawfill(pos, sz, '0 0 0', 1, 0);

    // Black bars: right
    pos_x = cx + radius; pos_y = 0; pos_z = 0;
    sz_x = g_width - (cx + radius); sz_y = g_height; sz_z = 0;
    drawfill(pos, sz, '0 0 0', 1, 0);

    // Black bars: top
    pos_x = cx - radius; pos_y = 0; pos_z = 0;
    sz_x = diameter; sz_y = cy - radius; sz_z = 0;
    drawfill(pos, sz, '0 0 0', 1, 0);

    // Black bars: bottom
    pos_x = cx - radius; pos_y = cy + radius; pos_z = 0;
    sz_x = diameter; sz_y = g_height - (cy + radius); sz_z = 0;
    drawfill(pos, sz, '0 0 0', 1, 0);

    // Scope circle graphic
    pos_x = cx - radius; pos_y = cy - radius; pos_z = 0;
    sz_x = diameter; sz_y = diameter; sz_z = 0;
    drawpic(pos, "gfx/scope.png", sz, '1 1 1', 1, 0);
};

string(float wep_id) HUD_WeaponName =
{
    switch (wep_id)
    {
    case WEP_DEAGLE:      return "DEAGLE";
    case WEP_KNIFE:       return "KNIFE";
    case WEP_AK47:        return "AK47";
    case WEP_M4A1:        return "M4A1";
    case WEP_FLAKSHOTGUN: return "SHOTGUN";
    case WEP_PISTOL:      return "PISTOL";
    case WEP_SCOUT:       return "SCOUT";
    case WEP_357:         return ".357";
    case WEP_WRENCH:      return "WRENCH";
    case WEP_M249:        return "M249";
    case WEP_GAUSS:       return "GAUSS";
    case WEP_CROSSBOW:    return "CROSSBOW";
    case WEP_DOD98K:      return "98K";
    case WEP_GRENADELAUNCHER: return "GL";
    case WEP_HLCROWBAR:   return "CROWBAR";
    case WEP_HLSHOTGUN:   return "SHOTGUN";
    case WEP_CSM3:        return "M3";
    case WEP_CSMP5:       return "MP5";
    case WEP_REBAR:       return "REBAR";
    case WEP_CSAWP:       return "AWP";
    case WEP_GLOCK:       return "GLOCK";
    case WEP_G3SG1:       return "G3SG1";
    default:              return "";
    }
};

float HUD_SLOT_WIDTH   = 100;
float HUD_SLOT_HEIGHT  = 22;
float HUD_SLOT_GAP     = 4;
float HUD_SLOT_PADDING = 6;

float HUD_SLOT_FONT    = 12;
float HUD_SLOT_SHADOW  = 1;

void(float slot_num, string label, string name, float is_active, vector pos) HUD_DrawWeaponSlot =
{
    vector bg_color;
    float  bg_alpha;
    vector text_color;
    float  text_alpha;
    string slot_text;
    vector text_pos;
    vector text_size;

    if (is_active)
    {
        bg_color = '0.2 0.35 0.5';
        bg_alpha = 0.85;
        text_color = '1 1 1';
        text_alpha = 1.0;
    }
    else
    {
        bg_color = '0.1 0.12 0.15';
        bg_alpha = 0.6;
        text_color = '0.6 0.6 0.6';
        text_alpha = 0.8;
    }

    drawfill(pos, [HUD_SLOT_WIDTH, HUD_SLOT_HEIGHT], bg_color, bg_alpha, 0);

    if (is_active)
        drawfill([pos_x + HUD_SLOT_WIDTH - 2, pos_y], [2, HUD_SLOT_HEIGHT], '0.4 0.7 1', 1.0, 0);

    slot_text = sprintf("%s %s", label, name);
    text_size = [HUD_SLOT_FONT, HUD_SLOT_FONT];
    text_pos_x = pos_x + HUD_SLOT_PADDING;
    text_pos_y = pos_y + (HUD_SLOT_HEIGHT - HUD_SLOT_FONT) * 0.5;
    text_pos_z = 0;

    // Drop shadow
    drawstring(text_pos + [HUD_SLOT_SHADOW, HUD_SLOT_SHADOW], slot_text, text_size, '0 0 0', text_alpha * 0.5, 0);
    // Main text
    drawstring(text_pos, slot_text, text_size, text_color, text_alpha, 0);
};

void() HUD_DrawWeaponSlots =
{
    float  active;
    float  slot_x, slot_y;
    string name1, name2, name3;

    active = predicted_player.weapon;

    name1 = HUD_WeaponName(predicted_player.slot_primary);
    name2 = HUD_WeaponName(predicted_player.slot_secondary);
    name3 = HUD_WeaponName(predicted_player.slot_melee);

    slot_x = g_width - HUD_SLOT_WIDTH - 12;
    slot_y = g_height * 0.5 - ((HUD_SLOT_HEIGHT * 3 + HUD_SLOT_GAP * 2) * 0.5);

    if (name1 != "")
        HUD_DrawWeaponSlot(1, "1", name1, active == predicted_player.slot_primary, [slot_x, slot_y]);

    if (name2 != "")
        HUD_DrawWeaponSlot(2, "2", name2, active == predicted_player.slot_secondary, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP)]);

    if (name3 != "")
        HUD_DrawWeaponSlot(3, "3", name3, active == predicted_player.slot_melee, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 2]);
};

void() HUD_DrawRoundTimer =
{
    float remaining;
    float minutes;
    float seconds;
    string timer_str;
    vector color;
    float text_width;
    float x, y;
    float phase;

    phase = getstatf(STAT_ROUND_PHASE);

    // During freeze, show freeze countdown on the bottom timer
    if (phase == ROUND_PHASE_FREEZE)
    {
        remaining = getstatf(STAT_FREEZE_TIMELEFT);
        if (remaining <= 0)
            return;
        timer_str = sprintf("%.0f", ceil(remaining));
        color = '1 0.8 0.2';
    }
    else if (phase == ROUND_PHASE_ACTIVE)
    {
        remaining = getstatf(STAT_ROUNDTIMER);
        if (remaining <= 0)
            return;
        minutes = floor(remaining / 60);
        seconds = floor(remaining - minutes * 60);
        timer_str = sprintf("%g:%02g", minutes, seconds);
        color = (remaining <= 30) ? '1 0.2 0.2' : '1 1 1';
    }
    else
        return;  // hide timer during round end / map end phases

    text_width = stringwidth(timer_str, 1, [32, 32]);
    x = g_width * 0.5 - text_width * 0.5;
    y = g_height - 52;
    drawstring([x + HUD_SLOT_SHADOW, y + HUD_SLOT_SHADOW], timer_str, [32, 32], '0 0 0', 0.5, 0);
    drawstring([x, y], timer_str, [32, 32], color, 0.9, 0);
};

void() HUD_DrawCenterMessage =
{
    float phase;
    float winning_team;
    float remaining;
    string main_text = "";
    string sub_text = "";
    vector main_color = '1 1 1';
    vector main_size;
    vector sub_size;
    float main_width, sub_width;
    float cx, cy;

    phase = getstatf(STAT_ROUND_PHASE);
    if (phase != ROUND_PHASE_FREEZE
        && phase != ROUND_PHASE_ROUND_END
        && phase != ROUND_PHASE_MAP_END)
        return;

    main_size = [36, 36];
    sub_size = [18, 18];
    cx = g_width * 0.5;
    cy = g_height * 0.35;

    if (phase == ROUND_PHASE_FREEZE)
    {
        remaining = getstatf(STAT_FREEZE_TIMELEFT);
        main_text = sprintf("%.0f", ceil(remaining));
        main_color = '1 0.8 0.2';
        main_size = [48, 48];

        main_width = stringwidth(main_text, 1, main_size);
        drawstring([cx - main_width * 0.5 + HUD_SLOT_SHADOW, cy + HUD_SLOT_SHADOW], main_text, main_size, '0 0 0', 0.5, 0);
        drawstring([cx - main_width * 0.5, cy], main_text, main_size, main_color, 0.9, 0);
        return;
    }

    remaining = getstatf(STAT_ROUNDTIMER);

    if (phase == ROUND_PHASE_ROUND_END)
    {
        winning_team = getstatf(STAT_WINNING_TEAM);
        if (winning_team == TEAM_BLUE)
        {
            main_text = "BLUE TEAM WINS";
            main_color = '0.45 0.7 1';
        }
        else if (winning_team == TEAM_RED)
        {
            main_text = "RED TEAM WINS";
            main_color = '1 0.42 0.42';
        }
        else
        {
            main_text = "ROUND OVER";
            main_color = '1 1 1';
        }
        sub_text = sprintf("Round restarting in %.0f...", ceil(remaining));
    }
    else if (phase == ROUND_PHASE_MAP_END)
    {
        main_text = "MAP HAS ENDED";
        main_color = '1 1 1';
        sub_text = sprintf("Restarting in %.0f...", ceil(remaining));
    }

    // Draw main text
    main_width = stringwidth(main_text, 1, main_size);
    drawstring([cx - main_width * 0.5 + HUD_SLOT_SHADOW, cy + HUD_SLOT_SHADOW], main_text, main_size, '0 0 0', 0.5, 0);
    drawstring([cx - main_width * 0.5, cy], main_text, main_size, main_color, 0.9, 0);

    // Draw subtext
    sub_width = stringwidth(sub_text, 1, sub_size);
    drawstring([cx - sub_width * 0.5 + HUD_SLOT_SHADOW, cy + 44 + HUD_SLOT_SHADOW], sub_text, sub_size, '0 0 0', 0.4, 0);
    drawstring([cx - sub_width * 0.5, cy + 44], sub_text, sub_size, '0.8 0.8 0.8', 0.85, 0);
};

void() CSQC_DrawWeaponHUD =
{
    string mag_str;
    string hp_str;
    float  x, y;
    float  prev_font;

    if (!predicted_player || !csqc_prediction_valid)
        return;

    {
        float predicted_zoomstage = predicted_player.zoomstage;
        if (predicted_zoomstage > 0)
            HUD_DrawScope();
        HUD_DrawCrosshair(predicted_zoomstage);
    }

    prev_font = drawfont;
    drawfont = hud_font;

    // Health — bottom left
    hp_str = sprintf("%.0f", (float)getstati(STAT_HEALTH));
    drawstring([20 + HUD_SLOT_SHADOW, g_height - 52 + HUD_SLOT_SHADOW], hp_str, [36, 36], '0 0 0', 0.5, 0);
    drawstring([20, g_height - 52], hp_str, [36, 36], '1 1 1', 0.9, 0);

    // Weapon slots — right side, vertically centered
    HUD_DrawWeaponSlots();

    // Round timer — bottom center
    HUD_DrawRoundTimer();

    // Center screen messages (freeze countdown, round end, map end)
    HUD_DrawCenterMessage();

    if (predicted_player.weapon == WEP_NONE)
    {
        drawfont = prev_font;
        return;
    }

    if (predicted_player.weapon == WEP_KNIFE
        || predicted_player.weapon == WEP_WRENCH
        || predicted_player.weapon == WEP_HLCROWBAR)
    {
        drawfont = prev_font;
        return;
    }

    y = g_height - 52;

    if (predicted_player.weapon == WEP_DEAGLE)
        mag_str = sprintf("%g / %g", predicted_player.mag_deagle, predicted_player.ammo_deagle);
    else if (predicted_player.weapon == WEP_AK47)
        mag_str = sprintf("%g / %g", predicted_player.mag_ak47, predicted_player.ammo_ak47);
    else if (predicted_player.weapon == WEP_M4A1)
        mag_str = sprintf("%g / %g", predicted_player.mag_m4a1, predicted_player.ammo_m4a1);
    else if (predicted_player.weapon == WEP_FLAKSHOTGUN)
        mag_str = sprintf("%g", predicted_player.mag_flakshotgun);
    else if (predicted_player.weapon == WEP_PISTOL)
        mag_str = sprintf("%g / %g", predicted_player.mag_pistol, predicted_player.ammo_pistol);
    else if (predicted_player.weapon == WEP_SCOUT)
        mag_str = sprintf("%g / %g", predicted_player.mag_scout, predicted_player.ammo_scout);
    else if (predicted_player.weapon == WEP_357)
        mag_str = sprintf("%g / %g", predicted_player.mag_357, predicted_player.ammo_357);
    else if (predicted_player.weapon == WEP_M249)
        mag_str = sprintf("%g / %g", predicted_player.mag_m249, predicted_player.ammo_m249);
    else if (predicted_player.weapon == WEP_CSAWP)
        mag_str = sprintf("%g / %g", predicted_player.mag_awp, predicted_player.ammo_awp);
    else if (predicted_player.weapon == WEP_DOD98K)
        mag_str = sprintf("%g / %g", predicted_player.mag_98k, predicted_player.ammo_98k);
    else if (predicted_player.weapon == WEP_HLSHOTGUN)
        mag_str = sprintf("%g / %g", predicted_player.mag_shotgun, predicted_player.ammo_shotgun);
    else if (predicted_player.weapon == WEP_CSM3)
        mag_str = sprintf("%g / %g", predicted_player.mag_m3, predicted_player.ammo_m3);
    else if (predicted_player.weapon == WEP_CSMP5)
        mag_str = sprintf("%g / %g", predicted_player.mag_mp5, predicted_player.ammo_mp5);
    else if (predicted_player.weapon == WEP_CROSSBOW)
        mag_str = sprintf("%g / %g", predicted_player.mag_crossbow, predicted_player.ammo_crossbow);
    else if (predicted_player.weapon == WEP_GRENADELAUNCHER)
        mag_str = sprintf("%g", predicted_player.mag_grenadelauncher);
    else if (predicted_player.weapon == WEP_REBAR)
        mag_str = sprintf("%g", predicted_player.mag_rebar);
    else if (predicted_player.weapon == WEP_GAUSS)
        mag_str = sprintf("%g", predicted_player.ammo_gauss);
    else if (predicted_player.weapon == WEP_GLOCK)
        mag_str = sprintf("%g / %g", predicted_player.mag_glock, predicted_player.ammo_glock);
    else if (predicted_player.weapon == WEP_G3SG1)
        mag_str = sprintf("%g / %g", predicted_player.mag_g3sg1, predicted_player.ammo_g3sg1);
    else
        return;

    x = g_width - 20 - stringwidth(mag_str, 1, [32, 32]);
    drawstring([x + HUD_SLOT_SHADOW, y + HUD_SLOT_SHADOW], mag_str, [32, 32], '0 0 0', 0.5, 0);
    drawstring([x, y], mag_str, [32, 32], '1 1 1', 0.9, 0);

    drawfont = prev_font;
};
