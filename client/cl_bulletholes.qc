// ============================================================
//  client/cl_bulletholes.qc  -  Client-side bullet hole decals
//
//  Spawns persistent client-side decal records at impact points.
//  Local player sees them instantly from prediction.
//  Other players see them from server multicast events.
//
//  Uses a linked list with a max cap — oldest holes are removed
//  when the cap is reached.
// ============================================================

// BULLETHOLE_MAX is now the cl_bulletholes_max cvar (cached per frame
// as bh_cache_max). 2048 was the legacy hard limit before the cvar.
const float BULLETHOLE_MAX_PER_FRAME   = 30;
const float BULLETHOLE_OFFSET_MIN      = 0.3;
const float BULLETHOLE_OFFSET_JITTER   = 0.1;
const float BULLETHOLE_DECAL_HALF_SIZE = 4;
const float SNOWSPLAT_DECAL_HALF_SIZE  = 9;
// Material-decal sizing — glass shatters spread out so we render the
// hole noticeably larger.  Other materials use the standard size.
const float BULLETHOLE_GLASS_HALF_SIZE = 14;
const float BULLETHOLE_MATERIAL_HALF_SIZE = 5;
// adddecal() fades alpha by distance from the decal origin plane, so
// z-fighting must be handled by the shader's polygonOffset instead.
const float BULLETHOLE_DECAL_BIAS      = 0;
string BULLETHOLE_QUAD_SHADER          = "gfx/bullethole";
string SNOWSPLAT_QUAD_SHADER           = "gfx/snowsplat";

// --- Linked list fields ---
.entity bh_next;
.entity bh_prev;
.entity bh_dyn_next;
.entity bh_dyn_prev;
// Per-quad linked list — holes that need a per-frame per-quad draw
// call because they carry a custom shader (bh_shader_path) and so
// can't share the batched gfx/bullethole / gfx/snowsplat trisoup.
// Populated by the snow/paint splat spawners for STATIC (world-hit)
// splats; TRACKED splats use bh_dyn_head instead.  Disjoint from
// bh_dyn_head — no hole appears in both.
.entity bh_pq_next;
.entity bh_pq_prev;
.float  bh_dynamic;        // TRUE if attached to a moving BSP entity
.vector bh_local_offset;   // offset from owner.absmin for dynamic holes
.vector bh_decal_origin;   // un-nudged impact center for clipped decal mode
.vector bh_decal_local_offset;
.vector bh_color;
.float  bh_half_size;
.float  bh_snow;
.float  bh_spawn_time;

// Tracked-polygon decal fields — used when the bullet target is a
// non-world brushmodel (func_breakable, func_door, func_button …).
// adddecal() only clips against the world model, so it can't render
// on submodels; we store hit-pos and hit-normal in the parent's
// LOCAL space at impact time and rebuild a world-space quad each
// frame from the parent's current origin + angles.  This makes the
// decal visually attached to the surface — it follows door/button
// motion (and rotation), and is purged with the rest of the owner's
// decals when the breakable is destroyed.
.float  bh_tracked;          // TRUE = render via local-space polygon, not adddecal
.vector bh_track_local_pos;     // hit position in parent's local frame
.vector bh_track_local_normal;  // hit normal in parent's local frame

// Pre-baked polygon corners for STATIC (world-owned) holes. Computed
// once at spawn time by CSQC_BakeStaticBulletHoleQuad so the per-frame
// draw becomes "read 4 vectors, submit 4 vertices" instead of doing
// tangent-frame math + corner computation every frame. Brushmodel-owned
// holes (bh_tracked) don't use these fields — they need per-frame
// transform because the parent moves.
.vector bh_quad_p0;
.vector bh_quad_p1;
.vector bh_quad_p2;
.vector bh_quad_p3;
// Per-hole 4-way rotation index (0/1/2/3 = 0/90/180/270°). Set at
// spawn time so each decal has a different orientation around its
// surface normal (visual variety, breaks the "all aligned" look).
// For static holes the rotation is baked into bh_quad_p0..p3; for
// tracked (brushmodel) holes it's applied each frame in the draw.
// The legacy adddecal path uses the same value via hole.angles_z.
.float bh_quad_rot;

entity bh_head;
entity bh_tail;
entity bh_dyn_head;
entity bh_dyn_tail;
entity bh_pq_head;         // per-quad list head (see .bh_pq_next)
entity bh_pq_tail;
float  bh_count;
float  bh_frame_count;     // per-frame spawn cap
// Per-shot decal counter — incremented by CSQC_SpawnBulletHole and
// reset at the top of each penetrating-hitscan loop via
// CSQC_BulletHoles_ResetShot.  Capped by cl_bulletholes_per_shot
// (0 = unlimited; 1 = entry decal only, no penetration exits).
float  bh_per_shot_count;
// Shotgun blast bypass — set by CSQC_PredictedShotgunImpact around its
// pellet loop so cl_bulletholes_per_shot doesn't clip the spray.  See
// the spawn-site comment for the rationale.
float  bh_shotgun_blast;
// Latched after the FIRST pellet of a blast plays its ricochet sound
// so subsequent pellets stay silent — without this every pellet of a
// 9-pellet shotgun spray fires its own ric*.wav and the spray sounds
// like a wall of shrapnel rather than one blast.
float  bh_shotgun_ric_played;
// Reused point-entity for cl_bulletholes_pvs_check.  Spawning once at
// first use and re-positioning it per decal saves the spawn/remove
// overhead — FTE's checkpvs just consults the PVS bitmask leaf-by-leaf
// based on the entity's current absmin/absmax.
entity bh_pvs_test_ent;

// Per-frame cvar caches — populated by CSQC_BulletHolesStartFrame so the
// hot loop doesn't re-read these cvars per hole. The accessor functions
// below now return the cached value, which means at spawn time (later in
// the same frame, after StartFrame has run) we still see the fresh value.
// On the very first frame before StartFrame runs, the values are 0/1
// defaults — close enough for the brief startup window.
float bh_cache_enabled;     // cl_bulletholes > 0
float bh_cache_opacity;     // bound(0, cl_decal_opacity, 1)
float bh_cache_polygon;     // cl_bullethole_renderer != 0 (1 = polygon, 0 = legacy adddecal)
float bh_cache_max;         // cl_bulletholes_max — eviction cap
float bh_cache_dist_sq;     // cl_bullethole_distance squared (0 = LOD off)
float bh_cache_clip_geom;   // cl_bullethole_clip_geom != 0 (Source-style edge clip at spawn)

// Per-frame frustum-cull state — populated by CSQC_BulletHolesStartFrame.
// Used by the draw loop to skip holes that are clearly behind the camera
// (cheap dot-product test). The engine would later reject these too, but
// we save the QC dispatch + transform per off-screen hole.
vector bh_cache_cam_origin;
vector bh_cache_cam_forward;

// ============================================================
//  Trisoup batching — one addtrisoup_simple call per shader per
//  frame, instead of one R_BeginPolygon chain per hole.
//
//  v1 of this code rebuilt the entire trisoup buffer every frame
//  by walking every hole and calling a per-vertex append helper.
//  Profile showed that approach replaced ~6 cheap engine builtins
//  per hole with ~40 QC opcodes per hole — the QC interpreter
//  overhead won, and total cost actually went UP relative to the
//  per-hole R_BeginPolygon path it was meant to replace.
//
//  v2 (this code): static-world hole vertices are written ONCE at
//  spawn time and live in the buffer until the hole is evicted /
//  WipeAll'd. Per frame the static portion costs zero work — the
//  same vertex data from last frame is just resubmitted with
//  addtrisoup_simple. Tracked (brushmodel-owned) holes still
//  pay per-frame work (their owner moves) and append at the
//  end of the buffer each frame.
//
//  Slot management: each hole entity stores its slot index in
//  .bh_slot. On remove the slot is zeroed (degenerate quad — GPU
//  draws nothing) and pushed onto a per-shader free list so the
//  next spawn reuses it instead of growing the buffer forever.
// ============================================================
// Bumped from the prior 1024 cap.  Decal accumulation across a long
// match commonly tops 1024 on de_dust-class maps; 2048 fits the
// realistic worst case without needing `auto` (fteqcc rev 6202 lacks
// the keyword, and src/qcc.cfg already raises MAX_REGS to 1M so the
// extra ~37k compile-time slots fit comfortably).
const int BH_TRISOUP_MAX_QUADS = 2048;

// Per-entity slot index into the trisoup buffer. -1 sentinel
// means "not in any buffer" (e.g. tracked holes that share the
// dynamic suffix, or holes that lost the slot race when the
// buffer was full).
.float bh_slot;

// Per-hole shader override path.  Empty/zero string means "use the
// default gfx/bullethole shader and the cached batched fast path".
// Non-empty means a per-material decal (gfx/decals/impacts/wood2 etc.):
// these holes skip the batched buffer entirely and submit a one-quad
// addtrisoup_simple call from the per-frame draw path.  Bounded cost
// because bh_count is capped by cl_bulletholes_max — a few extra draw
// calls per frame is irrelevant on modern GPUs.
.string bh_shader_path;

// Scratch verts/idx for per-hole addtrisoup_simple submits — declared
// at file scope so the per-frame draw path doesn't allocate.  Six
// indices form two CCW tris per quad, matching BH_WriteQuad's layout.
trisoup_simple_vert_t bh_scratch_verts[4];
int                   bh_scratch_idx[6];

// One-time init for bh_scratch_idx (indices never change — the four
// scratch verts are always wound the same way).
float bh_scratch_idx_initialised;
void() BH_InitScratchIdx =
{
    if (bh_scratch_idx_initialised) return;
    bh_scratch_idx[0] = 0; bh_scratch_idx[1] = 1; bh_scratch_idx[2] = 2;
    bh_scratch_idx[3] = 0; bh_scratch_idx[4] = 2; bh_scratch_idx[5] = 3;
    bh_scratch_idx_initialised = 1;
};

// Submit one quad as its own draw call against an arbitrary shader.
// Used by tracked / world holes carrying a non-default bh_shader_path.
void(string shader_path,
     vector p0, vector p1, vector p2, vector p3,
     vector col, float alpha) BH_SubmitOneQuad =
{
    BH_InitScratchIdx();

    bh_scratch_verts[0].xyz[0] = p0_x; bh_scratch_verts[0].xyz[1] = p0_y; bh_scratch_verts[0].xyz[2] = p0_z;
    bh_scratch_verts[0].st[0]  = 0;    bh_scratch_verts[0].st[1]  = 1;
    bh_scratch_verts[0].rgba[0] = col_x; bh_scratch_verts[0].rgba[1] = col_y; bh_scratch_verts[0].rgba[2] = col_z; bh_scratch_verts[0].rgba[3] = alpha;

    bh_scratch_verts[1].xyz[0] = p1_x; bh_scratch_verts[1].xyz[1] = p1_y; bh_scratch_verts[1].xyz[2] = p1_z;
    bh_scratch_verts[1].st[0]  = 1;    bh_scratch_verts[1].st[1]  = 1;
    bh_scratch_verts[1].rgba[0] = col_x; bh_scratch_verts[1].rgba[1] = col_y; bh_scratch_verts[1].rgba[2] = col_z; bh_scratch_verts[1].rgba[3] = alpha;

    bh_scratch_verts[2].xyz[0] = p2_x; bh_scratch_verts[2].xyz[1] = p2_y; bh_scratch_verts[2].xyz[2] = p2_z;
    bh_scratch_verts[2].st[0]  = 1;    bh_scratch_verts[2].st[1]  = 0;
    bh_scratch_verts[2].rgba[0] = col_x; bh_scratch_verts[2].rgba[1] = col_y; bh_scratch_verts[2].rgba[2] = col_z; bh_scratch_verts[2].rgba[3] = alpha;

    bh_scratch_verts[3].xyz[0] = p3_x; bh_scratch_verts[3].xyz[1] = p3_y; bh_scratch_verts[3].xyz[2] = p3_z;
    bh_scratch_verts[3].st[0]  = 0;    bh_scratch_verts[3].st[1]  = 0;
    bh_scratch_verts[3].rgba[0] = col_x; bh_scratch_verts[3].rgba[1] = col_y; bh_scratch_verts[3].rgba[2] = col_z; bh_scratch_verts[3].rgba[3] = alpha;

    addtrisoup_simple(shader_path, 0, &bh_scratch_verts[0], &bh_scratch_idx[0], 6);
};

