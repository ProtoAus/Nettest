//
// sv_func_tracktrain.qc — HL/GoldSrc func_tracktrain brush entity
//
// Path-following brush train that rotates to face the next path_track
// as it travels.  Walks path_track chains (vs func_train's
// path_corner chains).  Aligned via origin brush (mapper places it),
// brush model should face -X (west) in the editor so heading 0°
// = facing east at runtime.
//
// What's implemented (basic GoldSrc compatibility):
//   - Path walking via path_track .target chain.
//   - Auto-orient: angles re-computed each tick to face the current
//     destination track.  TT_NO_PITCH flag locks pitch to 0.
//   - Spawn-time orient toward the SECOND track (HL spec — train
//     spawns at first track and faces second).
//   - Engine sound enum (1..6, with the HL idx-5→ttrain6 quirk
//     preserved for asset compat).
//   - Crush damage via .blocked.
//   - path_track TELEPORT spawnflag (snap to track).
//   - path_track FIRE_ONCE message gating.
//   - trigger / multi_manager to start/stop the chain (HL: trigger toggles).
//   - Render modes (shares FuncTrain_ApplyRenderMode).
//
// NOT yet implemented (accepted in fgd, parsed, no effect):
//   - Player driving.  Real +use mount/throttle/HUD is substantial
//     CSQC work; for now the train walks its path after a normal
//     trigger / multi_manager use.  TT_NO_USERCONTROL is accepted as
//     mapper data but does not force spawn-time autostart.
//   - "wheels" front-axle kinematics — v1 uses simple delta-to-
//     next-track heading instead.  Close enough for most paths.
//   - "bank" — turn-banking roll.  v1 keeps roll at 0.
//   - "height" — origin offset above the path.  v1 places the
//     train directly on the track origins.
//
// Shared fields with func_train (declared there, visible here
// because sv_func_train.qc compiles first):
//   .train_target, .train_state, .train_fire_used,
//   .train_movesound_path, .train_movesound_active,
//   .train_stopsound_path, .avelocity_init.
// Helpers (declared in sv_func_train.qc, global QC scope):
//   FuncTrain_TickInterval(), FuncTrain_ApplyRenderMode().
//

const float TT_NO_PITCH       = 1;
const float TT_NO_USERCONTROL = 2;
const float TT_FORWARDS_ONLY  = 4;
const float TT_PASSABLE       = 8;

// path_track spawnflags.
const float PT_DISABLED       = 1;
const float PT_FIRE_ONCE      = 2;
const float PT_BRANCH_REVERSE = 4;
const float PT_DISABLE_TRAIN  = 8;
const float PT_TELEPORT       = 16;

// Mapper-facing keys not declared elsewhere.
.float wheels;
.float height;
.float startspeed;
.float bank;
.float sounds;     // func_tracktrain engine sound enum

// Forward decls — defined in sv_func_train.qc / sv_platform_carry.qc.
float() FuncTrain_TickInterval;
void(float mode, float amt) FuncTrain_ApplyRenderMode;
float() Mover_PlatformCarry;
float() Mover_GeometryBlockPush;
void(entity c) MovingBrush_AddToList;
void(entity c) MovingBrush_RemoveFromList;

// Declared in sv_trigger_logic.qc — TRUE once a live player has
// reached PlayerSpawn.  Gates the startspeed-driven autostart below.
// QC linker shares globals across files compiled in the same VM, so
// no explicit `extern` is needed — just reference the name.

void() func_tracktrain_arrive;
void() func_tracktrain_continue;
void() func_tracktrain_move_to_target;
void() func_tracktrain_move_tick;
void() func_tracktrain_use;
void() func_tracktrain_find_first;
void() func_tracktrain_blocked;

