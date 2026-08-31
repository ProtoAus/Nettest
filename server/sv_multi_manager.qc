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
.float  mm_slot_usetype;   // USE_* from the VALUE's '#suffix' (see MM_ValueUseType)
.float  mm_count;          // number of populated slots
.float  mm_index;          // current slot during firing pass
.entity mm_activator;      // captured at use-time, replayed to chain
.float  mm_clone;          // 1 if this is a per-fire clone (for cleanup)
.entity mm_clone_src;      // on a clone: the in-place manager it was copied
                           // from.  Read by MM_ResolveCaller so a multisource
                           // recognises a MULTITHREADED manager's fire as
                           // coming from the entity it pre-registered.

// Some valid multi_manager target keys collide with mapper fields used
// by other HL entities.  Those keys are parsed by the engine as normal
// QC fields instead of reaching ED_ParseUnknownEpair.  Recover the known
// collisions in multi_manager() before sorting the schedule.
.string train;             // func_trackautochange key; also a valid targetname

// ---------------------------------------------------------------------------
//  FIELD-NAME COLLISION RECOVERY  (MM_CollisionScan, below)
//
//  The `train` case above was hand-written, but it is one instance of a whole
//  silent-failure class.  ED_FindField (qclib/pr_edict.c) is consulted BEFORE
//  the ED_ParseUnknownEpair hook, so every field this mod declares claims that
//  spelling in the BSP keyvalue namespace.  A multi_manager slot whose target
//  happens to share the name of a declared field is bound to the field and the
//  slot harvester never runs — no warning, no dprint, the target simply never
//  fires.  This is invisible from inside the game and hard to attribute from
//  outside it, which is why it survived so long.
//
//  Measured over the 121-map Sven corpus: 40 slots on 20 maps are swallowed.
//  Renaming the offending field is only occasionally an option, because most
//  of these names are REAL keyvalues that other classes depend on:
//
//      fadein / fadeout   ambient_generic 48-51 maps, game_text 66 maps
//      explosion          func_door 88 maps, func_breakable 87
//      barrel             func_tank family, 28 maps
//      target1..16        trigger_random family, 30 maps
//      target_count       trigger_random family, 30 maps
//      train              func_trackchange, 4 maps
//      noise / think / blocked   engine fields; cannot be renamed at all
//
//  So the general fix is recovery, not renaming: a multi_manager has no
//  legitimate use for ANY of these fields, so on a multi_manager a non-default
//  value in one of them is by definition a swallowed slot.  Read it back with
//  getentityfieldstring and re-add it.
//
//  Two field names WERE renamed instead, because their type makes readback
//  impossible and neither is a real keyvalue:
//      .entity sq_owner -> sq_maker      (sv_monsters.qc; pizza_ya_san2)
//      .void() drop     -> deleted       (sh_weapons.qc; hl_c05_a2, uplink)
//
//  KNOWN LIMITS, both structural rather than lazy:
//    * A float field holding delay 0 is unrecoverable.  getentityfieldstring
//      returns the empty string for a zero value (pr_bgcmd.c:7809), so "key
//      absent" and "key present, value 0" are indistinguishable once bound.
//      6 slots in the corpus, all `fadein` 0: crystal, hl_c08_a2, judgement x3,
//      th_ep3_04.  They are reported by the audit but cannot be restored.
//    * A .void() field is unrecoverable — the mapper's delay is not a function
//      name, so nothing survives the parse.  1 slot left in the corpus after
//      the `drop` deletion above: toonrun3's `shoot`, plus hl_c12's `blocked`,
//      which is an engine field and can never be renamed.
//
//  A KEY WITH A '#suffix' IS NEVER AFFECTED: "fadein#1" does not match any
//  field spelling, so it falls through to the hook and is harvested normally.
//  That is also why the recovered slot target is the bare field name.
// ---------------------------------------------------------------------------
float   mm_collide_done;   // scan is one-shot per map

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

// Sven's per-slot use type, encoded as a '#suffix' on the VALUE:
//
//     "pickup" "0#0"      fire at t=0 with USE_OFF
//     "pickup#1" "8#1"    fire at t=8 with USE_ON
//
// Two DIFFERENT '#' conventions are in play and they must not be confused:
// the KEY suffix is Hammer's duplicate-key disambiguator (MM_StripSuffix
// above), while the VALUE suffix is this use type.
//
//     #0 = Off    #1 = On    #2 = Kill (remove the target entirely)
//     no suffix  = Toggle (the default)
//
// This is ALSO a different enum from the `triggerstate` key, where 2 means
// Toggle — do NOT route this through GoldSrc_TriggerStateToUseType.
//
// Measured across the 121-map Sven corpus: 4903 suffixed values, of which
// #2 (Kill) is the single most common at 2428.  Dropping the suffix made
// every slot a Toggle, which inverts any stop-then-start pair — th_ep1_00's
// `roadratmngr` says "stop the train at 0, start it at 8" and got the
// opposite, which is why the intro truck never appeared.
const float MM_USE_KILL = -1;      // sentinel; not a real USE_* value

