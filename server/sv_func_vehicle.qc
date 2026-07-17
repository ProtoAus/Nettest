//
// sv_func_vehicle.qc — GoldSrc/CS func_vehicle: a player-driven free-steer brush
//
// A func_vehicle is a free-steered cousin of func_tracktrain.  Instead of
// following a path_track chain it reads the driver's WASD and turns its own
// velocity + yaw.  The heavy lifting is REUSED:
//
//   - SV_InitReplicatedSolidBrush() (sv_brushsync.qc) replicates the brush;
//     we tag it BRUSH_TYPE_VEHICLE.  The brush ships origin/angles/velocity/
//     avelocity already, so live steering (avelocity_y) extrapolates on the
//     client via the brushsync avelocity path with no wire change.
//   - PM_CheckMovingPushers' TRAIN branch (sh_pmove.qc) — gated to also accept
//     BRUSH_TYPE_VEHICLE — carries the driver AND passengers (translation +
//     yaw + view-rotation + velocity-inherit + snap-jump reconcile), predicted
//     on both sides.  We add NO carry code.
//   - Crush is the engine .blocked callback (same as func_tracktrain): when the
//     MOVETYPE_PUSH brush can't push a player pinned against geometry, the
//     engine fires .blocked → we apply dmg.
//
// What's genuinely new here (the free-drive part trains never needed):
//   - A weighty drive model (ease-out accel, progressive brake, a self-centering
//     steering wheel, speed-tied turn rate).  Authored as a PURE step function
//     so Phase 2 can relocate it into shared pmove for client prediction.
//   - Explicit world collision (MOVETYPE_PUSH brushes pass through world, so a
//     free-roaming vehicle must sweep its own hull and clamp velocity).
//   - Optional ground-follow (Z + visual pitch from wheel-sample down-traces).
//   - ODE physics-prop shove on contact.
//   - func_vehiclecontrols: an invisible zone that follows+rotates with the
//     vehicle and gates where the driver must stand.  Server-only (prediction
//     needs only the .driving flag, replicated in Phase 2 via the proxy).
//
// PHASE 1 (this file): server-authoritative drive in a sv_func_tickrate think.
// Instant for a listen-server host; the driver's *velocity value* is
// server-latency-bound on a remote client (rides like a train corner).
// PHASE 2 (follow-up): replicate .driving + the steer/throttle accumulators via
// the prediction proxy and call Vehicle_DriveStep from shared pmove so a remote
// driver predicts with zero latency.  Nothing here is thrown away — only the
// drive-model CALL SITE and the input source change.
//
// Compile order (sv_progs.src): AFTER sv_func_tracktrain.qc (FuncTrain_* +
// SV_InitReplicatedSolidBrush + the carry list are defined earlier) and BEFORE
// sh_pmove.qc (so PM_* consts must be re-declared locally — same trick
// sv_platform_carry.qc:42-57 uses).
//

// ---------------------------------------------------------------------------
// Spawnflags (mirror the func_tracktrain / GoldSrc spec).
// ---------------------------------------------------------------------------
const float VEH_NO_PITCH       = 1;   // no terrain pitch/roll tilt (still yaws)
const float VEH_NO_USERCONTROL = 2;   // can't be mounted/driven
const float VEH_PASSABLE       = 8;   // non-solid (no collision / carry)

// Mapper keys not declared by earlier compile units.  (speed, dmg, volume,
// rendermode/renderamt/rendercolor, target, targetname, spawnflags come from
// the engine defs / sv_customdefs / sv_brushsync; wheels/height/startspeed/
// bank/sounds are declared in sv_func_tracktrain.qc which compiles first.)
.float length;   // wheelbase — longer = wider turn radius
.float width;    // track width — used for ground-follow roll sampling

// Runtime state (vehicle entity).
.entity vehicle_driver;        // current driver (world if none)
.entity veh_controls;          // our func_vehiclecontrols zone (world if none)
.entity veh_owner_vehicle;     // on the zone: back-link to its vehicle
.vector veh_ctrl_offset;       // on the zone: control-box CENTER in the vehicle's local frame (x=fwd, y=right, z=up-world)
.vector veh_ctrl_half;         // on the zone: control-box half-extents (rigidly rotated with the car for the OBB test)
.vector veh_spawn_origin;      // for round reset
.vector veh_spawn_angles;
.float  veh_link_tries;        // deferred controls-link retry counter
.float  veh_offdeck_since;     // time the driver first went off-deck/airborne (0 = on deck) — grace timer
.float  veh_airborne;          // 1 while the car is in the air (off a ramp/ledge) under gravity

// PM_TRIGGER_PROBE_DIM lives in sh_pmove.qc which compiles AFTER this file;
// re-declare the value locally (fteqcc shares the const slot — same as
// sv_platform_carry.qc:46).  Currently unused here but kept for parity if a
// future geometry probe is added.
const float VEH_TRIGGER_PROBE_DIM = 64;

// Forward decls.
void()  func_vehicle_use;
void()  func_vehicle_blocked;
void()  func_vehicle_spawn_settle;
void()  Vehicle_Think;
void(entity plyr) Vehicle_Dismount;
entity(entity plyr) Vehicle_FindMountable;
float(entity plyr, entity veh) Vehicle_TryMount;
float(entity plyr, entity veh) Vehicle_PlayerInControls;
float(entity plyr, entity veh) Vehicle_PlayerOnDeck;
void(entity veh, entity drv, float fwd, float side, float dt) Vehicle_DriveStep;
void(float dt) Vehicle_GroundFollow;
void(entity drv, float dt) Vehicle_CollideWorld;
void() Vehicle_ShoveProps;
void() Vehicle_UpdateControls;
void() Vehicle_RoundReset;
void(entity veh, entity attacker) Vehicle_ShotNudge;   // called from W_ApplyDamage (sv_weapons.qc)

