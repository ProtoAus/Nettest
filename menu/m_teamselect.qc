// Forward declarations (defined in m_scoreboard.qc, compiled later)
float hud_scoreboard_teamselect;
void() HUD_DrawScoreboard;

float team_menu_cursor_active;
float team_menu_join_pending;
float team_menu_forced_open;
float team_menu_hidden;
float team_menu_last_request_serial;
float team_menu_autoclosed_main;  // latch: we've sent togglemenu to close main menu over team select

// Character select state
float team_menu_state;          // 0 = team select, 1 = character select
float team_menu_pending_team;   // which team was picked before char select
float team_menu_hover_model;    // hovered model index (0-3), -1 = none
entity team_menu_preview_ent;   // persistent entity for 3D model preview

// Tracks the last cam_phase we pushed to the server so we only stuffcmd
// when the menu state actually changes.  Initialised to a sentinel value
// that no real phase uses (-1) on first TeamMenuSetCamPhase call.
float team_menu_last_cam_phase;
float team_menu_cam_phase_inited;

void(float new_phase) TeamMenuSetCamPhase =
{
    if (team_menu_cam_phase_inited && new_phase == team_menu_last_cam_phase)
        return;
    team_menu_last_cam_phase = new_phase;
    team_menu_cam_phase_inited = TRUE;
    localcmd(sprintf("cmd cam_phase %d\n", new_phase));
};

float HUD_TEAMSELECT_BIG_TEXT_SIZE = 12;
float HUD_TEAMSELECT_SMALL_TEXT_SIZE = 12;

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
    team_menu_state = 0;

    if (TeamMenuNeedsSelection())
        return;

    team_menu_join_pending = TEAM_NONE;
    team_menu_forced_open = TRUE;
};

void() TeamMenuClose =
{
    team_menu_join_pending = TEAM_NONE;
    team_menu_forced_open = FALSE;
    team_menu_state = 0;

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
        team_menu_state = 0;
    }

    if (TeamMenuNeedsSelection())
        team_menu_forced_open = FALSE;
    else
        team_menu_hidden = FALSE;

    // On connect the engine sometimes leaves the main menu open over the
    // team-select overlay. Close it once so team select shows immediately.
    if (TeamMenuIsOpen() && TeamMenuMainMenuOpen())
    {
        if (!team_menu_autoclosed_main)
        {
            localcmd("togglemenu\n");
            team_menu_autoclosed_main = TRUE;
        }
    }
    else
    {
        team_menu_autoclosed_main = FALSE;
    }

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

// Team select → go to character select instead of joining immediately
void(float team_id) TeamMenuSelect =
{
    float current_team;

    current_team = getstati(STAT_PLAYERTEAM);

    if (team_menu_join_pending != TEAM_NONE)
        return;

    // Transition to character select (even if same team — allows model reselection)
    team_menu_pending_team = team_id;
    team_menu_hover_model = 0;
    team_menu_state = 1;
};

