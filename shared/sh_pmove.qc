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
float  PM_MAX_CLIP_PLANES  = 8;   // raised from 5 to match ramp-fix bump count
float  PM_MAX_JUMPFIX_DP   = -0.1;  // ramp-fix dot-product threshold
float  PM_BTN_JUMP         = 2;     // bit in input_buttons
float  PM_BTN_DUCK         = 32;    // +button6 via DP_INPUTBUTTONS
float  PM_BTN_SPRINT       = 8;     // +button4  — run faster (sv_sprintspeed)
float  PM_BTN_USE          = 128;   // +button8 / +use     — high friction
float  PM_BTN_WALK         = 256;   // +speed   / +button9 — walk slower (sv_walkspeed)
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
float  PM_MOVETYPE_NOCLIP    = 5;

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
float  mv_shiftspeed;     // reduced max speed when +button4 (shift/walk) is held
float  mv_walkspeed;      // effective max speed when PM_BTN_WALK is held  (0 = disabled)
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
void(string snd, float vol) PM_EmitStepSound;

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
    tracebox(start, mins, maxs, end, MOVE_NORMAL, self);
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
#if defined(SSQC) || defined(CSQC)
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

    // Residual penetration fix (Momentum Mod): ensure clipped velocity
    // doesn't still move into the plane due to float precision.
    float adjust = out * normal;
    if (adjust < 0)
        out = out - (normal * adjust);

    return out;
}

// ============================================================================
//  11.  PM_SlideMove  –  multi-plane clipped slide with ramp-seam fix
//
//  Changes from vanilla pmove:
//    · bump count raised from 4 to pm_ramp_bumpcount (default 8)
//    · stuck_on_ramp: when zero progress is made against a surface while
//      airborne, find a valid escape plane and retrace from fixed_origin
//      nudged off the seam, instead of clipping to a degenerate normal
//    · primal_velocity reversal: don't zero velocity, just break — lets the
//      player keep momentum through ramp seams (ramp_slope_fix "OppositeDirection")
//    · allFraction == 0: same — don't zero velocity at the end
// ============================================================================

