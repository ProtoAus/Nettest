/*
==============================================================================
sh_pmove.qc  –  Shared player-movement code (SSQC + CSQC)

Port of EzQuake's pmove.c to FTE QuakeC.
Compiled into both server progs and client progs so that client-side
prediction exactly matches server physics.

Hull: mins = '-16 -16 0'  maxs = '16 16 56'  (origin at feet, GoldSrc style)
Eye : view_ofs.z = 48
==============================================================================
*/

#pragma warning disable Q302   // suppress uninitialised-variable warnings

// ============================================================================
//  Hull / physics constants
// ============================================================================

vector PM_MINS             = '-16 -16 0';   // standing hull bottom — never changes
vector PM_MAXS;             // standing hull top          — set by PM_ReadMovevars
vector PM_DUCK_MINS;        // duck hull bottom           — set by PM_ReadMovevars
vector PM_DUCK_MAXS;        // duck hull top              — set by PM_ReadMovevars
vector PM_VIEW_OFS;         // standing eye offset        — set by PM_ReadMovevars
vector PM_DUCK_VIEW_OFS;    // ducked eye offset          — set by PM_ReadMovevars

float  PM_STEPSIZE         = 18;
float  PM_FLYFRICTION      = 4;
float  PM_STOP_EPSILON     = 0.1;
float  PM_MIN_STEP_NORMAL  = 0.7;   // floor normal.z must be >= this
float  PM_MAX_CLIP_PLANES  = 5;
float  PM_MAX_JUMPFIX_DP   = -0.1;  // ramp-fix dot-product threshold
float  PM_BTN_JUMP         = 2;     // bit in input_buttons
float  PM_BTN_DUCK         = 32;    // +button6 via DP_INPUTBUTTONS
float  PM_DUCK_TIME        = 0.4;
float  PM_DUCKING_MULTIPLIER = 0.333;
float  PM_FIXEDSTEP_EPSILON = 0.000001;

// ============================================================================
//  Blocked flags  (returned by slide / step functions)
// ============================================================================

float  PM_BLOCKED_FLOOR    = 1;
float  PM_BLOCKED_STEP     = 2;
float  PM_BLOCKED_OTHER    = 4;

// ============================================================================
//  Movement types  (stored in self.pm_movetype)
// ============================================================================

float  PM_MOVETYPE_NORMAL    = 0;
float  PM_MOVETYPE_DEAD      = 1;
float  PM_MOVETYPE_FLY       = 2;
float  PM_MOVETYPE_SPECTATOR = 3;
float  PM_MOVETYPE_NONE      = 4;

// ============================================================================
//  Custom entity fields
// ============================================================================

.float pm_movetype;       // PM_MOVETYPE_*
.float pm_waterjumptime;  // seconds remaining in water-jump launch
.float pm_jump_held;      // true while jump button is held (prevent pogo)
.float pm_jump_msec;      // msec accumulator for jump timer (0 = expired)
.float pm_in_duck;        // true while transitioning into a crouch
.float pm_duck_msec;      // GoldSrc-style duck transition timer
.float pm_oldbuttons;     // previous input_buttons state for edge detection
.float pm_timecarry;      // leftover command time for fixed-step simulation
.entity pm_prediction_proxy; // owner-only SSQC->CSQC authoritative snapshot proxy

// ============================================================================
//  Per-move working globals  (loaded from self at the start of PM_PlayerMove)
// ============================================================================

vector pm_origin;
vector pm_velocity;
float  pm_onground;
float  pm_waterlevel;     // 0 = dry, 1 = feet, 2 = waist, 3 = eyes
float  pm_watertype;      // CONTENT_* of deepest touched water
vector pm_groundnormal;
float  pm_frametime;
vector pm_forward;
vector pm_right;
float  pm_on_ladder;      // TRUE if player overlaps a ladder trigger this step
vector pm_ladder_normal;  // outward-facing normal of the active ladder surface

// ============================================================================
//  Movevars  (populated from cvars each call via PM_ReadMovevars)
// ============================================================================

float  mv_gravity;
float  mv_maxspeed;
float  mv_stopspeed;
float  mv_friction;
float  mv_waterfriction;
float  mv_accelerate;
float  mv_airaccelerate;    // separate air-strafe accel (GoldSrc-style)
float  mv_wateraccelerate;
float  mv_entgravity;
float  mv_spectatormaxspeed;
float  mv_stamina;              // 1 = CS 1.6 landing-fatigue enabled, 0 = disabled
float  mv_autohop;              // 1 = jump re-fires every landing while held, 0 = require release

void() PM_CategorizePosition;
void() PM_PlayerMove;
void() PM_PlayerMoveStep;
void() PM_CheckLadder;

// ============================================================================
//  8.  PM_Trace  –  tracebox wrapper using the shared hull
// ============================================================================

vector PM_CurrentMaxs()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCK_MAXS;

    return PM_MAXS;
}

vector PM_CurrentMins()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCK_MINS;

    return PM_MINS;
}

void PM_TraceHull(vector start, vector mins, vector maxs, vector end)
{
    tracebox(start, mins, maxs, end, MOVE_NOMONSTERS, self);
}

void PM_Trace(vector start, vector end)
{
    PM_TraceHull(start, PM_CurrentMins(), PM_CurrentMaxs(), end);
}

// ============================================================================
//  9.  PM_TestPosition  –  returns true if the position is not solid
// ============================================================================

float PM_TestPositionExt(vector pos, vector mins, vector maxs)
{
    tracebox(pos, mins, maxs, pos, MOVE_NOMONSTERS, self);
    return !trace_startsolid;
}

float PM_TestPosition(vector pos)
{
    return PM_TestPositionExt(pos, PM_CurrentMins(), PM_CurrentMaxs());
}

float PM_MoveScale()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCKING_MULTIPLIER;

    return 1;
}

float PM_SplineFraction(float value, float scale)
{
    float value_squared;

    value = value * scale;
    value_squared = value * value;

    return 3 * value_squared - 2 * value_squared * value;
}

void PM_SyncHull()
{
#ifdef SSQC
    if (self.flags & FL_DUCKING)
        setsize(self, PM_DUCK_MINS, PM_DUCK_MAXS);
    else
        setsize(self, PM_MINS, PM_MAXS);
#endif
}

