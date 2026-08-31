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

// ---------------------------------------------------------------------------
// the stomp wave  —  CStomp, gargantua.cpp:79-179
// ---------------------------------------------------------------------------
// gargantua.cpp:1011-1014 sets m_seeTime = time + 12 on the stomp event, and
// :693-703 pushes it back to time + 5 whenever the enemy is out of sight.
const float GARG_STOMP_COOLDOWN = 12;
const float GARG_STOMP_SIGHT    = 5;
// STOMP_INTERVAL (gargantua.cpp:120) and the think period (:126).
const float GARG_STOMP_STEP     = 0.025;
const float GARG_STOMP_THINK    = 0.1;
const float GARG_STOMP_RANGE    = 1024;	// gargantua.cpp:477, the aim trace

.float gstomp_rate;	// HL's pev->framerate: the acceleration, itself accelerating
.float gstomp_budget;	// HL's pev->scale: distance left to travel, and its life
.float garg_range;	// the class's own ai_range_range, so the sight gate can restore it

void(entity m, float dmgamt) Garg_StompSpawn;

const float STUKA_AE_ATTACK = 1;

// svencoop voices, listed out of the mount rather than read from source - there is
// no Sven SDK here either.  The stukabat's whole sound directory is ONE file, a
// 1.5 KB wing flap, so there is no pain or death voice to install and none is
// invented; the kingpin has a full set and had none of it wired.
const string SND_STUKA_FLAP  = "stukabat/stukabat_flap1.wav";
const string SND_KING_IDLE   = "kingpin/kingpin_idle1.wav kingpin/kingpin_idle2.wav kingpin/kingpin_idle3.wav";
const string SND_KING_ALERT  = "kingpin/kingpin_alert1.wav kingpin/kingpin_alert2.wav kingpin/kingpin_alert3.wav";
const string SND_KING_PAIN   = "kingpin/kingpin_pain1.wav kingpin/kingpin_pain2.wav kingpin/kingpin_pain3.wav";
const string SND_KING_DIE    = "kingpin/kingpin_death1.wav kingpin/kingpin_death2.wav";

// gargantua.cpp:299-376.  ATTN_GARG is #defined to ATTN_NORM (gargantua.cpp:58),
// so despite the name every one of these carries exactly as far as anything else.
//
// gar_idle1-5, gar_alert1-3, gar_step1-2 and gar_breathe1-3 were neither precached
// nor reachable: the class had no idle, no alert, and its footstep and breathing
// events were explicit no-ops under a comment saying the model names no sound file
// on them.  True, and beside the point - Half-Life names them in the SERVER DLL,
// not in the model, exactly as it does for the zombie's SWISHSOUND.
//
// It also had one death sample where two exist.  There is no pDeathSounds array in
// gargantua.cpp at all, so gar_die1/gar_die2 are this port's own choice; both are
// on disk and using both is strictly better than using one.
const string SND_GARG_IDLE    = "garg/gar_idle1.wav garg/gar_idle2.wav garg/gar_idle3.wav garg/gar_idle4.wav garg/gar_idle5.wav";
const string SND_GARG_ALERT   = "garg/gar_alert1.wav garg/gar_alert2.wav garg/gar_alert3.wav";
const string SND_GARG_ATTACK  = "garg/gar_attack1.wav garg/gar_attack2.wav garg/gar_attack3.wav";
const string SND_GARG_PAIN    = "garg/gar_pain1.wav garg/gar_pain2.wav garg/gar_pain3.wav";
const string SND_GARG_DIE     = "garg/gar_die1.wav garg/gar_die2.wav";
const string SND_GARG_STEP    = "garg/gar_step1.wav garg/gar_step2.wav";
const string SND_GARG_BREATHE = "garg/gar_breathe1.wav garg/gar_breathe2.wav garg/gar_breathe3.wav";

// The BABY gargantua has its own folder, and it is not a copy of the above -
// svencoop ships sound/babygarg/ with all 25 files under the same names.  The
// baby was borrowing the adult's voice, which is wrong on its own (it should not
// sound like something four times its size) and is also what made pizza_ya_san1's
// electro.txt inert: that list remaps babygarg/gar_*, a path this class never
// emitted.  Same names, different directory, so one prefix swap covers the set.
const string SND_BGARG_IDLE    = "babygarg/gar_idle1.wav babygarg/gar_idle2.wav babygarg/gar_idle3.wav babygarg/gar_idle4.wav babygarg/gar_idle5.wav";
const string SND_BGARG_ALERT   = "babygarg/gar_alert1.wav babygarg/gar_alert2.wav babygarg/gar_alert3.wav";
const string SND_BGARG_ATTACK  = "babygarg/gar_attack1.wav babygarg/gar_attack2.wav babygarg/gar_attack3.wav";
const string SND_BGARG_PAIN    = "babygarg/gar_pain1.wav babygarg/gar_pain2.wav babygarg/gar_pain3.wav";
const string SND_BGARG_DIE     = "babygarg/gar_die1.wav babygarg/gar_die2.wav";
const string SND_BGARG_STEP    = "babygarg/gar_step1.wav babygarg/gar_step2.wav";
const string SND_BGARG_BREATHE = "babygarg/gar_breathe1.wav babygarg/gar_breathe2.wav babygarg/gar_breathe3.wav";

