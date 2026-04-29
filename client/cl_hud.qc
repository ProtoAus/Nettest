// ============================================================
//  client/cl_hud.qc  -  Heads-up display
// ============================================================

// --- Pain flash ---
float csqc_pain_flash_time;
float csqc_pain_flash_alpha;
const float PAIN_FLASH_DURATION = 0.4;

// --- Death-screen damage report (cl_playerdamage panel) ---
//
// Filled by the CSQC_EVENT_DAMAGE_REPORT handler in cl_main.qc when the
// local player dies; consumed by HUD_DrawDamageReport.  Same parallel-
// array shape as the killfeed.  Slot is 1-based on the wire to match
// edict-num convention; the helpers subtract 1 for getplayerkeyvalue.
const float DR_HUD_CAP        = 16;
const float DR_HUD_DURATION   = 7.0;     // total seconds visible
const float DR_HUD_FADE_TAIL  = 1.0;     // last second fades alpha to 0

float dr_show_until;

float dr_g_count;
float dr_g_slot [DR_HUD_CAP];
float dr_g_dmg  [DR_HUD_CAP];
float dr_g_hits [DR_HUD_CAP];
float dr_g_hp   [DR_HUD_CAP];

float dr_t_count;
float dr_t_slot [DR_HUD_CAP];
float dr_t_dmg  [DR_HUD_CAP];
float dr_t_hits [DR_HUD_CAP];
float dr_t_hp   [DR_HUD_CAP];

// Helper — returns the name to display for a 1-based player slot.
// Mirrors KillFeed_PlayerName so unknown/disconnected slots still
// render as "player" rather than blank.
string DR_PlayerName(float slot1)
{
    if (slot1 <= 0) return "player";
    string n = getplayerkeyvalue(slot1 - 1, INFOKEY_P_NAME);
    if (n == "") n = "player";
    return n;
}

// Team tint for a 1-based slot. Returns a neutral colour when the
// active gamemode isn't team-based (Bhop / FFA), so the panel doesn't
// fake teams the user can't see anywhere else in the HUD.
vector DR_PlayerColour(float slot1)
{
    float gm = getstatf(STAT_GAMEMODE);
    if (gm != GAMEMODE_TDM && gm != GAMEMODE_ELIMINATION)
        return '0.85 0.85 0.85';
    if (slot1 <= 0)
        return '0.85 0.85 0.85';

    string team_value = getplayerkeyvalue(slot1 - 1, "modteam");
    float team_id = (team_value != "") ? stof(team_value) : TEAM_NONE;
    if (team_id == TEAM_BLUE) return '0.45 0.7 1';
    if (team_id == TEAM_RED)  return '1 0.42 0.42';
    return '0.85 0.85 0.85';
}

// --- Hitmarker X ---
float csqc_hitmarker_time;
const float HITMARKER_DURATION = 0.25;
const float HITMARKER_GAP = 6;     // gap from center
const float HITMARKER_LENGTH = 4;  // line length beyond the gap
const float HITMARKER_WIDTH = 2;   // line thickness

void() HUD_TriggerHitmarker =
{
    csqc_hitmarker_time = cltime;
};

void() HUD_DrawHitmarker =
{
    float age, alpha;
    float cx, cy;
    float g, l;

    if (!cvar("cl_hitmarker"))
        return;

    if (csqc_hitmarker_time <= 0)
        return;

    age = cltime - csqc_hitmarker_time;
    if (age >= HITMARKER_DURATION)
    {
        csqc_hitmarker_time = 0;
        return;
    }

    alpha = 1.0 - (age / HITMARKER_DURATION);
    cx = g_width * 0.5;
    cy = g_height * 0.5;
    g = HITMARKER_GAP;
    l = HITMARKER_LENGTH;

    // Four true diagonal lines forming an X with a gap in the center
    // Draw multiple offset lines to simulate thickness
    float i;
    for (i = 0; i < HITMARKER_WIDTH; i++)
    {
        float ofs = i - (HITMARKER_WIDTH - 1) * 0.5;
        // Top-left
        drawline(1, [cx - g - l + ofs, cy - g - l, 0], [cx - g + ofs, cy - g, 0], '1 1 1', alpha);
        drawline(1, [cx - g - l, cy - g - l + ofs, 0], [cx - g, cy - g + ofs, 0], '1 1 1', alpha);
        // Top-right
        drawline(1, [cx + g + l + ofs, cy - g - l, 0], [cx + g + ofs, cy - g, 0], '1 1 1', alpha);
        drawline(1, [cx + g + l, cy - g - l + ofs, 0], [cx + g, cy - g + ofs, 0], '1 1 1', alpha);
        // Bottom-left
        drawline(1, [cx - g - l + ofs, cy + g + l, 0], [cx - g + ofs, cy + g, 0], '1 1 1', alpha);
        drawline(1, [cx - g - l, cy + g + l + ofs, 0], [cx - g, cy + g + ofs, 0], '1 1 1', alpha);
        // Bottom-right
        drawline(1, [cx + g + l + ofs, cy + g + l, 0], [cx + g + ofs, cy + g, 0], '1 1 1', alpha);
        drawline(1, [cx + g + l, cy + g + l + ofs, 0], [cx + g, cy + g + ofs, 0], '1 1 1', alpha);
    }
};