// HL func_tracktrain engine sound enum.  Index 5 maps to ttrain6.wav
// (note the gap) — preserved verbatim from HL .fgd for asset compat.
string(float idx) FuncTrackTrain_Sound =
{
    if (idx == 1) return "plats/ttrain1.wav";
    if (idx == 2) return "plats/ttrain2.wav";
    if (idx == 3) return "plats/ttrain3.wav";
    if (idx == 4) return "plats/ttrain4.wav";
    if (idx == 5) return "plats/ttrain6.wav";
    if (idx == 6) return "plats/ttrain7.wav";
    return "";
};

entity(entity from) FuncTrackTrain_NextTrack =
{
    if (!from || from.target == "") return world;
    return find(world, targetname, from.target);
};

// Compute angles using wheel-distance lookahead kinematics — the HL
// behaviour the user asked for: as the train approaches a corner the
// front-axle "lookahead" point projects past the corner onto the
// next-segment direction, so heading rotates SMOOTHLY before the
// train physically reaches the corner.  Stiff right-angle snaps
// happen only when `wheels` is 0 (degenerate case).
//
// Geometry: imagine a point `wheels` units ahead of the train along
// its current segment.  If that point is past the current target
// corner, the excess "spills" onto the next segment.  Heading is the
// vector from origin to that lookahead point.
//
//        origin → ───wheels─→ lookahead
//        (back wheel)         (front wheel)
//
//        With distance < wheels to corner, the lookahead extends
//        past the corner along the next-segment direction, pulling
//        heading toward the next corner BEFORE we arrive.
void() FuncTrackTrain_FaceTarget =
{
    if (self.train_target == world) return;

    vector to_target = self.train_target.origin - self.origin;
    float  dist_target = vlen(to_target);
    if (dist_target < 0.01) return;

    vector heading;
    float  wd = self.wheels;
    if (wd <= 0) wd = 100;            // HL default

    if (wd < dist_target)
    {
        // Lookahead within current segment — heading is just the
        // direction toward the current target.
        heading = to_target;
    }
    else
    {
        // Lookahead spills past the current corner.  Walk the
        // remaining `wd - dist_target` units along the next segment
        // direction.  If there's no next corner, pin at the current
        // target (heading reverts to straight-line).
        entity next_pt = FuncTrackTrain_NextTrack(self.train_target);
        if (next_pt == world)
        {
            heading = to_target;
        }
        else
        {
            vector to_next     = next_pt.origin - self.train_target.origin;
            float  next_len    = vlen(to_next);
            float  spill       = wd - dist_target;
            vector lookahead;
            if (next_len > 0.01)
                lookahead = self.train_target.origin
                          + (to_next / next_len) * (spill < next_len ? spill : next_len);
            else
                lookahead = self.train_target.origin;
            heading = lookahead - self.origin;
        }
    }

    if (self.spawnflags & TT_NO_PITCH)
        heading_z = 0;

    if (vlen(heading) < 0.01) return;

    vector new_angles = vectoangles(heading);
    if (self.spawnflags & TT_NO_PITCH)
        new_angles_x = 0;
    new_angles_z = 0;     // bank-on-turns not implemented; pin roll

    self.angles = new_angles;
};

void() func_tracktrain_move_tick =
{
    if (self.train_target == world)
    {
        self.velocity    = '0 0 0';
        self.avelocity   = '0 0 0';
        self.train_state = 0;
        return;
    }

    vector delta       = self.train_target.origin - self.origin;
    float  dist_remain = vlen(delta);

    float spd = self.speed;
    if (self.train_target.speed > 0)
        spd = self.train_target.speed;

    if (dist_remain <= 0 || spd <= 0)
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] tick at \"%s\" dist=%g -> arrive\n",
                           self.targetname, self.train_target.targetname, dist_remain));
        func_tracktrain_arrive();
        return;
    }

    float tick_dt = FuncTrain_TickInterval();
    float advance = spd * tick_dt;
    if (advance * 1.5 >= dist_remain)
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] snap to \"%s\" dist=%g\n",
                           self.targetname, self.train_target.targetname, dist_remain));
        setorigin(self, self.train_target.origin);
        self.velocity = '0 0 0';
        func_tracktrain_arrive();
        return;
    }

    self.velocity = (delta / dist_remain) * spd;
    self.mover_planned_velocity = self.velocity;
    FuncTrackTrain_FaceTarget();

    // Dirty the brushsync wire so CSQC sees the updated origin /
    // angles / velocity every tick — see sv_func_train.qc for the
    // full reasoning.  Without this, the train was visually frozen
    // on clients even though it moved server-side.
    self.SendFlags = 1;

    // Player interaction is applied from PM_CheckMovingPushers's
    // train branch (sh_pmove.qc), not from here — same reasoning
    // as sv_func_train.qc.  Single source on the pmove side keeps
    // server / client in lockstep.

    self.think     = func_tracktrain_move_tick;
    self.nextthink = self.ltime + tick_dt;
};

