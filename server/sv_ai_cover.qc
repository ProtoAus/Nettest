// server/sv_ai_cover.qc
// ----------------------------------------------------------------------------
// Take cover.  Ported from:
//   CBaseMonster::FindLateralCover   dlls/monsters.cpp:3146-3196
//   CBaseMonster::FindCover          dlls/monsters.cpp:2235-2330
//   CSquadMonster::FValidateCover    dlls/squadmonster.cpp:546-561
//   TASK_FIND_COVER_FROM_ENEMY       dlls/schedule.cpp:739-770
//   slTakeCoverFromEnemy             dlls/defaultai.cpp:953-980
//
// This is the other half of item H, and it is the half a player actually sees.
// Until now the entire vocabulary of a monster under fire was: chase, face,
// shoot, lob.  Every one of those moves TOWARD you or stands still.  There was
// no way for a monster to decide that where it is standing is a bad place to be,
// which is why sustained fire has always produced the same picture - a queue of
// monsters walking into it.
//
// THE SEARCH IS TWO SEARCHES, in HL's order, and they are different in kind:
//
//   LATERAL is a sidestep.  Five 48-unit steps left and right in the monster's
//   own frame, testing whether that spot breaks the enemy's line of sight.  It
//   is a LOCAL move: no pathfinder, no nav graph, just a hull sweep, exactly as
//   HL's CheckLocalMove is local.  This is the one that reads as "ducking behind
//   the crate you were already standing next to".
//
//   NODE is a relocation.  The nav graph already has the candidate positions, so
//   cover is "a node that blocks the enemy's view of me" rather than any new
//   spatial structure - which is what the plan called for and is the whole
//   reason this could follow squads rather than needing a month of its own.
//
// Compiled after sv_navnodes.qc (it reads nav_pos/nav_air/the grid directly),
// after sv_ai_squad.qc (cover validation is squad spacing), and before
// sv_ai_core.qc, which owns the task that calls it.
// ----------------------------------------------------------------------------

vector(entity m) AI_EyePos;		// sv_ai_core.qc; QC forward-declares functions

// ---------------------------------------------------------------------------
// tuning
// ---------------------------------------------------------------------------
const float COVER_LATERAL_CHECKS = 5;	// HL COVER_CHECKS  (monsters.cpp:3143)
const float COVER_LATERAL_DELTA  = 48;	// HL COVER_DELTA   (monsters.cpp:3144)
const float COVER_RADIUS         = 784;	// HL's FindCover default flMaxDist
// A node at zero distance is not cover, it is where the monster already stands,
// and accepting it would make "reached cover" a counter that increments without
// anything moving.  Half-Life passes flMinDist 0 and gets away with it because
// MoveToLocation fails on a zero-length route; this pathfinder answers such a
// request with a one-node path that retires immediately, so the floor is set
// here instead.  One lateral step plus the goal tolerance.
const float COVER_MIN_MOVE       = 96;
const float COVER_SQUAD_SPACING  = 128;	// squadmonster.cpp:554
// Bounds on one search.  HL scans every node in the graph and amortises the cost
// with a rotating global cursor (m_iLastCoverSearch); the grid makes the gather
// cheap enough to do properly, but the LOS traces are still traces, so they are
// capped and the cap is COUNTED - a search that quietly stopped looking and a
// map with no cover in it must not produce the same log line.
const float COVER_CAND_MAX       = 24;	// candidate nodes held per search
const float COVER_TRACE_MAX      = 12;	// LOS traces spent per search
const float COVER_ROUTE_MAX      = 4;	// A* reachability checks spent per search

// ---------------------------------------------------------------------------
// counters
// ---------------------------------------------------------------------------
// Cover has the same problem item G had: it fails silently and successfully.
// A monster that searches, finds nothing and stands there looks exactly like a
// monster that never searched, and both look like a monster with no cover code
// at all.  Every outcome of a search gets its own counter for that reason.
float ai_dbg_cover_sched;	// cover schedules selected
float ai_dbg_cover_asked;	// ...times a class trigger asked for one
float ai_dbg_cover_floor;	// ...refused: still inside the search retry floor
float ai_dbg_cover_nodmg;	// ...refused: the damage condition had already gone
float ai_dbg_cover_tries;	// searches run
float ai_dbg_cover_lateral;	// ...solved by a sidestep
float ai_dbg_cover_node;	// ...solved by a nav node
float ai_dbg_cover_none;	// ...that found nowhere at all
float ai_dbg_cover_refused;	// a spot was found and the path request was refused
float ai_dbg_cover_arrived;	// cover moves that reached the spot
float ai_dbg_cover_spacing;	// spots rejected: a squadmate was already there
float ai_dbg_cover_capped;	// searches that spent their budget and gave up
float ai_dbg_cover_noroute;	// hidden nodes rejected: no route from where we stand
float ai_dbg_cover_cower;	// SCHED_COWER selections
float ai_dbg_cover_facing;	// COND_ENEMY_FACING_ME raises

