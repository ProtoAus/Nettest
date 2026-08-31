// server/sv_ai_core.qc
// ----------------------------------------------------------------------------
// The decision loop: conditions in, schedule selected, tasks run.
//
// This is the file that turns the three layers below it into a monster.  It owns
// the per-monster think, the condition gathering, the generic schedule choice,
// and the task interpreter.  Per-class behaviour arrives through the .ai_*
// virtuals, never through a classname test in here - the only classname test in
// the whole AI layer is AI_ClassHasAI, which exists precisely so a class can be
// switched on one at a time.
//
// SCHEDULING FOR 50+ MONSTERS.  Nothing here is O(monsters) per frame: each
// monster runs on its own .nextthink under MOVETYPE_STEP, staggered at spawn.
// The two costs that DO scale are line-of-sight traces and path searches, and
// both are capped globally - traces by ai_trace_budget below, paths by B1's
// request queue, which this file only ever feeds through Nav_RequestPath.
// ----------------------------------------------------------------------------

// The two Stage 3a per-map census lines AI_Tick prints on its first frame.
// server/sv_checkpoint.qc and server/sv_chargers.qc both compile below us (they
// need sv_player.qc's and sv_goldsrc_pickups.qc's symbols respectively), so
// they are reached the same way every per-class entry point below is.
void() Checkpoint_Report;
void() Charger_Report;

// Per-class entry points, resolved by forward declaration so the class files can
// live after this one in compile order and still be reachable.
void(entity m) Headcrab_ClassInit;
void()         Headcrab_Precache;
float()        Headcrab_DefaultHealth;
void(entity m) Zombie_ClassInit;
void()         Zombie_Precache;
float()        Zombie_DefaultHealth;
void(entity m) ZombieBarney_ClassInit;
void(entity m) ZombieSoldier_ClassInit;
void()         ZombieVariants_Precache;
void(entity m) Cockroach_ClassInit;
void()         Cockroach_Precache;
float()        Cockroach_DefaultHealth;
void(entity m) Islave_ClassInit;
void()         Islave_Precache;
float()        Islave_DefaultHealth;
void(entity m) Houndeye_ClassInit;
void()         Houndeye_Precache;
float()        Houndeye_DefaultHealth;
void(entity m) HGrunt_ClassInit;
void(entity m) HGruntAlly_ClassInit;
void(entity m) HWGrunt_ClassInit;
void(entity m) Assassin_ClassInit;
// Re-points .ai_event at the handler the RESOLVED MODEL's event codes belong to.
void(entity m) Grunt_RigOverride;
void(entity m) Grunt_LoadoutInit;
void(entity m) Grunt_BodyInit;
void(entity m) Shocktrooper_ClassInit;
void(entity m) Robogrunt_ClassInit;
void(entity m) Barney_ClassInit;
void(entity m) Scientist_ClassInit;
float()        Scientist_DefaultHealth;
void(entity m) Generic_ClassInit;
float()        Generic_DefaultHealth;
void(entity m) Gargantua_ClassInit;
// The flame sweep's per-tick driver and its shut-off, reached from
// TASK_FLAME_SWEEP below.  Forward-declared because the task interpreter lives
// here and the class file compiles after it.
void(entity m, float dt) Garg_FlameUpdate;
void(entity m) Garg_FlameOff;
float()        Gargantua_DefaultHealth;
void(entity m) Babygarg_ClassInit;
float()        Babygarg_DefaultHealth;
void(entity m) Stukabat_ClassInit;
float()        Stukabat_DefaultHealth;
void(entity m) Kingpin_ClassInit;
float()        Kingpin_DefaultHealth;
void(entity m) BigMomma_ClassInit;
float()        BigMomma_DefaultHealth;
// The eight node tasks' bodies, reached from the interpreter below.  Same
// arrangement and the same reason as Garg_FlameUpdate above: the tasks are
// interpreted here and the class that owns their meaning compiles at :292.
void(entity m) BigMomma_NodeStart;	// resolve ai_bm_next into ai_bm_node
void(entity m) BigMomma_NodeReach;	// arrive: health, reachtarget, advance
float(entity m) BigMomma_NodeRange;	// the node's `radius`, or HL's 1e6 default
float(entity m) BigMomma_NodeDelay;	// the node's `reachdelay`
float(entity m) BigMomma_NodeWaits;	// SF_INFOBM_WAIT: hold here indefinitely
float(entity m) BigMomma_NodeRuns;	// SF_INFOBM_RUN: run rather than walk
float(entity m) BigMomma_NodeYaw;	// the node's own yaw, or keep the current one
float(entity m, float pre) BigMomma_NodeSeq;	// start presequence/reachsequence
void(entity m) Apache_ClassInit;
float()        Apache_DefaultHealth;
void(entity m) Osprey_ClassInit;
float()        Osprey_DefaultHealth;
void()         Bosses_Precache;
void()         BigFoes_Precache;
void()         Grunt_Precache;
void(entity m) Agrunt_ClassInit;
float()        Agrunt_DefaultHealth;
void(entity m) Bullsquid_ClassInit;
float()        Bullsquid_DefaultHealth;
void(entity m) Pitdrone_ClassInit;
float()        Pitdrone_DefaultHealth;
void(entity m) Gonome_ClassInit;
float()        Gonome_DefaultHealth;
void(entity m) Voltigore_ClassInit;
void(entity m) BabyVoltigore_ClassInit;
float()        Voltigore_DefaultHealth;
void()         Aliens_Precache;
void(entity m) Sentry_ClassInit;
void(entity m) Miniturret_ClassInit;
void(entity m) Turret_ClassInit;
void(entity m) Leech_ClassInit;
float()        Leech_DefaultHealth;
void(entity m) Ichthyosaur_ClassInit;
float()        Ichthyosaur_DefaultHealth;
void(entity m) Controller_ClassInit;
float()        Controller_DefaultHealth;
void(entity m) Barnacle_ClassInit;
float()        Barnacle_DefaultHealth;
void()         Barnacle_Precache;
void()         SwimFly_Precache;
void()         Turret_Precache;
float()        Turret_DefaultHealth;
float()        Grunt_DefaultHealth;
float()        Barney_DefaultHealth;

void()         Monster_ReportModels;	// sv_monsters.qc; the boot model inventory
void()         AI_ReportStats;		// defined at the end; AI_Tick drives it
void()         Monster_Chain_Verify;	// sv_monsters.qc; list repair, driven from AI_Tick

// Both live in files that compile AFTER this one (sv_sentences.qc :264 and
// sv_scripted.qc :272 against our :240), and AI_ToggleFollow needs them to make
// +use a no-op during a scene the way GoldSrc does.
float(entity e) Sentences_Speaking;
float(entity m) Script_CanInterrupt;

const float AI_TICK       = 0.1;	// decision rate, awake.  Half-Life's is the same.
const float AI_TICK_IDLE  = 0.5;	// ...and dormant, with nobody near
const float AI_HEAVY_DMG  = 20;		// >= this in one hit is COND_HEAVY_DAMAGE (HL's figure)
const float AI_FLINCH_GAP = 2.0;	// minimum seconds between flinches
// A monster DENIED A SQUAD SLOT is not on cooldown - it is ready to fire and is
// being rationed, possibly for a long time.  Standing at the edge of its own
// range for that whole period is most of what reads as "passive" in a firefight.
// So the stand-and-face band is TIGHTER for a denied monster than for one waiting
// out a cooldown: it closes to this fraction of its ranged range first.
//
// Deliberately not a chase to contact.  SCHED_CHASE_ENEMY completes on arrival,
// so a monster that is already close would arrive on the first tick, re-select
// and churn - the 17-arrivals-per-2s thrash the COND_SEE_ENEMY block below was
// written to stop.  Closing to a band and then holding has neither problem, and
// chase carries COND_ATTACK_READY in its interrupt mask (sv_ai_sched.qc:526-528),
// so the advance is abandoned mid-stride the moment a slot frees up.
const float AI_DENIED_CLOSE_FRAC = 0.4;
// How long a monster that failed to find cover waits before looking again.  A
// search is a gather plus up to COVER_TRACE_MAX tracelines, and the answer in an
// open room does not change from one tick to the next; without this floor a
// monster under fire in the open runs the whole search ten times a second for
// the length of the fight.  Long enough to matter, short enough that a monster
// which has since moved gets a fresh answer.
const float AI_COVER_RETRY = 3.0;

// Cached once per frame in AI_Tick.  Never call cvar() per monster per tick -
// sv_main.qc already caches hot cvars for exactly this reason (sv_main.qc:1028),
// after per-entity cvar() reads were measured costing thousands of string
// hashes a second.
// ai_cached_enable / _sight / _debug are declared in sv_ai_defs.qc: the movement
// and animation layers compile before this file and read them for diagnostics.
float ai_trace_budget;			// LOS traces left this frame
float ai_dbg_traces;			// diagnostics: traces actually spent
float ai_dbg_tracedenied;		// ...and checks skipped because the budget ran out
float ai_dbg_thinks;
// Scripted scenes that ended badly.  Declared here rather than with the other
// script counters in sv_scripted.qc because this file is what increments them -
// the interpreter for the first, the damage and death paths for the second - and
// it compiles first.
float ai_dbg_script_stuck;	// walks that gave up short of the mark
float ai_dbg_script_broke;	// scenes cut short by damage or death

// "I was still holding a corpse as my enemy."  One per kill is correct - the very
// next condition pass after a monster dies.  A number that keeps climbing means
// the deadflag test in AI_ValidEnemy is not doing its job and guards are back to
// emptying magazines into bodies.
float ai_dbg_corpse_enemy;

// Defined near the bottom of this file.  Forward-declared because two things
// above it need to compare a monster's .think against it: the gunfire sweep and
// (through sv_scripted.qc) script possession.  "Does this entity think with the
// AI" is the only reliable way to tell a real monster from one of the posed
// bodies in mon_corpses.qc - both carry FL_MONSTER and both sit on the chain.
void() AI_Think;

// One-shot latch per opcode for the "no interpreter case" gripe in AI_TaskStart.
// Without it a schedule containing an unhandled opcode would print once per
// monster per tick and bury the log it is trying to make readable.
float ai_op_griped[TASK_OP_COUNT];

// ---------------------------------------------------------------------------
// attack cadence
// ---------------------------------------------------------------------------
// How long a shooter waits between attack SEQUENCES.
//
// WHAT HALF-LIFE ACTUALLY DOES, because the obvious guess is wrong: its shooters
// have almost no cooldown.  CBarney never assigns m_flNextAttack anywhere, and
// CHGrunt::CheckRangeAttack1 (hgrunt.cpp:444-468) has no time gate either - it
// tests occlusion, distance and friendly fire and nothing else, and tlGruntSuppress
// (hgrunt.cpp:1423-1441) chains FIVE TASK_RANGE_ATTACK1 with no gap at all.  The
// firing animation IS the rate limit.  Barney then speeds even that up:
// CBarney::RunTask sets pev->framerate = 1.5 on the firing sequence when his enemy
// is a player (barney.cpp:223-238), so his 0.84 s shootgun plays in 0.56 s.
//
// THAT LAST PART IS NOT REPRODUCIBLE HERE and the limitation is worth stating
// rather than faking.  An HL model's playback clock is never networked: the client
// derives it in CL_LerpNetFrameState from when .frame last CHANGED and plays the
// sequence at the model's own fps (see the header of sv_ai_anim.qc).  There is no
// server-side framerate multiplier to set.  So the floor here is one attack per
// sequence length, which for Barney is 0.84 s against Half-Life's 0.56 s.  Making
// that exact needs .framerate in entity_state_t, which is the same kind of engine
// change as the bodygroup work.
//
// Against the 1.2 s flat cooldown this replaces - which sat ON TOP of the 0.84 s
// animation, for ~2.0 s per round - close-range fire is still about 2.4x faster.
//
// THE DISTANCE TERM is not Half-Life's; it was asked for, and it is why
// sv_ai_range_cadence exists.  At 0 this function is exactly Half-Life.  Above 0 a
// shooter gets slower as its target gets further away, up to
// AI_RANGE_CADENCE_MAX extra seconds at the edge of its own range.  The random
// jitter rides INSIDE the distance term deliberately, so turning the term off
// leaves no invented randomness behind.
const float AI_RANGE_CADENCE_MAX = 0.8;

void(entity m) AI_ArmAttackCooldown =
{
	float d = m.ai_attackrate;
	if (d < 0)
		d = 0;

	float k = cvar("sv_ai_range_cadence");
	if (k > 0 && m.ai_enemy && m.ai_range_range > 0)
	{
		float frac = vlen(m.ai_enemy.origin - m.origin) / m.ai_range_range;
		if (frac > 1)
			frac = 1;
		d = d + AI_RANGE_CADENCE_MAX * k * frac * (0.75 + random() * 0.5);
	}

	// A FLOOR, never a cap, and this matters: several classes still arm their own
	// longer cooldown from inside their event handler (the bullsquid's 2.5 s, the
	// islave's, the houndeye's 3 s).  Those handlers run DURING the sequence and
	// this runs at the end of it, so a plain assignment here would silently
	// overwrite every one of them with a shorter one and turn every alien in the
	// game into a machine gun.  Taking the later of the two leaves per-class
	// tuning alone and only ever adds the rate limit that was missing.
	float t = time + d;
	if (t > m.ai_nextattack)
		m.ai_nextattack = t;
};

// ---------------------------------------------------------------------------
// enemy validity and sighting
// ---------------------------------------------------------------------------
float(entity m, entity e) AI_ValidEnemy =
{
	if (e == world)			return FALSE;
	if (e == m)			return FALSE;

	// THE deadflag TEST, and it is not redundant with the health test below.
	//
	// Half-Life's IsAlive (cbase.h:204) is `deadflag == DEAD_NO && health > 0`,
	// BOTH halves - because BecomeDead (combat.cpp:518-532) deliberately hands the
	// corpse max_health/2 health so it has a gib pool.  We ported BecomeDead in
	// AI_Died and not the test it exists for, so a barney corpse sat at ~17 health,
	// passed every check here, and its killer went on shooting it forever:
	// COND_ENEMY_DEAD is raised ONLY from !AI_ValidEnemy (AI_GatherConditions
	// below), so the clear-and-stand branch in AI_SelectSchedule was unreachable
	// and every combat schedule's ENEMY_DEAD interrupt bit was dead code.
	//
	// Note the SOLID_NOT test below does not catch it either, in EITHER direction:
	// a corpse used to be SOLID_SLIDEBOX and is now SOLID_CORPSE (5), never 0.
	if (e.deadflag != DEAD_NO)	return FALSE;

	if (e.health <= 0)		return FALSE;
	if (e.solid == SOLID_NOT)	return FALSE;	// spectating / dead / not in the world

	// A player or another monster.  Anything else is scenery.
	if (e.classname != "player" && !(e.flags & FL_MONSTER))
		return FALSE;

	// PRISONER, both ways round.  HL's CBaseMonster::IRelationship has no such
	// rule; the flag is checked at the two ends instead (monsters.cpp's
	// BestVisibleEnemy skips a prisoner, and a prisoner's own enemy selection is
	// never run because it holds no combat schedule).  One test here reaches both
	// halves and cannot drift.
	//
	// Placed after the scenery test so a prisoner still counts as "a body" to
	// anything that only asks whether an edict is a monster at all, and before the
	// faction gate so no relationship lookup is spent on a fight that cannot start.
	if (m.ai_prisoner || e.ai_prisoner)
		return FALSE;

	// m == world is the spawn test asking "is this a player worth spawning
	// around", not a monster picking a fight.  It has no faction, so the
	// relationship test is skipped and the old player-only rule applies.
	if (m == world)
		return e.classname == "player";

	// THE FACTION GATE.  Without this every monster treated every player as an
	// enemy, which since W3 has meant barney, otis and the ally grunts shooting
	// the people they escort - roughly 800 placements of allies behaving as
	// hostiles.  Fear counts as a valid target: a scientist that fears a headcrab
	// still needs it as its .ai_enemy so it knows what to run away FROM.
	// AI_RelationshipEnt, not AI_Relationship: the entity-level form applies the
	// PROVOKED override (sv_ai_factions.qc), which is what lets a Barney the
	// player has shot adopt that player as an enemy.  The class matrix alone says
	// R_ALLY and always will - it has no way to know about the individual.
	float r = AI_RelationshipEnt(m, e);
	return (r >= R_DISLIKE || r == R_FEAR);
};

// Eye position.  GoldSrc monster origins are at the FEET, so a trace from
// .origin starts inside the floor on any slope and reports blocked.
vector(entity m) AI_EyePos =
{
	vector p = m.origin;
	p_z = p_z + m.maxs_z * 0.8;
	return p;
};

// Budgeted line of sight.  When the budget is spent the caller is told "not
// visible" for this tick only - the monster keeps its previous conditions and
// re-checks next tick.  Degrading to "did not see" rather than "saw" is the safe
// direction: a monster that notices you a tenth of a second late is invisible to
// a player, whereas one that shoots through a wall is not.
float(entity m, entity e) AI_CanSee =
{
	if (ai_trace_budget <= 0)
	{
		ai_dbg_tracedenied = ai_dbg_tracedenied + 1;
		return FALSE;
	}
	ai_trace_budget = ai_trace_budget - 1;
	ai_dbg_traces = ai_dbg_traces + 1;

	// MOVE_NOMONSTERS clips against BSP only, which is what HL's FVisible does
	// (ignore_monsters): monsters must not blind each other by standing in the
	// way, or a squadmaker wave becomes a queue of blind monsters behind one.
	traceline(AI_EyePos(m), AI_EyePos(e), MOVE_NOMONSTERS, m);
	if (trace_fraction == 1)
		return TRUE;
	return trace_ent == e;
};

// FInViewCone.  Is `e` inside this monster's field of view?
//
// SEPARATE FROM AI_CanSee ON PURPOSE, and Half-Life draws the same line: Look()
// tests FInViewCone && FVisible, but FVisible on its own has no cone at all.  So
// the cone gates ACQUIRING a target and nothing else - once a monster has you it
// tracks you, shoots at you and validates cover against you from any angle, which
// is what stops a grunt losing its enemy every time it turns to sidestep.
//
// Measured against the monster's BODY yaw rather than ai_yaw_ideal: the ideal is
// where it wants to be looking, and using it would let a monster see behind itself
// for as long as it took to turn round.  Pitch is dropped for the same reason HL's
// is - a target above or below you is still in front of you.
float(entity m, entity e) AI_InViewCone =
{
	// -1 is VIEW_FIELD_FULL: 360 degrees, no cone to fail.  NOT `<= 0` - HL's
	// wide cones are NEGATIVE dots (VIEW_FIELD_WIDE is -0.7, i.e. 270 degrees
	// across) and treating those as "no cone" would silently hand a 270-degree
	// monster a 360-degree head.
	if (m.ai_fov <= -1)
		return TRUE;

	vector d = e.origin - m.origin;
	d_z = 0;
	if (vlen(d) < 1)
		return TRUE;			// on top of us; the cone is meaningless

	makevectors([0, m.angles_y, 0]);
	if ((normalize(d) * v_forward) >= m.ai_fov)
		return TRUE;
	ai_dbg_fov_rejected = ai_dbg_fov_rejected + 1;
	return FALSE;
};

// Best valid enemy: RELATIONSHIP FIRST, distance only as the tiebreak.  Walks the
// player chain rather than find()ing, so it costs one pointer chase per player.
//
// The ordering is Half-Life's, and not having it was the "NPCs don't get aggroed
// by the correct NPC" half of the report.  BestVisibleEnemy (monsters.cpp:2428-2472)
// takes anything it dislikes MORE without even measuring the range - "No need to do
// a distance check", as Valve's own comment puts it - and only compares distance
// within a relationship tier.  This used to run both sweeps against a single shared
// `bestd`, so an R_DISLIKE monster two feet away beat an R_HATE player ten feet
// away, and a grunt would turn its back on you to swat something it merely disliked.
//
// bestr starts below R_NONE so the first valid candidate of any tier always wins;
// AI_ValidEnemy has already rejected anything below R_DISLIKE (bar R_FEAR, which is
// the scientist's "enemy" and is deliberately admitted).
// How far THIS monster can acquire.  .ai_sight overrides the global when a class
// sets it; everything that does not set it keeps sv_ai_sight exactly as before.
float(entity m) AI_SightRange =
{
	if (m.ai_sight > 0)
		return m.ai_sight;
	return ai_cached_sight;
};

entity(entity m) AI_FindEnemy =
{
	entity best  = world;
	float  sight = AI_SightRange(m);
	float  bestd = sight;
	float  bestr = -99;
	float  r;
	entity p = player_chain_head;

	while (p)
	{
		if (AI_ValidEnemy(m, p))
		{
			float d = vlen(p.origin - m.origin);
			if (d < sight)
			{
				r = AI_RelationshipEnt(m, p);
				// Strictly better tier, or same tier and nearer.
				if (r > bestr || (r == bestr && d < bestd))
				{
					// Cone before trace: it is free, and it rejects most of the
					// candidates a trace would otherwise be spent on - AI_CanSee
					// draws on a per-frame budget shared by every monster.
					if (AI_InViewCone(m, p) && AI_CanSee(m, p))
					{
						best  = p;
						bestd = d;
						bestr = r;
					}
				}
			}
		}
		p = p.player_chain_next;
	}

	// Monster-vs-monster.  Allies have to be able to find something to shoot, and
	// a scientist has to be able to see the headcrab it is running from.
	//
	// THROTTLED, and that matters: the player sweep is O(players) but this one is
	// O(monsters), and th_ep1_01 builds 209 of them.  Running it every tick for
	// every awake monster is the one genuinely quadratic thing this AI could do,
	// so each monster sweeps at most twice a second and only while it has no
	// enemy at all.  The LOS traces stay on the same global budget as everything
	// else, so a crowded room degrades by noticing late rather than by stalling.
	if (time < m.ai_nextscan)
		return best;
	m.ai_nextscan = time + 0.5;

	entity q = monster_chain_head;
	while (q)
	{
		if (q != m && AI_ValidEnemy(m, q))
		{
			float dq = vlen(q.origin - m.origin);
			// Against the sight range, not against bestd: a monster in a HIGHER
			// relationship tier than whatever the player sweep found must still be
			// considered even if it is further away, which is the whole point of
			// the ordering.  The tier comparison below is what decides.
			if (dq < sight)
			{
				r = AI_RelationshipEnt(m, q);
				if (r > bestr || (r == bestr && dq < bestd))
				{
					if (AI_InViewCone(m, q) && AI_CanSee(m, q))
					{
						best  = q;
						bestd = dq;
						bestr = r;
					}
				}
			}
		}
		q = q.monster_chain_next;
	}
	return best;
};

// Cheapest possible proximity test: no traces, no LOS, just "is any live player
// within sight range".  This is the gate that keeps a map full of sleeping
// monsters free.
float(entity m) AI_AnyPlayerNear =
{
	entity p = player_chain_head;
	float r = ai_cached_sight;
	while (p)
	{
		// A LIVENESS test, deliberately not AI_ValidEnemy.  This is the dormancy
		// gate - "is anybody around for anything to happen" - and using the enemy
		// test here meant that the moment the faction matrix stopped allies from
		// treating players as enemies, every ally also stopped WAKING UP: barney
		// and the scientists went permanently dormant and never fought the
		// monsters they are supposed to fight.  Measured as zero schedule
		// selections from eight barneys in 45 seconds.
		if (p.health > 0 && p.solid != SOLID_NOT)
			if (vlen(p.origin - m.origin) < r)
				return TRUE;
		p = p.player_chain_next;
	}
	return FALSE;
};

// ---------------------------------------------------------------------------
// conditions
// ---------------------------------------------------------------------------
// Damage bits are NOT recomputed here - they are latched by AI_Damaged when the
// hit lands and cleared by whichever schedule consumes them.  Recomputing them
// per tick would mean a hit taken between ticks is silently lost.
void(entity m) AI_GatherConditions =
{
	int c = m.ai_cond;

	// Drop everything this function owns, then re-derive it.
	c = c & ~(COND_SEE_ENEMY | COND_ENEMY_DEAD | COND_ENEMY_OCCLUDED
	        | COND_ENEMY_TOOFAR | COND_CAN_MELEE1 | COND_CAN_RANGE1
	        | COND_ENEMY_FACING_ME);

	if (m.ai_enemy)
		if (!AI_ValidEnemy(m, m.ai_enemy))
		{
			// Split out for measurement: "a corpse was still my enemy" is the
			// exact defect the deadflag test was added for, and it needs to be
			// separable from the ordinary cases (enemy left, enemy despawned).
			// It should be non-zero for exactly one tick per kill and never grow
			// after that.
			if (m.ai_enemy.deadflag != DEAD_NO)
				ai_dbg_corpse_enemy = ai_dbg_corpse_enemy + 1;

			c = c | COND_ENEMY_DEAD;
			m.ai_cond = c;
			return;
		}

	if (!m.ai_enemy)
	{
		// Only go looking when something is plausibly there.  AI_FindEnemy costs
		// a trace per candidate; AI_AnyPlayerNear costs none.
		if (AI_AnyPlayerNear(m))
			m.ai_enemy = AI_FindEnemy(m);
		if (!m.ai_enemy)
		{
			m.ai_cond = c;
			return;
		}

		// WHEN this engagement started.  Half-Life expresses "I have only just
		// seen you" as bits_COND_NEW_ENEMY, which this tree has never had (see the
		// note in Grunt_SelectSched); a timestamp is the same information and costs
		// one float.  What reads it is the grenade gate, because HL's whole
		// first-contact branch (hgrunt.cpp GetSchedule, MONSTERSTATE_COMBAT) is
		// reached BEFORE the grenade branch and returns suppressing fire, cover or
		// establish-line-of-fire - never a throw.
		m.ai_enemy_since = time;

		// THE CALLOUT.  This monster has just found an enemy on its own, so the
		// rest of its squad is told - squadmonster.cpp:244-276.  Here rather than
		// anywhere else because this is the ONE place in the tree where a monster
		// acquires an enemy by looking; AI_Damaged's adoption is being shot at,
		// which needs no announcement to be believable, and a squadmate handed an
		// enemy by Squad_MakeEnemy must not re-announce it or a four-man squad
		// would broadcast sixteen times for one sighting.
		Squad_MakeEnemy(m, m.ai_enemy);
	}

	entity e = m.ai_enemy;

	// THE NEAREST POINT OF THE ENEMY, not its origin.  Half-Life's CheckEnemy
	// (dlls/monsters.cpp) measures three times - to the origin, to the head
	// (origin + size.z) and to the feet (origin - size.z) - and keeps the
	// smallest:
	//
	//     flDistToEnemy = (vecEnemyPos - pev->origin).Length();
	//     vecEnemyPos.z += pEnemy->pev->size.z;      // head
	//     ... if closer, take it; else try feet ...
	//
	// Every range decision downstream runs off that number, and using the origin
	// alone is what made a player standing on anything unattackable: a zombie's
	// melee reach is ~70 units, a player on a 40-unit tombstone puts their ORIGIN
	// 40 units up and out of range, and the zombie stands at the foot of the stone
	// with nothing to do - while the player's FEET are a few units from its hands.
	// That is the reported "NPCs have no clue what to do when I stand on a
	// tombstone, they could just melee forward".
	//
	// It cuts the other way too and that is also HL: a monster on a ledge above
	// you gets the same three-point measure and can reach down.
	vector epos = e.origin;
	float d = vlen(epos - m.origin);
	float dz = e.maxs_z - e.mins_z;                  // pev->size.z
	float d2 = vlen((epos + [0, 0, dz]) - m.origin); // head
	if (d2 < d)
		d = d2;
	else
	{
		d2 = vlen((epos - [0, 0, dz]) - m.origin);   // feet
		if (d2 < d)
			d = d2;
	}

	if (d > AI_SightRange(m))
		c = c | COND_ENEMY_TOOFAR;

	if (AI_CanSee(m, e))
	{
		c = c | COND_SEE_ENEMY;
		m.ai_lastseen    = time;
		m.ai_lastseenpos = e.origin;

		// RE-AIM THE CHASE AT WHERE THE ENEMY IS NOW.
		//
		// The tail of Half-Life's CheckEnemy, and it is the whole of what "monsters
		// walk to where I WAS" is:
		//
		//     if ( m_movementGoal == MOVEGOAL_ENEMY )
		//         for ( i = m_iRouteIndex; i < ROUTE_SIZE; i++ )
		//             if ( m_Route[i].iType == (bits_MF_IS_GOAL|bits_MF_TO_ENEMY) )
		//                 if ( (m_Route[i].vecLocation - m_vecEnemyLKP).Length() > 80 )
		//                     FRefreshRoute();
		//                                                    -- dlls/monsters.cpp
		//
		// TASK_GET_PATH_ENEMY asks for a route ONCE, when the chase schedule is
		// selected, and nothing here refreshed it afterwards - so a monster that
		// started chasing you across a room walked the whole way to the spot you
		// were standing in when it set off, arrived, re-decided, and only then set
		// out for wherever you had got to.  Against a moving player that reads
		// exactly as "they ignore me and walk somewhere else".
		//
		// No AI_PathClear: the request is asynchronous (Nav_RequestPath queues it)
		// and the existing route still ends somewhere useful in the meantime, so
		// throwing it away first would strand the monster for as long as the queue
		// takes - the same trap TASK_GET_PATH_FOLLOW documents at length below.
		// AI_PathRequest's own AI_REPATH_OK throttle is what stops this becoming a
		// per-tick flood, and it re-stamps .ai_goalpos on success so the test
		// settles until the enemy has moved another 80 units.
		if (m.ai_sched == SCHED_CHASE_ENEMY
		    && vlen(m.ai_goalpos - e.origin) > AI_ENEMY_REPATH_DIST)
			AI_PathRequest(m, e.origin);

		// Raised only WITH sight, deliberately.  "Is that thing looking at me" is a
		// question a monster can only answer about something it can see, and
		// deriving it from angles alone would let a monster through a wall know it
		// was being aimed at.  It costs no trace - the sight test above already
		// paid for that - so it is free to compute here and nowhere else.
		if (Cover_EnemyFacingMe(m, e))
		{
			c = c | COND_ENEMY_FACING_ME;
			ai_dbg_cover_facing = ai_dbg_cover_facing + 1;
		}

		// Attack ranges are only meaningful with sight, which is what stops a
		// monster striking through a door it happens to be standing against.
		//
		// The cooldown gate belongs HERE and not in schedule selection, and that
		// distinction was worth a measured bug: filtering it during selection
		// left the condition set every tick, so a monster inside attack range but
		// on cooldown had its chase schedule interrupted by COND_ATTACK_READY,
		// re-selected, restarted at task 0, and never reached the task that
		// walks.  Measured as 137 chase selections against 27 walkmoves.  A
		// condition that is not true must not be SET; suppressing it downstream
		// is not the same thing.  HL agrees - CheckRangeAttack1 opens with
		// `if (m_flNextAttack > gpGlobals->time) return FALSE`.
		if (time >= m.ai_nextattack)
		{
			if (m.ai_melee_range > 0 && d <= m.ai_melee_range)
				c = c | COND_CAN_MELEE1;
			if (m.ai_range_range > 0 && d <= m.ai_range_range)
				c = c | COND_CAN_RANGE1;
		}
	}
	else
		c = c | COND_ENEMY_OCCLUDED;

	m.ai_cond = c;

	// Class veto, for preconditions only that class knows about - a headcrab
	// cannot leap while already airborne.  Same reasoning as above: it runs here,
	// while the conditions are being decided, not later while they are being
	// acted on.
	if (m.ai_checkattack)
		if (m.ai_cond & COND_ATTACK_READY)
		{
			entity oldself = self;
			self = m;
			m.ai_checkattack();
			self = oldself;
		}
};

// The CTalkMonster layer (server/sv_ai_talk.qc).  It compiles AFTER this file
// because it speaks through the sentence table, so its two entry points are
// forward-declared here: the +use path turns a talker's head, and the think runs
// its per-tick behaviour.
void(entity m, entity targ) AI_LookAt;
void(entity m)              AI_TalkTick;
void(entity m, string grp)  AI_MakeTalker;	// used by the class inits, also earlier
void()                      AI_ReportTalk;
// Speak a topic from this monster's sentence group, honouring PRE-DISASTER.
// Returns FALSE for a class that has no group at all (the aliens, the grunts),
// which is what lets every caller keep a text fallback.
float(entity m, string topic, float chan, float attn) AI_TalkSay;
// A player hurt this talker.  Owns HL's whole provoke escalation plus the
// "somebody tell him to stop shooting my friend" notification, both of which
// need the sentence layer and so cannot live in this file.
void(entity m, entity plyr, float dmg) AI_TalkDamaged;

// The scripted_sequence layer (server/sv_scripted.qc).  It compiles after this
// file because it needs the whole AI vocabulary - sequences by name, path
// requests, yaw control - so the seven entry points the interpreter, the schedule
// gate, the damage path and the death path need are forward-declared here.
//
// Every one of them is written to be safe when the monster's .ai_script has gone
// away underneath it (removed entity, recycled edict), because a scripted scene
// that half-finishes must never be able to leave a monster possessed by nothing.
float(entity m) Script_Schedule;	// SCHED_* the script wants, SCHED_NONE if free
void(entity m)  Script_StartIdle;	// begin (or re-assert) m_iszIdle
float(entity m) Script_MayPlay;		// has the script been told to go?
void(entity m)  Script_StartPlay;	// begin m_iszPlay
void(entity m)  Script_SequenceDone;	// action finished: fire the chain, release
void(entity m)  Script_AtMark;		// arrived and facing: enter the WAIT state
float(entity m) Script_CanInterrupt;	// may combat damage break this scene?
void(entity m, float firechain) Script_Release;
void()          AI_ReportScripts;

// ---------------------------------------------------------------------------
// following
// ---------------------------------------------------------------------------
// Half-Life's CTalkMonster follow behaviour, which is what the +use gate added
// back in B2 was always for.  An ally trails the player who asked, stops when
// close enough, and drops the escort if that player dies or leaves.
//
// AI_FOLLOW_STOP is the distance at which "close enough" starts, and the gap
// between it and AI_FOLLOW_RESUME is not padding - it is a hysteresis band.  A
// single threshold makes the follower select SCHED_FOLLOW, arrive, complete,
// re-select and arrive again several times a second while the player stands
// still, which is the same schedule-churn failure the chase path had in B2.
// How many times a scripted walk re-paths before it accepts that it cannot reach
// the mark.  Three attempts total.  More than this and a genuinely unreachable
// mark keeps an actor jogging into a wall for a long time, which is worse than a
// scene that plays slightly out of position.
const float AI_SCRIPT_RETRIES = 2;

const float AI_FOLLOW_STOP   = 128;
const float AI_FOLLOW_RESUME = 192;
const float AI_FOLLOW_GIVEUP = 1024;	// too far to plausibly still be escorting

// The gait band, straight out of TASK_MOVE_TO_TARGET_RANGE
// (AI_BaseNPC_Schedule.cpp:433-435).  Close enough to be following politely ->
// walk; far enough to be catching up -> run; the gap between is deliberate
// hysteresis, not a rounding allowance.
const float AI_FOLLOW_WALK_UNDER = 190;
const float AI_FOLLOW_RUN_OVER   = 270;

