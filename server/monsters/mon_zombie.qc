// server/monsters/mon_zombie.qc
// ----------------------------------------------------------------------------
// monster_zombie.  1194 placed across the Sven corpus - the single most demanded
// monster class there is, and the reason B3 exists.
//
// Where the headcrab proved the ranged/leaping half of the stack, the zombie
// proves the melee half: a hull-swept claw whose damage lands on animation
// events rather than on a schedule step, with three distinct codes for the two
// attack variants.  Everything below was read out of models/zombie.mdl; the full
// sequence table is in the header of sv_ai_defs.qc.
//
// The one thing worth knowing before touching the speeds: THE MODEL HAS NO RUN
// SEQUENCE.  Activity 4 is absent entirely, so AI_ActivityFallback resolves
// ACT_RUN to ACT_WALK, and a run speed higher than the walk speed would play the
// walk cycle at running pace - visible immediately as skating feet.  The two are
// deliberately equal.
// ----------------------------------------------------------------------------

// Animation event codes, straight from the model.  Monster-specific (< 1000), so
// these three numbers mean this and only this on a zombie.
const float ZOM_AE_ATTACK_RIGHT = 1;	// attack1 @ 0.667s
const float ZOM_AE_ATTACK_LEFT  = 2;	// attack1 @ 1.267s
const float ZOM_AE_ATTACK_BOTH  = 3;	// attack2 @ 0.400s

// Half-Life skill.cfg: sk_zombie_health1 / _dmg_one_slash1 / _dmg_both_slash1.
const float ZOM_HEALTH_DEFAULT     = 50;
const float ZOM_DMG_ONESLASH       = 20;
const float ZOM_DMG_BOTHSLASH      = 40;

// CZombie's claw reach, and the same figure it sweeps its damage hull over.
const float ZOM_MELEE_REACH = 70;

void() Zombie_Precache =
{
	precache_model("models/zombie.mdl");
	precache_sound("zombie/zo_idle1.wav");
	precache_sound("zombie/zo_idle2.wav");
	precache_sound("zombie/zo_idle3.wav");
	precache_sound("zombie/zo_idle4.wav");
	precache_sound("zombie/zo_alert10.wav");
	precache_sound("zombie/zo_alert20.wav");
	precache_sound("zombie/zo_alert30.wav");
	precache_sound("zombie/zo_attack1.wav");
	precache_sound("zombie/zo_attack2.wav");
	precache_sound("zombie/zo_pain1.wav");
	precache_sound("zombie/zo_pain2.wav");
	precache_sound("zombie/claw_miss1.wav");
	precache_sound("zombie/claw_miss2.wav");
	precache_sound("zombie/claw_strike1.wav");
	precache_sound("zombie/claw_strike2.wav");
	precache_sound("zombie/claw_strike3.wav");
};

// ---------------------------------------------------------------------------
// sounds
// ---------------------------------------------------------------------------
void() Zombie_IdleSound =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("zombie/zo_idle%g.wav", ceil(random() * 4)), 1, ATTN_IDLE);
};

