//
//  sv_monsters.qc  —  the monster construction seam
//
//  This mod has no NPC AI.  Sven Co-op maps are full of monsters anyway, and
//  they are load-bearing: they carry targetnames that trigger chains resolve
//  against, they are the look-at targets of trigger_cameras, and
//  scripted_sequences address them by name.  Dropping them severs map logic.
//
//  So every monster-ish class routes through ONE function, Monster_Build().
//  Today it produces a visible, non-thinking body with the right model, pose,
//  hull and name.  When GoldSrc AI is added later, it goes behind this one
//  function and every caller — monster_furniture, the map-placed monsters,
//  and everything squadmaker produces — inherits it without being touched.
//  Monster_HasAI() is the switch that will flip.
//
//  Do not add monster spawn functions anywhere else.  A second construction
//  path is exactly what this file exists to prevent.
//

void() BrushSync_ApplyRenderKeys;                                 // sv_brushsync.qc
void(entity caller, entity who, float useType) SUB_UseTargets;    // sv_triggers.qc
float(string master_name, entity who) IsMasterTriggered;          // sv_triggers.qc

// The AI layer compiles AFTER this file (it reads the per-monster keys declared
// below), so everything this file needs from it arrives by forward declaration.
// FUNCTIONS only — QC forward-declares those but not arrays, which is exactly
// why no AI array is ever named in here.
float(string cls) AI_ClassHasAI;    // sv_ai_core.qc
float(entity m)   AI_Spawn;
float(string path) Soundlist_Load;  // sv_soundlist.qc
float(string cls)  Squadmaker_IsItem;                       // sv_goldsrc_ammo.qc
entity(string cls, vector org) Squadmaker_SpawnItem;        // sv_goldsrc_ammo.qc
void(entity m)    AI_Died;
void(entity m)    Squad_Remove;     // sv_ai_squad.qc
float()           Headcrab_DefaultHealth;   // monsters/mon_headcrab.qc
float()           Zombie_DefaultHealth;     // monsters/mon_zombie.qc
float()           Cockroach_DefaultHealth;  // monsters/mon_cockroach.qc
float()           Islave_DefaultHealth;     // monsters/mon_islave.qc
float()           Houndeye_DefaultHealth;   // monsters/mon_houndeye.qc
float()           Grunt_DefaultHealth;      // monsters/mon_grunt.qc
float()           Shocktrooper_DefaultHealth; // monsters/mon_grunt.qc
float()           HWGrunt_DefaultHealth;    // monsters/mon_grunt.qc
float()           Otis_DefaultHealth;       // monsters/mon_grunt.qc
float()           Turret_DefaultHealth;     // monsters/mon_turret.qc
float()           Barnacle_DefaultHealth;   // monsters/mon_barnacle.qc
float()           Scientist_DefaultHealth;  // monsters/mon_grunt.qc
float()           Generic_DefaultHealth;    // monsters/mon_generic.qc
float()           BigMomma_DefaultHealth;     // monsters/mon_bosses.qc
float()           Apache_DefaultHealth;     // monsters/mon_bosses.qc
float()           Osprey_DefaultHealth;     // monsters/mon_bosses.qc
float()           Gargantua_DefaultHealth;    // monsters/mon_bigfoes.qc
float()           Babygarg_DefaultHealth;    // monsters/mon_bigfoes.qc
float()           Stukabat_DefaultHealth;    // monsters/mon_bigfoes.qc
float()           Kingpin_DefaultHealth;    // monsters/mon_bigfoes.qc
float()           Leech_DefaultHealth;   // monsters/mon_swimfly.qc
float()           Ichthyosaur_DefaultHealth;   // monsters/mon_swimfly.qc
float()           Controller_DefaultHealth;   // monsters/mon_swimfly.qc
float()           Agrunt_DefaultHealth;      // monsters/mon_aliens.qc
float()           Bullsquid_DefaultHealth;      // monsters/mon_aliens.qc
float()           Pitdrone_DefaultHealth;      // monsters/mon_aliens.qc
float()           Gonome_DefaultHealth;      // monsters/mon_aliens.qc
float()           Voltigore_DefaultHealth;      // monsters/mon_aliens.qc
float()           Barney_DefaultHealth;
void()            GoldSrc_UnknownRelay_Use; // sv_goldsrc_compat.qc

// Keys shared by Sven's monster family.  .body / .sequence / .angle come from
// sv_cycler.qc and .sequencename / .minhullsize / .maxhullsize from
// sv_item_generic.qc, both of which precede this file in sv_progs.src.
.string displayname;        // human-readable name (HUD / "killed by" text)

// Sven's Monster base-class key is "displayname" — FGD label "In-game Name",
// sven-coop.fgd:591, inherited by every monster_* class and repeated on squadmaker
// (:5532).  NOT "netname", which on a monster is the SQUAD name (sven-coop.fgd:3847
// and eleven other classes), and there is no "custom_name" / "display_name" anywhere
// in the 7054-line FGD.  Sven uses this same key as the payload of its own look-at
// readout: the Breakable base class labels it "HUD Info name" (:975) beside a
// showhudinfo gate (:991), and monsters carry the key with no such gate — so a
// monster's name is unconditional, which is why the HUD tag below needs no spawnflag.
//
// The FALLBACK carries more of the weight than the key does: most placed monsters
// have no displayname at all, and "monster_human_grunt_ally" is not a name.
string(string cls) Monster_PrettyClassName =
{
    string s = cls;
    if (substring(s, 0, 8) == "monster_")
        s = substring(s, 8, strlen(s) - 8);
    return strreplace("_", " ", s);
};

string(entity m) Monster_DisplayName =
{
    if (m.displayname != "" && m.displayname != __NULL__)
        return m.displayname;
    return Monster_PrettyClassName(m.classname);
};

.float  is_player_ally;
// Sven's "is player ally" is a FLIP of the class default, not a boolean, and the
// FGD proves it twice over: on a plain monster the choices read "No (Default)" /
// "Yes", on a talkmonster they read "Yes (Default)" / "No", and squadmaker's
// respawn_as_playerally spells it out as "Default (0)" / "Opposite (1)".  One rule
// covers all three - 1 means "the opposite of whatever this class normally is" -
// so the map key is moved here at build time and .is_player_ally is left for the
// ClassInit to state the class default into.  AI_Spawn applies the flip afterwards.
.float  ai_ally_flip;
.float  bloodcolor;
.float  classify;           // Sven CLASS_* relationship override
.float  gag;                // suppress idle speech
.float  notsolid;           // Sven tri-state: -1 = class default, 0 = solid, 1 = not
.float  weapons;            // equipment bitfield for the spawned body

// squadmaker's description of the child it makes
.string monstertype;        // classname to spawn
.string new_model;          // model override for the child
.float  new_body;           // bodygroup override for the child
// new_skin is new_body's sibling and was the only one of the pair missing.  Same
// -1 tri-state, same squadmaker-only scope (565 uses across 9 maps, all on
// squadmaker; 544 of them are the -1 no-op, so 21 entities in the whole corpus
// actually change appearance).  Skins are how a Sven map dresses one spawner's
// output differently from another's without shipping a second model.
.float  new_skin;           // skin override for the child, -1 = don't modify
.float  monstercount;       // total to spawn, -1 = unlimited
.float  m_imaxlivechildren; // concurrent cap
.float  spawn_mode;
.float  respawn_as_playerally;
.string squadname;
.float  is_squad_leader;
.string trigger_target;     // fired when trigger_condition is met
.float  trigger_condition;
// Sven's two idle-behaviour keys, on both the squadmaker and the monster itself.
// Declared ALL-LOWERCASE: ED_FindField is a plain strcmp and GoldSrc_TryCaseFoldedField
// lowercases before retrying, so a CamelCase declaration binds nothing.
.string guard_ent;          // targetname of the entity this monster guards
.float  freeroam;           // 0 = never, 1 = when idle, 2 = always
// The SAME two keys as a Half-Life base monster spells them.  A squadmaker
// writes the underscored pair above to describe its child; a MAP-PLACED monster
// writes "TriggerTarget" / "TriggerCondition" in CamelCase, and ED_FindField is
// a plain strcmp, so those bound to nothing at all and were silently dropped.
//
// Declared ALL-LOWER on purpose: GoldSrc_TryCaseFoldedField
// (server/sv_multi_manager.qc) folds a missed key to lower case and retries, and
// only a lowercase declaration can be hit that way.  Declaring the CamelCase
// spelling would bind Hammer's output and miss every other compiler's.
// Monster_NormaliseSvenKeys folds these onto the pair above.
//
// Measured: 46 map-placed monsters across 8 hc2 maps, plus the -TriggerCondition
// children a trigger_createentity spawns.
.string triggertarget;
.float  triggercondition;
.string soundlist;          // sound replacement file, e.g. "../pizza_ya_san/ownershin.txt"
.float  sl_table;           // resolved soundlist index + 1, 0 = none (sv_soundlist.qc)

// squadmaker's spawnflags, from sven-coop.fgd.  Only three of them describe the
// CHILD; the rest describe the spawner, which is why the maker's spawnflags can
// never simply be copied across - its START_ON would read as the child's
// SF_MON_WAIT_TILL_SEEN and its CYCLIC as the child's SF_MON_MONSTERCLIP.  The
// child-side SF_MON_* constants come from sv_ai_defs.qc, which compiles at
// sv_progs.src:22, well before this file.
const float SQ_SF_MONSTERCLIP    = 8;
const float SQ_SF_PRISONER       = 16;
const float SQ_SF_WAITFORSCRIPT  = 128;

// Sven's trigger_condition selector (sven-coop.fgd:5461).  Only Death is acted on
// differently from "fire immediately", because it is the only one the corpus
// actually uses in bulk - all 28 users on pizza_ya_san1 set it - and because
// getting it wrong is what runs a wave counter ahead of its wave.
const float SQ_COND_DEATH = 4;

// Sven's spawn_mode, "Blocked Spawn Handling" (sven-coop.fgd:5451).  What a maker
// does when the spawn point is occupied.  37 of pizza_ya_san1's 97 makers set it
// - 15 BLOCK, 22 FORCE - and none of the three modes was implemented, so every
// one of them behaved as LEGACY.
//
// LEGACY is what this file already did and stays the default: build the body,
// discover the overlap, throw it away, and try again at the full `delay`.  It
// burns a monstercount slot doing so, which for a finite wave means the wave
// quietly shrinks.
const float SQ_SPAWN_LEGACY = 0;
const float SQ_SPAWN_BLOCK  = 1;    // don't consume the budget; retry quickly
const float SQ_SPAWN_FORCE  = 2;    // stand it up anyway (see .ai_forceplace)

// How soon BLOCK retries.  Sven's own wording is "spawn as soon as clear", so the
// interval wants to be short enough to feel immediate when a corpse fades or a
// player steps aside, and long enough that a permanently walled-in spawn point
// is not a tracebox every frame.  Half a second is both.
const float SQ_BLOCK_RETRY = 0.5;

// --- map-pacing overrides ---------------------------------------------------
// A GoldSrc map's wave pacing lives entirely in ITS entities, not in this code:
// trigger_entity_iterator's delay_between_runs and squadmaker's `delay` are what
// decide how busy a map feels, and on desertcircle the iterator is additionally
// per-PLAYER, so a full server and a one-player game are different games.  These
// two helpers are the single point where a server admin can lean on that without
// editing maps.  Both default to a no-op.
//
// Compiled here rather than beside the iterator because sv_monsters.qc precedes
// sv_goldsrc_entities.qc in sv_progs.src and both need them.
float(float secs) SV_ScaleSpawnDelay =
{
    float s = cvar("sv_monster_spawnrate");
    if (s <= 0)
        return secs;                    // 0 / negative is "leave the map alone"
    float out = secs / s;
    // Floor it: a large multiplier must never produce a think interval short
    // enough to spin, and 0.05 is already 20 spawns a second.
    if (out < 0.05)
        out = 0.05;
    return out;
};

// Scaled concurrent-children cap.  Returns 0 for "no cap", matching the meaning
// m_imaxlivechildren already has when a map leaves it unset.
//
// 0 DELIBERATELY DOES NOT MEAN "UNLIMITED" HERE, however tempting that reading
// is.  cvar() answers 0 for a cvar the table has not applied yet, and the AI
// self-test runs early enough in map load to see exactly that - so an
// "0 == unlimited" arm silently removed every map's cap and the squadmaker test
// caught it as `cap breached, 4 live` / `killed 4 children, expected 3`.  Same
// shape as the USE_OFF-is-zero trap documented at sv_customdefs.qc:767.
// Unset therefore means "leave the map alone"; to lift a cap, scale it up.
float(float cap) SV_ScaleMaxLive =
{
    if (cap <= 0)
        return 0;                       // map said unlimited - stay unlimited
    float s = cvar("sv_monster_maxlive");
    if (s <= 0)
        return cap;                     // unset / nonsense - map's cap stands
    float out = floor(cap * s);
    if (out < 1)
        out = 1;
    return out;
};

// Live squadmaker bookkeeping
.float  sq_spawned_total;
.float  sq_live_children;
.float  sq_enabled;
.float  sq_warned;          // "no implementation for X" printed once, not per spawn
// NAMED sq_maker, NOT sq_owner, AND THAT IS LOAD-BEARING.  A declared field name
// occupies the map keyvalue namespace: the engine binds any BSP key with that
// spelling to the field and never calls ED_ParseUnknownEpair for it, so a
// multi_manager slot of the same name is swallowed before the slot harvester
// can see it (sv_multi_manager.qc MM_CollisionScan).  pizza_ya_san2 names its
// pizza-shop-owner squadmaker "sq_owner" and fires it from two multi_managers
// (mm_opend at 16s, mm_endmi2 at 0s) — with the field called sq_owner both
// slots vanished and the title character never spawned.  A .entity field cannot
// be recovered by readback either (the value reads back as an edict index, not
// the mapper's delay string), so renaming is the only fix.  Do not rename back.
.entity sq_maker;           // child -> its maker
.float  sq_counted;         // 1 while this child occupies a slot in sq_maker's count
// Item children are counted by SCAN rather than by latch.  A monster hands its
// slot back from one place (Monster_Teardown); a pickup can leave the world
// through the ammo touch, the weapon touch, a round restart or a plain remove(),
// and hooking four paths that must all agree is exactly the shape of bug the
// squad-slot latch exists to avoid.  Counting live children when the cap is
// tested is immune to all of them.  findchainfloat needs a float key, hence an
// id rather than the .sq_maker entity pointer; ids start at 1 so that a child
// with no owner (sq_ownerid 0) can never match a real maker.
.float  sq_id;              // maker: its own id, 1-based
.float  sq_ownerid;         // item child: the id of the maker that dispensed it
float   sq_next_id;

// Every constructed monster is chained so the AI pass can walk them without an
// O(num_edicts) find() per frame.  Head is reset in worldspawn.
//
// nettest: DOUBLY linked now.  The old chain was singly linked with no unlink at
// all, which was invisible only because nothing walked it yet: the moment a
// per-frame walker exists, a remove()d monster leaves a freed edict wired into the
// list and the walker reads through it.  Same shape as the player chain at
// sv_customdefs.qc:657-686, deliberately, so there is one idiom to learn.
entity monster_chain_head;
.entity monster_chain_next;
.entity monster_chain_prev;

void() Monster_Killed;      // defined below; Monster_Build installs it
float(string cls) Monster_ClassHasAI;   // defined below, used by Monster_Killed above it

// How many entities are currently linked.  Maintained exactly by the two
// functions below and reset from worldspawn beside monster_chain_head, purely so
// Monster_Chain_Verify has an honest upper bound to cap its walk at.  Nothing
// else should read it as a monster census - a dormant or dead monster is still
// in the chain.
float monster_chain_count;

// Counters for `sv_ai_debug 2`.  Both must sit at ZERO in normal play; either one
// climbing means some removal path is still freeing a linked monster.
float mchain_dbg_freed;         // freed edicts unlinked by the sweep
float mchain_dbg_cycles;        // cycles detected and broken
float monster_chain_next_verify;

void(entity adding) monster_chain_add =
{
    if (adding.monster_chain_prev || adding.monster_chain_next || adding == monster_chain_head)
    {
        dprint("[monster] chain_add on an entity already in the chain\n");
        return;
    }
    if (monster_chain_head)
        monster_chain_head.monster_chain_prev = adding;
    adding.monster_chain_next = monster_chain_head;
    monster_chain_head        = adding;
    monster_chain_count       = monster_chain_count + 1;
};