void PM_UnDuck()
{
    vector new_origin;

    new_origin = pm_origin;
    // Undo the ground duck origin shift: restore feet to world floor level.
    // In air there was no shift, so don't compensate.
    if (pm_onground)
        new_origin_z += PM_DUCK_MINS_z;

    if (!PM_TestPositionExt(new_origin, PM_MINS, PM_MAXS))
        return;

    pm_origin = new_origin;
    self.flags &= ~FL_DUCKING;
    self.pm_in_duck = FALSE;
    self.pm_duck_msec = 0;
    self.view_ofs = PM_VIEW_OFS;

    PM_SyncHull();
    PM_CategorizePosition();
}

void PM_CheckDuck()
{
    float buttons_changed;
    float buttons_pressed;
    float duck_down;
    float duck_time;
    float duck_fraction;

    duck_down = input_buttons & PM_BTN_DUCK;
    buttons_changed = self.pm_oldbuttons ^ input_buttons;
    buttons_pressed = buttons_changed & input_buttons;

    if (duck_down)
        self.pm_oldbuttons |= PM_BTN_DUCK;
    else
        self.pm_oldbuttons &= ~PM_BTN_DUCK;

    if (self.pm_movetype == PM_MOVETYPE_DEAD)
    {
        if ((self.flags & FL_DUCKING) || self.pm_in_duck)
            PM_UnDuck();
        return;
    }

    if (!duck_down && !self.pm_in_duck && !(self.flags & FL_DUCKING))
    {
        self.view_ofs = PM_VIEW_OFS;
        return;
    }

    if (duck_down)
    {
        if ((buttons_pressed & PM_BTN_DUCK) && !(self.flags & FL_DUCKING))
        {
            self.pm_duck_msec = 1000;
            self.pm_in_duck = TRUE;
        }

        if (self.pm_in_duck)
        {
            if (self.pm_duck_msec < 0)
                self.pm_duck_msec = 0;

            duck_time = max(0, 1 - self.pm_duck_msec / 1000);

            // Match GoldSrc: finish instantly once the duck timer crosses the
            // threshold or if the player is airborne mid-transition.
            if (self.pm_duck_msec / 1000 <= (1 - PM_DUCK_TIME) || !pm_onground)
            {
                self.flags |= FL_DUCKING;
                self.pm_in_duck = FALSE;
                self.view_ofs = PM_DUCK_VIEW_OFS;

                // On ground: shift origin down so feet stay planted at the same
                // world position (mirrors GoldSrc origin -= duck_mins - stand_mins).
                // In air: no shift — hull bottom rises, enabling crouch-jump.
                if (pm_onground)
                {
                    pm_origin_z -= PM_DUCK_MINS_z;
                    // Unstick if the shift pushed us into geometry
                    if (!PM_TestPosition(pm_origin))
                    {
                        local float nudge;
                        for (nudge = 0; nudge < 36; nudge = nudge + 1)
                        {
                            pm_origin_z = pm_origin_z + 1;
                            if (PM_TestPosition(pm_origin))
                                break;
                        }
                    }
                }

                PM_SyncHull();
                PM_CategorizePosition();
            }
            else
            {
                // Animate view toward (PM_DUCK_VIEW_OFS_z - PM_DUCK_MINS_z) so that
                // when the duck finalises on ground and origin shifts down by
                // PM_DUCK_MINS_z, the eye world-position is continuous (no pop).
                duck_fraction = PM_SplineFraction(duck_time, 1 / PM_DUCK_TIME);
                self.view_ofs_z = PM_VIEW_OFS_z * (1 - duck_fraction)
                                + (PM_DUCK_VIEW_OFS_z - PM_DUCK_MINS_z) * duck_fraction;
            }
        }
        else if (self.flags & FL_DUCKING)
        {
            self.view_ofs = PM_DUCK_VIEW_OFS;
        }

        return;
    }

    PM_UnDuck();
}

// ============================================================================
//  10.  PM_ClipVelocity  –  reflect / clip velocity off a plane
// ============================================================================

vector PM_ClipVelocity(vector in, vector normal, float overbounce)
{
    float  backoff;
    vector out;

    backoff = (in * normal) * overbounce;

    out_x = in_x - normal_x * backoff;
    out_y = in_y - normal_y * backoff;
    out_z = in_z - normal_z * backoff;

    // kill tiny residual components to avoid drift
    if (out_x > -PM_STOP_EPSILON && out_x < PM_STOP_EPSILON) out_x = 0;
    if (out_y > -PM_STOP_EPSILON && out_y < PM_STOP_EPSILON) out_y = 0;
    if (out_z > -PM_STOP_EPSILON && out_z < PM_STOP_EPSILON) out_z = 0;

    return out;
}

// ============================================================================
//  11.  PM_SlideMove  –  multi-plane clipped slide, up to 4 bumps
// ============================================================================

