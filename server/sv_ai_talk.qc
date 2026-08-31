// server/sv_ai_talk.qc
// ----------------------------------------------------------------------------
// Half-Life's CTalkMonster layer: the reason scientists and barneys feel ALIVE
// rather than like props that happen to be damageable.
//
// This is the answer to "they don't turn to face you, they don't talk, they feel
// like a 1 second decision".  The decision rate was never the problem - it is
// 0.1s, exactly Half-Life's.  What was missing is everything CTalkMonster does
// BETWEEN decisions:
//
//   - the head/upper body turns to track whoever is near, continuously
//   - idle chatter on a timer, and a greeting when you first come close
//   - the jaw moves while a line plays
//   - +use gets an answer, even from someone who will not follow you
//
// None of it changes a schedule.  That is the point: it is a cosmetic layer over
// an AI that already works, and it is worth more to how the game FEELS than any
// schedule change in the whole programme.
//
// WHY THIS COULD NOT EXIST BEFORE.  All of the above is driven by BONE
// CONTROLLERS, and until engine Patch 125 a server-side monster could set
// .bonecontrol1..5 and no client ever found out.  Head turn is controller 0 and
// the jaw is controller 4; both were unreachable, so this file is new code
// standing on a wire format that is also new.
//
// THE CONTROLLERS, measured out of the shipped models (never transcribed):
//
//   scientist.mdl  [0] 0x0008 -60..60   [4] 0x0020  0..20   <- jaw
//   barney.mdl     [0] 0x0008 -60..60   [4] 0x0020  0..45
//   otis.mdl       [0] 0x0008 -60..60   [4] 0x0020  0..25
//   gman.mdl       [0] 0x0008 -60..60   [4] 0x0008  0..30
//   hgrunt.mdl     [0] 0x0008 -70..70   (no jaw)
//
// Every one is a BOUNDED rotation in the 0x0008..0x0020 band, so the values here
// are DEGREES and the engine clamps them to each model's own range for us.  That
// clamp is a feature: a scientist asked to look 120 degrees behind himself turns
// as far as his neck goes and no further, which is exactly right and costs
// nothing to implement.
// ----------------------------------------------------------------------------

// Controller slots, by meaning rather than by number.
const float BC_HEAD_YAW = 0;
const float BC_MOUTH    = 4;

// How far a talker notices you from.  HL's CTalkMonster uses 128 for the "player
// is right here" tests and a longer range for looking; this is the look range.
const float TALK_LOOK_DIST  = 320;
const float TALK_GREET_DIST = 160;	// close enough to be spoken to

// Idle chatter spacing.  Long on purpose - HL's scientists are chatty but not
// constant, and a room with eight of them (hl_c01_a1 has 28) turns into noise
// very fast if this is short.  Randomised per monster so they do not all speak
// on the same tick.
const float TALK_IDLE_MIN = 12;
const float TALK_IDLE_MAX = 24;

// The fields live in sv_ai_defs.qc, which compiles first - sv_ai_core.qc and the
// class inits both touch them and both compile before this file.

// Counters, reported with the rest of the AI debug block.  Speech and head-turn
// are invisible to a headless drive - sound() logs nothing and a bone controller
// is a wire value - so without these there is no way to tell "the talk layer is
// working" from "the talk layer never ran", which is precisely the selections-vs-
// actions trap that has caught this programme twice.
float ai_dbg_talkers, ai_dbg_lines, ai_dbg_looks;

// The grudge counters live in sv_ai_defs.qc, not here: sv_ai_factions.qc bumps
// ai_dbg_forgiven and compiles BEFORE this file, and QC forward-declares
// functions but not globals.

// ---------------------------------------------------------------------------
// looking
// ---------------------------------------------------------------------------
// Latch a deliberate look. Used by +use and by the greeting, so being spoken to
// makes them actually turn to you rather than carry on staring at a wall.
void(entity m, entity targ) AI_LookAt =
{
	if (!m.ai_talker || !targ)
		return;
	m.ai_lookat = targ;
	m.ai_lookend = time + 4;
};

// Nearest live player within `dist`, or world.
entity(entity m, float dist) AI_NearestPlayer =
{
	entity best = world;
	float  bd = dist;
	entity p = find(world, classname, "player");
	while (p)
	{
		if (p.health > 0)
		{
			float d = vlen(p.origin - m.origin);
			if (d < bd)
			{
				bd = d;
				best = p;
			}
		}
		p = find(p, classname, "player");
	}
	return best;
};

