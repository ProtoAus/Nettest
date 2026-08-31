//
//  server/sv_func_pushable.qc  -  func_pushable  (GoldSrc / Sven Co-op)
//
//  "Similar to func_breakable, but this entity can also be pushed and carried
//  by players."  GoldSrc implements it exactly that way - CPushable DERIVES
//  from CBreakable - and this file does the same: the breakable half is
//  func_breakable() called verbatim, and only the physics half is new.
//
//  WHY THE FLAGS NEED TRANSLATING
//  Sven's func_pushable and this mod's func_breakable disagree on two bits:
//      Sven 512  Explosives Only   vs   mod 4    BREAKABLE_ONLY_EXPLOSION
//      Sven 256  1-Hit Break       ==   mod 256  BREAKABLE_INSTANT_CROWBAR  (match)
//  so 512 is folded onto bit 4 before the breakable spawn runs.  Bit 4 is unused
//  in Sven's func_pushable FGD, so nothing is lost by claiming it.
//
//  Sven also does NOT make a named brush trigger-only the way this mod's
//  func_breakable does; in GoldSrc a func_pushable with the Breakable flag is
//  shootable whatever its targetname, and most Sven crates are named (they get
//  fired by map logic).  Left alone, the mod's rule would have made almost
//  every Sven crate indestructible - so the flag that opts back in is set too.
//
//  PHYSICS
//  A replicated brush is MOVETYPE_PUSH, and a MOVETYPE_PUSH entity does NOT
//  collide with the world - the engine integrates its velocity straight through
//  walls (that is fine for doors, which run on rails).  So the crate has to
//  sweep its own hull and CLAMP velocity, never setorigin: the same division of
//  labour func_vehicle uses (sv_func_vehicle.qc, Vehicle_CollideWorld), for the
//  same reason - the engine stays the integrator, we only decide what velocity
//  is legal.
//
//  The think NEVER stops.  A MOVETYPE_PUSH entity with nextthink 0 has its
//  movetime clamped to 0 by WPhys_Physics_Pusher (engine sv_phys.c:1148), which
//  freezes .ltime - and .ltime is the clock nextthink is measured against, so a
//  crate that slept would need its ltime resynced before it could ever wake.
//  Ticking forever at a slow idle rate sidesteps that entirely; the idle body is
//  one tracebox.  For the same reason .blocked must zero velocity: PushMove
//  leaves ltime unadvanced when it is obstructed, and `thinktime > oldltime`
//  then never holds, so a blocked crate whose velocity kept pointing into the
//  obstruction would wedge permanently.
//
//  It stays AXIS-ALIGNED, and cannot reasonably do otherwise: a GoldSrc
//  func_pushable has no origin brush, so its BSP submodel geometry sits at
//  absolute world coordinates with .origin at 0 0 0, and FTE does not re-centre
//  submodels at load (gl_model.c:6480).  Setting .angles on one rotates it about
//  the WORLD origin, not about itself.  That is also why GoldSrc's own pushables
//  never tumble, so this is parity rather than a shortfall.
//
//  BRUSH_TYPE_TRAIN is not a lie of convenience - a pushable is precisely a
//  velocity-driven brush you can stand on, so it wants the carry + geometry-push
//  pass PM_CheckMovingPushers already runs for trains on BOTH sides, and the
//  train branch ships no extra wire fields (cl_brushsync.qc).
//

// Defined later in the compile order.
void(entity c) MovingBrush_AddToList;       // shared/sh_pmove.qc
void(entity c) MovingBrush_RemoveFromList;  // shared/sh_pmove.qc

// Sven "Buoyancy".  GoldSrc had no such key - CPushable::Spawn folds buoyancy
// into pev->skin - so `skin` is accepted as the legacy spelling.
.float buoyancy;
// Sven "Gib model": custom broken-parts model.  func_breakable already has this
// under the name `mdl`, so the key is bridged at spawn rather than reimplemented.
.string gibmodel;
// Parsed, deliberately inert - see the FGD entry, which says so to the mapper:
//   classify / soundlist / displayname
// need systems this mod does not have (monster relationships, per-map sound
// replacement, a HUD info readout).
.float  classify;
// spawnobject is NO LONGER inert - it is an index into the FGD's 39-entry
// pickup table, dispatched by Breakable_SpawnObject when the brush breaks.
// The field itself is declared in sv_customdefs.qc (position 15) rather than
// here (151), because sv_breakable.qc reads it at position 28 and QC can
// forward-declare functions but NOT fields.
//
// .explodemagnitude moved to sv_customdefs.qc for exactly the same reason once
// func_breakable_break started firing the explosion - see the note there.
.string soundlist;
.string displayname;

// Sven spawnflags.
const float PUSH_REPAIRABLE       = 8;
const float PUSH_MONSTERS_IGNORE  = 16;
const float PUSH_SHOW_HUD_INFO    = 32;
const float PUSH_BREAKABLE        = 128;
const float PUSH_INSTANT_BREAK    = 256;
const float PUSH_EXPLOSIVES_ONLY  = 512;
const float PUSH_LIFTABLE         = 1024;

// GoldSrc constants.  MaxSpeed() = 400 - friction, friction clamped to 399 so a
// "400" crate still creeps rather than dividing by nothing (Sven documents 400
// as "unmovable by pushing", and one unit/sec is close enough to unmovable).
const float PUSH_BASE_SPEED    = 400;
const float PUSH_MAX_FRICTION  = 399;
// Touch push scale factors, straight from CPushable::Move.
const float PUSH_FACTOR_GROUND = 1.0;   // toucher on the ground
const float PUSH_FACTOR_WATER  = 0.1;   // airborne toucher, but the crate floats
const float PUSH_FACTOR_OTHER  = 0.25;  // non-player toucher
const float PUSH_SOUND_GAP     = 0.7;   // CPushable::m_soundTime debounce

const float PUSH_TICK_IDLE     = 0.1;   // at rest: one ground probe per tick
const float PUSH_STOP_SPEED    = 4;     // below this we just stop
const float PUSH_GROUND_DECEL  = 6.0;   // per-second velocity decay on the ground
const float PUSH_AIR_DECEL     = 0.4;   // barely any while falling
const float PUSH_WATER_DECEL   = 2.0;

// --- buoyancy --------------------------------------------------------------
// Sven exposes a "Buoyancy" key (GoldSrc folded it into pev->skin) with no
// documented units, so it is read as a DENSITY RATIO through a cvar scale: how
// many times its own weight of water the crate displaces when fully submerged.
// >1 floats and settles at 1/ratio submerged; sv_pushable_buoyancy 0.1 turns
// Sven's default 20 into 2.0 - half submerged, which is what a crate looks like
// in the reference game.  0 sinks, which is also GoldSrc's default.
const float PUSH_BUOY_ACCEL_MAX = 2.0;  // cap on net buoyant accel, in gravities:
                                        // stops a very buoyant crate rocketing out
const float PUSH_BUOY_SPLASH_V  = 60;   // entry speed that earns a splash sound
const float PUSH_REST_V         = 3.0;  // vertical speed below which a floating crate parks
const float PUSH_REST_A         = 0.08; // ...and the net accel (in gravities) that allows it

.float push_maxspeed;
.vector push_spawn_origin;   // restored by the round reset
.vector push_last_sent_org;  // what CSQC was last told — see the SendFlags note in the tick
.vector push_last_sent_vel;
.float push_sound_time;
.float push_jam_check;       // one-shot spawn-time "am I buried?" report, sv_debug_pushable
.float push_moving;          // 1 while published to moving_brush_list
.float push_in_water;        // 1 while any part of the crate is under a waterline

void() func_breakable;                                  // sv_breakable.qc
float(entity playerent, float changedflags) solid_brush_SendEntity;
void(entity ce) FuncPushable_JamCheck;                  // defined beside func_pushable()

// How far the embedded-crate recovery below may move a crate in one frame, in
// either the back-out or the climb.  18 is Quake's and Half-Life's step height,
// and the point of the cap is that no crate in the corpus is 18 units tall - so
// the recovery can never be used to mount another one.
const float PUSH_UNSTICK_STEP = 18;

// World-space centre + half-extents.  A GoldSrc func_pushable usually has NO
// origin brush, so self.origin is '0 0 0' and mins/maxs hold the ABSOLUTE brush
// extents; with an origin brush they are relative instead.  Deriving the hull
// from the midpoint is correct either way, which tracebox(self.origin, mins,
// maxs, ...) is not.
vector() FuncPushable_Center =
{
    return self.origin + (self.mins + self.maxs) * 0.5;
};

// ---------------------------------------------------------------------------
// CRATE VERSUS CRATE, and why tracebox cannot be the one to answer it.
//
// FTE does not sweep the box you hand it against a Q1/HL BSP.  Q1BSP_ChooseHull
// (common/q1bsp.c:1554-1566) quantises the request to one of the three hulls the
// compiler baked - and because sv_compatiblehulls defaults to 1, World_Move
// (server/world.c:2755) skips the best-fit selector and goes straight to that
// size threshold.  Anything wider than 32.1 units gets HULL 2, which in a
// GoldSrc BSP is 64x64x64, and q1bsp.c:1570 anchors it at the REQUESTED MIN
// CORNER rather than centring it.  So a 40-wide crate is swept as a 64-wide
// cube that overhangs its own +X and +Y faces by 24 units.
//
// Every func_pushable on th_ep1_01 is between 40 and 58 units wide, so every one
// of them is traced fat.  Two of them are close enough for that to matter from
// the moment the map loads:
//   *121 x[312,352] y[-233,-193]   vs  *122 x[308,348] y[-192,-152]   - 1 unit apart
//   *324 x[2648,2696] y[-306,-258] vs  *325 x[2708,2756] y[-284,-236] - 12 units apart
// Both pairs are genuinely separated and both read as INTERPENETRATING to the
// trace.  That put the crate down the startsolid arm below on the very first
// shove, where the back-out gate could not be satisfied and the climb gate could
// not be satisfied either (allsolid is OR'd across entities, world.c:2144), so
// the crate simply had its velocity zeroed every frame and could never be pushed
// at all - while the pushbox scrape kept re-triggering for as long as anyone
// leaned on it.  "They slide in and bounce out" and "the sliding sound never
// stops" are both downstream of this one measurement error.
//
// No amount of tuning fixes it, because the error is in the quantisation, not in
// the numbers.  So: hide the other crates from the world sweep, and answer
// crate-vs-crate with an exact swept-AABB test instead.  A func_pushable is an
// axis-aligned box, which is the one shape this is trivial and exact for.
// ---------------------------------------------------------------------------
.float push_saved_solid;

