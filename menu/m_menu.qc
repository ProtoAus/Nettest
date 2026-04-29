float menu_font;

// serverkey() isn't declared in the engine-generated menu defs. Pull it in
// here (top of the first menu file in compile order — see m_progs.src) so
// every later menu file can read serverinfo.  #354 = pr_menu.c PF_cl_serverkey.
// m_loading.qc previously had a local copy; removed to avoid double-declare.
string(string key) serverkey = #354;

vector MENU_BG = '0.08 0.09 0.11';
vector MENU_BG_DARK = '0.04 0.05 0.07';
vector MENU_BORDER = '0.35 0.37 0.4';
vector MENU_BUTTON = '0.16 0.18 0.22';
vector MENU_BUTTON_BORDER = '0.4 0.42 0.46';
vector MENU_BUTTON_RETURN = '0.18 0.32 0.18';
vector MENU_BUTTON_RETURN_BORDER = '0.4 0.6 0.4';
vector MENU_TEXT_1 = '1 1 1';
vector MENU_TEXT_2 = '0.7 0.75 0.75';
vector MENU_HIGHLIGHT = '1 1 1';
vector MENU_DARKEN = '1 1 1';

vector MENU_TEXT_SMALL = '8 8 0';
vector MENU_TEXT_MEDIUM = '16 16 0';
vector MENU_TEXT_LARGE = '24 24 0';

vector menu_root_size;

void() m_close;
void() settings_menu;
void() create_server_load_maps;
void() create_server_menu;
void() server_browser_menu;

float current_menu;
const float MENU_MAIN = 1;
const float MENU_SETTINGS = 2;
const float MENU_HELP = 3;
const float MENU_CREATE_SERVER = 4;
const float MENU_SERVER_BROWSER = 5;

vector(float max_width) menu_pick_main_title_font =
{
    return '60 60 0';
};

vector(float title_size) menu_pick_subtitle_font =
{
    return '16 16 0';
};

// =============================================
//  UI Controls
// =============================================

// Drop shadow + panel body + solid border, in local (post-push_frame) coords.
// elev = shadow offset in px; pass 0 for nested panels inside an already-
// shadowed parent so they don't double-shadow.
void(vector size, float elev) menu_panel_bg =
{
	if (elev > 0)
		sui_fill([elev, elev], size, '0 0 0', 0.35, 0);
	sui_fill([0, 0], size, MENU_BG, 0.96, 0);
	sui_border_box([0, 0], size, 2, MENU_BORDER, 1.0, 0);
};

void(string id, vector pos, vector size, float maxlen, __inout string text, __inout float cursor) text_input_control =
{
	vector textsize = MENU_TEXT_SMALL;
	float text_y = floor(((size_y - 4) - textsize_y) * 0.5);
	sui_push_frame(pos, size);
	vector basecolor = sui_is_hovered(id) ? MENU_BG_DARK + MENU_HIGHLIGHT * 0.08 : MENU_BG_DARK;
	sui_fill([0, 0], size, basecolor, 0.9, 0);

	sui_text_input(id, [0, 0], size, text, cursor);
	sui_cap_input_length(maxlen, text, cursor);

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	float focused = sui_is_last_clicked(id);
	focused ? sui_border_box([0, 0], size, 2, MENU_BORDER, 1.0, 0) : 0;

	sui_push_frame([2, 0], [size_x - 4, size_y - 4]);

	float cursorx;
	if (stringwidth(text, 1, textsize) > size_x - 4)
	{
		sui_clip_to_frame();
		cursorx = 0;
		sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
		sui_text([0, text_y], textsize, text, MENU_TEXT_1, 1, 0);
	}
	else
	{
		sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
		cursorx = stringwidth(substring(text, 0, cursor), 1, textsize);
		sui_text([0, text_y], textsize, text, MENU_TEXT_1, 1, 0);
	}
	if (focused)
	{
		sui_fill([cursorx, text_y], [2, textsize_y], MENU_TEXT_1, fabs(sin(time * 4)), 0);
	}
	sui_reset_clip();
	sui_pop_frame();

	sui_pop_frame();
};

// Defined in m_main.qc (compiles after this file). Set TRUE when we
// kick off the disconnect→backdrop map-load so m_draw's transition
// handlers know to leave the menu open instead of force-closing it.
float mm_returning_to_backdrop;

