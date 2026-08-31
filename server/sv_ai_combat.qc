// server/sv_ai_combat.qc
// ----------------------------------------------------------------------------
// How a monster hurts things: hitscan, beams, blasts, projectiles and melee.
//
// There was NO monster-callable attack primitive before this file.  Every
// existing one is written for players and reads .v_angle / .view_ofs and a
// lag-compensation history that a monster does not have:
//
//   W_WeaponTraceLine (sv_weapons.qc:832) goes through Lagcomp_TraceLine, which
//   rewinds every other player to the SHOOTER'S VIEW TIME.  A monster has no
//   view time and no command history, so there is nothing to rewind to.  Worse,
//   rewinding for an entity that never had a recorded view would either no-op or
//   apply somebody else's timeline.  Monsters therefore use a plain traceline -
//   which is also what Half-Life does: CBaseMonster::FireBullets is an ordinary
//   UTIL_TraceLine against hulls, with no client-side compensation anywhere.
//
//   That also means no per-hitgroup damage for monsters, which is correct: HL
//   monsters cannot land headshots and neither can these.
//
// Everything below takes the shooter as an explicit `m` parameter rather than
// reading `self`.  The AI dispatches its virtuals with self already switched, so
// self would usually be right - but "usually" is how a squad member's tracer
// ends up anchored on its leader, and the explicit parameter costs nothing.
// ----------------------------------------------------------------------------

// A monster's eye/muzzle height as a fraction of its hull.  HL uses a per-model
// attachment point; gettaginfo exists here (sv_defs.qc:1548) but HL .mdl
// attachments are not exposed through it, so the hull is the honest source.
// Two thirds up the bounding box is where a humanoid's weapon sits and where a
// crab's mouth is, and it degrades sanely for anything in between.
const float AI_MUZZLE_FRAC  = 0.66;
const float AI_MUZZLE_FWD   = 12;	// forward of the origin, clear of the own hull
const float AI_BULLET_RANGE = 4096;

// ---------------------------------------------------------------------------
// geometry
// ---------------------------------------------------------------------------
vector(entity m) AI_MuzzlePos =
{
	vector p = m.origin;
	p_z = p_z + m.mins_z + (m.maxs_z - m.mins_z) * AI_MUZZLE_FRAC;

	// Push forward along the FACING, not along the aim: a monster's body does
	// not pitch, so lifting the muzzle out of the hull is a yaw-plane job.
	makevectors('0 1 0' * m.angles_y);
	vector fwd = p + v_forward * AI_MUZZLE_FWD;

	// Never let the push put the muzzle inside geometry - a monster with its back
	// to a wall would otherwise fire from the far side of it.
	traceline(p, fwd, MOVE_NORMAL, m);
	if (trace_fraction < 1)
		return p;
	return fwd;
};

// Where to aim ON a target.  Centre of hull rather than origin: a player's origin
// is at their feet, and a monster aiming there would shoot the floor.
vector(entity targ) AI_AimPoint =
{
	vector p = targ.origin;
	if (targ.classname == "player")
		return p + targ.view_ofs - '0 0 4';	// chest, not eyes
	p_z = p_z + targ.mins_z + (targ.maxs_z - targ.mins_z) * 0.75;
	return p;
};

// Unit aim direction, with a cone of `spread` (HL's vecSpread convention: the
// value is the sine of the half-angle, so 0.08716 is 5 degrees).
vector(entity m, vector src, entity targ, float spread) AI_AimDir =
{
	vector d = AI_AimPoint(targ) - src;
	if (d == '0 0 0')
		d = '1 0 0';
	d = normalize(d);

	if (spread > 0)
	{
		// Build the cone in the AIM basis, not the world one: offsetting in world
		// x/y would make vertical shots spread sideways only.
		// No crandom() in this codebase's defs; (random()*2 - 1) is the same
		// [-1,+1] roll and is what the shotgun spread already uses.
		makevectors(vectoangles(d));
		d = d + v_right * ((random() * 2 - 1) * spread)
		      + v_up    * ((random() * 2 - 1) * spread);
		d = normalize(d);
	}
	return d;
};

