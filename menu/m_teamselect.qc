float team_menu_cursor_active;
float team_menu_join_pending;
float team_menu_forced_open;
float team_menu_hidden;
float team_menu_last_request_serial;

float HUD_TEAMSELECT_BIG_TEXT_SIZE = 16;
float HUD_TEAMSELECT_SMALL_TEXT_SIZE = 8;

float() TeamMenuMainMenuOpen =
{
    return cvar("_nettest_menu_active") > 0;
};

float() TeamMenuNeedsSelection =
{
    return getstati(STAT_PLAYERTEAM) <= TEAM_NONE;
};

float() TeamMenuIsOpen =
{
    return (TeamMenuNeedsSelection() && !team_menu_hidden) || team_menu_forced_open;
};

void() TeamMenuOpen =
{
    team_menu_hidden = FALSE;

    if (TeamMenuNeedsSelection())
        return;

    team_menu_join_pending = TEAM_NONE;
    team_menu_forced_open = TRUE;
};

void() TeamMenuClose =
{
    team_menu_join_pending = TEAM_NONE;
    team_menu_forced_open = FALSE;

    if (TeamMenuNeedsSelection())
    {
        team_menu_hidden = TRUE;
        return;
    }

    team_menu_hidden = FALSE;
};

void() TeamMenuUpdateCursorState =
{
    float request_serial;

    request_serial = getstati(STAT_TEAMMENU_REQUEST);
    if (request_serial != team_menu_last_request_serial)
    {
        team_menu_last_request_serial = request_serial;
        if (request_serial > 0)
            TeamMenuOpen();
    }

    if (team_menu_join_pending != TEAM_NONE
        && !TeamMenuNeedsSelection()
        && getstati(STAT_PLAYERTEAM) == team_menu_join_pending)
    {
        team_menu_forced_open = FALSE;
        team_menu_join_pending = TEAM_NONE;
    }

    if (TeamMenuNeedsSelection())
        team_menu_forced_open = FALSE;
    else
        team_menu_hidden = FALSE;

    if (TeamMenuIsOpen() && !TeamMenuMainMenuOpen())
    {
        in_menu = MENU_JOIN;

        if (!team_menu_cursor_active)
        {
            setcursormode(TRUE, "gfx/xhair", [16, 16], cvar("vid_conautoscale"));
            team_menu_cursor_active = TRUE;
        }
        return;
    }

    if (team_menu_cursor_active)
    {
        setcursormode(FALSE);
        team_menu_cursor_active = FALSE;
    }

    if (in_menu == MENU_JOIN)
        in_menu = MENU_NONE;

    if (TeamMenuIsOpen())
        return;

    team_menu_join_pending = TEAM_NONE;
};

void(float team_id) TeamMenuSelect =
{
    float current_team;

    current_team = getstati(STAT_PLAYERTEAM);

    if (team_menu_join_pending != TEAM_NONE)
        return;

    if (!TeamMenuNeedsSelection() && team_id == current_team)
    {
        TeamMenuClose();
        return;
    }

    team_menu_join_pending = team_id;

    if (team_id == TEAM_BLUE)
        localcmd("cmd jointeam blue\n");
    else if (team_id == TEAM_RED)
        localcmd("cmd jointeam red\n");
};

float(string id, vector pos, vector size, string title, string subtitle, vector fill_colour, vector border_colour) TeamMenuButton =
{
    float clicked;
    vector base_colour;

    base_colour = fill_colour;
    if (sui_is_hovered(id))
        base_colour = base_colour + (border_colour * 0.15);
    if (sui_is_held(id))
        base_colour = base_colour * 0.85;

    sui_push_frame(pos, size);
    sui_fill([0, 0], size, base_colour, 0.92, 0);
    sui_border_box([0, 0], size, 2, border_colour, 1.0, 0);
    sui_action_element([0, 0], size, id, sui_noop);

    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, -14], [HUD_TEAMSELECT_BIG_TEXT_SIZE, HUD_TEAMSELECT_BIG_TEXT_SIZE, 0], title, '1 1 1', 1.0, 0);
    sui_text([0, 16], [HUD_TEAMSELECT_SMALL_TEXT_SIZE, HUD_TEAMSELECT_SMALL_TEXT_SIZE, 0], subtitle, '0.8 0.8 0.8', 1.0, 0);
    sui_pop_frame();

    clicked = sui_is_clicked(id);
    return clicked;
};

void() TeamMenuDraw =
{
    vector panel_pos;
    vector panel_size;
    float clicked_blue;
    float clicked_red;
    string status_text;

    if (!TeamMenuIsOpen())
        return;

    if (TeamMenuMainMenuOpen())
        return;

    TeamMenuUpdateCursorState();

    panel_pos = [g_width * 0.5 - 250, g_height * 0.5 - 160];
    panel_size = [500, 320];

    sui_fill([0, 0], [g_width, g_height], '0.01 0.01 0.02', 0.72, 0);

    sui_push_frame(panel_pos, panel_size);
    sui_fill([0, 0], panel_size, '0.08 0.09 0.11', 0.96, 0);
    sui_border_box([0, 0], panel_size, 2, '0.35 0.37 0.4', 1.0, 0);

    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
    sui_text([0, 28], [HUD_TEAMSELECT_BIG_TEXT_SIZE, HUD_TEAMSELECT_BIG_TEXT_SIZE, 0], "SELECT TEAM", '1 1 1', 1.0, 0);
    sui_text([0, 64], [HUD_TEAMSELECT_SMALL_TEXT_SIZE, HUD_TEAMSELECT_SMALL_TEXT_SIZE, 0], "Choose a side to enter the match", '0.8 0.8 0.8', 1.0, 0);

    if (team_menu_join_pending == TEAM_NONE)
    {
        sui_set_default_kb_focus("team_blue");
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

        clicked_blue = TeamMenuButton("team_blue", [40, 108], [190, 120], "BLUE TEAM", "Blue spawn", '0.12 0.22 0.5', '0.45 0.7 1');
        clicked_red = TeamMenuButton("team_red", [270, 108], [190, 120], "RED TEAM", "Red spawn", '0.46 0.1 0.12', '1 0.42 0.42');

        if (clicked_blue)
            TeamMenuSelect(TEAM_BLUE);
        if (clicked_red)
            TeamMenuSelect(TEAM_RED);

        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_END]);
        sui_text([0, -34], [HUD_TEAMSELECT_SMALL_TEXT_SIZE, HUD_TEAMSELECT_SMALL_TEXT_SIZE, 0], "Move left/right + attack or click", '0.74 0.76 0.8', 1.0, 0);
    }
    else
    {
        if (team_menu_join_pending == TEAM_BLUE)
            status_text = "Joining Blue Team...";
        else
            status_text = "Joining Red Team...";

        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
        sui_text([0, 18], [HUD_TEAMSELECT_SMALL_TEXT_SIZE, HUD_TEAMSELECT_SMALL_TEXT_SIZE, 0], status_text, '1 1 1', 1.0, 0);
    }

    sui_pop_frame();
};

float(float evtype, float scanx, float chary, float devid) TeamMenuInputEvent =
{
    string bound_command;

    if (!TeamMenuIsOpen())
        return FALSE;

    if (TeamMenuMainMenuOpen())
        return FALSE;

    bound_command = getkeybind(scanx);
    if (scanx == K_ESCAPE || bound_command == "togglemenu")
    {
        if (evtype == IE_KEYDOWN)
            TeamMenuClose();
        return TRUE;
    }

    if (scanx == K_F10 || bound_command == "quit")
        return FALSE;

    sui_input_event(evtype, scanx, chary, devid);
    return TRUE;
};
