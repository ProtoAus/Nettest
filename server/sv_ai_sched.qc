// server/sv_ai_sched.qc
// ----------------------------------------------------------------------------
// The schedule / task virtual machine.
//
// Half-Life's AI is not a state machine that decides what to do every frame; it
// is a machine that picks a SCHEDULE — a short fixed script of tasks — and then
// runs that script to completion unless an interrupt condition fires.  That
// distinction is the whole reason HL monsters read as deliberate rather than
// twitchy: a monster that has committed to "turn to face, then leap" does not
// re-decide mid-turn just because the player stepped sideways.
//
// HL expresses a schedule as a C++ static array of Task_t literals.  QC has no
// structs and no array literals, so the same data lives in three parallel flat
// arrays plus a per-schedule (first, len, interrupt-mask) index, built once at
// boot by Sched_Begin / Sched_Task / Sched_End.  Written out, a schedule here
// reads almost exactly like HL's own table.
//
// OWNERSHIP: every array below is owned by this file.  QC forward-declares
// functions but NOT arrays, so anything that wants to read them must compile
// after this file — which sv_ai_core.qc (the interpreter) does.  Nothing that
// compiles earlier may touch them.
// ----------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// task opcodes
// ---------------------------------------------------------------------------
// Two-phase, exactly like HL: AI_TaskStart sets a task up and may complete it
// immediately; AI_TaskRun is polled each decision tick for the ones that take
// time.  Which phase a given opcode uses is documented per case in sv_ai_core.qc.
const float TASK_NONE              = 0;
const float TASK_WAIT              = 1;		// a = seconds
const float TASK_WAIT_RANDOM       = 2;		// a = min, b = max
const float TASK_WAIT_INDEFINITE   = 3;		// until an interrupt fires; never self-completes
const float TASK_SET_ACTIVITY      = 4;		// a = ACT_*, completes instantly
const float TASK_PLAY_SEQUENCE     = 5;		// a = ACT_*, completes when the sequence ends
const float TASK_SET_FAIL_SCHED    = 6;		// a = SCHED_* to run if a later task fails
const float TASK_SET_STATE         = 7;		// a = MS_*
const float TASK_CLEAR_COND        = 8;		// a = COND_* bits to drop
const float TASK_FACE_ENEMY        = 9;		// sets ideal yaw; completes when facing
const float TASK_FACE_IDEAL        = 10;	// completes when yaw reaches ai_yaw_ideal
const float TASK_TURN_RANDOM       = 11;	// a = max degrees either way
const float TASK_GET_PATH_ENEMY    = 12;	// queue a path request to the enemy
const float TASK_GET_PATH_LKP      = 13;	// ...to the last known enemy position
const float TASK_WALK_PATH         = 14;	// a = ACT_* to play while moving
const float TASK_RUN_PATH          = 15;	// a = ACT_*
const float TASK_WAIT_FOR_MOVE     = 16;	// until arrived, blocked, or path lost
const float TASK_STOP_MOVING       = 17;
const float TASK_RANGE_ATTACK1     = 18;	// play the attack; anim EVENTS do the damage
const float TASK_MELEE_ATTACK1     = 19;
const float TASK_IDLE_SOUND        = 20;	// per-class virtual
const float TASK_ALERT_SOUND       = 21;
const float TASK_DIE               = 22;
const float TASK_CHECK_ATTACK      = 23;	// refresh CAN_MELEE1 / CAN_RANGE1 right now
const float TASK_FORGET_ENEMY      = 24;
const float TASK_SET_YAWSPEED      = 25;	// a = degrees/sec
const float TASK_GET_PATH_FLEE     = 26;	// a = distance; path to a point AWAY from the enemy
// Named-sequence tasks, for models that carry NO activity tags at all - the
// turret family and the barnacle's attack.  `a` is a SEQN_* slot rather than a
// string because Sched_Task carries floats; the slot resolves through
// ai_seqname_tab below, which is filled once at boot.
const float TASK_SET_SEQ_NAMED     = 27;	// a = SEQN_*, b = looping; instant
const float TASK_PLAY_SEQ_NAMED    = 28;	// a = SEQN_*; completes when it ends
const float TASK_RANGE_ATTACK2     = 29;	// the grenade throw; anim EVENTS release it
const float TASK_GET_PATH_FOLLOW   = 30;	// path to ai_follow, the escorted player
// scripted_sequence.  These four are the whole scripted-scene vocabulary: get to
// the mark, face the way the script says, hold the idle pose until told to go,
// then play the action.  They carry no `a`/`b` because every parameter comes off
// the SCRIPT entity (m_iszIdle, m_iszPlay, its origin and its angles), which the
// monster reaches through .ai_script - a string cannot travel in a task slot.
const float TASK_GET_PATH_SCRIPT   = 31;	// path to ai_script's origin
const float TASK_FACE_SCRIPT       = 32;	// turn to ai_script's yaw
const float TASK_WAIT_FOR_SCRIPT   = 33;	// hold m_iszIdle until the script is triggered
const float TASK_PLAY_SCRIPT       = 34;	// play m_iszPlay, then release the monster
const float TASK_OP_COUNT          = 35;	// bound for the validator

// ---------------------------------------------------------------------------
// named sequence slots
// ---------------------------------------------------------------------------
// Every name here was read out of the shipped .mdl files and confirmed present
// by the boot probe (AI_SeqNameSelfTest), not inferred from the classname - the
// first guess at the barnacle's names missed all seven.
const float SEQN_IDLE_OFF = 0;
const float SEQN_DEPLOY   = 1;
const float SEQN_SPIN     = 2;
const float SEQN_FIRE     = 3;
const float SEQN_RETIRE   = 4;
const float SEQN_DIE      = 5;
const float SEQN_ATTACK1  = 6;		// barnacle: its ONLY untagged sequence
const float SEQN_COUNT    = 7;

