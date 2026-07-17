// ============================================================
//  client/cl_paint.qc — player body painting (camo + paintball splats)
//
//  Two mechanics share this core:
//    * CAMO: a player holds +camo aiming at a wall; the server streams
//      (wall texture name, coverage 0..1) and every client paints that
//      player's skin with the ACTUAL wall texture in growing blotches —
//      stand against the wall and you blend in.
//    * SPLATS: paintball hits on players broadcast (color, seed); a
//      colored splat is stamped onto the victim's skin.
//
//  HOW IT WORKS (FTE runtime-paint pipeline, all CSQC):
//    r_readimage(base skin .bmp/.png)  ->  CPU RGBA buffer (cached per texture)
//    per painted player: memalloc a working copy, stamp blotches/splats
//    r_uploadimage("paint/p<slot>_s<k>")  ->  GPU texture (created by name)
//    shaderforname("paintsh/p<slot>_s<k>", "{program defaultskin ...}")
//    setcustomskin 'replace "<surface>" "paintsh/..."' on the player's
//    visual proxy — per-ENTITY binding, other players untouched.  The
//    replace lines are merged into the ONE setcustomskin call cl_player.qc
//    already makes for bodygroups (PlayerVis_ApplySkin) — two competing
//    setcustomskin calls would clobber each other.
//
//  Determinism: blotch/splat positions come from integer hashes of
//  (slot, surface, index) so every client renders the same paint from
//  the same event stream — nothing but the events crosses the wire.
//
//  Incremental: stamping only ADDS the new blotch/splat to the working
//  buffer (no full repaints), so a paint event costs a few thousand
//  pixel writes + one upload.  Full rebuilds happen only when coverage
//  DROPS (damage wash) or the wall texture changes.
//
//  Wire: CSQC_EVENT_PLAYER_PAINT (sh_weapons.qc), subtypes:
//    0 = camo set   (slot, amt byte, texname string)
//    1 = splat      (slot, r g b bytes, seed short)
//    2 = clear all  (slot)                       — death/respawn
//
//  Not supported v1: sini.mdl (skin embedded in the .mdl — no loose
//  file for r_readimage to seed from); late-join splat resync (camo IS
//  resynced; splats are live-only).
// ============================================================

// (r_readimage / r_uploadimage / memalloc / memfree are declared in cl_defs.qc)

// ---------- painted-surface table (generated: tools/dump_iqm_surfaces.py) ----------
// Per player model: which surfaces get painted and the loose texture file each
// surface's base pixels come from (IQM materials resolve beside the model).
// Glass/shades surfaces are skipped (translucent).  sini.mdl absent = no paint.
const float PAINT_MODEL_MAX = 11;
const float PAINT_SURF_MAX  = 8;

string paint_model_path[PAINT_MODEL_MAX];
float  paint_model_nsurf[PAINT_MODEL_MAX];
string paint_surf_name[88];   // PAINT_MODEL_MAX * PAINT_SURF_MAX
string paint_surf_tex [88];

float paint_table_ready;

// Row helper: register surface k of model row m.
void(float m, float k, string sname, string stex) PaintTable_Surf =
{
    paint_surf_name[m * PAINT_SURF_MAX + k] = sname;
    paint_surf_tex [m * PAINT_SURF_MAX + k] = stex;
};

