strbuf create_server_maps;
float create_server_maps_loaded;
float create_server_selected_map;
float create_server_map_dropdown_open;
vector create_server_map_scroll;
string create_server_player_name_text;
float create_server_player_name_cursor;
string create_server_name_text;
float create_server_name_cursor;
string create_server_maxplayers_text;
float create_server_maxplayers_cursor;
string create_server_password_text;
float create_server_password_cursor;
string create_server_rcon_password_text;
float create_server_rcon_password_cursor;
string create_server_fraglimit_text;
float create_server_fraglimit_cursor;
string create_server_roundtime_text;
float create_server_roundtime_cursor;
string create_server_timelimit_text;
float create_server_timelimit_cursor;
string create_server_maxrounds_text;
float create_server_maxrounds_cursor;
string create_server_maxvelocity_text;
float create_server_maxvelocity_cursor;
string create_server_freezetime_text;
float create_server_freezetime_cursor;
string create_server_restartdelay_text;
float create_server_restartdelay_cursor;
string create_server_deathdelay_text;
float create_server_deathdelay_cursor;
float create_server_pure;
float create_server_friendlyfire;
float create_server_autohop;
float create_server_falldamage;
float create_server_gamemode;
float create_server_seeded;

void() create_server_seed_fields =
{
	string maxplayers_text = "";

	if (create_server_seeded)
		return;

	menu_seed_text_from_cvar("name", "Player", create_server_player_name_text, create_server_player_name_cursor);
	menu_seed_text_from_cvar("hostname", "", create_server_name_text, create_server_name_cursor);

	maxplayers_text = cvar_string("maxclients");
	if (maxplayers_text == "")
		maxplayers_text = "8";
	if (create_server_maxplayers_text == "")
	{
		create_server_maxplayers_text = maxplayers_text;
		create_server_maxplayers_cursor = strlen(create_server_maxplayers_text);
	}

	menu_seed_text_from_cvar("password", "", create_server_password_text, create_server_password_cursor);
	menu_seed_text_from_cvar("rcon_password", "", create_server_rcon_password_text, create_server_rcon_password_cursor);
	menu_seed_text_from_cvar("fraglimit", "30", create_server_fraglimit_text, create_server_fraglimit_cursor);
	menu_seed_text_from_cvar("mp_roundtime", "5", create_server_roundtime_text, create_server_roundtime_cursor);
	menu_seed_text_from_cvar("mp_timelimit", "25", create_server_timelimit_text, create_server_timelimit_cursor);
	menu_seed_text_from_cvar("mp_maxrounds", "12", create_server_maxrounds_text, create_server_maxrounds_cursor);
	menu_seed_text_from_cvar("sv_maxvelocity", "2000", create_server_maxvelocity_text, create_server_maxvelocity_cursor);
	menu_seed_text_from_cvar("mp_freezetime", "3", create_server_freezetime_text, create_server_freezetime_cursor);
	menu_seed_text_from_cvar("mp_roundrestartdelay", "5", create_server_restartdelay_text, create_server_restartdelay_cursor);
	menu_seed_text_from_cvar("mp_deathdelay", "3", create_server_deathdelay_text, create_server_deathdelay_cursor);

	create_server_pure = cvar("sv_pure") > 0;
	create_server_friendlyfire = cvar("mp_friendlyfire") > 0;
	create_server_autohop = cvar("pm_autobunny") > 0;
	create_server_falldamage = cvar("mp_falldamage") > 0;
	create_server_gamemode = cvar("sv_gamemode") > 0;
	create_server_seeded = TRUE;
};

string() create_server_selected_map_name =
{
	float map_count = 0;

	if (!create_server_maps_loaded)
		create_server_load_maps();

	map_count = buf_getsize(create_server_maps);
	if (map_count <= 0)
		return "";

	create_server_selected_map = bound(0, create_server_selected_map, map_count - 1);
	return bufstr_get(create_server_maps, create_server_selected_map);
};

