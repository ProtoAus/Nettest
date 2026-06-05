//
//  sv_func_trackautochange.qc  –  HL/GoldSrc func_trackautochange
//
//  A moving piece of TRACK that ferries a parked func_train (or
//  func_tracktrain) between two positions — typically the end of an
//  "upper" track and the start of a "lower" track — and relinks the
//  train's path on arrival so it can continue along the new line.
//
//  Setup (HL spec):
//    1. Place the trackautochange brush at the spawn position
//       (TOP unless START_AT_BOTTOM is set).  An origin brush
//       within the brush group sets the rotation pivot.
//    2. Set `train` to the train's targetname.
//    3. Set `toptrack` to the first path_corner the train should
//       head toward when this autochange is at TOP.
//       Set `bottomtrack` to the first path_corner the train should
//       head toward when this autochange is at BOTTOM.
//    4. On the LAST path_corner of each connected track, set
//       "Fire on Dead End" (the corner's `target` chain via the
//       message field, or simply set the corner's `target` to the
//       autochange's targetname).  When the train arrives at that
//       dead-end corner, it fires the autochange's .use, which
//       swaps positions.
//
//  Movement:
//    - `height` qu of vertical travel (negative = down from spawn).
//    - `rotation` total degrees rotated during the move.
//    - `speed` units/sec — used for the linear move; the rotation
//      finishes in the same time so the two are paced together.
//    - Rotation axis: Z by default, X if SF_X_AXIS, Y if SF_Y_AXIS.
//    - Train carry: whatever entity is named in `train` gets snapped
//      to its initial offset relative to the autochange each tick
//      during the move (so it visually rides along).  No corner
//      switching mid-move; the train's path is only relinked on
//      arrival.
//
//  Scope (compatibility, not bug-for-bug):
//    Implemented — height/rotation movement, axis selection,
//    START_AT_BOTTOM, ROTATE_ONLY, AUTO_ACTIVATE_TRAIN, sound
//    enums (reusing the func_train tables), brushsync wire so
//    CSQC sees the motion smoothly, train carry during transit,
//    train path relink + optional auto-resume on arrival.
//    Skipped — RELINK_TRACK flag (docs are "??", and trains
//    already path-walk by name without explicit relink),
//    render-fx / per-entity globalname / zhlt fields.
//

// --- Externs from earlier compile units ---
void()  SV_InitReplicatedSolidBrush;            // sv_brushsync.qc
string(float idx) FuncTrain_MoveSound;          // sv_func_train.qc
string(float idx) FuncTrain_StopSound;          // sv_func_train.qc
void()  func_train_use;                         // sv_func_train.qc

// --- Spawnflags (HL bit layout — must match for .bsp entdata) ---
const float SF_TAC_AUTO_ACTIVATE   = 1;
const float SF_TAC_RELINK_TRACK    = 2;        // unused; docs are "??"
const float SF_TAC_START_AT_BOTTOM = 8;
const float SF_TAC_ROTATE_ONLY     = 16;
const float SF_TAC_X_AXIS          = 64;
const float SF_TAC_Y_AXIS          = 128;

// --- Map keys parsed off entdata ---
.string  train;        // train's targetname (HL key "train")
.string  toptrack;     // first corner on the upper track
.string  bottomtrack;  // first corner on the lower track
.float   height;       // vertical travel — negative = descend
.float   rotation;     // total rotation during the move (degrees)

// --- Runtime state ---
.vector  tac_pos_top;       // origin when at TOP
.vector  tac_pos_bottom;    // origin when at BOTTOM
.vector  tac_ang_top;       // angles when at TOP
.vector  tac_ang_bottom;    // angles when at BOTTOM
.float   tac_state;         // 0 = at TOP, 1 = at BOTTOM, 2 = moving to TOP, 3 = moving to BOTTOM
.entity  tac_train_ent;     // cached train reference (resolved on first use)
.vector  tac_train_ofs;     // train.origin - self.origin captured at start of move
.float   tac_train_ofs_known;

