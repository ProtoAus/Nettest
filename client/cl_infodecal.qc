//
//  cl_infodecal.qc  –  client receiver + renderer for the server infodecal entity.
//
//  CSQC_ENT_INFODECAL carries the surface point + normal + decal texture name the
//  server traced at spawn (sv_infodecal.qc), plus GoldSrc render keys
//  (rendermode/renderamt/rendercolor/renderfx).  We place the decal ONCE.
//
//  r_decal_renderer selects HOW (standardised with r_bullethole_renderer /
//  r_spray_renderer, default 1).  LIVE-SWAP: BOTH representations are populated at
//  placement and CSQC_InfoDecal_DrawTrisoup polls the cvar each frame and draws one,
//  so toggling re-renders existing infodecals immediately (mirrors bullet holes):
//    1 = TRI-SOUP projector (default) — a surface-aligned quad clipped to the hit
//        BSP surface's outline edges (BH_ClipQuadToHitTri), baked once, one
//        addtrisoup_simple per texture per frame.  Conforms to the wall.
//    0 = engine adddecal() — re-projected each frame, wraps across convex edges.
//
//  Render keys (static this round): renderamt -> per-vertex/decal ALPHA, rendercolor
//  -> tint, rendermode -> shader blend (additive / alpha-test).  renderfx is read +
//  stored but not yet animated (follow-up: per-frame vertex-alpha rewrite like blood).
//
//  COMPILE ORDER: this file is LAST in cl_progs.src (after cl_bulletholes.qc /
//  cl_bloodtrisoup.qc / cl_sprays.qc), so the BH_* clip/write helpers + bh_io_*
//  globals + SPRAY_QUAD_HALF are in scope.
//
//  The carrier never renders (drawmask 0).  Infodecals are PVSF_NOREMOVE map
//  FIXTURES: placed once, they persist for the map's life; the global buffers
//  re-zero on the CSQC VM restart at map change, so no manual wipe is needed.
//  Dispatched from CSQC_Ent_Update (cl_player.qc).
//

.float id_placed;    // 1 once this decal has been placed (place-once guard)
.float id_renderfx;  // GoldSrc renderfx 0..16 (read+stored; animation deferred)

// ---- TRI-SOUP buffer (r_decal_renderer 1) -----------------------------------
// String-keyed buckets like sprays (texture+mode names are open-ended), single-
// sided 6-idx quads via BH_WriteQuad/BH_WriteQuadUV like blood (cull none shader).
const int   ID_BUCKETS    = 16;           // distinct decal shaders drawn at once (raised from 8:
                                          // infodecals are place-once fixtures never re-baked, so an
                                          // LRU evict permanently destroys a whole bucket of them in
                                          // renderer 1 — size this to the map's distinct decal count)
const int   ID_PER_BUCKET = 16;           // placements per shader
// Off-surface lift is the cvar r_decal_offset (read at bake); polygonoffset 8 in
// the shader does the real z-fight defeat so this can be tiny for a flush look.

string id_bucket_tex  [ID_BUCKETS];       // shader key this bucket batches; "" = free
float  id_bucket_lru  [ID_BUCKETS];       // cltime of last alloc (LRU eviction)
int    id_bucket_count[ID_BUCKETS];       // active quads in this bucket
// Live r_decal_offset: the off-surface lift the trisoup quads currently reflect.  Bake
// uses this (not the live cvar); CSQC_InfoDecal_DrawTrisoup polls + re-shifts on change.
float  id_baked_offset;
float  id_lru_warned;   // one-shot: warn once per map when the bucket pool overflows (evicts)
// Big pools — `auto` keeps them out of the progs global block.  Literal dims MUST
// equal ID_BUCKETS * ID_PER_BUCKET * {4,6}.
auto trisoup_simple_vert_t id_bucket_verts[16 * 16 * 4];
auto int                   id_bucket_idx  [16 * 16 * 6];

