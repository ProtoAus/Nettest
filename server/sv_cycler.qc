//
//  sv_cycler.qc  –  cycler  (HL/GoldSrc point entity)
//
//  Model viewer: places an MDL in the world and lets the engine
//  auto-cycle its animation.  Originally a development tool for
//  previewing animations in-map; mappers also use it as a cheap
//  static prop (decorative scenery without scripting).
//
//  Distinct from cycler_sprite (sv_cycler_sprite.qc), which
//  handles SPR billboards and frame-by-frame advances.  cycler
//  handles MDL sequence playback — the engine's MDL renderer
//  cycles through the model's animation frames on its own once we
//  set `.frame` to the desired sequence-start frame and leave it
//  alone.
//
//  Keys (HL parity):
//    "model"        MDL path — required.
//    "sequence"     animation index — selects which sequence to
//                   play.  0 = idle / first sequence.
//    "frame"        starting frame within the sequence (0..255).
//    "body"         bodygroup combo (FTE: `.skin` is used; we
//                   store .body for future plumbing).
//    "skin"         skin index.
//    "angles"       Pitch Yaw Roll for the model's pose.
//    "rendermode"   0..5 GoldSrc render mode.
//    "renderamt"    0..255 fx-amount.
//    "rendercolor"  "R G B" 0..255 tint.
//    "targetname"   trigger identifier.
//
//  Behaviour scope (compatibility, not bug-for-bug):
//    - Engine auto-cycles MDL frames; we don't manage them tick by
//      tick.  Matches HL's "set up + leave alone" behaviour for
//      animated MDLs.
//    - Solid bbox so projectiles/players touch it (HL: human-sized
//      collision).  takedamage + on_damaged forwarded to a no-op
//      so trace shots feel right without the entity dying.
//    - .use is wired to a noop (HL's "freeze + step on hit"
//      mechanic was always documented as a development convenience;
//      no real map relies on the in-game freeze toggle).  Use
//      cycler_sprite if you need shoot-to-step semantics.
//

void() BrushSync_ApplyRenderKeys;        // sv_brushsync.qc

// Bodygroup combo.  As of Patch 131 this is a REAL entvar: the engine registers
// `body` in progdefs.h, ships it in entity_state_t under PEXT2_BODYGROUP, and
// gl_hlmdl.c divides it back out per bodypart.  It used to be parsed and stored
// and read by nothing at all.  Declared here rather than in sv_ai_defs.qc only
// because this file has owned the map-key spelling since the cycler landed.
.float body;
.float sequence;    // MDL animation index (map key — declared shared
                     // with sv_env_sprite.qc; QC accepts duplicate
                     // .float decls of matching type harmlessly)
.float angle;       // single-axis compass shortcut — HL/Quake map
                     // entdata uses `angle KEY` as a yaw hint that
                     // gets translated to angles_y.  Declared here
                     // so FTE's entdata parser has a slot to write
                     // it into; the spawn function reads it + folds
                     // into self.angles_y.

void() cycler_damaged =
{
    // Resurrect on damage so the prop never dies / disappears.
    self.health = 9999;
};

void() cycler_killed =
{
    // Defensive — same resurrect path as cycler_sprite, in case a
    // very large hit overflowed into on_killed.
    self.health     = 9999;
    self.takedamage = DAMAGE_YES;
};

void() cycler_use =
{
    // Toggle target — no-op stub.  HL's "freeze + step on damage"
    // mechanic was always documented as a development convenience;
    // map triggers calling .use shouldn't crash but don't need to
    // change visible behaviour.
};

// Per-tick frame driver.  Advances self.frame by framerate * tick_dt
// every tick and lets the engine read the smoothly-advancing value.
// The engine's auto-loop at the MDL sequence boundary can stall for
// a render frame on some HL models (apache.mdl's rotor sequence is
// the canonical example) — driving .frame from QC means the engine
// never has to figure out the loop point itself.  The frame value
// is a float that the renderer treats modulo the sequence length,
// so we just keep adding without bound.
//
// 0.05s think interval (20 Hz) is fine-grained enough to keep
// interpolation continuous between server updates without flooding
// the client with frame snapshots.
const float CYCLER_TICK = 0.05;

void() cycler_think =
{
    self.frame = self.frame + self.framerate * CYCLER_TICK;
    self.SendFlags = 1;        // dirty wire so the new frame replicates
    self.nextthink = time + CYCLER_TICK;
};

