//
// sv_platform_carry.qc — proper moving-platform player carry + geometry-aware push
//
// Replaces the bbox-overlap-and-slide approach (sv_doors.qc Mover_PushPlayers)
// for func_train and func_tracktrain.  The old approach treated the
// brush's AABB as a push volume, which falsely caught players who happened
// to be inside the brush's bbox even when there was empty space between
// them and the actual brush surfaces — particularly bad for enclosed
// brushes (hollow train cars).
//
// New behaviour:
//
//   1. STAND-ON LOCK (Mover_PlatformCarry).  Player whose feet trace
//      down to this brush is locked 1:1 to the brush's per-tick
//      translation + yaw delta.  Mirrors the func_rotating Phase 1
//      pattern in sv_doors_rotating.qc Brush_RotateCarry.
//
//   2. VELOCITY INHERIT.  When the player was being carried last tick
//      but isn't this tick (jumped or stepped off), the brush's last
//      velocity is added to the player's velocity once.  Single check
//      covers both jump and walk-off cases.
//
//   3. GEOMETRY PUSH (Mover_GeometryBlockPush).  Players not being
//      carried get pushed only when the brush's BSP geometry actually
//      intersects their bbox — tested via the dimension-bit trick from
//      PM_BoxInTriggerBrush in shared/sh_pmove.qc.  AABB-overlap-with-
//      no-geometry-touch (e.g. mid-air inside a hollow train) does
//      nothing.
//
// CSQC parity (predicted player carry) is a follow-up — requires
// extending sv_brushsync.qc to publish trains as BRUSH_TYPE_TRAIN
// so they appear in the client-side moving_brush_list.  For now the
// carry runs server-only; visual rubber-banding when riding a train
// is the trade-off until brushsync is extended.
//

// Forward decls.  Signatures must match sh_weapon_standard.qc /
// sv_doors_rotating.qc exactly or fteqcc rejects the redeclaration.
float(entity attacker, entity target, float damage) W_ApplyDamage;
vector(vector pt, vector pivot, float deg, float axis_idx) RotDoor_RotateAround;

// PM_TRIGGER_PROBE_DIM lives in sh_pmove.qc which compiles AFTER this
// file in sv_progs.src, so re-declare the value locally.  Both
// declarations must use the same numeric constant (64); fteqcc will
// share the const slot.
const float PM_TRIGGER_PROBE_DIM = 64;

// Same situation for pm_movetype + PM_MOVETYPE_* constants — re-declared
// here verbatim so this file compiles standalone.  fteqcc shares the
// field/const slots with the canonical declaration in sh_pmove.qc.
.float pm_movetype;
const float PM_MOVETYPE_NORMAL    = 0;
const float PM_MOVETYPE_DEAD      = 1;
const float PM_MOVETYPE_FLY       = 2;
const float PM_MOVETYPE_SPECTATOR = 3;
const float PM_MOVETYPE_NONE      = 4;
const float PM_MOVETYPE_NOCLIP    = 5;

