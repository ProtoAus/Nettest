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

// --- adddecal-style storage (r_spray_renderer 0) ---
// Parallel set of arrays for the BSP-wrapping decal path.  Each entry
// is one active spray; on the per-frame draw pass we call adddecal()
// for each.  Lifetime is FIFO (matches the quad path) — REMOVE event
// from the server clears the slot.  EVERY spray now stores BOTH a
// trisoup slot AND an adddecal slot (live-swap: the draw dispatcher
// picks one per frame off r_spray_renderer), so this is sized to match
// the trisoup capacity (SPRAY_BUCKETS * SPRAY_PER_BUCKET = 64).
const int SPRAY_ADDECAL_MAX = 64;
float  sp_dec_id      [SPRAY_ADDECAL_MAX];    // spray_id, 0 = free
string sp_dec_shader  [SPRAY_ADDECAL_MAX];
vector sp_dec_origin  [SPRAY_ADDECAL_MAX];
vector sp_dec_normal  [SPRAY_ADDECAL_MAX];
vector sp_dec_side    [SPRAY_ADDECAL_MAX];    // tangent / (full size), per adddecal API
vector sp_dec_tint    [SPRAY_ADDECAL_MAX];    // surface-light rgb (cl_decal_surflight) for the adddecal path
string sp_dec_map     [SPRAY_ADDECAL_MAX];    // the map target — to rebuild the `_lm` shader on renderer restart (r_decal_lightmap)
float  sp_dec_handle  [SPRAY_ADDECAL_MAX];    // engine persistent-decal handle (r_spray_renderer 2); 0=none, -1=off-surface

// Live r_spray_offset: the off-surface lift the trisoup spray quads currently reflect.
// The bake uses this (not the live cvar); CSQC_DrawSprays polls + re-shifts on change.
float sp_baked_offset;

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
int                   sp_bucket_idx  [SPRAY_BUCKETS * SPRAY_PER_BUCKET * 6];   // 6 idx/quad (front-only; cull none)
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

// Per-decal vertex tint (rgb) the writer stamps onto the quad — '1 1 1' (white,
// full-bright) for player sprays, the sampled surface light for { wad decals so they
// take the wall's lightmap brightness.  No literal initializer: a global initialised
// with one becomes read-only in fteqcc (it's set per-spawn before WriteQuad).
vector sp_decal_tint;

