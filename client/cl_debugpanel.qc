// ============================================================
//  client/cl_debugpanel.qc  -  F1 in-game debug & config panel
//
//  Floating CSQC overlay (F1 toggles) exposing Client and
//  Client-Debug cvars across two tabs. Models the server-browser
//  visual style (small native-font buttons, draggable title bar,
//  drop shadow, close X) but lives in CSQC so it's available during
//  active gameplay without forcing menu mode (which would freeze
//  the server).
//
//  Cursor takeover via setcursormode() — same pattern as the team
//  selection overlay (m_teamselect.qc).  Game physics keeps ticking
//  underneath; the player just can't shoot/look until they close
//  the panel.
//
//  Compiled for CSQC only via cl_progs.src.
// ============================================================

// --- Layout constants ---
const float DBG_KIND_TOGGLE  = 0;
const float DBG_KIND_SCALAR  = 1;
const float DBG_MAX_ENTRIES  = 64;

const float DBG_TAB_CLIENT       = 0;
const float DBG_TAB_CLIENT_DEBUG = 1;
const float DBG_TAB_COUNT        = 2;

const float DBG_TITLE_H      = 24;
const float DBG_TAB_STRIP_H  = 20;
const float DBG_ROW_H        = 18;
const float DBG_PAD          = 6;
const float DBG_GRIP_SIZE    = 12;
const float DBG_VBAR_W       = 8;

// Native 8x8 font cell — same value MENU_TEXT_SMALL resolves to
// in MenuQC.  Defined locally to avoid pulling MenuQC headers.
const vector DBG_FONT          = '8 8 0';

const vector DBG_BG            = '0.07 0.08 0.10';
const vector DBG_BG_DARKER     = '0.04 0.05 0.07';
const vector DBG_BORDER        = '0.30 0.30 0.35';
const vector DBG_TITLE_BG      = '0.05 0.06 0.08';
const vector DBG_HEADER_BG     = '0.10 0.11 0.13';
const vector DBG_BTN_OFF       = '0.18 0.18 0.20';
const vector DBG_BTN_OFF_BORD  = '0.30 0.30 0.35';
const vector DBG_BTN_ON        = '0.20 0.45 0.20';
const vector DBG_BTN_ON_BORD   = '0.35 0.65 0.35';
const vector DBG_BTN_CLOSE     = '0.40 0.15 0.15';
const vector DBG_BTN_CLOSE_BORD= '0.65 0.25 0.25';
const vector DBG_TEXT_1        = '0.95 0.95 0.95';
const vector DBG_TEXT_2        = '0.65 0.65 0.70';
const vector DBG_SHADOW        = '0 0 0';

// --- Cvar table (parallel arrays, populated once on first open) ---
string dbg_entry_label[DBG_MAX_ENTRIES];
string dbg_entry_cvar [DBG_MAX_ENTRIES];
float  dbg_entry_kind [DBG_MAX_ENTRIES];
float  dbg_entry_step [DBG_MAX_ENTRIES];
float  dbg_entry_tab  [DBG_MAX_ENTRIES];
float  dbg_entry_count;

// --- Single shared edit buffer ---
//
// Originally per-entry parallel arrays, but FTEQCC's __inout doesn't
// reliably write back to array slots — sui_text_input(... text, cursor)
// would mutate a copy and the user's typed chars vanished, leaving the
// box empty.  Switching to file-scope strings makes __inout work
// correctly (they're real lvalues) and naturally enforces "only one
// input is active at a time".
string dbg_edit_text;
float  dbg_edit_cursor;
// `var` so FTEQCC keeps it mutable — bare `float foo = -1;` at file
// scope is treated as const.
var float dbg_active_idx = -1;   // -1 when nothing is being edited

// --- Window state ---
float  dbg_panel_open;
float  dbg_panel_initialized;
vector dbg_panel_pos;
vector dbg_panel_size;
float  dbg_panel_dragging;
vector dbg_panel_drag_offset;
float  dbg_panel_resizing;
vector dbg_panel_resize_origin_size;
vector dbg_panel_resize_origin_cursor;
float  dbg_cursor_active;
vector dbg_panel_scroll_offset;
float  dbg_panel_current_tab;

