// server/monsters/mon_islave.qc
// ----------------------------------------------------------------------------
// monster_alien_slave  (the Vortigaunt / "islave")
//
// 726 placements — the #2 classname in the whole corpus, behind only the
// headcrab, and the highest-value non-human class by a wide margin.  It is also
// the first monster here that attacks at range with something other than its own
// body, so it is what the beam half of sv_ai_combat.qc exists for.
//
// models/islave.mdl, read out of the file (30 sequences, 1 bone controller):
//   act  1  idle1(w1)/idle2(w2)/idle3(w8)   loop
//   act  3  walk1 / walk2      34f @15 loop
//   act  4  run1               26f @25 loop
//   act 15/16  right / left    turns
//   act 17  crouch             25f @15
//   act 26  flinch2, 73..76 per-limb flinches
//   act 28  zapattack1  35f @15 once:
//             code 3 @0.00s, 0.27s, 0.67s, 1.00s   ZAP_POWERUP (the charge-up)
//             code 4 @1.60s                        ZAP_SHOOT   <- the beam fires
//             code 5 @1.93s                        ZAP_DONE
//   act 30  attack1     33f @22 once: code 1 @0.32s, 0.59s, 0.95s   CLAW
//   act 32  collar1 / collar2   the revive animation (ACT_RELOAD)
//   act 36/37/38/66  deaths
//   [28] jibber / [29] jabber   loop, 1008 EVENT_SOUND_VOICE with real filenames
//
// TWO THINGS THE TABLE SETTLES that would otherwise have been guesswork:
//
//   The beam fires 1.6 SECONDS into the animation, after four charge-up events.
//   Firing it when the schedule starts the attack — the obvious implementation —
//   would make the slave shoot before it visibly raises its arms.
//
//   attack1 carries THREE claw events, not one.  A single swing lands three
//   separate hits in Half-Life, which is why an islave melee hurts so much more
//   than its per-hit damage suggests.
// ----------------------------------------------------------------------------

// Per-class anim event codes (islave.cpp).  Low codes are per-monster: the same
// number means something else entirely on another model.
const float SLV_AE_CLAW        = 1;
const float SLV_AE_CLAWRAKE    = 2;
const float SLV_AE_ZAP_POWERUP = 3;
const float SLV_AE_ZAP_SHOOT   = 4;
const float SLV_AE_ZAP_DONE    = 5;

const float SLV_HEALTH_DEFAULT = 60;	// HL sk_islave_health
const float SLV_DMG_CLAW       = 10;	// per event, and there are three per swing
const float SLV_DMG_ZAP        = 10;
const float SLV_MELEE_REACH    = 70;
const float SLV_ZAP_RANGE      = 1024;
// islave.cpp:678.  Below this it starts looking for somewhere to be; above it
// it fights.  HL's literal 20, against the class's 60 starting health.
const float SLV_COVER_HEALTH   = 20;
const float SLV_ATTACK_DELAY   = 2.5;

// HL's m_iBeams, used only as the charge-up pitch ladder: ZAP_POWERUP arrives four
// times on one sequence and each one is meant to sound higher than the last.
.float ai_zapstage;

void() Islave_Precache =
{
	precache_model("models/islave.mdl");

	// slv_alert2.wav DOES NOT EXIST in the shipped install — the set is 1, 3, 4.
	// Checked against the filesystem rather than assumed, because a tidy-looking
	// ceil(random()*4) would have asked for a missing file a quarter of the time.
	precache_sound("aslave/slv_alert1.wav");
	precache_sound("aslave/slv_alert3.wav");
	precache_sound("aslave/slv_alert4.wav");
	precache_sound("aslave/slv_die1.wav");
	precache_sound("aslave/slv_die2.wav");
	precache_sound("aslave/slv_pain1.wav");
	precache_sound("aslave/slv_pain2.wav");
	// The slv_word*.wav set is referenced by the jibber/jabber sequences' own
	// EVENT_SOUND_VOICE events, so AI_PrecacheModelSounds picks those up from the
	// model and they are deliberately not restated here.

	// THE ATTACK SOUNDS, which this class had none of - Islave_Event did not
	// contain a single sound() call, so both the claw and the zap were silent.
	// They are missing from aslave/ because Half-Life does not keep them there:
	// islave.cpp:327/332 borrows the ZOMBIE's claw set, :393 uses debris/zap4 for
	// the charge-up and :416 uses the assault cannon's report for the zap itself.
	// All nine verified present on disk.
	precache_sound("zombie/claw_strike1.wav");
	precache_sound("zombie/claw_strike2.wav");
	precache_sound("zombie/claw_strike3.wav");
	precache_sound("zombie/claw_miss1.wav");
	precache_sound("zombie/claw_miss2.wav");
	precache_sound("debris/zap4.wav");		// ZAP_POWERUP
	precache_sound("hassault/hw_shoot1.wav");	// ZAP_SHOOT
};

