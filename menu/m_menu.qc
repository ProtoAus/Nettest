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

// --- Floating main-menu (new design) ---
// menu_font's native size list is 8 12 16 18 24 36 48 60 72; the
// constants below pick natives so text edges stay crisp.  Anything
// off this list scales and blurs.
const float FLOAT_MENU_MAIN_SIZE     = 24;   // big-options height (Create / Browser / Settings / Quit).
                                              // Two native sizes below the original 48 — menu_font's
                                              // size list is 8 12 16 18 24 36 48 ..., so 48→36→24.
const float FLOAT_MENU_SMALL_SIZE    = 16;   // connect / disconnect row height (one native step
                                              // smaller than 18; menu_font's list is 8 12 16 18 ...)
const float FLOAT_MENU_LEFT_PAD      = 32;   // left margin from screen edge
const float FLOAT_MENU_ROW_GAP_LARGE = 8;    // gap between consecutive 48-rows
const float FLOAT_MENU_ROW_GAP_SMALL = 4;    // gap between the two connect rows
const float FLOAT_MENU_TOP_GAP       = 18;   // gap between connect/disconnect block and main rows
const float FLOAT_MENU_QUIT_GAP      = 24;   // small visual gap before Quit

vector FLOAT_MENU_WHITE     = '1 1 1';
vector FLOAT_MENU_YELLOW    = '1 0.85 0.18';
vector FLOAT_MENU_GREEN     = '0.35 0.95 0.40';
vector FLOAT_MENU_RED       = '0.95 0.32 0.32';
vector FLOAT_MENU_HIGHLIGHT = '0.55 1 0.6';   // light green, used on hover

// Hover-sound state (drives one-shot click.ogg on hover-enter only).
//   last_hover_voiced_id  — the ID we played click.ogg for most
//                           recently.  Persists across frames so a
//                           button isn't re-sounded every frame the
//                           cursor sits on it.
//   this_frame_hovered_id — set by any Float_TextOption that's
//                           hovered this frame.  Cleared at the end
//                           of main_menu() so a "no hover" frame
//                           resets last_hover_voiced_id (lets the
//                           user re-hover the same row later and
//                           still hear the sound).
string last_hover_voiced_id;
string this_frame_hovered_id;

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
		// Backdrop latch (see m_main.qc + worldspawn in sv_main.qc): set the
		// pending flag, not sv_backdrop directly, so a console `map X` stays
		// a real game.
		localcmd("set sv_backdrop_pending 1\n");
		// See m_main.qc backdrop launcher — bind to port 0 (OS-assigned
		// ephemeral) so the backdrop never occupies 27500 for a real local/
		// dedicated server.  The backdrop client still uses the loopback socket.
		localcmd("sv_port 0\n");
		localcmd("deathmatch 1\n");
		localcmd("maxclients 2\n");
		// nettest (P26): returning to the nettest backdrop — drop the heavy game we were playing
		// (HL2/CS:S/CoD) but keep the always-mounted base (valve+cstrike) the mod borrows.  Engine
		// no-ops if the set is already exactly the base.  (Empty this to "" once nettest is fully
		// self-contained — matches create_server_deps_for_spec's base.)
		localcmd("fs_useaddons \"steam:Half-Life/valve\" \"steam:Half-Life/cstrike\"\n");
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

