//
// sv_func_guntarget.qc — HL/GoldSrc func_guntarget brush entity
//
// A func_train with hit points: a brushmodel that walks a path_corner
// chain while it is "on", takes damage while it walks, and fires its
// .message when it dies.  Half-Life source: dlls/plats.cpp, class
// CGunTarget (LINK_ENTITY_TO_CLASS at ~line 2130).
//
// Keys:
//   target   — first path_corner in the chain.
//   speed    — units/second (HL default 100; hc2 authors 80).
//   health   — hit points.  Restored from max_health every time the
//              target is switched ON, exactly as HL does.
//   message  — targetname fired ON DEATH.  NOT `target`: on a
//              func_guntarget `target` is already spoken for by the
//              path chain, which is why HL uses the message slot here.
//   movesnd / stopsnd / volume — see sv_func_train.qc's enum tables.
//
// Spawnflags:
//    1  START_ON — begin walking 0.3s after spawn without a trigger.
//
//
// ---------------------------------------------------------------------------
// THE DESTINATION CONVENTION — which turned out to be func_train's after all
// ---------------------------------------------------------------------------
// THIS SECTION'S ORIGINAL PREMISE WAS WRONG AND IS CORRECTED HERE.  It claimed
// func_train puts its ORIGIN on the corner while CGunTarget puts its BRUSH
// CENTRE there.  Both HL classes use the identical expression:
//        CFuncTrain::Activate  plats.cpp:822
//        CFuncTrain::Next      plats.cpp:806
//        CGunTarget::Activate  plats.cpp:2178
//        CGunTarget::Next      plats.cpp:2202
//        destination = corner.origin - (pev->mins + pev->maxs) * 0.5
// The real defect was in sv_func_train.qc, which read the corner origin raw at
// all five of its destination sites.  It has since been fixed there
// (FuncTrain_DestOrigin), which is what makes pizza_ya_san1's tr_soukoexit stop
// being teleported outside the world.
//
// So the offset below is now applied by the mover, and applying it a SECOND time
// here would put every guntarget twice as far off as it ever was.
// GunTarget_CentreOffset therefore returns zero — see the note on it.
//
// The measurement that motivated the offset is still correct and still worth
// keeping, because it is the proof that the shared convention is the right one.
// Verified against hc2_c2:
//   r_gt1 is submodel *157, bounds (-1856 -1684 -80)..(-1824 -1680 -32),
//   no ORIGIN brush, so its centre offset is (-1840 -1682 -56).  Its first
//   corner gt1_stp0 sits at (784 -5040 -3728), so
//       destination = (784 -5040 -3728) - (-1840 -1682 -56)
//                   = (2624 -3358 -3672)
//   which is the map's OWN authored origin key, "2624 -3360 -3584", to
//   within the couple of units bspguy rounded off when it merged hc2_c4
//   into hc2_c2.  Drop the centre offset entirely and the brush lands
//   at (784 -5040 -3728) — 1840 units away in X — and the entire shooting
//   range disappears into the void.  That is precisely the failure mode
//   func_train was suffering map-wide until FuncTrain_DestOrigin landed.
//
// The remaining six agree: gt2 (2688 -3342 -3592), gt3 (2526 -3360 -3592),
// gt4 (2624 -3358 -3672), gt5 (2622 -3360 -3656), gt6 (2626 -3440 -3592),
// gt7 (2544 -3358 -3592).
//
//
// ---------------------------------------------------------------------------
// HOW THE OFFSET IS APPLIED WITHOUT FORKING func_train
// ---------------------------------------------------------------------------
// Every mover in sv_func_train.qc reads its destination straight out of
// `self.train_target.origin` — func_train_move_tick, func_train_arrive and
// the PATH_TELEPORT branch all do.  There is no hook between "arrived" and
// "start the next leg", so a per-leg offset cannot be injected from here.
//
// So instead of forking the mover, we offset the PATH.  At spawn each
// func_guntarget builds a private, translated copy of its corner chain —
// one lightweight "guntarget_corner" edict per real path_corner, parked at
// `real.origin + offset` and carrying that corner's message / wait / speed /
// spawnflags — and points train_target at the copy.  Every func_train
// function then works verbatim and correctly: PATH_TELEPORT, PATH_FIRE_ONCE,
// PATH_WAIT_FOR_RETRIGGER, per-corner speed override, the arrival snap, the
// per-tick `self.SendFlags = 1` that keeps CSQC from rendering a frozen
// brush, MovingBrush_AddToList/RemoveFromList — all of it, unmodified.
//
// The copy is a translation of a fixed vector, so it stays valid for the
// life of the map.  Two consequences worth knowing:
//   * A trigger_changetarget that rewrites a real path_corner's .target
//     mid-game will NOT be seen by the copy.  No corpus map does this to a
//     guntarget chain, and the alternative is duplicating the mover.
//   * Two func_guntargets sharing one corner chain get one copy EACH, which
//     is required anyway: the translation is per-brush.
//