// ---------------------------------------------------------------------------
// speaking
// ---------------------------------------------------------------------------
// Say a topic from this monster's group, honouring PRE-DISASTER.
//
// Half-Life keeps a SECOND set of lines for before the cascade and CTalkMonster
// swaps to them wholesale - the "P" groups.  They are in the shipped file and
// they matter here more than anywhere: nearly every talker on hl_c01_a1 carries
// spawnflag 256, so the pre-disaster set IS the intro's dialogue.  Measured in
// sentences.txt: SC_PIDLE (11 lines) and SC_PHELLO (7) exist alongside SC_IDLE
// (14) and SC_HELLO (9).
//
// Falls back to the plain group when a P variant does not exist for that topic
// or that character, so a missing set degrades to the ordinary line rather than
// to silence.
float(entity m, string topic, float chan, float attn) AI_TalkSay =
{
	if (m.ai_talk_group == "" || !m.ai_talk_group)
		return FALSE;

	if (m.spawnflags & SF_MON_PRE_DISASTER)
		if (Sentences_Speak(m, strcat(m.ai_talk_group, "_P", topic), chan, 1, attn))
		{
			ai_dbg_lines = ai_dbg_lines + 1;
			return TRUE;
		}

	if (Sentences_Speak(m, strcat(m.ai_talk_group, "_", topic), chan, 1, attn))
	{
		ai_dbg_lines = ai_dbg_lines + 1;
		return TRUE;
	}
	return FALSE;
};

// ---------------------------------------------------------------------------
// being shot by a player
// ---------------------------------------------------------------------------
// Two separate Half-Life behaviours meet here, and keeping them apart is most of
// the work.  They were previously ONE thing and it was the wrong thing:
// AI_HeardGunfire played the SCARED group on every gunshot inside 1280 units,
// so scientists complained at you constantly while you were fighting for them.
//
//   1. THE VICTIM escalates.  barney.cpp:509-546.
//   2. A FRIEND of the victim tells you off.  talkmonster.cpp:1193-1211 finds the
//      nearest OTHER talker and hands it slIdleStopShooting, whose one task
//      speaks m_szGrp[TLK_NOSHOOT] - which scientist.cpp:745 sets to "SC_SCARED".
//
// So SC_SCARED was never a fear line at all.  It is "stop shooting my friend",
// it belongs to a BYSTANDER rather than to the person being shot, and it fires
// when a player damages a talker - never merely because a gun went off.  That
// single misreading is the whole complaint.

// HL's IsFacing (barney.cpp:491-506): did the player mean it?  Flattened to 2D
// and compared against 0.96, which the SDK's own comment calls "+/- 15 degrees or
// so".  v_angle rather than .angles, because a player's body yaw is not where
// they are aiming.
float(entity plyr, vector at) AI_PlayerIsFacing =
{
	vector dir = at - plyr.origin;
	dir_z = 0;
	if (dir == '0 0 0')
		return TRUE;		// standing inside them; no meaningful direction
	dir = normalize(dir);

	vector ang = plyr.v_angle;
	ang_x = 0;
	makevectors(ang);

	float dot = v_forward * dir;
	if (ai_cached_debug)
		dprint(sprintf("[ai] IsFacing: v_angle=%v dir=%v dot=%g -> %s\n",
		               plyr.v_angle, dir, dot, (dot > 0.96) ? "DELIBERATE" : "stray"));
	return dot > 0.96;
};

// The bystander line.  Nearest OTHER live talker within earshot says it.
const float TALK_NOSHOOT_DIST = 1024;

