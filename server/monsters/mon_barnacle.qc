// server/monsters/mon_barnacle.qc
// ----------------------------------------------------------------------------
// monster_barnacle  —  183 placements.
//
// A ceiling hazard, not a fighter: it hangs, drops a tongue, and eats whatever
// walks underneath.  Three things make it unlike every other class so far.
//
// IT HAS NO ATTACK EVENTS.  Every other monster in this programme takes its
// damage timing from the model — the grunt's three burst codes, the houndeye's
// thump at 2.36 s, the turret's muzzleflashes.  barnacle.mdl's attack1 carries
// NONE, so the tongue has to be driven from QC.  That is why the damage lives in
// the per-tick class hook below rather than in an .ai_event handler.
//
// IT IS THE ONLY CLASS THAT MUST NOT DROP TO THE FLOOR.  AIMODE_STATIC skips
// droptofloor entirely, which is the specific bug that mode was built to prevent
// back in W1c: a ceiling barnacle placed 200 units up would otherwise land on the
// ground and hang its tongue into the floor.
//
// models/barnacle.mdl (7 sequences, 1 bone controller), read out of the file:
//   [0] idle1 act 1 61f@15   [1] idle2 act 1 (two code-1 events)
//   [2] idle3 act 1 LOOP     [3] flinch_sm act 26
//   [4] attack1 act 0 (!) 51f@30 LOOP   <- the ONLY untagged sequence
//   [5] chewcycle act 35 = ACT_EAT LOOP
//   [6] death act 36 101f@15, four code-2 events
//
// The plan recorded this model as having "no activities"; measuring it showed the
// opposite — everything except attack1 is tagged, so only that one sequence needs
// AI_SetSequenceNamed and the rest resolve normally.  ACT_BARNACLE_HIT/PULL/
// CHOMP/CHEW (40-43) are the VICTIM's activities, played by whatever is being
// eaten, and are not in this model at all.
//
// HONEST LIMITATION: the tongue is not drawn and the victim is not lifted.  Both
// want the bone controller that sets tongue length, which is the W1a engine
// patch; hijacking a player's movement to haul them upward without that would be
// a lot of invasive code for something that would then look wrong anyway.  What
// is implemented is the part that matters for play: standing under a barnacle
// hurts, continuously, and the thing visibly chews while it happens.
// ----------------------------------------------------------------------------

const float BARN_TONGUE_MAX  = 512;	// how far down it can reach
// Resting droop with nothing in the column.  barnacle.mdl's controller range goes
// to -1024, but a tongue hanging half a map down looks like a bug; HL's idle
// barnacle dangles a short length and reels it in and out.
const float BARN_TONGUE_REST = 64;
const float BARN_BITE_GAP    = 0.5;	// seconds between damage ticks
const float BARN_HULL_R      = 12;	// tongue column radius

void() Barnacle_Precache =
{
	precache_model("models/barnacle.mdl");
	precache_sound("barnacle/bcl_chew1.wav");
	precache_sound("barnacle/bcl_chew2.wav");
	precache_sound("barnacle/bcl_chew3.wav");
	precache_sound("barnacle/bcl_bite3.wav");
	precache_sound("barnacle/bcl_die1.wav");
	precache_sound("barnacle/bcl_die3.wav");
};

// What is hanging in the tongue's column right now, or world.
//
// A downward tracebox rather than a traceline: the tongue is a physical thing
// with width, and a line would let a player stand half-under a barnacle and take
// nothing.  MOVE_NORMAL so world geometry blocks it — a barnacle over a catwalk
// must not reach through the catwalk to the floor below.
entity(entity m) Barnacle_FindVictim =
{
	vector src = m.origin;
	vector dst = src - '0 0 1' * BARN_TONGUE_MAX;
	vector hs  = '1 1 0' * BARN_HULL_R;

	tracebox(src, '0 0 0' - hs, hs, dst, MOVE_NORMAL, m);

	entity hit = trace_ent;
	if (!hit || hit == world || hit == m)
		return world;
	if (hit.health <= 0)
		return world;
	if (hit.takedamage != DAMAGE_YES && hit.classname != "player")
		return world;
	// Never eat its own kind, and never eat another barnacle's meal.
	if (hit.classname == m.classname)
		return world;
	return hit;
};

