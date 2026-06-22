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
//    static brush ents (func_wall), but movable brushes (func_door/func_train,
//    MOVETYPE_PUSH) and non-solids are treated as passable.
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
const float NAV_LINK_DIST   = 384;	// max link length for the info_node all-pairs pass
const float NAV_FLOOD_BUDGET = 150;	// flood pops processed per frame (one-time map build)
const float NAV_LINK_BUDGET  = 24;	// link source-nodes processed per frame

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

// --- A* scratch (stamped so we never clear per search) ---
float  nav_g[NAV_NODE_MAX];
float  nav_fscore[NAV_NODE_MAX];
float  nav_from[NAV_NODE_MAX];
float  nav_visit[NAV_NODE_MAX];
float  nav_inopen[NAV_NODE_MAX];
float  nav_stamp;
float  nav_recon[NAV_PATH_MAX];

// --- path result (start -> goal node indices) ---
float  nav_result[NAV_PATH_MAX];
float  nav_result_len;

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

// Can a player-sized box travel between two node points unobstructed?
// World + static brush ents block; movable brushes / non-solids pass (GoldSrc).
float(vector a, vector b) Nav_Walkable =
{
	tracebox(a, '-16 -16 -10', '16 16 40', b, MOVE_NOMONSTERS, world);
	if (trace_fraction >= 1)
		return TRUE;				// clear
	if (trace_ent == world)
		return FALSE;				// world geometry blocks
	if (trace_ent.solid == SOLID_BSP && trace_ent.movetype != MOVETYPE_PUSH)
		return FALSE;				// static brush ent (func_wall) blocks
	return TRUE;					// door / mover / other -> passable
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

// Add a one-way link a->b (caller adds the reverse).  Skips dups + overflow.
void(float a, float b, float dist) Nav_AddLink1 =
{
	if (a < 0 || b < 0 || a == b)
		return;
	float n = nav_linkcount[a];
	if (n >= NAV_LINK_MAX)
		return;
	float k;
	for (k = 0; k < n; k = k + 1)
		if (nav_link[a * NAV_LINK_MAX + k] == b)
			return;					// already linked
	nav_link[a * NAV_LINK_MAX + n] = b;
	nav_linkdist[a * NAV_LINK_MAX + n] = dist;
	nav_linkcount[a] = n + 1;
};

void(float a, float b) Nav_Link =
{
	float d = vlen(nav_pos[b] - nav_pos[a]);
	Nav_AddLink1(a, b, d);
	Nav_AddLink1(b, a, d);
};

// ---------------------------------------------------------------------------
// info_node / info_node_air map entities (GoldSrc-compatible)
// ---------------------------------------------------------------------------
void() info_node =
{
	self.movetype = MOVETYPE_NONE;
	self.solid    = SOLID_NOT;
	vector p = Nav_FloorDrop(self.origin);
	if (!nav_floor_ok)
	{	// keep it anyway at the placed height + offset (mapper knows best)
		p = self.origin; p_z = p_z + NAV_NODE_HEIGHT;
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
			Nav_Link(idx, ex);		// already a node here -> just link
			nav_dbg_dedup = nav_dbg_dedup + 1;
			continue;
		}
		float ni = Nav_AddNode(dropped, FALSE);
		if (ni < 0)
			return;				// cap hit
		Nav_Link(idx, ni);
		Nav_Enqueue(ni);
		nav_dbg_add = nav_dbg_add + 1;
	}
};

// ---------------------------------------------------------------------------
// all-pairs link pass (for sparse info_node maps) — frame-spread
// ---------------------------------------------------------------------------
void(float a) Nav_LinkNode =
{
	float b; vector pa = nav_pos[a];
	for (b = 0; b < nav_count; b = b + 1)
	{
		if (b == a) continue;
		if (nav_air[a] != nav_air[b]) continue;		// air links only to air
		float d = vlen(nav_pos[b] - pa);
		if (d > NAV_LINK_DIST) continue;
		if (nav_air[a])				// air: straight LOS, no floor walk
		{
			traceline(pa, nav_pos[b], MOVE_NOMONSTERS, world);
			if (trace_fraction < 1 && trace_ent == world) continue;
		}
		else if (!Nav_Walkable(pa, nav_pos[b]))
			continue;
		Nav_AddLink1(a, b, d);			// reverse handled when b is the source
	}
};

// ---------------------------------------------------------------------------
// A* pathfinding
// ---------------------------------------------------------------------------
float(float a, float b) Nav_Heur = { return vlen(nav_pos[b] - nav_pos[a]); };

// Nearest node with clear LOS from org (so the bot can actually reach it).
float(vector org) Nav_NearestNode =
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
	if (start == goal)
	{
		nav_result[0] = start; nav_result_len = 1;
		return TRUE;
	}

	nav_stamp = nav_stamp + 1;
	nav_g[start] = 0;
	nav_fscore[start] = Nav_Heur(start, goal);
	nav_from[start] = -1;
	nav_visit[start] = nav_stamp;
	nav_inopen[start] = nav_stamp;

	float guard = 0; float guardmax = nav_count * 6 + 64;
	float cur;
	while (1)
	{
		// pop the open node with the lowest f (linear scan)
		float i; cur = -1; float bestf = 1000000000;
		for (i = 0; i < nav_count; i = i + 1)
			if (nav_inopen[i] == nav_stamp && nav_fscore[i] < bestf)
			{ bestf = nav_fscore[i]; cur = i; }
		if (cur < 0)
			return FALSE;			// open set empty -> no path
		if (cur == goal)
			break;
		nav_inopen[cur] = 0;			// move out of open

		float lc = nav_linkcount[cur]; float k;
		for (k = 0; k < lc; k = k + 1)
		{
			float nb = nav_link[cur * NAV_LINK_MAX + k];
			float tg = nav_g[cur] + nav_linkdist[cur * NAV_LINK_MAX + k];
			if (nav_visit[nb] != nav_stamp || tg < nav_g[nb])
			{
				nav_from[nb] = cur;
				nav_g[nb] = tg;
				nav_fscore[nb] = tg + Nav_Heur(nb, goal);
				nav_visit[nb] = nav_stamp;
				nav_inopen[nb] = nav_stamp;
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
	nav_stamp = 0;
	nav_dbg_floor = 0; nav_dbg_dz = 0; nav_dbg_walk = 0; nav_dbg_dedup = 0; nav_dbg_add = 0;
	nav_dbg_lastcount = 0;
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
};

// Called every SV_StartFrame.  Kicks off + advances the incremental build.
void() Nav_Tick =
{
	float budget;

	if (nav_state == NAVB_READY)
		return;

	if (nav_state == NAVB_IDLE)
	{
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
			Nav_PrintStats();
		}
		return;
	}

	if (nav_state == NAVB_LINK)
	{
		budget = NAV_LINK_BUDGET;
		while (budget > 0 && nav_link_cursor < nav_count)
		{
			Nav_LinkNode(nav_link_cursor);
			nav_link_cursor = nav_link_cursor + 1;
			budget = budget - 1;
		}
		if (nav_link_cursor >= nav_count)
		{
			nav_state = NAVB_READY;
			Nav_PrintStats();
		}
		return;
	}
};
