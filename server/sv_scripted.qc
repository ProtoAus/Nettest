// server/sv_scripted.qc
// ----------------------------------------------------------------------------
// scripted_sequence / aiscripted_sequence — Half-Life's CCineMonster.
//
// This is the entity that puts barney in the chair.
//
// Every bit of choreography in a Half-Life or Sven campaign map runs through
// this one class: NPCs walking a patrol, leaning on a console, sitting at a
// desk, arguing in a corridor, turning to look at the player as he goes past.
// Measured over the 233-map corpus, 2019 of them; on hl_c01_a1 alone, 95 - and
// that map contains ZERO path_corner, so scripted_sequence is not part of the
// choreography system, it IS the choreography system.
//
// Until now it was a 0.5 s relay: it fired its target chain and touched no
// monster at all.  That is why the map read as a room full of statues.  Some of
// that was even correct - a monster carrying SF_MON_WAIT_FOR_SCRIPT (128) is
// SUPPOSED to stand still until a script claims it - but with nothing ever
// claiming anything, correct and broken looked identical.
//
// HOW POSSESSION WORKS, and it is worth reading because the shape is not obvious:
//
//   1. CLAIM.  The script finds its monster (by targetname, or by classname
//      inside m_flRadius) and takes it away from its own AI entirely.  The
//      monster enters MS_SCRIPT and from that moment AI_SelectSchedule's gate
//      hands it nothing but this file's schedules.
//   2. GET TO THE MARK, per m_fMoveTo: 0 stay, 1 walk, 2 run, 4 teleport,
//      5 stay but turn to face the script's angles.
//   3. HOLD m_iszIdle, looping, until the script is triggered.  This is where
//      the opening of Half-Life spends its entire time.
//   4. PLAY m_iszPlay once, fire the target chain, release the monster.
//
// WHICH SCRIPTS CLAIM AT MAP START.  Half-Life's rule (scripted.cpp, Spawn) is
// "no targetname OR has an m_iszIdle", and it is the rule that decides whether a
// map opens with a tableau or with a room of idle NPCs.  On hl_c01_a1 it selects
// exactly 7 of the 95: barneyatdesk, leaningbarney, airlockbarney,
// introroomleaner, coffee, and the arguing pair argumentg/arguments.  That list
// IS the opening of Half-Life.
//
// AND WHICH NEVER AUTO-PLAY.  m_fMoveTo 4 pushes the start time out of reach
// (scripted.cpp PossessEntity, case 4) even for a script with no targetname.
// That single line is why barneyatdesk sits at his desk for as long as you leave
// him there instead of standing up one second after the map loads - and it took
// reading the case to see it, because "no targetname means start immediately" is
// the rule everywhere else.
//
// THE ONE INVARIANT THAT OUTRANKS FIDELITY: a script must never be able to hang
// a campaign.  Possession takes a monster away from its own AI, so every failure
// mode in here - monster not found, mark unreachable, sequence name absent from
// the model, actor shot mid-scene, sequence that never ends - has an explicit
// path back out that ALSO fires the target chain.  Each one is counted, so
// "worked" and "gave up safely" are different numbers in the report rather than
// the same silence.
// ----------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// keys
// ---------------------------------------------------------------------------
// DECLARED IN LOWERCASE, and that is load-bearing rather than a style choice.
// ED_FindField is a plain strcmp (qclib/pr_edict.c:293), so a CamelCase
// declaration binds only for compilers that emit CamelCase.  The corpus is split
// - Hammer emits m_iszEntity, other tools emit m_iszentity - and the case-folding
// fallback in ED_ParseUnknownEpair (sv_multi_manager.qc:412) only searches for a
// LOWERCASE field.  So a lowercase declaration serves both spellings and a
// CamelCase one serves half the corpus.  The old `.string m_iszEntity` in
// sv_goldsrc_compat.qc was the CamelCase kind; it is gone.
// m_iszentity is declared in sv_customdefs.qc (compile position 15) rather than
// here, because scripted_SENTENCE shares it and the hook that fills it in for
// that class - ED_ParseUnknownEpair, in sv_multi_manager.qc at position 112 -
// compiles well before this file.  Same reason the game_text keys live there.
.string m_iszplay;		// the action sequence, by name
.string m_iszidle;		// the hold pose, by name; also decides claim-at-spawn
.float  m_fmoveto;		// 0 none, 1 walk, 2 run, 4 instant, 5 turn to face
.float  m_flradius;		// classname search radius (targetname search ignores it)
.float  m_flrepeat;		// parsed, unused - see the note in Script_Spawn
// moveto_radius (Sven's arrival tolerance) is the one key declared elsewhere -
// in sv_ai_defs.qc, because the task interpreter reads it and compiles first.

// Half-Life scripted_sequence spawnflags (scripted.cpp).  Corpus frequencies are
// on each line, because they say which of these are worth honouring: 96
// (NOINTERRUPT|OVERRIDESTATE) is the single commonest value at 355, and plain 4
// (REPEATABLE) is next at 295.
const float SF_SCRIPT_WAITTILLSEEN     = 1;	// parsed, not implemented
const float SF_SCRIPT_EXITAGITATED     = 2;	// leave the scene alert and provoked
const float SF_SCRIPT_REPEATABLE       = 4;	// may be triggered again afterwards
// 8 chooses between Half-Life's two endings for a body the script killed
// (scripted.cpp:828-836): clear use/think/touch and leave it forever, or
// SUB_StartFadeOut.  BOTH arms land on "permanent" in this tree, so the flag is
// honoured by being a no-op — and that is a fact worth writing down rather than a
// gap.  There is no corpse fade here at all: SF_MON_FADE_CORPSE (sv_ai_defs.qc)
// is declared and read by nothing, and AI_Died leaves every body in the world.
// HL's SetUse/SetThink/SetTouch NULL needs no counterpart either — the talker's
// use gate already refuses a dead body (sv_ai_talk.qc) and .ai_dead_done stops
// the corpse thinking.  13 of the 491 th_* scripts set this; when a fade does
// exist, this is the flag it hangs off.
const float SF_SCRIPT_LEAVECORPSE      = 8;	// see above: no-op, correctly
const float SF_SCRIPT_NOINTERRUPT      = 32;	// damage cannot break this scene
const float SF_SCRIPT_OVERRIDESTATE    = 64;	// parsed, not implemented
const float SF_SCRIPT_NOSCRIPTMOVEMENT = 128;	// no-op here: we do not extract
						// root motion from the animation
						// in the first place