void() func_tracktrain_move_to_target =
{
    if (self.train_target == world)
    {
        self.train_state = 0;
        return;
    }

    // PT_TELEPORT: jump instantly to the track.
    if (self.train_target.spawnflags & PT_TELEPORT)
    {
        setorigin(self, self.train_target.origin);
        self.velocity = '0 0 0';
        FuncTrackTrain_FaceTarget();
        func_tracktrain_arrive();
        return;
    }

    self.train_state = 1;

    // Engine sound loops for the whole move.  Start it once on the
    // first segment, leave running across corner transitions so we
    // don't stutter the loop.
    if (self.train_movesound_path != "" && !self.train_movesound_active)
    {
        sound(self, CHAN_BODY, self.train_movesound_path, self.volume, ATTN_NORM);
        self.train_movesound_active = 1;
    }

    // Publish to moving_brush_list so PM_CheckMovingPushers's train
    // branch can run the carry/push pass each pmove substep.  See
    // sv_func_train.qc for the full reasoning.
    MovingBrush_AddToList(self);

    func_tracktrain_move_tick();
};

void() func_tracktrain_arrive =
{
    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] arrive at \"%s\" origin=%v next=\"%s\"\n",
                       self.targetname,
                       self.train_target.targetname,
                       self.train_target.origin,
                       self.train_target.target));

    setorigin(self, self.train_target.origin);
    self.velocity              = '0 0 0';
    self.mover_planned_velocity = '0 0 0';

    // Re-dirty so CSQC sees the stop snap + stops integrating stale velocity.
    self.SendFlags = 1;

    // PT_DISABLE_TRAIN: HL stops user control here.  Without driving
    // implemented, this just halts the train at the track — pattern
    // used for runaway-train sequences that need to stop at a fixed
    // point.
    if (self.train_target.spawnflags & PT_DISABLE_TRAIN)
    {
        if (self.train_movesound_active)
        {
            sound(self, CHAN_BODY, "", 0, ATTN_NORM);
            self.train_movesound_active = 0;
        }
        MovingBrush_RemoveFromList(self);
        self.train_state = 0;
        return;
    }

    // Fire on pass — path_track.message holds the targetname.  Swap-
    // restore around Trigger_UseTargets (same pattern as func_train —
    // Trigger_UseTargets only reads caller.target so we temporarily
    // alias .target to .message during the fire).
    if (self.train_target.message != "")
    {
        if (!(self.train_target.spawnflags & PT_FIRE_ONCE)
            || !(self.train_fire_used & 1))
        {
            string saved_target = self.train_target.target;
            self.train_target.target = self.train_target.message;

            entity oldself = self;
            self = self.train_target;
            sub_use_type = USE_TOGGLE;
            Trigger_UseTargets(self, oldself);
            self = oldself;

            self.train_target.target = saved_target;

            if (self.train_target.spawnflags & PT_FIRE_ONCE)
                self.train_fire_used |= 1;
        }
    }

    // Optional pause at this track before continuing.
    if (self.train_target.wait > 0)
    {
        self.train_state = 2;
        self.think     = func_tracktrain_continue;
        self.nextthink = self.ltime + self.train_target.wait;
        return;
    }

    func_tracktrain_continue();
};

