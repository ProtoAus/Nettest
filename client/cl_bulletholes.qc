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
// Per-shot decal cap, scoped by the shot's action_id (every impact of a shot carries it) via a
// small ring — indexed by (action mod BH_SHOTRING), so several overlapping (sprayed) shots each
// count their OWN nearest-N decals.  Replaces the old single global counter, which was reset at
// FIRE time but checked at the DEFERRED spawn time: a later shot's reset then freed an earlier
// shot's still-parked EXIT decal onto the wall behind.  See CSQC_BulletHole_CapAllows.
const float BH_SHOTRING = 16;
float  bh_shot_action[BH_SHOTRING];   // action_id owning each ring slot (0 = default, matches action 0 harmlessly)
float  bh_shot_count [BH_SHOTRING];   // holes already placed for that shot
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
float bh_cache_polygon;     // TRUE only for r_bullethole_renderer 1 (trisoup); 0=adddecal, 2=persistent-lit
float bh_cache_renderer;    // r_bullethole_renderer raw value (0 adddecal / 1 trisoup / 2 persistent-lit)
float bh_last_renderer;     // previous frame's renderer — to detect a switch AWAY from mode 2 (free handles)
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

// r_bullethole_renderer 2 (PERSISTENT LIT): engine persistent-decal handle for a STATIC (world)
// hole — the engine clips it ONCE + re-emits cheaply (no per-frame BSP re-clip).  0=none, -1=off-surface.
.float bh_handle;

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

// World/BSP bullet-hole art — one of these four gfx/impacts/impactN.png is picked at random
// per world hit (replaces the old single gfx/bullethole).  Small + random 90-deg rotation.
// Size via the cl_bullethole_impact_size cvar (full units across, default 6).  Precached in
// CSQC_BulletHolesInit; `_lm` variants registered in CSQC_BulletHole_ReregisterShaders.
const float BH_IMPACT_COUNT = 4;
string bh_impact_path[4];

// World/BSP WOOD art — gfx/impacts/woodN.png, picked at random when a world/plain-brush hit lands
// on a surface tagged "wood" in scripts/surfaceprops.txt (impact_mat == IMPACT_MAT_WOOD).  Same
// world-hit path + sizing (cl_bullethole_impact_size) as bh_impact_path, but the art is radially
// symmetric splinter bursts (no baked shadow) so it takes a full random 90-deg rotation.  Breakable
// func_breakable wood keeps its own gfx/decals/impacts/wood set (bh_mat_path_wood, BH_PickMaterialDecal).
const float BH_WORLD_WOOD_COUNT = 4;
string bh_world_wood_path[4];

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

// Live r_bullethole_offset: the off-surface lift the STATIC tri-soup quads currently
// reflect.  The bake uses this (not the live cvar); CSQC_BulletHolesStartFrame polls
// the cvar and re-shifts on change.  Init 0 so the first poll lifts from 0 to the cvar
// (any quad baked before the first poll, baked at 0, is shifted to the cvar with it).
float bh_baked_offset;

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

    // WINDING (2026-07): 0,2,1 / 0,3,2 — i.e. the quad's triangles are wound so their geometric normal is
    // -wn, which is CLOCKWISE when viewed from the FRONT (+wn side).  That MATCHES Quake/BSP world surfaces,
    // and is what makes backface culling work: FTE leaves glFrontFace at GL_CCW and its default
    // SHADER_CULL_FRONT issues glCullFace(GL_FRONT) (gl_backend.c:1032, flipcull=0 in the normal view) — the
    // classic GLQuake convention — so CW-from-front survives and CCW-from-front is culled.  The old
    // 0,1,2 / 0,2,3 order gave normal +wn (CCW-from-front) which culls from the FRONT (decal/blob invisible).
    // It only ever worked because every consumer used `cull none`; now that decals cull, the winding matters.
    idx[ibase + 0] = vbase + 0;
    idx[ibase + 1] = vbase + 2;
    idx[ibase + 2] = vbase + 1;
    idx[ibase + 3] = vbase + 0;
    idx[ibase + 4] = vbase + 3;
    idx[ibase + 5] = vbase + 2;
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

    idx[ibase + 0] = vbase + 0;   // 0,2,1 / 0,3,2 — CW-from-front to match the world (see BH_WriteQuad)
    idx[ibase + 1] = vbase + 2;
    idx[ibase + 2] = vbase + 1;
    idx[ibase + 3] = vbase + 0;
    idx[ibase + 4] = vbase + 3;
    idx[ibase + 5] = vbase + 2;
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

