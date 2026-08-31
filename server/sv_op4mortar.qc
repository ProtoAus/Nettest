//
//  sv_op4mortar.qc  —  op4mortar / func_op4mortarcontroller
//
//  Opposing Force's emplaced mortar and the brushes a player uses to aim it.
//  Both classes are in sven-coop.fgd and neither existed here, so a map that
//  placed them got two inert relays and a decorative hole in the ground.
//
//  THERE IS NO OPPOSING FORCE SDK ON THIS MACHINE.  halflife/ is the base HL
//  SDK, which has no op4mortar.cpp, so the FGD is the authority for everything
//  below and nothing is invented past it:
//
//    sven-coop.fgd:5074  @PointClass base(Targetname, AttackObject)
//                        studio("models/mortar.mdl") = op4mortar
//        spawnflags  1 Active / 16 Line of Sight (FGD default ON) / 32 Can Control
//        mortar_velocity 800   h_min -90   h_max 90
//        mindist 256   maxdist 2048   firedelay 5
//        is_player_ally 0      (+ classify, from AttackObject)
//
//    sven-coop.fgd:2343  @SolidClass base(Target, ZHLTbmodel)
//                        = func_op4mortarcontroller
//        mortar_axis  0 Vertical / 1 Horizontal
//
//  Where the FGD is silent - what the shell looks like, how fast it arms, what
//  it does to the world - this reuses what the tree already has rather than
//  inventing a second convention: W_RadiusExplode for the blast and
//  CSQC_EVENT_ENV_EXPLOSION for the visual, exactly as func_tankrocket does
//  (sv_th_entities.qc:2010-2044).
//
//  desertcircle is the reference placement: one `mortar1` at -3232 3104 288,
//  spawnflags 33 (Active + Can Control, Line of Sight explicitly CLEARED),
//  firedelay 10, maxdist 4500, h_min/h_max +-120, mortar_velocity 1000, plus two
//  controller brushes (*22 vertical, *23 horizontal) and a func_button, and a
//  trigger_relay that fires it when the cannoneer beside it is hurt.
//

// ---------------------------------------------------------------------------
//  Keys and flags
// ---------------------------------------------------------------------------
const float OP4M_SF_ACTIVE     = 1;
const float OP4M_SF_LOS        = 16;
const float OP4M_SF_CANCONTROL = 32;

const float OP4M_AXIS_VERTICAL   = 0;
const float OP4M_AXIS_HORIZONTAL = 1;

const float OP4M_THINK_IV     = 0.1;
const float OP4M_SHELL_DAMAGE = 120;
const float OP4M_SHELL_RADIUS = 250;
const float OP4M_SHELL_MINDMG = 20;
const float OP4M_SHELL_PUSH   = 500;
const float OP4M_SHELL_LIFT   = 200;

// Pitch limits.  The FGD gives an arc for the HORIZONTAL axis only (h_min/h_max)
// and says nothing about elevation, so the vertical controller gets a sane fixed
// range rather than a guessed key: a mortar points up.
const float OP4M_PITCH_MIN = -75;	// nose up (QC pitch is inverted)
const float OP4M_PITCH_MAX = 0;		// level

.float mortar_velocity;
.float h_min;
.float h_max;
.float mindist;
.float maxdist;
.float firedelay;
.float mortar_axis;

.entity op4m_operator;		// the player currently on the controls, or world
.entity op4m_link;		// controller -> its mortar, resolved once
.vector op4m_base_angles;	// spawn orientation; both arcs are measured from it
.float  op4m_nextfire;
.float  op4m_nextscan;		// throttle on the all-entity target sweep
.float  op4m_active;

void() op4mortar_think;

// ---------------------------------------------------------------------------
//  The shell
// ---------------------------------------------------------------------------
void() op4mortar_shell_explode =
{
	entity atk;

	WriteByte(MSG_MULTICAST, SVC_CGAMEPACKET);
	WriteByte(MSG_MULTICAST, CSQC_EVENT_ENV_EXPLOSION);
	WriteCoord(MSG_MULTICAST, self.origin_x);
	WriteCoord(MSG_MULTICAST, self.origin_y);
	WriteCoord(MSG_MULTICAST, self.origin_z + 8);
	WriteShort(MSG_MULTICAST, OP4M_SHELL_DAMAGE);
	WriteByte(MSG_MULTICAST, 0);		// element mask: the full GoldSrc boom
	multicast(self.origin, MULTICAST_PVS);

	sound(self, CHAN_WEAPON, "weapons/mortarhit.wav", 1, ATTN_NORM);

	// An operator who disconnected mid-flight leaves a recycled edict behind, so
	// re-verify rather than trust the stored reference - the same guard, and for
	// the same reason, as TankRocket_RocketExplode (sv_th_entities.qc:2035).
	atk = self.owner;
	if (atk.classname != "player")
		atk = world;

	W_RadiusExplode(self.origin, OP4M_SHELL_RADIUS,
	                OP4M_SHELL_DAMAGE, OP4M_SHELL_MINDMG,
	                OP4M_SHELL_PUSH, OP4M_SHELL_LIFT, atk);

	remove(self);
};