// CSQC-native vignette — four edge strips with descending alpha towards
// screen centre.  Each edge is split into three bands so the falloff
// reads as a gradient instead of a hard stripe.  Independent of any
// GLSL / shader-script pipeline (the earlier post-process path was
// unreliable on this engine build).
void() HUD_DrawPainFlash =
{
    float age, intensity;
    float band_count = 3;
    float band_size;
    float i;
    float band_alpha;
    vector red = '0.85 0.05 0.05';

    if (csqc_pain_flash_time <= 0)
        return;

    age = cltime - csqc_pain_flash_time;
    if (age >= PAIN_FLASH_DURATION)
    {
        csqc_pain_flash_time = 0;
        return;
    }

    intensity = csqc_pain_flash_alpha * (1 - age / PAIN_FLASH_DURATION);

    // Edges take up to 15% of each axis; three bands of 5% each.
    band_size = min(g_width, g_height) * 0.05;

    for (i = 0; i < band_count; i = i + 1)
    {
        // Outermost band is most opaque; each inner band half as much.
        band_alpha = intensity * pow(0.5, i);
        float ofs = i * band_size;
        // Top / bottom strips span the full screen width at this offset.
        drawfill([0,               ofs],              [g_width, band_size], red, band_alpha, 0);
        drawfill([0, g_height - ofs - band_size],    [g_width, band_size], red, band_alpha, 0);
        // Left / right strips fit BETWEEN the top/bottom strips so corners
        // don't get double-alpha compositing.
        drawfill([ofs,               ofs + band_size],            [band_size, g_height - (ofs + band_size) * 2], red, band_alpha, 0);
        drawfill([g_width - ofs - band_size, ofs + band_size],   [band_size, g_height - (ofs + band_size) * 2], red, band_alpha, 0);
    }
};