void(entity removing) monster_chain_remove =
{
    // Membership test first, so the count stays exact.  This is deliberately the
    // same three-way test monster_chain_add guards with, and it covers all four
    // positions: sole element and head-of-many both match on the head compare,
    // tail matches on prev, middle matches on both.  An entity that was never
    // linked matches none of them and must not decrement anything.
    float linked = (removing == monster_chain_head)
                 || removing.monster_chain_prev
                 || removing.monster_chain_next;

    if (removing == monster_chain_head)
        monster_chain_head = removing.monster_chain_next;

    if (removing.monster_chain_next)
        removing.monster_chain_next.monster_chain_prev = removing.monster_chain_prev;
    if (removing.monster_chain_prev)
        removing.monster_chain_prev.monster_chain_next = removing.monster_chain_next;

    removing.monster_chain_next = world;
    removing.monster_chain_prev = world;

    if (linked && monster_chain_count > 0)
        monster_chain_count = monster_chain_count - 1;
};

// ---------------------------------------------------------------------------
//  Chain integrity sweep  —  the backstop that keeps a missed teardown from
//  being a server-killing infinite loop
// ---------------------------------------------------------------------------
// WHY THIS EXISTS RATHER THAN JUST FIXING THE REMOVAL SITES.  There are about
// twenty-five separate `while (e) { ... e = e.monster_chain_next; }` walks across
// server/, and not one of them is bounded by anything except the list itself. A
// single removal path that frees a linked monster therefore turns EVERY one of
// them into a non-terminating loop - which is exactly what happened: one missing
// teardown in SUB_KillTargets (server/sv_triggers.qc) produced two crashes that
// looked entirely unrelated, one in Script_FindMonster and one in AI_FindEnemy,
// minutes apart. Fixing that site was necessary; it is not sufficient, because
// the next site added will do it again and the failure mode is a dead server.
//
// THE TIMING IS WHAT MAKES THIS WORK. FTE's ED_Free does not clear fields
// (engine/qclib/pr_edict.c:198-209 is commented out), so a freed-but-not-yet-
// recycled edict still answers wasfreed() TRUE while its links are intact and
// readable. ED_Alloc will not re-issue that slot for 0.5 s (:129-136). Sweeping
// at 4 Hz therefore repairs the list inside that window, BEFORE the slot can come
// back as a new monster and close the loop - so the cycle never forms at all and
// the crash becomes a log line.
//
// The cap is the second half, and it is what makes the sweep safe to run against
// a list that is ALREADY circular (an older save, or a hole this misses): without
// it, the repair pass would be the twenty-sixth unbounded walk.
//
// Deliberately NOT gated on developer/sv_ai_debug: the repair has to happen on a
// production server too. Only the reporting is gated.
void() Monster_Chain_Verify =
{
    if (time < monster_chain_next_verify)
        return;
    monster_chain_next_verify = time + 0.25;

    float cap = monster_chain_count + 8;
    if (cap < 16)
        cap = 16;

    float  n    = 0;
    entity prev = world;
    entity e    = monster_chain_head;

    while (e)
    {
        if (n >= cap)
        {
            // More nodes than were ever added: the list loops. Cut it here. The
            // tail past the cut is lost, which is survivable and self-correcting
            // (those monsters simply stop being found until they respawn); an
            // infinite loop is not.
            if (prev)
                prev.monster_chain_next = world;
            else
                monster_chain_head = world;
            monster_chain_count = n;
            mchain_dbg_cycles   = mchain_dbg_cycles + 1;
            dprint(sprintf("[monster] CHAIN CYCLE detected after %g nodes (cap %g) - broken. "
                           "Some removal path is freeing a linked monster without Monster_Teardown.\n",
                           n, cap));
            return;
        }

        // Stash the successor BEFORE any unlink: monster_chain_remove clears both
        // of e's links on the way out.
        entity nxt = e.monster_chain_next;

        if (wasfreed(e))
        {
            monster_chain_remove(e);
            mchain_dbg_freed = mchain_dbg_freed + 1;
            // NOT debug-gated, and that is deliberate.  SUB_KillTargets was the
            // one hole findable by reading, and it is fixed - but a scan of all
            // 275 maps on this install (108 Sven, 20 of them They Hunger, plus the
            // vanilla and addon sets) finds ZERO placements where a killtarget
            // names a monster, so it cannot be the hole that produced the crashes
            // actually reported.  Something else frees a linked monster, and this
            // line is how we find out what: it fires once per leak, names nothing
            // yet, but its presence in a log narrows the window to the seconds
            // around it.  Remove the gate only once it has stopped appearing.
            dprint(sprintf("[monster] chain: unlinked a FREED edict (classname was \"%s\") - "
                           "some removal path skipped Monster_Teardown\n", e.classname));
            // prev deliberately not advanced - e is gone, so the node before it is
            // still the predecessor of whatever comes next.
        }
        else
        {
            prev = e;
            n    = n + 1;
        }

        e = nxt;
    }

    // Resync. The count can only drift if something wrote the links outside these
    // functions, which nothing does - but the walk has just established the truth
    // for free, so take it.
    monster_chain_count = n;
};

// Give a squadmaker back the slot this child occupies.
//
// sq_live_children was incremented on spawn and NEVER decremented.  That is inert
// today only because the cap below is gated on the AI seam; flip the seam without
// this and every squadmaker in every map pins at its cap forever and stops firing
// its target chain - which is a progression stall across 5161 spawners on 76 maps.
// The two changes are bound together deliberately: do not flip the seam without
// this function being called.
//
// The sq_counted latch makes a double release (death handler + removal) idempotent.
void(entity m) Monster_ReleaseSquadSlot =
{
    if (m.sq_counted != 1)
        return;
    m.sq_counted = 0;

    if (!m.sq_maker)
        return;
    m.sq_maker.sq_live_children = m.sq_maker.sq_live_children - 1;
    if (m.sq_maker.sq_live_children < 0)
        m.sq_maker.sq_live_children = 0;
};

// Single teardown point: whatever kills or removes a monster comes through here so
// the chain and the squad count can never disagree with reality.
void(entity m) Monster_Teardown =
{
    // Two entirely different "squads" meet on these two lines, which is worth
    // saying once: Monster_ReleaseSquadSlot hands back a slot in the SPAWNER's
    // child budget (squadmaker's sq_live_children), while Squad_Remove takes the
    // body out of the Half-Life SQUAD it fights in.  Neither is the other, both
    // are idempotent, and both have to happen here so a corpse left lying around
    // starves neither its spawner nor its squadmates' attack slots.
    Monster_ReleaseSquadSlot(m);
    Squad_Remove(m);
    // Single teardown point for both death and removal, so it is the one place a
    // path slot can be handed back without risking a double release.
    Nav_PathSlot_Release(m);
    monster_chain_remove(m);
};

// Death handler, installed on .on_killed for AI-enabled classes only.  Dispatched
// from W_ApplyDamage (sv_weapons.qc:1824) with `self` bound to the corpse.
//
// The body deliberately stays in the world - HL leaves corpses, and B2/B3 will add
// the death animation here.  But the slot and the chain link must be released the
// instant it dies, not whenever the body is eventually removed, or a map that
// leaves corpses lying around would starve its own squadmaker.  Monster_Teardown
// is idempotent, so a later remove() can call it again safely.
void() Monster_Killed =
{
    // trigger_condition 4 = Death (sven-coop.fgd:5467), and this is where it
    // belongs.  squadmaker used to fire trigger_target on SPAWN, which on this
    // map's wave counters meant the count arrived one kill early per maker and
    // the shop sequence completed while its stray dogs were still alive.  Fired
    // before the teardown so .sq_maker is still wired up.
    //
    // A throwaway relay rather than firing off the maker, for the reason the spawn
    // path already documents: SUB_UseTargets defers by the caller's .delay, and a
    // squadmaker's delay is its BETWEEN-SPAWNS interval, not a chain delay.
    if (self.sq_maker && self.sq_maker.trigger_condition == SQ_COND_DEATH
        && self.sq_maker.trigger_target != "")
    {
        entity relay = spawn();
        relay.classname = "sq_fire";
        relay.target    = self.sq_maker.trigger_target;
        SUB_UseTargets(relay, self, USE_TOGGLE);
        remove(relay);
    }

    Monster_Teardown(self);
    // Non-AI monsters only.  AI_Died below deliberately puts it BACK to
    // DAMAGE_YES for anything with a brain, because Half-Life leaves a corpse
    // shootable (combat.cpp:520) - that is what lets a body bleed and gib.  A
    // class with no AI has no corpse handling, so it keeps the old behaviour.
    self.takedamage = DAMAGE_NO;

    // Hand the body to the AI layer, which plays the death animation, drops the
    // corpse's solidity and stops it thinking once the sequence is done.  Called
    // after the teardown so the squad slot is already back regardless of how
    // long the death animation runs.
    if (Monster_ClassHasAI(self.classname))
        AI_Died(self);
};

// ---------------------------------------------------------------------------
//  Builtin probe  —  `sv_monster_probe 1`, prints once at worldspawn
// ---------------------------------------------------------------------------
// The entire animation design assumes SSQC can read Half-Life .mdl sequence data:
// activity lookup, sequence duration, and per-frame events. Those builtins are
// registered for SSQC in the engine (pr_cmds.c:11736-11741, :11824), but "declared
// and registered" is not "returns real data for an HL model on the server", and a
// negative answer changes the design rather than just a line of code. Measure it.
//
// Deliberately prints raw numbers rather than pass/fail on the activity IDs: the
// ACT_* enum is Half-Life's own activity.h, and a Sven-custom model may not carry
// the activity we ask for. -1 from frameforaction means "this model has no sequence
// tagged with that activity", which is a legitimate answer, not a broken builtin.
// What proves the pipe works is frameforname resolving a named sequence and
// getmodeleventidx returning a real timestamp/code.
const float PROBE_ACT_WALK           = 3;
const float PROBE_ACT_RUN            = 4;
const float PROBE_ACT_MELEE_ATTACK1  = 30;
const float PROBE_ACT_RANGE_ATTACK1  = 28;

void(string mdl) Monster_ProbeModel =
{
    float mi = getmodelindex(mdl);
    if (mi <= 0)
    {
        dprint(sprintf("[probe] %s: NOT FOUND (getmodelindex=%g)\n", mdl, mi));
        return;
    }

    // modelframecount is the ONLY valid range check on an HL model.  frameduration
    // cannot do it: HLMDL_FrameInfoForNum (gl/gl_hlmdl.c:1395) silently clamps an
    // out-of-range sequence to 0 and returns a plausible duration for it.  This call
    // also forces the lazy, BLOCKING model load (SVPR_GetCModel, pr_cmds.c:590) to
    // happen here at map load rather than mid-wave.
    float nseq = modelframecount(mi);

    dprint(sprintf("[probe] %s idx=%g sequences=%g\n", mdl, mi, nseq));

    dprint(sprintf("[probe]   frameforaction WALK=%g RUN=%g MELEE1=%g RANGE1=%g  (-1 = model has no such activity)\n",
                   frameforaction(mi, (int)PROBE_ACT_WALK),
                   frameforaction(mi, (int)PROBE_ACT_RUN),
                   frameforaction(mi, (int)PROBE_ACT_MELEE_ATTACK1),
                   frameforaction(mi, (int)PROBE_ACT_RANGE_ATTACK1)));

    // frameforname returns -1 on a miss, so it doubles as a name probe.
    float s_idle = frameforname(mi, "idle1");
    float s_walk = frameforname(mi, "walk");
    dprint(sprintf("[probe]   frameforname idle1=%g walk=%g\n", s_idle, s_walk));

    // Duration of a sequence we know exists, range-checked properly first.
    float probeseq = s_idle;
    if (probeseq < 0)
        probeseq = 0;
    if (probeseq < nseq)
        dprint(sprintf("[probe]   frameduration(seq %g)=%g\n", probeseq, frameduration(mi, probeseq)));

    // Walk the events.  getmodeleventidx rather than getnextmodelevent, because the
    // latter reports only the FIRST event at any given timestamp and HL co-times
    // footstep+sound constantly.
    //
    // Probe the ATTACK sequence, not idle: HL hangs almost every event off attacks
    // and deaths, so an eventless idle proves nothing about whether event data
    // survives the trip to SSQC - and that data is what lands melee damage on the
    // right frame.
    float atkseq = frameforaction(mi, (int)PROBE_ACT_MELEE_ATTACK1);
    if (atkseq < 0)
        atkseq = frameforaction(mi, (int)PROBE_ACT_RANGE_ATTACK1);

    float seqlist[2];
    seqlist[0] = probeseq;
    seqlist[1] = atkseq;

    float si = 0;
    while (si < 2)
    {
        float sq = seqlist[si];
        si = si + 1;
        if (sq < 0)
            continue;
        if (sq >= nseq)
            continue;

        float evi = 0;
        float ts; int code; string edata;
        float found = 0;
        while (evi < 12)
        {
            if (!getmodeleventidx(mi, sq, (int)evi, ts, code, edata))
                break;
            dprint(sprintf("[probe]   seq %g event[%g] t=%g code=%i data=\"%s\"\n",
                           sq, evi, ts, code, edata));
            found = found + 1;
            evi = evi + 1;
        }
        if (!found)
            dprint(sprintf("[probe]   seq %g: no events\n", sq));
    }
};

void() Monster_BuiltinProbe =
{
    if (!cvar("sv_monster_probe"))
        return;
    dprint("[probe] ---- HL .mdl sequence data, server side ----\n");
    Monster_ProbeModel("models/zombie.mdl");
    Monster_ProbeModel("models/headcrab.mdl");
    dprint("[probe] ---- end ----\n");
};

// ---------------------------------------------------------------------------
//  THE SEAM
// ---------------------------------------------------------------------------
// Returns TRUE once this build can actually drive an NPC.  Everything that
// would behave differently with AI present branches on this rather than
// hardcoding the AI-less assumption, so turning AI on is a one-line change
// here plus the behaviour itself.
// nettest: per-CLASS, not global.
//
// A single global flip would hand AI to every monster_* classname at once,
// including monster_furniture and monster_generic - which are scenery. They would
// become killable, start thinking, and (worse) start counting against squadmaker
// concurrency caps, stalling maps that never intended a live NPC. Classes opt in
// one at a time as they are actually implemented, so each addition is testable on
// its own and a broken class cannot take the rest of the corpus with it.
//
// The list itself lives in AI_ClassHasAI (sv_ai_core.qc), next to the class
// registry it has to stay in step with: a class named here but with no entry in
// AI_ClassInit would be built as a thinking monster with no behaviour at all.
// This stays as the seam every non-AI caller asks through.
float(string cls) Monster_ClassHasAI =
{
    if (cls == "")
        return FALSE;
    return AI_ClassHasAI(cls);
};

// Convenience wrapper for the common "does SELF have AI" question.
float() Monster_HasAI =
{
    return Monster_ClassHasAI(self.classname);
};

// Turn `self` — an entity already carrying the map's keys — into a monster
// body.  `want_solid` lets the caller distinguish "the mapper placed this and
// expects to bump into it" (furniture) from "we invented this as a stand-in"
// (squadmaker children, which must not wall a corridor off forever given they
// will never walk out of it).
// Class -> default world model.  In GoldSrc the model is baked into the C++
// class, not the entdata, so a monster with no `model` key has nothing to show
// and Monster_Build below would blank it entirely.
//
// Measured corpus-wide (all 108 Sven maps): 64.4% of placed monsters carry no
// `model` key at all, and for whole classes it is 100% — every one of the 29
// monster_hevsuit_dead omits it, and only 47 of 179 monster_scientist_dead
// supply one.  An earlier version of this comment claimed the problem was
// confined to five ichthyosaurs; that was true of the three-map sample it was
// written against and false everywhere else.
//
// Every path below verified present in svencoop/models/.
// Does this model file actually exist in the mounted content?
//
// This matters far more here than it looks.  The HL models arrive from a MOUNTED
// STEAM INSTALL (the search path shows "steam:Half-Life/valve"), and only valve
// is mounted - gearbox is NOT.  So every Opposing Force model is absent, and a
// class pointing at one spawns an invisible monster with no error anywhere.
//
// whichpack() answers without precaching, so probing a missing file costs neither
// a precache slot nor a console warning.
float(string mdl) Monster_ModelExists =
{
    if (mdl == "" || !mdl)
        return FALSE;
    string p = whichpack(mdl);
    return (p != "" && p);
};

// The same question for a sound.  Sound paths are written WITHOUT the "sound/"
// prefix everywhere in QC - precache_sound and sound() both add it - so the
// filesystem query has to add it back, which is exactly the sort of asymmetry
// that gets a class precaching files it will never find.
float(string snd) Monster_SoundExists =
{
    if (snd == "" || !snd)
        return FALSE;
    string p = whichpack(strcat("sound/", snd));
    return (p != "" && p);
};

// First of two that exists, else the first (so the caller still gets a name to
// report rather than an empty string that reads as "no model wanted").
string(string first, string fallback) Monster_PickModel =
{
    if (Monster_ModelExists(first))
        return first;
    if (Monster_ModelExists(fallback))
        return fallback;
    return first;
};

