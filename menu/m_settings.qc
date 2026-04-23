vector binds_scroll;
string settings_sensitivity_text;
float settings_sensitivity_cursor;
string settings_fov_text;
float settings_fov_cursor;

// Settings menu tab state.  0 = General, 1 = Crosshair.
float settings_tab;

// Crosshair colour component state — parsed from cl_crosshaircolour on first
// open per-session, written back whenever a slider moves.
float crosshair_cx_r;
float crosshair_cx_g;
float crosshair_cx_b;
float crosshair_seeded;

void() settings_seed_crosshair_colour =
{
	if (crosshair_seeded)
		return;
	string s = cvar_string("cl_crosshaircolour");
	tokenize(s);
	crosshair_cx_r = stof(argv(0));
	crosshair_cx_g = stof(argv(1));
	crosshair_cx_b = stof(argv(2));
	// If the cvar was greyscale ("0.5") or empty, fall back to green.
	if (crosshair_cx_r == 0 && crosshair_cx_g == 0 && crosshair_cx_b == 0)
	{ crosshair_cx_r = 0; crosshair_cx_g = 1; crosshair_cx_b = 0; }
	crosshair_seeded = TRUE;
};

void() settings_apply_crosshair_colour =
{
	// %.1f not %g — slider step math rounds to 0.0-1.0 in 0.1 steps but
	// binary floats still carry 0.89999998 noise; quantize on write so
	// config.cfg stores "0.9 0.1 0.0" not "0.89999998 0.099999994 0".
	cvar_set("cl_crosshaircolour", sprintf("%.1f %.1f %.1f", crosshair_cx_r, crosshair_cx_g, crosshair_cx_b));
};

// Draws a dark preview box and renders the configured crosshair centered in it.
// Matches HUD_DrawCrosshair (cl_crosshair.qc:200-237): thickness is halved and
// bounds applied.  Uses sui_fill so coords are frame-local, matching the
// sui_border_box around the preview.
void(vector pos, vector size) DrawCrosshairPreview =
{
	// Preview background + border (both frame-local)
	sui_fill(pos, size, '0.05 0.05 0.08', 0.85, 0);
	sui_border_box(pos, size, 1, MENU_BORDER, 0.5, 0);

	// Match HUD_DrawCrosshair bounds:
	//   length    clamped to 1..64
	//   thickness scaled * 0.5 and clamped to 0.5..8
	//   gap       clamped to 0..64  (no velocity bonus in menu preview)
	float len = bound(1,   cvar("cl_crosshairlength"),        64);
	float thk = bound(0.5, cvar("cl_crosshairthickness") * 0.5, 8);
	float gap = bound(0,   cvar("cl_crosshairgap"),           64);

	vector col = [crosshair_cx_r, crosshair_cx_g, crosshair_cx_b];
	float cx = pos_x + size_x * 0.5;
	float cy = pos_y + size_y * 0.5;

	// Top / bottom / left / right bars
	sui_fill([cx - thk * 0.5, cy - gap - len], [thk, len], col, 1, 0);
	sui_fill([cx - thk * 0.5, cy + gap],       [thk, len], col, 1, 0);
	sui_fill([cx - gap - len, cy - thk * 0.5], [len, thk], col, 1, 0);
	sui_fill([cx + gap,       cy - thk * 0.5], [len, thk], col, 1, 0);
};

// Wrapper around cvar_slider that returns TRUE if the slider's value changed
// this frame.  Used for the R/G/B sliders so we can write the composed cvar.
void(vector pos, vector sz, vector mms, string label, string fmt, __inout float value) settings_rgb_slider =
{
	float old = value;
	sui_push_frame(pos, [sz_x, sz_y * 0.5 - 4]);
	sui_text([0, 0], MENU_TEXT_SMALL, label, MENU_TEXT_1, 1, 0);
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
	sui_text([0, 0], MENU_TEXT_SMALL, sprintf(fmt, value), MENU_TEXT_1, 1, 0);
	sui_pop_frame();
	my_slider(strcat("rgb_", label), [pos_x, pos_y + sz_y * 0.5], [sz_x, sz_y * 0.5], mms, value);
	if (value != old)
		settings_apply_crosshair_colour();
};