// Write a quad into a specific bucket / slot.  Inlined exactly the
// way BH_WriteQuad (cl_bulletholes.qc:222) does — per-vertex
// xyz/st/rgba directly assigned for speed.  rgb = sp_decal_tint (surface light /
// white); alpha = 1 so the texture's own alpha (the { mask) drives the blend.
void(int bucket, int slot, vector p0, vector p1, vector p2, vector p3) CSQC_Spray_WriteQuad =
{
    int vbase = (bucket * SPRAY_PER_BUCKET + slot) * 4;
    int ibase = (bucket * SPRAY_PER_BUCKET + slot) * 6;    // 6 = 2 front triangles (cull none draws both sides)

    sp_bucket_verts[vbase + 0].xyz[0] = p0_x; sp_bucket_verts[vbase + 0].xyz[1] = p0_y; sp_bucket_verts[vbase + 0].xyz[2] = p0_z;
    sp_bucket_verts[vbase + 0].st[0]  = 0;    sp_bucket_verts[vbase + 0].st[1]  = 1;
    sp_bucket_verts[vbase + 0].rgba[0]= sp_decal_tint_x; sp_bucket_verts[vbase + 0].rgba[1]= sp_decal_tint_y;
    sp_bucket_verts[vbase + 0].rgba[2]= sp_decal_tint_z; sp_bucket_verts[vbase + 0].rgba[3]= 1;

    sp_bucket_verts[vbase + 1].xyz[0] = p1_x; sp_bucket_verts[vbase + 1].xyz[1] = p1_y; sp_bucket_verts[vbase + 1].xyz[2] = p1_z;
    sp_bucket_verts[vbase + 1].st[0]  = 1;    sp_bucket_verts[vbase + 1].st[1]  = 1;
    sp_bucket_verts[vbase + 1].rgba[0]= sp_decal_tint_x; sp_bucket_verts[vbase + 1].rgba[1]= sp_decal_tint_y;
    sp_bucket_verts[vbase + 1].rgba[2]= sp_decal_tint_z; sp_bucket_verts[vbase + 1].rgba[3]= 1;

    sp_bucket_verts[vbase + 2].xyz[0] = p2_x; sp_bucket_verts[vbase + 2].xyz[1] = p2_y; sp_bucket_verts[vbase + 2].xyz[2] = p2_z;
    sp_bucket_verts[vbase + 2].st[0]  = 1;    sp_bucket_verts[vbase + 2].st[1]  = 0;
    sp_bucket_verts[vbase + 2].rgba[0]= sp_decal_tint_x; sp_bucket_verts[vbase + 2].rgba[1]= sp_decal_tint_y;
    sp_bucket_verts[vbase + 2].rgba[2]= sp_decal_tint_z; sp_bucket_verts[vbase + 2].rgba[3]= 1;

    sp_bucket_verts[vbase + 3].xyz[0] = p3_x; sp_bucket_verts[vbase + 3].xyz[1] = p3_y; sp_bucket_verts[vbase + 3].xyz[2] = p3_z;
    sp_bucket_verts[vbase + 3].st[0]  = 0;    sp_bucket_verts[vbase + 3].st[1]  = 0;
    sp_bucket_verts[vbase + 3].rgba[0]= sp_decal_tint_x; sp_bucket_verts[vbase + 3].rgba[1]= sp_decal_tint_y;
    sp_bucket_verts[vbase + 3].rgba[2]= sp_decal_tint_z; sp_bucket_verts[vbase + 3].rgba[3]= 1;

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
    // Front face only — 2 triangles.  The registered spray shader sets `cull none`, so this one
    // winding is already visible from BOTH sides; the old back-face pair (reverse winding over the
    // same 4 verts) just double-drew every fragment = 2x fill + doubled alpha (1-(1-a)^2).
    sp_bucket_idx[ibase + 0] = vrel + 0;
    sp_bucket_idx[ibase + 1] = vrel + 1;
    sp_bucket_idx[ibase + 2] = vrel + 2;
    sp_bucket_idx[ibase + 3] = vrel + 0;
    sp_bucket_idx[ibase + 4] = vrel + 2;
    sp_bucket_idx[ibase + 5] = vrel + 3;
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

// Build + register the BASE spray shader (the key both the trisoup submit and the plain
// adddecal path use) for shader `tex` mapping image `maptarget`.  Extracted so vid_restart
// re-registration (CSQC_Spray_ReregisterShaders) rebuilds the SAME body — otherwise the
// trisoup quads fall back to the engine default after a restart (opaque, ignores alphaGen
// vertex).  Matches the scorch-decal template; returns the shader handle.
float(string tex, string maptarget) CSQC_Spray_BuildBaseShader =
{
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
        "}\n", maptarget);
    return shaderforname(tex, shader_body);
};

