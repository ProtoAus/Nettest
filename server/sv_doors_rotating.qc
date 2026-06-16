//
//  sv_doors_rotating.qc  –  func_door_rotating
//
//  Hinge-rotating door — same lifecycle as func_door but the brush
//  spins through a fixed angle around an origin-brush pivot instead
//  of translating along a direction.  Mappers include an ORIGIN-
//  textured brush in the entity to define the pivot; the BSP
//  compiler bakes its centre into self.origin and rotation happens
//  around that point automatically once we set self.angles or
//  self.avelocity.
//
//  Spawnflags reuse the DOOR_* values where the semantic matches:
//    1   START_OPEN    spawn pre-rotated to the open pose
//    2   REVERSE       negate the rotation direction
//    8   PASSABLE      brush is non-solid, no touch trigger
//    16  ONE_WAY       always rotate in the configured direction
//                       (don't auto-flip to open away from player)
//    32  TOGGLE        no auto-close, each press flips state
//    64  X_AXIS        rotate around X (pitch)
//    128 Y_AXIS        rotate around Y (roll)
//                       — default with neither flag is Z (yaw)
//    256 USE_ONLY      target/+use only, no auto proximity trigger
//
//  Keys handled: distance (rotation amount in degrees), speed,
//  wait, dmg, target, targetname, sounds, message.
//

// ---------------------------------------------------------------------------
// Externs from earlier compile units.
// ---------------------------------------------------------------------------
void() SV_InitReplicatedSolidBrush;                                  // sv_brushsync.qc
float(entity attacker, entity target, float damage) W_ApplyDamage;   // sv_weapons.qc
string(float idx) Door_LookupMoveSound;                              // sv_doors.qc
string(float idx) Door_LookupStopSound;                              // sv_doors.qc
string(float idx) Door_LookupLockedSound;                            // sv_doors.qc
string(float idx) Door_LookupUnlockedSound;                          // sv_doors.qc
void(string snd) Door_PrecacheIfReal;                                // sv_doors.qc
void() Door_PlayMoveSound;                                           // sv_doors.qc
void() Door_PlayStopSound;                                           // sv_doors.qc

// Forward decls — sh_pmove.qc compiles AFTER this file in sv_progs.src,
// so the rotating-brush list helpers it defines need to be predeclared
// here for Mover_RotateStart / rotdoor_hit_* to reference them.
void(entity c) RotatingBrush_AddToList;
void(entity c) RotatingBrush_RemoveFromList;

// Shared fields — declared authoritatively in sv_doors.qc.
.float movesnd;
.float stopsnd;
.float locked_sound;
.float unlocked_sound;
.string noise_locked;
.string noise_unlocked;
.float dmg;
// door_state is shared with sv_doors.qc's sliding func_door — we use
// the same DOOR_STATE_* enum.  The constants live in sv_doors.qc; no
// re-declaration needed because constants are global.

const float DOORROT_START_OPEN  = 1;
const float DOORROT_REVERSE     = 2;
const float DOORROT_UNBLOCKABLE = 4;     // grinder mode — no reverse on block, damage per tick
const float DOORROT_PASSABLE    = 8;
const float DOORROT_ONE_WAY     = 16;
const float DOORROT_TOGGLE      = 32;
const float DOORROT_X_AXIS      = 64;
const float DOORROT_Y_AXIS      = 128;
const float DOORROT_USE_ONLY    = 256;

void() rotdoor_go_up;
void() rotdoor_go_down;
void() rotdoor_blocked;

// Per-rotation state stamps.  rotdoor_finish_time / _cb stand in
// for the single-shot self.think Mover_Start uses for sliding doors;
// the rotating mover ticks rotdoor_carry_tick at high frequency so
// it can carry touching players along the rotation arc, only firing
// the move-done callback once self.ltime catches up to finish_time.
.float    rotdoor_finish_time;
.void()   rotdoor_finish_cb;
.float    rotdoor_carry_last_ltime;
// X-axis (pitch) → component 0 of avelocity.
// Y-axis (roll)  → component 2.
// Z-axis (yaw, default) → component 1.
.float    rotdoor_axis_index;
// Last angles snapshot at carry-tick time.  Carry rotates players
// by (current_angles - last_angles) on the active axis so they
// stay locked to the door regardless of mismatch between the
// engine's physics tick and the carry tick rate.
.vector   rotdoor_carry_last_angles;

// Rotate `pt` around `pivot` by `deg` degrees on the given axis
// component (0=pitch/X, 1=yaw/Z, 2=roll/Y per Quake angles
// convention — see the rotation constant comments below).  Used by
// the carry pass to move a player along the door's swung arc.
vector(vector pt, vector pivot, float deg, float axis_idx) RotDoor_RotateAround =
{
    float rad = deg * 0.017453293;
    float c = cos(rad);
    float s = sin(rad);
    vector rel = pt - pivot;
    vector r;

    if (axis_idx == 0)
    {
        // Pitch — rotates in XZ plane (around world Y axis).
        r_x = rel_x * c + rel_z * s;
        r_y = rel_y;
        r_z = -rel_x * s + rel_z * c;
    }
    else if (axis_idx == 2)
    {
        // Roll — rotates in YZ plane (around world X axis).
        r_x = rel_x;
        r_y = rel_y * c - rel_z * s;
        r_z = rel_y * s + rel_z * c;
    }
    else
    {
        // Yaw (default) — rotates in XY plane (around world Z).
        r_x = rel_x * c - rel_y * s;
        r_y = rel_x * s + rel_y * c;
        r_z = rel_z;
    }

    return pivot + r;
};

