//
// sv_func_train.qc — HL/GoldSrc func_train brush entity
//
// Brushmodel that walks a path_corner chain.  Each path_corner stores
// the targetname of the NEXT corner in its .target field, so the train
// just chases self.train_target.target through find()-by-name.  Speed,
// wait, fire-on-pass message, and per-corner spawnflags (teleport /
// wait-for-retrigger / fire-once) are read from the active path_corner
// at arrival time — the path_corner itself has no behaviour, all logic
// lives here (HL spec: "The logic is actually contained entirely in
// func_train").
//
// Keys:
//   target           — first stop path_corner's targetname.  Train
//                      spawns at this corner's origin.
//   speed            — units/second (default 100).
//   avelocity        — Y Z X axial rotation applied while moving.
//   dmg              — crush damage when something gets squished
//                      between the train and a wall (default 2).
//   movesnd          — index into the HL move-sound enum (see table).
//   stopsnd          — index into the HL stop-sound enum.
//   volume           — sound volume (default 0.85).
//   rendermode       — 0=normal, 1=color, 2=texture, 3=glow,
//                      4=solid (alphatest), 5=additive.
//   renderamt        — 0..255 alpha component for rendermodes 1-5.
//   rendercolor      — RGB tint for rendermode 1 (color).
//   renderfx         — pulse/strobe/glow envelope (subset
//                      implemented; values not listed are no-ops).
//
// Spawnflags:
//    8  NOT_SOLID    — train doesn't block players (passes through).
//

const float TRAIN_NOT_SOLID = 8;

// EF_ADDITIVE + EF_NODRAW are declared in server/sv_customdefs.qc (which
// compiles before us in sv_progs.src).

// path_corner spawnflag bits (read from the corner the train is
// arriving AT, not on the func_train itself).
const float PATH_WAIT_FOR_RETRIGGER = 1;
const float PATH_TELEPORT           = 2;
const float PATH_FIRE_ONCE          = 4;

// Mapper keys not declared elsewhere.
.float  dmg;
.float  movesnd;
.float  stopsnd;
.float  volume;
.float  rendermode;
.float  rendercolor_set;   // 1 if rendercolor was non-zero on spawn
.float  renderfx;
.vector avelocity_init;    // saved spawn-time avelocity (re-applied each move)

// Runtime state.
.entity train_target;       // current destination path_corner
.float  train_state;        // 0 = stopped, 1 = moving, 2 = waiting at corner
.float  train_fire_used;    // bit-per-corner-fired latch for PATH_FIRE_ONCE
                            // (overflows after 32 corners; HL fired_once is
                            // also a single bit per train so close enough).
.string train_movesound_path;   // resolved at spawn from movesnd enum
.string train_stopsound_path;
.float  train_movesound_active; // 1 = move sound currently playing on CHAN_BODY

// HL move-sound enum table.  Indices 1..13.  Index 0 = null.wav (no sound).
string(float idx) FuncTrain_MoveSound =
{
    if (idx == 1)  return "plats/bigmove1.wav";
    if (idx == 2)  return "plats/bigmove2.wav";
    if (idx == 3)  return "plats/elevmove1.wav";
    if (idx == 4)  return "plats/elevmove2.wav";
    if (idx == 5)  return "plats/elevmove3.wav";
    if (idx == 6)  return "plats/freightmove1.wav";
    if (idx == 7)  return "plats/freightmove2.wav";
    if (idx == 8)  return "plats/heavymove1.wav";
    if (idx == 9)  return "plats/rackmove1.wav";
    if (idx == 10) return "plats/railmove1.wav";
    if (idx == 11) return "plats/squeekmove1.wav";
    if (idx == 12) return "plats/talkmove1.wav";
    if (idx == 13) return "plats/talkmove2.wav";
    return "";
};