// ---------------------------------------------------------------------------
// hitscan
// ---------------------------------------------------------------------------
// Diagnostics: "the monster plays its fire animation but nothing happens" has
// several causes that look identical from outside - no trace, a trace that hits
// nothing, or damage refused by W_CanDamageTarget - and they want different
// fixes.  Same reasoning as the movement counters in sv_ai_move.qc.
float ai_dbg_shots, ai_dbg_shothits, ai_dbg_shotdmg;

// One bullet.  Returns TRUE if it hit something damageable.
float(entity m, vector src, vector dir, float dmg) AI_FireBullet =
{
	ai_dbg_shots = ai_dbg_shots + 1;

	traceline(src, src + dir * AI_BULLET_RANGE, MOVE_NORMAL, m);
	if (trace_fraction >= 1)
		return FALSE;			// open sky / nothing in range

	entity hit = trace_ent;
	float  landed = FALSE;

	if (hit && hit != world && hit != m)
	{
		if (hit.takedamage == DAMAGE_YES || hit.classname == "player")
		{
			if (W_ApplyDamage(m, hit, dmg))
			{
				landed = TRUE;
				ai_dbg_shothits = ai_dbg_shothits + 1;
				ai_dbg_shotdmg  = ai_dbg_shotdmg + dmg;
			}
		}
	}

	// Impact FX last, so W_ClassifyImpactMaterial sees the trace this shot made
	// rather than whatever W_ApplyDamage's own traces left behind.  Re-establish
	// the trace globals for exactly that reason.
	traceline(src, src + dir * AI_BULLET_RANGE, MOVE_NORMAL, m);
	W_ImpactEffectFrom(trace_endpos, trace_plane_normal,
	                   W_ClassifyImpactMaterial(trace_ent), m);
	return landed;
};

// A burst from the muzzle toward the current enemy.  The structural template is
// W_ShotgunFirePellets (sh_wpn_hlshotgun.qc:192): one trace per pellet, each with
// its own spread roll.
float(entity m, entity targ, float count, float spread, float dmg) AI_FireBullets =
{
	if (!targ)
		return 0;

	// PER-SHOT ID, and its absence is the whole of "do NPC bullets leave bullet
	// holes?".  W_ImpactEffectSend puts shooter.wep_action_id on the wire
	// (sv_weapons.qc:959) and the client's per-shot decal cap keys on it:
	// CSQC_BulletHole_CapAllows (cl_bulletholes.qc:1870-1889) only resets its
	// counter when the key CHANGES, and cl_bulletholes_per_shot defaults to 1.
	//
	// Nothing outside the player fire path ever incremented this field, so every
	// round a given monster fired shipped action = 0 and the key was a constant
	// for that monster's whole life.  The first bullet it ever fired left a hole
	// and every one after it was silently dropped - along with its impact debris
	// and chips, which throttle on the same value
	// (cl_bulletimpact.qc:1396-1410, :1015-1017).
	//
	// Incremented once per BURST rather than per pellet, which is what the cap
	// means by "shot": a shotgun blast is one trigger pull.
	m.wep_action_id = m.wep_action_id + 1;

	// THE MUZZLE FLASH.  Half-Life sets pev->effects = EF_MUZZLEFLASH on every
	// monster shot (barney.cpp:353, hgrunt.cpp and the rest), and a grep for
	// EF_MUZZLEFLASH across this whole server returned nothing at all - so no
	// humanoid in the game has ever flashed.  In a dark They Hunger corridor that
	// is the difference between "something is shooting at me from somewhere" and
	// knowing where.
	//
	// te_muzzleflash rather than the .effects bit, and that is not a style
	// preference: EF_MUZZLEFLASH is NQ-only (pr_cmds.c:13849 tags it NQ|CS, and
	// server.h:1039 has it commented out for QW).  This is a QW mod, and the
	// builtin is exactly the compatibility shim for that - PF_te_muzzleflash sends
	// svc_muzzleflash to the PHS on QW and sets the effects bit on NQ.
	te_muzzleflash(m);

	vector src = AI_MuzzlePos(m);
	float  i, hits = 0;

	for (i = 0; i < count; i = i + 1)
	{
		if (AI_FireBullet(m, src, AI_AimDir(m, src, targ, spread), dmg))
			hits = hits + 1;
	}
	return hits;
};