// SUI's tracked cursor — read directly so drag math uses the same
// coordinate space SUI's hit-test does.
vector _cursor_position;

// =============================================================
//  Cvar table builders
// =============================================================
void(string label, string cvarname, float kind, float step, float tab) Debug_AddEntryEx =
{
    if (dbg_entry_count >= DBG_MAX_ENTRIES) return;
    dbg_entry_label[dbg_entry_count] = label;
    dbg_entry_cvar [dbg_entry_count] = cvarname;
    dbg_entry_kind [dbg_entry_count] = kind;
    dbg_entry_step [dbg_entry_count] = step;
    dbg_entry_tab  [dbg_entry_count] = tab;
    dbg_entry_count = dbg_entry_count + 1;
};

void(string cvarname, float tab) Debug_AddToggle =
{
    Debug_AddEntryEx(cvarname, cvarname, DBG_KIND_TOGGLE, 0, tab);
};

void(string cvarname, float step, float tab) Debug_AddScalar =
{
    Debug_AddEntryEx(cvarname, cvarname, DBG_KIND_SCALAR, step, tab);
};

void() Debug_PanelInit =
{
    if (dbg_panel_initialized) return;
    dbg_panel_initialized = 1;
    dbg_panel_size = '208 360 0';
    dbg_panel_pos  = '64 64 0';
    dbg_panel_current_tab = DBG_TAB_CLIENT;
    // Explicit init — FTEQCC's `var float foo = -1;` initializer at
    // file scope can be unreliable across module loads, and a value
    // of 0 would falsely match the first row's index in was_active
    // checks (rows 0+ would all read as "already active").
    dbg_active_idx = -1;

    // ---------- Client ----------
    Debug_AddToggle("cl_autohop",               DBG_TAB_CLIENT);
    Debug_AddToggle("cl_hitmarker",             DBG_TAB_CLIENT);
    Debug_AddToggle("cl_speedometer",           DBG_TAB_CLIENT);
    Debug_AddToggle("cl_predict_hits",          DBG_TAB_CLIENT);
    Debug_AddToggle("cl_extrap",                DBG_TAB_CLIENT);
    Debug_AddToggle("cl_extrap_grounded",       DBG_TAB_CLIENT);
    Debug_AddToggle("cl_extrap_smooth",         DBG_TAB_CLIENT);
    Debug_AddToggle("cl_driftlock",          DBG_TAB_CLIENT);
    Debug_AddScalar("cl_extrap_smooth_time", 0.001, DBG_TAB_CLIENT);
    Debug_AddScalar("cl_interp_time",        0.001, DBG_TAB_CLIENT);
    Debug_AddToggle("cl_teamcolours",           DBG_TAB_CLIENT);
    Debug_AddToggle("net_graph",                DBG_TAB_CLIENT);

    // ---------- Client Debug ----------
    Debug_AddToggle("cl_debug_impacts",      DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_hitboxes",     DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_hbexpand",     DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_physprops",    DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_net",          DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_bandwidth",    DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_weapon",       DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_move",         DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_game",         DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_playermodel",  DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_smoothing",    DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_footsteps",    DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_extrap",       DBG_TAB_CLIENT_DEBUG);
    Debug_AddToggle("cl_debug_drift",        DBG_TAB_CLIENT_DEBUG);
};

// =============================================================
//  Helpers
// =============================================================

// Set a cvar via localcmd so the engine's normal write path runs
// (callbacks fire, archive flag is honoured).
void(string name, float v) Debug_SetFloat =
{
    localcmd(sprintf("%s %g\n", name, v));
};

