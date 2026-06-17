// ============================================================
//  client/cl_bloodsplat.qc  -  Projected blood-splat decals
//
//  Spawned at flesh impacts.  Engine-side particle systems
//  (pointparticles) live in C and can't be inspected from QC,
//  so we can't literally watch each red blood particle and
//  decal where it lands.  Instead we approximate the spray:
//  when a flesh hit happens we fire a small fan of tracelines
//  out from the wound and stamp a decal wherever each one
//  intersects world geometry.  Result is the visual the user
//  wants — splats on the wall behind the target and pools on
//  the floor underneath — without the engine knowing or caring.
//
//  Two trace patterns per impact:
//    a) "Exit-wound spray" — opposite the surface normal, with
//       random spread, captures the wall behind the target.
//    b) "Floor pool"       — straight down from randomly offset
//       points around the wound, captures the floor underneath.
//
//  Each decal uses adddecal() with one of seven bloodsplat
//  textures picked at spawn.  adddecal projects the texture
//  onto whatever BSP triangles it covers and clips at surface
//  boundaries — same wrap-the-geometry behaviour as scorches.
//
//  Cost: one adddecal call per active decal per frame.  Per-
//  impact spawns up to BLOOD_SPAWN_WALL + BLOOD_SPAWN_FLOOR
//  decals (default 5).  Total cap is BLOOD_MAX (default 96)
//  via the same FIFO eviction the scorch module uses.
//
//  Lifecycle: spawn -> 25 s opaque -> 5 s linear fade -> free.
// ============================================================

const string BLOOD_SHADER_1     = "gfx/blood/bloodsplat1";
const string BLOOD_SHADER_2     = "gfx/blood/bloodsplat2";
const string BLOOD_SHADER_3     = "gfx/blood/bloodsplat3";
const string BLOOD_SHADER_4     = "gfx/blood/bloodsplat4";
const string BLOOD_SHADER_5     = "gfx/blood/bloodsplat5";
const string BLOOD_SHADER_6     = "gfx/blood/bloodsplat6";
const string BLOOD_SHADER_7     = "gfx/blood/bloodsplat7";

// Decal half-extent in world units.  Smaller than scorch (64)
// because each impact stamps multiple splats; oversized blood
// reads as "soup" instead of distinct droplets.
const float  BLOOD_HALF_SIZE    = 24;

// How far we look for surfaces around a flesh hit.
const float  BLOOD_WALL_RANGE   = 192;   // exit-wound spray reach
const float  BLOOD_FLOOR_RANGE  = 256;   // diagonal floor-spray trace length
const float  BLOOD_FLOOR_SPREAD = 96;    // horizontal aim offset at floor depth
                                         // — wider value = flatter, wider fan

// Spawn budgets per impact.  Tunable via cvars below; constants
// are the fallback when the cvars are zero / unset.
// One of each by default — the user found multiple splats per shot
// read as gore-soup; a single arrow-shaped streak forward and one
// drip underneath gives a cleaner, more readable hit reaction.
const float  BLOOD_SPAWN_WALL   = 1;
const float  BLOOD_SPAWN_FLOOR  = 1;

const float  BLOOD_FADE_START   = 25;
const float  BLOOD_FADE_END     = 30;
const float  BLOOD_MAX          = 96;    // default live cap (cl_blood_decals_max overrides)
// Compile-time ceiling for cl_blood_decals_max.  MUST equal BLOOD_TRISOUP_MAX in
// cl_bloodtrisoup.qc (each of the 7 baked-trisoup partitions is sized to this, so
// the cap can never exceed it without overrunning the vertex buffer).
const float  BLOOD_HARD_MAX     = 256;

entity bs_head;
entity bs_tail;
.entity bs_prev;
.entity bs_next;
.float  bs_tex;           // 1..7, picks one of BLOOD_SHADER_N
.float  bs_spawn_time;
.vector bs_origin;        // trace_endpos
.vector bs_normal;        // outward surface normal
.vector bs_tangent;       // pre-baked side axis perpendicular to normal
.float  bs_size_scale;    // 1 = regular blood, 0.75 = smaller gib impact
.string bs_shader;        // BLOOD_SHADER_N resolved ONCE at spawn (perf: was re-resolved per decal per frame)
// Absolute slot index into the baked trisoup buffer (cl_bloodtrisoup.qc).
// -1 = not baked.  Set by Blood_BakeTrisoup, cleared by Blood_FreeTrisoupSlot.
.float  bs_slot;
// Last vertex alpha written to the baked quad.  The bake seeds the verts (and
// this) to 1.0, alpha is constant 1.0 for the whole 25 s hold, and only changes
// during the 5 s fade — so the per-frame alpha rewrite is rewritten ONLY when it
// actually differs from this (change-detection).  Seeded in Blood_BakeTrisoup
// (not at declaration — fteqcc const-global-initializer trap).
.float  bs_last_alpha;
float   bs_count;