// Reused from earlier compile units (defined before us — no extern needed,
// listed for readability): FuncTrain_TickInterval, FuncTrain_ApplyRenderMode,
// MovingBrush_AddToList/RemoveFromList, W_ApplyDamage.
float() FuncTrain_TickInterval;
void(float mode, float amt) FuncTrain_ApplyRenderMode;
void(entity c) MovingBrush_AddToList;
void(entity c) MovingBrush_RemoveFromList;
float(entity attacker, entity target, float damage) W_ApplyDamage;

// Cvar fetch with a fallback when unset/zero (the feel cvars register with
// sensible defaults so this is mostly belt-and-suspenders).
float(string nm, float dflt) Veh_Cvar =
{
    float v = cvar(nm);
    if (v == 0) return dflt;
    return v;
};

// ---------------------------------------------------------------------------
// Vehicle_DriveStep — the WEIGHTY drive model.  PURE: reads (driver input,
// driver's veh_steer/veh_throttle accumulators) and writes the driver's
// accumulators + the vehicle's velocity (planar) and avelocity_y (yaw rate).
// No collision / ground / Z here — those are applied by the think after.
//
// `fwd` / `side` are the raw WASD intent (engine input_movevalues_x/y),
// stashed by pmove.  We use them as signed intent.
// ---------------------------------------------------------------------------
void(entity veh, entity drv, float fwd, float side, float dt) Vehicle_DriveStep =
{
    float maxspeed  = veh.speed;
    if (maxspeed <= 0) maxspeed = 320;

    float accel     = Veh_Cvar("sv_vehicle_accel",        700);  // u/s^2 at standstill (ease-out)
    float brakerate = Veh_Cvar("sv_vehicle_brake",       1400);  // active brake decel
    float coastdec  = Veh_Cvar("sv_vehicle_decel",        220);  // engine-brake (no input) ~CS 200u/s/s
    float revfrac   = Veh_Cvar("sv_vehicle_reverse_frac", 0.35); // reverse cap fraction of max
    float steerrate = Veh_Cvar("sv_vehicle_steer_rate",   3.0);  // wheel turn-toward-target rate (per s)
    float steerret  = Veh_Cvar("sv_vehicle_steer_return", 4.0);  // wheel self-center rate (per s)
    float maxyaw    = Veh_Cvar("sv_vehicle_max_yaw",       180);  // deg/s at ideal speed

    // --- intent: sign of the WASD axis (full throttle when held) ---
    float in_fwd  = 0;
    if (fwd >  1) in_fwd =  1;
    if (fwd < -1) in_fwd = -1;
    float in_side = 0;
    if (side >  1) in_side =  1;
    if (side < -1) in_side = -1;

    // --- throttle: signed speed scalar (+forward, -reverse) ---
    float spd  = drv.veh_throttle;
    float room = 0;        // accel ease-out headroom (reused per branch)
    float k    = 0;        // steer lerp factor (reused per branch)
    if (in_fwd > 0)
    {
        // accelerate forward, ease-out toward maxspeed
        if (spd < 0)                      // was reversing → brake to 0 first
            spd = spd + brakerate * dt;
        else
        {
            room = 1 - (spd / maxspeed);
            if (room < 0) room = 0;
            spd = spd + accel * room * dt;
        }
        if (spd > maxspeed) spd = maxspeed;
    }
    else if (in_fwd < 0)
    {
        if (spd > 0)                      // moving forward, pressing back → brake
        {
            spd = spd - brakerate * dt;
            if (spd < 0) spd = 0;
        }
        else                              // reverse, ease-out toward -maxspeed*revfrac
        {
            float rmax = -maxspeed * revfrac;
            room = 1 - (spd / rmax);
            if (room < 0) room = 0;
            spd = spd - accel * room * dt;
            if (spd < rmax) spd = rmax;
        }
    }
    else
    {
        // no throttle: engine-brake toward 0
        if (spd > 0) { spd = spd - coastdec * dt; if (spd < 0) spd = 0; }
        else if (spd < 0) { spd = spd + coastdec * dt; if (spd > 0) spd = 0; }
    }
    drv.veh_throttle = spd;

    // --- steering wheel with weight: nudge toward target, self-center when released ---
    float st = drv.veh_steer;
    if (in_side != 0)
    {
        k = steerrate * dt; if (k > 1) k = 1;
        st = st + (in_side - st) * k;
    }
    else
    {
        k = steerret * dt; if (k > 1) k = 1;
        st = st - st * k;
    }
    if (st >  1) st =  1;
    if (st < -1) st = -1;
    drv.veh_steer = st;

    // --- yaw rate: tied to speed (no turn at standstill) and vehicle length ---
    float aspd  = spd; if (aspd < 0) aspd = -aspd;
    float ideal = maxspeed * 0.5; if (ideal < 1) ideal = 1;
    float sf    = aspd / ideal; if (sf > 1.1) sf = 1.1;        // speed factor
    float lenf  = 128 / bound(64, veh.length, 512);            // longer = slower turn
    float yawrate = -st * maxyaw * sf * lenf;                  // deg/s (sign: +side(right) turns right)
    // reverse: invert steering feel like backing up a real car
    if (spd < 0) yawrate = -yawrate;

    // --- outputs: planar velocity from heading, yaw via avelocity_y ---
    makevectors(veh.angles_y * '0 1 0');                       // yaw-only basis → planar v_forward (+X local)
    // GoldSrc brushes are built facing -X, so the visual FRONT is -v_forward.
    // Drive along the front so +throttle moves the way the car points.
    // Set ONLY the horizontal velocity — velocity_z is owned by Vehicle_GroundFollow
    // (ride / accumulating gravity).  Overwriting the whole vector here zeroed Z
    // every tick, which stopped gravity from accumulating ("not additive" float).
    vector hv = v_forward * (-spd);
    veh.velocity_x = hv_x;
    veh.velocity_y = hv_y;
    veh.avelocity_y = yawrate;                                 // engine integrates angles_y; client extrapolates via avelocity

    // --- bank roll: DISABLED for now ---
    // Rolling the brush tilts the COLLISION deck, but the platform-carry only
    // rotates riders about yaw (not roll), so a banked deck slid the driver off
    // and cost them control on turns.  Keep the deck level until bank can be a
    // visual-only effect on a separate non-solid render brush.
    veh.angles_z = 0;
};