// ---------------------------------------------------------------------------
// Per-player carry application.  Returns 1 if the carry blocked
// (couldn't translate the player cleanly — train should crush per
// HL semantics; the caller may choose to ignore).
//
// `self` MUST be set to the moving brush before calling.
// ---------------------------------------------------------------------------
float(entity p) Mover_PlatformCarry_Player =
{
    if (p.is_dead)
    {
        if (p.platform_carry == self)
            p.platform_carry = world;
        return 0;
    }

    // Noclip players phase through the world by design — they shouldn't
    // be locked to platforms or shoved by brush surfaces.  Skip both
    // the carry and any latch maintenance so leaving noclip doesn't
    // trigger a spurious velocity-inherit transition.
    if (p.pm_movetype == PM_MOVETYPE_NOCLIP
        || p.pm_movetype == PM_MOVETYPE_SPECTATOR
        || p.pm_movetype == PM_MOVETYPE_NONE)
    {
        if (cvar("sv_debug_func_train"))
            dprint(sprintf("[carry] skip player #%g pm_movetype=%g (noclip/spec/none)\n",
                           num_for_edict(p), p.pm_movetype));
        if (p.platform_carry == self)
        {
            p.platform_carry = world;
            p.platform_carry_velocity = '0 0 0';
        }
        return 0;
    }

    // Probe ground: trace down 4u from the player's feet.  Brush is
    // SOLID_BSP at this point (we don't temporarily un-solid until
    // the rotation tracebox), so the trace will hit the brush
    // top surface if the player is standing on it.  Mirrors the
    // Phase 1 detection in sv_doors_rotating.qc Brush_RotateCarry.
    //
    // EXCLUDE trace_startsolid: a player wedged INSIDE the brush
    // BSP (rare, but possible if a previous bug or external push
    // shoves them in) returns trace_fraction=0 + startsolid=1, which
    // without this check would test as "standing on the brush" and
    // the carry would track them with the brush's oscillation —
    // exactly the user-reported "I get stuck inside and follow it
    // up and down" symptom on doors.
    tracebox(p.origin, p.mins, p.maxs,
             p.origin - '0 0 4', MOVE_NORMAL, p);
    float on_this_brush = (trace_fraction < 1
                        && trace_ent == self
                        && !trace_startsolid);

    if ((p.flags & FL_ONGROUND) && on_this_brush)
    {
        // === CARRYING ===

        // Origin delta.  First tick after spawn has platform_prev_seeded=0,
        // so we skip the delta application and just seed the snapshot
        // to avoid teleporting the player by the brush's absolute origin.
        if (self.platform_prev_seeded)
        {
            vector origin_delta = self.origin - self.platform_prev_origin;
            float  yaw_delta    = self.angles_y - self.platform_prev_yaw;

            // Normalize yaw delta: engine may wrap angles to (-180, 180]
            // or [0, 360); a one-tick yaw step past either boundary
            // reads as a ±360 spike in the raw subtraction.  At our
            // tick rate the real yaw step is at most a few degrees.
            if (yaw_delta > 180)  yaw_delta = yaw_delta - 360;
            if (yaw_delta < -180) yaw_delta = yaw_delta + 360;

            // WHO OWNS THE POSITION, this tick pass or pmove?
            //
            // For a BRUSH_TYPE_TRAIN brush, PMOVE DOES - and it runs on both
            // sides (PM_CheckMovingPushers, sh_pmove.qc:3815), applying the same
            // translation and the same yaw orbit that the block below would.
            // Its own header records why that became the single source: "running
            // carry from two different tick rates double-applied deltas at
            // snapshot boundaries".  func_train and func_tracktrain were moved
            // over then and no longer call this function at all.
            //
            // THE PLAT FAMILY WAS MISSED, because it reaches us through
            // Mover_TravelTick (shared with doors and buttons) rather than
            // through a tick of its own - so it was the one BRUSH_TYPE_TRAIN
            // left being carried twice.  On a plain func_plat that is invisible:
            // the extra vertical shove puts the rider slightly above the deck
            // and gravity drops them back within the same frame.  On a
            // func_platrot there is no restoring force for angular position, so
            // the second orbit simply accumulates - hl_c01_a1's `ele_2` turns 90
            // degrees and swung its passenger through 180.
            //
            // Doors and buttons (BRUSH_TYPE_DOOR / BRUSH_TYPE_BUTTON) are skipped
            // by pmove's train branch entirely, so for them this tick pass is
            // still the only carry there is and nothing changes.
            //
            // ...AND SO WAS THE VIEW YAW, which this comment used to deny.  It
            // said "pmove moves pm_origin and never touches angles, so it is not
            // part of the double."  That is false: shared/sh_pmove.qc:4042-4048
            // sends CSQC_EVENT_DOOR_VIEWROT itself, under #ifdef SSQC, from the
            // same TRAIN branch.  Both senders deliver a full frame of yaw and
            // CSQC sums them into one csqc_door_yaw_offset, so ele_2's 90-degree
            // turn swung the passenger's VIEW through 180 even after the
            // position double was fixed.  Same bug, second channel.
            //
            // The gate is not simply "is this a train": pmove skips any brush
            // whose .velocity is zero (sh_pmove.qc:3823), so a rotation-only
            // func_platrot (height 0) never reaches pmove's branch at all and
            // this tick is its ONLY view-rot sender.  Gate on what pmove will
            // actually do, not on the brush type alone, or those lose their
            // carry rotation entirely.
            float pmove_owns_position = (self.brush_type == BRUSH_TYPE_TRAIN);
            float pmove_sends_viewrot = pmove_owns_position && (self.velocity != '0 0 0');

            if (pmove_owns_position)
            {
                if (yaw_delta != 0)
                    p.angles_y = p.angles_y + yaw_delta;
            }
            else
            {
                // Apply: translate by origin_delta, then rotate around the
                // brush's origin by yaw_delta on the Z axis (axis_idx=1
                // per RotDoor_RotateAround's mapping).  Tracebox the
                // destination to detect block.
                vector new_origin = p.origin + origin_delta;
                if (yaw_delta != 0)
                    new_origin = RotDoor_RotateAround(new_origin, self.origin, yaw_delta, 1);

                // Un-solid the brush during the tracebox so the player's
                // bbox doesn't false-block on the surface it's standing on.
                float saved_solid = self.solid;
                self.solid = SOLID_NOT;
                tracebox(p.origin, p.mins, p.maxs, new_origin, MOVE_NORMAL, p);
                self.solid = saved_solid;

                if (trace_fraction >= 1.0)
                {
                    setorigin(p, new_origin);
                    if (yaw_delta != 0)
                        p.angles_y = p.angles_y + yaw_delta;
                }
                else if (trace_fraction > 0)
                {
                    // Partial — carry as far as possible.
                    setorigin(p, trace_endpos);
                    if (yaw_delta != 0)
                        p.angles_y = p.angles_y + yaw_delta;
                }
                else
                {
                    // Blocked — crush per .dmg if the brush has it set.
                    // No takedamage gate - players are DAMAGE_NO in this mod and
                    // W_ApplyDamage decides for itself.
                    if (self.dmg > 0)
                        W_ApplyDamage(self, p, self.dmg);
                    p.platform_carry = self;
                    p.platform_carry_velocity = self.velocity;
                    return 1;
                }
            }

            // Rotate the carried player's VIEW yaw to match the cab's
            // yaw delta.  Sends CSQC_EVENT_DOOR_VIEWROT to this player
            // only (msg_entity), which their CSQC accumulates into
            // csqc_door_yaw_offset and folds into input_angles next
            // input frame.  Result: pressing "forward" inside a
            // turning cab keeps you moving relative to the cab, not
            // world-relative — fixes the "drift out of the cab" feel
            // on turns.  The receive path was already wired in
            // cl_main.qc:1154 for func_rotating-style carries; this
            // is the missing server-side send.
            //
            // ...but only when pmove is not already sending it — see
            // pmove_sends_viewrot above.  Doors and buttons (BRUSH_TYPE_DOOR /
            // BRUSH_TYPE_BUTTON) never enter pmove's train branch, so for them
            // this remains the only sender and nothing changes.
            if (!pmove_sends_viewrot && yaw_delta != 0 && SV_PlayerHasNetchan(p))   // skip bots (no netchan); engine-truth guard
            {
                msg_entity = p;
                WriteByte(MSG_ONE, SVC_CGAMEPACKET);
                WriteByte(MSG_ONE, CSQC_EVENT_DOOR_VIEWROT);
                // Send delta as short * 100 — matches the receive's
                // readshort() * 0.01 unfold in cl_main.qc.  Short
                // range ±32767 = ±327° per tick, plenty for any
                // realistic yaw step.
                WriteShort(MSG_ONE, yaw_delta * 100);
            }
        }

        // Update the carry latch so a future tick can detect departure.
        p.platform_carry          = self;
        p.platform_carry_velocity = self.velocity;
        return 0;
    }

    // === NOT CARRYING THIS TICK ===

    if (p.platform_carry == self)
    {
        // Just left us (jumped, stepped off, or got knocked off).
        // Replace the XY component of player velocity with the
        // platform's XY velocity — they leave moving AT the train's
        // speed, not at train+input speed.  Preserve Z so a jump
        // keeps its vertical impulse.
        //
        // Prior version did p.velocity += platform_carry_velocity,
        // which stacked the player's INPUT XY velocity (e.g. walking
        // forward at 320 in the cabin) on top of the train's 256,
        // sending them flying at 576 u/s.  The user's expectation
        // matches GoldSrc semantics: jumping inside a cabin keeps
        // you with the cabin, not faster than it.
        p.velocity_x  = p.platform_carry_velocity_x;
        p.velocity_y  = p.platform_carry_velocity_y;
        // p.velocity_z preserved (jump or fall velocity).

        p.platform_carry          = world;
        p.platform_carry_velocity = '0 0 0';
    }

    return 0;
};