// Float_TextOption — drop-shadowed left-anchored text "button" for
// the floating main menu.  Handles:
//   - hover: faint white wash behind the text (subtle highlight that
//            works for any text colour, since pure white can't get
//            brighter via colour multiplication)
//   - held:  text colour × 0.5 for press feedback
//   - hover-enter: one-shot sounds/ui/click.ogg (uses the file-scope
//                  last_hover_voiced_id state machine — see globals
//                  at top of file)
//   - click: sounds/ui/submit.ogg
// Hit-zone width follows `stringwidth(text, FALSE, [h,h,0])` so the
// clickable rect tracks variable-length labels.  Returns 1 on the
// frame the click is registered.
float(string id, vector pos, float height, string text, vector color) Float_TextOption =
{
	vector text_sz = [height, height, 0];
	float text_w = stringwidth(text, FALSE, text_sz);
	vector size = [text_w, height, 0];

	float hovered = sui_is_hovered(id);
	float held    = sui_is_held(id);

	if (hovered)
	{
		this_frame_hovered_id = id;
		if (last_hover_voiced_id != id)
		{
			localsound("sounds/ui/click.ogg");
			last_hover_voiced_id = id;
		}
	}

	// Hover swaps the text colour to FLOAT_MENU_HIGHLIGHT (light
	// green) regardless of the base colour — works for white +
	// yellow + green + red rows.  Held additionally halves the
	// brightness of whatever colour is showing right now.
	vector base = hovered ? FLOAT_MENU_HIGHLIGHT : color;
	vector display_color = held ? base * 0.5 : base;

	// Same-position double-draw — both passes at full alpha at
	// exactly the same coordinates.  No offset (so no visible
	// shadow/copy), but the anti-aliased fringe pixels at the
	// glyph edges get additively blended, which makes the text
	// read noticeably more opaque against the menumap backdrop
	// without changing the perceived font.
	sui_text(pos, text_sz, text, display_color, 1.0, 0);
	sui_text(pos, text_sz, text, display_color, 1.0, 0);

	sui_action_element(pos, size, id, sui_noop);

	float clicked = sui_is_clicked(id);
	if (clicked)
		localsound("sounds/ui/submit.ogg");
	return clicked;
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
	{ "Drop Weapon", "impulse 8" },
	{ "Grapple", "+grapple" },
	{ "Last Weapon", "impulse 14" },
	{ "Weapon Special", "impulse 7" },
	{ "Cycle Next", "impulse 12" },
	{ "Cycle Prev", "impulse 13" },
	{ "Weapon Slot 1", "impulse 1" },
	{ "Weapon Slot 2", "impulse 2" },
	{ "Weapon Slot 3", "impulse 3" },
	{ "Weapon Slot 4", "impulse 4" },
	{ "Weapon Slot 5 (C4)", "impulse 5" },
	{ "Team Menu", "impulse 28" },
	{ "Flashlight", "impulse 50" },
	{ "Spray", "impulse 19" },
	{ "Voice (bind in console)", "+voip" },
	{ "Show Scores", "+showscores" },
	{ "Radio", "radio" },
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
// Order mirrors the Settings menu sectioning so the generated cfg
// reads top-to-bottom in the same groups: General, Crosshair, Graphics,
// Perf & Net. Engine cvars (sys_*, vid_*, gl_*, r_renderscale,
// r_viewmodel_maxlight, cl_yieldcpu/maxfps/idlefps) are listed too —
// the writer just calls cvar_string() so it works regardless of QC vs
// engine origin.
string client_config_cvars[] =
{
    // --- General ---
    "name",
    "volume",
    "sensitivity",
    "fov",

    // --- Crosshair ---
    "cl_crosshairlength",
    "cl_crosshairthickness",
    "cl_crosshairgap",
    "cl_crosshaircolour",
    "cl_crosshairdynamic",
    "cl_crosshairweapongap",
    "cl_teamcolours",

    // --- Graphics: Decals & Bullet Holes ---
    "cl_bulletholes",
    "cl_bullethole_renderer",
    "cl_bulletholes_max",
    "cl_bullethole_distance",
    "cl_bullethole_dedupe_scale",
    "cl_decal_opacity",
    "cl_impact_quality",
    "cl_impact_particle_offset",
    "cl_impact_light",
    "cl_impact_light_scale",
    "cl_impact_light_offset",
    "cl_ejectcasing",
    "cl_ejectmag",

    // --- Graphics: Lighting ---
    "cl_muzzleflash_light",
    "cl_muzzleflash_light_scale",
    // Dynamic-light mode (RTLight vs lightmap rebuild) — persisted so a user's
    // dlights_fast/dlights_classic choice survives restarts (see data/default.cfg).
    "r_shadow_realtime_dlight",
    "r_shadow_realtime_dlight_shadows",
    "r_dynamic",
    "r_viewmodel_maxlight",
    "cl_viewmodel_nolight",

    // --- Graphics: Renderer ---
    "vid_conautoscale",
    "r_renderscale",
    "gl_texturemode2d",
    "gl_texturemode",

    // --- Perf & Net: Network & Prediction ---
    "cl_extrap",
    "cl_extrap_grounded",
    "cl_extrap_max",
    "cl_extrap_smooth",
    "cl_extrap_smooth_time",
    "cl_predict_hits",
    "cl_predict_breaks",
    "cl_interp_time",
    "cl_weapontrace_ignore_playerclip",

    // --- Perf & Net: Phys-Drop Smoothing ---
    "cl_physdrop_smooth_time",
    "cl_physdrop_extrap",
    "cl_physdrop_angextrap",

    // --- Perf & Net: Performance / Frame Pacing ---
    "sys_highpriority",
    "sys_clockprecision",
    "sys_clocktype",
    "sys_framepacing",
    "cl_yieldcpu",
    "cl_maxfps",
    "cl_idlefps",

    // --- Main-menu picks ---
    "cl_player_model_choice",
};

// Server cvars formerly enumerated here — moved to the manifest in
// shared/sh_cvar_table.qc.  Persisted entries are anything with the
// CVAR_FLAG_SAVE_TO_SERVER_CFG bit; the writer is CVar_WriteServerCfg.

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
    // from a previous save, so we never persist "" again.  The fixup
    // walks the manifest now — see CVar_ForceDefaults.
    Menu_FixupEmptyDefaults();

    // rcon_password has a special recovery path: if it came back empty,
    // first try the offline-stash cvar (sv_rcon_password_shadow), then
    // the previous data/server.cfg.  Done before the writer runs so
    // the live cvar carries the recovered value into the dump.
    if (cvar_string("rcon_password") == "")
    {
        string rp = cvar_string("sv_rcon_password_shadow");
        if (rp == "")
            rp = Menu_ReadConfigValue("data/server.cfg", "rcon_password");
        if (rp != "")
            cvar_set("rcon_password", rp);
    }

    // Single source of truth: shared/sh_cvar_table.qc.  Filtered to
    // SV-side entries with CVAR_FLAG_SAVE_TO_SERVER_CFG.
    CVar_WriteServerCfg("data/server.cfg");
};