// ---------------------------------------------------------------------------
// Vehicle_GroundFollow — terrain physics.  When there's ground close beneath the
// car it RIDES the surface (drives origin Z to the ground + pitches the deck to
// the slope); when the ground falls away (off a ramp/ledge) the car goes AIRBORNE
// and falls under gravity, keeping its horizontal momentum (air time).  The ride
// velocity at a ramp's lip becomes the launch velocity, so jumps come for free.
// ---------------------------------------------------------------------------
// Trace straight down to the ground under a world point, starting from above the
// car (so we never begin the trace inside the car or geometry).  Returns the
// ground Z, or a low sentinel when nothing is within reach (off-ledge detection).
float(vector pt) Veh_GroundUnder =
{
    vector top = pt; top_z = self.origin_z + self.maxs_z + 16;
    vector bot = pt; bot_z = top_z - 4096;
    traceline(top, bot, MOVE_NOMONSTERS, self);
    if (trace_fraction >= 1) return -99999;
    return trace_endpos_z;
};

void(float dt) Vehicle_GroundFollow =
{
    if (!cvar("sv_vehicle_ground_follow")) { self.veh_airborne = 0; return; }

    float grav = cvar("sv_gravity"); if (grav <= 0) grav = 800;

    float hl = self.length * 0.5; if (hl < 8) hl = 8;
    makevectors(self.angles_y * '0 1 0');
    vector c   = self.origin;
    vector fpt = c - v_forward * hl;     // FRONT wheel (-X-built brushes drive along -v_forward)
    vector bpt = c + v_forward * hl;     // BACK wheel

    // SPRING SUSPENSION.  Sample the ground under the front wheel, back wheel and
    // centre, and ride on the HIGHEST support so the chassis BRIDGES a peak (long
    // cars stop wedging) and never sinks in (low cars stop letting the rider clip).
    float front_g = Veh_GroundUnder(fpt);
    float back_g  = Veh_GroundUnder(bpt);
    float cen_g   = Veh_GroundUnder(c);

    float support_g = -99999;
    if (front_g > -50000 && back_g > -50000)
    {
        support_g = (front_g + back_g) * 0.5;          // line between the wheels
        if (cen_g > support_g) support_g = cen_g;      // but never let the belly bottom out on a peak
    }
    else if (cen_g > -50000)
        support_g = cen_g;

    float susp = cvar("sv_vehicle_suspension"); if (susp <= 0) susp = 28;
    float rest_bottom = support_g + self.height;       // where the bbox bottom should rest
    float bottom      = self.origin_z + self.mins_z;   // current bbox bottom
    float pen         = rest_bottom - bottom;          // >0 = below rest (push up); <0 = above rest (drop)

    if (support_g > -50000 && pen > -susp)
    {
        // Within the suspension range.
        if (pen > -2)
        {
            // at/below rest — ride the support (snap up onto a rising ramp; a tiny
            // controlled settle if just above).
            float up = pen / dt;
            if (up >  700) up =  700;
            if (up < -250) up = -250;
            self.velocity_z = up;
        }
        else
        {
            // within suspension but ABOVE rest (ground dropped under us) — let
            // GRAVITY pull it down fast instead of a slow capped float.
            self.velocity_z = self.velocity_z - grav * dt;
        }
        self.veh_airborne = (pen < -6);   // a clear gap counts as airborne (CollideWorld skip + airlock)

        // deck pitch from the wheel heights (sv_vehicle_pitch scales/signs it).
        float pscale = cvar("sv_vehicle_pitch");
        if (!(self.spawnflags & VEH_NO_PITCH) && pscale != 0
            && front_g > -50000 && back_g > -50000)
        {
            float pitch = ((front_g - back_g) / (hl * 2)) * 57.29578 * pscale;
            if (pitch >  35) pitch =  35;
            if (pitch < -35) pitch = -35;
            self.angles_x = self.angles_x + (pitch - self.angles_x) * bound(0, 6 * dt, 1);
        }
    }
    else
    {
        // Beyond the suspension (drove off an edge / launched off a ramp) —
        // FREE FALL under full gravity (the carry rides the driver through the arc).
        self.velocity_z   = self.velocity_z - grav * dt;
        self.veh_airborne = 1;
        if (!(self.spawnflags & VEH_NO_PITCH))
            self.angles_x = self.angles_x + (0 - self.angles_x) * bound(0, 2 * dt, 1);
    }
};

// ---------------------------------------------------------------------------
// Veh_RingPoint — world position of one of the car's 8 oriented collision
// samples (4 footprint corners + 4 edge midpoints), rotated by `yaw` about
// `org`.  Built from the car's REAL local-frame box (self.mins/maxs), inset 1u
// on X/Y so a wall the car rests against doesn't read as startsolid.  `localz`
// is an OFFSET from org (the ring height).  Same yaw-only projection used by
// the controls zone (Vehicle_UpdateControls): local X -> v_forward, Y -> v_right.
// ---------------------------------------------------------------------------
vector(vector org, float yaw, float localz, float idx) Veh_RingPoint =
{
    float minx = self.mins_x + 1; float maxx = self.maxs_x - 1;
    float miny = self.mins_y + 1; float maxy = self.maxs_y - 1;
    float midx = (minx + maxx) * 0.5;
    float midy = (miny + maxy) * 0.5;

    float lx; float ly;
    if      (idx == 0) { lx = maxx; ly = maxy; }   // corner
    else if (idx == 1) { lx = maxx; ly = miny; }   // corner
    else if (idx == 2) { lx = minx; ly = miny; }   // corner
    else if (idx == 3) { lx = minx; ly = maxy; }   // corner
    else if (idx == 4) { lx = maxx; ly = midy; }   // +X edge midpoint
    else if (idx == 5) { lx = minx; ly = midy; }   // -X edge midpoint
    else if (idx == 6) { lx = midx; ly = maxy; }   // +Y edge midpoint
    else               { lx = midx; ly = miny; }   // -Y edge midpoint

    makevectors(yaw * '0 1 0');
    return org + v_forward * lx + v_right * ly + '0 0 1' * localz;
};