// Full disconnect flow used by both the main-menu Disconnect button and
// the loading-panel Disconnect button.  When `cl_menumap` is set, kicks
// off the backdrop server so the user lands back on the menumap instead
// of a black screen.  When unset, falls through to a plain `disconnect`
// console command.
//
// We KEEP the menu open through the entire transition. Previously this
// did m_close → ... → togglemenu, but the gap between disconnect and
// map-finished left the engine in a "no menu, no connection" state
// where it would briefly auto-show the console (con_stayhidden's
// menu-fallback only fires under specific keydest+loading conditions
// that don't hold during a `map` command). Setting
// mm_returning_to_backdrop tells m_draw's transition handlers to skip
// their default close-menu + toggleconsole behavior — they assume the
// "menu was open during constate=connecting" pattern means console is
// stacked over a menu opened from the console, which is wrong here.
void() Menu_DisconnectAndReturnToMenuMap =
{
	string menumap = cvar_string("cl_menumap");
	if (menumap != "" && menumap != "none")
	{
		mm_returning_to_backdrop = TRUE;
		localcmd("set cl_menu_backdrop_active 1\n");
		localcmd("set sv_backdrop 1\n");
		// See m_main.qc backdrop launcher — keep the backdrop off
		// the default 27500 port so other local servers can use it.
		localcmd(sprintf("sv_port %g\n", 27501 + floor(random() * 100)));
		localcmd("deathmatch 1\n");
		localcmd("maxclients 2\n");
		localcmd(sprintf("map %s\n", menumap));
	}
	else
	{
		localcmd("disconnect\n");
	}
};

float(string id, vector pos, vector size, string text, vector button_color, vector border_color) my_button_colored =
{
	sui_push_frame(pos, size);
	vector basecolor = sui_is_hovered(id) ? button_color + MENU_HIGHLIGHT * 0.25 : button_color;
	basecolor = sui_is_held(id) ? button_color - MENU_DARKEN * 0.1 : basecolor;
	sui_fill([0, 0], size, basecolor, 0.92, 0);
	sui_border_box([0, 0], size, 2, border_color, 1.0, 0);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	sui_text([0, 1], MENU_TEXT_SMALL, text, MENU_TEXT_1, 1, 0);
	sui_action_element([0, 0], size, id, sui_noop);
	sui_pop_frame();

	return sui_is_clicked(id);
};

float(string id, vector pos, vector size, string text) my_button =
{
	return my_button_colored(id, pos, size, text, MENU_BUTTON, MENU_BUTTON_BORDER);
};

void(string id, vector pos, vector size, vector minmaxsteps, __inout float value) my_slider =
{
	sui_push_frame(pos, size);

	value = sui_slidercontrol(id, [0, 0], size, minmaxsteps, value, sui_slider_noop);
	float minval = minmaxsteps[0];
	float maxval = minmaxsteps[1];
	float range = max(0.0001, maxval - minval);
	float sliderx = ((value - minval) / range) * size_x;
	sui_fill([0, size_y * 0.25], [size_x, size_y * 0.5], MENU_BG_DARK, 1.0, 0);

	float is_active = sui_is_held(id) || (sui_is_hovered(id) && !sui_click_held());
	vector slider_ctrl_color = is_active ? MENU_BUTTON + MENU_HIGHLIGHT * 0.2 : MENU_BUTTON;
	sui_fill([sliderx - 2, 0], [4, size_y], slider_ctrl_color, 1.0, 0);

	sui_pop_frame();
};

void(vector pos, vector size, vector minmaxsteps, string cvar_s, string name, string format) cvar_slider =
{
	float current = cvar(cvar_s);
	float old = current;
	sui_push_frame(pos, [size_x, size_y * 0.5 - 4]);
	sui_text([0, 0], MENU_TEXT_SMALL, name, MENU_TEXT_1, 1, 0);
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
	sui_text([0, 0], MENU_TEXT_SMALL, sprintf(format, current), MENU_TEXT_1, 1, 0);
	sui_pop_frame();
	my_slider(strcat(cvar_s, "sldr"), [pos_x, pos_y + size_y * 0.5], [size_x, size_y * 0.5], minmaxsteps, current);
	// Write via sprintf(format, ...) not ftos() — slider step math gives
	// values like 0.90000004 due to float rounding; ftos would preserve
	// every bit and config.cfg ends up with `set volume "0.090000004"`.
	// Formatting with the display format quantizes storage to the same
	// precision the user sees.
	if (current != old) cvar_set(cvar_s, sprintf(format, current));
};

// =============================================
//  Numeric Input Helpers
// =============================================

float(float value) menu_is_digit =
{
	return value >= 48 && value <= 57;
};

void(__inout string text, __inout float cursor, float allow_decimal) menu_sanitize_numeric_text =
{
	string filtered = "";
	float next_cursor = 0;
	float saw_decimal = FALSE;
	float saw_minus = FALSE;
	float length = strlen(text);

	for (float index = 0; index < length; index += 1)
	{
		float chr = str2chr(text, index);
		float keep = FALSE;

		if (menu_is_digit(chr))
			keep = TRUE;
		else if (allow_decimal && chr == 46 && !saw_decimal)
		{
			keep = TRUE;
			saw_decimal = TRUE;
		}
		else if (chr == 45 && !saw_minus && strlen(filtered) == 0)
		{
			keep = TRUE;
			saw_minus = TRUE;
		}

		if (!keep)
			continue;

		filtered = strcat(filtered, chr2str(chr));
		if (index < cursor)
			next_cursor += 1;
	}

	text = filtered;
	cursor = min(next_cursor, strlen(text));
};

float(string text) menu_numeric_text_has_value =
{
	return text != "" && text != ".";
};

void(string cvar_s, string format, __inout string text, __inout float cursor) menu_seed_numeric_text =
{
	if (text != "")
		return;

	text = sprintf(format, cvar(cvar_s));
	cursor = strlen(text);
};