float PM_SlideMove()
{
    local vector planes[5];
    vector       primal_velocity;
    vector       original_velocity;
    vector       new_velocity;
    vector       dir;
    float        time_left;
    float        blocked;
    float        num_planes;
    float        i, j;
    float        d;

    primal_velocity = pm_velocity;
    original_velocity = pm_velocity;
    blocked         = 0;
    num_planes      = 0;
    time_left       = pm_frametime;

    // --- up to 4 collision bumps ---
    for (i = 0; i < 4; i++)
    {
        if (pm_velocity == '0 0 0')
            break;

        PM_Trace(pm_origin, pm_origin + pm_velocity * time_left);

        if (trace_startsolid || trace_allsolid)
        {
            // stuck inside solid – zero velocity and bail
            pm_velocity = '0 0 0';
            return PM_BLOCKED_FLOOR | PM_BLOCKED_STEP | PM_BLOCKED_OTHER;
        }

        if (trace_fraction > 0)
        {
            // moved some distance
            pm_origin    = trace_endpos;
            num_planes   = 0;
        }

        if (trace_fraction == 1)
            break;   // moved the whole way, no collision

        // hit something – classify the surface
        if (trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
            blocked |= PM_BLOCKED_FLOOR;
        else if (!trace_plane_normal_z)
            blocked |= PM_BLOCKED_STEP;
        else
            blocked |= PM_BLOCKED_OTHER;

        // store the plane
        if (num_planes < PM_MAX_CLIP_PLANES)
        {
            planes[num_planes] = trace_plane_normal;
            num_planes++;
        }

        time_left -= time_left * trace_fraction;

        // try each stored plane in turn
        for (j = 0; j < num_planes; j++)
        {
            new_velocity = PM_ClipVelocity(original_velocity, planes[j], 1);

            // check if this clipped velocity re-enters any previous plane
            local float ok;
            ok = TRUE;
            local float k;
            for (k = 0; k < num_planes; k++)
            {
                if (k == j)
                    continue;
                if ((new_velocity * planes[k]) < 0)
                {
                    ok = FALSE;
                    break;
                }
            }

            if (ok)
            {
                pm_velocity = new_velocity;
                break;
            }
        }

        if (j == num_planes)
        {
            // all planes conflicted – try the crease direction
            if (num_planes != 2)
            {
                pm_velocity = '0 0 0';
                break;
            }
            dir = crossproduct(planes[0], planes[1]);
            d   = dir * pm_velocity;
            pm_velocity = dir * d;
        }

        // if we are now moving into the original velocity, don't reverse
        if ((pm_velocity * primal_velocity) <= 0)
        {
            pm_velocity = '0 0 0';
            break;
        }
    }

    // during a water-jump the horizontal speed is locked to primal
    if (self.pm_waterjumptime)
    {
        pm_velocity_x = primal_velocity_x;
        pm_velocity_y = primal_velocity_y;
        pm_velocity_z = pm_velocity_z;   // keep any vertical clip result
    }

    return blocked;
}

// ============================================================================
//  12.  PM_StepSlideMove  –  slide with optional step-up
//  Structure matches pmove.c exactly: run flat slide, SAVE that result,
//  then try the step path and compare the two saved positions.
// ============================================================================

float PM_StepSlideMove(float in_air)
{
    vector  original_origin;
    vector  original_velocity;
    vector  down_origin;     // flat-slide result (saved before step attempt)
    vector  down_velocity;
    vector  org;
    float   blocked;
    float   stepsize;
    float   dx, dy;
    float   down_dist_sq, up_dist_sq;

    original_origin   = pm_origin;
    original_velocity = pm_velocity;

    // --- 1. flat slide ---
    blocked = PM_SlideMove();

    if (!blocked)
        return blocked;   // moved freely, nothing to step over

    // --- 2. airborne guard: only step over actual walls with ground below ---
    if (in_air)
    {
        if (!(blocked & PM_BLOCKED_STEP))
            return blocked;

        org = (original_velocity_z < 0) ? pm_origin : original_origin;
        PM_Trace(org, org - '0 0 1' * PM_STEPSIZE);
        if (trace_fraction == 1 || trace_plane_normal_z < PM_MIN_STEP_NORMAL)
            return blocked;

        // Match pmove.c: shrink the upward retry by how far below us the
        // supporting floor actually is.
        stepsize = PM_STEPSIZE - (org_z - trace_endpos_z);
        if (stepsize < 4)
            return blocked;
    }
    else
    {
        stepsize = PM_STEPSIZE;
    }

    // --- 3. save the flat-slide result as the "down" path ---
    down_origin   = pm_origin;
    down_velocity = pm_velocity;

    // --- 4. reset and attempt the step-up path ---
    pm_origin   = original_origin;
    pm_velocity = original_velocity;

    // step up
    PM_Trace(pm_origin, pm_origin + '0 0 1' * stepsize);
    if (!trace_startsolid && !trace_allsolid)
        pm_origin = trace_endpos;

    // in-air downward velocity zero (pmove.c does this before the elevated slide)
    if (in_air && original_velocity_z < 0)
        pm_velocity_z = 0;

    // slide at the elevated height
    PM_SlideMove();

    // step back down
    PM_Trace(pm_origin, pm_origin - '0 0 1' * stepsize);
    if (trace_fraction != 1 && trace_plane_normal_z < PM_MIN_STEP_NORMAL)
    {
        // landed on a wall, not a floor – fall back to the flat path
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }
    if (!trace_startsolid && !trace_allsolid)
        pm_origin = trace_endpos;

    // reject if step landed us lower than we started (stepped into a dip)
    if (pm_origin_z < original_origin_z)
    {
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }

    // --- 5. compare horizontal coverage of flat vs step paths ---
    dx = down_origin_x - original_origin_x;
    dy = down_origin_y - original_origin_y;
    down_dist_sq = dx*dx + dy*dy;

    dx = pm_origin_x - original_origin_x;
    dy = pm_origin_y - original_origin_y;
    up_dist_sq = dx*dx + dy*dy;

    if (down_dist_sq >= up_dist_sq)
    {
        // flat path covered as much or more ground – use it
        pm_origin   = down_origin;
        pm_velocity = down_velocity;
        return blocked;
    }

    // --- 6. step path was better: keep step position + step velocity,
    //        but borrow z-velocity from the flat slide (pmove.c convention) ---
    pm_velocity_z = down_velocity_z;

    // mid-air step penalty: lose a bit of horizontal speed proportional to
    // how high we stepped (pmove.c)
    if (!pm_onground && pm_waterlevel < 2 && (blocked & PM_BLOCKED_STEP))
    {
        float scale = 1 - 0.01 * (pm_origin_z - original_origin_z);
        pm_velocity_x *= scale;
        pm_velocity_y *= scale;
    }

    return blocked;
}

// ============================================================================
//  13.  PM_Friction
// ============================================================================

void PM_Friction()
{
    float speed, newspeed, control, drop, friction;
    vector vel2d;

    // water-jump in progress – don't interfere
    if (self.pm_waterjumptime)
        return;

    speed = vlen(pm_velocity);

    if (speed < 1)
    {
        pm_velocity_x = 0;
        pm_velocity_y = 0;
        if (self.pm_movetype == PM_MOVETYPE_FLY)
            pm_velocity_z = 0;
        return;
    }

    drop = 0;

    if (pm_waterlevel >= 2)
    {
        // water friction
        drop += speed * mv_waterfriction * pm_waterlevel * pm_frametime;
    }
    else if (self.pm_movetype == PM_MOVETYPE_FLY)
    {
        // fly friction
        drop += speed * PM_FLYFRICTION * pm_frametime;
    }
    else if (pm_onground)
    {
        // ground friction – check for ledge (slow down at edge)
        friction = mv_friction;

        vel2d   = pm_velocity;
        vel2d_z = 0;
        if (vel2d != '0 0 0')
        {
            vel2d = normalize(vel2d);

            // trace 16 units ahead then 34 units down to detect a drop-off
            PM_Trace(
                pm_origin + vel2d * 16 + '0 0 1',
                pm_origin + vel2d * 16 + '0 0 1' - '0 0 34'
            );
            if (trace_fraction == 1)
                friction = friction * 2;   // double friction at ledge
        }

        control = max(speed, mv_stopspeed);
        drop += control * friction * pm_frametime;
    }
    else
    {
        // airborne – no friction
        return;
    }

    newspeed = max(speed - drop, 0) / speed;
    pm_velocity = pm_velocity * newspeed;
}

// ============================================================================
//  14.  PM_Accelerate
// ============================================================================

void PM_Accelerate(vector wishdir, float wishspeed, float accel)
{
    float currentspeed, addspeed, accelspeed;

    if (self.pm_movetype == PM_MOVETYPE_DEAD)
        return;
    if (self.pm_waterjumptime)
        return;

    currentspeed = pm_velocity * wishdir;
    addspeed     = wishspeed - currentspeed;

    if (addspeed <= 0)
        return;

    accelspeed = accel * pm_frametime * wishspeed;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    pm_velocity = pm_velocity + wishdir * accelspeed;
}

// ============================================================================
//  15.  PM_AirAccelerate
// ============================================================================

void PM_AirAccelerate(vector wishdir, float wishspeed, float accel)
{
    float currentspeed, addspeed, accelspeed, wishspeed2;

    if (self.pm_movetype == PM_MOVETYPE_DEAD)
        return;
    if (self.pm_waterjumptime)
        return;

    wishspeed2 = min(wishspeed, 30);   // clamp wish before dot

    currentspeed = pm_velocity * wishdir;
    addspeed     = wishspeed2 - currentspeed;

    if (addspeed <= 0)
        return;

    // note: uses original wishspeed (not clamped) for accelspeed magnitude
    accelspeed = accel * wishspeed * pm_frametime;
    if (accelspeed > addspeed)
        accelspeed = addspeed;

    pm_velocity = pm_velocity + wishdir * accelspeed;
}

// ============================================================================
//  16.  PM_WaterMove
// ============================================================================

float PM_WaterMove()
{
    vector wishvel;
    float  wishspeed;
    float  fmove, smove, upmove;
    float  scale;

    scale = PM_MoveScale();

    fmove = input_movevalues_x * scale;
    smove = input_movevalues_y * scale;
    upmove = input_movevalues_z * scale;

    wishvel = pm_forward * fmove + pm_right * smove;

    if (self.pm_movetype != PM_MOVETYPE_FLY && fmove == 0 && smove == 0 && upmove == 0)
        wishvel_z -= 60;   // sink slowly when stationary
    else
        wishvel_z += upmove;

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }
    wishspeed *= 0.7;

    PM_Accelerate(normalize(wishvel), wishspeed, mv_wateraccelerate);

    return PM_StepSlideMove(FALSE);
}