// ============================================================
//  HUD_DrawDamageReport — death-screen Given/Taken panel
//
//  Filled by CSQC_EVENT_DAMAGE_REPORT.  Visible for DR_HUD_DURATION
//  seconds, fading over the last DR_HUD_FADE_TAIL seconds.  Gated by
//  cl_playerdamage so admins/players can hide it.
//
//  Each line: "<dmg> in <hits> [<name> - <hp>hp]" with the name
//  team-tinted in TDM/Elimination, neutral grey in Bhop / FFA.  Low-HP
//  opponents (<= 30) get a reddish HP suffix so it's obvious you nearly
//  killed them.
// ============================================================
void() HUD_DrawDamageReport =
{
    if (dr_show_until <= 0)
        return;
    if (cltime >= dr_show_until)
    {
        dr_show_until = 0;
        dr_g_count = 0;
        dr_t_count = 0;
        return;
    }
    if (!cvar("cl_playerdamage"))
        return;
    if (dr_g_count <= 0 && dr_t_count <= 0)
        return;

    float remaining = dr_show_until - cltime;
    float alpha = (remaining < DR_HUD_FADE_TAIL) ? (remaining / DR_HUD_FADE_TAIL) : 1.0;

    // Smallest native size in GoogleMed's load list (cl_main.qc CSQC_Init:
    //   "8 12 16 18 24 32 36 48 60 72").  Using a non-native size forces
    //   the engine to scale the bitmap font and the result looks blurry.
    float prev_font = drawfont;
    drawfont = hud_font_mono;

    vector header_size = '8 8 0';
    vector line_size   = '8 8 0';
    vector colour_white = '1 1 1';
    vector colour_dim   = '0.65 0.65 0.65';
    vector colour_low   = '1 0.55 0.55';   // dim red, used for HP <= 30

    float x = 20;
    float y = g_height * 0.35;
    float i;
    string txt;
    float w;

    // ---- Given ----
    if (dr_g_count > 0)
    {
        drawstring([x, y], "Given:", header_size, colour_white, alpha, 0);
        y = y + header_size_y + 2;
        for (i = 0; i < dr_g_count; i = i + 1)
        {
            float cx = x;

            // damage number
            txt = sprintf("%g", dr_g_dmg[i]);
            drawstring([cx, y], txt, line_size, colour_white, alpha, 0);
            cx = cx + stringwidth(txt, 0, line_size);

            // " in N "
            txt = sprintf(" in %g ", dr_g_hits[i]);
            drawstring([cx, y], txt, line_size, colour_dim, alpha, 0);
            cx = cx + stringwidth(txt, 0, line_size);

            // "["
            drawstring([cx, y], "[", line_size, colour_dim, alpha, 0);
            cx = cx + stringwidth("[", 0, line_size);

            // name (team-tinted)
            string name = DR_PlayerName(dr_g_slot[i]);
            vector ncol = DR_PlayerColour(dr_g_slot[i]);
            drawstring([cx, y], name, line_size, ncol, alpha, 0);
            cx = cx + stringwidth(name, 0, line_size);

            // " - Xhp]"
            vector hp_col = (dr_g_hp[i] <= 30) ? colour_low : colour_dim;
            txt = sprintf(" - %ghp]", dr_g_hp[i]);
            drawstring([cx, y], txt, line_size, hp_col, alpha, 0);

            y = y + line_size_y + 2;
        }
        y = y + 6;   // gap before Taken header
    }

    // ---- Taken ----
    if (dr_t_count > 0)
    {
        drawstring([x, y], "Taken:", header_size, colour_white, alpha, 0);
        y = y + header_size_y + 2;
        for (i = 0; i < dr_t_count; i = i + 1)
        {
            float cx = x;

            txt = sprintf("%g", dr_t_dmg[i]);
            drawstring([cx, y], txt, line_size, colour_white, alpha, 0);
            cx = cx + stringwidth(txt, 0, line_size);

            txt = sprintf(" in %g ", dr_t_hits[i]);
            drawstring([cx, y], txt, line_size, colour_dim, alpha, 0);
            cx = cx + stringwidth(txt, 0, line_size);

            drawstring([cx, y], "[", line_size, colour_dim, alpha, 0);
            cx = cx + stringwidth("[", 0, line_size);

            string name = DR_PlayerName(dr_t_slot[i]);
            vector ncol = DR_PlayerColour(dr_t_slot[i]);
            drawstring([cx, y], name, line_size, ncol, alpha, 0);
            cx = cx + stringwidth(name, 0, line_size);

            vector hp_col = (dr_t_hp[i] <= 30) ? colour_low : colour_dim;
            txt = sprintf(" - %ghp]", dr_t_hp[i]);
            drawstring([cx, y], txt, line_size, hp_col, alpha, 0);

            y = y + line_size_y + 2;
        }
    }

    drawfont = prev_font;
};

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
    case WEP_HLSMG:       return "SMG";
    case WEP_HLRPG:       return "RPG";
    case WEP_HLGRENADE:   return "GRENADE";
    case WEP_HLGLOCK:     return "HL GLOCK";
    case WEP_HLEGON:      return "EGON";
    case WEP_CSUSP:       return "USP-45";
    default:              return "";
    }
};

float HUD_SLOT_WIDTH   = 100;
float HUD_SLOT_HEIGHT  = 22;
float HUD_SLOT_GAP     = 4;
float HUD_SLOT_PADDING = 6;

float HUD_SLOT_FONT    = 12;
float HUD_SLOT_SHADOW  = 1;
float HUD_SLOT_FULL_HOLD = 1.25;