// Public — called from CSQC_Parse_Event on CSQC_EVENT_SPRAY.
//
// `name` is the basename portion of cl_spray (no extension, no path).
// FTE will auto-download gfx/sprays/<name>.png from the server if
// the client doesn't have it locally (allow_download + allow_download_other).
// half_w/half_h = surface half-extents (tangent/U, bitangent/V) in world units.  Player
// sprays pass SPRAY_QUAD_HALF for both (square, unchanged); infodecals pass aspect-correct
// extents (cl_infodecal.qc) so non-square decals keep their texture proportions.
void(float spray_id, vector pos, vector normal, vector eye_origin, string name, float half_w, float half_h) CSQC_SpawnSprayDecal =
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
    // Resolve the texture.  A {-prefixed name is a GoldSrc DECAL (used by infodecal);
    // anything else is a player-spray PNG.
    //   - The shader NAME must NOT start with { — that's the shader-block-open token, so a
    //     {-named shaderforname registers broken and renders the engine error texture.  Use
    //     a safe "waddecal_<stem>" key instead (stem = the brace-free name).
    //   - A { decal resolves to a LOOSE RGBA image, gfx/decals/<stem>.png — NOT the wad
    //     texture.  The wad route is a dead end here: W_GetTexture can't see the decal wad on
    //     a non-HalfLife map (texwadlump is gated to HL maps -> NULL -> white square), and the
    //     Quake-palette salmon key at index 255 mis-triggers FTE's W_ConvertWAD3Texture
    //     alpha==2 "blended decal" branch (flat single colour) even when it DOES resolve.  The
    //     loose PNG (real colours + the masked pixels baked to alpha 0) sidesteps both the
    //     gate and the palette heuristic and renders identically on every map type — the same
    //     proven loose-RGBA route the player sprays already use.  Produce the PNGs from the
    //     same wad/source art with tools/decals_to_png.py.
    float is_wad     = (substring(name, 0, 1) == "{");
    string wadstem   = is_wad ? substring(name, 1, strlen(name) - 1) : "";
    string tex       = is_wad ? strcat("waddecal_", wadstem)
                              : sprintf("gfx/sprays/%s.png", name);
    string maptarget = is_wad ? sprintf("gfx/decals/%s.png", wadstem) : tex;

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
    //   rgbGen / alphaGen vertex — the trisoup writer sets per-vertex colour + alpha:
    //                       alpha is a flat 1.0 so texture.a (the { mask / the PNG alpha)
    //                       passes through unchanged, and rgb is a per-decal TINT — white
    //                       for player sprays (texture shows as-is) and the sampled surface
    //                       light for { wad decals, so the decal takes the lightmap
    //                       brightness of the wall it sits on instead of rendering
    //                       full-bright. (texture.rgb * vertex.rgb, texture.a * vertex.a.)
    //   blendFunc straight alpha — standard alpha transparency
    float shader_handle = CSQC_Spray_BuildBaseShader(tex, maptarget);
    // Per-pixel-lightmap variant (`<tex>_lm`) for r_decal_lightmap on the adddecal path — shared
    // Decal_LMShaderBody (cl_bulletholes.qc).  CSQC_DrawSprays picks it + white rgb when the cvar is on.
    shaderforname(strcat(tex, "_lm"), Decal_LMShaderBody(maptarget, TRUE));
    if (!is_wad)
        precache_pic(tex);		// loose pic; wad decal textures aren't precache_pic-able

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

    // Surface-light tint (cl_decal_surflight 1, default) — ALL sprays dim/brighten with
    // the surface.  Computed here (before the adddecal store) so both render paths share
    // sp_decal_tint.  0 = legacy full-bright.  Phase-3 per-pixel (engine r_decal_lightmap)
    // overrides this to white at the adddecal call site in CSQC_DrawSprays.
    if (cvar("cl_decal_surflight"))
    {
        float spls = cvar("cl_decal_lightscale");
        if (spls <= 0) spls = 1.5;
        vector splt = getlight(pos + wn * 2) * (spls / 255);
        sp_decal_tint_x = bound(0, splt_x, 1);
        sp_decal_tint_y = bound(0, splt_y, 1);
        sp_decal_tint_z = bound(0, splt_z, 1);
    }
    else
        sp_decal_tint = '1 1 1';

    // LIVE-SWAP: populate BOTH representations for every spray.  The adddecal slot
    // (r_spray_renderer 0) here AND the trisoup quad (r_spray_renderer 1, default,
    // below) are both stored at placement; CSQC_DrawSprays dispatches to one per
    // frame off the live cvar, so toggling r_spray_renderer re-renders existing
    // sprays with no re-bake.  Each store guards its own capacity and SKIPS (does
    // not return) when its pool is full, so one path being full never starves the
    // other.  Mirrors the bullet-hole live-swap mechanism.
    //
    // adddecal path: the engine clips the decal against world surfaces (stair steps /
    // inside corners).  `side` = the world-up-projected bitangent at reciprocal size
    // (the image-UP axis); width tracks |side| so non-square is approximate here.
    // Needs a static scripts/sprays.shader entry per PNG for polygonoffset to bite at
    // full strength (the inline shaderforname offset is weaker) — else it can z-fight.
    int free_slot = -1;
    int di;
    for (di = 0; di < SPRAY_ADDECAL_MAX; di = di + 1)
    {
        if (sp_dec_id[di] == 0) { free_slot = di; break; }
    }
    if (free_slot >= 0)
    {
        sp_dec_id[free_slot]     = spray_id;
        sp_dec_shader[free_slot] = tex;
        sp_dec_origin[free_slot] = pos;
        sp_dec_normal[free_slot] = wn;
        sp_dec_side[free_slot]   = bitangent / (half_h * 2);
        sp_dec_tint[free_slot]   = sp_decal_tint;
        sp_dec_map[free_slot]    = maptarget;
        sp_dec_handle[free_slot] = 0;   // r_spray_renderer 2: CSQC_DrawSprays lazily creates the engine persistent decal
    }

    // trisoup path (r_spray_renderer 1, default).
    // Quad corners around the impact point, pushed off the surface to avoid z-fight.
    // Uses sp_baked_offset (not the live cvar) so the DrawSprays poll's uniform shift
    // keeps every trisoup spray consistent.
    vector center = pos + wn * sp_baked_offset;
    vector p0 = center - tangent * half_w - bitangent * half_h;
    vector p1 = center + tangent * half_w - bitangent * half_h;
    vector p2 = center + tangent * half_w + bitangent * half_h;
    vector p3 = center - tangent * half_w + bitangent * half_h;

    float bucket = CSQC_Spray_FindBucket(tex);
    float slot   = CSQC_Spray_AllocSlot(bucket);
    if (slot < 0)
        return;   // bucket full; drop the spray rather than overflow

    // (sp_decal_tint was computed up-front, before the adddecal store, so both paths share it.)
    CSQC_Spray_WriteQuad((int)bucket, (int)slot, p0, p1, p2, p3);
    sp_slot_id[((int)bucket) * SPRAY_PER_BUCKET + (int)slot] = spray_id;
};

