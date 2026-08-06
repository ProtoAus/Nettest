// server/sv_navnodes.qc
// ----------------------------------------------------------------------------
// Bot navigation graph (GoldSrc info_node-compatible) + A* pathfinding.
//
//  * info_node / info_node_air map entities register nav nodes (HL/GoldSrc maps
//    that already place them work for free — the engine dispatches the BSP
//    classname to these QC spawn funcs).  info_node drops to the floor and sits
//    NAV_NODE_HEIGHT above it (GoldSrc convention); info_node_air stays placed.
//  * For maps WITHOUT info_node (most CS/custom maps) we auto-generate a walkable
//    node grid by flood-filling outward from the player spawn points, dropping
//    each sample to the floor and linking reachable neighbours.  Built
//    incrementally across frames so there is no "Rebuilding Node Graph" stall.
//  * Links honour GoldSrc-ish line-of-sight: blocked by world geometry and
//    static brush ents (func_wall), but movers (func_door / func_train, i.e.
//    brush_type DOOR/TRAIN/VEHICLE) and non-solids are passed through.  The
//    mover/static split keys off brush_type, NOT movetype - every replicated
//    brush in this mod is MOVETYPE_PUSH, so a movetype test classifies nothing.
//    See Nav_EntBlocks.
//  * FTE's engine route_calculate() only consumes on-disk .way/.nav files, so we
//    roll our own A* (Nav_FindPath) over the node arrays.
//
// All QC globals persist across map changes (the progs aren't reloaded), so the
// graph is RESET from worldspawn (Nav_Reset) before each map's entities spawn.
// Nav_Tick() (called from SV_StartFrame) drives the incremental builder.
//
// Compile order: listed in sv_progs.src before sv_bots.qc + sv_main.qc.
// ----------------------------------------------------------------------------

const float NAV_NODE_MAX   = 2048;	// hard cap (logs + caps cleanly if exceeded — never overruns)
const float NAV_LINK_MAX   = 16;	// neighbours per node
const float NAV_PATH_MAX   = 128;	// longest path / reconstruct buffer
const float NAV_QUEUE_MAX  = 1024;	// flood BFS ring buffer

const float NAV_NODE_HEIGHT = 32;	// node floats this far above the floor
const float NAV_STEP_HEIGHT = 22;	// max step a link may climb
const float NAV_FLOOR_TRACE = 2048;	// how far down to look for floor
const float NAV_MIN_INFONODES = 6;	// >= this many info_nodes -> use them, skip auto-grid
// Max link length for the info_node all-pairs pass.  This was 384, which was the
// single biggest cause of unusable nav graphs: Half-Life's own node graph has NO
// length limit, so mappers place info_nodes wherever two of them can see each
// other, and Sven maps routinely space them 300+ apart (pizza_ya_san1's median
// neighbour distance is 308).  At 384 a 98-node map linked into 22 disconnected
// pieces with the largest holding 20% of the nodes; at 1536 the same map is 3
// pieces with 96% in the largest.
//
// It is affordable now only because candidates are shortlisted to the nearest few
// before anything is traced (NAV_CAND_MAX) - the radius no longer sets the cost.
// The value is NAV_PROFILE_STEP * NAV_PROFILE_MAX so that the floor-continuity
// probe always covers a link end to end; a longer link would be accepted with its
// far end unchecked.
const float NAV_LINK_DIST   = 2304;
const float NAV_FLOOD_BUDGET = 150;	// flood pops processed per frame (one-time map build)
const float NAV_LINK_BUDGET  = 24;	// link source-nodes processed per frame (legacy)
const float NAV_TRACE_BUDGET = 400;	// traces the link pass may spend per frame

// builder states
const float NAVB_IDLE   = 0;
const float NAVB_FLOOD  = 1;
const float NAVB_LINK   = 2;
const float NAVB_READY  = 3;

// --- node storage ---
vector nav_pos[NAV_NODE_MAX];
float  nav_build_serial;	// bumped each (re)build so nav-debug proxies resend the graph
float  nav_air[NAV_NODE_MAX];
float  nav_count;
float  nav_cap_logged;	// latched once the node cap is hit (don't corrupt nav_count)

// --- links (flat: node*NAV_LINK_MAX + k) ---
float  nav_linkcount[NAV_NODE_MAX];
float  nav_link[NAV_NODE_MAX * NAV_LINK_MAX];		// neighbour node index
float  nav_linkdist[NAV_NODE_MAX * NAV_LINK_MAX];	// edge cost (distance)

// Per-link restrictions.  A link blocked ONLY by a func_monsterclip is kept and
// flagged rather than dropped, because monsterclip is a hint about MONSTERS and
// nothing else: bots and any future non-monster user must still be able to route
// through it.  A searcher declares what it refuses to cross in nav_path_avoid.
const float NAVLF_MONSTERCLIP = 1;
float  nav_linkflags[NAV_NODE_MAX * NAV_LINK_MAX];
float  nav_path_avoid;		// link flags the CURRENT search will not traverse

// --- A* scratch (stamped so we never clear per search) ---
float  nav_g[NAV_NODE_MAX];
float  nav_fscore[NAV_NODE_MAX];
float  nav_from[NAV_NODE_MAX];
float  nav_visit[NAV_NODE_MAX];
float  nav_stamp;
float  nav_recon[NAV_PATH_MAX];

// --- A* open set: binary min-heap keyed on nav_fscore ---
//
// This replaces a full linear scan over EVERY node per pop.  The old open set was
// just a stamp array (nav_inopen[]), so membership had to be rediscovered by
// sweeping all nav_count nodes for the lowest f - once per pop.  Real maps in
// qconsole.log run 20-1715 nodes, and the pop guard allowed 6*V pops, so a single
// search on a 1715-node map could reach ~17.6M inner iterations of interpreted QC.
// With the heap a search is ~V*log2(V) ~ 19k operations.
//
// nav_heap is 1-BASED (slot 1 is the root) so the parent/child arithmetic is plain
// halving and doubling; nav_heap[0] is unused, hence the +1 size.
// nav_heappos maps node -> its heap slot, which is what makes decrease-key O(log n)
// instead of a search - and it doubles as the membership test that nav_inopen[] used
// to provide, so that array is gone entirely.  That deletion is deliberate: it also
// removes the cross-map stale-open bug described in Nav_Reset.
float  nav_heap[NAV_NODE_MAX + 1];	// heap slot -> node index
float  nav_heappos[NAV_NODE_MAX];	// node index -> heap slot; 0 = not in open set
float  nav_heapn;					// number of entries currently in the heap

// --- path result (start -> goal node indices) ---
float  nav_result[NAV_PATH_MAX];
float  nav_result_len;

// ---------------------------------------------------------------------------
// path slot pool
// ---------------------------------------------------------------------------
// Bot paths live in bot_pathnodes[], indexed by `num_for_edict(self) - 1`, which
// only works because players occupy edicts 1..32.  Monsters have no such
// reservation and there will be 50+ of them, so they allocate explicitly.
//
// nav_pslot_owner is not bookkeeping - it is the guard that makes release
// idempotent.  Pushing one slot onto the free list twice would hand it to two
// entities that then silently overwrite each other's waypoints, which is the only
// way this structure can corrupt itself.
const float NAV_PSLOT_MAX = 96;		// 32 player slots + 64 concurrently-pathing monsters
const float NAV_PSLOT_LEN = 24;		// == BOT_PATHLEN, so one stride serves both
float  nav_pslot_nodes[NAV_PSLOT_MAX * NAV_PSLOT_LEN];
float  nav_pslot_free[NAV_PSLOT_MAX];
entity nav_pslot_owner[NAV_PSLOT_MAX];
float  nav_pslot_freen;
float  nav_pslot_inuse;
float  nav_pslot_starved;		// diagnostics: acquisitions refused

void() Nav_PathPool_Init =
{
	float i;
	nav_pslot_freen = 0;
	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
	{
		nav_pslot_owner[i] = world;
		// push in reverse so the first acquire hands out slot 0 - purely so logs
		// and repro cases are stable rather than depending on fill order
		nav_pslot_free[nav_pslot_freen] = NAV_PSLOT_MAX - 1 - i;
		nav_pslot_freen = nav_pslot_freen + 1;
	}
	nav_pslot_inuse = 0;
	nav_pslot_starved = 0;
};

// Returns a slot index, or -1 when the pool is empty.  Idempotent: an entity that
// already holds a slot gets the same one back.
float(entity e) Nav_PathSlot_Acquire =
{
	if (e == world)
		return -1;
	if (e.ai_pathslot > 0)
		return e.ai_pathslot - 1;
	if (nav_pslot_freen <= 0)
	{
		nav_pslot_starved = nav_pslot_starved + 1;
		return -1;			// caller degrades to direct movement
	}
	nav_pslot_freen = nav_pslot_freen - 1;
	float s = nav_pslot_free[nav_pslot_freen];
	if (s < 0 || s >= NAV_PSLOT_MAX)
		return -1;			// corrupt free list; refuse rather than scribble
	nav_pslot_owner[s] = e;
	e.ai_pathslot = s + 1;
	nav_pslot_inuse = nav_pslot_inuse + 1;
	return s;
};

void(entity e) Nav_PathSlot_Release =
{
	if (e == world)
		return;
	if (e.ai_pathslot <= 0)
		return;				// holds nothing - the idempotent case
	float s = e.ai_pathslot - 1;
	e.ai_pathslot = 0;
	e.ai_path_len = 0;
	if (s < 0 || s >= NAV_PSLOT_MAX)
		return;
	// The owner check is what stops a double release: after the first, the slot
	// belongs to world (or to whoever acquired it next), so the second finds a
	// mismatch and does nothing instead of pushing the index twice.
	if (nav_pslot_owner[s] != e)
		return;
	nav_pslot_owner[s] = world;
	if (nav_pslot_freen < NAV_PSLOT_MAX)
	{
		nav_pslot_free[nav_pslot_freen] = s;
		nav_pslot_freen = nav_pslot_freen + 1;
	}
	nav_pslot_inuse = nav_pslot_inuse - 1;
};

// Copy the live nav_result into e's slot.  nav_result is a single global with no
// reentrancy, so this must happen before anything else can search.
float(entity e) Nav_PathSlot_Store =
{
	float s = Nav_PathSlot_Acquire(e);
	if (s < 0)
		return FALSE;
	float n = nav_result_len;
	if (n > NAV_PSLOT_LEN) n = NAV_PSLOT_LEN;
	float i;
	for (i = 0; i < n; i = i + 1)
		nav_pslot_nodes[s * NAV_PSLOT_LEN + i] = nav_result[i];
	e.ai_path_len = n;
	e.ai_path_cur = 0;
	e.ai_path_serial = nav_build_serial;
	return n > 0;
};

// -1 when e has no usable path, including when the graph was rebuilt underneath it
// (node INDICES are meaningless across a rebuild, so a stale path is not merely
// out of date - it points at whatever now occupies those slots).
float(entity e, float step) Nav_PathSlot_Node =
{
	if (e.ai_pathslot <= 0)			return -1;
	if (e.ai_path_serial != nav_build_serial)	return -1;
	if (step < 0)				return -1;
	if (step >= e.ai_path_len)		return -1;
	float s = e.ai_pathslot - 1;
	if (s < 0 || s >= NAV_PSLOT_MAX)	return -1;
	return nav_pslot_nodes[s * NAV_PSLOT_LEN + step];
};

// --- flood BFS queue ---
float  nav_q[NAV_QUEUE_MAX];
float  nav_qhead;
float  nav_qtail;

// --- builder state ---
float  nav_state;
float  nav_have_infonodes;
float  nav_link_cursor;		// progress through the all-pairs link pass
float  nav_floor_ok;		// set by Nav_FloorDrop
float  nav_dbg_floor, nav_dbg_dz, nav_dbg_walk, nav_dbg_dedup, nav_dbg_add;	// flood diagnostics
float  nav_dbg_lastcount;	// heartbeat throttle
float  nav_build_start;		// server time the build left NAVB_IDLE

// Traces spent by the link pass this frame.  The pass used to be budgeted in
// SOURCE NODES, which is not the thing that costs anything: a node in a crowded
// area with sixty candidates does sixty traces, one in a corridor does four.
// Declared up here because the walkability tests themselves charge against it.
float  nav_trace_spent;

// Trace proxy for walkability tests.
//
// A trace's contents mask comes from its PASSEDICT (engine world.c:2800-2848), and
// passing `world` yields the ordinary solid mask - which does not include
// MONSTERCLIP, so func_monsterclip volumes are invisible to it.  This entity
// exists only to carry a mask that DOES include it: .hitcontentsmaski is consulted
// first of all (world.c:2800), so no FL_MONSTER / SOLID_SLIDEBOX games are needed.
//
// It is spawned in Nav_Reset, which runs once per map from worldspawn
// (sv_main.qc:1588) - never at init, because a QC entity handle held across a map
// change refers to a freed edict that the next map will have reused.
entity nav_probe;
// Set for one call to make the walkability tests trace as `world` instead, i.e.
// with monsterclip volumes invisible.  Used to ask "was the clip the ONLY thing
// stopping this link?" without duplicating the test.
float  nav_probe_bypass;

entity() Nav_TracePass = { if (nav_probe_bypass) return world; return nav_probe; };

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// Drop a point to the floor and return floor + NAV_NODE_HEIGHT.  Sets
// nav_floor_ok FALSE if there's no walkable floor below (steep / void).
vector(vector p) Nav_FloorDrop =
{
	vector down = p; down_z = down_z - NAV_FLOOR_TRACE;
	traceline(p + '0 0 8', down, MOVE_NOMONSTERS, world);
	nav_floor_ok = FALSE;
	if (trace_startsolid || trace_allsolid)
		return p;
	if (trace_fraction >= 1)
		return p;				// no floor found
	if (trace_plane_normal_z < 0.7)
		return p;				// too steep to stand
	nav_floor_ok = TRUE;
	vector r = trace_endpos;
	r_z = r_z + NAV_NODE_HEIGHT;
	return r;
};

