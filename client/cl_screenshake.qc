// ============================================================
//  client/cl_screenshake.qc  -  the receiving half of the shake channel
//
//  In GoldSrc this code is in the ENGINE, not the SDK: the client DLL only
//  forwards gmsgShake, and V_CalcShake / V_ApplyShake (called from
//  cl_dll/view.cpp:527-528) live behind gEngfuncs.  FTE has no equivalent, so
//  the state machine is reimplemented here against the documented GoldSrc
//  algorithm and driven from the same place every other view modifier is —
//  the modifier stack in CSQC_UpdateViewAliveCamera.
//
//  Shape of the effect, which is worth stating because it is not a plain
//  decaying sine:
//    * a fresh random offset is drawn every 1/frequency seconds, so frequency
//      controls how often the view is re-kicked, not the pitch of a wave;
//    * the envelope is (remaining/duration) SQUARED, times sin(time * freq'),
//      where freq' RISES as the shake decays — it rattles faster as it dies;
//    * amplitude itself also bleeds off every frame, less for high-frequency
//      shakes.
//  See server/sv_screenshake.qc for the sending half and the HL clamp.
// ============================================================

// Live shake state.  All zero means "no shake", which is the resting case for
// almost every frame of almost every map.
float  csqc_shake_amplitude;
float  csqc_shake_duration;
float  csqc_shake_frequency;
float  csqc_shake_endtime;       // cltime at which the shake is finished
float  csqc_shake_nextdraw;      // cltime of the next random re-kick
vector csqc_shake_offset;        // current random extents
float  csqc_shake_angle;         // current random roll extent
float  csqc_shake_lasttime;      // for our own frametime, independent of cadence

// What CSQC_ScreenShake_Calc computed this frame, consumed by the two Apply
// helpers below.  Separated exactly as V_CalcShake / V_ApplyShake are, because
// the shake is applied to more than one thing (view origin and roll) but must
// only be ADVANCED once per frame.
vector csqc_shake_applied_offset;
float  csqc_shake_applied_angle;

// ---------------------------------------------------------------------------
//  Message entry point — called from the CSQC_EVENT_SCREENSHAKE handler.
// ---------------------------------------------------------------------------
void(float amplitude, float duration, float frequency) CSQC_ScreenShake_Start =
{
    csqc_shake_amplitude = amplitude;
    csqc_shake_duration  = duration;
    csqc_shake_frequency = frequency;

    // max(duration, 0.01) — a zero-duration shake would divide by zero in the
    // envelope below, and GoldSrc guards it the same way.
    csqc_shake_endtime  = cltime + max(duration, 0.01);
    csqc_shake_nextdraw = 0;        // re-kick immediately on the next frame
    csqc_shake_lasttime = cltime;

    if (cvar("cl_debug_shake"))
        print(sprintf("[shake] amp %g dur %g freq %g\n",
                      amplitude, duration, frequency));
};

// ---------------------------------------------------------------------------
//  V_CalcShake — advance the state, once per render frame.
// ---------------------------------------------------------------------------
void() CSQC_ScreenShake_Calc =
{
    // `shake_ft`, not `frametime` — cl_defs.qc:281 declares a global of that
    // name and QC's single namespace makes the local shadow it.
    float shake_ft;
    float fraction;
    float freq;

    csqc_shake_applied_offset = '0 0 0';
    csqc_shake_applied_angle  = 0;

    if (cltime > csqc_shake_endtime || csqc_shake_duration <= 0
        || csqc_shake_amplitude <= 0 || csqc_shake_frequency <= 0)
        return;

    shake_ft = cltime - csqc_shake_lasttime;
    csqc_shake_lasttime = cltime;
    if (shake_ft <= 0)
        return;                  // paused / same-frame re-entry

    if (cltime > csqc_shake_nextdraw)
    {
        // Higher frequency = recompute the extents more often, i.e. perturb
        // the view again sooner.
        csqc_shake_nextdraw = cltime + (1 / csqc_shake_frequency);

        // crandom() is SSQC-only in this dialect; (random()*2 - 1) is the
        // same -1..1 draw and is what the client VM has to use.
        csqc_shake_offset_x = (random() * 2 - 1) * csqc_shake_amplitude;
        csqc_shake_offset_y = (random() * 2 - 1) * csqc_shake_amplitude;
        csqc_shake_offset_z = (random() * 2 - 1) * csqc_shake_amplitude;
        csqc_shake_angle    = (random() * 2 - 1) * csqc_shake_amplitude * 0.25;
    }

    // Linear ramp-down 1 -> 0 across the duration...
    fraction = (csqc_shake_endtime - cltime) / csqc_shake_duration;

    // ...which also RAISES the frequency as it decays, so a dying shake
    // rattles faster rather than just quieter.
    if (fraction)
        freq = csqc_shake_frequency / fraction;
    else
        freq = 0;

    // Squared so it approaches zero more quickly than linearly, then a sine so
    // the view passes back through centre instead of drifting to one side.
    fraction = fraction * fraction;
    fraction = fraction * sin(cltime * freq);

    csqc_shake_applied_offset = csqc_shake_offset * fraction;
    csqc_shake_applied_angle  = csqc_shake_angle * fraction;

    // Bleed the amplitude down, less for higher-frequency shakes.
    csqc_shake_amplitude = csqc_shake_amplitude
                         - (csqc_shake_amplitude
                            * (shake_ft / (csqc_shake_duration * csqc_shake_frequency)));
};

// ---------------------------------------------------------------------------
//  V_ApplyShake — modifier-stack helpers, matching cl_viewfx.qc's shape.
// ---------------------------------------------------------------------------
vector(vector base) CSQC_ApplyScreenShake =
{
    return base + csqc_shake_applied_offset;
};

// Roll only, as GoldSrc does — a shake that moved pitch or yaw would fight the
// player's aim, and V_ApplyShake touches angles[ROLL] alone.
vector(vector base) CSQC_ApplyScreenShakeAngles =
{
    base_z = base_z + csqc_shake_applied_angle;
    return base;
};