// Commit the in-progress edit buffer to its cvar.  stof of an
// empty / non-numeric string returns 0, which is sane for these
// fields.  Caller is responsible for clearing dbg_active_idx.
void(float idx) Debug_CommitEdit =
{
    if (idx < 0 || idx >= DBG_MAX_ENTRIES) return;
    Debug_SetFloat(dbg_entry_cvar[idx], stof(dbg_edit_text));
};

// Reusable button.  Same shape as menu/m_menu.qc:my_button_colored
// but local so we don't depend on MenuQC.  Returns 1 on click.
float(string id, vector pos, vector size, string label,
      vector col, vector border) Debug_Button =
{
    sui_push_frame(pos, size);
    vector basecolor;
    if (sui_is_held(id))
        basecolor = col - '0.05 0.05 0.05';
    else if (sui_is_hovered(id))
        basecolor = col + '0.08 0.08 0.08';
    else
        basecolor = col;

    sui_fill([0, 0], size, basecolor, 0.92, 0);
    sui_border_box([0, 0], size, 1, border, 1, 0);
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
    sui_text([0, 1], DBG_FONT, label, DBG_TEXT_1, 1, 0);
    sui_action_element([0, 0], size, id, sui_noop);
    sui_pop_frame();
    return sui_is_clicked(id);
};

// =============================================================
//  Toggle / open / close
// =============================================================

float() Debug_PanelOpen = { return dbg_panel_open; };

void() Debug_PanelToggle =
{
    Debug_PanelInit();
    dbg_panel_open = !dbg_panel_open;

    if (dbg_panel_open && !dbg_cursor_active)
    {
        // Cursor takeover — same idiom as team_menu_cursor_active
        // in m_teamselect.qc.  Game keeps ticking underneath.
        setcursormode(TRUE, "gfx/xhair", '16 16 0', cvar("vid_conautoscale"));
        dbg_cursor_active = 1;
    }
    else if (!dbg_panel_open && dbg_cursor_active)
    {
        // Panel closing — commit any in-progress scalar edit so the
        // user's typing isn't lost when they F1 / Esc out mid-edit.
        if (dbg_active_idx >= 0)
        {
            Debug_CommitEdit(dbg_active_idx);
            dbg_active_idx = -1;
        }
        setcursormode(FALSE);
        dbg_cursor_active = 0;
    }
};

float(float evtype, float scanx, float chary, float devid) Debug_PanelInputEvent =
{
    if (!dbg_panel_open) return FALSE;

    // F1 closes from inside the panel (same key that opens it).
    if (evtype == IE_KEYDOWN && scanx == K_F1)
    {
        Debug_PanelToggle();
        return TRUE;
    }
    // ESC also closes — universal exit shortcut.
    if (evtype == IE_KEYDOWN && scanx == K_ESCAPE)
    {
        Debug_PanelToggle();
        return TRUE;
    }

    // Diagnostic — toggle `cl_debug_panelinput 1` to trace key events
    // reaching the panel.  Useful if typing into a scalar field looks
    // like it's not being received: this confirms whether
    // sui_input_event is being called with the right scan/char.
    if (evtype == IE_KEYDOWN && cvar("cl_debug_panelinput"))
    {
        dprint(sprintf("[panelinput] KEYDOWN scan=%g char=%g active_idx=%g\n",
            scanx, chary, dbg_active_idx));
    }

    // Forward everything else into SUI so buttons / scrollbar / wheel
    // receive their events.  Returning TRUE absorbs the input so it
    // doesn't leak into gameplay handlers.
    sui_input_event(evtype, scanx, chary, devid);
    return TRUE;
};

