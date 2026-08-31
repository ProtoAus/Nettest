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

// EVERY momentary_rot_button on the map, in a spawn-time list.
//
// The aim search walks THIS rather than findradius, and that is not a
// micro-optimisation - it is the only thing that works.  A non-DoorHack button is
// SOLID_NOT (Half-Life's rule, see the spawn function), and findradius SKIPS
// non-solid entities unless FL_FINDABLE_NONSOLID is set (engine world.c:1893).
// So the tracebox misses it for being non-solid and findradius drops it for the
// same reason, and the wheel becomes literally unfindable.
//
// A list has no such coupling, costs one pointer per button, and is what
// sv_teleport.qc already does for the same kind of "small fixed set the pmove
// has to scan every frame" problem.  It is also closer to Half-Life, whose
// PlayerUse walks entities in a sphere and never traces at all.
entity momentary_button_list;
.entity momentary_next;

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
    // Floored at the server's real physics frame — see Mover_TickInterval in
    // sv_customdefs.qc.
    return Mover_TickInterval(40);
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

    if (cvar("sv_debug_use"))
        dprint(sprintf("[momentary] door \"%s\" frac=%.3f origin=%v (pos1=%v pos2=%v)\n",
                       self.targetname, frac, self.origin, self.pos1, self.pos2));

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
    {
        // GoldSrc subtracts 2 from the size here, and says why:
        //
        //   // Subtract 2 from size because the engine expands bboxes by 1 in
        //   // all directions
        //                                     (doors.cpp, CMomentaryDoor::Spawn)
        //
        // That expansion is Mod_LoadSubmodels' "spread the mins / maxs by a
        // pixel", which FTE inherits verbatim (gl_model.c:4513 and :4551), so
        // .size is padded here by exactly the 2 the reference game is taking
        // back off.  Without it every momentary_door on every GoldSrc map
        // travelled two units past its stop.
        vector sz = self.size - '2 2 2';
        self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * sz) - self.lip);
    }

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

// RE-SNAPSHOT THE SWEEPING BUTTON TO CSQC ONCE PER TICK.
//
// The server side of this class was always right — the pusher integrates
// .avelocity into .angles every frame (sv_phys.c:1106-1127), so the real button
// completes its whole sweep.  What was wrong is what the CLIENT was told: the
// brush is drawn by the CSQC replica, and a CSQC entity is only re-sent when QC
// dirties SendFlags.  RotBtn_RotateStart dirtied it exactly ONCE, at the start.
//
// Meanwhile the client hard-caps forward extrapolation of a rotating mover to
// 0.05 s (cl_brushsync.qc:185-186, `if (clamp_to_dest && lookahead > 0.05)`),
// on a stated precondition (:171-175) that the server re-sends every tick "so a
// 50 ms forward cap covers a single missed snap".  func_door_rotating does
// (sv_doors_rotating.qc:599); this class did not.  So the replica advanced
// avelocity * 0.05 and then sat perfectly still until rotbtn_hit_top finally
// dirtied SendFlags and it snapped to the end.  At the corpus's most common
// authoring (speed 120, distance 90) that is 6 degrees of a 90-degree sweep —
// "only turns for 1 frame and stops".
//
// The fix belongs on this side, not by relaxing the client cap: the dest-axis
// clamp that used to bound the projection was deliberately removed
// (cl_brushsync.qc:190-198), so an uncapped 1.0 s lookahead would let a 0.75 s
// button overshoot pos2 by 30 degrees whenever the finish snapshot ran late.
//
// Borrows .rotdoor_finish_time / .rotdoor_finish_cb from sv_doors_rotating.qc
// (:127-128, compiled at sv_progs.src:224, before this file at :253).  A
// func_rot_button never runs rotating-door code, so the slots cannot collide.
void() RotBtn_SweepTick =
{
    if (self.ltime >= self.rotdoor_finish_time)
    {
        self.avelocity = '0 0 0';
        self.SendFlags = 1;
        // Return immediately after invoking it — the callback schedules its own
        // next think (rotbtn_hit_top sets nextthink = ltime + wait), and
        // touching nextthink afterwards would stomp that.  Identical shape to
        // RotDoor_CarryTick (sv_doors_rotating.qc:580-587).
        if (self.rotdoor_finish_cb)
            self.rotdoor_finish_cb();
        return;
    }
    self.SendFlags = 1;
    // CLAMP THE LAST TICK TO LAND EXACTLY ON THE DESTINATION.  The pusher
    // shortens movetime so ltime lands precisely on nextthink
    // (sv_phys.c:1147-1153), which is why the old single `nextthink = ltime +
    // travel` stopped the brush dead on pos2.  Ticking in whole intervals and
    // firing the callback on the first tick where ltime >= finish_time would let
    // the button rotate up to one interval PAST pos2 before rotbtn_hit_top snaps
    // it back — at the corpus's speed-200 authoring that is 5 degrees of
    // over-rotation on a SOLID_BSP brush with .blocked armed, so a player
    // standing at the end of the swing could be shoved or take block damage in
    // an arc the button never legitimately enters.  func_door_rotating carries
    // that flaw; this class does not have to inherit it.
    float step = Momentary_TickInterval();
    float left = self.rotdoor_finish_time - self.ltime;
    if (left < step) step = left;
    self.nextthink = self.ltime + step;
};

