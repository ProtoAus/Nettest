//
//  sv_water.qc  –  func_water  (translating water/slime/lava brush)
//
//  GoldSrc func_water is functionally a non-solid func_door that
//  holds water/slime/lava contents — primarily used for "rising
//  water" / flooding scenarios.  The brush translates on trigger
//  exactly like a sliding door; the engine reads the brush's water
//  texture (or `.skin` contents code) to apply the swim leaf.
//
//  Implementation: pre-stamp DOOR_PASS_THROUGH on spawnflags and
//  delegate to func_door, then override solid + dmg.  This inherits
//  the full sliding-door state machine (use, blocked, START_OPEN,
//  TOGGLE, USE_ONLY, etc.) without code duplication.
//
//  Sound keys (movesnd / stopsnd / sounds) are accepted but have no
//  effect — water doesn't make door sounds in HL.  Stripped before
//  the func_door handoff to match.
//
//  Spawnflags map cleanly to func_door's bits where they overlap:
//    1  Starts open  → DOOR_START_OPEN
//    4  Don't link   → no-op (was a stub key in HL too)
//    8  Passable     → DOOR_PASS_THROUGH (we force this regardless)
//    32 Toggle       → DOOR_TOGGLE
//    256 Use only    → DOOR_USE_ONLY
//

void() func_door;        // sv_doors.qc

// Mapper key — wave amplitude override.  Engine may or may not read
// this; declared so the BSP entity-block parser populates the field
// (rather than dropping the key on the floor).
.float WaveHeight;

/*QUAKED func_water (0 .5 .8) ? STARTS_OPEN x DONTLINK PASSABLE x TOGGLE x x USE_ONLY
Translating water/slime/lava brush.  Inherits func_door's lifecycle
for rising/falling on trigger.

"angles"     direction (use 'down -90 0' for falling water)
"speed"      translation speed (default 100)
"wait"       seconds before auto-close (-1 = stay open)
"lip"        residual lip after move
"distance"   explicit move distance (overrides lip calc)
"skin"       contents type (-3 water, -4 slime, -5 lava)
"WaveHeight" override of worldspawn-default surface wave height
*/
void() func_water =
{
    // Force PASS_THROUGH so func_door sets the brush non-solid AND
    // skips the proximity-touch trigger spawn.  Water can't be
    // +use'd into existence by walking up to it.
    self.spawnflags = self.spawnflags | 8;
    // Clear the bit-4 flag — HL says "Don't link" is bogus / unused,
    // but func_door reads bit 4 as UNBLOCKABLE which would make a
    // water column that won't reverse on block.  Strip it to be safe.
    self.spawnflags = self.spawnflags & ~4;

    // Default skin = water if mapper didn't pick.
    if (!self.skin)
        self.skin = -3;

    // Strip sound keys — none of them apply to water in HL, so don't
    // let func_door precache or play them.
    self.sounds  = 0;
    self.movesnd = 0;
    self.stopsnd = 0;
    self.noise1  = "";
    self.noise2  = "";

    // No crush damage on water — it's never solid, can't pin anything.
    self.dmg = 0;

    func_door();

    // SOLID_BSP, not SOLID_NOT — and this is the opposite of what it looks like.
    //
    // A negative .skin makes FTE treat every brush in the model as a VOLUME of
    // that content rather than as geometry: World_ClipMoveToEntity only lets the
    // brush block a trace when the trace's own contents mask includes the forced
    // contents (engine world.c:1327), and a mask is built from the mover's solid
    // type and NEVER includes water.  So a player, a bullet and a grenade all
    // pass straight through exactly as before.
    //
    // What SOLID_NOT cost us was visibility, not permeability.  Contents queries
    // walk the LINKED entities (World_ContentsOfLinks) and skip SOLID_NOT
    // outright — and the engine does not even link a SOLID_NOT entity into the
    // area grid.  So the water was unreachable: pointcontents/pointcontentsmask
    // both returned "empty" inside de_rats' pools and the player walked along the
    // bottom instead of swimming.  Being linked is the whole fix.
    //
    // PASS_THROUGH above still does the useful half of what SOLID_NOT did — it
    // stops func_door spawning a proximity +use trigger on the pool.
    self.solid = SOLID_BSP;
    // RELINK.  Assigning .solid does not move an entity into the area grid --
    // linking happens inside setmodel/setorigin, and func_door ran those while
    // PASS_THROUGH still had this brush SOLID_NOT, which World_LinkEdict skips
    // outright (world.c:641).  Without this the brush stays absent from the grid
    // and every contents query keeps answering "empty" no matter what .solid
    // says afterwards -- which is exactly the bug this whole change is fixing.
    setorigin(self, self.origin);
};
