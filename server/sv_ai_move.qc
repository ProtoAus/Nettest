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
// How far an enemy may wander from the goal a chase route was built to before the
// route is rebuilt mid-walk.  Half-Life's number, complete with its own UNDONE
// comment wondering whether monsters should be able to override it
// (CheckEnemy, dlls/monsters.cpp).  Read by AI_GatherConditions in sv_ai_core.qc.
const float AI_ENEMY_REPATH_DIST = 80;
// Vertical tolerances.  Horizontal-only reach tests are a trap that measurement
// caught: a headcrab standing directly under a player on a walkway reported
// "arrived" at a goal 60 units above its head, stopped, completed its chase
// schedule, re-selected, and did it again forever - 18 arrivals every 2 seconds
// and not one walkmove.  Reaching somewhere in plan view is not reaching it.
const float AI_REACH_STEP   = 18;	// sv_stepheight; what a monster can climb unaided
const float AI_NODE_REACH_Z = 72;	// waypoints: generous, nav links legitimately span stairs
// "Standing on it" rather than merely "near it".  Half a human hull width.  Only
// the doorway hold below reads this, and only to guarantee it terminates - a
// waypoint this close has nothing left to offer, so it retires unconditionally.
const float AI_NODE_ONNODE  = 16;
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
// Traversability traces run by AI_LegClear, and the two decisions it vetoed.
// Kept apart because they answer different questions: skipvetoes counts corners
// the monster wanted to cut through a wall, holdvetoes counts waypoints it
// wanted to retire before it had actually got through the gap.  On a map with no
// tight geometry both should sit near zero; in a doorway they should not.
float ai_dbg_legtraces;
float ai_dbg_skipveto, ai_dbg_holdveto;
// Half-Life's BuildRoute order.  direct = goals granted a straight walk and never
// sent to the node graph at all; nodefall = goals that failed the straight-line
// test and fell through to a nav search, which is HL's "last ditch".  A map where
// nodefall dwarfs direct is one where the geometry really is tight; direct sitting
// at zero in an open room means AI_LocalMoveClear is rejecting things it should
// not, and is the first number to look at if monsters start taking odd routes.
float ai_dbg_direct, ai_dbg_nodefall;
// ...and WHY a straight line was refused, because "direct=0" on its own is
// indistinguishable between "this map is tight" and "the test is broken".
// far = beyond AI_LOCAL_MAX; zgate = HL's DONT_TRIANGULATE height band;
// wall = a step the hull could not take; ledge = a step with no floor under it.
// solid = the hull was already in solid when the step began, which should never
// happen and would mean the test is wrong rather than the map tight;
// steps = total steps reached across all refusals, so steps/(refusals) says
// whether they fail at the first stride or a long way down the line.
float ai_dbg_dfar, ai_dbg_dz, ai_dbg_dwall, ai_dbg_dledge, ai_dbg_dsolid, ai_dbg_dsteps;
// Perception, added with the danger/FOV/investigate work.  danger_heard counts
// monsters notified by a danger sound, danger_cover the ones that acted on it;
// fov_rejected counts acquisitions refused by the view cone, which is the number
// that says whether the cone is doing anything at all.
float ai_dbg_danger_heard, ai_dbg_danger_cover;
float ai_dbg_fov_rejected, ai_dbg_investigate;

// ---------------------------------------------------------------------------
// HL_Normalize
// ---------------------------------------------------------------------------
// Half-Life's Vector::Normalize (util.h), which is NOT the same function as this
// engine's normalize() builtin: for a ZERO vector HL returns (0,0,1) and FTE
// returns (0,0,0).  Everywhere else the two agree exactly.
//
// That one case is load-bearing wherever SDK code normalises a velocity that can
// legitimately be zero, because zero-in/zero-out makes the result an absorbing
// state: the boid flock (mon_flock.qc) spawns every bird at rest and then does
// `velocity = velocity.Normalize(); speed += 10; velocity = velocity * speed`,
// so under FTE's rule a follower multiplies zero by a growing number forever and
// never moves.  Measured: 8 of 9 boids flying on hl_c18, varying run to run with
// which one happened to be the leader.
//
// Named for what it is rather than folded into a call site, because the same
// pattern appears in the Nihilanth's orbit solver and will appear again in the
// next thing ported straight off the SDK.
vector(vector v) HL_Normalize =
{
	if (v == '0 0 0')
		return '0 0 1';
	return normalize(v);
};

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

// THE 45-DEGREE CLIFF, and it is why small fast monsters teleport instead of moving.
//
// FTE refuses to interpolate an entity at all on any packet where its facing moved
// more than 45 degrees.  CL_TransitionPacketEntities computes
//     cos_theta = CompareAngles(sold->angles, snew->angles)      (cl_ents.c:4809)
// and one line later
//     if (DotProduct(move,move) > maxdist || cos_theta < 0.707 || ...) isnew = true;
// (cl_ents.c:4813).  The isnew branch hard-assigns BOTH origin and angles from the
// new packet and collapses old==new (:4830), skipping the MOVETYPE_STEP smoothing
// path at :4852-4890 entirely.  So the whole update - position included - lands as
// one visible jump.
//
// A grunt slewing that fast is barely noticeable because it moves a fraction of its
// own width per tick.  A cockroach is 2 units wide and covers ~11 units per AI tick,
// i.e. more than a body length, so the identical discarded interpolation reads as
// the roach flashing between two places.  That is the reported bug, and the cure is
// simply never to hand the client a >45-degree delta.
//
// 44 rather than 45 because the engine's test is on the cosine and the wire quantises
// yaw; leaving a degree of headroom costs nothing.  It only ever binds on the four
// classes tuned above 220 (cockroach, headcrab, and the two 240s), and only on the
// first tick of a genuinely sharp re-aim - every ordinary turn steps by less than
// this and is untouched.
const float AI_YAW_MAXSTEP = 44;

