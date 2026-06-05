//
//  sv_multi_manager.qc  –  multi_manager (sequenced fire, HL/CS-compatible)
//
//  Fires a list of targets at scheduled offsets after .use is called.
//  Each mapper-supplied keyvalue pair on the entity is interpreted as
//   "<targetname>" "<delay-in-seconds>"
//  The HL "#suffix" trick lets a target be fired multiple times with
//  different delays — appending '#' followed by anything to the
//  targetname makes the engine treat it as a unique key, but we strip
//  the suffix here so the actual triggered entity matches.
//
//  Keyvalue capture relies on the patched FTE engine's
//  ED_ParseUnknownEpair callback — see engine/server/pr_cmds.c
//  SV_BadField hook.  Without that engine support, mapper-supplied
//  keys go through the FGD's explicit slots / get dropped (vanilla
//  FTE behaviour).
//
//  HL spawnflag MULTITHREADED (bit 1): every .use call spawns a
//  short-lived clone that fires the schedule then removes itself,
//  so concurrent activators don't collide.  Without the flag the
//  re-entry guard rejects new .use calls until the current pass
//  finishes.
//
//  Activator relay: HL multi_manager preserves the original
//  activator across the firing chain — a player-fired multi_manager
//  whose targets reference activator.something see the player as
//  the activator, not the multi_manager.  We capture in
//  multi_manager_use and stamp it back via SUB_UseTargets's
//  activator parameter for each slot fire.
//

// Externs from earlier compile units.
void(entity caller, entity who, float useType) SUB_UseTargets;        // sv_triggers.qc

const float SF_MM_MULTITHREADED = 1;

// Maximum slots — was 16 (HL hard cap) but with engine-side keyvalue
// capture we have no reason to limit it.  Bumped to 64; a multi_manager
// with more than that is almost certainly a map authoring mistake.
const float MM_MAX_SLOTS = 64;

// Per-entity dynamic slot storage.  Allocated as a chain of small
// "mm_slot" sub-entities so we don't need per-multi_manager fixed
// fields.  Each node carries one (target, delay) pair and a chain
// link to the next node.
.entity mm_first_slot;     // head of slot chain on the multi_manager
.entity mm_next_slot;      // chain link on each slot node
.string mm_slot_target;    // <targetname> with any '#suffix' stripped
.float  mm_slot_delay;     // mapper-supplied delay in seconds
.float  mm_count;          // number of populated slots
.float  mm_index;          // current slot during firing pass
.entity mm_activator;      // captured at use-time, replayed to chain
.float  mm_clone;          // 1 if this is a per-fire clone (for cleanup)

// Some valid multi_manager target keys collide with mapper fields used
// by other HL entities.  Those keys are parsed by the engine as normal
// QC fields instead of reaching ED_ParseUnknownEpair.  Recover the known
// collisions in multi_manager() before sorting the schedule.
.string train;             // func_trackautochange key; also a valid targetname

void() multi_manager_think;

// Strip an HL '#suffix' from a key so a single multi_manager can fire
// the same target multiple times with different delays.  Mapper-side
// the keys must be unique (HL convention is foo#0, foo#1, foo#a, etc.),
// so we look at the post-'#' portion only for hashing — the actual
// triggered targetname is everything before the '#'.
string(string key) MM_StripSuffix =
{
    float i = 0;
    float n = strlen(key);
    while (i < n)
    {
        if (str2chr(key, i) == '#')
            return substring(key, 0, i);
        i = i + 1;
    }
    return key;
};