float(string value) MM_ValueUseType =
{
    float i = 0;
    float n = strlen(value);
    while (i < n)
    {
        if (str2chr(value, i) == '#')
        {
            float t = stof(substring(value, i + 1, n - i - 1));
            if (t == 0) return USE_OFF;
            if (t == 1) return USE_ON;
            if (t == 2) return MM_USE_KILL;
            return USE_TOGGLE;
        }
        i = i + 1;
    }
    return USE_TOGGLE;
};

// Allocate a new slot node and append it to the multi_manager's chain.
// Slots are stored in entry order — the calling code (the engine
// keyvalue hook) feeds them in BSP-entdata order, which matches the
// HL "key entry order" semantic the wiki documents.
void(entity mm, string target_name, float delay, float usetype) MM_AddSlot =
{
    if (mm.mm_count >= MM_MAX_SLOTS)
    {
        dprint(sprintf("multi_manager: too many slots (cap %g) on '%s'\n",
                       MM_MAX_SLOTS, mm.targetname));
        return;
    }

    if (cvar("sv_debug_use"))
        print(sprintf("[mm-parse] '%s' slot %g: target=\"%s\" delay=%g usetype=%g\n",
                      mm.targetname, mm.mm_count, target_name, delay, usetype));

    entity node = spawn();
    node.classname        = "mm_slot";
    node.owner            = mm;
    node.mm_slot_target   = target_name;
    node.mm_slot_delay    = delay;
    node.mm_slot_usetype  = usetype;
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

// Half-Life's CMultiManager::HasTarget (dlls/triggers.cpp): does this
// multi_manager carry a slot naming `nm`?
//
// It exists for ONE caller, and it is the one that makes multisource
// gates work: CMultiSource::Register (dlls/buttons.cpp:261-269) has a
// SECOND pass, after the `pev->target` walk, that iterates every
// multi_manager in the map and registers the ones that name the gate.
// A multi_manager has no `target` key — its targets live in arbitrary
// keyvalues — so without this pass a gate driven only by a
// multi_manager registers nothing at all.
//
// MM_USE_KILL slots are deliberately skipped.  Sven's "#2" suffix
// means "remove the target" rather than "fire it" (MM_FireSlot routes
// it to SUB_KillTargets and returns), so such a slot can never report
// in.  Counting it as an input would lock the gate for the whole map,
// which is the exact failure the registration pass exists to avoid.
// Half-Life has no kill suffix, so this has no parity cost.
float(entity mm, string nm) MM_HasTarget =
{
    if (nm == "" || nm == __NULL__)
        return FALSE;
    entity n = mm.mm_first_slot;
    while (n)
    {
        if (n.mm_slot_usetype != MM_USE_KILL && n.mm_slot_target == nm)
            return TRUE;
        n = n.mm_next_slot;
    }
    return FALSE;
};

// A MULTITHREADED multi_manager fires through a throwaway clone
// (MM_SpawnClone), so the entity that reaches SUB_UseTargets is NOT the
// one a multisource pre-registered.  Map the clone back to its source so
// the gate recognises its own input.
//
// Without this the clone falls through to ms_find_or_create_node, gains
// a SECOND node that is switched ON while the pre-registered node stays
// OFF forever, and the gate can never open.  Only 2 of the 440 corpus
// gates that MM_HasTarget newly registers are driven by a MULTITHREADED
// manager, but "2 maps soft-lock" is not an acceptable rounding error.
entity(entity e) MM_ResolveCaller =
{
    if (!e)
        return e;
    if (e.classname == "multi_manager_clone" && e.mm_clone_src)
        return e.mm_clone_src;
    return e;
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
                // Swap the (target, delay, usetype) TUPLES rather than
                // re-link the nodes — simpler and avoids prev-pointer
                // juggling.  usetype MUST be swapped with the pair or the
                // sort scrambles use types across slots.
                string t = a.mm_slot_target;
                float  d = a.mm_slot_delay;
                float  u = a.mm_slot_usetype;
                a.mm_slot_target  = b.mm_slot_target;
                a.mm_slot_delay   = b.mm_slot_delay;
                a.mm_slot_usetype = b.mm_slot_usetype;
                b.mm_slot_target  = t;
                b.mm_slot_delay   = d;
                b.mm_slot_usetype = u;
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
        print(sprintf("[mm-fire] '%s' slot t=%g: target=\"%s\" delay=%g usetype=%g %s\n",
                      mm.targetname, time - mm.attack_finished,
                      slot.mm_slot_target, slot.mm_slot_delay, slot.mm_slot_usetype,
                      probe ? "(exists)" : "(NO ENTITY WITH THAT TARGETNAME)"));
    }

    // Sven "#2" = Kill: remove the target outright rather than firing it.
    // Half-Life expresses this as UTIL_Remove, which SUB_KillTargets already
    // implements (find-by-name + remove).  It is deliberately NOT a fifth
    // USE_* value, so nothing downstream has to learn about it.
    if (slot.mm_slot_usetype == MM_USE_KILL)
    {
        SUB_KillTargets(slot.mm_slot_target);
        return;
    }

    string saved_target     = mm.target;
    string saved_killtarget = mm.killtarget;
    float  saved_delay      = mm.delay;

    mm.target     = slot.mm_slot_target;
    mm.killtarget = "";        // killtarget would apply to all slots — bad
    mm.delay      = 0;          // delay for the SLOT is via our scheduler;
                                // suppress SUB_UseTargets's own delay path

    SUB_UseTargets(mm, mm.mm_activator, slot.mm_slot_usetype);

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
    c.mm_clone_src  = src;   // so a multisource maps our fire back to `src`
    c.mm_activator  = src_activator;

    // Deep-copy the slot chain.
    entity src_n = src.mm_first_slot;
    entity prev = world;
    while (src_n)
    {
        entity n = spawn();
        n.classname      = "mm_slot";
        n.owner          = c;
        n.mm_slot_target  = src_n.mm_slot_target;
        n.mm_slot_delay   = src_n.mm_slot_delay;
        n.mm_slot_usetype = src_n.mm_slot_usetype;   // or MULTITHREADED clones lose it
        n.mm_next_slot    = world;
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
// Field lookup by name, so an unknown key can be retried in a different case
// before we give up on it.  Both are FTE extension builtins with no fixed
// number, hence the #0:name form (44 other builtins in sv_defs.qc use it).
float(string fieldname) findentityfield = #0:findentityfield;
float(float fieldnum, entity ent, string s) putentityfieldstring = #0:putentityfieldstring;

// Entity keys are matched with strcmp (engine/qclib/pr_edict.c ED_FindField),
// so key CASE is significant — and GoldSrc map compilers disagree about it.
// -sp_campaign_portal.bsp writes "m_iObeyTriggerMode"; pizza_ya_san1.bsp writes
// "m_imaxlivechildren", all lower.  Declaring every Sven key twice, once per
// casing, would be miserable and would still miss whatever a third compiler
// does, so instead: when a key misses, fold it to lower case and try once more.
//
// Our own field declarations are all lower-case, which makes the folded form
// the one that can actually hit.  Returns TRUE if the value was stored.
float(string key, string value) GoldSrc_TryCaseFoldedField =
{
    string lower = strtolower(key);
    if (lower == key)
        return FALSE;                   // already lower — the miss was real

    float fld = findentityfield(lower);
    if (fld <= 0)
        return FALSE;

    putentityfieldstring(fld, self, value);
    if (cvar("sv_debug_use"))
        print(sprintf("[keyfold] %s -> %s = \"%s\" on %s\n",
                      key, lower, value, self.classname));
    return TRUE;
};

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
    //
    // NOTE the underscore-stripped spellings.  The engine removes a leading
    // '_' BEFORE invoking this hook (engine/server/pr_cmds.c SV_BadField:
    // `if (*keyname == '_') keyname++;`), so ericw / TrenchBroom metadata
    // arrives here as "minlight", "tb_id", "light_*" — never with the
    // underscore.  The previous "_minl" / "_light" / "_tb_id" tests could
    // therefore never match, which is why our OWN maps were also spawning
    // mm_slot edicts for their editor metadata.
    if (substring(key, 0, 5) == "zhlt_")    return;   // no leading '_' — arrives intact
    if (substring(key, 0, 3) == "tb_")      return;   // _tb_id / _tb_type / _tb_name / _tb_textures
    if (substring(key, 0, 8) == "minlight") return;   // _minlight, _minlight_color
    // Deliberately NOT a bare "light" prefix test: that would eat a
    // legitimate multi_manager slot targeting an entity named e.g.
    // "lightswitch".  The specific ericw keys are enough.
    if (key == "light" || key == "lightignore" || key == "lightmap_scale") return;

    // GoldSrc / Sven Co-op per-entity config keys.  These are never
    // multi_manager slots, and a Sven map carries a LOT of them: each
    // func_door alone has m_iObeyTriggerMode plus four
    // fireon*_triggerstate, and -sp_campaign_portal.bsp has 1941 entities.
    // Without these tests every one becomes a real mm_slot edict, and both
    // SV_CheckTouchTriggers' per-player-per-frame findradius pair and
    // Door_OpenGroup's per-door classname scan walk the whole edict table.
    // The "m_" and "$" prefixes are structural (Half-Life member-variable
    // and Sven custom-keyvalue naming), so they cannot collide with a real
    // targetname in practice.
    // Before discarding anything, see whether it is just a mixed-case spelling of
    // a field we DO declare.
    //
    // nettest: this used to sit BELOW the m_/$/fireon prefix returns, which made it
    // unreachable for exactly the keys it was written for.  The old comment claimed
    // it "must run ahead of the slot capture, or a m_iObeyTriggerMode would become a
    // bogus slot instead of binding to .m_iobeytriggermode" - but the m_ return two
    // lines above it got there first, so no m_* key ever reached it, and
    // .m_iobeytriggermode is not declared anywhere in the tree.
    //
    // This matters well beyond that one key.  ED_FindField is a plain strcmp
    // (qclib/pr_edict.c:293), so a field only binds when the map's spelling matches
    // the declaration exactly, and the corpus is split: Hammer-family compilers emit
    // CamelCase (m_iszEntity, TriggerCondition) while others emit lowercase. The mod
    // declares BOTH spellings in different files - lowercase in sv_trigger_camera.qc,
    // CamelCase in sv_trigger_changetarget.qc / sv_trigger_copyvalue.qc /
    // sv_goldsrc_compat.qc:69 - so each key worked for exactly one compiler and was
    // silently dropped for the other. Hoisting the case-fold above the prefix returns
    // is what lets a single lowercase declaration serve both spellings, and it is a
    // prerequisite for scripted_sequence's m_isz* keys binding at all.
    //
    // The mm_slot flood protection the prefix returns provide is fully preserved:
    // an m_*/$/fireon key that does NOT case-fold onto a declared field still falls
    // through to the returns below and is discarded exactly as before.
    if (GoldSrc_TryCaseFoldedField(key, value))
        return;

    // WORLDSPAWN IS NOT A CAPTURE TARGET.
    //
    // The engine binds `self` to whatever edict is being parsed, with no edict-0
    // exclusion (engine/server/pr_cmds.c SV_BadField:495-506), and worldspawn is
    // parsed into edict 0 (engine/qclib/pr_edict.c:2439).  So every unrecognised
    // worldspawn key - MaxRange, startdark, chaptertitle, gametitle, defaultteam,
    // newunit, whatever the next compiler invents - reaches this hook with
    // self == world.  Combined with the classname fast-reject below deliberately
    // allowing self.classname == "" through, a classname-last compiler lets those
    // keys allocate real edicts owned by the world.
    //
    // That is not merely wasteful.  World is WRITABLE during entity parsing and
    // only becomes read-only afterwards (engine/server/sv_init.c:1652-1654), so
    // the capture succeeds silently at load and then MM_ReapOrphanSlots explodes
    // on the first StartFrame trying to clear the chain head back off the world:
    //     assignment to read-only entity 0 in MM_ReapOrphanSlots (??.mm_first_slot)
    // desertcircle produces exactly three of those.
    //
    // One guard, placed here, covers ALL FOUR things below that allocate storage
    // on self: CustomKey_Set, the '-' ce_key harvest, the gpe_item equip harvest
    // and MM_AddSlot.  Doing it by key name instead is what sv_th_entities.qc:1412
    // did for "skyname" - it works for exactly the key you thought of, and the
    // reap's own comment (:965-969) explains why that road has no end.
    //
    // Cost, stated plainly: a $s_/$i_/$f_/$v_ custom keyvalue written ON worldspawn
    // is now dropped rather than harvested.  That is the safer end of the trade -
    // world-hosted custom keys parse fine but trap the moment trigger_changevalue
    // writes one back, which is the same read-only error one frame later.  No map
    // in the corpus puts a custom keyvalue on worldspawn.
    if (self == world)
        return;

    // `sound` reaches this hook on EVERY map that uses it and always will: the
    // name is builtin #8, so the key can never have a field of its own (see the
    // .hl_soundkey note in sv_customdefs.qc).  Capture it verbatim onto the field
    // that stands in for it and stop — it is a real keyvalue, not an mm_slot, and
    // without this return it would fall through and allocate one.
    //
    // 45 uses across the corpus: 8 monster_tentacle impact-material selectors and
    // 37 Sven trigger_qualifier / trigger_hudsprite sound paths.
    if (key == "sound")
    {
        self.hl_soundkey = value;
        return;
    }

    if (substring(key, 0, 2) == "m_")     return;   // m_iObeyTriggerMode, m_iOpenFlags, m_fIgnoreTargetname
    // Sven custom keyvalues.  These used to be discarded outright; they are now
    // harvested into the side table in sv_customkeys.qc so trigger_condition can
    // compare one and trigger_changevalue can write one, which is how a Sven map
    // carries a variable.  CustomKey_IsCustom insists on a $s_/$i_/$f_/$v_ type
    // prefix, so a bare "$foo" and bspguy's $s_bspguy_map_source stamp — which
    // sits on hundreds of entities in every merged map — are still dropped here.
    if (substring(key, 0, 1) == "$")
    {
        if (CustomKey_IsCustom(key))
            CustomKey_Set(self, key, value);
        return;
    }
    if (substring(key, 0, 6) == "fireon") return;   // fireonclosed/opened/closing/opening[_triggerstate]
    if (key == "soundlist" || key == "explosion" || key == "weapon") return;
    // globalmodellist / globalsoundlist are declared fields (sh_modellist.qc)
    // so the engine binds them before this hook ever sees them — but a
    // mixed-case spelling that misses the case-fold above would otherwise reach
    // the slot capture below and become a bogus mm_slot edict whose delay is
    // stof("../pizza_ya_san/models.txt") == 0.
    if (key == "globalmodellist" || key == "globalsoundlist") return;
    // globalstate reaches here only via a mixed-case spelling the fold missed:
    // `.string globalstate` is a declared field (sv_triggers.qc) and carries real
    // meaning now (sv_globalstate.qc), so the engine binds the ordinary spelling
    // long before this hook.  Kept as a guard against it becoming an mm_slot.
    if (key == "globalstate" || key == "mapversion" || key == "scversion2") return;

    // trigger_createentity's child keys.  Sven spells them with a leading '-'
    // ("-model" "*158"), meaning "hold this and put it on the entity you
    // create", so the key set is whatever the child class accepts and none of
    // it can be declared here.  Harvest onto a chain; the spawner replays it.
    //
    // Two properties make this safe, and both were checked rather than assumed:
    //   * FTE strips a leading '_' before calling this hook (pr_cmds.c
    //     SV_BadField:447) but NOT a '-', so "-origin" arrives intact.
    //   * No field in the tree is named with a leading '-', so ED_FindField
    //     can never bind one of these ahead of us.
    // Today, without this block, each of the ~40 keys falls all the way through
    // to the slot capture below and allocates a junk mm_slot edict: the
    // skip-list at the top of this function tests bare "origin" / "angles" /
    // "target", which "-origin" does not match.
    //
    // Scoped like the game_text block, and "" is allowed for the same reason —
    // Hammer's key order is not guaranteed and classname may not have arrived
    // yet.  A corpus-wide census finds '-' keys on only two classnames
    // (trigger_createentity, and fallguys' trigger_create_ents), so the ""
    // case cannot steal a key from an entity that wanted it.
    //
    // strzone on BOTH halves: `key` and `value` are PR_TempStrings from the
    // engine's rotating buffer and are overwritten by the next key parsed —
    // the same trap documented on the m_iszEntity handling below.  Never freed;
    // they live as long as the map, and the whole corpus totals ~40 of them.
    if (substring(key, 0, 1) == "-"
        && (self.classname == "" || self.classname == __NULL__
            || self.classname == "trigger_createentity"))
    {
        entity ck = spawn();
        ck.classname       = "ce_key";
        ck.owner           = self;
        ck.ce_child_key    = strzone(substring(key, 1, strlen(key) - 1));
        ck.ce_child_value  = strzone(value);
        // Prepended, so the chain replays in reverse authoring order.  That is
        // fine: each key lands on a different field, and the spawner relinks
        // after the whole replay rather than depending on origin arriving last.
        ck.gpe_next_item    = self.gpe_first_item;
        self.gpe_first_item = ck;
        if (cvar("sv_debug_use"))
            print(sprintf("[createentity] captured \"%s\" = \"%s\"\n",
                          ck.ce_child_key, ck.ce_child_value));
        return;
    }

    // game_text styling keys that CANNOT be plain fields.
    //
    //   "effect" collides with the effect() builtin in sv_defs.qc — QC has a
    //           single namespace for fields and functions, so declaring
    //           `.float effect` is a hard compile error.
    //   "x"/"y" are legal field names but perilous next to vector _x/_y
    //           expansion, and far too generic to claim globally.
    //
    // Harvest them here instead.  self is bound to the entity being parsed,
    // so a direct assignment works.  This MUST sit above the classname
    // fast-reject below, which would otherwise discard them: Hammer emits
    // classname first, and game_text is not a multi_manager.
    // Scoped to game_text so a multi_manager slot literally named "x" or
    // "effect" can't be swallowed.  classname is "" when the compiler emits
    // it last, which is why the empty case is allowed through too.
    if (self.classname == "" || self.classname == __NULL__
        || self.classname == "game_text")
    {
        if (key == "effect") { self.gt_effect = stof(value); return; }
        if (key == "x")      { self.gt_x      = stof(value); return; }
        if (key == "y")      { self.gt_y      = stof(value); return; }
    }

    // Sven's weaponbox carries its entire contents as keyvalues, one per pool.
    //
    // NOT scoped to the classname, unlike the blocks above, and that is
    // deliberate: pizza_ya_san2 emits "classname" LAST for every one of its 28
    // weaponboxes, so at the moment these keys arrive self.classname is still
    // empty.  Scoping would silently harvest nothing.  The keys are distinctive
    // enough ("bullet556", "ARgrenades", "sporeclip") that claiming them
    // globally cannot swallow a real multi_manager slot, and landing one on a
    // non-weaponbox entity only sets a field nothing reads.
    //
    // Case matters: the BSP really does spell them "ARgrenades" and "Snarks".
    if (key == "bullet9mm")     { self.wbox_9mm         = stof(value); return; }
    if (key == "bullet357")     { self.wbox_357         = stof(value); return; }
    if (key == "buckshot")      { self.wbox_buckshot    = stof(value); return; }
    if (key == "bolts")         { self.wbox_bolts       = stof(value); return; }
    if (key == "bullet556")     { self.wbox_556         = stof(value); return; }
    if (key == "ARgrenades")    { self.wbox_argren      = stof(value); return; }
    if (key == "rockets")       { self.wbox_rockets     = stof(value); return; }
    if (key == "uranium")       { self.wbox_uranium     = stof(value); return; }
    if (key == "m40a1")         { self.wbox_762         = stof(value); return; }
    if (key == "sporeclip")     { self.wbox_spore       = stof(value); return; }
    if (key == "handgrenade")   { self.wbox_handgrenade = stof(value); return; }
    if (key == "satchelcharge") { self.wbox_satchel     = stof(value); return; }
    if (key == "tripmine")      { self.wbox_tripmine    = stof(value); return; }
    if (key == "Snarks")        { self.wbox_snarks      = stof(value); return; }

    // scripted_sentence's SPEAKER, for exactly the same reason and with exactly
    // the same shape.  Half-Life stores it in CScriptedSentence::m_iszEntity -
    // the same member scripted_sequence uses - but the two classes disagree
    // about the BSP spelling: scripted_sequence writes "m_iszEntity" and
    // scripted_sentence writes a bare "entity", which cannot be a QC field name
    // because `entity` is a type keyword.  So it lands here and is copied onto
    // the field its sibling already owns.
    //
    // Measured over the whole map corpus: 758 scripted_sentences across 124
    // maps, and ALL 758 carry this key.  Without it the speaker had to be
    // guessed from a nearest-monster radius search, which finds nothing at all
    // for 98 of them (the line then plays from an invisible point entity, so no
    // jaw moves anywhere) and picks the WRONG monster for another 196.  That is
    // 39% of the game's scripted dialogue coming out of the wrong mouth.
    //
    // Same classname scoping and same "" allowance as game_text above: the key
    // is generic enough that a multi_manager slot could legitimately be named
    // "entity", and Hammer's key order is not guaranteed.
    if (key == "entity")
    {
        if (self.classname == "" || self.classname == __NULL__
            || self.classname == "scripted_sentence")
        {
            // strzone because `value` is a PR_TempString from the engine's
            // rotating buffer (pr_cmds.c:502) and will be overwritten by the
            // next key parsed.  Never freed: it lives as long as the map does,
            // and 758 of them across the whole corpus is not a leak worth
            // bookkeeping for.
            self.m_iszentity = strzone(value);
            return;
        }
    }

    // game_player_equip's item list.  The KEY is the classname to give and the
    // VALUE is the quantity, so there is no fixed key set to declare — see the
    // gpe_first_item comment in sv_customdefs.qc.  Capture onto a child chain.
    //
    // Note some of these names (ammo_357, ammo_shells, ...) are real fields
    // already, so the engine binds them and they never arrive here.  That is a
    // known and documented gap, not something this hook can fix.
    // The classname test allows "" as well as the real name: these maps emit
    // classname LAST (verified on th_ep1_00, whose game_player_equip lists
    // item_suit before classname), so requiring the real name would never
    // match a single key.
    //
    // item_name_* / item_group_* are EXCLUDED — they are Sven's InventoryRules
    // base-class keys, not items to hand out, and they appear on unrelated
    // entities (th_ep1_00 has two on a func_conveyor).
    if ((self.classname == "" || self.classname == __NULL__
         || self.classname == "game_player_equip")
        && (substring(key, 0, 7) == "weapon_"
            || substring(key, 0, 5) == "ammo_"
            || (substring(key, 0, 5) == "item_"
                && substring(key, 0, 10) != "item_name_"
                && substring(key, 0, 11) != "item_group_")))
    {
        entity gi = spawn();
        gi.classname     = "gpe_item";
        gi.owner         = self;
        gi.netname       = strzone(key);
        gi.count         = stof(value);
        gi.gpe_next_item = self.gpe_first_item;
        self.gpe_first_item = gi;
        if (cvar("sv_debug_use"))
            print(sprintf("[game_player_equip] captured \"%s\" x%g\n", key, gi.count));
        return;
    }

    // Fast reject: if classname has ALREADY been parsed for this entity and
    // it isn't a multi_manager, there is nothing to capture.  This is an
    // OPTIMISATION, not a guarantee — ED_ParseEdict (engine/qclib/pr_edict.c)
    // walks keys in strict file order with no classname pre-pass, so this
    // fires only when the compiler emitted classname first (Hammer/VHLT and
    // TrenchBroom/ericw both do) and simply doesn't trigger in the
    // "classname last" case described above.  Correctness for that case is
    // unchanged: we still capture the slot and the spawn function still
    // ignores it unless the entity really is a multi_manager.
    if (self.classname != "" && self.classname != __NULL__
        && self.classname != "multi_manager")
        return;

    // Always print the capture so a user with sv_debug_use 1 enabled
    // at map-load can verify the engine hook is firing for each key.
    // Useful when "0 slots at use-time" symptom shows up — if the
    // [mm-parse] line is missing the engine never reached us.
    if (cvar("sv_debug_use"))
        print(sprintf("[mm-hook] ent=%g classname=\"%s\" key=\"%s\" value=\"%s\"\n",
                      num_for_edict(self), self.classname, key, value));

    // Capture as a slot.  Strip HL '#suffix' first.
    // Key suffix = Hammer's duplicate-key disambiguator.
    // Value suffix = Sven's per-slot use type.  Two different conventions.
    string tname = MM_StripSuffix(key);
    float  dly   = stof(value);            // stof stops at '#', so "8#1" -> 8
    float  ut    = MM_ValueUseType(value);
    MM_AddSlot(self, tname, dly, ut);
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
    //
    // `train` is handled here rather than being left to MM_CollisionScan
    // purely because it can be: it needs no cross-entity knowledge, and
    // recovering at spawn is strictly earlier than the post-spawn pass.
    // MM_CollisionScan is the general backstop and will find it having
    // already been cleared, so there is no double-add.
    if (self.train != "" && self.train != __NULL__)
    {
        if (cvar("sv_debug_use"))
            print(sprintf("[mm-recover] '%s' field-collision slot target=\"train\" delay=%g\n",
                          self.targetname, stof(self.train)));
        MM_AddSlot(self, "train", stof(self.train), MM_ValueUseType(self.train));
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

// ---------------------------------------------------------------------------
//  MM_CollisionScan — recover multi_manager slots swallowed by declared fields
//
//  Runs once per map, from StartFrame, AFTER every entity has spawned.  It has
//  to be a post-spawn pass rather than part of multi_manager(): the candidate
//  set is derived from the map's own targetnames, and during entity parsing an
//  arbitrary number of those have not been read yet.  Nothing can fire a
//  multi_manager before the first frame, so this is early enough.
//
//  The algorithm is the intersection the bug report needed and nobody could
//  see from inside the game:
//
//    for every targetname T in the map:
//        if findentityfield(T) hits, then any multi_manager slot named T was
//        bound to that field instead of being harvested.  A multi_manager has
//        no legitimate reason to carry ANY of these fields, so a non-default
//        value on one IS the lost slot — read it back and re-add it.
//
//  No dedupe table is needed: recovery clears the field, so a second entity
//  sharing the same colliding targetname finds nothing left to do.
//
//  The summary is printed unconditionally (not behind sv_debug_use) precisely
//  because this failure mode is otherwise silent.  A map that trips it should
//  say so on the console once.
// ---------------------------------------------------------------------------
void() MM_CollisionScan =
{
    entity e, m;
    float  fld, ftype, dly, ut;
    float  nfound, nrecovered, nlost;
    string tn, val;

    // Explicit: QC locals are statically allocated and are NOT zeroed on entry,
    // so these three would otherwise carry whatever the last caller left behind.
    nfound = 0;  nrecovered = 0;  nlost = 0;

    e = world;
    while ((e = nextent(e)))
    {
        tn = e.targetname;
        if (tn == "" || !tn)
            continue;

        fld = findentityfield(tn);
        if (fld <= 0)
            continue;                       // ordinary name, nothing claims it

        // Only the FIRST entity carrying a given colliding name does the work.
        // Several entities sharing one targetname is normal (hl_c12 has three
        // called "blocked"), and without this the unrecoverable-type warning
        // below repeats once per entity - the recovery path is already
        // idempotent because it clears the field it read.
        if (find(world, targetname, tn) != e)
            continue;

        ftype  = entityfieldtype(fld);
        nfound = nfound + 1;

        // WARN ON THE NAME, NOT ON THE VALUE, for types readback cannot serve.
        // This is the case hl_c12 exposed: its `blocked` slot binds to the
        // engine's .void() blocked, where the mapper's delay is not a function
        // name and nothing at all survives the parse - so the field still reads
        // as default and the loop below would find nothing to report.  Warning
        // when the colliding NAME is seen is the only way to surface it.
        // EV_ENTITY is lumped in here deliberately even though its readback is
        // non-empty: the value that comes back is an edict index, not the
        // mapper's delay, so recovering from it would invent a wrong schedule.
        if (ftype != EV_STRING && ftype != EV_FLOAT)
        {
            nlost = nlost + 1;
            print(sprintf("[mm-collide] map targetname \"%s\" collides with a declared "
                          "field of type %g; any multi_manager slot naming it was "
                          "discarded during parsing and CANNOT be recovered\n", tn, ftype));
            continue;
        }

        m = world;
        while ((m = find(m, classname, "multi_manager")))
        {
            // Empty means either "key absent" or - for a float - "key present
            // with value 0", which the engine cannot distinguish for us
            // (pr_bgcmd.c:7809 early-outs on a zero eval).  See the header.
            val = getentityfieldstring(fld, m);
            if (val == "" || !val)
                continue;

            // Resolve the tempstring fully before anything else can rotate it.
            dly = stof(val);
            ut  = MM_ValueUseType(val);

            MM_AddSlot(m, tn, dly, ut);
            MM_SortSlots(m);

            // Clear so the field reads default again: keeps the entity honest
            // for anything that inspects it later, and makes the scan
            // idempotent across duplicate targetnames.
            if (ftype == EV_STRING) putentityfieldstring(fld, m, "");
            else                    putentityfieldstring(fld, m, "0");

            nrecovered = nrecovered + 1;
            print(sprintf("[mm-recover] '%s': restored slot \"%s\" delay %g usetype %g "
                          "(was swallowed by a declared field)\n",
                          m.targetname, tn, dly, ut));
        }
    }

    // Printed whenever ANY collision exists, even with nothing recovered.  A
    // map can collide on a float name whose slot delay is 0, which is exactly
    // the case readback cannot see (corpus: `fadein` 0 on crystal, hl_c08_a2,
    // judgement x3, th_ep3_04), so "0 recovered" is not the same as "nothing
    // was lost" and the line must not be suppressed.
    if (nfound)
        print(sprintf("[mm-collide] %g map targetname(s) collide with declared fields: "
                      "%g slot(s) recovered, %g unrecoverable.  A float-typed collision "
                      "carrying delay 0 is invisible to this scan.\n",
                      nfound, nrecovered, nlost));
};

// ---------------------------------------------------------------------------
//  MM_ReapOrphanSlots — free slot nodes that were captured onto non-multi_managers
//
//  ED_ParseUnknownEpair's classname fast-reject is an optimisation that only
//  fires when the compiler emitted "classname" BEFORE the key in question.
//  Hammer and TrenchBroom do; J.A.C.K. frequently does not.  On a
//  classname-last map every unrecognised key on EVERY entity therefore reaches
//  the slot capture with self.classname still empty, and becomes a real edict.
//
//  That is by design and is documented at the fast-reject: correctness is
//  unaffected because the spawn function only consumes slots when the entity
//  really is a multi_manager.  What it costs is edicts.  pizza_ya_san2 is the
//  worst case in the corpus - J.A.C.K. writes every FGD default key on every
//  entity, and the map allocates hundreds of dead mm_slot nodes on top of its
//  own entity count.  Every one of them is walked by SV_CheckTouchTriggers'
//  per-player-per-frame findradius pair and by Door_OpenGroup's classname scan.
//
//  Guessing at key names to extend the skip list would be endless and would
//  risk eating a real slot named after whatever was guessed.  Reaping after the
//  fact is exact instead of heuristic: once every entity has spawned, a slot
//  whose owner did not turn out to be a multi_manager can never be read by
//  anything, so it can simply go.  No key names are involved.
// ---------------------------------------------------------------------------
float() MM_ReapOrphanSlots =
{
    entity s, nx;
    float  n;

    n = 0;
    s = find(world, classname, "mm_slot");
    while (s)
    {
        // Advance BEFORE the remove, or find() resumes from a freed edict.
        nx = find(s, classname, "mm_slot");

        // "multi_manager_clone" counts as a live owner too.  MM_SpawnClone
        // deep-copies the slot chain onto a clone with its own classname, and
        // although this pass runs on the first StartFrame - ahead of every
        // think, so ahead of any clone in practice - a multi_manager used
        // during map load would already have one.  Freeing a live clone's
        // schedule out from under it is not a failure mode worth leaving open
        // for the sake of one string compare.
        if (s.owner.classname != "multi_manager"
         && s.owner.classname != "multi_manager_clone")
        {
            // Drop the head/count too.  Nothing reads them on a non-multi_manager,
            // but leaving a chain pointer at a removed edict is the kind of thing
            // that turns a later debug print into a crash.
            //
            // NOT on the world.  ED_ParseUnknownEpair now refuses to capture onto
            // worldspawn at all, so this should be unreachable for that case - but
            // the branch is also taken when the owner was remove()d (a freed edict
            // reads back classname ""), and world is read-only from the end of
            // SV_LoadFromFile onward.  A store here would raise
            // "assignment to read-only entity 0" once per orphan, per field.
            if (s.owner != world)
            {
                s.owner.mm_first_slot = world;
                s.owner.mm_count      = 0;
            }
            remove(s);
            n = n + 1;
        }
        s = nx;
    }
    return n;
};

// The one-shot post-spawn pass, called from StartFrame.  Both halves need every
// entity to exist, and neither can run from a spawn function.
void() MM_PostSpawnPass =
{
    float reaped;

    if (mm_collide_done)
        return;
    mm_collide_done = TRUE;

    MM_CollisionScan();

    reaped = MM_ReapOrphanSlots();
    if (reaped)
        print(sprintf("[mm-reap] freed %g orphan slot edict(s) captured onto "
                      "non-multi_manager entities\n", reaped));
};