// ============================================================================
//  17.  PM_FlyMove
// ============================================================================

float PM_FlyMove()
{
    vector wishvel;
    float  wishspeed;
    float  scale;

    scale = PM_MoveScale();

    wishvel = pm_forward * (input_movevalues_x * scale)
            + pm_right   * (input_movevalues_y * scale)
            + v_up       * (input_movevalues_z * scale);

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }

    PM_Accelerate(normalize(wishvel), wishspeed, mv_accelerate);

    return PM_StepSlideMove(FALSE);
}

// ============================================================================
//  18.  PM_AirMove
// ============================================================================

float PM_AirMove()
{
    vector wishvel, wishdir;
    vector fwd2d, right2d;
    float  wishspeed;
    float  fmove, smove;
    float  scale;

    scale = PM_MoveScale();
    fmove = input_movevalues_x * scale;
    smove = input_movevalues_y * scale;

    // flatten forward and right into the horizontal plane
    fwd2d   = pm_forward;
    fwd2d_z = 0;
    right2d   = pm_right;
    right2d_z = 0;

    if (fwd2d != '0 0 0')   fwd2d   = normalize(fwd2d);
    if (right2d != '0 0 0') right2d = normalize(right2d);

    wishvel   = fwd2d * fmove + right2d * smove;
    wishvel_z = 0;

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }
    wishdir = (wishspeed > 0) ? normalize(wishvel) : wishvel;

    if (pm_onground)
    {
        // Grounded movement in pmove.c zeroes z before the step-slide path
        // unless the separate slidefix branch is being used. Keeping a
        // residual negative z here causes forward+down traces and "sticky"
        // wall catches on brush seams and 45-degree walls.
        pm_velocity_z = 0;

        // CS 1.6 stamina: landing fatigue bleeds horizontal speed for ~1.3s
        // after each jump (fuser2 decays from 1315 to 0 over that window).
        // factor_ref is the per-tick multiplier CS uses at 100 Hz (dt=0.01).
        // Raising it to (pm_frametime/0.01) makes the effect framerate-independent:
        // same net slowdown regardless of tickrate.
        if (mv_stamina && self.pm_fuser2 > 0)
        {
            float factor_ref = (100 - self.pm_fuser2 * 0.001 * 19) * 0.01;
            float factor = pow(factor_ref, pm_frametime * 100);
            pm_velocity_x *= factor;
            pm_velocity_y *= factor;
        }

        PM_Accelerate(wishdir, wishspeed, mv_accelerate);

        // if we ended up with no horizontal movement, stop cleanly
        if (pm_velocity_x == 0 && pm_velocity_y == 0)
        {
            pm_velocity_z = 0;
            return 0;
        }

        float ground_blocked = PM_StepSlideMove(FALSE);

        // Slope-glue: after zeroing pm_velocity_z we have no downward component
        // to clip along the slope, so the player walks off slope edges.
        // GoldSrc's PM_WalkMove fixes this by tracing down STEPSIZE after the
        // slide and snapping to any floor surface found.
        PM_Trace(pm_origin, pm_origin - '0 0 1' * PM_STEPSIZE);
        if (trace_fraction < 1 && !trace_startsolid && !trace_allsolid
            && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
        {
            pm_origin = trace_endpos;
        }

        return ground_blocked;
    }
    else
    {
        // airborne – uses the separate air-acceleration value (GoldSrc-style)
        PM_AirAccelerate(wishdir, wishspeed, mv_airaccelerate);

        // gravity
        pm_velocity_z -= mv_entgravity * mv_gravity * pm_frametime;

        return PM_SlideMove();
    }
}

