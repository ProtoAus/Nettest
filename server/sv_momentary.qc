//
//  sv_momentary.qc  –  GoldSrc Half-Life compatibility brush entities
//
//    func_rot_button       — a button that ROTATES around an origin-brush
//                            pivot when activated, then fires its target.
//    momentary_rot_button  — a rotating valve/wheel you HOLD +use to turn;
//                            drives its target momentary_door's open
//                            fraction (0..1) proportionally.
//    momentary_door        — a sliding door positioned externally (0..1)
//                            by a momentary_rot_button — no auto-travel.
//
//  Functional/compatible port (NOT bug-for-bug): the documented HL quirks
//  and the Team-Fortress-Classic-only keys are intentionally skipped.
//
//  Reuses the existing brush infrastructure: SV_InitReplicatedSolidBrush
//  (render keys + CSQC sync), SetMovedir (door direction), the func_door
//  sound lookups, Mover_PlatformCarry (rider carry), Trigger_UseTargets
//  (target firing), and the func_door_rotating axis-flag mapping.
//
//  KNOWN LIMITATIONS (per "compatible, not bug-for-bug"):
//    * One driving momentary_rot_button per momentary_door — a "Door Hack"
//      companion just spawns as a solid no-op (no multi-button sync).
//    * Momentary motion is server-authoritative + correct but NOT
//      client-predicted, so it can snapshot-step under high latency.
//    * A player standing in a closing momentary_door's path is pushed out
//      by depenetration rather than crushed (the door is position-driven).
//

// ---------------------------------------------------------------------------
// Externs from earlier compile units.
// ---------------------------------------------------------------------------
void() SV_InitReplicatedSolidBrush;                                  // sv_brushsync.qc
void() SetMovedir;                                                   // sv_push.qc
void(entity caller, entity triggerer) Trigger_UseTargets;            // sv_doors.qc
string(float idx) Door_LookupMoveSound;                              // sv_doors.qc
string(float idx) Door_LookupStopSound;                              // sv_doors.qc
string(float idx) Button_LookupSound;                                // sv_doors.qc
void(string snd) Door_PrecacheIfReal;                                // sv_doors.qc
float(entity attacker, entity target, float damage) W_ApplyDamage;   // sv_weapons.qc
float() Mover_PlatformCarry;                                         // sv_platform_carry.qc

// sh_pmove.qc compiles AFTER this file, so the rotating-brush list helpers
// it defines (used by func_rot_button's predicted rotation) are pre-declared.
void(entity c) RotatingBrush_AddToList;
void(entity c) RotatingBrush_RemoveFromList;

// Shared fields — declared authoritatively in earlier units; QC accepts
// duplicate `.float foo;` decls and they share storage.
.float  movesnd;
.float  stopsnd;
.float  dmg;
.float  rotdoor_axis_index;       // sv_doors_rotating.qc
.float  brush_is_rotating;        // sv_brushsync.qc
.vector platform_prev_origin;     // sv_platform_carry.qc
.float  platform_prev_seeded;     // sv_platform_carry.qc

// New fields for the momentary system.
.float  returnspeed;              // momentary_rot_button auto-return speed (deg/sec)
.float  momentary_frac;           // current 0..1 (button = rotation/distance, door = position)
.float  momentary_dir;            // +1 toward open, -1 toward close (no-auto-return mode)
.float  momentary_moving;         // momentary_door: move sound currently looping?
.float  momentary_idle_at;        // momentary_door: time after which it has settled
.entity momentary_active_button;  // ON THE PLAYER: the wheel they are currently turning

// PM_BTN_USE lives in sh_pmove.qc:45 which compiles after us — mirror the
// literal here (same trick CFC4_BTN_USE uses in sh_wpn_cfc4.qc).
const float MOM_BTN_USE = 128;    // +button8 / +use, set continuously while held

// Axis spawnflags — same values + mapping as func_door_rotating.
const float MOM_X_AXIS = 64;
const float MOM_Y_AXIS = 128;