void(string cvar_s, vector clamp_range, string format, __inout string text, __inout float cursor) menu_apply_numeric_text =
{
	if (!menu_numeric_text_has_value(text))
		return;

	float value = bound(clamp_range_x, stof(text), clamp_range_y);
	text = sprintf(format, value);
	cursor = strlen(text);
	cvar_set(cvar_s, text);
};

void(string label, string field_id, string button_id, vector pos, float width, float maxlen, string cvar_s, vector clamp_range, string format, __inout string text, __inout float cursor) menu_numeric_cvar_field =
{
	float label_width = 70;
	float button_width = 36;
	float gap = 4;
	float field_width = width - label_width - button_width - gap;

	sui_push_frame(pos, [width, 20]);
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	sui_text([0, 0], MENU_TEXT_SMALL, label, MENU_TEXT_1, 1, 0);
	text_input_control(field_id, [label_width, 0], [field_width, 20], maxlen, text, cursor);
	menu_sanitize_numeric_text(text, cursor, TRUE);

	if (my_button(button_id, [label_width + field_width + gap, 0], [button_width, 20], "Set"))
		menu_apply_numeric_text(cvar_s, clamp_range, format, text, cursor);

	sui_pop_frame();
};

void(vector pos, vector size, string text) menu_disabled_button =
{
	sui_push_frame(pos, size);
	sui_fill([0, 0], size, MENU_BG_DARK, 0.8, 0);
	sui_border_box([0, 0], size, 2, MENU_BORDER, 0.6, 0);
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	sui_text([0, 0], MENU_TEXT_SMALL, text, MENU_TEXT_2, 0.85, 0);
	sui_pop_frame();
};

void(string label, string field_id, vector pos, float width, float maxlen, __inout string text, __inout float cursor) menu_text_field =
{
	float label_width = 100;
	float gap = 8;
	float field_width = max(32, width - label_width - gap);

	sui_push_frame(pos, [width, 16]);
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	sui_text([0, 0], MENU_TEXT_SMALL, label, MENU_TEXT_1, 1, 0);
	text_input_control(field_id, [label_width + gap, 0], [field_width, 16], maxlen, text, cursor);
	sui_pop_frame();
};

// Same as menu_text_field but with a shorter label column — used for the
// Physics tab's half-width paired rows so the input box gets more space.
void(string label, string field_id, vector pos, float width, float maxlen, __inout string text, __inout float cursor) menu_text_field_tight =
{
	float label_width = 60;
	float gap = 4;
	float field_width = max(32, width - label_width - gap);

	sui_push_frame(pos, [width, 16]);
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	sui_text([0, 0], MENU_TEXT_SMALL, label, MENU_TEXT_1, 1, 0);
	text_input_control(field_id, [label_width + gap, 0], [field_width, 16], maxlen, text, cursor);
	sui_pop_frame();
};

float(string id, vector pos, vector size, string label, __inout float value) menu_toggle_button =
{
	string state = value ? "On" : "Off";
	vector button_color = value ? MENU_BUTTON_RETURN : MENU_BUTTON;
	vector border_color = value ? MENU_BUTTON_RETURN_BORDER : MENU_BUTTON_BORDER;

	if (!my_button_colored(id, pos, size, strcat(label, ": ", state), button_color, border_color))
		return FALSE;

	value = !value;
	return TRUE;
};

void(float default_value, float min_value, float max_value, __inout string text, __inout float cursor) menu_normalize_integer_text =
{
	float value = default_value;

	menu_sanitize_numeric_text(text, cursor, FALSE);
	if (menu_numeric_text_has_value(text))
		value = stof(text);

	value = floor(bound(min_value, value, max_value));
	text = sprintf("%.0f", value);
	cursor = strlen(text);
};

void(string cvar_s, string fallback, __inout string text, __inout float cursor) menu_seed_text_from_cvar =
{
	if (text != "")
		return;

	text = cvar_string(cvar_s);
	if (text == "")
		text = fallback;
	cursor = strlen(text);
};

float(strbuf buf, string item) menu_buf_contains =
{
	float count = buf_getsize(buf);

	for (float index = 0; index < count; index += 1)
	{
		if (bufstr_get(buf, index) == item)
			return TRUE;
	}

	return FALSE;
};

string(string filename) menu_map_name_from_filename =
{
	string lower = strtolower(filename);
	float length = strlen(filename);

	if (length <= 9)
		return "";
	if (strncmp(lower, "maps/", 5) != 0)
		return "";
	if (strncmp(lower, ".bsp", 4, length - 4, 0) != 0)
		return "";

	return substring(filename, 5, length - 9);
};

// =============================================
//  Key Bindings
// =============================================

struct name_command {
	string name;
	string command;
};