// Lightweight angular move (no per-tick player carry — buttons are small and
// rarely ridden, and reusing the door's carry would couple to the door's
// blocked/reverse callbacks).  Sets avelocity, ticks a re-snapshot to CSQC
// until the sweep is done, and publishes to the rotating-brush list for CSQC
// prediction.
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
    self.rotdoor_finish_time = self.ltime + travel;
    self.rotdoor_finish_cb   = move_done;
    self.think               = RotBtn_SweepTick;
    // Same exact-landing clamp as RotBtn_SweepTick — a sweep shorter than one
    // tick must still finish on time rather than a tick late.
    float first = Momentary_TickInterval();
    if (travel < first) first = travel;
    self.nextthink           = self.ltime + first;
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

    // MULTISOURCE ONLY on the return stroke.  This used to be a blanket
    // Trigger_UseTargets "so a light target pulses off", but Half-Life is
    // explicit that the return stroke re-fires ONLY multisource targets
    // (dlls/buttons.cpp:764-781 walks the target chain and `continue`s on
    // anything that is not FClassnameIs "multisource").
    //
    // The blanket form was harmless only because these buttons were unreachable
    // (see func_rot_button's SOLID_NOT note).  With that fixed it becomes a real
    // bug: desertcircle's ammo crates are `wait 10`, so one press would equip the
    // player, then equip them AGAIN ten seconds later when the button swung back.
    if (self.target != "" && self.target != __NULL__)
    {
        entity btn     = self;
        entity oldact  = activator;
        float  oldut   = sub_use_type;
        entity t       = find(world, targetname, self.target);
        while (t)
        {
            entity nxt = find(t, targetname, btn.target);
            if (t.classname == "multisource" && t.use)
            {
                self         = t;
                activator    = btn.enemy;
                sub_use_type = USE_TOGGLE;
                t.use();
            }
            t = nxt;
        }
        self         = btn;
        activator    = oldact;
        sub_use_type = oldut;
    }

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
    {
        self.solid = SOLID_NOT;

        // ...and therefore INVISIBLE TO +use unless we opt back into findradius.
        // traceline cannot hit a SOLID_NOT entity, and FTE's findradius skips
        // them outright (engine/common/pr_bgcmd.c:4085 - the only escape hatch is
        // sv_gameplayfix_blowupfallenzombies, which defaults to 0), so both
        // halves of SV_PlayerTryUse's search miss and rotbtn_use is unreachable.
        //
        // Half-Life has no equivalent problem: CBasePlayer::PlayerUse walks a
        // 64-unit sphere with no solidity test at all (dlls/player.cpp:1634), so
        // a "Not solid" button is exactly as usable there as a solid one.
        //
        // momentary_rot_button already carries this exact fix a few hundred lines
        // below, with a comment diagnosing this exact failure - it was simply
        // never applied to its sibling in the same file.  desertcircle is where
        // it shows: all five of its ammo-crate buttons set this flag, so pressing
        // a crate did nothing at all.  Every "Not solid" func_rot_button on every
        // GoldSrc map was affected.
        self.flags = self.flags | FL_FINDABLE_NONSOLID;
    }

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
//
// THE ROTATION IS CONDITIONAL, and this is what made desertcircle's flag poles
// unusable.  A GoldSrc brush entity compiled WITHOUT an ORIGIN brush keeps
// .origin == '0 0 0' and carries its world position baked into the submodel's
// absolute bounds - sv_brushsync.qc:595-603 documents exactly this hazard.
// Writing .angles on such a brush rotates it about the MAP ORIGIN, not about
// itself.  Measured on desertcircle: flagbutton1's model *1 sits at
// (2828,-2548,160), which is 3806 units from (0,0,0), so at its authored 12
// deg/s the brush sweeps ~797 units per second - about 80 units per tick.  The
// player's 96-unit aim trace lost it after a single frame, the claim was
// released, auto-return wound the fraction back, and holding +use moved the flag
// roughly half a unit before giving up.  All four of that map's buttons are
// built this way.
//
// So: rotate only when there is a real pivot to rotate about.  Nothing is lost
// on a pivotless button - it has no meaningful visual rotation to give, and on
// this map they are rendermode 5 with no renderamt, i.e. invisible in Half-Life
// too.  The FRACTION is the button's real output, and that is tracked either
// way, so the door and everything downstream behave identically.
void(entity btn, float frac) MomRotBtn_SetFrac =
{
    frac = bound(0, frac, 1);
    btn.momentary_frac = frac;
    if (btn.origin != '0 0 0')
    {
        btn.angles = btn.pos1 + btn.movedir * (btn.distance * frac);
        setorigin(btn, btn.origin);      // relink the rotated collision/bounds
    }
    btn.SendFlags = 1;
    MomRotBtn_DriveDoors(btn, frac);
};

