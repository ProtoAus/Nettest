// server/monsters/mon_bigfoes.qc
// ----------------------------------------------------------------------------
// The heavy melee tail: gargantua (29), babygarg (74), stukabat (60, a flyer),
// kingpin (26).  189 placements.
//
// models/garg.mdl and models/babygarg.mdl are the SAME 22-sequence layout — the
// baby is a rescale, which is why one event handler serves both:
//   act  1  idle1..idle4 (idle3 carries code 6 BREATHE, idle2 a voice line)
//   act  3  walk 34f: code 3 @0.05s, code 6 @0.35s, code 4 @0.90s
//   act  4  run  21f: code 3 @0.50s, code 4 @1.06s
//   act 30  Attack 55f @36: code 1 @0.78s          SLASH
//   act 28  stomp  21f @14: code 5 @1.36s          STOMP  <- the shockwave
//   act 31  shootflames2 7f @8 LOOP, no events     the flame stream
//   act 36  die 76f @15
// gargantua.cpp: 1 SLASH_LEFT, 3 RIGHT_FOOT, 4 LEFT_FOOT, 5 STOMP, 6 BREATHE.
// Codes 3/4/6 are footsteps and breathing — ambience, handled as no-ops here
// because the model does not name a sound file on them.
//
// THE STOMP LANDS AT 1.36 s OF A 1.5 s ANIMATION.  Same shape as the houndeye's
// blast: the wind-up is the tell, and firing it on schedule entry would delete
// the only warning the player gets before a very large amount of damage.
//
// models/stukabat.mdl is a FLYER (act 5 = ACT_FLY on Flying_cycler) with a ground
// walk as well, and two attacks: act 28 Attack_bomb (code 1 @1.00s) and act 29
// Attack_claw.  It is the only class so far that has both a flying and a walking
// gait; it uses AIMODE_FLY and the ground cycle simply never plays.
//
// models/kingpin.mdl has THREE SEQUENCES — idle, walk, run — and no attack
// animation whatsoever.  It is given a melee attack anyway, because a boss that
// cannot hurt anybody is worse than one whose swing is not animated; the activity
// falls back and it visibly walks into you while dealing damage.  Flagged rather
// than hidden: if a map supplies a fuller kingpin model this class gets better
// for free.
// ----------------------------------------------------------------------------

const float GARG_AE_SLASH   = 1;
const float GARG_AE_RFOOT   = 3;
const float GARG_AE_LFOOT   = 4;
const float GARG_AE_STOMP   = 5;
const float GARG_AE_BREATHE = 6;

const float STUKA_AE_ATTACK = 1;

void() BigFoes_Precache =
{
	precache_model("models/garg.mdl");
	precache_model("models/stukabat.mdl");
	precache_model("models/kingpin.mdl");
	if (Monster_ModelExists("models/babygarg.mdl"))
		precache_model("models/babygarg.mdl");
	precache_sound("garg/gar_attack1.wav");
	precache_sound("garg/gar_attack2.wav");
	precache_sound("garg/gar_attack3.wav");
	precache_sound("garg/gar_stomp1.wav");
	precache_sound("garg/gar_die1.wav");
	precache_sound("garg/gar_pain1.wav");
	precache_sound("garg/gar_pain2.wav");
	precache_sound("garg/gar_pain3.wav");
};