// HL stop-sound enum table.  Indices 1..8.  Index 0 = null.wav.
string(float idx) FuncTrain_StopSound =
{
    if (idx == 1) return "plats/bigstop1.wav";
    if (idx == 2) return "plats/bigstop2.wav";
    if (idx == 3) return "plats/freightstop1.wav";
    if (idx == 4) return "plats/heavystop2.wav";
    if (idx == 5) return "plats/rackstop1.wav";
    if (idx == 6) return "plats/railstop1.wav";
    if (idx == 7) return "plats/squeekstop1.wav";
    if (idx == 8) return "plats/talkstop1.wav";
    return "";
};

// HL rendermode → FTE .effects + .alpha translation.
//
// HL semantics for non-Normal render modes treat renderamt directly
// as the alpha component: 0 = fully transparent, 255 = fully opaque.
// Map authors lean on this hard — invisible func_trains that act as
// position markers for env_beam typically set rendermode=2
// (Texture) + renderamt=0 (or just leave renderamt unset, defaulting
// to 0).  Previous version of this code did `(amt > 0) ? amt/255 : 1.0`
// which inverted the HL convention and made every position-marker
// train fully opaque.
//
// EF_NODRAW used for the amt==0 case to skip rendering entirely
// (cheaper than alpha=0 on a brush, and matches sv_push.qc /
// sv_teleport.qc which use the same trick for their invisible
// trigger brushes).
void(float mode, float amt) FuncTrain_ApplyRenderMode =
{
    self.effects = 0;

    if (mode == 0)
    {
        self.alpha = 1.0;
        return;
    }

    if (amt == 0)
    {
        // HL: rendermode != Normal && renderamt == 0 → invisible.
        self.effects |= EF_NODRAW;
        return;
    }

    self.alpha = amt / 255;
    if (mode == 3 || mode == 5)            // glow / additive
        self.effects |= EF_ADDITIVE;
    if (mode == 4)                          // solid / alphatest
        self.alpha = 1.0;                   // alphatest is binary, force opaque
};

void() func_train_arrive;
void() func_train_continue;
void() func_train_move_to_target;
void() func_train_move_tick;
void() func_train_use;
void() func_train_blocked;
void() func_train_find_first;

// Forward decls.
//   Mover_PlatformCarry      — sv_platform_carry.qc.  Stand-on-lock +
//                              velocity-inherit on departure.  Replaces
//                              the old bbox-overlap Mover_PushPlayers
//                              call for trains (Mover_PushPlayers
//                              wrongly fired inside enclosed brushes
//                              even with empty space between player
//                              and walls).
//   Mover_GeometryBlockPush  — sv_platform_carry.qc.  Geometry-aware
//                              push for players NOT being carried.
//                              Uses the PM_BoxInTriggerBrush dimension
//                              trick so only actual BSP intersections
//                              trigger a push.
//   MovingBrush_*            — sh_pmove.qc list management.  Kept so
//                              the existing brushsync prediction
//                              plumbing finds us when extended to
//                              trains (follow-up).
float() Mover_PlatformCarry;
float() Mover_GeometryBlockPush;
void(entity c) MovingBrush_AddToList;
void(entity c) MovingBrush_RemoveFromList;

// Resolve the next-corner step.  Returns world if the chain ends or
// the next-name doesn't resolve (mapper error / dangling target).
entity(entity from) FuncTrain_NextCorner =
{
    if (!from || from.target == "")
        return world;
    return find(world, targetname, from.target);
};

