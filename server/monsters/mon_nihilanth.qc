// server/monsters/mon_nihilanth.qc
// ----------------------------------------------------------------------------
// monster_nihilanth - the last boss of Half-Life (dlls/nihilanth.cpp).
//
// One placement in the whole corpus, on hl_c17, and the map is unfinishable
// without it: every ending beat hangs off names this monster fires.  hl_c17
// ships the full support set and all of it was inert until now -
//
//     n_min / n_max            info_target       his vertical flight bounds
//     n_recharger1/2/3         info_target       the three healing crystals
//     n_draw1/2/3              multi_manager     fired as he drinks each one
//     n_leaving1..4            trigger_relay     the teleport-attack destinations
//     n_teleport1..4           trigger_teleport  ...and their touch halves
//     n_dead                   trigger_relay     fired when he stops moving
//     n_ending                 trigger_teleport  the ride to the credits
//
// The fight is a ladder.  He starts immortal; each time he is hurt he drains a
// recharger and heals; when the third is gone he opens his head (m_irritation 2)
// and only then can a killing blow land - and only on the head.  That last part
// is exact here rather than approximated, because this tree does have hitgroups:
// .death_hitgroup is stamped by every hitscan path and by the client hit-claim
// path (sv_player.qc:4108) before W_ApplyDamage runs, and .ai_damagefilter (added
// in PATCH 153) runs inside W_ApplyDamage early enough to read it.
//
// ---------------------------------------------------------------------------
// STRUCTURE
// ---------------------------------------------------------------------------
// Same shape as mon_tentacle.qc and for the same reason: CNihilanth drives its
// own think, its own sequence choice and its own flight integrator, and uses
// none of CBaseMonster's schedule machinery.  It borrows AI_SetSequenceNamed,
// AI_AnimPump and .ai_damagefilter and nothing else.
//
// Two classes live here.  nihilanth_energy_ball is his ammunition and it has SIX
// distinct behaviours off one classname - orbit, zap, teleport, green ball,
// absorb and dissipate - which is why the SDK gives it a mode per Init function
// rather than six classnames.  Kept as one class for the same reason.
//
// ---------------------------------------------------------------------------
// WHAT IS APPROXIMATED, AND WHY
// ---------------------------------------------------------------------------
//  * pev->framerate (nihilanth.cpp:895) scales his animation speed with how hurt
//    he is.  Not networkable from the server here - the limitation
//    mon_tentacle.qc documents in full.  He animates at the rig's authored rate.
//  * TE_ELIGHT, the moving coloured light on every ball and on his open head.
//    This tree has no dynamic-light temp entity plumbed to CSQC; the balls are
//    additive sprites, which carries most of it.
//  * DMG_SHOCK has no bit here.  sh_weapon_standard.qc:633-638 is
//    BULLET/CLUB/BLAST/SONIC/CRUSH/FALL and nothing else, so the zap uses SONIC -
//    the nearest in kind, and the bit only decides whether a corpse in the blast
//    bleeds or comes apart.  Same call the gonarch's DMG_ACID immunity got.
//  * MakeFriend uses the map's own info_node_air / info_node entities directly
//    instead of the compiled node graph.  Same source data - the graph is built
//    from those entities - and hl_c17 places 45 air nodes and 69 ground ones,
//    which is exactly what that call is choosing between.
//  * The head sprite (a CSprite attached to attachment 1 with
//    kRenderFxNoDissipation) is a plain additive sprite entity moved by position
//    each tick, because nothing here attaches a sprite to a studio attachment.
//
// Everything else - the recharger ladder, the level counter, the twenty orbiting
// spheres and their absorb-to-heal, the zap and teleport attacks, the friend
// spawning, the head-shot kill gate and the whole death sequence - is the SDK's.
// ----------------------------------------------------------------------------

const float N_SCALE   = 15;
const float N_SPHERES = 20;

// The six name prefixes.  HL exposes them as keyvalues that no map in the corpus
// overrides, so they are constants until one does.
const string NIH_RECHARGER = "n_recharger";
const string NIH_DRAWUSE   = "n_draw";
const string NIH_TELEUSE   = "n_leaving";
const string NIH_TELETOUCH = "n_teleport";
const string NIH_DEADUSE   = "n_dead";
const string NIH_DEADTOUCH = "n_ending";

.float  nih_level;		// m_iLevel: which recharger he is on, 1..9
.float  nih_teleport;		// m_iTeleport: which teleport destination is next
.float  nih_irritation;		// m_irritation: 0 asleep, 1 fighting, 2 head open, 3 head hit
.float  nih_force;		// m_flForce: the lift his flight integrator is applying
.vector nih_vel;		// m_velocity - NOT .velocity; he is MOVETYPE_FLY and
.vector nih_avel;		// m_avelocity  moves himself with setorigin
.vector nih_vecdesired;		// m_vecDesired: the facing he wants
.vector nih_posdesired;		// m_posDesired: the point he wants to be at
.vector nih_vectarget;		// m_vecTarget
.vector nih_postarget;		// m_posTarget: where his enemy was last seen
.float  nih_minz, nih_maxz;	// from n_min / n_max
.float  nih_adj;		// m_flAdj: how far above the enemy he hovers
.float  nih_lastseen;		// m_flLastSeen
.float  nih_nextpain;		// m_flNextPainSound
.entity nih_recharger;		// m_hRecharger
.entity nih_spheres;		// head of the orbiting-sphere list (m_hSphere[20])
.float  nih_nspheres;		// m_iActiveSpheres
.float  nih_shootend;		// m_flShootEnd
.float  nih_shoottime;		// m_flShootTime
.entity nih_enemy;		// m_hEnemy
.entity nih_ball;		// m_pBall, the head sprite
.float  nih_deadflag;		// pev->deadflag
.entity nih_friend1, nih_friend2, nih_friend3;	// m_hFriend[3]

// Energy-ball state.  hvr_mode exists only for the self-test and the debug line;
// the behaviour is carried by .think / .touch exactly as it is in the SDK.
const float HVR_CIRCLE    = 1;
const float HVR_ZAP       = 2;
const float HVR_TELEPORT  = 3;
const float HVR_GREENBALL = 4;
const float HVR_DISSIPATE = 5;

.float  hvr_mode;
.entity hvr_next;		// the owner's sphere list
.entity hvr_nih;		// m_pNihilanth
.entity hvr_target;		// m_hTargetEnt
.entity hvr_enemy;		// m_hEnemy
.entity hvr_touch;		// m_hTouch
.vector hvr_ideal;		// m_vecIdeal

const string SND_NIH_ATTACK   = "x/x_attack1.wav x/x_attack2.wav x/x_attack3.wav";
const string SND_NIH_BALL     = "x/x_ballattack1.wav";
const string SND_NIH_RECHARGE = "x/x_recharge1.wav x/x_recharge2.wav x/x_recharge3.wav";
const string SND_NIH_LAUGH    = "x/x_laugh1.wav x/x_laugh2.wav x/x_laugh3.wav";
const string SND_NIH_PAIN     = "x/x_pain1.wav x/x_pain2.wav x/x_pain3.wav";
const string SND_NIH_DIE      = "x/x_die1.wav";