// The three alert variants are 1/3/4, not 1..3 — pick from a table, not a range.
void() Islave_AlertSound =
{
	if (self.gag)
		return;
	float r = ceil(random() * 3);
	string s = "aslave/slv_alert1.wav";
	if (r == 2) s = "aslave/slv_alert3.wav";
	if (r >= 3) s = "aslave/slv_alert4.wav";
	AI_Sound(self, CHAN_VOICE, s, 1, ATTN_NORM);
};

void() Islave_PainSound =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("aslave/slv_pain%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

void() Islave_Death =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("aslave/slv_die%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// arm beams
// ---------------------------------------------------------------------------
// CISlave::ArmBeam, islave.cpp:723-762, and it is worth saying what this is NOT:
// it is not a beam at the enemy.  The slave throws three sample rays at RANDOM
// angles out to the side and up/down from a point above its shoulder, keeps
// whichever hit CLOSEST, and hangs an arc between that spot and its hand.  So
// the arcs land on the wall, the ceiling, a crate - whatever happens to be near -
// and a slave charging in the open produces none at all, because nothing is close
// enough.  That is the behaviour, not a limitation of the port.
//
// Three samples and keep the nearest, exactly as HL does: one ray would as often
// as not fly off down a corridor and the arc would vanish for that powerup.
//
// `side` is -1 or +1 and picks which hand.  Half-Life resolves the hand through
// SetEndAttachment(1|2); attachments are not exposed to server QC on this engine,
// so the arc is anchored on the same hull-relative construction AI_MuzzlePos uses
// with a lateral offset - one wrong-in-a-known-way answer rather than two.
const float SLV_BEAM_REACH   = 512;	// islave.cpp:736, the sample ray length
const float SLV_BEAM_SAMPLES = 3;	// islave.cpp:733

void(entity m, float side) Islave_ArmBeam =
{
	makevectors([0, m.angles_y, 0]);

	// islave.cpp:731 - up 36, out 16 to the side, forward 32.
	vector src = m.origin + '0 0 36' + v_right * (side * 16) + v_forward * 32;

	float  best = 1;
	vector hit  = '0 0 0';
	float  i;

	for (i = 0; i < SLV_BEAM_SAMPLES; i = i + 1)
	{
		vector aim = v_right * (side * random()) + v_up * (random() * 2 - 1);
		if (aim == '0 0 0')
			continue;
		traceline(src, src + normalize(aim) * SLV_BEAM_REACH, FALSE, m);
		if (trace_fraction < best)
		{
			best = trace_fraction;
			hit  = trace_endpos;
		}
	}

	// "Couldn't find anything close enough" (islave.cpp:745).  HL returns without
	// creating a beam and so do we - an arc drawn to a point 512 units away in
	// open air is not what the effect is.
	if (best >= 1)
		return;

	ai_dbg_slave_arcs = ai_dbg_slave_arcs + 1;
	HLBeam_Multicast(HL_BEAM_ARC, m, hit, src);
};

// ---------------------------------------------------------------------------
// anim events
// ---------------------------------------------------------------------------
void() Islave_Event =
{
	if (ai_event_code == SLV_AE_CLAW || ai_event_code == SLV_AE_CLAWRAKE)
	{
		// islave.cpp:325-335: the sound depends on whether the swing CONNECTED -
		// three strike samples on a hit, two miss samples on a whiff.  That is
		// audible feedback the player reads without thinking about it, and it is
		// why the claw needs the hit result rather than just playing on the event.
		entity hit = AI_MeleeHull(self, SLV_MELEE_REACH, SLV_DMG_CLAW, 16);
		if (!self.gag)
		{
			if (hit)
				AI_Sound(self, CHAN_WEAPON,
				      sprintf("zombie/claw_strike%g.wav", ceil(random() * 3)),
				      1, ATTN_NORM);
			else
				AI_Sound(self, CHAN_WEAPON,
				      sprintf("zombie/claw_miss%g.wav", ceil(random() * 2)),
				      1, ATTN_NORM);
		}
		return;
	}

	if (ai_event_code == SLV_AE_ZAP_POWERUP)
	{
		// islave.cpp:389-397.  The charge-up, and it arrives FOUR times on the
		// zap sequence (0.00/0.27/0.67/1.00 s) with HL raising the pitch on each
		// one - which is what makes the wind-up read as building rather than
		// repeating.  m_iBeams is HL's counter for that; ai_zapstage is ours.
		// The counter is NOT inside the gag test any more.  .gag mutes a monster,
		// not its visuals, and the glow below is scaled by the stage - so a gagged
		// slave would have wound up four times at stage 0 and shown a flat flare
		// instead of a building one.
		self.ai_zapstage = self.ai_zapstage + 1;
		if (!self.gag)
			AI_SoundEx(self, CHAN_ITEM, "debris/zap4.wav", 1, ATTN_NORM,
			      100 + self.ai_zapstage * 10, 0);

		// islave.cpp:368-377 fires a TE_DLIGHT per powerup and this port had
		// SOUND ONLY - so the one tell that a zap is coming was audible and
		// invisible, on a class with 726 placements.  The colour is HL's own
		// dlight, 255/180/96.
		AlienFX_Multicast(ALIENFX_ZAP_CHARGE, AlienFX_MouthPos(self, 12), '0 0 0');

		// ...and the ARM BEAMS, islave.cpp:388-390.  Two per powerup, one from
		// each hand, accumulating up to ISLAVE_MAX_BEAMS as the wind-up builds -
		// which is what HL's BeamGlow ramp is for and why the slave gets visibly
		// angrier over the 1.6 s rather than simply glowing.
		Islave_ArmBeam(self, -1);
		Islave_ArmBeam(self,  1);
		return;
	}

	if (ai_event_code == SLV_AE_ZAP_SHOOT)
	{
		// The beam, 1.6 s into the animation and not a moment before.  EGON rather
		// than GAUSS: the electric-blue trail is the closer match to the
		// vortigaunt's zap, and both are pre-existing effects.
		if (!self.gag)
			AI_SoundEx(self, CHAN_WEAPON, "hassault/hw_shoot1.wav", 1, ATTN_NORM,
			      130 + floor(random() * 31), 0);	// islave.cpp:416, pitch 130-160
		if (self.ai_enemy)
		{
			// The muzzle flare goes out BEFORE the beam so the two arrive in the
			// same frame with the flare underneath - AI_FireBeam multicasts its
			// own event, and a flare drawn after it sits on top of the trail.
			vector zsrc = AI_MuzzlePos(self);
			AlienFX_Multicast(ALIENFX_ZAP_FIRE, zsrc,
			                  AI_AimDir(self, zsrc, self.ai_enemy, 0));
			AI_FireBeam(self, self.ai_enemy, HL_BEAM_EGON, SLV_DMG_ZAP);
		}
		self.ai_nextattack = time + SLV_ATTACK_DELAY;
		self.ai_zapstage = 0;
		return;
	}

	if (ai_event_code == SLV_AE_ZAP_DONE)
	{
		// islave.cpp:440 ClearBeams().  The arcs are one-shot particle trails with
		// their own `die` rather than persistent beam entities, so there is still
		// nothing to tear down here - but they now expire on their own inside the
		// window this event closes, which is what ClearBeams was for.
		self.ai_zapstage = 0;
		return;
	}
};

// ---------------------------------------------------------------------------
// attack preconditions
// ---------------------------------------------------------------------------
// The zap needs line of sight it will not get from inside melee range, and HL's
// CISlave::CheckRangeAttack1 refuses when the enemy is very close for exactly
// that reason.  Without this the slave stands nose-to-nose charging a beam.
void() Islave_CheckAttack =
{
	if (!self.ai_enemy)
		return;

	float d = vlen(self.ai_enemy.origin - self.origin);
	if (d <= SLV_MELEE_REACH)
		self.ai_cond = self.ai_cond & ~COND_CAN_RANGE1;
};


// Per-activity turn rate, islave.cpp:281-301.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Islave_YawSpeed =
{
	if (act == ACT_WALK)	return 50;
	if (act == ACT_RUN)	return 70;
	if (act == ACT_IDLE)	return 50;
	return 90;
};

// islave.cpp:679-695.  The alien slave is the ONLY class in the SDK that breaks
// for cover because it is being LOOKED at rather than because it has been hit,
// and it is the reason COND_ENEMY_FACING_ME exists at all.  That condition has
// been declared in this mod since the AI landed (sv_ai_defs.qc:298) with exactly
// one reference tree-wide - its own declaration - which is the same shape
// COND_FRIEND_DAMAGED was in before last patch.
//
// Both branches are gated on having no melee.  A slave with its claws already in
// reach does not retreat, and HL's nesting says so first, before either cover
// test.
float() Islave_SelectSched =
{
	entity m = self;
	if (m.ai_state != MS_COMBAT || !m.ai_enemy)
		return SCHED_NONE;

	// NEARLY DEAD, and this gate is the whole difference between a slave that
	// fights and one that spends every engagement hiding.
	//
	// It was missed on the first pass and the firetest caught it in one number:
	// the slave's damage to the player fell from the 50 recorded in PATCH 138 to
	// 10, while every other class on the roster held its figure.  A slave that
	// breaks for cover whenever it is LOOKED at breaks for cover permanently,
	// because a player in a fight is looking at it.
	//
	// HL wraps both cover branches in `if (pev->health < 20 || m_iBravery < 0)`
	// (islave.cpp:678) - out of 60 starting health, so the last third.  The
	// bravery half is NOT implemented: it counts visible slaves, plus one for
	// each living and minus one for each dead (islave.cpp:488-500), and this mod
	// unlinks a corpse from monster_chain in Monster_Teardown, so "how many of my
	// kind are lying dead near me" is not a question the chain can answer.  The
	// health term is the dominant one and is what the behaviour reads as.
	if (m.health >= SLV_COVER_HEALTH)
		return SCHED_NONE;

	// Claws already in reach beats retreating, and HL's nesting says so before
	// either cover test rather than after.
	if (m.ai_cond & COND_CAN_MELEE1)
		return SCHED_NONE;

	float cs = Cover_ScheduleIfHurt(m);
	if (cs != SCHED_NONE)
		return cs;

	if (m.ai_cond & COND_SEE_ENEMY)
		if (m.ai_cond & COND_ENEMY_FACING_ME)
			if (Cover_Allowed(m))
			{
				ai_dbg_cover_sched = ai_dbg_cover_sched + 1;
				return SCHED_TAKE_COVER;
			}

	return SCHED_NONE;
};

void(entity m) Islave_ClassInit =
{
	m.ai_class = CLASS_ALIEN_MILITARY;	// HL's CISlave::Classify

	m.ai_melee_range = SLV_MELEE_REACH;
	m.ai_range_range = SLV_ZAP_RANGE;

	// Hand-set for the same reason as every other class here: HL derives gait
	// speed from seq->linearmovement and no QC builtin exposes it.  run1 is 26f
	// @25 — a brisk cycle, so the run speed is well above the walk.
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   islave.mdl [4] walk1 34f @15fps ->  27.2
	//   islave.mdl [6] run1   26f @25fps -> 171.9
	m.ai_speed_walk = 27;
	m.ai_speed_run  = 172;
	m.ai_yaw_speed  = 180;
	m.ai_yawspeed   = Islave_YawSpeed;

	m.ai_checkattack = Islave_CheckAttack;
	m.ai_selectsched = Islave_SelectSched;
	m.ai_alertsound  = Islave_AlertSound;
	m.ai_painsound   = Islave_PainSound;
	m.ai_event       = Islave_Event;
	m.ai_death       = Islave_Death;

	if (m.bloodcolor == 0)
		m.bloodcolor = 195;		// HL BLOOD_COLOR_GREEN
};

float() Islave_DefaultHealth =
{
	float h = cvar("sv_ai_islave_health");
	if (h <= 0)
		h = SLV_HEALTH_DEFAULT;
	return h;
};
