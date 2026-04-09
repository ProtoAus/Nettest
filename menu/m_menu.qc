float menu_font;

vector MENU_BG = '0.2 0.3 0.4';
vector MENU_BG_DARK = '0.1 0.15 0.2';
vector MENU_BORDER = '0.3 0.4 0.5';
vector MENU_BUTTON = '0.3 0.4 0.5';
vector MENU_BUTTON_BORDER = '0.35 0.45 0.55';
vector MENU_BUTTON_RETURN = '0.28 0.38 0.30';
vector MENU_BUTTON_RETURN_BORDER = '0.34 0.46 0.38';
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

void(string id, vector pos, vector size, float maxlen, __inout string text, __inout float cursor) text_input_control =
{
	vector textsize = MENU_TEXT_SMALL;
	float text_y = floor(((size_y - 4) - textsize_y) * 0.5);
	sui_push_frame(pos, size);
	vector basecolor = sui_is_hovered(id) ? MENU_BG_DARK + MENU_HIGHLIGHT * 0.08 : MENU_BG_DARK;
	sui_fill([0, 0], size, basecolor, 0.6, 0);

	sui_text_input(id, [0, 0], size, text, cursor);
	sui_cap_input_length(maxlen, text, cursor);

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	float focused = sui_is_last_clicked(id);
	focused ? sui_border_box([0, 0], size, 1, MENU_BORDER, 0.6, 0) : 0;

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
	sui_fill([0, 0], size, basecolor, 0.6, 0);
	sui_border_box([0, 0], size, 1, border_color, 0.4, 0);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	sui_text([0, 0], MENU_TEXT_SMALL, text, MENU_TEXT_1, 1, 0);
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
	if (current != old) cvar_set(cvar_s, ftos(current));
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
	sui_fill([0, 0], size, MENU_BG_DARK, 0.55, 0);
	sui_border_box([0, 0], size, 1, MENU_BORDER, 0.25, 0);
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
	{ "Weapon Special", "impulse 10" },
	{ "Cycle Next", "impulse 12" },
	{ "Cycle Prev", "impulse 13" },
	{ "Weapon Slot 1", "impulse 1" },
	{ "Weapon Slot 2", "impulse 2" },
	{ "Weapon Slot 3", "impulse 3" },
	{ "Weapon Slot 4", "impulse 4" },
	{ "Team Menu", "impulse 28" },
	{ "Show Scores", "+showscores" },
	{ "Chat", "messagemode" },
	{ "Screenshot", "screenshot" },
	{ "Quit", "quit" },
	{ "Toggle Console", "toggleconsole" },
	{ "Toggle Menu", "togglemenu" },
};

void(string id, vector pos, vector size, string name, string command) bind_button =
{
	sui_push_frame(pos, size);
	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
	string key = sui_binder(id, [0, 0], size, name, command);
	if (sui_is_hovered(id)) sui_fill([0, 0], size, MENU_HIGHLIGHT, 0.1, 0);
	sui_text([4, 0], MENU_TEXT_SMALL, name, MENU_TEXT_1, 1, 0);
	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_CENTER]);
	sui_text([-4, 0], MENU_TEXT_SMALL, key, MENU_TEXT_1, 1, 0);

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
//  Menus
// =============================================

void() help_menu =
{
	vector pos = [0, 0];
	vector size = [360, 280];

	sui_push_frame(pos, size);

	sui_fill([0, 0], size, MENU_BG, 0.75, 0);
	sui_border_box([0, 0], size, 2, MENU_BORDER, 0.3, 0);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, 4], MENU_TEXT_MEDIUM, "Help", MENU_TEXT_1, 1, 0);

	float xpos = 0;
	float ypos = 32;
	sui_text([xpos, ypos], MENU_TEXT_SMALL, "Bunch of Help and About", MENU_TEXT_1, 1, 0);

	sui_set_align([SUI_ALIGN_END, SUI_ALIGN_END]);
	my_button("hlp_back", [-8, -8], [80, 20], "Back") ? current_menu = MENU_MAIN : 0;

	if (sui_listen_back())
		current_menu = MENU_MAIN;

	sui_pop_frame();
};

void() main_menu =
{
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
	sui_text([0, 64], [36, 36, 0], "Proto's Quake", [1, 1, 1], 1, 0);

	vector pos = [0, -24];
	vector size = [148, 164];
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_END]);
	sui_push_frame(pos, size);

	sui_fill([0, 0], size, MENU_BG, 0.3, 0);
	sui_border_box([0, 0], size, 2, MENU_BORDER, 0.2, 0);

	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);

	my_button_colored("mm_return", [0, 8], [size_x - 16, 20], "Return", MENU_BUTTON_RETURN, MENU_BUTTON_RETURN_BORDER) ? m_close() : 0;
	if (my_button("mm_create", [0, 8 + 24], [size_x - 16, 20], "Create Server"))
	{
		create_server_load_maps();
		current_menu = MENU_CREATE_SERVER;
	}
	my_button("mm_settings", [0, 8 + 48], [size_x - 16, 20], "Settings") ? current_menu = MENU_SETTINGS : 0;
	my_button("mm_help", [0, 8 + 72], [size_x - 16, 20], "Help") ? current_menu = MENU_HELP : 0;
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_END]);
	my_button("mm_quit", [0, -8], [size_x - 16, 20], "Quit") ? localcmd("quit\n") : 0;
	sui_pop_frame();

	sui_set_default_kb_focus("mm_return");
};

void(vector size) root_menu =
{
	sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
	sui_fill([0, 0], size, '0 0 0', 0.5, 0);
	switch (current_menu)
	{
		case MENU_MAIN: main_menu(); break;
		case MENU_CREATE_SERVER: create_server_menu(); break;
		case MENU_SETTINGS: settings_menu(); break;
		case MENU_HELP: help_menu();
		default: break;
	}
};