// ---------------------------------------------------------------------------
// per-script runtime
// ---------------------------------------------------------------------------
.entity ss_mon;			// the monster we have possessed, world if none
.float  ss_started;		// time the play phase may begin; 0 = not armed
.float  ss_watchdog;		// force-finish deadline while playing; 0 = not playing
.float  ss_spent;		// finished and not repeatable: never claim again
.float  ss_claiming;		// still trying to find its monster
.float  ss_tries;		// how many times it has tried
.float  ss_ai;			// this is an aiscripted_sequence
// The possessed actor has NO AI and is driven straight from this entity's think.
// monster_gman, monster_sitting_scientist and the whole *_dead family are built
// by mon_corpses.qc as posed bodies rather than as monsters - which is correct,
// because in Half-Life the G-Man has no attacks and gman.mdl carries only IDLE
// and WALK.  He moves ONLY under scripted_sequence control, and all 36 of his
// corpus placements carry a targetname for exactly that reason.  A script layer
// that could not pose him would miss the one thing he exists for.
.float  ss_body;
.float  ss_bodyend;		// when the body's current sequence finishes

// How many misses before the claim retry says so out loud.  NOT a give-up: it
// used to be one, and that was wrong - a name that has not appeared in nine
// minutes is very often a squadmaker that has yet to fire, which is precisely
// pizza_ya_san1's four seated customers and its `mi`.  Half-Life never gives up
// (dlls/scripted.cpp:476-489) and neither do we; this is only the point at which
// a still-unresolved script earns one line in the log.
const float SCRIPT_CLAIM_TRIES = 120;

// The force-finish deadline.  No legitimate Half-Life animation is anywhere near
// this long (the longest in the campaign models is barney's 251-frame sit1, at
// 12.5 s, and that one is a LOOP that is never used as an action), so anything
// that reaches this has genuinely stopped advancing.
const float SCRIPT_PLAY_MAX = 30;

// ---------------------------------------------------------------------------
// counters
// ---------------------------------------------------------------------------
// The plan asked for scripts claimed, scripts completed and monsters actually
// moved as THREE SEPARATE NUMBERS, and that is exactly right: this programme has
// twice shipped code where the selections were perfect and the actions never
// happened (bigmomma's births, the grunt's grenades).  A scripted scene is even
// easier to get wrong that way, because a claimed monster standing in a pose and
// a claimed monster stuck in a wall look identical from a log.
//
// ai_dbg_script_stuck lives in sv_ai_core.qc - the interpreter increments it.
float ai_dbg_script_claimed;	// possessions that succeeded
float ai_dbg_script_moved;	// monsters that walked/ran to a mark and arrived
float ai_dbg_script_played;	// play phases actually started
float ai_dbg_script_done;	// scenes that finished and fired their chain
float ai_dbg_script_lost;	// triggered with no monster to be found
float ai_dbg_script_noseq;	// sequence names the model does not carry
float ai_dbg_script_forced;	// watchdog force-finishes
float ai_dbg_script_died;	// scenes whose actor died on a 1000 event

// Boot census, printed once.  "How many scripts are on this map and how many of
// them claim an actor at spawn" is the number that says whether the opening
// tableau can possibly work, and it is knowable before anything has happened -
// which makes it the first thing to check when a map opens wrong.
float script_dbg_total, script_dbg_atspawn, script_dbg_census;
// (ai_dbg_script_stuck and ai_dbg_script_broke are declared in sv_ai_core.qc:
// the interpreter and the damage/death paths increment them, and that file
// compiles first.)

void() Script_LostFinish;	// the soft-lock guard's think, referenced above it

// ---------------------------------------------------------------------------
// finding the monster
// ---------------------------------------------------------------------------
// Two kinds of actor can be possessed and they are driven by different machinery.
//
//   `think == AI_Think`  a real monster.  Possession goes through the schedule
//                        system: it can walk to its mark, turn, and be gathered
//                        back into its own AI when the scene ends.
//   anything else        a posed body from mon_corpses.qc.  It has no schedules,
//                        no conditions and no think of its own, so the SCRIPT
//                        drives it directly - see Script_BodyTick.
//
// Telling them apart by the think function rather than by FL_MONSTER is what
// makes that split reliable: both carry FL_MONSTER and both sit on the monster
// chain, and a script that fed a body into the schedule system would claim it,
// report success, and then never move it.
float(entity s, entity m) Script_Claimable =
{
	if (!m)
		return FALSE;
	// Already owned by another script.  Half-Life allows a by-NAME script to steal
	// a monster from an idle script; not doing so costs nothing here (no corpus map
	// relies on it) and stealing is the sort of thing that turns two working scenes
	// into one broken one.
	if (m.ai_script && m.ai_script != s)
		return FALSE;
	if (m.modelindex <= 0)
		return FALSE;		// nothing to pose

	if (m.think == AI_Think)
	{
		if (m.health <= 0 || m.ai_state == MS_DEAD)
			return FALSE;
		return TRUE;
	}

	// A posed body.  No liveness test: monster_hgrunt_dead is a corpse by
	// definition and is still a perfectly good thing to point a script at, which
	// several maps do to arrange a scene before the player arrives.
	return TRUE;
};

// Resolve a sequence name on a body.  Same bounds care as AI_SetSequenceNamed:
// frameduration silently clamps an out-of-range index to sequence 0 and hands
// back a plausible-looking duration, so a bad index would produce a believable
// timer for the wrong animation.
float(entity m, string nm) Script_BodySeq =
{
	if (nm == "" || !nm || m.modelindex <= 0)
		return -1;
	float seq = frameforname(m.modelindex, nm);
	if (seq < 0 || seq >= modelframecount(m.modelindex))
		return -1;
	return seq;
};

// Half-Life's search, in its two distinct halves (scripted.cpp FindEntity).
//
// THE TARGETNAME PASS IGNORES m_flRadius COMPLETELY.  That is not an oversight in
// HL and it is not one here: a named actor is named, and the radius key exists
// only to bound the classname fallback.  It matters in practice - hl_c01_a1's
// pondering scripts all carry m_flRadius 4098 while naming `study` by targetname,
// so the radius is decoration on every one of them.
//
// The classname pass is the one that needs the radius, because "monster_scientist"
// on a map with twenty-eight of them would otherwise grab whichever the edict
// order happened to put first.  Nearest wins.
entity(entity s) Script_FindMonster =
{
	string want = s.m_iszentity;
	if (want == "" || !want)
		return world;

	entity e;

	e = monster_chain_head;
	while (e)
	{
		if (e.targetname == want && Script_Claimable(s, e))
			return e;
		e = e.monster_chain_next;
	}

	// FGD default rather than Half-Life's literal 0.  A missing m_flRadius means
	// HL's classname sphere has radius zero and finds nothing at all, which is a
	// silent no-op; 512 is what the FGD tells mappers they are getting and what
	// 1507 of the corpus's 1906 radius keys say explicitly.
	float rad = s.m_flradius;
	if (rad <= 0)
		rad = 512;

	entity best = world;
	float  bestd = rad;

	e = monster_chain_head;
	while (e)
	{
		if (e.classname == want && Script_Claimable(s, e))
		{
			float d = vlen(e.origin - s.origin);
			if (d <= bestd)
			{
				bestd = d;
				best  = e;
			}
		}
		e = e.monster_chain_next;
	}
	return best;
};