void(entity victim, entity plyr) AI_TalkFriendShot =
{
	entity best = world;
	float  bd   = TALK_NOSHOOT_DIST;

	entity f = monster_chain_head;
	while (f)
	{
		if (f != victim && f.ai_talker && f.health > 0 && f.ai_state != MS_DEAD)
		if (time >= f.ai_noshoot_next)
		{
			float d = vlen(f.origin - victim.origin);
			if (d < bd)
			{
				bd = d;
				best = f;
			}
		}
		f = f.monster_chain_next;
	}

	if (!best)
		return;

	// 4 s is HL's own spacing for this group (RANDOM_FLOAT(2.8, 3.2) of speech
	// plus the schedule it sits in); the limit is per-speaker so a crowd does not
	// chorus, and it is checked in the search above so a rate-limited friend does
	// not shadow a further-away one that could actually speak.
	best.ai_noshoot_next = time + 4;
	ai_dbg_noshoot = ai_dbg_noshoot + 1;
	AI_LookAt(best, plyr);
	// "SCARED", not "NOSHOOT".  TLK_NOSHOOT is the SLOT; the GROUP behind it is
	// BA_SCARED / SC_SCARED (barney.cpp:470, scientist.cpp:745), and those are the
	// names that exist in sentences.txt - verified, along with BA_MAD and BA_SHOT
	// below.  Naming the slot here would resolve to BA_NOSHOOT and find nothing.
	AI_TalkSay(best, "SCARED", CHAN_VOICE, ATTN_NORM);
};

void(entity m, entity plyr, float dmg) AI_TalkDamaged =
{
	if (m.health <= 0 || m.ai_state == MS_DEAD)
		return;

	// (2) first - HL calls CTalkMonster::TakeDamage before the Barney override,
	// so the bystander speaks whether or not the victim ends up provoked.
	AI_TalkFriendShot(m, plyr);

	m.ai_playerdmg = m.ai_playerdmg + dmg;
	ai_dbg_plhit   = ai_dbg_plhit + 1;

	// SCIENTISTS DO NOT ESCALATE - they provoke on the first hit, silently.
	// scientist.cpp:771-778 is four lines with no facing test, no accumulated
	// damage, no crossfire exemption and no line, where barney.cpp:509-546 has
	// all five.  That is not an oversight in the SDK: BA_MAD and BA_SHOT exist in
	// sentences.txt and SC_MAD and SC_SHOT do not, so a scientist has nothing to
	// say about it and Valve did not give him a warning shot.
	//
	// Faithful, and survivable only because the grudge expires.
	if (m.ai_provoke_instant)
	{
		m.ai_memory = m.ai_memory | MEMORY_PROVOKED;
		ai_dbg_provoked = ai_dbg_provoked + 1;

		float sgrudge = cvar("sv_ai_grudge_time");
		m.ai_grudge_end = (sgrudge > 0) ? time + sgrudge : 0;

		m.ai_follow   = world;
		m.ai_taskdone = TRUE;
		m.ai_cond     = m.ai_cond | COND_SCHEDULE_DONE;
		return;
	}

	// THE CROSSFIRE EXEMPTION, and it is the reason this is faithful rather than
	// merely aggressive.  HL only escalates when the victim has NO enemy
	// (barney.cpp:522): if he is already fighting something, a round in the back
	// is assumed to be a stray from the same fight and is forgiven with a
	// grumble.  Without it, every co-op firefight ends with your escort shooting
	// you - which is exactly what "shoot back when I mean it" must not become.
	if (m.ai_enemy)
	{
		if (m.ai_enemy.classname != "player")
			AI_TalkSay(m, "SHOT", CHAN_VOICE, ATTN_NORM);
		return;
	}

	if ((m.ai_memory & MEMORY_SUSPICIOUS) || AI_PlayerIsFacing(plyr, m.origin))
	{
		// Second offence, or a deliberate first one.  Now he means it.
		AI_TalkSay(m, "MAD", CHAN_VOICE, ATTN_NORM);
		m.ai_memory = m.ai_memory | MEMORY_PROVOKED;
		ai_dbg_provoked = ai_dbg_provoked + 1;

		float grudge = cvar("sv_ai_grudge_time");
		if (grudge <= 0)
			m.ai_grudge_end = 0;		// HL parity: never forgives
		else
			m.ai_grudge_end = time + grudge;

		// StopFollowing.  HL suppresses the usual "wait here" line when provoked
		// (talkmonster.cpp:1368) - he is not politely staying put, he is done -
		// so the escort ends silently and MAD is the only thing he says.
		m.ai_follow = world;

		// Take him now rather than waiting for the next decision tick: he has
		// just announced he is angry and must not then stand still for half a
		// second.  AI_ValidEnemy will accept the player from here because
		// AI_RelationshipEnt now returns R_HATE for him.
		m.ai_taskdone = TRUE;
		m.ai_cond     = m.ai_cond | COND_SCHEDULE_DONE;
		return;
	}

	// First hit, and you were not looking at him.  A warning, not a war.
	AI_TalkSay(m, "SHOT", CHAN_VOICE, ATTN_NORM);
	m.ai_memory = m.ai_memory | MEMORY_SUSPICIOUS;
	ai_dbg_suspicious = ai_dbg_suspicious + 1;
};

