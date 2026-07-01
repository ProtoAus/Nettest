vector binds_scroll;
string settings_sensitivity_text;
float settings_sensitivity_cursor;
string settings_fov_text;
float settings_fov_cursor;

// Settings menu tab state.
//   0 = General, 1 = Crosshair, 2 = Graphics, 3 = Perf & Net, 4 = Voice
float settings_tab;

// Hover-tooltip latch. Each widget calls settings_tip(id, "description")
// after rendering itself; sui_is_hovered(id) checks if the cursor is
// over that widget this frame and, if so, replaces the latch text.
// Cleared at the start of every tab draw and rendered in the panel
// footer above the Back button.
string settings_tip_text;

void(string id, string desc) settings_tip =
{
    if (sui_is_hovered(id))
        settings_tip_text = desc;
};

// Tip-wrapped slider — same args as cvar_slider plus a description.
// cvar_slider's internal sui_action_element id is strcat(cvar_s, "sldr"),
// so the tip latches off that.
void(vector pos, vector size, vector minmaxsteps, string cvar_s, string label, string fmt, string desc) cvar_slider_tip =
{
    cvar_slider(pos, size, minmaxsteps, cvar_s, label, fmt);
    settings_tip(strcat(cvar_s, "sldr"), desc);
};

// Tip-wrapped boolean toggle bound to a numeric cvar (>0 == on).
void(string id, vector pos, vector size, string label, string cvar_s, string desc) settings_toggle_tip =
{
    float val = cvar(cvar_s) > 0;
    if (menu_toggle_button(id, pos, size, label, val))
        cvar_set(cvar_s, val ? "1" : "0");
    settings_tip(id, desc);
};

// localcmd_local-routed variants — for engine cvars flagged
// CVAR_NOTFROMSERVER (sys_highpriority, sys_clocktype,
// sys_clockprecision, sys_framepacing, plus the cfg_save_* family).
// The QC `cvar_set` builtin's PF_cvar_set silently rejects writes
// to those (engine/common/pr_bgcmd.c:1966) and the standard
// `localcmd` runs at RESTRICT_INSECURE which trips the same gate
// at the console-parser layer ("Server tried setting X cvar").
//
// localcmd_local is a custom engine builtin (engine/client/pr_menu.c:
// PF_M_localcmd_local) that submits to Cbuf at RESTRICT_LOCAL — the
// same trust level as the user typing into the console — so writes
// to NOTFROMSERVER cvars actually take. Menu-VM only by design;
// CSQC/SSQC don't get it.
// Cached at first use; 1 = engine has the patched builtin, 0 = old
// engine binary (pre-localcmd_local), -1 = unprobed. Bare declaration
// (no initialiser) so fteqcc treats it as a mutable global rather
// than folding it to a const. Probed via checkbuiltin() so an engine
// without the patch falls back to plain localcmd instead of crashing
// on a `Builtin not implemented` error.
var float settings_have_lc_local;

void(string cmd_str) settings_dispatch_local =
{
    // settings_have_lc_local is 0 on first call (QC zero-init); we
    // re-probe each call until checkbuiltin returns true so a runtime
    // engine swap is also handled. Cheap — checkbuiltin is just a
    // string lookup. Once it sticks at 1 the branch is permanent.
    if (!settings_have_lc_local)
    {
        if (checkbuiltin(localcmd_local))
            settings_have_lc_local = 1;
    }
    if (settings_have_lc_local)
        localcmd_local(cmd_str);
    else
        localcmd(cmd_str);   // best-effort; CVAR_NOTFROMSERVER cvars will reject
};

void(string id, vector pos, vector size, string label, string cvar_s, string desc) settings_toggle_lc_tip =
{
    float val = cvar(cvar_s) > 0;
    if (menu_toggle_button(id, pos, size, label, val))
        settings_dispatch_local(strcat(cvar_s, " ", val ? "1" : "0", "\n"));
    settings_tip(id, desc);
};