float nih_dbg_spheres;		// spheres emitted
float nih_dbg_absorbed;		// spheres drunk back
float nih_dbg_zaps;		// zap balls launched
float nih_dbg_teleports;	// teleport balls launched
float nih_dbg_friends;		// friends summoned
float nih_dbg_headhits;		// hits that landed on the open head

void() Nih_HuntThink;
void() Nih_DyingThink;
void(entity b) HVR_AbsorbInit;
void(entity nih, vector where) Nih_MakeFriend;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
// RandomTargetname (nihilanth.cpp:1275): reservoir-sample one entity out of
// however many share a name.  hl_c17 has TWO n_dead relays and this is what
// stops both of them firing.
entity(string nm) Nih_RandomTargetname =
{
	if (nm == "" || !nm)
		return world;

	float total = 0;
	entity pick = world;
	entity e = find(world, targetname, nm);
	while (e)
	{
		total = total + 1;
		if (floor(random() * total) < 1)
			pick = e;
		e = find(e, targetname, nm);
	}
	return pick;
};

// Call ONE known entity's .use, the way HL's pEnt->Use(...) does.  Not
// SUB_UseTargets, which fires an entity's TARGETS rather than the entity itself -
// n_leaving1 is a trigger_relay and what the SDK does with it is press it, not
// press what it points at.  Same save/restore shape the debug harness uses at
// sv_ai_debugcmds.qc:373-391, reduced to a single entity.
void(entity e, entity who, float ut) Nih_UseEntity =
{
	if (!e || !e.use)
		return;
	entity oldself = self, oldact = activator, oldcaller = sub_use_caller;
	float  oldut   = sub_use_type;

	self           = e;
	activator      = who;
	sub_use_caller = who;
	sub_use_type   = ut;
	e.use();

	self = oldself; activator = oldact;
	sub_use_caller = oldcaller; sub_use_type = oldut;
};

// ...and the touch half.  trigger_teleport does its work in .touch, so the
// teleport attack has to press it that way rather than through .use.
void(entity e, entity who) Nih_TouchAs =
{
	if (!e || !e.touch || !who)
		return;
	entity oldself = self, oldother = other;
	self = e; other = who;
	e.touch();
	self = oldself; other = oldother;
};

// Nearest visible player within `range`.  Deliberately NOT AI_FindEnemy: that
// walks the faction matrix and the squad tables on behalf of a monster registered
// in the AI layer, and this one is not.  Look(4096) + BestVisibleEnemy in the SDK
// comes to the same thing on hl_c17, where the only living things in the chamber
// are the players and whatever he has just summoned.
entity(entity m, float range) Nih_BestVisiblePlayer =
{
	entity best = world;
	float  bd   = range;
	entity p    = find(world, classname, "player");
	while (p)
	{
		if (p.health > 0)
		{
			float d = vlen(p.origin - m.origin);
			if (d < bd && AI_CanSee(m, p))
			{
				bd   = d;
				best = p;
			}
		}
		p = find(p, classname, "player");
	}
	return best;
};

// Force a named sequence to restart even if it is already the current one.
// AI_SetSequenceNamed is idempotent on the name (sv_ai_anim.qc:502) and this
// monster re-picks its sequence every time the last one finishes, so without the
// reset a run of two "float"s in a row would stall on the first.
float(entity m, string nm) Nih_PlaySeq =
{
	AI_ResetActivity(m);
	return AI_SetSequenceNamed(m, nm, FALSE);
};

void(entity m) Nih_PainSound =
{
	if (m.nih_nextpain > time)
		return;
	m.nih_nextpain = time + 2 + random() * 3;

	// Laughing while he is winning and screaming once he is not.  The threshold
	// is half health for the laugh and irritation 2 - head open, rechargers gone -
	// for the pain, so there is a middle band where he makes no sound at all.
	// That is HL's (:355-364), not an omission here.
	if (m.health > m.max_health / 2)
		AI_SndPlay(m, CHAN_VOICE, SND_NIH_LAUGH);
	else if (m.nih_irritation >= 2)
		AI_SndPlay(m, CHAN_VOICE, SND_NIH_PAIN);
};

// ---------------------------------------------------------------------------
// nihilanth_energy_ball
// ---------------------------------------------------------------------------
void() HVR_HoverThink;
void() HVR_ZapThink;
void() HVR_TeleportThink;
void() HVR_DissipateThink;
void() HVR_BounceTouch;
void() HVR_ZapTouch;
void() HVR_TeleportTouch;
void() HVR_RemoveTouch;

void() HVR_Precache =
{
	precache_model("sprites/flare6.spr");
	precache_model("sprites/nhth1.spr");
	precache_model("sprites/exit1.spr");
	precache_model("sprites/tele1.spr");
	precache_model("sprites/muzzleflash3.spr");
	precache_sound("debris/zap4.wav");
	precache_sound("weapons/electro4.wav");
	precache_sound("x/x_teleattack1.wav");
};

// `boss`, not `owner`: QC keeps fields and locals in ONE namespace, so a
// parameter called owner shadows the .owner FIELD and `b.owner = owner` stops
// compiling ("owner is not a field").  Exactly the collision the gonarch's work
// hit with .scale.
entity(entity boss, vector org) HVR_Make =
{
	entity b = spawn();
	b.classname  = "nihilanth_energy_ball";
	b.owner      = boss;
	b.rendermode = 5;			// kRenderTransAdd
	b.renderamt  = 255;
	b.scale      = 3.0;
	b.angles     = boss.angles;
	setorigin(b, org);
	return b;
};

vector(entity e) HVR_Center = { return e.origin + (e.mins + e.maxs) * 0.5; };

// CircleTarget (:1729-1782).  The orbit is computed in the PLANE - every z is
// zeroed before the distance test - and the height is a separate term bolted on
// at the end.  That separation is what makes twenty spheres form a ring around
// him rather than a shell.
float(entity b, vector targ) HVR_CircleTarget =
{
	float close = FALSE;

	vector dest = targ;                        dest_z = 0;
	vector est  = b.origin + b.velocity * 0.5; est_z  = 0;
	vector src  = b.origin;                    src_z  = 0;

	float d1 = vlen(dest - src) - 24 * N_SCALE;
	float d2 = vlen(dest - est) - 24 * N_SCALE;

	if (b.hvr_ideal == '0 0 0')
		b.hvr_ideal = b.velocity;

	if (d1 < 0 && d2 <= d1)
		b.hvr_ideal = b.hvr_ideal - HL_Normalize(dest - src) * 50;
	else if (d1 > 0 && d2 >= d1)
		b.hvr_ideal = b.hvr_ideal + HL_Normalize(dest - src) * 50;

	b.avelocity_z = d1 * 20;
	if (d1 < 32)
		close = TRUE;

	b.hvr_ideal = b.hvr_ideal + '1 0 0' * (random() * 4 - 2)
	                          + '0 1 0' * (random() * 4 - 2)
	                          + '0 0 1' * (random() * 4 - 2);

	vector flat = b.hvr_ideal;
	flat_z = 0;
	b.hvr_ideal = HL_Normalize(flat) * 200 + '0 0 1' * b.hvr_ideal_z;

	d1 = targ_z - b.origin_z;
	if (d1 > 0 && b.hvr_ideal_z < 200)
		b.hvr_ideal_z = b.hvr_ideal_z + 20;
	else if (d1 < 0 && b.hvr_ideal_z > -200)
		b.hvr_ideal_z = b.hvr_ideal_z - 20;

	b.velocity = b.hvr_ideal;
	return close;
};