// =============================================================
//  Title bar — drag region + close
// =============================================================
void() Debug_DrawTitleBar =
{
    sui_push_frame([0, 0], [dbg_panel_size_x, DBG_TITLE_H]);

    sui_fill([0, 0], [dbg_panel_size_x, DBG_TITLE_H], DBG_TITLE_BG, 1, 0);
    sui_fill([0, DBG_TITLE_H - 1], [dbg_panel_size_x, 1], DBG_BORDER, 1, 0);

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_text([8, 9], DBG_FONT, "Debug Panel", DBG_TEXT_1, 1, 0);

    float close_w = DBG_TITLE_H;

    // Drag region first (covers most of the bar).  Close button
    // registered AFTER takes precedence at the top-right corner.
    sui_action_element([0, 0],
        [dbg_panel_size_x - close_w, DBG_TITLE_H],
        "dbg_titlebar", sui_noop);

    if (Debug_Button("dbg_close",
        [dbg_panel_size_x - close_w, 0],
        [close_w, DBG_TITLE_H],
        "X", DBG_BTN_CLOSE, DBG_BTN_CLOSE_BORD))
    {
        Debug_PanelToggle();
    }

    sui_pop_frame();
};

void() Debug_HandleDrag =
{
    float held = sui_is_held("dbg_titlebar");

    if (held && !dbg_panel_dragging)
    {
        dbg_panel_dragging = 1;
        dbg_panel_drag_offset_x = _cursor_position_x - dbg_panel_pos_x;
        dbg_panel_drag_offset_y = _cursor_position_y - dbg_panel_pos_y;
    }

    if (held && dbg_panel_dragging)
    {
        dbg_panel_pos_x = _cursor_position_x - dbg_panel_drag_offset_x;
        dbg_panel_pos_y = _cursor_position_y - dbg_panel_drag_offset_y;

        // Keep at least 80 px of title bar on-screen.  g_width /
        // g_height are CSQC's per-frame screen dimensions set at the
        // top of CSQC_UpdateView.
        if (dbg_panel_pos_x < -dbg_panel_size_x + 80)
            dbg_panel_pos_x = -dbg_panel_size_x + 80;
        if (dbg_panel_pos_x > g_width - 80)
            dbg_panel_pos_x = g_width - 80;
        if (dbg_panel_pos_y < 0)
            dbg_panel_pos_y = 0;
        if (dbg_panel_pos_y > g_height - DBG_TITLE_H)
            dbg_panel_pos_y = g_height - DBG_TITLE_H;
    }

    if (!held)
        dbg_panel_dragging = 0;
};

// =============================================================
//  Tab strip
// =============================================================
void(string label, float tab_id, float x, float w) Debug_DrawOneTab =
{
    string id = sprintf("dbg_tab_%g", tab_id);
    vector col, bord;
    if (dbg_panel_current_tab == tab_id)
    {
        col  = DBG_BTN_ON;
        bord = DBG_BTN_ON_BORD;
    }
    else
    {
        col  = DBG_BTN_OFF;
        bord = DBG_BTN_OFF_BORD;
    }

    if (Debug_Button(id, [x, 3], [w, DBG_TAB_STRIP_H - 6], label, col, bord))
    {
        if (dbg_panel_current_tab != tab_id)
        {
            if (dbg_active_idx >= 0)
            {
                Debug_CommitEdit(dbg_active_idx);
                dbg_active_idx = -1;
            }
            dbg_panel_current_tab = tab_id;
            dbg_panel_scroll_offset = '0 0 0';
        }
    }
};

void() Debug_DrawTabStrip =
{
    float y0 = DBG_TITLE_H;
    sui_push_frame([0, y0], [dbg_panel_size_x, DBG_TAB_STRIP_H]);
    sui_fill([0, 0], [dbg_panel_size_x, DBG_TAB_STRIP_H], DBG_TITLE_BG, 1, 0);
    sui_fill([0, DBG_TAB_STRIP_H - 1], [dbg_panel_size_x, 1], DBG_BORDER, 1, 0);

    float gap = 2;
    float total_inset = DBG_PAD * 2;
    float available = dbg_panel_size_x - total_inset - gap * (DBG_TAB_COUNT - 1);
    float tab_w = floor(available / DBG_TAB_COUNT);
    if (tab_w < 96) tab_w = 96;

    float x = DBG_PAD;
    Debug_DrawOneTab("Client", DBG_TAB_CLIENT, x, tab_w); x += tab_w + gap;
    Debug_DrawOneTab("Client Debug", DBG_TAB_CLIENT_DEBUG, x, tab_w);

    sui_pop_frame();
};

