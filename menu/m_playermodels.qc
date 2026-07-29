// =============================================================
//  Main-menu "Player Model" panel
// =============================================================
//
//  Sticky player-model picker that lives next to the spray panel
//  on the main menu.  Renders a rotating 3D preview using FTE's
//  MenuQC scene builtins (clearscene + addentity + renderscene),
//  cycles the available models with < / > arrows, and persists
//  the chosen player_model_index to the cl_player_model_choice
//  cvar.  When sv_playerselect > 0, the in-game team-select skips
//  its character phase and joins with this value (see
//  menu/m_teamselect.qc TeamMenuSelect).
//
//  Layout — drawn from main_menu() in m_menu.qc:
//
//    +----------------------+ +----------------+
//    | Player Model:        | | Your Spray:    |
//    +----------------------+ +----------------+
//    |                      | |                |
//    |   3D preview (128x   | |   spray pic    |
//    |   160 rotating)      | |   (128x128)    |
//    |                      | |                |
//    +----------------------+ +----------------+
//    | <  numberK  >        | | <  rebel  >    |
//    +----------------------+ +----------------+

// Menu progs has a minimal entity field set (see m_defs.qc — auto-
// generated from pr_dumpplatform, no gameplay fields).  Declare what
// the 3D preview entity needs locally so the compiler resolves the
// field accesses; the engine recognises them by name at runtime.
.string classname;
.float  frame;
.vector origin;
.vector angles;
.float  scale;

const float PLAYERMODEL_PANEL_PREV_W = 128;
const float PLAYERMODEL_PANEL_PREV_H = 160;
const float PLAYERMODEL_PANEL_PAD    = 8;
const float PLAYERMODEL_PANEL_W      = 144;  // 128 preview + 2*8 pad
const float PLAYERMODEL_PANEL_GAP    = 12;   // space between this panel and Sprays

// Parallel arrays — index N across all three describes one model.
// player_model_index values match PlayerApplyModel in server/sv_player.qc.
const float PLAYERMODEL_COUNT = 3;
float  g_playermodel_indices[PLAYERMODEL_COUNT] = { 6, 7, 8 };
string g_playermodel_paths  [PLAYERMODEL_COUNT] = {
    "models/player/chickenman/chickenman.iqm",
    "models/player/numberk/numberK.iqm",
    "models/player/kilmer/kilmer.iqm"
};
string g_playermodel_names  [PLAYERMODEL_COUNT] = {
    "Chickenman",
    "numberK",
    "Kilmer"
};

float  g_playermodel_selected;     // index into the arrays, 0..PLAYERMODEL_COUNT-1
float  g_playermodel_inited;       // first-draw guard
entity g_playermodel_preview_ent;  // reused 3D preview entity (spawn once)

// Map the saved cvar value (a player_model_index) back to the slot in
// our arrays.  Falls through to slot 0 if the cvar holds something
// unexpected — keeps the menu functional after a model is removed.
float(float idx) Playermodels_SlotForIndex =
{
    float i;
    for (i = 0; i < PLAYERMODEL_COUNT; i = i + 1)
        if (g_playermodel_indices[i] == idx)
            return i;
    return 0;
};

// Init runs once on first draw.  Precaches every model so MenuQC's
// renderscene call can resolve them, spawns the persistent preview
// entity, and seeds the selection from the saved cvar.
void() Playermodels_Init =
{
    float i;
    for (i = 0; i < PLAYERMODEL_COUNT; i = i + 1)
        precache_model(g_playermodel_paths[i]);

    if (!g_playermodel_preview_ent)
    {
        g_playermodel_preview_ent = spawn();
        g_playermodel_preview_ent.classname = "playermodel_preview";
    }

    float saved = cvar("cl_player_model_choice");
    g_playermodel_selected = Playermodels_SlotForIndex(saved);
    g_playermodel_inited = TRUE;
};

// Persist the current selection to cvar AND push it to the server so
// the model swaps live for the connected player.  Mirrors the spray
// apply path (cvar + `cmd …`).  When not connected, the localcmd is
// queued harmlessly — the next connect picks up the cvar value.
// Server-side handling lives in SV_ParseClientCommand under the
// "playermodel" case (server/sv_player.qc) and is itself gated on
// sv_playerselect so a player can't bypass the legacy flow.
void() Playermodels_Apply =
{
    float idx = g_playermodel_indices[g_playermodel_selected];
    cvar_set("cl_player_model_choice", ftos(idx));
    localcmd(sprintf("cmd playermodel %d\n", idx));
};

void() Playermodels_Select_Prev =
{
    g_playermodel_selected = g_playermodel_selected - 1;
    if (g_playermodel_selected < 0)
        g_playermodel_selected = PLAYERMODEL_COUNT - 1;
    Playermodels_Apply();
};