// ---------------------------------------------------------------------------
// beams
// ---------------------------------------------------------------------------
// monster_alien_slave (726 placements, the #2 class in the whole corpus) is the
// consumer.  The visual rides the existing HL beam event, which is why W1b had
// to widen its owner field first: at a byte, a slave's edict number truncated and
// the beam anchored on whatever occupied slot (n & 255).
float(entity m, entity targ, float kind, float dmg) AI_FireBeam =
{
	if (!targ)
		return FALSE;

	vector src = AI_MuzzlePos(m);
	vector dir = AI_AimDir(m, src, targ, 0);

	traceline(src, src + dir * AI_BULLET_RANGE, MOVE_NORMAL, m);

	HLBeam_Multicast(kind, m, src, trace_endpos);

	entity hit = trace_ent;
	if (hit && hit != world && hit != m
	    && (hit.takedamage == DAMAGE_YES || hit.classname == "player"))
	{
		W_ApplyDamage(m, hit, dmg);
		return TRUE;
	}
	return FALSE;
};

// ---------------------------------------------------------------------------
// blasts
// ---------------------------------------------------------------------------
// The houndeye's sonic attack and, later, the gargantua's stomp.
//
// NOT a W_RadiusExplode wrapper, and the reason is worth stating: that function
// damages everything in the sphere, so a pack of houndeyes blasting at a player
// shreds itself.  Measured before this loop existed: five of eight spawned
// houndeyes were dead inside 45 seconds, killed by each other.  Half-Life does
// not use RadiusDamage here either - CHoundeye::SonicAttack walks entities in the
// sphere by hand for exactly this reason.
//
// Same-classname is the exclusion rather than the CLASS_* faction, deliberately:
// factions arrive with the ally work, and until then "my own kind" is the honest
// and conservative rule - it never protects something it should not.
void(entity m, float radius, float peak, float mindmg) AI_BlastAttack =
{
	entity e = findradius(m.origin, radius);

	while (e)
	{
		entity nxt = e.chain;		// stash it: damage may remove/relink e

		// NO takedamage GATE.  Every other attack primitive in this file carries
		// the "|| classname == player" escape hatch (AI_FireBullet:113,
		// AI_FireBeam:173, AI_ProjTouch:251, AI_MeleeHull:340) because players in
		// this mod sit at DAMAGE_NO permanently; this one never got it, so the
		// houndeye's sonic blast has never once hurt a player.  Dropping the test
		// entirely is better than adding a third copy of the hatch: W_ApplyDamage
		// already asks W_CanDamageTarget, which is the authority.
		if (e != m && !(e.flags & FL_MONSTER && e.classname == m.classname))
		{
			float d = W_LinearDamageFalloff(vlen(e.origin - m.origin),
			                                peak, mindmg, radius);

			// Blocked by geometry?  A blast through a wall is the thing players
			// notice fastest and complain about loudest.
			traceline(AI_MuzzlePos(m), e.origin + (e.mins + e.maxs) * 0.5,
			          MOVE_NOMONSTERS, m);
			if (trace_fraction < 1 && trace_ent != e)
			{
				// OCCLUDED.  Half-Life does not simply drop it: houndeye.cpp:643-657
				// gives a PLAYER half damage through cover and everything else none,
				// which is what stops "I was clearly behind a crate" from also being
				// "so it did nothing at all" - the blast is a pressure wave.
				if (e.classname != "player")
					d = 0;
				else
					d = d * 0.5;
			}

			if (d > 0)
			{
				// A sonic blast is DMG_SONIC|DMG_ALWAYSGIB in HL (houndeye.cpp:663),
				// and the damage type is what decides whether a corpse in the radius
				// bleeds or comes apart.
				sv_dmg_bits = DMG_SONIC;
				W_ApplyDamage(m, e, d);
			}
		}

		e = nxt;
	}
};

