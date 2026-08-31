// ============================================================
//  client/cl_codscope.qc  -  COD-style ADS-scope sequence
//
//  Toggled by sv_codscopes.  When ON, +attack2 on CSScout / CSAWP
//  runs a state-machine'd ADS-scope sequence instead of the CS 1.6
//  3-stage zoom toggle:
//
//      OFF
//       ↓ press +attack2 (scout or awp), no grapple/ladder/sprint
//      RAISING        — ADS envelope rises fast (cl_ads_fade)
//       ↓ ads_env > cl_codscope_ads_threshold  [COMMIT POINT]
//      FADING_IN      — drawfill black goes 0→1 quickly  (one-way)
//       ↓ fade reached 1
//      SCOPED         — fade 1→0 + overlay rises (ease-out)
//                       FOV switches to ZOOM_FOV_STAGE2 (12°)
//                       fog bias bumped by sv_fog_scope_bias_delta
//                       breathing sway applied to camera
//                       step / land sway applied to overlay
//       ↓ release / fire / sprint / weapon switch / grapple etc.
//      FADING_OUT     — fade 0→1 + overlay drops (ease-in)   (one-way)
//       ↓ fade reached 1
//      FALLING        — fade 1→0, ADS envelope decays back to 0
//       ↓ fade clears and ADS drops below 0.05
//      OFF
//
//  Anti-spam: once FADING_IN starts the state machine is committed
//  to reaching SCOPED — releasing the button mid-fade does NOT
//  return to RAISING / FALLING.  Same for FADING_OUT toward FALLING.
//  This prevents the "press / release rapidly to stay ADS-visible
//  while the scope animates closed" exploit.
//
//  Fire cancel: any increment of predicted_player.wep_action_id
//  while we're in {RAISING, FADING_IN, SCOPED} jumps to FADING_OUT
//  so the gun visibly drops out of scope after every shot.
//
//  Sprint cancel: +button4 with sv_shiftspeed > 1 while moving
//  forward on the ground forces FADING_OUT (matches the existing
//  ADS sprint cancel rule).
//
//  This file is included by cl_progs.src only — no SSQC compile.
// ============================================================

// State machine phases — exposed to other modules so HUD / FOV /
// crosshair gates can switch on "are we scoping right now".
const float CODSCOPE_PHASE_OFF        = 0;
const float CODSCOPE_PHASE_RAISING    = 1;
const float CODSCOPE_PHASE_FADING_IN  = 2;
const float CODSCOPE_PHASE_SCOPED     = 3;
const float CODSCOPE_PHASE_FADING_OUT = 4;
const float CODSCOPE_PHASE_FALLING    = 5;

float csqc_codscope_phase;
float csqc_codscope_phase_start;   // cltime when current phase began
float csqc_codscope_fade;          // 0..1 black-fade alpha (drawfill)
float csqc_codscope_overlay_env;   // 0..1 scope overlay reveal envelope
float csqc_codscope_overlay_env_out_start; // env value captured at FADING_OUT entry, for ease-in OUT animation
float csqc_codscope_fog_active;    // 1 = we issued the bias-delta fog, 0 = base

// Overlay vertical sway components (per-frame from UpdateState).
// dy applied at draw time = base from phase + step + land kicks.
float csqc_codscope_overlay_step_y;
float csqc_codscope_overlay_land_y;
float csqc_codscope_overlay_land_vel;   // simple spring velocity for landing dip

// Hold-breath envelope (eased multiplier on breathing amplitude).
//   1.0  = free breath  (full sway)
//   <1   = breath held  (target ≈ cl_codscope_sway_holdbreath_mult)
float csqc_codscope_holdbreath_env;
float csqc_codscope_holdbreath_active;  // edge latch: 1 if we already played breathin and are awaiting release

// Punish-scale sway envelope.  Onsets fast when codstamina_punished
// latches AND the player is scoped, ramps DOWN as stamina refills
// (target tied to (1 - codstamina/0.5) so by the time stamina = 0.5
// — when codstamina_punished clears — the env is already at 0).
// Multiplied into the final sway pitch / yaw so the camera AND the
// predicted trace bias both pick it up; otherwise the bullet would
// land at the un-amplified crosshair.
float csqc_codscope_punish_env;

// Fire un-ADS suppression — set when a shot fires while scoped, kept
// TRUE until the player releases +attack2.  Read by the ADS-envelope
// target in cl_viewfx.qc so the gun drops out of ADS even though the
// button is still held, matching the sprint cancel UX ("fire → gun
// physically drops, must re-press to re-ADS").
float csqc_codscope_fire_blocks_ads;

// Total sway pitch / yaw deltas (degrees) — classic sinusoidal sway
// PLUS slow breathing layer.  Computed once per CSQC_Input_Frame in
// UpdateState so the camera (cl_cameras.qc CSQC_ApplySniperSway) AND
// the predicted/authoritative trace see the same value.  Without this
// the bullet would land at the un-swayed crosshair while the camera
// rendered a swayed view — the user reported this needed fixing.
float csqc_codscope_sway_pitch;
float csqc_codscope_sway_yaw;

// Edge-detection state
float csqc_codscope_prev_action_id;
float csqc_codscope_prev_sprint_btn;
float csqc_codscope_prev_onground;
float csqc_codscope_prev_vel_z;
float csqc_codscope_last_update_time;
float csqc_codscope_prev_punished;          // edge for outofbreath.wav
float csqc_codscope_next_heartbeat_time;    // cltime of next heartbeat play