// The answer.  A single global rather than a by-reference argument because QC has
// neither; the finders are called from exactly one place and never nest.
vector cover_spot;

// ---------------------------------------------------------------------------
// the three tests a candidate has to pass
// ---------------------------------------------------------------------------
// 1. Does it actually hide the monster?
//
// Traced eye-to-eye, not origin-to-origin.  A GoldSrc monster's origin is at its
// FEET, so an origin-to-origin trace is a trace between two points in the floor
// and reports "hidden" behind every doorstep in the map.  AI_EyePos is the same
// rule AI_CanSee uses, which is what makes this test agree with the one that
// decides whether the monster can be seen at all.
float(entity m, vector spot, vector threateye) Cover_Hides =
{
	vector eye = spot;
	eye_z = eye_z + m.maxs_z * 0.8;
	traceline(threateye, eye, MOVE_NOMONSTERS, m);
	return (trace_fraction < 1);
};

// 2. Can the monster get there in a straight line?
//
// HL's CheckLocalMove, with the monster's OWN hull rather than a fixed one - a
// gargantua is four times the width of a headcrab and a spot a headcrab fits in
// is not cover for a gargantua, it is a wall.
//
// The floor test is the half HL gets from its movement code and this does not:
// a lateral sweep that is clear all the way can still end over a ledge, and a
// monster that "takes cover" by walking off a catwalk is worse than one that
// stands still.  Skipped for flyers and swimmers, which have no floor to want.
float(entity m, vector dest) Cover_CanReach =
{
	tracebox(m.origin, m.mins, m.maxs, dest, MOVE_NOMONSTERS, m);
	if (trace_fraction < 1)
		return FALSE;

	if (m.ai_movemode != AIMODE_GROUND)
		return TRUE;

	traceline(dest, dest - '0 0 64', MOVE_NOMONSTERS, m);
	if (trace_fraction >= 1)		return FALSE;	// nothing under it
	if (trace_plane_normal_z < 0.7)	return FALSE;	// too steep to stand on
	return TRUE;
};

// 3. Is somebody already there?
//
// squadmonster.cpp:546-561, and it is the reason a squad breaking for cover
// scatters instead of piling into one corner.  Measured flat (Length2D in HL) so
// that a spot directly above or below a squadmate on a stairwell still counts as
// taken - which is the useful reading, because the objection is "we would be
// standing on each other", not "we would be the same distance apart".
float(entity m, vector spot) Cover_Validate =
{
	if (!Squad_In(m))
		return TRUE;

	entity e = Squad_Leader(m);
	float guard = 0;
	while (e && guard < 32)
	{
		guard = guard + 1;
		if (e != m)
		{
			vector d = spot - e.origin;
			d_z = 0;
			if (vlen(d) <= COVER_SQUAD_SPACING)
			{
				ai_dbg_cover_spacing = ai_dbg_cover_spacing + 1;
				return FALSE;
			}
		}
		e = e.ai_squad_next;
	}
	return TRUE;
};