// Allocate a new slot node and append it to the multi_manager's chain.
// Slots are stored in entry order — the calling code (the engine
// keyvalue hook) feeds them in BSP-entdata order, which matches the
// HL "key entry order" semantic the wiki documents.
void(entity mm, string target_name, float delay) MM_AddSlot =
{
    if (mm.mm_count >= MM_MAX_SLOTS)
    {
        dprint(sprintf("multi_manager: too many slots (cap %g) on '%s'\n",
                       MM_MAX_SLOTS, mm.targetname));
        return;
    }

    if (cvar("sv_debug_use"))
        print(sprintf("[mm-parse] '%s' slot %g: target=\"%s\" delay=%g\n",
                      mm.targetname, mm.mm_count, target_name, delay));

    entity node = spawn();
    node.classname        = "mm_slot";
    node.owner            = mm;
    node.mm_slot_target   = target_name;
    node.mm_slot_delay    = delay;
    node.mm_next_slot     = world;

    // Append to tail to preserve entry order.
    if (!mm.mm_first_slot)
    {
        mm.mm_first_slot = node;
    }
    else
    {
        entity tail = mm.mm_first_slot;
        while (tail.mm_next_slot)
            tail = tail.mm_next_slot;
        tail.mm_next_slot = node;
    }
    mm.mm_count = mm.mm_count + 1;
};

// Get the Nth slot node (0-indexed) from a multi_manager's chain.
// O(N) linear walk — fine because n is small and we only walk during
// firing.
entity(entity mm, float idx) MM_SlotAt =
{
    entity n = mm.mm_first_slot;
    float i = 0;
    while (n)
    {
        if (i == idx)
            return n;
        i = i + 1;
        n = n.mm_next_slot;
    }
    return world;
};

// In-place insertion sort by delay so multi_manager_think can walk
// linearly with monotonically-increasing scheduled times.  Stable
// (preserves entry order among equal-delay slots) — important for HL
// maps that use the same delay for sequential targets and rely on
// the entry order tie-break.
void(entity mm) MM_SortSlots =
{
    if (mm.mm_count < 2) return;

    // Bubble sort by adjacent-swap on the linked list.  Stable, O(n²)
    // but n is bounded by MM_MAX_SLOTS so the total work is trivial.
    float swapped = 1;
    while (swapped)
    {
        swapped = 0;
        entity a = mm.mm_first_slot;
        while (a && a.mm_next_slot)
        {
            entity b = a.mm_next_slot;
            if (a.mm_slot_delay > b.mm_slot_delay)
            {
                // Swap the (target, delay) PAIRS rather than re-link
                // the nodes — simpler and avoids prev-pointer juggling.
                string t = a.mm_slot_target; float d = a.mm_slot_delay;
                a.mm_slot_target = b.mm_slot_target;
                a.mm_slot_delay  = b.mm_slot_delay;
                b.mm_slot_target = t;
                b.mm_slot_delay  = d;
                swapped = 1;
            }
            a = a.mm_next_slot;
        }
    }
};

// Fire one slot via SUB_UseTargets with the captured activator.  The
// trick: temporarily swap self.target so SUB_UseTargets's existing
// find-by-targetname walk picks up THIS slot's target rather than
// the multi_manager's own .target field (which is unused after spawn).
void(entity mm, entity slot) MM_FireSlot =
{
    if (cvar("sv_debug_use"))
    {
        // Confirm the target actually exists in the world before we
        // attempt the fire — useful diagnostic for "trigger has key 6
        // but no entity named 6" cases.
        entity probe = find(world, targetname, slot.mm_slot_target);
        print(sprintf("[mm-fire] '%s' slot t=%g: target=\"%s\" delay=%g %s\n",
                      mm.targetname, time - mm.attack_finished,
                      slot.mm_slot_target, slot.mm_slot_delay,
                      probe ? "(exists)" : "(NO ENTITY WITH THAT TARGETNAME)"));
    }

    string saved_target     = mm.target;
    string saved_killtarget = mm.killtarget;
    float  saved_delay      = mm.delay;

    mm.target     = slot.mm_slot_target;
    mm.killtarget = "";        // killtarget would apply to all slots — bad
    mm.delay      = 0;          // delay for the SLOT is via our scheduler;
                                // suppress SUB_UseTargets's own delay path

    SUB_UseTargets(mm, mm.mm_activator, USE_TOGGLE);

    mm.target     = saved_target;
    mm.killtarget = saved_killtarget;
    mm.delay      = saved_delay;
};