float PM_SlideMove()
{
    local vector planes[8];
    vector  primal_velocity;
    vector  original_velocity;
    vector  new_velocity;
    vector  dir;
    vector  fixed_origin;       // ramp fix: retrace start, offset off seam
    vector  valid_plane;        // ramp fix: escape surface normal
    float   time_left;
    float   blocked;
    float   num_planes;
    float   i, j;
    float   d;
    float   numbumps;
    float   stuck_on_ramp;
    float   has_valid_plane;
    float   all_fraction;

    numbumps = cvar("pm_ramp_bumpcount");
    if (numbumps < 4)
        numbumps = 8;

    primal_velocity   = pm_velocity;
    original_velocity = pm_velocity;
    blocked           = 0;
    num_planes        = 0;
    time_left         = pm_frametime;
    fixed_origin      = pm_origin;
    valid_plane       = '0 0 0';
    stuck_on_ramp     = FALSE;
    has_valid_plane   = FALSE;
    all_fraction      = 0;

    for (i = 0; i < numbumps; i++)
    {
        if (pm_velocity == '0 0 0')
            break;

        // --- Ramp-seam fix: escape when completely blocked while airborne ---
        if (stuck_on_ramp)
        {
            if (!has_valid_plane)
            {
                // Search stored planes for a usable escape normal
                local float k;
                for (k = num_planes - 1; k >= 0; k--)
                {
                    if (planes[k] != '0 0 0' && planes[k] != valid_plane)
                    {
                        valid_plane     = planes[k];
                        has_valid_plane = TRUE;
                        break;
                    }
                }
            }

            if (has_valid_plane)
            {
                // Clip velocity to the escape plane and nudge origin off seam
                pm_velocity       = PM_ClipVelocity(pm_velocity, valid_plane, 1);
                original_velocity = pm_velocity;
                fixed_origin      = fixed_origin + valid_plane * 0.2;
            }
            else
            {
                stuck_on_ramp = FALSE;
            }
        }

        // --- Trace forward ---
        if (stuck_on_ramp && has_valid_plane)
            PM_TraceHull(fixed_origin, PM_CurrentMins(), PM_CurrentMaxs(),
                         fixed_origin + pm_velocity * time_left);
        else
            PM_Trace(pm_origin, pm_origin + pm_velocity * time_left);

        if (trace_startsolid || trace_allsolid)
        {
            pm_velocity = '0 0 0';
            return PM_BLOCKED_FLOOR | PM_BLOCKED_STEP | PM_BLOCKED_OTHER;
        }

        if (trace_fraction > 0)
        {
            pm_origin         = trace_endpos;
            fixed_origin      = trace_endpos;
            original_velocity = pm_velocity;
            num_planes        = 0;
            stuck_on_ramp     = FALSE;
            has_valid_plane   = FALSE;
            all_fraction     += trace_fraction;
        }

        if (trace_fraction == 1)
        {
            // Stuck-on-arrival check (Momentum Mod): a swept trace can
            // report fraction==1 while the endpoint is embedded in terrain.
            // Re-test with an unswept box to catch this.
            if (i > 0)
            {
                PM_Trace(pm_origin, pm_origin);
                if (trace_startsolid || trace_fraction != 1)
                {
                    pm_velocity = '0 0 0';
                    break;
                }
            }
            break;   // moved the whole way, no collision
        }

        // Ramp-seam fix: zero progress against a surface while airborne —
        // the plane normal may be degenerate.  Store it and try the retrace.
        if (trace_fraction == 0 && !pm_onground && i > 0)
        {
            if (trace_plane_normal != '0 0 0')
            {
                valid_plane     = trace_plane_normal;
                has_valid_plane = TRUE;
            }
            stuck_on_ramp = TRUE;
        }

        // Classify the surface hit
        if (trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
            blocked |= PM_BLOCKED_FLOOR;
        else if (!trace_plane_normal_z)
            blocked |= PM_BLOCKED_STEP;
        else
            blocked |= PM_BLOCKED_OTHER;

        // Store the collision plane
        if (num_planes < PM_MAX_CLIP_PLANES)
        {
            planes[num_planes] = trace_plane_normal;
            num_planes++;
        }

        time_left -= time_left * trace_fraction;

        // First-impact airborne differentiated clip (Momentum Mod):
        // On the very first collision while airborne, use different
        // overbounce for floors vs walls.  sv_bounce defaults to 0,
        // making this a no-op unless explicitly configured for surf.
        if (num_planes == 1 && !pm_onground)
        {
            vector first_plane = planes[0];
            if (first_plane_z >= PM_MIN_STEP_NORMAL)
            {
                // Floor/slope: no bounce
                pm_velocity = PM_ClipVelocity(original_velocity, first_plane, 1);
            }
            else
            {
                // Wall: slight bounce based on sv_bounce
                float sv_bounce_val = cvar("sv_bounce");
                pm_velocity = PM_ClipVelocity(original_velocity, first_plane, 1 + sv_bounce_val);
            }
            original_velocity = pm_velocity;
            continue;
        }

        // Try each stored plane to find a compatible clip velocity
        for (j = 0; j < num_planes; j++)
        {
            new_velocity = PM_ClipVelocity(original_velocity, planes[j], 1);

            local float ok;
            ok = TRUE;
            local float kk;
            for (kk = 0; kk < num_planes; kk++)
            {
                if (kk == j)
                    continue;
                if ((new_velocity * planes[kk]) < 0)
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
            dir = normalize(crossproduct(planes[0], planes[1]));
            d   = dir * pm_velocity;
            pm_velocity = dir * d;
        }

        // if velocity reversed against primal, just stop without zeroing —
        // keeping momentum avoids sticking in ramp seams (ramp_slope_fix patch)
        if ((pm_velocity * primal_velocity) <= 0)
            break;
    }

    // if we made no progress at all, preserve velocity (ramp_slope_fix patch)
    // — the original code zeroed it here, which caused sticking on seams

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
    if (trace_startsolid && (blocked & PM_BLOCKED_STEP))
    {
        // Hull is flush with a wall face (NudgePosition grid-snapped us
        // onto the brush boundary).  Back off 0.125 units against our
        // movement direction and retry so the trace clears the seam.
        vector nudged = pm_origin - normalize(original_velocity) * 0.125;
        PM_Trace(nudged, nudged + '0 0 1' * stepsize);
    }
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

    if (down_dist_sq > up_dist_sq)
    {
        // flat path covered strictly more ground – use it
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

    if (pm_waterlevel >= 2)
    {
        speed = vlen(pm_velocity);
        if (speed < 1)
        {
            pm_velocity = '0 0 0';
            return;
        }

        // water friction
        drop = 0;
        drop += speed * mv_waterfriction * pm_waterlevel * pm_frametime;

        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
        return;
    }
    else if (self.pm_movetype == PM_MOVETYPE_FLY)
    {
        speed = vlen(pm_velocity);
        if (speed < 1)
        {
            pm_velocity = '0 0 0';
            return;
        }

        // fly friction
        drop = 0;
        drop += speed * PM_FLYFRICTION * pm_frametime;

        newspeed = max(speed - drop, 0) / speed;
        pm_velocity = pm_velocity * newspeed;
        return;
    }
    else if (pm_onground)
    {
        // Ground friction is based on horizontal speed only. Slope-clipped
        // vertical velocity is not player input and should not add extra drag
        // while walking up clip ramps or other sloped floors.
        vel2d   = pm_velocity;
        vel2d_z = 0;
        speed = vlen(vel2d);
        if (speed < 1)
        {
            pm_velocity_x = 0;
            pm_velocity_y = 0;
            return;
        }

        friction = mv_friction;

        // Holding +use on the ground doubles friction so the player slows
        // down noticeably when leaning against a wall or object.
        if (input_buttons & PM_BTN_USE)
            friction = friction * 4;

        drop = 0;
        control = max(speed, mv_stopspeed);
        drop += control * friction * pm_frametime;

        newspeed = max(speed - drop, 0) / speed;
        pm_velocity_x *= newspeed;
        pm_velocity_y *= newspeed;
        return;
    }
    else
    {
        // airborne – no friction
        return;
    }
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
    {
        if (!pm_onground)
            wishvel_z -= 60;   // sink slowly when stationary and airborne
    }
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

void PM_FollowGroundPlane()
{
    // Feet-origin adaptation: keep the horizontal speed the player earned,
    // then solve the Z component needed to stay tangent to the current floor.
    // This prevents ramp collision from shaving X/Y speed while walking uphill.
    if (!pm_onground)
        return;
    if (pm_groundnormal_z < PM_MIN_STEP_NORMAL)
        return;
    if (pm_groundnormal_z <= PM_FIXEDSTEP_EPSILON)
        return;

    pm_velocity_z = -(
        pm_velocity_x * pm_groundnormal_x +
        pm_velocity_y * pm_groundnormal_y
    ) / pm_groundnormal_z;
}

// ============================================================================
//  18.  PM_AirMove
// ============================================================================

float PM_AirMove()
{
    vector wishvel, wishdir;
    vector fwd2d, right2d;
    vector walk_dest;
    vector walk_delta;
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
            pm_velocity = '0 0 0';
            return 0;
        }

        // Feet-origin adaptation of GoldSrc's initial horizontal walk trace:
        // try to move straight along the current floor plane first. On ramps
        // this avoids feeding every frame through clip/step logic, which can
        // shave horizontal speed noticeably at lower sv_accelerate values.
        walk_delta = [pm_velocity_x * pm_frametime, pm_velocity_y * pm_frametime, 0];
        walk_dest = pm_origin + walk_delta;
        if (pm_groundnormal_z >= PM_MIN_STEP_NORMAL
            && pm_groundnormal_z > PM_FIXEDSTEP_EPSILON)
        {
            walk_dest_z += -(
                walk_delta_x * pm_groundnormal_x +
                walk_delta_y * pm_groundnormal_y
            ) / pm_groundnormal_z;
        }

        PM_Trace(pm_origin, walk_dest);
        if (trace_fraction == 1 && !trace_startsolid && !trace_allsolid)
        {
            pm_origin = trace_endpos;

            // Step-down snap: keep the player grounded when walking off
            // stairs/ledges up to PM_STEPSIZE high.  Mirrors the slope-glue
            // snap on the PM_StepSlideMove path below, and Source's
            // StayOnGround().
            PM_Trace(pm_origin, pm_origin - '0 0 1' * PM_STEPSIZE);
            if (trace_fraction < 1 && !trace_startsolid && !trace_allsolid
                && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
            {
                pm_origin = trace_endpos;
            }

            return 0;
        }

        PM_FollowGroundPlane();

        float ground_blocked = PM_StepSlideMove(FALSE);

        // Slope-glue: pull the player down onto downward slopes after zeroing z.
        // Only needed when we moved freely or hit a floor/angled surface — skip
        // when we blocked against a vertical wall (PM_BLOCKED_STEP).  Running
        // the snap at a wall-floor junction causes the hull to clip into the wall
        // by floating-point epsilon, producing a 1-frame sink + NudgePosition pop.
        if (!(ground_blocked & PM_BLOCKED_STEP))
        {
            PM_Trace(pm_origin, pm_origin - '0 0 1' * PM_STEPSIZE);
            if (trace_fraction < 1 && !trace_startsolid && !trace_allsolid
                && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
            {
                pm_origin = trace_endpos;
            }
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

    // --- water level check ---
    // Done first so the ground snap below can be skipped while swimming.

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

    // --- ground check ---
    // trace 2 units below origin (Momentum Mod uses 2 for more generous
    // ground detection, reducing ground-state flicker on uneven surfaces)
    PM_Trace(pm_origin, pm_origin - '0 0 2');

    if (pm_velocity_z > 180)
    {
        pm_onground    = FALSE;
        pm_groundnormal = '0 0 1';
    }
    else if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
    {
        pm_onground     = TRUE;
        pm_groundnormal = trace_plane_normal;
        // Skip the floor snap while swimming — it would kill upward velocity each frame.
        // Only snap if within 1 unit to avoid visible popping off small ledges
        // (ground detection reaches 2 units but snap stays conservative).
        if (pm_waterlevel < 2 && (pm_origin_z - trace_endpos_z) <= 1)
            pm_origin   = trace_endpos;
        self.pm_waterjumptime = 0;        // cancel water-jump on landing
    }
    else
    {
        // Quadrant ground check (Momentum Mod): the center trace hit a
        // steep surface — test 4 quarter-hull sub-boxes at hull corners
        // to find walkable ground the center missed at terrain seams.
        float found_ground = FALSE;
        if (trace_fraction < 1)
        {
            vector full_mins = PM_CurrentMins();
            vector full_maxs = PM_CurrentMaxs();
            vector qmins, qmaxs;
            vector gcheck_end = pm_origin - '0 0 2';

            // -x, -y quadrant
            qmins = full_mins;
            qmaxs = [min(0, full_maxs_x), min(0, full_maxs_y), full_maxs_z];
            PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
            if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                found_ground = TRUE;

            if (!found_ground)
            {
                // +x, +y quadrant
                qmins = [max(0, full_mins_x), max(0, full_mins_y), full_mins_z];
                qmaxs = full_maxs;
                PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
                if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                    found_ground = TRUE;
            }

            if (!found_ground)
            {
                // -x, +y quadrant
                qmins = [full_mins_x, max(0, full_mins_y), full_mins_z];
                qmaxs = [min(0, full_maxs_x), full_maxs_y, full_maxs_z];
                PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
                if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                    found_ground = TRUE;
            }

            if (!found_ground)
            {
                // +x, -y quadrant
                qmins = [max(0, full_mins_x), full_mins_y, full_mins_z];
                qmaxs = [full_maxs_x, min(0, full_maxs_y), full_maxs_z];
                PM_TraceHull(pm_origin, qmins, qmaxs, gcheck_end);
                if (trace_fraction < 1 && trace_plane_normal_z >= PM_MIN_STEP_NORMAL)
                    found_ground = TRUE;
            }
        }

        if (found_ground)
        {
            pm_onground     = TRUE;
            pm_groundnormal = trace_plane_normal;
            // Do NOT snap origin — quadrant endpos could push into wall
        }
        else
        {
            pm_onground     = FALSE;
            pm_groundnormal = trace_plane_normal;
        }
    }
}

// ============================================================================
//  20.  PM_CheckJump
// ============================================================================

void PM_CheckJump()
{
    float dp;
    float jump_down;

    jump_down = input_buttons & PM_BTN_JUMP;

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
    if (!jump_down)
    {
        self.pm_jump_held = FALSE;
        return;
    }

    // ladder jump: push away from wall + upward
    // GoldSrc: holding jump when you touch a ladder ejects you immediately —
    // the pm_jump_held guard is intentionally skipped here.
    if (pm_on_ladder)
    {
        // pm_ladder_normal may point toward OR away from the wall.
        // When no explicit movedir is set on the trigger, the normal is
        // derived from the player's view direction — which points INTO the
        // wall when the player is facing it (the common case).  Probe the
        // direction to find which side has open space.
        vector eject_dir;
        PM_Trace(pm_origin, pm_origin + pm_ladder_normal * 4);
        if (!trace_startsolid && trace_fraction == 1)
            eject_dir = pm_ladder_normal;   // open space ahead – kick this way
        else
            eject_dir = -pm_ladder_normal;  // wall ahead – reverse

        pm_velocity               = eject_dir * 270;
        pm_velocity_z             = 0;    // GoldSrc: purely horizontal, gravity takes over
        pm_onground               = FALSE;
        self.pm_jump_held         = TRUE;
        self.pm_ladder_detach_time = 0.1;
        pm_on_ladder              = FALSE;  // skip PM_LadderMove this step
        return;
    }

    // button is held from here onward

    // water-jump already in progress
    if (self.pm_waterjumptime)
    {
        if (!mv_autohop)
            self.pm_jump_held = TRUE;
        return;
    }

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
    {
        // GoldSrc-style jump gating: if jump is pressed in the air while
        // autohop is off, consume that press so it does not queue for landing.
        if (!mv_autohop)
            self.pm_jump_held = TRUE;
        return;
    }

    // pogo prevention: require button release between jumps unless autohop is on
    if (self.pm_jump_held && !mv_autohop)
        return;

    // ramp fix: if we have downward momentum along the ground normal, clip it
    dp = pm_velocity * pm_groundnormal;
    if (pm_velocity_z < 0 && dp < PM_MAX_JUMPFIX_DP)
        pm_velocity = PM_ClipVelocity(pm_velocity, pm_groundnormal, 1);

    // jump sound: step at full volume (water sound if feet are wet)
    if (pm_waterlevel >= 1)
        PM_EmitStepSound(strcat("sounds/player/waterstep", itos(floor(random() * 10) + 1), ".wav"), 1.0);
    else
        PM_EmitStepSound(strcat("sounds/player/step", itos(floor(random() * 4) + 1), ".wav"), 1.0);

    pm_onground       = FALSE;
    pm_velocity_z    += 270;
    self.spread_penalty = 4.0;   // jump spread penalty

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
//  23b. PM_NoclipMove  –  free fly through walls (noclip)
//
//  Identical structure to PM_SpectatorMove but uses pm_noclipspeed (default
//  3 × sv_maxspeed) so the player moves notably faster than spectators.
//  Origin is moved directly with no collision traces.
// ============================================================================

void PM_NoclipMove()
{
    vector wishvel, wishdir;
    float  wishspeed, maxspeed;

    maxspeed = cvar("pm_noclipspeed");
    if (maxspeed <= 0)
        maxspeed = mv_maxspeed * 3;

    // wish velocity from full 3-D view (forward + right + up)
    wishvel = pm_forward * input_movevalues_x
            + pm_right   * input_movevalues_y
            + v_up       * input_movevalues_z;

    wishspeed = vlen(wishvel);

    // Scale input to noclip speed — input_movevalues are clamped to
    // cl_forwardspeed (~400) by the engine, so we rescale them to fill
    // the full noclip range.
    if (wishspeed > 0)
    {
        wishdir = normalize(wishvel);
        pm_velocity = wishdir * maxspeed;
    }
    else
    {
        pm_velocity = '0 0 0';
    }

    // move directly — no collision
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

    mv_shiftspeed        = cvar("sv_shiftspeed");
    if (!mv_shiftspeed)       mv_shiftspeed        = 135;

    mv_walkspeed         = cvar("sv_walkspeed");
    if (!mv_walkspeed)        mv_walkspeed         = 135;

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

        if (!(trig.spawnflags & TELEPORT_KEEPVEL))
            pm_velocity = '0 0 0';

        self.pm_teleport_time = 0.2;

        // only one teleport per step
        return;
    }
};

// ============================================================================
//  27.  PM_CheckLadder + PM_LadderMove  –  GoldSrc-style ladder movement
// ============================================================================

float PM_PointHasLadderContents(vector pos)
{
    float cont;

    cont = pointcontents(pos);
    if (cont == CONTENT_LADDER || cont == SOLID_LADDER)
        return TRUE;

    return FALSE;
}

float PM_HullHasLadderContents(vector mins, vector maxs)
{
    vector probe_origin;

    tracebox(pm_origin, mins, maxs, pm_origin, MOVE_NOMONSTERS, self);
    if ((trace_endcontents & CONTENTBIT_FTELADDER)
        || (trace_endcontents & CONTENTBIT_Q2LADDER))
        return TRUE;

    probe_origin = pm_origin + (mins + maxs) * 0.5;
    return PM_PointHasLadderContents(probe_origin);
}

vector PM_DefaultLadderNormal()
{
    vector flat_fwd;

    flat_fwd   = pm_forward;
    flat_fwd_z = 0;

    if (vlen(flat_fwd) > 0)
        return normalize(flat_fwd);

    return '1 0 0';
}

float PM_LadderWallProbe(vector start, vector dir, float dist)
{
    if (dir == '0 0 0')
        return 2;

    tracebox(start, '0 0 0', '0 0 0', start + dir * dist, MOVE_NOMONSTERS, self);
    if (trace_startsolid || trace_allsolid)
        return 2;

    if (trace_fraction < 1 && trace_plane_normal != '0 0 0')
        return trace_fraction;

    return 2;
}

vector PM_FindLadderNormal(vector probe_origin, float probe_dist)
{
    vector flat_fwd;
    vector flat_right;
    vector best_normal;
    float best_fraction;
    float frac;

    flat_fwd = PM_DefaultLadderNormal();

    flat_right   = pm_right;
    flat_right_z = 0;
    if (vlen(flat_right) > 0)
        flat_right = normalize(flat_right);
    else
    {
        flat_right_x = -flat_fwd_y;
        flat_right_y = flat_fwd_x;
        flat_right_z = 0;
    }

    best_normal = '0 0 0';
    best_fraction = 2;

    frac = PM_LadderWallProbe(probe_origin, flat_fwd, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    frac = PM_LadderWallProbe(probe_origin, flat_fwd * -1, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    frac = PM_LadderWallProbe(probe_origin, flat_right, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    frac = PM_LadderWallProbe(probe_origin, flat_right * -1, probe_dist);
    if (frac < best_fraction)
    {
        best_fraction = frac;
        best_normal = trace_plane_normal;
    }

    if (best_normal != '0 0 0')
        return best_normal;

    return flat_fwd;
}

void() PM_CheckLadder =
{
    entity trig;
    vector player_mins, player_maxs;
    vector player_absmin, player_absmax;
    vector trig_absmin,   trig_absmax;
    vector probe_origin;
    float probe_dist;

    pm_on_ladder     = FALSE;
    pm_ladder_normal = '0 0 0';

    // recently jumped off — don't re-grab
    if (self.pm_ladder_detach_time > 0)
        return;

    player_mins = PM_CurrentMins();
    player_maxs = PM_CurrentMaxs();

    if (PM_HullHasLadderContents(player_mins, player_maxs))
    {
        probe_origin = pm_origin + (player_mins + player_maxs) * 0.5;
        probe_dist = max(max(fabs(player_mins_x), fabs(player_maxs_x)),
                         max(fabs(player_mins_y), fabs(player_maxs_y))) + 8;

        pm_on_ladder = TRUE;
        pm_ladder_normal = PM_FindLadderNormal(probe_origin, probe_dist);
        return;
    }

    player_absmin = pm_origin + player_mins;
    player_absmax = pm_origin + player_maxs;

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
            pm_ladder_normal = PM_DefaultLadderNormal();
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
//  28.  PM_StepSounds  –  GoldSrc-accurate footstep / ladder / water audio
//
//  Only SSQC emits sound() calls so there are no double-plays during CSQC
//  prediction replay.  The step timer (pm_step_time) is part of shared state
//  so both sides tick it identically for clean reconciliation.
// ============================================================================

// Set TRUE during CSQC prediction replay and the presentation preview so that
// step sounds fire only on the single live prediction pass per input frame.
#ifdef CSQC
float pm_suppress_sounds;
// cltime of the most recent localsound played by this client.
// Used by CSQC_Event_Sound to gate echo suppression on actual local playback.
float pm_last_local_step_time;
#endif

// Step sounds are server-side only: the SSQC sound() call is heard by all
// clients including the local player via the normal network sound path.
// CSQC prediction does NOT play a local duplicate — that caused double steps.
void(string snd, float vol) PM_EmitStepSound =
{
#ifdef SSQC
    sound(self, CHAN_BODY, snd, vol, ATTN_NORM);
#endif
};

// Called once per simulation step from PM_PlayerMoveStep.
// Advances pm_step_time and plays a sound when the interval expires.
void() PM_UpdateStepSound =
{
    float speed;
    float interval;
    float vol;
    string snd;

    // advance the countdown
    if (self.pm_step_time > 0)
    {
        self.pm_step_time -= pm_frametime;
        if (self.pm_step_time < 0)
            self.pm_step_time = 0;
        return;
    }

    // timer expired — decide whether to play a step
    // Ladder movement is primarily vertical, so measure full 3D speed there.
    // Ground/water movement is horizontal, so strip z for those checks.
    speed = vlen([pm_velocity_x, pm_velocity_y, 0]);

    if (pm_on_ladder && pm_waterlevel < 2)
    {
        // ladder — use total 3D speed so climbing up/down registers
        if (vlen(pm_velocity) < 50) return;
        interval = 0.35;
        vol      = 0.65;
        snd = strcat("sounds/player/ladder", itos(floor(random() * 4) + 1), ".wav");
    }
    else if (pm_waterlevel >= 1)
    {
        // water
        if (speed < 80) return;
        interval = 0.35;
        vol      = 0.50;
        snd = strcat("sounds/player/waterstep", itos(floor(random() * 10) + 1), ".wav");
    }
    else if (pm_onground)
    {
        // ground
        if (self.flags & FL_DUCKING)
        {
            if (speed < 50) return;
            interval = 0.60;
            vol      = 0.40;
        }
        else if (speed >= 220)
        {
            interval = 0.30;
            vol      = 1.00;
        }
        else
        {
            if (speed < 100) return;
            interval = 0.40;
            vol      = 0.50;
        }
        snd = strcat("sounds/player/step", itos(floor(random() * 4) + 1), ".wav");
    }
    else
    {
        return;  // airborne — no step
    }

    self.pm_step_time = interval;
    PM_EmitStepSound(snd, vol);
};

// ============================================================================
//  28.  PM_PlayerMoveStep  –  single fixed-size simulation slice
// ============================================================================

void PM_PlayerMoveStep()
{
    float  blocked;
    float  dp;
    float  was_onground;

    // --- load working state from entity ---
    pm_origin   = self.origin;
    pm_velocity = self.velocity;
    pm_onground = (self.flags & FL_ONGROUND) ? TRUE : FALSE;
    was_onground = pm_onground;

    pm_frametime = input_timelength;
    if (pm_frametime <= 0)
        return;

    // --- read cvars ---
    PM_ReadMovevars();

    // Shift/walk modifier (+button4): reduces mv_maxspeed to sv_shiftspeed.
    if ((input_buttons & PM_BTN_SPRINT) && !(self.flags & FL_DUCKING) && mv_shiftspeed > 0)
        mv_maxspeed = mv_shiftspeed;

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

    if (self.pm_movetype == PM_MOVETYPE_NOCLIP)
    {
        PM_NoclipMove();
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

    // Landing spread penalty: just transitioned from airborne to grounded
    if (pm_onground && !was_onground)
        self.spread_penalty = 4.0;

    // Decay spread penalty over time, quantized to 0.05 steps
    // so client and server converge to the same discrete values
    if (self.spread_penalty > 0)
    {
        self.spread_penalty -= pm_frametime * 2.0;
        if (self.spread_penalty > 0)
            self.spread_penalty = floor(self.spread_penalty * 20) / 20;
        else
            self.spread_penalty = 0;
    }

    // Decay fire spread penalty (sustained fire inaccuracy)
    if (self.fire_spread_penalty > 0)
    {
        self.fire_spread_penalty -= pm_frametime * FIRE_SPREAD_PENALTY_DECAY;
        if (self.fire_spread_penalty > 0)
            self.fire_spread_penalty = floor(self.fire_spread_penalty * 20) / 20;
        else
            self.fire_spread_penalty = 0;
    }

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

    // footstep / ladder / water step sounds
    PM_UpdateStepSound();

done:
    // --- write results back to entity ---
    setorigin(self, pm_origin);
    self.velocity = pm_velocity;
    PM_SyncHull();

    if (pm_onground)
        self.flags = self.flags | FL_ONGROUND;
    else
        self.flags = self.flags & ~FL_ONGROUND;

    self.waterlevel = pm_waterlevel;
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