// ...and whether that folder is actually mounted.  babygarg/ is svencoop content
// and this mod also runs against a valve-only mount, where babygarg.mdl is absent,
// the class falls back to garg.mdl and none of these files were precached - so an
// unconditional swap would trade the adult's voice for silence, which is the worse
// of the two.  Latched in BigFoes_Precache; a whichpack() per body would be a
// filesystem query per spawn for a fact that cannot change during a map.
float garg_hasbabyvoice;

// THE FLAME IS A SPRITE BEAM, not a particle streak, and this is the sprite.
// gargantua.cpp:51 — GARG_BEAM_SPRITE_NAME "sprites/xbeam3.spr" — precached at
// :784-788.  Worth naming the wrong guess explicitly because it is the obvious
// one: there is NO sprites/flame.spr anywhere in gargantua.cpp; gargeye1.spr is
// the eye glow (:767) and the stomp (:113), and the jet is xbeam3.
const string GARG_FLAME_SPRITE = "sprites/xbeam3.spr";

// The four beams of one jet, held for the life of the sweep.  Four, not two:
// FlameCreate (gargantua.cpp:492-530) builds beams 0-1 as the wide outer flame
// and 2-3 as a narrower blue CORE that starts 40% of the way down (:576), and the
// pair is most of what makes it read as a flame rather than a bar of light.
//
// Persistent entities rather than a re-emitted effect, which is the other half of
// the fidelity gap: HL creates these once and removes them in FlameDestroy, where
// this used to multicast a fresh 0.16 s particle recipe TWICE PER TICK for the
// whole 4.5 s sweep.
.entity garg_beam_l, garg_beam_r, garg_beam_lc, garg_beam_rc;

void() BigFoes_Precache =
{
	precache_model("models/garg.mdl");
	precache_model(GARG_FLAME_SPRITE);
	precache_model("models/stukabat.mdl");
	precache_model("models/kingpin.mdl");
	garg_hasbabyvoice = Monster_SoundExists("babygarg/gar_idle1.wav");
	if (Monster_ModelExists("models/babygarg.mdl"))
		precache_model("models/babygarg.mdl");
	if (garg_hasbabyvoice)
	{
		AI_SndPrecache(SND_BGARG_IDLE);
		AI_SndPrecache(SND_BGARG_ALERT);
		AI_SndPrecache(SND_BGARG_ATTACK);
		AI_SndPrecache(SND_BGARG_PAIN);
		AI_SndPrecache(SND_BGARG_DIE);
		AI_SndPrecache(SND_BGARG_STEP);
		AI_SndPrecache(SND_BGARG_BREATHE);
		precache_sound("babygarg/gar_stomp1.wav");
	}

	AI_SndPrecache(SND_GARG_IDLE);
	AI_SndPrecache(SND_GARG_ALERT);
	AI_SndPrecache(SND_GARG_ATTACK);
	AI_SndPrecache(SND_GARG_PAIN);
	AI_SndPrecache(SND_GARG_DIE);
	AI_SndPrecache(SND_GARG_STEP);
	AI_SndPrecache(SND_GARG_BREATHE);
	precache_sound("garg/gar_stomp1.wav");	// direct sound() call; keeps F210

	// The stukabat and the kingpin are svencoop classes with voices of their own.
	// Both were completely mute: no pain hook, no death hook, and in the
	// stukabat's case a single 1.5 KB wing flap as its entire sound set.
	if (Monster_ModelExists("models/stukabat.mdl"))
		precache_sound(SND_STUKA_FLAP);
	if (Monster_ModelExists("models/kingpin.mdl"))
	{
		AI_SndPrecache(SND_KING_IDLE);
		AI_SndPrecache(SND_KING_ALERT);
		AI_SndPrecache(SND_KING_PAIN);
		AI_SndPrecache(SND_KING_DIE);
	}
};

