//
//  cl_brushsync.qc  –  CSQC solid brush entity + door/button prediction
//
//  Receives brush entities from the server and rebuilds them as SOLID_BSP
//  for client-side prediction traces.
//
//  Doors and buttons receive pos1/pos2/speed/state parameters so the client
//  can predict their movement instantly (before the server confirms).
//

// Forward decls of the brushsync fields the predraw below reads.
// The full declarations live further down; QC accepts re-declaring
// the same `.float foo` to share storage, so the duplicates here
// are harmless and let us order the predraw before its field
// definitions.
.float  mover_state;
.float  brush_is_rotating;
.vector pos1;
.vector pos2;
// Server-intent non-solid bit — read by CSQC_SolidBrush_Update from
// the wire and consumed by the solid assignment below.  Forward-decl
// here so the parser block (which appears before the canonical
// declaration further down) can reference it.
.float  wire_nonsolid;
// Snapshot anchors for the predraw extrapolators — see
// CSQC_SolidBrush_Predraw.  Origin anchor lets train brushes
// extrapolate position forward each render frame instead of
// relying on engine MOVETYPE_NOCLIP integration (which got reset
// to authoritative each snapshot, producing visible back-and-
// forth oscillation between integration-forward and snap-back).
// Prev-anchor pairs are used by the train ANGLE rate calc — yaw
// isn't shipped as avelocity for tracktrains, so we differentiate
// snapshot-to-snapshot to compute a rate for between-snapshot
// extrapolation.
.vector csqc_snap_angles;
.vector csqc_snap_origin;
.float  csqc_snap_time;
.vector csqc_snap_angles_prev;
.float  csqc_snap_time_prev;

// Per-frame angle projector for rotating brushwork
// (func_door_rotating).  Brushsync ships self.avelocity + the
// snapshot angles in its payload; this predraw projects forward
// from the latest snapshot so rotation is smooth between server-
// tick snapshots.
//
// PROJECTOR, NOT INTEGRATOR.  Earlier versions accumulated
// `self.angles += avel * frametime` every render frame.  That
// drifted ahead of the server-side carry pass (which runs at
// sv_func_tickrate, default 64 Hz) — visible on a listen server
// as "view is slightly behind the door".  Each render frame now
// recomputes from `csqc_snap_angles + avel * elapsed`, where
// `elapsed = cltime - csqc_snap_time`.
//
// The brushsync wire only re-sends an entity when QC dirties
// SendFlags, and a rotating door only does that at start / end
// of the rotation — not every tick.  So for movers we MUST
// extrapolate forward across the whole rotation duration; the
// snapshot anchor stays put for several seconds at high
// `distance` (e.g. 800° at 200°/s = 4 s).  When the brush has a
// known destination (mover_state UP/DOWN) we let elapsed run
// uncapped and rely on the per-axis dest clamp below to bound
// the projection naturally.
//
// For non-mover rotation (idle or non-mover_state cases like
// func_rotating / func_pendulum) we still cap elapsed to
// cl_brushsync_lookahead so the brush doesn't drift forever
// between snaps when avelocity is the only signal we have.
//
// Clamping at the destination angle prevents the visible
// overshoot-then-snap-back that pure avelocity projection
// produces: avelocity stays non-zero in the wire until the server
// arrives at the target and ships a final snapshot with avel=0,
// and at typical net rates that means the projection can land one
// or two frames past the destination before the snap arrives.
// Knowing the destination here lets us stop at the right moment.
//
// Destination = pos2 when mover_state is UP (closed → open
// transition), pos1 when DOWN.  For rotating doors pos1 is the
// closed angles and pos2 the dynamically-computed open angles
// (server recomputes pos2 each go_up based on player side, then
// ships it via the wire).  Other states leave self.angles
// unclamped so the projector becomes a pure avel*elapsed step —
// fine for the brief windows between snapshots when the door is
// momentarily idle.
float(float step, float remain) _SolidBrush_StepAxis =
{
    // Sign-aware "don't pass" clamp.  Returns the step to apply
    // this frame so the caller's `angles = snap + step` lands at
    // the remainder limit and no further.
    if (step * remain <= 0)
        return remain;       // already at / past dest, snap exact
    if (fabs(step) >= fabs(remain))
        return remain;
    return step;
};

float(entity ent) CSQC_Brush_RotationAxis =
{
    if (fabs(ent.avelocity_x) >= fabs(ent.avelocity_y)
     && fabs(ent.avelocity_x) >= fabs(ent.avelocity_z)
     && fabs(ent.avelocity_x) > 0)
        return 0;
    if (fabs(ent.avelocity_z) >= fabs(ent.avelocity_y)
     && fabs(ent.avelocity_z) > 0)
        return 2;
    if (fabs(ent.avelocity_y) > 0)
        return 1;

    // Stopped func_door_rotating: infer the active axis from its
    // replicated closed/open angle pair so local +use prediction can
    // start on the same axis before the first server motion snapshot.
    vector delta = ent.pos2 - ent.pos1;
    if (fabs(delta_x) >= fabs(delta_y)
     && fabs(delta_x) >= fabs(delta_z)
     && fabs(delta_x) > 0)
        return 0;
    if (fabs(delta_z) >= fabs(delta_y)
     && fabs(delta_z) > 0)
        return 2;
    return 1;
};

// GoldSrc renderfx (0..16) animation enum + per-entity state for the
// BrushSync_ApplyRenderFX evaluator.  Declared here (above Predraw)
// rather than next to rendermode further down so the Predraw function
// can reference them without forward declarations.
.float  renderfx;       // wire byte (0..16)
.float  renderfx_spawn; // cltime captured on first non-zero renderfx
.float  renderfx_base_alpha;
.vector renderfx_base_colormod;
.float  renderfx_base_effects;

