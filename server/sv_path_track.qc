//
// sv_path_track.qc — HL/GoldSrc path_track point entity
//
// Pure data entity — same shape as path_corner, but used by
// func_tracktrain (which walks path_track chains) rather than
// func_train (which walks path_corner chains).  Spawnflag bit
// layout differs from path_corner so the entities aren't
// interchangeable at the wire level.
//
// Keys recognised here (consumer-driven semantics noted in the
// .fgd):
//   target   — targetname of the next path_track in the chain.
//   message  — "Fire On Pass" — tracktrain fires this on arrival.
//   wait     — "Wait here" seconds — tracktrain pauses this long.
//   speed    — "New train speed" — tracktrain adopts this speed.
//   angles   — alignment hint (unused by basic auto-orient path).
//
// Spawnflags (consumer-driven; func_tracktrain reads them at
// arrival):
//    1  DISABLED        — skip when iterating the chain (basic
//                         impl just leaves the corner in place;
//                         consumer can later add iteration filter).
//    2  FIRE_ONCE       — fire `message` only on first arrival.
//    4  BRANCH_REVERSE  — branch direction flag (unused in v1).
//    8  DISABLE_TRAIN   — stops user control past here (used by
//                         the runaway-train pattern in HL — v1
//                         just stops the train).
//   16  TELEPORT        — snap to this track instantly.
//

void() path_track =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    // No use handler — consumers read fields directly.
    if (cvar("sv_debug_func_train"))
        dprint(sprintf("[path_track] spawn targetname=\"%s\" target=\"%s\" origin=%v\n",
                       self.targetname, self.target, self.origin));
};