// TRUE once the monster is facing ai_yaw_ideal within AI_YAW_TOL.
float(entity m, float dt) AI_ChangeYaw =
{
	float diff = AI_AngleNorm(m.ai_yaw_ideal - m.angles_y);

	// Facing is now a QUESTION, not an early exit.  This used to be
	//     if (within tolerance) { m.angles_y = m.ai_yaw_ideal; return TRUE; }
	// which ASSIGNS the ideal outright - a free instantaneous rotation of up to
	// AI_YAW_TOL (12 degrees) every time a monster settled onto a heading.  On a
	// large model that is invisible; on a 2-unit roach whose whole turn completes
	// inside one tick it is most of what the eye actually catches, because the last
	// word on the facing is always a snap rather than a step.  The step below is
	// clamped to whatever remains, so it converges on the ideal within a tick either
	// way and every caller still sees the same TRUE.
	float facing = (diff > -AI_YAW_TOL && diff < AI_YAW_TOL);

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
	// THAT MECHANISM IS NOW LOAD-BEARING HERE TOO, which is why the elapsed time
	// comes from .ai_yawtime rather than from the dt argument.  AI_MoveAlongPath
	// calls this immediately after AI_YawToward so the body turns toward the ideal
	// it just computed (HL's order, monsters.cpp:1847-1848), and AI_Think calls it
	// again after the schedule for monsters that are turning without moving.  With
	// a caller-supplied dt those two would each apply a full tick's rotation and
	// every monster would turn at double its tuned rate; deriving it here means the
	// second call of a tick finds zero elapsed and correctly does nothing.
	//
	// The dt argument is kept in the signature and deliberately ignored: every call
	// site reads as "turn for this tick", and a caller passing 0 (as the in-move one
	// does) should not be a special case that means something different.
	//
	// The clamp is HL's too (monsters.cpp:2550): after a server hitch, elapsed would
	// otherwise let a monster snap round instantly.
	float d = time - m.ai_yawtime;
	if (d > 0.25)
		d = 0.25;
	if (d <= 0)
		return facing;			// already turned this frame
	m.ai_yawtime = time;
	float step = spd * d * 2;

	// Never hand the client a delta it will refuse to interpolate - see the comment
	// on AI_YAW_MAXSTEP above.  Clamping the STEP rather than the SPEED is what makes
	// this hold for a dormant monster too: those tick at 0.5 s (sv_ai_core.qc's
	// dormancy rate), and after the 0.25 clamp and the doubling even a modest
	// yaw_speed of 120 would otherwise ask for 60 degrees in one packet.
	if (step > AI_YAW_MAXSTEP)
		step = AI_YAW_MAXSTEP;

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
	return facing;
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

	// `sv_ai_debug 2`: NAME WHAT SAID NO.  walkmove returns a bare FALSE, so a
	// refusal rate on its own cannot distinguish "wedged against the world",
	// "walking into another monster" and "there is a ledge here" - and those want
	// completely different fixes.  This re-runs the same sweep as a tracebox
	// purely to read the blocker back, throttled to one line per monster per
	// second so a room full of stuck NPCs stays readable.
	//
	// Deliberately not gated on `sv_ai_debug 1`: that level is already a firehose
	// of schedule transitions, and this is the line you go looking for when the
	// counters say the fan is running and the corner-cuts are not landing.
	if (cvar("sv_ai_debug") >= 2 && time >= m.ai_dbg_blockgripe)
	{
		m.ai_dbg_blockgripe = time + 1;
		makevectors('0 1 0' * yaw);
		// FROM A STEPPED-UP ORIGIN, which is the difference between this reading
		// the truth and reading a lie.  SV_movestep lifts the hull by STEPSIZE
		// before it sweeps, precisely so a monster can walk up stairs and over the
		// lip of a slope; a flat sweep from m.origin instead contacts the floor at
		// fraction 0 on ANY ground that is not perfectly level, and reports
		// "blocked by world frac=0.00" for a monster standing in the open.  The
		// first version of this diagnostic did exactly that and made every failure
		// look like a wall.
		vector bstart = m.origin + '0 0 18';
		vector bend   = bstart + v_forward * dist;
		tracebox(bstart, m.mins, m.maxs, bend, MOVE_NORMAL, m);
		if (trace_fraction < 1 || trace_startsolid)
			dprint(sprintf("[ai] %s blocked yaw=%g dist=%g by %s frac=%.2f solid=%g org=%v\n",
			               m.classname, yaw, dist,
			               (trace_ent == world) ? "world" : trace_ent.classname,
			               trace_fraction, trace_startsolid, m.origin));
		else
			// The sweep is clear but walkmove still refused, which means it was
			// not geometry: walkmove also demands somewhere to STAND at the far
			// end (SV_CheckBottom), so this is a ledge, a step too tall, or a
			// drop the monster will not take.
			dprint(sprintf("[ai] %s blocked yaw=%g dist=%g by FOOTING (sweep clear) org=%v\n",
			               m.classname, yaw, dist, m.origin));
	}

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
// for why that field cannot be trusted on a MOVETYPE_STEP monster.
//
// PM_ContentsAt, *NOT* pointcontents, and the difference is the whole bug.
// pointcontents is World_PointContentsWorldOnly (engine server/pr_cmds.c) — it
// sees the WORLD MODEL and nothing else, so it is blind to brush entities.
// GoldSrc puts most of its pools in func_water, and every swimmer standing in
// one answered "not in water" to this test: 12 of 12 leeches on hl_c06, 44 of 44
// on -sp_campaign_portal, 7 of 7 on BlackMesaEPF, 5 of 5 on infested2, 3 of 3 on
// th_ep3_01.  AI_StepVolume below refuses any step whose destination is not in
// water, so those leeches could not move at all — not while idle, not in combat,
// not ever.  (The old comment claimed func_water's negative .skin made
// pointcontents report its interior; the skin trick is real and is what makes
// the CONTENTS query work, but only for a probe that consults brush entities in
// the first place.)
//
// PM_ContentsAt (shared/sh_customdefs.qc) is pointcontentsmask(p, 0) =
// World_PointContentsAllBSPs — the same probe the engine's own waterlevel code
// uses.  It is a strict superset in the direction that matters, and conservative
// in the other: its priority ladder puts CONTENT_SOLID first, so a point inside
// a submerged SOLID_BSP door still answers SOLID rather than WATER.
//
// Lava is excluded: nothing in the corpus lives in it, and a swimmer that treats
// it as home would happily park in a lava pit taking damage forever.
float(vector p) AI_InWater =
{
	float c = PM_ContentsAt(p);
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

// ---------------------------------------------------------------------------
// HALF-LIFE DOES NOT REACH FOR THE NODE GRAPH FIRST
// ---------------------------------------------------------------------------
// CBaseMonster::BuildRoute (dlls/monsters.cpp:1535-1590) opens with
// CheckLocalMove and, if the monster can simply walk the straight line, returns
// a one-waypoint route having never touched the nodes.  The graph is reached
// only in the branch its own comment labels "last ditch, try nodes".
//
// Ours went straight to Nav_RequestPath for every goal, and that is the rest of
// the "NPCs don't lock on, they follow nav even with a clear line" report: a
// route is anchored at Nav_NearestNode(origin) and then runs node to node, so a
// grunt with nothing whatsoever between it and the player still walks the
// dog-leg between two waypoints instead of at the player.
//
// CheckLocalMove is WALK_MOVE(WALKMOVE_CHECKONLY) taken in LOCAL_STEP_SIZE
// increments - a real walk, which climbs steps and REQUIRES GROUND the whole
// way.  That ground requirement is the entire reason this does not become
// "monsters march off ledges", so it is reproduced here rather than being
// approximated by AI_LegClear (which levels the Z and asks only about the
// horizontal opening - right for judging a nav link, far too permissive to
// commit a monster to walking somewhere).
//
// Traces rather than movement: HL teleports the monster to the start, walks it,
// and puts it back (monsters.cpp:1313-1396).  In QC that fires touch functions
// the whole way and can shove the monster through a trigger, so it is not worth
// copying literally.
const float AI_LOCAL_STEP  = 24;	// HL's LOCAL_STEP_SIZE is 16.  24 is the same
									// test at two thirds the trace count and is
									// still well under a 32-wide hull, so nothing
									// narrower than the monster can be stepped over.
// MEASURED, and the first version of this got it wrong.  The cap started at 1024
// because HL has a block at exactly that figure - but HL's block is COMMENTED OUT
// (monsters.cpp:1327-1339), so 1024 is a limit Half-Life does not actually apply.
// On desertcircle every single refusal was this cap and not one straight line was
// ever granted: `route refused: far=8` against `nodefall=8`.  On the tight map
// (th_ep1_01) the cap never fired at all - refusals there were real geometry, at a
// mean of step 5.  So the cap was doing nothing except switching the feature off
// wherever it would have helped most, which is open ground.
const float AI_LOCAL_MAX   = 2048;
// The cost that cap was there to bound is handled properly instead: the stride
// widens on long lines so the trace count is bounded whatever the distance.  64
// steps is ~128 traces worst case, and only a line that stays clear the whole way
// pays for all of them - a blocked one fails at the first obstruction, measured at
// step 5 on a real map.  At the 2048 cap the stride works out at 32, which is the
// hull width: the sweep still cannot miss an obstacle (tracebox sweeps the whole
// box), it only samples the FLOOR every 32 units, and a gap narrower than the
// monster is one it could straddle anyway.
const float AI_LOCAL_MAXSTEPS = 64;
// The monster can reach a spot UNDER the goal but not the goal: HL calls this
// LOCALMOVE_INVALID_DONT_TRIANGULATE and goes straight to the graph
// (monsters.cpp:1374-1382).  Same magic 64, same reason - it is the player
// standing on a ledge, where the straight line ends neatly at its foot and
// walking it would just press the monster into the wall below.
const float AI_LOCAL_MAXZ  = 64;

// How long a granted straight line stays granted.  Short, because the goal is
// usually a moving enemy: this expires with the repath throttle below so the
// line is re-tested about twice a second, and AI_ENEMY_REPATH_DIST already
// forces an earlier rebuild whenever the enemy moves more than 80 units.
const float AI_DIRECT_HOLD = 0.6;
// ...and how long a BLOCKED monster is barred from being granted another one.
// Long enough to actually walk a nav detour rather than immediately re-testing
// a line that still reads as clear; short enough that a monster shoved once by
// a squadmate is not stuck on the graph for the rest of the fight.
const float AI_DIRECT_BLOCKHOLD = 3.0;

float(entity m, vector goal) AI_LocalMoveClear =
{
	if (m.ai_movemode == AIMODE_STATIC)
		return FALSE;

	vector d = goal - m.origin;
	vector flat = d;
	flat_z = 0;
	float dist = vlen(flat);

	if (dist < 1)
		return TRUE;			// already there horizontally
	if (dist > AI_LOCAL_MAX)
	{
		ai_dbg_dfar = ai_dbg_dfar + 1;
		return FALSE;
	}

	// A goal well above or below us that we could otherwise "reach" in plan view
	// is HL's DONT_TRIANGULATE case.  Ground monsters only: a flyer owns its own
	// altitude and a height difference means nothing to it.
	if (m.ai_movemode == AIMODE_GROUND && fabs(d_z) > AI_LOCAL_MAXZ)
	{
		ai_dbg_dz = ai_dbg_dz + 1;
		return FALSE;
	}

	vector dir = flat * (1 / dist);
	vector lo = m.mins, hi = m.maxs;
	vector cur = m.origin;
	float travelled = 0;

	// HARD ITERATION GUARD.  The loop below shortens its last step to land
	// exactly on the goal, and "exactly" is where a float loop goes wrong: once
	// dist-travelled is small enough that travelled+step == travelled in single
	// precision, the counter stops advancing and the condition never fails.
	// That is a hung server, not a bad route, so it is bounded by construction
	// rather than trusted to arithmetic.  +2 covers the shortened final step.
	float guard = 0;
	float maxsteps = AI_LOCAL_MAXSTEPS + 2;

	// Widen the stride on long lines so the trace count stays bounded - see the
	// note beside AI_LOCAL_MAXSTEPS.  Short lines keep the fine 24-unit stride.
	float stride = AI_LOCAL_STEP;
	if (dist / stride > AI_LOCAL_MAXSTEPS)
		stride = dist / AI_LOCAL_MAXSTEPS;

	while (travelled < dist)
	{
		guard = guard + 1;
		if (guard > maxsteps)
			return FALSE;

		float step = stride;
		if (travelled + step > dist)
			step = dist - travelled;
		travelled = travelled + step;

		vector nxt = cur + dir * step;

		if (m.ai_movemode != AIMODE_GROUND)
		{
			// Flyer/swimmer: no floor to stand on, so the whole test is "is the
			// tube clear".  Full 3D, because unlike the ground case the goal's
			// altitude is part of the move.
			nxt_z = m.origin_z + (goal_z - m.origin_z) * (travelled / dist);
			ai_dbg_legtraces = ai_dbg_legtraces + 1;
			tracebox(cur, lo, hi, nxt, MOVE_NOMONSTERS, m);
			if (trace_fraction < 1 || trace_startsolid)
				return FALSE;
			cur = nxt;
			continue;
		}

		// Ground.  Try the move FLAT first and only climb if it is blocked,
		// which is the order SV_movestep uses.  Starting every step 18 units up
		// unconditionally would have demanded 18 units of headroom the monster
		// does not actually need, and would have refused the straight line in
		// any corridor shorter than hull+18 - the exact tight geometry where
		// falling back to the node graph is most expensive.
		vector a = cur, b = nxt;

		ai_dbg_legtraces = ai_dbg_legtraces + 1;
		tracebox(a, lo, hi, b, MOVE_NOMONSTERS, m);
		if (trace_startsolid)
		{
			// Counted apart from an ordinary obstruction on purpose.  A monster
			// is never legitimately inside solid, so startsolid on the FIRST
			// step would mean this test is measuring something other than what
			// it thinks - which is exactly the question "direct=0, wall=22"
			// cannot answer on its own.
			ai_dbg_dsolid = ai_dbg_dsolid + 1;
			ai_dbg_dsteps = ai_dbg_dsteps + guard;
			return FALSE;
		}
		if (trace_fraction < 1)
		{
			a_z = a_z + AI_REACH_STEP;
			b_z = b_z + AI_REACH_STEP;
			ai_dbg_legtraces = ai_dbg_legtraces + 1;
			tracebox(a, lo, hi, b, MOVE_NOMONSTERS, m);
			if (trace_fraction < 1 || trace_startsolid)
			{
				ai_dbg_dwall = ai_dbg_dwall + 1;
				ai_dbg_dsteps = ai_dbg_dsteps + guard;
				return FALSE;
			}
		}

		// ...then drop back onto the floor.  No floor within one step height is
		// a ledge, and refusing here is what keeps this from walking monsters
		// off walkways and into pits.  The drop allows the same 18 down as the
		// climb allowed up, which is what SV_movestep does after a successful
		// walk; the extra AI_REACH_STEP in the trace length is only there to
		// pay back a step-up that did happen.
		b = trace_endpos;
		vector down = b;
		down_z = down_z - (AI_REACH_STEP * 2);

		ai_dbg_legtraces = ai_dbg_legtraces + 1;
		tracebox(b, lo, hi, down, MOVE_NOMONSTERS, m);
		if (trace_fraction >= 1 || trace_startsolid)
		{
			ai_dbg_dledge = ai_dbg_dledge + 1;
			ai_dbg_dsteps = ai_dbg_dsteps + guard;
			return FALSE;		// nothing to stand on
		}

		cur = trace_endpos;
	}

	return TRUE;
};

float(entity m, vector goal) AI_PathRequest =
{
	if (time < m.ai_nextpath)
	{
		// ...UNLESS IT HAS NOTHING TO WALK ON AT ALL.  AI_REPATH_OK exists to stop
		// a monster that already holds a usable route from monopolising the queue,
		// and against that case a full second is right.  A monster with NO route is
		// a different animal: AI_MoveAlongPath falls back to heading straight at
		// the goal, and on real geometry that means pressing into a wall at a fixed
		// heading and sidestepping along it until something else changes.
		//
		// Measured on crossfire, whose nav graph is healthy (701 nodes, 93% in one
		// component): followers spent 100% of their move ticks with no waypoint,
		// and `sv_ai_debug 2` showed the same barney reporting "blocked by world
		// frac=0.00" at the same heading, once a second, for the length of the run.
		// It was not lost - it had never been given a route to be lost from.
		//
		// The HARD floor is untouched, so a genuine failure (queue full, goal
		// unreachable) still backs off the full AI_REPATH_FAIL and this cannot
		// become the retry storm that backoff exists to prevent.
		// Spelled out rather than calling AI_HasPath, which is defined further
		// down this file and so is not in scope yet; this is its first clause and
		// the only one that matters here (a stored route whose cursor has run off
		// the end is exactly as useless as no route, and the second clause would
		// catch that too - but a monster in that state is about to be re-pathed by
		// the schedule anyway).
		if (m.ai_path_len > 0)
			return FALSE;
		if (time < m.ai_nextpath_hard)
			return FALSE;
	}

	m.ai_goalpos = goal;

	// STRAIGHT LINE FIRST, exactly as BuildRoute does - see AI_LocalMoveClear.
	//
	// Behind a cvar because this is a movement-priority change with real
	// regression surface (a monster that now cuts across a room is a monster
	// that is no longer taking the cover-hugging route the graph gave it), and
	// because being able to turn it off in-game is what makes a report about it
	// attributable.  sv_ai_directmove 0 restores the always-use-the-graph
	// behaviour exactly.
	//
	// The nav slot is deliberately NOT released here.  Whatever route the
	// monster is holding simply stops being consulted for as long as
	// ai_directmove is live (AI_MoveAlongPath checks it before AI_HasPath), so
	// this needs no reasoning about slot ownership and cannot leak one.
	if (time >= m.ai_nodirect && cvar("sv_ai_directmove") && AI_LocalMoveClear(m, goal))
	{
		ai_dbg_direct = ai_dbg_direct + 1;
		m.ai_directmove = time + AI_DIRECT_HOLD;
		// Re-tested about twice a second rather than once, because the goal is
		// usually a moving enemy and a line that was clear is the thing most
		// likely to stop being clear.  Cheap: a line that has become blocked
		// fails at the first obstruction, so only a still-clear line pays for
		// the full walk.
		m.ai_nextpath = time + AI_DIRECT_HOLD;
		return TRUE;
	}
	ai_dbg_nodefall = ai_dbg_nodefall + 1;

	if (!Nav_RequestPath(m, goal, 0))
	{
		// Queue full or nav not ready.  Back off like a failure: retrying next
		// tick would just refill the queue with the same request.  Both floors,
		// because this is the case the hard one is for.
		m.ai_nextpath      = time + AI_REPATH_FAIL;
		m.ai_nextpath_hard = time + AI_REPATH_FAIL;
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
	// ...and give up any granted straight line.  AI_LocalMoveClear traces with
	// MOVE_NOMONSTERS - deliberately, so a crowd converging on one player does
	// not push every one of them onto the node graph - which means the one
	// obstruction it cannot see is another monster.  Without this, a monster
	// blocked by its own squadmate re-tests a line that is still "clear",
	// gets granted it again, and walks back into the same body forever.
	// Dropping the grant makes the next request fall through to a nav search,
	// which is what HL does with a failed local move.
	//
	// Dropping it is not enough on its own: the very next AI_PathRequest would
	// re-run the same test, get the same "clear", and hand the line straight
	// back.  So the straight line is BARRED for a few seconds, which is what
	// actually forces the monster onto the graph long enough to get round.
	m.ai_directmove = 0;
	m.ai_nodirect   = time + AI_DIRECT_BLOCKHOLD;
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

// Is the straight line from `from` to `to` walkable by THIS monster's hull?
//
// The path-advance loop below decides twice per tick whether a waypoint can be
// thrown away, and both decisions were purely about distance.  Distance cannot
// see a wall, which is how a monster ends up aiming diagonally at a doorframe
// instead of at the opening - so both of them now have to pass this first.
//
// Deliberately a box sweep on the monster's own hull, matching the nav builder's
// own link validation (Nav_WalkableStepped uses the same 32-wide human box), and
// lifted by the step height so an ordinary threshold or kerb does not read as a
// wall.  The Z components are levelled because a link that climbs stairs is
// legitimate and would otherwise fail every time.
float(entity m, vector from, vector to) AI_LegClear =
{
	vector lo = m.mins, hi = m.maxs;
	lo_z = lo_z + AI_REACH_STEP;

	vector a = from, b = to;
	a_z = a_z + AI_REACH_STEP;
	b_z = a_z;			// level: judge the horizontal opening, not the slope

	ai_dbg_legtraces = ai_dbg_legtraces + 1;
	tracebox(a, lo, hi, b, MOVE_NOMONSTERS, m);
	return (trace_fraction >= 1 && !trace_startsolid);
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

	// A GRANTED STRAIGHT LINE OUTRANKS THE STORED ROUTE.
	//
	// AI_PathRequest sets ai_directmove when AI_LocalMoveClear says the monster
	// can simply walk there, which is HL's BuildRoute returning before it ever
	// looks at the graph.  Checked ahead of AI_HasPath rather than instead of
	// it, so a route the monster was already holding is stepped over rather
	// than freed - nothing here has to reason about who owns the nav slot.
	//
	// have_wp is set so the "no usable waypoint" branch below cannot fire: that
	// branch returns NOPATH beyond NAV_LINK_DIST, which is precisely the case
	// this exists to serve - a clear line to something far away.
	if (m.ai_directmove > time)
	{
		want = m.ai_goalpos;
		have_wp = TRUE;
	}
	else if (AI_HasPath(m))
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
				// ...and retire it anyway if we are ALREADY PAST IT.
				//
				// A route is anchored at Nav_NearestNode(origin) and stored with
				// ai_path_cur = 0 (sv_navnodes.qc:1769, :199-213), so waypoint 0 is
				// the node the monster is standing NEAR - not necessarily the one it
				// is standing ON.  At the auto-grid spacing of 96 units, or an
				// info_node map where links run to NAV_LINK_DIST, that node is
				// routinely BEHIND the monster, and AI_ReachedNode only retires it
				// within 48 units.  So a freshly serviced path opened with a
				// backwards leg: the monster turned round, walked to a node it had
				// already passed, then turned round again - once per re-path, which
				// is the ping-pong at a longer period than the schedule bounce.
				//
				// The test is geometric rather than a special case for index 0, so it
				// also picks up a monster that has drifted past a mid-route waypoint
				// while sidestepping: if we are already at least as close to the NEXT
				// node as this node is, then walking to this one cannot help.
				//
				// AND IT HAS TO BE REACHABLE, which is the half that was missing.
				// The distance test alone reads "am I within one link-length of
				// the next node, straight-line, THROUGH ANYTHING" - walls
				// included - and it lives in a loop that can discard up to
				// NAV_PSLOT_LEN waypoints in a single tick.  On the commonest
				// room-with-one-door shape, where the route leaves the room and
				// doubles back along the far side of the wall, a monster standing
				// in the room is routinely closer to the corridor node than the
				// DOORWAY node is - so the doorway was deleted and the monster
				// aimed diagonally at solid wall.  That is the "one leaving at the
				// wrong angle" half of the jam.
				float nxt = Nav_PathSlot_Node(m, m.ai_path_cur + 1);
				if (nxt >= 0 && nxt < NAV_NODE_MAX)
				{
					vector np = nav_pos[nxt];
					if (vlen(np - m.origin) <= vlen(np - want))
					{
						if (AI_LegClear(m, m.origin, np))
						{
							m.ai_path_cur = m.ai_path_cur + 1;
							continue;
						}
						ai_dbg_skipveto = ai_dbg_skipveto + 1;
					}
				}
				have_wp = TRUE;
				break;
			}

			// REACHED - but not necessarily THROUGH.  AI_NODE_REACH is 48 against
			// a 32-wide hull, so a waypoint is retired a body-and-a-half early,
			// and because the step below is taken along ai_yaw_ideal rather than
			// the body angle the travel vector snaps to the next node on the very
			// same tick.  At an hgrunt's 304 qu/s that is 30 units of movement per
			// tick along the new heading, which in a 64-wide GoldSrc doorway puts
			// the monster into the frame.  Literally "they turn before they
			// actually make it to the door".
			//
			// So hold the waypoint when the next leg is not yet walkable from
			// here but IS walkable from the waypoint: that is exactly the "the
			// gap is still in front of me" case, and nothing else.  Open ground
			// passes both tests and retires as before, so this costs one trace
			// and changes nothing away from tight geometry.
			// The hold MUST terminate, and the distance guard is what guarantees
			// it.  Without one this livelocks: the monster is inside
			// AI_NODE_REACH, the leg ahead is blocked from here and clear from the
			// node, so it holds - and next tick it is still inside AI_NODE_REACH,
			// so it holds again, forever.  Measured on desertcircle before this
			// line existed: holdveto=20 in a 20-tick window, i.e. one monster
			// re-holding the same waypoint every single tick.
			//
			// Once it is genuinely ON the node there is nothing left to walk to
			// and the waypoint retires whatever the geometry says.  Half a hull
			// width is the threshold, which for a 32-wide monster means "the
			// doorway is behind me now".
			vector nd2 = want - m.origin;
			nd2_z = 0;
			float ahead = Nav_PathSlot_Node(m, m.ai_path_cur + 1);
			if (ahead >= 0 && ahead < NAV_NODE_MAX && vlen(nd2) > AI_NODE_ONNODE)
			{
				vector ap = nav_pos[ahead];
				if (!AI_LegClear(m, m.origin, ap) && AI_LegClear(m, want, ap))
				{
					ai_dbg_holdveto = ai_dbg_holdveto + 1;
					have_wp = TRUE;
					break;
				}
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

	// ...and turn toward it NOW, on the ideal we just computed.
	//
	// This is HL's own order - CBaseMonster::Move calls MakeIdealYaw and ChangeYaw
	// back to back inside the move (monsters.cpp:1847-1848) - and not having it was
	// the rest of the "NPCs turn really slowly" report.  AI_Think used to do all its
	// turning at sv_ai_core.qc:1986, one line BEFORE AI_RunSchedule, so the body
	// spent every tick turning toward the ideal computed on the PREVIOUS tick while
	// the step was taken along the new one.  The facing was permanently a tick
	// stale, and against a moving leader it could never converge at all - it was
	// always chasing where the goal had been 100 ms ago.
	//
	// Calling it here does not double anyone's turn rate: AI_ChangeYaw stamps
	// .ai_yawtime and derives its own elapsed time from it, so the post-schedule
	// call in AI_Think finds zero elapsed and does nothing.  That is HL's mechanism
	// too (m_flLastYawTime), and for exactly this reason - it wants ChangeYaw to be
	// callable from several places without the turn stacking.
	AI_ChangeYaw(m, 0);

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

	// PUT THE WALK CYCLE BACK, and this is most of the "NPCs slide around" report.
	//
	// The turn branch above sets ACT_TURN_LEFT/RIGHT, and nothing ever undid it.
	// ai_moveact is written exactly twice - at task start (sv_ai_core.qc:1346)
	// and when the follow gait band is crossed (:1681) - and that second site is
	// guarded by `want != m.ai_moveact`, which is FALSE after a turn: the field
	// still says ACT_RUN, it is the playing ACTIVITY that got clobbered.  So the
	// re-assert never fired.
	//
	// It bites hardest on exactly the rigs used for escorts.  barney.mdl and
	// scientist.mdl carry no ACT_TURN_* sequence, so the fallback at
	// sv_ai_anim.qc:95-96 sends them to ACT_IDLE - and then they travel, at full
	// running speed, in an idle pose with their feet planted.  That is the
	// skating.
	//
	// AI_SetActivity is idempotent (sv_ai_anim.qc:388), so on the overwhelming
	// majority of ticks - the ones that never turned - this costs a comparison.
	if (m.ai_moveact != ACT_RESET)
		AI_SetActivity(m, m.ai_moveact);

	// WALK WHERE YOU ARE POINTING, not where you WANT to point.
	//
	// This stepped along `yaw`, which is m.ai_yaw_ideal - the heading computed from
	// the waypoint a few lines ago.  The body turns toward that ideal at yaw_speed
	// but travels along it instantly, so a monster asked to change direction slides
	// sideways along the new heading with its model still facing the old one, and
	// only catches up over the next few ticks.  It is subtle on a slow turn and very
	// obvious on a fast one, and it is exactly the "move towards their location, and
	// as they do, rotate towards that direction as they move" the report asked for:
	// stepping along the BODY makes the path a real arc into the turn.
	//
	// Behind a cvar because it is a deliberate divergence from the SDK, which uses
	// ideal_yaw for WALK_MOVE (roach.cpp:365) and moves toward the waypoint POSITION
	// in the generic mover (monsters.cpp:1992).  It also makes monsters take wider
	// lines through doorways, which interacts with the corner-cut logic above - so if
	// anything starts clipping door frames, `sv_ai_arcturns 0` is the first thing to
	// try and it restores the old behaviour exactly.
	//
	// The pivot branch above is untouched: past AI_TURN_REFUSE the monster is not
	// travelling at all, so there is no arc to draw.
	float ok;
	float stepyaw = yaw;
	if (ai_cached_arcturns)
		stepyaw = m.angles_y;

	if (m.ai_movemode == AIMODE_GROUND)
		ok = AI_StepToward(m, stepyaw, dist);
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
	//
	// PROJECTED onto the direction of travel, not raw displacement, and that is
	// the difference between this check working and being decorative.  Raw
	// distance moved cannot tell progress from DITHER: a monster shuttling
	// left-right between two points covers a full stride every single tick, so
	// it scored maximum progress, reset ai_stuck to zero, and could oscillate
	// forever without ever reaching BLOCKED - the only result that drops the
	// route and asks for a new path.  Measured on hl_c01_a1 before this changed:
	// 236 sidesteps and 0 corner-cuts in a two-second window, 121 follow
	// selections, 3 arrivals.
	//
	// The sign matters as much as the magnitude: a step that ends up FURTHER
	// from the goal scores negative and counts against the monster, which is
	// what makes a two-point bounce converge on BLOCKED in a few ticks instead
	// of never.
	vector moved = m.origin - m.ai_lastorg;
	vector togoal = want - m.ai_lastorg;
	moved_z  = 0;
	togoal_z = 0;
	float advance;
	if (vlen(togoal) > 0)
		advance = moved * normalize(togoal);
	else
		advance = vlen(moved);		// no direction to judge against; fall back
	if (advance < dist * 0.25)
		m.ai_stuck = m.ai_stuck + 1;
	else
		m.ai_stuck = 0;
	m.ai_lastorg = m.origin;

	if (m.ai_stuck >= AI_STUCK_TICKS)
	{
		m.ai_stuck = 0;
		ai_dbg_mv_blocked = ai_dbg_mv_blocked + 1;

		// VACATE THE GAP BEFORE GIVING UP, because of what giving up costs
		// everyone else.  AIMOVE_BLOCKED lands the monster in
		// SCHED_CHASE_ENEMY_FAILED, which is STOP_MOVING / ACT_IDLE / FACE_ENEMY
		// / WAIT 1 - and it is SOLID_SLIDEBOX for the whole of that second.  In a
		// doorway that converts one wedged body into a plug: everything behind it
		// is now blocked by something that has stopped moving on purpose, each of
		// those accumulates its own stuck count, and the whole squad takes turns
		// freezing in the same opening.  That is the "one leaving at the wrong
		// angle blocks them all" the report describes.
		//
		// So spend the last tick backing out of the aperture rather than settling
		// into it.  Straight back first, then the two rear quarters - the monster
		// is by definition not making progress forwards, so nothing is lost, and
		// a body that has retreated a stride is a body the ones behind can get
		// past.  walkmove refuses when there is nowhere to go, in which case this
		// costs three traces and changes nothing.
		float bk = dist;
		if (bk < 16) bk = 16;
		if (!walkmove(m.angles_y + 180, bk))
			if (!walkmove(m.angles_y + 135, bk))
				walkmove(m.angles_y - 135, bk);
		m.ai_lastorg = m.origin;

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
	vector orig;
	float  ok;
	float  lift;

	// HALF-LIFE RAISES THE MONSTER ONE UNIT BEFORE DROPPING IT - monsters.cpp:2088,
	// whose comment is literally "Raise monster off the floor one unit, then drop
	// to floor".  Without that lift a body whose origin sits even a fraction inside
	// the floor fails outright: FTE's droptofloor returns 0 when the downward trace
	// is allsolid (pr_bgcmd.c:6660-6678) and sv_gameplayfix_droptofloorstartsolid
	// defaults to 0.  Measured on hl_c06 against the map's own clipnodes: the two
	// plain monster_human_grunt at z = -1.0 are SOLID at their own origin and EMPTY
	// one unit up, so this single line is the whole difference between a soldier and
	// a statue.  See the caller in sv_ai_core.qc for the other half of that bug.
	orig = m.origin;
	setorigin(m, m.origin + '0 0 1');

	self = m;
	ok   = droptofloor();
	self = oldself;

	// Still stuck.  Half-Life gives up at this point and leaves the monster where it
	// stands; we get one better cheaply, because bodies that fail are usually
	// embedded by a handful of units after an editor nudge or a re-compile.  Step up
	// in 4s - the same tracebox startsolid idiom AI_PlaceInVolume uses below - and
	// re-drop from the first height that is clear.
	//
	// Restore the mapper's origin if nothing frees it, so a genuinely buried body is
	// reported at the coordinates that are actually in the .bsp rather than 32 units
	// above them.
	if (!ok)
	{
		for (lift = 4; lift <= 32; lift = lift + 4)
		{
			setorigin(m, orig + [0, 0, lift]);
			tracebox(m.origin, m.mins, m.maxs, m.origin, MOVE_NORMAL, m);
			if (trace_startsolid || trace_allsolid)
				continue;

			self = m;
			ok   = droptofloor();
			self = oldself;
			if (ok)
				break;
		}
		if (!ok)
			setorigin(m, orig);
	}

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
	{
		// NUDGE, exactly as AI_PlaceOnFloor does, and the asymmetry was the bug.
		//
		// The ground path steps up in 4s and re-drops from the first height that is
		// clear, on the reasoning that "bodies that fail are usually embedded by a
		// handful of units after an editor nudge or a re-compile".  That reasoning
		// is not about gravity and applies to a swimmer or a flyer word for word -
		// but this function gave up on the first probe, so a monster one unit into
		// a pool wall was written off outright.
		//
		// th_ep1_01's three monster_leech are the measured case: `[ai] monster_leech
		// at 3166 -4670 -2312 could not be placed (movemode 2)`, and the AI volume
		// report for that map reads `clearance min=-1`, i.e. ONE unit of overlap.
		// A leech that fails here keeps its brain (it is map-placed) but can never
		// take a step, because AI_StepVolume refuses every move out of a startsolid
		// position - so it hangs in the rock doing nothing, which is what a player
		// swimming up to it reads as "it was already dead".
		//
		// Six directions per radius, nearest radius first, so the body comes out the
		// shortest way rather than always upward - a leech embedded in a ceiling and
		// one embedded in a floor both want the opposite of the other.  The mapper's
		// origin is restored if nothing frees it, for the same reason the ground path
		// restores it: a genuinely buried body should be reported at the coordinates
		// that are really in the .bsp.
		vector orig = m.origin;
		float  r, d;
		float  freed = FALSE;

		for (r = 4; r <= 32 && !freed; r = r + 4)
		{
			for (d = 0; d < 6; d = d + 1)
			{
				vector off = '0 0 0';
				if      (d == 0) off_z =  r;
				else if (d == 1) off_z = -r;
				else if (d == 2) off_x =  r;
				else if (d == 3) off_x = -r;
				else if (d == 4) off_y =  r;
				else             off_y = -r;

				setorigin(m, orig + off);
				tracebox(m.origin, m.mins, m.maxs, m.origin, MOVE_NORMAL, m);
				if (trace_startsolid || trace_allsolid)
					continue;

				// A swimmer freed into thin air has traded one dead end for a
				// worse one - AI_StepVolume will refuse every move back into the
				// water it can no longer reach.  Keep looking.
				if (m.ai_movemode == AIMODE_SWIM && !AI_InWater(m.origin))
					continue;

				freed = TRUE;
				break;
			}
		}

		if (!freed)
		{
			setorigin(m, orig);
			return FALSE;
		}

		if (ai_cached_debug)
			dprint(sprintf("[ai] %s freed from geometry: %v -> %v\n",
			               m.classname, orig, m.origin));
	}

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