string(string cls) Monster_DefaultModel =
{
    if (cls == "monster_ichthyosaur")     return "models/icky.mdl";
    if (cls == "monster_headcrab")        return "models/headcrab.mdl";
    if (cls == "monster_scientist")       return "models/scientist.mdl";
    if (cls == "monster_leech")           return "models/leech.mdl";
    if (cls == "monster_human_assassin")  return "models/hassassin.mdl";
    // massn.mdl is the stock model, but it lives in GEARBOX, which this install
    // does not mount - so the earlier "fix" from male_assassin.mdl to massn.mdl
    // swapped one missing file for another and 419 placements stayed invisible.
    // Resolve at runtime instead: use massn if a map or Sven content supplies it,
    // otherwise fall back to the valve assassin, which always exists.
    if (cls == "monster_male_assassin")
        return Monster_PickModel("models/massn.mdl", "models/hassassin.mdl");
    // Same story: otis.mdl is gearbox-only.  Barney is the same rig and reads as
    // a security guard, which is what otis is.
    if (cls == "monster_otis")
        return Monster_PickModel("models/otis.mdl", "models/barney.mdl");
    if (cls == "monster_zombie")          return "models/zombie.mdl";
    if (cls == "monster_houndeye")        return "models/houndeye.mdl";
    if (cls == "monster_alien_slave")     return "models/islave.mdl";
    if (cls == "monster_barnacle")        return "models/barnacle.mdl";
    if (cls == "monster_gargantua")       return "models/garg.mdl";
    if (cls == "monster_bigmomma")        return "models/big_mom.mdl";
    // blkop_* are the Opposing Force variants; both fall back to the valve
    // model, which is why the gearbox mount is worth having.
    if (cls == "monster_apache")
        return Monster_PickModel("models/apache.mdl", "models/blkop_apache.mdl");
    if (cls == "monster_osprey")
        return Monster_PickModel("models/osprey.mdl", "models/blkop_osprey.mdl");
    if (cls == "monster_stukabat")        return "models/stukabat.mdl";
    if (cls == "monster_kingpin")         return "models/kingpin.mdl";
    // ---- They Hunger's two finale bosses (th_ep3_07, one placement each) ----
    // Neither is a new creature.  monster_th_boss.as is Half-Life's CApache
    // wearing a different model - it keeps the apache's rotor loop, its
    // HuntThink/FlyTouch/DyingThink/CrashTouch state machine and its
    // m_posDesired/m_vecDesired steering, member name for member name.  So it
    // is registered as the apache archetype with this model, which is the same
    // arrangement the whole campaign already uses (monster_zombie wearing
    // hungerhound.mdl IS the dog).
    if (cls == "monster_th_boss")         return "models/hunger/boss.mdl";
    // ...and monster_th_cyberfranklin.as is CHGrunt: its animation-event codes
    // are the hgrunt's verbatim (RELOAD 2, KICK 3, BURST1..3 4-6, GREN_TOSS 7,
    // GREN_LAUNCH 8, GREN_DROP 9, CAUGHT_ENEMY 10, DROP_GUN 11).
    if (cls == "monster_th_cyberfranklin") return "models/hunger/franklin2.mdl";
    if (cls == "monster_babygarg")
        return Monster_PickModel("models/babygarg.mdl", "models/garg.mdl");
    if (cls == "monster_alien_controller") return "models/controller.mdl";
    if (cls == "monster_sentry")          return "models/sentry.mdl";
    if (cls == "monster_miniturret")      return "models/miniturret.mdl";
    if (cls == "monster_turret")          return "models/turret.mdl";
    if (cls == "monster_alien_grunt")     return "models/agrunt.mdl";
    if (cls == "monster_bullchicken")     return "models/bullsquid.mdl";
    if (cls == "monster_pitdrone")
        return Monster_PickModel("models/pit_drone.mdl", "models/bullsquid.mdl");
    if (cls == "monster_gonome")
        return Monster_PickModel("models/gonome.mdl", "models/zombie.mdl");
    if (cls == "monster_alien_voltigore")
        return Monster_PickModel("models/voltigore.mdl", "models/agrunt.mdl");
    // Sven's own juvenile voltigore.  The classname appeared nowhere in this mod,
    // so the three spawners that use it on pizza_ya_san1 produced nothing at all
    // while still feeding their counter - and the model is right there in
    // svencoop/models under an underscored name the classname does not hint at.
    if (cls == "monster_alien_babyvoltigore")
        return Monster_PickModel("models/baby_voltigore.mdl", "models/voltigore.mdl");

    // --- W3: the gun shooters ---
    // Every fallback below resolves at runtime through Monster_PickModel, because
    // most of this family's stock models live in GEARBOX or in Sven's own content
    // and neither is mounted here.  A map that ships its own model overrides all
    // of this anyway; what matters is that the class is never left invisible.
    if (cls == "monster_human_grunt")     return "models/hgrunt.mdl";
    if (cls == "monster_th_grunt_repel")  return "models/hgrunt.mdl";
    if (cls == "monster_human_assassin")  return "models/hassassin.mdl";
    if (cls == "monster_barney")          return "models/barney.mdl";
    if (cls == "monster_human_grunt_ally")
        return Monster_PickModel("models/hgrunt_opfor.mdl", "models/hgrunt.mdl");
    if (cls == "monster_hwgrunt")
        return Monster_PickModel("models/hwgrunt.mdl", "models/hgrunt.mdl");
    if (cls == "monster_robogrunt")
        return Monster_PickModel("models/robogrunt.mdl", "models/hgrunt.mdl");
    // "strooper.mdl", not "shocktrooper.mdl" - the real filename, checked against
    // both gearbox and svencoop rather than inferred from the classname.
    if (cls == "monster_shocktrooper")
        return Monster_PickModel("models/strooper.mdl", "models/hgrunt.mdl");
    if (cls == "monster_human_torch_ally")
        return Monster_PickModel("models/hgrunt_torch.mdl", "models/hgrunt.mdl");
    if (cls == "monster_human_medic_ally")
        return Monster_PickModel("models/hgrunt_medic.mdl", "models/barney.mdl");
    // "bgman.mdl", NOT "bodyguard.mdl", and the difference is the whole bug.
    // sven-coop.fgd:4005 declares the class as
    //     @PointClass base(Monster) ... studio("models/bgman.mdl") = monster_bodyguard
    // and there is no bodyguard.mdl anywhere in the Sven mount - the only files of
    // that name are PLAYER models under svencoop_downloads/models/player/, which
    // this never had a route to.  So the primary always missed and every bodyguard
    // in the corpus silently fell through to Barney.
    //
    // th_ep1_01 is where that shows: the church's `jp_telein` func_button drives a
    // squadmaker whose monstertype is monster_bodyguard and whose displayname is
    // JPolito, so pressing the button produced a Barney with someone else's name
    // over his head.
    if (cls == "monster_bodyguard")
        return Monster_PickModel("models/bgman.mdl", "models/barney.mdl");

    // --- W2 additions ---
    if (cls == "monster_zombie_barney")   return "models/zombie_barney.mdl";
    if (cls == "monster_zombie_soldier")  return "models/zombie_soldier.mdl";
    if (cls == "monster_cockroach")       return "models/roach.mdl";
    if (cls == "monster_gman")            return "models/gman.mdl";
    if (cls == "monster_scientist_dead")  return "models/scientist.mdl";
    if (cls == "monster_sitting_scientist") return "models/scientist.mdl";
    if (cls == "monster_barney_dead")     return "models/barney.mdl";
    if (cls == "monster_hgrunt_dead")     return "models/hgrunt.mdl";
    // HL's dead HEV suit is the PLAYER model — sequences 177..180 are its
    // corpse poses.  Not one of the 29 placements carries a model key, so this
    // default is the only thing that makes them visible at all.
    if (cls == "monster_hevsuit_dead")    return "models/player.mdl";
    return "";
};

// ---------------------------------------------------------------------------
// class hulls
// ---------------------------------------------------------------------------
// Half-Life sizes a monster from its CLASS, not from its model.  SET_MODEL only
// applies the studio header's bbox, and that is "0 0 0" for almost every HL
// monster model; each monster's Spawn() then calls UTIL_SetSize with a hull the
// C++ code picks.  monster_furniture never calls it, which is exactly why HL trees
// and scenery have no collision.
//
// Our engine fork cannot reproduce that by accident: it derives model bounds from
// GEOMETRY (gl_hlmdl.c, added so physics props get a usable hull), so a monster
// with no hull of its own inherits its idle animation's bounding box.  Measured,
// that is 500 x 468 x 622 for models/hunger/vegitation/arc_xer_tree1.mdl, and for
// zombie.mdl it is a 56-wide box running from -16 to +40 on X - not centred on the
// origin, so the collision sits about 12 units in front of where the model looks.
//
// Sizes below are Half-Life's own (VEC_HUMAN_HULL_MIN/MAX and the per-class
// UTIL_SetSize calls).  Monster origins are at the FEET in GoldSrc, hence mins_z 0.
vector monster_hull_min, monster_hull_max;

float(string cls) Monster_ClassHull =
{
    monster_hull_min = '-16 -16 0';
    monster_hull_max = '16 16 72';          // VEC_HUMAN_HULL_MIN/MAX

    if (cls == "monster_headcrab" || cls == "monster_babycrab")
        { monster_hull_min = '-12 -12 0'; monster_hull_max = '12 12 24'; return TRUE; }
    if (cls == "monster_cockroach")
        { monster_hull_min = '-1 -1 0';   monster_hull_max = '1 1 1';    return TRUE; }
    if (cls == "monster_leech")
        { monster_hull_min = '-8 -8 0';   monster_hull_max = '8 8 8';    return TRUE; }
    if (cls == "monster_houndeye")
        { monster_hull_min = '-16 -16 0'; monster_hull_max = '16 16 36'; return TRUE; }
    if (cls == "monster_ichthyosaur")
        { monster_hull_min = '-32 -32 -32'; monster_hull_max = '32 32 32'; return TRUE; }
    if (cls == "monster_barnacle")
        { monster_hull_min = '-16 -16 -32'; monster_hull_max = '16 16 0'; return TRUE; }
    // THE TURRETS, and their absence here is not cosmetic.  Half-Life sizes them
    // symmetrically about the mount point - turret.cpp:308 and :340 both use
    // (-x,-x,-m_iRetractHeight) .. (x,x,+m_iRetractHeight) with m_iRetractHeight
    // 16 - because a turret hangs from a ceiling as often as it stands on a floor,
    // and a hull that only extends UPWARDS puts a ceiling mount inside the brush
    // it is bolted to.  pizza_ya_san1 has four of them and every one is a ceiling
    // mount, so with the human hull all four fail placement and the shop's whole
    // security system never appears.  The sentry stands, so it keeps HL's own
    // (turret.cpp:1180 is the miniturret; the sentry inherits the base spawn).
    if (cls == "monster_turret")
        { monster_hull_min = '-32 -32 -16'; monster_hull_max = '32 32 16'; return TRUE; }
    if (cls == "monster_miniturret" || cls == "monster_sentry")
        { monster_hull_min = '-16 -16 -16'; monster_hull_max = '16 16 16'; return TRUE; }
    // The gargantua is not human-sized, and this table's header comment claimed
    // otherwise for it.  gargantua.cpp:752 is UTIL_SetSize(-32,-32,0)..(32,32,64):
    // twice as wide as a man and slightly SHORTER, which is not what you would
    // guess from looking at one - HL draws it far bigger than it collides
    // (SetObjectCollisionBox at :214-218 is 160x160x214, for rendering and PVS only).
    //
    // Landed together with the flame-attachment work in mon_bigfoes.qc and not
    // before it: while the emitters were synthesised from hull height, correcting
    // the hull ALONE would have moved them from 47.5 to 42.2 where the model's real
    // hands are at 86, i.e. strictly further from right.
    if (cls == "monster_gargantua" || cls == "monster_babygarg")
        { monster_hull_min = '-32 -32 0'; monster_hull_max = '32 32 64'; return TRUE; }

    // Everything else that walks is human-sized.  Returning TRUE for the default is
    // deliberate: an unknown monster with a human hull is far safer than one
    // wearing whatever box its animation happened to sweep out.
    return TRUE;
};

// ===========================================================================
//  SetObjectCollisionBox — the OTHER box a Half-Life monster has
// ===========================================================================
//
// The hull above is what a monster MOVES with.  It is not what a shot is culled
// against, and conflating the two is why a voltigore reads as having "awful
// hitboxes".  Half-Life keeps them separate: CBaseEntity::SetObjectCollisionBox
// normally derives absmin/absmax from mins/maxs (cbase.cpp:628-666), but the big
// monsters override it and write an absmin/absmax far larger than their hull:
//
//     gargantua.cpp:214   -80,-80,0    ..  80, 80,214   (hull 32x32x64)
//     bigmomma.cpp:282    -95,-95,0    ..  95, 95,190   (hull 32x32x64)
//     agrunt.cpp:80       -32,-32,0    ..  32, 32, 85   (hull 32x32x64)
//     apache.cpp:43      -300,-300,-172.. 300,300,  8
//
// That box is NOT cosmetic.  absmin/absmax is the volume World_ClipToLinks tests
// before it will consider an entity for a trace at all (world.c:1918-1924), and
// it bails out there BEFORE the per-bone MOVE_HITMODEL test ever runs.  FTE's own
// builtin doc spells it out: "The bounding box MUST be set to completely encompass
// the entity or those extra areas will be non-solid, leaving a hole for things to
// go through" (pr_cmds.c:13833).  So a monster drawn 190 units long inside a
// 32x32x72 cull box is, to a hitscan trace, mostly not there.
//
// QC cannot write absmin/absmax directly — the engine recomputes them in
// SV_LinkEdict on every setsize/setorigin — so this is done the way the mod
// already does it for players: swap the bbox out for the render box immediately
// before a weapon trace and swap it straight back after (see
// W_MonstersExpandHitboxes below and W_PlayersExpandHitboxes in sv_weapons.qc).
// MOVEMENT IS COMPLETELY UNAFFECTED — the pair brackets the trace only, and the
// real hit decision is still per-bone, so a bigger box can only ever add
// forgiveness, never invent a hit in empty air.
//
// Only classes that genuinely need one are listed.  Returning FALSE for the rest
// keeps the per-shot walk down to a handful of entities on a busy map.
vector monster_render_min, monster_render_max;

