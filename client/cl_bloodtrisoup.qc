// ============================================================
//  client/cl_bloodtrisoup.qc  -  Baked trisoup batch for blood decals
//
//  Blood splats used to call adddecal() once PER DECAL PER FRAME, which
//  re-projects the texture onto the BSP every frame (~1.0 s/frame with a
//  full BLOOD_MAX pool).  This module bakes each splat's world-space
//  geometry ONCE at spawn — clipped to the hit surface's triangle edges
//  the same way bullet holes are (BH_ClipQuadToHitTri) — and submits it
//  each frame with ONE addtrisoup_simple call per texture.  The geometry
//  is static; only the 4 vertex alphas are rewritten per frame to drive
//  the fade (blood holds full alpha for BLOOD_FADE_START seconds then
//  fades to BLOOD_FADE_END).
//
//  COMPILE ORDER: this file is listed in cl_progs.src immediately AFTER
//  client/cl_bulletholes.qc, so the BH_* clip/write helpers (BH_WriteQuad,
//  BH_WriteQuadUV, BH_ClipQuadToHitTri, BH_FindHitTriangle, the bh_io_*
//  globals, …) are in scope.  cl_bloodsplat.qc compiles BEFORE
//  cl_bulletholes.qc and only forward-declares the three public Blood_*
//  functions defined here.
//
//  TEXTURE PARTITIONS: blood spawns pick bs_tex = 1..7 at random, and
//  addtrisoup_simple takes ONE shader per call, so the vertex/index pool
//  is split into 7 contiguous partitions (one per BLOOD_SHADER_N).  A
//  splat in texture T lives in partition (T-1); its slot/free-list/count
//  are all indexed by that partition.  Worst case all BLOOD_MAX splats
//  could land in one texture, so each partition is sized to the full cap.
// ============================================================

const int BLOOD_TEX_COUNT     = 7;
// Per-texture quad capacity.  Worst case every one of the BLOOD_MAX (96)
// live splats picks the same texture, so each partition must hold the
// full cap.  Read from BLOOD_MAX in cl_bloodsplat.qc — keep in sync.
const int BLOOD_TRISOUP_MAX   = 96;        // == BLOOD_MAX
// Off-surface nudge + half-extent, mirroring CSQC_BakeStaticBulletHoleQuad
// and the old CSQC_DrawBloodDecals projection size.
const float BLOOD_BAKE_NUDGE  = 0.4;

// Flattened per-texture buffers.  Partition t occupies:
//   verts: [t*BLOOD_TRISOUP_MAX*4, (t+1)*BLOOD_TRISOUP_MAX*4)
//   idx:   [t*BLOOD_TRISOUP_MAX*6, (t+1)*BLOOD_TRISOUP_MAX*6)
// BH_WriteQuad / BH_WriteQuadUV are passed &blood_verts[part_base] /
// &blood_idx[part_base] so the indices they write are relative to that
// partition's sub-array — exactly what addtrisoup_simple wants for the
// per-texture draw.
auto trisoup_simple_vert_t blood_verts[7 * 96 * 4];
auto int                   blood_idx  [7 * 96 * 6];

// Per-texture slot bookkeeping (mirrors bh_bullet_static_count / _count /
// _free / _free_count, one set per texture partition).
int blood_static_count[7];      // high-water mark of allocated slots in this partition
int blood_count[7];             // submit count (== static_count; blood has no dynamic suffix)
auto int blood_free[7 * 96];    // per-partition free lists (flattened: part t at [t*MAX, …))
int blood_free_count[7];

// .bs_slot (declared in cl_bloodsplat.qc, init -1 at spawn) holds the
// ABSOLUTE slot index across the whole flattened buffer (partition base +
// local slot), so the fade helper / free path can address the verts
// without re-deriving the partition.  -1 = unbaked.