// Result of the last FuncPushable_SweepCrates: fraction along the move at which
// we first touch another crate (1 = clear), and the face normal we hit.
float  push_sweep_frac;
vector push_sweep_normal;
entity push_sweep_ent;

void(entity except, float hide) FuncPushable_MaskOthers =
{
    entity ce = pushable_rider_list;
    while (ce)
    {
        if (ce != except)
        {
            if (hide)
            {
                ce.push_saved_solid = ce.solid;
                ce.solid            = SOLID_NOT;
            }
            else
                ce.solid = ce.push_saved_solid;
        }
        ce = ce.pushable_rider_next;
    }
};

// Sweep our centre point through every other crate's box expanded by our own
// half-extents (the Minkowski sum), which is exactly equivalent to sweeping our
// box against theirs.  Unrolled per axis because QC has no component indexing.
void(entity me, vector center, vector half, vector move) FuncPushable_SweepCrates =
{
    push_sweep_frac   = 1;
    push_sweep_normal = '0 0 0';
    push_sweep_ent    = world;

    entity ce = pushable_rider_list;
    while (ce)
    {
        if (ce != me && !ce.breakable_broken && ce.solid != SOLID_NOT)
        {
            vector lo = ce.absmin - half;
            vector hi = ce.absmax + half;

            // One declaration each: fteqcc scopes locals per FUNCTION, not per block.
            float  tenter = 0, texit = 1, ok = TRUE;
            vector n = '0 0 0';
            float  t1, t2, sw;
            vector cand;

            // X
            if (fabs(move_x) < 0.0001)
            {
                if (center_x < lo_x || center_x > hi_x) ok = FALSE;
            }
            else
            {
                t1 = (lo_x - center_x) / move_x;
                t2 = (hi_x - center_x) / move_x;
                cand = '-1 0 0';
                if (t1 > t2) { sw = t1; t1 = t2; t2 = sw; cand = '1 0 0'; }
                if (t1 > tenter) { tenter = t1; n = cand; }
                if (t2 < texit)  texit = t2;
            }
            // Y
            if (ok)
            {
                if (fabs(move_y) < 0.0001)
                {
                    if (center_y < lo_y || center_y > hi_y) ok = FALSE;
                }
                else
                {
                    t1 = (lo_y - center_y) / move_y;
                    t2 = (hi_y - center_y) / move_y;
                    cand = '0 -1 0';
                    if (t1 > t2) { sw = t1; t1 = t2; t2 = sw; cand = '0 1 0'; }
                    if (t1 > tenter) { tenter = t1; n = cand; }
                    if (t2 < texit)  texit = t2;
                }
            }
            // Z.  Not optional: with the other crates hidden from the world sweep
            // above, this test is now the ONLY thing that lets a crate rest on
            // another crate, so it has to carry the vertical case as well.
            if (ok)
            {
                if (fabs(move_z) < 0.0001)
                {
                    if (center_z < lo_z || center_z > hi_z) ok = FALSE;
                }
                else
                {
                    t1 = (lo_z - center_z) / move_z;
                    t2 = (hi_z - center_z) / move_z;
                    cand = '0 0 -1';
                    if (t1 > t2) { sw = t1; t1 = t2; t2 = sw; cand = '0 0 1'; }
                    if (t1 > tenter) { tenter = t1; n = cand; }
                    if (t2 < texit)  texit = t2;
                }
            }

            if (ok && tenter > texit)  ok = FALSE;

            // ALREADY OVERLAPPING (tenter <= 0 with a valid interval).  This is not
            // hypothetical: the jam-check on th_ep1_01 shows two of its eight crates
            // interpenetrating by a unit from map load, and a crate resting ON
            // another one overlaps the expanded box every single frame by
            // construction.  Reporting it as a hit would jitter a stack; ignoring it
            // outright would let a shove drive one crate straight through the other,
            // because the world sweep can no longer see crates at all.
            //
            // So neither: allow motion that SEPARATES and refuse motion that
            // DEEPENS.  The axis of least penetration is the one to measure against
            // - it is the direction the two boxes are closest to being apart on, and
            // therefore the contact face a person would say they are touching along.
            if (ok && tenter <= 0)
            {
                ok = FALSE;
                float px = (move_x > 0) ? (hi_x - center_x) : (center_x - lo_x);
                float py = (move_y > 0) ? (hi_y - center_y) : (center_y - lo_y);
                float pz = (move_z > 0) ? (hi_z - center_z) : (center_z - lo_z);
                vector on = '0 0 0';
                if (px <= py && px <= pz)      on_x = (move_x > 0) ? -1 : 1;
                else if (py <= pz)             on_y = (move_y > 0) ? -1 : 1;
                else                           on_z = (move_z > 0) ? -1 : 1;
                // Only when the move actually pushes further in.
                if ((move * on) < 0)
                {
                    push_sweep_frac   = 0;
                    push_sweep_normal = on;
                    push_sweep_ent    = ce;
                }
            }

            if (ok && tenter >= push_sweep_frac) ok = FALSE;

            if (ok)
            {
                push_sweep_frac   = tenter;
                push_sweep_normal = n;
                push_sweep_ent    = ce;
            }
        }
        ce = ce.pushable_rider_next;
    }
};