// ============================================================================
//  19.  PM_CategorizePosition
// ============================================================================

void PM_CategorizePosition()
{
    vector hull_maxs;
    float  hull_height;

    hull_maxs = PM_CurrentMaxs();
    vector hull_mins = PM_CurrentMins();
    hull_height = hull_maxs_z - hull_mins_z;

    // --- ground check ---
    // trace 1 unit below origin
    PM_Trace(pm_origin, pm_origin - '0 0 1');

    if (pm_velocity_z > 180)
    {
        pm_onground    = FALSE;
        pm_groundnormal = '0 0 1';
    }
    else if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
    {
        pm_onground     = TRUE;
        pm_groundnormal = trace_plane_normal;
        pm_origin       = trace_endpos;   // snap to ground surface
        self.pm_waterjumptime = 0;        // cancel water-jump on landing
    }
    else
    {
        pm_onground     = FALSE;
        pm_groundnormal = trace_plane_normal;
    }

    // --- water level check ---
    // Sample the current hull: feet, midpoint, then eye position.

    pm_waterlevel = 0;
    pm_watertype  = CONTENT_EMPTY;

    local vector wpt;
    local float  cont;
    wpt_x = pm_origin_x;
    wpt_y = pm_origin_y;

    wpt_z = pm_origin_z + hull_mins_z + 1;
    cont  = pointcontents(wpt);
    if (cont <= CONTENT_WATER)
    {
        pm_watertype  = cont;
        pm_waterlevel = 1;

        wpt_z = pm_origin_z + hull_mins_z + hull_height * 0.5;
        cont  = pointcontents(wpt);
        if (cont <= CONTENT_WATER)
        {
            pm_waterlevel = 2;

            wpt_z = pm_origin_z + self.view_ofs_z;
            cont  = pointcontents(wpt);
            if (cont <= CONTENT_WATER)
                pm_waterlevel = 3;
        }
    }
}

// ============================================================================
//  20.  PM_CheckJump
// ============================================================================

void PM_CheckJump()
{
    float dp;

    // flying players jump via PM_FlyMove
    if (self.pm_movetype == PM_MOVETYPE_FLY)
        return;

    // dead – latch the held flag and bail
    if (self.pm_movetype == PM_MOVETYPE_DEAD)
    {
        self.pm_jump_held = TRUE;
        return;
    }

    // button released – clear the held latch
    if (!(input_buttons & PM_BTN_JUMP))
    {
        self.pm_jump_held = FALSE;
        return;
    }

    // ladder jump: push away from wall + upward
    if (pm_on_ladder)
    {
        if (self.pm_jump_held)
            return;

        pm_velocity               = pm_ladder_normal * 270;
        pm_velocity_z             = 0;    // GoldSrc: purely horizontal, gravity takes over
        pm_onground               = FALSE;
        self.pm_jump_held         = TRUE;
        self.pm_ladder_detach_time = 0.6;
        pm_on_ladder              = FALSE;  // skip PM_LadderMove this step
        return;
    }

    // button is held from here onward

    // water-jump already in progress
    if (self.pm_waterjumptime)
        return;

    // in water – do a water-jump
    if (pm_waterlevel >= 2)
    {
        if (pm_watertype == CONTENT_WATER)
            pm_velocity_z = 100;
        else if (pm_watertype == CONTENT_SLIME)
            pm_velocity_z = 80;
        else
            pm_velocity_z = 50;

        pm_onground = FALSE;
        return;
    }

    // not on the ground – can't jump
    if (!pm_onground)
        return;

    // pogo prevention: require button release between jumps unless autohop is on
    if (self.pm_jump_held && !mv_autohop)
        return;

    // ramp fix: if we have downward momentum along the ground normal, clip it
    dp = pm_velocity * pm_groundnormal;
    if (pm_velocity_z < 0 && dp < PM_MAX_JUMPFIX_DP)
        pm_velocity = PM_ClipVelocity(pm_velocity, pm_groundnormal, 1);

    pm_onground       = FALSE;
    pm_velocity_z    += 270;

    // CS 1.6 stamina: penalise jump height if still fatigued, then reset timer
    if (mv_stamina)
    {
        if (self.pm_fuser2 > 0)
            pm_velocity_z *= (100 - self.pm_fuser2 * 0.001 * 19) * 0.01;
        self.pm_fuser2 = 1315.7894;
    }

    self.pm_jump_held  = TRUE;
    self.pm_jump_msec  = pm_frametime * 1000;
}

// ============================================================================
//  21.  PM_CheckWaterJump
// ============================================================================

void PM_CheckWaterJump()
{
    vector flat_fwd, spot;
    float  cont;

    if (self.pm_waterjumptime)
        return;
    if (pm_velocity_z < -180)
        return;

    // flatten forward into horizontal
    flat_fwd   = pm_forward;
    flat_fwd_z = 0;
    if (flat_fwd == '0 0 0')
        return;
    flat_fwd = normalize(flat_fwd);

    // 24 units forward, 8 above origin – must be solid
    spot = pm_origin + flat_fwd * 24;
    spot_z += 8;
    cont = pointcontents(spot);
    if (cont != CONTENT_SOLID)
        return;

    // 24 more units up from that spot – must be empty (air above the ledge)
    spot_z += 24;
    cont = pointcontents(spot);
    if (cont != CONTENT_EMPTY)
        return;

    // conditions met – launch the water jump
    pm_velocity_x          = flat_fwd_x * 50;
    pm_velocity_y          = flat_fwd_y * 50;
    pm_velocity_z          = 310;
    self.pm_waterjumptime  = 2;
    self.pm_jump_held      = TRUE;
}