// ---------------------------------------------------------------------------
// projectiles
// ---------------------------------------------------------------------------
// A plain server-side entity, NOT the PROJ_TYPE_* system the player weapons use.
//
// That system exists so CSQC can predict and draw a player's own projectile: the
// type byte goes on the wire and the client derives model and gravity from
// Projectile_TypeModel / Projectile_TypeGravity.  A monster's projectile is never
// predicted by anybody, so all that would buy is two more table entries per
// monster and a wire format to keep in sync.  An ordinary networked entity with a
// model is simpler, needs no protocol change at all, and is what Quake monsters
// have always used.
//
// MOVETYPE_FLYMISSILE rather than MOVETYPE_FLY: it is the one movetype that does
// a full-extent trace per frame, so a fast spike cannot tunnel through a player.
//
// Its own damage field: this codebase has no generic .dmg (the RPG carries its
// payload in a per-weapon constant instead), and borrowing an unrelated float
// would collide the first time a monster projectile touched something that uses
// the same slot for its own purpose.
.float ai_proj_dmg;
// ALIENFX_* PLUS ONE for the effect this projectile leaves where it lands, or 0
// for none.  Plus-one because 0 is a valid kind and an unset field is also 0 -
// the same shape sv_proj_test's cvar uses, for the same reason.
//
// Set by the launcher's caller rather than taken as a parameter here: only the
// class knows whether its projectile is a glob of acid or a hornet, and adding a
// parameter would have made every existing caller name one.
.float ai_proj_fx;

void() AI_ProjTouch =
{
	if (other == self.owner)
		return;				// never hit the monster that fired it

	if (other && (other.takedamage == DAMAGE_YES || other.classname == "player"))
	{
		// The owner is the attacker, so kills credit
		// the monster rather than the world.
		W_ApplyDamage(self.owner, other, self.ai_proj_dmg);
		// ...NoTracer, and this is the whole of the "a bullet trace comes from the
		// bullsquid and hits where the spit landed" report.  W_ImpactEffectFrom
		// hard-codes is_entry = 1, i.e. "a bullet travelled this line, draw the
		// streak", and the client duly anchored one on the owner's muzzle through
		// Montrace_ResolveMuzzle.  A projectile flew here as a visible entity; there
		// is no line to draw.  The owner is still passed, because .wep_action_id is
		// what buckets the remote per-shot decal cap.
		//
		// Four monsters route through this touch and all four had it: bullsquid
		// (mon_aliens.qc:317), alien grunt (:235 - five hornets a volley, so five
		// streaks), pitdrone (:391) and gonome (:486).
		W_ImpactEffectFromNoTracer(self.origin, normalize(self.origin - other.origin),
		                           W_ClassifyImpactMaterial(other), self.owner);
	}
	else
	{
		W_ImpactEffectFromNoTracer(self.origin, trace_plane_normal,
		                           W_ClassifyImpactMaterial(other), self.owner);
	}

	// Half-Life sprays the spit AGAIN where it lands (bullsquid.cpp:157-164), and
	// that second spray is the half that tells you a glob went past you rather
	// than through you.  Direction is the surface normal so the splash comes back
	// off the wall; on a body hit trace_plane_normal is whatever the impact trace
	// left, so fall back to straight up rather than to a stale value.
	if (self.ai_proj_fx > 0)
	{
		vector fxn = trace_plane_normal;
		if (fxn == '0 0 0')
			fxn = '0 0 1';
		AlienFX_Multicast(self.ai_proj_fx - 1, self.origin, fxn);
	}

	remove(self);
};

void() AI_ProjExpire =
{
	remove(self);
};