float() CSQC_SolidBrush_Predraw =
{
    if (self.avelocity != '0 0 0')
    {
        // Project from the snapshot anchor, not from last frame's
        // angles — see header comment for why.
        float elapsed = cltime - self.csqc_snap_time;
        if (elapsed < 0)
            elapsed = 0;

        vector dest = self.csqc_snap_angles;
        float clamp_to_dest = 0;
        if (self.mover_state == MOVER_STATE_UP)
        {
            dest = self.pos2;
            clamp_to_dest = 1;
        }
        else if (self.mover_state == MOVER_STATE_DOWN)
        {
            dest = self.pos1;
            clamp_to_dest = 1;
        }

        // Lookahead cap — bounds how far the predraw projects past
        // the latest snapshot.
        //
        // Non-mover rotation (func_rotating / func_pendulum mid-snap):
        //   cl_brushsync_lookahead seconds.  These don't have a
        //   destination to bound extrapolation.
        //
        // Mover rotation (func_door_rotating, UP/DOWN states):
        //   force a tight 0.05 s cap regardless of cl_brushsync_lookahead.
        //   With cl_brushsync_lookahead at the default 1.0, an
        //   extrapolation that big combined with the dest-axis
        //   clamp below collapsed the projected angle straight to
        //   pos1/pos2 once the angle was within 1 s of the dest —
        //   the brush flickered between the correct mid-rotation
        //   pose and the dest pose every frame.  The server now
        //   re-sends every RotDoor_CarryTick (sv_func_tickrate
        //   dedup'd to netrate, ~50 ms gaps typical), so a 50 ms
        //   forward cap covers a single missed snap without ever
        //   reaching the dest one frame too early.
        float lookahead = cvar("cl_brushsync_lookahead");
        if (lookahead < 0)
            lookahead = 0;
        // Mover-state UP/DOWN: the per-tick re-snap from the server
        // keeps csqc_snap_angles within ~50 ms of authoritative, so
        // a tight 0.05 s cap is plenty.  Larger caps combined with
        // the previous dest-axis "don't pass" clamp produced visible
        // flicker between the correctly-extrapolated pose and the
        // dest pose mid-snap-interval (the user's reported bug).
        if (clamp_to_dest && lookahead > 0.05)
            lookahead = 0.05;
        if (elapsed > lookahead)
            elapsed = lookahead;

        // Linear extrapolation for ALL paths.  The dest-axis "don't
        // pass" clamp was removed: with a small lookahead and per-
        // tick server re-snaps, the worst-case overshoot is one cap
        // window of motion (~10 ° at 200°/s) and that's only visible
        // for a single frame before the server's final-stop snap
        // arrives with avelocity = 0 + the exact dest angle.  Far
        // less visible than the flicker the dest clamp produced
        // when step crossed the per-axis remaining-distance.  `dest`
        // is left computed above but no longer consulted.
        self.angles = self.csqc_snap_angles + self.avelocity * elapsed;
    }

    // TRAIN-specific extrapolation.  Engine MOVETYPE_NOCLIP integrates
    // origin += velocity * frametime each render frame, but the next
    // snapshot then OVERRIDES origin back to authoritative — the
    // integrate-then-reset cycle produced the visible back-and-forth
    // oscillation the user reported when noclipping near a moving
    // cab.  Replace it: each frame we compute origin = snap_origin +
    // velocity * (cltime - snap_time), capped to cl_brushsync_lookahead.
    // The engine's NOCLIP integration is still running into self.origin,
    // but this predraw runs after it and overwrites the result, so the
    // engine integration becomes a per-frame no-op.
    //
    // Yaw is treated similarly but with a rate differentiated from
    // two consecutive snapshots (no avelocity to use for tracktrains).
    if (self.brush_type == BRUSH_TYPE_TRAIN || self.brush_type == BRUSH_TYPE_VEHICLE)
    {
        float t_elapsed = cltime - self.csqc_snap_time;
        if (t_elapsed < 0) t_elapsed = 0;
        float t_lookahead = cvar("cl_brushsync_lookahead");
        if (t_lookahead < 0) t_lookahead = 0;

        // Cap the extrapolation at roughly ONE observed update interval, not at
        // the full cl_brushsync_lookahead (1 second by default).
        //
        // Extrapolation here is a straight line along the last known velocity,
        // and a tracktrain's velocity turns at every path_track.  Given a whole
        // second of budget, th_ep1_00's intro truck — 240 u/s — would carry 240
        // units past a corner before the next snapshot yanked it back onto the
        // rails: "the car drives off track weirdly, but next cut it's back on
        // track".  The same thing happens whenever updates simply stop arriving
        // (the brush leaves the PVS mid-shot), and there the replica then just
        // sits at that wrong offset until they resume.
        //
        // One update interval is the honest budget: it covers the gap we
        // actually expect and no more.  1.5x absorbs ordinary jitter in the
        // snapshot rate.  The cvar stays the hard ceiling, and the first
        // snapshot (no prev yet) still gets the full allowance because there is
        // nothing to measure from.
        if (self.csqc_snap_time_prev > 0)
        {
            float t_period = (self.csqc_snap_time - self.csqc_snap_time_prev) * 1.5;
            if (t_period > 0 && t_lookahead > t_period)
                t_lookahead = t_period;
        }

        // HARD CEILING, independent of the observed snapshot gap.
        //
        // The adaptive clamp above only ever TIGHTENS t_lookahead below
        // cl_brushsync_lookahead (default 1.0), so it is a mitigation and not
        // an amplifier -- but it still lets the budget grow back toward a full
        // second once the stream has been slow for two consecutive gaps (PVS
        // drop-out across a cutscene camera cut, packet loss, rate limit).
        // That is the wrong shape for a PATH-FOLLOWING brush: a func_train /
        // func_tracktrain re-aims its velocity at every path_corner /
        // path_track, so this straight-line projection leaves the road at
        // every corner by v * t * 2*sin(turn/2) and no budget is ever honest.
        //
        // Measured on th_ep1_00's intro truck "pickup" (50 path_tracks,
        // 18595 qu, 240 qu/s, 500 qu/s across pua -> puazzzzzt), sharpest
        // corner 32.4 deg at new2, factor 2*sin(16.2 deg) = 0.557:
        //       24 ms ->   3.2 qu   (healthy cadence; invisible)
        //      100 ms ->  13.4 qu   (this ceiling; 25 qu at 500 qu/s)
        //      300 ms ->  40 qu
        //     1000 ms -> 134 qu at 240 qu/s, 253 qu at 500 qu/s
        //                = one to two truck-lengths off the road
        //
        // 100 ms still covers a 10-packets-per-second stream, so nothing that
        // is smooth today becomes steppy; past that the replica holds near the
        // last authoritative sample instead of coasting away.
        //
        // Deliberately NOT switched to snapshot-to-snapshot INTERPOLATION.
        // csqc_snap_time is stamped with cltime at packet-parse time, so an
        // interpolation denominator would carry the full network jitter and the
        // rendered SPEED would wobble -- worse on a 77-second cinematic
        // tracking shot than a few qu of corner error.  And BRUSH_TYPE_TRAIN is
        // not tracktrain-only: func_plat, func_trackautochange and
        // func_pushable all share it, have no corners at all, and are ridden or
        // shoved by the player (63 pushables in bm_sts alone) -- a snapshot
        // interval of added latency there is a regression, not a fix.  It is
        // also not render-only: cl_defs.qc sets physics_mode = 2, so the
        // client's own collision link integrates from this origin.
        if (t_lookahead > 0.1) t_lookahead = 0.1;

        if (t_elapsed > t_lookahead) t_elapsed = t_lookahead;

        if (self.velocity != '0 0 0')
            self.origin = self.csqc_snap_origin + self.velocity * t_elapsed;

        // Yaw rate from two consecutive snapshots — only valid when
        // we have a previous snapshot recorded (csqc_snap_time_prev > 0)
        // and a non-zero gap between them.  Static / just-spawned
        // brushes leave prev at zero, which we treat as "no rate
        // yet; just hold snap_angles".
        //
        // BRUSH_TYPE_VEHICLE skips this snap-differentiated yaw entirely:
        // a func_vehicle ships avelocity_y (live steering), so the
        // rotating branch above (avelocity != 0) already extrapolated
        // angles_y.  Differentiating snap-to-snap here too would
        // double-drive the yaw (the 2x-rotation cab bug).
        if (self.brush_type == BRUSH_TYPE_TRAIN && self.csqc_snap_time_prev > 0)
        {
            float t_snap_dt = self.csqc_snap_time - self.csqc_snap_time_prev;
            if (t_snap_dt > 0.001)
            {
                float t_yaw_diff = self.csqc_snap_angles_y - self.csqc_snap_angles_prev_y;
                if (t_yaw_diff > 180)  t_yaw_diff = t_yaw_diff - 360;
                if (t_yaw_diff < -180) t_yaw_diff = t_yaw_diff + 360;
                float t_yaw_rate = t_yaw_diff / t_snap_dt;
                self.angles_y = self.csqc_snap_angles_y + t_yaw_rate * t_elapsed;
            }
        }
    }

    // Origin overshoot clamp for sliding func_door / func_button in
    // transit.  Engine's MOVETYPE_NOCLIP integration keeps adding
    // velocity * frametime to self.origin every render frame; when
    // the server's stop snap arrives it overrides origin back to
    // pos1/pos2 (and zeroes velocity).  Without a clamp the brush
    // visually overshoots the endpoint and snaps back — the user's
    // reported snap-back.  Knowing pos1/pos2 + mover_state on the
    // wire, we clamp ourselves: as soon as the integrated origin
    // crosses the dest along the velocity axis, snap to dest and
    // zero velocity locally so the engine stops integrating.
    if (self.velocity != '0 0 0'
        && !self.brush_is_rotating
        && (self.brush_type == BRUSH_TYPE_DOOR
         || self.brush_type == BRUSH_TYPE_BUTTON))
    {
        vector mdest = '0 0 0';
        float  has_dest = 0;
        if (self.mover_state == MOVER_STATE_UP)
        {
            mdest = self.pos2;
            has_dest = 1;
        }
        else if (self.mover_state == MOVER_STATE_DOWN)
        {
            mdest = self.pos1;
            has_dest = 1;
        }
        if (has_dest)
        {
            vector to_dest = mdest - self.origin;
            if (to_dest * self.velocity <= 0)
            {
                setorigin(self, mdest);
                self.velocity = '0 0 0';
            }
        }
    }

    // renderfx animation — applied here (NOT in Update) so the alpha /
    // colormod / effects pulse / strobe / fade smoothly between
    // snapshots at render rate.  BrushSync_ApplyRenderFX modulates
    // self.alpha/colormod/effects from the BASE values latched in
    // Update.  No-op when renderfx == 0.
    vector saved_origin_for_jitter = self.origin;
    float  jitter_applied = 0;
    if (self.renderfx > 0)
    {
        float fx_t = cltime - self.renderfx_spawn;
        BrushSync_ApplyRenderFX(self.renderfx_base_alpha,
                                self.renderfx_base_colormod,
                                self.renderfx_base_effects,
                                self.renderfx,
                                fx_t);

        // Renderfx 15/16 (Distort, Hologram) set RENDERFX_JITTER_FLAG
        // in self.effects.  Apply a small per-frame origin offset to
        // produce the distortion effect, then mask the sentinel off
        // before the engine renders (so the flag doesn't accidentally
        // ride along as an engine EF_* bit).  Saved/restored around
        // addentity so the jitter doesn't compound across frames.
        if (self.effects & RENDERFX_JITTER_FLAG)
        {
            // ±2qu jitter on X/Y.  Different sin frequencies per
            // axis to avoid axis-aligned shimmer; deterministic so
            // it doesn't hammer random().
            vector jitter;
            jitter_x = 2 * sin(cltime * 47.3 + self.entnum * 1.3);
            jitter_y = 2 * sin(cltime * 53.1 + self.entnum * 2.7);
            jitter_z = 0;
            setorigin(self, self.origin + jitter);
            self.effects = self.effects & ~RENDERFX_JITTER_FLAG;
            jitter_applied = 1;
        }
    }

    addentity(self);

    if (jitter_applied)
        setorigin(self, saved_origin_for_jitter);

    return PREDRAW_NEXT;
};