// ============================================================================
//  22.  PM_NudgePosition  –  un-stuck on 1/8-unit grid
// ============================================================================

void PM_NudgePosition()
{
    vector  base, try;
    float   i, x, y, z;
    // sign table: 0, -0.125, +0.125
    local float sign[3];
    sign[0] = 0;
    sign[1] = -0.125;
    sign[2] =  0.125;

    // snap to 1/8-unit grid
    base_x = rint(pm_origin_x * 8) / 8;
    base_y = rint(pm_origin_y * 8) / 8;
    base_z = rint(pm_origin_z * 8) / 8;

    // try 27 offsets (3 axes × 3 values)
    for (i = 0; i < 27; i++)
    {
        x = i - floor(i / 3) * 3;
        y = floor(i / 3) - floor(i / 9) * 3;
        z = floor(i / 9);

        try_x = base_x + sign[x];
        try_y = base_y + sign[y];
        try_z = base_z + sign[z];

        if (PM_TestPosition(try))
        {
            pm_origin = try;
            return;
        }
    }

    // nudging on the grid failed – try pushing up 1-18 units
    try = base;
    for (i = 1; i <= 18; i++)
    {
        try_z = base_z + i;
        if (PM_TestPosition(try))
        {
            pm_origin = try;
            return;
        }
    }

    // nothing worked – leave position unchanged
    pm_origin = base;
}

// ============================================================================
//  23.  PM_SpectatorMove
// ============================================================================

void PM_SpectatorMove()
{
    vector wishvel, wishdir;
    float  wishspeed, speed, newspeed, drop;

    // friction
    speed = vlen(pm_velocity);
    if (speed > 0)
    {
        drop     = speed * mv_friction * 1.5 * pm_frametime;
        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
    }

    // build wish velocity
    wishvel = pm_forward * input_movevalues_x
            + pm_right   * input_movevalues_y
            + v_up       * input_movevalues_z;

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_spectatormaxspeed)
    {
        wishvel   = wishvel * (mv_spectatormaxspeed / wishspeed);
        wishspeed = mv_spectatormaxspeed;
    }

    if (wishspeed > 0)
    {
        wishdir = normalize(wishvel);
        PM_Accelerate(wishdir, wishspeed, mv_accelerate);
        // cap to spectatormaxspeed after acceleration
        speed = vlen(pm_velocity);
        if (speed > mv_spectatormaxspeed)
            pm_velocity = pm_velocity * (mv_spectatormaxspeed / speed);
    }

    pm_origin += pm_velocity * pm_frametime;
}

// ============================================================================
//  24.  PM_ReadMovevars  –  populate movevars from engine cvars
// ============================================================================

void PM_ReadMovevars()
{
    // Hull height cvar — set to 56 (default) or 72 (GoldSrc proportions).
    // All duck/view values are derived so crouching adjusts automatically.
    float h;
    h = cvar("pm_hull_height");
    if (h < 32) h = 56;

    //  standing hull:  0 → h   (feet at origin)
    //  duck hull:    h/4 → 3h/4 (symmetric shrink — feet pull up h/4 in air)
    //  eye heights:  h-8 standing, 3h/4-4 ducked (after ground origin shift, eyes at h/4-4 from floor)
    PM_MAXS_x = 16;         PM_MAXS_y = 16;         PM_MAXS_z = h;
    PM_DUCK_MINS_x = -16;   PM_DUCK_MINS_y = -16;   PM_DUCK_MINS_z = h * 0.25;
    PM_DUCK_MAXS_x = 16;    PM_DUCK_MAXS_y = 16;    PM_DUCK_MAXS_z = h * 0.75;
    PM_VIEW_OFS_x = 0;      PM_VIEW_OFS_y = 0;      PM_VIEW_OFS_z = h - 8;
    PM_DUCK_VIEW_OFS_x = 0; PM_DUCK_VIEW_OFS_y = 0; PM_DUCK_VIEW_OFS_z = h * 0.75 - 4;

    mv_gravity           = cvar("sv_gravity");
    if (!mv_gravity)          mv_gravity           = 800;

    mv_maxspeed          = cvar("sv_maxspeed");
    if (!mv_maxspeed)         mv_maxspeed          = 320;

    mv_stopspeed         = cvar("sv_stopspeed");
    if (!mv_stopspeed)        mv_stopspeed         = 100;

    mv_friction          = cvar("sv_friction");
    if (!mv_friction)         mv_friction          = 4;

    mv_waterfriction     = cvar("sv_waterfriction");
    if (!mv_waterfriction)    mv_waterfriction     = 1;

    mv_accelerate        = cvar("sv_accelerate");
    if (!mv_accelerate)       mv_accelerate        = 10;

    // sv_airaccelerate: GoldSrc uses ~10, Quake uses same as sv_accelerate.
    // A separate lower value gives tighter, more predictable air strafing.
    mv_airaccelerate     = cvar("sv_airaccelerate");
    if (!mv_airaccelerate)    mv_airaccelerate     = mv_accelerate;

    mv_wateraccelerate   = cvar("sv_wateraccelerate");
    if (!mv_wateraccelerate)  mv_wateraccelerate   = 10;

    mv_spectatormaxspeed = cvar("sv_spectatormaxspeed");
    if (!mv_spectatormaxspeed) mv_spectatormaxspeed = 500;

    mv_stamina           = cvar("sv_stamina");   // 0 = off (default), 1 = CS 1.6 landing fatigue
    mv_autohop           = cvar("sv_autohop");   // 0 = require jump release (default), 1 = autohop

    // per-entity gravity multiplier
    mv_entgravity = self.gravity ? self.gravity : 1;
}

