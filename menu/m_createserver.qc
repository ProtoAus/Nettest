// Not in the menu's stock defs — declare the named builtin so we can tell which
// mounted game/package each map came from (used to bucket the map list by game).
string(searchhandle handle, float num) search_getpackagename = #0:search_getpackagename;

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
string create_server_port_text;
float create_server_port_cursor;
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
float create_server_nomapweapons;
// Hitmarker / damage owner: 0 = server-auth (server traces decide hits and
// emits hitmarker), 1 = trust client claims (client predicts hitmarker
// locally, server suppresses its own emit to dedupe).  Mode 2 (full trust,
// no sanity checks) is power-user — not exposed in the menu, set via
// console / data/server.cfg if needed.
float create_server_trust_clienthits;
// Voice / VoIP server-side toggles.  voip_record cycles through
// 0=off / 1=record-all / 2=spectators-only (matches engine sv_voip_record
// values).  voip_echo is debug-only.
float create_server_voip;
float create_server_voip_record;     // 0..2
float create_server_voip_echo;
float create_server_seeded;
float create_server_tab;    // 0 = server, 1 = game, 2 = movement
float create_server_tickrate_index;
float create_server_game_filter;	// map-list filter: 0=All 1=Nettest 2=CS 3=HL 4=CoD1 5=CoD2 6=Source
string create_server_game_labels[7] = { "Net", "CS", "HL", "CoD1", "CoD2", "HL2", "CSS" };
// Which game categories actually have maps in the offline index (data/maps_index.txt),
// keyed by game id (1..7).  Built once by create_server_scan_avail(); the filter row only
// draws tabs for games that are present, so e.g. the CoD tabs vanish without CoD content.
float  create_server_game_has_maps[8];
float  create_server_avail_scanned;

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

// --- Gamemode dropdown state ---
float  create_server_gamemode_open;
vector create_server_gamemode_scroll;
vector create_server_gamemode_pos;
vector create_server_gamemode_size;
strbuf create_server_gamemode_options;
float  create_server_gamemode_options_loaded;

// --- Physics tab state ---

string create_server_hitforce_text;       float create_server_hitforce_cursor;
string create_server_useforce_text;       float create_server_useforce_cursor;
string create_server_usevelmult_text;     float create_server_usevelmult_cursor;
string create_server_mass_text;           float create_server_mass_cursor;
string create_server_odeiter_text;        float create_server_odeiter_cursor;
string create_server_erp_text;            float create_server_erp_cursor;
string create_server_damplin_text;        float create_server_damplin_cursor;
string create_server_dampang_text;        float create_server_dampang_cursor;
string create_server_phfriction_text;     float create_server_phfriction_cursor;
float  create_server_odequick;
float  create_server_odeautodisable;

// --- Default-loadout dropdown state ---
// Default-loadout dropdown options are built from shared/sh_weapon_manifest.qc.

float cs_default_primary_idx;     float  cs_default_primary_open;     vector cs_default_primary_scroll;
float cs_default_secondary_idx;   float  cs_default_secondary_open;   vector cs_default_secondary_scroll;
float cs_default_melee_idx;       float  cs_default_melee_open;       vector cs_default_melee_scroll;
float cs_default_utility_idx;     float  cs_default_utility_open;     vector cs_default_utility_scroll;
// Multi-select bitmask of cs_default_utility_options indices.  Bit i
// means option i is checked.  sv_default_utility serialises as a
// comma-separated weapon-id list so the player can spawn with multiple
// grenades simultaneously.  cs_default_utility_idx stays as the
// "first checked" index (used by code paths that still treat it as a
// single selection — they get the active utility).
float cs_default_utility_mask;

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

// Create Server reads weapon names and loadout options from the shared
// metadata-only manifest.
string(string raw) create_server_weapon_name_key =
{
    return WeaponManifest_NameKey(raw);
};

float(string raw, float fallback) create_server_weapon_id_from_string_or_default =
{
    return WeaponManifest_IdFromStringOrDefault(raw, fallback);
};

void() create_server_load_gamemode_options =
{
	if (create_server_gamemode_options_loaded)
		return;

	create_server_gamemode_options = buf_create();
	bufstr_add(create_server_gamemode_options, "Team Deathmatch", FALSE);
	bufstr_add(create_server_gamemode_options, "Elimination", FALSE);
	bufstr_add(create_server_gamemode_options, "Bhop", FALSE);
	bufstr_add(create_server_gamemode_options, "Free For All", FALSE);
	bufstr_add(create_server_gamemode_options, "Paintball", FALSE);
	bufstr_add(create_server_gamemode_options, "Defuse", FALSE);
	bufstr_add(create_server_gamemode_options, "Prop Hunt", FALSE);
	create_server_gamemode_options_loaded = TRUE;
};

void() create_server_load_loadout_options =
{
    float i;

    if (cs_default_options_loaded)
        return;

    cs_default_primary_options = buf_create();
    for (i = 0; i < WeaponManifest_LoadoutCount(WMF_SLOT_PRIMARY); i++)
        bufstr_add(cs_default_primary_options, WeaponManifest_LoadoutLabel(WMF_SLOT_PRIMARY, i), FALSE);

    cs_default_secondary_options = buf_create();
    for (i = 0; i < WeaponManifest_LoadoutCount(WMF_SLOT_SECONDARY); i++)
        bufstr_add(cs_default_secondary_options, WeaponManifest_LoadoutLabel(WMF_SLOT_SECONDARY, i), FALSE);

    cs_default_melee_options = buf_create();
    for (i = 0; i < WeaponManifest_LoadoutCount(WMF_SLOT_MELEE); i++)
        bufstr_add(cs_default_melee_options, WeaponManifest_LoadoutLabel(WMF_SLOT_MELEE, i), FALSE);

    // Grenades are a multi-select tickbox list, so the "None" entry (loadout
    // index 0) is meaningless here — untick everything == no grenades.  Start
    // at index 1 to drop it; this shifts the tickbox-bit <-> weapon mapping by
    // one, handled in the mask<->cvar conversions below.
    cs_default_utility_options = buf_create();
    for (i = 1; i < WeaponManifest_LoadoutCount(WMF_SLOT_UTILITY); i++)
        bufstr_add(cs_default_utility_options, WeaponManifest_LoadoutLabel(WMF_SLOT_UTILITY, i), FALSE);

    cs_default_options_loaded = TRUE;
};

