// server/monsters/mon_grunt.qc
// ----------------------------------------------------------------------------
// The gun shooters — the single biggest block in the corpus at ~2600 placements.
//
// One archetype covers all of them because they share one activity set and one
// event vocabulary; only the model, health, damage and rate of fire differ:
//
//   monster_human_grunt (694)   monster_male_assassin (419)
//   monster_human_grunt_ally (406)  monster_barney (319)
//   monster_shocktrooper (208)  monster_robogrunt (164)
//   monster_hwgrunt (94)        monster_human_assassin (85)
//   monster_otis (81)           monster_human_medic_ally (52)
//   monster_bodyguard (41)      monster_th_grunt_repel (31)
//
// models/hgrunt.mdl, read out of the file (82 sequences, 1 bone controller):
//   act  1  idle1 / idle2          act 47 combatidle
//   act  3  walk1  85f @30 loop    act  4  run 18f @30 loop
//   act 11/12  strafeleft/right    act 15/16  180L / 180R
//   act 25  cower                  act 65  victorydance
//   act 26  smflinch(w5), 73..76 per-limb
//   act 28  crouching_mp5  13f @20 LOOP:
//             code 4 @0.00s, code 5 @0.10s, code 6 @0.20s   BURST1/2/3
//             plus three 5001 muzzleflashes, options "50"
//           crouching_shotgun 13f @20 once: code 4 @0.00s, 5001 "51"
//   act 29  launchgrenade (code 8 @0.53s) / throwgrenade (code 7 @1.20s)
//   act 30  frontkick 32f @35: code 3 @0.40s + a 2010 swish
//   act 32  reload_mp5 71f @40: code 2 @1.18s
//   act 21/22/23  advance / flank / retreat signals (code 10 on advance)
//   act 60  drop_grenade (code 9 @0.55s)
//   act 48/49  limpingwalk / limpingrun
//   act 40..43  barnacled1..4      act 5/10/50/51  the repel set
//   deaths 36/37/38/66/68, each with code 11 (DROP_GUN) + an EVENT_BODYDROP
//
// models/barney.mdl (71 sequences, 2 bone controllers) is the same shape with a
// smaller vocabulary: act 28 shootgun/shootgun2 fire ONE round on code 3, act 33
// draw (code 2), act 34 holster (code 4), act 32 reload.  Its walk and run carry
// real EVENT_SOUND footsteps, which AI_PrecacheModelSounds now picks up.
//
// THE BURST IS THE POINT.  A grunt's attack sequence LOOPS and fires three rounds
// per cycle, 0.1 s apart, from anim events.  Implementing it as "one schedule =
// one shot" would produce a soldier that plinks once every two seconds; the
// three-round burst on a looping sequence is what makes them read as suppressing
// fire.  That also means the attack ends by the SCHEDULE, not by the animation
// running out - a looping sequence never reports done.
// ----------------------------------------------------------------------------

// hgrunt.cpp event codes.
const float GRU_AE_RELOAD       = 2;
const float GRU_AE_KICK         = 3;
const float GRU_AE_BURST1       = 4;
const float GRU_AE_BURST2       = 5;
const float GRU_AE_BURST3       = 6;
const float GRU_AE_GREN_TOSS    = 7;
const float GRU_AE_GREN_LAUNCH  = 8;
const float GRU_AE_GREN_DROP    = 9;
const float GRU_AE_CAUGHT_ENEMY = 10;
const float GRU_AE_DROP_GUN     = 11;

// barney.cpp uses the same low range for different things — which is exactly why
// the event dispatcher keys on (class, code) and never on the code alone.
const float BAR_AE_DRAW    = 2;
const float BAR_AE_SHOOT   = 3;
const float BAR_AE_HOLSTER = 4;

// hassassin.cpp:56-58 — and this is the third meaning of the same low range.
// The assassin shares the grunt's CommonInit but NOT its codes: code 2 is a
// grenade toss here and a reload on a grunt, and code 1 is not a grunt event at
// all.  Inheriting Grunt_Event therefore made every assassin in the corpus mime:
// its shoot event fell through to nothing, and its grenade toss was swallowed by
// the reload no-op.
const float ASN_AE_SHOOT = 1;
const float ASN_AE_TOSS  = 2;
const float ASN_AE_JUMP  = 3;

// hassassin.cpp:201-210.  The assassin's accuracy TIGHTENS as she keeps firing:
// the first shot after a two-second lull opens at 0.10 and every round after it
// closes by 0.01 down to a floor of 0.02.  Sustained fire is what makes her
// dangerous, and backing off long enough to break the streak is the counter.
const float ASN_SPREAD_START = 0.10;
const float ASN_SPREAD_STEP  = 0.01;
const float ASN_SPREAD_MIN   = 0.02;
const float ASN_SPREAD_RESET = 2.0;	// seconds of quiet that reopens the cone
const float ASN_GREN_FUSE    = 2.0;	// hassassin.cpp:253, ShootTimed(..., 2.0)
const float ASN_GREN_RECHECK = 6.0;	// hassassin.cpp:255

.float ai_shot_spread;		// the assassin's running deviation
.float ai_lastshot;			// when she last pulled the trigger

const float GRU_MELEE_REACH  = 70;
const float GRU_RANGE        = 1600;
// The base delay between attack sequences.  0 is Half-Life's own figure for this
// whole family - neither CBarney nor CHGrunt gates its range attack on time at
// all, and the firing animation is the rate limit.  It used to be 1.2 s ON TOP of
// the animation, which is where "their shooting is far too slow" came from.
// See AI_ArmAttackCooldown (sv_ai_core.qc) for the distance term and for the one
// part of HL's cadence that needs an engine change to reach.
const float GRU_ATTACK_DELAY = 0;
const float GRU_SPREAD       = 0.08716;	// HL VECTOR_CONE_5DEGREES
const float GRU_SPREAD_WIDE  = 0.17365;	// 10 degrees, for the sloppier shooters

// Read out of dlls/weapons.h:422-431 rather than derived - HL's cone macros are
// NAMED for the full angle but hold the sine of the HALF angle, so
// VECTOR_CONE_10DEGREES is 0.08716 = sin(5 deg).  Deriving them from the names
// would put every one of these out by a factor of two.
const float GRU_SPREAD_PISTOL   = 0.01745;	// VECTOR_CONE_2DEGREES  - barney.cpp:355
const float GRU_SPREAD_SHOTGUN  = 0.13053;	// VECTOR_CONE_15DEGREES - hgrunt.cpp:828

// gSkillData.hgruntShotgunPellets.  valve/skill.cfg carries sk_hgrunt_pellets1/2/3
// = 3/5/6; 5 is skill 2, Half-Life's default difficulty, which is the same tier
// the shipped GRU_GREN_SPEED (sk_hgrunt_gspeed2 = 600) was already taken from.
const float GRU_SHOTGUN_PELLETS = 5;

// The shocktrooper's shock rifle.  Declared up here with the other constants
// because Grunt_Precache below names it and QC needs a constant declared before
// the line that reads it.
const string SND_SHOCK_FIRE = "weapons/shock_fire.wav";

// The Opposing Force engineer's sidearm, for the same reason: Grunt_Precache
// names it below.  The file lives in gearbox AND in svencoop, so it resolves on
// either mount; "de_shot1.wav" also exists in gearbox but is the player weapon's
// alternate, not the one the NPC uses.
const string SND_DEAGLE_FIRE = "weapons/desert_eagle_fire.wav";

void() Grunt_Precache =
{
	precache_model("models/hgrunt.mdl");
	precache_model("models/barney.mdl");
	precache_model("models/hassassin.mdl");

	precache_sound("weapons/sbarrel1.wav");
	precache_sound("weapons/pl_gun1.wav");		// hassassin.cpp:277-278
	precache_sound("weapons/pl_gun2.wav");
	precache_sound("hgrunt/gr_pain1.wav");
	precache_sound("hgrunt/gr_pain2.wav");
	precache_sound("hgrunt/gr_pain3.wav");
	precache_sound("hgrunt/gr_die1.wav");
	precache_sound("hgrunt/gr_die2.wav");
	precache_sound("hgrunt/gr_die3.wav");
	precache_sound("hgrunt/gr_mgun1.wav");		// the MP5 report; see Grunt_GunSound
	precache_sound("weapons/glauncher.wav");	// M203
	precache_sound("barney/ba_pain1.wav");
	precache_sound("barney/ba_pain2.wav");
	precache_sound("barney/ba_pain3.wav");
	precache_sound("barney/ba_die1.wav");
	precache_sound("barney/ba_die2.wav");
	precache_sound("barney/ba_die3.wav");
	// The 9mm/shotgun report.  These are the weapon sounds HL's grunts use, and
	// they are already precached by the player weapons - restating them is free
	// and keeps this class independent of which guns a map happens to include.
	precache_sound("weapons/hks1.wav");
	precache_sound("weapons/hks2.wav");
	precache_sound("weapons/hks3.wav");

	// The REAL Half-Life monster gun reports, which are not the player's.
	// hgrunt.cpp:922 picks at random between gr_mgun1 and gr_mgun2 (gr_mgun3 is
	// in the mount but HL's burst never uses it), and barney.cpp:364 fires
	// ba_attack2 with a pitch shift.  All four files verified present under
	// valve/sound/.
	precache_sound("hgrunt/gr_mgun2.wav");
	// The shocktrooper's rifle.  Its VOICE needs no line here - it rides event 1011
	// inside strooper.mdl and AI_PrecacheModelSounds harvests it off the model -
	// but the gun report is named by QC, so it has to be named here too.
	precache_sound(SND_SHOCK_FIRE);
	precache_sound(SND_DEAGLE_FIRE);
	precache_sound("barney/ba_attack1.wav");
	precache_sound("barney/ba_attack2.wav");

	// The HW grunt's minigun.  Present in valve/ since 1998 and precached by
	// nobody, which is why its 15-round burst was completely silent.
	precache_sound("hassault/hw_shoot1.wav");
	precache_sound("hassault/hw_shoot2.wav");
	precache_sound("hassault/hw_shoot3.wav");
};

