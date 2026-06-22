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

// Active-slot accent-bar colour for the weapon / utility selector.  Red for
// the red team, light blue otherwise (blue team, FFA, or pre-team-select).
vector() HUD_SelectorAccentColour =
{
    string tv = getplayerkeyvalue(player_localnum, "modteam");
    if (tv != "" && stof(tv) == TEAM_RED)
        return '1 0.42 0.42';
    return '0.4 0.7 1';
};

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

// Defuse progress bar — visible only on the active defuser's client.
// STAT_DEFUSE_PROGRESS is set per-client via the .float field
// defuse_progress_stat (sv_main.qc clientstat declaration).
//
// Layout: 250×8 outer box with a 1 px dark-blue border, a 1 px gap
// from border to fill (so the screen behind shows through), and the
// fill itself is a 246×4 horizontal dark-blue gradient that reveals
// from left to right as progress climbs.  No background — the gap
// acts as the see-through transparency.
void() HUD_DrawDefuseBar =
{
    float progress = getstatf(STAT_DEFUSE_PROGRESS);
    if (progress <= 0)
        return;

    float outer_w = 250;
    float outer_h = 8;
    float outer_x = (g_width - outer_w) * 0.5;
    float outer_y = g_height * 0.78;

    vector border_col = '0.18 0.22 0.34';   // muted dark slate, opaque

    // 1 px border — four strips so the centre stays transparent
    // (no full-rect drawfill, otherwise we'd cover the see-through).
    drawfill([outer_x, outer_y],
             [outer_w, 1], border_col, 1.0, 0);                                  // top
    drawfill([outer_x, outer_y + outer_h - 1],
             [outer_w, 1], border_col, 1.0, 0);                                  // bottom
    drawfill([outer_x, outer_y],
             [1, outer_h], border_col, 1.0, 0);                                  // left
    drawfill([outer_x + outer_w - 1, outer_y],
             [1, outer_h], border_col, 1.0, 0);                                  // right

    // Inner fill region — border (1) + gap (1) on every side.
    float bar_x = outer_x + 2;
    float bar_y = outer_y + 2;
    float bar_w = outer_w - 4;   // 246 px
    float bar_h = outer_h - 4;   //   4 px
    float fill_w = bar_w * (progress / CFC4_DEFUSE_TIME);
    if (fill_w > bar_w) fill_w = bar_w;

    // Horizontal dark-blue gradient — 16 vertical strips, each with
    // an interpolated colour stop.  Drawn only up to fill_w so each
    // newly-revealed pixel has its own gradient shade as the defuse
    // climbs left-to-right.
    vector grad_lo = '0.62 0.68 0.80';   // cool light grey on the left
    vector grad_hi = '0.94 0.97 1.00';   // near-white (faint blue tint) on the right
    float strips = 16;
    float strip_w_full = bar_w / strips;
    float i;
    for (i = 0; i < strips; i = i + 1)
    {
        float strip_x = i * strip_w_full;
        if (strip_x >= fill_w)
            break;
        float strip_w = strip_w_full;
        if (strip_x + strip_w > fill_w)
            strip_w = fill_w - strip_x;
        float t = i / strips;
        vector strip_col = grad_lo + (grad_hi - grad_lo) * t;
        drawfill([bar_x + strip_x, bar_y], [strip_w, bar_h], strip_col, 1.0, 0);
    }
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
    return WeaponManifest_HudName(wep_id);
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
float  hud_slot_cache_hlgrenade_ammo;
float  hud_slot_cache_snowball_ammo;
float  hud_slot_cache_cshegrenade_ammo;
float  hud_slot_cache_csflashbang_ammo;
float  hud_slot_cache_cssmokegrenade_ammo;
float  hud_slot_cache_slingshot;
string hud_slot_cache_text1;
string hud_slot_cache_text2;
string hud_slot_cache_text3;
string hud_slot_cache_text4;
string hud_slot_cache_text5;        // C4 label "5 C4" — id-constant, built once
float  hud_slot_cache_text5_valid;  // (no literal initializer: dodges the fteqcc const-global trap)
float  hud_slot_cache_active;
float  hud_slot_full_until;

float  hud_health_cache_valid;
float  hud_health_cache_value;
string hud_health_cache_text;

// Money / armor string caches — mirror the health cache.  Both change rarely
// (a buy, a kill reward, taking damage) but were sprintf'd every render frame.
float  hud_money_cache_valid;
float  hud_money_cache_value;
string hud_money_cache_text;
float  hud_armor_cache_valid;
float  hud_armor_cache_value;
string hud_armor_cache_text;

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

    // Slot 4 (utility): show the currently-selected utility's display
    // name (e.g. "FLASH", "HE") rather than a generic "UTILITY" label.
    // The dropdown rows beneath the slot list any other utilities the
    // player carries, so the slot label itself only needs to show
    // what's active.  Fall back to a name derived from carried ammo
    // if slot_utility hasn't latched yet (rare — happens between a
    // pickup tick and W_UtilityRefreshSlotBinding).
    if (slot_num == 4)
    {
        if (weapon_id != WEP_NONE)
            name = HUD_WeaponName(weapon_id);
        else if (predicted_player.ammo_hlgrenade > 0)        name = HUD_WeaponName(WEP_HLGRENADE);
        else if (predicted_player.ammo_snowball > 0)         name = HUD_WeaponName(WEP_SNOWBALL);
        else if (predicted_player.ammo_cshegrenade > 0)      name = HUD_WeaponName(WEP_CSHEGRENADE);
        else if (predicted_player.ammo_csflashbang > 0)      name = HUD_WeaponName(WEP_CSFLASHBANG);
        else if (predicted_player.ammo_cssmokegrenade > 0)   name = HUD_WeaponName(WEP_CSSMOKEGRENADE);
        else
            name = "";
    }
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
        && hud_slot_cache_hlgrenade_ammo == predicted_player.ammo_hlgrenade
        && hud_slot_cache_snowball_ammo == predicted_player.ammo_snowball
        && hud_slot_cache_cshegrenade_ammo == predicted_player.ammo_cshegrenade
        && hud_slot_cache_csflashbang_ammo == predicted_player.ammo_csflashbang
        && hud_slot_cache_cssmokegrenade_ammo == predicted_player.ammo_cssmokegrenade
        && hud_slot_cache_slingshot == predicted_player.snowball_has_slingshot
        && hud_slot_cache_active == predicted_player.weapon)
        return;

    changed = hud_slot_cache_valid;
    hud_slot_cache_valid = TRUE;
    hud_slot_cache_primary = predicted_player.slot_primary;
    hud_slot_cache_secondary = predicted_player.slot_secondary;
    hud_slot_cache_melee = predicted_player.slot_melee;
    hud_slot_cache_utility = predicted_player.slot_utility;
    hud_slot_cache_hlgrenade_ammo = predicted_player.ammo_hlgrenade;
    hud_slot_cache_snowball_ammo = predicted_player.ammo_snowball;
    hud_slot_cache_cshegrenade_ammo = predicted_player.ammo_cshegrenade;
    hud_slot_cache_csflashbang_ammo = predicted_player.ammo_csflashbang;
    hud_slot_cache_cssmokegrenade_ammo = predicted_player.ammo_cssmokegrenade;
    hud_slot_cache_slingshot = predicted_player.snowball_has_slingshot;
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