// Client-side door/button fields
.float  rendermode;     // GoldSrc 0..5 — server already folded the
                        //   alpha/effects effect into the wire bytes
                        //   above; CSQC reads the mode purely so it
                        //   can decide whether to apply rendercolor
                        //   as a colormod tint.
.vector rendercolor;    // 0..255-component RGB tint key
.float  is_aaatrigger;  // wire flag — set when the brush is fully
                        //   AAATRIGGER-textured; cl_aaatrigger gate
.float  wire_nonsolid;  // wire flag — server has self.solid==SOLID_NOT
                        //   (func_water / func_illusionary / etc.)
.float brush_type;      // BRUSH_TYPE_*
.float mover_state;     // MOVER_STATE_*
.float brush_is_rotating; // TRUE for func_door_rotating / func_rotating
.vector pos1;           // closed/bottom position
.vector pos2;           // open/top position
.float speed;           // movement speed
.float door_locked;     // TRUE if door has DOOR_LOCKED spawnflag
.float door_toggles;    // TRUE when the door carries TOGGLE (32).  Only a TOGGLE
                        // door closes on a re-press from TOP; every other door
                        // ignores the press server-side, so predicting the close
                        // animates a transition that is never confirmed.
.float brush_material;  // BREAKABLE_* code (0 = default/concrete);
                        // read by Impact_ClassifyLocal for per-surface
                        // particle effects on the local shooter.
.float brush_health;    // Current HP of breakable brushes, snapshotted
                        // from server on every damaging shot. CSQC
                        // subtracts predicted damage against this to
                        // decide whether a shot would break the brush.
.float brush_max_health;  // Original max HP; used by CSQC gib spawn to
                          // scale debris-piece damage/count on predicted
                          // breaks (matches server's BreakableSpawnDebris).
.float brush_cnt;         // Mapper/spawn-default gib count. Mirrors
                          // self.cnt on the server breakable.
// .brush_instant_melee (GoldSrc SF_BREAK_CROWBAR) is declared in
// shared/sh_customdefs.qc — sh_weapon_logic.qc compiles long before this file
// and is where the melee path reads it.
.float brush_broken_predicted;  // Local flag: the shooter predicted a
                                // break on this brush. Gates duplicate
                                // predicted break sounds until the next
                                // server snapshot either confirms
                                // (broken=1) or corrects (health>0).
