// ============================================================
//  menu/m_serverbrowser.qc  -  Floating server-browser window
//
//  Top-level menu page (MENU_SERVER_BROWSER) listing nettest +
//  vanilla QW servers from FTE's master-server hostcache.
//
//  Window is draggable (title bar click-and-drag) with a close
//  button (top-right), tab strip (`All` / `Favourites` — Favourites
//  stubbed for v1), six columns (Name, Mode, Players, Map, Ping,
//  Address), and Refresh + Connect buttons.
//
//  Coordinate space: root_menu sets ALIGN_CENTER+CENTER before
//  calling page handlers, so a child push_frame at e.g. (320, 80)
//  is interpreted as offset from screen center — that throws hit-
//  test regions off-screen.  We force ALIGN_START+START at entry
//  and let sb_window_pos be a top-left absolute screen coordinate.
//
//  Drag uses SUI's tracked _cursor_position (sui_sys.qc:184)
//  directly — sui_action_element transforms hit-test regions
//  through the frame stack and tests against _cursor_position, so
//  reading the same global gives matching coordinate space.
// ============================================================

// --- Window state ---
// FTEQCC folds initialised file-scope numerics into constants, so
// these stay un-initialised at file scope and get seeded at first
// draw via the sb_initialized one-shot.
vector sb_window_pos;
vector sb_window_size;

// Drag state.
float  sb_dragging;
vector sb_drag_offset;

// Screen size in SUI logical pixels — captured each frame BEFORE we
// push the window's frame, because sui_current_frame_size() returns
// the size of the CURRENT frame on the stack.  Once the window frame
// is pushed, that call would return the window's size (480 px), not
// the screen — which broke drag clamping (could drag far past the
// left edge, but only halfway from the right).
vector sb_screen_size;

// Tab + selection.
const float SB_TAB_ALL = 0;
const float SB_TAB_FAV = 1;
const float SB_TAB_LAN = 2;
float sb_current_tab;          // SB_TAB_*
float sb_selected_idx;         // hostcache row, -1 = none

// Scroll offset, fed __inout to sui_scroll_view_begin.  Vector form
// because the SUI API tracks both axes; only Y is meaningful here.
vector sb_scroll_offset;

// Sort state — column to sort by, ascending or descending.  Updated
// by clicks on the header row; consumed by sethostcachesort each
// refresh and on every header click.
float  sb_sort_field;
float  sb_sort_descending;
float  sb_sort_initialized;

// Refresh rate-limit + first-open hook.
float sb_last_refresh_time;
float sb_initialized;

// Live-resort timestamp.  FTE's CL_ReadServerInfo (net_master.c:3404)
// marks servers SRVSTATUS_ALIVE as their status replies arrive but
// does NOT call Master_ResortServer — so the cached numvisibleservers
// (which gethostcachevalue(SLIST_HOSTCACHEVIEWCOUNT) returns) goes
// stale during the 5-10 s after a refresh while replies trickle in.
// Calling resorthostcache() periodically while the browser is open
// keeps the view count and visible row list current.
float sb_last_resort_time;
// One-shot guard for ServerBrowser_EnsureMasters — net_qwmasterN cvars
// are CVAR_NOSAVE in FTE so we re-set them once per session.
float sb_masters_set;

// Cached field indices — gethostcacheindexforkey is cheap but resolving
// once on first list-build keeps the per-cell cost a single global read.
float sb_idx_resolved;
float sb_idx_name;
float sb_idx_ping;
float sb_idx_map;
float sb_idx_cname;
float sb_idx_numhumans;
float sb_idx_maxplayers;
float sb_idx_gamemode;
float sb_idx_modname;

// Layout constants.
const float SB_TITLE_H        = 28;
const float SB_TAB_H          = 24;
const float SB_COL_HEADER_H   = 20;
const float SB_ROW_H          = 20;
const float SB_BUTTON_ROW_H   = 36;
const float SB_PAD            = 8;

// Column budget — must sum to 464 (window 480 minus 8 px on each side).
// MAP sits with a 5 px gap before PING (Map shifted 5 left into
// Players' right edge per user request).
//
// Per cell, sb_cell_text insets text by 4 px on each side (8 px total),
// so usable chars per cell = (W - 8) / 8 at the native 8x8 font.  Each
// header below is sized to fit its label AND a representative worst-
// case datum without truncation.
//
//   Col       X    W    usable chars    header           data
//   NAME      8  208      25            "Name"  (4)      "192.168.1.100:27500" (19)
//   MODE    216   48       5            "Mode"  (4)      "Bhop"  (4)
//   PLAYERS 264   59       6            "Player" (6)*    "100/100" (7)*
//   MAP     323  104      12            "Map"   (3)      "bloodassault" (12)
//   (5 px visual gap — accepted trade for the requested Map shift)
//   PING    432   40       4            "Ping"  (4)      "999"   (3)
//                                                        sum = 464
//
// *PLAYERS at 59 px clips "Players" header to "Player" and "100/100"
// data to "100/10" in the rare full-server case.  Lower-priority info
// than Map names so accepted.
const float SB_COL_NAME_X      = 8;
const float SB_COL_NAME_W      = 208;
const float SB_COL_MODE_X      = 216;
const float SB_COL_MODE_W      = 48;
const float SB_COL_PLAYERS_X   = 264;
const float SB_COL_PLAYERS_W   = 59;
const float SB_COL_MAP_X       = 323;
const float SB_COL_MAP_W       = 104;
const float SB_COL_PING_X      = 432;
const float SB_COL_PING_W      = 40;