float  hud_slot_cache_valid;
float  hud_slot_cache_primary;
float  hud_slot_cache_secondary;
float  hud_slot_cache_melee;
float  hud_slot_cache_utility;
string hud_slot_cache_text1;
string hud_slot_cache_text2;
string hud_slot_cache_text3;
string hud_slot_cache_text4;
float  hud_slot_cache_active;
float  hud_slot_full_until;

float  hud_health_cache_valid;
float  hud_health_cache_value;
string hud_health_cache_text;

float  hud_ammo_cache_valid;
float  hud_ammo_cache_weapon;
float  hud_ammo_cache_format;
float  hud_ammo_cache_a;
float  hud_ammo_cache_b;
string hud_ammo_cache_text;
float  hud_ammo_cache_width;

float  hud_hlsmg_gren_cache_valid;
float  hud_hlsmg_gren_cache_value;
string hud_hlsmg_gren_cache_text;
float  hud_hlsmg_gren_cache_width;

string(float slot_num, float weapon_id) HUD_BuildWeaponSlotText =
{
    string name;

    name = HUD_WeaponName(weapon_id);
    if (name == "")
        return "";

    return sprintf("%g %s", slot_num, name);
};

void() HUD_UpdateWeaponSlotCache =
{
    float changed;

    if (hud_slot_cache_valid
        && hud_slot_cache_primary == predicted_player.slot_primary
        && hud_slot_cache_secondary == predicted_player.slot_secondary
        && hud_slot_cache_melee == predicted_player.slot_melee
        && hud_slot_cache_utility == predicted_player.slot_utility
        && hud_slot_cache_active == predicted_player.weapon)
        return;

    changed = hud_slot_cache_valid;
    hud_slot_cache_valid = TRUE;
    hud_slot_cache_primary = predicted_player.slot_primary;
    hud_slot_cache_secondary = predicted_player.slot_secondary;
    hud_slot_cache_melee = predicted_player.slot_melee;
    hud_slot_cache_utility = predicted_player.slot_utility;
    hud_slot_cache_active = predicted_player.weapon;

    hud_slot_cache_text1 = HUD_BuildWeaponSlotText(1, hud_slot_cache_primary);
    hud_slot_cache_text2 = HUD_BuildWeaponSlotText(2, hud_slot_cache_secondary);
    hud_slot_cache_text3 = HUD_BuildWeaponSlotText(3, hud_slot_cache_melee);
    hud_slot_cache_text4 = HUD_BuildWeaponSlotText(4, hud_slot_cache_utility);

    if (changed)
        hud_slot_full_until = cltime + HUD_SLOT_FULL_HOLD;
    else
        hud_slot_full_until = cltime + 0.25;
};

string() HUD_GetHealthString =
{
    float hp;

    hp = (float)getstati(STAT_HEALTH);
    if (!hud_health_cache_valid || hud_health_cache_value != hp)
    {
        hud_health_cache_valid = TRUE;
        hud_health_cache_value = hp;
        hud_health_cache_text = sprintf("%.0f", hp);
    }

    return hud_health_cache_text;
};

string(float weapon_id, float format_id, float value_a, float value_b) HUD_CacheAmmoString =
{
    if (!hud_ammo_cache_valid
        || hud_ammo_cache_weapon != weapon_id
        || hud_ammo_cache_format != format_id
        || hud_ammo_cache_a != value_a
        || hud_ammo_cache_b != value_b)
    {
        hud_ammo_cache_valid = TRUE;
        hud_ammo_cache_weapon = weapon_id;
        hud_ammo_cache_format = format_id;
        hud_ammo_cache_a = value_a;
        hud_ammo_cache_b = value_b;

        if (format_id == 1)
            hud_ammo_cache_text = sprintf("%g / %g", value_a, value_b);
        else
            hud_ammo_cache_text = sprintf("%g", value_a);

        hud_ammo_cache_width = stringwidth(hud_ammo_cache_text, 1, [32, 32]);
    }

    return hud_ammo_cache_text;
};

