// server/monsters/mon_swimfly.qc
// ----------------------------------------------------------------------------
// The classes that do not walk: two swimmers and a flyer.
//
//   monster_leech (200)          AIMODE_SWIM
//   monster_ichthyosaur (63)     AIMODE_SWIM
//   monster_alien_controller (135)  AIMODE_FLY
//
// These are the first real consumers of the locomotion modes built in W1c.  Until
// now both were exercised only through sv_ai_forcemode, which proved the physics
// worked but never proved a CLASS could be written against them.
//
// models/leech.mdl (8 sequences, valve) — the interesting one:
//   act  6  swim / swim2   31f @40 loop      <- ACT_SWIM, not ACT_WALK
//   act 30  attack         31f @150 loop, code 1 @0.00s
//   act 24  hover          act 15/16 turns   act 36/38 deaths
//   There is NO walk and NO run.  The movement tasks always ask for ACT_WALK or
//   ACT_RUN, so AI_ActivityFallback now routes WALK -> SWIM before IDLE; without
//   that the leech glided everywhere in its hover pose.
//
// models/icky.mdl (16 sequences, 4 bone controllers):
//   act  1  idle    act 3 "swim" 101f @50 loop   act 4 "thrust" 18f @17 loop
//   act 30  bite_r (code 1 @0.60s) / bite_l (code 2 @0.60s)
//           srattack1 52f @30 (code 1 @0.47s, code 2 @0.87s)
//   Note it tags its cruise and sprint as WALK and RUN, so unlike the leech it
//   needs no fallback help at all.
//
// models/controller.mdl (19 sequences):
//   act  1  float (loop)   act 3 walk   act 4 run   act 36 die1
//   act 28  attack1 / attack2, LOOP, powerup + small-shoot events
//   act 29  shoot 71f @30: code 1 @0.93s HEAD_OPEN, code 2 @1.87s BALL_SHOOT
//   act 30  throw / idle2 / block
//   The directional sequences (forward/backward/up/down/left/right) are act 0 and
//   are HL's strafing set; nothing here drives them.
// ----------------------------------------------------------------------------

// --- leech (leech.cpp) ---
const float LEECH_AE_BITE = 1;

// --- ichthyosaur (ichthyosaur.cpp) ---
const float ICKY_AE_SHAKE_RIGHT = 1;
const float ICKY_AE_SHAKE_LEFT  = 2;

// --- alien controller (controller.cpp) ---
const float CTRL_AE_HEAD_OPEN     = 1;
const float CTRL_AE_BALL_SHOOT    = 2;
const float CTRL_AE_SMALL_SHOOT   = 3;
const float CTRL_AE_POWERUP_FULL  = 4;
const float CTRL_AE_POWERUP_HALF  = 5;

// Voice families, verified file-by-file against the mounts before they were
// written down (scratchpad sndls.py) and against the SDK tables for WHICH members
// Half-Life actually uses.  Both halves of that mattered here:
//
//   controller/con_fire1.wav and con_fire2.wav DO NOT EXIST, in valve, gearbox,
//   svencoop or any loose directory.  They were in this file, precached (two
//   failing slots at every map load) and played on every energy ball, which is why
//   the controller's attack has always been silent.  The real family is
//   con_attack1-3 (controller.cpp:119-121).
//
//   ichy/ichy_bite3.wav does not exist either, and the bite rolled 1..3 - so one
//   ichthyosaur bite in three was silent.  Half-Life's pBiteSounds is two entries
//   (ichthyosaur.cpp:167-171).
//
//   The ichthyosaur's pain, alert and death families all have HOLES that a %g roll
//   would have fallen into: HL takes pain 2/3/5, alert 2/3 and die 2/4, skipping
//   ichy_pain1, ichy_alert1, ichy_die1 and ichy_die3 - every one of which is on
//   disk and none of which Valve uses.
const string SND_LEECH_BITE  = "leech/leech_bite1.wav leech/leech_bite2.wav leech/leech_bite3.wav";
const string SND_LEECH_ALERT = "leech/leech_alert1.wav leech/leech_alert2.wav";

const string SND_ICKY_BITE   = "ichy/ichy_bite1.wav ichy/ichy_bite2.wav";
const string SND_ICKY_IDLE   = "ichy/ichy_idle1.wav ichy/ichy_idle2.wav ichy/ichy_idle3.wav ichy/ichy_idle4.wav";
const string SND_ICKY_ALERT  = "ichy/ichy_alert2.wav ichy/ichy_alert3.wav";
const string SND_ICKY_PAIN   = "ichy/ichy_pain2.wav ichy/ichy_pain3.wav ichy/ichy_pain5.wav";
const string SND_ICKY_DIE    = "ichy/ichy_die2.wav ichy/ichy_die4.wav";