// ---------------------------------------------------------------------------
// lateral cover  —  monsters.cpp:3146-3196
// ---------------------------------------------------------------------------
// Steps out along the monster's own right vector, alternating sides, nearest
// step first.  HL tests left-then-right at each distance and so does this: the
// alternation is what stops every monster in a squad drifting the same way.
//
// The step is HL's 48 with a floor at the monster's own width.  A gargantua is
// 64 units across, so 48 puts the first candidate INSIDE the monster it is
// testing for; the sweep would start solid and the answer would be meaningless.
float(entity m, vector threat, vector threateye) Cover_Lateral =
{
	makevectors([0, m.angles_y, 0]);
	vector step = v_right;
	step_z = 0;
	if (step == '0 0 0')
		return FALSE;
	step = normalize(step);

	float delta = COVER_LATERAL_DELTA;
	float width = m.maxs_x - m.mins_x;
	if (delta < width)
		delta = width;

	float i;
	for (i = 1; i <= COVER_LATERAL_CHECKS; i = i + 1)
	{
		vector off = step * (delta * i);

		vector l = m.origin - off;
		if (Cover_Hides(m, l, threateye))
			if (Cover_Validate(m, l))
				if (Cover_CanReach(m, l))
				{
					cover_spot = l;
					return TRUE;
				}

		vector r = m.origin + off;
		if (Cover_Hides(m, r, threateye))
			if (Cover_Validate(m, r))
				if (Cover_CanReach(m, r))
				{
					cover_spot = r;
					return TRUE;
				}
	}
	return FALSE;
};

// ---------------------------------------------------------------------------
// node cover  —  monsters.cpp:2235-2330
// ---------------------------------------------------------------------------
// Candidate shortlist, nearest first.  Same insertion shape as Nav_NearInsert,
// kept separate because a cover search must not disturb the nearest-node
// shortlist a path request in the same frame is using.
float cover_cand[COVER_CAND_MAX];
float cover_candd[COVER_CAND_MAX];
float cover_candn;

void(float idx, float d) Cover_CandInsert =
{
	if (cover_candn >= COVER_CAND_MAX)
		if (d >= cover_candd[COVER_CAND_MAX - 1])
			return;

	float pos = cover_candn;
	if (pos >= COVER_CAND_MAX)
		pos = COVER_CAND_MAX - 1;
	while (pos > 0)
	{
		if (cover_candd[pos - 1] <= d)
			break;
		cover_cand[pos]  = cover_cand[pos - 1];
		cover_candd[pos] = cover_candd[pos - 1];
		pos = pos - 1;
	}
	cover_cand[pos]  = idx;
	cover_candd[pos] = d;
	if (cover_candn < COVER_CAND_MAX)
		cover_candn = cover_candn + 1;
};

// Gather every non-air node in the distance band into the shortlist.  Grid-first,
// because HL's "scan all m_cNodes and rotate the start cursor" is a full sweep of
// the graph per search and this graph is bigger than Valve's.
void(entity m, float mindist, float maxdist) Cover_Gather =
{
	cover_candn = 0;
	if (nav_count <= 0)
		return;

	vector org = m.origin;

	if (!nav_grid_ready)
	{
		float i;
		for (i = 0; i < nav_count; i = i + 1)
		{
			if (nav_air[i]) continue;
			float d = vlen(nav_pos[i] - org);
			if (d < mindist || d >= maxdist) continue;
			Cover_CandInsert(i, d);
		}
		return;
	}

	float qx = Nav_GridClamp(floor((org_x - nav_grid_org_x) / nav_grid_cell));
	float qy = Nav_GridClamp(floor((org_y - nav_grid_org_y) / nav_grid_cell));
	float r  = ceil(maxdist / nav_grid_cell) + 1;

	float gx, gy;
	for (gy = qy - r; gy <= qy + r; gy = gy + 1)
	{
		if (gy < 0) continue;
		if (gy > NAV_GRID_DIM - 1) continue;
		for (gx = qx - r; gx <= qx + r; gx = gx + 1)
		{
			if (gx < 0) continue;
			if (gx > NAV_GRID_DIM - 1) continue;
			float c = gy * NAV_GRID_DIM + gx;
			float s = nav_grid_start[c], e = nav_grid_start[c + 1];
			float k;
			for (k = s; k < e; k = k + 1)
			{
				float n = nav_grid_item[k];
				if (n < 0) continue;
				if (n >= nav_count) continue;
				if (nav_air[n]) continue;
				float d = vlen(nav_pos[n] - org);
				if (d < mindist || d >= maxdist) continue;
				Cover_CandInsert(n, d);
			}
		}
	}
};