void(entity b, vector targ) HVR_MovetoTarget =
{
	if (b.hvr_ideal == '0 0 0')
		b.hvr_ideal = b.velocity;
	if (vlen(b.hvr_ideal) > 300)
		b.hvr_ideal = HL_Normalize(b.hvr_ideal) * 300;
	b.hvr_ideal = b.hvr_ideal + HL_Normalize(targ - b.origin) * 300;
	b.velocity  = b.hvr_ideal;
};

void(entity b, entity targ) HVR_CircleInit =
{
	b.hvr_mode    = HVR_CIRCLE;
	b.movetype    = MOVETYPE_NOCLIP;
	b.solid       = SOLID_NOT;
	setmodel(b, "sprites/muzzleflash3.spr");
	b.rendercolor = '255 224 192';
	b.scale       = 2.0;
	b.renderamt   = 255;
	setsize(b, '0 0 0', '0 0 0');
	setorigin(b, b.origin);
	b.hvr_target  = targ;
	b.think       = HVR_HoverThink;
	b.touch       = HVR_BounceTouch;
	b.nextthink   = time + 0.1;
};

void() HVR_HoverThink =
{
	self.nextthink = time + 0.1;

	if (!self.hvr_target)
	{
		remove(self);
		return;
	}
	HVR_CircleTarget(self, self.hvr_target.origin + '0 0 1' * (16 * N_SCALE));
};

void(entity b, entity en) HVR_ZapInit =
{
	b.hvr_mode = HVR_ZAP;
	b.movetype = MOVETYPE_FLY;
	b.solid    = SOLID_BBOX;
	setmodel(b, "sprites/nhth1.spr");
	b.rendercolor = '255 255 255';
	b.scale       = 2.0;
	setsize(b, '0 0 0', '0 0 0');

	b.velocity  = HL_Normalize(en.origin - b.origin) * 200;
	b.hvr_enemy = en;
	b.think     = HVR_ZapThink;
	b.touch     = HVR_ZapTouch;
	b.nextthink = time + 0.1;

	sound(b, CHAN_WEAPON, "debris/zap4.wav", 1, ATTN_NORM);
	nih_dbg_zaps = nih_dbg_zaps + 1;
};

// The world-bounds test is HL's own and it is load-bearing rather than defensive:
// a zap ball that loses its enemy accelerates forever, and 4096 is the Xen map's
// own extent.
float(entity b) HVR_OutOfWorld =
{
	return (b.origin_x < -4096 || b.origin_x > 4096
	     || b.origin_y < -4096 || b.origin_y > 4096
	     || b.origin_z < -4096 || b.origin_z > 4096);
};

float() Nih_ZapDamage =
{
	float d = cvar("sk_nihilanth_zap");
	return (d > 0) ? d : 30;
};

void() HVR_ZapThink =
{
	self.nextthink = time + 0.05;

	if (!self.hvr_enemy || HVR_OutOfWorld(self))
	{
		self.touch = __NULL__;
		remove(self);
		return;
	}

	if (vlen(self.velocity) < 2000)
		self.velocity = self.velocity * 1.2;

	vector ctr = HVR_Center(self.hvr_enemy);
	if (vlen(ctr - self.origin) < 256)
	{
		// CLOSE ENOUGH: it stops flying and reaches out with a bolt instead, which
		// is why the zap is hard to strafe away from once it is on top of you.
		traceline(self.origin, ctr, MOVE_NORMAL, self);
		entity hit = trace_ent;

		HLBeam_Multicast(HL_BEAM_SHOCK, self.owner, self.origin, trace_endpos);

		if (hit && hit != world && hit != self.owner)
		{
			sv_dmg_bits = DMG_SONIC;	// no DMG_SHOCK here - see the header
			W_ApplyDamage(self.owner, hit, Nih_ZapDamage());
		}

		sound(self, CHAN_WEAPON, "weapons/electro4.wav", 0.5, ATTN_NORM);
		self.touch = __NULL__;
		remove(self);
		return;
	}
};

void() HVR_ZapTouch =
{
	sound(self, CHAN_WEAPON, "weapons/electro4.wav", 1, ATTN_NORM);
	sv_dmg_bits   = DMG_SONIC;
	AI_BlastAttack(self, 128, 50, 10);
	self.velocity = '0 0 0';
	self.touch    = __NULL__;
	remove(self);
};

void(entity b, entity nih, entity en, entity trig, entity tch) HVR_TeleportInit =
{
	b.hvr_mode = HVR_TELEPORT;
	b.movetype = MOVETYPE_FLY;
	b.solid    = SOLID_BBOX;
	b.rendercolor = '255 255 255';
	b.velocity_z  = b.velocity_z * 0.2;
	setmodel(b, "sprites/exit1.spr");
	setsize(b, '0 0 0', '0 0 0');

	b.hvr_nih    = nih;
	b.hvr_enemy  = en;
	b.hvr_target = trig;
	b.hvr_touch  = tch;
	b.think      = HVR_TeleportThink;
	b.touch      = HVR_TeleportTouch;
	b.nextthink  = time + 0.1;

	sound(b, CHAN_WEAPON, "x/x_teleattack1.wav", 1, 0.2);
	nih_dbg_teleports = nih_dbg_teleports + 1;
};

void(entity b) HVR_GreenBallInit =
{
	b.hvr_mode = HVR_GREENBALL;
	b.movetype = MOVETYPE_FLY;
	b.solid    = SOLID_BBOX;
	b.rendercolor = '255 255 255';
	b.scale       = 1.0;
	setmodel(b, "sprites/exit1.spr");
	setsize(b, '0 0 0', '0 0 0');
	b.touch = HVR_RemoveTouch;

	// No think of its own in the SDK either: it flies on its launch velocity until
	// it hits something.  Given a life here so a green ball thrown at open sky on
	// the last frame of his death cannot leak.
	b.think     = SUB_Remove;
	b.nextthink = time + 20;
};

void() HVR_TeleportThink =
{
	self.nextthink = time + 0.1;

	if (!self.hvr_enemy || self.hvr_enemy.health <= 0 || HVR_OutOfWorld(self))
	{
		remove(self);
		return;
	}

	vector ctr = HVR_Center(self.hvr_enemy);
	if (vlen(ctr - self.origin) < 128)
	{
		entity en = self.hvr_enemy;
		if (self.hvr_target)
			Nih_UseEntity(self.hvr_target, en, USE_ON);
		if (self.hvr_touch && en)
			Nih_TouchAs(self.hvr_touch, en);
		remove(self);
		return;
	}

	HVR_MovetoTarget(self, ctr);
};

// TeleportTouch (:1671-1692).  Touching the PLAYER teleports them; touching
// anything else spawns a friend at the impact point.  That second arm is where
// every alien_slave and alien_controller in the fight comes from.
void() HVR_TeleportTouch =
{
	if (other == self.hvr_enemy)
	{
		if (self.hvr_target)
			Nih_UseEntity(self.hvr_target, other, USE_ON);
		if (self.hvr_touch)
			Nih_TouchAs(self.hvr_touch, other);
	}
	else if (self.hvr_nih)
		Nih_MakeFriend(self.hvr_nih, self.origin);

	self.touch = __NULL__;
	remove(self);
};