// Sweep the planned move and clip velocity onto whatever it hits, so the crate
// slides along walls instead of tunnelling through them.  MOVE_NOMONSTERS on
// purpose: the player leaning on the crate must not count as an obstruction, or
// pushing it would immediately cancel itself.
void(float dt) FuncPushable_CollideWorld =
{
    vector planned = self.velocity * dt;
    if (planned == '0 0 0')
        return;

    vector half   = (self.maxs - self.mins) * 0.5;
    vector center = FuncPushable_Center();
    vector n      = '0 0 0';    // one declaration: fteqcc scopes locals per FUNCTION

    // EXACT crate-vs-crate first, so the world sweep can be told to ignore crates
    // entirely and stop lying about them.
    FuncPushable_SweepCrates(self, center, half, planned);

    float ss   = self.solid;
    self.solid = SOLID_NOT;                 // never let the sweep hit ourselves
    FuncPushable_MaskOthers(self, TRUE);
    tracebox(center, half * -1, half, center + planned, MOVE_NOMONSTERS, self);
    FuncPushable_MaskOthers(self, FALSE);
    self.solid = ss;

    // A crate blocked by another crate BEFORE anything in the world: clip onto that
    // face and stop.  No slide-and-retest - two boxes meeting flush is a dead stop
    // in GoldSrc too, and re-sweeping would need the whole pass again for no gain.
    // Deliberately NOT gated on the world trace being clean.  Three of th_ep1_01's
    // eight crates come back startsolid from the fat hull (see the jam-check note
    // below), and two of those are the pair that genuinely overlap each other - so
    // requiring a clean world trace here would hand exactly the crate-vs-crate case
    // this exists for to the penetration recovery instead.  An exact box test that
    // says a crate is in the way is better evidence than a quantised one that says
    // everything is.
    if (push_sweep_frac < 1 && push_sweep_frac <= trace_fraction)
    {
        vector cn = push_sweep_normal;
        self.velocity = self.velocity - cn * (self.velocity * cn);
        if (cvar("sv_debug_pushable"))
            dprint(sprintf("[pushable] crate-vs-crate frac=%.3f n=%v\n",
                           push_sweep_frac, cn));
        return;
    }

    // ALREADY INSIDE SOMETHING.  This arm has to come before the fraction test and
    // it is the reason a crate that ever clipped a wall could then travel through
    // anything at all.
    //
    // FTE initialises a trace with fraction 1 and q1bsp.c:1018 returns at
    // `if (trace->allsolid) return false` BEFORE fraction is assigned - so a sweep
    // that begins buried comes back reading exactly like a sweep that hit nothing.
    // The old code took that at face value, returned early, and handed the engine
    // an unclipped velocity; MOVETYPE_PUSH does not collide against the world at
    // all (it is built for doors on rails), so the crate then sailed on. The
    // failure was self-sustaining: one frame of penetration disabled the only
    // thing that could have stopped the next.
    //
    // Same engine quirk, same fix, as the teleport arrival probe at
    // sh_pmove.qc:4702-4719 - trace UP, because up is the direction that leaves
    // solid, and put the crate back on top of whatever it sank into.
    if (trace_startsolid || trace_allsolid)
    {
        // IS IT REALLY BURIED, OR IS THAT THE HULL TALKING?
        //
        // FTE cannot sweep a 42-unit box against a Q1/HL BSP.  Q1BSP_ChooseHull
        // quantises anything wider than 32.1 units to hull 2 - 64x64x64 in a GoldSrc
        // BSP - and anchors it at the requested MIN corner, so every crate on this
        // map is traced as a cube overhanging its own +X/+Y faces by up to 24 units.
        // There is no intermediate hull to fall back to: the choices are a point,
        // 32 wide, or 64 wide.
        //
        // The spawn-time jam-check measures the damage.  On th_ep1_01, THREE of the
        // eight crates come back startsolid, and two of those three are nowhere near
        // anything - they are 42- and 50-wide boxes whose 64-wide probe clips a wall
        // they are merely standing beside.  Treating that as "buried" sent them down
        // the recovery path on the very first shove, where the recovery's own probes
        // use the same fat hull, find no room either, and leave the crate frozen with
        // its velocity zeroed every frame.  A crate that cannot be pushed at all.
        //
        // A point trace is exact - hull 0, no quantisation - so ask it.  If the
        // crate's own centre is in open space and its real box overlaps no other
        // crate, the startsolid is an artefact and the crate is fine.  Fall through
        // to a point-swept move rather than to the recovery: five thin probes along
        // the path (centre plus the four horizontal mid-edges, inset a unit) approximate
        // a box sliding on a floor closely enough, and they are only paid in the
        // artefact case.  It is less conservative than the fat sweep - a corner can
        // clip a pillar - but the fat sweep's alternative here is not moving at all.
        traceline(center, center, MOVE_NOMONSTERS, self);
        float really_stuck = (trace_startsolid || trace_allsolid);
        if (!really_stuck && push_sweep_frac >= 1)
        {
            float bf = 1;
            vector probes = '0 0 0';
            float pi;
            for (pi = 0; pi < 5; pi = pi + 1)
            {
                if      (pi == 1) probes = [half_x - 1, 0, 0];
                else if (pi == 2) probes = [1 - half_x, 0, 0];
                else if (pi == 3) probes = [0, half_y - 1, 0];
                else if (pi == 4) probes = [0, 1 - half_y, 0];
                traceline(center + probes, center + probes + planned, MOVE_NOMONSTERS, self);
                if (!trace_startsolid && trace_fraction < bf)
                {
                    bf = trace_fraction;
                    n  = trace_plane_normal;
                }
            }
            if (bf < 1)
                self.velocity = self.velocity - n * (self.velocity * n);
            if (cvar("sv_debug_pushable") >= 2)
                dprint(sprintf("[pushable] hull artefact at %v - point-swept, frac=%.3f\n",
                               center, bf));
            return;
        }

        vector was = self.velocity;
        self.velocity = '0 0 0';

        // BACK OUT BEFORE CLIMBING, and never climb more than a step.
        //
        // This recovery used to lift by a FULL CRATE HEIGHT in one frame, and
        // upward is the wrong first guess when the thing you are embedded in is
        // the crate you are pushing: the escape it found was the top of the other
        // crate, so a shove into a neighbour ended with one box standing on the
        // other.  That is the reported "func_pushables jump on top of other
        // entities when pushing them" - Half-Life has no such recovery at all and
        // its crates simply refuse to move.
        //
        // Order now matches what actually went wrong: retreat along the reverse of
        // the move that caused the overlap, which un-does the penetration in the
        // axis it happened on and leaves the crate on the floor.  The climb stays
        // as the last resort - a crate that sank into world geometry still has to
        // be able to get out - but capped at PUSH_UNSTICK_STEP, so it can never
        // clear a crate, a barrel or a table in a single frame.
        // TEST THE DESTINATION, NOT THE ROUTE.  This used to sweep from `center`
        // toward center+back and accept the result only `if (!trace_startsolid
        // && !trace_allsolid && ...)` - but startsolid is a property of the START
        // point alone, and the start point here is the very point we just found
        // solid.  The condition was therefore unsatisfiable and the entire back-out
        // was dead code; control always fell through to the climb, which is exactly
        // the "crates jump on top of each other" this block was written to stop.
        //
        // A zero-length probe AT each candidate answers the question that actually
        // matters - is there room over there - and walking outward in 4-unit steps
        // takes the nearest free spot instead of the full 18 every time.
        float freed = FALSE;
        vector back = was;
        back_z = 0;
        if (back != '0 0 0')
        {
            back = normalize(back) * -1;
            float d = 4;
            while (d <= PUSH_UNSTICK_STEP)
            {
                if (!freed)
                {
                    vector cand = center + back * d;
                    self.solid = SOLID_NOT;
                    FuncPushable_MaskOthers(self, TRUE);
                    tracebox(cand, half * -1, half, cand, MOVE_NOMONSTERS, self);
                    FuncPushable_MaskOthers(self, FALSE);
                    self.solid = ss;
                    if (!trace_startsolid && !trace_allsolid)
                    {
                        setorigin(self, self.origin + (cand - center));
                        self.SendFlags = 1;     // a teleport the client must be told about
                        freed = TRUE;
                        if (cvar("sv_debug_pushable"))
                            dprint(sprintf("[pushable] EMBEDDED at %v - backed out %g\n",
                                           self.origin, d));
                    }
                }
                d = d + 4;
            }
        }

        if (!freed)
        {
            // Same correction on the climb: gate on the DESTINATION being clear.
            // `!trace_allsolid` on a probe that starts buried is false whenever the
            // whole segment is inside solid (q1bsp.c:794-806, and world.c:2144 ORs
            // allsolid across every entity clipped), so this arm could equally well
            // never fire - and when it DID fire it moved the crate the full lift,
            // because a buried sweep leaves fraction at its initialised 1.
            float lift = self.maxs_z - self.mins_z;
            if (lift > PUSH_UNSTICK_STEP)
                lift = PUSH_UNSTICK_STEP;
            vector up = center + '0 0 1' * lift;
            self.solid = SOLID_NOT;
            FuncPushable_MaskOthers(self, TRUE);
            tracebox(up, half * -1, half, up, MOVE_NOMONSTERS, self);
            FuncPushable_MaskOthers(self, FALSE);
            self.solid = ss;
            if (!trace_startsolid && !trace_allsolid)
            {
                setorigin(self, self.origin + '0 0 1' * lift);
                self.SendFlags = 1;
                if (cvar("sv_debug_pushable"))
                    dprint(sprintf("[pushable] EMBEDDED at %v - stopped and lifted %g\n",
                                   self.origin, lift));
            }
            else if (cvar("sv_debug_pushable"))
                dprint(sprintf("[pushable] EMBEDDED at %v - stopped, no room to recover\n",
                               self.origin));
        }
        return;
    }

    if (cvar("sv_debug_pushable") >= 3)
        dprint(sprintf("[clip] vel=%v planned=%v frac=%.3f n=%v\n",
                       self.velocity, planned, trace_fraction, trace_plane_normal));

    if (trace_fraction >= 1)
        return;

    // Clip onto the plane (slide), then re-test.  A second block means a corner
    // or a step the crate cannot round - stop dead rather than jitter into it.
    n = trace_plane_normal;
    self.velocity = self.velocity - n * (self.velocity * n);

    planned = self.velocity * dt;
    if (planned == '0 0 0')
        return;
    self.solid = SOLID_NOT;
    FuncPushable_MaskOthers(self, TRUE);
    tracebox(center, half * -1, half, center + planned, MOVE_NOMONSTERS, self);
    FuncPushable_MaskOthers(self, FALSE);
    self.solid = ss;
    if (trace_fraction < 1 || trace_startsolid)
    {
        self.velocity = '0 0 0';
        return;
    }
    // The slide changed direction, so the crate sweep has to be asked again about
    // the NEW one - otherwise sliding along a wall would take the crate straight
    // through the neighbour standing at the end of it.
    FuncPushable_SweepCrates(self, center, half, planned);
    if (push_sweep_frac < 1)
    {
        vector cn2 = push_sweep_normal;
        self.velocity = self.velocity - cn2 * (self.velocity * cn2);
    }
};

// Waterline above `p`, or PUSH_NO_WATER when the point is dry.
//
// PM_ContentsAt (shared/sh_customdefs.qc) rather than pointcontents, so this
// sees BRUSH water as well as baked world water.  func_water is how GoldSrc
// maps normally hold a pool, and de_rats' only crate spawns directly above one
// of its two, which is exactly why it used to sink to the bottom of the sink.
// Both kinds now answer the same query, so the surface is found the same way for
// both: climb out of the liquid in coarse steps, then step back down a unit at a
// time to the last wet sample.  Same shape as Buoy_SurfaceZ in sv_physprop.qc,
// and it reads the mapper's real water plane - no bounding-box approximation,
// and none of the bounds-padding arithmetic an AABB test would have needed.
const float PUSH_NO_WATER   = -999999;
const float PUSH_SCAN_STEP  = 8;
const float PUSH_SCAN_LIMIT = 512;

float(float c) FuncPushable_IsLiquid =
{
    return (c == CONTENT_WATER || c == CONTENT_SLIME || c == CONTENT_LAVA);
};

// Probe points inside the crate's own volume, so the crate has to be taken out
// of the contents query first.  World_ContentsOfLinks ORs together the contents
// of EVERY linked entity containing the point and has no passedict to exclude,
// so a SOLID_BSP crate reports CONTENT_SOLID at its own centre and drowns out
// the water it is floating in.  Reading .solid is how that function decides to
// skip an entity, and it reads the live field rather than anything baked in at
// link time, so flipping it for the duration of the probe is enough - no
// relink, same trick as the sweep traces above.
float(vector p) FuncPushable_ContentsIgnoringSelf =
{
    float ss   = self.solid;
    self.solid = SOLID_NOT;
    float c    = PM_ContentsAt(p);
    self.solid = ss;
    return c;
};