float(string id, vector pos, vector size, strbuf options, __inout float selected_index, __inout float is_open, __inout vector scrollofs, float keep_open) menu_dropdown =
{
	float changed = FALSE;
	float count = buf_getsize(options);
	float list_height = 0;
	string label = "No maps found";
	string button_text = label;
	vector button_color = MENU_BUTTON;
	vector border_color = MENU_BUTTON_BORDER;
	vector listitem_pos = '0 0 0';

	if (count > 0)
	{
		selected_index = bound(0, selected_index, count - 1);
		label = bufstr_get(options, selected_index);
		button_text = keep_open ? label : strcat(label, is_open ? " -" : " v");
	}
	else
	{
		is_open = FALSE;
		button_color = MENU_BG_DARK;
		border_color = MENU_BORDER;
	}

	if (keep_open)
	{
		my_button_colored(strcat(id, "_btn"), pos, [size_x, 20], button_text, button_color, border_color);
		is_open = count > 0;
	}
	else if (my_button_colored(strcat(id, "_btn"), pos, [size_x, 20], button_text, button_color, border_color) && count > 0)
	{
		is_open = !is_open;
	}

	if (!is_open || count <= 0)
		return FALSE;

	list_height = min(size_y - 24, max(24, count * 20 + 4));

	sui_push_frame([pos_x, pos_y + 24], [size_x, list_height]);
	sui_fill([0, 0], [size_x, list_height], MENU_BG_DARK, 0.92, 0);
	sui_border_box([0, 0], [size_x, list_height], 1, MENU_BORDER, 0.45, 0);

	sui_list_view_begin(strcat(id, "_list"), [1, 1], [size_x - 2, list_height - 2], [size_x - 8, 20], count, scrollofs, [0, 6]);
	for (float index = sui_list_item(listitem_pos); index > -1; index = sui_list_item(listitem_pos))
	{
		string item = bufstr_get(options, index);
		vector item_color = index == selected_index ? MENU_BUTTON_RETURN : MENU_BUTTON;
		vector item_border = index == selected_index ? MENU_BUTTON_RETURN_BORDER : MENU_BUTTON_BORDER;

		if (!my_button_colored(strcat(id, "_item", ftos(index)), listitem_pos, [size_x - 8, 20], item, item_color, item_border))
			continue;

		selected_index = index;
		is_open = keep_open;
		changed = TRUE;
	}
	sui_list_view_end();

	sui_pop_frame();
	return changed;
};

void() create_server_load_maps =
{
	searchhandle handle = -1;
	float count = 0;
	float map_count = 0;
	string previous_map = "";

	if (create_server_maps_loaded)
	{
		map_count = buf_getsize(create_server_maps);
		if (map_count > 0)
		{
			create_server_selected_map = bound(0, create_server_selected_map, map_count - 1);
			previous_map = bufstr_get(create_server_maps, create_server_selected_map);
		}

		buf_del(create_server_maps);
	}

	create_server_maps = buf_create();
	create_server_maps_loaded = TRUE;
	create_server_selected_map = 0;
	create_server_map_dropdown_open = FALSE;
	create_server_map_scroll = '0 0 0';

	handle = search_begin("maps/*.bsp", TRUE, TRUE);
	if (handle < 0)
		return;

	count = search_getsize(handle);
	for (float index = 0; index < count; index += 1)
	{
		string mapname = menu_map_name_from_filename(search_getfilename(handle, index));

		if (mapname == "" || menu_buf_contains(create_server_maps, mapname))
			continue;

		bufstr_add(create_server_maps, mapname, FALSE);
	}
	search_end(handle);

	map_count = buf_getsize(create_server_maps);
	if (map_count > 1)
		buf_sort(create_server_maps, 0, FALSE);

	if (previous_map != "")
	{
		for (float index = 0; index < map_count; index += 1)
		{
			if (bufstr_get(create_server_maps, index) != previous_map)
				continue;

			create_server_selected_map = index;
			break;
		}
	}
};

void() create_server_launch =
{
	string mapname = create_server_selected_map_name();

	if (mapname == "")
		return;

	if (create_server_player_name_text == "")
	{
		create_server_player_name_text = "Player";
		create_server_player_name_cursor = strlen(create_server_player_name_text);
	}

	menu_normalize_integer_text(8, 1, 64, create_server_maxplayers_text, create_server_maxplayers_cursor);
	menu_normalize_integer_text(30, 0, 999, create_server_fraglimit_text, create_server_fraglimit_cursor);
	menu_normalize_integer_text(5, 1, 999, create_server_roundtime_text, create_server_roundtime_cursor);
	menu_normalize_integer_text(25, 1, 999, create_server_timelimit_text, create_server_timelimit_cursor);
	menu_normalize_integer_text(12, 1, 999, create_server_maxrounds_text, create_server_maxrounds_cursor);
	menu_normalize_integer_text(2000, 100, 10000, create_server_maxvelocity_text, create_server_maxvelocity_cursor);
	menu_normalize_integer_text(3, 0, 60, create_server_freezetime_text, create_server_freezetime_cursor);
	menu_normalize_integer_text(5, 1, 60, create_server_restartdelay_text, create_server_restartdelay_cursor);
	menu_normalize_integer_text(3, 1, 30, create_server_deathdelay_text, create_server_deathdelay_cursor);

	cvar_set("name", create_server_player_name_text);
	cvar_set("hostname", create_server_name_text);
	cvar_set("maxclients", create_server_maxplayers_text);
	cvar_set("password", create_server_password_text);
	cvar_set("rcon_password", create_server_rcon_password_text);
	cvar_set("sv_pure", create_server_pure ? "1" : "0");
	cvar_set("fraglimit", create_server_fraglimit_text);
	cvar_set("mp_roundtime", create_server_roundtime_text);
	cvar_set("mp_timelimit", create_server_timelimit_text);
	cvar_set("mp_maxrounds", create_server_maxrounds_text);
	cvar_set("mp_friendlyfire", create_server_friendlyfire ? "1" : "0");
	cvar_set("pm_autobunny", create_server_autohop ? "1" : "0");
	cvar_set("mp_falldamage", create_server_falldamage ? "1" : "0");
	cvar_set("sv_gamemode", create_server_gamemode ? "1" : "0");
	cvar_set("mp_freezetime", create_server_freezetime_text);
	cvar_set("mp_roundrestartdelay", create_server_restartdelay_text);
	cvar_set("mp_deathdelay", create_server_deathdelay_text);
	cvar_set("sv_maxvelocity", create_server_maxvelocity_text);

	create_server_map_dropdown_open = FALSE;
	current_menu = MENU_MAIN;
	m_close();
	localcmd(sprintf("map %s\n", mapname));
};