// ---------------------------------------------------------------------------
// loadout
// ---------------------------------------------------------------------------
// hgrunt.cpp's pev->weapons bits.  A grunt carries EITHER hand grenades or the
// M203, never both, and which one it is decides whether the arc is a lob or a
// flat contact shot.  Map-placed grunts set this key; when they do not, HL's
// default is 9mmAR + hand grenades, so that is the default here too.
//
// These live ABOVE the firing code rather than down with the grenades, because
// HGRUNT_SHOTGUN now selects the gun report and the pellet blast as well as the
// throw arc - QC needs a constant declared before the line that reads it, and
// the grenade block compiles later.
const float HGRUNT_9MMAR          = 1;
const float HGRUNT_HANDGRENADE    = 2;
const float HGRUNT_GRENADELAUNCHER= 4;
const float HGRUNT_SHOTGUN        = 8;

// ---------------------------------------------------------------------------
// firing
// ---------------------------------------------------------------------------
// .weapon_burst_left is not a field this codebase has, and adding one for three
// rounds would be a field per monster for something the ANIMATION already tracks:
// the model fires on codes 4, 5 and 6, so the burst count is baked into the
// sequence.  All this has to do is convert one event into one round.
//
// THE SOUND IS NOT PLAYED HERE ANY MORE, and that is the whole point of the
// split.  Half-Life plays the gun report from the EVENT, not from the shot:
// hgrunt.cpp:913-937 emits it on BURST1 only, so a three-round burst is one
// bang and two silent rounds.  Playing it per bullet - which is what this
// function used to do - stacked three overlapping MP5 samples on every burst.
void(entity m, float count, float dmg, float spread) Grunt_FireOne =
{
	if (!m.ai_enemy)
		return;

	AI_FireBullets(m, m.ai_enemy, count, spread, dmg);
};

// ---------------------------------------------------------------------------
// gun reports
// ---------------------------------------------------------------------------
// One hook per rig, installed by the class init, because the barney rig and the
// hgrunt rig do not carry the same gun and never did.  Barney firing an MP5 was
// the visible symptom; the cause was that a single shared FireOne owned the
// sound, so every shooter in the family inherited the grunt's.
//
// `weapons/hks*.wav` - which is what everything here used to play - is the
// PLAYER's MP5.  Half-Life's monsters have their own reports and they are
// different samples.
void(entity m) Grunt_GunSound =
{
	if (m.gag)
		return;

	// Shotgun grunts get the shotgun (hgrunt.cpp:933).  HGRUNT_SHOTGUN has been
	// declared since the class landed and nothing ever read it, which is why
	// weapons/sbarrel1.wav was precached and never once played.
	if (m.weapons & HGRUNT_SHOTGUN)
	{
		sound(m, CHAN_WEAPON, "weapons/sbarrel1.wav", 1, ATTN_NORM);
		return;
	}

	// Two samples, picked at random - hgrunt.cpp:918 is a straight RANDOM_LONG(0,1).
	// gr_mgun3.wav exists in the mount but HL's burst code never reaches it.
	if (random() < 0.5)
		sound(m, CHAN_WEAPON, "hgrunt/gr_mgun1.wav", 1, ATTN_NORM);
	else
		sound(m, CHAN_WEAPON, "hgrunt/gr_mgun2.wav", 1, ATTN_NORM);
};

// The Opposing Force torch and medic allies.  See the bodygroup dump in
// Grunt_RigOverride for why this is a hand cannon and not an MP5.
//
// The pitch wobble is Barney's, not invented: HL gives every monster handgun the
// same lopsided RANDOM_LONG(0,20) shift (barney.cpp:356-364) so a sustained
// exchange does not sound like one sample on repeat, and a Desert Eagle firing
// six identical shots is the most obvious case of that in the game.
void(entity m) Grunt_DeagleSound =
{
	if (m.gag)
		return;

	float shift = floor(random() * 21);
	if (shift > 10)
		shift = 0;
	else
		shift = shift - 5;

	sound(m, CHAN_WEAPON, SND_DEAGLE_FIRE, 1, ATTN_NORM, 100 + shift, 0);
};

// The HW grunt's minigun, which had NO sound call of any kind - the muzzleflash
// branch of HWGrunt_Event fired fifteen rounds over 0.58 s in complete silence,
// and the only noise the class ever made came from its PISTOL branch playing the
// MP5 report.  That is the reported "the HW grunt doesn't make correct noises and
// plays smg firing sound sometimes".
//
// hassault/hw_shoot1-3, hw_spin, hw_spinup and hw_spindown all ship in valve/ and
// were precached by nobody.  RATE LIMITED rather than played per muzzle flash,
// because the samples are 1.19-1.29 s each - a full burst of minigun fire, not one
// round - so firing one per flash would stack twenty-six copies a second.  One per
// attack is what the sample is cut for.
const float HWG_BURSTSND_GAP = 1.15;	// just under the shortest of the three
.float ai_nextburstsnd;

void(entity m) HWGrunt_GunSound =
{
	if (m.gag)
		return;
	if (time < m.ai_nextburstsnd)
		return;
	m.ai_nextburstsnd = time + HWG_BURSTSND_GAP;

	float r = floor(random() * 3);
	if (r < 1)	sound(m, CHAN_WEAPON, "hassault/hw_shoot1.wav", 1, ATTN_NORM);
	else if (r < 2)	sound(m, CHAN_WEAPON, "hassault/hw_shoot2.wav", 1, ATTN_NORM);
	else		sound(m, CHAN_WEAPON, "hassault/hw_shoot3.wav", 1, ATTN_NORM);
};

// The report DISPATCHER.  A rig and a weapon are independent things: strooper.mdl
// shares the hgrunt's whole event vocabulary and carries a shock rifle, so it runs
// Grunt_Event and needs its own bang.  Classes that set no .ai_gunsound keep the
// grunt's, which is every one of them that actually carries an MP5 or a shotgun.
void(entity m) Grunt_FireSound =
{
	if (m.ai_gunsound)
	{
		m.ai_gunsound(m);
		return;
	}
	Grunt_GunSound(m);
};

// barney.cpp:356-364.  The pitch shift is HL's own and it is deliberately
// lopsided: RANDOM_LONG(0,20), and anything above 10 means NO shift at all, so
// roughly half the shots are unmodified and the rest land in 95..100.  That
// asymmetry is what stops a long exchange sounding like a synthesiser sweep.
void(entity m) Barney_GunSound =
{
	if (m.gag)
		return;

	float shift = floor(random() * 21);	// RANDOM_LONG(0, 20)
	if (shift > 10)
		shift = 0;
	else
		shift = shift - 5;

	// The 6th argument of `sound` is speedpct (fteextensions.qc:1693), where 100
	// is unmodified - the same scale HL's EMIT_SOUND_DYN pitch argument uses, so
	// the value carries across unconverted.
	sound(m, CHAN_WEAPON, "barney/ba_attack2.wav", 1, ATTN_NORM, 100 + shift, 0);
};

// ---------------------------------------------------------------------------
// grenades
// ---------------------------------------------------------------------------
// The grenade's own .gravity, which sv_gravity is scaled by for the arc maths.
// It must match W_HLGrenadeSpawn or every throw lands somewhere else.
const float GRU_GREN_GRAVITY  = 0.5;
const float GRU_GREN_SPEED    = 600;	// M203 muzzle speed (HL skill: hgruntGrenadeSpeed)
const float GRU_GREN_FUSE     = 3.5;	// hand grenade, hgrunt.cpp ShootTimed
const float GRU_GREN_MINRANGE = 256;	// inside this he would kill himself

.vector ai_tossvel;		// the arc solved at check time, released at event time
.float  ai_grenleft;		// grenades remaining
.float  ai_grencheck;		// rate limit on the (fairly expensive) arc solve
.float  ai_standing;		// HL's m_fStanding: fire from a stand or from a crouch

float(entity m) Grunt_HasGrenades =
{
	if (!m.ai_grenleft)
		return FALSE;
	return (m.weapons & (HGRUNT_HANDGRENADE | HGRUNT_GRENADELAUNCHER)) != 0;
};

