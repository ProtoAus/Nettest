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
// Sven Co-op InventoryRules.  Defined in sv_item_inventory.qc (position 265),
// which compiles AFTER this file — legal because QC forward-declares functions.
// The FIELDS it reads could not be declared there for the same reason, so they
// live in sv_customdefs.qc; see the block there.
float(entity rules, entity who) Inv_Gate;                             // sv_item_inventory.qc

// Spawnflags.  Match HL bit layout exactly so .bsp entdata decodes.
const float SF_TRIG_ALLOWMONSTERS = 1;
const float SF_TRIG_NOCLIENTS     = 2;
const float SF_TRIG_PUSHABLES     = 4;
// Sven additions to Half-Life's three (sven-coop.fgd, @BaseClass = Trigger).
// HL's CBaseTrigger::TriggerTouch knows only the first three, which is why the
// mod only ever implemented those.
const float SF_TRIG_EVERYTHING    = 8;    // things that are neither player, monster nor pushable
const float SF_TRIG_FIRE_ON_ENTER = 16;   // accepted; already this file's behaviour
const float SF_TRIG_FIRE_ON_EXIT  = 32;   // NOT implemented — needs per-toucher edge tracking

// Shared touch handler — class filter, master gate, wait cooldown,
// then SUB_UseTargets.  trigger_once's wait=-1 triggers single-fire
// remove via the bottom branch.
void() trigger_multi_touch =
{
    float is_player   = (other.classname == "player");
    float is_pushable = (other.classname == "func_pushable");

    if (is_player && (self.spawnflags & SF_TRIG_NOCLIENTS))
        return;

    // PUSHABLES.  Half-Life's own third arm of the filter
    //
    //     (pev->spawnflags & SF_TRIGGER_PUSHABLES) && FClassnameIs(pevToucher,
    //                                                              "func_pushable")
    //                                                       (triggers.cpp, MultiTouch)
    //
    // and it was the missing half of desertcircle's capture: the map lifts a
    // crate into a trigger_once whose ONLY spawnflag is this bit, so even once
    // the crate could ride the flag up (sv_platform_carry.qc) the trigger would
    // still have thrown it away for not being a player.
    if (is_pushable)
    {
        if (!(self.spawnflags & SF_TRIG_PUSHABLES))
            return;
    }
    else if (!is_player)
    {
        // EVERYTHING ELSE (bit 8) is Sven's fourth category, and until now the
        // mod collapsed it into ALLOWMONSTERS — which meant a trigger asking
        // for bit 8 and nothing else accepted nobody at all.
        //
        // th_escape is where that shows: both `veh*_dropoffs` trigger_multiple
        // carry spawnflags 26 (2|8|16), i.e. "no clients, everything else, fire
        // on enter".  That is the map's SECOND delivery route — drop the car
        // battery into the truck bed instead of walking it in — and with only
        // bits 1/2/4 known, bit 2 rejected the player and the absent bit 1
        // rejected the item, so the volume could never fire for anything.
        //
        // ADDITIVE on purpose: an entity that is neither player, monster nor
        // pushable is accepted by EITHER bit.  Splitting them strictly would be
        // closer to Sven, but it would also silently STOP accepting things that
        // 121 maps' worth of ALLOWMONSTERS triggers accept today, and there is
        // no map on disk that wants that.  Monsters keep their own bit either
        // way.
        float sf = self.spawnflags;
        if (other.flags & FL_MONSTER)
        {
            if (!(sf & SF_TRIG_ALLOWMONSTERS))
                return;
        }
        else if (!(sf & (SF_TRIG_ALLOWMONSTERS | SF_TRIG_EVERYTHING)))
            return;
    }

    if (time < self.attack_finished)
        return;

    if (!IsMasterTriggered(self.master, other))
        return;

    // Sven Co-op's InventoryRules — "Whenever player is attempting to use an
    // entity, the inventory test runs.  If test result is negative, the entity
    // won't work."  trigger_once and trigger_multiple are both on Sven's list
    // of classes that honour it.
    //
    // THIS GATE IS BEFORE THE COOLDOWN AND BEFORE THE SINGLE-FIRE REMOVE, and
    // both of those orderings are load-bearing.  A trigger_once that failed the
    // test must still be there for the player who comes back holding the right
    // item; retiring it on a failed touch would consume it for the whole map.
    // th_escape has 15 of these — the drop-off pads at the truck and the sewer
    // relays — and every one of them is a trigger_once that people will walk
    // over empty-handed long before they walk over it carrying anything.
    //
    // Inv_Gate also performs the pass_* side effects, which is how the item
    // leaves the player's hands: the drop-off pads carry
    // pass_destroy_item_name alongside item_name_required.
    if (!Inv_Gate(self, other))
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

    // EVERYTHING ELSE, for the same structural reason the pushable sweep below
    // exists, plus one more that is specific to items.
    //
    // A dropped item_inventory is SOLID_TRIGGER (Sven's `solid` key defaults to
    // "touch on edge, non-blocking"), and so is this volume — and the engine
    // never generates a touch pair between two SOLID_TRIGGERs.  So no amount of
    // getting the spawnflag filter right would make the engine deliver the
    // contact; the volume has to go and look.
    //
    // Only triggers that asked for bit 8 pay for this, and the same
    // attack_finished / wait<0 machinery deduplicates it against anything the
    // engine does deliver.
    if (self.spawnflags & SF_TRIG_EVERYTHING)
    {
        entity ivol = self;
        entity ioth = other;
        entity ie   = find(world, classname, "item_inventory");
        while (ie)
        {
            entity inxt = find(ie, classname, "item_inventory");
            if (ie.solid != SOLID_NOT
             && ie.absmin_x <= ivol.absmax_x && ie.absmax_x >= ivol.absmin_x
             && ie.absmin_y <= ivol.absmax_y && ie.absmax_y >= ivol.absmin_y
             && ie.absmin_z <= ivol.absmax_z && ie.absmax_z >= ivol.absmin_z)
            {
                self  = ivol;
                other = ie;
                ivol.touch();
                // Same retirement guard the pushable sweep documents: a
                // trigger_once clears its own .touch and queues SUB_Remove, and
                // calling a null function is a runtime error rather than a
                // no-op.
                if (wasfreed(ivol) || ivol.think == SUB_Remove)
                {
                    self  = ivol;
                    other = ioth;
                    return;
                }
            }
            ie = inxt;
        }
        self  = ivol;
        other = ioth;
    }

    if (!(self.spawnflags & SF_TRIG_PUSHABLES))
        return;

    // Same scan for crates, and for a stronger reason than the player one.  A
    // rider carried by a moving brush is repositioned with setorigin, and
    // setorigin relinks WITHOUT running the trigger pass (PF_setorigin ->
    // SV_LinkEdict(ent, false)) - so a crate can be lifted clean through a
    // trigger volume without the engine ever calling .touch.  Only triggers that
    // asked for pushables pay for this, and .attack_finished / the wait<0 remove
    // dedup it against a real engine touch.
    entity vol      = self;
    entity oldother = other;
    entity e        = find(world, classname, "func_pushable");
    while (e)
    {
        entity nxt = find(e, classname, "func_pushable");
        if (!e.breakable_broken
         && e.absmin_x <= vol.absmax_x && e.absmax_x >= vol.absmin_x
         && e.absmin_y <= vol.absmax_y && e.absmax_y >= vol.absmin_y
         && e.absmin_z <= vol.absmax_z && e.absmax_z >= vol.absmin_z)
        {
            self  = vol;
            other = e;
            vol.touch();
            // A trigger_once clears its own .touch and queues SUB_Remove; the
            // next iteration would then CALL a null function, which is a runtime
            // error, not a no-op.  Stop as soon as the volume has retired.
            if (wasfreed(vol) || vol.think == SUB_Remove)
                break;
        }
        e = nxt;
    }
    self  = vol;
    other = oldother;
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