void() op4mortar_shell_touch =
{
	// The engine already skips owner/ownee pairs in SV_ClipToLinks, but the shell
	// is launched from inside the mortar's own bbox and `owner` is the OPERATOR,
	// not the mortar - so the tube needs an explicit pass.
	if (other == self.enemy)
		return;
	op4mortar_shell_explode();
};

// Launch one shell from `mortar` along `dir` at `speed`.
void(entity mortar, vector src, vector dir, float speed) op4mortar_launch =
{
	entity sh = spawn();
	sh.classname = "op4mortar_shell";
	sh.movetype  = MOVETYPE_TOSS;		// gravity: this is artillery, not a rifle
	sh.solid     = SOLID_BBOX;
	sh.owner     = mortar.op4m_operator;	// who gets credit for the kill
	sh.enemy     = mortar;			// the tube, for the touch pass-through
	setmodel(sh, "models/grenade.mdl");
	setsize(sh, '0 0 0', '0 0 0');
	setorigin(sh, src);
	sh.velocity  = dir * speed;
	sh.avelocity = '300 300 300';
	sh.touch     = op4mortar_shell_touch;

	// A shell that flies out of the world would otherwise leak an edict per shot
	// on a mortar with firedelay 5 and nothing in range.
	sh.think     = op4mortar_shell_explode;
	sh.nextthink = time + 15;

	sound(mortar, CHAN_WEAPON, "weapons/ofmortar.wav", 1, ATTN_NORM);
};

// ---------------------------------------------------------------------------
//  Ballistics
// ---------------------------------------------------------------------------
// Solve the launch elevation for a shell of speed v to land on `target`.
//
//   tan(theta) = ( v^2 +- sqrt( v^4 - g*(g*dx^2 + 2*dy*v^2) ) ) / (g*dx)
//
// The HIGH root is taken deliberately: both roots hit, and the low one is a
// direct-fire trajectory, which is not what a mortar is - it lobs over things.
// That also makes the Line of Sight spawnflag meaningful rather than redundant.
//
// No atan is needed anywhere.  With t = tan(theta),
//   cos(theta) = 1/sqrt(1+t^2)   sin(theta) = t/sqrt(1+t^2)
// so the velocity components fall straight out of the tangent.
//
// Returns '0 0 0' when the target is out of ballistic reach (negative
// discriminant), which the caller reads as "hold fire" - the shell would land
// short no matter where the tube pointed.
vector(vector src, vector target, float speed) op4mortar_solve =
{
	float g = cvar("sv_gravity");
	if (g <= 0)
		g = 800;

	vector delta = target - src;
	vector flat  = delta;
	flat_z = 0;
	float dx = vlen(flat);
	if (dx < 1)
		return '0 0 0';			// straight up: no solution worth having
	float dy = delta_z;

	float v2   = speed * speed;
	float disc = v2 * v2 - g * (g * dx * dx + 2 * dy * v2);
	if (disc < 0)
		return '0 0 0';			// out of range at this muzzle velocity

	float t = (v2 + sqrt(disc)) / (g * dx);
	float inv = 1 / sqrt(1 + t * t);

	vector dir = flat * (1 / dx) * inv;	// horizontal component, unit * cos
	dir_z = t * inv;			// vertical component, sin
	return dir;
};

