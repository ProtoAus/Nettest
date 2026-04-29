// ============================================================
//  client/cl_tosssmooth.qc  -  CSQC extrap + smoothing for any
//  airborne networked entity (dropped weapons, server projectiles).
//
//  Pattern mirrors the player extrap+smooth in cl_player.qc but
//  unrolled per-entity (no global ring buffer) so any number of
//  in-flight items can ride the same code path. Three calls drive it:
//
//    CSQC_TossSampleApply(ent, new_origin, new_velocity, gravity_factor)
//      Called from each entity's CSQC_Ent_Update on every server
//      sample. Diffs against the entity's current displayed origin
//      and stashes the visual error in extrap_error_offset for
//      decay. Then anchors the new authoritative sample.
//
//    CSQC_TossPredraw(ent)
//      Called from each entity's predraw. Extrapolates from the last
//      anchor using stored velocity + gravity, applies the decaying
//      error_offset, and setorigin's the result.
//
//    CSQC_TossSmoothReset(ent)
//      Called on first appearance / explicit teleport. Wipes the
//      smoothing error so the next predraw renders cleanly without
//      decaying a stale offset.
//
//  Required entity fields (declared in cl_customdefs.qc):
//    .toss_last_origin / .toss_last_velocity / .toss_last_cltime
//    .toss_gravity
//    .extrap_error_offset / .extrap_error_cltime  (reused from
//      the player smoothing path — same decay semantics)
// ============================================================

// Skip imperceptible noise, but allow much larger snaps to be smoothed
// than the player path does — a fast projectile (1500 qu/s rocket) at
// 20 Hz moves 75 qu per sample, so the player's 32 qu wipe threshold
// would treat every single snap as a teleport and bail out of smoothing
// entirely. Above MAXJUMP we still snap (real teleports / spawn).
const float TOSS_SMOOTH_MIN     = 0.5;
const float TOSS_SMOOTH_MAXJUMP = 128;
const float TOSS_MOVING_SPEED_SQ = 1;

// Cap extrapolation at TOSS_EXTRAP_MAX_TICKS multiples of the actual
// server send interval (1 / sv_toss_tickrate). MUST NOT use sv_mintic
// here — that's the engine physics tick (~1/64s), not the toss send
// rate, so at low sv_toss_tickrate the cap was shorter than the
// inter-sample window and the extrap froze just before each new
// sample arrived → user-visible micro-snaps even at high smooth_time.
const float TOSS_EXTRAP_MAX_TICKS = 3;

float toss_frame_cache_valid;
float toss_frame_cache_cltime;
float toss_frame_cache_dt_cap;
float toss_frame_cache_gravity;
float toss_frame_cache_smooth_time;

void() CSQC_TossFrameCacheRefresh =
{
    float tic;

    if (toss_frame_cache_valid && toss_frame_cache_cltime == cltime)
        return;

    toss_frame_cache_valid = TRUE;
    toss_frame_cache_cltime = cltime;

    tic = 1.0 / bound(5, serverkeyfloat("sv_toss_tickrate", 40), 100);
    toss_frame_cache_dt_cap = tic * TOSS_EXTRAP_MAX_TICKS;
    toss_frame_cache_gravity = serverkeyfloat("sv_gravity", 800);

    toss_frame_cache_smooth_time = cvar("cl_toss_smooth_time");
    if (toss_frame_cache_smooth_time < 0.001)
        toss_frame_cache_smooth_time = 0.001;
};

// Reset the smoothing state. Use on first appearance, post-teleport,
// or whenever the next predraw should render with no smoothing error
// from the previous flight path.
void(entity ent) CSQC_TossSmoothReset =
{
    ent.extrap_error_offset = '0 0 0';
    ent.extrap_error_cltime = 0;
};