float(vector p) FuncPushable_WaterSurfaceAt =
{
    if (!FuncPushable_IsLiquid(FuncPushable_ContentsIgnoringSelf(p)))
        return PUSH_NO_WATER;

    // Coarse: climb until we leave the liquid, remembering the last wet sample.
    vector s   = p;
    float  wet = p_z;
    float  dry = 0;
    float  climbed = 0;
    while (climbed < PUSH_SCAN_LIMIT)
    {
        s_z     = s_z + PUSH_SCAN_STEP;
        climbed = climbed + PUSH_SCAN_STEP;
        if (!FuncPushable_IsLiquid(FuncPushable_ContentsIgnoringSelf(s)))
            break;
        wet = s_z;
    }
    dry = s_z;

    // Fine: bisect the wet/dry bracket.  Stepping down a unit at a time (the
    // obvious version) quantises the answer to wherever the scan happened to
    // start, so the reported waterline SLID WITH THE CRATE as it bobbed -- a
    // moving target for a plane the mapper drew once.  Eight halvings pin an
    // 8-unit bracket to about 0.03qu, which is exact enough to be stationary.
    float i = 0;
    while (i < 8)
    {
        float mid = (wet + dry) * 0.5;
        s_z = mid;
        if (FuncPushable_IsLiquid(FuncPushable_ContentsIgnoringSelf(s)))
            wet = mid;
        else
            dry = mid;
        i = i + 1;
    }
    return wet;
};

// TRUE when something solid is within a unit below the crate.
float() FuncPushable_OnGround =
{
    vector half   = (self.maxs - self.mins) * 0.5;
    vector center = FuncPushable_Center();
    float  ss     = self.solid;
    self.solid    = SOLID_NOT;
    tracebox(center, half * -1, half, center - '0 0 1', MOVE_NOMONSTERS, self);
    self.solid    = ss;
    return (trace_fraction < 1 || trace_startsolid);
};

void() func_pushable_tick =
{
    // Destroyed: nothing left to simulate, and rescheduling here would be a
    // per-frame busy loop.  func_breakable_break drops the brush to
    // MOVETYPE_NONE, whose think clock is world `time` while .ltime freezes -
    // so an ltime-based nextthink lands permanently in the past and the engine
    // re-fires the think every frame until the round reset re-arms it.
    if (self.breakable_broken)
    {
        if (self.push_moving)
        {
            MovingBrush_RemoveFromList(self);
            self.push_moving = 0;
        }
        self.velocity  = '0 0 0';
        self.nextthink = 0;
        return;
    }

    float dt   = FuncTrain_TickInterval();
    float grav = cvar("sv_gravity");  if (grav <= 0) grav = 800;

    vector center = FuncPushable_Center();
    float  half_z = (self.maxs_z - self.mins_z) * 0.5;
    float  bottom = center_z - half_z;
    float  height = half_z * 2;
    if (height < 1) height = 1;

    // Submerged FRACTION, not a boolean - a crate straddling the waterline has
    // to feel the part of itself that is actually under it, or it can never
    // settle: full buoyancy right up to the surface then none at all above it is
    // a step function, and a step function oscillates.
    float surf = FuncPushable_WaterSurfaceAt(center);
    if (surf == PUSH_NO_WATER)
        surf = FuncPushable_WaterSurfaceAt(center - '0 0 1' * (half_z - 1));  // bobbing: centre may be dry while the base is wet
    float submerged = 0;
    if (surf != PUSH_NO_WATER && surf > bottom)
        submerged = bound(0, (surf - bottom) / height, 1);

    float was_wet      = self.push_in_water;
    self.push_in_water = (submerged > 0);
    float in_water     = self.push_in_water;

    float grounded = FuncPushable_OnGround();

    // Vertical.  GoldSrc gets floating from the engine's FL_FLOAT handling of
    // pev->skin, which FTE has no equivalent for, so this is a real (if small)
    // buoyancy model rather than a transcription: net acceleration from the
    // displaced fraction, capped, plus damping so it comes to rest.
    float buoy_a = 0;
    if (submerged > 0)
    {
        float ratio = self.buoyancy * cvar("sv_pushable_buoyancy");
        buoy_a = grav * (submerged * ratio - 1);
        if (buoy_a >  grav * PUSH_BUOY_ACCEL_MAX) buoy_a =  grav * PUSH_BUOY_ACCEL_MAX;
        if (buoy_a < -grav) buoy_a = -grav;          // never sink faster than free-fall
        self.velocity_z = self.velocity_z + buoy_a * dt;

        // Damping as a RATIO, not a fixed coefficient.  Buoyancy is a spring:
        // the restoring accel changes by grav*ratio/height per unit of sink, so
        // the natural frequency is sqrt(grav*ratio/height) - which varies with
        // how tall and how buoyant each crate is.  A hardcoded drag constant is
        // therefore critically damped for exactly one crate and badly
        // under-damped for the rest (de_rats' 24-unit crate at buoyancy 25 came
        // out at zeta 0.09 - about ten visible bobs).  Deriving the coefficient
        // from the spring keeps every crate at the SAME feel:
        // sv_pushable_buoyancy_damping 1 = dead stop, 0.35 = a couple of bobs.
        // Same idea, and the same cvar spelling, as sv_prop_buoyancy_damping.
        float omega = sqrt(grav * ratio / height);
        float zeta  = cvar("sv_pushable_buoyancy_damping");
        self.velocity_z = self.velocity_z
                        - self.velocity_z * bound(0, 2 * zeta * omega * submerged * dt, 1);

        // Park it at equilibrium.  Damping alone only ever ASYMPTOTES to rest, so
        // without this the crate keeps a few units/sec of residual bob forever -
        // which would hold it at the fast tick rate and dirty the brushsync wire
        // every single tick for a crate that visually is not moving.
        if (fabs(self.velocity_z) < PUSH_REST_V && fabs(buoy_a) < grav * PUSH_REST_A)
            self.velocity_z = 0;
    }
    else if (!grounded)
        self.velocity_z = self.velocity_z - grav * dt;

    // Resting on something wins over a downward pull, but NOT over buoyancy -
    // a crate sitting on the bottom of a pool has to be able to rise off it.
    if (grounded && self.velocity_z < 0)
        self.velocity_z = 0;

    // Splash on entry, once, and only when it arrives with some speed - a crate
    // drifting across a waterline should be silent.
    if (in_water && !was_wet && fabs(self.velocity_z) > PUSH_BUOY_SPLASH_V)
        sound(self, CHAN_BODY, sprintf("player/pl_slosh%g.wav", floor(random() * 4) + 1),
              0.8, ATTN_NORM);

    // Horizontal decay.  GoldSrc leans on MOVETYPE_PUSHSTEP's engine friction;
    // FTE has no PUSHSTEP, so the crate damps itself.
    float decel = PUSH_AIR_DECEL;
    if (in_water)       decel = PUSH_WATER_DECEL;
    else if (grounded)  decel = PUSH_GROUND_DECEL;

    vector hv = self.velocity;  hv_z = 0;
    float  hs = vlen(hv);
    if (hs > 0)
    {
        float ns = hs - hs * decel * dt;
        if (ns < PUSH_STOP_SPEED)
            ns = 0;
        hv = (ns > 0) ? (hv * (ns / hs)) : '0 0 0';
        self.velocity_x = hv_x;
        self.velocity_y = hv_y;
    }

    FuncPushable_CollideWorld(dt);

    // Publish while in transit so the carry + geometry-push pass runs against
    // the player on both sides; drop out when parked so it costs nothing.
    float moving = (self.velocity != '0 0 0');
    if (moving != self.push_moving)
    {
        if (moving) MovingBrush_AddToList(self);
        else        MovingBrush_RemoveFromList(self);
        self.push_moving = moving;
    }

    // SHIP THE STOP, AND THAT IS THE "SLIDE IN AND BOUNCE OUT".
    //
    // This was `if (moving) self.SendFlags = 1;`, so on the frame the crate stopped
    // - the one frame whose contents the client most needs - `moving` was already 0
    // and nothing was sent.  SV_ProcessSendFlags only re-transmits a CSQC entity when
    // QC dirties SendFlags (sv_ents.c:4571); setorigin alone never does, and the
    // entity carries PVSF_NOREMOVE, so there is no other corrective path at all.
    //
    // The client meanwhile extrapolates: cl_brushsync.qc:287 advances the replica by
    // its last known velocity every frame. So a crate whose velocity was zeroed in one
    // step - which is precisely what a collision does, in FuncPushable_Move, from
    // PlayerPreThink, outside this tick entirely - leaves the client coasting the last
    // transmitted speed into the obstruction and then snapping back when some later
    // event finally dirties the flag.  Worse, cl_brushsync.qc:694 keeps a crate with
    // non-zero wire velocity on moving_brush_list, so sh_pmove's carry and geometry
    // push keep acting on the locally predicted player with a phantom velocity the
    // server does not have.
    //
    // Comparing against what was last SENT covers every writer - the tick, the
    // interaction poll, and the two unstick teleports above - rather than only the
    // ones that remember to dirty the flag.  A resting crate compares equal and costs
    // nothing; the decay path already snaps to zero below PUSH_STOP_SPEED so this
    // cannot chatter on a micro-jitter.
    if (self.origin != self.push_last_sent_org || self.velocity != self.push_last_sent_vel)
    {
        self.SendFlags          = 1;
        self.push_last_sent_org = self.origin;
        self.push_last_sent_vel = self.velocity;
    }

    if (self.push_jam_check > 0 && time >= self.push_jam_check)
    {
        self.push_jam_check = 0;
        if (cvar("sv_debug_pushable"))
            FuncPushable_JamCheck(self);
    }

    // sv_debug_pushable: the settle behaviour (does it land, does it jitter on
    // the floor, does it float or sink) is the part of this that a headless
    // server CAN be asked about, so make it askable.  Same idiom as
    // sv_debug_func_train / sv_debug_use.  Two lines because fteqcc caps
    // varargs at 8.
    if (cvar("sv_debug_pushable"))
    {
        dprint(sprintf("[pushable] t=%g org=%v vel=%v ground=%g\n",
                       time, self.origin, self.velocity, grounded));
        dprint(sprintf("           sub=%.2f surf=%g bottom=%g maxspd=%g buoy=%g\n",
                       submerged, (surf == PUSH_NO_WATER) ? 0 : surf,
                       bottom, self.push_maxspeed, self.buoyancy));
    }

    self.think     = func_pushable_tick;
    self.nextthink = self.ltime + (moving ? dt : PUSH_TICK_IDLE);
};