void() PaintTable_Init =
{
    if (paint_table_ready) return;
    paint_table_ready = 1;

    paint_model_path[0] = "models/player/urban/urban.iqm";
    paint_model_nsurf[0] = 5;
    PaintTable_Surf(0, 0, "ct_urban_vest",   "models/player/urban/ct_urban_vest.bmp");
    PaintTable_Surf(0, 1, "ct_urban_arms",   "models/player/urban/ct_urban_arms.bmp");
    PaintTable_Surf(0, 2, "ct_urban_helmet", "models/player/urban/ct_urban_helmet.bmp");
    PaintTable_Surf(0, 3, "ct_urban_pants",  "models/player/urban/ct_urban_pants.bmp");
    PaintTable_Surf(0, 4, "Backpack2",       "models/player/urban/Backpack2.BMP");

    paint_model_path[1] = "models/player/gign/gign.iqm";
    paint_model_nsurf[1] = 5;
    PaintTable_Surf(1, 0, "ct_gign_arms",    "models/player/gign/ct_gign_arms.bmp");
    PaintTable_Surf(1, 1, "ct_gign_pants",   "models/player/gign/ct_gign_pants.bmp");
    PaintTable_Surf(1, 2, "ct_gign_vest",    "models/player/gign/ct_gign_vest.bmp");
    PaintTable_Surf(1, 3, "ct_gign_helmet",  "models/player/gign/ct_gign_helmet.bmp");
    PaintTable_Surf(1, 4, "Backpack2",       "models/player/gign/Backpack2.BMP");

    paint_model_path[2] = "models/player/gsg9/gsg9.iqm";
    paint_model_nsurf[2] = 5;
    PaintTable_Surf(2, 0, "ct_gsg9_body",    "models/player/gsg9/ct_gsg9_body.bmp");
    PaintTable_Surf(2, 1, "ct_gsg9_arms",    "models/player/gsg9/ct_gsg9_arms.bmp");
    PaintTable_Surf(2, 2, "ct_gsg9_legs",    "models/player/gsg9/ct_gsg9_legs.bmp");
    PaintTable_Surf(2, 3, "ct_gsg9_head",    "models/player/gsg9/ct_gsg9_head.bmp");
    PaintTable_Surf(2, 4, "Backpack2",       "models/player/gsg9/Backpack2.BMP");

    paint_model_path[3] = "models/player/sas/sas.iqm";
    paint_model_nsurf[3] = 5;
    PaintTable_Surf(3, 0, "ct_sas_arms",     "models/player/sas/ct_sas_arms.bmp");
    PaintTable_Surf(3, 1, "ct_sas_pants",    "models/player/sas/ct_sas_pants.bmp");
    PaintTable_Surf(3, 2, "ct_sas_vest",     "models/player/sas/ct_sas_vest.bmp");
    PaintTable_Surf(3, 3, "ct_sas_head",     "models/player/sas/ct_sas_head.bmp");
    PaintTable_Surf(3, 4, "Backpack2",       "models/player/sas/Backpack2.BMP");

    paint_model_path[4] = "models/player/guerilla/guerilla.iqm";
    paint_model_nsurf[4] = 6;
    PaintTable_Surf(4, 0, "t_guerilla_arms",  "models/player/guerilla/t_guerilla_arms.bmp");
    PaintTable_Surf(4, 1, "t_guerilla_legs",  "models/player/guerilla/t_guerilla_legs.bmp");
    PaintTable_Surf(4, 2, "t_guerilla_boots", "models/player/guerilla/t_guerilla_boots.bmp");
    PaintTable_Surf(4, 3, "t_guerilla_head",  "models/player/guerilla/t_guerilla_head.bmp");
    PaintTable_Surf(4, 4, "t_guerilla_vest",  "models/player/guerilla/t_guerilla_vest.bmp");
    PaintTable_Surf(4, 5, "Backpack1",        "models/player/guerilla/Backpack1.BMP");

    paint_model_path[5] = "models/player/leet/leet.iqm";
    paint_model_nsurf[5] = 6;
    PaintTable_Surf(5, 0, "t_leet_arms",   "models/player/leet/t_leet_arms.bmp");
    PaintTable_Surf(5, 1, "t_leet_boots",  "models/player/leet/t_leet_boots.bmp");
    PaintTable_Surf(5, 2, "t_leet_legs",   "models/player/leet/t_leet_legs.bmp");
    PaintTable_Surf(5, 3, "t_leet_jacket", "models/player/leet/t_leet_jacket.bmp");
    PaintTable_Surf(5, 4, "t_leet_head",   "models/player/leet/t_leet_head.bmp");
    PaintTable_Surf(5, 5, "Backpack1",     "models/player/leet/Backpack1.BMP");

    paint_model_path[6] = "models/player/terror/terror.iqm";
    paint_model_nsurf[6] = 7;
    PaintTable_Surf(6, 0, "t_phoenix_arms",  "models/player/terror/t_phoenix_arms.bmp");
    PaintTable_Surf(6, 1, "t_phoenix_hands", "models/player/terror/t_phoenix_hands.bmp");
    PaintTable_Surf(6, 2, "t_phoenix_boots", "models/player/terror/t_phoenix_boots.bmp");
    PaintTable_Surf(6, 3, "t_phoenix_pants", "models/player/terror/t_phoenix_pants.bmp");
    PaintTable_Surf(6, 4, "t_phoenix_mask",  "models/player/terror/t_phoenix_mask.bmp");
    PaintTable_Surf(6, 5, "t_phoenix_vest",  "models/player/terror/t_phoenix_vest.bmp");
    PaintTable_Surf(6, 6, "Backpack1",       "models/player/terror/Backpack1.BMP");

    paint_model_path[7] = "models/player/arctic/arctic.iqm";
    paint_model_nsurf[7] = 5;
    PaintTable_Surf(7, 0, "t_arctic_arms",   "models/player/arctic/t_arctic_arms.bmp");
    PaintTable_Surf(7, 1, "t_arctic_head",   "models/player/arctic/t_arctic_head.bmp");
    PaintTable_Surf(7, 2, "t_arctic_legs",   "models/player/arctic/t_arctic_legs.bmp");
    PaintTable_Surf(7, 3, "t_arctic_jacket", "models/player/arctic/t_arctic_jacket.bmp");
    PaintTable_Surf(7, 4, "Backpack1",       "models/player/arctic/Backpack1.BMP");

    paint_model_path[8] = "models/player/chickenman/chickenman.iqm";
    paint_model_nsurf[8] = 2;
    PaintTable_Surf(8, 0, "hltex000", "models/player/chickenman/hltex000.png");
    PaintTable_Surf(8, 1, "hltex001", "models/player/chickenman/hltex001.png");

    paint_model_path[9] = "models/player/numberk/numberK.iqm";
    paint_model_nsurf[9] = 8;
    PaintTable_Surf(9, 0, "fin_shirt1",    "models/player/numberk/fin_shirt1.bmp");
    PaintTable_Surf(9, 1, "fin_pant1",     "models/player/numberk/fin_pant1.bmp");
    PaintTable_Surf(9, 2, "fin_pant2",     "models/player/numberk/fin_pant2.bmp");
    PaintTable_Surf(9, 3, "fin_pant3",     "models/player/numberk/fin_pant3.bmp");
    PaintTable_Surf(9, 4, "fin_vestFront", "models/player/numberk/fin_vestFront.bmp");
    PaintTable_Surf(9, 5, "fin_vestBack",  "models/player/numberk/fin_vestBack.bmp");
    PaintTable_Surf(9, 6, "fin_arm1",      "models/player/numberk/fin_arm1.bmp");
    PaintTable_Surf(9, 7, "fin_head",      "models/player/numberk/fin_head.bmp");

    paint_model_path[10] = "models/player/kilmer/kilmer.iqm";
    paint_model_nsurf[10] = 4;
    PaintTable_Surf(10, 0, "main",      "models/player/kilmer/main.bmp");
    PaintTable_Surf(10, 1, "hand",      "models/player/kilmer/hand.bmp");
    PaintTable_Surf(10, 2, "head",      "models/player/kilmer/head.bmp");
    PaintTable_Surf(10, 3, "Backpack1", "models/player/kilmer/Backpack1.BMP");
};