// ---- adddecal storage (r_decal_renderer 0) ----------------------------------
// LIVE-SWAP: EVERY infodecal also stores an adddecal slot, so the cap matches the
// trisoup capacity (ID_BUCKETS * ID_PER_BUCKET = 128).  Placed once, never freed.
const int ID_ADDECAL_MAX = 128;
float  id_dec_used  [ID_ADDECAL_MAX];     // 1 = active
string id_dec_shader[ID_ADDECAL_MAX];
vector id_dec_origin[ID_ADDECAL_MAX];
vector id_dec_normal[ID_ADDECAL_MAX];
vector id_dec_side  [ID_ADDECAL_MAX];     // V/up axis, reciprocal-size (adddecal API): encodes half_h
float  id_dec_aspect[ID_ADDECAL_MAX];     // half_w/half_h = pngW/pngH; adddecal() 7th arg widens the decal
vector id_dec_tint  [ID_ADDECAL_MAX];     // rgb tint
float  id_dec_alpha [ID_ADDECAL_MAX];     // 0..1 opacity (renderamt)
string id_dec_texname[ID_ADDECAL_MAX];    // BuildShader inputs, cached so the shaders can be
float  id_dec_rmode [ID_ADDECAL_MAX];     //   re-registered after a vid_restart (see below)
float  id_dec_handle[ID_ADDECAL_MAX];     // engine persistent-decal handle (r_decal_renderer 2); 0=none, -1=off-surface

// ---- bucket allocator (mirrors CSQC_Spray_FindBucket) -----------------------
float(string tex) CSQC_InfoDecal_FindBucket =
{
    int i;
    for (i = 0; i < ID_BUCKETS; i = i + 1)
        if (id_bucket_tex[i] == tex) { id_bucket_lru[i] = cltime; return i; }

    for (i = 0; i < ID_BUCKETS; i = i + 1)
        if (id_bucket_tex[i] == "")
        {
            id_bucket_tex[i]   = tex;
            id_bucket_lru[i]   = cltime;
            id_bucket_count[i] = 0;
            return i;
        }

    float lru_idx = 0;
    float lru_t   = id_bucket_lru[0];
    for (i = 1; i < ID_BUCKETS; i = i + 1)
        if (id_bucket_lru[i] < lru_t) { lru_idx = i; lru_t = id_bucket_lru[i]; }
    // Evicting a full bucket permanently DESTROYS its place-once infodecals in renderer 1 (they
    // survive in the parallel adddecal pool, so r_decal_renderer 0 vs 1 diverge).  Warn once per
    // map so this isn't silent — the real fix is a large-enough ID_BUCKETS for the map.
    if (!id_lru_warned)
    {
        dprint(sprintf("infodecal: >%i distinct decal textures in renderer 1 — some trisoup "
                       "decals will vanish; raise ID_BUCKETS.\n", ID_BUCKETS));
        id_lru_warned = 1;
    }
    id_bucket_tex[(int)lru_idx]   = tex;
    id_bucket_lru[(int)lru_idx]   = cltime;
    id_bucket_count[(int)lru_idx] = 0;
    return lru_idx;
};