// Why the last Nav_Walkable call answered the way it did.  Set on EVERY exit so
// the link-pass diagnostics (sv_nav_linkdebug) can attribute rejections instead of
// guessing.  Pure instrumentation - nothing in the pathfinder reads it.
const float NAVW_CLEAR      = 0;	// swept the whole way
const float NAVW_STARTSOLID = 1;	// the box is already stuck at 'a'
const float NAVW_WORLD      = 2;	// world geometry in the way
const float NAVW_STATIC     = 3;	// static brush ent (func_wall) in the way
const float NAVW_MOVER      = 4;	// door/train/other -> treated as passable
float nav_walk_reason;
float nav_walk_frac;
float nav_walk_startsolid;	// recorded separately: it CROSSES the reason codes
entity nav_walk_blocker;	// what said no, for the sv_nav_linkdebug 2 dump

vector NAV_SWEEP_MINS = '-16 -16 -10';
vector NAV_SWEEP_MAXS = '16 16 40';
const float NAV_SWEEP_MAXPASS = 4;	// movers a single link may be let through

// Does this brush entity stop a monster?
//
// This USED to ask `solid == SOLID_BSP && movetype != MOVETYPE_PUSH`, which is
// dead code in this mod: SV_InitReplicatedSolidBrush (sv_brushsync.qc:564-566)
// gives EVERY replicated brush MOVETYPE_PUSH and never clears it, func_wall
// included.  So func_wall, func_wall_toggle and func_breakable all fell through to
// "mover -> passable" and nav linked straight through them, while the diagnostic
// counter for static-brush rejections was structurally always zero - which is
// exactly why the earlier measurement read `static=0` and looked reassuring.
//
// brush_type is the taxonomy the mod already maintains for these (sh_weapons.qc:
// 486-496), so use it.  Only things that genuinely move out of the way are
// passable; everything else, INCLUDING an unset brush_type, blocks.  That default
// is deliberate: forgetting to mark a mover makes monsters walk around a door,
// while forgetting to mark a wall makes them walk through it.
float(entity e) Nav_EntBlocks =
{
	if (e == world)			return TRUE;
	if (e.solid != SOLID_BSP)	return FALSE;	// triggers, items, non-solids
	if (e.brush_type == BRUSH_TYPE_DOOR)	return FALSE;
	if (e.brush_type == BRUSH_TYPE_TRAIN)	return FALSE;
	if (e.brush_type == BRUSH_TYPE_VEHICLE)	return FALSE;
	// func_breakable lands here and BLOCKS.  That is a deliberate call, not an
	// oversight: a monster that paths through an intact glass pane and wedges
	// against it is worse than one that walks around.  Revisit when there is
	// break-the-obstacle behaviour to route into.
	return TRUE;
};

// Distance from p along unit dir to leave the box mn..mx.  0 if dir is degenerate.
float(vector p, vector dir, vector mn, vector mx) Nav_ExitDist =
{
	float best = 1000000; float t;
	if (dir_x >  0.001)	{ t = (mx_x - p_x) / dir_x; if (t < best) best = t; }
	else if (dir_x < -0.001){ t = (mn_x - p_x) / dir_x; if (t < best) best = t; }
	if (dir_y >  0.001)	{ t = (mx_y - p_y) / dir_y; if (t < best) best = t; }
	else if (dir_y < -0.001){ t = (mn_y - p_y) / dir_y; if (t < best) best = t; }
	if (dir_z >  0.001)	{ t = (mx_z - p_z) / dir_z; if (t < best) best = t; }
	else if (dir_z < -0.001){ t = (mn_z - p_z) / dir_z; if (t < best) best = t; }
	if (best >= 1000000)	return 0;
	if (best < 0)		return 0;
	return best;
};

// Can a player-sized box travel between two node points unobstructed?
// World + static brush ents block; doors / trains / vehicles are passed THROUGH.
float(vector a, vector b) Nav_Walkable =
{
	vector dir = b - a;
	float total = vlen(dir);
	if (total < 1)
	{
		nav_walk_reason = NAVW_CLEAR;
		nav_walk_frac = 1;
		nav_walk_startsolid = FALSE;
		return TRUE;
	}
	dir = dir * (1 / total);

	vector start = a;
	float pass;
	for (pass = 0; pass < NAV_SWEEP_MAXPASS; pass = pass + 1)
	{
		tracebox(start, NAV_SWEEP_MINS, NAV_SWEEP_MAXS, b, MOVE_NOMONSTERS, Nav_TracePass());
		if (pass == 0)
		{
			nav_walk_frac = trace_fraction;
			// Recorded, deliberately not acted on - a startsolid box keeps whatever
			// verdict the geometry gives it.
			nav_walk_startsolid = (trace_startsolid || trace_allsolid);
		}
		if (trace_fraction >= 1)
		{
			nav_walk_reason = NAVW_CLEAR;
			return TRUE;
		}
		if (trace_ent == world)
		{
			nav_walk_reason = NAVW_WORLD;
			return FALSE;
		}
		if (Nav_EntBlocks(trace_ent))
		{
			nav_walk_reason = NAVW_STATIC;
			nav_walk_blocker = trace_ent;
			return FALSE;			// func_wall and friends
		}

		// A door or train.  Returning TRUE here - which is what this did before -
		// accepts the link having tested only as far as the mover's near face,
		// leaving the rest of the chord unexamined.  That was survivable while
		// links were capped at 384 units and is not at 2304.  Resume the sweep from
		// just beyond the mover instead and keep going.
		vector mn = trace_ent.absmin - NAV_SWEEP_MAXS;
		vector mx = trace_ent.absmax - NAV_SWEEP_MINS;
		float ex = Nav_ExitDist(trace_endpos, dir, mn, mx);
		vector next = trace_endpos + dir * (ex + 1);
		if (vlen(next - start) < 1)
		{
			nav_walk_reason = NAVW_MOVER;
			return FALSE;			// no progress: refuse rather than spin
		}
		if (vlen(b - start) <= vlen(next - start))
		{
			nav_walk_reason = NAVW_MOVER;
			return TRUE;			// stepped past the far end -> clear
		}
		start = next;
	}
	nav_walk_reason = NAVW_MOVER;
	return FALSE;					// too many movers stacked; be conservative
};

// ---------------------------------------------------------------------------
// stepped walk test  —  what Half-Life actually does
// ---------------------------------------------------------------------------
// Nav_Walkable's single straight box sweep is strictly harsher than a monster
// walking the same route: a real walk gets a fresh step-up allowance at EVERY
// increment, so it climbs stairs, crosses thresholds and follows slopes that one
// straight sweep from A to B slams into.  Half-Life builds its own node graph this
// way (CTestHull WalkMoves between node pairs), so Sven/HL mappers placed their
// info_nodes assuming a walker, not a laser.
//
// This marches a floor-anchored hull along the link in NAV_WALK_STEP increments.
// Each increment lifts by NAV_STEP_HEIGHT, sweeps forward, then drops back down -
// exactly the up/forward/down that World_movestep does for walkmove().  A step that
// finds no floor within NAV_WALK_DROP is a ledge and fails the link, which is the
// one thing the straight sweep cannot detect at all.
const float NAV_WALK_STEP = 24;		// horizontal increment per simulated step
const float NAV_WALK_DROP = 96;		// how far a step may fall before it's a ledge
const float NAV_WALK_MAXSTEPS = 96;	// covers the longest link distance, plus slack

// Hull anchored at the FEET, not at the node.  Nodes sit NAV_NODE_HEIGHT above the
// floor, so subtracting that puts the box bottom on the ground where a monster's is.
vector NAV_HULL_MINS = '-16 -16 0';
vector NAV_HULL_MAXS = '16 16 72';

// TRUE if the swept hull was stopped by something a monster genuinely cannot pass.
// Movers (doors/trains) and non-solids are passable, matching Nav_Walkable.
float() Nav_HitBlocker =
{
	if (trace_fraction >= 1)		return FALSE;
	return Nav_EntBlocks(trace_ent);	// shared with Nav_Walkable - see there
};

// Why the last stepped walk gave up.  Counted by the link diagnostics so a bad
// result points at a step of the simulation instead of needing a guess.
const float NAVWF_OK      = 0;
const float NAVWF_BLOCKED = 1;	// swept into world / func_wall
const float NAVWF_LEDGE   = 2;	// nothing to land on within NAV_WALK_DROP
const float NAVWF_STEEP   = 3;	// landed on a slope too steep to stand on
const float NAVWF_STUCK   = 4;	// a step made no forward progress
const float NAVWF_SHORT   = 5;	// ran out of steps before arriving
const float NAVWF_HEIGHT  = 6;	// arrived in plan, but on a different floor
float nav_walkfail;

// Rest the hull this far clear of the surface it stands on.  A box whose bottom
// face is exactly coplanar with the floor is a coin-flip for startsolid, and a
// startsolid sweep reports fraction 0 against `world`, which reads as "blocked" -
// so without this every single step fails and the whole test returns FALSE.
const float NAV_WALK_LIFT = 1;

float(vector a, vector b) Nav_WalkableStepped =
{
	nav_walkfail = NAVWF_OK;

	vector up = '0 0 1' * NAV_STEP_HEIGHT;
	vector feet = a;  feet_z = feet_z - NAV_NODE_HEIGHT + NAV_WALK_LIFT;
	vector goal = b;  goal_z = goal_z - NAV_NODE_HEIGHT;

	float i;
	for (i = 0; i < NAV_WALK_MAXSTEPS; i = i + 1)
	{
		// Re-aim every step from where we ACTUALLY are: a sweep that slid along a
		// wall would otherwise keep marching the original heading into it.
		vector flat = goal - feet;  flat_z = 0;
		float togo = vlen(flat);
		if (togo <= NAV_WALK_STEP * 0.5)
			break;					// close enough to call it arrived
		vector dir = flat * (1 / togo);
		float adv = NAV_WALK_STEP;
		if (adv > togo) adv = togo;
		vector was = feet;

		// up, then forward: the lift is what lets it climb a step or a stair tread
		tracebox(feet, NAV_HULL_MINS, NAV_HULL_MAXS, feet + up, MOVE_NOMONSTERS, Nav_TracePass());
		vector high = trace_endpos;		// short if the ceiling is low
		vector want = high + dir * adv;
		tracebox(high, NAV_HULL_MINS, NAV_HULL_MAXS, want, MOVE_NOMONSTERS, Nav_TracePass());
		vector landed = trace_endpos;
		if (trace_fraction < 1)
		{
			if (Nav_HitBlocker())
				{ nav_walkfail = NAVWF_BLOCKED; return FALSE; }
			// Stopped by something GoldSrc treats as passable - a door, a train.
			// Stopping at its face would wedge the walk there forever and burn every
			// remaining step, so continue from the far side and let the floor probe
			// below decide whether there is anywhere to stand.
			landed = want;
		}

		// ...and down.  Falling further than NAV_WALK_DROP is a ledge, not a walk.
		vector floorprobe = landed;
		floorprobe_z = floorprobe_z - (NAV_STEP_HEIGHT + NAV_WALK_LIFT + NAV_WALK_DROP);
		tracebox(landed, NAV_HULL_MINS, NAV_HULL_MAXS, floorprobe, MOVE_NOMONSTERS, world);
		if (trace_fraction >= 1)
			{ nav_walkfail = NAVWF_LEDGE; return FALSE; }	// void under it
		if (!trace_startsolid)
			if (trace_plane_normal_z < 0.7)
				{ nav_walkfail = NAVWF_STEEP; return FALSE; }
		feet = trace_endpos;
		feet_z = feet_z + NAV_WALK_LIFT;

		vector moved = feet - was;  moved_z = 0;
		if (vlen(moved) < 1)
			{ nav_walkfail = NAVWF_STUCK; return FALSE; }	// wedged, not walking
	}

	// Arrived horizontally?  And at roughly the height the destination node claims -
	// otherwise the walk ended up on a different floor that merely lines up in plan.
	vector rem = goal - feet;  rem_z = 0;
	if (vlen(rem) > NAV_WALK_STEP)
		{ nav_walkfail = NAVWF_SHORT; return FALSE; }
	float dz = feet_z - goal_z;
	if (dz > NAV_STEP_HEIGHT + NAV_WALK_LIFT)	{ nav_walkfail = NAVWF_HEIGHT; return FALSE; }
	if (dz < -NAV_STEP_HEIGHT)			{ nav_walkfail = NAVWF_HEIGHT; return FALSE; }
	return TRUE;
};

// ---------------------------------------------------------------------------
// floor continuity along a link
// ---------------------------------------------------------------------------
// The box sweep travels through the AIR from node to node, so it is perfectly
// clear across a pit - there is nothing up there to hit.  Nothing in the link pass
// has ever checked that a monster following the link would have anything to stand
// on.  That hole was survivable while links were capped at 384 units; it is not
// once they are allowed to span a room.
//
// One traceline per sample, rather than the three traceboxes a full simulated step
// costs, because the only question being asked is "is there ground under this".
const float NAV_PROFILE_STEP  = 48;	// sample spacing along the link
const float NAV_PROFILE_MAX   = 48;	// sample cap, so a huge link cannot run away
const float NAV_PROFILE_REACH = 512;	// how far down to look for ground AT ALL
// Biggest floor-height change tolerated between two samples.  A 45-degree ramp -
// the steepest surface Quake lets anything stand on - climbs exactly one sample
// spacing per sample, so the allowance is that plus a step.  Anything beyond it is
// a wall face or a cliff, not terrain a walker follows.
const float NAV_PROFILE_JUMP  = 70;	// NAV_PROFILE_STEP + NAV_STEP_HEIGHT