// ----------------------------------------------------------------
//  CSQC_CodScope_Reset — called on disconnect / map change.
// ----------------------------------------------------------------
void() CSQC_CodScope_Reset =
{
    csqc_codscope_phase = CODSCOPE_PHASE_OFF;
    csqc_codscope_phase_start = 0;
    csqc_codscope_fade = 0;
    csqc_codscope_overlay_env = 0;
    csqc_codscope_overlay_env_out_start = 0;
    csqc_codscope_fog_active = 0;
    csqc_codscope_overlay_step_y = 0;
    csqc_codscope_overlay_land_y = 0;
    csqc_codscope_overlay_land_vel = 0;
    csqc_codscope_holdbreath_env = 1;
    csqc_codscope_holdbreath_active = 0;
    csqc_codscope_punish_env = 0;
    csqc_codscope_fire_blocks_ads = 0;
    csqc_codscope_prev_action_id = 0;
    csqc_codscope_prev_sprint_btn = 0;
    csqc_codscope_prev_onground = 0;
    csqc_codscope_prev_vel_z = 0;
    csqc_codscope_last_update_time = 0;
    csqc_codscope_prev_punished = 0;
    csqc_codscope_next_heartbeat_time = 0;
};

// ----------------------------------------------------------------
//  CSQC_CodScope_IsActive — true while the player is in any non-OFF
//  phase.  Used by the crosshair / sensitivity paths to gate against
//  the COD scope being engaged.
// ----------------------------------------------------------------
float() CSQC_CodScope_IsActive =
{
    return csqc_codscope_phase != CODSCOPE_PHASE_OFF;
};

// ----------------------------------------------------------------
//  CSQC_CodScope_IsScoped — true while the player is actually scoped
//  (phases SCOPED or FADING_OUT — both have the scope FOV applied).
//  Drives the FOV override and scope-fog hookup.
// ----------------------------------------------------------------
float() CSQC_CodScope_IsScoped =
{
    return csqc_codscope_phase == CODSCOPE_PHASE_SCOPED
        || csqc_codscope_phase == CODSCOPE_PHASE_FADING_OUT;
};

// ----------------------------------------------------------------
//  CSQC_CodScope_HidesViewmodel — caller is CSQC_AddPredictedViewmodel
//  in cl_weapons.qc.  TRUE when the viewmodel should be skipped because
//  the player is looking through a scope (either CoD or CS style).
//  Covers FADING_IN / SCOPED / FADING_OUT for CoD; zoomstage>0 +
//  scope-capable weapon for CS.  RAISING + FALLING are NOT hidden —
//  the user needs to see the gun animate up/down.
// ----------------------------------------------------------------
float() CSQC_CodScope_HidesViewmodel =
{
    if (!predicted_player)
        return 0;
    if (csqc_codscope_phase == CODSCOPE_PHASE_FADING_IN
        || csqc_codscope_phase == CODSCOPE_PHASE_SCOPED
        || csqc_codscope_phase == CODSCOPE_PHASE_FADING_OUT)
        return 1;
    // Weapon_HasZoomView covers the binoculars too — and because their zoomstage
    // is only raised at the END of down_to_up and dropped on the FIRST frame of
    // up_to_down (SH_DodBinocsZoomEngaged), the raise and the lower both stay
    // visible and only the held view is hidden.  That is the same rule the comment
    // above states for RAISING / FALLING.
    if (predicted_player.zoomstage > 0
        && Weapon_HasZoomView(predicted_player.weapon))
        return 1;
    return 0;
};

// Eligibility predicate — "is this weapon a COD-scope weapon AND is
// sv_codscopes on AND no grapple/ladder/sprint gate".  Single source
// of truth for entry conditions and runtime cancels.  Reads via
// PM_ReadMovevar so remote servers (where sv_codscopes / sv_codladders
// / sv_shiftspeed live only as serverinfo) work correctly.
float() CodScope_Eligible =
{
    if (!predicted_player || !csqc_prediction_valid)
        return 0;
    if (!PM_ReadMovevar("sv_codscopes", 0))
        return 0;
    if (predicted_player.weapon_scope_class == SCOPE_CLASS_NONE)
        return 0;
    // Grapple / carry / codladder are hard cancels — the lower envelope is
    // dropping the gun off-screen, scoping makes no sense.
    if (predicted_player.grapple_rope_active)
        return 0;
    if (predicted_player.pm_carrying)
        return 0;
    if (PM_ReadMovevar("sv_codladders", 0)
        && predicted_player.pm_on_ladder_cached)
        return 0;
    // Sprint cancel — matches the PM_PlayerMoveStep sprint multiplier
    // gate (sh_pmove.qc) which also requires !FL_DUCKING.  Without
    // the duck check, a player holding +button4 + +button6 (duck) +
    // +attack2 + forward would unscope on the forward press even
    // though no actual sprint speed-up is being applied (PM rejects
    // sprint while ducking).  User-reported bug.
    if (PM_ReadMovevar("sv_shiftspeed", 1.0) > 1.001
        && (csqc_live_buttons & PM_BTN_SPRINT)
        && (predicted_player.flags & FL_ONGROUND)
        && !(predicted_player.flags & FL_DUCKING)
        && input_movevalues_x > 0)
        return 0;
    return 1;
};