// ---------------------------------------------------------------------------
// NON-PLAYER RIDERS.
//
// A player is not the only thing that can be standing on a moving brush, and
// until now it was the only thing this file would move.  In GoldSrc the ENGINE
// does the carrying - SV_PushMove translates every entity whose groundentity is
// the pusher - so a crate on a lift rides it for free and mappers build on that.
// Every mover in this tree drives itself with setorigin instead (position-driven
// and exact, which is what a momentary_door needs), and setorigin does not run
// the pusher physics, so the brush slid out from under anything sitting on it.
//
// desertcircle is built entirely on this.  Each of its four flag poles is a
// momentary_door hidden in a shaft at the top of the map with a 16-unit
// func_pushable parked on its lid; raising the flag lifts the crate into a
// trigger_once 200 units above, and THAT is what captures the base - moves your
// spawn up, unlocks the next pole, freezes the flag at the masthead and prints
// the next objective.  With nothing to lift the crate, the entire mission chain
// was unreachable.
//
// Kept to func_pushable on purpose.  A pushable is inert physics that only ever
// wanted the engine's carry; monsters and items are a different question (they
// have their own movement running against ours) and are left alone.
// ---------------------------------------------------------------------------
entity pushable_rider_list;      // built in sv_func_pushable.qc's spawn function
.entity pushable_rider_next;

