strbuf create_server_maps;
float create_server_maps_loaded;
float create_server_selected_map;
float create_server_map_dropdown_open;
vector create_server_map_scroll;
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
float create_server_stamina;
float create_server_gamemode;
float create_server_cheats;
float create_server_noblock;
float create_server_seeded;
float create_server_tab;    // 0 = server, 1 = game, 2 = movement
float create_server_tickrate_index;

float tickrates[] = { 64, 66, 72, 85, 100, 128, 200, 300 };
string tickrate_labels[] = { "64 (CS:GO)", "66 (CS:S)", "72 (Quake)", "85 (CS:GO)", "100 (CS:S)", "128 (CS:GO)", "200 (FTE)", "300 (FTE)" };
string create_server_hullheight_text;
float create_server_hullheight_cursor;
string create_server_maxspeed_text;
float create_server_maxspeed_cursor;
string create_server_accelerate_text;
float create_server_accelerate_cursor;
string create_server_airaccelerate_text;
float create_server_airaccelerate_cursor;
string create_server_friction_text;
float create_server_friction_cursor;

// --- Physics tab state ---

string create_server_hitforce_text;       float create_server_hitforce_cursor;
string create_server_pushforce_text;      float create_server_pushforce_cursor;
string create_server_useforce_text;       float create_server_useforce_cursor;
string create_server_usevelmult_text;     float create_server_usevelmult_cursor;
string create_server_mass_text;           float create_server_mass_cursor;
string create_server_minkick_text;        float create_server_minkick_cursor;
string create_server_pushradius_text;     float create_server_pushradius_cursor;
string create_server_odeiter_text;        float create_server_odeiter_cursor;
string create_server_pushheight_text;     float create_server_pushheight_cursor;
string create_server_erp_text;            float create_server_erp_cursor;
string create_server_damplin_text;        float create_server_damplin_cursor;
string create_server_dampang_text;        float create_server_dampang_cursor;
string create_server_playerbounce_text;   float create_server_playerbounce_cursor;
string create_server_kickback_text;       float create_server_kickback_cursor;
string create_server_phfriction_text;     float create_server_phfriction_cursor;
float  create_server_passthrough;
float  create_server_qccollide;
float  create_server_odequick;
float  create_server_odeautodisable;
float  create_server_shape_index;
float  create_server_axis_index;
string physprop_shapes[] = { "box", "capsule", "cylinder", "sphere" };
string physprop_axes[]   = { "x", "y", "z" };

// --- Default-loadout dropdown state ---
// Parallel (id, display-name) arrays drive the four "Default Weapons"
// dropdowns on the Game tab.  The cvar stores the WEP_* integer directly;
// the index into these arrays is just UI state.  WEP_* values correspond to
// the constants in shared/sh_weapons.qc — keep this list in sync.
float  cs_loadout_primary_ids[]    = { 0,  3,    4,    19,   22,    16, 17, 10,  5,             7,     12,                8,          27,    24,    15,           23,      13,    18,     11    };
string cs_loadout_primary_names[]  = {"None","AK47","M4A1","AWP","G3SG1","M3","MP5","K98","Flak Shotgun","Gauss","Grenade Launcher","Crossbow","Egon","RPG","HL Shotgun","HL SMG","M249","Rebar","Scout"};

float  cs_loadout_secondary_ids[]   = { 0,     28,   1,              21,      9,      26,         6    };
string cs_loadout_secondary_names[] = {"None","USP","Desert Eagle","Glock",".357","HL Glock","9mm" };

float  cs_loadout_melee_ids[]       = { 0,     20,       2,       14       };
string cs_loadout_melee_names[]     = {"None","Wrench","Knife","Crowbar" };

float  cs_loadout_utility_ids[]     = { 0,     25       };
string cs_loadout_utility_names[]   = {"None","Grenade" };

float cs_default_primary_idx;     float  cs_default_primary_open;     vector cs_default_primary_scroll;
float cs_default_secondary_idx;   float  cs_default_secondary_open;   vector cs_default_secondary_scroll;
float cs_default_melee_idx;       float  cs_default_melee_open;       vector cs_default_melee_scroll;
float cs_default_utility_idx;     float  cs_default_utility_open;     vector cs_default_utility_scroll;

// Latched draw positions for the four dropdowns — set each frame when the
// buttons are drawn on the Server tab; read at end-of-frame to draw the
// expanded list as an overlay on top of everything else (including the
// Start Server button that's drawn later).
vector cs_default_primary_pos;    vector cs_default_primary_size;
vector cs_default_secondary_pos;  vector cs_default_secondary_size;
vector cs_default_melee_pos;      vector cs_default_melee_size;
vector cs_default_utility_pos;    vector cs_default_utility_size;

strbuf cs_default_primary_options;
strbuf cs_default_secondary_options;
strbuf cs_default_melee_options;
strbuf cs_default_utility_options;
float  cs_default_options_loaded;