// Apply (or restore) the scope-modified fog state via localcmd.
// Base fog string comes from the worldspawn "fog" key, pushed by the
// server as serverinfo sv_worldfog ("density r g b [a [bias]]"). When
// entering scope, +1 is added to the bias slot (last token); when
// leaving, the original string is re-emitted. Empty key = no fog
// hookup at all (scope visual still works).
void(float want_scope_fog) CodScope_ApplyFog =
{
    if (want_scope_fog == csqc_codscope_fog_active)
        return;
    string base = serverkey("sv_worldfog");
    if (base == "")
    {
        csqc_codscope_fog_active = want_scope_fog;
        return;
    }
    float n = tokenize(base);
    if (n < 4)
    {
        csqc_codscope_fog_active = want_scope_fog;
        return;
    }
    float density = stof(argv(0));
    float r = stof(argv(1));
    float g = stof(argv(2));
    float b = stof(argv(3));
    float a = (n >= 5) ? stof(argv(4)) : 1;
    float base_bias = (n >= 6) ? stof(argv(5)) : 0;
    // Scope bias delta is hardcoded +1 (raises fog bias-height so the
    // fog reads denser at eye level while scoped). Was sv_fog_scope_bias_delta.
    float bias = base_bias + (want_scope_fog ? 1 : 0);
    localcmd(sprintf("fog %f %f %f %f %f %f\n",
        density, r, g, b, a, bias));
    csqc_codscope_fog_active = want_scope_fog;
};

// Set the phase + stamp.  Snapshots overlay_env when entering OUT so
// the ease-in animation can scale from the value we left SCOPED (or
// FADING_IN) at — important for cancels mid-rise.  zoom.wav is NOT
// played here automatically — callers play it at their site so the
// fire-induced cancel doesn't double up with the user-release one
// (the user-reported "second fade out sound on release after fire"
// bug).  Specifically: RAISING→FADING_IN and SCOPED→FADING_OUT-via-
// button-release play zoom.wav at their sites; the fire-cancel and
// eligibility-cancel paths stay silent.
void(float new_phase) CodScope_SetPhase =
{
    if (new_phase == CODSCOPE_PHASE_FADING_OUT)
        csqc_codscope_overlay_env_out_start = csqc_codscope_overlay_env;
    csqc_codscope_phase = new_phase;
    csqc_codscope_phase_start = cltime;
};

// Easing curves — quadratic.
float(float t) ease_out_quad =
{
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return 1 - (1 - t) * (1 - t);
};
float(float t) ease_in_quad =
{
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return t * t;
};