const float TAC_TICK_INTERVAL = 0.05;    // 20 Hz — smooth enough for the carry

// --- Helpers ---

// Returns +1 (axis-x), +1 (axis-y), or +1 (axis-z) vector — the
// avelocity direction.  X / Y spawnflags map to QC's pitch/yaw
// vectors via the standard Quake convention (avelocity_y == yaw,
// avelocity_x == pitch, avelocity_z == roll).
vector() Trackauto_RotAxis =
{
    if (self.spawnflags & SF_TAC_X_AXIS) return '0 0 1';   // roll  (around world X)
    if (self.spawnflags & SF_TAC_Y_AXIS) return '1 0 0';   // pitch (around world Y)
    return '0 1 0';                                          // yaw   (around world Z, default)
};

// Resolve & cache the train this autochange is bound to.  Returns
// world if the `train` key wasn't set or the named entity doesn't
// exist.  The cache is invalidated each .use call so trains spawned
// after us (or removed + respawned via spawn pickups) are picked up.
entity() Trackauto_FindTrain =
{
    if (self.tac_train_ent != world && self.tac_train_ent.targetname == self.train)
        return self.tac_train_ent;
    if (self.train == "") return world;
    self.tac_train_ent = find(world, targetname, self.train);
    return self.tac_train_ent;
};

// Snap the carried train to its locked-in offset.  Called every
// move tick during a transition.
void() Trackauto_CarryTrain =
{
    if (!self.tac_train_ofs_known) return;
    entity t = self.tac_train_ent;
    if (t == world) return;
    // Simple positional carry — the train moves with us but doesn't
    // rotate around our pivot.  Most maps using this entity use Z
    // axis rotation only (lift goes up and yaws to face the new
    // track) so the train's orientation doesn't matter much during
    // the move; the train's own pathing realigns it on the next
    // segment.  X/Y axis rotation is rare; if a map needs the train
    // to barrel-roll with the autochange, the full rotation carry
    // can be added here later.
    setorigin(t, self.origin + self.tac_train_ofs);
    t.angles_y = self.angles_y;
    t.SendFlags = 1;
};

// Sound playback wrappers — silent when the enum maps to "" (idx 0).
void() Trackauto_PlayMoveSound =
{
    string s = FuncTrain_MoveSound(self.movesnd);
    if (s == "") return;
    float vol = self.volume;
    if (vol <= 0) vol = 0.85;
    sound(self, CHAN_BODY, s, vol, ATTN_NORM);
};
void() Trackauto_PlayStopSound =
{
    string s = FuncTrain_StopSound(self.stopsnd);
    if (s == "") return;
    float vol = self.volume;
    if (vol <= 0) vol = 0.85;
    sound(self, CHAN_BODY, s, vol, ATTN_NORM);
};

// Forward decls for the move state machine.
void() trackauto_arrive;
void() trackauto_move_tick;

