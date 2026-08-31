// server/sv_ai_anim.qc
// ----------------------------------------------------------------------------
// Activity -> sequence resolution, and the animation event pump.
//
// HOW HL MODELS ANIMATE HERE, measured from the engine rather than assumed:
//
//   .frame is the SEQUENCE INDEX, not a frame number.  HLMDL_GetBoneData_Internal
//   (gl/gl_hlmdl.c:1375) passes it straight to HL_SetupBones as `seqnum`, and
//   HL_SetupBones derives the actual frame as (frametime * sequence->timing),
//   wrapping on sequence->numframes for looping sequences.
//
//   The playback CLOCK is not sent.  .frame1time is a CSQC-only field - it does
//   not appear anywhere in sv_ents.c.  For a normal networked entity the client
//   derives it itself, in CL_LerpNetFrameState (client/cl_ents.c:4235):
//
//       fs->g[n].frametime[0] = cl.servertime - le->newframestarttime[n];
//
//   ...where newframestarttime is stamped whenever .frame CHANGES.  So the
//   server's whole job is to write the right sequence index; the client plays it
//   from the start, in real time, and loops it if the sequence loops.  Setting
//   frame1time server-side would accomplish nothing at all.
//
//   The one consequence worth knowing: assigning the SAME sequence index again
//   does not restart playback, because the client only re-stamps on a change
//   (cl_ents.c:4260, `if (force || frame != le->newframe[fst])`).  AI_SetActivity
//   re-rolls once to dodge that where the activity has several variants - which
//   is exactly the case that matters, the headcrab's three jump variants.  A
//   single-variant one-shot replayed back-to-back will continue rather than
//   restart visually.  Gameplay is unaffected either way: every timing decision
//   below runs off the SERVER's own clock (ai_seqstart / ai_seqend), never off
//   what the client is drawing.
//
//   frameforaction re-rolls its weighted random on EVERY call
//   (HLMDL_FrameForAction, gl/gl_hlmdl.c:846).  Calling it per frame would
//   reshuffle the animation continuously, so it is called once per activity
//   change and the result cached in .ai_seq.
// ----------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// which activities loop
// ---------------------------------------------------------------------------
// The engine knows (hlmdl_sequencelist_t.loop) but does not expose it: the only
// sequence metadata builtins are frameforname / frameforaction / frameduration /
// modelframecount, and none of them report the loop flag.  So the decision is
// made by ACTIVITY, which is how the schedule layer thinks about it anyway - a
// walk cycle repeats until told otherwise, an attack plays once.
float(float act) AI_ActivityLoops =
{
	if (act == ACT_IDLE)		return TRUE;
	if (act == ACT_IDLE_ANGRY)	return TRUE;
	if (act == ACT_GUARD)		return TRUE;
	if (act == ACT_WALK)		return TRUE;
	if (act == ACT_RUN)		return TRUE;
	if (act == ACT_WALK_HURT)	return TRUE;
	if (act == ACT_RUN_HURT)	return TRUE;
	if (act == ACT_FLY)		return TRUE;
	if (act == ACT_SWIM)		return TRUE;
	if (act == ACT_HOVER)		return TRUE;
	if (act == ACT_CROUCHIDLE)	return TRUE;
	if (act == ACT_COMBAT_IDLE)	return TRUE;
	if (act == ACT_WALK_SCARED)	return TRUE;
	if (act == ACT_RUN_SCARED)	return TRUE;
	return FALSE;
};

// WHICH ACTIVITIES ARE A RUN, for the mover's speed pick.
//
// The mover used to ask `ai_moveact == ACT_RUN` and that identity test is wrong
// for every variant of running the tree has since gained.  ACT_RUN_SCARED is 64,
// not 4, so a fleeing scientist failed it and was moved at ai_speed_walk - which
// is the whole of "when I hit one he runs away very slowly, not at running
// speed".  He was playing the frantic run cycle at walking pace, so he also
// skated.  ACT_RUN_HURT had the same problem and nobody had noticed because
// almost nothing selects it.
//
// Half-Life never has to answer this question: there, movement speed comes from
// the sequence's own m_flGroundSpeed, so asking for the scared run cycle IS
// asking for its speed.  This tree carries two numbers per monster instead, so
// the mapping from activity to number has to be written down.
float(float act) AI_ActivityIsRun =
{
	if (act == ACT_RUN)		return TRUE;
	if (act == ACT_RUN_SCARED)	return TRUE;
	if (act == ACT_RUN_HURT)	return TRUE;
	return FALSE;
};

// A sensible stand-in when a model has no sequence tagged with the activity we
// wanted.  Sven ships a great many custom models and there is no guarantee any
// given one carries the full HL activity set; without this a missing tag means
// .ai_seq = -1 and the monster freezes on whatever it was doing.
float(float act) AI_ActivityFallback =
{
	if (act == ACT_RUN)		return ACT_WALK;
	// WALK -> SWIM -> IDLE, not WALK -> IDLE.  leech.mdl has no walk or run at
	// all: its two gait cycles are tagged ACT_SWIM (6), so the movement tasks -
	// which always ask for ACT_WALK or ACT_RUN - would have fallen straight past
	// them to ACT_IDLE and left it gliding in a hover pose.  Land monsters are
	// unaffected: they carry no ACT_SWIM sequence, so the probe fails and the
	// chain continues to ACT_IDLE exactly as before.
	if (act == ACT_WALK)		return ACT_SWIM;
	if (act == ACT_SWIM)		return ACT_IDLE;
	if (act == ACT_FLY)		return ACT_WALK;
	if (act == ACT_HOVER)		return ACT_IDLE;
	if (act == ACT_RUN_HURT)	return ACT_RUN;
	if (act == ACT_WALK_HURT)	return ACT_WALK;
	if (act == ACT_IDLE_ANGRY)	return ACT_IDLE;
	if (act == ACT_COMBAT_IDLE)	return ACT_IDLE;
	if (act == ACT_SMALL_FLINCH)	return ACT_BIG_FLINCH;
	if (act == ACT_BIG_FLINCH)	return ACT_IDLE;
	if (act == ACT_DIESIMPLE)	return ACT_DIEBACKWARD;
	if (act == ACT_DIEBACKWARD)	return ACT_DIEFORWARD;
	if (act == ACT_DIEFORWARD)	return ACT_DIEVIOLENT;
	if (act == ACT_DIEVIOLENT)	return ACT_IDLE;
	if (act == ACT_MELEE_ATTACK2)	return ACT_MELEE_ATTACK1;
	if (act == ACT_RANGE_ATTACK2)	return ACT_RANGE_ATTACK1;
	if (act == ACT_TURN_LEFT)	return ACT_IDLE;
	if (act == ACT_TURN_RIGHT)	return ACT_IDLE;
	// The scared gaits, newly reachable now that the scientist actually flees.
	// scientist.mdl carries all three (walk_scared idx 1, run1/run2 idx 3/4, panic
	// idx 24), but SCHED_FLEE_ENEMY is shared with the cockroach and with anything
	// else that runs away, and those rigs have none of them - so they must degrade
	// to the ordinary cycle rather than to ACT_RESET and sequence 0.
	if (act == ACT_RUN_SCARED)	return ACT_RUN;
	if (act == ACT_WALK_SCARED)	return ACT_WALK;
	if (act == ACT_EXCITED)		return ACT_IDLE;
	// The region-specific deaths and flinches AI_DeathActivity / AI_FlinchActivity
	// choose between.  Both pickers already test AI_HasActivity before asking, so
	// these entries are a backstop for a replacement rig rather than the normal
	// path - without them a miss returns ACT_RESET and lands on sequence 0, which
	// for a death is a monster standing to attention as a corpse.
	//
	// CENSUSED across the 41 rigs this mod resolves, because "the constant exists"
	// and "any model was ever authored with it" are different claims:
	//   ACT_DIE_HEADSHOT     16 rigs      ACT_DIE_GUTSHOT      14
	//   ACT_DIE_CHESTSHOT     0           ACT_DIE_BACKSHOT      0
	//   ACT_FLINCH_HEAD       0           ACT_FLINCH_CHEST      0
	//   ACT_FLINCH_STOMACH    0           the four LIMB flinches 10 each
	// Nothing in Valve's, Gearbox's or Sven's model set tags CHESTSHOT, BACKSHOT
	// or the three torso flinches, and Half-Life's own GetDeathActivity /
	// GetSmallFlinchActivity never ask for them either - so those five constants
	// are dead in Half-Life as well, not merely unimplemented here.
	if (act == ACT_DIE_HEADSHOT)	return ACT_DIESIMPLE;
	if (act == ACT_DIE_CHESTSHOT)	return ACT_DIESIMPLE;
	if (act == ACT_DIE_GUTSHOT)	return ACT_DIESIMPLE;
	if (act == ACT_DIE_BACKSHOT)	return ACT_DIESIMPLE;
	if (act >= ACT_FLINCH_HEAD && act <= ACT_FLINCH_RIGHTLEG)
					return ACT_SMALL_FLINCH;
	return ACT_RESET;	// no further fallback; caller lands on sequence 0
};

// Resolve an activity to a sequence index, walking the fallback chain.  Returns
// -1 only if the model has no sequences at all.
float(entity m, float act) AI_SeqForActivity =
{
	float mi = m.modelindex;
	if (mi <= 0)
		return -1;

	float nseq = modelframecount(mi);
	if (nseq <= 0)
		return -1;

	float a = act;
	float guard = 0;
	while (a != ACT_RESET && guard < 8)
	{
		float s = frameforaction(mi, (int)a);
		// Range-check against modelframecount, NOT frameduration:
		// HLMDL_FrameInfoForNum (gl/gl_hlmdl.c:1395) silently clamps an
		// out-of-range sequence to 0 and hands back a plausible duration for it,
		// so frameduration can never tell a valid index from an invalid one.
		if (s >= 0 && s < nseq)
			return s;
		a = AI_ActivityFallback(a);
		guard = guard + 1;
	}

	return 0;	// every model has a sequence 0; a wrong pose beats a frozen one
};

// ---------------------------------------------------------------------------
// directional death and hitgroup flinch
// ---------------------------------------------------------------------------
// Half-Life's LookupActivity, and the load-bearing word is EXACT: no fallback
// chain.  AI_SeqForActivity walks fallbacks by design, so it can never answer
// "does this rig carry that tag" - it always finds SOMETHING and says yes.  Both
// pickers below need the honest answer, because Half-Life's whole structure is
// "ask for the ideal, and where the model cannot do it choose something else
// INSTEAD" rather than "ask, and take whatever comes back".
float(entity m, float act) AI_HasActivity =
{
	float mi = m.modelindex;
	if (mi <= 0)
		return FALSE;

	float nseq = modelframecount(mi);
	if (nseq <= 0)
		return FALSE;

	// Same range check and same reason as AI_SeqForActivity: frameduration
	// silently clamps an out-of-range index and hands back a plausible number
	// for it, so modelframecount is the only test that can fail.
	float s = frameforaction(mi, (int)act);
	return (s >= 0 && s < nseq);
};