.float brush_broken_confirmed;  // Server-side truth: set when either
                                // CSQC_EVENT_BRUSH_DESTROY arrives or a
                                // solid_brush snapshot has broken=1. The
                                // prediction-timeout in cl_bulletimpact
                                // checks this before un-hiding a brush,
                                // so a slow-but-real server confirmation
                                // doesn't get clobbered.

// Use impulse constant (must match server's CheckImpulses case)
const float USE_IMPULSE = 11;

// Use trace distance (must match server's PLAYER_USE_TRACE_LENGTH)
const float CSQC_USE_TRACE_LENGTH = 96;

// ============================================================
//  Brush sync update (called by engine when server sends entity)
// ============================================================

void() CSQC_SolidBrush_Update =
{
    // SNAP-JUMP CAPTURE.  Compute the UNCLAMPED extrap of where the
    // brush "should be" at cltime using the PREVIOUS snapshot's
    // anchor + velocity.  Below, after we apply the new authoritative
    // values, we accumulate (post - pre) into
    // brush_snap_origin_cumulative / brush_snap_yaw_cumulative so
    // carried players can consume the delta in PM_CheckMovingPushers.
    //
    // Using self.origin / self.angles_y for the "pre" would mix in:
    //   - predraw's cl_brushsync_lookahead clamp (caps extrap distance)
    //   - engine MOVETYPE_NOCLIP integration timing
    //   - whatever last frame's render order produced
    // …none of which are tied to the carry math.  The carry's
    // velocity-based delta on the player is UNCLAMPED (rb.velocity *
    // pm_frametime), so the snap_jump must represent the same
    // "predicted vs authoritative" gap the player accrued — not a
    // visual catch-up the player never simulated.  Using unclamped
    // extrap math here gives a snap_jump of ~0 in the constant-V case
    // even if the brush's visible position was lookahead-clamped.
    // It only becomes non-zero when the server actually changed
    // velocity mid-snap-interval, which is exactly the lurch we
    // want to capture.
    //
    // First snap (csqc_snap_time == 0): use 0 for the delta — no
    // history to extrapolate from, no carried players yet anyway.
    vector t_pre_snap_origin;
    float  t_pre_snap_yaw;
    if (self.csqc_snap_time > 0)
    {
        float t_pre_elapsed = cltime - self.csqc_snap_time;
        t_pre_snap_origin = self.csqc_snap_origin + self.velocity * t_pre_elapsed;
        t_pre_snap_yaw    = self.csqc_snap_angles_y;
        if (self.csqc_snap_time_prev > 0)
        {
            float t_snap_dt = self.csqc_snap_time - self.csqc_snap_time_prev;
            if (t_snap_dt > 0.001)
            {
                float t_yaw_diff = self.csqc_snap_angles_y - self.csqc_snap_angles_prev_y;
                if (t_yaw_diff > 180)  t_yaw_diff = t_yaw_diff - 360;
                if (t_yaw_diff < -180) t_yaw_diff = t_yaw_diff + 360;
                float t_yaw_rate = t_yaw_diff / t_snap_dt;
                t_pre_snap_yaw = t_pre_snap_yaw + t_yaw_rate * t_pre_elapsed;
            }
        }
    }
    else
    {
        // Sentinel — accumulate zero on first snap.
        t_pre_snap_origin = '0 0 0';
        t_pre_snap_yaw    = 0;
    }

    float mdlindex;
    vector org, ang, emins, emaxs, vel;
    float alpha_value;
    float effect_flags;
    float btype;
    float sv_state;

    // Server writes the precache index (readshort) instead of the model
    // path — setmodelindex below resolves it back.
    mdlindex = readshort();
    org = readvector();
    ang = readvector();
    emins = readvector();
    emaxs = readvector();
    // alpha byte biased 0..255 → 0..1 float; effects packed into short.
    alpha_value  = readbyte() * (1.0 / 255.0);
    effect_flags = readshort();
    // GoldSrc rendermode + rendercolor.  Server already folded the
    // mode-specific behaviour into the alpha / effects bytes above
    // (additive blend, glow, alpha-test) — rendercolor is the only
    // piece that doesn't fit there, so we apply it as colormod.
    self.rendermode = readbyte();
    vector rcol;
    rcol_x = readbyte();
    rcol_y = readbyte();
    rcol_z = readbyte();
    self.rendercolor = rcol;
    // GoldSrc renderfx — animation enum (see shared/sh_renderfx.qc).
    // 0 = no effect (steady state, identity in BrushSync_ApplyRenderFX).
    // Server bounds to 0..16 on send.  On first sight with a non-zero
    // value, latch the cltime as the animation epoch so two clients
    // see steady-state effects (pulses, strobes) in sync.
    float new_renderfx = readbyte();
    if (new_renderfx > 0 && self.renderfx == 0)
        self.renderfx_spawn = cltime;
    self.renderfx = new_renderfx;
    // GoldSrc alternate-texture selector — see the long note at the matching
    // WriteByte in server/sv_brushsync.qc.  Nothing else is needed on this side:
    // .frame is a standard engine field, these entities already draw with
    // MASK_ENGINE, and pr_csqc.c:471 copies it straight into the framestate the
    // renderer reads.  THE POSITION OF THIS READ IS LOAD-BEARING — the delta is
    // an untagged positional stream, so this must stay exactly where its
    // WriteByte is, and both VMs must be rebuilt together.
    self.frame = readbyte();
    self.is_aaatrigger = readbyte();
    // Server-intent non-solid bit — TRUE when self.solid == SOLID_NOT
    // on the server.  Without this CSQC always forced SOLID_BSP for
    // brushsync entities, so a non-solid brush (func_water,
    // func_illusionary, PASS_THROUGH doors) collided locally even
    // though the server didn't.  Stored on the entity so the solid
    // assignment further down can OR it in.
    self.wire_nonsolid = readbyte();
    // Contents override (server sends the magnitude of a negative .skin; 0 = none).
    // Applying it is what keeps a func_water SOLID_BSP on the client WITHOUT it
    // being a wall — the engine reads .skin < 0 on a brush entity as "this volume
    // is water/slime/lava", and a trace's contents mask never includes those, so
    // nothing collides with it.  Prediction needs the brush present and marked,
    // not absent: PM_ContentsAt has to find the same water the server does or the
    // client won't predict swimming and every stroke reconciles.
    float wire_contents = readbyte();
    self.skin = (wire_contents > 0) ? (0 - wire_contents) : 0;
    if (self.rendermode == 3 || self.rendermode == 5)
    {
        // Glow / Additive: the engine renders these additively (black drops out,
        // so a light-ray-on-black texture glows) but IGNORES entity .alpha on a
        // brush model — so renderamt can't dim them through alpha.  GoldSrc scales
        // additive BRIGHTNESS by renderamt, so fold it into colormod instead
        // (colormod IS honoured on additive brushes): rendercolor tints (default
        // white), all scaled by renderamt (alpha_value).  renderamt 0 -> invisible,
        // matching GoldSrc (mappers set renderamt explicitly for additive modes).
        vector tint;
        if (rcol != '0 0 0')
            tint = rcol / 255;
        else
            tint = '1 1 1';
        self.colormod = tint * alpha_value;
    }
    else if (self.rendermode == 1)
    {
        // Color (non-additive): .alpha drives the translucency, colormod just
        // tints — apply rendercolor when the mapper set one (default neutral).
        if (rcol != '0 0 0')
            self.colormod = rcol / 255;
        else
            self.colormod = '1 1 1';
    }
    else if (self.rendermode == 0 && rcol != '0 0 0')
    {
        // Extension over strict HL: rendermode 0 (Normal) with a
        // non-zero rendercolor tints the brush via colormod while
        // keeping the texture visible and solid.  Mirrors the
        // server-side path in BrushSync_ApplyRenderKeys.  Quake
        // palette textures, BSP textures, and modern shaders all
        // honour colormod the same way (per-vertex multiply on the
        // lit output).
        self.colormod = rcol / 255;
    }
    else
    {
        self.colormod = '1 1 1';
    }
    vel = readvector();
    // Angular velocity (func_door_rotating).  Stored on the
    // entity so the predraw below can spin self.angles at render
    // frame cadence — without that the door only updates its
    // angles on snapshot arrivals and the rotation reads as
    // discrete steps.  Sliding brushes ship zero here.
    vector avel;
    avel = readvector();
    self.avelocity = avel;
    // Hook the predraw whenever the brush is in motion — rotating
    // (avel) for the angles extrapolator, OR translating (vel) for
    // the dest-overshoot clamp — OR has a non-zero renderfx so the
    // animation evaluator runs each render frame.  Static brushes
    // with no renderfx leave .predraw at __NULL__ so the engine
    // takes its default render path with no QC overhead per frame.
    if (avel != '0 0 0' || vel != '0 0 0' || self.renderfx > 0)
        self.predraw = CSQC_SolidBrush_Predraw;
    else
        self.predraw = __NULL__;

    btype = readbyte();
    self.brush_is_rotating = readbyte();

    // Publish into the shared rotating-brush list so PM_CheckRotatingCarry
    // can mirror the server's carry math during pmove.  Idempotent —
    // the helper checks for a duplicate before linking.  Toggle off
    // when avelocity returns to zero so a stopped brush doesn't keep
    // showing up in the carry walk.
    //
    // ...EXCEPT a TRAIN or VEHICLE brush, which must never be on this list:
    // PM_CheckMovingPushers' train branch already orbits the rider by the
    // brush's own yaw delta (sh_pmove.qc:3952-4015), so a brush on BOTH lists
    // gets its rotation applied to the player TWICE per pmove substep.
    //
    // func_platrot is the class that has both, and it is the reported "the
    // player rotates 2x the amount, the rotation is being doubled up" on
    // hl_c01_a1's `ele_2`.  The server half of this lives in Plat_RotStart
    // (sv_goldsrc_compat.qc), but fixing it there alone would have changed
    // nothing here: THIS list is rebuilt purely from the wire's avelocity and
    // never mirrors the server's membership, so both halves are needed.
    //
    // Reading btype first is why those two lines moved above this block — the
    // brush type arrives after the velocities in the wire, and the decision
    // cannot be made without it.
    if (avel != '0 0 0'
     && btype != BRUSH_TYPE_TRAIN && btype != BRUSH_TYPE_VEHICLE)
        RotatingBrush_AddToList(self);
    else
        RotatingBrush_RemoveFromList(self);

    sv_state = 0;
    if (btype == BRUSH_TYPE_CONVEYOR)
    {
        self.movedir = readvector();
        self.speed   = readfloat();
        self.spawnflags = readfloat();
        // Add to conveyor_list (idempotent — checked inside).
        Conveyor_AddToList(self);
    }
    else if (btype == BRUSH_TYPE_DOOR || btype == BRUSH_TYPE_BUTTON)
    {
        self.pos1  = readvector();
        self.pos2  = readvector();
        self.speed = readfloat();
        sv_state   = readbyte();
        self.door_locked = readbyte();
        self.door_toggles = readbyte();	// order MUST match sv_brushsync.qc

        // Publish into the shared linear-motion list while the brush
        // is in transit (non-zero velocity).  PM_CheckMovingPushers
        // reads this list to predict the server-side
        // Mover_GeometryBlockPush pass, eliminating the snapshot-
        // reconcile delay on door push.
        if (vel != '0 0 0')
            MovingBrush_AddToList(self);
        else
            MovingBrush_RemoveFromList(self);
    }
    else if (btype == BRUSH_TYPE_TRAIN || btype == BRUSH_TYPE_VEHICLE)
    {
        // No extra wire fields for trains / vehicles — origin / angles /
        // velocity / avelocity are already in the shared brushsync header
        // above (a func_vehicle's live steering rides avelocity_y).
        // Add to moving_brush_list while in transit so the train
        // branch of PM_CheckMovingPushers can run the carry +
        // geometry-push pass against the local predicted player every
        // pmove tick.  This is what eliminates the jump-lurch and
        // landing-snap that the server-only carry left behind.
        if (vel != '0 0 0')
            MovingBrush_AddToList(self);
        else
            MovingBrush_RemoveFromList(self);
    }

    // Material byte (BREAKABLE_*). 0 for non-breakable brushes. Read by
    // Impact_ClassifyLocal in cl_bulletimpact.qc.
    self.brush_material = readbyte();

    // Current HP of the breakable. Used by CSQC_BulletImpact to decide
    // whether the attacker's predicted damage would break the brush.
    self.brush_health     = readshort();
    self.brush_max_health = readshort();
    self.brush_cnt        = readbyte();

    // Flag byte.
    //   bit 0 — broken.  func_breakable sets this when destroyed and clears it
    //           on round restart.  Client flips drawmask/solid instead of
    //           remove()-ing, so the entity slot survives for the next round.
    //   bit 1 — BREAKABLE_INSTANT_CROWBAR (GoldSrc SF_BREAK_CROWBAR).  Needed
    //           here because the client's breakclaim is what actually spends
    //           the brush's HP under the default sv_trust_clientbreak 1.
    float brushflags = readbyte();
    float broken = brushflags & 1;
    self.brush_instant_melee    = (brushflags & 2) ? 1 : 0;
    self.brush_broken_confirmed = broken;

    // Clear the predicted-break flag ONLY when the server resets the
    // brush to full HP — the unambiguous "round restart" / initial-spawn
    // signal (server-side health can only monotonically decrease via
    // damage, so any partial HP value is the server catching up to our
    // predicted damage rather than contradicting it). Preserving the
    // flag across catch-up snapshots prevents the brush from briefly
    // reappearing between "server processed shot 1" and "server processed
    // shot 2" at high ping + rapid fire — CSQC locked in the break at
    // shot 2 and shouldn't un-hide just because an intermediate partial
    // HP value arrives.
    if (!broken && self.brush_max_health > 0 && self.brush_health >= self.brush_max_health)
        self.brush_broken_predicted = 0;

    // Always setmodelindex — the conditional "only on model change"
    // variant left the render binding stale after a drawmask=0 →
    // drawmask=MASK_ENGINE transition (breakable reset), so the brush
    // stayed invisible even though the model index hadn't changed. An
    // unconditional rebind on every snapshot is cheap (model is already
    // precached by virtue of being in the BSP submodel list) and reliable.
    setmodelindex(self, mdlindex);
    setsize(self, emins, emaxs);

    // Keep the brush hidden if EITHER the server confirmed broken OR we
    // predicted a break locally that hasn't been rolled back by a full-HP
    // reset. The brush_broken_predicted gate is what stops catch-up
    // snapshots (broken=0, partial HP) from briefly un-hiding a brush
    // the attacker already saw shatter.
    float hide = (broken || self.brush_broken_predicted);
    // cl_aaatrigger 0 hides AAATRIGGER-textured func_ brushes.  Only
    // visibility is gated — solidity is left intact so the brush
    // still blocks the player exactly as the server's pmove sees it,
    // matching HL behaviour for clip / trigger placeholder brushes.
    float aaa_hide = (self.is_aaatrigger && !cvar("cl_aaatrigger"));

    // GoldSrc "FX Amount 0" means INVISIBLE for every non-Normal rendermode
    // (HL SDK const.h: kRenderTransAdd is src*a+dest, so a=0 contributes
    // nothing).  We cannot express that through .alpha or .colormod, because
    // FTE's CSQC->renderer copy treats an exact zero in either as "the field
    // was never set" and substitutes the opaque default:
    //     pr_csqc.c  if (!in->xv->alpha || in->xv->alpha == 1)
    //                    out->shaderRGBAf[3] = 1.0f;            // 0 -> OPAQUE
    //     pr_csqc.c  if (!colormod[0] && !colormod[1] && !colormod[2])
    //                    VectorSet(out->shaderRGBAf, 1,1,1);    // 0 -> WHITE
    // and r_surf.c forces BEF_FORCEADDITIVE for an RF_ADDITIVE brush model
    // regardless of alpha (RF_TRANSLUCENT is only an `else if`).  So both
    // dimming levers above collapse at exactly the value that should hide the
    // brush, and rendermode 5 + no renderamt rendered as an opaque FULL-WHITE
    // additive slab — the most visible result possible.  pizza_ya_san1 uses
    // that idiom for invisible-but-solid barriers (func_wall "*11",
    // func_wall_toggle "wlt_komugiarea"), which showed up as solid walls.
    float fx_hide = (alpha_value <= 0
                     && (self.rendermode == 1      // Color
                      || self.rendermode == 2      // Texture
                      || self.rendermode == 3      // Glow
                      || self.rendermode == 5));   // Additive

    // EF_NODRAW is likewise inert on a CSQC-drawn entity: the engine honours
    // it only for legacy NETWORK entities (cl_ents.c), and
    // CopyCSQCEdictToEntity reads just FULLBRIGHT / ADDITIVE / NOSHADOW /
    // NODEPTHTEST out of .effects — there is no NODRAW case.  So
    // func_wall_toggle_hide()'s EF_NODRAW made the brush non-solid but left it
    // fully drawn.  Honour it here, where drawmask actually works.
    float nodraw_hide = (effect_flags & EF_NODRAW);

    self.movetype    = MOVETYPE_NOCLIP;
    // SOLID_NOT when EITHER the brush is hidden (broken / predicted-
    // broken) OR the server explicitly marked it non-solid (func_water,
    // func_illusionary, PASS_THROUGH doors).  Forcing SOLID_BSP here
    // unconditionally — which is what we used to do — caused the
    // client's pmove to collide with brushes the server lets you walk
    // through, producing rubberbanding when reconciliation snapped the
    // player back into the empty space the server says they should be.
    self.solid       = (hide || self.wire_nonsolid) ? SOLID_NOT : SOLID_BSP;
    // drawmask 0 is the mod's established hide-but-stay-solid idiom (see
    // aaa_hide above); solidity is assigned separately on the line above, so a
    // hidden brush still blocks — which is the whole point of the GoldSrc
    // invisible-clip idiom.  Caveat, shared with the pre-existing aaa_hide
    // path: addentities gates CSQC_SolidBrush_Predraw on the same drawmask, so
    // a hidden MOVING brush loses the client-side origin-overshoot clamp and
    // rides on server snapshots alone.  Invisible movers are rare and the
    // snapshots still correct them, so this is the right trade.
    self.drawmask    = (hide || aaa_hide || fx_hide || nodraw_hide) ? 0 : MASK_ENGINE;
    self.angles      = ang;
    self.alpha       = alpha_value;
    self.effects     = effect_flags;

    // Snapshot the BASE (un-modulated) alpha/colormod/effects so the
    // predraw can re-evaluate renderfx each frame from a stable origin.
    // Without this latch, applying renderfx in predraw would feed the
    // modulated value back into itself the next frame and decay.
    self.renderfx_base_alpha    = self.alpha;
    self.renderfx_base_colormod = self.colormod;
    self.renderfx_base_effects  = self.effects;

    if (self.brush_type == btype
        && (btype == BRUSH_TYPE_DOOR || btype == BRUSH_TYPE_BUTTON)
        && !self.brush_is_rotating
        && self.mover_state == sv_state
        && (sv_state == MOVER_STATE_UP || sv_state == MOVER_STATE_DOWN))
    {
        // Server and client agree on direction — keep whichever position
        // is further along toward the destination.
        vector dest;
        if (sv_state == MOVER_STATE_UP)
            dest = self.pos2;
        else
            dest = self.pos1;

        float server_dist = vlen(dest - org);
        float client_dist = vlen(dest - self.origin);

        if (client_dist < server_dist)
            self.velocity = vel;   // client ahead — keep position
        else
        {
            self.velocity = vel;
            setorigin(self, org);
        }
    }
    else
    {
        // Server disagrees or static brush — accept server state fully.
        // This corrects mispredictions where the client started a mover
        // the server never activated.
        self.velocity    = vel;
        self.mover_state = sv_state;
        setorigin(self, org);
    }

    self.brush_type = btype;

    // Anchor the predraw projector at this snapshot's angles +
    // origin + arrival time.  Predraw projects forward from here at
    // velocity (translation) and a snapshot-differentiated rate
    // (angles for tracktrains that have no avelocity), capped to
    // cl_brushsync_lookahead so the extrapolation can't overshoot
    // far past the next snapshot's authoritative state.
    //
    // Roll the previous anchors forward to compute a derivative rate
    // for the train-angle extrapolator (yaw isn't shipped as
    // avelocity for tracktrains; we differentiate snap-to-snap to
    // get an instantaneous rate the predraw can extrapolate with).
    self.csqc_snap_angles_prev = self.csqc_snap_angles;
    self.csqc_snap_time_prev   = self.csqc_snap_time;

    self.csqc_snap_angles = self.angles;
    self.csqc_snap_origin = self.origin;
    self.csqc_snap_time   = cltime;

    // SNAP-JUMP ACCUMULATE (trains only — the carry mechanism that
    // consumes this only runs on BRUSH_TYPE_TRAIN).  In the
    // constant-velocity case t_pre_snap_origin ≈ self.origin (the
    // unclamped extrap matches the authoritative position), so the
    // per-snap delta is ≈ 0 and player carry is unaffected.  At a
    // velocity change the extrap diverges by exactly the amount of
    // motion the player's velocity-based pmove missed because CSQC
    // didn't know about the new velocity yet — recorded here so the
    // carry block can apply it next substep.  Skipped on the very
    // first snap (no previous anchor to extrap from).
    if ((btype == BRUSH_TYPE_TRAIN || btype == BRUSH_TYPE_VEHICLE) && self.csqc_snap_time_prev > 0)
    {
        self.brush_snap_origin_cumulative = self.brush_snap_origin_cumulative
                                          + (self.origin - t_pre_snap_origin);
        float t_jump_yaw_diff = self.angles_y - t_pre_snap_yaw;
        if (t_jump_yaw_diff > 180)  t_jump_yaw_diff = t_jump_yaw_diff - 360;
        if (t_jump_yaw_diff < -180) t_jump_yaw_diff = t_jump_yaw_diff + 360;
        self.brush_snap_yaw_cumulative = self.brush_snap_yaw_cumulative + t_jump_yaw_diff;
    }

    // Post-update diagnostic — shows final state after parsing, so we can
    // see if the server sent a bogus origin or model for a breakable.
    if (cvar("sv_debug_ent_types"))
    {
        print(sprintf("  [brush %g] model='%s' origin=%v mins=%v maxs=%v btype=%g mat=%g\n",
                      self.entnum, self.model, self.origin, self.mins, self.maxs,
                      self.brush_type, self.brush_material));
    }
};