// Set self.movedir + self.rotdoor_axis_index from the X/Y axis flags,
// mirroring func_door_rotating exactly (the FGD flag NAMES refer to which
// movedir slot HL sets, not the world axis rotated around):
//   bit 64  ("X axis") → movedir (0,0,1) → roll  (axis index 2)
//   bit 128 ("Y axis") → movedir (1,0,0) → pitch (axis index 0)
//   default            → movedir (0,1,0) → yaw   (axis index 1)
void() Momentary_AxisSetup =
{
    if (self.spawnflags & MOM_X_AXIS)
    {
        self.movedir            = '0 0 1';
        self.rotdoor_axis_index = 2;
    }
    else if (self.spawnflags & MOM_Y_AXIS)
    {
        self.movedir            = '1 0 0';
        self.rotdoor_axis_index = 0;
    }
    else
    {
        self.movedir            = '0 1 0';
        self.rotdoor_axis_index = 1;
    }
};

// Per-tick interval from sv_func_tickrate (Hz → seconds), clamped — matches
// the doors' RotDoor_TickInterval.
float() Momentary_TickInterval =
{
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = 40;
    if (hz > 200)  hz = 200;
    return 1.0 / hz;
};

// HL func_rot_button uses the lever sound set (sounds idx 21..25).
string(float idx) Momentary_LeverSound =
{
    if (idx == 21) return "buttons/lever1.wav";
    if (idx == 22) return "buttons/lever2.wav";
    if (idx == 23) return "buttons/lever3.wav";
    if (idx == 24) return "buttons/lever4.wav";
    if (idx == 25) return "buttons/lever5.wav";
    return Button_LookupSound(idx);   // fall back to the generic button table
};

// ============================================================================
//  momentary_door  (slave, fraction-driven)
// ============================================================================
//  pos1 = closed origin, pos2 = open origin (func_door movedir/lip/distance
//  convention).  The driving button calls MomentaryDoor_SetFrac() every
//  frame; we setorigin directly (tight follow) and carry riders.
// ============================================================================

const float MOMDOOR_START_OPEN = 1;

void() MomentaryDoor_SoundWatch;

void() momentary_door_blocked =
{
    // Position-driven, so no reverse — just crush damage if a rider gets
    // wedged (Mover_PlatformCarry's path check can still fire this).
    if (self.dmg > 0 && other != world)
        W_ApplyDamage(self, other, self.dmg);
};

// Stop the looping move sound once the door has been idle for ~0.2s.
void() MomentaryDoor_SoundWatch =
{
    if (time >= self.momentary_idle_at)
    {
        if (self.momentary_moving)
        {
            self.momentary_moving = 0;
            sound(self, CHAN_VOICE, "common/null.wav", 1, ATTN_NORM);  // cut the loop
            if (self.noise1 != "" && self.noise1 != "common/null.wav")
                sound(self, CHAN_VOICE, self.noise1, 1, ATTN_NORM);     // stop clunk
        }
        return;     // settled — stop watching
    }
    self.nextthink = time + 0.1;
};

// Public: drive door to fraction `frac` (0=closed .. 1=open).  Called from
// the momentary_rot_button each frame it turns.
void(entity door, float frac) MomentaryDoor_SetFrac =
{
    frac = bound(0, frac, 1);
    vector target = door.pos1 + (door.pos2 - door.pos1) * frac;
    if (target == door.origin)
        return;     // no change → no move, no sound

    entity oself = self;
    self = door;

    if (!self.platform_prev_seeded)
    {
        self.platform_prev_origin = self.origin;
        self.platform_prev_seeded = 1;
    }

    setorigin(self, target);
    Mover_PlatformCarry();           // carry riders by (target - platform_prev_origin)
    self.momentary_frac = frac;
    self.SendFlags      = 1;

    // Move sound: start the loop on first motion, refresh the idle watchdog.
    if (!self.momentary_moving && self.noise2 != "" && self.noise2 != "common/null.wav")
    {
        sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);
        self.momentary_moving = 1;
    }
    self.momentary_idle_at = time + 0.2;
    self.think             = MomentaryDoor_SoundWatch;
    self.nextthink         = time + 0.25;

    self = oself;
};