float(string cls) Monster_ClassRenderBox =
{
    if (cls == "monster_gargantua" || cls == "monster_babygarg")
        { monster_render_min = '-80 -80 0'; monster_render_max = '80 80 214'; return TRUE; }
    if (cls == "monster_bigmomma")
        { monster_render_min = '-95 -95 0'; monster_render_max = '95 95 190'; return TRUE; }
    if (cls == "monster_alien_grunt")
        { monster_render_min = '-32 -32 0'; monster_render_max = '32 32 85'; return TRUE; }
    if (cls == "monster_apache")
        { monster_render_min = '-300 -300 -172'; monster_render_max = '300 300 8'; return TRUE; }
    // The two Gearbox classes the playtest report names.  No Opposing Force
    // source exists on disk (halflife/dlls has no voltigore.cpp), so these come
    // from Sven's own fgd — sven-coop.fgd:3864 size(-80 -80 0, 80 80 90) and
    // :3815 size(-40 -40 0, 40 40 64) — which is exactly the right KIND of number
    // for this box even where the fgd is a poor guide to a movement hull.  The
    // measurement backs it: voltigore.mdl's idle pose sweeps 192 x 127 x 98 with
    // its eyes at z=95, against the 32x32x72 human default it was falling through
    // to.  baby_voltigore.mdl's idle is 64 x 42 x 33, eyes at 30.
    if (cls == "monster_alien_voltigore")
        { monster_render_min = '-80 -80 0'; monster_render_max = '80 80 90'; return TRUE; }
    if (cls == "monster_alien_babyvoltigore")
        { monster_render_min = '-40 -40 0'; monster_render_max = '40 40 64'; return TRUE; }
    // THE TWO THIS TABLE WAS MISSING, and they are the two worst cases in the game.
    // Grepping SetObjectCollisionBox across dlls/*.cpp returns exactly seven monsters
    // that override it — agrunt, apache, bigmomma, gargantua, leech, nihilanth,
    // tentacle.  Five were here.  leech does not belong (its override SHRINKS the box,
    // to 16x16x2, and ours is already bigger).  The other two were simply absent, and
    // both are bosses whose hull is a 32x32x64 stump at the base of something enormous:
    //
    //     tentacle.cpp:54    -400,-400,0  ..  400,400,850   (hull 32x32x64)
    //     nihilanth.cpp:44   -16,-16,-48  ..   16, 16, 28, all x N_SCALE 15
    //                      = -240,-240,-720 ..  240,240,420 (hull 32x32x64)
    //
    // Without an entry, World_ClipToLinks rejects the entity before the per-bone test
    // for any shot that does not pass through that stump — so 786 of the tentacle's 850
    // units were not there to a bullet.  mon_tentacle.qc:96-98 already identified the
    // absmin/absmax half of this and declined to fix it, on the grounds that "a setsize
    // to the full 800x800x850 would make the tentacle a solid block players cannot walk
    // under".  That is correct about setsize and irrelevant here: the expand/restore
    // pair brackets the TRACE only (W_MonstersExpandHitboxes), the box is back before
    // the next movement runs, and touch/pmove never observe it.  HL reaches the same
    // place by a different route — its box is permanent, but SOLID_SLIDEBOX collision
    // uses pev->size, not absmin/absmax, so it is equally not a wall there.
    if (cls == "monster_tentacle")
        { monster_render_min = '-400 -400 0'; monster_render_max = '400 400 850'; return TRUE; }
    if (cls == "monster_nihilanth")
        { monster_render_min = '-240 -240 -720'; monster_render_max = '240 240 420'; return TRUE; }
    // monster_th_boss is registered as the CApache archetype (sv_ai_core.qc:3635) but
    // this table dispatches on CLASSNAME, so the alias was picking up nothing at all
    // while monster_apache got the box.  Same aircraft, same numbers.
    if (cls == "monster_th_boss")
        { monster_render_min = '-300 -300 -172'; monster_render_max = '300 300 8'; return TRUE; }
    // NOT an SetObjectCollisionBox case: COsprey never overrides it.  It does not need
    // to, because in HL the osprey's own UTIL_SetSize IS 800x800x132 (osprey.cpp:153)
    // and the derived absmin/absmax follows it.  Here the class hull is the 32x32x72
    // human default, so the effect is identical to a missing SOCB and the fix belongs
    // in the same table: an aircraft 1235 units wingtip-to-wingtip was traceable
    // across 32.
    if (cls == "monster_osprey")
        { monster_render_min = '-400 -400 -100'; monster_render_max = '400 400 32'; return TRUE; }
    // Measured, not ported.  ichthyosaur.mdl's animated extent is 264 units long
    // against a 64-unit cube hull; barnacle.mdl is the one model in the corpus that
    // declares its own clipping box, and declares it as (-16,-16,-1024)..(16,16,0) —
    // the tongue.  The barnacle's hull hangs BELOW its mount (-32..0), so the +Z here
    // is the body it is bolted to and the -Z is the tongue's reach.
    if (cls == "monster_ichthyosaur")
        { monster_render_min = '-64 -64 -64'; monster_render_max = '64 64 64'; return TRUE; }
    // WIDENED FROM +-24 FOR SVEN CO-OP'S BARNACLE.  Measured bind-pose vertex
    // extents, which is what this box has to contain:
    //   valve/barnacle.mdl   x -23.62..23.03  y -19.10..19.10   <- fits +-24 exactly
    //   svencoop/barnacle.mdl x -28.72..29.61  y -24.72..25.54  <- overflows it
    // Sven Co-op is the master mount now (see the note at the top of
    // quakers/fs_addons.txt), so the second one is the model that loads, and at
    // +-24 the outer ~6 units of it were rejected by World_ClipToLinks before the
    // per-bone hitbox test ever ran - a barnacle you could shoot through at the
    // edges.  32 is the same number sv_hitbox_expand defaults to and leaves
    // margin for the animated sway; the -1024 tongue reach is unchanged.
    // It is the ONLY one of the thirteen render-box classes that grew: garg,
    // big_mom, agrunt, apache, voltigore, baby_voltigore, tentacle2, nihilanth,
    // osprey and icky all measured within 2% of their Half-Life originals.
    if (cls == "monster_barnacle")
        { monster_render_min = '-32 -32 -1024'; monster_render_max = '32 32 24'; return TRUE; }
    return FALSE;
};

// Saved bbox for the bracket below.  Absolute, not delta math: unlike the player
// pair this cannot reconstruct the original from a cvar, and a map-supplied
// minhullsize/maxhullsize (Monster_Build :1207) means the class table is not
// always the right thing to restore to either.
.vector mon_cull_save_min, mon_cull_save_max;
.float  mon_cull_inflated;

// THE SOCB SIDE-CHAIN.  Three classes build themselves with setmodel/setsize and
// never call Monster_Build — monster_tentacle (mon_tentacle.qc:882),
// monster_nihilanth (mon_nihilanth.qc:1273) and the boids (mon_flock.qc) — so they
// are not on monster_chain, and a Monster_ClassRenderBox row for them would be dead
// code: the walk below would never reach them.  Putting them ON monster_chain is not
// the answer either; ~25 AI functions walk it (AI_FindEnemy, the gib sweeps, talk,
// factions) and none of them has ever seen a tentacle.
//
// So they get their own list, which nothing else walks.  A fixed array rather than a
// linked chain because these are singletons-to-a-handful and an array cannot be
// corrupted by a removal: liveness is re-checked by classname at use time, and FTE's
// ED_Alloc zeroes a recycled slot (qclib/pr_edict.c:85), so a stale entry either
// still IS the thing it was or fails the classname test.
const float MON_SOCB_EXTRA_MAX = 8;
entity mon_socb_extra[MON_SOCB_EXTRA_MAX];
float  mon_socb_extra_n;

void(entity e) Monster_SOCBRegister =
{
    if (mon_socb_extra_n >= MON_SOCB_EXTRA_MAX)
        return;
    float i = 0;
    while (i < mon_socb_extra_n)         // idempotent — respawn/re-init must not double-add
    {
        if (mon_socb_extra[i] == e)
            return;
        i = i + 1;
    }
    mon_socb_extra[mon_socb_extra_n] = e;
    mon_socb_extra_n = mon_socb_extra_n + 1;
};

// How far from the shooter a monster still has to be considered.  Nothing in the mod
// traces further, and the gate is what keeps the per-shot cost bounded on a map like
// pizza_ya_san1 (419 placed assassins): a vlen is free next to a setsize, which is a
// full SV_LinkEdict.
const float MON_CULL_MAX_DIST = 4096;

// ...and the tighter gate on top of it.  Bracketing W_WeaponTraceLine put this walk
// on a PER-TRACE footing rather than a per-shot one, and a shotgun is eight traces:
// on a map like pizza_ya_san1 (419 placed assassins) the naive form is 8 x 419 x 2
// SV_LinkEdicts per blast.  So a caller that knows its trace segment publishes it
// here, and the walk skips any monster whose inflated box could not possibly meet it.
// Six float compares against a full setsize is not a close call.
//
// Callers that do NOT publish a segment (the three pre-existing hitscan sites) leave
// mon_cull_seg_valid at 0 and get the old unconditional behaviour, so this cannot
// change what they hit.
vector mon_cull_seg_min, mon_cull_seg_max;
float  mon_cull_seg_valid;

// hmin/hmax are the SWEPT HULL of the trace ('0 0 0' for a bare traceline).  They are
// applied to the segment's AABB rather than to its endpoints because adding a corner
// to each endpoint is only correct when the segment happens to run in the +X+Y+Z
// direction; a shot fired backwards would come out inverted.
void(vector a, vector b, vector hmin, vector hmax) Monster_CullSegment =
{
    mon_cull_seg_min = [min(a_x, b_x), min(a_y, b_y), min(a_z, b_z)] + hmin;
    mon_cull_seg_max = [max(a_x, b_x), max(a_y, b_y), max(a_z, b_z)] + hmax;
    mon_cull_seg_valid = TRUE;
};

// Uniform inflation applied on top of whatever box a monster ends up with.  This is
// the monster half of sv_hitbox_expand (default 32), which every PLAYER has had
// around every weapon trace all along (sv_weapons.qc:819-841) and no monster had.
// That asymmetry is most of "my shots pass through NPC limbs": measured against the
// per-sequence bboxes in the studio headers, EVERY Half-Life monster model's animated
// extent leaves the 32x32x72 human hull — a zombie's attack reaches x=+101 and z=+94,
// barney's reload reaches x=-90, houndeye's leap reaches z=+108 against a 36-tall
// hull.  Not one of them fits.  HL is no better here (SetObjectCollisionBox in
// cbase.cpp:628-666 is mins/maxs +/- 1 for everything it does not override); this is
// deliberately more forgiving than GoldSrc, in the same direction and by the same
// mechanism the mod already chose for players.
//
// IT CANNOT INVENT A HIT.  Every trace inside the bracket is MOVE_HITMODEL, and HL
// studio models all ship per-bone hitboxes — 291 of the 296 character models on this
// machine have numhitboxes > 0, and the 5 that do not are effect props — so
// gl_hlmdl.c:1567-1710 still does the real per-bone test.  A bigger box only stops
// World_ClipToLinks from rejecting the entity before that test runs.

float mon_cull_depth;      // re-entrancy guard, see below

void() W_MonstersExpandHitboxes =
{
    // NEST-SAFE.  The bracket now sits inside W_WeaponTraceLine and W_MeleeTrace as
    // well as around the two shared hitscan helpers, and a future caller may well
    // wrap one of those.  Expand is already idempotent per entity (.mon_cull_inflated),
    // but a nested RESTORE would deflate the boxes while the outer trace still needed
    // them — so depth is counted here and only the outermost restore acts.
    mon_cull_depth = mon_cull_depth + 1;
    if (mon_cull_depth > 1)
        return;

    float pad = cvar("sv_hitbox_expand");
    if (pad < 0) pad = 0;
    vector padv = '1 1 1' * pad;
    vector eye  = self.origin;

    float extra = 0;
    entity e = monster_chain_head;
    for (;;)
    {
        if (!e)
        {
            // Fall through onto the side-list once the main chain is exhausted.
            if (extra >= mon_socb_extra_n)
                break;
            e = mon_socb_extra[extra];
            extra = extra + 1;
            if (!e || (e.classname != "monster_tentacle" && e.classname != "monster_nihilanth"))
            {
                e = world;         // slot recycled, or never was one of ours
                continue;          // (must clear e, or the top-of-loop refill is skipped)
            }
        }

        // Dead bodies are already off this chain (Monster_Teardown calls
        // monster_chain_remove), so a corpse keeps its own box — which is right,
        // a body on the floor is not the standing silhouette.
        // POSE THE SERVER'S HITBOXES WHERE THE CLIENT DRAWS THE MODEL.
        //
        // Every weapon trace in the game runs MOVE_HITMODEL, which FTE resolves
        // against the model's own per-bone hitboxes.  To do that it has to pose the
        // skeleton, and the server takes the pose time from .frame1time
        // (pr_cmds.c:634 -> HL_SetupBones, which derives the frame as
        // frametime * sequence->timing).
        //
        // Nothing on the server ever wrote .frame1time for a MONSTER.  A grep of the
        // whole server tree finds it only on players, in sv_lagcomp.qc.  So every
        // monster's hitboxes sat at frametime 0 - frame 0 of whatever sequence it is
        // playing, permanently - while the client rendered the animation.  Shoot a
        // walking grunt in the arm and the server was checking where that arm was at
        // the first frame of the walk cycle.  That is one of the three reasons a shot
        // could look like a hit and land nothing.
        //
        // Players already got exactly this treatment, with a comment that says why:
        // sh_player_anims.qc:678-680, "wall-clock driven ... so no drift between
        // server hitbox and client visual model".  .ai_seqstart is the monster's
        // equivalent stamp (AI_ApplySequence writes it with every .frame it sets, and
        // the two map-supplied sequence overrides now do too).
        //
        // HL_SetupBones wraps a looping sequence itself, so no modulo is needed here,
        // and .frame1time is never transmitted (it appears nowhere in sv_ents.c) so
        // this changes nothing about what any client renders.  Written before the
        // broadphase test rather than beside the setsize, so it applies even on the
        // ticks where the box itself does not change.
        //
        // Residual, and deliberately left: the client derives its own frame1time from
        // when the snapshot arrived, so one ping of offset remains.  That is far
        // smaller than the frozen-at-frame-0 error this removes.
        if (e.solid != SOLID_NOT && vlen(e.origin - eye) <= MON_CULL_MAX_DIST)
            e.frame1time = (e.ai_seqstart > 0) ? (time - e.ai_seqstart) : 0;

        if (e.solid != SOLID_NOT && !e.mon_cull_inflated
            && vlen(e.origin - eye) <= MON_CULL_MAX_DIST)
        {
            vector mn, mx;
            if (Monster_ClassRenderBox(e.classname))
            {
                mn = monster_render_min;
                mx = monster_render_max;
            }
            else
            {
                mn = e.mins;
                mx = e.maxs;
            }
            mn = mn - padv;
            mx = mx + padv;

            // Broadphase: if the box we are about to install cannot overlap the
            // trace's own AABB, the trace could not have hit it however big it is,
            // so installing it is pure cost.  Exact enough to be safe — this is a
            // conservative overlap test, never a hit test.
            if (mon_cull_seg_valid)
            {
                vector wmin = e.origin + mn;
                vector wmax = e.origin + mx;
                if (wmin_x > mon_cull_seg_max_x || wmax_x < mon_cull_seg_min_x
                 || wmin_y > mon_cull_seg_max_y || wmax_y < mon_cull_seg_min_y
                 || wmin_z > mon_cull_seg_max_z || wmax_z < mon_cull_seg_min_z)
                {
                    e = (extra > 0) ? world : e.monster_chain_next;
                    continue;
                }
            }

            if (mn != e.mins || mx != e.maxs)
            {
                e.mon_cull_save_min = e.mins;
                e.mon_cull_save_max = e.maxs;
                e.mon_cull_inflated = TRUE;
                setsize(e, mn, mx);
            }
        }

        e = (extra > 0) ? world : e.monster_chain_next;
    }
};

void() W_MonstersRestoreHitboxes =
{
    mon_cull_depth = mon_cull_depth - 1;
    if (mon_cull_depth > 0)
        return;                 // an outer bracket still owns the inflation
    if (mon_cull_depth < 0)
        mon_cull_depth = 0;     // unpaired restore — clamp rather than go negative

    // CLEARED HERE, NOT AT THE CALL SITE.  A segment left set would be read by the
    // NEXT expand — including the three callers that publish none — and silently skip
    // monsters that trace had every right to hit.  Tying the lifetime to the bracket
    // makes it impossible to leak: the flag is valid only between the expand that
    // followed a Monster_CullSegment and this restore.
    mon_cull_seg_valid = FALSE;

    float extra = 0;
    entity e = monster_chain_head;
    for (;;)
    {
        if (!e)
        {
            if (extra >= mon_socb_extra_n)
                break;
            e = mon_socb_extra[extra];
            extra = extra + 1;
            if (!e)
                continue;      // e is already world here, so the refill re-runs
        }

        // Latch-driven, not predicate-driven: whatever made us inflate it, the
        // restore must happen even if solid/classname/position changed inside the
        // trace.  This is also why the distance gate above is safe.
        if (e.mon_cull_inflated)
        {
            e.mon_cull_inflated = FALSE;
            setsize(e, e.mon_cull_save_min, e.mon_cull_save_max);
        }

        e = (extra > 0) ? world : e.monster_chain_next;
    }
};

// ---- sv_debug_hitboxes, the NPC half ---------------------------------------
//
// Sends the ONE box that actually gates a shot at a monster: whatever
// W_MonstersExpandHitboxes above installs.  RECOMPUTED rather than read off
// .mins/.maxs, because by the time a hit is processed the bracket has already
// restored — sh_weapon_standard.qc calls W_PlayersRestoreHitboxes BEFORE the
// `if (trace_fraction < 1.0)` block that emits.  Same reason CSQC cannot just
// read getentity(GE_ABSMIN): the snapshot is built at end of frame, after the
// restore (cl_monstersolid.qc:39-41).
//
// Keep the mn/mx derivation here IDENTICAL to the walk above.  If that walk ever
// changes what box it installs, this must change with it or the overlay starts
// lying — which is the exact failure this feature exists to end.
void(entity target, float mode) W_SendServerNPCHitbox =
{
    if (!target || !target.modelindex)
        return;
    if (target.solid == SOLID_NOT)
        return;
    // FL_MONSTER rather than a classname prefix: it is what the build path sets
    // and what tentacle/nihilanth set by hand, and a dead cockroach strips it
    // alongside solid (mon_cockroach.qc:94) so corpses fall out for free —
    // matching the expand walk, which only sees live chain members.
    if (!(target.flags & FL_MONSTER))
        return;

    vector mn, mx;
    if (Monster_ClassRenderBox(target.classname))
    {
        mn = monster_render_min;
        mx = monster_render_max;
    }
    else
    {
        mn = target.mins;
        mx = target.maxs;
    }
    float pad = cvar("sv_hitbox_expand");
    if (pad < 0) pad = 0;
    mn = mn - '1 1 1' * pad;
    mx = mx + '1 1 1' * pad;

    float dest;
    if (mode == 2)
        dest = MSG_MULTICAST;
    else
    {
        dest = MSG_ONE;
        msg_entity = self;          // the shooter, exactly as W_SendServerHitboxes does
    }

    WriteByte(dest, SVC_CGAMEPACKET);
    WriteByte(dest, CSQC_EVENT_SERVER_NPC_HITBOX);
    WriteShort(dest, num_for_edict(target));   // SHORT: monster edicts pass 255
    WriteCoord(dest, target.origin_x);
    WriteCoord(dest, target.origin_y);
    WriteCoord(dest, target.origin_z);
    WriteCoord(dest, mn_x);
    WriteCoord(dest, mn_y);
    WriteCoord(dest, mn_z);
    WriteCoord(dest, mx_x);
    WriteCoord(dest, mx_y);
    WriteCoord(dest, mx_z);
    WriteByte(dest, mode);

    if (mode == 2)
        multicast(target.origin, MULTICAST_PVS);
};

