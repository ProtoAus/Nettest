//
//  sv_doors.qc  –  shared door/button helpers + sliding func_door
//
//  This file owns the cross-entity helpers consumed by sv_buttons.qc,
//  sv_doors_rotating.qc, sv_trigger_hurt.qc and sv_trigger_gravity.qc:
//   - HL/GoldSrc sound-lookup tables (Door_Lookup{Move,Stop,Locked,Unlocked}Sound,
//     Button_LookupSound, Door_PrecacheIfReal)
//   - Generic Mover_Start (linear translation)
//   - Trigger_UseTargets (target-chain firing helper)
//   - Shared field declarations (.float dmg, .float movesnd, .string noise_locked, ...)
//
//  Then it implements the sliding `func_door` itself.  Rotating doors,
//  buttons and trigger_hurt / trigger_gravity each live in their own
//  file under server/.
//
//  Compile order in sv_progs.src: this file MUST load before the
//  per-entity files because they extern its helpers.
//

// Forward decls — sh_pmove.qc compiles AFTER this file in sv_progs.src,
// so the moving-brush list helpers it defines need to be predeclared
// here for Mover_Start / Mover_TravelTick to reference them.
void(entity c) MovingBrush_AddToList;
void(entity c) MovingBrush_RemoveFromList;

// Geometry-aware per-tick push for doors + buttons.  Defined in
// sv_platform_carry.qc (compiles after us in sv_progs.src).  Uses
// the PM_TRIGGER_PROBE_DIM dimension-bit trick to confirm the
// player's bbox actually intersects this brush's BSP geometry —
// not just the AABB — before pushing.  Replaces the old bbox-
// overlap Mover_PushPlayers loop so doors push by mesh, not by
// trigger-box.  On wedge it invokes self.blocked() (door_blocked
// applies dmg + reverses, or grinds on UNBLOCKABLE).
float() Mover_GeometryBlockPush;

// Stand-on-top platform carry — players whose feet trace down to
// this brush get locked 1:1 to the brush's per-tick translation.
// Also handles the "rode the brush into a wall" case: trace fails,
// player stops at the wall, brush keeps moving past them.  Lives
// in sv_platform_carry.qc alongside the geometry push.
float() Mover_PlatformCarry;

// ============================================================================
//  Shared helpers
// ============================================================================

// HL/GoldSrc map keys for door + button sound selection.
//   movesnd / stopsnd      — door open / close sound pair (index → WAV).
//   locked_sound / unlocked_sound — feedback when an entity is in
//     locked / unlocked state.  Currently precached + reachable via
//     self.noise_locked / self.noise_unlocked but the door's
//     "locked" state machine isn't fully wired yet — mappers can
//     set them and the resolved string will be on the entity for
//     future hooks.
.float movesnd;
.float stopsnd;
.float locked_sound;
.float unlocked_sound;
.string noise_locked;
.string noise_unlocked;

void() SetMovedir;   // defined in sv_push.qc

// useType pass-through globals — the GoldSrc trigger suite (sv_triggers.qc
// and the per-entity files compiled after it) sets these before each
// .use() call to communicate USE_OFF / USE_ON / USE_TOGGLE semantics and
// the firing entity (multisource needs the caller to dedupe inputs).
// Default sub_use_type=0 falls back to USE_TOGGLE inside the loop below
// — preserves behaviour for legacy callers (button / breakable / etc.)
// that don't know about useType yet.
float  sub_use_type;       // declared here so sv_doors.qc compiles standalone
entity sub_use_caller;
const float USE_OFF    = 0;
const float USE_ON     = 1;
const float USE_SET    = 2;
const float USE_TOGGLE = 3;

void(entity caller, entity triggerer) Trigger_UseTargets =
{
    entity target_entity;
    entity oldself;
    entity oldactivator;
    entity oldcaller;
    float  oldusetype;
    float  olddirect;

    if (!caller.target)
        return;

    oldactivator = activator;
    oldcaller    = sub_use_caller;
    oldusetype   = sub_use_type;
    olddirect    = sv_use_is_player_direct;
    activator    = triggerer;

    // The targets fired by this chain are activated INDIRECTLY (the
    // caller is some other entity, not a player +use trace), so the
    // "is this a direct player +use?" flag must be FALSE for them
    // regardless of whether the chain was kicked off by a player.
    // Without this, a button's synchronous fire (BUTTON_DONT_MOVE
    // routes button_wait → Trigger_UseTargets directly inside
    // SV_PlayerTryUse where the flag is still TRUE) makes the
    // door's USE_ABLE gate reject the activation.
    sv_use_is_player_direct = FALSE;

    // Default useType for legacy callers — they invoke this two-arg
    // form without setting sub_use_type, so treat as toggle (the HL
    // default for SUB_UseTargets).
    if (sub_use_type == 0)
        sub_use_type = USE_TOGGLE;

    target_entity = find(world, targetname, caller.target);
    float dbg = cvar("sv_debug_use");
    while (target_entity)
    {
        if (target_entity != caller && target_entity.use)
        {
            if (dbg)
            {
                print(sprintf("[chain] %s(\"%s\") -> %s(\"%s\")  useType=%g\n",
                              caller.classname, caller.targetname,
                              target_entity.classname, target_entity.targetname,
                              sub_use_type));
            }
            oldself = self;
            self = target_entity;
            sub_use_caller = caller;     // multisource reads this
            self.use();
            self = oldself;
        }
        target_entity = find(target_entity, targetname, caller.target);
    }

    activator               = oldactivator;
    sub_use_caller          = oldcaller;
    sub_use_type            = oldusetype;
    sv_use_is_player_direct = olddirect;
};