// ------------------------------------------------------------------
//  Allocation — mirrors BH_AllocStaticSlot / BH_AllocStaticSlotUV but
//  indexed into texture `part`'s partition.  Returns the ABSOLUTE slot
//  index (partition base + local slot), or -1 if the partition is full.
//  `use_uv` routes through BH_WriteQuadUV (clipped fragment) when set,
//  else BH_WriteQuad (axis-aligned quad).  Caller sets bh_io_uv0..3
//  before calling with use_uv=1 (BH_WriteQuadUV reads them).
// ------------------------------------------------------------------
float(float part, float use_uv,
      vector p0, vector p1, vector p2, vector p3,
      vector col, float alpha) Blood_AllocSlot =
{
    int p = (int)part;
    int local_slot;
    int free_base = p * BLOOD_TRISOUP_MAX;

    if (blood_free_count[p] > 0)
    {
        blood_free_count[p] = blood_free_count[p] - 1;
        local_slot = blood_free[free_base + blood_free_count[p]];
    }
    else
    {
        if (blood_static_count[p] >= BLOOD_TRISOUP_MAX)
            return -1;
        local_slot = blood_static_count[p];
        blood_static_count[p] = blood_static_count[p] + 1;
    }
    if (blood_count[p] < blood_static_count[p])
        blood_count[p] = blood_static_count[p];

    // Partition base in vert/idx units.  BH_WriteQuad indexes its passed
    // base by local_slot*4 / local_slot*6, so the written indices are
    // partition-relative — correct for the per-texture submit.
    int vpart = p * BLOOD_TRISOUP_MAX * 4;
    int ipart = p * BLOOD_TRISOUP_MAX * 6;
    if (use_uv)
        BH_WriteQuadUV(local_slot, p0, p1, p2, p3, col, alpha,
                       &blood_verts[vpart], &blood_idx[ipart]);
    else
        BH_WriteQuad(local_slot, p0, p1, p2, p3, col, alpha,
                     &blood_verts[vpart], &blood_idx[ipart]);

    // Absolute slot index = partition slot offset + local slot.
    return p * BLOOD_TRISOUP_MAX + local_slot;
};

// ------------------------------------------------------------------
//  Bake one splat's geometry ONCE at spawn.  Builds the 4 quad corners
//  from bs.bs_origin + bs.bs_normal + a tangent/bitangent frame (same
//  construction as CSQC_BakeStaticBulletHoleQuad), optionally runs the
//  Source-style edge clip against the hit BSP triangle, then allocates a
//  slot in texture (bs.bs_tex-1)'s partition and stores the absolute slot
//  index in bs.bs_slot.  Per-vertex colour = brightness tint, alpha = 1.0
//  (the fade is applied live each frame by Blood_SetSlotAlpha).
// ------------------------------------------------------------------
void(entity bs) Blood_BakeTrisoup =
{
    bs.bs_slot = -1;

    if (vlen(bs.bs_normal) <= 0.001)
        return;

    vector world_normal = normalize(bs.bs_normal);

    // Tangent / bitangent frame.  bs.bs_tangent was already computed at
    // spawn from the same reference-axis trick, so reuse it for the
    // tangent and derive the bitangent from the cross.
    vector tangent = bs.bs_tangent;
    if (vlen(tangent) <= 0.001)
    {
        vector ref;
        if (fabs(world_normal_z) < 0.9)
            ref = '0 0 1';
        else
            ref = '1 0 0';
        tangent = normalize(crossproduct(world_normal, ref));
    }
    vector bitangent = crossproduct(world_normal, tangent);

    float size_scale = bs.bs_size_scale;
    if (size_scale <= 0) size_scale = 1.0;
    float half = BLOOD_HALF_SIZE * size_scale;

    // Push slightly off the surface to avoid z-fighting.
    vector center = bs.bs_origin + world_normal * BLOOD_BAKE_NUDGE;

    vector q0 = center - tangent * half - bitangent * half;
    vector q1 = center + tangent * half - bitangent * half;
    vector q2 = center + tangent * half + bitangent * half;
    vector q3 = center - tangent * half + bitangent * half;

    // Default (unclipped) UVs seed the bh_io_uv* globals.  When the clip
    // runs it propagates UVs through Sutherland-Hodgman so the surviving
    // fragment shows only the visible slice of the texture.
    bh_io_uv0 = '0 1 0';
    bh_io_uv1 = '1 1 0';
    bh_io_uv2 = '1 0 0';
    bh_io_uv3 = '0 0 0';
    float clipped = 0;

    // Source-style edge clip against the hit BSP triangle — reuses the
    // bullet-hole clip path verbatim (BH_* in scope because this file
    // compiles after cl_bulletholes.qc).  Gated on cl_blood_decals_clip.
    if (cvar("cl_blood_decals_clip") != 0)
    {
        float surf = getsurfacenearpoint(world, bs.bs_origin);
        if (surf >= 0)
        {
            float tri = BH_FindHitTriangle(world, surf, bs.bs_origin);
            if (tri >= 0)
            {
                vector idx = getsurfacetriangle(world, surf, tri);
                bh_io_tv0 = getsurfacepoint(world, surf, idx_x);
                bh_io_tv1 = getsurfacepoint(world, surf, idx_y);
                bh_io_tv2 = getsurfacepoint(world, surf, idx_z);
                bh_io_surf    = surf;
                bh_io_hit_tri = tri;
                vector sn = getsurfacenormal(world, surf);
                if (vlen(sn) > 0.001)
                {
                    bh_io_sn = normalize(sn);
                    clipped = BH_ClipQuadToHitTri(q0, q1, q2, q3);
                }
            }
        }
    }

    // Per-vertex colour = brightness tint; alpha baked at 1.0 (fade is
    // rewritten live each frame, geometry stays baked).
    float bright = cvar("cl_blood_decals_brightness");
    if (bright <= 0) bright = 0.4;
    vector tint = [bright, bright, bright];

    float part = bs.bs_tex - 1;
    if (part < 0) part = 0;
    if (part > BLOOD_TEX_COUNT - 1) part = BLOOD_TEX_COUNT - 1;

    bs.bs_slot = Blood_AllocSlot(part, clipped, q0, q1, q2, q3, tint, 1.0);
    // The 4 baked vertex alphas start at 1.0; seed the change-detection cache to
    // match so the opaque hold (alpha stays 1.0) issues zero per-frame rewrites.
    bs.bs_last_alpha = 1.0;
};

