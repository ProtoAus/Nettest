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
.float  has_custom_pivot;
.float  pivot_bbox_radius;
.vector pos1;
.vector pos2;
.vector custom_pivot;
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

vector(vector pt, float deg, float ax_idx) CSQC_Brush_RotateFromWorldOrigin =
{
    float rad = deg * 0.017453293;
    float c = cos(rad);
    float s = sin(rad);
    vector r;

    if (ax_idx == 0)
    {
        r_x = pt_x * c + pt_z * s;
        r_y = pt_y;
        r_z = -pt_x * s + pt_z * c;
    }
    else if (ax_idx == 2)
    {
        r_x = pt_x;
        r_y = pt_y * c - pt_z * s;
        r_z = pt_y * s + pt_z * c;
    }
    else
    {
        r_x = pt_x * c - pt_y * s;
        r_y = pt_x * s + pt_y * c;
        r_z = pt_z;
    }

    return r;
};

void(entity ent) CSQC_Brush_ApplyCustomPivotOrigin =
{
    if (!ent.has_custom_pivot)
        return;

    float ax = CSQC_Brush_RotationAxis(ent);
    float deg = ent.angles_y;
    if (ax == 0)      deg = ent.angles_x;
    else if (ax == 2) deg = ent.angles_z;

    vector rp = CSQC_Brush_RotateFromWorldOrigin(ent.custom_pivot, deg, ax);
    setorigin(ent, ent.custom_pivot - rp);

    // Re-anchor the SOLID_BBOX cube on the pivot each frame.  See the
    // engine-quirk comment in sv_doors_rotating.qc's Mover_ApplyCustomPivotOrigin
    // for why custom-pivot brushes can't use SOLID_BSP — short version,
    // mod->mins/maxs is in absolute world coords for TrenchBroom exports
    // and the rotation-aware AABB blows up to ~2× the pivot's world
    // distance.  Server ships pivot_bbox_radius once when has_custom_pivot
    // is set; client recomputes mins/maxs = R*P ± r·(1,1,1) per render
    // frame so the cube tracks the interpolated angle.
    if (ent.pivot_bbox_radius > 0)
    {
        float r = ent.pivot_bbox_radius;
        vector rv = '1 1 1' * r;
        setsize(ent, rp - rv, rp + rv);
    }
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
        CSQC_Brush_ApplyCustomPivotOrigin(self);
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
.float has_custom_pivot;  // TRUE when origin_target resolved server-side
.float pivot_bbox_radius; // half-extent of the SOLID_BBOX cube around the pivot
.vector pos1;           // closed/bottom position
.vector pos2;           // open/top position
.vector custom_pivot;    // world-space origin_target pivot
.float speed;           // movement speed
.float door_locked;     // TRUE if door has DOOR_LOCKED spawnflag
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
    self.is_aaatrigger = readbyte();
    // Server-intent non-solid bit — TRUE when self.solid == SOLID_NOT
    // on the server.  Without this CSQC always forced SOLID_BSP for
    // brushsync entities, so a non-solid brush (func_water,
    // func_illusionary, PASS_THROUGH doors) collided locally even
    // though the server didn't.  Stored on the entity so the solid
    // assignment further down can OR it in.
    self.wire_nonsolid = readbyte();
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

    // Publish into the shared rotating-brush list so PM_CheckRotatingCarry
    // can mirror the server's carry math during pmove.  Idempotent —
    // the helper checks for a duplicate before linking.  Toggle off
    // when avelocity returns to zero so a stopped brush doesn't keep
    // showing up in the carry walk.
    if (avel != '0 0 0')
        RotatingBrush_AddToList(self);
    else
        RotatingBrush_RemoveFromList(self);

    btype = readbyte();
    self.brush_is_rotating = readbyte();
    self.has_custom_pivot = readbyte();
    if (self.has_custom_pivot)
    {
        self.custom_pivot = readvector();
        self.pivot_bbox_radius = readcoord();
    }
    else
    {
        self.custom_pivot = '0 0 0';
        self.pivot_bbox_radius = 0;
    }

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

    // Broken flag — func_breakable sets this when destroyed and clears
    // it on round restart. Client flips drawmask/solid instead of
    // remove()-ing, so the entity slot survives for the next round.
    float broken = readbyte();
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
    self.movetype    = MOVETYPE_NOCLIP;
    // SOLID_NOT when EITHER the brush is hidden (broken / predicted-
    // broken) OR the server explicitly marked it non-solid (func_water,
    // func_illusionary, PASS_THROUGH doors).  Forcing SOLID_BSP here
    // unconditionally — which is what we used to do — caused the
    // client's pmove to collide with brushes the server lets you walk
    // through, producing rubberbanding when reconciliation snapped the
    // player back into the empty space the server says they should be.
    // Custom-pivot brushes use SOLID_BBOX (see Mover_ApplyCustomPivotOrigin
    // in sv_doors_rotating.qc).  CSQC_Brush_ApplyCustomPivotOrigin
    // re-aims the cube every render frame so absmin/absmax stays
    // anchored on the pivot regardless of the interpolated angle.
    float wire_solid = self.has_custom_pivot ? SOLID_BBOX : SOLID_BSP;
    self.solid       = (hide || self.wire_nonsolid) ? SOLID_NOT : wire_solid;
    self.drawmask    = (hide || aaa_hide) ? 0 : MASK_ENGINE;
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
        CSQC_Brush_ApplyCustomPivotOrigin(ent);
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

    // Match server: tracebox with expanded hull, not traceline
    tracebox(use_start, '-8 -8 -8', '8 8 8', use_end, MOVE_NORMAL, self);

    hit = trace_ent;
    if (hit && hit != world
        && (hit.brush_type == BRUSH_TYPE_DOOR || hit.brush_type == BRUSH_TYPE_BUTTON))
    {
        if (hit.brush_type == BRUSH_TYPE_DOOR && hit.door_locked)
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
            && !(e.brush_type == BRUSH_TYPE_DOOR && e.door_locked))
        {
            dot = normalize(e.origin - use_start) * v_forward;
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