const string SND_CTRL_ATTACK = "controller/con_attack1.wav controller/con_attack2.wav controller/con_attack3.wav";
const string SND_CTRL_IDLE   = "controller/con_idle1.wav controller/con_idle2.wav controller/con_idle3.wav controller/con_idle4.wav controller/con_idle5.wav";
const string SND_CTRL_ALERT  = "controller/con_alert1.wav controller/con_alert2.wav controller/con_alert3.wav";
const string SND_CTRL_PAIN   = "controller/con_pain1.wav controller/con_pain2.wav controller/con_pain3.wav";
const string SND_CTRL_DIE    = "controller/con_die1.wav controller/con_die2.wav";

void() SwimFly_Precache =
{
	precache_model("models/leech.mdl");
	precache_model("models/icky.mdl");
	precache_model("models/controller.mdl");

	AI_SndPrecache(SND_LEECH_BITE);
	AI_SndPrecache(SND_LEECH_ALERT);
	AI_SndPrecache(SND_ICKY_BITE);
	AI_SndPrecache(SND_ICKY_IDLE);
	AI_SndPrecache(SND_ICKY_ALERT);
	AI_SndPrecache(SND_ICKY_PAIN);
	AI_SndPrecache(SND_ICKY_DIE);
	AI_SndPrecache(SND_CTRL_ATTACK);
	AI_SndPrecache(SND_CTRL_IDLE);
	AI_SndPrecache(SND_CTRL_ALERT);
	AI_SndPrecache(SND_CTRL_PAIN);
	AI_SndPrecache(SND_CTRL_DIE);
};

// ---------------------------------------------------------------------------
// leech
// ---------------------------------------------------------------------------
void() Leech_Event =
{
	if (ai_event_code != LEECH_AE_BITE)
		return;

	float d = cvar("sv_ai_leech_dmg");
	if (d <= 0)
		d = 8;
	// A small hull: a leech is tiny and its bite should not reach past its body.
	// Reach comes from ai_melee_range so the swing can never be shorter than the
	// range that triggered it - the mismatch that cost the stukabat every hit.
	// Picked from the family but emitted directly: the leech is the one class whose
	// two families want different attenuations (bite ATTN_NORM, alert ATTN_NORM*0.5
	// - leech.cpp:281 vs :289) and .ai_snd_atten is per-entity, not per-family.
	if (AI_MeleeHull(self, self.ai_melee_range, d, 8) != world)
		if (!self.gag)
			AI_Sound(self, CHAN_WEAPON, AI_SndPick(SND_LEECH_BITE), 1, ATTN_NORM);
	self.ai_nextattack = time + 1.0;
};

