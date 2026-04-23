// ============================================================
//  client/cl_killfeed.qc  -  Top-left kill feed HUD
//
//  One entry per kill, added when CSQC_EVENT_KILLFEED arrives.
//  Holds for KILLFEED_HOLD_TIME, then fades over KILLFEED_FADE_TIME
//  and vacates its slot.  Entries stack top-down; expired slots are
//  compacted so the visible list stays top-aligned.
//
//  Segments per line:
//    [attacker name]  [connector]  [victim name]  [suffix]
//
//  For suicide / fall deaths there is no attacker; only the victim
//  name and the suffix render.
// ============================================================

const float KILLFEED_MAX       = 5;
const float KILLFEED_HOLD_TIME = 5.0;
const float KILLFEED_FADE_TIME = 1.0;
const float KILLFEED_LINE_SIZE = 12;
const float KILLFEED_LINE_GAP  = 4;
const float KILLFEED_MARGIN    = 8;

// kf_highlight values — used by HUD_DrawKillFeed to paint a row backdrop
// when the local player is directly involved.
const float KILLFEED_HL_NONE     = 0;
const float KILLFEED_HL_YOUR_KILL  = 1;   // you killed someone else
const float KILLFEED_HL_YOUR_DEATH = 2;   // you died (any cause, inc. suicide)

string kf_atk_name[KILLFEED_MAX];
vector kf_atk_col[KILLFEED_MAX];
string kf_connector[KILLFEED_MAX];
string kf_vic_name[KILLFEED_MAX];
vector kf_vic_col[KILLFEED_MAX];
string kf_suffix[KILLFEED_MAX];
float  kf_spawn[KILLFEED_MAX];
float  kf_highlight[KILLFEED_MAX];

vector KillFeed_TeamColour(float slot)
{
    if (slot == KILLFEED_NO_ATTACKER)
        return '0.85 0.85 0.85';

    string team_value = getplayerkeyvalue(slot, "modteam");
    float team_id = (team_value != "") ? stof(team_value) : TEAM_NONE;

    if (team_id == TEAM_BLUE) return '0.45 0.7 1';
    if (team_id == TEAM_RED)  return '1 0.42 0.42';
    return '0.85 0.85 0.85';
}

string KillFeed_PlayerName(float slot)
{
    if (slot == KILLFEED_NO_ATTACKER)
        return "";
    string n = getplayerkeyvalue(slot, INFOKEY_P_NAME);
    if (n == "") n = "player";
    return n;
}

void KillFeed_Add(string atk_name, vector atk_col,
                  string connector,
                  string vic_name, vector vic_col,
                  string suffix,
                  float highlight)
{
    // Find first empty slot; if full, shift everything up one (drop oldest).
    float i;
    float target = -1;
    for (i = 0; i < KILLFEED_MAX; i++)
    {
        if (!kf_spawn[i])
        {
            target = i;
            break;
        }
    }

    if (target < 0)
    {
        for (i = 0; i < KILLFEED_MAX - 1; i++)
        {
            kf_atk_name[i]  = kf_atk_name[i + 1];
            kf_atk_col[i]   = kf_atk_col[i + 1];
            kf_connector[i] = kf_connector[i + 1];
            kf_vic_name[i]  = kf_vic_name[i + 1];
            kf_vic_col[i]   = kf_vic_col[i + 1];
            kf_suffix[i]    = kf_suffix[i + 1];
            kf_spawn[i]     = kf_spawn[i + 1];
            kf_highlight[i] = kf_highlight[i + 1];
        }
        target = KILLFEED_MAX - 1;
    }

    kf_atk_name[target]  = atk_name;
    kf_atk_col[target]   = atk_col;
    kf_connector[target] = connector;
    kf_vic_name[target]  = vic_name;
    kf_vic_col[target]   = vic_col;
    kf_suffix[target]    = suffix;
    kf_spawn[target]     = cltime;
    kf_highlight[target] = highlight;
}

void KillFeed_Clear()
{
    float i;
    for (i = 0; i < KILLFEED_MAX; i++)
        kf_spawn[i] = 0;
}

