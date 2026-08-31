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

// --- valve families (agrunt.cpp:139-188, bullsquid.cpp:432-497) --------------
// Both classes had a death and a pain voice built out of TWO members of a family
// Half-Life draws three to five from, so most of their voice set has never been
// heard: ag_die5, ag_pain2/3/5, bc_die2, bc_pain2/3.  Neither had an idle or an
// alert at all, and the alien grunt's ag_attack1-3 - the roar it makes when it
// commits to a charge - was neither precached nor reachable.
//
// The three ag_alert files HL skips are not an oversight to correct: ag_alert2 is
// on disk and Valve's pAlertSounds is 1/3/4/5.
const string SND_AGR_FIRE   = "agrunt/ag_fire1.wav agrunt/ag_fire2.wav agrunt/ag_fire3.wav";
const string SND_AGR_ATTACK = "agrunt/ag_attack1.wav agrunt/ag_attack2.wav agrunt/ag_attack3.wav";
const string SND_AGR_IDLE   = "agrunt/ag_idle1.wav agrunt/ag_idle2.wav agrunt/ag_idle3.wav agrunt/ag_idle4.wav";
const string SND_AGR_ALERT  = "agrunt/ag_alert1.wav agrunt/ag_alert3.wav agrunt/ag_alert4.wav agrunt/ag_alert5.wav";
const string SND_AGR_PAIN   = "agrunt/ag_pain1.wav agrunt/ag_pain2.wav agrunt/ag_pain3.wav agrunt/ag_pain4.wav agrunt/ag_pain5.wav";
const string SND_AGR_DIE    = "agrunt/ag_die1.wav agrunt/ag_die4.wav agrunt/ag_die5.wav";
// Shared with the zombie and the gonarch; HL's own claw sounds for a big melee.
const string SND_CLAW_HIT   = "zombie/claw_strike1.wav zombie/claw_strike2.wav zombie/claw_strike3.wav";
const string SND_CLAW_MISS  = "zombie/claw_miss1.wav zombie/claw_miss2.wav";

const string SND_BSQ_SPIT   = "bullchicken/bc_attack2.wav bullchicken/bc_attack3.wav";
const string SND_BSQ_GROWL  = "bullchicken/bc_attackgrowl.wav bullchicken/bc_attackgrowl2.wav bullchicken/bc_attackgrowl3.wav";
const string SND_BSQ_BITE   = "bullchicken/bc_bite2.wav bullchicken/bc_bite3.wav";
const string SND_BSQ_IDLE   = "bullchicken/bc_idle1.wav bullchicken/bc_idle2.wav bullchicken/bc_idle3.wav bullchicken/bc_idle4.wav bullchicken/bc_idle5.wav";
// HL's AlertSound is bc_idle1 or bc_idle2 at ATTN_NORM rather than a family of
// its own (bullsquid.cpp:484-497) - the same two samples its idle uses, just
// carrying further.  Not a mistake in the port; it is what Valve wrote.
const string SND_BSQ_ALERT  = "bullchicken/bc_idle1.wav bullchicken/bc_idle2.wav";
const string SND_BSQ_PAIN   = "bullchicken/bc_pain1.wav bullchicken/bc_pain2.wav bullchicken/bc_pain3.wav bullchicken/bc_pain4.wav";
const string SND_BSQ_DIE    = "bullchicken/bc_die1.wav bullchicken/bc_die2.wav bullchicken/bc_die3.wav";

// --- gearbox families --------------------------------------------------------
// No Opposing Force SDK on this machine, so these are read out of the mount's own
// sound directories rather than from source, and the naming is regular enough to
// be unambiguous: <name>_idle/_alert/_pain/_die numbered from 1.  Every file below
// was listed out of gearbox/ before it was written down.
//
// The gonome is the one irregularity worth recording: its death family is
// gonome_death2/3/4 - there is no gonome_death1 - and its pain runs 1-4.  A
// %g roll from 1 would have been silent a quarter of the time.
const string SND_PIT_IDLE   = "pitdrone/pit_drone_idle1.wav pitdrone/pit_drone_idle2.wav pitdrone/pit_drone_idle3.wav";
const string SND_PIT_ALERT  = "pitdrone/pit_drone_alert1.wav pitdrone/pit_drone_alert2.wav pitdrone/pit_drone_alert3.wav";
const string SND_PIT_PAIN   = "pitdrone/pit_drone_pain1.wav pitdrone/pit_drone_pain2.wav pitdrone/pit_drone_pain3.wav pitdrone/pit_drone_pain4.wav";
const string SND_PIT_DIE    = "pitdrone/pit_drone_die1.wav pitdrone/pit_drone_die2.wav pitdrone/pit_drone_die3.wav";
const string SND_PIT_SPIKE  = "pitdrone/pit_drone_attack_spike1.wav pitdrone/pit_drone_attack_spike2.wav";
const string SND_PIT_MELEE  = "pitdrone/pit_drone_melee_attack1.wav pitdrone/pit_drone_melee_attack2.wav";

