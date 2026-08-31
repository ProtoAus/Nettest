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
//  MULTI_MANAGER SLOTS ARE INPUTS TOO, and the comment that used to sit
//  here said the opposite.  It claimed "HL's Register only scans
//  pev->target, so a gate driven by a multi_manager registers nothing",
//  and concluded that registering multi_manager slots would be "more
//  correct and less compatible".  That is simply not what the SDK does.
//  CMultiSource::Register (dlls/buttons.cpp:239-272) runs TWO passes:
//
//      pentTarget = FIND_ENTITY_BY_STRING(NULL, "target", targetname);
//      ... while (...) m_rgEntities[m_iTotal++] = pTarget;
//
//      pentTarget = FIND_ENTITY_BY_STRING(NULL, "classname", "multi_manager");
//      while (...) if (pTarget->HasTarget(pev->targetname))
//                      m_rgEntities[m_iTotal++] = pTarget;
//
//  The second pass is the whole reason a manager-driven lock works in
//  Half-Life, and skipping it is what made 440 corpus gates permissive.
//
//  hl_c01_a1's airlock is the reported case.  A trigger_multiple with
//  `master lk1lock1` opens the four `lk1` doors; `lk1lock1` is a
//  multisource whose ONLY input is the multi_manager airlockdoorbuzzmm1,
//  which barney fires at the end of his retina-scan chain.  With the
//  second pass missing, lk1lock1 registered nothing, fell through to the
//  permissive branch below, and the airlock was +use-able from map load —
//  before the guard had checked anyone's suit or touched the scanner.
//
//  Measured over the corpus (svencoop + svencoop_downloads + valve +
//  gearbox + bshift): 1363 gates, 565 with no `target` input at all, and
//  440 of those 565 are driven by a multi_manager and are now correctly
//  gated.  6 more gates gain extra inputs alongside their existing ones.
//  Two of the 440 are driven by a MULTITHREADED manager, which fires
//  through a clone — see MM_ResolveCaller, without which those two would
//  soft-lock.
//
//  ZERO-INPUT GATES ARE STILL PERMISSIVE, and that part was always right:
//  HL's IsTriggered walks `i < m_iTotal` with m_iTotal == 0, falls
//  straight out with i == m_iTotal, and returns TRUE.  It just applies to
//  far fewer gates now (125, not 565).
//
//  sv_multisource_no_mm_inputs 1 restores the old permissive behaviour.
//  It exists because this is a 440-gate behaviour change that no amount
//  of headless testing can play through, and one cvar is a cheaper
//  rollback than a revert.
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

