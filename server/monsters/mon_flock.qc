// server/monsters/mon_flock.qc
// ----------------------------------------------------------------------------
// monster_flyer_flock / monster_flyer — Half-Life's Xen boids (dlls/aflock.cpp).
//
// Three placements, all on hl_c18, all identical: iFlockSize 3, flFlockRadius
// 128.  Nine birds between them, and until now nine nothings — the flock spawner
// fell through to SV_OnEntityNoSpawnFunction, so hl_c18's sky was empty.
//
// A flock is a leader plus followers.  The leader flies forward, feels its way
// around obstacles with three forward traces, and turns toward whichever side has
// more room; the followers copy its heading, chase or hang back to hold station,
// and shove each other apart when they crowd.  That is the whole algorithm, and
// it is worth transcribing rather than approximating because it is what makes a
// flock read as a flock rather than as three things flying in a line.
//
// ---------------------------------------------------------------------------
// WHAT IS NOT REPRODUCIBLE
// ---------------------------------------------------------------------------
// BoidAdvanceFrame (aflock.cpp:340-361) sets pev->framerate from how hard the
// boid is accelerating, so a bird flaps faster when it is working.  A networked
// HL model in this engine plays at the model's own fps from whenever .frame last
// changed and there is no rate in entity_state_t — the same limitation
// mon_tentacle.qc's header sets out.  boid.mdl carries exactly ONE sequence
// ("idle", checked, not assumed), so there is no second sequence to fake it with
// either.
//
// The rest of BoidAdvanceFrame IS reproducible and is kept, because it is the
// half you actually see: .avelocity carries the lean and the bank, and avelocity
// is a real entvar the engine integrates for MOVETYPE_FLY.  A boid that banks
// into its turns still reads as a bird; one that does not reads as a paper dart.
//
// ---------------------------------------------------------------------------
// Two classnames, one file.  monster_flyer_flock is a SPAWNER — it creates its
// boids and removes itself (:150-157) — and monster_flyer is a single boid that
// recruits its neighbours into a squad at map start.  Both exist in the SDK and
// only the flock form appears in the corpus, but the loose form is nine lines on
// top of the flock's and a map that uses it would otherwise be silently empty.
// ----------------------------------------------------------------------------

const float AFLOCK_RECRUIT_RADIUS = 1024;
const float AFLOCK_FLY_SPEED      = 125;
const float AFLOCK_TURN_RATE      = 75;
const float AFLOCK_ACCELERATE     = 10;
const float AFLOCK_CHECK_DIST     = 192;
const float AFLOCK_TOO_CLOSE      = 100;
const float AFLOCK_TOO_FAR        = 256;

// The two map keys.  Spelled exactly as the FGD and the BSPs spell them —
// CamelCase iFlockSize with a lower i, and flFlockRadius — because ED_FindField
// is a plain strcmp.  The case-fold retry in ED_ParseUnknownEpair would catch a
// lowercase variant, but a key that binds directly never reaches that hook.
.float  iFlockSize;
.float  flFlockRadius;

.entity boid_leader;		// m_pSquadLeader; a leader points at itself
.entity boid_next;		// m_pSquadNext, a plain singly-linked list
.float  boid_turning;		// m_fTurning
.float  boid_blocked_at;	// m_flLastBlockedTime
.float  boid_fakeblock_at;	// m_flFakeBlockedTime
.float  boid_alert_until;	// m_flAlertTime
.float  boid_nextsound;		// m_flFlockNextSoundTime
.float  boid_goalspeed;		// m_flGoalSpeed
.float  boid_speed;		// pev->speed

const string SND_BOID_IDLE  = "boid/boid_idle1.wav boid/boid_idle2.wav";
const string SND_BOID_ALERT = "boid/boid_alert1.wav boid/boid_alert2.wav";

void() Boid_IdleThink;
void() Boid_LeaderThink;
void() Boid_FollowerThink;

float boid_dbg_spawned;
float boid_dbg_turns;

// ---------------------------------------------------------------------------
// squad plumbing
// ---------------------------------------------------------------------------
float(entity b) Boid_IsLeader = { return (b.boid_leader == b); };

void(entity lead, entity add) Boid_SquadAdd =
{
	add.boid_leader = lead;
	add.boid_next   = lead.boid_next;
	lead.boid_next  = add;
};