// HL's CHGrunt::CheckRangeAttack2, and every refusal in it is load-bearing.
// The function's real job is saying NO: a grunt that throws whenever it can
// reach is a grunt that kills its own squad and itself.
// Every refusal below is reported under sv_ai_debug, because "the grunt is not
// throwing grenades" has eight possible causes and no observable difference
// between them.  Naming the veto is the difference between a five-minute fix and
// an afternoon.
void(entity m, string why) Grunt_GrenVeto =
{
	if (cvar("sv_ai_debug"))
		dprint(sprintf("[ai] %s grenade veto: %s\n", m.classname, why));
};

float(entity m) Grunt_CheckGrenade =
{
	if (!m.ai_enemy || !Grunt_HasGrenades(m))
		return FALSE;
	if (time < m.ai_grencheck)
		return FALSE;

	// Don't lob at something that is not on the ground - it will simply be
	// somewhere else by the time the grenade lands.
	if (!(m.ai_enemy.flags & FL_ONGROUND) && m.ai_enemy.origin_z > m.absmax_z)
	{
		m.ai_grencheck = time + 1;
		Grunt_GrenVeto(m, "enemy is airborne");
		return FALSE;
	}

	// Aim at the enemy's FEET for a lob (it rolls to them) and at the body for a
	// contact round (it detonates where it hits).
	vector target = m.ai_enemy.origin;
	if (m.weapons & HGRUNT_HANDGRENADE)
		target_z = m.ai_enemy.absmin_z;
	else
		target = AI_AimPoint(m.ai_enemy);

	// Too close: this is the self-preservation check, and it is 2D on purpose -
	// a grunt on a gantry above the player is still inside his own blast.
	vector flat = target - m.origin;
	flat_z = 0;
	if (vlen(flat) <= GRU_GREN_MINRANGE)
	{
		m.ai_grencheck = time + 1;
		Grunt_GrenVeto(m, "enemy too close - would frag himself");
		return FALSE;
	}

	// ...and this is the one that stops him fragging his own side.
	if (AI_FriendlyNear(m, target, GRU_GREN_MINRANGE))
	{
		m.ai_grencheck = time + 1;
		Grunt_GrenVeto(m, "friendly inside the blast");
		return FALSE;
	}

	vector src = AI_MuzzlePos(m);
	vector v;
	if (m.weapons & HGRUNT_HANDGRENADE)
		v = AI_VecCheckToss(m, src, target, GRU_GREN_GRAVITY);
	else
		v = AI_VecCheckThrow(m, src, target, GRU_GREN_SPEED, GRU_GREN_GRAVITY);

	if (v == '0 0 0')
	{
		// No arc exists from here.  Backing off for a full second rather than
		// retrying next tick is deliberate: the solve costs four traces, and the
		// geometry that refused it will not have changed in 100 ms.
		m.ai_grencheck = time + 1;
		Grunt_GrenVeto(m, "no clear arc exists");
		return FALSE;
	}

	m.ai_tossvel  = v;
	m.ai_grencheck = time + 0.3;
	return TRUE;
};

// A grunt prefers the gun.  The grenade is for an enemy it cannot shoot - behind
// cover, or far enough away that suppressing fire is not landing.
float() Grunt_SelectSched =
{
	if (self.ai_state != MS_COMBAT || !self.ai_enemy)
		return SCHED_NONE;
	if (time < self.ai_nextattack)
		return SCHED_NONE;

	// NO occlusion or minimum-distance test here, and that is deliberate after
	// measuring one.  Requiring "occluded OR further than 600" produced zero
	// throws across two full drives, because engagements in these maps happen at
	// close range with line of sight - the gate was mine, not Half-Life's.
	// hgrunt.cpp's CheckRangeAttack2 has no such condition: the 256-unit minimum
	// and the arc solve below are the entire safety story, and they are enough.
	if (!Grunt_CheckGrenade(self))
		return SCHED_NONE;

	self.ai_grenleft   = self.ai_grenleft - 1;
	self.ai_nextattack = time + 4;
	return SCHED_RANGE_ATTACK2;
};

// The three release events.  All three build the SAME entity a player's hand
// grenade builds, through W_HLGrenadeSpawn - so it bounces, replicates and
// explodes identically.  A lookalike would have been half the code and a
// different weapon.
void(entity m) Grunt_ThrowGrenade =
{
	makevectors('0 1 0' * m.angles_y);
	vector src = m.origin + v_forward * 34 + '0 0 32';
	entity g = W_HLGrenadeSpawn(m, src, m.ai_tossvel, time + GRU_GREN_FUSE);

	// Reported separately from the schedule, for the same reason bigmomma's birth
	// is: a range_attack2 SELECTION only means the animation started.  The grenade
	// leaves the hand on an event 1.2 s in, and a schedule that is cut short before
	// then throws nothing at all.
	// modelindex is in here because "the grunt's grenade was invisible" has two
	// completely different causes that produce identical behaviour: a modelindex
	// of 0 means the model was never precached and setmodel silently did nothing,
	// while a non-zero index means the object exists and the fault is downstream
	// in the CSQC replication.  One number separates them.
	if (cvar("sv_ai_debug"))
		dprint(sprintf("[ai] %s threw a grenade, vel=%v modelindex=%g owner=%s\n",
		               m.classname, m.ai_tossvel, g.modelindex, m.classname));

	// NO SOUND.  HGRUNT_AE_GREN_TOSS (hgrunt.cpp:882-892) plays nothing at all -
	// the callout is the HG_THROW sentence, which is a different system entirely.
	// What used to be here was hgrunt/gr_mgun1.wav on CHAN_VOICE, i.e. the MP5
	// burst report coming out of the grunt's throat every time he lobbed a grenade.
};

// The M203's contact round: same object, but it detonates on the first thing it
// touches instead of on a fuse.  The long backstop fuse is there so a round that
// somehow touches nothing still cleans itself up rather than living forever.
void() Grunt_ContactGrenadeTouch =
{
	if (other == self.owner)
		return;
	W_HLGrenadeExplode();
};

void(entity m) Grunt_LaunchGrenade =
{
	makevectors('0 1 0' * m.angles_y);
	vector src = m.origin + v_forward * 34 + '0 0 32';

	entity g = W_HLGrenadeSpawn(m, src, m.ai_tossvel, time + 6);
	g.touch = Grunt_ContactGrenadeTouch;

	// 0.8, which is hgrunt.cpp:896's own volume, not 1.
	if (!m.gag)
		sound(m, CHAN_WEAPON, "weapons/glauncher.wav", 0.8, ATTN_NORM);
};

// Dropped at his feet, short fuse: in HL this is what a dying grunt does, and it
// is the reason you do not stand over a body.  Zero velocity, so no arc check.
void(entity m) Grunt_DropGrenade =
{
	makevectors('0 1 0' * m.angles_y);
	vector src = m.origin + v_forward * 17 - v_right * 27 + '0 0 6';
	W_HLGrenadeSpawn(m, src, '0 0 0', time + 2);
};

void() Grunt_Event =
{
	float dmg = cvar("sv_ai_grunt_dmg");
	if (dmg <= 0)
		dmg = 8;

	if (ai_event_code == GRU_AE_BURST1
	 || ai_event_code == GRU_AE_BURST2
	 || ai_event_code == GRU_AE_BURST3)
	{
		// The shotgun grunt is not a three-round burst at all - hgrunt.cpp:914
		// branches on the loadout bit and calls Shotgun() instead of Shoot(),
		// which is ONE blast of gSkillData.hgruntShotgunPellets at
		// VECTOR_CONE_15DEGREES.  Only BURST1 carries it; the other two codes
		// belong to the MP5's second and third rounds and must not fire a
		// second and third shell.
		if (self.weapons & HGRUNT_SHOTGUN)
		{
			if (ai_event_code == GRU_AE_BURST1)
			{
				Grunt_FireOne(self, GRU_SHOTGUN_PELLETS, dmg, GRU_SPREAD_SHOTGUN);
				Grunt_FireSound(self);
			}
			return;
		}

		ai_dbg_shots_grunt = ai_dbg_shots_grunt + 1;
		Grunt_FireOne(self, 1, dmg, self.ai_spread);

		// ONE report per burst, on the first round only (hgrunt.cpp:913-937).
		if (ai_event_code == GRU_AE_BURST1)
			Grunt_FireSound(self);

		// The cooldown is NOT armed here any more.  It used to be, on BURST3, and
		// that silently required every rig sharing this handler to raise code 6 -
		// which strooper.mdl and massn.mdl's shotgun and m40a1 sequences do not.
		// AI_ArmAttackCooldown now arms it at sequence end instead.
		return;
	}

	if (ai_event_code == GRU_AE_KICK)
	{
		AI_MeleeHull(self, GRU_MELEE_REACH, dmg * 2, 16);
		return;
	}

	if (ai_event_code == GRU_AE_RELOAD)
	{
		// Nothing to track: these monsters have no ammo model, and HL's own
		// reload only resets a counter this AI does not keep.  The animation is
		// the whole behaviour.
		return;
	}

	// TOSS and LAUNCH are ONE case, and the loadout - not the event code - decides
	// which kind of grenade comes out.
	//
	// hgrunt.mdl has TWO sequences tagged act 29: "throwgrenade" carrying code 7 at
	// 1.20 s, and "launchgrenade" carrying code 8 at 0.53 s.  frameforaction picks
	// between them by weight, at random, every time.  Keying the behaviour on the
	// code that arrived would therefore mean a grunt carrying hand grenades fires a
	// contact round roughly half the time, purely because the animation lottery
	// went the other way.  Both codes mean the same thing - "release it now" - so
	// both release whatever this grunt is actually carrying.
	if (ai_event_code == GRU_AE_GREN_TOSS || ai_event_code == GRU_AE_GREN_LAUNCH)
	{
		if (self.weapons & HGRUNT_GRENADELAUNCHER)
			Grunt_LaunchGrenade(self);
		else
			Grunt_ThrowGrenade(self);
		return;
	}
	if (ai_event_code == GRU_AE_GREN_DROP)
	{
		Grunt_DropGrenade(self);
		return;
	}

	// DROP_GUN, which every death sequence on every hgrunt-family rig raises and
	// which nothing could act on until .body was networked.  Without it a corpse
	// that has just dropped a pickup still has the same weapon painted onto its
	// hand, which is the "known cosmetic gap" the last patch had to admit to.
	if (ai_event_code == GRU_AE_DROP_GUN)
	{
		self.body = self.ai_body_gone;
		return;
	}

	// CAUGHT_ENEMY is the squad "I see him" callout; it arrives with the squad
	// work.
};