// Baked-trisoup batch (cl_bloodtrisoup.qc, compiled AFTER cl_bulletholes.qc
// so it can reuse the BH_* clip/write helpers).  Forward-declared here so
// the spawn / remove / draw paths below can call them; the bodies live in
// the later file.  Geometry is baked once at spawn; per-frame cost is the
// fade alpha rewrite + one addtrisoup_simple per texture.
void(entity bs) Blood_BakeTrisoup;
void(entity bs) Blood_FreeTrisoupSlot;
void(float abs_slot, float alpha) Blood_SetSlotAlpha;
void() Blood_DrawTrisoup;
void() Blood_ResetTrisoup;

void() CSQC_Bloodsplat_Precache =
{
    precache_pic(BLOOD_SHADER_1);
    precache_pic(BLOOD_SHADER_2);
    precache_pic(BLOOD_SHADER_3);
    precache_pic(BLOOD_SHADER_4);
    precache_pic(BLOOD_SHADER_5);
    precache_pic(BLOOD_SHADER_6);
    precache_pic(BLOOD_SHADER_7);
};

void(entity bs) CSQC_BloodsplatRemove =
{
    if (bs.bs_prev)
        bs.bs_prev.bs_next = bs.bs_next;
    else
        bs_head = bs.bs_next;
    if (bs.bs_next)
        bs.bs_next.bs_prev = bs.bs_prev;
    else
        bs_tail = bs.bs_prev;
    // Release the baked trisoup slot before freeing the entity (no-op for
    // splats whose bake failed / never ran — bs_slot stays at -1).
    Blood_FreeTrisoupSlot(bs);
    remove(bs);
    bs_count = bs_count - 1;
};

void() CSQC_BloodsplatWipeAll =
{
    while (bs_head)
        CSQC_BloodsplatRemove(bs_head);
    // Drain free lists + reset high-water marks so the next round starts
    // with a clean slot pool (mirrors CSQC_BulletHolesWipeAll).
    Blood_ResetTrisoup();
};

string(float idx) CSQC_BloodShaderForIndex =
{
    if (idx <= 1) return BLOOD_SHADER_1;
    if (idx == 2) return BLOOD_SHADER_2;
    if (idx == 3) return BLOOD_SHADER_3;
    if (idx == 4) return BLOOD_SHADER_4;
    if (idx == 5) return BLOOD_SHADER_5;
    if (idx == 6) return BLOOD_SHADER_6;
    return BLOOD_SHADER_7;
};

// Resolve the live decal cap.  cl_blood_decals_max overrides BLOOD_MAX; <=0
// falls back to the default, and it is clamped to BLOOD_HARD_MAX (the baked
// trisoup buffer ceiling — exceeding it would overrun blood_verts).
float() Blood_ResolveMax =
{
    float m = cvar("cl_blood_decals_max");
    if (m <= 0)
        m = BLOOD_MAX;
    if (m > BLOOD_HARD_MAX)
        m = BLOOD_HARD_MAX;
    return m;
};

// Append one decal to the list at trace_endpos / trace_plane_normal.
// Caller is responsible for issuing the traceline first; this just
// reads the trace_* globals.  Skips when the trace whiffed or hit sky.
void() CSQC_BloodsplatAddFromTrace =
{
    if (trace_fraction >= 1.0)
        return;
    if (vlen(trace_plane_normal) <= 0)
        return;
    if (pointcontents(trace_endpos - trace_plane_normal * 2) == CONTENT_SKY)
        return;

    float bmax = Blood_ResolveMax();
    while (bs_count >= bmax && bs_head)
        CSQC_BloodsplatRemove(bs_head);

    entity bs = spawn();
    bs.classname     = "blood_decal";
    bs.bs_tex        = 1 + floor(random() * 7);   // 1..7
    if (bs.bs_tex > 7) bs.bs_tex = 7;
    bs.bs_shader     = CSQC_BloodShaderForIndex(bs.bs_tex);  // resolve once, not per-frame
    bs.bs_spawn_time = cltime;
    bs.bs_origin     = trace_endpos;
    bs.bs_normal     = normalize(trace_plane_normal);
    bs.bs_size_scale = 1.0;

    // Pre-bake a side axis perpendicular to the normal so the per-
    // frame draw doesn't recompute it.  Same trick the scorch module
    // uses — pick a reference axis that isn't colinear with the
    // normal, then cross.
    vector ref;
    if (fabs(bs.bs_normal_z) < 0.9)
        ref = '0 0 1';
    else
        ref = '1 0 0';
    bs.bs_tangent = normalize(crossproduct(bs.bs_normal, ref));

    bs.bs_slot = -1;
    bs.bs_prev = bs_tail;
    bs.bs_next = world;
    if (bs_tail)
        bs_tail.bs_next = bs;
    else
        bs_head = bs;
    bs_tail = bs;
    bs_count = bs_count + 1;

    // Bake the splat geometry ONCE now that origin/normal/tangent are
    // resolved.  Per-frame draw is then just an alpha rewrite + batch.
    Blood_BakeTrisoup(bs);
};