// ---- resolve a decal NAME to the texture the shader stage should sample -----
// Two decal namespaces arrive here and they resolve in completely different
// places:
//
//   "{Source/srclock01"  the mod's own decal library.  The name always carries a
//                        CATEGORY folder and the art lives in a pack as
//                        gfx/decals/<category>/<name>.dds.
//   "{TARGET"            a GoldSrc WAD lump.  HL / CS 1.6 / Sven maps write
//                        infodecal "texture" keys naming a lump inside
//                        decals.wad — which is loaded for every BSP30 map
//                        because Mod_ParseInfoFromEntityLump seeds the wad list
//                        with it (engine client/wad.c) — and there is no image
//                        file anywhere to match.
//
// Pushing a wad name through the gfx/decals/ template built a path that resolves
// to nothing, so the stage got NO texture and the quad drew as a flat untextured
// square: dark under r_decal_renderer 2 (the _lm shader supplies white vertex
// colour and lets the lightmap do the work) and pale under 0/1 (surface-light
// tint).  That is the "de_rats {TARGET is a dark square" report.
//
// Handing the name to the engine's WAD3 path instead puts the lookup on
// W_ConvertWAD3Texture, which implements the GoldSrc decal convention — palette
// entry 255 is the decal's COLOUR and the pixel index is an inverted alpha ramp
// — so {TARGET arrives as the (145 23 11) bomb-site red with correct per-pixel
// alpha instead of a solid block.
//
// The "waddecal/" prefix is what REQUESTS that convention.  It used to be
// implicit: the engine applied the decal reading to every '{' wad texture whose
// palette entry 255 was not exactly blue.  That was wrong for BSP faces — a '{'
// texture on a world surface is MASKED in GoldSrc (index 255 transparent, palette
// RGB kept), and the implicit rule silently destroyed any world texture keyed on
// a near-blue or green background.  pizza_ya_san1's "{stripeh" road paint decoded
// to alpha<=58 and was then discarded wholesale by the '{' alpha-test shader, so
// the zebra crossings vanished and showed sky.  The engine now defaults to masked
// and only reads a decal when asked, which is what this prefix does.  (Matches
// xash3d-fwgs, which gates the same branch on IL_LOAD_DECAL.)
//
// The library/lump discriminator is the category slash: every decal in the mod's
// packs has one, no GoldSrc wad lump has one (lump names are capped at 15 chars
// and are flat).  So this cannot start mis-routing the existing library decals.
float(string texname) CSQC_InfoDecal_IsWadLump =
{
    if (substring(texname, 0, 1) != "{")
        return FALSE;
    return strstrofs(substring(texname, 1, strlen(texname) - 1), "/") < 0;
};

string(string texname) CSQC_InfoDecal_MapTarget =
{
    if (substring(texname, 0, 1) != "{")
        return texname;                             // already a plain image path
    string stem = substring(texname, 1, strlen(texname) - 1);
    if (strstrofs(stem, "/") >= 0)
        return sprintf("gfx/decals/%s", stem);      // mod library decal
    return strcat("waddecal/", texname);            // GoldSrc lump -> WAD3 decal reading
};