// Called from CSQC_Parse_Event on CSQC_EVENT_KILLFEED.
void KillFeed_Parse()
{
    float atk_slot = readbyte();
    float vic_slot = readbyte();
    float cause    = readbyte();
    float weapon   = readbyte();
    float headshot = readbyte();

    string atk_name = KillFeed_PlayerName(atk_slot);
    string vic_name = KillFeed_PlayerName(vic_slot);
    vector atk_col  = KillFeed_TeamColour(atk_slot);
    vector vic_col  = KillFeed_TeamColour(vic_slot);
    string connector = "";
    string suffix    = "";

    if (cause == KILL_CAUSE_WEAPON)
    {
        connector = " killed ";
        suffix = strcat(" /w ", Weapon_DisplayName(weapon));
        if (headshot)
            suffix = strcat(suffix, " (HeadShot)");
    }
    else if (cause == KILL_CAUSE_FRIENDLYFIRE)
    {
        // Tint both names warning-orange so the TK is visually distinct
        // even at a glance.
        atk_col = '1 0.5 0.3';
        vic_col = '1 0.5 0.3';
        connector = " TeamKilled ";
        suffix = strcat(" /w ", Weapon_DisplayName(weapon));
        if (headshot)
            suffix = strcat(suffix, " (HeadShot)");
    }
    else if (cause == KILL_CAUSE_FALL)
    {
        // Drop attacker segment entirely.
        atk_name = "";
        suffix = " dies to fall damage";
    }
    else  // KILL_CAUSE_SUICIDE
    {
        atk_name = "";
        suffix = " suicides";
    }

    // Your-kill / your-death highlight.  Death takes priority over kill
    // (matters only for suicide: atk == vic == local → treat as death).
    float highlight = KILLFEED_HL_NONE;
    if (vic_slot == player_localnum)
        highlight = KILLFEED_HL_YOUR_DEATH;
    else if (atk_slot == player_localnum && atk_slot != vic_slot)
        highlight = KILLFEED_HL_YOUR_KILL;

    KillFeed_Add(atk_name, atk_col, connector, vic_name, vic_col, suffix, highlight);
}

// Draws a shadowed text segment; returns pixel width so the caller can
// advance to the next segment.
float KillFeed_DrawSegment(vector pos, string text, vector col, float alpha)
{
    vector sz = [KILLFEED_LINE_SIZE, KILLFEED_LINE_SIZE, 0];
    drawstring(pos + '1 1 0', text, sz, '0 0 0', alpha * 0.5, 0);
    drawstring(pos, text, sz, col, alpha, 0);
    return stringwidth(text, 1, sz);
}

void HUD_DrawKillFeed()
{
    float i;
    float display_index = 0;

    // Render in the same typeface as the scoreboard and top-of-HUD text.
    float prev_font = drawfont;
    drawfont = hud_font;

    for (i = 0; i < KILLFEED_MAX; i++)
    {
        if (!kf_spawn[i])
            continue;

        float age = cltime - kf_spawn[i];
        if (age > KILLFEED_HOLD_TIME + KILLFEED_FADE_TIME)
        {
            kf_spawn[i] = 0;
            continue;
        }

        float alpha = (age < KILLFEED_HOLD_TIME)
            ? 1.0
            : 1.0 - (age - KILLFEED_HOLD_TIME) / KILLFEED_FADE_TIME;

        float y = KILLFEED_MARGIN + display_index * (KILLFEED_LINE_SIZE + KILLFEED_LINE_GAP);
        float x = KILLFEED_MARGIN;
        vector pos = [x, y, 0];

        // Highlight backdrop for rows involving the local player.
        if (kf_highlight[i] != KILLFEED_HL_NONE)
        {
            vector sz = [KILLFEED_LINE_SIZE, KILLFEED_LINE_SIZE, 0];
            string fullline = strcat(kf_atk_name[i], kf_connector[i],
                                     kf_vic_name[i], kf_suffix[i]);
            float bg_w = stringwidth(fullline, 1, sz) + 8;
            float bg_h = KILLFEED_LINE_SIZE + 4;
            vector bg_col = (kf_highlight[i] == KILLFEED_HL_YOUR_KILL)
                ? '0.85 0.7 0.15'    // gold — you got the kill
                : '0.45 0.05 0.05';  // dark blood red — you died
            drawfill([x - 4, y - 2, 0], [bg_w, bg_h, 0], bg_col, alpha * 0.75, 0);
        }

        if (kf_atk_name[i] != "")
        {
            pos_x += KillFeed_DrawSegment(pos, kf_atk_name[i], kf_atk_col[i], alpha);
            pos_x += KillFeed_DrawSegment(pos, kf_connector[i], '1 1 1', alpha);
        }
        pos_x += KillFeed_DrawSegment(pos, kf_vic_name[i], kf_vic_col[i], alpha);
        KillFeed_DrawSegment(pos, kf_suffix[i], '1 1 1', alpha);

        display_index++;
    }

    drawfont = prev_font;
}
