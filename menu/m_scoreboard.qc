float hud_scoreboard_held;
float hud_scoreboard_teamselect;   // TRUE when drawing as team select screen

float HUD_SCOREBOARD_ROW_HEIGHT = 24;
float HUD_SCOREBOARD_HEADER_HEIGHT = 22;
float HUD_SCOREBOARD_TITLE_SIZE = 18;
float HUD_SCOREBOARD_TEXT_SIZE = 12;
float HUD_SCOREBOARD_COLUMN_WIDTH = 220;
float HUD_SCOREBOARD_COLUMN_GAP = 16;
float HUD_SCOREBOARD_OUTER_PADDING = 14;
float HUD_SCOREBOARD_PICTURE_SIZE = 16;
float HUD_SCOREBOARD_SHADOW_OFFSET = 1;

float() HUD_ScoreboardVisible =
{
    return hud_scoreboard_held;
};

// Drop-shadowed text helper
void(vector pos, string text, vector sz, vector col, float alpha) HUD_ShadowString =
{
    drawstring(pos + '1 1 0' * HUD_SCOREBOARD_SHADOW_OFFSET, text, sz, '0 0 0', alpha * 0.5, 0);
    drawstring(pos, text, sz, col, alpha, 0);
};

float(float player_index) HUD_ScoreboardPlayerTeam =
{
    float team_id;
    float topcolor;
    float bottomcolor;
    string team_value;
    string topcolor_value;
    string bottomcolor_value;

    team_value = getplayerkeyvalue(player_index, "modteam");
    if (team_value != "")
    {
        team_id = stof(team_value);
        if (team_id != TEAM_NONE)
            return team_id;
    }

    topcolor = -1;
    bottomcolor = -1;
    topcolor_value = getplayerkeyvalue(player_index, INFOKEY_P_TOPCOLOR);
    bottomcolor_value = getplayerkeyvalue(player_index, INFOKEY_P_BOTTOMCOLOR);
    if (topcolor_value != "")
        topcolor = stof(topcolor_value);
    if (bottomcolor_value != "")
        bottomcolor = stof(bottomcolor_value);

    if (topcolor == 11 && bottomcolor == 2)
        return TEAM_BLUE;

    if (topcolor == 14 && bottomcolor == 5)
        return TEAM_RED;

    return TEAM_NONE;
};

string(float team_id) HUD_ScoreboardPicturePath =
{
    if (team_id == TEAM_RED)
        return "gfx/displaypicturered.png";

    if (team_id == TEAM_BLUE)
        return "gfx/displaypictureblue.png";

    return "gfx/displaypicture.png";
};

float(float team_id) HUD_ScoreboardCountTeamPlayers =
{
    float currentindex;
    float count;
    string player_name;

    count = 0;
    currentindex = 0;
    while (currentindex <= maxclients)
    {
        player_name = getplayerkeyvalue(currentindex, INFOKEY_P_NAME);
        if (player_name != "" && HUD_ScoreboardPlayerTeam(currentindex) == team_id)
            count = count + 1;

        currentindex = currentindex + 1;
    }

    return count;
};

