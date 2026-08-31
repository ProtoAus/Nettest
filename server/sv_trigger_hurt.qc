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
// Sven InventoryRules gate - defined in sv_item_inventory.qc (position 265), which
// compiles after this file; the KEY FIELDS it reads live in sv_customdefs.qc for
// exactly that reason.
float(entity rules, entity who) Inv_Gate;                            // sv_item_inventory.qc
float(entity rules) Inv_HasRules;                                    // sv_item_inventory.qc
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

// Sven's damage-type bitfield, straight out of Half-Life's cbase.h:608-634.
// 36 trigger_hurts across the target maps set it; on pizza_ya_san1 it is 23 gas
// traps, 3 burns and one freeze.
//
// ONLY THE ONES THAT MEAN SOMETHING HERE ARE NAMED.  The full table is 24 bits
// wide and most of it describes gameplay this mod does not model (paralysis,
// drown recovery, time-based ticks); listing constants nothing reads would just
// invite someone to assume they work.
const float HLDMG_CRUSH      = 1;
const float HLDMG_BULLET     = 2;
const float HLDMG_SLASH      = 4;
const float HLDMG_BURN       = 8;
const float HLDMG_FREEZE     = 16;
const float HLDMG_FALL       = 32;
const float HLDMG_BLAST      = 64;
const float HLDMG_CLUB       = 128;
const float HLDMG_SHOCK      = 256;
const float HLDMG_SONIC      = 512;
const float HLDMG_DROWN      = 16384;
const float HLDMG_NERVEGAS   = 65536;
const float HLDMG_POISON     = 131072;
const float HLDMG_RADIATION  = 262144;
const float HLDMG_ACID       = 1048576;
const float HLDMG_SLOWBURN   = 2097152;
const float HLDMG_SLOWFREEZE = 4194304;

.float damagetype;

// HL's numbering -> this mod's six-bit vocabulary, for sv_dmg_bits.
//
// THIS TRANSLATION IS NOT OPTIONAL AND THE COLLISIONS ARE THE REASON.  The two
// sets share names and disagree about values: HLDMG_BURN is 8 where ours is
// DMG_SONIC, and HLDMG_FREEZE is 16 where ours is DMG_CRUSH.  Both of ours are
// inside DMG_GIB_CORPSE, so assigning a map's damagetype straight across would
// gib every corpse lying in a gas trap - 23 of them on this map alone, all
// spelled 65536, which lands on nothing at all in our set and would read as
// "no bits, so bullet".
//
// Only the five that map onto something real are carried.  Everything else
// resolves to DMG_BULLET, which is what the whole path did before this existed.
float(float hl) TriggerHurt_GibBits =
{
	float bits = 0;
	if (hl & HLDMG_CRUSH)  bits = bits | DMG_CRUSH;
	if (hl & HLDMG_FALL)   bits = bits | DMG_FALL;
	if (hl & HLDMG_BLAST)  bits = bits | DMG_BLAST;
	if (hl & HLDMG_CLUB)   bits = bits | DMG_CLUB;
	if (hl & HLDMG_SLASH)  bits = bits | DMG_CLUB;   // no separate slash here
	if (hl & HLDMG_SONIC)  bits = bits | DMG_SONIC;
	if (hl & HLDMG_BULLET) bits = bits | DMG_BULLET;
	return bits;
};

