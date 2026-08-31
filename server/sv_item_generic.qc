//
//  sv_item_generic.qc  –  Sven Co-op "item_generic" model-display prop
//
//  Sven's own docs describe it as "widely used as a reliable way to display
//  prop models in the map", and that is exactly the scope implemented here:
//  a studio model placed in the world, with the render/skin/body/sequence
//  keys honoured.
//
//  Two behaviours are deliberate, not omissions — they are what Sven itself
//  specifies:
//    - Touch is ALWAYS ignored, even when the TOUCH_ONLY flag is set.  Sven:
//      "This item ignores all player touch (even if flag selected)".  Maps
//      that want a collidable pickup are told to use item_security instead.
//    - USE only does anything when the USE_ONLY flag is set, and here that
//      means "fire my target".  This mod has no HL inventory system, so
//      there is nothing to put in a backpack; firing the target is the part
//      map logic can actually observe.  item_inventory is the entity that
//      would need the inventory layer, and it is not implemented.
//
//  Frame driving differs from cycler on purpose.  cycler runs a 20 Hz QC
//  frame driver because FTE's MDL auto-advance can stall for a render frame
//  at a sequence loop boundary (apache.mdl's rotor).  cycler is a debug
//  entity placed once or twice; item_generic is placed in BULK — Sven maps
//  use it as general set dressing — so paying a per-entity 20 Hz SendFlags
//  dirty for every prop would be a real bandwidth cost for a cosmetic fix.
//  So the driver only runs when the mapper explicitly set "framerate";
//  otherwise the engine auto-cycles the sequence on its own.
//

void() BrushSync_ApplyRenderKeys;                                 // sv_brushsync.qc
void(entity caller, entity who, float useType) SUB_UseTargets;    // sv_triggers.qc

// .body / .sequence / .angle are declared in sv_cycler.qc, which precedes
// this file in sv_progs.src.  Only the keys nothing else parses are new here.
.string sequencename;    // Sven: sequence by NAME; the numeric key overrides it
.vector minhullsize;     // Sven: explicit bbox override (both must be set)
.vector maxhullsize;

// Sven spawnflags.  TOUCH_ONLY is parsed and deliberately does nothing (see
// the header); NOT_IN_DEATHMATCH is documented obsolete by Sven itself.
const float ITEMGEN_TOUCH_ONLY       = 128;
const float ITEMGEN_USE_ONLY         = 256;
const float ITEMGEN_USE_NO_LOS       = 512;
const float ITEMGEN_NO_RESPAWN       = 1024;
const float ITEMGEN_NOT_IN_DM        = 2048;

const float ITEMGEN_TICK = 0.05;

void() item_generic_think =
{
    self.frame     = self.frame + self.framerate * ITEMGEN_TICK;
    self.SendFlags = 1;                  // dirty the wire so the frame replicates
    self.nextthink = time + ITEMGEN_TICK;
};

void() item_generic_use =
{
    // Only responds when the mapper ticked "USE Only" — matches Sven, where
    // an item_generic without that flag cannot be interacted with at all.
    if (!(self.spawnflags & ITEMGEN_USE_ONLY))
        return;
    if (!self.target || self.target == "")
        return;
    SUB_UseTargets(self, activator, USE_TOGGLE);
};