void(vector pos, vector size, vector minmaxsteps, string cvar_s, string label, string fmt, string desc) cvar_slider_lc_tip =
{
    // Mirror cvar_slider's body so the write side can route through
    // settings_dispatch_local. cvar_slider can't be reused because it
    // hard-codes cvar_set on the write path.
    float current = cvar(cvar_s);
    float old = current;
    sui_push_frame(pos, [size_x, size_y * 0.5 - 4]);
    sui_text([0, 0], MENU_TEXT_SMALL, label, MENU_TEXT_1, 1, 0);
    sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
    sui_text([0, 0], MENU_TEXT_SMALL, sprintf(fmt, current), MENU_TEXT_1, 1, 0);
    sui_pop_frame();
    string sldr_id = strcat(cvar_s, "sldr");
    my_slider(sldr_id, [pos_x, pos_y + size_y * 0.5], [size_x, size_y * 0.5], minmaxsteps, current);
    if (current != old)
        settings_dispatch_local(strcat(cvar_s, " ", sprintf(fmt, current), "\n"));
    settings_tip(sldr_id, desc);
};

// Tip-wrapped enum cycler — on click, advances to the next value in
// `options` (space-separated). Works for both string and numeric cvars.
void(string id, vector pos, vector size, string label, string cvar_s, string options, string desc) settings_enum_tip =
{
    string cur = cvar_string(cvar_s);
    string display = strcat(label, ": ", cur);
    if (my_button_colored(id, pos, size, display, MENU_BUTTON, MENU_BUTTON_BORDER))
    {
        float n = tokenize(options);
        if (n > 0)
        {
            float idx = -1;
            for (float i = 0; i < n; i++)
                if (argv(i) == cur) { idx = i; break; }
            idx = (idx + 1) % n;
            cvar_set(cvar_s, argv(idx));
        }
    }
    settings_tip(id, desc);
};

