//
//  sv_rotating.qc  –  func_rotating  (GoldSrc-compatible spinning brush)
//
//  Continuously-rotating brush — fans, drills, anything that just
//  spins.  Differs from func_door_rotating in that there's no
//  pos1/pos2 / open/close lifecycle: the entity is either ON
//  (rotating at fan_target_speed) or OFF (stopped), with optional
//  acceleration / deceleration ramping under the ACC_DCC spawnflag.
//
//  Origin brush (an ORIGIN-textured brush in the entity) defines
//  the rotation pivot — same convention as func_door_rotating; the
//  BSP compiler bakes it into self.origin.
//

// ---------------------------------------------------------------------------
// Externs from earlier compile units.
// ---------------------------------------------------------------------------
void() SV_InitReplicatedSolidBrush;                                  // sv_brushsync.qc
float(entity attacker, entity target, float damage) W_ApplyDamage;   // sv_weapons.qc
float() Brush_RotateCarry;                                           // sv_doors_rotating.qc

// Spawnflag bits — match HL/GoldSrc func_rotating exactly so existing
// .bsp entity dumps decode correctly.
const float ROT_START_ON       = 1;
const float ROT_REVERSE        = 2;
const float ROT_X_AXIS         = 4;
const float ROT_Y_AXIS         = 8;
const float ROT_ACC_DCC        = 16;
const float ROT_FAN_PAIN       = 32;
const float ROT_NOT_SOLID      = 64;
const float ROT_SMALL_RADIUS   = 128;
const float ROT_MEDIUM_RADIUS  = 256;
const float ROT_LARGE_RADIUS   = 512;

// Per-fan state.
.float   fan_target_speed;   // deg/sec, magnitude
.float   fan_current_speed;  // deg/sec, magnitude (ramps under ACC/DCC)
.float   fan_active;         // 0 = stopped, 1 = running / ramping toward target
.float   fan_axis_index;     // 0=X, 1=Z (default), 2=Y — matches RotDoor_RotateAround
.float   fan_axis_sign;      // +1 or -1 (set from REVERSE)
.float   fan_attn;           // ATTN_NONE / ATTN_NORM / ATTN_IDLE / ATTN_STATIC
.float   fan_volume;         // 0..1 (volume key / 10)
.string  fan_noise;          // resolved looped sound path
.float   fan_next_hit;       // per-victim cooldown for FAN_PAIN

// Shared field — declared authoritatively in sv_doors.qc.
.float dmg;

// Mapper-set keys.  Declared here as entity fields so the BSP loader
// populates them when the worldspawn parser sees "fanfriction" /
// "volume" lines in the entity block.
.float fanfriction;
.float volume;

// Fan-sound preset table.  GoldSrc convention: the wav assets have
// loop cue points so the engine repeats them automatically once
// kicked off via sound().
string(float idx) Rotating_LookupSound =
{
    if (idx == 1) return "fans/fan1.wav";
    if (idx == 2) return "fans/fan2.wav";
    if (idx == 3) return "fans/fan3.wav";
    if (idx == 4) return "fans/fan4.wav";
    if (idx == 5) return "fans/fan5.wav";
    return "misc/null.wav";       // 0 = silence
};