const float FGUNTARGET_START_ON = 1;

// Sanity cap on the path walk.  A guntarget chain is a short loop (hc2's
// seven are two corners each); anything past this is a map authoring error
// or a chain we would rather truncate than hang the map load on.
const float GT_MAX_CORNERS = 64;

// Runtime state.  Everything else — .train_target, .train_state, .movesnd,
// .stopsnd, .volume, .dmg, the PATH_* corner spawnflags, the resolved
// sound paths — is reused from sv_func_train.qc, which is why this file
// MUST compile immediately after it: QC forward-declares functions but
// NOT fields.
.float  gt_on;              // HL m_on: is the target switched on?
.entity gt_corner_head;     // on the guntarget: head of the translated chain
.entity gt_corner_next;     // on each guntarget_corner: chain link
.entity gt_corner_src;      // on each guntarget_corner: the real path_corner

void() guntarget_use;

// Offset from a path_corner's origin to the origin this brush must be given so
// that its CENTRE lands on that corner.
//
// NOW ZERO, AND IT MUST STAY ZERO while sv_func_train.qc applies the offset.
// This used to compute `-(mins+maxs)*0.5` because the mover did not, and the
// translated-corner machinery below exists solely to deliver it.  The mover was
// fixed (FuncTrain_DestOrigin), so returning anything non-zero here would apply
// the centre offset twice and throw every guntarget exactly as far off as it was
// before the workaround existed.  See the header for the full story.
//
// The corner-copy machinery below is left in place rather than ripped out: it is
// now an identity translation and provably harmless, and removing it means
// re-deriving the loop closure, the PATH_* flag copying and the per-corner
// message/wait/speed carry-over, which is a change to test on hc2_c2 rather than
// a change to make in passing.  Keep the copies; keep the offset at zero.
vector() GunTarget_CentreOffset =
{
    return '0 0 0';
};

// Build the translated corner chain.  One-shot: the chain is a fixed
// translation, so there is nothing to rebuild.
void() GunTarget_BuildPath =
{
    if (self.gt_corner_head != world)
        return;                     // already built
    if (self.target == "")
        return;                     // no path — brush just sits where it spawned

    vector off  = GunTarget_CentreOffset();
    entity real = find(world, targetname, self.target);
    entity prev = world;
    entity node = world;
    entity dup  = world;
    float  idx  = 0;

    if (real == world)
    {
        dprint(sprintf("func_guntarget \"%s\": first stop \"%s\" not found in entity list\n",
                       self.targetname, self.target));
        return;
    }

    while (real != world && idx < GT_MAX_CORNERS)
    {
        // Already copied?  Then the real chain loops back on itself (hc2's
        // do: gtN_stp0 -> gtN_stp1 -> gtN_stp0).  Close the copy's loop the
        // same way and stop, or the walk never terminates.
        dup = self.gt_corner_head;
        while (dup != world && dup.gt_corner_src != real)
            dup = dup.gt_corner_next;
        if (dup != world)
        {
            if (prev != world)
                prev.target = dup.targetname;
            return;
        }

        node = spawn();
        node.classname    = "guntarget_corner";
        node.owner        = self;
        node.gt_corner_src = real;
        // Unique by construction: the real corner name for readability in
        // func_train_arrive's debug print, plus the owning edict number and
        // the index so two guntargets sharing a chain cannot collide.  '#'
        // never appears in a Hammer targetname, so find() can't confuse a
        // copy with a real entity.  strzone'd and never freed — 14 strings
        // on hc2_c2, which lives as long as the map does.
        node.targetname   = strzone(sprintf("%s#gtc%g.%g",
                                            real.targetname,
                                            num_for_edict(self), idx));
        // Carry the fields func_train_arrive / func_train_move_tick read off
        // the corner.  Anything not copied here is a corner feature the
        // mover does not consult.
        node.message      = real.message;
        node.wait         = real.wait;
        node.speed        = real.speed;
        node.spawnflags   = real.spawnflags;
        setorigin(node, real.origin + off);

        node.gt_corner_next = self.gt_corner_head;
        self.gt_corner_head = node;

        if (prev == world)
            self.train_target = node;       // anchor corner
        else
            prev.target = node.targetname;

        prev = node;
        idx  = idx + 1;
        real = FuncTrain_NextCorner(real);
    }
};