// Direct one-shot decal spawn for effects that already know their
// contact point, such as bouncing flesh gibs.  It renders through the
// same alpha / brightness path as bullet blood, but uses a smaller
// projection size so one chunk bounce does not read like a bullet hit.
void(vector pos, vector normal) CSQC_SpawnBloodDecalAt =
{
    if (!cvar("cl_blood_decals"))
        return;
    if (vlen(normal) <= 0)
        return;

    normal = normalize(normal);
    if (pointcontents(pos - normal * 2) == CONTENT_SKY)
        return;

    float bmax = Blood_ResolveMax();
    while (bs_count >= bmax && bs_head)
        CSQC_BloodsplatRemove(bs_head);

    entity bs = spawn();
    bs.classname     = "blood_decal";
    bs.bs_tex        = 1 + floor(random() * 7);
    if (bs.bs_tex > 7) bs.bs_tex = 7;
    bs.bs_shader     = CSQC_BloodShaderForIndex(bs.bs_tex);  // resolve once, not per-frame
    bs.bs_spawn_time = cltime;
    bs.bs_origin     = pos;
    bs.bs_normal     = normal;
    bs.bs_size_scale = 0.75;

    vector ref;
    if (fabs(bs.bs_normal_z) < 0.9)
        ref = '0 0 1';
    else
        ref = '1 0 0';
    bs.bs_tangent = normalize(crossproduct(bs.bs_normal, ref));

    bs.bs_slot = -1;
    bs.bs_prev = bs_tail;
    bs.bs_next = world;
    if (bs_tail)
        bs_tail.bs_next = bs;
    else
        bs_head = bs;
    bs_tail = bs;
    bs_count = bs_count + 1;

    Blood_BakeTrisoup(bs);
};

