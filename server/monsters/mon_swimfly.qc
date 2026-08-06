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

void() SwimFly_Precache =
{
	precache_model("models/leech.mdl");
	precache_model("models/icky.mdl");
	precache_model("models/controller.mdl");
	precache_sound("leech/leech_bite1.wav");
	precache_sound("leech/leech_bite2.wav");
	precache_sound("leech/leech_bite3.wav");
	precache_sound("ichy/ichy_bite1.wav");
	precache_sound("ichy/ichy_bite2.wav");
	precache_sound("ichy/ichy_bite3.wav");
	precache_sound("controller/con_fire1.wav");
	precache_sound("controller/con_fire2.wav");
	precache_sound("controller/con_die1.wav");
	precache_sound("controller/con_pain1.wav");
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
	if (AI_MeleeHull(self, self.ai_melee_range, d, 8) != world)
		if (!self.gag)
			sound(self, CHAN_WEAPON, sprintf("leech/leech_bite%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
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

	if (m.bloodcolor <= 0)
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
		if (!self.gag)
			sound(self, CHAN_WEAPON, sprintf("ichy/ichy_bite%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
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

	if (m.bloodcolor <= 0)
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
		if (!self.gag)
			sound(self, CHAN_WEAPON, sprintf("controller/con_fire%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
		self.ai_nextattack = time + 2.0;
		return;
	}
	// HEAD_OPEN and the two POWERUP codes are the charge-up beats.  HL hangs hand
	// sprites off them; with no per-hand attachment exposed here they are
	// deliberately no-ops rather than an invented approximation.
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

	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

float() Leech_DefaultHealth
	= { float h = cvar("sv_ai_leech_health");        return (h > 0) ? h : 8;  };
float() Ichthyosaur_DefaultHealth
	= { float h = cvar("sv_ai_ichthyosaur_health");  return (h > 0) ? h : 200; };
float() Controller_DefaultHealth
	= { float h = cvar("sv_ai_controller_health");   return (h > 0) ? h : 60; };