// ---------------------------------------------------------------------------
// Veh_EmbedIsClimbable — a swept sample STARTED solid: is it embedded in
// climbable ground (a ramp/curb the suspension will lift the car onto — e.g.
// landing with the rear corners on a ramp, before pitch/ground-follow catches
// up) or a real wall?  Trace down from above the point: climbable ground
// presents a shallow surface here; a wall doesn't (it stays solid up high, or
// only the distant floor is shallow).  Climbable → ignore the startsolid so we
// don't stick the car; wall → block.  (self is SOLID_NOT during the sweep, so
// this never hits the car itself.)
// ---------------------------------------------------------------------------
float(vector p) Veh_EmbedIsClimbable =
{
    traceline(p + '0 0 72', p - '0 0 4', MOVE_NOMONSTERS, self);
    return (!trace_startsolid && trace_fraction < 1 && trace_plane_normal_z >= 0.6);
};

// ---------------------------------------------------------------------------
// Vehicle_CollideWorld — sweep the car along the planned move and clamp velocity
// on a hit (slide).  MOVETYPE_PUSH brushes pass through world, so the vehicle
// must do this itself.  ORIENTED: a box trace is hull-clamped to ~64 on
// GoldSrc/Quake BSP (ignoring the car's real shape AND its yaw), so instead we
// trace the car's true rotated corners + edge midpoints as exact POINT traces
// (hull 0 is never clamped).  Single origin authority stays the engine
// integrator: we only CLAMP velocity, never setorigin.
// ---------------------------------------------------------------------------
void(entity drv, float dt) Vehicle_CollideWorld =
{
    // Master toggle (sv_vehicle_wallcollide 0 = drive through walls).
    if (cvar("sv_vehicle_wallcollide") < 0.5) return;

    // No wall clamp while airborne — the flat collision box would false-block on
    // the far side of a ramp peak (the "stuck in the air" bug).  Gravity + the
    // ground-follow handle flight.
    if (self.veh_airborne) return;

    // No wall clamp while pitched on a slope.  This also covers the ramp->flat
    // DESCENT: when the front reaches the flat but the back is still on the ramp
    // the car is still pitched, so the centre-only slope test below would miss it
    // and the box's rear would clip the ramp behind → a sudden stop.
    if (self.angles_x > 6 || self.angles_x < -6) return;

    vector hvel = self.velocity; hvel_z = 0;     // wall collision is the horizontal sweep
    if (hvel == '0 0 0') return;
    vector hdir = normalize(hvel);

    // No wall clamp when a ramp RISES AHEAD — the flat box would false-block on it
    // ("stuck climbing").  Check the ground at the car's leading edge vs under it;
    // a long car's front reaches the ramp while its centre is still on the flat,
    // which is exactly when the old centre-only slope test missed it.
    float here_g  = Veh_GroundUnder(self.origin);
    vector ahead  = self.origin + hdir * (vlen(self.size) * 0.5 + 8);
    float ahead_g = Veh_GroundUnder(ahead);
    if (ahead_g > here_g + 6)
        return;                                  // climbable ramp ahead — ground-follow handles it

    // Also skip if we're already standing on a slope.
    traceline(self.origin + '0 0 8', self.origin - '0 0 128', MOVE_NOMONSTERS, self);
    if (trace_fraction < 1 && trace_plane_normal_z < 0.9)
        return;

    // Ring height: lift the sample ring off the resting floor by the STEP height
    // (sv_vehicle_step) so curbs/stairs up to that height pass UNDER the samples
    // and aren't walls — the suspension drives the car up them (same idea as a
    // player's step-up).  A point that STARTS solid against this ring is a real
    // wall taller than a step.  zlo is an OFFSET from the car origin.
    float step = cvar("sv_vehicle_step"); if (step < 4) step = 4;
    float zlo = self.mins_z + step + 2;
    if (zlo >= self.maxs_z) return;              // degenerate (very flat brush) — skip

    // === ORIENTED SWEEP ===
    // Trace the car's true rotated footprint corners + edge midpoints as exact
    // point traces.  START uses the current yaw/origin; END includes BOTH the
    // translation and this frame's yaw delta, so a fast-spinning car's corners
    // are swept through their arc (not merely slid).
    float yaw0  = self.angles_y;
    vector org0 = self.origin;
    float yaw1  = self.angles_y + self.avelocity_y * dt;
    float reach = vlen(hvel) * dt + 4;           // frame travel + 4u skin (tunnel guard)
    vector org1 = self.origin + hdir * reach;

    float any_start = FALSE;
    float found     = FALSE;
    float best_frac = 1;
    vector clip_n   = '0 0 0';                   // earliest wall normal (the slide plane)
    vector ref_n    = '0 0 0';                   // first wall normal seen (wedge reference)
    float wedge     = FALSE;

    float ss = self.solid;
    self.solid = SOLID_NOT;                      // don't self-block on the sweep

    float i = 0;
    while (i < 8)
    {
        vector sp = Veh_RingPoint(org0, yaw0, zlo, i);
        traceline(sp, Veh_RingPoint(org1, yaw1, zlo, i), MOVE_NOMONSTERS, self);

        if (trace_startsolid)
        {
            // Only a real wall sticks us; an embed in a ramp/curb (rear-on-ramp
            // landing) is climbed by the suspension — ignore it.
            if (!Veh_EmbedIsClimbable(sp))
                any_start = TRUE;
        }
        else if (trace_fraction < 1
              && trace_plane_normal_z < 0.7 && trace_plane_normal_z > -0.7)
        {
            // A real wall.  Floor/ramp normals are ignored PER-SAMPLE, so a
            // corner resting on a ramp can't veto a wall hit at another corner.
            if (!found) { ref_n = trace_plane_normal; found = TRUE; }
            if (trace_fraction < best_frac)
            {
                best_frac = trace_fraction;
                clip_n    = trace_plane_normal;
            }
            if ((trace_plane_normal * ref_n) < -0.1)
                wedge = TRUE;                    // a second wall faces the first → wedged
        }
        i = i + 1;
    }

    // Center backstop — only if nothing else hit: catches a wall thinner than the
    // perimeter sample spacing that slipped between the points.
    if (!found && !any_start)
    {
        vector c0 = self.origin + '0 0 1' * zlo;
        traceline(c0, c0 + hdir * (reach + vlen(self.size) * 0.5), MOVE_NOMONSTERS, self);
        if (trace_startsolid)
        {
            if (!Veh_EmbedIsClimbable(c0))
                any_start = TRUE;
        }
        else if (trace_fraction < 1
              && trace_plane_normal_z < 0.7 && trace_plane_normal_z > -0.7)
        {
            clip_n = trace_plane_normal;
            found  = TRUE;
        }
    }

    self.solid = ss;

    // --- resolve ---
    if (any_start)
    {
        // Embedded in a wall — kill horizontal motion + bleed the throttle.
        self.velocity_x = 0;
        self.velocity_y = 0;
        if (drv != world) drv.veh_throttle = drv.veh_throttle * 0.2;
        return;
    }
    if (!found) return;

    if (wedge)
    {
        // Two facing walls (concave corner / dead-end) — no slide direction.
        self.velocity_x = 0;
        self.velocity_y = 0;
        if (drv != world) drv.veh_throttle = drv.veh_throttle * 0.2;
        return;
    }

    // Single wall: slide along it (clip the horizontal velocity onto the plane,
    // keep the vertical for gravity/ramp ride).
    float backoff = self.velocity * clip_n;
    self.velocity = self.velocity - clip_n * backoff;

    // head-on crunch: bleed the speed when the wall opposes the car's heading
    // (the front is -v_forward for these -X-built brushes).
    if (drv != world)
    {
        makevectors(self.angles_y * '0 1 0');
        if ((clip_n * v_forward) > 0.4)
            drv.veh_throttle = drv.veh_throttle * 0.4;
    }
};