// Forward — SUI's tracked cursor position (sui_sys.qc).  We read it
// directly so the drag math uses the same coordinate space SUI's
// hit-test does, avoiding the IE_MOUSEABS / vid_conautoscale mismatch
// that a manual mirror through Menu_InputEvent would introduce.
vector _cursor_position;
float() sui_click_held;

// =============================================================
//  Hostcache helpers
// =============================================================
void() ServerBrowser_ResolveIndices =
{
    if (sb_idx_resolved) return;
    sb_idx_resolved   = 1;

    // Tell the engine to include each key in per-server status queries.
    // FTE only fetches keys that were registered with addwantedhostcachekey
    // — without these, custom serverinfo keys (sv_gamemode, modname) come
    // back empty even on servers that publish them.  Standard keys (name,
    // ping, map, cname, numhumans, maxplayers) are usually fetched by
    // default but registering them is harmless and explicit.
    addwantedhostcachekey("name");
    addwantedhostcachekey("hostname");
    addwantedhostcachekey("ping");
    addwantedhostcachekey("map");
    addwantedhostcachekey("mapname");
    addwantedhostcachekey("cname");
    addwantedhostcachekey("numhumans");
    addwantedhostcachekey("numplayers");
    addwantedhostcachekey("maxplayers");
    addwantedhostcachekey("sv_maxclients");
    addwantedhostcachekey("maxclients");
    addwantedhostcachekey("sv_gamemode");
    addwantedhostcachekey("modname");
    addwantedhostcachekey("gamedir");
    // Raw serverinfo blob — pulled into the cache so the diagnostic
    // print (Ctrl+click a row, see ServerBrowser_DumpRow) can show the
    // exact reply the server sent.  Useful when fields appear empty.
    addwantedhostcachekey("serverinfo");
    addwantedhostcachekey("qcstatus");

    sb_idx_name       = gethostcacheindexforkey("name");
    sb_idx_ping       = gethostcacheindexforkey("ping");
    sb_idx_map        = gethostcacheindexforkey("map");
    sb_idx_cname      = gethostcacheindexforkey("cname");
    sb_idx_numhumans  = gethostcacheindexforkey("numhumans");
    sb_idx_maxplayers = gethostcacheindexforkey("maxplayers");
    sb_idx_gamemode   = gethostcacheindexforkey("sv_gamemode");
    sb_idx_modname    = gethostcacheindexforkey("modname");

    // Some QW servers report player count under "numplayers" instead of
    // "numhumans" (FTE's internal naming for the same stat).  Fall back
    // when the canonical key isn't present in the response.
    if (sb_idx_numhumans < 0)
        sb_idx_numhumans = gethostcacheindexforkey("numplayers");
};

string(float row) sb_map_name  = { return gethostcachestring(sb_idx_map,        row); };
string(float row) sb_cname_str = { return gethostcachestring(sb_idx_cname,      row); };
string(float row) sb_modname   = { return gethostcachestring(sb_idx_modname,    row); };
float (float row) sb_ping_raw  = { return gethostcachenumber(sb_idx_ping,       row); };
float (float row) sb_humans    = { return gethostcachenumber(sb_idx_numhumans,  row); };
float (float row) sb_maxp      = { return gethostcachenumber(sb_idx_maxplayers, row); };

// Name fallback — when a server's status reply has no `hostname` key
// (some QW servers don't bother setting it), FTE leaves info->name as
// the placeholder "<address> ?".  We prefer to show the address
// directly so the row isn't a duplicate of the ADDR column.
string(float row) sb_name =
{
    string n = gethostcachestring(sb_idx_name, row);
    string c = gethostcachestring(sb_idx_cname, row);
    if (n == "" || n == strcat(c, " ?"))
        return c;
    return n;
};

// Ping / players display strings.  PING_DEAD = 0xffff = 65535 marks a
// server that hasn't completed its follow-up status query yet — show
// "?" rather than a 5-digit number that overflows the column.
// Likewise maxplayers == 0 means the server didn't publish maxclients.
//
// Strings rendered here MUST be ASCII (codepoints 0-127).  Quake's
// stock font lacks Unicode glyphs, so a `—` (U+2014) gets emitted as
// its 3 UTF-8 bytes and the font draws each byte as a separate glyph
// — coming out as random characters on screen.
string(float row) sb_ping_str =
{
    float p = sb_ping_raw(row);
    if (p >= 999) return "?";
    return sprintf("%g", p);
};