// Public spawn entry.  Called from Impact_SpawnParticles when the
// material is flesh-class; pos is the hit point on the player,
// normal is the player surface normal (points back toward the
// shooter).  Fires a fan of tracelines and stamps decals wherever
// they hit world geometry.
//
// IMPORTANT: trace_* globals are saved and restored around our
// trace calls.  Callers like CSQC_BulletImpact read trace_ent
// AFTER Impact_SpawnParticles to drive hit attribution + breakable
// prediction; without the save/restore our blood traces clobber
// trace_ent and sv_trust_clienthits ends up rejecting the player
// hit entirely (last seen Dec 2025).
void(vector pos, vector normal) CSQC_SpawnBloodDecals =
{
    if (!cvar("cl_blood_decals"))
        return;
    if (vlen(normal) <= 0)
        return;

    // Snapshot the caller's trace state.
    entity saved_ent           = trace_ent;
    float  saved_fraction      = trace_fraction;
    vector saved_endpos        = trace_endpos;
    vector saved_plane_normal  = trace_plane_normal;
    float  saved_plane_dist    = trace_plane_dist;
    float  saved_inopen        = trace_inopen;
    float  saved_inwater       = trace_inwater;

    // Resolve per-impact spawn counts, allowing cvar overrides.
    float wall_n  = cvar("cl_blood_decals_wall_count");
    float floor_n = cvar("cl_blood_decals_floor_count");
    if (wall_n  <= 0) wall_n  = BLOOD_SPAWN_WALL;
    if (floor_n <= 0) floor_n = BLOOD_SPAWN_FLOOR;

    vector spray_dir = normalize(0 - normal);   // exit-wound direction

    // Both trace categories use MOVE_NOMONSTERS so the player/proxy
    // hitbox we just shot through isn't in the way.  Previously the
    // wall trace was MOVE_NORMAL and would smash straight into the
    // victim's own bbox a few units past the impact, producing zero
    // wall splats.  MOVE_NOMONSTERS still hits BSP world geometry,
    // which is exactly what we want decals on.

    // --- Wall splat(s): cone of tracelines along the exit-wound axis ---
    float i;
    for (i = 0; i < wall_n; i = i + 1)
    {
        // Random offset in a unit ball, scaled to control cone width.
        // Adding to spray_dir then re-normalising gives a spread cone
        // around the original axis without needing a proper basis.
        vector jitter = [random() - 0.5, random() - 0.5, random() - 0.5] * 0.9;
        vector dir = normalize(spray_dir + jitter);
        traceline(pos, pos + dir * BLOOD_WALL_RANGE, MOVE_NOMONSTERS, self);
        CSQC_BloodsplatAddFromTrace();
    }

    // --- Floor splat(s): angled traces that fan outward and downward
    // from the wound point.  Single trace default, but the spread cone
    // is wide enough that consecutive shots on the same target leave
    // distinct floor marks instead of stacking on one voxel.
    for (i = 0; i < floor_n; i = i + 1)
    {
        vector aim_offset = [(random() - 0.5) * 2 * BLOOD_FLOOR_SPREAD,
                             (random() - 0.5) * 2 * BLOOD_FLOOR_SPREAD,
                             0 - BLOOD_FLOOR_RANGE];
        vector dir = normalize(aim_offset);
        traceline(pos, pos + dir * BLOOD_FLOOR_RANGE, MOVE_NOMONSTERS, self);
        CSQC_BloodsplatAddFromTrace();
    }

    // Restore the caller's trace state — CSQC_BulletImpact still
    // needs trace_ent / trace_endpos for hole placement, breakable
    // prediction, and the trust-clienthits damage round-trip.
    trace_ent           = saved_ent;
    trace_fraction      = saved_fraction;
    trace_endpos        = saved_endpos;
    trace_plane_normal  = saved_plane_normal;
    trace_plane_dist    = saved_plane_dist;
    trace_inopen        = saved_inopen;
    trace_inwater       = saved_inwater;
};

void() CSQC_DrawBloodDecals =
{
    // No cvar gate here — the spawn function already refuses to add
    // new decals when cl_blood_decals is 0, so any entries in the
    // list are valid to keep drawing.  Toggling the cvar off mid-game
    // lets existing splats fade out naturally instead of snapping.
    //
    // PERF: geometry is now BAKED once at spawn (Blood_BakeTrisoup) and
    // submitted as a per-texture trisoup batch by Blood_DrawTrisoup —
    // adddecal() (which re-projected onto the BSP every decal every frame)
    // is gone.  This loop only (a) ages each splat and removes expired
    // ones, and (b) rewrites the 4 baked vertex alphas to drive the fade.
    // The behind-camera / distance cull is dropped — the batch draws every
    // splat and the engine frustum-culls the trisoup.

    entity bs = bs_head;
    entity next_bs;
    float  age, alpha;
    float  persistent = cvar("cl_blood_persistent");

    while (bs)
    {
        next_bs = bs.bs_next;

        if (persistent)
        {
            alpha = 1.0;
        }
        else
        {
            age = cltime - bs.bs_spawn_time;
            if (age >= BLOOD_FADE_END)
            {
                CSQC_BloodsplatRemove(bs);
                bs = next_bs;
                continue;
            }
            if (age < BLOOD_FADE_START)
                alpha = 1.0;
            else
                alpha = 1.0 - (age - BLOOD_FADE_START)
                            / (BLOOD_FADE_END - BLOOD_FADE_START);
        }

        // Rewrite the 4 baked vertex alphas ONLY when alpha actually changed
        // since last frame (change-detection).  During the 25 s opaque hold and
        // in persistent mode alpha is a constant 1.0 already baked into the
        // verts, so this skips the write entirely; it fires only across the 5 s
        // fade (and once to restore 1.0 if persistent is toggled on mid-fade).
        // Skips splats that failed to bake (bs_slot == -1).
        if (bs.bs_slot >= 0 && alpha != bs.bs_last_alpha)
        {
            Blood_SetSlotAlpha(bs.bs_slot, alpha);
            bs.bs_last_alpha = alpha;
        }

        bs = next_bs;
    }

    // One addtrisoup_simple per non-empty texture — replaces the old
    // per-decal adddecal storm.
    Blood_DrawTrisoup();
};
