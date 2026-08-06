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
void(entity m) Grunt_BodyInit;
void(entity m) Shocktrooper_ClassInit;
void(entity m) Robogrunt_ClassInit;
void(entity m) Barney_ClassInit;
void(entity m) Scientist_ClassInit;
float()        Scientist_DefaultHealth;
void(entity m) Gargantua_ClassInit;
float()        Gargantua_DefaultHealth;
void(entity m) Babygarg_ClassInit;
float()        Babygarg_DefaultHealth;
void(entity m) Stukabat_ClassInit;
float()        Stukabat_DefaultHealth;
void(entity m) Kingpin_ClassInit;
float()        Kingpin_DefaultHealth;
void(entity m) BigMomma_ClassInit;
float()        BigMomma_DefaultHealth;
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

const float AI_TICK       = 0.1;	// decision rate, awake.  Half-Life's is the same.
const float AI_TICK_IDLE  = 0.5;	// ...and dormant, with nobody near
const float AI_HEAVY_DMG  = 20;		// >= this in one hit is COND_HEAVY_DAMAGE (HL's figure)
const float AI_FLINCH_GAP = 2.0;	// minimum seconds between flinches

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

// Nearest valid enemy by straight-line distance, LOS-checked.  Walks the player
// chain rather than find()ing, so it costs one pointer chase per player.
entity(entity m) AI_FindEnemy =
{
	entity best = world;
	float bestd = ai_cached_sight;
	entity p = player_chain_head;

	while (p)
	{
		if (AI_ValidEnemy(m, p))
		{
			float d = vlen(p.origin - m.origin);
			if (d < bestd)
			{
				if (AI_CanSee(m, p))
				{
					best  = p;
					bestd = d;
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
			if (dq < bestd)
			{
				if (AI_CanSee(m, q))
				{
					best  = q;
					bestd = dq;
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
	        | COND_ENEMY_TOOFAR | COND_CAN_MELEE1 | COND_CAN_RANGE1);

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
	}

	entity e = m.ai_enemy;
	float d = vlen(e.origin - m.origin);

	if (d > ai_cached_sight)
		c = c | COND_ENEMY_TOOFAR;

	if (AI_CanSee(m, e))
	{
		c = c | COND_SEE_ENEMY;
		m.ai_lastseen    = time;
		m.ai_lastseenpos = e.origin;

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

// Global rate limit.  An automatic weapon fires ten times a second and each shot
// would otherwise walk the whole monster chain; four sweeps a second is plenty to
// feel instant and is the difference between a free feature and a per-shot cost.
float ai_gunfire_next;

void(entity who) AI_HeardGunfire =
{
	if (!who || time < ai_gunfire_next)
		return;
	ai_gunfire_next = time + 0.25;

	entity m = monster_chain_head;
	while (m)
	{
		if (m.health > 0 && m.think == AI_Think && m.ai_state != MS_DEAD)
		if (vlen(m.origin - who.origin) <= AI_GUNFIRE_RANGE)
		{
			m.ai_cond        = m.ai_cond | COND_HEAR_SOUND;
			m.ai_lastseenpos = who.origin;

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

	if (m.ai_selectsched)
	{
		entity oldself = self;
		self = m;
		float r = m.ai_selectsched();
		self = oldself;
		if (r != SCHED_NONE)
			return r;
	}

	// A failed task outranks everything except dying: the fail schedule is what
	// stops a monster retrying an impossible thing forever.
	if (m.ai_cond & COND_TASK_FAILED)
	{
		float fs = m.ai_failsched;
		if (fs <= SCHED_NONE || fs >= SCHED_MAX)
			fs = SCHED_FAIL;
		return fs;
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
		if (m.ai_cond & COND_CAN_MELEE1)	return SCHED_MELEE_ATTACK1;
		if (m.ai_cond & COND_CAN_RANGE1)	return SCHED_RANGE_ATTACK1;

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

	// Following, checked AFTER the combat block and BEFORE the alert/idle ladder.
	//
	// That position is the whole design.  Above it, and an escorted barney would
	// walk away from the thing shooting at him; below the idle branches, and he
	// would never get there at all, because SCHED_IDLE_STAND is returned
	// unconditionally and nothing after it is reachable.  Fighting outranks
	// following; following outranks standing around.
	if (AI_WantsToFollow(m))
		return SCHED_FOLLOW;

	if (m.ai_state == MS_ALERT)
	{
		if (m.ai_cond & COND_SEE_ENEMY)		return SCHED_WAKE_ANGRY;
		if (m.ai_cond & COND_HEAR_SOUND)	return SCHED_ALERT_FACE;
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
		if (!m.ai_enemy)
			AI_TaskFail(m);
		else
			AI_YawToward(m, m.ai_enemy.origin);
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
			AI_PathRequest(m, m.ai_enemy.origin);
			m.ai_taskend = time + 2;	// answer deadline, not a wait
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
		if (!m.ai_follow || m.ai_follow.health <= 0)
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
			makevectors('0 1 0' * (num_for_edict(m) * 47));
			vector spot = m.ai_follow.origin + v_forward * (AI_FOLLOW_STOP * 0.75);

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
		if (m.ai_idlesound)
		{
			oldself = self;
			self = m;
			m.ai_idlesound();
			self = oldself;
		}
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
	if (op == TASK_SET_FAIL_SCHED)		return TRUE;
	if (op == TASK_SET_STATE)		return TRUE;
	if (op == TASK_CLEAR_COND)		return TRUE;
	if (op == TASK_FACE_ENEMY)		return TRUE;
	if (op == TASK_FACE_IDEAL)		return TRUE;
	if (op == TASK_TURN_RANDOM)		return TRUE;
	if (op == TASK_GET_PATH_ENEMY)		return TRUE;
	if (op == TASK_GET_PATH_LKP)		return TRUE;
	if (op == TASK_GET_PATH_FLEE)		return TRUE;
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
	if (op == TASK_FACE_SCRIPT)		return TRUE;
	if (op == TASK_WAIT_FOR_SCRIPT)		return TRUE;
	if (op == TASK_PLAY_SCRIPT)		return TRUE;
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
	else if (op == TASK_PLAY_SEQUENCE || op == TASK_PLAY_SEQ_NAMED)
	{
		if (AI_SeqDone(m))
			AI_TaskComplete(m);
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
			Script_SequenceDone(m);
			AI_TaskComplete(m);
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
			float want = m.ai_moveact;
			if (fd < AI_FOLLOW_WALK_UNDER)
				want = ACT_WALK;
			else if (fd >= AI_FOLLOW_RUN_OVER)
				want = ACT_RUN;

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

		float spd = (m.ai_moveact == ACT_RUN) ? m.ai_speed_run : m.ai_speed_walk;
		if (spd <= 0)
			spd = 100;
		float r = AI_MoveAlongPath(m, spd * dt);

		if (r == AIMOVE_ARRIVED)
			AI_TaskComplete(m);
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

void(entity m, float dt) AI_RunSchedule =
{
	if (m.ai_sched == SCHED_NONE)
		AI_SetSchedule(m, AI_SelectSchedule(m));

	// Interrupt check, before running anything: a schedule whose preconditions
	// died this tick must not get one more task out first.
	int mask = Sched_Interrupts(m.ai_sched);
	if (mask)
		if (m.ai_cond & mask)
			AI_SetSchedule(m, AI_SelectSchedule(m));

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
		awake = AI_AnyPlayerNear(m);
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
	AI_ChangeYaw(m, dt);
	AI_RunSchedule(m, dt);
	AI_AnimPump(m);
};

// ---------------------------------------------------------------------------
// damage and death
// ---------------------------------------------------------------------------
// Installed on .on_damaged / driven from Monster_Killed.  W_ApplyDamage
// (sv_weapons.qc:1816) dispatches on_damaged with `self` bound to the victim and
// the attacker already stored in .dmg_inflictor (:1551).
void() AI_Damaged =
{
	entity m = self;

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
	if (dmg > 0 && m.ai_painsound && time >= m.ai_nextpain)
	{
		m.ai_nextpain = time + 1;
		entity oldpain = self;
		self = m;
		m.ai_painsound();
		self = oldpain;
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

// Called from Monster_Killed for AI classes, with self already the corpse.
void(entity m) AI_Died =
{
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

	AI_StopMoving(m);
	AI_PathClear(m);

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
	if (cls == "monster_human_grunt")		return TRUE;
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
	if (m.classname == "monster_osprey")	Osprey_ClassInit(m);
	if (m.classname == "monster_gargantua")	Gargantua_ClassInit(m);
	if (m.classname == "monster_babygarg")	Babygarg_ClassInit(m);
	if (m.classname == "monster_stukabat")	Stukabat_ClassInit(m);
	if (m.classname == "monster_kingpin")	Kingpin_ClassInit(m);
	if (m.classname == "monster_scientist")	Scientist_ClassInit(m);
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
	if (m.classname == "monster_human_grunt")	HGrunt_ClassInit(m);
	if (m.classname == "monster_human_grunt_ally")	HGruntAlly_ClassInit(m);
	if (m.classname == "monster_male_assassin")	Assassin_ClassInit(m);
	if (m.classname == "monster_hwgrunt")	HWGrunt_ClassInit(m);
	if (m.classname == "monster_robogrunt")	Robogrunt_ClassInit(m);
	if (m.classname == "monster_human_assassin")	Assassin_ClassInit(m);
	if (m.classname == "monster_shocktrooper")	Shocktrooper_ClassInit(m);
	if (m.classname == "monster_bodyguard")	Barney_ClassInit(m);
	if (m.classname == "monster_th_grunt_repel")	HGrunt_ClassInit(m);
	if (m.classname == "monster_barney")	Barney_ClassInit(m);
	if (m.classname == "monster_otis")	Barney_ClassInit(m);
	if (m.classname == "monster_human_medic_ally")	Barney_ClassInit(m);
	if (m.classname == "monster_human_torch_ally")	HGruntAlly_ClassInit(m);

	// LAST, and it overrides what the class init just installed.  Animation event
	// codes belong to the MODEL, and a classname can resolve to either of two rigs
	// depending on what is mounted - see Grunt_RigOverride (mon_grunt.qc) for the
	// male assassin, who spent 419 placements holding the wrong event table.
	Grunt_RigOverride(m);

	// ...and the bodygroup, AFTER the rig table, because the loadout it reads is
	// one of the things the rig table can change (the torch and the medic have
	// their MP5 bit cleared there).
	Grunt_BodyInit(m);
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
	// QC recycles edicts, so a latched avoidance side or a half-counted turn
	// oscillation from whatever used this slot before would carry into the new
	// monster's first steps.
	m.ai_avoidside  = 0;
	m.ai_turnticks  = 0;
	m.on_damaged    = AI_Damaged;

	AI_ClassInit(m);

	// Every ally becomes +use-able, in ONE place rather than in each of the six
	// ally class inits.  is_player_ally is the flag those inits already set, so
	// this is the whole opt-in: a class that declares itself an ally gets the
	// follow interaction for free, and a class that does not can never
	// accidentally acquire it.
	//
	// The trigger relay installed by Monster_Build is preserved and still runs for
	// non-player activators - a multi_manager naming a barney must keep passing
	// through it, and swapping .use outright is exactly how that would break.
	if (m.is_player_ally)
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
	float placed;
	if (m.ai_movemode == AIMODE_GROUND)
	{
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
		if (ai_cached_debug)
			dprint(sprintf("[ai] %s at %v could not be placed (movemode %g) - left inert\n",
			               m.classname, m.origin, m.ai_movemode));
		m.movetype = MOVETYPE_NONE;
		m.solid    = SOLID_NOT;
		m.flags    = m.flags & ~(FL_MONSTER | FL_FLY);
		return FALSE;
	}

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
// Placement is expected to FAIL for these children - they are spawned at the
// origin with no floor under them - and that is deliberate: the squad count must
// be correct whether or not a body could be stood up, because a mapper who
// places a spawner badly must still get their target chain.
float ai_squadtest_done;

void() AI_SquadSelfTest =
{
	entity oldself = self;
	float bad = 0;

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

	self = maker;
	float i;
	for (i = 0; i < 3; i = i + 1)
		squadmaker_spawn_one();
	self = oldself;

	if (maker.sq_live_children != 3)
	{
		dprint(sprintf("[ai-selftest] squad: expected 3 live children, got %g\n",
		               maker.sq_live_children));
		bad = bad + 1;
	}

	// The cap must actually hold.  This is the half that used to work.
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
		if (m.sq_owner == maker)
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
		if (m.sq_owner == maker)
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
		if (m.sq_owner == maker)
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

	ai_trace_budget = cvar("sv_ai_traces");
	if (ai_trace_budget <= 0)
		ai_trace_budget = 24;

	// Debug only, default 0.  See AI_Spawn.
	ai_cached_forcemode = cvar("sv_ai_forcemode");
};

void() AI_Tick =
{
	AI_CacheCvars();

	// Run once, on the first frame rather than from AI_Init: it spawns and
	// removes entities, and doing that inside worldspawn - while the map's own
	// entities are still being parsed - is asking for trouble.
	if (!ai_squadtest_done && cvar("sv_ai_selftest"))
	{
		ai_squadtest_done = TRUE;
		AI_SquadSelfTest();
	}

	AI_SpawnTest();
	AI_ProvokeTest();
	AI_CorpseTest();	// sv_ai_corpsetest: the corpse damage rules, measured
	AI_FireTest();		// sv_ai_firetest: does each shooter reach a player at all
	AI_WalkTest();		// sv_ai_walktest: does each walker's footstep cycle play
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

	dprint(sprintf("[ai-animtest] %-26s acts=%2g/%-3g events=%s\n",
	               cls, nact, nseq, codes));
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
		AI_SeqNameSelfTest();
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
	// Degrees of body yaw turned, and the ticks spent turning WITHOUT stepping.
	// The first must roughly double against the pre-patch build for the same
	// scene; the second must fall sharply, because monsters now walk while they
	// turn instead of standing still until they have finished.
	dprint(sprintf("[ai]   yaw: %g degrees turned, %g turn-only ticks\n",
	               ai_dbg_yawdeg, ai_dbg_mv_turning));
	dprint(sprintf("[ai]   anim events: shared=%g class=%g\n",
	               ai_dbg_ev_shared, ai_dbg_ev_class));
	// The three that were structurally zero before this patch and must not silently
	// return to zero: star = GoldSrc stream prefixes stripped off event sound names
	// (every one of which the engine refused to even look up), step = code 2003
	// footsteps, swish = code 2010 melee wind-ups.
	dprint(sprintf("[ai]   event fixes: star=%g step=%g swish=%g\n",
	               ai_dbg_ev_star, ai_dbg_ev_step, ai_dbg_ev_swish));
	// seqoverride = per-class SetActivity picks taken by NAME; missing = names the
	// rig did not carry, which fall back to the activity lottery and are the number
	// to watch on a Sven install.  The grenade split must correlate with the
	// loadout perfectly - a launch on a grunt carrying hand grenades is the exact
	// bug this replaced.
	dprint(sprintf("[ai]   seq overrides: taken=%g missing=%g  grenade: throw=%g launch=%g\n",
	               ai_dbg_seqoverride, ai_dbg_seqmissing,
	               ai_dbg_gren_throw, ai_dbg_gren_launch));
	ai_dbg_ev_shared = 0; ai_dbg_ev_class = 0;
	ai_dbg_ev_star = 0; ai_dbg_ev_step = 0; ai_dbg_ev_swish = 0;
	ai_dbg_seqoverride = 0; ai_dbg_seqmissing = 0;
	ai_dbg_gren_throw = 0; ai_dbg_gren_launch = 0;
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
};