void() settings_menu =
{
	vector pos = [0, 0];
	vector size = [430, 320];
	float pad = 10;
	float gap = 12;
	float left_width = 182;
	float right_x = pad + left_width + gap;
	float right_width = size_x - right_x - pad;
	float xpos;
	float ypos;

	sui_push_frame(pos, size);

	menu_panel_bg(size, 4);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, 8], MENU_TEXT_MEDIUM, "Settings", MENU_TEXT_1, 1, 0);

	menu_seed_numeric_text("sensitivity", "%.1f", settings_sensitivity_text, settings_sensitivity_cursor);
	menu_seed_numeric_text("fov", "%.0f", settings_fov_text, settings_fov_cursor);
	settings_seed_crosshair_colour();

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

	xpos = pad;
	ypos = 28;

	// --- Tab bar ---
	{
		float tab_w = (left_width - 4) * 0.5;
		vector active_col   = MENU_BUTTON_RETURN;
		vector active_brd   = MENU_BUTTON_RETURN_BORDER;
		vector inactive_col = MENU_BG_DARK;
		vector inactive_brd = MENU_BORDER;

		if (my_button_colored("tab_general", [xpos, ypos], [tab_w, 20], "General",
			settings_tab == 0 ? active_col : inactive_col,
			settings_tab == 0 ? active_brd : inactive_brd))
			settings_tab = 0;

		if (my_button_colored("tab_crosshair", [xpos + tab_w + 4, ypos], [tab_w, 20], "Crosshair",
			settings_tab == 1 ? active_col : inactive_col,
			settings_tab == 1 ? active_brd : inactive_brd))
			settings_tab = 1;
	}
	ypos += 26;

	if (settings_tab == 0)
	{
		// --- General tab ---
		float current_fov;
		float old_fov;
		float current_sensitivity;
		float old_sensitivity;

		cvar_slider([xpos, ypos], [left_width, 32], [0, 1, 10], "volume", "Volume", "%.1f");
		ypos += 32 + 4;

		current_fov = cvar("fov");
		old_fov = current_fov;
		sui_push_frame([xpos, ypos], [left_width, 12]);
		sui_text([0, 0], MENU_TEXT_SMALL, "Field of View", MENU_TEXT_1, 1, 0);
		sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
		sui_text([0, 0], MENU_TEXT_SMALL, sprintf("%.0f", current_fov), MENU_TEXT_1, 1, 0);
		sui_pop_frame();
		my_slider("fov_sldr", [xpos, ypos + 16], [left_width, 16], [60, 120, 60], current_fov);
		if (current_fov != old_fov)
		{
			cvar_set("fov", sprintf("%.0f", current_fov));
			settings_fov_text = sprintf("%.0f", current_fov);
			settings_fov_cursor = strlen(settings_fov_text);
		}
		ypos += 16 + 16 + 8;
		menu_numeric_cvar_field("FOV", "fov_field", "fov_set", [xpos, ypos], left_width, 6, "fov", [60, 120], "%.0f", settings_fov_text, settings_fov_cursor);
		ypos += 20 + 10;

		old_sensitivity = cvar("sensitivity");
		cvar_slider([xpos, ypos], [left_width, 32], [0.10, 10, 99], "sensitivity", "Sensitivity", "%.1f");
		current_sensitivity = cvar("sensitivity");
		if (current_sensitivity != old_sensitivity)
		{
			settings_sensitivity_text = sprintf("%.1f", current_sensitivity);
			settings_sensitivity_cursor = strlen(settings_sensitivity_text);
		}
		ypos += 32 + 6;
		menu_numeric_cvar_field("Sensitivity", "sens_field", "sens_set", [xpos, ypos], left_width, 8, "sensitivity", [0.10, 10], "%.1f", settings_sensitivity_text, settings_sensitivity_cursor);
		ypos += 22;

		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Video", MENU_TEXT_1, 1, 0);
		ypos += 16;
		my_button("fs_btn", [xpos, ypos], [left_width, 20], "Fullscreen") ? localcmd("vid_fullscreen 2; vid_restart\n") : 0;
		ypos += 24;
		my_button("wn_btn", [xpos, ypos], [left_width, 20], "Windowed") ? localcmd("vid_fullscreen 0; vid_width 1024; vid_height 768; vid_restart\n") : 0;
	}
	else
	{
		// --- Crosshair tab ---
		cvar_slider([xpos, ypos], [left_width, 28], [1, 32, 32], "cl_crosshairlength", "Length", "%.0f");
		ypos += 30;

		cvar_slider([xpos, ypos], [left_width, 28], [0, 8, 16], "cl_crosshairthickness", "Thickness", "%.0f");
		ypos += 30;

		cvar_slider([xpos, ypos], [left_width, 28], [0, 32, 32], "cl_crosshairgap", "Gap", "%.0f");
		ypos += 34;

		settings_rgb_slider([xpos, ypos], [left_width, 28], [0, 1, 10], "Red",   "%.1f", crosshair_cx_r);
		ypos += 30;
		settings_rgb_slider([xpos, ypos], [left_width, 28], [0, 1, 10], "Green", "%.1f", crosshair_cx_g);
		ypos += 30;
		settings_rgb_slider([xpos, ypos], [left_width, 28], [0, 1, 10], "Blue",  "%.1f", crosshair_cx_b);
		ypos += 30;
	}

	// --- Right panel: Controls (General) or Preview (Crosshair) ---
	ypos = 36;
	xpos = right_x;

	if (settings_tab == 0)
	{
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Controls", MENU_TEXT_1, 1, 0);
		ypos += 16;
		bind_list("bindlist", [xpos, ypos], [right_width, 230], binds_scroll);
		ypos += 230 + 8;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Click a binding to rebind.", MENU_TEXT_2, 0.85, 0);
		ypos += 10;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "ESC cancels, BACKSPACE clears.", MENU_TEXT_2, 0.85, 0);
	}
	else
	{
		float preview_size = min(right_width, 180);
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Preview", MENU_TEXT_1, 1, 0);
		ypos += 16;
		DrawCrosshairPreview([xpos, ypos], [preview_size, preview_size]);
		ypos += preview_size + 8;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Changes save on Back / ESC.", MENU_TEXT_2, 0.85, 0);
	}

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_END]);
	if (my_button("stg_back", [8, -8], [80, 20], "Back")) { Menu_SaveConfig(); current_menu = MENU_MAIN; }

	sui_set_default_kb_focus(settings_tab == 0 ? "sens_field" : "rgb_Red");

	if (sui_listen_back())
	{ Menu_SaveConfig(); current_menu = MENU_MAIN; }

	sui_pop_frame();
};
