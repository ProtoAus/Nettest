// server/sv_ai_move.qc
// ----------------------------------------------------------------------------
// Locomotion: turning, stepping, and following a nav path.
//
// WHY walkmove AND NOT movetogoal, restated because it is easy to undo:
//
//   MOVETYPE_STEP gives gravity and nextthink-respecting thinks and NOTHING
//   else.  WPhys_Physics_Step (server/sv_phys.c:1516) applies gravity + FlyMove
//   only when the entity is NOT on the ground; once FL_ONGROUND is set it runs
//   the think and returns.  There is no friction and no velocity integration on
//   the ground at all, so setting .velocity on a grounded monster moves it
//   exactly nowhere.  Every step has to come from walkmove.
//
//   movetogoal is declared void() in QC, so its success/failure return is
//   invisible to us; it silently does nothing while airborne, and it carries a
//   hardcoded 25% random re-chase.  None of that is wanted here.
//
// THE GROUND FLAG is the subtle part.  walkmove refuses outright without
// FL_ONGROUND|FL_FLY|FL_SWIM (PF_walkmove, server/pr_cmds.c:4762), and
// World_movestep sets .groundentity on success but never sets FL_ONGROUND
// (server/sv_move.c:272).  So the flag has to arrive from somewhere else:
// droptofloor sets it at spawn (pr_bgcmd.c:6684) and the step physics re-sets it
// on landing.  A monster that never leaves the ground keeps it, because walkmove
// does not touch velocity and the physics only clears the flag when upward
// velocity reaches 1/32 (sv_phys.c:1530).  That same line is what makes a leap
// work: write velocity, and the engine takes the monster off the ground, arcs it
// and lands it with no further help.
//
// walkmove also refuses to walk off a ledge - World_movestep runs a real
// World_CheckBottom and rolls the origin back (sv_move.c:254-265).  Monsters
// therefore cannot walk themselves off a catwalk, which is why no separate
// ledge check appears below.
// ----------------------------------------------------------------------------

// Movement outcomes.  Deliberately distinct: "no route exists" and "a route
// exists but something is in the way" want completely different reactions, and
// collapsing them is how a monster ends up re-pathing every tick against a
// closed door.
const float AIMOVE_ARRIVED = 0;
const float AIMOVE_MOVING  = 1;
const float AIMOVE_BLOCKED = 2;
const float AIMOVE_NOPATH  = 3;
const float AIMOVE_WAITING = 4;		// request queued, no answer yet

const float AI_NODE_REACH   = 48;	// waypoint counts as reached inside this (2D)
const float AI_GOAL_REACH   = 40;	// final goal tolerance
// Vertical tolerances.  Horizontal-only reach tests are a trap that measurement
// caught: a headcrab standing directly under a player on a walkway reported
// "arrived" at a goal 60 units above its head, stopped, completed its chase
// schedule, re-selected, and did it again forever - 18 arrivals every 2 seconds
// and not one walkmove.  Reaching somewhere in plan view is not reaching it.
const float AI_REACH_STEP   = 18;	// sv_stepheight; what a monster can climb unaided
const float AI_NODE_REACH_Z = 72;	// waypoints: generous, nav links legitimately span stairs
const float AI_STUCK_TICKS  = 4;	// consecutive no-progress ticks before BLOCKED
// Consecutive ticks spent turning toward a heading without ever getting to step.
// 20 at 10 Hz is two seconds, which is comfortably longer than the slowest legal
// 180-degree turn in the game and short enough that a real oscillation is broken
// before a player notices it.
const float AI_TURN_TICKS   = 20;
const float AI_YAW_TOL      = 12;	// degrees; "facing" for task purposes