// Material-variant tables.  Random index picked at spawn time.
// Concrete is also the fallback for IMPACT_MAT_DEFAULT — world hits on
// brushwork without an explicit breakable still use the same look as
// concrete breakables.  Counts must match what's in gfx/decals/impacts/.
const float BH_MAT_CONC_COUNT  = 5;
const float BH_MAT_WOOD_COUNT  = 4;
const float BH_MAT_METAL_COUNT = 2;
const float BH_MAT_GLASS_COUNT = 5;

// Persistent shader-path strings, populated at init.  Storing them
// here keeps the picker free of sprintf tempstrings on every spawn —
// matters because the picker is in the bullet-hit hot path and we'd
// otherwise be churning the temp-string pool.
string bh_mat_path_conc[5];
string bh_mat_path_wood[4];
string bh_mat_path_metal[2];
string bh_mat_path_glass[5];

// Splat-variant table.  Used by BOTH snow splats (CSQC_SpawnSnowSplat)
// and paintball splats (CSQC_SpawnPaintSplat) — same 9 textures, random
// pick per splat for visual variety.  Populated at init by the
// precache_pic loop in CSQC_BulletHolesInit (same pattern as the
// material decal paths above).
const float BH_SPLAT_COUNT = 9;
string bh_splat_path[9];

// File-scope I/O slots for BH_ClipQuadToHitTri / BH_Sample4 / BH_WriteQuadUV.
// Passing UVs + triangle verts + surface normal as function args overflows
// fteqcc's parameter slot limit (the prior 12-vec3 signature crashed the
// compiler).  Using globals keeps the function frames flat; CSQC is
// single-threaded so there's no race risk inside one bake call.
// Declared individually (not via comma-separated `vector a, b, c`) AND
// before BH_WriteQuadUV so fteqcc has the _x/_y component accessors
// in scope at the use sites.
vector bh_io_uv0;
vector bh_io_uv1;
vector bh_io_uv2;
vector bh_io_uv3;
vector bh_io_tv0;
vector bh_io_tv1;
vector bh_io_tv2;
vector bh_io_sn;
// Hit surface + triangle index — read by BH_ClipQuadToHitTri to walk
// the surface's other triangles and detect shared (internal) edges
// that shouldn't actually clip the decal.  BSP surfaces are flat by
// construction, so any edge shared between two triangles within the
// SAME surface is interior to a coplanar region (e.g. the diagonal
// of a quad-split-into-2-triangles); clipping the decal there
// produces a wrong-looking cut on what is really a flat wall.
float bh_io_surf;
float bh_io_hit_tri;

auto trisoup_simple_vert_t bh_bullet_verts[BH_TRISOUP_MAX_QUADS * 4];
auto int                   bh_bullet_idx  [BH_TRISOUP_MAX_QUADS * 6];
int                   bh_bullet_static_count;          // high-water mark of static slots
int                   bh_bullet_count;                 // submit count (static + per-frame dyn)
auto int                   bh_bullet_free[BH_TRISOUP_MAX_QUADS];
int                   bh_bullet_free_count;

auto trisoup_simple_vert_t bh_snow_verts  [BH_TRISOUP_MAX_QUADS * 4];
auto int                   bh_snow_idx    [BH_TRISOUP_MAX_QUADS * 6];
int                   bh_snow_static_count;
int                   bh_snow_count;
auto int                   bh_snow_free[BH_TRISOUP_MAX_QUADS];
int                   bh_snow_free_count;

// Write one quad's worth of vertex+index data at the given slot.
// Inlined per-vertex assignment (no helper-function calls) — the
// QC interpreter overhead of nested calls was a measurable hot
// spot in v1. Caller is responsible for picking the right buffer
// and ensuring slot < BH_TRISOUP_MAX_QUADS.
void(int slot, vector p0, vector p1, vector p2, vector p3,
     vector col, float alpha,
     trisoup_simple_vert_t *verts, int *idx) BH_WriteQuad =
{
    int vbase = slot * 4;
    int ibase = slot * 6;

    verts[vbase + 0].xyz[0] = p0_x; verts[vbase + 0].xyz[1] = p0_y; verts[vbase + 0].xyz[2] = p0_z;
    verts[vbase + 0].st[0]  = 0;    verts[vbase + 0].st[1]  = 1;
    verts[vbase + 0].rgba[0] = col_x; verts[vbase + 0].rgba[1] = col_y; verts[vbase + 0].rgba[2] = col_z; verts[vbase + 0].rgba[3] = alpha;

    verts[vbase + 1].xyz[0] = p1_x; verts[vbase + 1].xyz[1] = p1_y; verts[vbase + 1].xyz[2] = p1_z;
    verts[vbase + 1].st[0]  = 1;    verts[vbase + 1].st[1]  = 1;
    verts[vbase + 1].rgba[0] = col_x; verts[vbase + 1].rgba[1] = col_y; verts[vbase + 1].rgba[2] = col_z; verts[vbase + 1].rgba[3] = alpha;

    verts[vbase + 2].xyz[0] = p2_x; verts[vbase + 2].xyz[1] = p2_y; verts[vbase + 2].xyz[2] = p2_z;
    verts[vbase + 2].st[0]  = 1;    verts[vbase + 2].st[1]  = 0;
    verts[vbase + 2].rgba[0] = col_x; verts[vbase + 2].rgba[1] = col_y; verts[vbase + 2].rgba[2] = col_z; verts[vbase + 2].rgba[3] = alpha;

    verts[vbase + 3].xyz[0] = p3_x; verts[vbase + 3].xyz[1] = p3_y; verts[vbase + 3].xyz[2] = p3_z;
    verts[vbase + 3].st[0]  = 0;    verts[vbase + 3].st[1]  = 0;
    verts[vbase + 3].rgba[0] = col_x; verts[vbase + 3].rgba[1] = col_y; verts[vbase + 3].rgba[2] = col_z; verts[vbase + 3].rgba[3] = alpha;

    idx[ibase + 0] = vbase + 0;
    idx[ibase + 1] = vbase + 1;
    idx[ibase + 2] = vbase + 2;
    idx[ibase + 3] = vbase + 0;
    idx[ibase + 4] = vbase + 2;
    idx[ibase + 5] = vbase + 3;
};

// Write one quad's vertex+index data using per-vert UVs read from the
// file-scope bh_io_uv0..3 globals.  Same signature as BH_WriteQuad
// (avoids exploding the parameter count); only difference is the .st
// fields come from the UV globals instead of hard-coded literals.
// Used by the clip-geom path so the rendered fragment shows the
// surviving slice of the bullet-hole texture, not the full image
// squeezed into the clipped shape.
void(int slot, vector p0, vector p1, vector p2, vector p3,
     vector col, float alpha,
     trisoup_simple_vert_t *verts, int *idx) BH_WriteQuadUV =
{
    int vbase = slot * 4;
    int ibase = slot * 6;

    verts[vbase + 0].xyz[0] = p0_x; verts[vbase + 0].xyz[1] = p0_y; verts[vbase + 0].xyz[2] = p0_z;
    verts[vbase + 0].st[0]  = bh_io_uv0_x; verts[vbase + 0].st[1]  = bh_io_uv0_y;
    verts[vbase + 0].rgba[0] = col_x; verts[vbase + 0].rgba[1] = col_y; verts[vbase + 0].rgba[2] = col_z; verts[vbase + 0].rgba[3] = alpha;

    verts[vbase + 1].xyz[0] = p1_x; verts[vbase + 1].xyz[1] = p1_y; verts[vbase + 1].xyz[2] = p1_z;
    verts[vbase + 1].st[0]  = bh_io_uv1_x; verts[vbase + 1].st[1]  = bh_io_uv1_y;
    verts[vbase + 1].rgba[0] = col_x; verts[vbase + 1].rgba[1] = col_y; verts[vbase + 1].rgba[2] = col_z; verts[vbase + 1].rgba[3] = alpha;

    verts[vbase + 2].xyz[0] = p2_x; verts[vbase + 2].xyz[1] = p2_y; verts[vbase + 2].xyz[2] = p2_z;
    verts[vbase + 2].st[0]  = bh_io_uv2_x; verts[vbase + 2].st[1]  = bh_io_uv2_y;
    verts[vbase + 2].rgba[0] = col_x; verts[vbase + 2].rgba[1] = col_y; verts[vbase + 2].rgba[2] = col_z; verts[vbase + 2].rgba[3] = alpha;

    verts[vbase + 3].xyz[0] = p3_x; verts[vbase + 3].xyz[1] = p3_y; verts[vbase + 3].xyz[2] = p3_z;
    verts[vbase + 3].st[0]  = bh_io_uv3_x; verts[vbase + 3].st[1]  = bh_io_uv3_y;
    verts[vbase + 3].rgba[0] = col_x; verts[vbase + 3].rgba[1] = col_y; verts[vbase + 3].rgba[2] = col_z; verts[vbase + 3].rgba[3] = alpha;

    idx[ibase + 0] = vbase + 0;
    idx[ibase + 1] = vbase + 1;
    idx[ibase + 2] = vbase + 2;
    idx[ibase + 3] = vbase + 0;
    idx[ibase + 4] = vbase + 2;
    idx[ibase + 5] = vbase + 3;
};

// UV-aware static slot allocator — same slot-pool logic as
// BH_AllocStaticSlot but routes through BH_WriteQuadUV so the
// bh_io_uv0..3 globals supply the texture coords.  Caller is
// responsible for setting bh_io_uv0..3 before invoking this.
float(entity hole, vector p0, vector p1, vector p2, vector p3,
      vector col, float alpha) BH_AllocStaticSlotUV =
{
    int slot;
    if (hole.bh_snow)
    {
        if (bh_snow_free_count > 0)
        {
            bh_snow_free_count = bh_snow_free_count - 1;
            slot = bh_snow_free[bh_snow_free_count];
        }
        else
        {
            if (bh_snow_static_count >= BH_TRISOUP_MAX_QUADS)
                return -1;
            slot = bh_snow_static_count;
            bh_snow_static_count = bh_snow_static_count + 1;
        }
        BH_WriteQuadUV(slot, p0, p1, p2, p3,
                       col, alpha, &bh_snow_verts[0], &bh_snow_idx[0]);
    }
    else
    {
        if (bh_bullet_free_count > 0)
        {
            bh_bullet_free_count = bh_bullet_free_count - 1;
            slot = bh_bullet_free[bh_bullet_free_count];
        }
        else
        {
            if (bh_bullet_static_count >= BH_TRISOUP_MAX_QUADS)
                return -1;
            slot = bh_bullet_static_count;
            bh_bullet_static_count = bh_bullet_static_count + 1;
        }
        BH_WriteQuadUV(slot, p0, p1, p2, p3,
                       col, alpha, &bh_bullet_verts[0], &bh_bullet_idx[0]);
    }
    return slot;
};