// Character selected — send join command with model index
void(float model_idx) CharacterMenuSelect =
{
    team_menu_join_pending = team_menu_pending_team;

    string team_str;
    if (team_menu_pending_team == TEAM_BLUE)
        team_str = "blue";
    else
        team_str = "red";

    localcmd(sprintf("cmd jointeam %s %d\n", team_str, model_idx));
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

// --- 3D Model Preview ---
// Uses a map-authored "camera" entity tagged Team_Blue_Player (spawnflag 4)
// or Team_Red_Player (spawnflag 8) as the viewport pose — see cl_cameras.qc.
// Falls back to a hardcoded default pose if the map doesn't have one.
void(vector preview_pos, vector preview_size, string mdl_path) DrawCharacterPreview =
{
    if (!team_menu_preview_ent)
    {
        team_menu_preview_ent = spawn();
        team_menu_preview_ent.classname = "char_preview";
        team_menu_preview_ent.solid = SOLID_NOT;
    }

    // Pick the preview camera based on which team we're picking a char for.
    float req_flag;
    if (team_menu_pending_team == TEAM_BLUE)
        req_flag = CAM_FLAG_TEAM_BLUE_PLAYER;
    else
        req_flag = CAM_FLAG_TEAM_RED_PLAYER;

    entity cam = CSQC_GetPreviewCamera(req_flag);

    vector preview_view_origin;
    vector preview_view_angles;
    vector model_origin;
    if (cam != world)
    {
        preview_view_origin  = cam.origin;
        preview_view_angles  = cam.angles;
        // Character model stands at the camera's look target when provided
        // (info_notnull pointed at by .target), else directly in front of it.
        // The info_notnull is meant to sit on the floor — player models are
        // drawn from their midpoint origin, so lift the render position by
        // 32 units so their feet land on the floor.  Aim the camera at the
        // lifted point too, otherwise the camera still points at the floor
        // and the character is framed off the bottom of the preview.
        if (cam.cam_target_origin != '0 0 0')
        {
            model_origin = cam.cam_target_origin + '0 0 32';
            preview_view_angles = vectoangles(model_origin - cam.origin);
            preview_view_angles_z = 0;
        }
        else
        {
            makevectors(cam.angles);
            model_origin = cam.origin + v_forward * 80;
        }
    }
    else
    {
        // Fallback — same numbers as the old hardcoded preview.
        preview_view_origin  = [300, 0, -10];
        preview_view_angles  = [0, 180, 0];
        model_origin = '0 0 0';
    }

    setmodel(team_menu_preview_ent, mdl_path);
    team_menu_preview_ent.frame = 1; // CSANIM_IDLE
    team_menu_preview_ent.origin = model_origin;
    team_menu_preview_ent.angles = [0, time * 40, 0]; // slow rotation
    team_menu_preview_ent.scale = 1;

    // Set up a small 3D viewport for the preview.
    clearscene();
    setproperty(VF_MIN, preview_pos);
    setproperty(VF_SIZE, preview_size);
    // VF_ANGLES uses view-angle convention (+pitch = up).  vectoangles
    // returns +pitch = down, so flip X before handing it to the renderer.
    // Same "Quake pitch flip" used by the chase-cam path in cl_main.qc.
    preview_view_angles_x = -preview_view_angles_x;
    setproperty(VF_ORIGIN, preview_view_origin);
    setproperty(VF_ANGLES, preview_view_angles);
    setproperty(VF_AFOV, 20);                // tight FOV for portrait framing
    addentity(team_menu_preview_ent);
    renderscene();
};

// --- Character Select Screen ---
void() DrawCharacterSelect =
{
    float i;
    float is_blue = (team_menu_pending_team == TEAM_BLUE);
    vector team_col, team_border;
    string team_label;

    if (is_blue)
    {
        team_col = '0.12 0.22 0.5';
        team_border = '0.3 0.5 1';
        team_label = "Blue Team";
    }
    else
    {
        team_col = '0.46 0.1 0.12';
        team_border = '1 0.3 0.35';
        team_label = "Red Team";
    }

    // Dark background (gated on cl_menu_backdrop so it can be disabled).
    if (cvar("cl_menu_backdrop"))
        drawfill('0 0 0', [g_width, g_height, 0], '0.01 0.01 0.02', 0.82, 0);

    // Panel dimensions
    float panel_w = 460;
    float panel_h = 340;
    float px = (g_width - panel_w) * 0.5;
    float py = (g_height - panel_h) * 0.5;

    sui_push_frame([px, py], [panel_w, panel_h]);

    // Panel background
    sui_fill([0, 0], [panel_w, panel_h], '0.06 0.06 0.08', 0.95, 0);
    sui_border_box([0, 0], [panel_w, panel_h], 2, team_border, 0.8, 0);

    // Title
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
    sui_text([0, 12], [14, 14, 0], sprintf("Choose %s Character", team_label),
             '1 1 1', 1.0, 0);

    // Left side: 4 character buttons
    float btn_w = 180;
    float btn_h = 48;
    float btn_x = 20;
    float btn_y = 44;
    float btn_spacing = 8;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    for (i = 0; i < TEAM_MODEL_COUNT; i++)
    {
        string btn_id = sprintf("cs_char_%d", i);
        vector btn_pos = [btn_x, btn_y + i * (btn_h + btn_spacing)];

        vector btn_col = team_col;
        if (sui_is_hovered(btn_id))
        {
            btn_col = btn_col + (team_border * 0.15);
            team_menu_hover_model = i;
        }
        if (sui_is_held(btn_id))
            btn_col = btn_col * 0.85;

        sui_push_frame(btn_pos, [btn_w, btn_h]);
        sui_fill([0, 0], [btn_w, btn_h], btn_col, 0.92, 0);
        sui_border_box([0, 0], [btn_w, btn_h], 2, team_border, 0.8, 0);
        sui_action_element([0, 0], [btn_w, btn_h], btn_id, sui_noop);

        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
        string char_name = is_blue ? team_blue_names[i] : team_red_names[i];
        sui_text([0, 0], [12, 12, 0], char_name, '1 1 1', 1.0, 0);
        sui_pop_frame();

        if (sui_is_clicked(btn_id))
            CharacterMenuSelect(i);
    }

    // Back button
    float back_y = btn_y + TEAM_MODEL_COUNT * (btn_h + btn_spacing) + 8;
    vector back_col = '0.25 0.25 0.3';
    if (sui_is_hovered("cs_back"))
        back_col = '0.35 0.35 0.4';
    if (sui_is_held("cs_back"))
        back_col = back_col * 0.85;

    sui_push_frame([btn_x, back_y], [btn_w, 36]);
    sui_fill([0, 0], [btn_w, 36], back_col, 0.92, 0);
    sui_border_box([0, 0], [btn_w, 36], 1, '0.5 0.5 0.5', 0.6, 0);
    sui_action_element([0, 0], [btn_w, 36], "cs_back", sui_noop);
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, 0], [10, 10, 0], "Back", '0.8 0.8 0.8', 1.0, 0);
    sui_pop_frame();

    if (sui_is_clicked("cs_back"))
        team_menu_state = 0;

    // Secret Sini button — top right of panel
    vector sini_col = '0.2 0.15 0.25';
    if (sui_is_hovered("cs_sini"))
    {
        sini_col = '0.35 0.25 0.45';
        team_menu_hover_model = 5; // special: sini
    }
    if (sui_is_held("cs_sini"))
        sini_col = sini_col * 0.85;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_push_frame([panel_w - 70, 8], [60, 24]);
    sui_fill([0, 0], [60, 24], sini_col, 0.85, 0);
    sui_border_box([0, 0], [60, 24], 1, '0.5 0.3 0.6', 0.6, 0);
    sui_action_element([0, 0], [60, 24], "cs_sini", sui_noop);
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, 0], [8, 8, 0], "Sini", '0.7 0.5 0.8', 1.0, 0);
    sui_pop_frame();

    if (sui_is_clicked("cs_sini"))
        CharacterMenuSelect(5); // model index 5 = sini

    sui_pop_frame();

    // Right side: 3D model preview (drawn outside SUI using raw renderscene)
    float preview_w = 200;
    float preview_h = 280;
    float preview_x = px + panel_w - preview_w - 20;
    float preview_y = py + 44;

    // Preview border
    drawfill([preview_x - 1, preview_y - 1], [preview_w + 2, preview_h + 2], '0.2 0.2 0.25', 0.8, 0);

    float hover_idx = team_menu_hover_model;
    string preview_mdl;
    if (hover_idx == 5)
        preview_mdl = "models/player/sini.mdl";
    else if (team_menu_pending_team == TEAM_BLUE)
        preview_mdl = team_blue_models[bound(0, hover_idx, TEAM_MODEL_COUNT - 1)];
    else
        preview_mdl = team_red_models[bound(0, hover_idx, TEAM_MODEL_COUNT - 1)];

    DrawCharacterPreview([preview_x, preview_y], [preview_w, preview_h], preview_mdl);

    sui_set_default_kb_focus("cs_char_0");
};