// THE SHOVE IS TAKEN FROM INTENT, NOT FROM RESOLVED VELOCITY.
//
// GoldSrc reads `pevToucher->button` inside CPushable::Move, and this file used to
// substitute the toucher's own velocity because "the mod has no server-side
// movement-key state".  It does - and it has to be used, because the velocity is
// the one number that is guaranteed to be WRONG here.  The crate is SOLID_BSP, so
// by the time anything downstream of PM_PlayerMove looks at the player, the pmove
// has already clipped the into-the-crate component out (sh_pmove.qc:5701 writes the
// resolved value back).  A player walking flat into a crate therefore has ~0
// velocity toward it, which fails the old `vlen(tv) < 16` gate outright and, even
// with the gate removed, multiplies to a zero shove.
//
// So the caller passes what the player ASKED for.  FuncPushable_TickInteraction
// reads it from input_movevalues in PlayerPreThink, which runs once per usercmd
// immediately before the pmove that cancels it.
//
// `intent` is a world-space horizontal wish velocity.  '0 0 0' means "use the
// toucher's own velocity", which is what the non-player and rider paths still want -
// func_pushable_touch is still live for monsters, which are MOVETYPE_STEP and do
// generate real engine impacts.
vector funcpush_intent;

void(entity toucher, float push) FuncPushable_Move =
{
    if (!toucher || toucher == world)
        return;

    vector shove = funcpush_intent;
    if (shove == '0 0 0')
        shove = toucher.velocity;
    shove_z = 0;

    // Standing ON the crate is not pushing it - GoldSrc only lets a rider
    // transfer vertical motion, and only while it floats.  Gate on being IN
    // water rather than on the buoyancy key: a floatable crate sitting on dry
    // ground should not sink under someone's weight.
    if ((toucher.flags & FL_ONGROUND) && toucher.groundentity == self)
    {
        if (self.push_in_water)
            self.velocity_z = self.velocity_z + toucher.velocity_z * 0.1;
        return;
    }

    float is_player = (toucher.flags & FL_CLIENT) != 0;
    float factor;
    if (is_player)
    {
        if (!(toucher.flags & FL_ONGROUND))
        {
            // Jumping/falling players do not shove crates around - but a
            // swimmer pushing a raft does, which is the whole point of a
            // floating crate.
            if (!self.push_in_water)
                return;
            factor = PUSH_FACTOR_WATER;
        }
        else
            factor = PUSH_FACTOR_GROUND;

        // GoldSrc's own floor, asked of the intent rather than the aftermath:
        // `if ( pActivator->pev->velocity != g_vecZero )` (func_break.cpp:905).
        if (vlen(shove) < 16)
            return;
    }
    else
        factor = PUSH_FACTOR_OTHER;

    // RATE-NORMALISE THE SHOVE, or cl_cmdrate is a strength stat.
    //
    // This poll runs once per USERCMD, not once per server frame, and it applied the
    // full factor every time - so a player sending 100 cmd/s shoved a crate roughly
    // 1.6x harder per physics frame than one sending 60, and either way the crate
    // reached its cap within two commands with no ramp at all.  That instant snap to
    // full speed is why there was no felt resistance: nothing about pushing a crate
    // ever cost the player anything.
    //
    // GoldSrc has the same problem and the same shape of fix - CPushable::Move scales
    // by `gpGlobals->frametime * sv_pushable_fixed_tick_fudge` (func_break.cpp:967,
    // default 15).  input_timelength is this command's own duration, which is exactly
    // the quantity that belongs here; the guard covers a hitched or malformed command
    // and the +use pull path, where it may not be meaningful.
    float cmddt = input_timelength;
    if (cmddt <= 0 || cmddt > 0.25)
        cmddt = FuncTrain_TickInterval();
    float fudge = cvar("sv_pushable_tick_fudge");
    if (fudge <= 0) fudge = 15;
    factor = factor * bound(0, cmddt * fudge, 1);

    self.velocity_x = self.velocity_x + shove_x * factor;
    self.velocity_y = self.velocity_y + shove_y * factor;

    vector hv = self.velocity;  hv_z = 0;
    float  len = vlen(hv);
    // UNCONDITIONAL, as the SDK's is (func_break.cpp:978-983).  The `push &&` gate
    // meant the +use PULL path - FuncPushable_Move(player, 0) - had no cap at all,
    // and it adds up to sv_maxspeed per usercmd against only a 6/s exponential
    // decay, so a crate could be dragged to arbitrary speed.
    if (len > self.push_maxspeed)
    {
        self.velocity_x = self.velocity_x * self.push_maxspeed / len;
        self.velocity_y = self.velocity_y * self.push_maxspeed / len;
        len = self.push_maxspeed;
    }

    if (is_player)
    {
        // NO VELOCITY GLUE.  GoldSrc writes the crate's speed back onto the pusher
        // (func_break.cpp:990) because two engine-moved bodies would otherwise
        // interpenetrate while the push resolves.  Here the crate is genuinely
        // SOLID_BSP on BOTH sides - the wall already does that job - and the write
        // would be an unpredicted stamp on the authoritative player velocity, every
        // frame, clamping them to as little as 60 u/s on a heavy crate while CSQC
        // keeps predicting full walk speed.  That is a guaranteed per-frame reconcile
        // error, i.e. the exact rubber-band this file is trying not to cause.
        //
        // THE PUSHBACK IS IN push_maxspeed INSTEAD.  See func_pushable() below: the
        // cap is now derived from sv_maxspeed so a crate is always the slower body,
        // and the player is therefore braked by their OWN collision with a SOLID_BSP
        // brush - a collision CSQC already predicts identically, so it costs no
        // reconcile error at all.  A heavier crate (higher "friction") feels heavier
        // for free, which is what the glue was for.
    }

    // CLIP WHAT WE JUST ADDED, BEFORE THE ENGINE EVER SEES IT.
    //
    // This is the fix for "crates can be pushed through walls and through each
    // other", and the ordering is the entire explanation.  Per frame, FTE runs:
    //
    //   1. SV_RunClients  -> PlayerPreThink -> FuncPushable_TickInteraction -> here,
    //                        which ADDS the shove to .velocity
    //   2. SV_Physics     -> WPhys_Physics_Pusher -> WPhys_PushMove, which MOVES the
    //                        crate by that velocity
    //   3. ...and only THEN, at the bottom of the same function, runs the think -
    //                        func_pushable_tick, where FuncPushable_CollideWorld
    //                        clipped the velocity
    //
    // So the clip was always one full step behind the move it was meant to
    // authorise.  A crate parked flush against a wall had its velocity zeroed by
    // the tick, then re-armed to full push speed by step 1, and step 2 drove it
    // ~4 units into the brush before step 3 zeroed it again - about 250 units per
    // second of steady penetration, for as long as the player kept walking.  The
    // tick was doing its job perfectly and could never win.
    //
    // MOVETYPE_PUSH is why there is no engine backstop: a pusher is assumed to be a
    // door or a platform driven along a path the QC already validated, so it does
    // not collide against the world, and it ignores other SOLID_BSP pushers
    // entirely - which is the same sentence read twice and covers both halves of
    // the report.
    //
    // Clipping here closes the gap: whatever this function hands to .velocity has
    // been swept against the world and against every other crate first.  The tick's
    // own call stays where it is, because gravity and buoyancy also write velocity
    // and they arrive by a different route.
    FuncPushable_CollideWorld(FuncTrain_TickInterval());

    // THE SLIDE SOUND, AND IT HAS TO BE AFTER THE CLIP.
    //
    // The debris/pushbox wavs are the right ones and 0.7 s is the SDK's debounce
    // (func_break.cpp:996-1008), but two of the SDK's gates were missing and both
    // matter more than they look:
    //
    //   * HL tests `length > 0 && FBitSet(pev->flags, FL_ONGROUND)`.  Ours tested a
    //     `len` taken BEFORE FuncPushable_CollideWorld had clipped the velocity, and
    //     tested nothing about the ground - so a crate that could not move an inch
    //     (wedged against a wall, or, before the fix above, spuriously interpenetrating
    //     its neighbour) still reported a full push speed and scraped.
    //   * HL has an else-branch that CUTS the sound.  Ours did not, and the samples
    //     are 1.17-1.20 s long re-triggered every 0.7 s - so consecutive plays overlap
    //     and replace each other on the same channel, which is a seamless, permanent
    //     scrape rather than a repeating one.  That is the "continuous scraping sound"
    //     in the report, and on th_ep1_01 it was reachable simply by leaning on *121
    //     or *324, the two crates the hull quantisation had jammed from map load.
    //
    // The cut is a null sample rather than stopsound(): this file's sibling
    // PhysFiles_StopScrape (sv_physprop.qc) documents at length why stopsound never
    // reaches a client - cl_parse.c:5616 bails on the precache lookup before it can
    // reach the stop branch - and why an empty-string sound() never leaves the server.
    // A real sample on the same entity and channel is the only cancel that works, and
    // SV_StartSound already forces SOLID_BSP sounds reliable (sv_send.c:1367-1377), so
    // this one cannot be lost to the PHS the way the physprop scrape could.
    if (is_player && time - self.push_sound_time > PUSH_SOUND_GAP)
    {
        self.push_sound_time = time;
        vector pv = self.velocity;  pv_z = 0;
        if (vlen(pv) > 1 && FuncPushable_OnGround())
            sound(self, CHAN_WEAPON,
                  sprintf("debris/pushbox%g.wav", floor(random() * 3) + 1),
                  0.5, ATTN_NORM);
        else
            sound(self, CHAN_WEAPON, "sounds/null.wav", 1, ATTN_NORM);
    }

    // Wake the tick immediately rather than waiting out the idle interval.
    if (self.velocity != '0 0 0' && self.nextthink > self.ltime + FuncTrain_TickInterval())
        self.nextthink = self.ltime + FuncTrain_TickInterval();
};