// Per-fan think — runs every 0.1 s.  Single code path for both
// ACC/DCC ramp and instant snap; the spawnflag just picks the
// per-tick step.  Writes self.avelocity on the chosen axis and
// bumps SendFlags so brushsync re-ships the new spin to clients.
void() rotating_think =
{
    float step = self.fan_target_speed * (self.fanfriction / 100);
    float target;
    if (self.fan_active)
        target = self.fan_target_speed;
    else
        target = 0;

    if (self.spawnflags & ROT_ACC_DCC)
    {
        // Ramp toward target by step per tick.
        if (self.fan_current_speed < target)
        {
            self.fan_current_speed = self.fan_current_speed + step;
            if (self.fan_current_speed > target)
                self.fan_current_speed = target;
        }
        else if (self.fan_current_speed > target)
        {
            self.fan_current_speed = self.fan_current_speed - step;
            if (self.fan_current_speed < target)
                self.fan_current_speed = target;
        }
    }
    else
    {
        // Instant snap when ACC/DCC is off.
        self.fan_current_speed = target;
    }

    // Apply current speed to the chosen axis component.  axis_index
    // mirrors RotDoor_RotateAround's convention: 0=X, 1=Z (yaw,
    // default), 2=Y.
    self.avelocity = '0 0 0';
    if (self.fan_axis_index == 0)
        self.avelocity_x = self.fan_current_speed * self.fan_axis_sign;
    else if (self.fan_axis_index == 2)
        self.avelocity_z = self.fan_current_speed * self.fan_axis_sign;
    else
        self.avelocity_y = self.fan_current_speed * self.fan_axis_sign;
    self.SendFlags = 1;

    // Carry-or-halt: try to push players the brush would clip into;
    // if any can't be pushed (wedged against a wall) Brush_RotateCarry
    // returns blocked=1 with `dmg` already applied per blocker each
    // tick.  We then HALT the rotation for this tick (revert the
    // engine's angle integration so the brush appears stationary) but
    // keep fan_current_speed intact — the next tick re-runs the carry
    // and either resumes rotation (blocker cleared) or halts again
    // (still wedged).  This is the "stop, damage every tick, resume
    // when out of the way" semantic the user asked for.
    self.rotdoor_axis_index = self.fan_axis_index;
    if (self.fan_current_speed > 0)
    {
        self.pos1 = self.angles;

        // Capture pre-carry angles BEFORE Brush_RotateCarry — it
        // updates rotdoor_carry_last_angles to the post-integration
        // value at the top of the function, so without this snapshot
        // we'd lose the pre-tick state we need for the revert.
        vector pre_carry_angles = self.rotdoor_carry_last_angles;

        if (Brush_RotateCarry())
        {
            // Revert the engine's angle integration for this tick.
            // self.angles ← pre-tick value, and rotdoor_carry_last_angles
            // ← same so next tick's deg_step is correct.
            self.angles                    = pre_carry_angles;
            self.rotdoor_carry_last_angles = pre_carry_angles;
            // Stop integrating next physics frame.  The top of
            // rotating_think re-sets avelocity from fan_current_speed
            // on the next tick, so this halt is per-tick only.
            self.avelocity = '0 0 0';
            self.SendFlags = 1;
        }
    }

    // Tick at sv_func_tickrate (default 64 Hz) so the carry pass
    // applies smoothly per server tick instead of the previous 10 Hz
    // chunks — at slow rotation speeds (e.g. fanfriction 20 + speed 30)
    // 10 Hz felt like the player wasn't being taken with the rotation,
    // because the carry only fired every 100 ms (3° per chunk vs. the
    // brush's continuously-integrated angles).
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = 40;
    if (hz > 200)  hz = 200;
    self.nextthink = self.ltime + 1.0 / hz;
};

// .use toggles ON/OFF.  Plays the looped sound on transition into
// active and silences it on transition out.  The think loop is
// always running — it observes fan_active and ramps accordingly,
// so .use never needs to schedule its own think.
void() rotating_use =
{
    self.fan_active = self.fan_active ? 0 : 1;
    if (self.fan_active)
    {
        if (self.fan_noise != "misc/null.wav")
            sound(self, CHAN_VOICE, self.fan_noise,
                  self.fan_volume, self.fan_attn);
    }
    else
    {
        // FTE silences the channel by replaying with vol=0.
        sound(self, CHAN_VOICE, "misc/null.wav", 0, self.fan_attn);
    }
};

// FAN_PAIN: damage on contact while spinning.  Per-victim 0.5s
// cooldown matches the trigger_hurt cadence so a `dmg N` map key
// reads as ~N HP/s of sustained damage.
void() rotating_touch =
{
    if (!(self.spawnflags & ROT_FAN_PAIN)) return;
    if (self.fan_current_speed <= 0) return;     // not actually spinning
    if (other.classname != "player") return;     // GoldSrc semantics
    if (time < other.fan_next_hit) return;
    other.fan_next_hit = time + 0.5;
    if (self.dmg > 0)
        W_ApplyDamage(self, other, self.dmg);
};

// .blocked: the engine fires this when our push integration runs
// into something solid.  Apply dmg if set.  Fans don't reverse on
// block (matching GoldSrc) — combined with dmg, this becomes a
// meat-grinder.
void() rotating_blocked =
{
    if (self.dmg > 0 && other != world && other.takedamage != DAMAGE_NO)
        W_ApplyDamage(self, other, self.dmg);
};