void() func_tracktrain_continue =
{
    entity next_pt = FuncTrackTrain_NextTrack(self.train_target);
    if (next_pt == world)
    {
        // End of chain — stop here.  Engine sound cuts so the train
        // isn't humming forever.
        if (self.train_movesound_active)
        {
            sound(self, CHAN_BODY, "", 0, ATTN_NORM);
            self.train_movesound_active = 0;
        }
        MovingBrush_RemoveFromList(self);
        self.train_state = 0;
        return;
    }
    self.train_target = next_pt;
    func_tracktrain_move_to_target();
};

void() func_tracktrain_use =
{
    // Lazy first-stop init if find_first hasn't run yet.
    if (self.train_target == world && self.target != "")
    {
        func_tracktrain_find_first();
        if (self.train_target == world)
            return;
    }

    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] use state=%g useType=%g current=\"%s\"\n",
                       self.targetname, self.train_state, sub_use_type,
                       self.train_target ? self.train_target.targetname : ""));

    if (self.train_state == 0)
    {
        // Start — advance to NEXT track (current is our spawn anchor).
        entity next_pt = FuncTrackTrain_NextTrack(self.train_target);
        if (next_pt == world)
        {
            if (cvar("sv_debug_func_train"))
                dprint(sprintf("[tracktrain %s] use start failed: no next after \"%s\"\n",
                               self.targetname, self.train_target.targetname));
            return;
        }
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] use start: \"%s\" -> \"%s\"\n",
                           self.targetname, self.train_target.targetname, next_pt.targetname));
        self.train_target = next_pt;
        func_tracktrain_move_to_target();
        return;
    }

    // Triggered while moving — HL stops the train.  Re-trigger
    // restarts via the state==0 path above.
    self.velocity              = '0 0 0';
    self.mover_planned_velocity = '0 0 0';
    self.train_state           = 0;
    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] use stop at origin=%v target=\"%s\"\n",
                       self.targetname, self.origin,
                       self.train_target ? self.train_target.targetname : ""));
    if (self.train_movesound_active)
    {
        sound(self, CHAN_BODY, "", 0, ATTN_NORM);
        self.train_movesound_active = 0;
    }
    MovingBrush_RemoveFromList(self);
};

void() func_tracktrain_blocked =
{
    if (self.dmg <= 0 || !other) return;
    if (other.takedamage == DAMAGE_NO) return;
    other.health -= self.dmg;
};

// Deferred init — snap to first track, then orient toward the SECOND
// track per HL spec ("orient itself to face the second path_track").
void() func_tracktrain_find_first =
{
    if (self.target == "")
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] no first stop target; staying at brush origin=%v\n",
                           self.targetname, self.origin));
        return;
    }

    entity pt = find(world, targetname, self.target);
    if (pt == world)
    {
        dprint(sprintf("func_tracktrain \"%s\": first stop \"%s\" not found\n",
                       self.targetname, self.target));
        return;
    }

    setorigin(self, pt.origin);
    self.train_target = pt;
    self.train_state  = 0;

    // Face the second track (= first.target) on spawn.
    entity second = FuncTrackTrain_NextTrack(pt);
    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[tracktrain %s] first=\"%s\" origin=%v second=\"%s\" flags=%g speed=%g startspeed=%g\n",
                       self.targetname, pt.targetname, pt.origin,
                       second ? second.targetname : "",
                       self.spawnflags, self.speed, self.startspeed));
    if (second != world)
    {
        entity saved = self.train_target;
        self.train_target = second;
        FuncTrackTrain_FaceTarget();
        self.train_target = saved;
    }

    // GoldSrc compatibility autostart.  HL maps that begin with the
    // player already aboard a moving train (chapter intros, c0a0a's
    // intro_train, etc.) rely on either trigger_auto firing the
    // train or the engine restoring its previous-map .globalname
    // state mid-motion.  Quake-style level transitions don't carry
    // entity state across maps and these maps rarely include a
    // trigger_auto — so the train sits motionless at its first
    // path_track instead of rolling away.
    //
    // Heuristic: if `startspeed` is non-zero, the mapper authored
    // this train to be moving at spawn.  Kick it into motion by
    // running the same Use() path a trigger_auto would.  Mappers
    // who want a strictly stop-at-spawn train just leave startspeed
    // at 0 (the default), so this can't regress static-on-spawn
    // tracktrains.  Globalname-restored state still works because
    // any later .use() call from a real trigger will toggle stop /
    // start as authored.
    if (self.startspeed > 0 && self.train_state == 0)
    {
        // sv_waitforplayer: defer the autostart until a live player
        // has spawned, so an intro train on a listen server doesn't
        // roll away before the local user even joined a team.
        // Re-runs find_first in a short loop until the gate releases.
        if (cvar("sv_waitforplayer") && !sv_first_player_spawned)
        {
            if (cvar("sv_debug_func_train"))
                dprint(sprintf("[tracktrain %s] autostart deferred — waiting for first player\n",
                               self.targetname));
            self.think     = func_tracktrain_find_first;
            self.nextthink = time + 0.25;
            return;
        }

        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[tracktrain %s] startspeed autostart speed=%g\n",
                           self.targetname, self.startspeed));
        func_tracktrain_use();
    }
};