// Which death and which flinch got chosen.  Counters rather than prose because
// the failure mode here is invisible: every one of these activities ALREADY
// resolved to something before this patch (through the fallback chain), so
// "directional death works" and "directional death silently degrades to
// ACT_DIESIMPLE on every rig" produce identical logs and identical framerates.
float ai_dbg_die_group;		// ACT_DIE_HEADSHOT / GUTSHOT: the hitgroup decided it
float ai_dbg_die_dir;		// ACT_DIEFORWARD / DIEBACKWARD: the shot direction did
float ai_dbg_die_simple;	// ACT_DIESIMPLE: the rig could not do either
float ai_dbg_die_blocked;	// ...of which, downgraded because there was no room to fall
float ai_dbg_flinch_group;	// a limb-specific flinch
float ai_dbg_flinch_generic;	// ACT_SMALL_FLINCH

// combat.cpp:346-460, CBaseMonster::GetDeathActivity.
float(entity m) AI_DeathActivity =
{
	float act       = ACT_DIESIMPLE;	// if nothing better can be found
	float tried_dir = FALSE;

	// dot(facing, the direction the shot was TRAVELLING).  .ai_attackdir points
	// AT the inflictor, so negating it gives the bullet's own heading: > 0.3
	// means it was travelling the way the monster faces, i.e. it arrived from
	// behind - and a body shot in the back falls forward.  Half-Life's sign
	// convention exactly (combat.cpp:368), which is worth stating because it
	// reads backwards until you notice the * -1.
	makevectors([0, m.angles_y, 0]);
	float dot = v_forward * (m.ai_attackdir * -1);

	if (m.ai_lasthitgroup == HITGROUP_HEAD)
		act = ACT_DIE_HEADSHOT;
	else if (m.ai_lasthitgroup == HITGROUP_STOMACH)
		act = ACT_DIE_GUTSHOT;
	else
	{
		// HITGROUP_GENERIC and every limb: direction decides.  A hit inside
		// +/-0.3 of side-on gets neither and stays on ACT_DIESIMPLE.
		tried_dir = TRUE;
		if (dot > 0.3)
			act = ACT_DIEFORWARD;
		else if (dot <= -0.3)
			act = ACT_DIEBACKWARD;
	}

	if (!AI_HasActivity(m, act))
	{
		// The ideal is not on this rig.  If it was already a directional pick
		// there is nothing left to try; if it was region-specific, fall back to
		// the direction rather than straight to simple.
		if (tried_dir)
			act = ACT_DIESIMPLE;
		else if (dot > 0.3)
			act = ACT_DIEFORWARD;
		else if (dot <= -0.3)
			act = ACT_DIEBACKWARD;
	}
	if (!AI_HasActivity(m, act))
		act = ACT_DIESIMPLE;

	// ROOM TO FALL.  A forward death that ends inside a wall is a corpse halfway
	// through the brushwork, so Half-Life traces a head hull the way the body is
	// about to go and downgrades if anything is there.  GoldSrc's head hull is
	// (-16,-16,-18)..(16,16,18); FALSE for nomonsters because HL passes
	// dont_ignore_monsters - a second body in the way counts.
	if (act == ACT_DIEFORWARD || act == ACT_DIEBACKWARD)
	{
		vector c    = m.origin + (m.mins + m.maxs) * 0.5;
		vector away = v_forward * 64;
		if (act == ACT_DIEBACKWARD)
			away = away * -1;
		tracebox(c, '-16 -16 -18', '16 16 18', c + away, FALSE, m);
		if (trace_fraction != 1)
		{
			act = ACT_DIESIMPLE;
			ai_dbg_die_blocked = ai_dbg_die_blocked + 1;
		}
	}

	if (act == ACT_DIE_HEADSHOT || act == ACT_DIE_GUTSHOT)
		ai_dbg_die_group = ai_dbg_die_group + 1;
	else if (act == ACT_DIEFORWARD || act == ACT_DIEBACKWARD)
		ai_dbg_die_dir = ai_dbg_die_dir + 1;
	else
		ai_dbg_die_simple = ai_dbg_die_simple + 1;

	m.ai_dbg_hitact = act;
	return act;
};

// combat.cpp:469-517, CBaseMonster::GetSmallFlinchActivity.
//
// HL computes a flDot here too and then never reads it - dead code in the SDK,
// not an omission on this side.  A flinch is chosen by REGION only.
//
// The census in AI_ActivityFallback says what this can actually do: HITGROUP_HEAD
// and HITGROUP_STOMACH have no authored sequence on ANY rig in the corpus, so
// those two cases resolve to ACT_SMALL_FLINCH on every monster in the game and
// the whole visible effect of this function is the four LIMB flinches, on the ten
// rigs that carry them (agrunt, barney, hgrunt, islave, otis, scientist,
// strooper and the three zombies).
float(entity m) AI_FlinchActivity =
{
	float act = ACT_SMALL_FLINCH;
	float hg  = m.ai_lasthitgroup;

	if      (hg == HITGROUP_HEAD)		act = ACT_FLINCH_HEAD;
	else if (hg == HITGROUP_STOMACH)	act = ACT_FLINCH_STOMACH;
	else if (hg == HITGROUP_LEFTARM)	act = ACT_FLINCH_LEFTARM;
	else if (hg == HITGROUP_RIGHTARM)	act = ACT_FLINCH_RIGHTARM;
	else if (hg == HITGROUP_LEFTLEG)	act = ACT_FLINCH_LEFTLEG;
	else if (hg == HITGROUP_RIGHTLEG)	act = ACT_FLINCH_RIGHTLEG;

	if (!AI_HasActivity(m, act))
		act = ACT_SMALL_FLINCH;

	if (act == ACT_SMALL_FLINCH)
		ai_dbg_flinch_generic = ai_dbg_flinch_generic + 1;
	else
		ai_dbg_flinch_group = ai_dbg_flinch_group + 1;

	m.ai_dbg_hitact = act;
	return act;
};

// Short names for the activities the two pickers above can return, for the
// reports.  Only this set: a general activity-name table would be forty more
// strings that nothing reads.
string(float act) AI_HitActName =
{
	if (act == ACT_DIE_HEADSHOT)	return "die_headshot";
	if (act == ACT_DIE_CHESTSHOT)	return "die_chestshot";
	if (act == ACT_DIE_GUTSHOT)	return "die_gutshot";
	if (act == ACT_DIE_BACKSHOT)	return "die_backshot";
	if (act == ACT_DIEFORWARD)	return "die_forward";
	if (act == ACT_DIEBACKWARD)	return "die_backward";
	if (act == ACT_DIEVIOLENT)	return "die_violent";
	if (act == ACT_DIESIMPLE)	return "die_simple";
	if (act == ACT_FLINCH_HEAD)	return "flinch_head";
	if (act == ACT_FLINCH_CHEST)	return "flinch_chest";
	if (act == ACT_FLINCH_STOMACH)	return "flinch_stomach";
	if (act == ACT_FLINCH_LEFTARM)	return "flinch_leftarm";
	if (act == ACT_FLINCH_RIGHTARM)	return "flinch_rightarm";
	if (act == ACT_FLINCH_LEFTLEG)	return "flinch_leftleg";
	if (act == ACT_FLINCH_RIGHTLEG)	return "flinch_rightleg";
	if (act == ACT_SMALL_FLINCH)	return "small_flinch";
	if (act == ACT_BIG_FLINCH)	return "big_flinch";
	if (act == 0)			return "-";
	return ftos(act);
};

// ---------------------------------------------------------------------------
// AI_SetActivity  /  AI_SetSequenceNamed
// ---------------------------------------------------------------------------
// AI_ApplySequence is the single place .frame is written for a monster.  Both
// entry points funnel through it so the timing bookkeeping AI_SeqDone and
// AI_AnimPump depend on cannot diverge between them.
void(entity m, float seq, float looping) AI_ApplySequence =
{
	m.ai_seq       = seq;
	m.ai_seqstart  = time;
	m.ai_evtcursor = -1;		// -1 so an event at exactly t=0 still fires
	m.frame        = seq;

	if (looping)
	{
		// Looping: no end time.  frameduration would still return a number here
		// and it is a WRONG one to seat a loop timer from - it computes
		// (numframes-1)/fps, i.e. one frame short of the true period.
		m.ai_seqdur = 0;
		m.ai_seqend = 0;
	}
	else
	{
		float d = frameduration(m.modelindex, seq);
		if (d <= 0)
			d = 0.1;	// degenerate/1-frame sequence: do not wedge the schedule
		m.ai_seqdur = d;
		m.ai_seqend = time + d;
	}
};

// Sequence overrides taken, and overrides the model could not honour.  The second
// number is the one that matters on a Sven install: a replacement rig that lacks
// `throwgrenade` silently falls back to the activity lottery, and without a
// counter that is indistinguishable from the fix working.
float ai_dbg_seqoverride, ai_dbg_seqmissing;
// One-shot sequences that had to be re-rolled onto a different variant so the
// client would restart playback, and the ones where the model offered no
// alternative and the re-roll gave up.  Two numbers because they mean opposite
// things: `restart` climbing is the fix working, `stuck` climbing says a model
// has a single-variant one-shot being replayed back-to-back and will visually
// freeze on it — which is a MODEL fact, not a bug here.
float ai_dbg_seqrestart, ai_dbg_seqstuck;
// See the re-roll in AI_SetActivity.  frameforaction is a weighted pick, so this
// is a retry count, not a loop over variants: zombie.mdl weights attack1 5:1
// against attack2, and 16 tries clears that repeat ~95% of the time.
const float AI_SEQ_REROLL_TRIES = 16;
// The grenade animation specifically, because it is the reported bug and because
// "correlated with the loadout" is a claim a single number can settle: before this
// patch the split was a coin flip independent of what the grunt was carrying.
// Declared here rather than in mon_grunt.qc because globals cannot be
// forward-declared and the report lives in sv_ai_core.qc, between the two.
float ai_dbg_gren_throw, ai_dbg_gren_launch;
// The alien slave's arm arcs, here for the same reason: mon_islave.qc compiles
// after sv_ai_core.qc, where the report lives, and QC cannot forward-declare a
// global.  Worth a counter because ArmBeam legitimately produces NOTHING when the
// slave is charging in the open - three sample rays that all miss is a correct
// outcome, not a broken one - so "no arcs visible" has two causes and only this
// number separates them.
float ai_dbg_slave_arcs;
// The gargantua's flame, here for the same reason.  Three numbers rather than
// one because they fail independently: sweeps=0 means no gargantua ever got a
// target into its cone, ticks=0 with sweeps>0 would mean the task never ran, and
// hits=0 with ticks>0 means it burned and touched nothing.
float ai_dbg_garg_flames;	// sweeps started
float ai_dbg_garg_stomps;	// stomp waves spawned
float ai_dbg_garg_flameticks;	// ticks burned
float ai_dbg_garg_flamehits;	// entities damaged by them