name_command bindlist[] =
{
	{ "Primary Fire", "+attack" },
	{ "Secondary Fire", "+attack2" },
	{ "Move Forward", "+forward" },
	{ "Move Back", "+back" },
	{ "Move Left", "+moveleft" },
	{ "Move Right", "+moveright" },
	{ "Jump", "+jump" },
	{ "Sprint", "+button4" },
	{ "Duck", "+button6" },
	{ "Use", "+use" },
	{ "Reload", "impulse 6" },
	{ "Drop Weapon", "impulse 5" },
	{ "Last Weapon", "impulse 14" },
	{ "Weapon Special", "impulse 7" },
	{ "Cycle Next", "impulse 12" },
	{ "Cycle Prev", "impulse 13" },
	{ "Weapon Slot 1", "impulse 1" },
	{ "Weapon Slot 2", "impulse 2" },
	{ "Weapon Slot 3", "impulse 3" },
	{ "Weapon Slot 4", "impulse 4" },
	{ "Team Menu", "impulse 28" },
	{ "Show Scores", "+showscores" },
	{ "Chat", "messagemode" },
};

void(string id, vector pos, vector size, string name, string command) bind_button =
{
	sui_push_frame(pos, size);
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	string key = sui_binder(id, [0, 0], size, name, command);
	if (sui_is_hovered(id)) sui_fill([0, 0], size, MENU_HIGHLIGHT, 0.1, 0);
	sui_text([4, 1], MENU_TEXT_SMALL, name, MENU_TEXT_1, 1, 0);
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_CENTER]);
	sui_text([-4, 1], MENU_TEXT_SMALL, key, MENU_TEXT_1, 1, 0);

	sui_pop_frame();
};

void(string id, vector pos, vector size, __inout vector scrollofs) bind_list =
{
	sui_fill(pos, size, MENU_BG_DARK, 0.75, 0);
	sui_list_view_begin(strcat(id, "scrl"), pos, size, [size_x - 6, 24], bindlist.length, scrollofs, [0, 6]);
	vector listitem_pos = '0 0 0';
	for (float index = sui_list_item(listitem_pos); index > -1; index = sui_list_item(listitem_pos))
	{
		sui_push_frame(listitem_pos, [size_x - 6, 24]);
		bind_button(strcat(id, ftos(index)), [0, 0], [size_x - 6, 24], bindlist[index].name, bindlist[index].command);
		sui_pop_frame();
	}
	sui_list_view_end();
};

// =============================================
//  Config Save/Load
// =============================================

// Client-only cvars — persisted to data/settings.cfg, loaded on menu init.
string client_config_cvars[] =
{
    "name",
    "volume",
    "sensitivity",
    "fov",
    "cl_crosshairlength",
    "cl_crosshairthickness",
    "cl_crosshairgap",
    "cl_crosshaircolour",
    "cl_crosshairdynamic",
    "cl_crosshairweapongap",
    "cl_teamcolours",
};

// Server-only cvars — persisted to data/server.cfg, applied by sv_main worldspawn.
string server_config_cvars[] =
{
    "hostname",
    "maxclients",
    "password",
    "rcon_password",
    "sv_pure",
    "fraglimit",
    "mp_roundtime",
    "mp_timelimit",
    "mp_maxrounds",
    "mp_friendlyfire",
    "mp_falldamage",
    "mp_nomapweapons",
    "mp_freezetime",
    "mp_roundrestartdelay",
    "mp_respawndelay",
    "sv_autohop",
    "sv_stamina",
    "sv_gamemode",
    "sv_maxvelocity",
    "sv_hull_height",
    "sv_eye_height",
    "sv_maxspeed",
    "sv_accelerate",
    "sv_airaccelerate",
    "sv_friction",
    "sv_shiftspeed",
    "sv_mintic",
    "sv_maxtic",
    "sv_minpitch",
    "sv_maxpitch",
    "mp_cheats",
    "sv_cheats",
    "mp_noblock",
    "sv_trust_clienthits",

    // Non-UI advanced server cvars (no menu control — edit data/server.cfg to change)
    "sv_lagcomp",
    "sv_lagcomp_maxrewind",
    "sv_hitbox_expand",
    "sv_anim_qu_per_sec",
    "sv_anim_qu_per_sec_crouch",
    "sv_player_basebone",
    "sv_antilag",
    "sv_bigcoords",
    "sv_nqplayerphysics",
    "sv_wateraccelerate",
    "sv_waterfriction",
    "sv_toss_tickrate",
    "pm_ramp_bumpcount",

    // Physics props
    "sv_physprop_hit_force",
    "sv_physprop_mass",
    "sv_physprop_erp",
    "sv_physprop_damp_lin",
    "sv_physprop_damp_ang",
    "sv_physprop_friction",
    "sv_physprop_use_force",
    "sv_physprop_use_velmult",

    // ODE engine cvars
    "physics_ode_iterationsperframe",
    "physics_ode_worldquickstep",
    "physics_ode_autodisable",

    // Default starting loadout (Create Server → Game tab)
    "sv_default_primary",
    "sv_default_secondary",
    "sv_default_melee",
    "sv_default_utility",
};