// ---- runtime { -decal shader (replicates the is_wad branch of -------------
//      CSQC_SpawnSprayDecal; shaderforname idempotent).  rendermode selects the
//      blendFunc and is folded into the shader KEY (so modes don't collide on one
//      cached shader / one bucket).  Returns the shader key (also the bucket key).
string(string texname, float rmode) CSQC_InfoDecal_BuildShader =
{
    float  is_wad    = (substring(texname, 0, 1) == "{");
    string stem      = is_wad ? substring(texname, 1, strlen(texname) - 1) : texname;
    string base      = is_wad ? strcat("waddecal_", stem) : texname;
    //Extensionless: decals ship as BC7 .dds inside their pack pk3s (2026-07-28) and FTE's loader
    //walks its own extension list, so .dds or .png both resolve with no QC edit.
    //
    //`stem` INCLUDES the category folder -- a map names the texture "{Source/srclock01", so this
    //resolves gfx/decals/Source/srclock01. The pk3s therefore mirror that structure; do not
    //flatten them (learned the hard way on 2026-07-28: flattening silently kills every decal
    //whose name carries a category, which is nearly all of them).
    //
    //A BARE wad lump name ("{TARGET") resolves to itself instead -- see
    //CSQC_InfoDecal_MapTarget above.  `base` keeps the waddecal_ prefix either way, so the
    //shader KEY never collides with the world-surface shader of the same texture name.
    string maptarget = CSQC_InfoDecal_MapTarget(texname);

    // GoldSrc rendermode -> blend.  4 = Solid (alpha-test, opaque); 3/5 = Glow/
    // Additive; else Normal/Color/Texture (alpha blend).  Suffix keeps modes apart.
    string innerblend;
    string keysuffix;
    if (rmode == 4)
    {
        innerblend = "        alphaFunc GE128\n";
        keysuffix  = "_m4";
    }
    else if (rmode == 3 || rmode == 5)
    {
        innerblend = "        blendFunc GL_ONE GL_ONE\n";
        keysuffix  = "_m5";
    }
    else
    {
        innerblend = "        blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n";
        keysuffix  = "";
    }
    string tex = strcat(base, keysuffix);

    // NO `cull none` (2026-07): it let the decal's BACK face draw, and `polygonoffset 8`'s constant -200
    // depth bias pulls the decal toward the camera by an amount that GROWS with distance (~48qu @2000u) —
    // past a wall's thickness it beat the wall's far face, so the decal showed THROUGH the wall from behind
    // once you backed away.  Omitting cull => FTE's default SHADER_CULL_FRONT (normal backface culling), and
    // nothing is lost: the engine clipper never builds decal geometry on away-facing surfaces
    // (r_decal_noperpendicular).  See Decal_LMShaderBody (cl_bulletholes.qc) for the full write-up.
    string shader_body = sprintf(
        "{\n"
        "    sort decal\n"
        "    polygonoffset 8\n"
        "    nopicmip\n"
        "    {\n"
        "        map %s\n"
        "        rgbGen vertex\n"
        "        alphaGen vertex\n"
        "%s"
        "    }\n"
        "}\n", maptarget, innerblend);
    shaderforname(tex, shader_body);

    // nettest r_decal_lightmap: a per-pixel-lightmap variant (`<tex>_lm`, program
    // decal_lightmap) used ONLY by the adddecal path (r_decal_renderer 0) when r_decal_lightmap
    // is on.  Kept SEPARATE from the plain shader so the tri-soup path's shader has no $lightmap
    // stage (an addtrisoup_simple batch carries no lightmap page → a $lightmap stage there
    // mis-reads one).  Body from the shared Decal_LMShaderBody() (cl_bulletholes.qc) so all 3
    // adddecal renderers stay identical.
    shaderforname(strcat(tex, "_lm"), Decal_LMShaderBody(maptarget, FALSE));

    return tex;
};