// `grav` is a multiplier: 0 flies flat (hornets, spikes), 0.5 arcs (spit).
entity(entity m, string mdl, vector dir, float speed, float dmg, float grav) AI_LaunchProjectile =
{
	entity p = spawn();

	// Same per-shot id as AI_FireBullets, for the same reason: AI_ProjTouch emits
	// its impact through W_ImpactEffectFrom naming the OWNER as shooter, so a
	// monster that never advances this leaves exactly one decal per lifetime no
	// matter how many spits or spikes it throws.
	m.wep_action_id = m.wep_action_id + 1;

	p.owner     = m;
	p.classname = "ai_projectile";
	p.movetype  = MOVETYPE_FLYMISSILE;
	p.solid     = SOLID_BBOX;
	p.ai_proj_dmg = dmg;

	setmodel(p, mdl);
	setsize(p, '0 0 0', '0 0 0');	// point hull: the trace does the work
	setorigin(p, AI_MuzzlePos(m));

	p.velocity = normalize(dir) * speed;
	p.angles   = vectoangles(p.velocity);
	p.gravity  = grav;		// 0 is not "default" here - MOVETYPE_FLYMISSILE
					// only applies gravity when this is non-zero

	p.touch     = AI_ProjTouch;
	p.think     = AI_ProjExpire;
	p.nextthink = time + 8;		// never leave one flying forever

	return p;
};

// ---------------------------------------------------------------------------
// melee
// ---------------------------------------------------------------------------
// Factored out of the working Zombie_ClawAttack, unchanged in behaviour.
//
// tracebox rather than traceline, and this is the part worth keeping: Half-Life's
// CheckTraceHullAttack sweeps a HULL, so a claw connects with a player who is
// beside the monster's centre line rather than exactly on it.  A traceline here
// makes melee monsters feel like they are missing constantly, because they are.
// HL's CheckTraceHullAttack sweeps `head_hull`, which on a GoldSrc BSP is
// (-16,-16,-18)..(16,16,18) — 36 units TALL, not 32.  The extra 2 units either
// side is not why the sweep was missing, but it is free correctness and the
// number is the model for the vertical slack below.
const float AI_MELEE_HULL_Z = 18;

// How far off the sweep's own vertical band the enemy's centre may sit before
// the sweep tilts to follow it.  Zero would mean "always aim at the enemy",
// which is wrong for a GROUND monster: HL's is a flat forward sweep, and a
// zombie that tracked its target in 3D would connect on lunges HL cannot make.
const float AI_MELEE_TILT_SLACK = 8;

