//
//  sv_multisource.qc  –  multisource (AND-gate)
//
//  Tracks the ON/OFF state of every entity that targets it; flips its
//  own ms_active to TRUE only when all known inputs are ON.  IsMaster-
//  Triggered reads ms_active so an entity with master="ms_name" stays
//  inert until the AND-gate is satisfied.
//
//  Inputs are PRE-REGISTERED at map load, mirroring HL's
//  CMultiSource::Register: a deferred think walks the world for every
//  entity whose `target` names this multisource and allocates one node
//  per hit, all starting OFF.  The gate opens only when ALL of them are
//  ON.
//
//  This used to be lazy — nodes were created on first fire, so the chain
//  held exactly one node after the first input reported and the AND-gate
//  immediately evaluated TRUE.  Every multi-input puzzle unlocked on its
//  first input.  Measured on the Sven corpus: -sp_campaign_portal has 40
//  two-input gates, and pizza_ya_san1 has five FOURTEEN-input gates
//  (ms_komugibako1..5 — break all 14 flour sacks).
//
//  Registration must be deferred: entities spawn one at a time during map
//  load, so a multisource emitted before its inputs would see none of
//  them.  Same reason func_vehiclecontrols and squadmaker defer.
//
//  ZERO-INPUT GATES ARE PERMISSIVE, and that is deliberate HL parity, not
//  an oversight.  HL's Register only scans `pev->target`, so a gate driven
//  by a multi_manager (whose targets live in arbitrary keyvalues, not in
//  .target) registers nothing.  HL's IsTriggered then walks `i < m_iTotal`
//  with m_iTotal == 0, falls straight out with i == m_iTotal, and returns
//  TRUE — so such a gate reads as permanently satisfied and its Use fires
//  the target chain immediately.  pizza_ya_san1's `ms_norainu` is exactly
//  this: two multi_managers (mm_meatshopend / mm_vegeshopend) drive it and
//  nothing targets it by name.  Requiring both would soft-lock the map
//  against how it was authored and tested.  Registering multi_manager
//  slots would be "more correct" and less compatible; we match HL.
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

.float  ms_input_count;   // registered inputs; 0 => permissive (see header)
.float  ms_permissive;    // HL parity for the no-registerable-inputs case
.float  ms_registered;    // registration pass has run

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
    src.ms_input_count = src.ms_input_count + 1;
    return n;
};

// Find the node tracking `caller`, or world if it isn't a registered input.
entity(entity src, entity caller) ms_find_node =
{
    entity n = src.ms_first_node;
    while (n)
    {
        if (n.ms_input == caller)
            return n;
        n = n.ms_next;
    }
    return world;
};

// ---------------------------------------------------------------------------
// ms_register — HL's CMultiSource::Register.  Deferred one frame's worth so
// every map entity exists by the time we walk.
// ---------------------------------------------------------------------------
void() ms_register =
{
    self.ms_registered = 1;

    if (self.targetname != "" && self.targetname != __NULL__)
    {
        entity e = find(world, target, self.targetname);
        while (e)
        {
            // Don't register ourselves, and skip entities that can't fire
            // (no .use means they will never report in, so counting them
            // would lock the gate forever).
            //
            // gs_unimplemented belongs in exactly that category and is NOT
            // covered by the .use test: SV_OnEntityNoSpawnFunction deliberately
            // gives unknown classes a relay .use so chains routed through them
            // still reach the far side, which makes one look like a working
            // input here.  Nothing will ever fire it, though — whatever would
            // have is the behaviour we did not implement.  Measured across the
            // Sven corpus this is item_security and nothing else: 28 of the 877
            // real multisource inputs, against trigger_relay 630, trigger_once
            // 114, func_breakable 46, func_button 34, all of which work.
            // Skipping rather than blanket-permissive keeps the gate honest for
            // the inputs that DO work instead of throwing the whole gate away.
            if (e != self && e.use && !e.gs_unimplemented)
                ms_find_or_create_node(self, e);
            e = find(e, target, self.targetname);
        }
    }

    if (!self.ms_input_count)
    {
        // See the header: HL treats this as permanently satisfied.
        self.ms_permissive = 1;
        self.ms_active     = 1;
        if (cvar("sv_debug_use"))
            print(sprintf("[multisource] \"%s\" has no registerable inputs "
                          "-> permissive (HL parity)\n", self.targetname));
        return;
    }

    if (cvar("sv_debug_use"))
        print(sprintf("[multisource] \"%s\" registered %g input(s)\n",
                      self.targetname, self.ms_input_count));
};

void() multisource_use =
{
    entity caller = sub_use_caller;
    if (!caller)
        caller = activator;
    if (!caller)
        return;     // can't track anonymous fires

    // A gate that never registered any input behaves as HL's does: it is
    // already satisfied, and any fire pushes the chain onward.
    if (self.ms_permissive)
    {
        self.ms_active = 1;
        SUB_UseTargets(self, activator, USE_TOGGLE);
        return;
    }

    entity node;
    if (cvar("sv_multisource_strict") && self.ms_registered)
    {
        // Strict: only pre-registered inputs count.  HL prints
        // "MultiSrc:Used by non member" and returns; do the same rather
        // than inventing a node, which is what made the gate open early.
        node = ms_find_node(self, caller);
        if (!node)
        {
            if (cvar("sv_debug_use"))
                print(sprintf("[multisource] \"%s\" used by non-member %s(\"%s\")"
                              " — ignored\n", self.targetname,
                              caller.classname, caller.targetname));
            return;
        }
    }
    else
    {
        // Legacy lazy behaviour, kept behind the cvar as a rollback path.
        node = ms_find_or_create_node(self, caller);
    }

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
        if (cvar("sv_debug_use"))
            print(sprintf("[multisource] \"%s\" -> %s\n", self.targetname,
                          all_on ? "OPEN" : "CLOSED"));
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
    self.use       = multisource_use;
    self.ms_active = 0;

    // Deferred input registration — see the file header.  0.2s matches the
    // other deferred linkers in this codebase (func_vehiclecontrols_link,
    // trigger_teleport_resolve) and is comfortably after entity spawn.
    self.think     = ms_register;
    self.nextthink = time + 0.2;
};