// Scenery classes.  HL leaves these at the model's (zero) hull, so they never
// block anything - which is the whole point of monster_furniture.
float(string cls) Monster_ClassIsScenery =
{
    if (cls == "monster_furniture")	return TRUE;
    return FALSE;
};

// Live players on a playing team, for the two bosses' party-scaled health.
// Spectators and the not-yet-joined are excluded: Sven counts connected PLAYERS,
// and giving a boss +200 HP for someone sitting on the team-select camera would
// make the fight harder for the people actually in it.
float() Monster_PlayerCount =
{
    float n = 0;
    entity e = player_chain_head;
    while (e)
    {
        if (e.player_team == TEAM_BLUE || e.player_team == TEAM_RED)
            n = n + 1;
        e = e.player_chain_next;
    }
    return n;
};

// Class default health, consulted BEFORE the generic 100 fallback.  Half-Life
// bakes health into the C++ class and 64.4% of placed monsters carry no health
// key, so without this every AI monster would be a 100 HP version of itself.
float(string cls) Monster_ClassHealth =
{
    if (cls == "monster_headcrab")	return Headcrab_DefaultHealth();
    if (cls == "monster_zombie")	return Zombie_DefaultHealth();
    if (cls == "monster_zombie_barney")	return Zombie_DefaultHealth();
    if (cls == "monster_zombie_soldier")	return Zombie_DefaultHealth();
    if (cls == "monster_cockroach")	return Cockroach_DefaultHealth();
    if (cls == "monster_alien_slave")	return Islave_DefaultHealth();
    if (cls == "monster_houndeye")	return Houndeye_DefaultHealth();
    if (cls == "monster_barnacle")	return Barnacle_DefaultHealth();
    if (cls == "monster_scientist")	return Scientist_DefaultHealth();
    if (cls == "monster_generic")	return Generic_DefaultHealth();
    if (cls == "monster_bigmomma")	return BigMomma_DefaultHealth();
    if (cls == "monster_apache")	return Apache_DefaultHealth();
    if (cls == "monster_osprey")	return Osprey_DefaultHealth();
    if (cls == "monster_gargantua")	return Gargantua_DefaultHealth();
    if (cls == "monster_babygarg")	return Babygarg_DefaultHealth();
    if (cls == "monster_stukabat")	return Stukabat_DefaultHealth();
    if (cls == "monster_kingpin")	return Kingpin_DefaultHealth();
    if (cls == "monster_leech")	return Leech_DefaultHealth();
    if (cls == "monster_ichthyosaur")	return Ichthyosaur_DefaultHealth();
    if (cls == "monster_alien_controller")	return Controller_DefaultHealth();
    if (cls == "monster_sentry")	return Turret_DefaultHealth();
    if (cls == "monster_miniturret")	return Turret_DefaultHealth();
    if (cls == "monster_turret")	return Turret_DefaultHealth();
    if (cls == "monster_alien_grunt")	return Agrunt_DefaultHealth();
    if (cls == "monster_bullchicken")	return Bullsquid_DefaultHealth();
    if (cls == "monster_pitdrone")	return Pitdrone_DefaultHealth();
    if (cls == "monster_gonome")	return Gonome_DefaultHealth();
    if (cls == "monster_alien_voltigore")	return Voltigore_DefaultHealth();
    // Sven's juvenile: half the adult's pool, matching the babygarg/garg ratio
    // this mod already uses for the same relationship.
    if (cls == "monster_alien_babyvoltigore")	return Voltigore_DefaultHealth() * 0.5;
    if (cls == "monster_human_grunt")	return Grunt_DefaultHealth();
    if (cls == "monster_human_grunt_ally")	return Grunt_DefaultHealth();
    if (cls == "monster_male_assassin")	return Grunt_DefaultHealth();
    // NOT Grunt_DefaultHealth.  Both of these share the grunt's rig and neither
    // shares its health: Sven's skill.cfg gives sk_hwgrunt_health and
    // sk_shocktrooper_health 200 apiece against the line grunt's 50, and there is
    // no Half-Life number for either class to fall back on.
    if (cls == "monster_hwgrunt")	return HWGrunt_DefaultHealth();
    if (cls == "monster_robogrunt")	return Grunt_DefaultHealth();
    if (cls == "monster_human_assassin")	return Grunt_DefaultHealth();
    if (cls == "monster_shocktrooper")	return Shocktrooper_DefaultHealth();
    if (cls == "monster_bodyguard")	return Barney_DefaultHealth();
    if (cls == "monster_th_grunt_repel")	return Grunt_DefaultHealth();
    // The two bosses scale with the party, which is the ONE thing about them
    // that is not inherited from their archetype.  monster_th_boss.as:11-12 is
    // 1000 + 200 per player; monster_th_cyberfranklin.as:21-22 is 400 + 110.
    // Both scripts read g_PlayerFuncs' live count at Spawn, so the number is
    // fixed when the boss is built, not re-evaluated as players join or leave.
    if (cls == "monster_th_boss")		return 1000 + 200 * Monster_PlayerCount();
    if (cls == "monster_th_cyberfranklin")	return 400 + 110 * Monster_PlayerCount();
    if (cls == "monster_barney")	return Barney_DefaultHealth();
    if (cls == "monster_otis")	return Otis_DefaultHealth();	// sk_otis_health 65, not Barney's 35
    // NOT Barney_DefaultHealth, and the boot-time hp column is what caught it:
    // the medic and the torch are the same Opposing Force engineer pair on the
    // same rig, and they were reporting 35 and 50.  The medic gets Barney's
    // number only because monster_human_medic_ally runs Barney_ClassInit for its
    // TALK behaviour - which is the right init and the wrong health table.  Both
    // derive from the friendly grunt in OpFor, so both take the grunt's.
    if (cls == "monster_human_medic_ally")	return Grunt_DefaultHealth();
    if (cls == "monster_human_torch_ally")	return Grunt_DefaultHealth();
    return 0;				// unknown: caller falls back
};

// ---------------------------------------------------------------------------
// model inventory  —  part of `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// Reports what every AI class actually RESOLVED to, and from which pack.
//
// This exists because guessing here has been wrong three separate times: once
// pointing at a file that never existed (male_assassin.mdl), once "fixing" it to
// a file this install could not reach, and twice more from filenames inferred
// from the classname (shocktrooper.mdl for strooper.mdl, pitdrone for pit_drone).
// The content arrives from several mounted Steam games at once - valve, gearbox
// and Sven Co-op - so which one wins is not something to reason about when the
// engine will simply say.
// ...and the HEALTH it hands that class, which used to be reportable nowhere at
// all.  Both existing harnesses overwrite it - the firetest sets its subjects to
// 100000 so a bot cannot shoot them, and the voicetest keeps hurting them - so
// "what does a monster of this class spawn with" had no number anywhere, and a
// class silently falling through to another class's default (which is how the
// shocktrooper and the HW grunt both ended up on the line grunt's 50) produced
// no observable symptom short of playing the map.
void(string cls) Monster_ReportModel =
{
    float hp = Monster_ClassHealth(cls);
    string mdl = Monster_DefaultModel(cls);
    if (mdl == "" || !mdl)
    {
        dprint(sprintf("[ai-selftest] model %-26s (none)                       hp=%g\n", cls, hp));
        return;
    }
    string pack = whichpack(mdl);
    if (pack == "" || !pack)
        dprint(sprintf("[ai-selftest] model %-26s %-30s hp=%-5g MISSING\n", cls, mdl, hp));
    else
        dprint(sprintf("[ai-selftest] model %-26s %-30s hp=%-5g <- %s\n", cls, mdl, hp, pack));
};

// ONE list, several consumers.  It used to be three hand-maintained lists that
// were supposed to agree and did not: this report knew 43 classes, AI_Init's
// warm/precache list knew 21 models, and the two had drifted far enough that
// every Opposing Force monster - strooper, gonome, massn, voltigore, pit_drone,
// hwgrunt, robogrunt, otis - was never warmed and therefore never had its event
// sounds precached, which is a large part of why they were silent.
//
// A function pointer rather than a returned array because QC cannot forward-
// declare an array and the consumers live in files that compile later.  Set
// monster_class_cb, call Monster_ForEachAIClass, and adding a class stays one
// line in one place.
// `var` is load-bearing: a bare `void(string) f;` in QC declares a CONSTANT
// function (a forward declaration), and assigning to it is Q106.  Only `var`
// makes it a reassignable function pointer.
var void(string cls) monster_class_cb;

void() Monster_ForEachAIClass =
{
    if (!monster_class_cb)
        return;
    monster_class_cb("monster_headcrab");
    monster_class_cb("monster_zombie");
    monster_class_cb("monster_cockroach");
    monster_class_cb("monster_alien_slave");
    monster_class_cb("monster_houndeye");
    monster_class_cb("monster_human_grunt");
    monster_class_cb("monster_human_grunt_ally");
    monster_class_cb("monster_male_assassin");
    monster_class_cb("monster_human_assassin");
    monster_class_cb("monster_hwgrunt");
    monster_class_cb("monster_robogrunt");
    monster_class_cb("monster_shocktrooper");
    monster_class_cb("monster_barney");
    monster_class_cb("monster_otis");
    monster_class_cb("monster_bodyguard");
    monster_class_cb("monster_human_medic_ally");
    monster_class_cb("monster_human_torch_ally");
    monster_class_cb("monster_th_grunt_repel");
    monster_class_cb("monster_th_boss");
    monster_class_cb("monster_th_cyberfranklin");
    monster_class_cb("monster_barnacle");
    monster_class_cb("monster_scientist");
    monster_class_cb("monster_bigmomma");
    monster_class_cb("monster_apache");
    monster_class_cb("monster_osprey");
    monster_class_cb("monster_gargantua");
    monster_class_cb("monster_babygarg");
    monster_class_cb("monster_stukabat");
    monster_class_cb("monster_kingpin");
    monster_class_cb("monster_leech");
    monster_class_cb("monster_ichthyosaur");
    monster_class_cb("monster_alien_controller");
    monster_class_cb("monster_sentry");
    monster_class_cb("monster_miniturret");
    monster_class_cb("monster_turret");
    monster_class_cb("monster_alien_grunt");
    monster_class_cb("monster_bullchicken");
    monster_class_cb("monster_pitdrone");
    monster_class_cb("monster_gonome");
    monster_class_cb("monster_alien_voltigore");
    monster_class_cb("monster_alien_babyvoltigore");
};

// The self-test's consumer.  AI_Init has the other one (AI_WarmClass), and the
// whole point of the shared walker is that neither can now know about a class
// the other does not.
void() Monster_ReportModels =
{
    monster_class_cb = Monster_ReportModel;
    Monster_ForEachAIClass();
};

// Sven's monster keys are TRI-STATES far more often than they look, and reading
// one as a boolean is wrong in the silent direction every time.  This turns the
// map's spelling into the mod's before anything reads it, so the ~40 call sites
// scattered through monsters/*.qc can keep testing plain truthiness.
//
// Runs on `self`, from Monster_Build, i.e. once per body and before AI_ClassInit.
void() Monster_NormaliseSvenKeys =
{
    // gag: -1 "Default" / 0 "No" / 1 "Yes" (sven-coop.fgd:5501).  -1 is what
    // pizza_ya_san1 writes on all 19 of its NPC spawners, and as a plain boolean
    // -1 is TRUE - so every customer, every stray dog and both shop clerks were
    // being muted by the key that means "say nothing special".
    if (self.gag < 0)
        self.gag = 0;
    // ...and the HL spawnflag of the same name, which nothing read either.
    if (self.spawnflags & SF_MON_GAG)
        self.gag = 1;

    // A map-placed monster's CamelCase TriggerTarget/TriggerCondition, folded
    // onto the underscored pair the AI layer already reads.  The underscored
    // spelling wins when both are set, because that one is written directly by a
    // squadmaker describing its child and is therefore the more specific answer.
    if ((self.trigger_target == "" || !self.trigger_target) && self.triggertarget != "")
        self.trigger_target = self.triggertarget;
    if (!self.trigger_condition && self.triggercondition)
        self.trigger_condition = self.triggercondition;

    // SQUAD NAME.  A MAP-PLACED monster names its squad in `netname`, not in
    // `squadname`: HL's CSquadMonster::SquadRecruit matches on
    // UTIL_FindEntityByString(..., "netname", ...) (squadmonster.cpp:327-346) and
    // Sven's FGD agrees, labelling `netname` "Squad Name" on every monster class
    // (sven-coop.fgd:4204 and 28 siblings).  `squadname` is SQUADMAKER's key for
    // describing its CHILD, and Monster_Spawn hands it down at :1222 below.
    //
    // Squad_Recruit compares .squadname (sv_ai_squad.qc:209), so before this every
    // map-placed monster carried "" and they all compared EQUAL - hl_c06's three
    // authored squads (squad_initial / squad_lift / squad_back) could merge by
    // proximity into one. 278 map-placed monsters across 29 maps name a squad.
    //
    // Translate here, in the one place that exists to translate the map's spelling
    // before anything reads it.
    //
    // GATED ON sq_maker, and it has to be: on a SQUADMAKER `netname` means something
    // completely different - it is the targetname handed to the child (:1242 below) -
    // so a maker with a netname and no squadname would otherwise name every child's
    // squad after the child's own targetname.  .sq_maker is assigned at :1240, before
    // Monster_Build calls this, so the test is live for children.
    //
    // AND GATED ON THE GONARCH, for the same shape of reason: `netname` on
    // monster_bigmomma is the name of the first info_bigmomma node in her patrol
    // chain (bigmomma.cpp keeps the next node's name in pev->netname and hl_c15
    // seeds it with "goose1"), not a squad.  Left in, she became a one-member
    // squad called goose1 — harmless in itself, but it is a squad name that can
    // collide with a real one on any map that uses both spellings, and the field
    // means something else entirely for this class.
    if (self.sq_maker == world && self.squadname == "" && self.netname != "" && self.netname
        && self.classname != "monster_bigmomma")
        self.squadname = self.netname;

    // bloodcolor: 0 "Monster Default" / -1 "No Blood" / 1 "Red" / 2 "Yellow"
    // (sven-coop.fgd:592).  1 and 2 are SYMBOLS, not palette indices; taken
    // literally they are two near-black entries at the bottom of the ramp.  The
    // mod already speaks HL's palette (247 = BLOOD_COLOR_RED, 195 =
    // BLOOD_COLOR_YELLOW, which HL #defines BLOOD_COLOR_GREEN to as well), so
    // translate here and let the class defaults fill in the 0 case.
    //
    // -1 is left alone deliberately: it is the DONT_BLEED marker the robogrunt
    // and the gargantua already use, and the class inits' "fill in a default"
    // guards have been narrowed from `<= 0` to `== 0` so it now survives them.
    if (self.bloodcolor == 1)
        self.bloodcolor = 247;
    else if (self.bloodcolor == 2)
        self.bloodcolor = 195;

    // The ally flip.  See the .ai_ally_flip note at the top of this file: the map
    // key states "opposite of the class default", so it cannot stay in the field
    // the class default is about to be written into.
    if (self.is_player_ally)
    {
        self.ai_ally_flip  = TRUE;
        self.is_player_ally = FALSE;
    }

    // Resolve the per-monster sound replacement table.  Done here rather than at
    // emission time because Soundlist_Load parses the file and precaches every
    // replacement it names, and doing that once per body is the cheap version.
    // Children get sl_table handed down by Monster_Spawn and so short-circuit.
    if (!self.sl_table && self.soundlist != "" && self.soundlist)
        self.sl_table = Soundlist_Load(self.soundlist);
};