// Called from the Settings menu "Back" / apply path — saves both client and binds.
void() Menu_SaveConfig =
{
    Menu_SaveClientConfig();
};

// Backward-compat shim: a couple of older callers may still ask the
// menu to "register a cvar with a default and force-set if empty".
// Forwards to the engine's registercvar (menu signature has 3 args)
// and applies the empty-string fallback once, the same as before.
void(string name, string def) menu_register_default =
{
    registercvar(name, def, 0);
    if (cvar_string(name) == "")
        cvar_set(name, def);
};

// Restore manifest defaults for any SV-side cvar that came back empty
// after data/server.cfg exec.  Walks the manifest in
// shared/sh_cvar_table.qc — adding a new cvar there is automatically
// included here.
void() Menu_FixupEmptyDefaults =
{
    CVar_ForceDefaults();
};

void() Menu_RegisterCvars =
{
    // Populate the manifest, then registercvar() every entry so the
    // menu VM doesn't auto-create cvars on first read and the engine
    // sees the intended defaults before data/*.cfg is exec'd.
    CVar_Init();
    CVar_RegisterMine();

    // Menu-only cvars that don't belong in the manifest (purely
    // ephemeral or menu-internal).  registercvar is idempotent.
    registercvar("_nettest_menu_active", "0", 0);

    // Crosshair UI toggles registered on the CSQC side (CVAR_SIDE_CL).
    // The manifest's CVar_RegisterMine flagged them BOTH for menu so
    // they're already covered here — no extra wrangling needed.

    // Idempotent backstop for the small client_config_cvars list (used
    // by Menu_SaveClientConfig for data/settings.cfg).  Anything in
    // there that overlaps the manifest is a no-op; the rest gets a
    // blank default so the engine knows the cvar exists.
    float i;
    for (i = 0; i < client_config_cvars.length; i++)
        registercvar(client_config_cvars[i], "", 0);
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

// Player-name state — preserved as no-op infrastructure after the
// main-menu rework dropped the inline name input.  m_main.qc still
// calls mm_flush_name() on Enter / menu-close, so the function
// stays defined; its early-return on !mm_name_seeded effectively
// makes it a no-op since nothing ever flips the flag now.  Future
// reintroduction of a name field (e.g. in Settings) can re-seed
// mm_name_text from cvar_string("name") and flip mm_name_seeded.
string mm_name_text;
float mm_name_seeded;

void() mm_flush_name =
{
	if (!mm_name_seeded) return;          // field never opened this session
	if (mm_name_text == "") return;       // empty → ignore, keep current
	if (mm_name_text == cvar_string("name")) return;   // unchanged, skip
	cvar_set("name", mm_name_text);
};

// Forward decls — defined in their respective files (compiled after this).
void(vector menu_size) Sprays_DrawPanel;
void(vector menu_size) Playermodels_DrawPanel;

void() main_menu =
{
	// --- Title + subtitle (unchanged) ---
	// Centred near the top of the screen.  Positioning uses a
	// fixed Y band rather than the old "stack-relative" math
	// because the menu stack is now a free-floating left column,
	// not a centred box.
	vector title_font = menu_pick_main_title_font(menu_root_size_x - 48);
	vector subtitle_font = menu_pick_subtitle_font(title_font_y);
	float title_block_y = max(12, floor(menu_root_size_y * 0.15) - floor(title_font_y * 0.5));
	float subtitle_x = max(8, floor(title_font_y * 0.80));
	float subtitle_y = title_block_y + floor(title_font_y * 0.85) - 3;

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, title_block_y], title_font, "Quakers", [1, 1, 1], 1, 0);
	sui_text([subtitle_x, subtitle_y], subtitle_font,
	         "The Religious Society of Friends",
	         '0.80 0.80 0.80', 1, 0);

	// Floating Sprays panel — right-edge anchored, independent of
	// the main-menu left column.  See menu/m_sprays.qc.
	Sprays_DrawPanel(menu_root_size);

	// Player-model picker — sits immediately left of Sprays, shares
	// the same baseline. See menu/m_playermodels.qc.
	Playermodels_DrawPanel(menu_root_size);

	// Build tag — bottom-right corner of the screen, dimmed.
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_END]);
	sui_text([-6, -6], MENU_TEXT_SMALL,
	         "Build: nettest16",
	         '0.80 0.80 0.80', 1, 0);

	// --- Floating left-anchored option column ---
	// Two modes:
	//   backdrop (menumap, not connected): yellow Proto.bar +
	//     green Localhost on top of the four main options.
	//   in-game (real server): a single red Disconnect on top.
	// All rows use Float_TextOption which handles hover sounds,
	// drop shadow, hold-darken, click sound, and SUI hit-zone
	// registration sized to the actual text width.
	float backdrop_mode = (serverkey("sv_backdrop") == "1");

	// Compute block height for vertical centring.  Main block is
	// always 3 big rows + 2 small gaps + the gap-before-Quit + the
	// Quit row.  The top block changes shape per mode.
	float main_block = FLOAT_MENU_MAIN_SIZE * 3
	                 + FLOAT_MENU_ROW_GAP_LARGE * 2
	                 + FLOAT_MENU_QUIT_GAP
	                 + FLOAT_MENU_MAIN_SIZE;
	float top_block;
	if (backdrop_mode)
		top_block = FLOAT_MENU_SMALL_SIZE * 2
		          + FLOAT_MENU_ROW_GAP_SMALL
		          + FLOAT_MENU_TOP_GAP;
	else
		top_block = FLOAT_MENU_SMALL_SIZE
		          + FLOAT_MENU_TOP_GAP;
	float block_height = top_block + main_block;

	// Bottom-anchored at 15% up from the bottom edge — scales with
	// viewport height so the menu sits consistently on any
	// resolution instead of pinning to a fixed pixel offset.
	// Quit row's bottom edge lands at menu_root_size_y * 0.85.
	float bx = FLOAT_MENU_LEFT_PAD;
	float by = floor(menu_root_size_y * 0.85) - block_height;
	float y  = by;

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

	if (backdrop_mode)
	{
		if (Float_TextOption("mm_proto", [bx, y, 0],
		                     FLOAT_MENU_SMALL_SIZE, "Connect to Proto.bar",
		                     FLOAT_MENU_YELLOW))
		{
			// Close the menu so m_drawloading takes over while the
			// network-connect phase runs (preserves the old click
			// flow exactly — see the historical comment block in
			// pre-rewrite main_menu for the rationale).
			m_close();
			localcmd("set cl_menu_backdrop_active 0\n");
			localcmd("set sv_backdrop 0\n");
			localcmd("sv_port 27500\n");
			localcmd("connect proto.bar\n");
		}
		y += FLOAT_MENU_SMALL_SIZE + FLOAT_MENU_ROW_GAP_SMALL;

		if (Float_TextOption("mm_local", [bx, y, 0],
		                     FLOAT_MENU_SMALL_SIZE, "Connect to Localhost",
		                     FLOAT_MENU_GREEN))
		{
			m_close();
			localcmd("set cl_menu_backdrop_active 0\n");
			localcmd("set sv_backdrop 0\n");
			localcmd("sv_port 27500\n");
			localcmd("connect localhost\n");
		}
		y += FLOAT_MENU_SMALL_SIZE + FLOAT_MENU_TOP_GAP;
	}
	else
	{
		if (Float_TextOption("mm_disconn", [bx, y, 0],
		                     FLOAT_MENU_SMALL_SIZE, "Disconnect",
		                     FLOAT_MENU_RED))
			Menu_DisconnectAndReturnToMenuMap();
		y += FLOAT_MENU_SMALL_SIZE + FLOAT_MENU_TOP_GAP;
	}

	if (Float_TextOption("mm_create", [bx, y, 0],
	                     FLOAT_MENU_MAIN_SIZE, "Create Server", FLOAT_MENU_WHITE))
	{
		create_server_load_maps();
		current_menu = MENU_CREATE_SERVER;
	}
	y += FLOAT_MENU_MAIN_SIZE + FLOAT_MENU_ROW_GAP_LARGE;

	if (Float_TextOption("mm_browser", [bx, y, 0],
	                     FLOAT_MENU_MAIN_SIZE, "Server Browser", FLOAT_MENU_WHITE))
		current_menu = MENU_SERVER_BROWSER;
	y += FLOAT_MENU_MAIN_SIZE + FLOAT_MENU_ROW_GAP_LARGE;

	if (Float_TextOption("mm_settings", [bx, y, 0],
	                     FLOAT_MENU_MAIN_SIZE, "Settings", FLOAT_MENU_WHITE))
		current_menu = MENU_SETTINGS;
	y += FLOAT_MENU_MAIN_SIZE + FLOAT_MENU_QUIT_GAP;

	if (Float_TextOption("mm_quit", [bx, y, 0],
	                     FLOAT_MENU_MAIN_SIZE, "Quit", FLOAT_MENU_WHITE))
		localcmd("quit\n");

	// Hover-sound transition reset.  If no button was hovered this
	// frame, clear last_hover_voiced_id so re-entering any button
	// next time re-triggers click.ogg.
	if (this_frame_hovered_id == "")
		last_hover_voiced_id = "";
	this_frame_hovered_id = "";

	sui_set_default_kb_focus("mm_create");
};

void(vector size) root_menu =
{
	menu_root_size = size;
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	// Full-screen dim behind heavier submenus only. The floating main
	// menu is meant to sit directly over the live menumap backdrop.
	if (current_menu != MENU_MAIN && cvar("cl_menu_backdrop"))
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