entity(entity m, float reach, float dmg, float hullsize) AI_MeleeHull =
{
	vector src = m.origin;
	src_z = src_z + (m.maxs_z * 0.5);

	// Z is RAISED to HL's head_hull half-height, never lowered.  X/Y stay the
	// caller's number, because that is what each class was tuned against — and
	// so does Z for the classes that already ask for more: the gargantua and the
	// big foes sweep at 32 and the stukabat at 32, and clamping those DOWN to 18
	// would be a reach regression dressed up as a fidelity fix.  Only the 8/16
	// callers move, and they move upward.
	vector hs = '1 1 1' * hullsize;
	hs_z = max(hullsize, AI_MELEE_HULL_Z);

	vector end;
	if (m.ai_movemode != AIMODE_GROUND && m.ai_enemy)
	{
		// Volume modes sweep in 3D, at the enemy.  A flyer swinging along its yaw
		// plane can never touch anything: the stukabat hovers at its cruising
		// height and attacked eleven times without connecting once, because the
		// sweep was horizontal and the target was on the floor.  The same applies
		// to a swimmer biting something above or below it.
		vector d = AI_AimPoint(m.ai_enemy) - src;
		if (d == '0 0 0')
			d = '1 0 0';
		end = src + normalize(d) * reach;
	}
	else
	{
		makevectors('0 1 0' * m.angles_y);
		end = src + v_forward * reach;

		// GROUND USED TO BE A STRICTLY HORIZONTAL SWEEP, and that is the whole of
		// "zombies attack a slightly elevated player and the swing misses".
		//
		// The range test that SELECTS the attack is a 3D distance (AI_CheckAttacks
		// -> vlen(enemy - self)), so a player one step up at 60 units away is
		// comfortably "in melee range".  The sweep that has to cash that cheque
		// was pinned to the monster's own eye plane and spanned z +/- 16 from
		// there, so the claw passed under a player standing on anything taller
		// than a crate lip and the attack could never land — the monster swung,
		// the miss sound played, and it swung again forever.
		//
		// Half-Life gets away with the flat sweep because UTIL_MakeAimVectors
		// (util.cpp:157) feeds pev->angles.x into the forward vector, so a monster
		// that has pitched toward its enemy sweeps along that pitch.  This tree
		// keeps monster pitch at zero — nothing sets angles_x on a ground monster —
		// so the equivalent has to come from the target instead.
		//
		// The tilt only engages when the enemy's centre is genuinely outside the
		// hull's own vertical band.  On flat ground that test never fires and the
		// sweep is byte-for-byte the horizontal one the zombie, grunt, islave and
		// gargantua were verified against.
		if (m.ai_enemy)
		{
			vector aim = AI_AimPoint(m.ai_enemy);
			float dz = aim_z - src_z;
			if (fabs(dz) > hs_z + AI_MELEE_TILT_SLACK)
			{
				vector tilt = aim - src;
				if (tilt != '0 0 0')
					end = src + normalize(tilt) * reach;
			}
		}
	}

	// SWEEP PAST YOUR OWN SIDE, up to a couple of bodies deep.
	//
	// tracebox stops at the FIRST solid thing, and a mob of zombies crowding one
	// doorway means the first solid thing in front of a zombie is usually another
	// zombie.  That is the reported "their swing misses and they just hit each
	// other": the claw landed 20 damage on a squadmate, the squadmate's pain
	// sound played, and the player standing right behind it took nothing.
	//
	// Half-Life has the same single-hit trace and mostly dodges the problem
	// because its monsters push each other apart harder than this tree's do, so
	// the fix here is to skip what HL would never have wanted damaged rather than
	// to widen the sweep: a hit the attacker does not HATE is stepped over and the
	// trace resumes just past it.  Two skips is enough for any realistic pile-up
	// and bounds the cost at three traces per swing.
	//
	// The current ENEMY is never skipped even if the faction layer says otherwise
	// — a monster that has decided to attack something has already made that call.
	// The skip is done by making the friendly briefly non-solid and re-tracing
	// from the SAME start, not by advancing the start point past it.  Advancing
	// needs the blocker's depth along the sweep axis, which a trace does not
	// report, and guessing it either re-hits the same body or steps clean over
	// the player standing behind it.  World_ClipToLinks reads .solid live, so
	// clearing it is exact and costs no relink.
	entity skip1 = world, skip2 = world;
	float  ssol1 = 0,     ssol2 = 0;
	entity hit   = world;
	float  skips = 0;

	while (skips < 3)
	{
		tracebox(src, '0 0 0' - hs, hs, end, MOVE_NORMAL, m);
		hit = trace_ent;

		if (!hit || hit == world || hit == m)
		{
			hit = world;
			break;
		}

		if (hit.takedamage != DAMAGE_YES && hit.classname != "player")
		{
			// Solid but not damageable (a func_wall, a closed door): the claw is
			// stopped, exactly as in HL.
			hit = world;
			break;
		}

		if (hit == m.ai_enemy || !(hit.flags & FL_MONSTER) || AI_Hates(m, hit))
			break;

		if (skips == 0)      { skip1 = hit; ssol1 = hit.solid; hit.solid = SOLID_NOT; }
		else if (skips == 1) { skip2 = hit; ssol2 = hit.solid; hit.solid = SOLID_NOT; }
		else                 { hit = world; break; }
		hit   = world;
		skips = skips + 1;
	}

	if (skip1) skip1.solid = ssol1;
	if (skip2) skip2.solid = ssol2;

	if (hit != world)
	{
		W_ApplyDamage(m, hit, dmg);
		return hit;
	}
	return world;
};