// ============================================================
//  Client-side door/button prediction
// ============================================================

// Start a mover moving toward a destination (client-side equivalent of Mover_Start)
void(entity ent, vector destination) CSQC_MoverPredict =
{
    vector delta;
    float distance;

    delta    = destination - ent.origin;
    distance = vlen(delta);

    if (distance <= 0 || ent.speed <= 0)
    {
        ent.velocity = '0 0 0';
        setorigin(ent, destination);
        return;
    }

    ent.velocity = delta * (ent.speed / distance);

    // ARM THE ARRIVAL CLAMP.  The replica is MOVETYPE_NOCLIP, so the engine
    // integrates origin += velocity * frametime every render frame and the
    // ONLY thing that ever stops it is the overshoot clamp inside
    // CSQC_SolidBrush_Predraw.  That predraw is otherwise installed only by
    // the snapshot handler, gated on the SERVER-reported velocity — and a
    // resting brush's last snapshot had velocity 0, so a locally-predicted
    // move had no predraw and no clamp at all.
    //
    // Symptom when this is missing: press a button the server then refuses
    // (locked master, mp_disabledoors, or simply an aim mismatch) and the
    // client brush slides away across the map forever, because a refusal
    // sets no SendFlags and PVSF_NOREMOVE means no corrective snapshot ever
    // arrives.  This is exactly the pizza_ya_san1 `ml_startobj` report.
    //
    // Its rotating twin CSQC_RotateMoverPredict has always done this.
    ent.csqc_snap_origin = ent.origin;
    ent.csqc_snap_time   = cltime;
    ent.predraw          = CSQC_SolidBrush_Predraw;
    MovingBrush_AddToList(ent);
};