// ---------------------------------------------------------------------------
//  Target selection
// ---------------------------------------------------------------------------
// SCOPE, STATED: `is_player_ally` is the only allegiance input actually used.
// The FGD's `classify` is parsed and stored but not consulted, because this
// entity is not a monster - it has no .ai_class, is not in the monster chain and
// never consults the faction matrix.  A mortar therefore shells players, or
// shells monsters when the mapper flipped it.  Both FGD values behave; the
// twenty-way classify enum does not, and pretending otherwise would be worse
// than saying so.
float(entity mortar, entity cand) op4mortar_valid =
{
	if (cand == world)          return FALSE;
	if (cand.health <= 0)       return FALSE;
	if (cand.solid == SOLID_NOT) return FALSE;

	if (mortar.is_player_ally)
	{
		if (!(cand.flags & FL_MONSTER))
			return FALSE;
	}
	else
	{
		if (cand.classname != "player")
			return FALSE;
	}

	float d = vlen(cand.origin - mortar.origin);
	if (mortar.mindist > 0 && d < mortar.mindist) return FALSE;
	if (mortar.maxdist > 0 && d > mortar.maxdist) return FALSE;

	// Inside the traverse the mapper allowed.  h_min/h_max are measured from the
	// spawn yaw, which is why op4m_base_angles is latched rather than read back
	// off .angles - the tube moves.
	vector to = cand.origin - mortar.origin;
	float want = vectoyaw(to);
	float off  = anglemod(want - mortar.op4m_base_angles_y + 180) - 180;
	if (off < mortar.h_min || off > mortar.h_max)
		return FALSE;

	// Spawnflag 16.  The FGD defaults it ON; desertcircle explicitly clears it so
	// its mortar can shell the far side of a wall, which is the whole point of
	// indirect fire.
	if (mortar.spawnflags & OP4M_SF_LOS)
	{
		traceline(mortar.origin + '0 0 32', cand.origin + '0 0 16', MOVE_NOMONSTERS, mortar);
		if (trace_fraction < 1)
			return FALSE;
	}
	return TRUE;
};

entity(entity mortar) op4mortar_findtarget =
{
	entity best = world;
	float  bestd = 0;
	entity e;

	for (e = world; (e = nextent(e)); )
	{
		if (!op4mortar_valid(mortar, e))
			continue;
		float d = vlen(e.origin - mortar.origin);
		if (best == world || d < bestd)
		{
			best  = e;
			bestd = d;
		}
	}
	return best;
};

// ---------------------------------------------------------------------------
//  Firing
// ---------------------------------------------------------------------------
vector(entity mortar) op4mortar_muzzle =
{
	return mortar.origin + '0 0 48';
};

void(entity mortar, vector dir) op4mortar_fire =
{
	float v = mortar.mortar_velocity;
	if (v <= 0)
		v = 800;			// FGD default

	op4mortar_launch(mortar, op4mortar_muzzle(mortar), dir, v);

	float fd = mortar.firedelay;
	if (fd <= 0)
		fd = 5;				// FGD default
	mortar.op4m_nextfire = time + fd;
};

// ---------------------------------------------------------------------------
//  Think
// ---------------------------------------------------------------------------
void() op4mortar_think =
{
	self.nextthink = time + OP4M_THINK_IV;

	// A player on the controls owns the tube outright - no auto-fire while
	// somebody is aiming it, or the mortar would shoot out from under them.
	if (self.op4m_operator != world)
	{
		entity p = self.op4m_operator;
		if (p.health <= 0 || p.classname != "player")
		{
			self.op4m_operator = world;
			return;
		}

		// Each controller drives ONE axis, but the mortar has to hold both, so the
		// aim accumulates onto .angles and each axis is clamped to its own arc.
		// Which axis is live was latched onto the mortar at mount time from the
		// brush the operator actually used.
		if (self.mortar_axis == OP4M_AXIS_HORIZONTAL)
		{
			float off = anglemod(p.v_angle_y - self.op4m_base_angles_y + 180) - 180;
			off = bound(self.h_min, off, self.h_max);
			self.angles_y = self.op4m_base_angles_y + off;
		}
		else
		{
			self.angles_x = bound(OP4M_PITCH_MIN, p.v_angle_x, OP4M_PITCH_MAX);
		}
		self.SendFlags = 1;

		if (p.button0 && time >= self.op4m_nextfire)
		{
			makevectors(self.angles);
			op4mortar_fire(self, v_forward);
		}
		return;
	}

	if (!self.op4m_active)
		return;
	if (time < self.op4m_nextfire)
		return;
	// op4mortar_findtarget is an all-entity sweep, and an ACTIVE mortar with
	// nothing in its band reaches it on every think - 10 Hz across 568 entities on
	// desertcircle, forever, for an answer that cannot change that fast.  The
	// reload gate above does not cover this: it is only pushed forward when a shot
	// is actually taken.
	if (time < self.op4m_nextscan)
		return;
	self.op4m_nextscan = time + 0.5;

	entity t = op4mortar_findtarget(self);
	if (t == world)
		return;

	float v = self.mortar_velocity;
	if (v <= 0)
		v = 800;

	vector src = op4mortar_muzzle(self);
	vector dir = op4mortar_solve(src, t.origin, v);
	if (dir == '0 0 0')
		return;				// out of ballistic reach; try again next think

	// Point the tube where the solution says, so the model visibly tracks.
	self.angles_y = vectoyaw(dir);
	self.angles_x = 0 - asin(dir_z) * 180 / M_PI;
	self.SendFlags = 1;

	op4mortar_fire(self, dir);
};

