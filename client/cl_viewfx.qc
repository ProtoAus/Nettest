// ============================================================
//  client/cl_viewfx.qc  -  CoD/Quake3-style camera & viewmodel feel
//
//  Four togglable effects layered on top of the rigid CS-style
//  baseline.  All four are pure presentation modifiers — they
//  read predicted_player / view_angles but never write back into
//  prediction state or input_angles, so bullets continue to fire
//  from the player's real aim direction (server-authoritative).
//
//      cl_camerabob       — cadence-based camera oscillation
//      cl_viewmodelbob    — same oscillation on the viewmodel
//      cl_viewmodelweight — spring-damped camera dip on landings
//      cl_viewmodelsway   — viewmodel angle/parallax lag on turns
//
//  State updates run once per CSQC_Input_Frame (controlled cadence,
//  immune to render-rate spikes).  Offsets are applied per render
//  frame from CSQC_UpdateViewAliveCamera (camera) and
//  CSQC_AddPredictedViewmodel (gun) via the modifier-stack pattern
//  established in cl_cameras.qc.
// ============================================================

// ---- Bob state ---------------------------------------------------
// Phase wraps in [0,1) and advances by distance walked, so the
// footstep cadence matches the player's actual ground speed at any
// movement rate and stops cleanly when motion stops.
float  csqc_viewfx_bob_phase;
// Walking↔airborne↔idle envelope.  Rate-limited toward target so
// leaving the ground (jump) doesn't snap the bob off.
float  csqc_viewfx_bob_envelope;

// ---- Landing-dip spring state (1D harmonic oscillator) ----------
// Position in units (negative = dipped down), velocity in u/s.
float  csqc_viewfx_weight_pos;
float  csqc_viewfx_weight_vel;
// Airborne→ground edge detector + last airborne vel.z for impact.
float  csqc_viewfx_prev_onground;
float  csqc_viewfx_prev_vel_z;

// ---- Sway state -------------------------------------------------
// Lag accumulated from view-angle deltas (pitch in _x, yaw in _y).
// Decays toward zero every tick, hard-clamped so a 180° flick can't
// peel the gun off the screen.
vector csqc_viewfx_sway_ang;
vector csqc_viewfx_prev_view_angles;

// ---- Sprint envelope --------------------------------------------
// Ramps 0→1 while the player is actually sprinting (sv_shiftspeed>1
// AND the shift button held AND moving on the ground AND not ducking).
// Drives multiple effects: the across-the-chest gun pose, the bob
// amplitude multipliers, etc.  Tracking it independently of any one
// cvar means turning on/off the pose doesn't affect the bob, and
// vice-versa.
float  csqc_viewfx_sprint_env;

// ADS envelope — ramps 0→1 while the player holds +attack2 with a
// weapon that supports ADS (HDAK47 in v1).  Sprint wins if both are
// active.  Mirrors the sprint-envelope easing.
float  csqc_viewfx_ads_env;

// Weapon-lower envelope — ramps 0→1 when the player is grappling
// (grapple_rope_active is set, hook is in flight or attached) or
// when sv_codladders is on AND the player is on a ladder.  Drops
// the viewmodel off-screen and gates firing via Weapon_LowerBlocksFire
// so the gun visually disappears while the player is doing something
// that shouldn't allow shooting.  Same exponential ease as sprint/ADS.
float  csqc_viewfx_lower_env;

// Last CSQC_ViewFX_UpdateState time, used to compute dt.
float  csqc_viewfx_last_update;

// Last cltime at which `onground` was observed TRUE.  Drives the
// "grace-grounded" hysteresis below — both the bob envelope and the
// sprint envelope read this so a single-frame FL_ONGROUND flicker on
// a clip-brush slope (where trace_plane_normal_z hovers right around
// PM_MIN_STEP_NORMAL = 0.7) doesn't stutter the gun pose.  The actual
// landing-edge detector (csqc_viewfx_prev_onground) intentionally
// stays on the un-smoothed signal — that one wants the real edge.
float  csqc_viewfx_last_onground_time;