// ...and from a LATER one.  sv_multi_manager.qc is at sv_progs.src:172 and this
// file is at :166, so both of these are forward declarations rather than the
// ordinary case.  Only ms_register (a deferred think) and multisource_use call
// them, and both run long after every compile unit is loaded.
float(entity mm, string nm) MM_HasTarget;
entity(entity e) MM_ResolveCaller;

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
            // (nothing will ever report in for them, so counting them would
            // lock the gate forever).
            //
            // "Can fire" is .use OR .touch.  It used to be .use alone, and
            // that was wrong in the most common case there is: a brush
            // trigger.  trigger_multiple_init installs a .touch and a .think
            // and no .use — it reports in from trigger_multi_touch, through
            // SUB_UseTargets, exactly like a trigger_relay does.  Under the
            // .use-only test every such input was skipped, the gate fell
            // through to the no-inputs branch below, and PERMISSIVE is the
            // worst possible default there: the gate is open from map load,
            // which is the opposite of what a locked gate is for.
            //
            // hl_c01_a1 is the map that surfaced it.  `suit_ms` has one input
            // (a trigger_once in the HEV bay) and masters the
            // game_player_equip that grants item_suit, so the suit was handed
            // out on the first spawn — 50 armour, and Barney's
            // trigger_suitcheck passing before the player had been anywhere
            // near the locker.  Two more gates on that map (`ms1`,
            // `lk1lock1`) were stuck open the same way.  HL's
            // CMultiSource::Register (dlls/triggers.cpp) tests nothing at all
            // and registers every entity whose `target` matches, so this is a
            // step back TOWARD parity, not away from it.
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
            if (e != self && (e.use || e.touch) && !e.gs_unimplemented)
                ms_find_or_create_node(self, e);
            e = find(e, target, self.targetname);
        }

        // PASS 2 — every multi_manager that names us in a slot.  HL's
        // second Register loop, verbatim in intent: it walks by CLASSNAME
        // because a manager's targets are not in .target and so cannot be
        // found by the walk above.  See the file header for the corpus
        // numbers and for what this fixes on hl_c01_a1.
        //
        // Clones are excluded for free: MM_SpawnClone names them
        // "multi_manager_clone", so this find never returns one.  That is
        // the right outcome anyway — a clone is created per-fire and
        // removed when its schedule ends, so it could never be a stable
        // input.  MM_ResolveCaller maps a clone's fire back onto its
        // source, which IS the entity registered here.
        if (!cvar("sv_multisource_no_mm_inputs"))
        {
            entity mm = find(world, classname, "multi_manager");
            while (mm)
            {
                if (mm != self && MM_HasTarget(mm, self.targetname))
                    ms_find_or_create_node(self, mm);
                mm = find(mm, classname, "multi_manager");
            }
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

    // A MULTITHREADED multi_manager fires through a throwaway clone, which is
    // not the entity ms_register pre-registered.  Resolve it back, or the
    // clone would take a second node of its own and the gate could never
    // reach all-on.  No-op for every other caller.
    caller = MM_ResolveCaller(caller);

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

    // buttons.cpp:216-236 — CMultiSource::IsTriggered is TWO tests ANDed: every
    // input on, AND the named global ON.
    //
    // ms_active stays PURE INPUT STATE and the global is ANDed in at each read
    // (here and in IsMasterTriggered).  That is not tidiness: HL re-evaluates
    // IsTriggered() on every UTIL_IsMasterTriggered call, so a gate whose inputs
    // are already satisfied opens the instant an env_global elsewhere — or on an
    // earlier map — flips the state ON.  Folding the global into the cached flag
    // would freeze such a gate shut until an input happened to fire again, and
    // for a cross-map global no input ever would.
    float gate_ok = GlobalState_GateOpen(self.globalstate);

    if (all_on != self.ms_active)
    {
        self.ms_active = all_on;
        if (cvar("sv_debug_use"))
            print(sprintf("[multisource] \"%s\" -> %s%s\n", self.targetname,
                          all_on ? "OPEN" : "CLOSED",
                          (all_on && !gate_ok) ? " (held by globalstate)" : ""));
        if (all_on && gate_ok)
        {
            // buttons.cpp:207-210 — a multisource WITH a globalstate hands its
            // chain USE_ON rather than USE_TOGGLE.  These gates unlock things
            // that must not re-lock on a second fire, which is exactly what a
            // toggle would do.
            if (self.globalstate != "" && self.globalstate != __NULL__)
                SUB_UseTargets(self, activator, USE_ON);
            else
                SUB_UseTargets(self, activator, USE_TOGGLE);
        }
        else if (!all_on)
        {
            // NOT Half-Life: CMultiSource::Use fires nothing when IsTriggered
            // is false.  This tree has always pushed a USE_OFF on the closing
            // edge so a mastered door re-locks, and that is kept.  The
            // globalstate-held case deliberately does NOT reach here — being
            // held shut is not a closing edge, and firing OFF on it would drive
            // the chain from a state change that never happened.
            SUB_UseTargets(self, activator, USE_OFF);
        }
    }
};

/*QUAKED multisource (.5 .5 .5) (-8 -8 -8) (8 8 8)
AND-gate of trigger inputs.  Fires its target when every input that
has reported in is currently ON.  Acts as a master for any entity
whose `master` key names this multisource.

"targetname"  name (so other entities can target / master this)
"target"      entity / chain to fire when AND-gate flips ON
"globalname"  accepted, ignored (HL level-transition identity, not this)
"globalstate" extra condition — the named global must be ON as well, and the
              outgoing chain is handed USE_ON instead of USE_TOGGLE
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
