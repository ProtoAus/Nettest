// server/monsters/mon_bosses.qc
// ----------------------------------------------------------------------------
// W7, part one: monster_bigmomma (26) and the two air vehicles,
// monster_apache and monster_osprey.
//
// models/big_mom.mdl (20 sequences), read out of the file:
//   act  1  idle1 / idle2      code 5 SACK slosh
//   act  3  walk 49f @35: codes 1,2,3,4 - the four footfalls
//   act  4  run  23f @28: same four plus a sack
//   act 30  claw x3 variants:
//             [5] 41f: code 16 @0.43 (attack sound), 10 @0.57 (MELEE_ATTACK1), 5
//             [6] 20f: code 16, 14 (SCREAM), 8  (MELEE_ATTACKBR)
//             [7] 23f: code 9 (MELEE_ATTACKBL), 14
//   act 31  spawn 31f @20: code 12 @0.40 LAY_CRAB, 17 BIRTH_SOUND, 16
//   act 28  mortar 17f @20: code 11 @0.50 MORTAR_ATTACK, 16
//   act 36  death, code 6 DEATHSOUND
//   act 26  flinch, code 15 PAIN_SOUND
// bigmomma.cpp: 1-4 footsteps, 5 sack, 6 death, 8/9/10 melee, 11 mortar,
// 12 lay crab, 13 jump, 14 scream, 15 pain, 16 attack sound, 17 birth.
//
// SHE LAYS HEADCRABS.  Event 12 on the spawn sequence is HL's LAY_CRAB, and it
// is the whole reason this fight works the way it does - the boss is a spawner,
// not just a big melee monster.  That is implemented here because the headcrab
// class already exists and Monster_Build is reachable; it would have been the
// first thing to cut and the first thing anyone noticed missing.
//
// THE AIR VEHICLES HAVE ONE SEQUENCE EACH.  apache.mdl is a 7-frame "idle" rotor
// loop and osprey.mdl an 11-frame "rotor" loop - no activities, no events, no
// attacks, no deaths.  Everything they do has to come from QC, which is exactly
// what the plan predicted, and it means the animation layer has nothing to
// contribute: AI_SetActivity would resolve every activity to sequence 0 anyway.
// They are AIMODE_FLY hitscan platforms that hold altitude and shoot.
// ----------------------------------------------------------------------------

const float BM_AE_SACK        = 5;
const float BM_AE_DEATHSOUND  = 6;
const float BM_AE_MELEE_BR    = 8;
const float BM_AE_MELEE_BL    = 9;
const float BM_AE_MELEE1      = 10;
const float BM_AE_MORTAR      = 11;
const float BM_AE_LAY_CRAB    = 12;
const float BM_AE_SCREAM      = 14;
const float BM_AE_PAIN        = 15;
const float BM_AE_ATTACK_SND  = 16;
const float BM_AE_BIRTH       = 17;

void() Bosses_Precache =
{
	precache_model("models/big_mom.mdl");
	precache_model("models/apache.mdl");
	precache_model("models/osprey.mdl");
	precache_sound("gonarch/gon_attack1.wav");
	precache_sound("gonarch/gon_attack2.wav");
	precache_sound("gonarch/gon_attack3.wav");
	precache_sound("gonarch/gon_pain2.wav");
	precache_sound("gonarch/gon_pain3.wav");
	precache_sound("gonarch/gon_die1.wav");
	precache_sound("gonarch/gon_birth1.wav");
	precache_sound("gonarch/gon_birth2.wav");
	precache_sound("gonarch/gon_sack1.wav");
	precache_sound("gonarch/gon_sack3.wav");
	precache_sound("weapons/mortarhit.wav");
	precache_sound("apache/ap_rotor2.wav");
	precache_sound("apache/ap_whine1.wav");
	// The crabs she lays are ordinary monster_headcrabs, already precached by
	// the headcrab class - nothing extra is needed here.
};

// ---------------------------------------------------------------------------
// bigmomma
// ---------------------------------------------------------------------------
.float ai_crabtime;		// earliest time she may birth again