// barney / otis / medic: one round per shot, on a different code.
void() Barney_Event =
{
	// DRAW and HOLSTER, live at last.  barney.mdl and otis.mdl have raised these
	// on every draw/holster sequence since the class landed, and the comment at
	// the bottom of this function used to say "nothing here tracks that yet" -
	// because there was nothing to track it WITH until .body reached the
	// renderer.  See Grunt_BodyInit for where the numbers come from.
	if (ai_event_code == BAR_AE_DRAW)
	{
		self.body = self.ai_body_armed;
		return;
	}
	if (ai_event_code == BAR_AE_HOLSTER)
	{
		self.body = self.ai_body_holster;
		return;
	}

	if (ai_event_code == BAR_AE_SHOOT)
	{
		float dmg = cvar("sv_ai_barney_dmg");
		if (dmg <= 0)
			dmg = 10;
		// GRU_SPREAD is the grunt's 5 degrees, and Barney is not firing a grunt's
		// gun.  barney.cpp:355 is VECTOR_CONE_2DEGREES - a pistol, aimed, one
		// round at a time - so he is markedly more accurate than the squad that
		// used to share his spread by accident.
		ai_dbg_shots_barney = ai_dbg_shots_barney + 1;
		Grunt_FireOne(self, 1, dmg, GRU_SPREAD_PISTOL);
		Barney_GunSound(self);
		return;			// cooldown: AI_ArmAttackCooldown, at sequence end
	}
	// DRAW / HOLSTER are the weapon-in-hand beats; nothing here tracks that yet.
};

// ---------------------------------------------------------------------------
// hassassin.cpp — the black-ops assassin
// ---------------------------------------------------------------------------
// 504 placements across the corpus, and not one of them had ever fired: the
// class inherited Grunt_Event, whose lowest handled code is 2 (reload).  Her
// shoot is code 1 and fell off the end of the dispatch; her grenade toss IS
// code 2 and was therefore swallowed by the reload no-op.  Both are here now.
void() Assassin_Event =
{
	if (ai_event_code == ASN_AE_SHOOT)
	{
		if (!self.ai_enemy)
			return;

		// hassassin.cpp:201-210, verbatim.  A lull reopens the cone; a burst
		// walks it shut.  Reading the previous shot's time BEFORE stamping the
		// new one is the whole mechanism.
		if (self.ai_lastshot + ASN_SPREAD_RESET < time)
			self.ai_shot_spread = ASN_SPREAD_START;
		else
		{
			self.ai_shot_spread = self.ai_shot_spread - ASN_SPREAD_STEP;
			if (self.ai_shot_spread < ASN_SPREAD_MIN)
				self.ai_shot_spread = ASN_SPREAD_MIN;
		}
		self.ai_lastshot = time;

		float dmg = cvar("sv_ai_assassin_dmg");
		if (dmg <= 0)
			dmg = 5;		// sk_9mm_bullet2, BULLET_MONSTER_9MM

		ai_dbg_shots_assassin = ai_dbg_shots_assassin + 1;
		Grunt_FireOne(self, 1, dmg, self.ai_shot_spread);

		// hassassin.cpp:219-227 — one of two pistol reports, and deliberately
		// quiet (0.6..0.8): she is supposed to be hard to place by ear.
		if (random() < 0.5)
			sound(self, CHAN_WEAPON, "weapons/pl_gun1.wav", 0.6 + random() * 0.2, ATTN_NORM);
		else
			sound(self, CHAN_WEAPON, "weapons/pl_gun2.wav", 0.6 + random() * 0.2, ATTN_NORM);
		return;
	}

	if (ai_event_code == ASN_AE_TOSS)
	{
		// Same entity a grunt throws, so it bounces and explodes identically -
		// only the fuse differs (2 s here, hassassin.cpp:253).
		//
		// She is NOT given grenades yet, so this is live but inert, and that is
		// deliberate.  hassassin.cpp:688 gates the throw on m_iFrustration > 2 -
		// a counter that only climbs when she cannot reach or hit you - with the
		// comment "don't get grenade happy unless the player starts to piss you
		// off".  Handing her grenades without that counter would make her open
		// every fight with one.  The frustration counter belongs with her hunt
		// and jump AI; the handler is written now so that lands as one line.
		if (self.ai_tossvel != '0 0 0')
		{
			makevectors('0 1 0' * self.angles_y);
			vector src = self.origin + v_forward * 34 + '0 0 32';
			W_HLGrenadeSpawn(self, src, self.ai_tossvel, time + ASN_GREN_FUSE);
			self.ai_grenleft = self.ai_grenleft - 1;
		}
		self.ai_nextattack = time + ASN_GREN_RECHECK;
		return;
	}

	// JUMP is her leap, and it needs the jump-target solve that only arrives
	// with the movement work.  Left unhandled ON PURPOSE rather than faked:
	// launching her with an unsolved velocity would throw her into a wall.
};

// ---------------------------------------------------------------------------
// aim tracking  (W1a, engine Patch 125)
// ---------------------------------------------------------------------------
// hgrunt.mdl carries one bone controller on the spine, type 0x0008 (a bounded
// rotation) with a range of -70..70 DEGREES; barney.mdl has the same at -60..60
// plus a second for the mouth.  Feeding it the residual yaw to the enemy is what
// makes a soldier visibly track you between bursts instead of firing dead ahead
// and hoping - the single most obvious difference between a Half-Life grunt and
// a Quake enemy.
//
// The engine clamps to the model's own range, so no clamp here: a grunt asked to
// look 120 degrees to its left turns its torso as far as it goes and no further,
// then the body catches up at ai_yaw_speed.  That limit is the behaviour, not an
// error to be worked around.
void() Grunt_Aim =
{
	if (!self.ai_enemy || self.health <= 0)
	{
		self.bonecontrol1 = 0;
		return;
	}
	self.bonecontrol1 = AI_AimResidualYaw(self, AI_AimPoint(self.ai_enemy));
};

// ---------------------------------------------------------------------------
// attack preconditions
// ---------------------------------------------------------------------------
// A shooter must not fire from inside melee reach - HL's grunts kick instead,
// and without this gate the model plays its crouch-and-fire animation while
// standing on top of the player.
void() Grunt_CheckAttack =
{
	if (!self.ai_enemy)
		return;

	// Only refuse the gun at contact range if there IS something to refuse it in
	// favour of.  Barney and the other barney-rigged allies have no melee at all
	// (no act 30 in the model), so vetoing their gun up close left them with
	// NOTHING: measured as 18 combat_face selections, zero range attacks and one
	// landed hit while a headcrab chewed on them.
	if (self.ai_melee_range <= 0)
		return;

	if (vlen(self.ai_enemy.origin - self.origin) <= GRU_MELEE_REACH)
		self.ai_cond = self.ai_cond & ~COND_CAN_RANGE1;
};