// The per-tick class hook (.ai_tick).  This monster is the reason that hook
// exists: its damage cannot come from an anim event because attack1 carries none,
// and it cannot come from ai_checkattack because that only fires when an attack
// condition is already set - which needs a non-zero attack range, which a barnacle
// deliberately does not have.  Measured before the hook existed: the tongue check
// ran ZERO times while the class oscillated between two schedules 295 times.
void() Barnacle_Tick =
{
	entity v = Barnacle_FindVictim(self);

	self.ai_victim = v;

	// THE TONGUE, now that bone controllers reach the client (W1a, Patch 125).
	//
	// barnacle.mdl's single controller is type 0x0002 - a TRANSLATION, not a
	// rotation - with a range of -1024..0, so the value is in world units and
	// NEGATIVE is further down.  It is not degrees and it is not normalised; the
	// engine passes it straight through (gl_hlmdl.c:990, the non-rotation branch).
	//
	// Driven from the same trace that found the victim, so the drawn tongue ends
	// exactly where the damage is applied rather than approximately near it.
	// With no victim it hangs at its resting length instead of snapping to zero,
	// which is what a barnacle looks like when nothing has wandered under it.
	float reach;
	if (v)
		reach = self.origin_z - v.origin_z;
	else
		reach = BARN_TONGUE_REST;
	self.bonecontrol1 = 0 - bound(0, reach, BARN_TONGUE_MAX);

	if (!v)
		return;			// nothing in the column; the idle schedule handles it

	// A barnacle does not care about line of sight, hearing or range: if you are
	// in the column, you are food.  It has no eyes, so it never consults the
	// sighting path at all - which is exactly why the victim lives in its own
	// field rather than in ai_enemy.
	//
	// COND_SEE_ENEMY is asserted purely so the idle schedule's interrupt mask can
	// react on the same tick; nothing here reads it as "I can see something".
	self.ai_cond = self.ai_cond | COND_SEE_ENEMY;

	if (time < self.ai_nextattack)
		return;
	self.ai_nextattack = time + BARN_BITE_GAP;

	float d = cvar("sv_ai_barnacle_dmg");
	if (d <= 0)
		d = 10;
	W_ApplyDamage(self, v, d);

	if (!self.gag)
		sound(self, CHAN_WEAPON, sprintf("barnacle/bcl_chew%g.wav", ceil(random() * 3)), 1, ATTN_NORM);
};

float() Barnacle_SelectSched =
{
	if (self.ai_state == MS_DEAD)
		return SCHED_NONE;

	if (self.ai_victim)
		return SCHED_BARNACLE_CHOMP;
	return SCHED_BARNACLE_IDLE;
};

void() Barnacle_Death =
{
	if (!self.gag)
		sound(self, CHAN_VOICE, (random() < 0.5) ? "barnacle/bcl_die1.wav" : "barnacle/bcl_die3.wav", 1, ATTN_NORM);
};

void(entity m) Barnacle_ClassInit =
{
	m.ai_class = CLASS_ALIEN_MONSTER;

	// STATIC: bolted to the ceiling.  See the header — this is the class the mode
	// was designed around.
	m.ai_movemode = AIMODE_STATIC;

	// Both ranges zero: the generic ladder must never offer it an attack schedule.
	// Everything it does is driven by Barnacle_SelectSched instead.
	m.ai_melee_range = 0;
	m.ai_range_range = 0;
	m.ai_yaw_speed   = 0;			// it does not turn; it hangs

	m.ai_selectsched = Barnacle_SelectSched;
	m.ai_tick        = Barnacle_Tick;
	m.ai_death       = Barnacle_Death;

	if (m.bloodcolor <= 0)
		m.bloodcolor = 195;
};

float() Barnacle_DefaultHealth
	= { float h = cvar("sv_ai_barnacle_health"); return (h > 0) ? h : 25; };
