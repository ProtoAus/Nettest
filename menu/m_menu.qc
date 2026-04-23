float menu_font;

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

void() m_close;
void() settings_menu;
void() create_server_load_maps;
void() create_server_menu;

float current_menu;
const float MENU_MAIN = 1;
const float MENU_SETTINGS = 2;
const float MENU_HELP = 3;
const float MENU_CREATE_SERVER = 4;

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
    "cl_teamcolours",
};

// Server-only cvars — persisted to data/server.cfg, exec'd by sv_main worldspawn.
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

    // Non-UI advanced server cvars (no menu control — edit data/server.cfg to change)
    "sv_lagcomp",
    "sv_lagcomp_maxrewind",
    "sv_hitbox_expand",
    "sv_anim_qu_per_sec",
    "sv_player_basebone",
    "sv_antilag",
    "sv_bigcoords",
    "sv_nqplayerphysics",
    "sv_wateraccelerate",
    "sv_waterfriction",
    "pm_ramp_bumpcount",

    // Physics props
    "sv_physprop_hit_force",
    "sv_physprop_push_force",
    "sv_physprop_push_height",
    "sv_physprop_passthrough",
    "sv_physprop_mass",
    "sv_physprop_erp",
    "sv_physprop_damp_lin",
    "sv_physprop_damp_ang",
    "sv_physprop_player_bounce",
    "sv_physprop_player_minkick",
    "sv_physprop_player_kickback",
    "sv_physprop_friction",
    "sv_physprop_shape",
    "sv_physprop_axis",
    "sv_physprop_push_radius",
    "sv_physprop_use_force",
    "sv_physprop_use_velmult",
    "sv_physprop_qc_collide",

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
    if (cvar_string("sv_anim_qu_per_sec")   == "") cvar_set("sv_anim_qu_per_sec",   "240");
    if (cvar_string("sv_player_basebone")   == "") cvar_set("sv_player_basebone",   "0");
    if (cvar_string("sv_antilag")           == "") cvar_set("sv_antilag",           "3");
    if (cvar_string("sv_bigcoords")         == "") cvar_set("sv_bigcoords",         "1");
    if (cvar_string("sv_nqplayerphysics")   == "") cvar_set("sv_nqplayerphysics",   "0");
    if (cvar_string("sv_wateraccelerate")   == "") cvar_set("sv_wateraccelerate",   "10");
    if (cvar_string("sv_waterfriction")     == "") cvar_set("sv_waterfriction",     "1");
    if (cvar_string("pm_ramp_bumpcount")    == "") cvar_set("pm_ramp_bumpcount",    "8");

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
    menu_register_default("sv_shiftspeed",   "135");

    // Non-UI server cvars (saved to data/server.cfg, no menu control).
    menu_register_default("sv_lagcomp",           "1");
    menu_register_default("sv_lagcomp_maxrewind", "0.5");
    menu_register_default("sv_debug_lagcomp",     "0");
    menu_register_default("sv_hitbox_expand",     "32");
    menu_register_default("sv_anim_qu_per_sec",   "240");
    menu_register_default("sv_player_basebone",   "0");
    menu_register_default("sv_antilag",           "3");
    menu_register_default("sv_bigcoords",         "1");
    menu_register_default("sv_nqplayerphysics",   "0");
    menu_register_default("sv_wateraccelerate",   "10");
    menu_register_default("sv_waterfriction",     "1");
    menu_register_default("sv_ode_loaded",        "0");
    menu_register_default("pm_ramp_bumpcount",    "8");

    // Default starting loadout cvars — stored as WEP_* integers.
    menu_register_default("sv_default_primary",   "0");
    menu_register_default("sv_default_secondary", "28");
    menu_register_default("sv_default_melee",     "20");
    menu_register_default("sv_default_utility",   "25");

    // Re-register physics cvars with proper defaults (the loop above registered
    // them with "" which would make first-open seed to fallback).
    registercvar("sv_physprop_hit_force",         "8000", 0);
    registercvar("sv_physprop_push_force",        "8000", 0);
    registercvar("sv_physprop_push_height",       "0.6",  0);
    registercvar("sv_physprop_passthrough",       "1",    0);
    registercvar("sv_physprop_mass",              "20",   0);
    registercvar("sv_physprop_erp",               "0",    0);
    registercvar("sv_physprop_damp_lin",          "0.2",  0);
    registercvar("sv_physprop_damp_ang",          "0.2",  0);
    registercvar("sv_physprop_player_bounce",     "0.4",  0);
    registercvar("sv_physprop_player_minkick",    "100",  0);
    registercvar("sv_physprop_player_kickback",   "0.005",0);
    registercvar("sv_physprop_friction",          "1.0",  0);
    registercvar("sv_physprop_shape",             "cylinder", 0);
    registercvar("sv_physprop_axis",              "y",    0);
    registercvar("sv_physprop_push_radius",       "40",   0);
    registercvar("sv_physprop_use_force",         "800",  0);
    registercvar("sv_physprop_use_velmult",       "800",  0);
    registercvar("sv_physprop_qc_collide",        "1",    0);
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

