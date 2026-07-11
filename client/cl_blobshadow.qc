// ============================================================================
//  Blob shadows — cheap batched ground-shadow blobs under models.
//
//  A soft dark quad (gfx/blobshadow.png, black + radial alpha falloff) is projected
//  from each entity along the ACTIVE GRAVITY direction onto the world and drawn
//  through ONE addtrisoup_simple call per frame, mirroring the blood/bullet-hole
//  trisoup architecture (this file compiles after cl_bulletholes.qc and reuses its
//  BH_WriteQuad writer + Decal_BaseShaderBody shader body).
//
//  Two quad classes share one buffer:
//    [0, blob_static_count)      persistent baked blobs under SETTLED physics props
//                                (their predraw unhooks at rest — see cl_physprop.qc —
//                                so nothing would re-emit them per frame).  Freed on
//                                wake / entity removal via BlobShadow_FreeStatic.
//    [static_count, blob_count)  per-frame dynamic suffix, re-emitted by live predraws
//                                (players, corpses, ragdolls, moving props) and reset
//                                every frame by BlobShadow_FrameReset.
//
//  Cvar-gated experiment (all registered in sh_cvar_table.qc, default OFF):
//    cl_blobshadows 0|1, cl_blobshadow_scale, cl_blobshadow_alpha,
//    cl_blobshadow_maxdist, cl_blobshadow_sunskew.
//  Auto-disables (with a one-time note) while the ENGINE's r_shadows >= 1 is active,
//  so the two systems never double-shadow.
// ============================================================================

const float BLOB_MAX_QUADS = 512;      // ~400 resting props + live players/props headroom

string BLOB_SHADER = "gfx/blobshadow";

auto trisoup_simple_vert_t blob_verts[BLOB_MAX_QUADS * 4];
auto int                   blob_idx  [BLOB_MAX_QUADS * 6];
int  blob_static_count;                // persistent prefix high-water mark
int  blob_count;                       // static prefix + this frame's dynamic suffix
auto int                   blob_free[BLOB_MAX_QUADS];
int  blob_free_count;

// Slot+1 of a baked static blob owned by this (settled prop) entity; 0 = none.
.float pp_blob_slot;

// Per-frame cvar cache (polled once in BlobShadow_FrameReset, read by every emit).
float blob_on;
float blob_scale_cv;
float blob_alpha_cv;
float blob_maxdist_cv;
float blob_sunskew_cv;
float blob_engine_warned;

// Register the blob shader under its texture name (a bare precache_pic name renders
// INVISIBLE through addtrisoup_simple — same trap as the other decals).  Called from
// CSQC init and CSQC_RendererRestarted (vid_restart purges shaderforname shaders).
void() CSQC_BlobShadow_ReregisterShaders =
{
    shaderforname(BLOB_SHADER, Decal_BaseShaderBody(BLOB_SHADER));
};

// Frame start (cl_main.qc, next to CSQC_BulletHolesStartFrame): poll cvars, drop last
// frame's dynamic suffix.  The static prefix persists untouched.
void() BlobShadow_FrameReset =
{
    blob_on = cvar("cl_blobshadows");
    if (blob_on)
    {
        if (cvar("r_shadows") >= 1)
        {
            if (!blob_engine_warned)
            {
                print("cl_blobshadows: engine r_shadows is active - blob shadows disabled to avoid doubling (set r_shadows 0 to use them)\n");
                blob_engine_warned = 1;
            }
            blob_on = 0;
        }
        else
            blob_engine_warned = 0;
    }
    blob_scale_cv   = cvar("cl_blobshadow_scale");
    if (blob_scale_cv <= 0)   blob_scale_cv = 1.0;
    blob_alpha_cv   = cvar("cl_blobshadow_alpha");
    if (blob_alpha_cv <= 0)   blob_alpha_cv = 0.5;
    blob_maxdist_cv = cvar("cl_blobshadow_maxdist");
    if (blob_maxdist_cv <= 0) blob_maxdist_cv = 256;
    blob_sunskew_cv = cvar("cl_blobshadow_sunskew");

    blob_count = blob_static_count;
};

// Frame end (cl_main.qc, after both addentities passes so every predraw has emitted):
// ONE draw call for every blob on screen.  Gating on blob_on also hides the persistent
// static prefix the moment the cvar goes off.
void() BlobShadow_FrameSubmit =
{
    if (!blob_on)
        return;
    if (blob_count > 0)
        addtrisoup_simple(BLOB_SHADER, 0, &blob_verts[0], &blob_idx[0], blob_count * 6);
};