string(float money) HUD_GetMoneyString =
{
    if (!hud_money_cache_valid || hud_money_cache_value != money)
    {
        hud_money_cache_valid = TRUE;
        hud_money_cache_value = money;
        hud_money_cache_text  = sprintf("$%g", money);
    }
    return hud_money_cache_text;
};

string(float armor) HUD_GetArmorString =
{
    if (!hud_armor_cache_valid || hud_armor_cache_value != armor)
    {
        hud_armor_cache_valid = TRUE;
        hud_armor_cache_value = armor;
        hud_armor_cache_text  = sprintf("AP %g", armor);
    }
    return hud_armor_cache_text;
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
    float wep = predicted_player.weapon;
    if (W_SlotAmmo_UsesSlot(wep))
    {
        float fmt = W_SlotAmmo_HudFormat(predicted_player, wep);
        float a = W_SlotAmmo_HudPrimaryValue(predicted_player, wep);
        float b = slotammo_ammo;
        return HUD_CacheAmmoString(wep, fmt, a, b);
    }

    if (predicted_player.weapon == WEP_DEAGLE)
        return HUD_CacheAmmoString(WEP_DEAGLE, 1, predicted_player.mag_deagle, predicted_player.ammo_deagle);
    else if (predicted_player.weapon == WEP_AK47)
        return HUD_CacheAmmoString(WEP_AK47, 1, predicted_player.mag_ak47, predicted_player.ammo_ak47);
    else if (predicted_player.weapon == WEP_HDAK47)
        return HUD_CacheAmmoString(WEP_HDAK47, 1, predicted_player.mag_ak47, predicted_player.ammo_ak47);
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
    else if (predicted_player.weapon == WEP_SNOWBALL)
        return HUD_CacheAmmoString(WEP_SNOWBALL, 2, predicted_player.ammo_snowball, 0);
    else if (predicted_player.weapon == WEP_CSHEGRENADE)
        return HUD_CacheAmmoString(WEP_CSHEGRENADE, 2, predicted_player.ammo_cshegrenade, 0);
    else if (predicted_player.weapon == WEP_CSFLASHBANG)
        return HUD_CacheAmmoString(WEP_CSFLASHBANG, 2, predicted_player.ammo_csflashbang, 0);
    else if (predicted_player.weapon == WEP_CSSMOKEGRENADE)
        return HUD_CacheAmmoString(WEP_CSSMOKEGRENADE, 2, predicted_player.ammo_cssmokegrenade, 0);
    else if (predicted_player.weapon == WEP_PAINTBALL)
        return HUD_CacheAmmoString(WEP_PAINTBALL, 1, predicted_player.mag_paintball, predicted_player.ammo_paintball);
    else if (predicted_player.weapon == WEP_HLGLOCK)
        return HUD_CacheAmmoString(WEP_HLGLOCK, 1, predicted_player.mag_hlglock, predicted_player.ammo_hlglock);
    else if (predicted_player.weapon == WEP_HLEGON)
        return HUD_CacheAmmoString(WEP_HLEGON, 2, predicted_player.ammo_hlegon, 0);
    else if (predicted_player.weapon == WEP_CFAUG)
        return HUD_CacheAmmoString(WEP_CFAUG, 1, predicted_player.mag_cfaug, predicted_player.ammo_cfaug);
    else if (predicted_player.weapon == WEP_CFFAMAS)
        return HUD_CacheAmmoString(WEP_CFFAMAS, 1, predicted_player.mag_cffamas, predicted_player.ammo_cffamas);
    else if (predicted_player.weapon == WEP_CFMAC10)
        return HUD_CacheAmmoString(WEP_CFMAC10, 1, predicted_player.mag_cfmac10, predicted_player.ammo_cfmac10);
    else if (predicted_player.weapon == WEP_CFMP5)
        return HUD_CacheAmmoString(WEP_CFMP5, 1, predicted_player.mag_cfmp5, predicted_player.ammo_cfmp5);
    else if (predicted_player.weapon == WEP_CFVECTOR)
        return HUD_CacheAmmoString(WEP_CFVECTOR, 1, predicted_player.mag_cfvector, predicted_player.ammo_cfvector);
    else if (predicted_player.weapon == WEP_CFTYPE89)
        return HUD_CacheAmmoString(WEP_CFTYPE89, 1, predicted_player.mag_cftype89, predicted_player.ammo_cftype89);
    else if (predicted_player.weapon == WEP_CFUMP45)
        return HUD_CacheAmmoString(WEP_CFUMP45, 1, predicted_player.mag_cfump45, predicted_player.ammo_cfump45);
    else if (predicted_player.weapon == WEP_CFM249)
        return HUD_CacheAmmoString(WEP_CFM249, 1, predicted_player.mag_cfm249, predicted_player.ammo_cfm249);
    else if (predicted_player.weapon == WEP_CFAWM)
        return HUD_CacheAmmoString(WEP_CFAWM, 1, predicted_player.mag_cfawm, predicted_player.ammo_cfawm);
    else if (predicted_player.weapon == WEP_CFKS23)
        return HUD_CacheAmmoString(WEP_CFKS23, 1, predicted_player.mag_cfks23, predicted_player.ammo_cfks23);
    else if (predicted_player.weapon == WEP_CFM4)
        return HUD_CacheAmmoString(WEP_CFM4, 1, predicted_player.mag_cfm4, predicted_player.ammo_cfm4);
    else if (predicted_player.weapon == WEP_CFMK23)
        return HUD_CacheAmmoString(WEP_CFMK23, 1, predicted_player.mag_cfmk23, predicted_player.ammo_cfmk23);
    else if (predicted_player.weapon == WEP_CSUSP)
        return HUD_CacheAmmoString(WEP_CSUSP, 1, predicted_player.mag_csusp, predicted_player.ammo_csusp);
    else if (predicted_player.weapon == WEP_CFGALIL)
        return HUD_CacheAmmoString(WEP_CFGALIL, 1, predicted_player.mag_cfgalil, predicted_player.ammo_cfgalil);
    else if (predicted_player.weapon == WEP_CFGLOCK)
        return HUD_CacheAmmoString(WEP_CFGLOCK, 1, predicted_player.mag_cfglock, predicted_player.ammo_cfglock);
    else if (predicted_player.weapon == WEP_CFELITE)
        return HUD_CacheAmmoString(WEP_CFELITE, 1, predicted_player.mag_cfelite, predicted_player.ammo_cfelite);
    else if (predicted_player.weapon == WEP_CFP228)
        return HUD_CacheAmmoString(WEP_CFP228, 1, predicted_player.mag_cfp228, predicted_player.ammo_cfp228);
    else if (predicted_player.weapon == WEP_CFMSG90)
        return HUD_CacheAmmoString(WEP_CFMSG90, 1, predicted_player.mag_cfmsg90, predicted_player.ammo_cfmsg90);
    else if (predicted_player.weapon == WEP_CFSG552)
        return HUD_CacheAmmoString(WEP_CFSG552, 1, predicted_player.mag_cfsg552, predicted_player.ammo_cfsg552);
    else if (predicted_player.weapon == WEP_CFSL8)
        return HUD_CacheAmmoString(WEP_CFSL8, 1, predicted_player.mag_cfsl8, predicted_player.ammo_cfsl8);
    else if (predicted_player.weapon == WEP_CFM9)
        return HUD_CacheAmmoString(WEP_CFM9, 1, predicted_player.mag_cfm9, predicted_player.ammo_cfm9);
    else if (predicted_player.weapon == WEP_CFREVOLVER)
        return HUD_CacheAmmoString(WEP_CFREVOLVER, 1, predicted_player.mag_cfrevolver, predicted_player.ammo_cfrevolver);
    else if (predicted_player.weapon == WEP_CFBARRETT)
        return HUD_CacheAmmoString(WEP_CFBARRETT, 1, predicted_player.mag_cfbarrett, predicted_player.ammo_cfbarrett);
    else if (predicted_player.weapon == WEP_CFPSG1)
        return HUD_CacheAmmoString(WEP_CFPSG1, 1, predicted_player.mag_cfpsg1, predicted_player.ammo_cfpsg1);
    else if (predicted_player.weapon == WEP_CFDDEAGLE)
        return HUD_CacheAmmoString(WEP_CFDDEAGLE, 1, predicted_player.mag_cfddeagle, predicted_player.ammo_cfddeagle);
    else if (predicted_player.weapon == WEP_CFSPAS12)
        return HUD_CacheAmmoString(WEP_CFSPAS12, 1, predicted_player.mag_cfspas12, predicted_player.ammo_cfspas12);
    else if (predicted_player.weapon == WEP_CFM700)
        return HUD_CacheAmmoString(WEP_CFM700, 1, predicted_player.mag_cfm700, predicted_player.ammo_cfm700);
    else if (predicted_player.weapon == WEP_CFM3)
        return HUD_CacheAmmoString(WEP_CFM3, 1, predicted_player.mag_cfm3, predicted_player.ammo_cfm3);
    else if (predicted_player.weapon == WEP_CFSCAR)
        return HUD_CacheAmmoString(WEP_CFSCAR, 1, predicted_player.mag_cfscar, predicted_player.ammo_cfscar);
    else if (predicted_player.weapon == WEP_CFMAUSER)
        return HUD_CacheAmmoString(WEP_CFMAUSER, 1, predicted_player.mag_cfmauser, predicted_player.ammo_cfmauser);
    else if (predicted_player.weapon == WEP_CFSVD)
        return HUD_CacheAmmoString(WEP_CFSVD, 1, predicted_player.mag_cfsvd, predicted_player.ammo_cfsvd);

    return "";
};