// HL CGunTarget::Activate — build the path and snap the brush onto the
// first corner.  Idempotent, so guntarget_use can call it if a trigger
// fires before our deferred think has run (trigger_auto fires at map load).
void() GunTarget_Anchor =
{
    if (self.gt_corner_head != world)
        return;

    GunTarget_BuildPath();
    if (self.train_target == world)
        return;

    setorigin(self, self.train_target.origin);
    // Replicate the snap.  Without this CSQC keeps drawing the brush at its
    // editor position until the first move dirties the wire — the identical
    // note sv_func_train.qc:551 records for func_train_find_first.
    self.SendFlags = 1;

    if (cvar("sv_debug_use") || cvar("sv_debug_func_train"))
        dprint(sprintf("[guntarget %s] mins=%v maxs=%v centre-offset=%v "
                       "first corner \"%s\" at %v -> origin %v\n",
                       self.targetname, self.mins, self.maxs,
                       GunTarget_CentreOffset(),
                       self.train_target.gt_corner_src.targetname,
                       self.train_target.gt_corner_src.origin,
                       self.origin));
};

// HL CGunTarget::Stop.  Note it clears takedamage: a stopped guntarget is
// not shootable, which is the whole reason Spawn starts at DAMAGE_NO.
void() GunTarget_Stop =
{
    self.velocity               = '0 0 0';
    self.mover_planned_velocity = '0 0 0';
    self.avelocity              = '0 0 0';
    self.think                  = sub_noop;
    self.nextthink              = 0;
    self.train_state            = 0;
    self.takedamage             = DAMAGE_NO;
    self.gt_on                  = 0;

    MovingBrush_RemoveFromList(self);

    if (self.train_movesound_active)
    {
        SV_StopChannel(self, CHAN_BODY);
        self.train_movesound_active = 0;
    }

    // Push the velocity=0 state so CSQC stops integrating stale velocity —
    // same reason func_train_arrive re-dirties.
    self.SendFlags = 1;
};

// Death.  Reached through .on_killed, NOT by subtracting health here:
// W_ApplyDamage is the tree's damage chokepoint and dispatches .on_killed
// once health crosses zero (sv_weapons.qc:2042).  The same idiom
// func_breakable uses.
//
// .on_killed also takes precedence over .use in that dispatch, which is
// exactly what we need — we carry both.
void() guntarget_killed =
{
    self.health = 0;
    GunTarget_Stop();

    // HL fires pev->message here, not pev->target: `target` is this entity's
    // first path corner.  Trigger_UseTargets only ever walks caller.target,
    // so swap for the duration of the fire and restore — the same swap
    // func_train_arrive performs for a corner's fire-on-pass message.
    // Safe across a delay: SUB_UseTargets copies caller.target into the
    // delayed_use edict synchronously (sv_triggers.qc:128).
    if (self.message == "" || self.message == __NULL__)
        return;

    string saved_target = self.target;
    self.target = self.message;
    // Activator is the guntarget itself — HL passes `this` for both the
    // activator and the caller in CGunTarget::TakeDamage's FireTargets call.
    SUB_UseTargets(self, self, USE_TOGGLE);
    self.target = saved_target;
};

// HL CGunTarget::Use.
//
// One deliberate divergence: HL's m_on is set FALSE in Spawn and never
// assigned again, so ShouldToggle always reports "off" and a USE_TOGGLE can
// only ever switch a guntarget ON — CGunTarget::Stop is unreachable from a
// toggle.  That is a Half-Life bug, not a design; we track gt_on honestly so
// a second toggle switches off, and so a use AFTER a kill re-arms the target
// with full health (which is how a shooting range gets reset).  hc2 never
// notices either way: each of its seven is used exactly once, by the
// multi_manager the previous target's death fires.
void() guntarget_use =
{
    GunTarget_Anchor();                 // no-op once the path is built
    if (self.train_target == world)
        return;

    // HL ShouldToggle — see the matching comment in sv_func_train.qc.
    if (sub_use_type == USE_ON  &&  self.gt_on) return;
    if (sub_use_type == USE_OFF && !self.gt_on) return;

    if (self.gt_on)
    {
        GunTarget_Stop();
        return;
    }

    self.gt_on      = 1;
    self.takedamage = DAMAGE_YES;
    self.health     = self.max_health;

    // Step one corner forward from the anchor and hand the leg to
    // func_train's mover.  Same shape as func_train_use's stopped branch.
    entity next_pc = FuncTrain_NextCorner(self.train_target);
    if (next_pc == world)
        return;         // one-corner path: shootable but stationary, as in HL
                        // (its LinearMove would cover zero distance)

    self.train_target = next_pc;
    func_train_move_to_target();
};