void() momentary_door =
{
    if (self.movesnd > 0) self.noise2 = Door_LookupMoveSound(self.movesnd);
    if (self.stopsnd > 0) self.noise1 = Door_LookupStopSound(self.stopsnd);
    Door_PrecacheIfReal(self.noise2);
    Door_PrecacheIfReal(self.noise1);
    precache_sound("common/null.wav");      // played on CHAN_VOICE to cut the move-sound loop

    if (!self.speed) self.speed = 100;
    if (!self.dmg)   self.dmg   = 2;

    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_DOOR;
    self.blocked    = momentary_door_blocked;

    self.pos1 = self.origin;
    SetMovedir();
    if (self.distance)
        self.pos2 = self.pos1 + self.movedir * self.distance;
    else
        self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * self.size) - self.lip);

    // SetMovedir has just zeroed .angles, but SV_InitReplicatedSolidBrush above
    // already linked this brush with the old value.  Re-link so the PVS box is built
    // from the real geometry rather than one rotated about (0,0,0).
    // (The START_OPEN branch below happens to setorigin and would mask this.)
    BrushSync_RelinkAngles();

    if (self.spawnflags & MOMDOOR_START_OPEN)
    {
        setorigin(self, self.pos2);
        self.momentary_frac       = 1;
        self.platform_prev_origin = self.pos2;
    }
    else
    {
        self.momentary_frac       = 0;
        self.platform_prev_origin = self.pos1;
    }
    self.platform_prev_seeded = 1;
    self.door_state           = DOOR_STATE_BOTTOM;
};

// ============================================================================
//  func_rot_button  (instant rotating button, fires its target)
// ============================================================================

const float ROTBTN_NOT_SOLID = 1;
const float ROTBTN_REVERSE   = 2;
const float ROTBTN_TOGGLE    = 32;
const float ROTBTN_TOUCH     = 256;

void() rotbtn_go_up;
void() rotbtn_go_down;

// Lightweight angular move (no per-tick player carry — buttons are small and
// rarely ridden, and reusing the door's carry would couple to the door's
// blocked/reverse callbacks).  Sets avelocity, finishes via a wall-clock
// think, and publishes to the rotating-brush list for CSQC prediction.
void(vector dest_angles, float move_speed, void() move_done) RotBtn_RotateStart =
{
    vector delta = dest_angles - self.angles;
    float  dist  = vlen(delta);
    if (dist <= 0 || move_speed <= 0)
    {
        self.angles    = dest_angles;
        self.avelocity = '0 0 0';
        self.SendFlags = 1;
        move_done();
        return;
    }
    float travel   = dist / move_speed;
    self.avelocity = delta * (1.0 / travel);
    self.SendFlags = 1;
    self.think     = move_done;
    self.nextthink = self.ltime + travel;
    RotatingBrush_AddToList(self);
};

void() rotbtn_blocked =
{
    // A player blocking the swing just takes the block damage; the engine
    // reverts the brush's angle integration for the blocked tick, so the
    // button waits in place and completes once the player clears.
    if (self.dmg > 0 && other != world)
        W_ApplyDamage(self, other, self.dmg);
};

void() rotbtn_hit_bottom =
{
    self.angles      = self.pos1;
    self.avelocity   = '0 0 0';
    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;
    self.SendFlags   = 1;
    RotatingBrush_RemoveFromList(self);
    if (self.max_health) self.health = self.max_health;     // re-arm shootable
};

void() rotbtn_hit_top =
{
    self.angles      = self.pos2;
    self.avelocity   = '0 0 0';
    self.door_state  = DOOR_STATE_TOP;
    self.mover_state = MOVER_STATE_TOP;
    self.SendFlags   = 1;
    RotatingBrush_RemoveFromList(self);
    if (self.max_health) self.health = self.max_health;
    Trigger_UseTargets(self, self.enemy);                   // fire target on activation
    if ((self.spawnflags & ROTBTN_TOGGLE) || self.wait < 0)
        return;
    self.nextthink = self.ltime + self.wait;
    self.think     = rotbtn_go_down;
};

void() rotbtn_go_down =
{
    if (self.door_state == DOOR_STATE_BOTTOM || self.door_state == DOOR_STATE_DOWN)
        return;
    self.door_state  = DOOR_STATE_DOWN;
    self.mover_state = MOVER_STATE_DOWN;
    // Re-fire on the return stroke (mirrors func_button's button_return) so a
    // light target pulses off / a toggle's second press retriggers.
    Trigger_UseTargets(self, self.enemy);
    RotBtn_RotateStart(self.pos1, self.speed, rotbtn_hit_bottom);
};

void() rotbtn_go_up =
{
    if (self.door_state == DOOR_STATE_TOP || self.door_state == DOOR_STATE_UP)
        return;
    self.door_state  = DOOR_STATE_UP;
    self.mover_state = MOVER_STATE_UP;
    RotBtn_RotateStart(self.pos2, self.speed, rotbtn_hit_top);
};