string() HUD_GetHLSMGGrenadeString =
{
    W_SlotAmmo_GetForWeapon(predicted_player, WEP_HLSMG);
    float grenades = slotammo_aux;
    if (!hud_hlsmg_gren_cache_valid
        || hud_hlsmg_gren_cache_value != grenades)
    {
        hud_hlsmg_gren_cache_valid = TRUE;
        hud_hlsmg_gren_cache_value = grenades;
        hud_hlsmg_gren_cache_text = sprintf("Grenade Launcher: %g", grenades);
        hud_hlsmg_gren_cache_width = stringwidth(hud_hlsmg_gren_cache_text, 1, [16, 16]);
    }

    return hud_hlsmg_gren_cache_text;
};

// flash_red is REQUIRED (not optional): QC optional params are not zeroed — an
// unpassed one reads stale OFS_PARM3 from the previous call, which made the
// non-C4 slots flash with a garbage value.  All callers pass it explicitly.
void(string slot_text, float is_active, vector pos, float flash_red) HUD_DrawWeaponSlot =
{
    vector text_color;
    float  text_alpha;
    vector text_pos;
    vector text_size;

    if (is_active)
    {
        text_color = '1 1 1';
        text_alpha = 1.0;
    }
    else
    {
        text_color = '0.6 0.6 0.6';
        text_alpha = 0.8;
    }

    // Bombsite plant-zone alert: when the caller flags this slot (the C4 slot,
    // driven by STAT_CAN_PLANT — set only while the carrier stands on a bombsite),
    // pulse it red so they can SEE they're able to plant.  Overrides the normal
    // colour AND the active accent bar.  ~1.6 Hz sine on cltime.
    if (flash_red)
    {
        float pulse = 0.5 + 0.5 * sin(cltime * 10);
        drawfill([pos_x, pos_y], [HUD_SLOT_WIDTH, HUD_SLOT_HEIGHT], '1 0 0', 0.12 + 0.30 * pulse, 0);
        text_color = '1 0.2 0.2';
        text_alpha = 0.55 + 0.45 * pulse;
    }
    // Background panel removed — the font's baked outline (loadfont outline=1)
    // keeps the label readable over the world without a fill.  Active slot is
    // marked by brighter text + a 2px accent bar at the LEFT edge (moved in from
    // the old panel's right edge so it sits beside the label instead of floating
    // where the now-invisible panel used to end).
    else if (is_active)
        drawfill([pos_x, pos_y], [2, HUD_SLOT_HEIGHT], HUD_SelectorAccentColour(), 1.0, 0);

    text_size = [HUD_SLOT_FONT, HUD_SLOT_FONT];
    text_pos_x = pos_x + HUD_SLOT_PADDING;
    // The font's glyph metrics extend below the geometric mid-line;
    // the math-only midpoint lands ~1 px high.  Bump the baseline by
    // 1 px so the label sits centred to the eye instead of crammed
    // against the slot's top edge.
    text_pos_y = pos_y + (HUD_SLOT_HEIGHT - HUD_SLOT_FONT) * 0.5 + 1;
    text_pos_z = 0;

    // Single draw — legibility border comes from the font's baked outline
    // (loadfont outline=1 in cl_main.qc), replacing the old shadow double-draw.
    drawstring(text_pos, slot_text, text_size, text_color, text_alpha, 0);
};

// Compact dropdown row — half-height of the main slot, native 8 px
// bitmap font, no shadow.  Active row gets a subtle highlight so the
// player can see which utility is currently selected without the row
// rearranging the list.
float HUD_DROP_HEIGHT = 12;
float HUD_DROP_FONT   = 8;