void() op4mortar_use =
{
	// USE_UNSET means "toggle", the tree-wide convention: USE_OFF is 0 and a
	// truthiness test would silently discard it.
	float ut = (sub_use_type == USE_UNSET) ? USE_TOGGLE : sub_use_type;

	if (ut == USE_ON)       self.op4m_active = TRUE;
	else if (ut == USE_OFF) self.op4m_active = FALSE;
	else                    self.op4m_active = !self.op4m_active;

	if (cvar("sv_debug_use"))
		print(sprintf("[op4mortar] \"%s\" active=%g\n",
		              self.targetname, self.op4m_active));
};

/*QUAKED op4mortar (.8 .5 .2) (-16 -16 0) (16 16 48) ACTIVE x x x LOS CANCONTROL
Opposing Force emplaced mortar.  Lobs shells at whatever it is hostile to.

"mortar_velocity"  muzzle speed (default 800)
"h_min" "h_max"    traverse arc in degrees, measured from the spawn yaw
"mindist" "maxdist" engagement band
"firedelay"        seconds between shots (default 5)
"is_player_ally"   0 shells players (default), 1 shells monsters
"classify"         parsed, NOT consulted - see op4mortar_valid
*/
void() op4mortar =
{
	precache_model("models/mortar.mdl");
	precache_model("models/grenade.mdl");
	precache_sound("weapons/ofmortar.wav");
	precache_sound("weapons/mortarhit.wav");

	setmodel(self, "models/mortar.mdl");
	self.movetype = MOVETYPE_NONE;
	self.solid    = SOLID_BBOX;
	setorigin(self, self.origin);

	self.op4m_base_angles = self.angles;
	self.op4m_operator    = world;
	self.use              = op4mortar_use;

	// FGD defaults, applied only where the map said nothing.  h_min/h_max are
	// signed and a map may legitimately write 0, so they are defaulted as a PAIR
	// on "both absent" rather than individually on "falsy".
	if (!self.h_min && !self.h_max) { self.h_min = -90; self.h_max = 90; }
	if (!self.mindist)  self.mindist  = 256;
	if (!self.maxdist)  self.maxdist  = 2048;
	if (!self.firedelay) self.firedelay = 5;
	if (!self.mortar_velocity) self.mortar_velocity = 800;

	self.op4m_active = (self.spawnflags & OP4M_SF_ACTIVE) ? TRUE : FALSE;

	self.think     = op4mortar_think;
	self.nextthink = time + 0.5;
};

// ---------------------------------------------------------------------------
//  The controller brushes
// ---------------------------------------------------------------------------
// Mount / dismount, modelled on tankcontrols_use (sv_goldsrc_compat.qc:1697).
// The one structural difference is mortar_axis: a func_tank is aimed by a single
// controls brush, whereas a mortar has one brush PER AXIS, so the mount records
// which axis this brush drives.
void() op4mortarcontroller_use =
{
	if (!self.op4m_link || self.op4m_link.classname != "op4mortar")
		self.op4m_link = find(world, targetname, self.target);
	if (!self.op4m_link)
		return;

	entity mortar = self.op4m_link;

	if (!(mortar.spawnflags & OP4M_SF_CANCONTROL))
		return;

	if (mortar.op4m_operator == activator)
	{
		// Same player, same brush: dismount.  A player on the vertical brush who
		// +uses the HORIZONTAL one just changes axis, which is how a two-brush
		// mortar is meant to be driven.
		if (mortar.mortar_axis == self.mortar_axis)
		{
			activator.pm_movetype = PM_MOVETYPE_NORMAL;
			mortar.op4m_operator  = world;
			return;
		}
		mortar.mortar_axis = self.mortar_axis;
		return;
	}

	if (mortar.op4m_operator != world)
		return;				// someone else is on it

	mortar.op4m_operator  = activator;
	mortar.mortar_axis    = self.mortar_axis;
	activator.pm_movetype = PM_MOVETYPE_NONE;
	activator.velocity    = '0 0 0';
};

/*QUAKED func_op4mortarcontroller (0 .3 .8) ?
Brush you +use to aim the op4mortar named by "target".

"mortar_axis"  0 = Vertical (elevation), 1 = Horizontal (traverse)
*/
void() func_op4mortarcontroller =
{
	SV_InitReplicatedSolidBrush();
	self.brush_type = BRUSH_TYPE_STATIC;
	self.solid      = SOLID_BSP;
	self.use        = op4mortarcontroller_use;
};