float(string mdl) Paint_ModelRow =
{
    float m;
    PaintTable_Init();
    for (m = 0; m < PAINT_MODEL_MAX; m = m + 1)
        if (paint_model_path[m] == mdl)
            return m;
    return -1;
};

// ---------- base-pixel cache (one entry per distinct texture file) ----------
// Base buffers are r_readimage results (QC-addressable); kept for the whole
// session — a handful of small skins + a few wall textures, low MB.
const float PAINT_BASE_MAX = 96;
string paint_base_path[PAINT_BASE_MAX];
float  paint_base_w   [PAINT_BASE_MAX];
float  paint_base_h   [PAINT_BASE_MAX];
float  paint_base_count;

// POINTER TABLE — one memalloc'd int block holding every pixel-buffer pointer:
//   [0..95]    base-cache pointers (parallel to paint_base_* above)
//   [96..359]  per-slot work-buffer pointers (96 + slot*PAINT_SURF_MAX + k)
// fteqcc GLOBAL INT ARRAYS silently break (writes not visible to later reads —
// verified live: buffers allocated fine, the very next loop read them as 0),
// so pointers must live behind a plain int* with pointer indexing, the same
// well-tested mechanism the pixel blits use.
int *paint_ptrtab;
void() Paint_TabInit =
{
    if (paint_ptrtab) return;
    paint_ptrtab = memalloc(360 * 4);
    int i;
    for (i = 0; i < 360; i = i + 1)
        paint_ptrtab[i] = 0;
};

// Returns cache row or -1 (missing/unreadable file — surface silently skips).
float(string path) Paint_BaseFor =
{
    float i;
    Paint_TabInit();
    for (i = 0; i < paint_base_count; i = i + 1)
        if (paint_base_path[i] == path)
            return (paint_ptrtab[ftoi(i)] != 0) ? i : -1;   // 0 ptr = cached miss
    if (paint_base_count >= PAINT_BASE_MAX) return -1;

    int w, h;
    int *pix = r_readimage(path, w, h);
    i = paint_base_count;
    paint_base_count = paint_base_count + 1;
    paint_base_path[i] = strzone(path);
    if (!pix || w <= 0 || h <= 0)
    {
        paint_ptrtab[ftoi(i)] = 0;  // remember the miss, don't retry every event
        return -1;                  // callers (Paint_WallFor) report a consolidated miss
    }
    paint_ptrtab[ftoi(i)] = (int)pix;
    paint_base_w[i]   = itof(w);
    paint_base_h[i]   = itof(h);
    return i;
};

// Resolve a WALL texture's pixels: loose textures/<name> with an extension
// ladder (the ericw bounce PNGs are the common case; TGA/JPG for variety).
// DDS-only textures (inside pk3s) can't be CPU-decoded by r_readimage — those
// fall back to the flat olive tint in Paint_CatchUp.  Misses are cached (each
// probe burns a cache row, hence the generous PAINT_BASE_MAX) and reported
// once so "why is my camo olive" is answerable from the console.
float(string texname) Paint_WallFor =
{
    float b = Paint_BaseFor(strcat("textures/", texname, ".png"));
    if (b < 0) b = Paint_BaseFor(strcat("textures/", texname, ".tga"));
    if (b < 0) b = Paint_BaseFor(strcat("textures/", texname, ".jpg"));
    if (b < 0) b = Paint_BaseFor(strcat("textures/", texname, ".dds"));  // pk3 DDS (engine P99 CPU-decodes)
    if (b < 0)
        print(sprintf("paint: no readable textures/%s.(png|tga|jpg|dds) — flat-tint camo\n", texname));
    return b;
};

// ---------- per-slot paint state ----------
const float PAINT_SLOT_MAX  = 33;   // 1-based player entnums 1..32
const float PAINT_SPLAT_MAX = 24;
const float PAINT_DISSOLVE_BLOCK = 8;  // camo dissolve granularity (px); smaller = smoother frontier, more work

string paint_camo_tex[PAINT_SLOT_MAX];      // zoned wall texture name; "" = none
float  paint_camo_amt[PAINT_SLOT_MAX];      // 0..1 coverage from the server
float  paint_splat_count[PAINT_SLOT_MAX];
vector paint_splat_col[792];                // PAINT_SLOT_MAX * PAINT_SPLAT_MAX
float  paint_splat_seed[792];