// WHERE A CORNER ACTUALLY PUTS THE TRAIN.
//
// Half-Life does NOT put the entity's origin on the path_corner — it puts the
// BRUSH'S CENTRE there.  Both destination sites in CFuncTrain say so:
//     Activate: UTIL_SetOrigin(pev, pevTarg->origin - (pev->mins + pev->maxs) * 0.5)
//                                                            (plats.cpp:822)
//     Next:     LinearMove(pTarg->pev->origin - (pev->mins + pev->maxs) * 0.5, ...)
//                                                            (plats.cpp:806)
// This file read the corner origin raw at all five destination sites, which is
// harmless ONLY when the func_train has an ORIGIN brush — ZHLT then offsets the
// submodel geometry so (mins+maxs)*0.5 is ~0 and the two formulas agree.  With
// no origin key the inline submodel carries ABSOLUTE bounds (the same case
// sv_brushsync.qc:617-621 documents for func_wall), and the brush is translated
// by the entire corner vector instead of by the small local offset.
//
// pizza_ya_san1's tr_soukoexit is exactly that: no origin key, submodel *74 with
// centre (676 1888 -864), first corner at (676 1888 -936).  HL places it at
// (0 0 -72); this placed it at (676 1888 -936), putting the brush's world box at
// Y 3744 and Z -1856 against a world hull that ends at Y 2816 / Z -1024.  So the
// train DID spawn, DID setmodel and was NOT invisible — func_train_find_first
// teleported it bodily outside the map 0.1 s later, where it has no PVS leafs
// and is never sent to the client.  "I just don't see it in the level."
//
// Measured over the corpus: 1107 func_train with an inline brushmodel, 527 with
// no origin key, and every one of those 527 has |centre| > 16 (median 2432).
vector(entity pc) FuncTrain_DestOrigin =
{
    return pc.origin - (self.mins + self.maxs) * 0.5;
};

// Per-tick movement step.  Re-evaluated every TRAIN_MOVE_TICK seconds
// while the train is in transit between corners.  Each tick:
//   1. Recompute the remaining vector to the destination.
//   2. If the next tick would overshoot the destination, SNAP to it
//      exactly and call func_train_arrive() — this is the cure for
//      the previous "shoots past the corner before nextthink fires"
//      bug (the engine's MOVETYPE_PUSH integrator advances velocity *
//      frametime per server tick, and the single-shot
//      nextthink=time+travel_time approach left ~one tick of
//      overshoot before the arrival think fired).
//   3. Otherwise re-aim velocity at the destination (handles the
//      case where a func_train target gets moved between ticks) and
//      reschedule.
// Resolve the QC tick interval from sv_func_tickrate (Hz).  Clamped
// to (0, 200] so a typo doesn't lock think dispatch.
float() FuncTrain_TickInterval =
{
    // Floored at the server's real physics frame — see Mover_TickInterval in
    // sv_customdefs.qc.  Scheduling shorter than a frame does not make a train
    // smoother, it makes it SLOWER, by exactly the ratio.
    return Mover_TickInterval(64);
};