float(entity r) Mover_PlatformCarry_Rider =
{
    if (!self.platform_prev_seeded)
        return 0;

    vector delta = self.origin - self.platform_prev_origin;
    if (delta == '0 0 0')
        return 0;

    // "IS IT ON US" IS AN AABB TEST, NOT A GROUND TRACE, and that is not a
    // shortcut - a ground trace cannot answer it here.  We are called AFTER the
    // brush has already been moved, so a lid that rose 0.9 units this tick is now
    // 0.9 units INSIDE the crate resting on it: a downward probe from the crate
    // starts solid and reports nothing.  GoldSrc has the same ordering and solves
    // it the same way, taking either of two conditions (SV_PushMove):
    //
    //     if ( !((check->v.flags & FL_ONGROUND) && check->v.groundentity == pusher) )
    //     {   if ( check->v.absmin[0] >= maxs[0] || ... ) continue;   // no intersection
    //         if ( !SV_TestEntityPosition(check) )        continue; } // not inside
    //     // move this entity
    //
    // i.e. standing on the pusher OR overlapping its new box.  XY overlap plus a
    // Z window that spans "just touching the lid" through "the lid has swept up
    // into it" covers both.  absmin/absmax carry the engine's 1-unit link
    // padding, so a crate at rest on a lid reads as -2, not 0.
    if (r.absmin_x > self.absmax_x || r.absmax_x < self.absmin_x) return 0;
    if (r.absmin_y > self.absmax_y || r.absmax_y < self.absmin_y) return 0;
    if (r.absmin_z > self.absmax_z + 8 || r.absmin_z < self.absmax_z - 16) return 0;

    // Hull from the MIDPOINT, not from .origin.  A GoldSrc brush entity built
    // without an origin brush keeps .origin '0 0 0' and holds its world position
    // in mins/maxs, so tracebox(r.origin, r.mins, r.maxs, ...) would probe the
    // map origin.  Same reasoning, and the same shape, as FuncPushable_Center.
    vector half   = (r.maxs - r.mins) * 0.5;
    vector center = r.origin + (r.mins + r.maxs) * 0.5;

    // Sweep the carry so a crate driven into a ceiling stops instead of being
    // shoved through it.  Un-solid both ends: ourselves because we are the
    // surface it is riding, the rider because a brush entity is its own
    // obstruction.
    float rs   = r.solid;
    float ss   = self.solid;
    self.solid = SOLID_NOT;
    r.solid    = SOLID_NOT;
    tracebox(center, half * -1, half, center + delta, MOVE_NOMONSTERS, r);
    r.solid    = rs;
    self.solid = ss;

    if (trace_startsolid)
    {
        // Already embedded in something that is not us - we cannot reason about
        // the sweep, so take the pusher's word for it and translate.  Crushing
        // here would punish a crate for geometry it was spawned in.
        setorigin(r, r.origin + delta);
        r.SendFlags = -1;
        return 0;
    }

    if (trace_fraction <= 0)
    {
        // Wedged against real geometry - crush per .dmg, as the player path does.
        if (self.dmg > 0)
            W_ApplyDamage(self, r, self.dmg);
        return 1;
    }

    setorigin(r, r.origin + (trace_endpos - center));
    r.SendFlags = -1;       // replicated brush: ship the new origin to CSQC
    return 0;
};