// ============================================================================
//  HL/GoldSrc sound lookup tables — shared by func_door, func_door_rotating
//  and func_button.  Map keys movesnd / stopsnd / locked_sound /
//  unlocked_sound (and func_button's `sounds`) carry small integer
//  indices that resolve to specific WAV paths in sound/doors/ and
//  sound/buttons/.  Values 0 always map to common/null.wav (silence).
//  Unknown indices fall back to silence so a typo doesn't crash on
//  precache_sound("").
// ============================================================================

string(float idx) Door_LookupMoveSound =
{
    if (idx == 1)  return "doors/doormove1.wav";
    if (idx == 2)  return "doors/doormove2.wav";
    if (idx == 3)  return "doors/doormove3.wav";
    if (idx == 4)  return "doors/doormove4.wav";
    if (idx == 5)  return "doors/doormove5.wav";
    if (idx == 6)  return "doors/doormove6.wav";
    if (idx == 7)  return "doors/doormove7.wav";
    if (idx == 8)  return "doors/doormove8.wav";
    if (idx == 9)  return "doors/doormove9.wav";
    if (idx == 10) return "doors/doormove10.wav";
    return "common/null.wav";
};

string(float idx) Door_LookupStopSound =
{
    if (idx == 1) return "doors/doorstop1.wav";
    if (idx == 2) return "doors/doorstop2.wav";
    if (idx == 3) return "doors/doorstop3.wav";
    if (idx == 4) return "doors/doorstop4.wav";
    if (idx == 5) return "doors/doorstop5.wav";
    if (idx == 6) return "doors/doorstop6.wav";
    if (idx == 7) return "doors/doorstop7.wav";
    if (idx == 8) return "doors/doorstop8.wav";
    return "common/null.wav";
};

string(float idx) Door_LookupLockedSound =
{
    if (idx == 2)  return "buttons/button2.wav";
    if (idx == 8)  return "buttons/button8.wav";
    if (idx == 10) return "buttons/button10.wav";
    if (idx == 11) return "buttons/button11.wav";
    if (idx == 12) return "buttons/latchlocked1.wav";
    return "common/null.wav";
};

string(float idx) Door_LookupUnlockedSound =
{
    if (idx == 1)  return "buttons/button1.wav";
    if (idx == 3)  return "buttons/button3.wav";
    if (idx == 4)  return "buttons/button4.wav";
    if (idx == 5)  return "buttons/button5.wav";
    if (idx == 6)  return "buttons/button6.wav";
    if (idx == 7)  return "buttons/button7.wav";
    if (idx == 8)  return "buttons/button8.wav";
    if (idx == 9)  return "buttons/button9.wav";
    if (idx == 10) return "buttons/button10.wav";
    if (idx == 13) return "buttons/latchunlocked1.wav";
    if (idx == 14) return "buttons/lightswitch2.wav";
    return "common/null.wav";
};

// func_button's `sounds` key uses the GoldSrc button index space
// (subset of the unlocked-sound table plus a couple of extras).
string(float idx) Button_LookupSound =
{
    if (idx == 1)  return "buttons/button1.wav";
    if (idx == 2)  return "buttons/button2.wav";
    if (idx == 3)  return "buttons/button3.wav";
    if (idx == 4)  return "buttons/button4.wav";
    if (idx == 5)  return "buttons/button5.wav";
    if (idx == 6)  return "buttons/button6.wav";
    if (idx == 7)  return "buttons/button7.wav";
    if (idx == 8)  return "buttons/button8.wav";
    if (idx == 9)  return "buttons/button9.wav";
    if (idx == 10) return "buttons/button10.wav";
    if (idx == 11) return "buttons/button11.wav";
    if (idx == 14) return "buttons/lightswitch2.wav";
    return "common/null.wav";
};

// Helper: precache a sound only if it's a real path (lookup returns
// "common/null.wav" for the silence sentinel so let the engine
// dedup-precache that one).
void(string snd) Door_PrecacheIfReal =
{
    if (snd != "" && snd != __NULL__)
        precache_sound(snd);
};

float(string snd) Door_IsSilentSound =
{
    if (snd == "" || snd == __NULL__)
        return TRUE;
    if (snd == "common/null.wav" || snd == "misc/null.wav" || snd == "sounds/null.wav")
        return TRUE;
    return FALSE;
};

void() Door_StopMoveSound =
{
    // Cut the current door movement sound on CHAN_VOICE.  This matters
    // for loop-cued GoldSrc movement WAVs: if there is no stop sound to
    // replace the channel, the loop can otherwise continue after the
    // brush has arrived.
    sound(self, CHAN_VOICE, "", 0, ATTN_NORM);
};

void() Door_PlayMoveSound =
{
    if (!Door_IsSilentSound(self.noise2))
        sound(self, CHAN_VOICE, self.noise2, 1, ATTN_NORM);
};

void() Door_PlayStopSound =
{
    Door_StopMoveSound();
    if (!Door_IsSilentSound(self.noise1))
        sound(self, CHAN_VOICE, self.noise1, 1, ATTN_NORM);
};

// ============================================================================
//  Generic mover  –  velocity-based movement toward a destination
//  Sets SendFlags so the CSQC entity gets the updated position + velocity.
// ============================================================================

