//
//  sv_pendulum.qc  –  func_pendulum  (oscillating brush, SHM motion)
//
//  Simple-harmonic-motion pendulum that matches GoldSrc's CPendulum:
//  velocity is zero at the swing extremes, peaks at the midpoint, and
//  the pose obeys angle(t) = center + sign * amp * cos(omega * t)
//  where omega = 2 * speed / |distance| (per the HL acceleration
//  formula m_accel = speed² / (2 * |distance|)).
//
//  Per-tick think runs at 64 Hz, writes self.angles directly and
//  sets self.avelocity to the instantaneous derivative — so client
//  CSQC predraw can extrapolate one server tick forward smoothly,
//  while server-side angles always match the SHM equation exactly.
//
//  Axis selection MATCHES HL's CBaseToggle::AxisDir bit-to-movedir
//  mapping (NOT the more intuitive "rotate around world X" reading
//  that the FGD label suggests).  This matters because GoldSrc maps
//  ship with spawnflag bits chosen for HL's behaviour:
//    bit 64  ("X axis" in FGD) → movedir (0,0,1) → ROLL  on angles_z
//    bit 128 ("Y axis" in FGD) → movedir (1,0,0) → PITCH on angles_x
//    no flag                   → movedir (0,1,0) → YAW   on angles_y
//
//  Spawnflags (HL bit layout):
//    1   Start On
//    8   Passable      – non-solid
//    16  Auto-Return   – on .use, snap to center and halt
//    64  X axis        – swing on roll (advances angles_z)
//    128 Y axis        – swing on pitch (advances angles_x)
//

void() SV_InitReplicatedSolidBrush;                                   // sv_brushsync.qc
float(entity attacker, entity target, float damage) W_ApplyDamage;    // sv_weapons.qc
float() Brush_RotateCarry;                                            // sv_doors_rotating.qc

const float SF_PEND_START_ON   = 1;
const float SF_PEND_PASSABLE   = 8;
const float SF_PEND_AUTORETURN = 16;
const float SF_PEND_X_AXIS     = 64;
const float SF_PEND_Y_AXIS     = 128;

const float PEND_PI = 3.14159265358979;

// Per-pendulum state.
.vector pend_axis_vec;       // unit Euler-delta direction (sign of distance baked in)
.vector pend_center;         // midpoint of swing arc
.float  pend_amp;            // current amplitude (degrees, decays with damp)
.float  pend_amp_initial;    // mapper-set magnitude, used for re-triggers
.float  pend_omega;          // angular frequency (rad/sec), constant
.float  pend_t0;             // ltime at start of current half-period
.float  pend_phase_sign;     // +1 / -1, alternates each half-period
.float  pend_active;

.float dmg;                  // already declared in sv_doors.qc
.float damp;                 // mapper key: damping rate (0..1000)

void() pendulum_think;

// Snap pendulum to the center pose and halt.
void() pendulum_halt =
{
    self.pend_active = 0;
    self.angles      = self.pend_center;
    self.avelocity   = '0 0 0';
    self.think       = __NULL__;
    self.nextthink   = 0;
    self.SendFlags   = 1;
};

// Begin a swing — caller has already populated self.pend_t0 etc.
void() pendulum_start_swing =
{
    if (self.pend_active) return;
    self.pend_active     = 1;
    self.pend_amp        = self.pend_amp_initial;
    self.pend_t0         = self.ltime;
    self.pend_phase_sign = -1;     // start at -axis*amp from center = mapper's spawn pose
    self.think           = pendulum_think;
    // Engine think scheduler treats nextthink == 0 (or anything <= the
    // think state's "already-fired" cutoff) as inactive — we need a
    // strictly positive future tick.
    self.nextthink       = self.ltime + 0.01;
};