// working buffers, keyed [slot][surfidx] — flattened.  The POINTERS live in
// paint_ptrtab at [96 + ws] (see the int-array trap note above); only the
// float/string metadata lives in real QC arrays.
string paint_buf_model  [PAINT_SLOT_MAX];   // model the buffers were built for
float  paint_buf_dirty  [264];              // needs re-upload (PAINT_SLOT_MAX * PAINT_SURF_MAX)
float  paint_buf_shader [264];              // shaderforname done for this name
float  paint_applied_cov   [PAINT_SLOT_MAX];// camo coverage already dissolved onto the buffers (0..1)
float  paint_stamped_splat [PAINT_SLOT_MAX];// splats stamped so far

// ---------- deterministic hash ----------
float(float a, float b, float c) Paint_Noise01 =
{
    int h = ftoi(a) * 374761393 + ftoi(b) * 668265263 + ftoi(c) * 974634751;
    h = h ^ (h >> 13);
    h = h * 1274126177;
    h = h ^ (h >> 16);
    return itof(h & 1023) / 1023;
};

// ---------- pixel stamps ----------
// Blotch: copy the WALL texture (tiled, offset per-blotch) into a ragged
// soft circle of the work buffer.  All int math; ~ (2r)^2 pixel writes.
void(int wptr, float ww, float wh, int bptr, float bw, float bh,
     float cx, float cy, float rad, float seed) Paint_StampBlotch =
{
    int *dst  = (int*)wptr;
    int *wall = (int*)bptr;
    int iww = ftoi(ww);
    int ibw = ftoi(bw);
    int ibh = ftoi(bh);
    int ox  = ftoi(Paint_Noise01(seed, 91, 3) * bw);   // per-blotch tile offset
    int oy  = ftoi(Paint_Noise01(seed, 57, 9) * bh);

    float x0 = floor(cx - rad); if (x0 < 0) x0 = 0;
    float y0 = floor(cy - rad); if (y0 < 0) y0 = 0;
    float x1 = ceil(cx + rad);  if (x1 > ww - 1) x1 = ww - 1;
    float y1 = ceil(cy + rad);  if (y1 > wh - 1) y1 = wh - 1;

    float x, y;
    for (y = y0; y <= y1; y = y + 1)
    {
        float dy = y - cy;
        for (x = x0; x <= x1; x = x + 1)
        {
            float dx = x - cx;
            float d  = sqrt(dx*dx + dy*dy);
            if (d > rad) continue;
            float f = 1 - d / rad;                       // 1 centre .. 0 edge
            if (f < 0.35)                                // ragged rim
            {
                if (Paint_Noise01(x, y, seed) > f * 2.9)
                    continue;
            }
            int wx = ftoi(x) + ox;  wx = wx - (wx / ibw) * ibw;
            int wy = ftoi(y) + oy;  wy = wy - (wy / ibh) * ibh;
            dst[ftoi(y) * iww + ftoi(x)] = wall[wy * ibw + wx];
        }
    }
};

// Camo DISSOLVE fill: replace every block whose 2-octave block-noise <= coverage
// with the tiled wall texture (or a flat colour when the wall couldn't be read).
// This GUARANTEES full coverage at cov=1.0 (every block's noise is <= 1) — the old
// scattered-blotch approach left permanent gaps, so only the UV islands under a
// blotch got painted ("just the shoes / part of the face").  Growth order is the
// block noise, so low-noise blobs appear first and spread — reads as organic camo.
// Idempotent: re-filling an already-covered block writes the same pixels, so it's
// safe to call repeatedly as coverage climbs (no per-block "done" tracking needed).
// wallptr<0 signalled by wbw<=0 -> flat `flat` colour instead of the wall tile.
// Fills only the block band (cov0 <= noise <= cov1) so an incremental coverage step
// touches ~one band's worth of pixels, not the whole texture each time.  Union of the
// bands as coverage climbs = the full [0, cov] set; boundary blocks re-fill harmlessly.
void(int wptr, float ww, float wh, int wallptr, float wbw, float wbh,
     float cov0, float cov1, vector flat, float seed) Paint_DissolveFill =
{
    int *dst  = (int*)wptr;
    int *wall = (int*)wallptr;
    int iww = ftoi(ww);
    int iwh = ftoi(wh);
    int ibw = ftoi(wbw);
    int ibh = ftoi(wbh);
    float haswall = (wbw > 0) ? 1 : 0;
    int flatpix = ftoi(bound(0, flat_x * 255, 255))
                | (ftoi(bound(0, flat_y * 255, 255)) << 8)
                | (ftoi(bound(0, flat_z * 255, 255)) << 16)
                | (255 << 24);
    float bs = PAINT_DISSOLVE_BLOCK;

    float bx, by;
    for (by = 0; by < wh; by = by + bs)
    {
        for (bx = 0; bx < ww; bx = bx + bs)
        {
            // 2-octave block noise: coarse ~4-block blobs + per-block detail so the
            // frontier isn't a straight grid line.
            float t = 0.62 * Paint_Noise01(floor(bx / bs / 4), floor(by / bs / 4), seed)
                    + 0.38 * Paint_Noise01(floor(bx / bs),     floor(by / bs),     seed + 7);
            if (t < cov0 || t > cov1) continue;

            float x1 = bx + bs; if (x1 > ww) x1 = ww;
            float y1 = by + bs; if (y1 > wh) y1 = wh;
            float x, y;
            for (y = by; y < y1; y = y + 1)
            {
                int iy = ftoi(y);
                if (haswall)
                {
                    int wy = iy - (iy / ibh) * ibh;
                    for (x = bx; x < x1; x = x + 1)
                    {
                        int ix = ftoi(x);
                        int wx = ix - (ix / ibw) * ibw;
                        dst[iy * iww + ix] = wall[wy * ibw + wx];
                    }
                }
                else
                {
                    for (x = bx; x < x1; x = x + 1)
                        dst[iy * iww + ftoi(x)] = flatpix;
                }
            }
        }
    }
};

