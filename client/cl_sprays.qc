// =============================================================
//  Player spray decals — CSQC
// =============================================================
//
//  Receives CSQC_EVENT_SPRAY / CSQC_EVENT_SPRAY_REMOVE from the
//  server (see server/sv_spray.qc).  Each spray is a flat textured
//  quad projected onto the hit surface, batched into a trisoup
//  buffer for cheap submission via addtrisoup_simple — same render
//  technique cl_bulletholes.qc uses.
//
//  Bucketed batching
//  -----------------
//  Each spray uses a per-player PNG (gfx/sprays/<name>.png).  A
//  single trisoup submission is keyed by ONE shader path, so to
//  render multiple players' different sprays we partition the
//  active set across SPRAY_BUCKETS buckets, each holding quads of
//  one PNG.  If all buckets are in use and a new distinct PNG
//  arrives, the LRU bucket is evicted wholesale (all its quads
//  disappear).  In practice servers with sv_spraymax ≤ 4 won't hit
//  this often; if it becomes a problem we expand SPRAY_BUCKETS.
//
//  Surface-projection math is copied verbatim from
//  CSQC_BakeStaticBulletHoleQuad (cl_bulletholes.qc:578+) so the
//  spray orientation matches bullet holes for the same wall.

const int   SPRAY_BUCKETS     = 4;
const int   SPRAY_PER_BUCKET  = 16;
const float SPRAY_QUAD_HALF   = 32;       // 64u square (2x HL parity, mapper preference)
const float SPRAY_DECAL_OFFSET = 0.4;     // world-space bias off surface.
                                          // Matches the bullet-hole baseline
                                          // (cl_bulletholes.qc:15
                                          // BULLETHOLE_OFFSET_MIN = 0.3).
                                          // The previous 1.5u was a hedge
                                          // for users without a shader-script
                                          // entry — now that shaderforname
                                          // registers a polygonoffset-aware
                                          // shader at runtime for every spray
                                          // (cl_sprays.qc:285), we can rely
                                          // on the GPU depth bias and keep
                                          // the world-space lift small
                                          // enough that the spray reads as
                                          // FLUSH against the wall instead
                                          // of floating off it.

// --- adddecal-style storage (cl_spray_style 1) ---
// Parallel set of arrays for the BSP-wrapping decal path.  Each entry
// is one active spray; on the per-frame draw pass we call adddecal()
// for each.  Lifetime is FIFO (matches the quad path) — REMOVE event
// from the server clears the slot.  Capped at SPRAY_ADDECAL_MAX which
// generously exceeds sv_spraymax × player count for typical play.
const int SPRAY_ADDECAL_MAX = 32;
float  sp_dec_id      [SPRAY_ADDECAL_MAX];    // spray_id, 0 = free
string sp_dec_shader  [SPRAY_ADDECAL_MAX];
vector sp_dec_origin  [SPRAY_ADDECAL_MAX];
vector sp_dec_normal  [SPRAY_ADDECAL_MAX];
vector sp_dec_side    [SPRAY_ADDECAL_MAX];    // tangent / (full size), per adddecal API

// --- One bucket per active PNG path ---
//
// `tex` holds the shader path the bucket batches.  Empty string
// means "free bucket".  `lru_time` is the cltime of the most-recent
// allocation into this bucket, used for LRU eviction when a fifth
// distinct PNG shows up.
// Each quad uses 4 vertices and 12 indices (4 triangles — two for the
// front face, two for the back).  Double-sided lets sprays render
// without requiring a `cull none` shader for every spray PNG: even
// the engine's default sprite-shader fallback (which has back-face
// culling enabled) will show ONE of the two faces from any viewer
// angle.  The "back" triangles reuse the same vertices in reverse
// winding, which means the back side shows the image mirrored — but
// you only see the back from inside the wall, which doesn't happen
// in normal play.
string sp_bucket_tex     [SPRAY_BUCKETS];
float  sp_bucket_lru_time[SPRAY_BUCKETS];
trisoup_simple_vert_t sp_bucket_verts[SPRAY_BUCKETS * SPRAY_PER_BUCKET * 4];
int                   sp_bucket_idx  [SPRAY_BUCKETS * SPRAY_PER_BUCKET * 12];
int                   sp_bucket_count[SPRAY_BUCKETS];  // active quad count in this bucket
int                   sp_bucket_free [SPRAY_BUCKETS * SPRAY_PER_BUCKET];
int                   sp_bucket_free_count[SPRAY_BUCKETS];