void(float want_solid) Monster_Build =
{
    string mdl = self.model;
    if (mdl == "" || !mdl)
        mdl = self.new_model;
    if (mdl == "" || !mdl)
        mdl = Monster_DefaultModel(self.classname);

    if (mdl == "" || !mdl)
    {
        // No model to show.  Keep the entity — its targetname may still be
        // the anchor of a trigger chain or a camera's look-at — but it is
        // invisible and inert.
        self.solid     = SOLID_NOT;
        self.movetype  = MOVETYPE_NONE;
        self.modelindex = 0;
    }
    else
    {
        precache_model(mdl);
        setmodel(self, mdl);

        // Sven's notsolid is a tri-state: -1 means "use the class default",
        // which is why every squadmaker in pizza_ya_san1 carries -1 rather
        // than 0.  Only an explicit 1 forces non-solid.
        //
        // want_solid is deliberately ignored for AI classes.  It exists because
        // an AI-less body can never step out of a corridor it is blocking, so
        // squadmaker children were built non-solid; a monster that walks has no
        // such problem, and one that cannot be shot or collided with is not a
        // monster.  An explicit notsolid 1 from the map still wins.
        float want = want_solid;
        if (Monster_ClassHasAI(self.classname))
            want = TRUE;

        if (self.notsolid == 1 || !want || Monster_ClassIsScenery(self.classname))
            self.solid = SOLID_NOT;
        else
            self.solid = SOLID_BBOX;

        self.movetype = MOVETYPE_NONE;

        if (self.new_body && !self.body)
            self.body = self.new_body;
        if (self.new_skin > 0 && !self.skin)
            self.skin = self.new_skin;

        // Explicit hull override, both corners or neither — a half-specified
        // hull collapses the bbox and drops the entity out of the PVS.  Note
        // Sven maps write "0 0 0" for both to mean "no override", which this
        // test already treats correctly.
        if (self.minhullsize != '0 0 0' && self.maxhullsize != '0 0 0')
            setsize(self, self.minhullsize, self.maxhullsize);
        else if (self.solid != SOLID_NOT)
        {
            // No explicit hull from the map: take the class's, NOT the model's.
            // See Monster_ClassHull for why the model's is unusable here.
            Monster_ClassHull(self.classname);
            setsize(self, monster_hull_min, monster_hull_max);
        }

        // .ai_seqstart is stamped alongside because it is now read as the POSE
        // CLOCK: W_MonstersExpandHitboxes derives .frame1time from it so the
        // server's per-bone hitboxes are posed where the client draws the model.
        // AI_ApplySequence stamps it for every sequence the AI plays; these two
        // map-supplied overrides write .frame directly and did not, which would
        // leave frame1time reading the whole map clock.
        if (self.sequence > 0)
        {
            self.frame       = self.sequence;
            self.ai_seqstart = time;
        }
        else if (self.sequencename && self.sequencename != "")
        {
            float seq = frameforname(self.modelindex, self.sequencename);
            if (seq >= 0)
            {
                self.frame       = seq;
                self.ai_seqstart = time;
            }
        }

        BrushSync_ApplyRenderKeys();
    }

    // `angle` is HL entdata's single-axis yaw shortcut; fold it in the same
    // way cycler and item_generic do.
    if (self.angles == '0 0 0' && self.angle != 0)
        self.angles_y = self.angle;

    Monster_NormaliseSvenKeys();

    // Class default first, generic fallback second.  Order matters: AI_Spawn
    // seats ai_lasthealth from .health, and that field is what sizes every later
    // hit — so health arriving after it would make the first shot register as a
    // negative amount of damage.
    if (!self.health)
        self.health = Monster_ClassHealth(self.classname);
    if (!self.health)
        self.health = 100;

    // Record the spawn health.  HL's BecomeDead gives a corpse max_health/2 as
    // its own gib pool (combat.cpp:523), which is only meaningful if max_health
    // was captured while the monster was ALIVE - deriving it at death reads a
    // health that is already zero or negative and leaves every corpse with a
    // one-point pool that the first crowbar swing bursts.  Measured: a headcrab
    // corpse came out at health=1 and gibbed on swing one.
    self.max_health = self.health;

    // Give every monster the inert trigger relay.
    //
    // This is the bug the plan flagged: defining a spawn function SILENTLY
    // removes a class's pass-through.  An unimplemented monster_barney gets
    // .use = GoldSrc_UnknownRelay_Use from SV_OnEntityNoSpawnFunction and so
    // forwards a chain routed through it; the moment the class gains a spawn
    // function it stops doing that, and any multi_manager naming it dead-ends.
    // Nothing reports it — the chain just stops.
    //
    // SV_UseTarget refuses FL_MONSTER entities unless monster_player_usable is
    // set, so this is a relay for TRIGGERS only and a player cannot fire a
    // monster's target chain by pressing +use on it.
    self.use = GoldSrc_UnknownRelay_Use;

    // Still DAMAGE_NO for classes with no AI: W_CanDamageTarget (sv_weapons.qc:1103)
    // requires DAMAGE_YES to admit damage at all, so scenery stays unkillable.
    // A class that opts into AI becomes damageable and gets the death handler that
    // hands its squadmaker slot back.
    if (Monster_ClassHasAI(self.classname) && self.solid != SOLID_NOT)
    {
        self.takedamage = DAMAGE_YES;
        self.on_killed  = Monster_Killed;
        // Re-does movetype and solidity for a walking body, drops it to the
        // floor and starts it thinking.  A FALSE return means it could not be
        // stood anywhere; it is left inert but still addressable by targetname,
        // for the same reason the AI-less classes are.
        AI_Spawn(self);
    }
    else
        self.takedamage = DAMAGE_NO;

    monster_chain_add(self);

    if (cvar("sv_debug_monsters"))
    {
        dprint(sprintf("[monster] %s \"%s\" model=%s solid=%g hull %v .. %v\n",
                       self.classname, self.displayname, mdl, self.solid,
                       self.mins, self.maxs));
        // Skeleton reachability, once per body.  Whether the SERVER carries HL bone
        // data is not answerable from the engine source alone - Mod_GetTag needs the
        // model loaded with its skeleton, and nothing in this tree called gettaginfo
        // from SSQC until the gargantua's flame emitters started asking for real
        // attachment positions (mon_bigfoes.qc).  numbones > 0 here means every
        // attachment-driven effect can stop synthesising offsets off the hull.
        {
            float dbgsk = skel_create(self.modelindex);
            float dbgnb = 0;
            if (dbgsk) { dbgnb = skel_get_numbones(dbgsk); skel_delete(dbgsk); }
            vector dbgtag = (dbgnb > 0) ? gettaginfo(self, dbgnb + 2) : '0 0 0';
            dprint(sprintf("[monster]    bones=%g tag[%g]=%v rel=%v\n",
                           dbgnb, dbgnb + 2, dbgtag,
                           (dbgtag != '0 0 0') ? (dbgtag - self.origin) : '0 0 0'));
        }
        // The keys that decide whether this body is friendly, and they are worth a
        // line of their own: "the shop staff shot me" and "the customer will not
        // sit down" are both answered here and nowhere else.  ai_class is read
        // AFTER AI_Spawn has run, so it is the post-flip value.
        dprint(sprintf("[monster]   ally=%g flip=%g prisoner=%g class=%g classify=%g\n",
                       self.is_player_ally, self.ai_ally_flip, self.ai_prisoner,
                       self.ai_class, self.classify));
        dprint(sprintf("[monster]   gag=%g blood=%g body=%g weapons=%g soundlist=%g\n",
                       self.gag, self.bloodcolor, self.body, self.weapons, self.sl_table));
    }
};

// Runtime construction, used by squadmaker.  The caller has no entity yet, so
// this makes one, copies the maker's description of the child onto it, then
// funnels into the same Monster_Build.
entity(entity maker, string cls, vector org, vector ang) Monster_Spawn =
{
    entity oldself = self;
    entity m = spawn();

    m.classname   = cls;
    m.model       = maker.new_model;
    // new_body is a tri-state too: -1 is "no override", which is what all four of
    // pizza_ya_san1's turret spawners write.  Copied raw it became bodygroup -1.
    if (maker.new_body > 0)
        m.body    = maker.new_body;
    // `> 0`, exactly as new_body does, and the first version of this used `>= 0`
    // on the reasoning that skin 0 is a real skin while bodygroup 0 is not.  That
    // reasoning is right about models and wrong about QC: an ABSENT key leaves the
    // field at 0, so `>= 0` cannot tell "the mapper asked for skin 0" from "the
    // mapper said nothing", and it forced skin 0 onto every child of every maker
    // in the corpus.  Caught by the diagnostic below on th_escape, which printed
    // `skin=0` for cockroach spawners that carry no new_skin key at all.
    //
    // Nothing is lost by it: no corpus entity writes new_skin 0, 544 of the 565
    // write the -1 no-op, and the remaining 21 are 1 and 2.
    if (maker.new_skin > 0)
        m.skin    = maker.new_skin;
    m.health      = maker.health;
    m.max_health  = maker.health;	// see the note in the map-spawn path above
    m.displayname = maker.displayname;
    m.bloodcolor  = maker.bloodcolor;
    m.classify    = maker.classify;
    m.notsolid    = maker.notsolid;
    m.weapons     = maker.weapons;
    m.minhullsize = maker.minhullsize;
    m.maxhullsize = maker.maxhullsize;
    m.rendermode  = maker.rendermode;
    m.renderamt   = maker.renderamt;
    m.rendercolor = maker.rendercolor;
    // gag and soundlist were not copied at all, so a spawner's whole voice
    // configuration stopped at the spawner.  Both are per-BODY settings that the
    // maker is only holding on the child's behalf.
    m.gag         = maker.gag;
    m.soundlist   = maker.soundlist;
    m.sl_table    = maker.sl_table;
    // respawn_as_playerally is the same flip as is_player_ally - "Default (0)" /
    // "Opposite (1)" in the FGD - so it lands in the same field.  Writing it into
    // .is_player_ally, as this did, meant the ClassInit that runs a moment later
    // overwrote it with the class default and the key never reached anything.
    if (maker.respawn_as_playerally)
        m.ai_ally_flip = TRUE;
    // Blocked-spawn policy is the MAKER's, but only the child can act on it: the
    // overlap is not discovered until AI_Spawn tries to stand the body up.  Mode
    // 2 rides down on the child as a flag; mode 1 is handled by the maker itself,
    // which is the only thing that can decide to try again.
    if (maker.spawn_mode == SQ_SPAWN_FORCE)
        m.ai_forceplace = TRUE;
    // Only the three maker flags that describe the CHILD, translated rather than
    // copied - see the SQ_SF_* block at the top of this file.
    if (maker.spawnflags & SQ_SF_PRISONER)
        m.spawnflags = m.spawnflags | SF_MON_PRISONER;
    if (maker.spawnflags & SQ_SF_MONSTERCLIP)
        m.spawnflags = m.spawnflags | SF_MON_MONSTERCLIP;
    if (maker.spawnflags & SQ_SF_WAITFORSCRIPT)
        m.spawnflags = m.spawnflags | SF_MON_WAIT_FOR_SCRIPT;
    // The squad identity was NOT being copied, so every child spawned squadless:
    // HL's squad coordination keys entirely off .squadname, and a squadmaker whose
    // whole purpose is to produce a SQUAD was producing a set of unrelated loners.
    // is_squad_leader rides along for the same reason.
    m.squadname       = maker.squadname;
    m.is_squad_leader = maker.is_squad_leader;
    // guard_ent / freeroam describe the CHILD's idle behaviour, not the maker's -
    // the maker never moves.  Without this the keys stopped at the spawner, which
    // on desertcircle is 16 of 18 makers setting freeroam 2 and 8 setting a
    // guard_ent, all of it reaching nothing.
    m.guard_ent   = maker.guard_ent;
    m.freeroam    = maker.freeroam;
    // Same reasoning: `attackrange` on a squadmaker describes the CHILD's reach,
    // not the spawner's — the spawner has no attack.  Ten corpus makers set it.
    m.attackrange = maker.attackrange;
    m.sq_maker    = maker;
    // squadmaker's `netname` is the targetname handed to the CHILD, which is
    // how scripted_sequence and trigger chains address a spawned monster.
    m.targetname  = maker.netname;
    m.angles      = ang;

    setorigin(m, org);

    self = m;
    // FALSE = "not solid unless the class earns it".  An AI-less child can never
    // step out of a corridor it is blocking, so those stay non-solid; a class
    // with AI overrides this inside Monster_Build, because it can walk away.
    Monster_Build(FALSE);
    self = oldself;

    return m;
};

/*QUAKED monster_furniture (.4 .3 .2) (-16 -16 0) (16 16 64)
Sven Co-op static prop "monster" — a model that stands there. NOT solid.

This used to be built solid, on the reasoning that mappers place furniture as
physical set dressing. That was wrong, and measurably so. GoldSrc's
CFurniture::Spawn is indeed SOLID_BBOX, but SET_MODEL sizes a studio entity from
the model HEADER's bbox — and every furniture model in the corpus declares that
header as "0 0 0", so the box has zero volume and blocks nothing. Half-Life
furniture is decorative, full stop.

Our engine fork cannot inherit that by accident: it derives model bounds from
GEOMETRY (gl_hlmdl.c, added so physics props get a usable hull), so a solid
furniture entity wears its idle animation's bounding box instead. Measured:
  th_ep1_02   models/hunger/vegitation/arc_xer_tree1.mdl   500 x 468 x 622
  pizza_ya_san1 models/pizza_ya_san/pi_tree.mdl            474 x 445 x 618
  pizza_ya_san1 models/can.mdl                             13 x 7 x 7
...which is why you could not get near the trees on either map, and why a drinks
can on the floor of pizza_ya_san1 was something you could walk into. Both maps
write "minhullsize"/"maxhullsize" as "0 0 0", so the keys cannot tell the two
apart — the class rule is the fix. A mapper who genuinely wants collision has
item_security / func_wall, which is what Sven's own docs point them at.

"model"        studio model to display (required to be visible)
"minhullsize"  explicit bbox min (set both to override)
"maxhullsize"  explicit bbox max
"displayname"  human-readable name
"rendermode" "renderamt" "rendercolor"  as func_wall
*/
void() monster_furniture =
{
    Monster_Build(TRUE);
};

// Shared entry for the map-placed monster classes.  All of them are inert
// until Monster_HasAI() flips; they exist so their targetnames resolve and so
// trigger_cameras aiming at them (pizza_ya_san1's cam_mi aims at
// monster_human_assassin "mon_mi") have something at a real position.
void() Monster_MapPlaced =
{
    Monster_Build(FALSE);
};