// ---- bake one infodecal quad into the trisoup buffer (renderer 1) -----------
void(vector pos, vector norm, string shaderkey,
     float half_w, float half_h, vector tint, float alpha, float angle) CSQC_BakeInfoDecalQuad =
{
    vector wn = normalize(norm);

    // SPRAY world-up tangent frame (upright, un-mirrored — readable art).
    vector bitangent;
    if (fabs(wn_z) > 0.95)
        bitangent = '0 1 0';
    else
        bitangent = normalize('0 0 1' - ('0 0 1' * wn) * wn);
    vector tangent = crossproduct(bitangent, wn);

    // Spin the frame about the surface normal by the entity `angle` (deg). tangent/bitangent
    // are perpendicular to wn, so Rodrigues reduces to v*cos + (wn x v)*sin.
    if (angle != 0)
    {
        float ar = angle * 0.0174532925;
        float ca = cos(ar);
        float sa = sin(ar);
        vector nt = tangent   * ca + crossproduct(wn, tangent)   * sa;
        vector nb = bitangent * ca + crossproduct(wn, bitangent) * sa;
        tangent   = nt;
        bitangent = nb;
    }

    // Uses id_baked_offset (not the live cvar) so the DrawTrisoup poll's uniform shift
    // keeps every quad consistent (the <0 clamp lives in the poll).
    vector center = pos + wn * id_baked_offset;
    vector q0 = center - tangent * half_w - bitangent * half_h;
    vector q1 = center + tangent * half_w - bitangent * half_h;
    vector q2 = center + tangent * half_w + bitangent * half_h;
    vector q3 = center - tangent * half_w + bitangent * half_h;

    bh_io_uv0 = '0 1 0'; bh_io_uv1 = '1 1 0';
    bh_io_uv2 = '1 0 0'; bh_io_uv3 = '0 0 0';
    float clipped = 0;

    float surf = getsurfacenearpoint(world, pos);
    if (surf >= 0)
    {
        float tri = BH_FindHitTriangle(world, surf, pos);
        if (tri >= 0)
        {
            vector idx = getsurfacetriangle(world, surf, tri);
            bh_io_tv0     = getsurfacepoint(world, surf, idx_x);
            bh_io_tv1     = getsurfacepoint(world, surf, idx_y);
            bh_io_tv2     = getsurfacepoint(world, surf, idx_z);
            bh_io_surf    = surf;
            bh_io_hit_tri = tri;
            vector sn = getsurfacenormal(world, surf);
            if (vlen(sn) > 0.001)
            {
                bh_io_sn = normalize(sn);
                clipped  = BH_ClipQuadToHitTri(q0, q1, q2, q3);
            }
        }
    }

    float bucket = CSQC_InfoDecal_FindBucket(shaderkey);
    int   b      = (int)bucket;
    if (id_bucket_count[b] >= ID_PER_BUCKET)
    {
        // Per-texture cap: >ID_PER_BUCKET decals of ONE shader drop silently in renderer 1.
        if (!id_lru_warned)
        {
            dprint(sprintf("infodecal: >%i decals share one texture in renderer 1 — extras "
                           "dropped; raise ID_PER_BUCKET.\n", ID_PER_BUCKET));
            id_lru_warned = 1;
        }
        return;   // bucket full — drop
    }
    int slot = id_bucket_count[b];
    id_bucket_count[b] = id_bucket_count[b] + 1;

    int vpart = b * ID_PER_BUCKET * 4;
    int ipart = b * ID_PER_BUCKET * 6;
    if (clipped)
        BH_WriteQuadUV(slot, q0, q1, q2, q3, tint, alpha,
                       &id_bucket_verts[vpart], &id_bucket_idx[ipart]);
    else
        BH_WriteQuad(slot, q0, q1, q2, q3, tint, alpha,
                     &id_bucket_verts[vpart], &id_bucket_idx[ipart]);
};

// ---- store one infodecal for the per-frame adddecal path (renderer 0) -------
float(vector pos, vector norm, string shaderkey, float half_w, float half_h,
     vector tint, float alpha, float angle) CSQC_InfoDecal_AddDecalSlot =
{
    vector wn = normalize(norm);
    vector bitangent;
    if (fabs(wn_z) > 0.95)
        bitangent = '0 1 0';
    else
        bitangent = normalize('0 0 1' - ('0 0 1' * wn) * wn);

    // Spin about the normal by the entity `angle` (deg) — rotating the V/up axis (bitangent)
    // rotates the whole adddecal (the engine derives U from side x normal). See BakeInfoDecalQuad.
    if (angle != 0)
    {
        float ar = angle * 0.0174532925;
        bitangent = bitangent * cos(ar) + crossproduct(wn, bitangent) * sin(ar);
    }

    int i;
    int free = -1;
    for (i = 0; i < ID_ADDECAL_MAX; i = i + 1)
        if (!id_dec_used[i]) { free = i; break; }
    if (free < 0) return -1;   // cap hit, drop (trisoup may still have it)

    id_dec_used[free]   = 1;
    id_dec_shader[free] = shaderkey;
    id_dec_origin[free] = pos;
    id_dec_normal[free] = wn;
    id_dec_side[free]   = bitangent / (half_h * 2);   // V/up axis sets the vertical (T) half-extent = half_h
    id_dec_aspect[free] = (half_h > 0) ? (half_w / half_h) : 1;  // adddecal() widens axis[1] (S) to half_w
    id_dec_tint[free]   = tint;
    id_dec_alpha[free]  = alpha;
    id_dec_handle[free] = 0;   // r_decal_renderer 2: DrawTrisoup lazily creates the engine persistent decal
    return free;
};