// Splat: solid-color disk with a ragged rim + slightly darker centre ring.
void(int wptr, float ww, float wh, float cx, float cy, float rad,
     vector col, float seed) Paint_StampSplat =
{
    int *dst = (int*)wptr;
    int iww = ftoi(ww);
    int a255 = 255;
    int cr = ftoi(bound(0, col_x * 255, 255));
    int cg = ftoi(bound(0, col_y * 255, 255));
    int cb = ftoi(bound(0, col_z * 255, 255));
    int cpix  = cr | (cg << 8) | (cb << 16) | (a255 << 24);
    int cdark = ftoi(cr * 0.72) | (ftoi(cg * 0.72) << 8) | (ftoi(cb * 0.72) << 16) | (a255 << 24);

    float x0 = floor(cx - rad); if (x0 < 0) x0 = 0;
    float y0 = floor(cy - rad); if (y0 < 0) y0 = 0;
    float x1 = ceil(cx + rad);  if (x1 > ww - 1) x1 = ww - 1;
    float y1 = ceil(cy + rad);  if (y1 > wh - 1) y1 = wh - 1;

    float x, y;
    for (y = y0; y <= y1; y = y + 1)
    {
        float dy = y - cy;
        for (x = x0; x <= x1; x = x + 1)
        {
            float dx = x - cx;
            float d  = sqrt(dx*dx + dy*dy);
            if (d > rad) continue;
            float f = 1 - d / rad;
            if (f < 0.40)
            {
                if (Paint_Noise01(x, y, seed) > f * 2.6)
                    continue;
            }
            dst[ftoi(y) * iww + ftoi(x)] = (f > 0.72) ? cdark : cpix;
        }
    }
};

// ---------- buffer lifecycle ----------
void(float slot) Paint_FreeBuffers =
{
    float k;
    Paint_TabInit();
    for (k = 0; k < PAINT_SURF_MAX; k = k + 1)
    {
        float ws = slot * PAINT_SURF_MAX + k;
        if (paint_ptrtab[ftoi(ws) + 96])
        {
            memfree((void*)paint_ptrtab[ftoi(ws) + 96]);
            paint_ptrtab[ftoi(ws) + 96] = 0;
        }
        paint_buf_dirty[ws] = 0;
        // paint_buf_shader stays — shader handles persist in the engine
    }
    if (paint_buf_model[slot] != "")
    {
        strunzone(paint_buf_model[slot]);
        paint_buf_model[slot] = "";
    }
    paint_applied_cov[slot]   = 0;
    paint_stamped_splat[slot]  = 0;
};

// Verbose diagnostics (set by painttest for its refresh; camo path stays quiet).
float paint_verbose;

// Ensure work buffers exist for this slot + model.  Returns table row or -1.
// Fresh buffers start as clean copies of the base skin (all stamps reset).
float(float slot, string mdl) Paint_EnsureBuffers =
{
    float row = Paint_ModelRow(mdl);
    if (row < 0) return -1;

    if (paint_buf_model[slot] == mdl)
        return row;

    Paint_FreeBuffers(slot);
    float k;
    float got = 0;
    for (k = 0; k < paint_model_nsurf[row]; k = k + 1)
    {
        float b = Paint_BaseFor(paint_surf_tex[row * PAINT_SURF_MAX + k]);
        if (b < 0)
        {
            if (paint_verbose)
                print(sprintf("paint:   surf %g '%s': base READ FAILED (%s)\n", k,
                              paint_surf_name[row * PAINT_SURF_MAX + k],
                              paint_surf_tex[row * PAINT_SURF_MAX + k]));
            continue;
        }
        int npix = ftoi(paint_base_w[b]) * ftoi(paint_base_h[b]);
        int *buf = memalloc(npix * 4);
        if (!buf)
        {
            if (paint_verbose)
                print(sprintf("paint:   surf %g '%s': memalloc(%g) FAILED (CSQC heap? see pr_csqc_memsize)\n",
                              k, paint_surf_name[row * PAINT_SURF_MAX + k], itof(npix) * 4));
            continue;
        }
        int *src = (int*)paint_ptrtab[ftoi(b)];
        int i;
        for (i = 0; i < npix; i = i + 1)
            buf[i] = src[i];
        float ws = slot * PAINT_SURF_MAX + k;
        paint_ptrtab[ftoi(ws) + 96]   = (int)buf;
        paint_buf_dirty[ws] = 1;
        got = 1;
        if (paint_verbose)
            print(sprintf("paint:   surf %g '%s': ok %gx%g\n", k,
                          paint_surf_name[row * PAINT_SURF_MAX + k],
                          paint_base_w[b], paint_base_h[b]));
    }
    if (!got) return -1;
    paint_buf_model[slot] = strzone(mdl);
    return row;
};