// ---------------------------------------------------------------------------
// gargantua / babygarg
// ---------------------------------------------------------------------------
// One event handler, two sound folders.  A latch rather than a classname compare
// at four sites inside a per-event hook, and rather than four more .string fields
// for what is really one bit of information.
.float gar_isbaby;

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
		AI_SndPlay(self, CHAN_WEAPON, self.gar_isbaby ? SND_BGARG_ATTACK : SND_GARG_ATTACK);
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
			d = 100;	// Sven skill.cfg:68 sk_gargantua_dmg_stomp, and HL's medium/hard
		// No gag gate: HL's stomp report at gargantua.cpp:484 has none, and a silent
		// stomp is the same "placeholder" failure the grunt sounds had.
		AI_SoundEx(self, CHAN_WEAPON, self.gar_isbaby ? "babygarg/gar_stomp1.wav" : "garg/gar_stomp1.wav", 1, ATTN_NORM,
		      90 + floor(random() * 21), 0);	// gargantua.cpp:484, PITCH +/-10

		// gargantua.cpp:483, between StompCreate and the sound.  Radius 1000
		// against the stomp's own 400-unit blast, so you feel it coming from
		// well outside the damage — which is the point of it.
		SV_ScreenShake(self.origin, 12.0, 100.0, 2.0, 1000);

		float srad = 400 * self.ai_dmg_scale;

		// THE STOMP HAD NO VISUAL OF ANY KIND - sound and radius damage and
		// nothing on screen - which made it the one attack in the game that has
		// to be read from its extent and gave you nothing to read it from.
		//
		// THE RING IS NOW A TELEGRAPH AND NOTHING ELSE.  It used to carry the damage
		// too, via AI_BlastAttack at 400 units - which was this port's own invention:
		// Half-Life's stomp does NO radial damage at any radius.  All of it lives in
		// CStomp, the wave spawned below, which travels forward and hits the first
		// thing in its path (gargantua.cpp:122-179).
		//
		// The ring stays because the argument for adding it still holds - before it,
		// the stomp was the one attack in the game with no on-screen tell at all - and
		// because a wave that starts 35 units in front of the gargantua reads as
		// something the gargantua just did to the floor.  Red with a white core, taken
		// from gargeye1.spr's own palette - (255,255,255) (231,24,24) (181,16,16).
		Shockwave_Multicast(self.origin, srad, 0.55, 26, '255 60 30', SHOCKWAVE_EXPAND);

		// ...plus fire coming up out of the floor around the rim, which is the
		// half a flat ring cannot carry. Eight points, not a solid ring: HL's
		// wave is ten discrete sprites and a continuous skirt would read as a
		// dome rather than as ground bursting.
		float si;
		for (si = 0; si < 8; si = si + 1)
		{
			float sa = si * (M_PI * 2 / 8);
			vector sp = self.origin + [cos(sa) * srad * 0.75, sin(sa) * srad * 0.75, 0];
			sp_z = sp_z + self.mins_z + 4;
			AlienFX_Multicast(ALIENFX_GARG_STOMP, sp, '0 0 1');
		}

		// The damage: HL's travelling wave, not a radial blast.  See Garg_StompSpawn.
		Garg_StompSpawn(self, d * self.ai_dmg_scale);

		// 12 seconds, not 4.  HL sets m_seeTime = time + 12 on this very event
		// (gargantua.cpp:1011-1014) and CheckRangeAttack1 refuses until it passes;
		// PrescheduleThink additionally pushes m_seeTime to time+5 on every think
		// where the gargantua cannot see its enemy (:693-703), so it must have held
		// the player in sight for five continuous seconds before the first one.
		// At 4 s with no sight requirement this stomped three times as often as HL.
		self.ai_nextattack = time + GARG_STOMP_COOLDOWN;
		self.ai_seetime    = time + GARG_STOMP_COOLDOWN;
		return;
	}
	// The footfalls and the breathing.  The MODEL names no file on these codes,
	// which is why they used to be no-ops - but Half-Life does not read the file
	// from the model here either.  gargantua.cpp:1013-1019 names pFootSounds and
	// pBreatheSounds in the server dll, the same way the zombie's SWISHSOUND is
	// named in code rather than in the options field.  On a monster this size the
	// footsteps are the arrival warning, and there was none.
	if (ai_event_code == GARG_AE_RFOOT || ai_event_code == GARG_AE_LFOOT)
	{
		AI_SndPlay(self, CHAN_BODY, self.gar_isbaby ? SND_BGARG_STEP : SND_GARG_STEP);
		// gargantua.cpp:1008 — every footfall shakes the ground for 750 units.
		// Low amplitude and a very low frequency (3, against the stomp's 100),
		// so it reads as a heavy tremor rather than a rattle.  Together with
		// the sound above this is the arrival warning the comment mentions.
		SV_ScreenShake(self.origin, 4.0, 3.0, 1.0, 750);
		return;
	}
	if (ai_event_code == GARG_AE_BREATHE)
	{
		AI_SndPlay(self, CHAN_VOICE, self.gar_isbaby ? SND_BGARG_BREATHE : SND_GARG_BREATHE);
		return;
	}
};