// ============================================================
//  CSQC_ViewFX_UpdateState
//  Single per-input-frame tick.  Advances bob phase, fades the
//  envelope, integrates the landing spring, detects landings, and
//  integrates the sway filter.  Safe to call when no prediction
//  proxy exists — early-returns clean.
// ============================================================
void() CSQC_ViewFX_UpdateState =
{
    if (!predicted_player || !csqc_prediction_valid)
        return;

    float now = cltime;
    float dt = now - csqc_viewfx_last_update;
    csqc_viewfx_last_update = now;
    // Clamp dt: first-call (huge), pause-resume (huge), or weird
    // sub-millisecond ticks (would underflow the linear decay below).
    if (dt < 0.0001) dt = 0.0001;
    if (dt > 0.1)    dt = 0.1;

    vector vel = predicted_player.velocity;
    float onground = (predicted_player.flags & FL_ONGROUND) != 0;
    vector hvel = vel;
    hvel_z = 0;
    float hspeed = vlen(hvel);

    // ---- Grace-grounded hysteresis ----
    // Refresh the timestamp every tick we see real ground, then treat
    // ourselves as grounded for cl_viewfx_ground_grace seconds after the
    // last real ground observation.  Hides single-frame FL_ONGROUND
    // flicker that PM_CategorizePosition produces on clip-brush slopes
    // sitting right at the PM_MIN_STEP_NORMAL boundary.
    if (onground)
        csqc_viewfx_last_onground_time = now;
    float ground_grace = cvar("cl_viewfx_ground_grace");
    if (ground_grace <= 0) ground_grace = 0.1;
    float grace_grounded = onground
        || (now - csqc_viewfx_last_onground_time) < ground_grace;

    // ---- Bob envelope ----
    // Below ~25 u/s the player is effectively stationary (occurs while
    // a deceleration tail is still bleeding off after the player lets
    // go of move keys); treat as not-walking so the bob fades out.
    float speed_ref = cvar("cl_camerabob_speed_ref");
    if (speed_ref < 1) speed_ref = 250;
    float target = 0;
    if (grace_grounded && hspeed > 25)
        target = bound(0, hspeed / speed_ref, 1.2);
    float fade_t = cvar("cl_camerabob_fade_time");
    if (fade_t < 0.001) fade_t = 0.001;
    float step = dt / fade_t;
    csqc_viewfx_bob_envelope += bound(-step,
                                       target - csqc_viewfx_bob_envelope,
                                       step);

    // ---- Bob phase ----
    float cycle = cvar("cl_camerabob_cycle");
    if (cycle < 1) cycle = 1;
    csqc_viewfx_bob_phase += (hspeed * dt) / cycle;
    csqc_viewfx_bob_phase -= floor(csqc_viewfx_bob_phase);

    // ---- Landing detection (airborne→ground edge, threshold-gated) ----
    if (onground && !csqc_viewfx_prev_onground)
    {
        float impact = 0 - csqc_viewfx_prev_vel_z;  // positive = falling speed
        float thr = cvar("cl_viewmodelweight_threshold");
        if (impact > thr)
        {
            float dip_scale = cvar("cl_viewmodelweight_scale");
            float dip_max = cvar("cl_viewmodelweight_max");
            // Inject downward velocity into the spring; spring then
            // dips and recovers.  The 60×/8× constants tune scale so
            // sensible cvar defaults produce a visible-but-not-jarring
            // dip without making the cvars use tiny fractional values.
            float kick = (impact - thr) * dip_scale * 60;
            float kick_cap = dip_max * 8;
            if (kick > kick_cap) kick = kick_cap;
            csqc_viewfx_weight_vel -= kick;
        }
    }
    if (!onground)
        csqc_viewfx_prev_vel_z = vel_z;
    csqc_viewfx_prev_onground = onground;

    // ---- Spring integration (semi-implicit Euler) ----
    float k = cvar("cl_viewmodelweight_stiffness");
    float c = cvar("cl_viewmodelweight_damp");
    csqc_viewfx_weight_vel += (0 - k * csqc_viewfx_weight_pos
                                 - c * csqc_viewfx_weight_vel) * dt;
    csqc_viewfx_weight_pos += csqc_viewfx_weight_vel * dt;
    float wmax = cvar("cl_viewmodelweight_max");
    csqc_viewfx_weight_pos = bound(0 - wmax, csqc_viewfx_weight_pos, wmax);

    // ---- Sway: angular-velocity-driven lag with linear decay ----
    vector ang_delta = view_angles - csqc_viewfx_prev_view_angles;
    // Normalise yaw wrap so a 359°→1° crossing doesn't read as +358°.
    while (ang_delta_y >  180) ang_delta_y -= 360;
    while (ang_delta_y < -180) ang_delta_y += 360;
    while (ang_delta_x >  180) ang_delta_x -= 360;
    while (ang_delta_x < -180) ang_delta_x += 360;
    csqc_viewfx_prev_view_angles = view_angles;

    csqc_viewfx_sway_ang_x += ang_delta_x * cvar("cl_viewmodelsway_pitch_scale");
    csqc_viewfx_sway_ang_y += ang_delta_y * cvar("cl_viewmodelsway_yaw_scale");
    // Linear decay (1 - r*dt clamped to [0,1]) — avoids depending on
    // exp().  At recover=9 Hz, dt=16ms → multiplier 0.856 per frame
    // ≈ -98 dB/s, ≈ 0.11s to fall to 10%.  Matches CoD-style snap-back.
    float recover = cvar("cl_viewmodelsway_recover");
    float decay = 1.0 - bound(0, recover * dt, 1.0);
    csqc_viewfx_sway_ang_x *= decay;
    csqc_viewfx_sway_ang_y *= decay;

    float my = cvar("cl_viewmodelsway_max_yaw");
    float mp = cvar("cl_viewmodelsway_max_pitch");
    csqc_viewfx_sway_ang_x = bound(0 - mp, csqc_viewfx_sway_ang_x, mp);
    csqc_viewfx_sway_ang_y = bound(0 - my, csqc_viewfx_sway_ang_y, my);

    // ---- Sprint envelope ----
    // Sprint = multiplier mode (sv_shiftspeed > 1) AND the shift button
    // is held AND the player is moving forward on the ground.  Ducking
    // cancels.  Forward-only matches the PM_PlayerMoveStep gate that
    // requires input_movevalues_x > 0 for the speed boost — strafing or
    // backing up cancels both the multiplier and the visual pose, so
    // the two stay in lockstep.
    float sprint_target = 0;
    // sv_codstamina punish — when the player has burned through the
    // stamina pool while sprinting, the multiplier is gated off in
    // PM_PlayerMoveStep AND the visual sprint pose should also
    // disengage so the gun rises back up (the user's "raise weapon
    // until refilled" requirement).  predicted_player.codstamina_punished
    // is server-authoritative; reads through the same field both sides
    // run.
    float stamina_block = PM_ReadMovevar("sv_codstamina", 0) > 0
                       && predicted_player.codstamina_punished;
    if ((csqc_live_buttons & PM_BTN_SPRINT)
        && cvar("sv_shiftspeed") > 1.001
        && input_movevalues_x > 0
        && grace_grounded && hspeed > 25
        && !(predicted_player.flags & FL_DUCKING)
        && !stamina_block)
    {
        sprint_target = 1;
    }
    // Exponential smoothing toward the target: each tick moves a
    // fraction of the remaining gap, so the envelope starts fast
    // (large gap → big step) and arrives softly (small gap → tiny
    // step).  Naturally symmetric for engage AND disengage — both
    // ease out into their target — which is the "starts quick, slows
    // into place" curve a linear ramp can't produce.
    //
    // Rate constant 4 sets cl_viewmodellowering_sprint_fade as the
    // approximate time to reach ~98 % of the target (1 − e^-4 ≈ 0.98);
    // the 0.005 snap kills the asymptotic tail so the pose code
    // doesn't keep doing micro-work once the gun has visibly settled.
    float sprint_fade = cvar("cl_viewmodellowering_sprint_fade");
    if (sprint_fade < 0.001) sprint_fade = 0.15;
    float sprint_k = bound(0, (4.0 * dt) / sprint_fade, 1.0);
    csqc_viewfx_sprint_env += (sprint_target - csqc_viewfx_sprint_env)
                              * sprint_k;
    float sprint_gap = sprint_target - csqc_viewfx_sprint_env;
    if (sprint_gap < 0.005 && sprint_gap > 0 - 0.005)
        csqc_viewfx_sprint_env = sprint_target;
    csqc_viewfx_sprint_env = bound(0, csqc_viewfx_sprint_env, 1);

    // ---- ADS envelope ----
    // Hold +attack2 with the HDAK47 to ramp the gun up to the face.
    // Sprint cancels via sprint_target (the LIVE input/state check),
    // not the envelope.  Using the envelope here would force the gun
    // through idle pose on the sprint→ADS handoff: ADS couldn't start
    // until sprint_env fully decayed.  Reading sprint_target instead
    // means the moment the player releases +button4 (or any other
    // sprint condition fails), the ADS gate opens immediately, ads_env
    // starts rising while sprint_env is still decaying, and the two
    // envelopes evolve in parallel — the visible pose interpolates
    // directly from sprint to ADS without dropping to rest.  Same
    // exponential ease the sprint envelope uses — "fast start, slow
    // settle" — but with its own fade cvar.  Crouching is allowed
    // (CoD-style: hold-aim works whether standing or ducked).
    float ads_target = 0;
    if (predicted_player
        && (csqc_live_buttons & 4)            // +attack2 bit
        && !sprint_target)
    {
        // Bar ADS while reloading on every ADS weapon — gun is busy
        // racking / inserting shells, can't be brought up to the eye.
        // Mirrors the grapple / lower-envelope cancellation pattern.
        if (predicted_player.weaponstate != WS_RELOAD
         && (predicted_player.weapon == WEP_HDAK47
          || predicted_player.weapon == WEP_AK47
          || predicted_player.weapon == WEP_DEAGLE
          || predicted_player.weapon == WEP_CFMAC10
          || predicted_player.weapon == WEP_CFFAMAS
          || predicted_player.weapon == WEP_CFFIVESEVEN
          || predicted_player.weapon == WEP_CFDEAGLE
          || predicted_player.weapon == WEP_CFELITE
          || predicted_player.weapon == WEP_CFGALIL
          || predicted_player.weapon == WEP_CFGLOCK
          || predicted_player.weapon == WEP_CFXM1014
          || predicted_player.weapon == WEP_CFM3
          || predicted_player.weapon == WEP_CFMP5
          || predicted_player.weapon == WEP_CFVECTOR
          || predicted_player.weapon == WEP_CFTYPE89))
            ads_target = 1;
        // sv_codscopes adds scout / awp to the ADS-eligible set so
        // the CoD scope state machine in cl_codscope.qc can ride the
        // existing envelope for the gun-raise portion of the sequence.
        // The grapple / codladder lower envelope also vetoes — same as
        // the existing HDAK ADS — so the gun-down hard cancels scope.
        // csqc_codscope_fire_blocks_ads is set in cl_codscope.qc when
        // a shot fires and stays TRUE until the player releases
        // +attack2 — that's what gives the "fire physically drops the
        // gun even with +attack2 still held" behaviour the user asked
        // for.
        if ((predicted_player.weapon == WEP_SCOUT
          || predicted_player.weapon == WEP_CSAWP
          || predicted_player.weapon == WEP_CFAWP
          || predicted_player.weapon == WEP_CFG3SG1
          || predicted_player.weapon == WEP_CFSCOUTM700
          || predicted_player.weapon == WEP_CFSG550
          || predicted_player.weapon == WEP_CFAUG)
            && PM_ReadMovevar("sv_codscopes", 0)
            && predicted_player.weaponstate != WS_RELOAD
            && !predicted_player.grapple_rope_active
            && !(PM_ReadMovevar("sv_codladders", 0)
                 && predicted_player.pm_on_ladder_cached)
            && !csqc_codscope_fire_blocks_ads)
            ads_target = 1;
    }
    float ads_fade = cvar("cl_ads_fade");
    if (ads_fade < 0.001) ads_fade = 0.18;
    float ads_k = bound(0, (4.0 * dt) / ads_fade, 1.0);
    csqc_viewfx_ads_env += (ads_target - csqc_viewfx_ads_env) * ads_k;
    float ads_gap = ads_target - csqc_viewfx_ads_env;
    if (ads_gap < 0.005 && ads_gap > 0 - 0.005)
        csqc_viewfx_ads_env = ads_target;
    csqc_viewfx_ads_env = bound(0, csqc_viewfx_ads_env, 1);

    // ---- Weapon-lower envelope ----
    // Drives the off-screen viewmodel pose for grapple + (optional)
    // ladder.  Source signals are both predicted_player-resident:
    //   - grapple_rope_active is replicated through the prediction
    //     proxy (sh_customdefs.qc) and survives reconcile, so it
    //     reads cleanly here regardless of pmove timing.
    //   - pm_on_ladder_cached is latched on predicted_player at the
    //     end of PM_PlayerMoveStep (sh_pmove.qc) so we don't have
    //     to sample the transient pm_on_ladder global ourselves.
    // PM_ReadMovevar makes sv_codladders work both on listen servers
    // (read local cvar) and remote servers (read serverkeyfloat).
    float lower_target = 0;
    if (predicted_player.grapple_rope_active)
        lower_target = 1;
    else if (PM_ReadMovevar("sv_codladders", 0)
             && predicted_player.pm_on_ladder_cached)
        lower_target = 1;
    float lower_fade = cvar("cl_viewmodel_lower_fade");
    if (lower_fade < 0.001) lower_fade = 0.20;
    float lower_k = bound(0, (4.0 * dt) / lower_fade, 1.0);
    csqc_viewfx_lower_env += (lower_target - csqc_viewfx_lower_env) * lower_k;
    float lower_gap = lower_target - csqc_viewfx_lower_env;
    if (lower_gap < 0.005 && lower_gap > 0 - 0.005)
        csqc_viewfx_lower_env = lower_target;
    csqc_viewfx_lower_env = bound(0, csqc_viewfx_lower_env, 1);
};