void() Menu_SaveClientConfig =
{
    float f = fopen("data/settings.cfg", FILE_WRITE);
    if (f < 0)
    {
        print("Menu_SaveClientConfig: failed to open data/settings.cfg\n");
        return;
    }

    fputs(f, "// data/settings.cfg — client settings (auto-generated)\n\n");

    // Cvars
    float i;
    for (i = 0; i < client_config_cvars.length; i++)
    {
        string name = client_config_cvars[i];
        string val  = cvar_string(name);
        fputs(f, sprintf("set %s \"%s\"\n", name, val));
    }

    // Keybinds
    fputs(f, "\n// Binds\n");
    for (i = 0; i < bindlist.length; i++)
    {
        string keys_str = findkeysforcommand(bindlist[i].command);
        float num_keys = tokenize(keys_str);
        float j;
        for (j = 0; j < num_keys; j++)
        {
            float keynum = stof(argv(j));
            if (keynum > 0)
            {
                string key = keynumtostring(keynum);
                if (key != "")
                    fputs(f, sprintf("bind %s \"%s\"\n", key, bindlist[i].command));
            }
        }
    }

    fclose(f);
};

void() Menu_FixupEmptyDefaults;  // forward

string(string cfgpath, string target_name) Menu_ReadConfigValue =
{
    float f = fopen(cfgpath, FILE_READ);
    if (f < 0)
        return "";

    string found = "";
    string line = fgets(f);
    while (line)
    {
        float n = strlen(line);
        if (n > 0 && substring(line, n - 1, 1) == "\r")
            line = substring(line, 0, n - 1);

        float argc = tokenize(line);
        if (argc <= 0)
        {
            line = fgets(f);
            continue;
        }

        string cmd = argv(0);
        if (cmd == "//" || substring(cmd, 0, 1) == "#")
        {
            line = fgets(f);
            continue;
        }

        if ((cmd == "set" || cmd == "seta" || cmd == "setfl") && argc >= 3)
        {
            if (argv(1) == target_name)
                found = argv(2);
        }
        else if (argc >= 2)
        {
            if (argv(0) == target_name)
                found = argv(1);
        }

        line = fgets(f);
    }

    fclose(f);
    return found;
};

void() Menu_SaveServerConfig =
{
    // Restore intended defaults for any non-UI cvar that came back empty
    // from a previous save, so we never persist "" again.
    Menu_FixupEmptyDefaults();

    float f = fopen("data/server.cfg", FILE_WRITE);
    if (f < 0)
    {
        print("Menu_SaveServerConfig: failed to open data/server.cfg\n");
        return;
    }

    fputs(f, "// data/server.cfg — server settings (auto-generated)\n\n");

    float i;
    for (i = 0; i < server_config_cvars.length; i++)
    {
        string name = server_config_cvars[i];
        string val  = cvar_string(name);
        // If the live value is empty (e.g. a previous save wrote ""
        // before the cvar had a registered default), ensure the menu VM
        // force-set the default via menu_register_default on init — so
        // if we see empty here, it's because the cfg exec overrode to "".
        // Re-apply by reading the registered default and setting it live.
        if (val == "")
        {
            if (name == "rcon_password")
                val = cvar_string("sv_rcon_password_shadow");

            if (name == "rcon_password" && val == "")
                val = Menu_ReadConfigValue("data/server.cfg", name);

            if (val == "")
                val = cvar_defstring(name);

            if (val != "")
            {
                cvar_set(name, val);   // apply live so the next read works
            }
        }
        fputs(f, sprintf("set %s \"%s\"\n", name, val));
    }

    fclose(f);
};

// Called from the Settings menu "Back" / apply path — saves both client and binds.
void() Menu_SaveConfig =
{
    Menu_SaveClientConfig();
};

// Register every cvar the menu reads so the menu VM doesn't auto-create
// them when the Create Server / Settings pages seed their UI values.
// Idempotent — registercvar is a no-op if the cvar already exists.
// Register a cvar with a default value.  If the cvar already exists (engine
// builtin, or earlier register call), force its VALUE to default when empty
// so cvar_string reads the intended value even though registercvar can't
// overwrite an existing default.
void(string name, string def) menu_register_default =
{
    registercvar(name, def, 0);
    if (cvar_string(name) == "")
        cvar_set(name, def);
};