void(string label, float is_active, vector pos) HUD_DrawUtilityDropRow =
{
    vector tx_color  = is_active ? '1 1 1'          : '0.7 0.75 0.85';
    float  tx_alpha  = is_active ? 1.0  : 0.7;

    // Background panel removed (see HUD_DrawWeaponSlot) — outlined text only,
    // with a left-edge accent bar on the active row.
    if (is_active)
        drawfill([pos_x, pos_y], [2, HUD_DROP_HEIGHT], HUD_SelectorAccentColour(), 1.0, 0);

    vector text_size = [HUD_DROP_FONT, HUD_DROP_FONT];
    vector text_pos;
    text_pos_x = pos_x + HUD_SLOT_PADDING + 4;
    text_pos_y = pos_y + (HUD_DROP_HEIGHT - HUD_DROP_FONT) * 0.5 + 1;
    text_pos_z = 0;

    drawstring(text_pos, label, text_size, tx_color, tx_alpha, 0);
};

// Render the full carried-utility list below slot 4 in fixed canonical
// order (HE → Snowball → CSHE → Flash → Smoke).  The active utility
// gets the highlighted row instead of being hidden, so cycling the
// utility key (impulse 4) or scroll wheel doesn't reshuffle the
// visible rows — only the highlight moves.  Order matches
// W_UtilityCycleCarried so the next-key target maps to the next row
// down.  Returns the number of rows drawn (informational).
// Throttled-recompute cache for the utility dropdown. The carried[]
// + names[] + total values rebuild at cl_hud_fps Hz (default 30) OR
// immediately whenever any of the 5 ammo fields changes — the
// ammo_sum check forces an instant rebuild on pickup / use so the
// dropdown stays responsive without paying the full eval cost on
// idle frames. `active` (currently-equipped utility) reads per frame
// because it's a single cheap field lookup and drives the
// per-row highlight.
float  hud_util_cache_last_recompute;
float  hud_util_cache_total;
float  hud_util_cache_carried[5];
string hud_util_cache_names[5];
float  hud_util_cache_ammo_sum;

float(vector first_pos) HUD_DrawUtilityDropdown =
{
    float row = 0;
    float active = predicted_player.slot_utility;
    vector pos = first_pos;

    float cands[5] = { WEP_HLGRENADE, WEP_SNOWBALL, WEP_CSHEGRENADE,
                       WEP_CSFLASHBANG, WEP_CSSMOKEGRENADE };

    // Detect any ammo change since the last rebuild — pickup / use /
    // drop instantly invalidates the cache regardless of throttle.
    // Sum is a good-enough fingerprint: any ammo field changing by ±1
    // shifts the sum by ±1, never colliding within one tick.
    float ammo_sum = predicted_player.ammo_hlgrenade
                   + predicted_player.ammo_snowball
                   + predicted_player.ammo_cshegrenade
                   + predicted_player.ammo_csflashbang
                   + predicted_player.ammo_cssmokegrenade;

    float hud_fps = cvar("cl_hud_fps");
    if (hud_fps <= 0) hud_fps = 30;
    float interval = 1.0 / hud_fps;

    if (ammo_sum != hud_util_cache_ammo_sum
        || cltime - hud_util_cache_last_recompute >= interval)
    {
        hud_util_cache_last_recompute = cltime;
        hud_util_cache_ammo_sum = ammo_sum;

        hud_util_cache_carried[0] = predicted_player.ammo_hlgrenade > 0;
        hud_util_cache_carried[1] = predicted_player.ammo_snowball > 0;
        hud_util_cache_carried[2] = predicted_player.ammo_cshegrenade > 0;
        hud_util_cache_carried[3] = predicted_player.ammo_csflashbang > 0;
        hud_util_cache_carried[4] = predicted_player.ammo_cssmokegrenade > 0;

        hud_util_cache_total = 0;
        for (float ci = 0; ci < 5; ci++)
        {
            if (hud_util_cache_carried[ci])
            {
                hud_util_cache_names[ci] = HUD_WeaponName(cands[ci]);
                hud_util_cache_total = hud_util_cache_total + 1;
            }
        }
    }

    // Don't draw a single-row dropdown — slot 4 already shows the only
    // carried utility, the dropdown adds nothing.
    if (hud_util_cache_total <= 1)
        return 0;

    for (float i = 0; i < 5; i++)
    {
        if (!hud_util_cache_carried[i])
            continue;

        HUD_DrawUtilityDropRow(hud_util_cache_names[i], cands[i] == active, pos);
        pos_y = pos_y + HUD_DROP_HEIGHT + 1;
        row++;
    }

    return row;
};

void() HUD_DrawWeaponSlots =
{
    float  active;
    float  slot_x, slot_y;

    active = predicted_player.weapon;
    HUD_UpdateWeaponSlotCache();

    slot_x = g_width - HUD_SLOT_WIDTH - 12;
    slot_y = g_height * 0.5 - ((HUD_SLOT_HEIGHT * 4 + HUD_SLOT_GAP * 3) * 0.5);

    // No more auto-hide — non-active slots stay visible at reduced
    // opacity so the player keeps a constant view of their loadout.
    // HUD_DrawWeaponSlot already dims inactive entries via bg_alpha
    // 0.6 / text_alpha 0.8.

    if (hud_slot_cache_text1 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text1, active == predicted_player.slot_primary, [slot_x, slot_y], 0);

    if (hud_slot_cache_text2 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text2, active == predicted_player.slot_secondary, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP)], 0);

    if (hud_slot_cache_text3 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text3, active == predicted_player.slot_melee, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 2], 0);

    if (hud_slot_cache_text4 != "")
        HUD_DrawWeaponSlot(hud_slot_cache_text4, active == predicted_player.slot_utility, [slot_x, slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 3], 0);

    // Slot 5 — C4 (impulse 5).  Visible whenever the player carries a
    // charge, even if not currently holding it.  Lives outside the
    // utility cycle so it gets its own dedicated slot.  Label format
    // matches the other slots ("N NAME") via HUD_BuildWeaponSlotText.
    float c4_y = slot_y + (HUD_SLOT_HEIGHT + HUD_SLOT_GAP) * 4;
    if (predicted_player.ammo_cfc4 > 0)
    {
        // The C4 label is constant ("5 C4"), so build it once instead of
        // sprintf'ing every frame the player carries the charge. (Cache-once
        // is valid only while the label stays constant — revisit if it ever
        // becomes dynamic, e.g. "5 C4 (armed)".)
        if (!hud_slot_cache_text5_valid)
        {
            hud_slot_cache_text5       = sprintf("5 %s", HUD_WeaponName(WEP_CFC4));
            hud_slot_cache_text5_valid = TRUE;
        }
        // Flash the slot red while the carrier stands on a bombsite (can plant).
        HUD_DrawWeaponSlot(hud_slot_cache_text5, active == WEP_CFC4, [slot_x, c4_y], getstatf(STAT_CAN_PLANT));
        c4_y = c4_y + HUD_SLOT_HEIGHT + HUD_SLOT_GAP;
    }

    // Carried-utility "dropdown" — appears beneath the last slot
    // (utility, or C4 if present) whenever the player carries any
    // utility besides the active one.
    HUD_DrawUtilityDropdown([slot_x, c4_y]);
};