// ============================================================
//  CSQC_ApplyCameraBob — modifier-stack helper (origin)
//  Vertical bobs at 2× cadence (both footsteps push down), lateral
//  bobs at 1× cadence (alternates per step).  Crouch halves amp.
// ============================================================
vector(vector base) CSQC_ApplyCameraBob =
{
    if (!cvar("cl_camerabob"))
        return base;
    if (!predicted_player)
        return base;
    float env = csqc_viewfx_bob_envelope;
    if (env <= 0.001)
        return base;
    if (predicted_player.flags & FL_DUCKING)
        env *= 0.5;

    // Sprint-time amplitude boost: lerp 1.0 → cl_camerabob_sprint_mult
    // with the sprint envelope (already exponentially eased in
    // CSQC_ViewFX_UpdateState — quick start, soft settle) so the
    // cadence steps grow and shrink with the same curve as the pose.
    float sprint_mult = 1.0 + (cvar("cl_camerabob_sprint_mult") - 1.0)
                              * csqc_viewfx_sprint_env;
    env *= sprint_mult;

    float two_pi = 6.2831853;
    float phase = csqc_viewfx_bob_phase * two_pi;

    float vert = sin(phase * 2) * cvar("cl_camerabob_amp_z") * env;
    float lat  = sin(phase)     * cvar("cl_camerabob_amp_x") * env;

    // camang is the global the caller will hand to setproperty(VF_ANGLES).
    // makevectors clobbers v_right/v_forward/v_up — fine to reuse here
    // because the rest of the modifier chain (sniper sway, kick) only
    // touches camang, not the v_* basis.
    makevectors(camang);
    vector out = base;
    out_z += vert;
    out += v_right * lat;
    return out;
};