void() create_server_load_loadout_options =
{
    float i;

    if (cs_default_options_loaded)
        return;

    cs_default_primary_options = buf_create();
    for (i = 0; i < cs_loadout_primary_names.length; i++)
        bufstr_add(cs_default_primary_options, cs_loadout_primary_names[i], FALSE);

    cs_default_secondary_options = buf_create();
    for (i = 0; i < cs_loadout_secondary_names.length; i++)
        bufstr_add(cs_default_secondary_options, cs_loadout_secondary_names[i], FALSE);

    cs_default_melee_options = buf_create();
    for (i = 0; i < cs_loadout_melee_names.length; i++)
        bufstr_add(cs_default_melee_options, cs_loadout_melee_names[i], FALSE);

    cs_default_utility_options = buf_create();
    for (i = 0; i < cs_loadout_utility_names.length; i++)
        bufstr_add(cs_default_utility_options, cs_loadout_utility_names[i], FALSE);

    cs_default_options_loaded = TRUE;
};

void() Menu_FixupEmptyDefaults;  // forward — defined in m_menu.qc

void() create_server_seed_fields =
{
	string maxplayers_text = "";

	if (create_server_seeded)
		return;

	// Ensure non-UI server cvars have their proper defaults before we
	// read them into UI state.  Handles the case where a prior save
	// wrote empty strings to data/server.cfg.
	Menu_FixupEmptyDefaults();

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
	menu_seed_text_from_cvar("mp_respawndelay", "3", create_server_deathdelay_text, create_server_deathdelay_cursor);

	menu_seed_text_from_cvar("sv_hull_height", "72", create_server_hullheight_text, create_server_hullheight_cursor);
	menu_seed_text_from_cvar("sv_maxspeed", "270", create_server_maxspeed_text, create_server_maxspeed_cursor);
	menu_seed_text_from_cvar("sv_accelerate", "5", create_server_accelerate_text, create_server_accelerate_cursor);
	menu_seed_text_from_cvar("sv_airaccelerate", "150", create_server_airaccelerate_text, create_server_airaccelerate_cursor);
	menu_seed_text_from_cvar("sv_friction", "4", create_server_friction_text, create_server_friction_cursor);

	// Seed tickrate index from current sv_mintic
	{
		float cur_mintic = cvar("sv_mintic");
		if (cur_mintic > 0)
		{
			float cur_tick = 1.0 / cur_mintic;
			float best = 0;
			float best_diff = 9999;
			for (float ti = 0; ti < tickrates.length; ti++)
			{
				float diff = fabs(tickrates[ti] - cur_tick);
				if (diff < best_diff) { best_diff = diff; best = ti; }
			}
			create_server_tickrate_index = best;
		}
		else
			create_server_tickrate_index = 0;  // default 64 tick
	}

	create_server_pure = cvar("sv_pure") > 0;
	create_server_friendlyfire = cvar("mp_friendlyfire") > 0;
	create_server_autohop = cvar("sv_autohop") > 0;
	create_server_falldamage = cvar("mp_falldamage") > 0;
	create_server_stamina = cvar("sv_stamina") > 0;
	create_server_gamemode = cvar("sv_gamemode");
	create_server_cheats = cvar("mp_cheats") > 0;
	create_server_noblock = cvar("mp_noblock") > 0;

	// Seed default-loadout dropdown indices from the sv_default_* cvars.
	// Each cvar stores a WEP_* integer; find its index in the matching
	// cs_loadout_*_ids array.  Falls back to index 0 ("None") if not found.
	create_server_load_loadout_options();
	{
		float want;
		float i;

		want = cvar("sv_default_primary");
		cs_default_primary_idx = 0;
		for (i = 0; i < cs_loadout_primary_ids.length; i++)
			if (cs_loadout_primary_ids[i] == want) { cs_default_primary_idx = i; break; }

		want = cvar("sv_default_secondary");
		cs_default_secondary_idx = 0;
		for (i = 0; i < cs_loadout_secondary_ids.length; i++)
			if (cs_loadout_secondary_ids[i] == want) { cs_default_secondary_idx = i; break; }

		want = cvar("sv_default_melee");
		cs_default_melee_idx = 0;
		for (i = 0; i < cs_loadout_melee_ids.length; i++)
			if (cs_loadout_melee_ids[i] == want) { cs_default_melee_idx = i; break; }

		want = cvar("sv_default_utility");
		cs_default_utility_idx = 0;
		for (i = 0; i < cs_loadout_utility_ids.length; i++)
			if (cs_loadout_utility_ids[i] == want) { cs_default_utility_idx = i; break; }
	}

	// Physics tab seeding
	menu_seed_text_from_cvar("sv_physprop_hit_force",         "8000",  create_server_hitforce_text,     create_server_hitforce_cursor);
	menu_seed_text_from_cvar("sv_physprop_push_force",        "8000",  create_server_pushforce_text,    create_server_pushforce_cursor);
	menu_seed_text_from_cvar("sv_physprop_use_force",         "800",   create_server_useforce_text,     create_server_useforce_cursor);
	menu_seed_text_from_cvar("sv_physprop_use_velmult",       "800",   create_server_usevelmult_text,   create_server_usevelmult_cursor);
	menu_seed_text_from_cvar("sv_physprop_mass",              "20",    create_server_mass_text,         create_server_mass_cursor);
	menu_seed_text_from_cvar("sv_physprop_player_minkick",    "100",   create_server_minkick_text,      create_server_minkick_cursor);
	menu_seed_text_from_cvar("sv_physprop_push_radius",       "40",    create_server_pushradius_text,   create_server_pushradius_cursor);
	menu_seed_text_from_cvar("physics_ode_iterationsperframe","10",    create_server_odeiter_text,      create_server_odeiter_cursor);
	menu_seed_text_from_cvar("sv_physprop_push_height",       "0.6",   create_server_pushheight_text,   create_server_pushheight_cursor);
	menu_seed_text_from_cvar("sv_physprop_erp",               "0",     create_server_erp_text,          create_server_erp_cursor);
	menu_seed_text_from_cvar("sv_physprop_damp_lin",          "0.2",   create_server_damplin_text,      create_server_damplin_cursor);
	menu_seed_text_from_cvar("sv_physprop_damp_ang",          "0.2",   create_server_dampang_text,      create_server_dampang_cursor);
	menu_seed_text_from_cvar("sv_physprop_player_bounce",     "0.4",   create_server_playerbounce_text, create_server_playerbounce_cursor);
	menu_seed_text_from_cvar("sv_physprop_player_kickback",   "0.005", create_server_kickback_text,     create_server_kickback_cursor);
	menu_seed_text_from_cvar("sv_physprop_friction",          "1.0",   create_server_phfriction_text,   create_server_phfriction_cursor);

	create_server_passthrough    = cvar("sv_physprop_passthrough") > 0;
	create_server_qccollide      = cvar("sv_physprop_qc_collide") > 0;
	create_server_odequick       = cvar("physics_ode_worldquickstep") > 0;
	create_server_odeautodisable = cvar("physics_ode_autodisable") > 0;

	// Shape/axis cycle indices — match current cvar to table, default to cylinder/y.
	create_server_shape_index = 2;
	string cur_shape = cvar_string("sv_physprop_shape");
	float si;
	for (si = 0; si < physprop_shapes.length; si++)
		if (cur_shape == physprop_shapes[si]) { create_server_shape_index = si; break; }

	create_server_axis_index = 1;
	string cur_axis = cvar_string("sv_physprop_axis");
	for (si = 0; si < physprop_axes.length; si++)
		if (cur_axis == physprop_axes[si]) { create_server_axis_index = si; break; }

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

// Button-only variant — draws the selector button and toggles is_open on
// click, but does NOT render the expanded list. Use together with
// menu_dropdown_list (typically called later in the same frame so the list
// overlays any content drawn between the two calls).
float(string id, vector pos, vector size, strbuf options, __inout float selected_index, __inout float is_open, float keep_open) menu_dropdown_button =
{
	float count = buf_getsize(options);
	string label = "No maps found";
	string button_text = label;
	vector button_color = MENU_BUTTON;
	vector border_color = MENU_BUTTON_BORDER;

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
		return FALSE;
	}

	if (my_button_colored(strcat(id, "_btn"), pos, [size_x, 20], button_text, button_color, border_color) && count > 0)
	{
		is_open = !is_open;
		return TRUE;
	}
	return FALSE;
};