// Why the last profile failed, for `sv_nav_linkfloor 2`.
const float NAVP_NOFLOOR = 1;
const float NAVP_JUMPUP  = 2;
const float NAVP_JUMPDN  = 3;
float  nav_prof_why;
vector nav_prof_at;
float  nav_prof_prevz, nav_prof_fz;

float(vector a, vector b) Nav_FloorProfile =
{
	nav_prof_why = 0;
	// The early-out is on the FULL 3D length, not the horizontal run.  Keying it on
	// the horizontal distance meant two nodes stacked nearly vertically - a balcony
	// over a floor, say - had a horizontal separation under one sample spacing and
	// so skipped the ground check completely, on exactly the links where "is there
	// anything to walk on between these" matters most.
	float dist = vlen(b - a);
	if (dist <= NAV_PROFILE_STEP)
		return TRUE;				// too short to hide anything

	float n = ceil(dist / NAV_PROFILE_STEP);
	if (n > NAV_PROFILE_MAX)
		n = NAV_PROFILE_MAX;

	// Sample along the chord itself: the box sweep already proved the chord is
	// clear, so every sample starts in open air.  What matters is not how far the
	// ground sits below the chord - a link down a stairwell is legitimately a long
	// way under the straight line between its endpoints - but whether the ground is
	// CONTINUOUS.  Testing proximity to the chord instead threw away real routes:
	// it cost 9 links on hl_c01_a1 and took the largest component from 94 nodes
	// down to 59, because the links it rejected were the ones bridging areas.
	float prevz = a_z - NAV_NODE_HEIGHT;
	float i;
	for (i = 1; i <= n; i = i + 1)
	{
		vector p = a + (b - a) * (i / n);
		vector down = p;
		down_z = down_z - NAV_PROFILE_REACH;
		nav_trace_spent = nav_trace_spent + 1;
		traceline(p, down, MOVE_NOMONSTERS, world);
		nav_prof_at = p; nav_prof_prevz = prevz;
		if (trace_fraction >= 1)
		{
			nav_prof_why = NAVP_NOFLOOR;
			nav_prof_fz = -99999;
			return FALSE;			// no ground under the link at all
		}
		float fz = trace_endpos_z;
		nav_prof_fz = fz;
		float dz = fz - prevz;
		if (dz >  NAV_PROFILE_JUMP)	{ nav_prof_why = NAVP_JUMPUP; return FALSE; }
		if (dz < -NAV_PROFILE_JUMP)	{ nav_prof_why = NAVP_JUMPDN; return FALSE; }
		prevz = fz;
	}
	return TRUE;
};

// Nearest existing node within (rad horiz, vrad vert) of p, or -1.
float(vector p, float rad, float vrad) Nav_FindNear =
{
	float i; vector d;
	for (i = 0; i < nav_count; i = i + 1)
	{
		d = nav_pos[i] - p;
		if (d_z > vrad || d_z < -vrad)
			continue;
		d_z = 0;
		if (vlen(d) <= rad)
			return i;
	}
	return -1;
};

// Append a node; returns its index, or -1 if the cap is hit (logged once).
float(vector p, float isair) Nav_AddNode =
{
	if (nav_count >= NAV_NODE_MAX)
	{
		// CRITICAL: never bump nav_count past NAV_NODE_MAX — the old "log once"
		// hack set it to MAX+1, and every downstream `for (i<nav_count)` loop then
		// read nav_pos[NAV_NODE_MAX] → engine boundcheck SV_Error on load.  Use a
		// separate latch instead.
		if (!nav_cap_logged)
		{
			dprint("^1[nav] node cap reached - increase NAV_NODE_MAX\n");
			nav_cap_logged = TRUE;
		}
		return -1;
	}
	float idx = nav_count;
	nav_pos[idx] = p;
	nav_air[idx] = isair;
	nav_linkcount[idx] = 0;
	nav_visit[idx] = 0;
	nav_count = idx + 1;
	return idx;
};

// Add a one-way link a->b (caller adds the reverse).  Skips dups.
//
// When node a is full this KEEPS THE SHORTEST NAV_LINK_MAX links rather than the
// first NAV_LINK_MAX offered.  That is not a refinement, it is a correctness fix:
// the all-pairs pass walks candidates in node-INDEX order, which has nothing to do
// with proximity, so first-come let a node's slots be eaten by whatever happened to
// be numbered low.  Measured on th_ep1_01, widening the search radius from 384 to
// 1536 under first-come took the graph from 21 components to 97 (93 of them single
// isolated nodes) - widening the search made connectivity strictly worse, because
// every extra candidate was another chance to fill a slot with a far node and
// permanently lock out a near one.
float nav_link_evictions;		// diagnostics: how often the cap actually bit

// Drop a->b if present, compacting the slot list.  Needed because eviction and a
// refused insert both have to be undone on the OTHER side to keep links symmetric.
void(float a, float b) Nav_RemoveLink1 =
{
	if (a < 0 || b < 0)
		return;
	float base = a * NAV_LINK_MAX;
	float n = nav_linkcount[a]; float k;
	for (k = 0; k < n; k = k + 1)
	{
		if (nav_link[base + k] != b)
			continue;
		// swap the last entry into the hole; order carries no meaning here
		nav_link[base + k]      = nav_link[base + n - 1];
		nav_linkdist[base + k]  = nav_linkdist[base + n - 1];
		nav_linkflags[base + k] = nav_linkflags[base + n - 1];
		nav_linkcount[a] = n - 1;
		return;
	}
};

// TRUE if a->b is present once this returns.
float(float a, float b, float dist, float flags) Nav_AddLink1 =
{
	if (a < 0 || b < 0 || a == b)
		return FALSE;
	float base = a * NAV_LINK_MAX;
	float n = nav_linkcount[a];
	float k;
	for (k = 0; k < n; k = k + 1)
		if (nav_link[base + k] == b)
		{
			// Already linked from another pass.  Keep the LEAST restrictive answer:
			// if either direction found a clean route, the edge is clean.
			nav_linkflags[base + k] = nav_linkflags[base + k] & flags;
			return TRUE;
		}
	if (n < NAV_LINK_MAX)
	{
		nav_link[base + n] = b;
		nav_linkdist[base + n] = dist;
		nav_linkflags[base + n] = flags;
		nav_linkcount[a] = n + 1;
		return TRUE;
	}
	// Full: evict the longest link, but only if this one is shorter than it.
	float worst = -1; float worstd = dist;
	for (k = 0; k < NAV_LINK_MAX; k = k + 1)
		if (nav_linkdist[base + k] > worstd)
		{
			worstd = nav_linkdist[base + k];
			worst = k;
		}
	if (worst < 0)
		return FALSE;				// everything already here is shorter
	// Evicting a->c without dropping c->a would leave a one-way edge behind, which
	// is exactly the asymmetry Nav_Link exists to prevent.
	Nav_RemoveLink1(nav_link[base + worst], a);
	nav_link[base + worst] = b;
	nav_linkdist[base + worst] = dist;
	nav_linkflags[base + worst] = flags;
	nav_link_evictions = nav_link_evictions + 1;
	return TRUE;
};

// Symmetric by construction.  The second insert CAN refuse - b may be full with
// nothing longer than this link to give up - and taking that silently would leave
// a one-way edge: a monster walks somewhere and cannot walk back, while
// Nav_ReportComponents (a forward-only flood) still reports the pair as connected
// and hides it.  If the reverse will not fit, the forward one is withdrawn.
void(float a, float b, float flags) Nav_Link =
{
	float d = vlen(nav_pos[b] - nav_pos[a]);
	if (!Nav_AddLink1(a, b, d, flags))
		return;
	if (!Nav_AddLink1(b, a, d, flags))
		Nav_RemoveLink1(a, b);
};

float(float a, float b) Nav_HasLink =
{
	if (a < 0 || b < 0)
		return FALSE;
	float base = a * NAV_LINK_MAX;
	float n = nav_linkcount[a]; float k;
	for (k = 0; k < n; k = k + 1)
		if (nav_link[base + k] == b)
			return TRUE;
	return FALSE;
};

// ---------------------------------------------------------------------------
// info_node / info_node_air map entities (GoldSrc-compatible)
// ---------------------------------------------------------------------------
float nav_dbg_nodrop;		// info_nodes that found no walkable floor beneath them
float nav_dbg_clipvols;		// func_monsterclip volumes kept this map

void() info_node =
{
	self.movetype = MOVETYPE_NONE;
	self.solid    = SOLID_NOT;
	vector p = Nav_FloorDrop(self.origin);
	if (!nav_floor_ok)
	{	// keep it anyway at the placed height + offset (mapper knows best)
		p = self.origin; p_z = p_z + NAV_NODE_HEIGHT;
		nav_dbg_nodrop = nav_dbg_nodrop + 1;
	}
	if (Nav_AddNode(p, FALSE) >= 0)
		nav_have_infonodes = nav_have_infonodes + 1;
	remove(self);
};

void() info_node_air =
{
	self.movetype = MOVETYPE_NONE;
	self.solid    = SOLID_NOT;
	Nav_AddNode(self.origin, TRUE);		// air nodes stay where placed
	remove(self);
};

// ---------------------------------------------------------------------------
// auto-grid: flood-fill walkable space outward from the spawn points
// ---------------------------------------------------------------------------
void(float idx) Nav_Enqueue =
{
	float nt = nav_qtail + 1;
	if (nt >= NAV_QUEUE_MAX) nt = 0;
	if (nt == nav_qhead) return;		// queue full -> drop (graph already huge)
	nav_q[nav_qtail] = idx;
	nav_qtail = nt;
};

float() Nav_QueueEmpty = { return nav_qhead == nav_qtail; };

float() Nav_Dequeue =
{
	float v = nav_q[nav_qhead];
	nav_qhead = nav_qhead + 1;
	if (nav_qhead >= NAV_QUEUE_MAX) nav_qhead = 0;
	return v;
};

// Seed the flood from one spawn-point origin.
void(vector org) Nav_SeedPoint =
{
	vector p = Nav_FloorDrop(org);
	if (!nav_floor_ok)
		return;
	if (Nav_FindNear(p, 48, NAV_STEP_HEIGHT) >= 0)
		return;					// already covered
	float idx = Nav_AddNode(p, FALSE);
	if (idx >= 0)
		Nav_Enqueue(idx);
};

void(string cname) Nav_SeedClass =
{
	entity e;
	for (e = world; (e = find(e, classname, cname)); )
		Nav_SeedPoint(e.origin);
};

void() Nav_SeedFromSpawns =
{
	Nav_SeedClass("info_player_deathmatch");
	Nav_SeedClass("info_player_start");
	Nav_SeedClass("info_player_blue");
	Nav_SeedClass("info_player_red");
	Nav_SeedClass("info_player_terrorist");
	Nav_SeedClass("info_player_counterterrorist");
	Nav_SeedClass("info_player_teamspawn");
};

// Expand one flooded node in the 8 horizontal directions.
void(float idx) Nav_FloodExpand =
{
	float step = cvar("sv_nav_gridstep");
	if (step < 48) step = 96;
	vector base = nav_pos[idx];
	float dx[8] = { 1, -1,  0,  0,  1,  1, -1, -1};
	float dy[8] = { 0,  0,  1, -1,  1, -1,  1, -1};
	float i; vector cand, dropped;
	for (i = 0; i < 8; i = i + 1)
	{
		cand = base;
		cand_x = cand_x + dx[i] * step;
		cand_y = cand_y + dy[i] * step;
		dropped = Nav_FloorDrop(cand);
		if (!nav_floor_ok)
			{ nav_dbg_floor = nav_dbg_floor + 1; continue; }
		float dz = dropped_z - base_z;
		if (dz > NAV_STEP_HEIGHT * 2 || dz < -128)
			{ nav_dbg_dz = nav_dbg_dz + 1; continue; }	// too tall a step up / fell off a cliff
		if (!Nav_Walkable(base, dropped))
			{ nav_dbg_walk = nav_dbg_walk + 1; continue; }
		float ex = Nav_FindNear(dropped, step * 0.6, NAV_STEP_HEIGHT);
		if (ex >= 0)
		{
			Nav_Link(idx, ex, 0);		// already a node here -> just link
			nav_dbg_dedup = nav_dbg_dedup + 1;
			continue;
		}
		float ni = Nav_AddNode(dropped, FALSE);
		if (ni < 0)
			return;				// cap hit
		Nav_Link(idx, ni, 0);
		Nav_Enqueue(ni);
		nav_dbg_add = nav_dbg_add + 1;
	}
};

// ---------------------------------------------------------------------------
// link-pass diagnostics  —  `sv_nav_linkdebug 1`
// ---------------------------------------------------------------------------
// Turned on to answer one question: when an info_node graph shatters into two
// dozen components, WHICH test is throwing the links away?  Every counter below is
// a candidate pair that was geometrically within NAV_LINK_DIST of its source.
//
// The *_alt counters are counterfactuals, evaluated only for pairs the shipping
// test rejected, so one run says not just what is failing but what would fix it:
//   alt_step  - same box sweep, both ends lifted NAV_STEP_HEIGHT first (does a
//               step-up allowance recover it?)
//   alt_los   - a bare traceline between node centres, which is what Half-Life's
//               own CGraph::LinkVisibleNodes uses (is the BOX the problem?)
float navdbg_cand, navdbg_rej_dist, navdbg_rej_air;
float navdbg_ok_clear, navdbg_ok_mover;
float navdbg_rej_world, navdbg_rej_static, navdbg_rej_startsolid, navdbg_rej_floor;
float navdbg_rej_clip;		// links kept but flagged as monsterclip-only
float navdbg_alt_step, navdbg_alt_los, navdbg_alt_walk;
float navdbg_frac_early, navdbg_frac_mid, navdbg_frac_late;
float navdbg_walk_falsepos;	// pairs the stepped walk REJECTS that the sweep accepted
float navdbg_wf_blocked, navdbg_wf_ledge, navdbg_wf_steep;
float navdbg_wf_stuck, navdbg_wf_short, navdbg_wf_height;