// Per-mover state for the per-tick travel think — required because
// players use MOVETYPE_NONE (custom pmove), and the engine's
// WPhys_Push explicitly skips MOVETYPE_NONE entities (sv_phys.c:754-758).
// That means a sliding door phases right through the player and
// .blocked never fires.  We now run an authoritative QC push pass at
// sv_func_tickrate during travel; these fields hold the destination
// we're heading to and the move_done callback to fire once we arrive.
.vector mover_dest;
.void() mover_done_cb;
// Snapshot of the velocity the door starts moving at, captured by
// Mover_Start.  Used by the arrival check for per-tick distance
// (self.velocity may equal this throughout transit since the door
// no longer pauses on block) and by sv_platform_carry.qc's
// geometry-push direction fallback for the unlikely case where
// .blocked side-effects zeroed self.velocity briefly.
.vector mover_planned_velocity;

// Per-tick travel think — runs at sv_func_tickrate during the move.
// Two passes:
//
//   1. Mover_PlatformCarry  — players standing ON TOP ride the brush.
//                             If their swept path is partially
//                             blocked (e.g. wall in front), they
//                             stop at the wall and the brush slides
//                             past underneath; eventually the brush
//                             no longer covers their feet and they
//                             fall off the back.  Door does NOT
//                             pause for a stuck passenger — that's
//                             the desired "platform slid out from
//                             under me" behaviour.
//   2. Mover_GeometryBlockPush — players whose bbox actually
//                             intersects the brush BSP get slid one
//                             tick along velocity.  If wedged, the
//                             brush's .blocked callback fires
//                             (damage + reverse-or-grind per the
//                             door's spawnflags).
//
// Wedge-detected pause: when geometry push wedges, the door's
// velocity is zeroed for this tick UNLESS .blocked reversed the
// door's direction.  We detect reversal by sign-checking the
// velocity (.blocked → door_go_down/up → Mover_Start writes a new
// velocity in the opposite direction).  Result:
//
//   - Default door wedge → .blocked reverses → velocity flips →
//     no pause → door opens cleanly, one-shot dmg applied.
//   - UNBLOCKABLE wedge → .blocked just damages, velocity unchanged
//     → pause kicks in → door stops at the player's head, damage
//     per tick until the player dies or moves out.
//
// Engine MOVETYPE_PUSH skips MOVETYPE_NONE players so it doesn't
// fire .blocked itself; this QC path is the only way to detect
// the crush and apply damage.  Pause keeps the door visually
// stopped at the wedge instead of phasing through.
void() Mover_TravelTick =
{
    Mover_PlatformCarry();

    // Capture velocity before geometry push so we can detect
    // whether .blocked reversed the door (reverse → planned_velocity
    // changes → no pause needed) vs. no-reverse UNBLOCKABLE
    // (planned_velocity unchanged → pause needed).  Substitute
    // planned_velocity when self.velocity is 0 (paused last tick)
    // so a continued wedge still compares meaningfully.
    vector pre_velocity = self.velocity;
    if (pre_velocity == '0 0 0')
        pre_velocity = self.mover_planned_velocity;
    float wedged = Mover_GeometryBlockPush();

    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = 40;
    if (hz > 200)  hz = 200;
    float tick_dt = 1.0 / hz;

    if (wedged)
    {
        // Did .blocked reverse direction?  Reverse → planned_velocity
        // got rewritten by Mover_Start.  No-reverse (UNBLOCKABLE) →
        // planned_velocity unchanged; we pause velocity for this tick
        // so the engine doesn't keep advancing the door through the
        // wedged player while we damage them per tick.  This is the
        // user-requested "stop at my head and damage me" behaviour
        // for crusher doors.
        if (self.mover_planned_velocity == pre_velocity)
        {
            // First wedge tick after motion: backing off here is
            // now unnecessary since the geometry helper looks AHEAD
            // (the brush hasn't entered the player yet — we pause
            // before the next engine integration).  Keep velocity 0
            // so the engine doesn't advance into the player.
            if (self.velocity != '0 0 0')
            {
                self.velocity  = '0 0 0';
                self.SendFlags = 1;
            }
            if (cvar("sv_debug_doors"))
                dprint(sprintf("[door %s] tick: PAUSE (wedge ahead, no reverse)\n",
                               self.targetname));
        }
        else
        {
            // Reverse fired — sync engine velocity to the new planned
            // direction so motion resumes immediately.
            if (self.velocity != self.mover_planned_velocity)
            {
                self.velocity  = self.mover_planned_velocity;
                self.SendFlags = 1;
            }
            if (cvar("sv_debug_doors"))
                dprint(sprintf("[door %s] tick: REVERSED, velocity now %v\n",
                               self.targetname, self.velocity));
        }
    }
    else
    {
        // Wedge cleared (player walked away, died, or was never
        // wedged).  Restore velocity from plan so a previously
        // paused door resumes closing.
        if (self.velocity != self.mover_planned_velocity)
        {
            self.velocity  = self.mover_planned_velocity;
            self.SendFlags = 1;
        }
    }

    // Have we arrived?  Use the PLANNED speed for the per-tick distance
    // — current velocity is 0 while paused for a wedge and would
    // otherwise falsely register arrival.  Skip arrival while paused
    // so the door doesn't snap past a wedged player.
    float dist_remaining = vlen(self.mover_dest - self.origin);
    float per_tick = vlen(self.mover_planned_velocity) * tick_dt;
    if (!wedged && dist_remaining <= per_tick + 0.5)
    {
        // Arrival snap.  Mover_PlatformCarry already ran at the top of
        // this tick with platform_prev_origin = previous tick's origin,
        // so carried players got the engine-integrated delta but NOT
        // the snap delta about to be applied below.  Without the snap
        // fixup, players riding a door that lines up with an adjacent
        // floor end up ~0.5-2u above the floor — they "float", the
        // client-side pmove sees no ground in its 4u down-trace and
        // predicts a fall, server snaps them back via reconcile every
        // snapshot.  Capture the snap delta and apply it to every
        // currently-carried player so they land cleanly.
        vector pre_snap_origin = self.origin;
        setorigin(self, self.mover_dest);
        vector snap_delta = self.mover_dest - pre_snap_origin;
        if (snap_delta != '0 0 0')
        {
            entity p = find(world, classname, "player");
            while (p)
            {
                if (p.platform_carry == self)
                    setorigin(p, p.origin + snap_delta);
                p = find(p, classname, "player");
            }
        }
        self.velocity = '0 0 0';
        self.SendFlags = 1;
        // Drop out of the linear-motion list now that we're idle —
        // client predict pass should stop pushing players against
        // this brush.
        MovingBrush_RemoveFromList(self);
        void() cb = self.mover_done_cb;
        self.mover_done_cb = __NULL__;
        if (cb) cb();
        return;
    }

    self.nextthink = self.ltime + tick_dt;
};