// ---------------------------------------------------------------------------
// lobbed projectiles
// ---------------------------------------------------------------------------
// Half-Life's VecCheckToss and VecCheckThrow (combat.cpp), ported rather than
// approximated, because a grenade thrown on a made-up arc is worse than no
// grenade at all: it lands on the thrower.  Both return '0 0 0' for "no arc
// exists", and that refusal is the whole safety mechanism - the caller must
// treat zero as "do not throw", never as "throw with no velocity".
//
// Gravity here is sv_gravity scaled by the projectile's own .gravity, which for
// the HL hand grenade is 0.5.  Getting that factor wrong is silent: the arc
// simply lands short or long, and it looks like bad aim rather than bad maths.

// The lob.  Picks an apex above the midpoint, verifies both legs are clear, and
// solves the two half-flights independently - which is what lets the grenade
// arc OVER cover rather than through it.
vector(entity m, vector src, vector dest, float gravadj) AI_VecCheckToss =
{
	float g = cvar("sv_gravity") * gravadj;
	if (g <= 0)
		g = 800 * gravadj;

	if (dest_z - src_z > 500)
		return '0 0 0';			// too high above us to lob at

	vector mid = src + (dest - src) * 0.5;

	// How high the apex can be before it hits a ceiling.  MOVE_NOMONSTERS: a
	// squadmate standing under the arc must not veto it, only geometry may.
	traceline(mid, mid + '0 0 384', MOVE_NOMONSTERS, m);
	vector apex = trace_endpos - '0 0 15';
	if (apex_z <= src_z + 16 || apex_z <= dest_z + 16)
		return '0 0 0';			// no room to arc at all

	// Both legs must be clear.  The outgoing leg is traced against MONSTERS too,
	// because a grenade that clips the squadmate in front of you on the way up is
	// exactly the throw HL refuses.
	traceline(src, apex, MOVE_NORMAL, m);
	if (trace_fraction != 1)
		return '0 0 0';
	traceline(dest, apex, MOVE_NOMONSTERS, m);
	if (trace_fraction != 1)
		return '0 0 0';

	float d1 = apex_z - src_z;
	float d2 = apex_z - dest_z;
	float t1 = sqrt(d1 / (0.5 * g));
	float t2 = sqrt(d2 / (0.5 * g));
	if (t1 < 0.1)
		return '0 0 0';

	vector tv = (dest - src) * (1 / (t1 + t2));
	tv_z = g * t1;
	return tv;
};

// The flat throw, for the M203's contact round: a fixed muzzle speed with just
// enough upward bias to cancel the drop over the flight time.
vector(entity m, vector src, vector dest, float speed, float gravadj) AI_VecCheckThrow =
{
	float g = cvar("sv_gravity") * gravadj;
	if (g <= 0)
		g = 800 * gravadj;
	if (speed <= 0)
		return '0 0 0';

	vector d = dest - src;
	float t = vlen(d) / speed;
	if (t <= 0)
		return '0 0 0';

	vector tv = d * (1 / t);
	tv_z = tv_z + g * t * 0.5;

	vector apex = src + d * 0.5;
	apex_z = apex_z + 0.5 * g * (t * 0.5) * (t * 0.5);

	traceline(src, apex, MOVE_NORMAL, m);
	if (trace_fraction != 1)
		return '0 0 0';
	traceline(dest, apex, MOVE_NOMONSTERS, m);
	if (trace_fraction != 1)
		return '0 0 0';

	return tv;
};

// "Is anyone I would not want to blow up standing near where this is going to
// land?"  HL asks only about squad members; asking the FACTION matrix instead is
// strictly better and costs the same walk - it also covers the player, allied
// scientists, and a second squad fighting alongside this one, none of which
// HL's squad-only test protects.
float(entity m, vector spot, float radius) AI_FriendlyNear =
{
	entity e = monster_chain_head;
	while (e)
	{
		if (e != m && e.health > 0 && (e.flags & FL_MONSTER)
		    && vlen(e.origin - spot) < radius
		    && !AI_Hates(m, e))
			return TRUE;
		e = e.monster_chain_next;
	}

	// Players are not on the monster chain, and a grunt's ALLY variants must not
	// frag the people they are escorting.
	e = find(world, classname, "player");
	while (e)
	{
		if (e.health > 0 && vlen(e.origin - spot) < radius && !AI_Hates(m, e))
			return TRUE;
		e = find(e, classname, "player");
	}
	return FALSE;
};