void() func_train_move_tick =
{
    if (self.train_target == world)
    {
        self.velocity    = '0 0 0';
        self.avelocity   = '0 0 0';
        self.train_state = 0;
        return;
    }

    vector delta       = FuncTrain_DestOrigin(self.train_target) - self.origin;
    float  dist_remain = vlen(delta);

    // Per-corner speed override (HL: "New train speed" on path_corner).
    float spd = self.speed;
    if (self.train_target.speed > 0)
        spd = self.train_target.speed;

    if (dist_remain <= 0 || spd <= 0)
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[train %s] tick at corner \"%s\" (dist=%g) -> arrive\n",
                           self.targetname, self.train_target.targetname, dist_remain));
        func_train_arrive();
        return;
    }

    // Would the next tick (at the current speed) carry us PAST the
    // corner?  If yes, snap exactly to the destination this frame so
    // the path doesn't visibly overshoot.  Compare against advance *
    // 1.5 to absorb single-frame jitter in server tick spacing —
    // better to snap a tiny bit early than to overshoot.
    float tick_dt = FuncTrain_TickInterval();
    float advance = spd * tick_dt;
    if (advance * 1.5 >= dist_remain)
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[train %s] tick snap to \"%s\" (dist=%g <= adv=%g*1.5)\n",
                           self.targetname, self.train_target.targetname,
                           dist_remain, advance));
        setorigin(self, FuncTrain_DestOrigin(self.train_target));
        self.velocity = '0 0 0';
        func_train_arrive();
        return;
    }

    // Still distance to go.  Re-aim velocity each tick (corner may
    // have moved if mappers point trains at other movers) and
    // reschedule the next check.
    //
    // CRITICAL: MOVETYPE_PUSH entities run on self.ltime — the engine's
    // per-entity integration clock — not world `time`.  See earlier
    // commit comment for the back-and-forth oscillation history.
    self.velocity  = (delta / dist_remain) * spd;
    self.mover_planned_velocity = self.velocity;   // Mover_PushPlayers reads this as fallback if velocity gets zeroed by a block
    self.avelocity = self.avelocity_init;

    // Dirty the brushsync wire so CSQC sees the updated origin /
    // velocity / angles each tick.  Without this, SV_InitReplicatedSolidBrush
    // set SendFlags=1 ONCE at spawn, the engine cleared it after the
    // first send, and the train then sat visually frozen on the client
    // even though it was moving server-side — the user's "train doesn't
    // move visually but I get dragged with the server collision" symptom.
    self.SendFlags = 1;

    // Player interaction is NOT applied from the train's tick.
    // Both server and client pmove now run the carry + geometry-push
    // pass against each player from PM_CheckMovingPushers (sh_pmove.qc
    // train branch), so the SAME math runs at the SAME pmove cadence
    // on both sides — snapshots match predictions, no reconcile snap.
    // The previous tick-side application introduced double-source
    // jitter because the train tick (64 Hz) and the pmove (60-300 Hz)
    // produced different per-tick deltas; reconcile pulled the
    // predicted player toward the server's tick-resolution position
    // every snapshot.

    self.think     = func_train_move_tick;
    self.nextthink = self.ltime + tick_dt;
};

// Kick off a move from the current origin to self.train_target.origin.
// Handles the path_corner TELEPORT spawnflag, starts the move sound,
// and hands off to the per-tick walker.
void() func_train_move_to_target =
{
    if (self.train_target == world)
    {
        self.train_state = 0;
        return;
    }

    // PATH_TELEPORT: jump instantly to the corner and arrive without
    // running the per-tick walker.
    if (self.train_target.spawnflags & PATH_TELEPORT)
    {
        setorigin(self, FuncTrain_DestOrigin(self.train_target));
        self.velocity = '0 0 0';
        func_train_arrive();
        return;
    }

    self.train_state = 1;

    // Move sound — CHAN_BODY so the per-train looping plays without
    // colliding with other entities' sound channels.  HL plays the
    // move sound throughout the move (loop = single play of a short
    // sample, restarted if move duration exceeds sample length).
    if (self.train_movesound_path != "" && !self.train_movesound_active)
    {
        sound(self, CHAN_BODY, self.train_movesound_path, self.volume, ATTN_NORM);
        self.train_movesound_active = 1;
    }

    // Publish to moving_brush_list — PM_CheckMovingPushers walks this
    // list every pmove substep and runs the train carry/push branch
    // against each player.  We're back to the list now that the
    // bbox-overlap path (which previously double-stacked train.velocity
    // onto carried players) lives in a separate CSQC-only door branch
    // — the train branch added in PM_CheckMovingPushers does its own
    // ground-trace carry math instead of bbox push.
    MovingBrush_AddToList(self);

    // First tick runs synchronously so we set velocity + schedule
    // the next check immediately, without waiting for an engine tick.
    func_train_move_tick();
};