void() monster_generic          = { Monster_MapPlaced(); };
void() monster_leech            = { Monster_MapPlaced(); };
void() monster_ichthyosaur      = { Monster_MapPlaced(); };
void() monster_human_assassin   = { Monster_MapPlaced(); };
void() monster_male_assassin    = { Monster_MapPlaced(); };
void() monster_zombie           = { Monster_MapPlaced(); };
// th_ep1_00 places 4 scientists and 1 headcrab.  Both carry a `model` key in
// that map, so they render from the entdata; the table above covers the case
// where a map leaves it to the class default.
void() monster_scientist        = { Monster_MapPlaced(); };
void() monster_headcrab         = { Monster_MapPlaced(); };
// W2.  All three are AI classes, so Monster_Build overrides the FALSE below and
// builds them solid — see the want_solid comment there.
void() monster_zombie_barney    = { Monster_MapPlaced(); };
void() monster_zombie_soldier   = { Monster_MapPlaced(); };
void() monster_cockroach        = { Monster_MapPlaced(); };
// W1d/W5.  alien_slave is 726 placements - the #2 classname in the corpus.
void() monster_alien_slave      = { Monster_MapPlaced(); };
void() monster_houndeye         = { Monster_MapPlaced(); };
// monster_leech and monster_ichthyosaur already have spawn functions above, from
// when they were inert scenery bodies; they need no second one now that they have
// AI, because Monster_MapPlaced -> Monster_Build is the single construction path
// and AI_ClassHasAI is what decides whether a body gets a brain.
void() monster_alien_controller = { Monster_MapPlaced(); };
void() monster_barnacle         = { Monster_MapPlaced(); };
void() monster_bigmomma	= { Monster_MapPlaced(); };
void() monster_apache	= { Monster_MapPlaced(); };
void() monster_osprey	= { Monster_MapPlaced(); };
void() monster_gargantua	= { Monster_MapPlaced(); };
void() monster_babygarg	= { Monster_MapPlaced(); };
void() monster_stukabat	= { Monster_MapPlaced(); };
void() monster_kingpin	= { Monster_MapPlaced(); };
void() monster_sentry	= { Monster_MapPlaced(); };
void() monster_miniturret	= { Monster_MapPlaced(); };
void() monster_turret	= { Monster_MapPlaced(); };
void() monster_alien_grunt	= { Monster_MapPlaced(); };
void() monster_bullchicken	= { Monster_MapPlaced(); };
void() monster_pitdrone	= { Monster_MapPlaced(); };
void() monster_gonome	= { Monster_MapPlaced(); };
void() monster_alien_voltigore	= { Monster_MapPlaced(); };
void() monster_alien_babyvoltigore	= { Monster_MapPlaced(); };
// W3: the gun shooters.  ~2600 placements on one archetype.
void() monster_human_grunt	= { Monster_MapPlaced(); };
void() monster_human_grunt_ally	= { Monster_MapPlaced(); };
void() monster_hwgrunt	= { Monster_MapPlaced(); };
void() monster_robogrunt	= { Monster_MapPlaced(); };
void() monster_shocktrooper	= { Monster_MapPlaced(); };
void() monster_bodyguard	= { Monster_MapPlaced(); };
void() monster_th_grunt_repel	= { Monster_MapPlaced(); };
// They Hunger's finale pair, th_ep3_07.  Re-skins of the apache and the
// hgrunt - see the model and health tables above for why that is the port
// rather than a shortcut.
void() monster_th_boss	= { Monster_MapPlaced(); };
void() monster_th_cyberfranklin	= { Monster_MapPlaced(); };
// CORRECTION: `monster_grunt_repel` IS HALF-LIFE'S OWN CLASSNAME, not an
// unprefixed spelling of They Hunger's.
//
// hgrunt.cpp:2389 — LINK_ENTITY_TO_CLASS(monster_grunt_repel, CHGruntRepel) — and
// CHGruntRepel is not a grunt at all.  It is an invisible, SOLID_NOT, use-triggered
// SPAWNER (:2391-2397, no model and no think) whose whole behaviour is RepelUse
// (:2405-2430): trace 4096 units down for the landing spot, Create() a normal
// monster_human_grunt, give it MOVETYPE_FLY and a downward velocity, play
// ACT_GLIDE, draw a sprites/rope.spr beam from 112 units above it, and
// UTIL_Remove itself.
//
// Aliasing it onto They Hunger's monster_th_grunt_repel turned that into a solid,
// visible, standing hgrunt.mdl suspended in mid-air at the rope anchor, with its
// .use chain gone — so the rappel never happens and the map gets a floating soldier
// instead.  The two classes genuinely differ; only the name looks shared.
//
// LATENT TODAY, which is why it has not been reported: a scan of all 35 Sven hl_c*
// maps and the vanilla c1a3*/c1a4*/c2a2* set finds ZERO placements, because the
// Sven port replaced Half-Life's helicopter-rappel scene with plain squadmakers
// (hl_c04 has ten of them).  Fixed anyway, so that a map which does use it gets
// nothing rather than something wrong.
//
// The full rappel is deliberately not implemented here — a stub that silently does
// nothing is the honest state, and sv_goldsrc_compat.qc:271-272 already warns that
// a stub counts as implemented to the unhandled-classname reporter, so this one
// says so out loud instead.
void() monster_grunt_repel =
{
	self.solid    = SOLID_NOT;
	self.movetype = MOVETYPE_NONE;
	self.model    = "";
	dprint(sprintf("monster_grunt_repel at %v: HL's rappel spawner is not implemented; "
	               "no grunt will drop here (see hgrunt.cpp:2405-2430)\n", self.origin));
};

// (They Hunger's own prefixed monster_th_grunt_repel — 4 placements on th_ep3_04,
// and genuinely just a standing grunt — already has its spawn function at :1321,
// so nothing needs to be re-routed to it.)

// ---------------------------------------------------------------------------
//  monster_snark — the live snark placed as a map entity
// ---------------------------------------------------------------------------
//  18 placements across 8 maps, all of them squadmaker children.  There is no
//  new creature here: `monster_snark` IS squeakgrenade.cpp's classname, and
//  W_SnarkSpawn (shared/weapons/sh_wpn_hlsnark.qc:292) already builds exactly
//  that entity for the thrown weapon — it even sets this classname itself.
//
//  So this is the map-placed door onto the same constructor, with no owner: a
//  wild snark bites whatever it reaches, including the player.
//
//  IT STILL DIES ON ITS FUSE, and that is HL, not an omission.
//  CSqueakGrenade::Spawn arms m_flDie unconditionally (squeakgrenade.cpp:108),
//  so a map-placed snark pops after SNARK_FUSE seconds exactly like a thrown
//  one.  A mapper wanting a permanent nest uses a squadmaker, which is what all
//  18 of these are.
// ---------------------------------------------------------------------------
// W_SnarkSpawn is deliberately NOT forward-declared here: sh_wpn_hlsnark.qc
// compiles far above us, so it is already DEFINED, and in fteqcc a second
// declaration of a defined function re-emits the global as an empty one — every
// call then silently does nothing.  (Measured the hard way on GoldSrcFX_Count.)
void() monster_snark =
{
	// A tiny upward kick so one that was placed a few units inside the floor
	// settles out of it rather than starting stuck — MOVETYPE_BOUNCE plus the
	// anti-stick jitter in W_SnarkThink handles the rest.
	W_SnarkSpawn(world, self.origin + '0 0 8', '0 0 16');
	remove(self);
};

// ---------------------------------------------------------------------------
//  ...and the same door for a squadmaker / monstermaker whose monstertype is
//  monster_snark.
// ---------------------------------------------------------------------------
//  76 makers across 15 maps (46 monstermaker, 30 squadmaker) name it, and every
//  one of them printed `[squadmaker] no implementation for "monster_snark"` and
//  produced nothing while the target chain still fired.
//
//  Half-Life needs no special case here at all: CMonsterMaker::MakeMonster just
//  calls CREATE_NAMED_ENTITY(monstertype) (monstermaker.cpp:182) and the engine's
//  spawnfunc table does the rest.  This mod resolves monstertype through three
//  predicates instead — Monster_ClassHasAI / Monster_ClassIsScenery /
//  Squadmaker_IsItem — and the snark is in none of them, so the door has to be
//  opened by hand.
//
//  DELIBERATELY NOT ROUTED THROUGH Monster_Spawn.  The snark is not an AI class
//  and must never become one: AI_ClassInit has no entry for it, so it would come
//  out a modelless dummy holding a squad slot forever — the exact trap the
//  comment above Monster_ClassHasAI warns about.  W_SnarkSpawn IS the
//  constructor, the same one the map-placed door and the thrown weapon use.
//
//  owner == world is correct, not a shortcut: monstermaker.cpp:211-212 sets
//  pevCreate->owner only AFTER DispatchSpawn has run, so CSqueakGrenade::Spawn
//  sees a NULL owner and m_hOwner stays NULL.  A maker's snark is nobody's kill
//  and bites the first thing it touches, the player included.
entity(entity maker, vector org) Squadmaker_SpawnSnark =
{
	// Same upward kick as the map-placed door above, for a maker whose origin
	// sits a few units inside the floor.
	vector at = org + '0 0 8';
	entity s = W_SnarkSpawn(world, at, '0 0 16');
	if (!s)
		return world;

	// 11 of the 76 corpus makers re-model the creature — sc_mazing dresses it as
	// a scarab (8) and th_escape as a zombie rat (3).  Sven gives monster_snark
	// the full base(Monster) keyset (sven-coop.fgd:4919), so this is documented
	// use rather than abuse.
	//
	// setmodel THEN setsize THEN setorigin, in that order: setmodel on a studio
	// model overwrites mins/maxs from the model's own bounds and would silently
	// resize the creature away from squeakgrenade.cpp:103's (-4 -4 0)/(4 4 8).
	if (maker.new_model != "" && maker.new_model)
	{
		precache_model(maker.new_model);
		setmodel(s, maker.new_model);
		setsize(s, '-4 -4 0', '4 4 8');
		setorigin(s, at);
	}
	if (maker.new_skin > 0)
		s.skin = maker.new_skin;
	if (maker.new_body > 0)
		s.body = maker.new_body;
	// health > 0 only: an absent key reads 0 and must not wipe SNARK_HEALTH.
	if (maker.health > 0)
	{
		s.health     = maker.health;
		s.max_health = maker.health;
	}
	s.displayname = maker.displayname;
	// squadmaker's netname is the targetname handed to the CHILD.
	s.targetname  = maker.netname;
	// Back-pointer to the maker.  Nothing decrements a snark's slot — it leaves
	// the world through remove() in W_SnarkPop and never reaches
	// Monster_Teardown — but without this a maker carrying a death-based
	// trigger_condition would wait forever on a notification that cannot arrive.
	s.sq_maker    = maker;
	return s;
};

// monster_rat — one placement in the whole corpus, and Sven ships bigrat.mdl for
// it.  Scenery, and that is a judgement rather than a shortcut: there is no rat
// archetype, and inventing an AI class for a single decorative entity would cost
// more than it could possibly return.  Routed through monster_furniture so it
// inherits that class's not-solid rule, which matters here — a studio hull
// derived from geometry (see the long note on monster_furniture) would put an
// invisible rat-shaped wall on the floor.
void() monster_rat =
{
	self.classname = "monster_furniture";
	if (self.model == "" || !self.model)
		self.model = "models/bigrat.mdl";
	monster_furniture();
};
void() monster_barney	= { Monster_MapPlaced(); };
void() monster_otis	= { Monster_MapPlaced(); };
void() monster_human_medic_ally	= { Monster_MapPlaced(); };
void() monster_human_torch_ally	= { Monster_MapPlaced(); };

// ---------------------------------------------------------------------------
//  squadmaker
// ---------------------------------------------------------------------------
// Sven's monster spawner, and the single biggest class in pizza_ya_san1 (97
// instances, 11% of the map).  Waves of these drive the whole mission: they
// fire target chains and feed game_counters, and that progression must advance
// whether or not a body ever appears.
//
// So the spawner logic — counts, caps, delays, enable/disable, target chains —
// is fully implemented, and only the BODY is gated behind sv_squadmaker_spawn
// (default 0).  With AI absent, 97 spawners producing standing dummies is
// worse than nothing; with AI present, flip the cvar and the same code path
// starts producing real monsters via Monster_Spawn.
const float SQ_SF_STARTON = 1;      // spawn continuously from map start
// HL's monstermaker adds this one: each trigger drops exactly ONE monster and
// nothing is scheduled.  Sven's squadmaker has no equivalent, so it is only ever
// set on entities that came in as monstermaker - but the flag lives here because
// both classes run the same code.
const float SQ_SF_CYCLIC  = 4;

void() squadmaker_spawn_one;

// How many of this maker's dispensed items are still lying in the world.  See the
// .sq_ownerid note above for why this is a scan and the monster path is a latch.
float(entity maker) Squadmaker_CountLiveItems =
{
    if (!maker.sq_id)
        return 0;
    float n = 0;
    entity e = findchainfloat(sq_ownerid, maker.sq_id);
    while (e)
    {
        n = n + 1;
        e = e.chain;
    }
    return n;
};

// IS THE SPAWN SPOT ALREADY OCCUPIED?
//
// Half-Life's CMonsterMaker::MakeMonster refuses outright rather than build a
// tower of monsters (monstermaker.cpp:180-190):
//     Vector mins = pev->origin - Vector(34,34,0);  mins.z = m_flGround;
//     if (UTIL_EntitiesInBox(pList, 2, mins, maxs, FL_CLIENT|FL_MONSTER))
//         return;                       // don't build a stack of monsters!
// and m_flGround exists purely "to make sure no monsters are under the maker
// when it drops a new child" (monstermaker.cpp:59).
//
// This mod had no equivalent, and nothing downstream can stand in for it.  The
// only placement check is AI_PlaceOnFloor -> droptofloor, and FTE's
// PF_droptofloor only reports failure on `trace.fraction == 1 || trace.allsolid`
// (pr_bgcmd.c:6678).  A box trace that STARTS inside another monster gives
// startsolid=1, fraction=0 and allsolid=0 - allsolid is only OR'd in from the
// per-entity trace (world.c:1952-1981) and the 256-unit downward trace leaves
// that monster's box - so droptofloor returns success, .ai_placefail is never
// set, and the lift-and-retry loop at sv_ai_move.qc:1084 (guarded by `if (!ok)`)
// never runs.  The child is simply accepted standing in its predecessor.
// m_imaxlivechildren is what bounds the HEIGHT of the resulting stack, which is
// why pizza_ya_san1's ml_flour5 shows three babyvoltigores inside one another
// and sq_flour4 shows two shocktroopers sharing one box.
//
// Deliberately NOT findradius: .chain is one shared temp field and
// Squadmaker_CountLiveItems is already using it on this code path, and it
// measures from the bbox centre rather than testing overlap.  Walk the mod's own
// chains instead.  Corpses need no special case - Monster_Teardown calls
// monster_chain_remove the instant a monster dies (see Monster_Killed), so a
// body left lying on the spot is already off this chain and cannot jam the maker
// forever, which is the one way this test could stall a map.
//
// The child's OWN hull, not HL's fixed 34: this mod's classes run from a 2-unit
// cockroach to a 160-unit voltigore, and a fixed box would either wave the
// voltigore through or refuse to place a roach next to one.
float(entity maker, string cls) Squadmaker_SpotBlocked =
{
    vector mn, mx;
    if (maker.minhullsize != '0 0 0' && maker.maxhullsize != '0 0 0')
    {
        // Same "both corners or neither" rule Monster_Build applies at :1207.
        mn = maker.origin + maker.minhullsize;
        mx = maker.origin + maker.maxhullsize;
    }
    else
    {
        Monster_ClassHull(cls);          // fills monster_hull_min/max
        mn = maker.origin + monster_hull_min;
        mx = maker.origin + monster_hull_max;
    }

    entity e = monster_chain_head;
    while (e)
    {
        if (e.solid != SOLID_NOT
            && e.absmin_x < mx_x && e.absmax_x > mn_x
            && e.absmin_y < mx_y && e.absmax_y > mn_y
            && e.absmin_z < mx_z && e.absmax_z > mn_z)
            return TRUE;
        e = e.monster_chain_next;
    }

    // FL_CLIENT is half of HL's mask, and it matters: a player standing on the
    // spot should stop the spawn, not be telefragged by it.  (Sven's other answer
    // is the `dmg` key, "Amount of Telefrag Damage" - sven-coop.fgd:5459 - which
    // this build does not implement.)
    entity p = player_chain_head;
    while (p)
    {
        if (p.solid != SOLID_NOT && !p.is_dead
            && p.absmin_x < mx_x && p.absmax_x > mn_x
            && p.absmin_y < mx_y && p.absmax_y > mn_y
            && p.absmin_z < mx_z && p.absmax_z > mn_z)
            return TRUE;
        p = p.player_chain_next;
    }
    return FALSE;
};

void() squadmaker_think =
{
    if (!self.sq_enabled)
        return;
    squadmaker_spawn_one();
};