// List-only variant — if is_open, draws the expanded list at pos (offset by
// the button height).  Returns TRUE when the user picks an item.
float(string id, vector pos, vector size, strbuf options, __inout float selected_index, __inout float is_open, __inout vector scrollofs) menu_dropdown_list =
{
	float changed = FALSE;
	float count = buf_getsize(options);
	float list_height = 0;
	vector listitem_pos = '0 0 0';

	if (!is_open || count <= 0)
		return FALSE;

	list_height = min(size_y - 24, max(24, count * 20 + 4));

	sui_push_frame([pos_x, pos_y + 24], [size_x, list_height]);
	sui_fill([0, 0], [size_x, list_height], MENU_BG_DARK, 0.96, 0);
	sui_border_box([0, 0], [size_x, list_height], 2, MENU_BORDER, 1.0, 0);

	sui_list_view_begin(strcat(id, "_list"), [1, 1], [size_x - 2, list_height - 2], [size_x - 8, 20], count, scrollofs, [0, 6]);
	for (float index = sui_list_item(listitem_pos); index > -1; index = sui_list_item(listitem_pos))
	{
		string item = bufstr_get(options, index);
		vector item_color = index == selected_index ? MENU_BUTTON_RETURN : MENU_BUTTON;
		vector item_border = index == selected_index ? MENU_BUTTON_RETURN_BORDER : MENU_BUTTON_BORDER;

		if (!my_button_colored(strcat(id, "_item", ftos(index)), listitem_pos, [size_x - 8, 20], item, item_color, item_border))
			continue;

		selected_index = index;
		is_open = FALSE;
		changed = TRUE;
	}
	sui_list_view_end();
	sui_pop_frame();

	return changed;
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
	sui_fill([0, 0], [size_x, list_height], MENU_BG_DARK, 0.96, 0);
	sui_border_box([0, 0], [size_x, list_height], 2, MENU_BORDER, 1.0, 0);

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

	menu_normalize_integer_text(8, 1, 64, create_server_maxplayers_text, create_server_maxplayers_cursor);
	menu_normalize_integer_text(30, 0, 999, create_server_fraglimit_text, create_server_fraglimit_cursor);
	menu_normalize_integer_text(5, 1, 999, create_server_roundtime_text, create_server_roundtime_cursor);
	menu_normalize_integer_text(25, 1, 999, create_server_timelimit_text, create_server_timelimit_cursor);
	menu_normalize_integer_text(12, 1, 999, create_server_maxrounds_text, create_server_maxrounds_cursor);
	menu_normalize_integer_text(2000, 100, 10000, create_server_maxvelocity_text, create_server_maxvelocity_cursor);
	menu_normalize_integer_text(3, 0, 60, create_server_freezetime_text, create_server_freezetime_cursor);
	menu_normalize_integer_text(5, 1, 60, create_server_restartdelay_text, create_server_restartdelay_cursor);
	menu_normalize_integer_text(3, 1, 30, create_server_deathdelay_text, create_server_deathdelay_cursor);
	menu_normalize_integer_text(72, 32, 128, create_server_hullheight_text, create_server_hullheight_cursor);
	menu_normalize_integer_text(320, 50, 2000, create_server_maxspeed_text, create_server_maxspeed_cursor);
	menu_normalize_integer_text(5, 1, 100, create_server_accelerate_text, create_server_accelerate_cursor);
	menu_normalize_integer_text(150, 1, 1000, create_server_airaccelerate_text, create_server_airaccelerate_cursor);
	menu_normalize_integer_text(4, 1, 50, create_server_friction_text, create_server_friction_cursor);

	// Physics integer clamps
	menu_normalize_integer_text(8000, 0, 100000, create_server_hitforce_text,   create_server_hitforce_cursor);
	menu_normalize_integer_text(8000, 0, 100000, create_server_pushforce_text,  create_server_pushforce_cursor);
	menu_normalize_integer_text(800,  0, 100000, create_server_useforce_text,   create_server_useforce_cursor);
	menu_normalize_integer_text(800,  0, 10000,  create_server_usevelmult_text, create_server_usevelmult_cursor);
	menu_normalize_integer_text(20,   1, 1000,   create_server_mass_text,       create_server_mass_cursor);
	menu_normalize_integer_text(100,  0, 10000,  create_server_minkick_text,    create_server_minkick_cursor);
	menu_normalize_integer_text(40,   0, 512,    create_server_pushradius_text, create_server_pushradius_cursor);
	menu_normalize_integer_text(10,   1, 60,     create_server_odeiter_text,    create_server_odeiter_cursor);

	// Compute tickrate values
	float tick = tickrates[create_server_tickrate_index];
	string tic_val = sprintf("%.6f", 1.0 / tick);

	// Apply all cvars
	cvar_set("hostname", create_server_name_text);
	cvar_set("maxclients", create_server_maxplayers_text);
	cvar_set("password", create_server_password_text);
	cvar_set("rcon_password", create_server_rcon_password_text);
	cvar_set("sv_pure", create_server_pure ? "1" : "0");
	cvar_set("sv_mintic", tic_val);
	cvar_set("sv_maxtic", tic_val);
	cvar_set("fraglimit", create_server_fraglimit_text);
	cvar_set("mp_roundtime", create_server_roundtime_text);
	cvar_set("mp_timelimit", create_server_timelimit_text);
	cvar_set("mp_maxrounds", create_server_maxrounds_text);
	cvar_set("mp_friendlyfire", create_server_friendlyfire ? "1" : "0");
	// Cheats toggle — mirror on both mp_cheats (mod-level) and sv_cheats (engine-level).
	cvar_set("mp_cheats", create_server_cheats ? "1" : "0");
	cvar_set("sv_cheats", create_server_cheats ? "1" : "0");
	cvar_set("mp_noblock", create_server_noblock ? "1" : "0");
	cvar_set("sv_autohop", create_server_autohop ? "1" : "0");
	cvar_set("mp_falldamage", create_server_falldamage ? "1" : "0");
	cvar_set("sv_stamina", create_server_stamina ? "1" : "0");
	cvar_set("sv_gamemode", ftos(create_server_gamemode));

	// Default-loadout WEP_* IDs.  Index is clamped because the dropdown
	// arrays might change between sessions (e.g. a weapon was removed).
	cs_default_primary_idx   = bound(0, cs_default_primary_idx,   cs_loadout_primary_ids.length   - 1);
	cs_default_secondary_idx = bound(0, cs_default_secondary_idx, cs_loadout_secondary_ids.length - 1);
	cs_default_melee_idx     = bound(0, cs_default_melee_idx,     cs_loadout_melee_ids.length     - 1);
	cs_default_utility_idx   = bound(0, cs_default_utility_idx,   cs_loadout_utility_ids.length   - 1);
	cvar_set("sv_default_primary",   ftos(cs_loadout_primary_ids[cs_default_primary_idx]));
	cvar_set("sv_default_secondary", ftos(cs_loadout_secondary_ids[cs_default_secondary_idx]));
	cvar_set("sv_default_melee",     ftos(cs_loadout_melee_ids[cs_default_melee_idx]));
	cvar_set("sv_default_utility",   ftos(cs_loadout_utility_ids[cs_default_utility_idx]));

	cvar_set("mp_freezetime", create_server_freezetime_text);
	cvar_set("mp_roundrestartdelay", create_server_restartdelay_text);
	cvar_set("mp_respawndelay", create_server_deathdelay_text);
	cvar_set("sv_maxvelocity", create_server_maxvelocity_text);
	cvar_set("sv_hull_height", create_server_hullheight_text);
	cvar_set("sv_maxspeed", create_server_maxspeed_text);
	cvar_set("sv_accelerate", create_server_accelerate_text);
	cvar_set("sv_airaccelerate", create_server_airaccelerate_text);
	cvar_set("sv_friction", create_server_friction_text);

	// Physics settings
	cvar_set("sv_physprop_hit_force",       create_server_hitforce_text);
	cvar_set("sv_physprop_push_force",      create_server_pushforce_text);
	cvar_set("sv_physprop_use_force",       create_server_useforce_text);
	cvar_set("sv_physprop_use_velmult",     create_server_usevelmult_text);
	cvar_set("sv_physprop_mass",            create_server_mass_text);
	cvar_set("sv_physprop_player_minkick",  create_server_minkick_text);
	cvar_set("sv_physprop_push_radius",     create_server_pushradius_text);
	cvar_set("sv_physprop_push_height",     create_server_pushheight_text);
	cvar_set("sv_physprop_erp",             create_server_erp_text);
	cvar_set("sv_physprop_damp_lin",        create_server_damplin_text);
	cvar_set("sv_physprop_damp_ang",        create_server_dampang_text);
	cvar_set("sv_physprop_player_bounce",   create_server_playerbounce_text);
	cvar_set("sv_physprop_player_kickback", create_server_kickback_text);
	cvar_set("sv_physprop_friction",        create_server_phfriction_text);
	cvar_set("sv_physprop_shape",           physprop_shapes[create_server_shape_index]);
	cvar_set("sv_physprop_axis",            physprop_axes[create_server_axis_index]);
	cvar_set("sv_physprop_passthrough",     create_server_passthrough ? "1" : "0");
	cvar_set("sv_physprop_qc_collide",      create_server_qccollide ? "1" : "0");
	cvar_set("physics_ode_iterationsperframe", create_server_odeiter_text);
	cvar_set("physics_ode_worldquickstep",  create_server_odequick ? "1" : "0");
	cvar_set("physics_ode_autodisable",     create_server_odeautodisable ? "1" : "0");

	// Save only the server cvars to data/server.cfg.
	// sv_main.qc execs this file on worldspawn to pick up the values.
	Menu_SaveServerConfig();

	create_server_map_dropdown_open = FALSE;
	current_menu = MENU_MAIN;
	m_close();
	// Leaving the backdrop — the new map is a real game, so CSQC should
	// show HUD + team-select normally.  See m_main.qc m_init for details.
	localcmd("set cl_menu_backdrop_active 0\n");
	localcmd(sprintf("map %s\n", mapname));
};

