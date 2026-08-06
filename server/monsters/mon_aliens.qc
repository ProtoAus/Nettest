// server/monsters/mon_aliens.qc
// ----------------------------------------------------------------------------
// The alien melee/ranged wave — everything in W5 that is not the slave or the
// houndeye.  Grouped in one file because they share one shape: a melee pair and
// a projectile, differing only in the projectile and the event codes.
//
//   monster_alien_grunt (293)   monster_pitdrone (189)
//   monster_bullchicken (169)   monster_gonome (127)
//   monster_alien_voltigore (38)
//
// All five tables were read out of the .mdl files.  Two things they settled that
// would have been wrong by guesswork:
//
//   THE ALIEN GRUNT FIRES FIVE HORNETS PER ATTACK, not one.  hornetattack carries
//   codes 1,2,3,4,5 at 0.30/0.50/0.70/0.80/1.10 s, and longshoot carries SEVEN
//   (1,2,3,4,5,5,5).  The volley is the attack — one hornet per schedule would be
//   a completely different monster.
//
//   The event codes COLLIDE across these classes.  Code 1 is a hornet on the
//   agrunt, a spit on the pitdrone, a claw on the gonome and an energy ball on
//   the voltigore.  This is exactly why the dispatcher keys on (class, code) via
//   the per-class .ai_event virtual and never on the code alone.
//
// models/agrunt.mdl (32 seqs, valve):
//   act 28 hornetattack 16f@10: 1@0.30 2@0.50 3@0.70 4@0.80 5@1.10
//          quickshoot 12f@10: 1@0.50 1@0.70   longshoot 21f@10: 1..5,5,5
//   act 30 mattack2 (13@0.53) / mattack3 (12@0.47)   punches
//   act  3 walk / act 4 run carry 10/11 footstep events
// models/pit_drone.mdl (19 seqs, gearbox):
//   act 28 range 42f@30: 1@0.37   act 30 bite: 2@0.48, 6@0.48, 2@0.56
//   act 31 whip 61f@30: 4@0.43, 4@0.80   act 32 reload: 7@1.08
// models/bullsquid.mdl (24 seqs, valve):
//   act 28 range 42f@30: 1@0.37   act 30 whip 55f@30: 4@0.77
//   act 31 bite 29f@30: 2@0.23, 6@0.33
// models/gonome.mdl (24 seqs, gearbox):
//   act 30 attack1 61f@37: 1@0.51, 2@0.95    act 28 attack3 85f@40: 3@1.00, 4@1.55
// models/voltigore.mdl (16 seqs, gearbox):
//   act 30 mattack2 (13@0.44) / mattack3 (12@0.81)
//   act 28 distanceattack 81f@45: 1@0.89
// ----------------------------------------------------------------------------

// --- alien grunt (agrunt.cpp) ---
const float AGR_AE_HORNET1     = 1;
const float AGR_AE_HORNET5     = 5;
const float AGR_AE_LEFT_PUNCH  = 12;
const float AGR_AE_RIGHT_PUNCH = 13;

// --- bullsquid / pitdrone (they share opfor's vocabulary) ---
const float BSQ_AE_SPIT     = 1;
const float BSQ_AE_BITE     = 2;
const float BSQ_AE_TAILWHIP = 4;
const float BSQ_AE_THROW    = 6;
const float BSQ_AE_RELOAD   = 7;

// --- gonome ---
const float GON_AE_CLAW1 = 1;
const float GON_AE_CLAW2 = 2;
const float GON_AE_SPIT1 = 3;
const float GON_AE_SPIT2 = 4;

// --- voltigore ---
const float VOL_AE_BALL        = 1;
const float VOL_AE_LEFT_PUNCH  = 12;
const float VOL_AE_RIGHT_PUNCH = 13;

const string AI_MDL_HORNET = "models/hornet.mdl";
const string AI_MDL_SPIKE  = "models/pit_drone_spike.mdl";
const string AI_SPR_SPIT   = "sprites/bigspit.spr";