// SquadRemove (:832 onward).  The leader dying is the interesting case: HL hands
// leadership to the next member rather than disbanding, which is why shooting the
// front bird does not stop the flock.
void(entity lead, entity gone) Boid_SquadRemove =
{
	if (!lead || !gone)
		return;

	if (lead == gone)
	{
		entity nl = gone.boid_next;
		entity w  = nl;
		while (w)
		{
			w.boid_leader = nl;
			w = w.boid_next;
		}
		gone.boid_leader = world;
		gone.boid_next   = world;
		return;
	}

	entity p = lead;
	while (p && p.boid_next != gone)
		p = p.boid_next;
	if (p)
		p.boid_next = gone.boid_next;
	gone.boid_leader = world;
	gone.boid_next   = world;
};

void(entity b) Boid_MakeSound =
{
	if (b.boid_alert_until > time)
		AI_SndPlay(b, CHAN_WEAPON, SND_BOID_ALERT);
	else
		AI_SndPlay(b, CHAN_WEAPON, SND_BOID_IDLE);
};

// ---------------------------------------------------------------------------
// BoidAdvanceFrame (:340-361), minus the framerate — see the header
// ---------------------------------------------------------------------------
void(entity b) Boid_AdvanceFrame =
{
	// armorvalue is HL's low-pass filter on speed and the only thing flapspeed is
	// computed from.  Kept even though the flap itself is not reachable, because
	// the LEAN is scaled by it: a boid that is accelerating hard pitches its nose
	// down further than one holding station.
	float flap = (b.boid_speed - b.armorvalue) / AFLOCK_ACCELERATE;
	b.armorvalue = b.armorvalue * 0.8 + b.boid_speed * 0.2;

	if (flap < 0)		flap = 0 - flap;
	if (flap < 0.25)	flap = 0.25;
	if (flap > 1.9)		flap = 1.9;

	// Lean, then bank.  Both are written as a corrective toward zero rather than
	// as a rate, which is why they read as self-levelling: the angular velocity is
	// whatever would undo the current tilt in one second, plus the new tilt.
	b.avelocity_x = 0 - (b.angles_x + flap * 5);
	b.avelocity_z = 0 - (b.angles_z + b.avelocity_y);
};

// FPathBlocked (:500-565).  Three parallel traces rather than one, so a boid
// aimed at the edge of a pillar still sees it.
float(entity b) Boid_PathBlocked =
{
	if (b.boid_fakeblock_at > time)
	{
		// The FAKE BLOCK, and it is not a bug.  A boid that has flown clear for
		// six seconds invents an obstacle so it turns anyway — without it a flock
		// in an open Xen sky flies in a dead straight line until it hits the far
		// wall.
		b.boid_blocked_at = time;
		return TRUE;
	}

	makevectors(b.angles);
	float blocked = FALSE;

	traceline(b.origin, b.origin + v_forward * AFLOCK_CHECK_DIST, MOVE_NOMONSTERS, b);
	if (trace_fraction != 1) { b.boid_blocked_at = time; blocked = TRUE; }

	vector r = v_right * 12;
	traceline(b.origin + r, b.origin + r + v_forward * AFLOCK_CHECK_DIST, MOVE_NOMONSTERS, b);
	if (trace_fraction != 1) { b.boid_blocked_at = time; blocked = TRUE; }

	traceline(b.origin - r, b.origin - r + v_forward * AFLOCK_CHECK_DIST, MOVE_NOMONSTERS, b);
	if (trace_fraction != 1) { b.boid_blocked_at = time; blocked = TRUE; }

	if (!blocked && time - b.boid_blocked_at > 6)
		b.boid_fakeblock_at = time + 1 + floor(random() * 3);

	return blocked;
};

// SpreadFlock (:449-476): the LEADER pushes everyone else away from itself.
void(entity b) Boid_SpreadFlock =
{
	entity l = b.boid_leader;
	while (l)
	{
		if (l != b && vlen(b.origin - l.origin) <= AFLOCK_TOO_CLOSE)
		{
			vector dir = HL_Normalize(l.origin - b.origin);
			float  sp  = vlen(l.velocity);
			l.velocity = (HL_Normalize(l.velocity) + dir) * 0.5 * sp;
		}
		l = l.boid_next;
	}
};

// SpreadFlock2 (:483-499): a FOLLOWER pushes ITSELF away from everyone else.
// HL's comment insists the caller's velocity must be normalised first, and it is
// — FlockFollowerThink normalises immediately before calling.
void(entity b) Boid_SpreadFlock2 =
{
	entity l = b.boid_leader;
	while (l)
	{
		if (l != b && vlen(b.origin - l.origin) <= AFLOCK_TOO_CLOSE)
			b.velocity = b.velocity + HL_Normalize(b.origin - l.origin);
		l = l.boid_next;
	}
};

