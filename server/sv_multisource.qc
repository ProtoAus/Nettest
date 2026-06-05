//
//  sv_multisource.qc  –  multisource (AND-gate)
//
//  Tracks the ON/OFF state of every entity that targets it; flips its
//  own ms_active to TRUE only when all known inputs are ON.  IsMaster-
//  Triggered reads ms_active so an entity with master="ms_name" stays
//  inert until the AND-gate is satisfied.
//
//  Inputs are learned dynamically — the multisource doesn't pre-walk
//  the world for triggers targeting it.  The first time a caller fires
//  multisource_use, a sub-entity ("ms_state_node") is allocated to
//  track that caller's state.  Subsequent fires from the same caller
//  toggle the same node.
//
//  Each ms_state_node holds:
//    .ms_input    — the entity it represents
//    .ms_state    — current ON/OFF (TRUE/FALSE)
//    .ms_next     — chain pointer, walked at evaluate time
//    .owner       — back-pointer to the parent multisource (cleanup)
//
//  Lifetime: nodes are never freed.  Map life is the bound.
//

// Externs from earlier compile units.
void(entity caller, entity who, float useType) SUB_UseTargets;        // sv_triggers.qc

// ms_active is forward-declared in sv_triggers.qc so IsMasterTriggered
// can read it before this file loads.  Re-declare for documentation.
.float  ms_active;

// Chain head (lives on the multisource), node pointer + per-node
// state (live on each ms_state_node).
.entity ms_first_node;
.entity ms_next;
.entity ms_input;
.float  ms_state;

// Find the node tracking `caller`, or spawn a new one.
entity(entity src, entity caller) ms_find_or_create_node =
{
    entity n = src.ms_first_node;
    while (n)
    {
        if (n.ms_input == caller)
            return n;
        n = n.ms_next;
    }
    n = spawn();
    n.classname = "ms_state_node";
    n.owner     = src;
    n.ms_input  = caller;
    n.ms_state  = 0;
    n.ms_next   = src.ms_first_node;
    src.ms_first_node = n;
    return n;
};

void() multisource_use =
{
    entity caller = sub_use_caller;
    if (!caller)
        caller = activator;
    if (!caller)
        return;     // can't track anonymous fires

    entity node = ms_find_or_create_node(self, caller);

    // Apply useType: OFF clears, ON sets, TOGGLE flips.  Anything
    // else (USE_SET) is treated as toggle for compatibility.
    if (sub_use_type == USE_OFF)
        node.ms_state = 0;
    else if (sub_use_type == USE_ON)
        node.ms_state = 1;
    else
        node.ms_state = !node.ms_state;

    // Walk chain: AND-gate.  Empty chain (degenerate) → all_on=1, but
    // we guard so a multisource never spuriously fires its target
    // before any input has reported.
    float all_on = 1;
    float any    = 0;
    entity n = self.ms_first_node;
    while (n)
    {
        any = 1;
        if (!n.ms_state) all_on = 0;
        n = n.ms_next;
    }
    if (!any) all_on = 0;

    if (all_on != self.ms_active)
    {
        self.ms_active = all_on;
        if (all_on)
            SUB_UseTargets(self, activator, USE_TOGGLE);
        else
            SUB_UseTargets(self, activator, USE_OFF);
    }
};

/*QUAKED multisource (.5 .5 .5) (-8 -8 -8) (8 8 8)
AND-gate of trigger inputs.  Fires its target when every input that
has reported in is currently ON.  Acts as a master for any entity
whose `master` key names this multisource.

"targetname"  name (so other entities can target / master this)
"target"      entity / chain to fire when AND-gate flips ON
"globalname"  accepted, ignored (env_global is OOS)
"globalstate" accepted, ignored
*/
void() multisource =
{
    self.use      = multisource_use;
    self.ms_active = 0;
};