// Idempotent: asking for the activity that is already playing does nothing,
// which matters because the schedule layer re-asserts the movement activity on
// every decision tick.
void(entity m, float act) AI_SetActivity =
{
	if (m.ai_activity == act && m.ai_seq >= 0)
		return;

	// THE CLASS GETS FIRST REFUSAL ON THE SEQUENCE, which is Half-Life's structure
	// exactly: a monster with an override implements SetActivity, names the
	// sequences only the loadout can choose between, and lets everything else fall
	// through to LookupActivity.  See the .ai_seqfor note in sv_ai_defs.qc for the
	// measured tag collisions this exists to resolve - the grunt's grenade is the
	// reported one, but the HW grunt's minigun-vs-pistol is the same bug and it was
	// choosing the monster's SOUND as well as its pose.
	//
	// A name the model does not carry is not an error: it falls through, because
	// Sven and Opposing Force ship replacement rigs that legitimately lack them.
	float seq = -1;
	if (m.ai_seqfor && m.modelindex > 0)
	{
		string nm = m.ai_seqfor(m, act);
		if (nm != "" && nm)
		{
			float ns = frameforname(m.modelindex, nm);
			if (ns >= 0 && ns < modelframecount(m.modelindex))
			{
				seq = ns;
				ai_dbg_seqoverride = ai_dbg_seqoverride + 1;
			}
			else
				ai_dbg_seqmissing = ai_dbg_seqmissing + 1;
		}
	}

	if (seq < 0)
	{
		seq = AI_SeqForActivity(m, act);
		if (seq < 0)
			return;		// no model / no sequences - nothing to drive

		// RE-ROLL OFF THE SEQUENCE THE MODEL IS ALREADY SHOWING, because assigning
		// it again does not restart playback (see the file header) and a one-shot
		// that does not restart is a monster frozen in its own follow-through pose.
		//
		// This is the whole of "the zombie did one swing animation, then reverted
		// to nothing, but kept making swing noises".  zombie.mdl tags TWO sequences
		// ACT_MELEE_ATTACK1 — attack1 at weight 5 and attack2 at weight 1 — so two
		// consecutive swings both land on attack1 about 69% of the time.  The
		// SERVER was fine throughout: ai_seqstart/ai_seqend kept running, the event
		// pump kept firing codes 1/2/3, and the claw kept dealing damage and playing
		// claw_strike.  Only the client had nothing to re-stamp, so the zombie stood
		// in the last frame of its first swing and hit you from there.
		//
		// Compared against `m.frame`, NOT `m.ai_seq`.  m.frame IS the sequence index
		// the client will diff (AI_ApplySequence writes it), and it is the one field
		// AI_ResetActivity does not clear — ai_seq is set to -1 there, which made
		// this test unreachable for exactly the case it was written for, since every
		// attack task calls AI_ResetActivity immediately before AI_SetActivity.
		//
		// LOOPING ACTIVITIES ARE EXEMPT and must stay that way.  A loop that is
		// re-asserted simply keeps looping, and HL is explicit about not restarting
		// across the walk/run pair (CBaseMonster::SetActivity, monsters.cpp:1225).
		//
		// frameforaction re-rolls its weighted random per call, so this is a
		// bounded retry rather than a single flip: at zombie.mdl's 5:1 weighting one
		// re-roll would only escape 1 time in 6.  Eight tries brings that to ~77%,
		// twenty-four to ~99%.  Failing all of them is harmless — you get the old
		// behaviour for that one swing, and nothing about damage or timing moves.
		//
		// Deliberately NOT applied to a class override: a name is a decision, and
		// re-rolling it would be the same coin flip this hook exists to remove.
		if (seq == m.frame && !AI_ActivityLoops(act))
		{
			float tries = 0;
			while (tries < AI_SEQ_REROLL_TRIES)
			{
				float again = AI_SeqForActivity(m, act);
				if (again >= 0 && again != seq)
				{
					seq = again;
					ai_dbg_seqrestart = ai_dbg_seqrestart + 1;
					break;
				}
				tries = tries + 1;
			}
			if (tries >= AI_SEQ_REROLL_TRIES)
				ai_dbg_seqstuck = ai_dbg_seqstuck + 1;
		}
	}

	m.ai_activity = act;
	m.ai_seqname  = "";		// an activity is now driving this monster, not a name

	// THE TURN RATE IS PART OF THE ACTIVITY, and this is where Half-Life picks
	// it: CBaseMonster::SetActivity calls SetYawSpeed() (monsters.cpp:1240) on
	// every change, which is why an hgrunt pivots faster than it strafes and
	// slower than neither while shooting.  Deliberately NOT driven from
	// TASK_SET_YAWSPEED - that task exists and is handled, but HL does not use
	// it for this and wiring it into every schedule would be a second source of
	// truth for the same number.
	//
	// sv_ai_yawspeed_hl is the escape hatch named in the plan's risk section:
	// Valve's tables make the small aliens markedly slower than this mod's own
	// hand-picked figures (a walking headcrab is 20 in HL against 280 here), and
	// if that reads badly this is the dial, not the factor of two.
	if (m.ai_yawspeed && cvar("sv_ai_yawspeed_hl"))
	{
		float ys = m.ai_yawspeed(m, act);
		if (ys > 0)
			m.ai_yaw_speed = ys;
	}

	AI_ApplySequence(m, seq, AI_ActivityLoops(act));
};

// Play a sequence BY NAME.
//
// The turret family and the barnacle need this because their models carry no
// activity tags whatsoever - sentry.mdl, miniturret.mdl and turret.mdl are six
// named sequences each (idle_off, deploy, spin, fire, retire, die) and
// barnacle.mdl is seven.  frameforaction on any of them returns nothing useful,
// so AI_SetActivity's whole fallback chain would land them on sequence 0 and
// leave them there.
//
// `looping` is a PARAMETER rather than something derived, because the engine
// does not expose the model's loop flag: hlmdl_sequencelist_t.loop exists but no
// builtin reports it, and AI_ActivityLoops only works because it keys off the
// activity, which a named sequence does not have.  The caller knows whether
// idle_off loops; nothing else here can.
//
// Returns FALSE if the model has no sequence by that name, so a class can probe
// before committing to a scheme - Sven ships many replacement models and a
// missing name must degrade rather than silently freeze the monster on frame 0.
float(entity m, string nm, float looping) AI_SetSequenceNamed =
{
	if (nm == "" || !nm)
		return FALSE;

	float mi = m.modelindex;
	if (mi <= 0)
		return FALSE;

	// Idempotent on the NAME, mirroring AI_SetActivity's idempotence on the
	// activity: the schedule layer re-asserts whatever is playing every tick.
	if (m.ai_seqname == nm && m.ai_seq >= 0)
		return TRUE;

	float seq = frameforname(mi, nm);
	// frameforname returns -1 for an unknown name, but range-check the upper end
	// too: frameduration silently clamps out-of-range to sequence 0 and hands back
	// a plausible duration, so a bad index here would produce a believable-looking
	// timer for the wrong animation.
	if (seq < 0 || seq >= modelframecount(mi))
		return FALSE;

	m.ai_activity = ACT_RESET;	// no activity owns this monster now
	m.ai_seqname  = nm;
	AI_ApplySequence(m, seq, looping);
	return TRUE;
};

// Does this model carry a sequence by that name?  For boot-time probes, where
// finding out that a replacement model lacks the names a class needs is much
// more useful than discovering it as a frozen monster mid-game.
float(float mi, string nm) AI_SeqNameExists =
{
	if (mi <= 0 || nm == "" || !nm)
		return FALSE;
	float s = frameforname(mi, nm);
	return (s >= 0 && s < modelframecount(mi));
};

// Force the next AI_SetActivity to take effect even for the same activity.
// Used when a sequence must genuinely be replayed from the top (a second flinch
// from a second hit, for instance) rather than merely re-asserted.
void(entity m) AI_ResetActivity =
{
	m.ai_activity = ACT_RESET;
	m.ai_seqname  = "";		// or a named sequence would still test as current
	m.ai_seq      = -1;
};

// TRUE once a one-shot sequence has played out.  A looping activity never
// reports done - the schedule layer is what ends those, via a wait or an
// interrupt condition.
float(entity m) AI_SeqDone =
{
	if (m.ai_seqend <= 0)
		return FALSE;
	return time >= m.ai_seqend;
};

// ---------------------------------------------------------------------------
// the event pump
// ---------------------------------------------------------------------------
// Half-Life hangs the actual gameplay off animation events rather than off the
// schedule: the headcrab's leap is applied by event code 2 on frame 0 of the
// jump sequence, not by the task that started the jump.  Reproducing that is
// what makes attacks land in sync with what the player sees.
//
// getmodeleventidx rather than getnextmodelevent, because the latter reports
// only the FIRST event at any given timestamp and HL co-times sound+effect
// constantly.  Its timestamp is already in SECONDS from the sequence start
// (HLMDL_GetModelEvent, gl/gl_hlmdl.c:867 - `ev->pose / seq->timing`), i.e. the
// same clock as (time - ai_seqstart), so no conversion is needed.
//
// ai_evtcursor is a monotonic high-water mark, which is also what makes this
// safe under sv_gameplayfix_multiplethinks (default 1): a think that fires
// several times in one frame finds cursor == now on the later calls and emits
// nothing, instead of firing every event again.
const float AI_EVENT_MAX = 24;		// per-sequence scan bound

// Animation events actually delivered, split by who consumed them.  Worth having
// permanently: the footstep events live on a LOOPING sequence, which is the one
// path in this pump with a known wrap approximation, and "did any event fire at
// all" is otherwise invisible - a silent monster looks exactly like a monster
// whose sound file is missing.
float ai_dbg_ev_shared, ai_dbg_ev_class;
// Three counters for the three systemic bugs fixed below, so none of them can rot
// back to silence unnoticed.  Each one was worth exactly zero before this patch.
float ai_dbg_ev_star;		// '*' stream prefixes stripped
float ai_dbg_ev_step;		// code 2003 footsteps played
float ai_dbg_ev_swish;		// code 2010 melee swishes played
float ai_dbg_ev_scriptdead;	// code 1000 SCRIPT_EVENT_DEAD honoured

