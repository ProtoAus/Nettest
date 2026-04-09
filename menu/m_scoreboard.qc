float hud_scoreboard_held;

float HUD_SCOREBOARD_ROW_HEIGHT = 24;
float HUD_SCOREBOARD_HEADER_HEIGHT = 22;
float HUD_SCOREBOARD_TITLE_SIZE = 18;
float HUD_SCOREBOARD_TEXT_SIZE = 12;
float HUD_SCOREBOARD_COLUMN_WIDTH = 280;
float HUD_SCOREBOARD_COLUMN_GAP = 16;
float HUD_SCOREBOARD_OUTER_PADDING = 14;
float HUD_SCOREBOARD_PICTURE_SIZE = 16;

float() HUD_ScoreboardVisible =
{
    return hud_scoreboard_held;
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

    kills_x = pos_x + size_x - 90;
    deaths_x = pos_x + size_x - 62;
    ping_x = pos_x + size_x - 34;

    drawfill(pos, size, '0.08 0.09 0.11', 0.94, 0);
    drawfill(pos, [size_x, HUD_SCOREBOARD_HEADER_HEIGHT, 0], fill_colour, 0.94, 0);
    drawfill(pos, [size_x, 2, 0], border_colour, 1.0, 0);
    drawfill([pos_x, pos_y + size_y - 2, 0], [size_x, 2, 0], border_colour, 1.0, 0);
    drawfill(pos, [2, size_y, 0], border_colour, 1.0, 0);
    drawfill([pos_x + size_x - 2, pos_y, 0], [2, size_y, 0], border_colour, 1.0, 0);

    // Vertically center header text in header area (nudge +1 for font ascender)
    header_text_y = pos_y + (HUD_SCOREBOARD_HEADER_HEIGHT - HUD_SCOREBOARD_TEXT_SIZE) * 0.5 + 1;

    draw_pos_x = pos_x + 12;
    draw_pos_y = header_text_y;
    draw_pos_z = 0;
    drawstring(draw_pos, label, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

    draw_pos_x = kills_x;
    draw_pos_y = header_text_y;
    draw_pos_z = 0;
    drawstring(draw_pos, "K", [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

    draw_pos_x = deaths_x;
    draw_pos_y = header_text_y;
    draw_pos_z = 0;
    drawstring(draw_pos, "D", [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

    draw_pos_x = ping_x;
    draw_pos_y = header_text_y;
    draw_pos_z = 0;
    drawstring(draw_pos, "P", [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

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

            if (row_is_even)
            {
                draw_pos_x = pos_x + 2;
                draw_pos_y = row_y;
                draw_pos_z = 0;
                draw_size_x = size_x - 4;
                draw_size_y = HUD_SCOREBOARD_ROW_HEIGHT;
                draw_size_z = 0;
                drawfill(draw_pos, draw_size, '0.12 0.13 0.16', 0.48, 0);
            }

            draw_pos_x = pos_x + 10;
            draw_pos_y = pic_y;
            draw_pos_z = 0;
            draw_size_x = HUD_SCOREBOARD_PICTURE_SIZE;
            draw_size_y = HUD_SCOREBOARD_PICTURE_SIZE;
            draw_size_z = 0;
            drawpic(draw_pos, HUD_ScoreboardPicturePath(team_id), draw_size, '1 1 1', 1.0, 0);

            draw_pos_x = pos_x + 34;
            draw_pos_y = text_y;
            draw_pos_z = 0;
            drawstring(draw_pos, player_name, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

            frags = getplayerkeyfloat(currentindex, INFOKEY_P_FRAGS, 0);
            deaths = getplayerkeyfloat(currentindex, "deaths", 0);
            ping = getplayerkeyfloat(currentindex, INFOKEY_P_PING, 0);

            draw_pos_x = kills_x;
            draw_pos_y = text_y;
            draw_pos_z = 0;
            drawstring(draw_pos, ftos(frags), [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

            draw_pos_x = deaths_x;
            draw_pos_y = text_y;
            draw_pos_z = 0;
            drawstring(draw_pos, ftos(deaths), [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

            draw_pos_x = ping_x;
            draw_pos_y = text_y;
            draw_pos_z = 0;
            drawstring(draw_pos, ftos(ping), [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '1 1 1', 1.0, 0);

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
    string server_name;
    string map_name;
    string map_timer_str;
    string round_str;
    string info_left;
    string info_right;
    float map_timeleft;
    float map_minutes;
    float map_seconds;
    float cur_round;
    float max_rounds;
    float info_y;
    float text_w;
    float columns_y;

    prev_font = drawfont;
    drawfont = hud_font;

    blue_count = HUD_ScoreboardCountTeamPlayers(TEAM_BLUE);
    red_count = HUD_ScoreboardCountTeamPlayers(TEAM_RED);
    row_count = max(1, max(blue_count, red_count));

    // Header area above columns: server name + info line + separator
    header_height = 54;
    column_height = (row_count * HUD_SCOREBOARD_ROW_HEIGHT) + HUD_SCOREBOARD_HEADER_HEIGHT;
    float top_pad = 10;

    board_width = (HUD_SCOREBOARD_COLUMN_WIDTH * 2) + HUD_SCOREBOARD_COLUMN_GAP + (HUD_SCOREBOARD_OUTER_PADDING * 2);
    board_height = header_height + column_height + top_pad;
    outer_x = (g_width - board_width) * 0.5;
    outer_y = (g_height - board_height) * 0.5;

    // Full-screen dim
    drawfill('0 0 0', [g_width, g_height, 0], '0.01 0.01 0.02', 0.64, 0);

    // Board background + border
    pos_x = outer_x;
    pos_y = outer_y;
    pos_z = 0;
    sz_x = board_width;
    sz_y = board_height;
    sz_z = 0;
    drawfill(pos, sz, '0.08 0.09 0.11', 0.96, 0);
    drawfill(pos, [board_width, 2, 0], '0.35 0.37 0.4', 1.0, 0);
    drawfill([outer_x, outer_y + board_height - 2, 0], [board_width, 2, 0], '0.35 0.37 0.4', 1.0, 0);
    drawfill(pos, [2, board_height, 0], '0.35 0.37 0.4', 1.0, 0);
    drawfill([outer_x + board_width - 2, outer_y, 0], [2, board_height, 0], '0.35 0.37 0.4', 1.0, 0);

    // Server name — centered
    server_name = serverkey("hostname");
    if (server_name == "")
        server_name = "Server";
    title_width = stringwidth(server_name, 1, [HUD_SCOREBOARD_TITLE_SIZE, HUD_SCOREBOARD_TITLE_SIZE, 0]);
    pos_x = outer_x + ((board_width - title_width) * 0.5);
    pos_y = outer_y + 10;
    pos_z = 0;
    drawstring(pos, server_name, [HUD_SCOREBOARD_TITLE_SIZE, HUD_SCOREBOARD_TITLE_SIZE, 0], '1 1 1', 1.0, 0);

    // Gamemode label — top left
    string gamemode_str;
    float gamemode_val = getstatf(STAT_GAMEMODE);
    if (gamemode_val == GAMEMODE_ELIMINATION)
        gamemode_str = "Elimination";
    else
        gamemode_str = "Team Deathmatch";
    pos_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING;
    pos_y = outer_y + 10;
    pos_z = 0;
    drawstring(pos, gamemode_str, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.6 0.7 0.8', 0.8, 0);

    // Info line: map name + time left on left, round on right
    info_y = outer_y + 30;

    map_name = serverkey("mapname");
    if (map_name == "")
        map_name = "unknown";
    map_timeleft = getstatf(STAT_MAPTIMELEFT);
    map_minutes = floor(map_timeleft / 60);
    map_seconds = floor(map_timeleft - map_minutes * 60);
    info_left = sprintf("%s  |  Time Left: %g:%02g", map_name, map_minutes, map_seconds);

    pos_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING;
    pos_y = info_y;
    pos_z = 0;
    drawstring(pos, info_left, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.8 0.8 0.8', 0.9, 0);

    cur_round = getstatf(STAT_ROUNDNUM);
    max_rounds = getstatf(STAT_MAXROUNDS);
    round_str = sprintf("Round: %g / %g", cur_round, max_rounds);
    text_w = stringwidth(round_str, 1, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0]);
    pos_x = outer_x + board_width - HUD_SCOREBOARD_OUTER_PADDING - text_w;
    pos_y = info_y;
    pos_z = 0;
    drawstring(pos, round_str, [HUD_SCOREBOARD_TEXT_SIZE, HUD_SCOREBOARD_TEXT_SIZE, 0], '0.8 0.8 0.8', 0.9, 0);

    // Separator line
    drawfill([outer_x + HUD_SCOREBOARD_OUTER_PADDING, info_y + 16, 0], [board_width - HUD_SCOREBOARD_OUTER_PADDING * 2, 1, 0], '0.35 0.37 0.4', 0.5, 0);

    // Team columns
    columns_y = outer_y + header_height;

    pos_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING;
    pos_y = columns_y;
    pos_z = 0;
    sz_x = HUD_SCOREBOARD_COLUMN_WIDTH;
    sz_y = column_height;
    sz_z = 0;
    HUD_DrawScoreboardColumn("BLUE TEAM", pos, sz, '0.12 0.22 0.5', '0.45 0.7 1', TEAM_BLUE);

    pos_x = outer_x + HUD_SCOREBOARD_OUTER_PADDING + HUD_SCOREBOARD_COLUMN_WIDTH + HUD_SCOREBOARD_COLUMN_GAP;
    pos_y = columns_y;
    pos_z = 0;
    sz_x = HUD_SCOREBOARD_COLUMN_WIDTH;
    sz_y = column_height;
    sz_z = 0;
    HUD_DrawScoreboardColumn("RED TEAM", pos, sz, '0.46 0.1 0.12', '1 0.42 0.42', TEAM_RED);

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