// ---------------------------------------------------------------------------
// bone controllers  (W1a, engine Patch 125)
// ---------------------------------------------------------------------------
// Half-Life models aim, elevate, open their mouths and stretch a barnacle tongue
// by driving BONE CONTROLLERS - a small set of per-model scalars that offset one
// bone independently of whatever animation is playing.  Until the engine patch
// that ships with this, .bonecontrol1..5 existed in progdefs and were read by
// nothing on the wire: a server-side monster could set them and no client ever
// found out.  That is why turrets swivelled their whole chassis, the barnacle's
// tongue was invisible, and grunts fired without ever looking at you.
//
// THE UNITS ARE NOT UNIFORM, and this is the part that will catch anyone who
// assumes otherwise.  gl_hlmdl.c:HL_CalcBoneAdj branches on the controller's
// `type` field, read out of the model:
//
//   type & 0x8000 (RLOOP, a wrapping rotation)
//        -> value is used RAW and UNCLAMPED, and the code below it does no
//           degree conversion, so the engine consumes it as RADIANS.
//   type in [0x0008, 0x0020] (XR/YR/ZR, a bounded rotation)
//        -> value is CLAMPED to the controller's own [start,end] and then
//           converted with M_PI*value/180, so it is DEGREES.
//   anything else (e.g. 0x0002, a translation)
//        -> raw model units.
//
// Measured from the shipped models:
//   sentry/miniturret/turret  [0] 0x8010  0..360   yaw    -> RADIANS, wrapping
//                             [1] 0x0010/0x0020    pitch  -> DEGREES, clamped
//   barnacle                  [0] 0x0002 -1024..0  tongue -> UNITS
//   hgrunt                    [0] 0x0008  -70..70  yaw    -> DEGREES
//   barney                    [0] 0x0008  -60..60  yaw    -> DEGREES
//                             [1] 0x0020    0..45  mouth  -> DEGREES
//
// So the helpers below are named for what they mean, not for which slot they
// write, and each one states its own units.

// QC has no arrays on fields, so the slot dispatch is written out once here
// rather than at every call site.
void(entity m, float idx, float v) AI_SetBoneControl =
{
	if      (idx == 0) m.bonecontrol1 = v;
	else if (idx == 1) m.bonecontrol2 = v;
	else if (idx == 2) m.bonecontrol3 = v;
	else if (idx == 3) m.bonecontrol4 = v;
	else if (idx == 4) m.bonecontrol5 = v;
};

// The signed yaw from where the MODEL is facing to where the target is, in
// degrees, normalised to +-180.
//
// This is a RESIDUAL, and that is the whole trick to making aim look right
// without breaking anything.  The entity keeps turning at its own ai_yaw_speed
// exactly as before - so TASK_FACE_ENEMY still completes and no schedule
// changes - while the controller instantly closes whatever gap is left.  The
// barrel leads the chassis, which is precisely how Half-Life reads.
float(entity m, vector target) AI_AimResidualYaw =
{
	vector d = target - m.origin;
	if (!d_x && !d_y)
		return 0;
	return AI_AngleNorm(vectoyaw(d) - m.angles_y);
};

// The signed pitch to the target in degrees, positive UP.
float(entity m, vector src, vector target) AI_AimResidualPitch =
{
	vector d = target - src;
	float flat = sqrt(d_x * d_x + d_y * d_y);
	if (flat < 1)
		flat = 1;
	return atan2(d_z, flat) * 180 / 3.14159265;
};

// ---------------------------------------------------------------------------
// reporting
// ---------------------------------------------------------------------------
void() AI_ReportCombat =
{
	if (!ai_dbg_shots)
		return;
	dprint(sprintf("[ai]   shots=%g hits=%g dmg=%g\n",
	               ai_dbg_shots, ai_dbg_shothits, ai_dbg_shotdmg));
	ai_dbg_shots = 0; ai_dbg_shothits = 0; ai_dbg_shotdmg = 0;
};