// Allocate a slot for a new STATIC hole and write its vertices
// once. Returns the slot index (or -1 if buffer is full and no
// free slot is available). The slot persists across frames; the
// entity records it in .bh_slot so the per-remove path can free
// it later. Called from CSQC_SpawnBulletHole when the hole
// belongs to world geometry and polygon-renderer mode is on.
float(entity hole, vector p0, vector p1, vector p2, vector p3,
      vector col, float alpha) BH_AllocStaticSlot =
{
    int slot;
    if (hole.bh_snow)
    {
        if (bh_snow_free_count > 0)
        {
            bh_snow_free_count = bh_snow_free_count - 1;
            slot = bh_snow_free[bh_snow_free_count];
        }
        else
        {
            if (bh_snow_static_count >= BH_TRISOUP_MAX_QUADS)
                return -1;
            slot = bh_snow_static_count;
            bh_snow_static_count = bh_snow_static_count + 1;
        }
        BH_WriteQuad(slot, p0, p1, p2, p3, col, alpha,
                     &bh_snow_verts[0], &bh_snow_idx[0]);
    }
    else
    {
        if (bh_bullet_free_count > 0)
        {
            bh_bullet_free_count = bh_bullet_free_count - 1;
            slot = bh_bullet_free[bh_bullet_free_count];
        }
        else
        {
            if (bh_bullet_static_count >= BH_TRISOUP_MAX_QUADS)
                return -1;
            slot = bh_bullet_static_count;
            bh_bullet_static_count = bh_bullet_static_count + 1;
        }
        BH_WriteQuad(slot, p0, p1, p2, p3, col, alpha,
                     &bh_bullet_verts[0], &bh_bullet_idx[0]);
    }
    return slot;
};

// Free a static hole's slot — degenerates the quad (sets all 4
// vertex alphas to 0 so the GPU effectively skips it) and pushes
// the slot index onto the per-shader free list for reuse. Called
// from CSQC_BulletHoleRemove. Cheap (8 array writes + 1 push).
void(entity hole) BH_FreeStaticSlot =
{
    if (hole.bh_slot < 0) return;
    int slot = (int)hole.bh_slot;
    int vbase = slot * 4;
    if (hole.bh_snow)
    {
        bh_snow_verts[vbase + 0].rgba[3] = 0;
        bh_snow_verts[vbase + 1].rgba[3] = 0;
        bh_snow_verts[vbase + 2].rgba[3] = 0;
        bh_snow_verts[vbase + 3].rgba[3] = 0;
        bh_snow_free[bh_snow_free_count] = slot;
        bh_snow_free_count = bh_snow_free_count + 1;
    }
    else
    {
        bh_bullet_verts[vbase + 0].rgba[3] = 0;
        bh_bullet_verts[vbase + 1].rgba[3] = 0;
        bh_bullet_verts[vbase + 2].rgba[3] = 0;
        bh_bullet_verts[vbase + 3].rgba[3] = 0;
        bh_bullet_free[bh_bullet_free_count] = slot;
        bh_bullet_free_count = bh_bullet_free_count + 1;
    }
    hole.bh_slot = -1;
};

// Per-frame append for tracked (brushmodel-owned) holes — they
// can't be cached because their owner moves, so we recompute
// world-space corners every frame and append at the end of the
// already-cached static portion of the buffer. Returns silently
// if no headroom (static portion has filled the entire buffer).
void(float is_snow, vector p0, vector p1, vector p2, vector p3,
     vector col, float alpha) BH_AppendDynamicQuad =
{
    if (is_snow)
    {
        if (bh_snow_count >= BH_TRISOUP_MAX_QUADS) return;
        BH_WriteQuad(bh_snow_count, p0, p1, p2, p3, col, alpha,
                     &bh_snow_verts[0], &bh_snow_idx[0]);
        bh_snow_count = bh_snow_count + 1;
    }
    else
    {
        if (bh_bullet_count >= BH_TRISOUP_MAX_QUADS) return;
        BH_WriteQuad(bh_bullet_count, p0, p1, p2, p3, col, alpha,
                     &bh_bullet_verts[0], &bh_bullet_idx[0]);
        bh_bullet_count = bh_bullet_count + 1;
    }
};

// === Decal clip-at-spawn against hit BSP triangle ==========================
// Replicates the spirit of Source engine's edge-clipped decals so quads
// stop overhanging surface edges, without changing the per-frame render
// path (renderer 1's batched addtrisoup_simple submit is preserved).
//
// Approach: at spawn, look up the hit BSP surface via getsurfacenearpoint,
// pick the triangle whose centroid is closest to hit_pos, then run a
// Sutherland-Hodgman clip of the 4-vert decal quad against that triangle's
// 3 edge planes.  The clip output is 3–7 verts; we cap to 4 by sampling
// evenly around the result so the existing fixed-stride 4-vert / 6-index
// buffer slot layout still fits (expanding to multi-fragment storage would
// blow the QC globals budget — verified empirically while implementing
// rain batching).
//
// Limits: single-fragment (decals spanning multiple triangles only get the
// closest-tri's edges) and skipped on tracked (brushmodel-owned) holes.
// Both follow-ups can land later once the global budget is freed up.
const float BH_CLIP_BUF_MAX     = 12;
const float BH_MAX_SURFACE_TRIS = 128;   // skip huge tessellated patches

// Ping-pong work buffers — file scope because fteqcc treats array locals
// as globals; reusing module-scope buffers keeps the QC global count flat.
// Safe because CSQC is single-threaded and clipping runs to completion
// inside one bake call.
//
// Parallel UV buffers carry the texture coordinate for each vertex.
// When a new vertex is introduced at a plane intersection during the
// Sutherland-Hodgman clip, its UV is interpolated with the SAME t
// parameter used to interpolate position.  This makes the rendered
// decal show the actual surviving slice of the texture instead of
// the full image squeezed into the clipped quad.  UV is stored as
// vec3 with z=0 (CSQC vectors are vec3-only — the .st field at write
// time only uses .x and .y).
vector bh_clip_buf_a[12];
vector bh_clip_buf_b[12];
vector bh_clip_uv_a [12];
vector bh_clip_uv_b [12];

// (bh_io_* declarations were moved earlier in the file so the
// _x / _y component accessors are defined before BH_WriteQuadUV uses
// them; see the block before BH_WriteQuad.)

// Clip a polygon against one half-space (plane defined by a point on it
// + inward-facing normal).  Vertex is KEPT when (v - plane_pt) · plane_n
// >= 0.  Reads from src/src_uv[0..src_n), writes to dst/dst_uv[0..returned_count).
// UVs are interpolated with the SAME t parameter used for positions so
// the texture coords stay in lockstep with the geometry across the clip.
float(vector *src, float src_n, vector *dst,
      vector *src_uv, vector *dst_uv,
      vector plane_pt, vector plane_n) BH_ClipPolyToPlane =
{
    if (src_n < 3) return 0;
    float dst_n = 0;
    vector prev    = src   [(int)src_n - 1];
    vector prev_uv = src_uv[(int)src_n - 1];
    float  prev_d = (prev - plane_pt) * plane_n;
    float i;
    float t_split;
    for (i = 0; i < src_n; i = i + 1)
    {
        vector curr    = src   [(int)i];
        vector curr_uv = src_uv[(int)i];
        float  curr_d = (curr - plane_pt) * plane_n;
        if (curr_d >= 0)
        {
            if (prev_d < 0 && dst_n < BH_CLIP_BUF_MAX)
            {
                t_split = prev_d / (prev_d - curr_d);
                dst   [(int)dst_n] = prev    + (curr    - prev   ) * t_split;
                dst_uv[(int)dst_n] = prev_uv + (curr_uv - prev_uv) * t_split;
                dst_n = dst_n + 1;
            }
            if (dst_n < BH_CLIP_BUF_MAX)
            {
                dst   [(int)dst_n] = curr;
                dst_uv[(int)dst_n] = curr_uv;
                dst_n = dst_n + 1;
            }
        }
        else if (prev_d >= 0 && dst_n < BH_CLIP_BUF_MAX)
        {
            t_split = prev_d / (prev_d - curr_d);
            dst   [(int)dst_n] = prev    + (curr    - prev   ) * t_split;
            dst_uv[(int)dst_n] = prev_uv + (curr_uv - prev_uv) * t_split;
            dst_n = dst_n + 1;
        }
        prev    = curr;
        prev_uv = curr_uv;
        prev_d  = curr_d;
    }
    return dst_n;
};

// Return 1 if undirected edge (a,b) matches undirected edge (c,d).
// Used by BH_HitTriEdgeShared to compare triangle edges regardless of
// which direction each triangle stores its vertex order.
float(float a, float b, float c, float d) BH_EdgeEq =
{
    return ((a == c) && (b == d)) || ((a == d) && (b == c));
};

// Is the edge (ea,eb) of the hit triangle ALSO an edge of any OTHER
// triangle on the same surface?  BSP surfaces are flat (all triangles
// in one surface are coplanar by construction), so shared edges within
// a surface are interior cuts created by the tessellation — they
// shouldn't clip the decal.  Returns 1 if shared (skip clip), 0 if
// the edge is on the surface outline (do clip).
float(entity ent, float surf, float self_tri, float ea, float eb) BH_HitTriEdgeShared =
{
    float ntri = getsurfacenumtriangles(ent, surf);
    float t;
    for (t = 0; t < ntri; t = t + 1)
    {
        if (t == self_tri) continue;
        vector idx = getsurfacetriangle(ent, surf, t);
        float ta = idx_x;
        float tb = idx_y;
        float tc = idx_z;
        if (BH_EdgeEq(ea, eb, ta, tb)) return 1;
        if (BH_EdgeEq(ea, eb, tb, tc)) return 1;
        if (BH_EdgeEq(ea, eb, tc, ta)) return 1;
    }
    return 0;
};

// Build inward-facing clip plane normal for triangle edge e_v0 → e_v1.
// `third` is the triangle's third vertex; the plane is oriented so it's
// on the positive side.
vector(vector e_v0, vector e_v1, vector third, vector surf_n) BH_EdgePlaneNormal =
{
    vector edge_dir = e_v1 - e_v0;
    vector pn = crossproduct(surf_n, edge_dir);
    if (((third - e_v0) * pn) < 0)
        pn = -pn;
    return pn;
};

// Find the triangle in `surf` whose centroid is closest to hit_pos.
// Returns -1 if no usable triangle (zero-tri surface, or surface tri
// count exceeds BH_MAX_SURFACE_TRIS — skip-clip fallback).
float(entity ent, float surf, vector hit_pos) BH_FindHitTriangle =
{
    float ntri = getsurfacenumtriangles(ent, surf);
    if (ntri <= 0) return -1;
    if (ntri > BH_MAX_SURFACE_TRIS) return -1;
    float best = -1;
    float best_d2 = 1000000000;   // 1e9 — bigger than any sane qu² distance
    float t;
    for (t = 0; t < ntri; t = t + 1)
    {
        vector idx = getsurfacetriangle(ent, surf, t);
        vector v0 = getsurfacepoint(ent, surf, idx_x);
        vector v1 = getsurfacepoint(ent, surf, idx_y);
        vector v2 = getsurfacepoint(ent, surf, idx_z);
        vector c  = (v0 + v1 + v2) * (1.0 / 3.0);
        vector d  = c - hit_pos;
        float  d2 = d * d;
        if (d2 < best_d2)
        {
            best_d2 = d2;
            best    = t;
        }
    }
    return best;
};