string() HUD_GetAmmoString =
{
    if (predicted_player.weapon == WEP_DEAGLE)
        return HUD_CacheAmmoString(WEP_DEAGLE, 1, predicted_player.mag_deagle, predicted_player.ammo_deagle);
    else if (predicted_player.weapon == WEP_AK47)
        return HUD_CacheAmmoString(WEP_AK47, 1, predicted_player.mag_ak47, predicted_player.ammo_ak47);
    else if (predicted_player.weapon == WEP_M4A1)
        return HUD_CacheAmmoString(WEP_M4A1, 1, predicted_player.mag_m4a1, predicted_player.ammo_m4a1);
    else if (predicted_player.weapon == WEP_FLAKSHOTGUN)
        return HUD_CacheAmmoString(WEP_FLAKSHOTGUN, 2, predicted_player.mag_flakshotgun, 0);
    else if (predicted_player.weapon == WEP_PISTOL)
        return HUD_CacheAmmoString(WEP_PISTOL, 1, predicted_player.mag_pistol, predicted_player.ammo_pistol);
    else if (predicted_player.weapon == WEP_SCOUT)
        return HUD_CacheAmmoString(WEP_SCOUT, 1, predicted_player.mag_scout, predicted_player.ammo_scout);
    else if (predicted_player.weapon == WEP_357)
        return HUD_CacheAmmoString(WEP_357, 1, predicted_player.mag_357, predicted_player.ammo_357);
    else if (predicted_player.weapon == WEP_M249)
        return HUD_CacheAmmoString(WEP_M249, 1, predicted_player.mag_m249, predicted_player.ammo_m249);
    else if (predicted_player.weapon == WEP_CSAWP)
        return HUD_CacheAmmoString(WEP_CSAWP, 1, predicted_player.mag_awp, predicted_player.ammo_awp);
    else if (predicted_player.weapon == WEP_DOD98K)
        return HUD_CacheAmmoString(WEP_DOD98K, 1, predicted_player.mag_98k, predicted_player.ammo_98k);
    else if (predicted_player.weapon == WEP_HLSHOTGUN)
        return HUD_CacheAmmoString(WEP_HLSHOTGUN, 1, predicted_player.mag_shotgun, predicted_player.ammo_shotgun);
    else if (predicted_player.weapon == WEP_CSM3)
        return HUD_CacheAmmoString(WEP_CSM3, 1, predicted_player.mag_m3, predicted_player.ammo_m3);
    else if (predicted_player.weapon == WEP_CSMP5)
        return HUD_CacheAmmoString(WEP_CSMP5, 1, predicted_player.mag_mp5, predicted_player.ammo_mp5);
    else if (predicted_player.weapon == WEP_CROSSBOW)
        return HUD_CacheAmmoString(WEP_CROSSBOW, 1, predicted_player.mag_crossbow, predicted_player.ammo_crossbow);
    else if (predicted_player.weapon == WEP_GRENADELAUNCHER)
        return HUD_CacheAmmoString(WEP_GRENADELAUNCHER, 2, predicted_player.mag_grenadelauncher, 0);
    else if (predicted_player.weapon == WEP_REBAR)
        return HUD_CacheAmmoString(WEP_REBAR, 2, predicted_player.mag_rebar, 0);
    else if (predicted_player.weapon == WEP_GAUSS)
        return HUD_CacheAmmoString(WEP_GAUSS, 2, predicted_player.ammo_gauss, 0);
    else if (predicted_player.weapon == WEP_GLOCK)
        return HUD_CacheAmmoString(WEP_GLOCK, 1, predicted_player.mag_glock, predicted_player.ammo_glock);
    else if (predicted_player.weapon == WEP_G3SG1)
        return HUD_CacheAmmoString(WEP_G3SG1, 1, predicted_player.mag_g3sg1, predicted_player.ammo_g3sg1);
    else if (predicted_player.weapon == WEP_HLSMG)
        return HUD_CacheAmmoString(WEP_HLSMG, 1, predicted_player.mag_hlsmg, predicted_player.ammo_hlsmg);
    else if (predicted_player.weapon == WEP_HLRPG)
        return HUD_CacheAmmoString(WEP_HLRPG, 1, predicted_player.mag_hlrpg, predicted_player.ammo_hlrpg);
    else if (predicted_player.weapon == WEP_HLGRENADE)
        return HUD_CacheAmmoString(WEP_HLGRENADE, 2, predicted_player.ammo_hlgrenade, 0);
    else if (predicted_player.weapon == WEP_HLGLOCK)
        return HUD_CacheAmmoString(WEP_HLGLOCK, 1, predicted_player.mag_hlglock, predicted_player.ammo_hlglock);
    else if (predicted_player.weapon == WEP_HLEGON)
        return HUD_CacheAmmoString(WEP_HLEGON, 2, predicted_player.ammo_hlegon, 0);
    else if (predicted_player.weapon == WEP_CSUSP)
        return HUD_CacheAmmoString(WEP_CSUSP, 1, predicted_player.mag_csusp, predicted_player.ammo_csusp);

    return "";
};

