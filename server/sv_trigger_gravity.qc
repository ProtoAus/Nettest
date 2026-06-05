//
//  sv_trigger_gravity.qc  –  trigger_gravity
//
//  Brush volume that overrides a touching player's gravity multiplier.
//  Standard HL semantics: the multiplier sticks until something else
//  changes it (another trigger_gravity, respawn, or a 1.0-trigger to
//  reset).  Unlike trigger_hurt this fires every touch — there's no
//  per-victim cooldown — because the assignment is idempotent and
//  cheap (one float store).
//
//  Keys:
//    "gravity" multiplier applied to player.gravity.  0..1 = low
//              gravity; >1 = heavier.  pmove reads .gravity each
//              tick (sh_pmove.qc:2138 → mv_entgravity).
//

void(entity volume, vector inflate) Trigger_FireOnOverlap;       // sv_triggers.qc

void() trigger_gravity_touch =
{
    if (other.classname != "player") return;
    other.gravity = self.gravity;
};

// Per-tick scan so stationary players in the volume keep getting
// the gravity assignment — engine touch only fires on motion.  The
// assignment is idempotent so duplicate fires from the engine touch
// + this scan don't cause issues.
void() trigger_gravity_scan =
{
    self.nextthink = time + 0.1;
    Trigger_FireOnOverlap(self, '1 1 1');
};

/*QUAKED trigger_gravity (.5 0 .5) ?
Brush volume that sets player gravity multiplier on touch.

"gravity"  multiplier (1.0 = normal, 0.5 = half, etc.)
*/
void() trigger_gravity =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    self.effects   |= EF_NODRAW;     // hide the placeholder texture
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_TRIGGER;
    self.touch      = trigger_gravity_touch;
    self.think      = trigger_gravity_scan;
    self.nextthink  = time + 0.1;
    if (!self.gravity)
        self.gravity = 1.0;          // mapper-omitted default = no change
};