void(string label, vector pos, vector size, vector fill_colour, vector border_colour, float team_id) HUD_DrawScoreboardColumn =
{
    float currentindex;
    float row_index;
    float row_is_even;
    float row_y;
    float text_y;
    float pic_y;
    string player_name;
    float frags;
    float deaths;
    float ping;
    vector draw_pos;
    vector draw_size;
    float kills_x;
    float deaths_x;
    float ping_x;
    float header_text_y;
    float is_local;
    vector text_sz;

    text_sz = [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0];

    kills_x = pos_x + size_x - 90;
    deaths_x = pos_x + size_x - 62;
    ping_x = pos_x + size_x - 34;

    drawfill(pos, size, '0.08 0.09 0.11', 0.94, 0);
    drawfill(pos, [size_x, HUD_SCOREBOARD_HEADER_HEIGHT, 0], fill_colour, 0.94, 0);
    drawfill(pos, [size_x, 2, 0], border_colour, 1.0, 0);
    drawfill([pos_x, pos_y + size_y - 2, 0], [size_x, 2, 0], border_colour, 1.0, 0);
    drawfill(pos, [2, size_y, 0], border_colour, 1.0, 0);
    drawfill([pos_x + size_x - 2, pos_y, 0], [2, size_y, 0], border_colour, 1.0, 0);

    // Header — use bold font
    drawfont = hud_font;
    header_text_y = pos_y + (HUD_SCOREBOARD_HEADER_HEIGHT - HUD_SCOREBOARD_TEXT_SIZE) * 0.5 + 3;

    HUD_ShadowString([pos_x + 12, header_text_y, 0], label, text_sz, '1 1 1', 1.0);
    HUD_ShadowString([kills_x, header_text_y, 0], "K", text_sz, '1 1 1', 1.0);
    HUD_ShadowString([deaths_x, header_text_y, 0], "D", text_sz, '1 1 1', 1.0);
    HUD_ShadowString([ping_x, header_text_y, 0], "P", text_sz, '1 1 1', 1.0);

    // Player rows — use regular font for names and stats
    drawfont = hud_font_regular;

    row_index = 0;
    row_is_even = TRUE;
    currentindex = 0;
    while (currentindex <= maxclients)
    {
        player_name = getplayerkeyvalue(currentindex, INFOKEY_P_NAME);
        if (player_name != "" && HUD_ScoreboardPlayerTeam(currentindex) == team_id)
        {
            row_y = pos_y + HUD_SCOREBOARD_HEADER_HEIGHT + (row_index * HUD_SCOREBOARD_ROW_HEIGHT);
            text_y = row_y + (HUD_SCOREBOARD_ROW_HEIGHT - HUD_SCOREBOARD_TEXT_SIZE) * 0.5;
            pic_y = row_y + (HUD_SCOREBOARD_ROW_HEIGHT - HUD_SCOREBOARD_PICTURE_SIZE) * 0.5 - 1;

            is_local = (currentindex + 1 == player_localentnum);
            float is_dead = getplayerkeyfloat(currentindex, "dead", 0);

            // Row background
            if (is_dead)
            {
                // Dead — dark red/brown tint so the row visibly reads as "out"
                drawfill([pos_x + 2, row_y, 0], [size_x - 4, HUD_SCOREBOARD_ROW_HEIGHT, 0], '0.18 0.05 0.05', 0.55, 0);
            }
            else if (is_local)
            {
                // Local player — dark green highlight
                drawfill([pos_x + 2, row_y, 0], [size_x - 4, HUD_SCOREBOARD_ROW_HEIGHT, 0], '0.08 0.22 0.08', 0.6, 0);
            }
            else if (row_is_even)
            {
                drawfill([pos_x + 2, row_y, 0], [size_x - 4, HUD_SCOREBOARD_ROW_HEIGHT, 0], '0.12 0.13 0.16', 0.48, 0);
            }

            // Dead players dim everything on their row (picture, name, stats)
            // to about 40%; otherwise full brightness.
            float row_alpha = is_dead ? 0.4 : 1.0;

            // Team picture
            drawpic([pos_x + 10, pic_y, 0], HUD_ScoreboardPicturePath(team_id), [HUD_SCOREBOARD_PICTURE_SIZE, HUD_SCOREBOARD_PICTURE_SIZE, 0], '1 1 1', row_alpha, 0);

            // Player name
            vector name_col = is_local ? '0.7 1 0.7' : '1 1 1';
            HUD_ShadowString([pos_x + 34, text_y, 0], player_name, text_sz, name_col, row_alpha);

            // Stats
            frags = getplayerkeyfloat(currentindex, INFOKEY_P_FRAGS, 0);
            deaths = getplayerkeyfloat(currentindex, "deaths", 0);
            ping = getplayerkeyfloat(currentindex, INFOKEY_P_PING, 0);

            HUD_ShadowString([kills_x, text_y, 0], ftos(frags), text_sz, '1 1 1', row_alpha);
            HUD_ShadowString([deaths_x, text_y, 0], ftos(deaths), text_sz, '1 1 1', row_alpha);
            HUD_ShadowString([ping_x, text_y, 0], ftos(ping), text_sz, '1 1 1', row_alpha);

            row_index = row_index + 1;
            row_is_even = !row_is_even;
        }

        currentindex = currentindex + 1;
    }
};