string(float row) sb_players_str =
{
    float maxp = sb_maxp(row);
    if (maxp <= 0) return "?";
    return sprintf("%g/%g", sb_humans(row), maxp);
};

string(float row) sb_gamemode_str =
{
    string raw = gethostcachestring(sb_idx_gamemode, row);
    if (raw == "") return "?";
    float gm = stof(raw);
    if (gm == 0) return "TDM";
    if (gm == 1) return "Elim";
    if (gm == 2) return "Bhop";
    if (gm == 3) return "FFA";
    if (gm == 4) return "Paint";
    return raw;
};

// Diagnostic dump — prints every queryable hostcache field for one
// row to the console.  Called from the row-select handler the FIRST
// time a row is selected per session, so the user can compare what
// arrived vs. what should have arrived if a server is showing all "?"
// fields.  An empty value below means the server's status reply did
// not include that key — likely a server-config issue (hostname cvar
// unset, status query firing before svs.info is populated, custom
// build with truncated reply, etc.) rather than a client bug.
void(float row) ServerBrowser_DumpRow =
{
    print("[serverbrowser] --- row ", ftos(row), " ---\n");
    print("  cname        : '", gethostcachestring(sb_idx_cname,      row), "'\n");
    print("  name         : '", gethostcachestring(sb_idx_name,       row), "'\n");
    print("  ping         : '", ftos(gethostcachenumber(sb_idx_ping,  row)), "'\n");
    print("  map          : '", gethostcachestring(sb_idx_map,        row), "'\n");
    print("  numhumans    : '", ftos(gethostcachenumber(sb_idx_numhumans,  row)), "'\n");
    print("  maxplayers   : '", ftos(gethostcachenumber(sb_idx_maxplayers, row)), "'\n");
    print("  modname      : '", gethostcachestring(sb_idx_modname,    row), "'\n");
    print("  sv_gamemode  : '", gethostcachestring(sb_idx_gamemode,   row), "'\n");
    // Raw serverinfo blob shows the exact key=value pairs the server
    // sent.  If this is empty the server isn't publishing anything;
    // if it's non-empty but missing hostname, the server's hostname
    // cvar isn't reaching svs.info.
    float idx_serverinfo = gethostcacheindexforkey("serverinfo");
    float idx_qcstatus   = gethostcacheindexforkey("qcstatus");
    if (idx_serverinfo >= 0)
        print("  serverinfo   : '", gethostcachestring(idx_serverinfo, row), "'\n");
    if (idx_qcstatus >= 0)
        print("  qcstatus     : '", gethostcachestring(idx_qcstatus,   row), "'\n");
};

// Restore ezQuake/nQuake-equivalent QW master coverage.  FTE's
// compiled-in QW master list is sparse and currently the only two
// non-empty entries (master.quakeservers.net, qwmaster.fodquake.net)
// don't reliably reply.  master.quakeworld.nu is the busy public
// master that ezQuake / nQuake clients use; setting net_qwmaster1 to
// it puts a working master in the rotation.  These cvars are
// CVAR_NOSAVE so we re-set them once per session.
//
// Use cvar_set (synchronous) instead of localcmd (queued through
// Cbuf) — localcmd would only apply AFTER this menu function returns,
// so the very next refreshhostcache() call would still see empty
// masters and hit nothing.  cvar_set writes the cvar immediately.
void() ServerBrowser_EnsureMasters =
{
    if (sb_masters_set) return;
    sb_masters_set = 1;
    cvar_set("net_qwmaster1", "master.quakeworld.nu:27000");
    cvar_set("net_qwmaster2", "master.quakeservers.net:27000");
    cvar_set("net_qwmaster3", "qwmaster.fodquake.net:27000");
};

// Diagnostic — print every visible row's cname / hostname / islocal
// flag to the console.  Used to investigate the LAN-tab "shows wrong
// details" report: the user runs this, drops console (~), and we
// compare against what they see in the table.  If the dump shows
// rows with empty hostname (broadcast-only entries awaiting follow-
// up status) those will populate over the next 1-3 s.  If the dump
// shows non-LAN servers leaking through, the OR-rule prefix list at
// ServerBrowser_ApplyTabFilter is the place to tighten.
void() ServerBrowser_DumpLanView =
{
    float view_n = gethostcachevalue(SLIST_HOSTCACHEVIEWCOUNT);
    print("[serverbrowser] LAN tab now showing ", ftos(view_n), " rows:\n");
    float idx_islocal = gethostcacheindexforkey("islocal");
    float i;
    // print() builtin caps at 8 string args (m_defs.qc:358), so dump
    // each row across three calls.
    for (i = 0; i < view_n; i++)
    {
        print("  row ", ftos(i),
              " cname='", gethostcachestring(sb_idx_cname, i),
              "' name='", gethostcachestring(sb_idx_name,  i), "'");
        print(" map='",   gethostcachestring(sb_idx_map,   i),
              "' islocal=", ftos(gethostcachenumber(idx_islocal, i)));
        print(" ping=",   ftos(gethostcachenumber(sb_idx_ping, i)), "\n");
    }
};