// Sample 4 verts evenly from a polygon of n>4 verts so the clipped shape
// still fits in the 4-vert quad slot.  Picks indices [0, n/4, n/2, 3n/4]
// in increasing order — Sutherland-Hodgman preserves CCW winding, so
// the resulting 4-vert quad is also CCW.  UVs written back via the
// file-scope bh_io_uv0..3 globals to keep the parameter slot count
// within fteqcc's limit.
void(vector *src, vector *src_uv, float n,
     __out vector o0,  __out vector o1,  __out vector o2,  __out vector o3) BH_Sample4 =
{
    float i1 = floor(n * 0.25);
    float i2 = floor(n * 0.5);
    float i3 = floor(n * 0.75);
    if (i1 < 1) i1 = 1;
    if (i2 <= i1) i2 = i1 + 1;
    if (i3 <= i2) i3 = i2 + 1;
    if (i3 >= n) i3 = n - 1;
    o0  = src   [0];
    o1  = src   [(int)i1];
    o2  = src   [(int)i2];
    o3  = src   [(int)i3];
    bh_io_uv0 = src_uv[0];
    bh_io_uv1 = src_uv[(int)i1];
    bh_io_uv2 = src_uv[(int)i2];
    bh_io_uv3 = src_uv[(int)i3];
};

// Clip a 4-vert quad against a triangle's 3 edges, propagating UVs
// alongside positions.  UVs/tri-verts/surf-normal come in via the
// file-scope bh_io_* globals (parameter-slot count from passing them
// as args overflows fteqcc); the function reads them, performs the
// clip, and writes the resulting per-vert UVs back to the same
// globals.  Position outputs go via __inout args as before.
//
// Caller sets:  bh_io_uv0..3   = starting UVs (0,1)(1,1)(1,0)(0,0)
//               bh_io_tv0..2   = triangle vertices
//               bh_io_sn       = surface plane normal
// Caller reads: q0..q3         = clipped positions (via __inout)
//               bh_io_uv0..3   = clipped UVs (overwritten in-place)
//
// Returns 1 on success, 0 if the result is degenerate — caller falls
// back to the un-clipped original (q0..q3 and bh_io_uv0..3 untouched).
float(__inout vector q0, __inout vector q1, __inout vector q2, __inout vector q3) BH_ClipQuadToHitTri =
{
    // Resolve the hit triangle's vertex indices once so we can detect
    // which of its 3 edges are SHARED with other triangles on the same
    // surface.  Shared edges = interior cuts in a flat region (BSP
    // surfaces are coplanar by construction), and clipping the decal
    // against them produces visible cuts on what should be flat
    // geometry.  Outline edges (not shared with any other tri in the
    // surface) are real surface boundaries — those we DO clip against.
    vector hit_idx = getsurfacetriangle(world, bh_io_surf, bh_io_hit_tri);
    float  ia = hit_idx_x, ib = hit_idx_y, ic = hit_idx_z;

    // Edges of the hit triangle, with their (from, to) vertex indices
    // and the third (opposite) vertex used for inward-normal orient.
    vector edges_v0[3];
    vector edges_v1[3];
    vector edges_third[3];
    float  edges_idx_a[3];
    float  edges_idx_b[3];
    edges_v0[0] = bh_io_tv0; edges_v1[0] = bh_io_tv1; edges_third[0] = bh_io_tv2;
    edges_v0[1] = bh_io_tv1; edges_v1[1] = bh_io_tv2; edges_third[1] = bh_io_tv0;
    edges_v0[2] = bh_io_tv2; edges_v1[2] = bh_io_tv0; edges_third[2] = bh_io_tv1;
    edges_idx_a[0] = ia; edges_idx_b[0] = ib;
    edges_idx_a[1] = ib; edges_idx_b[1] = ic;
    edges_idx_a[2] = ic; edges_idx_b[2] = ia;

    // Build the active-edge mask: bit e is set when edge e is an
    // outline edge (= NOT shared with another triangle in the same
    // surface).  If no edges qualify, the decal is sitting inside a
    // tessellated flat region and clipping would only carve away the
    // original quad with no real benefit — return 0 so the caller
    // keeps the un-clipped axis-aligned quad.
    float active_mask = 0;
    float e;
    for (e = 0; e < 3; e = e + 1)
    {
        if (!BH_HitTriEdgeShared(world, bh_io_surf, bh_io_hit_tri,
                                 edges_idx_a[(int)e], edges_idx_b[(int)e]))
            active_mask = active_mask + (1 << (int)e);
    }
    if (active_mask == 0)
        return 0;

    bh_clip_buf_a[0] = q0;          bh_clip_buf_a[1] = q1;
    bh_clip_buf_a[2] = q2;          bh_clip_buf_a[3] = q3;
    bh_clip_uv_a [0] = bh_io_uv0;   bh_clip_uv_a [1] = bh_io_uv1;
    bh_clip_uv_a [2] = bh_io_uv2;   bh_clip_uv_a [3] = bh_io_uv3;
    float n = 4;
    float use_b = 0;

    // Clip ONLY against the outline (unshared) edges.  Internal cuts
    // (the diagonal of a quad split into 2 tris, etc.) are skipped so
    // a decal centred on the diagonal stays intact.
    for (e = 0; e < 3; e = e + 1)
    {
        if (!(active_mask & (1 << (int)e)))
            continue;
        vector pn = BH_EdgePlaneNormal(edges_v0[(int)e], edges_v1[(int)e],
                                       edges_third[(int)e], bh_io_sn);
        if (use_b)
            n = BH_ClipPolyToPlane(&bh_clip_buf_b[0], n, &bh_clip_buf_a[0],
                                   &bh_clip_uv_b [0],    &bh_clip_uv_a [0],
                                   edges_v0[(int)e], pn);
        else
            n = BH_ClipPolyToPlane(&bh_clip_buf_a[0], n, &bh_clip_buf_b[0],
                                   &bh_clip_uv_a [0],    &bh_clip_uv_b [0],
                                   edges_v0[(int)e], pn);
        use_b = !use_b;
        if (n < 3) return 0;
    }

    // Result lives in the buffer NOT pointed at by use_b (since use_b
    // already toggled past the final write).  Sample 4 verts back into
    // q0..q3 and 4 UVs back into bh_io_uv0..3 (BH_Sample4 writes UVs
    // via the same globals).
    if (use_b)
    {
        if (n == 3)
        {
            q0 = bh_clip_buf_b[0]; q1 = bh_clip_buf_b[1]; q2 = bh_clip_buf_b[2]; q3 = bh_clip_buf_b[2];
            bh_io_uv0 = bh_clip_uv_b[0]; bh_io_uv1 = bh_clip_uv_b[1];
            bh_io_uv2 = bh_clip_uv_b[2]; bh_io_uv3 = bh_clip_uv_b[2];
        }
        else if (n == 4)
        {
            q0 = bh_clip_buf_b[0]; q1 = bh_clip_buf_b[1]; q2 = bh_clip_buf_b[2]; q3 = bh_clip_buf_b[3];
            bh_io_uv0 = bh_clip_uv_b[0]; bh_io_uv1 = bh_clip_uv_b[1];
            bh_io_uv2 = bh_clip_uv_b[2]; bh_io_uv3 = bh_clip_uv_b[3];
        }
        else
            BH_Sample4(&bh_clip_buf_b[0], &bh_clip_uv_b[0], n, q0, q1, q2, q3);
    }
    else
    {
        if (n == 3)
        {
            q0 = bh_clip_buf_a[0]; q1 = bh_clip_buf_a[1]; q2 = bh_clip_buf_a[2]; q3 = bh_clip_buf_a[2];
            bh_io_uv0 = bh_clip_uv_a[0]; bh_io_uv1 = bh_clip_uv_a[1];
            bh_io_uv2 = bh_clip_uv_a[2]; bh_io_uv3 = bh_clip_uv_a[2];
        }
        else if (n == 4)
        {
            q0 = bh_clip_buf_a[0]; q1 = bh_clip_buf_a[1]; q2 = bh_clip_buf_a[2]; q3 = bh_clip_buf_a[3];
            bh_io_uv0 = bh_clip_uv_a[0]; bh_io_uv1 = bh_clip_uv_a[1];
            bh_io_uv2 = bh_clip_uv_a[2]; bh_io_uv3 = bh_clip_uv_a[3];
        }
        else
            BH_Sample4(&bh_clip_buf_a[0], &bh_clip_uv_a[0], n, q0, q1, q2, q3);
    }
    return 1;
};

float() CSQC_BulletHolesEnabled =
{
    return bh_cache_enabled;
};

float() CSQC_DecalOpacity =
{
    return bh_cache_opacity;
};

// --- Remove a hole from the linked list ---
void(entity hole) CSQC_BulletHoleRemove =
{
    if (hole.bh_dynamic)
    {
        if (hole == bh_dyn_head)
            bh_dyn_head = hole.bh_dyn_next;
        if (hole == bh_dyn_tail)
            bh_dyn_tail = hole.bh_dyn_prev;
        if (hole.bh_dyn_prev)
            hole.bh_dyn_prev.bh_dyn_next = hole.bh_dyn_next;
        if (hole.bh_dyn_next)
            hole.bh_dyn_next.bh_dyn_prev = hole.bh_dyn_prev;
    }
    // Per-quad list — static (world-hit) splats with bh_shader_path.
    // Detected by head pointer (any pq-listed hole satisfies head==hole
    // or has a non-world prev/next) — we don't carry an explicit
    // "linked into pq" flag, so a stray remove on a non-pq hole is
    // a cheap no-op via the head/tail/prev/next checks below.
    if (hole == bh_pq_head)
        bh_pq_head = hole.bh_pq_next;
    if (hole == bh_pq_tail)
        bh_pq_tail = hole.bh_pq_prev;
    if (hole.bh_pq_prev)
        hole.bh_pq_prev.bh_pq_next = hole.bh_pq_next;
    if (hole.bh_pq_next)
        hole.bh_pq_next.bh_pq_prev = hole.bh_pq_prev;

    if (hole == bh_head)
        bh_head = hole.bh_next;
    if (hole == bh_tail)
        bh_tail = hole.bh_prev;
    if (hole.bh_prev)
        hole.bh_prev.bh_next = hole.bh_next;
    if (hole.bh_next)
        hole.bh_next.bh_prev = hole.bh_prev;

    // Free the cached trisoup slot (no-op for tracked / non-cached
    // holes whose bh_slot stays at the -1 sentinel).
    BH_FreeStaticSlot(hole);

    remove(hole);
    bh_count -= 1;
};

// Remove any existing bullet hole / splat whose center lies within
// `decal_half_size * cl_bullethole_dedupe_scale` of `hit_pos`. Called
// from each spawn function so a new hole replaces an overlapping old
// one instead of stacking on top. Squared-distance check avoids sqrt
// in the loop. Works regardless of cl_bullethole_renderer mode —
// operates on the storage list, not the draw path.
//
// User-tunable via cl_bullethole_dedupe_scale:
//   0   → no dedupe (decals stack like before — old behaviour)
//   1   → default; ~half-overlap removes the old decal
//   2   → aggressive; any overlap (centers within full diameter) removes old
//   1.5 → middle ground; ~75% overlap triggers
void(vector hit_pos, float decal_half_size) CSQC_BulletHole_DedupeNearby =
{
    float scale = cvar("cl_bullethole_dedupe_scale");
    if (scale <= 0)
        return;
    float radius = decal_half_size * scale;
    float r2 = radius * radius;
    entity h, next;
    h = bh_head;
    while (h)
    {
        next = h.bh_next;
        vector d = h.bh_decal_origin - hit_pos;
        if ((d * d) < r2)
            CSQC_BulletHoleRemove(h);
        h = next;
    }
};