// Arrived at self.train_target.  Fire its message, then either:
//   - wait `wait` seconds and continue
//   - stop here for retrigger (PATH_WAIT_FOR_RETRIGGER)
//   - or move straight to the next corner
void() func_train_arrive =
{
    if (cvar("sv_debug_func_train"))
        // Print the MOVER's origin as well as the corner's.  They are not the
        // same thing and the difference is the entire func_train centre-offset
        // bug (see FuncTrain_DestOrigin): a debug line that shows only the
        // corner cannot distinguish a correctly-placed train from one sitting
        // thousands of units outside the world.
        dprint(sprintf("[train %s] arrive at \"%s\" corner=%v self.origin=%v next=\"%s\"\n",
                       self.targetname,
                       self.train_target.targetname,
                       self.train_target.origin,
                       self.origin,
                       self.train_target.target));

    setorigin(self, FuncTrain_DestOrigin(self.train_target));
    self.velocity              = '0 0 0';
    self.mover_planned_velocity = '0 0 0';
    self.avelocity             = '0 0 0';   // pause rotation while stopped (HL behaviour)

    // Re-dirty so CSQC receives the velocity=0 state and stops its
    // MOVETYPE_NOCLIP integration of stale velocity.  Without this
    // the client would keep visually drifting after the train stopped.
    self.SendFlags = 1;

    // Drop out of moving_brush_list while stopped so PM_CheckMovingPushers
    // doesn't keep ticking us as a "moving" brush.
    MovingBrush_RemoveFromList(self);

    // Stop the move sound and play the stop sound.
    if (self.train_movesound_active)
    {
        SV_StopChannel(self, CHAN_BODY);              // cut the loop
        self.train_movesound_active = 0;
    }
    if (self.train_stopsound_path != "")
        sound(self, CHAN_BODY, self.train_stopsound_path, self.volume, ATTN_NORM);

    // Fire on pass — path_corner.message holds the targetname of the
    // entity to fire when the train passes through.  Trigger_UseTargets
    // ONLY reads caller.target, so we temporarily swap .target with
    // .message for the duration of the fire and restore after.
    // (Previous version called Trigger_UseTargets with .target unchanged,
    // which fires the NEXT path_corner instead of the mapper's intended
    // "Fire On Pass" target — wrong field.)
    if (self.train_target.message != "")
    {
        if (!(self.train_target.spawnflags & PATH_FIRE_ONCE)
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

            if (self.train_target.spawnflags & PATH_FIRE_ONCE)
                self.train_fire_used |= 1;
        }
    }

    // PATH_WAIT_FOR_RETRIGGER: stop here until the train is .use()'d.
    if (self.train_target.spawnflags & PATH_WAIT_FOR_RETRIGGER)
    {
        self.train_state = 0;
        self.think = sub_noop;
        self.nextthink = 0;
        return;
    }

    // Wait at this corner before continuing.  wait <= 0 means no wait.
    // ltime-based scheduling — see func_train_move_tick for rationale.
    if (self.train_target.wait > 0)
    {
        self.train_state = 2;
        self.think     = func_train_continue;
        self.nextthink = self.ltime + self.train_target.wait;
        return;
    }

    // No wait — chain straight into the next corner.
    func_train_continue();
};

void() func_train_continue =
{
    entity next_pc = FuncTrain_NextCorner(self.train_target);
    if (next_pc == world)
    {
        // End of chain — stop here.  Mappers loop a chain by pointing
        // the last corner's .target back at the first.
        self.train_state = 0;
        return;
    }
    self.train_target = next_pc;
    func_train_move_to_target();
};

// Trigger handler.  HL has a single .use semantic for trains:
//   - First trigger after spawn: start the chain from the first corner.
//   - During PATH_WAIT_FOR_RETRIGGER pause: resume to next corner.
//   - While moving: stop+restart-quick reroutes when the target was
//     changed via trigger_changetarget (rare; we re-resolve target
//     from the current corner's .target field).
void() func_train_use =
{
    entity next_pc;

    // Lazy init.  If the deferred func_train_find_first hasn't run
    // yet (trigger_auto fires at map load time, our find_first is
    // deferred 0.1s so all path_corners are linked) the train_target
    // is still world and use() would no-op.  Run find_first
    // synchronously here so the first-trigger path works regardless
    // of think timing.
    if (self.train_target == world && self.target != "")
    {
        func_train_find_first();
        if (self.train_target == world)
            return;     // first stop still couldn't resolve
    }

    // HL ShouldToggle — see the matching comment in sv_func_tracktrain.qc.
    if (sub_use_type == USE_ON  && self.train_state != 0) return;
    if (sub_use_type == USE_OFF && self.train_state == 0) return;

    if (self.train_state == 0)
    {
        // Stopped — kick the chain.  Walk one corner forward from the
        // current target (which is our spawn-anchor corner).
        next_pc = FuncTrain_NextCorner(self.train_target);
        if (next_pc == world)
            return;
        self.train_target = next_pc;
        func_train_move_to_target();
        return;
    }

    if (self.train_state == 1 || self.train_state == 2)
    {
        // Already running — HL's "trigger twice to reroute" behaviour:
        // the SECOND trigger forces an immediate stop and re-resolve
        // from the current corner's .target (which may have been
        // changed via trigger_changetarget since we last moved).
        self.velocity  = '0 0 0';
        self.avelocity = '0 0 0';
        next_pc = FuncTrain_NextCorner(self.train_target);
        if (next_pc == world)
        {
            self.train_state = 0;
            return;
        }
        self.train_target = next_pc;
        func_train_move_to_target();
    }
};