void() rotbtn_fire =
{
    if (cvar("mp_disabledoors")) return;
    if (self.door_state == DOOR_STATE_UP || self.door_state == DOOR_STATE_DOWN)
        return;     // locked mid-rotation
    if (self.noise)
        sound(self, CHAN_VOICE, self.noise, 1, ATTN_NORM);
    if (self.door_state == DOOR_STATE_TOP)
    {
        if (self.spawnflags & ROTBTN_TOGGLE)
            rotbtn_go_down();       // toggle closes on the second press
        return;                     // non-toggle is committed to its auto-return
    }
    rotbtn_go_up();
};

void() rotbtn_use =
{
    self.enemy = activator;
    rotbtn_fire();
};

void() rotbtn_touch =
{
    if (other.classname != "player") return;
    if (!(self.spawnflags & ROTBTN_TOUCH)) return;
    self.enemy = other;
    rotbtn_fire();
};

void() func_rot_button =
{
    if (!self.noise)
        self.noise = Momentary_LeverSound(self.sounds ? self.sounds : 21);
    Door_PrecacheIfReal(self.noise);

    if (!self.speed)    self.speed    = 50;
    if (!self.wait)     self.wait     = 3;
    if (!self.distance) self.distance = 90;

    SV_InitReplicatedSolidBrush();
    self.brush_type        = BRUSH_TYPE_BUTTON;
    self.brush_is_rotating = 1;
    self.blocked           = rotbtn_blocked;

    if (self.spawnflags & ROTBTN_NOT_SOLID)
        self.solid = SOLID_NOT;

    Momentary_AxisSetup();
    self.pos1 = self.angles;
    self.pos2 = self.pos1 + self.movedir
              * (self.distance * ((self.spawnflags & ROTBTN_REVERSE) ? -1 : 1));

    self.use = rotbtn_use;
    if (self.spawnflags & ROTBTN_TOUCH)
        self.touch = rotbtn_touch;
    if (self.health)
    {
        self.max_health = self.health;          // W_ApplyDamage fires .use on death
        self.takedamage = DAMAGE_YES;
    }

    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;
};

// ============================================================================
//  momentary_rot_button  (held-+use rotating wheel that drives momentary_door)
// ============================================================================

const float MOMROT_DOORHACK   = 1;     // solid but un-USE-able companion
const float MOMROT_AUTORETURN = 16;    // returns toward closed when released

void() MomRotBtn_ReturnTick;

// Push the button's current fraction out to every momentary_door it targets.
void(entity btn, float frac) MomRotBtn_DriveDoors =
{
    if (!btn.target) return;
    entity d = find(world, targetname, btn.target);
    while (d)
    {
        if (d.classname == "momentary_door")
            MomentaryDoor_SetFrac(d, frac);
        d = find(d, targetname, btn.target);
    }
};

// Set the button's rotation to fraction `frac` (0..1) + sync visuals/doors.
void(entity btn, float frac) MomRotBtn_SetFrac =
{
    frac = bound(0, frac, 1);
    btn.momentary_frac = frac;
    btn.angles = btn.pos1 + btn.movedir * (btn.distance * frac);
    setorigin(btn, btn.origin);      // relink the rotated collision/bounds
    btn.SendFlags = 1;
    MomRotBtn_DriveDoors(btn, frac);
};

// Advance the button while +use is held (called every server frame).
void(entity btn) MomRotBtn_Advance =
{
    if (btn.distance <= 0) return;
    float ft = frametime;
    if (ft <= 0)   ft = 0.013;
    if (ft > 0.1)  ft = 0.1;
    float step = (btn.speed > 0 ? btn.speed : 50) * ft / btn.distance;   // frac/frame
    MomRotBtn_SetFrac(btn, btn.momentary_frac + btn.momentary_dir * step);
};

// Auto-return: ease the fraction back toward 0 at returnspeed.  Yields if the
// player re-grabs (enemy set again).
void() MomRotBtn_ReturnTick =
{
    if (self.enemy != world)
        return;     // re-grabbed — held drive takes over, stop returning
    if (self.distance <= 0 || self.momentary_frac <= 0)
    {
        self.momentary_dir = 0;
        return;
    }
    float spd  = (self.returnspeed > 0) ? self.returnspeed : self.speed;
    float dt   = Momentary_TickInterval();
    float step = (spd > 0 ? spd : 50) * dt / self.distance;
    MomRotBtn_SetFrac(self, self.momentary_frac - step);
    if (self.momentary_frac <= 0)
    {
        self.momentary_dir = 0;
        return;     // closed — stop
    }
    self.nextthink = self.ltime + dt;
};