// Cached formatted timer — the displayed text is identical for a whole second
// but was sprintf'd + stringwidth'd EVERY render frame (uncapped fps).  Re-format
// only when the displayed second, phase, or red/normal colour-state changes.
float  hud_rt_cache_valid;
float  hud_rt_cache_phase;
float  hud_rt_cache_second;
float  hud_rt_cache_red;
string hud_rt_cache_str;
vector hud_rt_cache_color;
float  hud_rt_cache_width;

void() HUD_DrawRoundTimer =
{
    float remaining;
    float disp_sec;
    float want_red = 0;
    float phase;

    phase = getstatf(STAT_ROUND_PHASE);

    // During freeze, show freeze countdown on the bottom timer
    if (phase == ROUND_PHASE_FREEZE)
    {
        remaining = getstatf(STAT_FREEZE_TIMELEFT);
        if (remaining <= 0)
            return;
        disp_sec = ceil(remaining);
    }
    else if (phase == ROUND_PHASE_ACTIVE)
    {
        // Defuse: once the bomb is down the round clock is suspended on the
        // server (the bomb fuse owns the round), so remove the timer from the
        // HUD until the next round.  STAT_BOMB_PLANTED is only ever set in
        // Defuse mode, so no extra gamemode check is needed here.
        if (getstatf(STAT_BOMB_PLANTED))
            return;
        remaining = getstatf(STAT_ROUNDTIMER);
        if (remaining <= 0)
            return;
        disp_sec = floor(remaining);
        want_red = (remaining <= 30);
    }
    else
        return;  // hide timer during round end / map end phases

    // Re-format only on a second / phase / colour change (getstatf above is a
    // cheap stat-array read; the sprintf + stringwidth were the per-frame waste).
    if (!hud_rt_cache_valid
        || phase != hud_rt_cache_phase
        || disp_sec != hud_rt_cache_second
        || want_red != hud_rt_cache_red)
    {
        hud_rt_cache_valid  = TRUE;
        hud_rt_cache_phase  = phase;
        hud_rt_cache_second = disp_sec;
        hud_rt_cache_red    = want_red;
        if (phase == ROUND_PHASE_FREEZE)
        {
            hud_rt_cache_str   = sprintf("%.0f", disp_sec);
            hud_rt_cache_color = '1 0.8 0.2';
        }
        else
        {
            float minutes = floor(remaining / 60);
            float seconds = floor(remaining - minutes * 60);
            hud_rt_cache_str   = sprintf("%g:%02g", minutes, seconds);
            hud_rt_cache_color = want_red ? '1 0.2 0.2' : '1 1 1';
        }
        hud_rt_cache_width = stringwidth(hud_rt_cache_str, 1, [32, 32]);
    }

    float x = g_width * 0.5 - hud_rt_cache_width * 0.5;
    float y = g_height - 52;
    drawstring([x, y], hud_rt_cache_str, [32, 32], hud_rt_cache_color, 0.9, 0);
};

// ============================================================
//  Dopamine kill/cash feedback  (kill popup, round cash, money floats)
// ------------------------------------------------------------
//  Driven by the CSQC_EVENT_KILL_REWARD / CSQC_EVENT_ROUND_REWARD
//  handlers below (called from CSQC_Parse_Event) + a per-frame
//  STAT_MONEY watch.  HUD_DopamineFrame() runs once per frame from
//  both the alive HUD and the spectator HUD.
// ============================================================

// --- Kill-cash popup (center-top, delayed 0.5s, fade-in + shrink) ---
float  killpop_armed;        // event received, waiting out the 0.5s delay
float  killpop_fire_time;    // cltime the popup appears + orchestralhit plays
float  killpop_start_time;   // cltime the popup actually started (0 = idle)
float  killpop_amount;       // cash reward to print
float  killpop_headshot;     // 1 = gold + HEADSHOT flair
const float KILLPOP_DELAY = 0;      // post-kill delay before it appears (0 = instant)
const float KILLPOP_RISE  = 0.15;   // fade-in (alpha 0->1) + shrink (1.8->1.0)
const float KILLPOP_HOLD  = 0.55;   // full-alpha hold
const float KILLPOP_FALL  = 0.45;   // fade-out
const float KILLPOP_LIFE  = 1.15;   // RISE + HOLD + FALL

// --- Round win/lose cash (drawn under the win/lose banner) ---
float  roundrew_time;        // cltime the round-reward event arrived (0 = none)
float  roundrew_amount;
float  roundrew_won;
const float ROUNDREW_WINDOW = 12;    // recency gate so a prior reward can't bleed onto a draw round

// --- Money-add floats ("+$xxx" drifting down into the cash counter) ---
const float MONEYADD_MAX  = 4;
const float MONEYADD_LIFE = 0.7;
float  moneyadd_amount [MONEYADD_MAX];
float  moneyadd_start  [MONEYADD_MAX];
float  moneyadd_head;        // ring write index
float  moneyadd_prev;        // last-seen STAT_MONEY
float  moneyadd_inited;      // FALSE until the first frame seeds moneyadd_prev

// --- Progression HUD (Part 1): rank/XP widget + rank-up flash ---
const float PROG_LEVELUP_FLASH = 2.5;   // seconds the "RANK UP" banner shows
float  prog_level_prev;                 // last-seen STAT_LEVEL
float  prog_level_inited;               // FALSE until the first frame seeds prog_level_prev
float  prog_levelup_time;               // cltime of the last rank-up (drives the flash + sound)

// Event handlers — called from CSQC_Parse_Event (cl_main.qc).
void(float amount, float headshot) HUD_OnKillReward =
{
    killpop_amount     = amount;
    killpop_headshot   = headshot;
    killpop_fire_time  = cltime + KILLPOP_DELAY;
    killpop_start_time = 0;
    killpop_armed      = TRUE;
    // The "kill confirmed" sting plays IMMEDIATELY on a headshot kill;
    // the +$ popup + orchestralhit still land KILLPOP_DELAY later.
    if (headshot)
        localsound("sounds/effects/killsound.wav");
};

void(float amount, float won) HUD_OnRoundReward =
{
    roundrew_amount = amount;
    roundrew_won    = won;
    roundrew_time   = cltime;
    localsound("sounds/effects/cashregister1.mp3");
};