// Apply hostcache mask for the active tab.  Called from refresh and
// on every tab-switch click so the view count updates instantly.
//
// LAN tab passes a server if EITHER:
//   - SLKEY_ISLOCAL is set (engine flagged it as broadcast-discovered)
//   - cname starts with a loopback / RFC1918 prefix
//
// The cname-prefix fallback is needed because FTE only sets SS_LOCAL
// when a NEW server entry is allocated from a broadcast reply
// (net_master.c:3438).  When you start a listen server in the SAME
// FTE process and refresh, the local server is added through a
// different path (loopback / direct add) and never gets SS_LOCAL.
// Without the fallback, single-machine LAN testing would always show
// an empty LAN tab.
//
// FTE's mask API encodes the OR flag in mask&512 (pr_clcmd.c:847).
// Rule 0 is AND (must match islocal>0); subsequent OR rules can
// reinstate servers the AND filter excluded.
void() ServerBrowser_ApplyTabFilter =
{
    resethostcachemasks();
    if (sb_current_tab == SB_TAB_LAN)
    {
        float idx_local = gethostcacheindexforkey("islocal");
        if (idx_local >= 0)
            sethostcachemasknumber(0, idx_local, 0, SLIST_TEST_GREATER);

        float idx_cname = gethostcacheindexforkey("cname");
        if (idx_cname >= 0)
        {
            sethostcachemaskstring(512, idx_cname, "127.",     SLIST_TEST_STARTSWITH);
            sethostcachemaskstring(512, idx_cname, "192.168.", SLIST_TEST_STARTSWITH);
            sethostcachemaskstring(512, idx_cname, "10.",      SLIST_TEST_STARTSWITH);
            sethostcachemaskstring(512, idx_cname, "loopback", SLIST_TEST_STARTSWITH);
            sethostcachemaskstring(512, idx_cname, "::1",      SLIST_TEST_STARTSWITH);
            sethostcachemaskstring(512, idx_cname, "fe80:",    SLIST_TEST_STARTSWITH);
        }
    }
    // SB_TAB_FAV: empty-list-with-placeholder per stub (no persistence yet).
    // SB_TAB_ALL: no mask — show everything.
    resorthostcache();
};

// Toggle / set the sort field.  Same-column click flips direction;
// different-column click switches and resets to ascending.  Drives
// both the engine sort (sethostcachesort) and our ASCII sort indicator
// in the header label.
void(float field) ServerBrowser_SortBy =
{
    if (sb_sort_initialized && sb_sort_field == field)
        sb_sort_descending = !sb_sort_descending;
    else
    {
        sb_sort_field = field;
        sb_sort_descending = 0;
        sb_sort_initialized = 1;
    }
    sethostcachesort(sb_sort_field, sb_sort_descending);
    resorthostcache();
};

void() ServerBrowser_RefreshList =
{
    if (time < sb_last_refresh_time + 2)
        return;
    sb_last_refresh_time = time;

    // Resolve keys + register addwantedhostcachekey FIRST — the engine
    // applies these on the next master query, so this has to land
    // before refreshhostcache.
    ServerBrowser_ResolveIndices();

    // Set the working master list before kicking the query.
    ServerBrowser_EnsureMasters();

    // Initialise sort to ping-ascending on first refresh; subsequent
    // refreshes keep the user's last header-click choice.
    if (!sb_sort_initialized)
    {
        sb_sort_field = sb_idx_ping;
        sb_sort_descending = 0;
        sb_sort_initialized = 1;
    }
    sethostcachesort(sb_sort_field, sb_sort_descending);

    // refreshhostcache(1) — PURGE.  Clears cached info->name /
    // info->maxplayers / info->map etc. on existing entries and re-
    // queries.  Without this, stale data from earlier sessions (e.g.
    // a server that has since changed map or hostname) lingers in the
    // display.
    refreshhostcache(1);

    // Apply the current tab's filter (also calls resorthostcache).
    ServerBrowser_ApplyTabFilter();

    sb_selected_idx  = -1;
    sb_scroll_offset = '0 0 0';
};

// =============================================================
//  Drawing helpers
// =============================================================
// Truncation disabled per user request.  Cells now draw their full
// string regardless of column width.  This means a long server name
// will overflow visually into the adjacent column (Mode / Players)
// — preferred over the previous behaviour where short names like
// "Players" or "Ping ^" would get clipped to "Pla..." / "P..." even
// though the column had visible empty space.
//
// Reason the old strlen-based math under-counted available room: it
// assumed every char is 8 px wide (native Quake font) but stringwidth
// can return narrower widths for proportional fonts, FTE TTF fonts
// (gl_font), or post-vid_conautoscale rendering — so the floor(w/8)
// estimate was conservative AND wrong.  Disabling sidesteps all of
// that.  If overflow into the next column becomes a problem, the
// next step would be sui_clip_to_frame around each cell — clips at
// the column boundary visually without losing string data.
string(string s, float max_w) sb_clip_text =
{
    return s;
};