void(entity ent, vector dest_angles) CSQC_RotateMoverPredict =
{
    vector delta = dest_angles - ent.angles;
    float distance = vlen(delta);

    if (distance <= 0 || ent.speed <= 0)
    {
        ent.angles = dest_angles;
        ent.avelocity = '0 0 0';
        ent.csqc_snap_angles = ent.angles;
        ent.csqc_snap_time = cltime;
        RotatingBrush_RemoveFromList(ent);
        return;
    }

    float travel = distance / ent.speed;
    ent.avelocity = delta * (1.0 / travel);
    ent.csqc_snap_angles = ent.angles;
    ent.csqc_snap_time = cltime;
    ent.predraw = CSQC_SolidBrush_Predraw;
    RotatingBrush_AddToList(ent);
};

// Predict a single door or button activation (client-side equivalent of
// door_go_up / button_fire).  Does NOT handle door groups — groups are
// corrected when the server snapshot arrives.
void(entity hit) CSQC_PredictMoverActivate =
{
    // Bhop gamemode: server clears door/button .use/.touch/.blocked so the
    // brush is inert (sv_doors.qc spawn paths). If we predicted locally
    // anyway, the server would never move the brush, never dirty its
    // SendFlags, never snapshot a "you got it wrong" — the predicted
    // open/closed state would stick on the client until map change.
    // Treat bhop +use on a brush as a no-op to match server.
    if (getstatf(STAT_GAMEMODE) == GAMEMODE_BHOP)
        return;

    // Already moving? Don't re-trigger (matches server guard)
    if (hit.mover_state == MOVER_STATE_UP || hit.mover_state == MOVER_STATE_DOWN)
        return;

    if (hit.mover_state == MOVER_STATE_BOTTOM)
    {
        hit.mover_state = MOVER_STATE_UP;
        if (hit.brush_is_rotating)
            CSQC_RotateMoverPredict(hit, hit.pos2);
        else
            CSQC_MoverPredict(hit, hit.pos2);
    }
    else if (hit.mover_state == MOVER_STATE_TOP)
    {
        // Buttons return on their own timer — server rejects re-activation
        // from TOP state (button_fire guards against UP/TOP).  Only doors
        // can be toggled back from TOP.
        if (hit.brush_type == BRUSH_TYPE_BUTTON)
            return;

        // ...and of those, ONLY a TOGGLE door.  Door_ActivateSingle
        // (sv_doors.qc:1063) closes from TOP only when DOOR_TOGGLE is set;
        // rotdoor_use (sv_doors_rotating.qc:906) does the same with
        // DOORROT_TOGGLE.  A non-TOGGLE door parked at TOP — the mapper's
        // `wait -1` "stay open" — is never going to close, so predicting it
        // starts a rotation the server never confirms: the predraw's 0.05s
        // mover-state lookahead cap (line 185) freezes the brush a few degrees
        // shut, no snapshot arrives to correct it because a refused press
        // dirties no SendFlags, and the replica keeps a non-zero avelocity on
        // the rotating-brush list so PM_CheckRotatingCarry shoves anyone who
        // walks into it.  That is the reported "closes for one frame, stops,
        // and acts buggy on touch".
        // The predicate is TOGGLE, NOT the "One Way" flag: ONE_WAY (16, HL
        // SF_DOOR_ONEWAY, doors.cpp:590) only restricts which way the door
        // swings and says nothing about whether it can close.  On th_ep1_01
        // three of the twelve affected doors do not carry it at all.
        if (!hit.door_toggles)
            return;

        hit.mover_state = MOVER_STATE_DOWN;
        if (hit.brush_is_rotating)
            CSQC_RotateMoverPredict(hit, hit.pos1);
        else
            CSQC_MoverPredict(hit, hit.pos1);
    }
};

