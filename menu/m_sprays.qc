// =============================================================
//  Main-menu "Sprays" panel
// =============================================================
//
//  Scans gfx/sprays/*.png via FTE's search_begin builtin, lets the
//  user cycle / pick a spray, and persists the choice as both the
//  `cl_spray` cvar and the `_spray` userinfo key (so SV_PlayerSpray
//  on the server can read it via infokey()).
//
//  Lives on the right side of the main menu — drawn from
//  main_menu() in m_menu.qc.  Panel layout:
//
//    +----------------------+
//    |   "Sprays"           |
//    +----------------------+
//    |                      |
//    |   256x256 preview    |
//    |                      |
//    +----------------------+
//    |   <  rebel  >        |
//    +----------------------+
//    |       Refresh        |
//    +----------------------+
//
//  Refresh re-runs the search so a PNG dropped into the folder at
//  runtime can be discovered without restarting.  Selection
//  defaults to the entry matching the current cl_spray value, or
//  "nospray" if that PNG isn't in the folder.

const float SPRAY_LIST_MAX     = 64;
const float SPRAY_PANEL_PREV   = 128;     // 128×128 preview window
const float SPRAY_PANEL_PAD    = 8;       // inner padding
const float SPRAY_PANEL_W      = 144;     // 128 preview + 2*8 pad
const float SPRAY_PANEL_RIGHT  = 24;      // distance from screen right edge

string spray_list[SPRAY_LIST_MAX];        // basenames (no extension)
float  spray_list_count;
float  spray_list_selected;               // index into spray_list[]
float  spray_list_inited;                 // first-draw guard

// ---------- helpers ----------

// Strip the leading "gfx/sprays/" prefix and trailing ".png" suffix
// from a filename returned by search_getfilename.  Returns the base
// name, or empty string if the path doesn't look like a spray PNG.
string(string full) Sprays_StripPath =
{
    string name = full;
    string prefix = "gfx/sprays/";
    float plen = strlen(prefix);
    if (strlen(name) > plen && substring(name, 0, plen) == prefix)
        name = substring(name, plen, strlen(name) - plen);
    float nlen = strlen(name);
    if (nlen > 4 && substring(name, nlen - 4, 4) == ".png")
        name = substring(name, 0, nlen - 4);
    return name;
};

// (Re)scan gfx/sprays/*.png on the local filesystem.  Repopulates
// spray_list[] and keeps spray_list_selected pointing at the current
// cl_spray choice if it's still available.
void() Sprays_Refresh =
{
    string current = cvar_string("cl_spray");
    if (current == "") current = "nospray";

    spray_list_count    = 0;
    spray_list_selected = 0;

    float h = search_begin("gfx/sprays/*.png", TRUE, TRUE);
    if (h < 0)
    {
        // No files found.  Leave spray_list empty; UI will show
        // "(none)" — server-side SV_PlayerSpray will still fall back
        // to nospray.png if the player's _spray happens to point at
        // a missing file.
        spray_list_inited = TRUE;
        return;
    }

    float n = search_getsize(h);
    float i;
    for (i = 0; i < n && spray_list_count < SPRAY_LIST_MAX; i = i + 1)
    {
        string full = search_getfilename(h, i);
        string base = Sprays_StripPath(full);
        if (base == "") continue;
        spray_list[spray_list_count] = base;
        if (base == current)
            spray_list_selected = spray_list_count;
        spray_list_count = spray_list_count + 1;
    }
    search_end(h);

    spray_list_inited = TRUE;
};