// ---------------------------------------------------------------------------
// Server-side wrapper: walk all players and apply the carry helper.
// Captures the brush's pre-tick snapshot at the END so the next call
// sees the delta correctly.
//
// `self` MUST be the moving brush.
// ---------------------------------------------------------------------------
float() Mover_PlatformCarry =
{
    float blocked = 0;
    entity p = find(world, classname, "player");
    while (p)
    {
        blocked = blocked | Mover_PlatformCarry_Player(p);
        p = find(p, classname, "player");
    }

    entity r = pushable_rider_list;
    while (r)
    {
        entity nxt = r.pushable_rider_next;     // capture first: a crush can free it
        blocked = blocked | Mover_PlatformCarry_Rider(r);
        r = nxt;
    }

    // Snapshot for next tick.  Even on the very first call we set this
    // and mark seeded so the second call computes a real delta.
    self.platform_prev_origin = self.origin;
    self.platform_prev_yaw    = self.angles_y;
    self.platform_prev_seeded = 1;

    return blocked;
};

// ---------------------------------------------------------------------------
// Look-ahead crush detection.  Predicts where the brush will be
// after this tick's engine integration (origin + planned_velocity *
// tick_dt) and probes for player overlap THERE — not at the current
// position.  Any player whose bbox would be inside the brush after
// the next move gets damaged via self.blocked(); the caller pauses
// the door so the engine never actually advances into them.
//
// Why look-ahead instead of react-after?  The engine integrates
// MOVETYPE_PUSH brushes BEFORE think fires, so a react-after probe
// sees the brush already embedded in the player — the door has
// already phased through.  Look-ahead catches the wedge at the
// boundary, leaves the brush sitting at the contact surface.
//
// Slide attempts removed: previous version tried to push the player
// out of the brush's path on overlap.  In open-floor scenarios the
// slide always succeeded (no wall behind the player) so .blocked
// never fired, no damage, no stop — exactly the "doesn't stop,
// no damage" bug.  Now: any future-overlap = damage + pause.  No
// shove-out-of-the-way semantics for in-path players.  (Lock-on
// carry for players standing ON TOP of the brush still works via
// Mover_PlatformCarry, which runs first.)
//
// Returns 1 if any player would be inside the brush after the next
// integration.  Caller (Mover_TravelTick) uses this to gate
// velocity to 0 so the engine doesn't advance the brush this tick.
//
// `self` MUST be the moving brush.
// ---------------------------------------------------------------------------
float(entity p) Mover_GeometryBlockPush_Player =
{
    if (p.is_dead) return 0;
    if (p.platform_carry == self) return 0;       // already locked-on, skip
    if (p.pm_movetype == PM_MOVETYPE_NOCLIP
        || p.pm_movetype == PM_MOVETYPE_SPECTATOR
        || p.pm_movetype == PM_MOVETYPE_NONE) return 0;  // phasing through by design

    // === 1. Detect overlap with brush's future footprint ===
    //
    // Geometry intersection probe at the brush's CURRENT position
    // (which the caller has temporarily set to the look-ahead
    // future origin).  Dimension-bit trick scopes the trace to
    // ONLY this brush so other geometry doesn't false-trigger.
    float saved_dim_hit = p.dimension_hit;
    p.dimension_hit     = PM_TRIGGER_PROBE_DIM;

    tracebox(p.origin, p.mins, p.maxs, p.origin, MOVE_NORMAL, p);

    p.dimension_hit = saved_dim_hit;

    if (!(trace_startsolid && trace_ent == self))
        return 0;     // not in the brush's future footprint

    // === 2. Try to push the player along the brush's motion ===
    //
    // Crusher semantics: instead of immediately damaging + reversing
    // on first overlap (the old behaviour), give the player a chance
    // to be carried.  Push direction is the brush's planned per-tick
    // advance vector — the same `advance` the caller used to position
    // self at the look-ahead origin.  If the swept path from p.origin
    // to (p.origin + advance) is clear of OTHER geometry, the brush
    // is carrying the player along its motion; no damage.  If the
    // sweep stops short (wall / floor / ceiling / another player),
    // the player is being crushed → fall through to .blocked().
    //
    // Mirrors GoldSrc-style crusher behaviour: descending ceiling
    // pushes a mid-air player down with it, only damaging when the
    // player meets the floor; rising plat next to a player lifts
    // them along, only damaging when their head meets a ceiling.
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)  hz = 40;
    if (hz > 200) hz = 200;
    vector advance       = self.mover_planned_velocity * (1.0 / hz);
    vector pushed_origin = p.origin + advance;

    // === 3. Free-path check ===
    //
    // Hide the brush during the traces so they only see OTHER
    // geometry — walls, floor, ceiling, other entities.  We KNOW
    // the brush itself overlaps the player's path by design (that's
    // step 1's detection); the question is whether anything ELSE
    // would block the carry.
    //
    // Three traces are needed because the player may already be in
    // contact with non-brush geometry (e.g. standing flush against
    // a wall on the plat).  A naive `trace_fraction >= 1.0 &&
    // !trace_startsolid` rejects that legitimate case as a crush.
    // Compare start-solid vs end-solid so we only reject when the
    // push *introduces* new solid contact:
    //
    //   start_solid=0, end_solid=0  → clean push, accept
    //   start_solid=1, end_solid=1  → still touching the same thing
    //                                 they were before (e.g. sliding
    //                                 along a wall) → accept
    //   start_solid=0, end_solid=1  → push moved them INTO new solid
    //                                 → crush, reject
    //   path_blocked (frac<1)       → swept box hit new geometry
    //                                 mid-path → crush, reject
    float saved_solid = self.solid;
    self.solid        = SOLID_NOT;

    // 3a. Start-solid probe at p.origin
    tracebox(p.origin, p.mins, p.maxs, p.origin, MOVE_NORMAL, p);
    float start_solid = trace_startsolid;

    // 3b. Swept push trace
    tracebox(p.origin, p.mins, p.maxs, pushed_origin, MOVE_NORMAL, p);
    float path_clear = (trace_fraction >= 1.0);

    // 3c. End-solid probe at pushed_origin
    tracebox(pushed_origin, p.mins, p.maxs, pushed_origin, MOVE_NORMAL, p);
    float end_solid = trace_startsolid;

    self.solid = saved_solid;

    float newly_trapped = (end_solid && !start_solid);

    if (path_clear && !newly_trapped)
    {
        // Push valid — carry the player by `advance`.  No velocity
        // change: the player keeps their own momentum (gravity /
        // input / jump impulse); the brush has just relocated
        // their origin one tick's worth of its motion.  Mirrors
        // Mover_PlatformCarry_Player's origin-only carry for
        // stand-on-top players (see line 149 above).
        setorigin(p, pushed_origin);

        if (cvar("sv_debug_doors"))
            dprint(sprintf("[mover %s] carried player #%g by %v (start_solid=%g end_solid=%g)\n",
                           self.targetname, num_for_edict(p), advance,
                           start_solid, end_solid));
        return 0;   // not blocked — brush integrates this tick
    }

    // === 4. Push failed — crush ===
    //
    // The sweep hit something other than the brush, meaning the
    // player would be wedged between the brush and that obstacle
    // after one tick of motion.  Fire .blocked (damage + reverse,
    // or pause-and-damage-per-tick for DOOR_UNBLOCKABLE).
    if (cvar("sv_debug_doors"))
        dprint(sprintf("[mover %s] crush — push to %v path_clear=%g newly_trapped=%g (start_solid=%g end_solid=%g)\n",
                       self.targetname, pushed_origin, path_clear, newly_trapped,
                       start_solid, end_solid));

    if (self.blocked)
    {
        entity saved_other = other;
        other = p;
        self.blocked();
        other = saved_other;
    }
    return 1;
};