// Forward decl from cl_weapons.qc (compiled later in cl_progs.src).
void(entity w) CSQC_PredictPickupWeapon;

// Try to predict door/button activation OR weapon pickup via +use trace.
// Called from CSQC_PredictWeaponCommand context (self = predicted_player).
// Matches the server's SV_PlayerTryUse: tracebox first, then cone fallback.
void() CSQC_PredictUse =
{
    vector use_start, use_end;
    entity hit, best, e, w, best_w;
    float best_dot, dot, w_best_dot;

    makevectors(input_angles);
    use_start = self.origin + self.view_ofs;
    use_end   = use_start + v_forward * CSQC_USE_TRACE_LENGTH;

    // Match the server EXACTLY: sv_use.qc's primary probe is a traceline, not
    // a fat tracebox.  The old comment here claimed otherwise and was wrong,
    // and on a small brush the difference is a live mispredict: an 8-unit-wide
    // button is hit by a +-8 client hull at aim angles where the server's
    // centre line misses entirely, so the client predicts a press the server
    // never sees.
    traceline(use_start, use_end, MOVE_NORMAL, self);

    hit = trace_ent;
    if (hit && hit != world
        && (hit.brush_type == BRUSH_TYPE_DOOR || hit.brush_type == BRUSH_TYPE_BUTTON))
    {
        // door_locked is the server's predict_block byte and it is sent for
        // BUTTONS too (mastered buttons, and GoldSrc doors that refuse +use).
        // Restricting this test to doors meant a mastered button predicted an
        // open the server was always going to reject.
        if (hit.door_locked)
            return;
        CSQC_PredictMoverActivate(hit);
        return;
    }

    // Cone fallback: pick the closest-aligned usable entity (matches server)
    best = world;
    best_dot = 0.7;
    e = findradius(use_start, CSQC_USE_TRACE_LENGTH);
    while (e)
    {
        if (e != self
            && (e.brush_type == BRUSH_TYPE_DOOR || e.brush_type == BRUSH_TYPE_BUTTON)
            && !e.door_locked)      // applies to buttons too — see above
        {
            // Rank by AABB MIDPOINT, not .origin.  A GoldSrc brush entity
            // compiled without an ORIGIN brush keeps .origin == '0 0 0' —
            // its world position lives entirely in the baked BSP submodel —
            // so ranking on .origin scored every Half-Life func_door /
            // func_button as if it sat at the map origin, and the cone could
            // never select one.  This must stay identical to the server's
            // SV_PlayerTryUse cone (sv_use.qc) or the two sides predict
            // different doors.  It also matches findradius's own selection
            // basis, which measures to origin + (mins+maxs)*0.5.
            vector to_e = ((e.absmin + e.absmax) * 0.5) - use_start;
            if (vlen(to_e) < 0.01) { e = e.chain; continue; }   // standing inside it
            dot = normalize(to_e) * v_forward;
            if (dot > best_dot)
            {
                best_dot = dot;
                best = e;
            }
        }
        e = e.chain;
    }

    // Dropped-weapon scan — proxies are SOLID_NOT so the tracebox above
    // can't hit them (otherwise the local player would also collide with
    // them on walk-through). Walk dropped_weapon_list and pick the best
    // cone-aligned one. Mirrors the server's combined cone in SV_PlayerTryUse.
    //
    // Two acceptance paths so +use grabs match the server:
    //   1. Cone-aligned + within use trace length (matches server's
    //      findradius cone fallback).
    //   2. Player bbox overlapping the WEAPON_PICKUP_* zone (matches
    //      server's tracebox direct hit for phys-drops, which sit in
    //      SOLID_PHYSICS_TRIMESH and would be hit by the server's
    //      forward tracebox even if not perfectly cone-aligned).
    // Either path lets the predict succeed; cone alignment still ranks
    // for tie-breaking when several drops are close together.
    vector pmins = self.origin + self.mins;
    vector pmaxs = self.origin + self.maxs;

    best_w = world;
    w_best_dot = 0.7;
    w = dropped_weapon_list;
    float guard = 0;
    while (w)
    {
        entity nxt = w.dropped_weapon_next;
        guard = guard + 1;
        if (guard > 4096) break;

        if (!w.dropped_weapon_predicted_taken
            && cltime >= w.dropped_weapon_pickup_time)
        {
            float in_zone = FALSE;
            vector zmins = w.origin + [-(WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                       -(WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                       -(WEAPON_PICKUP_HEIGHT_DN + WEAPON_PICKUP_PAD)];
            vector zmaxs = w.origin + [ (WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                        (WEAPON_PICKUP_HALF_W + WEAPON_PICKUP_PAD),
                                        (WEAPON_PICKUP_HEIGHT_UP + WEAPON_PICKUP_PAD)];
            if (pmaxs_x >= zmins_x && pmins_x <= zmaxs_x
             && pmaxs_y >= zmins_y && pmins_y <= zmaxs_y
             && pmaxs_z >= zmins_z && pmins_z <= zmaxs_z)
                in_zone = TRUE;

            float in_cone = FALSE;
            dot = 0;
            if (vlen(use_start - w.origin) < CSQC_USE_TRACE_LENGTH)
            {
                dot = normalize(w.origin - use_start) * v_forward;
                if (dot > 0.7)
                    in_cone = TRUE;
            }

            if (in_zone || in_cone)
            {
                // Cone-dot is the ranking key; in_zone-only entries get
                // a synthetic "perfect" alignment so a weapon you're
                // standing on outranks a weapon down the cone.
                float rank = in_zone ? 1.0 : dot;
                if (rank > w_best_dot)
                {
                    w_best_dot = rank;
                    best_w = w;
                }
            }
        }
        w = nxt;
    }

    // Whichever (door/button vs weapon) is most centered wins. If both
    // tied near the threshold, weapon pickup gets priority — matches the
    // intuition that a weapon at your feet is the obvious target.
    if (best_w && (best == world || w_best_dot >= best_dot))
        CSQC_PredictPickupWeapon(best_w);
    else if (best)
        CSQC_PredictMoverActivate(best);
};

// Proximity door prediction removed — iterating all entities per frame
// caused runaway loop errors. Touch-triggered doors will open with the
// server's normal latency. Use-triggered doors (+use) are predicted
// instantly via CSQC_PredictUse traceline above.
