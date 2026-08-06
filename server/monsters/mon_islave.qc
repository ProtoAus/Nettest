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
	sound(self, CHAN_VOICE, s, 1, ATTN_NORM);
};

void() Islave_PainSound =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("aslave/slv_pain%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

void() Islave_Death =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("aslave/slv_die%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
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
				sound(self, CHAN_WEAPON,
				      sprintf("zombie/claw_strike%g.wav", ceil(random() * 3)),
				      1, ATTN_NORM);
			else
				sound(self, CHAN_WEAPON,
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
		if (!self.gag)
		{
			self.ai_zapstage = self.ai_zapstage + 1;
			sound(self, CHAN_ITEM, "debris/zap4.wav", 1, ATTN_NORM,
			      100 + self.ai_zapstage * 10, 0);
		}
		return;
	}

	if (ai_event_code == SLV_AE_ZAP_SHOOT)
	{
		// The beam, 1.6 s into the animation and not a moment before.  EGON rather
		// than GAUSS: the electric-blue trail is the closer match to the
		// vortigaunt's zap, and both are pre-existing effects.
		if (!self.gag)
			sound(self, CHAN_WEAPON, "hassault/hw_shoot1.wav", 1, ATTN_NORM,
			      130 + floor(random() * 31), 0);	// islave.cpp:416, pitch 130-160
		if (self.ai_enemy)
			AI_FireBeam(self, self.ai_enemy, HL_BEAM_EGON, SLV_DMG_ZAP);
		self.ai_nextattack = time + SLV_ATTACK_DELAY;
		self.ai_zapstage = 0;
		return;
	}

	if (ai_event_code == SLV_AE_ZAP_DONE)
	{
		// islave.cpp:440 ClearBeams().  We have no persistent arm beams to clear,
		// so all this owns is resetting the charge-up pitch ladder.
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
	m.ai_alertsound  = Islave_AlertSound;
	m.ai_painsound   = Islave_PainSound;
	m.ai_event       = Islave_Event;
	m.ai_death       = Islave_Death;

	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;		// HL BLOOD_COLOR_GREEN
};

float() Islave_DefaultHealth =
{
	float h = cvar("sv_ai_islave_health");
	if (h <= 0)
		h = SLV_HEALTH_DEFAULT;
	return h;
};