// ---------------------------------------------------------------------------
// Vehicle_ShoveProps — wake + nudge ODE physics props the vehicle runs into.
// Server-only (ODE isn't predicted).  A sleeping body ignores a velocity write,
// so physics_enable(prop, TRUE) first (sv_physprop.qc:870-876).
// ---------------------------------------------------------------------------
void() Vehicle_ShoveProps =
{
    float spd = vlen(self.velocity);
    if (spd < 50) return;

    vector fdir = self.velocity; fdir_z = 0;
    if (fdir == '0 0 0') return;
    fdir = normalize(fdir);

    float reach = vlen(self.size) * 0.5 + 48;
    entity p = findradius(self.origin, reach);
    while (p)
    {
        if (p != self
            && (p.solid == SOLID_PHYSICS_BOX || p.solid == SOLID_PHYSICS_TRIMESH))
        {
            // only props roughly ahead of us
            vector to_p = p.origin - self.origin; to_p_z = 0;
            if (to_p != '0 0 0' && normalize(to_p) * fdir > 0.2)
            {
                physics_enable(p, TRUE);
                p.velocity = p.velocity + fdir * (spd * 0.8) + '0 0 40';
                // Resume the prop's full-rate think + snap its mirror out: a settled prop is on
                // the slow sleep tick, and this shove is invisible to it until that tick fires.
                PhysProp_KickStream(p);
            }
        }
        p = p.chain;
    }
};

// ---------------------------------------------------------------------------
// Vehicle_ShotNudge — a bullet doesn't damage a func_vehicle; it gives it a
// small shove ALONG THE SHOT (away from the shooter), but only as far as the
// path is clear.  So a player can shoot a stuck car free by standing on the side
// opposite the way they want it to go.  Called from W_ApplyDamage.
// ---------------------------------------------------------------------------
void(entity veh, entity attacker) Vehicle_ShotNudge =
{
    if (veh == world || attacker == world) return;

    // Don't shove a car that's being DRIVEN: the driver is bolted inside its
    // hull, so a setorigin nudge would jam the car into their own bbox ("stuck
    // inside you").  The nudge is only for freeing PARKED/stuck cars — while
    // driving you reposition with WASD, so own-shots (and others') no-op here.
    if (veh.vehicle_driver != world) return;

    // Push the car along the SHOOTER'S AIM (where they're facing), not the
    // centre-to-centre line — so you shove the car wherever you point the gun.
    makevectors(attacker.v_angle);
    vector dir = v_forward;
    dir_z = 0;
    if (dir == '0 0 0') return;
    dir = normalize(dir);

    float dist = cvar("sv_vehicle_shotnudge"); if (dist <= 0) dist = 12;
    vector dest = veh.origin + dir * dist;

    float ss = veh.solid;
    veh.solid = SOLID_NOT;                          // don't self-block on the probe
    tracebox(veh.origin, veh.mins, veh.maxs, dest, MOVE_NOMONSTERS, veh);
    veh.solid = ss;

    if (trace_fraction > 0.05)                      // only move into clear space
    {
        setorigin(veh, trace_endpos);
        veh.velocity_z = 0;                         // don't fight gravity with the nudge
        veh.SendFlags = 1;
    }
};