void(vector destination, float move_speed, void() move_done) Mover_Start =
{
    vector delta;
    float  distance;
    float  travel_time;

    delta    = destination - self.origin;
    distance = vlen(delta);

    if (distance <= 0 || move_speed <= 0)
    {
        setorigin(self, destination);
        self.velocity              = '0 0 0';
        self.mover_planned_velocity = '0 0 0';
        self.SendFlags             = 1;
        move_done();
        return;
    }

    travel_time                = distance / move_speed;
    self.velocity              = delta * (1.0 / travel_time);
    self.mover_planned_velocity = self.velocity;   // remembered so Mover_TravelTick can pause/resume on blocking
    self.SendFlags             = 1;   // tell CSQC: new origin + velocity

    // Per-tick travel think replaces the previous one-shot move_done
    // at travel_time end.  Engine still integrates self.origin via
    // velocity each physics tick (MOVETYPE_PUSH); our think just
    // pushes players in the path and decides when we've arrived.
    self.mover_dest    = destination;
    self.mover_done_cb = move_done;
    self.think         = Mover_TravelTick;

    // Publish into the shared moving-brush list so PM_CheckMovingPushers
    // mirrors the server's push pass on the client during travel.
    // Mover_TravelTick removes the entry once we arrive.
    MovingBrush_AddToList(self);

    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)   hz = 40;
    if (hz > 200)  hz = 200;
    self.nextthink = self.ltime + 1.0 / hz;
};

// ============================================================================
//  func_door  (sliding)
// ============================================================================

// Spawnflags
//   1   — START_OPEN: spawn pre-opened.  Auto-closes after `wait`
//          seconds unless TOGGLE/ONE_MOVEMENT pin it open.  Resets
//          to open at every round restart.
//   2   — USE_ABLE (default ON in maps): direct +use opens the door.
//          Off → only target activation / damage / proximity is
//          rejected too — the door is purely externally driven.
//   4   — UNBLOCKABLE: when something blocks the close, the door
//          does NOT reverse — it keeps trying to close.  Combined
//          with `dmg`, this becomes a continuous crusher.
//   8   — PASS_THROUGH: door is non-solid (SOLID_NOT) — visible but
//          walk-through.  No proximity trigger spawned.
//   16  — ONE_MOVEMENT: door can activate exactly once per round.
//          Auto-return is suppressed.  Combined with `health`, this
//          gives the "shoot once to open, stays open" behaviour.
//   32  — TOGGLE: each press toggles state; no auto-close.
//   256 — USE_ONLY: target activation is rejected.  Damage path and
//          direct +use still work.
const float DOOR_START_OPEN     = 1;
const float DOOR_USE_ABLE       = 2;
const float DOOR_UNBLOCKABLE    = 4;
const float DOOR_PASS_THROUGH   = 8;
const float DOOR_ONE_MOVEMENT   = 16;
const float DOOR_TOGGLE         = 32;
const float DOOR_USE_ONLY       = 256;

float DOOR_STATE_BOTTOM = 0;
float DOOR_STATE_UP     = 1;
float DOOR_STATE_TOP    = 2;
float DOOR_STATE_DOWN   = 3;

float DOOR_TRIGGER_PAD_XY = 60;
float DOOR_TRIGGER_PAD_Z  = 8;

float door_group_mark_serial;

// ONE_MOVEMENT latch — set when a door first activates this round,
// cleared by Door_RoundReset.  While set, door_use / door_use_force
// short-circuit so the door cannot re-activate until the next round.
.float door_movement_done;
// Block damage carried on the door entity itself — set from the
// mapper's "dmg" key.  Read by door_blocked.
.float dmg;

float(entity attacker, entity target, float damage) W_ApplyDamage;  // sv_weapons.qc
void() SV_InitReplicatedSolidBrush;                                // sv_brushsync.qc