// Public — called from CSQC_Parse_Event on CSQC_EVENT_SPRAY_REMOVE.
//
// Linear search across all slots is cheap at our bucket sizes
// (SPRAY_BUCKETS × SPRAY_PER_BUCKET = 64 entries).  Collapses the quad to
// zero-area geometry (and zeros vertex alpha) and recycles the slot via the
// bucket's free list — mirrors BH_FreeStaticSlot (which now collapses too).
void(float spray_id) CSQC_RemoveSprayDecal =
{
    // Each spray stores BOTH a trisoup slot and an adddecal slot (live-swap), so
    // clear BOTH — `found` ends the trisoup scan but the adddecal scan always runs.
    int b, s;
    float found = 0;
    for (b = 0; b < SPRAY_BUCKETS && !found; b = b + 1)
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
                // Collapse to zero-area geometry too — sp_bucket_count is a high-water mark that
                // never shrinks, so this freed slot's indices keep being submitted every frame;
                // alpha 0 alone would ghost under r_showtris or a post-vid_restart shader fallback.
                Decal_CollapseQuad(&sp_bucket_verts[vbase]);
                sp_slot_id[idx] = 0;
                sp_bucket_free[b * SPRAY_PER_BUCKET + sp_bucket_free_count[b]] = s;
                sp_bucket_free_count[b] = sp_bucket_free_count[b] + 1;
                found = 1;
                break;
            }
        }
    }

    int i;
    for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
    {
        if (sp_dec_id[i] == spray_id)
        {
            if (sp_dec_handle[i] > 0) removedecal(sp_dec_handle[i]);   // r_spray_renderer 2: free the engine persistent decal
            sp_dec_handle[i] = 0;
            sp_dec_id[i]     = 0;
            sp_dec_shader[i] = "";
            break;
        }
    }
};

// Per-frame submission.  Called from the existing CSQC predraw /
// HUD pass that already submits bullethole trisoup buffers (see
// CSQC_BulletHolesStartFrame at cl_bulletholes.qc:902).

// Live r_spray_offset: shift the trisoup spray quads along their surface normals by
// `delta` (recovered per-quad via Decal_ShiftQuadVerts, cl_bulletholes.qc).
void(float delta) CSQC_Spray_ShiftQuads =
{
    int b, s;
    for (b = 0; b < SPRAY_BUCKETS; b = b + 1)
    {
        if (sp_bucket_tex[b] == "") continue;
        for (s = 0; s < sp_bucket_count[b]; s = s + 1)
            Decal_ShiftQuadVerts(&sp_bucket_verts[(b * SPRAY_PER_BUCKET + s) * 4], delta);
    }
};

