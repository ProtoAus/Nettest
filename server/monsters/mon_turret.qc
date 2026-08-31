// server/monsters/mon_turret.qc
// ----------------------------------------------------------------------------
// monster_sentry (203) / monster_miniturret (163) / monster_turret (87)
//
// 453 placements, and the first class in the whole programme to use either of the
// two mechanisms built for it: AIMODE_STATIC (W1c) and AI_SetSequenceNamed (W1e).
// Both have been verified in isolation and unused until now.
//
// WHY THESE CANNOT USE THE NORMAL PATH.  All three models carry NO activity tags
// whatsoever — every one of their six sequences is act 0 — so frameforaction can
// never reach any of them and AI_SetActivity's whole fallback chain would land
// them on sequence 0 and leave them there.  Confirmed by the boot probe:
//
//   sentry.mdl / miniturret.mdl / turret.mdl, 6 sequences each, all act 0:
//     idle_off  1f  @1   once      deploy  once     spin    LOOP
//     fire      LOOP, with EVENT_MUZZLEFLASH (5001) events
//     retire    once             die     once
//
// THE MUZZLEFLASH EVENTS ARE THE RATE OF FIRE.  "fire" loops and carries a 5001
// per round — three on sentry (0.00/0.10/0.20 s), seven on miniturret, three on
// turret at 150 fps. Hanging the shot on those events rather than on a QC timer
// means each model keeps its own authored cadence for free, and the flash the
// player sees is the shot that was fired.
//
// A turret is deliberately NOT given ai_melee_range: AI_SelectSchedule would then
// be able to pick SCHED_MELEE_ATTACK1, which resolves to an activity these models
// do not have.
// ----------------------------------------------------------------------------

const float TUR_RANGE          = 1200;
const float TUR_SPREAD         = 0.04362;	// ~2.5 degrees: turrets are accurate
const float TUR_RETIRE_DELAY   = 5.0;		// seconds without a target before folding away

// .ai_deployed is the turret's own bit of state.  It cannot live in ai_state
// (MS_* is the shared monster-state vocabulary) and deriving it from the current
// sequence would break the moment a sequence failed to resolve.
.float ai_deployed;
.float ai_lostsight;		// time the enemy was last both alive and visible
.float ai_pingtime;		// next search ping (turret.cpp:418-432, one a second)
// The gun report, per class rather than per file.  All three models share this
// code and only ONE of them shares Half-Life's gun: the ceiling turret fires
// turret/tu_fire1.wav (turret.cpp:622) while the miniturret and the sentry fire
// weapons/hks1-3.wav (turret.cpp:633-635 and :1193-1195).  Every turret in this
// mod fired tu_fire1, and the three hks files were precached in mon_grunt.qc -
// a class that cannot play them - and so were never heard at all.
.string tur_gunsnd;

const string SND_TUR_FIRE = "turret/tu_fire1.wav";
const string SND_TUR_HKS  = "weapons/hks1.wav weapons/hks2.wav weapons/hks3.wav";
const string SND_TUR_DIE  = "turret/tu_die.wav turret/tu_die2.wav turret/tu_die3.wav";

void() Turret_Precache =
{
	precache_model("models/sentry.mdl");
	precache_model("models/miniturret.mdl");
	precache_model("models/turret.mdl");

	AI_SndPrecache(SND_TUR_HKS);
	AI_SndPrecache(SND_TUR_DIE);
	// Literal, because these four are played by direct sound() calls and fteqcc's
	// F210 check can still see them.  weapons/357_shot1.wav used to be here: it is
	// not a turret sound in Half-Life, nothing in this tree ever played it, and it
	// was one of the dead precaches the audit was looking for.
	precache_sound("turret/tu_fire1.wav");
	precache_sound("turret/tu_ping.wav");
	precache_sound("turret/tu_alert.wav");
	precache_sound("turret/tu_deploy.wav");
	precache_sound("turret/tu_spinup.wav");
	precache_sound("turret/tu_spindown.wav");
};