void() Nav_TallyWalkFail =
{
	if (nav_walkfail == NAVWF_BLOCKED)	navdbg_wf_blocked = navdbg_wf_blocked + 1;
	else if (nav_walkfail == NAVWF_LEDGE)	navdbg_wf_ledge   = navdbg_wf_ledge + 1;
	else if (nav_walkfail == NAVWF_STEEP)	navdbg_wf_steep   = navdbg_wf_steep + 1;
	else if (nav_walkfail == NAVWF_STUCK)	navdbg_wf_stuck   = navdbg_wf_stuck + 1;
	else if (nav_walkfail == NAVWF_SHORT)	navdbg_wf_short   = navdbg_wf_short + 1;
	else if (nav_walkfail == NAVWF_HEIGHT)	navdbg_wf_height  = navdbg_wf_height + 1;
};

void(vector pa, vector pb) Nav_LinkDebugRejected =
{
	if (nav_walk_startsolid)
		navdbg_rej_startsolid = navdbg_rej_startsolid + 1;

	// where along the sweep did it die?  ~0 means the obstruction is right on top
	// of the source node (a node buried in geometry); ~0.5 means real cover.
	if (nav_walk_frac < 0.05)	navdbg_frac_early = navdbg_frac_early + 1;
	else if (nav_walk_frac < 0.9)	navdbg_frac_mid   = navdbg_frac_mid + 1;
	else				navdbg_frac_late  = navdbg_frac_late + 1;

	vector up = '0 0 1' * NAV_STEP_HEIGHT;
	tracebox(pa + up, '-16 -16 -10', '16 16 40', pb + up, MOVE_NOMONSTERS, world);
	if (trace_fraction >= 1)
		navdbg_alt_step = navdbg_alt_step + 1;

	traceline(pa, pb, MOVE_NOMONSTERS, world);
	if (trace_fraction >= 1)
		navdbg_alt_los = navdbg_alt_los + 1;
	// the stepped-walk counterfactual is tallied by the caller, which already has
	// the result - running it again here would double the cost of a debug build
};

void() Nav_LinkDebugReset =
{
	navdbg_cand = 0; navdbg_rej_dist = 0; navdbg_rej_air = 0;
	navdbg_ok_clear = 0; navdbg_ok_mover = 0;
	navdbg_rej_world = 0; navdbg_rej_static = 0; navdbg_rej_startsolid = 0; navdbg_rej_floor = 0;
	navdbg_rej_clip = 0;
	navdbg_alt_step = 0; navdbg_alt_los = 0; navdbg_alt_walk = 0;
	navdbg_frac_early = 0; navdbg_frac_mid = 0; navdbg_frac_late = 0;
	navdbg_walk_falsepos = 0;
	navdbg_wf_blocked = 0; navdbg_wf_ledge = 0; navdbg_wf_steep = 0;
	navdbg_wf_stuck = 0; navdbg_wf_short = 0; navdbg_wf_height = 0;
};

void() Nav_LinkDebugReport =
{
	if (!cvar("sv_nav_linkdebug"))
		return;
	dprint(sprintf("[navlink] cand=%g  accepted clear=%g mover=%g\n",
	               navdbg_cand, navdbg_ok_clear, navdbg_ok_mover));
	dprint(sprintf("[navlink] rejected world=%g static=%g nofloor=%g (startsolid=%g)\n",
	               navdbg_rej_world, navdbg_rej_static, navdbg_rej_floor, navdbg_rej_startsolid));
	dprint(sprintf("[navlink] monsterclip-only links kept+flagged: %g\n", navdbg_rej_clip));
	dprint(sprintf("[navlink] blocked at frac <0.05=%g 0.05-0.9=%g >0.9=%g\n",
	               navdbg_frac_early, navdbg_frac_mid, navdbg_frac_late));
	dprint(sprintf("[navlink] would recover: +stepup=%g  bare-LOS=%g  stepped-walk=%g\n",
	               navdbg_alt_step, navdbg_alt_los, navdbg_alt_walk));
	dprint(sprintf("[navlink] stepped-walk would DROP %g of the %g the sweep accepted\n",
	               navdbg_walk_falsepos, navdbg_ok_clear + navdbg_ok_mover));
	dprint(sprintf("[navlink] walkfail blocked=%g ledge=%g steep=%g\n",
	               navdbg_wf_blocked, navdbg_wf_ledge, navdbg_wf_steep));
	dprint(sprintf("[navlink] walkfail stuck=%g short=%g height=%g\n",
	               navdbg_wf_stuck, navdbg_wf_short, navdbg_wf_height));
};

// ---------------------------------------------------------------------------
// all-pairs link pass (for sparse info_node maps) — frame-spread
// ---------------------------------------------------------------------------
// At NAV_LINK_BUDGET=24 source nodes, a debug build measured 0.5s spread over five
// frames - ~100ms server hitches, during which no entity updates are sent and no
// sound advances.  The visible symptom is doors that have not appeared yet and
// audio looping, which reads exactly like an entity bug and is not one.  Hence
// nav_trace_spent (declared with the builder state) and NAV_TRACE_BUDGET.
float nav_linksweep_r;		// >0: diagnostic radius override (see Nav_LinkSweep)

// ---------------------------------------------------------------------------
// per-node candidate shortlist
// ---------------------------------------------------------------------------
// The link pass used to trace-test EVERY node within NAV_LINK_DIST, which made the
// search radius and the build cost the same dial - and that dial had to be turned
// down to 384 to stay affordable, which is what shattered the graph.  Shortlisting
// the K nearest first decouples them: cost becomes K traces per node no matter how
// far the search reaches, so the radius can be dropped entirely.
//
// Measured (geometry only, hl_c01_a1 / th_ep1_01): K of 8, 16 and 24 give BYTE-FOR-
// BYTE the same component counts at every radius - the connectivity-critical edges
// are always among the nearest few - while the radius takes th_ep1_01 from 21
// components at 384 to 1 at unlimited, for 1616 traces instead of 1204.
const float NAV_CAND_MAX = 12;
float nav_cand_idx[NAV_CAND_MAX];
float nav_cand_d[NAV_CAND_MAX];
float nav_cand_n;

// Insertion into a K-slot ascending-distance shortlist.
void(float idx, float d) Nav_CandInsert =
{
	if (nav_cand_n >= NAV_CAND_MAX)
		if (d >= nav_cand_d[NAV_CAND_MAX - 1])
			return;				// further than everything already held
	float pos = nav_cand_n;
	if (pos >= NAV_CAND_MAX)
		pos = NAV_CAND_MAX - 1;			// drop the current worst
	while (pos > 0)
	{
		if (nav_cand_d[pos - 1] <= d)
			break;
		nav_cand_idx[pos] = nav_cand_idx[pos - 1];
		nav_cand_d[pos]   = nav_cand_d[pos - 1];
		pos = pos - 1;
	}
	nav_cand_idx[pos] = idx;
	nav_cand_d[pos]   = d;
	if (nav_cand_n < NAV_CAND_MAX)
		nav_cand_n = nav_cand_n + 1;
};

void(float a) Nav_LinkNode =
{
	float dbg = cvar("sv_nav_linkdebug");
	float usewalk = cvar("sv_nav_linkwalk");
	float usefloor = cvar("sv_nav_linkfloor");
	float lim = nav_linksweep_r;
	if (lim <= 0) lim = cvar("sv_nav_linkdist");
	if (lim < 64) lim = NAV_LINK_DIST;
	// The floor probe samples at most NAV_PROFILE_MAX points and stretches its
	// spacing to cover whatever it is given, so a link longer than STEP*MAX gets
	// checked at a coarser resolution than intended - silently.  Rather than let a
	// cvar widen the radius past what the gate can actually inspect, clamp it.
	if (usefloor)
		if (lim > NAV_PROFILE_STEP * NAV_PROFILE_MAX)
			lim = NAV_PROFILE_STEP * NAV_PROFILE_MAX;

	float b; vector pa = nav_pos[a];

	// Pass 1: shortlist the NAV_CAND_MAX nearest, no traces at all.
	nav_cand_n = 0;
	for (b = 0; b < nav_count; b = b + 1)
	{
		if (b == a) continue;
		if (nav_air[a] != nav_air[b]) continue;		// air links only to air
		float cd = vlen(nav_pos[b] - pa);
		if (cd > lim) continue;
		Nav_CandInsert(b, cd);
	}

	// Pass 2: trace-test the shortlist, nearest first.
	float ci;
	for (ci = 0; ci < nav_cand_n; ci = ci + 1)
	{
		b = nav_cand_idx[ci];
		float d = nav_cand_d[ci];

		// Links are made symmetric, so if b already reached us in its own pass the
		// answer is known and the trace would be paid twice for one edge.
		if (Nav_HasLink(a, b))
			continue;

		// Height gate.  The flood builder has always had one (Nav_FloodExpand's dz
		// test); this pass never did, so nothing stopped it linking two nodes
		// stacked nearly vertically - the box sweep can run straight up an open
		// shaft and the floor probe used to skip short horizontal runs entirely.
		// Anything steeper than a 45-degree climb is not a walk, with a step's
		// worth of slack so ordinary stairs and lips still pass.
		vector delta = nav_pos[b] - pa;
		float dz = delta_z;
		delta_z = 0;
		float run = vlen(delta);
		if (dz > run + NAV_STEP_HEIGHT)		continue;
		if (dz < -(run + NAV_WALK_DROP))	continue;
		if (dbg) navdbg_cand = navdbg_cand + 1;

		if (nav_air[a])				// air: straight LOS, no floor walk
		{
			nav_trace_spent = nav_trace_spent + 1;
			traceline(pa, nav_pos[b], MOVE_NOMONSTERS, nav_probe);
			if (trace_fraction < 1 && trace_ent == world) continue;
			Nav_Link(a, b, 0);
			continue;
		}

		nav_trace_spent = nav_trace_spent + 1;
		float swept = Nav_Walkable(pa, nav_pos[b]);
		float reason = nav_walk_reason;		// Nav_WalkableStepped clobbers it

		// The straight sweep is the cheap test.  A monster does not travel in a
		// straight line through the air though - it gets a fresh step-up allowance
		// at every footfall - so anything the sweep rejects gets a second chance
		// from a simulated walk before the link is thrown away.
		float walked = -1;			// -1 = not evaluated
		if (!swept)
			if (usewalk || dbg)
			{
				// A simulated walk is ~3 traces per 24 units, so charge it as such
				// or the budget below is meaningless.
				nav_trace_spent = nav_trace_spent + (d / NAV_WALK_STEP) * 3;
				walked = Nav_WalkableStepped(pa, nav_pos[b]);
			}

		if (dbg)
		{
			if (swept)
			{
				if (reason == NAVW_MOVER)	navdbg_ok_mover = navdbg_ok_mover + 1;
				else				navdbg_ok_clear = navdbg_ok_clear + 1;
				// A test that silently LOSES links the current one keeps would trade
				// one connectivity problem for another, so count those too.
				nav_trace_spent = nav_trace_spent + (d / NAV_WALK_STEP) * 3;
				if (!Nav_WalkableStepped(pa, nav_pos[b]))
				{
					navdbg_walk_falsepos = navdbg_walk_falsepos + 1;
					Nav_TallyWalkFail();
				}
			}
			else
			{
				if (reason == NAVW_WORLD)	navdbg_rej_world = navdbg_rej_world + 1;
				else
				{
					navdbg_rej_static = navdbg_rej_static + 1;
					// Name the blocker.  A count alone cannot tell "correctly
					// rejected by a wall" from "wrongly rejected by something that
					// should never have been in the blocking set", and this whole
					// classification was just found to be wrong once already.
					if (dbg >= 2)
						dprint(sprintf("[navblock] %g->%g len=%g by %s btype=%g model=%s\n",
						               a, b, d, nav_walk_blocker.classname,
						               nav_walk_blocker.brush_type,
						               nav_walk_blocker.model));
				}
				if (walked > 0)			navdbg_alt_walk = navdbg_alt_walk + 1;
				else				Nav_TallyWalkFail();
				Nav_LinkDebugRejected(pa, nav_pos[b]);
			}
		}

		// A link stopped ONLY by a func_monsterclip is not dead - it is off-limits
		// to monsters and perfectly fine for everyone else.  Re-run the sweep with
		// the clip volumes invisible (passedict `world` carries no MONSTERCLIP bit);
		// if that clears, keep the link and flag it instead of throwing it away.
		float lflags = 0;
		if (!swept)
			if (nav_walk_reason == NAVW_STATIC || reason == NAVW_STATIC)
				if (nav_walk_blocker.skin == CONTENT_MONSTERCLIP)
				{
					nav_trace_spent = nav_trace_spent + 1;
					nav_probe_bypass = TRUE;
					swept = Nav_Walkable(pa, nav_pos[b]);
					nav_probe_bypass = FALSE;
					if (swept)
					{
						lflags = NAVLF_MONSTERCLIP;
						navdbg_rej_clip = navdbg_rej_clip + 1;
					}
				}

		if (!swept)
			if (!usewalk || walked <= 0)
				continue;

		// Cleared the air; now make sure there is ground the whole way.
		if (usefloor)
			if (!Nav_FloorProfile(pa, nav_pos[b]))
			{
				navdbg_rej_floor = navdbg_rej_floor + 1;
				if (usefloor >= 2)
				{
					dprint(sprintf("[navfloor] %g->%g len=%g why=%g at %v\n",
					               a, b, d, nav_prof_why, nav_prof_at));
					dprint(sprintf("[navfloor]    node %v .. %v  prevz=%g fz=%g\n",
					               pa, nav_pos[b], nav_prof_prevz, nav_prof_fz));
				}
				continue;
			}

		// Both directions here, not one: with a per-node shortlist "b is among a's
		// nearest" does not imply "a is among b's", so relying on b's own pass to
		// add the reverse would leave one-way edges wherever the node density is
		// uneven - a monster could walk somewhere and not be able to walk back.
		Nav_Link(a, b, lflags);
	}
};