// Per-tick fire pass.  Walks slots from mm_index forward and fires every
// slot whose scheduled time has arrived; reschedules at the next slot's
// fire time.  When all slots fired: clones remove themselves, in-place
// instances reset and become reusable.
void() multi_manager_think =
{
    while (self.mm_index < self.mm_count)
    {
        entity slot = MM_SlotAt(self, self.mm_index);
        if (!slot) break;

        float when = self.attack_finished + slot.mm_slot_delay;
        if (time < when)
        {
            self.nextthink = when;
            return;
        }

        MM_FireSlot(self, slot);
        self.mm_index = self.mm_index + 1;
    }

    // Schedule complete.
    if (self.mm_clone)
    {
        // Clean up clone + its slot chain.  The slots were copied,
        // so they're our private allocation, free them.
        entity n = self.mm_first_slot;
        while (n)
        {
            entity nxt = n.mm_next_slot;
            remove(n);
            n = nxt;
        }
        remove(self);
        return;
    }

    // In-place instance: reset for re-trigger.
    self.mm_index  = 0;
    self.think     = __NULL__;
    self.nextthink = 0;
};

// Spawn a clone with a copy of the slot chain so concurrent .use
// invocations don't trample each other.  Used only when MULTITHREADED
// spawnflag is set on the original multi_manager.
entity(entity src, entity src_activator) MM_SpawnClone =
{
    entity c = spawn();
    c.classname     = "multi_manager_clone";
    c.spawnflags    = src.spawnflags;
    c.targetname    = "";    // clones aren't externally addressable
    c.mm_count      = src.mm_count;
    c.mm_clone      = 1;
    c.mm_activator  = src_activator;

    // Deep-copy the slot chain.
    entity src_n = src.mm_first_slot;
    entity prev = world;
    while (src_n)
    {
        entity n = spawn();
        n.classname      = "mm_slot";
        n.owner          = c;
        n.mm_slot_target = src_n.mm_slot_target;
        n.mm_slot_delay  = src_n.mm_slot_delay;
        n.mm_next_slot   = world;
        if (!prev)
            c.mm_first_slot = n;
        else
            prev.mm_next_slot = n;
        prev = n;
        src_n = src_n.mm_next_slot;
    }
    return c;
};

void() multi_manager_use =
{
    if (cvar("sv_debug_use"))
        print(sprintf("[mm-use] '%s' activated by %s, %g slots, %s\n",
                      self.targetname,
                      activator.netname != "" ? activator.netname : activator.classname,
                      self.mm_count,
                      (self.spawnflags & SF_MM_MULTITHREADED) ? "MULTITHREADED" : "single-thread"));

    if (self.spawnflags & SF_MM_MULTITHREADED)
    {
        // Spawn a clone, dispatch it on its own schedule.  Original
        // multi_manager stays inert and immediately re-triggerable.
        entity c = MM_SpawnClone(self, activator);
        c.attack_finished = time;
        c.mm_index        = 0;
        c.think           = multi_manager_think;
        c.nextthink       = time;
        return;
    }

    // Non-multithreaded: re-entry guard.  Reject new .use until the
    // current schedule finishes (matches HL behaviour — second press
    // during firing is silently dropped).
    if (self.think == multi_manager_think)
    {
        if (cvar("sv_debug_use"))
            print(sprintf("[mm-use] '%s' BUSY (re-entry guard) — fire ignored\n",
                          self.targetname));
        return;
    }

    self.mm_activator    = activator;
    self.mm_index        = 0;
    self.attack_finished = time;
    self.think           = multi_manager_think;
    self.nextthink       = time;
};