// ---------------------------------------------------------------------------
// starting sequences
// ---------------------------------------------------------------------------
// The hold pose.  Called at possession time AND from the wait task every tick:
// the first so a monster claimed while the player is far away is already posed
// (it may be dormant and never run a schedule), the second so a monster knocked
// out of its sequence goes back into it.  AI_SetSequenceNamed is idempotent on
// the name, so the repeat costs a string compare.
void(entity m) Script_StartIdle =
{
	entity s = m.ai_script;
	if (!s)
		return;

	if (s.m_iszidle != "" && s.m_iszidle)
	{
		if (AI_SetSequenceNamed(m, s.m_iszidle, TRUE))
			return;
		// The model does not carry that name.  Not hypothetical and not rare: this
		// map's own enterbarney2/enterbarney3 ask for "sit2" and "sit3", and NEITHER
		// Valve's barney.mdl NOR Sven's replacement has them - only sit1.  Falling
		// back to a plain idle keeps the monster animating instead of freezing it on
		// frame 0, and the counter says how often a map is asking for poses the
		// installed models cannot strike.
		if (m.ai_seqname != s.m_iszidle)
			ai_dbg_script_noseq = ai_dbg_script_noseq + 1;
	}
	AI_SetActivity(m, ACT_IDLE);
};

// The action.  Anything that cannot play - no name, or a name the model lacks -
// is turned into "already finished" rather than into an error, by seating the
// sequence end at now.  The task then completes on its next poll and the chain
// fires through the ordinary path, which is exactly Half-Life's own
// completeOnEmpty behaviour (scripted.cpp StartSequence) and also the safest
// possible failure.
void(entity m) Script_StartPlay =
{
	entity s = m.ai_script;
	if (!s)
		return;

	s.ss_watchdog = time + SCRIPT_PLAY_MAX;
	ai_dbg_script_played = ai_dbg_script_played + 1;

	if (s.m_iszplay == "" || !s.m_iszplay)
	{
		m.ai_seqend = time;
		return;
	}

	// Force the restart.  AI_SetSequenceNamed is idempotent on the name, and a
	// script whose play sequence IS its idle sequence (Half-Life has several, and
	// handles the case by freezing the framerate) would otherwise get TRUE back
	// without a new end time - leaving a one-shot task parked on a looping
	// sequence until the watchdog fires.
	AI_ResetActivity(m);

	if (!AI_SetSequenceNamed(m, s.m_iszplay, FALSE))
	{
		ai_dbg_script_noseq = ai_dbg_script_noseq + 1;
		dprint(sprintf("[script] \"%s\": %s has no sequence \"%s\"\n",
		               s.targetname, m.classname, s.m_iszplay));
		m.ai_seqend = time;
	}
};

// ---------------------------------------------------------------------------
// the actor died in the scene
// ---------------------------------------------------------------------------
// Half-Life's CineCleanup DEAD_DYING branch (scripted.cpp:818-841), reached when
// m_iszPlay raised SCRIPT_EVENT_DEAD (1000) part-way through — which is how a
// choreographed death is authored: the ANIMATION says when the character dies,
// not the map.  Nine scripted_sequences across the th_* corpus play such a
// sequence (sstruggle on four scientists, draghole on three hgrunts,
// fall_elevator on th_ep1_03's lavaman), and every one of them used to finish its
// death animation and then stand back up at full health.
//
// This is NOT AI_Died and must not become it.  Half-Life's own comment on the
// line is "BUGBUG -- This doesn't call Killed()", and the omission is correct
// here for three separate reasons:
//   * no death ANIMATION.  The sequence that just played WAS the death and the
//     body has to hold its last frame.  AI_Died routes through SCHED_DIE, whose
//     TASK_PLAY_DEATH would overwrite the pose with diesimple.
//   * no death VOICE.  The scene's own 1008 events carry the lines it wants.
//   * no weapon drop.  th_ep2_01's holegrunt is dragged into a vent; leaving an
//     MP5 on the floor where he vanished is not the scene.
// So the shared part — AI_BecomeCorpse — is called directly and nothing else.
void(entity m) Script_DieInPlace =
{
	ai_dbg_script_died = ai_dbg_script_died + 1;

	// FREEZE THE POSE.  Half-Life spells this `pev->framerate = 0` plus
	// StopAnimation(); here it is already done for us — Script_Release cleared
	// .ai_seqname and called AI_ResetActivity, which sets .ai_seq = -1, and
	// AI_AnimPump returns immediately on that.  .frame is never touched by either,
	// and FTE does not wrap a non-looping HL sequence, so the body simply holds the
	// final frame with no extra work and nothing new on the wire.
	//
	// MOVETYPE IS DELIBERATELY LEFT ALONE, and this is the one place this function
	// refuses to follow CineCleanup.  Half-Life sets MOVETYPE_NONE, which freezes
	// th_ep1_03's `lavaman` in mid-air over the pit at the end of fall_elevator;
	// the un-ground test in Script_Release exists precisely to stop that (see its
	// comment) and it is worth more than the fidelity.  A corpse on MOVETYPE_STEP
	// falls, exactly as AI_Died's corpses do.
	AI_StopMoving(m);
	AI_PathClear(m);

	// Kill any looping sample the class started at spawn, same reason and same two
	// lines as AI_Died: TASK_DIE is where that normally happens and this path never
	// reaches it.
	if (m.ai_snd_loop != "")
	{
		AI_SoundEx(m, m.ai_snd_loopchan, m.ai_snd_loop, 0, ATTN_NORM, 100, SOUNDFLAG_FOLLOW);
		m.ai_snd_loop = "";
	}

	AI_BecomeCorpse(m);

	m.ai_state = MS_DEAD;
	m.ai_enemy = world;
	m.ai_cond  = COND_NONE;
	// THE LATCH, and without it the rest of this function is undone one tick later:
	// AI_SelectSchedule hands a MS_DEAD monster SCHED_DIE until .ai_dead_done is
	// set, and SCHED_DIE's TASK_PLAY_DEATH would replace the held pose with an
	// ordinary death animation.  Set here rather than in TASK_DIE because for this
	// path the death HAS finished animating — that is what the 1000 event meant.
	m.ai_dead_done = TRUE;

	// Hand the squad slot, the nav slot and the monster chain back, exactly as
	// Monster_Killed does before AI_Died.  A scripted death is still a death:
	// without this a th_ep2_01 vent grunt would pin its squadmaker's child budget
	// forever.  Idempotent, so a later remove() or a shot into the corpse can call
	// it again.
	Monster_Teardown(m);
};