void() Zombie_AlertSound =
{
	if (self.gag)
		return;
	// The alert files are named 10/20/30, not 1/2/3.
	sound(self, CHAN_VOICE, sprintf("zombie/zo_alert%g0.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

void() Zombie_PainSound =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("zombie/zo_pain%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

// Growl as the swing starts.  Separate from the claw connecting, which is what
// the anim events below handle.
void() Zombie_StartAttack =
{
	if (self.gag)
		return;
	sound(self, CHAN_VOICE, sprintf("zombie/zo_attack%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
// the claw
// ---------------------------------------------------------------------------
// CZombie::HandleAnimEvent calls CheckTraceHullAttack(70, dmg, DMG_SLASH), which
// sweeps a hull forward from the monster's eye and damages the first thing it
// finds.  A traceline would be wrong here and noticeably so: it would miss a
// player standing slightly off the zombie's centre line, which at claw range is
// most of the time.  tracebox with a modest hull reproduces the sweep.
//
// Damage lands from the EVENT, so a swing that is interrupted before its event
// timestamp does no damage at all - which is what makes backing out of a zombie's
// reach mid-swing actually work.
void(float dmg) Zombie_ClawAttack =
{
	// The hull sweep itself now lives in AI_MeleeHull (sv_ai_combat.qc), because
	// every melee monster from here on wants exactly this and a second copy is a
	// second thing to get wrong.  What stays here is the part that is actually
	// the zombie's: which sound plays on a hit and which on a miss.
	if (AI_MeleeHull(self, ZOM_MELEE_REACH, dmg, 16) != world)
		sound(self, CHAN_WEAPON, sprintf("zombie/claw_strike%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
	else
		sound(self, CHAN_WEAPON, sprintf("zombie/claw_miss%g.wav", ceil(random() * 2)), 1, ATTN_NORM);
};

void() Zombie_Event =
{
	if (ai_event_code == ZOM_AE_ATTACK_RIGHT || ai_event_code == ZOM_AE_ATTACK_LEFT)
	{
		float d = cvar("sv_ai_zombie_dmg_slash");
		if (d <= 0)
			d = ZOM_DMG_ONESLASH;
		Zombie_ClawAttack(d);
		return;
	}

	if (ai_event_code == ZOM_AE_ATTACK_BOTH)
	{
		float db = cvar("sv_ai_zombie_dmg_both");
		if (db <= 0)
			db = ZOM_DMG_BOTHSLASH;
		Zombie_ClawAttack(db);
		return;
	}
};

// ---------------------------------------------------------------------------
// class init
// ---------------------------------------------------------------------------

// Per-activity turn rate, zombie.cpp:122-134.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
float(entity m, float act) Zombie_YawSpeed =
{
	return 120;						// flat in HL too
};

void(entity m) Zombie_ClassInit =
{
	m.ai_class = CLASS_ALIEN_MONSTER;	// CZombie::Classify

	// Melee only - the model carries no ranged activity of any kind.
	m.ai_melee_range = ZOM_MELEE_REACH;
	m.ai_range_range = 0;

	// Equal on purpose: there is no run sequence.  See the file header.
	// Measured from the model's own linearmovement, HL's GetSequenceInfo
	// (animation.cpp:245-249):  speed = |linearmovement| * fps / (numframes-1).
	//   zombie.mdl [10] walk 60f @22fps -> 72.5.  There is no ACT_RUN in the model
	// at all, so run MUST equal walk or the fallback (RUN -> WALK) would play a
	// walk cycle at a run's pace and skate - which is the note below.
	m.ai_speed_walk = 72;
	m.ai_speed_run  = 72;

	// CZombie::SetYawSpeed uses 120 for everything except its turn activities.
	m.ai_yaw_speed = 120;
	m.ai_yawspeed  = Zombie_YawSpeed;

	m.ai_checkattack = __NULL__;		// no extra preconditions beyond the generic ones
	m.ai_idlesound   = Zombie_IdleSound;
	m.ai_alertsound  = Zombie_AlertSound;
	m.ai_painsound   = Zombie_PainSound;
	m.ai_startattack = Zombie_StartAttack;
	m.ai_event       = Zombie_Event;

	if (m.bloodcolor <= 0)
		m.bloodcolor = 247;		// HL BLOOD_COLOR_RED
};

float() Zombie_DefaultHealth =
{
	float h = cvar("sv_ai_zombie_health");
	if (h <= 0)
		h = ZOM_HEALTH_DEFAULT;
	return h;
};

// ---------------------------------------------------------------------------
// variants
// ---------------------------------------------------------------------------
// monster_zombie_barney (92) and monster_zombie_soldier (58) need no code of
// their own.  Both models carry exactly the same shape as zombie.mdl - WALK and
// MELEE1 and nothing else - and, checked against the files, the same three
// attack event codes (1, 2, 3).  So Zombie_ClassInit drives all three unchanged;
// only the default model differs, and that is a table entry in
// Monster_DefaultModel, not code.
//
// Their sounds come from the same zombie/ set, which is correct: Sven ships no
// separate sound folders for either variant.
void(entity m) ZombieBarney_ClassInit =
{
	Zombie_ClassInit(m);
};

void(entity m) ZombieSoldier_ClassInit =
{
	Zombie_ClassInit(m);
	// The soldier reads as armoured and 9 of its 18 placements already set a
	// health key; this only moves the DEFAULT for the ones that do not.
	//   zombie_soldier.mdl [10] walk 60f @28fps -> 95.2.  FASTER than the plain
	// zombie, not slower: its walk cycle runs at 28fps against the base 22.  The
	// old "visibly heavier" note had it backwards.
	m.ai_speed_walk = 95;
	m.ai_speed_run  = 95;
};

void() ZombieVariants_Precache =
{
	precache_model("models/zombie_barney.mdl");
	precache_model("models/zombie_soldier.mdl");
};