string ai_seqname_tab[SEQN_COUNT];

string(float slot) Sched_SeqName =
{
	if (slot < 0 || slot >= SEQN_COUNT)
		return "";
	return ai_seqname_tab[slot];
};

// ---------------------------------------------------------------------------
// schedule ids
// ---------------------------------------------------------------------------
// 0 is deliberately not a schedule.  A QC field defaults to 0, so "ai_sched ==
// SCHED_NONE" is the natural state of a monster that has not been given one and
// no id-plus-one offset games are needed anywhere.
const float SCHED_NONE               = 0;
const float SCHED_IDLE_STAND         = 1;
const float SCHED_ALERT_STAND        = 2;
const float SCHED_ALERT_FACE         = 3;
const float SCHED_WAKE_ANGRY         = 4;
const float SCHED_COMBAT_FACE        = 5;
const float SCHED_CHASE_ENEMY        = 6;
const float SCHED_CHASE_ENEMY_FAILED = 7;
const float SCHED_RANGE_ATTACK1      = 8;
const float SCHED_MELEE_ATTACK1      = 9;
const float SCHED_SMALL_FLINCH       = 10;
const float SCHED_DIE                = 11;
const float SCHED_FAIL               = 12;
const float SCHED_FLEE_ENEMY         = 13;
const float SCHED_TURRET_IDLE        = 14;	// retracted, waiting
const float SCHED_TURRET_DEPLOY      = 15;	// pop up on sighting
const float SCHED_TURRET_SCAN        = 16;	// deployed, sweeping for a target
const float SCHED_TURRET_ATTACK      = 17;	// firing
const float SCHED_TURRET_RETIRE      = 18;	// nothing left to shoot: fold away
const float SCHED_BARNACLE_IDLE      = 19;	// hanging, tongue empty
const float SCHED_BARNACLE_CHOMP     = 20;	// something is in the tongue
const float SCHED_BIGMOMMA_LAYCRAB   = 21;	// the gonarch births a headcrab
const float SCHED_RANGE_ATTACK2      = 22;	// lob a grenade
const float SCHED_FOLLOW             = 23;	// an ally escorting a player
const float SCHED_SCRIPT_WALK        = 24;	// walking to a scripted_sequence's mark
const float SCHED_SCRIPT_RUN         = 25;
const float SCHED_SCRIPT_WAIT        = 26;	// at the mark, holding the idle pose
const float SCHED_SCRIPT_PLAY        = 27;	// playing the scripted action
const float SCHED_COUNT              = 28;

// ---------------------------------------------------------------------------
// storage
// ---------------------------------------------------------------------------
// TASK_MAX is the total task count across ALL schedules, not per schedule.
//
// Raised from 192/32 for the monster waves.  W3 alone adds squad, reload and
// cover schedules across thirteen classes, and W6's turrets and barnacle bring
// schedule sets that share nothing with the walking monsters.  The cost of the
// headroom is 384 * 3 floats + 64 * 4 slots of globals - a few kilobytes, paid
// once - against a table overflow whose symptom is a monster that silently stops
// mid-schedule, which is the single hardest failure in this system to recognise
// in-game.  Sched_Task already refuses rather than writing past the end, and
// AI_SchedSelfTest reports the refusal count, so an overflow is loud; it just
// should not happen at all.
const float TASK_MAX  = 384;
const float SCHED_MAX = 64;

float  task_op[TASK_MAX];
float  task_a[TASK_MAX];
float  task_b[TASK_MAX];

float  sched_first[SCHED_MAX];
float  sched_len[SCHED_MAX];
int    sched_interrupt[SCHED_MAX];
string sched_name[SCHED_MAX];		// diagnostics only — never branched on

float  sched_taskn;			// build cursor into task_*[]
float  sched_open;			// schedule id currently being built, SCHED_NONE = none
float  sched_overflow;			// tasks refused; non-zero means the table is too small
float  sched_builderr;			// builder misuse count, reported by the self-test

// ---------------------------------------------------------------------------
// builder
// ---------------------------------------------------------------------------
// Runs once, at worldspawn, before any monster exists.  It is deliberately noisy
// on misuse: a silently truncated schedule is a monster that stops mid-attack
// forever, and that is very hard to recognise as a table-overflow bug when you
// meet it in-game months later.
void(float id, string nm, int interrupts) Sched_Begin =
{
	if (sched_open != SCHED_NONE)
	{
		dprint(sprintf("[ai] Sched_Begin(%s) while %s is still open\n", nm, sched_name[sched_open]));
		sched_builderr = sched_builderr + 1;
	}
	if (id <= SCHED_NONE || id >= SCHED_MAX)
	{
		dprint(sprintf("[ai] Sched_Begin: id %g out of range for \"%s\"\n", id, nm));
		sched_builderr = sched_builderr + 1;
		sched_open = SCHED_NONE;
		return;
	}
	if (sched_len[id] != 0)
	{
		dprint(sprintf("[ai] Sched_Begin: id %g (\"%s\") already built as \"%s\"\n",
		               id, nm, sched_name[id]));
		sched_builderr = sched_builderr + 1;
	}

	sched_open            = id;
	sched_name[id]        = nm;
	sched_first[id]       = sched_taskn;
	sched_len[id]         = 0;
	sched_interrupt[id]   = interrupts;
};

void(float op, float a, float b) Sched_Task =
{
	if (sched_open == SCHED_NONE)
	{
		dprint("[ai] Sched_Task outside Sched_Begin/End\n");
		sched_builderr = sched_builderr + 1;
		return;
	}
	if (sched_taskn >= TASK_MAX)
	{
		// Refuse rather than write past the array: an out-of-range global array
		// write is an engine boundcheck SV_Error, i.e. the server dies at map load.
		sched_overflow = sched_overflow + 1;
		return;
	}
	task_op[sched_taskn] = op;
	task_a[sched_taskn]  = a;
	task_b[sched_taskn]  = b;
	sched_taskn          = sched_taskn + 1;
	sched_len[sched_open] = sched_len[sched_open] + 1;
};