void() Aliens_Precache =
{
	precache_model("models/agrunt.mdl");
	precache_model("models/bullsquid.mdl");
	precache_model(AI_MDL_HORNET);
	precache_model(AI_SPR_SPIT);
	precache_sound("agrunt/ag_fire1.wav");
	precache_sound("agrunt/ag_fire2.wav");
	precache_sound("agrunt/ag_fire3.wav");
	precache_sound("agrunt/ag_die1.wav");
	precache_sound("agrunt/ag_die4.wav");
	precache_sound("agrunt/ag_pain1.wav");
	precache_sound("agrunt/ag_pain4.wav");
	precache_sound("bullchicken/bc_attack2.wav");
	precache_sound("bullchicken/bc_attack3.wav");
	precache_sound("bullchicken/bc_bite2.wav");
	precache_sound("bullchicken/bc_bite3.wav");
	precache_sound("bullchicken/bc_die1.wav");
	precache_sound("bullchicken/bc_die3.wav");
	precache_sound("bullchicken/bc_pain1.wav");
	precache_sound("bullchicken/bc_pain4.wav");

	// gearbox / svencoop classes.  Guarded with Monster_ModelExists so a machine
	// without Opposing Force mounted logs nothing and precaches nothing, rather
	// than emitting a warning per model at every map load.
	if (Monster_ModelExists("models/pit_drone.mdl"))
	{
		precache_model("models/pit_drone.mdl");
		if (Monster_ModelExists(AI_MDL_SPIKE))
			precache_model(AI_MDL_SPIKE);
	}
	if (Monster_ModelExists("models/gonome.mdl"))
		precache_model("models/gonome.mdl");
	if (Monster_ModelExists("models/voltigore.mdl"))
		precache_model("models/voltigore.mdl");
};

// ---------------------------------------------------------------------------
// shared attack bodies
// ---------------------------------------------------------------------------
const float ALIEN_MELEE_REACH = 70;

void(entity m, string mdl, float speed, float dmg, float grav) Alien_Spit =
{
	if (!m.ai_enemy)
		return;

	vector src = AI_MuzzlePos(m);
	AI_LaunchProjectile(m, mdl, AI_AimDir(m, src, m.ai_enemy, 0.05), speed, dmg, grav);
};

// ---------------------------------------------------------------------------
// alien grunt
// ---------------------------------------------------------------------------
void() Agrunt_Event =
{
	// Codes 1..5 are all hornets.  Testing the RANGE rather than listing five
	// constants keeps longshoot's repeated 5s working without a special case.
	if (ai_event_code >= AGR_AE_HORNET1 && ai_event_code <= AGR_AE_HORNET5)
	{
		float d = cvar("sv_ai_agrunt_dmg");
		if (d <= 0)
			d = 8;
		Alien_Spit(self, AI_MDL_HORNET, 900, d, 0);
		if (!self.gag)
			sound(self, CHAN_WEAPON, sprintf("agrunt/ag_fire%g.wav", ceil(random() * 3)), 1, ATTN_NORM);

		// Only the LAST hornet arms the cooldown, or the volley would end itself
		// after the first one.
		if (ai_event_code == AGR_AE_HORNET5)
			self.ai_nextattack = time + 2.5;
		return;
	}

	if (ai_event_code == AGR_AE_LEFT_PUNCH || ai_event_code == AGR_AE_RIGHT_PUNCH)
	{
		AI_MeleeHull(self, ALIEN_MELEE_REACH, 25, 16);
		return;
	}
	// 10 / 11 are footsteps; HL plays them from the model and so do we, via the
	// shared EVENT_SOUND handler where the model names a file.
};

void() Agrunt_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "agrunt/ag_die1.wav" : "agrunt/ag_die4.wav", 1, ATTN_NORM);
};

void() Agrunt_PainSound =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "agrunt/ag_pain1.wav" : "agrunt/ag_pain4.wav", 1, ATTN_NORM);
};


// Per-activity turn rate, agrunt.cpp:395-408.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Agrunt_YawSpeed =
{
	if (act == ACT_TURN_LEFT || act == ACT_TURN_RIGHT)	return 110;
	return 100;
};