// Crush damage when a player (or other takedamage entity) gets pinned
// between the train and a wall.  HL fires per-tick crush as long as
// the obstacle is in the way; we mirror that — the engine calls
// .blocked while the move is obstructed.
void() func_train_blocked =
{
    if (self.dmg <= 0 || !other)
        return;
    // The cutscene_immune check is kept explicitly (W_ApplyDamage reaches it via
    // W_CanDamageTarget, but bailing here also skips the shove).  A player
    // watching a cutscene with the Invulnerable flag must not be ground up by a
    // train they can't see and can't move away from.
    if (other.cutscene_immune)
        return;

    // SHOVE, THEN DAMAGE — HL's order and HL's reason (plats.cpp:1022-1027).
    vector away = other.origin - self.origin;
    away_z = 0;
    if (vlen(away) > 0.01)
    {
        away = normalize(away);
        other.velocity_x = away_x * self.dmg;
        other.velocity_y = away_y * self.dmg;
        other.velocity_z = other.velocity_z + 300;
    }

    // W_ApplyDamage, NOT `other.health -= self.dmg`.
    //
    // The raw path looked harmless and was not: subtracting health kills
    // nothing, so a blocker stays SOLID IN THE PATH — and a blocked
    // MOVETYPE_PUSH brush does not advance .ltime, while every think in this
    // file is scheduled on ltime.  So one monster wandering onto the rails
    // stops the train permanently, for the rest of the map.
    //
    // Measured on the func_tracktrain twin of this function before it was
    // fixed: a monster_houndeye reached health -5,300,000 on hl_c05_a1, still
    // being decremented every frame, with the train frozen against it.
    //
    // The takedamage == DAMAGE_NO early-out is deliberately gone: players are
    // DAMAGE_NO in this tree, so it silently exempted them from being crushed.
    // W_ApplyDamage is the damage chokepoint and decides for itself — the same
    // reasoning sv_platform_carry.qc:164-166 records for its crush call.
    //
    // BEHAVIOUR CHANGE, called out on purpose: train crush now genuinely kills
    // where it previously drove health negative and did nothing else.
    W_ApplyDamage(self, other, self.dmg);
};

// Deferred init — runs 0.1s after spawn so all path_corner entities
// have been spawned + linked by then.  Snaps the train onto the
// first-stop path_corner so designers can place the brush in a dark
// corner for lighting and the player still sees it at the path start.
void() func_train_find_first =
{
    if (self.target == "")
        return;     // no path — train just sits at its brush origin
    entity pc = find(world, targetname, self.target);
    if (pc == world)
    {
        dprint(sprintf("func_train \"%s\": first stop \"%s\" not found in entity list\n",
                       self.targetname, self.target));
        return;
    }
    setorigin(self, FuncTrain_DestOrigin(pc));
    self.train_target = pc;
    self.train_state  = 0;     // stay stopped until triggered
    // Replicate the snap — see the identical note in sv_func_tracktrain.qc.
    // Without this the client keeps rendering the train at its editor
    // position until the train first moves.
    self.SendFlags = 1;
};