// ---- re-register decal shaders after a renderer restart (vid_restart) --------
// vid_restart purges the shader cache, but the .id_placed guard stops
// CSQC_InfoDecal_BuildShader from re-running at placement.  So the next adddecal()
// would recreate the shader from FTE's built-in default body (PF_R_AddDecal in the
// engine: a "surfaceparms" typo + `map $diffuse` -> a texture named after the shader,
// which doesn't exist -> the error checkerboard).  Rebuild every active decal's shader
// here (idempotent) so both the plain key AND the `_lm` lightmap variant come back with
// our own body + a freshly-linked `program decal_lightmap`.  Also covers the plain
// adddecal + trisoup shaders (same reload fragility).
void() CSQC_InfoDecal_ReregisterShaders =
{
    int i;
    for (i = 0; i < ID_ADDECAL_MAX; i = i + 1)
        if (id_dec_used[i])
            CSQC_InfoDecal_BuildShader(id_dec_texname[i], id_dec_rmode[i]);
};

// Engine entry point: called after the video/renderer is restarted (and once at CSQC
// load, where there are no decals yet -> harmless).  Its purpose is exactly this:
// re-register shaders the engine purged.
void(string rendererdescription) CSQC_RendererRestarted =
{
    CSQC_InfoDecal_ReregisterShaders();
    CSQC_Spray_ReregisterShaders();       // cl_sprays.qc (compiled earlier)
    CSQC_BulletHole_ReregisterShaders();  // cl_bulletholes.qc (compiled earlier)
    Blood_ReregisterShaders();            // cl_bloodtrisoup.qc — plain + _lm blood decal shaders (r_decal_renderer 2)
    CSQC_BlobShadow_ReregisterShaders();  // cl_blobshadow.qc (compiled earlier) — blob-shadow decal shader
    Paint_RendererRestarted();            // cl_paint.qc (compiled later; prototype in cl_customdefs) — re-upload body-paint textures
};

// ---- per-frame draw — LIVE-SWAP dispatch on r_decal_renderer ----------------
// Called from cl_main.qc after CSQC_DrawSprays.  Both paths are populated at
// placement; this polls the cvar and draws ONE, so toggling re-renders existing
// infodecals next frame.
// Live r_decal_offset: shift the trisoup infodecal quads along their surface normals by
// `delta` (recovered per-quad via Decal_ShiftQuadVerts, cl_bulletholes.qc).
void(float delta) CSQC_InfoDecal_ShiftQuads =
{
    int b, s;
    for (b = 0; b < ID_BUCKETS; b = b + 1)
    {
        if (id_bucket_tex[b] == "") continue;
        for (s = 0; s < id_bucket_count[b]; s = s + 1)
            Decal_ShiftQuadVerts(&id_bucket_verts[b * ID_PER_BUCKET * 4 + s * 4], delta);
    }
};