void() door_go_up;
void() door_go_down;
void() door_use_force;

void() door_hit_bottom =
{
    setorigin(self, self.pos1);
    self.velocity    = '0 0 0';
    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;
    self.SendFlags   = 1;
    Door_PlayStopSound();
};

void() door_go_down =
{
    if (self.door_state == DOOR_STATE_BOTTOM || self.door_state == DOOR_STATE_DOWN)
        return;
    self.door_state  = DOOR_STATE_DOWN;
    self.mover_state = MOVER_STATE_DOWN;
    Door_PlayMoveSound();
    Mover_Start(self.pos1, self.speed, door_hit_bottom);
};

void() door_hit_top =
{
    setorigin(self, self.pos2);
    self.velocity    = '0 0 0';
    self.door_state  = DOOR_STATE_TOP;
    self.mover_state = MOVER_STATE_TOP;
    self.SendFlags   = 1;
    Door_PlayStopSound();
    // TOGGLE / ONE_MOVEMENT / wait<0 all suppress the auto-return.
    // ONE_MOVEMENT is the "stays open this round" semantic — even
    // damage-driven opens latch into this state until Door_RoundReset
    // clears the door_movement_done flag.
    if ((self.spawnflags & DOOR_TOGGLE) || self.wait < 0)
        return;
    if (self.spawnflags & DOOR_ONE_MOVEMENT)
        return;
    self.nextthink = self.ltime + self.wait;
    self.think     = door_go_down;
};

void() door_go_up =
{
    if (self.door_state == DOOR_STATE_TOP)
    {
        if (!(self.spawnflags & DOOR_TOGGLE) && self.wait >= 0)
        {
            self.nextthink = self.ltime + self.wait;
            self.think     = door_go_down;
        }
        return;
    }
    if (self.door_state == DOOR_STATE_UP)
        return;
    self.door_state  = DOOR_STATE_UP;
    self.mover_state = MOVER_STATE_UP;
    Door_PlayMoveSound();
    Mover_Start(self.pos2, self.speed, door_hit_top);
};

void() door_blocked =
{
    // Player blocker: try a slide-along-movedir push BEFORE the
    // `dmg` + reverse path runs.  Engine has already reverted door
    // origin for this tick (sv_phys.c:1068).  If we successfully
    // push the player out of the door's path, the door integrates
    // cleanly next tick — feels like the door "shoves" the player
    // along its motion instead of just reversing or grinding them.
    // If the push fails (player wedged against a wall), fall through
    // Apply block damage to the obstruction if `dmg` is set.
    //
    // Earlier versions tried a "movedir slide" first — teleport the
    // player along self.movedir (the door's OPEN direction) to nudge
    // them out of the closing brush's path before applying dmg.  In
    // practice this teleported the player INTO the descending door:
    // movedir for an up-opening door is UP, the player is BELOW the
    // closing brush, slide_dist = UP*9 pushes them upward through
    // the door's volume.  Each "successful" slide moved the player
    // deeper inside the bbox until they couldn't move any further;
    // by then the look-ahead probe found the player inside the
    // brush regardless of which direction the door was travelling,
    // and the reverse-on-block path entered an infinite oscillation
    // (close → wedge → reverse → wedge → reverse → ...).  The
    // look-ahead helper in sv_platform_carry.qc already prevents
    // the door from entering the player's bbox in the first place,
    // so the slide is both unnecessary and harmful — gone now.  No
    // takedamage gate — W_CanDamageTarget unconditionally accepts
    // targets with classname=="player" regardless of their
    // .takedamage field (which players have at 0 / DAMAGE_NO in
    // this mod because we never call SetTakedamage on them).
    // Skipping the W_ApplyDamage call on the takedamage check would
    // turn this into a no-op for every player block — i.e. the
    // "door crushes me but I don't take damage" bug.
    if (self.dmg > 0 && other != world)
    {
        if (cvar("sv_debug_doors"))
            dprint(sprintf("[door %s] blocked: applying %g dmg to %s\n",
                           self.targetname, self.dmg, other.netname));
        W_ApplyDamage(self, other, self.dmg);
    }

    // UNBLOCKABLE: don't reverse — engine keeps attempting the close
    // and the dmg above keeps killing whatever's stuck.
    if (self.spawnflags & DOOR_UNBLOCKABLE)
    {
        if (cvar("sv_debug_doors"))
            dprint(sprintf("[door %s] blocked: UNBLOCKABLE, no reverse\n",
                           self.targetname));
        return;
    }

    // Default: reverse direction so the blocker can free themselves
    // and the close fails gracefully.
    if (cvar("sv_debug_doors"))
        dprint(sprintf("[door %s] blocked: reversing\n", self.targetname));
    if (self.door_state == DOOR_STATE_UP || self.door_state == DOOR_STATE_TOP)
        door_go_down();
    else
        door_go_up();
};

// ---- door group activation ----

// Adjacency / groupname-based linking is unchanged from the prior
// implementation — only the legacy DOOR_DONT_LINK opt-out (bit 4)
// was dropped because that bit is now UNBLOCKABLE.  Mappers that need
// to keep adjacent doors independent should use distinct `groupname`
// keys instead.
float(entity d1, entity d2) Door_ShouldLink =
{
    if (d1 == d2)                                              return FALSE;
    if (d1.groupname && d1.groupname[0])
        return (d2.groupname == d1.groupname);
    if (d2.groupname && d2.groupname[0])                       return FALSE;
    if (d1.cmins_x > d2.cmaxs_x || d1.cmaxs_x < d2.cmins_x) return FALSE;
    if (d1.cmins_y > d2.cmaxs_y || d1.cmaxs_y < d2.cmins_y) return FALSE;
    if (d1.cmins_z > d2.cmaxs_z || d1.cmaxs_z < d2.cmins_z) return FALSE;
    return TRUE;
};