// The shared (>= 1000) half of the event table, handled once here for every
// monster rather than per class - which is exactly where Half-Life handles it
// too, in CBaseMonster::HandleAnimEvent rather than in each monster's override.
// Returns TRUE if the event was consumed and the class virtual should not also
// see it.
//
// EVENT_SOUND is the one that matters and the one that was missed: the zombie's
// walk cycle carries six of them naming common/npc_step1..4.wav, and until this
// existed every zombie in the mod walked in silence.  Any model added later that
// asks for a sound now gets it for free, with no per-class code at all.
// The options string on a sound event names a file, and the two families of model
// disagree about whether that name carries its extension.  Half-Life's own models
// write "common/npc_step1.wav"; Opposing Force's strooper.mdl writes
// "shocktrooper/shock_trooper_attack" with no extension at all, and gonome.mdl
// writes both forms in the same file.  precache_sound and sound() need the real
// filename, so normalise here rather than at each of the three call sites.
//
// Lowercased before the compare because the extension is content, not code, and
// nothing stops a model from carrying ".WAV".
//
// The leading '*' is GoldSrc's "stream this off disk, do not cache it" marker, and
// it is part of the NAME as far as every consumer here is concerned.  FTE does not
// merely fail to find the file - it never looks: S_LoadSound tests `*name == '*'`
// and takes it for a Quake 2 sexed sound, setting SLS_FAILED and returning before
// the path is built at all (client/snd_mem.c:1058-1063).  So these could not have
// worked, and could not have been made to work by adding files.
//
// Measured across the 42 rigs the mod warms: 21 distinct names on 28 events, all of
// them Half-Life's own - barney's and otis's *buttons/blip1.wav, the zombie's
// *debris/bustcrate1.wav, and sixteen scientist lines including *scientist/scream3
// and both pain lines.  All 21 resolve in valve/ the moment the star comes off.
string(string data) AI_EventSoundName =
{
	if (substring(data, 0, 1) == "*")
	{
		data = substring(data, 1, -1);
		ai_dbg_ev_star = ai_dbg_ev_star + 1;
	}

	float n = strlen(data);
	if (n < 4)
		return data;
	if (strtolower(substring(data, n - 4, 4)) == ".wav")
		return data;
	return strcat(data, ".wav");
};

// One of four, so a walk cycle does not machine-gun the same sample.  Half-Life's
// rigs that spell their footsteps out get the variety for free by naming a
// different file on each event; the code-2003 rigs name nothing, so it happens
// here instead.
string() AI_StepSound =
{
	float r = floor(random() * 4);
	if (r < 1)	return SND_NPC_STEP1;
	if (r < 2)	return SND_NPC_STEP2;
	if (r < 3)	return SND_NPC_STEP3;
	return SND_NPC_STEP4;
};

// ---------------------------------------------------------------------------
// voice families
// ---------------------------------------------------------------------------
// The backing code for .ai_snd_pain / _die / _idle / _alert (sv_ai_defs.qc).  A
// family is a space-separated list of complete sound paths; the same literal is
// walked by AI_SndPrecache and picked from by AI_SndPlay, so the two can never
// drift apart.
//
// tokenize/argv is the same mechanism AI_ProbeModelSeqs uses on sequence names
// further down this file.  Neither call site sits inside another tokenize loop -
// the voice hooks fire from schedule tasks and from AI_Damaged, the precache walk
// from spawn - so there is no argv state to clobber.
float ai_dbg_snd_voice;		// voice lines played out of a family, per report interval
float ai_dbg_snd_total;		// ...and since map start, which nothing resets
float ai_dbg_snd_files;		// distinct paths precached through a family

string(string list) AI_SndPick =
{
	float n = tokenize(list);
	if (n <= 0)
		return "";
	// FTE's PF_random is (rand()&0x7fff)/0x7fff, which CAN return exactly 1.0 -
	// unlike the [0,1) every other engine documents.  One clamp here rather than a
	// once-in-32768 argv(n) that returns "" and drops a voice line.
	float i = floor(random() * n);
	if (i >= n)
		i = n - 1;
	return argv(i);
};

// GAG DOES NOT MUTE A MONSTER.  This function used to open with `if (m.gag)
// return;`, which made SF_MONSTER_GAG a blanket silencer over every sound any
// class makes through the shared list-picker - gunfire, claws, footsteps, pain
// and death included.  Half-Life reads that flag in exactly one place, FOkToSpeak
// (hgrunt.cpp:331-345, agrunt.cpp:284, talkmonster.cpp:931), which gates SENTENCE
// SPEECH and idle chatter and nothing else - and even that is overridden the
// moment the monster enters MONSTERSTATE_COMBAT.
//
// The reported symptom was hl_c06's grunts reading as "place holders with no
// actual function": 9 of its 14 carry spawnflag 2, so they fired an MP5 with no
// gunshot, took hits without a grunt and died without a scream.  538 of 4207
// map-placed monsters across 68 maps carry the flag.
//
// Speech now goes through AI_SndSpeak below; this path is unconditional, as HL's
// EMIT_SOUND_ARRAY_DYN is.
void(entity m, float chan, string list) AI_SndPlay =
{
	string s = AI_SndPick(list);
	if (s == "")
		return;

	// Half-Life plays every one of these families through EMIT_SOUND_ARRAY_DYN
	// (monsters.h), which is NOT a plain EMIT_SOUND: volume 1.0, ATTN_NORM and
	// RANDOM_LONG(95,105) pitch.  The jitter is most of why four idle lines do not
	// sound like exactly four idle lines, so it is the default here too.
	float at = m.ai_snd_atten;
	if (at <= 0)
		at = ATTN_NORM;
	float pj = m.ai_snd_pitch;
	if (pj == 0)
		pj = 5;			// negative means "no jitter", for a class that wants none
	if (pj < 0)
		pj = 0;

	AI_SoundEx(m, chan, s, 1, at, 100 - pj + floor(random() * (pj * 2 + 1)), 0);
	ai_dbg_snd_voice = ai_dbg_snd_voice + 1;
	ai_dbg_snd_total = ai_dbg_snd_total + 1;
};

// The gag-respecting half: idle chatter and anything else that is the monster
// TALKING rather than the monster acting.  This is HL's FOkToSpeak, including its
// combat override - a gagged grunt that has been engaged is allowed its voice
// again (hgrunt.cpp:337-344, `if (m_MonsterState != MONSTERSTATE_COMBAT ...)`),
// which is why an ambush squad goes quiet before the fight and audible during it.
//
// Both spellings are honoured for the same reason sv_ai_talk.qc:372 honours both:
// the spawnflag is HL's and the `gag` key is Sven's, and maps use each.
void(entity m, float chan, string list) AI_SndSpeak =
{
	if ((m.gag || (m.spawnflags & SF_MON_GAG)) && m.ai_state != MS_COMBAT)
		return;
	AI_SndPlay(m, chan, list);
};

// ---------------------------------------------------------------------------
// the sound register  —  `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// Every name that goes through AI_SndPrecache is kept, so the boot self-test can
// walk them and ask the filesystem whether each one is actually there.
//
// THIS IS NOT OPTIONAL BOOKKEEPING.  fteqcc has a static check for this - warning
// F210, "sound used but not directly precached" - and it only sees LITERAL
// precache_sound calls, so routing a family through a runtime walk defeats it.
// The register buys back a strictly stronger check in exchange: F210 can only tell
// you a precache line is missing, whereas whichpack() can tell you the file does
// not exist at all.  That is the failure mode this whole audit kept finding -
// con_fire1, gon_pain3, ichy_bite3 and sniper_reload1 were all precached exactly as
// they should have been, and none of them has ever existed.
//
// 640 slots against ~200 real entries.  The overflow counter is reported rather
// than silently dropped, because a truncated register that reports "all present"
// is worse than no register.
const float AI_SNDREG_MAX = 640;
string ai_sndreg[AI_SNDREG_MAX];
float  ai_sndreg_count;
float  ai_sndreg_overflow;
float  ai_sndreg_dupes;

void(string nm) AI_SndRegister =
{
	float i;
	for (i = 0; i < ai_sndreg_count; i = i + 1)
		if (ai_sndreg[i] == nm)
		{
			ai_sndreg_dupes = ai_sndreg_dupes + 1;
			return;
		}
	if (ai_sndreg_count >= AI_SNDREG_MAX)
	{
		ai_sndreg_overflow = ai_sndreg_overflow + 1;
		return;
	}
	ai_sndreg[ai_sndreg_count] = nm;
	ai_sndreg_count = ai_sndreg_count + 1;
};

// Returns the number of files precached, so a class can assert on it if it wants.
float(string list) AI_SndPrecache =
{
	float n = tokenize(list);
	float i;
	// argv() is invalidated by the next tokenize, and AI_SndRegister does not
	// tokenize - but strzone is still needed: argv returns a temp string whose
	// storage the engine reuses.  strcat with "" forces a fresh permanent copy,
	// which is this codebase's existing way of doing that without a strunzone
	// obligation for a table that lives until the map ends.
	for (i = 0; i < n; i = i + 1)
	{
		string nm = strcat(argv(i), "");
		precache_sound(nm);
		AI_SndRegister(nm);
	}
	ai_dbg_snd_files = ai_dbg_snd_files + n;
	return n;
};

// Walk the register and ask the filesystem, not the precache table.  whichpack()
// answers without precaching (the same builtin Monster_ModelExists uses), so this
// costs nothing beyond the walk itself and is safe to run at boot.
void() AI_SndSelfTest =
{
	float i, bad = 0;
	string miss = "";

	for (i = 0; i < ai_sndreg_count; i = i + 1)
	{
		// The engine resolves a sound name relative to sound/, so that is where the
		// file has to be probed.  Getting this prefix wrong would make every entry
		// report missing, which is why the control below exists.
		string p = whichpack(strcat("sound/", ai_sndreg[i]));
		if (p == "" || !p)
		{
			bad = bad + 1;
			if (bad <= 12)
				miss = strcat(miss, " ", ai_sndreg[i]);
		}
	}

	// CONTROL, and it is the whole reason this report can be believed.  If the
	// prefix or the builtin were wrong, every real name would report missing and
	// the number would look alarming but mean nothing.  A name that CANNOT resolve
	// must report missing and a name that must resolve has to report present -
	// common/npc_step1.wav is one this mod plays on every zombie footstep.
	string ctl_bad  = whichpack("sound/__ai_no_such_sound__.wav");
	string ctl_good = whichpack("sound/common/npc_step1.wav");

	dprint(sprintf("[ai-selftest] sounds: %g registered, %g dupes, %g overflow, %g MISSING\n",
	               ai_sndreg_count, ai_sndreg_dupes, ai_sndreg_overflow, bad));
	dprint(sprintf("[ai-selftest]   control: absent=%s present=%s\n",
	               (ctl_bad == "" || !ctl_bad) ? "notfound(ok)" : "FOUND(BAD)",
	               (ctl_good == "" || !ctl_good) ? "notfound(BAD)" : "found(ok)"));
	if (bad)
		dprint(sprintf("[ai-selftest]   MISSING:%s%s\n",
		               miss, (bad > 12) ? " ..." : ""));
};