// Per-slot bookkeeping for REMOVE event lookup.  spray_id 0 = unused.
// slot index = bucket * SPRAY_PER_BUCKET + within-bucket.
float sp_slot_id[SPRAY_BUCKETS * SPRAY_PER_BUCKET];

// ---------- Bucket allocator ----------

// Find a bucket that already batches this PNG, or claim an empty
// one, or evict the LRU bucket.  Returns the bucket index.
float(string tex) CSQC_Spray_FindBucket =
{
    int i;

    // Match existing
    for (i = 0; i < SPRAY_BUCKETS; i = i + 1)
    {
        if (sp_bucket_tex[i] == tex)
        {
            sp_bucket_lru_time[i] = cltime;
            return i;
        }
    }

    // Find empty
    for (i = 0; i < SPRAY_BUCKETS; i = i + 1)
    {
        if (sp_bucket_tex[i] == "")
        {
            sp_bucket_tex[i] = tex;
            sp_bucket_lru_time[i] = cltime;
            sp_bucket_count[i] = 0;
            sp_bucket_free_count[i] = 0;
            return i;
        }
    }

    // All buckets in use — evict the LRU one and reclaim.
    float lru_idx = 0;
    float lru_t   = sp_bucket_lru_time[0];
    for (i = 1; i < SPRAY_BUCKETS; i = i + 1)
    {
        if (sp_bucket_lru_time[i] < lru_t)
        {
            lru_idx = i;
            lru_t   = sp_bucket_lru_time[i];
        }
    }

    // Zero the bucket's contents.  We don't send REMOVE events to the
    // server here — server's still tracking those sprays in its FIFO.
    // If the player who owns the evicted sprays sprays again, server
    // will eventually FIFO-evict them; until then the spray_id
    // mapping in sp_slot_id[] for the freed range will mismatch any
    // REMOVE message and the lookup will simply not find it.  That's
    // benign — we just lose the visual a bit early.
    int base = lru_idx * SPRAY_PER_BUCKET;
    for (i = 0; i < SPRAY_PER_BUCKET; i = i + 1)
    {
        sp_slot_id[base + i] = 0;
    }
    sp_bucket_tex[lru_idx] = tex;
    sp_bucket_lru_time[lru_idx] = cltime;
    sp_bucket_count[lru_idx] = 0;
    sp_bucket_free_count[lru_idx] = 0;
    return lru_idx;
};

// Allocate a within-bucket slot for a new quad.  Returns -1 if the
// bucket's per-bucket cap is hit (caller should drop the spray).
float(float bucket) CSQC_Spray_AllocSlot =
{
    int b = (int)bucket;
    if (sp_bucket_free_count[b] > 0)
    {
        sp_bucket_free_count[b] = sp_bucket_free_count[b] - 1;
        return sp_bucket_free[b * SPRAY_PER_BUCKET + sp_bucket_free_count[b]];
    }
    if (sp_bucket_count[b] >= SPRAY_PER_BUCKET)
        return -1;
    float slot = sp_bucket_count[b];
    sp_bucket_count[b] = sp_bucket_count[b] + 1;
    return slot;
};