void() HVR_RemoveTouch = { remove(self); };

// BounceTouch (:1837-1849): a mirror reflection off the surface normal, applied
// to the orbit's ideal velocity rather than to .velocity, because CircleTarget
// overwrites .velocity every tick.
void() HVR_BounceTouch =
{
	vector dir = HL_Normalize(self.hvr_ideal);
	float  n   = 0 - (trace_plane_normal * dir);
	dir = 2 * trace_plane_normal * n + dir;
	self.hvr_ideal = dir * vlen(self.hvr_ideal);
};

void(entity b) HVR_AbsorbInit =
{
	b.hvr_mode  = HVR_DISSIPATE;
	b.think     = HVR_DissipateThink;
	b.nextthink = time + 0.1;
	b.renderamt = 255;
	if (b.hvr_target)
		HLBeam_Multicast(HL_BEAM_ARC, b, b.origin, b.hvr_target.origin);
};

void() HVR_DissipateThink =
{
	self.nextthink = time + 0.1;

	if (self.scale > 5.0 || !self.hvr_target)
	{
		remove(self);
		return;
	}
	self.renderamt = self.renderamt - 2;
	self.scale     = self.scale + 0.1;

	// Straight up and away: the orbit target is 4096 units above him, so the
	// solver drives it out of the room instead of round him.
	HVR_CircleTarget(self, self.hvr_target.origin + '0 0 4096');
};

void() nihilanth_energy_ball =
{
	// A map could place one, and HL registers the classname, so the spawn function
	// exists - but with no Init called it has no behaviour in the SDK either.
	// Removing it is the honest reading of that.
	HVR_Precache();
	remove(self);
};

// ---------------------------------------------------------------------------
// spheres
// ---------------------------------------------------------------------------
float(entity m) Nih_EmitSphere =
{
	if (m.nih_nspheres >= N_SPHERES)
		return FALSE;
	if (!m.nih_recharger)
		return FALSE;

	entity b = HVR_Make(m, m.nih_recharger.origin);
	b.velocity = m.origin - m.nih_recharger.origin;
	HVR_CircleInit(b, m);

	b.hvr_next      = m.nih_spheres;
	m.nih_spheres   = b;
	m.nih_nspheres  = m.nih_nspheres + 1;
	nih_dbg_spheres = nih_dbg_spheres + 1;
	return TRUE;
};

// Pop one off the head of the list and send it home.  HL walks a fixed array and
// takes the first live slot; a list gives the same "any one of them" and cannot
// leave holes.
float(entity m) Nih_AbsorbSphere =
{
	entity b = m.nih_spheres;
	if (!b)
		return FALSE;

	m.nih_spheres  = b.hvr_next;
	b.hvr_next     = world;
	m.nih_nspheres = m.nih_nspheres - 1;
	HVR_AbsorbInit(b);
	nih_dbg_absorbed = nih_dbg_absorbed + 1;
	return TRUE;
};

// ---------------------------------------------------------------------------
// friends
// ---------------------------------------------------------------------------
// MakeFriend (:627-675).  Three slots, one summon per call, and a coin flip
// between a flying controller placed on an AIR node and a walking slave placed on
// a ground one.
entity(vector near, string cls) Nih_NearestNode =
{
	entity best = world;
	float  bd   = 1000000;
	entity e    = find(world, classname, cls);
	while (e)
	{
		float d = vlen(e.origin - near);
		if (d < bd) { bd = d; best = e; }
		e = find(e, classname, cls);
	}
	return best;
};

entity(entity m, entity slot, vector where) Nih_SummonInto =
{
	if (slot && slot.health > 0)
		return slot;			// still alive; this slot is busy

	float air = (random() < 0.5);
	entity node = Nih_NearestNode(where, air ? "info_node_air" : "info_node");
	if (!node)
		return world;

	entity f = spawn();
	f.classname = air ? "monster_alien_controller" : "monster_alien_slave";
	f.angles    = m.angles;
	setorigin(f, node.origin + (air ? '0 0 32' : '0 0 36'));

	// The spawn functions are the ordinary map ones, called directly - the same
	// thing a squadmaker does.  self has to be the new entity for the duration,
	// which is the QC equivalent of HL's Create().
	entity oldself = self;
	self = f;
	if (air)
		monster_alien_controller();
	else
		monster_alien_slave();
	self = oldself;

	sound(f, CHAN_WEAPON, "debris/beamstart7.wav", 1, ATTN_NORM);
	nih_dbg_friends = nih_dbg_friends + 1;
	return f;
};

void(entity nih, vector where) Nih_MakeFriend =
{
	if (!nih.nih_friend1 || nih.nih_friend1.health <= 0)
	{
		nih.nih_friend1 = Nih_SummonInto(nih, nih.nih_friend1, where);
		return;
	}
	if (!nih.nih_friend2 || nih.nih_friend2.health <= 0)
	{
		nih.nih_friend2 = Nih_SummonInto(nih, nih.nih_friend2, where);
		return;
	}
	if (!nih.nih_friend3 || nih.nih_friend3.health <= 0)
		nih.nih_friend3 = Nih_SummonInto(nih, nih.nih_friend3, where);
};

// ---------------------------------------------------------------------------
// flight  (:904-970)
// ---------------------------------------------------------------------------
// A physical integrator, not a mover: he banks toward the facing he wants, adds
// lift along his own up vector, bleeds sideways speed, and is then moved by hand
// with setorigin.  That is why he drifts and overshoots instead of tracking, and
// most of why he is hard to hit.
void(entity m) Nih_Flight =
{
	makevectors(m.angles + m.nih_avel);
	float side = m.nih_vecdesired * v_right;

	if (side < 0)
	{
		if (m.nih_avel_y < 180)
			m.nih_avel_y = m.nih_avel_y + 6;
	}
	else
	{
		if (m.nih_avel_y > -180)
			m.nih_avel_y = m.nih_avel_y - 6;
	}
	m.nih_avel_y = m.nih_avel_y * 0.98;

	vector est = m.origin + m.nih_vel * 2.0 + v_up * m.nih_force * 20;

	makevectors(m.angles);
	m.nih_vel = m.nih_vel + v_up * m.nih_force;

	// Sideways drag, per axis and scaled by how much of that axis the right vector
	// occupies - a body that is turning loses speed across itself.
	m.nih_vel_x = m.nih_vel_x * (1 - fabs(v_right_x) * 0.05);
	m.nih_vel_y = m.nih_vel_y * (1 - fabs(v_right_y) * 0.05);
	m.nih_vel_z = m.nih_vel_z * (1 - fabs(v_right_z) * 0.05);
	m.nih_vel   = m.nih_vel * 0.995;

	if (m.nih_force < 100 && est_z < m.nih_posdesired_z)
		m.nih_force = m.nih_force + 10;
	else if (m.nih_force > -100 && est_z > m.nih_posdesired_z)
		m.nih_force = m.nih_force - 10;

	setorigin(m, m.origin + m.nih_vel * 0.1);
	m.angles = m.angles + m.nih_avel * 0.1;
};