void() TeamMenuDraw =
{
    if (!TeamMenuIsOpen())
        return;

    if (TeamMenuMainMenuOpen())
        return;

    TeamMenuUpdateCursorState();

    // Keep the server's camera phase in sync with the menu state.  The world
    // view during char-select rides the Team_Blue/Team_Red-flagged cameras;
    // the small preview viewport in DrawCharacterPreview independently uses
    // Team_Blue_Player/Team_Red_Player cameras via CSQC_GetPreviewCamera.
    if (team_menu_state == 1 && team_menu_pending_team == TEAM_BLUE)
        TeamMenuSetCamPhase(CAM_PHASE_TEAM_BLUE);
    else if (team_menu_state == 1 && team_menu_pending_team == TEAM_RED)
        TeamMenuSetCamPhase(CAM_PHASE_TEAM_RED);
    else
        TeamMenuSetCamPhase(CAM_PHASE_NEUTRAL);

    if (team_menu_join_pending != TEAM_NONE)
    {
        // Show "Joining..." overlay while waiting for server
        string status_text;
        if (team_menu_join_pending == TEAM_BLUE)
            status_text = "Joining Blue Team...";
        else
            status_text = "Joining Red Team...";

        if (cvar("cl_menu_backdrop"))
            drawfill('0 0 0', [g_width, g_height, 0], '0.01 0.01 0.02', 0.72, 0);
        float prev_font = drawfont;
        drawfont = hud_font;
        vector tsz = [HUD_TEAMSELECT_BIG_TEXT_SIZE, HUD_TEAMSELECT_BIG_TEXT_SIZE, 0];
        float tw = stringwidth(status_text, 1, tsz);
        drawstring([g_width * 0.5 - tw * 0.5, g_height * 0.5, 0], status_text, tsz, '1 1 1', 1.0, 0);
        drawfont = prev_font;
        return;
    }

    if (team_menu_state == 1)
    {
        // Character select screen
        DrawCharacterSelect();
        return;
    }

    // Draw scoreboard-style team select with join buttons
    hud_scoreboard_teamselect = TRUE;
    HUD_DrawScoreboard();
    hud_scoreboard_teamselect = FALSE;
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
        {
            // ESC in character select → back to team select
            if (team_menu_state == 1)
                team_menu_state = 0;
            else
                TeamMenuClose();
        }
        return TRUE;
    }

    if (scanx == K_F10 || bound_command == "quit")
        return FALSE;

    sui_input_event(evtype, scanx, chary, devid);
    return TRUE;
};