// Called AFTER data/server.cfg is exec'd.  Any cvar we care about that came
// back empty from the cfg gets restored to its hardcoded default.  Call
// again at save time so the file never writes "" for these.
void() Menu_FixupEmptyDefaults =
{
    if (cvar_string("sv_lagcomp")           == "") cvar_set("sv_lagcomp",           "1");
    if (cvar_string("sv_lagcomp_maxrewind") == "") cvar_set("sv_lagcomp_maxrewind", "0.5");
    if (cvar_string("sv_debug_lagcomp")     == "") cvar_set("sv_debug_lagcomp",     "0");
    if (cvar_string("sv_hitbox_expand")     == "") cvar_set("sv_hitbox_expand",     "32");
    if (cvar_string("sv_anim_qu_per_sec")        == "") cvar_set("sv_anim_qu_per_sec",        "240");
    if (cvar_string("sv_anim_qu_per_sec_crouch") == "") cvar_set("sv_anim_qu_per_sec_crouch", "100");
    if (cvar_string("sv_player_basebone")   == "") cvar_set("sv_player_basebone",   "0");
    if (cvar_string("sv_antilag")           == "") cvar_set("sv_antilag",           "3");
    if (cvar_string("sv_bigcoords")         == "") cvar_set("sv_bigcoords",         "1");
    if (cvar_string("sv_nqplayerphysics")   == "") cvar_set("sv_nqplayerphysics",   "0");
    if (cvar_string("sv_wateraccelerate")   == "") cvar_set("sv_wateraccelerate",   "10");
    if (cvar_string("sv_waterfriction")     == "") cvar_set("sv_waterfriction",     "1");
    if (cvar_string("sv_toss_tickrate")     == "") cvar_set("sv_toss_tickrate",     "20");
    if (cvar_string("pm_ramp_bumpcount")    == "") cvar_set("pm_ramp_bumpcount",    "8");
    if (cvar_string("sv_trust_clienthits")  == "") cvar_set("sv_trust_clienthits",  "1");

    // Default starting loadout — match sv_main.qc's SV_FixupEmptyDefaults so
    // the menu VM sees the same values before a server is ever started.
    if (cvar_string("sv_default_primary")   == "") cvar_set("sv_default_primary",   "0");   // WEP_NONE
    if (cvar_string("sv_default_secondary") == "") cvar_set("sv_default_secondary", "28");  // WEP_CSUSP
    if (cvar_string("sv_default_melee")     == "") cvar_set("sv_default_melee",     "20");  // WEP_WRENCH
    if (cvar_string("sv_default_utility")   == "") cvar_set("sv_default_utility",   "25");  // WEP_HLGRENADE
};

void() Menu_RegisterCvars =
{
    // Register cvars that have real defaults BEFORE the generic loop.
    // registercvar is a no-op if the cvar already exists, so the generic
    // loop (which uses "" as default) would otherwise clobber these.
    registercvar("_nettest_menu_active", "0", 0);
    // Ephemeral admin trigger — pre-register so `cvar("sv_roundrestart")`
    // in QC doesn't auto-create it.  Not persisted (not in save list).
    menu_register_default("sv_roundrestart", "0");
    menu_register_default("sv_rcon_password_shadow", "");
    // Same story — these get registered by worldspawn (sv_main.qc) but
    // the menu VM reads them earlier (sv_info_push, SV_FixupEmptyDefaults
    // queued from data/server.cfg exec) and the auto-create path prints
    // "Created QC Cvar" to console.  Pre-registering here shuts that up.
    menu_register_default("sv_snipersway",           "0");
    menu_register_default("sv_command_continuation", "1");
    menu_register_default("sv_debug_continuation",   "0");
    // Gameplay toggles / settings that live in the save list.  Defaults
    // must be registered here so cvar_string doesn't return "".
    menu_register_default("mp_noblock",      "0");
    menu_register_default("mp_nomapweapons", "0");
    menu_register_default("sv_shiftspeed",   "135");
    // Crosshair behaviour toggles — defaults match the CSQC registration
    // in HUD_EnsureCrosshairCVars so the menu doesn't spawn "Created QC
    // Cvar" warnings on first open.
    menu_register_default("cl_crosshairdynamic",    "1");
    menu_register_default("cl_crosshairweapongap", "1");

    // Non-UI server cvars (saved to data/server.cfg, no menu control).
    menu_register_default("sv_lagcomp",           "1");
    menu_register_default("sv_lagcomp_maxrewind", "0.5");
    menu_register_default("sv_debug_lagcomp",     "0");
    menu_register_default("sv_hitbox_expand",     "32");
    menu_register_default("sv_anim_qu_per_sec",         "240");
    menu_register_default("sv_anim_qu_per_sec_crouch",  "100");
    menu_register_default("sv_player_basebone",   "0");
    menu_register_default("sv_antilag",           "3");
    menu_register_default("sv_bigcoords",         "1");
    menu_register_default("sv_nqplayerphysics",   "0");
    menu_register_default("sv_wateraccelerate",   "10");
    menu_register_default("sv_waterfriction",     "1");
    menu_register_default("sv_toss_tickrate",     "20");
    menu_register_default("sv_ode_loaded",        "0");
    menu_register_default("pm_ramp_bumpcount",    "8");
    menu_register_default("sv_trust_clienthits",  "1");

    // Default starting loadout cvars — stored as WEP_* integers.
    menu_register_default("sv_default_primary",   "0");
    menu_register_default("sv_default_secondary", "28");
    menu_register_default("sv_default_melee",     "20");
    menu_register_default("sv_default_utility",   "25");

    // Re-register physics cvars with proper defaults (the loop above registered
    // them with "" which would make first-open seed to fallback).
    registercvar("sv_physprop_hit_force",         "8000", 0);
    registercvar("sv_physprop_mass",              "20",   0);
    registercvar("sv_physprop_erp",               "0",    0);
    registercvar("sv_physprop_damp_lin",          "0.01", 0);
    registercvar("sv_physprop_damp_ang",          "0.01", 0);
    registercvar("sv_physprop_friction",          "1.0",  0);
    registercvar("sv_physprop_use_force",         "800",  0);
    registercvar("sv_physprop_use_velmult",       "800",  0);
    registercvar("physics_ode_iterationsperframe","10",   0);
    registercvar("physics_ode_worldquickstep",    "0",    0);
    registercvar("physics_ode_autodisable",       "0",    0);

    // Fallback: register anything in the save lists that wasn't given a
    // specific default above (hostname, passwords, mp_* etc).  This is
    // idempotent — registercvar is a no-op for cvars that already exist.
    float i;
    for (i = 0; i < client_config_cvars.length; i++)
        registercvar(client_config_cvars[i], "", 0);
    for (i = 0; i < server_config_cvars.length; i++)
        registercvar(server_config_cvars[i], "", 0);
};