// FloatSequence (:561-588): the idle pose says which way he is drifting.
void(entity m) Nih_FloatSequence =
{
	if (m.nih_irritation >= 2)	{ Nih_PlaySeq(m, "float_open"); return; }
	if (m.nih_avel_y > 30)		{ Nih_PlaySeq(m, "walk_r");     return; }
	if (m.nih_avel_y < -30)		{ Nih_PlaySeq(m, "walk_l");     return; }
	if (m.nih_vel_z > 30)		{ Nih_PlaySeq(m, "walk_u");     return; }
	if (m.nih_vel_z < -30)		{ Nih_PlaySeq(m, "walk_d");     return; }
	Nih_PlaySeq(m, "float");
};

// ---------------------------------------------------------------------------
// ShootBalls  (:590-625)
// ---------------------------------------------------------------------------
// A one-second burst at 5 Hz from both hands, and the loop is a CATCH-UP loop:
// nih_shoottime advances by 0.2 regardless of how long the frame took, so a
// stalled server fires the whole burst at once rather than dropping it.
void(entity m) Nih_ShootBalls =
{
	if (m.nih_shootend <= time)
		return;

	vector dir, src;
	entity b;

	while (m.nih_shoottime < m.nih_shootend && m.nih_shoottime < time)
	{
		if (m.nih_enemy)
		{
			// Hoisted out of the loop body: fteqcc scopes locals to the FUNCTION,
			// so a declaration inside a while() is a duplicate definition on the
			// second pass rather than a fresh variable.
			dir = HL_Normalize(m.nih_postarget - m.origin);

			src = gettaginfo(m, 3);
			b = HVR_Make(m, src);
			b.velocity = dir * 200;
			HVR_ZapInit(b, m.nih_enemy);

			src = gettaginfo(m, 4);
			b = HVR_Make(m, src);
			b.velocity = dir * 200;
			HVR_ZapInit(b, m.nih_enemy);
		}
		m.nih_shoottime = m.nih_shoottime + 0.2;
	}
};

// ---------------------------------------------------------------------------
// NextActivity  (:677-836) - the ladder
// ---------------------------------------------------------------------------
void(entity m) Nih_NextActivity =
{
	makevectors(m.angles);

	// THE RECHARGER LADDER, and it is the whole fight.  He goes looking for a
	// crystal whenever he is under half health OR has burned half his spheres,
	// drinks it, and moves to the next one; when the names run out he opens his
	// head and becomes killable.
	if ((m.health < m.max_health / 2 || m.nih_nspheres < N_SPHERES / 2)
	    && !m.nih_recharger && m.nih_level <= 9)
	{
		string nm = strcat(NIH_RECHARGER, ftos(m.nih_level));
		entity best = world;
		float  bd   = 8192;
		entity e = find(world, targetname, nm);
		while (e)
		{
			float d = vlen(e.origin - m.origin);
			if (d < bd) { bd = d; best = e; }
			e = find(e, targetname, nm);
		}

		if (best)
		{
			m.nih_recharger    = best;
			m.nih_posdesired   = m.origin;
			m.nih_posdesired_z = best.origin_z;
			vector want = best.origin - m.nih_posdesired;
			want_z = 0;
			m.nih_vecdesired = HL_Normalize(want);
		}
		else
		{
			m.nih_recharger = world;
			m.nih_level     = m.nih_level + 1;
			if (cvar("sv_ai_debug"))
				dprint(sprintf("[nihilanth] no \"%s\"; level now %g\n", nm, m.nih_level));
			if (m.nih_level > 9)
				m.nih_irritation = 2;		// head opens: he is mortal now
		}
	}

	float dist = vlen(m.nih_posdesired - m.origin);
	float dot  = m.nih_vecdesired * v_forward;

	if (m.nih_recharger)
	{
		if (dist < 128)
		{
			// Arriving fires n_draw<level> ONCE - the test is on the sequence not
			// already being "recharge", which is HL's own edge detector.
			if (m.ai_seqname != "recharge")
			{
				string dn = strcat(NIH_DRAWUSE, ftos(m.nih_level));
				float fired = SV_FireTargetsByName(dn, m, USE_ON);
				if (cvar("sv_ai_debug"))
					dprint(sprintf("[nihilanth] drinking: fired \"%s\" -> %g\n", dn, fired));
			}
			Nih_PlaySeq(m, "recharge");
		}
		else
			Nih_FloatSequence(m);
		return;
	}

	if (m.nih_enemy && m.nih_enemy.health <= 0)
		m.nih_enemy = world;
	if (m.nih_lastseen + 15 < time)
		m.nih_enemy = world;

	if (!m.nih_enemy)
		m.nih_enemy = Nih_BestVisiblePlayer(m, 4096);

	if (m.nih_enemy && m.nih_irritation != 0)
	{
		if (m.nih_lastseen + 5 > time && dist < 256 && dot > 0)
		{
			if (m.nih_irritation >= 2 && m.health < m.max_health / 2)
			{
				Nih_PlaySeq(m, "attack1_open");
				return;
			}

			if (random() < 0.5)
			{
				Nih_PlaySeq(m, "attack1");	// zap
				return;
			}

			// Teleport, if there is anywhere left to send them.  Running out of
			// destinations bumps the counter and falls back to a zap rather than
			// wasting the attack - HL's own recovery (:820-828).
			string tt = strcat(NIH_TELETOUCH, ftos(m.nih_teleport));
			string tu = strcat(NIH_TELEUSE,   ftos(m.nih_teleport));
			if (find(world, targetname, tt) || find(world, targetname, tu))
				Nih_PlaySeq(m, "attack2");
			else
			{
				m.nih_teleport = m.nih_teleport + 1;
				Nih_PlaySeq(m, "attack1");
			}
			return;
		}
	}

	Nih_FloatSequence(m);
};

// ---------------------------------------------------------------------------
// anim events  (:1046-1192)
// ---------------------------------------------------------------------------
void() Nih_Event =
{
	// Hoisted: fteqcc scopes locals to the FUNCTION, so the same name declared in
	// two sibling branches is a duplicate rather than two variables.
	vector src;
	entity b;

	if (ai_event_code == 2)			// zen - open the zap burst
	{
		if (!self.nih_enemy)
			return;
		if (floor(random() * 5) == 0)
			AI_SndPlay(self, CHAN_VOICE, SND_NIH_ATTACK);
		AI_Sound(self, CHAN_WEAPON, SND_NIH_BALL, 1, 0.2);
		self.nih_shoottime = time;
		self.nih_shootend  = time + 1.0;
		return;
	}

	if (ai_event_code == 3)			// prayer - the teleport ball
	{
		if (!self.nih_enemy)
			return;

		string tt = strcat(NIH_TELETOUCH, ftos(self.nih_teleport));
		string tu = strcat(NIH_TELEUSE,   ftos(self.nih_teleport));
		entity tch  = find(world, targetname, tt);
		entity trig = find(world, targetname, tu);

		if (trig || tch)
		{
			AI_SndPlay(self, CHAN_VOICE, SND_NIH_ATTACK);
			src = gettaginfo(self, 3);
			b = HVR_Make(self, src);
			b.velocity = self.origin - src;
			HVR_TeleportInit(b, self, self.nih_enemy, trig, tch);
		}
		else
		{
			// Nothing to teleport them into: bump the counter and throw a zap burst
			// instead, so the attack animation still means something.
			self.nih_teleport  = self.nih_teleport + 1;
			AI_Sound(self, CHAN_WEAPON, SND_NIH_BALL, 1, 0.2);
			self.nih_shoottime = time;
			self.nih_shootend  = time + 1.0;
		}
		return;
	}

	if (ai_event_code == 4)			// take a sphere off the recharger
	{
		if (self.nih_recharger)
			if (!Nih_EmitSphere(self))
				self.nih_recharger = world;	// full: done with this crystal
		return;
	}

	if (ai_event_code == 5)			// start up the sphere machine
	{
		AI_SndPlay(self, CHAN_VOICE, SND_NIH_RECHARGE);
		return;
	}

	if (ai_event_code == 6)			// single zap ball
	{
		if (!self.nih_enemy)
			return;
		src = gettaginfo(self, 3);
		b = HVR_Make(self, src);
		b.velocity = self.origin - src;
		HVR_ZapInit(b, self.nih_enemy);
		return;
	}

	// Codes 1 and 7 are empty in the SDK too - 7's body is commented out at
	// :1180-1188.  Recorded so nobody hunts for a missing green ball here; every
	// green ball comes from DyingThink.
};