// =============================================================
//  Bottom bar — mirrors the title bar styling and contains the
//  resize grip.  Previously the grip drew its own stand-alone
//  border which clashed with the panel's outer border (looked like
//  a duplicate outline pinned to the corner).  Wrapping it inside
//  a themed strip makes the whole bottom edge of the window look
//  like a cohesive footer.
// =============================================================
void() Debug_DrawBottomBar =
{
    float by = dbg_panel_size_y - DBG_GRIP_SIZE;

    sui_push_frame([0, by], [dbg_panel_size_x, DBG_GRIP_SIZE]);

    // Solid bottom strip in the same colour as the title bar, plus
    // a 1 px separator line above it (mirrors the title bar's lower
    // separator at DBG_TITLE_H - 1).
    sui_fill([0, 0], [dbg_panel_size_x, DBG_GRIP_SIZE], DBG_TITLE_BG, 1, 0);
    sui_fill([0, 0], [dbg_panel_size_x, 1], DBG_BORDER, 1, 0);

    // Resize grip — three diagonal hatch ticks at the bottom-right.
    // No own border; the panel's outer border draws the right + bottom
    // edges already, and the bottom-bar separator handles the top edge.
    float gx = dbg_panel_size_x - DBG_GRIP_SIZE;
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    // Subtle highlight on hover so the grip is discoverable.
    if (sui_is_hovered("dbg_resize"))
        sui_fill([gx, 0], [DBG_GRIP_SIZE, DBG_GRIP_SIZE],
                 '0.18 0.18 0.20', 0.5, 0);

    float i;
    for (i = 2; i < DBG_GRIP_SIZE; i = i + 3)
    {
        sui_fill([gx + DBG_GRIP_SIZE - i - 1, i], [i + 1, 1],
                 DBG_TEXT_2, 0.7, 0);
    }

    sui_action_element([gx, 0], [DBG_GRIP_SIZE, DBG_GRIP_SIZE],
        "dbg_resize", sui_noop);

    sui_pop_frame();
};

void() Debug_HandleResize =
{
    float held = sui_is_held("dbg_resize");

    if (held && !dbg_panel_resizing)
    {
        dbg_panel_resizing = 1;
        dbg_panel_resize_origin_size   = dbg_panel_size;
        dbg_panel_resize_origin_cursor = _cursor_position;
    }

    if (held && dbg_panel_resizing)
    {
        dbg_panel_size_x = dbg_panel_resize_origin_size_x
            + (_cursor_position_x - dbg_panel_resize_origin_cursor_x);
        dbg_panel_size_y = dbg_panel_resize_origin_size_y
            + (_cursor_position_y - dbg_panel_resize_origin_cursor_y);

        // Clamp.  Min ensures the title + a couple of rows are always
        // visible; max keeps the window on a 640x480 screen.
        // Min width matches the two-tab layout: narrow enough to feel
        // collapsed, but still wide enough for the "Client Debug" tab.
        if (dbg_panel_size_x < 208) dbg_panel_size_x = 208;
        if (dbg_panel_size_y < 200) dbg_panel_size_y = 200;
        if (dbg_panel_size_x > 640) dbg_panel_size_x = 640;
        if (dbg_panel_size_y > 600) dbg_panel_size_y = 600;
    }

    if (!held)
        dbg_panel_resizing = 0;
};