// Rotation pivot = the brush's BSP-baked origin (from the ORIGIN-
// textured pivot brush).  Used by the carry pass to rotate players
// along the brush's arc.
vector() Mover_RotationPivot =
{
    return self.origin;
};

// Per-tick carry pass.  Finds players whose bbox overlaps the
// door's actual brush volume and rotates their origin around the
// pivot by the same angular delta the engine just applied to the
// door this tick.  If the rotation would clip the player into
// geometry, rotdoor_blocked fires (damage + reverse) — that's how
// the door detects "the player is between me and a wall" without
// relying on the engine's MOVETYPE_PUSH push (which doesn't
// reliably carry along avelocity-driven rotations in FTE).
//
// "In path" check uses the door's LOCAL bbox at the closed pose.
// Reverse-rotating the player's origin into local space and
// AABB-testing against self.mins/maxs gives a tight match to the
// brush's actual slab extent — players standing in the swept fan
// area but not against the leaf get left alone, even though the
// engine's bloated absmin/max would have captured them.
//
// Generic rotation-carry helper.  Any rotating brush (func_rotating,
// func_pendulum, func_door_rotating) can call this once per tick to
// either carry overlapping players along the rotation arc, or report
// that a player is blocking the rotation (couldn't be moved out of
// the way without clipping into geometry).  Caller is responsible
// for the response — halt, reverse, damage, etc.
//
// Caller must have populated:
//   self.avelocity                — non-zero rotation
//   self.rotdoor_carry_last_angles — previous-tick angles snapshot
//   self.rotdoor_axis_index        — 0/1/2 picking the active component
//   self.pos1                      — closed-pose angles (for the
//                                     local-frame bbox test)
//
// Returns 1 if ANY player was blocked (regardless of opening/closing).
// Side effects: setorigin() on each carryable player; sends
// CSQC_EVENT_DOOR_VIEWROT on the active-yaw case so the carried
// player's view tracks the rotation.  Damages stuck players if dmg>0.
float() Brush_RotateCarry =
{
    if (self.avelocity == '0 0 0') return 0;
    vector pivot = Mover_RotationPivot();

    vector ang_delta = self.angles - self.rotdoor_carry_last_angles;
    self.rotdoor_carry_last_angles = self.angles;
    self.rotdoor_carry_last_ltime  = self.ltime;

    float ax_idx = self.rotdoor_axis_index;
    float deg_step = ang_delta_x;
    if (ax_idx == 1) deg_step = ang_delta_y;
    else if (ax_idx == 2) deg_step = ang_delta_z;
    // Normalize: the engine wraps integrated angles to [0,360) (or
    // [-180,180]), so a step past either boundary reads as ±360 in
    // the raw subtraction.  Within one carry tick the real rotation
    // is at most avelocity/tickrate ≈ a few degrees, so anything
    // outside ±180 is a wrap artifact.  Without this normalization,
    // any rotation past one full turn (e.g. distance=800) trips a
    // false carry-block on the wrap and the door reverses.
    if (deg_step > 180)  deg_step = deg_step - 360;
    if (deg_step < -180) deg_step = deg_step + 360;
    if (deg_step == 0) return 0;

    float local_unrot_deg = self.angles_x - self.pos1_x;
    if (ax_idx == 1) local_unrot_deg = self.angles_y - self.pos1_y;
    else if (ax_idx == 2) local_unrot_deg = self.angles_z - self.pos1_z;
    // Same normalization for the local-frame anchor — rotation by
    // X is identical to rotation by (X mod 360), so we can wrap to
    // a small range without changing the bbox-test result, but
    // keeping it bounded avoids floating-point precision issues
    // in cos/sin for absurd values.
    while (local_unrot_deg > 180)  local_unrot_deg = local_unrot_deg - 360;
    while (local_unrot_deg < -180) local_unrot_deg = local_unrot_deg + 360;

    float saved_solid = self.solid;

    float blocked = 0;
    entity p = player_chain_head;
    while (p)
    {
        if (!p.is_dead)
        {
            // "Standing on this brush" detection — server-side trace-down,
            // since p.groundentity is unreliable for our MOVETYPE_NONE
            // players.  The engine only sets groundentity from its own
            // physics pass, which doesn't run for MOVETYPE_NONE entities;
            // before this fix the gate (groundentity == self) was always
            // false and Phase 1 ground carry never fired — visible as
            // "standing on a slow func_rotating shows the player not
            // taken with the rotation."  Brush is currently SOLID_BSP,
            // so the trace will hit it if the player is on top.
            self.solid = saved_solid;        // ensure SOLID_BSP for trace
            tracebox(p.origin, p.mins, p.maxs,
                     p.origin - '0 0 4', MOVE_NORMAL, p);
            float on_this_brush = (trace_fraction < 1 && trace_ent == self);

            if ((p.flags & FL_ONGROUND) && on_this_brush)
            {
                // Phase 1 — rotate around pivot.  Un-solid the brush
                // for the rotation tracebox so the player's bbox
                // doesn't false-block on the very surface it's sitting
                // on.
                self.solid = SOLID_NOT;

                vector new_origin = RotDoor_RotateAround(p.origin, pivot, deg_step, ax_idx);
                tracebox(p.origin, p.mins, p.maxs, new_origin, MOVE_NORMAL, p);
                if (trace_fraction >= 1.0)
                {
                    setorigin(p, new_origin);
                }
                else if (trace_fraction > 0)
                {
                    // Partial motion — carry as far as the trace
                    // allowed, mirrors the conveyor pattern so the
                    // player isn't stuck in place when the rotation
                    // arc nicks adjacent geometry.
                    setorigin(p, trace_endpos);
                }
                else
                {
                    // Same takedamage trap as Phase 3 below — players
                    // are DAMAGE_NO in this mod, W_CanDamageTarget
                    // accepts classname=="player" unconditionally.
                    if (self.dmg > 0)
                        W_ApplyDamage(self, p, self.dmg);
                    blocked = 1;
                }
            }
        }
        p = p.player_chain_next;
    }

    // Restore solid for the air-push pass below — Phase 2 doesn't
    // do its own tracebox so it doesn't matter, but keep the
    // contract clean.
    self.solid = SOLID_NOT;

    // Phase 2 — air-touch nudge.  Player gets a tangent velocity kick
    // ONLY when their hull is actually overlapping the brush's BSP
    // mesh (not just inside the brush's AABB) AND they're not on the
    // ground.  This fixes the "force field" symptom on rotators with
    // gaps between geometry (windmill blades, fan rotor): a player
    // jumping over the windmill is inside the AABB but in the empty
    // space between blades, so the AABB-only test was nudging them
    // even though no blade was touching them.  trace_startsolid +
    // trace_ent == self only fires when the player's bbox is in the
    // brush's actual polygon volume — i.e., a blade is currently
    // sweeping into the player.
    //
    // The result is what the user described:
    //   - touching the brush in air → velocity nudge along tangent
    //   - jump off the platform → tangent inheritance via
    //     PM_InheritRotatorTangent in PM_CheckJump (separate path)
    //   - airborne pass-through that doesn't touch a blade → no push
    //   - ground walk-through (FL_ONGROUND on floor) → still skipped
    //     by the FL_ONGROUND gate
    entity p2 = player_chain_head;
    while (p2)
    {
        if (!p2.is_dead && !(p2.flags & FL_ONGROUND))
        {
            // Re-solid the brush for the touch trace, then un-solid
            // for safety (no further traces below in this loop).
            self.solid = saved_solid;
            tracebox(p2.origin, p2.mins, p2.maxs, p2.origin,
                     MOVE_NORMAL, p2);
            self.solid = SOLID_NOT;
            if (trace_startsolid && trace_ent == self)
            {
                vector rel = p2.origin - pivot;
                float omega_rad =
                    (ax_idx == 1) ? self.avelocity_y :
                    (ax_idx == 0) ? self.avelocity_x :
                                    self.avelocity_z;
                omega_rad = omega_rad * 0.017453293;
                vector tangent = '0 0 0';
                if (ax_idx == 1)
                {
                    tangent_x = -rel_y * omega_rad;
                    tangent_y =  rel_x * omega_rad;
                }
                else if (ax_idx == 0)
                {
                    tangent_y = -rel_z * omega_rad;
                    tangent_z =  rel_y * omega_rad;
                }
                else
                {
                    tangent_x =  rel_y * omega_rad;
                    tangent_y = -rel_x * omega_rad;
                }
                p2.velocity = p2.velocity + tangent;
            }
        }
        p2 = p2.player_chain_next;
    }

    // Phase 3 — ground players in the brush's mesh path.  Engine's
    // WPhys_PushAngles skips MOVETYPE_NONE players (sv_phys.c:754),
    // so a player standing on the floor while a yaw-rotating brush
    // sweeps into them just gets phased through.  Detect the touch
    // (tracebox-startsolid) and slide them tangentially; if the slide
    // tracebox fails (wall behind), apply per-tick `dmg` and signal
    // blocked so the caller can halt the rotation this tick.
    //
    // Skips players already handled by Phase 1 (on this brush as
    // ground — re-traces the down-check) so the carry doesn't
    // double-process them.
    entity p3 = player_chain_head;
    while (p3)
    {
        if (!p3.is_dead && (p3.flags & FL_ONGROUND))
        {
            self.solid = saved_solid;       // SOLID_BSP for traces
            tracebox(p3.origin, p3.mins, p3.maxs,
                     p3.origin - '0 0 4', MOVE_NORMAL, p3);
            float on_self = (trace_fraction < 1 && trace_ent == self);
            // "Standing on a DIFFERENT rotating brush" check — skip
            // Phase 3 here so the player isn't slid by this brush
            // when another currently-rotating brush is already
            // Phase-1-carrying them (e.g. two X-axis barrels next to
            // each other in a row).  Without this, the user gets
            // flung in a random direction by the combined motion.
            // Brush_RotateCarry runs once per rotating brush per
            // tick (per-brush think) — the stand-on brush's own
            // Brush_RotateCarry handles the player via Phase 1.
            float on_other_rotator = (trace_fraction < 1
                                      && trace_ent != self
                                      && trace_ent != world
                                      && trace_ent.avelocity != '0 0 0');

            if (!on_self && !on_other_rotator)
            {
                tracebox(p3.origin, p3.mins, p3.maxs, p3.origin,
                         MOVE_NORMAL, p3);
                if (trace_startsolid && trace_ent == self)
                {
                    // Brush mesh is sweeping into this ground player.
                    // Compute tangent at their position and try to
                    // slide them out.
                    vector p3_rel = p3.origin - pivot;
                    float p3_omega =
                        (ax_idx == 1) ? self.avelocity_y :
                        (ax_idx == 0) ? self.avelocity_x :
                                        self.avelocity_z;
                    p3_omega = p3_omega * 0.017453293;
                    vector p3_tangent = '0 0 0';
                    if (ax_idx == 1)
                    {
                        p3_tangent_x = -p3_rel_y * p3_omega;
                        p3_tangent_y =  p3_rel_x * p3_omega;
                    }
                    else if (ax_idx == 0)
                    {
                        p3_tangent_y = -p3_rel_z * p3_omega;
                        p3_tangent_z =  p3_rel_y * p3_omega;
                    }
                    else
                    {
                        p3_tangent_x =  p3_rel_y * p3_omega;
                        p3_tangent_y = -p3_rel_x * p3_omega;
                    }
                    float p3_tan_speed = vlen(p3_tangent);
                    if (p3_tan_speed > 0.01)
                    {
                        vector p3_tan_dir = p3_tangent * (1.0 / p3_tan_speed);
                        float p3_hz = cvar("sv_func_tickrate");
                        if (p3_hz <= 0)  p3_hz = 40;
                        if (p3_hz > 200) p3_hz = 200;
                        vector p3_new_pos = p3.origin
                                        + p3_tan_dir * (p3_tan_speed / p3_hz + 4);
                        self.solid = SOLID_NOT;       // exclude self from slide trace
                        tracebox(p3.origin, p3.mins, p3.maxs,
                                 p3_new_pos, MOVE_NORMAL, p3);
                        if (trace_fraction >= 1.0)
                        {
                            // Full slide — player cleared the swept
                            // arc.  Origin-only; NO velocity addition.
                            // Velocity-add accumulated dramatically
                            // when player straddled multiple barrels
                            // and produced the across-the-map fling.
                            // Mirrors CSQC Phase 3 (sh_pmove.qc).
                            setorigin(p3, p3_new_pos);
                        }
                        else
                        {
                            // Partial or fully stuck — player can't
                            // be moved to a free spot.  Snap to
                            // trace_endpos for a clean visual but do
                            // NOT add tangent velocity; signal blocked
                            // so the caller (rotating_think /
                            // RotDoor_CarryPlayers) halts the rotation
                            // for this tick.  User-facing rule: the
                            // door doesn't open through a player who
                            // has a wall behind them.
                            //
                            // No takedamage gate — players in this mod
                            // have takedamage = DAMAGE_NO by default
                            // (we never call SetTakedamage on them),
                            // and W_CanDamageTarget unconditionally
                            // accepts targets with classname=="player".
                            // Same trap func_door's door_blocked path
                            // documents at sv_doors.qc:572-578.
                            if (trace_fraction > 0)
                                setorigin(p3, trace_endpos);
                            if (self.dmg > 0)
                                W_ApplyDamage(self, p3, self.dmg);
                            blocked = 1;
                        }
                    }
                }
            }
            self.solid = SOLID_NOT;
        }
        p3 = p3.player_chain_next;
    }

    self.solid = saved_solid;
    return blocked;
};

