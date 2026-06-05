//
// sv_path_corner.qc — HL/GoldSrc path_corner point entity
//
// Pure data entity — exists in the entity list with a named origin,
// a "next stop" target, and optional per-stop keys (message, wait,
// speed) that consumer entities (func_train, trigger_camera, etc.)
// read from when they reach this corner.  path_corner itself has no
// behaviour; all path-following logic lives in the consumer.
//
// Keys recognised here (consumer-driven semantics noted in the .fgd):
//   target   — targetname of the next path_corner in the chain.
//   message  — "Fire On Pass" — consumer fires this when passing.
//   wait     — "Wait here" seconds — consumer pauses this long.
//   speed    — "New train speed" — consumer adopts this speed.
//   angles   — Pitch/Yaw/Roll for craft alignment (apache/osprey).
//
// Spawnflags (consumer-driven):
//    1  WAIT_FOR_RETRIGGER — stop here until triggered.
//    2  TELEPORT           — teleport to this corner.
//    4  FIRE_ONCE          — fire the "message" target only once.
//
// No consumer entities exist in nettest yet that read path_corner
// (no func_train, no trigger_camera with path attachment).  Adding
// path_corner here so maps that ship with path entities don't error
// at BSP load; future consumers can iterate the chain via
// find(world, targetname, prev_corner.target).
//

// Mapper keys not already declared elsewhere.  message + target + wait
// are standard fields; speed and angles are standard too.  No new
// fields needed for path_corner itself.

void() path_corner =
{
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_NOT;
    // No use handler — consumers read our fields directly.
    if (cvar("sv_debug_env_beam"))
        dprint(sprintf("[path_corner] spawn targetname=\"%s\" target=\"%s\" origin=%v\n",
                       self.targetname, self.target, self.origin));
};