// Kill-cash popup — center-top "+$xxx" that fades in + shrinks big->small,
// holds, then fades out.  Latches its real start (and plays orchestralhit)
// once KILLPOP_DELAY has elapsed since the kill.
void() HUD_DrawKillPopup =
{
    if (!killpop_armed && killpop_start_time == 0)
        return;
    if (killpop_armed)
    {
        if (cltime < killpop_fire_time)
            return;                 // still waiting out the post-kill delay
        killpop_armed      = FALSE;
        killpop_start_time = cltime;
        localsound("sounds/effects/orchestralhit.mp3");
    }

    float age = cltime - killpop_start_time;
    if (age >= KILLPOP_LIFE)
    {
        killpop_start_time = 0;     // animation done
        return;
    }

    float a, scale, t;
    if (age < KILLPOP_RISE)
    {
        t     = age / KILLPOP_RISE;     // 0..1
        a     = t;                      // alpha 0 -> 1
        scale = 1.8 - 0.8 * t;          // big -> normal (1.8 -> 1.0)
    }
    else if (age < KILLPOP_RISE + KILLPOP_HOLD)
    {
        a = 1;  scale = 1.0;
    }
    else
    {
        t = (age - KILLPOP_RISE - KILLPOP_HOLD) / KILLPOP_FALL;  // 0..1
        a = 1 - t;  scale = 1.0;
    }

    vector col = killpop_headshot ? '1 0.85 0.2' : '0.4 0.9 0.4';
    string txt = sprintf("+$%g", killpop_amount);

    float prev_font = drawfont;
    drawfont = hud_font;

    float base = 40;
    vector sz = [base * scale, base * scale];
    float w  = stringwidth(txt, 1, sz);
    float cx = g_width * 0.5;
    float cy = g_height * 0.30;
    drawstring([cx - w * 0.5, cy], txt, sz, col, a, 0);

    if (killpop_headshot)
    {
        vector hsz = [16, 16];
        float hw = stringwidth("HEADSHOT", 1, hsz);
        drawstring([cx - hw * 0.5, cy - 20], "HEADSHOT", hsz, '1 0.85 0.2', a, 0);
    }

    drawfont = prev_font;
};

// Money-add floats — each "+$delta" appears just above the cash counter and
// drifts DOWN into it as it fades.  Spawned by HUD_MoneyWatch on any increase.
void() HUD_DrawMoneyAdds =
{
    float i;
    float prev_font = drawfont;
    drawfont = hud_font_mono;
    float counter_y = g_height - 74;    // matches the money counter draw
    for (i = 0; i < MONEYADD_MAX; i = i + 1)
    {
        if (moneyadd_start[i] <= 0)
            continue;
        float age = cltime - moneyadd_start[i];
        if (age >= MONEYADD_LIFE)
        {
            moneyadd_start[i] = 0;
            continue;
        }
        float t = age / MONEYADD_LIFE;          // 0..1
        float y = (counter_y - 22) + 22 * t;    // drift down into the counter
        float a = 1 - t;                        // fade as it lands
        drawstring([24, y], sprintf("+$%g", moneyadd_amount[i]), [14, 14], '0.5 1 0.5', a * 0.95, 0);
    }
    drawfont = prev_font;
};

// Watch our own STAT_MONEY; on any INCREASE push a money-add float.
void() HUD_MoneyWatch =
{
    float m = getstatf(STAT_MONEY);
    if (!moneyadd_inited)
    {
        moneyadd_inited = TRUE;
        moneyadd_prev   = m;        // seed without spawning a connect-time float
        return;
    }
    if (m > moneyadd_prev)
    {
        moneyadd_amount[moneyadd_head] = m - moneyadd_prev;
        moneyadd_start [moneyadd_head] = cltime;
        moneyadd_head = (moneyadd_head + 1) % MONEYADD_MAX;
    }
    moneyadd_prev = m;
};

// Rank title for a level band — mirrors server Prog_RankName (sv_progression.qc).
string(float lvl) HUD_RankName =
{
    if (lvl >= 50) return "Commander";
    if (lvl >= 40) return "Captain";
    if (lvl >= 30) return "Lieutenant";
    if (lvl >= 20) return "Sergeant";
    if (lvl >= 10) return "Corporal";
    if (lvl >= 5)  return "Private";
    return "Recruit";
};

// Watch STAT_LEVEL; on an increase latch a rank-up flash + fanfare.  Level only
// ever rises (the server subtracts xp on level-up but never lowers level), so a
// plain delta is reliable here.
void() HUD_ProgWatch =
{
    float lvl = getstatf(STAT_LEVEL);
    if (!prog_level_inited)
    {
        prog_level_inited = TRUE;
        prog_level_prev   = lvl;   // seed without a connect-time false rank-up
        return;
    }
    if (lvl > prog_level_prev)
    {
        prog_levelup_time = cltime;
        localsound("sounds/effects/orchestralhit.mp3");
    }
    prog_level_prev = lvl;
};

// Compact rank widget (bottom-left, above the cash counter): "Lv N  Rank" + a
// thin XP progress bar, plus the transient centered "RANK UP" banner.
void() HUD_DrawRankWidget =
{
    float lvl = getstatf(STAT_LEVEL);
    float xp  = getstatf(STAT_XP);
    float xpn = getstatf(STAT_XP_NEXT);
    if (lvl < 1)  lvl = 1;
    if (xpn <= 0) xpn = 1;

    float bx = 24;
    float by = g_height - 116;
    float bw = 168;
    float bh = 6;

    float prev_font = drawfont;
    drawfont = hud_font;
    drawstring([bx, by - 16], sprintf("Lv %g  %s", lvl, HUD_RankName(lvl)),
               [12, 12], '0.75 0.85 1', 0.9, 0);
    drawfont = prev_font;

    drawfill([bx, by], [bw, bh], '0.10 0.13 0.20', 0.85, 0);
    float fillw = bw * (xp / xpn);
    if (fillw < 0)  fillw = 0;
    if (fillw > bw) fillw = bw;
    if (fillw > 0)
        drawfill([bx, by], [fillw, bh], '0.40 0.62 0.95', 0.95, 0);

    if (prog_levelup_time > 0 && (cltime - prog_levelup_time) < PROG_LEVELUP_FLASH)
    {
        float a = 1 - (cltime - prog_levelup_time) / PROG_LEVELUP_FLASH;
        string up = sprintf("RANK UP  -  %s", HUD_RankName(lvl));
        vector usz = [26, 26];
        float  uw  = stringwidth(up, 1, usz);
        drawstring([g_width * 0.5 - uw * 0.5, g_height * 0.30], up, usz, '1 0.92 0.5', a, 0);
    }
};

