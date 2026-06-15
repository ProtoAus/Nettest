// ============================================================
//  client/cl_tracers.qc  -  Per-shot bullet tracers
//
//  Each fired shot emits ONE engine particle (weapons.tracer) that
//  flies from the muzzle to the impact point and dies on the wall.
//  This replaced an older system that rebuilt a camera-facing QUAD
//  per live tracer every frame in QC (R_BeginPolygon) — the particle
//  is carried entirely C-side by the engine's particle simulator, so
//  there is no per-frame QC draw loop and no billboard/muzzle-offset
//  math.  One particle per shot, batched by the engine = a big win on
//  spray weapons vs the old up-to-256 quads/frame.
//
//  The look lives in the recipe (particles/weapons.cfg -> weapons.tracer,
//  hot-reload with `reloaddebris`).  CSQC knobs:
//    cl_tracer               0/1 toggle (default 1)
//    cl_tracer_travel_speed  flight speed qu/s (default 8000) — also the
//                            single source of truth for the delayed-impact
//                            arrival time (see CSQC_ProcessPendingImpacts).
//  (The old per-quad look cvars cl_tracer_width/_color/_opacity/_time and
//  the _travel* mode flags are superseded by the recipe; left registered
//  for config compatibility but no longer drive the particle.)
// ============================================================

// Lazy-resolved handle for the weapons.tracer effect.  particleeffectnum
// returns a slot even for an UNREGISTERED name, so particleeffectquery
// (non-empty == registered) is the real validator — weapons.cfg can finish
// loading a few frames after CSQC init.  Mirrors Rain_ResolveSplash.
float pe_weapons_tracer;

float() Tracer_Resolve =
{
    if (pe_weapons_tracer != 0)
        return pe_weapons_tracer;
    pe_weapons_tracer = particleeffectnum("weapons.tracer");
    if (pe_weapons_tracer != 0 && particleeffectquery(pe_weapons_tracer, 0) == "")
        pe_weapons_tracer = 0;   // not loaded YET — retry next call
    return pe_weapons_tracer;
};

void() CSQC_TracersInit =
{
    pe_weapons_tracer = 0;   // force a fresh resolve on the next shot
};

void() CSQC_TracersWipeAll =
{
    // No per-tracer state to wipe anymore (the engine owns the particles);
    // kept so existing map-change / reset call sites still link.
};

// Emit a tracer for one shot.  Cheap: a single pointparticles call.  The
// emit `dir` arg IS the particle's spawn velocity, so dir*speed makes the
// streak fly to the impact; the recipe's clipbounce -1 kills it on the wall.
// Every fire path can call this without a per-frame budget worry.
void(vector start_pos, vector end_pos) CSQC_SpawnTracer =
{
    if (cvar("cl_tracer") <= 0)
        return;

    // First-person muzzle fix.  start_pos is the weapon's muzzle (current view +
    // the cached muzzle offset), which tracks the CURRENT position.  If it's
    // essentially our camera (first shot before any muzzle flash stamped the
    // offset), relocate to a fake muzzle so the streak exits the gun + clears the
    // near plane.  Remote shooters' starts are their own eye, far from us.
    vector start = start_pos;
    vector cam_pos = (vector)getproperty(VF_ORIGIN);
    if (vlen(start - cam_pos) < 8)
    {
        makevectors((vector)getproperty(VF_ANGLES));
        float lh = cvar("cl_lefthand") ? -1 : 1;
        start = cam_pos + v_forward * 16 + v_right * (4 * lh) + v_up * (-4);
    }

    // Reject zero-length / sub-quake-unit traces — nothing useful to draw.
    vector d = end_pos - start;
    if ((d * d) < 4)        // < 2 qu length
        return;

    float fx = Tracer_Resolve();
    if (fx == 0)
        return;             // recipe not registered yet (or stock engine)

    float speed = cvar("cl_tracer_travel_speed");
    if (speed <= 0) speed = 8000;

    pointparticles(fx, start, normalize(d) * speed, 1);
};
