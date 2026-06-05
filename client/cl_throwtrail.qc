// ============================================================
//  client/cl_throwtrail.qc  -  Fading polygonal trail behind
//  thrown projectiles (snowballs + grenades).
//
//  Per-tracked-projectile ring buffer of sampled origins.  Each
//  frame walks all csqc_projectile entities of an eligible type
//  (grenade family or snowball), pushes the current origin into
//  the ring, then renders a camera-facing ribbon connecting the
//  last N samples.  The head end (current origin) is at full
//  width/alpha; samples taper to zero width and zero alpha as
//  they age out, producing the "fading shrinking tail to a point"
//  shape the user asked for.
//
//  Pattern mirrors cl_tracers.qc's per-quad submission via
//  R_BeginPolygon / R_PolygonVertex / R_EndPolygon.  No server
//  cooperation — purely cosmetic, all CSQC.
//
//  Cvars (registered in shared/sh_cvar_table.qc):
//    cl_throwtrail           — 0/1 enable
//    cl_throwtrail_length    — head-end fade duration in seconds
//    cl_throwtrail_width     — head-end ribbon width (qu)
//    cl_throwtrail_alpha     — head-end alpha
//    cl_throwtrail_color     — RGB tint vec3
//    cl_throwtrail_texture   — shader name (auto-registered via
//                               shaderforname on first draw)
// ============================================================

const int TT_TRAIL_MAX = 64;          // ring slots per projectile
const int TT_PROJ_MAX  = 32;          // max simultaneously-tracked projectiles

// Spawn-frame skip: the first sampled origin is the projectile's
// spawn position (e.g. for snowballs: self.origin + view_ofs +
// v_forward * 18 — inside the thrower's body region).  Drawing a
// segment from that to the next sample produces a visible "line
// from my chest to the throw-start point" artifact.  Skipping the
// first sample means the trail starts from the SECOND captured
// origin (already mid-flight), eliminating the artifact.
const int TT_SAMPLE_SKIP = 1;

// Per-slot state.  Slot 0 unused (sentinel) so entnum=0 is "free".
float  tt_proj_entnum [TT_PROJ_MAX];
vector tt_trail_pos   [TT_PROJ_MAX * TT_TRAIL_MAX];
float  tt_trail_time  [TT_PROJ_MAX * TT_TRAIL_MAX];
int    tt_trail_count [TT_PROJ_MAX];      // filled slots in this ring
int    tt_trail_head  [TT_PROJ_MAX];      // next write index (wraps)
float  tt_proj_lru    [TT_PROJ_MAX];      // cltime of last write — LRU eviction
float  tt_last_sample [TT_PROJ_MAX];      // cltime the last sample was pushed
int    tt_total_seen  [TT_PROJ_MAX];      // total samples observed (for spawn-skip)
float  tt_spawn_time  [TT_PROJ_MAX];      // cltime of first KEPT sample — used for
                                          // the head-end width rampup so the trail
                                          // starts narrow at throw and widens to
                                          // cl_throwtrail_width over the rampup
                                          // window.

// One-shot shader registration cache.  Re-register every time the
// texture cvar changes; idempotent shaderforname call otherwise.
string tt_shader_current;

// Eligibility — which projectile types get a trail.  Anything thrown
// or grenade-shaped.  Crossbow bolts / RPGs / paintballs deliberately
// excluded (they're shot, not thrown — separate visual identity).
float(float ptype) ThrowTrail_TypeEligible =
{
    if (ptype == PROJ_TYPE_HLGRENADE)      return 1;   // HL handgrenade
    if (ptype == PROJ_TYPE_GRENADE)        return 1;   // launcher grenade
    if (ptype == PROJ_TYPE_SNOWBALL)       return 1;
    if (ptype == PROJ_TYPE_CSHEGRENADE)    return 1;
    if (ptype == PROJ_TYPE_CSFLASHBANG)    return 1;
    if (ptype == PROJ_TYPE_CSSMOKEGRENADE) return 1;
    return 0;
};