// Text inset within a 20 px row: y+6 leaves 6 px above and 6 px below
// the 8 px native font, vertically centring it.  Earlier y+4 looked
// top-heavy because the 12 px of remaining vertical space was 4/8
// (top/bottom) instead of 6/6.
void(float x, float y, float w, string txt, vector col, float alpha) sb_cell_text =
{
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_text([x + 4, y + 6], MENU_TEXT_SMALL, sb_clip_text(txt, w - 8), col, alpha, 0);
};

// =============================================================
//  Drag handler — uses SUI's tracked cursor position + sui_is_held
//  so latching happens on mouse-DOWN (when SUI flags the element as
//  "held") not on the mouse-up click event.  sui_is_clicked fires
//  only on release per sui_sys.qc:264 — by then the hold is over.
// =============================================================
void() ServerBrowser_HandleDrag =
{
    float held = sui_is_held("sb_titlebar");

    if (held && !sb_dragging)
    {
        // First frame the title bar sees the hold — capture the
        // cursor-to-window offset.  Subsequent frames keep dragging
        // until the user releases the mouse button.
        sb_dragging = 1;
        sb_drag_offset_x = _cursor_position_x - sb_window_pos_x;
        sb_drag_offset_y = _cursor_position_y - sb_window_pos_y;
    }

    if (held && sb_dragging)
    {
        sb_window_pos_x = _cursor_position_x - sb_drag_offset_x;
        sb_window_pos_y = _cursor_position_y - sb_drag_offset_y;

        // Clamp so at least 80 px of title bar stays on-screen.  Use
        // sb_screen_size — captured before the window frame was pushed
        // — because sui_current_frame_size() inside the window's frame
        // returns the WINDOW size, not the screen.
        if (sb_window_pos_x < -sb_window_size_x + 80)
            sb_window_pos_x = -sb_window_size_x + 80;
        if (sb_window_pos_x > sb_screen_size_x - 80)
            sb_window_pos_x = sb_screen_size_x - 80;
        if (sb_window_pos_y < 0)
            sb_window_pos_y = 0;
        if (sb_window_pos_y > sb_screen_size_y - SB_TITLE_H)
            sb_window_pos_y = sb_screen_size_y - SB_TITLE_H;
    }

    if (!held)
        sb_dragging = 0;
};

// =============================================================
//  Title bar
// =============================================================
void() ServerBrowser_DrawTitleBar =
{
    sui_push_frame([0, 0], [sb_window_size_x, SB_TITLE_H]);

    sui_fill([0, 0], [sb_window_size_x, SB_TITLE_H], '0.07 0.08 0.10', 1, 0);
    sui_fill([0, SB_TITLE_H - 1], [sb_window_size_x, 1], MENU_BORDER, 1, 0);

    // Title text — anchored to top-left of title bar with a small
    // inset.  Uses native 8x8 (MENU_TEXT_SMALL) so it stays crisp at
    // 1x conscale; non-native sizes get bilinear-filtered = blurry.
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_text([10, 10], MENU_TEXT_SMALL, "Server Browser", MENU_TEXT_1, 1, 0);

    // Drag region first, close button second.  The drag region
    // covers most of the title bar; the close button (registered
    // AFTER) takes precedence on the right corner where it overlays.
    float close_w = SB_TITLE_H;
    sui_action_element([0, 0],
        [sb_window_size_x - close_w, SB_TITLE_H],
        "sb_titlebar", sui_noop);

    if (my_button_colored("sb_close",
        [sb_window_size_x - close_w, 0],
        [close_w, SB_TITLE_H],
        "X",
        '0.40 0.15 0.15',
        '0.65 0.25 0.25'))
    {
        current_menu = MENU_MAIN;
    }

    sui_pop_frame();
};