// ---------------------------------------------------------------------------
// FlockLeaderThink (:556-668)
// ---------------------------------------------------------------------------
void() Boid_LeaderThink =
{
	self.nextthink = time + 0.1;
	makevectors(self.angles);

	if (!Boid_PathBlocked(self))
	{
		if (self.boid_turning)
		{
			self.boid_turning = FALSE;
			self.avelocity_y  = 0;
		}
		if (self.boid_speed <= AFLOCK_FLY_SPEED)
			self.boid_speed = self.boid_speed + 5;

		self.velocity = v_forward * self.boid_speed;
		Boid_AdvanceFrame(self);
		return;
	}

	if (!self.boid_turning)
	{
		// Which way has more room.  A tie is broken by a coin flip rather than by
		// a default, so two boids meeting the same wall do not both go left.
		traceline(self.origin, self.origin + v_right * AFLOCK_CHECK_DIST, MOVE_NOMONSTERS, self);
		float rs = vlen(trace_endpos - self.origin);
		traceline(self.origin, self.origin - v_right * AFLOCK_CHECK_DIST, MOVE_NOMONSTERS, self);
		float ls = vlen(trace_endpos - self.origin);

		self.boid_turning = TRUE;
		boid_dbg_turns    = boid_dbg_turns + 1;

		if (rs > ls)
			self.avelocity_y = 0 - AFLOCK_TURN_RATE;
		else if (ls > rs)
			self.avelocity_y = AFLOCK_TURN_RATE;
		else if (random() < 0.5)
			self.avelocity_y = AFLOCK_TURN_RATE;
		else
			self.avelocity_y = 0 - AFLOCK_TURN_RATE;
	}

	Boid_SpreadFlock(self);
	self.velocity = v_forward * self.boid_speed;

	// Do not fly into the floor.  Cheap and unconditional, because a boid that
	// clips scenery on Xen ends up under it.
	traceline(self.origin, self.origin - '0 0 16', MOVE_NOMONSTERS, self);
	if (trace_fraction != 1 && self.velocity_z < 0)
		self.velocity_z = 0;

	if (self.flags & FL_ONGROUND)
	{
		setorigin(self, self.origin + '0 0 1');
		self.velocity_z = 0;
	}

	if (self.boid_nextsound < time)
	{
		Boid_MakeSound(self);
		self.boid_nextsound = time + 1 + random() * 2;
	}

	Boid_AdvanceFrame(self);
};

// ---------------------------------------------------------------------------
// FlockFollowerThink (:673-742)
// ---------------------------------------------------------------------------
void() Boid_FollowerThink =
{
	self.nextthink = time + 0.1;

	if (Boid_IsLeader(self) || !self.boid_leader)
	{
		// The leader died and this bird has just inherited the job.
		self.think = Boid_LeaderThink;
		return;
	}

	entity lead = self.boid_leader;
	vector tolead = lead.origin - self.origin;
	float  dist   = vlen(tolead);

	// Heading is COPIED, not steered toward.  This is what keeps a flock in
	// formation instead of letting it fan out, and it is also why only the leader
	// needs obstacle avoidance.
	self.angles = lead.angles;

	// FInViewCone with the boid's m_flFieldOfView of 0.2.  Out of the cone means
	// the leader is behind us, so slow down and let it back in front.
	makevectors(self.angles);
	float infront = (dist > 0) ? (HL_Normalize(tolead) * v_forward) : 1;

	if (infront > 0.2)
	{
		if (dist > AFLOCK_TOO_FAR)
			self.boid_goalspeed = vlen(lead.velocity) * 1.5;
		else if (dist < AFLOCK_TOO_CLOSE)
			self.boid_goalspeed = vlen(lead.velocity) * 0.5;
	}
	else
		self.boid_goalspeed = vlen(lead.velocity) * 0.5;

	Boid_SpreadFlock2(self);

	self.boid_speed = vlen(self.velocity);
	self.velocity   = HL_Normalize(self.velocity);

	if (dist > AFLOCK_TOO_FAR)
		self.velocity = (self.velocity + HL_Normalize(tolead)) * 0.5;

	if (self.boid_goalspeed > AFLOCK_FLY_SPEED * 2)
		self.boid_goalspeed = AFLOCK_FLY_SPEED * 2;

	if (self.boid_speed < self.boid_goalspeed)
		self.boid_speed = self.boid_speed + AFLOCK_ACCELERATE;
	else if (self.boid_speed > self.boid_goalspeed)
		self.boid_speed = self.boid_speed - AFLOCK_ACCELERATE;

	self.velocity = self.velocity * self.boid_speed;
	Boid_AdvanceFrame(self);
};