void() CSQC_InfoDecal_DrawTrisoup =
{
    // Live r_decal_offset: re-shift the trisoup quads when it changes (ungated — keep the
    // trisoup verts correct even while in adddecal mode).
    float id_want_off = cvar("r_decal_offset");
    if (id_want_off < 0) id_want_off = 0;
    if (id_want_off != id_baked_offset)
    {
        CSQC_InfoDecal_ShiftQuads(id_want_off - id_baked_offset);
        id_baked_offset = id_want_off;
    }

    float id_mode = cvar("r_decal_renderer");

    // Mode 2 = PERSISTENT LIT DECALS: the engine clips each decal ONCE (adddecal_static) and re-emits
    // it cheaply every frame (Source-style), keeping the per-pixel lightmap without the per-frame BSP
    // re-clip.  Reconcile handles here (infodecals are placed once), then draw NOTHING (engine emits).
    if (id_mode == 2)
    {
        float lm2 = cvar("r_decal_lightmap");
        int im;
        for (im = 0; im < ID_ADDECAL_MAX; im = im + 1)
        {
            if (!id_dec_used[im]) continue;
            if (id_dec_handle[im] != 0) continue;   // already have a handle (or -1 = tried+failed)
            float h;
            if (lm2)
                h = adddecal_static(strcat(id_dec_shader[im], "_lm"), id_dec_origin[im], id_dec_normal[im],
                                    id_dec_side[im], '1 1 1', id_dec_alpha[im], id_dec_aspect[im], 0);
            else
                h = adddecal_static(id_dec_shader[im], id_dec_origin[im], id_dec_normal[im],
                                    id_dec_side[im], id_dec_tint[im], id_dec_alpha[im], id_dec_aspect[im], 0);
            id_dec_handle[im] = (h >= 0) ? h : -1;   // -1 = off-surface; don't retry every frame
        }
        return;
    }

    // Modes 0/1: release any persistent decals left over from mode 2 (else they'd double-draw), then dispatch.
    int jr;
    for (jr = 0; jr < ID_ADDECAL_MAX; jr = jr + 1)
        if (id_dec_handle[jr] != 0)
        {
            if (id_dec_handle[jr] > 0) removedecal(id_dec_handle[jr]);
            id_dec_handle[jr] = 0;   // clear (incl. the -1 failed sentinel) so returning to mode 2 re-creates
        }

    if (id_mode != 0)
    {
        int b;
        for (b = 0; b < ID_BUCKETS; b = b + 1)
        {
            if (id_bucket_count[b] <= 0) continue;
            if (id_bucket_tex[b] == "")  continue;
            int vpart = b * ID_PER_BUCKET * 4;
            int ipart = b * ID_PER_BUCKET * 6;
            addtrisoup_simple(id_bucket_tex[b], 0,
                              &id_bucket_verts[vpart],
                              &id_bucket_idx[ipart],
                              id_bucket_count[b] * 6);
        }
    }
    else
    {
        // nettest r_decal_lightmap (engine): per-pixel surface lightmap.  Use the `_lm`
        // program-shader variant + WHITE vertex colour (the lightmap supplies the lighting);
        // else the plain shader + the surface-light tint (Phase-1).
        float lm = cvar("r_decal_lightmap");
        int i;
        for (i = 0; i < ID_ADDECAL_MAX; i = i + 1)
        {
            if (!id_dec_used[i]) continue;
            if (lm)
                adddecal(strcat(id_dec_shader[i], "_lm"), id_dec_origin[i], id_dec_normal[i],
                         id_dec_side[i], '1 1 1', id_dec_alpha[i], id_dec_aspect[i]);
            else
                adddecal(id_dec_shader[i], id_dec_origin[i], id_dec_normal[i],
                         id_dec_side[i], id_dec_tint[i], id_dec_alpha[i], id_dec_aspect[i]);
        }
    }
};