// Arrival — snap to final position, stop sound, relink train.
// Called when the per-tick distance check sees us within one tick
// of the destination.
void() trackauto_arrive =
{
    // Snap precisely so accumulated tick error doesn't drift.
    vector dest_origin;
    vector dest_angles;
    string track_name;
    if (self.tac_state == 2)              // arriving at TOP
    {
        self.tac_state = 0;
        dest_origin = self.tac_pos_top;
        dest_angles = self.tac_ang_top;
        track_name  = self.toptrack;
    }
    else if (self.tac_state == 3)         // arriving at BOTTOM
    {
        self.tac_state = 1;
        dest_origin = self.tac_pos_bottom;
        dest_angles = self.tac_ang_bottom;
        track_name  = self.bottomtrack;
    }
    else
    {
        // Defensive — arrive() called without an in-flight move.
        // Shouldn't happen; bail without side effects.
        return;
    }

    setorigin(self, dest_origin);
    self.angles    = dest_angles;
    self.velocity  = '0 0 0';
    self.avelocity = '0 0 0';
    self.SendFlags = 1;

    // Final carry snap so the train rests on the autochange.
    Trackauto_CarryTrain();

    self.think     = __NULL__;
    self.nextthink = 0;

    Trackauto_PlayStopSound();

    // Relink train.  At TOP we steer it onto toptrack's first
    // corner; at BOTTOM onto bottomtrack's first corner.  The
    // train itself doesn't move yet — that needs AUTO_ACTIVATE
    // or an external trigger.
    entity t = Trackauto_FindTrain();
    if (t != world && track_name != "")
    {
        entity new_corner = find(world, targetname, track_name);
        if (new_corner != world)
        {
            // Set the train's "current target corner" to the new
            // path start.  func_train uses .train_target as its
            // chase anchor and .target as the next-resolve key, so
            // updating both keeps it consistent whether use() walks
            // forward via FuncTrain_NextCorner or restarts from
            // .target via find_first.
            t.train_target = new_corner;
            t.target = new_corner.targetname;

            if (self.spawnflags & SF_TAC_AUTO_ACTIVATE)
            {
                // Kick the train into motion along the new path.
                // func_train_use handles both the "stopped → start"
                // and "moving → re-resolve" cases.  We invoke it
                // with the train as self so its self-relative
                // references resolve correctly.
                entity saved_self = self;
                self = t;
                func_train_use();
                self = saved_self;
            }
        }
    }

    // Clear carry latch so the next move re-captures the offset.
    self.tac_train_ofs_known = 0;
};

// Per-tick movement think.  Same shape as func_train_move_tick:
// recompute the remaining vector each tick, snap on the last tick
// to avoid overshoot, otherwise re-aim velocity + reschedule.
void() trackauto_move_tick =
{
    vector dest;
    if (self.tac_state == 2)
        dest = self.tac_pos_top;
    else if (self.tac_state == 3)
        dest = self.tac_pos_bottom;
    else
    {
        // Not moving — defensive cleanup, shouldn't happen.
        self.think = __NULL__;
        self.velocity = '0 0 0';
        self.avelocity = '0 0 0';
        return;
    }

    vector delta = dest - self.origin;
    float dist = vlen(delta);
    float spd = self.speed;
    if (spd <= 0) spd = 64;
    float advance = spd * TAC_TICK_INTERVAL;

    if (dist <= 0 || advance * 1.5 >= dist)
    {
        // Snap on the last tick — would overshoot if we keep
        // velocity-driving.  arrive() snaps + relinks.
        trackauto_arrive();
        return;
    }

    self.velocity  = (delta / dist) * spd;
    // avelocity already configured in func_trackautochange_use;
    // keep it as-is.  The engine integrates angles per tick from it.
    self.SendFlags = 1;

    Trackauto_CarryTrain();

    self.think     = trackauto_move_tick;
    self.nextthink = time + TAC_TICK_INTERVAL;
};