float ai_dbg_walkmoves;			// diagnostics: walkmove calls this second
// Total degrees of body yaw turned this report window, across every monster.
// The one number that proves the rate change landed: with the same monsters
// doing the same things it must roughly DOUBLE, and it is also how a future
// regression in the per-activity table would show up.
float ai_dbg_yawdeg;
float ai_dbg_walkfails;
float ai_dbg_sidesteps;
// Sidesteps that were immediately followed by a successful step back onto the
// original heading, i.e. corners actually rounded rather than walls scraped.
// If this stays near zero while sidesteps climbs, the fan is finding room but
// the monster is not getting anywhere with it.
float ai_dbg_cornercuts;
// Per-outcome counters for AI_MoveAlongPath.  "monsters select a chase schedule
// but never step" has several possible causes that look identical from outside
// the function - arriving instantly, turning forever, or having no waypoint -
// and separating them is the difference between diagnosing it and guessing.
float ai_dbg_mv_arrived, ai_dbg_mv_moving, ai_dbg_mv_blocked;
float ai_dbg_mv_nopath, ai_dbg_mv_turning, ai_dbg_mv_nowp;
// Turn oscillations broken by AI_TURN_TICKS.  Distinct from mv_blocked because
// the cause is different: blocked means geometry refused the step, spun means
// the monster never got as far as attempting one.
float ai_dbg_mv_spun;
float ai_dbg_mv_gripe;			// throttle for the per-outcome detail print
// Volume steps are counted separately from walkmoves on purpose: keeping them
// out of ai_dbg_walkmoves is what lets a regression run prove the ground path is
// untouched by comparing one number.
float ai_dbg_volmoves;

// ---------------------------------------------------------------------------
// turning
// ---------------------------------------------------------------------------
// Not the changeyaw builtin: that turns by self.yaw_speed PER CALL, which bakes
// in Quake's fixed 10 Hz monster think.  Scaling by real elapsed time instead
// means the turn rate stays correct if the decision tick is ever retuned, and
// keeps ai_yaw_speed readable as plain degrees per second.
float(float a) AI_AngleNorm =
{
	// -> (-180, 180], no loops, so a wild input cannot spin here.
	float d = a - floor(a / 360) * 360;
	if (d > 180)
		d = d - 360;
	return d;
};

void(entity m, vector targ) AI_YawToward =
{
	vector d = targ - m.origin;
	d_z = 0;
	if (d == '0 0 0')
		return;			// directly on top of us: keep the current facing
	m.ai_yaw_ideal = vectoyaw(d);
};

// TRUE once the monster is facing ai_yaw_ideal within AI_YAW_TOL.
float(entity m, float dt) AI_ChangeYaw =
{
	float diff = AI_AngleNorm(m.ai_yaw_ideal - m.angles_y);
	if (diff > -AI_YAW_TOL && diff < AI_YAW_TOL)
	{
		m.angles_y = m.ai_yaw_ideal;
		return TRUE;
	}

	float spd = m.ai_yaw_speed;
	if (spd <= 0)
		spd = 180;		// a sane default beats a monster that never turns

	// THE FACTOR OF TWO, and it is the whole "NPCs turn too slowly" report.
	//
	// Half-Life's CBaseMonster::ChangeYaw (monsters.cpp:2552) is
	//     speed = yawSpeed * delta * 2;
	// and this line was `spd * dt`.  Both run at the same 10 Hz think rate
	// (AI_TICK 0.1; HL's MonsterThink, monsters.cpp:521), so for identical
	// numbers every monster in this mod turned at exactly HALF the rate Valve
	// tuned its yaw_speed values against.  An hgrunt's 180-degree turn took
	// 1.20 s here against 0.50 s in Half-Life.
	//
	// HL's repeated calls within one think do NOT stack - m_flLastYawTime is
	// stamped inside the branch, so a second call the same frame gets delta 0 -
	// which is why the equivalent is one call per tick with the doubling, not
	// two calls without it.
	//
	// The clamp is HL's too (monsters.cpp:2550): after a server hitch, dt would
	// otherwise let a monster snap round instantly.
	float d = dt;
	if (d > 0.25)
		d = 0.25;
	float step = spd * d * 2;

	// One declaration: fteqcc scopes locals per FUNCTION, not per block.
	float t;
	if (diff > 0)
	{
		t = (step < diff) ? step : diff;
		m.angles_y = m.angles_y + t;
	}
	else
	{
		t = (step < (0 - diff)) ? step : (0 - diff);
		m.angles_y = m.angles_y - t;
	}
	ai_dbg_yawdeg = ai_dbg_yawdeg + t;

	m.angles_y = AI_AngleNorm(m.angles_y);
	return FALSE;
};

float(entity m) AI_FacingIdeal =
{
	float diff = AI_AngleNorm(m.ai_yaw_ideal - m.angles_y);
	if (diff < 0)
		diff = 0 - diff;
	return diff < AI_YAW_TOL;
};

