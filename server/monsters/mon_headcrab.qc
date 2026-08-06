// server/monsters/mon_headcrab.qc
// ----------------------------------------------------------------------------
// monster_headcrab.  705 placed across the Sven corpus, third by demand, and the
// class this whole AI layer was built against - it exercises every part of the
// stack (conditions, schedules, activities, anim events, walkmove pathing,
// damage, death) while depending on nothing another monster needs first.
//
// Everything model-shaped below was read out of models/headcrab.mdl rather than
// remembered; see the table at the top of sv_ai_defs.qc.  The two facts that
// shape this file:
//
//   The leap is an ANIMATION EVENT, not a schedule step.  All three jump
//   variants carry exactly one event, code 2, at t=0.000s.  The schedule starts
//   ACT_RANGE_ATTACK1 and the model decides when the crab leaves the ground.
//
//   The crab has no melee attack.  ai_melee_range stays 0, which is also what
//   keeps the model's mis-tagged "yaw_adjustment" sequence (activity 31, i.e.
//   ACT_MELEE_ATTACK2) permanently unreachable.
// ----------------------------------------------------------------------------

// (W_ApplyDamage needs no forward declaration: sv_weapons.qc is line 22 of
// sv_progs.src and every AI file compiles well after it.)

// Anim event code 2, from the model.  Monster-specific (< 1000), so the number
// means this and only this on a headcrab.
const float HC_AE_JUMPATTACK = 2;

// HL's own figures.  skill.cfg calls them sk_headcrab_health1 / _dmg_bite1;
// exposed as cvars because Sven maps are balanced against a range of values and
// a server operator should not have to recompile to move them.
const float HC_HEALTH_DEFAULT = 10;
const float HC_DAMAGE_DEFAULT = 10;

// CHeadCrab::CheckRangeAttack1 leaps at up to 256 units.
const float HC_LEAP_RANGE   = 256;
const float HC_ATTACK_DELAY = 2.0;	// m_flNextAttack, set on launch
const float HC_LEAP_MAXVEL  = 650;	// "don't jump too far/fast"

void() Headcrab_Precache =
{
	precache_model("models/headcrab.mdl");
	precache_sound("headcrab/hc_idle1.wav");
	precache_sound("headcrab/hc_idle2.wav");
	precache_sound("headcrab/hc_idle3.wav");
	precache_sound("headcrab/hc_idle4.wav");
	precache_sound("headcrab/hc_idle5.wav");
	precache_sound("headcrab/hc_alert1.wav");
	precache_sound("headcrab/hc_alert2.wav");
	precache_sound("headcrab/hc_attack1.wav");
	precache_sound("headcrab/hc_attack2.wav");
	precache_sound("headcrab/hc_attack3.wav");
	precache_sound("headcrab/hc_die1.wav");
	precache_sound("headcrab/hc_die2.wav");
	precache_sound("headcrab/hc_headbite.wav");
	precache_sound("headcrab/hc_pain1.wav");
	precache_sound("headcrab/hc_pain2.wav");
	precache_sound("headcrab/hc_pain3.wav");
};

// ---------------------------------------------------------------------------
// sounds
// ---------------------------------------------------------------------------
void() Headcrab_IdleSound =
{
	// Sven's `gag` key means "this one keeps quiet".  Honoured here rather than
	// in the schedule so a gagged monster still runs the same task list.
	if (self.gag)
		return;
	float n = ceil(random() * 5);
	sound(self, CHAN_VOICE, sprintf("headcrab/hc_idle%g.wav", n), 1, ATTN_IDLE);
};