// ---------------------------------------------------------------------------
// the tick
// ---------------------------------------------------------------------------
// Called from AI_Think for every talker, AFTER the class's own ai_tick.
//
// That ordering is load-bearing.  Barney runs Grunt_Aim as his ai_tick, which
// points controller 0 at his ENEMY; this must not fight it.  So the head-turn
// below only runs when there is no enemy - in a fight the gun wins, out of a
// fight the conversation does.
void(entity m) AI_TalkTick =
{
	ai_dbg_talkers = ai_dbg_talkers + 1;

	// Keep any in-flight sentence moving regardless of state: a monster that
	// starts a line and then gets shot should finish the word, not cut out.
	Sentences_Pump(m);

	if (m.health <= 0 || m.ai_state == MS_DEAD)
	{
		m.bonecontrol1 = 0;
		m.bonecontrol5 = 0;
		return;
	}

	// --- the jaw -----------------------------------------------------------
	// A crude open/closed flutter while a line plays.  HL drives this from the
	// sample's amplitude envelope, which needs the audio data; QC has none, so
	// this is a periodic wobble instead.  It reads correctly at conversational
	// distance and is enormously better than a jaw welded shut.
	if (Sentences_Speaking(m))
	{
		float open = 0.5 + 0.5 * sin(time * 22);
		m.bonecontrol5 = open * 25;	// engine clamps to the model's own max
	}
	else
		m.bonecontrol5 = 0;

	// --- the head ----------------------------------------------------------
	if (m.ai_enemy)
		return;				// fighting: the class aim owns controller 0

	entity look = m.ai_lookat;
	if (look && (time >= m.ai_lookend || look.health <= 0))
		look = m.ai_lookat = world;
	if (!look)
		look = AI_NearestPlayer(m, TALK_LOOK_DIST);

	if (look)
	{
		// Residual yaw, not absolute: the body may already be part-way round, and
		// the engine clamp is against the model's neck limit either way.
		m.bonecontrol1 = AI_AimResidualYaw(m, AI_AimPoint(look));
		ai_dbg_looks = ai_dbg_looks + 1;
	}
	else
	{
		// Ease back to neutral rather than snapping - a rank of scientists all
		// flicking their heads forward the instant you step away is worse than
		// them not tracking at all.
		m.bonecontrol1 = m.bonecontrol1 * 0.8;
		if (m.bonecontrol1 < 0.5 && m.bonecontrol1 > -0.5)
			m.bonecontrol1 = 0;
	}

	// --- speech ------------------------------------------------------------
	// GAG is Half-Life's "shut up until provoked" flag, and hl_c01_a1 relies on
	// it: several of its scientists carry spawnflag 258 (= PRE_DISASTER|GAG)
	// precisely so they do NOT chatter through the intro.  Honouring both the
	// flag and the Sven `gag` key costs one test.
	if (m.gag || (m.spawnflags & SF_MON_GAG))
		return;
	if (Sentences_Speaking(m))
		return;
	if (m.ai_talk_group == "" || !m.ai_talk_group)
		return;

	// Greet someone who has just come close, once per cooldown.
	entity near = AI_NearestPlayer(m, TALK_GREET_DIST);
	if (near && time >= m.ai_talk_greet)
	{
		m.ai_talk_greet = time + 20;
		m.ai_talk_next  = time + TALK_IDLE_MIN;
		AI_LookAt(m, near);
		AI_TalkSay(m, "HELLO", CHAN_VOICE, ATTN_NORM);
		return;
	}

	if (time >= m.ai_talk_next)
	{
		m.ai_talk_next = time + TALK_IDLE_MIN + random() * (TALK_IDLE_MAX - TALK_IDLE_MIN);
		// Only chatter with someone around to hear it.  An empty corridor full of
		// muttering scientists is not atmosphere, it is a sound budget leak.
		if (AI_NearestPlayer(m, TALK_LOOK_DIST))
			AI_TalkSay(m, "IDLE", CHAN_VOICE, ATTN_IDLE);
	}
};