void() Menu_LoadConfig =
{
    // Register defaults first so cvar reads don't spawn "Created QC Cvar"
    // warnings, then apply persisted client + server settings.
    Menu_RegisterCvars();

    // Mod-author client defaults (binds, graphics, audio).  Only execs on
    // game instances with a menu VM — i.e. clients and listen servers.
    // Dedicated servers don't run the menu so they skip this entirely.
    // Loaded FIRST so user-saved data/settings.cfg can override it.
    localcmd("exec data/default.cfg\n");

    localcmd("exec data/settings.cfg\n");

    // Also load data/server.cfg at menu init so the Create Server menu
    // populates its text fields with persisted server settings instead of
    // hard-coded defaults.  Cvars are engine-global, so setting them here
    // (menu VM) means the server VM sees the same values when it later
    // exec's the same file in worldspawn — harmless re-apply.
    localcmd("exec data/server.cfg\n");
    // localcmd is queued — Menu_FixupEmptyDefaults is invoked at save time
    // (see Menu_SaveServerConfig) and first-open of the Create Server menu
    // instead, when we can be sure the exec has already run.
};

// =============================================
//  Menus
// =============================================

// Player name — persists across all menu pages. Committed to the `name`
// cvar (and thus broadcast to the server) only on Enter or menu-close,
// NOT on every keystroke — otherwise the server sees every character of
// a rename as a separate `<user> changed name to "Pro"`, `"Prot"`,
// `"Proto"`… spam.
string mm_name_text;
float mm_name_cursor;
float mm_name_seeded;

void() mm_flush_name =
{
	if (!mm_name_seeded) return;          // field never opened this session
	if (mm_name_text == "") return;       // empty → ignore, keep current
	if (mm_name_text == cvar_string("name")) return;   // unchanged, skip
	cvar_set("name", mm_name_text);
};