void() CSQC_DrawSprays =
{
    // LIVE-SWAP dispatch: both representations are stored per spray; this picks one
    // per frame off r_spray_renderer (1 = trisoup default, 0 = adddecal).  Polled
    // here so a mid-game toggle re-renders every existing spray next frame.
    float sp_mode = cvar("r_decal_renderer");   // UNIFIED decal renderer (was r_spray_renderer)

    // Live r_decal_offset: re-shift the trisoup quads when it changes.  Ungated (runs in
    // all renderer modes) so the trisoup offset stays correct even while in another mode.
    float sp_want_off = cvar("r_decal_offset");   // UNIFIED decal offset (was r_spray_offset)
    if (sp_want_off < 0) sp_want_off = 0;   // negative would lift into the wall
    if (sp_want_off != sp_baked_offset)
    {
        CSQC_Spray_ShiftQuads(sp_want_off - sp_baked_offset);
        sp_baked_offset = sp_want_off;
    }

    // Mode 2 = PERSISTENT LIT DECALS: the engine clips each spray ONCE (adddecal_static) and re-emits
    // it cheaply every frame (Source-style), keeping the per-pixel lightmap without a per-frame re-clip.
    // Reconcile handles here, then draw NOTHING (engine emits).  Mirrors CSQC_InfoDecal_DrawTrisoup.
    if (sp_mode == 2)
    {
        float sp_lm2 = cvar("r_decal_lightmap");
        int im;
        for (im = 0; im < SPRAY_ADDECAL_MAX; im = im + 1)
        {
            if (sp_dec_id[im] == 0) continue;
            if (sp_dec_handle[im] != 0) continue;   // already have a handle (or -1 = tried+failed)
            float h;
            if (sp_lm2)
                h = adddecal_static(strcat(sp_dec_shader[im], "_lm"),
                                    sp_dec_origin[im], sp_dec_normal[im], sp_dec_side[im],
                                    '1 1 1', 1.0, 1, 0);
            else
                h = adddecal_static(sp_dec_shader[im],
                                    sp_dec_origin[im], sp_dec_normal[im], sp_dec_side[im],
                                    sp_dec_tint[im], 1.0, 1, 0);
            sp_dec_handle[im] = (h >= 0) ? h : -1;   // -1 = off-surface; don't retry every frame
        }
        return;
    }

    // Modes 0/1: release any persistent decals left over from mode 2 (else they'd double-draw), then dispatch.
    int jr;
    for (jr = 0; jr < SPRAY_ADDECAL_MAX; jr = jr + 1)
        if (sp_dec_handle[jr] != 0)
        {
            if (sp_dec_handle[jr] > 0) removedecal(sp_dec_handle[jr]);
            sp_dec_handle[jr] = 0;
        }

    if (sp_mode != 0)
    {
        // --- trisoup-quad path (r_spray_renderer 1) ---
        // Each active quad contributes 6 indices (2 front triangles; cull none shows both sides).
        float spray_dbg = cvar("cl_debug_spray");   // hoisted out of the per-bucket loop
        int b;
        for (b = 0; b < SPRAY_BUCKETS; b = b + 1)
        {
            if (sp_bucket_count[b] <= 0) continue;
            if (sp_bucket_tex[b] == "")  continue;
            int base_v = b * SPRAY_PER_BUCKET * 4;
            int base_i = b * SPRAY_PER_BUCKET * 6;
            if (spray_dbg >= 2)
                print(sprintf("[spray] submit b=%g tex='%s' cnt=%g v0=%g i0=%g\n",
                              (float)b, sp_bucket_tex[b],
                              (float)sp_bucket_count[b],
                              (float)base_v, (float)base_i));
            addtrisoup_simple(sp_bucket_tex[b], 0,
                              &sp_bucket_verts[base_v],
                              &sp_bucket_idx[base_i],
                              sp_bucket_count[b] * 6);
        }
    }
    else
    {
        // --- adddecal path (r_spray_renderer 0) ---
        // One adddecal() per active spray per frame.  Engine clips against the world
        // model so the result wraps geometry.  Cost scales with the active spray count.
        // r_decal_lightmap: use the `_lm` program variant + WHITE rgb (the world lightmap lights
        // it per-pixel); else the plain shader + the surface-light tint (cl_decal_surflight).
        float sp_lm = cvar("r_decal_lightmap");
        int i;
        for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
        {
            if (sp_dec_id[i] == 0) continue;
            if (sp_lm)
                adddecal(strcat(sp_dec_shader[i], "_lm"),
                         sp_dec_origin[i], sp_dec_normal[i], sp_dec_side[i],
                         '1 1 1', 1.0);
            else
                adddecal(sp_dec_shader[i],
                         sp_dec_origin[i], sp_dec_normal[i], sp_dec_side[i],
                         sp_dec_tint[i], 1.0);
        }
    }
};

// Re-register spray shaders after a renderer restart (vid_restart purges shaderforname shaders).
// Rebuilds BOTH the BASE key (that CSQC_DrawSprays' trisoup submit uses — without it the quads
// fall back to the engine default: opaque, ignores alphaGen vertex, so freed/masked quads show)
// AND the `_lm` per-pixel-lightmap adddecal variant.  Every active spray stores an adddecal slot
// (live-swap), so iterating sp_dec_* covers every bucket's base shader.  Called from
// CSQC_RendererRestarted (cl_infodecal.qc).
void() CSQC_Spray_ReregisterShaders =
{
    int i;
    for (i = 0; i < SPRAY_ADDECAL_MAX; i = i + 1)
        if (sp_dec_id[i] != 0 && sp_dec_map[i] != "")
        {
            CSQC_Spray_BuildBaseShader(sp_dec_shader[i], sp_dec_map[i]);
            shaderforname(strcat(sp_dec_shader[i], "_lm"), Decal_LMShaderBody(sp_dec_map[i], TRUE));
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
        sp_dec_handle[i] = 0;   // r_spray_renderer 2: engine already wiped its store on map change (CL_ClearState)
    }
    sp_baked_offset = 0;   // next post-clear poll lifts fresh sprays from 0 to the cvar
};