// ---------------------------------------------------------------------------
// release
// ---------------------------------------------------------------------------
// The single way out of a scene, from all five directions: completion, damage,
// death, the watchdog, and the script entity vanishing underneath the monster.
// Having one exit is what makes the state safe to reason about - there is no
// path that clears half of it.
//
// `firechain` fires the script's target chain on the way out.  Completion passes
// TRUE because that is what a finished scene does; damage, death and the watchdog
// ALSO pass TRUE, and that is a deliberate divergence from Half-Life, which fires
// nothing when a scene is interrupted.  Half-Life can afford it because its
// scenes are staged where the player cannot start a fight in the middle of one.
// A co-op mod cannot: an actor shot mid-scene must not leave the rest of the map
// waiting on a chain that can no longer come.
void(entity m, float firechain) Script_Release =
{
	entity s = m.ai_script;

	// Read this BEFORE the actor is handed back, because the whole tail of this
	// function branches on it.  DEAD_DYING is set by one thing only — the 1000
	// event in AI_HandleSharedEvent — so it is an exact test for "this scene was a
	// death", and it cannot collide with the shot-mid-scene path: AI_Died calls us
	// while deadflag is still DEAD_NO and only reaches DEAD_DEAD afterwards.
	float dying = (m.deadflag == DEAD_DYING);

	m.ai_script      = world;
	m.ai_scriptstate = SCRIPTST_NONE;
	m.ai_scriptgo    = FALSE;
	// A monster that has been through a script once is no longer "waiting for a
	// script", whatever its spawnflags still say.  Half-Life never needs to ask
	// the question — SF_MONSTER_WAIT_FOR_SCRIPT only gates MonsterInit — but the
	// HUD readout does: see the note in LookatNPC_Tick (server/sv_lookatnpc.qc).
	m.ai_script_played = TRUE;

	// Hand the body back to the animation system.  Without clearing the name the
	// monster keeps re-asserting its scripted pose (AI_SetActivity's idempotence
	// is on .ai_activity, and a named sequence has none), so a released scientist
	// would walk around still sitting down.
	m.ai_seqname = "";
	AI_ResetActivity(m);

	// PUT THE ACTOR BACK ON THE GROUND, or take the ground away from it.
	//
	// This is the tail of Half-Life's CineCleanup (dlls/scripted.cpp:842-889),
	// which nothing here implemented:
	//
	//     pev->origin.z += 1;
	//     pev->flags |= FL_ONGROUND;
	//     int drop = DROP_TO_FLOOR( ENT(pev) );
	//     if ( drop < 0 )       pev->origin = oldOrigin;   // ended in solid
	//     else if ( drop == 0 ) pev->flags &= ~FL_ONGROUND; // hanging in air
	//
	// The `drop == 0` arm is the whole point and is the half that was missing: a
	// sequence that ends with the actor unsupported must hand it back to GRAVITY,
	// not leave it standing on nothing.  th_ep1_03's `lavaman` is exactly that -
	// a scientist who hangs from a lift ("hanging_idle2"), plays "fall_elevator"
	// and is supposed to drop into the lava.  Without this he finished the
	// sequence and stood in mid-air over the pit, which is the reported
	// "monster_scientist lavaman stands floating in the air".
	//
	// Runs for a posed body too.  A body has no AI to notice it is unsupported, so
	// it is the case that needs the un-grounding most.
	//
	// NOT run when the actor is dead: a corpse has already been sized to its
	// one-unit pancake by AI_Died and re-dropping it here would fight that.
	//
	// `dying` is admitted deliberately, and is the exception that proves the rule:
	// its health is already 0 (the 1000 event zeroed it) but AI_BecomeCorpse has
	// NOT run yet — Script_DieInPlace is called further down — so there is no
	// pancake to fight, and skipping the block is exactly what would leave
	// th_ep1_03's lavaman hanging over the lava as a corpse instead of falling into
	// it.  Half-Life skips it (CineCleanup returns before this block) and freezes
	// him in the air; this is the same divergence the block's own comment already
	// argues for, extended to the case that made the actor dead.
	if ((dying || (m.ai_state != MS_DEAD && m.health > 0)) && m.movetype != MOVETYPE_NONE)
	{
		vector oldorg = m.origin;
		entity oldds  = self;
		self = m;
		setorigin(m, m.origin + '0 0 1');
		m.flags = m.flags | FL_ONGROUND;
		if (!droptofloor())
		{
			// Either "ended inside solid" or "nothing under it".  Half-Life tells
			// the two apart from DROP_TO_FLOOR's -1 / 0; QC's droptofloor collapses
			// both to FALSE, so the distinction is made by hand: put the actor back
			// where the sequence left it, and only clear FL_ONGROUND when the spot
			// is actually free.  A monster whose origin is in solid must KEEP its
			// footing or it falls through the world.
			setorigin(m, oldorg);
			traceline(oldorg, oldorg - '0 0 2', MOVE_NORMAL, m);
			if (trace_fraction == 1 && !trace_startsolid)
				m.flags = m.flags - (m.flags & FL_ONGROUND);
		}
		self = oldds;
	}

	// The scene's own animation killed the actor — make the corpse and hold the
	// last frame.  Ahead of the MS_SCRIPT arm because that arm's job is to hand a
	// LIVE actor back to the AI, and this one must never reach it.
	if (dying)
		Script_DieInPlace(m);
	else if (m.ai_state == MS_SCRIPT)
	{
		// Half-Life's CineCleanup: normally back to idle, but EXITAGITATED (2) means
		// the scene ended with the actor spooked - it leaves alert and provoked, and
		// that is how a scripted scare hands over to a real fight.
		//
		// A DEAD actor is never handed back to idle.  CineCleanup's own guard is
		// `if (pev->health > 0) m_IdealMonsterState = MONSTERSTATE_IDLE; else
		// m_IdealMonsterState = MONSTERSTATE_DEAD` (scripted.cpp:898-909), and
		// FixScriptMonsterSchedule repeats it (`if (m_IdealMonsterState !=
		// MONSTERSTATE_DEAD)`).  Without it an actor killed mid-scene is resurrected
		// standing when the scene ends, which is the reported "the NPC just jumps
		// back to position alive standing".
		if (m.health <= 0)
			m.ai_state = MS_DEAD;
		else if (s && (s.spawnflags & SF_SCRIPT_EXITAGITATED))
		{
			m.ai_state = MS_ALERT;
			m.ai_cond  = m.ai_cond | COND_PROVOKED;
		}
		else
			m.ai_state = MS_IDLE;
	}

	// Force a clean re-selection on the next tick.  ai_sched is cleared rather
	// than left alone because the release can happen from inside the task loop
	// (completion) or from outside it (damage, death), and only "no schedule"
	// behaves identically in both.
	m.ai_sched    = SCHED_NONE;
	m.ai_task     = 0;
	m.ai_taskdone = FALSE;
	m.ai_cond     = m.ai_cond | COND_SCHEDULE_DONE;
	// Only wake something that HAS a think.  A posed body has none, and handing
	// the engine a nextthink with a null think function is an SV_Error, not a
	// no-op - so this test is load-bearing rather than defensive.
	if (m.think)
		if (m.nextthink <= 0 || m.nextthink > time + 0.1)
			m.nextthink = time + 0.05;

	if (!s)
		return;

	s.ss_mon      = world;
	s.ss_started  = 0;
	s.ss_watchdog = 0;
	s.ss_claiming = FALSE;
	s.ss_body     = FALSE;
	s.ss_bodyend  = 0;
	s.nextthink   = 0;

	// Non-repeatable scripts are done for good.  Half-Life removes the entity
	// outright here; marking it spent is the same thing without the hazard of
	// deleting something the rest of the map may still address by targetname.
	if (!(s.spawnflags & SF_SCRIPT_REPEATABLE))
		s.ss_spent = TRUE;

	if (firechain)
	{
		// self is the MONSTER on every path into here, so the caller has to be
		// passed explicitly.  SUB_UseTargets honours .delay and .killtarget, which
		// matters: hl_c01_a1's argument loop is built entirely out of scripts whose
		// delay keys pace the conversation.
		entity oldself = self;
		entity oldact  = activator;
		self      = s;
		activator = s.delayed_activator;
		SUB_UseTargets(s, s.delayed_activator, USE_TOGGLE);
		activator = oldact;
		self      = oldself;
	}
};