// ---------------------------------------------------------------------------
// damage  (:1234-1273)
// ---------------------------------------------------------------------------
// TakeDamage and TraceAttack fold into one filter here because this tree has one
// hook, and they are two halves of one rule: a killing blow only lands if this
// particular hit was a headshot AND the head is open.
//
// irritation 3 is HL's per-hit latch for "the last trace hit the head" - set in
// TraceAttack, consumed and cleared in TakeDamage.  Both run per hit, in that
// order, which is exactly the order of the two halves below.
float(entity m, float damage, float dmgbits) Nih_DamageFilter =
{
	// TraceAttack's half.  .death_hitgroup is stamped before W_ApplyDamage by
	// every path that can produce one (sv_player.qc:4108 for a client hit-claim,
	// the hitscan paths directly).
	if (m.nih_irritation == 3)
		m.nih_irritation = 2;
	if (m.nih_irritation == 2 && m.death_hitgroup == HITGROUP_HEAD && damage > 2)
	{
		m.nih_irritation = 3;
		nih_dbg_headhits = nih_dbg_headhits + 1;
	}

	// TakeDamage's half.  Anything lethal is refused outright unless the head was
	// just hit; his health floors at 1 instead and the fight carries on.
	if (damage >= m.health)
	{
		if (m.nih_irritation != 3)
		{
			Nih_PainSound(m);
			return m.health - 1;
		}
		return damage;			// the head took it: this one kills
	}

	Nih_PainSound(m);
	return damage;
};

// ---------------------------------------------------------------------------
// think
// ---------------------------------------------------------------------------
void() Nih_HuntThink =
{
	self.nextthink = time + 0.1;
	AI_AnimPump(self);
	Nih_ShootBalls(self);

	if (self.health <= 0)
	{
		self.think = Nih_DyingThink;
		return;
	}

	// Hurt and holding spheres?  Drink one.  This is the healing that makes the
	// twenty orbiting balls a second health bar rather than decoration.
	if (self.health < self.max_health && Nih_AbsorbSphere(self))
		self.health = self.health + self.max_health / N_SPHERES;

	if (AI_SeqDone(self))
		Nih_NextActivity(self);

	if (self.nih_enemy && !self.nih_recharger)
	{
		if (AI_CanSee(self, self.nih_enemy))
		{
			self.nih_lastseen     = time;
			self.nih_postarget    = self.nih_enemy.origin;
			self.nih_vectarget    = HL_Normalize(self.nih_postarget - self.origin);
			self.nih_vecdesired   = self.nih_vectarget;
			self.nih_posdesired   = self.origin;
			self.nih_posdesired_z = self.nih_postarget_z + self.nih_adj;
		}
		else
		{
			// Climb while he cannot see them.  m_flAdj only ever grows, so a player
			// who hides keeps pushing him toward the ceiling - which is how he gets
			// back into the open.
			self.nih_adj = self.nih_adj + 10;
			if (self.nih_adj > 1000)
				self.nih_adj = 1000;
		}
	}

	if (self.nih_posdesired_z > self.nih_maxz) self.nih_posdesired_z = self.nih_maxz;
	if (self.nih_posdesired_z < self.nih_minz) self.nih_posdesired_z = self.nih_minz;

	Nih_Flight(self);

	// The head sprite rides his first attachment.  A real CSprite parented to the
	// attachment is not available here, so it is moved by hand each tick - same
	// position, one frame of lag on a 10 Hz think.
	if (self.nih_ball)
		setorigin(self.nih_ball, gettaginfo(self, 2));
};

// DyingThink (:424-540): he rises to n_max, fires n_dead when he gets there, and
// spends the whole climb tearing himself apart with beams and green balls.
void() Nih_DyingThink =
{
	self.nextthink = time + 0.1;
	AI_AnimPump(self);

	if (self.nih_deadflag == 0)
	{
		AI_SndPlay(self, CHAN_VOICE, SND_NIH_DIE);
		self.nih_deadflag     = 1;
		self.nih_posdesired_z = self.nih_maxz;
	}

	if (self.nih_deadflag == 1)
	{
		Nih_Flight(self);
		if (fabs(self.origin_z - self.nih_maxz) < 16)
		{
			self.nih_vel      = '0 0 0';
			self.nih_deadflag = 2;
			float fired = SV_FireTargetsByName(NIH_DEADUSE, self, USE_ON);
			if (cvar("sv_ai_debug"))
				dprint(sprintf("[nihilanth] dead at the ceiling: fired \"%s\" -> %g\n",
				               NIH_DEADUSE, fired));
		}
	}

	if (AI_SeqDone(self))
	{
		self.nih_avel_y = self.nih_avel_y + (random() * 200 - 100);
		if (self.nih_avel_y < -100) self.nih_avel_y = -100;
		if (self.nih_avel_y >  100) self.nih_avel_y =  100;
		Nih_PlaySeq(self, "die1");
	}

	if (self.nih_ball)
	{
		if (self.nih_ball.renderamt > 0)
			self.nih_ball.renderamt = self.nih_ball.renderamt - 2;
		else
		{
			remove(self.nih_ball);
			self.nih_ball = world;
		}
	}

	// The light show, and it STOPS once he reaches the ceiling.  HL's DyingThink
	// keeps spawning a beam and a green ball every tick forever, because its map
	// runs a trigger_changelevel moments later and nothing has to survive that.
	// A co-op server may sit on hl_c17 indefinitely, and ten entities a second
	// with no cap is not something to inherit.  deadflag 2 is exactly the moment
	// n_dead fires, i.e. the point the map takes over - so the whole climb, which
	// is the part anyone watches, is unchanged.
	if (self.nih_deadflag >= 2)
		return;

	// One beam per tick from a random attachment, in a random direction biased
	// away from the body.
	makevectors(self.angles);
	float att = 1 + floor(random() * 4);
	vector dir;
	do {
		dir = '1 0 0' * (random() * 2 - 1)
		    + '0 1 0' * (random() * 2 - 1)
		    + '0 0 1' * (random() * 2 - 1);
	} while (dir * dir > 1);

	if (att == 1)		{ dir_z = fabs(dir_z) * 0.5; dir = dir + 2 * v_up; }
	else if (att == 2)	{ if (dir * v_forward < 0) dir = dir * -1; dir = dir + 2 * v_forward; }
	else if (att == 3)	{ if (dir * v_right   > 0) dir = dir * -1; dir = dir - 2 * v_right; }
	else			{ if (dir * v_right   < 0) dir = dir * -1; dir = dir + 2 * v_right; }

	vector src = gettaginfo(self, att);
	traceline(src, src + dir * 4096, MOVE_NOMONSTERS, self);
	HLBeam_Multicast(HL_BEAM_ARC, self, src, trace_endpos);

	entity b = HVR_Make(self, gettaginfo(self, 1));
	b.velocity = ('1 0 0' * (random() * 1.4 - 0.7)
	            + '0 1 0' * (random() * 1.4 - 0.7)
	            + '0 0 1') * 600;
	HVR_GreenBallInit(b);
};