// Convert sv_default_utility (comma-separated weapon ids) → bitmask of
// indices into cs_default_utility_options.  Unknown / non-utility ids
// are silently ignored.  Single-int strings ("33") still parse since
// tokenizebyseparator returns one token in that case.
float(string list) create_server_utility_mask_from_cvar =
{
    float mask = 0;
    if (list == "")
        return 0;
    float n = tokenizebyseparator(list, ",");
    float i;
    for (i = 0; i < n; i++)
    {
        float id  = create_server_weapon_id_from_string_or_default(argv(i), 0);
        float idx = WeaponManifest_LoadoutFindIndex(WMF_SLOT_UTILITY, id);
        // Options start at loadout index 1 (None dropped), so the tickbox bit
        // is idx-1.  Skip None / unknown ids.
        if (idx < 1 || idx >= WeaponManifest_LoadoutCount(WMF_SLOT_UTILITY))
            continue;
        mask = mask | pow(2, idx - 1);
    }
    return mask;
};

// Convert mask → comma-separated id list for cvar_set.  Empty mask
// serialises as "0" so PlayerSpawn falls back to WEP_NONE.
string(float mask) create_server_utility_mask_to_cvar =
{
    string out = "";
    // Tickbox bit i maps to loadout index i+1 (None at index 0 is not shown).
    float grenades = WeaponManifest_LoadoutCount(WMF_SLOT_UTILITY) - 1;
    float i, n_set = 0;
    for (i = 0; i < grenades; i++)
    {
        if (!(mask & pow(2, i)))
            continue;
        float id = WeaponManifest_LoadoutWeapon(WMF_SLOT_UTILITY, i + 1);
        if (n_set == 0)
            out = ftos(id);
        else
            out = strcat(out, ",", ftos(id));
        n_set++;
    }
    if (n_set == 0)
        return "0";
    return out;
};