const string SND_GNM_IDLE   = "gonome/gonome_idle1.wav gonome/gonome_idle2.wav gonome/gonome_idle3.wav";
const string SND_GNM_PAIN   = "gonome/gonome_pain1.wav gonome/gonome_pain2.wav gonome/gonome_pain3.wav gonome/gonome_pain4.wav";
const string SND_GNM_DIE    = "gonome/gonome_death2.wav gonome/gonome_death3.wav gonome/gonome_death4.wav";
const string SND_GNM_MELEE  = "gonome/gonome_melee1.wav gonome/gonome_melee2.wav";
const string SND_GNM_SPIT   = "gonome/gonome_jumpattack.wav";

const string SND_VOL_IDLE   = "voltigore/voltigore_idle1.wav voltigore/voltigore_idle2.wav voltigore/voltigore_idle3.wav";
const string SND_VOL_ALERT  = "voltigore/voltigore_alert1.wav voltigore/voltigore_alert2.wav voltigore/voltigore_alert3.wav";
const string SND_VOL_PAIN   = "voltigore/voltigore_pain1.wav voltigore/voltigore_pain2.wav voltigore/voltigore_pain3.wav voltigore/voltigore_pain4.wav";
const string SND_VOL_DIE    = "voltigore/voltigore_die1.wav voltigore/voltigore_die2.wav voltigore/voltigore_die3.wav";
const string SND_VOL_MELEE  = "voltigore/voltigore_attack_melee1.wav voltigore/voltigore_attack_melee2.wav";
const string SND_VOL_SHOCK  = "voltigore/voltigore_attack_shock.wav";

void() Aliens_Precache =
{
	precache_model("models/agrunt.mdl");
	precache_model("models/bullsquid.mdl");
	precache_model(AI_MDL_HORNET);
	precache_model(AI_SPR_SPIT);

	AI_SndPrecache(SND_AGR_FIRE);
	AI_SndPrecache(SND_AGR_ATTACK);
	AI_SndPrecache(SND_AGR_IDLE);
	AI_SndPrecache(SND_AGR_ALERT);
	AI_SndPrecache(SND_AGR_PAIN);
	AI_SndPrecache(SND_AGR_DIE);
	AI_SndPrecache(SND_CLAW_HIT);
	AI_SndPrecache(SND_CLAW_MISS);

	AI_SndPrecache(SND_BSQ_SPIT);
	AI_SndPrecache(SND_BSQ_GROWL);
	AI_SndPrecache(SND_BSQ_BITE);
	AI_SndPrecache(SND_BSQ_IDLE);
	AI_SndPrecache(SND_BSQ_PAIN);
	AI_SndPrecache(SND_BSQ_DIE);

	// gearbox / svencoop classes.  Guarded with Monster_ModelExists so a machine
	// without Opposing Force mounted logs nothing and precaches nothing, rather
	// than emitting a warning per model at every map load.  The SOUNDS are guarded
	// on the same test for the same reason - they ship in the same mount, so a
	// missing model and a missing voice are the same condition.  Before this, all
	// three classes were entirely mute AND produced live "SV_StartSound: not
	// precached" warnings on the installs that DO have them.
	if (Monster_ModelExists("models/pit_drone.mdl"))
	{
		precache_model("models/pit_drone.mdl");
		if (Monster_ModelExists(AI_MDL_SPIKE))
			precache_model(AI_MDL_SPIKE);
		AI_SndPrecache(SND_PIT_IDLE);
		AI_SndPrecache(SND_PIT_ALERT);
		AI_SndPrecache(SND_PIT_PAIN);
		AI_SndPrecache(SND_PIT_DIE);
		AI_SndPrecache(SND_PIT_SPIKE);
		AI_SndPrecache(SND_PIT_MELEE);
	}
	if (Monster_ModelExists("models/gonome.mdl"))
	{
		precache_model("models/gonome.mdl");
		AI_SndPrecache(SND_GNM_IDLE);
		AI_SndPrecache(SND_GNM_PAIN);
		AI_SndPrecache(SND_GNM_DIE);
		AI_SndPrecache(SND_GNM_MELEE);
		AI_SndPrecache(SND_GNM_SPIT);
	}
	if (Monster_ModelExists("models/baby_voltigore.mdl"))
		precache_model("models/baby_voltigore.mdl");
	if (Monster_ModelExists("models/voltigore.mdl"))
	{
		precache_model("models/voltigore.mdl");
		AI_SndPrecache(SND_VOL_IDLE);
		AI_SndPrecache(SND_VOL_ALERT);
		AI_SndPrecache(SND_VOL_PAIN);
		AI_SndPrecache(SND_VOL_DIE);
		AI_SndPrecache(SND_VOL_MELEE);
		AI_SndPrecache(SND_VOL_SHOCK);
	}
};