void() pendulum_think =
{
    if (!self.pend_active) return;

    float half_period = PEND_PI / self.pend_omega;
    float t = self.ltime - self.pend_t0;

    // Cross half-period boundaries: snap to extreme, apply damping,
    // flip phase sign, restart timer.  while-loop covers the rare
    // case where the think missed multiple boundaries due to a
    // hitch.
    while (t >= half_period)
    {
        self.pend_t0          = self.pend_t0 + half_period;
        t                     = t - half_period;
        self.pend_phase_sign  = -self.pend_phase_sign;

        if (self.damp > 0)
        {
            float decay = self.damp / 1000;
            if (decay > 1) decay = 1;
            self.pend_amp = self.pend_amp * (1 - decay);
            if (self.pend_amp < 0.5)
            {
                pendulum_halt();
                return;
            }
        }
    }

    // Position + velocity at time t into the current half-period.
    //   pos(t) = center + sign * amp * cos(omega * t) * axis
    //   vel(t) = -sign * amp * omega * sin(omega * t) * axis
    float c = cos(self.pend_omega * t);
    float s = sin(self.pend_omega * t);
    float pos_off = self.pend_phase_sign * self.pend_amp * c;
    float vel_off = -self.pend_phase_sign * self.pend_amp * self.pend_omega * s;

    self.angles    = self.pend_center + self.pend_axis_vec * pos_off;
    self.avelocity = self.pend_axis_vec * vel_off;
    self.SendFlags = 1;

    // Carry-or-reverse: if a player overlaps the swept arc and can't
    // be pushed out of the way, reverse the phase like .blocked would.
    // Brush_RotateCarry needs rotdoor_axis_index (which avelocity
    // component is non-zero) and pos1 (closed-pose angles for the
    // local-frame bbox check — pendulum has no "closed" so use the
    // current pose).
    self.pos1 = self.angles;
    if (self.pend_axis_vec_x != 0)      self.rotdoor_axis_index = 0;
    else if (self.pend_axis_vec_z != 0) self.rotdoor_axis_index = 2;
    else                                 self.rotdoor_axis_index = 1;
    if (Brush_RotateCarry())
    {
        // Reverse phase so the next swing goes back through center
        // instead of plowing forward into the blocker.
        self.pend_phase_sign = -self.pend_phase_sign;
        self.pend_t0         = self.ltime;
        if (self.dmg > 0)
        {
            // Damage the blocker — same as pendulum_blocked.
            entity p = find(world, classname, "player");
            while (p)
            {
                // No takedamage test: players are permanently DAMAGE_NO in
                // this mod and W_CanDamageTarget accepts them regardless, so the
                // gate only ever excluded the one thing a pendulum should hit.
                if (!p.is_dead)
                {
                    vector pmin = p.origin + p.mins;
                    vector pmax = p.origin + p.maxs;
                    vector dmin = self.absmin;
                    vector dmax = self.absmax;
                    if (pmin_x <= dmax_x && pmax_x >= dmin_x
                     && pmin_y <= dmax_y && pmax_y >= dmin_y
                     && pmin_z <= dmax_z && pmax_z >= dmin_z)
                        W_ApplyDamage(self, p, self.dmg);
                }
                p = find(p, classname, "player");
            }
        }
    }

    // Tick at sv_func_tickrate so the pendulum's tick cadence matches
    // every other func mover (doors, rotating, conveyors).  Default 64
    // Hz gives the CSQC predraw a fresh snapshot every ~16 ms so the
    // per-tick linearization (avelocity * elapsed) tracks the SHM curve
    // tightly; admins can dial it down for smoother high-rate clients
    // or up for cheaper sims.
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = 64;
    if (hz > 200)  hz = 200;
    self.nextthink = self.ltime + 1.0 / hz;
};

void() pendulum_use =
{
    if (self.spawnflags & SF_PEND_AUTORETURN)
    {
        pendulum_halt();
        return;
    }
    if (self.pend_active)
        pendulum_halt();
    else
        pendulum_start_swing();
};