// ---------------------------------------------------------------------------
// possession
// ---------------------------------------------------------------------------
float(entity s) Script_Possess =
{
	if (s.ss_spent)
		return FALSE;

	entity m = Script_FindMonster(s);
	if (!m)
		return FALSE;

	m.ai_script = s;
	s.ss_mon    = m;
	s.ss_tries  = 0;
	s.ss_body   = (m.think != AI_Think);
	ai_dbg_script_claimed = ai_dbg_script_claimed + 1;

	if (s.ss_body)
	{
		// A posed body.  It cannot walk, so every movement mode that would have
		// travelled becomes a snap to the mark.
		//
		// That IS a divergence - Half-Life's G-Man walks under script control and
		// gman.mdl carries a walk cycle for it - and it is the right one to make:
		// without AI there is no locomotion to reach the mark with at all, and a
		// scene played four metres from where it was authored reads as a bug, while
		// a body already standing on its mark (which is the overwhelmingly common
		// case - 0 and 4 are what these scripts use) snaps to no visible effect.
		float bmv = s.m_fmoveto;
		if (bmv == 1 || bmv == 2 || bmv == 4)
		{
			setorigin(m, s.origin);
			m.velocity = '0 0 0';
			m.flags    = m.flags | FL_ONGROUND;
		}
		if (bmv != 0)
			m.angles_y = s.angles_y;

		float bseq = Script_BodySeq(m, s.m_iszidle);
		if (bseq >= 0)
			m.frame = bseq;
		else if (s.m_iszidle != "" && s.m_iszidle)
			ai_dbg_script_noseq = ai_dbg_script_noseq + 1;

		// Same arming rule as a real monster, minus the walk cases it cannot use.
		if (bmv == 4)
			s.ss_started = 0;
		else if (s.targetname == "" || !s.targetname)
			s.ss_started = time;
		else
			s.ss_started = 0;

		s.ss_bodyend = 0;
		s.nextthink  = time + 0.5;

		if (ai_cached_debug)
			dprint(sprintf("[script] \"%s\" posed body %s \"%s\" moveto=%g seq=%g\n",
			               s.targetname, m.classname, m.targetname, bmv, bseq));
		return TRUE;
	}

	// Drop everything the monster was committed to.  An escorting ally in
	// particular MUST stop escorting: SCHED_FOLLOW is selected below the script
	// gate so it could never run again anyway, and leaving .ai_follow set would
	// have the monster resume the escort the instant the scene ended, from
	// wherever the scene left it.
	AI_StopMoving(m);
	AI_PathClear(m);
	m.ai_follow = world;
	m.ai_state  = MS_SCRIPT;

	float mv = s.m_fmoveto;

	// aiscripted_sequence never teleports.  That is the substantive difference
	// between the two classes: CCineAI is the "let the AI walk there normally"
	// variant, used where snapping an actor into place in front of the player
	// would be visible.  Demoting 4 to a walk is the honest reading of it.
	if (s.ss_ai && mv == 4)
		mv = 1;

	// A bolted-down monster (turret, barnacle) cannot travel to a mark, and Sven
	// maps do pose them.  Demote to "stay put" rather than hand it a walk it can
	// never finish - the same rule AI_SelectSchedule already applies to chases.
	if (m.ai_movemode == AIMODE_STATIC && (mv == 1 || mv == 2))
		mv = 5;

	if (mv == 1)
		m.ai_scriptstate = SCRIPTST_WALK;
	else if (mv == 2)
		m.ai_scriptstate = SCRIPTST_RUN;
	else
	{
		m.ai_scriptstate = SCRIPTST_WAIT;

		if (mv == 4)
		{
			// The teleport.  FL_ONGROUND is set deliberately and it is the whole
			// trick: FTE's step physics computes freefall as
			// !(FL_ONGROUND|FL_FLY|FL_SWIM) (sv_phys.c:1541), so a monster placed
			// with the flag set simply stays where it was put.  Half-Life relies on
			// exactly the same property - PossessEntity has the line that would
			// clear FL_ONGROUND commented out, which reads as an accident until you
			// notice that removing the comment would drop every posed NPC in the
			// game onto the floor.
			//
			// Monster origins are at the feet in both engines (Monster_ClassHull:
			// mins_z 0), so the mark's origin transfers with no adjustment.
			setorigin(m, s.origin);
			m.velocity = '0 0 0';
			m.avelocity = '0 0 0';
			m.flags = m.flags | FL_ONGROUND;
			m.angles_y = s.angles_y;
		}
		if (mv == 4 || mv == 5)
			m.ai_yaw_ideal = AI_AngleNorm(s.angles_y);
	}

	// When may the action start?
	//
	//   walk/run - on ARRIVAL at the mark.  Half-Life reaches this through
	//              DelayStart, and it is why the pondering loop on this map runs
	//              without anything re-triggering it: each script walks its
	//              scientist to the next mark, plays there, and fires the next.
	//   instant  - never, until triggered.  This is the barneyatdesk rule.
	//   none/face- immediately if the script has no targetname (nothing will ever
	//              trigger it), otherwise wait to be triggered.
	if (mv == 1 || mv == 2 || mv == 4)
		s.ss_started = 0;
	else if (s.targetname == "" || !s.targetname)
	{
		s.ss_started  = time;
		m.ai_scriptgo = TRUE;
	}
	else
		s.ss_started = 0;

	// Pose it NOW rather than waiting for the schedule.  A monster claimed with no
	// player nearby is dormant (AI_Think's MS_SCRIPT/WAIT branch), so its schedule
	// may not run for half a second or more - and the animation pump runs while
	// dormant, so the pose set here is live immediately and stays live.
	Script_StartIdle(m);

	// Re-select on the next tick so the gate picks the script schedule up.
	m.ai_sched    = SCHED_NONE;
	m.ai_task     = 0;
	m.ai_taskdone = FALSE;
	m.nextthink   = time + 0.05;

	// One line per possession.  Bounded by the number of scripts on the map and
	// it is the line that answers "which scenes actually took an actor, and what
	// did each one decide to do with it" - which no aggregate counter can, because
	// nine claims that all teleport and nine that all walk report identically.
	if (ai_cached_debug)
		dprint(sprintf("[script] \"%s\" claimed %s \"%s\" moveto=%g -> %s\n",
		               s.targetname, m.classname, m.targetname, mv,
		               (m.ai_scriptstate == SCRIPTST_WALK) ? "walk" :
		               (m.ai_scriptstate == SCRIPTST_RUN)  ? "run"  : "wait"));
	return TRUE;
};