void() Grunt_PainSound =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("hgrunt/gr_pain%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Grunt_Death =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("hgrunt/gr_die%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Barney_PainSound =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("barney/ba_pain%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Barney_Death =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("barney/ba_die%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

// Defined below, beside the pickup classes they name.  Forward-declared because
// the class inits that install them come first in this file.
void(entity m) Grunt_DropWeapon;
void(entity m) Barney_DropWeapon;

// ---------------------------------------------------------------------------
// shared init
// ---------------------------------------------------------------------------
// Everything the whole family agrees on.  Each class init below sets only what
// makes it different, which is what keeps twelve classes from becoming twelve
// ---------------------------------------------------------------------------
// per-activity turn rates
// ---------------------------------------------------------------------------
// Straight out of the SDK's SetYawSpeed switches.  These are HL's raw numbers;
// AI_ChangeYaw applies the same x2 HL does, so 150 here is 300 degrees/second
// on the ground exactly as it is in Half-Life.
//
// The spread inside each table is the point.  A grunt that pivots at 180 and
// shoots at 120 leans into a turn and plants itself to fire; one flat number
// for both - which is what every class had - reads as a turret on a lazy susan.
float(entity m, float act) Grunt_YawSpeed =		// hgrunt.cpp:643-683
{
	if (act == ACT_TURN_LEFT || act == ACT_TURN_RIGHT)	return 180;
	if (act == ACT_WALK)					return 180;
	if (act == ACT_RANGE_ATTACK1 || act == ACT_RANGE_ATTACK2)	return 120;
	if (act == ACT_MELEE_ATTACK1 || act == ACT_MELEE_ATTACK2)	return 120;
	return 150;						// IDLE and RUN
};

float(entity m, float act) Barney_YawSpeed =		// barney.cpp:285-307
{
	if (act == ACT_RUN)	return 90;
	return 70;						// IDLE, WALK and the default
};

float(entity m, float act) Assassin_YawSpeed =		// hassassin.cpp:169-184
{
	// 360 in every case, which at HL's doubling is 720 deg/s - by a wide margin
	// the fastest turn in the game, and the reason she is so hard to flank.
	return 360;
};

float(entity m, float act) Scientist_YawSpeed =		// scientist.cpp:612-635
{
	if (act == ACT_WALK)					return 180;
	if (act == ACT_RUN)					return 150;
	if (act == ACT_IDLE)					return 120;
	if (act == ACT_TURN_LEFT || act == ACT_TURN_RIGHT)	return 120;
	return 90;
};

// ---------------------------------------------------------------------------
// per-activity sequence overrides
// ---------------------------------------------------------------------------
// CHGrunt::SetActivity, hgrunt.cpp:1866-1972.  Half-Life reaches these by NAME
// because the model carries several sequences under one activity tag and only the
// loadout can say which is right; frameforaction re-rolls its weighted random on
// every call, so without this the grunt plays each candidate about half the time
// and there is no relationship between what he is holding and what he is seen to
// do.  See the .ai_seqfor note in sv_ai_defs.qc for the measured collisions.
//
// Reported as "it plays the submachinegun grenade animation and not the grenade
// animation", which is exactly right: hgrunt.mdl tags BOTH "throwgrenade" (the
// overhand toss, code 7 at 1.20 s) and "launchgrenade" (the underbarrel M203 shot,
// code 8 at 0.53 s) as act 29.  Two others were hiding behind the same bug and are
// fixed by the same table - a grunt carrying an MP5 played the shotgun crouch-fire
// pose half the time, and "standing_mp5"/"standing_shotgun" carry act=0 w=0, i.e.
// no activity tag at all, so EVERY grunt in this mod has fired from a crouch since
// the day the AI landed.
//
// HL_LIMP_HEALTH is hgrunt.cpp:55.
const float GRU_LIMP_HEALTH = 20;

string(entity m, float act) Grunt_SeqFor =
{
	if (act == ACT_RANGE_ATTACK2)
	{
		// hgrunt.cpp:1901-1915.  The behaviour half of this decision was already
		// loadout-driven (see Grunt_Event); this is the half that was still a coin
		// flip, and the two openly disagreed - he mimed an M203 shot and a hand
		// grenade came out.
		if (m.weapons & HGRUNT_HANDGRENADE)
		{
			ai_dbg_gren_throw = ai_dbg_gren_throw + 1;
			return "throwgrenade";
		}
		ai_dbg_gren_launch = ai_dbg_gren_launch + 1;
		return "launchgrenade";
	}

	if (act == ACT_RANGE_ATTACK1)
	{
		// hgrunt.cpp:1873-1900.  m_fStanding flips on a 1-in-10 roll each time HL
		// selects SCHED_RANGE_ATTACK1 (hgrunt.cpp:2284-2286) and starts FALSE, so an
		// HL grunt mostly crouches and occasionally stands.  Rolled here instead of
		// in the selector because AI_SetActivity is idempotent on the activity - the
		// hook runs once per transition INTO the attack, which is the same cadence.
		if (random() < 0.1)
			m.ai_standing = (random() < 0.5);

		if (m.weapons & HGRUNT_SHOTGUN)
			return m.ai_standing ? "standing_shotgun" : "crouching_shotgun";
		return m.ai_standing ? "standing_mp5" : "crouching_mp5";
	}

	// hgrunt.cpp:1916-1936.  HL routes these through LookupActivity(ACT_*_HURT)
	// rather than by name; the names are used here because this hook trades in
	// names, and limpingwalk/limpingrun are the only sequences carrying those two
	// tags on every rig in the family.  hwgrunt and the talkers have neither, so
	// they fall through - which is correct, not a gap.
	if (act == ACT_WALK && m.health <= GRU_LIMP_HEALTH)	return "limpingwalk";
	if (act == ACT_RUN  && m.health <= GRU_LIMP_HEALTH)	return "limpingrun";

	return "";
};

// The HW grunt is the same bug wearing different sequence names, and it is the
// other half of "the HW grunt doesn't make correct noises and plays smg firing
// sound sometimes": hwgrunt.mdl tags "attack" (the minigun, fifteen 5001 muzzle
// events over 0.58 s), "pistol_shoot" and "pistol_crouchshoot" ALL as act 28, so
// two times in three the minigun gunner played a pistol animation - and since the
// SOUND is chosen by which event code arrives, he made a pistol's noise while
// holding a minigun.  Fixing the pose fixes the audio, because in this rig they
// are the same decision.
//
// Its walk and run collide the same way (act 3: creeping_walk / pistol_walk;
// act 4: run / pistol_run), so a minigun gunner walked with a pistol gait half
// the time.
//
// Which of the two he is holding is a BODYGROUP, read out of hwgrunt.mdl rather
// than assumed: its "weapons" group is five submodels at base 1 -
//   0 weapon_minigun   1 weapon_beretta   2 weapon_deagle   3 weapon_python
//   4 blank
// so anything that is not 0 is a sidearm and 4 is the dropped state.  This rig was
// missing from Grunt_BodyInit entirely, which also meant his death sequences -
// all three raise code 11, DROP_GUN - had no blank submodel to switch to, so every
// HW grunt corpse kept its minigun welded on.
const float HWG_BODY_MINIGUN = 0;
const float HWG_BODY_BLANK   = 4;

string(entity m, float act) HWGrunt_SeqFor =
{
	float haspistol = (m.body != HWG_BODY_MINIGUN);

	if (act == ACT_RANGE_ATTACK1)
		return haspistol ? "pistol_shoot" : "attack";
	if (act == ACT_WALK)
		return haspistol ? "pistol_walk" : "creeping_walk";
	if (act == ACT_RUN)
		return haspistol ? "pistol_run" : "run";
	// "pistol_idle" carries act=0 w=0, i.e. no tag at all, so it is unreachable
	// without a name.  The minigun idle IS tagged (idle w3 / idle2 w1) and the
	// weighted pick between those two is wanted, so that case returns "" and lets
	// the ordinary path run.
	if (act == ACT_IDLE || act == ACT_IDLE_ANGRY)
		return haspistol ? "pistol_idle" : "";
	return "";
};

// near-identical blocks that drift apart.
void(entity m) Grunt_CommonInit =
{
	m.ai_yawspeed = Grunt_YawSpeed;
	m.ai_seqfor   = Grunt_SeqFor;

	m.ai_melee_range = GRU_MELEE_REACH;
	m.ai_range_range = GRU_RANGE;
	m.ai_spread      = GRU_SPREAD;

	// MEASURED OUT OF hgrunt.mdl, not chosen.  Half-Life does not carry monster
	// speeds as constants at all: GetSequenceInfo (animation.cpp:245-249) derives
	// m_flGroundSpeed from the sequence's own baked linearmovement,
	//     speed = |linearmovement| * fps / (numframes - 1)
	// so the gait and the travel rate cannot disagree - the animation IS the
	// speed.  Hand-typed numbers are what produced "they run their run animation
	// at a walking pace": every run in this mod was set at roughly half its real
	// value, and the feet slid to make up the difference.
	//   hgrunt.mdl [0] walk1  85f @30fps -> 40.1
	//   hgrunt.mdl [1] run    18f @30fps -> 304.0
	m.ai_speed_walk = 40;
	m.ai_speed_run  = 304;
	m.ai_yaw_speed  = 150;

	m.ai_attackrate  = GRU_ATTACK_DELAY;
	m.ai_dropweapon  = Grunt_DropWeapon;
	m.ai_checkattack = Grunt_CheckAttack;
	m.ai_event       = Grunt_Event;
	m.ai_painsound   = Grunt_PainSound;
	m.ai_death       = Grunt_Death;
	m.ai_tick        = Grunt_Aim;	// the spine controller tracks the enemy

	if (m.bloodcolor <= 0)
		m.bloodcolor = 247;		// HL BLOOD_COLOR_RED
};

// Only the hgrunt-rigged classes get this.  barney.mdl and scientist.mdl have no
// act 29 and no act 60, so wiring the grenade to them would fall through the
// activity chain to sequence 0 and produce a barney standing in an idle pose
// while a grenade materialised out of his chest.  That is precisely the failure
// his melee range had, and the fix is the same: do not offer a class an activity
// its model cannot play.
void(entity m) Grunt_GrenadeInit =
{
	m.ai_selectsched = Grunt_SelectSched;

	// HL's default loadout when the map sets no `weapons` key.
	if (!m.weapons)
		m.weapons = HGRUNT_9MMAR | HGRUNT_HANDGRENADE;

	float n = cvar("sv_ai_grunt_grenades");
	if (n <= 0)
		n = 3;
	m.ai_grenleft = n;
};

void(entity m) HGrunt_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	m.ai_class = CLASS_HUMAN_MILITARY;
};

void(entity m) HGruntAlly_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	// The faction matrix lands with the ally work; until then the classification
	// is stored so nothing has to be re-derived later.
	m.ai_class       = CLASS_PLAYER_ALLY;
	m.is_player_ally = TRUE;
};