void() BigMomma_LayCrab =
{
	// One headcrab, dropped just behind her.  Monster_Build is the single
	// construction path, so the child gets a brain, a hull and a chain entry the
	// same way a map-placed crab does - no special case anywhere.
	//
	// Monster_Spawn is deliberately NOT used even though it exists for exactly
	// this shape: it copies the maker's health onto the child, and hers is 1000.
	// Every crab she laid would have arrived with a boss's hit points.
	makevectors('0 1 0' * self.angles_y);
	vector org = self.origin - v_forward * 48 + '0 0 16';

	// Refuse to birth into solid rather than dropping a crab inside the geometry
	// behind her.  She is enormous, so "behind" is frequently a wall.  The hull
	// comes from Monster_ClassHull rather than being written out here, so this
	// cannot drift from the hull the crab is actually built with.
	Monster_ClassHull("monster_headcrab");
	tracebox(self.origin + '0 0 16', monster_hull_min, monster_hull_max,
	         org, MOVE_NOMONSTERS, self);
	if (trace_startsolid || trace_allsolid)
		return;
	org = trace_endpos;

	entity oldself = self;
	entity c = spawn();
	c.classname = "monster_headcrab";
	setorigin(c, org);
	self = c;
	Monster_Build(TRUE);
	self = oldself;

	// Book the child against her own live-children count, using the squadmaker
	// latch rather than a private counter.  Monster_Teardown already releases the
	// slot from both the death handler and remove(), idempotently, and the squad
	// self-test already asserts that accounting - so the cap below cannot drift,
	// and a gonarch whose crabs are all killed can birth a fresh brood.
	//
	// Set AFTER Monster_Build so nothing inside construction can clobber it.
	c.sq_owner            = self;
	c.sq_counted          = 1;
	self.sq_live_children = self.sq_live_children + 1;

	// Reported separately from the schedule histogram on purpose: a laycrab
	// SELECTION only means the animation started.  The crab appears on an event
	// 0.4 of the way in, so selections and births are different numbers, and the
	// gap between them is precisely where this behaviour was broken before.
	if (cvar("sv_ai_debug"))
		dprint(sprintf("[ai] bigmomma birthed a headcrab (live=%g)\n",
		               self.sq_live_children));

	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "gonarch/gon_birth1.wav"
		                                         : "gonarch/gon_birth2.wav", 1, ATTN_NORM);
};

// The whole reason SCHED_BIGMOMMA_LAYCRAB exists.  Her spawn sequence is tagged
// ACT_MELEE_ATTACK2, and the generic ladder selects ACT_MELEE_ATTACK1 or
// ACT_RANGE_ATTACK1 and nothing else - so without this virtual the event was
// wired to a sequence that never played.
float() BigMomma_SelectSched =
{
	if (!self.ai_enemy)
		return SCHED_NONE;
	if (self.ai_state != MS_COMBAT)
		return SCHED_NONE;
	if (time < self.ai_crabtime)
		return SCHED_NONE;

	float cap = cvar("sv_ai_bigmomma_maxcrabs");
	if (cap <= 0)
		cap = 10;
	if (self.sq_live_children >= cap)
		return SCHED_NONE;

	// Stamped HERE, at selection, not in the event handler.  The event fires 0.4
	// of the way into the sequence; if the gap were stamped there, every tick
	// before it would re-select this schedule and restart the animation from the
	// top, so the birth frame would never be reached at all.  That is the same
	// restart-before-you-arrive failure the chase schedule had in B2.
	float gap = cvar("sv_ai_bigmomma_crabgap");
	if (gap <= 0)
		gap = 8;
	self.ai_crabtime = time + gap;

	return SCHED_BIGMOMMA_LAYCRAB;
};

void() BigMomma_Event =
{
	if (ai_event_code == BM_AE_MELEE1 || ai_event_code == BM_AE_MELEE_BR
	 || ai_event_code == BM_AE_MELEE_BL)
	{
		float d = cvar("sv_ai_bigmomma_dmg");
		if (d <= 0)
			d = 50;
		AI_MeleeHull(self, self.ai_melee_range, d, 32);
		return;
	}

	if (ai_event_code == BM_AE_MORTAR)
	{
		// The mortar, half a second into a short sequence.  HL lobs a real
		// projectile; this uses the blast primitive centred on the ENEMY rather
		// than on her, which is the same threat without a new projectile type -
		// and unlike a lob it cannot be dodged by the arc being wrong.
		if (self.ai_enemy)
		{
			float md = cvar("sv_ai_bigmomma_mortar_dmg");
			if (md <= 0)
				md = 40;
			vector saved = self.origin;
			// AI_BlastAttack centres on the attacker, so borrow her origin for
			// the call.  setorigin is deliberately NOT used: this is one function
			// call with no traces in between that could observe the move.
			self.origin = self.ai_enemy.origin;
			AI_BlastAttack(self, 200, md, md * 0.25);
			self.origin = saved;

			sound(self, CHAN_WEAPON, "weapons/mortarhit.wav", 1, ATTN_NORM);
		}
		self.ai_nextattack = time + 5.0;
		return;
	}

	if (ai_event_code == BM_AE_LAY_CRAB)
	{
		BigMomma_LayCrab();
		return;
	}

	if (ai_event_code == BM_AE_ATTACK_SND || ai_event_code == BM_AE_SCREAM)
	{
		if (!self.gag)
			sound(self, CHAN_VOICE, sprintf("gonarch/gon_attack%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
		return;
	}

	if (ai_event_code == BM_AE_SACK)
	{
		if (!self.gag)
			sound(self, CHAN_BODY, (random() < 0.5) ? "gonarch/gon_sack1.wav"
			                                        : "gonarch/gon_sack3.wav", 1, ATTN_NORM);
		return;
	}
	// Footsteps (1-4), PAIN (15) and DEATHSOUND (6) are handled by the class
	// virtuals below or are ambience with no file named on the event.
};

void() BigMomma_PainSound =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "gonarch/gon_pain2.wav"
		                                         : "gonarch/gon_pain3.wav", 1, ATTN_NORM);
};