// ----------------------------------------------------------------
//  CSQC_CodScope_UpdateState  —  called once per CSQC_Input_Frame
//  from cl_player.qc's predict-tick path (alongside CSQC_ViewFX_UpdateState).
//  Drives phase transitions, overlay envelope, sway components, and
//  the breathing sound edge.
// ----------------------------------------------------------------
void() CSQC_CodScope_UpdateState =
{
    if (!predicted_player || !csqc_prediction_valid)
    {
        if (csqc_codscope_phase != CODSCOPE_PHASE_OFF)
        {
            CodScope_ApplyFog(0);
            CSQC_CodScope_Reset();
        }
        return;
    }

    float now = cltime;
    float dt = now - csqc_codscope_last_update_time;
    csqc_codscope_last_update_time = now;
    if (dt < 0.0001) dt = 0.0001;
    if (dt > 0.1) dt = 0.1;

    float eligible = CodScope_Eligible();
    float button_held = (csqc_live_buttons & 4) ? 1 : 0;
    float age = now - csqc_codscope_phase_start;
    float dur;
    float t;

    // Fire-suppression source of truth lives on the player entity as
    // .pm_fire_suppress_until (set by SH_StandardTryFire).  Mirror it
    // into csqc_codscope_fire_blocks_ads so existing consumers
    // (cl_viewfx.qc ADS target gate, the FALLING / OFF re-engage
    // gates below) keep reading the boolean without an entity deref.
    // Auto re-engage falls out for free: once the timer expires the
    // boolean flips to 0, the OFF → RAISING entry edge re-arms, and
    // the player rescopes if they're still holding +attack2 — the
    // user-requested "return to ADS scoping in after the shot is
    // complete" behaviour.
    // PSG1 (semi-auto sniper) exempt — the fire-suppress timer still
    // ticks but its visual effects are suppressed so the scope feel
    // remains "stay scoped through rapid shots".
    // CFAUG is full-auto — exempt like the semi-auto snipers so the
    // post-fire ADS-drop never triggers and the scope stays up while
    // the player empties the mag.
    // Only BOLT-action snipers block re-ADS after a shot (the bolt cycle
    // drops the scope); semi-auto snipers + low-power scoped rifles stay
    // scoped.  Driven by weapon_scope_class.
    csqc_codscope_fire_blocks_ads =
        (time < predicted_player.pm_fire_suppress_until
         && predicted_player.weapon_scope_class == SCOPE_CLASS_SNIPER_BOLT) ? 1 : 0;

    // Fire detection — any increment of wep_action_id while we're in
    // a "scope is forming or formed" phase forces a scope-out so the
    // gun visibly drops after every shot.  RAISING-fire goes to OFF
    // directly (no fade was set up) so a later release doesn't
    // re-enter FALLING which would reset fade to 1 and produce a
    // visible black flash — the original "second fade out" bug.
    //
    // Semi-auto sniper exception: PSG1 / SVD Dragunov stay scoped
    // through fire so rapid follow-up shots feel right.  Bolt-action
    // snipers (Scout, AWP, Barrett M82, Remington M700) still scope
    // out because the bolt-cycle animation visually races the scope.
    float fire_scopes_out = 1;
    if (predicted_player.weapon_scope_class == SCOPE_CLASS_SNIPER_SEMI
        || predicted_player.weapon_scope_class == SCOPE_CLASS_RIFLE_LOWPOWER)
        fire_scopes_out = 0;
    float cur_action = predicted_player.wep_action_id;
    if (csqc_codscope_prev_action_id != 0
        && cur_action != csqc_codscope_prev_action_id
        && fire_scopes_out)
    {
        if (csqc_codscope_phase == CODSCOPE_PHASE_SCOPED
            || csqc_codscope_phase == CODSCOPE_PHASE_FADING_IN)
            CodScope_SetPhase(CODSCOPE_PHASE_FADING_OUT);
        else if (csqc_codscope_phase == CODSCOPE_PHASE_RAISING)
            CodScope_SetPhase(CODSCOPE_PHASE_OFF);
    }
    csqc_codscope_prev_action_id = cur_action;

    // Phase-OFF → RAISING entry edge.  Gated on !fire_blocks_ads so a
    // post-fire FALLING→OFF transition with +attack2 still held doesn't
    // immediately re-enter RAISING (which would later transition through
    // FALLING again on the user's eventual release, producing a second
    // black fade-out — the user-reported "screen unfades and fades out
    // twice" bug).  Player must release +attack2 first; that clears
    // fire_blocks_ads and the next press re-engages cleanly.
    if (csqc_codscope_phase == CODSCOPE_PHASE_OFF)
    {
        if (eligible && button_held && !csqc_codscope_fire_blocks_ads)
            CodScope_SetPhase(CODSCOPE_PHASE_RAISING);
    }

    // Hard cancel from any non-OFF phase if the player isn't eligible
    // (weapon switch, grapple, ladder, sprint).  RAISING aborts to
    // OFF (no fade started → no animation needed); committed phases
    // (FADING_IN / SCOPED) route through FADING_OUT to animate the
    // close.
    if (csqc_codscope_phase != CODSCOPE_PHASE_OFF && !eligible)
    {
        if (csqc_codscope_phase == CODSCOPE_PHASE_SCOPED
            || csqc_codscope_phase == CODSCOPE_PHASE_FADING_IN)
            CodScope_SetPhase(CODSCOPE_PHASE_FADING_OUT);
        else if (csqc_codscope_phase == CODSCOPE_PHASE_RAISING)
            CodScope_SetPhase(CODSCOPE_PHASE_OFF);
    }

    // Per-phase animation.
    if (csqc_codscope_phase == CODSCOPE_PHASE_RAISING)
    {
        // ADS envelope (driven separately in cl_viewfx.qc) brings the
        // gun up.  Cross the configurable threshold to COMMIT to the
        // scope-in.  Releasing the button BEFORE the threshold sends
        // us to FALLING (gun lowers naturally, no fade).
        csqc_codscope_fade = 0;
        csqc_codscope_overlay_env = 0;
        float thresh = cvar("cl_codscope_ads_threshold");
        if (thresh < 0.01) thresh = 0.95;
        if (csqc_viewfx_ads_env > thresh)
        {
            // Scope-in click — only at the commit edge.
            localsound("sounds/weapons/wpn_csawp/zoom.wav");
            CodScope_SetPhase(CODSCOPE_PHASE_FADING_IN);
        }
        else if (!button_held)
        {
            // Release before commit — go straight to OFF, NOT
            // FALLING.  FALLING's fade animation starts at 1 (it's
            // designed to UNDO a faded-out scope), so entering it
            // with fade=0 would jump-cut to black and unfade — the
            // user-reported "second fade out on release" artifact.
            CodScope_SetPhase(CODSCOPE_PHASE_OFF);
        }
    }
    else if (csqc_codscope_phase == CODSCOPE_PHASE_FADING_IN)
    {
        // COMMITTED — no button-release cancel.  Quickly fade up.
        // When the fade reaches 1, swap to SCOPED which inverts
        // the ramp and starts revealing the overlay.
        dur = cvar("cl_codscope_fade_in_time");
        if (dur < 0.001) dur = 0.08;
        csqc_codscope_fade = bound(0, age / dur, 1);
        csqc_codscope_overlay_env = 0;
        if (csqc_codscope_fade >= 1)
            CodScope_SetPhase(CODSCOPE_PHASE_SCOPED);
    }
    else if (csqc_codscope_phase == CODSCOPE_PHASE_SCOPED)
    {
        // Unfade slowly with ease-out (fast initial reveal, soft
        // settle) — matches "ramp down when it comes to centre of
        // screen".  Overlay rises with the same curve so the two
        // arrive together.  Engage the fog hookup here.
        dur = cvar("cl_codscope_unfade_time");
        if (dur < 0.001) dur = 0.35;
        t = bound(0, age / dur, 1);
        csqc_codscope_fade = 1 - ease_out_quad(t);
        csqc_codscope_overlay_env = ease_out_quad(t);
        CodScope_ApplyFog(1);
        if (!button_held)
        {
            // Scope-out click — only at the intentional release edge.
            // Fire-induced cancel above stays silent so the user's
            // post-fire release doesn't trigger a redundant second
            // zoom.wav.
            localsound("sounds/weapons/wpn_csawp/zoom.wav");
            CodScope_SetPhase(CODSCOPE_PHASE_FADING_OUT);
        }
    }
    else if (csqc_codscope_phase == CODSCOPE_PHASE_FADING_OUT)
    {
        // COMMITTED — overlay drops with ease-IN (slow start,
        // accelerating fall) per user spec "out is a slow ramp up
        // going down".  Fade also ramps to black quickly.  When the
        // fade reaches 1, restore fog and drop into FALLING.  We do
        // NOT short-circuit back to SCOPED on mid-fade re-press —
        // that would let the player keep their scope view by spamming
        // +attack2.  Re-engage only kicks in once we reach FALLING.
        dur = cvar("cl_codscope_fade_out_time");
        if (dur < 0.001) dur = 0.08;
        t = bound(0, age / dur, 1);
        csqc_codscope_fade = t;
        csqc_codscope_overlay_env = csqc_codscope_overlay_env_out_start
                                  * (1 - ease_in_quad(t));
        if (csqc_codscope_fade >= 1)
        {
            CodScope_ApplyFog(0);
            CodScope_SetPhase(CODSCOPE_PHASE_FALLING);
        }
    }
    else if (csqc_codscope_phase == CODSCOPE_PHASE_FALLING)
    {
        // Unfade back to clear.  Wait until ADS envelope has finished
        // decaying so the OFF transition happens AFTER the gun is
        // visibly back down.
        //
        // Mid-fall re-engage: if the player re-presses +attack2
        // before the gun has fully lowered AND eligibility is still
        // satisfied AND the fire suppression has cleared (button was
        // released since the last shot), kick straight back into the
        // scope sequence.  Without this, releasing then re-pressing
        // before the ADS envelope hits 0 leaves the gun ADS-visible
        // but with no scope — the user-reported bug.
        dur = cvar("cl_codscope_unfade_out_time");
        if (dur < 0.001) dur = 0.15;
        t = bound(0, age / dur, 1);
        csqc_codscope_fade = 1 - t;
        csqc_codscope_overlay_env = 0;
        if (eligible && button_held && !csqc_codscope_fire_blocks_ads)
        {
            float thresh2 = cvar("cl_codscope_ads_threshold");
            if (thresh2 < 0.01) thresh2 = 0.85;
            // If the ADS envelope is still high enough (we caught the
            // re-press before the gun fell far) jump straight back
            // into FADING_IN; otherwise drop into RAISING so the gun
            // re-raises with the standard ADS ease.
            if (csqc_viewfx_ads_env > thresh2)
                CodScope_SetPhase(CODSCOPE_PHASE_FADING_IN);
            else
                CodScope_SetPhase(CODSCOPE_PHASE_RAISING);
        }
        else if (csqc_codscope_fade <= 0 && csqc_viewfx_ads_env < 0.05)
        {
            CodScope_SetPhase(CODSCOPE_PHASE_OFF);
        }
    }

    // ---- Hold-breath sound edges + amplitude envelope ----
    // The latch flips from 0 → 1 whenever "should be holding breath"
    // becomes true — covers BOTH (a) +button4 pressed while already
    // scoped AND (b) scope reaching SCOPED with +button4 already held
    // (the user-reported "press +button4 first then scope = drain but
    // no breath reduction" bug).  Falling edge plays breathout only
    // if we're still scoped at the moment of release so a fire-driven
    // auto-unscope doesn't leak a stray breathout when the player
    // eventually releases +button4.
    float sprint_btn = (csqc_live_buttons & PM_BTN_SPRINT) ? 1 : 0;
    float scoped = CSQC_CodScope_IsScoped();

    // A weapon on the LEGACY zoomstage path is aiming too.  Hoisted up here
    // from the sway block below, which has always gated on `scoped ||
    // cs_zoomed` — while hold-breath tested `scoped` ALONE.
    //
    // That asymmetry is a real bug, not a style nit: CSQC_CodScope_IsScoped()
    // is CoD-phase only, and a weapon only reaches the CoD phase if it
    // declared a scope class through W_SetADSProfile.  Any WMF_FLAG_SCOPE
    // weapon that didn't — the crossbow and the G3SG1 today — therefore got
    // the full sway treatment with no way whatsoever to steady it, and
    // +sprint while scoped did nothing.  The two gates have to agree: if it
    // sways, it must be steadyable.
    float cs_zoomed = predicted_player.zoomstage > 0
                   && Weapon_HasScope(predicted_player.weapon);
    float aiming = scoped || cs_zoomed;

    float stamina_locked = PM_ReadMovevar("sv_codstamina", 0) > 0
                        && predicted_player.codstamina_punished;
    float wants_holdbreath = aiming && sprint_btn && !stamina_locked;
    if (wants_holdbreath && !csqc_codscope_holdbreath_active)
    {
        localsound("sounds/player/breathin.wav");
        csqc_codscope_holdbreath_active = 1;
        csqc_codscope_next_heartbeat_time = now + 1.0;
    }
    else if (!wants_holdbreath && csqc_codscope_holdbreath_active)
    {
        // `aiming`, not `scoped` — otherwise releasing +sprint on a legacy-zoom
        // weapon swallows the breathout it just played breathin for.
        if (aiming)
            localsound("sounds/player/breathout.wav");
        csqc_codscope_holdbreath_active = 0;
    }
    csqc_codscope_prev_sprint_btn = sprint_btn;

    // Heartbeat — 1 Hz pulse while the hold-breath latch is set.  Same
    // gate as the breathin click, so a stamina punish silences it.
    if (csqc_codscope_holdbreath_active && now >= csqc_codscope_next_heartbeat_time)
    {
        localsound("sounds/player/heartbeat.wav");
        csqc_codscope_next_heartbeat_time = now + 1.0;
    }

    // Stamina-depletion edge — out-of-breath cue, played once each
    // time the punish latch flips from 0 → 1.  Independent of scope
    // state so a stamina drain from sprint also gets it.
    float cur_punished = predicted_player.codstamina_punished
                      && PM_ReadMovevar("sv_codstamina", 0) > 0;
    if (cur_punished && !csqc_codscope_prev_punished)
        localsound("sounds/player/outofbreath.wav");
    csqc_codscope_prev_punished = cur_punished;

    float breath_target = 1.0;
    // Only honour the hold-breath multiplier reduction when the
    // player isn't punished — otherwise the env stays at 1 = full
    // amplitude breathing sway, which IS the heavy-breathing punish.
    if (csqc_codscope_holdbreath_active && !stamina_locked)
    {
        breath_target = cvar("cl_codscope_sway_holdbreath_mult");
        if (breath_target <= 0) breath_target = 0.15;
    }
    float breath_fade = cvar("cl_codscope_sway_breath_fade");
    if (breath_fade < 0.001) breath_fade = 0.30;
    float bk = bound(0, (4.0 * dt) / breath_fade, 1.0);
    csqc_codscope_holdbreath_env += (breath_target - csqc_codscope_holdbreath_env) * bk;

    // ---- Punish-scale sway envelope ----
    // Target = 1 at codstamina=0 (just-depleted), ramps linearly to 0
    // at codstamina=1.0 (the clear threshold — the SSQC drain now
    // requires the bar to refill ALL the way before the lockout
    // releases, so the punish env tracks the full 0→1 refill range
    // instead of 0→0.5).  Onsets fast (cl_codscope_sway_punish_fade,
    // default 0.20 s) and ramps down over the full refill duration.
    float punish_target = 0;
    if (scoped && stamina_locked)
    {
        float st_now = predicted_player.codstamina;
        if (st_now < 0) st_now = 0;
        punish_target = bound(0, 1 - st_now, 1);
    }
    float punish_fade = cvar("cl_codscope_sway_punish_fade");
    if (punish_fade < 0.001) punish_fade = 0.20;
    float pk = bound(0, (4.0 * dt) / punish_fade, 1.0);
    csqc_codscope_punish_env += (punish_target - csqc_codscope_punish_env) * pk;
    csqc_codscope_punish_env = bound(0, csqc_codscope_punish_env, 1);

    // ---- Overlay step sway ----
    // Walking / running induces a small vertical bob of the scope
    // overlay only — not the camera.  Reuses cl_viewfx's bob phase
    // (already drives camera bob) so the cadence stays synchronized.
    if (scoped)
    {
        vector hvel = predicted_player.velocity;
        hvel_z = 0;
        float hspeed = vlen(hvel);
        float step_amp = cvar("cl_codscope_sway_step_amp");
        if (step_amp < 0) step_amp = 0;
        // Two_pi * bob phase gives the same cadence the camera uses.
        // sin(phase*2) gives 2× cadence (both footsteps push down),
        // matching the existing camera bob z component.
        float two_pi = 6.2831853;
        float kick = sin(csqc_viewfx_bob_phase * two_pi * 2)
                   * step_amp
                   * bound(0, hspeed / 250, 1.2)
                   * csqc_codscope_holdbreath_env;
        csqc_codscope_overlay_step_y = kick;
    }
    else
    {
        csqc_codscope_overlay_step_y = 0;
    }

    // ---- Overlay landing-impact spring ----
    // Detects ground-touch edge with downward velocity, kicks the
    // overlay-Y spring proportional to impact strength.  The spring
    // recovers to neutral via simple semi-implicit Euler with cvars
    // for stiffness / damping.  Only applies while scoped.
    float onground = (predicted_player.flags & FL_ONGROUND) ? 1 : 0;
    if (scoped && onground && !csqc_codscope_prev_onground)
    {
        float impact = 0 - csqc_codscope_prev_vel_z;
        if (impact > 100)
        {
            float land_amp = cvar("cl_codscope_sway_land_amp");
            if (land_amp < 0) land_amp = 0;
            csqc_codscope_overlay_land_vel += impact * land_amp * 0.05;
        }
    }
    if (!onground)
        csqc_codscope_prev_vel_z = predicted_player.velocity_z;
    csqc_codscope_prev_onground = onground;

    // Spring integration — 80 / 6 = stiffness / damping (matches the
    // camera weight feel without re-exposing yet more cvars).
    csqc_codscope_overlay_land_vel += (0 - 80 * csqc_codscope_overlay_land_y
                                       - 6  * csqc_codscope_overlay_land_vel) * dt;
    csqc_codscope_overlay_land_y += csqc_codscope_overlay_land_vel * dt;
    csqc_codscope_overlay_land_y = bound(-30, csqc_codscope_overlay_land_y, 30);
    if (!scoped)
    {
        // Idle decay when not scoped — avoids the overlay starting a
        // new scope cycle already pre-kicked.
        csqc_codscope_overlay_land_y *= bound(0, 1 - dt * 4, 1);
        csqc_codscope_overlay_land_vel *= bound(0, 1 - dt * 4, 1);
    }

    // ---- Sway angle bias (camera + trace) ----
    // Combined classic + breathing sway in degrees.  Cached here so
    // BOTH the rendered camera (CSQC_ApplySniperSway in cl_cameras.qc)
    // AND the predicted/authoritative trace see the same value, which
    // is the user-asked-for property "bullet lands where the scope is
    // aiming".  Gated on (legacy zoomstage OR cod scoped) AND
    // sv_snipersway; otherwise zero so the bias is a clean no-op for
    // un-scoped fire.
    // cs_zoomed / aiming are computed up beside the hold-breath gate now, so
    // the two cannot drift apart again.
    if (aiming && serverkeyfloat("sv_snipersway", 0) > 0)
    {
        vector hv = predicted_player.velocity;
        hv_z = 0;
        float spd = vlen(hv);
        float sway_intensity = 0.5 + bound(0, spd / 300, 1.5);
        sway_intensity *= csqc_codscope_holdbreath_env;
        float two_pi2 = 6.2831853;
        // Classic-style faster sway (legacy CSQC_ApplySniperSway).
        // Values inlined here so the constants don't need to escape
        // cl_cameras.qc — keep both files in sync if these change.
        float classic_pitch_amp  = 0.7;
        float classic_pitch_rate = 0.28;
        float classic_yaw_amp    = 1.2;
        float classic_yaw_rate   = 0.4;
        float classic_pitch = sin(cltime * classic_pitch_rate * two_pi2)
                            * classic_pitch_amp * sway_intensity;
        float classic_yaw   = sin(cltime * classic_yaw_rate   * two_pi2)
                            * classic_yaw_amp   * sway_intensity;
        // Slow breathing layer — same numbers BreathingSway() uses.
        float breath_amp2 = cvar("cl_codscope_sway_breath_amp");
        float breath_rate2 = cvar("cl_codscope_sway_breath_rate");
        if (breath_rate2 <= 0) breath_rate2 = 0.18;
        float breath_pitch = sin(cltime * breath_rate2 * two_pi2)
                           * breath_amp2 * csqc_codscope_holdbreath_env;
        float breath_yaw   = sin(cltime * breath_rate2 * two_pi2 + 1.2)
                           * breath_amp2 * 0.6 * csqc_codscope_holdbreath_env;
        // Punish multiplier — amplifies the scope sway when the player
        // is in the codstamina punish window.  Default cvar scale = 3
        // → 3× the normal amplitude at peak punish, smoothly tracking
        // the stamina refill toward 1× (no amplification) as the bar
        // climbs back to 0.5.  Multiplied into the cached pitch / yaw
        // so the trace bias (CSQC_CodScope_GetTraceBias) picks it up
        // automatically and the bullet still lands where the swayed
        // crosshair appears.
        float punish_scale = cvar("cl_codscope_sway_punish_scale");
        if (punish_scale < 1) punish_scale = 1;
        float punish_mul = 1 + csqc_codscope_punish_env * (punish_scale - 1);
        csqc_codscope_sway_pitch = (classic_pitch + breath_pitch) * punish_mul;
        csqc_codscope_sway_yaw   = (classic_yaw   + breath_yaw)   * punish_mul;
    }
    else
    {
        csqc_codscope_sway_pitch = 0;
        csqc_codscope_sway_yaw = 0;
    }
};