void(entity m) Leech_ClassInit =
{
	m.ai_class    = CLASS_INSECT;		// HL's CLeech::Classify
	m.ai_movemode = AIMODE_SWIM;

	m.ai_melee_range = 40;
	m.ai_range_range = 0;			// no ranged attack at all

	// Swim speeds.  The cycles are 31f @40, i.e. very quick, and a leech that
	// crawls looks broken rather than slow.
	m.ai_speed_walk = 60;
	m.ai_speed_run  = 130;
	m.ai_yaw_speed  = 240;			// they turn on the spot in water

	m.ai_event = Leech_Event;

	// HL gives the leech an alert voice and nothing else - no pain, no death
	// (leech.cpp declares only pAttackSounds and pAlertSounds).  ATTN_NORM*0.5
	// carries it 2500 units, which is deliberate: it is a warning to the player,
	// not a noise the leech makes for itself.  PITCH_NORM, so no jitter.
	m.ai_snd_alert = SND_LEECH_ALERT;
	m.ai_snd_atten = ATTN_NORM * 0.5;
	m.ai_snd_pitch = -1;

	if (m.bloodcolor == 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// ichthyosaur
// ---------------------------------------------------------------------------
void() Ichthyosaur_Event =
{
	if (ai_event_code != ICKY_AE_SHAKE_RIGHT && ai_event_code != ICKY_AE_SHAKE_LEFT)
		return;

	float d = cvar("sv_ai_ichthyosaur_dmg");
	if (d <= 0)
		d = 35;				// HL sk_ichthyosaur_shake - it hits hard
	if (AI_MeleeHull(self, 90, d, 32) != world)
		AI_SndPlay(self, CHAN_WEAPON, SND_ICKY_BITE);
	self.ai_nextattack = time + 2.0;
};


// Per-activity turn rate, ichthyosaur.cpp:393.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Ichthyosaur_YawSpeed =
{
	return 100;						// hardcoded in HL
};

void(entity m) Ichthyosaur_ClassInit =
{
	m.ai_yawspeed   = Ichthyosaur_YawSpeed;
	m.ai_class    = CLASS_ALIEN_MONSTER;
	m.ai_movemode = AIMODE_SWIM;

	m.ai_melee_range = 90;			// a big animal with a big bite
	m.ai_range_range = 0;

	m.ai_speed_walk = 90;
	m.ai_speed_run  = 300;			// "thrust" is the sprint; it is fast
	m.ai_yaw_speed  = 150;

	m.ai_event = Ichthyosaur_Event;

	// EMIT_ICKY_SOUND (ichthyosaur.cpp:186-187) is the class's own emit macro:
	// attenuation 0.6 and pitch 95-105 on every family.  0.6 reaches 1667 units,
	// two thirds again as far as ATTN_NORM - it is a big animal in open water.
	m.ai_snd_idle  = SND_ICKY_IDLE;
	m.ai_snd_alert = SND_ICKY_ALERT;
	m.ai_snd_pain  = SND_ICKY_PAIN;
	m.ai_snd_die   = SND_ICKY_DIE;
	m.ai_snd_atten = 0.6;

	if (m.bloodcolor == 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// alien controller
// ---------------------------------------------------------------------------
void() Controller_Event =
{
	if (ai_event_code == CTRL_AE_BALL_SHOOT || ai_event_code == CTRL_AE_SMALL_SHOOT)
	{
		float d = cvar("sv_ai_controller_dmg");
		if (d <= 0)
			d = 12;
		// The energy ball reuses the existing beam rather than inventing a
		// projectile sprite: it is an energy discharge and the beam already works.
		if (self.ai_enemy)
			AI_FireBeam(self, self.ai_enemy, HL_BEAM_EGON, d);
		// CHAN_VOICE, not CHAN_WEAPON: HL's AttackSound goes through the same
		// EMIT_SOUND_ARRAY_DYN as its idle and alert lines (controller.cpp:254).
		AI_SndPlay(self, CHAN_VOICE, SND_CTRL_ATTACK);
		self.ai_nextattack = time + 2.0;
		return;
	}
	// HEAD_OPEN and the two POWERUP codes are the charge-up beats, and they were
	// explicit no-ops: a controller winding up its attack showed nothing at all,
	// so its one dangerous beat had no tell.
	//
	// HL hangs a per-HAND xspark4.spr off these (controller.cpp:851) and this
	// port still has no per-hand attachment to hang anything on - that part of
	// the old comment stands.  What it does have is a mouth point, and one
	// charge glow at the head is a truthful approximation of two at the hands in
	// a way that "nothing" is not.
	//
	// Yellow-orange, and that is measured: xspark4.spr's 256-entry palette runs
	// (255,252,14) (226,197,9) (188,134,0) (151,80,0).  The controller reads as a
	// blue creature and its energy is not blue.
	if (ai_event_code == CTRL_AE_HEAD_OPEN
	 || ai_event_code == CTRL_AE_POWERUP_FULL || ai_event_code == CTRL_AE_POWERUP_HALF)
	{
		AlienFX_Multicast(ALIENFX_CTRL_BALL, AlienFX_MouthPos(self, 10), '0 0 0');
		return;
	}
};


// Per-activity turn rate, controller.cpp:167-179.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Controller_YawSpeed =
{
	return 120;						// flat in HL
};

void(entity m) Controller_ClassInit =
{
	m.ai_yawspeed   = Controller_YawSpeed;
	m.ai_fov      = -1;		// VIEW_FIELD_FULL, controller.cpp:373
	m.ai_class    = CLASS_ALIEN_MILITARY;
	m.ai_movemode = AIMODE_FLY;

	// Cruising clearance above the floor.  AI_PlaceInVolume settles it here at
	// spawn and AI_MoveAlongPath lifts every nav waypoint by the same amount, so
	// it follows the floor-level graph without descending to ankle height.
	m.ai_flyheight = 64;

	m.ai_melee_range = 0;			// it never closes; it hovers and shoots
	m.ai_range_range = 1024;

	m.ai_speed_walk = 70;
	m.ai_speed_run  = 160;
	m.ai_yaw_speed  = 160;

	m.ai_event = Controller_Event;

	// Five idle lines, three alert, three pain, two death - all present in valve/,
	// none of them reachable until now: this class had no pain hook and no death
	// hook at all, and its two precached files were the only two names in the
	// family that do not exist.
	m.ai_snd_idle  = SND_CTRL_IDLE;
	m.ai_snd_alert = SND_CTRL_ALERT;
	m.ai_snd_pain  = SND_CTRL_PAIN;
	m.ai_snd_die   = SND_CTRL_DIE;

	if (m.bloodcolor == 0)
		m.bloodcolor = 195;
};

float() Leech_DefaultHealth
	= { float h = cvar("sv_ai_leech_health");        return (h > 0) ? h : 8;  };
float() Ichthyosaur_DefaultHealth
	= { float h = cvar("sv_ai_ichthyosaur_health");  return (h > 0) ? h : 200; };
float() Controller_DefaultHealth
	= { float h = cvar("sv_ai_controller_health");   return (h > 0) ? h : 60; };