// Nearest valid node that hides the monster.
//
// TWO DIVERGENCES FROM HL, both deliberate:
//
//   HL takes the FIRST node its rotating scan accepts; this takes the NEAREST.
//   A monster that sprints past three usable corners to reach a fourth reads as
//   a monster that has decided to leave, and the spacing test is what stops a
//   whole squad choosing the same nearest corner.
//
//   HL compares graph PATH LENGTHS to insist the node is not further from the
//   monster than from the threat (monsters.cpp:2303) - it can afford to, having
//   an all-pairs table.  Straight-line distance stands in for it here.  The test
//   exists to stop a monster running THROUGH its enemy to reach cover behind
//   them, and for that purpose the two agree everywhere except inside a maze,
//   where a full path-length query per candidate would cost more than the whole
//   rest of the search.
float(entity m, vector threat, vector threateye, float mindist, float maxdist) Cover_Node =
{
	// THE MONSTER HAS TO BE ON THE GRAPH BEFORE ANY OF THIS MEANS ANYTHING, and
	// this line is the first half of a bug sv_ai_covertest found on hl_c01_a1.
	//
	// Without it the search reported 51 successful node picks in twenty seconds
	// while not one of the four subjects moved a single unit: they were standing
	// in a part of the map the graph does not reach, every path request came back
	// empty, and the cover system happily kept choosing spots for them.  A
	// monster off the graph cannot be routed anywhere, so node cover is not
	// available to it at all - say so once, cheaply, instead of discovering it
	// once per candidate.
	float mynode = Nav_NearestNode(m.origin);
	if (mynode < 0)
		return FALSE;

	Cover_Gather(m, mindist, maxdist);
	if (cover_candn <= 0)
		return FALSE;

	float spent = 0;
	float routes = 0;
	float i;
	for (i = 0; i < cover_candn; i = i + 1)
	{
		if (spent >= COVER_TRACE_MAX || routes >= COVER_ROUTE_MAX)
		{
			ai_dbg_cover_capped = ai_dbg_cover_capped + 1;
			return FALSE;
		}

		float cand = cover_cand[i];
		vector p = nav_pos[cand];

		// Cheap tests before the trace, so the trace budget buys as many real
		// candidates as possible.
		if (vlen(p - m.origin) > vlen(p - threat))
			continue;
		if (!Cover_Validate(m, p))
			continue;

		spent = spent + 1;
		if (!Cover_Hides(m, p, threateye))
			continue;

		// AND IT HAS TO BE SOMEWHERE THE MONSTER CAN ACTUALLY GET TO.  This is
		// the second half of the same bug and the more interesting one: a node
		// qualifies as cover precisely BECAUSE the trace to it is blocked, so
		// "hidden" and "on the other side of a wall with no way round" look
		// identical to Cover_Hides.  Every candidate it accepted on hl_c01_a1 was
		// the second kind.
		//
		// Half-Life has this gate too and it is easy to miss, because it is
		// disguised as the action: FindCover's accept condition is
		// `FValidateCover(...) && MoveToLocation(ACT_RUN, 0, node.m_vecOrigin)`
		// (monsters.cpp:2306), and MoveToLocation is what BUILDS the route - so
		// a node with no route to it fails the test and the loop moves on to the
		// next candidate rather than failing the whole search.
		//
		// Nav_FindPathNodes is the synchronous A* the request queue itself uses,
		// driven directly on two node indices.  Safe to call from a think: a
		// queued search runs to completion inside one Nav_Think, so the two can
		// never interleave over the shared open set.  Bounded by COVER_ROUTE_MAX
		// because it is by far the most expensive thing in this file, and it only
		// runs for candidates that have already passed every cheaper test.
		routes = routes + 1;
		nav_path_avoid = 0;
		if (!Nav_FindPathNodes(mynode, cand))
		{
			ai_dbg_cover_noroute = ai_dbg_cover_noroute + 1;
			continue;
		}

		cover_spot = p;
		return TRUE;
	}
	return FALSE;
};

// ---------------------------------------------------------------------------
// the entry point  —  schedule.cpp:739-770
// ---------------------------------------------------------------------------
// Lateral first, then node, exactly as HL orders them, and the order matters for
// how it looks: a monster that always relocates never appears to use the cover
// right beside it.
//
// Returns COVER_* below.  The LOCAL result is not a lesser one - it means the
// spot is close enough to walk straight at, so the caller must NOT wait on a
// path that was never requested.
const float COVER_FAIL    = 0;
const float COVER_LOCAL   = 1;	// sidestep: goal set, no route needed
const float COVER_ROUTED  = 2;	// nav node: a path request is in flight
const float COVER_REFUSED = 3;	// found a spot, could not ask for a route