// ---------------------------------------------------------------------------
// Sven guard_ent / freeroam
// ---------------------------------------------------------------------------
// What a monster does when nothing is shooting at it.  Before these, the answer
// was SCHED_IDLE_STAND - stand exactly where you spawned, forever - and on a map
// whose squadmakers are spread over thousands of units that is the whole of the
// reported "some of them don't move".
//
// DORMANCY IS DELIBERATELY NOT TOUCHED.  AI_Think still sleeps an idle monster
// with no player within sv_ai_sight (1024), so a guard three rooms away does not
// walk to its post until somebody could plausibly see it do so.  Keeping every
// roamer on the map awake at 10 Hz plus a path request per leg is exactly the
// cost the dormancy gate exists to avoid, and it buys nothing a player can
// observe.  The symptom being fixed is a monster standing still IN FRONT OF the
// player, and that monster is awake by definition.
const float AI_GUARD_RADIUS    = 192;	// inside this, the monster is "at its post"
const float AI_GUARD_RERESOLVE = 2;	// seconds between targetname lookups
// Backoff after a guard walk that ended without arriving.  Same principle as
// AI_REPATH_FAIL (sv_ai_move.qc:455): an unreachable post stays unreachable, and
// retrying it at schedule rate is how 439 selections produce zero arrivals.
const float AI_GUARD_RETRY     = 10;
const float AI_ROAM_MIN        = 256;	// nearer than this is not worth walking to
const float AI_ROAM_MAX        = 2048;

float(entity m) AI_WantsToGuard =
{
	if (m.guard_ent == "" || !m.guard_ent)
		return FALSE;

	// Backoff after a walk that could not finish.  Deliberately ABOVE the resolve,
	// so a monster held off its post is not also spending a find() every two
	// seconds on a targetname it already knows.
	if (time < m.ai_guard_retry)
		return FALSE;

	// Resolved LAZILY, and re-resolved whenever the goal goes away.  For this key
	// "the goal does not exist" is not an error, it is the normal middle of one of
	// these monsters' lives: desertcircle creates every guard object at runtime
	// with trigger_createentity, AFTER the first wave has already spawned, and then
	// each <base>goalkiller relay killtargets its own goal the instant any grunt
	// sees a player.
	//
	// The targetname re-check is not redundant with wasfreed(): QC recycles edicts,
	// so a freed goal's slot can come back as an unrelated entity and a bare
	// pointer test would happily guard a door.
	if (!m.ai_guard || wasfreed(m.ai_guard) || m.ai_guard.targetname != m.guard_ent)
	{
		if (time < m.ai_guard_next)
			return FALSE;
		m.ai_guard_next = time + AI_GUARD_RERESOLVE;
		m.ai_guard = find(world, targetname, m.guard_ent);
		if (!m.ai_guard)
			return FALSE;
	}

	return (vlen(m.ai_guard.origin - m.origin) > AI_GUARD_RADIUS);
};

float(entity m) AI_WantsToRoam =
{
	// Sven: 0 never, 1 when idle, 2 always.  Both non-zero values mean the same
	// thing here, because this is only ever consulted once the combat, follow and
	// alert branches above have all declined - i.e. the monster IS idle.  Keeping
	// them distinct in the key and identical in the behaviour is honest: there is
	// no state in which "always" could do more than "when idle" without overriding
	// combat, which no Sven NPC does.
	if (m.freeroam < 1)
		return FALSE;

	// A MONSTER WITH A LIVE POST STAYS ON IT.  AI_WantsToGuard answers FALSE both
	// for "no post to go to" and for "already standing on it", so the resolved
	// pointer is the only thing that tells those two apart - and without this test
	// the pair of keys cancel out: desertcircle's grunt makers set guard_ent AND
	// freeroam 2 together, so every grunt would walk to its post and then
	// immediately wander off it again.
	//
	// Note this reads the CACHED pointer and never resolves.  If the post has been
	// killtargeted (which is exactly what each <base>goalkiller relay does the
	// moment a grunt sees a player) the cache fails its validity test, roaming is
	// allowed, and the monster falls back to wandering instead of standing over
	// the hole where its objective used to be.
	if (m.guard_ent != "" && m.guard_ent && m.ai_guard
	    && !wasfreed(m.ai_guard) && m.ai_guard.targetname == m.guard_ent)
		return FALSE;

	// Absent cvar means enabled - the AI layer can init before CVar_Init.
	if (cvar_string("sv_ai_freeroam") != "" && !cvar("sv_ai_freeroam"))
		return FALSE;

	if (time < m.ai_roam_next)
		return FALSE;
	if (nav_state != NAVB_READY || nav_count <= 0)
		return FALSE;
	return TRUE;
};

float(entity m) AI_WantsToFollow =
{
	if (!m.ai_follow)
		return FALSE;

	// The leader is gone: dead, disconnected, or a recycled edict.  Clear rather
	// than keep testing, so the ally goes back to its normal life.
	if (m.ai_follow.health <= 0 || m.ai_follow.classname != "player")
	{
		m.ai_follow = world;
		return FALSE;
	}

	float d = vlen(m.ai_follow.origin - m.origin);
	if (d > AI_FOLLOW_GIVEUP)
	{
		// Lost them entirely - through a level transition, a teleport, or simply
		// outrun.  Standing there re-pathing across the whole map forever is worse
		// than giving up, and HL's allies do give up.
		m.ai_follow = world;
		return FALSE;
	}

	// Inside the stop band: stay put.  Outside the resume band: go.  In between,
	// keep doing whatever was already happening - which for a monster mid-walk is
	// its current schedule, so it coasts to a stop instead of stuttering.
	if (d <= AI_FOLLOW_STOP)
		return FALSE;

	// JUST ASKED: go now, band or no band.
	//
	// This is the "they wait so long before they start following" delay, and it
	// was a side effect rather than a rule.  The resume band exists to stop a
	// follower that has ALREADY ARRIVED from re-selecting the follow every tick
	// while the leader stands still.  Someone who has this second been asked has
	// not arrived at anything, so the band had nothing to damp - it just meant an
	// ally standing 150 units away answered "lead the way" and then did not move
	// until you had walked 192 units off.
	if (time < m.ai_follow_kick)
		return TRUE;

	if (d < AI_FOLLOW_RESUME && m.ai_sched != SCHED_FOLLOW)
		return FALSE;
	return TRUE;
};

void(entity m, entity p) AI_ToggleFollow;	// defined just below

// Installed as .use on allies.  SV_UseTarget binds `self` to the monster and
// `activator` to whoever pressed - which for a trigger chain is not a player,
// and that case must keep behaving exactly as it did before.
void() AI_AllyUse =
{
	if (activator && activator.classname == "player")
	{
		AI_ToggleFollow(self, activator);
		return;
	}
	// Not a player: this is a trigger chain routed through the monster, so fall
	// through to the pass-through relay Monster_Build would otherwise have left
	// here.  Dropping it would dead-end a multi_manager on a campaign map.
	GoldSrc_UnknownRelay_Use();
};

// +use on an ally toggles the escort.  Called with `self` bound to the monster
// and the player passed in, matching how SV_UseTarget dispatches.
void(entity m, entity p) AI_ToggleFollow =
{
	if (!p || p.classname != "player")
		return;

	// +USE IS A NO-OP DURING A SCENE, which is what Half-Life does and what this
	// did not.  Both halves below are HL's, and both were missing.
	//
	// This was not merely cosmetic.  The press used to reach the two lines further
	// down that (a) speak on CHAN_VOICE, cutting the scripted_sentence the actor was
	// mid-way through, and (b) set m.ai_taskdone = TRUE, which AI_RunSchedule reads
	// directly - force-completing the running script task without Script_MayPlay
	// ever being consulted, and leaving ai_follow set on a monster Script_Possess
	// had deliberately cleared. That is the "it cuts their voice line and then
	// misbehaves" report, and it is what made the chain-corruption crash
	// reproducible on demand.
	//
	// 1. THE SENTENCE LOCKOUT.  talkmonster.cpp:1419-1420 refuses outright while
	//    m_useTime has not expired, and PlayScriptedSentence stamps that to
	//    time + duration (:1145). Sentences_Speaking is the same question asked of
	//    the sentence system directly, so no parallel timestamp is needed.
	if (Sentences_Speaking(m))
		return;

	// 2. THE SCENE LOCKOUT.  CTalkMonster::CanFollow (talkmonster.cpp:1403-1407)
	//    refuses while MONSTERSTATE_SCRIPT unless the scene explicitly allows
	//    interruption. Script_CanInterrupt (sv_scripted.qc:783-793) is already the
	//    exact analogue of CCineMonster::CanInterrupt - it was written, and nothing
	//    on this path ever called it. Worth knowing how often this fires: the file's
	//    own corpus note (sv_scripted.qc:80-81) records spawnflag 96
	//    (NOINTERRUPT|OVERRIDESTATE) as the single commonest value at 355 uses, so
	//    most scenes in the campaign are explicitly non-interruptible.
	if (m.ai_script && !Script_CanInterrupt(m))
		return;
	if (m.ai_state == MS_SCRIPT)
		return;

	// PRE-DISASTER talkers do not come with you, and this is not a nicety - it is
	// most of hl_c01_a1.  Nearly every scientist and barney in the intro carries
	// spawnflag 256, and in Half-Life they brush you off because the cascade has
	// not happened yet and they are still at work.  Letting them follow made the
	// one interaction that worked on that map the one that should not exist:
	// a conga line of scientists trailing you around Black Mesa before the
	// accident, in a map whose scripts are what should have been moving them.
	//
	// They still TURN to look at you and still talk - that is the talk layer, and
	// it is what should answer a +use here.
	if (m.spawnflags & SF_MON_PRE_DISASTER)
	{
		if (time >= m.ai_followsay)
		{
			m.ai_followsay = time + 1;
			// SAY it, do not just print it.  Half-Life's DeclineFollowing plays the
			// "P_OK" group and those lines are the character: BA_POK is barney/ba_post,
			// ba_duty, ba_raincheck, ba_later - "I'm on duty", "rain check".  A silent
			// brush-off with a line of console text is not the same interaction, and it
			// is the one the player meets most often in the intro because nearly every
			// NPC there is pre-disaster.
			//
			// The print stays as the fallback for a class with no sentence group (the
			// aliens and the grunts are not talkers), so nothing loses its answer.
			if (!AI_TalkSay(m, "POK", CHAN_VOICE, ATTN_NORM))
				sprint(p, PRINT_HIGH, sprintf("%s is busy right now.\n",
				       (m.displayname != "") ? m.displayname : m.classname));
		}
		AI_LookAt(m, p);
		return;
	}

	if (m.ai_follow == p)
	{
		m.ai_follow = world;
		AI_StopMoving(m);
		if (time >= m.ai_followsay)
		{
			m.ai_followsay = time + 1;
			AI_LookAt(m, p);
			// SC_WAIT / BA_WAIT - "wait here", HL's own acknowledgement group.
			if (!AI_TalkSay(m, "WAIT", CHAN_VOICE, ATTN_NORM))
				sprint(p, PRINT_HIGH, sprintf("%s waits here.\n",
				       (m.displayname != "") ? m.displayname : m.classname));
		}
		return;
	}

	m.ai_follow = p;
	// Drop whatever it was doing so the follow starts on THIS tick rather than
	// whenever the current schedule happens to run out - an ally that ignores you
	// for four seconds reads as one that did not hear you.
	m.ai_taskdone = TRUE;
	m.ai_cond     = m.ai_cond | COND_SCHEDULE_DONE;

	// Two more things stood between "OK" and the first step, both of them timers
	// that are right in general and wrong at this exact moment:
	//   - the resume band (see AI_WantsToFollow), lifted for 2 seconds;
	//   - ai_nextpath, the per-monster repath floor, which can be up to
	//     AI_REPATH_FAIL in the future if this monster's last route failed.  A
	//     fresh order deserves a fresh route request, not the tail of an old
	//     backoff.
	m.ai_follow_kick = time + 2;
	m.ai_nextpath    = 0;

	if (time >= m.ai_followsay)
	{
		m.ai_followsay = time + 1;
		AI_LookAt(m, p);
		// SC_OK / BA_OK - "lead the way", "I'm with you".
		if (!AI_TalkSay(m, "OK", CHAN_VOICE, ATTN_NORM))
			sprint(p, PRINT_HIGH, sprintf("%s follows you.\n",
			       (m.displayname != "") ? m.displayname : m.classname));
	}
};

// ---------------------------------------------------------------------------
// gunfire
// ---------------------------------------------------------------------------
// Half-Life's monsters hear guns.  Ours did not - COND_HEAR_SOUND existed and was
// set by exactly one thing, taking damage (AI_Damaged), so a player could empty a
// magazine next to a room of scientists and not one of them would look up.  That
// is the "they don't get scared when I fire" complaint, and it is a missing
// input rather than a missing behaviour: the alert ladder, the look-at and the
// SCARED sentence groups were all already there with nothing to trigger them.
//
// HL routes this through CSoundEnt, a ring buffer of world sounds that monsters
// poll.  A direct notification is the same thing without the buffer: there is one
// producer (a shot) and the consumers are a bounded list we already walk.
const float AI_GUNFIRE_RANGE = 1280;	// HL's combat sounds carry ~1000-1500 units

// ---------------------------------------------------------------------------
// danger
// ---------------------------------------------------------------------------
// bits_SOUND_DANGER, and the reason a Half-Life squad scatters when a grenade
// lands among them.  This tree had no equivalent at all, which made every
// grenade, satchel and rocket free damage against anything that was not already
// moving - the most recognisable GoldSrc reaction there is, entirely absent.
//
// A DIFFERENT CONDITION from COND_HEAR_SOUND on purpose: a gunshot makes a
// monster look TOWARDS the noise and a live grenade makes it run AWAY, so one bit
// cannot carry both without the responses fighting.
//
// The radius is the emitter's business, not a constant here - a hand grenade and
// a satchel do not frighten people equally far.
const float AI_DANGER_MEMORY = 2.0;	// how long a danger position stays worth fleeing

// Is this projectile type something a monster should get away from?
//
// Types rather than classnames, because .proj_type is the one field every
// projectile in the tree sets and it is already the authority CSQC resolves the
// model from - so a new explosive added later is covered by naming it here, and
// nothing has to remember to call an emitter at its spawn site.
//
// Bolts, snowballs, paintballs and the shock bolt are deliberately absent: they
// hurt whoever they hit and nobody else, and diving for cover from a crossbow
// bolt already in flight is pure comedy.  The displacer orb IS in - it detonates
// with radius damage - and so is the smoke grenade, because HL treats smoke as a
// danger sound too and a monster backing out of a cloud is right.
float(float t) AI_ProjIsDangerous =
{
	if (t == PROJ_TYPE_HLGRENADE)		return TRUE;
	if (t == PROJ_TYPE_GRENADE)		return TRUE;
	if (t == PROJ_TYPE_SMG_GRENADE)		return TRUE;
	if (t == PROJ_TYPE_CSHEGRENADE)		return TRUE;
	if (t == PROJ_TYPE_CSFLASHBANG)		return TRUE;
	if (t == PROJ_TYPE_CSSMOKEGRENADE)	return TRUE;
	if (t == PROJ_TYPE_RPG_ROCKET)		return TRUE;
	if (t == PROJ_TYPE_DISPLACER_BALL)	return TRUE;
	if (t == PROJ_TYPE_SPORE)		return TRUE;
	// Day of Defeat anti-tank.  All three are high-explosive, so AI treats them
	// exactly like an incoming rocket -- without these rows a bazooka round is
	// invisible to the danger scan and nobody dives out of the way.
	if (t == PROJ_TYPE_DOD_BAZOOKA)		return TRUE;
	if (t == PROJ_TYPE_DOD_SCHRECK)		return TRUE;
	if (t == PROJ_TYPE_DOD_PIAT)		return TRUE;
	return FALSE;
};

// ---------------------------------------------------------------------------
// the world-sound slot
// ---------------------------------------------------------------------------
// CSoundEnt, reduced to ONE SLOT.  Half-Life keeps a ring buffer of world sounds
// that every monster polls through Listen()/PBestSound(); the three functions
// below are already this tree's equivalent producers, but they PUSH the result
// straight onto the monster chain and keep nothing, so a consumer that is not on
// that chain can never learn a noise happened.
//
// monster_tentacle is that consumer and the reason this exists.  It is not an
// AI_Think monster (see mon_tentacle.qc for why), so the `m.think == AI_Think`
// gate every walk below carries excludes it by construction - and hearing is not
// one input among several for a tentacle, it is the ONLY one it has.
//
// One slot rather than a buffer, because one slot is all the consumer asks for:
// PBestSound returns a single sound and the tentacle uses nothing else.  Most
// recent wins, which is not quite HL's loudest-wins - stated rather than hidden,
// and it only differs while two noises overlap inside the same tick.
vector ai_worldsnd_pos;
float  ai_worldsnd_radius;
float  ai_worldsnd_time;

int ai_worldsnd_type;

void(vector org, float radius, int stype) AI_WorldSoundRecord =
{
	ai_worldsnd_pos    = org;
	ai_worldsnd_radius = radius;
	ai_worldsnd_time   = time;
	ai_worldsnd_type   = stype;
};

// WHAT THIS MONSTER IS LISTENING FOR RIGHT NOW.
//
// Half-Life computes this in two halves and ANDs them (monsters.cpp:211-217): the
// monster's own ISoundMask, and the mask of the schedule it is currently running.
// The schedule half is the one that matters here and it is the half that was
// missing - CTalkMonster's idle schedules all carry
//
//     bits_SOUND_COMBAT | //bits_SOUND_PLAYER | //bits_SOUND_WORLD | bits_SOUND_DANGER
//
// with PLAYER and WORLD *commented out in the SDK source* and the line above them
// reading "change these, and you'll break the talking code"
// (talkmonster.cpp:287-291, :310-314; slIdleHello at :161-167 narrows to COMBAT
// alone).  So an idling scientist is deaf to footsteps by construction, and that
// is precisely why he does not wander over to inspect them.
//
// Expressed per-monster-and-state rather than as a mask column on every schedule
// because the schedules here are shared across all classes - SCHED_IDLE_STAND is
// one row used by scientists and headcrabs alike, and masking PLAYER on it would
// make the headcrab deaf too, which HL does not do.  The talker/idle test asks the
// same question the schedule table answers in HL, at the only granularity this
// table can express it.
int(entity m) AI_SoundMaskNow =
{
	int mask = m.ai_soundmask;
	if (!mask)
		mask = SND_DEFAULT;

	// Only while genuinely idle.  A talker in a fight, in a script, or already
	// following someone is not running one of the Tlk idle schedules and gets his
	// full personal mask back, exactly as HL's `if (m_pSchedule)` AND does once the
	// schedule changes.
	if (m.ai_talker && !m.ai_enemy && !m.ai_script
	    && (m.ai_state == MS_IDLE || m.ai_state == MS_NONE || m.ai_state == MS_ALERT))
		mask = mask & ~(SND_PLAYER | SND_WORLD);

	return mask;
};

// A NOISE CAN END AN IDLE SCENE, and Half-Life does not do this.
//
// HL's SCRIPT_BREAK_CONDITIONS is bits_COND_LIGHT_DAMAGE|bits_COND_HEAVY_DAMAGE
// and nothing else (scripted.cpp, IgnoreConditions), so in the SDK a scripted
// actor is deaf for as long as the scene lasts.  Sven's FGD adds no interruption
// keys either — its scripted_sequence spawnflags are Half-Life's exactly.
//
// The reason to diverge is the shape of a They Hunger map.  th_ep1_01 parks a
// zombie on `eatbody` (spawnflags 2 — interruptible, no bit 32) and another on
// `getuplad` (spawnflags 0) chewing a corpse, and they hold that pose through a
// firefight happening in the same room.  "monster_zombie should wake up from
// eating when the player is nearby, shoots another zombie, or shoots next to
// him" is the report, and a horror map full of monsters that ignore gunfire two
// metres away is a fair thing to call broken even though it is faithful.
//
// THREE THINGS KEEP THIS FROM EATING THE CHOREOGRAPHY:
//
//   * Only a script that already declared itself interruptible.  355 of the
//     corpus's scripts carry SF_SCRIPT_NOINTERRUPT and are untouched; on this map
//     that is 22 of 41.
//   * Only during SCRIPTST_WAIT — a monster parked in m_iszIdle waiting to be
//     triggered.  A scene that has been fired and is mid-performance runs to the
//     end, so nothing a mapper sequenced can be cut in half.
//   * A cvar, because the risk is campaign-wide rather than local.
//         sv_ai_script_wake 0  damage only, i.e. Half-Life
//         sv_ai_script_wake 1  + combat and danger noise (gunfire, grenades)
//         sv_ai_script_wake 2  + player footsteps, i.e. "somebody walked in"
//     1 is the default.  2 is what "when the player is nearby" literally asks
//     for, and is left off by default because it would also stand up every
//     interruptible seated scientist in Half-Life as you walk past him.
float ai_cached_scriptwake;

void(entity m, int stype) AI_ScriptNoiseWake =
{
	if (!m.ai_script)
		return;
	if (m.ai_scriptstate != SCRIPTST_WAIT)
		return;

	float lvl = ai_cached_scriptwake;
	if (lvl <= 0)
		return;
	if ((stype & (SND_COMBAT | SND_DANGER)) == 0 && lvl < 2)
		return;

	if (!Script_CanInterrupt(m))
		return;

	ai_dbg_script_broke = ai_dbg_script_broke + 1;
	Script_Release(m, TRUE);
};

void(vector org, float radius) AI_DangerSound =
{
	AI_WorldSoundRecord(org, radius, SND_DANGER);

	entity m = monster_chain_head;
	while (m)
	{
		if (m.health > 0 && m.think == AI_Think && m.ai_state != MS_DEAD)
		if (m.ai_movemode != AIMODE_STATIC)		// bolted down; nowhere to go
		if (AI_SoundMaskNow(m) & SND_DANGER)
		if (vlen(m.origin - org) <= radius)
		{
			m.ai_cond         = m.ai_cond | COND_HEAR_DANGER;
			m.ai_dangerpos    = org;
			m.ai_danger_until = time + AI_DANGER_MEMORY;

			// Wake a dormant one, exactly as gunfire does.  A grenade rolling
			// under an idle grunt has to be able to move him.
			if (m.ai_state == MS_IDLE || m.ai_state == MS_NONE)
				m.ai_state = MS_ALERT;
			m.nextthink = time + 0.05;

			// Clear the cover retry floor.  It exists to stop a monster in an
			// open room re-searching for cover every tick, and that reasoning
			// does not survive a live grenade: this is precisely the moment to
			// try again however recently the last attempt failed.
			m.ai_covernext = 0;

			AI_ScriptNoiseWake(m, SND_DANGER);

			ai_dbg_danger_heard = ai_dbg_danger_heard + 1;
		}
		m = m.monster_chain_next;
	}
};

// How far each kind of explosive frightens people.  Roughly its own blast radius
// with a margin, because the useful answer to "should I move" is "would this hurt
// me here", not "how loud was it".
float(float t) AI_ProjDangerRadius =
{
	if (t == PROJ_TYPE_RPG_ROCKET)		return 400;
	if (t == PROJ_TYPE_CSSMOKEGRENADE)	return 200;
	if (t == PROJ_TYPE_CSFLASHBANG)		return 300;
	// Matched to each warhead's own blast radius plus a margin, the rule this
	// function states: 320 for the bazooka and Panzerschreck, 300 for the PIAT.
	if (t == PROJ_TYPE_DOD_BAZOOKA)		return 380;
	if (t == PROJ_TYPE_DOD_SCHRECK)		return 380;
	if (t == PROJ_TYPE_DOD_PIAT)		return 350;
	return 320;
};

// THE EMITTER, and it is a scan rather than a hook at every throw site.
//
// Half-Life does the same thing from the other end: CGrenade::DangerSoundThink
// re-emits every 0.2 s for the whole of a grenade's flight, so a monster that
// walks into the area afterwards still reacts and one that was looking away gets
// another chance.  A one-shot notification at the moment of the throw would give
// neither.
//
// Scanning by .proj_type rather than hooking each weapon is what makes this one
// piece of code instead of a dozen: every projectile in the tree sets that field
// already, the throw sites are spread across a dozen shared weapon files that
// compile into both VMs, and a hook in each is a hook someone will forget in the
// thirteenth.  One walk of the entity list five times a second is the cost.
const float AI_DANGER_SCAN = 0.2;
float ai_danger_scan_next;

void() AI_DangerScan =
{
	if (time < ai_danger_scan_next)
		return;
	ai_danger_scan_next = time + AI_DANGER_SCAN;

	// Nothing to frighten - skip the walk entirely.  Most maps spend most of
	// their time here.
	if (!monster_chain_head)
		return;

	entity e = nextent(world);
	while (e)
	{
		// The SendEntity test is the discriminator and has to be, not .proj_type:
		// PROJ_TYPE_HLGRENADE is 0 and so is every unset float in the game, so
		// testing the type alone would declare all 568 entities on desertcircle a
		// live hand grenade.
		if (e.SendEntity == projectile_SendEntity)
			if (AI_ProjIsDangerous(e.proj_type))
				AI_DangerSound(e.origin, AI_ProjDangerRadius(e.proj_type));
		e = nextent(e);
	}
};

// Global rate limit.  An automatic weapon fires ten times a second and each shot
// would otherwise walk the whole monster chain; four sweeps a second is plenty to
// feel instant and is the difference between a free feature and a per-shot cost.
float ai_gunfire_next;

// A WORLD NOISE at `org`, audible `radius` units away.  The general form of what
// AI_HeardGunfire does for one specific noise, so footsteps, breaking crates and
// anything else that should turn a head can share it.
//
// Records ai_soundpos as well as ai_lastseenpos: the two are different questions
// and conflating them is why hearing could only ever turn a head.  lastseenpos is
// "where I think my ENEMY is" and feeds combat; soundpos is "where that noise
// came from" and feeds going to look, which may be nothing to do with an enemy at
// all.
void(vector org, float radius, int stype) AI_HeardNoise =
{
	AI_WorldSoundRecord(org, radius, stype);

	entity m = monster_chain_head;
	while (m)
	{
		if (m.health > 0 && m.think == AI_Think && m.ai_state != MS_DEAD)
		// THE MASK TEST, and it is the whole fix for the wandering scientists.
		// Half-Life does this in Listen() before the distance check
		// (monsters.cpp:231) and a monster that fails it gets no condition, no
		// stored position and - critically - no promotion out of MS_IDLE below.
		// A scientist standing in the airlock therefore stays standing while the
		// player walks past, instead of waking up and being handed a schedule.
		if (AI_SoundMaskNow(m) & stype)
		if (vlen(m.origin - org) <= radius)
		{
			m.ai_cond      = m.ai_cond | COND_HEAR_SOUND;
			m.ai_soundpos  = org;
			m.ai_soundtype = stype;
			if (m.ai_state == MS_IDLE || m.ai_state == MS_NONE)
			{
				m.ai_state  = MS_ALERT;
				m.nextthink = time + 0.05;
			}
			AI_ScriptNoiseWake(m, stype);
		}
		m = m.monster_chain_next;
	}
};

// Player movement.  HL's CSoundEnt gets a bits_SOUND_PLAYER entry sized by how
// hard the player is moving; this is the same idea with the volume collapsed to a
// radius.  Rate-limited hard because it is driven from the movement code, which
// runs every frame for every client.
//
// Crouching is deliberately silent - it is the only stealth control the player
// has, and it is worth something only if it does something.
const float AI_FOOTSTEP_RUN  = 640;
const float AI_FOOTSTEP_WALK = 320;
float ai_footstep_next;

void(entity who, float speed, float crouched) AI_HeardFootstep =
{
	if (!who || crouched || time < ai_footstep_next)
		return;
	if (speed < 80)
		return;					// creeping; below the noise floor
	ai_footstep_next = time + 0.35;
	AI_HeardNoise(who.origin, (speed > 200) ? AI_FOOTSTEP_RUN : AI_FOOTSTEP_WALK,
	              SND_PLAYER);
};

void(entity who) AI_HeardGunfire =
{
	if (!who || time < ai_gunfire_next)
		return;
	ai_gunfire_next = time + 0.25;

	AI_WorldSoundRecord(who.origin, AI_GUNFIRE_RANGE, SND_COMBAT);

	entity m = monster_chain_head;
	while (m)
	{
		if (m.health > 0 && m.think == AI_Think && m.ai_state != MS_DEAD)
		if (AI_SoundMaskNow(m) & SND_COMBAT)
		if (vlen(m.origin - who.origin) <= AI_GUNFIRE_RANGE)
		{
			m.ai_cond        = m.ai_cond | COND_HEAR_SOUND;
			m.ai_lastseenpos = who.origin;
			m.ai_soundpos    = who.origin;
			m.ai_soundtype   = SND_COMBAT;

			// Wake a dormant one immediately.  A half-second delay before a
			// scientist reacts to a gunshot beside him is precisely the "slow to
			// react" feel that started this work.
			if (m.ai_state == MS_IDLE || m.ai_state == MS_NONE)
			{
				m.ai_state  = MS_ALERT;
				m.nextthink = time + 0.05;
			}

			// LOOK, do not speak.
			//
			// This used to say the SCARED group here, and that was a misreading
			// with a very visible cost: scientists complained at the player
			// throughout every firefight fought on their behalf.  SC_SCARED is
			// Half-Life's TLK_NOSHOOT group (scientist.cpp:745) - "stop shooting
			// my friend" - and talkmonster.cpp:1193 fires it when a player DAMAGES
			// a talker, from that talker's nearest FRIEND.  It has nothing to do
			// with hearing a gun.  It now lives in AI_TalkDamaged, where HL keeps
			// it, and this path does what a heard gunshot should do: turn and look.
			//
			// NOT a flee either.  Half-Life's scientists do take cover from danger
			// sounds, but an escort that bolts every time the player fires is
			// unusable in a co-op mod.
			if (m.ai_talker && !m.ai_enemy && !m.ai_script && time >= m.ai_scared_next)
			{
				m.ai_scared_next = time + 8;
				AI_LookAt(m, who);
			}

			// ...and a gunshot beside a monster parked in an idle scene ends the
			// scene.  See AI_ScriptNoiseWake for the whole rule and its cvar.
			AI_ScriptNoiseWake(m, SND_COMBAT);
		}
		m = m.monster_chain_next;
	}
};