// ============================================================
//  CSQC_ApplyCameraWeight — modifier-stack helper (origin)
//  Adds the spring-decayed landing dip Z offset.  Independent of
//  bob so the user can run weight without bob (or vice versa).
// ============================================================
vector(vector base) CSQC_ApplyCameraWeight =
{
    if (!cvar("cl_viewmodelweight"))
        return base;
    vector out = base;
    out_z += csqc_viewfx_weight_pos * cvar("cl_viewmodelweight_cam_scale");
    return out;
};

// ============================================================
//  CSQC_ApplyViewmodelOffsets — mutates the viewmodel entity
//  Origin/angles are interpreted by the engine as camera-relative
//  offsets (R_RotateForEntity multiplies by weaponmatrix), so the
//  basis is: +x forward, +y right, +z up relative to the camera.
//  See engine/gl/gl_rmain.c:263-335 for the matrix multiply.
// ============================================================
// Scratch globals populated by CSQC_ViewFX_ComputeOffsets — every
// call to ComputeOffsets fully overwrites them, no carry-over.  Two
// downstream consumers read these:
//   - CSQC_ApplyViewmodelOffsets writes them onto the viewmodel entity
//     at render time (preserves the original behaviour).
//   - CSQC_ViewFX_PoseViewmodelForBoneLookup composes them into world
//     space and sets the entity for gettaginfo, so muzzle-flash and
//     tracer-start sample the bone at its VISIBLE world position
//     instead of the pose-less baseline.
vector csqc_viewfx_pose_pos;
vector csqc_viewfx_pose_ang;