// Door-specific wrapper: delegate to Brush_RotateCarry, then decide
// what to do with a "blocked" report based on the door's direction.
//
//   Opening (state=UP)   — the door SWEEPS PAST the stuck player.
//                          The carry already tried to move them out
//                          of the way; if it couldn't, the player
//                          stays where they are and the leaf rotates
//                          past.  Damage is still applied inside the
//                          carry (Brush_RotateCarry).  We INTENTIONALLY
//                          do NOT reverse here — auto-reverse during
//                          opening creates an open-block-reverse loop
//                          for long rotations (distance > ~180°)
//                          whenever the player is anywhere near the
//                          door's swept area.  HL doors also sweep
//                          past on opening.
//   Closing (state=DOWN) — reverse via rotdoor_blocked (door starts
//                          opening again so the trapped-against-wall
//                          player can free themselves).
float() RotDoor_CarryPlayers =
{
    // Capture pre-tick angles for the UNBLOCKABLE halt path below.
    // Engine has already integrated self.angles forward by this point;
    // reverting it makes the door appear stationary this tick.
    vector pre_carry_angles = self.rotdoor_carry_last_angles;

    float was_blocked = Brush_RotateCarry();
    if (!was_blocked) return 0;

    if (self.spawnflags & DOORROT_UNBLOCKABLE)
    {
        // Grinder mode — no reverse.  Per-tick damage is already
        // applied inside Brush_RotateCarry's Phase 1 and Phase 3
        // when the player is wedged.  Just halt the engine's
        // integration for this tick; next tick the engine retries
        // (re-blocks if still wedged → damage again, halt again;
        // or resumes if the player moved out of the way).  Same
        // pattern rotating_think uses for fans (sv_rotating.qc:140).
        self.angles                    = pre_carry_angles;
        self.rotdoor_carry_last_angles = pre_carry_angles;
        self.SendFlags                 = 1;
        return 1;
    }

    // Default: reverse direction so the trapped player can free
    // themselves and the door doesn't sit forever in a wedged state.
    // The previous design halt-on-opening was added to avoid an
    // open-block-reverse oscillation comment at lines 530-541, but
    // the user reports the halt-and-stuck behaviour is worse than
    // brief oscillation — and with strict-block (Phase 3 partial
    // slide blocks the door), the door is now far less twitchy on
    // marginal contacts than it used to be.  rotdoor_blocked applies
    // damage and calls rotdoor_go_up/down to reverse direction.
    rotdoor_blocked();
    return 1;
};