// ---------------------------------------------------------------------------
// the script entity's own think
// ---------------------------------------------------------------------------
// Two jobs, and it only runs when one of them is outstanding: keep trying to
// claim a monster that is not there yet, and watchdog a scene that has stopped
// advancing.  A script sitting in the map doing neither has nextthink 0 and costs
// nothing, which is what makes 95 of them on one map free.
// A posed body's whole playback loop, in one function, because it has nowhere
// else to live: the body has no think, no schedule and no conditions, so the
// script entity is the only thing ticking on its behalf.
//
// Sets its own nextthink rather than returning a rate: idle waiting is cheap
// (half a second), playback needs to notice the sequence ending promptly, and a
// map with thirty posed bodies should only pay the fast rate for the ones
// actually mid-scene.
void(entity s, entity m) Script_BodyTick =
{
	if (s.ss_bodyend > 0)
	{
		if (time >= s.ss_bodyend)
		{
			ai_dbg_script_done = ai_dbg_script_done + 1;
			Script_Release(m, TRUE);
			return;			// Release zeroes nextthink
		}
		s.nextthink = time + 0.1;
		return;
	}

	if (s.ss_started > 0 && time >= s.ss_started)
	{
		ai_dbg_script_played = ai_dbg_script_played + 1;

		float seq = Script_BodySeq(m, s.m_iszplay);
		if (seq >= 0)
		{
			m.frame = seq;
			s.ss_bodyend = time + frameduration(m.modelindex, seq);
		}
		else
		{
			if (s.m_iszplay != "" && s.m_iszplay)
			{
				ai_dbg_script_noseq = ai_dbg_script_noseq + 1;
				dprint(sprintf("[script] \"%s\": %s has no sequence \"%s\"\n",
				               s.targetname, m.classname, s.m_iszplay));
			}
			s.ss_bodyend = time;
		}
		// Never zero-length: a degenerate duration would complete on the same tick
		// it started, and a chain of such scripts would run the whole scene inside
		// one frame with nothing visible.
		if (s.ss_bodyend <= time)
			s.ss_bodyend = time + 0.1;

		s.nextthink = time + 0.05;
		return;
	}

	s.nextthink = time + 0.5;
};

// Is there a maker on this map that will one day produce an actor by this name?
//
// squadmaker/monstermaker hand their `netname` to each child as its targetname
// (sv_monsters.qc:1877 and :2118), so a script waiting on a name that a maker
// declares is waiting for something that has not been asked to exist yet — the
// normal, correct case for a mid-map set piece.  th_escape is the example that
// prompted this: the unnamed scripted_sequence at (4701,-4285,-1032) holds
// "standing_idle" for "jail_sheriff", and the only jail_sheriff there will ever
// be is the monster_gman that squadmaker "jail_sheriffspawn" spawns when
// "populate_jail" runs at the END of the map.  The script therefore misses for
// the entire run and the watchdog printed
//     [script] "": still looking for "jail_sheriff" after 120 tries
// which reads as a fault and is not one.
//
// Only the DIAGNOSTIC is gated.  The retry itself keeps running either way —
// that is the whole point of removing the give-up, and gating the retry on this
// would reintroduce it for every script whose actor is placed rather than made.
//
// Runs once per script, at the threshold, over two find() chains.  Not hot.
float(string want) Script_MakerWillSupply =
{
    if (want == "")
        return FALSE;

    entity m = find(world, classname, "squadmaker");
    while (m)
    {
        if (m.netname == want)
            return TRUE;
        m = find(m, classname, "squadmaker");
    }

    m = find(world, classname, "monstermaker");
    while (m)
    {
        if (m.netname == want)
            return TRUE;
        m = find(m, classname, "monstermaker");
    }

    return FALSE;
};