// Write a quad into a specific bucket / slot.  Inlined exactly the
// way BH_WriteQuad (cl_bulletholes.qc:222) does — per-vertex
// xyz/st/rgba directly assigned for speed.
void(int bucket, int slot, vector p0, vector p1, vector p2, vector p3) CSQC_Spray_WriteQuad =
{
    int vbase = (bucket * SPRAY_PER_BUCKET + slot) * 4;
    int ibase = (bucket * SPRAY_PER_BUCKET + slot) * 12;   // 12 = 2 front + 2 back triangles

    sp_bucket_verts[vbase + 0].xyz[0] = p0_x; sp_bucket_verts[vbase + 0].xyz[1] = p0_y; sp_bucket_verts[vbase + 0].xyz[2] = p0_z;
    sp_bucket_verts[vbase + 0].st[0]  = 0;    sp_bucket_verts[vbase + 0].st[1]  = 1;
    sp_bucket_verts[vbase + 0].rgba[0]= 1;    sp_bucket_verts[vbase + 0].rgba[1]= 1;
    sp_bucket_verts[vbase + 0].rgba[2]= 1;    sp_bucket_verts[vbase + 0].rgba[3]= 1;

    sp_bucket_verts[vbase + 1].xyz[0] = p1_x; sp_bucket_verts[vbase + 1].xyz[1] = p1_y; sp_bucket_verts[vbase + 1].xyz[2] = p1_z;
    sp_bucket_verts[vbase + 1].st[0]  = 1;    sp_bucket_verts[vbase + 1].st[1]  = 1;
    sp_bucket_verts[vbase + 1].rgba[0]= 1;    sp_bucket_verts[vbase + 1].rgba[1]= 1;
    sp_bucket_verts[vbase + 1].rgba[2]= 1;    sp_bucket_verts[vbase + 1].rgba[3]= 1;

    sp_bucket_verts[vbase + 2].xyz[0] = p2_x; sp_bucket_verts[vbase + 2].xyz[1] = p2_y; sp_bucket_verts[vbase + 2].xyz[2] = p2_z;
    sp_bucket_verts[vbase + 2].st[0]  = 1;    sp_bucket_verts[vbase + 2].st[1]  = 0;
    sp_bucket_verts[vbase + 2].rgba[0]= 1;    sp_bucket_verts[vbase + 2].rgba[1]= 1;
    sp_bucket_verts[vbase + 2].rgba[2]= 1;    sp_bucket_verts[vbase + 2].rgba[3]= 1;

    sp_bucket_verts[vbase + 3].xyz[0] = p3_x; sp_bucket_verts[vbase + 3].xyz[1] = p3_y; sp_bucket_verts[vbase + 3].xyz[2] = p3_z;
    sp_bucket_verts[vbase + 3].st[0]  = 0;    sp_bucket_verts[vbase + 3].st[1]  = 0;
    sp_bucket_verts[vbase + 3].rgba[0]= 1;    sp_bucket_verts[vbase + 3].rgba[1]= 1;
    sp_bucket_verts[vbase + 3].rgba[2]= 1;    sp_bucket_verts[vbase + 3].rgba[3]= 1;

    // Indices are RELATIVE to the per-bucket vertex pointer passed to
    // addtrisoup_simple in CSQC_DrawSprays (`&sp_bucket_verts[base_v]`,
    // base_v = bucket * SPRAY_PER_BUCKET * 4).  So index 0 means
    // "vertex 0 from THAT pointer", i.e. the first vertex of THIS
    // bucket's segment.  Earlier code wrote `vbase + 0..3` which is
    // ABSOLUTE into the global array — works for bucket 0 (base_v=0)
    // but for every other bucket the engine ends up dereferencing
    // 2× past the bucket segment and rendering garbage / degenerate
    // triangles.  User-visible: "only one texture per session,
    // switching to a different spray after laying one down doesn't
    // render".  Use `slot * 4 + 0..3` so the indices stay relative
    // to the passed pointer regardless of which bucket we're in.
    int vrel = slot * 4;
    // Front face — counter-clockwise winding from the +normal side.
    sp_bucket_idx[ibase + 0] = vrel + 0;
    sp_bucket_idx[ibase + 1] = vrel + 1;
    sp_bucket_idx[ibase + 2] = vrel + 2;
    sp_bucket_idx[ibase + 3] = vrel + 0;
    sp_bucket_idx[ibase + 4] = vrel + 2;
    sp_bucket_idx[ibase + 5] = vrel + 3;
    // Back face — reverse winding so the polygon renders from the
    // other side too.  Necessary because most PNGs won't have a
    // `cull none` shader entry; the engine's default sprite shader
    // culls back faces and our tangent-frame winding can land on
    // either side depending on the wall's normal direction.  The
    // back image is mirrored — only visible from inside the wall,
    // which doesn't happen during normal play.
    sp_bucket_idx[ibase + 6] = vrel + 0;
    sp_bucket_idx[ibase + 7] = vrel + 2;
    sp_bucket_idx[ibase + 8] = vrel + 1;
    sp_bucket_idx[ibase + 9] = vrel + 0;
    sp_bucket_idx[ibase + 10] = vrel + 3;
    sp_bucket_idx[ibase + 11] = vrel + 2;
};