// ---------------------------------------------------------------------------
// stepping
// ---------------------------------------------------------------------------
// One walkmove in the wanted direction; on refusal, a widening fan to either
// side, and then a corner-cut back onto the original heading.
//
// THE OLD VERSION WAS THE "THEY GET STUCK ON CORNERS" REPORT, in two ways.
//
// It tried yaw+40 then yaw-40, with no memory of which way it went last time.
// Forty degrees is not enough to clear an inside corner - the monster's own
// bounding box is still overlapping the wall it is trying to get round - so both
// alternatives usually failed and it simply stalled. And when one of them DID
// succeed, nothing recorded which, so the next tick was free to pick the other:
// step right, step left, step right, forever, with walkmove reporting success
// every single time. That is the shape a player reads as "stuck", and because
// every one of those ticks counted as progress, the stuck detector below never
// fired and it never asked for a new path either.
//
// Three changes, all of them things Half-Life already does:
//
//   1. THE FAN WIDENS. 45 degrees still makes forward progress; 90 is a pure
//      slide along the wall face, which is what actually clears an inside
//      corner; 135 is the last resort that backs out of a dead end. HL's
//      FTriangulate probes at a right angle for the same reason.
//   2. THE SIDE IS LATCHED. Once a direction works it is tried first next tick
//      and stays latched until the direct line is open again, which is what
//      turns a dither into a commitment to go round.
//   3. THE CORNER IS CUT. A sidestep that succeeds is immediately followed by a
//      retry of the ORIGINAL heading from the new position. That is what gets a
//      monster round a doorframe in one tick instead of scraping along the wall
//      for the length of the room, and it costs one extra walkmove only on the
//      ticks that were already blocked.
//
// Cost is unchanged in the common case: a monster with a clear line still does
// exactly one walkmove. The fan only runs on a tick that had already failed.
const float AI_AVOID_NARROW = 45;
const float AI_AVOID_WIDE   = 90;
const float AI_AVOID_BACK   = 135;
const float AI_AVOID_TRIES  = 6;

float(entity m, float yaw, float dist) AI_StepToward =
{
	if (dist <= 0)
		return TRUE;
	if (!(m.flags & FL_ONGROUND))
		return FALSE;		// airborne (mid-leap): walkmove would refuse anyway

	entity oldself = self;
	self = m;

	ai_dbg_walkmoves = ai_dbg_walkmoves + 1;
	if (walkmove(yaw, dist))
	{
		// The direct line is open, so any avoidance we were committed to is over.
		m.ai_avoidside = 0;
		self = oldself;
		return TRUE;
	}

	ai_dbg_walkfails = ai_dbg_walkfails + 1;

	float side = m.ai_avoidside;
	if (!side)
		side = (random() < 0.5) ? 1 : -1;

	float i;
	for (i = 0; i < AI_AVOID_TRIES; i = i + 1)
	{
		// Preferred side first at each width, then the other: 45, -45, 90, -90,
		// 135, -135 (signs relative to whichever side is currently latched).
		float s   = (i & 1) ? (0 - side) : side;
		float ang = AI_AVOID_BACK;
		if (i < 2)
			ang = AI_AVOID_NARROW;
		else if (i < 4)
			ang = AI_AVOID_WIDE;

		ai_dbg_sidesteps = ai_dbg_sidesteps + 1;
		if (!walkmove(yaw + s * ang, dist))
			continue;

		m.ai_avoidside = s;

		// Cut the corner: from the new spot, is the original heading open now?
		if (walkmove(yaw, dist))
			ai_dbg_cornercuts = ai_dbg_cornercuts + 1;

		self = oldself;
		return TRUE;
	}

	self = oldself;
	return FALSE;
};

// ---------------------------------------------------------------------------
// water
// ---------------------------------------------------------------------------
// Our own probe rather than .waterlevel — see the AIMODE_* note in sv_ai_defs.qc
// for why that field cannot be trusted on a MOVETYPE_STEP monster.  This is the
// pattern the physics props already use (sv_physprop.qc:828), and func_water
// deliberately keeps a negative .skin so pointcontents reports its interior
// (sv_water.qc:92).
//
// Lava is excluded: nothing in the corpus lives in it, and a swimmer that treats
// it as home would happily park in a lava pit taking damage forever.
float(vector p) AI_InWater =
{
	float c = pointcontents(p);
	return (c == CONTENT_WATER || c == CONTENT_SLIME);
};