void() func_pushable_touch =
{
    FuncPushable_Move(other, 1);
};

// CPushable::Use - a trigger breaks it (when breakable), a player shoves it.
//
// GoldSrc splits on `pActivator->IsPlayer()`, which a BUTTON chain also
// satisfies: the button forwards the pressing player as the activator, so a
// mapper's trigger->pushable link gets read as a shove.  sv_use_is_player_direct
// (set only inside SV_PlayerTryUse, cleared by Trigger_UseTargets) is the same
// question asked accurately, so the chain breaks it and a hand on the crate
// pushes it.
void() func_pushable_use =
{
    if (!sv_use_is_player_direct)
    {
        if ((self.spawnflags & PUSH_BREAKABLE) && self.on_killed)
            self.on_killed();
        return;
    }
    if (activator && (activator.flags & FL_CLIENT) && activator.velocity != '0 0 0')
        FuncPushable_Move(activator, 0);
};

// ---------------------------------------------------------------------------
// THE PUSH POLL.  This is what makes a crate pushable at all.
//
// GoldSrc gets its push from the ENGINE: CPushable is SOLID_BBOX + MOVETYPE_PUSHSTEP
// (func_break.cpp:827-828), so a moving player generates a real SV_Impact pair and
// CPushable::Touch runs.  This mod's players are MOVETYPE_NONE running the QC pmove
// (sv_player.qc), so the engine produces no impact pairs for them at all, and the
// substitute dispatcher - SV_CheckTouchTriggers, sv_use.qc:404 - only knows
// FL_MONSTER, SOLID_TRIGGER and classname "func_button".  A SOLID_BSP crate matches
// none of the three, so func_pushable_touch has never once been called by a player
// walking into one.  That is the whole of the reported bug.
//
// Teaching that dispatcher about pushables would NOT have fixed it: it runs after
// PM_PlayerMove, which has already cancelled the velocity into the crate.  See the
// note above FuncPushable_Move.  So the poll lives in PlayerPreThink instead, which
// runs once per usercmd immediately BEFORE the pmove, with input_movevalues and
// input_buttons set for that command - the one place the intent still exists.
//
// This is the fifth user of that pattern: Momentary_TickInteraction (sv_momentary.qc),
// Charger_TickInteraction, C4_TickDefuseInteraction and TrackTrain_DriverTick already
// run there for the same reason.  GoldSrc's name for the requirement is
// FCAP_CONTINUOUS_USE, which CPushable::ObjectCaps returns (func_break.cpp:790).
// ---------------------------------------------------------------------------

// sh_pmove.qc:45 owns PM_BTN_USE and compiles after us - mirror the literal, the
// same way sv_momentary.qc:83 and sv_chargers.qc do.
const float PUSH_BTN_USE = 128;

// How close counts as contact, for both the forward sweep and the flush-contact
// fallback.  Small on purpose: this is "touching", not "nearby".
const float PUSH_PROBE_DIST = 6;

void(entity player) FuncPushable_TickInteraction =
{
    if (player.health <= 0)
        return;
    if (!pushable_rider_list)
        return;                 // no crates on this map: the whole poll is free

    // WHAT THE PLAYER ASKED FOR, in world space, before the wall takes it away.
    makevectors(player.v_angle);
    vector wish = v_forward * input_movevalues_x + v_right * input_movevalues_y;
    wish_z = 0;

    float wl = vlen(wish);
    if (wl < 16)
        return;                 // standing still: leaning, not pushing

    // Clamp to a walk.  input_movevalues carries the client's cl_forwardspeed, which
    // is a client cvar - without this a raised one would shove harder than a person
    // can, and the crate's own push_maxspeed clamp is applied AFTER the factor.
    float maxspd = cvar("sv_maxspeed");
    if (maxspd <= 0) maxspd = 320;
    if (wl > maxspd)
        wish = wish * (maxspd / wl);

    // TWO PATHS, AND THEY SELECT THEIR TARGET DIFFERENTLY - because in GoldSrc they
    // are two different functions.  CPushable::Touch is CONTACT (the engine hands it
    // whatever you walked into) and pushes; CPushable::Use is AIM (the +use trace
    // picks it) and pulls.  Holding +use you walk BACKWARDS, so a probe along the
    // wish vector would be pointing away from the crate and find nothing - the pull
    // has to be selected by where you are looking.
    float  pulling = (input_buttons & PUSH_BTN_USE) != 0;
    entity target  = world;

    if (pulling)
    {
        // 96 units from the eye, matching SV_PlayerTryUse's reach.  That file
        // compiles after us (sv_progs.src:227 vs :214) so the constant is mirrored
        // rather than shared.
        makevectors(player.v_angle);
        vector eye = player.origin + player.view_ofs;
        traceline(eye, eye + v_forward * 96, MOVE_NORMAL, player);
    }
    else
    {
        // DIRECTIONAL, not a radius sweep.  A plain findradius + box test (what the
        // func_button arm of SV_CheckTouchTriggers does) fires on a crate you are
        // merely walking PAST, and Move adds the shove componentwise - so that reads
        // as a sideways nudge of a crate you never touched.  Sweeping the player's
        // own hull a few units along the wish vector asks what the engine's touch
        // would have answered: what am I leaning on, in the direction I am pushing.
        tracebox(player.origin, player.mins, player.maxs,
                 player.origin + normalize(wish) * PUSH_PROBE_DIST, MOVE_NORMAL, player);
    }

    if (trace_ent.classname == "func_pushable" && !trace_ent.breakable_broken)
        target = trace_ent;

    // SECOND ARM: already in contact.  The sweep answers "am I about to walk into
    // one", which misses the case that matters most - the player has ALREADY been
    // stopped by the crate, so their hull is flush against it and a forward sweep
    // can return fraction 0 with trace_ent set to whatever the engine resolved
    // first.  GoldSrc has no such gap because its touch is bbox overlap, not a
    // sweep, so match that: any crate whose box is within the probe distance of the
    // player's box AND lies in the direction being pushed.  The direction gate is
    // what keeps this from becoming the sideways-nudge findradius above.
    if (!target && !pulling)
    {
        vector wdir = normalize(wish);
        // The spawn-time list, NOT findchain.  This arm runs on every frame that
        // every alive player is moving and not already touching a crate - i.e.
        // almost always - so a findchain here would be a full edict scan per player
        // per frame on a 32-slot server.  The list is built in func_pushable()
        // for the rider carry (sv_platform_carry.qc) and is empty on the many maps
        // with no pushables at all, which makes this whole arm free there.
        entity ce   = pushable_rider_list;
        float  bestd = PUSH_PROBE_DIST;
        while (ce)
        {
            if (!ce.breakable_broken && ce.solid != SOLID_NOT)
            {
                // Gap between the two AABBs, per axis; 0 on an axis that overlaps.
                vector g = '0 0 0';
                if      (ce.absmin_x > player.absmax_x) g_x = ce.absmin_x - player.absmax_x;
                else if (ce.absmax_x < player.absmin_x) g_x = ce.absmax_x - player.absmin_x;
                if      (ce.absmin_y > player.absmax_y) g_y = ce.absmin_y - player.absmax_y;
                else if (ce.absmax_y < player.absmin_y) g_y = ce.absmax_y - player.absmin_y;
                if      (ce.absmin_z > player.absmax_z) g_z = ce.absmin_z - player.absmax_z;
                else if (ce.absmax_z < player.absmin_z) g_z = ce.absmax_z - player.absmin_z;

                float gd = vlen(g);
                if (gd <= bestd)
                {
                    // Is it the way I am pushing?  Compare against the horizontal
                    // offset to the crate's centre, which is the only direction
                    // information a flush contact still carries.
                    vector to_c = ((ce.absmin + ce.absmax) * 0.5) - player.origin;
                    to_c_z = 0;
                    if (vlen(to_c) < 1 || (normalize(to_c) * wdir) > 0.4)
                    {
                        bestd  = gd;
                        target = ce;
                    }
                }
            }
            ce = ce.pushable_rider_next;
        }
    }

    // Printed on every ACTIVE poll, not just on a hit.  "the poll never ran" and
    // "the poll ran and found nothing to push" are the two failure modes here and
    // they are indistinguishable from a log that only speaks on success - which is
    // the same trap cl_monstertrace.qc's header describes falling into.
    if (cvar("sv_debug_pushable"))
    {
        // Nearest crate, so "the poll found nothing" can be told apart from "there
        // was nothing to find".  Box distance, not origin distance: a GoldSrc
        // submodel's .origin is '0 0 0'.
        float nd = 999999;
        entity ne = pushable_rider_list;
        while (ne)
        {
            vector cc = (ne.absmin + ne.absmax) * 0.5;
            float  d  = vlen(cc - player.origin);
            if (d < nd) nd = d;
            ne = ne.pushable_rider_next;
        }
        dprint(sprintf("[pushable] poll wish=%v probe=\"%s\" near=%.0f target=%g\n",
                       wish, (trace_ent == world) ? "world" : trace_ent.classname,
                       nd, (target != world) ? num_for_edict(target) : 0));
    }

    // sv_debug_pushable 2 = FORCE: ignore contact and shove the nearest crate
    // within 512 units.  Same idea, and the same spelling, as
    // r_shadows_propshadows_debug 2 - it exists so the SHOVE half (intent -> Move
    // -> velocity -> the crate's own tick) can be measured on a headless server,
    // where nothing can be made to walk into a crate on purpose.
    if (!target && cvar("sv_debug_pushable") >= 2)
    {
        entity fe = pushable_rider_list;
        float  fd = 512;
        while (fe)
        {
            if (!fe.breakable_broken)
            {
                float fdist = vlen(((fe.absmin + fe.absmax) * 0.5) - player.origin);
                if (fdist < fd) { fd = fdist; target = fe; }
            }
            fe = fe.pushable_rider_next;
        }
        if (target)
            dprint(sprintf("[pushable] FORCE target ent=%g at %.0f units\n",
                           num_for_edict(target), fd));
    }

    if (!target)
        return;

    // The shove is the player's own movement direction in BOTH cases - GoldSrc's Use
    // is `Move(pActivator, 0)`, not a reversed vector, so a crate follows you out
    // because you are walking away from it while holding the key.  Only the `push`
    // flag differs, and with it the max-speed clamp.
    entity oself = self;
    self = target;
    funcpush_intent = wish;
    FuncPushable_Move(player, pulling ? 0 : 1);
    funcpush_intent = '0 0 0';
    self = oself;

    if (cvar("sv_debug_pushable"))
        dprint(sprintf("[pushable]      shoved \"%s\" vel=%v\n",
                       target.targetname, target.velocity));
};