/*QUAKED func_tracktrain (0 .5 .8) ? TT_NO_PITCH TT_NO_USERCONTROL TT_FORWARDS_ONLY TT_PASSABLE
HL/GoldSrc-style path-following brush train that auto-orients to face
the next path_track.

"target"      First-stop path_track targetname.
"speed"       Max speed (units/sec, default 100).
"startspeed"  Initial speed (defaults to speed).
"wheels"      Front-wheel distance (v1: unused; uses delta-to-next).
"height"      Offset above track (v1: unused).
"dmg"         Crush damage on .blocked (default 2).
"sounds"      Engine sound enum 1..6.
"volume"      Engine sound volume (default 0.85).
"bank"        Turn-banking degrees (v1: unused).
"rendermode"  0=normal, 1=color, 2=texture, 3=glow, 4=solid, 5=additive.
"renderamt"   Alpha 0..255 for non-normal render modes.
"rendercolor" RGB for rendermode=1.

TT_NO_PITCH       Lock pitch to 0 (yaw-only rotation).
TT_NO_USERCONTROL Player driving disabled (v1: always effectively on).
TT_FORWARDS_ONLY  Can only be driven forward (v1: irrelevant).
TT_PASSABLE       Train doesn't block players.
*/
void() func_tracktrain =
{
    if (self.speed == 0)      self.speed      = 100;
    if (self.startspeed == 0) self.startspeed = self.speed;
    if (self.wheels == 0)     self.wheels     = 100;
    if (self.dmg == 0)        self.dmg        = 2;
    if (self.volume == 0)     self.volume     = 0.85;

    if (cvar("sv_debug_func_train"))
    {
        dprint(sprintf("[tracktrain %s] spawn target=\"%s\" speed=%g startspeed=%g flags=%g\n",
                       self.targetname, self.target, self.speed, self.startspeed,
                       self.spawnflags));
        dprint(sprintf("             height=%g wheels=%g origin=%v\n",
                       self.height, self.wheels, self.origin));
    }

    // Wire through brushsync so CSQC predicts our motion + the
    // platform-carry / geometry-push pass (sv_func_train.qc has the
    // long-form comment for why).
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;
    if (self.spawnflags & TT_PASSABLE)
        self.solid = SOLID_NOT;

    // Engine sound enum → path resolution + precache.
    self.train_movesound_path = FuncTrackTrain_Sound(self.sounds);
    if (self.train_movesound_path != "")
        precache_sound(self.train_movesound_path);

    if (self.rendermode > 0)
        FuncTrain_ApplyRenderMode(self.rendermode, self.renderamt);

    self.use     = func_tracktrain_use;
    self.blocked = func_tracktrain_blocked;

    self.think     = func_tracktrain_find_first;
    self.nextthink = time + 0.1;
};