// Spawn a short burst of forward-drifting smoke puffs to fake a
// brief "held the spray can" effect.  Reuses MS_SpawnOnePuff from
// cl_muzzlesmoke.qc — those puffs hook into muzzlesmoke_list and
// get drawn / aged by the existing CSQC_DrawMuzzleSmoke pass, so we
// inherit gfx/smoke shading + camera-facing billboards for free.
//
// Five puffs spawned at once with staggered `ms_spawn_time`s makes
// the effect look like a 0.6 s stream rather than a single burst:
// the first puff is already aged ~0.4 s when drawn (smaller, fading)
// while the last is just born — visually identical to puffs that
// would have emitted in sequence.
void(vector eye, vector forward_dir) CSQC_SpawnSpraySmoke =
{
    float n = 5;
    float i;
    for (i = 0; i < n; i = i + 1)
    {
        // Per-puff spawn position: stepped along the forward axis so
        // older-looking puffs are further from the can.
        vector spawn_pos = eye + forward_dir * (4 + i * 2);
        // Up vector for drift bias — global up is fine (puffs only
        // need a sensible perpendicular for the drift-randomness in
        // MS_SpawnOnePuff to use).
        vector up_dir = '0 0 1';

        MS_SpawnOnePuff(spawn_pos,
                        forward_dir,
                        up_dir,
                        0.7,                // scale (smaller than muzzle smoke)
                        0.7,                // life seconds — quick puff
                        4.0,                // base_size in quake units
                        3.0,                // grow factor over life
                        4.0,                // drift_u (mild upward rise)
                        70.0);              // drift_f (forward drift speed)

        // The new puff is muzzlesmoke_list's head right now — age it
        // by stepping ms_spawn_time backwards so the burst looks like
        // a 0.6 s trail rather than five overlapping copies.
        if (muzzlesmoke_list)
            muzzlesmoke_list.ms_spawn_time = cltime - i * 0.12;
    }
};