void() Headcrab_AlertSound =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("headcrab/hc_alert%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// the leap
// ---------------------------------------------------------------------------
// Fires on contact while airborne.  Straight from CHeadCrab::LeapTouch,
// including its one odd property: the early-out on a non-damageable toucher
// means the touch is NOT cleared when the crab lands on the floor.  That is
// safe, and deliberately kept, because the FL_ONGROUND gate below makes an armed
// touch inert the moment the crab is back on the ground - so a crab that leaps
// and misses simply keeps a harmless hook until its next real contact.
void() Headcrab_LeapTouch =
{
	if (other == world)
		return;
	if (other.takedamage != DAMAGE_YES && other.classname != "player")
		return;

	// Back on the ground: the leap is over, so this is just a bump.
	if (self.flags & FL_ONGROUND)
	{
		self.touch = __NULL__;
		return;
	}

	float dmg = cvar("sv_ai_headcrab_dmg");
	if (dmg <= 0)
		dmg = HC_DAMAGE_DEFAULT;

	sound(self, CHAN_WEAPON, "headcrab/hc_headbite.wav", 1, ATTN_NORM);
	W_ApplyDamage(self, other, dmg);

	self.touch = __NULL__;
};

// Animation event handler.  Reads ai_event_code / ai_event_data, which the pump
// sets immediately before calling (the .void() virtual convention, matching
// sub_use_type elsewhere in the GoldSrc port).
void() Headcrab_Event =
{
	if (ai_event_code != HC_AE_JUMPATTACK)
		return;

	entity e = self.ai_enemy;

	// Come off the ground explicitly and lift a unit clear.  Without the lift,
	// the step physics can re-ground the crab on the same frame it launched
	// (WPhys_Physics_Step only clears FL_ONGROUND once upward velocity reaches
	// 1/32, and the ground trace would win first).  HL does exactly this, for
	// exactly this reason.
	self.flags = self.flags - (self.flags & FL_ONGROUND);
	setorigin(self, self.origin + '0 0 1');

	makevectors(self.angles);

	vector jump;
	if (e)
	{
		float grav = cvar("sv_gravity");
		if (grav <= 1)
			grav = 800;

		vector aim = e.origin + e.view_ofs;

		// Ballistic solve: pick the vertical speed that just reaches the target's
		// height, then scale the horizontal part to arrive at the same moment.
		float height = aim_z - self.origin_z;
		if (height < 16)
			height = 16;
		float spd = sqrt(2 * grav * height);
		float t   = spd / grav;

		jump   = (aim - self.origin) * (1 / t);
		jump_z = spd;

		float d = vlen(jump);
		if (d > HC_LEAP_MAXVEL)
			jump = jump * (HC_LEAP_MAXVEL / d);
	}
	else
	{
		// No enemy: a hop forward, going nowhere in particular.
		jump = v_forward * 350;
		jump_z = v_up_z * 350;
	}

	self.velocity      = jump;
	self.ai_nextattack = time + HC_ATTACK_DELAY;
	self.touch         = Headcrab_LeapTouch;

	if (!self.gag)
		sound(self, CHAN_VOICE, sprintf("headcrab/hc_attack%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// attack precondition
// ---------------------------------------------------------------------------
// CHeadCrab::CheckRangeAttack1 refuses unless the crab is on the ground.  Run
// from AI_GatherConditions, so the condition is never SET while it is untrue -
// suppressing it later instead is what made the crab re-select its chase
// schedule every tick and never actually walk.
//
// The attack cooldown that HL also checks here is generic, so it lives in
// AI_GatherConditions for every class rather than being restated per monster.
void() Headcrab_CheckAttack =
{
	if (!(self.flags & FL_ONGROUND))
		self.ai_cond = self.ai_cond & ~COND_CAN_RANGE1;
};

void() Headcrab_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, sprintf("headcrab/hc_die%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
	self.touch = __NULL__;
};

// ---------------------------------------------------------------------------
// class init
// ---------------------------------------------------------------------------
// Called from AI_ClassInit during Monster_Build, after the body exists and
// before it is placed on the floor.

// Per-activity turn rate, headcrab.cpp:182-207.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Headcrab_YawSpeed =
{
	if (act == ACT_TURN_LEFT || act == ACT_TURN_RIGHT)	return 60;
	// 20 while moving is HL's own, and it is LOW on purpose: a crab that
	// cannot swing round mid-approach is a crab you can sidestep, which is the
	// whole of fighting one.  This mod had 280 for every activity.
	if (act == ACT_WALK || act == ACT_RUN)			return 20;
	return 30;						// IDLE, RANGE_ATTACK1, default
};

void(entity m) Headcrab_ClassInit =
{
	m.ai_class = CLASS_ALIEN_PREY;		// HL's CHeadCrab::Classify

	// No melee: the crab only leaps.  Leaving this at 0 is also what makes the
	// model's mis-tagged ACT_MELEE_ATTACK2 sequence unreachable - see
	// sv_ai_defs.qc.
	m.ai_melee_range = 0;
	m.ai_range_range = HC_LEAP_RANGE;

	// Ground speeds.  HL derives these from each sequence's authored linear
	// movement (seq->linearmovement), which no QC builtin exposes, so they are
	// hand-set: too slow and the feet skate, too fast and the crab slides.  These
	// were picked to sit close to the walk/run cycles' apparent pace.
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   headcrab.mdl [3] walk 35f @30fps ->  9.5
	//   headcrab.mdl [4] run  29f @30fps -> 50.2
	// SLOWER than what was here, and that is not a mistake.  A headcrab's threat
	// has never been its ground speed - it is the LEAP, which is applied by anim
	// event and is unaffected by this.  At 150 it chased the player down like a
	// dog, which is not how they behave in Half-Life at all.
	m.ai_speed_walk = 10;
	m.ai_speed_run  = 50;
	m.ai_yaw_speed  = 280;
	m.ai_yawspeed   = Headcrab_YawSpeed;

	// No ai_selectsched: the generic ladder in AI_SelectSchedule already produces
	// correct headcrab behaviour once the attack preconditions are right, and a
	// class override that only re-derives the generic answer is a place for the
	// two to drift apart.
	m.ai_checkattack = Headcrab_CheckAttack;
	m.ai_idlesound   = Headcrab_IdleSound;
	m.ai_alertsound  = Headcrab_AlertSound;
	m.ai_event       = Headcrab_Event;
	m.ai_death       = Headcrab_Death;

	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;		// HL BLOOD_COLOR_GREEN
};

// Class defaults consumed by Monster_Build before the generic health fallback.
float() Headcrab_DefaultHealth =
{
	float h = cvar("sv_ai_headcrab_health");
	if (h <= 0)
		h = HC_HEALTH_DEFAULT;
	return h;
};