// ---------------------------------------------------------------------------
// shared attack bodies
// ---------------------------------------------------------------------------
const float ALIEN_MELEE_REACH = 70;

// `fxkind` is ALIENFX_* for the muzzle effect, or -1 for none.  It is a
// parameter rather than something the callers emit for themselves so the effect
// and the projectile provably leave the same point: the launch position is
// computed in here, and a call site recomputing it is a second copy of a
// derivation that has already been wrong once elsewhere in this port.
void(entity m, string mdl, float speed, float dmg, float grav, float fxkind) Alien_Spit =
{
	if (!m.ai_enemy)
		return;

	vector src = AI_MuzzlePos(m);
	vector dir = AI_AimDir(m, src, m.ai_enemy, 0.05);
	if (fxkind >= 0)
		AlienFX_Multicast(fxkind, src, dir);

	entity p = AI_LaunchProjectile(m, mdl, dir, speed, dmg, grav);

	// The impact spray, but only for the ones that ARE a glob of acid.  A hornet
	// is a solid thing that hits and stops; spraying it would be inventing a
	// behaviour the source does not have.
	if (p && fxkind == ALIENFX_SPIT_MUZZLE)
		p.ai_proj_fx = ALIENFX_SPIT_IMPACT + 1;
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
		Alien_Spit(self, AI_MDL_HORNET, 900, d, 0, ALIENFX_HORNET_FIRE);
		AI_SndPlay(self, CHAN_WEAPON, SND_AGR_FIRE);

		// Only the LAST hornet arms the cooldown, or the volley would end itself
		// after the first one.
		if (ai_event_code == AGR_AE_HORNET5)
			self.ai_nextattack = time + 2.5;
		return;
	}

	if (ai_event_code == AGR_AE_LEFT_PUNCH || ai_event_code == AGR_AE_RIGHT_PUNCH)
	{
		// Hit and miss are DIFFERENT sounds in Half-Life (agrunt.cpp:522-531), and
		// the difference is most of the feedback a punch gives: a swing that
		// connects cracks, a swing that whiffs whooshes.  AI_MeleeHull already
		// tells us which happened.
		if (AI_MeleeHull(self, ALIEN_MELEE_REACH, 25, 16) != world)
			AI_SndPlay(self, CHAN_WEAPON, SND_CLAW_HIT);
		else
			AI_SndPlay(self, CHAN_WEAPON, SND_CLAW_MISS);
		return;
	}
	// 10 / 11 are footsteps; HL plays them from the model and so do we, via the
	// shared EVENT_SOUND handler where the model names a file.
};