// Find existing slot for entnum, or allocate a free / LRU one.
// Returns -1 only if entnum is 0 (engine-invalid).
int(float entnum) ThrowTrail_SlotFor =
{
    if (entnum <= 0) return -1;

    int i;
    int free_slot = -1;
    int lru_slot  = 0;
    float lru_t   = tt_proj_lru[0];
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        if (tt_proj_entnum[i] == entnum)
            return i;        // existing
        if (tt_proj_entnum[i] == 0 && free_slot < 0)
            free_slot = i;   // first free
        if (tt_proj_lru[i] < lru_t)
        {
            lru_slot = i;
            lru_t    = tt_proj_lru[i];
        }
    }
    if (free_slot >= 0)
    {
        tt_proj_entnum[free_slot] = entnum;
        tt_trail_count[free_slot] = 0;
        tt_trail_head[free_slot]  = 0;
        tt_proj_lru[free_slot]    = cltime;
        tt_last_sample[free_slot] = 0;
        tt_total_seen[free_slot]  = 0;
        tt_spawn_time[free_slot]  = 0;
        return free_slot;
    }
    // All slots used — evict LRU.
    tt_proj_entnum[lru_slot] = entnum;
    tt_trail_count[lru_slot] = 0;
    tt_trail_head[lru_slot]  = 0;
    tt_proj_lru[lru_slot]    = cltime;
    tt_last_sample[lru_slot] = 0;
    tt_total_seen[lru_slot]  = 0;
    tt_spawn_time[lru_slot]  = 0;
    return lru_slot;
};

// Public — called from CSQC_Ent_Remove when a projectile entity
// disappears (impact, explosion, timeout).  Releases the slot so a
// new projectile can claim it without forcing an LRU eviction of
// an unrelated trail.
void(float entnum) ThrowTrail_OnProjectileRemove =
{
    if (entnum <= 0) return;
    int i;
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        if (tt_proj_entnum[i] == entnum)
        {
            tt_proj_entnum[i] = 0;
            tt_trail_count[i] = 0;
            return;
        }
    }
};

// Push the current origin into the ring.  Time-rate-limited: only
// pushes when at least `min_interval` has elapsed since the last
// sample.  This decouples trail length from frame rate — at any
// FPS, the ring fills with TT_TRAIL_MAX samples spaced
// `min_interval` apart, covering exactly TT_TRAIL_MAX *
// min_interval seconds of motion.  Caller derives min_interval
// from the lifetime cvar so the cvar literally specifies trail
// duration in seconds.
//
// Also skips the first TT_SAMPLE_SKIP samples — those represent
// the projectile's spawn position, which on the owner-side fake
// is inside the thrower's body and produces a visible "line from
// chest to throw-start" segment on the very first frame.
void(int slot, vector pos, float min_interval) ThrowTrail_PushSample =
{
    // Entity-reuse / stale-ring detection.  When the previous fake
    // projectile is removed via remove() (e.g. CSQC_FakeSnowballTouch
    // on landing), the engine does NOT call CSQC_Ent_Remove for the
    // fake — that hook only fires for server-pushed entities.  So
    // tt_proj_entnum[slot] stays stamped with the dead entnum, and
    // the engine may reuse that entnum for a new fake when the
    // player throws again.  SlotFor finds the matching entnum,
    // returns the old slot WITHOUT clearing, and new samples join
    // stale ring data — producing the user-reported "trail draws
    // from new throw position back to the previous landing point"
    // artifact.
    //
    // Detect via time gap: if the last sample is older than 0.5s,
    // the trail has decayed (cl_throwtrail_length default 0.4s, so
    // anything past that is well into "no longer visible").  Treat
    // as a fresh projectile and wipe the ring + reset spawn-skip.
    if (tt_last_sample[slot] > 0
     && cltime - tt_last_sample[slot] > 0.5)
    {
        tt_trail_count[slot] = 0;
        tt_trail_head[slot]  = 0;
        tt_total_seen[slot]  = 0;
        tt_last_sample[slot] = 0;
        tt_spawn_time[slot]  = 0;
    }

    tt_total_seen[slot] = tt_total_seen[slot] + 1;
    if (tt_total_seen[slot] <= TT_SAMPLE_SKIP)
    {
        // Eat the first sample(s) — spawn-position artifact.  Still
        // bump the timer so the next sample isn't rate-limited from
        // the t=0 baseline.
        tt_last_sample[slot] = cltime;
        tt_proj_lru[slot]    = cltime;
        return;
    }

    // Rate-limit: only push if enough time has passed since the
    // previous sample.  First post-skip sample falls through
    // because tt_last_sample was reset above to cltime, but that
    // sample is still good (the projectile has moved at least one
    // frame from spawn).
    if (cltime - tt_last_sample[slot] < min_interval)
    {
        tt_proj_lru[slot] = cltime;       // keep the slot warm
        return;
    }

    int base = slot * TT_TRAIL_MAX;
    int h    = tt_trail_head[slot];
    tt_trail_pos [base + h] = pos;
    tt_trail_time[base + h] = cltime;
    int next_h = h + 1;
    if (next_h >= TT_TRAIL_MAX) next_h = 0;
    tt_trail_head[slot] = next_h;
    if (tt_trail_count[slot] < TT_TRAIL_MAX)
        tt_trail_count[slot] = tt_trail_count[slot] + 1;
    tt_last_sample[slot] = cltime;
    tt_proj_lru[slot]    = cltime;

    // Record spawn time of FIRST kept sample.  Used by the draw
    // code to ramp head-end width from 0 → cl_throwtrail_width
    // over cl_throwtrail_rampup seconds, so the trail visually
    // grows from a point at throw to its full width as the
    // grenade travels.
    if (tt_spawn_time[slot] == 0)
        tt_spawn_time[slot] = cltime;
};