void() squadmaker_spawn_one =
{
    // Total budget.  -1 is Sven's "unlimited" sentinel, which is what all 97
    // spawners in pizza_ya_san1 use.
    if (self.monstercount >= 0 && self.sq_spawned_total >= self.monstercount)
    {
        self.sq_enabled = 0;
        return;
    }

    // What is this maker actually going to produce?  Decided BEFORE the cap,
    // because the cap is only meaningful for a child that can eventually hand its
    // slot back - see below.
    //
    // Produce a BODY when the child's class can actually behave, and only then.
    // This used to be one global cvar, on the reasoning that 97 spawners making
    // standing dummies is worse than making nothing.  That reasoning still holds
    // for the classes with no AI yet - but it is per-class, not global, and a
    // single switch cannot express that.  Keyed on the child's class, a zombie
    // squadmaker starts producing real zombies the moment B3 lands while a
    // monster_alien_slave squadmaker keeps firing its chain and making nothing,
    // exactly as before.
    //
    // sv_squadmaker_spawn remains as the override that forces bodies for the
    // AI-less classes too, for anyone who wants the scenery.
    //
    // Scenery is unconditional now: monster_furniture has no AI and never will,
    // but six of this map's spawners produce set dressing (a bigmac set, a pizza,
    // two sausages, two vegetable trays) and the whole class is a model standing
    // still, which is the one thing a spawner with no AI can do perfectly.
    float is_item   = Squadmaker_IsItem(self.monstertype);
    // The snark is neither an item nor an AI class — its constructor lives in
    // sh_wpn_hlsnark.qc and the creature drives itself.  Third arm, below.
    float is_snark  = (self.monstertype == "monster_snark");
    float want_body = Monster_ClassHasAI(self.monstertype)
                      || Monster_ClassIsScenery(self.monstertype);
    // `&& !is_snark` is load-bearing: without it sv_squadmaker_spawn 1 would ALSO
    // take the want_body arm and stand up a second, inert, modelless body per
    // spawn alongside the real creature.
    if (!want_body && !is_item && !is_snark)
        want_body = cvar("sv_squadmaker_spawn");

    // Concurrent cap.  Enforced for every child that BOOKS A SLOT, which is the
    // change: it used to be gated on Monster_ClassHasAI(monstertype) alone, so a
    // maker whose class has no AI never booked one and free-ran at its `delay`
    // forever.  On this map that is ml_flour5 - monstercount 6, delay 1, an
    // unimplemented babyvoltigore - pumping twelve counts into cnt_flour in six
    // seconds while producing nothing.
    //
    // Still keyed on "will a body appear", not on the cap alone: a maker that
    // produces nothing must keep firing its target chain, because that chain is
    // what advances the map, and a cap it can never come back under would stall
    // the mission outright.  Items are excluded for the same reason from the
    // other side - a healthkit lying on the floor never dies, so counting it
    // would jam its dispenser after m_imaxlivechildren pickups.
    // sv_monster_maxlive scales the cap; 1 leaves the map exactly as authored.
    // Bodies only - the item cap below is deliberately NOT scaled, because
    // multiplying a healthkit dispenser is a supply change, not a difficulty one.
    float bodycap = SV_ScaleMaxLive(self.m_imaxlivechildren);
    if (want_body && bodycap > 0 && self.sq_live_children >= bodycap)
    {
        self.nextthink = time + SV_ScaleSpawnDelay(1);
        self.think     = squadmaker_think;
        return;
    }

    // The same cap for items, counted rather than latched.  It is not optional:
    // every one of this map's 34 item spawners is monstercount -1 with a 5 second
    // delay, so uncapped they would carpet the shop in healthkits and shotgun
    // shells within a minute of the siege starting.
    // Snarks share the item cap — a SCAN, not the sq_live_children latch — and
    // that is deliberate.  A snark leaves the world through remove() in
    // W_SnarkPop and never touches Monster_Teardown / Monster_ReleaseSquadSlot,
    // so a latch would fill up once and jam the maker permanently.  HL has the
    // same jam and just lives with it: SuperBounceTouch nulls pev->owner on the
    // first bounce (squeakgrenade.cpp:331) so CSqueakGrenade::Killed can never
    // send DeathNotice back to the maker, and m_cLiveChildren only ever counts
    // up.  Scan-counting enforces the mapper's cap without inheriting that.
    if ((is_item || is_snark) && self.m_imaxlivechildren > 0
        && Squadmaker_CountLiveItems(self) >= self.m_imaxlivechildren)
    {
        self.nextthink = time + 1;
        self.think     = squadmaker_think;
        return;
    }

    // HL's "don't build a stack of monsters" gate (monstermaker.cpp:180-190).
    // Placed HERE - after both caps, before the budget is consumed - because
    // that is where HL has it: it returns before FireTargets and before
    // m_cNumMonsters--, so a blocked attempt costs the maker nothing and simply
    // comes round again.  Same shape as the over-cap branch above.
    //
    // spawn_mode 2 (FORCE) is exempt by definition: the mapper has said stand it
    // up regardless of what is in the way, which is the same exemption AI_Spawn
    // already honours for .ai_forceplace.
    if (want_body && self.spawn_mode != SQ_SPAWN_FORCE
        && Squadmaker_SpotBlocked(self, self.monstertype))
    {
        if (cvar("sv_debug_monsters"))
            dprint(sprintf("[squadmaker] %s spot at %v occupied - not stacking\n",
                           self.monstertype, self.origin));
        self.think     = squadmaker_think;
        self.nextthink = time + SQ_BLOCK_RETRY;
        return;
    }

    self.sq_spawned_total = self.sq_spawned_total + 1;

    float made = FALSE;
    if (is_item)
    {
        entity it = Squadmaker_SpawnItem(self.monstertype, self.origin);
        if (it)
        {
            it.sq_ownerid = self.sq_id;
            made = TRUE;
        }
    }
    else if (is_snark)
    {
        entity sn = Squadmaker_SpawnSnark(self, self.origin);
        if (sn)
        {
            sn.sq_ownerid = self.sq_id;   // counted by scan — see the cap above
            made = TRUE;
        }
    }
    else if (want_body && self.monstertype != "")
    {
        entity child = Monster_Spawn(self, self.monstertype, self.origin, self.angles);
        // PLACEMENT CAN FAIL, and a failure used to be permanent.  AI_Spawn
        // returns FALSE when the body cannot be stood anywhere and leaves it
        // inert; an inert child can never die, so its slot was never returned -
        // and 72 of this map's 97 makers have m_imaxlivechildren 1, so one blocked
        // spawn killed that spawner for the rest of the map with no diagnostic
        // whatsoever (the only dprint was behind sv_ai_debug, default 0).
        //
        // Half-Life does not have this problem because CMonsterMaker::MakeMonster
        // tests the space FIRST and simply does not spawn (monstermaker.cpp:180),
        // so removing the failed body is the faithful behaviour as well as the
        // one that lets the maker try again next interval.
        //
        // spawn_mode 2 (FORCE) never gets here: AI_Spawn keeps the body and does
        // not set ai_placefail, so the child below is a live monster standing in
        // whatever was in the way.  That is the mapper's explicit choice.
        if (child && child.ai_placefail)
        {
            if (cvar("sv_debug_monsters"))
                dprint(sprintf("[squadmaker] %s could not be placed at %v - retrying (spawn_mode %g)\n",
                               self.monstertype, self.origin, self.spawn_mode));
            Monster_Teardown(child);
            remove(child);
            child = world;

            // spawn_mode 1, "Block, spawn as soon as clear".  The spawn has not
            // happened, so nothing downstream may behave as though it has: give
            // the budget slot back, do NOT fire the target chain, and come round
            // again shortly rather than at the full between-waves delay.
            //
            // Returning here is the whole difference from LEGACY.  Falling
            // through would fire the Death fallback below - which exists so a
            // maker that can never produce a body does not stall the map - and on
            // a maker that is merely blocked for a moment that is a wave counter
            // ticking up for a monster that is still coming.
            if (self.spawn_mode == SQ_SPAWN_BLOCK)
            {
                self.sq_spawned_total = self.sq_spawned_total - 1;
                self.think     = squadmaker_think;
                self.nextthink = time + SQ_BLOCK_RETRY;
                return;
            }
        }
        // Latch the slot ON THE CHILD so Monster_ReleaseSquadSlot can hand back
        // exactly one, exactly once, however the child eventually dies.
        if (child)
        {
            made = TRUE;
            child.sq_counted      = 1;
            self.sq_live_children = self.sq_live_children + 1;
        }
    }
    else if (self.monstertype != "" && self.monstertype)
    {
        // Named something this build has neither AI nor a pickup for.  Once per
        // maker, not once per spawn: these fire on a one-second interval.
        if (!self.sq_warned)
        {
            self.sq_warned = 1;
            dprint(sprintf("[squadmaker] no implementation for \"%s\" - chain still fires\n",
                           self.monstertype));
        }
    }

    if (cvar("sv_debug_monsters"))
    {
        // The child's appearance overrides are folded into one string rather than
        // given two %g slots of their own: fteqcc caps a varargs call at eight
        // parameters INCLUDING the format, and this line was already at eight.
        string look = "";
        if (self.new_body > 0)
            look = sprintf(" body=%g", self.new_body);
        if (self.new_skin > 0)
            look = strcat(look, sprintf(" skin=%g", self.new_skin));
        dprint(sprintf("[squadmaker] %s #%g type=%s item=%g%s made=%g live=%g\n",
                       self.targetname, self.sq_spawned_total, self.monstertype,
                       is_item, look, made,
                       (is_item || is_snark) ? Squadmaker_CountLiveItems(self)
                                             : self.sq_live_children));
    }

    // Fire the chain.  trigger_condition 4 is Sven's "Death" (sven-coop.fgd:5467)
    // and it is what all 28 users on pizza_ya_san1 set - so firing it here, on
    // SPAWN, ran every wave counter one kill ahead of the kills.  cnt_meatshop and
    // cnt_vegeshop want 15 dead stray dogs each and cnt_finale wants 40; with the
    // count arriving at spawn time the shop sequence completed while its dogs were
    // still standing there.  Death now fires from the child (Monster_Killed);
    // every other condition keeps the old spawn-time behaviour, which is wrong for
    // some of them too but is at least no worse than before and never stalls a map.
    if (self.trigger_target != "" && self.trigger_condition > 0
        && self.trigger_condition != SQ_COND_DEATH)
    {
        entity relay = spawn();
        relay.classname = "sq_fire";
        relay.target    = self.trigger_target;
        SUB_UseTargets(relay, activator, USE_TOGGLE);
        remove(relay);
    }
    // ...and if the maker asked for Death but can produce no body at all, fire on
    // spawn anyway.  A map whose progression waits on kills that can never happen
    // is stalled forever, and this entity's first duty is that the mission
    // advances whether or not a monster appeared.
    if (self.trigger_target != "" && self.trigger_condition == SQ_COND_DEATH && !made)
    {
        entity relay2 = spawn();
        relay2.classname = "sq_fire";
        relay2.target    = self.trigger_target;
        SUB_UseTargets(relay2, activator, USE_TOGGLE);
        remove(relay2);
    }
    if (self.target != "")
    {
        // `delay` here is Sven's BETWEEN-SPAWNS interval, not a chain delay —
        // but SUB_UseTargets defers by caller.delay, so leaving it set delays
        // the target chain by the whole spawn interval every wave.  The
        // trigger_target call just above already dodges this by using a
        // throwaway relay; this path did not.
        float saved_delay = self.delay;
        self.delay = 0;
        SUB_UseTargets(self, activator, USE_TOGGLE);
        self.delay = saved_delay;
    }

    // CYCLIC (monstermaker only): one monster per trigger, never a stream.  It
    // must not re-arm the think, or a map that fires it once gets a continuous
    // spawner instead of the single monster it asked for.
    if (self.spawnflags & SQ_SF_CYCLIC)
    {
        self.sq_enabled = 0;
        self.nextthink  = 0;
        return;
    }

    // Reschedule.  `delay` is Sven's between-spawns interval.
    float iv = SV_ScaleSpawnDelay(self.delay);
    if (iv <= 0) iv = SV_ScaleSpawnDelay(1);
    if (self.monstercount < 0 || self.sq_spawned_total < self.monstercount)
    {
        self.think     = squadmaker_think;
        self.nextthink = time + iv;
    }
    else
        self.sq_enabled = 0;
};

void() squadmaker_use =
{
    float mastered = IsMasterTriggered(self.master, activator);

    if (cvar("sv_debug_monsters"))
        dprint(sprintf("[squadmaker] %s use ut=%g master=\"%s\" pass=%g enabled=%g live=%g/%g\n",
                       self.targetname, sub_use_type, self.master, mastered,
                       self.sq_enabled, self.sq_live_children, self.m_imaxlivechildren));

    if (!mastered)
        return;

    // CYCLIC has no on/off state at all - every trigger is one monster.  Checked
    // before the toggle, because toggle semantics would swallow every other
    // press and halve the monster count a map expects.
    if (self.spawnflags & SQ_SF_CYCLIC)
    {
        squadmaker_spawn_one();
        return;
    }

    // HONOUR THE USE TYPE.  This used to be an unconditional toggle that never
    // read sub_use_type, and that is the same swallow-every-other-press bug the
    // CYCLIC branch above is guarding against - just one level up.  A
    // multi_manager or trigger_entity_iterator that fires the SAME non-cyclic
    // maker repeatedly with `triggerstate 1` (USE_ON) was alternately starting
    // and STOPPING it, so a map that re-asserts its spawners on every objective
    // ended up with half of them switched off.
    //
    // Measured on desertcircle: 3 [squadmaker] spawns in a 60 s run.  Its base
    // chain re-fires the makers behind each capture rather than pulsing them
    // once, which is exactly the pattern this punished.
    //
    // == USE_UNSET, not truthiness - USE_OFF is 0 and a ternary throws it away.
    // sv_customdefs.qc:767-792 documents that trap at length, and
    // trigger_entity_iterator_use (sv_goldsrc_entities.qc:254) is the shape
    // being copied here, down to the "already running -> no-op" rule.
    float ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;

    float want;
    if (ut == USE_ON)       want = 1;
    else if (ut == USE_OFF) want = 0;
    else                    want = !self.sq_enabled;

    if (!want)
    {
        self.sq_enabled = 0;
        self.nextthink  = 0;
        return;
    }

    // Already running: re-asserting On must NOT restart the cadence or spawn an
    // extra child, or a map that pulses its makers would spawn on every pulse
    // and outrun its own `delay`.
    if (self.sq_enabled)
        return;

    // Idle -> running.  First child immediately rather than after `delay`.
    self.sq_enabled = 1;
    squadmaker_spawn_one();
};

/*QUAKED squadmaker (.8 .3 .3) (-8 -8 -8) (8 8 8) START_ON
Sven Co-op monster spawner.  The spawner itself is fully implemented; the
BODIES it produces are gated behind sv_squadmaker_spawn (default 0) because
this build has no NPC AI and standing dummies are worse than none.  Target
chains and counters fire either way, so map progression works now.

"monstertype"        classname of the child to spawn
"new_model"          model override for the child
"new_body"           bodygroup override for the child
"netname"            targetname given to each spawned child
"monstercount"       total to spawn (-1 = unlimited)
"m_iMaxLiveChildren" concurrent cap (enforced only once AI exists)
"delay"              seconds between spawns
"health"             child health
"trigger_target"     fired per spawn when trigger_condition is set
"trigger_condition"  Sven condition selector
"target"             fired per spawn, unconditionally
"squadname" "is_squad_leader" "classify" "bloodcolor" "weapons" "gag"
"notsolid" "respawn_as_playerally" "spawn_mode" "displayname"  parsed
"soundlist"          accepted, not implemented (no sound replacement layer)
*/
void() squadmaker =
{
    self.solid     = SOLID_NOT;
    self.movetype  = MOVETYPE_NONE;
    self.modelindex = 0;
    self.use       = squadmaker_use;

    if (!self.monstercount)
        self.monstercount = -1;

    sq_next_id = sq_next_id + 1;
    self.sq_id = sq_next_id;

    // Parse and precache the child's sound replacements NOW, at map parse time,
    // rather than when the first child appears.  FTE can precache at runtime
    // (svcfte_precache, pr_cmds.c:4589) so late would work, but a wave spawning
    // mid-fight is the worst moment to open a file and precache 60 samples.
    if (self.soundlist != "" && self.soundlist)
        self.sl_table = Soundlist_Load(self.soundlist);

    // Activation.  Half-Life's CMonsterMaker::Spawn (dlls/monstermaker.cpp:110-137)
    // has THREE branches and this port only had the first, which is the whole
    // reason pizza_ya_san1 opened on an empty shop counter:
    //
    //     else
    //     {// no targetname, just start.
    //             pev->nextthink = gpGlobals->time + m_flDelay;
    //             m_fActive = TRUE;
    //             SetThink ( &CMonsterMaker::MakerThink );
    //     }
    //
    // A maker with no targetname can never be triggered by anything, so an
    // inactive one would be dead weight in the map - HL therefore runs it
    // unconditionally, and mappers rely on that as the idiom for "this NPC is
    // simply here from the start".  pizza_ya_san1 has exactly three such makers
    // and they are the pizza shop owner, the chief and the leader; ten
    // scripted_sequences address them by netname, so this one branch is also what
    // unblocks the opening scene.  START_ON stays as the explicit form for a maker
    // that IS named and still wants to run from map start.
    float autostart = (self.spawnflags & SQ_SF_STARTON);
    if (!autostart && (self.targetname == "" || !self.targetname))
        autostart = TRUE;

    if (autostart)
    {
        // START_ON plus CYCLIC is contradictory - cyclic means "one per trigger"
        // - and HL resolves it by letting CYCLIC win.  Match that rather than
        // producing a stream from an entity the mapper marked one-shot.
        if (!(self.spawnflags & SQ_SF_CYCLIC))
        {
            self.sq_enabled = 1;
            // Deferred like func_train_find_first — the entities our target chain
            // resolves against have not all spawned yet at map-parse time.
            self.think     = squadmaker_think;
            self.nextthink = time + 0.5;
        }
    }
};

/*QUAKED monstermaker (.8 .3 .3) (-8 -8 -8) (8 8 8) START_ON x CYCLIC MONSTERCLIP
Half-Life's monster spawner — 607 instances across 51 Sven maps, and squadmaker's
twin.  Sven's squadmaker is a strict superset of it, so both run the same code;
the only behaviour monstermaker adds is the CYCLIC spawnflag (4), which makes
each trigger drop exactly one monster instead of starting a stream.

Everything squadmaker parses is accepted here.  The keys HL maps actually use:

"monstertype"        classname of the child to spawn
"netname"            targetname given to each spawned child
"monstercount"       total to spawn (-1 = unlimited)
"m_iMaxLiveChildren" concurrent cap
"delay"              seconds between spawns (ignored when CYCLIC)
"target"             fired per spawn

Bodies appear for classes that have AI; the target chain fires either way, so a
map's progression advances regardless.  See squadmaker above.
*/
void() monstermaker =
{
    squadmaker();
};