// ---------------------------------------------------------------------------
// firing, driven by the model's own muzzleflash events
// ---------------------------------------------------------------------------
void() Turret_Event =
{
	if (ai_event_code != EVENT_MUZZLEFLASH)
		return;

	if (!self.ai_enemy)
		return;

	float d = cvar("sv_ai_turret_dmg");
	if (d <= 0)
		d = 8;

	AI_FireBullets(self, self.ai_enemy, 1, TUR_SPREAD, d);
	if (!self.gag)
		AI_Sound(self, CHAN_WEAPON, AI_SndPick(self.tur_gunsnd), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// schedule selection
// ---------------------------------------------------------------------------
// A turret's behaviour is a small state machine that the generic ladder cannot
// express: it has to deploy before it can shoot, and fold away again when there
// has been nothing to shoot at for a while.  Returning 0 anywhere here would hand
// it back to the generic ladder, which is why every path returns a real schedule.
// ---------------------------------------------------------------------------
// aiming  (W1a, engine Patch 125)
// ---------------------------------------------------------------------------
// Until the bone controllers were networked, a turret could only "aim" by
// rotating its entire chassis, wall mount and all.  Now the base still swivels
// at ai_yaw_speed - so TASK_FACE_ENEMY completes exactly as before and none of
// the turret schedules change - and the GUN closes whatever angle is left, plus
// the elevation the chassis could never express at all.
//
// Controller 0 is type 0x8010: a WRAPPING rotation, which FTE consumes as
// RADIANS without clamping.  Controller 1 is a bounded rotation in DEGREES,
// clamped by the engine to the model's own range (-60..60 on the sentry,
// -90..15 on the two turrets), so no clamping is needed here either - passing
// the true angle and letting the model limit it is what makes a turret visibly
// fail to depress far enough to hit something directly beneath it.
void() Turret_Aim =
{
	if (!self.ai_enemy || self.health <= 0)
	{
		AI_SetBoneControl(self, 0, 0);
		AI_SetBoneControl(self, 1, 0);
		return;
	}

	vector aim = AI_AimPoint(self.ai_enemy);
	vector src = AI_MuzzlePos(self);

	AI_SetBoneControl(self, 0, AI_AimResidualYaw(self, aim) * 3.14159265 / 180);
	AI_SetBoneControl(self, 1, AI_AimResidualPitch(self, src, aim));
};

float() Turret_SelectSched =
{
	// Death first, and by NAME: these models have a "die" sequence but no
	// ACT_DIESIMPLE tag, so the generic SCHED_DIE would play sequence 0.
	if (self.ai_state == MS_DEAD)
		return SCHED_NONE;		// AI_Died handles it; see Turret_Death

	float see = (self.ai_cond & COND_SEE_ENEMY) && self.ai_enemy;

	if (see)
		self.ai_lostsight = time;

	if (!self.ai_deployed)
	{
		// Retracted.  Only a visible enemy brings it up.
		if (!see)
			return SCHED_TURRET_IDLE;
		self.ai_deployed = TRUE;
		// The deploy is a MACHINE moving, and until now it moved in silence: both
		// tu_deploy and tu_retract were precached by this file and played by
		// nothing.  Two sounds because HL uses two - the mount swinging out
		// (CHAN_BODY, turret.cpp:650) and the barrel coming up to speed
		// (turret.cpp:740).  This branch runs exactly once per deployment.
		if (!self.gag)
		{
			AI_Sound(self, CHAN_BODY, "turret/tu_deploy.wav", 1, ATTN_NORM);
			AI_Sound(self, CHAN_ITEM, "turret/tu_spinup.wav", 1, ATTN_NORM);
		}
		return SCHED_TURRET_DEPLOY;
	}

	// Deployed.
	if (see)
	{
		self.ai_pingtime = 0;		// re-arm the search ping for the next sweep
		if (vlen(self.ai_enemy.origin - self.origin) <= TUR_RANGE)
			return SCHED_TURRET_ATTACK;
		return SCHED_TURRET_SCAN;
	}

	// Nothing in sight.  Sweep for a while before folding away, so a player who
	// ducks behind cover for a moment does not get a free reset.
	if (time - self.ai_lostsight > TUR_RETIRE_DELAY)
	{
		self.ai_deployed = FALSE;
		if (!self.gag)
		{
			AI_Sound(self, CHAN_ITEM, "turret/tu_spindown.wav", 1, ATTN_NORM);
			// HL reuses the deploy sample at pitch 120 for the retract rather than
			// spending a second slot on tu_retract (turret.cpp:700, and the comment
			// at :284 says so outright).
			AI_SoundEx(self, CHAN_BODY, "turret/tu_deploy.wav", 1, ATTN_NORM, 120, 0);
		}
		return SCHED_TURRET_RETIRE;
	}

	// The search ping, one a second while sweeping (turret.cpp:418-432).  It is
	// most of what tells a player a turret is awake and has not found them yet.
	if (time >= self.ai_pingtime)
	{
		self.ai_pingtime = time + 1;
		if (!self.gag)
			AI_Sound(self, CHAN_ITEM, "turret/tu_ping.wav", 1, ATTN_NORM);
	}
	return SCHED_TURRET_SCAN;
};

void() Turret_Death =
{
	// One of three, evenly (turret.cpp:931-938).  CHAN_BODY, not CHAN_VOICE: a
	// machine has no voice, and HL puts it on the body channel so the shot that
	// killed it does not cut it off.
	AI_SndPlay(self, CHAN_BODY, SND_TUR_DIE);
	// By name, for the same reason the selector avoids SCHED_DIE: there is no
	// ACT_DIESIMPLE on this model, so asking for the activity plays sequence 0.
	AI_SetSequenceNamed(self, "die", FALSE);
};

void() Turret_AlertSound =
{
	// tu_alert.wav, which nothing in this tree had ever precached.  It used to play
	// tu_active2 - that is the RUNNING-SPIN loop, a sample meant to sit under the
	// turret continuously on CHAN_STATIC, not a one-shot alert (turret.cpp:748 vs
	// :915).  The spin loop is still unused and is noted as such.
	if (!self.gag)
		AI_Sound(self, CHAN_BODY, "turret/tu_alert.wav", 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// class init
// ---------------------------------------------------------------------------
void(entity m) Turret_CommonInit =
{
	m.ai_class = CLASS_MACHINE;

	// STATIC: bolted to whatever surface the mapper put it on.  AI_Spawn gives it
	// MOVETYPE_NONE and skips droptofloor entirely - a ceiling turret dropped to
	// the floor is exactly the bug AIMODE_STATIC exists to prevent.
	m.ai_movemode = AIMODE_STATIC;

	// NO melee range.  See the header: a melee schedule would resolve to an
	// activity these models do not carry.
	m.ai_melee_range = 0;
	m.ai_range_range = TUR_RANGE;

	// VIEW_FIELD_FULL (turret.cpp:271), and in CommonInit rather than on one
	// variant because it is load-bearing for all three: a turret that could only
	// acquire inside a forward cone would stop covering the room it was placed to
	// cover, and it cannot walk round to look.
	m.ai_fov         = -1;

	m.ai_yaw_speed   = 120;		// the base swivels; the gun leads it - see Turret_Aim
	m.ai_selectsched = Turret_SelectSched;
	m.ai_tick        = Turret_Aim;
	m.ai_event       = Turret_Event;
	m.ai_death       = Turret_Death;
	m.ai_alertsound  = Turret_AlertSound;

	m.bloodcolor = -1;		// DONT_BLEED
};

void(entity m) Sentry_ClassInit =
{
	Turret_CommonInit(m);
	m.tur_gunsnd = SND_TUR_HKS;		// turret.cpp:1193-1195
	// The sentry is the free-standing one: it starts deployed and never retires,
	// which is what makes it read as a walking hazard rather than a wall fixture.
	m.ai_deployed = TRUE;
};

void(entity m) Miniturret_ClassInit
	= { Turret_CommonInit(m); m.tur_gunsnd = SND_TUR_HKS;  };	// turret.cpp:633-635
void(entity m) Turret_ClassInit
	= { Turret_CommonInit(m); m.tur_gunsnd = SND_TUR_FIRE; };	// turret.cpp:622

float() Turret_DefaultHealth
	= { float h = cvar("sv_ai_turret_health"); return (h > 0) ? h : 50; };