// Player name — persists across all menu pages
string mm_name_text;
float mm_name_cursor;
float mm_name_seeded;

void() main_menu =
{
	// Floating player name island above the title
	if (!mm_name_seeded)
	{
		mm_name_text = cvar_string("name");
		if (mm_name_text == "")
			mm_name_text = "Player";
		mm_name_cursor = strlen(mm_name_text);
		mm_name_seeded = TRUE;
	}

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([1, 65], [36, 36, 0], "Proto's Quake", '0 0 0', 0.5, 0);
	sui_text([0, 64], [36, 36, 0], "Proto's Quake", [1, 1, 1], 1, 0);

	vector pos = [0, -100];
	vector size = [148, 120];
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_END]);

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

		if (mm_name_text != "")
			cvar_set("name", mm_name_text);
	}

	// Connect button is swapped for a Disconnect button once we've left the
	// backdrop map (i.e. the user is in a real game / on a real server).
	// Clicking Disconnect re-launches the backdrop map and re-arms the
	// suppress-HUD flag, exactly like the engine-startup path in m_init.
	if (cvar("cl_menu_backdrop_active"))
	{
		if (my_button_colored("mm_connect", [0, 8], [size_x - 16, 20], "Connect to Proto.bar", '0.6 0.55 0.1', '0.75 0.7 0.2'))
		{
			// Close the menu immediately so m_drawloading takes over during
			// the network-connect phase (before the engine's auto-close on
			// map load would have fired).  Otherwise m_draw keeps running
			// and the main menu flashes with a stale Disconnect button.
			m_close();
			localcmd("set cl_menu_backdrop_active 0\n");
			localcmd("connect proto.bar\n");
		}
	}
	else
	{
		if (my_button_colored("mm_disconnect", [0, 8], [size_x - 16, 20], "Disconnect", '0.55 0.2 0.2', '0.75 0.3 0.3'))
		{
			string menumap = cvar_string("cl_menumap");
			if (menumap != "" && menumap != "none")
			{
				// Explicit m_close() so menu_active is known-FALSE before the
				// map swap; the trailing togglemenu then reliably re-opens the
				// menu after the backdrop finishes loading (same pattern as
				// the engine-startup path in m_init).
				m_close();
				localcmd("set cl_menu_backdrop_active 1\n");
				localcmd("deathmatch 1\n");
				localcmd("maxclients 2\n");
				localcmd(sprintf("map %s\n", menumap));
				localcmd("togglemenu\n");
			}
			else
			{
				localcmd("disconnect\n");
			}
		}
	}
	if (my_button("mm_create", [0, 8 + 24], [size_x - 16, 20], "Create Server"))
	{
		create_server_load_maps();
		current_menu = MENU_CREATE_SERVER;
	}
	my_button("mm_settings", [0, 8 + 48], [size_x - 16, 20], "Settings") ? current_menu = MENU_SETTINGS : 0;
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_END]);
	my_button("mm_quit", [0, -8], [size_x - 16, 20], "Quit") ? localcmd("quit\n") : 0;
	sui_pop_frame();

	sui_set_default_kb_focus("mm_return");
};

void(vector size) root_menu =
{
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	// Full-screen dim behind the main menu (gated on cl_menu_backdrop).
	if (cvar("cl_menu_backdrop"))
		sui_fill([0, 0], size, '0.01 0.01 0.02', 0.64, 0);
	switch (current_menu)
	{
		case MENU_MAIN: main_menu(); break;
		case MENU_CREATE_SERVER: create_server_menu(); break;
		case MENU_SETTINGS: settings_menu(); 
		default: break;
	}
};