void() Sched_End =
{
	if (sched_open == SCHED_NONE)
	{
		dprint("[ai] Sched_End with nothing open\n");
		sched_builderr = sched_builderr + 1;
		return;
	}
	if (sched_len[sched_open] <= 0)
	{
		// An empty schedule completes on the tick it starts and the monster
		// immediately re-selects — which, if selection returns the same empty
		// schedule, is an infinite loop inside one frame.
		dprint(sprintf("[ai] schedule \"%s\" is empty\n", sched_name[sched_open]));
		sched_builderr = sched_builderr + 1;
	}
	sched_open = SCHED_NONE;
};

// Bounds-checked accessors.  The interpreter could index the arrays directly
// (it compiles after this file) but every read there is driven by a per-entity
// cursor, and a corrupt cursor must degrade rather than SV_Error the server.
float(float sched, float idx) Sched_Op =
{
	if (sched <= SCHED_NONE)	return TASK_NONE;
	if (sched >= SCHED_MAX)		return TASK_NONE;
	if (idx < 0)			return TASK_NONE;
	if (idx >= sched_len[sched])	return TASK_NONE;
	float t = sched_first[sched] + idx;
	if (t < 0 || t >= TASK_MAX)	return TASK_NONE;
	return task_op[t];
};

float(float sched, float idx) Sched_A =
{
	if (sched <= SCHED_NONE)	return 0;
	if (sched >= SCHED_MAX)		return 0;
	if (idx < 0)			return 0;
	if (idx >= sched_len[sched])	return 0;
	float t = sched_first[sched] + idx;
	if (t < 0 || t >= TASK_MAX)	return 0;
	return task_a[t];
};

float(float sched, float idx) Sched_B =
{
	if (sched <= SCHED_NONE)	return 0;
	if (sched >= SCHED_MAX)		return 0;
	if (idx < 0)			return 0;
	if (idx >= sched_len[sched])	return 0;
	float t = sched_first[sched] + idx;
	if (t < 0 || t >= TASK_MAX)	return 0;
	return task_b[t];
};

float(float sched) Sched_Len =
{
	if (sched <= SCHED_NONE)	return 0;
	if (sched >= SCHED_MAX)		return 0;
	return sched_len[sched];
};

int(float sched) Sched_Interrupts =
{
	if (sched <= SCHED_NONE)	return 0;
	if (sched >= SCHED_MAX)		return 0;
	return sched_interrupt[sched];
};

string(float sched) Sched_Name =
{
	if (sched <= SCHED_NONE)	return "none";
	if (sched >= SCHED_MAX)		return "?";
	if (!sched_name[sched])		return "?";
	return sched_name[sched];
};

// Does this schedule contain a task that requires the monster to travel?
float(float sched) Sched_HasMovement =
{
	float j, n = Sched_Len(sched);
	for (j = 0; j < n; j = j + 1)
	{
		float op = Sched_Op(sched, j);
		if (op == TASK_GET_PATH_ENEMY || op == TASK_GET_PATH_LKP
		 || op == TASK_GET_PATH_FLEE  || op == TASK_WALK_PATH
		 || op == TASK_RUN_PATH       || op == TASK_WAIT_FOR_MOVE
		 || op == TASK_GET_PATH_FOLLOW || op == TASK_GET_PATH_SCRIPT)
			return TRUE;
	}
	return FALSE;
};

// Does this opcode take time, i.e. does the schedule stop advancing at it and
// start being exposed to its own interrupt mask?  Everything else completes
// inside AI_TaskStart and runs as part of the instant chain on entry.
float(float op) Sched_TaskBlocks =
{
	if (op == TASK_WAIT)			return TRUE;
	if (op == TASK_WAIT_RANDOM)		return TRUE;
	if (op == TASK_WAIT_INDEFINITE)		return TRUE;
	if (op == TASK_PLAY_SEQUENCE)		return TRUE;
	if (op == TASK_FACE_ENEMY)		return TRUE;
	if (op == TASK_FACE_IDEAL)		return TRUE;
	if (op == TASK_GET_PATH_ENEMY)		return TRUE;
	if (op == TASK_GET_PATH_LKP)		return TRUE;
	if (op == TASK_GET_PATH_FLEE)		return TRUE;
	// TASK_GET_PATH_FOLLOW is deliberately absent: it completes instantly and never
	// waits on the nav queue.  See its case in AI_TaskStart.
	if (op == TASK_WAIT_FOR_MOVE)		return TRUE;
	if (op == TASK_RANGE_ATTACK1)		return TRUE;
	if (op == TASK_RANGE_ATTACK2)		return TRUE;
	if (op == TASK_MELEE_ATTACK1)		return TRUE;
	if (op == TASK_PLAY_SEQ_NAMED)		return TRUE;
	// TASK_GET_PATH_SCRIPT is absent for the same reason TASK_GET_PATH_FOLLOW is:
	// it completes inside AI_TaskStart and never waits on the nav queue.
	if (op == TASK_FACE_SCRIPT)		return TRUE;
	if (op == TASK_WAIT_FOR_SCRIPT)		return TRUE;
	if (op == TASK_PLAY_SCRIPT)		return TRUE;
	return FALSE;
};