/*QUAKED func_rotating (0 .5 .8) ? START_ON REVERSE X_AXIS Y_AXIS ACC_DCC FAN_PAIN NOT_SOLID SMALL_RADIUS MEDIUM_RADIUS LARGE_RADIUS
A continuously-rotating brush (fan / drill / spinner).  Define the
rotation axis with an ORIGIN-textured brush included in the entity
(the BSP compiler bakes the axis into self.origin).

"speed"        peak rotation speed (deg/sec, default 100)
"fanfriction"  Acc/Dcc ramp rate 1-100 (default 50; only matters with ACC_DCC flag)
"volume"       sound volume 0-10 (default 10 = 1.0)
"sounds"       fan sound preset (0=silent, 1..5 = fans/fan1..5.wav)
"message"      custom WAV path (overrides "sounds")
"dmg"          damage per FAN_PAIN tick AND per crush (default 0)
*/
void() func_rotating =
{
    // Resolve looped noise: "message" key (mapper-supplied custom WAV)
    // overrides the "sounds" preset.  Empty / absent → silence sentinel.
    string preset = Rotating_LookupSound(self.sounds);
    if (self.message && self.message != "")
        self.fan_noise = self.message;
    else
        self.fan_noise = preset;
    if (self.fan_noise != "misc/null.wav")
        precache_sound(self.fan_noise);
    // Always precache the silence sentinel — every func_rotating
    // toggles to it on .use to stop the looped sound, so the wav
    // needs to be in the precache table before the first sound()
    // call references it (otherwise FTE warns once per toggle).
    precache_sound("misc/null.wav");

    // Volume 0..10 → 0..1.  Default to full volume when the mapper
    // didn't set the key (HL convention — "volume" is optional).
    if (self.volume <= 0)
        self.fan_volume = 1.0;
    else
        self.fan_volume = bound(0, self.volume / 10, 1);

    // Sound radius spawnflag → ATTN_*.  Larger HL radius = lower
    // attenuation (sound carries further).  No-flag default is the
    // "Large Radius" semantic per the spec.
    if (self.spawnflags & ROT_SMALL_RADIUS)
        self.fan_attn = ATTN_IDLE;
    else if (self.spawnflags & ROT_MEDIUM_RADIUS)
        self.fan_attn = ATTN_STATIC;
    else
        self.fan_attn = ATTN_NORM;

    // Axis pick — match HL's CBaseToggle::AxisDir bit-to-movedir map.
    // The FGD flag NAMES ("X axis" / "Y axis") refer to which slot of
    // the movedir vector HL's source code sets non-zero, NOT to which
    // world axis the brush rotates around.  HL maps' spawn flags are
    // picked for HL's mapping, so we mirror it exactly:
    //   bit 4  ("X axis" FGD) → movedir (0,0,1) → angles_z = roll
    //   bit 8  ("Y axis" FGD) → movedir (1,0,0) → angles_x = pitch
    //   default               → movedir (0,1,0) → angles_y = yaw
    if (self.spawnflags & ROT_X_AXIS)
        self.fan_axis_index = 2;       // roll (avelocity_z)
    else if (self.spawnflags & ROT_Y_AXIS)
        self.fan_axis_index = 0;       // pitch (avelocity_x)
    else
        self.fan_axis_index = 1;       // yaw (avelocity_y, default)

    self.fan_axis_sign = (self.spawnflags & ROT_REVERSE) ? -1 : 1;

    if (!self.speed)        self.speed       = 100;
    if (!self.fanfriction)  self.fanfriction = 50;
    self.fan_target_speed  = self.speed;
    self.fan_current_speed = 0;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_STATIC;     // not a mover with pos1/pos2
    self.brush_is_rotating = 1;
    self.use     = rotating_use;
    self.blocked = rotating_blocked;
    if (self.spawnflags & ROT_FAN_PAIN)
        self.touch = rotating_touch;

    // Pre-set rotdoor_axis_index for the carry-rotation math; per-tick
    // rotating_think keeps it in sync with fan_axis_index.
    self.rotdoor_axis_index = self.fan_axis_index;

    if (self.spawnflags & ROT_NOT_SOLID)
        self.solid = SOLID_NOT;

    self.fan_active = (self.spawnflags & ROT_START_ON) ? 1 : 0;
    if (self.fan_active && self.fan_noise != "misc/null.wav")
        sound(self, CHAN_VOICE, self.fan_noise,
              self.fan_volume, self.fan_attn);

    // Without ACC/DCC, snap current to target so the very first
    // think tick already has the brush spinning at full speed.
    if (!(self.spawnflags & ROT_ACC_DCC) && self.fan_active)
        self.fan_current_speed = self.fan_target_speed;

    self.think = rotating_think;
    {
        float ihz = cvar("sv_func_tickrate");
        if (ihz <= 0)  ihz = 40;
        if (ihz > 200) ihz = 200;
        self.nextthink = self.ltime + 1.0 / ihz;
    }
};