// =============================================================
//  Tab strip
// =============================================================
void() ServerBrowser_DrawTabs =
{
    sui_push_frame([0, SB_TITLE_H], [sb_window_size_x, SB_TAB_H]);

    sui_fill([0, 0], [sb_window_size_x, SB_TAB_H], MENU_BG_DARK, 1, 0);
    sui_fill([0, SB_TAB_H - 1], [sb_window_size_x, 1], MENU_BORDER, 1, 0);

    float tab_w = 96;
    float tab_gap = 4;

    vector all_col    = (sb_current_tab == SB_TAB_ALL) ? MENU_BUTTON_RETURN : MENU_BUTTON;
    vector all_border = (sb_current_tab == SB_TAB_ALL) ? '0.30 0.50 0.30' : MENU_BUTTON_BORDER;
    if (my_button_colored("sb_tab_all",
                          [SB_PAD, 4],
                          [tab_w, SB_TAB_H - 8],
                          "All", all_col, all_border))
    {
        sb_current_tab = SB_TAB_ALL;
        ServerBrowser_ApplyTabFilter();
    }

    vector lan_col    = (sb_current_tab == SB_TAB_LAN) ? MENU_BUTTON_RETURN : MENU_BUTTON;
    vector lan_border = (sb_current_tab == SB_TAB_LAN) ? '0.30 0.50 0.30' : MENU_BUTTON_BORDER;
    if (my_button_colored("sb_tab_lan",
                          [SB_PAD + (tab_w + tab_gap) * 1, 4],
                          [tab_w, SB_TAB_H - 8],
                          "LAN", lan_col, lan_border))
    {
        sb_current_tab = SB_TAB_LAN;
        ServerBrowser_ApplyTabFilter();
        ServerBrowser_DumpLanView();    // diagnostic, prints to console
    }

    vector fav_col    = (sb_current_tab == SB_TAB_FAV) ? MENU_BUTTON_RETURN : MENU_BUTTON;
    vector fav_border = (sb_current_tab == SB_TAB_FAV) ? '0.30 0.50 0.30' : MENU_BUTTON_BORDER;
    if (my_button_colored("sb_tab_fav",
                          [SB_PAD + (tab_w + tab_gap) * 2, 4],
                          [tab_w, SB_TAB_H - 8],
                          "Favourites", fav_col, fav_border))
    {
        sb_current_tab = SB_TAB_FAV;
        ServerBrowser_ApplyTabFilter();
    }

    sui_pop_frame();
};

// =============================================================
//  Column header row — each header is a clickable button that sets
//  the active sort column.  The active header gets a brighter colour
//  + an ASCII " v" / " ^" suffix so the user can see direction.
// =============================================================
//
// Suffix is space + ASCII v/^ (codepoints 0x76 / 0x5E) — both inside
// Quake's 8-bit charset, so they render as plain glyphs.  A Unicode
// arrow like ↓ / ↑ would emit 3 UTF-8 bytes that the font draws as
// random characters (see sb_clip_text comment).
string(float field, string label) sb_header_label =
{
    if (sb_sort_initialized && sb_sort_field == field)
        return strcat(label, sb_sort_descending ? " v" : " ^");
    return label;
};

void(float field, float x, float w, string label) sb_header_cell =
{
    string id = strcat("sb_hdr_", label);
    vector col = (sb_sort_initialized && sb_sort_field == field)
                 ? MENU_TEXT_1 : MENU_TEXT_2;
    sb_cell_text(x, 0, w, sb_header_label(field, label), col, 1);
    sui_action_element([x, 0], [w, SB_COL_HEADER_H], id, sui_noop);
    if (sui_is_clicked(id))
        ServerBrowser_SortBy(field);
};

void() ServerBrowser_DrawColumnHeaders =
{
    float y0 = SB_TITLE_H + SB_TAB_H;
    sui_push_frame([0, y0], [sb_window_size_x, SB_COL_HEADER_H]);

    sui_fill([0, 0], [sb_window_size_x, SB_COL_HEADER_H], '0.10 0.11 0.13', 1, 0);
    sui_fill([0, SB_COL_HEADER_H - 1], [sb_window_size_x, 1], MENU_BORDER, 1, 0);

    sb_header_cell(sb_idx_name,      SB_COL_NAME_X,    SB_COL_NAME_W,    "Name");
    sb_header_cell(sb_idx_gamemode,  SB_COL_MODE_X,    SB_COL_MODE_W,    "Mode");
    sb_header_cell(sb_idx_numhumans, SB_COL_PLAYERS_X, SB_COL_PLAYERS_W, "Players");
    sb_header_cell(sb_idx_map,       SB_COL_MAP_X,     SB_COL_MAP_W,     "Map");
    sb_header_cell(sb_idx_ping,      SB_COL_PING_X,    SB_COL_PING_W,    "Ping");

    sui_pop_frame();
};