string() HUD_GetHLSMGGrenadeString =
{
    if (!hud_hlsmg_gren_cache_valid
        || hud_hlsmg_gren_cache_value != predicted_player.ammo_hlsmg_grenades)
    {
        hud_hlsmg_gren_cache_valid = TRUE;
        hud_hlsmg_gren_cache_value = predicted_player.ammo_hlsmg_grenades;
        hud_hlsmg_gren_cache_text = sprintf("Grenade Launcher: %g", predicted_player.ammo_hlsmg_grenades);
        hud_hlsmg_gren_cache_width = stringwidth(hud_hlsmg_gren_cache_text, 1, [16, 16]);
    }

    return hud_hlsmg_gren_cache_text;
};

void(string slot_text, float is_active, vector pos) HUD_DrawWeaponSlot =
{
    vector bg_color;
    float  bg_alpha;
    vector text_color;
    float  text_alpha;
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
    string active_text = "";

    active = predicted_player.weapon;
    HUD_UpdateWeaponSlotCache();

    slot_x = g_width - HUD_SLOT_WIDTH - 12;
    slot_y = g_height * 0.5 - ((HUD_SLOT_HEIGHT * 4 + HUD_SLOT_GAP * 3) * 0.5);

    if (cltime > hud_slot_full_until)
    {
        // Auto-hide branch: keep the active row at its OWN slot's Y so
        // the panel feels stationary — only the active row remains
        // visible, the others vanish in place. Previously this branch
        // re-centered the row vertically, which made the active label
        // jump to the middle of the screen whenever auto-hide kicked in.
        float active_y = slot_y;
        if (active == predicted_player.slot_primary)
        {
            active_text = hud_slot_cache_text1;
            active_y = slot_y;
        }
        else if (active == predicted_player.slot_secondary)
        {
            active_text = hud_slot_cache_text2;
            active_y = slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP);
        }
        else if (active == predicted_player.slot_melee)
        {
            active_text = hud_slot_cache_text3;
            active_y = slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 2;
        }
        else if (active == predicted_player.slot_utility)
        {
            active_text = hud_slot_cache_text4;
            active_y = slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 3;
        }

        if (active_text != "")
            HUD_DrawWeaponSlot(active_text, TRUE, [slot_x, active_y]);
        return;
    }

    if (hud_slot_cache_text1 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text1, active == predicted_player.slot_primary, [slot_x, slot_y]);

    if (hud_slot_cache_text2 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text2, active == predicted_player.slot_secondary, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP)]);

    if (hud_slot_cache_text3 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text3, active == predicted_player.slot_melee, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 2]);

    if (hud_slot_cache_text4 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text4, active == predicted_player.slot_utility, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 3]);
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
    if (phase != ROUND_PHASE_ROUND_END
        && phase != ROUND_PHASE_MAP_END)
        return;

    main_size = [36, 36];
    sub_size = [18, 18];
    cx = g_width * 0.5;
    cy = g_height * 0.35;

    if (FALSE) // freeze countdown removed — already shown in bottom timer
    {
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

    // Always draw round messages and timer, even when dead/spectating
    float prev_font_early = drawfont;
    drawfont = hud_font;
    HUD_DrawCenterMessage();
    HUD_DrawRoundTimer();
    drawfont = prev_font_early;

    if (!predicted_player || !csqc_prediction_valid)
        return;

    // Team-select cameras: the local ent exists with health=100 and a default
    // loadout, but the player hasn't joined yet.  Hide health / weapon slots /
    // crosshair until they're on a team.  (Round messages and timer above
    // already drew, which is intentional — they're useful during team pick.)
    if (getstati(STAT_PLAYERTEAM) <= TEAM_NONE)
        return;

    {
        float predicted_zoomstage = predicted_player.zoomstage;
        // Swap to a non-scope weapon while scoped and the server's
        // zoomstage reset lags on high ping — clear it locally based on
        // the predicted weapon so the scope overlay disappears instantly.
        if (predicted_zoomstage > 0 && !Weapon_HasScope(predicted_player.weapon))
            predicted_zoomstage = 0;

        if (predicted_zoomstage > 0)
            HUD_DrawScope();
        HUD_DrawCrosshair(predicted_zoomstage);
    }

    prev_font = drawfont;
    drawfont = hud_font;

    // Health — bottom left
    hp_str = HUD_GetHealthString();
    drawstring([20 + HUD_SLOT_SHADOW, g_height - 52 + HUD_SLOT_SHADOW], hp_str, [36, 36], '0 0 0', 0.5, 0);
    drawstring([20, g_height - 52], hp_str, [36, 36], '1 1 1', 0.9, 0);

    // Weapon slots — right side, vertically centered
    HUD_DrawWeaponSlots();

    // Round timer and center messages drawn above (before prediction check)

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

    mag_str = HUD_GetAmmoString();
    if (mag_str == "")
    {
        drawfont = prev_font;
        return;
    }

    // SMG: show grenade ammo above main ammo
    if (predicted_player.weapon == WEP_HLSMG)
    {
        string gren_str = HUD_GetHLSMGGrenadeString();
        float gx = g_width - 20 - hud_hlsmg_gren_cache_width;
        drawstring([gx + HUD_SLOT_SHADOW, y - 20 + HUD_SLOT_SHADOW], gren_str, [16, 16], '0 0 0', 0.4, 0);
        drawstring([gx, y - 20], gren_str, [16, 16], '0.8 0.7 0.3', 0.85, 0);
    }

    x = g_width - 20 - hud_ammo_cache_width;
    drawstring([x + HUD_SLOT_SHADOW, y + HUD_SLOT_SHADOW], mag_str, [32, 32], '0 0 0', 0.5, 0);
    drawstring([x, y], mag_str, [32, 32], '1 1 1', 0.9, 0);

    drawfont = prev_font;
};