// Reset work buffers to the clean base (coverage dropped / texture changed).
void(float slot, float row) Paint_ResetToBase =
{
    float k;
    for (k = 0; k < paint_model_nsurf[row]; k = k + 1)
    {
        float ws = slot * PAINT_SURF_MAX + k;
        if (!paint_ptrtab[ftoi(ws) + 96]) continue;
        float b = Paint_BaseFor(paint_surf_tex[row * PAINT_SURF_MAX + k]);
        if (b < 0) continue;
        int npix = ftoi(paint_base_w[b]) * ftoi(paint_base_h[b]);
        int *dst = (int*)paint_ptrtab[ftoi(ws) + 96];
        int *src = (int*)paint_ptrtab[ftoi(b)];
        int i;
        for (i = 0; i < npix; i = i + 1)
            dst[i] = src[i];
        paint_buf_dirty[ws] = 1;
    }
    paint_applied_cov[slot]   = 0;
    paint_stamped_splat[slot]  = 0;
};

// ---------- stamping catch-up (the incremental heart) ----------
// Bring the slot's buffers up to date with the networked paint state:
// stamp missing camo blotches on every surface, then missing splats.
void(float slot, float row) Paint_CatchUp =
{
    float k, i;
    float nsurf = paint_model_nsurf[row];

    // camo: dissolve the wall texture onto every surface up to the coverage.
    float cov = 0;
    if (paint_camo_amt[slot] > 0 && paint_camo_tex[slot] != "")
        cov = bound(0, paint_camo_amt[slot], 1);
    if (cov < paint_applied_cov[slot])
    {
        // coverage went DOWN (damage wash) — rebuild from base, re-dissolve below.
        Paint_ResetToBase(slot, row);   // sets paint_applied_cov[slot] = 0
    }
    if (cov > paint_applied_cov[slot])
    {
        float wb = -1;
        if (paint_camo_tex[slot] != "")
            wb = Paint_WallFor(paint_camo_tex[slot]);
        float wbw = 0, wbh = 0;
        int   wbp = 0;
        if (wb >= 0) { wbw = paint_base_w[wb]; wbh = paint_base_h[wb]; wbp = paint_ptrtab[ftoi(wb)]; }
        for (k = 0; k < nsurf; k = k + 1)
        {
            float ws = slot * PAINT_SURF_MAX + k;
            if (!paint_ptrtab[ftoi(ws) + 96]) continue;
            float b = Paint_BaseFor(paint_surf_tex[row * PAINT_SURF_MAX + k]);
            if (b < 0) continue;
            // Fill the newly-revealed band [applied, cov]; the union of bands as coverage
            // climbs = full [0, cov], guaranteeing 100% at cov=1.  Per-surface seed so each
            // body part dissolves in its own pattern.
            Paint_DissolveFill(paint_ptrtab[ftoi(ws) + 96], paint_base_w[b], paint_base_h[b],
                wbp, wbw, wbh, paint_applied_cov[slot], cov, '0.35 0.38 0.27', slot * 97 + k * 13 + 5);
            paint_buf_dirty[ws] = 1;
        }
        paint_applied_cov[slot] = cov;
    }

    // splats: each new splat lands on ONE surface picked by its seed
    for (i = paint_stamped_splat[slot]; i < paint_splat_count[slot]; i = i + 1)
    {
        float si  = slot * PAINT_SPLAT_MAX + i;
        float sd  = paint_splat_seed[si];
        k = floor(Paint_Noise01(sd, 5, slot) * nsurf);
        if (k >= nsurf) k = nsurf - 1;
        float ws = slot * PAINT_SURF_MAX + k;
        if (!paint_ptrtab[ftoi(ws) + 96]) continue;
        float b = Paint_BaseFor(paint_surf_tex[row * PAINT_SURF_MAX + k]);
        if (b < 0) continue;
        float w = paint_base_w[b];
        float h = paint_base_h[b];
        float cx = Paint_Noise01(sd, 17, slot) * w;
        float cy = Paint_Noise01(sd, 29, slot) * h;
        float rr = (0.07 + 0.05 * Paint_Noise01(sd, 41, slot)) * ((w > h) ? w : h);
        Paint_StampSplat(paint_ptrtab[ftoi(ws) + 96], w, h, cx, cy, rr, paint_splat_col[si], sd);
        paint_buf_dirty[ws] = 1;
    }
    paint_stamped_splat[slot] = paint_splat_count[slot];
};

// Upload dirty buffers + make sure each painted surface has its shader.
void(float slot, float row) Paint_Upload =
{
    float k;
    for (k = 0; k < paint_model_nsurf[row]; k = k + 1)
    {
        float ws = slot * PAINT_SURF_MAX + k;
        if (!paint_ptrtab[ftoi(ws) + 96]) continue;
        float b = Paint_BaseFor(paint_surf_tex[row * PAINT_SURF_MAX + k]);
        if (b < 0) continue;
        string texname = sprintf("paint/p%g_s%g", slot, k);
        if (paint_buf_dirty[ws])
        {
            r_uploadimage(texname, ftoi(paint_base_w[b]), ftoi(paint_base_h[b]),
                          (int*)paint_ptrtab[ftoi(ws) + 96]);
            paint_buf_dirty[ws] = 0;
        }
        if (!paint_buf_shader[ws])
        {
            // program defaultskin keeps ALL model lighting (lightgrid N.L,
            // self-shadow, P98 sun-shade) on the painted skin.
            // $rt: prefix is REQUIRED: r_uploadimage creates the texture with
            // RT_IMAGEFLAGS, and $rt: is the shader-side spelling of exactly
            // those flags (Shader_SetImageFlags) — a plain name looks up with
            // different flags, misses the cache, tries the DISK, and the whole
            // model renders with the pink error texture.
            shaderforname(sprintf("paintsh/p%g_s%g", slot, k), sprintf(
                "{\nprogram defaultskin\ndiffusemap \"$rt:%s\"\n{\nmap $diffuse\n}\n}", texname));
            paint_buf_shader[ws] = 1;
        }
    }
};