// ----------------------------------------------------------------
//  CSQC_CodScope_GetTraceBias  —  pitch/yaw delta (degrees) the
//  current sway introduces to the view direction.  Added to
//  self.v_angle around the predict-trace and sent to the server with
//  the `cs` notification so the authoritative trace matches.
// ----------------------------------------------------------------
vector() CSQC_CodScope_GetTraceBias =
{
    return [csqc_codscope_sway_pitch, csqc_codscope_sway_yaw, 0];
};

// ----------------------------------------------------------------
//  CSQC_CodScope_BreathingSway  —  helper called by CSQC_ApplySniperSway
//  in cl_cameras.qc.  Returns an additive (pitch, yaw, 0) breathing
//  oscillation scaled by the live hold-breath envelope.  Works for
//  BOTH the legacy CS scope and the CoD scope — the caller gates on
//  whichever zoom state applies.
// ----------------------------------------------------------------
vector() CSQC_CodScope_BreathingSway =
{
    float amp = cvar("cl_codscope_sway_breath_amp");
    if (amp <= 0) return '0 0 0';
    float rate = cvar("cl_codscope_sway_breath_rate");
    if (rate <= 0) rate = 0.18;
    float two_pi = 6.2831853;
    float scale = csqc_codscope_holdbreath_env;
    if (scale < 0) scale = 0;
    float pitch = sin(cltime * rate * two_pi) * amp * scale;
    // Yaw component uses 0.6× amp and a slight phase offset so the
    // two axes don't track perfectly and the head appears to drift.
    float yaw = sin(cltime * rate * two_pi + 1.2) * amp * 0.6 * scale;
    return [pitch, yaw, 0];
};

