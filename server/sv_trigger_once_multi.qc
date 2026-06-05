//
//  sv_trigger_once_multi.qc  –  trigger_once + trigger_multiple
//
//  Touch-driven brush volumes that fire their `target` chain when
//  entered.  trigger_multiple respects a `wait` cooldown; trigger_once
//  is the same with wait=-1 (single-fire then remove).
//
//  Both honour `master`, `killtarget`, and `delay` via SUB_UseTargets.
//

// Externs from earlier compile units.
void(entity caller, entity who, float useType) SUB_UseTargets;        // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;              // sv_triggers.qc
void() SUB_Remove;                                                    // sv_triggers.qc
void(entity volume, vector inflate) Trigger_FireOnOverlap;            // sv_triggers.qc

// Spawnflags.  Match HL bit layout exactly so .bsp entdata decodes.
const float SF_TRIG_ALLOWMONSTERS = 1;
const float SF_TRIG_NOCLIENTS     = 2;
const float SF_TRIG_PUSHABLES     = 4;

// Shared touch handler — class filter, master gate, wait cooldown,
// then SUB_UseTargets.  trigger_once's wait=-1 triggers single-fire
// remove via the bottom branch.
void() trigger_multi_touch =
{
    float is_player = (other.classname == "player");
    if (is_player && (self.spawnflags & SF_TRIG_NOCLIENTS))
        return;
    // Non-player paths are mostly inert in this mod (no monsters, no
    // pushables) — the spawnflag check is forward-compat scaffolding.
    if (!is_player && !(self.spawnflags & SF_TRIG_ALLOWMONSTERS))
        return;

    if (time < self.attack_finished)
        return;

    if (!IsMasterTriggered(self.master, other))
        return;

    // Cooldown — only set when wait >= 0; for trigger_once we'd
    // otherwise leave attack_finished pinned at +infinity, but the
    // remove branch below makes that irrelevant.
    if (self.wait >= 0)
        self.attack_finished = time + self.wait;

    SUB_UseTargets(self, other, USE_TOGGLE);

    if (self.wait < 0)
    {
        // Single-fire trigger_once: detach touch + queue remove.
        self.touch     = __NULL__;
        self.think     = SUB_Remove;
        self.nextthink = time + 0.1;
    }
};

// Per-tick scan think — catches stationary players inside small
// floor triggers that the engine's motion-driven touch misses.
// 1 qu inflation so a player whose feet are exactly at the trigger's
// top boundary still register.
void() trigger_multi_scan =
{
    self.nextthink = time + 0.1;
    Trigger_FireOnOverlap(self, '1 1 1');
};

// Shared init — bbox via setmodel, EF_NODRAW so the trigger texture
// doesn't render, SOLID_TRIGGER so the engine fires .touch on overlap.
void() trigger_multiple_init =
{
    if (!self.model)
    {
        remove(self);
        return;
    }
    setmodel(self, self.model);
    self.effects |= EF_NODRAW;     // hide placeholder texture
    self.movetype = MOVETYPE_NONE;
    self.solid    = SOLID_TRIGGER;
    self.touch    = trigger_multi_touch;
    self.think     = trigger_multi_scan;
    self.nextthink = time + 0.2;
};

/*QUAKED trigger_multiple (.5 .5 .5) ? ALLOWMONSTERS NOCLIENTS PUSHABLES
Brush volume that fires its target every `wait` seconds while
entered.  See trigger_once for single-fire variant.

"target"     entity / chain to fire
"targetname" name (for being triggered externally)
"master"     name of multisource / game_team_master gate
"killtarget" entity to remove on each fire
"delay"      seconds to defer the fire after touch
"wait"       per-victim cooldown (default 0.2)
"message"    optional display string (not implemented)
*/
void() trigger_multiple =
{
    if (!self.wait)
        self.wait = 0.2;
    trigger_multiple_init();
};

/*QUAKED trigger_once (.5 .5 .5) ? ALLOWMONSTERS NOCLIENTS PUSHABLES
Single-fire trigger_multiple — fires once then removes itself.
*/
void() trigger_once =
{
    self.wait = -1;
    trigger_multiple_init();
};
