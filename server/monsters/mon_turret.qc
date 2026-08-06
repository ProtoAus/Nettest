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

void() Turret_Precache =
{
	precache_model("models/sentry.mdl");
	precache_model("models/miniturret.mdl");
	precache_model("models/turret.mdl");
	precache_sound("weapons/357_shot1.wav");
	precache_sound("turret/tu_fire1.wav");
	precache_sound("turret/tu_ping.wav");
	precache_sound("turret/tu_active2.wav");
	precache_sound("turret/tu_die.wav");
	precache_sound("turret/tu_deploy.wav");
	precache_sound("turret/tu_retract.wav");
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
		sound(self, CHAN_WEAPON, "turret/tu_fire1.wav", 1, ATTN_NORM);
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
		return SCHED_TURRET_DEPLOY;
	}

	// Deployed.
	if (see)
	{
		if (vlen(self.ai_enemy.origin - self.origin) <= TUR_RANGE)
			return SCHED_TURRET_ATTACK;
		return SCHED_TURRET_SCAN;
	}

	// Nothing in sight.  Sweep for a while before folding away, so a player who
	// ducks behind cover for a moment does not get a free reset.
	if (time - self.ai_lostsight > TUR_RETIRE_DELAY)
	{
		self.ai_deployed = FALSE;
		return SCHED_TURRET_RETIRE;
	}
	return SCHED_TURRET_SCAN;
};

void() Turret_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, "turret/tu_die.wav", 1, ATTN_NORM);
	// By name, for the same reason the selector avoids SCHED_DIE: there is no
	// ACT_DIESIMPLE on this model, so asking for the activity plays sequence 0.
	AI_SetSequenceNamed(self, "die", FALSE);
};

void() Turret_AlertSound =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, "turret/tu_active2.wav", 1, ATTN_NORM);
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
	// The sentry is the free-standing one: it starts deployed and never retires,
	// which is what makes it read as a walking hazard rather than a wall fixture.
	m.ai_deployed = TRUE;
};

void(entity m) Miniturret_ClassInit = { Turret_CommonInit(m); };
void(entity m) Turret_ClassInit     = { Turret_CommonInit(m); };

float() Turret_DefaultHealth
	= { float h = cvar("sv_ai_turret_health"); return (h > 0) ? h : 50; };