// ---------------------------------------------------------------------------
// A* pathfinding
// ---------------------------------------------------------------------------
float(float a, float b) Nav_Heur = { return vlen(nav_pos[b] - nav_pos[a]); };

// ---------------------------------------------------------------------------
// binary min-heap over nav_fscore  (open set for Nav_FindPath)
// ---------------------------------------------------------------------------
// Every mutator keeps nav_heappos in lockstep with nav_heap, because the
// decrease-key path and the "is this node already open" test both read it.

void(float slot) Nav_HeapSiftUp =
{
	float n = nav_heap[slot];
	float f = nav_fscore[n];
	while (slot > 1)
	{
		float parent = floor(slot * 0.5);
		float pn = nav_heap[parent];
		if (nav_fscore[pn] <= f)
			break;
		nav_heap[slot]  = pn;
		nav_heappos[pn] = slot;
		slot = parent;
	}
	nav_heap[slot] = n;
	nav_heappos[n] = slot;
};

void(float slot) Nav_HeapSiftDown =
{
	float n = nav_heap[slot];
	float f = nav_fscore[n];
	while (1)
	{
		float child = slot + slot;
		if (child > nav_heapn)
			break;
		// pick the smaller of the two children
		if (child < nav_heapn)
			if (nav_fscore[nav_heap[child + 1]] < nav_fscore[nav_heap[child]])
				child = child + 1;
		float cn = nav_heap[child];
		if (nav_fscore[cn] >= f)
			break;
		nav_heap[slot]  = cn;
		nav_heappos[cn] = slot;
		slot = child;
	}
	nav_heap[slot] = n;
	nav_heappos[n] = slot;
};

void(float node) Nav_HeapPush =
{
	if (node < 0)			return;
	if (node >= NAV_NODE_MAX)	return;
	if (nav_heapn >= NAV_NODE_MAX)	return;	// one slot per node, so unreachable
	nav_heapn = nav_heapn + 1;
	nav_heap[nav_heapn] = node;
	nav_heappos[node]   = nav_heapn;
	Nav_HeapSiftUp(nav_heapn);
};

// Returns the lowest-f node and removes it, or -1 when the open set is empty.
float() Nav_HeapPop =
{
	if (nav_heapn <= 0)
		return -1;
	float top = nav_heap[1];
	nav_heappos[top] = 0;

	float last = nav_heap[nav_heapn];
	nav_heapn = nav_heapn - 1;
	if (nav_heapn > 0)
	{
		nav_heap[1]      = last;
		nav_heappos[last] = 1;
		Nav_HeapSiftDown(1);
	}
	return top;
};

// O(open-set), not O(nav_count): only entries actually in the heap need clearing.
void() Nav_HeapClear =
{
	float i;
	for (i = 1; i <= nav_heapn; i = i + 1)
		nav_heappos[nav_heap[i]] = 0;
	nav_heapn = 0;
};

// ---------------------------------------------------------------------------
// spatial index over nav_pos  (B1b)
// ---------------------------------------------------------------------------
// Nav_NearestNode used to sweep every node and fire a traceline on each distance
// improvement, twice per Nav_FindPath.  The flood builder emits nodes in BFS order
// outward from the spawns, so index order is CORRELATED with distance and the
// improvement count sits near its worst case rather than the ~ln(V) a random order
// would give.  With 50+ monsters coming that is the wrong shape entirely.
//
// The graph is immutable once the build reaches NAVB_READY, so a flat CSR bucket
// list built once is enough - no insert, no delete, no rebalance.
//
// Z is deliberately not bucketed: nodes are floor-anchored, so a multi-storey cell
// simply holds a few more entries and the distance compare sorts them out.  Adding
// a third axis would cost memory to save almost nothing.
const float NAV_GRID_DIM   = 32;
const float NAV_GRID_CELLS = 1024;		// NAV_GRID_DIM * NAV_GRID_DIM
float  nav_grid_start[NAV_GRID_CELLS + 1];	// CSR: cell c occupies [start[c], start[c+1])
float  nav_grid_item[NAV_NODE_MAX];		// node indices, cell-major
vector nav_grid_org;				// world-space min corner of the grid
float  nav_grid_cell;				// cell edge length
float  nav_grid_ready;

float(vector p) Nav_GridCell =
{
	float cx = floor((p_x - nav_grid_org_x) / nav_grid_cell);
	float cy = floor((p_y - nav_grid_org_y) / nav_grid_cell);
	if (cx < 0) cx = 0;
	if (cy < 0) cy = 0;
	if (cx > NAV_GRID_DIM - 1) cx = NAV_GRID_DIM - 1;
	if (cy > NAV_GRID_DIM - 1) cy = NAV_GRID_DIM - 1;
	return cy * NAV_GRID_DIM + cx;
};

float(float v) Nav_GridClamp =
{
	if (v < 0)			return 0;
	if (v > NAV_GRID_DIM - 1)	return NAV_GRID_DIM - 1;
	return v;
};

void() Nav_GridBuild =
{
	nav_grid_ready = FALSE;
	if (nav_count <= 0)
		return;

	vector mn = nav_pos[0], mx = nav_pos[0];
	float i;
	for (i = 1; i < nav_count; i = i + 1)
	{
		vector p = nav_pos[i];
		if (p_x < mn_x) mn_x = p_x;
		if (p_y < mn_y) mn_y = p_y;
		if (p_x > mx_x) mx_x = p_x;
		if (p_y > mx_y) mx_y = p_y;
	}
	nav_grid_org = mn;
	float ext = mx_x - mn_x;
	if (mx_y - mn_y > ext) ext = mx_y - mn_y;
	nav_grid_cell = ext / NAV_GRID_DIM;
	if (nav_grid_cell < 1)
		nav_grid_cell = 1;			// degenerate / single-point graphs

	// counting sort into CSR.  Count into start[c+1], prefix-sum, then scatter
	// using start[c] as a destructive cursor and shift back - no scratch array.
	float c;
	for (c = 0; c <= NAV_GRID_CELLS; c = c + 1)
		nav_grid_start[c] = 0;
	for (i = 0; i < nav_count; i = i + 1)
	{
		c = Nav_GridCell(nav_pos[i]);
		nav_grid_start[c + 1] = nav_grid_start[c + 1] + 1;
	}
	for (c = 0; c < NAV_GRID_CELLS; c = c + 1)
		nav_grid_start[c + 1] = nav_grid_start[c + 1] + nav_grid_start[c];
	for (i = 0; i < nav_count; i = i + 1)
	{
		c = Nav_GridCell(nav_pos[i]);
		nav_grid_item[nav_grid_start[c]] = i;
		nav_grid_start[c] = nav_grid_start[c] + 1;
	}
	// undo the destructive cursor: start[] is now the END of each cell, so shift
	for (c = NAV_GRID_CELLS; c > 0; c = c - 1)
		nav_grid_start[c] = nav_grid_start[c - 1];
	nav_grid_start[0] = 0;
	nav_grid_ready = TRUE;
};

// Nearest node with clear LOS from org (so the walker can actually reach it).
//
// Semantics are unchanged from the old linear sweep - "the nearest non-air node
// this point can see" - and the exhaustive scan is still there as a fallback, so
// a query whose answer is further away than the shortlist reaches still finds it.
const float NAV_NEAR_MAX = 16;
float nav_near_idx[NAV_NEAR_MAX];
float nav_near_d[NAV_NEAR_MAX];
float nav_near_n;

void(float idx, float d) Nav_NearInsert =
{
	if (nav_near_n >= NAV_NEAR_MAX)
		if (d >= nav_near_d[NAV_NEAR_MAX - 1])
			return;
	float pos = nav_near_n;
	if (pos >= NAV_NEAR_MAX)
		pos = NAV_NEAR_MAX - 1;
	while (pos > 0)
	{
		if (nav_near_d[pos - 1] <= d)
			break;
		nav_near_idx[pos] = nav_near_idx[pos - 1];
		nav_near_d[pos]   = nav_near_d[pos - 1];
		pos = pos - 1;
	}
	nav_near_idx[pos] = idx;
	nav_near_d[pos]   = d;
	if (nav_near_n < NAV_NEAR_MAX)
		nav_near_n = nav_near_n + 1;
};

float(vector org) Nav_NearestNodeLinear =
{
	float i, best = -1; float bestd = 1000000000;
	vector eye = org; eye_z = eye_z + 24;
	for (i = 0; i < nav_count; i = i + 1)
	{
		if (nav_air[i]) continue;
		float d = vlen(nav_pos[i] - org);
		if (d >= bestd) continue;
		traceline(eye, nav_pos[i], MOVE_NOMONSTERS, world);
		if (trace_fraction < 1 && trace_ent == world) continue;
		bestd = d; best = i;
	}
	return best;
};

float(vector org) Nav_NearestNode =
{
	if (!nav_grid_ready)
		return Nav_NearestNodeLinear(org);

	vector eye = org; eye_z = eye_z + 24;
	float qx = Nav_GridClamp(floor((org_x - nav_grid_org_x) / nav_grid_cell));
	float qy = Nav_GridClamp(floor((org_y - nav_grid_org_y) / nav_grid_cell));

	nav_near_n = 0;
	float ring;
	for (ring = 0; ring < NAV_GRID_DIM; ring = ring + 1)
	{
		// Once the shortlist is full and its worst entry is closer than anything
		// this ring could contain, no further ring can improve on it.
		if (nav_near_n >= NAV_NEAR_MAX)
			if (nav_near_d[nav_near_n - 1] <= (ring - 1) * nav_grid_cell)
				break;

		float gx, gy;
		for (gy = qy - ring; gy <= qy + ring; gy = gy + 1)
		{
			if (gy < 0) continue;
			if (gy > NAV_GRID_DIM - 1) continue;
			for (gx = qx - ring; gx <= qx + ring; gx = gx + 1)
			{
				if (gx < 0) continue;
				if (gx > NAV_GRID_DIM - 1) continue;
				// only the ring's perimeter; the interior was done already
				if (ring > 0)
					if (gx > qx - ring)
						if (gx < qx + ring)
							if (gy > qy - ring)
								if (gy < qy + ring)
									continue;
				float c = gy * NAV_GRID_DIM + gx;
				float s = nav_grid_start[c], e = nav_grid_start[c + 1];
				float k;
				for (k = s; k < e; k = k + 1)
				{
					float n = nav_grid_item[k];
					if (n < 0) continue;
					if (n >= nav_count) continue;
					if (nav_air[n]) continue;
					Nav_NearInsert(n, vlen(nav_pos[n] - org));
				}
			}
		}
	}

	// Trace the shortlist nearest-first and take the first that can be seen.
	float i;
	for (i = 0; i < nav_near_n; i = i + 1)
	{
		traceline(eye, nav_pos[nav_near_idx[i]], MOVE_NOMONSTERS, world);
		if (trace_fraction < 1 && trace_ent == world) continue;
		return nav_near_idx[i];
	}
	// Nothing in the shortlist was visible.  Rare, and the honest answer may still
	// be out there, so pay for the exhaustive scan rather than report failure.
	return Nav_NearestNodeLinear(org);
};

// A* between two NODE INDICES.  Split out of Nav_FindPath so the self-test can
// drive the search directly without going through Nav_NearestNode's traces.
// Fills nav_result[0..nav_result_len-1] (start->goal). Returns TRUE on success.
float(float start, float goal) Nav_FindPathNodes =
{
	nav_result_len = 0;
	if (start < 0)			return FALSE;
	if (goal  < 0)			return FALSE;
	if (start >= nav_count)		return FALSE;
	if (goal  >= nav_count)		return FALSE;
	if (start == goal)
	{
		nav_result[0] = start; nav_result_len = 1;
		return TRUE;
	}

	nav_stamp = nav_stamp + 1;
	Nav_HeapClear();			// previous search may have aborted with entries still in

	nav_g[start] = 0;
	nav_fscore[start] = Nav_Heur(start, goal);
	nav_from[start] = -1;
	nav_visit[start] = nav_stamp;
	Nav_HeapPush(start);

	float guard = 0; float guardmax = nav_count * 6 + 64;
	float cur;
	while (1)
	{
		cur = Nav_HeapPop();		// lowest f, O(log n)
		if (cur < 0)
			return FALSE;			// open set empty -> no path
		if (cur == goal)
			break;

		float lc = nav_linkcount[cur]; float k;
		for (k = 0; k < lc; k = k + 1)
		{
			float nb = nav_link[cur * NAV_LINK_MAX + k];
			// Bounds-check the neighbour before it indexes four parallel arrays.
			// Cheap, and the flood/all-pairs builders are the only writers of
			// nav_link - a truncated build must not be able to corrupt a search.
			if (nb < 0)		continue;
			if (nb >= nav_count)	continue;
			// whatever this searcher declared it will not cross
			if (nav_linkflags[cur * NAV_LINK_MAX + k] & nav_path_avoid)
				continue;

			float tg = nav_g[cur] + nav_linkdist[cur * NAV_LINK_MAX + k];

			if (nav_visit[nb] != nav_stamp)
			{
				// First time this search has seen the node.
				nav_from[nb]   = cur;
				nav_g[nb]      = tg;
				nav_fscore[nb] = tg + Nav_Heur(nb, goal);
				nav_visit[nb]  = nav_stamp;
				Nav_HeapPush(nb);
			}
			else if (tg < nav_g[nb])
			{
				// Cheaper route found.  Note f only ever DECREASES here (h is
				// unchanged for a given node), so sift-up is the correct repair.
				nav_from[nb]   = cur;
				nav_g[nb]      = tg;
				nav_fscore[nb] = tg + Nav_Heur(nb, goal);
				if (nav_heappos[nb] > 0)
					Nav_HeapSiftUp(nav_heappos[nb]);	// decrease-key in place
				else
					Nav_HeapPush(nb);			// already closed: re-open it
			}
		}
		guard = guard + 1;
		if (guard > guardmax)
			return FALSE;
	}

	// reconstruct goal->start, then reverse into nav_result
	float n = 0; float c = goal;
	while (c >= 0 && n < NAV_PATH_MAX)
	{
		nav_recon[n] = c; n = n + 1;
		c = nav_from[c];
	}
	float j;
	nav_result_len = n;
	for (j = 0; j < n; j = j + 1)
		nav_result[j] = nav_recon[n - 1 - j];
	return TRUE;
};