void(entity m) Agrunt_ClassInit =
{
	m.ai_class       = CLASS_ALIEN_MILITARY;
	m.ai_melee_range = ALIEN_MELEE_REACH;
	m.ai_range_range = 1024;
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   agrunt.mdl [2] walk 20f @15fps ->  46.1
	//   agrunt.mdl [3] run  26f @35fps -> 292.2
	m.ai_speed_walk  = 46;
	m.ai_speed_run   = 292;
	m.ai_yaw_speed   = 150;
	m.ai_yawspeed    = Agrunt_YawSpeed;
	m.ai_event       = Agrunt_Event;
	m.ai_death       = Agrunt_Death;
	m.ai_painsound   = Agrunt_PainSound;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// bullsquid  /  pitdrone
// ---------------------------------------------------------------------------
void() Bullsquid_Event =
{
	if (ai_event_code == BSQ_AE_SPIT)
	{
		float d = cvar("sv_ai_bullsquid_dmg");
		if (d <= 0)
			d = 10;
		// Arcs: HL's spit is a lobbed glob, not a bolt.
		Alien_Spit(self, AI_SPR_SPIT, 900, d, 0.5);
		if (!self.gag)
			sound(self, CHAN_WEAPON, sprintf("bullchicken/bc_attack%g.wav", 2 + rint(random())), 1, ATTN_NORM);
		self.ai_nextattack = time + 2.5;
		return;
	}

	if (ai_event_code == BSQ_AE_BITE || ai_event_code == BSQ_AE_THROW)
	{
		if (AI_MeleeHull(self, ALIEN_MELEE_REACH, 25, 16) != world)
			if (!self.gag)
				sound(self, CHAN_WEAPON, sprintf("bullchicken/bc_bite%g.wav", 2 + rint(random())), 1, ATTN_NORM);
		return;
	}

	if (ai_event_code == BSQ_AE_TAILWHIP)
	{
		AI_MeleeHull(self, ALIEN_MELEE_REACH + 10, 20, 20);
		return;
	}
	// RELOAD (7) refills the pitdrone's spike rack in HL; nothing here counts
	// ammo, so the animation is the whole behaviour.
};

void() Bullsquid_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "bullchicken/bc_die1.wav" : "bullchicken/bc_die3.wav", 1, ATTN_NORM);
};

void() Bullsquid_PainSound =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "bullchicken/bc_pain1.wav" : "bullchicken/bc_pain4.wav", 1, ATTN_NORM);
};


// Per-activity turn rate, bullsquid.cpp:503-520.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Bullsquid_YawSpeed =
{
	return 90;						// flat in HL
};