// Resolve the per-tick carry interval from sv_func_tickrate.  Cvar
// is in Hz; we cap to a sensible range and convert to a seconds
// interval.  Higher Hz = smoother carry / earlier block detection
// at higher CPU cost — defaults to 64 Hz (~15.6 ms) which is a good
// compromise for typical door speeds.
float() RotDoor_TickInterval =
{
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = 40;
    if (hz > 200)  hz = 200;
    return 1.0 / hz;
};

void() RotDoor_CarryTick =
{
    // Drive the carry pass at sv_func_tickrate cadence.  Each
    // invocation moves players touching the door by the same
    // angular delta the engine integrated this tick — so the
    // player visibly sweeps with the door instead of being
    // clipped through.
    if (RotDoor_CarryPlayers())
        return;     // blocked branch already handed off to rotdoor_blocked

    if (self.ltime >= self.rotdoor_finish_time)
    {
        self.avelocity = '0 0 0';
        self.SendFlags = 1;
        if (self.rotdoor_finish_cb)
            self.rotdoor_finish_cb();
        return;
    }

    // Re-send the brushsync snap each carry tick so the client's
    // CSQC_SolidBrush_Predraw can re-anchor csqc_snap_angles /
    // csqc_snap_time to the latest authoritative angle.  Without
    // this, SendFlags only fires at rotation start + end, and the
    // client extrapolates seconds forward of authoritative on long
    // (distance 800) rotations — visible as "brush mesh leads
    // collision" + a ~1-sec smoother fade after stop.  The engine
    // dedups outgoing brushsync packets to netrate cadence (~20 Hz)
    // so the bandwidth cost is one packet per netrate tick per
    // viewer regardless of sv_func_tickrate.
    self.SendFlags = 1;

    self.nextthink = self.ltime + RotDoor_TickInterval();
};