void() BigMomma_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, "gonarch/gon_die1.wav", 1, ATTN_NORM);
};


// Per-activity turn rate, bigmomma.cpp:416-428.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) BigMomma_YawSpeed =
{
	if (act == ACT_IDLE)	return 100;
	return 90;
};

void(entity m) BigMomma_ClassInit =
{
	m.ai_yawspeed    = BigMomma_YawSpeed;
	m.ai_class       = CLASS_ALIEN_MONSTER;
	m.ai_melee_range = 120;			// she is enormous
	m.ai_range_range = 1024;		// the mortar
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   big_mom.mdl [2] walk 49f @35fps -> 130.1
	//   big_mom.mdl [3] run  23f @28fps -> 399.7
	m.ai_speed_walk  = 130;
	m.ai_speed_run   = 400;
	m.ai_yaw_speed   = 90;
	m.ai_dmg_scale   = 1;
	m.ai_event       = BigMomma_Event;
	m.ai_painsound   = BigMomma_PainSound;
	m.ai_death       = BigMomma_Death;
	m.ai_selectsched = BigMomma_SelectSched;
	// First brood comes shortly after she engages, not on the opening tick: an
	// instant birth on sighting reads as a spawn glitch rather than a boss move.
	m.ai_crabtime    = time + 4;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// apache / osprey
// ---------------------------------------------------------------------------
// One sequence each, so there is no animation to drive and no event to hang an
// attack on: the firing runs from the per-tick hook, the same mechanism the
// barnacle and the kingpin needed for the same reason.
void() Apache_Tick =
{
	if (!self.ai_enemy)
		return;
	if (time < self.ai_nextattack)
		return;
	if (vlen(self.ai_enemy.origin - self.origin) > self.ai_range_range)
		return;

	// A short burst rather than one round: a helicopter chin gun reads as
	// sustained fire, and AI_FireBullets already does the per-round spread roll.
	float d = cvar("sv_ai_apache_dmg");
	if (d <= 0)
		d = 10;
	AI_FireBullets(self, self.ai_enemy, 3, 0.08716, d);
	self.ai_nextattack = time + 1.0;

	if (!self.gag)
		sound(self, CHAN_WEAPON, "apache/ap_whine1.wav", 1, ATTN_NORM);
};

void(entity m) Apache_ClassInit =
{
	m.ai_class    = CLASS_HUMAN_MILITARY;
	m.ai_movemode = AIMODE_FLY;
	m.ai_flyheight = 320;			// it stays well up, out of easy reach

	m.ai_melee_range = 0;
	m.ai_range_range = 2048;
	m.ai_speed_walk  = 120;
	m.ai_speed_run   = 320;
	m.ai_yaw_speed   = 90;
	m.ai_dmg_scale   = 1;
	m.ai_tick        = Apache_Tick;
	m.bloodcolor     = -1;			// a machine
};

// The osprey is a troop transport, not a gunship: in HL it drops grunts and does
// not shoot.  It flies and it can be destroyed, and that is deliberately all -
// the drop behaviour belongs with scripted_sequence (W8), which is what actually
// drives it on the maps that use it.
void(entity m) Osprey_ClassInit =
{
	m.ai_class    = CLASS_HUMAN_MILITARY;
	m.ai_movemode = AIMODE_FLY;
	m.ai_flyheight = 400;

	m.ai_melee_range = 0;
	m.ai_range_range = 0;			// unarmed
	m.ai_speed_walk  = 100;
	m.ai_speed_run   = 260;
	m.ai_yaw_speed   = 60;
	m.ai_dmg_scale   = 1;
	m.bloodcolor     = -1;
};

float() BigMomma_DefaultHealth
	= { float h = cvar("sv_ai_bigmomma_health"); return (h > 0) ? h : 1000; };
float() Apache_DefaultHealth
	= { float h = cvar("sv_ai_apache_health");   return (h > 0) ? h : 250; };
float() Osprey_DefaultHealth
	= { float h = cvar("sv_ai_osprey_health");   return (h > 0) ? h : 400; };