// ---- network receiver -------------------------------------------------------
void(float isnew) CSQC_InfoDecal_Update =
{
    vector pos, norm;
    pos_x  = readcoord();  pos_y  = readcoord();  pos_z  = readcoord();
    norm_x = readcoord();  norm_y = readcoord();  norm_z = readcoord();
    float visible = readbyte();
    float escale  = readcoord();   // per-entity scale (sv_infodecal networks self.scale here)
    string texname = readstring();
    // GoldSrc render keys (must match sv_infodecal.qc infodecal_SendEntity order).
    // Local names rmode/ramt/rcol avoid clashing with the client's .rendermode /
    // .rendercolor field globals (cl_brushsync.qc).
    float  rmode = readbyte();
    float  ramt  = readbyte();
    vector rcol;
    rcol_x = readbyte();  rcol_y = readbyte();  rcol_z = readbyte();
    self.id_renderfx = readbyte();   // stored for the renderfx follow-up (not yet animated)
    float dang = readcoord();        // decal rotation (deg, spin about the surface normal)

    self.drawmask = 0;   // carrier only — nothing to render for the entity itself

    if (visible && !self.id_placed && texname != "" && vlen(norm) > 0.001)
    {
        // Final size = entity scale * the global cl_infodecal_scale multiplier.
        float s = escale * cvar("cl_infodecal_scale");
        if (s <= 0) s = 1;

        // Build the shader BEFORE measuring: a GoldSrc wad decal has no image file to
        // measure, so it gets sized through the shader we just registered for it.
        string shaderkey = CSQC_InfoDecal_BuildShader(texname, rmode);

        // Aspect-correct half-extents from the decal image (extensionless -- see :117).
        float half_w = SPRAY_QUAD_HALF * s;
        float half_h = SPRAY_QUAD_HALF * s;
        if (substring(texname, 0, 1) == "{")
        {
            // Library decals measure the image file directly.  A bare wad lump is measured
            // via `shaderkey` instead of its own name, because precache_pic("{target")
            // would register a 2D pic under the SAME global shader name a world surface
            // using that texture holds — the decal would then be able to restyle map
            // geometry.  waddecal_<stem> is private to this file.
            //
            // Worth the detour: 95 of the 225 lumps in decals.wad are non-square (128x32
            // arrows, 48x96 signs), so falling back to a square quad visibly distorts
            // them.  A probe that returns nothing simply keeps the square, as before.
            string pic = CSQC_InfoDecal_MapTarget(texname);
            // Tested on the SOURCE name, not by comparing against the mapped
            // one: MapTarget now rewrites wad lumps too (to "waddecal/{LUMP"),
            // so the old `pic == texname` identity check would take the
            // image-file branch and precache_pic a name no file can satisfy.
            if (CSQC_InfoDecal_IsWadLump(texname))
                pic = shaderkey;        // GoldSrc wad lump — measure our own shader
            else
                precache_pic(pic);      // image file — precache before measuring
            vector sz = drawgetimagesize(pic);
            if (sz_x > 0 && sz_y > 0)
            {
                if (sz_x >= sz_y)
                    half_h = SPRAY_QUAD_HALF * s * (sz_y / sz_x);   // landscape
                else
                    half_w = SPRAY_QUAD_HALF * s * (sz_x / sz_y);   // portrait
            }
        }

        // renderamt -> opacity.  0/unset = opaque (don't make keyless infodecals
        // invisible); solid mode (4) is alpha-tested so renderamt doesn't apply.
        if (ramt <= 0) ramt = 255;
        float alpha = ramt / 255;
        if (rmode == 4) alpha = 1;

        // rendercolor -> explicit tint when set.  Else surface-light tint (cl_decal_surflight
        // 1, default — consistent with bullet holes/sprays) so the decal isn't full-bright in
        // a dark room; surflight 0 -> white.  ('0 0 0' rendercolor = unset; black would be
        // invisible anyway.)
        vector wn = normalize(norm);
        vector tint = '1 1 1';
        if (rcol != '0 0 0')
            tint = rcol * (1.0 / 255);
        else if (cvar("cl_decal_surflight"))
        {
            float ls = cvar("cl_decal_lightscale");
            if (ls <= 0) ls = 1.5;
            vector lt = getlight(pos + wn * 2) * (ls / 255);
            tint_x = bound(0, lt_x, 1);
            tint_y = bound(0, lt_y, 1);
            tint_z = bound(0, lt_z, 1);
        }

        // LIVE-SWAP: populate BOTH paths; CSQC_InfoDecal_DrawTrisoup picks one/frame.
        CSQC_BakeInfoDecalQuad(pos, norm, shaderkey, half_w, half_h, tint, alpha, dang);
        float slot = CSQC_InfoDecal_AddDecalSlot(pos, norm, shaderkey, half_w, half_h, tint, alpha, dang);
        if (slot >= 0)
        {   // cache BuildShader's inputs so CSQC_RendererRestarted can rebuild the shader
            id_dec_texname[slot] = texname;
            id_dec_rmode[slot]   = rmode;
        }

        self.id_placed = 1;
    }
};