void() main_menu =
{
	vector menu_box_size;
	vector title_font;
	vector subtitle_font;
	float  title_block_y;
	float  title_mid_y;
	float  menu_stack_h;
	float  menu_stack_bottom_y;
	float  menu_stack_top_y;
	float  subtitle_x;
	float  subtitle_y;

	// Floating player name island above the title
	if (!mm_name_seeded)
	{
		mm_name_text = cvar_string("name");
		if (mm_name_text == "")
			mm_name_text = "Player";
		mm_name_cursor = strlen(mm_name_text);
		mm_name_seeded = TRUE;
	}

	// Main menu box size depends on whether the backdrop-only localhost
	// connect row is present. The full menu stack sits a little above
	// the bottom of the screen, and the title centers in the space
	// between the top of the screen and that stack.
	menu_box_size = [148, (serverkey("sv_backdrop") == "1") ? 168 : 144];
	menu_stack_h = menu_box_size_y + 26;  // 20 px name field + 6 px gap
	menu_stack_bottom_y = max(menu_stack_h + 16, floor(menu_root_size_y * 0.85));
	menu_stack_top_y = menu_stack_bottom_y - menu_stack_h;

	title_font = menu_pick_main_title_font(menu_root_size_x - 48);
	subtitle_font = menu_pick_subtitle_font(title_font_y);
	title_mid_y = floor(menu_stack_top_y * 0.5);
	title_block_y = max(12, title_mid_y - floor(title_font_y * 0.5));
	subtitle_x = max(8, floor(title_font_y * 0.80));
	subtitle_y = title_block_y + floor(title_font_y * 0.85) - 3;

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([2, title_block_y + 1], title_font, "Quakers", '0 0 0', 0.5, 0);
	sui_text([0, title_block_y], title_font, "Quakers", [1, 1, 1], 1, 0);
	sui_text([subtitle_x, subtitle_y], subtitle_font,
	         "The Religious Society of Friends",
	         '0.80 0.80 0.80', 1, 0);

	// Build tag — bottom-right corner of the screen, dimmed.  Uses
	// END align so the offset is from the right/bottom edge.
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_END]);
	sui_text([-6, -6], MENU_TEXT_SMALL,
	         "Build: pre-nettest13",
	         '0.80 0.80 0.80', 1, 0);

	vector pos = [0, menu_stack_top_y + 26];
	// Backdrop mode adds a Localhost button under Connect-to-Proto.bar, so
	// the panel needs an extra row of height. Real-game mode (Disconnect)
	// has no localhost row and is shorter.  Both heights bumped by 24 px
	// over the original to fit the new Server Browser row between Create
	// Server and Settings without clipping into the bottom-aligned Quit.
	vector size = menu_box_size;
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);

	sui_push_frame(pos, size);

	menu_panel_bg(size, 4);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);

	// Floating name island — 6px above the main menu box
	{
		float nw = size_x - 16;
		float nh = 20;
		sui_push_frame([0, -(nh + 6)], [nw, nh]);
		menu_panel_bg([nw, nh], 0);
		sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
		sui_text([4, 1], MENU_TEXT_SMALL, "Name:", MENU_TEXT_2, 0.85, 0);
		float input_x = 42;
		text_input_control("mm_name", [input_x, 0], [nw - input_x - 4, 14], 32, mm_name_text, mm_name_cursor);
		sui_pop_frame();

		// Do NOT cvar_set here — that would spam the server with a
		// rename event per keystroke. mm_flush_name() commits on
		// menu-close (m_close) and on Enter (Menu_InputEvent).
	}

	// Connect button is swapped for a Disconnect button once we've left the
	// backdrop map (i.e. the user is in a real game / on a real server).
	// Clicking Disconnect re-launches the backdrop map and re-arms the
	// suppress-HUD flag, exactly like the engine-startup path in m_init.
	//
	// Reads server-authoritative sv_backdrop instead of the local cvar so
	// console-driven connects (e.g. `connect localhost`) flip the button
	// correctly — the local cvar wouldn't update on those code paths.
	if (serverkey("sv_backdrop") == "1")
	{
		if (my_button_colored("mm_connect", [0, 8], [size_x - 16, 20], "Connect to Proto.bar", '0.6 0.55 0.1', '0.75 0.7 0.2'))
		{
			// Close the menu immediately so m_drawloading takes over during
			// the network-connect phase (before the engine's auto-close on
			// map load would have fired).  Otherwise m_draw keeps running
			// and the main menu flashes with a stale Disconnect button.
			m_close();
			localcmd("set cl_menu_backdrop_active 0\n");
			// Clear the server-side flag too — the local listen server may
			// still be running, and `connect` will tear it down, but we set
			// it explicitly so any future listen-server launch defaults to
			// "real game" instead of inheriting the stale backdrop value.
			localcmd("set sv_backdrop 0\n");
			// Restore the default listen-server port (backdrop launchers
			// move it off 27500 to avoid colliding with other local servers).
			localcmd("sv_port 27500\n");
			localcmd("connect proto.bar\n");
		}

		// Localhost connect — same teardown as the Proto.bar Connect, but
		// connects to 127.0.0.1:27500 (a sibling nettest instance the user
		// is hosting locally). Stacked beneath Proto.bar at the standard
		// 24px row pitch.
		if (my_button_colored("mm_connect_local", [0, 8 + 24], [size_x - 16, 20], "Connect to Localhost", '0.18 0.45 0.18', '0.30 0.65 0.30'))
		{
			m_close();
			localcmd("set cl_menu_backdrop_active 0\n");
			localcmd("set sv_backdrop 0\n");
			localcmd("sv_port 27500\n");
			localcmd("connect localhost\n");
		}
	}
	else
	{
		if (my_button_colored("mm_disconnect", [0, 8], [size_x - 16, 20], "Disconnect", '0.55 0.2 0.2', '0.75 0.3 0.3'))
		{
			Menu_DisconnectAndReturnToMenuMap();
		}
	}
	// Backdrop mode shows two top buttons (Proto.bar + Localhost), real-game
	// mode shows one (Disconnect). Push Create Server / Settings down by an
	// extra row when the localhost row is visible so the layout doesn't
	// collide with it.
	float extra_row = (serverkey("sv_backdrop") == "1") ? 24 : 0;

	if (my_button("mm_create", [0, 8 + 24 + extra_row], [size_x - 16, 20], "Create Server"))
	{
		create_server_load_maps();
		current_menu = MENU_CREATE_SERVER;
	}
	my_button("mm_browser",  [0, 8 + 48 + extra_row], [size_x - 16, 20], "Server Browser") ? current_menu = MENU_SERVER_BROWSER : 0;
	my_button("mm_settings", [0, 8 + 72 + extra_row], [size_x - 16, 20], "Settings") ? current_menu = MENU_SETTINGS : 0;
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_END]);
	my_button_colored("mm_quit", [0, -8], [size_x - 16, 20], "Quit", '0.55 0.2 0.2', '0.75 0.3 0.3') ? localcmd("quit\n") : 0;
	sui_pop_frame();

	sui_set_default_kb_focus("mm_return");
};

void(vector size) root_menu =
{
	menu_root_size = size;
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	// Full-screen dim behind the main menu (gated on cl_menu_backdrop).
	if (cvar("cl_menu_backdrop"))
		sui_fill([0, 0], size, '0.01 0.01 0.02', 0.64, 0);
	switch (current_menu)
	{
		case MENU_MAIN:            main_menu();            break;
		case MENU_CREATE_SERVER:   create_server_menu();   break;
		case MENU_SERVER_BROWSER:  server_browser_menu();  break;
		case MENU_SETTINGS:        settings_menu();
		default: break;
	}
};
