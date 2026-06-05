//
//  sv_info_landmark.qc  –  HL/GoldSrc info_landmark point entity
//
//  Defines "the same point in space" in two adjacent maps so that a
//  level transition can carry the player at a consistent relative
//  offset.  In HL the engine uses this for landmark-relative spawn:
//  on level change, the player's offset from the source map's
//  landmark gets re-applied to the destination map's landmark with
//  the matching targetname.
//
//  In this mod we DON'T implement landmark-relative spawn (it needs
//  save/restore plumbing across the level boundary that's well out
//  of scope of this entity).  info_landmark exists here as a no-op
//  marker so:
//    1. .bsp entdata loads cleanly (engine doesn't warn on unknown
//       classnames),
//    2. trigger_transition can share its targetname for the in-area
//       check (see sv_trigger_transition.qc), which is the primary
//       use-case once the landmark-relative spawn is unimplemented.
//
//  Keys:
//    targetname  — name shared with trigger_transition entities.
//

/*QUAKED info_landmark (0 0 1) (-8 -8 -8) (8 8 8)
Point marker used by trigger_changelevel + trigger_transition.
Position is the "same point" reference shared with the destination
map's matching info_landmark.

"targetname"  unique name — trigger_transition uses the same value
              to gate the level change on player-in-volume.
*/
void() info_landmark =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    // .origin is set by the engine from the entdata; we don't touch
    // it.  Nothing else to do — the entity exists to be located by
    // find(world, targetname, name).
};