// HL CGunTarget::Start — a START_ON target uses itself once the map is live.
void() guntarget_start =
{
    self.think     = sub_noop;
    self.nextthink = 0;
    sub_use_type   = USE_ON;
    guntarget_use();
};

// Deferred init, 0.1s after spawn so every path_corner has been spawned and
// linked — the same reason func_train defers func_train_find_first.
void() guntarget_activate =
{
    GunTarget_Anchor();

    self.think     = sub_noop;
    self.nextthink = 0;

    if (self.spawnflags & FGUNTARGET_START_ON)
    {
        // ltime, not time: a MOVETYPE_PUSH entity's thinks are dispatched
        // against its own integration clock.  HL spells this
        // `pev->nextthink = pev->ltime + 0.3`.
        self.think     = guntarget_start;
        self.nextthink = self.ltime + 0.3;
    }
};

/*QUAKED func_guntarget (0 .5 .8) ? START_ON
A func_train with hit points — a moving shooting-range target.  Walks its
path_corner chain while switched on, takes damage while it walks, and fires
"message" when it is destroyed.

Unlike func_train the brush's CENTRE is placed on each corner, not its
origin, so a target modelled around its own centre lines up with the path.

"target"      First path_corner in the chain.
"speed"       Move speed in units/sec (default 100).
"health"      Hit points.  Restored in full each time the target is switched on.
"message"     Targetname fired when the target is destroyed.
"movesnd"     Move sound enum (1..13), as func_train.
"stopsnd"     Stop sound enum (1..8), as func_train.
"volume"      Sound volume (default 0.85).

START_ON (1)  Start walking 0.3s after spawn with no trigger.
*/
void() func_guntarget =
{
    if (self.speed == 0)  self.speed  = 100;    // HL CGunTarget::Spawn
    if (self.volume == 0) self.volume = 0.85;

    // NOTE: .angles is deliberately left alone, unlike func_wall /
    // func_breakable which zero it.  Those never rotate, so a stray editor
    // angle on an ORIGIN-less submodel is always a mistake worth stamping
    // out; a guntarget is a mover and a mapper may legitimately have rotated
    // one.  HL does not zero it either.  None of the seven corpus placements
    // carries an angles key, so this costs nothing today.

    // Wire through brushsync — setmodel (which is what gives us the mins/maxs
    // the centre offset is computed from), MOVETYPE_PUSH, SOLID_BSP, the
    // render keys and the CSQC send function.
    SV_InitReplicatedSolidBrush();
    self.brush_type = BRUSH_TYPE_TRAIN;

    // Sound enums.  HL's CGunTarget is a CBaseMonster and has no move/stop
    // sound of its own, but the mover we share with func_train reads these
    // fields on every leg, so honouring them costs four lines and means a
    // mapper who sets movesnd gets what they asked for instead of silence.
    self.train_movesound_path = FuncTrain_MoveSound(self.movesnd);
    self.train_stopsound_path = FuncTrain_StopSound(self.stopsnd);
    if (self.train_movesound_path != "")
        precache_sound(self.train_movesound_path);
    if (self.train_stopsound_path != "")
        precache_sound(self.train_stopsound_path);

    // "Don't take damage until on" (HL comment, verbatim).
    self.takedamage = DAMAGE_NO;
    self.max_health = self.health;
    self.gt_on       = 0;
    self.train_state = 0;

    // FL_MONSTER is NOT set, although HL sets it.  There it only buys autoaim
    // and CLASS_MACHINE classification; here the flag is load-bearing for
    // things a brush must stay out of — GoldSrc_UnknownRelay's monster
    // searches (sv_goldsrc_compat.qc:957), the +use refusal in sv_use.qc:58,
    // and the flesh impact material in sv_weapons.qc:943, which would make
    // every bullet hit spray blood off a metal target.

    self.use       = guntarget_use;
    self.on_killed = guntarget_killed;
    // Crush.  HL's CGunTarget never sets pev->dmg, so this only ever does
    // something for a mapper who asks for it — but wiring it means a blocked
    // guntarget can clear its own obstruction instead of stalling forever
    // (a blocked MOVETYPE_PUSH brush stops advancing .ltime, and every think
    // in the shared mover is scheduled on ltime).
    self.blocked   = func_train_blocked;

    self.think     = guntarget_activate;
    self.nextthink = time + 0.1;
};