// --- Init (call from CSQC init) ---
void() CSQC_BulletHolesInit =
{
    bh_head = world;
    bh_tail = world;
    bh_dyn_head = world;
    bh_dyn_tail = world;
    bh_pq_head = world;
    bh_pq_tail = world;
    bh_count = 0;
    bh_frame_count = 0;
    precache_pic(BULLETHOLE_QUAD_SHADER);
    precache_pic(SNOWSPLAT_QUAD_SHADER);

    // Material decal variants (gfx/decals/impacts/...).  Precaching
    // returns a persistent shader-name string we cache so the picker
    // doesn't re-sprintf on every bullet hit.
    float i;
    for (i = 0; i < BH_MAT_CONC_COUNT; i++)
        bh_mat_path_conc[i]  = precache_pic(sprintf("gfx/decals/impacts/conc%g",  i + 1));
    for (i = 0; i < BH_MAT_WOOD_COUNT; i++)
        bh_mat_path_wood[i]  = precache_pic(sprintf("gfx/decals/impacts/wood%g",  i + 1));
    for (i = 0; i < BH_MAT_METAL_COUNT; i++)
        bh_mat_path_metal[i] = precache_pic(sprintf("gfx/decals/impacts/metal%g", i + 1));
    for (i = 0; i < BH_MAT_GLASS_COUNT; i++)
        bh_mat_path_glass[i] = precache_pic(sprintf("gfx/decals/impacts/glass%g", i + 1));

    // Splat variants — shared by paintball + snow splats.  Same
    // 9-PNG set drives both effects via random per-spawn pick.
    for (i = 0; i < BH_SPLAT_COUNT; i++)
        bh_splat_path[i] = precache_pic(sprintf("gfx/impacts/paintball/splat%g", i + 1));

    precache_model("models/props/barrel.iqm");
    precache_model("models/props/can.mdl");
    precache_model("gfx/fexplo.spr");       // CSQC_SpawnExplodeSprite (cl_bulletimpact.qc) — HL grenade fireball
};

// Pick a random variant shader path for the given IMPACT_MAT_* code,
// and write the matching half-size into *out_half_size.  Returns the
// empty string for materials we don't have art for (flesh / metal-
// nodecal) — caller falls back to the default bullethole shader.
string(float impact_mat, __out float out_half_size) BH_PickMaterialDecal =
{
    float idx;
    out_half_size = BULLETHOLE_MATERIAL_HALF_SIZE;
    if (impact_mat == IMPACT_MAT_GLASS)
    {
        idx = floor(random() * BH_MAT_GLASS_COUNT);
        if (idx < 0) idx = 0;
        if (idx >= BH_MAT_GLASS_COUNT) idx = BH_MAT_GLASS_COUNT - 1;
        out_half_size = BULLETHOLE_GLASS_HALF_SIZE;
        return bh_mat_path_glass[idx];
    }
    if (impact_mat == IMPACT_MAT_WOOD)
    {
        idx = floor(random() * BH_MAT_WOOD_COUNT);
        if (idx < 0) idx = 0;
        if (idx >= BH_MAT_WOOD_COUNT) idx = BH_MAT_WOOD_COUNT - 1;
        return bh_mat_path_wood[idx];
    }
    if (impact_mat == IMPACT_MAT_METAL)
    {
        idx = floor(random() * BH_MAT_METAL_COUNT);
        if (idx < 0) idx = 0;
        if (idx >= BH_MAT_METAL_COUNT) idx = BH_MAT_METAL_COUNT - 1;
        return bh_mat_path_metal[idx];
    }
    if (impact_mat == IMPACT_MAT_DEFAULT)
    {
        idx = floor(random() * BH_MAT_CONC_COUNT);
        if (idx < 0) idx = 0;
        if (idx >= BH_MAT_CONC_COUNT) idx = BH_MAT_CONC_COUNT - 1;
        return bh_mat_path_conc[idx];
    }
    return "";
};

// --- Wipe all bullet holes (round restart) ---
void() CSQC_BulletHolesWipeAll =
{
    entity hole, next;
    hole = bh_head;
    while (hole)
    {
        next = hole.bh_next;
        remove(hole);
        hole = next;
    }
    bh_head = world;
    bh_tail = world;
    bh_dyn_head = world;
    bh_dyn_tail = world;
    bh_pq_head = world;
    bh_pq_tail = world;
    bh_count = 0;

    // Reset the cached trisoup buffers — entire buffer is now empty,
    // free lists drained, high-water marks back to 0. Avoids leaving
    // stale (but degenerated) quads in the buffer after a round
    // restart and lets the next round start with a clean slot pool.
    bh_bullet_static_count = 0;
    bh_bullet_count        = 0;
    bh_bullet_free_count   = 0;
    bh_snow_static_count   = 0;
    bh_snow_count          = 0;
    bh_snow_free_count     = 0;
};

// --- Remove all bullet holes belonging to a specific entity ---
// Called when a func_breakable is destroyed so holes don't float in air.
void(entity owner_ent) CSQC_BulletHolesRemoveByOwner =
{
    entity hole, next;
    hole = bh_head;
    while (hole)
    {
        next = hole.bh_next;
        if (hole.owner == owner_ent)
            CSQC_BulletHoleRemove(hole);
        hole = next;
    }
};

void(entity hole) CSQC_DrawBulletHoleDecal =
{
    vector normal_arg, side_arg;
    vector decal_origin;
    float full_size;

    makevectors(hole.angles);

    // FTE's adddecal() docs call these "up" and "side", but the engine
    // treats the first vector as a surface-normal vector (negated before
    // clipping) and the second as a reciprocal texture axis.
    if (hole.bh_half_size > 0)
        full_size = hole.bh_half_size * 2;
    else if (hole.bh_snow)
        full_size = SNOWSPLAT_DECAL_HALF_SIZE * 2;
    else
        full_size = BULLETHOLE_DECAL_HALF_SIZE * 2;
    normal_arg = -v_forward;      // v_forward was built from -hit_normal
    side_arg = v_right / full_size;
    decal_origin = hole.bh_decal_origin + normal_arg * BULLETHOLE_DECAL_BIAS;

    // Pick the shader: per-variant if set (snow/paint splats carry
    // gfx/impacts/paintball/splatN), else the snow/bullet default.
    string shader_path = hole.bh_shader_path;
    if (!shader_path)
        shader_path = hole.bh_snow ? SNOWSPLAT_QUAD_SHADER
                                   : BULLETHOLE_QUAD_SHADER;
    adddecal(shader_path, decal_origin,
             normal_arg, side_arg, hole.bh_color,
             hole.alpha * CSQC_DecalOpacity());
};

// Pre-bake the four polygon corners for a static (world-owned) hole.
// Called ONCE at spawn time — the corners are constant for static
// holes (world doesn't move), so per-frame recomputation is wasted
// work. Mirrors the math at the bottom of CSQC_DrawTrackedBulletHole
// exactly. The draw path (CSQC_DrawBakedBulletHole) just reads the
// stored corners and submits vertices.
void(entity hole, vector hit_pos, vector hit_normal) CSQC_BakeStaticBulletHoleQuad =
{
    vector world_normal;
    if (vlen(hit_normal) <= 0.001)
    {
        // Degenerate normal — store zeroed corners; draw will short-circuit.
        hole.bh_quad_p0 = '0 0 0';
        hole.bh_quad_p1 = '0 0 0';
        hole.bh_quad_p2 = '0 0 0';
        hole.bh_quad_p3 = '0 0 0';
        return;
    }
    world_normal = normalize(hit_normal);

    // Build a tangent / bitangent frame from the normal. Pick a
    // reference axis that isn't parallel to the normal (otherwise
    // crossproduct degenerates), then orthonormalise.
    vector ref;
    if (fabs(world_normal_z) < 0.9)
        ref = '0 0 1';
    else
        ref = '1 0 0';
    vector tangent   = normalize(crossproduct(world_normal, ref));
    vector bitangent = crossproduct(world_normal, tangent);

    // 4-way rotation around the surface normal. Free at bake time —
    // just swap/negate the tangent + bitangent before computing
    // corners. No trig.
    float rot = hole.bh_quad_rot;
    if (rot == 1)
    {
        vector tmp1 = tangent;
        tangent = bitangent;
        bitangent = -tmp1;
    }
    else if (rot == 2)
    {
        tangent = -tangent;
        bitangent = -bitangent;
    }
    else if (rot == 3)
    {
        vector tmp3 = tangent;
        tangent = -bitangent;
        bitangent = tmp3;
    }

    float half = hole.bh_half_size > 0
                 ? hole.bh_half_size
                 : (hole.bh_snow ? SNOWSPLAT_DECAL_HALF_SIZE
                                 : BULLETHOLE_DECAL_HALF_SIZE);

    // Push slightly off the surface to avoid z-fighting.
    vector center = hit_pos + world_normal * 0.4;

    hole.bh_quad_p0 = center - tangent * half - bitangent * half;
    hole.bh_quad_p1 = center + tangent * half - bitangent * half;
    hole.bh_quad_p2 = center + tangent * half + bitangent * half;
    hole.bh_quad_p3 = center - tangent * half + bitangent * half;

    // Standard quad UVs seed the bh_io_uv* globals.  When the clip
    // runs, it propagates UVs through Sutherland-Hodgman so the
    // surviving fragment shows only the visible slice of the texture
    // (not the full image squeezed into the clipped shape).  When the
    // clip is skipped or fails, these defaults still hold and the
    // normal (0,1)(1,1)(1,0)(0,0) quad layout renders.
    bh_io_uv0 = '0 1 0';
    bh_io_uv1 = '1 1 0';
    bh_io_uv2 = '1 0 0';
    bh_io_uv3 = '0 0 0';
    float clipped = 0;

    // Source-style edge clip — cut the quad against the hit BSP
    // triangle's 3 edges so it conforms to the surface boundary
    // instead of overhanging.  One-shot per decal at spawn; the cost
    // (a handful of getsurface* calls + 3 plane clips) is paid once
    // and the per-frame render path is unchanged.  See the block
    // comment near BH_ClipPolyToPlane for the cap-at-4 fidelity
    // trade-off.
    if (bh_cache_clip_geom)
    {
        float surf = getsurfacenearpoint(world, hit_pos);
        if (surf >= 0)
        {
            float tri = BH_FindHitTriangle(world, surf, hit_pos);
            if (tri >= 0)
            {
                vector idx = getsurfacetriangle(world, surf, tri);
                bh_io_tv0 = getsurfacepoint(world, surf, idx_x);
                bh_io_tv1 = getsurfacepoint(world, surf, idx_y);
                bh_io_tv2 = getsurfacepoint(world, surf, idx_z);
                // Surface + triangle index handed to BH_ClipQuadToHitTri
                // so it can walk the neighbours and detect which of the
                // hit triangle's 3 edges are surface-outline vs internal
                // tessellation cuts.
                bh_io_surf    = surf;
                bh_io_hit_tri = tri;
                vector sn = getsurfacenormal(world, surf);
                if (vlen(sn) > 0.001)
                {
                    bh_io_sn = normalize(sn);
                    // Clip MUTATES q0..q3 + bh_io_uv0..3 on success.
                    // On failure (< 3 verts after clip) both revert to
                    // the pre-call values (q0..q3 untouched since they
                    // came in by value through __inout; bh_io_uv*
                    // still hold the defaults set above).
                    clipped = BH_ClipQuadToHitTri(
                        hole.bh_quad_p0, hole.bh_quad_p1,
                        hole.bh_quad_p2, hole.bh_quad_p3);
                }
            }
        }
    }

    // Allocate a cached trisoup slot for this static hole and write
    // its vertices ONCE. The vertex data persists in the buffer
    // across frames (BSP doesn't move, alpha doesn't fade), so the
    // per-frame draw cost is just the addtrisoup_simple submit at
    // the bottom of CSQC_BulletHolesStartFrame — no per-hole
    // walking, no per-hole vertex writes. Skipped in legacy
    // adddecal mode (cl_bullethole_renderer 0) since that path
    // uses adddecal each frame instead of the trisoup buffer.
    //
    // Holes carrying a custom per-variant shader (bh_shader_path —
    // snow/paint splats now, material decals previously) can't share
    // the batched gfx/bullethole buffer, so they skip slot allocation
    // and route through CSQC_DrawBakedBulletHole each frame instead.
    if (bh_cache_polygon && !hole.bh_shader_path)
    {
        if (clipped)
            // bh_io_uv0..3 carry the clipped UVs; AllocStaticSlotUV
            // reads from them via BH_WriteQuadUV.
            hole.bh_slot = BH_AllocStaticSlotUV(hole,
                hole.bh_quad_p0, hole.bh_quad_p1,
                hole.bh_quad_p2, hole.bh_quad_p3,
                hole.bh_color, hole.alpha * bh_cache_opacity);
        else
            hole.bh_slot = BH_AllocStaticSlot(hole,
                hole.bh_quad_p0, hole.bh_quad_p1,
                hole.bh_quad_p2, hole.bh_quad_p3,
                hole.bh_color, hole.alpha * bh_cache_opacity);
    }
};

