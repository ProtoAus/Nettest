// Forward declarations (defined in m_scoreboard.qc, compiled later)
float hud_scoreboard_teamselect;
void() HUD_DrawScoreboard;
void() HUD_ScoreboardSnapHidden;     // snap-hide the slide/fade animation (no fade-out tail)

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

// True only when connected to our mod's server.  worldspawn pushes
// `serverinfo modname nettest` so this key is set on every map our
// server hosts; vanilla QW servers leave it empty.  Used to gate the
// team menu off entirely when our client connects to a non-mod server
// (the menu hijacks cursor + input waiting on STAT_PLAYERTEAM, which
// vanilla doesn't push, so without this gate the player gets stuck
// in the menu forever and never spawns).
float() TeamMenu_IsModServer =
{
    return serverkey("modname") == "nettest";
};

float() TeamMenuIsOpen =
{
    if (!TeamMenu_IsModServer())
        return FALSE;
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

// Forward decl — defined immediately below.  Needed because TeamMenuSelect
// invokes it on the sv_playerselect fast path.
void(float model_idx) CharacterMenuSelect;

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

    // sv_playerselect: main-menu picker owns model choice.  Skip
    // Phase 1 and join immediately with the cvar-stored player_model
    // _index.  CharacterMenuSelect reads team_menu_pending_team to
    // build the "blue"/"red" command string, so the assignment above
    // is required.
    if (serverkeyfloat("sv_playerselect", 0) > 0)
    {
        float idx = cvar("cl_player_model_choice");
        if (idx < 0) idx = 7;        // numberK fallback
        CharacterMenuSelect(idx);
        return;
    }

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

    // Skip the scoreboard's fade-out tail when the team menu closes
    // post-join — the user just confirmed a model and is about to
    // spawn, so the picker should vanish instantly rather than play
    // the going-away animation.  Snapping sb_anim_progress to 0 means
    // the next time HUD_DrawScoreboard sees TeamMenuIsOpen() flip to
    // false, the bail-out branch fires immediately with no fade ticks.
    HUD_ScoreboardSnapHidden();
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

    // No camera-distance reflection here.  Authored cameras (cam +
    // info_notnull) sit at the position the mapper intended; doubling
    // origin' = 2*origin - model would mirror the camera through the
    // model's plane, throwing the camera into walls behind the
    // authored position — the "void overlay" / "in the wall" symptom.
    // Synthesised cameras already place themselves at the correct
    // viewport distance (CAM_SYNTH_BACK_125 = 125 units, picked to
    // frame a full player in the resized panel).  If a specific
    // authored camera ever feels too close, fix it in the .map.

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

// --- FFA Character Select Screen ---
// All 8 models in a single panel, two columns (blue 0-3 left, red 0-3 right)
// + one shared 3D preview on the right. No "Back" button (FFA skips Phase 0
// entirely so there's nowhere to back to). Click sends the appropriate
// blue/red team command based on which side the picked model belongs to,
// keeping the backend team field populated for clean mode-switching.
void() DrawCharacterSelectFFA =
{
    float i;

    // Dark background (gated on cl_menu_backdrop so it can be disabled).
    if (cvar("cl_menu_backdrop"))
        drawfill('0 0 0', [g_width, g_height, 0], '0.01 0.01 0.02', 0.82, 0);

    // Layout constants. Button column dimensions drive panel height +
    // preview height so everything stays aligned: bottom of last button
    // == bottom of preview == (panel_h - bottom_pad).
    float btn_w = 120;
    float btn_h = 44;
    float col_gap = 8;
    float row_gap = 8;
    float btn_y0 = 44;
    float btn_left_pad = 20;
    float bottom_pad = 16;
    float btn_area_h = (4 * btn_h) + (3 * row_gap);   // 4 rows × (h + gap) − 1 trailing gap

    // Panel dimensions. panel_h sized to button column + header + bottom
    // padding so there's no empty bottom strip. panel_w fits two button
    // columns + inter-section gap + preview + right padding.
    float preview_w = 200;
    float preview_h = btn_area_h;
    float section_gap = 12;
    float right_pad = 20;
    float panel_w = btn_left_pad + (2 * btn_w) + col_gap + section_gap + preview_w + right_pad;
    float panel_h = btn_y0 + btn_area_h + bottom_pad;

    float px = (g_width - panel_w) * 0.5;
    float py = (g_height - panel_h) * 0.5;

    // Neutral border (no team allegiance shown in FFA).
    vector neutral_border = '0.55 0.55 0.6';

    sui_push_frame([px, py], [panel_w, panel_h]);

    sui_fill([0, 0], [panel_w, panel_h], '0.06 0.06 0.08', 0.95, 0);
    sui_border_box([0, 0], [panel_w, panel_h], 2, neutral_border, 0.8, 0);

    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
    sui_text([0, 12], [14, 14, 0], "Choose Your Character",
             '1 1 1', 1.0, 0);

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    // Two columns of 4 buttons each: blue side (0..3) on the left, red
    // side (4..7) on the right. Indices map directly to the model_idx
    // we send to the server.
    float blue_col_x = btn_left_pad;
    float red_col_x  = blue_col_x + btn_w + col_gap;

    vector blue_col_fill   = '0.12 0.22 0.5';
    vector blue_col_border = '0.3 0.5 1';
    vector red_col_fill    = '0.46 0.1 0.12';
    vector red_col_border  = '1 0.3 0.35';

    for (i = 0; i < 8; i++)
    {
        float is_blue_btn = (i < 4);
        float row = is_blue_btn ? i : (i - 4);
        float bx = is_blue_btn ? blue_col_x : red_col_x;
        float by = btn_y0 + row * (btn_h + row_gap);

        vector fill   = is_blue_btn ? blue_col_fill   : red_col_fill;
        vector border = is_blue_btn ? blue_col_border : red_col_border;

        string btn_id = sprintf("ffacs_char_%d", i);
        vector btn_col = fill;
        if (sui_is_hovered(btn_id))
        {
            btn_col = btn_col + (border * 0.15);
            team_menu_hover_model = i;
        }
        if (sui_is_held(btn_id))
            btn_col = btn_col * 0.85;

        sui_push_frame([bx, by], [btn_w, btn_h]);
        sui_fill([0, 0], [btn_w, btn_h], btn_col, 0.92, 0);
        sui_border_box([0, 0], [btn_w, btn_h], 2, border, 0.8, 0);
        sui_action_element([0, 0], [btn_w, btn_h], btn_id, sui_noop);

        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
        string char_name = is_blue_btn ? team_blue_names[row]
                                       : team_red_names[row];
        sui_text([0, 0], [12, 12, 0], char_name, '1 1 1', 1.0, 0);
        sui_pop_frame();
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

        if (sui_is_clicked(btn_id))
        {
            // Translate unified 0..7 into the right team + 0..3 model_idx.
            // CharacterMenuSelect reads team_menu_pending_team to build
            // the "blue"/"red" command string, so set it here just before
            // dispatching.
            if (is_blue_btn)
            {
                team_menu_pending_team = TEAM_BLUE;
                CharacterMenuSelect(row);
            }
            else
            {
                team_menu_pending_team = TEAM_RED;
                CharacterMenuSelect(row);
            }
        }
    }

    sui_pop_frame();

    // Right side: 3D model preview. Camera-flag selection follows the
    // hovered model's side, so the preview cam swaps cleanly when the
    // user moves between the blue and red columns. Top-aligned with the
    // button column and the same height — no overhang past the buttons.
    float preview_x = px + panel_w - preview_w - right_pad;
    float preview_y = py + btn_y0;

    drawfill([preview_x - 1, preview_y - 1], [preview_w + 2, preview_h + 2], '0.2 0.2 0.25', 0.8, 0);

    float hover_idx = team_menu_hover_model;
    float hover_is_blue = (hover_idx < 4);
    string preview_mdl;
    if (hover_is_blue)
        preview_mdl = team_blue_models[bound(0, hover_idx, TEAM_MODEL_COUNT - 1)];
    else
        preview_mdl = team_red_models[bound(0, hover_idx - 4, TEAM_MODEL_COUNT - 1)];

    // Latch pending_team to match the hovered side so DrawCharacterPreview's
    // camera-flag check picks the right preview cam (CAM_FLAG_TEAM_BLUE_PLAYER
    // for indices 0-3, CAM_FLAG_TEAM_RED_PLAYER for 4-7).
    team_menu_pending_team = hover_is_blue ? TEAM_BLUE : TEAM_RED;

    DrawCharacterPreview([preview_x, preview_y], [preview_w, preview_h], preview_mdl);

    sui_set_default_kb_focus("ffacs_char_0");
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

    // Chickenman button — sits to the LEFT of the Sini button
    vector chk_col = '0.25 0.2 0.1';
    if (sui_is_hovered("cs_chickenman"))
    {
        chk_col = '0.45 0.35 0.18';
        team_menu_hover_model = 6; // special: chickenman
    }
    if (sui_is_held("cs_chickenman"))
        chk_col = chk_col * 0.85;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_push_frame([panel_w - 138, 8], [60, 24]);
    sui_fill([0, 0], [60, 24], chk_col, 0.85, 0);
    sui_border_box([0, 0], [60, 24], 1, '0.6 0.45 0.2', 0.6, 0);
    sui_action_element([0, 0], [60, 24], "cs_chickenman", sui_noop);
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, 0], [8, 8, 0], "Chicken", '0.95 0.8 0.4', 1.0, 0);
    sui_pop_frame();

    if (sui_is_clicked("cs_chickenman"))
        CharacterMenuSelect(6); // model index 6 = chickenman

    // NumberK button — sits to the LEFT of the Chickenman button
    vector nk_col = '0.1 0.18 0.25';
    if (sui_is_hovered("cs_numberk"))
    {
        nk_col = '0.18 0.32 0.45';
        team_menu_hover_model = 7; // special: numberK
    }
    if (sui_is_held("cs_numberk"))
        nk_col = nk_col * 0.85;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_push_frame([panel_w - 206, 8], [60, 24]);
    sui_fill([0, 0], [60, 24], nk_col, 0.85, 0);
    sui_border_box([0, 0], [60, 24], 1, '0.3 0.55 0.75', 0.6, 0);
    sui_action_element([0, 0], [60, 24], "cs_numberk", sui_noop);
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, 0], [8, 8, 0], "NumberK", '0.55 0.8 1', 1.0, 0);
    sui_pop_frame();

    if (sui_is_clicked("cs_numberk"))
        CharacterMenuSelect(7); // model index 7 = numberK

    // Kilmer button — sits to the LEFT of the NumberK button
    vector km_col = '0.2 0.15 0.1';
    if (sui_is_hovered("cs_kilmer"))
    {
        km_col = '0.4 0.28 0.18';
        team_menu_hover_model = 8; // special: kilmer
    }
    if (sui_is_held("cs_kilmer"))
        km_col = km_col * 0.85;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_push_frame([panel_w - 274, 8], [60, 24]);
    sui_fill([0, 0], [60, 24], km_col, 0.85, 0);
    sui_border_box([0, 0], [60, 24], 1, '0.7 0.5 0.3', 0.6, 0);
    sui_action_element([0, 0], [60, 24], "cs_kilmer", sui_noop);
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, 0], [8, 8, 0], "Kilmer", '1 0.85 0.6', 1.0, 0);
    sui_pop_frame();

    if (sui_is_clicked("cs_kilmer"))
        CharacterMenuSelect(8); // model index 8 = kilmer

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
    else if (hover_idx == 6)
        preview_mdl = "models/player/chickenman/chickenman.iqm";
    else if (hover_idx == 7)
        preview_mdl = "models/player/numberk/numberK.iqm";
    else if (hover_idx == 8)
        preview_mdl = "models/player/kilmer/kilmer.iqm";
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

    // FFA collapses the menu to a single character-select panel — no
    // "Join Blue / Join Red" Phase 0. Force state=1 each frame so the
    // FFA branch always lands on the character grid.
    // Unified-team modes (FFA + Bhop) collapse the menu to a single
    // character-select panel — no Phase 0. Force state=1 each frame so
    // the unified branch always lands on the character grid.
    float in_ffa = Gamemode_HasUnifiedTeams();
    if (in_ffa)
        team_menu_state = 1;

    // sv_playerselect: when on, the main-menu picker owns the model
    // choice and the in-game character grid should never appear.
    //
    // Team mode is already handled in TeamMenuSelect (clicking blue/red
    // auto-commits with the cvar pick), but FFA never goes through that
    // path — it has no Phase 0, so it lands here with state==1 and
    // would normally render the character grid. Fire the auto-commit
    // here, gated on join_pending so we only do it once.
    if (in_ffa && serverkeyfloat("sv_playerselect", 0) > 0
        && team_menu_join_pending == TEAM_NONE)
    {
        float auto_idx = cvar("cl_player_model_choice");
        if (auto_idx < 0) auto_idx = 7;     // numberK fallback
        // FFA backend team is implementation detail (any model works
        // either way under the special-index path 5/6/7/8) — pick
        // BLUE so CharacterMenuSelect builds a valid jointeam string.
        team_menu_pending_team = TEAM_BLUE;
        CharacterMenuSelect(auto_idx);
        // Fall through to draw the "Joining..." overlay block below.
    }

    // Keep the server's camera phase in sync with the menu state.  The world
    // view during char-select rides the Team_Blue/Team_Red-flagged cameras;
    // the small preview viewport in DrawCharacterPreview independently uses
    // Team_Blue_Player/Team_Red_Player cameras via CSQC_GetPreviewCamera.
    // FFA stays on NEUTRAL — the per-hover side flip in DrawCharacterSelectFFA
    // would otherwise spam cam_phase changes as the user moves the mouse.
    if (in_ffa)
        TeamMenuSetCamPhase(CAM_PHASE_NEUTRAL);
    else if (team_menu_state == 1 && team_menu_pending_team == TEAM_BLUE)
        TeamMenuSetCamPhase(CAM_PHASE_TEAM_BLUE);
    else if (team_menu_state == 1 && team_menu_pending_team == TEAM_RED)
        TeamMenuSetCamPhase(CAM_PHASE_TEAM_RED);
    else
        TeamMenuSetCamPhase(CAM_PHASE_NEUTRAL);

    if (team_menu_join_pending != TEAM_NONE)
    {
        // Show "Joining..." overlay while waiting for server. In FFA the
        // backend team is implementation detail (every model is fair game),
        // so just say "Joining..." rather than naming a team.
        string status_text;
        if (in_ffa)
            status_text = "Joining...";
        else if (team_menu_join_pending == TEAM_BLUE)
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

    if (in_ffa)
    {
        DrawCharacterSelectFFA();
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
            // ESC universally closes the team-select window in any
            // gamemode and any phase. Previously Phase 1 (character
            // select) in team mode went back to Phase 0 — but FFA has
            // no Phase 0 to back to (state is force-pinned to 1), and
            // users expect ESC to be a consistent "get me out of here"
            // exit everywhere. The on-screen Back button in team mode's
            // DrawCharacterSelect still navigates back to Phase 0 for
            // users who explicitly want it.
            //
            // ESC closes the team picker WITHOUT also popping the main
            // menu — earlier behaviour stacked them open with one
            // press, but users expect ESC to mean "back out one step"
            // not "back out one step and also open something else".
            // The user can still manually open the main menu via ESC
            // afterward if they want it.
            TeamMenuClose();
        }
        return TRUE;
    }

    if (scanx == K_F10 || bound_command == "quit")
        return FALSE;

    sui_input_event(evtype, scanx, chary, devid);
    return TRUE;
};