void(entity m) Bullsquid_ClassInit =
{
	m.ai_class       = CLASS_ALIEN_PREDATOR;
	m.ai_melee_range = ALIEN_MELEE_REACH;
	m.ai_range_range = 1024;
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   bullsquid.mdl [0] walk 150f @30fps ->  51.4
	//   bullsquid.mdl [1] run    37f @30fps -> 299.2
	m.ai_speed_walk  = 51;
	m.ai_speed_run   = 299;
	m.ai_yaw_speed   = 200;
	m.ai_yawspeed    = Bullsquid_YawSpeed;
	m.ai_event       = Bullsquid_Event;
	m.ai_death       = Bullsquid_Death;
	m.ai_painsound   = Bullsquid_PainSound;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

// The pitdrone is the same behaviour with a solid spike instead of a glob, so it
// shares the event handler and only swaps the projectile in.
void() Pitdrone_Event =
{
	if (ai_event_code == BSQ_AE_SPIT)
	{
		float d = cvar("sv_ai_pitdrone_dmg");
		if (d <= 0)
			d = 12;
		// Flat, not arced: a spike is fired, not lobbed.  Falls back to the spit
		// sprite when Opposing Force is not mounted, so the class still works.
		string mdl = AI_MDL_SPIKE;
		if (!Monster_ModelExists(mdl))
			mdl = AI_SPR_SPIT;
		Alien_Spit(self, mdl, 1200, d, 0);
		self.ai_nextattack = time + 2.0;
		return;
	}
	Bullsquid_Event();		// bite / whip / reload are identical
};

void(entity m) Pitdrone_ClassInit =
{
	Bullsquid_ClassInit(m);

	// It shares the bullsquid's behaviour, NOT its legs.  Overridden after the
	// base init rather than before it, or the base would overwrite these.
	//   pit_drone.mdl [2] walk 51f @30fps ->  41.7  (gallop, also ACT_WALK, is 83.9)
	//   pit_drone.mdl [4] run  25f @50fps -> 285.4
	m.ai_speed_walk  = 42;
	m.ai_speed_run   = 285;
	m.ai_event = Pitdrone_Event;
};

// ---------------------------------------------------------------------------
// gonome
// ---------------------------------------------------------------------------
void() Gonome_Event =
{
	if (ai_event_code == GON_AE_CLAW1 || ai_event_code == GON_AE_CLAW2)
	{
		AI_MeleeHull(self, ALIEN_MELEE_REACH, 20, 16);
		return;
	}
	// ONE goop per animation, on the SECOND code.
	//
	// gonome.mdl [9] attack3 (act 28) raises 3 at 1.00 s and 4 at 1.55 s, and this
	// used to be an OR over both - so a single 2.1-second throw animation spawned
	// two projectiles 0.55 s apart.  That is the reported "he throws the goop at
	// the start of the animation and then again at the end".
	//
	// Code 4 is the release and code 3 is the wind-up, by the same shape every
	// other two-code attack in this port uses: the bullsquid pairs SPIT with THROW,
	// and the islave runs ZAP_POWERUP -> ZAP_SHOOT -> ZAP_DONE.  There is no
	// Opposing Force SDK on this machine to confirm it against, so this is read
	// from the model and from the family pattern rather than from source, and the
	// timing is the tell: 1.55 s of a 2.13 s animation is a throw, 1.00 s is an arm
	// coming back.
	if (ai_event_code == GON_AE_SPIT2)
	{
		Alien_Spit(self, AI_SPR_SPIT, 900, 10, 0.5);
		return;			// cooldown: AI_ArmAttackCooldown, at sequence end
	}
	if (ai_event_code == GON_AE_SPIT1)
		return;			// the wind-up; deliberately nothing
};

void(entity m) Gonome_ClassInit =
{
	m.ai_class       = CLASS_ALIEN_MONSTER;
	m.ai_melee_range = ALIEN_MELEE_REACH;
	m.ai_range_range = 1024;
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   gonome.mdl [0] walk    61f @30fps ->  39.6
	//   gonome.mdl [1] runlong 31f @40fps -> 262.1  (runshort is 260.4)
	m.ai_speed_walk  = 40;
	m.ai_speed_run   = 262;
	m.ai_yaw_speed   = 180;
	// Was armed from inside the spit handler; moved here now that the cooldown is
	// centralised, so the number survives the handler no longer setting it.
	m.ai_attackrate  = 2.5;
	m.ai_event       = Gonome_Event;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// voltigore
// ---------------------------------------------------------------------------
void() Voltigore_Event =
{
	if (ai_event_code == VOL_AE_LEFT_PUNCH || ai_event_code == VOL_AE_RIGHT_PUNCH)
	{
		AI_MeleeHull(self, ALIEN_MELEE_REACH + 10, 35, 20);
		return;
	}
	if (ai_event_code == VOL_AE_BALL)
	{
		// The energy ball reuses the beam rather than a projectile: it is an
		// electric discharge, and the beam already exists and already works.
		if (self.ai_enemy)
			AI_FireBeam(self, self.ai_enemy, HL_BEAM_EGON, 25);
		self.ai_nextattack = time + 3.0;
		return;
	}
};

void(entity m) Voltigore_ClassInit =
{
	m.ai_class       = CLASS_ALIEN_MILITARY;
	m.ai_melee_range = ALIEN_MELEE_REACH + 10;
	m.ai_range_range = 1024;
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   voltigore.mdl [2] walk 49f @25fps ->  37.0
	//   voltigore.mdl [3] run   37f @50fps -> 333.5
	m.ai_speed_walk  = 37;
	m.ai_speed_run   = 333;
	m.ai_yaw_speed   = 140;
	m.ai_event       = Voltigore_Event;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// health defaults (HL skill.cfg)
// ---------------------------------------------------------------------------
float() Agrunt_DefaultHealth
	= { float h = cvar("sv_ai_agrunt_health");    return (h > 0) ? h : 90; };
float() Bullsquid_DefaultHealth
	= { float h = cvar("sv_ai_bullsquid_health"); return (h > 0) ? h : 40; };
float() Pitdrone_DefaultHealth
	= { float h = cvar("sv_ai_pitdrone_health");  return (h > 0) ? h : 60; };
float() Gonome_DefaultHealth
	= { float h = cvar("sv_ai_gonome_health");    return (h > 0) ? h : 200; };
float() Voltigore_DefaultHealth
	= { float h = cvar("sv_ai_voltigore_health"); return (h > 0) ? h : 200; };