// ============================================================
//  Speedometer — horizontal speed display (cl_speedometer 1)
// ============================================================

void() HUD_DrawSpeedometer =
{
    if (!cvar("cl_speedometer"))
        return;
    if (!predicted_player || !csqc_prediction_valid)
        return;

    float prev_font = drawfont;
    drawfont = hud_font;

    // Horizontal speed only (ignore vertical component)
    vector flat_vel = predicted_player.velocity;
    flat_vel_z = 0;
    float speed = vlen(flat_vel);

    string speed_str = sprintf("%.0f u/s", speed);
    vector text_size = [24, 24];
    float text_width = stringwidth(speed_str, 0, text_size);
    float x = g_width * 0.5 - text_width * 0.5;
    float y = g_height * 0.55;

    drawstring([x + 1, y + 1], speed_str, text_size, '0 0 0', 0.5, 0);
    drawstring([x, y], speed_str, text_size, '1 1 1', 0.9, 0);

    drawfont = prev_font;
};

// net_graph HUD — bottom-right readout of netcode + interp state.
// Toggle with `net_graph 1`.  Useful for spotting stutter causes:
//   srv tick vs cl snd  — if cl snd < srv tick, server sees stale input
//   snap dt             — time since last snapshot; should be small (0 to 1/tick)
//   snap interval       — spacing of recent snapshots; flat means steady network
//   extrap              — cl_extrap master + grounded flag
//
// Smoothed fps/snap-interval via EMA so the readout doesn't jitter every frame.
float net_graph_ema_fps;
float net_graph_ema_snap_interval;
float net_graph_last_snap_cltime;
float net_graph_last_snap_serverprevtime;