// The roar it makes when it commits, agrunt.cpp:362.  Fired from the attack task
// rather than from an anim event because no sequence on agrunt.mdl carries a code
// for it - in Half-Life it is AttackSound(), called by the schedule, not by the
// animation.  ag_attack1-3 were precached by nobody and had never played.
void() Agrunt_StartAttack =
{
	AI_SndPlay(self, CHAN_VOICE, SND_AGR_ATTACK);
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
	m.ai_fov         = 0.2;		// agrunt.cpp:587
	// Two hornet slots, squadmonster.h:36-39.  Alien grunts hold their fire for
	// each other exactly as human grunts do; the difference is what they throw.
	m.ai_slots_attack = SQSLOTS_AGRUNT_HORNET;
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
	m.ai_startattack = Agrunt_StartAttack;
	m.ai_snd_idle    = SND_AGR_IDLE;
	m.ai_snd_alert   = SND_AGR_ALERT;
	m.ai_snd_pain    = SND_AGR_PAIN;
	m.ai_snd_die     = SND_AGR_DIE;
	m.ai_snd_pitch   = -1;		// agrunt.cpp uses plain EMIT_SOUND, no jitter
	if (m.bloodcolor == 0)
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
		Alien_Spit(self, AI_SPR_SPIT, 900, d, 0.5, ALIENFX_SPIT_MUZZLE);
		AI_SndPlay(self, CHAN_WEAPON, SND_BSQ_SPIT);
		self.ai_nextattack = time + 2.5;
		return;
	}

	if (ai_event_code == BSQ_AE_BITE || ai_event_code == BSQ_AE_THROW)
	{
		entity bsq_hurt = AI_MeleeHull(self, ALIEN_MELEE_REACH, 25, 16);
		if (bsq_hurt != world)
		{
			AI_SndPlay(self, CHAN_WEAPON, SND_BSQ_BITE);
			// bullsquid.cpp:650, in case BSQUID_AE_THROW.  Centred on the
			// VICTIM with a radius of 2, which is not a typo in the SDK — it
			// is how HL addresses "shake only the thing I just hit" using a
			// broadcast primitive.  The SDK's own comment beside it explains
			// the choice over punchangle: "screeshake transforms the viewmodel
			// as well as the viewangle".
			SV_ScreenShake(bsq_hurt.origin, 25.0, 1.5, 0.7, 2);
		}
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


// bullsquid.cpp:1175-1181, the growl before it spits.  Three samples, all three
// precached by Valve and none of them reachable here until now.
void() Bullsquid_StartAttack =
{
	AI_SndPlay(self, CHAN_VOICE, SND_BSQ_GROWL);
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
	m.ai_fov         = 0.2;		// bullsquid.cpp:681
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
	m.ai_startattack = Bullsquid_StartAttack;
	m.ai_snd_idle    = SND_BSQ_IDLE;
	m.ai_snd_alert   = SND_BSQ_ALERT;
	m.ai_snd_pain    = SND_BSQ_PAIN;
	m.ai_snd_die     = SND_BSQ_DIE;
	if (m.bloodcolor == 0)
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
			d = 15;			// sk_pitdrone_dmg_spit
		// Flat, not arced: a spike is fired, not lobbed.  Falls back to the spit
		// sprite when Opposing Force is not mounted, so the class still works.
		string mdl = AI_MDL_SPIKE;
		if (!Monster_ModelExists(mdl))
			mdl = AI_SPR_SPIT;
		Alien_Spit(self, mdl, 1200, d, 0, ALIENFX_SPIT_MUZZLE);
		AI_SndPlay(self, CHAN_WEAPON, self.ai_snd_shoot);
		self.ai_nextattack = time + 2.0;
		return;
	}
	// Its bite and whip are its OWN, not the bullsquid's: the shared handler plays
	// bc_bite2/3 because that is the class it was written for, and a pitdrone on an
	// install with gearbox mounted has pit_drone_melee_attack1/2 sitting unused.
	if (ai_event_code == BSQ_AE_BITE || ai_event_code == BSQ_AE_THROW
	 || ai_event_code == BSQ_AE_TAILWHIP)
	{
		float reach = ALIEN_MELEE_REACH;
		if (ai_event_code == BSQ_AE_TAILWHIP)
			reach = reach + 10;
		// sk_pitdrone_dmg_bite and sk_pitdrone_dmg_whip are BOTH 25 in Sven's
		// skill.cfg, so one number covers both codes honestly.
		float md = cvar("sv_ai_pitdrone_melee");
		if (md <= 0)
			md = 25;
		if (AI_MeleeHull(self, reach, md, 16) != world)
			AI_SndPlay(self, CHAN_WEAPON, self.ai_snd_melee);
		return;
	}
	Bullsquid_Event();		// reload is identical (and is animation only)
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

	// Its own voice, but ONLY when it is wearing its own rig.  Monster_DefaultModel
	// falls a pitdrone back to bullsquid.mdl when gearbox is not mounted, and the
	// gearbox sound directory is missing on exactly the same installs - so the test
	// that picked the model is the test that has to pick the voice.  Guarding on
	// m.model rather than re-probing the filesystem is the same rule Grunt_RigOverride
	// follows, and it also covers a map that sets its own model key.
	if (m.model == "models/pit_drone.mdl")
	{
		m.ai_snd_idle  = SND_PIT_IDLE;
		m.ai_snd_alert = SND_PIT_ALERT;
		m.ai_snd_pain  = SND_PIT_PAIN;
		m.ai_snd_die   = SND_PIT_DIE;
		m.ai_snd_shoot = SND_PIT_SPIKE;
		m.ai_snd_melee = SND_PIT_MELEE;
	}
	else
	{
		// Wearing the bullsquid, so it keeps the bullsquid's voice - which
		// Bullsquid_ClassInit already installed above.
		m.ai_snd_shoot = SND_BSQ_SPIT;
		m.ai_snd_melee = SND_BSQ_BITE;
	}
};