void(entity m) HWGrunt_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	m.ai_class      = CLASS_HUMAN_MILITARY;
	// Sven's own class, so there is no SDK sequence to measure against - he wears
	// the hgrunt rig.  Kept DELIBERATELY below the measured hgrunt figures at
	// roughly the same ratio he already had (0.8 walk, 0.6 run): a heavy weapons
	// carrier who is slower than the line troops is the whole point of him, and
	// that is a design choice rather than a measurement.
	m.ai_speed_walk = 32;
	m.ai_speed_run  = 185;
	m.ai_spread     = GRU_SPREAD_WIDE;
	// AFTER CommonInit, which installed the hgrunt table.  This rig shares none of
	// those sequence names - see HWGrunt_SeqFor.
	m.ai_seqfor     = HWGrunt_SeqFor;
};

void(entity m) Assassin_ClassInit =
{
	Grunt_CommonInit(m);
	// MUST come after CommonInit, which points ai_event at Grunt_Event.  That
	// inheritance is exactly what stopped her firing for 504 placements.
	//
	// This is the hassassin.mdl init.  monster_male_assassin ALSO lands here and
	// wears a different rig entirely; Grunt_RigOverride at the bottom of this file
	// puts him back on Grunt_Event once the model is known.
	m.ai_event      = Assassin_Event;
	m.ai_dropweapon = Barney_DropWeapon;	// hassassin.cpp fires a 9mm pistol
	m.ai_class      = CLASS_HUMAN_MILITARY;

	// NO MELEE, for the same reason Barney has none, and measured out of the model
	// rather than assumed: hassassin.mdl's kick (seq 7, act 30) and kickshort
	// (seq 8, act 31) carry ZERO animation events, so no handler can ever make
	// them hurt anybody.  Half-Life does not use them either - CHAssassin maps
	// SCHED_MELEE_ATTACK1 to her JUMP (hassassin.cpp:988-1002), not to a kick.
	//
	// Leaving the grunt's 70-unit melee range on her was not merely cosmetic:
	// AI_SelectSchedule prefers melee over range unconditionally, and
	// Grunt_CheckAttack strips COND_CAN_RANGE1 inside melee reach, so at the range
	// players actually fight her she could ONLY pick an attack that does nothing,
	// and was forbidden from using the pistol that works.  That is the reported
	// "her kick and shooting don't hit me" in one line.
	//
	// Grunt_RigOverride restores the melee range for the male assassin, whose rig
	// does have a working kick.
	m.ai_melee_range = 0;
	//   hassassin.mdl [4] walk 82f @35fps -> 47.9
	//   hassassin.mdl [3] run  21f @40fps -> 483.4  (the fastest thing in HL)
	m.ai_speed_walk = 48;
	m.ai_speed_run  = 483;
	m.ai_yaw_speed  = 240;
	m.ai_yawspeed   = Assassin_YawSpeed;
};

// ---------------------------------------------------------------------------
// monster_shocktrooper  —  208 placements
// ---------------------------------------------------------------------------
// strooper.mdl is the HGRUNT RIG.  Dumped from the file rather than guessed, and
// this is why it keeps Grunt_Event rather than getting a handler of its own:
//
//   [13] frontkick     act=30  3@0.47 3@0.83  +2010 +1011"shock_trooper_attack"
//   [16] crouching_mp5 act=28  4@0.07                 <- ONE burst code, not three
//   [17] standing_mp5  act=0                          <- untagged, unreachable
//   [18] reload_mp5    act=32  2@2.00
//   [ 9] throwgrenade  act=29  7@1.33
//   [22] drop_grenade  act=60  9@0.03
//   [27..32] deaths            11@..  2001@..  +1011"shock_trooper_die1..4"
//
// Every one of those codes is already in Grunt_Event's vocabulary.  What was
// actually wrong was two things elsewhere: the cooldown was armed on BURST3, which
// this rig never raises (so it re-selected its attack forever and stood there
// cycling the animation), and its entire voice sits on event 1011, which nothing
// handled and nothing precached.  Both are fixed centrally now.
//
// What is genuinely its own is the WEAPON.  It carries a shock rifle, not an MP5.
void(entity m) Shocktrooper_GunSound =
{
	if (m.gag)
		return;
	sound(m, CHAN_WEAPON, SND_SHOCK_FIRE, 1, ATTN_NORM);
};

void(entity m) Shocktrooper_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	m.ai_class = CLASS_ALIEN_MILITARY;
	m.ai_gunsound = Shocktrooper_GunSound;
	// No drop.  Grunt_CommonInit installed the MP5 drop and this monster does not
	// carry one - in Opposing Force it drops a SHOCKROACH, which is a live weapon
	// this mod has no pickup for.  Dropping nothing is honest; dropping an MP5
	// because it shares the hgrunt rig would not be.
	m.ai_dropweapon = __NULL__;
	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;		// alien, not human
};

void(entity m) Robogrunt_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	m.ai_class = CLASS_MACHINE;
	m.bloodcolor = -1;			// DONT_BLEED: it is a robot
};

void(entity m) Barney_ClassInit =
{
	Grunt_CommonInit(m);
	m.ai_class       = CLASS_PLAYER_ALLY;
	m.is_player_ally = TRUE;

	// NO MELEE.  barney.mdl has no act 30 whatsoever - its whole vocabulary is
	// shootgun (28), reload (32), draw (33), holster (34).  Inheriting the grunt's
	// melee range meant SCHED_MELEE_ATTACK1 fell through the activity fallback to
	// sequence 0 and he stood there playing an IDLE pose while "attacking":
	// measured as 9 melee selections and a single landed hit in 50 seconds.
	// The hgrunt keeps its melee because it genuinely has a frontkick.
	m.ai_melee_range = 0;

	// CTalkMonster.  "BA" is the sentences.txt prefix: BA_IDLE (11 lines),
	// BA_HELLO (7), BA_ANSWER (22)... plus the pre-disaster "P" variants the talk
	// layer prefers when spawnflag 256 is set.  Barney and otis share the rig, the
	// voice set and the group, which is why they share this init.
	AI_MakeTalker(m, "BA");

	m.ai_event       = Barney_Event;	// one round per shot, on code 3
	m.ai_dropweapon  = Barney_DropWeapon;	// barney.cpp:623, weapon_9mmhandgun
	m.ai_painsound   = Barney_PainSound;
	m.ai_death       = Barney_Death;
	m.ai_yawspeed    = Barney_YawSpeed;	// barney.cpp:285-307, replaces the grunt's
	//   barney.mdl [4] walk 32f @30fps ->  61.4
	//   barney.mdl [5] run  16f @25fps -> 362.4
	// He was on 160, so he covered ground at 44% of what his own run cycle
	// describes.  That gap is the reported symptom in one number.
	m.ai_speed_walk  = 61;
	m.ai_speed_run   = 362;
};

// ---------------------------------------------------------------------------
// monster_hwgrunt  —  94 placements, and it has never fired a shot either
// ---------------------------------------------------------------------------
// Found by sv_ai_animtest rather than by reading code, which is the whole reason
// that self-test exists: it reported hwgrunt raising codes 1, 2, 11 and 12 - not
// one of which is a Grunt_Event firing code - and the dump explained why.
//
// hwgrunt.mdl (Sven Co-op's, 23 sequences) carries TWO act-28 sequences and
// frameforaction picks between them at random:
//
//   [ 6] attack              act=28   FIFTEEN 5001 muzzleflashes at 0.04 s apart
//                                     and NO low-code event at all  <- the minigun
//   [19] pistol_shoot        act=28   1@0.00s                       <- the pistol
//   [21] pistol_reload       act=32   2@0.89s
//
// So half the time it played a minigun animation that raised nothing this handler
// knew, and the other half a pistol whose code 1 is not in the hgrunt vocabulary
// either.  Either way: no bullets.
//
// The minigun's rate of fire IS its muzzleflash list - fifteen rounds in 0.6 s is
// what a minigun sounds like - so 5001 is the firing event for this rig, and that
// is exactly why this cannot live in Grunt_Event: hgrunt.mdl and massn.mdl raise
// 5001 as well, three per burst, ALONGSIDE codes 4/5/6.  Sharing a handler would
// double every grunt's output.  One rig, one handler.
void() HWGrunt_Event =
{
	float dmg = cvar("sv_ai_grunt_dmg");
	if (dmg <= 0)
		dmg = 8;

	// The minigun: one round per muzzle flash.
	if (ai_event_code == EVENT_MUZZLEFLASH)
	{
		ai_dbg_shots_grunt = ai_dbg_shots_grunt + 1;
		// A minigun round is individually weaker than a rifle round; the volume is
		// the threat.  Half of the grunt's per-shot damage over five times the rate
		// is a large net increase and is the point of the class.
		Grunt_FireOne(self, 1, dmg * 0.5, GRU_SPREAD_WIDE);
		HWGrunt_GunSound(self);
		return;
	}

	// The pistol variant of the same activity.  weapon_beretta in the bodygroup, so
	// Barney's 9 mm report - NOT Grunt_FireSound, which resolves to the MP5 burst
	// and was the audible half of this class playing the wrong animation.
	if (ai_event_code == 1)
	{
		ai_dbg_shots_grunt = ai_dbg_shots_grunt + 1;
		Grunt_FireOne(self, 1, dmg, GRU_SPREAD_PISTOL);
		Barney_GunSound(self);
		return;
	}

	if (ai_event_code == GRU_AE_RELOAD)
		return;			// animation only, as on every other rig here
};