// =============================================================
//  Body — scrollable list of cvar rows filtered by current tab
// =============================================================
void() Debug_DrawBody =
{
    float body_y0 = DBG_TITLE_H + DBG_TAB_STRIP_H;
    float body_h  = dbg_panel_size_y - body_y0 - DBG_GRIP_SIZE;
    float body_w  = dbg_panel_size_x;

    sui_push_frame([0, body_y0], [body_w, body_h]);
    sui_fill([0, 0], [body_w, body_h], DBG_BG_DARKER, 1, 0);

    // Compute total content height for the active tab only.
    float content_h = 0;
    float i;
    for (i = 0; i < dbg_entry_count; i = i + 1)
    {
        if (dbg_entry_tab[i] == dbg_panel_current_tab)
            content_h = content_h + DBG_ROW_H;
    }

    sui_scroll_view_begin("dbg_body_scroll",
        [0, 0],
        [body_w, body_h],
        [body_w - DBG_VBAR_W, content_h],
        dbg_panel_scroll_offset,
        [0, DBG_VBAR_W]);

    float row_w = body_w - DBG_VBAR_W - DBG_PAD * 2;
    float y     = 0;

    // Cull rows outside the viewport so we don't blow MAX_ACTION_ELEMENTS.
    float vp_top    = dbg_panel_scroll_offset_y - DBG_ROW_H;
    float vp_bottom = dbg_panel_scroll_offset_y + body_h + DBG_ROW_H;

    for (i = 0; i < dbg_entry_count; i = i + 1)
    {
        if (dbg_entry_tab[i] != dbg_panel_current_tab)
            continue;

        float kind  = dbg_entry_kind[i];
        float row_h = DBG_ROW_H;
        float row_y = y;

        if (row_y + row_h < vp_top || row_y > vp_bottom)
        {
            y = y + row_h;
            continue;
        }

        // Reset alignment at the top of every iteration so previous
        // rows' transient align changes don't leak into this row's
        // fills. Toggle bg and input bg both use sui_fill, which
        // honours the parent frame's alignment.
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

        if (kind == DBG_KIND_TOGGLE)
        {
            string cn  = dbg_entry_cvar[i];
            float  v   = cvar(cn);
            string lab = sprintf("%s : %s", dbg_entry_label[i],
                                  v ? "On" : "Off");
            vector col   = v ? DBG_BTN_ON       : DBG_BTN_OFF;
            vector bord  = v ? DBG_BTN_ON_BORD  : DBG_BTN_OFF_BORD;
            string id    = sprintf("dbg_t_%s", cn);

            if (Debug_Button(id,
                [DBG_PAD, row_y + 1],
                [row_w, row_h - 2],
                lab, col, bord))
            {
                Debug_SetFloat(cn, v ? 0 : 1);
            }
        }
        else // DBG_KIND_SCALAR — clickable text input for free-form numeric edit.
        {
            string sc_cn = dbg_entry_cvar[i];

            float input_w = floor(row_w * 0.5);
            float lbl_w   = row_w - input_w;

            sui_text([DBG_PAD + 4, row_y + 6], DBG_FONT,
                     dbg_entry_label[i], DBG_TEXT_2, 1, 0);

            string id_input = sprintf("dbg_s_%s", sc_cn);
            float input_x = DBG_PAD + lbl_w;
            float input_h = row_h - 2;

            sui_push_frame([input_x, row_y + 1], [input_w, input_h]);

            // Background + border (uses pre-call active state — colour
            // may flicker on the click frame but corrects next frame).
            float was_active = (dbg_active_idx == i);
            vector inp_bg   = was_active ? '0.15 0.16 0.18' : DBG_HEADER_BG;
            vector inp_bord = was_active ? '0.45 0.50 0.55' : DBG_BORDER;
            sui_fill([0, 0], [input_w, input_h], inp_bg, 0.85, 0);
            sui_border_box([0, 0], [input_w, input_h], 1, inp_bord, 1, 0);

            // ALWAYS call sui_text_input with the global buffer.
            // The earlier dummy-buffer-when-unfocused branch had a
            // race: now_focused was queried BEFORE the action_element
            // was registered this frame, so on the first click the
            // dummy branch ran and the buffer never received the
            // user's typed chars.  sui_text_input only mutates the
            // buffer when its own internal sui_is_last_clicked check
            // passes, so passing the global is safe — non-focused
            // calls are no-ops for the buffer.
            //
            // Why: sui_scroll_view_begin drains the entire input
            // buffer (sui_get_input) when the scroll view is hovered,
            // so it can convert mousewheel events into scroll.  After
            // that drain, _input_index sits at end-of-buffer, and
            // sui_text_input's own get-input loop reads nothing.
            // Without this reset, typing only worked when the cursor
            // was OFF the panel (no hover → no drain).
            sui_reread_input();
            sui_text_input(id_input, [3, 0], [input_w - 6, input_h],
                dbg_edit_text, dbg_edit_cursor);
            sui_cap_input_length(12, dbg_edit_text, dbg_edit_cursor);

            // NOW query focus — sui_text_input has just registered the
            // action_element so last_clicked reflects this frame.
            float now_focused = sui_is_last_clicked(id_input);

            if (now_focused && !was_active)
            {
                // Just gained focus.  Commit any prior, load this one.
                if (dbg_active_idx >= 0)
                    Debug_CommitEdit(dbg_active_idx);
                dbg_active_idx  = i;
                dbg_edit_text   = ftos(cvar(sc_cn));
                dbg_edit_cursor = strlen(dbg_edit_text);
            }
            else if (!now_focused && was_active)
            {
                // Lost focus → commit.
                Debug_CommitEdit(i);
                dbg_active_idx = -1;
            }

            // Render text — buffer if this row is the active edit,
            // live cvar value otherwise.  Use `dbg_active_idx == i`
            // (not now_focused) so the text we render matches what's
            // actually in dbg_edit_text after the transition logic.
            sui_set_align([SUI_ALIGN_START, SUI_ALIGN_CENTER]);
            string display_text;
            if (dbg_active_idx == i)
                display_text = dbg_edit_text;
            else
                display_text = ftos(cvar(sc_cn));
            sui_text([3, 1], DBG_FONT, display_text,
                     DBG_TEXT_1, 1, 0);

            // Blinking caret.  Reset align to START so the previous
            // CENTER-on-y from sui_text doesn't shift the caret 50%
            // down the row (sui_set_align mutates the parent frame's
            // align, and the caret sui_fill picks it up).
            if (dbg_active_idx == i)
            {
                sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
                float cursorx = stringwidth(
                    substring(dbg_edit_text, 0, dbg_edit_cursor),
                    1, DBG_FONT);
                sui_fill([3 + cursorx, 4], [1, 8],
                         DBG_TEXT_1, fabs(sin(time * 4)), 0);
            }

            sui_pop_frame();
        }

        y = y + row_h;
    }

    sui_scroll_view_end();
    sui_pop_frame();
};

