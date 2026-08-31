// server/monsters/mon_houndeye.qc
// ----------------------------------------------------------------------------
// monster_houndeye  —  231 placements.
//
// The first monster here whose attack is a RADIUS blast rather than a trace, so
// it is what AI_BlastAttack exists for.
//
// models/houndeye.mdl, read out of the file (31 sequences, 0 bone controllers):
//   act  1  idle1 / idle2(w20, loop) / idle3
//   act  3  walk2               36f @30 loop
//   act  4  run   (3 variants)  19f @30 loop
//   act  2  leaderlook          121f, two code-1 events
//   act 15/16  180l / 180r      loop
//   act 17/18/19  gotosleep / sleep / sleeptostand
//   act 26  flinch_small, flinch_small2
//   act 28  attack   60f @25 once:  code 2 @0.20s   STARTATTACK
//                                   code 3 @2.36s   THUMP   <- the blast
//   act 35  eat, act 46 inspect, act 47 madidle x3
//   act  7  wakefast, act 8 jumpback  29f: code 6 @0.20s  HOPBACK
//   act 36/37/38  deaths, each with an EVENT_BODYDROP
//
// THE TIMING IS THE WHOLE CLASS.  The blast lands 2.36 SECONDS into a 2.4-second
// animation — the houndeye rears up, holds, and only then thumps.  Firing on
// schedule entry would remove the entire tell that makes the attack dodgeable,
// which is the one thing players remember about this monster.
// ----------------------------------------------------------------------------

// houndeye.cpp event codes.
const float HE_AE_WARN        = 1;
const float HE_AE_STARTATTACK = 2;
const float HE_AE_THUMP       = 3;
const float HE_AE_ANGERSOUND1 = 4;
const float HE_AE_ANGERSOUND2 = 5;
const float HE_AE_HOPBACK     = 6;
const float HE_AE_CLOSE_EYE   = 7;

const float HE_HEALTH_DEFAULT = 20;	// HL sk_houndeye_health
const float HE_DMG_BLAST      = 15;	// HL sk_houndeye_dmg_blast
const float HE_BLAST_RADIUS   = 384;
const float HE_ATTACK_RANGE   = 384;	// it must be close for the blast to matter
const float HE_ATTACK_DELAY   = 3.0;

// houndeye.cpp:511-541, CHoundeye::WriteBeamColor.  THE RING COLOUR IS A SQUAD
// READOUT, and now that squads exist it can finally say what it was designed to
// say: the deeper and bluer the ring, the more houndeyes are about to thump you
// at once.  A solo houndeye gets the palest.
//
// Valve's table is not a smooth ramp and is reproduced rather than tidied - the
// step from 2 to 3 is the big one and 4 goes darker rather than bluer:
//   solo 188 220 255   |   2: 101 133 221   |   3: 67 85 255   |   4: 62 33 211
const vector HE_BEAM_COLOUR_SOLO = '188 220 255';
const vector HE_BEAM_COLOUR_2    = '101 133 221';
const vector HE_BEAM_COLOUR_3    = '67 85 255';
const vector HE_BEAM_COLOUR_4    = '62 33 211';

vector(entity m) Houndeye_BeamColour =
{
	float n = Squad_Count(m);
	if (n <= 1) return HE_BEAM_COLOUR_SOLO;
	if (n == 2) return HE_BEAM_COLOUR_2;
	if (n == 3) return HE_BEAM_COLOUR_3;
	// HL's default case for a squad bigger than 4 falls back to the SOLO colour
	// (houndeye.cpp:534-539, with an at_aiconsole complaint) - which reads as a
	// bug, since a bigger pack would suddenly look weaker than a smaller one.
	// Clamped to the four-strong colour instead, and said out loud.
	return HE_BEAM_COLOUR_4;
};

// How many eye textures houndeyeT.mdl actually carries.  HL's HOUNDEYE_EYE_FRAMES
// is 4 and it sets skin = 3, which is out of range for the three skin families
// the texture model really has (dumped from the file) and relies on the renderer
// clamping it back to 0.  Using the real count means the blink is the same three
// visible steps without depending on that clamp.
const float HE_EYE_FRAMES = 3;

void() Houndeye_Precache =
{
	precache_model("models/houndeye.mdl");
	precache_model(SHOCKWAVE_SPRITE);	// houndeye.cpp:386 precaches it too
	float i;
	for (i = 1; i <= 3; i = i + 1)
	{
		precache_sound(sprintf("houndeye/he_alert%g.wav",  i));
		precache_sound(sprintf("houndeye/he_attack%g.wav", i));
		precache_sound(sprintf("houndeye/he_blast%g.wav",  i));
		precache_sound(sprintf("houndeye/he_die%g.wav",    i));
		// THE SQUEAK.  he_hunt is the sound a houndeye makes while it is running
		// at you, and it was neither precached nor played by anything - the class
		// had five of HL's six voices and was missing the one players remember.
		precache_sound(sprintf("houndeye/he_hunt%g.wav",   i));
	}
	for (i = 1; i <= 4; i = i + 1)
		precache_sound(sprintf("houndeye/he_idle%g.wav", i));
	for (i = 1; i <= 5; i = i + 1)
		precache_sound(sprintf("houndeye/he_pain%g.wav", i));
};