// Compute the ground quad for `e` and write it at `slot`.  Returns TRUE if written.
// Projection runs along the ACTIVE gravity dir (gravity-shift aware: blobs sit on the
// wall you're walking on), lands on world/BSP only (MOVE_NOMONSTERS), fades+shrinks
// with height, and scales darkness by the local lightmap so unlit corners don't get
// double-dark.  Optional sun skew pushes the blob away from env_sun's r_sun_dir.
float(entity e, int slot) BlobShadow_WriteForEnt =
{
    vector gdir = stov(serverkey("gravdir"));
    if (gdir == '0 0 0')
        gdir = '0 0 -1';

    traceline(e.origin, e.origin + gdir * blob_maxdist_cv, MOVE_NOMONSTERS, e);
    if (trace_fraction >= 1)
        return FALSE;

    vector n = trace_plane_normal;
    if (vlen(n) < 0.001)
        n = '0 0 0' - gdir;

    float h    = vlen(trace_endpos - e.origin);
    float fade = 1 - (h / blob_maxdist_cv);
    if (fade <= 0)
        return FALSE;

    // Footprint radius from the entity's bbox; the texture's soft edge reads smaller
    // than the quad, so pad it.  Shrink a little as the caster rises.
    float rx = e.maxs_x - e.mins_x;
    float ry = e.maxs_y - e.mins_y;
    float radius = max(rx, ry) * 0.5;
    if (radius < 4)
        radius = 4;
    radius = radius * 1.35 * blob_scale_cv * (0.65 + 0.35 * fade);

    // Darkness follows the local light level (getlight at the landing point).
    vector l = getlight(trace_endpos + n * 4);
    float lum = (l_x + l_y + l_z) * 0.333;
    float ldark = lum / 96;
    if (ldark > 1)    ldark = 1;
    if (ldark < 0.15) ldark = 0.15;
    float alpha = blob_alpha_cv * fade * ldark;
    if (alpha <= 0.01)
        return FALSE;

    vector center = trace_endpos + n;      // 1qu lift; the shader's polygonoffset does the rest

    if (blob_sunskew_cv > 0)
    {
        // Per-entity LIGHT-AWARE skew: lean away from THIS entity's own dominant map
        // light (weighted blend of nearby lights + the env_sun term — MapLights_DirAt
        // handles the sun-active gate and stale-r_sun_dir trap internally).  Two props
        // flanking one lamp lean opposite ways.  Zero = nothing in range -> no skew.
        vector sk = MapLights_DirAt(e.origin);
        if (sk != '0 0 0')
        {
            sk = sk - n * (sk * n);                   // keep it in the surface plane
            center = center + sk * (h * 0.25 * blob_sunskew_cv);
        }
    }

    // Tangent frame on the landing surface (same reference-axis trick as Blood_BakeTrisoup).
    vector ref;
    if (fabs(n_z) < 0.9)
        ref = '0 0 1';
    else
        ref = '1 0 0';
    vector tangent   = normalize(crossproduct(n, ref));
    vector bitangent = crossproduct(n, tangent);

    vector q0 = center - tangent * radius - bitangent * radius;
    vector q1 = center + tangent * radius - bitangent * radius;
    vector q2 = center + tangent * radius + bitangent * radius;
    vector q3 = center - tangent * radius + bitangent * radius;

    // Texture RGB is black; the shader is rgbGen vertex so colour is irrelevant —
    // alpha alone controls the darkening blend.
    BH_WriteQuad(slot, q0, q1, q2, q3, '0 0 0', alpha, &blob_verts[0], &blob_idx[0]);
    return TRUE;
};

// Per-frame dynamic emit — call from a live entity's predraw (before its addentity).
void(entity e) BlobShadow_Emit =
{
    // Feed the per-caster fake-shadow driver too (r_shadows 2 + cl_lightshadow_perlight):
    // this runs for every rendered caster BEFORE the blob-enable gate, and self-gates on
    // the fake-shadow system being active, so the two systems are independent.  All six
    // BlobShadow_Emit call sites (players, corpses, props, ragdolls) are caster origins.
    MapLights_RegisterShadowCaster(e.origin);
    if (!blob_on)
        return;
    if (blob_count >= BLOB_MAX_QUADS)
        return;
    if (BlobShadow_WriteForEnt(e, blob_count))
        blob_count = blob_count + 1;
};

// Free a settled prop's persistent blob (on wake, on entity removal).  Degenerates the
// quad in place (zero-area = invisible) and recycles the slot via the free list.
void(entity e) BlobShadow_FreeStatic =
{
    if (!e.pp_blob_slot)
        return;
    int slot = (int)(e.pp_blob_slot - 1);
    BH_WriteQuad(slot, e.origin, e.origin, e.origin, e.origin, '0 0 0', 0,
                 &blob_verts[0], &blob_idx[0]);
    if (blob_free_count < BLOB_MAX_QUADS)
    {
        blob_free[blob_free_count] = slot;
        blob_free_count = blob_free_count + 1;
    }
    e.pp_blob_slot = 0;
};

// Bake a persistent blob under a prop the moment it settles (its predraw is about to
// unhook, so per-frame emit stops).  Freed again by BlobShadow_FreeStatic on wake.
void(entity e) BlobShadow_BakeStatic =
{
    if (!blob_on)
        return;                      // cvar off at settle time: prop stays blob-less until it next wakes
    BlobShadow_FreeStatic(e);        // replace any stale slot

    int slot;
    if (blob_free_count > 0)
    {
        blob_free_count = blob_free_count - 1;
        slot = blob_free[blob_free_count];
    }
    else
    {
        if (blob_static_count >= BLOB_MAX_QUADS)
            return;
        slot = blob_static_count;
        blob_static_count = blob_static_count + 1;
        // Growing the static prefix mid-frame may overwrite the FIRST dynamic quad of
        // this frame's suffix (1 quad, 1 frame — imperceptible); the suffix re-bases
        // on the new prefix at the next FrameReset.
        if (blob_count < blob_static_count)
            blob_count = blob_static_count;
    }

    if (!BlobShadow_WriteForEnt(e, slot))
    {   // No ground below (prop resting on another prop / overhanging a ledge).  The slot
        // may hold STALE dynamic-quad data from an earlier frame (growth claims exactly the
        // index where dynamic suffixes are written) and it now sits inside the persistent
        // static prefix — degenerate it (as FreeStatic does) or it renders as a frozen
        // ghost blob, then return it to the free list.
        BH_WriteQuad(slot, e.origin, e.origin, e.origin, e.origin, '0 0 0', 0,
                     &blob_verts[0], &blob_idx[0]);
        blob_free[blob_free_count] = slot;
        blob_free_count = blob_free_count + 1;
        return;
    }
    e.pp_blob_slot = slot + 1;
};