// ---------------------------------------------------------------------------
// stepping, volume modes
// ---------------------------------------------------------------------------
// The FLY/SWIM counterpart of AI_StepToward: a direct tracebox and setorigin.
//
// walkmove cannot do this job at all.  It builds its move as
// cos(yaw)*dist*axis[0] + sin(yaw)*dist*axis[1] (pr_cmds.c:4768) — there is no
// vertical term and no way to supply one, so anything driven by it can never
// change altitude.  World_movestep's FL_SWIM|FL_FLY branch is worse than useless
// here: its second attempt is gated on ent->v->enemy (sv_move.c:207), a field
// this AI deliberately never populates, so for us it degenerates to a single
// tracebox with neither step-up nor CheckBottom — strictly less than doing the
// tracebox directly.
//
// NOTE: calls makevectors on the deflection attempts, so v_forward/v_right/v_up
// are clobbered.  Nothing on the movement path reads them across this call.
float(entity m, vector dir, float dist) AI_StepVolume =
{
	if (dist <= 0)
		return TRUE;
	if (dir == '0 0 0')
		return FALSE;

	vector fwd = normalize(dir);
	float  i;

	ai_dbg_volmoves = ai_dbg_volmoves + 1;

	// Straight at it, then two shallow deflections — the same three-attempt shape
	// as the ground path and for the same reason: each retry is a full tracebox,
	// and a wider fan costs more than it recovers.
	for (i = 0; i < 3; i = i + 1)
	{
		vector d = fwd;

		if (i > 0)
		{
			// Deflect in the horizontal plane only, preserving the climb rate.  A
			// blocked flyer that veers vertically grinds along the ceiling; veering
			// sideways is what gets it around a pillar.
			vector flat = fwd;
			flat_z = 0;
			float flen = vlen(flat);
			if (flen < 0.001)
				break;			// straight up or down: no horizontal to deflect

			makevectors('0 1 0' * (vectoyaw(flat) + ((i == 1) ? 40 : -40)));
			d   = v_forward * flen;
			d_z = fwd_z;			// v_forward is unit and level, so d stays unit
		}

		vector dst = m.origin + d * dist;

		// A swimmer must not leave its element.  With no gravity acting on it, a
		// leech that breaches the surface has nothing to bring it back down.
		if (m.ai_movemode == AIMODE_SWIM && !AI_InWater(dst))
		{
			dst_z = m.origin_z;		// try the same move flat instead
			if (!AI_InWater(dst))
				continue;
		}

		tracebox(m.origin, m.mins, m.maxs, dst, MOVE_NORMAL, m);
		if (trace_startsolid || trace_allsolid)
			return FALSE;			// already wedged; deflecting cannot help

		if (trace_fraction >= 1)
		{
			setorigin(m, dst);
			return TRUE;
		}
		if (trace_fraction > 0.05)
		{
			// A partial move still counts.  Whether a run of these is actually
			// getting anywhere is what the progress check in AI_MoveAlongPath is
			// for; deciding it here would duplicate that logic and disagree with it.
			setorigin(m, trace_endpos);
			return TRUE;
		}

		if (i == 0)
		{
			ai_dbg_walkfails = ai_dbg_walkfails + 1;
			ai_dbg_sidesteps = ai_dbg_sidesteps + 1;
		}
	}

	return FALSE;
};

void(entity m) AI_StopMoving =
{
	m.ai_moveact = ACT_RESET;
	m.velocity_x = 0;
	m.velocity_y = 0;
	// velocity_z is deliberately untouched: zeroing it mid-fall would freeze a
	// monster in the air, and the step physics owns the vertical axis anyway.
};

// ---------------------------------------------------------------------------
// path acquisition
// ---------------------------------------------------------------------------
// Requests go through the nav queue, never straight into a search - the whole
// point of B1's budget is that fifty monsters converging on one player cost two
// searches a frame between them rather than fifty.
//
// ai_nextpath is a per-monster floor on top of that.  The global budget stops
// the server from doing too much work per frame; this stops one monster from
// monopolising the queue by re-requesting the instant its last answer failed.
const float AI_REPATH_OK   = 1.0;	// after a successful path
const float AI_REPATH_FAIL = 2.0;	// after a failure - unreachable goals stay unreachable

