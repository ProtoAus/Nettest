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

// Per-RIG damage override; 0 means "use the class cvar".
//
// The rig-override hook already knows which models carry a Desert Eagle instead
// of the 9 mm or the MP5 - that is where the SOUND was fixed - and the damage is
// the other half of the same fact.  Sven prices sk_otis_bullet at 34 against
// Barney's 10, which is the difference between a hand cannon and a service
// pistol, and until now the model decided the noise and the classname decided
// the number.  Three rigs are affected: otis.mdl, hgrunt_torch.mdl and
// hgrunt_medic.mdl, all three of which visibly hold the same gun.
.float ai_shot_dmg;

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

// ---------------------------------------------------------------------------
// the two specialist loadouts
// ---------------------------------------------------------------------------
// Neither of these needs a firing loop, because the MODELS already carry one.
// Dumped from the studio headers rather than assumed:
//
//   crouching_m40a1 / standing_m40a1   act 28, 13 frames @ 15 fps = 0.867 s,
//                                      ONE event (f1:e4)
//   rpg_shoot                          act 28, 16 frames @ 30 fps = 0.533 s,
//                                      ONE event (f10:e4)
//
// against the MP5's 13 @ 20 fps carrying three (e4/e5/e6) on HL's rig.  So a
// sniper or rocket sequence raises BURST1 exactly once and the burst count is
// already right; all these constants have to supply is the ballistics.
//
// Pinpoint, matching the player M40A1's SNIPER_BASE_SPREAD = 0
// (sh_wpn_opsniperrifle.qc:65).  A sniper that sprays is not a sniper.
const float GRU_SPREAD_SNIPER = 0;

// The bolt cycle.  ai_attackrate is a FLOOR - AI_ArmAttackCooldown adds its
// distance term on top and never lowers a longer figure - so this is the minimum
// gap between shots, not the whole of it.  The player's M40A1 gates on its
// 1.733 s fire animation (SNIPER_FIRE_DELAY); a monster that has to reacquire
// between shots gets a little more.
const float GRU_SNIPER_REFIRE = 2.0;

// The rocket is slower still, and deliberately: it is the tree's full-strength
// RPG round, so the rate limit is what keeps an RPG grunt from being a delete
// button.  See Grunt_FireRocket.
const float GRU_RPG_REFIRE    = 4.0;

// Both specialists shoot further than the 1600 the family gets by default, and
// 2048 is where it stops mattering - sv_ai_sight bounds AI_CanSee, and
// COND_CAN_RANGE1 is only ever raised inside the branch that saw the enemy.
const float GRU_SPECIALIST_RANGE = 2048;

// Self-preservation on the rocket, the same figure and the same reason as
// GRU_GREN_MINRANGE below: RPG_EXPLOSION_RADIUS is 300 and he is standing in it.
const float GRU_RPG_MINRANGE  = 256;

// The shocktrooper's shock rifle.  Declared up here with the other constants
// because Grunt_Precache below names it and QC needs a constant declared before
// the line that reads it.
const string SND_SHOCK_FIRE = "weapons/shock_fire.wav";

// The Opposing Force engineer's sidearm, for the same reason: Grunt_Precache
// names it below.  The file lives in gearbox AND in svencoop, so it resolves on
// either mount; "de_shot1.wav" also exists in gearbox but is the player weapon's
// alternate, not the one the NPC uses.
const string SND_DEAGLE_FIRE = "weapons/desert_eagle_fire.wav";

// The M40A1, for the grunt-family rigs that carry a sniper submodel.  Precached
// globally already (sh_customdefs.qc:1690-1694, unconditionally, as part of the
// player weapon set) but named here too because that is this file's convention -
// every sound its handlers play appears in Grunt_Precache - and because fteqcc's
// F210 check only recognises a literal precache_sound(), not one reached through
// another file.
const string SND_SNIPER_FIRE = "weapons/sniper_fire.wav";

// Is Sven's friendly-grunt voice folder mounted?  Answered once in Grunt_Precache
// and read by HGruntAlly_ClassInit - a per-body whichpack() would be a filesystem
// query per spawn for a fact that cannot change during a map.
float grunt_ally_hasfgrunt;

void() Grunt_Precache =
{
	precache_model("models/hgrunt.mdl");
	precache_model("models/barney.mdl");
	precache_model("models/hassassin.mdl");

	precache_sound("weapons/sbarrel1.wav");
	precache_sound(SND_SNIPER_FIRE);
	precache_sound("weapons/pl_gun1.wav");		// hassassin.cpp:277-278
	precache_sound("weapons/pl_gun2.wav");
	precache_sound("hgrunt/gr_pain1.wav");
	precache_sound("hgrunt/gr_pain2.wav");
	precache_sound("hgrunt/gr_pain3.wav");
	precache_sound("hgrunt/gr_die1.wav");
	precache_sound("hgrunt/gr_die2.wav");
	precache_sound("hgrunt/gr_die3.wav");
	// The FRIENDLY grunt's own set, which is a different folder and not a copy:
	// Sven ships sound/fgrunt/ with 195 files, six pain lines and six deaths (note
	// "death%g", not "gr_die%g" - the friendly rig renamed them).  Every grunt ally
	// in this mod was playing the enemy grunt's voice, which is wrong on its own
	// and is also what made pizza_ya_san1's soundlist a no-op: that map remaps
	// fgrunt/* and nothing here ever emitted an fgrunt path to be remapped.
	//
	// GUARDED, because fgrunt/ is Sven content and this mod also runs against a
	// valve-only mount.  Swapping the voice unconditionally would trade "an ally
	// grunt sounds like an enemy grunt" for "an ally grunt is silent", which is the
	// worse of the two; grunt_ally_hasfgrunt is what HGruntAlly_ClassInit tests.
	grunt_ally_hasfgrunt = Monster_SoundExists("fgrunt/death1.wav");
	float fg;
	if (grunt_ally_hasfgrunt)
		for (fg = 1; fg <= 6; fg = fg + 1)
		{
			precache_sound(sprintf("fgrunt/gr_pain%g.wav", fg));
			precache_sound(sprintf("fgrunt/death%g.wav",   fg));
		}
	// The scientist's, which nothing precached because nothing played them - see
	// Scientist_PainSound.
	for (fg = 1; fg <= 5; fg = fg + 1)
		precache_sound(sprintf("scientist/sci_pain%g.wav", fg));
	precache_sound("hgrunt/gr_mgun1.wav");		// the MP5 report; see Grunt_GunSound
	precache_sound("weapons/glauncher.wav");	// M203
	precache_sound("barney/ba_pain1.wav");
	precache_sound("barney/ba_pain2.wav");
	precache_sound("barney/ba_pain3.wav");
	precache_sound("barney/ba_die1.wav");
	precache_sound("barney/ba_die2.wav");
	precache_sound("barney/ba_die3.wav");
	// weapons/hks1-3.wav USED TO BE PRECACHED HERE, described as "the 9mm/shotgun
	// report ... the weapon sounds HL's grunts use".  They are not: hks1-3 are the
	// MINITURRET and SENTRY guns (turret.cpp:633-635, :1193-1195), no grunt in
	// Half-Life ever plays one, and no line in this file ever did either.  They now
	// live in mon_turret.qc beside the class that fires them.

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
// Sven's additions to the same field (sven-coop.fgd:5508).  SAW is annotated
// "human_grunt_ally only!" and NO_WEAPONS "male_assassin only!", which is exactly
// how pizza_ya_san1 uses them: the pizza shop owner is `weapons 16` and the
// employee uboa is `weapons 32`.  Both bits fell outside the mod's set, so a key
// that says "this NPC carries a machine gun" and a key that says "this NPC is
// unarmed" produced the same thing - an hgrunt loadout with no matching bit.
const float HGRUNT_SAW            = 16;
const float HGRUNT_NOWEAPONS      = 32;
// The rest of the grunt's own list, which had no constants at all - so a map
// saying "rocket launcher" or "sniper rifle" set a bit nothing tested, the
// loadout defaulted, and the NPC quietly carried an MP5 instead.  desertcircle
// has four squadmakers on `weapons 64`.
const float HGRUNT_RPG            = 64;
const float HGRUNT_SNIPER         = 128;
const float HGRUNT_NODROP         = 256;	// "Don't drop weapon (HWG etc)"

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
// the rocket, for `weapons 64`
// ---------------------------------------------------------------------------
// sven-coop.fgd:4339 and :5518 both spell bit 64 "Rocket Launcher", on
// monster_human_grunt and on squadmaker.  desertcircle has four squadmakers set
// to it and the bit had no reader at all, so those grunts quietly carried an MP5.
//
// THIS IS THE TREE'S OWN ROCKET, not a new projectile type: same entity as
// W_RPGFire (sh_wpn_hlrpg.qc:414) and TankRocket_Launch (sv_th_entities.qc:2074)
// build, down to reusing W_RPGRocketThink - whose laser-guidance branch is gated
// on self.owner.rpg_laser_active, which a monster never sets, so it falls through
// to the plain acceleration path exactly as it does for a brush-fired rocket.
//
// NOT calling TankRocket_Launch itself, for two independent reasons.  It compiles
// later than this file (sv_progs.src:317 against :272), and its explode handler
// does `atk = self.tankrocket_operator; if (atk.classname != "player") atk = world;`
// - which is right for a brush that would otherwise bill the kill to a func_tank,
// and wrong here, because it would strip a live monster attacker off the blast and
// with it every faction and friendly-fire decision W_CanDamageTarget makes.
void() Grunt_RocketExplode =
{
	entity atk;

	// Identical wire shape to TankRocket_RocketExplode (sv_th_entities.qc:2010)
	// and op4mortar_shell_explode.  17 bytes, fixed by cl_main.qc:1954 - the
	// element mask stays 0 so the full GoldSrc boom plays.
	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_EXPLOSION);
	WriteCoord(MSG_MULTICAST, self.origin_x);
	WriteCoord(MSG_MULTICAST, self.origin_y);
	WriteCoord(MSG_MULTICAST, self.origin_z + 8);
	WriteShort(MSG_MULTICAST, RPG_EXPLOSION_DAMAGE);
	WriteByte(MSG_MULTICAST, 0);
	multicast(self.origin, MULTICAST_PVS);

	// Kill the SOUNDFLAG_FOLLOW motor loop on the channel that owns it.
	sound(self, CHAN_VOICE, "sounds/null.wav", 1, ATTN_NORM);

	// The grunt keeps the credit while he is alive to hold it.  Shooting him out
	// from under his own rocket recycles the edict, so re-verify rather than
	// trust the reference - world is what an unattributed blast passes.
	atk = self.owner;
	if (!atk || wasfreed(atk) || atk.classname == "")
		atk = world;

	float d = cvar("sv_ai_rpg_dmg");
	if (d <= 0)
		d = RPG_EXPLOSION_DAMAGE;

	W_RadiusExplode(self.origin, RPG_EXPLOSION_RADIUS,
	                d, RPG_EXPLOSION_MIN_DAMAGE,
	                RPG_KNOCKBACK_PUSH, RPG_KNOCKBACK_UPLIFT, atk);

	remove(self);
};