float() Mover_GeometryBlockPush =
{
    // Set up look-ahead: move the brush to its future origin
    // (origin + planned_velocity * tick_dt) for the duration of all
    // player probes, then restore.  Using planned_velocity instead
    // of current velocity so a door paused last tick still looks
    // ahead toward where it WANTS to move — otherwise paused doors
    // would probe at their current position (= no advance to detect)
    // and immediately un-pause.
    float hz = cvar("sv_func_tickrate");
    if (hz <= 0)  hz = 40;
    if (hz > 200) hz = 200;
    float tick_dt = 1.0 / hz;

    vector advance = self.mover_planned_velocity * tick_dt;
    if (advance == '0 0 0')
        return 0;   // not moving / no planned motion — nothing to look ahead to

    vector saved_origin    = self.origin;
    float  saved_solid     = self.solid;
    float  saved_dim_solid = self.dimension_solid;

    setorigin(self, saved_origin + advance);
    self.solid             = SOLID_BSP;
    self.dimension_solid  |= PM_TRIGGER_PROBE_DIM;

    if (cvar("sv_debug_doors"))
        dprint(sprintf("[mover %s] look-ahead origin %v -> %v (adv %v)\n",
                       self.targetname, saved_origin,
                       saved_origin + advance, advance));

    float blocked = 0;
    entity p = find(world, classname, "player");
    while (p)
    {
        blocked = blocked | Mover_GeometryBlockPush_Player(p);
        p = find(p, classname, "player");
    }

    // Restore brush state in reverse order of the look-ahead setup.
    self.dimension_solid = saved_dim_solid;
    self.solid           = saved_solid;
    setorigin(self, saved_origin);

    if (cvar("sv_debug_doors") && blocked)
        dprint(sprintf("[mover %s] BLOCKED — wedge detected at look-ahead\n",
                       self.targetname));

    return blocked;
};