void() create_server_menu =
{
	vector pos = [0, 0];
	vector size = [500, 420];
	float pad = 12;
	float gap = 12;
	float footer_height = 88;
	float left_width = 206;
	float right_x = pad + left_width + gap;
	float right_width = size_x - right_x - pad;
	float property_x = right_x + 20;
	float property_width = max(180, size_x - property_x - pad);
	float map_panel_height = size_y - 64 - footer_height;
	float xpos = 0;
	float ypos = 0;
	float has_maps = FALSE;
	float dropdown_height = 0;
	float map_count = 0;
	string selected_map = "";

	create_server_seed_fields();
	if (!create_server_maps_loaded)
		create_server_load_maps();

	map_count = buf_getsize(create_server_maps);
	create_server_map_dropdown_open = TRUE;
	has_maps = map_count > 0;
	dropdown_height = has_maps ? min(map_panel_height - 24, max(24, map_count * 20 + 4)) : 0;
	selected_map = create_server_selected_map_name();

	sui_push_frame(pos, size);

	sui_fill([0, 0], size, MENU_BG, 0.78, 0);
	sui_border_box([0, 0], size, 2, MENU_BORDER, 0.3, 0);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, 4], MENU_TEXT_MEDIUM, "Create Server", MENU_TEXT_1, 1, 0);

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

	xpos = pad;
	ypos = 36;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Map Selection", MENU_TEXT_1, 1, 0);
	ypos += 16;
	menu_dropdown("create_map", [xpos, ypos], [left_width, map_panel_height], create_server_maps, create_server_selected_map, create_server_map_dropdown_open, create_server_map_scroll, TRUE);
	ypos += 24 + dropdown_height + 8;

	if (selected_map != "")
		sui_text([xpos, ypos], MENU_TEXT_SMALL, strcat("Selected: ", selected_map), MENU_TEXT_1, 0.95, 0);
	else
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "No BSP files found in maps/.", MENU_TEXT_2, 0.9, 0);
	ypos += 20;

	if (my_button("create_refresh", [xpos, ypos], [left_width, 20], "Refresh Maps"))
	{
		create_server_load_maps();
		map_count = buf_getsize(create_server_maps);
		has_maps = map_count > 0;
		dropdown_height = has_maps ? min(map_panel_height - 24, max(24, map_count * 20 + 4)) : 0;
		selected_map = create_server_selected_map_name();
	}
	ypos += 26;

	if (has_maps)
		sui_text([xpos, ypos], MENU_TEXT_SMALL, sprintf("%.0f maps available", map_count), MENU_TEXT_2, 0.85, 0);
	else
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Drop BSPs into maps/ to fill this list.", MENU_TEXT_2, 0.85, 0);

	xpos = property_x;
	ypos = 36;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Server Properties", MENU_TEXT_1, 1, 0);
	ypos += 16;

	menu_text_field("Player Name", "create_player_name", [xpos, ypos], property_width, 32, create_server_player_name_text, create_server_player_name_cursor);
	ypos += 18;

	menu_text_field("Server Name", "create_name", [xpos, ypos], property_width, 48, create_server_name_text, create_server_name_cursor);
	ypos += 18;

	menu_text_field("Max Clients", "create_players", [xpos, ypos], property_width, 3, create_server_maxplayers_text, create_server_maxplayers_cursor);
	menu_sanitize_numeric_text(create_server_maxplayers_text, create_server_maxplayers_cursor, FALSE);
	ypos += 18;

	menu_text_field("Password", "create_password", [xpos, ypos], property_width, 32, create_server_password_text, create_server_password_cursor);
	ypos += 18;

	menu_text_field("Rcon PW", "create_rcon_password", [xpos, ypos], property_width, 32, create_server_rcon_password_text, create_server_rcon_password_cursor);
	ypos += 18;

	menu_text_field("Frag Limit", "create_fraglimit", [xpos, ypos], property_width, 3, create_server_fraglimit_text, create_server_fraglimit_cursor);
	menu_sanitize_numeric_text(create_server_fraglimit_text, create_server_fraglimit_cursor, FALSE);
	ypos += 18;

	menu_text_field("Round Time", "create_roundtime", [xpos, ypos], property_width, 3, create_server_roundtime_text, create_server_roundtime_cursor);
	menu_sanitize_numeric_text(create_server_roundtime_text, create_server_roundtime_cursor, FALSE);
	ypos += 18;

	menu_text_field("Map Time", "create_timelimit", [xpos, ypos], property_width, 3, create_server_timelimit_text, create_server_timelimit_cursor);
	menu_sanitize_numeric_text(create_server_timelimit_text, create_server_timelimit_cursor, FALSE);
	ypos += 18;

	menu_text_field("Max Rounds", "create_maxrounds", [xpos, ypos], property_width, 3, create_server_maxrounds_text, create_server_maxrounds_cursor);
	menu_sanitize_numeric_text(create_server_maxrounds_text, create_server_maxrounds_cursor, FALSE);
	ypos += 18;

	menu_text_field("Max Velocity", "create_maxvelocity", [xpos, ypos], property_width, 5, create_server_maxvelocity_text, create_server_maxvelocity_cursor);
	menu_sanitize_numeric_text(create_server_maxvelocity_text, create_server_maxvelocity_cursor, FALSE);
	ypos += 18;

	menu_text_field("Freeze Time", "create_freezetime", [xpos, ypos], property_width, 3, create_server_freezetime_text, create_server_freezetime_cursor);
	menu_sanitize_numeric_text(create_server_freezetime_text, create_server_freezetime_cursor, FALSE);
	ypos += 18;

	menu_text_field("Restart Delay", "create_restartdelay", [xpos, ypos], property_width, 3, create_server_restartdelay_text, create_server_restartdelay_cursor);
	menu_sanitize_numeric_text(create_server_restartdelay_text, create_server_restartdelay_cursor, FALSE);
	ypos += 18;

	menu_text_field("Death Delay", "create_deathdelay", [xpos, ypos], property_width, 3, create_server_deathdelay_text, create_server_deathdelay_cursor);
	menu_sanitize_numeric_text(create_server_deathdelay_text, create_server_deathdelay_cursor, FALSE);
	ypos += 22;

	menu_toggle_button("create_pure", [xpos, ypos], [property_width, 20], "Pure", create_server_pure);
	ypos += 24;

	menu_toggle_button("create_ff", [xpos, ypos], [property_width, 20], "Friendly Fire", create_server_friendlyfire);
	ypos += 24;

	menu_toggle_button("create_autohop", [xpos, ypos], [property_width, 20], "Autohop", create_server_autohop);
	ypos += 24;

	menu_toggle_button("create_falldamage", [xpos, ypos], [property_width, 20], "Fall Damage", create_server_falldamage);
	ypos += 24;

	{
		string gamemode_label = create_server_gamemode ? "Elimination" : "Team Deathmatch";
		if (my_button("create_gamemode", [xpos, ypos], [property_width, 20], gamemode_label))
			create_server_gamemode = !create_server_gamemode;
	}
	ypos += 26;

	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Map time is in minutes.", MENU_TEXT_2, 0.85, 0);
	ypos += 10;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Max rounds is per side.", MENU_TEXT_2, 0.85, 0);

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_END]);
	if (my_button("create_back", [8, -8], [80, 20], "Back"))
	{
		create_server_map_dropdown_open = FALSE;
		current_menu = MENU_MAIN;
	}

	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_END]);
	if (has_maps)
	{
		if (my_button("create_launch", [-pad, -8], [116, 20], "Start Server"))
			create_server_launch();
	}
	else
	{
		menu_disabled_button([-pad, -8], [116, 20], "Start Server");
	}

	sui_set_default_kb_focus("create_player_name");

	if (sui_listen_back())
	{
		create_server_map_dropdown_open = FALSE;
		current_menu = MENU_MAIN;
	}

	sui_pop_frame();
};