// BUMP INTO ME AND I STEP ASIDE  —  CTalkMonster::Touch, talkmonster.cpp:876-896.
//
// Transcribed rather than approximated, because every clause in it is load-bearing
// and each one corresponds to a way the behaviour goes wrong without it:
//
//     if ( pOther->IsPlayer() )                     // only players jostle
//     {
//         if ( m_afMemory & bits_MEMORY_PROVOKED ) return;   // not if I hate you
//         if ( IsTalking() ) return;                         // stay put mid-line
//         float speed = fabs(velocity.x) + fabs(velocity.y);
//         if ( speed > 50 ) { SetConditions(bits_COND_CLIENT_PUSH);
//                             MakeIdealYaw(pOther->pev->origin); }
//     }
//
// The speed floor is why standing against a scientist does nothing while walking
// into one moves him: leaning is not shoving.  HL sums the two axes rather than
// taking the vector length, and that is kept - it is a cheaper, slightly more
// generous test, and matching it means the threshold behaves identically.
//
// MakeIdealYaw is not cosmetic either.  It aims .ai_yaw_ideal at the player, and
// TASK_GET_PATH_AWAY retreats along `ai_yaw_ideal + 180` - so this call is what
// decides WHICH WAY "away" is.  Without it the scientist would step aside in
// whatever direction he happened to be facing.
//
// Reachable at all only because SV_CheckTouchTriggers (sv_use.qc:425-446) walks
// FL_MONSTER entities and calls .touch: this mod's players are MOVETYPE_NONE under
// the QC pmove, so the engine emits no impact pairs for them and that sweep is the
// only touch dispatcher there is.
void() AI_TalkerTouch =
{
	if (!(other.flags & FL_CLIENT) || other.health <= 0)
		return;
	if (self.health <= 0 || self.ai_state == MS_DEAD || self.ai_script)
		return;
	if (self.ai_enemy == other)
		return;				// bits_MEMORY_PROVOKED: you are the problem
	if (Sentences_Speaking(self))
		return;				// "Stay put during speech"

	if (fabs(other.velocity_x) + fabs(other.velocity_y) <= 50)
		return;				// leaning, not pushing

	self.ai_cond    = self.ai_cond | COND_CLIENT_PUSH;
	self.ai_pushpos = other.origin;
	self.ai_yaw_ideal = vectoyaw(other.origin - self.origin);

	// Glance at whoever shoved you.  This stands in for the TASK_FACE_PLAYER that
	// closes HL's tlMoveAway: the walk overwrites .ai_yaw_ideal every tick with the
	// direction of travel, so a facing task at the end of the schedule would aim
	// the wrong way, while the look layer holds a target across the whole move.
	AI_LookAt(self, other);
};

// Mark a class as a talker.  `grp` is the sentences.txt prefix: HL names its
// groups <PREFIX>_<TOPIC><n>, so "SC" reaches SC_IDLE0.., SC_HELLO0.., and the
// pain/fear sets a later pass can use.
void(entity m, string grp) AI_MakeTalker =
{
	m.ai_talker    = TRUE;
	m.ai_talk_group = grp;
	// The touch hook, installed here because "is a talker" is exactly the set of
	// classes CTalkMonster::Touch applies to.  Never stamped over a class that
	// already wants its own contact behaviour - nothing in the talker set does
	// today, but the barnacle and the cockroach both do, and a silent overwrite
	// here would be very hard to find later.
	if (!m.touch)
		m.touch = AI_TalkerTouch;
	// Stagger the first line so a room of scientists does not open in unison.
	m.ai_talk_next = time + 4 + random() * TALK_IDLE_MAX;
};