void() create_server_menu =
{
	vector pos = [0, 0];
	vector size = [480, 350];
	float pad = 12;
	float gap = 6;
	float footer_height = 88;
	float left_width = 206;
	float right_x = pad + left_width + gap;
	float right_width = size_x - right_x - pad;
	float property_x = right_x + 10;
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

	menu_panel_bg(size, 4);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([1, 13], MENU_TEXT_MEDIUM, "Create Server", '0 0 0', 0.5, 0);
	sui_text([0, 12], MENU_TEXT_MEDIUM, "Create Server", MENU_TEXT_1, 1, 0);

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

	// Tab toggle buttons — 4 tabs
	{
		float tab_w = (property_width - 12) / 4;
		vector active_col = MENU_BUTTON_RETURN;
		vector active_brd = MENU_BUTTON_RETURN_BORDER;
		vector inactive_col = MENU_BG_DARK;
		vector inactive_brd = MENU_BORDER;

		if (my_button_colored("tab_server", [xpos, ypos], [tab_w, 20], "Server",
			create_server_tab == 0 ? active_col : inactive_col,
			create_server_tab == 0 ? active_brd : inactive_brd))
			create_server_tab = 0;

		if (my_button_colored("tab_game", [xpos + tab_w + 4, ypos], [tab_w, 20], "Game",
			create_server_tab == 1 ? active_col : inactive_col,
			create_server_tab == 1 ? active_brd : inactive_brd))
			create_server_tab = 1;

		if (my_button_colored("tab_movement", [xpos + (tab_w + 4) * 2, ypos], [tab_w, 20], "Movement",
			create_server_tab == 2 ? active_col : inactive_col,
			create_server_tab == 2 ? active_brd : inactive_brd))
			create_server_tab = 2;

		if (my_button_colored("tab_physics", [xpos + (tab_w + 4) * 3, ypos], [tab_w, 20], "Physics",
			create_server_tab == 3 ? active_col : inactive_col,
			create_server_tab == 3 ? active_brd : inactive_brd))
			create_server_tab = 3;
	}
	ypos += 26;

	float half_w = (property_width - 4) * 0.5;

	if (create_server_tab == 0)
	{
		// --- Server Settings ---
		menu_text_field("Server Name", "create_name", [xpos, ypos], property_width, 48, create_server_name_text, create_server_name_cursor);
		ypos += 18;

		menu_text_field("Max Clients", "create_players", [xpos, ypos], property_width, 3, create_server_maxplayers_text, create_server_maxplayers_cursor);
		menu_sanitize_numeric_text(create_server_maxplayers_text, create_server_maxplayers_cursor, FALSE);
		ypos += 18;

		menu_text_field("Password", "create_password", [xpos, ypos], property_width, 32, create_server_password_text, create_server_password_cursor);
		ypos += 18;

		menu_text_field("Rcon PW", "create_rcon_password", [xpos, ypos], property_width, 32, create_server_rcon_password_text, create_server_rcon_password_cursor);
		ypos += 20;

		menu_toggle_button("create_pure", [xpos, ypos], [property_width, 20], "SV Pure", create_server_pure);
		ypos += 24;

		{
			string tick_label = sprintf("Tickrate: %s", tickrate_labels[create_server_tickrate_index]);
			if (my_button("create_tickrate", [xpos, ypos], [property_width, 20], tick_label))
			{
				create_server_tickrate_index += 1;
				if (create_server_tickrate_index >= tickrates.length)
					create_server_tickrate_index = 0;
			}
		}
	}
	else if (create_server_tab == 1)
	{
		// --- Game Settings ---
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

		menu_text_field("Freeze Time", "create_freezetime", [xpos, ypos], property_width, 3, create_server_freezetime_text, create_server_freezetime_cursor);
		menu_sanitize_numeric_text(create_server_freezetime_text, create_server_freezetime_cursor, FALSE);
		ypos += 18;

		menu_text_field("Restart Delay", "create_restartdelay", [xpos, ypos], property_width, 3, create_server_restartdelay_text, create_server_restartdelay_cursor);
		menu_sanitize_numeric_text(create_server_restartdelay_text, create_server_restartdelay_cursor, FALSE);
		ypos += 18;

		menu_text_field("Respawn Delay", "create_respawndelay", [xpos, ypos], property_width, 3, create_server_deathdelay_text, create_server_deathdelay_cursor);
		menu_sanitize_numeric_text(create_server_deathdelay_text, create_server_deathdelay_cursor, FALSE);
		ypos += 20;

		menu_toggle_button("create_ff",     [xpos,              ypos], [half_w, 20], "Friendly Fire", create_server_friendlyfire);
		menu_toggle_button("create_cheats", [xpos + half_w + 4, ypos], [half_w, 20], "Cheats",        create_server_cheats);
		ypos += 24;

		{
			string gamemode_label;
			// 0 = TDM, 1 = Elimination, 2 = Bhop (see shared/sh_customdefs.qc)
			if (create_server_gamemode == 1)
				gamemode_label = "Elimination";
			else if (create_server_gamemode == 2)
				gamemode_label = "Bhop";
			else
				gamemode_label = "Team Deathmatch";
			if (my_button("create_gamemode", [xpos, ypos], [property_width, 20], gamemode_label))
				create_server_gamemode = (create_server_gamemode + 1) - floor((create_server_gamemode + 1) / 3) * 3;
		}
		ypos += 24;

		// --- Default Loadout dropdowns ---
		// Lay out 2x2.  Only the selector buttons are drawn here; the expanded
		// lists are drawn at the end of create_server_menu so they overlay the
		// Start Server button and anything beneath them.
		create_server_load_loadout_options();
		{
			float dd_max = 120;

			sui_text([xpos, ypos], MENU_TEXT_SMALL, "Default Loadout", MENU_TEXT_2, 0.85, 0);
			ypos += 14;

			cs_default_primary_pos    = [xpos,              ypos];
			cs_default_primary_size   = [half_w, dd_max];
			cs_default_secondary_pos  = [xpos + half_w + 4, ypos];
			cs_default_secondary_size = [half_w, dd_max];

			if (menu_dropdown_button("create_def_prim", cs_default_primary_pos, cs_default_primary_size,
				cs_default_primary_options, cs_default_primary_idx, cs_default_primary_open, FALSE))
			{
				cs_default_secondary_open = FALSE;
				cs_default_melee_open = FALSE;
				cs_default_utility_open = FALSE;
			}
			if (menu_dropdown_button("create_def_sec", cs_default_secondary_pos, cs_default_secondary_size,
				cs_default_secondary_options, cs_default_secondary_idx, cs_default_secondary_open, FALSE))
			{
				cs_default_primary_open = FALSE;
				cs_default_melee_open = FALSE;
				cs_default_utility_open = FALSE;
			}
			ypos += 22;

			cs_default_melee_pos    = [xpos,              ypos];
			cs_default_melee_size   = [half_w, dd_max];
			cs_default_utility_pos  = [xpos + half_w + 4, ypos];
			cs_default_utility_size = [half_w, dd_max];

			if (menu_dropdown_button("create_def_mel", cs_default_melee_pos, cs_default_melee_size,
				cs_default_melee_options, cs_default_melee_idx, cs_default_melee_open, FALSE))
			{
				cs_default_primary_open = FALSE;
				cs_default_secondary_open = FALSE;
				cs_default_utility_open = FALSE;
			}
			if (menu_dropdown_button("create_def_util", cs_default_utility_pos, cs_default_utility_size,
				cs_default_utility_options, cs_default_utility_idx, cs_default_utility_open, FALSE))
			{
				cs_default_primary_open = FALSE;
				cs_default_secondary_open = FALSE;
				cs_default_melee_open = FALSE;
			}
		}
	}
	else if (create_server_tab == 2)
	{
		// --- Player Movement ---
		menu_text_field("Hull Height", "create_hullheight", [xpos, ypos], property_width, 3, create_server_hullheight_text, create_server_hullheight_cursor);
		menu_sanitize_numeric_text(create_server_hullheight_text, create_server_hullheight_cursor, FALSE);
		ypos += 18;

		menu_text_field("Max Speed", "create_maxspeed", [xpos, ypos], property_width, 4, create_server_maxspeed_text, create_server_maxspeed_cursor);
		menu_sanitize_numeric_text(create_server_maxspeed_text, create_server_maxspeed_cursor, FALSE);
		ypos += 18;

		menu_text_field("Accelerate", "create_accel", [xpos, ypos], property_width, 4, create_server_accelerate_text, create_server_accelerate_cursor);
		menu_sanitize_numeric_text(create_server_accelerate_text, create_server_accelerate_cursor, FALSE);
		ypos += 18;

		menu_text_field("Air Accel", "create_airaccel", [xpos, ypos], property_width, 4, create_server_airaccelerate_text, create_server_airaccelerate_cursor);
		menu_sanitize_numeric_text(create_server_airaccelerate_text, create_server_airaccelerate_cursor, FALSE);
		ypos += 18;

		menu_text_field("Friction", "create_friction", [xpos, ypos], property_width, 3, create_server_friction_text, create_server_friction_cursor);
		menu_sanitize_numeric_text(create_server_friction_text, create_server_friction_cursor, FALSE);
		ypos += 18;

		menu_text_field("Max Velocity", "create_maxvelocity", [xpos, ypos], property_width, 5, create_server_maxvelocity_text, create_server_maxvelocity_cursor);
		menu_sanitize_numeric_text(create_server_maxvelocity_text, create_server_maxvelocity_cursor, FALSE);
		ypos += 20;

		menu_toggle_button("create_autohop", [xpos, ypos], [half_w, 20], "Autohop", create_server_autohop);
		menu_toggle_button("create_stamina", [xpos + half_w + 4, ypos], [half_w, 20], "Stamina", create_server_stamina);
		ypos += 22;

		menu_toggle_button("create_falldamage", [xpos,              ypos], [half_w, 20], "Fall Damage", create_server_falldamage);
		menu_toggle_button("create_noblock",    [xpos + half_w + 4, ypos], [half_w, 20], "No Block",    create_server_noblock);
	}
	else
	{
		// --- Physics (tab 3) ---
		// ODE plugin status — set by server worldspawn into sv_ode_loaded.
		// 1 = loaded (green), 0 = not loaded (red), anything else = unknown (gray).
		// Unknown shows until the user has started a server once this session
		// (that's when phys_barrel_precache runs physics_supported() and writes
		// the cvar).
		float ode_state = cvar("sv_ode_loaded");
		if (ode_state == 1)
			sui_text([xpos, ypos], MENU_TEXT_SMALL, "ODE plugin is loaded", '0.3 1 0.4', 1, 0);
		else if (ode_state == -1)
			sui_text([xpos, ypos], MENU_TEXT_SMALL, "ODE plugin is not loaded", '1 0.3 0.3', 1, 0);
		else
			sui_text([xpos, ypos], MENU_TEXT_SMALL, "ODE status unknown (start a server to check)", '0.7 0.7 0.7', 1, 0);
		ypos += 14;

		// Integer rows (half-width paired, tight labels for more input space)
		menu_text_field_tight("Hit Force",   "create_ph_hitf",  [xpos,              ypos], half_w, 6, create_server_hitforce_text,   create_server_hitforce_cursor);
		menu_sanitize_numeric_text(create_server_hitforce_text, create_server_hitforce_cursor, FALSE);
		menu_text_field_tight("Push Force",  "create_ph_pushf", [xpos + half_w + 4, ypos], half_w, 6, create_server_pushforce_text,  create_server_pushforce_cursor);
		menu_sanitize_numeric_text(create_server_pushforce_text, create_server_pushforce_cursor, FALSE);
		ypos += 18;

		menu_text_field_tight("Use Force",   "create_ph_usef",  [xpos,              ypos], half_w, 6, create_server_useforce_text,   create_server_useforce_cursor);
		menu_sanitize_numeric_text(create_server_useforce_text, create_server_useforce_cursor, FALSE);
		menu_text_field_tight("Use VelMult", "create_ph_uvm",   [xpos + half_w + 4, ypos], half_w, 5, create_server_usevelmult_text, create_server_usevelmult_cursor);
		menu_sanitize_numeric_text(create_server_usevelmult_text, create_server_usevelmult_cursor, FALSE);
		ypos += 18;

		menu_text_field_tight("Mass",        "create_ph_mass",  [xpos,              ypos], half_w, 4, create_server_mass_text,       create_server_mass_cursor);
		menu_sanitize_numeric_text(create_server_mass_text, create_server_mass_cursor, FALSE);
		menu_text_field_tight("Push Radius", "create_ph_prad",  [xpos + half_w + 4, ypos], half_w, 4, create_server_pushradius_text, create_server_pushradius_cursor);
		menu_sanitize_numeric_text(create_server_pushradius_text, create_server_pushradius_cursor, FALSE);
		ypos += 18;

		// Decimal rows (half-width paired, tight labels)
		menu_text_field_tight("Push Height", "create_ph_phh",   [xpos,              ypos], half_w, 5, create_server_pushheight_text, create_server_pushheight_cursor);
		menu_sanitize_numeric_text(create_server_pushheight_text, create_server_pushheight_cursor, TRUE);
		menu_text_field_tight("Friction",    "create_ph_frict", [xpos + half_w + 4, ypos], half_w, 5, create_server_phfriction_text, create_server_phfriction_cursor);
		menu_sanitize_numeric_text(create_server_phfriction_text, create_server_phfriction_cursor, TRUE);
		ypos += 18;

		menu_text_field_tight("Damp Lin",    "create_ph_dl",    [xpos,              ypos], half_w, 5, create_server_damplin_text,    create_server_damplin_cursor);
		menu_sanitize_numeric_text(create_server_damplin_text, create_server_damplin_cursor, TRUE);
		menu_text_field_tight("Damp Ang",    "create_ph_da",    [xpos + half_w + 4, ypos], half_w, 5, create_server_dampang_text,    create_server_dampang_cursor);
		menu_sanitize_numeric_text(create_server_dampang_text, create_server_dampang_cursor, TRUE);
		ypos += 18;

		menu_text_field_tight("Plr Bounce",  "create_ph_bnc",   [xpos,              ypos], half_w, 5, create_server_playerbounce_text, create_server_playerbounce_cursor);
		menu_sanitize_numeric_text(create_server_playerbounce_text, create_server_playerbounce_cursor, TRUE);
		menu_text_field_tight("Plr Kickback","create_ph_kb",    [xpos + half_w + 4, ypos], half_w, 6, create_server_kickback_text,   create_server_kickback_cursor);
		menu_sanitize_numeric_text(create_server_kickback_text, create_server_kickback_cursor, TRUE);
		ypos += 18;

		menu_text_field_tight("Plr MinKick", "create_ph_mk",    [xpos,              ypos], half_w, 5, create_server_minkick_text,    create_server_minkick_cursor);
		menu_sanitize_numeric_text(create_server_minkick_text, create_server_minkick_cursor, FALSE);
		menu_text_field_tight("ODE Iter",    "create_ph_oiter", [xpos + half_w + 4, ypos], half_w, 3, create_server_odeiter_text,    create_server_odeiter_cursor);
		menu_sanitize_numeric_text(create_server_odeiter_text, create_server_odeiter_cursor, FALSE);
		ypos += 18;

		menu_text_field_tight("ERP",         "create_ph_erp",   [xpos,              ypos], half_w, 5, create_server_erp_text,        create_server_erp_cursor);
		menu_sanitize_numeric_text(create_server_erp_text, create_server_erp_cursor, TRUE);
		ypos += 20;

		// Shape / Axis cycle buttons (half-width paired)
		if (my_button("create_ph_shape", [xpos,              ypos], [half_w, 20], sprintf("Shape: %s", physprop_shapes[create_server_shape_index])))
			create_server_shape_index = (create_server_shape_index + 1) - floor((create_server_shape_index + 1) / physprop_shapes.length) * physprop_shapes.length;
		if (my_button("create_ph_axis",  [xpos + half_w + 4, ypos], [half_w, 20], sprintf("Axis: %s",  physprop_axes[create_server_axis_index])))
			create_server_axis_index  = (create_server_axis_index  + 1) - floor((create_server_axis_index  + 1) / physprop_axes.length)  * physprop_axes.length;
		ypos += 22;

		// Toggles
		menu_toggle_button("create_ph_pt", [xpos,              ypos], [half_w, 20], "Passthrough", create_server_passthrough);
		menu_toggle_button("create_ph_qc", [xpos + half_w + 4, ypos], [half_w, 20], "QC Collide",  create_server_qccollide);
		ypos += 22;

		menu_toggle_button("create_ph_oq",  [xpos,              ypos], [half_w, 20], "ODE QuickStep",  create_server_odequick);
		menu_toggle_button("create_ph_oad", [xpos + half_w + 4, ypos], [half_w, 20], "ODE AutoDisable", create_server_odeautodisable);
	}

	// Bottom buttons — Back matches the width of the "Refresh Maps" button
	// above (left_width); Start Server spans the Physics tab width.
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_END]);
	if (my_button("create_back", [pad, -8], [left_width, 20], "Back"))
	{
		create_server_map_dropdown_open = FALSE;
		current_menu = MENU_MAIN;
	}

	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_END]);
	if (has_maps)
	{
		if (my_button_colored("create_launch", [-pad, -8], [property_width, 20], "Start Server",
			MENU_BUTTON_RETURN, MENU_BUTTON_RETURN_BORDER))
			create_server_launch();
	}
	else
	{
		menu_disabled_button([-pad, -8], [property_width, 20], "Start Server");
	}

	// Overlay: draw any open Default Loadout list on top of the footer so
	// the picker is visible and clickable even when it would overlap the
	// Start Server button.  Only the Game tab draws the buttons, so these
	// positions are zero on other tabs and the `is_open` guards no-op.
	// Reset alignment — the footer buttons above left it at END/END, which
	// would reinterpret the stored positions relative to the bottom-right.
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	if (create_server_tab == 1)
	{
		menu_dropdown_list("create_def_prim", cs_default_primary_pos, cs_default_primary_size,
			cs_default_primary_options, cs_default_primary_idx, cs_default_primary_open, cs_default_primary_scroll);
		menu_dropdown_list("create_def_sec", cs_default_secondary_pos, cs_default_secondary_size,
			cs_default_secondary_options, cs_default_secondary_idx, cs_default_secondary_open, cs_default_secondary_scroll);
		menu_dropdown_list("create_def_mel", cs_default_melee_pos, cs_default_melee_size,
			cs_default_melee_options, cs_default_melee_idx, cs_default_melee_open, cs_default_melee_scroll);
		menu_dropdown_list("create_def_util", cs_default_utility_pos, cs_default_utility_size,
			cs_default_utility_options, cs_default_utility_idx, cs_default_utility_open, cs_default_utility_scroll);
	}

	sui_set_default_kb_focus("create_name");

	if (sui_listen_back())
	{
		create_server_map_dropdown_open = FALSE;
		current_menu = MENU_MAIN;
	}

	sui_pop_frame();
};