void(entity door) Door_ActivateSingle =
{
    entity oldself;
    door.attack_finished = time + 0.1;
    oldself = self;
    if ((door.spawnflags & DOOR_TOGGLE) && (door.door_state == DOOR_STATE_UP || door.door_state == DOOR_STATE_TOP))
    {
        self = door; door_go_down(); self = oldself;
        return;
    }
    self = door; door_go_up(); self = oldself;
};

void(entity seed) Door_OpenGroup =
{
    entity nextdoor;
    if (seed.door_mark == door_group_mark_serial)
        return;
    seed.door_mark = door_group_mark_serial;
    Door_ActivateSingle(seed);
    nextdoor = find(world, classname, "func_door");
    while (nextdoor)
    {
        if (nextdoor.door_mark != door_group_mark_serial && Door_ShouldLink(seed, nextdoor))
            Door_OpenGroup(nextdoor);
        nextdoor = find(nextdoor, classname, "func_door");
    }
};

void() door_use =
{
    // mp_disabledoors live admin gate (also applies to door_use_force).
    if (cvar("mp_disabledoors")) return;

    // USE_ABLE controls whether direct +use opens the door.  Off →
    // a player +using the door does nothing; the door must be
    // opened externally (target trigger, damage, proximity).  We
    // detect "direct +use" via sv_use_is_player_direct, the same
    // flag the use system already maintains for sv_use.qc.
    if (sv_use_is_player_direct && !(self.spawnflags & DOOR_USE_ABLE))
        return;

    // USE_ONLY rejects target-trigger fires.  When set, the door
    // can only be opened by direct +use (or damage).  Mirrors the
    // FGD label "Use Only" — the door is intentionally isolated
    // from external trigger chains.
    if (!sv_use_is_player_direct && (self.spawnflags & DOOR_USE_ONLY))
        return;

    // ONE_MOVEMENT latch — already activated this round.
    if (self.door_movement_done)
        return;

    if (self.attack_finished > time)
        return;
    self.attack_finished = time + 0.1;

    // Mark the latch BEFORE the group walk so linked doors don't
    // each re-mark their own (and so a re-press during the open
    // animation doesn't slip past).
    if (self.spawnflags & DOOR_ONE_MOVEMENT)
        self.door_movement_done = 1;

    Trigger_UseTargets(self, activator);
    door_group_mark_serial = door_group_mark_serial + 1;
    if (door_group_mark_serial <= 0) door_group_mark_serial = 1;
    Door_OpenGroup(self);
};

// Damage-driven open path.  Called by door_killed (on_killed callback
// when self.health drops to zero from gunfire).  Bypasses USE_ABLE /
// USE_ONLY because damage is a separate activation channel — a door
// flagged "no +use, no target" can still be shot open if it has
// health.  ONE_MOVEMENT and mp_disabledoors still apply.
void() door_use_force =
{
    if (cvar("mp_disabledoors")) return;
    if (self.door_movement_done) return;
    if (self.attack_finished > time) return;
    self.attack_finished = time + 0.1;

    if (self.spawnflags & DOOR_ONE_MOVEMENT)
        self.door_movement_done = 1;

    Trigger_UseTargets(self, activator);
    door_group_mark_serial = door_group_mark_serial + 1;
    if (door_group_mark_serial <= 0) door_group_mark_serial = 1;
    Door_OpenGroup(self);
};

// on_killed callback — the door's `health` reached zero from
// gunfire.  Re-arms the door for next-round use unless
// ONE_MOVEMENT pinned it open this round.
void() door_killed =
{
    activator = self.dmg_inflictor;     // shooter for kill credit / target chain

    if (self.spawnflags & DOOR_ONE_MOVEMENT)
    {
        // Stop accepting damage — extra shots after the open are
        // wasted, and leaving takedamage on would let the kill
        // fire repeatedly during the same frame.
        self.takedamage = DAMAGE_NO;
    }
    else
    {
        // Re-arm so the door can be shot open again on its next
        // close cycle.
        self.health = self.max_health;
    }

    door_use_force();
};

void() door_trigger_touch =
{
    entity oldself, oldactivator;
    if (other.classname != "player")
        return;
    // Treat proximity-touch the same as direct +use for gate
    // purposes — USE_ABLE off means the door is purely externally
    // driven and doesn't fire on player approach either.
    if (!(self.owner.spawnflags & DOOR_USE_ABLE))
        return;
    oldself = self; oldactivator = activator;
    activator = other;
    self = self.owner;
    door_use();
    self = oldself; activator = oldactivator;
};

void() door_spawn_trigger =
{
    entity trigger;
    vector center, mins, maxs;
    center  = (self.cmins + self.cmaxs) * 0.5;
    mins    = self.cmins - center - [DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_Z];
    maxs    = self.cmaxs - center + [DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_XY, DOOR_TRIGGER_PAD_Z];
    trigger = spawn();
    setorigin(trigger, center);
    setsize(trigger, mins, maxs);
    trigger.movetype = MOVETYPE_NONE;
    trigger.solid    = SOLID_TRIGGER;
    trigger.owner    = self;
    trigger.touch    = door_trigger_touch;
};