// Reported alongside the movement and combat counters.  `talkers` is per-tick
// hook calls, `looks` is ticks that actually aimed a head at somebody, and
// `lines` is sentences that really started - the last of these being the one
// that separates "the talk layer ran" from "the talk layer spoke".
void() AI_ReportTalk =
{
	if (!ai_dbg_talkers)
		return;
	dprint(sprintf("[ai]   talk: ticks=%g looks=%g lines=%g\n",
	               ai_dbg_talkers, ai_dbg_looks, ai_dbg_lines));

	// Second line, and only when something actually happened - the grudge path is
	// player-driven, so on a headless drive with no shooter it is silent and an
	// unconditional row of zeroes would just be noise.
	//
	// READ IT AS A FUNNEL: plhit is how often a player hurt an ally, and susp +
	// prov should account for the ones with no enemy at the time.  A plhit count
	// far above susp+prov means the crossfire exemption is doing its job; the two
	// being EQUAL means it is not firing and every stray round is escalating.
	// forgiven MUST be in this gate.  It fires seconds after the hit that caused
	// it, by which time plhit and noshoot have been reset to 0 - so gating on
	// those alone made the one counter that proves the grudge EXPIRES the one
	// counter that could never be printed.
	if (ai_dbg_plhit || ai_dbg_noshoot || ai_dbg_forgiven)
		dprint(sprintf("[ai]   grudge: plhit=%g susp=%g prov=%g forgiven=%g noshoot=%g\n",
		               ai_dbg_plhit, ai_dbg_suspicious, ai_dbg_provoked,
		               ai_dbg_forgiven, ai_dbg_noshoot));

	// staleenemy is the guards-shooting-bodies counter.  ONE per kill is correct
	// and healthy: it is the single condition pass in which the killer notices its
	// enemy has died.  A number that tracks the number of THINKS rather than the
	// number of kills means AI_ValidEnemy's deadflag test has stopped working and
	// the body is a valid target again.
	if (ai_dbg_corpse_hit || ai_dbg_corpse_gib || ai_dbg_corpse_enemy)
		dprint(sprintf("[ai]   corpses: hit=%g chipped=%g gibbed=%g staleenemy=%g\n",
		               ai_dbg_corpse_hit, ai_dbg_corpse_chip, ai_dbg_corpse_gib,
		               ai_dbg_corpse_enemy));
	ai_dbg_corpse_hit = 0; ai_dbg_corpse_chip = 0; ai_dbg_corpse_gib = 0;
	ai_dbg_corpse_enemy = 0;

	// Player-vs-monster contact.  Structurally 0 before the monster branch was
	// added to SV_CheckTouchTriggers, and the prerequisite for both the roach
	// squish and the bump-away behaviour.
	if (sv_dbg_monster_touch)
		dprint(sprintf("[ai]   player touched monsters: %g\n", sv_dbg_monster_touch));
	sv_dbg_monster_touch = 0;

	// scripted_sentence speaker binding.  named/total, and they must be equal:
	// every one of the 758 scripted_sentences in the corpus carries an `entity`
	// key, so a shortfall means ED_ParseUnknownEpair is not seeing it and the
	// line will come out of a point entity with no jaw.  NOT reset - this is
	// spawn-time state, not a per-report tally.
	if (sv_dbg_sent_total)
		dprint(sprintf("[ai]   scripted_sentence speakers: %g named / %g total\n",
		               sv_dbg_sent_named, sv_dbg_sent_total));

	// Bodygroups.  "armed" counts live monsters whose rig HAS a weapon bodygroup
	// and whose .body is currently the armed value - i.e. guns actually in hands.
	// Structurally zero before Patch 131, because nothing ever wrote .body and
	// the renderer read a hardcoded 0 anyway.
	float bg_armed = 0, bg_rigged = 0;
	entity bm = monster_chain_head;
	while (bm)
	{
		if (bm.ai_body_armed != bm.ai_body_gone)	// this rig has a weapon group
		{
			bg_rigged = bg_rigged + 1;
			if (bm.body == bm.ai_body_armed)
				bg_armed = bg_armed + 1;
		}
		bm = bm.monster_chain_next;
	}
	if (bg_rigged)
		dprint(sprintf("[ai]   bodygroups: %g armed / %g with a weapon group\n",
		               bg_armed, bg_rigged));

	if (ai_dbg_shots_grunt || ai_dbg_shots_barney || ai_dbg_shots_assassin)
		dprint(sprintf("[ai]   shots: grunt=%g barney=%g assassin=%g\n",
		               ai_dbg_shots_grunt, ai_dbg_shots_barney, ai_dbg_shots_assassin));
	ai_dbg_shots_grunt = 0; ai_dbg_shots_barney = 0; ai_dbg_shots_assassin = 0;

	ai_dbg_talkers = 0; ai_dbg_looks = 0; ai_dbg_lines = 0;
	ai_dbg_plhit = 0; ai_dbg_suspicious = 0; ai_dbg_provoked = 0;
	ai_dbg_forgiven = 0; ai_dbg_noshoot = 0;
};
