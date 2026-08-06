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
void(entity m)    AI_Died;
float()           Headcrab_DefaultHealth;   // monsters/mon_headcrab.qc
float()           Zombie_DefaultHealth;     // monsters/mon_zombie.qc
float()           Cockroach_DefaultHealth;  // monsters/mon_cockroach.qc
float()           Islave_DefaultHealth;     // monsters/mon_islave.qc
float()           Houndeye_DefaultHealth;   // monsters/mon_houndeye.qc
float()           Grunt_DefaultHealth;      // monsters/mon_grunt.qc
float()           Turret_DefaultHealth;     // monsters/mon_turret.qc
float()           Barnacle_DefaultHealth;   // monsters/mon_barnacle.qc
float()           Scientist_DefaultHealth;  // monsters/mon_grunt.qc
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
.float  is_player_ally;
.float  bloodcolor;
.float  classify;           // Sven CLASS_* relationship override
.float  gag;                // suppress idle speech
.float  notsolid;           // Sven tri-state: -1 = class default, 0 = solid, 1 = not
.float  weapons;            // equipment bitfield for the spawned body

// squadmaker's description of the child it makes
.string monstertype;        // classname to spawn
.string new_model;          // model override for the child
.float  new_body;           // bodygroup override for the child
.float  monstercount;       // total to spawn, -1 = unlimited
.float  m_imaxlivechildren; // concurrent cap
.float  spawn_mode;
.float  respawn_as_playerally;
.string squadname;
.float  is_squad_leader;
.string trigger_target;     // fired when trigger_condition is met
.float  trigger_condition;
.string soundlist;          // sound replacement file — accepted, not implemented

// Live squadmaker bookkeeping
.float  sq_spawned_total;
.float  sq_live_children;
.float  sq_enabled;
.entity sq_owner;           // child -> its maker
.float  sq_counted;         // 1 while this child occupies a slot in sq_owner's count

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
};

void(entity removing) monster_chain_remove =
{
    if (removing == monster_chain_head)
        monster_chain_head = removing.monster_chain_next;

    if (removing.monster_chain_next)
        removing.monster_chain_next.monster_chain_prev = removing.monster_chain_prev;
    if (removing.monster_chain_prev)
        removing.monster_chain_prev.monster_chain_next = removing.monster_chain_next;

    removing.monster_chain_next = world;
    removing.monster_chain_prev = world;
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

    if (!m.sq_owner)
        return;
    m.sq_owner.sq_live_children = m.sq_owner.sq_live_children - 1;
    if (m.sq_owner.sq_live_children < 0)
        m.sq_owner.sq_live_children = 0;
};

// Single teardown point: whatever kills or removes a monster comes through here so
// the chain and the squad count can never disagree with reality.
void(entity m) Monster_Teardown =
{
    Monster_ReleaseSquadSlot(m);
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
    if (cls == "monster_bodyguard")
        return Monster_PickModel("models/bodyguard.mdl", "models/barney.mdl");

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

    // Everything else that walks is human-sized.  Returning TRUE for the default is
    // deliberate: an unknown monster with a human hull is far safer than one
    // wearing whatever box its animation happened to sweep out.
    return TRUE;
};