// .use — toggle position.  No-op while a move is already in flight
// (re-triggering doesn't queue a return trip; train-driven dead-end
// triggers fire on arrival anyway, not while traveling).
void() func_trackautochange_use =
{
    if (self.tac_state == 2 || self.tac_state == 3)
        return;

    // Compute target side + the linear / angular velocities for
    // the trip.  Move time is derived from the larger of the two
    // distances so a pure-rotation autochange (height=0) still
    // takes a finite, speed-related interval.
    vector target_origin;
    vector target_angles;
    if (self.tac_state == 0)              // at TOP → go to BOTTOM
    {
        self.tac_state = 3;
        target_origin = self.tac_pos_bottom;
        target_angles = self.tac_ang_bottom;
    }
    else                                  // at BOTTOM → go to TOP
    {
        self.tac_state = 2;
        target_origin = self.tac_pos_top;
        target_angles = self.tac_ang_top;
    }

    float dist = vlen(target_origin - self.origin);
    float spd = self.speed;
    if (spd <= 0) spd = 64;

    float move_time;
    if (dist > 0.001)
        move_time = dist / spd;
    else if (self.rotation != 0)
    {
        // Pure rotation — use speed as deg/sec when there's no
        // linear travel (HL spec: "If the Rotate Only flag is set
        // this will be the speed of rotation only").
        move_time = fabs(self.rotation) / spd;
        if (move_time <= 0) move_time = 1;
    }
    else
    {
        // No travel + no rotation = instant arrival.
        move_time = 0.001;
    }

    // Capture the train's offset BEFORE we move so the per-tick
    // carry snaps it relative to our pre-move origin.
    entity t = Trackauto_FindTrain();
    if (t != world)
    {
        self.tac_train_ofs       = t.origin - self.origin;
        self.tac_train_ofs_known = 1;
    }

    self.velocity = (target_origin - self.origin) * (1.0 / move_time);

    // Angular velocity — total angle delta divided by move time,
    // applied along the selected axis.  arrive() snaps to the
    // final angles anyway, so the rate is approximate.
    vector ang_delta = target_angles - self.angles;
    self.avelocity = ang_delta * (1.0 / move_time);

    self.SendFlags = 1;
    Trackauto_PlayMoveSound();

    self.think     = trackauto_move_tick;
    self.nextthink = time + TAC_TICK_INTERVAL;
};

/*QUAKED func_trackautochange (.5 .5 .5) ? AUTO_ACTIVATE RELINK_TRACK x START_AT_BOTTOM ROTATE_ONLY x X_AXIS Y_AXIS
A moving piece of track that ferries a parked train between TOP and
BOTTOM positions + relinks the train's path on arrival.

"train"       targetname of the train to ferry
"toptrack"    first path_corner the train follows when AC is at TOP
"bottomtrack" first path_corner the train follows when AC is at BOTTOM
"height"      vertical travel distance (negative = down)
"rotation"    total rotation in degrees during the move
"speed"       linear units/sec (also rotation deg/sec if ROTATE_ONLY)
"movesnd"     index into HL move-sound enum (0..13)
"stopsnd"     index into HL stop-sound enum (0..8)
"volume"      sound volume (default 0.85)
"targetname"  for being triggered (e.g. via path_corner Fire-on-Dead-End)
*/
void() func_trackautochange =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    self.movetype = MOVETYPE_PUSH;
    self.solid    = SOLID_BSP;

    // Cache top + bottom anchors.  Top is the spawn position UNLESS
    // START_AT_BOTTOM is set, in which case the spawn position is
    // the bottom anchor and TOP is offset upward by +height.
    vector rot_axis = Trackauto_RotAxis();
    vector ang_delta = rot_axis * self.rotation;

    float height_used = (self.spawnflags & SF_TAC_ROTATE_ONLY) ? 0 : self.height;

    if (self.spawnflags & SF_TAC_START_AT_BOTTOM)
    {
        self.tac_pos_bottom = self.origin;
        self.tac_pos_top    = self.origin + '0 0 1' * height_used;
        self.tac_ang_bottom = self.angles;
        self.tac_ang_top    = self.angles + ang_delta;
        self.tac_state      = 1;       // at BOTTOM
    }
    else
    {
        self.tac_pos_top    = self.origin;
        self.tac_pos_bottom = self.origin - '0 0 1' * height_used;
        self.tac_ang_top    = self.angles;
        self.tac_ang_bottom = self.angles - ang_delta;
        self.tac_state      = 0;       // at TOP
    }

    // Hook brushsync so CSQC sees the motion smoothly — same
    // pattern func_train uses for its track section.
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;

    // Sound precaches based on the configured enums.
    string mv = FuncTrain_MoveSound(self.movesnd);
    string sp = FuncTrain_StopSound(self.stopsnd);
    if (mv != "") precache_sound(mv);
    if (sp != "") precache_sound(sp);

    self.use = func_trackautochange_use;
};