/*QUAKED func_door (0 .5 .8) ? START_OPEN USE_ABLE UNBLOCKABLE PASS_THROUGH ONE_MOVEMENT TOGGLE x x TOUCH x x USE_ONLY
Moving brush door.

START_OPEN (1):    spawns pre-opened, auto-closes after `wait`.
USE_ABLE (2):      direct +use opens it (default — leave on for
                    standard doors; off makes the door purely
                    externally driven via target/damage).
UNBLOCKABLE (4):   blocked closes do NOT reverse — combined with
                    `dmg`, becomes a continuous crusher.
PASS_THROUGH (8):  brush is non-solid; players walk through it.
ONE_MOVEMENT (16): one activation per round; with `health` lets you
                    shoot it open and have it stay open.
TOGGLE (32):       each press flips state; no auto-close.
USE_ONLY (256):    target-trigger activation rejected; +use / damage
                    only.

"angle"      opening direction
"target"     entities to fire when opened
"targetname" if set, no auto trigger is spawned; activate via use/target/damage
"speed"      movement speed (default 100)
"wait"       seconds before closing (default 3, -1 = stay open)
"lip"        remaining lip at end of move (default 8)
"distance"   explicit move distance (overrides lip calc)
"groupname"  link doors with the same name into one group
"sounds"     0=silent 1=stone 2=base 3=chain 4=metal
"dmg"        block damage (0 = no crush damage)
"health"     shootable threshold; door opens when health hits 0
*/
void() func_door =
{
    vector swap_pos;

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

    // GoldSrc movesnd / stopsnd / locked_sound / unlocked_sound
    // override the legacy `sounds` preset pair when set.  These map
    // through the Door_Lookup* tables to specific WAVs and are
    // precached unconditionally — common/null.wav is the silence
    // sentinel for index 0 / unknown values.
    if (self.movesnd > 0)        self.noise2        = Door_LookupMoveSound(self.movesnd);
    if (self.stopsnd > 0)        self.noise1        = Door_LookupStopSound(self.stopsnd);
    if (self.locked_sound > 0)   self.noise_locked  = Door_LookupLockedSound(self.locked_sound);
    if (self.unlocked_sound > 0) self.noise_unlocked = Door_LookupUnlockedSound(self.unlocked_sound);

    Door_PrecacheIfReal(self.noise1);
    Door_PrecacheIfReal(self.noise2);
    Door_PrecacheIfReal(self.noise_locked);
    Door_PrecacheIfReal(self.noise_unlocked);

    if (!self.speed) self.speed = 100;
    if (!self.wait)  self.wait  = 3;
    // lip defaults to 0 (door opens its full width).  The earlier
    // default of 8 was inherited from old Q1 func_door but felt
    // wrong on small doorways — the door would visibly hang into
    // the frame after opening.  Mappers who want a partial-open
    // can still set lip explicitly.
    // dmg defaults to 2 per blocked tick (HL CBaseDoor parity).
    // Without this, doors with UNBLOCKABLE never killed the
    // wedged player and they got stuck inside the brush forever.
    // Default-doors mostly never apply damage anyway because
    // door_blocked reverses on first block (one-shot 2 dmg nudge
    // before the open phase starts).
    if (!self.dmg)   self.dmg   = 2;

    SV_InitReplicatedSolidBrush();
    self.brush_type  = BRUSH_TYPE_DOOR;
    self.blocked = door_blocked;
    self.use     = door_use;
    self.pos1    = self.origin;

    // PASS_THROUGH: visible-but-walkable.  SOLID_NOT skips the engine's
    // collision tests entirely (including bullets); mappers wanting a
    // pass-through-to-players-but-bullet-stop should add a separate
    // clip brush.  We still keep MOVETYPE_PUSH so the door animates.
    if (self.spawnflags & DOOR_PASS_THROUGH)
        self.solid = SOLID_NOT;

    // Shootable doors — `health` lets gunfire trigger an open via the
    // standard on_killed callback, the same path func_breakable uses.
    // door_killed re-arms (or latches, with ONE_MOVEMENT) appropriately.
    if (self.health)
    {
        self.max_health  = self.health;
        self.takedamage  = DAMAGE_YES;
        self.on_killed   = door_killed;
    }

    if (self.movedir != '0 0 0')
    {
        self.pos2   = self.pos1 + self.movedir;
        self.angles = '0 0 0';
    }
    else if (self.mangle != '0 0 0')
    {
        if (!self.distance) self.distance = 64;
        makevectors(self.mangle);
        self.movedir = v_forward;
        self.pos2    = self.pos1 + self.movedir * self.distance;
    }
    else
    {
        // No Q1 "auto-default to UP if angles are zero" here — that
        // legacy fallback silently rewrote angles 0 0 0 to 0 -1 0
        // (Quake's "up" sentinel) which broke HL-style horizontal
        // doors that explicitly use angles 0 0 0 to mean +X movement.
        // Mappers wanting a vertical door must set angles '0 -1 0'
        // (up) or '0 -2 0' (down) explicitly — same convention HL,
        // CS and the rest of the codebase already use.  SetMovedir
        // honours those special vectors and otherwise calls
        // makevectors(angles) → v_forward, so:
        //   angles '0 0 0'   → +X
        //   angles '0 90 0'  → +Y
        //   angles '0 180 0' → -X
        //   angles '0 270 0' → -Y
        //   angles '0 -1 0'  → +Z (up)
        //   angles '0 -2 0'  → -Z (down)
        SetMovedir();
        if (self.distance)
            self.pos2 = self.pos1 + self.movedir * self.distance;
        else
            self.pos2 = self.pos1 + self.movedir * (fabs(self.movedir * self.size) - self.lip);
    }

    if (self.spawnflags & DOOR_START_OPEN)
    {
        setorigin(self, self.pos2);
        swap_pos  = self.pos1;
        self.pos1 = self.pos2;
        self.pos2 = swap_pos;

        // Auto-close behaviour at map load — same logic
        // Door_RoundReset uses on subsequent rounds.  TOGGLE pins the
        // door open until pressed; ONE_MOVEMENT pins it for the
        // round; wait<0 is the legacy "stay open" sentinel.
        if (self.wait >= 0
            && !(self.spawnflags & DOOR_TOGGLE)
            && !(self.spawnflags & DOOR_ONE_MOVEMENT))
        {
            self.nextthink = self.ltime + self.wait;
            self.think     = door_go_up;        // close direction (post-swap)
        }
    }

    // combined bounds for proximity trigger and group-linking
    self.cmins = self.pos1 + self.mins;
    self.cmaxs = self.pos1 + self.maxs;
    if (self.pos2_x + self.mins_x < self.cmins_x) self.cmins_x = self.pos2_x + self.mins_x;
    if (self.pos2_y + self.mins_y < self.cmins_y) self.cmins_y = self.pos2_y + self.mins_y;
    if (self.pos2_z + self.mins_z < self.cmins_z) self.cmins_z = self.pos2_z + self.mins_z;
    if (self.pos2_x + self.maxs_x > self.cmaxs_x) self.cmaxs_x = self.pos2_x + self.maxs_x;
    if (self.pos2_y + self.maxs_y > self.cmaxs_y) self.cmaxs_y = self.pos2_y + self.maxs_y;
    if (self.pos2_z + self.maxs_z > self.cmaxs_z) self.cmaxs_z = self.pos2_z + self.maxs_z;

    self.door_state  = DOOR_STATE_BOTTOM;
    self.mover_state = MOVER_STATE_BOTTOM;

    // Auto-spawn the proximity touch trigger ONLY when sv_door_proximity is on (default 0 = OFF).
    // Off → the door opens only on +use (door_use, requires USE_ABLE) / target-chain / damage — never on
    // walk-near.  The proximity trigger re-fired door_use every frame the player stood in its box (via the
    // per-frame SV_CheckTouchTriggers scan), which caused both the walk-near open AND the every-frame
    // direction reversal.  Still gated on un-targeted (mappers wiring via target want exclusive control) +
    // USE_ABLE + not PASS_THROUGH when re-enabled.
    if (cvar("sv_door_proximity")
        && !self.targetname
        && (self.spawnflags & DOOR_USE_ABLE)
        && !(self.spawnflags & DOOR_PASS_THROUGH))
        door_spawn_trigger();
};