float(entity m, vector goal) AI_PathRequest =
{
	if (time < m.ai_nextpath)
		return FALSE;

	m.ai_goalpos = goal;

	if (!Nav_RequestPath(m, goal, 0))
	{
		// Queue full or nav not ready.  Back off like a failure: retrying next
		// tick would just refill the queue with the same request.
		m.ai_nextpath = time + AI_REPATH_FAIL;
		return FALSE;
	}

	m.ai_nextpath = time + AI_REPATH_OK;
	return TRUE;
};

void(entity m) AI_PathClear =
{
	Nav_PathSlot_Release(m);
	m.ai_path_len = 0;
	m.ai_path_cur = 0;
};

// A route that ended in BLOCKED is a route through geometry this monster cannot
// actually traverse, so keeping it is worse than having none: the schedule fails,
// re-selects, finds AI_HasPath still true, and walks the monster straight back
// into the same wall.  Throw it away.
//
// The repath throttle is pulled forward rather than cleared.  AI_REPATH_OK exists
// to stop one monster monopolising the nav queue, and that is still worth having
// when fifty of them are converging on the same player - but a full second of
// standing still after hitting a corner is exactly the pause a player reads as
// "it gave up", so a blocked monster gets to ask again much sooner.
//
// (Note for anyone reading the old plan note here: the `avoid` argument to
// Nav_RequestPath is a LINK-FLAG MASK - which link types the search refuses to
// traverse, sv_nav.qc:1523 - not a position to route around.  Feeding it the
// blocking point would have done nothing.)
const float AI_REPATH_BLOCKED = 0.25;

void(entity m) AI_PathBlocked =
{
	AI_PathClear(m);
	m.ai_avoidside = 0;		// fresh route, fresh choice of side
	if (m.ai_nextpath > time + AI_REPATH_BLOCKED)
		m.ai_nextpath = time + AI_REPATH_BLOCKED;
};

// Has the queued request been answered?  Nav_PathSlot_Store writes ai_path_len
// and stamps ai_path_serial with the build serial, and Nav_PathSlot_Node returns
// -1 for anything stale, so this is just "is there a live first waypoint".
float(entity m) AI_HasPath =
{
	if (m.ai_path_len <= 0)
		return FALSE;
	return Nav_PathSlot_Node(m, m.ai_path_cur) >= 0;
};

// ---------------------------------------------------------------------------
// reach tests
// ---------------------------------------------------------------------------
// Split by mode because altitude means two different things.  A ground monster
// does not control its own height, so a goal it could step up onto counts as
// reached; a flyer owns all three axes and has to actually get there.
float(entity m, vector goal) AI_ReachedGoal =
{
	vector d = goal - m.origin;

	if (m.ai_movemode != AIMODE_GROUND)
		return vlen(d) <= AI_GOAL_REACH;

	// Vertically, "arrived" means the goal is somewhere this monster could
	// actually touch from where it stands: no higher than its own head plus a
	// step, and no lower than a step below its feet.  Anything outside that is
	// still to be travelled to, however close it looks from above.
	float dz = d_z;
	d_z = 0;
	if (vlen(d) > AI_GOAL_REACH)		return FALSE;
	if (dz > m.maxs_z + AI_REACH_STEP)	return FALSE;
	if (dz < m.mins_z - AI_REACH_STEP)	return FALSE;
	return TRUE;
};

float(entity m, vector wp) AI_ReachedNode =
{
	vector d = wp - m.origin;

	if (m.ai_movemode != AIMODE_GROUND)
		return vlen(d) <= AI_NODE_REACH;

	float dz = d_z;
	if (dz < 0) dz = 0 - dz;
	d_z = 0;
	// Same reasoning as the goal test with a looser window: nav links legitimately
	// span stairs and ramps, so a waypoint one storey up must not be retired as
	// reached while the monster is still standing below it.
	return (vlen(d) <= AI_NODE_REACH && dz <= AI_NODE_REACH_Z);
};