// ---------------------------------------------------------------------------
// dropped weapons
// ---------------------------------------------------------------------------
// barney.cpp:612-628 and hgrunt.cpp:287-303 / :849-872.  The pickup classes are
// the mod's own (compiled far earlier than this file), not the GoldSrc aliases in
// sv_goldsrc_pickups.qc, which compile later and are only name forwarders anyway.
//
// The spawn functions build a complete pickup from whatever entity `self` is, so
// dropping one is a spawn(), a position and a call.  MOVETYPE_TOSS - which each of
// them sets - does the falling.
void(entity m, void() spawnfunc) Grunt_DropOne =
{
	entity oldself = self;
	entity w = spawn();

	// Out of the chest and slightly forward, then let it fall.  HL reads a real
	// attachment off the model for this; ours would need the attachment plumbing,
	// and a hand-height offset is close enough for something that immediately
	// drops to the floor.
	makevectors('0 1 0' * m.angles_y);
	setorigin(w, m.origin + v_forward * 16 + '0 0 36');
	w.angles   = [0, m.angles_y, 0];
	w.velocity = v_forward * (40 + random() * 40) + '0 0 100';
	w.avelocity = '0 200 0';

	self = w;
	spawnfunc();
	self = oldself;

	// Take it out of the corpse's hand at the same moment, rather than relying on
	// the death sequence to raise DROP_GUN.  Most hgrunt-family deaths do raise
	// it, but barney.mdl's do not, and a barney whose glock is lying on the floor
	// AND still welded to his fist is worse than either alone.
	m.body = m.ai_body_gone;
};

void(entity m) Grunt_DropWeapon =
{
	// A robot leaves no gun, for the same reason it leaves no gibs: its weapon is
	// part of it.  bloodcolor < 0 is the existing DONT_BLEED marker and is exactly
	// the same question.
	if (m.bloodcolor < 0)
		return;

	if (m.weapons & HGRUNT_SHOTGUN)
		Grunt_DropOne(m, weapon_hlshotgun);
	else
		Grunt_DropOne(m, weapon_hlsmg);
};

void(entity m) Barney_DropWeapon =
{
	Grunt_DropOne(m, weapon_hlglock);
};

// ---------------------------------------------------------------------------
// bodygroups
// ---------------------------------------------------------------------------
// THE GUN IN THE HAND.  Every value below is read out of the model's bodyparts
// lump, not invented, and the arithmetic is GoldSrc's own:
//
//     choice_for_part = (body / part->base) % part->nummodels
//
// so ONE integer selects every part at once and the multipliers are what decide
// how to compose them.
//
//   barney.mdl    gun    n=3 base=1 : [0] holstered  [1] drawn  [2] blank
//   otis.mdl      gun    n=3 base=1 : [0] holstered  [1] drawn  [2] donut(!)
//                 heads  n=2 base=3
//   hgrunt.mdl    heads  n=4 base=1 : grunt / commander / shotgun / m203
//                 weapon n=3 base=4 : [0] MP5  [1] shotgun  [2] blank
//   hgrunt_torch  weapon n=3 base=1 : [0] deagle  [1] torch  [2] holstered
//   hgrunt_medic  heads  n=2 base=1
//                 weapon n=4 base=2 : [0] deagle [1] glock [2] needle [3] hlstr
//   hgrunt_opfor  heads  n=8 base=1, torso n=4 base=8
//                 weapon n=4 base=32: [0] MP5 [1] shotgun [2] SAW [3] blank
//
// barney.mdl SPAWNS AT 0, which is holstered, and that is the whole reason his
// pistol was never in his hand: nothing ever changed .body, so every barney in
// the game stood there patting an empty holster while firing.  hgrunt.mdl's
// default happens to be the MP5, which is why grunts looked right and he did not
// - the same bug, invisible on one model and glaring on the other.
//
// Otis has no "blank" gun submodel, so his dropped state is the holster: he has
// put it away rather than had it vanish, which is the closest the rig allows.
void(entity m) Grunt_BodyInit =
{
	string mdl = m.model;

	if (mdl == "models/barney.mdl" || mdl == "models/bodyguard.mdl")
	{
		m.ai_body_holster = 0;
		m.ai_body_armed   = 1;
		m.ai_body_gone    = 2;
	}
	else if (mdl == "models/otis.mdl")
	{
		m.ai_body_holster = 0;
		m.ai_body_armed   = 1;
		m.ai_body_gone    = 0;		// no blank submodel on this rig
	}
	else if (mdl == "models/hgrunt.mdl")
	{
		// hgrunt.mdl: heads n=4 base=1, weapons n=3 base=4, so
		// body = head*1 + weapon*4 with weapon 0=MP5 1=shotgun 2=blank.
		//
		// Head first so the weapon multiplier lands on top of it.  A shotgun
		// grunt gets the shotgun head, which is HL's own pairing and the reason
		// that head exists.
		float head = (m.weapons & HGRUNT_SHOTGUN) ? 2 : 0;
		m.ai_body_armed   = head + ((m.weapons & HGRUNT_SHOTGUN) ? 4 : 0);
		m.ai_body_holster = m.ai_body_armed;	// no holstered pose on this rig
		m.ai_body_gone    = head + 8;
	}
	else if (mdl == "models/massn.mdl")
	{
		// SPLIT OUT OF THE HGRUNT BRANCH, because the bases are not the same and
		// sharing them produced values that are not indices at all.  Dumped:
		//   massn.mdl   heads n=3 base=1, weapons n=3 base=3
		//               weapon 0=Massn_MP5 1=Massn_M40A1 2=blank
		// so body = head*1 + weapon*3.  The hgrunt formula multiplied by 4 and
		// dropped to +8, which on this rig asks for weapon 8/3 - the engine floors
		// the division, so "gone" landed on the M40A1 and a disarmed corpse was
		// handed a sniper rifle.
		//
		// No shotgun submodel on this rig at all; the second weapon is the M40A1,
		// which is a different loadout and not yet modelled (see the TESTING.md
		// note).  Until it is, he carries the MP5 he already visibly carries.
		float mhead = 0;
		m.ai_body_armed   = mhead + 0 * 3;	// MP5
		m.ai_body_holster = m.ai_body_armed;
		m.ai_body_gone    = mhead + 2 * 3;	// blank
	}
	else if (mdl == "models/hgrunt_torch.mdl")
	{
		m.ai_body_armed   = 0;		// Desert Eagle
		m.ai_body_holster = 2;
		m.ai_body_gone    = 2;
	}
	else if (mdl == "models/hgrunt_medic.mdl")
	{
		m.ai_body_armed   = 0;		// Desert Eagle, head 0
		m.ai_body_holster = 6;		// weapon slot 3 (holster) * base 2
		m.ai_body_gone    = 6;
	}
	else if (mdl == "models/hwgrunt.mdl")
	{
		// weapons group, base 1: minigun / beretta / deagle / python / blank.
		m.ai_body_armed   = HWG_BODY_MINIGUN;
		m.ai_body_holster = HWG_BODY_MINIGUN;	// no holstered pose on this rig
		m.ai_body_gone    = HWG_BODY_BLANK;
	}
	else if (mdl == "models/hgrunt_opfor.mdl")
	{
		float wep = 0;					// MP5
		if (m.weapons & HGRUNT_SHOTGUN)
			wep = 1;
		m.ai_body_armed   = wep * 32;
		m.ai_body_holster = m.ai_body_armed;
		m.ai_body_gone    = 3 * 32;		// the blank weapon submodel
	}
	else
		return;				// rig has no weapon bodygroup; leave .body alone

	// Armed on spawn.  Half-Life holsters its talkers until they go alert and
	// draws on BAR_AE_DRAW, and that beat is honoured in Barney_Event - but the
	// initial state has to be something, and an armed guard is both what the
	// player expects and what every non-talker in the family wants anyway.
	m.body = m.ai_body_armed;
};