// Mover_Start counterpart for angular motion.  Sets avelocity so the
// engine integrates self.angles smoothly between ticks, schedules a
// per-tick carry think for the duration so touching players sweep
// along with the door.  Snapping to the exact destination on
// arrival kills float drift.
void(vector dest_angles, float move_speed, void() move_done) Mover_RotateStart =
{
    vector delta    = dest_angles - self.angles;
    float  distance = vlen(delta);

    if (cvar("sv_debug_use"))
        print(sprintf("[rotdoor-start] '%s' angles=%v dest=%v delta=%v dist=%g speed=%g travel=%g\n",
                      self.targetname, self.angles, dest_angles, delta,
                      distance, move_speed,
                      move_speed > 0 ? (distance / move_speed) : 0));

    if (distance <= 0 || move_speed <= 0)
    {
        self.angles    = dest_angles;
        self.avelocity = '0 0 0';
        self.SendFlags = 1;
        move_done();
        return;
    }

    float travel    = distance / move_speed;
    self.avelocity  = delta * (1.0 / travel);
    self.SendFlags  = 1;

    // Pick the axis index for the carry-rotation math from the
    // dominant avelocity component — usually exactly one is non-zero
    // for a single-axis rotating door.  Falls back to yaw (1) when
    // all components are equal (degenerate, shouldn't happen).
    if (fabs(self.avelocity_x) >= fabs(self.avelocity_y)
     && fabs(self.avelocity_x) >= fabs(self.avelocity_z))
        self.rotdoor_axis_index = 0;
    else if (fabs(self.avelocity_z) >= fabs(self.avelocity_y))
        self.rotdoor_axis_index = 2;
    else
        self.rotdoor_axis_index = 1;

    self.rotdoor_finish_time       = self.ltime + travel;
    self.rotdoor_finish_cb         = move_done;
    self.rotdoor_carry_last_ltime  = self.ltime;
    self.rotdoor_carry_last_angles = self.angles;
    self.think                     = RotDoor_CarryTick;
    self.nextthink                 = self.ltime + RotDoor_TickInterval();

    // Publish to the shared rotating-brush list so CSQC's pmove can
    // mirror the carry math against this brush.  Removed in the
    // hit_top / hit_bottom callbacks once rotation finishes.
    RotatingBrush_AddToList(self);
};