// A* from the node nearest 'fromorg' to the node nearest 'goalorg'.
// Fills nav_result[0..nav_result_len-1] (start->goal). Returns TRUE on success.
float(vector fromorg, vector goalorg) Nav_FindPath =
{
	nav_result_len = 0;
	if (nav_state != NAVB_READY || nav_count <= 0)
		return FALSE;
	float start = Nav_NearestNode(fromorg);
	float goal  = Nav_NearestNode(goalorg);
	if (start < 0 || goal < 0)
		return FALSE;
	return Nav_FindPathNodes(start, goal);
};

// ---------------------------------------------------------------------------
// path request queue + shared cache  (B1c)
// ---------------------------------------------------------------------------
// Nav_FindPath is synchronous, and with 50+ monsters a wave that all decide to
// repath on the same frame would run 50 full A* searches back to back inside one
// StartFrame.  Requests are queued instead and serviced against a per-frame cap.
//
// Dedup is via .nav_req_slot: a requester that asks again overwrites its own entry
// rather than appending, so the queue can never hold more entries than there are
// requesters no matter how hard they spam it.
//
// The cache key INCLUDES the avoid mask.  A path computed for a bot (mask 0) may
// cross a func_monsterclip link and is simply wrong to hand to a monster, so
// keying on (start, goal) alone would serve poisoned results across searcher
// types.  It also carries nav_build_serial, because node indices mean nothing
// after a rebuild.
const float NAV_REQ_MAX     = 128;
const float NAV_CACHE_SLOTS = 8;

entity navreq_ent[NAV_REQ_MAX];
vector navreq_goal[NAV_REQ_MAX];
float  navreq_avoid[NAV_REQ_MAX];
float  navreq_head, navreq_tail, navreq_pending, navreq_dropped;

// A slot caches a GOAL, not a path.  navcache_next maps node -> the next node to
// step to on an optimal route to that goal, so one completed search populates an
// answer for every node ALONG it, not just for the start it was asked about.
//
// That is the difference between the cache working and not working for the shape
// of traffic it exists for: a squadmaker wave converges on the players, so fifty
// monsters share one goal but have fifty different starts.  Keyed on
// (start, goal) every one of them is a miss; keyed on goal alone, the first few
// searches lay down a next-hop field the rest of the wave lands on.
//
// Merging routes from several searches into one field cannot create a cycle: every
// entry came from an optimal path to the goal and every edge weight is a strictly
// positive vlen, so following next-hops strictly decreases the true remaining
// cost.  The walk is still bounded, because a corrupt field must degrade rather
// than hang the server.
float  navcache_goal[NAV_CACHE_SLOTS];
float  navcache_avoid[NAV_CACHE_SLOTS];
float  navcache_serial[NAV_CACHE_SLOTS];
float  navcache_stamp[NAV_CACHE_SLOTS];		// LRU: last use
float  navcache_next[NAV_CACHE_SLOTS * NAV_NODE_MAX];
float  navcache_clock, navcache_hits, navcache_misses;
float  navcache_nopath;		// no route exists - NOT a cache failure, counted apart
float  nav_searches_this_frame;			// budget adherence check

void() Nav_QueueReset =
{
	float i;
	for (i = 0; i < NAV_REQ_MAX; i = i + 1)
		navreq_ent[i] = world;
	navreq_head = 0; navreq_tail = 0; navreq_pending = 0; navreq_dropped = 0;
	for (i = 0; i < NAV_CACHE_SLOTS; i = i + 1)
	{
		navcache_serial[i] = -1;	// never matches a live nav_build_serial
		navcache_stamp[i] = 0;
	}
	navcache_clock = 0; navcache_hits = 0; navcache_misses = 0; navcache_nopath = 0;
	nav_searches_this_frame = 0;
};

// Queue a request.  TRUE if it is now pending (or already was).
float(entity e, vector goalpos, float avoid) Nav_RequestPath =
{
	if (e == world)			return FALSE;
	if (nav_state != NAVB_READY)	return FALSE;

	if (e.nav_req_slot > 0)
	{
		float s = e.nav_req_slot - 1;
		if (s >= 0)
			if (s < NAV_REQ_MAX)
				if (navreq_ent[s] == e)
				{
					navreq_goal[s]  = goalpos;	// refresh in place
					navreq_avoid[s] = avoid;
					return TRUE;
				}
		e.nav_req_slot = 0;		// stale handle
	}

	float nt = navreq_tail + 1;
	if (nt >= NAV_REQ_MAX) nt = 0;
	if (nt == navreq_head)
	{
		navreq_dropped = navreq_dropped + 1;
		return FALSE;			// full: caller degrades to direct movement
	}
	navreq_ent[navreq_tail]   = e;
	navreq_goal[navreq_tail]  = goalpos;
	navreq_avoid[navreq_tail] = avoid;
	e.nav_req_slot = navreq_tail + 1;
	navreq_tail = nt;
	navreq_pending = navreq_pending + 1;
	return TRUE;
};

float(float goal, float avoid) Nav_CacheFind =
{
	float i;
	for (i = 0; i < NAV_CACHE_SLOTS; i = i + 1)
	{
		if (navcache_serial[i] != nav_build_serial)	continue;
		if (navcache_goal[i]   != goal)			continue;
		if (navcache_avoid[i]  != avoid)		continue;
		return i;
	}
	return -1;
};

// Wipe a slot's next-hop field.  -1 means "no route known from this node".
void(float slot, float goal, float avoid) Nav_CacheClaim =
{
	float base = slot * NAV_NODE_MAX; float i;
	for (i = 0; i < NAV_NODE_MAX; i = i + 1)
		navcache_next[base + i] = -1;
	navcache_goal[slot]   = goal;
	navcache_avoid[slot]  = avoid;
	navcache_serial[slot] = nav_build_serial;
};

// Fold the path currently in nav_result into slot's next-hop field.
void(float slot) Nav_CacheAbsorb =
{
	float base = slot * NAV_NODE_MAX; float i;
	for (i = 0; i + 1 < nav_result_len; i = i + 1)
	{
		float n = nav_result[i];
		if (n < 0) continue;
		if (n >= NAV_NODE_MAX) continue;
		navcache_next[base + n] = nav_result[i + 1];
	}
	if (nav_result_len > 0)
	{
		float g = nav_result[nav_result_len - 1];
		if (g >= 0)
			if (g < NAV_NODE_MAX)
				navcache_next[base + g] = g;	// goal points at itself: terminator
	}
};

// Rebuild a path from start by following next-hops.  FALSE if start has no entry.
float(float slot, float start) Nav_CacheMaterialize =
{
	float base = slot * NAV_NODE_MAX;
	if (start < 0)			return FALSE;
	if (start >= NAV_NODE_MAX)	return FALSE;
	if (navcache_next[base + start] < 0)
		return FALSE;

	nav_result_len = 0;
	float cur = start; float n = 0;
	while (n < NAV_PATH_MAX)
	{
		nav_result[n] = cur;
		n = n + 1;
		float nx = navcache_next[base + cur];
		if (nx == cur)
			break;				// reached the goal
		if (nx < 0)			return FALSE;	// field truncated
		if (nx >= nav_count)		return FALSE;
		cur = nx;
	}
	nav_result_len = n;
	return n > 0;
};

float() Nav_CacheVictim =
{
	float i, worst = 0, worstt = navcache_stamp[0];
	for (i = 1; i < NAV_CACHE_SLOTS; i = i + 1)
	{
		if (navcache_serial[i] != nav_build_serial)
			return i;			// free/stale slot beats evicting a live one
		if (navcache_stamp[i] < worstt)
			{ worstt = navcache_stamp[i]; worst = i; }
	}
	return worst;
};

// Run one request: resolve endpoints, consult the cache, search on a miss, then
// copy the result into the requester's path slot.
void(entity e, vector goalpos, float avoid) Nav_ServiceOne =
{
	float start = Nav_NearestNode(e.origin);
	float goal  = Nav_NearestNode(goalpos);
	if (start < 0 || goal < 0)
	{
		e.ai_path_len = 0;
		return;
	}

	float prev_avoid = nav_path_avoid;
	nav_path_avoid = avoid;

	float slot = Nav_CacheFind(goal, avoid);
	float served = FALSE;
	if (slot >= 0)
		if (Nav_CacheMaterialize(slot, start))
		{
			navcache_hits = navcache_hits + 1;
			served = TRUE;
		}

	if (!served)
	{
		navcache_misses = navcache_misses + 1;
		nav_searches_this_frame = nav_searches_this_frame + 1;
		if (!Nav_FindPathNodes(start, goal))
		{
			// Unreachable, which is a property of the GRAPH, not a cache failure.
			// Counting it as a miss turns the hit rate into a measure of
			// connectivity and hides how the cache is actually performing.
			navcache_misses = navcache_misses - 1;
			navcache_nopath = navcache_nopath + 1;
			nav_path_avoid = prev_avoid;
			e.ai_path_len = 0;
			return;
		}
		// Claim a slot only if this goal has none yet - otherwise ADD to the field
		// already there, which is the whole point of caching by goal.
		if (slot < 0)
		{
			slot = Nav_CacheVictim();
			Nav_CacheClaim(slot, goal, avoid);
		}
		Nav_CacheAbsorb(slot);
	}

	navcache_clock = navcache_clock + 1;
	navcache_stamp[slot] = navcache_clock;
	nav_path_avoid = prev_avoid;
	// nav_result is a single global with no reentrancy, so it is copied out here
	// and not left for the caller to fetch on some later frame.
	Nav_PathSlot_Store(e);
};

// Called once per SV_StartFrame.
void() Nav_ServiceRequests =
{
	nav_searches_this_frame = 0;
	if (nav_state != NAVB_READY)
		return;
	float budget = cvar("sv_nav_budget");
	if (budget <= 0) budget = 2;

	while (budget > 0)
	{
		if (navreq_head == navreq_tail)
			break;
		float s = navreq_head;
		navreq_head = navreq_head + 1;
		if (navreq_head >= NAV_REQ_MAX) navreq_head = 0;

		entity e = navreq_ent[s];
		navreq_ent[s] = world;
		if (e == world)
			continue;			// requester died before it was serviced
		if (e.nav_req_slot == s + 1)
			e.nav_req_slot = 0;
		navreq_pending = navreq_pending - 1;

		Nav_ServiceOne(e, navreq_goal[s], navreq_avoid[s]);
		budget = budget - 1;
	}
};

// ---------------------------------------------------------------------------
// self-test  —  `sv_nav_selftest <n>`, runs n random queries at map load
// ---------------------------------------------------------------------------
// Swapping the open set from a linear scan to a binary heap is the kind of change
// that compiles cleanly and silently returns slightly-wrong paths, so it gets a
// real differential test rather than a smoke test.
//
// Nav_RefPathCost is the ORIGINAL linear-scan A*, kept verbatim in spirit, writing
// to its own scratch arrays so it cannot disturb the live search. Optimal path cost
// is unique even when the path itself is not (ties break differently between the
// two open-set implementations), so COST is the right thing to compare - comparing
// node sequences would produce false failures.

float  navtst_g[NAV_NODE_MAX];
float  navtst_f[NAV_NODE_MAX];
float  navtst_from[NAV_NODE_MAX];
float  navtst_visit[NAV_NODE_MAX];
float  navtst_open[NAV_NODE_MAX];
float  navtst_stamp;

// Returns total path cost, or -1 for "no path".
float(float start, float goal) Nav_RefPathCost =
{
	if (start < 0)			return -1;
	if (goal  < 0)			return -1;
	if (start >= nav_count)		return -1;
	if (goal  >= nav_count)		return -1;
	if (start == goal)		return 0;

	navtst_stamp = navtst_stamp + 1;
	navtst_g[start] = 0;
	navtst_f[start] = Nav_Heur(start, goal);
	navtst_from[start] = -1;
	navtst_visit[start] = navtst_stamp;
	navtst_open[start]  = navtst_stamp;

	float guard = 0; float guardmax = nav_count * 6 + 64;
	float cur;
	while (1)
	{
		float i; cur = -1; float bestf = 1000000000;
		for (i = 0; i < nav_count; i = i + 1)
			if (navtst_open[i] == navtst_stamp)
				if (navtst_f[i] < bestf)
				{ bestf = navtst_f[i]; cur = i; }
		if (cur < 0)		return -1;
		if (cur == goal)	break;
		navtst_open[cur] = 0;

		float lc = nav_linkcount[cur]; float k;
		for (k = 0; k < lc; k = k + 1)
		{
			float nb = nav_link[cur * NAV_LINK_MAX + k];
			if (nb < 0)		continue;
			if (nb >= nav_count)	continue;
			// same rule as the live search, or the differential test compares two
			// searches over different graphs and its agreement means nothing
			if (nav_linkflags[cur * NAV_LINK_MAX + k] & nav_path_avoid)
				continue;
			float tg = navtst_g[cur] + nav_linkdist[cur * NAV_LINK_MAX + k];
			float fresh = FALSE;
			if (navtst_visit[nb] != navtst_stamp)	fresh = TRUE;
			else if (tg < navtst_g[nb])		fresh = TRUE;
			if (fresh)
			{
				navtst_from[nb]  = cur;
				navtst_g[nb]     = tg;
				navtst_f[nb]     = tg + Nav_Heur(nb, goal);
				navtst_visit[nb] = navtst_stamp;
				navtst_open[nb]  = navtst_stamp;
			}
		}
		guard = guard + 1;
		if (guard > guardmax)	return -1;
	}
	return navtst_g[goal];
};

