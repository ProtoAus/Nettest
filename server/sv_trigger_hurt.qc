//
//  sv_trigger_hurt.qc  –  trigger_hurt
//
//  Volume that damages anything touching it.  Mappers bound it
//  with a brush; touch events are filtered against the spawnflags
//  and a per-victim 0.5s cooldown (so a static dmg=N value reads
//  as ~N HP/s of sustained damage).  Negative dmg heals.
//
//  Spawnflags:
//    1   TARGET_ONCE       fire `target` once on the first damaging
//                          contact, then stop firing the chain.
//    2   START_OFF         spawn inactive — needs a trigger to
//                          flip the .use latch before it damages.
//    8   NO_CLIENTS        don't damage players.
//    32  CLIENT_ONLY       only damage players (filter out monsters
//                          / phys-props / etc.).
//  Keys:
//    "dmg" damage per second (0.5x applied per 0.5s tick).  Negative
//          adds health up to .max_health (or 100 if unset).
//

// Externs from earlier compile units.
void(entity caller, entity triggerer) Trigger_UseTargets;       // sv_doors.qc
float(entity attacker, entity target, float damage) W_ApplyDamage;  // sv_weapons.qc
void(entity volume, vector inflate) Trigger_FireOnOverlap;          // sv_triggers.qc
float(entity player, entity trig) Trigger_PlayerInBSPBrush;         // sv_triggers.qc

// Shared field — already declared in sv_doors.qc; redeclaration is
// harmless and shares storage (same pattern sv_breakable.qc uses).
.float dmg;

const float TRIGGER_HURT_TARGET_ONCE = 1;
const float TRIGGER_HURT_START_OFF   = 2;
const float TRIGGER_HURT_NO_CLIENTS  = 8;
const float TRIGGER_HURT_CLIENT_ONLY = 32;

// Per-victim cooldown stamp — game-time of the next hit eligible.
// Sven's damage-type bitfield (0 GENERIC, 1 CRUSH, 2 BULLET, ... 4194304
// SLOWFREEZE).  DECLARED ONLY: W_ApplyDamage has no damage-type channel, so
// nothing can act on it yet.  36 trigger_hurts across the target maps set it;
// declaring the field just stops the key being silently dropped, and makes it
// visible in an entity dump for whoever wires up damage types later.
.float damagetype;

.float thurt_next_hit;

// Per-trigger active flag (cleared while START_OFF, toggled by .use)
// and the latch that mutes the target chain after TARGET_ONCE has
// already fired its first round.
.float thurt_active;
.float thurt_target_once_done;

void() trigger_hurt_touch =
{
    if (!self.thurt_active) return;

    float is_player = (other.classname == "player");
    if ((self.spawnflags & TRIGGER_HURT_NO_CLIENTS) && is_player)  return;
    if ((self.spawnflags & TRIGGER_HURT_CLIENT_ONLY) && !is_player) return;

    // No takedamage gate here — this mod doesn't set .takedamage on
    // players (they default to DAMAGE_NO=0), so checking it was
    // blocking every positive-dmg hit while still letting heals
    // (negative dmg) through the second branch.  W_ApplyDamage's
    // W_CanDamageTarget handles damageability via classname.

    // BSP refinement — engine-fired SOLID_TRIGGER touch is AABB-only,
    // so an angled or non-rectangular trigger brush over-triggers
    // for players inside the AABB but outside the actual brush
    // volume.  A zero-length tracebox at the player's hull against
    // the brush's BSP geometry filters those false positives out.
    if (is_player && !Trigger_PlayerInBSPBrush(other, self))
        return;

    // Per-victim 0.5s gate — same cadence the HL trigger_hurt
    // uses so a `dmg N` map key matches the documented behaviour
    // of ~N HP/sec sustained damage.
    if (time < other.thurt_next_hit) return;
    other.thurt_next_hit = time + 0.5;

    float dmg_amount = self.dmg * 0.5;
    if (dmg_amount > 0)
    {
        W_ApplyDamage(self, other, dmg_amount);
    }
    else if (dmg_amount < 0)
    {
        // Heal — bounded by max_health (or 100 as a Q1-default
        // fallback for entities that don't track one).
        float cap = other.max_health ? other.max_health : 100;
        other.health = other.health - dmg_amount;
        if (other.health > cap) other.health = cap;
    }

    if (!self.thurt_target_once_done)
    {
        // Targetx keys (killtarget / delay) are dropped by the two-arg
        // walker.  No map in the current corpus sets either on a
        // trigger_hurt, but HL fires this chain through SUB_UseTargets.
        SUB_UseTargets(self, other, USE_TOGGLE);
        if (self.spawnflags & TRIGGER_HURT_TARGET_ONCE)
            self.thurt_target_once_done = 1;
    }
};

void() trigger_hurt_scan =
{
    self.nextthink = time + 0.1;
    Trigger_FireOnOverlap(self, '1 1 1');
};

void() trigger_hurt_use =
{
    // Toggle.  If a mapper wants edge-only on/off they can layer
    // a trigger_relay or custom entity on top; a bare toggle
    // covers the START_OFF case the spawnflag implies.
    self.thurt_active = self.thurt_active ? 0 : 1;
};

/*QUAKED trigger_hurt (.5 0 .5) ? TARGET_ONCE START_OFF x NO_CLIENTS x x CLIENT_ONLY
Brush volume that damages whatever touches it.

"dmg"        damage per second (negative = heal up to max_health)
"target"     entities to fire on each damaging touch
"targetname" if set, .use toggles active state
*/
void() trigger_hurt =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    // Hide the brush from the renderer while keeping its bbox linked
    // for SOLID_TRIGGER overlap.  Zeroing modelindex would also work
    // visually but the engine derives the trigger volume from the
    // model bounds — wiping it kills touch detection.  EF_NODRAW skips
    // only the render pass; the entity's mins/maxs and absmin/absmax
    // remain valid so PlayerTouch fires on bbox overlap as expected.
    self.effects   |= EF_NODRAW;
    self.movetype   = MOVETYPE_NONE;
    self.solid      = SOLID_TRIGGER;
    self.touch      = trigger_hurt_touch;
    self.use        = trigger_hurt_use;
    self.thurt_active = (self.spawnflags & TRIGGER_HURT_START_OFF) ? 0 : 1;
    // HL default — a mapper who omits "dmg" expects a working trigger,
    // not a no-op.  Negative values (heal) are explicit so they survive.
    if (!self.dmg)
        self.dmg = 10;
    // Per-tick scan so stationary players inside the volume still get
    // hit — the engine's touch only fires on entry/motion.  The
    // .thurt_next_hit cooldown gates duplicate firing.
    self.think     = trigger_hurt_scan;
    self.nextthink = time + 0.1;
};