/*QUAKED func_train (0 .5 .8) ? x x x TRAIN_NOT_SOLID
HL/GoldSrc-style path-following brush train.

"target"      First-stop path_corner targetname.
"speed"       Move speed in units/sec (default 100).
"avelocity"   Y Z X axial rotation while moving.
"dmg"         Crush damage per tick (default 2).
"movesnd"     Move sound enum (1..13).
"stopsnd"     Stop sound enum (1..8).
"volume"      Sound volume (default 0.85).
"rendermode"  0=normal, 1=color, 2=texture, 3=glow, 4=solid, 5=additive.
"renderamt"   Alpha 0..255 for non-normal render modes.
"rendercolor" RGB for rendermode=1 (color).

TRAIN_NOT_SOLID  Train doesn't block players (passes through).
*/
void() func_train =
{
    if (self.speed == 0)  self.speed  = 100;
    if (self.dmg == 0)    self.dmg    = 2;
    if (self.volume == 0) self.volume = 0.85;

    // Wire through brushsync (sv_brushsync.qc) — sets movetype, solid,
    // SendEntity, pvsflags, AAATRIGGER detection, render keys.  This is
    // what gets the train into CSQC's moving_brush_list (via cl_brushsync's
    // BRUSH_TYPE_TRAIN branch) so client-side pmove can predict carry +
    // geometry-push every frame, eliminating the snap-on-jump and
    // drift-on-corner symptoms.
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;

    // SV_InitReplicatedSolidBrush forces SOLID_BSP; honour the
    // TRAIN_NOT_SOLID spawnflag afterward.  CSQC reads wire_nonsolid
    // from the wire and applies the same.
    if (self.spawnflags & TRAIN_NOT_SOLID)
        self.solid = SOLID_NOT;

    // Save spawn-time avelocity so we can pause + resume rotation
    // around the move/stop transitions.  (.avelocity itself gets
    // zeroed when the train stops at a corner.)
    self.avelocity_init = self.avelocity;
    self.avelocity = '0 0 0';

    // Sound enum → path resolution + precache.
    self.train_movesound_path = FuncTrain_MoveSound(self.movesnd);
    self.train_stopsound_path = FuncTrain_StopSound(self.stopsnd);
    if (self.train_movesound_path != "")
        precache_sound(self.train_movesound_path);
    if (self.train_stopsound_path != "")
        precache_sound(self.train_stopsound_path);

    // HL render modes (subset).  rendercolor parsing: the BSP stores
    // it as "R G B" components on a vector field; non-zero indicates
    // the mapper explicitly set it.
    if (self.rendermode > 0)
        FuncTrain_ApplyRenderMode(self.rendermode, self.renderamt);

    self.use     = func_train_use;
    self.blocked = func_train_blocked;

    // NOT in the player's +use search.  CFuncTrain derives from CBasePlatTrain,
    // whose ObjectCaps is `CBaseEntity::ObjectCaps() & ~FCAP_ACROSS_TRANSITION`
    // (halflife/dlls/plats.cpp:35) - which is ZERO, so it carries none of
    // FCAP_IMPULSE_USE / CONTINUOUS_USE / ONOFF_USE and CBasePlayer::PlayerUse
    // (player.cpp:1573) never finds it.  A train is started by a button or a
    // trigger, never by walking up and pressing use on the carriage.
    //
    // .use is still installed, because that is what a trigger chain calls -
    // th_ep1_01's `liftdrop_train` is fired by a func_button, and the button is
    // the thing the player presses.  use_passthrough is specifically the "keep it
    // out of the player's search" bit, so a press aimed past a train still reaches
    // whatever is behind it (see the note in sv_customdefs.qc).
    self.use_passthrough = TRUE;

    // Defer to find first stop so all path_corners have spawned.
    self.think     = func_train_find_first;
    self.nextthink = time + 0.1;
};