// ---------- the one entry point cl_player.qc uses ----------
// Returns the 'replace "<surf>" "<shader>"' lines for this proxy's
// setcustomskin call ("" = unpainted / unsupported / disabled).  Does ALL
// the lazy work (buffers, stamps, uploads) so callers stay one-liners.
float paint_warned_mdl;   // one console line per session for unsupported models

string(entity proxy) Paint_SkinLines =
{
    if (!cvar("cl_paint")) return "";
    float slot = proxy.vis_owner_entnum;
    if (slot < 1 || slot >= PAINT_SLOT_MAX) return "";

    // any paint state at all?
    if (paint_camo_amt[slot] <= 0 && paint_splat_count[slot] <= 0)
        return "";

    float row = Paint_EnsureBuffers(slot, proxy.model);
    if (row < 0)
    {
        if (!paint_warned_mdl && proxy.model != "")
        {
            paint_warned_mdl = 1;
            print(sprintf("paint: no paint support for model %s (embedded/unknown skins)\n", proxy.model));
        }
        return "";
    }

    Paint_CatchUp(slot, row);
    Paint_Upload(slot, row);

    string lines = "";
    float k;
    for (k = 0; k < paint_model_nsurf[row]; k = k + 1)
    {
        float ws = slot * PAINT_SURF_MAX + k;
        if (!paint_ptrtab[ftoi(ws) + 96]) continue;
        lines = strcat(lines, sprintf("replace \"%s\" \"paintsh/p%g_s%g\"\n",
                       paint_surf_name[row * PAINT_SURF_MAX + k], slot, k));
    }
    if (paint_verbose)
    {
        print(sprintf("paint: skin lines for %s:\n%s", proxy.model, lines));
        // Headless coverage audit: count pixels that differ from the base skin so a
        // no-display test can confirm full coverage ("part of the face" was < 100%).
        for (k = 0; k < paint_model_nsurf[row]; k = k + 1)
        {
            float ws = slot * PAINT_SURF_MAX + k;
            if (!paint_ptrtab[ftoi(ws) + 96]) continue;
            float b = Paint_BaseFor(paint_surf_tex[row * PAINT_SURF_MAX + k]);
            if (b < 0) continue;
            int npix = ftoi(paint_base_w[b]) * ftoi(paint_base_h[b]);
            int *w = (int*)paint_ptrtab[ftoi(ws) + 96];
            int *s = (int*)paint_ptrtab[ftoi(b)];
            int diff = 0, i;
            for (i = 0; i < npix; i = i + 1)
                if (w[i] != s[i]) diff = diff + 1;
            print(sprintf("paint:   AUDIT surf %g '%s': %g%% painted\n", k,
                          paint_surf_name[row * PAINT_SURF_MAX + k],
                          itof(diff) * 100 / itof(npix)));
        }
    }
    return lines;
};

// Re-run the proxy's skin apply after a paint state change.  The skin body
// (geomsets + our lines) is owned by PlayerVis_ApplySkin in cl_player.qc.
void(float slot) Paint_RefreshProxy =
{
    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (p.vis_owner_entnum == slot && p.model != "")
            PlayerVis_ApplySkin(p);
        p = p.chain;
    }
};

// ---------- event handlers (dispatched from cl_main.qc) ----------
void() Paint_Ev_Read =
{
    float sub  = readbyte();
    float slot = readbyte();

    if (sub == 0)          // camo set: amt byte + texname string
    {
        float amt = readbyte() / 255;
        string tex = readstring();
        if (slot < 1 || slot >= PAINT_SLOT_MAX) return;
        if (paint_camo_tex[slot] != "" && paint_camo_tex[slot] != tex)
        {
            // texture swap: force a from-base rebuild (applied > any real cov -> CatchUp resets)
            paint_applied_cov[slot] = 2;
        }
        if (paint_camo_tex[slot] != "")
            strunzone(paint_camo_tex[slot]);
        paint_camo_tex[slot] = strzone(tex);
        paint_camo_amt[slot] = amt;
        Paint_RefreshProxy(slot);
    }
    else if (sub == 1)     // splat: r g b bytes + seed short
    {
        vector col;
        col_x = readbyte() / 255;
        col_y = readbyte() / 255;
        col_z = readbyte() / 255;
        float seed = readshort();
        if (slot < 1 || slot >= PAINT_SLOT_MAX) return;
        if (paint_splat_count[slot] >= PAINT_SPLAT_MAX)
        {
            // ring full: drop the whole layer + restamp (rare)
            paint_splat_count[slot]    = 0;
            paint_stamped_splat[slot]  = 0;
            paint_applied_cov[slot]    = 2;  // forces from-base reset in CatchUp
        }
        float si = slot * PAINT_SPLAT_MAX + paint_splat_count[slot];
        paint_splat_col[si]  = col;
        paint_splat_seed[si] = seed;
        paint_splat_count[slot] = paint_splat_count[slot] + 1;
        Paint_RefreshProxy(slot);
    }
    else if (sub == 2)     // clear all (death/respawn)
    {
        if (slot < 1 || slot >= PAINT_SLOT_MAX) return;
        if (paint_camo_tex[slot] != "")
        {
            strunzone(paint_camo_tex[slot]);
            paint_camo_tex[slot] = "";
        }
        paint_camo_amt[slot]    = 0;
        paint_splat_count[slot] = 0;
        Paint_FreeBuffers(slot);
        Paint_RefreshProxy(slot);   // rebinds to the plain skin (lines = "")
    }
};