// The schedules AI_SelectSchedule's generic ladder can hand a monster with no
// locomotion at all.  Kept as an explicit list rather than derived from the
// selector, because the whole point is to fail loudly the day someone adds a
// movement task to one of these without noticing that a turret runs it too.
float(float sched) Sched_StaticReachable =
{
	if (sched == SCHED_IDLE_STAND)		return TRUE;
	if (sched == SCHED_ALERT_STAND)		return TRUE;
	if (sched == SCHED_ALERT_FACE)		return TRUE;
	if (sched == SCHED_WAKE_ANGRY)		return TRUE;
	if (sched == SCHED_COMBAT_FACE)		return TRUE;
	if (sched == SCHED_RANGE_ATTACK1)	return TRUE;
	if (sched == SCHED_MELEE_ATTACK1)	return TRUE;
	if (sched == SCHED_SMALL_FLINCH)	return TRUE;
	if (sched == SCHED_DIE)			return TRUE;
	if (sched == SCHED_FAIL)		return TRUE;
	if (sched == SCHED_TURRET_IDLE)		return TRUE;
	if (sched == SCHED_TURRET_DEPLOY)	return TRUE;
	if (sched == SCHED_TURRET_SCAN)		return TRUE;
	if (sched == SCHED_TURRET_ATTACK)	return TRUE;
	if (sched == SCHED_TURRET_RETIRE)	return TRUE;
	if (sched == SCHED_BARNACLE_IDLE)	return TRUE;
	if (sched == SCHED_BARNACLE_CHOMP)	return TRUE;
	// A scripted_sequence can name ANY monster, including a bolted-down one - Sven
	// maps pose turrets and barnacles for set dressing.  Script_Schedule demotes a
	// STATIC monster's walk/run to the standing pair rather than handing it a move
	// it cannot make, so these two are reachable and must stay movement-free.
	if (sched == SCHED_SCRIPT_WAIT)		return TRUE;
	if (sched == SCHED_SCRIPT_PLAY)		return TRUE;
	return FALSE;
};