// ---------------------------------------------------------------------------
// Vehicle_UpdateControls — keep the controls zone glued to (and rotated with)
// the vehicle.  The zone bbox stays axis-aligned; only its center translates by
// the spawn-time local offset rotated into the current heading.
// ---------------------------------------------------------------------------
void() Vehicle_UpdateControls =
{
    entity z = self.veh_controls;
    if (z == world) return;
    makevectors(self.angles_y * '0 1 0');
    vector off = z.veh_ctrl_offset;
    vector wpos = self.origin + v_forward * off_x + v_right * off_y + '0 0 1' * off_z;
    setorigin(z, wpos);
};

// ---------------------------------------------------------------------------
// Stand-on-deck probe (mount gate + parity with the carry's detection).
// ---------------------------------------------------------------------------
float(entity plyr, entity veh) Vehicle_PlayerOnDeck =
{
    tracebox(plyr.origin, plyr.mins, plyr.maxs,
             plyr.origin - '0 0 6', MOVE_NORMAL, plyr);
    return (trace_fraction < 1 && trace_ent == veh && !trace_startsolid);
};

// In-controls test — ROTATION-AWARE (oriented box, no engine OBB needed).
//
// An axis-aligned trigger can't follow a rotating brush, so instead of moving a
// world-AABB zone we transform the PLAYER into the car's LOCAL (un-rotated) frame
// and AABB-compare against the control box stored in that frame.  Rotating the
// player back by the car's yaw is equivalent to testing an oriented box that
// rotates rigidly with the car — exactly what the func_vehiclecontrols needs.
float(entity plyr, entity veh) Vehicle_PlayerInControls =
{
    vector lc, half;
    entity z = veh.veh_controls;
    if (z != world)
    {
        lc   = z.veh_ctrl_offset;     // box center in the car's local frame
        half = z.veh_ctrl_half;       // box half-extents (rigidly rotated with the car)
    }
    else
    {
        // No func_vehiclecontrols: default region is the car's own footprint
        // (length x width) a little above the deck.
        float lh = veh.length * 0.5; if (lh < 16) lh = 16;
        float wh = veh.width  * 0.5; if (wh < 16) wh = 16;
        lc   = '0 0 0';  lc_z = 24;
        half_x = lh + 8; half_y = wh + 8; half_z = 40;
    }

    // World -> car-local: project the player's offset onto the car's axes
    // (this is the inverse yaw rotation).
    vector rel = plyr.origin - veh.origin;
    makevectors(veh.angles_y * '0 1 0');
    vector lp;
    lp_x = rel * v_forward;
    lp_y = rel * v_right;
    lp_z = rel_z;

    return (lp_x >= lc_x - half_x      && lp_x <= lc_x + half_x
         && lp_y >= lc_y - half_y      && lp_y <= lc_y + half_y
         && lp_z >= lc_z - half_z - 8  && lp_z <= lc_z + half_z + 72);
};

// ---------------------------------------------------------------------------
// Mount / dismount.  Mount is called from the +use gate in sv_use.qc; dismount
// from there, from the continuous control check, or on round reset.
// ---------------------------------------------------------------------------
// Find a func_vehicle the player is standing on (for the +use mount gate).
entity(entity plyr) Vehicle_FindMountable =
{
    tracebox(plyr.origin, plyr.mins, plyr.maxs,
             plyr.origin - '0 0 6', MOVE_NORMAL, plyr);
    if (trace_fraction < 1 && trace_ent != world && !trace_startsolid
        && trace_ent.classname == "func_vehicle")
        return trace_ent;
    return world;
};

float(entity plyr, entity veh) Vehicle_TryMount =
{
    if (veh == world) return FALSE;     // guard: never write world's fields (entity 0 is read-only)
    if (veh.spawnflags & VEH_NO_USERCONTROL) return FALSE;
    if (veh.vehicle_driver != world && veh.vehicle_driver != plyr) return FALSE;
    if (!Vehicle_PlayerOnDeck(plyr, veh)) return FALSE;
    if (!Vehicle_PlayerInControls(plyr, veh)) return FALSE;

    // Set the VEHICLE side first, then the player-lock fields LAST, so a
    // failure mid-mount can never leave the player with pm_driving stuck on
    // (which would freeze their input via the pmove driver-lock).
    veh.vehicle_driver  = plyr;
    MovingBrush_AddToList(veh);     // join the moving-brush list so the carry runs
    veh.think     = Vehicle_Think;
    veh.nextthink = veh.ltime + FuncTrain_TickInterval();

    plyr.driving        = veh;
    plyr.veh_steer      = 0;
    plyr.veh_throttle   = 0;
    plyr.pm_driving     = TRUE;     // replicated to the owner via the prediction proxy → drives the pmove lock + fire-block (set LAST)

    if (cvar("sv_debug_func_vehicle"))
        dprint(sprintf("[vehicle %s] mounted by %s\n", veh.targetname, plyr.netname));
    return TRUE;
};

void(entity plyr) Vehicle_Dismount =
{
    entity veh = plyr.driving;
    if (veh == world) return;

    plyr.driving      = world;
    plyr.pm_driving   = FALSE;
    plyr.veh_steer    = 0;
    plyr.veh_throttle = 0;
    if (veh.vehicle_driver == plyr) veh.vehicle_driver = world;

    // leave the vehicle's velocity to coast down in Vehicle_Think (engine-brake);
    // it removes itself from the moving list once fully stopped.
    if (cvar("sv_debug_func_vehicle"))
        dprint(sprintf("[vehicle %s] dismounted by %s\n", veh.targetname, plyr.netname));
};