// QUICK TEST (console `painttest`, local-only — nothing crosses the wire):
//   painttest brickwall 0.8      -> 80% camo in textures/brickwall.png on YOUR body
//   painttest - 0 6              -> clean camo, 6 random paint splats
//   painttest -                  -> clear everything
// View yourself with chase_active 1 / thirdperson.  Exercises the whole
// pipeline (readimage -> stamps -> upload -> shader -> customskin) without a
// server round-trip.
// Shared test core.  Returns the number of proxies repainted.
float(string tex, float amt, float nspl) Paint_TestApply =
{
    float slot = player_localentnum;
    print(sprintf("painttest: slot=%g tex='%s' amt=%g splats=%g (cl_paint=%g)\n",
                  slot, tex, amt, nspl, cvar("cl_paint")));
    if (slot < 1 || slot >= PAINT_SLOT_MAX)
    {
        print("painttest: no local player slot (spectating?)\n");
        return 0;
    }

    if (paint_camo_tex[slot] != "")
    {
        strunzone(paint_camo_tex[slot]);
        paint_camo_tex[slot] = "";
    }
    paint_camo_amt[slot]    = 0;
    paint_splat_count[slot] = 0;
    Paint_FreeBuffers(slot);   // full rebuild from base on next SkinLines

    if (tex != "" && tex != "-")
    {
        paint_camo_tex[slot] = strzone(tex);
        paint_camo_amt[slot] = (amt > 0) ? bound(0, amt, 1) : 1;
    }
    float i;
    for (i = 0; i < nspl && i < PAINT_SPLAT_MAX; i = i + 1)
    {
        float si = slot * PAINT_SPLAT_MAX + i;
        paint_splat_col[si]  = [0.2 + random() * 0.8, 0.2 + random() * 0.8, 0.2 + random() * 0.8];
        paint_splat_seed[si] = floor(random() * 30000);
        paint_splat_count[slot] = i + 1;
    }
    // Refresh + report: did we actually find + repaint a proxy?
    paint_verbose = 1;
    float refreshed = 0;
    entity p = findchain(classname, "player_visual_proxy");
    while (p)
    {
        if (p.vis_owner_entnum == slot && p.model != "")
        {
            PlayerVis_ApplySkin(p);
            refreshed = refreshed + 1;
            print(sprintf("painttest: repainted proxy model '%s'\n", p.model));
        }
        p = p.chain;
    }
    paint_verbose = 0;
    if (!refreshed)
        print("painttest: NO visual proxy found for your slot — join a game first (not spectate)\n");
    else
        print(sprintf("painttest: done — camo '%s' amt %.2f, %g splats. chase_active 1 to view; 'painttest -' to clear\n",
                      paint_camo_tex[slot], paint_camo_amt[slot], paint_splat_count[slot]));
    return refreshed;
};

void() Paint_TestCmd =
{
    string tex = argv(1);
    if (tex == "")
    {
        print("usage: painttest <wallTexName|-> [amt01] [splats]   (view: chase_active 1)\n");
        return;
    }
    Paint_TestApply(tex, stof(argv(2)), stof(argv(3)));
};

// Headless self-test hook (per-frame from cl_main.qc): launch the game with
// `+set cl_paint_autotest <texname>` and once in-game the test runs itself,
// dumps the console to painttest_dump.txt and quits.  Dev tool for the
// automated harness — inert unless the cvar is set on the command line.
float paint_autotest_state;   // 0 = idle/armed, 1 = done
float paint_autotest_next;    // next attempt time (1 Hz retry while the proxy spawns)
void() Paint_AutoTestFrame =
{
    if (paint_autotest_state) return;
    string t = cvar_string("cl_paint_autotest");
    if (t == "")   { paint_autotest_state = 1; return; }   // not armed this session
    if (cltime < 5) return;                                 // let the join settle
    if (cltime < paint_autotest_next) return;
    paint_autotest_next = cltime + 1;
    localcmd("cmd jointeam blue 0\n");                      // headless boots sit at team select — join
    if (Paint_TestApply(t, 1, 4) <= 0 && cltime < 25)
        return;                                             // proxy not up yet — retry in 1s
    paint_autotest_state = 1;
    localcmd("condump painttest_dump.txt\nquit\n");
};

// Video restart destroys name-only textures (no disk backing) — re-upload
// everything that's active.  Called from CSQC_RendererRestarted (cl_main.qc).
void() Paint_RendererRestarted =
{
    float slot, k;
    Paint_TabInit();
    for (slot = 1; slot < PAINT_SLOT_MAX; slot = slot + 1)
    {
        if (paint_buf_model[slot] == "") continue;
        for (k = 0; k < PAINT_SURF_MAX; k = k + 1)
        {
            float ws = slot * PAINT_SURF_MAX + k;
            if (paint_ptrtab[ftoi(ws) + 96]) paint_buf_dirty[ws] = 1;
            paint_buf_shader[ws] = 0;
        }
        float row = Paint_ModelRow(paint_buf_model[slot]);
        if (row >= 0)
        {
            Paint_Upload(slot, row);
            Paint_RefreshProxy(slot);
        }
    }
};