void() rotdoor_hit_bottom =
{
    self.angles      = self.pos1;
    self.avelocity   = '0 0 0';
    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;
    self.SendFlags   = 1;
    RotatingBrush_RemoveFromList(self);
    Door_PlayStopSound();
};

void() rotdoor_go_down =
{
    if (self.door_state == DOOR_STATE_BOTTOM
    || self.door_state == DOOR_STATE_DOWN) return;
    self.door_state  = DOOR_STATE_DOWN;
    self.mover_state = MOVER_STATE_DOWN;
    Door_PlayMoveSound();
    Mover_RotateStart(self.pos1, self.speed, rotdoor_hit_bottom);
};

void() rotdoor_hit_top =
{
    self.angles      = self.pos2;
    self.avelocity   = '0 0 0';
    self.door_state  = DOOR_STATE_TOP;
    self.mover_state = MOVER_STATE_TOP;
    self.SendFlags   = 1;
    RotatingBrush_RemoveFromList(self);
    Door_PlayStopSound();
    if ((self.spawnflags & DOORROT_TOGGLE) || self.wait < 0)
        return;
    self.nextthink = self.ltime + self.wait;
    self.think     = rotdoor_go_down;
};

void() rotdoor_go_up =
{
    if (self.door_state == DOOR_STATE_TOP)
    {
        if (!(self.spawnflags & DOORROT_TOGGLE) && self.wait >= 0)
        {
            self.nextthink = self.ltime + self.wait;
            self.think     = rotdoor_go_down;
        }
        return;
    }
    if (self.door_state == DOOR_STATE_UP) return;

    // pos2 (open angle) is RECOMPUTED only on fresh activation from
    // BOTTOM (= closed and stationary).  On reversal mid-close (state
    // = DOWN, blocked) we reuse the existing pos2 — re-running the
    // auto-flip would flip pos2 to the OTHER side of pos1 if the
    // activator's facing changed (or activator is the blocked player
    // standing on the opposite side), and the door would then rotate
    // from its mid-close angle past pos1 onto the new far side — i.e.
    // "the door goes through me and opens in the other direction"
    // (user-reported bug on TOGGLE doors blocked while closing).
    if (self.door_state == DOOR_STATE_BOTTOM)
    {
        float sign_eff = (self.spawnflags & DOORROT_REVERSE) ? -1 : 1;

        // Open away from player — flip the rotation sign when the
        // activator stands on the FRONT side, so the leaf swings
        // away from them (toward the back).  Player on the back
        // side gets the un-flipped default sign which swings the
        // leaf forward, again away from the player.  ONE_WAY skips
        // the auto-flip entirely.  The facing test uses the door's
        // local forward at the closed pose.
        if (!(self.spawnflags & DOORROT_ONE_WAY)
            && activator && activator != world)
        {
            vector saved = self.angles;
            self.angles = self.pos1;       // facing test against closed pose
            makevectors(self.angles);
            self.angles = saved;
            vector to_act = activator.origin - Mover_RotationPivot();
            if (to_act * v_forward > 0)
                sign_eff = -sign_eff;
        }

        self.pos2 = self.pos1 + self.movedir * (self.distance * sign_eff);
    }

    self.door_state  = DOOR_STATE_UP;
    self.mover_state = MOVER_STATE_UP;
    Door_PlayMoveSound();
    Mover_RotateStart(self.pos2, self.speed, rotdoor_hit_top);
};