// Section header row inside a tab — small bold-ish label + thin hairline.
void(vector pos, float width, string label) settings_section =
{
    sui_text([pos_x, pos_y], MENU_TEXT_SMALL, label, MENU_TEXT_1, 1, 0);
    sui_fill([pos_x, pos_y + 11], [width, 1], MENU_BORDER, 0.6, 0);
};

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
	// Two equal columns split down the centre of the panel. Was
	// asymmetric (left=182, right=216); the new tabs use both
	// columns for widget content so they need to match.
	float left_width  = (size_x - pad * 2 - gap) * 0.5;
	float right_x     = pad + left_width + gap;
	float right_width = left_width;
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
	// 5 tabs across the full panel width. Each tab gets ~equal share of
	// (panel_width - pad*2) minus 4 inter-tab gaps. Tab strip widened
	// past left_width so longer labels (Perf & Net) fit.
	settings_tip_text = "";
	{
		float tab_strip_w = size_x - pad * 2;
		float tab_gap     = 4;
		float tab_w       = (tab_strip_w - tab_gap * 4) * 0.2;
		vector active_col   = MENU_BUTTON_RETURN;
		vector active_brd   = MENU_BUTTON_RETURN_BORDER;
		vector inactive_col = MENU_BG_DARK;
		vector inactive_brd = MENU_BORDER;

		if (my_button_colored("tab_general", [xpos, ypos], [tab_w, 20], "General",
			settings_tab == 0 ? active_col : inactive_col,
			settings_tab == 0 ? active_brd : inactive_brd))
			settings_tab = 0;

		if (my_button_colored("tab_crosshair", [xpos + (tab_w + tab_gap), ypos], [tab_w, 20], "Crosshair",
			settings_tab == 1 ? active_col : inactive_col,
			settings_tab == 1 ? active_brd : inactive_brd))
			settings_tab = 1;

		if (my_button_colored("tab_graphics", [xpos + (tab_w + tab_gap) * 2, ypos], [tab_w, 20], "Graphics",
			settings_tab == 2 ? active_col : inactive_col,
			settings_tab == 2 ? active_brd : inactive_brd))
			settings_tab = 2;

		if (my_button_colored("tab_perfnet", [xpos + (tab_w + tab_gap) * 3, ypos], [tab_w, 20], "Perf & Net",
			settings_tab == 3 ? active_col : inactive_col,
			settings_tab == 3 ? active_brd : inactive_brd))
			settings_tab = 3;

		if (my_button_colored("tab_voice", [xpos + (tab_w + tab_gap) * 4, ypos], [tab_w, 20], "Voice",
			settings_tab == 4 ? active_col : inactive_col,
			settings_tab == 4 ? active_brd : inactive_brd))
			settings_tab = 4;
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
	else if (settings_tab == 1)
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
		ypos += 34;

		// Dynamic inaccuracy toggle — when off, the crosshair stops
		// expanding on jump/fire/move (the per-weapon baseline can still
		// differ unless the next toggle is also off).
		float settings_cx_dynamic = cvar("cl_crosshairdynamic") > 0;
		if (menu_toggle_button("cx_dyn_btn", [xpos, ypos], [left_width, 20], "Dynamic Inaccuracy", settings_cx_dynamic))
			cvar_set("cl_crosshairdynamic", settings_cx_dynamic ? "1" : "0");
		ypos += 24;

		// Per-weapon gap toggle — when off, the gap stays uniform across
		// weapons (hlshotgun won't visibly widen compared to the glock).
		float settings_cx_weapon_gap = cvar("cl_crosshairweapongap") > 0;
		if (menu_toggle_button("cx_wep_btn", [xpos, ypos], [left_width, 20], "Per-Weapon Gap", settings_cx_weapon_gap))
			cvar_set("cl_crosshairweapongap", settings_cx_weapon_gap ? "1" : "0");
		ypos += 24;
	}
	else if (settings_tab == 2)
	{
		// --- Graphics tab ---
		// Two columns: decals on the left; lighting + renderer on the
		// right. Widget rows are 18 px tall (vs 28 in General/Crosshair)
		// to fit ~9 widgets per column inside the 280 px content area.
		float row_h    = 18;
		float row_step = 21;
		float hdr_step = 16;
		float colL_x   = xpos;
		float colR_x   = right_x;
		float colL_w   = left_width;
		float colR_w   = right_width;
		float yL = ypos, yR = ypos;

		// --- Left column: Decals & Bullet Holes ---
		settings_section([colL_x, yL], colL_w, "Decals & Bullet Holes");                                     yL += hdr_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 2, 2],   "cl_bulletholes",          "Bullet Holes",     "%.0f", "Master toggle. 0=off, 1=walls only, 2=walls + props.");                              yL += row_step;
		settings_toggle_tip("bh_renderer", [colL_x, yL], [colL_w, row_h], "Polygon Renderer", "r_bullethole_renderer", "On=cheap polygon quad. Off=legacy adddecal (BSP-clipped, slower).");                    yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [128, 2048, 15], "cl_bulletholes_max",   "Max Holes",        "%.0f", "Most bullet holes kept on screen. Lower = better fps.");                              yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 3000, 30],   "cl_bullethole_distance","Hole Draw Distance",  "%.0f", "Distance LOD. Holes farther than this are skipped.");                            yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 2, 20],      "cl_bullethole_dedupe_scale","Dedupe Scale","%.2f", "How aggressively new holes overwrite nearby old ones (0=stack, 2=aggressive).");      yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 1, 10],      "cl_decal_opacity",     "Decal Opacity",    "%.1f", "Global alpha multiplier for bullet/blood/paint decals.");                              yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 1, 1],       "cl_impact_quality",    "Impact Particles", "%.0f", "Bullet-impact smoke + sparks. 0=off, 1=on. (Impact dynamic light is the separate 'Impact Light' toggle.)");   yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 8, 8],       "cl_impact_particle_offset","Particle Push","%.0f", "Push impact particles this many units along the surface normal\nso they don't z-fight the wall they spawned on.");      yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 1, 10],      "cl_impact_light_scale","Impact Light Scale","%.1f", "Brightness scale for the per-impact dynamic light flash.");                            yL += row_step;

		// --- Right column: Lighting + Renderer ---
		settings_section([colR_x, yR], colR_w, "Lighting");                                                  yR += hdr_step;
		settings_toggle_tip("mz_light", [colR_x, yR], [colR_w, row_h], "Muzzle Flash Light", "cl_muzzleflash_light", "Brief dynamic light at the muzzle on each shot.");                                          yR += row_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0, 1, 10],      "cl_muzzleflash_light_scale","Muzzle Light Scale","%.1f","Brightness scale for the muzzle flash dynamic light.");                          yR += row_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0, 255, 51],    "r_viewmodel_maxlight", "Viewmodel Max Light","%.0f", "Caps how bright the viewmodel can become under map lighting (0–255).");             yR += row_step;
		yR += 6;

		settings_section([colR_x, yR], colR_w, "Renderer");                                                  yR += hdr_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [1, 4, 3],       "vid_conautoscale",     "UI Auto-Scale",    "%.0f", "Console/HUD scale factor (1 = native pixel size, 4 = 4x).");                          yR += row_step;
		// 0.5..2 range with 6 steps gives positions 0.5, 0.75, 1.0,
		// 1.25, 1.5, 1.75, 2.0. <1 = downsample (faster), >1 = SSAA.
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0.5, 2.0, 6],   "r_renderscale",        "Render Scale",     "%.2f", "<1 renders below screen res then upscales (faster).\n>1 renders above then downsamples (SSAA, sharper).");  yR += row_step;
		settings_enum_tip("gl_tex2d", [colR_x, yR], [colR_w, row_h], "2D Filter", "gl_texturemode2d", "n.l l.l nll lll", "Texture filtering for 2D (HUD/menu).\nFirst char = minify, third = magnify. n=nearest (crisp pixels), l=linear (blur).");      yR += row_step;
		settings_enum_tip("gl_tex3d", [colR_x, yR], [colR_w, row_h], "3D Filter", "gl_texturemode",   "n.l l.l nll lll", "Texture filtering for the 3D world.\nMiddle char = mipmap blend; nll = crisp + smooth distance.");                              yR += row_step;
	}
	else if (settings_tab == 3)
	{
		// --- Perf & Net tab ---
		// row_step shrunk from 21→19 vs Graphics tab because Perf & Net
		// has more rows (8 + 3 + 7 widgets across two cols + 3 section
		// headers). Phys-Drop section moved to the bottom of the right
		// column so the left column doesn't run past the Back-button
		// row at the bottom of the panel.
		row_h    = 17;
		row_step = 19;
		hdr_step = 16;
		colL_x   = xpos;
		colR_x   = right_x;
		colL_w   = left_width;
		colR_w   = right_width;
		yL = ypos;
		yR = ypos;

		// --- Left column: Network & Prediction (9 widgets) ---
		settings_section([colL_x, yL], colL_w, "Network & Prediction");                                       yL += hdr_step;
		settings_toggle_tip("ex_on",         [colL_x, yL], [colL_w, row_h], "Extrapolate",         "cl_extrap",          "Predict remote-player motion past the last received snapshot.");                       yL += row_step;
		settings_toggle_tip("ex_grounded",   [colL_x, yL], [colL_w, row_h], "Extrap Grounded",     "cl_extrap_grounded", "Also extrapolate players that look stationary on ground.");                            yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 20, 20],  "cl_extrap_max",       "Extrap Max",          "%.0f", "Max snapshots to extrapolate before freezing — caps how far we predict.");           yL += row_step;
		settings_toggle_tip("ex_smooth",     [colL_x, yL], [colL_w, row_h], "Smooth Snaps",        "cl_extrap_smooth",   "Decay position-snap correction visually instead of teleporting.");                     yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 0.2, 40], "cl_extrap_smooth_time","Smooth Time",        "%.3f", "Seconds to decay a snap. Lower = snappier, higher = smoother.");                      yL += row_step;
		settings_toggle_tip("predict_hits",  [colL_x, yL], [colL_w, row_h], "Predict Hits",        "cl_predict_hits",    "Show hit feedback (hitmarker, blood, decals) instantly on local fire.");               yL += row_step;
		settings_toggle_tip("predict_breaks",[colL_x, yL], [colL_w, row_h], "Predict Breaks",      "cl_predict_breaks",  "Hide a func_breakable instantly when local damage is lethal.\nServer confirms or rolls back ~1 RTT later.");                          yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 0.1, 20], "cl_interp_time",      "Interp Time",         "%.3f", "Engine snapshot interpolation window. 0 = follow fastest snapshot.");                yL += row_step;
		settings_toggle_tip("trace_clip",    [colL_x, yL], [colL_w, row_h], "Trace Skip Clip",     "cl_weapontrace_ignore_playerclip", "CSQC weapon traces ignore playerclip brushes (decals on visible wall)."); yL += row_step;

		// --- Right column: Performance (7 widgets) + Phys-Drop (3 widgets) ---
		// sys_* cvars are CVAR_NOTFROMSERVER — QC's cvar_set silently
		// rejects them (PF_cvar_set in pr_bgcmd.c hard-checks the
		// flag). Use the localcmd-routed _lc variants instead so the
		// console parser actually applies the change.
		settings_section([colR_x, yR], colR_w, "Performance");                                                yR += hdr_step;
		settings_toggle_lc_tip("sys_hp",     [colR_x, yR], [colR_w, row_h], "High Process Priority","sys_highpriority",  "Bump OS scheduling priority of the game process.\nReduces frame-time jitter under load; uses more CPU.");                                 yR += row_step;
		settings_toggle_lc_tip("sys_cprec",  [colR_x, yR], [colR_w, row_h], "Clock Precision",     "sys_clockprecision","Request the Windows scheduler's high-resolution timer.\nLower wait jitter; mild battery / heat increase on laptops.");                yR += row_step;
		cvar_slider_lc_tip([colR_x, yR], [colR_w, row_h], [0, 3, 3],   "sys_clocktype",      "Clock Type",         "%.0f", "Timer source. 0=auto, 1=timeGetTime (low precision),\n2=QueryPerfCounter, 3=QPC + force-affinity (no drift).");                                yR += row_step;
		cvar_slider_lc_tip([colR_x, yR], [colR_w, row_h], [0, 3, 3],   "sys_framepacing",    "Frame Pacing",       "%.0f", "0=vanilla Sleep, 1=hi-res waitable timer, 2=+DXGI sync,\n3=+absolute-anchor pacing (best, default).");                                   yR += row_step;
		settings_toggle_tip("yieldcpu",   [colR_x, yR], [colR_w, row_h], "Yield CPU",           "cl_yieldcpu",       "Sleep between frames. Off = lowest input latency, higher CPU.");                          yR += row_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [30, 500, 47],"cl_maxfps",          "Max FPS",            "%.0f", "Render cap when game has focus.");                                                       yR += row_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [30, 500, 47],"cl_idlefps",         "Idle FPS",           "%.0f", "Render cap when game window is unfocused.");                                            yR += row_step;
		yR += 4;

		settings_section([colR_x, yR], colR_w, "Phys-Drop Smoothing");                                        yR += hdr_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0, 0.2, 40], "cl_physdrop_smooth_time","Smooth Time",      "%.3f", "Snap-decay time for ODE-physics dropped weapons (0 = off).");                          yR += row_step;
		settings_toggle_tip("pd_extrap",     [colR_x, yR], [colR_w, row_h], "PhysDrop Extrap",     "cl_physdrop_extrap",     "Extrapolate phys-drop linear velocity between samples.");                          yR += row_step;
		settings_toggle_tip("pd_angextrap",  [colR_x, yR], [colR_w, row_h], "PhysDrop Ang Extrap", "cl_physdrop_angextrap",  "Extrapolate phys-drop angular velocity between samples.");                         yR += row_step;
	}
	else if (settings_tab == 4)
	{
		// --- Voice tab ---
		// Two columns mirroring Graphics/Perf-Net: Capture on the left
		// (mic settings, codec, send mode), Playback + HUD on the right.
		// row_h/row_step/hdr_step + colL_x/colR_x/colL_w/colR_w/yL/yR
		// are reused from the Graphics tab branch above (QC has function-
		// scope locals — redeclaring with `float` would trip Q207).
		row_h    = 17;
		row_step = 19;
		hdr_step = 16;
		colL_x = xpos;
		colR_x = right_x;
		colL_w = left_width;
		colR_w = right_width;
		yL = ypos; yR = ypos;

		// --- Left column: Capture ---
		settings_section([colL_x, yL], colL_w, "Capture");                                                       yL += hdr_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 2, 2],         "cl_voip_send",        "Send Mode",          "%.0f", "0 = push-to-talk only (hold +voip key).\n1 = voice activation (open mic).\n2 = always send.");        yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 7, 7],         "cl_voip_codec",       "Codec",              "%.0f", "0=Speex11k 1=Raw 2=Opus 3=Speex8k\n4=Speex16k 5=Speex32k 6=PCMA 7=PCMU.\nOpus (2) recommended for best quality/perf.");      yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [6000, 32000, 26], "cl_voip_bitrate",     "Bitrate",            "%.0f", "Codec target bitrate.  24000 (24 kbps) is excellent for Opus.");          yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 10, 40],       "cl_voip_micamp",      "Mic Gain",           "%.1f", "Microphone amplification.  Raise if your mic is too quiet.");              yL += row_step;
		cvar_slider_tip([colL_x, yL], [colL_w, row_h], [0, 50, 50],       "cl_voip_vad_threshhold","VAD Threshold",    "%.0f", "Voice-activation level when Send Mode = 1.\nHigher = quieter sounds get filtered out.");                  yL += row_step;
		settings_toggle_tip("voip_test",  [colL_x, yL], [colL_w, row_h], "Mic Test (loopback)", "cl_voip_test",       "Hear your own captured audio locally without networking.\nUse to verify mic + gain are working.");           yL += row_step;

		// --- Right column: Playback + HUD ---
		settings_section([colR_x, yR], colR_w, "Playback");                                                       yR += hdr_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0, 2, 20],        "cl_voip_play",        "Receive Volume",     "%.2f", "Volume scaler for incoming voice (others' voices).");                       yR += row_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0, 1, 20],        "cl_voip_capturingvol","My Sidetone",        "%.2f", "Game audio scale while YOU are transmitting (so you can hear yourself / others over your own voice).");      yR += row_step;
		cvar_slider_tip([colR_x, yR], [colR_w, row_h], [0, 1, 20],        "cl_voip_ducking",     "Game Audio Duck",    "%.2f", "Game audio scale while someone is talking to you.\nLower = duck game more so voices stay audible.");        yR += row_step;
		settings_toggle_tip("voip_nf",  [colR_x, yR], [colR_w, row_h], "Noise Filter",          "cl_voip_noisefilter", "Speex noise cancellation.  Recommended on.");                              yR += row_step;
		settings_toggle_tip("voip_ag",  [colR_x, yR], [colR_w, row_h], "Auto Gain",             "cl_voip_autogain",    "Auto-normalize voice level.  Off recommended — interferes with VAD.");      yR += row_step;
		yR += 6;

		settings_section([colR_x, yR], colR_w, "HUD");                                                            yR += hdr_step;
		settings_toggle_tip("voip_hud", [colR_x, yR], [colR_w, row_h], "Show VoIP HUD",         "hud_voip_show",       "Mod's bottom-left widget: green '+VOIP' indicator while you're talking,\nspeaker list above showing other players who are currently transmitting.");      yR += row_step;
		settings_toggle_tip("voip_em",  [colR_x, yR], [colR_w, row_h], "Engine Volume Meter",   "cl_voip_showmeter",   "FTE's built-in mic volume meter.  Off by default — replaced by the HUD widget above.");      yR += row_step;
	}

	// --- Right panel: Controls (General) or Preview (Crosshair).
	// Graphics + Perf & Net tabs render their own right column inside
	// the tab branch above (two-column layout) and only need the
	// shared tooltip footer below.
	// Right column starts under the tab strip — same y as the left
	// column does after `ypos += 26` for tab strip clearance. Was 36
	// (legacy from when there was no tab strip), which made "Controls"
	// and "Preview" overlap the new tab buttons.
	if (settings_tab == 0)
	{
		ypos = 54;
		xpos = right_x;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Controls", MENU_TEXT_1, 1, 0);
		ypos += 16;
		// Bind list height shrunk so the helper text underneath
		// (and the Back button) still have clearance under the new
		// tab strip height.
		bind_list("bindlist", [xpos, ypos], [right_width, 200], binds_scroll);
		ypos += 200 + 8;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Click a binding to rebind.", MENU_TEXT_2, 0.85, 0);
		ypos += 10;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "ESC cancels, BACKSPACE clears.", MENU_TEXT_2, 0.85, 0);
	}
	else if (settings_tab == 1)
	{
		ypos = 54;
		xpos = right_x;
		float preview_size = min(right_width, 180);
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Preview", MENU_TEXT_1, 1, 0);
		ypos += 16;
		DrawCrosshairPreview([xpos, ypos], [preview_size, preview_size]);
		ypos += preview_size + 8;
		sui_text([xpos, ypos], MENU_TEXT_SMALL, "Changes save on Back / ESC.", MENU_TEXT_2, 0.85, 0);
	}

	// Tooltip footer — single line on the SAME row as the Back button
	// but offset to its right. Earlier version sat above the button
	// and clipped through it; the right-of-button placement leaves
	// the button visually clear and gives the description ~330 px of
	// width to render in. settings_tip_text was reset to "" at the
	// top of the tab strip and re-latched by any widget whose id
	// sui_is_hovered() matched this frame.
	if (settings_tab == 2 || settings_tab == 3 || settings_tab == 4)
	{
		// Tip strip sits to the RIGHT of the Back button (x = 96).
		// Multi-line tips: split on '\n' and stack two rows; the
		// 20-px button is just tall enough for two MENU_TEXT_SMALL
		// (8 px) lines stacked at 10 px spacing. tip_y was -1 px
		// from the previous version per user feedback.
		float tip_x = 8 + 80 + 6;          // 6 px gap right of button (was 8 — −2 left)
		float tip_y = size_y - 28 + 2;     // 2 px tighter to the top (was +4 — −2 up)
		string display = settings_tip_text;
		float  alpha   = 0.95;
		if (display == "")
		{
			display = "Hover an option for a description.";
			alpha   = 0.5;
		}

		// Split on the first '\n'. Two-line max — engine text widget
		// doesn't auto-wrap, and we only have ~2 lines of footer
		// height. Anything beyond '\n' goes on the second row.
		float nl = strstrofs(display, "\n", 0);
		if (nl >= 0)
		{
			string line1 = substring(display, 0, nl);
			string line2 = substring(display, nl + 1, -1);
			sui_text([tip_x, tip_y],     MENU_TEXT_SMALL, line1, MENU_TEXT_2, alpha, 0);
			sui_text([tip_x, tip_y + 9], MENU_TEXT_SMALL, line2, MENU_TEXT_2, alpha, 0);
		}
		else
		{
			sui_text([tip_x, tip_y], MENU_TEXT_SMALL, display, MENU_TEXT_2, alpha, 0);
		}
	}

	sui_set_align([SUI_ALIGN_START, SUI_ALIGN_END]);
	if (my_button("stg_back", [8, -8], [80, 20], "Back")) { Menu_SaveConfig(); current_menu = MENU_MAIN; }

	sui_set_default_kb_focus(settings_tab == 0 ? "sens_field" : "rgb_Red");

	if (sui_listen_back())
	{ Menu_SaveConfig(); current_menu = MENU_MAIN; }

	sui_pop_frame();
};