// Engine keyvalue-capture hook (requires patched FTE — see
// engine/server/pr_cmds.c SV_BadField).  Called for every key on
// every entity that doesn't match a declared .field.  We capture
// EVERY unknown key as a slot regardless of entity classname, because
// FTE's BSP entdata parser doesn't guarantee classname is processed
// before other keys (some compilers sort keys alphabetically; some
// preserve mapper insertion order).  Gating on classname here was
// silently dropping slot adds for the "classname comes after slot
// keys" case.  The spawn function only consumes slots if the entity
// is actually a multi_manager — slots attached to anything else are
// dead memory but functionally harmless.
//
// The "#suffix" stripping lets a single multi_manager fire the same
// target multiple times via foo#0 / foo#1 / foo#a etc.
void(string key, string value) ED_ParseUnknownEpair =
{
    // Engine-handled / spawn-system keys — never slot pairs.  Skip
    // so they don't pollute multi_manager schedules.
    if (key == "wait")           return;
    if (key == "spawnflags")     return;
    if (key == "origin")         return;
    if (key == "angles")         return;
    if (key == "angle")          return;
    if (key == "target")         return;
    if (key == "targetname")     return;
    if (key == "killtarget")     return;
    if (key == "delay")          return;
    if (key == "globalname")     return;
    if (key == "message")        return;
    if (key == "model")          return;
    if (key == "classname")      return;
    if (key == "renderamt")      return;
    if (key == "rendercolor")    return;
    if (key == "rendermode")     return;
    if (key == "renderfx")       return;
    // Hammer / ZHLT editor metadata — not gameplay keys.
    if (substring(key, 0, 5) == "zhlt_")  return;
    if (substring(key, 0, 5) == "_minl")  return;
    if (substring(key, 0, 6) == "_light") return;
    if (key == "_tb_id" || key == "_tb_type" || key == "_tb_name") return;

    // Always print the capture so a user with sv_debug_use 1 enabled
    // at map-load can verify the engine hook is firing for each key.
    // Useful when "0 slots at use-time" symptom shows up — if the
    // [mm-parse] line is missing the engine never reached us.
    if (cvar("sv_debug_use"))
        print(sprintf("[mm-hook] ent=%g classname=\"%s\" key=\"%s\" value=\"%s\"\n",
                      num_for_edict(self), self.classname, key, value));

    // Capture as a slot.  Strip HL '#suffix' first.
    string tname = MM_StripSuffix(key);
    float  dly   = stof(value);
    MM_AddSlot(self, tname, dly);
};

/*QUAKED multi_manager (.5 .5 .5) (-8 -8 -8) (8 8 8) MULTITHREADED
Sequenced fire of an arbitrary list of targets at per-slot delays.

Each mapper-supplied keyvalue pair (other than the engine / standard
slot listed below) is interpreted as
   "<targetname>" "<delay-in-seconds>"
The HL '#suffix' on a key (foo#0, foo#1, foo#a) lets the same target
appear in the list multiple times with different delays.

"targetname"  name (must be set, otherwise nothing can fire it)

MULTITHREADED (1): each .use spawns a clone that fires the schedule
                   independently.  Without it, re-entry while running
                   is rejected (HL semantic).
*/
void() multi_manager =
{
    // The engine has populated ALL keyvalue pairs by now (calling
    // ED_ParseUnknownEpair for each unknown one), so mm_count and
    // mm_first_slot are already set.  Recover any known field-name
    // collisions, then sort and wire .use.
    if (self.train != "" && self.train != __NULL__)
    {
        if (cvar("sv_debug_use"))
            print(sprintf("[mm-recover] '%s' field-collision slot target=\"train\" delay=%g\n",
                          self.targetname, stof(self.train)));
        MM_AddSlot(self, "train", stof(self.train));
        self.train = "";
    }

    MM_SortSlots(self);
    self.use = multi_manager_use;

    // Post-sort summary — easy way to confirm at map-load that the
    // engine keyvalue hook captured everything the mapper wrote.
    // If the count looks low or a target is missing, the
    // [mm-parse] lines printed during entdata load show what
    // actually arrived (and in what order).
    if (cvar("sv_debug_use"))
    {
        print(sprintf("[mm-spawn] '%s' ready, %g slots (sorted by delay):\n",
                      self.targetname, self.mm_count));
        entity n = self.mm_first_slot;
        float i = 0;
        while (n)
        {
            print(sprintf("  [%g] target=\"%s\" delay=%g\n",
                          i, n.mm_slot_target, n.mm_slot_delay));
            i = i + 1;
            n = n.mm_next_slot;
        }
    }
};