// Round restart — restore every door to its initial pose, re-arm
// shootable doors, and re-schedule the START_OPEN auto-close.
// Called from RoundRestart in sv_main.qc.
void() Door_RoundReset =
{
    entity d = find(world, classname, "func_door");
    while (d)
    {
        d.door_movement_done = 0;
        d.attack_finished    = 0;
        d.velocity           = '0 0 0';
        d.think              = __NULL__;
        d.nextthink          = 0;

        // Snap to pos1 — for non-START_OPEN doors that's the closed
        // position; for START_OPEN doors pos1/pos2 were swapped at
        // spawn so pos1 is the OPEN position.  Either way, "BOTTOM"
        // is the door's initial state.
        setorigin(d, d.pos1);
        d.door_state  = DOOR_STATE_BOTTOM;
        d.mover_state = MOVER_STATE_BOTTOM;
        d.SendFlags   = 1;

        if (d.max_health)
        {
            d.health     = d.max_health;
            d.takedamage = DAMAGE_YES;
        }

        // Re-arm the START_OPEN auto-close timer for this round.
        if ((d.spawnflags & DOOR_START_OPEN)
            && d.wait >= 0
            && !(d.spawnflags & DOOR_TOGGLE)
            && !(d.spawnflags & DOOR_ONE_MOVEMENT))
        {
            d.nextthink = d.ltime + d.wait;
            d.think     = door_go_up;
        }

        d = find(d, classname, "func_door");
    }
};

// ============================================================================
//  Team spawn point stubs
//
//  Empty QC functions so the engine keeps these entities at map load
//  (entities with no matching QC function get dropped).  Their classnames
//  are the spawn-search anchors for PlayerGetSpawnPointEntity.
// ============================================================================

void() info_player_blue = {};
void() info_player_red = {};
void() info_player_start_blue = { info_player_blue(); };
void() info_player_start_red = { info_player_red(); };
void() info_player_team1 = { info_player_blue(); };
void() info_player_team2 = { info_player_red(); };

// CS-style fallback spawn — empty stub so the engine keeps the entity
// at map load.  PlayerGetSpawnPointEntity falls back to
// info_player_deathmatch as the RED/T-side primary CS spawn classname.
// info_player_start already has its own QC function in sv_player.qc.
void() info_player_deathmatch = {};