// ---------------------------------------------------------------------------
// the stomp wave
// ---------------------------------------------------------------------------
// CStomp::Think, gargantua.cpp:122-179.  A shockwave that starts just in front of
// the gargantua, accelerates along the ground and damages the FIRST thing it
// reaches - which is why standing beside a gargantua is safe and standing in front
// of one is not.  The port had a 400-unit radial blast instead, which is the exact
// opposite shape, and Half-Life has no radial component to the stomp at all.
//
// ACCELERATION, AND WHY THE NUMBERS ARE NOT HL'S LITERALLY.  The SDK writes
// `speed += gpGlobals->frametime * framerate` inside a think it schedules every
// 0.1 s - frametime is the SERVER FRAME delta, not the think period, so GoldSrc's
// wave travels at a speed that depends on the server's framerate and is roughly six
// times slower at 60 fps than the same expression integrated over the think it lives
// in.  That is a bug in the original, not a design, and transcribing it would make
// this attack behave differently on every machine.  Integrated over the think period
// instead: the speed series is 3, 21, 54, 102, 165, 243 ... and the wave covers its
// full 1024 units in about 1.6 s, deterministically.
void() garg_stomp_think =
{
	entity own = self.owner;
	if (!own || wasfreed(own))
	{
		remove(self);
		return;
	}

	self.nextthink = time + GARG_STOMP_THINK;

	// Damage for this frame: a head-hull sweep 30 units up, first hit only
	// (gargantua.cpp:129-144).  The wave keeps going through whatever it hits.
	vector st = self.origin;
	st_z = st_z + 30;
	vector en = st + self.movedir * self.speed * GARG_STOMP_THINK;
	tracebox(st, '-16 -16 -18', '16 16 18', en, FALSE, self);
	if (trace_ent && trace_ent != world && trace_ent != own && trace_ent.health > 0)
	{
		// The same pair AI_BlastAttack uses (sv_ai_combat.qc:268-269).  No takedamage
		// gate, for the reason Garg_FlameDamage documents at length: players in this
		// tree sit at DAMAGE_NO permanently and W_CanDamageTarget is the authority.
		sv_dmg_bits = DMG_SONIC;
		W_ApplyDamage(own, trace_ent, self.dmg);
	}

	self.speed       = self.speed + GARG_STOMP_THINK * self.gstomp_rate;
	self.gstomp_rate = self.gstomp_rate + GARG_STOMP_THINK * 1500;

	// Advance in HL's 0.025 s sub-steps so the trail is laid down evenly rather than
	// in one jump per think, and so the distance budget is spent at the right rate.
	float k;
	for (k = 0; k < GARG_STOMP_THINK; k = k + GARG_STOMP_STEP)
	{
		setorigin(self, self.origin + self.movedir * (self.speed * GARG_STOMP_STEP));
		self.gstomp_budget = self.gstomp_budget - self.speed * GARG_STOMP_STEP;
		if (self.gstomp_budget <= 0)
		{
			remove(self);
			return;
		}
	}

	// Fire out of the floor under the wave.  HL drops two sprites per 0.025 s step,
	// i.e. eighty a second; this is one multicast per think, because ALIENFX_GARG_STOMP
	// is already a 12-particle burst plus a dynamic light (sh_alienfx.qc:181, :198)
	// rather than a single sprite, and eighty of those a second is a wire flood for a
	// visual that is not eight times better.
	traceline(self.origin, self.origin - '0 0 500', TRUE, self);
	if (trace_fraction < 1)
		AlienFX_Multicast(ALIENFX_GARG_STOMP, trace_endpos + '0 0 4', '0 0 1');
};

// CGargantua::StompAttack, gargantua.cpp:472-489.
void(entity m, float dmgamt) Garg_StompSpawn =
{
	makevectors([0, m.angles_y, 0]);
	vector st = m.origin + '0 0 60' + v_forward * 35;

	// Aim at the enemy if there is one, straight ahead otherwise, and trace the
	// full range with monsters ignored so the budget is "distance to the first WALL".
	vector dir = v_forward;
	if (m.ai_enemy)
	{
		vector to = (m.ai_enemy.origin + '0 0 24') - st;
		if (to != '0 0 0')
			dir = normalize(to);
	}
	dir_z = 0;			// the wave runs along the ground
	if (dir == '0 0 0')
		return;
	dir = normalize(dir);

	traceline(st, st + dir * GARG_STOMP_RANGE, TRUE, m);
	float budget = vlen(trace_endpos - st);
	if (budget < 32)
		return;

	entity s = spawn();
	s.classname     = "garg_stomp";
	s.owner         = m;
	s.movetype      = MOVETYPE_NONE;
	s.solid         = SOLID_NOT;
	s.movedir       = dir;
	s.speed         = 0;			// starts at rest and accelerates
	s.gstomp_rate   = 30;			// pev->framerate, gargantua.cpp:111
	s.gstomp_budget = budget;		// pev->scale: "scale has the life of this effect"
	s.dmg           = dmgamt;
	setorigin(s, st);
	s.think     = garg_stomp_think;
	s.nextthink = time + GARG_STOMP_THINK;

	ai_dbg_garg_stomps = ai_dbg_garg_stomps + 1;
};


// Per-activity turn rate, gargantua.cpp:720-743.  HL's raw numbers;
// AI_ChangeYaw applies the same x2 Half-Life does.
// ---------------------------------------------------------------------------
// the flame
// ---------------------------------------------------------------------------
// The gargantua's flamethrower did not exist: Garg_Event handled SLASH and STOMP
// and nothing else, so the single most recognisable thing a gargantua does was
// absent from a boss with 208 placements.  This is CGargantua::FlameCreate /
// FlameUpdate / FlameDamage (gargantua.cpp:492-672) as one sustained task.
//
// WHY IT NEEDED A SCHEDULE RATHER THAN AN ANIMATION EVENT.  Every other attack in
// this mod lands on an event: the animation reaches a frame, damage happens, the
// attack is over.  The flame is not shaped like that - it burns for four and a
// half seconds, tracks the enemy while it burns, does damage continuously and
// re-draws itself ten times a second.  Bolting that onto GARG_AE_SLASH would have
// produced a single frame of orange and no threat, which is why PATCH 136 left it
// out rather than half-landing it.