/*QUAKED item_generic (.3 .6 .3) (-8 -8 -8) (8 8 8) x x x x x x x TOUCH_ONLY USE_ONLY USE_NO_LOS NO_RESPAWN NOT_IN_DEATHMATCH
Sven Co-op prop-model display entity.  Shows a studio model; never picked up.

"model"          model to display, path from the game dir (required)
"skin"           model skin index
"body"           bodygroup combo
"sequence"       animation index (overrides sequencename)
"sequencename"   animation by name
"scale"          size multiplier
"framerate"      set non-zero to drive the animation from the server
"minhullsize"    explicit bbox min (set both to override)
"maxhullsize"    explicit bbox max
"solid"          0 = non-solid (default), 4 = SOLID_BBOX
"movetype"       0 = static (default), 6 = toss
"rendermode" "renderamt" "rendercolor" "renderfx"  as func_wall
"target"         fired on use, when the USE_ONLY flag is set
*/
void() item_generic =
{
    if (!self.model || self.model == "")
    {
        dprint("item_generic: no model set, removing\n");
        remove(self);
        return;
    }

    precache_model(self.model);
    setmodel(self, self.model);

    // Sven exposes both as keyvalues.  Default is a decorative, walk-through
    // prop: the docs point mappers at item_security when they want collision,
    // so anything solid here has to be asked for explicitly.
    if (self.solid != SOLID_BBOX && self.solid != SOLID_SLIDEBOX)
        self.solid = SOLID_NOT;
    if (self.movetype != MOVETYPE_TOSS && self.movetype != MOVETYPE_BOUNCE)
        self.movetype = MOVETYPE_NONE;

    // Explicit hull override.  Only applied when the mapper set BOTH corners,
    // since a half-specified hull collapses the bbox and takes the prop out of
    // the PVS -- the same failure mode documented in sv_cycler.qc for props
    // that got a hardcoded 32qu cube.
    //
    // Stashed rather than applied immediately: the drop below has to run against
    // HL's item hull, not this one.  Re-applied straight after.
    float have_hull = (self.minhullsize != '0 0 0' && self.maxhullsize != '0 0 0');

    // Sequence.  The numeric key wins when present; otherwise resolve the name
    // through the model itself.
    //
    // A name MISS is normal, not an error: Sven maps routinely ask for "idle"
    // on props whose only sequence is actually called "idle1" (all 41 of the
    // ginsengavenger props in -sp_campaign_portal do exactly this).  Sven falls
    // back to sequence 0 in that case, which is what leaving .frame alone
    // already gives us, so the visual result matches.  The message is therefore
    // gated behind `developer` — FTE's dprint is unconditional, unlike vanilla
    // QC's, so an ungated one costs 41 console lines on a single map load.
    if (self.sequence > 0)
        self.frame = self.sequence;
    else if (self.sequencename && self.sequencename != "")
    {
        float seq = frameforname(self.modelindex, self.sequencename);
        if (seq >= 0)
            self.frame = seq;
        else if (cvar("developer"))
            dprint(sprintf("item_generic: model \"%s\" has no sequence \"%s\" — using sequence 0\n",
                self.model, self.sequencename));
    }

    BrushSync_ApplyRenderKeys();

    // DROP TO FLOOR, because item_generic is an ITEM.
    //
    // Sven's FGD derives it from ItemWithDefaultModel -> Pickup
    // (sven-coop.fgd:3412, :392, :289), which is the CItem family, and
    // CItem::Spawn ends with DROP_TO_FLOOR (halflife/dlls/items.cpp).  There is no
    // "don't drop" spawnflag anywhere in that chain - Pickup's flag list is
    // TOUCH Only / USE Only / Can Use w/o LoS / Disable Respawn and nothing else -
    // so every item_generic in every Sven map is standing on whatever is under it,
    // not on the coordinate the mapper typed.  th_ep1_01 has eleven skeleton props
    // authored a few units high and they hang in the air here for exactly that
    // reason.
    //
    // A FAILED drop is left alone rather than removed, and that is a deliberate
    // divergence: CItem::Spawn deletes the entity and logs "fell out of level",
    // which for a decorative prop hung deliberately over a stairwell would silently
    // delete set dressing.  Leaving it where the mapper put it is the safer half of
    // the difference, and it is the half that cannot lose content.
    //
    // droptofloor() traces the entity's own bbox 256 units down, so a prop on a
    // table lands on the table.  WHICH bbox matters enormously, and using the
    // model's own is what kept th_ep1_01's sitting skeleton hanging in the air.
    //
    // CItem::Spawn (halflife/dlls/items.cpp) sizes the item to a FIXED
    // (-16,-16,0)..(16,16,16) hull and only THEN calls DROP_TO_FLOOR.  Every
    // CItem-derived entity in Half-Life — item_generic included, via
    // ItemWithDefaultModel -> Pickup -> CItem — therefore drops on a 32x32x16
    // box regardless of how big or small its display model is.
    //
    // Dropping on the studio model's own bbox instead fails in both directions.
    // A wide model (models/skeleton.mdl posed "s_sitting" spans most of a 64qu
    // tile) starts solid against the wall or the crate it was authored beside,
    // droptofloor returns 0, and the prop keeps the raw mapper Z — the reported
    // "floating skeleton".  A model with a degenerate header bbox took the
    // `maxs != mins` branch below and was skipped outright.
    //
    // So: drop on HL's hull, then put the real hull back.  The display hull is
    // restored afterwards because it is what feeds PVS culling here — clamping a
    // 256qu-tall tree to a 16qu box would pop it out of view at close range,
    // which HL doesn't care about (it culls studio models by model extents) but
    // FTE does.
    if (self.movetype == MOVETYPE_NONE)
    {
        vector pre  = self.origin;
        vector kmin = self.mins;
        vector kmax = self.maxs;

        setsize(self, '-16 -16 0', '16 16 16');
        float landed = droptofloor();
        if (!landed)
            setorigin(self, pre);

        // A FAILED drop is left in place rather than removed, and that is a
        // deliberate divergence: CItem::Spawn deletes the entity and logs "fell
        // out of level", which for a decorative prop hung deliberately over a
        // stairwell would silently delete set dressing.  Leaving it where the
        // mapper put it is the safer half of the difference, and it is the half
        // that cannot lose content.
        if (have_hull)
            setsize(self, self.minhullsize, self.maxhullsize);
        else
            setsize(self, kmin, kmax);

        if (cvar("sv_debug_spawns"))
        {
            if (!landed)
                dprint(sprintf("item_generic \"%s\" at %v: no floor within 256qu, left in place\n",
                               self.model, pre));
            else if (self.origin != pre)
                dprint(sprintf("item_generic \"%s\" dropped %g units to the floor\n",
                               self.model, pre_z - self.origin_z));
        }
    }
    else if (have_hull)
        setsize(self, self.minhullsize, self.maxhullsize);

    // `angle KEY` is HL entdata's single-axis yaw shortcut; fold it into
    // angles_y exactly as cycler does, since FTE's parser may not translate it
    // depending on where the map came from.
    if (self.angles == '0 0 0' && self.angle != 0)
    {
        self.angles_y = self.angle;
        self.angle    = 0;
    }

    self.use = item_generic_use;

    // Server-driven animation only on request — see the header for why this
    // deliberately differs from cycler.
    if (self.framerate > 0)
    {
        self.think     = item_generic_think;
        self.nextthink = time + ITEMGEN_TICK;
    }
};