// ---------------------------------------------------------------------------
// Start / IdleThink (:369-411)
// ---------------------------------------------------------------------------
void() Boid_Start =
{
	self.nextthink = time + 0.1;
	self.think     = Boid_IsLeader(self) ? Boid_LeaderThink : Boid_FollowerThink;

	// boid.mdl has ONE sequence, "idle" — checked against the rig, not assumed —
	// so HL's SetActivity(ACT_FLY) has nowhere to land and this is sequence 0
	// either way.  AI_ApplySequence rather than a bare .frame write so the frame
	// bookkeeping matches every other model-driven entity in the tree.
	AI_ApplySequence(self, 0, TRUE);

	Boid_AdvanceFrame(self);
	self.boid_speed = AFLOCK_FLY_SPEED;	// "no delay!" (:410)
};

// A flock does nothing until somebody can see it.  HL asks FIND_CLIENT_IN_PVS;
// checkclient() is the same question and the same cost — the engine round-robins
// one client per frame and caches the answer, which is why HL polls it at 5 Hz
// rather than every tick.
void() Boid_IdleThink =
{
	self.nextthink = time + 0.2;

	entity c = checkclient();
	if (c && c.classname == "player")
	{
		self.think     = Boid_Start;
		self.nextthink = time + 0.1;
	}
};

// ---------------------------------------------------------------------------
// death (:270-315)
// ---------------------------------------------------------------------------
// Reached only if something changes .takedamage: SpawnCommonCode sets DAMAGE_NO
// (:331) and nothing in the SDK clears it, so a boid is invulnerable in Half-Life
// too.  Transcribed anyway because it is nine lines and because the alert it
// raises — fifteen seconds of agitated calls across the whole flock — is the only
// thing that ever makes these birds sound different.
void() Boid_Killed =
{
	entity l = self.boid_leader;
	while (l)
	{
		l.boid_alert_until = time + 15;
		l = l.boid_next;
	}

	Boid_SquadRemove(self.boid_leader, self);

	self.solid     = SOLID_NOT;
	self.movetype  = MOVETYPE_TOSS;
	self.velocity  = '0 0 0';
	self.avelocity = '0 0 0';
	self.think     = SUB_Remove;
	self.nextthink = time + 10;
};

// ---------------------------------------------------------------------------
// SpawnCommonCode (:325-341)
// ---------------------------------------------------------------------------
void() Boid_Precache =
{
	precache_model("models/boid.mdl");
	AI_SndPrecache(SND_BOID_IDLE);
	AI_SndPrecache(SND_BOID_ALERT);
};

entity() Boid_Make =
{
	entity b = spawn();
	b.classname  = "monster_flyer";
	b.solid      = SOLID_SLIDEBOX;
	b.movetype   = MOVETYPE_FLY;
	b.takedamage = DAMAGE_NO;		// HL's value; see Boid_Killed
	b.health     = 1;
	b.max_health = 1;
	b.on_killed  = Boid_Killed;		// sv_customdefs.qc:315, W_ApplyDamage:2069

	setmodel(b, "models/boid.mdl");
	setsize(b, '-5 -5 0', '5 5 2');

	b.ai_seq   = -1;
	b.think    = Boid_IdleThink;
	b.nextthink = time + 0.2;

	boid_dbg_spawned = boid_dbg_spawned + 1;
	return b;
};

// ---------------------------------------------------------------------------
// monster_flyer — a loose boid that recruits its neighbours
// ---------------------------------------------------------------------------
// FormFlock (:415-446) runs once, from the first think: every monster_flyer
// within 1024 units that is not already in a squad joins this one.  Nothing in
// the corpus places these, but the class is real and a map that used it would
// otherwise get one spawn function's worth of nothing.
void() Boid_FormFlock =
{
	if (!self.boid_leader)
	{
		self.boid_leader = self;
		self.boid_next   = world;

		entity e = findradius(self.origin, AFLOCK_RECRUIT_RADIUS);
		while (e)
		{
			entity nxt = e.chain;
			if (e != self && e.classname == "monster_flyer" && e.health > 0
			    && !e.boid_leader)
				Boid_SquadAdd(self, e);
			e = nxt;
		}
	}

	self.think     = Boid_IdleThink;
	self.nextthink = time;
};

void() monster_flyer =
{
	Boid_Precache();

	entity b = Boid_Make();
	setorigin(b, self.origin);
	b.angles = self.angles;

	// The recruit pass has to wait for the rest of the entity lump to spawn, or
	// the first flyer in the file recruits nobody and every later one makes its
	// own one-bird flock.  0.2 s is HL's own delay before the first think.
	b.think     = Boid_FormFlock;
	b.nextthink = time + 0.2;

	remove(self);
};