// The search proper, against a THREAT POSITION rather than a threat entity.
//
// Split out because not every threat is an entity you can point at: a danger
// sound is a place, and taking cover from a grenade means breaking line of sight
// with the ground it is lying on.  HL reaches the same place from the other
// direction - SCHED_TAKE_COVER_FROM_BEST_SOUND feeds CSound::m_vecOrigin into the
// same cover finder that SCHED_TAKE_COVER_FROM_ENEMY feeds an enemy's eyes into.
float(entity m, vector tp, vector te) Cover_FindFrom =
{
	ai_dbg_cover_tries = ai_dbg_cover_tries + 1;

	if (Cover_Lateral(m, tp, te))
	{
		// A LOCAL MOVE, deliberately not a path request.  AI_MoveAlongPath walks
		// straight at ai_goalpos whenever it has no waypoints and the goal is
		// inside NAV_LINK_DIST, so a 48-240 unit sidestep needs no route - and
		// asking for one would be worse than pointless: Nav_RequestPath snaps both
		// ends to the nearest node, and over that distance both ends usually snap
		// to the SAME node, yielding a one-node path that retires on the first tick
		// and a monster that never moves.
		AI_PathClear(m);
		m.ai_goalpos = cover_spot;
		ai_dbg_cover_lateral = ai_dbg_cover_lateral + 1;
		return COVER_LOCAL;
	}

	float lo = COVER_MIN_MOVE;
	if (Cover_Node(m, tp, te, lo, COVER_RADIUS))
	{
		if (!AI_PathRequest(m, cover_spot))
		{
			// The per-monster repath throttle or a full queue.  Counted apart from
			// "no cover exists" because they are opposite problems with opposite
			// fixes, and a single failure counter would blur them into one number
			// that means nothing.
			ai_dbg_cover_refused = ai_dbg_cover_refused + 1;
			return COVER_REFUSED;
		}
		ai_dbg_cover_node = ai_dbg_cover_node + 1;
		if (ai_cached_debug)
			dprint(sprintf("[cover] %s node cover at %v, %g units away\n",
			               m.classname, cover_spot, rint(vlen(cover_spot - m.origin))));
		return COVER_ROUTED;
	}

	ai_dbg_cover_none = ai_dbg_cover_none + 1;
	return COVER_FAIL;
};

float(entity m, entity threat) Cover_Find =
{
	// HL falls back to hiding from ITSELF when it has no enemy (schedule.cpp:744,
	// with Valve's own commented-out TaskFail above it).  Kept: a monster told to
	// take cover with nothing to take cover from should still leave where it is
	// standing, which is what "cover from origin" means.
	if (threat && threat != world)
		return Cover_FindFrom(m, threat.origin, AI_EyePos(threat));
	return Cover_FindFrom(m, m.origin, AI_EyePos(m));
};


// ---------------------------------------------------------------------------
// the guard rail every class trigger goes through
// ---------------------------------------------------------------------------
// Cover is selected by CLASS VIRTUALS, never by the generic ladder, and that is
// a decision rather than an omission.  Half-Life's CBaseMonster::GetSchedule
// does not take cover either - only seven of its classes do (agrunt, barney,
// controller, hassassin, hgrunt, houndeye, islave) - and the ones that do not
// are the ones for which it would be absurd: a headcrab does not duck.
//
// AIMODE_STATIC is checked here rather than trusted to the callers because the
// consequence is not a cosmetic one.  SCHED_TAKE_COVER contains movement tasks,
// a turret cannot satisfy them, and AI_SchedSelfTest asserts that no schedule a
// bolted-down monster can reach contains any - so a class trigger that forgot
// this would turn a self-test that currently passes into a permanent BAD.
float(entity m) Cover_Allowed =
{
	if (!m.ai_enemy)			return FALSE;
	if (m.ai_movemode == AIMODE_STATIC)	return FALSE;
	if (time < m.ai_covernext)		return FALSE;
	return TRUE;
};