// .on_killed, and it exists mainly to STOP something else happening.
//
// W_ApplyDamage (sv_weapons.qc:2049) calls target.use() on a death when the target
// has a .use and NO .on_killed - and this monster's .use has a USE_OFF arm that
// shoves the player into n_ending.  Without a death handler the credits would fire
// the instant the killing blow lands, ahead of the whole death sequence he is
// meant to play on the way to the ceiling.  The comment above that branch says the
// precedence is deliberate: .on_killed is the specific handler, .use the generic
// one.  This is the specific one.
//
// It deliberately does NOT set .deadflag.  The gib path below the on_killed call
// (:2086) only runs for DEAD_DEAD, and the Nihilanth must not come apart into
// gibs - he has his own five-second disintegration.
void() Nih_Died =
{
	self.takedamage = DAMAGE_NO;
	self.think      = Nih_DyingThink;
	self.nextthink  = time + 0.1;
};

// ---------------------------------------------------------------------------
// use  (:1194-1232)
// ---------------------------------------------------------------------------
void() Nih_Use =
{
	if (sub_use_type == USE_ON)
	{
		// The fight starts.  Before this he floats and does nothing, which is what
		// the arrival cutscene is played over.
		if (self.nih_irritation == 0)
			self.nih_irritation = 1;
		return;
	}

	if (sub_use_type == USE_OFF)
	{
		// The ending: shove whoever is left into n_ending.
		entity t = Nih_RandomTargetname(NIH_DEADTOUCH);
		if (!t)
			return;
		entity who = self.nih_enemy;
		if (!who || who.health <= 0)
			who = find(world, classname, "player");
		if (who && who.health > 0)
			Nih_TouchAs(t, who);
	}
};

// ---------------------------------------------------------------------------
// spawn
// ---------------------------------------------------------------------------
void() Nih_Precache =
{
	precache_model("models/nihilanth.mdl");
	precache_model("sprites/lgtning.spr");
	precache_model("sprites/tele1.spr");
	precache_sound("debris/beamstart7.wav");
	HVR_Precache();
	AI_SndPrecache(SND_NIH_ATTACK);
	AI_SndPrecache(SND_NIH_BALL);
	AI_SndPrecache(SND_NIH_RECHARGE);
	AI_SndPrecache(SND_NIH_LAUGH);
	AI_SndPrecache(SND_NIH_PAIN);
	AI_SndPrecache(SND_NIH_DIE);
};

void() Nih_StartupThink =
{
	self.nih_irritation = 0;
	self.nih_adj        = 512;

	entity e = find(world, targetname, "n_min");
	self.nih_minz = e ? e.origin_z : -4096;
	e = find(world, targetname, "n_max");
	self.nih_maxz = e ? e.origin_z : 4096;

	// TWENTY SPHERES, emitted from HIMSELF rather than from a crystal - HL points
	// m_hRecharger at `this` for the duration of this loop and clears it again
	// afterwards (:408-413).  Without that they would all spawn at the origin.
	self.nih_recharger = self;
	float i = 0;
	while (i < N_SPHERES)
	{
		Nih_EmitSphere(self);
		i = i + 1;
	}
	self.nih_recharger = world;

	// The head glow.  Additive sprite, moved by hand in HuntThink.
	entity ball = spawn();
	ball.classname  = "nihilanth_ball";
	ball.solid      = SOLID_NOT;
	ball.movetype   = MOVETYPE_NONE;
	ball.rendermode = 5;
	ball.renderamt  = 255;
	ball.scale      = 4.0;
	setmodel(ball, "sprites/tele1.spr");
	setorigin(ball, self.origin);
	self.nih_ball = ball;

	self.think     = Nih_HuntThink;
	self.nextthink = time + 0.1;

	if (cvar("sv_ai_debug"))
		dprint(sprintf("[nihilanth] awake at %v: z %g..%g, %g sphere(s)\n",
		               self.origin, self.nih_minz, self.nih_maxz, self.nih_nspheres));
};

float() Nih_DefaultHealth =
{
	float h = cvar("sk_nihilanth_health");
	return (h > 0) ? h : 800;
};

void() monster_nihilanth =
{
	Nih_Precache();

	self.movetype = MOVETYPE_FLY;
	self.solid    = SOLID_BBOX;
	setmodel(self, "models/nihilanth.mdl");

	// The 64-unit box is HL's, and it is deliberately nothing like his size: the
	// commented-out 600x600x512 above it (:287) is what Valve tried first.  A hull
	// that big would wedge him in the chamber, and all his damage comes from
	// hitboxes and projectiles rather than from touching him.
	setsize(self, '-32 -32 0', '32 32 64');
	setorigin(self, self.origin);

	// ...and because "all his damage comes from hitboxes", the shot-cull box has to be
	// the one HL gives him, or those hitboxes are never reached: nihilanth.cpp:42-46
	// writes absmin/absmax of +-16,+-16,-48..+28 scaled by N_SCALE 15 (:25), i.e.
	// (-240,-240,-720)..(240,240,420).  Against the 64-unit hull alone,
	// World_ClipToLinks rejected him before MOVE_HITMODEL could run on anything but
	// his feet.  Not on monster_chain (no Monster_Build call), hence the side-list.
	Monster_SOCBRegister(self);

	self.flags      = self.flags | FL_MONSTER;
	// DAMAGE_YES, not HL's DAMAGE_AIM.  W_CanDamageTarget (sv_weapons.qc:1279)
	// rejects anything whose .takedamage is not exactly DAMAGE_YES, and every
	// hitscan, pellet, melee, projectile and trigger_hurt path in the tree funnels
	// through it — so a DAMAGE_AIM boss is simply unshootable.  HL's constant means
	// "damageable AND an autoaim target", a distinction this tree does not draw.
	// Caught by the self-test: a 9999-damage hit left him on 800.
	self.takedamage = DAMAGE_YES;
	self.health     = Nih_DefaultHealth();
	self.max_health = self.health;
	self.view_ofs   = '0 0 300';
	self.bloodcolor = 195;

	self.nih_vecdesired   = '1 0 0';
	self.nih_posdesired   = self.origin;
	self.nih_posdesired_z = 512;
	self.nih_level        = 1;
	self.nih_teleport     = 1;

	self.ai_damagefilter = Nih_DamageFilter;
	self.ai_event        = Nih_Event;
	self.use             = Nih_Use;
	self.on_killed       = Nih_Died;	// must outrank .use — see Nih_Died

	self.ai_seq = -1;
	Nih_PlaySeq(self, "float");

	self.think     = Nih_StartupThink;
	self.nextthink = time + 0.1;
};