// The two flame emitters.  HL takes them from ATTACHMENTS 1 AND 2 - the hands -
// via GetAttachment(i+1) in FlameUpdate (gargantua.cpp:566, with :509 noting the
// index is 0-based).  Read out of the model files themselves:
//
//   garg.mdl      att[1] bone 32 "Bip01 R Arm2" (53,5,0)   att[2] bone 25 "Bip01 L Arm2"
//   babygarg.mdl  same two bones, (21,2,0)
//   hlclassic     same offsets as garg.mdl, but 57 bones where svencoop's has 50
//
// This file used to claim attachments "are not exposed to server QC on this
// engine" and synthesise the emitters off the hull instead.  THAT WAS FALSE and it
// cost about 109 units per hand: FTE registers gettaginfo as SSQC builtin 452
// (engine/server/pr_cmds.c:12128) and exposes HL attachments as tag indices
// numbones+1 .. numbones+numattachments (engine/gl/gl_hlmdl.c:1327-1384), with the
// bone controllers this file already drives applied in the server framestate.
//
// The constants below are now the FALLBACK, for a replacement model that has no
// attachments (or a server that cannot evaluate the skeleton).  They are also why
// the gargantua's hull must not be corrected on its own - see Monster_ClassHull.
const float GARG_FLAME_SIDE  = 26;	// lateral offset per emitter
const float GARG_FLAME_UP    = 0.66;	// fraction of hull height, as AI_MuzzlePos

// Resolved once per body: the model's bone count, which is where its attachment
// tags start.  It is NOT a constant across the corpus (50 vs 57), so it cannot be
// hardcoded.  -1 means "asked and the model has no skeleton" - use the fallback.
.float garg_tagbase;

// HL's m_flameX / m_flameY: the EASED aim residuals.  Half-Life runs both through
// UTIL_ApproachAngle at 4 deg (pitch) and 8 deg (yaw) per FlameUpdate call
// (gargantua.cpp:545-546), so the jet LAGS a moving target - that lag is what makes
// a sweep dodgeable rather than a homing beam.
.float garg_flamex, garg_flamey;

// One attachment, in world space.  '0 0 0' means "not available".
vector(entity m, float attach_idx) Garg_AttachPos =
{
	if (!m.garg_tagbase)
	{
		float sk = skel_create(m.modelindex);
		if (sk)
		{
			m.garg_tagbase = skel_get_numbones(sk);
			skel_delete(sk);
		}
		if (m.garg_tagbase <= 0)
			m.garg_tagbase = -1;

		// Once per body, because whether the DEDICATED server carries HL bone data at
		// all is the one thing about this path that cannot be settled by reading the
		// engine source - Mod_GetTag needs the model loaded with its skeleton, and
		// nothing in this tree had ever called gettaginfo from SSQC before.
		if (cvar("sv_ai_debug") || cvar("sv_debug_monsters"))
		{
			vector pr = (m.garg_tagbase > 0) ? gettaginfo(m, m.garg_tagbase + 2) : '0 0 0';
			dprint(sprintf("[garg] %s tagbase=%g attach1=%v rel=%v %s\n",
			               m.model, m.garg_tagbase, pr, pr - m.origin,
			               (m.garg_tagbase > 0 && pr != '0 0 0') ? "OK" : "FALLBACK"));
		}
	}
	if (m.garg_tagbase > 0)
	{
		// Tags are 1-based and the attachment block follows the bones, so
		// attachment N (0-based, as HL counts them) is tag numbones + 1 + N.
		vector p = gettaginfo(m, m.garg_tagbase + 1 + attach_idx);
		if (p != '0 0 0')
			return p;
	}
	return '0 0 0';
};

// UTIL_ApproachAngle (util.cpp): step `cur` toward `target` by at most `rate`.
// Both are already normalised residuals here, so no wrap handling is needed.
float(float target, float cur, float rate) Garg_ApproachAngle =
{
	float d = target - cur;
	if (d >  rate) d =  rate;
	if (d < -rate) d = -rate;
	return cur + d;
};

// gargantua.cpp:608-672, FlameDamage.  A CONE ALONG THE JET, not a sphere at the
// gargantua: HL searches a sphere centred on the MIDPOINT of the beam whose
// radius is half the beam's length, then falls damage off past 64 units from the
// nearest point on the jet.  So standing beside a gargantua is safe and standing
// three hundred units in front of one is not, which is the whole reason the
// attack has a shape worth implementing.
void(entity m, vector src, vector hit, float dmg) Garg_FlameDamage =
{
	vector mid = (src + hit) * 0.5;
	float  rad = vlen(hit - src) * 0.5;
	if (rad < 1)
		return;
	vector aim = normalize(hit - src);

	entity e = findradius(mid, rad);
	while (e)
	{
		entity nxt = e.chain;	// stash it: damage may remove or relink e

		// NO takedamage GATE, and this is the exact trap AI_BlastAttack documents
		// at sv_ai_combat.qc:236-243: players in this mod sit at DAMAGE_NO
		// permanently, so HL's `pev->takedamage != DAMAGE_NO` filter - which is
		// what this function started life with - excluded the only target that
		// matters and nothing else.  Measured on the first run: the flame reported
		// 222 ticks and hits=0 while the gargantua's stomp went on landing damage,
		// which reads exactly like "the flame does no damage" and actually meant
		// "the flame cannot see players".  W_ApplyDamage asks W_CanDamageTarget,
		// which is the authority.
		if (e != m && e.health > 0
		    && e.ai_class != CLASS_ALIEN_MONSTER)	// HL's iClassIgnore
		{
			vector spot = e.origin + (e.mins + e.maxs) * 0.5;

			// Project onto the jet, clamp to its length, and measure from there.
			float d = (spot - mid) * aim;
			if (d >  rad) d =  rad;
			if (d < -rad) d = -rad;
			vector on = mid + aim * d;

			traceline(on, spot, FALSE, m);
			if (trace_fraction == 1 || trace_ent == e)
			{
				float off = vlen(on - trace_endpos);
				float adj = dmg;
				if (off > 64)
					adj = dmg - (off - 64) * 0.4;
				if (adj > 0)
				{
					e.death_hitgroup = HITGROUP_GENERIC;
					W_ApplyDamage(m, e, adj);
					ai_dbg_garg_flamehits = ai_dbg_garg_flamehits + 1;
				}
			}
		}
		e = nxt;
	}
};