// The whole trigger in one call, for the classes whose rule is just "hurt enough
// to want to be somewhere else".  Returns a schedule id or SCHED_NONE so it drops
// straight into a class virtual's ladder.
float(entity m) Cover_ScheduleIfHurt =
{
	ai_dbg_cover_asked = ai_dbg_cover_asked + 1;
	// Split by REASON, because "cover was rarely chosen" has three causes that
	// want three different responses: the trigger is not being reached at all
	// (the condition is gone by the time selection runs), the retry floor is
	// holding it off, or it is working and the map has nothing to offer.
	if (time < m.ai_covernext)
	{
		ai_dbg_cover_floor = ai_dbg_cover_floor + 1;
		return SCHED_NONE;
	}
	if (!Cover_Allowed(m))
		return SCHED_NONE;
	if (!(m.ai_cond & COND_DAMAGE))
	{
		ai_dbg_cover_nodmg = ai_dbg_cover_nodmg + 1;
		return SCHED_NONE;
	}
	ai_dbg_cover_sched = ai_dbg_cover_sched + 1;
	return SCHED_TAKE_COVER;
};

// "I can see him, I want to shoot him, and the squad will not let me."
//
// THE MISSING GOLDSRC BEHAVIOUR, and the main reason a squad here reads as dumb.
// The attack slots ration who may fire so a squad does not form a firing line -
// that part works - but a monster REFUSED a slot just fell through the generic
// ladder to "face, close, reposition" and stood in the open holding a rifle it
// was not allowed to use.  Half-Life's grunt does the opposite: denied a slot it
// takes cover or moves to establish a line of fire, and that single rule is most
// of what makes a GoldSrc squad look alive.
//
// Deliberately NOT in the generic ladder, per the doctrine at the top of this
// file: only the classes that take cover in HL should get it, so it is offered as
// a trigger for a class virtual to call, exactly like Cover_ScheduleIfHurt.
//
// Ordered cheapest-test-first on purpose.  Unlike the hurt trigger this one is
// consulted on every selection during a firefight rather than on a damage event,
// so the two condition tests and the two-bit slot scan come before anything that
// touches time or the cover system.
float(entity m) Cover_ScheduleIfCrowded =
{
	if (!(m.ai_cond & COND_CAN_RANGE1))
		return SCHED_NONE;		// not trying to shoot; nothing is being denied
	if (!(m.ai_cond & COND_SEE_ENEMY))
		return SCHED_NONE;		// no shot for a better reason than the rationing
	if (!Squad_In(m) || Squad_SlotsFree(m))
		return SCHED_NONE;		// solo, or a slot is there for the taking

	ai_dbg_cover_asked = ai_dbg_cover_asked + 1;
	if (time < m.ai_covernext)
	{
		ai_dbg_cover_floor = ai_dbg_cover_floor + 1;
		return SCHED_NONE;
	}
	if (!Cover_Allowed(m))
		return SCHED_NONE;

	ai_dbg_cover_sched = ai_dbg_cover_sched + 1;
	return SCHED_TAKE_COVER;
};

// ---------------------------------------------------------------------------
// is the enemy looking at me?  —  bits_COND_ENEMY_FACING_ME
// ---------------------------------------------------------------------------
// COND_ENEMY_FACING_ME (sv_ai_defs.qc:298) was declared with the rest of the
// condition set and, like COND_FRIEND_DAMAGED before this round, had exactly one
// reference tree-wide: its own declaration.  It exists for one purpose in
// Half-Life - the alien slave breaks for cover when it is being LOOKED at, not
// only when it is being hit (islave.cpp:687-691) - and that is a genuinely
// different behaviour from every other trigger in the ladder, because it fires
// before the first shot rather than after it.
//
// HL's FInViewCone is the reverse of the usual test: the angle is measured in the
// ENEMY's frame, looking back at the monster.  A player's aim is their v_angle,
// not their entity yaw, so the player case reads that instead - otherwise every
// player would appear to be facing wherever their model happened to be turned.
const float COVER_FACING_DOT = 0.5;	// ~60 degrees off the enemy's centre line

float(entity m, entity en) Cover_EnemyFacingMe =
{
	if (!en || en == world)
		return FALSE;

	vector ang = en.angles;
	if (en.flags & FL_CLIENT)
		ang = en.v_angle;
	ang_x = 0;			// yaw only: looking over your head is still facing you
	ang_z = 0;
	makevectors(ang);

	vector d = m.origin - en.origin;
	d_z = 0;
	if (d == '0 0 0')
		return TRUE;
	return ((normalize(d) * v_forward) >= COVER_FACING_DOT);
};