// Walk nav_result and confirm it is a REAL path: right endpoints, and every
// consecutive pair genuinely linked in the graph.  Returns the summed edge cost,
// or -1 if the path is malformed.
float(float start, float goal) Nav_ValidateResult =
{
	if (nav_result_len <= 0)			return -1;
	if (nav_result[0] != start)			return -1;
	if (nav_result[nav_result_len - 1] != goal)	return -1;

	float total = 0;
	float i;
	for (i = 0; i + 1 < nav_result_len; i = i + 1)
	{
		float a = nav_result[i];
		float b = nav_result[i + 1];
		if (a < 0)		return -1;
		if (a >= nav_count)	return -1;

		float found = FALSE;
		float lc = nav_linkcount[a]; float k;
		for (k = 0; k < lc; k = k + 1)
		{
			if (nav_link[a * NAV_LINK_MAX + k] != b)
				continue;
			total = total + nav_linkdist[a * NAV_LINK_MAX + k];
			found = TRUE;
			break;
		}
		if (!found)
			return -1;		// consecutive nodes are not actually connected
	}
	return total;
};

// Count connected components of the link graph, and report the largest.
//
// A high "no path" rate in the self-test is not necessarily a search bug - it is
// usually the graph being in many disconnected pieces, which matters enormously for
// monsters: an NPC whose target sits in another component can never path to it, and
// the AI will look broken while the pathfinder is behaving perfectly.  Measure it so
// the two failure modes are never confused.
//
// Reuses navtst_visit as scratch (the self-test's reference search is not running
// while this executes) and the builder's own BFS ring buffer.
void() Nav_ReportComponents =
{
	navtst_stamp = navtst_stamp + 1;
	float mystamp = navtst_stamp;

	float comps = 0, biggest = 0, isolated = 0;
	float seed;
	for (seed = 0; seed < nav_count; seed = seed + 1)
	{
		if (navtst_visit[seed] == mystamp)
			continue;

		// flood this component
		comps = comps + 1;
		float size = 0;
		nav_qhead = 0; nav_qtail = 0;
		navtst_visit[seed] = mystamp;
		Nav_Enqueue(seed);
		while (!Nav_QueueEmpty())
		{
			float cur = Nav_Dequeue();
			size = size + 1;
			float lc = nav_linkcount[cur]; float k;
			for (k = 0; k < lc; k = k + 1)
			{
				float nb = nav_link[cur * NAV_LINK_MAX + k];
				if (nb < 0)			continue;
				if (nb >= nav_count)		continue;
				// honour the avoid mask: "how connected is this graph" has a
				// different answer for a monster than for a bot
				if (nav_linkflags[cur * NAV_LINK_MAX + k] & nav_path_avoid)
					continue;
				if (navtst_visit[nb] == mystamp)	continue;
				navtst_visit[nb] = mystamp;
				Nav_Enqueue(nb);
			}
		}
		if (size > biggest)	biggest = size;
		if (size <= 1)		isolated = isolated + 1;
	}
	nav_qhead = 0; nav_qtail = 0;

	float pct = 0;
	if (nav_count > 0)
		pct = (biggest * 100) / nav_count;
	dprint(sprintf("[navtest] components=%g largest=%g (%g%% of %g nodes) isolated=%g\n",
	               comps, biggest, pct, nav_count, isolated));
};

// Every link must exist in both directions.  A one-way edge is invisible to
// Nav_ReportComponents (it floods forward only, so it counts the pair as
// connected) and shows up in play as a monster that walks somewhere and then
// cannot walk back - which reads as an AI bug, not a graph bug.
void() Nav_CheckSymmetry =
{
	float oneway = 0, total = 0;
	float a;
	for (a = 0; a < nav_count; a = a + 1)
	{
		float lc = nav_linkcount[a]; float k;
		for (k = 0; k < lc; k = k + 1)
		{
			float b = nav_link[a * NAV_LINK_MAX + k];
			if (b < 0)		continue;
			if (b >= nav_count)	continue;
			total = total + 1;
			if (Nav_HasLink(b, a))
				continue;
			oneway = oneway + 1;
			if (oneway <= 3)
				dprint(sprintf("[navtest] ONE-WAY link %g->%g (no reverse)\n", a, b));
		}
	}
	dprint(sprintf("[navtest] link symmetry: %g links, one-way=%g\n", total, oneway));
};

// Drive the request queue with a synthetic burst.  The queue exists to survive
// many simultaneous requesters and there are none yet, so the load has to be
// manufactured or the budget and the cache are both untested guesses.
void() Nav_QueueSelfTest =
{
	if (nav_count < 2)
		return;
	float bad = 0;
	float N = 50;				// a squadmaker-sized wave
	entity req[50];
	float i;

	// Everyone heads for the same goal - that is the realistic shape (a wave
	// converging on the players) and it is what the cache should exploit.
	//
	// The goal has to be a node MOST starts can actually reach, or the run measures
	// graph fragmentation instead of the cache: picking nav_pos[0] on th_ep1_01 put
	// the goal in a small component, every search failed, and the cache reported a
	// flat zero hits that had nothing to do with the cache.  Pick the node with the
	// most other nodes reachable from it, out of a cheap sample.
	float bestgoal = 0, bestreach = -1;
	float t;
	for (t = 0; t < 12; t = t + 1)
	{
		float cand = floor(random() * nav_count);
		if (cand >= nav_count) cand = nav_count - 1;
		// count how many of a small probe set can reach it
		float reach = 0, pr;
		for (pr = 0; pr < 12; pr = pr + 1)
		{
			float from = floor(random() * nav_count);
			if (from >= nav_count) from = nav_count - 1;
			if (Nav_FindPathNodes(from, cand))
				reach = reach + 1;
		}
		if (reach > bestreach)
			{ bestreach = reach; bestgoal = cand; }
	}
	vector goalpos = nav_pos[bestgoal];

	float hits0 = navcache_hits, miss0 = navcache_misses, nopath0 = navcache_nopath;
	for (i = 0; i < N; i = i + 1)
	{
		req[i] = spawn();
		float n = floor(random() * nav_count);
		if (n >= nav_count) n = nav_count - 1;
		setorigin(req[i], nav_pos[n]);
		if (!Nav_RequestPath(req[i], goalpos, 0))
			{ dprint(sprintf("[navqueue] request %g refused\n", i)); bad = bad + 1; }
	}
	if (navreq_pending != N)
		{ dprint(sprintf("[navqueue] pending=%g want %g\n", navreq_pending, N)); bad = bad + 1; }

	// Re-request for everyone: dedup must overwrite, not append.
	for (i = 0; i < N; i = i + 1)
		Nav_RequestPath(req[i], goalpos, 0);
	if (navreq_pending != N)
		{ dprint(sprintf("[navqueue] dedup failed, pending=%g want %g\n",
		                 navreq_pending, N)); bad = bad + 1; }

	// Drain, checking the per-frame cap is actually respected each time round.
	float budget = cvar("sv_nav_budget");
	if (budget <= 0) budget = 2;
	float frames = 0, worst = 0;
	while (navreq_pending > 0 && frames < 500)
	{
		Nav_ServiceRequests();
		if (nav_searches_this_frame > worst)
			worst = nav_searches_this_frame;
		if (nav_searches_this_frame > budget)
			{ dprint(sprintf("[navqueue] BUDGET EXCEEDED: %g > %g\n",
			                 nav_searches_this_frame, budget)); bad = bad + 1; }
		frames = frames + 1;
	}
	if (navreq_pending != 0)
		{ dprint(sprintf("[navqueue] %g still pending after %g frames\n",
		                 navreq_pending, frames)); bad = bad + 1; }

	// Every delivered path must be a REAL path.  A next-hop field merged from
	// several searches is precisely where a wrong-but-plausible route would hide:
	// it would still look like a list of node indices, just one with a jump in it.
	float withpath = 0, badpath = 0;
	for (i = 0; i < N; i = i + 1)
	{
		if (req[i].ai_path_len <= 0)
			continue;
		withpath = withpath + 1;
		float step, prev = -1, brk = 0;
		for (step = 0; step < req[i].ai_path_len; step = step + 1)
		{
			float nd = Nav_PathSlot_Node(req[i], step);
			if (nd < 0 || nd >= nav_count)
				{ brk = 1; break; }
			if (prev >= 0)
				if (!Nav_HasLink(prev, nd))
					{ brk = 2; break; }
			prev = nd;
		}
		if (brk)
		{
			badpath = badpath + 1;
			if (badpath <= 3)
				dprint(sprintf("[navqueue] BROKEN PATH for req %g (reason %g, len %g)\n",
				               i, brk, req[i].ai_path_len));
		}
	}
	if (badpath > 0)
		bad = bad + badpath;

	float hits = navcache_hits - hits0, miss = navcache_misses - miss0;
	float nopath = navcache_nopath - nopath0;
	dprint(sprintf("[navqueue] paths delivered=%g broken=%g\n", withpath, badpath));
	dprint(sprintf("[navqueue] %g requests drained in %g frames, peak %g searches/frame\n",
	               N, frames, worst));
	dprint(sprintf("[navqueue] reachable=%g of which cache-served=%g searched=%g\n",
	               hits + miss, hits, miss));
	dprint(sprintf("[navqueue] unreachable=%g dropped=%g BAD=%g\n",
	               nopath, navreq_dropped, bad));

	for (i = 0; i < N; i = i + 1)
		Nav_PathSlot_Release(req[i]);
	for (i = 0; i < N; i = i + 1)
		remove(req[i]);
};

// Exercise the path pool.  Its failure mode is not a crash - it is two entities
// silently holding the same slot and overwriting each other's waypoints - so
// "it compiled" proves nothing and this checks the invariants directly.
void() Nav_PathPoolSelfTest =
{
	float bad = 0;
	float seen[NAV_PSLOT_MAX];
	entity holder[NAV_PSLOT_MAX];
	float i;

	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
		seen[i] = 0;

	// 1. drain the pool, and confirm no slot is ever issued twice
	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
	{
		holder[i] = spawn();
		float s = Nav_PathSlot_Acquire(holder[i]);
		if (s < 0)
			{ dprint(sprintf("[navpool] acquire %g failed early\n", i)); bad = bad + 1; break; }
		if (seen[s])
			{ dprint(sprintf("[navpool] slot %g ISSUED TWICE\n", s)); bad = bad + 1; }
		seen[s] = 1;
	}
	if (nav_pslot_freen != 0)
		{ dprint(sprintf("[navpool] drained pool has freen=%g, want 0\n", nav_pslot_freen)); bad = bad + 1; }

	// 2. one past the end must refuse, not scribble
	entity extra = spawn();
	float starve_before = nav_pslot_starved;
	if (Nav_PathSlot_Acquire(extra) >= 0)
		{ dprint("[navpool] exhausted pool still handed out a slot\n"); bad = bad + 1; }
	if (nav_pslot_starved != starve_before + 1)
		{ dprint("[navpool] starvation not counted\n"); bad = bad + 1; }
	remove(extra);

	// 3. re-acquiring is idempotent, not a second allocation
	float again = Nav_PathSlot_Acquire(holder[0]);
	if (again != holder[0].ai_pathslot - 1)
		{ dprint("[navpool] re-acquire returned a different slot\n"); bad = bad + 1; }

	// 4. release everything, then release AGAIN - the double release is the one
	//    thing that can corrupt the free list, so it is tested explicitly
	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
		Nav_PathSlot_Release(holder[i]);
	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
		Nav_PathSlot_Release(holder[i]);
	if (nav_pslot_freen != NAV_PSLOT_MAX)
		{ dprint(sprintf("[navpool] after release freen=%g, want %g\n",
		                 nav_pslot_freen, NAV_PSLOT_MAX)); bad = bad + 1; }
	if (nav_pslot_inuse != 0)
		{ dprint(sprintf("[navpool] after release inuse=%g, want 0\n", nav_pslot_inuse)); bad = bad + 1; }

	// 5. the restored free list must still be a permutation - no duplicates
	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
		seen[i] = 0;
	for (i = 0; i < nav_pslot_freen; i = i + 1)
	{
		float s = nav_pslot_free[i];
		if (s < 0 || s >= NAV_PSLOT_MAX)
			{ dprint(sprintf("[navpool] free list holds %g\n", s)); bad = bad + 1; continue; }
		if (seen[s])
			{ dprint(sprintf("[navpool] slot %g DUPLICATED in free list\n", s)); bad = bad + 1; }
		seen[s] = 1;
	}

	for (i = 0; i < NAV_PSLOT_MAX; i = i + 1)
		remove(holder[i]);

	dprint(sprintf("[navpool] pool selftest BAD=%g (freen=%g inuse=%g)\n",
	               bad, nav_pslot_freen, nav_pslot_inuse));
};