// ---------------------------------------------------------------------------
// schedule selection
// ---------------------------------------------------------------------------
// The class virtual gets first refusal and may return SCHED_NONE to mean "no
// opinion, use the generic pick" - which is what keeps a class file small: a
// headcrab only has to describe the parts where it differs from every other
// monster, not restate the whole ladder.
float(entity m) AI_SelectSchedule =
{
	if (m.ai_state == MS_DEAD)
	{
		// Once the death schedule has run to completion the corpse is finished
		// and must be given NOTHING, so AI_Think's "stop thinking entirely"
		// branch can actually fire.
		//
		// Without the latch this returns SCHED_DIE forever: the schedule ends,
		// re-selects, and starts again.  That made AI_Think's nextthink = 0 path
		// unreachable, so every corpse on the map kept ticking at 10 Hz for the
		// rest of the round.  Measured on a 1 HP class (the cockroach, which
		// dies instantly and has no death sequence to slow the loop down): 102
		// death-schedule selections in 45 seconds.
		if (m.ai_dead_done)
			return SCHED_NONE;
		return SCHED_DIE;
	}

	// A scripted_sequence outranks EVERYTHING except dying, and it sits above the
	// class virtual on purpose.  A script is the map author's decision about what
	// this monster does; a class virtual is ours.  Below the virtual, a grunt with
	// a grenade opinion or a bigmomma with a birth schedule would talk over a
	// cutscene, and the failure would look like the script never ran.
	//
	// This is also the single point where possession is enforced, which is what
	// makes the state safe: there is no path by which a claimed monster picks its
	// own schedule, so nothing downstream has to defend against one.
	if (m.ai_script)
	{
		float ss = Script_Schedule(m);
		if (ss != SCHED_NONE)
			return ss;
		// Script_Schedule returned nothing, which means it has just let go of this
		// monster (the entity vanished, or the scene is over).  Fall through to the
		// normal ladder rather than returning NONE - a monster given no schedule at
		// all stops thinking, and a released actor must go back to being a monster.
	}

	// A FAILED TASK OUTRANKS THE CLASS VIRTUAL, and it did not until cover was
	// written.  This is Half-Life's own structure: MaintainSchedule
	// (schedule.cpp:238-259) tests bits_COND_TASK_FAILED and calls the fail
	// schedule, and the call to GetSchedule - the class virtual - is the ELSE of
	// that branch.  The two are mutually exclusive, and failure wins.
	//
	// Here the virtual used to be asked first, which made the fail branch below
	// unreachable for any monster whose class had an opinion.  It was latent for
	// as long as the virtuals were narrow: the grenade sits behind an attack
	// cooldown, the gargantua's flame behind a six-second one, and the turret and
	// barnacle state machines almost never fail a task.  Cover is the first
	// virtual that answers on EVERY damaged tick, so it collided immediately.
	//
	// The symptom, from sv_ai_covertest on hl_c01_a1, is worth keeping because
	// nothing about it says "ordering":
	//
	//   sched=186 arrived=0 tries=17 ... cower=12
	//   monster_human_grunt moved=0 was-visible=yes now=visible sched=take_cover
	//
	// Cover chosen 186 times, the search reached 17 times, and not one monster
	// moved a single unit.  COND_TASK_FAILED was set, nothing could clear it
	// because SCHED_COVER_FAILED - the only schedule that clears it - could never
	// be selected, and take_cover's own interrupt mask contains it, so every
	// selection was thrown away 0.2 s later by the condition that selected it.
	//
	// The scripted_sequence branch stays ABOVE this one.  HL puts task-failed
	// above everything, but Script_Schedule has its own retry-and-release
	// handling (ai_scriptretry), and letting a failed task pull a monster out of
	// a cutscene would undo that.
	if (m.ai_cond & COND_TASK_FAILED)
	{
		float fs = m.ai_failsched;
		if (fs <= SCHED_NONE || fs >= SCHED_MAX)
			fs = SCHED_FAIL;
		return fs;
	}

	if (m.ai_selectsched)
	{
		entity oldself = self;
		self = m;
		float r = m.ai_selectsched();
		self = oldself;
		if (r != SCHED_NONE)
			return r;
	}

	// Flinch, rate limited.  Without the limit, sustained fire re-selects the
	// flinch schedule every tick and the monster is stunlocked into never
	// finishing an attack - which reads as a bug rather than as difficulty.
	if (m.ai_cond & COND_DAMAGE)
	{
		if (time >= m.ai_nextflinch)
		{
			m.ai_nextflinch = time + AI_FLINCH_GAP;
			return SCHED_SMALL_FLINCH;
		}

		// Cooldown still running, so this hit gets no flinch - and the bits MUST be
		// dropped here rather than left for a schedule to consume.  Only
		// SCHED_SMALL_FLINCH clears COND_DAMAGE, so a hit that does not earn a
		// flinch used to leave the bits set forever, and COND_DAMAGE is in almost
		// every schedule's interrupt mask: the monster was interrupted, re-selected,
		// and interrupted again at the full tick rate for the whole two seconds.
		//
		// Measured as 517 alert_stand selections in 45 s from eight houndeyes,
		// whose blast damages their own pack - but this was never houndeye-specific.
		// Any monster under sustained fire has been doing it since B2.
		//
		// Clearing here loses nothing: interrupts are tested in AI_RunSchedule
		// BEFORE selection runs, so by the time we are here the condition has
		// already done its one job.
		m.ai_cond = m.ai_cond & ~COND_DAMAGE;
	}

	if (m.ai_state == MS_COMBAT)
	{
		if (!m.ai_enemy || (m.ai_cond & COND_ENEMY_DEAD))
		{
			m.ai_enemy = world;
			m.ai_state = MS_ALERT;
			return SCHED_ALERT_STAND;
		}
		// A LIVE GRENADE COMES FIRST - before melee, before the rationed shot,
		// before everything.  This is the one input that should outrank an
		// attack the monster is otherwise ready to make: standing still to
		// punch someone while a grenade cooks at your feet is exactly the
		// behaviour that reads as "they never react to anything".
		//
		// Unlike the other cover triggers this one IS in the generic ladder,
		// and deliberately: fleeing a grenade is not a per-class personality
		// the way "duck when hurt" is, and AIMODE_STATIC is already excluded
		// at the emitter.  Cover_Allowed still gets the last word.
		if (m.ai_cond & COND_HEAR_DANGER)
		{
			m.ai_cond = m.ai_cond & ~COND_HEAR_DANGER;
			if (time < m.ai_danger_until && Cover_Allowed(m))
				return SCHED_TAKE_COVER;
		}

		if (m.ai_cond & COND_CAN_MELEE1)	return SCHED_MELEE_ATTACK1;

		// THE RANGED ATTACK IS RATIONED, melee is not.  Half-Life's slots are all
		// ranged (engage, grenade, hornet) because the thing they exist to stop is
		// a firing line - four monsters standing in a row shooting simultaneously.
		// Melee already rations itself: only so many bodies fit within arm's
		// reach, and a squad that queued to punch you would just stand still.
		//
		// A refused slot falls THROUGH to the ladder below rather than returning
		// SCHED_NONE, which is the difference between a squad that takes turns and
		// a squad where three of the four freeze: the ones without a slot go and
		// do something else - face, close, reposition - and pick a slot up when
		// the monster holding it changes schedule.
		float denied_slot = FALSE;
		if (m.ai_cond & COND_CAN_RANGE1)
		{
			if (Squad_MayEngage(m))
				return SCHED_RANGE_ATTACK1;
			denied_slot = TRUE;
		}

		// Already in range but not able to strike yet - almost always the attack
		// cooldown.  Stand and face rather than chase: the chase schedule would
		// reach its goal on the first tick, complete, re-select, and do it again
		// two or three times a second for the whole cooldown.  Measured as 17
		// arrivals per 2 s from six monsters that were standing still.
		//
		// This is what SCHED_COMBAT_FACE is for, and it interrupts the moment
		// COND_ATTACK_READY appears, so nothing is lost by waiting in it.
		if (m.ai_cond & COND_SEE_ENEMY)
		{
			float reach = m.ai_melee_range;
			if (m.ai_range_range > reach)
				reach = m.ai_range_range;

			// Rationed rather than reloading: hold at a tighter band so the
			// squad's non-shooters advance instead of posing at max range.
			// See AI_DENIED_CLOSE_FRAC.
			if (denied_slot && m.ai_range_range > 0)
			{
				reach = m.ai_range_range * AI_DENIED_CLOSE_FRAC;
				if (reach < m.ai_melee_range)
					reach = m.ai_melee_range;
			}

			if (reach > 0 && vlen(m.ai_enemy.origin - m.origin) <= reach)
				return SCHED_COMBAT_FACE;
		}

		// A bolted-down monster cannot close distance, so it must never be handed
		// a chase.  AI_MoveAlongPath would answer ARRIVED on the first tick, the
		// schedule would complete, selection would hand it another, and a turret
		// would churn through the whole cycle several times a second forever.
		// AI_SchedSelfTest asserts that combat_face itself contains no movement.
		if (m.ai_movemode == AIMODE_STATIC)
			return SCHED_COMBAT_FACE;

		return SCHED_CHASE_ENEMY;
	}

	// THE PLAYER SHOVED ME.  CScientist::GetSchedule tests this twice - once inside
	// the following branch (SCHED_MOVE_AWAY_FOLLOW) and once outside it
	// (scientist.cpp:982, :995) - so it holds whether or not the ally is escorting
	// anybody.  Checked here, above the follow, for the same reason: one schedule
	// covers both cases, because SCHED_MOVE_AWAY runs to completion and the next
	// selection puts an escort straight back on SCHED_FOLLOW by itself.
	//
	// The condition is consumed rather than left set.  A player leaning on a
	// scientist re-raises it every frame from AI_TalkerTouch, and re-selecting the
	// same schedule each time would restart the walk from task 0 forever - the
	// monster would vibrate against the player instead of stepping out of the way.
	if (m.ai_cond & COND_CLIENT_PUSH)
	{
		m.ai_cond = m.ai_cond & ~COND_CLIENT_PUSH;
		if (!m.ai_script && m.ai_movemode != AIMODE_STATIC && m.ai_state != MS_COMBAT)
			return SCHED_MOVE_AWAY;
	}

	// COWER WHEN YOU HEAR SOMETHING SCARY - scientist.cpp:938-956, and the reason
	// "they don't get scared when I fire a gun" was unfixable until sounds carried
	// a type.  HL's test is exactly:
	//
	//     if ( pSound->m_iType & (bits_SOUND_DANGER | bits_SOUND_COMBAT) )
	//         if ( gpGlobals->time - m_fearTime > 3 )
	//             return GetScheduleOfType( SCHED_STARTLE );
	//
	// Talkers only, because it is CScientist's override - a grunt hearing gunfire
	// goes and looks (the branch below), he does not duck.
	//
	// The fear clock is also stamped on seeing the enemy, which is HL's
	// `m_fearTime = gpGlobals->time` in the same function: an ally already staring
	// at the thing shooting at him has bigger problems than flinching at the noise.
	if (m.ai_talker && !m.ai_script && (m.ai_cond & COND_HEAR_SOUND)
	    && (m.ai_soundtype & (SND_COMBAT | SND_DANGER)))
	{
		if (m.ai_cond & COND_SEE_ENEMY)
			m.ai_feartime = time;
		else if (time - m.ai_feartime > 3)
		{
			m.ai_feartime = time;
			m.ai_cond     = m.ai_cond & ~COND_HEAR_SOUND;
			return SCHED_STARTLE;
		}
	}

	// Following, checked AFTER the combat block and BEFORE the alert/idle ladder.
	//
	// That position is the whole design.  Above it, and an escorted barney would
	// walk away from the thing shooting at him; below the idle branches, and he
	// would never get there at all, because SCHED_IDLE_STAND is returned
	// unconditionally and nothing after it is reachable.  Fighting outranks
	// following; following outranks standing around.
	if (AI_WantsToFollow(m))
		return SCHED_FOLLOW;

	// Danger with no enemy - a grenade lobbed into a room nobody has been alerted
	// in yet.  Same reaction, one rung further down, so an idle guard still dives
	// away from it instead of standing there because he has nothing to fight.
	if (m.ai_cond & COND_HEAR_DANGER)
	{
		m.ai_cond = m.ai_cond & ~COND_HEAR_DANGER;
		if (time < m.ai_danger_until && m.ai_movemode != AIMODE_STATIC
		    && time >= m.ai_covernext)
			return SCHED_TAKE_COVER;
	}

	if (m.ai_state == MS_ALERT)
	{
		if (m.ai_cond & COND_SEE_ENEMY)		return SCHED_WAKE_ANGRY;

		// GO AND LOOK, rather than only turning to face it.
		//
		// Gated hard, because "wander off towards a noise" is exactly the wrong
		// behaviour for most of the things that can hear one: a monster with a
		// post to guard, one in a scripted scene, a bolted-down turret, an escort
		// that would leave the player behind, and anything already in a fight all
		// keep the old head-turn.  What is left is the idle patroller, which is
		// the case the behaviour is for.
		//
		// The distance floor matters as much as the rate limit: without it a
		// monster standing on top of the noise would path a few units, arrive,
		// and re-select for the whole two-second wait.
		// ...AND ONLY FOR A COMBAT SOUND.  Half-Life's alert branch reads
		//
		//     if ( pSound->m_iType & bits_SOUND_COMBAT )
		//         return GetScheduleOfType( SCHED_INVESTIGATE_SOUND );
		//
		// (monsters.cpp, MONSTERSTATE_ALERT) and there is no second arm: a
		// footstep, a door, a smashed crate all fall past it to ALERT_STAND.  Only
		// gunfire is worth crossing a room for.
		//
		// Without this test the gate above admitted a PLAYER footstep, which is
		// regenerated every 0.35s from wherever the player now is - so the monster
		// re-pathed to the player's current position over and over.  That is the
		// entire mechanism behind "they seem to just want to walk towards the
		// player", and it needed no +use, no ai_follow and no enemy to happen; the
		// distance floor and the 8-second retry are what made it read as a slow,
		// clumsy follow rather than as a charge.
		if ((m.ai_cond & COND_HEAR_SOUND) && (m.ai_soundtype & SND_COMBAT)
		    && !m.ai_enemy && !m.ai_script
		    && m.ai_movemode != AIMODE_STATIC && !m.ai_follow && !m.ai_guard
		    && time >= m.ai_investigate_next
		    && m.ai_soundpos != '0 0 0'
		    && vlen(m.ai_soundpos - m.origin) > 128)
		{
			m.ai_cond = m.ai_cond & ~COND_HEAR_SOUND;
			m.ai_investigate_next = time + 8;
			ai_dbg_investigate = ai_dbg_investigate + 1;
			return SCHED_INVESTIGATE_SOUND;
		}

		if (m.ai_cond & COND_HEAR_SOUND)	return SCHED_ALERT_FACE;
		// Below the two condition branches, so an alerted monster still reacts to
		// what alerted it; above the stand, because "go back to your post" beats
		// "stand here" once there is nothing left to react to.
		// Same reasoning as the MS_IDLE terminal below — a swimmer has no post to
		// return to and no node to roam to, and standing is the one thing it must
		// not do.
		if (m.ai_movemode == AIMODE_SWIM)	return SCHED_SWIM_IDLE;
		if (AI_WantsToGuard(m))			return SCHED_GUARD;
		if (AI_WantsToRoam(m))			return SCHED_ROAM;
		return SCHED_ALERT_STAND;
	}

	// Anything this monster FEARS is run from, not fought.  This generalises what
	// the cockroach hardcoded in W2: a scientist fears a headcrab, an insect fears
	// everything, and both want the same schedule.  Checked before the state
	// ladder so it holds in every state.
	if (m.ai_enemy && AI_Fears(m, m.ai_enemy))
		if (m.ai_cond & (COND_SEE_ENEMY | COND_DAMAGE))
			return SCHED_FLEE_ENEMY;

	// MS_IDLE / MS_NONE
	if (m.ai_cond & COND_SEE_ENEMY)		return SCHED_WAKE_ANGRY;
	if (m.ai_cond & COND_HEAR_SOUND)	return SCHED_ALERT_FACE;
	if (m.ai_cond & COND_PROVOKED)		return SCHED_ALERT_STAND;
	// The terminal that used to be reached by every spawned monster with nothing
	// to fight: SCHED_IDLE_STAND, i.e. stand on the spawn point until a player
	// walks into sight.  Guard and roam are what a Sven map expects instead.
	// A SWIMMER NEVER STANDS.  Above guard and roam deliberately: both of those
	// walk to a nav node, and there are no nav nodes inside a pool, so a swimmer
	// that reached them would fail its path and land back on IDLE_STAND anyway.
	// Below the COND_SEE_ENEMY test just as deliberately — a leech that can see
	// you must chase you, not wander.
	if (m.ai_movemode == AIMODE_SWIM)	return SCHED_SWIM_IDLE;
	if (AI_WantsToGuard(m))			return SCHED_GUARD;
	if (AI_WantsToRoam(m))			return SCHED_ROAM;
	return SCHED_IDLE_STAND;
};

// ---------------------------------------------------------------------------
// the task interpreter
// ---------------------------------------------------------------------------
void(entity m) AI_TaskStart;

void(entity m) AI_TaskComplete =
{
	m.ai_taskdone = TRUE;
};

void(entity m) AI_TaskFail =
{
	m.ai_cond     = m.ai_cond | COND_TASK_FAILED;
	m.ai_taskdone = TRUE;
};

void(entity m, float s) AI_SetSchedule =
{
	m.ai_sched    = s;
	m.ai_task     = 0;
	m.ai_taskdone = FALSE;
	m.ai_cond     = m.ai_cond & ~COND_SCHEDULE_DONE;
	// Reset each time: TASK_SET_FAIL_SCHED is per-schedule, and inheriting the
	// previous schedule's fallback is how a monster ends up looping between two
	// unrelated failure paths.
	m.ai_failsched = SCHED_FAIL;

	// The single most useful line when a monster misbehaves: which schedule it
	// picked, in what state, with which conditions set.  Almost every wrong
	// behaviour is visible as the wrong schedule rather than as a wrong task.
	if (ai_cached_debug)
		dprint(sprintf("[ai] %s state=%g cond=%i -> \"%s\"\n",
		               m.classname, m.ai_state, m.ai_cond, Sched_Name(s)));

	if (s != SCHED_NONE)
		AI_TaskStart(m);
};