// ---------------------------------------------------------------------------
// boot self-test  (sv_nihilanth_selftest)
// ---------------------------------------------------------------------------
// Three things this checks that nothing else can on a map with no players: that
// the rig carries every sequence name the ladder asks for; that hl_c17's support
// entities all resolve; and that he actually emits his twenty spheres and starts
// flying.  The last one is the difference between "he spawned" and "the fight
// works", and it is invisible otherwise - a Nihilanth stuck at irritation 0
// hovers exactly like one that is working.
float  nih_selftest_phase;
float  nih_selftest_at;
vector nih_selftest_seed;

void() Nih_SelfTest =
{
	if (!cvar("sv_nihilanth_selftest") || nih_selftest_phase >= 3)
		return;
	if (nih_selftest_at <= 0)
		nih_selftest_at = 3;
	if (time < nih_selftest_at)
		return;

	entity n = find(world, classname, "monster_nihilanth");

	// Hoisted for the same fteqcc function-scope reason as Nih_Event's: `bad` and
	// `i` are wanted in more than one phase.
	float bad = 0;
	float i;

	// PHASE 2 - the kill gate.  Two lethal hits, differing only in hitgroup: the
	// first must be refused and the second must land.  That pair IS the boss
	// fight's rule, and nothing else in a headless run can reach it.
	if (nih_selftest_phase == 2)
	{
		nih_selftest_phase = 3;
		if (!n)
			return;

		n.nih_irritation = 2;			// head open, rechargers spent
		n.health         = 400;

		n.death_hitgroup = HITGROUP_GENERIC;
		W_ApplyDamage(world, n, 9999);
		float survived = (n.health > 0);

		n.death_hitgroup = HITGROUP_HEAD;
		W_ApplyDamage(world, n, 9999);
		float killed = (n.health <= 0);

		if (!survived)	bad = bad + 1;		// a body shot must not kill him
		if (!killed)	bad = bad + 1;		// a head shot must

		print(sprintf("[nihtest] killgate: bodyshot survived=%g headshot killed=%g headhits=%g BAD=%g\n",
		              survived, killed, nih_dbg_headhits, bad));
		return;
	}

	// PHASE 1 - did the wake-up take, and did the big hit in phase 0 get soaked
	// up by the spheres rather than killing him?
	if (nih_selftest_phase == 1)
	{
		nih_selftest_phase = 2;
		nih_selftest_at    = time + 2;
		if (!n)
		{
			nih_selftest_phase = 3;
			return;
		}

		float moved = (vlen(n.origin - nih_selftest_seed) > 8);
		float balls = 0;
		entity b = find(world, classname, "nihilanth_energy_ball");
		while (b)
		{
			balls = balls + 1;
			b = find(b, classname, "nihilanth_energy_ball");
		}

		if (!moved)			bad = bad + 1;	// the flight integrator never ran
		if (n.health <= 0)		bad = bad + 1;	// he is not killable yet
		if (n.nih_irritation < 1)	bad = bad + 1;	// phase 0 woke him
		if (nih_dbg_absorbed < 1)	bad = bad + 1;	// he never drank a sphere

		// Folded into one string first: fteqcc caps a varargs call at EIGHT
		// parameters INCLUDING the format, and this wants ten.
		string tail = sprintf("health=%g spheres=%g live=%g irritation=%g level=%g",
		                      n.health, n.nih_nspheres, balls,
		                      n.nih_irritation, n.nih_level);
		print(sprintf("[nihtest] moved=%g %s emitted=%g absorbed=%g BAD=%g\n",
		              moved, tail, nih_dbg_spheres, nih_dbg_absorbed, bad));
		return;
	}

	nih_selftest_phase = 1;
	nih_selftest_at    = time + 5;

	// Sequence names first - they are checked even with no Nihilanth placed,
	// because a replacement rig that lacks one would strand him mid-ladder and
	// this is the cheapest place to find that out.
	float mi = getmodelindex("models/nihilanth.mdl");
	// "-" rather than an empty list when the rig was never precached, because a
	// map with no Nihilanth would otherwise print `missing:[]` and read as a pass
	// on a check that never ran.
	string missing = "-";
	if (mi > 0)
	{
		missing = "";
		string want = "float attack1 attack2 recharge float_open attack1_open die1 walk_u walk_d walk_l walk_r";
		float cnt = tokenize(want);
		for (i = 0; i < cnt; i = i + 1)
			if (!AI_SeqNameExists(mi, argv(i)))
			{
				missing = strcat(missing, argv(i), " ");
				bad = bad + 1;
			}
	}

	// Then the map's support set.  Each of these is a beat of the fight and a
	// missing one is silent: he simply never does that thing.
	float rech = 0, draw = 0, tele = 0, tport = 0;
	for (i = 1; i <= 9; i = i + 1)
	{
		if (find(world, targetname, strcat(NIH_RECHARGER, ftos(i)))) rech  = rech + 1;
		if (find(world, targetname, strcat(NIH_DRAWUSE,   ftos(i)))) draw  = draw + 1;
		if (find(world, targetname, strcat(NIH_TELEUSE,   ftos(i)))) tele  = tele + 1;
		if (find(world, targetname, strcat(NIH_TELETOUCH, ftos(i)))) tport = tport + 1;
	}
	float bounds = (find(world, targetname, "n_min") ? 1 : 0)
	             + (find(world, targetname, "n_max") ? 1 : 0);
	float ending = (find(world, targetname, NIH_DEADUSE)   ? 1 : 0)
	             + (find(world, targetname, NIH_DEADTOUCH) ? 1 : 0);

	string sup = sprintf("recharger=%g draw=%g leaving=%g teleport=%g",
	                     rech, draw, tele, tport);
	print(sprintf("[nihtest] seqs missing:[%s] %s bounds=%g/2 ending=%g/2 BAD=%g\n",
	              missing, sup, bounds, ending, bad));

	if (!n)
	{
		print("[nihtest] no monster_nihilanth on this map; gate only, BAD=0\n");
		nih_selftest_phase = 3;
		return;
	}

	// Wake him, the way the map's own trigger does, and remember where he was so
	// phase 1 can tell whether the flight integrator ran.
	nih_selftest_seed = n.origin;
	entity oldself = self;
	float  oldut   = sub_use_type;
	self = n;
	sub_use_type = USE_ON;
	Nih_Use();
	self = oldself;
	sub_use_type = oldut;

	// Then hit him hard enough to kill anything.  Through W_ApplyDamage, not by
	// writing .health, so the whole chain runs: W_CanDamageTarget, the
	// .ai_damagefilter hook, the clamp.  He must come out of it alive on 1 health
	// and then spend the next five seconds drinking his own spheres back up,
	// which is the mechanic that makes the first two thirds of this fight.
	n.death_hitgroup = HITGROUP_GENERIC;
	W_ApplyDamage(world, n, 9999);
	if (cvar("sv_ai_debug"))
		dprint(sprintf("[nihtest] after a 9999 body hit: health=%g\n", n.health));
};