// ============================================================================
//  25.  PM_CheckTriggerPushes  –  velocity impulse from overlapping push triggers
// ============================================================================

void(entity trig) PM_ApplyTriggerPush =
{
    vector offset;
    float  current, delta;

    if (trig.spawnflags & PUSH_SOURCE)
    {
        // boost along movedir only up to speed; don't reduce existing speed
        current = pm_velocity * trig.movedir;
        delta   = trig.speed - current;
        if (delta > 0)
            pm_velocity = pm_velocity + trig.movedir * delta;
    }
    else if (trig.spawnflags & PUSH_ADDITIVE)
        pm_velocity = pm_velocity + trig.movedir * trig.speed;
    else
        pm_velocity = trig.movedir * trig.speed;

    if (trig.spawnflags & PUSH_TUNNEL)
    {
        // pull toward the trigger's centerline while pushing
        offset = (trig.origin + (trig.mins + trig.maxs) * 0.5) - pm_origin;
        offset = offset - trig.movedir * (offset * trig.movedir);
        pm_velocity = pm_velocity + offset * trig.speed * 0.1;
    }
};

void() PM_CheckTriggerPushes =
{
    entity trig;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;

    player_absmin = pm_origin + PM_CurrentMins();
    player_absmax = pm_origin + PM_CurrentMaxs();

    for (trig = push_trigger_list; trig; trig = trig.push_next)
    {
        trig_absmin = trig.origin + trig.mins;
        trig_absmax = trig.origin + trig.maxs;

        if (player_absmin_x >= trig_absmax_x) continue;
        if (player_absmax_x <= trig_absmin_x) continue;
        if (player_absmin_y >= trig_absmax_y) continue;
        if (player_absmax_y <= trig_absmin_y) continue;
        if (player_absmin_z >= trig_absmax_z) continue;
        if (player_absmax_z <= trig_absmin_z) continue;

        PM_ApplyTriggerPush(trig);
    }
};

// ============================================================================
//  26.  PM_CheckTeleportTriggers  –  instant position snap through teleporters
// ============================================================================

void() PM_CheckTeleportTriggers =
{
    entity trig;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;

    // guard: player recently teleported, don't re-fire
    if (self.pm_teleport_time > 0)
        return;

    player_absmin = pm_origin + PM_CurrentMins();
    player_absmax = pm_origin + PM_CurrentMaxs();

    for (trig = teleport_trigger_list; trig; trig = trig.tele_next)
    {
        if (!trig.tele_resolved) continue;

        trig_absmin = trig.origin + trig.mins;
        trig_absmax = trig.origin + trig.maxs;

        if (player_absmin_x >= trig_absmax_x) continue;
        if (player_absmax_x <= trig_absmin_x) continue;
        if (player_absmin_y >= trig_absmax_y) continue;
        if (player_absmax_y <= trig_absmin_y) continue;
        if (player_absmin_z >= trig_absmax_z) continue;
        if (player_absmax_z <= trig_absmin_z) continue;

        // snap to destination
        pm_origin   = trig.tele_dest_origin;
        pm_onground = FALSE;

        if (!(trig.spawnflags & TELEPORT_KEEP_VELOCITY))
            pm_velocity = '0 0 0';

        self.pm_teleport_time = 0.2;

        // view angle snap (consumed by CSQC_UpdateView this frame; not replayed)
        if (trig.tele_dest_angles != '0 0 0')
        {
            self.pm_snap_angles = trig.tele_dest_angles;
            self.pm_angle_snap  = TRUE;
        }

        // only one teleport per step
        return;
    }
};

// ============================================================================
//  27.  PM_CheckLadder + PM_LadderMove  –  GoldSrc-style ladder movement
// ============================================================================

void() PM_CheckLadder =
{
    entity trig;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;
    vector flat_fwd;

    pm_on_ladder     = FALSE;
    pm_ladder_normal = '0 0 0';

    // recently jumped off — don't re-grab
    if (self.pm_ladder_detach_time > 0)
        return;

    player_absmin = pm_origin + PM_CurrentMins();
    player_absmax = pm_origin + PM_CurrentMaxs();

    for (trig = ladder_trigger_list; trig; trig = trig.ladder_next)
    {
        trig_absmin = trig.origin + trig.mins;
        trig_absmax = trig.origin + trig.maxs;

        if (player_absmin_x >= trig_absmax_x) continue;
        if (player_absmax_x <= trig_absmin_x) continue;
        if (player_absmin_y >= trig_absmax_y) continue;
        if (player_absmax_y <= trig_absmin_y) continue;
        if (player_absmin_z >= trig_absmax_z) continue;
        if (player_absmax_z <= trig_absmin_z) continue;

        pm_on_ladder = TRUE;

        if (trig.movedir != '0 0 0')
        {
            pm_ladder_normal = trig.movedir;
        }
        else
        {
            // No explicit normal: derive from horizontal view direction.
            // pm_forward is already set from input_angles, so this is
            // deterministic and identical on server and client.
            flat_fwd   = pm_forward;

            flat_fwd_z = 0;
            if (vlen(flat_fwd) > 0)
                pm_ladder_normal = normalize(flat_fwd);
            else
                pm_ladder_normal = '1 0 0';
        }
        return;
    }
};

// GoldSrc-style ladder movement.
//
// Wish velocity uses the full 3D forward vector (pitch included) so looking
// up while pressing forward is already faster than looking horizontal.
// On top of that, GoldSrc redirects the component pressing INTO the wall as
// extra upward movement, and pressing AWAY from the wall as downward movement.
// This gives the signature HL feel:
//   - look horizontal + W  → climb up
//   - look up + W          → climb up fast
//   - S (or back)          → slide down
//   - look up + W + facing wall → maximum upward speed
void() PM_LadderMove =
{
    vector wishvel, climb;
    float  along_normal, wishspeed;
    float  scale;

    scale = PM_MoveScale();

    // Full 3D forward: looking up contributes positive wishvel.z already
    wishvel = pm_forward * (input_movevalues_x * scale)
            + pm_right   * (input_movevalues_y * scale);
    wishvel_z += input_movevalues_z * scale;

    wishspeed = vlen(wishvel);
    if (wishspeed > mv_maxspeed)
    {
        wishvel   = wishvel * (mv_maxspeed / wishspeed);
        wishspeed = mv_maxspeed;
    }

    // Decompose into tangential component (along the ladder surface)
    along_normal = wishvel * pm_ladder_normal;
    climb        = wishvel - pm_ladder_normal * along_normal;

    // GoldSrc: the into-wall component drives vertical movement.
    // Our pm_ladder_normal is outward (toward player), so:
    //   along_normal < 0 = pressing INTO wall  → downward (climb_z decreases)
    //   along_normal > 0 = pressing AWAY wall  → upward   (climb_z increases)
    // Derived from PM_LadderMove: final.z = lateral.z - dot(velocity, N_inward)
    //                                     = lateral.z + dot(velocity, N_outward)
    climb_z += along_normal;

    pm_velocity = climb;
    PM_StepSlideMove(FALSE);
};