// ---------------------------------------------------------------------------
// gargantua / babygarg
// ---------------------------------------------------------------------------
void() Garg_Event =
{
	if (ai_event_code == GARG_AE_SLASH)
	{
		float d = cvar("sv_ai_garg_dmg");
		if (d <= 0)
			d = 50;			// HL sk_gargantua_dmg_slash
		// .ai_spread doubles as the size scale here: a babygarg reaches less far
		// than its parent, and both reach further than anything else in the mod.
		AI_MeleeHull(self, self.ai_melee_range, d * self.ai_dmg_scale, 32);
		if (!self.gag)
			sound(self, CHAN_WEAPON, sprintf("garg/gar_attack%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
		self.ai_nextattack = time + 2.0;
		return;
	}

	if (ai_event_code == GARG_AE_STOMP)
	{
		// The shockwave, 1.36 s in.  HL's is a travelling wave; this is a radius
		// blast centred on the gargantua, which is the same threat from the
		// player's side without a new entity type to network.
		// Not a second `float d`: QC scopes locals function-wide, so the one
		// declared in the slash branch above is already in scope here.
		d = cvar("sv_ai_garg_stomp_dmg");
		if (d <= 0)
			d = 50;
		if (!self.gag)
			sound(self, CHAN_WEAPON, "garg/gar_stomp1.wav", 1, ATTN_NORM);
		AI_BlastAttack(self, 400 * self.ai_dmg_scale, d * self.ai_dmg_scale, d * 0.2);
		self.ai_nextattack = time + 4.0;
		return;
	}
	// RIGHT_FOOT / LEFT_FOOT / BREATHE are ambience.  The model names no sound
	// file on them, so there is nothing to play without inventing one.
};

void() Garg_PainSound =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, sprintf("garg/gar_pain%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Garg_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, "garg/gar_die1.wav", 1, ATTN_NORM);
};


// Per-activity turn rate, gargantua.cpp:720-743.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Garg_YawSpeed =
{
	// 180 on a dedicated turn against 60 for everything else - the gargantua
	// plants and pivots rather than steering, which is exactly how it reads.
	if (act == ACT_TURN_LEFT || act == ACT_TURN_RIGHT)	return 180;
	return 60;
};

void(entity m) Garg_CommonInit =
{
	m.ai_class       = CLASS_ALIEN_MONSTER;
	m.ai_melee_range = 110;			// it is enormous; so is its reach
	m.ai_range_range = 400;			// the stomp
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   garg.mdl [4] walk 34f @20fps ->  91.3
	//   garg.mdl [5] run  21f @18fps -> 356.0
	m.ai_speed_walk  = 91;
	m.ai_speed_run   = 356;
	m.ai_yaw_speed   = 100;			// heavy, turns slowly
	m.ai_yawspeed    = Garg_YawSpeed;
	m.ai_dmg_scale   = 1;
	m.ai_event       = Garg_Event;
	m.ai_painsound   = Garg_PainSound;
	m.ai_death       = Garg_Death;
	if (m.bloodcolor <= 0)
		m.bloodcolor = -1;		// HL gargantua does not bleed
};

void(entity m) Gargantua_ClassInit = { Garg_CommonInit(m); };

void(entity m) Babygarg_ClassInit =
{
	Garg_CommonInit(m);
	// Same rig at a smaller scale: shorter reach, less damage, quicker.
	m.ai_melee_range = 80;
	m.ai_range_range = 250;
	m.ai_dmg_scale   = 0.5;
	//   babygarg.mdl [4] walk 34f @17fps ->  34.0  (kept from Garg_CommonInit's 91
	//   babygarg.mdl [5] run  21f @16fps -> 273.3   would be wrong for the small rig)
	m.ai_speed_walk  = 34;
	m.ai_speed_run   = 273;
	m.ai_yaw_speed   = 140;
};

// ---------------------------------------------------------------------------
// stukabat  —  a flyer with a bombing run
// ---------------------------------------------------------------------------
void() Stukabat_Event =
{
	if (ai_event_code != STUKA_AE_ATTACK)
		return;
	float d = cvar("sv_ai_stukabat_dmg");
	if (d <= 0)
		d = 15;
	// ai_melee_range, NOT a second hardcoded number.  COND_CAN_MELEE1 is gated on
	// ai_melee_range, so a shorter literal here means the attack triggers at a
	// distance the swing cannot actually reach - which is exactly what happened:
	// gated at 80, swung 60, ten attacks and zero contact.
	AI_MeleeHull(self, self.ai_melee_range, d, 16);
	self.ai_nextattack = time + 2.0;
};

void(entity m) Stukabat_ClassInit =
{
	m.ai_class    = CLASS_ALIEN_MONSTER;
	m.ai_movemode = AIMODE_FLY;
	// 48, not 96.  At 96 it cruised two hull-heights above a grounded player and
	// its 60-unit reach could not span the gap - eleven attacks, zero contact.
	// A stukabat is a diving attacker, so it flies low enough to actually reach.
	m.ai_flyheight = 48;

	// RANGE, not melee - and this is the headcrab trap again.  The dive is tagged
	// act 28 (ACT_RANGE_ATTACK1) and this model has NO act 30 at all, so asking
	// for a melee activity fell through the whole fallback chain to sequence 0,
	// which carries no attack event.  Eleven attacks, zero damage, because the
	// schedule was playing an idle pose.  The attack is physical; the ACTIVITY
	// TAG is what decides which schedule can reach it.
	m.ai_melee_range = 0;
	m.ai_range_range = 80;
	m.ai_speed_walk  = 90;
	m.ai_speed_run   = 260;			// Flying_cycler is 26f @35 - very quick
	m.ai_yaw_speed   = 220;
	m.ai_dmg_scale   = 1;
	m.ai_event       = Stukabat_Event;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// kingpin
// ---------------------------------------------------------------------------
// See the header: this model has no attack sequence at all, so the melee below
// plays whatever the activity fallback lands on.  The damage is real; only the
// animation is missing.
void() Kingpin_Tick =
{
	if (!self.ai_enemy)
		return;
	if (time < self.ai_nextattack)
		return;
	if (vlen(self.ai_enemy.origin - self.origin) > self.ai_melee_range)
		return;

	self.ai_nextattack = time + 1.5;
	float d = cvar("sv_ai_kingpin_dmg");
	if (d <= 0)
		d = 30;
	AI_MeleeHull(self, self.ai_melee_range, d, 24);
};

void(entity m) Kingpin_ClassInit =
{
	m.ai_class       = CLASS_ALIEN_MILITARY;
	m.ai_melee_range = 80;
	m.ai_range_range = 0;
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   kingpin.mdl [1] walk 41f @30fps ->  48.9
	//   kingpin.mdl [2] run  20f @30fps -> 158.8   (genuinely a slow one)
	m.ai_speed_walk  = 49;
	m.ai_speed_run   = 159;
	m.ai_yaw_speed   = 130;
	m.ai_dmg_scale   = 1;
	// Driven from the per-tick hook rather than an anim event, because there is no
	// attack animation to hang an event on.  Same mechanism the barnacle needed.
	m.ai_tick = Kingpin_Tick;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

float() Gargantua_DefaultHealth
	= { float h = cvar("sv_ai_garg_health");     return (h > 0) ? h : 800; };
float() Babygarg_DefaultHealth
	= { float h = cvar("sv_ai_babygarg_health"); return (h > 0) ? h : 400; };
float() Stukabat_DefaultHealth
	= { float h = cvar("sv_ai_stukabat_health"); return (h > 0) ? h : 60;  };
float() Kingpin_DefaultHealth
	= { float h = cvar("sv_ai_kingpin_health");  return (h > 0) ? h : 250; };