// PushMove leaves .ltime unadvanced while obstructed, and the think only fires
// when thinktime > oldltime - so a crate that kept driving into whatever blocked
// it would wedge forever.  Dropping the velocity lets the next frame's zero-
// length push succeed, ltime advance, and the think resume.
void() func_pushable_blocked =
{
    self.velocity = '0 0 0';
    // Dirty the flag here too.  This runs from the engine's blocked callback, i.e.
    // outside the tick, so without it the client keeps extrapolating the velocity
    // that has just been cancelled until the tick next compares - one frame late,
    // and much worse if the crate is already parked and ticking at PUSH_TICK_IDLE.
    self.SendFlags = 1;
};

/*QUAKED func_pushable (0 .5 .8) ? x x x REPAIRABLE MONSTERS_IGNORE SHOW_HUD_INFO x BREAKABLE INSTANT_BREAK EXPLOSIVES_ONLY LIFTABLE
Sven Co-op / GoldSrc pushable crate: a func_breakable you can shove around.
Walk into it to push it, or +use it while moving to nudge it sideways.
Falls under gravity and floats on water (baked BSP water and func_water alike).

  "health"          hit points (needs the BREAKABLE flag to matter)
  "material"        0=Glass 1=Wood 2=Metal 3=Flesh 4=CinderBlock 5=CeilingTile
                     6=Computer 7=UnbreakableGlass 8=Rocks
  "friction"        0-400, higher is heavier.  Max push speed is 400 - friction,
                     so 400 is effectively unpushable (Sven's own advice).
  "buoyancy"        how well it floats; 0 sinks (GoldSrc spelt this "skin")
  "gibmodel"        custom debris model (bridged onto func_breakable's "mdl")
  "target"/"delay"  fired when it breaks
  "rendermode" "renderamt" "rendercolor" "renderfx"  as func_wall

Flags:
  8    Repairable      PARSED, NOT IMPLEMENTED (no wrench-repair system)
  16   Monsters Ignore PARSED, NOT IMPLEMENTED (no monster AI)
  32   Show HUD Info   PARSED, NOT IMPLEMENTED (no "displayname" HUD readout)
  128  Breakable       full func_breakable behaviour: HP, debris, break sound, target
  256  1-Hit Break     any melee weapon destroys it in one hit
  512  Explosives Only bullet-proof; only radius explosions damage it
  1024 Liftable        PARSED, NOT IMPLEMENTED (Sven documents it as heavily bugged
                        and advises against using it)
*/
void() func_pushable =
{
    // Sven "Gib model" is func_breakable's "mdl" under another name - bridge it
    // BEFORE the breakable spawn, which is what precaches and indexes it.
    if (self.gibmodel != "" && self.mdl == "")
        self.mdl = self.gibmodel;

    // Flag translation (see the header) - must also happen before the breakable
    // spawn, which reads spawnflags to decide takedamage and the touch handler.
    //
    // Tell Break_NormaliseFlags to keep its hands off: func_pushable's Sven
    // flag space is NOT func_breakable's (128 Breakable / 512 Explosives Only /
    // 1024 Liftable vs 1 Only Trigger / 2 Touch / 4 Pressure), so running the
    // breakable translation over these bits would corrupt them.  We do our own
    // translation right here instead.
    self.break_skip_normalise = 1;

    if (self.spawnflags & PUSH_EXPLOSIVES_ONLY)
        self.spawnflags = self.spawnflags | BREAKABLE_ONLY_EXPLOSION;
    else if (self.spawnflags & PUSH_BREAKABLE)
        self.spawnflags = self.spawnflags | BREAKABLE_ALWAYS_SHOOTABLE;

    if (self.spawnflags & PUSH_BREAKABLE)
    {
        func_breakable();               // HP, material, debris, break sound, target chain
        if (wasfreed(self))
            return;                     // no model - func_breakable already removed it
    }
    else
    {
        // Not breakable: still a replicated brush, just not damageable.
        SV_InitReplicatedSolidBrush();
        if (wasfreed(self))
            return;
        if (self.material != 0)
            self.style = self.material;
        self.takedamage = DAMAGE_NO;
    }

    self.brush_type = BRUSH_TYPE_TRAIN;

    // GoldSrc: MaxSpeed() = 400 - friction, friction clamped to 399, then the
    // field is ZEROED so the engine's own friction handling can never see it.
    if (self.friction > PUSH_MAX_FRICTION)
        self.friction = PUSH_MAX_FRICTION;

    // ...BUT SCALED TO THE WALKER, and this is where the "slight pushback" lives.
    //
    // The SDK's flat 400-friction gives 370 and 350 for th_ep1_01's crates, against
    // an sv_maxspeed of 270.  A crate 30-37% faster than a person can walk is a crate
    // that runs away from you the instant you touch it, which is why pushing one felt
    // weightless: the player's own predicted collision with the crate can only brake
    // them while the crate is the SLOWER body, and after two usercmds it never was.
    //
    // Keeping the friction TERM but expressing the ceiling as a fraction of walk speed
    // means the crate is always the slower body, so the brake is the player's ordinary
    // collision with a SOLID_BSP brush - already predicted identically on both sides
    // (cl_brushsync.qc:794), so it adds no reconcile error whatever.  Heavier crates
    // stay heavier: friction 30 -> ~212 u/s, friction 50 -> ~201 u/s.
    //
    // sv_pushable_speed_frac 1.48 restores GoldSrc's numbers exactly on this map if
    // the divergence is ever unwanted.
    float pmfrac = cvar("sv_pushable_speed_frac");
    if (pmfrac <= 0) pmfrac = 0.85;
    float pmwalk = cvar("sv_maxspeed");
    if (pmwalk <= 0) pmwalk = 270;
    self.push_maxspeed = pmwalk * pmfrac
                       * ((PUSH_BASE_SPEED - self.friction) / PUSH_BASE_SPEED);
    self.friction      = 0;

    // Legacy spelling: GoldSrc stored buoyancy in pev->skin.  Clear it either
    // way - a NEGATIVE .skin on a brush entity is FTE's contents override, so
    // leaving one on a crate would turn it into a pool of water.
    if (self.buoyancy == 0 && self.skin > 0)
        self.buoyancy = self.skin;
    self.skin = 0;

    // `weapon` IS DOCUMENTED INERT FOR THIS CLASS (see the field block above and the
    // FGD entry below) - but it is a STOCK entvars field, not one of ours, so the
    // entity-lump parser has been writing it all along.  Every func_pushable on both
    // pizza_ya_san maps ships `"weapon" "1"`, which is WEP_DEAGLE, and the weapon-drop
    // machinery reads .weapon as gospel.  Clearing it here makes the code match its own
    // documentation and protects every reader at once - the grapple, the gravity gun,
    // sv_breakable's drop, sv_physprop - rather than one caller at a time.
    if (self.weapon && cvar("sv_debug_pushable"))
        dprint(sprintf("[pushable] spawn: clearing stray map key weapon=%g (would read as a gun)\n",
                       self.weapon));
    self.weapon = 0;

    self.push_spawn_origin = self.origin;

    // Join the rider list so a moving brush can carry us.  GoldSrc gets this
    // from the engine (SV_PushMove moves whatever is standing on the pusher);
    // every mover here is setorigin-driven, so the movers have to do it
    // themselves and this is the set they walk - see Mover_PlatformCarry_Rider
    // in sv_platform_carry.qc, and desertcircle's flag poles for why it matters.
    self.pushable_rider_next = pushable_rider_list;
    pushable_rider_list      = self;

    // Touch has to win over func_breakable's TOUCH-flag handler: a pushable is
    // pushed by walking into it, never shattered by it.  (A Sven pushable does
    // not expose the TOUCH flag at all, so nothing legitimate is being lost.)
    self.touch   = func_pushable_touch;
    self.use     = func_pushable_use;
    self.blocked = func_pushable_blocked;

    precache_sound("debris/pushbox1.wav");
    precache_sound("debris/pushbox2.wav");
    precache_sound("debris/pushbox3.wav");
    precache_sound("player/pl_slosh1.wav");   // water entry
    precache_sound("player/pl_slosh2.wav");
    precache_sound("player/pl_slosh3.wav");
    precache_sound("player/pl_slosh4.wav");

    self.think     = func_pushable_tick;
    // SPAWN-TIME JAM ASSERTION, one tick in, under sv_debug_pushable.
    //
    // The reason a crate can be unpushable is invisible from every existing log
    // line: FuncPushable_CollideWorld only runs when the crate is already trying to
    // move, so on a headless server with nobody leaning on anything, a crate that is
    // permanently startsolid against its neighbour looks exactly like a crate that
    // is fine.  FuncPushable_SelfTest cannot see it either - on the startsolid path
    // CollideWorld zeroes the velocity, so its `plan` comes out '0 0 0' and the BAD
    // assertion is skipped entirely.  A green self-test was never evidence.
    //
    // This asks the question directly and prints the two answers side by side: what
    // tracebox says (quantised to a 64-wide hull anchored at the min corner, for any
    // crate over 32.1 units) versus what the crate's real box says.  A line where
    // hull=SOLID and exact=CLEAR is a crate the engine believes is buried and that
    // genuinely is not - i.e. one that could not be pushed at all before the crate
    // sweep started masking its neighbours out of that trace.
    self.push_jam_check = time + 0.5;
    self.nextthink = self.ltime + PUSH_TICK_IDLE;
};