// ---------------------------------------------------------------------------
// gonome
// ---------------------------------------------------------------------------
void() Gonome_Event =
{
	if (ai_event_code == GON_AE_CLAW1 || ai_event_code == GON_AE_CLAW2)
	{
		float md = cvar("sv_ai_gonome_melee");
		if (md <= 0)
			md = 30;		// sk_gonome_dmg_one_slash
		if (AI_MeleeHull(self, ALIEN_MELEE_REACH, md, 16) != world)
			AI_SndPlay(self, CHAN_WEAPON, self.ai_snd_melee);
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
		float sd = cvar("sv_ai_gonome_dmg");
		if (sd <= 0)
			sd = 15;		// sk_gonome_dmg_guts
		Alien_Spit(self, AI_SPR_SPIT, 900, sd, 0.5, ALIENFX_SPIT_MUZZLE);
		AI_SndPlay(self, CHAN_WEAPON, self.ai_snd_shoot);
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

	// gonome.mdl is gearbox-only and has no fallback rig in Monster_DefaultModel,
	// so this class simply does not appear without the mount.  The guard is kept
	// anyway, for the same reason the pitdrone has one: a map may set its own model
	// key, and a class whose voice depends on a mount should say so out loud.
	//
	// It had NO pain and NO death hook of any kind - 127 placements that took a
	// magazine in silence and fell over in silence.
	if (m.model == "models/gonome.mdl")
	{
		m.ai_snd_idle  = SND_GNM_IDLE;
		m.ai_snd_pain  = SND_GNM_PAIN;
		m.ai_snd_die   = SND_GNM_DIE;
		m.ai_snd_melee = SND_GNM_MELEE;
		m.ai_snd_shoot = SND_GNM_SPIT;
	}
	if (m.bloodcolor == 0)
		m.bloodcolor = 195;
};

// ---------------------------------------------------------------------------
// voltigore
// ---------------------------------------------------------------------------
void() Voltigore_Event =
{
	if (ai_event_code == VOL_AE_LEFT_PUNCH || ai_event_code == VOL_AE_RIGHT_PUNCH)
	{
		float md = cvar("sv_ai_voltigore_melee");
		if (md <= 0)
			md = 30;		// sk_voltigore_dmg_punch
		if (AI_MeleeHull(self, ALIEN_MELEE_REACH + 10, md, 20) != world)
			AI_SndPlay(self, CHAN_WEAPON, self.ai_snd_melee);
		return;
	}
	if (ai_event_code == VOL_AE_BALL)
	{
		// The energy ball reuses the beam rather than a projectile: it is an
		// electric discharge, and the beam already exists and already works.
		//
		// sk_voltigore_dmg_beam is 40, not the 25 this shipped with - it is the
		// hardest-hitting single ranged attack any non-boss alien has, and the
		// class was doing under two thirds of it.
		float bd = cvar("sv_ai_voltigore_dmg");
		if (bd <= 0)
			bd = 40;
		if (self.ai_enemy)
			AI_FireBeam(self, self.ai_enemy, HL_BEAM_EGON, bd);
		AI_SndPlay(self, CHAN_WEAPON, self.ai_snd_shoot);
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

	// Same story as the gonome: gearbox-only, and until now completely mute in
	// every register - no pain, no death, and a shock attack whose 59 KB sample
	// (voltigore_attack_shock.wav) had never been loaded.
	// Both rigs, because baby_voltigore.mdl is the same rig at a smaller scale and
	// shares the adult's voice folder - gating on the adult filename alone left the
	// juvenile completely mute.
	if (m.model == "models/voltigore.mdl" || m.model == "models/baby_voltigore.mdl")
	{
		m.ai_snd_idle  = SND_VOL_IDLE;
		m.ai_snd_alert = SND_VOL_ALERT;
		m.ai_snd_pain  = SND_VOL_PAIN;
		m.ai_snd_die   = SND_VOL_DIE;
		m.ai_snd_melee = SND_VOL_MELEE;
		m.ai_snd_shoot = SND_VOL_SHOCK;
	}
	if (m.bloodcolor == 0)
		m.bloodcolor = 195;
};

// Sven's juvenile voltigore, which pizza_ya_san1 uses as the thing that comes out
// of a burst flour sack (three spawners, and the classname appeared nowhere in
// this mod).  Same rig at a smaller scale - the relationship babygarg has to
// garg - but NOT the same behaviour: the shared rig's ranged attack is untagged
// on the baby, so it is melee-only and the speeds are its own, both measured out
// of baby_voltigore.mdl rather than scaled from the adult.  See below.
// baby_voltigore.mdl does carry the adult's sequence NAMES, so the event table
// and the voice families still come through Voltigore_ClassInit unchanged.
void(entity m) BabyVoltigore_ClassInit =
{
	Voltigore_ClassInit(m);
	m.ai_melee_range = ALIEN_MELEE_REACH;
	m.ai_dmg_scale   = 0.5;

	// THE BABY HAS NO RANGED ATTACK, and inheriting the adult's is the whole of
	// "they are passive and never move".  Voltigore_ClassInit leaves
	// ai_range_range at 1024 (:579), so AI_CheckAttacks raises COND_CAN_RANGE1
	// for any enemy in sight inside that (sv_ai_core.qc:668) and the ladder
	// returns SCHED_RANGE_ATTACK1 (sv_ai_core.qc:1581) BEFORE it can ever fall
	// through to SCHED_CHASE_ENEMY (:1624).  That schedule is stop / face / attack
	// with no movement task in it (sv_ai_sched.qc:627).
	//
	// And the attack it commits to does not exist on this rig.  Read out of the
	// file: baby_voltigore.mdl's `distanceattack` (seq 10) carries activity 0,
	// actweight 0 and ZERO animation events, where voltigore.mdl's carries
	// activity 28 (ACT_RANGE_ATTACK1) and event code 1 at 0.89 s.  So
	// AI_SeqForActivity finds no ACT_RANGE_ATTACK1, walks a fallback chain that
	// has no entry for it (sv_ai_anim.qc:92-150), and lands on sequence 0 -
	// idle1.  The baby stands in its idle pose for 1.25 s, arms a cooldown, holds
	// SCHED_COMBAT_FACE through it (sv_ai_core.qc:1612), and repeats forever
	// without firing anything or taking a step.
	//
	// Sven's own manual agrees with the rig and is the authority here, since no
	// Opposing Force SDK exists to check against: "Baby voltigore ... Weapons:
	// Swipe" against "Voltigore ... Weapons: Lightning ; swipe"
	// (svencoop/manual/enemies.html).  Melee only.  The untagged distanceattack
	// is a leftover of the shared rig that Sven never wired up.
	//
	// 0 rather than a smaller number: this must REMOVE the opportunity, not
	// shrink it.  It also makes the map's `attackrange` key inert for this class,
	// which is the documented contract at sv_ai_core.qc:3786 - that key tunes a
	// ranged attack, it does not grant one.  Neither ml_flour5 maker on
	// pizza_ya_san1 sets it.
	m.ai_range_range = 0;

	// Measured off baby_voltigore.mdl with the formula Voltigore_ClassInit states
	// at :580 - |linearmovement| * fps / (numframes-1):
	//   baby_voltigore.mdl [2] walk 49f @25fps, lm 23.681 ->  12.3
	//   baby_voltigore.mdl [3] run  37f @50fps, lm 80.040 -> 111.2
	// The 45/280 these replace were the garg pair's RATIOS applied to the adult's
	// figures rather than this rig's own, and they are 3.7x and 2.5x too fast.
	// AI_TaskRun translates the body at ai_speed_run (sv_ai_core.qc:2983) while
	// the client plays the run cycle at the model's own rate, so the baby skated.
	m.ai_speed_walk  = 12;
	m.ai_speed_run   = 111;
	m.ai_yaw_speed   = 160;
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
// sk_voltigore_health.  Gearbox-only class, so Sven's skill.cfg is the only
// source there is - 350, not the 200 that was picked to sit beside the gonome's.
float() Voltigore_DefaultHealth
	= { float h = cvar("sv_ai_voltigore_health"); return (h > 0) ? h : 350; };