// ============================================================================
//  28.  PM_PlayerMoveStep  –  single fixed-size simulation slice
// ============================================================================

void PM_PlayerMoveStep()
{
    float  blocked;
    float  dp;

    // --- load working state from entity ---
    pm_origin   = self.origin;
    pm_velocity = self.velocity;
    pm_onground = (self.flags & FL_ONGROUND) ? TRUE : FALSE;

    pm_frametime = input_timelength;
    if (pm_frametime <= 0)
        return;

    // --- read cvars ---
    PM_ReadMovevars();

    // --- build movement axes ---
    makevectors(input_angles);
    pm_forward = v_forward;
    pm_right   = v_right;

    // --- shortcut for NONE / SPECTATOR ---
    if (self.pm_movetype == PM_MOVETYPE_NONE)
    {
        PM_CategorizePosition();
        goto done;
    }

    if (self.pm_movetype == PM_MOVETYPE_SPECTATOR)
    {
        PM_SpectatorMove();
        pm_onground = FALSE;
        goto done;
    }

    // --- general movement ---
    PM_NudgePosition();
    PM_CategorizePosition();

    // cancel water-jump when falling hard or dead
    if (pm_velocity_z < 0 || self.pm_movetype == PM_MOVETYPE_DEAD)
        self.pm_waterjumptime = 0;

    // decrement water-jump timer
    if (self.pm_waterjumptime > 0)
    {
        self.pm_waterjumptime -= pm_frametime;
        if (self.pm_waterjumptime < 0)
            self.pm_waterjumptime = 0;
    }

    // advance jump-msec accumulator (expires after 50 ms)
    if (self.pm_jump_msec)
    {
        self.pm_jump_msec += pm_frametime * 1000;
        if (self.pm_jump_msec > 50)
            self.pm_jump_msec = 0;
    }

    if (self.pm_duck_msec > 0)
    {
        self.pm_duck_msec -= pm_frametime * 1000;
        if (self.pm_duck_msec < 0)
            self.pm_duck_msec = 0;
    }

    if (self.pm_teleport_time > 0)
    {
        self.pm_teleport_time -= pm_frametime;
        if (self.pm_teleport_time < 0)
            self.pm_teleport_time = 0;
    }

    if (self.pm_ladder_detach_time > 0)
    {
        self.pm_ladder_detach_time -= pm_frametime;
        if (self.pm_ladder_detach_time < 0)
            self.pm_ladder_detach_time = 0;
    }

    if (self.pm_fuser2 > 0)
    {
        self.pm_fuser2 -= pm_frametime * 1000;
        if (self.pm_fuser2 < 0)
            self.pm_fuser2 = 0;
    }

    PM_CheckDuck();
    PM_CheckLadder();

    // check for wall-launched water jump (waist-deep)
    if (pm_waterlevel == 2 && self.pm_movetype != PM_MOVETYPE_FLY)
        PM_CheckWaterJump();

    PM_CheckJump();

    PM_Friction();

    if (pm_on_ladder && pm_waterlevel < 2)
        PM_LadderMove();
    else if (pm_waterlevel >= 2)
        blocked = PM_WaterMove();
    else if (self.pm_movetype == PM_MOVETYPE_FLY)
        blocked = PM_FlyMove();
    else
        blocked = PM_AirMove();

    // second categorize for landing detection
    PM_CategorizePosition();

    // ramp landing fix: if we just landed and had significant downward speed
    if (pm_onground && pm_velocity_z < -300)
    {
        dp = pm_velocity * pm_groundnormal;
        if (dp < PM_MAX_JUMPFIX_DP)
            pm_velocity = PM_ClipVelocity(pm_velocity, pm_groundnormal, 1);
    }

    // apply any push triggers the player is standing inside
    PM_CheckTriggerPushes();

    // teleport if inside a trigger_teleport volume
    PM_CheckTeleportTriggers();

done:
    // --- write results back to entity ---
    setorigin(self, pm_origin);
    self.velocity = pm_velocity;
    PM_SyncHull();

    if (pm_onground)
        self.flags = self.flags | FL_ONGROUND;
    else
        self.flags = self.flags & ~FL_ONGROUND;
}

// ============================================================================
//  26.  PM_PlayerMove  –  fixed-step wrapper around PM_PlayerMoveStep
// ============================================================================

void PM_PlayerMove()
{
    float fixedstep;
    float remaining;
    float saved_timelength;

    // Use sv_mintic as the physics step size so one cvar controls both
    // FTE's server tick rate and our internal simulation rate.
    // 0.015 = 66.67 Hz (standard CS 1.6), 0.01 = 100 Hz (competitive CS 1.6).
    fixedstep = cvar("sv_mintic");
    if (fixedstep < 0.001) fixedstep = 0.01;

    saved_timelength = input_timelength;
    remaining = max(self.pm_timecarry + input_timelength, 0);

    while (remaining + PM_FIXEDSTEP_EPSILON >= fixedstep)
    {
        input_timelength = fixedstep;
        PM_PlayerMoveStep();

        remaining -= fixedstep;
        if (remaining < PM_FIXEDSTEP_EPSILON)
        {
            remaining = 0;
            break;
        }
    }

    self.pm_timecarry = remaining;
    input_timelength = saved_timelength;
}