// One tick of the sweep: aim, trace, draw, burn.
void(entity m, float dt) Garg_FlameUpdate =
{
	ai_dbg_garg_flameticks = ai_dbg_garg_flameticks + 1;

	// Track the enemy WITHIN A CONE rather than turning the whole body: HL drives
	// bone controllers 0 and 1 off the residual yaw and pitch and clamps the yaw
	// to +/-45 (gargantua.cpp:534-548), so the gargantua sweeps its arms across a
	// target that is already roughly in front of it and does not spin.
	float ry = 0, rp = 0;
	if (m.ai_enemy)
	{
		ry = AI_AimResidualYaw(m, m.ai_enemy.origin);
		rp = AI_AimResidualPitch(m, m.origin + '0 0 64', m.ai_enemy.origin);
		if (ry >  45) ry =  45;
		if (ry < -45) ry = -45;
		// Pitch clamp is the MODEL's, not a guess: garg.mdl's bone controller 1 runs
		// -35..35 and FTE saturates a bounded controller silently, so an unclamped
		// residual would drive the arms to the stop while the jet kept climbing.
		if (rp >  35) rp =  35;
		if (rp < -35) rp = -35;
	}
	// Ease toward the target rather than snapping onto it - gargantua.cpp:545-546.
	m.garg_flamey = Garg_ApproachAngle(ry, m.garg_flamey, 8);
	m.garg_flamex = Garg_ApproachAngle(rp, m.garg_flamex, 4);
	AI_SetBoneControl(m, 0, m.garg_flamey);
	AI_SetBoneControl(m, 1, m.garg_flamex);
	ry = m.garg_flamey;
	rp = m.garg_flamex;

	// EMITTERS FIRST, AIM SECOND, and the order is load-bearing: gettaginfo sets
	// v_forward/v_right/v_up as a side effect, so sampling the hands after
	// makevectors would silently replace the aim basis with the last bone's.
	vector src_r = Garg_AttachPos(m, 1);	// attachment 1 - Bip01 R Arm2
	vector src_l = Garg_AttachPos(m, 2);	// attachment 2 - Bip01 L Arm2

	// PITCH GOES INTO THE AIM.  HL builds vecAim = angles + (m_flameX, m_flameY)
	// and only then calls UTIL_MakeVectors (gargantua.cpp:564-571), so the beam and
	// the damage cone tilt with the arms.  This used to pass [0, yaw, 0], which
	// drove the bone controller but left the jet pinned to the horizontal - a
	// gargantua on a catwalk burned the air over your head.  QC pitch is
	// negative-up, and AI_AimResidualPitch returns positive-up, so negate.
	makevectors([-rp, m.angles_y + ry, 0]);

	float dmg = cvar("sv_ai_garg_dmg_fire");
	if (dmg <= 0)
		dmg = 4;			// Sven skill.cfg sk_gargantua_dmg_fire
	dmg = dmg * m.ai_dmg_scale;

	// Per TICK, not per second, exactly as HL does it - FlameUpdate runs off the
	// monster think and applies the skill figure each time.  Scaled by dt anyway
	// so the burn does not change strength if AI_TICK ever moves.
	dmg = dmg * (dt / 0.1);

	vector base = m.origin;
	base_z = base_z + m.mins_z + (m.maxs_z - m.mins_z) * GARG_FLAME_UP;

	// The SDK's own numbers, and every one of them was unrepresentable in the
	// particle recipe this replaces (r_part's beam type has no sprite, no width,
	// no brightness and no scroll):
	//   beams 0-1  xbeam3.spr, width 240 (24.0u), rgb 255 130 90, bright 190
	//   beams 2-3  xbeam3.spr, width 140 (14.0u), rgb 0 120 255,  bright 190
	//   both       SetScrollRate(20)  <- the texture SCROLLS, which is what sells
	//                                    it as flowing flame rather than a bar
	// gargantua.cpp:503-522.  Noise is 0: FlameCreate never calls SetNoise, so the
	// jet is straight and the flicker comes from the scrolling texture.
	float sprite = getmodelindex(GARG_FLAME_SPRITE);

	// Drop stale handles first.  HLBeam_EntUpdate arms a 0.3 s dead-man timer on
	// every refresh (sh_hlbeamfx.qc:164-165), which is what stops a beam outliving
	// a gargantua that dies mid-sweep - but it removes the ENTITY without telling
	// us, so these fields can point at a freed edict by the time a later sweep
	// starts. Handing one of those back to HLBeam_EntUpdate would have it reuse a
	// freed slot instead of spawning a fresh beam.
	if (m.garg_beam_l  && wasfreed(m.garg_beam_l))   m.garg_beam_l  = world;
	if (m.garg_beam_r  && wasfreed(m.garg_beam_r))   m.garg_beam_r  = world;
	if (m.garg_beam_lc && wasfreed(m.garg_beam_lc))  m.garg_beam_lc = world;
	if (m.garg_beam_rc && wasfreed(m.garg_beam_rc))  m.garg_beam_rc = world;

	float i;
	for (i = -1; i <= 1; i = i + 2)
	{
		// i < 0 is the LEFT beam, which is HL's attachment 2; i > 0 is the right,
		// attachment 1.  Fall back to the hull construction only if the model has no
		// attachment there.
		vector src = (i < 0) ? src_l : src_r;
		if (src == '0 0 0')
			src = base + v_right * (i * GARG_FLAME_SIDE) + v_forward * 16;

		traceline(src, src + v_forward * GARG_FLAME_LENGTH, FALSE, m);
		vector hit = trace_endpos;

		// The blue core starts 40% down the jet, not at the hand:
		// m_pFlame[i+2]->SetStartPos((vecStart * 0.6) + (trace.vecEndPos * 0.4))
		// gargantua.cpp:576.
		vector core_src = src * 0.6 + hit * 0.4;

		if (i < 0)
		{
			m.garg_beam_l  = HLBeam_EntUpdate(m.garg_beam_l,  m, src,      hit, sprite,
			                                  '255 130 90', 190, 240, 0, 20, 0);
			m.garg_beam_lc = HLBeam_EntUpdate(m.garg_beam_lc, m, core_src, hit, sprite,
			                                  '0 120 255',  190, 140, 0, 20, 0);
		}
		else
		{
			m.garg_beam_r  = HLBeam_EntUpdate(m.garg_beam_r,  m, src,      hit, sprite,
			                                  '255 130 90', 190, 240, 0, 20, 0);
			m.garg_beam_rc = HLBeam_EntUpdate(m.garg_beam_rc, m, core_src, hit, sprite,
			                                  '0 120 255',  190, 140, 0, 20, 0);
		}

		Garg_FlameDamage(m, src, hit, dmg);
	}
};

