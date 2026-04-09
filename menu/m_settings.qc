vector binds_scroll;
string settings_sensitivity_text;
float settings_sensitivity_cursor;
string settings_fov_text;
float settings_fov_cursor;

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
	float current_fov;
	float old_fov;
	float current_sensitivity;
	float old_sensitivity;

	sui_push_frame(pos, size);

	sui_fill([0, 0], size, MENU_BG, 0.75, 0);
	sui_border_box([0, 0], size, 2, MENU_BORDER, 0.3, 0);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, 4], MENU_TEXT_MEDIUM, "Settings", MENU_TEXT_1, 1, 0);

	menu_seed_numeric_text("sensitivity", "%.2f", settings_sensitivity_text, settings_sensitivity_cursor);
	menu_seed_numeric_text("fov", "%.0f", settings_fov_text, settings_fov_cursor);

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

	xpos = pad;
	ypos = 36;

	cvar_slider([xpos, ypos], [left_width, 32], [0, 1, 100], "volume", "Volume", "%.2f");
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
	cvar_slider([xpos, ypos], [left_width, 32], [0.10, 10, 99], "sensitivity", "Sensitivity", "%.2f");
	current_sensitivity = cvar("sensitivity");
	if (current_sensitivity != old_sensitivity)
	{
		settings_sensitivity_text = sprintf("%.2f", current_sensitivity);
		settings_sensitivity_cursor = strlen(settings_sensitivity_text);
	}
	ypos += 32 + 6;
	menu_numeric_cvar_field("Sensitivity", "sens_field", "sens_set", [xpos, ypos], left_width, 8, "sensitivity", [0.10, 10], "%.2f", settings_sensitivity_text, settings_sensitivity_cursor);
	ypos += 22;

	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Video", MENU_TEXT_1, 1, 0);
	ypos += 16;
	my_button("fs_btn", [xpos, ypos], [left_width, 20], "Fullscreen") ? localcmd("vid_fullscreen 2; vid_restart\n") : 0;
	ypos += 24;
	my_button("wn_btn", [xpos, ypos], [left_width, 20], "Windowed") ? localcmd("vid_fullscreen 0; vid_width 1024; vid_height 768; vid_restart\n") : 0;
	ypos += 24;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Window can be resized.", MENU_TEXT_1, 0.8, 0);

	ypos = 36;
	xpos = right_x;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Controls", MENU_TEXT_1, 1, 0);
	ypos += 16;
	bind_list("bindlist", [xpos, ypos], [right_width, 230], binds_scroll);
	ypos += 230 + 8;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Click a binding to rebind.", MENU_TEXT_2, 0.85, 0);
	ypos += 10;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "ESC cancels, BACKSPACE clears.", MENU_TEXT_2, 0.85, 0);

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_END]);
	my_button("stg_back", [8, -8], [80, 20], "Back") ? current_menu = MENU_MAIN : 0;

	sui_set_default_kb_focus("sens_field");

	if (sui_listen_back())
		current_menu = MENU_MAIN;

	sui_pop_frame();
};