// ---------------------------------------------------------------------------
// the schedules
// ---------------------------------------------------------------------------
// Interrupt masks are the important half of each entry and are the part most
// worth reading.  A mask that is too wide makes a monster abandon its attack the
// instant it is grazed; too narrow and it keeps walking into a wall after its
// path has been invalidated.  Half-Life's own masks are the starting point.
void() AI_SchedBuildAll =
{
	float i;

	sched_taskn    = 0;
	sched_open     = SCHED_NONE;
	sched_overflow = 0;
	sched_builderr = 0;
	for (i = 0; i < SCHED_MAX; i = i + 1)
	{
		sched_first[i]     = 0;
		sched_len[i]       = 0;
		sched_interrupt[i] = 0;
		sched_name[i]      = "";
	}

	// --- idle -------------------------------------------------------------
	// The dormant case.  Anything at all that happens should pull the monster
	// out of it, so the mask is wide on purpose.
	Sched_Begin(SCHED_IDLE_STAND, "idle_stand",
	            COND_SEE_ENEMY | COND_HEAR_SOUND | COND_DAMAGE | COND_PROVOKED);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_STATE,      MS_IDLE, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_WAIT_RANDOM,    2, 6);
		Sched_Task(TASK_IDLE_SOUND,     0, 0);
	Sched_End();

	// --- alert ------------------------------------------------------------
	// Awake, no enemy located.  Turning in place is what makes a disturbed but
	// un-sighted HL monster look like it is searching rather than idling.
	// COND_PROVOKED is NOT in this mask, and that omission is the point.  It is
	// Half-Life's persistent MEMORY flag ("this monster now hates you"), not an
	// event, and nothing ever clears it - so leaving it here interrupted the
	// schedule on its first tick every tick, forever.  Measured as 707 alert_stand
	// selections from six barneys in 50 seconds, all carrying cond=4096.
	// It stays in idle_stand's mask, where waking a dormant monster is the whole
	// job; an already-alert monster has nothing further to do about it.
	Sched_Begin(SCHED_ALERT_STAND, "alert_stand",
	            COND_SEE_ENEMY | COND_DAMAGE);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_STATE,      MS_ALERT, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_WAIT_RANDOM,    1, 3);
		Sched_Task(TASK_TURN_RANDOM,    90, 0);
		Sched_Task(TASK_FACE_IDEAL,     0, 0);
		Sched_Task(TASK_WAIT_RANDOM,    1, 3);
	Sched_End();

	// Heard something: turn toward where it came from and look.
	// The clear leads, for the reason documented on SCHED_FAIL: COND_HEAR_SOUND is
	// what selected this schedule, and leaving it set behind a blocking turn means
	// an interrupted monster re-selects alert_face on the very next tick and turns
	// toward the same stale noise forever.
	Sched_Begin(SCHED_ALERT_FACE, "alert_face",
	            COND_SEE_ENEMY | COND_DAMAGE);
		Sched_Task(TASK_CLEAR_COND,     COND_HEAR_SOUND, 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_STATE,      MS_ALERT, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_FACE_IDEAL,     0, 0);
		Sched_Task(TASK_WAIT,           1, 0);
	Sched_End();

	// First sight of an enemy.  Deliberately NOT interruptible by seeing that
	// same enemy again, or the monster would restart this every tick and never
	// finish its alert sound.
	Sched_Begin(SCHED_WAKE_ANGRY, "wake_angry",
	            COND_HEAVY_DAMAGE);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_STATE,      MS_COMBAT, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_ALERT_SOUND,    0, 0);
		Sched_Task(TASK_FACE_ENEMY,     0, 0);
	Sched_End();

	// In combat, enemy not currently attackable and not worth chasing yet.
	Sched_Begin(SCHED_COMBAT_FACE, "combat_face",
	            COND_ATTACK_READY | COND_ENEMY_DEAD | COND_HEAVY_DAMAGE);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_FACE_ENEMY,     0, 0);
		Sched_Task(TASK_CHECK_ATTACK,   0, 0);
		Sched_Task(TASK_WAIT,           0.5, 0);
	Sched_End();

	// --- chase ------------------------------------------------------------
	// COND_ATTACK_READY in the mask is what stops the monster from walking all
	// the way to its goal node before noticing it could already strike.
	// TASK_FAILED is in the mask so a path that dies mid-walk drops straight to
	// the fail schedule instead of the monster running the remaining tasks
	// against a path it no longer has.
	Sched_Begin(SCHED_CHASE_ENEMY, "chase_enemy",
	            COND_ATTACK_READY | COND_ENEMY_DEAD | COND_HEAVY_DAMAGE
	          | COND_TASK_FAILED | COND_NO_PATH);
		Sched_Task(TASK_SET_FAIL_SCHED, SCHED_CHASE_ENEMY_FAILED, 0);
		Sched_Task(TASK_SET_STATE,      MS_COMBAT, 0);
		Sched_Task(TASK_GET_PATH_ENEMY, 0, 0);
		Sched_Task(TASK_RUN_PATH,       ACT_RUN, 0);
		Sched_Task(TASK_WAIT_FOR_MOVE,  0, 0);
		Sched_Task(TASK_FACE_ENEMY,     0, 0);
	Sched_End();

	// No route exists.  Standing still for a moment rather than retrying every
	// tick is the entire point: an unreachable enemy otherwise costs a path
	// search per monster per tick, which is what the request budget exists to
	// prevent in the first place.
	// Same ordering rule as SCHED_FAIL below, and for the same reason: this mask
	// contains three conditions that routinely fire on the first tick, and
	// TASK_FACE_ENEMY blocks until the turn completes.  A clear placed after it
	// would rarely run at all.
	Sched_Begin(SCHED_CHASE_ENEMY_FAILED, "chase_failed",
	            COND_ATTACK_READY | COND_ENEMY_DEAD | COND_HEAVY_DAMAGE);
		Sched_Task(TASK_CLEAR_COND,     COND_NO_PATH | COND_TASK_FAILED, 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_FACE_ENEMY,     0, 0);
		Sched_Task(TASK_WAIT,           1, 0);
	Sched_End();

	// --- attacks ----------------------------------------------------------
	// Light damage is NOT an interrupt here.  A headcrab that aborts its leap
	// because a pistol round clipped it mid-air would be both wrong and, worse,
	// unkillable-looking: it would flinch-loop under sustained fire and never
	// close.  Heavy damage still interrupts.
	// Both attacks clear their own opportunity condition FIRST.  Behind
	// TASK_FACE_ENEMY it was skipped whenever heavy damage landed during the turn,
	// leaving COND_CAN_RANGE1 set so the monster re-selected the attack it had just
	// abandoned.  Clearing on entry is also the more honest reading: the schedule
	// has consumed the opportunity the moment it commits to it.
	//
	// Re-arming during the turn is not a problem.  AI_GatherConditions may set the
	// bit again while TASK_FACE_ENEMY blocks, but neither mask below contains it,
	// so it cannot interrupt - and once the attack task runs, the per-class
	// ai_nextattack cooldown keeps it clear.
	Sched_Begin(SCHED_RANGE_ATTACK1, "range_attack1",
	            COND_ENEMY_DEAD | COND_HEAVY_DAMAGE);
		Sched_Task(TASK_CLEAR_COND,     COND_CAN_RANGE1, 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_FACE_ENEMY,     0, 0);
		Sched_Task(TASK_RANGE_ATTACK1,  0, 0);
	Sched_End();

	Sched_Begin(SCHED_MELEE_ATTACK1, "melee_attack1",
	            COND_ENEMY_DEAD | COND_HEAVY_DAMAGE);
		Sched_Task(TASK_CLEAR_COND,     COND_CAN_MELEE1, 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_FACE_ENEMY,     0, 0);
		Sched_Task(TASK_MELEE_ATTACK1,  0, 0);
	Sched_End();

	// --- reactions --------------------------------------------------------
	// Zero interrupts, both of them: a flinch or a death animation that can be
	// cut short is a monster that visibly teleports between poses.
	Sched_Begin(SCHED_SMALL_FLINCH, "small_flinch", 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_CLEAR_COND,     COND_DAMAGE, 0);
		Sched_Task(TASK_PLAY_SEQUENCE,  ACT_SMALL_FLINCH, 0);
	Sched_End();

	Sched_Begin(SCHED_DIE, "die", 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_STATE,      MS_DEAD, 0);
		Sched_Task(TASK_PLAY_SEQUENCE,  ACT_DIESIMPLE, 0);
		Sched_Task(TASK_DIE,            0, 0);
	Sched_End();

	// --- flight -----------------------------------------------------------
	// For classes that have no attack at all.  Without this the generic ladder
	// hands them SCHED_CHASE_ENEMY - a cockroach would sprint AT the player,
	// which is both wrong and unmistakably a bug to anyone watching.
	//
	// Not interruptible by seeing the enemy again: that is the condition that
	// started the flight, and re-selecting on it every tick would restart the
	// schedule before the monster covered any ground.  This is the same failure
	// the chase schedule had in B2.
	Sched_Begin(SCHED_FLEE_ENEMY, "flee_enemy",
	            COND_ENEMY_DEAD | COND_TASK_FAILED | COND_NO_PATH);
		Sched_Task(TASK_STOP_MOVING,     0, 0);
		Sched_Task(TASK_SET_STATE,       MS_ALERT, 0);
		Sched_Task(TASK_GET_PATH_FLEE,   400, 0);
		Sched_Task(TASK_RUN_PATH,        ACT_RUN, 0);
		Sched_Task(TASK_WAIT_FOR_MOVE,   0, 0);
		Sched_Task(TASK_FORGET_ENEMY,    0, 0);
	Sched_End();

	// --- turrets -----------------------------------------------------------
	// sentry.mdl / miniturret.mdl / turret.mdl have NO activities: every one of
	// their six sequences is act 0, so frameforaction cannot reach any of them and
	// these schedules drive them entirely by name.
	//
	// None of them contains a movement task, which AI_SchedSelfTest now asserts -
	// a turret is AIMODE_STATIC and cannot satisfy one.
	ai_seqname_tab[SEQN_IDLE_OFF] = "idle_off";
	ai_seqname_tab[SEQN_DEPLOY]   = "deploy";
	ai_seqname_tab[SEQN_SPIN]     = "spin";
	ai_seqname_tab[SEQN_FIRE]     = "fire";
	ai_seqname_tab[SEQN_RETIRE]   = "retire";
	ai_seqname_tab[SEQN_DIE]      = "die";
	ai_seqname_tab[SEQN_ATTACK1]  = "attack1";

	Sched_Begin(SCHED_TURRET_IDLE, "turret_idle",
	            COND_SEE_ENEMY | COND_DAMAGE | COND_PROVOKED);
		Sched_Task(TASK_SET_STATE,        MS_IDLE, 0);
		Sched_Task(TASK_SET_SEQ_NAMED,    SEQN_IDLE_OFF, 0);
		Sched_Task(TASK_WAIT_INDEFINITE,  0, 0);
	Sched_End();

	// Deploying is deliberately NOT interruptible: a turret that re-triggers its
	// pop-up every tick while the player strafes never finishes deploying and so
	// never shoots.  Same failure the chase schedule had in B2.
	Sched_Begin(SCHED_TURRET_DEPLOY, "turret_deploy", 0);
		Sched_Task(TASK_SET_STATE,        MS_ALERT, 0);
		Sched_Task(TASK_PLAY_SEQ_NAMED,   SEQN_DEPLOY, 0);
	Sched_End();

	Sched_Begin(SCHED_TURRET_SCAN, "turret_scan",
	            COND_ATTACK_READY | COND_SEE_ENEMY);
		Sched_Task(TASK_SET_SEQ_NAMED,    SEQN_SPIN, 1);
		Sched_Task(TASK_WAIT,             3, 0);
	Sched_End();

	// The FIRE sequence loops and carries EVENT_MUZZLEFLASH events; each one fires
	// a round, so the model's own timing drives the rate.  The schedule just holds
	// it there and re-faces between bursts.
	Sched_Begin(SCHED_TURRET_ATTACK, "turret_attack",
	            COND_ENEMY_DEAD | COND_ENEMY_OCCLUDED | COND_ENEMY_TOOFAR);
		Sched_Task(TASK_CLEAR_COND,       COND_CAN_RANGE1, 0);
		Sched_Task(TASK_FACE_ENEMY,       0, 0);
		Sched_Task(TASK_SET_SEQ_NAMED,    SEQN_FIRE, 1);
		Sched_Task(TASK_WAIT,             1, 0);
	Sched_End();

	Sched_Begin(SCHED_TURRET_RETIRE, "turret_retire",
	            COND_SEE_ENEMY);
		Sched_Task(TASK_PLAY_SEQ_NAMED,   SEQN_RETIRE, 0);
		Sched_Task(TASK_SET_STATE,        MS_IDLE, 0);
	Sched_End();

	// --- barnacle ----------------------------------------------------------
	// Its idle sequences ARE tagged (act 1), so this needs no name; only the
	// chomp does, because attack1 is the one untagged sequence in the model.
	//
	// Neither is interruptible by damage: a barnacle that flinches out of its
	// chew every time the victim shoots it would let go, and letting go is not a
	// thing a barnacle does.
	// Interrupts on COND_SEE_ENEMY, which Barnacle_Tick asserts the moment
	// something enters the tongue column.  With a zero mask this schedule ran its
	// full second before re-selecting, so the chew animation almost never played
	// even while the tongue was landing damage - measured as 3 hits with 0 chomp
	// selections.  The damage was always correct; only the animation lagged.
	Sched_Begin(SCHED_BARNACLE_IDLE, "barnacle_idle", COND_SEE_ENEMY);
		Sched_Task(TASK_SET_STATE,        MS_IDLE, 0);
		Sched_Task(TASK_SET_ACTIVITY,     ACT_IDLE, 0);
		Sched_Task(TASK_WAIT,             1, 0);
	Sched_End();

	Sched_Begin(SCHED_BARNACLE_CHOMP, "barnacle_chomp", 0);
		Sched_Task(TASK_SET_STATE,        MS_COMBAT, 0);
		Sched_Task(TASK_SET_SEQ_NAMED,    SEQN_ATTACK1, 1);
		Sched_Task(TASK_WAIT,             0.5, 0);
	Sched_End();

	// --- bigmomma ----------------------------------------------------------
	// The gonarch's birth animation, and the only reason this schedule exists as
	// its own entry rather than as a class case inside melee_attack1: it plays
	// ACT_MELEE_ATTACK2, and NOTHING in the generic ladder ever selects that
	// activity.  Her spawn sequence carries the LAY_CRAB event, so an activity
	// the ladder cannot reach meant the boss's defining behaviour - she is a
	// spawner, not a big melee monster - simply never happened.  It was wired,
	// event-correct, and unreachable.
	//
	// ZERO INTERRUPT MASK, for the same reason the flinch and death schedules
	// have one: the crab appears on an animation EVENT 0.4 of the way through.
	// A mask that let damage cut the birth short would mean she births nothing
	// whenever the player is actually shooting her, which is always.
	Sched_Begin(SCHED_BIGMOMMA_LAYCRAB, "bigmomma_laycrab", 0);
		Sched_Task(TASK_STOP_MOVING,      0, 0);
		Sched_Task(TASK_FACE_ENEMY,       0, 0);
		Sched_Task(TASK_PLAY_SEQUENCE,    ACT_MELEE_ATTACK2, 0);
	Sched_End();

	// --- the grenade throw --------------------------------------------------
	// ZERO INTERRUPT MASK, and this one is not a style choice.  The grenade
	// leaves the hand on an anim event roughly half a second in; a throw cut
	// short by incoming fire means the grunt has committed to the animation,
	// been interrupted, and NOT released the grenade - so the toss velocity
	// solved for a position the enemy has long since left is simply discarded.
	// Worse, the arc was already validated as safe when the schedule was
	// selected.  Re-entering it later from a different position with the old
	// velocity is how a grunt kills its own squad.
	Sched_Begin(SCHED_RANGE_ATTACK2, "range_attack2", 0);
		Sched_Task(TASK_STOP_MOVING,      0, 0);
		Sched_Task(TASK_FACE_ENEMY,       0, 0);
		Sched_Task(TASK_RANGE_ATTACK2,    0, 0);
	Sched_End();

	// --- following ----------------------------------------------------------
	// An ally catching up with the player who asked it to come along.
	//
	// COND_SEE_ENEMY is in the mask so a follower that walks into a fight stops
	// walking and fights: without it the ally would trot obediently past the
	// thing shooting at it, because a schedule is only re-selected when the
	// current one ends and a long walk does not end quickly.
	//
	// The RUN activity, not walk.  HL's allies jog to catch up, and a follower
	// that moves slower than the player can never actually arrive - it would
	// spend the whole map re-pathing to a position it has already lost.
	Sched_Begin(SCHED_FOLLOW, "follow",
	            COND_SEE_ENEMY | COND_HEAVY_DAMAGE);
		Sched_Task(TASK_GET_PATH_FOLLOW,  0, 0);
		Sched_Task(TASK_RUN_PATH,         ACT_RUN, 0);
		Sched_Task(TASK_WAIT_FOR_MOVE,    0, 0);
	Sched_End();

	// --- scripted sequences -------------------------------------------------
	// The four states a possessed monster can be in.  ALL FOUR HAVE A ZERO
	// INTERRUPT MASK, and that is the defining property of a scripted scene: a
	// scientist walking his pondering loop past a headcrab must not break off to
	// flee, because the map author decided what happens here and the AI did not.
	//
	// Nothing is lost by the zero mask, because the gate in AI_SelectSchedule
	// re-selects from .ai_scriptstate anyway - the schedule cannot drift.  The only
	// way out is through the script itself (Script_Release), which is what damage,
	// death and completion all funnel into.
	//
	// The walk pair is deliberately a full STOP_MOVING / path / move / face chain
	// rather than reusing the chase schedules: a script mark is a fixed point in
	// the world with a fixed facing, and arriving at roughly the right place while
	// looking the wrong way is exactly the failure that makes a posed scene read
	// as broken.
	Sched_Begin(SCHED_SCRIPT_WALK, "script_walk", 0);
		Sched_Task(TASK_SET_STATE,        MS_SCRIPT, 0);
		Sched_Task(TASK_STOP_MOVING,      0, 0);
		Sched_Task(TASK_GET_PATH_SCRIPT,  0, 0);
		Sched_Task(TASK_WALK_PATH,        ACT_WALK, 0);
		Sched_Task(TASK_WAIT_FOR_MOVE,    0, 0);
		Sched_Task(TASK_FACE_SCRIPT,      0, 0);
	Sched_End();

	Sched_Begin(SCHED_SCRIPT_RUN, "script_run", 0);
		Sched_Task(TASK_SET_STATE,        MS_SCRIPT, 0);
		Sched_Task(TASK_STOP_MOVING,      0, 0);
		Sched_Task(TASK_GET_PATH_SCRIPT,  0, 0);
		Sched_Task(TASK_RUN_PATH,         ACT_RUN, 0);
		Sched_Task(TASK_WAIT_FOR_MOVE,    0, 0);
		Sched_Task(TASK_FACE_SCRIPT,      0, 0);
	Sched_End();

	// Holding the pose.  TASK_WAIT_FOR_SCRIPT never self-completes until the script
	// says go, which is why this is the state the opening of Half-Life spends its
	// whole time in - barney sits at that desk until the player walks past the
	// trigger that fires his script, and that may be never.
	Sched_Begin(SCHED_SCRIPT_WAIT, "script_wait", 0);
		Sched_Task(TASK_SET_STATE,        MS_SCRIPT, 0);
		Sched_Task(TASK_STOP_MOVING,      0, 0);
		Sched_Task(TASK_WAIT_FOR_SCRIPT,  0, 0);
	Sched_End();

	Sched_Begin(SCHED_SCRIPT_PLAY, "script_play", 0);
		Sched_Task(TASK_SET_STATE,        MS_SCRIPT, 0);
		Sched_Task(TASK_STOP_MOVING,      0, 0);
		Sched_Task(TASK_PLAY_SCRIPT,      0, 0);
	Sched_End();

	// The universal fallback.  Every path into it has already failed at
	// something, so it must not itself be able to fail.
	//
	// TASK_CLEAR_COND COMES FIRST, and that ordering is the whole schedule.  It
	// used to sit last, behind the wait, and the result was measured as 71 "fail"
	// selections from eight zombies in forty seconds: the interrupt mask below
	// contains COND_ENEMY_DEAD, an enemy dying set it, the schedule was interrupted
	// on its very next tick, and the clear it exists to perform never ran.  So
	// COND_TASK_FAILED survived, and the monster came straight back here.
	//
	// Instant tasks at the head of a schedule all run in the tick that starts it,
	// before any interrupt is tested, so anything that MUST happen has to be in
	// front of the first blocking task.  That is a general rule for this table,
	// not a detail of this schedule.
	Sched_Begin(SCHED_FAIL, "fail",
	            COND_ENEMY_DEAD | COND_HEAVY_DAMAGE);
		Sched_Task(TASK_CLEAR_COND,     COND_TASK_FAILED | COND_NO_PATH | COND_BLOCKED, 0);
		Sched_Task(TASK_STOP_MOVING,    0, 0);
		Sched_Task(TASK_SET_ACTIVITY,   ACT_IDLE, 0);
		Sched_Task(TASK_WAIT,           1, 0);
	Sched_End();
};