// Return the option-index of the lowest set bit in the mask, or 0 if
// the mask is empty.  Used to keep cs_default_utility_idx in sync as
// the "active utility" (matches what the runtime spawns into slot_utility).
float(float mask) create_server_utility_first_idx =
{
    float i;
    for (i = 0; i < 24; i++)
        if (mask & pow(2, i))
            return i;
    return 0;
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

	// Seed from the cvar, but bump anything below 4 up to the mod default
	// (16). Keeps old installs whose data/server.cfg still has the legacy
	// "2" from breaking back down every time the menu is opened.
	maxplayers_text = cvar_string("maxclients");
	if (maxplayers_text == "" || stof(maxplayers_text) < 4)
		maxplayers_text = "16";
	if (create_server_maxplayers_text == "")
	{
		create_server_maxplayers_text = maxplayers_text;
		create_server_maxplayers_cursor = strlen(create_server_maxplayers_text);
	}

	menu_seed_text_from_cvar("password", "", create_server_password_text, create_server_password_cursor);
	if (create_server_rcon_password_text == "")
	{
		create_server_rcon_password_text = cvar_string("sv_rcon_password_shadow");
		if (create_server_rcon_password_text == "")
			create_server_rcon_password_text = Menu_ReadConfigValue("data/server.cfg", "rcon_password");
		create_server_rcon_password_cursor = strlen(create_server_rcon_password_text);
	}
	// Port defaults to 27500 — never seed from the live sv_port cvar because
	// the backdrop launcher temporarily moves it into the 27501..27600 range,
	// and we don't want that ephemeral value showing up in the form.
	if (create_server_port_text == "")
	{
		create_server_port_text   = "27500";
		create_server_port_cursor = strlen(create_server_port_text);
	}
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
	create_server_voip        = cvar("sv_voip") > 0;
	create_server_voip_record = bound(0, cvar("sv_voip_record"), 2);
	create_server_voip_echo   = cvar("sv_voip_echo") > 0;
	create_server_friendlyfire = cvar("mp_friendlyfire") > 0;
	create_server_autohop = cvar("sv_autohop") > 0;
	create_server_falldamage = cvar("mp_falldamage") > 0;
	create_server_stamina = cvar("sv_stamina") > 0;
	create_server_load_gamemode_options();
	create_server_gamemode = cvar("sv_gamemode");
	create_server_gamemode = bound(0, create_server_gamemode, buf_getsize(create_server_gamemode_options) - 1);
	create_server_cheats = cvar("mp_cheats") > 0;
	create_server_noblock = cvar("mp_noblock") > 0;
	create_server_nomapweapons = cvar("mp_nomapweapons") > 0;
	// Treat any non-zero value as "on" so an admin who's set mode 2 from
	// the console doesn't see the toggle flicker to off here.  Saving
	// the toggle writes 0 or 1 and clears mode 2 — fine, mode 2 is for
	// debugging only.
	create_server_trust_clienthits = cvar("sv_trust_clienthits") > 0;

	// Seed default-loadout dropdown indices from the sv_default_* cvars.
	// Each cvar stores a WEP_* integer; find its manifest loadout index.
	create_server_load_loadout_options();
	{
		float want;

		want = create_server_weapon_id_from_string_or_default(cvar_string("sv_default_primary"), 0);
		cs_default_primary_idx = WeaponManifest_LoadoutFindIndex(WMF_SLOT_PRIMARY, want);

		want = create_server_weapon_id_from_string_or_default(cvar_string("sv_default_secondary"), 0);
		cs_default_secondary_idx = WeaponManifest_LoadoutFindIndex(WMF_SLOT_SECONDARY, want);

		want = create_server_weapon_id_from_string_or_default(cvar_string("sv_default_melee"), 0);
		cs_default_melee_idx = WeaponManifest_LoadoutFindIndex(WMF_SLOT_MELEE, want);

		// Utility is multi-select; seed both the bitmask and the legacy
		// single-index (kept in sync as "first checked" so any code that
		// still reads cs_default_utility_idx stays correct).
		cs_default_utility_mask = create_server_utility_mask_from_cvar(cvar_string("sv_default_utility"));
		cs_default_utility_idx  = create_server_utility_first_idx(cs_default_utility_mask);
	}

	// Physics tab seeding
	menu_seed_text_from_cvar("sv_physprop_hit_force",         "8000",  create_server_hitforce_text,     create_server_hitforce_cursor);
	menu_seed_text_from_cvar("sv_physprop_use_force",         "800",   create_server_useforce_text,     create_server_useforce_cursor);
	menu_seed_text_from_cvar("sv_physprop_use_velmult",       "800",   create_server_usevelmult_text,   create_server_usevelmult_cursor);
	menu_seed_text_from_cvar("sv_physprop_mass",              "20",    create_server_mass_text,         create_server_mass_cursor);
	menu_seed_text_from_cvar("physics_ode_iterationsperframe","10",    create_server_odeiter_text,      create_server_odeiter_cursor);
	menu_seed_text_from_cvar("sv_physprop_erp",               "0",     create_server_erp_text,          create_server_erp_cursor);
	menu_seed_text_from_cvar("sv_physprop_damp_lin",          "0.01",  create_server_damplin_text,      create_server_damplin_cursor);
	menu_seed_text_from_cvar("sv_physprop_damp_ang",          "0.01",  create_server_dampang_text,      create_server_dampang_cursor);
	menu_seed_text_from_cvar("sv_physprop_friction",          "1.0",   create_server_phfriction_text,   create_server_phfriction_cursor);

	create_server_odequick       = cvar("physics_ode_worldquickstep") > 0;
	create_server_odeautodisable = cvar("physics_ode_autodisable") > 0;

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

// ---- Multi-select dropdown ----
// `selection_mask` is a float bitmask of option indices (bit i set =
// option i is checked).  Float can exactly represent integers up to
// 2^24, more than enough for the small option lists this is used with
// (utility loadout has ≤ 8 entries).  Click on the button toggles the
// list open/closed; click on a list item toggles that option's bit
// without closing the list.
//
// Caller-side cvar serialisation: convert the mask to / from a comma-
// separated weapon-id list using create_server_utility_mask_to_cvar /
// create_server_utility_mask_from_cvar (defined below).

string(strbuf options, float mask) menu_multidropdown_summary =
{
    float count = buf_getsize(options);
    float i, n_set = 0;
    string out = "";
    for (i = 0; i < count; i++)
    {
        if (!(mask & pow(2, i)))
            continue;
        if (n_set == 0)
            out = bufstr_get(options, i);
        else if (n_set < 2)
            out = strcat(out, ", ", bufstr_get(options, i));
        n_set++;
    }
    if (n_set == 0)
        return "(none)";
    if (n_set > 2)
        return sprintf("%g selected", n_set);
    return out;
};

float(string id, vector pos, vector size, strbuf options, __inout float selection_mask, __inout float is_open) menu_multidropdown_button =
{
    float count = buf_getsize(options);
    string button_text = menu_multidropdown_summary(options, selection_mask);
    vector button_color = MENU_BUTTON;
    vector border_color = MENU_BUTTON_BORDER;

    if (count <= 0)
    {
        is_open = FALSE;
        button_color = MENU_BG_DARK;
        border_color = MENU_BORDER;
        button_text = "(no options)";
    }
    else
    {
        button_text = strcat(button_text, is_open ? " -" : " v");
    }

    if (my_button_colored(strcat(id, "_btn"), pos, [size_x, 20], button_text, button_color, border_color) && count > 0)
    {
        is_open = !is_open;
        return TRUE;
    }
    return FALSE;
};

float(string id, vector pos, vector size, strbuf options, __inout float selection_mask, __inout float is_open, __inout vector scrollofs) menu_multidropdown_list =
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
        float bit = pow(2, index);
        float checked = (selection_mask & bit) ? 1 : 0;
        string item = strcat(checked ? "[x] " : "[ ] ", bufstr_get(options, index));
        vector item_color  = checked ? MENU_BUTTON_RETURN        : MENU_BUTTON;
        vector item_border = checked ? MENU_BUTTON_RETURN_BORDER : MENU_BUTTON_BORDER;

        if (!my_button_colored(strcat(id, "_item", ftos(index)), listitem_pos, [size_x - 8, 20], item, item_color, item_border))
            continue;

        // Toggle this bit; keep list open so user can pick more items.
        if (checked)
            selection_mask = selection_mask - bit;
        else
            selection_mask = selection_mask + bit;
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

// Bucket a map by its SOURCE GAME spec (the fs_addons.txt dir it came from, as written into
// data/maps_index.txt by the engine's `fs_indexmaps`).  This is the reliable signal — the spec is
// the real game dir, so CS:S ("...Counter-Strike Source/cstrike") and CS1.6 ("...Half-Life/cstrike")
// are distinguished even though both end in "cstrike" and share map names (de_dust2).
// Returns the game id used by create_server_game_filter (1..7).
float(string spec) create_server_map_game =
{
	string p = strtolower(spec);
	if (strstrofs(p, "call of duty 2") >= 0) return 5;	// CoD2
	if (strstrofs(p, "call of duty") >= 0)   return 4;	// CoD1
	if (strstrofs(p, "counter-strike source") >= 0) return 7;	// CS:Source (own category, checked before cstrike)
	if (strstrofs(p, "half-life 2") >= 0)    return 6;	// HL2 (Source)
	if (strstrofs(p, "cstrike") >= 0)        return 2;	// CS 1.6 (GoldSrc cstrike gamedir)
	if (strstrofs(p, "valve") >= 0)          return 3;	// Half-Life
	// This mod's own maps.  BOTH spellings are matched on purpose: the engine writes the tag for
	// non-addon (i.e. our own) maps as a HARDCODED literal — common/fs.c FS_IndexAddonMaps does
	//     ctx.tag = "nettest";
	// — so it did NOT follow the nettest->quakers gamedir rename.  Matching only "quakers" made
	// every one of our maps fall through to the `return 6` default and get filed under HL2, which
	// emptied the Net tab in the Create Server menu.  Accepting both keeps this working against a
	// stock engine build and a fixed one.  The durable fix is engine-side: derive that tag from the
	// live gamedir instead of a string literal, then this line can drop "nettest".
	if (strstrofs(p, "quakers") >= 0)        return 1;	// this mod
	if (strstrofs(p, "nettest") >= 0)        return 1;	// this mod, pre-rename engine tag
	return 6;	// HL2 / other Source
};

// Read the engine-built OFFLINE map index (data/maps_index.txt — one "<sourcespec>\t<mapname>"
// line per map, written by `fs_indexmaps`; no game is mounted to build it).  Add the maps whose
// source game matches the active filter (0 = All).  Replaces the old search_begin scan, which
// only saw MOUNTED games and shadowed same-named maps (the missing-CS:S-maps bug).
void(float filter) create_server_read_index =
{
	float fh = fopen("data/maps_index.txt", FILE_READ);
	if (fh < 0)
		return;
	string line = fgets(fh);
	while (line)
	{
		float n = strlen(line);
		if (n > 0 && substring(line, n - 1, 1) == "\r")
		{
			line = substring(line, 0, n - 1);
			n -= 1;
		}
		float tab = strstrofs(line, "\t");
		if (tab > 0)
		{
			string spec = substring(line, 0, tab);
			string mapname = substring(line, tab + 1, n - tab - 1);
			if (mapname != "" &&
			    (filter == 0 || create_server_map_game(spec) == filter) &&
			    !menu_buf_contains(create_server_maps, mapname))
				bufstr_add(create_server_maps, mapname, FALSE);
		}
		line = fgets(fh);
	}
	fclose(fh);
};

// One-time scan of the offline index: mark which game categories (1..7) actually have maps,
// so the filter row can hide tabs for games you don't have loaded (no CoD content -> no CoD
// tab).  Net (1) is the base mod and is always shown.  Cheap (single file read), gated by
// create_server_avail_scanned so it runs once per session, not per menu frame.
void() create_server_scan_avail =
{
	float gid;
	for (gid = 0; gid <= 7; gid += 1)
		create_server_game_has_maps[gid] = 0;
	create_server_game_has_maps[1] = 1;	// Net = the running mod, always available

	float fh = fopen("data/maps_index.txt", FILE_READ);
	if (fh >= 0)
	{
		string line = fgets(fh);
		while (line)
		{
			float n = strlen(line);
			if (n > 0 && substring(line, n - 1, 1) == "\r")
			{
				line = substring(line, 0, n - 1);
				n -= 1;
			}
			float tab = strstrofs(line, "\t");
			if (tab > 0)
			{
				string spec = substring(line, 0, tab);
				string mapname = substring(line, tab + 1, n - tab - 1);
				if (mapname != "")
					create_server_game_has_maps[create_server_map_game(spec)] = 1;
			}
			line = fgets(fh);
		}
		fclose(fh);
	}
	create_server_avail_scanned = 1;
};

// Find a map's source-game spec in the index.  Filter-aware: when a game tab is active, match THAT
// game so de_dust2 resolves to the right one (CS:S vs CS1.6).  Returns "" if not found.
string(string mapname, float filter) create_server_index_spec_for =
{
	float fh = fopen("data/maps_index.txt", FILE_READ);
	if (fh < 0)
		return "";
	string result = "";
	string line = fgets(fh);
	while (line)
	{
		float n = strlen(line);
		if (n > 0 && substring(line, n - 1, 1) == "\r")
		{
			line = substring(line, 0, n - 1);
			n -= 1;
		}
		float tab = strstrofs(line, "\t");
		if (tab > 0)
		{
			string spec = substring(line, 0, tab);
			string mn = substring(line, tab + 1, n - tab - 1);
			if (mn == mapname && (filter == 0 || create_server_map_game(spec) == filter))
			{
				result = spec;
				break;
			}
		}
		line = fgets(fh);
	}
	fclose(fh);
	return result;
};

// fs_useaddons argument string for a map's source game: BASE game(s) first, then the source dir,
// each quoted (specs contain spaces).  "" => clear all addons (a nettest/base map needs none).
// CS:Source maps need the HL2 base content; CS 1.6 maps need the Half-Life (valve) base.
// The mod CURRENTLY borrows gameplay/map assets from Half-Life (valve) + CS 1.6 (cstrike), so those
// are the always-mounted BASE that EVERY map needs (nettest's own maps included) — the selected map's
// own game is ADDED on top, never swapped in.  A per-game EXCLUSIVE mount broke things: dropping
// valve/cstrike for a CS:S/HL2/CoD map strips the mod itself (missing player models/textures -> crash;
// "maps that worked before stop working").  When nettest is fully self-contained, empty `base` below
// to make it truly lazy (only each game's own content mounts for its own maps).
string(string spec) create_server_deps_for_spec =
{
	string base = "\"steam:Half-Life/valve\" \"steam:Half-Life/cstrike\"";
	float gid = create_server_map_game(spec);
	if (gid == 7)               // CS:Source -> base + HL2 content + the CS:S cstrike dir
		return strcat(base, " \"steam:Half-Life 2/hl2\" \"steam:Counter-Strike Source/cstrike\"");
	if (gid == 6)               // HL2 -> base + hl2
		return strcat(base, " \"steam:Half-Life 2/hl2\"");
	if (gid == 4 || gid == 5)   // CoD1/CoD2 -> base + that CoD dir (its content lives in .iwd/.pk3)
		return strcat(base, " \"", spec, "\"");
	return base;                // nettest / CS 1.6 / HL -> just the always-mounted base
};

// Lazy-mount exactly the given map's game (+ base deps) on demand.  Must run right before the
// `map` command (same command buffer, FIFO) so the load sees the content mounted.  An empty deps
// string (nettest/base map) clears all addons so a previously-selected game's content can't shadow.
void(string mapname, float filter) create_server_mount_for_map =
{
	string spec = create_server_index_spec_for(mapname, filter);
	if (spec == "")
		return;	// not indexed (e.g. true first boot before fs_indexmaps) -> leave the addon set as-is
	// deps is the always-mounted base (valve+cstrike) + this map's own game.  Setting it drops any
	// game from a PREVIOUS selection that this map doesn't use (the engine no-ops when unchanged, so
	// re-selecting the same game / a base-only map at boot costs nothing).
	string deps = create_server_deps_for_spec(spec);
	localcmd(strcat("fs_useaddons ", deps, "\n"));
};

void() create_server_load_maps =
{
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

	// Read the offline index (both .bsp and .d3dbsp were indexed by the engine), bucketed by
	// source game via create_server_game_filter (0 = All).
	create_server_read_index(create_server_game_filter);

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

	menu_normalize_integer_text(16, 2, 64, create_server_maxplayers_text, create_server_maxplayers_cursor);
	// Port: clamp to 1..65535. Default 27500 (PORT_DEFAULTSERVER).
	menu_normalize_integer_text(27500, 1, 65535, create_server_port_text, create_server_port_cursor);
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
	menu_normalize_integer_text(800,  0, 100000, create_server_useforce_text,   create_server_useforce_cursor);
	menu_normalize_integer_text(800,  0, 10000,  create_server_usevelmult_text, create_server_usevelmult_cursor);
	menu_normalize_integer_text(20,   1, 1000,   create_server_mass_text,       create_server_mass_cursor);
	menu_normalize_integer_text(10,   1, 60,     create_server_odeiter_text,    create_server_odeiter_cursor);

	// Compute tickrate values
	float tick = tickrates[create_server_tickrate_index];
	string tic_val = sprintf("%.6f", 1.0 / tick);

	// Apply all cvars
	cvar_set("hostname", create_server_name_text);
	cvar_set("maxclients", create_server_maxplayers_text);
	cvar_set("password", create_server_password_text);
	cvar_set("rcon_password", create_server_rcon_password_text);
	cvar_set("sv_rcon_password_shadow", create_server_rcon_password_text);
	cvar_set("sv_pure", create_server_pure ? "1" : "0");
	cvar_set("sv_voip", create_server_voip ? "1" : "0");
	cvar_set("sv_voip_record", ftos(create_server_voip_record));
	cvar_set("sv_voip_echo", create_server_voip_echo ? "1" : "0");
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
	cvar_set("mp_nomapweapons", create_server_nomapweapons ? "1" : "0");
	cvar_set("sv_autohop", create_server_autohop ? "1" : "0");
	cvar_set("mp_falldamage", create_server_falldamage ? "1" : "0");
	cvar_set("sv_stamina", create_server_stamina ? "1" : "0");
	cvar_set("sv_trust_clienthits", create_server_trust_clienthits ? "1" : "0");
	cvar_set("sv_gamemode", ftos(create_server_gamemode));

	// Apply gamemode-default toggles so the saved server.cfg reflects
	// what this gamemode wants out of the box. SSQC's StartFrame also
	// re-asserts these on each map load (gamemode-changed branch in
	// sv_main.qc) — applying them here too means the very first
	// server.cfg write after Create Server is already correct, instead
	// of carrying over stale `mp_respawn 0` from a previous Elimination
	// session. Mirrors sv_main.qc's per-gamemode block exactly.
	// IDs match the dropdown order seeded in create_server_gamemode_options
	// init (TDM=0, ELIMINATION=1, BHOP=2, FFA=3, PAINTGUN=4); shared/
	// sh_customdefs.qc isn't included in m_progs.src so the GAMEMODE_*
	// constants aren't visible — keep the IDs in sync if you rename them.
	if (create_server_gamemode == 2)         // BHOP
	{
		cvar_set("mp_falldamage",   "0");
		cvar_set("mp_noblock",      "1");
		cvar_set("mp_respawn",      "1");
		cvar_set("mp_disabledoors", "1");
	}
	else if (create_server_gamemode == 3)    // FFA
	{
		cvar_set("mp_respawn",      "1");
		cvar_set("mp_disabledoors", "0");
	}
	else if (create_server_gamemode == 1)    // ELIMINATION
	{
		cvar_set("mp_respawn",      "0");
		cvar_set("mp_disabledoors", "0");
	}
	else if (create_server_gamemode == 4)    // PAINTGUN
	{
		cvar_set("mp_respawn",      "0");
		cvar_set("mp_disabledoors", "0");
		cvar_set("mp_falldamage",   "0");
		cvar_set("mp_nomapweapons", "1");
	}
	else if (create_server_gamemode == 5)    // DEFUSE — one life per round
	{
		cvar_set("mp_respawn",      "0");
		cvar_set("mp_disabledoors", "0");
	}
	else if (create_server_gamemode == 6)    // PROPHUNT — one life, no falldamage
	{
		cvar_set("mp_respawn",      "0");
		cvar_set("mp_disabledoors", "0");
		cvar_set("mp_falldamage",   "0");
		cvar_set("mp_nomapweapons", "1");
	}
	else                                      // TDM (0) — fallback
	{
		cvar_set("mp_respawn",      "1");
		cvar_set("mp_disabledoors", "0");
	}

	// Default-loadout WEP_* IDs.  Index is clamped because the dropdown
	// arrays might change between sessions (e.g. a weapon was removed).
	cs_default_primary_idx   = bound(0, cs_default_primary_idx,   WeaponManifest_LoadoutCount(WMF_SLOT_PRIMARY)   - 1);
	cs_default_secondary_idx = bound(0, cs_default_secondary_idx, WeaponManifest_LoadoutCount(WMF_SLOT_SECONDARY) - 1);
	cs_default_melee_idx     = bound(0, cs_default_melee_idx,     WeaponManifest_LoadoutCount(WMF_SLOT_MELEE)     - 1);
	cs_default_utility_idx   = create_server_utility_first_idx(cs_default_utility_mask);
	cvar_set("sv_default_primary",   ftos(WeaponManifest_LoadoutWeapon(WMF_SLOT_PRIMARY, cs_default_primary_idx)));
	cvar_set("sv_default_secondary", ftos(WeaponManifest_LoadoutWeapon(WMF_SLOT_SECONDARY, cs_default_secondary_idx)));
	cvar_set("sv_default_melee",     ftos(WeaponManifest_LoadoutWeapon(WMF_SLOT_MELEE, cs_default_melee_idx)));
	// Utility serialises as a comma-separated id list (multi-select).
	cvar_set("sv_default_utility",   create_server_utility_mask_to_cvar(cs_default_utility_mask));

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
	cvar_set("sv_physprop_use_force",       create_server_useforce_text);
	cvar_set("sv_physprop_use_velmult",     create_server_usevelmult_text);
	cvar_set("sv_physprop_mass",            create_server_mass_text);
	cvar_set("sv_physprop_erp",             create_server_erp_text);
	cvar_set("sv_physprop_damp_lin",        create_server_damplin_text);
	cvar_set("sv_physprop_damp_ang",        create_server_dampang_text);
	cvar_set("sv_physprop_friction",        create_server_phfriction_text);
	cvar_set("physics_ode_iterationsperframe", create_server_odeiter_text);
	cvar_set("physics_ode_worldquickstep",  create_server_odequick ? "1" : "0");
	cvar_set("physics_ode_autodisable",     create_server_odeautodisable ? "1" : "0");

	// Save only the server cvars to data/server.cfg.
	// sv_main.qc applies this file on worldspawn to pick up the values.
	Menu_SaveServerConfig();

	create_server_map_dropdown_open = FALSE;
	create_server_gamemode_open = FALSE;
	current_menu = MENU_MAIN;
	m_close();
	// Leaving the backdrop — the new map is a real game, so CSQC should
	// show HUD + team-select normally.  See m_main.qc m_init for details.
	localcmd("set cl_menu_backdrop_active 0\n");
	localcmd("set sv_backdrop 0\n");
	// Apply the user-chosen listen port (backdrop launchers temporarily
	// move sv_port into 27501..27600 to avoid blocking 27500 for another
	// local server — this restores the form's value).
	localcmd(sprintf("sv_port %s\n", create_server_port_text));
	// Lazy-mount: bring up exactly this map's game (+ base deps) BEFORE the map load.  Same command
	// buffer (FIFO) so `map` sees the content mounted; clears any previously-active game so a
	// same-named map (CS:S vs CS1.6 de_dust2) can't load the wrong content.
	create_server_mount_for_map(mapname, create_server_game_filter);
	// nettest (P26 Part 2): on a specific game tab, load THAT game's copy of a same-named map by qualifying
	// the map name with its source spec ("map @<spec>/<mapname>").  The engine biases ONLY the worldmodel
	// locate to that game's dir, so e.g. CS:S cs_assault loads instead of the higher-priority CS1.6 one.
	// The All tab (filter 0) keeps plain highest-priority behaviour.  The spec contains spaces and a ':' /
	// '/', so the whole arg MUST be quoted to stay one token (the engine splits the tag on the LAST '/').
	string spec = "";
	if (create_server_game_filter != 0)
		spec = create_server_index_spec_for(mapname, create_server_game_filter);
	if (spec != "")
		localcmd(sprintf("map \"@%s/%s\"\n", spec, mapname));
	else
		localcmd(sprintf("map %s\n", mapname));
};

// Game-filter tab row for the map list — click a game to show only its maps.
void(vector at, float w) create_server_draw_game_filter =
{
	float gid;
	// Count only the games that actually have maps — the tab row sizes/positions
	// itself to just those, so absent games (e.g. no CoD content) leave no gap.
	float n = 0;
	for (gid = 1; gid <= 7; gid += 1)
		if (create_server_game_has_maps[gid])
			n += 1;
	if (n < 1) n = 1;

	float g = 2;
	float bw = (w - g * (n - 1)) / n;
	vector on_col = MENU_BUTTON_RETURN,  on_brd = MENU_BUTTON_RETURN_BORDER;
	vector off_col = MENU_BG_DARK,       off_brd = MENU_BORDER;

	float slot = 0;
	for (gid = 1; gid <= 7; gid += 1)
	{
		if (!create_server_game_has_maps[gid])
			continue;
		float sel = (create_server_game_filter == gid);
		if (my_button_colored(strcat("gamefilter_", ftos(gid)), [at_x + slot * (bw + g), at_y], [bw, 18],
			create_server_game_labels[gid - 1], sel ? on_col : off_col, sel ? on_brd : off_brd))
		{
			if (create_server_game_filter != gid)
			{
				create_server_game_filter = gid;
				create_server_load_maps();
			}
		}
		slot += 1;
	}
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
	float map_panel_height = size_y - 64 - footer_height - 22;	// -22 for the game-filter tab row
	float xpos = 0;
	float ypos = 0;
	float has_maps = FALSE;
	float dropdown_height = 0;
	float map_count = 0;
	string selected_map = "";

	create_server_seed_fields();
	if (!create_server_avail_scanned)
		create_server_scan_avail();
	// Default to the Net tab — never "All" (0).  Also fall back to Net if the
	// remembered tab is a game you no longer have maps for, so you can't get stuck
	// on a tab that isn't drawn anymore; reload the list when the tab changes.
	if (create_server_game_filter < 1 || !create_server_game_has_maps[create_server_game_filter])
	{
		create_server_game_filter = 1;
		create_server_maps_loaded = FALSE;
	}
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
	create_server_draw_game_filter([xpos, ypos], left_width);
	ypos += 22;
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
		{
			create_server_gamemode_open = FALSE;
			cs_default_primary_open = FALSE;
			cs_default_secondary_open = FALSE;
			cs_default_melee_open = FALSE;
			cs_default_utility_open = FALSE;
			create_server_tab = 0;
		}

		if (my_button_colored("tab_game", [xpos + tab_w + 4, ypos], [tab_w, 20], "Game",
			create_server_tab == 1 ? active_col : inactive_col,
			create_server_tab == 1 ? active_brd : inactive_brd))
		{
			create_server_gamemode_open = FALSE;
			cs_default_primary_open = FALSE;
			cs_default_secondary_open = FALSE;
			cs_default_melee_open = FALSE;
			cs_default_utility_open = FALSE;
			create_server_tab = 1;
		}

		if (my_button_colored("tab_movement", [xpos + (tab_w + 4) * 2, ypos], [tab_w, 20], "Movement",
			create_server_tab == 2 ? active_col : inactive_col,
			create_server_tab == 2 ? active_brd : inactive_brd))
		{
			create_server_gamemode_open = FALSE;
			cs_default_primary_open = FALSE;
			cs_default_secondary_open = FALSE;
			cs_default_melee_open = FALSE;
			cs_default_utility_open = FALSE;
			create_server_tab = 2;
		}

		if (my_button_colored("tab_physics", [xpos + (tab_w + 4) * 3, ypos], [tab_w, 20], "Physics",
			create_server_tab == 3 ? active_col : inactive_col,
			create_server_tab == 3 ? active_brd : inactive_brd))
		{
			create_server_gamemode_open = FALSE;
			cs_default_primary_open = FALSE;
			cs_default_secondary_open = FALSE;
			cs_default_melee_open = FALSE;
			cs_default_utility_open = FALSE;
			create_server_tab = 3;
		}
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
		ypos += 18;

		menu_text_field("Port", "create_port", [xpos, ypos], property_width, 5, create_server_port_text, create_server_port_cursor);
		menu_sanitize_numeric_text(create_server_port_text, create_server_port_cursor, FALSE);
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
		ypos += 24;

		// --- Voice / VoIP server toggles ---
		// Master receive switch.  When 0, the server drops every voice
		// packet — no in-game voice chat for anyone connected.
		menu_toggle_button("create_voip", [xpos, ypos], [property_width, 20], "Voice Chat", create_server_voip);
		ypos += 24;

		// MVD voice recording — cycler since the engine accepts 0/1/2.
		// 0 = off, 1 = record everyone, 2 = record spectators only.
		{
			string voip_rec_label;
			if      (create_server_voip_record == 1) voip_rec_label = "Voice Record: All";
			else if (create_server_voip_record == 2) voip_rec_label = "Voice Record: Spec";
			else                                     voip_rec_label = "Voice Record: Off";
			if (my_button("create_voip_rec", [xpos, ypos], [property_width, 20], voip_rec_label))
			{
				create_server_voip_record += 1;
				if (create_server_voip_record > 2)
					create_server_voip_record = 0;
			}
		}
		ypos += 24;

		// Debug echo — server bounces voice packets back to the sender
		// for testing.  Off in production.
		menu_toggle_button("create_voip_echo", [xpos, ypos], [property_width, 20], "Voice Echo (debug)", create_server_voip_echo);
		ypos += 24;
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

		create_server_load_gamemode_options();
		{
			create_server_gamemode_pos  = [xpos, ypos];
			create_server_gamemode_size = [half_w, 108];
			if (menu_dropdown_button("create_gamemode", create_server_gamemode_pos, create_server_gamemode_size,
				create_server_gamemode_options, create_server_gamemode, create_server_gamemode_open, FALSE))
			{
				cs_default_primary_open = FALSE;
				cs_default_secondary_open = FALSE;
				cs_default_melee_open = FALSE;
				cs_default_utility_open = FALSE;
			}
			menu_toggle_button("create_nomapweapons", [xpos + half_w + 4, ypos], [half_w, 20], "No Map Weapons", create_server_nomapweapons);
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
				create_server_gamemode_open = FALSE;
				cs_default_secondary_open = FALSE;
				cs_default_melee_open = FALSE;
				cs_default_utility_open = FALSE;
			}
			if (menu_dropdown_button("create_def_sec", cs_default_secondary_pos, cs_default_secondary_size,
				cs_default_secondary_options, cs_default_secondary_idx, cs_default_secondary_open, FALSE))
			{
				create_server_gamemode_open = FALSE;
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
				create_server_gamemode_open = FALSE;
				cs_default_primary_open = FALSE;
				cs_default_secondary_open = FALSE;
				cs_default_utility_open = FALSE;
			}
			if (menu_multidropdown_button("create_def_util", cs_default_utility_pos, cs_default_utility_size,
				cs_default_utility_options, cs_default_utility_mask, cs_default_utility_open))
			{
				create_server_gamemode_open = FALSE;
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
		ypos += 22;

		// Trust client hits: ON → client predicts hitmarker locally,
		// server suppresses its own emit (so the marker doesn't fire
		// twice on high-ping connections).  OFF → server is authoritative
		// and the only source of hitmarker feedback.
		menu_toggle_button("create_trust_clienthits", [xpos, ypos], [half_w, 20], "Trust Client Hits", create_server_trust_clienthits);
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
		menu_text_field_tight("Use Force",   "create_ph_usef",  [xpos + half_w + 4, ypos], half_w, 6, create_server_useforce_text,   create_server_useforce_cursor);
		menu_sanitize_numeric_text(create_server_useforce_text, create_server_useforce_cursor, FALSE);
		ypos += 18;

		menu_text_field_tight("Use VelMult", "create_ph_uvm",   [xpos,              ypos], half_w, 5, create_server_usevelmult_text, create_server_usevelmult_cursor);
		menu_sanitize_numeric_text(create_server_usevelmult_text, create_server_usevelmult_cursor, FALSE);
		menu_text_field_tight("Mass",        "create_ph_mass",  [xpos + half_w + 4, ypos], half_w, 4, create_server_mass_text,       create_server_mass_cursor);
		menu_sanitize_numeric_text(create_server_mass_text, create_server_mass_cursor, FALSE);
		ypos += 18;

		// Decimal rows (half-width paired, tight labels)
		menu_text_field_tight("Friction",    "create_ph_frict", [xpos,              ypos], half_w, 5, create_server_phfriction_text, create_server_phfriction_cursor);
		menu_sanitize_numeric_text(create_server_phfriction_text, create_server_phfriction_cursor, TRUE);
		menu_text_field_tight("ERP",         "create_ph_erp",   [xpos + half_w + 4, ypos], half_w, 5, create_server_erp_text,        create_server_erp_cursor);
		menu_sanitize_numeric_text(create_server_erp_text, create_server_erp_cursor, TRUE);
		ypos += 18;

		menu_text_field_tight("Damp Lin",    "create_ph_dl",    [xpos,              ypos], half_w, 5, create_server_damplin_text,    create_server_damplin_cursor);
		menu_sanitize_numeric_text(create_server_damplin_text, create_server_damplin_cursor, TRUE);
		menu_text_field_tight("Damp Ang",    "create_ph_da",    [xpos + half_w + 4, ypos], half_w, 5, create_server_dampang_text,    create_server_dampang_cursor);
		menu_sanitize_numeric_text(create_server_dampang_text, create_server_dampang_cursor, TRUE);
		ypos += 18;

		menu_text_field_tight("ODE Iter",    "create_ph_oiter", [xpos,              ypos], half_w, 3, create_server_odeiter_text,    create_server_odeiter_cursor);
		menu_sanitize_numeric_text(create_server_odeiter_text, create_server_odeiter_cursor, FALSE);
		ypos += 20;

		// Toggles
		menu_toggle_button("create_ph_oq",  [xpos,              ypos], [half_w, 20], "ODE QuickStep",  create_server_odequick);
		menu_toggle_button("create_ph_oad", [xpos + half_w + 4, ypos], [half_w, 20], "ODE AutoDisable", create_server_odeautodisable);
	}

	// Bottom buttons — Back matches the width of the "Refresh Maps" button
	// above (left_width); Start Server spans the Physics tab width.
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_END]);
	if (my_button("create_back", [pad, -8], [left_width, 20], "Back"))
	{
		create_server_map_dropdown_open = FALSE;
		create_server_gamemode_open = FALSE;
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
	// Start Server button. The gamemode selector uses the same overlay path.
	// Only the Game tab draws the buttons, so these positions are zero on
	// other tabs and the `is_open` guards no-op.
	// Reset alignment — the footer buttons above left it at END/END, which
	// would reinterpret the stored positions relative to the bottom-right.
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
	if (create_server_tab == 1)
	{
		menu_dropdown_list("create_gamemode", create_server_gamemode_pos, create_server_gamemode_size,
			create_server_gamemode_options, create_server_gamemode, create_server_gamemode_open, create_server_gamemode_scroll);
		menu_dropdown_list("create_def_prim", cs_default_primary_pos, cs_default_primary_size,
			cs_default_primary_options, cs_default_primary_idx, cs_default_primary_open, cs_default_primary_scroll);
		menu_dropdown_list("create_def_sec", cs_default_secondary_pos, cs_default_secondary_size,
			cs_default_secondary_options, cs_default_secondary_idx, cs_default_secondary_open, cs_default_secondary_scroll);
		menu_dropdown_list("create_def_mel", cs_default_melee_pos, cs_default_melee_size,
			cs_default_melee_options, cs_default_melee_idx, cs_default_melee_open, cs_default_melee_scroll);
		menu_multidropdown_list("create_def_util", cs_default_utility_pos, cs_default_utility_size,
			cs_default_utility_options, cs_default_utility_mask, cs_default_utility_open, cs_default_utility_scroll);
	}

	sui_set_default_kb_focus("create_name");

	if (sui_listen_back())
	{
		create_server_map_dropdown_open = FALSE;
		create_server_gamemode_open = FALSE;
		current_menu = MENU_MAIN;
	}

	sui_pop_frame();
};
