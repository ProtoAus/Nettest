// ============================================================
//  menu/m_loading.qc  -  Custom loading / download screen
//
//  Engine data via serverkey() (see fteqw/engine/client/pr_clcmd.c):
//    constate:     "active" | "disconnected" | "connecting"
//    transferring: hostname of destination server, or ""
//    loadstate:    ALWAYS a formatted string "stage cur total \"img\"";
//                  stage=0 means "not loading". Docs in fteextensions.qc
//                  are wrong about token order.
//    dlstate:      "remaining total_size unknown_flag local remote
//                    pct rate recv total"  — empty string when idle
//
//  FTE only raises scr_drawloading around the map-load plaque; during
//  the "Downloading X..." phase it stays false.  We therefore render
//  the panel from both m_drawloading (plaque) and m_draw (gated on
//  m_loading_should_show).
// ============================================================

// serverkey() isn't declared in the menu defs; pull it in locally.  #354
// matches pr_menu.c's PF_cl_serverkey entry.
string(string key) serverkey = #354;

// Panel padding — kept in sync with the main menu so sizes feel familiar.
const float LD_PAD       = 8;    // uniform outer padding
const float LD_TITLE_SZ  = 18;
const float LD_TEXT_SZ   = 12;
const float LD_STAT_SZ   = 8;    // small readouts (byte counts, rates)
const float LD_BAR_H     = 10;
const float LD_BAR_SM_H  = 8;    // per-file bar inside download card

string(float bytes) m_loading_format_bytes =
{
    if (bytes < 0) bytes = 0;
    if (bytes < 1024)
        return sprintf("%.0f B", bytes);
    if (bytes < 1024 * 1024)
        return sprintf("%.1f KB", bytes / 1024);
    if (bytes < 1024 * 1024 * 1024)
        return sprintf("%.1f MB", bytes / (1024 * 1024));
    return sprintf("%.2f GB", bytes / (1024 * 1024 * 1024));
};

// Filled rectangle showing `pct` (0..100).  pct < 0 → indeterminate bar:
// a ~25 %-wide chunk slides back and forth at ~2 s period.
void(vector pos, vector size, float pct) m_loading_progress_bar =
{
    sui_fill(pos, size, MENU_BG_DARK, 1, 0);

    if (pct >= 0)
    {
        pct = bound(0, pct, 100);
        if (pct > 0)
            sui_fill(pos, [size_x * (pct / 100), size_y, 0],
                     MENU_BUTTON_RETURN, 1, 0);
    }
    else
    {
        float chunk_w = size_x * 0.25;
        float travel  = size_x - chunk_w;
        float t = time * 0.5;
        t = t - floor(t);                                 // 2s sawtooth
        float phase = (t < 0.5) ? (t * 2) : (2 - t * 2);  // triangle
        sui_fill([pos_x + phase * travel, pos_y, 0],
                 [chunk_w, size_y, 0], MENU_BUTTON_RETURN, 1, 0);
    }

    sui_border_box(pos, size, 1, MENU_BORDER, 1, 0);
};

// TRUE iff the engine reports active loading or an active download.
// Used by m_draw to decide whether to cover the screen with our panel
// during the pre-plaque download phase.
float() m_loading_should_show =
{
    string ls = serverkey("loadstate");
    if (ls != "")
    {
        tokenize(ls);
        if (stof(argv(0)) > 0)
            return TRUE;
    }
    if (serverkey("dlstate") != "")
        return TRUE;
    return FALSE;
};

// Transfer-rate fallback — FTE's own `rate` token reads 0 for fast local
// downloads (sampling window too short).  Track the received-bytes delta
// ourselves and surface it when the engine has nothing useful.  Reset on
// filename change or when bytes go backwards (new file started).
string m_dl_last_name;
float  m_dl_last_recv;
float  m_dl_last_time;
float  m_dl_rate_smoothed;