void() rotdoor_blocked =
{
    // Air-player block — engine has already reverted the brush's angle
    // integration for this physics tick (sv_phys.c WPhys_PushAngles
    // line 898-908).  Reversing direction on top of that creates the
    // visible oscillation a falling player gets stuck in (door rotates
    // → blocked → reverses → blocked → reverses → ...).  Instead:
    // impart tangent velocity at the player's position so they're
    // shoved away from the brush, then halt-on-opening / reverse-on-
    // closing — the same semantic the ground-player carry already uses
    // (sweep past on opening, reverse on closing so the trapped player
    // can free themselves).
    float air_player =
        (other && other.classname == "player"
         && !((other.flags & FL_ONGROUND) && other.groundentity == self));
    if (air_player)
    {
        vector rel = other.origin - Mover_RotationPivot();
        float omega_rad;
        vector tangent = '0 0 0';
        if (self.rotdoor_axis_index == 0)         // pitch
        {
            omega_rad = self.avelocity_x * 0.017453293;
            tangent_y = -rel_z * omega_rad;
            tangent_z =  rel_y * omega_rad;
        }
        else if (self.rotdoor_axis_index == 2)    // roll
        {
            omega_rad = self.avelocity_z * 0.017453293;
            tangent_x =  rel_y * omega_rad;
            tangent_y = -rel_x * omega_rad;
        }
        else                                       // yaw (default)
        {
            omega_rad = self.avelocity_y * 0.017453293;
            tangent_x = -rel_y * omega_rad;
            tangent_y =  rel_x * omega_rad;
        }
        other.velocity = other.velocity + tangent;

        // Halt on opening — engine already reverted angles for this
        // tick, so just don't reverse.  Brush retries next tick;
        // gravity + tangent kick will eventually move the player out.
        if (self.door_state == DOOR_STATE_UP || self.door_state == DOOR_STATE_TOP)
            return;
        // Closing falls through to the reverse path so a player
        // wedged between a closing door and a wall can free
        // themselves the way they always could.
    }

    // No takedamage gate — players have takedamage = DAMAGE_NO in
    // this mod by default; W_CanDamageTarget accepts classname=="player"
    // unconditionally.  Same trap documented at sv_doors.qc:572-578.
    if (self.dmg > 0 && other != world)
        W_ApplyDamage(self, other, self.dmg);
    // Reverse direction so the blocker can free themselves — matches
    // the standard func_door blocked behaviour.  DOORROT_UNBLOCKABLE
    // is handled by RotDoor_CarryPlayers above, which doesn't call
    // this function in grinder mode.
    if (self.door_state == DOOR_STATE_UP || self.door_state == DOOR_STATE_TOP)
        rotdoor_go_down();
    else
        rotdoor_go_up();
};

void() rotdoor_use =
{
    if (cvar("mp_disabledoors")) return;

    // USE_ONLY rejects target-trigger fires (auto proximity isn't
    // spawned for these brushes either) — exactly the behaviour
    // func_door's USE_ONLY flag implements.
    if (!sv_use_is_player_direct
        && (self.spawnflags & DOORROT_USE_ONLY))
        return;

    if (self.attack_finished > time) return;
    self.attack_finished = time + 0.1;

    // Door is locked while mid-rotation.  +use / push / target
    // chain all silently ignore until the brush has reached its
    // next at-rest state.  For non-TOGGLE doors the auto-return
    // path still runs — the lock is just on re-trigger from the
    // outside, not on the internal go_down schedule.
    if (self.door_state == DOOR_STATE_UP
     || self.door_state == DOOR_STATE_DOWN)
        return;

    if (self.door_state == DOOR_STATE_TOP)
    {
        // Idle at TOP — non-TOGGLE doors are committed to their
        // auto-return cycle and ignore re-trigger.  TOGGLE doors
        // close on the second press.
        if (self.spawnflags & DOORROT_TOGGLE)
            rotdoor_go_down();
        return;
    }
    rotdoor_go_up();
};

void() rotdoor_touch =
{
    entity oldself, oldactivator;
    if (other.classname != "player") return;
    if (self.spawnflags & DOORROT_USE_ONLY) return;

    // Push-only activation: brushing past the proximity bbox
    // shouldn't open the door, only an actual push into it.
    // Project the player's velocity onto the direction toward the
    // door's pivot — positive (toward door) above a small
    // threshold counts as a push, anything else (standing,
    // walking past, walking away) doesn't activate.  +use still
    // works via the door's .use entry point regardless.
    vector to_door = self.owner.origin - other.origin;
    if (vlen(to_door) < 0.01) return;
    to_door = normalize(to_door);
    if ((other.velocity * to_door) < 50)
        return;

    oldself = self; oldactivator = activator;
    activator = other;
    self = self.owner;
    rotdoor_use();
    self = oldself; activator = oldactivator;
};

void() rotdoor_spawn_trigger =
{
    // GoldSrc-style: the door activates when the player physically
    // touches the BSP brush, NOT when they wander into a wide
    // proximity volume.  Hug the brush's actual bounds (mins/maxs
    // rather than the swept-radius cmins/cmaxs that the sliding
    // door uses), with a 2 qu inflation just so the engine's
    // touch test reliably fires on contact rather than requiring
    // exact overlap.
    entity trigger;
    vector center, t_mins, t_maxs;
    center = (self.absmin + self.absmax) * 0.5;
    t_mins = self.absmin - center - '2 2 2';
    t_maxs = self.absmax - center + '2 2 2';
    trigger = spawn();
    setorigin(trigger, center);
    setsize(trigger, t_mins, t_maxs);
    trigger.movetype = MOVETYPE_NONE;
    trigger.solid    = SOLID_TRIGGER;
    trigger.owner    = self;
    trigger.touch    = rotdoor_touch;
};