float(entity m, float code, string data) AI_HandleSharedEvent =
{
	// 1004 and 1011 are the same event wearing two different numbers - Valve's and
	// Sven's.  Treating them identically (and on the same channel) is deliberate:
	// 1011 carries footsteps AND vocals in the same model (gonome.mdl runlong vs
	// attack1), so there is no channel split to make, and CHAN_BODY is what 1004
	// already uses and what keeps these off the class's own CHAN_VOICE pain and
	// idle lines.
	//
	// ATTN_IDLE, not ATTN_NORM, and it is Half-Life's number rather than a taste
	// call: monsters.cpp:2659 and :2663 both pass ATTN_IDLE.  The two engines agree
	// on what that constant means - GoldSrc and Quake both cut a sound off at
	// 1000/attenuation units, and ATTN_IDLE is 2.0 in both, so this is an exact
	// match at 500 units.  ATTN_NORM was carrying every monster footstep and every
	// event voice line 1000 units in a game whose own AI can only hear 1024, which
	// is why a single zombie could be heard walking from most of a map away.
	if (code == EVENT_SOUND || code == EVENT_SOUND_SVEN)
	{
		if (data != "" && data)
			AI_Sound(m, CHAN_BODY, AI_EventSoundName(data), 1, ATTN_IDLE);
		return TRUE;
	}
	if (code == EVENT_SOUND_VOICE)
	{
		if (data != "" && data)
			AI_Sound(m, CHAN_VOICE, AI_EventSoundName(data), 1, ATTN_IDLE);
		return TRUE;
	}
	if (code == EVENT_BODYDROP_LIGHT || code == EVENT_BODYDROP_HEAVY)
	{
		// HL's own pair, and the reason a zombie's death animation has always
		// landed silently here: diesimple carries a 2001 at 0.650s.
		//
		// Three details from monsters.cpp:2694-2719 that the first pass at this
		// invented instead of reading.  The file is picked at RANDOM from the same
		// two for both codes; HEAVY differs only by going out at pitch 90
		// (EMIT_SOUND_DYN, i.e. speedpct here - see the note at mon_grunt.qc:290);
		// and both are gated on FL_ONGROUND, without which a monster killed in
		// mid-air thuds while it is still falling.
		if (!(m.flags & FL_ONGROUND))
			return TRUE;
		AI_SoundEx(m, CHAN_BODY, (random() < 0.5) ? SND_BODYDROP_A : SND_BODYDROP_B,
		           1, ATTN_NORM, (code == EVENT_BODYDROP_HEAVY) ? 90 : 100, 0);
		return TRUE;
	}
	// Sven Co-op's footstep event.  Empty options in all 104 occurrences across the
	// mounts, so the sample is named in sv_ai_defs.qc beside BODYDROP's for the same
	// reason.  In THIS install only hwgrunt.mdl reaches it - the valve copies of
	// hgrunt/barney/scientist/zombie win the path lookup and those spell their
	// footsteps out as EVENT_SOUND - but that is a fact about mount order, not about
	// the code, and it costs nothing to be right for the Sven rigs that follow.
	if (code == EVENT_FOOTSTEP_SVEN)
	{
		if (m.flags & FL_ONGROUND)
		{
			AI_Sound(m, CHAN_BODY, AI_StepSound(), 1, ATTN_IDLE);
			ai_dbg_ev_step = ai_dbg_ev_step + 1;
		}
		return TRUE;
	}

	// 1000/1010 — the scripted life-and-death pair, and the reason a scientist who
	// played a dying animation used to STAND BACK UP at the end of it.  The comment
	// this replaces said these "appear on sequences this AI does not play yet",
	// which stopped being true the moment scripted_sequence went live: sstruggle
	// carries 1000 on frame 1 of 66, and th_ep1_01's `caretaker` plays it.
	//
	// THE EVENT DOES NOT KILL THE MONSTER.  monsters.cpp:2634-2646 only raises a
	// flag — deadflag DEAD_DYING and health 0 — and lets the remaining 65 frames
	// play, because those frames ARE the dying.  The corpse is made later, once,
	// by Script_DieInPlace off the back of this flag (sv_scripted.qc).  Killing
	// here would cut the animation off at 36 ms and hand the body to SCHED_DIE,
	// which would then play a SECOND, ordinary death animation over the top.
	//
	// Gated on MS_SCRIPT exactly as Half-Life is, and the gate is load-bearing
	// rather than defensive: scientist.mdl carries 1000 on fourteen sequences
	// (sstruggle, fall, fall_elevator, tentacle_grab, helicack, haulscientist,
	// ickyjump_sci...), several of which a mapper can also reach through cycler or
	// a forced `sequence` key, and a monster nobody has possessed must not be able
	// to flag itself dead out of an idle loop.
	if (code == EVENT_DEAD)
	{
		if (m.ai_state == MS_SCRIPT && m.ai_script)
		{
			m.deadflag = DEAD_DYING;
			m.health   = 0;
			ai_dbg_ev_scriptdead = ai_dbg_ev_scriptdead + 1;
		}
		return TRUE;
	}
	// The other half of the pair: "bring back to life", for the life/death
	// sequences where the script decides which.  Nothing in the th_* corpus
	// reaches it (measured: 0 of 491 scripted_sequences), but it is two lines and
	// implementing one half of a pair is how the next model quietly goes wrong.
	// max_health is the right restore because it is only repurposed as the
	// blood-decal budget AFTER a corpse exists, and this path runs before that.
	if (code == EVENT_NOT_DEAD)
	{
		if (m.ai_state == MS_SCRIPT && m.ai_script)
		{
			m.deadflag = DEAD_NO;
			m.health   = m.max_health;
		}
		return TRUE;
	}
	// 1001/1002 stay swallowed, and that is now a measured decision rather than a
	// deferral: AllowInterrupt is a no-op for this corpus because every one of the
	// nine th_* scripts whose play sequence carries 1000 ALSO carries
	// SF_SCRIPT_NOINTERRUPT (32), which Script_CanInterrupt already honours.
	if (code == EVENT_NOINTERRUPT)	return TRUE;
	if (code == EVENT_CANINTERRUPT)	return TRUE;

	// 2010 SWISHSOUND rides on every melee wind-up in the gearbox rigs (massn's
	// three frontkicks, strooper's, hgrunt's).  It used to be swallowed here under a
	// comment claiming HL's client dll owned the sample and there was nothing to
	// play - which was wrong, and wrong in the way that is worth recording: the
	// options field being empty was read as evidence, when the sample is named
	// inline in the server dll at monsters.cpp:2721-2726, directly under Valve's own
	// all-caps warning that any monster using this event must precache it.  Empty
	// options means "the name is in the code", not "there is no name".
	if (code == EVENT_SWISHSOUND)
	{
		AI_Sound(m, CHAN_BODY, SND_SWISH, 1, ATTN_NORM);
		ai_dbg_ev_swish = ai_dbg_ev_swish + 1;
		return TRUE;
	}

	return FALSE;		// including 5001 and the whole low per-class range
};

void(entity m, float lo, float hi) AI_PumpEventRange =
{
	if (hi <= lo)
		return;

	float mi = m.modelindex;
	float seq = m.ai_seq;
	if (mi <= 0 || seq < 0)
		return;

	entity oldself = self;
	float evi = 0;
	float ts; int code; string edata;

	while (evi < AI_EVENT_MAX)
	{
		if (!getmodeleventidx(mi, seq, (int)evi, ts, code, edata))
			break;			// also the natural end-of-list; it range-checks
		evi = evi + 1;

		if (ts <= lo)	continue;
		if (ts > hi)	continue;

		if (AI_HandleSharedEvent(m, (float)code, edata))
		{
			ai_dbg_ev_shared = ai_dbg_ev_shared + 1;
			continue;
		}

		ai_event_code = (float)code;
		ai_event_data = edata;

		if (m.ai_event)
		{
			ai_dbg_ev_class = ai_dbg_ev_class + 1;
			self = m;
			m.ai_event();
			self = oldself;
		}
	}
};

void(entity m) AI_AnimPump =
{
	if (m.ai_seq < 0)
		return;
	if (m.modelindex <= 0)
		return;

	float tnow = time - m.ai_seqstart;
	if (tnow < 0)
		tnow = 0;

	if (m.ai_seqdur > 0)
	{
		// One-shot: clamp so events never fire past the end, and so a monster
		// left holding a finished sequence stops re-scanning it.
		if (tnow > m.ai_seqdur)
			tnow = m.ai_seqdur;
		AI_PumpEventRange(m, m.ai_evtcursor, tnow);
		m.ai_evtcursor = tnow;
		return;
	}

	// Looping.  Events repeat every period, so the cursor has to wrap with them.
	//
	// HONEST LIMITATION: the true period is numframes/fps and the only figure QC
	// can obtain is frameduration's (numframes-1)/fps, so this wraps one frame
	// early and drifts against what the renderer draws by one frame per loop.
	// That is acceptable for what actually lives on looping sequences here -
	// footsteps and idle noises - and nothing in B2/B3 puts damage on one.  A
	// class that needs frame-exact looping events wants a one-shot sequence
	// re-armed by the schedule instead.
	float period = frameduration(m.modelindex, m.ai_seq);
	if (period <= 0)
	{
		// Cannot establish a period: scan forward once and stop, rather than
		// spin.  Better a missed footstep than a stuck cursor.
		AI_PumpEventRange(m, m.ai_evtcursor, tnow);
		m.ai_evtcursor = tnow;
		return;
	}

	float cyc = tnow - floor(tnow / period) * period;

	if (cyc >= m.ai_evtcursor)
		AI_PumpEventRange(m, m.ai_evtcursor, cyc);
	else
	{
		// Wrapped since the last pump: finish the old loop, then the new one.
		AI_PumpEventRange(m, m.ai_evtcursor, period);
		AI_PumpEventRange(m, -1, cyc);
	}
	m.ai_evtcursor = cyc;
};

// ---------------------------------------------------------------------------
// sequence-name probe  —  part of `sv_ai_selftest 1`
// ---------------------------------------------------------------------------
// The turret family and the barnacle carry no activity tags, so W6 will drive
// them entirely through AI_SetSequenceNamed.  Two things are worth knowing before
// those classes are written rather than after: whether the models are installed
// at all, and whether they carry the names the class intends to ask for.  Sven
// ships replacement models freely, and a missing name is otherwise discovered as
// a monster frozen on frame 0 with nothing in the log.
//
// This PRECACHES each model it probes, so it is gated behind sv_ai_selftest and
// never runs on a live server: a precache slot spent on a model no entity uses is
// a real cost on a busy map.
void(string mdl, string names) AI_ProbeModelSeqs =
{
	float mi = getmodelindex(mdl);
	if (mi <= 0)
	{
		dprint(sprintf("[ai-selftest] seqprobe %-24s NOT INSTALLED\n", mdl));
		return;
	}

	float n = tokenize(names);
	float i;
	string have = "", miss = "";

	for (i = 0; i < n; i = i + 1)
	{
		string nm = argv(i);
		if (AI_SeqNameExists(mi, nm))
		{
			// THE DURATION IS THE POINT for viewmodels, not just the name.
			// Several models/v_*.mdl paths resolve from more than one mounted
			// gamedir with the SAME labels in the SAME order at DIFFERENT fps —
			// v_m40a1.mdl is gearbox-vs-svencoop — so a name-only probe cannot
			// tell you which copy won, which is exactly the question.  One
			// number does: v_m40a1 draw(1.000) is gearbox, draw(0.517) is Sven.
			have = strcat(have, sprintf(" %s(%.3f)", nm,
			                            frameduration(mi, frameforname(mi, nm))));
		}
		else
			miss = strcat(miss, " ", nm);
	}

	dprint(sprintf("[ai-selftest] seqprobe %-24s %g seqs | have:%s | MISSING:%s\n",
	               mdl, modelframecount(mi), have, miss));
};