// ---------------------------------------------------------------------------
// self-test  —  `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// Validates the table itself, not the AI.  Everything it checks is a mistake
// that produces a monster which silently stops behaving rather than an error:
// an unbuilt schedule id, a task that runs off the end of its own schedule, an
// opcode the interpreter has no case for, or a fail-schedule pointing at a
// schedule that was never built.
//
// Lives in sv_ai_core.qc, which compiles after this file and owns the task
// interpreter.  Forward-declared rather than moved because the interpreter is
// the only thing that actually knows which opcodes it implements, and the whole
// value of the check is that the two live next to each other.
float(float op) AI_TaskOpHandled;
void() AI_SchedSelfTest =
{
	float i, j, bad = 0;

	if (sched_open != SCHED_NONE)
	{
		dprint(sprintf("[ai-selftest] schedule \"%s\" was never closed\n", Sched_Name(sched_open)));
		bad = bad + 1;
	}
	if (sched_overflow)
	{
		dprint(sprintf("[ai-selftest] TASK_MAX (%g) overflowed: %g tasks refused\n",
		               TASK_MAX, sched_overflow));
		bad = bad + 1;
	}
	if (sched_builderr)
	{
		dprint(sprintf("[ai-selftest] %g builder error(s) reported above\n", sched_builderr));
		bad = bad + 1;
	}

	for (i = 1; i < SCHED_COUNT; i = i + 1)
	{
		if (sched_len[i] <= 0)
		{
			dprint(sprintf("[ai-selftest] schedule id %g was never built\n", i));
			bad = bad + 1;
			continue;
		}
		if (sched_first[i] + sched_len[i] > sched_taskn)
		{
			dprint(sprintf("[ai-selftest] \"%s\" runs past the end of the task table\n",
			               Sched_Name(i)));
			bad = bad + 1;
			continue;
		}

		for (j = 0; j < sched_len[i]; j = j + 1)
		{
			float op = Sched_Op(i, j);
			if (op <= TASK_NONE || op >= TASK_OP_COUNT)
			{
				dprint(sprintf("[ai-selftest] \"%s\" task %g: unknown opcode %g\n",
				               Sched_Name(i), j, op));
				bad = bad + 1;
			}
			else if (!AI_TaskOpHandled(op))
			{
				// Declared in the opcode list and used in a schedule, but the
				// interpreter has no case for it.  AI_TaskStart's fallback treats an
				// unknown opcode as an instant no-op, so the schedule does not wedge
				// - it just quietly skips the step.  A monster that never reloads,
				// or attacks without ever dealing damage, is the result, and nothing
				// about it looks like a missing case.  This is the check that turns
				// "I added the opcode but not its handler" into a boot-time line.
				dprint(sprintf("[ai-selftest] \"%s\" task %g: opcode %g has no interpreter case\n",
				               Sched_Name(i), j, op));
				bad = bad + 1;
			}
			if (op == TASK_SET_FAIL_SCHED)
			{
				float fs = Sched_A(i, j);
				if (fs <= SCHED_NONE || fs >= SCHED_MAX || sched_len[fs] <= 0)
				{
					dprint(sprintf("[ai-selftest] \"%s\" task %g: fail-schedule %g does not exist\n",
					               Sched_Name(i), j, fs));
					bad = bad + 1;
				}
			}
		}

		// A TASK_CLEAR_COND behind a blocking task, in a schedule that can be
		// interrupted, may never run at all - the interrupt fires while the
		// schedule is parked on the blocking task and the clear is simply skipped.
		// Whatever condition it was meant to drop then persists, and the monster
		// comes straight back to the same schedule.  This is not hypothetical: it
		// was SCHED_FAIL's behaviour, worth 71 re-entries from eight zombies in
		// forty seconds, and it took a schedule histogram to notice.  A clear that
		// matters belongs in front of the first blocking task.
		if (Sched_Interrupts(i))
		{
			float blocked_at = -1;
			for (j = 0; j < sched_len[i]; j = j + 1)
			{
				float op2 = Sched_Op(i, j);
				if (blocked_at < 0 && Sched_TaskBlocks(op2))
					blocked_at = j;
				else if (op2 == TASK_CLEAR_COND && blocked_at >= 0)
				{
					dprint(sprintf("[ai-selftest] \"%s\" task %g: TASK_CLEAR_COND sits behind blocking task %g - an interrupt can skip it\n",
					               Sched_Name(i), j, blocked_at));
					bad = bad + 1;
				}
			}
		}

		// A monster with AIMODE_STATIC has no locomotion whatsoever.  Handing it a
		// schedule that waits for a move it can never make is a silent lockup, not
		// an error, so assert the shape here rather than discovering it as a turret
		// that stops responding.
		if (Sched_StaticReachable(i) && Sched_HasMovement(i))
		{
			dprint(sprintf("[ai-selftest] \"%s\" has a movement task but a STATIC monster can reach it\n",
			               Sched_Name(i)));
			bad = bad + 1;
		}
	}

	dprint(sprintf("[ai-selftest] schedules: %g built, %g/%g tasks used, BAD=%g\n",
	               SCHED_COUNT - 1, sched_taskn, TASK_MAX, bad));
};