// Public — called from CSQC_Parse_Event on CSQC_EVENT_SPRAY.
//
// `name` is the basename portion of cl_spray (no extension, no path).
// FTE will auto-download gfx/sprays/<name>.png from the server if
// the client doesn't have it locally (allow_download + allow_download_other).
void(float spray_id, vector pos, vector normal, vector eye_origin, string name) CSQC_SpawnSprayDecal =
{
    if (cvar("cl_debug_spray"))
        print(sprintf("[spray] CSQC got name='%s' id=%g pos=%v\n",
                      name, spray_id, pos));

    if (vlen(normal) <= 0.001) return;   // degenerate surface — ignore

    // Forward direction from player toward the impact wall — used to
    // aim the smoke puff drift.
    vector to_impact = pos - eye_origin;
    if (vlen(to_impact) > 0.001)
        CSQC_SpawnSpraySmoke(eye_origin, normalize(to_impact));

    // Shader path WITH .png extension.  The shader name + the `map`
    // directive both use this full name so the engine's exact-match
    // shader lookup hits.  Without the extension, adddecal() finds
    // neither shader nor texture and the spray is silently invisible.
    string tex = sprintf("gfx/sprays/%s.png", name);

    // Register the decal shader at runtime via shaderforname().  This
    // sidesteps the "auto-generated scripts/sprays.shader file lives
    // in the wrong gamedir subpath" issue: FTE's fopen writes to the
    // writable gamedir (data/scripts/...) but shaders are loaded from
    // the read gamedir (scripts/...), so the auto-generated file
    // never actually got parsed — the engine had the PNG loaded but
    // no shader to render it through, and every spray rendered
    // through the default fallback (visible as "always nospray" /
    // invisible).  shaderforname registers the shader directly,
    // skipping the disk roundtrip entirely.  Idempotent — second call
    // for the same name returns the cached handle.
    //
    // Properties match the scorch-decal template (effects.shader), which
    // is the working reference for adddecal on this engine:
    //   sort decal       — render after world surfaces, before transparent
    //   polygonoffset 8  — depth bias.  FTE multiplies the GL polygon
    //                       offset by this factor (gl_shader.c:
    //                       unit = -25 * m).  Default `polygonoffset` /
    //                       value 1 (= -25 GL units) is enough for
    //                       bullet-hole-sized decals but too weak for
    //                       spray-sized adddecal projections, which
    //                       z-fight on walls — same issue scorches
    //                       had before their entry got bumped to 8.
    //                       8 → unit -200, well past any wall's
    //                       slope-scaled depth.  Style-0 trisoup also
    //                       benefits when the world-space lift is small.
    //   nopicmip         — don't downsample (decals are already small)
    //   cull none        — visible from either side (spray faces the
    //                       impact normal but the player may walk past)
    //   rgbGen / alphaGen vertex — pick up the per-vertex colour/alpha
    //                       the trisoup writer sets so fade-out works
    //   blendFunc straight alpha — standard PNG transparency
    string shader_body = sprintf(
        "{\n"
        "    sort decal\n"
        "    polygonoffset 8\n"
        "    nopicmip\n"
        "    cull none\n"
        "    {\n"
        "        map %s\n"
        "        rgbGen vertex\n"
        "        alphaGen vertex\n"
        "        blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n"
        "    }\n"
        "}\n", tex);
    float shader_handle = shaderforname(tex, shader_body);
    precache_pic(tex);

    if (cvar("cl_debug_spray"))
        print(sprintf("[spray] shader='%s' handle=%g\n", tex, shader_handle));

    // --- Surface-aligned tangent frame ---
    // Bullet holes use a cross(normal, ref) tangent whose sign flips
    // with the side the normal points from — fine for bullet holes
    // (rotationally random + no readable content) but it mirrors a
    // spray image when the wall normal is along -X / -Y / -Z.
    //
    // Build the frame from WORLD UP projected onto the surface plane
    // instead.  bitangent always points "up along the wall" (or to
    // world +Y for horizontal floors/ceilings), tangent is then
    // cross(bitangent, normal) so the image's right edge consistently
    // lands on the viewer's right regardless of which side the wall
    // faces.  Image reads correctly when viewed from the normal side.
    vector wn = normalize(normal);
    vector world_up = '0 0 1';
    vector bitangent;
    if (fabs(wn_z) > 0.95)
    {
        // Floor / ceiling — world_up is parallel to normal, the
        // projection is zero.  Pick world +Y as a stable fallback so
        // the image always renders in the same orientation looking
        // straight down at a flat floor.
        bitangent = '0 1 0';
    }
    else
    {
        // Project world_up onto the surface plane.
        bitangent = world_up - (world_up * wn) * wn;
        bitangent = normalize(bitangent);
    }
    vector tangent = crossproduct(bitangent, wn);

    // cl_spray_style 1: BSP-wrapping adddecal path.  Engine clips the
    // decal against world surfaces so it follows stair steps / inside
    // corners.  Matches cl_scorch.qc's working pattern exactly — any
    // deviation (origin bias, alternative tangent computation) tends
    // to make the decal silently invisible.  REQUIRES a shader script
    // entry per PNG in scripts/effects.shader (template documented
    // there next to `gfx/sprays/nospray.png`); without one, FTE has
    // no shader to render the projected polygons and r_showtris is
    // the only way to see them.
    if (cvar("cl_spray_style") >= 1)
    {
        int free_slot = -1;
        int i;
        for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
        {
            if (sp_dec_id[i] == 0) { free_slot = i; break; }
        }
        if (free_slot < 0)
            return;   // cap hit, drop

        sp_dec_id[free_slot]     = spray_id;
        sp_dec_shader[free_slot] = tex;
        // Zero bias — relies on the shader's `polygonoffset 8` for
        // z-fight defeat.  Works ONLY when the shader is loaded from
        // a static .shader file (scripts/sprays.shader).  FTE's
        // runtime-registered shaders (via shaderforname's inline
        // defaultshader) don't honour polygonoffset at full strength,
        // so even `polygonoffset 8` in the inline body still z-fights.
        // Static scripts/sprays.shader is the working path — ship one
        // alongside the mod, and the shaderforname call in this file
        // will load it from disk (preferring disk over the inline
        // defaultshader, per FTE_FORCESHADER semantics).  Mirrors the
        // scorch pattern at scripts/effects.shader exactly.
        sp_dec_origin[free_slot] = pos;
        sp_dec_normal[free_slot] = wn;
        // adddecal's `side` arg in FTE is the texture's T-axis (image
        // UP direction) with reciprocal-size magnitude.  Earlier I
        // assumed it was the S-axis (image right) and passed
        // `crossproduct(wn, ref)` — that's a 90° off-axis vector and
        // came out as -90° image rotation.  The world-up-projected
        // `bitangent` we already compute for the trisoup path IS the
        // image-up direction, so passing it gives a correct
        // upright orientation.  The previous bitangent attempt that
        // came out invisible was caused by an unrelated origin-bias
        // bug (now fixed by setting decal_origin = pos with no
        // offset); bitangent itself is the right side arg.
        sp_dec_side[free_slot] = bitangent / (SPRAY_QUAD_HALF * 2);
        return;
    }

    // cl_spray_style 0: flat trisoup quad (default fallback).
    // Quad corners around the impact point, pushed off the surface
    // to avoid z-fight with the underlying brush.
    vector center = pos + wn * SPRAY_DECAL_OFFSET;
    vector p0 = center - tangent * SPRAY_QUAD_HALF - bitangent * SPRAY_QUAD_HALF;
    vector p1 = center + tangent * SPRAY_QUAD_HALF - bitangent * SPRAY_QUAD_HALF;
    vector p2 = center + tangent * SPRAY_QUAD_HALF + bitangent * SPRAY_QUAD_HALF;
    vector p3 = center - tangent * SPRAY_QUAD_HALF + bitangent * SPRAY_QUAD_HALF;

    float bucket = CSQC_Spray_FindBucket(tex);
    float slot   = CSQC_Spray_AllocSlot(bucket);
    if (slot < 0)
        return;   // bucket full; drop the spray rather than overflow

    CSQC_Spray_WriteQuad((int)bucket, (int)slot, p0, p1, p2, p3);
    sp_slot_id[((int)bucket) * SPRAY_PER_BUCKET + (int)slot] = spray_id;
};