// ---------------------------------------------------------------------------
// path following
// ---------------------------------------------------------------------------
// Returns one of the AIMOVE_* codes.  `dist` is how far to travel this tick.
float(entity m, float dist) AI_MoveAlongPath =
{
	// A bolted-down monster has no locomotion at all.  ARRIVED rather than NOPATH
	// on purpose: NOPATH sets COND_NO_PATH and fails the task, which would bounce
	// a turret through its fail schedule every single tick.  AI_SelectSchedule
	// keeps a static monster out of the chase schedule in the first place; this is
	// the backstop for a class schedule that reaches here anyway.
	if (m.ai_movemode == AIMODE_STATIC)
	{
		AI_StopMoving(m);
		ai_dbg_mv_arrived = ai_dbg_mv_arrived + 1;
		return AIMOVE_ARRIVED;
	}

	vector here = m.origin;
	vector gd   = m.ai_goalpos - here;

	// How far the goal is for the "close enough to walk straight at" test below.
	// Flat on the ground, where the monster does not control its altitude and a
	// goal one storey up is still a horizontal problem; the true 3D distance for
	// a flyer, which does control it.
	float goaldist;
	if (m.ai_movemode == AIMODE_GROUND)
	{
		vector flat = gd;
		flat_z   = 0;
		goaldist = vlen(flat);
	}
	else
		goaldist = vlen(gd);

	// Arrived at the final goal?  Checked before the waypoint logic so a goal
	// that sits between two nodes still terminates.
	if (AI_ReachedGoal(m, m.ai_goalpos))
	{
		AI_StopMoving(m);
		ai_dbg_mv_arrived = ai_dbg_mv_arrived + 1;
		if (ai_cached_debug && time >= ai_dbg_mv_gripe)
		{
			ai_dbg_mv_gripe = time + 1;
			dprint(sprintf("[ai]   arrived: org=%v goal=%v dist=%g pathlen=%g cur=%g\n",
			               m.origin, m.ai_goalpos, goaldist, m.ai_path_len, m.ai_path_cur));
		}
		return AIMOVE_ARRIVED;
	}

	// Seeded with the goal so it is defined on every path through the waypoint
	// scan below, including the ones that break out before assigning it.
	vector want = m.ai_goalpos;
	float have_wp = FALSE;

	if (AI_HasPath(m))
	{
		// Retire every waypoint already inside reach, not just one per tick: at
		// a run speed of 200 qu/s a 10 Hz tick covers 20 units, but nav nodes on
		// open floor can sit closer together than that, and consuming one per
		// tick would make the monster crawl through dense stretches.
		float guard = 0;
		while (guard < NAV_PSLOT_LEN)
		{
			guard = guard + 1;

			float nd = Nav_PathSlot_Node(m, m.ai_path_cur);
			if (nd < 0)
				break;			// ran off the end of the path
			if (nd >= NAV_NODE_MAX)
				break;			// corrupt index; fall through to direct movement

			want = nav_pos[nd];
			// Nav nodes sit on the floor.  A flyer that follows them literally
			// descends to ankle height and cruises there, so lift the waypoint -
			// before the reach test, or it would be retired at the wrong altitude.
			// The GOAL is deliberately left alone: that is usually an enemy, and a
			// flyer should come to where the enemy actually is.
			if (m.ai_movemode == AIMODE_FLY && m.ai_flyheight > 0)
				want_z = want_z + m.ai_flyheight;

			if (!AI_ReachedNode(m, want))
			{
				have_wp = TRUE;
				break;
			}
			m.ai_path_cur = m.ai_path_cur + 1;
		}
	}

	if (!have_wp)
	{
		// No usable waypoint left.  If the goal is close, walk straight at it -
		// the last nav node is rarely the goal itself.  If it is far, the path
		// is spent and the caller has to ask for a new one.
		if (goaldist > NAV_LINK_DIST)
		{
			ai_dbg_mv_nopath = ai_dbg_mv_nopath + 1;
			return AIMOVE_NOPATH;
		}
		ai_dbg_mv_nowp = ai_dbg_mv_nowp + 1;
		want = m.ai_goalpos;
	}

	AI_YawToward(m, want);

	// HALF-LIFE TURNS AND WALKS AT THE SAME TIME, and this gate not doing so is
	// most of the reported "NPCs turn really slowly".
	//
	// CBaseMonster::Move (monsters.cpp:1847-1848) calls MakeIdealYaw + ChangeYaw
	// and then UNCONDITIONALLY calls MoveExecute (:1958) - which is
	// UTIL_MoveToOrigin toward the waypoint, independent of pev->angles.y.  An HL
	// monster walks the arc while it rotates.  This gate froze ours completely
	// until the heading error dropped under 60 degrees, so an hgrunt asked to
	// turn 180 stood perfectly still for (180-60)/300 = 0.4 s and then set off.
	// Doubling the turn rate alone would have halved that dead time; removing it
	// is what actually makes them look alive.
	//
	// The threshold moves 60 -> 120, i.e. it now only refuses when the goal is
	// genuinely BEHIND the monster, where stepping would carry it further away.
	// That case still deserves a pivot in place.
	const float AI_TURN_REFUSE = 120;
	float yaw = m.ai_yaw_ideal;
	float diff = AI_AngleNorm(yaw - m.angles_y);
	if (diff < 0)
		diff = 0 - diff;
	if (diff > AI_TURN_REFUSE)
	{
		ai_dbg_mv_turning = ai_dbg_mv_turning + 1;

		// ...but a turn that never completes has to end somewhere.  This branch
		// used to return MOVING without touching any counter, so a monster whose
		// wanted heading kept flipping more than 60 degrees - which is exactly
		// what happens when a waypoint sits behind a corner it cannot round -
		// span on the spot indefinitely and never counted as blocked, so it never
		// asked for a new path.
		//
		// The allowance is generous because turning legitimately takes ticks: the
		// slowest turn in the game is the gargantua's 60 (120 deg/s after the
		// doubling), so a full 180 costs 1.5 s and this only fires on a genuine
		// oscillation.
		//
		// THE TURN ANIMATION BELONGS HERE and nowhere else.  ACT_TURN_LEFT and
		// ACT_TURN_RIGHT have been declared since the AI landed and were reachable
		// by nothing, so every monster in the game pivoted with its feet planted
		// in an idle pose.  This branch is now the only place a monster turns
		// WITHOUT travelling, which is exactly what those cycles animate; the
		// activity fallback (sv_ai_anim.qc:95-96) already sends rigs that lack
		// them back to ACT_IDLE, so this is safe on every model.
		//
		// It also feeds the per-activity yaw table: HL's grunt turns at 180 for
		// these two against 150 for everything else, so asking for the activity
		// is what buys the faster pivot.
		AI_SetActivity(m, (AI_AngleNorm(yaw - m.angles_y) > 0)
		                  ? ACT_TURN_LEFT : ACT_TURN_RIGHT);

		m.ai_turnticks = m.ai_turnticks + 1;
		if (m.ai_turnticks >= AI_TURN_TICKS)
		{
			m.ai_turnticks = 0;
			m.ai_stuck     = 0;
			m.ai_lastorg   = m.origin;
			ai_dbg_mv_spun = ai_dbg_mv_spun + 1;
			return AIMOVE_BLOCKED;
		}
		return AIMOVE_MOVING;		// still swinging round; the yaw tick does the work
	}
	m.ai_turnticks = 0;

	float ok;
	if (m.ai_movemode == AIMODE_GROUND)
		ok = AI_StepToward(m, yaw, dist);
	else
		ok = AI_StepVolume(m, want - m.origin, dist);

	if (!ok)
	{
		m.ai_stuck = m.ai_stuck + 1;
		// ai_lastorg has to be re-seated here as well as on the success path.
		// It was not, and that quietly disarmed the progress check below: after
		// several refused ticks the stored origin was stale by however far the
		// monster had travelled BEFORE it got wedged, so the first step that did
		// succeed compared against a point metres away, looked like enormous
		// progress, and reset the counter to zero.  A monster scraping along a
		// wall therefore never accumulated four bad ticks in a row and never
		// reached BLOCKED, which is the only thing that asks for a new path.
		m.ai_lastorg = m.origin;
		if (m.ai_stuck >= AI_STUCK_TICKS)
		{
			m.ai_stuck = 0;
			ai_dbg_mv_blocked = ai_dbg_mv_blocked + 1;
			return AIMOVE_BLOCKED;
		}
		return AIMOVE_MOVING;
	}

	// Progress check.  walkmove can report success while barely moving - it
	// succeeds on any non-zero displacement, including a 1-unit slide along a
	// wall - so success alone is not evidence of progress.  Without this a
	// monster wedged in a doorway reports MOVING forever and never re-paths.
	if (vlen(m.origin - m.ai_lastorg) < dist * 0.25)
		m.ai_stuck = m.ai_stuck + 1;
	else
		m.ai_stuck = 0;
	m.ai_lastorg = m.origin;

	if (m.ai_stuck >= AI_STUCK_TICKS)
	{
		m.ai_stuck = 0;
		ai_dbg_mv_blocked = ai_dbg_mv_blocked + 1;
		return AIMOVE_BLOCKED;
	}

	ai_dbg_mv_moving = ai_dbg_mv_moving + 1;
	return AIMOVE_MOVING;
};