// Register the trail shader at runtime.  Inline default fallback so
// no static shader file is required for the throwtrail to render —
// runtime-registered polygonoffset isn't needed because the ribbon
// floats in mid-air (no surface to z-fight against).
void(string tex) ThrowTrail_RegisterShader =
{
    if (tex == tt_shader_current) return;
    string body = sprintf(
        "{\n"
        "    nopicmip\n"
        "    cull none\n"
        "    {\n"
        "        map %s\n"
        "        rgbGen vertex\n"
        "        alphaGen vertex\n"
        "        blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA\n"
        "    }\n"
        "}\n", tex);
    shaderforname(tex, body);
    precache_pic(tex);
    tt_shader_current = tex;
};

// Per-frame entry point.  Called from CSQC_UpdateViewAliveScene
// alongside CSQC_TracersDraw / CSQC_Rain_Tick.
void() CSQC_ThrowTrail_Tick =
{
    if (cvar("cl_throwtrail") <= 0) return;

    float lifetime = cvar("cl_throwtrail_length");
    if (lifetime <= 0) lifetime = 0.4;
    // Sampling interval = lifetime / ring size.  Spaces samples so the
    // oldest one is exactly `lifetime` seconds old when it gets
    // evicted — i.e. the cvar literally controls trail duration in
    // seconds, regardless of FPS.  Floor at 1ms so a tiny lifetime
    // doesn't div-by-zero or hammer the sample loop.
    float min_interval = lifetime / (float)TT_TRAIL_MAX;
    if (min_interval < 0.001) min_interval = 0.001;

    float head_alpha = bound(0, cvar("cl_throwtrail_alpha"), 1);
    if (head_alpha <= 0) return;
    float head_width = cvar("cl_throwtrail_width");
    if (head_width <= 0) head_width = 2;

    // Rampup window: head-end width grows from 0 → head_width over
    // this many seconds since the projectile's first sample.  0 (or
    // unset) disables the ramp — trail starts at full width
    // immediately (legacy behaviour).
    float rampup = cvar("cl_throwtrail_rampup");
    if (rampup < 0) rampup = 0;

    vector colour = stov(cvar_string("cl_throwtrail_color"));
    if (colour == '0 0 0') colour = '1 1 1';

    string tex = cvar_string("cl_throwtrail_texture");
    if (tex == "") tex = "gfx/throwtrail/default";
    ThrowTrail_RegisterShader(tex);

    vector cam_pos = (vector)getproperty(VF_ORIGIN);

    // === Update phase: walk all live projectiles, push their current
    // origin into the matching ring slot. ===
    //
    // Two classnames are scanned:
    //   "csqc_projectile"     — server-replicated projectiles
    //                            (cl_projectiles.qc), seen by every
    //                            non-owner client.
    //   "csqc_fake_csgrenade" — owner-side CSQC fake for CS-style
    //                            grenades; tagged with the matching
    //                            csqc_projectile_type at spawn so the
    //                            eligibility check below works.
    // HL grenades and snowballs use "csqc_projectile" for their fakes
    // too (we stamped them at spawn alongside the real classname),
    // so they don't need a third pass.
    int slot;
    entity p = find(world, classname, "csqc_projectile");
    while (p)
    {
        if (ThrowTrail_TypeEligible(p.csqc_projectile_type))
        {
            slot = ThrowTrail_SlotFor(num_for_edict(p));
            if (slot >= 0)
                ThrowTrail_PushSample(slot, p.origin, min_interval);
        }
        p = find(p, classname, "csqc_projectile");
    }
    p = find(world, classname, "csqc_fake_csgrenade");
    while (p)
    {
        if (ThrowTrail_TypeEligible(p.csqc_projectile_type))
        {
            slot = ThrowTrail_SlotFor(num_for_edict(p));
            if (slot >= 0)
                ThrowTrail_PushSample(slot, p.origin, min_interval);
        }
        p = find(p, classname, "csqc_fake_csgrenade");
    }

    // === Draw phase: per-slot, build a tapering ribbon between
    // consecutive ring samples.  Walk newest→oldest, computing the
    // age-based fade and width taper per segment. ===
    int i;
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        if (tt_proj_entnum[i] == 0)        continue;
        if (tt_trail_count[i] < 2)         continue;     // need 2 points for a segment

        int base = i * TT_TRAIL_MAX;
        int n    = tt_trail_count[i];
        // Walk samples newest→oldest.  head-1 is the newest.
        int j;
        for (j = 0; j < n - 1; j = j + 1)
        {
            int idx_new = tt_trail_head[i] - 1 - j;
            int idx_old = idx_new - 1;
            while (idx_new < 0) idx_new = idx_new + TT_TRAIL_MAX;
            while (idx_old < 0) idx_old = idx_old + TT_TRAIL_MAX;

            float age_new = cltime - tt_trail_time[base + idx_new];
            float age_old = cltime - tt_trail_time[base + idx_old];
            if (age_new >= lifetime) break;   // and all older are too — done with this slot

            float fade_new = 1.0 - (age_new / lifetime);
            float fade_old = 1.0 - (age_old / lifetime);
            if (fade_old < 0) fade_old = 0;

            // Per-sample width rampup: each sample's contribution to
            // the trail's effective head_width is scaled by how old
            // the SAMPLE'S RECORDING MOMENT was relative to the
            // projectile's first-sample time.  Net effect: the trail
            // width at any point along the ribbon corresponds to
            // "how long had the grenade been flying when that piece
            // of trail was recorded".  Earliest samples (near throw
            // moment) → narrow; later samples (further into flight)
            // → full width.  cltime - sample_time = sample age;
            // first_sample_time = tt_spawn_time[i].  So sample's
            // grenade age = sample_time - tt_spawn_time[i].
            float ramp_new = 1;
            float ramp_old = 1;
            if (rampup > 0 && tt_spawn_time[i] > 0)
            {
                float gren_age_new = tt_trail_time[base + idx_new] - tt_spawn_time[i];
                float gren_age_old = tt_trail_time[base + idx_old] - tt_spawn_time[i];
                ramp_new = bound(0, gren_age_new / rampup, 1);
                ramp_old = bound(0, gren_age_old / rampup, 1);
            }

            float a_new = head_alpha * fade_new;
            float a_old = head_alpha * fade_old;
            float w_new = head_width * fade_new * ramp_new;
            float w_old = head_width * fade_old * ramp_old;

            vector p_new = tt_trail_pos[base + idx_new];
            vector p_old = tt_trail_pos[base + idx_old];

            vector dir = p_new - p_old;
            if ((dir * dir) < 0.01) continue;
            dir = normalize(dir);

            // Camera-facing side vector — perpendicular to segment
            // direction AND the eye→midpoint vector (same pattern as
            // cl_tracers.qc:148).
            vector mid     = (p_new + p_old) * 0.5;
            vector cam_dir = mid - cam_pos;
            if (vlen(cam_dir) < 0.01) continue;
            cam_dir = normalize(cam_dir);
            vector side = crossproduct(dir, cam_dir);
            if (vlen(side) < 0.01)
            {
                // Fallback when segment is parallel to view dir.
                if (fabs(dir_z) < 0.95)
                    side = crossproduct(dir, '0 0 1');
                else
                    side = crossproduct(dir, '1 0 0');
                if (vlen(side) < 0.01) continue;
            }
            side = normalize(side);

            vector side_new = side * (w_new * 0.5);
            vector side_old = side * (w_old * 0.5);

            R_BeginPolygon(tex, 0, 0);
            R_PolygonVertex(p_old - side_old, '0 0 0', colour, a_old);
            R_PolygonVertex(p_old + side_old, '1 0 0', colour, a_old);
            R_PolygonVertex(p_new + side_new, '1 1 0', colour, a_new);
            R_PolygonVertex(p_new - side_new, '0 1 0', colour, a_new);
            R_EndPolygon();
        }
    }
};

// Map-change reset — clears all slots so a new map doesn't render
// trails carried over from the previous map.  Hooked from the same
// map-load path that resets bullet holes / sprays / scorches.
void() CSQC_ThrowTrail_Clear =
{
    int i;
    for (i = 0; i < TT_PROJ_MAX; i = i + 1)
    {
        tt_proj_entnum[i] = 0;
        tt_trail_count[i] = 0;
        tt_trail_head[i]  = 0;
        tt_proj_lru[i]    = 0;
        tt_last_sample[i] = 0;
        tt_total_seen[i]  = 0;
        tt_spawn_time[i]  = 0;
    }
};