void() Playermodels_Select_Next =
{
    g_playermodel_selected = g_playermodel_selected + 1;
    if (g_playermodel_selected >= PLAYERMODEL_COUNT)
        g_playermodel_selected = 0;
    Playermodels_Apply();
};

// 3D preview — adapted from DrawCharacterPreview in m_teamselect.qc.
// Fixed camera (the menumap doesn't carry a CAM_FLAG_*_PLAYER cam, and
// we want the main-menu preview consistent regardless of which map is
// loaded as the backdrop).  Camera at +X looking back at the origin,
// model spinning slowly on Y.
void(vector preview_pos, vector preview_size, string mdl_path) Playermodels_DrawPreview =
{
    setmodel(g_playermodel_preview_ent, mdl_path);
    g_playermodel_preview_ent.frame  = 1; // CSANIM_IDLE
    g_playermodel_preview_ent.origin = '0 0 0';
    g_playermodel_preview_ent.angles = [0, time * 40, 0]; // slow rotation
    g_playermodel_preview_ent.scale  = 1;

    clearscene();
    setproperty(VF_MIN, preview_pos);
    setproperty(VF_SIZE, preview_size);
    // Camera at +X looking back at origin, with tight FOV for a
    // larger framed model. Aim slightly above the model's feet so the
    // torso/head sit in the upper portion of the panel.
    setproperty(VF_ORIGIN, [180, 0, 16]);
    setproperty(VF_ANGLES, [0, 180, 0]);
    setproperty(VF_AFOV, 14);
    addentity(g_playermodel_preview_ent);
    renderscene();
};

// ---------- public draw ----------
//
// Called from main_menu() in m_menu.qc.  `menu_size` is menu_root_size
// (full screen, sui canvas dimensions).  Panel sits immediately left
// of the Sprays panel and shares its 85% baseline.
void(vector menu_size) Playermodels_DrawPanel =
{
    if (!g_playermodel_inited)
        Playermodels_Init();

    float header_h    = 22;
    float arrow_row_h = 24;
    float total_h = header_h + PLAYERMODEL_PANEL_PREV_H + arrow_row_h
                    + PLAYERMODEL_PANEL_PAD * 3;

    // Position: directly left of the Sprays panel (which is anchored
    // at menu_size_x - SPRAY_PANEL_W - SPRAY_PANEL_RIGHT).  Same py.
    float sprays_left = menu_size_x - SPRAY_PANEL_W - SPRAY_PANEL_RIGHT;
    float px = sprays_left - PLAYERMODEL_PANEL_GAP - PLAYERMODEL_PANEL_W;
    float py = floor(menu_size_y * 0.85) - total_h;

    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_push_frame([px, py], [PLAYERMODEL_PANEL_W, total_h]);

    // --- header ---
    sui_set_align([SUI_ALIGN_START, SUI_ALIGN_START]);
    sui_text([PLAYERMODEL_PANEL_PAD, 4], [12, 12, 0],
             "Player Model:", '1 1 1', 1.0, 0);

    // --- 3D preview ---
    float prev_y = header_h;
    // Render into the sub-rect.  setproperty(VF_MIN/SIZE) expects
    // absolute screen coords, not SUI-frame-relative, so add the
    // frame origin back in.
    Playermodels_DrawPreview([px + PLAYERMODEL_PANEL_PAD, py + prev_y],
                             [PLAYERMODEL_PANEL_PREV_W,
                              PLAYERMODEL_PANEL_PREV_H],
                             g_playermodel_paths[g_playermodel_selected]);

    // Click hitzone over the preview — advances to the next model.
    // Placed AFTER the renderscene so the SUI input pass sees the
    // rect at the same coords as the rendered preview.
    sui_action_element([PLAYERMODEL_PANEL_PAD, prev_y],
                       [PLAYERMODEL_PANEL_PREV_W, PLAYERMODEL_PANEL_PREV_H],
                       "pm_click", sui_noop);
    if (sui_is_clicked("pm_click"))
        Playermodels_Select_Next();

    // --- name row ---
    float label_y = prev_y + PLAYERMODEL_PANEL_PREV_H + PLAYERMODEL_PANEL_PAD;
    sui_set_align([SUI_ALIGN_CENTER, SUI_ALIGN_START]);
    string label = sprintf("%s  (%d/%d)",
                           g_playermodel_names[g_playermodel_selected],
                           g_playermodel_selected + 1,
                           PLAYERMODEL_COUNT);
    // 12, not 10: menu_font only rasterises 8 12 16 18 24 36 48 60 72 (m_main.qc:157), so an
    // off-list size gets bilinear-scaled and reads blurry. See menu/m_menu.qc:26-33.
    sui_text([0, label_y + (arrow_row_h - 12) * 0.5],
             [12, 12, 0], label, '0.85 0.85 0.9', 1.0, 0);

    sui_pop_frame();
};