void() HUD_DrawScoreboard =
{
    float blue_count;
    float red_count;
    float row_count;
    float board_width;
    float board_height;
    float column_height;
    float header_height;
    float outer_x;
    float outer_y;
    float title_width;
    vector pos;
    vector sz;
    float prev_font;
    string title_text;
    string map_name;
    string map_timer_str;
    string round_str;
    float map_timeleft;
    float map_minutes;
    float map_seconds;
    float cur_round;
    float max_rounds;
    float info_y;
    float text_w;
    float columns_y;
    float join_btn_height;

    prev_font = drawfont;
    drawfont = hud_font;

    blue_count = HUD_ScoreboardCountTeamPlayers(TEAM_BLUE);
    red_count = HUD_ScoreboardCountTeamPlayers(TEAM_RED);
    row_count = max(1, max(blue_count, red_count));

    header_height = 40;
    join_btn_height = 0;   // buttons go outside the board now
    column_height = (row_count * HUD_SCOREBOARD_ROW_HEIGHT) + HUD_SCOREBOARD_HEADER_HEIGHT;
    float top_pad = 10;

    // Count spectators for the bottom section
    float spec_count = 0;
    float si;
    for (si = 0; si < maxclients; si++)
    {
        if (HUD_ScoreboardPlayerTeam(si) == TEAM_SPEC)
        {
            string sn = getplayerkeyvalue(si, INFOKEY_P_NAME);
            if (sn != "")
                spec_count++;
        }
    }
    float spec_section_height = (spec_count > 0) ? 14 : 0;

    board_width = (HUD_SCOREBOARD_COLUMN_WIDTH * 2) + HUD_SCOREBOARD_COLUMN_GAP + (HUD_SCOREBOARD_OUTER_PADDING * 2);
    board_height = header_height + column_height + top_pad + join_btn_height + spec_section_height;
    outer_x = (g_width - board_width) * 0.5;
    outer_y = (g_height - board_height) * 0.5;

    // Full-screen dim (gated on cl_menu_backdrop so it can be disabled).
    if (cvar("cl_menu_backdrop"))
        drawfill('0 0 0', [g_width, g_height, 0], '0.01 0.01 0.02', 0.64, 0);

    // Board drop shadow
    drawfill([outer_x + 4, outer_y + 4, 0], [board_width, board_height, 0], '0 0 0', 0.35, 0);

    // Board background + border
    pos = [outer_x, outer_y, 0];
    sz = [board_width, board_height, 0];
    drawfill(pos, sz, '0.08 0.09 0.11', 0.96, 0);
    drawfill(pos, [board_width, 2, 0], '0.35 0.37 0.4', 1.0, 0);
    drawfill([outer_x, outer_y + board_height - 2, 0], [board_width, 2, 0], '0.35 0.37 0.4', 1.0, 0);
    drawfill(pos, [2, board_height, 0], '0.35 0.37 0.4', 1.0, 0);
    drawfill([outer_x + board_width - 2, outer_y, 0], [2, board_height, 0], '0.35 0.37 0.4', 1.0, 0);

    // Title — "Select a Team" when in team select mode, else server name
    if (hud_scoreboard_teamselect)
        title_text = "Select a Team";
    else
    {
        title_text = serverkey("hostname");
        if (title_text == "")
            title_text = "Server";
    }
    title_width = stringwidth(title_text, 1, [HUD_SCOREBOARD_TITLE_SIZE, HUD_SCOREBOARD_TITLE_SIZE, 0]);
    HUD_ShadowString([outer_x + ((board_width - title_width) * 0.5), outer_y + 6, 0],
        title_text, [HUD_SCOREBOARD_TITLE_SIZE, HUD_SCOREBOARD_TITLE_SIZE, 0], '1 1 1', 1.0);

    // Gamemode label
    string gamemode_str;
    float gamemode_val = getstatf(STAT_GAMEMODE);
    if (gamemode_val == GAMEMODE_ELIMINATION)
        gamemode_str = "Elimination";
    else
        gamemode_str = "Team Deathmatch";
    text_w = stringwidth(gamemode_str, 1, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0]);
    HUD_ShadowString([outer_x + ((board_width - text_w) * 0.5), outer_y + 24, 0],
        gamemode_str, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.6 0.7 0.8', 0.8);

    // Time left — top right
    map_timeleft = getstatf(STAT_MAPTIMELEFT);
    map_minutes = floor(map_timeleft / 60);
    map_seconds = floor(map_timeleft - map_minutes * 60);
    map_timer_str = sprintf("%g:%02g", map_minutes, map_seconds);
    text_w = stringwidth(map_timer_str, 1, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0]);
    HUD_ShadowString([outer_x + board_width - HUD_SCOREBOARD_OUTER_PADDING - text_w, outer_y + 10, 0],
        map_timer_str, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.8 0.8 0.8', 0.9);

    // Info line: map name on left, round on right
    info_y = outer_y + 24;
    map_name = serverkey("mapname");
    if (map_name == "")
        map_name = serverkey("map");
    if (map_name == "")
        map_name = infokey(world, "mapname");
    if (map_name == "")
        map_name = infokey(world, "map");
    if (map_name == "")
        map_name = "unknown";
    HUD_ShadowString([outer_x + HUD_SCOREBOARD_OUTER_PADDING, info_y, 0],
        map_name, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.8 0.8 0.8', 0.9);

    cur_round = getstatf(STAT_ROUNDNUM);
    max_rounds = getstatf(STAT_MAXROUNDS);
    round_str = sprintf("Round: %g / %g", cur_round, max_rounds);
    text_w = stringwidth(round_str, 1, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0]);
    HUD_ShadowString([outer_x + board_width - HUD_SCOREBOARD_OUTER_PADDING - text_w, info_y, 0],
        round_str, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.8 0.8 0.8', 0.9);

    // Team columns
    columns_y = outer_y + header_height;

    float blue_col_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING;
    float red_col_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING + HUD_SCOREBOARD_COLUMN_WIDTH + HUD_SCOREBOARD_COLUMN_GAP;

    {
        float bs = getstatf(STAT_BLUE_SCORE);
        float rs = getstatf(STAT_RED_SCORE);
        string blue_label = sprintf("BLUE TEAM - %.0f", bs);
        string red_label = sprintf("RED TEAM - %.0f", rs);

        HUD_DrawScoreboardColumn(blue_label,
            [blue_col_x, columns_y, 0],
            [HUD_SCOREBOARD_COLUMN_WIDTH, column_height, 0],
            '0.12 0.22 0.5', '0.45 0.7 1', TEAM_BLUE);

        HUD_DrawScoreboardColumn(red_label,
            [red_col_x, columns_y, 0],
            [HUD_SCOREBOARD_COLUMN_WIDTH, column_height, 0],
            '0.46 0.1 0.12', '1 0.42 0.42', TEAM_RED);
    }

    // --- "In Spectate:" section at the bottom of the board ---
    if (spec_count > 0)
    {
        string spec_names = "";
        float n;
        for (n = 0; n < maxclients; n++)
        {
            if (HUD_ScoreboardPlayerTeam(n) == TEAM_SPEC)
            {
                string pname = getplayerkeyvalue(n, INFOKEY_P_NAME);
                if (pname != "")
                {
                    if (spec_names != "")
                        spec_names = strcat(spec_names, ", ");
                    spec_names = strcat(spec_names, pname);
                }
            }
        }

        string spec_line = strcat("In Spectate: ", spec_names);
        vector spec_sz = [12, 12, 0];
        float spec_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING;
        float spec_y = outer_y + board_height - 18;
        drawstring([spec_x + 1, spec_y + 1], spec_line, spec_sz, '0 0 0', 0.4, 0);
        drawstring([spec_x, spec_y], spec_line, spec_sz, '0.6 0.6 0.6', 0.75, 0);
    }

    // Team select join buttons — placed UNDER the scoreboard board
    if (hud_scoreboard_teamselect)
    {
        float btn_y = outer_y + board_height + 8;
        float btn_h = 30;
        float btn_text_sz = 14;
        vector btn_sz = [HUD_SCOREBOARD_COLUMN_WIDTH, btn_h, 0];

        drawfont = hud_font;   // EB font for buttons

        vector btn_text_size = [btn_text_sz, btn_text_sz, 0];
        float blue_tw = stringwidth("Join Blue Team", 1, btn_text_size);
        float red_tw = stringwidth("Join Red Team", 1, btn_text_size);
        float blue_tx = blue_col_x + (HUD_SCOREBOARD_COLUMN_WIDTH - blue_tw) * 0.5;
        float red_tx = red_col_x + (HUD_SCOREBOARD_COLUMN_WIDTH - red_tw) * 0.5;
        float btn_text_y = btn_y + (btn_h - btn_text_sz) * 0.5;

        // Blue button box shadow
        drawfill([blue_col_x + 3, btn_y + 3, 0], btn_sz, '0 0 0', 0.3, 0);
        // Blue join button
        sui_push_frame([blue_col_x, btn_y], btn_sz);
        {
            vector btn_col = sui_is_hovered("ts_join_blue") ? '0.18 0.32 0.6' : '0.12 0.22 0.5';
            if (sui_is_held("ts_join_blue")) btn_col = btn_col * 0.85;
            sui_fill([0, 0], btn_sz, btn_col, 0.92, 0);
            sui_border_box([0, 0], btn_sz, 2, '0.45 0.7 1', 1.0, 0);
            sui_action_element([0, 0], btn_sz, "ts_join_blue", sui_noop);
        }
        sui_pop_frame();
        // Text with drop shadow (drawn outside sui_push_frame so coordinates are absolute)
        HUD_ShadowString([blue_tx, btn_text_y, 0], "Join Blue Team", btn_text_size, '1 1 1', 1.0);

        if (sui_is_clicked("ts_join_blue"))
            TeamMenuSelect(TEAM_BLUE);

        // Red button box shadow
        drawfill([red_col_x + 3, btn_y + 3, 0], btn_sz, '0 0 0', 0.3, 0);
        // Red join button
        sui_push_frame([red_col_x, btn_y], btn_sz);
        {
            vector btn_col_r = sui_is_hovered("ts_join_red") ? '0.56 0.18 0.2' : '0.46 0.1 0.12';
            if (sui_is_held("ts_join_red")) btn_col_r = btn_col_r * 0.85;
            sui_fill([0, 0], btn_sz, btn_col_r, 0.92, 0);
            sui_border_box([0, 0], btn_sz, 2, '1 0.42 0.42', 1.0, 0);
            sui_action_element([0, 0], btn_sz, "ts_join_red", sui_noop);
        }
        sui_pop_frame();
        HUD_ShadowString([red_tx, btn_text_y, 0], "Join Red Team", btn_text_size, '1 1 1', 1.0);

        if (sui_is_clicked("ts_join_red"))
            TeamMenuSelect(TEAM_RED);

        sui_set_default_kb_focus("ts_join_blue");
    }

    drawfont = prev_font;
};

float(float evtype, float scanx, float chary, float devid) HUD_ScoreboardInputEvent =
{
    string cmd;

    if (evtype != IE_KEYDOWN && evtype != IE_KEYUP)
        return FALSE;

    cmd = getkeybind(scanx);
    if (scanx != K_TAB && cmd != "+showscores" && cmd != "showscores")
        return FALSE;

    if (evtype == IE_KEYDOWN)
        hud_scoreboard_held = TRUE;
    else
        hud_scoreboard_held = FALSE;

    return TRUE;
};