// Scenery classes.  HL leaves these at the model's (zero) hull, so they never
// block anything - which is the whole point of monster_furniture.
float(string cls) Monster_ClassIsScenery =
{
    if (cls == "monster_furniture")	return TRUE;
    return FALSE;
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
    if (cls == "monster_human_grunt")	return Grunt_DefaultHealth();
    if (cls == "monster_human_grunt_ally")	return Grunt_DefaultHealth();
    if (cls == "monster_male_assassin")	return Grunt_DefaultHealth();
    if (cls == "monster_hwgrunt")	return Grunt_DefaultHealth();
    if (cls == "monster_robogrunt")	return Grunt_DefaultHealth();
    if (cls == "monster_human_assassin")	return Grunt_DefaultHealth();
    if (cls == "monster_shocktrooper")	return Grunt_DefaultHealth();
    if (cls == "monster_bodyguard")	return Barney_DefaultHealth();
    if (cls == "monster_th_grunt_repel")	return Grunt_DefaultHealth();
    if (cls == "monster_barney")	return Barney_DefaultHealth();
    if (cls == "monster_otis")	return Barney_DefaultHealth();
    if (cls == "monster_human_medic_ally")	return Barney_DefaultHealth();
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
void(string cls) Monster_ReportModel =
{
    string mdl = Monster_DefaultModel(cls);
    if (mdl == "" || !mdl)
    {
        dprint(sprintf("[ai-selftest] model %-26s (none)\n", cls));
        return;
    }
    string pack = whichpack(mdl);
    if (pack == "" || !pack)
        dprint(sprintf("[ai-selftest] model %-26s %-30s MISSING\n", cls, mdl));
    else
        dprint(sprintf("[ai-selftest] model %-26s %-30s <- %s\n", cls, mdl, pack));
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
};

// The self-test's consumer.  AI_Init has the other one (AI_WarmClass), and the
// whole point of the shared walker is that neither can now know about a class
// the other does not.
void() Monster_ReportModels =
{
    monster_class_cb = Monster_ReportModel;
    Monster_ForEachAIClass();
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

        if (self.sequence > 0)
            self.frame = self.sequence;
        else if (self.sequencename && self.sequencename != "")
        {
            float seq = frameforname(self.modelindex, self.sequencename);
            if (seq >= 0)
                self.frame = seq;
        }

        BrushSync_ApplyRenderKeys();
    }

    // `angle` is HL entdata's single-axis yaw shortcut; fold it in the same
    // way cycler and item_generic do.
    if (self.angles == '0 0 0' && self.angle != 0)
        self.angles_y = self.angle;

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
        dprint(sprintf("[monster] %s \"%s\" model=%s solid=%g hull %v .. %v\n",
                       self.classname, self.displayname, mdl, self.solid,
                       self.mins, self.maxs));
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
    m.body        = maker.new_body;
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
    m.is_player_ally = maker.respawn_as_playerally;
    // The squad identity was NOT being copied, so every child spawned squadless:
    // HL's squad coordination keys entirely off .squadname, and a squadmaker whose
    // whole purpose is to produce a SQUAD was producing a set of unrelated loners.
    // is_squad_leader rides along for the same reason.
    m.squadname       = maker.squadname;
    m.is_squad_leader = maker.is_squad_leader;
    m.sq_owner    = maker;
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
// W3: the gun shooters.  ~2600 placements on one archetype.
void() monster_human_grunt	= { Monster_MapPlaced(); };
void() monster_human_grunt_ally	= { Monster_MapPlaced(); };
void() monster_hwgrunt	= { Monster_MapPlaced(); };
void() monster_robogrunt	= { Monster_MapPlaced(); };
void() monster_shocktrooper	= { Monster_MapPlaced(); };
void() monster_bodyguard	= { Monster_MapPlaced(); };
void() monster_th_grunt_repel	= { Monster_MapPlaced(); };
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

    // Concurrent cap.  Without AI nothing ever dies, so live_children would
    // pin at the cap forever and the target chain below would stop firing —
    // which is precisely the progression stall this entity must not cause.
    // Only enforce the cap once bodies are real.
    //
    // nettest: asks about the CHILD's class, not the squadmaker's own classname.
    // Monster_HasAI() reads self.classname, and self here is the squadmaker, so the
    // old call could only ever have answered for "squadmaker" itself.  The cap must
    // track whether the thing being spawned can die and give its slot back.
    if (Monster_ClassHasAI(self.monstertype) && self.m_imaxlivechildren > 0
        && self.sq_live_children >= self.m_imaxlivechildren)
    {
        self.nextthink = time + 1;
        self.think     = squadmaker_think;
        return;
    }

    self.sq_spawned_total = self.sq_spawned_total + 1;

    // Produce a BODY when the child's class can actually behave, and only then.
    //
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
    float want_body = Monster_ClassHasAI(self.monstertype);
    if (!want_body)
        want_body = cvar("sv_squadmaker_spawn");

    if (want_body && self.monstertype != "")
    {
        entity child = Monster_Spawn(self, self.monstertype, self.origin, self.angles);
        // Latch the slot ON THE CHILD so Monster_ReleaseSquadSlot can hand back
        // exactly one, exactly once, however the child eventually dies.
        if (child)
        {
            child.sq_counted      = 1;
            self.sq_live_children = self.sq_live_children + 1;
        }
    }

    // Fire the chain regardless of whether a body appeared.  This is what
    // advances game_counters and wave logic.
    if (self.trigger_target != "" && self.trigger_condition > 0)
    {
        entity relay = spawn();
        relay.classname = "sq_fire";
        relay.target    = self.trigger_target;
        SUB_UseTargets(relay, activator, USE_TOGGLE);
        remove(relay);
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
    float iv = self.delay;
    if (iv <= 0) iv = 1;
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
    if (!IsMasterTriggered(self.master, activator))
        return;

    // CYCLIC has no on/off state at all - every trigger is one monster.  Checked
    // before the toggle, because toggle semantics would swallow every other
    // press and halve the monster count a map expects.
    if (self.spawnflags & SQ_SF_CYCLIC)
    {
        squadmaker_spawn_one();
        return;
    }

    // Toggle semantics: a squadmaker that is running stops, one that is idle
    // starts and spawns its first child immediately rather than after `delay`.
    if (self.sq_enabled)
    {
        self.sq_enabled = 0;
        self.nextthink  = 0;
        return;
    }

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

    if (self.spawnflags & SQ_SF_STARTON)
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