// Per-frame entry — watch + draw.  Called from BOTH the alive HUD and the
// spectator HUD so the money watch tracks continuously (no stale delta
// across a death/respawn).
void() HUD_DopamineFrame =
{
    HUD_MoneyWatch();
    HUD_DrawKillPopup();
    HUD_DrawMoneyAdds();
    HUD_ProgWatch();
    HUD_DrawRankWidget();
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
    drawstring([cx - main_width * 0.5, cy], main_text, main_size, main_color, 0.9, 0);

    // Draw subtext
    sub_width = stringwidth(sub_text, 1, sub_size);
    drawstring([cx - sub_width * 0.5, cy + 44], sub_text, sub_size, '0.8 0.8 0.8', 0.85, 0);

    // Dopamine round-cash line — under the win/lose banner.  Driven by the
    // CSQC_EVENT_ROUND_REWARD event (no event on a draw → no line); the
    // recency gate stops a prior round's reward bleeding onto a draw round.
    if (phase == ROUND_PHASE_ROUND_END
        && roundrew_time > 0
        && (cltime - roundrew_time) < ROUNDREW_WINDOW)
    {
        string cash_txt = sprintf("+$%g", roundrew_amount);
        vector cash_col = roundrew_won ? '0.4 0.95 0.4' : '0.8 0.8 0.85';
        vector cash_sz  = [26, 26];
        float  cash_w   = stringwidth(cash_txt, 1, cash_sz);
        drawstring([cx - cash_w * 0.5, cy + 72], cash_txt, cash_sz, cash_col, 0.95, 0);
    }

    // nettest progression: session-XP + rank summary on the round/match-end
    // banner (networked via STAT_PROG_SESSIONXP / STAT_LEVEL).
    if (phase == ROUND_PHASE_ROUND_END || phase == ROUND_PHASE_MAP_END)
    {
        float sxp = getstatf(STAT_PROG_SESSIONXP);
        float lvl = getstatf(STAT_LEVEL);
        if (lvl < 1) lvl = 1;
        string xp_txt = sprintf("Session XP +%g   -   Lv %g  %s", sxp, lvl, HUD_RankName(lvl));
        vector xp_sz  = [18, 18];
        float  xp_w   = stringwidth(xp_txt, 1, xp_sz);
        drawstring([cx - xp_w * 0.5, cy + 104], xp_txt, xp_sz, '0.7 0.85 1', 0.9, 0);
    }
};

void() CSQC_DrawWeaponHUD =
{
    string mag_str;
    string hp_str;
    float  x, y;
    float  prev_font;
    float  prev_font_early;

    // ---- SCOPE OVERLAY FIRST (alive players only) ----
    // The scope (letterbox + scope.png + fade) must draw BEFORE any
    // text or status overlays so the round timer / center message /
    // stamina bar can composite on top.  Without this, the scope's
    // black bars would cover the round timer (user reported bug:
    // "Can you ensure the bar overlays on top of scope, same with
    // the round time").
    float scope_ok = predicted_player && csqc_prediction_valid
                  && getstati(STAT_PLAYERTEAM) > TEAM_NONE;
    float predicted_zoomstage = 0;
    if (scope_ok)
    {
        predicted_zoomstage = predicted_player.zoomstage;
        // Swap to a non-scope weapon while scoped and the server's
        // zoomstage reset lags on high ping — clear it locally based on
        // the predicted weapon so the scope overlay disappears instantly.
        if (predicted_zoomstage > 0 && !Weapon_HasScope(predicted_player.weapon))
            predicted_zoomstage = 0;

        if (predicted_zoomstage > 0)
            HUD_DrawScope();
        // CoD scope draws on top of the CS-style stack — the two are
        // mutually exclusive (Weapon_HasScope returns 0 for scout/awp
        // under sv_codscopes so the legacy HUD_DrawScope can't fire
        // for them), but ordering this AFTER it keeps the fade fill
        // above any other HUD overlay drawn earlier.  The drawer
        // self-gates on phase != OFF.
        CSQC_CodScope_DrawOverlay();
    }

    // ---- Round timer + center message + stamina bar — ON TOP of scope ----
    // Drawn for everyone including dead / spectating; the scope above
    // is alive-gated so spectators get the same layout minus the scope.
    prev_font_early = drawfont;
    drawfont = hud_font;
    HUD_DrawCenterMessage();
    HUD_DrawRoundTimer();
    HUD_DrawCodStaminaBar();
    drawfont = prev_font_early;

    if (!predicted_player || !csqc_prediction_valid)
        return;
    if (getstati(STAT_PLAYERTEAM) <= TEAM_NONE)
        return;

    {
        // Pass an effective zoomstage that reflects the CoD scope too
        // so the crosshair-suppress branch in cl_crosshair.qc treats
        // a CoD-scoped player the same as a CS-scoped one.
        if (CSQC_CodScope_IsScoped() && predicted_zoomstage == 0)
            predicted_zoomstage = 2;
        HUD_DrawCrosshair(predicted_zoomstage);
    }

    prev_font = drawfont;
    drawfont = hud_font;

    // Health — bottom left
    hp_str = HUD_GetHealthString();
    drawstring([20, g_height - 52], hp_str, [36, 36], '1 1 1', 0.9, 0);

    // Armor (Kevlar) — same hud_font as health but a notch smaller, sitting to
    // the RIGHT of the health number with their floors (text baselines) aligned.
    // Only drawn when you actually have armor.  (Health text: top g_height-52,
    // 36 tall -> floor at g_height-16; armor top = floor - its size.)
    {
        float cur_armor_hp = getstatf(STAT_CSARMOR);
        if (cur_armor_hp > 0)
        {
            float hp_w  = stringwidth(hp_str, 1, [36, 36]);
            float ar_sz = 24;
            drawstring([20 + hp_w + 10, (g_height - 16) - ar_sz],
                       HUD_GetArmorString(cur_armor_hp), [ar_sz, ar_sz],
                       '0.5 0.7 1', 0.9, 0);
        }
    }

    // Money — left side, just above health, in a smaller GoogleMed size
    // (hud_font_mono).
    {
        float cur_money = getstatf(STAT_MONEY);
        float prev_money_font = drawfont;
        string money_str;
        float my;
        drawfont = hud_font_mono;
        // Green normally; flashes gold -> bright-yellow while the player can buy
        // here (in a buy zone, or buy-anywhere / a zone-less map) so they notice
        // they can shop — same idea as the C4 slot's plant-zone flash.  ~1.3 Hz.
        vector money_col;
        if (getstatf(STAT_IN_BUYZONE))
        {
            float bz_pulse = 0.5 + 0.5 * sin(cltime * 8);
            money_col = '1 0.85 0.2' + '0 0.15 0.55' * bz_pulse;
        }
        else
            money_col = '0.4 0.9 0.4';
        money_str = HUD_GetMoneyString(cur_money);
        my = g_height - 52 - 22;
        drawstring([20, my], money_str, [18, 18], money_col, 0.9, 0);
        drawfont = prev_money_font;
    }

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
        drawstring([gx, y - 20], gren_str, [16, 16], '0.8 0.7 0.3', 0.85, 0);
    }

    x = g_width - 20 - hud_ammo_cache_width;
    drawstring([x, y], mag_str, [32, 32], '1 1 1', 0.9, 0);

    drawfont = prev_font;
};

// ============================================================
//  Speedometer — horizontal speed display (cl_speedometer 1)
// ============================================================