void() Script_Think =
{
	entity m = self.ss_mon;

	// Lost it: the monster was removed, or something else took it.  Both are
	// normal (a squadmaker's monster can be culled mid-scene) and both mean this
	// script owns nothing.
	if (m && m.ai_script != self)
	{
		self.ss_mon = world;
		m = world;
	}

	if (m && self.ss_body)
	{
		Script_BodyTick(self, m);
		return;
	}

	if (m)
	{
		if (self.ss_watchdog > 0 && time > self.ss_watchdog)
		{
			// The action has been "playing" for half a minute.  Something is wrong
			// with the sequence, not with the map, and the map must not pay for it.
			ai_dbg_script_forced = ai_dbg_script_forced + 1;
			dprint(sprintf("[script] \"%s\": \"%s\" never finished on %s - forcing\n",
			               self.targetname, self.m_iszplay, m.classname));
			Script_Release(m, TRUE);
			return;			// Release zeroes nextthink
		}
		self.nextthink = time + 1;
		return;
	}

	if (!self.ss_claiming || self.ss_spent)
	{
		self.nextthink = 0;
		return;
	}

	if (Script_Possess(self))
	{
		self.ss_claiming = FALSE;
		self.nextthink   = time + 1;	// straight into watchdog duty
		return;
	}

	self.ss_tries = self.ss_tries + 1;

	// Say WHY on the first miss.  A script that cannot find its actor is the
	// single most likely thing to be wrong on a new map (a renamed monster, a
	// classname search out of radius, a monstermaker that has not fired yet), and
	// without this the symptom is a scene that silently never happens - which is
	// indistinguishable from a scene nobody triggered.  Once per script, so 95 of
	// them cost 95 lines at worst and only under developer.
	if (self.ss_tries == 1)
		dprint(sprintf("[script] \"%s\" cannot find \"%s\" yet (moveto=%g radius=%g)\n",
		               self.targetname, self.m_iszentity, self.m_fmoveto, self.m_flradius));

	// NO GIVE-UP.  Half-Life's CineThink (dlls/scripted.cpp:476-489) retries at
	// 1 Hz for the whole map, and the 120-try cutoff that used to be here stopped
	// at ~565 s on the reasoning that a name absent for nine minutes is a mapper
	// typo rather than a squadmaker that has yet to fire.  pizza_ya_san1 is the
	// counter-example, five times over: scrp_jk2 / scrp_farmer2 / scrp_electro2 /
	// scrp_gamesaba2 hold "sit_pizza" / "sit_bigmac" for mon_jk2 & co., and
	// scrip_mi2 holds "smile_sit_hiji" for mon_mi2 - all squadmaker children that
	// cannot exist until the players have voted the map open and pressed fifteen
	// ml_gomi* buttons, and NOTHING in the BSP targets those five scripts, so this
	// retry is their only route to an actor.  Past the old deadline the four
	// customers stood at their chairs in a default idle for the rest of the map
	// with no recovery path whatsoever.  Say so once at the old threshold, so a
	// genuine mapper typo is still visible in the log, and keep going.
	// ...but not when a squadmaker/monstermaker on the map declares that name, in
	// which case "the actor does not exist yet" is the design, not a defect.  See
	// Script_MakerWillSupply.
	if (self.ss_tries == SCRIPT_CLAIM_TRIES)
	if (!Script_MakerWillSupply(self.m_iszentity))
		dprint(sprintf("[script] \"%s\": still looking for \"%s\" after %g tries - still retrying\n",
		               self.targetname, self.m_iszentity, self.ss_tries));

	// Half-Life's rate, permanently.  The fast phase is for the ordinary case (a
	// monster the map places at load is there within a tick or two); 1 Hz after it
	// is HL's own figure and bounds the visible pop-in - a customer standing up
	// before dropping into the chair - to a single second when a squadmaker
	// finally fires.  Only scripts still LOOKING pay it: six on pizza_ya_san1,
	// seven on hl_c01_a1.
	self.nextthink = time + 1;
};

// ---------------------------------------------------------------------------
// hooks the interpreter calls
// ---------------------------------------------------------------------------
// Which schedule a possessed monster gets.  The one place possession is turned
// into behaviour, and it double-checks the link in BOTH directions: a script
// entity that was removed leaves .ai_script pointing at a freed edict whose
// fields read back as zero, so ss_mon != m catches it and releases rather than
// leaving a monster possessed by nothing for the rest of the map.
float(entity m) Script_Schedule =
{
	entity s = m.ai_script;
	if (!s || s.ss_mon != m)
	{
		Script_Release(m, FALSE);
		return SCHED_NONE;
	}

	if (m.ai_scriptstate == SCRIPTST_WALK)	return SCHED_SCRIPT_WALK;
	if (m.ai_scriptstate == SCRIPTST_RUN)	return SCHED_SCRIPT_RUN;
	if (m.ai_scriptstate == SCRIPTST_PLAY)	return SCHED_SCRIPT_PLAY;
	return SCHED_SCRIPT_WAIT;
};

// Arrived at the mark and finished turning.  Half-Life's DelayStart(0) equivalent:
// reaching the mark is itself what arms a walk/run script, which is why a chain of
// them plays through without anything re-triggering each link.
void(entity m) Script_AtMark =
{
	entity s = m.ai_script;
	if (!s)
		return;

	ai_dbg_script_moved = ai_dbg_script_moved + 1;
	m.ai_scriptstate = SCRIPTST_WAIT;

	if (!s.ss_started)
	{
		s.ss_started  = time + 0.05;
		m.ai_scriptgo = TRUE;
	}
};

float(entity m) Script_MayPlay =
{
	entity s = m.ai_script;
	if (!s || s.ss_mon != m)
		return FALSE;
	if (s.ss_started <= 0)
		return FALSE;
	return time >= s.ss_started;
};

void(entity m) Script_SequenceDone =
{
	ai_dbg_script_done = ai_dbg_script_done + 1;
	// Release BEFORE firing, exactly as Half-Life does and for its stated reason:
	// the chain very often triggers the next script aimed at this same monster,
	// and that script has to find it free.  hl_c01_a1's pondering ring and its
	// argument loop are both built this way.
	Script_Release(m, TRUE);
};

float(entity m) Script_CanInterrupt =
{
	entity s = m.ai_script;
	if (!s)
		return FALSE;
	// aiscripted_sequence is the interruptible variant by definition - it is the
	// class a mapper picks when the scene should yield to a fight.
	if (s.ss_ai)
		return TRUE;
	return !(s.spawnflags & SF_SCRIPT_NOINTERRUPT);
};

// ---------------------------------------------------------------------------
// triggering
// ---------------------------------------------------------------------------
void() Script_Use =
{
	if (self.ss_spent)
		return;			// Half-Life has removed the entity by now

	entity m = self.ss_mon;
	if (m && m.ai_script != self)
	{
		self.ss_mon = world;
		m = world;
	}

	if (!m)
	{
		self.delayed_activator = activator;
		if (Script_Possess(self))
			m = self.ss_mon;
	}

	if (m)
	{
		if (self.ss_body)
		{
			if (self.ss_bodyend > 0)
				return;		// already playing
			self.delayed_activator = activator;
			self.ss_started  = time + 0.05;
			self.ss_claiming = FALSE;
			self.nextthink   = time + 0.05;	// Script_BodyTick takes it from here
			return;
		}

		if (m.ai_scriptstate == SCRIPTST_PLAY)
			return;		// already running; HL ignores a second trigger

		self.delayed_activator = activator;
		self.ss_started  = time + 0.05;
		m.ai_scriptgo    = TRUE;
		m.nextthink      = time + 0.05;
		self.ss_claiming = FALSE;
		self.nextthink   = time + 1;		// watchdog duty
		return;
	}

	// THE SOFT-LOCK GUARD, and it is the oldest behaviour in this file - it is
	// what the 0.5 s relay this class used to be existed to do.
	//
	// No monster answers to that name, so the scene cannot happen.  Fire the target
	// chain anyway after a beat, because on a campaign map the chain is progression
	// and a severed chain is a map the player cannot finish.  Half-Life would sit
	// here retrying forever and let the map deadlock; that is the one place being
	// unfaithful is obviously right.
	//
	// The delay keeps the chain asynchronous, so a script that targets its own
	// trigger cannot recurse.
	ai_dbg_script_lost = ai_dbg_script_lost + 1;
	self.delayed_activator = activator;
	self.ss_spent  = TRUE;
	self.ss_claiming = FALSE;
	self.think     = Script_LostFinish;
	self.nextthink = time + 0.5;
};

