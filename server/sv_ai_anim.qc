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
// The grenade animation specifically, because it is the reported bug and because
// "correlated with the loadout" is a claim a single number can settle: before this
// patch the split was a coin flip independent of what the grunt was carrying.
// Declared here rather than in mon_grunt.qc because globals cannot be
// forward-declared and the report lives in sv_ai_core.qc, between the two.
float ai_dbg_gren_throw, ai_dbg_gren_launch;

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

		// Re-roll once if the weighted pick landed on the sequence already playing.
		// For a multi-variant activity (the headcrab's three jump variants) this
		// usually finds a different one, which is what makes the client re-stamp its
		// playback clock and actually restart the animation.
		//
		// Deliberately NOT applied to an override: a name is a decision, and
		// re-rolling it would be the same coin flip this hook exists to remove.
		if (seq == m.ai_seq && m.ai_activity != act)
		{
			float again = AI_SeqForActivity(m, act);
			if (again >= 0)
				seq = again;
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
			sound(m, CHAN_BODY, AI_EventSoundName(data), 1, ATTN_IDLE);
		return TRUE;
	}
	if (code == EVENT_SOUND_VOICE)
	{
		if (data != "" && data)
			sound(m, CHAN_VOICE, AI_EventSoundName(data), 1, ATTN_IDLE);
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
		sound(m, CHAN_BODY, (random() < 0.5) ? SND_BODYDROP_A : SND_BODYDROP_B,
		      1, ATTN_NORM, (code == EVENT_BODYDROP_HEAVY) ? 90 : 100);
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
			sound(m, CHAN_BODY, AI_StepSound(), 1, ATTN_IDLE);
			ai_dbg_ev_step = ai_dbg_ev_step + 1;
		}
		return TRUE;
	}

	// Deliberately swallowed, not passed on: these drive Half-Life's scripted
	// sequence machinery, which is W8.  They appear on sequences this AI does not
	// play yet, and a class virtual has nothing useful to do with them.
	if (code == EVENT_DEAD)		return TRUE;
	if (code == EVENT_NOINTERRUPT)	return TRUE;
	if (code == EVENT_CANINTERRUPT)	return TRUE;
	if (code == EVENT_NOT_DEAD)	return TRUE;

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
		sound(m, CHAN_BODY, SND_SWISH, 1, ATTN_NORM);
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
			have = strcat(have, " ", nm);
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
	AI_ProbeModelSeqs("models/hgrunt.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 standing_shotgun crouching_shotgun limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/hgrunt_opfor.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 standing_shotgun crouching_shotgun limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/massn.mdl",
	                  "throwgrenade launchgrenade standing_mp5 crouching_mp5 standing_shotgun crouching_shotgun limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/hgrunt_torch.mdl",
	                  "throwgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/hgrunt_medic.mdl",
	                  "throwgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/strooper.mdl",
	                  "throwgrenade standing_mp5 crouching_mp5 limpingwalk limpingrun");
	AI_ProbeModelSeqs("models/hwgrunt.mdl",
	                  "attack pistol_shoot pistol_crouchshoot creeping_walk pistol_walk run pistol_run pistol_idle");
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