// Release: clear the claim; auto-return buttons start easing closed.
void(entity btn) Momentary_Release =
{
    if (btn.enemy != world)
        btn.enemy = world;
    if ((btn.spawnflags & MOMROT_AUTORETURN) && btn.momentary_frac > 0)
    {
        btn.think     = MomRotBtn_ReturnTick;
        btn.nextthink = btn.ltime + Momentary_TickInterval();
    }
};

// Per-frame held-+use poll — called from PlayerPreThink for each alive player
// (mirrors C4_TickDefuseInteraction).  Detects the wheel the player is holding
// +use at and drives it; releases it when +use lets go or aim leaves.
void(entity player) Momentary_TickInteraction =
{
    entity btn = world;

    if ((input_buttons & MOM_BTN_USE) && player.health > 0)
    {
        makevectors(player.v_angle);
        vector start = player.origin + player.view_ofs;
        vector end   = start + v_forward * 96;

        tracebox(start, '-8 -8 -8', '8 8 8', end, MOVE_NORMAL, player);
        if (trace_ent.classname == "momentary_rot_button"
            && !(trace_ent.spawnflags & MOMROT_DOORHACK))
            btn = trace_ent;

        if (btn == world)
        {
            float best = 0.6;
            entity e = findradius(start, 96);
            while (e)
            {
                if (e.classname == "momentary_rot_button"
                    && !(e.spawnflags & MOMROT_DOORHACK))
                {
                    vector to_e = e.origin - start;
                    float d = vlen(to_e);
                    if (d > 0)
                    {
                        float dot = (to_e * (1.0 / d)) * v_forward;
                        if (dot > best) { best = dot; btn = e; }
                    }
                }
                e = e.chain;
            }
        }
    }

    entity prev = player.momentary_active_button;

    if (btn != world)
    {
        // Stale-claim recovery — if the recorded claimer is no longer driving
        // this wheel (died / disconnected / respawned without the release path
        // running), free it so it can't lock up.
        if (btn.enemy != world && btn.enemy.momentary_active_button != btn)
            btn.enemy = world;

        // First-claim-wins — another player is already turning it.
        if (btn.enemy != world && btn.enemy != player)
        {
            if (prev) { Momentary_Release(prev); player.momentary_active_button = world; }
            return;
        }

        if (btn != prev)
        {
            // Fresh grab (rising edge): release any prior, claim, pick direction.
            if (prev) Momentary_Release(prev);
            btn.enemy = player;
            if (btn.spawnflags & MOMROT_AUTORETURN)
                btn.momentary_dir = 1;                  // always opens while held
            else if (btn.momentary_dir == 0)
                btn.momentary_dir = 1;                  // first grab opens
            else
                btn.momentary_dir = -btn.momentary_dir; // alternate open/close
            player.momentary_active_button = btn;
        }

        MomRotBtn_Advance(btn);
        return;
    }

    // Not holding +use at a wheel — release ours.
    if (prev)
    {
        Momentary_Release(prev);
        player.momentary_active_button = world;
    }
};

void() momentary_rot_button =
{
    if (!self.noise)
        self.noise = Momentary_LeverSound(self.sounds ? self.sounds : 21);
    Door_PrecacheIfReal(self.noise);

    if (!self.speed)    self.speed    = 50;
    if (!self.distance) self.distance = 90;

    SV_InitReplicatedSolidBrush();
    self.brush_type        = BRUSH_TYPE_BUTTON;
    self.brush_is_rotating = 1;

    Momentary_AxisSetup();
    self.pos1 = self.angles;                       // closed angles
    self.pos2 = self.pos1 + self.movedir * self.distance;  // open angles
    self.momentary_frac = 0;
    self.momentary_dir  = 0;

    // Door Hack: solid but NOT directly usable — a placed companion that the
    // (intentionally unimplemented) multi-button sync would drive.  It just
    // sits there solid; the primary button drives the door.  No .use so the
    // held-+use poll skips it.  Non-DoorHack buttons are driven entirely by
    // Momentary_TickInteraction, so they also get no one-shot .use.
};