// Commit the current selection to the cl_spray cvar + push the name
// to the server via `cmd setspray <name>`.  The server stores it on
// the player entity and reads it from SV_PlayerSpray each fire —
// previously we used `setinfo _spray ...` but the userinfo path
// didn't propagate mid-session (forcing a reconnect for changes to
// land), so we route through the explicit command channel now.
void() Sprays_Apply =
{
    if (spray_list_count <= 0) return;
    if (spray_list_selected < 0) spray_list_selected = 0;
    if (spray_list_selected >= spray_list_count)
        spray_list_selected = spray_list_count - 1;
    string sel = spray_list[spray_list_selected];
    cvar_set("cl_spray", sel);
    localcmd(sprintf("cmd setspray %s\n", sel));
};

void() Sprays_Select_Prev =
{
    if (spray_list_count <= 0) return;
    spray_list_selected = spray_list_selected - 1;
    if (spray_list_selected < 0)
        spray_list_selected = spray_list_count - 1;
    Sprays_Apply();
};

void() Sprays_Select_Next =
{
    if (spray_list_count <= 0) return;
    spray_list_selected = spray_list_selected + 1;
    if (spray_list_selected >= spray_list_count)
        spray_list_selected = 0;
    Sprays_Apply();
};

// ---------- public draw ----------
//
// Called from main_menu() in m_menu.qc.  `menu_size` is menu_root_size
// (full screen, sui canvas dimensions).
void(vector menu_size) Sprays_DrawPanel =
{
    if (!spray_list_inited)
        Sprays_Refresh();

    // Header band over preview, plus a name label beneath.
    // Selection cycles by clicking the preview; no arrow/refresh row.
    float header_h     = 22;
    float arrow_row_h  = 24;
    float total_h = header_h + SPRAY_PANEL_PREV + arrow_row_h
                    + SPRAY_PANEL_PAD * 3;

    float px = menu_size_x - SPRAY_PANEL_W - SPRAY_PANEL_RIGHT;
    // Bottom-anchor the panel's lower edge at 85% of screen height —
    // matches the main-menu left text column so both UI blocks
    // share the same baseline regardless of resolution.
    float py = floor(menu_size_y * 0.85) - total_h;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_push_frame([px, py], [SPRAY_PANEL_W, total_h]);

    // Floating — no panel background.  Each row draws over the menu
    // backdrop directly.

    // --- header ---
    // Left-aligned at the same x as the preview's left edge
    // (SPRAY_PANEL_PAD).  START align measures both axes from the
    // top-left of the SUI frame.
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_text([SPRAY_PANEL_PAD, 4], [12, 12, 0], "Your Spray:", '1 1 1', 1.0, 0);

    // --- preview ---
    // No border around the preview — the panel is fully background-
    // free now to match the floating main menu's aesthetic.
    float prev_y = header_h;
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    string preview_name;
    if (spray_list_count > 0 && spray_list_selected >= 0
        && spray_list_selected < spray_list_count)
        preview_name = spray_list[spray_list_selected];
    else
        preview_name = "nospray";

    string preview_path = sprintf("gfx/sprays/%s.png", preview_name);
    drawpic([px + SPRAY_PANEL_PAD, py + prev_y],
            preview_path,
            [SPRAY_PANEL_PREV, SPRAY_PANEL_PREV, 0],
            '1 1 1', 1.0, 0);

    // Click hitzone over the preview — advances to the next spray.
    sui_action_element([SPRAY_PANEL_PAD, prev_y],
                       [SPRAY_PANEL_PREV, SPRAY_PANEL_PREV],
                       "sprays_click", sui_noop);
    if (sui_is_clicked("sprays_click"))
        Sprays_Select_Next();

    // --- name row ---
    float label_y = prev_y + SPRAY_PANEL_PREV + SPRAY_PANEL_PAD;
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
    string label;
    if (spray_list_count > 0)
        label = sprintf("%s  (%d/%d)",
                        preview_name,
                        spray_list_selected + 1,
                        spray_list_count);
    else
        label = "(no sprays found)";
    sui_text([0, label_y + (arrow_row_h - 10) * 0.5],
             [10, 10, 0], label, '0.85 0.85 0.9', 1.0, 0);

    sui_pop_frame();
};