// Called once when a task begins.  Instantaneous tasks do their work and call
// AI_TaskComplete here; the rest set up state that AI_TaskRun then polls.
void(entity m) AI_TaskStart =
{
	float op = Sched_Op(m.ai_sched, m.ai_task);
	float a  = Sched_A(m.ai_sched, m.ai_task);
	float b  = Sched_B(m.ai_sched, m.ai_task);

	m.ai_taskend = 0;

	entity oldself;

	if (op == TASK_WAIT)
	{
		m.ai_taskend = time + a;
	}
	else if (op == TASK_WAIT_RANDOM)
	{
		float lo = a, hi = b;
		if (hi < lo) hi = lo;
		m.ai_taskend = time + lo + random() * (hi - lo);
	}
	else if (op == TASK_WAIT_INDEFINITE)
	{
		m.ai_taskend = 0;		// only an interrupt condition ends this
	}
	else if (op == TASK_SET_ACTIVITY)
	{
		AI_SetActivity(m, a);
		AI_TaskComplete(m);
	}
	else if (op == TASK_PLAY_SEQUENCE)
	{
		// Reset first so the sequence genuinely restarts even if this activity
		// is the one already playing (a second flinch from a second hit).
		AI_ResetActivity(m);
		AI_SetActivity(m, a);
	}
	else if (op == TASK_PLAY_DEATH)
	{
		// The activity is decided HERE and not in the schedule table, from where
		// the killing blow landed and which way it was travelling.  Same reset
		// and same reason as TASK_PLAY_SEQUENCE.
		AI_ResetActivity(m);
		float dact = AI_DeathActivity(m);
		AI_SetActivity(m, dact);

		// A RIG WITH NO DEATH ANIMATION MUST NOT WAIT FOR ONE.
		//
		// AI_DeathActivity always returns something, and where the model carries
		// none of the death activities the fallback ladder (sv_ai_anim.qc:111-114)
		// bottoms out at ACT_IDLE.  So the corpse is put onto the rig's IDLE cycle
		// and this task then sits waiting for that cycle to finish before TASK_DIE
		// - the task that actually removes the body - is allowed to run.
		//
		// roach.mdl is exactly this case: two sequences, run_1 and run_2, no death.
		// A squashed cockroach therefore stood there running its gait on the spot,
		// which is the "their little antennae keep moving" in the report.  It is
		// worse than the sequence length suggests, because a monster with no player
		// nearby ticks at the dormant rate rather than at AI_TICK, so the wait is
		// rounded up to whole half-seconds.
		//
		// Half-Life does not wait at all: CRoach::Killed calls UTIL_Remove in the
		// same frame (roach.cpp:182).  Completing here does the same thing for any
		// rig that genuinely has nothing to play, and changes nothing for a rig
		// that does.
		if (!AI_HasActivity(m, dact))
			AI_TaskComplete(m);
	}
	else if (op == TASK_PLAY_FLINCH)
	{
		AI_ResetActivity(m);
		AI_SetActivity(m, AI_FlinchActivity(m));
	}
	else if (op == TASK_FLAME_SWEEP)
	{
		// The cooldown is stamped HERE, at the start, not at the end - so a sweep
		// cut short by the enemy escaping still costs the full six seconds and a
		// gargantua cannot re-light every time its target steps in and out of the
		// cone.  gargantua.cpp:1092.
		m.ai_taskend   = time + a;
		m.ai_flametime = time + GARG_FLAME_COOLDOWN;
		AI_SetBoneControl(m, 0, 0);
		AI_SetBoneControl(m, 1, 0);
	}
	else if (op == TASK_SET_FAIL_SCHED)
	{
		m.ai_failsched = a;
		AI_TaskComplete(m);
	}
	else if (op == TASK_SET_STATE)
	{
		m.ai_state = a;
		AI_TaskComplete(m);
	}
	else if (op == TASK_CLEAR_COND)
	{
		m.ai_cond = m.ai_cond & ~((int)a);
		AI_TaskComplete(m);
	}
	else if (op == TASK_FACE_ENEMY)
	{
		if (m.ai_enemy)
			AI_YawToward(m, m.ai_enemy.origin);
		else if (time < m.ai_danger_until)
			// Fled a grenade with nobody to blame for it.  Facing where it came
			// from is both the sensible pose and the difference between the
			// cover schedule completing and failing on its last task after the
			// monster has already done the useful part.
			AI_YawToward(m, m.ai_dangerpos);
		else
			AI_TaskFail(m);
	}
	else if (op == TASK_FACE_IDEAL)
	{
		// ai_yaw_ideal was set by whatever came before (TASK_TURN_RANDOM).
	}
	else if (op == TASK_TURN_RANDOM)
	{
		m.ai_yaw_ideal = AI_AngleNorm(m.angles_y + (random() * 2 - 1) * a);
		AI_TaskComplete(m);
	}
	else if (op == TASK_GET_PATH_ENEMY)
	{
		if (!m.ai_enemy)
			AI_TaskFail(m);
		else
		{
			// NEVER WAIT ON THE NAV QUEUE, exactly as TASK_GET_PATH_FOLLOW and
			// TASK_GET_PATH_SCRIPT below already refuse to.  Half-Life's
			// TASK_GET_PATH_TO_ENEMY is synchronous (dlls/schedule.cpp:990-1014),
			// and the BuildRoute behind it tries a straight CheckLocalMove FIRST,
			// reaching the node graph only as a "last ditch"
			// (dlls/monsters.cpp:1535-1590).  Blocking here parked the monster for
			// up to TWO SECONDS at the start of every chase leg and then walked it
			// down a node route it usually did not need - which is most of
			// "they don't lock on, and they arrive late".
			//
			// The goal is RESTATED after the request, and that line is the other
			// half: AI_PathRequest returns BEFORE assigning ai_goalpos whenever its
			// repath throttle refuses (sv_ai_move.qc:561-589 against the assignment
			// at :591), which is the common case for a monster that already holds a
			// route - so the chase goal could be up to AI_REPATH_OK (1.0s) stale,
			// about 320 units at player run speed.  HL's FRefreshRoute has no such
			// throttle.
			AI_PathRequest(m, m.ai_enemy.origin);
			m.ai_goalpos = m.ai_enemy.origin;
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_GET_PATH_FOLLOW)
	{
		// UNLIKE the other path tasks, this one NEVER waits for the nav queue and
		// never fails because the queue said no.
		//
		// Waiting was measured as a permanent starvation loop: eight allies request
		// in the same tick, most are refused, each waits out its 2 s deadline, fails
		// with COND_NO_PATH, and the failure backoff pushes ai_nextpath two seconds
		// further out - so the NEXT request is refused before it is even made.  20
		// follow selections, 19 failures, zero arrivals.
		//
		// It is also wrong in principle.  Half-Life's allies do not graph-search to
		// the player at all; CTalkMonster walks straight at them with local
		// avoidance, and reserves the node graph for long routes.  A follower is by
		// definition nearby (AI_FOLLOW_GIVEUP drops the escort past 1024 units), so
		// the straight line is the common case and the graph is the optimisation.
		//
		// So: set the goal, ask the queue as a courtesy, and get on with walking.
		// AI_MoveAlongPath uses the route if one turns up mid-move and heads
		// straight for the goal if none does.
		// WHO is being walked to.  Normally the escorted player (ai_follow); during
		// SCHED_HEAL it is the patient instead, which is usually the same person but
		// need not be - a scientist nobody asked to follow still walks over to a hurt
		// player.  Resolved here rather than by seating ai_follow, because ai_follow
		// is the ESCORT relationship: writing it would leave the scientist trailing
		// the player around the map for the rest of the level after one injection.
		// Distinct local name because fteqcc hoists locals to function scope.
		entity followlead = m.ai_follow;
		if (m.ai_sched == SCHED_HEAL)
		if (m.ai_healtarget)
			followlead = m.ai_healtarget;

		if (!followlead || followlead.health <= 0)
			AI_TaskFail(m);
		else
		{
			// Aim at a point on a ring AROUND the leader, not at the leader.
			//
			// Every follower heading for the same coordinate means they arrive as a
			// scrum, jam against each other, trip the stuck counter and report
			// BLOCKED - measured as 39 follow selections and 38 failures with eight
			// allies escorting one player.  The angle is derived from the edict
			// number so it is stable for the life of the monster (a random one would
			// have them shuffling around the player forever) and well spread: 47
			// degrees per slot walks the circle without repeating for eight of them.
			// ...and the ring is anchored BEHIND THE LEADER rather than to world
			// north.  The per-edict spread is unchanged and is still what keeps
			// them from scrumming; what changes is where the spread is measured
			// from.  A world-absolute bearing means slot N is due north of the
			// player forever, so a follower whose number puts it in front of a
			// walking leader has to cross through them to reach its own spot, and
			// then gets overtaken and has to cross back.  Measured before this:
			// 121 follow selections and 3 arrivals.
			//
			// 200 degrees of arc centred on the leader's back, so nobody is put in
			// the leader's path, and the offset stays a pure function of the edict
			// number - a follower's slot within the formation never changes, only
			// the formation's orientation does.
			//
			// The leader's yaw is sampled ONCE PER LEG (this task runs on schedule
			// selection, not per tick), which is what keeps it from jittering: a
			// player turning on the spot does not drag their escort round with them,
			// it just changes where the next leg aims.
			float slot = num_for_edict(m) * 47;
			slot = slot - floor(slot / 200) * 200;		// -> [0,200)
			makevectors('0 1 0' * (followlead.angles_y + 180 - 100 + slot));
			vector spot = followlead.origin + v_forward * (AI_FOLLOW_STOP * 0.75);

			// Drop the old route, but ONLY when the leg has genuinely changed.
			//
			// The bug being fixed: every other movement schedule clears through
			// TASK_STOP_MOVING ("a stale path from the previous schedule is worse
			// than none"), SCHED_FOLLOW has no such task, and AI_MoveAlongPath
			// gives leftover waypoints PRIORITY over the goal
			// (sv_ai_move.qc:559-592 runs before the no-waypoint fallback) - so a
			// re-selected follower walked back along the previous leg, toward where
			// the leader USED to be, before turning round.  That is the two-point
			// bounce, at the measured 2-3 re-selections a second.
			//
			// THE THRESHOLD IS LOAD-BEARING, and clearing unconditionally is worse
			// than not clearing at all.  Measured: an unconditional clear here took
			// no-waypoint move ticks from ~85% to 100%, because SCHED_FOLLOW
			// re-selects far faster than AI_REPATH_OK lets a replacement be
			// requested - so it threw away a good route and could not get another.
			// Only a goal that has moved further than the arrival radius makes the
			// existing route actually wrong; anything less and the route still ends
			// somewhere useful and is worth keeping while a better one is fetched.
			if (vlen(spot - m.ai_goalpos) > AI_GOAL_REACH)
				AI_PathClear(m);

			m.ai_goalpos = spot;
			AI_PathRequest(m, spot);
			m.ai_goalpos = spot;		// restate: a refused request returns
							// before assigning it
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_GET_PATH_SCRIPT)
	{
		// Same contract as TASK_GET_PATH_FOLLOW and for a stronger reason: a script
		// mark is usually a few metres away in the same room, and the nav graph on
		// these maps is not good enough to be a prerequisite.  Measured on
		// hl_c01_a1: 98 nodes in EIGHT disconnected components, the largest holding
		// 39 of them - so "the graph cannot route there" says almost nothing about
		// whether the monster can walk there.
		//
		// Set the goal, ask the queue as a courtesy, and start walking.  If a route
		// turns up mid-move AI_MoveAlongPath uses it; if not, it heads straight for
		// the mark.  A script must never fail because a search failed.
		if (!m.ai_script)
			AI_TaskFail(m);
		else
		{
			vector mark = m.ai_script.origin;

			// DROP THE MARK TO THE FLOOR FIRST, and this is not a nicety - without
			// it most scripted walks cannot succeed at all.
			//
			// A script mark is a point entity placed by hand in Hammer, and it lands
			// at whatever height the mapper's grid cursor was; nothing forces it to
			// the floor and nothing in Half-Life needs it to be, because HL routes to
			// the goal ENTITY through its node graph and arrives by 2D proximity.
			// Our arrival test is 3D (AI_ReachedGoal), and it rejects a goal more
			// than one step below the monster's feet - deliberately, so a monster
			// does not report "arrived" at a goal one storey down.
			//
			// hl_c01_a1 puts its pondering marks at z=-240 and the scientist who
			// walks them at z=-216.  24 units, against an 18-unit step: the goal was
			// unreachable BY CONSTRUCTION, so the monster walked into it until the
			// stuck counter fired.  Measured as 2 of 3 scripted walks giving up.
			//
			// MOVE_NOMONSTERS so another actor standing on the mark cannot become
			// the "floor", which would put the goal at chest height and reintroduce
			// exactly the problem this removes.
			traceline(mark + '0 0 32', mark - '0 0 256', MOVE_NOMONSTERS, m);
			if (trace_fraction < 1 && !trace_startsolid)
				mark = trace_endpos;

			m.ai_scriptretry = 0;		// fresh mark, fresh budget
			m.ai_goalpos = mark;
			AI_PathRequest(m, mark);
			m.ai_goalpos = mark;		// restate: a refused request returns
							// before assigning it
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_GET_PATH_GUARD)
	{
		// Same contract as TASK_GET_PATH_FOLLOW / _SCRIPT: set the goal, ask the
		// queue as a courtesy, walk.  A guard post is a place in the world, not a
		// route, and refusing to walk there because the graph could not route is
		// how a monster ends up standing still next to its own objective.
		if (!m.ai_guard)
			AI_TaskFail(m);
		else
		{
			// Aim at a point on a ring around the goal rather than at the goal
			// itself, for the reason SCHED_FOLLOW does it: several guards sharing
			// one guard_ent otherwise converge on one coordinate, jam, trip the
			// stuck counter and all report BLOCKED.  desertcircle points three
			// grunt makers at each <base>goal, so this is the normal case.
			//
			// Derived from the edict number so a given monster's slot in the ring
			// never changes; a random bearing would have them shuffling forever.
			// Named apart from SCHED_FOLLOW's `slot`/`spot`: QC locals are
			// function-scoped, not block-scoped, so reusing those names is a
			// duplicate definition rather than a shadow.
			float guardslot = num_for_edict(m) * 47;
			guardslot = guardslot - floor(guardslot / 360) * 360;
			makevectors('0 1 0' * guardslot);
			vector guardspot = m.ai_guard.origin + v_forward * (AI_GUARD_RADIUS * 0.6);

			// Drop to the floor, exactly as the script mark is: a guard object
			// placed by hand (or spawned by trigger_createentity with a -origin
			// key) sits wherever the mapper left it, and AI_ReachedGoal rejects a
			// goal more than one step off the monster's feet.
			traceline(guardspot + '0 0 32', guardspot - '0 0 256', MOVE_NOMONSTERS, m);
			if (trace_fraction < 1 && !trace_startsolid)
				guardspot = trace_endpos;

			m.ai_goalpos = guardspot;
			AI_PathRequest(m, guardspot);
			m.ai_goalpos = guardspot;	// restate: a refused request returns
							// before assigning it
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_GET_PATH_ROAM)
	{
		// Reject goals in another component up front.  Without this the pick is
		// blind, and on a fragmented graph most legs are spent discovering that
		// the destination is unreachable - one path request, one NOPATH, then a
		// 3-7 s throttle before trying again.  See Nav_PickRoamGoal.
		float ni = Nav_PickRoamGoal(m.origin, AI_ROAM_MIN, AI_ROAM_MAX,
		                            Nav_ComponentAt(m.origin));
		if (ni < 0)
		{
			// Nowhere to go.  Push the throttle out so this does not become a
			// per-tick search over the whole node array on a map where the monster
			// is boxed into a corner of the graph.
			m.ai_roam_next = time + 5;
			AI_TaskFail(m);
		}
		else
		{
			vector roamspot = Nav_NodePos(ni);
			m.ai_roam_goal = roamspot;
			// A wander leg is unhurried on purpose - see SCHED_ROAM's trailing
			// wait.  The throttle is what keeps a monster that arrives instantly
			// (a node just past AI_ROAM_MIN) from re-picking at schedule rate.
			m.ai_roam_next = time + 3 + random() * 4;
			m.ai_goalpos = roamspot;
			AI_PathRequest(m, roamspot);
			m.ai_goalpos = roamspot;
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_GET_PATH_SWIM)
	{
		// Pick somewhere in the water to swim to.  NOT a nav node: the node graph
		// is built from walkable floor and there is none inside a pool, which is
		// the other half of why a swimmer had nowhere to go.
		//
		// The goal is written straight into ai_goalpos with no path behind it.
		// AI_MoveAlongPath falls through to `want = m.ai_goalpos` when it has no
		// waypoint, so a pathless goal yields exactly the straight-line swim HL
		// produces by integrating a heading.
		//
		// TWO PASSES, and the second one matters.  hl_c06's leech pool is only
		// 352 x 368 units, so a long candidate leaves the water far more often
		// than not; a single long pass would fail all its tries, AI_TaskFail into
		// SCHED_FAIL, and re-select every schedule tick — a different way of
		// standing still.  Pass 2 halves the reach and tries again before giving
		// up.
		float si, sgot = FALSE;
		vector sspot = m.origin;
		float sreach = 224;

		while (sreach >= 56 && !sgot)
		{
			si = 0;
			while (si < 6)
			{
				makevectors([0, random() * 360, 0]);
				sspot = m.origin
				      + v_forward * (48 + random() * sreach)
				      + [0, 0, (random() - 0.5) * 64];
				// Both ends have to be wet, or the leech aims at the bank.
				if (AI_InWater(sspot))
				{
					traceline(m.origin, sspot, MOVE_NOMONSTERS, m);
					if (trace_fraction >= 1)
					{
						sgot = TRUE;
						si = 6;
					}
				}
				si = si + 1;
			}
			sreach = sreach * 0.5;
		}

		if (!sgot)
		{
			AI_TaskFail(m);
		}
		else
		{
			AI_PathClear(m);
			m.ai_goalpos = sspot;
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_PLANT_ON_SCRIPT)
	{
		// HL's TASK_PLANT_ON_SCRIPT (schedule.cpp:1279-1288).  The walk got the
		// actor NEAR the mark; this puts it exactly ON it, so the pose plays where
		// the mapper authored it instead of up to AI_GOAL_REACH (40 units) away.
		//
		// TWO DELIBERATE DIVERGENCES from the SDK's one-liner, both because our
		// arrival test is stricter than HL's and our physics is less forgiving:
		//
		//  1. Plant on ai_goalpos, not on ai_script.origin.  TASK_GET_PATH_SCRIPT
		//     already floor-dropped the mark into ai_goalpos, and it has to: a
		//     script mark is a hand-placed point entity at whatever height the
		//     Hammer cursor was, and hl_c01_a1's pondering marks sit 24 units
		//     below the scientist who walks them.  Planting on the raw key would
		//     bury him to the knees - HL gets away with it because its monsters
		//     settle, ours are pinned by FL_ONGROUND.
		//
		//  2. Refuse the plant if the MARK ITSELF is solid.  HL plants
		//     unconditionally, which is safe there because it only reaches this
		//     task after a successful route.  We reach it after the give-up path
		//     too (a blocked scripted walk completes rather than failing, so a
		//     script can never soft-lock a campaign - see AI_TaskRun's
		//     ai_dbg_script_stuck branch), and teleporting an actor into the very
		//     obstruction that stopped it would turn "stopped short" into "stuck
		//     in a wall".  Stopped short is the better failure.
		//
		//     WORLD ONLY, AND A DEGENERATE TRACE RATHER THAN A SWEEP.  Both of
		//     those took a wrong turn first and the map corrected each in turn:
		//
		//     - Sweeping origin -> mark and refusing on any hit rejected the two
		//       airlock marks ("blocked by func_button").  This is a TELEPORT, so
		//       the only question is whether the mark is standable, not whether
		//       the straight line to it is walkable.
		//     - Refusing on ANY solid at the mark still rejected them, because a
		//       retina-scanner mark is placed hard against the panel by design and
		//       the guard's own 32-wide hull genuinely overlaps the wall-mounted
		//       func_button.  Half-Life plants straight through that: its version
		//       is a bare `pev->origin = ...` with no collision test of any kind,
		//       and a monster resting inside a wall panel's bbox bothers nothing.
		//
		//     So the only thing worth refusing is a mark inside WORLD
		//     architecture, which is the give-up path's genuine hazard.  When the
		//     world makes a start point solid, FTE's SV_ClipToLinks returns before
		//     clipping any entity, so trace_ent is left as world - which makes
		//     `startsolid && trace_ent == world` a reliable "the mark is inside
		//     the map" and not merely "something is here".
		if (!m.ai_script)
			AI_TaskFail(m);
		else
		{
			// `plantpos` rather than `mark`: fteqcc hoists locals to function
			// scope, and TASK_GET_PATH_SCRIPT above already owns that name.
			vector plantpos = m.ai_goalpos;
			tracebox(plantpos, m.mins, m.maxs, plantpos, MOVE_NOMONSTERS, m);
			if (!(trace_startsolid && trace_ent == world))
			{
				if (ai_cached_debug && vlen(plantpos - m.origin) > 1)
					dprint(sprintf("[script] %s planted %g units onto \"%s\"\n",
					               m.classname, vlen(plantpos - m.origin),
					               m.ai_script.targetname));
				setorigin(m, plantpos);
				m.velocity = '0 0 0';
				m.flags    = m.flags | FL_ONGROUND;
			}
			else if (ai_cached_debug)
				dprint(sprintf("[script] %s could not plant onto \"%s\": mark %v is inside world geometry (%g units short)\n",
				               m.classname, m.ai_script.targetname, plantpos,
				               vlen(plantpos - m.origin)));
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_HEAL)
	{
		// scientist.cpp:1088-1100, CScientist::Heal.  Two distance gates, not one,
		// and they are deliberately different numbers: CanHeal (checked when the
		// schedule is CHOSEN) has no range term at all, tlHeal's first task walks
		// to within 50, and Heal itself refuses past 100 - so a target that walked
		// off during the approach gets the needle put away rather than a heal at
		// range.  Reproduced exactly, including the fact that a refusal here does
		// NOT start the cooldown: HL leaves m_healTime alone on that path, so the
		// scientist may try again immediately, which is what makes him "keep trying
		// to walk toward the player".
		//
		// TakeHealth's clamp is the max_health cap, and it is what stops this
		// topping a player past 100.
		entity ht = m.ai_healtarget;
		if (!ht)
			ht = m.ai_follow;
		if (ht)
		if (ht.health > 0)
		if (vlen(ht.origin - m.origin) <= 100)
		{
			float amt = cvar("sv_ai_scientist_heal");
			if (amt <= 0)
				amt = 25;			// HL sk_scientist_heal
			float cap = ht.max_health;
			if (cap <= 0)
				cap = 100;
			if (ht.health < cap)
			{
				ht.health = min(cap, ht.health + amt);
				m.ai_healtime = time + 60;	// scientist.cpp:1099, "don't heal again for 1 minute"
				if (ai_cached_debug)
					dprint(sprintf("[sci] %s healed %s for %g -> %g\n",
					               m.classname, ht.classname, amt, ht.health));
			}
		}
		AI_TaskComplete(m);
	}
	else if (op == TASK_FACE_SCRIPT)
	{
		// The mark's yaw is the pose's facing.  HL sets ideal_yaw from the script
		// entity's angles here and so do we; the turn itself is polled in TaskRun.
		if (!m.ai_script)
			AI_TaskFail(m);
		else
			m.ai_yaw_ideal = AI_AngleNorm(m.ai_script.angles_y);
	}
	else if (op == TASK_WAIT_FOR_SCRIPT)
	{
		// Start the hold pose.  Script_StartIdle is idempotent and also runs at
		// possession time, so a monster claimed while dormant is already in its
		// pose before this task ever gets a tick.
		Script_StartIdle(m);
	}
	else if (op == TASK_PLAY_SCRIPT)
	{
		Script_StartPlay(m);
	}
	else if (op == TASK_BM_FIND_NODE)
	{
		// bigmomma.cpp:925-937.  The re-read looks redundant and is not: when the
		// advance bit is CLEAR she is being sent at a node she has already stood
		// on - the health gate held her there and the player has now shot it off -
		// and ai_bm_next was moved past it by NodeReach the first time round.
		// Re-reading the CURRENT node's target is what stops her skipping the node
		// after it.  Following ai_bm_next blindly here would drop a node from the
		// chain every time a health gate fired, which on hl_c15 is nine of them.
		if (!(m.ai_bm_mem & BMMEM_ADVANCE) && m.ai_bm_node)
			m.ai_bm_next = m.ai_bm_node.target;
		BigMomma_NodeStart(m);

		// FAIL, RATHER THAN COMPLETE, WHEN THE PATH HAS JUST ENDED.  Half-Life
		// completes unconditionally here and leaves m_hTargetEnt pointing at the
		// node it has already finished with, so the remaining ten tasks all run
		// against that node a second time - including TASK_PROCESS_NODE, which
		// fires its reachtarget again.  On hl_c15 the final node has no
		// reachtarget so the double-fire is invisible there, but "the last stop
		// on the chain fires its target twice" is not a behaviour to inherit
		// just because one map does not notice.  Failing here sends her to the
		// fail schedule instead, which clears the condition and steps aside.
		if (m.ai_bm_mem & BMMEM_FINISHED)
			AI_TaskFail(m);
		else
			AI_TaskComplete(m);
	}
	else if (op == TASK_BM_PRESEQUENCE || op == TASK_BM_SEQUENCE)
	{
		// bigmomma.cpp:951-975.  A node with no sequence key, or one naming a
		// sequence big_mom.mdl does not carry, completes instantly rather than
		// failing - which is HL's behaviour and also the only safe one, since a
		// failure here would divert the whole chain into the fail schedule and
		// stall the map on a missing animation.  Only 5 of hl_c15's 22 nodes name
		// a reachsequence and 3 a presequence, so the instant path is the common
		// one.
		if (!BigMomma_NodeSeq(m, (op == TASK_BM_PRESEQUENCE)))
			AI_TaskComplete(m);
		// else: AI_TaskRun polls AI_SeqDone, exactly as TASK_PLAY_SEQ_NAMED does.
	}
	else if (op == TASK_BM_PATH_NODE)
	{
		if (!m.ai_bm_node)
			AI_TaskFail(m);
		else
		{
			// Same courtesy contract as TASK_GET_PATH_SCRIPT and _GUARD: set the
			// goal, ask the queue, and set off regardless of whether a route comes
			// back.  It matters more for her than for anything else on the map -
			// she is 190 units wide and 190 tall, so almost no nav link on hl_c15
			// was built for a body her size, and a node walk that required a route
			// would refuse to start on most legs of the chain.
			vector nodepos = m.ai_bm_node.origin;

			// Floor-drop, for the reason the script mark is dropped: an
			// info_bigmomma is a hand-placed point entity and lands at whatever
			// height the Hammer cursor was.  hl_c15's chain is authored at z=0,
			// -192, -824 and -1288 while the floors under those nodes are not
			// always at the key's own height, and AI_ReachedGoal rejects a goal
			// more than one step off her feet.
			traceline(nodepos + '0 0 32', nodepos - '0 0 256', MOVE_NOMONSTERS, m);
			if (trace_fraction < 1 && !trace_startsolid)
				nodepos = trace_endpos;

			// WALK OR RUN IS THE NODE'S DECISION, not the schedule's, which is the
			// whole reason this is not TASK_GET_PATH_* followed by a constant
			// TASK_WALK_PATH: SF_INFOBM_RUN is a per-node spawnflag and a schedule
			// table's argument is fixed at build time.  16 of hl_c15's 22 nodes
			// carry it, so the chase legs run and the set-piece legs stalk.
			float nodeact = BigMomma_NodeRuns(m) ? ACT_RUN : ACT_WALK;
			m.ai_moveact = nodeact;
			AI_SetActivity(m, nodeact);

			m.ai_goalpos = nodepos;
			AI_PathRequest(m, nodepos);
			m.ai_goalpos = nodepos;		// restate: a refused request returns
							// before assigning it
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_BM_NODE_YAW)
	{
		// bigmomma.cpp:977-980.  A node with no angles keeps her current facing
		// rather than snapping her to zero - BigMomma_NodeYaw owns that fallback.
		m.ai_yaw_ideal = AI_AngleNorm(BigMomma_NodeYaw(m));
		AI_TaskComplete(m);
	}
	else if (op == TASK_BM_WAIT_NODE)
	{
		m.ai_taskend = time + BigMomma_NodeDelay(m);
	}
	else if (op == TASK_BM_PROCESS_NODE)
	{
		BigMomma_NodeReach(m);
		AI_TaskComplete(m);
	}
	else if (op == TASK_BM_NODE_DELAY)
	{
		m.ai_bm_nodetime = time + a;
		AI_TaskComplete(m);
	}
	else if (op == TASK_GET_PATH_LKP)
	{
		if (m.ai_lastseen <= 0)
			AI_TaskFail(m);
		else
		{
			AI_PathRequest(m, m.ai_lastseenpos);
			m.ai_taskend = time + 2;
		}
	}
	else if (op == TASK_GET_PATH_SOUND)
	{
		// The noise position, not the enemy's.  Fails when there is nothing
		// recorded, which drops the schedule and returns the monster to whatever
		// it was doing - the right outcome for "I have already been there".
		if (m.ai_soundpos == '0 0 0')
			AI_TaskFail(m);
		else
		{
			AI_PathRequest(m, m.ai_soundpos);
			m.ai_taskend = time + 2;
		}
	}
	else if (op == TASK_GET_PATH_FLEE)
	{
		// Straight away from the enemy, `a` units.  Deliberately NOT a clever
		// cover search: a fleeing animal runs, it does not solve for the best
		// corner.  If the graph cannot reach the point the task fails and the
		// fail schedule handles it, which is also what happens when a monster
		// is cornered - the right outcome either way.
		if (!m.ai_enemy)
			AI_TaskFail(m);
		else
		{
			vector away = m.origin - m.ai_enemy.origin;
			away_z = 0;
			if (away == '0 0 0')
				away = '1 0 0';		// exactly co-located; any direction will do
			AI_PathRequest(m, m.origin + normalize(away) * a);
			m.ai_taskend = time + 2;
		}
	}
	else if (op == TASK_GET_PATH_AWAY)
	{
		// TASK_MOVE_AWAY_PATH, talkmonster.cpp:458-481.  HL builds the retreat point
		// from `ideal_yaw + 180` - the yaw CTalkMonster::Touch just aimed at the
		// player - walks `flData` units along it, and falls back to cover before
		// giving up:
		//
		//     if ( MoveToLocation( ACT_WALK, 2, dir ) )   TaskComplete();
		//     else if ( FindCover( ... ) )                TaskComplete();
		//     else                                        TaskFail();
		//
		// That middle arm is the answer to "they run into a corner - can they move
		// somewhere that isn't just straight away from the player".  Straight back
		// is the FIRST choice, not the only one, and Cover_Find already scores
		// candidates on whether they break line of sight rather than on which way
		// they point, so it naturally picks round a corner instead of into one.
		//
		// Cover_CanReach is what stands in for HL's synchronous MoveToLocation.
		// AI_PathRequest only queues, so its return value cannot answer "is that
		// spot any good" - but Cover_CanReach sweeps the hull and checks there is
		// floor at the far end, which is the same question and is answerable now.
		// Without it the fallback would be unreachable in practice and this would
		// be HL's first arm alone, i.e. the corner-walking behaviour again.
		// Locals are FUNCTION-scoped in QC, not block-scoped, so these carry an
		// `away_` prefix rather than reusing `away`/`spot`/`cr` from the sibling
		// task arms above - fteqcc merges same-named declarations and warns.
		vector away_dir;
		makevectors('0 1 0' * (m.ai_yaw_ideal + 180));
		away_dir   = v_forward;
		away_dir_z = 0;
		if (away_dir == '0 0 0')
			away_dir = '1 0 0';

		vector away_spot = m.origin + normalize(away_dir) * a;
		if (Cover_CanReach(m, away_spot))
		{
			AI_PathClear(m);
			m.ai_goalpos = away_spot;
			AI_TaskComplete(m);
		}
		else
		{
			float away_cr = Cover_FindFrom(m, m.ai_pushpos, m.ai_pushpos + '0 0 24');
			if (away_cr == COVER_LOCAL)
				AI_TaskComplete(m);
			else if (away_cr == COVER_ROUTED)
				m.ai_taskend = time + 2;
			else
				AI_TaskFail(m);
		}
	}
	else if (op == TASK_FIND_COVER_ENEMY)
	{
		// schedule.cpp:739-770.  The enemy may legitimately be gone by the time
		// this runs - the schedule was chosen a tick ago - and HL's answer is to
		// take cover from ITSELF rather than fail, which Cover_Find implements.
		m.ai_coverwait = FALSE;

		// A LIVE GRENADE OUTRANKS THE ENEMY.  While a danger position is fresh the
		// thing to get away from is the grenade, not the man who threw it - they
		// are usually in opposite directions, and hiding from the thrower while
		// standing on the grenade is worse than not moving at all.
		float cr;
		if (time < m.ai_danger_until)
		{
			ai_dbg_danger_cover = ai_dbg_danger_cover + 1;
			cr = Cover_FindFrom(m, m.ai_dangerpos, m.ai_dangerpos + '0 0 24');
		}
		else
			cr = Cover_Find(m, m.ai_enemy);
		if (cr == COVER_LOCAL)
		{
			// The goal is already set and needs no route.  Complete now: waiting
			// on a path that was never requested is a two-second stall ending in
			// COND_NO_PATH, which would turn every successful sidestep into a
			// failed schedule.
			AI_TaskComplete(m);
		}
		else if (cr == COVER_ROUTED)
		{
			m.ai_coverwait = TRUE;
			m.ai_taskend   = time + 2;
		}
		else
		{
			// No cover, or a route that could not even be asked for.  Back off
			// before failing: without this a monster in an open room re-selects
			// cover, searches, fails, and does it again at the full tick rate.
			m.ai_covernext = time + AI_COVER_RETRY;
			AI_TaskFail(m);
		}
	}
	else if (op == TASK_WALK_PATH || op == TASK_RUN_PATH)
	{
		m.ai_moveact = a;
		AI_SetActivity(m, a);
		AI_TaskComplete(m);		// TASK_WAIT_FOR_MOVE does the walking
	}
	else if (op == TASK_WAIT_FOR_MOVE)
	{
		m.ai_stuck     = 0;
		m.ai_lastorg   = m.origin;
		m.ai_turnticks = 0;
	}
	else if (op == TASK_STOP_MOVING)
	{
		AI_StopMoving(m);
		// Drop the route too.  Almost every schedule opens with this, and a
		// stale path from the previous schedule is worse than none: it points
		// somewhere the monster no longer wants to be.
		AI_PathClear(m);
		AI_TaskComplete(m);
	}
	else if (op == TASK_RANGE_ATTACK1 || op == TASK_RANGE_ATTACK2
	      || op == TASK_MELEE_ATTACK1)
	{
		float atkact = ACT_MELEE_ATTACK1;
		if (op == TASK_RANGE_ATTACK1)	atkact = ACT_RANGE_ATTACK1;
		if (op == TASK_RANGE_ATTACK2)	atkact = ACT_RANGE_ATTACK2;

		AI_ResetActivity(m);
		AI_SetActivity(m, atkact);
		if (m.ai_startattack)
		{
			oldself = self;
			self = m;
			m.ai_startattack();
			self = oldself;
		}
	}
	else if (op == TASK_IDLE_SOUND)
	{
		// The virtual wins; the family is the fallback for the classes whose voice
		// is nothing but "play one of these".  Same shape at all four sites below.
		if (m.ai_idlesound)
		{
			oldself = self;
			self = m;
			m.ai_idlesound();
			self = oldself;
		}
		else
			// AI_SndSpeak, not AI_SndPlay: idle chatter is the one family Half-Life
			// really does silence for a GAG monster (monsterstate.cpp:69), and the
			// only one.  Every other call site in the tree - gunfire, claws, alert,
			// pain, death, footsteps - is unconditional, which is what makes a
			// gagged ambush squad audible the moment it opens fire.
			AI_SndSpeak(m, CHAN_VOICE, m.ai_snd_idle);
		AI_TaskComplete(m);
	}
	else if (op == TASK_ALERT_SOUND)
	{
		if (m.ai_alertsound)
		{
			oldself = self;
			self = m;
			m.ai_alertsound();
			self = oldself;
		}
		else
			AI_SndPlay(m, CHAN_VOICE, m.ai_snd_alert);
		AI_TaskComplete(m);
	}
	else if (op == TASK_DIE)
	{
		if (m.ai_death)
		{
			oldself = self;
			self = m;
			m.ai_death();
			self = oldself;
		}
		else
			AI_SndPlay(m, CHAN_VOICE, m.ai_snd_die);
		// The latch AI_SelectSchedule reads to stop handing this corpse another
		// death schedule.  Set here rather than in AI_Died because THIS is the
		// point the death actually finished animating.
		m.ai_dead_done = TRUE;
		AI_TaskComplete(m);
	}
	else if (op == TASK_CHECK_ATTACK)
	{
		AI_GatherConditions(m);
		AI_TaskComplete(m);
	}
	else if (op == TASK_FORGET_ENEMY)
	{
		m.ai_enemy = world;
		AI_TaskComplete(m);
	}
	else if (op == TASK_SET_YAWSPEED)
	{
		m.ai_yaw_speed = a;
		AI_TaskComplete(m);
	}
	else if (op == TASK_SET_SEQ_NAMED)
	{
		// Instant.  A FAILED resolve is a real outcome, not a no-op: it means the
		// model does not carry that name, and completing anyway would leave a
		// turret frozen on whatever it was showing while the schedule marched on.
		if (!AI_SetSequenceNamed(m, Sched_SeqName(a), b))
			AI_TaskFail(m);
		else
			AI_TaskComplete(m);
	}
	else if (op == TASK_PLAY_SEQ_NAMED)
	{
		if (!AI_SetSequenceNamed(m, Sched_SeqName(a), FALSE))
			AI_TaskFail(m);
		// else: AI_TaskRun polls AI_SeqDone, exactly as TASK_PLAY_SEQUENCE does.
	}
	else
	{
		// Unknown opcode.  The schedule self-test catches this at boot; here it
		// must not wedge the monster, so treat it as an instant no-op.  Say so
		// once per opcode anyway: the self-test only runs under sv_ai_selftest,
		// and a class-built schedule added later must not be able to skip a step
		// in silence on a server where that cvar is off.
		if (op > TASK_NONE && op < TASK_OP_COUNT && !ai_op_griped[op])
		{
			ai_op_griped[op] = TRUE;
			dprint(sprintf("[ai] task opcode %g has no interpreter case (schedule \"%s\") - skipped\n",
			               op, Sched_Name(m.ai_sched)));
		}
		AI_TaskComplete(m);
	}
};

// Which opcodes AI_TaskStart above actually implements.  Read by
// AI_SchedSelfTest, which cannot see this file's chain and would otherwise have
// no way to tell a handled opcode from a declared-but-forgotten one.
//
// This IS a hand-maintained mirror of the if/else chain, and mirrors drift - so
// the runtime gripe above exists as the second line of defence, catching the
// opposite mistake (listed here, no case) that this function cannot.  Keep the
// two in the same commit as any new opcode.
float(float op) AI_TaskOpHandled =
{
	if (op == TASK_WAIT)			return TRUE;
	if (op == TASK_WAIT_RANDOM)		return TRUE;
	if (op == TASK_WAIT_INDEFINITE)		return TRUE;
	if (op == TASK_SET_ACTIVITY)		return TRUE;
	if (op == TASK_PLAY_SEQUENCE)		return TRUE;
	if (op == TASK_PLAY_DEATH)		return TRUE;
	if (op == TASK_PLAY_FLINCH)		return TRUE;
	if (op == TASK_FLAME_SWEEP)		return TRUE;
	if (op == TASK_SET_FAIL_SCHED)		return TRUE;
	if (op == TASK_SET_STATE)		return TRUE;
	if (op == TASK_CLEAR_COND)		return TRUE;
	if (op == TASK_FACE_ENEMY)		return TRUE;
	if (op == TASK_FACE_IDEAL)		return TRUE;
	if (op == TASK_TURN_RANDOM)		return TRUE;
	if (op == TASK_GET_PATH_ENEMY)		return TRUE;
	if (op == TASK_GET_PATH_LKP)		return TRUE;
	if (op == TASK_GET_PATH_SOUND)		return TRUE;
	// GUARD and ROAM were missing from this list while the interpreter has had
	// cases for both since they were added (:1727, :1768).  The consequence was
	// only that the schedule self-test reported BAD=2 on every boot - but a
	// self-test that is permanently unhappy is a self-test nobody reads, which
	// costs more than the thing it was failing to find.
	if (op == TASK_GET_PATH_GUARD)		return TRUE;
	if (op == TASK_GET_PATH_ROAM)		return TRUE;
	if (op == TASK_GET_PATH_SWIM)		return TRUE;
	if (op == TASK_GET_PATH_FLEE)		return TRUE;
	if (op == TASK_GET_PATH_AWAY)		return TRUE;
	if (op == TASK_FIND_COVER_ENEMY)	return TRUE;
	if (op == TASK_GET_PATH_FOLLOW)		return TRUE;
	if (op == TASK_WALK_PATH)		return TRUE;
	if (op == TASK_RUN_PATH)		return TRUE;
	if (op == TASK_WAIT_FOR_MOVE)		return TRUE;
	if (op == TASK_STOP_MOVING)		return TRUE;
	if (op == TASK_RANGE_ATTACK1)		return TRUE;
	if (op == TASK_RANGE_ATTACK2)		return TRUE;
	if (op == TASK_MELEE_ATTACK1)		return TRUE;
	if (op == TASK_IDLE_SOUND)		return TRUE;
	if (op == TASK_ALERT_SOUND)		return TRUE;
	if (op == TASK_DIE)			return TRUE;
	if (op == TASK_CHECK_ATTACK)		return TRUE;
	if (op == TASK_FORGET_ENEMY)		return TRUE;
	if (op == TASK_SET_YAWSPEED)		return TRUE;
	if (op == TASK_SET_SEQ_NAMED)		return TRUE;
	if (op == TASK_PLAY_SEQ_NAMED)		return TRUE;
	if (op == TASK_GET_PATH_SCRIPT)		return TRUE;
	if (op == TASK_PLANT_ON_SCRIPT)		return TRUE;
	if (op == TASK_FACE_SCRIPT)		return TRUE;
	if (op == TASK_WAIT_FOR_SCRIPT)		return TRUE;
	if (op == TASK_PLAY_SCRIPT)		return TRUE;
	if (op == TASK_BM_FIND_NODE)		return TRUE;
	if (op == TASK_BM_PRESEQUENCE)		return TRUE;
	if (op == TASK_BM_PATH_NODE)		return TRUE;
	if (op == TASK_BM_NODE_YAW)		return TRUE;
	if (op == TASK_BM_WAIT_NODE)		return TRUE;
	if (op == TASK_BM_SEQUENCE)		return TRUE;
	if (op == TASK_BM_PROCESS_NODE)		return TRUE;
	if (op == TASK_BM_NODE_DELAY)		return TRUE;
	if (op == TASK_HEAL)			return TRUE;
	return FALSE;
};

// Polled every decision tick until it completes the task.
void(entity m, float dt) AI_TaskRun =
{
	float op = Sched_Op(m.ai_sched, m.ai_task);

	if (op == TASK_WAIT || op == TASK_WAIT_RANDOM)
	{
		if (time >= m.ai_taskend)
			AI_TaskComplete(m);
	}
	else if (op == TASK_WAIT_INDEFINITE)
	{
		// Never completes by itself; the schedule's interrupt mask ends it.
	}
	else if (op == TASK_PLAY_SEQUENCE || op == TASK_PLAY_SEQ_NAMED
	      || op == TASK_PLAY_DEATH    || op == TASK_PLAY_FLINCH
	      || op == TASK_BM_PRESEQUENCE || op == TASK_BM_SEQUENCE)
	{
		if (AI_SeqDone(m))
			AI_TaskComplete(m);
	}
	else if (op == TASK_BM_WAIT_NODE)
	{
		// bigmomma.cpp:1059-1066.  SF_INFOBM_WAIT is "stay here until something
		// else moves her on", so the task simply never completes and the schedule
		// parks - which is safe because the only things that can restart the chain
		// are the health gate and a fresh advance bit, both of which come from
		// outside this schedule.  No node in the corpus sets it; it is transcribed
		// because a stall with no way out is exactly the failure a map author
		// would use it to build deliberately.
		if (BigMomma_NodeWaits(m))
			return;
		if (time >= m.ai_taskend)
			AI_TaskComplete(m);
	}
	else if (op == TASK_FLAME_SWEEP)
	{
		// Driven by the CLOCK, not by the sequence: ACT_MELEE_ATTACK2 on garg.mdl
		// loops, so AI_SeqDone would never fire.
		if (time >= m.ai_taskend)
		{
			Garg_FlameOff(m);
			AI_TaskComplete(m);
		}
		else
			Garg_FlameUpdate(m, dt);
	}
	else if (op == TASK_FACE_ENEMY)
	{
		if (!m.ai_enemy)
		{
			AI_TaskFail(m);
			return;
		}
		AI_YawToward(m, m.ai_enemy.origin);
		if (AI_FacingIdeal(m))
			AI_TaskComplete(m);
	}
	else if (op == TASK_FACE_IDEAL)
	{
		if (AI_FacingIdeal(m))
			AI_TaskComplete(m);
	}
	else if (op == TASK_FACE_SCRIPT)
	{
		if (!m.ai_script)
		{
			AI_TaskFail(m);
			return;
		}
		if (AI_FacingIdeal(m))
		{
			Script_AtMark(m);
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_WAIT_FOR_SCRIPT)
	{
		// Re-assert the pose every tick.  Cheap (AI_SetSequenceNamed is idempotent
		// on the name) and it is what stops a monster that was flinched or shoved
		// out of its sequence from standing in the wrong animation for the rest of
		// the map.
		Script_StartIdle(m);
		if (Script_MayPlay(m))
		{
			m.ai_scriptstate = SCRIPTST_PLAY;
			AI_TaskComplete(m);
		}
	}
	else if (op == TASK_PLAY_SCRIPT)
	{
		if (AI_SeqDone(m))
		{
			// Script_SequenceDone releases the actor and THEN fires the script's
			// trigger chain (sv_scripted.qc:780 -> Script_Release:408), which is
			// Half-Life's own ordering and exists precisely so a second scene can
			// take the monster straight over (scripted.cpp:571-579).
			//
			// So it may come back POSSESSED.  Script_Possess deliberately resets the
			// schedule to start the new scene cleanly (ai_sched = SCHED_NONE,
			// ai_task = 0, ai_taskdone = FALSE), and an unconditional
			// AI_TaskComplete here immediately undid that - marking a task done on a
			// schedule that no longer exists, so AI_RunSchedule advanced past the new
			// scene's FIRST task. The tell was a hand-off scene that silently skipped
			// its opening beat.
			entity before = m.ai_script;
			Script_SequenceDone(m);
			if (m.ai_script == before)
				AI_TaskComplete(m);
		}
	}
	else if (op == TASK_FIND_COVER_ENEMY)
	{
		// Only reached in the ROUTED case; the local one completed on start.
		if (AI_HasPath(m))
		{
			AI_TaskComplete(m);
			return;
		}
		if (time >= m.ai_taskend)
		{
			m.ai_covernext = time + AI_COVER_RETRY;
			m.ai_cond      = m.ai_cond | COND_NO_PATH;
			AI_TaskFail(m);
		}
	}
	else if (op == TASK_GET_PATH_ENEMY || op == TASK_GET_PATH_LKP
	      || op == TASK_GET_PATH_FLEE)
	{
		if (AI_HasPath(m))
		{
			AI_TaskComplete(m);
			return;
		}
		if (time >= m.ai_taskend)
		{
			// The queue answered with "no route" or never got to us.  NO_PATH
			// rather than a bare failure, so the chase schedule's interrupt mask
			// can tell this apart from a task that merely went wrong.
			m.ai_cond = m.ai_cond | COND_NO_PATH;
			AI_TaskFail(m);
		}
	}
	else if (op == TASK_WAIT_FOR_MOVE)
	{
		// A FOLLOWER arrives at its own distance, not at the goal.
		//
		// Without this the escort walks to the leader's exact origin, because that
		// is what the path was requested to and AI_GOAL_REACH is 40 units - so it
		// shoves into the player, cannot get closer, trips the stuck counter and
		// reports BLOCKED.  Measured as 27 follow selections and 27 failures, a
		// perfect 1:1: the schedule could not succeed even once, by construction.
		// AI_FOLLOW_STOP is where an escort is meant to stand, so that is where the
		// move is finished.
		if (m.ai_follow && m.ai_sched == SCHED_FOLLOW)
		{
			float fd = vlen(m.ai_follow.origin - m.origin);
			if (fd <= AI_FOLLOW_STOP)
			{
				AI_StopMoving(m);
				AI_TaskComplete(m);
				return;
			}

			// AN ESCORT WALKS WHEN IT IS CLOSE BEHIND YOU.
			//
			// This is where the walk animation went.  SCHED_FOLLOW asks for
			// ACT_RUN unconditionally, so a scientist trailing you two metres
			// back sprinted on the spot for the whole map - and since follow is
			// the ONLY movement most allies ever do, the walk cycle was
			// effectively unreachable in normal play.
			//
			// Half-Life decides it by DISTANCE, not by schedule:
			// TASK_MOVE_TO_TARGET_RANGE (AI_BaseNPC_Schedule.cpp:429-436) walks
			// under 190 units, runs at 270 or more, and holds whatever it was
			// doing in between.  The SDK's own comment calls that gap "overlap
			// the range to prevent oscillation" - without it an escort at
			// exactly the threshold flickers between the two cycles every tick.
			//
			// ...and if it is frightened, the SCARED variants of both.  That is
			// Half-Life's slFollowScared / TASK_MOVE_TO_TARGET_RANGE_SCARED
			// (scientist.cpp:154-173, :519, :566-574), which uses the very same 190
			// and 270 thresholds - an escorting scientist who has seen something
			// hostile shuffles instead of walking and bolts instead of running. The
			// activity fallback chain sends any rig without the scared cycles back to
			// the plain ones, so this is safe on barney, otis and the ally grunts.
			float scared = (m.ai_enemy && AI_Fears(m, m.ai_enemy));

			float want = m.ai_moveact;
			if (fd < AI_FOLLOW_WALK_UNDER)
				want = scared ? ACT_WALK_SCARED : ACT_WALK;
			else if (fd >= AI_FOLLOW_RUN_OVER)
				want = scared ? ACT_RUN_SCARED : ACT_RUN;

			if (want != m.ai_moveact)
			{
				m.ai_moveact = want;
				AI_SetActivity(m, want);	// idempotent; re-asserting is free
			}
		}

		float inscript = (m.ai_script
		               && (m.ai_sched == SCHED_SCRIPT_WALK || m.ai_sched == SCHED_SCRIPT_RUN));

		// Sven's `moveto_radius` (157 uses corpus-wide) is "close enough counts as
		// arrived", and it exists because a mark inside a doorway or behind a desk
		// is not always standable.  Honoured here rather than inside the movement
		// code because it is a property of the SCRIPT, and nothing else in the AI
		// has a per-goal tolerance.
		if (inscript && m.ai_script.moveto_radius > 0)
			if (vlen(m.ai_script.origin - m.origin) <= m.ai_script.moveto_radius)
			{
				AI_StopMoving(m);
				AI_TaskComplete(m);
				return;
			}

		// An info_bigmomma node has its OWN arrival tolerance, and it is the same
		// kind of thing as moveto_radius above - a per-goal distance that belongs
		// to the destination rather than to the mover.  It is not decoration:
		// hl_c15 authors 96, 64, 32 and 2, against AI_GOAL_REACH's fixed 40, and
		// the gonarch is 190 units across.  Made to walk to within 40 units of a
		// node placed against a wall she would grind into the geometry until the
		// stuck counter fired, which is the same 1:1 selection-to-failure shape
		// SCHED_FOLLOW had before it got its own arrival distance.
		//
		// HL tests `distance < GetNodeRange() || MovementIsComplete()`
		// (bigmomma.cpp:1037-1053) and the OR is load-bearing at the far end of
		// the chain, where `end` carries radius 2: two units is tighter than
		// anything the mover can promise, so without the fallback the last node
		// could never be reached.  AI_MoveAlongPath returning ARRIVED below is
		// that second arm, so this test only ever WIDENS the tolerance.
		if (m.ai_sched == SCHED_BIGMOMMA_NODE && m.ai_bm_node)
		{
			float noderange = BigMomma_NodeRange(m);
			if (noderange > 0 && vlen(m.ai_bm_node.origin - m.origin) < noderange)
			{
				AI_StopMoving(m);
				AI_TaskComplete(m);
				return;
			}
		}

		float spd = AI_ActivityIsRun(m.ai_moveact) ? m.ai_speed_run : m.ai_speed_walk;
		if (spd <= 0)
			spd = 100;
		float r = AI_MoveAlongPath(m, spd * dt);

		if (r == AIMOVE_ARRIVED)
		{
			// SELECTIONS AND ARRIVALS ARE COUNTED SEPARATELY, and the gap between
			// them is the only honest measure of whether cover works.  "Cover was
			// chosen 40 times" says nothing: a monster that picks cover and never
			// reaches it is a monster that stands in the open looking indecisive,
			// which is worse than one that charges.
			if (m.ai_sched == SCHED_TAKE_COVER)
				ai_dbg_cover_arrived = ai_dbg_cover_arrived + 1;
			AI_TaskComplete(m);
		}
		else if (inscript && (r == AIMOVE_BLOCKED || r == AIMOVE_NOPATH)
		      && m.ai_scriptretry < AI_SCRIPT_RETRIES)
		{
			// One blocked tick is not proof the mark is unreachable.  The first path
			// request is fired and NOT waited on (TASK_GET_PATH_SCRIPT completes
			// instantly by design), so an actor can set off before the nav queue has
			// answered and wedge itself on a corner it would have routed around.
			//
			// Clear the route, drop the per-monster repath floor, and ask again from
			// where it actually is - which is a different question from the one asked
			// at the start of the walk, and often has a different answer.
			m.ai_scriptretry = m.ai_scriptretry + 1;
			AI_PathClear(m);
			m.ai_nextpath = 0;
			AI_PathRequest(m, m.ai_goalpos);
			m.ai_stuck   = 0;
			m.ai_lastorg = m.origin;
			return;
		}
		else if (inscript && (r == AIMOVE_BLOCKED || r == AIMOVE_NOPATH))
		{
			// A SCRIPTED walk that cannot finish is finished anyway.
			//
			// This is the single most important safety rule in the whole scripted
			// layer.  Failing the task here would send the monster to SCHED_FAIL,
			// the gate above would immediately hand it the script schedule back,
			// and it would retry the impossible walk at 10 Hz forever - possessed,
			// so its own AI can never take over, and holding a target chain that
			// the rest of the map is waiting on.  That is a campaign soft-lock
			// built out of two correct-looking pieces.
			//
			// So: it stops where it got to, faces the mark's yaw, and the scene
			// plays from there.  Visibly imperfect beats permanently stuck, and the
			// counter (Script_ReportStats' "stuck") makes the imperfection
			// measurable rather than invisible.
			AI_StopMoving(m);
			ai_dbg_script_stuck = ai_dbg_script_stuck + 1;
			if (ai_cached_debug)
			{
				// Name the obstruction.  "Blocked" on its own is not actionable -
				// a door that nobody opened, another actor standing on the route and
				// a wall the nav graph cannot route around are three different bugs
				// with three different fixes, and they produce identical counters.
				vector dir = m.ai_goalpos - m.origin;
				dir_z = 0;
				if (dir != '0 0 0')
					dir = normalize(dir);
				tracebox(m.origin, m.mins, m.maxs, m.origin + dir * 40, MOVE_NORMAL, m);
				dprint(sprintf("[script] %s gave up %g units short of \"%s\" (%s) blocker=%s \"%s\"\n",
				               m.classname, vlen(m.ai_goalpos - m.origin),
				               m.ai_script.targetname,
				               (r == AIMOVE_BLOCKED) ? "blocked" : "nopath",
				               (trace_fraction < 1) ? trace_ent.classname : "world/none",
				               (trace_fraction < 1) ? trace_ent.targetname : ""));
			}
			AI_TaskComplete(m);
		}
		else if (r == AIMOVE_BLOCKED && m.ai_follow && m.ai_sched == SCHED_FOLLOW)
		{
			// A blocked FOLLOWER has simply got as close as the geometry allows.
			// That is a finished move, not a failed one: routing it into SCHED_FAIL
			// makes it re-select the follow it cannot complete, over and over.  It
			// stands where it is and tries again when the leader next moves.
			AI_StopMoving(m);
			AI_TaskComplete(m);
		}
		else if ((r == AIMOVE_BLOCKED || r == AIMOVE_NOPATH)
		      && (m.ai_sched == SCHED_GUARD || m.ai_sched == SCHED_ROAM))
		{
			// THE SAME RULE AS THE BLOCKED FOLLOWER ABOVE, and it was found the
			// same way.  A guard that cannot reach its post has got as close as the
			// geometry allows; a wanderer's destination was arbitrary to begin
			// with.  Neither is a FAILURE, and calling it one sends the monster to
			// SCHED_FAIL, which re-selects the identical unreachable goal.
			//
			// Measured on desertcircle before this branch existed: 439 guard
			// selections, 435 failures, ZERO arrivals - the 1:1 signature of a
			// schedule that cannot succeed by construction.  Its base1goal is
			// created 2200 units away and 400 units up from the squadmaker that
			// produces the grunts guarding it, across a graph that is still in ten
			// components after supplementing, so "unreachable" is the normal case
			// here rather than the exception.
			AI_StopMoving(m);
			if (m.ai_sched == SCHED_GUARD)
				m.ai_guard_retry = time + AI_GUARD_RETRY;
			AI_TaskComplete(m);
		}
		else if (r == AIMOVE_BLOCKED)
		{
			// Drop the route that failed before failing the task, or the
			// re-selected schedule finds AI_HasPath still true and marches back
			// into the same corner.  See AI_PathBlocked.
			AI_PathBlocked(m);
			m.ai_cond = m.ai_cond | COND_BLOCKED;
			AI_TaskFail(m);
		}
		else if (r == AIMOVE_NOPATH)
		{
			m.ai_cond = m.ai_cond | COND_NO_PATH;
			AI_TaskFail(m);
		}
	}
	else if (op == TASK_RANGE_ATTACK1 || op == TASK_RANGE_ATTACK2
	      || op == TASK_MELEE_ATTACK1)
	{
		if (AI_SeqDone(m))
		{
			// THE COOLDOWN IS ARMED HERE, at the end of the attack SEQUENCE, and
			// that is the fix for a whole class of silent breakage.
			//
			// It used to be armed by the class event handler on a specific event
			// code - Grunt_Event on GRU_AE_BURST3, the last round of the MP5's
			// three-round burst.  That is true of hgrunt.mdl and false of every
			// other rig that shares the handler: strooper.mdl's crouching_mp5
			// raises ONLY code 4, and massn.mdl's crouching_shotgun and
			// crouching_m40a1 likewise.  Those monsters therefore never armed a
			// cooldown at all, re-selected SCHED_RANGE_ATTACK1 the instant the
			// half-second sequence ended, and stood there visibly cycling their
			// firing animation forever.
			//
			// Sequence end is rig-independent and needs no per-model knowledge.
			if (op == TASK_RANGE_ATTACK1 || op == TASK_RANGE_ATTACK2)
				AI_ArmAttackCooldown(m);
			AI_TaskComplete(m);
		}
	}
	else
	{
		// Anything that completed during AI_TaskStart should never reach here.
		AI_TaskComplete(m);
	}
};

// One decision tick's worth of schedule progress.
//
// The loop exists because tasks chain: SET_ACTIVITY completes instantly, so the
// tick that starts it must also start the task after it, or a schedule of five
// instant tasks would take half a second to get anywhere.  The guard bounds that
// chaining - a schedule made entirely of instant tasks that re-selects itself
// costs a fixed number of iterations per tick rather than hanging the server.
const float AI_CHAIN_MAX = 12;

// CSquadMonster::ScheduleChange, squadmonster.cpp:117-121: hand the attack slot
// back whenever the schedule is about to change.
//
// BEFORE SELECTION, NOT ON ASSIGNMENT, and the order is the whole thing.  The
// first version of this lived inside AI_SetSchedule - which runs AFTER
// AI_SelectSchedule has already asked for a slot - so every grant was undone by
// the assignment that followed it and the ration did nothing at all.  Half-Life
// has the same two steps in the opposite order for the same reason
// (schedule.cpp:229, ScheduleChange() then GetSchedule()).
//
// Caught by sv_ai_squadtest, and it is worth saying how, because the wrong
// version looked healthy: four grunts, two engage slots, and the run reported
// `won=64 denied=0` with every grunt holding slot 0.  Sixty-four grants and not
// one refusal is not a ration - it is a counter being incremented by something
// that is immediately thrown away.
//
// Spelled out at all three re-selection sites rather than wrapped in a helper:
// there are exactly three, they are all in this function, and a wrapper would
// make it possible to add a fourth that forgets.
void(entity m, float dt) AI_RunSchedule =
{
	if (m.ai_sched == SCHED_NONE)
	{
		Squad_VacateSlot(m);
		AI_SetSchedule(m, AI_SelectSchedule(m));
	}

	// Interrupt check, before running anything: a schedule whose preconditions
	// died this tick must not get one more task out first.
	int mask = Sched_Interrupts(m.ai_sched);
	if (mask)
		if (m.ai_cond & mask)
		{
			Squad_VacateSlot(m);
			AI_SetSchedule(m, AI_SelectSchedule(m));
		}

	float guard = 0;
	while (guard < AI_CHAIN_MAX)
	{
		guard = guard + 1;

		if (m.ai_sched == SCHED_NONE)
			break;

		if (!m.ai_taskdone)
			AI_TaskRun(m, dt);
		if (!m.ai_taskdone)
			break;				// still running; nothing more to do this tick

		m.ai_taskdone = FALSE;
		m.ai_task     = m.ai_task + 1;

		if (m.ai_task >= Sched_Len(m.ai_sched))
		{
			m.ai_cond = m.ai_cond | COND_SCHEDULE_DONE;
			Squad_VacateSlot(m);
			AI_SetSchedule(m, AI_SelectSchedule(m));
		}
		else
			AI_TaskStart(m);
	}

	if (guard >= AI_CHAIN_MAX && ai_cached_debug)
		dprint(sprintf("[ai] %s: task chain hit the guard in \"%s\"\n",
		               m.classname, Sched_Name(m.ai_sched)));
};

// ---------------------------------------------------------------------------
// the think
// ---------------------------------------------------------------------------
void() AI_Think =
{
	entity m = self;

	// Dormancy: idle with nobody in range costs one distance check per player
	// every half second and nothing else - no traces, no schedule, no pathing.
	// This is the whole reason a map full of sleeping monsters is free.
	float awake = TRUE;
	if (m.ai_state == MS_IDLE || m.ai_state == MS_NONE)
	{
		awake = AI_AnyPlayerNear(m);

		// ...EXCEPT a monster that has somewhere it was told to be and has not got
		// there yet.  A guard post is an explicit instruction from the map, and
		// desertcircle's guarded objectives sit hundreds of units from where its
		// squadmakers drop the grunts - so gating the walk on "is a player already
		// watching" means the grunts are never in position when one arrives, which
		// is the whole behaviour the key exists to produce.
		//
		// Bounded three ways, which is what makes it affordable: it ends the moment
		// the monster reaches its post (AI_WantsToGuard goes FALSE inside
		// AI_GUARD_RADIUS), only monsters carrying the key pay anything at all (the
		// empty-string test is the first line of AI_WantsToGuard), and the
		// targetname lookup behind it is throttled to AI_GUARD_RERESOLVE.
		//
		// Roaming deliberately does NOT get this exemption.  Wandering is ambient,
		// nobody can observe it happening with no player in range, and keeping every
		// roamer on a big map awake at 10 Hz plus a path request per leg is exactly
		// the cost the dormancy gate exists to avoid.
		if (!awake && AI_WantsToGuard(m))
			awake = TRUE;
	}
	else if (m.ai_state == MS_SCRIPT && m.ai_scriptstate == SCRIPTST_WAIT && !m.ai_scriptgo)
	{
		// A monster holding a scripted pose is doing LESS than an idle one: it has
		// no schedule to advance and nothing to decide until the script is fired.
		// Without this, MS_SCRIPT would be the one state that never sleeps, and a
		// Sven map that poses two hundred NPCs as set dressing would pay 10 Hz for
		// every one of them forever.
		//
		// Safe because the pose is started at POSSESSION time, not by the task, and
		// AI_AnimPump below runs even while dormant - so a sleeping actor is still
		// visibly in its pose and its animation still emits events.  The wake is
		// explicit: Script_Play sets .ai_scriptgo, which this test reads.
		awake = AI_AnyPlayerNear(m);
	}

	m.nextthink = time + (awake ? AI_TICK : AI_TICK_IDLE);

	float dt = time - m.ai_lasttick;
	// sv_gameplayfix_multiplethinks defaults to 1, so this think can fire
	// several times in a single frame.  Everything below is rate-based, and
	// running it twice on the same frame would double the tick's movement.
	if (dt < AI_TICK * 0.5)
		return;
	// ...and after a server hitch, dt can be large enough to teleport the
	// monster across a wall in one walkmove.  Clamp it.
	if (dt > 0.5)
		dt = 0.5;
	m.ai_lasttick = time;
	ai_dbg_thinks = ai_dbg_thinks + 1;

	// The animation pump runs even while dormant and even while dead: a death
	// sequence still has events on it, and a dormant monster still has an idle
	// loop whose footsteps should not silently stop.
	//
	// It is called TWICE per tick, on purpose.  Before the schedule, so events
	// from the sequence that has been playing since last tick land first and the
	// schedule sees their effects.  After it, so a sequence the schedule has just
	// started gets its t=0 events on the SAME tick - and every headcrab jump
	// variant carries its launch event at exactly t=0.000, so without the second
	// call every leap would fire a decision tick (100 ms) late.
	//
	// Calling it twice is safe because ai_evtcursor is a monotonic high-water
	// mark: the second call on an unchanged sequence finds cursor == now and
	// emits nothing.  That is the same property that makes it safe under
	// sv_gameplayfix_multiplethinks.
	AI_AnimPump(m);

	if (m.ai_state == MS_DEAD)
	{
		// Corpse.  Let the death schedule finish, then stop thinking entirely -
		// a map that leaves fifty bodies lying around should not pay for them.
		if (m.ai_sched == SCHED_NONE)
		{
			m.nextthink = 0;
			return;
		}
		AI_RunSchedule(m, dt);
		AI_AnimPump(m);
		return;
	}

	if (!awake)
		return;

	// SQUAD RECRUITMENT, once per monster, on its first waking tick.
	//
	// NOT at spawn, and the reason is structural rather than a preference: a
	// monster built while the .bsp is still being parsed cannot see squadmates
	// that have not been spawned yet, so recruiting from Monster_Build would give
	// the first entity in the file an empty squad and every later one a squad of
	// the wrong size.  Half-Life has exactly this shape - SquadRecruit runs from
	// StartMonster, off the first think, for the same reason.
	//
	// The flag is set BEFORE the call, so a class that cannot form a squad pays
	// one findradius in its whole life rather than one per tick forever.
	//
	// ...and only a LEADER recruits, when the squad was named by the map.  HL:
	// `if (!FStringNull(pev->netname)) { if (!(pev->spawnflags & SF_SQUADMONSTER_LEADER))
	// return; }` before SquadRecruit (squadmonster.cpp:415-435).  A monster with no
	// squad name still recruits by proximity, which is HL's unnamed case and the
	// behaviour every class here already had.  hl_c06 has 9 named grunts and exactly
	// three leaders (spawnflags 33, 35, 162); without the gate all nine tried to lead.
	if (!m.ai_squad_tried)
	{
		m.ai_squad_tried = TRUE;
		// .is_squad_leader is the SQUADMAKER's spelling of the same idea, handed down
		// by Monster_Spawn (sv_monsters.qc:1239).  A child carries the field and never
		// the spawnflag, so both have to count or a squadmaker wave would stop forming
		// squads entirely - 54 of pizza_ya_san2's 56 makers set it.
		if (m.squadname == "" || !m.squadname
		    || (m.spawnflags & SF_SQUADMONSTER_LEADER) || m.is_squad_leader)
			Squad_Recruit(m, SQUAD_RECRUIT_DIST);
	}

	// Unconditional class hook, run BEFORE conditions are gathered so anything it
	// asserts is visible to selection on the same tick.
	if (m.ai_tick)
	{
		entity oldself = self;
		self = m;
		m.ai_tick();
		self = oldself;
	}

	// The talk layer, AFTER the class hook and deliberately so.  Barney's ai_tick
	// is Grunt_Aim, which points bone controller 0 at his enemy; the talk tick
	// owns that same controller when there is NO enemy.  Running talk second lets
	// it see the class's decision and stand down during a fight rather than the
	// two of them fighting over the head every tick.
	if (m.ai_talker)
		AI_TalkTick(m);

	AI_GatherConditions(m);
	AI_RunSchedule(m, dt);
	// The turn runs AFTER the schedule, not before it.  It used to sit on the
	// line above AI_RunSchedule, which meant the body spent every tick rotating
	// toward the ideal yaw computed on the PREVIOUS tick while the step was taken
	// along the new one - the facing was permanently one tick (up to ~18 degrees)
	// stale, and against a moving target it never converged.  Half-Life turns
	// inside the move instead (monsters.cpp:1847-1848), which is where
	// AI_MoveAlongPath now does it.
	//
	// This call is therefore the fallback for monsters that turn WITHOUT moving -
	// TASK_FACE_ENEMY, TASK_FACE_IDEAL, a static turret tracking - which never
	// reach AI_MoveAlongPath and would otherwise stop turning altogether.  For a
	// monster that did move, AI_ChangeYaw's own .ai_yawtime stamp makes this a
	// no-op rather than a second helping of rotation.
	AI_ChangeYaw(m, dt);
	AI_AnimPump(m);
};

// ---------------------------------------------------------------------------
// damage and death
// ---------------------------------------------------------------------------
// Installed on .on_damaged / driven from Monster_Killed.  W_ApplyDamage
// (sv_weapons.qc:1816) dispatches on_damaged with `self` bound to the victim and
// the attacker already stored in .dmg_inflictor (:1551).
// WHERE THE HIT LANDED AND WHERE IT CAME FROM, taken once per hit.  Called from
// AI_Damaged for a survivable blow and from AI_Died for a fatal one - exactly one
// of the two runs per W_ApplyDamage call, because W_ApplyDamage dispatches
// .on_damaged only while health remains and .on_killed only when it does not.
//
// READ-AND-CLEAR on the hitgroup.  .death_hitgroup is stamped by the eleven paths
// that resolve one (the hitscan paths, the hitclaim handler, the per-pellet
// shotgun paths) and by none of the other 52 callers of W_ApplyDamage, so leaving
// it latched means a monster shot once in the head and later crushed by a door
// plays the headshot death.  Half-Life has that bug - m_LastHitGroup is written
// only in TraceAttack and never cleared - and it is not worth porting: clearing
// makes an unstamped path read HITGROUP_GENERIC, which is precisely what GENERIC
// means to both pickers, "no region, use the direction".
//
// Safe to clear because every other reader of .death_hitgroup inside W_ApplyDamage
// is gated on target.classname == "player" (the armour test, the killfeed, the
// flinch multicast, the gib burst); nothing reads a MONSTER's after this point.
void(entity m) AI_ConsumeHit =
{
	m.ai_lasthitgroup = m.death_hitgroup;
	m.death_hitgroup  = HITGROUP_GENERIC;

	// g_vecAttackDir, combat.cpp:864-872.  Centre to centre, with the inflictor
	// pretended 10 units lower than it is - Valve's comment says why, "so the
	// body will tend to fly upward a bit", and it is kept because the same vector
	// feeds gib launch velocity there and may here later.
	m.ai_attackdir = '0 0 0';
	entity inf = m.dmg_inflictor;
	if (inf && inf != world)
	{
		vector d = (inf.origin + (inf.mins + inf.maxs) * 0.5 - '0 0 10')
		         - (m.origin   + (m.mins   + m.maxs)   * 0.5);
		if (d != '0 0 0')
			m.ai_attackdir = normalize(d);
	}
};

// Called from W_ApplyDamage with the hit still unapplied, which is the whole
// point - see the .ai_damagefilter note in sv_ai_defs.qc.  Kept as a wrapper
// rather than calling the field directly at the damage site so the null case and
// the non-monster case live in the AI layer, where they belong, instead of in the
// weapon core.
float(entity m, float damage, float dmgbits) AI_DamageFilter =
{
	if (!m.ai_damagefilter)
		return damage;
	return m.ai_damagefilter(m, damage, dmgbits);
};

void() AI_Damaged =
{
	entity m = self;

	AI_ConsumeHit(m);

	// W_ApplyDamage does not pass the amount, so size the hit from the health
	// delta.  ai_lasthealth is re-seated here and at spawn, which makes this
	// correct for every damage path that funnels through W_ApplyDamage.
	float dmg = m.ai_lasthealth - m.health;
	m.ai_lasthealth = m.health;
	if (dmg < 0)
		dmg = 0;			// healed, or a fresh spawn; not a hit

	if (dmg >= AI_HEAVY_DMG)
		m.ai_cond = m.ai_cond | COND_HEAVY_DAMAGE;
	else if (dmg > 0)
		m.ai_cond = m.ai_cond | COND_LIGHT_DAMAGE;

	m.ai_cond = m.ai_cond | COND_PROVOKED;

	// COND_FRIEND_DAMAGED, which until now had exactly one reference tree-wide:
	// its own declaration.  A squadmate being shot is how the rest of a squad
	// learns there is a fight before any of them has seen anybody - and it is
	// deliberately NOT a callout of the attacker: the condition says "something
	// is happening to us", the squad still has to find you.
	if (dmg > 0 && Squad_In(m))
	{
		Squad_AddConditions(m, COND_FRIEND_DAMAGED);
		ai_dbg_squad_frienddmg = ai_dbg_squad_frienddmg + 1;
	}

	// Being shot ends an interruptible scene.  Half-Life's SF_SCRIPT_NOINTERRUPT
	// (32) is the mapper saying "play this through whatever happens", and it is on
	// 355 of the corpus's scripts - so the common case is a scene that does NOT
	// break, and this only fires for the ones that opted in.  The chain is fired on
	// the way out for the same reason it is on death.
	if (m.ai_script && dmg > 0)
		if (Script_CanInterrupt(m))
		{
			ai_dbg_script_broke = ai_dbg_script_broke + 1;
			Script_Release(m, TRUE);
		}

	// Pain sound, rate limited HERE rather than in the class: every class wants
	// the same limit, and sustained automatic fire lands hits far faster than a
	// voice line can play.  Without it a zombie under an MP5 machine-guns its own
	// grunt.
	if (dmg > 0 && time >= m.ai_nextpain && (m.ai_painsound || m.ai_snd_pain != ""))
	{
		m.ai_nextpain = time + 1;
		if (m.ai_painsound)
		{
			entity oldpain = self;
			self = m;
			m.ai_painsound();
			self = oldpain;
		}
		else
			AI_SndPlay(m, CHAN_VOICE, m.ai_snd_pain);
	}

	// Wake a dormant monster immediately rather than waiting out its half-second
	// idle tick - being shot is exactly the case where a 500 ms delay shows.
	if (m.ai_state == MS_IDLE || m.ai_state == MS_NONE)
		m.ai_state = MS_ALERT;
	m.nextthink = time + 0.05;

	entity att = m.dmg_inflictor;

	// A PLAYER shot an ally.  This is the whole "when I shoot a barney they
	// should start attacking me" behaviour, and it runs BEFORE the enemy adoption
	// below because it is what decides whether that adoption is allowed to happen:
	// AI_ValidEnemy consults the relationship, and the relationship only turns
	// hostile once AI_Provoke has set the bit.
	// is_player_ally, not ai_talker.  HL hangs the provoke bit on CTalkMonster, so
	// only its talkers can be angered - but monster_human_grunt_ally (406
	// placements) is an ally that carries no sentence group here, and an armed
	// escort you cannot anger is stranger than a silent one.  AI_TalkSay already
	// returns FALSE for a class with no group, so a non-talker ally gets the whole
	// escalation without a voice, which is the right degradation.
	if (dmg > 0 && att.classname == "player" && m.is_player_ally)
		AI_TalkDamaged(m, att, dmg);

	if (AI_ValidEnemy(m, att))
	{
		if (!m.ai_enemy)
			m.ai_enemy = att;
		m.ai_lastseenpos = att.origin;
		// Shot from somewhere it cannot see: turn toward the shot.  HL drives
		// this off its sound/dislocation system, which does not exist here; the
		// attacker's position is the honest stand-in and produces the same
		// visible behaviour.
		if (!(m.ai_cond & COND_SEE_ENEMY))
			m.ai_cond = m.ai_cond | COND_HEAR_SOUND;
		m.ai_yaw_ideal = vectoyaw(att.origin - m.origin);
	}
};

// The BODY, shared by the two ways a monster can stop being alive: shot
// (AI_Died, below) and killed by its own scripted sequence (Script_DieInPlace in
// sv_scripted.qc, which is Half-Life's CineCleanup DEAD_DYING branch).  Split out
// so the two cannot drift — a corpse that is SOLID_CORPSE on one path and
// SOLID_SLIDEBOX on the other is exactly the kind of difference nobody notices
// until a body blocks a doorway on one map and not another.  Every line and every
// reason below is the one AI_Died already carried; nothing here is new.
void(entity m) AI_BecomeCorpse =
{
	// SOLID_CORPSE, and the reasoning has now been round-tripped twice.
	//
	// Round 1 said SOLID_NOT, quoting Half-Life.  Wrong: schedule.cpp:451-468 has
	// the pev->solid = SOLID_NOT line COMMENTED OUT and squashes the bbox to a
	// one-unit pancake instead.  Round 2 therefore kept the body SOLID_SLIDEBOX
	// with the HL pancake - faithful, and it broke three things in play:
	//
	//   * a corpse kept POSITIVE health (below), so AI_ValidEnemy accepted it and
	//     guards emptied magazines into bodies
	//   * the 1-unit pancake is a ledge the CLIENT cannot predict - CSQC cannot
	//     see monsters at all (cl_monstertrace.qc:11-13), so the server stepped the
	//     player up and the client did not, and the view sank on every body
	//   * bodies still obstructed doorways
	//
	// FTE has the thing Half-Life did not: SOLID_CORPSE (pr_common.h:709), live for
	// QW progs (pr_cmds.c:1289).  A SOLID_SLIDEBOX passedict's default trace mask
	// carries no CORPSE bit (world.c:2841-2856, "slidebox passes through corpses"),
	// so players AND monsters walk straight through - and sv_ents.c:3573 gives it
	// solidsize 0, so the client's physent list does not contain it either.  Server
	// and client finally agree that the body is not there.
	//
	// It stays HITTABLE because a trace can opt in with CONTENTBIT_CORPSE, which
	// W_WeaponTraceLine now does for every melee swing and every bullet.
	//
	// The pancake is kept: it is HL's own shape for a body on the floor, and with
	// SOLID_CORPSE it no longer costs anything.
	//   UTIL_SetSize(pev, mins, Vector(maxs.x, maxs.y, mins.z + 1))
	m.deadflag = DEAD_DEAD;
	m.solid    = SOLID_CORPSE;
	setsize(m, m.mins, [m.maxs_x, m.maxs_y, m.mins_z + 1]);

	// combat.cpp:518-532 BecomeDead(), all three lines and all three reasons:
	//   takedamage stays YES        so the body can be shot
	//   health = max_health / 2     the corpse's own pool, chipped by gib-type
	//                               damage until one hit lands over what is left
	//   max_health = 5              repurposed as a blood-DECAL budget, so a
	//                               body cannot paint the whole room
	// Seated at spawn by Monster_Build; this is a backstop for anything that
	// reached death without going through it.
	if (m.max_health <= 0)
		m.max_health = 40;
	m.takedamage = DAMAGE_YES;
	m.health     = m.max_health * 0.5;
	if (m.health < 1)
		m.health = 1;
	m.max_health = 5;
	setorigin(m, m.origin);		// relink with the new size
};

// Called from Monster_Killed for AI classes, with self already the corpse.
void(entity m) AI_Died =
{
	// The KILLING blow's hitgroup and direction, which AI_Damaged never sees:
	// W_ApplyDamage runs .on_damaged only while the target still has health, so
	// without this the death animation would be chosen from whatever the previous
	// non-fatal hit happened to be - and for anything that dies in one shot, from
	// nothing at all.
	AI_ConsumeHit(m);

	// Let go of any scripted_sequence FIRST, before the state changes underneath
	// it.  The `TRUE` fires the script's target chain, and that is a deliberate
	// divergence from Half-Life, which calls CineCleanup and fires nothing: a
	// campaign map whose actor is shot mid-scene would otherwise wait on a chain
	// that can never come.  Half-Life can afford that because its scenes happen
	// where the player cannot start a fight; a co-op mod cannot.
	if (m.ai_script)
		Script_Release(m, TRUE);

	m.ai_state = MS_DEAD;
	m.ai_enemy = world;
	m.ai_cond  = COND_NONE;

	// Kill any looping sample the class started at spawn.  Here rather than in
	// TASK_DIE because TASK_DIE runs at the END of a death animation, and the two
	// classes that own a loop today (apache, osprey) have no death animation at all
	// - their whole model is one rotor cycle.
	if (m.ai_snd_loop != "")
	{
		AI_SoundEx(m, m.ai_snd_loopchan, m.ai_snd_loop, 0, ATTN_NORM, 100, SOUNDFLAG_FOLLOW);
		m.ai_snd_loop = "";
	}

	AI_StopMoving(m);
	AI_PathClear(m);

	AI_BecomeCorpse(m);

	// What it was carrying.  HL does this in CBarney::Killed (barney.cpp:612-628)
	// and CHGrunt (hgrunt.cpp:287-303 on gib, :849-872 on the DROP_GUN event), and
	// having it means a firefight leaves ammunition behind instead of only bodies.
	//
	// Gated on sv_ai_dropweapons because it is a real change to the economy of a
	// map: a corridor of grunts is now also a corridor of MP5s.
	//
	// KNOWN COSMETIC GAP, stated rather than hidden: Half-Life also sets the
	// model's bodygroup to GUN_NONE / BARNEY_BODY_GUNGONE at the same moment, so
	// the weapon vanishes from the corpse's hands as the pickup appears.  Server
	// entities cannot select a bodygroup on this engine build yet, so for now the
	// body keeps a painted-on gun as well as dropping a real one.  That is the
	// engine work this round's plan puts immediately after.
	if (m.ai_dropweapon && cvar("sv_ai_dropweapons"))
		m.ai_dropweapon(m);

	// A dead flyer falls.  FL_FLY is the only thing holding it up - clearing it
	// puts the step physics back on the gravity path (freefall = !(ONGROUND|FLY),
	// sv_phys.c:1537) and the corpse drops and lands with no further help.  A
	// STATIC monster is left exactly where it is: a turret stays bolted to its
	// wall after it dies.
	if (m.ai_movemode == AIMODE_FLY || m.ai_movemode == AIMODE_SWIM)
		m.flags = m.flags & ~FL_FLY;

	// Straight into the death schedule, bypassing selection - death is not a
	// decision.
	AI_SetSchedule(m, SCHED_DIE);
	m.think     = AI_Think;
	m.nextthink = time + 0.05;
};

// ---------------------------------------------------------------------------
// class registry
// ---------------------------------------------------------------------------
// The single classname test in the AI layer.  Everything else dispatches through
// the .ai_* virtuals, so switching a class on is one line here plus its class
// file - and a broken class cannot take the rest of the corpus with it.
float(string cls) AI_ClassHasAI =
{
	if (cls == "monster_headcrab")		return TRUE;
	if (cls == "monster_zombie")		return TRUE;
	if (cls == "monster_zombie_barney")	return TRUE;
	if (cls == "monster_zombie_soldier")	return TRUE;
	if (cls == "monster_cockroach")		return TRUE;
	if (cls == "monster_alien_slave")	return TRUE;
	if (cls == "monster_houndeye")		return TRUE;
	if (cls == "monster_bigmomma")	return TRUE;
	if (cls == "monster_apache")	return TRUE;
	if (cls == "monster_th_boss")	return TRUE;
	if (cls == "monster_osprey")	return TRUE;
	if (cls == "monster_gargantua")	return TRUE;
	if (cls == "monster_babygarg")	return TRUE;
	if (cls == "monster_stukabat")	return TRUE;
	if (cls == "monster_kingpin")	return TRUE;
	if (cls == "monster_scientist")	return TRUE;
	if (cls == "monster_barnacle")	return TRUE;
	if (cls == "monster_leech")	return TRUE;
	if (cls == "monster_ichthyosaur")	return TRUE;
	if (cls == "monster_alien_controller")	return TRUE;
	if (cls == "monster_sentry")		return TRUE;
	if (cls == "monster_miniturret")		return TRUE;
	if (cls == "monster_turret")		return TRUE;
	if (cls == "monster_alien_grunt")		return TRUE;
	if (cls == "monster_bullchicken")		return TRUE;
	if (cls == "monster_pitdrone")		return TRUE;
	if (cls == "monster_gonome")		return TRUE;
	if (cls == "monster_alien_voltigore")		return TRUE;
	if (cls == "monster_alien_babyvoltigore")	return TRUE;
	if (cls == "monster_human_grunt")		return TRUE;
	if (cls == "monster_th_cyberfranklin")		return TRUE;
	if (cls == "monster_human_grunt_ally")		return TRUE;
	if (cls == "monster_male_assassin")		return TRUE;
	if (cls == "monster_hwgrunt")		return TRUE;
	if (cls == "monster_robogrunt")		return TRUE;
	if (cls == "monster_human_assassin")		return TRUE;
	if (cls == "monster_shocktrooper")		return TRUE;
	if (cls == "monster_bodyguard")		return TRUE;
	if (cls == "monster_th_grunt_repel")		return TRUE;
	if (cls == "monster_barney")		return TRUE;
	if (cls == "monster_otis")		return TRUE;
	if (cls == "monster_human_medic_ally")		return TRUE;
	if (cls == "monster_human_torch_ally")		return TRUE;
	// NOT scenery.  See mon_generic.qc: CGenericMonster calls MonsterInit() like any
	// other NPC, and without AI here every scripted_sequence that asks it to walk
	// teleports it to the mark instead.
	if (cls == "monster_generic")		return TRUE;
	return FALSE;
};

void(entity m) AI_ClassInit =
{
	if (m.classname == "monster_headcrab")		Headcrab_ClassInit(m);
	if (m.classname == "monster_zombie")		Zombie_ClassInit(m);
	if (m.classname == "monster_zombie_barney")	ZombieBarney_ClassInit(m);
	if (m.classname == "monster_zombie_soldier")	ZombieSoldier_ClassInit(m);
	if (m.classname == "monster_cockroach")		Cockroach_ClassInit(m);
	if (m.classname == "monster_alien_slave")	Islave_ClassInit(m);
	if (m.classname == "monster_houndeye")		Houndeye_ClassInit(m);
	if (m.classname == "monster_bigmomma")	BigMomma_ClassInit(m);
	if (m.classname == "monster_apache")	Apache_ClassInit(m);
	// They Hunger boss: CApache with a different model.  Same init, so the
	// rotor loop, the strafing hunt and the death spiral all come for free.
	if (m.classname == "monster_th_boss")	Apache_ClassInit(m);
	if (m.classname == "monster_osprey")	Osprey_ClassInit(m);
	if (m.classname == "monster_gargantua")	Gargantua_ClassInit(m);
	if (m.classname == "monster_babygarg")	Babygarg_ClassInit(m);
	if (m.classname == "monster_stukabat")	Stukabat_ClassInit(m);
	if (m.classname == "monster_kingpin")	Kingpin_ClassInit(m);
	if (m.classname == "monster_scientist")	Scientist_ClassInit(m);
	if (m.classname == "monster_generic")	Generic_ClassInit(m);
	if (m.classname == "monster_barnacle")	Barnacle_ClassInit(m);
	if (m.classname == "monster_leech")	Leech_ClassInit(m);
	if (m.classname == "monster_ichthyosaur")	Ichthyosaur_ClassInit(m);
	if (m.classname == "monster_alien_controller")	Controller_ClassInit(m);
	if (m.classname == "monster_sentry")	Sentry_ClassInit(m);
	if (m.classname == "monster_miniturret")	Miniturret_ClassInit(m);
	if (m.classname == "monster_turret")	Turret_ClassInit(m);
	if (m.classname == "monster_alien_grunt")	Agrunt_ClassInit(m);
	if (m.classname == "monster_bullchicken")	Bullsquid_ClassInit(m);
	if (m.classname == "monster_pitdrone")	Pitdrone_ClassInit(m);
	if (m.classname == "monster_gonome")	Gonome_ClassInit(m);
	if (m.classname == "monster_alien_voltigore")	Voltigore_ClassInit(m);
	if (m.classname == "monster_alien_babyvoltigore")	BabyVoltigore_ClassInit(m);
	if (m.classname == "monster_human_grunt")	HGrunt_ClassInit(m);
	if (m.classname == "monster_human_grunt_ally")	HGruntAlly_ClassInit(m);
	if (m.classname == "monster_male_assassin")	Assassin_ClassInit(m);
	if (m.classname == "monster_hwgrunt")	HWGrunt_ClassInit(m);
	if (m.classname == "monster_robogrunt")	Robogrunt_ClassInit(m);
	if (m.classname == "monster_human_assassin")	Assassin_ClassInit(m);
	if (m.classname == "monster_shocktrooper")	Shocktrooper_ClassInit(m);
	if (m.classname == "monster_bodyguard")	Barney_ClassInit(m);
	if (m.classname == "monster_th_grunt_repel")	HGrunt_ClassInit(m);
	// ...and cyberfranklin is CHGrunt, down to the animation-event codes.
	if (m.classname == "monster_th_cyberfranklin")	HGrunt_ClassInit(m);
	if (m.classname == "monster_barney")	Barney_ClassInit(m);
	if (m.classname == "monster_otis")	Barney_ClassInit(m);
	if (m.classname == "monster_human_medic_ally")	Barney_ClassInit(m);
	if (m.classname == "monster_human_torch_ally")	HGruntAlly_ClassInit(m);

	// LAST, and it overrides what the class init just installed.  Animation event
	// codes belong to the MODEL, and a classname can resolve to either of two rigs
	// depending on what is mounted - see Grunt_RigOverride (mon_grunt.qc) for the
	// male assassin, who spent 419 placements holding the wrong event table.
	Grunt_RigOverride(m);

	// The cadence and reach consequences of the loadout, for the same reason and
	// in the same window - after the rig table can rewrite .weapons, before the
	// body is composed.  ABOVE Grunt_BodyInit deliberately: that function zeroes
	// ai_range_range for HGRUNT_NOWEAPONS, and an unarmed monster must stay
	// unarmed even if the map also set a gun bit.
	Grunt_LoadoutInit(m);

	// ...and the bodygroup, AFTER the rig table, because the loadout it reads is
	// one of the things the rig table can change (the torch and the medic have
	// their MP5 bit cleared there).
	Grunt_BodyInit(m);

	// LAST OF ALL: the map's own reach override, Sven's `attackrange`.  It has to
	// be last because it is the MAPPER's decision and everything above is ours -
	// a class default the map explicitly disagreed with is not a default any more.
	//
	// IT TUNES A RANGED ATTACK, IT DOES NOT GRANT ONE, which is why the guard
	// tests the existing value rather than just assigning.  Grunt_BodyInit two
	// lines up zeroes ai_range_range for HGRUNT_NOWEAPONS, and a squadmaker that
	// sets both an attackrange and the no-weapons bit would otherwise hand a gun
	// range back to a grunt with no gun - which reads in-game as a monster that
	// shoots invisible bullets.  The same guard covers the barnacle and the
	// gargantua, whose ranges are deliberately zero so the generic ladder can
	// never offer them a ranged schedule.
	if (m.attackrange > 0 && m.ai_range_range > 0)
	{
		if (ai_cached_debug && m.attackrange != m.ai_range_range)
			dprint(sprintf("[ai] %s attackrange %g overrides class range %g\n",
			               m.classname, m.attackrange, m.ai_range_range));
		m.ai_range_range = m.attackrange;
	}
};

// StartMonster's half of HL's MonsterInit split (monsters.cpp:2085-2089), run
// ONCE for the whole map after ED_LoadFromFile has finished.
//
// Armed by worldspawn at time+0.001 so it lands before any other think, trigger
// or mover has run: a func_plat that snaps to its bottom position, or a
// func_train that jumps to its first path_corner, must not be allowed to move
// out from under a monster standing on it before the drop happens.
//
// Walks the monster chain the mod already maintains (monster_chain_add) rather
// than searching, and clears ai_lump_parsing on the way out so every runtime
// spawn from here on places synchronously as before.
void() AI_DeferredPlacePass =
{
	entity m = monster_chain_head;

	ai_lump_parsing = FALSE;

	while (m)
	{
		entity nxt = m.monster_chain_next;
		if (m.ai_needplace)
		{
			m.ai_needplace = FALSE;
			// A body that has already been torn down or killed in the same
			// instant is not worth dropping.
			if (m.solid != SOLID_NOT && m.health > 0)
			{
				vector pre = m.origin;
				float  ok  = AI_PlaceOnFloor(m);
				if (!ok && cvar("sv_debug_monsters"))
					dprint(sprintf("[ai] map-placed %s at %v could not be "
					               "placed - kept live\n", m.classname, pre));
				else if (cvar("sv_debug_monsters") && m.origin != pre)
					dprint(sprintf("[ai-place] %s \"%s\" %v -> %v (dz %g)\n",
					               m.classname, m.targetname, pre, m.origin,
					               m.origin_z - pre_z));
			}
		}
		m = nxt;
	}

	remove(self);
};

// Turn a built monster body into a thinking one.  Called from Monster_Build,
// which has already set the model, hull, health and name.
//
// Returns FALSE when the body cannot be made to work - specifically when it
// cannot be stood on a floor.  The caller keeps it as an inert prop in that
// case rather than removing it, because its targetname may still be the anchor
// of a trigger chain.
float(entity m) AI_Spawn =
{
	if (!ai_cached_enable)
		return FALSE;

	m.movetype   = MOVETYPE_STEP;
	m.solid      = SOLID_SLIDEBOX;
	m.flags      = m.flags | FL_MONSTER;
	m.takedamage = DAMAGE_YES;

	// Explicitly, because QC recycles edicts: a spawn() that lands on a slot a
	// corpse used to occupy inherits its fields, and DEAD_DEAD is now the single
	// test that decides whether anything in the world will attack this body.  A
	// monster born already-dead would be permanently invisible to every enemy.
	m.deadflag   = DEAD_NO;

	m.ai_state      = MS_IDLE;
	m.ai_cond       = COND_NONE;
	m.ai_sched      = SCHED_NONE;
	m.ai_enemy      = world;
	m.ai_seq        = -1;
	m.ai_activity   = ACT_RESET;
	m.ai_lasthealth = m.health;
	m.ai_yaw_ideal  = m.angles_y;
	m.ai_yaw_speed  = 180;
	m.ai_speed_walk = 60;
	m.ai_speed_run  = 120;
	m.ai_movemode   = AIMODE_GROUND;
	m.ai_flyheight  = 0;
	// CBaseMonster::CBaseMonster's own default: 0.5, i.e. 60 degrees off centre
	// and 120 across.  A class that should see wider, narrower or all round says
	// so in its init; leaving it here means a class nobody has thought about gets
	// a sensible head rather than eyes in the back of it.
	m.ai_fov        = 0.5;
	// Recycled-edict hygiene, same reason as ai_avoidside below: a stale danger
	// position would make a fresh monster flee a grenade that went off before it
	// existed.
	m.ai_dangerpos    = '0 0 0';
	m.ai_danger_until = 0;
	// QC recycles edicts, so a latched avoidance side or a half-counted turn
	// oscillation from whatever used this slot before would carry into the new
	// monster's first steps.
	m.ai_avoidside  = 0;
	m.ai_turnticks  = 0;
	// Seeded, because AI_ChangeYaw derives its elapsed time from this: left at a
	// recycled edict's stale value it would compute a wild interval on the first
	// turn (clamped, so at worst one 0.25 s helping - but a monster that snaps a
	// quarter-second of rotation on its first tick is not what anything wants).
	m.ai_yawtime    = time;
	m.on_damaged    = AI_Damaged;

	AI_ClassInit(m);

	// THE ALLY FLIP, and it has to be here: after the class init, because the flip
	// is defined against the class default, and that default does not exist until
	// the init has stated it.
	//
	// Sven writes this key three ways and they all mean the same thing - a plain
	// monster's is_player_ally reads "No (Default) / Yes", a talkmonster's reads
	// "Yes (Default) / No", and squadmaker's respawn_as_playerally reads
	// "Default (0) / Opposite (1)".  One rule covers all three.
	//
	// pizza_ya_san1 is what this is for.  Its four seated customers are a
	// monster_human_assassin, a monster_zombie, a monster_babygarg and a
	// monster_male_assassin - four hostile classes wearing custom models - and the
	// shop's four turrets and its robogrunt are the same trick.  Without the flip
	// the pizza shop opens fire on its own customers and on you.
	if (m.ai_ally_flip)
	{
		if (m.is_player_ally)
		{
			// An ally class asked to be the opposite: a grunt ally that fights for
			// the other side.  CLASS_HUMAN_MILITARY is the hostile twin of every
			// class that defaults to ally, all of which are human.
			m.is_player_ally = FALSE;
			m.ai_class       = CLASS_HUMAN_MILITARY;
		}
		else
		{
			m.is_player_ally = TRUE;
			m.ai_class       = CLASS_PLAYER_ALLY;
		}
	}

	// PRISONER: "never fights, never targeted".  The bit has been declared in
	// sv_ai_defs.qc since B2 and read nowhere, which is why nine of this map's
	// spawners and both of its map-placed friendlies were fighting anyway - it is
	// Sven's ordinary way of saying "this NPC is set dressing with a pulse".
	// Enforced in AI_ValidEnemy in both directions; latched here so the test is one
	// field read rather than a spawnflag decode per candidate per tick.
	if (m.spawnflags & SF_MON_PRISONER)
		m.ai_prisoner = TRUE;

	// Every ally becomes +use-able, in ONE place rather than in each of the six
	// ally class inits.  is_player_ally is the flag those inits already set, so
	// this is the whole opt-in: a class that declares itself an ally gets the
	// follow interaction for free, and a class that does not can never
	// accidentally acquire it.
	//
	// The trigger relay installed by Monster_Build is preserved and still runs for
	// non-player activators - a multi_manager naming a barney must keep passing
	// through it, and swapping .use outright is exactly how that would break.
	//
	// ...except a PRISONER.  Sven's flag means "set dressing with a pulse", and on
	// pizza_ya_san1 every one of them is held by a scripted_sequence - the four
	// seated customers, the two map-placed friendlies.  Handing the player a +use
	// that pulls a seated customer out of their scene and marches them around the
	// shop is not the interaction the map is offering.
	if (m.is_player_ally && !m.ai_prisoner)
	{
		m.monster_player_usable = TRUE;
		m.use = AI_AllyUse;
	}

	// `sv_ai_forcemode <AIMODE_*>`: override whatever the class chose.  This exists
	// because FLY, SWIM and STATIC otherwise ship with no class using them and
	// therefore no way to exercise them at all - make a headcrab fly and the
	// volume path gets driven by a monster whose behaviour is already known good.
	// Default 0 (= AIMODE_GROUND, the real default), so it is inert unless set.
	if (ai_cached_forcemode > AIMODE_GROUND && ai_cached_forcemode <= AIMODE_STATIC)
	{
		m.ai_movemode = ai_cached_forcemode;
		if (m.ai_movemode == AIMODE_FLY && m.ai_flyheight <= 0)
			m.ai_flyheight = 48;
	}

	// Locomotion mode is a per-class decision, so the physics flags that depend on
	// it have to land AFTER the class init.  GROUND is the first branch and touches
	// nothing: it keeps exactly the movetype, solid and flags set above, which is
	// what every shipped monster was verified against.
	//
	// ...except for WHEN the ground drop happens — see the block below.
	float placed;
	if (m.ai_movemode == AIMODE_GROUND)
	{
		// HALF-LIFE DOES NOT DROP A MONSTER INSIDE ITS OWN SPAWN FUNCTION, and
		// that is not an implementation detail — it is the only reason a monster
		// can stand on a brush entity at all.  CBaseMonster::MonsterInit merely
		// ARMS the drop (monsters.cpp:2047-2048, `nextthink = time + 0.1`) and
		// StartMonster does the raise-one-unit + DROP_TO_FLOOR later
		// (monsters.cpp:2085-2089) — by which point ED_LoadFromFile has spawned
		// and linked EVERY entity in the lump.
		//
		// Doing it here instead means the drop only sees the entities that happen
		// to come BEFORE this one in the .bsp.  th_ep1_03's raft is func_wall
		// *76, entity #266; the monster_otis standing on it is entity #26 — so
		// the raft does not exist yet, droptofloor finds only the world, and he
		// lands on the lake bed 172 units below, underwater.  th_ep1_04 is the
		// same set piece a map later (raft #316, otis #97, barney #98) and both
		// actors sink through it, which is why the "Zombie Cop" beside him falls
		// too: this was never otis-specific.
		//
		// Deferred to a SINGLE one-shot pass at time+0.001 rather than to each
		// monster's own first think.  Two reasons, and the second is the
		// important one:
		//   - it needs no per-monster gate, and any such gate would be wrong —
		//     `sq_maker == world` also catches every runtime spawn that has no
		//     maker, and HL does not gate at all;
		//   - a per-monster 0.1 s deferral lets MOVERS move first.  A func_plat
		//     that snaps to its bottom position, or a func_train that jumps to
		//     its first path_corner, would relocate out from under the monster
		//     before it was placed.  At time+0.001 nothing else has run yet.
		//
		// The mod already reasons exactly this way one function over: squad
		// recruitment is deferred to the first think because "a monster built
		// while the .bsp is still being parsed cannot see squadmates that have
		// not been spawned yet".  Same ordering problem, same shape of answer.
		if (ai_lump_parsing)
		{
			m.ai_needplace = TRUE;
			// Judged by AI_DeferredPlacePass instead.  Reporting TRUE here is
			// safe rather than optimistic: the `if (!placed)` branch below does
			// nothing but dprint for a map-placed body anyway — it is kept live
			// with no teardown, because its targetname may be load-bearing for a
			// trigger chain — and a squadmaker child never reaches this arm.
			placed = TRUE;
		}
		else
			placed = AI_PlaceOnFloor(m);
	}
	else
	{
		if (m.ai_movemode == AIMODE_STATIC)
		{
			// Nothing ever moves it, so no physics is wanted at all.  Thinks still
			// run: WPhys_Physics_None calls RunThink (sv_phys.c:2275).
			m.movetype = MOVETYPE_NONE;
		}
		else
		{
			// FL_FLY on MOVETYPE_STEP, and NOT MOVETYPE_FLY - see the AIMODE_* note
			// in sv_ai_defs.qc.  FL_SWIM is never set even for AIMODE_SWIM, because
			// its no-gravity rule reads .waterlevel, which is garbage here.
			m.flags = m.flags | FL_FLY;
		}
		// Whatever droptofloor would have left behind: without gravity this flag
		// only makes walkmove and the physics disagree about what the monster is.
		m.flags = m.flags & ~FL_ONGROUND;
		placed  = AI_PlaceInVolume(m);
	}

	if (!placed)
	{
		// Sven's squadmaker spawn_mode 2, "Force spawn, never block"
		// (sven-coop.fgd:5451), carried down from the maker by Monster_Spawn.
		// The body stays exactly as the class init left it - solid, FL_MONSTER,
		// its own movetype - and is NOT marked ai_placefail, so the maker keeps
		// it and books a slot for it.
		//
		// It is deliberately still reported.  "Force spawn" means the mapper
		// accepts a monster standing in a wall rather than a wave that never
		// arrives; it does not mean the overlap stops being worth knowing about,
		// and a monster spawned inside geometry is the first thing to suspect
		// when one later behaves oddly.
		if (m.ai_forceplace)
		{
			if (ai_cached_debug || cvar("sv_debug_monsters"))
				dprint(sprintf("[ai] %s at %v could not be placed (movemode %g) - FORCED (spawn_mode 2)\n",
				               m.classname, m.origin, m.ai_movemode));
		}
		else if (m.sq_maker == world)
		{
			// A MAP-PLACED body KEEPS ITS BRAIN, because that is all Half-Life does.
			// CBaseMonster::StartMonster prints "Monster %s stuck in wall--level design
			// error" and sets EF_BRIGHTFIELD (monsters.cpp:2093) and stops there: the
			// monster still thinks, still fights, and can still be claimed by a
			// scripted_sequence.  It is never disabled.
			//
			// Stripping it here is what the user reported as "place holders with no
			// actual function", and the description was exact - hl_c06's two doorway
			// grunts and `dragguy` (the actor for the drag-into-the-hole set piece) were
			// all three turned into scenery by this branch.  Measured over the 121
			// GoldSrc maps: 114 of 2209 map-placed AI monsters land here, across 32 maps.
			//
			// The strip below is still exactly right for a SQUADMAKER CHILD - a wave
			// member that cannot fit must not book a slot - and .ai_placefail is the
			// signal the maker reads for that (sv_ai_defs.qc:618-624).  .sq_maker is the
			// child -> maker back-pointer set in Monster_Spawn (sv_monsters.qc:1222), so
			// world here means "came from the .bsp".
			if (ai_cached_debug || cvar("sv_debug_monsters"))
				dprint(sprintf("[ai] %s at %v could not be placed (movemode %g) - map-placed, kept live\n",
				               m.classname, m.origin, m.ai_movemode));
		}
		else
		{
			// Reported at sv_debug_monsters as well as sv_ai_debug.  A failed placement
			// is not an AI event a developer goes looking for - it is a monster that is
			// missing from the map, which is the report - and burying the only trace of
			// it behind a cvar that defaults to 0 is how one blocked spawn point silently
			// killed a spawner for a whole map.
			if (ai_cached_debug || cvar("sv_debug_monsters"))
				dprint(sprintf("[ai] %s at %v could not be placed (movemode %g) - left inert\n",
				               m.classname, m.origin, m.ai_movemode));
			m.movetype    = MOVETYPE_NONE;
			m.solid       = SOLID_NOT;
			m.flags       = m.flags & ~(FL_MONSTER | FL_FLY);
			m.ai_placefail = TRUE;
			return FALSE;
		}
	}

	// The looping ambience, started HERE rather than in the class init - which is
	// where it was first written and where it was wrong.  A class init runs before
	// placement, and placement can fail: the harnesses retry a spawn up to 24 times
	// and Monster_Build chains every attempt, so a loop started in the init would
	// leave a rotor beating on each of the 23 bodies that were torn down again.
	// SOUNDFLAG_FORCELOOP runs until something replaces it on this entity channel,
	// so there is no self-limiting behaviour to fall back on.
	//
	// Pitch 110 is HL's own on both of the two classes that have one - the apache
	// (apache.cpp:708) and the osprey (osprey.cpp:450).
	if (m.ai_snd_loop != "")
		AI_SoundEx(m, m.ai_snd_loopchan, m.ai_snd_loop, 1,
		      (m.ai_snd_loopatten > 0) ? m.ai_snd_loopatten : ATTN_NORM, 110,
		      SOUNDFLAG_FORCELOOP | SOUNDFLAG_FOLLOW);

	AI_SetActivity(m, ACT_IDLE);

	m.think = AI_Think;
	// Stagger the first think so a squadmaker wave does not land every child's
	// decision tick on the same frame.  Same idiom as sv_env_spark.qc:136.
	m.nextthink   = time + 0.1 + random() * 0.1;
	m.ai_lasttick = time - AI_TICK;		// so the first think is not eaten by the dt guard

	return TRUE;
};

// ---------------------------------------------------------------------------
// spawn test  —  `sv_ai_spawntest <n>`
// ---------------------------------------------------------------------------
// Drops n headcrabs in a ring around the first player and zeroes itself.  This
// is the only way to get monsters in front of a player on demand: the corpus
// puts headcrabs where its maps put them, and a squadmaker spawns whatever its
// own monstertype says.  Shipped behind a cvar for the same reason the nav
// self-tests are - being able to re-measure on any map without a rebuild.
//
// Monster_Build is reachable directly: sv_monsters.qc compiles before this file.
void(vector org, string cls) AI_SpawnTestOne =
{
	entity oldself = self;
	entity m = spawn();
	m.classname = cls;			// no model key -> Monster_DefaultModel

	// `sv_ai_spawnweapons <bits>`: the map's `weapons` key, for the same reason
	// sv_ai_spawnfollow exists - it is the only way a headless drive can reach a
	// loadout, and two of the grunt's bits (64 Rocket Launcher, 128 Sniper Rifle)
	// appear on exactly two squadmakers in the whole corpus, on a map where they
	// spawn behind a flag capture.  Set BEFORE Monster_Build, because AI_ClassInit
	// runs inside it and every reader of .weapons is downstream of that call.
	float lo = cvar("sv_ai_spawnweapons");
	if (lo > 0)
		m.weapons = lo;

	setorigin(m, org);
	self = m;
	Monster_Build(TRUE);

	// Ceiling-mounted shapes get lifted to the ceiling.  A barnacle's hull hangs
	// entirely BELOW its origin (maxs_z <= 0), so dropping one at floor level
	// leaves it tracing its tongue straight into the ground and it can never find
	// a victim - which is not a bug in the class, only in where the test put it.
	// Detected from the hull rather than the classname so it covers ceiling
	// turrets too.
	if (m.maxs_z <= 0 && m.mins_z < 0)
	{
		traceline(m.origin, m.origin + '0 0 1' * 512, MOVE_NORMAL, m);
		if (trace_fraction > 0.05)
		{
			setorigin(m, trace_endpos + '0 0 -1');
			if (ai_cached_debug)
				dprint(sprintf("[ai] spawntest: hung %s from the ceiling at %v\n",
				               cls, m.origin));
		}
	}

	self = oldself;
};

float ai_spawntest_gripe;

void() AI_SpawnTest =
{
	float n = cvar("sv_ai_spawntest");
	if (n <= 0)
		return;

	// Deliberately NOT consumed here.  Set from the command line it fires during
	// map load, before any client has joined, and a one-shot reset would eat it
	// with nothing to show for it.  Held until there is somebody to spawn around
	// instead, which is also the behaviour a player wants from the console: it
	// works even if they happen to be mid-respawn when they type it.
	// Pick a player that is actually standing in the world.  player_chain_head is
	// whoever connected most recently, and a player is in the chain from
	// PutClientInServer onward - which includes moments when they are dead,
	// spectating, or not yet moved to a spawn point.  AI_ValidEnemy is exactly
	// the right predicate: if a monster would not accept this player as a
	// target, spawning monsters around them is pointless too.
	entity p = player_chain_head;
	while (p)
	{
		if (AI_ValidEnemy(world, p))
			break;
		p = p.player_chain_next;
	}
	if (!p)
	{
		// Throttled: this runs every frame while the request is pending.  Lists
		// what IS in the chain, because "no valid player" and "a player who is
		// dead / spectating / not yet placed" look identical from the outside
		// and want completely different responses.
		if (time >= ai_spawntest_gripe)
		{
			ai_spawntest_gripe = time + 5;
			dprint("[ai] sv_ai_spawntest: waiting for a live in-world player\n");
			entity q = player_chain_head;
			while (q)
			{
				dprint(sprintf("[ai]   \"%s\" org=%v health=%g solid=%g movetype=%g\n",
				               q.netname, q.origin, q.health, q.solid, q.movetype));
				q = q.player_chain_next;
			}
		}
		return;
	}

	// ...and that they are somewhere REAL.  A client that has been put in the
	// server but not yet moved to a spawn point reads as perfectly valid - right
	// health, right solidity, in the player chain - while standing at the map
	// origin.  Spawning around them puts every monster in the void, which is
	// exactly what this test did before: eight crabs at nav nodes near '0 0 37',
	// a bot that then teleported to its real spawn, and no monster that ever saw
	// anybody.  A nav node within reach is the cheap proof they are in the world.
	float i;
	float nearest = -1;
	for (i = 0; i < nav_count; i = i + 1)
	{
		float d0 = vlen(nav_pos[i] - p.origin);
		if (nearest < 0 || d0 < nearest)
			nearest = d0;
	}
	if (nav_count > 0 && nearest > NAV_LINK_DIST * 2)
	{
		if (time >= ai_spawntest_gripe)
		{
			ai_spawntest_gripe = time + 5;
			dprint(sprintf("[ai] sv_ai_spawntest: \"%s\" is at %v, %g units from the nearest nav node - waiting for a real spawn\n",
			               p.netname, p.origin, nearest));
		}
		return;
	}

	cvar_set("sv_ai_spawntest", "0");	// consumed only now that it can be honoured

	string cls = cvar_string("sv_ai_spawnclass");
	if (cls == "" || !cls)
		cls = "monster_headcrab";

	// A SECOND class, interleaved with the first.  This exists for one reason the
	// harness could not otherwise reach: the faction matrix decides who fights
	// whom, and testing it needs two DIFFERENT classes standing next to each
	// other.  With one class per run, "barney does not shoot the player" was
	// verifiable but "barney shoots the headcrab" was not, so the ally work
	// shipped half-tested.
	string cls2 = cvar_string("sv_ai_spawnclass2");
	if (cls2 != "" && cls2)
		if (!AI_ClassHasAI(cls2))
			cls2 = "";
	if (!AI_ClassHasAI(cls))
	{
		dprint(sprintf("[ai] sv_ai_spawnclass \"%s\" has no AI - spawning it would just make scenery\n", cls));
		return;
	}

	if (n > 64)
		n = 64;

	// Prefer NAV NODES near the player over a blind ring around them.  A node is
	// somewhere the graph build already proved a monster can stand and walk from,
	// whereas a ring at a fixed radius lands in walls, off ledges and inside
	// props - which is exactly what the first run of this test did, putting all
	// eight crabs in the void.  The ring stays as the fallback for maps with no
	// nav graph.
	//
	// The n NEAREST nodes, not the first n in range.  Graph order is build order,
	// so "first within 2048 units" scattered the monsters across half the map and
	// left them dormant - the whole point of the test is to put them where the
	// player will meet them.  n is capped at 64 and nav_count is a few hundred, so
	// the O(n * nav_count) scan is a few thousand compares, once.
	float spawned = 0;
	float prevd = -1, previ = -1;

	while (spawned < n)
	{
		float bd = -1, bi = -1;
		for (i = 0; i < nav_count; i = i + 1)
		{
			float d = vlen(nav_pos[i] - p.origin);
			// Strictly after the previous pick in (distance, index) order.  The
			// index tiebreak is what stops two nodes at the same distance - common
			// on a grid-built graph - from making the scan pick one of them forever.
			if (d < prevd)			continue;
			if (d == prevd && i <= previ)	continue;
			if (bi >= 0)
			{
				if (d > bd)		continue;
				if (d == bd && i > bi)	continue;
			}
			bd = d; bi = i;
		}
		if (bi < 0)
			break;			// ran out of nodes

		prevd = bd; previ = bi;
		// Alternate the two classes so they end up interleaved rather than in two
		// separate clumps - the point is to have them within sight of each other.
		if (cls2 != "" && cls2 && (spawned & 1))
			AI_SpawnTestOne(nav_pos[bi] + '0 0 8', cls2);
		else
			AI_SpawnTestOne(nav_pos[bi] + '0 0 8', cls);
		spawned = spawned + 1;
	}

	if (!spawned)
	{
		vector a = '0 0 0';
		for (i = 0; i < n; i = i + 1)
		{
			a_y = i * 45;
			makevectors(a);
			float rad = 96 + floor(i / 8) * 64;
			AI_SpawnTestOne(p.origin + '0 0 16' + v_forward * rad, cls);
			spawned = spawned + 1;
		}
		dprint(sprintf("[ai] sv_ai_spawntest: no nav nodes near %v, fell back to a ring\n", p.origin));
	}

	// `sv_ai_spawnfollow 1`: every ally that just spawned starts escorting the test
	// player.  The follow behaviour is otherwise reachable only through a human
	// pressing +use, which a headless drive has no way to do - so without this the
	// one path that cannot be measured is the one most likely to be wrong.
	if (cvar("sv_ai_spawnfollow"))
	{
		entity m = monster_chain_head;
		float nf = 0;
		while (m)
		{
			if ((m.flags & FL_MONSTER) && m.is_player_ally && !m.ai_follow)
			{
				m.ai_follow = p;
				nf = nf + 1;
			}
			m = m.monster_chain_next;
		}
		dprint(sprintf("[ai] sv_ai_spawnfollow: %g ally(s) now escorting %s\n", nf, p.netname));
	}

	dprint(sprintf("[ai] sv_ai_spawntest: spawned %g %s near %s at %v (nav_count=%g)\n",
	               spawned, cls, p.netname, p.origin, nav_count));
};

// ---------------------------------------------------------------------------
// publishing the monster model set  —  so the shooter's own bullets can hit them
// ---------------------------------------------------------------------------
// THE PROBLEM THIS SOLVES.  The person firing is the one person who never
// receives the server's impact effect: W_ImpactEffectSend skips the shooter
// (sv_weapons.qc:918) so their own predicted ric is not echoed back a ping later.
// Their entire visual is therefore CSQC's local trace - and CSQC cannot see
// monsters at all.  Monsters are plain engine-networked entities; they are not
// CSQC entities, so a CSQC traceline passes straight through one and lands on the
// wall behind it.
//
// The result is not merely "no blood".  It is a CONCRETE-DUST puff and a bullet
// hole on the wall behind the monster you just shot, at the wrong distance, with
// the tracer overshooting through the body.  That is the report.
//
// CSQC can reach engine entities through getentity() (#504) - origin, absmin,
// absmax, modelindex - so it can do the ray test itself for free, exactly as it
// already does for physics props (CSQC_PhysProp_OverrideTrace).  The only thing
// it cannot work out on its own is WHICH of those entities is a monster.
//
// Hence this: the server tells it, once, as a set of modelindexes.
//
// A HARDCODED CLIENT-SIDE LIST WOULD HAVE BEEN SHORTER AND WRONG.  Sven Co-op
// maps ship their own monster models constantly, and Monster_Build accepts a
// `model` key override on any placement - so the set genuinely is per-map and
// only the server knows it.  Publishing costs one small reliable message.
const float AI_MODELSET_MAX = 64;
float ai_modelset[AI_MODELSET_MAX];
float ai_modelset_n;
float ai_modelset_next;		// re-scan throttle
float ai_modelset_dirty;

void() AI_PublishMonsterModels =
{
	if (time < ai_modelset_next)
		return;
	// Rescan every 5s rather than every frame.  New models can only appear when a
	// squadmaker spawns a class the map had not placed, which is rare and never
	// urgent - the worst case is a few seconds of concrete-dust on a brand new
	// monster type, against a per-frame walk of the whole monster chain forever.
	ai_modelset_next = time + 5;

	// ACCUMULATING, never rebuilt.  The scan walks monster_chain, which a monster
	// LEAVES the instant it dies (Monster_Teardown) - so rebuilding from scratch
	// meant that when the last live grunt on the map died, the grunt modelindex
	// dropped out of the set within five seconds and every grunt CORPSE stopped
	// being traceable by the shooter's own client.  Bodies would bleed while one
	// of their kind was still alive and stop bleeding once it was not.
	//
	// A modelindex that has ever belonged to a monster still does.  The set is
	// capped at 64 and a busy map carries well under 20 distinct monster models,
	// so never forgetting costs nothing and removes the flicker entirely.
	float n = ai_modelset_n;
	entity m = monster_chain_head;
	while (m && n < AI_MODELSET_MAX)
	{
		float mi = m.modelindex;
		if (mi > 0)
		{
			// Linear scan: n is tiny and this runs once every five seconds.
			float j, seen = FALSE;
			for (j = 0; j < n; j = j + 1)
				if (ai_modelset[j] == mi)
					seen = TRUE;
			if (!seen)
			{
				ai_modelset[n] = mi;
				n = n + 1;
			}
		}
		m = m.monster_chain_next;
	}

	// The three classes that build themselves outside Monster_Build are not on
	// monster_chain, so this walk has never published tentacle2.mdl, nihilanth.mdl or
	// boid.mdl.  Consequence on hl_c11 / hl_c16 / hl_c17: Montrace_IsMonsterIdx says
	// no, CSQC_Monster_OverrideTrace skips them, and the SHOOTER's own bullets and
	// melee swings pass visually straight through the tentacle and the Nihilanth —
	// concrete dust on the wall behind, a metal clang on a swing that the server
	// scored as flesh.  Exactly the bug cl_monstertrace.qc:5-18 exists to fix, just
	// on the entities that were never in its set.  Cheap because it runs at the same
	// 5 s cadence and the set is accumulating, so one sighting is permanent.
	// (mi / j / seen are the loop above's locals — QC scopes locals to the FUNCTION,
	// so re-declaring them here is a Q207 duplicate-definition warning, not a shadow.)
	float pass = 0;
	while (pass < 2 && n < AI_MODELSET_MAX)
	{
		string socb_cls = (pass == 0) ? "monster_tentacle" : "monster_nihilanth";
		entity x = find(world, classname, socb_cls);
		while (x && n < AI_MODELSET_MAX)
		{
			mi = x.modelindex;
			if (mi > 0)
			{
				seen = FALSE;
				for (j = 0; j < n; j = j + 1)
					if (ai_modelset[j] == mi)
						seen = TRUE;
				if (!seen) { ai_modelset[n] = mi; n = n + 1; }
			}
			x = find(x, classname, socb_cls);
		}
		pass = pass + 1;
	}

	if (n == ai_modelset_n && !ai_modelset_dirty)
		return;			// nothing new; do not re-broadcast

	ai_modelset_n     = n;
	ai_modelset_dirty = FALSE;
	if (!n)
		return;

	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_MONSTER_MODELS);
	WriteByte(MSG_MULTICAST, n);
	float i;
	for (i = 0; i < n; i = i + 1)
		WriteShort(MSG_MULTICAST, ai_modelset[i]);
	// RELIABLE and ALL, not PVS.  A client that misses this gets no monster
	// bullet collision for the rest of the map and would have no way to ask
	// again; and the set is global state, not something happening at a place.
	multicast('0 0 0', MULTICAST_ALL_R);

	dprint(sprintf("[ai] published %g monster modelindexes to clients\n", n));
};

// A client that connects mid-map has missed the broadcast, so force the next
// scan to re-send.  Called from the connect path.
void() AI_MonsterModelsResend =
{
	ai_modelset_dirty = TRUE;
	ai_modelset_next  = 0;
};

// ---------------------------------------------------------------------------
// provoke self-test  —  `sv_ai_provoketest 1`
// ---------------------------------------------------------------------------
// The grudge escalation is reachable ONLY by a player shooting an ally, and a
// headless drive has no player who will: bots pick targets from the faction
// matrix, which says an ally is a friend, so a bot will never fire on one.  That
// leaves the whole of AI_TalkDamaged - two memory bits, the facing heuristic, the
// crossfire exemption and the expiry - untestable without a human.
//
// Same problem and same answer as sv_ai_spawnfollow directly above, and for the
// same reason: an unmeasurable path is where bugs live.  This drives the REAL
// entry point (W_ApplyDamage from a player edict) rather than calling
// AI_TalkDamaged directly, so what it exercises is what play exercises.
//
// TWO hits, spaced, because one proves nothing.  The design is an escalation:
// the first should leave the ally SUSPICIOUS and still friendly, the second
// should provoke.  A test that fires once cannot tell that from "every hit
// provokes", which is the failure mode that would ruin co-op.
.float ai_provoketest_stage;

void() AI_ProvokeTestThink =
{
	entity p = self.owner;
	if (!p || p.classname != "player" || p.health <= 0)
	{
		remove(self);
		return;
	}

	// Nearest live ally to the test player.
	entity best = world;
	float  bd   = 4096;
	entity m = monster_chain_head;
	while (m)
	{
		if (m.is_player_ally && m.health > 0 && m.think == AI_Think)
		{
			float d = vlen(m.origin - p.origin);
			if (d < bd) { bd = d; best = m; }
		}
		m = m.monster_chain_next;
	}

	if (!best)
	{
		dprint("[ai] sv_ai_provoketest: no live ally found\n");
		remove(self);
		return;
	}

	// AIM DELIBERATELY, and aim DIFFERENTLY on each hit - the facing heuristic is
	// half of what is under test and a bot's incidental view angle would make the
	// result a coin toss.
	//
	//   hit 1: looking 180 degrees AWAY.  HL reads that as an accident, so this
	//          must come back SUSPICIOUS and still friendly.
	//   hit 2: still looking away, but SUSPICIOUS is now set - and
	//          barney.cpp:525 ORs the two, so the second stray round provokes
	//          even though this one also looks accidental.
	//
	// That pair is the entire escalation.  Aiming at him both times would provoke
	// on hit 1 and prove only that the angry path exists.
	vector aim = vectoangles(best.origin - p.origin);
	if (self.ai_provoketest_stage < 2)
		aim_y = aim_y + 180;
	p.v_angle = aim;
	p.angles  = aim;

	W_ApplyDamage(p, best, 5);

	dprint(sprintf("[ai] sv_ai_provoketest: hit %g -> %s at %g units: memory=%g instant=%g follow=%s enemy=%s\n",
	               self.ai_provoketest_stage + 1, best.classname, bd, best.ai_memory,
	               best.ai_provoke_instant,
	               best.ai_follow ? "yes" : "no",
	               (best.ai_enemy == p) ? "PLAYER" : (best.ai_enemy ? best.ai_enemy.classname : "none")));

	self.ai_provoketest_stage = self.ai_provoketest_stage + 1;
	if (self.ai_provoketest_stage >= 2)
	{
		remove(self);
		return;
	}
	self.nextthink = time + 3;
};

// Armed once, from the AI tick, as soon as there is a live player to attribute
// the damage to.  Consumes the cvar so it cannot re-arm on respawn.
void() AI_CorpseTest;	// sv_ai_gibs.qc, which compiles after this file
void() AI_FireTest;	// likewise
void() AI_WalkTest;	// likewise
void() AI_VoiceTest;	// likewise
void() AI_DeathTest;	// likewise
void() AI_SquadTest;	// likewise
void() AI_CoverTest;	// likewise

void() AI_ProvokeTest =
{
	if (!cvar("sv_ai_provoketest"))
		return;

	entity p = player_chain_head;
	while (p && (p.health <= 0 || p.solid == SOLID_NOT))
		p = p.player_chain_next;
	if (!p)
		return;			// no live player yet; try again next tick

	cvar_set("sv_ai_provoketest", "0");

	entity t = spawn();
	t.owner     = p;
	t.think     = AI_ProvokeTestThink;
	// Late enough that the map's own scripted_sequences have claimed whoever they
	// are going to claim - a possessed actor is deliberately not provokable, and
	// hitting one would measure the script layer rather than this.
	t.nextthink = time + 12;
};

// ---------------------------------------------------------------------------
// squadmaker accounting self-test  —  `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// sq_live_children was incremented on spawn and never decremented.  That was
// inert while no spawned class could die; B3 makes zombie children real, so it
// is live now across 5768 spawners on 108 maps - and its failure mode is a
// silent progression stall, not an error: every capped squadmaker pins at its
// cap forever and stops firing the target chain the map's progression waits on.
//
// Gameplay cannot reach it in a test run (all 79 zombie spawners on th_ep1_01
// are capped AND none are START_ON, so they need a player to trigger them), so
// the accounting is exercised directly here.
//
// TWO CONTRACTS, and they used to be one.  The original test drove
// squadmaker_spawn_one three times at the world origin and asserted the count
// came out at 3, on the stated reasoning that placement would fail there and the
// accounting had to be right anyway.
//
// Both halves of that are now wrong.  An unplaceable child is REMOVED and NOT
// counted, which is Half-Life's own behaviour - CMonsterMaker::MakeMonster
// (monstermaker.cpp:172-186) boxes the spawn point first and returns without
// making anything if it is occupied - and it is what stops one blocked spawn
// point jamming a spawner for the rest of the map, since 72 of pizza_ya_san1's 97
// makers have m_imaxlivechildren 1 and would never come back under the cap.
// AND placement at the origin does not reliably fail: measured on pizza_ya_san1,
// all three test children stood up perfectly well, which is exactly the
// map-dependent self-test AI_SquadMonsterSelfTest warns about below.
//
// So Part A asserts the INVARIANT rather than an outcome - the slot count must
// equal the number of this maker's children actually left in the world - which is
// true whether or not the void happens to be standable on today's map, and is the
// property that matters: a phantom slot pins the spawner forever and an orphaned
// child is a monster nothing can account for.  Part B is the slot accounting, and
// it builds its children by hand and forces the fields placement would have set,
// the same move AI_SquadMonsterSelfTest makes and for the same reason.
float ai_squadtest_done;

// Children of `maker` still linked into the monster chain.
float(entity maker) AI_SquadTest_CountChildren =
{
	float n = 0;
	entity e = monster_chain_head;
	while (e)
	{
		if (e.sq_maker == maker)
			n = n + 1;
		e = e.monster_chain_next;
	}
	return n;
};

void() AI_SquadSelfTest =
{
	entity oldself = self;
	float bad = 0;
	float i;

	entity maker = spawn();
	maker.classname          = "squadmaker";
	maker.monstertype        = "monster_zombie";
	maker.monstercount       = 6;
	maker.m_imaxlivechildren = 3;
	maker.delay              = 0;
	maker.netname            = "";
	maker.target             = "";
	maker.trigger_target     = "";
	setorigin(maker, '0 0 0');

	// --- Part A: booked slots and surviving children must agree --------------
	self = maker;
	for (i = 0; i < 3; i = i + 1)
		squadmaker_spawn_one();
	self = oldself;

	float alive = AI_SquadTest_CountChildren(maker);
	if (maker.sq_live_children != alive)
	{
		dprint(sprintf("[ai-selftest] squad: %g slot(s) booked but %g child(ren) in the world\n",
		               maker.sq_live_children, alive));
		bad = bad + 1;
	}
	// ...and the maker is still willing to try, whichever way placement went:
	// budget 6, three attempts spent, three left.
	if (maker.sq_spawned_total >= maker.monstercount)
	{
		dprint(sprintf("[ai-selftest] squad: budget exhausted after 3 attempts (%g/%g)\n",
		               maker.sq_spawned_total, maker.monstercount));
		bad = bad + 1;
	}

	// Clear whatever Part A produced, so Part B starts from a known count rather
	// than from "however many the void happened to accept".
	entity c = monster_chain_head;
	while (c)
	{
		entity nx = c.monster_chain_next;
		if (c.sq_maker == maker)
		{
			monster_chain_remove(c);
			remove(c);
		}
		c = nx;
	}
	maker.sq_live_children = 0;
	maker.sq_spawned_total = 0;

	// --- Part B: the slot accounting, geometry-independent -------------------
	for (i = 0; i < 3; i = i + 1)
	{
		entity ch = Monster_Spawn(maker, maker.monstertype, maker.origin, maker.angles);
		// Force what placement would have set, so this half measures the SLOT
		// bookkeeping rather than whether the void is standable.
		ch.ai_placefail = FALSE;
		ch.flags        = ch.flags | FL_MONSTER;
		ch.health       = 100;
		ch.deadflag     = DEAD_NO;
		ch.sq_counted   = 1;
		maker.sq_live_children = maker.sq_live_children + 1;
	}

	if (maker.sq_live_children != 3)
	{
		dprint(sprintf("[ai-selftest] squad: expected 3 live children, got %g\n",
		               maker.sq_live_children));
		bad = bad + 1;
	}

	// The cap must actually hold.  This is the half that always worked.
	self = maker;
	squadmaker_spawn_one();
	self = oldself;
	if (maker.sq_live_children != 3)
	{
		dprint(sprintf("[ai-selftest] squad: cap breached, %g live\n", maker.sq_live_children));
		bad = bad + 1;
	}

	// Kill them through the real death handler and check the slots come back.
	entity m = monster_chain_head;
	float killed = 0;
	while (m)
	{
		entity nxt = m.monster_chain_next;	// Monster_Killed unlinks m
		if (m.sq_maker == maker)
		{
			self = m;
			m.health = 0;
			Monster_Killed();
			self = oldself;
			killed = killed + 1;
		}
		m = nxt;
	}

	if (killed != 3)
	{
		dprint(sprintf("[ai-selftest] squad: killed %g children, expected 3\n", killed));
		bad = bad + 1;
	}
	if (maker.sq_live_children != 0)
	{
		dprint(sprintf("[ai-selftest] squad: %g slots never returned (the pin-forever bug)\n",
		               maker.sq_live_children));
		bad = bad + 1;
	}

	// Double release must be a no-op.  A slot pushed back twice would let the
	// count go NEGATIVE and the cap stop applying at all - the opposite failure,
	// and a much harder one to see.
	m = monster_chain_head;
	while (m)
	{
		entity nxt2 = m.monster_chain_next;
		if (m.sq_maker == maker)
			Monster_Teardown(m);
		m = nxt2;
	}
	if (maker.sq_live_children != 0)
	{
		dprint(sprintf("[ai-selftest] squad: double release moved the count to %g\n",
		               maker.sq_live_children));
		bad = bad + 1;
	}

	// Tidy up: these are test entities and must not be left in the map.
	m = monster_chain_head;
	while (m)
	{
		entity nxt3 = m.monster_chain_next;
		if (m.sq_maker == maker)
		{
			monster_chain_remove(m);
			remove(m);
		}
		m = nxt3;
	}
	remove(maker);

	dprint(sprintf("[ai-selftest] squad accounting: BAD=%g\n", bad));
};

// ---------------------------------------------------------------------------
// squadmaker KEYS self-test  —  `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// The three squadmaker keys that decide what a Sven map's NPCs actually ARE, and
// every one of them used to be parsed and dropped on the floor:
// respawn_as_playerally, the Prisoner spawnflag, and an item classname in
// monstertype.  All three are invisible from any counter - a hostile customer
// looks exactly like a friendly one until it shoots you - so they get assertions
// rather than a report.
//
// Deliberately geometry-independent: every field checked below is set by
// AI_ClassInit or by the flip that follows it, both of which run BEFORE placement
// inside AI_Spawn, so the result does not depend on whether the world origin is
// standable on today's map.
float ai_squadkeytest_done;

// ---------------------------------------------------------------------------
// WEAPON ROSTER SELF-TEST
//
// Not an AI test, and it lives here only because this is where the gated
// self-test harness already runs.  It is the guard the weapon files' own
// comments keep pointing at: sh_weapons.qc:585 cites
// "check_serverfire.py now derives the correct set straight from the
// weapon sources and fails if this list disagrees with it", and that script does
// not exist on disk.  A test that runs on every headless map load does.
//
// Three invariants, each of which has already broken this tree at least once and
// each of which is INVISIBLE at compile time:
//
//   1. Every weapon id up to WMF_WEP_LAST has a manifest row.  A missing row
//      returns FALSE and the weapon draws as slot 0 with an empty display name -
//      it appears in no menu and equips to nothing.
//   2. Every PRIMARY/SECONDARY weapon survives a slot-ammo round trip.  A
//      missing mirror row is silent: the HUD prints 0 while the server holds the
//      real value (sh_weapon_slotammo.qc:106 records exactly that bug for four
//      weapons).
//   3. The loadout / debug / buy orders stay CONTIGUOUS with no duplicates.  A
//      gap leaves a "None" hole in the dropdown; a duplicate makes the lower id
//      win and the higher weapon unreachable (sh_weapon_manifest.qc:360, :903).
// ---------------------------------------------------------------------------
float ai_weptest_done;

void() AI_WeaponRosterSelfTest =
{
	entity oldself = self;
	float bad = 0;
	float wep;
	float missing_row = 0, mirror_fail = 0;

	entity p = spawn();
	p.classname = "player";
	self = p;

	for (wep = 1; wep <= WMF_WEP_LAST; wep = wep + 1)
	{
		// 1. manifest row present?
		if (!WeaponManifest_Load(wep))
		{
			missing_row = missing_row + 1;
			dprint(sprintf("[weptest] id %g has NO manifest row\n", wep));
			bad = bad + 1;
			continue;
		}

		// 2. slot-ammo round trip, for the slots that have one.
		if (!W_SlotAmmo_UsesSlot(wep))
			continue;

		// EXPECTATIONS COME FROM THE MANIFEST, not from a fixed pair.  A weapon
		// legitimately has a magazine, a reserve, both, or neither: the charge
		// weapons (gauss, egon, hornetgun, shock rifle, displacer, tesla, and
		// now the belt-fed minigun) carry no magazine at all, the grenade
		// launcher and rebar carry no reserve, and the gravity gun and grapple
		// carry nothing.  Demanding both back from all of them reports eleven
		// shipped weapons as broken, which is a test that would be turned off
		// rather than read.
		//
		// What must hold is narrower and is the thing that actually breaks: a
		// value the weapon IS supposed to have must survive the round trip.
		float want_mag  = (WeaponManifest_DefaultMag(wep)  > 0) ? 7  : 0;
		float want_ammo = (WeaponManifest_DefaultAmmo(wep) > 0) ? 23 : 0;
		if (!want_mag && !want_ammo)
			continue;                          // carries neither - nothing to mirror

		// Write a distinctive pair through the legacy fields, push it to the
		// canonical slot, wipe the slot, and pull it back.  A weapon missing
		// from either mirror table returns zeros.
		W_SlotAmmo_SetForWeapon(p, wep, want_mag, want_ammo, 0);
		W_SlotAmmo_LoadLegacy(p, wep);        // canonical -> the weapon's own fields
		W_SlotAmmo_SetForWeapon(p, wep, 0, 0, 0);
		W_SlotAmmo_SaveLegacy(p, wep);        // the weapon's own fields -> canonical
		W_SlotAmmo_GetForWeapon(p, wep);

		if (slotammo_mag != want_mag || slotammo_ammo != want_ammo)
		{
			mirror_fail = mirror_fail + 1;
			dprint(sprintf("[weptest] %s (id %g) slot-ammo round trip: want %g/%g got %g/%g\n",
			               WeaponManifest_DisplayName(wep), wep,
			               want_mag, want_ammo, slotammo_mag, slotammo_ammo));
			bad = bad + 1;
		}
	}

	remove(p);
	self = oldself;

	dprint(sprintf("[ai-selftest] weapon roster: %g weapons, %g missing rows, %g mirror failures, BAD=%g\n",
	               WMF_WEP_LAST, missing_row, mirror_fail, bad));
};

void() AI_SquadmakerKeySelfTest =
{
	entity oldself = self;
	float  bad = 0;
	float  i;

	// --- the ally flip, both directions -------------------------------------
	// Sven's key is "Default (0) / Opposite (1)", so the SAME value has to make a
	// hostile class friendly and a friendly class hostile.  pizza_ya_san1 relies
	// on the first: its four seated customers are an assassin, a zombie, a
	// babygargantua and a male assassin wearing custom models.
	entity flipmaker = spawn();
	flipmaker.classname             = "squadmaker";
	flipmaker.respawn_as_playerally = 1;
	setorigin(flipmaker, '0 0 0');

	entity hostile = Monster_Spawn(flipmaker, "monster_human_grunt", '0 0 0', '0 0 0');
	if (hostile.ai_class != CLASS_PLAYER_ALLY || !hostile.is_player_ally)
	{
		dprint(sprintf("[ai-selftest] squadkeys: flipped grunt is class %g ally %g, expected %g 1\n",
		               hostile.ai_class, hostile.is_player_ally, CLASS_PLAYER_ALLY));
		bad = bad + 1;
	}

	entity friendly = Monster_Spawn(flipmaker, "monster_human_grunt_ally", '0 0 0', '0 0 0');
	if (friendly.ai_class == CLASS_PLAYER_ALLY || friendly.is_player_ally)
	{
		dprint(sprintf("[ai-selftest] squadkeys: flipped grunt ALLY is class %g ally %g, expected hostile\n",
		               friendly.ai_class, friendly.is_player_ally));
		bad = bad + 1;
	}

	// ...and no flip means no change, which is the case the three pizza shop staff
	// take and the one a bug here would break silently.
	flipmaker.respawn_as_playerally = 0;
	entity plain = Monster_Spawn(flipmaker, "monster_human_grunt_ally", '0 0 0', '0 0 0');
	if (plain.ai_class != CLASS_PLAYER_ALLY || !plain.is_player_ally)
	{
		dprint(sprintf("[ai-selftest] squadkeys: unflipped grunt ally is class %g ally %g\n",
		               plain.ai_class, plain.is_player_ally));
		bad = bad + 1;
	}

	// --- PRISONER, and it has to bind in BOTH directions ---------------------
	entity prismaker = spawn();
	prismaker.classname  = "squadmaker";
	prismaker.spawnflags = SQ_SF_PRISONER;
	setorigin(prismaker, '0 0 0');

	entity prisoner = Monster_Spawn(prismaker, "monster_human_grunt", '0 0 0', '0 0 0');
	if (!prisoner.ai_prisoner)
	{
		dprint("[ai-selftest] squadkeys: Prisoner spawnflag never reached the child\n");
		bad = bad + 1;
	}
	// Forced, because AI_ValidEnemy tests them and placement may have cleared them.
	prisoner.flags = prisoner.flags | FL_MONSTER;  prisoner.health = 100;
	prisoner.deadflag = DEAD_NO;                   prisoner.solid  = SOLID_SLIDEBOX;
	hostile.flags  = hostile.flags  | FL_MONSTER;  hostile.health  = 100;
	hostile.deadflag  = DEAD_NO;                   hostile.solid   = SOLID_SLIDEBOX;
	if (AI_ValidEnemy(hostile, prisoner))
	{
		dprint("[ai-selftest] squadkeys: a prisoner was picked as an enemy\n");
		bad = bad + 1;
	}
	if (AI_ValidEnemy(prisoner, hostile))
	{
		dprint("[ai-selftest] squadkeys: a prisoner picked an enemy\n");
		bad = bad + 1;
	}

	// --- the item dispenser, and its cap ------------------------------------
	// 44 of pizza_ya_san1's 97 makers name an item rather than a monster, all of
	// them monstercount -1: uncapped they would bury the map in healthkits, and
	// unimplemented they produce nothing at all.  Both failures are silent.
	entity itemmaker = spawn();
	itemmaker.classname          = "squadmaker";
	itemmaker.monstertype        = "item_healthkit";
	itemmaker.monstercount       = -1;
	itemmaker.m_imaxlivechildren = 2;
	itemmaker.delay              = 0;
	sq_next_id = sq_next_id + 1;
	itemmaker.sq_id = sq_next_id;
	setorigin(itemmaker, '0 0 0');

	self = itemmaker;
	for (i = 0; i < 4; i = i + 1)
		squadmaker_spawn_one();
	self = oldself;

	float made = Squadmaker_CountLiveItems(itemmaker);
	if (made != 2)
	{
		dprint(sprintf("[ai-selftest] squadkeys: item maker produced %g, expected its cap of 2\n", made));
		bad = bad + 1;
	}

	// Take one away, as a pickup would, and the dispenser must come back under the
	// cap by itself - the whole reason the item count is a scan and not a latch.
	entity it = findfloat(world, sq_ownerid, itemmaker.sq_id);
	if (it)
		remove(it);
	self = itemmaker;
	squadmaker_spawn_one();
	self = oldself;
	if (Squadmaker_CountLiveItems(itemmaker) != 2)
	{
		dprint(sprintf("[ai-selftest] squadkeys: dispenser did not refill (%g live)\n",
		               Squadmaker_CountLiveItems(itemmaker)));
		bad = bad + 1;
	}

	// Tidy up.  Everything spawned here is a test entity.
	entity e = findfloat(world, sq_ownerid, itemmaker.sq_id);
	while (e)
	{
		entity nx = findfloat(e, sq_ownerid, itemmaker.sq_id);
		remove(e);
		e = nx;
	}
	Monster_Teardown(hostile);   remove(hostile);
	Monster_Teardown(friendly);  remove(friendly);
	Monster_Teardown(plain);     remove(plain);
	Monster_Teardown(prisoner);  remove(prisoner);
	remove(flipmaker);
	remove(prismaker);
	remove(itemmaker);

	dprint(sprintf("[ai-selftest] squadmaker keys: BAD=%g\n", bad));
};

// ---------------------------------------------------------------------------
// squad MONSTER self-test  —  `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// Entirely different subject from the one above, sharing only an unfortunate
// word: that test is the SPAWNER's child budget, this one is the Half-Life squad
// a monster fights in.
//
// It exists because squads are close to invisible from outside.  A run where no
// squad ever forms and a run where the squad system is switched off produce the
// same log and the same behaviour, and the difference between them on a real map
// is whether that map happens to place two of the same monster within 1024 units
// of each other with line of sight - which is a property of the map, not of the
// code.  Measured on hl_c01_a1: exactly one squad of two, which is far too thin
// a result to conclude anything from.
//
// So the situation is CONSTRUCTED.  Four bodies at known offsets, recruited
// directly, and then the three things that are easy to get quietly wrong:
// leadership inheritance when the leader dies, the slot ration, and the ration
// being handed back.
float ai_squadmontest_done;
float ai_covertest_done;

void() AI_SquadMonsterSelfTest =
{
	entity oldself = self;
	float  bad = 0;
	float  i;
	entity mem[4];

	// Four grunts in a line 64 units apart at the world origin.  Built through
	// Monster_Build so they carry a real .ai_class and .ai_slots_attack, but
	// placement is expected to fail (no floor) and does not matter: recruitment
	// asks about class, name, distance and sight, none of which need ground.
	for (i = 0; i < 4; i = i + 1)
	{
		entity m = spawn();
		m.classname = "monster_human_grunt";
		setorigin(m, [i * 64, 0, 0]);
		self = m;
		Monster_Build(TRUE);
		self = oldself;
		// Force the parts placement would have set, so the test measures squads
		// rather than whether the void is standable.
		m.flags    = m.flags | FL_MONSTER;
		m.health   = 100;
		m.deadflag = DEAD_NO;
		mem[i] = m;
	}

	// BUILT BY HAND, not by Squad_Recruit, and that is a correction rather than a
	// shortcut.  Recruitment ends in a traceline between the two bodies, so it is
	// a function of the MAP: the first version of this test called it, and it
	// passed on th_ep1_00 and hl_c01_a1 and reported BAD=6 on th_ep1_01 and 2fort
	// - not because squads were broken there, but because the world origin these
	// test bodies stand at is inside solid geometry on those two, so the trace
	// between grunt 0 and grunts 2 and 3 never arrived.
	//
	// A self-test whose result depends on which map is loaded is worse than no
	// self-test, because it teaches the reader to ignore it.  Everything below
	// this line is geometry-independent; the recruitment FILTERS get their own
	// check at the end, which is geometry-independent too.
	mem[0].ai_squad_leader = mem[0];
	mem[0].ai_squad_next   = world;
	for (i = 1; i < 4; i = i + 1)
		Squad_Add(mem[0], mem[i]);

	if (Squad_Count(mem[0]) != 4)
	{
		dprint(sprintf("[ai-selftest] squadmon: squad of %g, expected 4\n",
		               Squad_Count(mem[0])));
		bad = bad + 1;
	}
	if (!Squad_IsLeader(mem[0]))
	{
		dprint("[ai-selftest] squadmon: recruiter is not the leader\n");
		bad = bad + 1;
	}
	for (i = 1; i < 4; i = i + 1)
		if (Squad_Leader(mem[i]) != mem[0])
		{
			dprint(sprintf("[ai-selftest] squadmon: member %g points at the wrong leader\n", i));
			bad = bad + 1;
		}

	// THE RATION.  Two engage slots, four askers: exactly two must get one.  A
	// third success means the bitfield is not shared; a second failure on the
	// same monster means a slot is being taken twice.
	float won = 0;
	for (i = 0; i < 4; i = i + 1)
		if (Squad_OccupySlot(mem[i], SQSLOTS_ENGAGE))
			won = won + 1;
	if (won != 2)
	{
		dprint(sprintf("[ai-selftest] squadmon: %g of 4 got an engage slot, expected 2\n", won));
		bad = bad + 1;
	}

	// ...and handed back.  Vacating must be idempotent: it is called from
	// schedule change, from death and from teardown, and two of those can fire
	// for the same monster in one frame.
	for (i = 0; i < 4; i = i + 1)
	{
		Squad_VacateSlot(mem[i]);
		Squad_VacateSlot(mem[i]);
	}
	if (mem[0].ai_squad_slots != 0)
	{
		dprint(sprintf("[ai-selftest] squadmon: %i slot bits never returned\n",
		               mem[0].ai_squad_slots));
		bad = bad + 1;
	}

	// THE CALLOUT reaches everyone who is not already engaged.
	mem[0].ai_enemy = oldself;
	Squad_MakeEnemy(mem[0], oldself);
	for (i = 1; i < 4; i = i + 1)
		if (mem[i].ai_enemy != oldself)
		{
			dprint(sprintf("[ai-selftest] squadmon: member %g never got the callout\n", i));
			bad = bad + 1;
		}

	// LEADERSHIP IS INHERITED, not disbanded.  Killing the leader must leave a
	// squad of three with a new head, not three individuals - otherwise shooting
	// the right grunt first silently turns off the whole system.
	Squad_Remove(mem[0]);
	if (Squad_In(mem[0]))
	{
		dprint("[ai-selftest] squadmon: dead leader is still in the squad\n");
		bad = bad + 1;
	}
	if (Squad_Count(mem[1]) != 3)
	{
		dprint(sprintf("[ai-selftest] squadmon: %g left after the leader died, expected 3\n",
		               Squad_Count(mem[1])));
		bad = bad + 1;
	}
	// WHICHEVER survivor inherited, not mem[1].  The chain is built in findradius
	// order, which is not array order - the first version of this check assumed it
	// was and reported "leadership was not inherited" against working code.  The
	// property that actually matters is that ONE of them is now its own leader and
	// the other two agree with it.
	entity heir = Squad_Leader(mem[1]);
	if (!Squad_IsLeader(heir) || heir == mem[0]
	    || Squad_Leader(mem[2]) != heir || Squad_Leader(mem[3]) != heir)
	{
		dprint("[ai-selftest] squadmon: leadership was not inherited\n");
		bad = bad + 1;
	}

	// Down to one: NOT a squad any more, or the survivor spends the rest of the
	// map rationing its own attack slots against nobody.  Removed by identity
	// rather than by index for the same reason as above.
	for (i = 1; i < 4; i = i + 1)
		if (mem[i] != heir)
			Squad_Remove(mem[i]);
	if (Squad_In(heir))
	{
		dprint("[ai-selftest] squadmon: a lone survivor is still flagged as a squad\n");
		bad = bad + 1;
	}

	// THE RECRUITMENT FILTERS, checked the one way that needs no line of sight:
	// by asserting what must NOT happen.  Re-form the squad by hand, then let a
	// fresh grunt standing on top of them try to recruit.  Every candidate it can
	// see is already taken, so it must come away with nobody - a recruiter that
	// steals members would leave two half-squads and a leader pointing at a
	// monster that no longer answers to it.
	mem[0].ai_squad_leader = mem[0];
	mem[0].ai_squad_next   = world;
	for (i = 1; i < 4; i = i + 1)
	{
		mem[i].ai_squad_leader = world;
		mem[i].ai_squad_next   = world;
		Squad_Add(mem[0], mem[i]);
	}

	entity late = spawn();
	late.classname = "monster_human_grunt";
	setorigin(late, mem[0].origin);
	self = late;
	Monster_Build(TRUE);
	self = oldself;
	late.flags    = late.flags | FL_MONSTER;
	late.health   = 100;
	late.deadflag = DEAD_NO;

	Squad_Recruit(late, SQUAD_RECRUIT_DIST);
	if (Squad_In(late))
	{
		dprint("[ai-selftest] squadmon: a late arrival recruited monsters that were already in a squad\n");
		bad = bad + 1;
	}
	if (Squad_Count(mem[0]) != 4)
	{
		dprint(sprintf("[ai-selftest] squadmon: original squad is %g after a second recruiter ran, expected 4\n",
		               Squad_Count(mem[0])));
		bad = bad + 1;
	}
	Monster_Teardown(late);
	remove(late);

	for (i = 0; i < 4; i = i + 1)
	{
		Monster_Teardown(mem[i]);
		remove(mem[i]);
	}

	dprint(sprintf("[ai-selftest] squad monsters: BAD=%g\n", bad));
};

// ---------------------------------------------------------------------------
// cover
// ---------------------------------------------------------------------------
// GEOMETRY-INDEPENDENT BY CONSTRUCTION, which is the lesson from the squad
// self-test rather than a coincidence: its first version called Squad_Recruit,
// which ends in a traceline, and so reported BAD=6 on the two maps whose world
// origin is inside solid.  Nothing below fires a trace, so nothing below can
// disagree between maps.
//
// That rules out testing the SEARCH itself - "is there cover near the origin"
// is a question about the map, and the only honest place to ask it is a live
// harness (sv_ai_covertest).  What can be asserted here is everything that
// decides whether a found spot is USED, plus the schedule shapes, which are the
// parts a later edit is most likely to break silently.
// The half that reads the SCHEDULE TABLE, split out and run from AI_Init instead
// of from AI_Tick.
//
// THAT SPLIT IS A BUG THIS TEST FOUND IN ITS OWN WIRING, and it is worth stating
// because it is a trap for the next self-test as much as it was for this one.
// The two squad self-tests run from AI_Tick, and the comment there explains why:
// they spawn and remove entities, which is not a thing to do inside worldspawn
// while the map's own entities are still being parsed.  Cover needs both - it
// spawns bodies AND reads the schedule table - and the first version put the
// whole thing in AI_Tick, where it reported `take_cover is missing find=0
// move=0` on all five maps while the table plainly contained both tasks.  The
// table is built by AI_SchedBuildAll inside AI_Init, and the AI_Tick tests do
// not run after it in the order the log actually shows.  Nothing that reads
// sched_* may run from AI_Tick; nothing that spawns may run from AI_Init.
//
// The count is carried in a global rather than printed here so the reader still
// gets exactly one `cover: BAD=` line to look at.
float ai_cover_schedbad;

void() AI_CoverSchedSelfTest =
{
	ai_cover_schedbad = 0;

	// THE INTERRUPT MASK IS THE ASSERTION THAT MATTERS.  Every condition a
	// reasonable person might add to take_cover is one that destroys it:
	// COND_DAMAGE aborts the run to cover at the first round that lands, which
	// is the exact moment cover exists for, and COND_ATTACK_READY stops the
	// monster halfway to shoot from the open.  Both produce a monster that sets
	// off somewhere and then does not go, and neither produces an error.
	int cm = Sched_Interrupts(SCHED_TAKE_COVER);
	if (cm & COND_DAMAGE)
	{
		dprint("[ai-selftest] cover: take_cover interrupts on damage; it will abort every time it is shot at\n");
		ai_cover_schedbad = ai_cover_schedbad + 1;
	}
	if (cm & COND_ATTACK_READY)
	{
		dprint("[ai-selftest] cover: take_cover interrupts on attack-ready; it will stop halfway\n");
		ai_cover_schedbad = ai_cover_schedbad + 1;
	}

	// The schedule has to actually contain the two tasks that make it a move.
	float have_find = FALSE;
	float have_move = FALSE;
	float j;
	float n = Sched_Len(SCHED_TAKE_COVER);
	for (j = 0; j < n; j = j + 1)
	{
		float op = Sched_Op(SCHED_TAKE_COVER, j);
		if (op == TASK_FIND_COVER_ENEMY)	have_find = TRUE;
		if (op == TASK_WAIT_FOR_MOVE)		have_move = TRUE;
	}
	if (!have_find || !have_move)
	{
		dprint(sprintf("[ai-selftest] cover: take_cover len=%g is missing find=%g move=%g\n",
		               n, have_find, have_move));
		ai_cover_schedbad = ai_cover_schedbad + 1;
	}

	// Cower must NOT move.  It is what a monster does when it cannot.
	if (Sched_HasMovement(SCHED_COWER))
	{
		dprint("[ai-selftest] cover: cower contains a movement task\n");
		ai_cover_schedbad = ai_cover_schedbad + 1;
	}
	// ...and cover_failed must not either, or a monster that just failed to find
	// anywhere to go would be told to go there anyway.
	if (Sched_HasMovement(SCHED_COVER_FAILED))
	{
		dprint("[ai-selftest] cover: cover_failed contains a movement task\n");
		ai_cover_schedbad = ai_cover_schedbad + 1;
	}
};

// ---------------------------------------------------------------------------
// sv_ai_selftest  —  the view cone
// ---------------------------------------------------------------------------
// Pure geometry with no gameplay attached, which is exactly what a synthetic test
// is for: the headless harness cannot make a monster ACQUIRE anything (the
// headless client connects as a spectator, so AI_ValidEnemy rejects it and no
// acquisition is ever attempted), so the cone would otherwise ship unmeasured.
//
// The negative cases are the point.  Half-Life writes wide cones as NEGATIVE dot
// thresholds - VIEW_FIELD_WIDE is -0.7, i.e. 270 degrees across - and the first
// version of AI_InViewCone treated anything <= 0 as "no cone at all", which would
// have silently handed every barney, scientist and alien slave a 360-degree head.
void() AI_SenseSelfTest =
{
	entity oldself = self;
	float  bad = 0;

	entity a = spawn();
	entity b = spawn();
	setorigin(a, '0 0 0');
	a.angles = '0 0 0';		// facing +x

	// --- a 120-degree cone (CBaseMonster's own default) --------------------
	a.ai_fov = 0.5;
	setorigin(b, '200 0 0');
	if (!AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: straight ahead was outside a 120-degree cone\n"); bad = bad + 1; }
	setorigin(b, '-200 0 0');
	if (AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: directly behind was inside a 120-degree cone\n"); bad = bad + 1; }
	setorigin(b, '0 200 0');	// 90 degrees off: dot 0, outside 0.5
	if (AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: 90 degrees off was inside a 120-degree cone\n"); bad = bad + 1; }

	// --- VIEW_FIELD_WIDE, the one the old test would have got wrong --------
	a.ai_fov = -0.7;
	setorigin(b, '0 200 0');	// dot 0 > -0.7: inside
	if (!AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: 90 degrees off was outside a 270-degree cone\n"); bad = bad + 1; }
	setorigin(b, '-200 0 0');	// dot -1 < -0.7: still outside
	if (AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: directly behind was inside a 270-degree cone\n"); bad = bad + 1; }

	// --- VIEW_FIELD_FULL: nothing is ever outside --------------------------
	a.ai_fov = -1;
	setorigin(b, '-200 0 0');
	if (!AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: a 360-degree monster failed to see behind itself\n"); bad = bad + 1; }

	// --- pitch must not matter --------------------------------------------
	// A target over your head is still in front of you; HL drops the Z for the
	// same reason.  A turret shooting at something on a gantry depends on it.
	a.ai_fov = 0.5;
	setorigin(b, '200 0 400');
	if (!AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: height above the eyeline changed the cone answer\n"); bad = bad + 1; }

	// --- the cone follows the BODY, not the ideal yaw ----------------------
	a.angles = '0 180 0';		// turned round; +x is now behind it
	setorigin(b, '200 0 0');
	if (AI_InViewCone(a, b))
	{ dprint("[ai-selftest] sense: the cone did not follow the body's yaw\n"); bad = bad + 1; }

	remove(a);
	remove(b);
	self = oldself;
	dprint(sprintf("[ai-selftest] sense: BAD=%g\n", bad));
};

void() AI_CoverSelfTest =
{
	entity oldself = self;
	float  bad = ai_cover_schedbad;

	// --- two bodies, no floor needed --------------------------------------
	entity a = spawn();
	entity b = spawn();
	a.classname = "monster_human_grunt";
	b.classname = "monster_human_grunt";
	setorigin(a, '0 0 0');
	setorigin(b, '200 0 0');
	self = a; Monster_Build(TRUE); self = oldself;
	self = b; Monster_Build(TRUE); self = oldself;
	a.flags = a.flags | FL_MONSTER;	a.health = 100; a.deadflag = DEAD_NO;
	b.flags = b.flags | FL_MONSTER;	b.health = 100; b.deadflag = DEAD_NO;

	// --- Cover_Validate: squad spacing ------------------------------------
	// A monster with no squad accepts everything - squadmonster.cpp:548.
	if (!Cover_Validate(a, b.origin))
	{
		dprint("[ai-selftest] cover: a squadless monster refused a cover spot\n");
		bad = bad + 1;
	}

	a.ai_squad_leader = a;
	a.ai_squad_next   = world;
	Squad_Add(a, b);

	// b is standing at [200 0 0], so a spot on top of it is taken and a spot well
	// clear of it is not.  COVER_SQUAD_SPACING is 128, measured flat.
	if (Cover_Validate(a, '210 0 0'))
	{
		dprint("[ai-selftest] cover: accepted a spot a squadmate is standing on\n");
		bad = bad + 1;
	}
	if (!Cover_Validate(a, '600 0 0'))
	{
		dprint("[ai-selftest] cover: refused a spot 400 units clear of the squad\n");
		bad = bad + 1;
	}
	// Measured FLAT, like HL's Length2D: a squadmate one storey up is still on
	// top of you as far as "we would be standing on each other" goes.
	if (Cover_Validate(a, '210 0 400'))
	{
		dprint("[ai-selftest] cover: spacing measured in 3D, not flat\n");
		bad = bad + 1;
	}

	// --- Cover_Allowed: the guard rail ------------------------------------
	a.ai_enemy    = b;
	a.ai_covernext = 0;
	float wasmode = a.ai_movemode;
	a.ai_movemode = AIMODE_STATIC;
	if (Cover_Allowed(a))
	{
		// This one is not cosmetic: SCHED_TAKE_COVER contains movement tasks, and
		// AI_SchedSelfTest asserts that nothing a bolted-down monster can reach
		// does.  A turret that could take cover turns a passing self-test into a
		// permanent failure somewhere else entirely.
		dprint("[ai-selftest] cover: a bolted-down monster was allowed to take cover\n");
		bad = bad + 1;
	}
	a.ai_movemode = wasmode;
	if (!Cover_Allowed(a))
	{
		dprint("[ai-selftest] cover: a mobile monster with an enemy was refused\n");
		bad = bad + 1;
	}
	// The retry floor has to hold, or a monster in an open room runs the whole
	// search ten times a second for the length of the fight.
	a.ai_covernext = time + 10;
	if (Cover_Allowed(a))
	{
		dprint("[ai-selftest] cover: the search retry floor is not respected\n");
		bad = bad + 1;
	}
	a.ai_covernext = 0;
	a.ai_enemy = world;
	if (Cover_Allowed(a))
	{
		dprint("[ai-selftest] cover: allowed with no enemy at all\n");
		bad = bad + 1;
	}

	// --- Cover_EnemyFacingMe ----------------------------------------------
	// a is at the origin, b at [200 0 0].  b facing -x is looking straight at a;
	// b facing +x is looking away.  Pure arithmetic, no trace.
	b.flags  = b.flags - (b.flags & FL_CLIENT);
	b.angles = '0 180 0';
	if (!Cover_EnemyFacingMe(a, b))
	{
		dprint("[ai-selftest] cover: an enemy looking straight at us did not count as facing\n");
		bad = bad + 1;
	}
	b.angles = '0 0 0';
	if (Cover_EnemyFacingMe(a, b))
	{
		dprint("[ai-selftest] cover: an enemy looking directly away counted as facing\n");
		bad = bad + 1;
	}
	// PITCH MUST NOT MATTER.  Someone aiming over your head is still pointed at
	// you, and folding pitch into the test would make every enemy on a staircase
	// read as looking elsewhere.
	b.angles = '80 180 0';
	if (!Cover_EnemyFacingMe(a, b))
	{
		dprint("[ai-selftest] cover: pitch changed the facing answer\n");
		bad = bad + 1;
	}

	Monster_Teardown(a); remove(a);
	Monster_Teardown(b); remove(b);

	dprint(sprintf("[ai-selftest] cover: BAD=%g\n", bad));
};

// ---------------------------------------------------------------------------
// per-frame budget reset
// ---------------------------------------------------------------------------
// Called from StartFrame, before physics runs the monster thinks.
float ai_next_report;

// Split out of AI_Tick because AI_Init needs it too.
//
// This is not a refactor for tidiness: map entities spawn during map load,
// BEFORE the first StartFrame, so a cache only ever filled by AI_Tick is still
// all zeroes when Monster_Build runs for every monster the map places.  With
// ai_cached_enable at 0, AI_Spawn returned FALSE for all of them and the entire
// corpus stayed inert while the cvar read 1.  Priming it in AI_Init - which
// worldspawn calls before any entity spawns - is what makes map-placed monsters
// work at all.
void() AI_CacheCvars =
{
	ai_cached_enable = cvar("sv_ai_enable");
	ai_cached_debug  = cvar("sv_ai_debug");

	ai_cached_sight = cvar("sv_ai_sight");
	if (ai_cached_sight <= 0)
		ai_cached_sight = 1024;			// HL's default sight range

	ai_cached_arcturns = cvar("sv_ai_arcturns");
	ai_cached_scriptwake = cvar("sv_ai_script_wake");

	ai_trace_budget = cvar("sv_ai_traces");
	if (ai_trace_budget <= 0)
		ai_trace_budget = 24;

	// Negative is meaningless; 0 legitimately means "no ration at all", so this
	// cannot use the <=0 fallback shape the two above use.
	ai_cached_engageslots = cvar("sv_ai_engageslots");
	if (ai_cached_engageslots < 0)
		ai_cached_engageslots = 2;

	// Debug only, default 0.  See AI_Spawn.
	ai_cached_forcemode = cvar("sv_ai_forcemode");
};

void() AI_Tick =
{
	AI_CacheCvars();

	// Repair the monster list before anything walks it this frame.  Self-throttled
	// to 4 Hz, which is inside FTE's 0.5 s edict-recycle window - see the long note
	// on Monster_Chain_Verify (server/sv_monsters.qc) for why that number is the
	// whole mechanism.  Not gated on any cvar: a circular list is a dead server.
	Monster_Chain_Verify();

	// One line, once, on the first frame - see its own comment for why not from
	// AI_Init.  Self-latching, so this is a field read after the first tick.
	Soundlist_Report();
	Modellist_Report();
	GSoundlist_Report();
	// Stage 3a's three subsystems, same self-latching one-line-per-map shape.
	// GoldSrcFX_Report is already compiled (sv_progs.src:203); the other two
	// live below us and are forward-declared at the head of this file.
	// A cosmetic or scripted entity leaves nothing in a log on its own, so
	// without these "it did not work" and "it was never built" are the same
	// observation.  Each prints only on a map that actually has one.
	GoldSrcFX_Report();
	Checkpoint_Report();
	Charger_Report();
	// Did the Half-Life animation set reach the player models?  Same
	// self-latching one-line shape; see its own comment for why it is permanent.
	SH_HLAnimReport();
	SH_DoDAnimReport();

	// Run once, on the first frame rather than from AI_Init: it spawns and
	// removes entities, and doing that inside worldspawn - while the map's own
	// entities are still being parsed - is asking for trouble.
	if (!ai_squadtest_done && cvar("sv_ai_selftest"))
	{
		ai_squadtest_done = TRUE;
		AI_SquadSelfTest();
	}

	// ...and this one waits for ai_cached_enable as well.  Every field it asserts
	// is written by AI_ClassInit, which AI_Spawn refuses to reach while the AI is
	// off - and sv_ai_enable is not readable on the first frame, because the cvar
	// table has not been registered yet and cvar() answers 0 for a name it has
	// never seen.  Measured: the test ran three seconds before the map's own
	// monsters and reported every class as 0.
	if (!ai_squadkeytest_done && ai_cached_enable && cvar("sv_ai_selftest"))
	{
		ai_squadkeytest_done = TRUE;
		AI_SquadmakerKeySelfTest();
	}
	if (!ai_weptest_done && cvar("sv_ai_selftest"))
	{
		ai_weptest_done = TRUE;
		AI_WeaponRosterSelfTest();
	}

	if (!ai_squadmontest_done && cvar("sv_ai_selftest"))
	{
		ai_squadmontest_done = TRUE;
		AI_SquadMonsterSelfTest();
	}

	if (!ai_covertest_done && cvar("sv_ai_selftest"))
	{
		ai_covertest_done = TRUE;
		AI_CoverSelfTest();
		AI_SenseSelfTest();
	}

	// Live explosives -> danger sounds.  Self-throttled to 5 Hz and returns
	// immediately on a map with no monsters, so it costs nothing where it buys
	// nothing.
	AI_DangerScan();

	AI_SpawnTest();
	AI_ProvokeTest();
	AI_CorpseTest();	// sv_ai_corpsetest: the corpse damage rules, measured
	AI_FireTest();		// sv_ai_firetest: does each shooter reach a player at all
	AI_WalkTest();		// sv_ai_walktest: does each walker's footstep cycle play
	AI_VoiceTest();		// sv_ai_voicetest: does a .ai_snd_* family reach the mixer
	AI_DeathTest();		// sv_ai_deathtest: does a monster die the way it was shot
	AI_SquadTest();		// sv_ai_squadtest: do four grunts behave like a squad
	AI_CoverTest();		// sv_ai_covertest: does a monster under fire get out of the way
	AI_PublishMonsterModels();

	if (ai_cached_debug && time >= ai_next_report)
	{
		ai_next_report = time + 2;
		AI_ReportStats();
	}
};

// ---------------------------------------------------------------------------
// sv_ai_animtest  —  "are we using all the sequences, and does anything consume
//                     the events these models raise?"
// ---------------------------------------------------------------------------
// Two numbers per class, both derived from the MODEL rather than from a list
// somebody has to maintain:
//
//   acts=N/M   how many of Half-Life's 77 activities resolve to a real sequence
//              on this model, out of how many sequences it carries.  This is the
//              direct measurement of the "are all the animations used" question -
//              a low N against a high M means most of the model is unreachable.
//
//   events=... every DISTINCT low (< 1000, per-class) event code the model raises
//              anywhere.  A code in this list that the class's handler has no
//              branch for is a behaviour that silently does nothing, which is
//              exactly how the male assassin lost his kick and his entire burst
//              and how the shocktrooper lost its rate limit.
//
// The pairing is the point.  Neither number needs updating when a model changes,
// and a mount that swaps massn.mdl for hassassin.mdl changes both, in place, on
// the next run.
const float AI_ANIMTEST_MAXACT   = 78;	// HL's activity enum tops out at 77
const float AI_ANIMTEST_MAXCODE  = 32;	// per-class codes are small; 1000+ is shared

float animtest_seen[AI_ANIMTEST_MAXCODE];

void(string cls) AI_AnimTestClass =
{
	string mdl = Monster_DefaultModel(cls);
	if (mdl == "" || !mdl)
		return;

	float mi = getmodelindex(mdl);
	if (mi <= 0)
	{
		dprint(sprintf("[ai-animtest] %-26s %-24s MODEL MISSING\n", cls, mdl));
		return;
	}

	float nseq = modelframecount(mi);
	float a, nact = 0;
	for (a = 1; a < AI_ANIMTEST_MAXACT; a = a + 1)
		if (frameforaction(mi, (int)a) >= 0)
			nact = nact + 1;

	// Distinct low event codes across every sequence.
	float i;
	for (i = 0; i < AI_ANIMTEST_MAXCODE; i = i + 1)
		animtest_seen[i] = 0;

	float s, e;
	float ts; int code; string edata;
	for (s = 0; s < nseq; s = s + 1)
		for (e = 0; e < AI_EVENT_MAX; e = e + 1)
		{
			if (!getmodeleventidx(mi, s, (int)e, ts, code, edata))
				break;
			if ((float)code > 0 && (float)code < AI_ANIMTEST_MAXCODE)
				animtest_seen[(float)code] = 1;
		}

	string codes = "";
	for (i = 1; i < AI_ANIMTEST_MAXCODE; i = i + 1)
		if (animtest_seen[i])
			codes = strcat(codes, (codes == "") ? "" : ",", ftos(i));
	if (codes == "")
		codes = "-";

	// WHICH DEATHS AND FLINCHES THIS RIG CAN ACTUALLY DO.  The directional-death
	// and hitgroup-flinch pickers ask for an ideal and take something else when
	// the model cannot do it, so "the code chose ACT_DIE_HEADSHOT" and "the
	// monster played a headshot death" are different claims and only the model
	// file settles the second one.  Printed per class so a Sven install with
	// replacement rigs reports its own answer rather than inheriting valve's.
	//
	// Measured over the 41 rigs this mod resolves today: HEADSHOT on 16, GUTSHOT
	// on 14, forward/backward on 22/21, the four limb flinches on 10 each - and
	// CHESTSHOT, BACKSHOT and the three torso flinches on NOTHING, which is why
	// those five constants are dead in Half-Life too.
	string dfl = "";
	if (frameforaction(mi, (int)ACT_DIE_HEADSHOT) >= 0)  dfl = strcat(dfl, "head ");
	if (frameforaction(mi, (int)ACT_DIE_GUTSHOT)  >= 0)  dfl = strcat(dfl, "gut ");
	if (frameforaction(mi, (int)ACT_DIEFORWARD)   >= 0)  dfl = strcat(dfl, "fwd ");
	if (frameforaction(mi, (int)ACT_DIEBACKWARD)  >= 0)  dfl = strcat(dfl, "back ");
	if (frameforaction(mi, (int)ACT_FLINCH_LEFTARM)  >= 0
	 || frameforaction(mi, (int)ACT_FLINCH_RIGHTARM) >= 0
	 || frameforaction(mi, (int)ACT_FLINCH_LEFTLEG)  >= 0
	 || frameforaction(mi, (int)ACT_FLINCH_RIGHTLEG) >= 0) dfl = strcat(dfl, "limbs ");
	if (dfl == "")
		dfl = "-";

	dprint(sprintf("[ai-animtest] %-26s acts=%2g/%-3g die/flinch=%-24s events=%s\n",
	               cls, nact, nseq, dfl, codes));
};

void() AI_AnimTest =
{
	dprint("[ai-animtest] --- activities reachable / event codes raised, per model ---\n");
	monster_class_cb = AI_AnimTestClass;
	Monster_ForEachAIClass();
};

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------
// Monster_ForEachAIClass's warm consumer.  Kept as a named function rather than
// inlined because QC has no lambdas and the walker takes a function pointer.
void(string cls) AI_WarmClass =
{
	AI_WarmModel(Monster_DefaultModel(cls));
};

void() AI_Init =
{
	// FIRST: worldspawn runs before the map's entities, and every one of them
	// reaches Monster_Build -> AI_Spawn, which reads this cache.  Filling it only
	// in AI_Tick (StartFrame) is one frame too late for the whole map.
	AI_CacheCvars();

	AI_SchedBuildAll();

	// Event sounds the ANIM PUMP names itself.  Every other event sound arrives in
	// the event's options string and AI_PrecacheModelSounds harvests it off the
	// model; these two have no options field, so nothing was ever going to find
	// them automatically.  See the SND_BODYDROP_* note in sv_ai_defs.qc.
	precache_sound(SND_BODYDROP_A);
	precache_sound(SND_BODYDROP_B);
	// The swish and the four footsteps are here for exactly the same reason: their
	// events carry an empty options string, so AI_PrecacheModelSounds - which can
	// only harvest names it is GIVEN - will never see them.  The four steps happen
	// to be precached already as a side effect of valve's zombie and hgrunt naming
	// them in EVENT_SOUND events, but relying on that would make hwgrunt's footsteps
	// depend on which OTHER monsters the map happens to contain.
	precache_sound(SND_SWISH);
	precache_sound(SND_NPC_STEP1);
	precache_sound(SND_NPC_STEP2);
	precache_sound(SND_NPC_STEP3);
	precache_sound(SND_NPC_STEP4);

	// The per-class sound sets: hand-written lists of files the QC names itself.
	Headcrab_Precache();
	Zombie_Precache();
	ZombieVariants_Precache();
	Cockroach_Precache();
	Islave_Precache();
	Houndeye_Precache();
	Bosses_Precache();
	BigFoes_Precache();
	Grunt_Precache();
	Barnacle_Precache();
	SwimFly_Precache();
	Turret_Precache();
	Aliens_Precache();

	// And every model, warmed and harvested, derived from the class list rather
	// than hand-listed beside it.
	//
	// This used to be 21 AI_WarmModel lines interleaved with the calls above, and
	// the AI registry knew 43 classes.  The 18 that were missing were all the
	// Opposing Force and Sven half - strooper, gonome, massn, otis, voltigore,
	// pit_drone, hwgrunt, robogrunt, hgrunt_opfor, scientist, babygarg, kingpin -
	// and warming is where AI_PrecacheModelSounds runs, so those models' event
	// sounds were never precached and sound() dropped every one of them on the
	// floor.  A silent monster looks exactly like a monster with no sound events,
	// which is why it survived three rounds of review.
	//
	// Resolving through Monster_DefaultModel rather than a literal path also means
	// the FALLBACK gets warmed when the real model is absent: monster_male_assassin
	// warms massn.mdl on an install with gearbox mounted and hassassin.mdl on one
	// without, which is the same question the rig table below has to answer.
	monster_class_cb = AI_WarmClass;
	Monster_ForEachAIClass();

	// Two the class list cannot reach: the zombie variants share one classname
	// group but three distinct models.
	AI_WarmModel("models/zombie_barney.mdl");
	AI_WarmModel("models/zombie_soldier.mdl");

	if (cvar("sv_ai_selftest"))
	{
		AI_SchedSelfTest();
		// Here and not in AI_Tick: it reads the schedule table, which
		// AI_SchedBuildAll built a few lines above.  See its own comment.
		AI_CoverSchedSelfTest();
		AI_SeqNameSelfTest();
		// AFTER the class warm-up above, not before: AI_WarmClass is what runs every
		// class's precache, and an empty register would report a clean bill of
		// health for a list it had never seen.
		AI_SndSelfTest();
		Monster_ReportModels();
		AI_AnimTest();
	}
};

// ---------------------------------------------------------------------------
// diagnostics  —  `sv_ai_debug 1`
// ---------------------------------------------------------------------------
// Volume-mode census.  Answers the one question the aggregate counters cannot:
// are the flyers actually flying?  The counters prove QC is the only thing moving
// them; they say nothing about whether the engine is quietly pulling them down.
// A FLY monster that has fallen reads as clearance ~0, which is exactly what a
// gravity regression would look like - and exactly what MOVETYPE_FLY would have
// produced, since Physics_Toss pins anything that touches a floor.
//
// Debug-only and folded into the 2 s report, so its traces never run on a live
// server, and silent when nothing uses a volume mode.
void() AI_ReportVolume =
{
	entity e;
	float n = 0, lo = 0, hi = 0, sum = 0;

	e = findflags(world, flags, FL_MONSTER);
	while (e)
	{
		if (e.ai_movemode != AIMODE_GROUND && e.health > 0)
		{
			traceline(e.origin, e.origin - '0 0 4096', MOVE_NORMAL, e);

			// Clearance under the HULL, matching how ai_flyheight is specified.
			// -1 means the trace found no floor at all within 4096 units, which is
			// a monster over a pit rather than one that has sunk.
			float clr = -1;
			if (trace_fraction < 1)
				clr = (e.origin_z + e.mins_z) - trace_endpos_z;

			if (!n || clr < lo)	lo = clr;
			if (!n || clr > hi)	hi = clr;
			n   = n + 1;
			sum = sum + clr;
		}
		e = findflags(e, flags, FL_MONSTER);
	}

	if (n)
		dprint(sprintf("[ai]   volume: n=%g clearance min=%g max=%g mean=%g\n",
		               n, lo, hi, sum / n));
};

void() AI_ReportStats =
{
	dprint(sprintf("[ai] thinks=%g traces=%g denied=%g walkmove=%g fails=%g sidestep=%g cornercut=%g\n",
	               ai_dbg_thinks, ai_dbg_traces, ai_dbg_tracedenied,
	               ai_dbg_walkmoves, ai_dbg_walkfails, ai_dbg_sidesteps,
	               ai_dbg_cornercuts));
	// Split across two prints: sprintf takes at most 8 varargs (fteqcc warns past
	// that and silently drops the rest), and this line had exactly 8 already.
	dprint(sprintf("[ai]   move: arrived=%g moving=%g turning=%g nowaypoint=%g\n",
	               ai_dbg_mv_arrived, ai_dbg_mv_moving, ai_dbg_mv_turning,
	               ai_dbg_mv_nowp));
	dprint(sprintf("[ai]   move: blocked=%g spun=%g nopath=%g volstep=%g\n",
	               ai_dbg_mv_blocked, ai_dbg_mv_spun, ai_dbg_mv_nopath,
	               ai_dbg_volmoves));
	// Traversability, from AI_LegClear.  skipveto = corners the monster wanted to
	// cut straight through a wall; holdveto = waypoints it wanted to retire while
	// the gap was still in front of it.  Both should be ~0 in open country and
	// non-zero wherever there is a doorway.
	dprint(sprintf("[ai]   legs: traces=%g skipveto=%g holdveto=%g\n",
	               ai_dbg_legtraces, ai_dbg_skipveto, ai_dbg_holdveto));
	// Half-Life's BuildRoute order.  direct = goals walked straight to without
	// ever touching the node graph; nodefall = goals that failed the local-move
	// test and fell through to a nav search ("last ditch, try nodes").
	// Split across two prints deliberately: fteqcc warns past 8 varargs, and a
	// sprintf that silently drops arguments is a diagnostic that lies.
	dprint(sprintf("[ai]   route: direct=%g nodefall=%g\n",
	               ai_dbg_direct, ai_dbg_nodefall));
	dprint(sprintf("[ai]   route refused: far=%g zgate=%g wall=%g ledge=%g solid=%g steps=%g\n",
	               ai_dbg_dfar, ai_dbg_dz, ai_dbg_dwall, ai_dbg_dledge,
	               ai_dbg_dsolid, ai_dbg_dsteps));
	// Perception.  fovreject at 0 while monsters are fighting means the cone is
	// doing nothing; danger heard/cover should move together, and heard climbing
	// while cover stays flat means the cover search is failing, not the sound.
	dprint(sprintf("[ai]   sense: fovreject=%g danger heard=%g cover=%g investigate=%g\n",
	               ai_dbg_fov_rejected, ai_dbg_danger_heard,
	               ai_dbg_danger_cover, ai_dbg_investigate));
	// Degrees of body yaw turned, and the ticks spent turning WITHOUT stepping.
	// The first must roughly double against the pre-patch build for the same
	// scene; the second must fall sharply, because monsters now walk while they
	// turn instead of standing still until they have finished.
	dprint(sprintf("[ai]   yaw: %g degrees turned, %g turn-only ticks\n",
	               ai_dbg_yawdeg, ai_dbg_mv_turning));
	dprint(sprintf("[ai]   anim events: shared=%g class=%g\n",
	               ai_dbg_ev_shared, ai_dbg_ev_class));
	// BOTH MUST BE ZERO.  freed = a removal path let a linked monster be freed
	// without Monster_Teardown; cycles = the list had already closed into a ring
	// before the sweep caught it, which is a crash the sweep converted into a log
	// line.  Either one climbing is the next bug, not a statistic.
	dprint(sprintf("[ai]   chain: %g linked, freed-unlinked=%g cycles-broken=%g\n",
	               monster_chain_count, mchain_dbg_freed, mchain_dbg_cycles));
	// The three that were structurally zero before this patch and must not silently
	// return to zero: star = GoldSrc stream prefixes stripped off event sound names
	// (every one of which the engine refused to even look up), step = code 2003
	// footsteps, swish = code 2010 melee wind-ups.
	// scriptdead = code 1000 SCRIPT_EVENT_DEAD, i.e. scenes whose own animation
	// killed the actor.  Must read exactly one per triggered death scene: 0 means
	// the event never arrived, >1 means the pump is re-delivering it.
	dprint(sprintf("[ai]   event fixes: star=%g step=%g swish=%g scriptdead=%g\n",
	               ai_dbg_ev_star, ai_dbg_ev_step, ai_dbg_ev_swish,
	               ai_dbg_ev_scriptdead));
	// seqoverride = per-class SetActivity picks taken by NAME; missing = names the
	// rig did not carry, which fall back to the activity lottery and are the number
	// to watch on a Sven install.  The grenade split must correlate with the
	// loadout perfectly - a launch on a grunt carrying hand grenades is the exact
	// bug this replaced.
	dprint(sprintf("[ai]   seq overrides: taken=%g missing=%g  grenade: throw=%g launch=%g\n",
	               ai_dbg_seqoverride, ai_dbg_seqmissing,
	               ai_dbg_gren_throw, ai_dbg_gren_launch));
	// restart = one-shot sequences re-rolled onto a second variant so the client
	// would replay them (the zombie's frozen mid-swing pose); stuck = repeats the
	// model offered no alternative for, which will still freeze and is a fact about
	// the rig rather than a fault here.
	dprint(sprintf("[ai]   seq replay: restart=%g stuck=%g\n",
	               ai_dbg_seqrestart, ai_dbg_seqstuck));
	// voice = lines played out of a .ai_snd_* family, reg = distinct files the
	// register holds.  reg is a TOTAL, not an interval count, so it must stay put
	// once the map has warmed; voice must be non-zero on any map with live
	// monsters, and was necessarily zero before the families existed for the
	// twenty-odd classes that had no pain or death hook at all.
	dprint(sprintf("[ai]   voices: played=%g  registered=%g (dupes=%g overflow=%g)\n",
	               ai_dbg_snd_voice, ai_sndreg_count,
	               ai_sndreg_dupes, ai_sndreg_overflow));
	// TOTALS, not interval counts, and deliberately so: a death happens once per
	// monster, so a two-second window over a quiet map would read 0 0 0 and say
	// nothing.  group = the hitgroup chose the death (head / gut), dir = the shot
	// direction did (fall forward / backward), simple = the rig could do neither.
	// `simple` is never expected to be 0 - the headcrab, garg, controller and
	// bigmomma carry only ACT_DIESIMPLE - but `group` and `dir` both being 0 on a
	// map with bullet kills means the plumbing is dead, which is exactly what
	// could not be seen before, since the old table constant resolved through the
	// same fallback chain and produced identical logs either way.
	dprint(sprintf("[ai]   deaths: group=%g dir=%g simple=%g (nowhere-to-fall=%g)  flinch: limb=%g generic=%g\n",
	               ai_dbg_die_group, ai_dbg_die_dir, ai_dbg_die_simple,
	               ai_dbg_die_blocked, ai_dbg_flinch_group, ai_dbg_flinch_generic));
	// The two creature effects that are TRACED rather than simply emitted, so a
	// zero here has two meanings and the second number tells them apart:
	// slave arcs legitimately find nothing when the slave charges in the open,
	// and the flame legitimately never starts if no gargantua ever gets a target
	// into its cone.  ticks/hits are what prove a started sweep did anything.
	dprint(sprintf("[ai]   slave-arcs=%g  garg-flames: sweeps=%g ticks=%g hits=%g  stomps=%g\n",
	               ai_dbg_slave_arcs, ai_dbg_garg_flames,
	               ai_dbg_garg_flameticks, ai_dbg_garg_flamehits, ai_dbg_garg_stomps));
	// ALL TOTALS, none reset - unlike the movement and event lines above, which
	// are interval counts.  Squads form once and a callout happens once per
	// sighting, so a two-second window over a quiet stretch would read all zeros
	// and say nothing; and sv_ai_squadtest reads these directly at the end of its
	// run, which an interval counter cannot support.
	//
	// `denied` is the number that says the ration is doing something: 0 with a
	// squad in a fight means everybody is shooting at once, which is the firing
	// line the slots exist to prevent.  `won` at 0 while monsters shoot means the
	// request never reached Squad_MayEngage at all.
	dprint(sprintf("[ai]   squads=%g members=%g callouts=%g slots: won=%g denied=%g  ff-holds=%g friend-dmg=%g\n",
	               ai_dbg_squad_leaders, ai_dbg_squad_recruits,
	               ai_dbg_squad_callouts, ai_dbg_squad_slotwins,
	               ai_dbg_squad_slotdenied, ai_dbg_squad_ffholds,
	               ai_dbg_squad_frienddmg));
	// Totals too, for the same reason, and laid out so the two questions cover
	// raises can be asked separately:
	//
	//   Is it being CHOSEN?  sched.  Zero means no class trigger ever fired -
	//   nobody was hurt, or nobody who was hurt has a cover trigger.
	//   Is it WORKING?  arrived against sched.  A large gap is the failure this
	//   whole line exists to make visible: a monster that decides to take cover
	//   and never gets there stands in the open looking indecisive, which is a
	//   worse picture than the charging it replaced.
	//
	// The four search outcomes are separate because they have opposite fixes.
	// `none` is a map with no cover in it and is a legitimate answer; `refused`
	// is the nav queue or the repath throttle saying no and is OURS to fix;
	// `capped` is the search giving up early, which no single failure counter
	// would ever distinguish from either.
	// Split across two lines because fteqcc's sprintf takes at most eight
	// varargs, not for any reason of layout.
	dprint(sprintf("[ai]   cover: sched=%g arrived=%g tries=%g lateral=%g node=%g\n",
	               ai_dbg_cover_sched, ai_dbg_cover_arrived, ai_dbg_cover_tries,
	               ai_dbg_cover_lateral, ai_dbg_cover_node));
	dprint(sprintf("[ai]   cover: none=%g refused=%g capped=%g noroute=%g spacing=%g cower=%g facing=%g\n",
	               ai_dbg_cover_none, ai_dbg_cover_refused, ai_dbg_cover_capped,
	               ai_dbg_cover_noroute, ai_dbg_cover_spacing, ai_dbg_cover_cower,
	               ai_dbg_cover_facing));
	ai_dbg_ev_shared = 0; ai_dbg_ev_class = 0;
	ai_dbg_ev_star = 0; ai_dbg_ev_step = 0; ai_dbg_ev_swish = 0;
	ai_dbg_ev_scriptdead = 0;
	ai_dbg_seqoverride = 0; ai_dbg_seqmissing = 0;
	ai_dbg_seqrestart = 0; ai_dbg_seqstuck = 0;
	ai_dbg_gren_throw = 0; ai_dbg_gren_launch = 0;
	ai_dbg_snd_voice = 0;
	AI_ReportTalk();
	AI_ReportScripts();
	AI_ReportCombat();
	AI_ReportVolume();
	ai_dbg_thinks = 0; ai_dbg_traces = 0; ai_dbg_tracedenied = 0;
	ai_dbg_walkmoves = 0; ai_dbg_walkfails = 0; ai_dbg_sidesteps = 0;
	ai_dbg_cornercuts = 0;
	ai_dbg_volmoves = 0;
	ai_dbg_mv_arrived = 0; ai_dbg_mv_moving = 0; ai_dbg_mv_turning = 0;
	ai_dbg_mv_nowp = 0; ai_dbg_mv_blocked = 0; ai_dbg_mv_nopath = 0;
	ai_dbg_mv_spun = 0; ai_dbg_yawdeg = 0;
	ai_dbg_legtraces = 0; ai_dbg_skipveto = 0; ai_dbg_holdveto = 0;
	ai_dbg_direct = 0; ai_dbg_nodefall = 0;
	ai_dbg_dfar = 0; ai_dbg_dz = 0; ai_dbg_dwall = 0; ai_dbg_dledge = 0;
	ai_dbg_dsolid = 0; ai_dbg_dsteps = 0;
	ai_dbg_fov_rejected = 0; ai_dbg_danger_heard = 0;
	ai_dbg_danger_cover = 0; ai_dbg_investigate = 0;
};

// ---------------------------------------------------------------------------
//  sv_ai_sound_selftest  —  the hearing rules, asserted against their sources
// ---------------------------------------------------------------------------
// Written because "the scientists follow me around and ignore my gun" was ONE
// bug with two faces, and the fix for it is a set of rules rather than a patch to
// a single line.  A rule that is only checked by playing the game is a rule that
// silently rots; these are the four that matter, each with the SDK line it comes
// from, checked on a scratch entity that is never linked into the world.
//
// Stage 1 is the mask algebra (AI_SoundMaskNow), stage 2 the movement-speed pick
// that made a fleeing scientist walk.  Both are pure functions of their inputs, so
// this needs no map, no player and no monster - it runs identically everywhere and
// costs one frame.
float aisnd_test_done;

void() AI_SoundSelfTest =
{
	if (!cvar("sv_ai_sound_selftest") || aisnd_test_done)
		return;
	aisnd_test_done = TRUE;

	float bad = 0;
	entity t  = spawn();

	// --- 1. an IDLE TALKER is deaf to footsteps and to world noise -----------
	// CTalkMonster's idle schedules carry `bits_SOUND_COMBAT | bits_SOUND_DANGER`
	// with PLAYER and WORLD commented out in the SDK source itself
	// (talkmonster.cpp:287-291), under the line "change these, and you'll break
	// the talking code".  This is the assertion that keeps a scientist from
	// walking over to inspect the player's feet every 0.35 seconds.
	t.ai_talker = TRUE;
	t.ai_state  = MS_IDLE;
	int m1 = AI_SoundMaskNow(t);
	if (m1 & SND_PLAYER)	{ bad = bad + 1; dprint("[aisnd] BAD: idle talker hears PLAYER\n"); }
	if (m1 & SND_WORLD)	{ bad = bad + 1; dprint("[aisnd] BAD: idle talker hears WORLD\n"); }
	if (!(m1 & SND_COMBAT))	{ bad = bad + 1; dprint("[aisnd] BAD: idle talker deaf to COMBAT\n"); }
	if (!(m1 & SND_DANGER))	{ bad = bad + 1; dprint("[aisnd] BAD: idle talker deaf to DANGER\n"); }

	// --- 2. ...but not once he has something to fight ------------------------
	// HL's AND is against the CURRENT schedule's mask, so the narrowing lifts the
	// moment he leaves the idle set.  Modelled here by the enemy test.
	t.ai_enemy = t;
	if (!(AI_SoundMaskNow(t) & SND_PLAYER))
		{ bad = bad + 1; dprint("[aisnd] BAD: engaged talker still deaf to PLAYER\n"); }
	t.ai_enemy = world;

	// --- 3. a NON-talker keeps the full default mask -------------------------
	// CBaseMonster cares about every sound (monsters.cpp).  Masking PLAYER on the
	// shared idle schedules would have made headcrabs deaf too, which is exactly
	// the mistake AI_SoundMaskNow's per-class form exists to avoid.
	t.ai_talker = FALSE;
	int m3 = AI_SoundMaskNow(t);
	if (!(m3 & SND_PLAYER))	{ bad = bad + 1; dprint("[aisnd] BAD: plain monster deaf to PLAYER\n"); }
	// Widened for printing only: sprintf's %g wants a float and these are ints, so
	// the alternative is five casts inline.  The comparisons above stay integer.
	float f1 = m1, f3 = m3, fd = SND_DEFAULT;
	if (m3 != SND_DEFAULT)	{ bad = bad + 1; dprint(sprintf("[aisnd] BAD: default mask is %g, want %g\n", f3, fd)); }

	// --- 4. the scared gaits are RUNS ---------------------------------------
	// ACT_RUN_SCARED is 64, not 4, so the mover's old `== ACT_RUN` identity test
	// sent a fleeing scientist off at ai_speed_walk - 59 u/s against the 275 the
	// cycle is drawn for.  He played the frantic animation at a stroll and skated.
	if (!AI_ActivityIsRun(ACT_RUN))		{ bad = bad + 1; dprint("[aisnd] BAD: ACT_RUN not a run\n"); }
	if (!AI_ActivityIsRun(ACT_RUN_SCARED))	{ bad = bad + 1; dprint("[aisnd] BAD: ACT_RUN_SCARED not a run\n"); }
	if (AI_ActivityIsRun(ACT_WALK))		{ bad = bad + 1; dprint("[aisnd] BAD: ACT_WALK counted as a run\n"); }
	if (AI_ActivityIsRun(ACT_WALK_SCARED))	{ bad = bad + 1; dprint("[aisnd] BAD: ACT_WALK_SCARED counted as a run\n"); }

	remove(t);
	dprint(sprintf("[aisnd] mask idle-talker=%g default=%g plain=%g  BAD=%g\n",
	               f1, fd, f3, bad));
};