// =============================================================
//  Body / row list — wrapped in a SUI scroll view so the mouse
//  wheel + scrollbar thumb both work without us hand-rolling them.
//  See sui_sys.qc:1191-1248 — the begin/end pair handles wheel
//  hover-detection, drag thumb, and frame clipping.
// =============================================================
void() ServerBrowser_DrawBody =
{
    float y0 = SB_TITLE_H + SB_TAB_H + SB_COL_HEADER_H;
    float body_h = sb_window_size_y - y0 - SB_BUTTON_ROW_H;

    sui_push_frame([0, y0], [sb_window_size_x, body_h]);
    sui_fill([0, 0], [sb_window_size_x, body_h], '0.04 0.05 0.07', 1, 0);

    if (sb_current_tab == SB_TAB_FAV)
    {
        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
        sui_text([0, 0], MENU_TEXT_SMALL,
                 "No favourites yet - coming soon",
                 MENU_TEXT_2, 0.7, 0);
        sui_pop_frame();
        return;
    }

    float count = gethostcachevalue(SLIST_HOSTCACHEVIEWCOUNT);
    if (count <= 0)
    {
        sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_CENTER]);
        string empty_msg = (sb_current_tab == SB_TAB_LAN)
            ? "No LAN servers found - start a local server and Refresh"
            : "No servers - try Refresh";
        sui_text([0, 0], MENU_TEXT_SMALL, empty_msg, MENU_TEXT_2, 0.7, 0);
        sui_pop_frame();
        return;
    }

    // Scroll view — viewport is the full body area; content is
    // count*ROW_H tall.  scrollbar_widths in SUI is [hbar_h, vbar_w]
    // (note swap), so [0, 8] means no horizontal bar and an 8 px
    // vertical bar on the right.  The view begins a translated
    // frame, so row positions below are at their NATURAL y (no
    // manual sb_scroll_y subtraction).
    float content_h = count * SB_ROW_H;
    float vbar_w = 8;
    sui_scroll_view_begin("sb_body_scroll",
        [0, 0],
        [sb_window_size_x, body_h],
        [sb_window_size_x - vbar_w, content_h],
        sb_scroll_offset,
        [0, vbar_w]);

    // Cull off-screen rows: SUI's scroll_view does pixel-clipping for
    // drawing, but action_elements still accumulate one-per-row.  At
    // 50+ master servers we sail past MAX_ACTION_ELEMENTS (256).
    // Inside the scroll view's translated frame, the visible viewport
    // sits at y in [scroll_offset_y, scroll_offset_y + body_h].  Skip
    // any row whose [row_y, row_y+SB_ROW_H] lies outside that range.
    // Keep one row of slack on each side for smooth scroll feel.
    float vp_top    = sb_scroll_offset_y - SB_ROW_H;
    float vp_bottom = sb_scroll_offset_y + body_h + SB_ROW_H;

    float i;
    float row_w = sb_window_size_x - vbar_w;    // leave room for the scrollbar
    for (i = 0; i < count; i++)
    {
        float row_y = i * SB_ROW_H;
        if (row_y + SB_ROW_H < vp_top || row_y > vp_bottom)
            continue;

        string id = sprintf("sb_row_%g", i);
        float is_selected = (sb_selected_idx == i);
        float is_hover    = sui_is_hovered(id);

        if (is_selected)
            sui_fill([0, row_y], [row_w, SB_ROW_H],
                     MENU_BUTTON_RETURN, 0.85, 0);
        else if (is_hover)
            sui_fill([0, row_y], [row_w, SB_ROW_H],
                     '0.14 0.16 0.20', 1, 0);
        else if ((floor(i) - 2 * floor(i / 2)) == 0)
            sui_fill([0, row_y], [row_w, SB_ROW_H],
                     '0.06 0.07 0.09', 0.5, 0);

        vector text_col = is_selected ? '0.95 1 0.95' : MENU_TEXT_1;
        sb_cell_text(SB_COL_NAME_X,    row_y, SB_COL_NAME_W,    sb_name(i),         text_col, 1);
        sb_cell_text(SB_COL_MODE_X,    row_y, SB_COL_MODE_W,    sb_gamemode_str(i), text_col, 1);
        sb_cell_text(SB_COL_PLAYERS_X, row_y, SB_COL_PLAYERS_W, sb_players_str(i),  text_col, 1);
        sb_cell_text(SB_COL_MAP_X,     row_y, SB_COL_MAP_W,     sb_map_name(i),     text_col, 1);
        sb_cell_text(SB_COL_PING_X,    row_y, SB_COL_PING_W,    sb_ping_str(i),     text_col, 1);

        sui_action_element([0, row_y], [row_w, SB_ROW_H], id, sui_noop);
        if (sui_is_clicked(id))
        {
            if (sb_selected_idx != i)
                ServerBrowser_DumpRow(i);   // diagnostic, prints to console
            sb_selected_idx = i;
        }
    }

    sui_scroll_view_end();
    sui_pop_frame();
};