// Public — called from CSQC_Parse_Event on CSQC_EVENT_SPRAY_REMOVE.
//
// Linear search across all slots is cheap at our bucket sizes
// (SPRAY_BUCKETS × SPRAY_PER_BUCKET = 64 entries).  Zeros the quad's
// vertex alphas (degenerate render) and recycles the slot via the
// bucket's free list — mirrors BH_FreeStaticSlot (cl_bulletholes.qc:304).
void(float spray_id) CSQC_RemoveSprayDecal =
{
    // Try the trisoup-quad path first.
    int b, s;
    for (b = 0; b < SPRAY_BUCKETS; b = b + 1)
    {
        for (s = 0; s < SPRAY_PER_BUCKET; s = s + 1)
        {
            int idx = b * SPRAY_PER_BUCKET + s;
            if (sp_slot_id[idx] == spray_id)
            {
                int vbase = idx * 4;
                sp_bucket_verts[vbase + 0].rgba[3] = 0;
                sp_bucket_verts[vbase + 1].rgba[3] = 0;
                sp_bucket_verts[vbase + 2].rgba[3] = 0;
                sp_bucket_verts[vbase + 3].rgba[3] = 0;
                sp_slot_id[idx] = 0;
                sp_bucket_free[b * SPRAY_PER_BUCKET + sp_bucket_free_count[b]] = s;
                sp_bucket_free_count[b] = sp_bucket_free_count[b] + 1;
                return;
            }
        }
    }

    // Fall through to the adddecal path.
    int i;
    for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
    {
        if (sp_dec_id[i] == spray_id)
        {
            sp_dec_id[i]     = 0;
            sp_dec_shader[i] = "";
            return;
        }
    }
};

// Per-frame submission.  Called from the existing CSQC predraw /
// HUD pass that already submits bullethole trisoup buffers (see
// CSQC_BulletHolesStartFrame at cl_bulletholes.qc:902).
void() CSQC_DrawSprays =
{
    // --- trisoup-quad path (cl_spray_style 0) ---
    // Each active quad contributes 12 indices (4 triangles — double-
    // sided).  See CSQC_Spray_WriteQuad for the winding layout.
    float spray_dbg = cvar("cl_debug_spray");   // hoisted out of the per-bucket loop
    int b;
    for (b = 0; b < SPRAY_BUCKETS; b = b + 1)
    {
        if (sp_bucket_count[b] <= 0) continue;
        if (sp_bucket_tex[b] == "")  continue;
        int base_v = b * SPRAY_PER_BUCKET * 4;
        int base_i = b * SPRAY_PER_BUCKET * 12;
        if (spray_dbg >= 2)
            print(sprintf("[spray] submit b=%g tex='%s' cnt=%g v0=%g i0=%g\n",
                          (float)b, sp_bucket_tex[b],
                          (float)sp_bucket_count[b],
                          (float)base_v, (float)base_i));
        addtrisoup_simple(sp_bucket_tex[b], 0,
                          &sp_bucket_verts[base_v],
                          &sp_bucket_idx[base_i],
                          sp_bucket_count[b] * 12);
    }

    // --- adddecal path (cl_spray_style 1) ---
    // One adddecal() per active spray per frame.  Engine clips against
    // the world model so the result wraps geometry.  Cost scales with
    // the number of active sprays, capped at SPRAY_ADDECAL_MAX.
    int i;
    for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
    {
        if (sp_dec_id[i] == 0) continue;
        adddecal(sp_dec_shader[i],
                 sp_dec_origin[i],
                 sp_dec_normal[i],
                 sp_dec_side[i],
                 '1 1 1', 1.0);
    }
};