// ------------------------------------------------------------------
//  Free a splat's baked slot — zero its 4 vertex alphas (degenerate, GPU
//  skips it) and push the local slot back onto its partition's free list.
//  Mirrors BH_FreeStaticSlot.  Safe no-op when bs_slot is the -1 sentinel.
// ------------------------------------------------------------------
void(entity bs) Blood_FreeTrisoupSlot =
{
    if (bs.bs_slot < 0) return;
    int abs_slot = (int)bs.bs_slot;
    int p = abs_slot / BLOOD_TRISOUP_MAX;
    if (p < 0 || p > BLOOD_TEX_COUNT - 1) { bs.bs_slot = -1; return; }
    int local_slot = abs_slot - p * BLOOD_TRISOUP_MAX;

    int vbase = abs_slot * 4;
    blood_verts[vbase + 0].rgba[3] = 0;
    blood_verts[vbase + 1].rgba[3] = 0;
    blood_verts[vbase + 2].rgba[3] = 0;
    blood_verts[vbase + 3].rgba[3] = 0;

    int free_base = p * BLOOD_TRISOUP_MAX;
    blood_free[free_base + blood_free_count[p]] = local_slot;
    blood_free_count[p] = blood_free_count[p] + 1;

    bs.bs_slot = -1;
};

// ------------------------------------------------------------------
//  Live per-frame fade — write a splat's current alpha into its 4 baked
//  vertices.  Cheap (4 array writes); only the alpha channel changes,
//  the geometry stays baked from spawn.  abs_slot indexes the flattened
//  vert buffer directly (partition math already folded into bs_slot).
// ------------------------------------------------------------------
void(float abs_slot, float alpha) Blood_SetSlotAlpha =
{
    int vbase = (int)abs_slot * 4;
    blood_verts[vbase + 0].rgba[3] = alpha;
    blood_verts[vbase + 1].rgba[3] = alpha;
    blood_verts[vbase + 2].rgba[3] = alpha;
    blood_verts[vbase + 3].rgba[3] = alpha;
};

// ------------------------------------------------------------------
//  Per-frame draw — ONE addtrisoup_simple per non-empty texture.  The
//  vertex data persists across frames; only the alphas were touched this
//  frame by Blood_SetSlotAlpha.  The engine frustum-culls the trisoup.
// ------------------------------------------------------------------
void() Blood_DrawTrisoup =
{
    float t;
    for (t = 0; t < BLOOD_TEX_COUNT; t = t + 1)
    {
        int p = (int)t;
        if (blood_count[p] <= 0)
            continue;
        int vpart = p * BLOOD_TRISOUP_MAX * 4;
        int ipart = p * BLOOD_TRISOUP_MAX * 6;
        addtrisoup_simple(CSQC_BloodShaderForIndex(t + 1), 0,
                          &blood_verts[vpart], &blood_idx[ipart],
                          blood_count[p] * 6);
    }
};

// ------------------------------------------------------------------
//  Reset all partitions (round restart / wipe).  Drains free lists and
//  resets high-water marks so the next round starts with a clean pool.
//  Mirrors the bullet-hole WipeAll buffer reset.
// ------------------------------------------------------------------
void() Blood_ResetTrisoup =
{
    float t;
    for (t = 0; t < BLOOD_TEX_COUNT; t = t + 1)
    {
        blood_static_count[(int)t] = 0;
        blood_count[(int)t]        = 0;
        blood_free_count[(int)t]   = 0;
    }
};