// Advance the button by `dt` seconds of turning.
void(entity btn, float dt) MomRotBtn_AdvanceBy =
{
    if (btn.distance <= 0) return;
    if (dt <= 0)  dt = 0.013;
    if (dt > 0.1) dt = 0.1;
    float step = (btn.speed > 0 ? btn.speed : 50) * dt / btn.distance;
    MomRotBtn_SetFrac(btn, btn.momentary_frac + btn.momentary_dir * step);
};

// Advance the button while +use is held (called every server frame).
void(entity btn) MomRotBtn_Advance =
{
    MomRotBtn_AdvanceBy(btn, frametime);
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

// Triggered rather than held: one pulse advances the wheel by one tick's worth
// and arms the auto-return, so a multi_manager pulsing at 0.1 s drives it at the
// same rate a player's hands would.  Also the only way to exercise the whole
// button -> door -> trigger_setorigin chain without a pair of hands, which is
// what `sv_debug_firetarget` is for.
void() momentary_rot_button_use =
{
    if (self.spawnflags & MOMROT_DOORHACK)
        return;                                 // solid companion; not usable

    if (self.spawnflags & MOMROT_AUTORETURN)
        self.momentary_dir = 1;                 // only ever opens while pulsed
    else if (self.momentary_dir == 0)
        self.momentary_dir = 1;

    // A PULSE IS WORTH A TICK, not a frame.  Sven's documented cadence is one
    // trigger every 0.1 s, and Half-Life's own CMomentaryRotButton::UpdateSelf
    // sets avelocity and `nextthink = ltime + 0.1` per pulse - so a pulse buys
    // 0.1 s of rotation.  Charging it a frame instead would make remote control
    // several times slower than a pair of hands on the same wheel.
    MomRotBtn_AdvanceBy(self, 0.1);

    // Re-arm the return from scratch on every pulse: while the pulses keep
    // coming this think never gets to run, and when they stop it is what closes
    // the wheel again.
    if ((self.spawnflags & MOMROT_AUTORETURN) && self.enemy == world)
    {
        self.think     = MomRotBtn_ReturnTick;
        self.nextthink = self.ltime + Momentary_TickInterval() * 3;
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
            // Half-Life's own selection rule, and the only one that can work on
            // a non-solid brush: take every candidate within reach and keep the
            // one most centred in view.  CBasePlayer::PlayerUse does exactly
            // this (a 64-unit sphere ranked by DotProduct against v_forward)
            // and never traces - which is why a SOLID_NOT momentary_rot_button
            // is just as usable there as a solid one.
            float best = 0.6;
            entity e = momentary_button_list;
            while (e)
            {
                if (!(e.spawnflags & MOMROT_DOORHACK))
                {
                    // Measure to the NEAREST FACE of the brush, not to its
                    // centre.  Two reasons, and HL does the same thing
                    // (UTIL_ClampVectorToBox in CBasePlayer::PlayerUse):
                    //
                    //  - .origin is useless here.  A GoldSrc brush with no
                    //    ORIGIN brush has .origin '0 0 0', so anything ranked on
                    //    it points at the map origin and never passes the gate.
                    //  - a centre is nearly as bad on a LONG brush.  These
                    //    levers are 8x8x128 poles; stand beside the bottom of
                    //    one and its centre is 60 units over your head, so both
                    //    the range and the facing test answer about somewhere
                    //    you are not looking.
                    //
                    // Clamping the eye->centre vector by the box half-size walks
                    // it in to the closest point on the box, which is the thing
                    // the player is actually aiming at.
                    vector half = (e.absmax - e.absmin) * 0.5;
                    vector to_e = ((e.absmin + e.absmax) * 0.5) - start;
                    if      (to_e_x >  half_x) to_e_x = to_e_x - half_x;
                    else if (to_e_x < -half_x) to_e_x = to_e_x + half_x;
                    else                       to_e_x = 0;
                    if      (to_e_y >  half_y) to_e_y = to_e_y - half_y;
                    else if (to_e_y < -half_y) to_e_y = to_e_y + half_y;
                    else                       to_e_y = 0;
                    if      (to_e_z >  half_z) to_e_z = to_e_z - half_z;
                    else if (to_e_z < -half_z) to_e_z = to_e_z + half_z;
                    else                       to_e_z = 0;

                    float d = vlen(to_e);
                    if (d <= 96)
                    {
                        // Standing inside the brush counts as aiming at it, the
                        // way HL's normalize-of-zero does.
                        float dot = (d > 0) ? ((to_e * (1.0 / d)) * v_forward) : 1;
                        if (dot > best) { best = dot; btn = e; }
                    }
                }
                e = e.momentary_next;
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

            // The lever sound, on the rising edge of the grab.  It was resolved
            // and precached in the spawn function and then never played by
            // anything - the only sound() calls in this file belonged to
            // momentary_door and func_rot_button, so turning a wheel was silent.
            // HL emits it from CMomentaryRotButton::UpdateSelf under the same
            // `if (!m_lastUsed)` rising-edge test this branch is.
            if (btn.noise != "" && btn.noise != "common/null.wav")
                sound(btn, CHAN_VOICE, btn.noise, 1, ATTN_NORM);
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

    // NON-SOLID unless Door Hack, which is Half-Life's own rule:
    //
    //     if (pev->spawnflags & SF_MOMENTARY_DOOR) pev->solid = SOLID_BSP;
    //     else                                     pev->solid = SOLID_NOT;
    //                                          (buttons.cpp:947-950)
    //
    // SV_InitReplicatedSolidBrush forces SOLID_BSP for everything, which turned
    // desertcircle's four invisible lever brushes into collidable posts standing
    // at each flag pole - and, once one started turning, into a solid brush being
    // swept across the map at several hundred units a second.  solid_brush_
    // SendEntity converts .solid into the wire_nonsolid bit, so CSQC's prediction
    // stops colliding with it too; same route func_wall_toggle uses.
    //
    // This also puts the aim search on Half-Life's own footing.  HL never traces
    // for a use target at all - CBasePlayer::PlayerUse walks a 64-unit sphere
    // around the player and picks the best facing dot - so a non-solid button is
    // exactly as usable there as a solid one.  Here the tracebox in
    // Momentary_TickInteraction now always misses and the findradius cone below
    // it does the work, which is why that cone's ranking had to be fixed first.
    if (!(self.spawnflags & MOMROT_DOORHACK))
        self.solid = SOLID_NOT;

    // findradius would skip us now that we are SOLID_NOT, so join the list the
    // aim search actually walks.  FL_FINDABLE_NONSOLID as well, so anything else
    // that reasonably expects to findradius a usable brush still can.
    self.flags            = self.flags | FL_FINDABLE_NONSOLID;
    self.momentary_next   = momentary_button_list;
    momentary_button_list = self;

    Momentary_AxisSetup();
    self.pos1 = self.angles;                       // closed angles
    self.pos2 = self.pos1 + self.movedir * self.distance;  // open angles
    self.momentary_frac = 0;
    self.momentary_dir  = 0;

    // REMOTE CONTROL, which Sven documents and this class never had: "you can
    // remote control a momentary_rot_button by triggering it in 0.1 s intervals.
    // For auto-returning buttons it will only move towards the open position
    // while being triggered, and return towards its closed position when the
    // trigger pulse ceases."  One fire is worth one tick of held use, which is
    // exactly what that cadence implies.
    self.use = momentary_rot_button_use;

    // Door Hack: solid but NOT directly usable — a placed companion that the
    // (intentionally unimplemented) multi-button sync would drive.  It just
    // sits there solid; the primary button drives the door.  No .use so the
    // held-+use poll skips it.  Non-DoorHack buttons are driven entirely by
    // Momentary_TickInteraction, so they also get no one-shot .use.
};