// ...and the same key -> the HUD's reason byte.  Tested most-specific first,
// because a mapper is free to OR several together and the flash can only be one
// colour: the ambient hazards win over the mechanical ones, since those are the
// ones a player cannot otherwise identify.
float(float hl) TriggerHurt_HudType =
{
	if (hl & HLDMG_NERVEGAS)                        return DMGHUD_GAS;
	if (hl & HLDMG_POISON)                          return DMGHUD_POISON;
	if (hl & HLDMG_ACID)                            return DMGHUD_ACID;
	if (hl & HLDMG_RADIATION)                       return DMGHUD_RADIATION;
	if (hl & (HLDMG_BURN | HLDMG_SLOWBURN))         return DMGHUD_BURN;
	if (hl & (HLDMG_FREEZE | HLDMG_SLOWFREEZE))     return DMGHUD_FREEZE;
	if (hl & HLDMG_SHOCK)                           return DMGHUD_SHOCK;
	if (hl & HLDMG_DROWN)                           return DMGHUD_DROWN;
	return DMGHUD_NONE;
};

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

    // Sven's InventoryRules on a trigger_hurt reads the OTHER WAY ROUND from
    // every other class that honours it.  Its changelog entry is "Defend player
    // from damage", so PASSING the rules is what protects you: a carrier of the
    // required item takes nothing here and everyone else burns.
    //
    // Inv_HasRules is load-bearing, not an optimisation.  Inv_Gate returns TRUE
    // for an entity with no rules configured — correctly, since "all defined
    // rules must pass" is vacuously true when none are defined — and with the
    // inverted sense above that would mean every unconfigured trigger_hurt in
    // the corpus (which is all of them) protects everybody and does no damage
    // at all.  The gate only gets to speak when the mapper actually wrote a
    // rule.
    //
    // ABOVE the per-victim cooldown deliberately: a protected player who set
    // thurt_next_hit on the way through would suppress the next real hit from a
    // DIFFERENT trigger_hurt half a second later, because that cooldown is a
    // field on the victim rather than on the volume.
    //
    // Inv_Gate rather than a bare Inv_RulesPass because the pass_* side effects
    // are the point: a trigger_hurt with pass_destroy_item_name is Sven's idiom
    // for "the hazard suit burns out as it saves you".
    if (is_player)
        if (Inv_HasRules(self))
            if (Inv_Gate(self, other))
                return;

    // Per-victim 0.5s gate — same cadence the HL trigger_hurt
    // uses so a `dmg N` map key matches the documented behaviour
    // of ~N HP/sec sustained damage.
    if (time < other.thurt_next_hit) return;
    other.thurt_next_hit = time + 0.5;

    float dmg_amount = self.dmg * 0.5;
    if (dmg_amount > 0)
    {
        // Both globals are read-and-cleared by W_ApplyDamage, so they are set
        // immediately before the call and never left standing — the same
        // convention the 58 weapon call sites use for sv_dmg_bits.
        if (self.damagetype)
        {
            sv_dmg_bits    = TriggerHurt_GibBits(self.damagetype);
            sv_dmg_hudtype = TriggerHurt_HudType(self.damagetype);
        }
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

// ===========================================================================
//  trigger_hurt_remote  —  "Trigger Hurt (non-touch)", sven-coop.fgd:6462
// ===========================================================================
//  A POINT entity that damages something ELSE by name.  10 placements across 6
//  of the They Hunger / pizza maps, and the names say what they are for:
//  `blow_kelly_toshit`, `elev_instakill`, `sc_killspider`, `pauls_door_brk` —
//  scripted kills and scripted breakage, fired by a multi_manager rather than
//  by anyone walking into anything.
//
//  THE `target` KEY IS THE VICTIM, NOT A TRIGGER CHAIN.  That is the one thing
//  about this class that will trip a reader who knows the rest of the file: the
//  normal SUB_UseTargets walk must NOT run on it, or firing this entity would
//  ALSO use whatever it is trying to kill.  `!activator` (2 of the 10) means
//  whoever fired us.
//
//  Spawnflags (fgd:6464):
//    1  Instant Kill   ignore `dmg`, just kill it
//    2  Constant       keep hurting every `delay` seconds while switched on
//    4  Start On       Constant mode begins live rather than waiting
//    8  Do Armor       drain `armordmg` from armour before the health damage
//
//  The damagetype translation is the one already at the top of this file:
//  TriggerHurt_GibBits / TriggerHurt_HudType, and the collision it documents
//  (HLDMG_BURN 8 == our DMG_SONIC, HLDMG_FREEZE 16 == our DMG_CRUSH, both
//  inside DMG_GIB_CORPSE) applies here for exactly the same reason.
// ===========================================================================

const float THR_INSTANT_KILL = 1;
const float THR_CONSTANT     = 2;
const float THR_START_ON     = 4;
const float THR_DO_ARMOR     = 8;

.string targetclass;      // fgd:6471 — hurt every entity of this classname
.float  armordmg;         // fgd:6473
.float  thr_active;

void(entity trig, entity victim) TriggerHurtRemote_Hit =
{
    if (!victim || victim == world)
        return;

    // Do Armor: armour comes off first and does NOT pass through to health.
    // .armor is the CS Kevlar value (sv_customdefs.qc:546) and is the only
    // armour channel this mod has; SUIT_ARMOR_MAX is declared in
    // sv_goldsrc_pickups.qc, which compiles far below us, so the floor is
    // written out rather than named.
    if ((trig.spawnflags & THR_DO_ARMOR) && trig.armordmg > 0)
    {
        victim.armor = victim.armor - trig.armordmg;
        if (victim.armor < 0)
            victim.armor = 0;
    }

    float amount = trig.dmg;
    if (trig.spawnflags & THR_INSTANT_KILL)
    {
        // Enough to kill, not enough to gib.  Reading the `dmg` key here would
        // be wrong in both directions: `elev_instakill` sets 99999999999999,
        // which would tear the body apart, and one placement leaves dmg at the
        // default 10, which would not kill anything at all.
        amount = victim.health + 100;
    }
    if (amount <= 0)
        return;

    if (trig.damagetype)
    {
        sv_dmg_bits    = TriggerHurt_GibBits(trig.damagetype);
        sv_dmg_hudtype = TriggerHurt_HudType(trig.damagetype);
    }
    W_ApplyDamage(trig, victim, amount);
};

void() TriggerHurtRemote_Fire =
{
    // `!activator` — whoever fired us.  Sven's convention, and the reason
    // `blow_kelly_toshit` works on the player who set it off rather than on a
    // named entity the mapper would have had to invent.
    // Snapshot the successor BEFORE each hit: a fatal blow can remove the
    // victim, and find() resumes from an entity that no longer exists.  Same
    // reason trigger_respawn_use walks its chain with a saved `nxt`.
    entity nxt;

    if (self.target == "!activator")
    {
        TriggerHurtRemote_Hit(self, activator);
    }
    else if (self.target != "" && self.target)
    {
        entity e = find(world, targetname, self.target);
        while (e)
        {
            nxt = find(e, targetname, self.target);
            TriggerHurtRemote_Hit(self, e);
            e = nxt;
        }
    }

    if (self.targetclass != "" && self.targetclass)
    {
        entity c = find(world, classname, self.targetclass);
        while (c)
        {
            nxt = find(c, classname, self.targetclass);
            TriggerHurtRemote_Hit(self, c);
            c = nxt;
        }
    }
};

void() TriggerHurtRemote_Tick =
{
    if (!self.thr_active)
        return;
    TriggerHurtRemote_Fire();
    self.nextthink = time + (self.delay > 0 ? self.delay : 1);
};

void() trigger_hurt_remote_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;

    // One-shot mode: fire and be done.  Constant mode: the trigger is a
    // switch, so a use TOGGLES it — which is how `sc_mustdie_killer` is armed
    // and disarmed by its multi_manager.
    if (!(self.spawnflags & THR_CONSTANT))
    {
        TriggerHurtRemote_Fire();
        return;
    }

    self.thr_active = self.thr_active ? 0 : 1;
    if (self.thr_active)
    {
        self.think     = TriggerHurtRemote_Tick;
        self.nextthink = time;
    }
    else
    {
        self.think     = __NULL__;
        self.nextthink = 0;
    }
};

/*QUAKED trigger_hurt_remote (.5 0 .5) (-8 -8 -8) (8 8 8) INSTANT_KILL CONSTANT START_ON DO_ARMOR
Point entity that damages a NAMED entity rather than whatever touches it.

"target"       targetname of the victim, or "!activator"
"targetclass"  hurt every entity of this classname as well
"dmg"          damage per application (default 10)
"armordmg"     armour drained first, with DO_ARMOR
"delay"        seconds between applications, CONSTANT only (default 1)
"damagetype"   HL damage bitfield — see the table at the top of this file
*/
void() trigger_hurt_remote =
{
    self.solid    = SOLID_NOT;
    self.movetype = MOVETYPE_NONE;
    self.effects |= EF_NODRAW;

    if (!self.dmg)
        self.dmg = 10;          // fgd:6472

    self.use = trigger_hurt_remote_use;

    if ((self.spawnflags & THR_CONSTANT) && (self.spawnflags & THR_START_ON))
    {
        self.thr_active = 1;
        self.think      = TriggerHurtRemote_Tick;
        self.nextthink  = time + 0.5;
    }
};