void() HUD_DrawNetGraph =
{
    if (!cvar("net_graph"))
        return;

    float prev_font = drawfont;
    drawfont = hud_font_mono;

    // --- Sample fps (clframetime) with light EMA smoothing ---
    if (clframetime > 0)
    {
        float inst_fps = 1.0 / clframetime;
        if (net_graph_ema_fps <= 0)
            net_graph_ema_fps = inst_fps;
        else
            net_graph_ema_fps = net_graph_ema_fps * 0.9 + inst_fps * 0.1;
    }

    // --- Detect new snapshot via serverprevtime, record spacing ---
    if (serverprevtime != net_graph_last_snap_serverprevtime)
    {
        if (net_graph_last_snap_cltime > 0)
        {
            float snap_dt = cltime - net_graph_last_snap_cltime;
            if (net_graph_ema_snap_interval <= 0)
                net_graph_ema_snap_interval = snap_dt;
            else
                net_graph_ema_snap_interval = net_graph_ema_snap_interval * 0.7 + snap_dt * 0.3;
        }
        net_graph_last_snap_cltime = cltime;
        net_graph_last_snap_serverprevtime = serverprevtime;
    }

    // --- Read config + live state ---
    float sv_tick = serverkeyfloat("sv_mintic");
    if (sv_tick <= 0) sv_tick = 0.015;
    float srv_hz = 1.0 / sv_tick;

    float cl_send = cvar("cl_netfps");

    float extrap_master;
    if (cvar_string("cl_extrap") == "")
        extrap_master = 1;
    else
        extrap_master = cvar("cl_extrap");
    float extrap_grounded = cvar("cl_extrap_grounded");

    float snap_dt_now = cltime - net_graph_last_snap_cltime;  // time since latest snap
    float snap_hz = (net_graph_ema_snap_interval > 0) ? (1.0 / net_graph_ema_snap_interval) : 0;

    // Smoothing (entity error compensation) state — visible so the three
    // smoothness layers (interp / extrap / smooth) are all in one panel.
    float smooth_enabled = 1;
    if (cvar_string("cl_extrap_smooth") != "" && !cvar("cl_extrap_smooth"))
        smooth_enabled = 0;
    float smooth_time;
    if (cvar_string("cl_extrap_smooth_time") == "")
        smooth_time = 0.031;
    else
        smooth_time = cvar("cl_extrap_smooth_time");

    // --- Build lines ---
    string line_fps    = sprintf("fps   %4.0f", net_graph_ema_fps);
    string line_srv    = sprintf("srv   %4.0f Hz  (%.4fs)", srv_hz, sv_tick);
    string line_snd    = sprintf("snd   %4.0f Hz", cl_send);
    string line_snap   = sprintf("snap  %4.0f Hz  dt %.3fs", snap_hz, snap_dt_now);
    string line_extr   = sprintf("extrap %s%s", extrap_master ? "ON " : "OFF",
                                 extrap_grounded ? "(grounded)" : "");
    string line_smooth = sprintf("smooth %s %.3fs",
                                 (smooth_enabled && smooth_time > 0) ? "ON " : "OFF",
                                 smooth_time);

    // --- Layout: bottom-right, stacked upward ---
    vector text_size = [12, 12];
    float pad = 8;
    float line_h = text_size_y + 2;
    float right_x = g_width - pad;
    float bottom_y = g_height - pad;

    string lines[6];
    lines[0] = line_fps;
    lines[1] = line_srv;
    lines[2] = line_snd;
    lines[3] = line_snap;
    lines[4] = line_extr;
    lines[5] = line_smooth;

    // Background panel
    float panel_w = 0;
    float i;
    for (i = 0; i < 6; i++)
    {
        float w = stringwidth(lines[i], 0, text_size);
        if (w > panel_w) panel_w = w;
    }
    float panel_h = line_h * 6 + 4;
    vector panel_pos = [right_x - panel_w - 6, bottom_y - panel_h];
    drawfill(panel_pos, [panel_w + 8, panel_h], '0 0 0', 0.55, 0);

    // Lines stacked from bottom to top (smooth at bottom, fps at top)
    for (i = 0; i < 6; i++)
    {
        float w = stringwidth(lines[i], 0, text_size);
        vector p = [right_x - w - 2, bottom_y - line_h * (6 - i) + 2];
        vector col;
        col = '1 1 1';
        // Highlight the big ones
        if (i == 3) col = (snap_dt_now > sv_tick * 2) ? '1 0.5 0.3' : '0.7 1 0.7';  // snap dt
        if (i == 4) col = extrap_master ? '0.7 1 0.7' : '1 0.7 0.7';
        if (i == 5) col = (smooth_enabled && smooth_time > 0) ? '0.7 1 0.7' : '0.8 0.8 0.8';
        drawstring(p + [1, 1], lines[i], text_size, '0 0 0', 0.7, 0);
        drawstring(p, lines[i], text_size, col, 0.95, 0);
    }

    drawfont = prev_font;
};