// Static-hole per-frame draw — NO-OP for cached-trisoup holes. Their
// vertices were written to the cached trisoup buffer at spawn time
// (CSQC_BakeStaticBulletHoleQuad → BH_AllocStaticSlot) and persist
// there until the hole is removed (CSQC_BulletHoleRemove →
// BH_FreeStaticSlot). The single addtrisoup_simple call at the
// bottom of CSQC_BulletHolesStartFrame resubmits the same data each
// frame at near-zero CPU cost.
//
// EXCEPTION: holes with a per-variant shader (bh_shader_path —
// snow/paint splats now, future material decals) skip the cached
// buffer because each one carries its own shader. For those we read
// the baked corners and emit a single-quad draw call here. Cost is
// one draw call per visible splat per frame; capped by
// cl_bulletholes_max.
void(entity hole) CSQC_DrawBakedBulletHole =
{
    if (!hole.bh_shader_path) return;
    if (hole.bh_quad_p0 == '0 0 0' && hole.bh_quad_p2 == '0 0 0')
        return;   // degenerate (bake failed on a zero-normal hit)
    BH_SubmitOneQuad(hole.bh_shader_path,
                     hole.bh_quad_p0, hole.bh_quad_p1,
                     hole.bh_quad_p2, hole.bh_quad_p3,
                     hole.bh_color, hole.alpha * bh_cache_opacity);
};

// Polygon-quad render for tracked decals — brushmodel-owned (func_door,
// func_button, func_breakable). Local-space pos/normal transformed back
// to world via the owner's current origin + angles each frame so the
// decal tracks the brush's motion + rotation. Static-world holes go
// through CSQC_DrawBakedBulletHole instead (cheaper).
void(entity hole) CSQC_DrawTrackedBulletHole =
{
    if (!hole.owner || hole.owner.solid != SOLID_BSP)
        return;   // owner became non-solid (broken / hidden) — skip

    vector lp = hole.bh_track_local_pos;
    vector ln = hole.bh_track_local_normal;

    makevectors(hole.owner.angles);
    vector world_pos = hole.owner.origin
                     + v_forward * lp_x
                     + v_right   * lp_y
                     + v_up      * lp_z;
    vector world_normal = v_forward * ln_x
                        + v_right   * ln_y
                        + v_up      * ln_z;

    if (vlen(world_normal) <= 0.001)
        return;
    world_normal = normalize(world_normal);

    vector ref;
    if (fabs(world_normal_z) < 0.9)
        ref = '0 0 1';
    else
        ref = '1 0 0';
    vector tangent   = normalize(crossproduct(world_normal, ref));
    vector bitangent = crossproduct(world_normal, tangent);

    // 4-way rotation — same swap/negate as the bake helper. Costs
    // ~5 ops per draw vs being free for static holes, but brushmodel
    // holes are a tiny minority of the population.
    float rot = hole.bh_quad_rot;
    if (rot == 1)
    {
        vector tmp1 = tangent;
        tangent = bitangent;
        bitangent = -tmp1;
    }
    else if (rot == 2)
    {
        tangent = -tangent;
        bitangent = -bitangent;
    }
    else if (rot == 3)
    {
        vector tmp3 = tangent;
        tangent = -bitangent;
        bitangent = tmp3;
    }

    float half = hole.bh_half_size > 0
                 ? hole.bh_half_size
                 : (hole.bh_snow ? SNOWSPLAT_DECAL_HALF_SIZE
                                 : BULLETHOLE_DECAL_HALF_SIZE);

    vector center = world_pos + world_normal * 0.4;

    vector p0 = center - tangent * half - bitangent * half;
    vector p1 = center + tangent * half - bitangent * half;
    vector p2 = center + tangent * half + bitangent * half;
    vector p3 = center - tangent * half + bitangent * half;

    float bh_a = hole.alpha * bh_cache_opacity;
    // Tracked holes can't be cached because their owner moves —
    // append into the same per-shader buffer at the end of the
    // already-cached static portion. The append is reset back to
    // the static-portion size each frame (in StartFrame) so this
    // suffix is always rebuilt fresh. Tracked hole count is small
    // in practice (only func_door / func_breakable / func_button
    // hits), so per-frame transform cost is bounded.
    //
    // Material decals (bh_shader_path set) carry their own shader
    // and can't share the gfx/bullethole batched buffer — submit a
    // one-quad addtrisoup_simple call instead.  Cost is one draw
    // call per visible material hole; the per-frame hole cap
    // (cl_bulletholes_max) bounds the total.
    if (hole.bh_shader_path)
        BH_SubmitOneQuad(hole.bh_shader_path, p0, p1, p2, p3, hole.bh_color, bh_a);
    else
        BH_AppendDynamicQuad(hole.bh_snow, p0, p1, p2, p3, hole.bh_color, bh_a);
};

void(entity hole) CSQC_DrawBulletHoleTexture =
{
    // Cull paths — applied to BOTH renderer modes. Both use
    // bh_decal_origin (world-space hit pos) which is correct for static
    // holes but stale for brushmodel-owned ones (the brush moves), so
    // brushmodel-owned holes skip both culls and always reach their
    // per-mode draw which resolves the current world position.
    if (!hole.owner || hole.owner == world)
    {
        // Behind-camera cull — 32-unit slop keeps just-behind holes
        // visible during sharp turns.
        vector to_hole = hole.bh_decal_origin - bh_cache_cam_origin;
        if ((to_hole * bh_cache_cam_forward) < -32)
            return;

        // Distance LOD cull — skip far-away holes when cl_bullethole_
        // distance is set. Squared compare so no sqrt; the threshold
        // is pre-squared into bh_cache_dist_sq each frame.
        if (bh_cache_dist_sq > 0 && (to_hole * to_hole) > bh_cache_dist_sq)
            return;
    }

    // Cvar-gated dispatch (cached once per frame in StartFrame):
    //   bh_cache_polygon != 0 — polygon path for ALL holes (default,
    //     fast). Static (world-owned) holes use the pre-baked-corners
    //     fast path (CSQC_DrawBakedBulletHole, ~10 ops). Brushmodel-
    //     owned holes use the full per-frame transform (~80 ops) so
    //     the decal tracks the moving brush.
    //   bh_cache_polygon == 0 — legacy mixed mode. Brushmodel-owned
    //     still uses polygon (adddecal can't reproject onto a moving
    //     brush), world-owned falls back to adddecal for corner-wrap.
    if (bh_cache_polygon || hole.bh_tracked)
    {
        if (hole.bh_tracked)
            CSQC_DrawTrackedBulletHole(hole);   // brushmodel, full math
        else
            CSQC_DrawBakedBulletHole(hole);     // static, baked corners
        return;
    }
    CSQC_DrawBulletHoleDecal(hole);
};

// --- Per-frame: update dynamic holes, reset frame cap, draw decal mode ---
void() CSQC_BulletHolesStartFrame =
{
    entity hole, next;

    // Reset the trisoup count back to "just the cached static
    // portion". Tracked (brushmodel-owned) holes will append after
    // that during the per-frame walk below; static holes are already
    // in [0, static_count) and persist across frames.
    bh_bullet_count = bh_bullet_static_count;
    bh_snow_count   = bh_snow_static_count;

    // Per-frame cvar cache. Populated ONCE per frame so the per-hole
    // accessor functions don't pay repeated cvar() calls. Profile
    // previously showed ~500k cvar reads/sec each from
    // CSQC_BulletHolesEnabled and CSQC_DecalOpacity; now ~4 reads/frame.
    bh_cache_enabled   = cvar("cl_bulletholes") > 0;
    bh_cache_opacity   = bound(0, cvar("cl_decal_opacity"), 1);
    bh_cache_polygon   = cvar("cl_bullethole_renderer") != 0;
    bh_cache_max       = cvar("cl_bulletholes_max");
    if (bh_cache_max < 1) bh_cache_max = 1;     // sanity floor
    bh_cache_clip_geom = cvar("cl_bullethole_clip_geom") != 0;

    // Frustum/distance-cull state — only used by the legacy
    // adddecal path (CSQC_DrawBulletHoleTexture's per-hole cull
    // check on world-owned holes). The polygon path caches
    // vertex data at spawn time and submits via addtrisoup_simple,
    // skipping per-hole culling entirely (let GPU + frustum clip
    // handle visibility — see Decided notes in the v2 batching
    // rewrite). Reading these cvars + getproperty + makevectors
    // every frame in polygon mode was ~3 ms of pure waste.
    if (!bh_cache_polygon)
    {
        float dist = cvar("cl_bullethole_distance");
        bh_cache_dist_sq = (dist > 0) ? dist * dist : 0;
        bh_cache_cam_origin = (vector)getproperty(VF_ORIGIN);
        makevectors((vector)getproperty(VF_ANGLES));
        bh_cache_cam_forward = v_forward;
    }

    bh_frame_count = 0;
    hole = bh_dyn_head;

    while (hole)
    {
        next = hole.bh_dyn_next;

        if (hole.owner && hole.owner.solid == SOLID_BSP)
        {
            // Tracked decals derive world-space directly from the
            // owner's current origin/angles inside the polygon
            // renderer, so no per-frame absmin recompute is needed
            // here — only the legacy adddecal-based dynamic path
            // (which projects against worldmodel) still needs it.
            if (!hole.bh_tracked)
            {
                setorigin(hole, hole.owner.absmin + hole.bh_local_offset);
                hole.bh_decal_origin = hole.owner.absmin + hole.bh_decal_local_offset;
            }
        }
        else
            CSQC_BulletHoleRemove(hole);

        hole = next;
    }

    // Per-frame draw walk. In polygon mode static holes are cached
    // in the trisoup buffer (BH_AllocStaticSlot wrote them at spawn
    // time and they persist across frames), so we only need to
    // visit tracked (brushmodel-owned) holes here. The bh_dyn_head
    // list contains those — a strict subset of bh_head, typically
    // tiny or empty.
    //
    // In legacy adddecal mode (cl_bullethole_renderer 0), static
    // holes need a per-frame adddecal call so we keep the full
    // bh_head walk for that path.
    if (!CSQC_BulletHolesEnabled())
    {
        // skip both walks AND the submit; nothing should render
    }
    else if (bh_cache_polygon)
    {
        hole = bh_dyn_head;
        while (hole)
        {
            next = hole.bh_dyn_next;
            CSQC_DrawBulletHoleTexture(hole);
            hole = next;
        }
        // Static per-quad splats (snow/paint world hits with
        // bh_shader_path) — can't share the batched gfx/bullethole or
        // gfx/snowsplat trisoup buffer because each carries its own
        // variant shader, so each one needs its own draw call.
        // Routed through CSQC_DrawBakedBulletHole → BH_SubmitOneQuad.
        hole = bh_pq_head;
        while (hole)
        {
            next = hole.bh_pq_next;
            CSQC_DrawBulletHoleTexture(hole);
            hole = next;
        }
    }
    else
    {
        // Legacy adddecal mode — full walk for per-frame adddecal calls.
        hole = bh_head;
        while (hole)
        {
            next = hole.bh_next;
            hole.drawmask = 0;
            CSQC_DrawBulletHoleTexture(hole);
            hole = next;
        }
    }

    // Submit the cached + appended trisoup buffers — at most one
    // draw call per shader (gfx/bullethole + gfx/snowsplat),
    // regardless of how many holes are in the buffer. Static holes
    // contribute the [0, *_static_count) prefix that persists across
    // frames; tracked holes contribute the [*_static_count, *_count)
    // suffix that was rebuilt this frame.
    if (CSQC_BulletHolesEnabled() && bh_cache_polygon)
    {
        if (bh_bullet_count > 0)
            addtrisoup_simple(BULLETHOLE_QUAD_SHADER, 0,
                              &bh_bullet_verts[0], &bh_bullet_idx[0],
                              bh_bullet_count * 6);
        if (bh_snow_count > 0)
            addtrisoup_simple(SNOWSPLAT_QUAD_SHADER, 0,
                              &bh_snow_verts[0], &bh_snow_idx[0],
                              bh_snow_count * 6);
    }
};