// ----------------------------------------------------------------
//  CSQC_ViewFX_ComputeOffsets  —  pure math, no entity I/O (except
//  the inner sway-pivot bone lookup which save/restores cleanly).
//  Writes the result to csqc_viewfx_pose_pos / _ang.
// ----------------------------------------------------------------
void(entity gun) CSQC_ViewFX_ComputeOffsets =
{
    vector pos = '0 0 0';
    vector ang = '0 0 0';

    // ---- Bob: synchronised phase with the camera, more visible ----
    if (cvar("cl_viewmodelbob") && csqc_viewfx_bob_envelope > 0.001)
    {
        float env = csqc_viewfx_bob_envelope;
        if (predicted_player && (predicted_player.flags & FL_DUCKING))
            env *= 0.5;
        // Match the camera bob's sprint amplitude lerp so both
        // surfaces grow their footstep step together.  Same eased
        // envelope so the multiplier transitions match the pose.
        float bob_sprint_mult = 1.0
            + (cvar("cl_viewmodelbob_sprint_mult") - 1.0)
            * csqc_viewfx_sprint_env;
        env *= bob_sprint_mult;
        float two_pi = 6.2831853;
        float phase = csqc_viewfx_bob_phase * two_pi;
        float ps = cvar("cl_viewmodelbob_pos_scale");
        float as = cvar("cl_viewmodelbob_ang_scale");
        pos_x += sin(phase * 2) *  0.4 * env * ps;
        pos_y += sin(phase)     *  1.2 * env * ps;
        pos_z += sin(phase * 2) * -0.6 * env * ps;
        ang_z += sin(phase)     *  1.2 * env * as;
        ang_x += sin(phase * 2) *  0.6 * env * as;
    }

    // ---- Weight: gun follows the camera dip, scaled independently ----
    if (cvar("cl_viewmodelweight"))
        pos_z += csqc_viewfx_weight_pos * cvar("cl_viewmodelweight_gun_scale");

    // ---- Sway: gun trails behind camera angular changes ----
    if (cvar("cl_viewmodelsway"))
    {
        // Negative sign: the gun lags, so it pitches opposite to the
        // mouse motion briefly, then returns to neutral.
        ang_x -= csqc_viewfx_sway_ang_x;
        ang_y -= csqc_viewfx_sway_ang_y;

        // Pivot mode: when the current viewmodel has a muzzle tag,
        // compensate origin so the rotation pivots around the muzzle
        // instead of the entity origin (CoD-style — butt swings, muzzle
        // stays roughly fixed).  Models without a tag fall through to
        // the translation parallax below.
        float pivot_done = 0;
        if (cvar("cl_viewmodelsway_pivot")
            && predicted_player.weapon_muzzle_bone != ""
            && gun.modelindex)
        {
            // gettaginfo needs the entity in a clean baseline pose so
            // its result is in the model-local Quake basis (which is
            // the same basis CSQC_AddPredictedViewmodel uses for these
            // origin/angles writes — see the comment at the top of
            // this function).  Save / restore as cl_muzzleflash.qc does.
            vector saved_origin = gun.origin;
            vector saved_angles = gun.angles;
            setorigin(gun, '0 0 0');
            gun.angles = '0 0 0';
            float bidx = gettagindex(gun,
                predicted_player.weapon_muzzle_bone);
            if (bidx > 0)
            {
                vector bone_pos = gettaginfo(gun, bidx);
                // gettaginfo also set v_forward/v_right/v_up to the
                // bone's axes — apply the HL-studio offset in that
                // frame (negating Y to convert HL +Y-left to Quake
                // +Y-right, matching cl_muzzleflash.qc:336).  Result
                // is in the Quake WORLD basis (+X east, +Y north,
                // +Z up) because the entity was placed at the world
                // origin with identity angles for the lookup.
                vector mo = predicted_player.weapon_muzzle_offset;
                vector B_world = bone_pos
                              + v_forward * mo_x
                              + v_right   * (0 - mo_y)
                              + v_up      * mo_z;
                // Convert world → entity-local (camera-relative +Y
                // right): Quake's R_e2w(0) maps (x, y, z)_local to
                // (x, -y, z)_world, so the inverse just negates Y.
                vector b_local;
                b_local_x = B_world_x;
                b_local_y = 0 - B_world_y;
                b_local_z = B_world_z;
                // Compute the bone's WORLD position after the entity
                // rotates by the sway angles.  R_e2w(A)·b_local =
                // b_local.x·v_forward + b_local.y·v_right +
                // b_local.z·v_up — this is the entity-local→world
                // mapping and gives identity at A=0 (Quake's v_right
                // is (0,-1,0) at rest, which exactly undoes the Y
                // negation above).
                vector sway_a = '0 0 0';
                sway_a_x = 0 - csqc_viewfx_sway_ang_x;
                sway_a_y = 0 - csqc_viewfx_sway_ang_y;
                makevectors(sway_a);
                vector w_after = v_forward * b_local_x
                               + v_right   * b_local_y
                               + v_up      * b_local_z;
                // Compensation in world coords, then convert back to
                // camera-relative for pos (negate Y again).  RF_XFLIP
                // commutes with this offset so it's correct for both
                // flipped and unflipped weapons.
                vector dW = B_world - w_after;
                pos_x += dW_x;
                pos_y += 0 - dW_y;
                pos_z += dW_z;
                pivot_done = 1;
            }
            setorigin(gun, saved_origin);
            gun.angles = saved_angles;
        }

        if (!pivot_done)
        {
            // Fallback: translation parallax for bone-less models (or
            // when pivot mode is off).  This is the original sway
            // behaviour — a small translate in the lag direction.
            float lps = cvar("cl_viewmodelsway_pos_scale");
            pos_y -= csqc_viewfx_sway_ang_y * lps * 0.1;
            pos_z -= csqc_viewfx_sway_ang_x * lps * 0.1;
        }
    }

    // ---- Speed-driven lowering: gun dips with the walk/run envelope ----
    if (cvar("cl_viewmodellowering") && csqc_viewfx_bob_envelope > 0.001)
    {
        float lower = cvar("cl_viewmodellowering_amount");
        pos_z -= csqc_viewfx_bob_envelope * lower;
    }

    // ---- Sprint pose: across-the-chest gun rotation while sprinting ----
    if (cvar("cl_viewmodellowering_sprint")
        && csqc_viewfx_sprint_env > 0.001)
    {
        float se = csqc_viewfx_sprint_env;
        // RF_XFLIP is applied at render time when
        // (predicted_player.weapon_viewmodel_flip XOR cl_lefthand) is
        // true (see CSQC_AddPredictedViewmodel).  The engine mirrors the
        // model across the camera's right axis, which visually inverts
        // yaw, roll, and lateral position — so the pose has to invert
        // those inputs too for "rotate inward" and "shift right" to
        // remain visually correct regardless of the per-weapon flip
        // flag (some authored meshes are left-handed and use
        // weapon_viewmodel_flip = TRUE to read as right-handed).
        float vm_flip = predicted_player.weapon_viewmodel_flip;
        if (cvar("cl_lefthand"))
            vm_flip = !vm_flip;
        float side = vm_flip ? -1 : 1;
        ang_x += cvar("cl_viewmodellowering_sprint_pitch")   * se;
        ang_y += cvar("cl_viewmodellowering_sprint_yaw")     * se * side;
        ang_z += cvar("cl_viewmodellowering_sprint_roll")    * se * side;
        pos_x -= cvar("cl_viewmodellowering_sprint_forward") * se;
        pos_y += cvar("cl_viewmodellowering_sprint_right")   * se * side;
        pos_z -= cvar("cl_viewmodellowering_sprint_down")    * se;
    }

    // ---- ADS pose: hold +attack2 to bring the gun up to the face ----
    // Layered after the sprint pose so when both transitions are
    // mid-decay (e.g., player just released sprint and started ADS)
    // both contribute proportionally to their envelopes.  Same flip
    // handling as the sprint pose — RF_XFLIP inverts yaw/roll/right
    // visually, so we sign-flip those when the model uses XFLIP.
    if (csqc_viewfx_ads_env > 0.001)
    {
        float ae = csqc_viewfx_ads_env;
        float ads_vm_flip = predicted_player.weapon_viewmodel_flip;
        if (cvar("cl_lefthand"))
            ads_vm_flip = !ads_vm_flip;
        float ads_side = ads_vm_flip ? -1 : 1;

        // Single shared ADS pose for every weapon — tuned via the
        // global cl_ads_* set (cl_ads_pitch / _yaw / _roll / _forward
        // / _right / _down).  The former per-weapon prefixes
        // (cl_ads_deagle_*, cl_ads_mac10_*, …) were removed in favour
        // of one shared pose for all guns.
        string ads_pfx = "cl_ads";

        ang_x += cvar(strcat(ads_pfx, "_pitch"))   * ae;
        ang_y += cvar(strcat(ads_pfx, "_yaw"))     * ae * ads_side;
        ang_z += cvar(strcat(ads_pfx, "_roll"))    * ae * ads_side;
        pos_x += cvar(strcat(ads_pfx, "_forward")) * ae;
        pos_y += cvar(strcat(ads_pfx, "_right"))   * ae * ads_side;
        pos_z += cvar(strcat(ads_pfx, "_down"))    * ae;
    }

    // ---- Weapon-lower pose: shove the gun off-screen ----
    // Layered LAST so when grapple fires (or the player mounts a
    // ladder with sv_codladders 1) the gun visibly drops out of view
    // regardless of any sprint / ADS pose that was active when the
    // transition started — both decay to zero while the lower
    // envelope rises, but until they do the lower offsets dominate.
    // Default cl_viewmodel_lower_down ≈ -30 drops the gun a player-
    // height unit below the camera, which is enough to clear most
    // viewmodel meshes from the screen at FOV 90; tune via the cvars
    // in shared/sh_cvar_table.qc.  Same XFLIP / cl_lefthand sign
    // handling as the sprint and ADS poses — yaw / roll / right
    // invert when the active model uses RF_XFLIP.
    if (csqc_viewfx_lower_env > 0.001)
    {
        float le = csqc_viewfx_lower_env;
        float lower_vm_flip = predicted_player.weapon_viewmodel_flip;
        if (cvar("cl_lefthand"))
            lower_vm_flip = !lower_vm_flip;
        float lower_side = lower_vm_flip ? -1 : 1;
        ang_x += cvar("cl_viewmodel_lower_pitch")   * le;
        ang_y += cvar("cl_viewmodel_lower_yaw")     * le * lower_side;
        ang_z += cvar("cl_viewmodel_lower_roll")    * le * lower_side;
        pos_x += cvar("cl_viewmodel_lower_forward") * le;
        pos_y += cvar("cl_viewmodel_lower_right")   * le * lower_side;
        pos_z += cvar("cl_viewmodel_lower_down")    * le;
    }

    csqc_viewfx_pose_pos = pos;
    csqc_viewfx_pose_ang = ang;
};

