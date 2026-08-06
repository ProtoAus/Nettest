//
//  sv_trigger_logic.qc  –  trigger_relay + trigger_auto + trigger_counter
//
//  Three logic-only entities.  None respond to touch — they fire from
//  .use chains (relay, counter) or once at map load (auto).  All
//  honour master / killtarget / delay via SUB_UseTargets.
//

// Externs from earlier compile units.
void(entity caller, entity who, float useType) SUB_UseTargets;        // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;              // sv_triggers.qc
float(float ts) GoldSrc_TriggerStateToUseType;                        // sv_triggers.qc

// ============================================================================
//  trigger_relay
//
//  Sends a fixed triggerstate (USE_OFF / USE_ON / USE_TOGGLE) to its
//  target.  Useful for mappers who want a button to forcibly turn
//  something OFF rather than toggle it.  Most target entities ignore
//  the useType and toggle anyway, but the relay still passes it along.
// ============================================================================

const float SF_RELAY_FIREONCE = 1;

void() trigger_relay_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;
    float us = GoldSrc_TriggerStateToUseType(self.triggerstate);
    SUB_UseTargets(self, activator, us);
    if (self.spawnflags & SF_RELAY_FIREONCE)
        remove(self);
};

/*QUAKED trigger_relay (.5 .5 .5) (-8 -8 -8) (8 8 8) FIREONCE
Routes a trigger event with a fixed triggerstate.

"target"        entity / chain to fire
"targetname"    name
"triggerstate"  0=off, 1=on, 2=toggle (default toggle)
"delay"         seconds to defer
"killtarget"    entity to remove on fire
"master"        gate
*/
void() trigger_relay =
{
    self.use = trigger_relay_use;
};

// ============================================================================
//  trigger_auto
//
//  Fires once at map load (after `delay` seconds, default 0.2).  Used
//  to kick off scripted intros.  globalstate is accepted-but-ignored
//  pending env_global support.
// ============================================================================

const float SF_AUTO_FIREONCE = 1;

// Flipped TRUE on the first PlayerSpawn (sv_player.qc).  Gates
// trigger_auto / func_tracktrain auto-start when sv_waitforplayer is
// non-zero so intro sequences don't play to an empty server.
var float sv_first_player_spawned;

void() trigger_auto_think =
{
    // sv_waitforplayer: defer the fire-once dispatch until a live
    // player exists.  Without this, listen servers without an active
    // client (or dedicated servers right at map start) burn through
    // every trigger_auto / multi_manager chain before a player is
    // there to see it — the intro train rolls away into the empty
    // map, env_messages tick off in the void.  Reschedule the think
    // at a short interval and resume when sv_first_player_spawned
    // flips TRUE; the cvar is dynamic so admins can toggle live.
    if (cvar("sv_waitforplayer") && !sv_first_player_spawned)
    {
        self.nextthink = time + 0.1;
        return;
    }

    float us = GoldSrc_TriggerStateToUseType(self.triggerstate);
    // `delay` on a trigger_auto is its MAP-START wait, and it has just
    // elapsed — it is not also a chain delay.  SUB_UseTargets defers by
    // caller.delay, so leaving it set fires the target at 2x the authored
    // time (pizza_ya_san1's delay-10 auto fired at t=20).  Zero it across
    // the call rather than in the spawn function, so the key stays readable
    // for entity dumps and trigger_copyvalue.
    float saved_delay = self.delay;
    self.delay = 0;
    SUB_UseTargets(self, world, us);
    self.delay = saved_delay;
    // Mirror HL: trigger_auto without FIREONCE still only fires once
    // (the think isn't re-scheduled), so the flag controls whether
    // the entity persists in the slot table or is freed.
    if (self.spawnflags & SF_AUTO_FIREONCE)
        remove(self);
};

/*QUAKED trigger_auto (.5 .5 .5) (-8 -8 -8) (8 8 8) FIREONCE
Fires its target automatically when the map loads.

"target"        entity / chain to fire
"triggerstate"  0=off, 1=on, 2=toggle (default toggle)
"delay"         seconds to wait after map load (default 0.2)
"killtarget"    entity to remove on fire
*/
void() trigger_auto =
{
    self.think     = trigger_auto_think;
    self.nextthink = time + (self.delay > 0 ? self.delay : 0.2);
};

// ============================================================================
//  trigger_counter
//
//  Brush-shaped (so the FGD can place it in the world) but only
//  .use-driven — touches do NOT increment the counter.  Decrements
//  self.count per .use; on reaching 0, fires target chain and
//  removes itself.  Counter never resets (matches HL).
// ============================================================================

void() trigger_counter_use =
{
    if (!IsMasterTriggered(self.master, activator))
        return;
    self.count = self.count - 1;
    if (self.count > 0)
        return;
    SUB_UseTargets(self, activator, USE_TOGGLE);
    remove(self);
};

/*QUAKED trigger_counter (.5 .5 .5) ?
Brush-shaped counter — fires target after being .use'd `count` times,
then removes itself.  Note: only triggers count, NOT touches.

"target"     entity / chain to fire on final activation
"targetname" name
"master"     gate
"killtarget" entity to remove on final fire
"delay"      seconds to defer the final fire
"count"      number of activations needed (default 2)
*/
void() trigger_counter =
{
    if (!self.count)
        self.count = 2;
    self.solid = SOLID_NOT;       // not a touch volume; pure logic
    self.use   = trigger_counter_use;
};