// Scan gfx/sprays/*.png and (re)write scripts/sprays.shader with a
// `gfx/sprays/<name>.png` entry per file.  Each entry has the
// `cull none` + `polygonoffset` properties needed for proper decal
// rendering (matches the scorch/bullet-hole template) — without
// this, PNGs without a manually-written shader entry z-fight and
// have wrong culling.
//
// Called from CSQC_WorldLoaded on every map load so newly-added
// PNGs are picked up without restarting the game.  `flushshaders`
// makes the engine re-parse shader scripts after we write.
//
// File ops are best-effort: if fopen returns -1 (gamedir not
// writable, etc.) we silently bail — the user can still write
// entries manually in effects.shader as the previous workflow.
void() CSQC_RegenerateSpraysShader =
{
    float h = search_begin("gfx/sprays/*.png", TRUE, TRUE);
    if (h < 0) return;

    float f = fopen("scripts/sprays.shader", FILE_WRITE);
    if (f < 0)
    {
        search_end(h);
        return;
    }

    fputs(f, "// Auto-generated by CSQC_RegenerateSpraysShader on map load.\n");
    fputs(f, "// One entry per file in gfx/sprays/*.png — defines `cull none`\n");
    fputs(f, "// + `polygonoffset` + straight-alpha blend so any spray PNG\n");
    fputs(f, "// renders correctly without manual shader authoring.\n");
    fputs(f, "// Edit cl_sprays.qc's CSQC_RegenerateSpraysShader to change\n");
    fputs(f, "// the template applied to every entry.\n\n");

    float n = search_getsize(h);
    float i;
    for (i = 0; i < n; i = i + 1)
    {
        string full = search_getfilename(h, i);
        // `full` is a path like "gfx/sprays/rebel.png".  The shader
        // name and the `map` directive both use the same string.
        fputs(f, sprintf("%s\n{\n", full));
        fputs(f, "\tsort decal\n");
        fputs(f, "\tpolygonoffset 8\n");
        fputs(f, "\tnopicmip\n");
        fputs(f, "\tcull none\n");
        fputs(f, "\t{\n");
        fputs(f, sprintf("\t\tmap %s\n", full));
        fputs(f, "\t\trgbGen vertex\n");
        fputs(f, "\t\talphaGen vertex\n");
        fputs(f, "\t\tblendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n");
        fputs(f, "\t}\n}\n\n");
    }

    fclose(f);
    search_end(h);

    // Tell the engine to drop its shader cache so the file we just
    // wrote gets parsed on next render.  Lighter than `vid_reload`
    // — textures already precached stay loaded.
    localcmd("flushshaders\n");
};

// Map-change reset — clears all buckets so a new map doesn't inherit
// stale sprays.  Called from the same map-load reset hook that
// already calls bullet-hole cleanup.
void() CSQC_ClearSprays =
{
    int i;
    for (i = 0; i < SPRAY_BUCKETS; i = i + 1)
    {
        sp_bucket_tex[i]        = "";
        sp_bucket_lru_time[i]   = 0;
        sp_bucket_count[i]      = 0;
        sp_bucket_free_count[i] = 0;
    }
    for (i = 0; i < SPRAY_BUCKETS * SPRAY_PER_BUCKET; i = i + 1)
    {
        sp_slot_id[i] = 0;
    }
    for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
    {
        sp_dec_id[i]     = 0;
        sp_dec_shader[i] = "";
    }
};