// --- Spawn a bullet hole decal at a hit point ---
// `impact_mat` is the IMPACT_MAT_* code (0 = default).  When the hit
// target is a brushmodel entity (func_breakable / door / button), the
// material picks a random variant from gfx/decals/impacts/* and the
// hole is rendered via per-frame addtrisoup_simple instead of the
// shared cached buffer.  World hits ignore the material and use the
// default gfx/bullethole shader on the cached fast path.
// Reset hook — call at the top of the penetrating-hitscan loop in
// sh_weapon_standard.qc so the per-shot counter applies to that one
// shot only.  Zero-cost when cl_bulletholes_per_shot is 0.
void() CSQC_BulletHoles_ResetShot =
{
    bh_per_shot_count = 0;
};

void(vector hit_pos, vector hit_normal, entity hit_target, float impact_mat) CSQC_SpawnBulletHole =
{
    entity hole;
    vector hole_normal, hole_angles, hole_origin;
    float hole_offset;

    if (!CSQC_BulletHolesEnabled())
        return;

    // Reject: phys props move + rotate under ODE so a decal would
    // visibly slide off the surface as soon as the prop tipped or
    // rolled.  Phys props are CSQC-replicated via SendEntity (see
    // cl_physprop.qc) so they arrive with classname set; the trace
    // also hits them since the CSQC update sets SOLID_BBOX.  Static
    // breakable brushes (SOLID_BSP) and world get decals normally.
    if (hit_target != world && (!hit_target || hit_target.solid != SOLID_BSP))
    {
        if (hit_target.classname == "phys_barrel" || hit_target.classname == "phys_can")
            return;   // phys prop hit — sparks still play, no decal
        return;       // any other non-BSP target (player, projectile, etc.)
    }

    // No bullet holes on sky
    if (pointcontents(hit_pos - hit_normal * 2) == CONTENT_SKY)
        return;

    // No bullet holes on the inside-facing side of a brush, where the
    // surface looks into solid (closed) BSP — these come from
    // penetration exit-hits on the back face of a wall whose other
    // side is unreachable void.  Sample 2 u along the hit normal
    // (away from the surface); if that's INSIDE solid the decal can't
    // be seen from any reachable viewpoint.
    if (pointcontents(hit_pos + hit_normal * 2) == CONTENT_SOLID)
        return;

    // PVS reachability — catches the harder "decal facing into a
    // genuinely enclosed CONTENT_EMPTY void" case the SOLID check
    // misses.  Cheap: a single reused point-entity gets re-positioned
    // and tested via checkpvs against the local camera.  Maps with
    // proper vis data return 0 for entities in sealed-off leaves, so
    // exit decals in unreachable bubbles get culled.  Disable with
    // cl_bulletholes_pvs_check 0 if a non-vis'd map under-reports.
    if (cvar("cl_bulletholes_pvs_check"))
    {
        if (!bh_pvs_test_ent)
        {
            bh_pvs_test_ent = spawn();
            setsize(bh_pvs_test_ent, '0 0 0', '0 0 0');
        }
        setorigin(bh_pvs_test_ent, hit_pos + hit_normal * 2);
        vector cam_pos = (vector)getproperty(VF_ORIGIN);
        if (!checkpvs(cam_pos, bh_pvs_test_ent))
            return;
    }

    if (bh_frame_count >= BULLETHOLE_MAX_PER_FRAME)
        return;

    // Per-shot cap (cl_bulletholes_per_shot).  Bullets that penetrate
    // can spawn entry + exit decals up to 4 hits = 8 decals each; this
    // gate lets the user trim that.  0 keeps the old behaviour.
    //
    // Shotgun bypass: shotgun blasts are a single trigger pull but emit
    // N pellets, each conceptually part of the SAME shot.  The user
    // expects "per shot" to mean "per trigger pull" — capping the visible
    // holes here would clip most of the spray.  CSQC_PredictedShotgunImpact
    // sets bh_shotgun_blast = 1 around its pellet loop so the per-shot
    // cap is bypassed inside that loop only.
    float per_shot_cap = cvar("cl_bulletholes_per_shot");
    if (!bh_shotgun_blast
        && per_shot_cap > 0
        && bh_per_shot_count >= per_shot_cap)
        return;
    bh_per_shot_count += 1;

    if (vlen(hit_normal) <= 0)
        return;

    // Drop any existing hole whose center sits within our decal radius
    // — the new hole would visually overlap the old one almost
    // entirely, so we keep the new one and remove the old.
    CSQC_BulletHole_DedupeNearby(hit_pos, BULLETHOLE_DECAL_HALF_SIZE);

    // Evict oldest if at cap
    // Eviction cap is the cl_bulletholes_max cvar (cached per frame).
    // Evicting more than one per spawn covers the case where the user
    // dropped the cvar mid-game and we're now over the new cap.
    while (bh_count >= bh_cache_max && bh_head)
        CSQC_BulletHoleRemove(bh_head);

    hole = spawn();
    hole.movetype = MOVETYPE_NONE;
    hole.solid = SOLID_NOT;
    hole.classname = "bullethole";
    hole.drawmask = 0;
    // -1 sentinel so BH_FreeStaticSlot is a no-op for tracked holes
    // (which never get a cached slot) and for any spawn that fails
    // to allocate one (full buffer).
    hole.bh_slot = -1;

    setsize(hole, '0 0 0', '0 0 0');
    hole.scale = 1;
    hole.alpha = 1;
    hole.bh_color = '1 1 1';
    hole.bh_half_size = BULLETHOLE_DECAL_HALF_SIZE;
    hole.effects = hole.effects | EF_FULLBRIGHT;

    hole.owner = hit_target;

    // Material-specific decal override.  Only kicks in for hits on
    // brushwork that ACTUALLY has a material code set — i.e. a
    // func_breakable with a known style.  func_wall / func_door /
    // func_button get the wire's no-material sentinel (255) from
    // sv_brushsync.qc so they fall through to the default
    // gfx/bullethole look here, same as world hits.  Without this
    // gate every plain func_wall would grab the concrete-decal
    // override even when the mapper hadn't asked for one.
    if (hit_target != world && hit_target.brush_material != 255)
    {
        float pick_half = 0;
        string pick_path = BH_PickMaterialDecal(impact_mat, pick_half);
        if (pick_path)
        {
            hole.bh_shader_path = pick_path;
            hole.bh_half_size   = pick_half;
        }
    }

    // Orient decal to face outward from the surface.
    hole_normal = normalize(hit_normal) * -1;
    hole_angles = vectoangles(hole_normal);
    hole_angles_x = 0 - hole_angles_x;
    hole.angles = hole_angles;
    // Pick the random 4-way rotation once and use the same value for
    // both render paths: angles_z drives the legacy adddecal renderer
    // (entity-rotation-based), bh_quad_rot drives the polygon path
    // (tangent/bitangent swap in bake / tracked draw).
    //
    // Per-material rotation rules:
    //   wood — {0, 2} only (grain is strongly vertical in the art, so
    //          the texture only ever appears upright or vertically
    //          flipped, never lying on its side)
    //   conc — locked to 0 (no rotation; the art has directional
    //          shading the rotated copies were inverting)
    //   else — full 4-way pick
    if (impact_mat == IMPACT_MAT_WOOD)
        hole.bh_quad_rot = floor(random() * 2) * 2;
    else if (impact_mat == IMPACT_MAT_DEFAULT)
        hole.bh_quad_rot = 0;
    else
        hole.bh_quad_rot = floor(random() * 4);
    hole.angles_z    = hole.bh_quad_rot * 90;

    // Nudge slightly off the surface to prevent z-fighting
    makevectors(hole.angles);
    hole_offset = BULLETHOLE_OFFSET_MIN + (random() * BULLETHOLE_OFFSET_JITTER);
    hole_origin = hit_pos - (v_forward * hole_offset);
    setorigin(hole, hole_origin);
    hole.bh_decal_origin = hit_pos;

    // Track offset for dynamic (moving BSP) entities.  The two flags
    // bh_dynamic + bh_tracked have related but distinct purposes:
    //   bh_dynamic — keeps the hole tied to its owner's lifetime so
    //                CSQC_BulletHolesStartFrame removes it when the
    //                owner becomes non-SOLID_BSP (broken / hidden).
    //   bh_tracked — selects the per-frame polygon render path that
    //                transforms a stored LOCAL-space pos/normal back
    //                to world via the owner's CURRENT origin + angles.
    //                Replaces the old absmin-offset hack which only
    //                worked for translation and re-projected against
    //                worldmodel via adddecal each frame (so doors
    //                "moved" the projection target instead of the
    //                surface, leaving the decal stuck on the wall
    //                behind the door).
    if (hit_target != world)
    {
        hole.bh_dynamic = TRUE;
        hole.bh_local_offset = hole_origin - hit_target.absmin;
        hole.bh_decal_local_offset = hit_pos - hit_target.absmin;

        hole.bh_tracked = TRUE;
        makevectors(hit_target.angles);
        vector dp = hit_pos - hit_target.origin;
        hole.bh_track_local_pos = [dp * v_forward, dp * v_right, dp * v_up];
        hole.bh_track_local_normal = [hit_normal * v_forward,
                                       hit_normal * v_right,
                                       hit_normal * v_up];
    }
    else
    {
        // World hits: pre-bake the polygon corners ONCE so the per-
        // frame draw is just 4 vertex submits — no transform math,
        // no tangent-frame, no corner computation. Leave bh_tracked
        // unset so CSQC_DrawBulletHoleTexture routes us to
        // CSQC_DrawBakedBulletHole (the fast static path), and so
        // legacy adddecal mode still owns world holes when toggled.
        // bh_track_local_pos/normal kept as a debug-friendly trace
        // of the original hit_pos/normal.
        hole.bh_track_local_pos    = hit_pos;
        hole.bh_track_local_normal = hit_normal;
        CSQC_BakeStaticBulletHoleQuad(hole, hit_pos, hit_normal);
    }

    // Append to linked list
    hole.bh_prev = bh_tail;
    hole.bh_next = world;

    if (bh_tail)
        bh_tail.bh_next = hole;
    else
        bh_head = hole;

    bh_tail = hole;

    if (hole.bh_dynamic)
    {
        hole.bh_dyn_prev = bh_dyn_tail;
        hole.bh_dyn_next = world;

        if (bh_dyn_tail)
            bh_dyn_tail.bh_dyn_next = hole;
        else
            bh_dyn_head = hole;

        bh_dyn_tail = hole;
    }

    bh_count += 1;
    bh_frame_count += 1;
};

