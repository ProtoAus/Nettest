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

vector PM_MINS             = '-16 -16 0';
vector PM_MAXS             = '16 16 56';
vector PM_DUCK_MAXS        = '16 16 28';
vector PM_VIEW_OFS         = '0 0 48';
vector PM_DUCK_VIEW_OFS    = '0 0 24';

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
float  PM_FIXEDSTEP        = 0.01;
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

void() PM_CategorizePosition;
void() PM_PlayerMove;
void() PM_PlayerMoveStep;

// ============================================================================
//  8.  PM_Trace  –  tracebox wrapper using the shared hull
// ============================================================================

vector PM_CurrentMaxs()
{
    if (self.flags & FL_DUCKING)
        return PM_DUCK_MAXS;

    return PM_MAXS;
}

void PM_TraceHull(vector start, vector mins, vector maxs, vector end)
{
    tracebox(start, mins, maxs, end, MOVE_NOMONSTERS, self);
}

void PM_Trace(vector start, vector end)
{
    PM_TraceHull(start, PM_MINS, PM_CurrentMaxs(), end);
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
    return PM_TestPositionExt(pos, PM_MINS, PM_CurrentMaxs());
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
        setsize(self, PM_MINS, PM_DUCK_MAXS);
    else
        setsize(self, PM_MINS, PM_MAXS);
#endif
}

void PM_UnDuck()
{
    if (!PM_TestPositionExt(pm_origin, PM_MINS, PM_MAXS))
        return;

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

                PM_SyncHull();
                PM_CategorizePosition();
            }
            else
            {
                duck_fraction = PM_SplineFraction(duck_time, 1 / PM_DUCK_TIME);
                self.view_ofs = PM_VIEW_OFS * (1 - duck_fraction)
                              + PM_DUCK_VIEW_OFS * duck_fraction;
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

        PM_Accelerate(wishdir, wishspeed, mv_accelerate);

        // if we ended up with no horizontal movement, stop cleanly
        if (pm_velocity_x == 0 && pm_velocity_y == 0)
        {
            pm_velocity_z = 0;
            return 0;
        }

        return PM_StepSlideMove(FALSE);
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
    hull_height = hull_maxs_z - PM_MINS_z;

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

    wpt_z = pm_origin_z + 1;
    cont  = pointcontents(wpt);
    if (cont <= CONTENT_WATER)
    {
        pm_watertype  = cont;
        pm_waterlevel = 1;

        wpt_z = pm_origin_z + PM_MINS_z + hull_height * 0.5;
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

    // pogo prevention: button was already held from the previous landing
//    if (self.pm_jump_held && !self.pm_jump_msec)
//        return;

    // ramp fix: if we have downward momentum along the ground normal, clip it
    dp = pm_velocity * pm_groundnormal;
    if (pm_velocity_z < 0 && dp < PM_MAX_JUMPFIX_DP)
        pm_velocity = PM_ClipVelocity(pm_velocity, pm_groundnormal, 1);

    pm_onground       = FALSE;
    pm_velocity_z    += 270;
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

    // per-entity gravity multiplier
    mv_entgravity = self.gravity ? self.gravity : 1;
}

// ============================================================================
//  25.  PM_PlayerMoveStep  –  single fixed-size simulation slice
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

    PM_CheckDuck();

    // check for wall-launched water jump (waist-deep)
    if (pm_waterlevel == 2 && self.pm_movetype != PM_MOVETYPE_FLY)
        PM_CheckWaterJump();

    PM_CheckJump();

    PM_Friction();

    if (pm_waterlevel >= 2)
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
    float remaining;
    float saved_timelength;

    saved_timelength = input_timelength;
    remaining = max(self.pm_timecarry + input_timelength, 0);

    while (remaining + PM_FIXEDSTEP_EPSILON >= PM_FIXEDSTEP)
    {
        input_timelength = PM_FIXEDSTEP;
        PM_PlayerMoveStep();

        remaining -= PM_FIXEDSTEP;
        if (remaining < PM_FIXEDSTEP_EPSILON)
        {
            remaining = 0;
            break;
        }
    }

    self.pm_timecarry = remaining;
    input_timelength = saved_timelength;
}