// ---------------------------------------------------------------------------
// spawn-time placement
// ---------------------------------------------------------------------------
// Two jobs, both required before the monster can move at all: put it on the
// floor, and get FL_ONGROUND set so walkmove will talk to us.
//
// Returns FALSE when the mapper placed the monster somewhere it cannot stand -
// in solid, or more than pr_droptofloorunits (256) above any floor.  The caller
// keeps such a monster as an inert body rather than deleting it: its targetname
// may be load-bearing for a trigger chain, exactly as for the AI-less classes.
float(entity m) AI_PlaceOnFloor =
{
	entity oldself = self;
	self = m;
	float ok = droptofloor();
	self = oldself;

	if (ok)
	{
		// droptofloor already set FL_ONGROUND and .groundentity (pr_bgcmd.c:6684),
		// but say so explicitly: everything downstream depends on this flag and
		// a reader should not have to know that builtin's side effects.
		m.flags = m.flags | FL_ONGROUND;
	}

	m.ai_lastorg = m.origin;
	m.ai_stuck   = 0;
	return ok;
};

// The FLY / SWIM / STATIC counterpart of AI_PlaceOnFloor.
//
// Deliberately does NOT droptofloor.  The floor is not where these monsters live
// — a ceiling-mounted barnacle dropped to the ground is the exact bug this exists
// to prevent — and FL_ONGROUND, the only thing droptofloor is wanted for on the
// ground path, is meaningless to a monster gravity never touches.
//
// Same contract as AI_PlaceOnFloor: FALSE means the mapper put the monster
// somewhere it cannot exist, and the caller keeps it as an inert body rather than
// removing it, because its targetname may still anchor a trigger chain.
float(entity m) AI_PlaceInVolume =
{
	setorigin(m, m.origin);		// link it before tracing against the world

	tracebox(m.origin, m.mins, m.maxs, m.origin, MOVE_NORMAL, m);
	if (trace_startsolid || trace_allsolid)
		return FALSE;

	// Settle to the class's cruising height if it asked for one.  Mappers place
	// flyers at editor eye level far more often than at the altitude the class
	// actually wants to hold.
	if (m.ai_movemode == AIMODE_FLY && m.ai_flyheight > 0)
	{
		traceline(m.origin, m.origin - '0 0 4096', MOVE_NORMAL, m);
		if (trace_fraction < 1)
		{
			// ai_flyheight is clearance UNDER THE HULL, not origin height, so a
			// class can be written without knowing its own mins_z.
			vector dst = m.origin;
			dst_z = trace_endpos_z + m.ai_flyheight - m.mins_z;

			tracebox(m.origin, m.mins, m.maxs, dst, MOVE_NORMAL, m);
			if (!trace_startsolid && !trace_allsolid)
				setorigin(m, trace_endpos);
		}
	}

	// Not a placement failure: HL leaves a beached swimmer where the mapper put
	// it, and so do we.  But it will never move again — AI_StepVolume refuses
	// every step that would keep it out of the water — so say so once.
	if (m.ai_movemode == AIMODE_SWIM && ai_cached_debug && !AI_InWater(m.origin))
		dprint(sprintf("[ai] %s at %v is a swimmer placed out of water\n",
		               m.classname, m.origin));

	m.ai_lastorg = m.origin;
	m.ai_stuck   = 0;
	return TRUE;
};