// =============================================================
//  Bottom button row
// =============================================================
void() ServerBrowser_DrawButtons =
{
    float y0 = sb_window_size_y - SB_BUTTON_ROW_H;
    sui_push_frame([0, y0], [sb_window_size_x, SB_BUTTON_ROW_H]);

    sui_fill([0, 0], [sb_window_size_x, SB_BUTTON_ROW_H], '0.07 0.08 0.10', 1, 0);
    sui_fill([0, 0], [sb_window_size_x, 1], MENU_BORDER, 1, 0);

    float btn_w = 110;
    float btn_h = 22;
    float btn_y = (SB_BUTTON_ROW_H - btn_h) * 0.5;

    float refresh_ready = (time >= sb_last_refresh_time + 2);
    vector refresh_col    = refresh_ready ? MENU_BUTTON         : '0.10 0.10 0.10';
    vector refresh_border = refresh_ready ? MENU_BUTTON_BORDER  : '0.20 0.20 0.20';
    if (my_button_colored("sb_refresh",
            [SB_PAD, btn_y], [btn_w, btn_h],
            refresh_ready ? "Refresh" : "Refresh...",
            refresh_col, refresh_border)
        && refresh_ready)
        ServerBrowser_RefreshList();

    // Status line — when a row is selected, show its full address (this
    // is the home of the address info that used to live in the dropped
    // ADDR column).  Otherwise show `view N / total M` so you can see
    // whether refresh is bringing anything back from the masters at all.
    // view = post-filter count, total = everything the cache has heard
    // about.  If both are 0 after a refresh, the master query is failing
    // (network / firewall / masters down).
    //
    // Use START align with a hand-calculated centred y — SUI's CENTER-Y
    // align ADDS to the y you pass (sui_sys.qc:104), so a non-zero y
    // with CENTER align pushes the text past the bottom of the row.
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    string status_text;
    if (sb_selected_idx >= 0)
    {
        status_text = sprintf("Selected: %s", sb_cname_str(sb_selected_idx));
    }
    else
    {
        float view_n  = gethostcachevalue(SLIST_HOSTCACHEVIEWCOUNT);
        float total_n = gethostcachevalue(SLIST_HOSTCACHETOTALCOUNT);
        status_text = sprintf("view %g / total %g", view_n, total_n);
    }
    sui_text([SB_PAD + btn_w + 12,
              floor((SB_BUTTON_ROW_H - 8) * 0.5)],
             MENU_TEXT_SMALL,
             status_text,
             MENU_TEXT_2, 0.85, 0);

    // Reset align to START before the next push_frame — my_button_colored
    // pushes its frame using the parent's alignment, so a leftover non-
    // START align would offset the connect button relative to refresh.
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    float can_connect = (sb_selected_idx >= 0);
    vector connect_col    = can_connect ? MENU_BUTTON_RETURN  : '0.10 0.10 0.10';
    vector connect_border = can_connect ? '0.30 0.50 0.30'    : '0.20 0.20 0.20';
    if (my_button_colored("sb_connect",
            [sb_window_size_x - SB_PAD - btn_w, btn_y], [btn_w, btn_h],
            "Connect",
            connect_col, connect_border)
        && can_connect)
    {
        string addr = sb_cname_str(sb_selected_idx);
        if (addr != "")
            localcmd(strcat("connect ", addr, "\n"));
    }

    sui_pop_frame();
};

// =============================================================
//  Public entry point — called from root_menu's switch.
// =============================================================
void() server_browser_menu =
{
    if (!sb_initialized)
    {
        sb_initialized   = 1;
        sb_window_size   = '480 296 0';   // total window w × h
        sb_selected_idx  = -1;
        ServerBrowser_RefreshList();
    }

    // root_menu sets ALIGN_CENTER+CENTER before dispatch, which would
    // make a child push_frame at (320, 80) be interpreted as offset
    // from screen center — throwing the hit-test region off-screen
    // and breaking drag.  Force ALIGN_START so window_pos is a top-
    // left absolute coordinate in SUI's logical screen space.
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    // Capture the screen size NOW — sui_current_frame_size at this
    // point returns the root frame (= screen).  Once we push the
    // window's frame below, the same call would return 480×296
    // (window size), which is wrong for drag clamping.
    sb_screen_size = sui_current_frame_size();

    // Periodic resort while the browser is open.  As status replies
    // arrive over 5-10 s after a refresh, FTE marks servers ALIVE in
    // the cache but doesn't update numvisibleservers — so the live
    // "view N" status would stay frozen at whatever it was at the
    // last explicit resort.  Clicking a column header used to jump
    // it from "8" to "636" because the click was the first thing to
    // call resorthostcache.  A 0.5 s tick keeps it current without
    // sorting on every frame.
    if (time >= sb_last_resort_time + 0.5)
    {
        sb_last_resort_time = time;
        resorthostcache();
    }

    // Centre on screen on first open OR if the user hasn't dragged
    // yet (window_pos still zero).
    if (!sb_dragging && sb_window_pos_x == 0 && sb_window_pos_y == 0)
    {
        sb_window_pos_x = floor((sb_screen_size_x - sb_window_size_x) * 0.5);
        sb_window_pos_y = floor((sb_screen_size_y - sb_window_size_y) * 0.5);
        if (sb_window_pos_x < 0) sb_window_pos_x = 0;
        if (sb_window_pos_y < 0) sb_window_pos_y = 0;
    }

    sui_push_frame(sb_window_pos, sb_window_size);

    sui_fill([0, 0], sb_window_size, MENU_BG_DARK, 0.96, 0);
    sui_border_box([0, 0], sb_window_size, 2, MENU_BORDER, 1, 0);

    ServerBrowser_DrawTitleBar();
    ServerBrowser_DrawTabs();
    ServerBrowser_DrawColumnHeaders();
    ServerBrowser_DrawBody();
    ServerBrowser_DrawButtons();

    ServerBrowser_HandleDrag();

    sui_pop_frame();
};