// ---------------------------------------------------------------------------
// monster_flyer_flock — the spawner (:150-224)
// ---------------------------------------------------------------------------
void() monster_flyer_flock =
{
	Boid_Precache();

	float count = self.iFlockSize;
	if (count <= 0)
		count = 2;				// the FGD's default
	float R = self.flFlockRadius;

	entity leader = world;
	float  i      = 0;
	while (i < count)
	{
		entity b = Boid_Make();

		if (!leader)
		{
			leader = b;
			b.boid_leader = b;
			b.boid_next   = world;
		}

		// The scatter is a BOX, not a disc, and only 0..16 units tall — the flock
		// starts as a flat cluster and spreads itself out once it is flying.
		vector spot;
		spot_x = self.origin_x + (random() * 2 - 1) * R;
		spot_y = self.origin_y + (random() * 2 - 1) * R;
		spot_z = self.origin_z + random() * 16;
		setorigin(b, spot);

		b.flags    = b.flags - (b.flags & FL_ONGROUND);
		b.velocity = '0 0 0';
		b.angles   = self.angles;

		if (b != leader)
			Boid_SquadAdd(leader, b);

		i = i + 1;
	}

	if (cvar("sv_ai_debug"))
		dprint(sprintf("[flock] %g boid(s) at %v, radius %g\n",
		               count, self.origin, R));

	remove(self);					// dump the spawn ent (:156)
};

// ---------------------------------------------------------------------------
// boot self-test  (sv_flock_selftest)
// ---------------------------------------------------------------------------
// Two phases for the same reason the tentacle's has two: a flock is dormant until
// checkclient() finds somebody, so a headless server sees nine birds sitting
// perfectly still and cannot tell that from nine broken ones.  Phase 1 forces
// every boid past the PVS gate; phase 2 reports whether they actually moved and
// whether the squad links are intact.
float flock_selftest_phase;
float flock_selftest_at;
vector flock_selftest_seed;

void() Flock_SelfTest =
{
	if (!cvar("sv_flock_selftest") || flock_selftest_phase >= 2)
		return;
	if (flock_selftest_at <= 0)
		flock_selftest_at = 3;
	if (time < flock_selftest_at)
		return;

	entity b = find(world, classname, "monster_flyer");

	if (flock_selftest_phase == 1)
	{
		flock_selftest_phase = 2;

		float n = 0, flying = 0, linked = 0, leaders = 0;
		vector last = '0 0 0';
		while (b)
		{
			n = n + 1;
			if (vlen(b.velocity) > 1)	flying  = flying + 1;
			if (b.boid_leader)		linked  = linked + 1;
			if (Boid_IsLeader(b))		leaders = leaders + 1;
			last = b.origin;
			b = find(b, classname, "monster_flyer");
		}

		// Three flocks on hl_c18, so three leaders is right and one would mean the
		// recruit/link logic had merged them.  Movement is checked as "did the
		// cluster's last member end up somewhere else", which is cheap and cannot
		// be faked by a boid that is merely spinning on the spot.
		float bad = 0;
		if (n > 0 && flying < n)	bad = bad + 1;
		if (n > 0 && linked < n)	bad = bad + 1;
		if (n > 0 && vlen(last - flock_selftest_seed) < 8)	bad = bad + 1;

		string tail = sprintf("flying=%g linked=%g leaders=%g turns=%g",
		                      flying, linked, leaders, boid_dbg_turns);
		print(sprintf("[flocktest] %g boid(s) spawned=%g  %s  BAD=%g\n",
		              n, boid_dbg_spawned, tail, bad));
		return;
	}

	flock_selftest_phase = 1;
	flock_selftest_at    = time + 4;

	if (!b)
	{
		print("[flocktest] no monster_flyer on this map; gate only, BAD=0\n");
		flock_selftest_phase = 2;
		return;
	}

	// Force the PVS gate.  checkclient() cannot succeed on a server with no
	// clients, and waiting for one is not something a headless run can do — so
	// push every boid straight into Start, which is exactly what IdleThink would
	// have done.  Seed the movement check off the last one in the list.
	while (b)
	{
		flock_selftest_seed = b.origin;
		if (b.think == Boid_IdleThink)
		{
			b.think     = Boid_Start;
			b.nextthink = time + 0.1;
		}
		b = find(b, classname, "monster_flyer");
	}
};