void(vector hit_pos, vector hit_normal, entity hit_target) CSQC_SpawnSnowSplat =
{
    entity hole;
    entity existing;
    vector hole_normal, hole_angles, hole_origin;
    float hole_offset;

    if (!CSQC_BulletHolesEnabled())
        return;
    if (vlen(hit_normal) <= 0)
        return;
    if (hit_target != world && (!hit_target || hit_target.solid != SOLID_BSP))
        return;
    if (pointcontents(hit_pos - hit_normal * 2) == CONTENT_SKY)
        return;

    existing = bh_head;
    while (existing)
    {
        if (existing.classname == "snowsplat"
            && (cltime - existing.bh_spawn_time) < 0.35
            && vlen(existing.bh_decal_origin - hit_pos) <= SNOWSPLAT_DECAL_HALF_SIZE * 2)
            return;
        existing = existing.bh_next;
    }

    // Replace any older overlapping decal at this spot — the time-
    // window reject above already protects against shotgun-pellet
    // spam from same shot; this strips stale decals (other types or
    // same-type past the 0.35s window) so the new splat doesn't
    // visually stack.
    CSQC_BulletHole_DedupeNearby(hit_pos, SNOWSPLAT_DECAL_HALF_SIZE);

    // Eviction cap is the cl_bulletholes_max cvar (cached per frame).
    // Evicting more than one per spawn covers the case where the user
    // dropped the cvar mid-game and we're now over the new cap.
    while (bh_count >= bh_cache_max && bh_head)
        CSQC_BulletHoleRemove(bh_head);

    hole = spawn();
    hole.movetype = MOVETYPE_NONE;
    hole.solid = SOLID_NOT;
    hole.classname = "snowsplat";
    hole.drawmask = 0;
    hole.bh_slot = -1;          // see CSQC_SpawnBulletHole — sentinel for cached-trisoup slot
    hole.bh_snow = TRUE;
    hole.bh_spawn_time = cltime;

    // Random splat variant 1..9 (gfx/impacts/paintball/splat1..9).
    hole.bh_shader_path = bh_splat_path[(int)floor(random() * BH_SPLAT_COUNT)];

    setsize(hole, '0 0 0', '0 0 0');
    hole.scale = 1;
    hole.alpha = 1;
    hole.bh_color = '1 1 1';
    hole.bh_half_size = SNOWSPLAT_DECAL_HALF_SIZE;
    hole.effects = hole.effects | EF_FULLBRIGHT;
    hole.owner = hit_target;

    hole_normal = normalize(hit_normal) * -1;
    hole_angles = vectoangles(hole_normal);
    hole_angles_x = 0 - hole_angles_x;
    hole.angles = hole_angles;
    // Pick the random 4-way rotation once and use the same value for
    // both render paths: angles_z drives the legacy adddecal renderer
    // (entity-rotation-based), bh_quad_rot drives the polygon path
    // (tangent/bitangent swap in bake / tracked draw).
    hole.bh_quad_rot = floor(random() * 4);
    hole.angles_z    = hole.bh_quad_rot * 90;

    makevectors(hole.angles);
    hole_offset = BULLETHOLE_OFFSET_MIN + (random() * BULLETHOLE_OFFSET_JITTER);
    hole_origin = hit_pos - (v_forward * hole_offset);
    setorigin(hole, hole_origin);
    hole.bh_decal_origin = hit_pos;

    if (hit_target != world)
    {
        hole.bh_dynamic = TRUE;
        hole.bh_local_offset = hole_origin - hit_target.absmin;
        hole.bh_decal_local_offset = hit_pos - hit_target.absmin;

        // Tracked-polygon mode (mirrors bullet holes) — local-space
        // pos/normal so the splat tracks brushmodel motion + rotation
        // and gets purged with the breakable on destroy.
        hole.bh_tracked = TRUE;
        makevectors(hit_target.angles);
        vector dp_t = hit_pos - hit_target.origin;
        hole.bh_track_local_pos = [dp_t * v_forward, dp_t * v_right, dp_t * v_up];
        hole.bh_track_local_normal = [hit_normal * v_forward,
                                       hit_normal * v_right,
                                       hit_normal * v_up];
    }
    else
    {
        // World hits — pre-bake polygon corners (mirrors the world
        // branch in CSQC_SpawnBulletHole). Routes through
        // CSQC_DrawBakedBulletHole each frame: ~10 ops per draw vs
        // ~80 for the brushmodel-tracked path.
        hole.bh_track_local_pos    = hit_pos;
        hole.bh_track_local_normal = hit_normal;
        CSQC_BakeStaticBulletHoleQuad(hole, hit_pos, hit_normal);
    }

    hole.bh_prev = bh_tail;
    hole.bh_next = world;
    if (bh_tail)
        bh_tail.bh_next = hole;
    else
        bh_head = hole;
    bh_tail = hole;

    if (hole.bh_dynamic)
    {
        hole.bh_dyn_prev = bh_dyn_tail;
        hole.bh_dyn_next = world;
        if (bh_dyn_tail)
            bh_dyn_tail.bh_dyn_next = hole;
        else
            bh_dyn_head = hole;
        bh_dyn_tail = hole;
    }
    else if (hole.bh_shader_path)
    {
        // Static (world-hit) splat with per-variant shader — link
        // into bh_pq so the per-frame draw walk visits it for a
        // BH_SubmitOneQuad call.  Tracked splats already go through
        // bh_dyn_head above so they're excluded here.
        hole.bh_pq_prev = bh_pq_tail;
        hole.bh_pq_next = world;
        if (bh_pq_tail)
            bh_pq_tail.bh_pq_next = hole;
        else
            bh_pq_head = hole;
        bh_pq_tail = hole;
    }

    bh_count += 1;
};

void(vector hit_pos, vector hit_normal, entity hit_target, vector color, float half_size) CSQC_SpawnPaintSplat =
{
    entity hole;
    vector hole_normal, hole_angles, hole_origin;
    float hole_offset;

    if (!CSQC_BulletHolesEnabled())
        return;
    if (vlen(hit_normal) <= 0)
        return;
    if (hit_target != world && (!hit_target || hit_target.solid != SOLID_BSP))
        return;
    if (pointcontents(hit_pos - hit_normal * 2) == CONTENT_SKY)
        return;

    // Replace any older overlapping decal — paintball is full-auto so
    // a fresh paintsplat removes any older hole/splat at the same
    // spot instead of stacking. Uses the splat's actual half_size
    // (passed in as a parameter, varies between paint colors/types).
    CSQC_BulletHole_DedupeNearby(hit_pos, half_size);

    // Eviction cap is the cl_bulletholes_max cvar (cached per frame).
    // Evicting more than one per spawn covers the case where the user
    // dropped the cvar mid-game and we're now over the new cap.
    while (bh_count >= bh_cache_max && bh_head)
        CSQC_BulletHoleRemove(bh_head);

    hole = spawn();
    hole.movetype = MOVETYPE_NONE;
    hole.solid = SOLID_NOT;
    hole.classname = "paintsplat";
    hole.drawmask = 0;
    hole.bh_slot = -1;          // see CSQC_SpawnBulletHole — sentinel for cached-trisoup slot
    hole.bh_snow = TRUE;
    hole.bh_spawn_time = cltime;

    // Random splat variant 1..9 (gfx/impacts/paintball/splat1..9).
    hole.bh_shader_path = bh_splat_path[(int)floor(random() * BH_SPLAT_COUNT)];

    setsize(hole, '0 0 0', '0 0 0');
    hole.scale = 1;
    hole.alpha = 1;
    hole.bh_color = color;
    hole.bh_half_size = half_size;
    hole.effects = hole.effects | EF_FULLBRIGHT;
    hole.owner = hit_target;

    hole_normal = normalize(hit_normal) * -1;
    hole_angles = vectoangles(hole_normal);
    hole_angles_x = 0 - hole_angles_x;
    hole.angles = hole_angles;
    // Pick the random 4-way rotation once and use the same value for
    // both render paths: angles_z drives the legacy adddecal renderer
    // (entity-rotation-based), bh_quad_rot drives the polygon path
    // (tangent/bitangent swap in bake / tracked draw).
    hole.bh_quad_rot = floor(random() * 4);
    hole.angles_z    = hole.bh_quad_rot * 90;

    makevectors(hole.angles);
    hole_offset = BULLETHOLE_OFFSET_MIN + (random() * BULLETHOLE_OFFSET_JITTER);
    hole_origin = hit_pos - (v_forward * hole_offset);
    setorigin(hole, hole_origin);
    hole.bh_decal_origin = hit_pos;

    if (hit_target != world)
    {
        hole.bh_dynamic = TRUE;
        hole.bh_local_offset = hole_origin - hit_target.absmin;
        hole.bh_decal_local_offset = hit_pos - hit_target.absmin;

        // Tracked-polygon mode (mirrors bullet holes) — local-space
        // pos/normal so the splat tracks brushmodel motion + rotation
        // and gets purged with the breakable on destroy.
        hole.bh_tracked = TRUE;
        makevectors(hit_target.angles);
        vector dp_t = hit_pos - hit_target.origin;
        hole.bh_track_local_pos = [dp_t * v_forward, dp_t * v_right, dp_t * v_up];
        hole.bh_track_local_normal = [hit_normal * v_forward,
                                       hit_normal * v_right,
                                       hit_normal * v_up];
    }
    else
    {
        // World hits — pre-bake polygon corners (mirrors the world
        // branch in CSQC_SpawnBulletHole). Routes through
        // CSQC_DrawBakedBulletHole each frame: ~10 ops per draw vs
        // ~80 for the brushmodel-tracked path.
        hole.bh_track_local_pos    = hit_pos;
        hole.bh_track_local_normal = hit_normal;
        CSQC_BakeStaticBulletHoleQuad(hole, hit_pos, hit_normal);
    }

    hole.bh_prev = bh_tail;
    hole.bh_next = world;
    if (bh_tail)
        bh_tail.bh_next = hole;
    else
        bh_head = hole;
    bh_tail = hole;

    if (hole.bh_dynamic)
    {
        hole.bh_dyn_prev = bh_dyn_tail;
        hole.bh_dyn_next = world;
        if (bh_dyn_tail)
            bh_dyn_tail.bh_dyn_next = hole;
        else
            bh_dyn_head = hole;
        bh_dyn_tail = hole;
    }
    else if (hole.bh_shader_path)
    {
        // Static (world-hit) paint splat — same per-quad list as the
        // snow splat spawner above; see comment there.
        hole.bh_pq_prev = bh_pq_tail;
        hole.bh_pq_next = world;
        if (bh_pq_tail)
            bh_pq_tail.bh_pq_next = hole;
        else
            bh_pq_head = hole;
        bh_pq_tail = hole;
    }

    bh_count += 1;
};

// Convenience: spawn from trace globals (after a traceline).  Maps
// the brushsync's BREAKABLE_* code on trace_ent.brush_material to the
// matching IMPACT_MAT_* code that BH_PickMaterialDecal expects.
// Mirrors the lookup in Impact_ClassifyLocal (cl_bulletimpact.qc) —
// keep the two in sync when material numbering changes.
//   0 GLASS / 7 UNBREAKABLE_GLASS → glass decal
//   1 WOOD  / 5 TILE              → wood decal
//   2 METAL / 6 COMPUTER          → metal decal
//   4 CINDER / 8 ROCKS / 3 FLESH  → default (concrete-style) decal
void() CSQC_SpawnTraceBulletHole =
{
    float mat = IMPACT_MAT_DEFAULT;
    if (trace_ent)
    {
        float bm = trace_ent.brush_material;
        if (bm == 0 || bm == 7)        mat = IMPACT_MAT_GLASS;
        else if (bm == 1 || bm == 5)   mat = IMPACT_MAT_WOOD;
        else if (bm == 2 || bm == 6)   mat = IMPACT_MAT_METAL;
    }
    CSQC_SpawnBulletHole(trace_endpos, trace_plane_normal, trace_ent, mat);
};