void() AI_SeqNameSelfTest =
{
	// CONTROL FIRST.  A model path that cannot exist must report NOT INSTALLED.
	// Without this line the probe cannot be trusted at all: if the engine hands
	// back a substitute model for a missing file, every "have:" below would be
	// describing the substitute, and a confident-looking inventory of models that
	// are not there is worse than no inventory.
	AI_ProbeModelSeqs("models/__ai_probe_control__.mdl", "idle walk");

	// A correctness check against a model this mod already ships and whose
	// sequence names were read out of the file: five that must resolve and one
	// that must not.  If "__nosuchsequence__" ever appears under have:, then
	// frameforname is not failing the way AI_SetSequenceNamed assumes it does and
	// every probe below is meaningless.
	AI_ProbeModelSeqs("models/headcrab.mdl",
	                  "idle1 walk run jump dieback __nosuchsequence__");

	// Inventory for W6.  The turret set is what the plan read out of the models;
	// the barnacle's names are NOT known here, so its line is worth reading purely
	// for the sequence count and for which guesses land.
	AI_ProbeModelSeqs("models/sentry.mdl",     "idle_off deploy spin fire retire die");
	AI_ProbeModelSeqs("models/miniturret.mdl", "idle_off deploy spin fire retire die");
	AI_ProbeModelSeqs("models/turret.mdl",     "idle_off deploy spin fire retire die");
	// The barnacle's real names, read out of the file after the first guess at
	// them missed all seven.  Only attack1 lacks an activity.
	AI_ProbeModelSeqs("models/barnacle.mdl",
	                  "idle1 idle2 idle3 flinch_sm attack1 chewcycle death");

	// EVERY NAME .ai_seqfor CAN ASK FOR, checked on every rig that carries a table.
	// This is the boot-time half of the ai_dbg_seqmissing counter and it is the
	// better half: the counter only reports names that were actually requested
	// during play, so a rig whose grenade animation is missing stays silent until
	// somebody happens to fight it at the right range.  Here it is a number on
	// every map load, on every install.
	//
	// A "MISSING:" entry is not fatal - the hook falls through to the activity
	// lottery, which is what these rigs did before - but on hgrunt.mdl and
	// hwgrunt.mdl it means the reported bug is back.
	// crouching_m40a1 AND rpg_shoot ARE THE DISCRIMINATOR Grunt_BodyInit uses to
	// tell the three rigs called "hgrunt" apart, so their have:/MISSING: answers
	// here are load-bearing, not decoration - and the sequence COUNT on the same
	// line says which file won the name outright (Half-Life 82, Sven 95,
	// desertcircle 88).  Read them together: m40a1 present means the six-weapon
	// base-5 rig, rpg_shoot alone means desertcircle's base-4 one, neither means
	// Half-Life's.
	AI_ProbeModelSeqs("models/hgrunt.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 standing_shotgun crouching_shotgun limpingwalk limpingrun rpg_shoot crouching_m40a1");
	AI_ProbeModelSeqs("models/hgrunt_sniper.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun standing_m40a1 crouching_m40a1");
	AI_ProbeModelSeqs("models/hgrunt_opfor.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 standing_shotgun crouching_shotgun standing_saw crouching_saw limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/massn.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 standing_shotgun crouching_shotgun limpingwalk limpingrun standing_m40a1 crouching_m40a1");
	AI_ProbeModelSeqs("models/hgrunt_torch.mdl",
	                  "throwgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/hgrunt_medic.mdl",
	                  "throwgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/strooper.mdl",
	                  "throwgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/hwgrunt.mdl",
	                  "attack pistol_shoot pistol_crouchshoot creeping_walk pistol_walk run pistol_run pistol_idle");

	// VIEWMODELS, not monsters — the only two weapons that resolve their
	// sequences by name (sh_wpn_csglock.qc / sh_wpn_csg3sg1.qc via
	// SH_SeqForName).  Both come from the mounted cstrike gamedir
	// (fs_addons.txt:16) rather than from models/weapons/, because the copies
	// under wpn_csglock/ and wpn_csg3sg1/ are flat IDPO frame bakes whose frame
	// names were all overwritten with "frameN" — FTE groups those into ONE
	// group called "frame", so every lookup against them whiffs.
	//
	// A MISSING: entry here is not fatal — SH_SeqForName falls back to the
	// hardcoded index — but it is the difference between the guns animating
	// correctly and animating the way they did before this was fixed, and
	// nothing else in the build would say so.  czero also ships both of these
	// filenames with the SAME sequence names at different fps, so whichever
	// mount wins, these lines must stay full.
	AI_ProbeModelSeqs("models/v_glock18.mdl",
	                  "idle1 shoot shoot2 shoot3 shoot_empty reload draw");
	AI_ProbeModelSeqs("models/v_g3sg1.mdl",
	                  "idle1 shoot shoot2 reload draw");

	// THE DEAGLE MOVED OFF ITS BUNDLED IDPO onto the mounted cstrike model, so
	// this line is what says the swap actually landed and which copy answered —
	// czero ships its own v_deagle.mdl at a different size and fps.  A MISSING:
	// on shoot_empty would mean the slide-lock take is being faked by shoot1.
	AI_ProbeModelSeqs("models/v_deagle.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw");
	// The AWP already has a probe row further down — read the DURATIONS in its
	// have: list, not just the names.  idle1(0.500) against shoot1(1.171) is the
	// whole of the cut-bolt-cycle bug: the fire state was timed off the first,
	// not the second.  See SH_AWPTickState.

	// v_9mmar.mdl is the WORST of the colliding bare paths: valve, gearbox,
	// bshift and svencoop all ship it with different layouts, and the gearbox /
	// Blue Shift copy inserts a second "deploy" that shifts every shoot index by
	// one.  sh_wpn_hlsmg.qc resolves around that by name, but which mount actually
	// won is invisible without this line.  READ IT AS A PAIR:
	//   9 seqs + "shoot"           -> gearbox / bshift (shoots at 6/7/8)
	//   8 seqs + "shoot"           -> valve           (shoots at 5/6/7)
	//   8 seqs + "fire1", no shoot -> svencoop        (shoots at 5/6/7)
	// A line with NEITHER "shoot" nor "fire1" under have: means the resolver is
	// falling back to the hardcoded indices and the gun may mis-animate.
	AI_ProbeModelSeqs("models/v_9mmar.mdl",
	                  "longidle idle1 idle grenade launch reload deploy shoot fire1");

	// THE SIX WHOSE STATE DURATIONS FOLLOW THE MODEL.  Every one of these was
	// hardcoded against valve's or gearbox's copy while svencoop's — which is
	// above both in fs_addons.txt — is what the engine actually opens, so each
	// state ran long or short against whatever was on screen.  They resolve
	// through SH_SeqDuration now; these lines say which copy answered, and the
	// durations in the `have:` list are the whole point of them.
	//
	//   v_saw        17 seqs + deploy/undeploy   -> svencoop   (draw 1.100)
	//                 9 seqs, no deploy          -> gearbox    (draw 1.000)
	//   v_shotgun    11 seqs + shoot_double      -> svencoop   (shoot1 1.050)
	//                10 seqs + shoot_big         -> valve      (shoot  1.000)
	//   v_357         reload(2.500)              -> svencoop
	//                 reload(3.056)              -> valve      <- the 0.556 s freeze
	//   v_9mmhandgun  reload_empty present       -> svencoop
	//                 reload_noshot present      -> valve
	//
	// A MISSING: entry on the svencoop-only or valve-only names is expected and
	// is how the pair is read; a miss on `draw` or `reload` is not.
	AI_ProbeModelSeqs("models/v_saw.mdl",
	                  "idle slowidle idle2 idle_fidget draw holster reload1 reload_start reload1_2 shoot shoot_1 deploy undeploy");
	AI_ProbeModelSeqs("models/v_shotgun.mdl",
	                  "sm_idle idle4 deepidle draw reholster shoot shoot1 shoot_big shoot_double reload reload_middle pump reload_end start_reload reload_start");
	AI_ProbeModelSeqs("models/v_357.mdl",
	                  "idle1 idle2 idle3 fidget1 fire1 reload draw holster");
	AI_ProbeModelSeqs("models/v_9mmhandgun.mdl",
	                  "idle1 idle2 idle3 shoot shoot_empty reload reload_noshot reload_empty draw holster");
	AI_ProbeModelSeqs("models/v_usp.mdl",
	                  "idle shoot1 shootlast reload draw add_silencer idle_unsil reload_unsil draw_unsil detach_silencer");
	// The pipe wrench and the OpFor knife: the *hit halves of their swing sets
	// are live now (they were unreachable — every call site hardcoded a miss),
	// so a miss here is a real one on either.
	AI_ProbeModelSeqs("models/v_pipe_wrench.mdl",
	                  "idle1 draw attack1hit attack1miss attack2hit attack2miss attack3hit attack3miss attackbigwind attackbigloop attackbighit attackbigmiss");
	// gearbox's v_knife spells its six swing takes INCONSISTENTLY and the QC index
	// table decodes it from the studio events rather than the labels — so probe the
	// names the model actually carries, not the roles:
	//     attack1(3)=HIT   attack1miss(4)=MISS
	//     attack2(5)=MISS  attack2hit(6)=HIT     <- reversed against attack1
	//     attack3(7)=MISS  attack3hit(8)=HIT
	AI_ProbeModelSeqs("models/v_knife.mdl",
	                  "idle1 idle2 draw attack1 attack1miss attack2 attack2hit attack3 attack3hit charge stab");
	// The mod's OWN Counter-Strike knife — not a mounted path, and not affected
	// by svencoop at all; its slash was cut at 70 % of a 1.200 s take.
	AI_ProbeModelSeqs("models/weapons/wpn_csknife/v_knife.mdl",
	                  "idle slash1 slash2 midslash1 midslash2 draw stab stab_miss");

	// v_m40a1.mdl (the OpFor sniper rifle, sh_wpn_opsniperrifle.qc).  Unlike
	// v_9mmar this one is invisible to a name-only probe: gearbox and svencoop
	// ship the SAME nine labels in the SAME order, so only the DURATIONS differ.
	// Read the draw:
	//   draw(1.000) reload1(2.324) reload2(1.778)  -> gearbox
	//   draw(0.517) reload1(2.683) reload2(1.250)  -> svencoop
	// Nothing is broken either way — the weapon resolves every duration through
	// SH_SeqDuration precisely so both are correct — but when a reload looks
	// mistimed in game, this line says which model you were actually looking at.
	AI_ProbeModelSeqs("models/v_m40a1.mdl",
	                  "draw slowidle fire firelastround reload1 reload2 reload3 slowidle2 holster");

	// The thirteen Counter-Strike 1.6 guns, for the same reason as the two CS
	// viewmodels above and with the same reading: a MISSING: entry is not fatal,
	// because every one of these files resolves through SH_SeqForName with a
	// hardcoded index as the fallback, but it is the difference between the gun
	// animating and the gun playing whatever sequence happens to sit at that
	// index on the mount that won.
	//
	// cstrike and czero BOTH ship all thirteen of these filenames, so which one
	// answers is decided purely by fs_addons.txt line order, and these lines are
	// the only place the build says which it was.  Two of them are worth reading
	// closely:
	//
	//   v_ump45  — czero's copy carries a SEVENTH sequence, shoot_empty, that
	//              cstrike's does not.  Both are correct; sh_wpn_csump45.qc asks
	//              for it by name and falls back to an ordinary shoot take when
	//              it is absent, so this line tells you which behaviour you have.
	//   v_tmp    — all THREE of its firing takes are labelled "shoot".
	//              frameforname returns the first, so sh_wpn_cstmp.qc resolves
	//              "shoot" once and derives the other two as base+1 / base+2.
	//              A have: list showing "shoot" once is correct, not a fault.
	AI_ProbeModelSeqs("models/v_p228.mdl",
	                  "idle1 shoot1 shoot2 shoot3 shoot_empty reload draw");
	AI_ProbeModelSeqs("models/v_fiveseven.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw");
	AI_ProbeModelSeqs("models/v_elite.mdl",
	                  "idle shoot_left1 shoot_leftlast shoot_right1 shoot_rightlast reload draw");
	AI_ProbeModelSeqs("models/v_tmp.mdl",
	                  "idle1 reload draw shoot");
	AI_ProbeModelSeqs("models/v_mac10.mdl",
	                  "idle1 reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_ump45.mdl",
	                  "idle1 reload draw shoot1 shoot2 shoot3 shoot_empty");
	AI_ProbeModelSeqs("models/v_p90.mdl",
	                  "idle reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_galil.mdl",
	                  "idle reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_famas.mdl",
	                  "idle reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_aug.mdl",
	                  "idle reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_sg552.mdl",
	                  "idle reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_sg550.mdl",
	                  "idle1 shoot shoot2 reload draw");
	AI_ProbeModelSeqs("models/v_xm1014.mdl",
	                  "idle shoot1 shoot2 insert after_reload start_reload draw");
	// THE SEVEN THAT MOVED TO THE MOUNT on 2026-08-30.  Each was driving a
	// mod-local IDPO (Quake-format) re-bake with hand-written frame ranges — which
	// is why they read as "the game version, not the mounted version" — and each
	// went sequence-driven with the path.  They belong in this probe for the same
	// reason the thirteen above do: every name below is resolved by NAME at
	// runtime, so a MISSING: entry means that gun is animating off a fallback
	// index measured from a different model.
	//
	// The AWP's ORDER is not the AK's: it puts shoot1..3 at 1-3 and reload/draw at
	// 4-5, which is exactly the kind of divergence the fallbacks cannot survive
	// and the names can.  The Scout labels BOTH its shoot takes "shoot", so only
	// one is probed — SH_SeqForName resolves either request to the first, and the
	// pair is frame-identical.  The M4A1 carries the silenced set at 0-6 and the
	// whole unsilenced set again at 7-13, so both halves are named.
	AI_ProbeModelSeqs("models/v_ak47.mdl",
	                  "idle1 reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_mp5.mdl",
	                  "idle1 reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_awp.mdl",
	                  "idle1 reload draw shoot1 shoot2 shoot3");
	AI_ProbeModelSeqs("models/v_m249.mdl",
	                  "idle1 reload draw shoot1 shoot2");
	AI_ProbeModelSeqs("models/v_scout.mdl",
	                  "idle1 reload draw shoot");
	AI_ProbeModelSeqs("models/v_m3.mdl",
	                  "idle shoot1 shoot2 insert after_reload start_reload draw");
	AI_ProbeModelSeqs("models/v_m4a1.mdl",
	                  "idle reload draw shoot1 shoot2 shoot3 add_silencer");
	AI_ProbeModelSeqs("models/v_m4a1.mdl",
	                  "idle_unsil reload_unsil draw_unsil shoot1_unsil shoot2_unsil shoot3_unsil detach_silencer");

	// The twelve Day of Defeat view models.  Read exactly like the CS thirteen
	// above -- every one resolves its sequences by name through SH_SeqForName
	// with a measured index as the fallback, so a MISSING: entry means the gun
	// is animating off the fallback and may be playing the wrong take.
	//
	// The DURATIONS are the more useful half here, because DoD's model set is
	// one of the most heavily replaced in GoldSrc and a custom v_garand.mdl with
	// the right labels at the wrong lengths is exactly the case a name-only
	// probe cannot see.  The shipped numbers are in each weapon file's header.
	// empty_idle is probed on the eight weapons that now select it — the model
	// carries a bolt-open / slide-locked rest pose and every one of these used to
	// rest closed on an empty magazine.  Probing it means a mount that lacks the
	// take is REPORTED rather than silently falling back to the loaded index.
	AI_ProbeModelSeqs("models/v_colt.mdl",
	                  "idle empty_idle shoot1 shoot2 shoot_empty reload reload_noshoot draw");
	AI_ProbeModelSeqs("models/v_luger.mdl",
	                  "idle empty_idle shoot shoot_empty reload reload_empty draw");
	AI_ProbeModelSeqs("models/v_webley.mdl",
	                  "idle shoot reload draw");
	AI_ProbeModelSeqs("models/v_garand.mdl",
	                  "idle empty_idle shoot1 shoot2 shoot3 shoot_empty reload draw draw_empty smash smash_empty");
	AI_ProbeModelSeqs("models/v_m1carbine.mdl",
	                  "idle reload draw shoot");
	AI_ProbeModelSeqs("models/v_k43.mdl",
	                  "idle empty_idle shoot1 shoot2 reload draw smash");
	AI_ProbeModelSeqs("models/v_tommy.mdl",
	                  "idle empty_idle reload draw shoot1 shoot2");
	AI_ProbeModelSeqs("models/v_mp40.mdl",
	                  "idle empty_idle reload draw shoot1 shoot2");
	AI_ProbeModelSeqs("models/v_sten.mdl",
	                  "idle reload draw shoot");
	AI_ProbeModelSeqs("models/v_greasegun.mdl",
	                  "idle empty_idle reload draw shoot1 shoot2");
	AI_ProbeModelSeqs("models/v_mp44.mdl",
	                  "idle empty_idle reload draw shoot1 shoot2");
	// BOTH halves now.  down_* is the bipod-deployed set and it IS wired --
	// +attack2 plants the BAR through the shared .wep_deployed stance.
	AI_ProbeModelSeqs("models/v_bar.mdl",
	                  "up_idle up_reload up_draw up_shoot up_to_down down_idle down_reload down_shoot down_to_up");

	// Day of Defeat, second batch.  Every one of these resolves BY NAME in its
	// weapon file, so a MISSING: entry means the fallback index is being used
	// against a table it was never measured from — the same class of bug the
	// shield block below exists to catch, not a cosmetic miss.
	// The UNSCOPED K98 moved onto the mount on 2026-08-30 (it was the last DoD
	// weapon shipping a mod-local view model, and that copy was a Quake MDL with
	// no sequences at all), so it belongs in this list now.
	AI_ProbeModelSeqs("models/v_98k.mdl",
	                  "idle shoot reload draw stab stabslash");
	AI_ProbeModelSeqs("models/v_scoped98k.mdl",
	                  "idle shoot reload draw stab stabslash");
	AI_ProbeModelSeqs("models/v_spring.mdl",
	                  "idle shoot1 shoot2 reload draw empty_idle");
	// reload AND reload_long -- the Enfield picks between them off the magazine.
	AI_ProbeModelSeqs("models/v_enfield_scoped.mdl",
	                  "idle shoot reload reload_long draw");
	// BOTH halves, and the belt brackets with them.  The bipod set IS wired now
	// (+attack2 plants the gun through the shared .wep_deployed stance) and so are
	// the ten belt-count variants -- SH_DodMGBeltSuffix builds the name and
	// SH_SeqForName2 falls back to the base take, so a MISSING: on a suffixed name
	// is not fatal, but it does mean that gun's belt never shrinks.
	//
	// One bracket from each family is probed rather than all ten: they are
	// generated as a set by the artist, so if `upidle8` is there `upidle7` is too,
	// and the empty end is the one worth naming because it is the one a player
	// sees at the moment the gun runs dry.
	//
	// THE MG34 SPELLS ITS BRACKET DIFFERENTLY -- `_empty` with an underscore
	// against the belt pair's `empty` -- and has no numbered set at all, which is
	// exactly what SH_DodMGBeltSuffix branches on.
	AI_ProbeModelSeqs("models/v_30cal.mdl",
	                  "upidle upshoot downtoup uptodown downidle downshoot reload upidle8 upidleempty downtoupempty uptodownempty");
	AI_ProbeModelSeqs("models/v_mg34.mdl",
	                  "upidle upshoot downtoup uptodown downidle downshoot reload upidle_empty downidle_empty downtoup_empty uptodown_empty");
	AI_ProbeModelSeqs("models/v_mg42.mdl",
	                  "upidle upshoot downtoup uptodown downidle downshoot reload upidle8 upidleempty downtoupempty uptodownempty");
	// The shouldered set IS wired now (aimed / down_to_up / up_to_down drive the
	// +attack2 pose), so it is probed.  reload_aimed still is not — see the note
	// in sh_wpn_dodat.qc about the Panzerschreck's two reloads having different
	// durations.  The PIAT's two `_empty` SHOULDER TRANSITIONS are wired now and
	// probed below; its idle_empty / draw_empty / aimed_empty remain unwired and
	// unprobed.  The bazooka and Panzerschreck carry no `_empty` art at all (8
	// sequences each), which is why the lookup is name-first-with-fallback.
	AI_ProbeModelSeqs("models/v_bazooka.mdl",
	                  "idle draw launch reload_idle aimed down_to_up up_to_down");
	AI_ProbeModelSeqs("models/v_panzerschreck.mdl",
	                  "idle draw launch reload_idle aimed down_to_up up_to_down");
	AI_ProbeModelSeqs("models/v_piat.mdl",
	                  "idle draw launch reload_idle aimed down_to_up up_to_down down_to_up_empty up_to_down_empty");
	// Day of Defeat, third batch.  The Bren and the two FG42s use the BAR's
	// up_* naming (sh_wpn_dodauto.qc); the mortar's names are its own and
	// index 0 on that model is `round_up`, not an idle, which is why every
	// fallback in that file is named explicitly.
	// The full nine on all three: the down_ bipod half is wired now (see the
	// header retraction in sh_wpn_dodauto.qc), so the probe has to cover it or a
	// mount whose copy lacks a take fails silently into an index fallback.
	AI_ProbeModelSeqs("models/v_bren.mdl",
		"up_idle up_reload up_draw up_shoot up_to_down down_idle down_reload down_shoot down_to_up");
	AI_ProbeModelSeqs("models/v_fg42.mdl",
		"up_idle up_reload up_draw up_shoot up_to_down down_idle down_reload down_shoot down_to_up");
	AI_ProbeModelSeqs("models/v_scopedfg42.mdl",
		"up_idle up_reload up_draw up_shoot up_to_down down_idle down_reload down_shoot down_to_up");
	AI_ProbeModelSeqs("models/v_fcarb.mdl",      "idle reload draw shoot");
	AI_ProbeModelSeqs("models/v_enfield.mdl",    "idle shoot reload reload_long draw stab");
	// The mortar's emplaced set is wired now: +attack2 (or weapon-special) plants
	// it with up_to_down, idle_down is the planted rest, round_up runs by itself
	// as the prepare take and ends on idle_ready, and packing up is round_down
	// then down_to_up.  ALL NINE are live — round_down included, which the note
	// here used to say stayed unwired.
	AI_ProbeModelSeqs("models/v_mortar.mdl",
	                  "idle_up idle_ready fire round_up round_down draw up_to_down idle_down down_to_up");
	AI_ProbeModelSeqs("models/v_binoculars.mdl", "idle_down down_to_up idle_up up_to_down draw");
	AI_ProbeModelSeqs("models/v_amerk.mdl",     "idle slash1 slash2 draw");
	AI_ProbeModelSeqs("models/v_fairbairn.mdl", "idle slash1 slash2 draw");
	AI_ProbeModelSeqs("models/v_paraknife.mdl", "idle slash1 slash2 draw");
	AI_ProbeModelSeqs("models/v_spade.mdl",     "idle slash1 slash2 draw");
	// The two grenades, INCLUDING the exploding_* set -- those are wired (they
	// are the pose for a grenade whose pin is already out), so a miss there is a
	// real one.  Note `pinpull`, DoD's spelling, against Counter-Strike's
	// `pullpin`: sh_wpn_csgrenades.qc tries both.
	AI_ProbeModelSeqs("models/v_mills.mdl",
	                  "idle draw pinpull throw exploding_pinpull exploding_throw");
	AI_ProbeModelSeqs("models/v_stick.mdl",
	                  "idle draw pinpull throw exploding_pinpull exploding_throw");

	// The nine tactical-shield combined view models.  These are read differently
	// from every line above: shared/weapons/sh_wpn_csshield.qc resolves ALL of
	// their sequences by name, so a MISSING: entry here is not the cosmetic
	// "falls back to a hardcoded index" it is for the guns — it means the fallback
	// index is being used against a table it was never measured from, which is
	// precisely the class of bug this block was added to catch.
	//
	// READ THEM AS THREE GROUPS, because they are three different layouts and
	// only shield_up / shield_idle / shield_down are common to all nine:
	//
	//   5 pistols   9 seqs   idle1 shoot1 shoot2 shoot_empty reload draw + the 3
	//   knife       7 seqs   idle slash hit deploy           + the 3
	//   3 grenades  7 seqs   idle1 pullpin throw draw        + the 3
	//
	// A pistol line missing `shoot_empty`, or a grenade line missing `pullpin`,
	// means the shield model on this mount is not the one the resolver expects.
	AI_ProbeModelSeqs("models/shield/v_shield_usp.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_glock18.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_deagle.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_p228.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_fiveseven.mdl",
	                  "idle1 shoot1 shoot2 shoot_empty reload draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_knife.mdl",
	                  "idle slash hit deploy shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_hegrenade.mdl",
	                  "idle1 pullpin throw draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_flashbang.mdl",
	                  "idle1 pullpin throw draw shield_idle shield_up shield_down");
	AI_ProbeModelSeqs("models/shield/v_shield_smokegrenade.mdl",
	                  "idle1 pullpin throw draw shield_idle shield_up shield_down");
};