/*QUAKED func_door_rotating (0 .5 .8) ? START_OPEN REVERSE x PASSABLE ONE_WAY TOGGLE X_AXIS Y_AXIS USE_ONLY
A door that rotates around a hinge pivot.  Define the pivot with an
ORIGIN-textured brush included in the entity (the BSP compiler bakes
its centre into self.origin); the door swings around that point.

"distance"   degrees to rotate (default 90)
"speed"      degrees per second (default 100)
"wait"       seconds before auto-close (default 3, -1 = stay open)
"dmg"        block damage (default 0)
"angles"     initial rotation pose (pitch yaw roll)
"target"     entities to fire on open
"targetname" if set, no auto proximity trigger spawns
"sounds"     0=silent 1=stone 2=base 3=chain 4=metal
*/
void() func_door_rotating =
{
    if (self.sounds == 1)
    {
        if (!self.noise1) self.noise1 = "doors/drclos4.wav";
        if (!self.noise2) self.noise2 = "doors/doormv1.wav";
    }
    else if (self.sounds == 2)
    {
        if (!self.noise1) self.noise1 = "doors/hydro2.wav";
        if (!self.noise2) self.noise2 = "doors/hydro1.wav";
    }
    else if (self.sounds == 3)
    {
        if (!self.noise1) self.noise1 = "doors/stndr2.wav";
        if (!self.noise2) self.noise2 = "doors/stndr1.wav";
    }
    else if (self.sounds == 4)
    {
        if (!self.noise1) self.noise1 = "doors/ddoor2.wav";
        if (!self.noise2) self.noise2 = "doors/ddoor1.wav";
    }

    // HL movesnd / stopsnd / locked / unlocked overrides — see the
    // Door_Lookup* helpers in sv_doors.qc.
    if (self.movesnd > 0)        self.noise2         = Door_LookupMoveSound(self.movesnd);
    if (self.stopsnd > 0)        self.noise1         = Door_LookupStopSound(self.stopsnd);
    if (self.locked_sound > 0)   self.noise_locked   = Door_LookupLockedSound(self.locked_sound);
    if (self.unlocked_sound > 0) self.noise_unlocked = Door_LookupUnlockedSound(self.unlocked_sound);

    Door_PrecacheIfReal(self.noise1);
    Door_PrecacheIfReal(self.noise2);
    Door_PrecacheIfReal(self.noise_locked);
    Door_PrecacheIfReal(self.noise_unlocked);

    if (!self.speed)    self.speed    = 100;
    if (!self.wait)     self.wait     = 3;
    if (!self.distance) self.distance = 90;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_DOOR;
    self.brush_is_rotating = 1;
    self.blocked    = rotdoor_blocked;
    self.use        = rotdoor_use;

    // PASSABLE: visible-but-walkable.  Skips both .solid and the
    // proximity trigger; +use against a non-solid brush won't
    // resolve, so PASSABLE doors are intentionally external-target-
    // only (combine with a button or trigger to actuate).
    if (self.spawnflags & DOORROT_PASSABLE)
        self.solid = SOLID_NOT;

    // Axis selection — match HL's CBaseToggle::AxisDir bit-to-movedir
    // map.  The FGD flag NAMES ("X axis" / "Y axis") refer to which
    // slot of movedir HL sets non-zero, NOT to which world axis the
    // door rotates around.  HL maps' spawn flags are picked for HL's
    // mapping, so we mirror it exactly:
    //   bit 64  ("X axis" FGD) → movedir (0,0,1) → angles_z = roll
    //   bit 128 ("Y axis" FGD) → movedir (1,0,0) → angles_x = pitch
    //   default                → movedir (0,1,0) → angles_y = yaw
    if (self.spawnflags & DOORROT_X_AXIS)
    {
        self.movedir            = '0 0 1';
        self.rotdoor_axis_index = 2;     // roll, around world X — matches Mover_RotateStart
    }
    else if (self.spawnflags & DOORROT_Y_AXIS)
    {
        self.movedir            = '1 0 0';
        self.rotdoor_axis_index = 0;     // pitch, around world Y
    }
    else
    {
        self.movedir            = '0 1 0';
        self.rotdoor_axis_index = 1;     // yaw, around world Z (default)
    }

    self.pos1 = self.angles;
    self.pos2 = self.pos1 + self.movedir
              * (self.distance * ((self.spawnflags & DOORROT_REVERSE) ? -1 : 1));

    if (self.spawnflags & DOORROT_START_OPEN)
    {
        self.angles = self.pos2;
        // Mirror func_door's "swap so BOTTOM means at-pos1" pattern:
        // for a START_OPEN rotating door, the brush sits at pos2
        // (open) at spawn and "bottom" of the state machine is the
        // open pose.  Swap pos1/pos2 so subsequent go_up moves it
        // to the closed pose, matching the inverted convention.
        vector swap = self.pos1;
        self.pos1 = self.pos2;
        self.pos2 = swap;
    }

    // Worst-case bounds for proximity trigger / group sizing —
    // rotation can sweep through any point inside the brush's
    // bounding sphere, so just inflate by the diagonal radius.
    // Center on the brush's absolute bounds so the proximity trigger
    // hugs the brush's actual world position.
    float radius = vlen(self.maxs - self.mins) * 0.5 + 8;
    vector brush_center = (self.absmin + self.absmax) * 0.5;
    self.cmins = brush_center - [radius, radius, radius];
    self.cmaxs = brush_center + [radius, radius, radius];

    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;

    if (!self.targetname && !(self.spawnflags & DOORROT_PASSABLE))
        rotdoor_spawn_trigger();
};