// End of sweep: put the arms back.  Separate from the task's completion so the
// same shutdown runs if the schedule is ever ended another way.
void(entity m) Garg_FlameOff =
{
	AI_SetBoneControl(m, 0, 0);
	AI_SetBoneControl(m, 1, 0);
	// ...and the eased residuals with them, or the next sweep would start already
	// aimed wherever the last one ended and skip its own approach.
	m.garg_flamex = 0;
	m.garg_flamey = 0;

	// FlameDestroy, gargantua.cpp:677-690 - UTIL_Remove on all four.  This is the
	// half a persistent beam needs that a re-emitted particle effect did not: the
	// old version simply stopped multicasting and the last puff aged out on its
	// own, so there was nothing to tear down.  Miss this and the jet stays lit,
	// welded to the gargantua, forever.
	// wasfreed-guarded for the same reason the update path is: the dead-man timer
	// may already have taken the entity, and HLBeam_EntKill's `if (b)` test is true
	// for a freed edict, so an unguarded remove() here would be a double free.
	if (m.garg_beam_l  && !wasfreed(m.garg_beam_l))   HLBeam_EntKill(m.garg_beam_l);
	if (m.garg_beam_r  && !wasfreed(m.garg_beam_r))   HLBeam_EntKill(m.garg_beam_r);
	if (m.garg_beam_lc && !wasfreed(m.garg_beam_lc))  HLBeam_EntKill(m.garg_beam_lc);
	if (m.garg_beam_rc && !wasfreed(m.garg_beam_rc))  HLBeam_EntKill(m.garg_beam_rc);
	m.garg_beam_l = world;  m.garg_beam_r  = world;
	m.garg_beam_lc = world; m.garg_beam_rc = world;
};

// CGargantua::CheckMeleeAttack2, gargantua.cpp:934-947.  A BAND, not a radius:
// too close and it slashes instead, too far and the jet does not reach.
float() Garg_SelectSched =
{
	if (self.ai_state != MS_COMBAT || !self.ai_enemy)
		return SCHED_NONE;
	if (time < self.ai_flametime)
		return SCHED_NONE;
	if (!(self.ai_cond & COND_SEE_ENEMY))
		return SCHED_NONE;

	float d = vlen(self.ai_enemy.origin - self.origin);
	if (d <= GARG_FLAME_MINDIST || d > GARG_FLAME_LENGTH)
		return SCHED_NONE;

	makevectors([0, self.angles_y, 0]);
	vector to = self.ai_enemy.origin - self.origin;
	to_z = 0;
	if (to == '0 0 0')
		return SCHED_NONE;
	if ((v_forward * normalize(to)) < GARG_FLAME_DOT)
		return SCHED_NONE;

	ai_dbg_garg_flames = ai_dbg_garg_flames + 1;
	return SCHED_GARG_FLAME;
};

float(entity m, float act) Garg_YawSpeed =
{
	// 180 on a dedicated turn against 60 for everything else - the gargantua
	// plants and pivots rather than steering, which is exactly how it reads.
	if (act == ACT_TURN_LEFT || act == ACT_TURN_RIGHT)	return 180;
	return 60;
};