// Compute the predicted current position from the previous sample.
// Used by both the apply (to compute the new error) and the predraw
// (to render). Pure function — no side effects on the entity.
vector(entity ent) Toss_PredictedNow =
{
    if (ent.toss_last_cltime <= 0)
        return ent.origin;

    CSQC_TossFrameCacheRefresh();

    float dt = cltime - ent.toss_last_cltime;
    if (dt < 0) dt = 0;

    // Cap dt against the actual toss send interval (NOT sv_mintic, which
    // is the engine physics tick — typically much shorter than the toss
    // send rate at low sv_toss_tickrate values). Multiply by
    // TOSS_EXTRAP_MAX_TICKS to allow some lateness tolerance for missed
    // samples without the extrap freezing mid-frame.
    if (dt > toss_frame_cache_dt_cap) dt = toss_frame_cache_dt_cap;

    vector ext = ent.toss_last_origin;
    if (!ent.toss_moving)
        return ext;

    ext = ext + ent.toss_last_velocity * dt;

    // Gravity is ONLY applied when the entity is actively moving. A
    // settled / map-placed weapon (movetype=NONE on the server, sending
    // velocity=0 every tick) would otherwise visibly drop by 0.5 * g *
    // dt² between samples and then snap back up on the next server
    // snapshot — the "weapons fall and jump back up" bug. The 1 qu/s
    // velocity floor also screens float noise on near-stopped items.
    ext_z -= 0.5 * toss_frame_cache_gravity * ent.toss_gravity * dt * dt;
    return ext;
};

// Stash a fresh server sample on the entity. Captures the current
// displayed-vs-predicted error first so the predraw can decay it back
// to zero over cl_extrap_smooth_time, hiding the snap visually.
//
// Caller does NOT need to setorigin — the predraw is the sole position
// authority once smoothing kicks in. (Setting origin here would just
// be overwritten next frame anyway.)
void(entity ent, vector new_origin, vector new_velocity, float gravity_factor)
CSQC_TossSampleApply =
{
    // Compute the position we WOULD have rendered this frame from the
    // previous anchor, then compare to the new authoritative origin.
    // The delta is the visual jump we want to hide.
    vector predicted = Toss_PredictedNow(ent);
    vector err = predicted - new_origin;
    float emag = vlen(err);

    if (emag > TOSS_SMOOTH_MIN && emag < TOSS_SMOOTH_MAXJUMP)
    {
        // Within the smoothing band — fold this error into the decay
        // pipeline. Add to any existing offset so successive small
        // corrections compound smoothly rather than each one resetting
        // the decay clock from a half-decayed state.
        ent.extrap_error_offset = err;
        ent.extrap_error_cltime = cltime;
    }
    else
    {
        // Either no meaningful change, or too large a jump (teleport,
        // explosion knockback, first-sample) — wipe so the predraw
        // renders the new origin cleanly.
        ent.extrap_error_offset = '0 0 0';
        ent.extrap_error_cltime = 0;
    }

    // Anchor the new authoritative sample. Predraw will extrapolate
    // from here until the next CSQC_TossSampleApply call.
    ent.toss_last_origin   = new_origin;
    ent.toss_last_velocity = new_velocity;
    ent.toss_last_cltime   = cltime;
    ent.toss_gravity       = gravity_factor;
    ent.toss_moving        = ((new_velocity * new_velocity) > TOSS_MOVING_SPEED_SQ);
};

// Per-frame predraw. Extrapolates from the last anchor + decays the
// visual error toward zero over cl_extrap_smooth_time. Final origin
// is committed via setorigin so engine link/render math sees it.
void(entity ent) CSQC_TossPredraw =
{
    vector ext = Toss_PredictedNow(ent);

    // Apply the smoothing error if there's one outstanding. Linear
    // decay over cl_extrap_smooth_time (same time constant the player
    // smoothing uses — 0.031s default; admins can bump it for slower
    // decay if items still feel snappy at high ping).
    if (ent.extrap_error_cltime > 0)
    {
        // Item-specific smoothing time — separate from the player extrap
        // so admins can tune one without affecting the other.
        CSQC_TossFrameCacheRefresh();
        float age = cltime - ent.extrap_error_cltime;
        float decay = 1.0 - (age / toss_frame_cache_smooth_time);
        if (decay > 0)
            ext = ext + ent.extrap_error_offset * decay;
        else
        {
            // Fully decayed — clear so we don't keep doing the math.
            ent.extrap_error_offset = '0 0 0';
            ent.extrap_error_cltime = 0;
        }
    }

    if (ext != ent.origin)
        setorigin(ent, ext);
};