void() pendulum_blocked =
{
    // W_ApplyDamage owns the "can this be hurt" decision (W_CanDamageTarget);
    // pre-filtering on takedamage here only ever excluded players.
    if (self.dmg > 0 && other != world)
        W_ApplyDamage(self, other, self.dmg);
    // Reverse: flip phase_sign and restart timer at "extreme".
    // Effectively: bounce off whatever blocked us.
    self.pend_phase_sign = -self.pend_phase_sign;
    self.pend_t0         = self.ltime;
};

/*QUAKED func_pendulum (0 .5 .8) ? START_ON x x PASSABLE AUTORETURN x x X_AXIS Y_AXIS
A brush that swings sinusoidally around an ORIGIN-textured pivot.

"speed"     peak swing rate at midpoint (deg/sec, default 100)
"distance"  total swing arc (degrees, negative reverses initial direction; default 90)
"damp"      decay rate 0..1000 (0 = perpetual; 1000 = single swing)
"dmg"       damage on block

START_ON (1):     begin swinging at map load.
PASSABLE (8):     non-solid.
AUTO_RETURN (16): trigger snaps to center and halts instead of toggling.
X_AXIS (64):      swing on ROLL (advances angles_z) — matches HL bit-64 semantics.
Y_AXIS (128):     swing on PITCH (advances angles_x) — matches HL bit-128 semantics.
                   (neither = yaw / advances angles_y, the default — same as
                    func_rotating's default in this mod)
*/
void() func_pendulum =
{
    if (!self.speed)    self.speed    = 100;
    if (!self.distance) self.distance = 90;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;
    self.use     = pendulum_use;
    self.blocked = pendulum_blocked;

    if (self.spawnflags & SF_PEND_PASSABLE)
        self.solid = SOLID_NOT;

    // Axis selection — HL's CBaseToggle::AxisDir bit-to-movedir map.
    // The FGD flag NAMES ("X axis" / "Y axis") refer to which slot of
    // the movedir vector is set non-zero, NOT to which world axis the
    // brush rotates around.  HL maps' spawn flags are picked for HL's
    // movedir map, so we mirror it exactly:
    //   bit 64  ("X axis" FGD) → movedir (0,0,1) → angles_z = roll
    //   bit 128 ("Y axis" FGD) → movedir (1,0,0) → angles_x = pitch
    //   default                → movedir (0,1,0) → angles_y = yaw
    if (self.spawnflags & SF_PEND_X_AXIS)
        self.pend_axis_vec = '0 0 1';
    else if (self.spawnflags & SF_PEND_Y_AXIS)
        self.pend_axis_vec = '1 0 0';
    else
        self.pend_axis_vec = '0 1 0';

    // Bake distance sign into the axis vector so all downstream math
    // uses positive amp.  Negative distance reverses initial swing
    // direction (HL semantic).
    float signed_distance = self.distance;
    if (signed_distance < 0)
    {
        self.pend_axis_vec = self.pend_axis_vec * -1;
        signed_distance    = -signed_distance;
    }
    float amp = signed_distance * 0.5;
    self.pend_amp_initial = amp;
    self.pend_amp         = amp;

    // omega = sqrt(2 * accel / amp) where accel = speed^2 / (2*distance).
    // Substituting: omega = sqrt(speed^2 / (distance * amp)) =
    //   speed / sqrt(distance * amp) = speed / sqrt(distance * distance/2)
    //   = speed * sqrt(2) / distance.
    // Equivalently: omega = 2*speed / distance (the simple harmonic
    // identity peak_velocity = amp * omega → omega = peak/amp).
    self.pend_omega = 2 * self.speed / signed_distance;

    // pos1 = mapper's spawn pose = one extreme of the swing.
    // center = pos1 + axis_vec * amp (offset into the swing direction).
    self.pos1        = self.angles;
    self.pend_center = self.pos1 + self.pend_axis_vec * amp;

    if (self.spawnflags & SF_PEND_START_ON)
        pendulum_start_swing();
};