// ---------------------------------------------------------------------------
//  IS THIS A STUDIO (HL) MODEL, OR A LEGACY QUAKE MDL?
//
//  The distinction decides what .frame MEANS, and the driver above is only
//  correct for one of them:
//
//    legacy Quake .mdl  - .frame is a FRAME index; advancing it animates.
//    HL studio .mdl     - .frame is a SEQUENCE index.  The client advances
//                         time within the current sequence by itself (exactly
//                         how every monster in this mod animates), so QC must
//                         set the sequence and then LEAVE IT ALONE.
//
//  Both use the .mdl extension, so the format cannot be told from the path.
//  skel_create succeeds and reports a bone count only for a skeletal model,
//  which makes it an exact runtime discriminator - the same probe the
//  gargantua uses to find its attachment tags.
//
//  Measured: all 82 cycler entities in the 121-map corpus are studio models
//  (drone.mdl 31, hair.mdl 17, shoppingcart.mdl 11, apache.mdl, pipe_bubbles,
//  rengine, fungus...), and every one of them sets "sequence" "0".  So the
//  driver was walking a SEQUENCE index upward at framerate*20 = 200 per second
//  on all of them.  Most survive only because they have exactly one sequence
//  and the renderer clamps; rengine.mdl has three and genuinely strobes.
//  It also cost a forced entity snapshot per prop per tick - 620/sec on
//  pizza_ya_san2's 31 drones alone - to publish a value nothing should read.
//
//  The apache-rotor stall the driver was written for is a LEGACY MDL problem;
//  apache.mdl here is a 9-bone studio model with one sequence.  Leaving the
//  legacy path exactly as it was costs nothing and keeps that fix intact.
//
//  DO NOT COPY THIS TO sv_cycler_sprite.qc.  A sprite really does use .frame
//  as a frame index, and its driver is correct as written.
// ---------------------------------------------------------------------------
float(entity e) Cycler_IsStudioModel =
{
    float sk, nb;

    sk = skel_create(e.modelindex);
    if (!sk)
        return FALSE;
    nb = skel_get_numbones(sk);
    skel_delete(sk);
    return nb > 0;
};

/*QUAKED cycler (.5 .5 .5) (-16 -16 -16) (16 16 16)
HL/GoldSrc model viewer point entity.  Auto-cycles the model's
animation; takes damage as a static prop without dying.

"model"        MDL path (e.g. "models/scientist.mdl").
"sequence"     animation index.
"frame"        starting frame.
"angles"       Pitch Yaw Roll.
"rendermode"   0..5 GoldSrc render mode.
"renderamt"    0..255 fx-amount.
"rendercolor"  "R G B" 0..255 tint.
"targetname"   trigger identifier.
*/
void() cycler =
{
    if (!self.model || self.model == "")
    {
        dprint("cycler: no model set, removing\n");
        remove(self);
        return;
    }

    precache_model(self.model);
    setmodel(self, self.model);

    // Keep the MDL's authored bounding box (setmodel set absmin /
    // absmax from the model's internal bounds).  The earlier
    // override to a 32-qu cube — copied from HL's CCycler::Spawn
    // — works fine for human-sized props (scientist.mdl etc.) but
    // collapses the bbox for large props like apache.mdl, which
    // is dozens of units wide.  PVS culling reads abs-bounds for
    // entity visibility, so a tiny bbox on a large model can
    // cause the entity to disappear from view when its origin's
    // leaf isn't directly visible even though the visual mesh
    // extends into a visible leaf.  Trusting the MDL is the safer
    // default; users who want human-sized collision can wrap with
    // a func_wall.

    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;       // pure visual prop — no collision

    // Frame / sequence handling.  Default frame 0 covers the
    // common case (rest pose).  HL's `sequence` key maps to an
    // animation slot inside the MDL; FTE's MDL renderer uses
    // .frame as the cycling cursor for legacy MDL formats.  For
    // HL-style sequenced MDLs we forward sequence → frame as a
    // starting hint; the engine cycles automatically once frame
    // is set.
    if (self.sequence > 0 && self.frame == 0)
        self.frame = self.sequence;

    // Framerate — ensure non-zero so the engine knows to advance
    // the MDL animation.  Zero framerate freezes the model on the
    // current frame; for some MDL formats (HL .mdl with empty
    // sequence-0) frame 0 is a degenerate pose that doesn't
    // render the mesh visibly.  10 Hz is the cycler_sprite default.
    if (self.framerate <= 0)
        self.framerate = 10;

    self.use = cycler_use;

    BrushSync_ApplyRenderKeys();

    // Convert the `angle` single-axis shortcut to `angles_y` (yaw)
    // — HL's BSP entdata uses `angle KEY` as a 1-d compass hint
    // that the FGD converts to `angles 0 KEY 0`.  FTE's parser may
    // or may not do that translation depending on map source.
    // Mirror it here so the user's mapper-set yaw applies.
    if (self.angles == '0 0 0' && self.angle != 0)
    {
        self.angles_y = self.angle;
        self.angle    = 0;
    }

    // Hook the per-tick frame driver ONLY for legacy Quake MDLs, where .frame
    // is a frame index and advancing it is what animates the model.  Without
    // it, FTE's MDL auto-advance can stall for a render frame at the sequence
    // loop boundary (visible as a one-frame pause every time a rotor completes
    // a rotation), which is why the driver exists.
    //
    // On a studio (HL) model .frame is the SEQUENCE index instead, the client
    // advances animation time on its own, and driving .frame does active harm.
    // See Cycler_IsStudioModel above for the measurement.
    if (!Cycler_IsStudioModel(self))
    {
        self.think     = cycler_think;
        self.nextthink = time + CYCLER_TICK;
    }
    else if (cvar("sv_debug_ent_types"))
    {
        print(sprintf("[cycler] %s is a studio model - sequence %g held, "
                      "frame driver not installed\n", self.model, self.frame));
    }
};