float(string local_name, float recv) m_loading_track_rate =
{
    float now = time;
    if (local_name != m_dl_last_name || recv < m_dl_last_recv)
    {
        m_dl_last_name = local_name;
        m_dl_last_recv = recv;
        m_dl_last_time = now;
        m_dl_rate_smoothed = 0;
        return 0;
    }
    float dt = now - m_dl_last_time;
    if (dt >= 0.1)
    {
        float instant = (recv - m_dl_last_recv) / dt;
        // Simple low-pass so the readout doesn't jitter frame-to-frame.
        m_dl_rate_smoothed = m_dl_rate_smoothed * 0.6 + instant * 0.4;
        m_dl_last_recv = recv;
        m_dl_last_time = now;
    }
    return m_dl_rate_smoothed;
};

// Core panel render — NO sui_begin/sui_end, NO fullscreen fill.  Call
// from inside an already-active sui frame.  Auto-sized to its content.
void(vector screensize) m_loading_draw_panel =
{
    string host = serverkey("transferring");
    string ls   = serverkey("loadstate");
    string dl   = serverkey("dlstate");

    // Parse loadstate (stage, cur, total) — 0 stage = idle.
    float ls_stage = 0;
    float ls_cur = 0, ls_max = 0;
    if (ls != "")
    {
        tokenize(ls);
        ls_stage = stof(argv(0));
        ls_cur   = stof(argv(1));
        ls_max   = stof(argv(2));
    }

    float has_subtitle = (host != "");
    float has_dl       = (dl != "");
    float has_stage    = (ls_stage > 0);

    // --- Compute content heights so we can size the panel tightly ---
    // Stage block: label + bar + (optional) step readout
    float stage_block_h = LD_TEXT_SZ + 4 + LD_BAR_H;
    float show_step_readout = (ls_max > 0 && ls_cur > 0);
    if (show_step_readout)
        stage_block_h += 2 + LD_STAT_SZ;

    // Download card: header + filename + bar + stats
    float card_h = 0;
    if (has_dl)
    {
        // 4 rows at tight spacing inside 8 px padding.
        card_h = LD_PAD
               + LD_TEXT_SZ            // header
               + 4 + LD_TEXT_SZ        // filename
               + 6 + LD_BAR_SM_H       // per-file bar
               + 4 + LD_STAT_SZ        // stats
               + LD_PAD;
    }

    float panel_w = has_dl ? 280 : 220;
    float panel_h = LD_PAD
                  + LD_TITLE_SZ
                  + (has_subtitle ? (2 + LD_TEXT_SZ) : 0)
                  + 8
                  + stage_block_h
                  + (has_dl ? (6 + card_h) : 0)
                  + LD_PAD;

    vector panel_size = [panel_w, panel_h, 0];
    vector panel_pos  = [floor((screensize_x - panel_w) * 0.5),
                         floor((screensize_y - panel_h) * 0.5), 0];

    sui_push_frame(panel_pos, panel_size);
    menu_panel_bg(panel_size, 4);

    // --- Title ---
    string title_text;
    if (has_dl)                                 title_text = "Downloading";
    else if (has_stage && ls_stage == 1)        title_text = "Connecting";
    else if (host != "" && !has_stage)          title_text = "Connecting";
    else                                        title_text = "Loading";

    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
    sui_text([1, LD_PAD + 1], [LD_TITLE_SZ, LD_TITLE_SZ, 0],
             title_text, '0 0 0', 0.5, 0);
    sui_text([0, LD_PAD],     [LD_TITLE_SZ, LD_TITLE_SZ, 0],
             title_text, '1 1 1', 1, 0);

    float y = LD_PAD + LD_TITLE_SZ;
    if (has_subtitle)
    {
        y += 2;
        sui_text([0, y], [LD_TEXT_SZ, LD_TEXT_SZ, 0],
                 host, MENU_TEXT_2, 0.9, 0);
        y += LD_TEXT_SZ;
    }

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);

    // --- Stage label + bar ---
    y += 8;
    string stage_text;
    float pct = -1;
    if (has_stage)
    {
        if (ls_stage == 1)      stage_text = "Connecting";
        else if (ls_stage == 2) stage_text = "Loading server data";
        else                    stage_text = "Loading client data";
        // Only trust the ratio when cur is actually advancing — FTE often
        // sets max > 0 but never increments cur during client-data loads.
        if (ls_max > 0 && ls_cur > 0)
            pct = (ls_cur / ls_max) * 100;
    }
    else if (has_dl)
    {
        stage_text = "Receiving content";
    }
    else
    {
        stage_text = "Please wait";
    }

    sui_text([LD_PAD, y], [LD_TEXT_SZ, LD_TEXT_SZ, 0],
             stage_text, MENU_TEXT_1, 1, 0);
    y += LD_TEXT_SZ + 4;
    m_loading_progress_bar([LD_PAD, y, 0],
                           [panel_w - LD_PAD * 2, LD_BAR_H, 0], pct);
    y += LD_BAR_H;
    if (show_step_readout)
    {
        y += 2;
        sui_set_align([SUI_ALIGN_END, SUI_ALIGN_START]);
        sui_text([-LD_PAD, y], [LD_STAT_SZ, LD_STAT_SZ, 0],
                 sprintf("%g / %g", ls_cur, ls_max),
                 MENU_TEXT_2, 0.9, 0);
        sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
        y += LD_STAT_SZ;
    }

    // --- Download card ---
    if (has_dl)
    {
        tokenize(dl);
        float remaining   = stof(argv(0));
        float total_size  = stof(argv(1));
        float unknown_fl  = stof(argv(2));
        string local_name = argv(3);
        float file_pct    = stof(argv(5));
        float engine_rate = stof(argv(6));
        float file_recv   = stof(argv(7));
        float file_total  = stof(argv(8));

        // Substitute our own rate tracker when the engine's sample is 0.
        float tracked_rate = m_loading_track_rate(local_name, file_recv);
        float file_rate = (engine_rate > 0) ? engine_rate : tracked_rate;

        float card_x = LD_PAD;
        float card_y = y + 6;
        float card_w = panel_w - LD_PAD * 2;

        sui_push_frame([card_x, card_y], [card_w, card_h]);
        menu_panel_bg([card_w, card_h], 0);

        string totalstr = strcat(unknown_fl ? "~" : "",
                                 m_loading_format_bytes(total_size));
        string hdr = sprintf("%g file%s  (%s)",
                             remaining,
                             (remaining == 1) ? "" : "s",
                             totalstr);

        float cy = LD_PAD;
        sui_text([LD_PAD, cy], [LD_TEXT_SZ, LD_TEXT_SZ, 0],
                 hdr, MENU_TEXT_1, 1, 0);
        cy += LD_TEXT_SZ + 4;

        if (local_name != "")
        {
            sui_text([LD_PAD, cy], [LD_TEXT_SZ, LD_TEXT_SZ, 0],
                     local_name, MENU_TEXT_2, 0.9, 0);
        }
        cy += LD_TEXT_SZ + 6;

        m_loading_progress_bar([LD_PAD, cy, 0],
                               [card_w - LD_PAD * 2, LD_BAR_SM_H, 0],
                               file_pct);
        cy += LD_BAR_SM_H + 4;

        string stats = sprintf("%s / %s   %.0f%%   %s/s",
            m_loading_format_bytes(file_recv),
            m_loading_format_bytes(file_total),
            file_pct,
            m_loading_format_bytes(file_rate));
        sui_text([LD_PAD, cy], [LD_STAT_SZ, LD_STAT_SZ, 0],
                 stats, MENU_TEXT_2, 0.9, 0);

        sui_pop_frame();
    }

    sui_pop_frame();
};

// Called during the "loading plaque" phase (engine's scr_drawloading).
void(vector screensize, float opaque) m_drawloading =
{
    drawfont = menu_font;
    sui_begin(screensize_x, screensize_y);

    if (opaque)
        sui_fill([0, 0], screensize, '0.01 0.01 0.02', 1, 0);

    // If the engine fired this handler but there's nothing truly loading
    // anymore (stale scr_drawloading), just paint the backdrop and bail —
    // don't redraw a stuck panel.
    if (m_loading_should_show())
        m_loading_draw_panel(screensize);

    sui_end();
};