// ---------------------------------------------------------------------------
// Per-tick drive loop (sv_func_tickrate).  Server-authoritative in Phase 1.
// ---------------------------------------------------------------------------
void() Vehicle_Think =
{
    float dt = FuncTrain_TickInterval();
    entity drv = self.vehicle_driver;

    // Continuous control: keep driving while alive and inside the ROTATION-AWARE
    // control region (Vehicle_PlayerInControls transforms the player into the
    // car's local frame, so the region tracks the car's yaw).  We do NOT require
    // FL_ONGROUND — the driver is bolted to the car by the carry even while the
    // car is airborne (off a ramp), so you keep control through jumps.  A brief
    // excursion gets a grace window before control is dropped.
    if (drv != world)
    {
        if (drv.driving != self || drv.health <= 0)
        {
            // hard loss — dead / desync: drop immediately
            Vehicle_Dismount(drv);
            drv = world;
        }
        else if (!Vehicle_PlayerInControls(drv, self))
        {
            // soft loss — off the deck / airborne: dismount only if it persists
            if (self.veh_offdeck_since == 0)
                self.veh_offdeck_since = time;
            if (time - self.veh_offdeck_since > 0.5)
            {
                Vehicle_Dismount(drv);
                drv = world;
            }
        }
        else
        {
            self.veh_offdeck_since = 0;   // back on the deck — reset the grace timer
        }
    }

    if (drv != world)
    {
        Vehicle_DriveStep(self, drv, drv.veh_in_fwd, drv.veh_in_side, dt);
    }
    else
    {
        // no driver → coast to a stop (engine brake), straighten out
        float cur = vlen(self.velocity);
        if (cur > 1)
        {
            float dec = Veh_Cvar("sv_vehicle_decel", 220);
            float nv = cur - dec * dt; if (nv < 0) nv = 0;
            self.velocity = self.velocity * (nv / cur);
        }
        else
            self.velocity = '0 0 0';
        self.avelocity_y = 0;
    }

    if (cvar("sv_debug_func_vehicle"))
    {
        float dbg_hasdrv = 0; if (drv != world) dbg_hasdrv = 1;
        float dbg_og = 0; if (drv.flags & FL_ONGROUND) dbg_og = 1;
        dprint(sprintf("[veh tick] hasdrv=%g fwd=%g side=%g spd=%g vel=%v onground=%g\n",
                       dbg_hasdrv, drv.veh_in_fwd, drv.veh_in_side,
                       drv.veh_throttle, self.velocity, dbg_og));
    }

    Vehicle_GroundFollow(dt);
    Vehicle_CollideWorld(drv, dt);

    self.mover_planned_velocity = self.velocity;   // crush look-ahead / carry use this

    if (drv != world)
        Vehicle_ShoveProps();

    // (No per-tick zone move needed — Vehicle_PlayerInControls tests the control
    //  box directly in the car's local frame, so it tracks rotation for free.)

    self.SendFlags = 1;     // re-dirty so CSQC sees the new velocity/angles every tick

    if (drv == world && self.velocity == '0 0 0' && self.avelocity_y == 0)
    {
        // fully idle and nobody driving → stop ticking, leave the moving list
        self.mover_planned_velocity = '0 0 0';
        MovingBrush_RemoveFromList(self);
        self.nextthink = 0;
        return;
    }

    self.nextthink = self.ltime + dt;
    self.think     = Vehicle_Think;
};

// ---------------------------------------------------------------------------
// Engine .blocked — crush (same path as func_tracktrain): the MOVETYPE_PUSH
// brush couldn't push `other` out of its way (pinned vs geometry) → damage.
// ---------------------------------------------------------------------------
void() func_vehicle_blocked =
{
    if (cvar("sv_debug_func_vehicle"))
        dprint(sprintf("[veh BLOCKED] by classname=\"%s\" (engine reversed the push)\n",
                       other.classname));
    if (self.dmg <= 0 || !other) return;
    if (other.takedamage == DAMAGE_NO) return;
    W_ApplyDamage(self, other, self.dmg);
};

// ---------------------------------------------------------------------------
// .use — CS "triggering a func_vehicle gives a jolt".  Optional; mounting is
// handled by the dedicated +use gate in sv_use.qc, not here.
// ---------------------------------------------------------------------------
void() func_vehicle_use =
{
    // A DIRECT player +use must never jolt the car — it should only ever mount
    // (handled in sv_use.qc before the forward trace).  Only an indirect trigger
    // relay (game logic) may give the CS-style forward jolt.
    if (sv_use_is_player_direct) return;

    // Trigger relay jolt: nudge forward proportional to speed if nobody's driving.
    if (self.vehicle_driver != world) return;
    makevectors(self.angles_y * '0 1 0');
    self.velocity = v_forward * (self.speed * 0.5);
    self.mover_planned_velocity = self.velocity;
    MovingBrush_AddToList(self);
    self.think     = Vehicle_Think;
    self.nextthink = self.ltime + FuncTrain_TickInterval();
    self.SendFlags = 1;
};

// ---------------------------------------------------------------------------
// Round reset — no train/tracktrain reset exists, so vehicles need their own.
// Called from RoundRestart (sv_main.qc).
// ---------------------------------------------------------------------------
void() Vehicle_RoundReset =
{
    entity e = find(world, classname, "func_vehicle");
    while (e)
    {
        if (e.vehicle_driver != world)
            Vehicle_Dismount(e.vehicle_driver);

        e.velocity              = '0 0 0';
        e.avelocity             = '0 0 0';
        e.mover_planned_velocity = '0 0 0';
        setorigin(e, e.veh_spawn_origin);
        e.angles = e.veh_spawn_angles;
        MovingBrush_RemoveFromList(e);
        e.nextthink = 0;
        e.SendFlags = 1;

        e = find(e, classname, "func_vehicle");
    }
};