// =============================================================
//  Main draw — called from CSQC_UpdateView inside sui_begin/end.
// =============================================================
void() Debug_PanelDraw =
{
    if (!dbg_panel_open) return;
    Debug_PanelInit();

    // Drop shadow first — drawn in screen space BEFORE the window
    // frame is pushed so it sits behind the panel.
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_fill([dbg_panel_pos_x + 3, dbg_panel_pos_y + 3],
             dbg_panel_size, DBG_SHADOW, 0.45, 0);

    // Clamp window so it can't drift off-screen between frames
    // (e.g. after a resize that left it past the right edge).
    if (dbg_panel_pos_x > g_width - 80)
        dbg_panel_pos_x = g_width - 80;
    if (dbg_panel_pos_y > g_height - DBG_TITLE_H)
        dbg_panel_pos_y = g_height - DBG_TITLE_H;

    sui_push_frame(dbg_panel_pos, dbg_panel_size);

    sui_fill([0, 0], dbg_panel_size, DBG_BG, 0.94, 0);
    sui_border_box([0, 0], dbg_panel_size, 2, DBG_BORDER, 1, 0);

    Debug_DrawTitleBar();
    Debug_DrawTabStrip();
    Debug_DrawBody();
    Debug_DrawBottomBar();

    Debug_HandleDrag();
    Debug_HandleResize();

    sui_pop_frame();
};