void() Script_LostFinish =
{
	entity oldact = activator;
	activator = self.delayed_activator;
	SUB_UseTargets(self, activator, USE_TOGGLE);
	activator = oldact;
	self.nextthink = 0;
};

// ---------------------------------------------------------------------------
// spawn
// ---------------------------------------------------------------------------
void() Script_Spawn =
{
	self.solid    = SOLID_NOT;
	self.movetype = MOVETYPE_NONE;
	self.use      = Script_Use;
	self.think    = Script_Think;

	// `angle` is the old single-float spelling and 399 corpus entities still use
	// it; the engine folds it into angles for brush models but not reliably for
	// point entities, and the mark's yaw IS the pose's facing, so it is worth the
	// two lines.
	if (self.angles == '0 0 0' && self.angle)
		self.angles_y = self.angle;

	// m_flRepeat is parsed and not acted on.  Half-Life's CCineMonster stores it
	// and never reads it either - 578 of the corpus's 631 uses are literally "0" -
	// so implementing it would mean inventing behaviour rather than porting it.
	// Named here so the next reader does not go looking for the missing code.

	// Claim at map start?  Half-Life's rule verbatim (scripted.cpp Spawn): a script
	// with no targetname has nothing that could ever trigger it, and a script with
	// an idle pose is describing how its actor STANDS, which has to be true before
	// anyone triggers anything.
	script_dbg_total = script_dbg_total + 1;

	if ((self.targetname == "" || !self.targetname)
	 || (self.m_iszidle != "" && self.m_iszidle))
	{
		self.ss_claiming = TRUE;
		self.nextthink   = time + 1;	// HL's one second, so squadmakers and
						// monstermakers have spawned first
		script_dbg_atspawn = script_dbg_atspawn + 1;
	}
	else
		self.nextthink = 0;
};

void() scripted_sequence =
{
	Script_Spawn();
};

// Half-Life's CCineAI.  Same machinery, two differences that matter: it never
// teleports its actor (see Script_Possess) and it always yields to damage (see
// Script_CanInterrupt).  76 uses corpus-wide against scripted_sequence's 1943,
// so this is the rare variant and treating it as a flag on the common one is
// proportionate.
void() aiscripted_sequence =
{
	self.ss_ai = TRUE;
	Script_Spawn();
};

// ---------------------------------------------------------------------------
// diagnostics
// ---------------------------------------------------------------------------
// claimed / moved / played / done are the four numbers that matter, and they are
// deliberately not collapsed into one.  A scene can be claimed and never move
// (mark unreachable), move and never play (arrival not detected), play and never
// finish (sequence never ends) - and each of those failures looks exactly like
// success from any single counter.  lost / noseq / stuck / forced / broke are the
// five ways out that are NOT success, reported separately so a map that limps
// through on the safety guards cannot be mistaken for one that works.
void() AI_ReportScripts =
{
	if (!script_dbg_census && script_dbg_total)
	{
		script_dbg_census = TRUE;
		dprint(sprintf("[script] map has %g scripted_sequence(s), %g claim an actor at spawn\n",
		               script_dbg_total, script_dbg_atspawn));
	}

	// Live census of possessed actors.  The rate counters above say what HAPPENED
	// in the last two seconds; this says what IS, which is the only way to tell a
	// map whose tableau is standing correctly from one whose actors were claimed
	// and then quietly lost.  Silent when nothing is possessed.
	float nwalk = 0, nwait = 0, nplay = 0;
	entity e = monster_chain_head;
	while (e)
	{
		if (e.ai_script)
		{
			if (e.ai_scriptstate == SCRIPTST_WALK || e.ai_scriptstate == SCRIPTST_RUN)
				nwalk = nwalk + 1;
			else if (e.ai_scriptstate == SCRIPTST_PLAY)
				nplay = nplay + 1;
			else
				nwait = nwait + 1;
		}
		e = e.monster_chain_next;
	}
	if (nwalk || nwait || nplay)
		dprint(sprintf("[ai]   script now: walking=%g posed=%g playing=%g\n",
		               nwalk, nwait, nplay));

	if (!ai_dbg_script_claimed && !ai_dbg_script_played && !ai_dbg_script_done
	 && !ai_dbg_script_lost && !ai_dbg_script_noseq && !ai_dbg_script_stuck
	 && !ai_dbg_script_forced && !ai_dbg_script_broke && !ai_dbg_script_moved)
		return;

	// Two lines rather than one: fteqcc warns past eight varargs, and the split
	// falls exactly where the meaning does - what worked, then how it failed.
	dprint(sprintf("[ai]   script: claimed=%g moved=%g played=%g done=%g\n",
	               ai_dbg_script_claimed, ai_dbg_script_moved,
	               ai_dbg_script_played, ai_dbg_script_done));
	// `died` is not a bail — it is a scene that worked — but it belongs on this
	// line rather than the one above because it is the outcome an operator wants to
	// read NEXT TO the failures; the four-number line is the possession ledger.
	dprint(sprintf("[ai]   script bail: lost=%g noseq=%g stuck=%g forced=%g broke=%g died=%g\n",
	               ai_dbg_script_lost, ai_dbg_script_noseq,
	               ai_dbg_script_stuck, ai_dbg_script_forced,
	               ai_dbg_script_broke, ai_dbg_script_died));

	ai_dbg_script_claimed = 0; ai_dbg_script_moved  = 0;
	ai_dbg_script_played  = 0; ai_dbg_script_done   = 0;
	ai_dbg_script_lost    = 0; ai_dbg_script_noseq  = 0;
	ai_dbg_script_stuck   = 0; ai_dbg_script_forced = 0;
	ai_dbg_script_broke   = 0; ai_dbg_script_died   = 0;
};