// houndeye.cpp:427-444.  Called from two places in HL and we were doing neither:
// the HOUND_AE_WARN animation event, and PrescheduleThink.
void() Houndeye_WarnSound =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("houndeye/he_hunt%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Houndeye_IdleSound =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("houndeye/he_idle%g.wav", ceil(random() * 4)), 1, ATTN_NORM);
};

void() Houndeye_AlertSound =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("houndeye/he_alert%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Houndeye_PainSound =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("houndeye/he_pain%g.wav", ceil(random() * 5)), 1, ATTN_NORM);
};

void() Houndeye_Death =
{
	if (self.gag)
		return;
	AI_Sound(self, CHAN_VOICE, sprintf("houndeye/he_die%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// anim events
// ---------------------------------------------------------------------------
void() Houndeye_Event =
{
	if (ai_event_code == HE_AE_STARTATTACK)
	{
		// The wind-up growl, 0.20 s in.  Purely the tell — no damage here.
		if (!self.gag)
			AI_Sound(self, CHAN_WEAPON, sprintf("houndeye/he_attack%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
		return;
	}

	if (ai_event_code == HE_AE_THUMP)
	{
		// 2.36 s in: the sonic blast.  Radius damage centred on the houndeye
		// itself, so backing off during the wind-up genuinely saves you.
		if (!self.gag)
			AI_Sound(self, CHAN_WEAPON, sprintf("houndeye/he_blast%g.wav", ceil(random() * 3)), 1, ATTN_NORM);

		// THE ATTACK, MADE VISIBLE.  houndeye.cpp:571-612 writes exactly two
		// TE_BEAMCYLINDER rings from the same centre - a wide one at the full
		// damage radius and a second at half of it - and that pair IS the whole
		// visual.  Without them the blast was a noise and an unexplained health
		// drop, which is the report.  16 units wide, 0.2 s, both HL's own.
		//
		// The inner ring is the one that carries the information: it reaches the
		// rim at the same moment the outer one does, so the gap between them
		// narrows as they travel and the eye reads a wavefront rather than two
		// unrelated circles.
		vector c  = self.origin + '0 0 16';
		vector bc = Houndeye_BeamColour(self);
		Shockwave_Multicast(c, HE_BLAST_RADIUS,     0.2, 16, bc, SHOCKWAVE_EXPAND);
		Shockwave_Multicast(c, HE_BLAST_RADIUS / 2, 0.2, 16, bc, SHOCKWAVE_EXPAND);

		float d = cvar("sv_ai_houndeye_dmg");
		if (d <= 0)
			d = HE_DMG_BLAST;

		// Falloff to ZERO at the rim, not to a quarter.  houndeye.cpp:641 is
		// `flAdjustedDamage -= (flDist / HOUNDEYE_MAX_ATTACK_RADIUS) * flAdjustedDamage`,
		// which reaches 0 exactly at the edge - so standing at the limit of the
		// blast really does mean taking nothing, and that is the whole reason
		// backing away from the wind-up is worth doing.
		AI_BlastAttack(self, HE_BLAST_RADIUS, d, 0);
		self.ai_nextattack = time + HE_ATTACK_DELAY;
		return;
	}

	if (ai_event_code == HE_AE_ANGERSOUND1 || ai_event_code == HE_AE_ANGERSOUND2)
	{
		if (!self.gag)
			AI_Sound(self, CHAN_VOICE, sprintf("houndeye/he_alert%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
		return;
	}

	// WARN is NOT a movement beat, and calling it one is what silenced the hunt
	// squeak.  houndeye.cpp:279-282 maps it straight to WarnSound().
	if (ai_event_code == HE_AE_WARN)
	{
		Houndeye_WarnSound();
		return;
	}

	// HOPBACK and CLOSE_EYE genuinely are movement and eyelid beats.  The hop is
	// a squad-retreat behaviour that belongs with the squad work, so these stay
	// no-ops rather than an approximation of something else.
};

// ---------------------------------------------------------------------------
// per-tick: houndeye.cpp:846-870, CHoundeye::PrescheduleThink
// ---------------------------------------------------------------------------
// Runs at AI_TICK, which is Half-Life's own MonsterThink rate, so the two
// probabilities below carry across unconverted.
void() Houndeye_Tick =
{
	entity m = self;

	// "if the hound is mad and is running, make hunt noises."  This is the whole
	// answer to "houndeyes don't make their squeak noise": the sound is not on an
	// event and not on a schedule, it is a 20%-per-think roll while CHASING.  A
	// pack closing on you chatters constantly and a stationary one never does,
	// which is the entire character of the sound.
	if (m.ai_state == MS_COMBAT && m.ai_activity == ACT_RUN && random() < 0.2)
		Houndeye_WarnSound();

	// The blink.  houndeyeT.mdl carries the eye textures as skin families and
	// nothing in this mod has ever set .skin on a monster, so every houndeye in
	// the game has been staring without blinking.  1-in-128 per think at 10 Hz is
	// a blink every ~13 s, then one frame of eyelid per think on the way back.
	if (m.ai_activity == ACT_RANGE_ATTACK1)
	{
		// ...except during the attack, where HL deliberately scrambles it every
		// frame (houndeye.cpp:809) so the eye flickers while the hound charges.
		m.skin = floor(random() * HE_EYE_FRAMES);

		// The wind-up tell.  HL writes a TE_IMPLOSION every frame of the 2.4 s
		// charge - particles converging on the houndeye - and this engine has no
		// such temp entity either.  A ring running the other way reads the same
		// and costs one message instead of a particle system.
		//
		// Deliberately NOT once per tick: at 10 Hz a 2.4-second wind-up would be
		// 24 multicasts per houndeye per attack, and these arrive in packs.  A
		// 0.3 s ring emitted every 0.2 s overlaps continuously, so the
		// convergence still looks unbroken at half the traffic.
		if (time >= m.ai_nextimplode)
		{
			m.ai_nextimplode = time + 0.2;
			Shockwave_Multicast(m.origin + '0 0 16', HE_BLAST_RADIUS * 0.55,
			                    0.3, 10, HE_BEAM_COLOUR_SOLO, SHOCKWAVE_IMPLODE);
		}
		return;
	}

	if (m.skin != 0)
		m.skin = m.skin - 1;			// already blinking: open back up
	else if (random() < (1 / 128))
		m.skin = HE_EYE_FRAMES - 1;		// start blinking
};


// Per-activity turn rate, houndeye.cpp:207-233.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Houndeye_YawSpeed =
{
	if (act == ACT_CROUCHIDLE)	return 0;		// asleep: does not turn at all
	if (act == ACT_IDLE)		return 60;
	return 90;						// WALK, RUN, TURN, default
};

// houndeye.cpp:1272-1288.  Hurt, of either weight, and it backs off.
//
// HL rolls 40 % for SCHED_HOUND_HOP_RETREAT first - a scripted backward LEAP,
// taken only when a 128-unit hull trace behind the hound comes back clear - and
// falls through to ordinary cover otherwise.  The hop is not ported: it is a
// bespoke schedule built on TASK_HOUND_HOP_BACK, which sets a velocity and an
// activity houndeye.mdl does carry, and it belongs with the rest of that class's
// movement rather than with the cover mechanism.  Recorded here rather than
// silently dropped, because the two behaviours look quite different in play and
// somebody comparing against Half-Life will notice the leap is missing.
float() Houndeye_SelectSched =
{
	entity m = self;
	if (m.ai_state != MS_COMBAT || !m.ai_enemy)
		return SCHED_NONE;
	return Cover_ScheduleIfHurt(m);
};

void(entity m) Houndeye_ClassInit =
{
	m.ai_class = CLASS_ALIEN_MONSTER;	// HL's CHoundEye::Classify
	m.ai_selectsched = Houndeye_SelectSched;
	// THREE attack slots, squadmonster.h:41-44 - a looser ration than the
	// grunt's two, because a houndeye pack is supposed to overlap its blasts.
	m.ai_slots_attack = SQSLOTS_HOUND_ATTACK;

	// No melee at all: the blast IS the attack, and giving it a melee range would
	// let the generic ladder pick SCHED_MELEE_ATTACK1, which resolves to an
	// activity this model does not have.
	m.ai_melee_range = 0;
	m.ai_range_range = HE_ATTACK_RANGE;

	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   houndeye.mdl [15] walk2 36f @30fps ->  32.6
	//   houndeye.mdl [3/4/5] run 19f @30fps -> 409.6  (three identical variants)
	// 409 is the fastest ground speed in the base game after the assassin, and it
	// is why a houndeye pack closes on you the moment it notices.
	m.ai_speed_walk = 33;
	m.ai_speed_run  = 409;
	m.ai_yaw_speed  = 220;
	m.ai_yawspeed   = Houndeye_YawSpeed;

	m.ai_idlesound  = Houndeye_IdleSound;
	m.ai_alertsound = Houndeye_AlertSound;
	m.ai_painsound  = Houndeye_PainSound;
	m.ai_event      = Houndeye_Event;
	m.ai_death      = Houndeye_Death;
	m.ai_tick       = Houndeye_Tick;

	if (m.bloodcolor == 0)
		m.bloodcolor = 195;		// HL BLOOD_COLOR_GREEN
};

float() Houndeye_DefaultHealth =
{
	float h = cvar("sv_ai_houndeye_health");
	if (h <= 0)
		h = HE_HEALTH_DEFAULT;
	return h;
};
