//
//  sv_trigger_transition.qc  –  HL/GoldSrc trigger_transition
//
//  Brush volume that gates a trigger_changelevel: when a
//  trigger_changelevel fires (touch OR external .use), the engine
//  checks for trigger_transitions whose targetname matches the
//  changelevel's `landmark` key.  If any exist, the level change
//  proceeds only if a player is inside one of their bounding boxes.
//
//  Typical setup:
//    - info_landmark    targetname "lm_door1"
//    - trigger_transition targetname "lm_door1"  (same name)
//    - trigger_changelevel landmark "lm_door1" + map "..."
//
//  Why this entity exists: in elevators / airlocks the changelevel
//  is fired by a door-close event (.use), not by player touch.
//  Without a transition check the level would change even if the
//  player was outside the elevator.  trigger_transition fixes that
//  by requiring the player be inside the elevator (transition
//  volume) at the moment of fire.
//
//  HL also uses trigger_transition to filter which non-player
//  entities transfer to the next map.  That feature isn't
//  implemented here — changelevel in this mod doesn't preserve
//  arbitrary entity state across the boundary in the first place
//  (the engine restarts cleanly).  The volume only gates the
//  player-presence check.
//
//  Keys:
//    targetname  — MUST match info_landmark and the trigger_changelevel
//                  `landmark` value.
//

/*QUAKED trigger_transition (.5 .5 .5) ?
Brush volume that gates a trigger_changelevel's fire on
player-in-volume.

"targetname"  share with info_landmark and trigger_changelevel.landmark
*/
void() trigger_transition =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    self.effects   |= EF_NODRAW;          // hide the trigger brush texture
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_NOT;          // pure bbox marker — no touch fire
    // .absmin/.absmax are computed from the brush model bounds by
    // the engine.  Trigger_Transition_PlayerInside (in
    // sv_trigger_changelevel.qc) reads them directly.
};

// Public helper — returns 1 if at least one player's origin sits
// inside the bbox of a trigger_transition whose targetname matches
// `landmark_name`.  Returns 1 (allow) when no matching transition
// exists at all — the changelevel proceeds without a gate in that
// case, matching HL's "no transition specified = no check" rule.
//
// Called from trigger_changelevel_fire().  Walks both lists with
// find()-chains since both player and trigger_transition counts
// are small in practice.
float(string landmark_name) Trigger_Transition_PlayerInside =
{
    if (landmark_name == "") return 1;   // no gate requested

    entity tx = find(world, classname, "trigger_transition");
    float found_any_transition = 0;
    while (tx)
    {
        if (tx.targetname == landmark_name)
        {
            found_any_transition = 1;
            entity p = find(world, classname, "player");
            while (p)
            {
                // AABB containment.  Player origin is at bbox
                // center for QW players; using just the origin is
                // a near-exact membership test for typical
                // transition volumes (which are always at least
                // player-bbox-sized).
                if (p.origin_x >= tx.absmin_x && p.origin_x <= tx.absmax_x
                 && p.origin_y >= tx.absmin_y && p.origin_y <= tx.absmax_y
                 && p.origin_z >= tx.absmin_z && p.origin_z <= tx.absmax_z)
                    return 1;
                p = find(p, classname, "player");
            }
        }
        tx = find(tx, classname, "trigger_transition");
    }

    // Had a landmark name but no matching trigger_transition
    // anywhere — treat as "no gate".  Matches HL behaviour.
    if (!found_any_transition) return 1;

    // Found transitions but no player inside any — block.
    return 0;
};