// ----------------------------------------------------------------
//  CSQC_ApplyViewmodelOffsets  —  preserved entry point for the
//  per-frame render path in cl_weapons.qc.  Thin wrapper over
//  ComputeOffsets.
// ----------------------------------------------------------------
void(entity gun) CSQC_ApplyViewmodelOffsets =
{
    CSQC_ViewFX_ComputeOffsets(gun);
    gun.origin = csqc_viewfx_pose_pos;
    gun.angles = csqc_viewfx_pose_ang;
};

// ----------------------------------------------------------------
//  CSQC_ViewFX_PoseViewmodelForBoneLookup  —  composes the camera
//  baseline (view_pos / view_ang) with the live view-feel offsets
//  (csqc_viewfx_pose_*) and writes the result onto csqc_viewmodel_ent,
//  so a subsequent gettaginfo returns the bone at its rendered world
//  position.  Used by CSQC_ViewmodelAttachmentWorldPos in
//  cl_muzzleflash.qc — fire-time muzzle/tracer sampling.
//
//  Without this composition the bone was sampled with .origin/.angles
//  at the bare camera pose, so all the CoD-style offsets (bob, sway
//  pivot, weight dip, sprint pose, ADS) got skipped — flash and tracer
//  spawned where the bone WOULD be on a pose-less viewmodel.
//
//  The translation has to ride along the camera's basis: the
//  offset vector is in viewmodel-relative space (+x forward, +y right,
//  +z up; v_right in Quake is -world_y, hence the Y negation — same
//  convention the sway-pivot math here already uses).
// ----------------------------------------------------------------
void(vector view_pos, vector view_ang) CSQC_ViewFX_PoseViewmodelForBoneLookup =
{
    CSQC_ViewFX_ComputeOffsets(csqc_viewmodel_ent);
    makevectors(view_ang);
    vector off = csqc_viewfx_pose_pos;
    vector world_off = v_forward * off_x
                     + v_right   * (0 - off_y)
                     + v_up      * off_z;
    setorigin(csqc_viewmodel_ent, view_pos + world_off);
    csqc_viewmodel_ent.angles = view_ang + csqc_viewfx_pose_ang;
};