// ----------------------------------------------------------------
//  CSQC_CodScope_ApplyFOV  —  called from CSQC_UpdateViewAliveSensitivity
//  AFTER the existing CS-style zoom branch.  Applies AFOV + sensitivity
//  scaling while the COD scope is engaged in its zoomed phases.
// ----------------------------------------------------------------
void() CSQC_CodScope_ApplyFOV =
{
    if (!CSQC_CodScope_IsScoped())
        return;
    // sv_codscope_fov controls the scoped FOV in degrees; falls back
    // to ZOOM_FOV_STAGE2 (12°, the legacy AWP-equivalent zoom) when
    // the cvar is unset / non-positive.  Read via PM_ReadMovevar so
    // remote servers' value is honoured.
    float zoom_fov = PM_ReadMovevar("sv_codscope_fov", 0);
    if (zoom_fov <= 0) zoom_fov = ZOOM_FOV_STAGE2;
    // Scoped assault rifles (AUG / SG552 / SL8) carry a low-power optic —
    // 20% wider FOV than the sniper baseline.  Driven by weapon_scope_class.
    if (predicted_player.weapon_scope_class == SCOPE_CLASS_RIFLE_LOWPOWER)
        zoom_fov *= 1.2;
    setproperty(VF_AFOV, zoom_fov);
    setsensitivityscaler(zoom_fov / cvar("fov"));
};