// ---------------------------------------------------------------------------
// model warm-up
// ---------------------------------------------------------------------------
// SVPR_GetCModel (server/pr_cmds.c:590) loads a model lazily and BLOCKS while it
// does.  The first frameforaction on a class therefore pays a disk load, and if
// that first call happens when a squadmaker wave spawns, the whole server stalls
// mid-fight.  Touching each AI class's model during worldspawn moves that cost
// to map load, where a hitch is invisible.
// Every sound an EVENT_SOUND names anywhere in this model, precached at map load.
//
// This closes a whole class of bug rather than one instance of it.  A sound
// played through sound() without a precache does not work, and the sounds a model
// wants are written inside the MODEL, not in any QC list - so the only reliable
// way to know them is to ask the model.  Doing it by hand per class means every
// future monster gets one chance to forget, and the symptom is silence, which
// nobody notices.
//
// getmodeleventidx range-checks both the sequence and the event index and returns
// FALSE past the end, so the double loop needs no separate bounds.
void(float mi) AI_PrecacheModelSounds =
{
	if (mi <= 0)
		return;

	float nseq = modelframecount(mi);
	float s, e, found = 0;
	float ts; int code; string edata;

	for (s = 0; s < nseq; s = s + 1)
	{
		for (e = 0; e < AI_EVENT_MAX; e = e + 1)
		{
			if (!getmodeleventidx(mi, s, (int)e, ts, code, edata))
				break;
			// EVENT_SOUND_SVEN belongs in this list and its absence is why every
			// Opposing Force monster was mute: the play site would have been fine,
			// but sound() on an unprecached file is silently dropped, so adding the
			// handler without adding the harvest fixes nothing.
			if ((float)code != EVENT_SOUND
			 && (float)code != EVENT_SOUND_VOICE
			 && (float)code != EVENT_SOUND_SVEN)
				continue;
			if (edata == "" || !edata)
				continue;
			precache_sound(AI_EventSoundName(edata));
			found = found + 1;
		}
	}

	if (found && ai_cached_debug)
		dprint(sprintf("[ai] precached %g event sound(s) from modelindex %g\n", found, mi));
};