// Reports whether this crate reads as buried, and whether that reading is real.
void(entity ce) FuncPushable_JamCheck =
{
    vector half   = (ce.maxs - ce.mins) * 0.5;
    vector center = ce.origin + (ce.mins + ce.maxs) * 0.5;

    float ss  = ce.solid;
    ce.solid  = SOLID_NOT;
    tracebox(center, half * -1, half, center, MOVE_NOMONSTERS, ce);
    ce.solid  = ss;
    float hull_solid = (trace_startsolid || trace_allsolid);

    // Exact: does our real AABB overlap any other crate's real AABB?
    float exact_solid = FALSE;
    entity oe = pushable_rider_list;
    while (oe)
    {
        if (oe != ce && oe.solid != SOLID_NOT)
            if (oe.absmin_x < ce.absmax_x && oe.absmax_x > ce.absmin_x
             && oe.absmin_y < ce.absmax_y && oe.absmax_y > ce.absmin_y
             && oe.absmin_z < ce.absmax_z && oe.absmax_z > ce.absmin_z)
                exact_solid = TRUE;
        oe = oe.pushable_rider_next;
    }

    dprint(sprintf("[pushable] jam-check box=%v..%v w=%g hull=%s exact=%s\n",
                   ce.absmin, ce.absmax, ce.maxs_x - ce.mins_x,
                   hull_solid  ? "SOLID" : "clear",
                   exact_solid ? "SOLID" : "clear"));
};

// Round reset.  Called from BreakableResetAll (sv_breakable.qc) - a pushable
// needs its SPAWN ORIGIN back as well as its health, which a func_breakable
// never does because a func_breakable never moves.
void() FuncPushable_ResetAll =
{
    entity e = nextent(world);
    while (e)
    {
        if (e.classname == "func_pushable")
        {
            e.velocity  = '0 0 0';
            e.avelocity = '0 0 0';
            setorigin(e, e.push_spawn_origin);

            if (e.push_moving)
            {
                MovingBrush_RemoveFromList(e);
                e.push_moving = 0;
            }

            if (e.breakable_broken)
            {
                setmodel(e, e.breakable_model);
                e.solid                       = SOLID_BSP;
                e.movetype                    = MOVETYPE_PUSH;
                e.health                      = e.max_health;
                e.breakable_broken            = FALSE;
                e.breakable_next_impact_sound = 0;
                e.on_damaged                  = BreakableDamaged;
                e.on_killed                   = func_breakable_break;

                if (e.spawnflags & BREAKABLE_ONLY_EXPLOSION)
                    e.takedamage = DAMAGE_NO;
                else if (e.style == BREAKABLE_UNBREAKABLE_GLASS)
                    e.takedamage = DAMAGE_NO;
                else if (e.spawnflags & PUSH_BREAKABLE)
                    e.takedamage = DAMAGE_YES;
                else
                    e.takedamage = DAMAGE_NO;

                // Re-arm the pushable handlers - func_breakable_break cleared
                // solid/movetype and BreakableResetAll's own re-arm doesn't run
                // for this class.
                e.touch   = func_pushable_touch;
                e.use     = func_pushable_use;
                e.blocked = func_pushable_blocked;

                // .ltime froze the moment the break dropped it to MOVETYPE_NONE,
                // so it is now a whole round behind world time.  Resync before
                // scheduling - nextthink is measured against ltime once the
                // pusher physics resume, and the engine only fires a think when
                // thinktime > the ltime it had at the START of the frame.
                e.ltime     = time;
                e.think     = func_pushable_tick;
                e.nextthink = e.ltime + PUSH_TICK_IDLE;
            }

            e.SendFlags = -1;   // see BreakableResetAll: |= 1 can look unchanged
        }
        e = nextent(e);
    }
};


// ---------------------------------------------------------------------------
//  sv_pushable_selftest  -  the anti-tunnelling INVARIANT
// ---------------------------------------------------------------------------
// The reported bug is "func_pushables can be pushed through walls and through
// other func_pushables".  A MOVETYPE_PUSH entity gets no collision from the
// engine at all - WPhys_PushMove integrates velocity straight through world
// geometry, and ignores other SOLID_BSP pushers entirely - so the ONLY thing
// standing between a crate and a wall is that FuncPushable_CollideWorld refuses
// to leave a velocity that would cross one.  That is the invariant, and it is
// what this asserts:
//
//     after CollideWorld(dt), sweeping the crate's hull along velocity*dt
//     must be unobstructed.
//
// Stated that way it needs no physics, no gravity and no player - which matters,
// because three earlier attempts at an end-to-end drive test all foundered on the
// same thing: the crates on the test maps sit on ledges, so shoving one takes it
// over the edge and what gets measured is a fall, not a push.  (Subject 803 on
// svencoop2 reached -137 u/s vertically inside half a second.)  Falling, sliding
// along an angled face and rounding a corner are all legitimate motions that a
// distance test calls failures, and none of them is the defect.
//
// Every crate on the map is checked, in all four cardinal directions, at a dt of
// half a second - large on purpose, so the swept distance (200 units at the push
// speed cap) is long enough to reach the walls a real crate is near, rather than
// the 6 units one 64Hz tick would cover.
float pushtest_done;
float pushtest_tries;

void() FuncPushable_SelfTest =
{
    if (!cvar("sv_pushable_selftest") || pushtest_done)
        return;

    // RETRY, DO NOT GIVE UP ON THE FIRST LOOK.  The frame hook starts running
    // before `+map` has been processed, so the first pass sees the empty pre-map
    // world - measured: an earlier version of this printed its "no crates" line at
    // 04:12:12 and svencoop2's nine crates spawned at 04:12:13.  Giving up there
    // disabled the test permanently, because the cvar survives the map load that
    // wipes every QC global (PR_Deinit, sv_init.c:945) - so the state said "never
    // started" while the switch said "off".
    if (!pushable_rider_list)
    {
        pushtest_tries = pushtest_tries + 1;
        if (pushtest_tries < 300)
            return;
        dprint("[pushtest] no func_pushable on this map - skipped\n");
        pushtest_done = TRUE;
        return;
    }

    float bad     = 0;
    float crates  = 0;
    float probes  = 0;
    float clipped = 0;
    float dt      = 0.5;

    entity oself = self;
    entity ce    = pushable_rider_list;
    while (ce)
    {
        if (!ce.breakable_broken)
        {
            crates = crates + 1;
            self   = ce;

            vector saved = ce.velocity;
            float  i     = 0;
            while (i < 4)
            {
                vector d = '1 0 0';
                if (i == 1) d = '-1 0 0';
                if (i == 2) d = '0 1 0';
                if (i == 3) d = '0 -1 0';

                // Drive it at the cap, which is the fastest a player can ever make
                // it go, and ask the clip to make that safe.
                float spd = ce.push_maxspeed;
                if (spd <= 0) spd = PUSH_BASE_SPEED;
                ce.velocity = d * spd;

                FuncPushable_CollideWorld(dt);

                // ...and now the crate must be able to travel what it still asks
                // for, without meeting anything.
                vector half   = (ce.maxs - ce.mins) * 0.5;
                vector center = ce.origin + (ce.mins + ce.maxs) * 0.5;
                vector plan   = ce.velocity * dt;

                if (plan != '0 0 0')
                {
                    float ss = ce.solid;
                    ce.solid = SOLID_NOT;
                    tracebox(center, half * -1, half, center + plan,
                             MOVE_NOMONSTERS, ce);
                    ce.solid = ss;

                    probes = probes + 1;
                    if (ce.velocity != d * spd)
                        clipped = clipped + 1;

                    if (trace_fraction < 1 || trace_startsolid || trace_allsolid)
                    {
                        bad = bad + 1;
                        dprint(sprintf("[pushtest] BAD: ent=%g dir=%v leaves vel=%v"
                                       " - sweep frac %.3f start=%g\n",
                                       num_for_edict(ce), d, ce.velocity,
                                       trace_fraction, trace_startsolid));
                    }
                }
                else
                    probes = probes + 1;

                i = i + 1;
            }

            ce.velocity = saved;
        }
        ce = ce.pushable_rider_next;
    }
    self = oself;

    dprint(sprintf("[pushtest] %g crate(s), %g probes, %g clipped by geometry  BAD=%g\n",
                   crates, probes, clipped, bad));
    pushtest_done = TRUE;
    cvar_set("sv_pushable_selftest", "0");
};