// ----------------------------------------------------------------
//  CSQC_CodScope_DrawOverlay  —  called from the HUD-pass in
//  CSQC_UpdateViewAliveHud.  Draws (in order):
//    1. The scope overlay — letterbox + scope.png mask, with the
//       hole vertically translated by (1 - overlay_env) * g_height *
//       cl_codscope_overlay_travel plus step + landing kicks.  The
//       LEFT and RIGHT letterbox bars cover the FULL screen height
//       always, and the TOP bar extends from y=0 down to the moving
//       hole top — that fixes the "top of scope not filled" bug from
//       the previous translation-only approach.
//    2. The black fade fill, on top of the overlay so the fade can
//       hide the partially-risen overlay during the FADING_IN window.
// ----------------------------------------------------------------
void() CSQC_CodScope_DrawOverlay =
{
    if (csqc_codscope_phase == CODSCOPE_PHASE_OFF)
        return;

    // Scope overlay — only if the envelope is positive enough to read.
    if (csqc_codscope_overlay_env > 0.001)
    {
        float cx = g_width * 0.5;
        float cy = g_height * 0.5;
        float radius = g_height * 0.45;
        float diameter = radius * 2;

        // Travel cvar caps how far the overlay slides from its
        // centred position — default 0.30 = 30 % of screen height.
        float travel = cvar("cl_codscope_overlay_travel");
        if (travel < 0) travel = 0;
        if (travel > 1) travel = 1;
        // Negative dy moves the hole DOWN the screen (below centre).
        // Add step + landing kicks for the per-frame sway.
        float dy = (1 - csqc_codscope_overlay_env) * g_height * travel
                 + csqc_codscope_overlay_step_y
                 + csqc_codscope_overlay_land_y;

        vector pos, sz;

        // Left letterbox bar — always full screen height, hole-side
        // edge is at cx - radius.  Keeps the screen edge solid black
        // regardless of hole position.
        pos_x = 0; pos_y = 0; pos_z = 0;
        sz_x = cx - radius; sz_y = g_height; sz_z = 0;
        drawfill(pos, sz, '0 0 0', 1, 0);

        // Right letterbox bar — same idea, full height.
        pos_x = cx + radius; pos_y = 0; pos_z = 0;
        sz_x = g_width - (cx + radius); sz_y = g_height; sz_z = 0;
        drawfill(pos, sz, '0 0 0', 1, 0);

        // Top letterbox bar — extends from y=0 down to the hole's
        // top edge (cy - radius + dy).  This is the fix for the
        // previous "top visible above hole" bug: anchor y=0, not dy.
        float top_height = cy - radius + dy;
        if (top_height > 0)
        {
            pos_x = cx - radius; pos_y = 0; pos_z = 0;
            sz_x = diameter; sz_y = top_height; sz_z = 0;
            drawfill(pos, sz, '0 0 0', 1, 0);
        }

        // Bottom letterbox bar — extends from the hole's bottom edge
        // down to y = g_height.  Same anchoring.
        float bottom_top = cy + radius + dy;
        if (bottom_top < g_height)
        {
            pos_x = cx - radius; pos_y = bottom_top; pos_z = 0;
            sz_x = diameter; sz_y = g_height - bottom_top; sz_z = 0;
            drawfill(pos, sz, '0 0 0', 1, 0);
        }

        // The scope circle texture itself.
        pos_x = cx - radius; pos_y = cy - radius + dy; pos_z = 0;
        sz_x = diameter; sz_y = diameter; sz_z = 0;
        drawpic(pos, "gfx/scope.png", sz, '1 1 1', 1, 0);
    }

    // Full-screen black fade on top of everything.
    if (csqc_codscope_fade > 0.001)
    {
        vector full_sz;
        full_sz_x = g_width; full_sz_y = g_height; full_sz_z = 0;
        drawfill('0 0 0', full_sz, '0 0 0', csqc_codscope_fade, 0);
    }
};

// ----------------------------------------------------------------
//  CSQC_CodScope_FogCSStyle  —  called from the CS-style zoom path
//  so that even non-COD scopes (AWP/Scout/G3SG1/Crossbow when
//  sv_codscopes is off) get the bias delta while scoped.  The user
//  spec says: "raise the bias by 1 ... this is for cod scopes and
//  non cod scopes" — so the hookup applies in both modes.
// ----------------------------------------------------------------
void() CSQC_CodScope_FogCSStyle =
{
    // If the COD state machine is engaged it already owns the fog
    // hookup — don't fight it.
    if (csqc_codscope_phase != CODSCOPE_PHASE_OFF)
        return;
    if (!predicted_player || !csqc_prediction_valid)
    {
        CodScope_ApplyFog(0);
        return;
    }
    float scoped = predicted_player.zoomstage > 0
                && Weapon_HasScope(predicted_player.weapon);
    CodScope_ApplyFog(scoped ? 1 : 0);
};