// Draw a speed readout from a precomputed horizontal speed.  Shared by the alive
// HUD (predicted velocity) and the spectator HUD (spectated body's velocity) so
// cl_speedometer works while spectating — handy for reading bot speeds.
void(float speed) HUD_DrawSpeedometerValue =
{
    if (!cvar("cl_speedometer"))
        return;

    float prev_font = drawfont;
    drawfont = hud_font;

    string speed_str = sprintf("%.0f u/s", speed);
    vector text_size = [24, 24];
    float text_width = stringwidth(speed_str, 0, text_size);
    float x = g_width * 0.5 - text_width * 0.5;
    float y = g_height * 0.55;

    drawstring([x, y], speed_str, text_size, '1 1 1', 0.9, 0);

    drawfont = prev_font;
};

void() HUD_DrawSpeedometer =
{
    if (!cvar("cl_speedometer"))
        return;
    if (!predicted_player || !csqc_prediction_valid)
        return;

    // Horizontal speed only (ignore vertical component)
    vector flat_vel = predicted_player.velocity;
    flat_vel_z = 0;
    HUD_DrawSpeedometerValue(vlen(flat_vel));
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

// Throttled-recompute cache for HUD_DrawNetGraph. Lines[] and widths[]
// are rebuilt at cl_netgraph_fps Hz (default 10) and reused on every
// other frame; the per-frame draw loop just re-blits the cached
// strings. Cuts the per-frame ~6 cvar reads + 6 sprintf builds + 6
// stringwidth calls down to ~2 reads + zero formatting work in
// steady state.
float  ng_cache_last_recompute;
string ng_cache_lines[6];
float  ng_cache_widths[6];
float  ng_cache_panel_w;
float  ng_cache_extrap_master;
float  ng_cache_smooth_enabled;
float  ng_cache_smooth_time;
float  ng_cache_sv_tick;

void() HUD_DrawNetGraph =
{
    if (!cvar("net_graph"))
        return;

    float prev_font = drawfont;
    drawfont = hud_font_mono;

    // --- Sample fps (clframetime) with light EMA smoothing ---
    // Runs every frame so the EMA is fresh; the EMA value itself is
    // displayed via the throttled string-rebuild below.
    if (clframetime > 0)
    {
        float inst_fps = 1.0 / clframetime;
        if (net_graph_ema_fps <= 0)
            net_graph_ema_fps = inst_fps;
        else
            net_graph_ema_fps = net_graph_ema_fps * 0.9 + inst_fps * 0.1;
    }

    // --- Detect new snapshot via serverprevtime, record spacing ---
    // Also runs every frame so we don't miss a snapshot tick.
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

    // --- Throttled recompute (cl_netgraph_fps, default 10) ---
    // Cvar reads + sprintf + stringwidth scan run at most this often;
    // every other frame just re-blits the cached strings + widths.
    // Lines display data that's already smoothed (fps EMA, snap-interval
    // EMA), so 10 Hz refresh is visually identical to per-frame.
    float ng_fps = cvar("cl_netgraph_fps");
    if (ng_fps <= 0) ng_fps = 10;
    if (cltime - ng_cache_last_recompute >= 1.0 / ng_fps)
    {
        ng_cache_last_recompute = cltime;

        ng_cache_sv_tick = serverkeyfloat("sv_mintic");
        if (ng_cache_sv_tick <= 0) ng_cache_sv_tick = 0.015;
        float srv_hz = 1.0 / ng_cache_sv_tick;

        float cl_send = cvar("cl_netfps");

        if (cvar_string("cl_extrap") == "")
            ng_cache_extrap_master = 1;
        else
            ng_cache_extrap_master = cvar("cl_extrap");
        float extrap_grounded = cvar("cl_extrap_grounded");

        float snap_dt_recompute = cltime - net_graph_last_snap_cltime;
        float snap_hz = (net_graph_ema_snap_interval > 0) ? (1.0 / net_graph_ema_snap_interval) : 0;

        ng_cache_smooth_enabled = 1;
        if (cvar_string("cl_extrap_smooth") != "" && !cvar("cl_extrap_smooth"))
            ng_cache_smooth_enabled = 0;
        if (cvar_string("cl_extrap_smooth_time") == "")
            ng_cache_smooth_time = 0.031;
        else
            ng_cache_smooth_time = cvar("cl_extrap_smooth_time");

        ng_cache_lines[0] = sprintf("fps   %4.0f", net_graph_ema_fps);
        ng_cache_lines[1] = sprintf("srv   %4.0f Hz  (%.4fs)", srv_hz, ng_cache_sv_tick);
        ng_cache_lines[2] = sprintf("snd   %4.0f Hz", cl_send);
        ng_cache_lines[3] = sprintf("snap  %4.0f Hz  dt %.3fs", snap_hz, snap_dt_recompute);
        ng_cache_lines[4] = sprintf("extrap %s%s",
                                    ng_cache_extrap_master ? "ON " : "OFF",
                                    extrap_grounded ? "(grounded)" : "");
        ng_cache_lines[5] = sprintf("smooth %s %.3fs",
                                    (ng_cache_smooth_enabled && ng_cache_smooth_time > 0) ? "ON " : "OFF",
                                    ng_cache_smooth_time);

        vector text_size_local = [12, 12];
        ng_cache_panel_w = 0;
        for (float ci = 0; ci < 6; ci++)
        {
            ng_cache_widths[ci] = stringwidth(ng_cache_lines[ci], 0, text_size_local);
            if (ng_cache_widths[ci] > ng_cache_panel_w)
                ng_cache_panel_w = ng_cache_widths[ci];
        }
    }

    // --- Per-frame layout + draw using cached strings/widths ---
    vector text_size = [12, 12];
    float pad = 8;
    float line_h = text_size_y + 2;
    float right_x = g_width - pad;
    float bottom_y = g_height - pad;
    float panel_h = line_h * 6 + 4;
    vector panel_pos = [right_x - ng_cache_panel_w - 6, bottom_y - panel_h];
    drawfill(panel_pos, [ng_cache_panel_w + 8, panel_h], '0 0 0', 0.55, 0);

    // snap_dt_now is fresh per frame so the snap-dt colour reacts
    // immediately to lag spikes even if the cached string is up to
    // 100 ms stale (it'll catch up on the next throttled rebuild).
    float snap_dt_now = cltime - net_graph_last_snap_cltime;

    for (float i = 0; i < 6; i++)
    {
        vector p = [right_x - ng_cache_widths[i] - 2, bottom_y - line_h * (6 - i) + 2];
        vector col;
        col = '1 1 1';
        if (i == 3) col = (snap_dt_now > ng_cache_sv_tick * 2) ? '1 0.5 0.3' : '0.7 1 0.7';
        if (i == 4) col = ng_cache_extrap_master ? '0.7 1 0.7' : '1 0.7 0.7';
        if (i == 5) col = (ng_cache_smooth_enabled && ng_cache_smooth_time > 0) ? '0.7 1 0.7' : '0.8 0.8 0.8';
        drawstring(p, ng_cache_lines[i], text_size, col, 0.95, 0);
    }

    drawfont = prev_font;
};