// ---------------------------------------------------------------------------
// Deferred spawn: optional snap to a first path_track, ground-settle, resolve
// the controls zone.  Runs once 0.1 s after spawn (lets path_tracks/zones load).
// ---------------------------------------------------------------------------
void() func_vehicle_spawn_settle =
{
    // optional: align to the first path_track named by 'target' (CS "First Stop Target")
    if (self.target != "")
    {
        entity pt = find(world, targetname, self.target);
        if (pt != world)
        {
            setorigin(self, pt.origin);
            // face the second track if present (HL spec)
            entity second = (pt.target != "") ? find(world, targetname, pt.target) : world;
            if (second != world)
            {
                vector d = second.origin - pt.origin;
                // CONFIRMED: these GoldSrc brushes are built facing -X (the model's
                // visual front is its -X side).  Add 180 so the FRONT points toward
                // the next track.  (This now renders correctly because the angle is
                // networked via the SendFlags below — the earlier attempt only
                // looked wrong because that send was missing.)
                self.angles_y = vectoyaw(d) + 180;
            }
        }
    }

    self.veh_spawn_origin = self.origin;
    self.veh_spawn_angles = self.angles;

    if (cvar("sv_debug_func_vehicle"))
        dprint(sprintf("[veh spawn] %s target=\"%s\" angles=%v origin=%v\n",
                       self.targetname, self.target, self.angles, self.origin));

    // Publish the settled origin/angles to CSQC NOW.  Without this the client
    // keeps rendering (and colliding against) the pre-align orientation until
    // something else dirties the wire — so the car looked backwards and then
    // snapped 180° the instant you mounted, flinging you off the deck.
    self.SendFlags = 1;

    // idle until mounted
    self.nextthink = 0;
};

/*QUAKED func_vehicle (0 .5 .8) ? VEH_NO_PITCH VEH_NO_USERCONTROL x VEH_PASSABLE
GoldSrc/CS driveable brush.  Mount with +use while standing on the deck inside a
func_vehiclecontrols zone (or, with no zone, anywhere on the deck); WASD drives.

"speed"       Max forward speed (default 320).
"length"      Wheelbase — longer turns wider (default 128).
"width"       Track width — ground-follow roll sampling (default 64).
"height"      Ride height above ground when sv_vehicle_ground_follow is on.
"dmg"         Crush damage when it pins a player vs geometry (default 50).
"bank"        Visual lean-into-turns degrees (default 8).
"sounds"      Engine sound enum (reserved).
"volume"      Engine sound volume.
"rendermode"/"renderamt"/"rendercolor"  GoldSrc render keys.
"target"      Optional first-stop path_track to align to at spawn.

VEH_NO_PITCH       No terrain pitch/roll tilt (still yaws + banks).
VEH_NO_USERCONTROL Can't be driven.
VEH_PASSABLE       Non-solid.
*/
void() func_vehicle =
{
    if (self.speed  == 0) self.speed  = 320;
    if (self.length == 0) self.length = 128;
    if (self.width  == 0) self.width  = 64;
    if (self.dmg    == 0) self.dmg    = 50;
    if (self.bank   == 0) self.bank   = 8;
    if (self.volume == 0) self.volume = 0.8;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_VEHICLE;
    if (self.spawnflags & VEH_PASSABLE)
        self.solid = SOLID_NOT;

    if (self.rendermode > 0)
        FuncTrain_ApplyRenderMode(self.rendermode, self.renderamt);

    self.use     = func_vehicle_use;
    self.blocked = func_vehicle_blocked;
    self.vehicle_driver = world;

    // Shootable, but a hit NUDGES rather than damages (W_ApplyDamage special-cases
    // func_vehicle).  Big health so nothing ever "kills" it.
    self.takedamage = DAMAGE_YES;
    self.health     = 1000000;

    self.think     = func_vehicle_spawn_settle;
    self.nextthink = time + 0.1;
};

// ---------------------------------------------------------------------------
// func_vehiclecontrols — invisible zone that follows the vehicle and gates
// where the driver must stand.  Server-only.
// ---------------------------------------------------------------------------
void() func_vehiclecontrols_link =
{
    entity veh = (self.target != "") ? find(world, targetname, self.target) : world;
    if (veh == world || veh.classname != "func_vehicle")
    {
        // vehicle not spawned yet (or bad target) — retry a few times
        self.veh_link_tries = self.veh_link_tries + 1;
        if (self.veh_link_tries < 40)
        {
            self.nextthink = time + 0.1;
            self.think     = func_vehiclecontrols_link;
        }
        return;
    }

    veh.veh_controls       = self;
    self.veh_owner_vehicle = veh;

    // Store the control box in the car's LOCAL frame (center + half-extents) so
    // Vehicle_PlayerInControls can test it as an oriented box that rotates
    // rigidly with the car.  The zone entity itself never has to move.
    makevectors(veh.angles_y * '0 1 0');
    vector zcenter = self.origin + (self.mins + self.maxs) * 0.5;
    vector d = zcenter - veh.origin;
    self.veh_ctrl_offset_x = d * v_forward;
    self.veh_ctrl_offset_y = d * v_right;
    self.veh_ctrl_offset_z = d_z;
    self.veh_ctrl_half     = (self.maxs - self.mins) * 0.5;
};

/*QUAKED func_vehiclecontrols (0 .3 .8) ?
Invisible zone (cuboid) that moves with its target func_vehicle and defines
where a player must stand to drive it.
"target"  targetname of the func_vehicle to control.
*/
void() func_vehiclecontrols =
{
    if (!self.model)
    {
        remove(self);
        return;
    }

    setmodel(self, self.model);
    vector zmin = self.mins;
    vector zmax = self.maxs;
    self.model      = "";            // invisible — keep the bbox, drop the render model
    self.modelindex = 0;
    self.solid      = SOLID_NOT;
    self.movetype   = MOVETYPE_NONE;
    setsize(self, zmin, zmax);

    self.veh_link_tries = 0;
    self.think     = func_vehiclecontrols_link;
    self.nextthink = time + 0.2;     // after func_vehicle spawns
};