// PrescheduleThink, gargantua.cpp:693-703.  While the enemy is out of sight the
// stomp timer keeps being pushed five seconds out, so a gargantua must have held
// you in view CONTINUOUSLY for that long before its first stomp - and twelve
// seconds pass between them (:1011-1014).  Without this the port stomped roughly
// three times as often as Half-Life does.
//
// Withdrawing the range band is how the gate is applied, because the stomp is this
// class's only RANGE attack and COND_CAN_RANGE1 is set from ai_range_range in the
// condition pass.  The class hook runs BEFORE conditions are gathered, so it takes
// effect on the same tick.  Melee is deliberately untouched: HL's m_seeTime gates
// CheckRangeAttack1 and never CheckMeleeAttack1, so the slash stays available.
void() Garg_Tick =
{
	// Resolve the attachment tag base on the first tick rather than waiting for a
	// flame sweep, so the one-shot probe in Garg_AttachPos reports whether the
	// server can evaluate this model's skeleton even on a map where no gargantua
	// ever gets a target.
	if (!self.garg_tagbase)
		Garg_AttachPos(self, 1);

	if (!self.ai_enemy || !(self.ai_cond & COND_SEE_ENEMY))
		self.ai_seetime = time + GARG_STOMP_SIGHT;

	if (time >= self.ai_seetime)
		self.ai_range_range = self.garg_range;
	else
		self.ai_range_range = 0;
};

void(entity m) Garg_CommonInit =
{
	m.ai_class       = CLASS_ALIEN_MONSTER;
	m.ai_melee_range = 110;			// it is enormous; so is its reach
	m.ai_range_range = 400;			// the stomp
	m.garg_range     = 400;			// remembered so Garg_Tick can withdraw and restore it
	m.ai_tick        = Garg_Tick;
	m.ai_seetime     = time + GARG_STOMP_SIGHT;
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
	m.ai_selectsched = Garg_SelectSched;
	m.ai_snd_idle    = SND_GARG_IDLE;
	m.ai_snd_alert   = SND_GARG_ALERT;
	m.ai_snd_pain    = SND_GARG_PAIN;
	m.ai_snd_die     = SND_GARG_DIE;
	m.ai_snd_pitch   = 10;			// gargantua.cpp uses PITCH_NORM +/- 10
	if (m.bloodcolor == 0)
		m.bloodcolor = -1;		// HL gargantua does not bleed
};

void(entity m) Gargantua_ClassInit = { Garg_CommonInit(m); };

void(entity m) Babygarg_ClassInit =
{
	Garg_CommonInit(m);
	// Its own voice, out of svencoop's sound/babygarg/ - see the SND_BGARG_* block
	// at the top of this file.  Must come after CommonInit, which installs the
	// adult's families.
	if (garg_hasbabyvoice)
	{
		m.gar_isbaby   = TRUE;
		m.ai_snd_idle  = SND_BGARG_IDLE;
		m.ai_snd_alert = SND_BGARG_ALERT;
		m.ai_snd_pain  = SND_BGARG_PAIN;
		m.ai_snd_die   = SND_BGARG_DIE;
	}
	// Same rig at a smaller scale: shorter reach, less damage, quicker.
	m.ai_melee_range = 80;
	m.ai_range_range = 250;
	m.garg_range     = 250;
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
		d = 12;			// sk_stukabat_dmg_bite
	// ai_melee_range, NOT a second hardcoded number.  COND_CAN_MELEE1 is gated on
	// ai_melee_range, so a shorter literal here means the attack triggers at a
	// distance the swing cannot actually reach - which is exactly what happened:
	// gated at 80, swung 60, ten attacks and zero contact.
	AI_MeleeHull(self, self.ai_melee_range, d, 16);
	// The one sample svencoop ships for this class.  Sixty placements whose entire
	// audible presence was nothing at all until this line.
	if (!self.gag)
		AI_SoundEx(self, CHAN_WEAPON, SND_STUKA_FLAP, 1, ATTN_NORM,
		      90 + floor(random() * 21), 0);
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
	if (m.bloodcolor == 0)
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
		d = 40;			// sk_kingpin_melee
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

	// Guarded on the model for the same reason the gearbox aliens are: kingpin.mdl
	// and its voice ship in the same mount, so a machine that lacks one lacks both.
	if (m.model == "models/kingpin.mdl")
	{
		m.ai_snd_idle  = SND_KING_IDLE;
		m.ai_snd_alert = SND_KING_ALERT;
		m.ai_snd_pain  = SND_KING_PAIN;
		m.ai_snd_die   = SND_KING_DIE;
	}
	if (m.bloodcolor == 0)
		m.bloodcolor = 195;
};

float() Gargantua_DefaultHealth
	= { float h = cvar("sv_ai_garg_health");     return (h > 0) ? h : 800; };
// The three below are Sven/OpFor-only classes, so the fallbacks are Sven Co-op's
// own skill.cfg (sk_babygargantua_health, sk_stukabat, sk_kingpin_health) rather
// than a number picked to look right beside the gargantua's.  See the block in
// sh_cvar_table.qc for why these three in particular were badly out.
float() Babygarg_DefaultHealth
	= { float h = cvar("sv_ai_babygarg_health"); return (h > 0) ? h : 600; };
float() Stukabat_DefaultHealth
	= { float h = cvar("sv_ai_stukabat_health"); return (h > 0) ? h : 123; };
float() Kingpin_DefaultHealth
	= { float h = cvar("sv_ai_kingpin_health");  return (h > 0) ? h : 450; };