void(string mdl) AI_WarmModel =
{
	if (mdl == "" || !mdl)
		return;
	float mi = getmodelindex(mdl);
	if (mi <= 0)
		return;
	modelframecount(mi);	// forces the load; return value deliberately unused

	// While the model is loaded and we are still at worldspawn, which is the only
	// place precache_sound may be called.
	AI_PrecacheModelSounds(mi);
};

// ---------------------------------------------------------------------------
// PATCH 155: animation playback rate over the wire  (sv_animrate_selftest)
// ---------------------------------------------------------------------------
// The other half of the reverse-playback work, and the half that cannot be
// checked from the server at all.
//
// mon_tentacle.qc's self-test proves the SERVER decides to reverse a link and
// sets .animrate accordingly.  It cannot prove the value crossed the wire, and
// the tentacle is a bad witness for that anyway: a headless client spawns at the
// map's start point and hl_c05_a2's tentacle silo is nowhere near it, so no
// entity update for a tentacle is ever sent.  Measured - the client log for a
// 150 s run contained zero tentacle entities.
//
// So this puts a witness where the client is guaranteed to be looking: an HL
// model spawned ON A CONNECTED PLAYER, playing a real sequence BACKWARDS.  Run
// it under hlclient.sh and the client's own "[animrate] ent N: REVERSE -1" line
// is the end-to-end proof, engine to engine.
//
// ON THE PLAYER, not at info_player_start, and that distinction is the whole
// test.  The first version used the spawn point and reported a clean BAD=0 while
// the client log stayed empty: hl_c05_a2's info_player_start is at
// -792 -927 -1457 and players actually arrive some 8000 units away, so the
// witness was never in anyone's PVS and was never sent.  A test that cannot fail
// is worse than no test.
//
// Deliberately NOT solid and NOT damageable - it is scenery for the duration of
// the run and must not block the player it stands next to.
float animrate_test_done;

void() AI_AnimRateSelfTest =
{
    if (!cvar("sv_animrate_selftest") || animrate_test_done)
        return;

    // Wait for a real client.  This hook runs every frame, so returning early is
    // how the test waits; without the latch below it would spawn one witness per
    // frame, which the first version did (the log carried hundreds of them).
    entity p = find(world, classname, "player");
    if (!p)
        return;

    // scientist.mdl is in every GoldSrc install and its walk cycle is long
    // enough that a reversed play is unmistakable by eye as well as in the log.
    string mdl = "models/scientist.mdl";
    float  mi  = getmodelindex(mdl);
    if (mi <= 0)
    {
        print(sprintf("[animratetest] BAD %s not loadable\n", mdl));
        animrate_test_done = 1;
        return;
    }

    // Resolve by NAME and say which one won, because a silently-failed lookup
    // falling back to sequence 0 is exactly how the first version came to report
    // seq 0 as "walk".  Pit_Idle-style single-frame sequences cannot show a
    // reversal at all, so landing on one by accident would hide a real failure.
    string sname = "walk";
    float  seq   = frameforname(mi, sname);
    if (seq < 0) { sname = "walk1";  seq = frameforname(mi, sname); }
    if (seq < 0) { sname = "run";    seq = frameforname(mi, sname); }
    if (seq < 0) { sname = "idle1";  seq = frameforname(mi, sname); }
    if (seq < 0)
    {
        print(sprintf("[animratetest] BAD no usable sequence on %s\n", mdl));
        animrate_test_done = 1;
        return;
    }

    entity w = spawn();
    w.classname = "animrate_selftest_witness";
    setmodel(w, mdl);
    setorigin(w, p.origin + '0 0 8');
    w.angles     = p.angles;
    w.solid      = SOLID_NOT;
    w.movetype   = MOVETYPE_NONE;
    w.takedamage = DAMAGE_NO;
    w.frame      = seq;

    // -1 exactly, not a jittered value: this is a wire test, and a round number
    // is what makes the client's report unambiguous.
    w.animrate = -1;

    animrate_test_done = 1;
    print(sprintf("[animratetest] witness on player at %v seq %g (\"%s\") animrate %g BAD=0\n",
                  w.origin, seq, sname, w.animrate));
};