// Collapse a quad's 4 verts onto its own first corner so both triangles are zero-area and
// the GPU discards them regardless of shader / vertex alpha.  Shared by all three tri-soup
// decal free paths (bullet holes, blood, sprays) — zeroing alpha ALONE relies on the shader
// honouring `alphaGen vertex`, which r_showtris bypasses and a post-vid_restart base-shader
// fallback defeats, leaving a visible ghost.  trisoup_simple_vert_t.xyz is float[3], so copy
// per component (same idiom as Decal_ShiftQuadVerts).  Compile order (cl_progs.src) puts this
// before the blood/spray free paths, so they can call it.
void(trisoup_simple_vert_t *v) Decal_CollapseQuad =
{
    v[1].xyz[0] = v[0].xyz[0]; v[1].xyz[1] = v[0].xyz[1]; v[1].xyz[2] = v[0].xyz[2];
    v[2].xyz[0] = v[0].xyz[0]; v[2].xyz[1] = v[0].xyz[1]; v[2].xyz[2] = v[0].xyz[2];
    v[3].xyz[0] = v[0].xyz[0]; v[3].xyz[1] = v[0].xyz[1]; v[3].xyz[2] = v[0].xyz[2];
};

// Free a static hole's slot — degenerates the quad to ZERO-AREA geometry (collapses all 4
// verts onto the first corner; also zeros alpha as belt-and-suspenders) so the GPU skips it
// regardless of the bound shader, and pushes the slot index onto the per-shader free list
// for reuse. Called from CSQC_BulletHoleRemove. Cheap (a handful of array writes + 1 push).
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
        Decal_CollapseQuad(&bh_snow_verts[vbase]);
        bh_snow_free[bh_snow_free_count] = slot;
        bh_snow_free_count = bh_snow_free_count + 1;
    }
    else
    {
        bh_bullet_verts[vbase + 0].rgba[3] = 0;
        bh_bullet_verts[vbase + 1].rgba[3] = 0;
        bh_bullet_verts[vbase + 2].rgba[3] = 0;
        bh_bullet_verts[vbase + 3].rgba[3] = 0;
        Decal_CollapseQuad(&bh_bullet_verts[vbase]);
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

// Cross-surface coplanar-seam probe (P1 fix).  getsurfacenearpoint returns ONE BSP face, so a
// flat wall the compiler split into coplanar faces reads its A|B seam as a real outline edge and
// slices the decal there.  For each outline edge we probe just past it and, if solid COPLANAR
// geometry continues, treat the edge as interior (don't clip).  Kept tiny so only ~zero-width
// compiler seams bridge — a real gap (doorway) between two coplanar walls is NOT bridged.
const float BH_SEAM_PROBE     = 1.5;   // qu past the edge (in-plane) to sample the neighbour
const float BH_SEAM_DEPTH     = 2.0;   // qu each side of the plane for the perpendicular micro-trace
const float BH_SEAM_PLANE_EPS = 0.5;   // qu tolerance for "neighbour lies in the hit plane"

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

    // Cross-surface coplanar seams (P1): getsurfacenearpoint handed us ONE face, so an edge shared
    // with a coplanar NEIGHBOUR face (a qbsp split of a flat wall) was flagged "outline" above and
    // would slice the decal.  For each such outline edge, probe just past it and CLEAR its bit if
    // solid geometry continues in the SAME plane.  A real corner (non-parallel neighbour) or an
    // outer boundary (nothing past the edge) stays set, so genuine edges still clip.  Separate
    // `continue` guards (not one &&) — fteqcc has no short-circuit — and an inline abs (no fabs dep).
    for (e = 0; e < 3; e = e + 1)
    {
        if (!(active_mask & (1 << (int)e)))
            continue;
        vector seam_mid = (edges_v0[(int)e] + edges_v1[(int)e]) * 0.5;
        vector seam_in  = BH_EdgePlaneNormal(edges_v0[(int)e], edges_v1[(int)e],
                                             edges_third[(int)e], bh_io_sn);  // inward, in-plane
        vector seam_out = normalize(seam_in * -1);                           // outward, past the edge
        vector seam_p   = seam_mid + seam_out * BH_SEAM_PROBE;
        traceline(seam_p + bh_io_sn * BH_SEAM_DEPTH,
                  seam_p - bh_io_sn * BH_SEAM_DEPTH, MOVE_NOMONSTERS, world);
        if (trace_fraction >= 1)                        continue;  // open past edge → real boundary
        if ((trace_plane_normal * bh_io_sn) <= 0.999)   continue;  // not parallel → real corner
        float seam_pd = (trace_endpos - bh_io_tv0) * bh_io_sn;
        if (seam_pd < 0) seam_pd = -seam_pd;
        if (seam_pd >= BH_SEAM_PLANE_EPS)               continue;  // parallel but offset plane
        active_mask = active_mask - (1 << (int)e);                 // coplanar continuation → seam
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

    if (hole.bh_handle > 0) removedecal(hole.bh_handle);   // r_bullethole_renderer 2: free the engine persistent decal
    remove(hole);
    bh_count -= 1;
};

// Remove any existing bullet hole / splat whose center lies within
// `decal_half_size * cl_bullethole_dedupe_scale` of `hit_pos`. Called
// from each spawn function so a new hole replaces an overlapping old
// one instead of stacking on top. Squared-distance check avoids sqrt
// in the loop. Works regardless of r_bullethole_renderer mode —
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

// ===== Per-pixel decal-lightmap shader body (shared by all 3 adddecal renderers) =====
// Returns the `_lm` shader body for `r_decal_lightmap 1` — a program pass that samples the world
// lightmap the engine binds at each clipped fragment (engine Patch 72 / memory infodecal-renderer-
// trisoup).  Registered "<key>_lm" alongside the plain adddecal shader via shaderforname; the
// adddecal draw uses it + WHITE vertex rgb when the cvar is on.  ORDER MATTERS: blendfunc/rgbgen/
// alphagen come BEFORE the two `map` lines — in a program pass each `map` opens a merged sub-pass,
// and a blendfunc after the maps lands on the LAST sub-pass ($lightmap) while the backend applies
// the BASE pass's blend (would default opaque => the decal's masked-out magenta shows).  `!!samps 2`
// = positional s_t0(png)/s_t1($lightmap).  In scope for cl_sprays.qc + cl_infodecal.qc (compiled after).
// `twosided`: 1 = keep `cull none` (sprays — deliberately visible from either side, cl_sprays.qc:371).
// 0 = OMIT cull entirely => FTE's default SHADER_CULL_FRONT (gl_shader.c:7689) = normal backface culling.
// WHY culling matters: `polygonoffset 8` is a CONSTANT window-space depth bias (unit = -25*8 = -200,
// gl_shader.c:1295).  Depth is nonlinear, so that constant bias equals a world-space pull toward the camera
// of ~d²·Δz/near — it GROWS with distance (~12qu @1000, ~48qu @2000).  Past ~1-2k units it exceeds a wall's
// thickness, the decal's depth beats the wall's FAR face, and `cull none` then draws it => the decal shows
// THROUGH the wall from behind at range.  Culling kills that outright, and costs nothing: the engine's
// clipper already refuses to build decal geometry on away-facing surfaces (r_decal_noperpendicular=1,
// q1bsp.c:394-409), so there is no legitimate back-facing decal to lose.
string(string maptarget, float twosided) Decal_LMShaderBody =
{
    return sprintf(
        "{\n"
        "    sort decal\n"
        "    polygonoffset 8\n"
        "    nopicmip\n"
        "%s"
        "    {\n"
        "        program decal_lightmap\n"
        "        blendfunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n"
        "        rgbgen vertex\n"
        "        alphagen vertex\n"
        "        map %s\n"
        "        map $lightmap\n"
        "    }\n"
        "}\n", twosided ? "    cull none\n" : "", maptarget);
};

// PLAIN (non-lightmap) decal shader body — the vertex-lit variant used by the trisoup path
// (addtrisoup_simple).  A precache_pic'd name is only a 2D shader and renders INVISIBLE through
// addtrisoup_simple (see cl_sprays.qc:344-353); registering this real decal shader under the plain
// name is what makes r_decal_renderer 1 (trisoup) actually draw.  rgbGen/alphaGen vertex so the
// per-vertex colour (bh_color surflight tint) + alpha the trisoup writer sets modulate the texture.
// Same body sprays build inline (cl_sprays.qc:280-296).  Shared: in scope for cl_bloodtrisoup.qc /
// cl_sprays.qc / cl_infodecal.qc (compiled after).
// `twosided` — see Decal_LMShaderBody above (0 = omit cull => engine default backface culling).
string(string maptarget, float twosided) Decal_BaseShaderBody =
{
    return sprintf(
        "{\n"
        "    sort decal\n"
        "    polygonoffset 8\n"
        "    nopicmip\n"
        "%s"
        "    {\n"
        "        map %s\n"
        "        rgbGen vertex\n"
        "        alphaGen vertex\n"
        "        blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n"
        "    }\n"
        "}\n", twosided ? "    cull none\n" : "", maptarget);
};

// Register/refresh the decal shaders for every bullet-hole texture (a FIXED set — unlike
// open-ended spray/infodecal names).  Called at the end of CSQC_BulletHolesInit AND from
// CSQC_RendererRestarted (vid_restart purges shaderforname shaders).  shaderforname is idempotent.
//
// TWO shaders per texture:
//   plain  <name>     — vertex-lit decal body, used by the TRISOUP path (addtrisoup_simple, mode 1)
//                       and the adddecal path when r_decal_lightmap is off.  THIS is the one that was
//                       missing — the names used to be precache_pic'd (2D only) → invisible in trisoup.
//   <name>_lm         — per-pixel-lightmap body, used by the adddecal path (modes 0/2) when the cvar is on.
// Init now stores bare names (no precache_pic), so these shaderforname calls create the shaders fresh.
void() CSQC_BulletHole_ReregisterShaders =
{
    float i;
    shaderforname(BULLETHOLE_QUAD_SHADER, Decal_BaseShaderBody(BULLETHOLE_QUAD_SHADER, FALSE));
    shaderforname(SNOWSPLAT_QUAD_SHADER,  Decal_BaseShaderBody(SNOWSPLAT_QUAD_SHADER, FALSE));
    shaderforname(strcat(BULLETHOLE_QUAD_SHADER, "_lm"), Decal_LMShaderBody(BULLETHOLE_QUAD_SHADER, FALSE));
    shaderforname(strcat(SNOWSPLAT_QUAD_SHADER,  "_lm"), Decal_LMShaderBody(SNOWSPLAT_QUAD_SHADER, FALSE));
    for (i = 0; i < BH_MAT_CONC_COUNT;  i = i + 1)
        if (bh_mat_path_conc[i]  != "") { shaderforname(bh_mat_path_conc[i],  Decal_BaseShaderBody(bh_mat_path_conc[i], FALSE));  shaderforname(strcat(bh_mat_path_conc[i],  "_lm"), Decal_LMShaderBody(bh_mat_path_conc[i], FALSE)); }
    for (i = 0; i < BH_MAT_WOOD_COUNT;  i = i + 1)
        if (bh_mat_path_wood[i]  != "") { shaderforname(bh_mat_path_wood[i],  Decal_BaseShaderBody(bh_mat_path_wood[i], FALSE));  shaderforname(strcat(bh_mat_path_wood[i],  "_lm"), Decal_LMShaderBody(bh_mat_path_wood[i], FALSE)); }
    for (i = 0; i < BH_MAT_METAL_COUNT; i = i + 1)
        if (bh_mat_path_metal[i] != "") { shaderforname(bh_mat_path_metal[i], Decal_BaseShaderBody(bh_mat_path_metal[i], FALSE)); shaderforname(strcat(bh_mat_path_metal[i], "_lm"), Decal_LMShaderBody(bh_mat_path_metal[i], FALSE)); }
    for (i = 0; i < BH_MAT_GLASS_COUNT; i = i + 1)
        if (bh_mat_path_glass[i] != "") { shaderforname(bh_mat_path_glass[i], Decal_BaseShaderBody(bh_mat_path_glass[i], FALSE)); shaderforname(strcat(bh_mat_path_glass[i], "_lm"), Decal_LMShaderBody(bh_mat_path_glass[i], FALSE)); }
    for (i = 0; i < BH_SPLAT_COUNT;     i = i + 1)
        if (bh_splat_path[i]     != "") { shaderforname(bh_splat_path[i],     Decal_BaseShaderBody(bh_splat_path[i], FALSE));     shaderforname(strcat(bh_splat_path[i],     "_lm"), Decal_LMShaderBody(bh_splat_path[i], FALSE)); }
    for (i = 0; i < BH_IMPACT_COUNT;    i = i + 1)
        if (bh_impact_path[i]    != "") { shaderforname(bh_impact_path[i],    Decal_BaseShaderBody(bh_impact_path[i], FALSE));    shaderforname(strcat(bh_impact_path[i],    "_lm"), Decal_LMShaderBody(bh_impact_path[i], FALSE)); }
    for (i = 0; i < BH_WORLD_WOOD_COUNT; i = i + 1)
        if (bh_world_wood_path[i] != "") { shaderforname(bh_world_wood_path[i], Decal_BaseShaderBody(bh_world_wood_path[i], FALSE)); shaderforname(strcat(bh_world_wood_path[i], "_lm"), Decal_LMShaderBody(bh_world_wood_path[i], FALSE)); }
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

    // Material/splat/impact decal variants.  Store the bare shader NAME only (NOT precache_pic'd):
    // CSQC_BulletHole_ReregisterShaders (called below) registers each name as a real decal shader via
    // shaderforname (plain + `_lm`).  precache_pic would create a competing 2D shader under the same name
    // that renders INVISIBLE through addtrisoup_simple (the trisoup path) and that shaderforname can't
    // replace — so we skip it.  The texture still loads via each shader's own `map` directive.
    float i;
    for (i = 0; i < BH_MAT_CONC_COUNT; i++)
        bh_mat_path_conc[i]  = sprintf("gfx/decals/impacts/conc%g",  i + 1);
    for (i = 0; i < BH_MAT_WOOD_COUNT; i++)
        bh_mat_path_wood[i]  = sprintf("gfx/decals/impacts/wood%g",  i + 1);
    for (i = 0; i < BH_MAT_METAL_COUNT; i++)
        bh_mat_path_metal[i] = sprintf("gfx/decals/impacts/metal%g", i + 1);
    for (i = 0; i < BH_MAT_GLASS_COUNT; i++)
        bh_mat_path_glass[i] = sprintf("gfx/decals/impacts/glass%g", i + 1);

    // Splat variants — shared by paintball + snow splats.  Same
    // 9-PNG set drives both effects via random per-spawn pick.
    for (i = 0; i < BH_SPLAT_COUNT; i++)
        bh_splat_path[i] = sprintf("gfx/impacts/paintball/splat%g", i + 1);

    // World/BSP bullet-hole variants — random per hit (see CSQC_SpawnBulletHole).
    for (i = 0; i < BH_IMPACT_COUNT; i++)
        bh_impact_path[i] = sprintf("gfx/impacts/impact%g", i + 1);

    // World/BSP WOOD variants — used on wood-tagged world surfaces (see CSQC_SpawnBulletHole).
    for (i = 0; i < BH_WORLD_WOOD_COUNT; i++)
        bh_world_wood_path[i] = sprintf("gfx/impacts/wood%g", i + 1);

    // (The barrel/can precaches that used to sit here named models/props/barrel.iqm and
    //  models/props/can.mdl — neither exists.  The real barrel/can models are precached
    //  server-side in phys_barrel_precache and resolved by CSQC_PhysProp_ResolveIndexes.)
    precache_model("gfx/fexplo.spr");       // CSQC_SpawnExplodeSprite (cl_bulletimpact.qc) — HL grenade fireball

    CSQC_BulletHole_ReregisterShaders();    // r_decal_lightmap `_lm` variants for the decal textures just precached
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
        if (hole.bh_handle > 0) removedecal(hole.bh_handle);   // r_bullethole_renderer 2: this raw-remove() loop bypasses CSQC_BulletHoleRemove — must free the handle here or round-restart leaks every one
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
    bh_baked_offset        = 0;   // next post-wipe poll lifts fresh holes from 0 to the cvar
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
    // r_decal_lightmap: `_lm` program variant + WHITE rgb (the world lightmap lights the hole
    // per-pixel); else the plain shader + bh_color (the surface-light tint / cl_decal_surflight).
    if (cvar("r_decal_lightmap"))
        adddecal(strcat(shader_path, "_lm"), decal_origin,
                 normal_arg, side_arg, '1 1 1',
                 hole.alpha * CSQC_DecalOpacity());
    else
        adddecal(shader_path, decal_origin,
                 normal_arg, side_arg, hole.bh_color,
                 hole.alpha * CSQC_DecalOpacity());
};

// r_bullethole_renderer 2 (PERSISTENT LIT): clip a STATIC (world) hole ONCE via adddecal_static and cache
// the handle, so the engine re-emits it cheaply every frame instead of the per-frame BSP re-clip — while
// keeping the per-pixel lightmap.  Same arg math as CSQC_DrawBulletHoleDecal (bullet holes are square →
// aspect 1, permanent → lifetime 0).  Tracked (moving-brushmodel) holes are NOT persisted (they move).
void(entity hole) CSQC_BulletHole_CreatePersistent =
{
    vector normal_arg, side_arg, decal_origin;
    float full_size;

    makevectors(hole.angles);
    if (hole.bh_half_size > 0)
        full_size = hole.bh_half_size * 2;
    else if (hole.bh_snow)
        full_size = SNOWSPLAT_DECAL_HALF_SIZE * 2;
    else
        full_size = BULLETHOLE_DECAL_HALF_SIZE * 2;
    normal_arg = -v_forward;
    side_arg = v_right / full_size;
    decal_origin = hole.bh_decal_origin + normal_arg * BULLETHOLE_DECAL_BIAS;

    string shader_path = hole.bh_shader_path;
    if (!shader_path)
        shader_path = hole.bh_snow ? SNOWSPLAT_QUAD_SHADER : BULLETHOLE_QUAD_SHADER;

    float h;
    if (cvar("r_decal_lightmap"))
        h = adddecal_static(strcat(shader_path, "_lm"), decal_origin,
                            normal_arg, side_arg, '1 1 1',
                            hole.alpha * CSQC_DecalOpacity(), 1, 0);
    else
        h = adddecal_static(shader_path, decal_origin,
                            normal_arg, side_arg, hole.bh_color,
                            hole.alpha * CSQC_DecalOpacity(), 1, 0);
    hole.bh_handle = (h >= 0) ? h : -1;   // -1 = off-surface; don't retry every frame
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

    // Tangent / bitangent frame — derived from the SAME makevectors(hole.angles) basis the adddecal
    // REFERENCE path uses (CSQC_DrawBulletHoleDecal).  hole.angles already encodes the random bh_quad_rot
    // in angles_z (all 3 callers pitch-negate + set angles_z = rot*90), so the rotation flows through
    // makevectors IDENTICALLY to modes 0/2 — no separate swap.  The corner→UV mapping below (U along
    // +tangent, V along -bitangent) is 180 deg from the engine's actual adddecal texture mapping, so both
    // axes are NEGATED here to bring mode-1 upright to match modes 0/2 (a 180 deg spin about the normal).
    makevectors(hole.angles);
    vector tangent   = crossproduct(v_right, v_forward);   // = -cross(v_forward,v_right): U axis, 180-flipped
    vector bitangent = v_right;                            // corners use V = -bitangent = -v_right

    float half = hole.bh_half_size > 0
                 ? hole.bh_half_size
                 : (hole.bh_snow ? SNOWSPLAT_DECAL_HALF_SIZE
                                 : BULLETHOLE_DECAL_HALF_SIZE);

    // Push slightly off the surface to avoid z-fighting.  Uses bh_baked_offset (not the
    // live cvar) so the StartFrame poll's uniform shift keeps every static quad consistent.
    vector center = hit_pos + world_normal * bh_baked_offset;

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
    // adddecal mode (r_bullethole_renderer 0) since that path
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

    // Tracked (brushmodel) holes recompute every frame, so read the live cvar directly —
    // changing r_decal_offset updates them next frame with no shift pass.
    float trk_off = cvar("r_decal_offset");   // UNIFIED decal offset (was r_bullethole_offset)
    if (trk_off < 0) trk_off = 0;
    vector center = world_pos + world_normal * trk_off;

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

// ===== Live decal-offset refresh (shared by all 3 tri-soup renderers) =====
// Translate a quad's 4 verts (v[0..3]) along the surface normal by `delta`.  The normal
// is recovered from the quad's own coplanar corners — no stored normal needed:
//   n = cross(v1-v0, v3-v0); fallback cross(v1-v0, v2-v0) for a clipped n==3 quad
//   (q3==q2); skip a degenerate/cleared (zero-area) slot.
// NOTE: trisoup_simple_vert_t.xyz is float[3], not a vector — read/write per component.
void(trisoup_simple_vert_t *v, float delta) Decal_ShiftQuadVerts =
{
    vector v0 = [v[0].xyz[0], v[0].xyz[1], v[0].xyz[2]];
    vector v1 = [v[1].xyz[0], v[1].xyz[1], v[1].xyz[2]];
    vector v2 = [v[2].xyz[0], v[2].xyz[1], v[2].xyz[2]];
    vector v3 = [v[3].xyz[0], v[3].xyz[1], v[3].xyz[2]];
    vector n = crossproduct(v1 - v0, v3 - v0);
    if (vlen(n) <= 0.0001)
        n = crossproduct(v1 - v0, v2 - v0);
    if (vlen(n) <= 0.0001)
        return;                       // degenerate / cleared slot
    n = normalize(n) * delta;
    int k;
    for (k = 0; k < 4; k = k + 1)
    {
        v[k].xyz[0] = v[k].xyz[0] + n_x;
        v[k].xyz[1] = v[k].xyz[1] + n_y;
        v[k].xyz[2] = v[k].xyz[2] + n_z;
    }
};

// Shift the persistent STATIC bullet-hole + snow quads by `delta` on a live
// r_bullethole_offset change.  Only the static prefix [0, *_static_count) — the
// per-frame dynamic/tracked suffix rebakes at the live cvar each frame.
void(float delta) BH_ShiftStaticQuads =
{
    int s;
    for (s = 0; s < bh_bullet_static_count; s = s + 1)
        Decal_ShiftQuadVerts(&bh_bullet_verts[s * 4], delta);
    for (s = 0; s < bh_snow_static_count; s = s + 1)
        Decal_ShiftQuadVerts(&bh_snow_verts[s * 4], delta);
};

// Shift the per-quad (bh_pq_head) holes' baked corners by `delta` along their surface normal on a
// live r_decal_offset change.  BH_ShiftStaticQuads above only touches the (now-dead) bh_bullet/snow
// static VERT buffers — but WORLD bullet holes + snow/paint splats store their corners in the entity
// fields bh_quad_p0..p3 and draw from THOSE (CSQC_DrawBakedBulletHole), so without this they never
// re-lift when r_decal_offset changes.  Normal recovered per hole from makevectors(h.angles):
// v_forward = -world_normal (all spawn paths pitch-negate), so the outward lift is delta * -v_forward.
void(float delta) BH_ShiftPQHoles =
{
    entity h = bh_pq_head;
    while (h)
    {
        if (h.bh_quad_p0 != h.bh_quad_p2)   // skip degenerate (zeroed-corner) holes
        {
            makevectors(h.angles);
            vector d = v_forward * (0 - delta);   // world normal = -v_forward; lift outward by delta
            h.bh_quad_p0 = h.bh_quad_p0 + d;
            h.bh_quad_p1 = h.bh_quad_p1 + d;
            h.bh_quad_p2 = h.bh_quad_p2 + d;
            h.bh_quad_p3 = h.bh_quad_p3 + d;
        }
        h = h.bh_pq_next;
    }
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
    bh_cache_renderer  = cvar("r_decal_renderer");   // UNIFIED decal renderer (was r_bullethole_renderer) — one cvar for bulletholes/sprays/infodecals/blood
    bh_cache_polygon   = bh_cache_renderer == 1;   // trisoup ONLY on mode 1 (mode 2 = persistent-lit, handled below)
    // r_bullethole_renderer 2 = PERSISTENT LIT: static world holes are clipped ONCE by the engine
    // (adddecal_static) and re-emitted cheaply.  On a switch AWAY from mode 2, free every hole's engine
    // handle once (else the engine keeps emitting them under the mode-0/1 draw = double).
    if (bh_cache_renderer != 2 && bh_last_renderer == 2)
    {
        entity ch = bh_head;
        while (ch)
        {
            if (ch.bh_handle > 0) removedecal(ch.bh_handle);
            ch.bh_handle = 0;
            ch = ch.bh_next;
        }
    }
    bh_last_renderer   = bh_cache_renderer;
    bh_cache_max       = cvar("cl_bulletholes_max");
    if (bh_cache_max < 1) bh_cache_max = 1;     // sanity floor
    // Cap at the fixed pool: above BH_TRISOUP_MAX_QUADS the eviction loops (bh_count >=
    // bh_cache_max) can never fire, so old holes never evict and new ones get slot -1 (invisible).
    if (bh_cache_max > BH_TRISOUP_MAX_QUADS) bh_cache_max = BH_TRISOUP_MAX_QUADS;
    bh_cache_clip_geom = cvar("cl_bullethole_clip_geom") != 0;

    // Live r_decal_offset: re-shift the baked quads when it changes.  BH_ShiftStaticQuads handles the
    // static VERT buffers; BH_ShiftPQHoles handles the per-quad bh_pq_head holes (world bullet holes +
    // snow/paint splats) whose corners live in bh_quad_p0..p3.  (Runs after the static-count reset above.)
    float bh_want_off = cvar("r_decal_offset");   // UNIFIED decal offset (was r_bullethole_offset)
    if (bh_want_off < 0) bh_want_off = 0;   // negative would lift into the wall
    if (bh_want_off != bh_baked_offset)
    {
        BH_ShiftStaticQuads(bh_want_off - bh_baked_offset);
        BH_ShiftPQHoles(bh_want_off - bh_baked_offset);
        bh_baked_offset = bh_want_off;
    }

    // Frustum/distance-cull state for the per-hole cull in CSQC_DrawBulletHoleTexture (owner==world holes).
    // Needed in mode 0 (bh_head walk) AND mode 1 (world bullet holes + snow/paint render via the bh_pq_head
    // walk → CSQC_DrawBakedBulletHole, which still runs the owner==world cull).  ONLY mode 2 (persistent,
    // engine-emitted, not per-hole culled) can skip it.  (Was gated `!bh_cache_polygon`, which starved mode 1
    // of fresh cull state → world holes were culled against a STALE camera and vanished.)
    if (bh_cache_renderer != 2)
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
    // In legacy adddecal mode (r_bullethole_renderer 0), static
    // holes need a per-frame adddecal call so we keep the full
    // bh_head walk for that path.
    if (!CSQC_BulletHolesEnabled())
    {
        // skip both walks AND the submit; nothing should render
    }
    else if (bh_cache_renderer == 2)
    {
        // PERSISTENT LIT (r_bullethole_renderer 2): each STATIC (world) hole is clipped ONCE by the engine
        // (adddecal_static) and re-emitted cheaply every frame — no per-frame BSP re-clip, keeps the
        // per-pixel lightmap.  Reconcile handles here (create once for handle-less static holes); the engine
        // draws them, so nothing is submitted for them.  Snow/paint world splats are static too → also
        // persisted.  This walk is cheap (a handle check per hole) vs. the ≤1024 BSP re-clips mode 0 paid.
        hole = bh_head;
        while (hole)
        {
            next = hole.bh_next;
            if (!hole.bh_dynamic && hole.bh_handle == 0)
                CSQC_BulletHole_CreatePersistent(hole);
            hole = next;
        }
        // Tracked (moving-brushmodel) holes can't be persisted (adddecal_static clips once against static
        // world) — keep them on the per-frame trisoup path (submitted below, same as mode 1).
        hole = bh_dyn_head;
        while (hole)
        {
            next = hole.bh_dyn_next;
            CSQC_DrawBulletHoleTexture(hole);
            hole = next;
        }
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
    // Mode 2 also submits — but static holes were NOT baked into the trisoup buffer (bh_cache_polygon is
    // false in mode 2, so CSQC_BakeStaticBulletHoleQuad's :1336 gate skipped them → static_count stays 0),
    // so this submits only the tracked (moving-brushmodel) suffix.  No double with the persistent decals.
    if (CSQC_BulletHolesEnabled() && (bh_cache_polygon || bh_cache_renderer == 2))
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
// DEPRECATED no-op: the per-shot cap is now scoped by action_id (CSQC_BulletHole_CapAllows),
// which self-resets per shot regardless of the deferred impact queue — so the fire-time reset
// this used to do (the cause of the cross-shot decal leak) is gone.  Kept as a no-op so the
// existing call sites in sh_weapon_*.qc need no change.
void() CSQC_BulletHoles_ResetShot =
{
};

// Per-shot bullet-hole cap, keyed by the shot's action_id (which EVERY impact of a shot carries,
// entry + penetration exits alike).  Robust to the deferred impact QUEUE draining shots out of
// order: each shot counts against its OWN ring slot, so a slow-arriving exit decal from an
// earlier shot can't leak past its cap onto the wall behind, and it can't steal a later shot's
// slot.  Returns TRUE (consuming one) when a hole is allowed under cl_bulletholes_per_shot.
float(float action) CSQC_BulletHole_CapAllows =
{
    if (bh_shotgun_blast)
        return TRUE;                    // shotgun blast = one trigger pull, whole pellet spread shows
    float cap = cvar("cl_bulletholes_per_shot");
    if (cap <= 0)
        return TRUE;                    // 0 = unlimited
    if (action < 0)
        return TRUE;                    // remote impacts carry no per-shot id (-1) — isolated, not capped here
    float slot = action - (floor(action / BH_SHOTRING) * BH_SHOTRING);   // 0..BH_SHOTRING-1
    if (bh_shot_action[slot] != action)
    {
        bh_shot_action[slot] = action;  // a new shot landed in this slot -> fresh count
        bh_shot_count[slot]  = 0;
    }
    if (bh_shot_count[slot] >= cap)
        return FALSE;                   // this shot already placed `cap` holes
    bh_shot_count[slot] = bh_shot_count[slot] + 1;
    return TRUE;
};

void(vector hit_pos, vector hit_normal, entity hit_target, float impact_mat, float action) CSQC_SpawnBulletHole =
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

    // Per-shot cap (cl_bulletholes_per_shot) — scoped by the shot's action_id so overlapping
    // (sprayed) shots each keep their own nearest-N decals regardless of the deferred impact
    // queue's drain order.  Placed AFTER the sky/solid/PVS rejects above so a rejected exit-hit
    // doesn't consume a slot.  Shotgun blasts + the unlimited/remote cases bypass (see the fn).
    if (!CSQC_BulletHole_CapAllows(action))
        return;

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
    // Surface-light tint (cl_decal_surflight 1, default) so holes dim/brighten with the
    // wall like infodecals, instead of full-bright.  Sampled once here; baked into the
    // trisoup verts + passed to adddecal (both consume bh_color).  Phase-3 per-pixel
    // (engine r_decal_lightmap) overrides this to white at the adddecal call site.
    if (cvar("cl_decal_surflight"))
    {
        float bhls = cvar("cl_decal_lightscale");
        if (bhls <= 0) bhls = 1.5;
        vector bhlt = getlight(hit_pos + hit_normal * 2) * (bhls / 255);
        hole.bh_color_x = bound(0, bhlt_x, 1);
        hole.bh_color_y = bound(0, bhlt_y, 1);
        hole.bh_color_z = bound(0, bhlt_z, 1);
    }
    else
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

    // Default world/plain-brush hit (no material decal from BH_PickMaterialDecal): a RANDOM one of
    // the four gfx/impacts/impactN, sized by cl_bullethole_impact_size (full units across, default
    // 6).  Wood-tagged world surfaces (impact_mat == IMPACT_MAT_WOOD, from scripts/surfaceprops.txt)
    // use gfx/impacts/woodN instead — same world-hit path + sizing, different art.
    // is_impact_default / is_world_wood drive the rotation choice below.
    float is_impact_default = 0;
    float is_world_wood = 0;
    if (!hole.bh_shader_path)
    {
        float impfull = cvar("cl_bullethole_impact_size");
        if (impfull <= 0) impfull = 6;
        hole.bh_half_size = impfull * 0.5;
        if (impact_mat == IMPACT_MAT_WOOD)
        {
            hole.bh_shader_path = bh_world_wood_path[(int)floor(random() * BH_WORLD_WOOD_COUNT)];
            is_world_wood = 1;
        }
        else
        {
            hole.bh_shader_path = bh_impact_path[(int)floor(random() * BH_IMPACT_COUNT)];
            is_impact_default = 1;
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
    //   impact1-4 (world default) — fixed orientation (the art has baked directional shadow).
    //          Steps go clockwise (rot 1 = 90-deg right); the art reads 90-deg-right at rot 0,
    //          so rot 3 (270 = 90-deg left) brings it upright.  Random texture pick per hit.
    //   wood1-4 (world wood) — same 90-deg-right baked offset as impact1-4, so rot 3 (270 = 90-deg
    //          left) brings it upright.  Locked; random texture pick per hit.
    if (is_impact_default)
        hole.bh_quad_rot = 3;
    else if (is_world_wood)
        hole.bh_quad_rot = 3;
    else if (impact_mat == IMPACT_MAT_WOOD)
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
    else if (hole.bh_shader_path)
    {
        // Static (world-hit) bullet hole carries a per-variant shader (gfx/impacts/impactN|woodN) so it gets
        // no batched trisoup slot — link it into bh_pq so the r_decal_renderer 1 (tri-soup) draw walk visits
        // it for a BH_SubmitOneQuad call (mirrors CSQC_SpawnSnowSplat).  Without this, world bullet holes
        // VANISH in mode 1 (modes 0/2 walk bh_head so they still show there; only mode 1 was broken).
        hole.bh_pq_prev = bh_pq_tail;
        hole.bh_pq_next = world;
        if (bh_pq_tail)
            bh_pq_tail.bh_pq_next = hole;
        else
            bh_pq_head = hole;
        bh_pq_tail = hole;
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
    CSQC_SpawnBulletHole(trace_endpos, trace_plane_normal, trace_ent, mat, -1);   // one-off trace decal — no per-shot grouping
};