void() Nav_SelfTest =
{
	float trials = cvar("sv_nav_selftest");
	if (trials <= 0)
		return;
	// After the gate: this spawns and removes NAV_PSLOT_MAX+1 entities, which is
	// not something to do on every ordinary map load.
	Nav_PathPoolSelfTest();
	Nav_CheckSymmetry();
	Nav_QueueSelfTest();
	if (nav_state != NAVB_READY)
	{
		dprint("[navtest] graph not ready, skipping\n");
		return;
	}
	if (nav_count < 2)
	{
		dprint("[navtest] fewer than 2 nodes, skipping\n");
		return;
	}

	float ok = 0, bad = 0, nopath = 0, malformed = 0, mismatch = 0;
	float worst = 0;
	float t;
	for (t = 0; t < trials; t = t + 1)
	{
		float a = floor(random() * nav_count);
		float b = floor(random() * nav_count);
		if (a >= nav_count)	a = nav_count - 1;
		if (b >= nav_count)	b = nav_count - 1;

		float refcost = Nav_RefPathCost(a, b);
		float got     = Nav_FindPathNodes(a, b);

		if (refcost < 0)
		{
			// Reference says unreachable; the heap must agree.
			if (got)
			{
				dprint(sprintf("[navtest] MISMATCH %g->%g: ref=nopath heap=path\n", a, b));
				bad = bad + 1;
			}
			else
				nopath = nopath + 1;
			continue;
		}

		if (!got)
		{
			dprint(sprintf("[navtest] MISMATCH %g->%g: ref=%g heap=nopath\n", a, b, refcost));
			bad = bad + 1;
			continue;
		}

		float mycost = Nav_ValidateResult(a, b);
		if (mycost < 0)
		{
			dprint(sprintf("[navtest] MALFORMED path %g->%g (len=%g)\n", a, b, nav_result_len));
			malformed = malformed + 1;
			bad = bad + 1;
			continue;
		}

		// Same optimum, allowing for float accumulation order.
		float diff = fabs(mycost - refcost);
		if (diff > worst)
			worst = diff;
		if (diff > 0.5)
		{
			dprint(sprintf("[navtest] COST MISMATCH %g->%g: ref=%g heap=%g\n", a, b, refcost, mycost));
			mismatch = mismatch + 1;
			bad = bad + 1;
			continue;
		}
		ok = ok + 1;
	}

	// Split across two prints: fteqcc caps varargs at 8 parameters.
	dprint(sprintf("[navtest] nodes=%g trials=%g ok=%g nopath=%g\n",
	               nav_count, trials, ok, nopath));
	dprint(sprintf("[navtest] BAD=%g (malformed=%g costmismatch=%g) worstdiff=%g\n",
	               bad, malformed, mismatch, worst));
	// Nav_PrintStats already reported components; a high nopath count above is read
	// against that figure, not against a second copy of it.

	// The spatial index replaced an exhaustive scan, which is exactly the kind of
	// swap that compiles clean and quietly returns a DIFFERENT nearest node.  Both
	// must agree on every sample or the graph lookup is lying.
	float g;
	float gridbad = 0, gridsame = 0;
	for (g = 0; g < trials; g = g + 1)
	{
		// sample real node positions, jittered - that is where queries land
		float seed = floor(random() * nav_count);
		if (seed >= nav_count) seed = nav_count - 1;
		vector q = nav_pos[seed];
		q_x = q_x + (random() - 0.5) * 256;
		q_y = q_y + (random() - 0.5) * 256;

		float viagrid = Nav_NearestNode(q);
		float vialin  = Nav_NearestNodeLinear(q);
		if (viagrid == vialin)
			{ gridsame = gridsame + 1; continue; }
		// A tie at equal distance is legitimate - only a genuinely WORSE answer is
		// a bug, so compare the distances rather than the indices.
		float dg = 1000000000, dl = 1000000000;
		if (viagrid >= 0) dg = vlen(nav_pos[viagrid] - q);
		if (vialin  >= 0) dl = vlen(nav_pos[vialin]  - q);
		if (dg <= dl + 0.5)
			{ gridsame = gridsame + 1; continue; }
		gridbad = gridbad + 1;
		if (gridbad <= 3)
			dprint(sprintf("[navtest] GRID MISMATCH at %v: grid=%g (%g) linear=%g (%g)\n",
			               q, viagrid, dg, vialin, dl));
	}
	dprint(sprintf("[navtest] nearest-node grid vs linear: agree=%g BAD=%g\n",
	               gridsame, gridbad));
};

// ---------------------------------------------------------------------------
// link-radius sweep  —  `sv_nav_linksweep 1`
// ---------------------------------------------------------------------------
// Rebuilds the link set at a series of radii inside ONE map load and reports the
// connectivity each produces.  Doing this by relaunching the game per radius meant
// a window on the user's screen per measurement, and the wide radii hitch the
// server hard enough to look like a bug in something else entirely.
float nav_sweep_idx;
float nav_sweep_radii[6] = { 384, 768, 1024, 1536, 3072, 99999 };

void() Nav_SweepReport =
{
	float i, links = 0;
	for (i = 0; i < nav_count; i = i + 1)
		links = links + nav_linkcount[i];
	dprint(sprintf("^3[navsweep] R=%g links=%g evict=%g nofloor=%g walk=%g floor=%g\n",
	               nav_linksweep_r, links, nav_link_evictions, navdbg_rej_floor,
	               cvar("sv_nav_linkwalk"), cvar("sv_nav_linkfloor")));
	Nav_ReportComponents();
};

// TRUE if the sweep restarted the link pass for another radius.
// Index 1..6 are the measured radii; 7 is a final rebuild at whatever the server is
// really configured for, so a diagnostic run never LEAVES the graph at 1536.
float() Nav_LinkSweepAdvance =
{
	if (!cvar("sv_nav_linksweep"))
		return FALSE;
	if (nav_sweep_idx > 0)
		if (nav_sweep_idx <= 6)
			Nav_SweepReport();		// report the pass that just finished
	if (nav_sweep_idx == 7)
	{
		nav_sweep_idx = 0;			// final rebuild done
		return FALSE;
	}
	if (nav_sweep_idx >= 6)
	{
		nav_linksweep_r = 0;			// hand the configured radius back
		nav_sweep_idx = 7;
	}
	else
	{
		nav_linksweep_r = nav_sweep_radii[nav_sweep_idx];
		nav_sweep_idx = nav_sweep_idx + 1;
	}
	float i;
	for (i = 0; i < nav_count; i = i + 1)
		nav_linkcount[i] = 0;
	nav_link_evictions = 0;
	nav_link_cursor = 0;
	// Every rewire of the link set invalidates any path held elsewhere, exactly as
	// a rebuild does.  Nothing caches paths across frames yet, but the path cache
	// and the monster path pool both key their staleness check on this serial, so
	// bumping it here is what stops this diagnostic silently handing them a path
	// through links that no longer exist.
	nav_build_serial = nav_build_serial + 1;
	Nav_LinkDebugReset();
	return TRUE;
};

// ---------------------------------------------------------------------------
// builder lifecycle
// ---------------------------------------------------------------------------
void() Nav_Reset =
{
	nav_count = 0;
	nav_cap_logged = 0;
	nav_have_infonodes = 0;
	nav_qhead = 0; nav_qtail = 0;
	nav_link_cursor = 0;
	nav_state = NAVB_IDLE;
	nav_build_serial = nav_build_serial + 1;	// invalidate any streamed nav-debug graph

	// nav_stamp deliberately NOT reset.
	//
	// It used to be zeroed here, which was a cross-map corruption bug: the per-node
	// scratch arrays (nav_visit / nav_g / nav_from) are stamped rather than cleared,
	// so zeroing the counter made the next map's first search (stamp 1) collide with
	// leftover stamp-1 marks from the PREVIOUS map.  A* would then treat a node it
	// had never reached as already visited and reconstruct a path through a stale
	// nav_from chain - on a graph whose node indices now mean something else
	// entirely.  Maps reload constantly, so this was reachable in normal play.
	//
	// Letting it increase monotonically costs nothing: at one search per frame at
	// 64 Hz it needs over 8 months of continuous uptime to reach 2^24, where float
	// integer exactness ends.
	//
	// The heap needs a real clear, though - nav_heappos is a position index, not a
	// stamp, so a search interrupted by a map change would otherwise leave stale
	// slots behind.  One pass at map load is free.
	Nav_HeapClear();
	float hp;
	for (hp = 0; hp < NAV_NODE_MAX; hp = hp + 1)
		nav_heappos[hp] = 0;
	nav_dbg_floor = 0; nav_dbg_dz = 0; nav_dbg_walk = 0; nav_dbg_dedup = 0; nav_dbg_add = 0;
	nav_dbg_lastcount = 0;
	nav_dbg_nodrop = 0;
	nav_dbg_clipvols = 0;
	nav_link_evictions = 0;
	nav_build_start = time;
	nav_sweep_idx = 0;
	nav_linksweep_r = 0;
	nav_path_avoid = 0;
	nav_probe_bypass = 0;
	nav_grid_ready = 0;
	nav_near_n = 0;
	// Rebuilt from scratch, not repaired: a map change clears every entity without
	// any release running, so surviving .ai_pathslot values are meaningless.
	Nav_PathPool_Init();
	Nav_QueueReset();

	// Fresh every map: see the note on nav_probe.  No remove() of the old one -
	// the engine already cleared the edict list, so the stale handle would point at
	// whatever now occupies that slot.
	nav_probe = spawn();
	nav_probe.classname = "nav_probe";
	nav_probe.solid     = SOLID_NOT;
	nav_probe.movetype  = MOVETYPE_NONE;
	nav_probe.hitcontentsmaski = CONTENTBITS_BOXSOLID | CONTENTBIT_MONSTERCLIP;

	Nav_LinkDebugReset();
};

void() Nav_PrintStats =
{
	float i, links = 0;
	for (i = 0; i < nav_count; i = i + 1)
		links = links + nav_linkcount[i];
	dprint(sprintf("^5[nav] nodes=%g links=%g infonodes=%g state=%g\n",
		nav_count, links, nav_have_infonodes, nav_state));
	dprint(sprintf("^5[nav] flood reject: floor=%g dz=%g wall=%g dedup=%g add=%g\n",
		nav_dbg_floor, nav_dbg_dz, nav_dbg_walk, nav_dbg_dedup, nav_dbg_add));
	dprint(sprintf("^5[nav] build took %gs, link-slot evictions=%g\n",
		time - nav_build_start, nav_link_evictions));
	dprint(sprintf("^5[nav] info_nodes with no floor beneath: %g\n", nav_dbg_nodrop));
	dprint(sprintf("^5[nav] func_monsterclip volumes: %g\n", nav_dbg_clipvols));
	dprint(sprintf("^5[nav] path pool: %g/%g free, inuse=%g starved=%g\n",
		nav_pslot_freen, NAV_PSLOT_MAX, nav_pslot_inuse, nav_pslot_starved));
	Nav_LinkDebugReport();
	// Unconditional (it's a dprint, so developer-gated anyway): connectivity is the
	// number that decides whether monsters can reach anything, and it must not be
	// hidden behind the self-test cvar.
	Nav_ReportComponents();

	// Same graph as a MONSTER sees it.  Reporting only the unrestricted number
	// would hide the whole point of func_monsterclip - the mapper's restriction is
	// invisible unless it is measured separately.
	if (navdbg_rej_clip > 0)
	{
		nav_path_avoid = NAVLF_MONSTERCLIP;
		dprint("^5[nav] ...as a monster sees it (monsterclip honoured):\n");
		Nav_ReportComponents();
		nav_path_avoid = 0;
	}
};

// Called every SV_StartFrame.  Kicks off + advances the incremental build.
void() Nav_Tick =
{
	float budget;

	if (nav_state == NAVB_READY)
		return;

	if (nav_state == NAVB_IDLE)
	{
		nav_build_start = time;
		if (nav_have_infonodes >= NAV_MIN_INFONODES)
		{
			// enough hand-placed info_nodes -> link them (all-pairs)
			nav_link_cursor = 0;
			nav_state = NAVB_LINK;
		}
		else
		{
			// few/no info_nodes -> auto-grid from spawns
			Nav_SeedFromSpawns();
			dprint(sprintf("^5[nav] seeds=%g\n", nav_count));
			nav_state = NAVB_FLOOD;
		}
		return;
	}

	if (nav_state == NAVB_FLOOD)
	{
		budget = NAV_FLOOD_BUDGET;
		while (budget > 0 && !Nav_QueueEmpty())
		{
			Nav_FloodExpand(Nav_Dequeue());
			budget = budget - 1;
		}
		if (Nav_QueueEmpty())
		{
			nav_state = NAVB_READY;
			Nav_GridBuild();	// graph is immutable from here
			Nav_PrintStats();
			Nav_SelfTest();		// sv_nav_selftest <n>: differential A* check
		}
		return;
	}

	if (nav_state == NAVB_LINK)
	{
		// Two limits, because there are two costs.  NAV_LINK_BUDGET bounds the
		// per-node shortlist scan, which is O(nav_count) and happens even when
		// every candidate is already linked and no trace is spent at all.
		// NAV_TRACE_BUDGET cuts in earlier when the nodes are expensive - the
		// debug and simulated-walk paths can spend hundreds of traces on one node,
		// and that is what turns a build into a visible server hitch.
		nav_trace_spent = 0;
		budget = NAV_LINK_BUDGET;
		while (nav_link_cursor < nav_count)
		{
			Nav_LinkNode(nav_link_cursor);
			nav_link_cursor = nav_link_cursor + 1;
			budget = budget - 1;
			if (budget <= 0)
				break;
			if (nav_trace_spent >= NAV_TRACE_BUDGET)
				break;
		}
		if (nav_link_cursor >= nav_count)
		{
			if (Nav_LinkSweepAdvance())
				return;		// diagnostic sweep wants another radius
			nav_state = NAVB_READY;
			Nav_GridBuild();	// graph is immutable from here
			Nav_PrintStats();
			Nav_SelfTest();		// sv_nav_selftest <n>: differential A* check
		}
		return;
	}
};