void() Grunt_RocketTouch =
{
	if (other == self.owner)
		return;
	Grunt_RocketExplode();
};

void(entity m) Grunt_FireRocket =
{
	if (!m.ai_enemy)
		return;

	vector src = AI_MuzzlePos(m);
	// Zero spread: the launcher is aimed, and RPG_EXPLOSION_RADIUS is 300, so a
	// cone would only decide which side of the player it lands on.
	vector dir = AI_AimDir(m, src, m.ai_enemy, 0);

	entity rocket = spawn();
	// Owner is the grunt, which buys the touch pass-through AND the damage
	// credit in one - unlike the tank, whose owner has to be the brush.
	rocket.owner     = m;
	rocket.classname = "proj_rpg_rocket";
	rocket.movetype  = MOVETYPE_FLYMISSILE;
	rocket.solid     = SOLID_BBOX;
	setmodel(rocket, RPG_ROCKET_MODEL);
	setsize(rocket, '-2 -2 -2', '2 2 2');
	setorigin(rocket, src);
	rocket.velocity  = dir * RPG_INITIAL_SPEED;
	rocket.angles    = W_ModelAngles(rocket.velocity, TRUE);
	rocket.touch     = Grunt_RocketTouch;
	// projectile_SendEntity hides the rocket from its owner (sv_weapons.qc:2619)
	// by comparing against the receiving PLAYER, so a monster owner hides it from
	// nobody - every client sees it, which is what we want with no predicted fake.
	rocket.proj_type  = PROJ_TYPE_RPG_ROCKET;
	rocket.SendEntity = projectile_SendEntity;
	rocket.SendFlags  = 1;
	rocket.think      = W_RPGRocketThink;
	rocket.nextthink  = time + Toss_NextThinkInterval();

	sound(rocket, CHAN_VOICE, RPG_FLY_SOUND, 1, ATTN_NORM, 0, SOUNDFLAG_FOLLOW);
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
//
// NO `.gag` GATE HERE, OR IN ANY OF THE PAIN / DEATH / REPORT HANDLERS BELOW, AND
// PUTTING ONE BACK IS A BUG.  SF_MONSTER_GAG reaches exactly one function in the
// SDK - FOkToSpeak (hgrunt.cpp:331-345) - and gates SENTENCE SPEECH only; the gun
// report at hgrunt.cpp:913-937, PainSound at :1162 and DeathSound at :1204 have no
// gag test at all.  Thirteen such gates lived in this file and made every gagged
// monster fire, bleed and die in silence, which is what hl_c06 (9 of its 14 grunts
// carry the flag) was reporting as "place holders with no actual function".
// The speech path that DOES honour it is AI_SndSpeak (sv_ai_anim.qc) and the
// talk tick's own gate at sv_ai_talk.qc:372.
void(entity m) Grunt_GunSound =
{
	// The M40A1.  Above the shotgun test because Assassin_ClassInit translates
	// this class's bit 8 into HGRUNT_SNIPER and a grunt can carry both bits;
	// whichever gun is in his hands should be the one you hear.
	if (m.weapons & HGRUNT_SNIPER)
	{
		AI_Sound(m, CHAN_WEAPON, SND_SNIPER_FIRE, 1, ATTN_NORM);
		return;
	}

	// Shotgun grunts get the shotgun (hgrunt.cpp:933).  HGRUNT_SHOTGUN has been
	// declared since the class landed and nothing ever read it, which is why
	// weapons/sbarrel1.wav was precached and never once played.
	if (m.weapons & HGRUNT_SHOTGUN)
	{
		AI_Sound(m, CHAN_WEAPON, "weapons/sbarrel1.wav", 1, ATTN_NORM);
		return;
	}

	// Two samples, picked at random - hgrunt.cpp:918 is a straight RANDOM_LONG(0,1).
	// gr_mgun3.wav exists in the mount but HL's burst code never reaches it.
	if (random() < 0.5)
		AI_Sound(m, CHAN_WEAPON, "hgrunt/gr_mgun1.wav", 1, ATTN_NORM);
	else
		AI_Sound(m, CHAN_WEAPON, "hgrunt/gr_mgun2.wav", 1, ATTN_NORM);
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
	float shift = floor(random() * 21);
	if (shift > 10)
		shift = 0;
	else
		shift = shift - 5;

	AI_SoundEx(m, CHAN_WEAPON, SND_DEAGLE_FIRE, 1, ATTN_NORM, 100 + shift, 0);
};

// ...and what it does when it lands.  Named after the gun rather than after Otis
// because three rigs carry it; sk_otis_bullet is simply where Sven Co-op happens
// to keep the number (skill.cfg, "Otis" block).
float() Grunt_DeagleDamage =
{
	float d = cvar("sv_ai_otis_dmg");
	if (d <= 0)
		d = 34;
	return d;
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
	if (time < m.ai_nextburstsnd)
		return;
	m.ai_nextburstsnd = time + HWG_BURSTSND_GAP;

	float r = floor(random() * 3);
	if (r < 1)	AI_Sound(m, CHAN_WEAPON, "hassault/hw_shoot1.wav", 1, ATTN_NORM);
	else if (r < 2)	AI_Sound(m, CHAN_WEAPON, "hassault/hw_shoot2.wav", 1, ATTN_NORM);
	else		AI_Sound(m, CHAN_WEAPON, "hassault/hw_shoot3.wav", 1, ATTN_NORM);
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
	float shift = floor(random() * 21);	// RANDOM_LONG(0, 20)
	if (shift > 10)
		shift = 0;
	else
		shift = shift - 5;

	// The 6th argument of `sound` is speedpct (fteextensions.qc:1693), where 100
	// is unmodified - the same scale HL's EMIT_SOUND_DYN pitch argument uses, so
	// the value carries across unconverted.
	AI_SoundEx(m, CHAN_WEAPON, "barney/ba_attack2.wav", 1, ATTN_NORM, 100 + shift, 0);
};

// ---------------------------------------------------------------------------
// grenades
// ---------------------------------------------------------------------------
// The grenade's own .gravity, which sv_gravity is scaled by for the arc maths.
// It must match W_HLGrenadeSpawn or every throw lands somewhere else.
// How long an engagement must have been running before a grenade is on the
// table.  Stands in for Half-Life's bits_COND_NEW_ENEMY branch, which occupies
// the grunt with suppressing fire or cover for its first exchange - see the gate
// in Grunt_CheckGrenade.  Not a Valve constant: HL's equivalent is "until the
// NEW_ENEMY condition clears", which is one schedule, and two seconds is one
// schedule's worth of shooting.
const float GRU_GREN_OPENING  = 2;
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

	// NOT AS THE OPENING MOVE.  Reported as "their first reaction is always to
	// throw a grenade at you", and that is exactly what this file's own ladder
	// produced: Grunt_SelectSched runs ahead of the generic combat block, so the
	// throw was the first thing tested once the cover rolls declined.
	//
	// Half-Life cannot do that, structurally.  CHGrunt::GetSchedule tests
	// bits_COND_NEW_ENEMY BEFORE it ever reaches the grenade branch, and that
	// branch returns SCHED_TAKE_COVER_FROM_ENEMY for a non-leader or
	// SCHED_GRUNT_SUPPRESS / SCHED_GRUNT_ESTABLISH_LINE_OF_FIRE for the leader.
	// A grunt's first answer to seeing you is bullets or cover, never a grenade;
	// the grenade is what he does once the fight has settled.
	if (time < m.ai_enemy_since + GRU_GREN_OPENING)
	{
		Grunt_GrenVeto(m, "engagement just started - shoot first");
		return FALSE;
	}

	// STATIONARY ONLY - hgrunt.cpp:482-486, "if the grunt isn't moving, it's ok
	// to check", which is the SDK's way of saying a moving grunt never throws.
	// This gate was missing entirely, and without it a grunt lobs while walking,
	// which is both unlike HL and the reason throws felt constant rather than
	// occasional.
	if (vlen(m.velocity) > 8)
	{
		Grunt_GrenVeto(m, "moving - HL only throws from a standstill");
		return FALSE;
	}

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
//
// Ordered as hgrunt.cpp:2040-2175 orders it, which is not the order it would be
// written in from scratch: cover comes BEFORE the attacks.  A grunt that has just
// been hit gives up its turn to shoot and moves, and that single ordering choice
// is most of what separates Half-Life's grunts from a firing line.
float() Grunt_SelectSched =
{
	entity m = self;
	if (m.ai_state != MS_COMBAT || !m.ai_enemy)
		return SCHED_NONE;

	// PINNED.  hgrunt.cpp:1571 is the only place in the SDK that reaches
	// SCHED_COWER - the fail schedule of take-cover-from-best-sound, commented
	// "duck and cover if cannot move from explosion".  This mod has no danger
	// sounds, so that exact trigger does not exist; what is kept is the intent,
	// and it is also the first thing in the tree ever to READ COND_BLOCKED, which
	// has been raised at sv_ai_core.qc's movement failure since the AI landed and
	// tested by nothing at all.
	//
	// Being hit is part of the condition on purpose.  A grunt merely wedged on a
	// doorframe should keep trying to walk, not fold up; a grunt wedged on a
	// doorframe while under fire has run out of options, which is what the
	// animation depicts.
	if (m.ai_cond & COND_BLOCKED)
		if (m.ai_cond & COND_DAMAGE)
			if (AI_HasActivity(m, ACT_COWER))
			{
				ai_dbg_cover_cower = ai_dbg_cover_cower + 1;
				return SCHED_COWER;
			}

	// NO SLOT TO SHOOT FROM.
	//
	// hgrunt.cpp's MONSTERSTATE_COMBAT ladder ends in "if I cannot occupy an
	// attack slot, take cover / establish a line of fire" - and that single rule
	// is most of what makes a GoldSrc grunt squad look alive.  Without it the
	// rationing this mod already has produces the opposite of the intended
	// effect: one grunt fires and the other three stand in the open holding a
	// rifle they are not allowed to use.
	//
	// ABOVE the friend-damaged trigger because it is the commoner case by far and
	// costs nothing when a slot is available - Squad_SlotsFree is a loop over two
	// bits, and everything expensive is behind it.
	{
		float crowded = Cover_ScheduleIfCrowded(m);
		if (crowded != SCHED_NONE)
			return crowded;
	}

	// A SQUADMATE IS BEING SHOT AT.
	//
	// Stated plainly as a stand-in rather than a port: Half-Life's trigger here is
	// bits_COND_NEW_ENEMY on a squad member that is not the leader
	// (hgrunt.cpp:2048-2056), and this mod has no COND_NEW_ENEMY.  What it does
	// have is COND_FRIEND_DAMAGED, which the squad work raised for the first time
	// last patch and which nothing consumed - and "the man beside me was just hit
	// and I did not find this fight myself" lands in almost exactly the place
	// Valve's condition does: the grunt who spotted you holds his ground and the
	// others break.
	//
	// Cleared on consumption, in the same spirit as the flinch cooldown in
	// AI_SelectSchedule: nothing else clears it, and a condition left set is a
	// grunt that takes cover, arrives, re-selects, and takes cover again for the
	// rest of the fight.
	if (m.ai_cond & COND_FRIEND_DAMAGED)
	{
		m.ai_cond = m.ai_cond & ~COND_FRIEND_DAMAGED;
		if (Squad_In(m))
			if (!Squad_IsLeader(m))
				if (Cover_Allowed(m))
				{
					ai_dbg_cover_sched = ai_dbg_cover_sched + 1;
					return SCHED_TAKE_COVER;
				}
	}

	// HURT.  hgrunt.cpp:2100-2124 - 90 % cover, 10 % flinch, and the roll is HL's
	// own.  Returning SCHED_NONE on the other 10 % drops through to the generic
	// ladder, whose damage branch produces the flinch (and rate-limits it), so the
	// split needs no second implementation here.
	if (m.ai_cond & COND_DAMAGE)
		if (random() < 0.9)
		{
			float cs = Cover_ScheduleIfHurt(m);
			if (cs != SCHED_NONE)
				return cs;
		}

	if (time < m.ai_nextattack)
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
	// THE CALLOUT, and this is the second half of a fix from the last patch.  The
	// MP5 burst report that used to play out of the grunt's throat here was removed
	// because HL plays no SOUND on HGRUNT_AE_GREN_TOSS - but it does speak: the
	// callout is the HG_THROW sentence (hgrunt.cpp:216).  Removing the wrong noise
	// without restoring the right one left a silent grenade throw.
	AI_TalkSay(m, "THROW", CHAN_VOICE, ATTN_NORM);

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
	AI_TalkSay(m, "THROW", CHAN_VOICE, ATTN_NORM);

	makevectors('0 1 0' * m.angles_y);
	vector src = m.origin + v_forward * 34 + '0 0 32';

	entity g = W_HLGrenadeSpawn(m, src, m.ai_tossvel, time + 6);
	g.touch = Grunt_ContactGrenadeTouch;

	// 0.8, which is hgrunt.cpp:896's own volume, not 1.  Ungated: HL's report at
	// hgrunt.cpp:896 carries no gag test, and a silent grenade launcher is exactly
	// the "placeholder" symptom this round removed.
	AI_Sound(m, CHAN_WEAPON, "weapons/glauncher.wav", 0.8, ATTN_NORM);
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
	// The rig gets the last word on what its gun does - see .ai_shot_dmg.  The
	// melee below deliberately keeps the class figure: a kick is a kick whatever
	// is holstered.
	float gundmg = (self.ai_shot_dmg > 0) ? self.ai_shot_dmg : dmg;

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
		// THE ROCKET AND THE SNIPER SHOT ARE BOTH "BURST1 ONLY", the same shape
		// as the shotgun below and for the same reason.  rpg_shoot and
		// crouching_m40a1 each carry exactly ONE event, so on their own rigs the
		// guard costs nothing - but a reskin whose m40a1 pose is missing falls
		// through to the activity and can land on crouching_m16a2, which carries
		// three.  Without the return, that rig would fire three rockets.
		if (self.weapons & HGRUNT_RPG)
		{
			if (ai_event_code == GRU_AE_BURST1)
				Grunt_FireRocket(self);
			return;
		}

		if (self.weapons & HGRUNT_SNIPER)
		{
			if (ai_event_code == GRU_AE_BURST1)
			{
				float sd = cvar("sv_ai_sniper_dmg");
				if (sd <= 0)
					sd = 40;
				Grunt_FireOne(self, 1, sd, GRU_SPREAD_SNIPER);
				Grunt_FireSound(self);
			}
			return;
		}

		if (self.weapons & HGRUNT_SHOTGUN)
		{
			if (ai_event_code == GRU_AE_BURST1)
			{
				Grunt_FireOne(self, GRU_SHOTGUN_PELLETS, gundmg, GRU_SPREAD_SHOTGUN);
				Grunt_FireSound(self);
			}
			return;
		}

		ai_dbg_shots_grunt = ai_dbg_shots_grunt + 1;
		Grunt_FireOne(self, 1, gundmg, self.ai_spread);

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
		// Otis shares this handler and does not share this gun - see .ai_shot_dmg.
		if (self.ai_shot_dmg > 0)
			dmg = self.ai_shot_dmg;
		// GRU_SPREAD is the grunt's 5 degrees, and Barney is not firing a grunt's
		// gun.  barney.cpp:355 is VECTOR_CONE_2DEGREES - a pistol, aimed, one
		// round at a time - so he is markedly more accurate than the squad that
		// used to share his spread by accident.
		ai_dbg_shots_barney = ai_dbg_shots_barney + 1;
		Grunt_FireOne(self, 1, dmg, GRU_SPREAD_PISTOL);
		// Through the DISPATCHER, not straight to Barney_GunSound: this handler is
		// shared by barney.mdl and otis.mdl, and they are not carrying the same gun
		// - see the otis branch of Grunt_RigOverride.  Classes that install no
		// .ai_gunsound still land on Grunt_GunSound, so put Barney's back explicitly
		// in Barney_ClassInit rather than relying on the default.
		Grunt_FireSound(self);
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
			AI_Sound(self, CHAN_WEAPON, "weapons/pl_gun1.wav", 0.6 + random() * 0.2, ATTN_NORM);
		else
			AI_Sound(self, CHAN_WEAPON, "weapons/pl_gun2.wav", 0.6 + random() * 0.2, ATTN_NORM);
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

	// THE ROCKET HAS A MINIMUM RANGE, and this hook is the only place to put one:
	// AI_GatherConditions raises COND_CAN_RANGE1 on a maximum-distance test alone
	// (sv_ai_core.qc:530-536) and the generic ladder has no minimum anywhere.
	// Without this an RPG grunt fires RPG_EXPLOSION_RADIUS (300) into a target
	// standing on top of him and takes the blast himself, which is the same
	// self-preservation Grunt_CheckGrenade already applies to the toss.
	//
	// Vetoing the range attack leaves melee and chase, both of which he can still
	// reach - unlike the grenade veto, which only declines an option.
	if (self.weapons & HGRUNT_RPG)
	{
		if (vlen(self.ai_enemy.origin - self.origin) <= GRU_RPG_MINRANGE
		 || AI_FriendlyNear(self, self.ai_enemy.origin, GRU_RPG_MINRANGE))
		{
			self.ai_cond = self.ai_cond & ~COND_CAN_RANGE1;
			return;
		}
	}

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
	AI_Sound(self, CHAN_VOICE, sprintf("hgrunt/gr_pain%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// the sentence callouts
// ---------------------------------------------------------------------------
// The grunt family speaks in SENTENCES, not in wavs, and this is the half of that
// the talk layer did not already cover.  AI_MakeTalker gives every one of these
// classes IDLE, HELLO, SHOT, MAD, SCARED, OK, WAIT and POK; what none of them had
// was the line they say the moment they SEE you - which in Half-Life is the single
// most recognisable noise a grunt makes.
//
// The groups are confirmed present in all three mounted sentences.txt files
// (valve 404 groups, gearbox 323, bshift 293): HG_ALERT and HG_THROW in every one,
// BA_ATTACK in valve and gearbox.  AI_TalkSay resolves through the same table and
// returns FALSE for a group that is missing, so a mount without one goes quiet
// rather than erroring.
//
// hgrunt.cpp:210-217 names all seven grunt sentences; the ones still unreached are
// HG_MONSTER, HG_COVER, HG_CHARGE and HG_TAUNT, and all four belong to the squad
// and take-cover work rather than here.
void() Grunt_AlertSound =
{
	AI_TalkSay(self, "ALERT", CHAN_VOICE, ATTN_NORM);
};

// barney.cpp:270-279: Barney says "Freeze!", and it is BA_ATTACK rather than a
// BA_ALERT - there is no such group in any sentences.txt.  ATTN_IDLE is HL's own
// on this one line, which is why he does not shout it across the map.
void() Barney_AlertSound =
{
	AI_TalkSay(self, "ATTACK", CHAN_VOICE, ATTN_IDLE);
};

void() Grunt_Death =
{
	AI_Sound(self, CHAN_VOICE, sprintf("hgrunt/gr_die%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

// The friendly grunt's own voice.  Sven's fgrunt is not a re-skinned hgrunt: it
// has its own sound folder with six pain lines and six deaths, and the deaths are
// spelled "death%g" rather than "gr_die%g".
//
// This is also the hinge the whole soundlist layer turns on for pizza_ya_san1.
// The map's ownershin/empenuze/emptake lists remap fgrunt/gr_pain1-6 and
// fgrunt/death1-6 onto Japanese lines; a lookup keyed on the LEFT column can only
// match what the class actually emits, so with hgrunt paths here every one of
// those pairs was unreachable no matter how correct the parser was.
void() GruntAlly_PainSound =
{
	AI_Sound(self, CHAN_VOICE, sprintf("fgrunt/gr_pain%g.wav", ceil(random() * 6)), 1, ATTN_NORM);
};

void() GruntAlly_Death =
{
	AI_Sound(self, CHAN_VOICE, sprintf("fgrunt/death%g.wav", ceil(random() * 6)), 1, ATTN_NORM);
};

void() Barney_PainSound =
{
	AI_Sound(self, CHAN_VOICE, sprintf("barney/ba_pain%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

// scientist.cpp:801-824.  Scientist_ClassInit set neither .ai_painsound nor
// .ai_death, and AI_Damaged requires one of the two before it will make any noise
// at all (sv_ai_core.qc:2062) - so all 271 placements took a crowbar and died
// without a sound.  HL picks from sci_pain1-5, and its DeathSound is literally
// `PainSound()` (scientist.cpp:826) - there is no SC_DIE group in valve's
// sentences.txt and no scientist death wav, so the two really are the same call.
void() Scientist_PainSound =
{
	AI_Sound(self, CHAN_VOICE, sprintf("scientist/sci_pain%g.wav", ceil(random() * 5)), 1, ATTN_NORM);
};

void() Barney_Death =
{
	AI_Sound(self, CHAN_VOICE, sprintf("barney/ba_die%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
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

		// The rocket has ONE sequence, not a standing/crouching pair: Sven's
		// hgrunt.mdl carries rpg_idle / rpg_aim / rpg_shoot, and only rpg_shoot
		// is tagged act 28 and carries the fire event (f10:e4, 16 frames @ 30).
		//
		// desertcircle's models/descrcl/hgrunt.mdl has the RPG *submodel* but not
		// the sequences, so its rocket grunts degrade to the activity lottery and
		// fire from an MP5 pose.  That is the safe end of the failure - they still
		// launch - and it is why this asks by name rather than adding an activity.
		if (m.weapons & HGRUNT_RPG)
			return "rpg_shoot";

		// The M40A1.  13 frames @ 15 fps against the MP5's 20, and ONE event
		// where HL's mp5 pose carries three - the model is the bolt action.
		// Present on massn, massnf, hgrunt_sniper and Sven's own hgrunt; absent
		// from Half-Life's, which is why this is a name and not an activity.
		if (m.weapons & HGRUNT_SNIPER)
			return m.ai_standing ? "standing_m40a1" : "crouching_m40a1";

		if (m.weapons & HGRUNT_SHOTGUN)
			return m.ai_standing ? "standing_shotgun" : "crouching_shotgun";
		// Sven's SAW, which is grunt-ally-only and carries its own pair of firing
		// sequences.  pizza_ya_san1's shop owner is `weapons 16` on owner_shin.mdl,
		// which has standing_saw / crouching_saw / reload_saw and no *_mp5 at all -
		// so without this he asked for a sequence his rig does not own, fell through
		// to the activity lottery and fired from an idle pose.  AI_SeqOrAct degrades
		// safely for a rig that has no SAW animation, so the test costs nothing on
		// the stock models.
		if (m.weapons & HGRUNT_SAW)
			return m.ai_standing ? "standing_saw" : "crouching_saw";

		// THE M16, newly reachable.  HGRUNT_GRENADELAUNCHER already picks the M16
		// SUBMODEL through iM16 in Grunt_BodyInit, but the POSE fell through to
		// the MP5 pair below, so a `weapons 4` grunt held a rifle and fired it
		// like an SMG.  That was not a choice - Half-Life's hgrunt.mdl has no M16
		// firing sequence at all, so there was nothing to ask for.
		//
		// Sven Co-op's rigs do: hgrunt.mdl, hgrunt_opfor.mdl and massn.mdl all
		// carry standing_m16a2 / crouching_m16a2 (massn even renamed its shotgun
		// pair to them), and Sven is the master mount now, so the sequence is
		// there to be used.
		//
		// PROBED, unlike the branches above, and the asymmetry is deliberate.
		// Those degrade to the activity lottery, which still fires; this one has
		// a strictly better fallback available - the MP5 pose, i.e. exactly what
		// this rig did before - so it is worth one frameforname to keep a
		// Half-Life-rigged grunt on it instead.
		if ((m.weapons & HGRUNT_GRENADELAUNCHER)
		    && AI_SeqNameExists(m.modelindex, "standing_m16a2"))
			return m.ai_standing ? "standing_m16a2" : "crouching_m16a2";

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
	// hgrunt.cpp:1027 - `m_flFieldOfView = 0.2` - wider than CBaseMonster's 0.5,
	// about 157 degrees across.  A soldier is meant to be hard to walk up on from
	// the side; you have to get genuinely behind him.
	m.ai_fov         = 0.2;

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
	m.ai_alertsound  = Grunt_AlertSound;	// HG_ALERT, hgrunt.cpp:211
	m.ai_death       = Grunt_Death;
	m.ai_tick        = Grunt_Aim;	// the spine controller tracks the enemy

	if (m.bloodcolor == 0)
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
	// TWO ENGAGE SLOTS PER SQUAD, squadmonster.h:25-27.  This is the single
	// biggest difference between Half-Life's grunts and a firing line: at most
	// two of a four-man squad shoot at any moment and the other two reposition,
	// which is what makes a squad read as coordinated rather than as four copies
	// of one monster.  A grunt with no squad is never rationed.
	m.ai_slots_attack = SQSLOTS_ENGAGE;

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
	m.ai_class       = CLASS_PLAYER_ALLY;
	m.is_player_ally = TRUE;

	// Sven's friendly grunt voice, replacing the enemy grunt's that CommonInit
	// installed.  See GruntAlly_PainSound, and the guard in Grunt_Precache for why
	// this is conditional rather than unconditional.
	if (grunt_ally_hasfgrunt)
	{
		m.ai_painsound = GruntAlly_PainSound;
		m.ai_death     = GruntAlly_Death;
	}

	// A TALKER, which he was not - so 406 grunt allies plus this map's shop owner
	// and chief had no head turn, no jaw and no idle behaviour at all, because
	// AI_TalkTick only runs for .ai_talker.
	//
	// The group is "FG", Sven's own prefix, and that choice is deliberate on both
	// sides of the fence.  The only sentences.txt this install actually loads is
	// valve's (Sentences_Load reads exactly one, sv_sentences.qc:152), and valve's
	// has no FG_ groups - so AI_TalkSay returns FALSE and he gets the head-turn and
	// look-at behaviour while staying QUIET on the sentence channel, which is what
	// a Japanese shopkeeper should do rather than shouting Half-Life's English
	// military callouts.  If op4's sentences.txt is ever mounted - it has 145 FG_
	// groups over fgrunt/* words - those lines light up AND land on the soundlist
	// remap, which is exactly what the map is built for.
	AI_MakeTalker(m, "FG");
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

	// SVEN'S `weapons` FIELD IS CLASS-DEPENDENT, and bit 8 is where that bites.
	// From the two weapons(Choices) blocks in sven-coop.fgd:
	//
	//   monster_human_grunt      8 = Shotgun        64 = Rocket Launcher
	//                          128 = Sniper Rifle
	//   monster_male_assassin    8 = Sniper Rifle   10 = Sniper Rifle + HG
	//                          256 = Sniper - No drop
	//
	// One bit, two different guns.  This tree read HGRUNT_SHOTGUN everywhere, so
	// every assassin a map armed as a SNIPER fired a shotgun - sound, pellet
	// spread and all.  desertcircle's eight tower marksmen are `weapons 8` and
	// were doing exactly that, from a tower, at range.
	//
	// Translated on the class that means something different by it, so nothing
	// downstream has to know: from here on, one bit means one gun.
	if (m.weapons & HGRUNT_SHOTGUN)
		m.weapons = m.weapons - (m.weapons & HGRUNT_SHOTGUN) + HGRUNT_SNIPER;

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
	AI_Sound(m, CHAN_WEAPON, SND_SHOCK_FIRE, 1, ATTN_NORM);
};

// ...and the weapon is why it needed a handler after all.  This is a THIN one:
// it intercepts exactly the firing and kick codes and hands everything else
// straight back to Grunt_Event, so the rig's shared vocabulary stays shared.
//
// The reported bug was "the shock troopers shot is invisible", and hitscan was
// not merely invisible - it was the wrong primitive.  A shock rifle fires a bolt
// of energy, so this goes down AI_FireBeam (the islave's and the voltigore's
// path) with its own beam kind, rather than AI_FireBullets.  Fixing the tracer
// blindness in cl_monstertrace.qc would have given this class a lead streak.
//
// The numbers are Sven Co-op's own, out of svencoop/skill.cfg on disk rather
// than out of an SDK this machine does not have:
//     sk_plr_shockrifle    15   the bolt.  There is no sk_shocktrooper_dmg
//                               entry because the monster fires the player's
//                               weapon, which is the whole point of the class -
//                               kill one and you can pick its shockroach up.
//     sk_shocktrooper_kick 12   the melee, which was dmg*2 = 16 by inheritance.
void() Shocktrooper_Event =
{
	if (ai_event_code == GRU_AE_BURST1
	 || ai_event_code == GRU_AE_BURST2
	 || ai_event_code == GRU_AE_BURST3)
	{
		float d = cvar("sv_ai_shocktrooper_dmg");
		if (d <= 0)
			d = 15;

		// strooper.mdl's crouching_mp5 raises ONE firing code (4 @0.07) - the
		// dump at the top of this section - so this is one bolt per trigger
		// pull, not three.  The other two codes stay handled because the class
		// shares the hgrunt rig and a map is free to ship one that raises them.
		if (self.ai_enemy)
			AI_FireBeam(self, self.ai_enemy, HL_BEAM_SHOCK, d);
		ai_dbg_shots_grunt = ai_dbg_shots_grunt + 1;
		Grunt_FireSound(self);
		return;
	}

	if (ai_event_code == GRU_AE_KICK)
	{
		float k = cvar("sv_ai_shocktrooper_kick");
		if (k <= 0)
			k = 12;
		AI_MeleeHull(self, GRU_MELEE_REACH, k, 16);
		return;
	}

	Grunt_Event();
};

void(entity m) Shocktrooper_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	m.ai_class = CLASS_ALIEN_MILITARY;
	m.ai_gunsound = Shocktrooper_GunSound;
	// AFTER Grunt_CommonInit, which points ai_event at Grunt_Event.  Grunt_Event
	// is still the fallthrough - see above.
	m.ai_event = Shocktrooper_Event;
	// No drop.  Grunt_CommonInit installed the MP5 drop and this monster does not
	// carry one - in Opposing Force it drops a SHOCKROACH, which is a live weapon
	// this mod has no pickup for.  Dropping nothing is honest; dropping an MP5
	// because it shares the hgrunt rig would not be.
	m.ai_dropweapon = __NULL__;
	if (m.bloodcolor == 0)
		m.bloodcolor = 195;		// alien, not human
};

void(entity m) Robogrunt_ClassInit =
{
	Grunt_CommonInit(m);
	Grunt_GrenadeInit(m);
	m.ai_class = CLASS_MACHINE;
	m.bloodcolor = -1;			// DONT_BLEED: it is a robot
};

// barney.cpp:720-721.  HEAVY damage only, which is a real distinction and not a
// simplification of the grunt's rule: Barney shrugs off a graze and keeps
// shooting, and only breaks when something hits him hard.  A guard who dived for
// cover every time a headcrab clipped him would be useless as an escort, and
// this is the same threshold AI_HEAVY_DMG already draws for the flinch.
//
// Otis and the medic ally share this init, so they share the behaviour - which
// is correct, they share the class in Half-Life too.
float() Barney_SelectSched =
{
	entity m = self;
	if (m.ai_state != MS_COMBAT || !m.ai_enemy)
		return SCHED_NONE;

	if (m.ai_cond & COND_HEAVY_DAMAGE)
		if (Cover_Allowed(m))
		{
			ai_dbg_cover_sched = ai_dbg_cover_sched + 1;
			return SCHED_TAKE_COVER;
		}

	return SCHED_NONE;
};

void(entity m) Barney_ClassInit =
{
	Grunt_CommonInit(m);
	// VIEW_FIELD_WIDE, and barney.cpp:418 says why in Valve's own words: "we need
	// a wide field of view so npc will notice player and say hello".  Overrides
	// the 0.2 CommonInit just set for the soldier.
	m.ai_fov         = -0.7;
	m.ai_selectsched = Barney_SelectSched;
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
	m.ai_gunsound    = Barney_GunSound;	// the 9 mm; otis overrides it below
	m.ai_dropweapon  = Barney_DropWeapon;	// barney.cpp:623, weapon_9mmhandgun
	m.ai_painsound   = Barney_PainSound;
	m.ai_alertsound  = Barney_AlertSound;	// BA_ATTACK, barney.cpp:276
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

	// Sven's two "leave nothing behind" bits, neither of which was read: 256 is
	// the explicit "Don't drop weapon", 32 is "No Weapons" and there is nothing to
	// drop.  Without these an unarmed NPC dropped an MP5 it was never carrying.
	if (m.weapons & (HGRUNT_NODROP | HGRUNT_NOWEAPONS))
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
// Defined below, beside the rig table they were written for.  Used here too,
// because this function had the SAME exact-path bug and it is the one a player
// actually sees: a reskinned grunt kept bodygroup 0 whatever its loadout said.
string(string mdl) Rig_Stem;
float(string stem, string known) Rig_StemIs;
float(string stem, string known) Rig_StemHas;

void(entity m) Grunt_BodyInit =
{
	// MATCHED ON THE STEM, for the reason Grunt_RigOverride is - and this is the
	// half you can SEE.
	//
	// A CORRECTION TO THE LAST ROUND, which said the stem match was the whole fix
	// for desertcircle: it was not.  Making the branch RUN still composes body 0
	// for an ordinary grunt, and body 0 on that rig is the M4 - so the reported
	// "carries a low quality looking assault rifle" survived the fix.  Only the
	// shotgun grunt was corrected by it.
	//
	// The real problem is that THREE different models answer to the stem `hgrunt`
	// and no two of them lay their weapon bodygroup out the same way.  Dumped from
	// the studio headers:
	//
	//   Half-Life/valve/models/hgrunt.mdl
	//       heads   n=4 base=1  weapons n=3 base=4
	//       [0] MP5  [1] shotgun  [2] blank
	//   svencoop/models/hgrunt.mdl
	//       heads   n=5 base=1  weapons n=6 base=5
	//       [0] M16  [1] spas12  [2] unarmed  [3] RPG  [4] MP5  [5] M40A1
	//   svencoop/models/descrcl/hgrunt.mdl
	//       heads   n=4 base=1  weapons n=5 base=4
	//       [0] M4   [1] shotgun  [2] blank    [3] RPG  [4] MP5
	//
	// The formula that was here describes the FIRST of those and only that one.
	//
	// WHICH OF THEM IS LIVE, measured rather than assumed: `sv_ai_selftest 1`
	// prints a sequence count per rig, and models/hgrunt.mdl reports 82 - which is
	// Half-Life's (Sven's is 95, desertcircle's 88).  fs_addons.txt lists
	// steam:Half-Life/valve above steam:Sven Co-op/svencoop and valve wins the
	// name, so on this install the old formula was right for the plain classname.
	//
	// So exactly one of the two bugs is on screen today, and it is the one that
	// was reported: desertcircle names its rig by explicit path, nothing can
	// shadow it, and its index 0 is an M4.  Sven's own rig is the LATENT case -
	// unmount valve, or ship a map that names svencoop's hgrunt.mdl directly, and
	// an ordinary grunt composes 0 and picks up an M16, a shotgun grunt takes the
	// commander head instead of the shotgun one, and `gone` (head+8) lands on the
	// spas12 rather than the blank so a disarmed corpse keeps a shotgun.  Handled
	// here because the cost is one probe and the failure is silent.
	//
	// So this resolves a per-rig INDEX TABLE instead of doing arithmetic per
	// branch, and the three hgrunt rigs are told apart by the sequences they
	// carry - AI_SeqNameExists (sv_ai_anim.qc:522), which exists for exactly this
	// ("finding out that a replacement model lacks the names a class needs").
	// Sequence names are the right discriminator because they are also what
	// decides whether the loadout can be ANIMATED: a rig with rpg_shoot has an RPG
	// submodel, and one without has neither.
	//
	// An unrecognised reskin falls to the Half-Life layout, which is what this
	// function already did for everything, so nothing regresses into a worse
	// state than it was in.
	string mdl = Rig_Stem(m.model);

	// The table: base multiplier, then the submodel index per gun.  -1 means the
	// rig has no submodel for it and the selector must fall back.
	float wb    = 0;	// weapon bodygroup base
	float iMP5  = -1;
	float iSG   = -1;
	float iM40  = -1;
	float iRPG  = -1;
	float iSAW  = -1;
	float iNONE = -1;	// the empty-handed submodel
	float iM16  = -1;	// the M16 that carries the M203 — HGRUNT_GRENADELAUNCHER
	float head  = 0;
	float wi    = -1;	// the index the selector settles on, hoisted for the probe
	string rig  = "none";	// which branch of the table claimed this model

	// UNARMED, and it has to be decided here because this is the last hook in
	// AI_ClassInit - after the rig override, so nothing can put the gun back.
	// Zeroing the range instead of adding a "can he shoot" test everywhere is the
	// same mechanism the scientist uses (Scientist_ClassInit): the generic
	// schedule ladder can only offer an attack whose range is non-zero, so one
	// assignment removes the behaviour everywhere at once.
	if (m.weapons & HGRUNT_NOWEAPONS)
		m.ai_range_range = 0;

	// bgman.mdl, monster_bodyguard's own rig (sven-coop.fgd:4005), and it is NOT
	// laid out like barney's: bodypart[1] is a 2-model HEAD group at base 1 and
	// bodypart[2] is an 8-model GUN group at base 2, so the gun costs two per index
	// and submodel 0 is the blank rather than a holster.  The eight guns are in the
	// FGD's own order - blank, pistol, deagle, shotgun, akimbo uzis, mp5, sniper,
	// minigun - which is also what its `weapons` key selects, so the key indexes
	// the group directly instead of going through the hgrunt bitfield.
	//
	// Tested BEFORE the barney branch because "bodyguard" used to land there and
	// take barney's 0/1/2 - which on this rig is "blank gun, second head" for
	// armed, i.e. an empty-handed bodyguard, and "deagle" for a dropped weapon.
	if (Rig_StemIs(mdl, "bgman"))
	{
		float bgun = bound(0, rint(m.weapons), 7);
		if (bgun <= 0)
			bgun = 1 + floor(random() * 7);	// FGD's "Random"
		m.ai_body_armed   = bgun * 2;
		m.ai_body_holster = m.ai_body_armed;	// no holstered pose on this rig
		m.ai_body_gone    = 0;			// submodel 0 IS the blank
	}
	// Rig_StemHas, not Rig_StemIs, and that one word is the whole of "barney does
	// not hold his glock".
	//
	// Every reskin of this rig puts the family name at the END of the filename -
	// They Hunger's hungerbarney.mdl and hungerotis.mdl, Half-Life's own
	// barney_helmet.mdl and barney_vest.mdl - so a PREFIX test matched none of
	// them.  A rig that matched nothing fell out of this ladder with wb still 0
	// and .ai_body_armed still 0, and 0 on all four of these models is the
	// HOLSTERED submodel.  So the guard drew, aimed, fired and killed you with an
	// empty hand and the pistol still on his hip.
	//
	// Verified against the models rather than assumed: barney.mdl (valve, valve_hd
	// and svencoop), hungerbarney.mdl, sheriff.mdl and pilot.mdl all carry a
	// 3-submodel "gun" group at bodypart[1] base 1, in the order
	// holstered / drawn / blank.  otis.mdl and hungerotis.mdl carry the same group
	// in the same place with a DONUT where the blank would be, which is why that
	// branch keeps its own `gone`.
	else if (Rig_StemHas(mdl, "barney") || Rig_StemHas(mdl, "bodyguard")
	      || Rig_StemIs(mdl, "sheriff") || Rig_StemIs(mdl, "pilot"))
	{
		m.ai_body_holster = 0;
		m.ai_body_armed   = 1;
		m.ai_body_gone    = 2;
	}
	else if (Rig_StemHas(mdl, "otis"))
	{
		m.ai_body_holster = 0;
		m.ai_body_armed   = 1;
		m.ai_body_gone    = 0;		// no blank submodel on this rig
	}
	// The "hgrunt_" exclusion is what lets this sit above the three specialists
	// without swallowing them: every one of their stems begins with this one.
	else if (Rig_StemIs(mdl, "hgrunt") && !Rig_StemIs(mdl, "hgrunt_"))
	{
		// THREE RIGS, ONE STEM.  Told apart by the sequences they carry, because
		// that is the same fact that decides whether the loadout can be animated.
		// Head first in every case, so the weapon multiplier lands on top of it -
		// a shotgun grunt gets the shotgun head, which is HL's own pairing and the
		// reason that head exists.
		// crouching_m40a1 IS THE MARKER FOR THE SIX-WEAPON RIG, and that is not a
		// coincidence worth hiding: the M40A1 is the sixth submodel, so the rig
		// that animates it is exactly the rig that owns six of them.  rpg_shoot is
		// NOT the marker - it looked like one until desertcircle's grunts came out
		// holding an M4 anyway, because that rig carries rpg_idle/aim/shoot/reload
		// too and still lays its weapons out on base 4.
		if (AI_SeqNameExists(m.modelindex, "crouching_m40a1"))
		{
			// svencoop/models/hgrunt.mdl, 95 sequences.
			// heads n=5 base=1 : gasmask / commander / shotgun / black / ROCKET
			// weapons n=6 base=5 : [0] M16 [1] spas12 [2] unarmed [3] RPG
			//                      [4] MP5 [5] M40A1
			// Note the base is FIVE, and index 0 is an M16, not the MP5 - both of
			// which the old formula got wrong.
			rig = "sven-hgrunt";
			wb = 5;  iMP5 = 4;  iSG = 1;  iRPG = 3;  iM40 = 5;  iNONE = 2;
			iM16 = 0;
			if (m.weapons & HGRUNT_RPG)          head = 4;
			else if (m.weapons & HGRUNT_SHOTGUN) head = 2;
		}
		else if (AI_SeqNameExists(m.modelindex, "rpg_shoot"))
		{
			// The desertcircle shape: models/descrcl/hgrunt.mdl, 88 sequences.
			// heads n=4 base=1 : mask / commander / shotgun / grunt
			// weapons n=5 base=4 : [0] M4 [1] shotgun [2] blank [3] RPG [4] MP5
			// Same base as Half-Life's, but index 0 is an M4 and the MP5 has moved
			// to 4 - which is why an ordinary grunt here still showed a rifle after
			// the last round made this branch run at all.  No rocket head on this
			// rig; its four heads are mask / commander / shotgun / grunt.
			rig = "descrcl-hgrunt";
			wb = 4;  iMP5 = 4;  iSG = 1;  iRPG = 3;  iNONE = 2;
			iM16 = 0;			// that M4 IS this rig's "M16 + GL"
			if (m.weapons & HGRUNT_SHOTGUN) head = 2;
		}
		else
		{
			// Half-Life's own, and the fallback for any rig we do not recognise.
			// heads n=4 base=1, weapons n=3 base=4 : [0] MP5 [1] shotgun [2] blank
			// No M16 submodel at all here, so a `weapons 5` grunt on stock HL keeps
			// the MP5 in hand - which is what Half-Life itself shows, since the bit
			// is Sven's addition and valve's rig was never given the gun.
			rig = "hl-hgrunt";
			wb = 4;  iMP5 = 0;  iSG = 1;  iNONE = 2;
			if (m.weapons & HGRUNT_SHOTGUN) head = 2;
		}
	}
	else if (Rig_StemIs(mdl, "hgrunt_sniper"))
	{
		// A STOCK SVEN RIG THAT MATCHED NOTHING AT ALL until now: the "hgrunt_"
		// exclusion above pushes it past the generic branch and no specialist
		// claimed it, so it fell to `else return;` and wore bodygroup 0 - an MP5 -
		// whatever the map asked for.  It is the same shape as massn but on base 4:
		//   heads n=4 base=1, weapons n=4 base=4 : [0] MP5 [1] M40A1 [2] blank [3] M4
		// and it carries crouching_m40a1 / standing_m40a1, so the sniper animation
		// resolves on it too.
		rig = "hgrunt_sniper";
		wb = 4;  iMP5 = 0;  iM40 = 1;  iNONE = 2;  iM16 = 3;
	}
	else if (Rig_StemIs(mdl, "massn"))
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
		// No shotgun submodel on this rig at all, and now none is wanted: the
		// second weapon IS the M40A1, and Assassin_ClassInit has already turned
		// this class's bit 8 into HGRUNT_SNIPER, so the loadout the map asked for
		// and the submodel that exists finally name the same gun.
		//
		// Verified against both rigs rather than assumed - stock massn.mdl and
		// desertcircle's models/descrcl/massnf.mdl are the same shape:
		//   heads n=3 base=1, weapons n=4 base=3 : [0] MP5 [1] M40A1 [2] blank
		//                                          [3] M16/M4
		// That fourth submodel is the "M16 + GL" one - massn.mdl names it
		// Weapons\weapon_m16 outright and massnf.mdl calls it hgrunt_m4_Reference.
		rig = "massn";
		wb = 3;  iMP5 = 0;  iM40 = 1;  iNONE = 2;  iM16 = 3;
	}
	else if (Rig_StemIs(mdl, "hgrunt_torch"))
	{
		m.ai_body_armed   = 0;		// Desert Eagle
		m.ai_body_holster = 2;
		m.ai_body_gone    = 2;
	}
	else if (Rig_StemIs(mdl, "hgrunt_medic"))
	{
		m.ai_body_armed   = 0;		// Desert Eagle, head 0
		m.ai_body_holster = 6;		// weapon slot 3 (holster) * base 2
		m.ai_body_gone    = 6;
	}
	else if (Rig_StemIs(mdl, "hwgrunt"))
	{
		// weapons group, base 1: minigun / beretta / deagle / python / blank.
		m.ai_body_armed   = HWG_BODY_MINIGUN;
		m.ai_body_holster = HWG_BODY_MINIGUN;	// no holstered pose on this rig
		m.ai_body_gone    = HWG_BODY_BLANK;
	}
	else if (Rig_StemIs(mdl, "hgrunt_opfor"))
	{
		// TWO rigs answer to this name, and which one wins is now a MOUNT-ORDER
		// question, so this branch probes instead of assuming:
		//   gearbox/models/hgrunt_opfor.mdl   73 seqs, weapons n=4 base=32
		//       [0] MP5  [1] shotgun  [2] SAW  [3] blank
		//   svencoop/models/hgrunt_opfor.mdl  75 seqs, weapons n=5 base=32
		//       [0] M16  [1] spas12  [2] SAW  [3] blank  [4] MP5
		//
		// THE NOTE THAT USED TO SIT HERE IS NOW WRONG, and it is worth saying why
		// rather than deleting it: it read "hgrunt_opfor.mdl reports 73, so
		// Opposing Force's own rig wins and index 0 is genuinely the MP5", which
		// was true only because fs_addons.txt listed valve/gearbox above
		// svencoop.  Sven Co-op is the master mount now, so its 75-sequence rig
		// wins the name and index 0 is the M16 - a `weapons 5` OpFor grunt would
		// have been handed a rifle while the code believed it was an MP5.
		//
		// Probed by NAME, not by sequence count, for the same reason the hgrunt
		// trio above is: a count is a fact about one pair of files, a name is a
		// fact about the rig.  standing_m16a2 / crouching_m16a2 / walk_new exist
		// only on Sven's copy (diffed: gearbox has walk1 where Sven has walk_new,
		// and gearbox has no *_m16a2 at all).
		//
		// THE SAW IS ON INDEX 2 ON BOTH.  Grunt_SeqFor has answered "standing_saw"
		// for HGRUNT_SAW since pizza_ya_san1, but the body never moved off
		// submodel 0, so a `weapons 16` grunt mimed a SAW while holding an MP5.
		rig = "hgrunt_opfor";
		wb = 32;  iSG = 1;  iSAW = 2;  iNONE = 3;
		if (AI_SeqNameExists(m.modelindex, "standing_m16a2"))
		{
			// svencoop/models/hgrunt_opfor.mdl - the MP5 moved to 4 and a real
			// M16 submodel appeared at 0, so this rig can finally honour an M16
			// loadout instead of silently substituting the MP5.
			rig  = "sven-hgrunt_opfor";
			iM16 = 0;  iMP5 = 4;
		}
		else
		{
			// Opposing Force's own rig.  No M16 submodel exists on it at all, so
			// iM16 stays -1 and a `weapons 5` grunt keeps the MP5.
			iMP5 = 0;
		}
	}
	else
	{
		// Rig has no weapon bodygroup, or one this table does not describe; leave
		// .body alone.  Still worth a probe line - "which monsters fell through"
		// is exactly the question this print exists to answer.
		if (cvar("sv_monster_probe"))
			dprint(sprintf("[bodygroup] %s rig=%s(%s) weapons=%g -> NO TABLE, body left at %g\n",
			               m.classname, mdl, rig, m.weapons, m.body));
		return;
	}

	// ONE selector for every rig that filled the table in.  Precedence matches
	// Grunt_SeqFor and Grunt_Event exactly - RPG, sniper, shotgun, SAW, then the
	// M16 - so what he holds, what he plays and what comes out of the barrel can
	// never disagree.  A rig missing a submodel keeps the MP5 rather than
	// composing an index it does not own.
	//
	// THE M16 IS NEW HERE, and it is the same shape of bug the SAW was: bit 4
	// (HGRUNT_GRENADELAUNCHER) has driven the grenade arc since this file was
	// written - Grunt_ThrowGrenade already fires the M203's flat contact shot
	// instead of a lob for it - but the body never moved, so the grunt launched
	// rifle grenades while visibly holding an MP5.  Sven's FGD spells the loadout
	// "M16 + GL" and writes it as weapons 5; desertcircle has two (base2sm3 and
	// castlesm4) and the corpus has many more.
	//
	// It sits LAST because its bit travels WITH the MP5's - 5 is bit 1 | bit 4,
	// so every M16 grunt is also nominally an MP5 grunt.  Testing it after the
	// exclusive loadouts means a map writing 5|8 still gets the shotgun it asked
	// for, and a rig with no M16 submodel (Half-Life's own, and gearbox's OpFor)
	// keeps the MP5 rather than composing an index it does not own.
	if (wb > 0)
	{
		wi = iMP5;
		if      ((m.weapons & HGRUNT_RPG)     && iRPG >= 0)	wi = iRPG;
		else if ((m.weapons & HGRUNT_SNIPER)  && iM40 >= 0)	wi = iM40;
		else if ((m.weapons & HGRUNT_SHOTGUN) && iSG  >= 0)	wi = iSG;
		else if ((m.weapons & HGRUNT_SAW)     && iSAW >= 0)	wi = iSAW;
		else if ((m.weapons & HGRUNT_GRENADELAUNCHER) && iM16 >= 0)	wi = iM16;
		if (wi < 0)
			wi = 0;

		m.ai_body_armed   = head + wi * wb;
		m.ai_body_holster = m.ai_body_armed;	// no holstered pose on these rigs
		m.ai_body_gone    = head + ((iNONE >= 0) ? iNONE : wi) * wb;
	}

	// THE MEASUREMENT, because "the sniper is holding an assault rifle" is not a
	// question the source can answer on its own: every step of this function
	// traces clean for a massnf marksman and still produced the wrong gun on
	// screen, which means the interesting failure is somewhere between here and
	// the renderer.  This prints what the SERVER decided, so a run tells you
	// which side of the wire to look at.  One line per body, behind the probe
	// cvar that already gates the rest of the spawn dump.
	// Two prints, not one: sprintf carries at most 8 varargs.  wi and iNONE are
	// left out because both are recoverable from the line - wi = (armed-head)/wb
	// and iNONE = (gone-head)/wb.
	if (cvar("sv_monster_probe"))
	{
		dprint(sprintf("[bodygroup] %s rig=%s(%s) weapons=%g m16=%g -> armed=%g gone=%g\n",
		               m.classname, mdl, rig, m.weapons, iM16,
		               m.ai_body_armed, m.ai_body_gone));
		dprint(sprintf("[bodygroup]   wb=%g head=%g | mp5=%g sg=%g m40=%g rpg=%g saw=%g\n",
		               wb, head, iMP5, iSG, iM40, iRPG, iSAW));
	}

	// ...and if the map said "No Weapons", the empty-handed submodel is the armed
	// one.  Down here rather than beside the range test at the top because
	// ai_body_gone is not known until the rig branch above has run.
	if (m.weapons & HGRUNT_NOWEAPONS)
	{
		m.ai_body_armed   = m.ai_body_gone;
		m.ai_body_holster = m.ai_body_gone;
	}

	// Armed on spawn.  Half-Life holsters its talkers until they go alert and
	// draws on BAR_AE_DRAW, and that beat is honoured in Barney_Event - but the
	// initial state has to be something, and an armed guard is both what the
	// player expects and what every non-talker in the family wants anyway.
	m.body = m.ai_body_armed;
};

// The two specialist loadouts change more than the model and the bullet: a bolt
// action is not an MP5's cadence and neither gun is a 1600-unit weapon.
//
// SEPARATE FROM THE CLASS INIT because the loadout is not a property of the
// class - `weapons` comes off the map key, one classname can carry any of the
// bits, and Grunt_RigOverride can still rewrite them (the torch and medic rigs
// have their MP5 bit cleared there).  So this runs where Grunt_BodyInit runs,
// after the rig table has had its say, and reads exactly what the body is about
// to be composed from.
void(entity m) Grunt_LoadoutInit =
{
	// The rocket first, matching every other precedence in this file.
	if (m.weapons & HGRUNT_RPG)
	{
		m.ai_attackrate  = GRU_RPG_REFIRE;
		m.ai_range_range = GRU_SPECIALIST_RANGE;
		return;
	}

	if (m.weapons & HGRUNT_SNIPER)
	{
		// ai_attackrate is a FLOOR, not the whole gap: AI_ArmAttackCooldown
		// (sv_ai_core.qc:201) adds its distance term on top and never lowers a
		// longer figure, so a sniper engaging across the map waits longer still.
		m.ai_attackrate  = GRU_SNIPER_REFIRE;
		m.ai_range_range = GRU_SPECIALIST_RANGE;
	}
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
//
// MATCHED ON THE BASENAME STEM, NOT THE FULL PATH.  Exact-path compares looked
// safe and quietly failed for every map that reskins a stock NPC into its own
// directory - which is the normal way a Sven map ships a custom-looking grunt.
// desertcircle is the case that found it: all 18 of its squadmakers and all 10 of
// its placed NPCs point at models/descrcl/*.mdl, so NOT ONE override fired.
//
// Its "models/descrcl/massnf.mdl" is a massn rig wearing a new skin - 55 bones /
// 53 sequences / 2 bone controllers against stock massn.mdl's 56 / 53 / 2, where
// hassassin.mdl is 62 / 17 / 0 - so the eight tower snipers and four assassin
// squadmakers were running Assassin_Event (codes 1/2/3) on a rig that raises the
// HGRUNT vocabulary (3/4/5/6).  Every round of every burst fell off the end of the
// dispatch, and code 2 - the massn RELOAD - was read as a grenade toss, arming a
// six-second attack lockout each time they reloaded.  That is the identical defect
// described at the top of this block for the gearbox-mounted male assassin, coming
// back in through the custom-model door.
//
// Prefix matching on the stem is what makes "massnf" resolve to the massn rig.
// The specialists are therefore tested BEFORE any shorter stem that prefixes them,
// so hgrunt_opfor can never collapse into a bare hgrunt.
string(string mdl) Rig_Stem =
{
	string s = strtolower(mdl);
	float  n = strlen(s);
	float  i, cut = -1;

	// Last separator wins - forward scan, keep the highest index.  Both slashes,
	// because a map cfg or a .res line can spell either.
	for (i = 0; i < n; i = i + 1)
	{
		string c = substring(s, i, 1);
		if (c == "/" || c == "\\")
			cut = i;
	}
	if (cut >= 0)
		s = substring(s, cut + 1, n - cut - 1);

	n = strlen(s);
	if (n > 4 && substring(s, n - 4, 4) == ".mdl")
		s = substring(s, 0, n - 4);
	return s;
};

// Does `stem` begin with `known`?  substring() clamps, so a stem SHORTER than the
// candidate simply returns itself and fails the compare - no length guard needed.
float(string stem, string known) Rig_StemIs =
{
	return substring(stem, 0, strlen(known)) == known;
};

// Does `stem` CONTAIN `known` anywhere?
//
// Prefix matching is right for telling hgrunt_opfor from hgrunt, and wrong for
// reskins that put the family name at the END: They Hunger ships hungerbarney.mdl
// and hungerotis.mdl, Half-Life itself ships barney_helmet.mdl and
// barney_vest.mdl, and not one of them begins with the name of the rig it IS.
//
// Used only for the bodygroup layout, which is the one question where a reskin
// answers the same as its parent by construction - a model that borrowed barney's
// skeleton borrowed his three-submodel gun group with it.  The rig DISPATCH above
// deliberately keeps prefix matching, because that is where a wrong answer swaps
// an entire event handler.
float(string stem, string known) Rig_StemHas =
{
	return strstrofs(stem, known, 0) >= 0;
};

void(entity m) Grunt_RigOverride =
{
	string mdl = Rig_Stem(m.model);

	if (Rig_StemIs(mdl, "massn"))
	{
		// The hgrunt rig, so the hgrunt handler - and the kick range it took away
		// from the female, because THIS model's frontkick does raise code 3.
		m.ai_event       = Grunt_Event;
		m.ai_dropweapon  = Grunt_DropWeapon;	// an MP5, not the female's pistol
		m.ai_melee_range = GRU_MELEE_REACH;
		m.ai_painsound   = Grunt_PainSound;
		m.ai_alertsound  = Grunt_AlertSound;
		m.ai_death       = Grunt_Death;
		return;
	}

	if (Rig_StemIs(mdl, "hwgrunt"))
	{
		// Sven's heavy weapons grunt: a minigun that fires on 5001 and a pistol
		// that fires on code 1, neither of which the hgrunt handler knows.
		m.ai_event       = HWGrunt_Event;
		m.ai_melee_range = 0;		// no frontkick on this rig
		return;
	}

	if (Rig_StemIs(mdl, "otis"))
	{
		// Otis carries a DESERT EAGLE, and the model says so in its own texture
		// lump - otis.mdl's five textures are otis.BMP, Desert_Eagle.bmp, donut.bmp
		// and two heads.  There is no OpFor SDK on this machine to read the class
		// out of, so the model is the authority, and it is not ambiguous: barney.mdl
		// carries no such texture.
		//
		// He shares Barney's rig, his event vocabulary, his sentence group and his
		// whole class init, so this is the ONE thing that differs - which is exactly
		// what the rig-override hook is for.  Until now he fired barney/ba_attack2,
		// the 9 mm Glock.
		m.ai_gunsound = Grunt_DeagleSound;
		// ...and it hit like one.  sk_otis_bullet is 34; he was doing Barney's 10,
		// because the sound came from the model and the damage came from the class.
		m.ai_shot_dmg = Grunt_DeagleDamage();
		return;
	}

	if (Rig_StemIs(mdl, "hassassin"))
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
	// A REPLACEMENT MODEL KEEPS THE RIG AND LOSES THE NAME, and the stem test
	// above only knows names.  pizza_ya_san1's squadmaker "leader" is
	// monstertype monster_human_medic_ally on new_model
	// models/pizza_ya_san/emptake.mdl, so Rig_Stem answers "emptake", no branch
	// claims it, and the class keeps Barney_Event.  emptake.mdl IS the medic rig
	// - weapons bodygroup [0]"de" [1]"blank" [2]"pizzamed" [3]"blank", plus
	// pull_needle / give_shot / heal_crouch - and its crouching_mp5 and
	// standing_mp5 each carry exactly code 4 + 5001.  Code 4 is HGRUNT_AE_BURST1
	// (hgrunt.cpp:81); in Barney's vocabulary it is BARNEY_AE_HOLSTER
	// (barney.cpp:37).  So he played the firing pose, the event arrived, and the
	// handler PUT HIS GUN AWAY: no bullet, no report, no muzzleflash.  Reported
	// as "leader doesn't make any sound or fire any bullets when he plays his
	// firing animation".
	//
	// BOTH HALVES ARE REQUIRED.  The classname is the mapper's statement of
	// intent; the sequence is the proof that the model can honour it.  A medic
	// reskinned onto a barney-rigged model (shootgun, code 3) must stay on
	// Barney_Event, and crouching_mp5 is exactly the discriminator that says so -
	// the same test, for the same reason, that tells the three "hgrunt" rigs
	// apart in Grunt_BodyInit.  A model that failed to load reports modelindex 0,
	// AI_SeqNameExists returns FALSE, and this falls back to today's behaviour.
	if (Rig_StemIs(mdl, "hgrunt_torch") || Rig_StemIs(mdl, "hgrunt_medic")
	 || (m.classname == "monster_human_medic_ally"
	     && AI_SeqNameExists(m.modelindex, "crouching_mp5")))
	{
		// THE MEDIC HAD NEVER FIRED A SHOT, and this is where that is fixed.
		// monster_human_medic_ally runs Barney_ClassInit (sv_ai_core.qc:2022),
		// which installs Barney_Event - a handler whose only shoot code is 3.
		// hgrunt_medic.mdl fires on 4.  Same shape as the male assassin and the
		// shocktrooper, and found the same way: by diffing the codes the model
		// raises against the codes its handler consumes.
		m.ai_event      = Grunt_Event;		// hgrunt vocabulary, verified above
		m.ai_gunsound   = Grunt_DeagleSound;
		m.ai_shot_dmg   = Grunt_DeagleDamage();	// the same hand cannon Otis carries
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

	if (Rig_StemIs(mdl, "hgrunt_opfor"))
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
// A SCIENTIST RUNS.  He has no attack at all, and until this existed the fear
// path was dead code: the generic ladder in AI_SelectSchedule reaches its
// R_FEAR branch (sv_ai_core.qc:986) only AFTER the MS_COMBAT block, the follow
// test and the MS_ALERT block, and every one of those returns first for a
// scientist who has just been shot.  The measured chain was AI_Damaged -> MS_ALERT
// -> SCHED_WAKE_ANGRY -> MS_COMBAT -> and then, because both attack ranges are 0,
// straight out of the bottom of the combat block to SCHED_CHASE_ENEMY.  He walked
// at you, playing ACT_RUN, forever.
//
// A class selector runs BEFORE that whole ladder (sv_ai_core.qc:874-882), which is
// how the cockroach has always fled correctly with the identical faction answer.
// This is that function, and the parallel is deliberate - see Cockroach_SelectSched.
//
// The condition set is HL's trigger list for fear, collapsed: scientist.cpp:771-782
// (any player damage provokes), :1001-1011 (a new or visible enemy in
// MONSTERSTATE_COMBAT takes cover/panics) and :939-956 (danger or combat sound
// startles).  COND_PROVOKED covers the first, COND_SEE_ENEMY the second,
// COND_DAMAGE the third's practical case.
// scientist.cpp:1080 CScientist::CanHeal, plus the range gate that HL keeps one
// level up at :979 ("If I'm already close enough to my target ... Heal
// opportunistically", TargetDistance() <= 128).
//
// Seats .ai_healtarget as a side effect and returns whether there is anyone to
// treat.  Two conditions are HL's exactly: the 60-second cooldown, and "health
// above half of max means you are fine" - which is where the user's "below 50"
// comes from, since a player's max_health is 100.
//
// ONE DELIBERATE WIDENING.  Half-Life only ever heals m_hTargetEnt, the player
// who asked the scientist to follow, so a scientist standing in a corridor will
// watch you bleed out.  That is a consequence of HL's scientists being almost
// always escorts by the time you are hurt, and it reads as broken here, where
// the follow gate (+use) is rarely used.  So: prefer the escorted player, and
// fall back to the nearest hurt player inside HL's own 128-unit trigger radius.
// Everything past this point - the walk, the 100-unit injection range, the
// cooldown, the amount - is Half-Life's.
float(entity m) Scientist_CanHeal =
{
	m.ai_healtarget = world;

	if (m.ai_healtime > time)
		return FALSE;
	// A frightened scientist runs; he does not stop to do paperwork.  Matches the
	// enclosing `relationship != R_DL && relationship != R_HT` gate at :977.
	if (m.ai_enemy)
		return FALSE;

	// The escort first, at HL's range.
	entity best = world;
	float  bestd = 128;

	if (m.ai_follow)
	if (m.ai_follow.health > 0)
	if (m.ai_follow.health <= m.ai_follow.max_health * 0.5)
	if (vlen(m.ai_follow.origin - m.origin) <= 128)
	{
		m.ai_healtarget = m.ai_follow;
		return TRUE;
	}

	entity p = player_chain_head;
	while (p)
	{
		if (p.health > 0)
		if (p.solid != SOLID_NOT)
		if (p.max_health > 0)
		if (p.health <= p.max_health * 0.5)
		{
			float d = vlen(p.origin - m.origin);
			if (d < bestd)
			{
				best  = p;
				bestd = d;
			}
		}
		p = p.player_chain_next;
	}

	if (!best)
		return FALSE;

	m.ai_healtarget = best;
	return TRUE;
};

float() Scientist_SelectSched =
{
	if (self.ai_state == MS_DEAD)
		return SCHED_NONE;		// let the generic ladder run the death path

	// Deliberately NOT gated on AI_Fears: the faction layer already answers R_FEAR
	// for CLASS_HUMAN_PASSIVE against everything hostile, and for a provoked player
	// AI_RelationshipEnt returns R_FEAR too precisely because this class has no
	// attack (sv_ai_factions.qc:185-186).  Anything that got as far as becoming his
	// ai_enemy is something he should be running from.
	if (self.ai_enemy)
		if (self.ai_cond & (COND_SEE_ENEMY | COND_DAMAGE | COND_PROVOKED))
		{
			// Point and scream, on the TRANSITION only.  .ai_sched still holds the
			// previous schedule when a selector runs, so comparing against it is the
			// whole edge test - without that he would re-say it ten times a second
			// for as long as he ran.  Sentences_Speak is a second guard behind this
			// one (it will not cut its own line short), so the two together give
			// HL's one utterance per fright.
			//
			// scientist.cpp:491-502 picks by who the enemy is: SC_PLFEAR when the
			// thing frightening him is the PLAYER - which is the case the report is
			// about - and SC_FEAR for a monster.  Both groups are in HL's
			// sentences.txt and reach the mixer through the "SC" talk group set in
			// AI_MakeTalker below.
			if (self.ai_sched != SCHED_FLEE_ENEMY)
			{
				if (self.ai_enemy.classname == "player")
					AI_TalkSay(self, "PLFEAR", CHAN_VOICE, ATTN_NORM);
				else
					AI_TalkSay(self, "FEAR", CHAN_VOICE, ATTN_NORM);
			}
			return SCHED_FLEE_ENEMY;
		}

	// The syringe.  Below the fear branch for the same reason HL puts it inside
	// the "nothing scary" arm at scientist.cpp:977 - a scientist being chased does
	// not stop to treat anyone, including himself.
	if (Scientist_CanHeal(self))
		return SCHED_HEAL;

	return SCHED_NONE;
};

void(entity m) Scientist_ClassInit =
{
	m.ai_class       = CLASS_HUMAN_PASSIVE;
	m.ai_fov         = -0.7;	// VIEW_FIELD_WIDE, scientist.cpp:682 - same reason
					// as barney: he has to notice you to greet you
	m.is_player_ally = TRUE;
	m.ai_selectsched = Scientist_SelectSched;

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

	m.ai_painsound = Scientist_PainSound;
	m.ai_death     = Scientist_PainSound;	// HL's DeathSound IS PainSound here

	// scientist.cpp:771-778: the first round from a player provokes him outright,
	// with none of Barney's escalation.  See AI_TalkDamaged for why the two
	// classes genuinely differ rather than this being an inconsistency.
	m.ai_provoke_instant = TRUE;

	// Usable: HL scientists follow on +use.  The gate for this was added in B2
	// (monster_player_usable in sv_use.qc); the follow behaviour itself is still
	// to come, but marking them usable now means the +use path is exercised.
	m.monster_player_usable = TRUE;

	if (m.bloodcolor == 0)
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

// ---------------------------------------------------------------------------
// ...and the three in this family that are NOT Half-Life classes
// ---------------------------------------------------------------------------
// All three used to fall through to Grunt_DefaultHealth or Barney_DefaultHealth,
// which is how the heaviest human in Opposing Force and a shock trooper both
// ended up with a line grunt's 50 HP.  Nothing chose that; it is what sharing a
// rig gets you when the health table is keyed on the rig's owner.
//
// Half-Life has no number for any of them, so Sven Co-op's skill.cfg is not a
// second opinion here - it is the only one.
float() Shocktrooper_DefaultHealth =
{
	float h = cvar("sv_ai_shocktrooper_health");
	if (h <= 0)
		h = 200;			// sk_shocktrooper_health
	return h;
};

float() HWGrunt_DefaultHealth =
{
	float h = cvar("sv_ai_hwgrunt_health");
	if (h <= 0)
		h = 200;			// sk_hwgrunt_health
	return h;
};

float() Otis_DefaultHealth =
{
	float h = cvar("sv_ai_otis_health");
	if (h <= 0)
		h = 65;				// sk_otis_health
	return h;
};