// ---------------------------------------------------------------------------
// the rig table
// ---------------------------------------------------------------------------
// EVENT CODES BELONG TO THE MODEL, NOT TO THE CLASSNAME, and keying the dispatch
// on the classname alone is what broke the male assassin.
//
// AI_ClassInit dispatches on m.classname, but the model is resolved separately by
// Monster_DefaultModel and can FALL BACK when a mount is missing:
//
//   monster_male_assassin -> massn.mdl    else hassassin.mdl   (sv_monsters.qc:390)
//   monster_shocktrooper  -> strooper.mdl else hgrunt.mdl      (:443)
//   monster_otis          -> otis.mdl     else barney.mdl      (:394)
//
// So one classname can arrive wearing either of two rigs with two different event
// vocabularies, and which one it is depends on what the player has installed.
// Dumped out of the shipped files:
//
//   massn.mdl      kick 3, burst 4/5/6, reload 2, toss 7, launch 8, drop 9,
//                  signal 10, dropgun 11        -- the HGRUNT vocabulary
//   hassassin.mdl  shoot 1, toss 2, jump 3      -- its own, and no kick events
//                  at all on its two kick sequences
//
// Assassin_ClassInit installs Assassin_Event for both classnames.  On any install
// with gearbox mounted - which this one has - the male assassin therefore got a
// handler that knows codes 1 and 2 for a rig that raises 3, 4, 5 and 6: his kick
// and every round of his burst fell off the end of the dispatch, and his RELOAD
// (code 2) was read as a grenade toss, which set a six-second attack lockout every
// time he reloaded.  419 placements that could not hurt anybody.
//
// This runs at the END of AI_ClassInit, after the model is known, and overrides
// whatever the class init installed.  It is deliberately keyed on the model rather
// than on "did the fallback happen", because a map is free to set its own model
// key on any monster and the same reasoning applies.
void(entity m) Grunt_RigOverride =
{
	string mdl = m.model;

	if (mdl == "models/massn.mdl")
	{
		// The hgrunt rig, so the hgrunt handler - and the kick range it took away
		// from the female, because THIS model's frontkick does raise code 3.
		m.ai_event       = Grunt_Event;
		m.ai_dropweapon  = Grunt_DropWeapon;	// an MP5, not the female's pistol
		m.ai_melee_range = GRU_MELEE_REACH;
		m.ai_painsound   = Grunt_PainSound;
		m.ai_death       = Grunt_Death;
		return;
	}

	if (mdl == "models/hwgrunt.mdl")
	{
		// Sven's heavy weapons grunt: a minigun that fires on 5001 and a pistol
		// that fires on code 1, neither of which the hgrunt handler knows.
		m.ai_event       = HWGrunt_Event;
		m.ai_melee_range = 0;		// no frontkick on this rig
		return;
	}

	if (mdl == "models/hassassin.mdl")
	{
		// Reached by monster_human_assassin normally, and by monster_male_assassin
		// on an install with no gearbox mount.  Her kick sequences carry no events,
		// so she must never be offered a melee schedule.
		m.ai_event       = Assassin_Event;
		m.ai_melee_range = 0;
		return;
	}

	// --- the Opposing Force specialists ------------------------------------
	//
	// THE WEAPON IS A PROPERTY OF THE MODEL, and the model says so out loud.
	// Dumped from the bodyparts lump rather than inferred from the classname or
	// from the sequence names, both of which lie here:
	//
	//   hgrunt_torch.mdl  weapons n=3 : Desert_Eagle, engineer_torch,
	//                                   engineer_gunholster
	//   hgrunt_medic.mdl  weapons n=4 : Desert_Eagle, glock, hypodermic,
	//                                   engineer_gunholster
	//   hgrunt_opfor.mdl  weapons n=4 : MP5, shotgun, SAW, blank
	//
	// The torch and the medic hold a DESERT EAGLE.  Their firing sequences are
	// still named "crouching_mp5" - inherited animation names from the shared
	// rig - and taking that name at face value is why a torch ally has been
	// making an MP5 noise while visibly holding a hand cannon.  The sequence
	// names lie; the bodygroup does not.
	//
	// It is not only the sound.  Both rigs raise ONE burst code (4) where the
	// MP5 rigs raise three, because one trigger pull is one round: they were
	// also getting the grunt's 5-degree burst cone instead of a handgun's aimed
	// 2 degrees, and were being handed a grenade loadout they have no sequence
	// for.
	if (mdl == "models/hgrunt_torch.mdl" || mdl == "models/hgrunt_medic.mdl")
	{
		// THE MEDIC HAD NEVER FIRED A SHOT, and this is where that is fixed.
		// monster_human_medic_ally runs Barney_ClassInit (sv_ai_core.qc:2022),
		// which installs Barney_Event - a handler whose only shoot code is 3.
		// hgrunt_medic.mdl fires on 4.  Same shape as the male assassin and the
		// shocktrooper, and found the same way: by diffing the codes the model
		// raises against the codes its handler consumes.
		m.ai_event      = Grunt_Event;		// hgrunt vocabulary, verified above
		m.ai_gunsound   = Grunt_DeagleSound;
		m.ai_spread     = GRU_SPREAD_PISTOL;
		m.ai_dropweapon = Barney_DropWeapon;	// a pistol, not an MP5

		// ...and the kick that comes with the rig.  Barney_ClassInit zeroes the
		// melee range because barney.mdl genuinely has no act 30; BOTH of these
		// models do have one, and its frontkick raises code 3, which Grunt_Event
		// consumes.  Same test as always: offer the range only when the model's
		// melee sequence carries a code the handler answers.
		m.ai_melee_range = GRU_MELEE_REACH;
		m.weapons       = m.weapons - (m.weapons & (HGRUNT_9MMAR | HGRUNT_SHOTGUN));
		// No grenade: neither model has a throwgrenade sequence bound to an
		// activity the ladder can reach, and offering an activity a model cannot
		// play is the exact failure the female assassin's kick was.
		m.weapons       = m.weapons - (m.weapons & (HGRUNT_HANDGRENADE | HGRUNT_GRENADELAUNCHER));
		m.ai_grenleft   = 0;
		return;
	}

	if (mdl == "models/hgrunt_opfor.mdl")
	{
		// The OpFor line grunt.  Same three weapons the base hgrunt has plus the
		// SAW, whose firing sequence raises SEVEN burst codes (4 5 5 5 5 5 6)
		// against the MP5's three - a squad-support weapon that really does put
		// twice the rounds downrange per animation, for free, because the codes
		// are already in Grunt_Event's vocabulary.
		m.ai_event = Grunt_Event;
		if (m.weapons & HGRUNT_SHOTGUN)
			m.ai_spread = GRU_SPREAD_SHOTGUN;
		return;
	}
};

// ---------------------------------------------------------------------------
// scientist  —  271 placements
// ---------------------------------------------------------------------------
// The class the fear path in AI_SelectSchedule exists for.  A scientist has no
// attack of any kind: both ranges stay 0 so the generic ladder can never offer it
// an attack schedule, and the faction matrix returns R_FEAR for everything
// hostile, which routes it into SCHED_FLEE_ENEMY - the schedule built for the
// cockroach back in W2 and now shared.
//
// scientist.mdl carries 129 sequences, almost all of them for scripted set-pieces
// that W8 consumes.  Nothing here touches those: this is the ambient behaviour
// only, so a map's own scripted_sequences will drive the same body later without
// having to undo anything.
void(entity m) Scientist_ClassInit =
{
	m.ai_class       = CLASS_HUMAN_PASSIVE;
	m.is_player_ally = TRUE;

	m.ai_melee_range = 0;
	m.ai_range_range = 0;

	//   scientist.mdl [0] walk 17f @20fps ->  58.7
	//   scientist.mdl [2] run  19f @25fps -> 275.4
	// scientist.mdl also carries run1/run2 tagged ACT_RUN_SCARED at 315.5, which
	// is why a fleeing scientist outruns a walking one so visibly in Half-Life.
	m.ai_speed_walk = 59;
	m.ai_speed_run  = 275;
	m.ai_yaw_speed  = 160;
	m.ai_yawspeed   = Scientist_YawSpeed;

	// CTalkMonster.  "SC" reaches SC_IDLE (14), SC_HELLO (9), SC_QUESTION (27),
	// SC_ANSWER (30) and the SC_P* pre-disaster set (SC_PIDLE 11, SC_PHELLO 7)
	// which is what nearly every scientist in hl_c01_a1 actually uses.
	AI_MakeTalker(m, "SC");

	// scientist.cpp:771-778: the first round from a player provokes him outright,
	// with none of Barney's escalation.  See AI_TalkDamaged for why the two
	// classes genuinely differ rather than this being an inconsistency.
	m.ai_provoke_instant = TRUE;

	// Usable: HL scientists follow on +use.  The gate for this was added in B2
	// (monster_player_usable in sv_use.qc); the follow behaviour itself is still
	// to come, but marking them usable now means the +use path is exercised.
	m.monster_player_usable = TRUE;

	if (m.bloodcolor <= 0)
		m.bloodcolor = 247;
};

float() Scientist_DefaultHealth
	= { float h = cvar("sv_ai_scientist_health"); return (h > 0) ? h : 20; };

float() Grunt_DefaultHealth =
{
	float h = cvar("sv_ai_grunt_health");
	if (h <= 0)
		h = 50;				// HL sk_hgrunt_health
	return h;
};

float() Barney_DefaultHealth =
{
	float h = cvar("sv_ai_barney_health");
	if (h <= 0)
		h = 35;				// HL sk_barney_health
	return h;
};
